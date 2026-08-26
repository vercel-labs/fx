//! User-configured lifecycle hooks executed as bounded local processes.
//!
//! Configuration contracts live in Core. This adapter owns native process
//! execution and registers those contracts with the shared hook runtime.

const std = @import("std");
const builtin = @import("builtin");
const hook_config = @import("../../core/hooks/config.zig");
const hooks = @import("../../core/hooks/hooks.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const max_stdout_bytes: usize = hooks.Limits.arguments_json_bytes + 16 * 1024;
const max_stderr_bytes: usize = 16 * 1024;
const max_input_bytes: usize = 2 * 1024 * 1024;
const poll_interval_ms: i64 = 25;

pub const Runtime = struct {
    alloc: Allocator,
    config: hook_config.Config = .{},
    contexts: []Context = &.{},

    const Context = struct {
        runtime: *Runtime,
        handler: *const hook_config.Handler,
        event: hooks.HookKind,
    };

    pub fn init(alloc: Allocator) Runtime {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.contexts.len > 0) self.alloc.free(self.contexts);
        self.config.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn adopt(self: *Runtime, config: hook_config.Config) void {
        std.debug.assert(self.contexts.len == 0);
        self.config.deinit(self.alloc);
        self.config = config;
    }

    pub fn configure(self: *Runtime, registry: *hooks.Runtime) !void {
        if (comptime !std.process.can_spawn) return;
        std.debug.assert(self.contexts.len == 0);
        const count = self.config.count();
        if (count == 0) return;

        self.contexts = try self.alloc.alloc(Context, count);
        var context_index: usize = 0;
        try self.registerEvent(
            registry,
            .pre_tool_use,
            self.config.pre_tool_use,
            &context_index,
        );
        try self.registerEvent(registry, .stop, self.config.stop, &context_index);
        try self.registerEvent(
            registry,
            .post_turn_end,
            self.config.post_turn_end,
            &context_index,
        );
        try self.registerEvent(
            registry,
            .attention_required,
            self.config.attention_required,
            &context_index,
        );
        std.debug.assert(context_index == count);
    }

    fn registerEvent(
        self: *Runtime,
        registry: *hooks.Runtime,
        event: hooks.HookKind,
        configured: ?[]hook_config.Handler,
        context_index: *usize,
    ) !void {
        const handlers = configured orelse return;
        for (handlers, 0..) |*handler, event_index| {
            const context = &self.contexts[context_index.*];
            context.* = .{
                .runtime = self,
                .handler = handler,
                .event = event,
            };
            context_index.* += 1;

            var name_buffer: [hooks.Limits.handler_name_bytes]u8 = undefined;
            const name = try std.fmt.bufPrint(
                &name_buffer,
                "user.{s}.{s}.{d}",
                .{ @tagName(handler.source), event.definition().lifecycle_event, event_index },
            );
            switch (event) {
                .pre_tool_use => try registry.registerPreToolUse(.{
                    .name = name,
                    .ctx = context,
                    .run = runPreToolUse,
                    .release_action = releasePreToolUse,
                }),
                .stop => try registry.registerStop(.{
                    .name = name,
                    .ctx = context,
                    .run = runStop,
                    .release_action = releaseStop,
                }),
                .post_turn_end => try registry.registerPostTurnEnd(.{
                    .name = name,
                    .ctx = context,
                    .run = runPostTurnEnd,
                }),
                .attention_required => try registry.registerAttentionRequired(.{
                    .name = name,
                    .ctx = context,
                    .run = runAttentionRequired,
                }),
            }
        }
    }
};

fn runPreToolUse(raw: *anyopaque, input: hooks.PreToolUseInput) hooks.HandlerError!hooks.PreToolUseAction {
    const context: *Runtime.Context = @ptrCast(@alignCast(raw));
    const encoded = encodePreToolUse(context.runtime.alloc, input) catch return error.Failed;
    defer context.runtime.alloc.free(encoded);
    const output = runConfigured(context, input.invocation, encoded) catch |err| return mapHandlerError(input.invocation, err);
    defer context.runtime.alloc.free(output);
    return parsePreToolUseAction(context.runtime.alloc, output) catch return error.Failed;
}

fn releasePreToolUse(raw: *anyopaque, action: hooks.PreToolUseAction) void {
    const context: *Runtime.Context = @ptrCast(@alignCast(raw));
    switch (action) {
        .rewrite_arguments => |value| context.runtime.alloc.free(value),
        .block => |value| context.runtime.alloc.free(value),
        .continue_ => {},
    }
}

fn runStop(raw: *anyopaque, input: hooks.StopInput) hooks.HandlerError!hooks.StopAction {
    const context: *Runtime.Context = @ptrCast(@alignCast(raw));
    const encoded = encodeStop(context.runtime.alloc, input) catch return error.Failed;
    defer context.runtime.alloc.free(encoded);
    const output = runConfigured(context, input.invocation, encoded) catch |err| return mapHandlerError(input.invocation, err);
    defer context.runtime.alloc.free(output);
    return parseStopAction(context.runtime.alloc, output) catch return error.Failed;
}

fn releaseStop(raw: *anyopaque, action: hooks.StopAction) void {
    const context: *Runtime.Context = @ptrCast(@alignCast(raw));
    switch (action) {
        .continue_once => |value| context.runtime.alloc.free(value),
        .allow => {},
    }
}

fn runPostTurnEnd(raw: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
    const context: *Runtime.Context = @ptrCast(@alignCast(raw));
    const encoded = encodePostTurnEnd(context.runtime.alloc, input) catch return error.Failed;
    defer context.runtime.alloc.free(encoded);
    const output = runConfigured(context, input.invocation, encoded) catch |err| return mapHandlerError(input.invocation, err);
    context.runtime.alloc.free(output);
}

fn runAttentionRequired(raw: *anyopaque, input: hooks.AttentionRequiredInput) hooks.HandlerError!void {
    const context: *Runtime.Context = @ptrCast(@alignCast(raw));
    const encoded = encodeAttentionRequired(context.runtime.alloc, input) catch return error.Failed;
    defer context.runtime.alloc.free(encoded);
    const output = runConfigured(context, input.invocation, encoded) catch |err| return mapHandlerError(input.invocation, err);
    context.runtime.alloc.free(output);
}

fn mapHandlerError(invocation: hooks.Invocation, err: anyerror) hooks.HandlerError {
    if (err == error.Cancelled or
        (invocation.cancel_flag != null and invocation.cancel_flag.?.load(.acquire)))
    {
        return error.Cancelled;
    }
    return error.Failed;
}

fn runConfigured(
    context: *Runtime.Context,
    invocation: hooks.Invocation,
    input: []const u8,
) ![]u8 {
    if (input.len > max_input_bytes) return error.HookInputTooLarge;
    var environment = try hookEnvironment(context.runtime.alloc, context);
    defer environment.deinit();
    var result = runProcess(
        context.runtime.alloc,
        context.handler.command,
        invocation.scope.workspace_root,
        &environment,
        input,
        context.handler.timeout_ms,
        invocation.cancel_flag,
    ) catch |err| {
        traceProcessFailure(context, err, 0);
        return err;
    };
    defer result.deinit(context.runtime.alloc);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            traceProcessFailure(context, error.HookProcessExitedNonZero, result.stderr.len);
            return error.HookProcessExitedNonZero;
        },
        .signal, .stopped, .unknown => {
            traceProcessFailure(context, error.HookProcessTerminated, result.stderr.len);
            return error.HookProcessTerminated;
        },
    }
    return result.takeStdout();
}

