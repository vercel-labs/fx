//! The `monitor` tool: start a command whose output reaches the agent as
//! messages, list the agent's monitors, and stop one. A monitor is the shell
//! tool's captured command, started with `yield_time_ms` 0, so the same
//! permission rules, sandbox runner, and process cleanup apply to it. The
//! app's loop reads each monitor's output and posts the events
//! (`src/core/app/app_monitor_runtime.zig`).

const std = @import("std");
const monitor = @import("../../core/monitor/monitor.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const shell_impl = @import("../shell/shell.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum { start, list, stop };

/// The longest label, in bytes. A label defaults to the start of the command.
const max_label_bytes: usize = 48;

pub const Input = struct {
    action: Action,
    command: []u8 = &.{},
    label: []u8 = &.{},
    id: []u8 = &.{},

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.command);
        alloc.free(self.label);
        alloc.free(self.id);
        self.* = undefined;
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var decoder: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = "monitor" };
    var parsed = decoder.parse(args_json) catch |err| return .{ .failure = try decoder.takeFailure(err) };
    defer parsed.deinit();
    const args = parsed.value.object;
    const action_text = decoder.requiredString(args, "action") catch |err| return .{ .failure = try decoder.takeFailure(err) };
    const action = std.meta.stringToEnum(Action, action_text) orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "monitor field \"action\" must be start, list, or stop") };
    const command = (decoder.optionalString(args, "command") catch |err| return .{ .failure = try decoder.takeFailure(err) }) orelse "";
    const label = (decoder.optionalString(args, "label") catch |err| return .{ .failure = try decoder.takeFailure(err) }) orelse "";
    const id = (decoder.optionalString(args, "id") catch |err| return .{ .failure = try decoder.takeFailure(err) }) orelse "";
    switch (action) {
        .start => if (std.mem.trim(u8, command, " \t\r\n").len == 0)
            return .{ .failure = try ctx.allocator.dupe(u8, "monitor start requires a command") }
        else if (command.len > monitor.saved.max_command_bytes)
            // A restart note holds the whole command, so a longer one belongs in a script.
            return .{ .failure = try ctx.allocator.print("monitor command is longer than {d} bytes: put it in a script and run that", .{monitor.saved.max_command_bytes}) },
        .stop => if (id.len == 0)
            return .{ .failure = try ctx.allocator.dupe(u8, "monitor stop requires the id that start returned") },
        .list => {},
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .action = action };
    errdefer input.deinit(ctx.allocator);
    input.command = try ctx.allocator.dupe(u8, command);
    input.label = try cleanLabel(ctx.allocator, if (label.len > 0) label else command);
    input.id = try ctx.allocator.dupe(u8, id);
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

/// One terminal-safe line of at most `max_label_bytes`.
fn cleanLabel(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var encoded = try text_utils.encodeTerminalSafeInline(alloc, raw, max_label_bytes);
    defer encoded.deinit(alloc);
    return alloc.dupe(u8, encoded.bytes);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const registry = ctx.monitors orelse return .{
        .failure = try ctx.allocator.dupe(u8, "monitor is not available here: only the terminal UI's main agent runs monitors."),
    };
    return switch (input.action) {
        .start => callStart(ctx, registry, input),
        .list => .{ .success = try registry.listText(ctx.allocator) },
        .stop => callStop(ctx, registry, input),
    };
}

fn callStart(ctx: tool_dispatch.DispatchContext, registry: *monitor.Registry, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (registry.count() >= monitor.max_monitors) return .{
        .failure = try ctx.allocator.print("monitor limit reached: {d} monitors run. Stop one first.", .{monitor.max_monitors}),
    };
    // A monitor is a shell run that returns at once and keeps running, so a
    // cancel of this turn leaves it running (`shell.zig` `withoutSteeringYield`).
    const shell_args = try shellArguments(ctx.allocator, .{ .action = "run", .command = input.command, .yield_time_ms = 0 });
    defer ctx.allocator.free(shell_args);
    // A monitor's output is read once a second, so its command may print more
    // between two reads than a shell run keeps.
    var start_ctx = ctx;
    start_ctx.max_command_output_bytes = monitor.max_unread_output_bytes;
    const started = try runShell(start_ctx, shell_args);
    switch (started) {
        .failure => return started,
        .rich => return started,
        .success => |body| {
            defer ctx.allocator.free(body);
            const id = sessionId(ctx.allocator, body) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NoSessionId => return .{ .failure = try ctx.allocator.dupe(u8, "monitor could not start: the command ended at once. Run it with the shell tool to see why.") },
            };
            defer ctx.allocator.free(id);
            registry.add(id, input.label, input.command) catch |err| {
                stopQuietly(ctx, id);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.TooManyMonitors => .{ .failure = try ctx.allocator.print("monitor limit reached: {d} monitors run.", .{monitor.max_monitors}) },
                };
            };
            debug_trace.logf("monitor", "event=start id={s} command_bytes={d}", .{ id, input.command.len });
            return .{ .success = try ctx.allocator.print(
                "Monitor {s} ({s}) started. Its output arrives as messages from it, at most one every {d} seconds. While you are busy or blocked on a prompt, the newest {d} wait and older ones are dropped, so read the file each message names with read_file for everything it printed: the newest 4 to 8 MiB. Stop it with action=stop and id={s}.",
                .{ id, input.label, @divTrunc(monitor.event.min_gap_ms, 1000), monitor.event.max_held, id },
            ) };
        },
    }
}

