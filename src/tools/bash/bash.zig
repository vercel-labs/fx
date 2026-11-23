//! The bash tool: its arguments, their validation, the predicates the permission
//! gate reads, the text the model sees, and the calls that run a program or wait
//! for the running one. The tool spec is in src/builtins/bash_tools.zig.
const std = @import("std");
const bash_session = @import("../../core/bash_session/bash_session.zig");
const managed_execution = @import("../../core/execution/managed_execution.zig");
const mem_utils = @import("../../core/shared/mem_utils.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const builtin = @import("builtin");
const command_admission = @import("../../core/permissions/command_admission.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");
const managed_contract = @import("../../core/execution/managed_execution_contract.zig");
const managed_delivery = @import("../../core/tooling/managed_delivery.zig");
const mcp_call_bridge = @import("../../core/mcp_host/mcp_call_bridge.zig");
const shell_resolver = @import("../../core/terminal/shell_resolver.zig");
const terminal_contracts = @import("../../core/terminal/contracts.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

/// The output is kept whole only while it plus this many bytes fits in
/// `max_bytes`. The reserve holds the status line, the flags, and their line ends.
const result_reserve_bytes = 512;

/// Room for the cut marker and its line ends: "[... N bytes cut ...]", with a
/// count of up to 20 digits, plus two line ends.
const cut_marker_reserve_bytes = 64;

/// The smallest `max_bytes` that leaves room for the reserves and a cut.
const min_result_bytes = 1024;

/// How a call acts: `run` sends a program, `wait` waits for the running one.
pub const Action = enum { run, wait };

const Input = struct {
    command: []const u8,
    action: Action,
};

const OwnedInput = struct {
    arena_state: std.heap.ArenaAllocator.State,
    value: Input,

    fn deinit(self: *OwnedInput, alloc: Allocator) void {
        self.arena_state.promote(alloc).deinit();
        self.* = undefined;
    }
};

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *OwnedInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

const needs_command_text = "bash needs {\"command\": \"<bash program>\"}.";
const action_text = "bash action must be \"" ++ @tagName(Action.run) ++ "\" or \"" ++ @tagName(Action.wait) ++ "\".";
const empty_command_text = "bash needs a program in \"command\".";
const too_long_text = std.fmt.comptimePrint("bash programs are at most {d} bytes; save a longer script to a file and run that file.", .{terminal_contracts.max_command_bytes});
/// The sentence that tells the model how to wait for a running program.
const wait_hint = "Send " ++ bash_session.wait_word ++ " as the whole program to wait for it.";
const wait_needs_text = "bash action \"" ++ @tagName(Action.wait) ++ "\" needs the command " ++ bash_session.wait_word ++ ".";
const send_without_action_text = "send " ++ bash_session.wait_word ++ " without an action.";

/// The variables fx adds to every bash program. The saved state never holds
/// them, so the session skips them by these names.
const fx_variables = [_][]const u8{managed_execution.agent_variable} ++ mcp_call_bridge.variable_names;

/// How long a call waits before it reports that the program is still running.
pub const program_yield_ms: u32 = managed_contract.default_yield_time_ms;
const still_running_text = "A program is still running. " ++ wait_hint;
const nothing_running_text = "Nothing is running.";
const unavailable_text = "bash is not available in this host.";
const folder_changed_text = "The bash session's start folder changed after this program was approved, because the last program ended in another folder. Send the program again.";

/// The action a call gets, decided by its command: `wait` when the command is
/// the wait request, else `run`. This is fx's own field, so an `action` the
/// model sent is replaced. Null when `command` is missing or not a string.
pub fn inferAction(object: std.json.ObjectMap) ?[]const u8 {
    const command = object.get("command") orelse return null;
    if (command != .string) return null;
    return if (bash_session.isWaitMore(command.string)) @tagName(Action.wait) else @tagName(Action.run);
}

/// What decoding one call's arguments found: the typed input, or the plain text
/// the model reads back.
const Decoded = union(enum) {
    input: Input,
    failure: []const u8,
};

/// Reads `args_json` as one bash call. Strings in the result live in `arena`.
fn parseArguments(arena: Allocator, args_json: []const u8) Allocator.Error!Decoded {
    const raw = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = needs_command_text },
    };
    if (raw != .object) return .{ .failure = needs_command_text };
    const object = raw.object;
    const command = object.get("command") orelse return .{ .failure = needs_command_text };
    if (command != .string) return .{ .failure = needs_command_text };

    var keys = object.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "command") or std.mem.eql(u8, key, "action")) continue;
        return .{ .failure = try arena.print("bash takes only \"command\"; remove \"{s}\".", .{key}) };
    }

    const action: Action = if (object.get("action")) |value| explicit: {
        if (value != .string) return .{ .failure = action_text };
        break :explicit std.meta.stringToEnum(Action, value.string) orelse return .{ .failure = action_text };
    } else inferred: {
        const text = inferAction(object) orelse return .{ .failure = needs_command_text };
        break :inferred if (std.mem.eql(u8, text, @tagName(Action.wait))) .wait else .run;
    };
    return .{ .input = .{ .command = command.string, .action = action } };
}

