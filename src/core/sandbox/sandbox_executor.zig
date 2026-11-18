//! The router's sandbox executor. It runs a sandbox-placed command through the
//! sandbox runtime and relays the live output the way the local runner does.
const std = @import("std");
const api = @import("api.zig");
const command_runner = @import("../execution/command_runner.zig");
const io_mod = @import("../shared/io.zig");
const report_text = @import("report_text.zig");
const result = @import("result.zig");
const run_exec = @import("executor.zig");
const runtime = @import("runtime.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

/// The router's sandbox executor, backed by `rt`.
pub fn executor(rt: *runtime.Runtime) command_runner.SandboxExecutor {
    return .{ .context = rt, .execute = execute };
}

/// The read tool's sandbox reader, backed by `rt`.
pub fn reader(rt: *runtime.Runtime) tool_dispatch.SandboxReader {
    return .{ .context = rt, .read = readFile };
}

fn readFile(context: *anyopaque, arena: Allocator, path: []const u8, max_bytes: usize) anyerror!?[]const u8 {
    const rt: *runtime.Runtime = @ptrCast(@alignCast(context));
    return rt.readSandboxFile(arena, path, max_bytes);
}

fn execute(
    context: *anyopaque,
    cfg: command_runner.Config,
    alloc: Allocator,
    command: command_runner.SandboxCommand,
) anyerror!command_runner.CommandExecutionResult {
    const rt: *runtime.Runtime = @ptrCast(@alignCast(context));
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var relay: Relay = .{ .cfg = cfg };
    const report = try rt.run(arena, .{
        .command = command.command,
        .cwd = command.cwd,
        .placement = command.placement,
        .profile = command.profile,
    }, controlsFor(cfg), .{ .context = &relay, .on_line = Relay.onLine });
    // The notes follow the command's own output, through the same callbacks, as stderr.
    const notes = try report_text.noteLines(arena, report);
    if (notes.len > 0) try relay.deliver(.stderr, notes);
    return result.toRunCommandResult(alloc, report, command.command, command.cwd);
}

/// The executor's controls for one command, from the router's config.
fn controlsFor(cfg: command_runner.Config) run_exec.Controls {
    return .{
        .cancel_flag = cfg.cancel_flag,
        .force_cancel_flag = cfg.force_cancel_flag,
        .deadline_ms = deadlineFor(cfg),
        .max_output_bytes = cfg.max_command_output_bytes,
    };
}

/// The wall-clock time the command must stop, or null when it has no timeout.
fn deadlineFor(cfg: command_runner.Config) ?i64 {
    const timeout = cfg.timeout_ms orelse return null;
    const started = cfg.timeout_started_ms orelse io_mod.milliTimestamp();
    return started + @as(i64, @intCast(timeout));
}

/// Passes output to the router's callbacks. The accepted callback gets every
/// chunk as it arrived. The projected callback gets a chunk only when it is
/// model-safe, unless the projection is raw.
const Relay = struct {
    cfg: command_runner.Config,

    fn onLine(context: *anyopaque, stream: api.Stream, line: []const u8) anyerror!void {
        if (line.len == 0) return;
        const relay: *Relay = @ptrCast(@alignCast(context));
        const kind: command_runner.CommandOutputStream = switch (stream) {
            .stdout => .stdout,
            .stderr => .stderr,
        };
        try relay.deliver(kind, line);
    }

    fn deliver(self: *Relay, kind: command_runner.CommandOutputStream, chunk: []const u8) anyerror!void {
        const cfg = self.cfg;
        if (cfg.on_accepted_output_chunk) |callback| {
            if (cfg.accepted_output_chunk_ctx) |ctx| {
                try callback(ctx, cfg.output_chunk_lifecycle_id, kind, chunk);
            }
        }
        if (cfg.on_output_chunk) |callback| {
            if (cfg.output_chunk_ctx) |ctx| {
                if (cfg.callback_projection == .raw or text_utils.isModelSafeText(chunk)) {
                    try callback(ctx, cfg.output_chunk_lifecycle_id, kind, chunk);
                }
            }
        }
    }
};

// ---- tests (run in the full suite) ----

const testing = std.testing;
const client_mod = @import("client.zig");
const credentials = @import("credentials.zig");
const types = @import("../shared/types.zig");
const test_sandbox = @import("test_sandbox.zig");
const FakeSandbox = test_sandbox.FakeSandbox;

/// Counts the chunks each callback receives, and how many of them are notes.
const Recorder = struct {
    accepted_lines: usize = 0,
    projected_lines: usize = 0,
    accepted_notes: usize = 0,
    projected_notes: usize = 0,

    fn accepted(context: *anyopaque, lifecycle_id: ?types.ToolLifecycleId, stream: command_runner.CommandOutputStream, chunk: []const u8) anyerror!void {
        _ = lifecycle_id;
        _ = stream;
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.accepted_lines += 1;
        if (std.mem.startsWith(u8, chunk, "fx: ")) self.accepted_notes += 1;
    }

    fn projected(context: *anyopaque, lifecycle_id: ?types.ToolLifecycleId, stream: command_runner.CommandOutputStream, chunk: []const u8) anyerror!void {
        _ = lifecycle_id;
        _ = stream;
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.projected_lines += 1;
        if (std.mem.startsWith(u8, chunk, "fx: ")) self.projected_notes += 1;
    }
};

const TestHooks = struct {
    fn token(context: *anyopaque, arena: Allocator) credentials.Error![]const u8 {
        _ = context;
        _ = arena;
        return "test-token";
    }

    fn listFiles(context: *anyopaque, arena: Allocator, cwd: []const u8, problem: *[]const u8) anyerror!?[]const []const u8 {
        _ = context;
        _ = arena;
        _ = cwd;
        _ = problem;
        return &.{};
    }

    fn namedInputs(context: *anyopaque, arena: Allocator, cwd: []const u8, command: []const u8) anyerror![]const []const u8 {
        _ = context;
        _ = arena;
        _ = cwd;
        _ = command;
        return &.{};
    }

    fn getenv(context: *anyopaque, name: []const u8) ?[]const u8 {
        _ = context;
        _ = name;
        return null;
    }
};

test "the callbacks get the command's lines, then its notes once each" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!test_sandbox.toolsAvailable(arena)) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const zio = io_mod.getIo();
    try tmp.dir.createDir(zio, "state", std.Io.File.Permissions.fromMode(0o755));
    try tmp.dir.createDir(zio, "disk", std.Io.File.Permissions.fromMode(0o755));
    try tmp.dir.createDir(zio, "work", std.Io.File.Permissions.fromMode(0o755));
    const base = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const state = try arena.print("{s}/state", .{base});
    const disk = try arena.print("{s}/disk", .{base});
    const work = try arena.print("{s}/work", .{base});
    const config_text = try arena.print("{{\"team\":\"team\",\"project\":\"project\",\"api_url\":\"https://sandbox.test\",\"remote_root\":\"{s}\"}}", .{disk});
    {
        var file = try std.Io.Dir.createFileAbsolute(zio, try arena.print("{s}/config.json", .{state}), .{});
        defer file.close(zio);
        try file.writeStreamingAll(zio, config_text);
    }

    var fake: FakeSandbox = .{ .disk = disk };
    const transport: client_mod.Transport = .{ .context = &fake, .send = FakeSandbox.send };
    const hooks: runtime.Hooks = .{
        .context = &fake,
        .token = TestHooks.token,
        .list_files = TestHooks.listFiles,
        .named_inputs = TestHooks.namedInputs,
        .getenv = TestHooks.getenv,
        .transport = transport,
    };
    const rt = try runtime.Runtime.create(testing.allocator, state, "tester", "host.test", 7, hooks);
    defer rt.destroy();

    var recorder: Recorder = .{};
    const cfg: command_runner.Config = .{
        .max_command_output_bytes = 1 << 20,
        .accepted_output_chunk_ctx = &recorder,
        .on_accepted_output_chunk = Recorder.accepted,
        .output_chunk_ctx = &recorder,
        .on_output_chunk = Recorder.projected,
    };
    const exec = executor(rt);
    const command_result = try exec.execute(exec.context, cfg, testing.allocator, .{
        .command = "printf 'ok\\n'; printf 'bad\\0line\\n'",
        .cwd = work,
        .placement = .isolated,
    });
    defer testing.allocator.free(command_result.output);
    // Two output lines, then one notes chunk. The NUL line is skipped by the projected callback only.
    try testing.expectEqual(@as(usize, 3), recorder.accepted_lines);
    try testing.expectEqual(@as(usize, 2), recorder.projected_lines);
    try testing.expectEqual(@as(usize, 1), recorder.accepted_notes);
    try testing.expectEqual(@as(usize, 1), recorder.projected_notes);
}
