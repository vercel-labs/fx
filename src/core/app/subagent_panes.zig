//! Live logs of subagent runs for a command that shows them outside fx, such
//! as a terminal split beside the session. Off unless FX_SUBAGENT_START_CMD
//! names that command.
//!
//! Each run gets a plain-text log of the subagent's streamed text and tool
//! calls. When the run starts, fx runs `$FX_SUBAGENT_START_CMD <log> <id>
//! <name>` detached; the log's last line is `[fx-subagent] end <outcome>`
//! once the run is over. Everything here is best effort: a failure turns the
//! log off for that run and never reaches the session.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

pub const env_var = "FX_SUBAGENT_START_CMD";
pub const end_marker = "[fx-subagent] end ";

const Run = struct {
    file: std.Io.File,
};

var mutex: std.Io.Mutex = .init;
var runs: std.StringHashMapUnmanaged(Run) = .empty;
var spawned: std.ArrayListUnmanaged(std.process.Child.Id) = .empty;
var next_run: u64 = 1;

fn command() ?[]const u8 {
    const value = io_mod.getenv(env_var) orelse return null;
    return if (value.len > 0) value else null;
}

/// Opens a log for child `id`'s new run and starts the command on it. A run
/// already open for `id` keeps its log.
pub fn start(id: []const u8, name: []const u8) void {
    const alloc = std.heap.c_allocator;
    const cmd = command() orelse return;
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    reapSpawned();
    if (runs.contains(id)) return;

    const base = io_mod.getenv("TMPDIR") orelse "/tmp";
    const dir = std.fmt.allocPrint(alloc, "{s}/fx-subagents/{d}", .{ std.mem.trimEnd(u8, base, "/"), std.c.getpid() }) catch return;
    defer alloc.free(dir);
    io_mod.makeDirRecursive(dir) catch |err| {
        debug_trace.logf("subagent-panes", "log dir not made err={s}", .{@errorName(err)});
        return;
    };
    const path = std.fmt.allocPrint(alloc, "{s}/{d}.log", .{ dir, next_run }) catch return;
    defer alloc.free(path);
    next_run += 1;
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true }) catch |err| {
        debug_trace.logf("subagent-panes", "log not opened err={s}", .{@errorName(err)});
        return;
    };
    const key = alloc.dupe(u8, id) catch {
        file.close(io);
        return;
    };
    runs.put(alloc, key, .{ .file = file }) catch {
        alloc.free(key);
        file.close(io);
        return;
    };

    var argv = [_][]const u8{ cmd, path, id, if (name.len > 0) name else id };
    const child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |err| {
        debug_trace.logf("subagent-panes", "command not started err={s}", .{@errorName(err)});
        return;
    };
    // Reaped on a later call so a finished command does not stay a zombie.
    if (child.id) |pid| spawned.append(alloc, pid) catch {};
    debug_trace.logf("subagent-panes", "started agent={s} log={s}", .{ id, path });
}

fn write(id: []const u8, bytes: []const u8) void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const run = runs.getPtr(id) orelse return;
    run.file.writeStreamingAll(io, bytes) catch {};
}

/// Appends streamed assistant text from child `id`.
pub fn appendText(id: []const u8, text: []const u8) void {
    if (command() == null) return;
    write(id, text);
}

/// Records that child `id` started a tool call, on a line of its own.
pub fn noteTool(id: []const u8, label: []const u8) void {
    if (command() == null) return;
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\n▸ {s}\n", .{label[0..@min(label.len, 400)]}) catch return;
    write(id, line);
}

/// Ends child `id`'s run: writes the end marker and closes its log.
pub fn finish(id: []const u8, outcome: []const u8) void {
    const alloc = std.heap.c_allocator;
    if (command() == null) return;
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const entry = runs.fetchRemove(id) orelse return;
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\n" ++ end_marker ++ "{s}\n", .{outcome}) catch "";
    entry.value.file.writeStreamingAll(io, line) catch {};
    entry.value.file.close(io);
    alloc.free(entry.key);
    reapSpawned();
}

fn reapSpawned() void {
    var i: usize = 0;
    while (i < spawned.items.len) {
        if (std.c.waitpid(spawned.items[i], null, std.c.W.NOHANG) == 0) {
            i += 1;
            continue;
        }
        _ = spawned.swapRemove(i);
    }
}

test "start without the command set does nothing" {
    start("child", "name");
    appendText("child", "text");
    finish("child", "done");
    try std.testing.expectEqual(@as(usize, 0), runs.count());
}