/// Decodes one bash call's arguments: `command`, and `action` when present.
pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(arena_state);
    const arena = arena_state.allocator();
    switch (try parseArguments(arena, args_json)) {
        .failure => |text| return .{ .failure = try ctx.allocator.dupe(u8, text) },
        .input => |input| {
            const owned = try ctx.allocator.create(OwnedInput);
            owned.* = .{ .arena_state = arena_state.state, .value = input };
            arena_state.state = .init;
            return .{ .input = .{ .ptr = owned, .deinit_fn = inputDeinit } };
        },
    }
}

/// Refuses a call the tool cannot run, with the text the model reads back.
pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(OwnedInput).value;
    const text = if (input.command.len == 0)
        empty_command_text
    else if (input.command.len > terminal_contracts.max_command_bytes)
        too_long_text
    else if (input.action == .wait and !bash_session.isWaitMore(input.command))
        wait_needs_text
    else if (input.action == .run and bash_session.isWaitMore(input.command))
        send_without_action_text
    else
        return null;
    return try ctx.allocator.dupe(u8, text);
}

/// A wait call reads the running program's output and changes nothing.
pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return erased.as(OwnedInput).value.action == .wait;
}

pub fn isCapturedCommand(erased: tool_dispatch.ToolInput) bool {
    return erased.as(OwnedInput).value.action == .run;
}

pub fn isProcessLocal(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

/// Runs the call `decode` made: a program, or a wait for the running one.
pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .run => callRun(ctx, input.command, program_yield_ms),
        .wait => callWait(ctx, program_yield_ms),
    };
}

/// The fingerprint an approval was given for, whichever kind of approval it is.
fn approvedFingerprint(authority: command_admission.CommandExecutionAuthority) command_admission.AdmissionFingerprint {
    return switch (authority) {
        .direct_only => |fingerprint| fingerprint,
        .shell_allowed => |allowed| allowed.fingerprint,
    };
}

/// Starts `command` as this session's program and waits up to `yield_ms` for its
/// result. A session whose program is still running starts no other.
fn callRun(
    ctx: tool_dispatch.DispatchContext,
    command: []const u8,
    yield_ms: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailableResult(ctx);
    const session = ctx.bash_session orelse return unavailableResult(ctx);
    if (tool_dispatch.bashProgramRunning(session, runtime)) return failureText(ctx, still_running_text);
    const execution_authority = ctx.execution_authority orelse return unavailableResult(ctx);
    const authority = switch (execution_authority) {
        .run_command => |value| value,
        else => return unavailableResult(ctx),
    };
    const swept = session.prepare(io_mod.getIo(), tmpRoot(), &fx_variables) catch |err| return runtimeFailure(ctx, err);
    if (swept > 0) debug_trace.logf("bash", "removed {d} bash session folders that ended processes left", .{swept});
    // A background program may have ended since the approval and left another folder.
    session.refreshStartFolder(io_mod.getIo());
    const folder = session.startFolder() orelse ctx.workspace_root;
    var request_arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer mem_utils.deinit_arena(request_arena_state);
    const request_arena = request_arena_state.allocator();
    // The environment admission approved, built the same way, so the run is the
    // one that was approved.
    const environment = try shell_resolver.bashToolEnvironment(request_arena);
    // The approval must cover the folder the program starts in. Checked before
    // the program is set, so a refused call leaves no program behind.
    const starts_in = command_admission.CommandContext{
        .command = command,
        .resolved_cwd = folder,
        .target_os = builtin.target.os.tag,
        .environment = environment,
    };
    if (!approvedFingerprint(authority).matches(starts_in)) return failureText(ctx, folder_changed_text);
    var execution_id_buffer: [64]u8 = undefined;
    const execution_id = runtime.generatedId(&execution_id_buffer) catch |err| return runtimeFailure(ctx, err);
    // Set before the start, so a failed start never leaves an untracked program.
    session.setProgram(execution_id) catch |err| return runtimeFailure(ctx, err);
    // While this call runs, its program can reach this agent's MCP tools with
    // `fx mcp call` (`mcp_call_bridge.zig`).
    const bridge_registration: ?*mcp_call_bridge.Registration = if (comptime mcp_call_bridge.supported) registration: {
        const capability = ctx.mcp_call_capability orelse break :registration null;
        break :registration mcp_call_bridge.register(capability) catch |err| {
            debug_trace.logf("bash", "bash call not registered with the bridge err={s}", .{@errorName(err)});
            break :registration null;
        };
    } else null;
    defer if (comptime mcp_call_bridge.supported) if (bridge_registration) |registration| mcp_call_bridge.unregister(registration);
    var variables: std.ArrayList(managed_execution.EnvironmentVariable) = .empty;
    if (bridge_registration) |registration| try variables.appendSlice(request_arena, registration.environment());
    const bash_env = session.bashEnv() orelse return runtimeFailure(ctx, error.SessionNotPrepared);
    try variables.append(request_arena, .{ .name = bash_session.env_var, .value = bash_env });
    var prepared = runtime.startCaptured(ctx.allocator, .{
        .execution_id = execution_id,
        .command = command,
        .cwd = folder,
        .environment = environment,
        .authority = authority,
        .extra_environment = variables.items,
        .yield_hold = if (bridge_registration) |registration| &registration.hold else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .timeout_ms = ctx.command_timeout_ms,
        .command_artifact_dir = ctx.command_artifact_dir,
        .replay_capability = ctx.session_child_capability,
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .yield_time_ms = yield_ms,
        .cancel_flag = ctx.cancel_flag,
        .tool_yield_flag = ctx.tool_yield_flag,
    }) catch |err| {
        if (err == error.Cancelled and cancelRequested(ctx)) return error.Cancelled;
        return runtimeFailure(ctx, err);
    };
    defer prepared.deinit(ctx.allocator);
    return finish(ctx, runtime, &prepared);
}

