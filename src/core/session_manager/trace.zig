//! Test-only trace hook, compiled only with `-Dhooks=true`.
//!
//! Each traced run writes `zig-out/traces/SPEC--CASE.ndjson`: one JSON line
//! per spec action, named like the action, with one field per spec variable
//! (`docs/session-manager/tla/trace/README.md`). Fields that model the disk
//! are read back from the real files after the step; fields that model
//! memory come from the code's own state.
//!
//! A trace write failure never changes the traced code's behavior; it is
//! kept and returned by `finish`, which fails the test.

const std = @import("std");
const build_options = @import("build_options");
const schema = @import("schema.zig");
const Io = std.Io;

/// The folder unit tests write traces to.
pub const default_dir = build_options.trace_dir;

/// Deliberate bugs that trace tests plant to prove a wrapper rejects them.
pub const Planted = enum {
    none,
    /// Recovery leaves a torn final line in place (SessionLog).
    keep_torn_tail,
    /// The first-turn publish renames before syncing line 1 (Lifecycle).
    rename_before_fsync,
    /// The manager accepts an item with no open turn (TurnLifecycle).
    accept_item_outside_turn,
    /// open(.resume) skips the flock (WriterLock).
    skip_flock,
    /// Snapshots leave out the prefs setting (ResumeSnapshot).
    snapshot_drops_field,
    /// A fork leaves one source blob unlinked (Fork).
    fork_skips_blob_link,
    /// Parent reopen repair finishes the first child twice (Subagents).
    repair_marks_child_twice,
    /// Rebuild lists sessions sitting in `.trash` as live (Catalog).
    rebuild_resurrects,
};

/// One ndjson trace file.
pub const Trace = struct {
    gpa: std.mem.Allocator,
    io: Io,
    file: Io.File,
    offset: u64 = 0,
    failure: ?anyerror = null,

    /// Creates `SPEC--CASE.ndjson` in the build's trace folder, replacing an
    /// older run's file.
    pub fn create(gpa: std.mem.Allocator, io: Io, spec: []const u8, case: []const u8) !Trace {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, build_options.trace_dir);
        var dir = try cwd.openDir(io, build_options.trace_dir, .{});
        defer dir.close(io);
        var name_buffer: [256]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s}--{s}.ndjson", .{ spec, case });
        const file = try dir.createFile(io, name, .{ .truncate = true });
        return .{ .gpa = gpa, .io = io, .file = file };
    }

    /// Opens an existing trace to continue it, as the driver does after a
    /// worker process was killed.
    pub fn append(gpa: std.mem.Allocator, io: Io, path: []const u8) !Trace {
        const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        return .{ .gpa = gpa, .io = io, .file = file, .offset = try file.length(io) };
    }

    /// Creates or replaces a trace at an explicit path.
    pub fn createAt(gpa: std.mem.Allocator, io: Io, path: []const u8) !Trace {
        const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        return .{ .gpa = gpa, .io = io, .file = file };
    }

    /// Appends one JSON line.
    pub fn write(t: *Trace, value: anytype) void {
        if (t.failure != null) return;
        t.writeFallible(value) catch |err| {
            t.failure = err;
        };
    }

    fn writeFallible(t: *Trace, value: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(t.gpa, value, .{});
        defer t.gpa.free(json);
        try t.file.writePositionalAll(t.io, json, t.offset);
        t.offset += json.len;
        try t.file.writePositionalAll(t.io, "\n", t.offset);
        t.offset += 1;
    }

    /// Closes the file and returns the first write failure, if any.
    pub fn finish(t: *Trace) !void {
        t.file.close(t.io);
        if (t.failure) |err| return err;
    }
};

/// Traces `SessionLog.tla` for one log file.
pub const SessionLogTracer = struct {
    trace: Trace,
    /// The traced log's folder and name. Read directly, never through the
    /// fault layer, so a dead process's disk can still be observed.
    dir: Io.Dir,
    name: []const u8,
    /// Caller-side ghost state: lines acknowledged durable. It survives
    /// crashes, like the callers who were told.
    acked: u64 = 0,

    pub const Status = enum { open, writing, down };

    pub fn step(t: *SessionLogTracer, event: []const u8, durable: u64, status: Status) void {
        const disk = readDisk(t.trace.gpa, t.trace.io, t.dir, t.name) catch |err| {
            t.trace.failure = t.trace.failure orelse err;
            return;
        };
        defer t.trace.gpa.free(disk.seqs);
        if (std.mem.eql(u8, event, "Fsync")) t.acked = durable;
        t.trace.write(.{
            .event = event,
            .log_len = disk.log_len,
            .tail_done = disk.tail_done,
            .seqs = disk.seqs,
            .durable = durable,
            .acked = t.acked,
            .status = @tagName(status),
        });
    }

    pub fn finish(t: *SessionLogTracer) !void {
        return t.trace.finish();
    }
};

const Disk = struct {
    log_len: u64,
    tail_done: bool,
    /// Owned by the caller.
    seqs: []i64,
};