fn traceProcessFailure(context: *const Runtime.Context, err: anyerror, stderr_bytes: usize) void {
    debug_trace.logf(
        "hooks",
        "user hook process failed lifecycle_event={s} source={s} command={s} error={s} stderr_bytes={d}",
        .{
            context.event.definition().lifecycle_event,
            @tagName(context.handler.source),
            context.handler.command[0],
            @errorName(err),
            stderr_bytes,
        },
    );
}

const safe_environment = [_][]const u8{
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
    "TMPDIR",
    "SHELL",
    "TERM",
    "SystemRoot",
    "WINDIR",
    "COMSPEC",
    "PATHEXT",
};

fn hookEnvironment(alloc: Allocator, context: *const Runtime.Context) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(alloc);
    errdefer environment.deinit();
    for (safe_environment) |name| {
        if (io_mod.getenv(name)) |value| try environment.put(name, value);
    }
    for (context.handler.environment) |name| {
        if (io_mod.getenv(name)) |value| try environment.put(name, value);
    }
    try environment.put("FX_HOOK_SCHEMA_VERSION", "1");
    try environment.put("FX_HOOK_EVENT", context.event.definition().lifecycle_event);
    try environment.put("FX_HOOK_CONFIGURATION_SCOPE", @tagName(context.handler.source));
    return environment;
}

const ProcessResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *ProcessResult, alloc: Allocator) void {
        if (self.stdout.len > 0) alloc.free(self.stdout);
        if (self.stderr.len > 0) alloc.free(self.stderr);
        self.* = undefined;
    }

    fn takeStdout(self: *ProcessResult) []u8 {
        const value = self.stdout;
        self.stdout = &.{};
        return value;
    }
};

fn runProcess(
    alloc: Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    environment: *const std.process.Environ.Map,
    input: []const u8,
    timeout_ms: u32,
    cancel_flag: ?*const std.atomic.Value(bool),
) !ProcessResult {
    if (comptime !std.process.can_spawn) return error.OperationUnsupported;
    const io = io_mod.getIo();
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = environment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) null else 0,
        .create_no_window = true,
    });
    const process_group_id = if (builtin.os.tag == .windows or builtin.os.tag == .wasi)
        null
    else
        child.id;
    defer terminateHookProcess(&child, process_group_id);

    const child_input = child.stdin orelse return error.HookProcessPipeUnavailable;
    child.stdin = null;
    try writeProcessInput(
        &child,
        process_group_id,
        child_input,
        input,
        deadline,
        cancel_flag,
    );

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (true) {
        try checkProcessBudget(deadline, cancel_flag);
        var finished = false;
        multi_reader.fill(4096, .{
            .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(poll_interval_ms),
            },
        }) catch |err| switch (err) {
            error.Timeout => {},
            error.EndOfStream => finished = true,
            else => |read_err| return read_err,
        };
        if (stdout_reader.buffered().len > max_stdout_bytes or
            stderr_reader.buffered().len > max_stderr_bytes)
        {
            return error.HookOutputTooLarge;
        }
        if (finished) break;
    }
    try multi_reader.checkAnyError();
    const term = try waitForProcess(&child, deadline, cancel_flag);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer alloc.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

const InputEvent = union(enum) {
    written: anyerror!void,
    timeout: anyerror!void,
    cancelled: anyerror!void,
};

fn writeInput(file: std.Io.File, input: []const u8) anyerror!void {
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), input);
}

fn waitUntil(deadline: std.Io.Clock.Timestamp) anyerror!void {
    return std.Io.Timeout.sleep(.{ .deadline = deadline }, io_mod.getIo());
}

fn waitForCancellation(cancel_flag: *const std.atomic.Value(bool)) anyerror!void {
    while (!cancel_flag.load(.acquire)) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn writeProcessInput(
    child: *std.process.Child,
    process_group_id: ?std.posix.pid_t,
    file: std.Io.File,
    input: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*const std.atomic.Value(bool),
) !void {
    var event_buffer: [3]InputEvent = undefined;
    var select: std.Io.Select(InputEvent) = .init(io_mod.getIo(), &event_buffer);
    try select.concurrent(.written, writeInput, .{ file, input });
    select.concurrent(.timeout, waitUntil, .{deadline}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    if (cancel_flag) |flag| {
        select.concurrent(.cancelled, waitForCancellation, .{flag}) catch |err| {
            select.cancelDiscard();
            return err;
        };
    }
    const event = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    return switch (event) {
        .written => |result| blk: {
            select.cancelDiscard();
            break :blk result;
        },
        .timeout => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            terminateHookProcess(child, process_group_id);
            select.cancelDiscard();
            return error.TimedOut;
        },
        .cancelled => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            terminateHookProcess(child, process_group_id);
            select.cancelDiscard();
            return error.Cancelled;
        },
    };
}