/// Waits up to `yield_ms` for the session's program, or says that nothing is
/// running. A wait is not a command, so it needs no authority.
fn callWait(
    ctx: tool_dispatch.DispatchContext,
    yield_ms: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailableResult(ctx);
    const session = ctx.bash_session orelse return unavailableResult(ctx);
    const id = session.program() orelse return successText(ctx, nothing_running_text);
    if (runtime.stateFor(id) == null or runtime.isTombstone(id)) return successText(ctx, nothing_running_text);
    var prepared = runtime.waitOrYield(
        ctx.allocator,
        id,
        yield_ms,
        ctx.cancel_flag,
        ctx.tool_yield_flag,
    ) catch |err| {
        if (err == error.Cancelled and cancelRequested(ctx)) return error.Cancelled;
        return runtimeFailure(ctx, err);
    };
    defer prepared.deinit(ctx.allocator);
    return finish(ctx, runtime, &prepared);
}

/// Turns a program's snapshot into the result the model reads, then hands the
/// delivery to the runtime. A failed hand-off cancels the reservation, so none is
/// left behind, and frees the body.
fn finish(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    prepared: *managed_execution.PreparedSnapshot,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const budget = @max(ctx.max_tool_result_bytes, min_result_bytes);
    const body = formatResult(ctx.allocator, prepared.snapshot, budget) catch |err| {
        runtime.cancelDelivery(prepared.snapshot.execution_id, prepared.reservation_id) catch |cancel_err| {
            debug_trace.logf("bash", "delivery cancel failed after a format error err={s}", .{@errorName(cancel_err)});
        };
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return failureText(ctx, "bash result is unavailable");
    };
    managed_delivery.handoff(ctx, runtime, prepared.reservation_id) catch |err| {
        debug_trace.logf("bash", "result commit failed err={s}", .{@errorName(err)});
        ctx.allocator.free(body);
        runtime.cancelDelivery(prepared.snapshot.execution_id, prepared.reservation_id) catch |cancel_err| {
            debug_trace.logf("bash", "delivery cancel failed after a commit failure err={s}", .{@errorName(cancel_err)});
        };
        return failureText(ctx, "bash result commit failed");
    };
    // The program has ended, so the next program starts where it left off.
    if (ctx.bash_session) |session| {
        if (std.meta.activeTag(prepared.snapshot.state) != .running) session.refreshStartFolder(io_mod.getIo());
    }
    return if (prepared.snapshot.failed())
        .{ .failure = body }
    else
        .{ .success = body };
}

fn successText(ctx: tool_dispatch.DispatchContext, text: []const u8) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, text) };
}

fn failureText(ctx: tool_dispatch.DispatchContext, text: []const u8) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.dupe(u8, text) };
}

fn unavailableResult(ctx: tool_dispatch.DispatchContext) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return failureText(ctx, unavailable_text);
}

/// The failure text for a runtime error. Running out of memory is the caller's
/// to report, so it is returned as is.
fn runtimeFailure(ctx: tool_dispatch.DispatchContext, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try ctx.allocator.print("bash could not run the program: {s}.", .{@errorName(err)}) };
}

fn cancelRequested(ctx: tool_dispatch.DispatchContext) bool {
    const flag = ctx.cancel_flag orelse return false;
    return flag.load(.seq_cst);
}

/// The folder the session's files go in: `$TMPDIR` without trailing slashes, or
/// `/tmp` when it is unset.
fn tmpRoot() []const u8 {
    return tmpRootFor(io_mod.getenv("TMPDIR") orelse "/tmp");
}

/// `raw` when it is an absolute path without trailing slashes, else `/tmp`. A
/// relative path would fail every call, and `$`, a backquote, or a backslash
/// would be expanded by bash from `BASH_ENV`, so `/tmp` stands in for both.
fn tmpRootFor(raw: []const u8) []const u8 {
    if (!std.Io.Dir.path.isAbsolute(raw)) return "/tmp";
    const trimmed = std.mem.trimEnd(u8, raw, "/");
    if (std.mem.findAny(u8, trimmed, "$`\\") != null) return "/tmp";
    return if (trimmed.len == 0) "/" else trimmed;
}