/// The abstraction function from file bytes to `SessionLog` state: every
/// complete line, a torn final line if the file does not end in a newline,
/// and the seq parsed from each complete line (-1 when it does not parse).
fn readDisk(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) !Disk {
    const data = try dir.readFileAlloc(io, name, gpa, .limited(64 << 20));
    defer gpa.free(data);
    var seqs: std.ArrayList(i64) = .empty;
    errdefer seqs.deinit(gpa);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var complete: u64 = 0;
    while (lines.next()) |line| {
        if (lines.index == null) break; // the part after the last newline
        complete += 1;
        const seq: i64 = if (schema.parseHeader(line)) |h|
            std.math.cast(i64, h.seq) orelse -1
        else |_|
            -1;
        try seqs.append(gpa, seq);
    }
    const torn = data.len > 0 and data[data.len - 1] != '\n';
    return .{
        .log_len = complete + @intFromBool(torn),
        .tail_done = !torn,
        .seqs = try seqs.toOwnedSlice(gpa),
    };
}

test "the disk abstraction counts a torn tail and parses seqs" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "log",
        .data = "{\"v\":1,\"seq\":1,\"ts\":0,\"kind\":\"item\"}\ngarbage\n{\"v\":1,\"se",
    });
    const disk = try readDisk(std.testing.allocator, io, tmp.dir, "log");
    defer std.testing.allocator.free(disk.seqs);
    try std.testing.expectEqual(@as(u64, 3), disk.log_len);
    try std.testing.expect(!disk.tail_done);
    try std.testing.expectEqualSlices(i64, &.{ 1, -1 }, disk.seqs);
}

// ---------------------------------------------------------------------------
// TurnLifecycle, for any number of sessions and across processes

const session_mod = @import("session.zig");
const log_mod = @import("log.zig");