fn callStop(ctx: tool_dispatch.DispatchContext, registry: *monitor.Registry, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const shell_args = try shellArguments(ctx.allocator, .{ .action = "stop", .session_id = input.id });
    defer ctx.allocator.free(shell_args);
    // Out of the registry first, so the stop sends no end event: this call
    // is its answer. A stop that fails puts the monitor back.
    const kept = registry.removeKeeping(input.id) orelse return .{
        .failure = try ctx.allocator.print("No monitor has id {s}. Use action=list to see them.", .{input.id}),
    };
    const stopped = runShell(ctx, shell_args) catch |err| {
        registry.restore(input.id, kept);
        return err;
    };
    switch (stopped) {
        .success => |body| {
            ctx.allocator.free(body);
            registry.freeCopy(kept);
            debug_trace.logf("monitor", "event=stop id={s} reason=agent_stop", .{input.id});
            return .{ .success = try ctx.allocator.print("Monitor {s} stopped.", .{input.id}) };
        },
        .failure, .rich => {
            // The stop kills the command before it reads the result, so a
            // read the loop held at that moment can fail it. A command that
            // no longer runs is stopped.
            if (stillRunning(ctx, input.id)) {
                registry.restore(input.id, kept);
                return stopped;
            }
            stopped.deinit(ctx.allocator);
            registry.freeCopy(kept);
            debug_trace.logf("monitor", "event=stop id={s} reason=agent_stop", .{input.id});
            return .{ .success = try ctx.allocator.print("Monitor {s} stopped.", .{input.id}) };
        },
    }
}

fn stillRunning(ctx: tool_dispatch.DispatchContext, id: []const u8) bool {
    const runtime = ctx.managed_executions orelse return true;
    const state = runtime.stateFor(id) orelse return false;
    return state == .running;
}

/// Stops a command the monitor could not register, so none runs unlisted.
fn stopQuietly(ctx: tool_dispatch.DispatchContext, id: []const u8) void {
    const shell_args = shellArguments(ctx.allocator, .{ .action = "stop", .session_id = id, .force = true }) catch return;
    defer ctx.allocator.free(shell_args);
    const result = runShell(ctx, shell_args) catch return;
    result.deinit(ctx.allocator);
}

fn runShell(ctx: tool_dispatch.DispatchContext, shell_args: []const u8) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    switch (try shell_impl.decode(ctx, shell_args)) {
        .failure => |text| return .{ .failure = text },
        .input => |shell_input| {
            defer shell_input.deinit(ctx.allocator);
            return shell_impl.call(ctx, shell_input);
        },
    }
}