test "tmpRoot uses an absolute TMPDIR without trailing slashes, and /tmp otherwise" {
    try std.testing.expectEqualStrings("/var/folders/fx", tmpRootFor("/var/folders/fx/"));
    try std.testing.expectEqualStrings("/", tmpRootFor("/"));
    try std.testing.expectEqualStrings("/tmp", tmpRootFor(""));
    try std.testing.expectEqualStrings("/tmp", tmpRootFor("relative/dir"));
    try std.testing.expectEqualStrings("/tmp", tmpRootFor("./tmp"));
    try std.testing.expectEqualStrings("/tmp", tmpRootFor("/bad$dir"));
    try std.testing.expectEqualStrings("/tmp", tmpRootFor("/bad`dir"));
    try std.testing.expectEqualStrings("/tmp", tmpRootFor("/bad\\dir"));
}

/// The text the model sees for one snapshot of a bash program: its output, cut
/// to `max_bytes` when needed, then at most one status line, then the flags.
/// The caller frees the result.
fn formatResult(alloc: Allocator, snapshot: managed_execution.Snapshot, max_bytes: usize) ![]u8 {
    if (max_bytes < min_result_bytes) return error.ResultBudgetTooSmall;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const output = snapshot.output_delta;
    if (output.len + result_reserve_bytes > max_bytes) {
        const keep = max_bytes - result_reserve_bytes - cut_marker_reserve_bytes;
        try appendCutOutput(alloc, &out, output, keep);
    } else {
        try out.appendSlice(alloc, output);
    }
    if (try statusLine(alloc, snapshot)) |line| {
        defer alloc.free(line);
        try appendLine(alloc, &out, line);
    }
    if (snapshot.output_truncated) try appendLine(alloc, &out, "[some output was cut]");
    if (snapshot.output_incomplete) try appendLine(alloc, &out, "[some output could not be read]");
    return out.toOwnedSlice(alloc);
}

/// Appends the head and the tail of `text`, with a line between them that says
/// how many bytes were cut. The head and tail together keep at most `keep`
/// bytes, and each cut lands on a character boundary.
fn appendCutOutput(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8, keep: usize) !void {
    const head_budget = keep / 2;
    const tail_budget = keep - head_budget;
    const head_end = text_utils.utf8BackwardBoundary(text, head_budget);
    const tail_start = text_utils.utf8ForwardBoundary(text, text.len - tail_budget);
    const marker = try alloc.print("[... {d} bytes cut ...]", .{tail_start - head_end});
    defer alloc.free(marker);
    try out.appendSlice(alloc, text[0..head_end]);
    try appendLine(alloc, out, marker);
    try appendLine(alloc, out, text[tail_start..]);
}

/// Appends `line` on its own line, first adding a line end when `out` does not
/// already end with one.
fn appendLine(alloc: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
    try out.appendSlice(alloc, line);
}

/// The one status line for `snapshot`, or null when its state needs none. The
/// caller frees a non-null result.
fn statusLine(alloc: Allocator, snapshot: managed_execution.Snapshot) Allocator.Error!?[]u8 {
    const no_output = snapshot.output_delta.len == 0;
    return switch (snapshot.state) {
        .running => if (snapshot.running_ms) |ms|
            try alloc.print("[still running after {d} s. " ++ wait_hint ++ "]", .{ms / 1000})
        else
            try alloc.dupe(u8, "[still running. " ++ wait_hint ++ "]"),
        .completed => |status| switch (status) {
            .exit_code => |code| if (code != 0)
                try alloc.print("[exit {d}]", .{code})
            else if (no_output)
                try alloc.dupe(u8, "[done, no output]")
            else
                null,
            .finished => if (no_output) try alloc.dupe(u8, "[done, no output]") else null,
            .signal => |signal| try alloc.print("[killed by signal {d}]", .{signal}),
            .indeterminate => try alloc.dupe(u8, "[ended; exit status unknown]"),
        },
        .stopped => try alloc.dupe(u8, "[stopped]"),
        .lost => try alloc.dupe(u8, "[fx lost this program]"),
    };
}

fn parseObject(arena: Allocator, text: []const u8) !std.json.ObjectMap {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    return value.object;
}

fn expectInferred(text: []const u8, want: ?[]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = inferAction(try parseObject(arena_state.allocator(), text));
    if (want) |expected| {
        try std.testing.expectEqualStrings(expected, got orelse return error.TestExpectedAction);
    } else {
        try std.testing.expect(got == null);
    }
}

fn expectDecodedAction(args_json: []const u8, want: Input) !void {
    const alloc = std.testing.allocator;
    switch (try decode(.{ .allocator = alloc }, args_json)) {
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(OwnedInput).value;
            try std.testing.expectEqual(want.action, input.action);
            try std.testing.expectEqualStrings(want.command, input.command);
        },
        .failure => |text| {
            alloc.free(text);
            return error.TestUnexpectedFailure;
        },
    }
}