/// Traces `TurnLifecycle.tla` for every session of one manager, one file
/// per session: `{dir}/TurnLifecycle--{case}-{id}.ndjson`. A session is
/// traced from its creation; forks and sessions created elsewhere are not
/// (`Fork.tla` covers forks). Each line also records the tracer's own state
/// (`status`, `fresh`), so a later process can continue a trace after the
/// one that wrote it was killed.
pub const TurnTraces = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The sessions root, read directly.
    root: Io.Dir,
    dir: []const u8,
    case: []const u8,
    mutex: Io.Mutex = .init,
    sessions: std.ArrayList(Per) = .empty,
    /// The first failure to start a trace file; `finish` returns it.
    failure: ?anyerror = null,

    const Per = struct {
        id: []u8,
        path: []u8,
        trace: Trace,
        status: []const u8,
        fresh: bool,
    };

    pub fn observer(t: *TurnTraces) session_mod.Observer {
        return .{ .context = t, .notify = notify };
    }

    pub fn deinit(t: *TurnTraces) void {
        for (t.sessions.items) |*per| {
            t.gpa.free(per.id);
            t.gpa.free(per.path);
        }
        t.sessions.deinit(t.gpa);
    }

    /// Closes every trace file; returns the first failure.
    pub fn finish(t: *TurnTraces) !void {
        var first: ?anyerror = t.failure;
        for (t.sessions.items) |*per| per.trace.finish() catch |err| {
            first = first orelse err;
        };
        if (first) |err| return err;
    }

    /// The trace path for a session (caller frees).
    pub fn pathFor(gpa: std.mem.Allocator, dir: []const u8, case: []const u8, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/TurnLifecycle--{s}-{s}.ndjson", .{ dir, case, id });
    }

    /// Continues a trace written by a process that was killed: restores
    /// the tracer's state from its last line, then records the crash.
    pub fn adoptAfterKill(t: *TurnTraces, id: []const u8) !void {
        const path = try pathFor(t.gpa, t.dir, t.case, id);
        errdefer t.gpa.free(path);
        const bytes = Io.Dir.cwd().readFileAlloc(t.io, path, t.gpa, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                t.gpa.free(path);
                return; // the worker died before this session's first event
            },
            else => return err,
        };
        defer t.gpa.free(bytes);
        var status: []const u8 = "new";
        var fresh = false;
        const trimmed = std.mem.trimEnd(u8, bytes, "\n");
        if (trimmed.len > 0) {
            const last = trimmed[if (std.mem.findScalarLast(u8, trimmed, '\n')) |nl| nl + 1 else 0..];
            const Last = struct { status: []const u8, fresh: bool };
            const parsed = try std.json.parseFromSlice(Last, t.gpa, last, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            status = statusName(parsed.value.status);
            fresh = parsed.value.fresh;
        }
        try t.sessions.append(t.gpa, .{
            .id = try t.gpa.dupe(u8, id),
            .path = path,
            .trace = try Trace.append(t.gpa, t.io, path),
            .status = status,
            .fresh = fresh,
        });
        // Crash applies only to an open session (the spec's guard).
        if (std.mem.eql(u8, status, "open")) t.crash(id);
    }

    /// Every session traced so far.
    pub fn traced(t: *TurnTraces) []const Per {
        return t.sessions.items;
    }

    /// fx died with this session open.
    pub fn crash(t: *TurnTraces, id: []const u8) void {
        const per = t.find(id) orelse return;
        if (!std.mem.eql(u8, per.status, "open")) return;
        per.status = "down";
        t.emit(per, "Crash", null, null);
    }

    fn statusName(s: []const u8) []const u8 {
        for ([_][]const u8{ "new", "open", "closed", "down" }) |known| {
            if (std.mem.eql(u8, s, known)) return known;
        }
        return "down";
    }

    fn find(t: *TurnTraces, id: []const u8) ?*Per {
        for (t.sessions.items) |*per| {
            if (std.mem.eql(u8, per.id, id)) return per;
        }
        return null;
    }

    fn start(t: *TurnTraces, id: []const u8) ?*Per {
        if (t.find(id)) |per| return per;
        return t.startFallible(id) catch |err| {
            t.failure = t.failure orelse err;
            return null;
        };
    }

    fn startFallible(t: *TurnTraces, id: []const u8) !*Per {
        try Io.Dir.cwd().createDirPath(t.io, t.dir);
        const path = try pathFor(t.gpa, t.dir, t.case, id);
        errdefer t.gpa.free(path);
        const owned_id = try t.gpa.dupe(u8, id);
        errdefer t.gpa.free(owned_id);
        try t.sessions.ensureUnusedCapacity(t.gpa, 1);
        const trace = try Trace.createAt(t.gpa, t.io, path);
        t.sessions.appendAssumeCapacity(.{ .id = owned_id, .path = path, .trace = trace, .status = "new", .fresh = false });
        return &t.sessions.items[t.sessions.items.len - 1];
    }

    fn notify(context: *anyopaque, session: *session_mod.Session, what: session_mod.Observed) void {
        const t: *TurnTraces = @ptrCast(@alignCast(context));
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const is_header = what == .wrote_line and what.wrote_line.cause == .header;
        const per = (if (is_header) t.start(session.id()) else t.find(session.id())) orelse return;
        switch (what) {
            .wrote_line => |w| switch (w.cause) {
                .header => {
                    per.status = "open";
                    t.emit(per, "Create", null, w.seq);
                },
                .host, .workspace_repair => if (specKind(w.kind)) |k| {
                    if (std.mem.eql(u8, k, "start")) per.fresh = false;
                    t.emit(per, "Write", k, w.seq);
                },
                .snapshot, .close, .interrupt_repair, .child_repair => {},
            },
            .reopened => {
                per.status = "open";
                per.fresh = true;
                t.emit(per, "Reopen", null, null);
            },
            .closed => {
                per.status = "closed";
                per.fresh = false;
                t.emit(per, "Close", null, null);
            },
            else => {},
        }
    }

    fn specKind(kind: schema.Kind) ?[]const u8 {
        return switch (kind) {
            .session_created => "created",
            .turn_started => "start",
            .item => "item",
            .compacted => "compacted",
            .turn_committed => "commit",
            .turn_interrupted => "interrupt",
            .set => "set",
            .closed => "closed",
            .snapshot, .child_spawned, .child_finished => null,
        };
    }

    /// Writes one line. The disk view holds the lines up to `upto_seq`: a
    /// batch is one write, and its lines are observed one by one after it.
    fn emit(t: *TurnTraces, per: *Per, event: []const u8, kind: ?[]const u8, upto_seq: ?u64) void {
        var arena_state = std.heap.ArenaAllocator.init(t.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var kinds: std.ArrayList([]const u8) = .empty;
        if (readSessionLog(t.gpa, t.io, t.root, per.id)) |bytes| {
            defer t.gpa.free(bytes);
            var at: usize = 0;
            while (std.mem.findScalarPos(u8, bytes, at, '\n')) |nl| : (at = nl + 1) {
                const header = log_mod.checkLine(bytes[at .. nl + 1]) catch continue;
                if (upto_seq) |limit| if (header.seq > limit) break;
                const k = header.kind orelse continue;
                if (specKind(k)) |name| kinds.append(arena, name) catch return;
            }
        }
        if (kind) |k| {
            per.trace.write(.{ .event = event, .kind = k, .log = kinds.items, .status = per.status, .fresh = per.fresh });
        } else {
            per.trace.write(.{ .event = event, .log = kinds.items, .status = per.status, .fresh = per.fresh });
        }
    }
};

/// A session's log bytes from `{id}/` or, while it is being published,
/// from `.tmp/{id}/`. Caller frees.
fn readSessionLog(gpa: std.mem.Allocator, io: Io, root: Io.Dir, id: []const u8) ?[]u8 {
    var buf: [300]u8 = undefined;
    const direct = std.fmt.bufPrint(&buf, "{s}/log.jsonl", .{id}) catch return null;
    if (root.readFileAlloc(io, direct, gpa, .limited(64 << 20))) |bytes| return bytes else |_| {}
    const staged = std.fmt.bufPrint(&buf, ".tmp/{s}/log.jsonl", .{id}) catch return null;
    return root.readFileAlloc(io, staged, gpa, .limited(64 << 20)) catch null;
}