fn terminateHookProcess(
    child: *std.process.Child,
    process_group_id: ?std.posix.pid_t,
) void {
    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (process_group_id) |pid| {
            std.posix.kill(-pid, std.posix.SIG.KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => debug_trace.logf(
                    "hooks",
                    "user hook process-group cleanup failed error={s}",
                    .{@errorName(err)},
                ),
            };
        }
    }
    child.kill(io_mod.getIo());
}

const WaitEvent = union(enum) {
    process: anyerror!std.process.Child.Term,
    timeout: anyerror!void,
    cancelled: anyerror!void,
};

fn waitForChild(child: *std.process.Child) anyerror!std.process.Child.Term {
    return child.wait(io_mod.getIo());
}

fn waitForProcess(
    child: *std.process.Child,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*const std.atomic.Value(bool),
) !std.process.Child.Term {
    var event_buffer: [3]WaitEvent = undefined;
    var select: std.Io.Select(WaitEvent) = .init(io_mod.getIo(), &event_buffer);
    try select.concurrent(.process, waitForChild, .{child});
    select.concurrent(.timeout, waitUntil, .{deadline}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    if (cancel_flag) |flag| {
        select.concurrent(.cancelled, waitForCancellation, .{flag}) catch |err| {
            select.cancelDiscard();
            return err;
        };
    }
    const event = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    return switch (event) {
        .process => |result| blk: {
            select.cancelDiscard();
            break :blk result;
        },
        .timeout => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            select.cancelDiscard();
            return error.TimedOut;
        },
        .cancelled => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            select.cancelDiscard();
            return error.Cancelled;
        },
    };
}

fn checkProcessBudget(
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*const std.atomic.Value(bool),
) !void {
    if (cancel_flag) |flag| {
        if (flag.load(.acquire)) return error.Cancelled;
    }
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) return error.TimedOut;
}