fn expectDecodeFailure(args_json: []const u8, want: []const u8) !void {
    const alloc = std.testing.allocator;
    switch (try decode(.{ .allocator = alloc }, args_json)) {
        .input => |erased| {
            erased.deinit(alloc);
            return error.TestExpectedFailure;
        },
        .failure => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings(want, text);
        },
    }
}

fn decodeTestInput(alloc: Allocator, args_json: []const u8) !tool_dispatch.ToolInput {
    return switch (try decode(.{ .allocator = alloc }, args_json)) {
        .input => |erased| erased,
        .failure => |text| {
            alloc.free(text);
            return error.TestUnexpectedFailure;
        },
    };
}

fn expectValidation(args_json: []const u8, want: ?[]const u8) !void {
    const alloc = std.testing.allocator;
    const erased = try decodeTestInput(alloc, args_json);
    defer erased.deinit(alloc);
    const got = try validate(.{ .allocator = alloc }, erased);
    defer if (got) |text| alloc.free(text);
    if (want) |expected| {
        try std.testing.expectEqualStrings(expected, got orelse return error.TestExpectedText);
    } else {
        try std.testing.expect(got == null);
    }
}

/// Arguments whose `command` is `command_bytes` long, all `a`.
fn argsWithCommand(alloc: Allocator, command_bytes: usize) ![]u8 {
    const command = try alloc.alloc(u8, command_bytes);
    defer alloc.free(command);
    @memset(command, 'a');
    return alloc.print("{{\"command\":\"{s}\"}}", .{command});
}

fn testSnapshot(output: []const u8, state: managed_execution.SnapshotState) managed_execution.Snapshot {
    return .{
        .execution_id = @constCast("program"),
        .command = @constCast("ls"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = state,
        .output_delta = @constCast(output),
        .output_truncated = false,
    };
}

test "bash infers the action from the command: wait_more waits, anything else runs" {
    try expectInferred("{\"command\":\"wait_more\"}", "wait");
    try expectInferred("{\"command\":\"ls -la\"}", "run");
    try expectInferred("{\"command\":\"ls\",\"action\":\"run\"}", "run");
    try expectInferred("{\"command\":\"wait_more\",\"action\":\"run\"}", "wait");
    try expectInferred("{\"command\":\"ls\",\"action\":\"wait\"}", "run");
    try expectInferred("{\"other\":1}", null);
    try expectInferred("{\"command\":3}", null);
}

test "bash decode takes command and action, and infers the action when it is absent" {
    try expectDecodedAction("{\"command\":\"ls\",\"action\":\"run\"}", .{ .command = "ls", .action = .run });
    try expectDecodedAction("{\"command\":\"wait_more\",\"action\":\"wait\"}", .{ .command = "wait_more", .action = .wait });
    try expectDecodedAction("{\"command\":\"ls\"}", .{ .command = "ls", .action = .run });
    try expectDecodedAction("{\"command\":\"wait_more\"}", .{ .command = "wait_more", .action = .wait });
}

test "bash decode names a bad argument in plain text" {
    try expectDecodeFailure("[1]", needs_command_text);
    try expectDecodeFailure("{", needs_command_text);
    try expectDecodeFailure("{\"action\":\"run\"}", needs_command_text);
    try expectDecodeFailure("{\"command\":3}", needs_command_text);
    try expectDecodeFailure("{\"command\":\"ls\",\"timeout_ms\":5}", "bash takes only \"command\"; remove \"timeout_ms\".");
    try expectDecodeFailure("{\"command\":\"ls\",\"action\":\"stop\"}", action_text);
    try expectDecodeFailure("{\"command\":\"ls\",\"action\":3}", action_text);
}

const max_fuzz_call_text_bytes: usize = 16 * 1024;

/// What a call's bytes must decode to, read by std.json with the rules written
/// out a second time, so the fuzz property can compare the decoder with them.
const CallReading = struct {
    command: []const u8,
    /// Null when the call has no `action` key.
    action: ?[]const u8,
};

/// Null means the bytes must be refused: not a JSON object, no string
/// `command`, a key other than `command` and `action`, or an `action` that is
/// not "run" or "wait".
fn readCallText(arena: Allocator, text: []const u8) error{OutOfMemory}!?CallReading {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (value != .object) return null;
    const object = value.object;
    const command = object.get("command") orelse return null;
    if (command != .string) return null;
    var keys = object.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "command") and !std.mem.eql(u8, key, "action")) return null;
    }
    const action: ?[]const u8 = if (object.get("action")) |stated| blk: {
        if (stated != .string) return null;
        if (!std.mem.eql(u8, stated.string, "run") and !std.mem.eql(u8, stated.string, "wait")) return null;
        break :blk stated.string;
    } else null;
    return .{ .command = command.string, .action = action };
}

