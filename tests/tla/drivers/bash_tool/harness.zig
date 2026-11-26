//! A JSON-lines shell around the real result store of the bash tool's `$FX_OUT`
//! folder, for the Bun driver in tests/tla/drivers/bash_tool/.
//!
//! The driver copies this file to the root of a work folder that holds a copy of
//! src/, so each import below is a real file of this tree. The store is real:
//! `ResultFolder` numbers, captures, publishes, and indexes each result (`nextNumber`,
//! `capture`, `publish`, `appendIndex`), and `program_output` and `bash_results`
//! build the text the model sees. `restart` drops the folder object and opens it again on the same
//! folder, as a resumed fx process does. The state of the store is read back from
//! the folder: each result file's first bytes name its program.
//!
//! The session around the store is glue. Which program runs, when it ends, the
//! saved bash state, the damage and the heal, and the client's wait follow the
//! rules of ResultStore.tla in this file. No program and no bash session runs.
//!
//! Each input line is one event: {"event":"send","i":1}. The first output line is
//! the state after start, and each later line is the state after one event, as
//! {"state":{...},"out":[...]}. An event whose guard does not hold is refused: the
//! state does not change, and `out` says so.
//!
//! The process takes `--root DIR --room N`: the folder holds N result files, and
//! the store's results folders sit under DIR. `reset` is not a model step: it
//! starts again from the initial state in a new empty results folder, which is what
//! a new fx process with a new workspace does. The walk uses it, so one process
//! can cover many runs.
const std = @import("std");
const io_mod = @import("src/core/shared/io.zig");
const result_files = @import("src/core/session/result_files.zig");
const bash_results = @import("src/core/bash_results/bash_results.zig");
const program_output = @import("src/tools/bash/program_output.zig");
const text_utils = @import("src/core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;

const programs = 3;
/// How many times fx may stop and resume (ResultStore's MaxRestarts).
const max_restarts = 1;
/// Every program prints exactly this many bytes, so `room` files fill the folder.
const output_bytes = 32;
const inline_bytes = 4096;
const full_notice = "not saved: the results folder is full";
const names = [programs][]const u8{ "p1", "p2", "p3" };
const no_flags: [programs]bool = .{ false, false, false };
const no_counts: [programs]u32 = .{ 0, 0, 0 };
const no_kinds: [programs]Kind = .{ .none, .none, .none };
const commands = [programs][]const u8{ "echo p1", "echo p2", "echo p3" };

const Phase = enum { idle, run, ended, filed, saved };
const Kind = enum { none, ok, exit, killed };

const Input = struct {
    event: []const u8,
    i: ?u32 = null,
    kind: ?[]const u8 = null,
    big: bool = false,
};

/// A result file the folder has shown: its number and its program's index.
const FileRec = struct { n: u64, prog: u8 };

const FileJson = struct { n: u64, prog: []const u8 };
const RunsJson = struct { p1: u32, p2: u32, p3: u32 };
const HowJson = struct { p1: []const u8, p2: []const u8, p3: []const u8 };
const StateJson = struct {
    sent: []const []const u8,
    current: []const u8,
    phase: []const u8,
    ready: []const u8,
    waiting: []const u8,
    shown: []const []const u8,
    files: []const FileJson,
    indexed: []const u64,
    unsaved: []const []const u8,
    fullNoticed: []const []const u8,
    stopped: []const []const u8,
    restarts: u32,
    runs: RunsJson,
    saves: u32,
    torn: bool,
    how: HowJson,
    savedBy: []const []const u8,
    refused: []const []const u8,
    noticed: []const []const u8,
    damaged: bool,
    lost: []const []const u8,
    lostNoticed: []const []const u8,
    unreported: bool,
};
const LineJson = struct { state: StateJson, out: []const []const u8 };

const Harness = struct {
    /// Owns the memory of one generation: a reset frees it and starts a new arena.
    base: Allocator,
    arena: *std.heap.ArenaAllocator,
    alloc: Allocator,
    root: []const u8,
    /// How many result files the folder holds before it is full (ResultStore's Room).
    room: u64,
    generation: u32 = 0,
    path: []const u8,
    limits: result_files.Limits,
    folder: result_files.ResultFolder,

    sent: [programs]bool = no_flags,
    current: ?u8 = null,
    phase: Phase = .idle,
    ready: ?u8 = null,
    waiting: ?u8 = null,
    shown: [programs]bool = no_flags,
    unsaved: [programs]bool = no_flags,
    full_noticed: [programs]bool = no_flags,
    stopped: [programs]bool = no_flags,
    restarts: u32 = 0,
    runs: [programs]u32 = no_counts,
    saves: u32 = 0,
    how: [programs]Kind = no_kinds,
    saved_by: [programs]bool = no_flags,
    refused: [programs]bool = no_flags,
    noticed: [programs]bool = no_flags,
    damaged: bool = false,
    lost: [programs]bool = no_flags,
    lost_noticed: [programs]bool = no_flags,
    unreported: bool = false,

    /// Every result file the folder has shown so far, with the program it holds.
    files: std.ArrayList(FileRec) = .empty,
    /// The numbers of the index lines in index.tsv now.
    indexed: std.ArrayList(u64) = .empty,
    /// The number the folder gave the current program's file, until its index line is written.
    pending_n: ?u64 = null,
    /// The text the model would see for the ready result, and the file it names, if any.
    ready_text: ?[]const u8 = null,
    ready_file: ?u64 = null,
    notes: std.ArrayList([]const u8) = .empty,

    fn note(self: *Harness, comptime fmt: []const u8, args: anytype) !void {
        try self.notes.append(self.alloc, try self.alloc.print(fmt, args));
    }

    fn hasFile(self: *const Harness, n: u64, prog: u8) bool {
        for (self.files.items) |rec| {
            if (rec.n == n and rec.prog == prog) return true;
        }
        return false;
    }

    fn hasIndexed(self: *const Harness, n: u64) bool {
        for (self.indexed.items) |m| {
            if (m == n) return true;
        }
        return false;
    }

    fn fileExists(self: *Harness, n: u64) bool {
        var buf: [32]u8 = undefined;
        const name = std.mem.print(&buf, "{d}.txt", .{n}) catch return false;
        self.folder.dir.dir.access(io_mod.getIo(), name, .{}) catch return false;
        return true;
    }

    /// Reads the folder back: each N.txt it holds, and each index line in index.tsv.
    fn observe(self: *Harness) !void {
        const io = io_mod.getIo();
        var it = self.folder.dir.dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const n = resultNumber(entry.name) orelse continue;
            const bytes = try self.folder.dir.dir.readFileAlloc(io, entry.name, self.alloc, .limited(64));
            const prog = programOf(bytes) orelse return error.UnknownResultFile;
            if (!self.hasFile(n, prog)) try self.files.append(self.alloc, .{ .n = n, .prog = prog });
        }
        self.indexed.clearRetainingCapacity();
        const index_bytes = self.folder.dir.dir.readFileAlloc(io, result_files.index_file_name, self.alloc, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        var lines = std.mem.splitScalar(u8, index_bytes, '\n');
        while (lines.next()) |line| {
            const field = line[0 .. std.mem.findScalar(u8, line, '\t') orelse line.len];
            const n = std.fmt.parseInt(u64, field, 10) catch continue;
            if (!self.hasIndexed(n)) try self.indexed.append(self.alloc, n);
        }
    }

    fn perform(self: *Harness, input: Input) !bool {
        const event = input.event;
        if (eq(event, "reset")) {
            try self.reset();
            return true;
        }
        if (eq(event, "send")) return self.send(try progIndex(input.i));
        if (eq(event, "finish")) return self.finish(try kindOf(input.kind), input.big);
        if (eq(event, "file")) return self.file();
        if (eq(event, "index")) return self.index();
        if (eq(event, "clear")) return self.clear();
        if (eq(event, "show")) return self.show();
        if (eq(event, "give_up")) return self.giveUp();
        if (eq(event, "wait_more")) return self.waitMore();
        if (eq(event, "damage")) return self.damage();
        if (eq(event, "heal_fails")) return self.healFails();
        if (eq(event, "restart")) return self.restart();
        return error.UnknownEvent;
    }

    /// Starts a program. A loss of the saved state the damage caused is reported
    /// to this program's result (glue, as ResultStore's Send).
    fn send(self: *Harness, k: u8) !bool {
        if (self.sent[k] or self.phase != .idle) return false;
        self.sent[k] = true;
        self.current = k;
        self.phase = .run;
        self.runs[k] += 1;
        self.ready = null;
        self.waiting = k;
        if (self.damaged) {
            self.damaged = false;
            self.lost[k] = true;
            self.lost_noticed[k] = true;
            self.unreported = false;
            try self.note("the saved bash state was lost, so {s} starts from a fresh state", .{names[k]});
        }
        return true;
    }

    /// The program ends (glue). A killed program saves no state. A state over the cap is refused.
    fn finish(self: *Harness, kind: Kind, big: bool) bool {
        if (self.phase != .run) return false;
        const k = self.current.?;
        self.phase = .ended;
        self.how[k] = kind;
        if (kind == .killed) return true;
        if (big) {
            self.refused[k] = true;
            self.noticed[k] = true;
            return true;
        }
        self.saves += 1;
        self.saved_by[k] = true;
        return true;
    }

    /// The real store publishes the ended program's output as the next numbered file.
    /// A number another writer takes between the pick and the publish is picked again,
    /// once, with the same output, as program_output.save does. A folder with no room
    /// saves nothing, and the result is ready at once.
    fn file(self: *Harness) !bool {
        if (self.phase != .ended) return false;
        const k = self.current.?;
        var n = try self.folder.nextNumber();
        const content = outputOf(k);
        var reader: std.Io.Reader = .fixed(content[0..]);
        var captured = try self.folder.capture(&reader);
        defer captured.deinit(self.alloc);
        const outcome = self.folder.publish(n, &captured) catch |err| switch (err) {
            error.NumberTaken => taken: {
                n = try self.folder.nextNumber();
                break :taken self.folder.publish(n, &captured) catch |again| switch (again) {
                    error.NumberTaken => {
                        try self.notSaved(k, "the result number was taken twice");
                        return true;
                    },
                    else => return again,
                };
            },
            else => return err,
        };
        switch (outcome) {
            .saved => {
                self.pending_n = n;
                self.phase = .filed;
            },
            .full => {
                const text = try self.resultText(k, .not_saved_full, self.how[k], false);
                self.unsaved[k] = true;
                if (std.mem.find(u8, text, full_notice) != null) self.full_noticed[k] = true;
                self.ready = k;
                self.ready_text = text;
                self.ready_file = null;
                self.phase = .saved;
            },
        }
        return true;
    }

    /// A result whose output could not be published is shown with its reason. The
    /// model has no such step, so the state differs from the model's and the trace check fails.
    fn notSaved(self: *Harness, k: u8, reason: []const u8) !void {
        self.ready = k;
        self.ready_text = try self.resultText(k, .{ .not_saved_error = reason }, self.how[k], false);
        self.ready_file = null;
        self.phase = .saved;
    }

    /// The real store adds the file's index line. A line that cannot be written
    /// is reported in the result, as program_output.save does, and the result is ready.
    fn index(self: *Harness) !bool {
        if (self.phase != .filed) return false;
        const k = self.current.?;
        const n = self.pending_n.?;
        var index_missing = false;
        self.folder.appendIndex(.{
            .n = n,
            .exit = exitOf(self.how[k]),
            .bytes = output_bytes,
            .lines = 1,
            .command = commands[k],
        }) catch |err| {
            index_missing = true;
            try self.note("index line not written: {s}", .{@errorName(err)});
        };
        self.pending_n = null;
        self.ready = k;
        self.ready_text = try self.resultText(k, .{ .file = n }, self.how[k], index_missing);
        self.ready_file = n;
        self.phase = .saved;
        return true;
    }

    fn clear(self: *Harness) bool {
        if (self.phase != .saved) return false;
        self.phase = .idle;
        return true;
    }

    /// The waiting client shows the model the ready result. The text names a file
    /// that must exist and have its index line (SavedBeforeShown).
    fn show(self: *Harness) !bool {
        const w = self.waiting orelse return false;
        if (self.ready != w) return false;
        const text = self.ready_text orelse return error.ReadyWithoutText;
        if (self.ready_file) |n| {
            if (!self.fileExists(n) or !self.hasIndexed(n)) {
                try self.note("shown before its file was saved and indexed: {d}.txt", .{n});
            }
        }
        try self.note("shown: {s}", .{text});
        self.shown[w] = true;
        self.waiting = null;
        self.ready = null;
        self.ready_text = null;
        self.ready_file = null;
        return true;
    }

    /// The client's wait ends before the ready result arrives (glue).
    fn giveUp(self: *Harness) bool {
        if (self.waiting == null or self.ready == self.waiting) return false;
        self.waiting = null;
        return true;
    }

    /// wait_more waits for the last program, running or ready, and never starts it again.
    fn waitMore(self: *Harness) bool {
        const running = self.phase != .idle;
        if (self.waiting != null or (!running and self.ready == null)) return false;
        self.waiting = self.current;
        return true;
    }

    /// After its save, the last program damages the session's files (glue).
    fn damage(self: *Harness) bool {
        if (self.current == null or self.phase == .run or self.damaged) return false;
        self.damaged = true;
        self.unreported = true;
        return true;
    }

    /// The next program's heal fails, so nothing runs and the loss stays unreported (glue).
    fn healFails(self: *Harness) !bool {
        if (self.phase != .idle or !self.damaged) return false;
        try self.note("the session folder could not be made, so nothing ran and the loss stays unreported", .{});
        return true;
    }

    /// fx stops and resumes in a new process: the folder object is dropped and
    /// opened again on the same folder. What was in flight is not shown.
    fn restart(self: *Harness) !bool {
        if (self.restarts >= max_restarts) return false;
        self.restarts += 1;
        if (self.current) |k| {
            if (self.phase == .run or self.phase == .ended or self.phase == .filed) self.stopped[k] = true;
        }
        self.phase = .idle;
        self.current = null;
        self.ready = null;
        self.waiting = null;
        self.ready_text = null;
        self.ready_file = null;
        self.pending_n = null;
        self.folder.deinit();
        self.folder = try result_files.ResultFolder.initWithLimits(self.alloc, self.path, self.limits);
        return true;
    }

    /// Starts again from the initial state, in an empty results folder of its own.
    fn reset(self: *Harness) !void {
        self.folder.deinit();
        const base = self.base;
        const root = self.root;
        const room = self.room;
        const limits = self.limits;
        const arena = self.arena;
        const generation = self.generation + 1;
        arena.deinit();
        arena.* = std.heap.ArenaAllocator.init(base);
        const alloc = arena.allocator();
        const path = try alloc.print("{s}/results-{d}", .{ root, generation });
        self.* = .{
            .base = base,
            .arena = arena,
            .alloc = alloc,
            .root = root,
            .room = room,
            .generation = generation,
            .path = path,
            .limits = limits,
            .folder = try result_files.ResultFolder.initWithLimits(alloc, path, limits),
        };
    }

    /// The text the model sees for an ended program: its header, its output as
    /// bash_results plans it (or the binary notice), and the index notice. This follows
    /// bash.zig's formatResult and appendBody for an ended program, whose functions are
    /// private.
    fn resultText(self: *Harness, k: u8, saved: bash_results.Saved, kind: Kind, index_missing: bool) ![]const u8 {
        const content = outputOf(k);
        var keep = try program_output.Keep.init(self.alloc, program_output.keep_min_bytes);
        defer keep.deinit();
        keep.feed(content[0..]);
        const output: program_output.Output = .{
            .saved = saved,
            .stats = keep.stats,
            .head = keep.head(),
            .tail = keep.tail(),
            .keep = null,
            .index_missing = index_missing,
        };
        var text: std.ArrayList(u8) = .empty;
        var header: std.Io.Writer.Allocating = .init(self.alloc);
        try bash_results.writeHeader(&header.writer, .{
            .state = stateOf(kind),
            .bytes = output.stats.bytes,
            .lines = output.stats.lines(),
            .saved = output.saved,
        });
        try appendLine(self.alloc, &text, header.written());
        const planned = bash_results.plan(output.head, output.tail, output.stats, .{ .inline_bytes = inline_bytes });
        const notice = noticeOf(saved);
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        if (std.meta.activeTag(planned) == .preview) try bash_results.writeShape(&body.writer, output.stats, notice);
        if (modelSafe(planned)) {
            try bash_results.writePreview(&body.writer, planned, notice);
        } else {
            try bash_results.writeBinaryNotice(&body.writer, notice);
        }
        if (body.written().len > 0) try appendLine(self.alloc, &text, body.written());
        if (index_missing) {
            var missing: std.Io.Writer.Allocating = .init(self.alloc);
            try bash_results.writeIndexMissing(&missing.writer, saved);
            try appendLine(self.alloc, &text, missing.written());
        }
        return text.items;
    }

    fn stateJson(self: *const Harness) !StateJson {
        const alloc = self.alloc;
        var files: std.ArrayList(FileJson) = .empty;
        for (self.files.items) |rec| try files.append(alloc, .{ .n = rec.n, .prog = names[rec.prog] });
        return .{
            .sent = try progSet(alloc, self.sent),
            .current = optName(self.current),
            .phase = @tagName(self.phase),
            .ready = optName(self.ready),
            .waiting = optName(self.waiting),
            .shown = try progSet(alloc, self.shown),
            .files = files.items,
            .indexed = self.indexed.items,
            .unsaved = try progSet(alloc, self.unsaved),
            .fullNoticed = try progSet(alloc, self.full_noticed),
            .stopped = try progSet(alloc, self.stopped),
            .restarts = self.restarts,
            .runs = .{ .p1 = self.runs[0], .p2 = self.runs[1], .p3 = self.runs[2] },
            .saves = self.saves,
            .torn = false,
            .how = .{ .p1 = @tagName(self.how[0]), .p2 = @tagName(self.how[1]), .p3 = @tagName(self.how[2]) },
            .savedBy = try progSet(alloc, self.saved_by),
            .refused = try progSet(alloc, self.refused),
            .noticed = try progSet(alloc, self.noticed),
            .damaged = self.damaged,
            .lost = try progSet(alloc, self.lost),
            .lostNoticed = try progSet(alloc, self.lost_noticed),
            .unreported = self.unreported,
        };
    }
};

/// Whether the text the model would read is safe (bash.zig appendBody).
fn modelSafe(planned: bash_results.Plan) bool {
    return switch (planned) {
        .whole => |text| text_utils.isModelSafeText(text),
        .preview => |preview| text_utils.isModelSafeText(preview.head) and text_utils.isModelSafeText(preview.tail),
    };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn progIndex(value: ?u32) !u8 {
    const i = value orelse return error.MissingProgram;
    if (i < 1 or i > programs) return error.BadProgram;
    return @intCast(i - 1);
}

fn kindOf(text: ?[]const u8) !Kind {
    const word = text orelse return error.MissingKind;
    if (eq(word, "ok")) return .ok;
    if (eq(word, "exit")) return .exit;
    if (eq(word, "killed")) return .killed;
    return error.BadKind;
}

fn stateOf(kind: Kind) bash_results.State {
    return switch (kind) {
        .ok => .{ .exit = 0 },
        .exit => .{ .exit = 1 },
        .killed => .{ .signal = 9 },
        .none => .unknown,
    };
}

fn exitOf(kind: Kind) result_files.Exit {
    return switch (kind) {
        .ok => .{ .code = 0 },
        .exit => .{ .code = 1 },
        .killed => .{ .signal = 9 },
        .none => .unknown,
    };
}

fn noticeOf(saved: bash_results.Saved) bash_results.Notice {
    return switch (saved) {
        .file => |number| .{ .file = number },
        .file_cut => |cut| .{ .file = cut.number },
        .not_saved_full, .not_saved_error => .not_saved,
    };
}

/// The bytes a program prints: its name, then filler, then a line end. Always 32 bytes.
fn outputOf(k: u8) [output_bytes]u8 {
    var bytes: [output_bytes]u8 = undefined;
    @memset(&bytes, 'x');
    bytes[0] = 'p';
    bytes[1] = '1' + k;
    bytes[2] = ' ';
    bytes[output_bytes - 1] = '\n';
    return bytes;
}

fn programOf(bytes: []const u8) ?u8 {
    if (bytes.len < 2 or bytes[0] != 'p') return null;
    const digit = bytes[1];
    if (digit < '1' or digit > '0' + programs) return null;
    return digit - '1';
}

fn resultNumber(name: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, name, ".txt")) return null;
    return std.fmt.parseInt(u64, name[0 .. name.len - ".txt".len], 10) catch null;
}