fn encodePreToolUse(alloc: Allocator, input: hooks.PreToolUseInput) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeEnvelopeStart(&out.writer, .pre_tool_use, input.invocation);
    try out.writer.writeAll("{\"step_index\":");
    try out.writer.print("{d}", .{input.step_index});
    try out.writer.writeAll(",\"call_id\":");
    try writeJsonString(&out.writer, input.call_id);
    try out.writer.writeAll(",\"tool_name\":");
    try writeJsonString(&out.writer, input.tool_name);
    try out.writer.writeAll(",\"arguments\":");
    try out.writer.writeAll(input.arguments_json);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn encodeStop(alloc: Allocator, input: hooks.StopInput) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeEnvelopeStart(&out.writer, .stop, input.invocation);
    try out.writer.writeAll("{\"step_index\":");
    try out.writer.print("{d}", .{input.step_index});
    try out.writer.writeAll(",\"assistant_text\":");
    try writeJsonString(&out.writer, input.assistant_text);
    try out.writer.writeAll(",\"provider_disposition\":");
    try writeJsonString(&out.writer, @tagName(input.provider_disposition));
    try out.writer.print(",\"can_continue\":{s}", .{if (input.can_continue) "true" else "false"});
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn encodePostTurnEnd(alloc: Allocator, input: hooks.PostTurnEndInput) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeEnvelopeStart(&out.writer, .post_turn_end, input.invocation);
    try out.writer.writeAll("{\"outcome\":");
    try writeJsonString(&out.writer, @tagName(input.outcome));
    try out.writer.writeAll(",\"provider_disposition\":");
    if (input.provider_disposition) |disposition| {
        try writeJsonString(&out.writer, @tagName(disposition));
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn encodeAttentionRequired(alloc: Allocator, input: hooks.AttentionRequiredInput) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeEnvelopeStart(&out.writer, .attention_required, input.invocation);
    try out.writer.writeAll("{\"kind\":");
    try writeJsonString(&out.writer, @tagName(input.kind));
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn writeEnvelopeStart(
    writer: *std.Io.Writer,
    event: hooks.HookKind,
    invocation: hooks.Invocation,
) !void {
    try writer.writeAll("{\"schema_version\":");
    try writer.print("{d}", .{hook_config.schema_version});
    try writer.writeAll(",\"event\":");
    try writeJsonString(writer, event.definition().lifecycle_event);
    try writer.writeAll(",\"invocation\":{\"scope\":");
    try writeJsonString(writer, @tagName(invocation.scope.kind));
    try writer.writeAll(",\"workspace_root\":");
    try writeJsonString(writer, invocation.scope.workspace_root);
    try writer.writeAll(",\"session_id\":");
    try writeOptionalJsonString(writer, invocation.scope.session_id);
    try writer.writeAll(",\"subagent_id\":");
    if (invocation.scope.subagent_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
    try writer.writeAll(",\"turn_id\":");
    if (invocation.turn_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
    try writer.writeAll("},\"payload\":");
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeOptionalJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |present| try writeJsonString(writer, present) else try writer.writeAll("null");
}

fn parsePreToolUseAction(alloc: Allocator, bytes: []const u8) !hooks.PreToolUseAction {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHookResponse;
    const action_value = parsed.value.object.get("action") orelse return error.InvalidHookResponse;
    if (action_value != .string) return error.InvalidHookResponse;
    if (std.mem.eql(u8, action_value.string, "continue")) return .continue_;
    if (std.mem.eql(u8, action_value.string, "block")) {
        const reason = parsed.value.object.get("reason") orelse return error.InvalidHookResponse;
        if (reason != .string) return error.InvalidHookResponse;
        return .{ .block = try alloc.dupe(u8, reason.string) };
    }
    if (std.mem.eql(u8, action_value.string, "rewrite")) {
        const arguments = parsed.value.object.get("arguments") orelse return error.InvalidHookResponse;
        if (arguments != .object) return error.InvalidHookResponse;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(arguments, .{}, &out.writer);
        return .{ .rewrite_arguments = try out.toOwnedSlice() };
    }
    return error.InvalidHookResponse;
}

fn parseStopAction(alloc: Allocator, bytes: []const u8) !hooks.StopAction {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHookResponse;
    const action_value = parsed.value.object.get("action") orelse return error.InvalidHookResponse;
    if (action_value != .string) return error.InvalidHookResponse;
    if (std.mem.eql(u8, action_value.string, "allow")) return .allow;
    if (std.mem.eql(u8, action_value.string, "continue")) {
        const context = parsed.value.object.get("context") orelse return error.InvalidHookResponse;
        if (context != .string) return error.InvalidHookResponse;
        return .{ .continue_once = try alloc.dupe(u8, context.string) };
    }
    return error.InvalidHookResponse;
}

test "user hook payloads expose versioned structured event data without internal cancellation" {
    var cancel = std.atomic.Value(bool).init(false);
    const invocation = hooks.Invocation{
        .scope = .{
            .kind = .subagent,
            .workspace_root = "/tmp/workspace",
            .session_id = "session",
            .subagent_id = 7,
        },
        .turn_id = 42,
        .cancel_flag = &cancel,
    };
    const encoded = try encodePreToolUse(std.testing.allocator, .{
        .invocation = invocation,
        .step_index = 3,
        .call_id = "call-1",
        .tool_name = "terminal",
        .arguments_json = "{\"command\":\"pwd\"}",
    });
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("PreToolUse", parsed.value.object.get("event").?.string);
    const invocation_json = parsed.value.object.get("invocation").?.object;
    try std.testing.expectEqualStrings("subagent", invocation_json.get("scope").?.string);
    try std.testing.expect(invocation_json.get("cancel_flag") == null);
    const payload = parsed.value.object.get("payload").?.object;
    try std.testing.expectEqualStrings("pwd", payload.get("arguments").?.object.get("command").?.string);
}

test "user hook response actions parse structured rewrites and continuations" {
    const rewrite = try parsePreToolUseAction(
        std.testing.allocator,
        "{\"action\":\"rewrite\",\"arguments\":{\"path\":\"README.md\"}}",
    );
    defer releasePreToolUseForTest(std.testing.allocator, rewrite);
    try std.testing.expect(rewrite == .rewrite_arguments);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", rewrite.rewrite_arguments);

    const continuation = try parseStopAction(
        std.testing.allocator,
        "{\"action\":\"continue\",\"context\":\"run tests\"}",
    );
    defer releaseStopForTest(std.testing.allocator, continuation);
    try std.testing.expect(continuation == .continue_once);
    try std.testing.expectEqualStrings("run tests", continuation.continue_once);
}

fn releasePreToolUseForTest(alloc: Allocator, action: hooks.PreToolUseAction) void {
    switch (action) {
        .rewrite_arguments, .block => |value| alloc.free(value),
        .continue_ => {},
    }
}

fn releaseStopForTest(alloc: Allocator, action: hooks.StopAction) void {
    switch (action) {
        .continue_once => |value| alloc.free(value),
        .allow => {},
    }
}

test "configured hook process receives JSON through stdin with a scrubbed environment" {
    if (builtin.os.tag == .windows or !std.process.can_spawn) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "read payload; printf '%s' \"$payload\"; printf '%s' \"${FX_SECRET_SHOULD_NOT_LEAK-unset}\" >&2",
    };
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    const result_value = try runProcess(
        alloc,
        &argv,
        "/tmp",
        &environment,
        "{\"event\":\"test\"}\n",
        1_000,
        null,
    );
    var result = result_value;
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("{\"event\":\"test\"}", result.stdout);
    try std.testing.expectEqualStrings("unset", result.stderr);
}

test "configured hook process timeout is bounded" {
    if (builtin.os.tag == .windows or !std.process.can_spawn) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expectError(error.TimedOut, runProcess(
        std.testing.allocator,
        &.{ "/bin/sh", "-c", "sleep 2" },
        "/tmp",
        &environment,
        "{}\n",
        25,
        null,
    ));
}

test "configured hook process observes turn cancellation" {
    if (builtin.os.tag == .windows or !std.process.can_spawn) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, runProcess(
        std.testing.allocator,
        &.{ "/bin/sh", "-c", "sleep 2" },
        "/tmp",
        &environment,
        "{}\n",
        1_000,
        &cancel,
    ));
}

test "configured process handlers compose through the core lifecycle runtime" {
    if (builtin.os.tag == .windows or !std.process.can_spawn) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{
        \\  "PreToolUse": [{
        \\    "command": ["/bin/sh", "-c", "cat >/dev/null; printf '%s' '{\"action\":\"rewrite\",\"arguments\":{\"wrapped\":true}}'"]
        \\  }],
        \\  "Stop": [{
        \\    "command": ["/bin/sh", "-c", "cat >/dev/null; printf '%s' '{\"action\":\"continue\",\"context\":\"verify integration\"}'"]
        \\  }]
        \\}
    ,
        .{},
    );
    defer parsed_json.deinit();
    var config = try hook_config.parse(alloc, parsed_json.value);
    var user_runtime = Runtime.init(alloc);
    defer user_runtime.deinit();
    user_runtime.adopt(config);
    config = .{};

    var registry = hooks.Runtime.init(alloc);
    defer registry.deinit();
    try user_runtime.configure(&registry);
    const view = registry.freeze();
    const invocation = hooks.Invocation{
        .scope = .{
            .kind = .ask,
            .workspace_root = "/tmp",
            .session_id = "session",
        },
        .turn_id = 9,
    };

    var pre = try view.runPreToolUse(alloc, .{
        .invocation = invocation,
        .step_index = 1,
        .call_id = "call",
        .tool_name = "terminal",
        .arguments_json = "{}",
    });
    defer pre.deinit(alloc);
    try std.testing.expect(pre == .rewritten);
    try std.testing.expectEqualStrings("{\"wrapped\":true}", pre.rewritten);

    var stop = view.runStop(alloc, .{
        .invocation = invocation,
        .step_index = 2,
        .assistant_text = "done",
        .provider_disposition = .completed,
        .can_continue = true,
    });
    defer stop.deinit(alloc);
    try std.testing.expect(stop == .continue_once);
    try std.testing.expectEqualStrings("verify integration", stop.continue_once);
}