fn fuzzBashCallText(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_fuzz_call_text_bytes]u8 = undefined;
    const text = buffer[0..smith.slice(&buffer)];

    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const reading = try readCallText(arena_state.allocator(), text);

    // Any error other than OutOfMemory is a decoder defect, not a refusal.
    const result = decode(.{ .allocator = alloc }, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TestDecodeReturnedAnError,
    };
    switch (result) {
        .input => |erased| {
            defer erased.deinit(alloc);
            const want = reading orelse return error.TestDecodedRefusedBytes;
            const input = erased.as(OwnedInput).value;
            try std.testing.expectEqualStrings(want.command, input.command);
            if (want.action) |stated| {
                try std.testing.expectEqualStrings(stated, @tagName(input.action));
            } else {
                const inferred: Action = if (bash_session.isWaitMore(want.command)) .wait else .run;
                try std.testing.expectEqual(inferred, input.action);
            }
        },
        .failure => |failure| {
            defer alloc.free(failure);
            if (reading != null) return error.TestRefusedAcceptedBytes;
            try std.testing.expect(failure.len > 0);
        },
    }
}

test "bash calls sent as JSON text decode or are refused on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzBashCallText, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"command\":\"echo hi\"}",
            "{\"command\":\"wait_more\"}",
            "{\"command\":\"ls\",\"action\":\"run\"}",
            "{\"command\":\"wait_more\",\"action\":\"run\"}",
            "{\"request\":{\"command\":\"pwd\"}}",
            "{\"command\":\"x\",\"cwd\":\"/\"}",
        }) ++ @import("fuzz_corpus").bash_call_text.*),
    });
}

test "bash validate refuses an empty, oversized, or mismatched program with its text" {
    const alloc = std.testing.allocator;
    try expectValidation("{\"command\":\"\"}", empty_command_text);
    try expectValidation("{\"command\":\"ls\",\"action\":\"wait\"}", wait_needs_text);
    try expectValidation("{\"command\":\"wait_more\",\"action\":\"run\"}", send_without_action_text);
    try expectValidation("{\"command\":\"ls\"}", null);
    try expectValidation("{\"command\":\"wait_more\"}", null);

    const at_limit = try argsWithCommand(alloc, terminal_contracts.max_command_bytes);
    defer alloc.free(at_limit);
    try expectValidation(at_limit, null);
    const over_limit = try argsWithCommand(alloc, terminal_contracts.max_command_bytes + 1);
    defer alloc.free(over_limit);
    try expectValidation(over_limit, too_long_text);
}

test "bash predicates follow the action" {
    const alloc = std.testing.allocator;
    const run = try decodeTestInput(alloc, "{\"command\":\"ls\"}");
    defer run.deinit(alloc);
    try std.testing.expect(isCapturedCommand(run));
    try std.testing.expect(!readsOnly(run));
    try std.testing.expect(isProcessLocal(run));
    try std.testing.expect(!isIrreversible(run));

    const wait = try decodeTestInput(alloc, "{\"command\":\"wait_more\"}");
    defer wait.deinit(alloc);
    try std.testing.expect(!isCapturedCommand(wait));
    try std.testing.expect(readsOnly(wait));
}

test "formatResult shows one status line for each state" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        output: []const u8,
        state: managed_execution.SnapshotState,
        running_ms: ?u64 = null,
        want: []const u8,
    }{
        .{ .output = "", .state = .running, .running_ms = 3500, .want = "[still running after 3 s. Send wait_more as the whole program to wait for it.]" },
        .{ .output = "x\n", .state = .running, .want = "x\n[still running. Send wait_more as the whole program to wait for it.]" },
        .{ .output = "", .state = .{ .completed = .{ .exit_code = 0 } }, .want = "[done, no output]" },
        .{ .output = "ok\n", .state = .{ .completed = .{ .exit_code = 0 } }, .want = "ok\n" },
        .{ .output = "ok\n", .state = .{ .completed = .{ .exit_code = 2 } }, .want = "ok\n[exit 2]" },
        .{ .output = "", .state = .{ .completed = .{ .exit_code = 2 } }, .want = "[exit 2]" },
        .{ .output = "", .state = .{ .completed = .{ .signal = 9 } }, .want = "[killed by signal 9]" },
        .{ .output = "", .state = .{ .completed = .indeterminate }, .want = "[ended; exit status unknown]" },
        .{ .output = "", .state = .{ .completed = .finished }, .want = "[done, no output]" },
        .{ .output = "half\n", .state = .{ .stopped = null }, .want = "half\n[stopped]" },
        .{ .output = "", .state = .lost, .want = "[fx lost this program]" },
    };
    for (cases) |case| {
        var snapshot = testSnapshot(case.output, case.state);
        snapshot.running_ms = case.running_ms;
        const got = try formatResult(alloc, snapshot, 4096);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "formatResult adds the cut and read flags on their own lines" {
    const alloc = std.testing.allocator;
    var snapshot = testSnapshot("ok\n", .{ .completed = .finished });
    snapshot.output_truncated = true;
    snapshot.output_incomplete = true;
    const got = try formatResult(alloc, snapshot, 4096);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("ok\n[some output was cut]\n[some output could not be read]", got);
}

test "formatResult keeps the head and tail of a long output within max_bytes, on whole characters" {
    const alloc = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    // 735 ASCII bytes, then three-byte characters. The head cut at half the
    // kept bytes lands inside the first character, and the tail cut lands
    // inside one too.
    for (0..735) |_| try output.append(alloc, 'a');
    for (0..1000) |_| try output.appendSlice(alloc, "€");
    const snapshot = testSnapshot(output.items, .{ .completed = .{ .exit_code = 0 } });
    const got = try formatResult(alloc, snapshot, 2048);
    defer alloc.free(got);
    try std.testing.expect(got.len <= 2048);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
    try std.testing.expectEqualSlices(u8, output.items[0..735], got[0..735]);
    try std.testing.expectEqual(@as(u8, '\n'), got[735]);
    try std.testing.expect(std.mem.find(u8, got, "[... 2265 bytes cut ...]") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "€"));
}

