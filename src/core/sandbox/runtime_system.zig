//! The sandbox runtime for this process, with the real hooks: the Vercel login,
//! the files in a command's folder, the files a command names, and the
//! environment of this process.
const std = @import("std");
const command_lex = @import("../shell_command/command_lex.zig");
const credentials = @import("credentials.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const runtime = @import("runtime.zig");
const sandbox_workspace = @import("workspace.zig");
const tool_files = @import("../workspace/tool_files.zig");

const Allocator = std.mem.Allocator;

/// Most files one isolated command names outside its folder.
const max_inputs = 32;
/// Most bytes of one named file that fx copies into an isolated sandbox.
const max_input_bytes: u64 = 64 * 1024 * 1024;
/// Most candidate files one folder listing may return.
const list_candidate_cap = 50_000;

/// The state behind the hooks. They keep none, so it is never read.
var system_context: u8 = 0;

/// The runtime for this process, and it starts the sweep. Only out of memory
/// fails. A missing sandbox folder is no error: the runtime has no config, so
/// every command stays local, and fx makes the folder when it first writes there.
/// A config that cannot be read makes the runtime refuse every command.
pub fn createForApp(alloc: Allocator, home: []const u8) error{OutOfMemory}!*runtime.Runtime {
    const sandbox_dir = try profile_paths.rootPath(alloc, home, &.{"sandbox"});
    defer alloc.free(sandbox_dir);
    const hooks: runtime.Hooks = .{
        .context = &system_context,
        .token = systemToken,
        .list_files = systemListFiles,
        .named_inputs = systemNamedInputs,
        .getenv = systemGetenv,
    };
    const user = io_mod.getenv("USER") orelse "unknown";
    const host = try hostName(alloc);
    defer alloc.free(host);
    const pid: u32 = @intCast(std.c.getpid());
    const rt = try runtime.Runtime.create(alloc, sandbox_dir, user, host, pid, hooks);
    rt.startSweep();
    return rt;
}

/// This machine's host name, or `unknown` when the system does not say.
fn hostName(alloc: Allocator) Allocator.Error![]const u8 {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&buf) catch return alloc.dupe(u8, "unknown");
    return alloc.dupe(u8, name);
}

fn systemToken(context: *anyopaque, arena: Allocator) credentials.Error![]const u8 {
    _ = context;
    const inputs = try credentials.systemInputs(arena);
    const token = try credentials.resolve(arena, inputs, credentials.systemEffects());
    return token.value;
}

/// The files under `cwd`, relative to it. A listing that was cut short is refused.
fn systemListFiles(context: *anyopaque, arena: Allocator, cwd: []const u8, problem: *[]const u8) anyerror!?[]const []const u8 {
    _ = context;
    // The listing's scratch memory has an arena of its own, so no other thread shares it.
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();
    const listing = try tool_files.list(scratch_state.allocator(), arena, cwd, cwd, .{
        .include_hidden = true,
        .include_hidden_in_repository = true,
        .candidate_cap = list_candidate_cap,
    });
    if (listing.incomplete or listing.cap_reached) {
        problem.* = try arena.print("fx could not list every file in {s}, so it did not copy it into an isolated sandbox.", .{cwd});
        return null;
    }
    return listing.files;
}

/// The files outside `cwd` that the command names: regular files, at most 64 MiB each, 32 at most.
fn systemNamedInputs(context: *anyopaque, arena: Allocator, cwd: []const u8, command: []const u8) anyerror![]const []const u8 {
    _ = context;
    // A command the lexer cannot read still runs: it just names no inputs.
    const argv = command_lex.tokenize_argv(arena, command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("sandbox", "named inputs skipped: the command could not be tokenized err={s}", .{@errorName(err)});
            return &.{};
        },
    };
    var inputs: std.ArrayList([]const u8) = .empty;
    for (argv.tokens) |token| {
        if (inputs.items.len >= max_inputs) break;
        const text = token.value;
        if (!std.mem.startsWith(u8, text, "/") and !std.mem.startsWith(u8, text, "../")) continue;
        const full = try std.Io.Dir.path.resolveAlloc(arena, &.{ cwd, text });
        if (isInside(full, cwd)) continue;
        const size = sandbox_workspace.regularFileSize(full) orelse continue;
        if (size > max_input_bytes) continue;
        try inputs.append(arena, full);
    }
    return inputs.items;
}

/// True when `path` is `dir` or lies below it.
fn isInside(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/';
}

fn systemGetenv(context: *anyopaque, name: []const u8) ?[]const u8 {
    _ = context;
    return io_mod.getenv(name);
}

// ---- tests (run in the full suite) ----

const testing = std.testing;

fn writeText(path: []const u8, text: []const u8) !void {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.createFileAbsolute(zio, path, .{});
    defer file.close(zio);
    try file.writeStreamingAll(zio, text);
}

test "a command that cannot be tokenized names no inputs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dummy: u8 = 0;
    const inputs = try systemNamedInputs(&dummy, arena, "/tmp", "cat \x00 /abs/in.txt");
    try testing.expectEqual(@as(usize, 0), inputs.len);
}

test "named inputs pick outside files that exist and skip the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const zio = io_mod.getIo();
    const mode = std.Io.File.Permissions.fromMode(0o755);
    try tmp.dir.createDir(zio, "work", mode);
    try tmp.dir.createDir(zio, "outside", mode);
    const base = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const cwd = try arena.print("{s}/work", .{base});
    try writeText(try arena.print("{s}/a.txt", .{base}), "a\n");
    try writeText(try arena.print("{s}/outside/in.png", .{base}), "png\n");
    try writeText(try arena.print("{s}/work/in.txt", .{base}), "in\n");
    try std.Io.Dir.createDirAbsolute(zio, try arena.print("{s}/outside/folder", .{base}), mode);

    const command = try arena.print("convert {s}/outside/in.png ../a.txt {s}/work/in.txt {s}/missing.png {s}/outside/folder in.txt", .{ base, base, base, base });
    var dummy: u8 = 0;
    const inputs = try systemNamedInputs(&dummy, arena, cwd, command);
    try testing.expectEqual(@as(usize, 2), inputs.len);
    try testing.expectEqualStrings(try arena.print("{s}/outside/in.png", .{base}), inputs[0]);
    try testing.expectEqualStrings(try arena.print("{s}/a.txt", .{base}), inputs[1]);
}