fn shellArguments(alloc: Allocator, value: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The `session_id` a shell result names, owned. A result without one means
/// the command had ended and left nothing to monitor.
fn sessionId(alloc: Allocator, body: []const u8) error{ OutOfMemory, NoSessionId }![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NoSessionId,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.NoSessionId;
    const id = parsed.value.object.get("session_id") orelse return error.NoSessionId;
    if (id != .string or id.string.len == 0) return error.NoSessionId;
    return alloc.dupe(u8, id.string);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn isCapturedCommand(erased: tool_dispatch.ToolInput) bool {
    return erased.as(Input).action == .start;
}

pub fn isProcessLocal(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return erased.as(Input).action == .list;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const action = std.meta.stringToEnum(Action, tool_args.optionalStringArg(args, "action") orelse return null) orelse return null;
    return switch (action) {
        .start => .{
            .activity_kind = .command,
            .action_label = "Starting monitor",
            .completed_action_label = "Started monitor",
            .label_arg_kind = .command,
            .label_arg_default = "command",
        },
        .list => .{
            .activity_kind = .command,
            .action_label = "Listing",
            .completed_action_label = "Listed",
            .label_arg_kind = .action,
            .label_arg_default = "monitors",
        },
        .stop => .{
            .activity_kind = .command,
            .action_label = "Stopping monitor",
            .completed_action_label = "Stopped monitor",
            .label_arg_kind = .session_id,
            .label_arg_default = "monitor",
        },
    };
}

fn testDecode(args: []const u8) !tool_dispatch.ToolInput {
    return switch (try decode(.{ .allocator = std.testing.allocator }, args)) {
        .input => |input| input,
        .failure => |text| {
            std.testing.allocator.free(text);
            return error.TestExpectedInput;
        },
    };
}

fn expectRefused(args: []const u8, needle: []const u8) !void {
    switch (try decode(.{ .allocator = std.testing.allocator }, args)) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedFailure;
        },
        .failure => |text| {
            defer std.testing.allocator.free(text);
            try std.testing.expect(std.mem.find(u8, text, needle) != null);
        },
    }
}

test "start reads its command and label, and a missing label is the command" {
    const input = try testDecode("{\"action\":\"start\",\"command\":\"gh pr checks 9 --watch\",\"label\":\"ci\"}");
    defer input.deinit(std.testing.allocator);
    try std.testing.expectEqual(Action.start, input.as(Input).action);
    try std.testing.expectEqualStrings("ci", input.as(Input).label);
    try std.testing.expect(isCapturedCommand(input));
    const plain = try testDecode("{\"action\":\"start\",\"command\":\"tail -f build.log\"}");
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("tail -f build.log", plain.as(Input).label);
}

test "a long label is cut and a control byte in it never survives" {
    const input = try testDecode("{\"action\":\"start\",\"command\":\"x\",\"label\":\"a\\u001b[31mred \\n and a very long tail that goes past the label limit by a lot\"}");
    defer input.deinit(std.testing.allocator);
    const label = input.as(Input).label;
    try std.testing.expect(label.len <= max_label_bytes);
    try std.testing.expect(std.mem.findScalar(u8, label, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, label, '\n') == null);
}

test "a command too long for the restart record is refused" {
    const long = text_utils.repeat("x", 4097);
    try expectRefused("{\"action\":\"start\",\"command\":\"" ++ long ++ "\"}", "put it in a script");
}

test "start and stop name what they need, and list needs nothing" {
    try expectRefused("{\"action\":\"start\"}", "requires a command");
    try expectRefused("{\"action\":\"start\",\"command\":\"  \"}", "requires a command");
    try expectRefused("{\"action\":\"stop\"}", "requires the id");
    try expectRefused("{\"action\":\"watch\"}", "start, list, or stop");
    try expectRefused("[]", "must be an object");
    const list = try testDecode("{\"action\":\"list\"}");
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(readsOnly(list));
    try std.testing.expect(!isCapturedCommand(list));
}

test "a monitor without a registry says where it works" {
    const input = try testDecode("{\"action\":\"list\"}");
    defer input.deinit(std.testing.allocator);
    const result = try call(.{ .allocator = std.testing.allocator }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .failure);
    try std.testing.expect(std.mem.find(u8, result.failure, "not available here") != null);
}

test "list and stop work on the registry, and stop of an unknown id fails" {
    var registry: monitor.Registry = .{ .alloc = std.testing.allocator };
    defer registry.deinit();
    try registry.add("shell-7", "ci", "gh pr checks 1 --watch");
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = std.testing.allocator, .monitors = &registry };
    const list = try testDecode("{\"action\":\"list\"}");
    defer list.deinit(std.testing.allocator);
    const listed = try call(ctx, list);
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("shell-7\tci\tgh pr checks 1 --watch\n", listed.success);
    const stop = try testDecode("{\"action\":\"stop\",\"id\":\"shell-9\"}");
    defer stop.deinit(std.testing.allocator);
    const refused = try call(ctx, stop);
    defer refused.deinit(std.testing.allocator);
    try std.testing.expect(refused == .failure);
    try std.testing.expect(registry.contains("shell-7"));
}

test "the session id comes from a running shell result" {
    const id = try sessionId(std.testing.allocator, "{\"session_id\":\"shell-3\",\"state\":\"running\"}");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("shell-3", id);
    try std.testing.expectError(error.NoSessionId, sessionId(std.testing.allocator, "{\"state\":\"completed\"}"));
    try std.testing.expectError(error.NoSessionId, sessionId(std.testing.allocator, "not json"));
}