test "formatResult refuses a budget too small for its reserves" {
    try std.testing.expectError(
        error.ResultBudgetTooSmall,
        formatResult(std.testing.allocator, testSnapshot("x", .{ .completed = .finished }), 100),
    );
}

/// How long the tests' calls wait before they report a running program.
const test_yield_ms: u32 = 200;

/// One test's bash world: a workspace folder, the runtime that runs programs,
/// the session that keeps their state, and the arena that holds call authority.
/// Pair `init` with `defer deinit`. `context` reads the fields at each call, so
/// a context never points at a copy of this struct.
const TestBash = struct {
    alloc: Allocator,
    io: std.Io,
    tmp: std.testing.TmpDir,
    /// Sentinel-terminated, as `realPathFileAlloc` returns it: `free` needs the allocation's length.
    workspace: [:0]u8,
    runtime: managed_execution.Runtime,
    session: bash_session.Session,
    arena_state: std.heap.ArenaAllocator,
    /// The gate's fd, held read-write so opening it never waits; see `makeGate`.
    gate: ?std.Io.File = null,

    fn init(alloc: Allocator) !TestBash {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const workspace = try tmp.dir.realPathFileAlloc(io, ".", alloc);
        return .{
            .alloc = alloc,
            .io = io,
            .tmp = tmp,
            .workspace = workspace,
            .runtime = managed_execution.Runtime.init(alloc),
            .session = bash_session.Session.init(alloc),
            .arena_state = std.heap.ArenaAllocator.init(alloc),
        };
    }

    fn deinit(self: *TestBash) void {
        self.arena_state.deinit();
        self.session.deinit(self.io);
        self.runtime.deinit();
        if (self.gate) |file| file.close(self.io);
        self.alloc.free(self.workspace);
        self.tmp.cleanup();
    }

    /// The context a call runs with: this test's runtime and session, in its workspace.
    fn context(self: *TestBash) tool_dispatch.DispatchContext {
        return .{
            .allocator = self.alloc,
            .workspace_root = self.workspace,
            .managed_executions = &self.runtime,
            .bash_session = &self.session,
        };
    }

    /// Gives `ctx` the authority of a yolo-approved run of `command`.
    fn authorize(self: *TestBash, ctx: *tool_dispatch.DispatchContext, command: []const u8) !void {
        try authorizeRun(ctx, self.arena_state.allocator(), command);
    }

    /// Writes `folder` into the session's folder file, as the end of a program does.
    fn writeSessionFolder(self: *TestBash, folder: []const u8) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.session.dir.?, .{});
        defer dir.close(self.io);
        try dir.writeFile(self.io, .{ .sub_path = "folder", .data = folder });
    }

    /// Makes the gate: a fifo in the workspace, held open read-write and nonblocking.
    /// That fd is a reader and a writer, so the open never waits, and a program's
    /// `read` finds a writer. The program blocks on its read until `release`.
    fn makeGate(self: *TestBash) !void {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.mem.printSentinel(&path_buffer, "{s}/gate", .{self.workspace}, 0);
        if (mkfifo(path, 0o600) != 0) return error.MkfifoFailed;
        const fd = try std.posix.openat(self.tmp.dir.handle, "gate", .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
        self.gate = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    }

    /// Writes one line to the gate, which lets the program blocked on its read finish.
    /// The line waits in the pipe until bash opens the gate, so nothing waits on time.
    fn release(self: *TestBash) !void {
        const gate = self.gate orelse return error.GateNotMade;
        try gate.writeStreamingAll(self.io, "go\n");
    }
};

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

/// The folder a call approved now starts in: the session's start folder, else
/// the workspace root.
fn startFolderOf(ctx: tool_dispatch.DispatchContext) []const u8 {
    const session = ctx.bash_session orelse return ctx.workspace_root;
    return session.startFolder() orelse ctx.workspace_root;
}