fn appendLine(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
    try out.appendSlice(alloc, text);
}

fn optName(k: ?u8) []const u8 {
    return if (k) |v| names[v] else "none";
}

fn progSet(alloc: Allocator, set: [programs]bool) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (set, 0..) |on, k| {
        if (on) try list.append(alloc, names[k]);
    }
    return list.items;
}

fn writeLine(writer: *std.Io.Writer, harness: *const Harness, notes: []const []const u8) !void {
    const line: LineJson = .{ .state = try harness.stateJson(), .out = notes };
    try std.json.Stringify.value(line, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    io_mod.setIo(io);
    const alloc = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5 or !std.mem.eql(u8, args[1], "--root") or !std.mem.eql(u8, args[3], "--room")) return error.Usage;
    const root = args[2];
    const room = try std.fmt.parseInt(u64, args[4], 10);
    const path = try std.Io.Dir.path.join(arena, &.{ root, "results-0" });
    const limits: result_files.Limits = .{ .max_folder_bytes = room * output_bytes };
    var harness: Harness = .{
        .base = alloc,
        .arena = &arena_state,
        .alloc = arena,
        .root = root,
        .room = room,
        .path = path,
        .limits = limits,
        .folder = try result_files.ResultFolder.initWithLimits(arena, path, limits),
    };

    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);

    try harness.observe();
    try writeLine(&stdout.interface, &harness, &.{});
    while (try stdin.interface.takeDelimiter('\n')) |raw| {
        const text = std.mem.trim(u8, raw, " \r\t");
        if (text.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Input, arena, text, .{ .ignore_unknown_fields = true });
        harness.notes.clearRetainingCapacity();
        if (!try harness.perform(parsed.value)) try harness.note("refused: {s}", .{parsed.value.event});
        try harness.observe();
        try writeLine(&stdout.interface, &harness, harness.notes.items);
    }
}