/// Gives `ctx` the authority a yolo-approved run of `command` gets: a fingerprint
/// of the same command, cwd, and environment the call computes. Built the way
/// `shell.zig`'s integration test builds its authority.
fn authorizeRun(ctx: *tool_dispatch.DispatchContext, arena: Allocator, command: []const u8) !void {
    // The approval keeps this slice, and the session frees its start folder on
    // refresh, so the approval gets its own copy.
    const folder = try arena.dupe(u8, startFolderOf(ctx.*));
    const command_ctx = command_admission.CommandContext{
        .command = command,
        .resolved_cwd = folder,
        .target_os = builtin.target.os.tag,
        .environment = try shell_resolver.bashToolEnvironment(arena),
    };
    ctx.execution_authority = .{ .run_command = .{ .shell_allowed = .{
        .fingerprint = .init(command_ctx),
        .source = .yolo,
    } } };
}

/// The text of `result` when it has the outcome `success`, else an error.
fn outcomeText(result: tool_dispatch.ToolResult, success: bool) ![]const u8 {
    switch (result) {
        .success => |body| if (success) return body,
        .failure => |body| if (!success) return body,
        .rich => {},
    }
    return error.TestUnexpectedOutcome;
}

test "bash state carries from one program to the next" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    try bash.authorize(&ctx, "x=41");
    const first = try callRun(ctx, "x=41", program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    try bash.authorize(&ctx, "echo $((x+1))");
    const second = try callRun(ctx, "echo $((x+1))", program_yield_ms);
    defer second.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, try outcomeText(second, true), "42"));
}

test "bash working folder carries from one program to the next" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    try bash.authorize(&ctx, "cd /");
    const moved = try callRun(ctx, "cd /", program_yield_ms);
    defer moved.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(moved, true));

    try bash.authorize(&ctx, "pwd");
    const pwd = try callRun(ctx, "pwd", program_yield_ms);
    defer pwd.deinit(alloc);
    try std.testing.expectEqualStrings("/\n", try outcomeText(pwd, true));
}

test "bash reports a failing program with its exit status" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    try bash.authorize(&ctx, "false");
    const failed = try callRun(ctx, "false", program_yield_ms);
    defer failed.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(failed, false), "[exit 1]") != null);
}

test "bash waits with nothing running and says so" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    const ctx = bash.context();

    const waited = try callWait(ctx, program_yield_ms);
    defer waited.deinit(alloc);
    try std.testing.expectEqualStrings(nothing_running_text, try outcomeText(waited, true));
}

test "bash refuses a second program while one is running" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    try bash.makeGate();

    // The program reads the gate, so it runs until the test writes to the gate.
    try bash.authorize(&ctx, "read go < gate; echo done");
    const started = try callRun(ctx, "read go < gate; echo done", test_yield_ms);
    defer started.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(started, true), "[still running") != null);

    try bash.authorize(&ctx, "echo again");
    const refused = try callRun(ctx, "echo again", test_yield_ms);
    defer refused.deinit(alloc);
    try std.testing.expectEqualStrings(still_running_text, try outcomeText(refused, false));

    try bash.release();
    const finished = try callWait(ctx, program_yield_ms);
    defer finished.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(finished, true), "done") != null);
}

test "bash waits for a running program, then says nothing is running" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    try bash.makeGate();

    try bash.authorize(&ctx, "read go < gate; echo done");
    const started = try callRun(ctx, "read go < gate; echo done", test_yield_ms);
    defer started.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(started, true), "[still running") != null);

    try bash.release();
    const waited = try callWait(ctx, program_yield_ms);
    defer waited.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(waited, true), "done") != null);

    const after = try callWait(ctx, program_yield_ms);
    defer after.deinit(alloc);
    try std.testing.expectEqualStrings(nothing_running_text, try outcomeText(after, true));
}

test "bash refuses to run or wait without a session" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    ctx.bash_session = null;

    const run = try callRun(ctx, "echo hi", program_yield_ms);
    defer run.deinit(alloc);
    try std.testing.expectEqualStrings(unavailable_text, try outcomeText(run, false));

    const waited = try callWait(ctx, program_yield_ms);
    defer waited.deinit(alloc);
    try std.testing.expectEqualStrings(unavailable_text, try outcomeText(waited, false));
}

test "bash refuses a program whose start folder changed after its approval" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);

    // Approved while the session starts in the workspace root.
    try bash.authorize(&ctx, "echo moved");
    // A background program ends in another folder, and its end writes the folder.
    try bash.writeSessionFolder("/");
    const refused = try callRun(ctx, "echo moved", test_yield_ms);
    defer refused.deinit(alloc);
    try std.testing.expectEqualStrings(folder_changed_text, try outcomeText(refused, false));
    try std.testing.expect(bash.session.program() == null);
}

test "a program starts in the folder the session holds, not one the saved state remembers" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);

    try bash.authorize(&ctx, "cd /");
    const moved = try callRun(ctx, "cd /", program_yield_ms);
    defer moved.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(moved, true));

    // fx moves the start folder back to the workspace, as a program's end would.
    try bash.writeSessionFolder(bash.workspace);
    bash.session.refreshStartFolder(bash.io);
    try bash.authorize(&ctx, "pwd");
    const pwd = try callRun(ctx, "pwd", program_yield_ms);
    defer pwd.deinit(alloc);
    const expected = try alloc.print("{s}\n", .{bash.workspace});
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, try outcomeText(pwd, true));
}
