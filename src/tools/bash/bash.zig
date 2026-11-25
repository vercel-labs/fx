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
const tool_bridge = @import("../../core/tool_bridge/tool_bridge.zig");
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

/// The largest state a program may save, as the text of its notice.
const max_state_text = std.fmt.comptimePrint("{d}", .{bash_session.max_state_bytes});

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
const fx_variables = [_][]const u8{managed_execution.agent_variable} ++ tool_bridge.variable_names;

/// How long a call waits before it reports that the program is still running.
pub const program_yield_ms: u32 = managed_contract.default_yield_time_ms;
const still_running_text = "A program is still running. " ++ wait_hint;
const nothing_running_text = "Nothing is running.";
const unavailable_text = "bash is not available in this host.";
const folder_changed_text = "The bash session's start folder changed after this program was approved, because the last program ended in another folder. Send the program again.";
/// The notice a call's result carries when the session dropped the saved start
/// folder. It is true of a started program, a refused call, and a failed start.
const start_folder_notice = "fx: the bash session's saved folder could not be used, so programs start in the workspace root until one saves a new folder.";
/// The notice a call's result carries when `heal` lost the saved state, because a
/// program removed or replaced the session's files. It is true of every result.
const state_lost_notice = "fx: the bash session's saved state was lost because its files were removed or replaced, so programs start from a fresh state.";

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
        return .{ .failure = try joinParts(arena, &.{ "bash takes only \"command\"; remove \"", key, "\"." }) };
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
    // Before the program, the session folder is checked and repaired, so no shell
    // the program starts waits on a FIFO, a link, or a missing file. Every repair
    // made is logged, even when a later one fails.
    const healed = session.heal(io_mod.getIo(), &fx_variables);
    if (swept + healed.swept > 0) debug_trace.logf("bash", "removed {d} bash session folders that ended processes left", .{swept + healed.swept});
    for (healed.items()) |repair| traceRepair(@tagName(repair.what), repair.name);
    if (healed.repair_failed) |err| traceError("bash session repair failed", err);
    if (healed.forget_failed) |err| traceError("bash session could not remove its old folder", err);
    if (healed.fresh_failed) |err| {
        traceError("bash session could not make a folder", err);
        return sessionFailure(ctx, err);
    }
    // Set by the prepare and heal above. Looked up before the program is set, so a
    // missing text fails the call without running a program with no saved state.
    const after_startup = session.afterStartupText() orelse return runtimeFailure(ctx, error.SessionNotPrepared);
    // A background program may have ended since the approval and left another folder.
    // A drop by this refresh, or one the last program's end recorded, gives this call its notice.
    refreshFolder(session);
    // A loss that an earlier call's failed fresh folder left is still pending, so this call reports it too.
    const lost = healed.stateLost() or session.lossPending();
    if (lost and !healed.stateLost()) traceRepair("state_lost", "session");
    const notes: CallNotes = .{
        .folder = if (session.takeFolderDropped()) start_folder_notice else null,
        .state = if (lost) state_lost_notice else null,
    };
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
    if (!approvedFingerprint(authority).matches(starts_in)) return failureWithNote(ctx, folder_changed_text, notes);
    var execution_id_buffer: [64]u8 = undefined;
    const execution_id = runtime.generatedId(&execution_id_buffer) catch |err| return runtimeFailure(ctx, err);
    // Set before the start, so a failed start never leaves an untracked program.
    session.setProgram(execution_id) catch |err| return runtimeFailure(ctx, err);
    // While this call runs, its program can reach this agent's MCP tools with
    // `fx mcp call` (`tool_bridge.zig`).
    const bridge_registration: ?*tool_bridge.Registration = if (comptime tool_bridge.supported) registration: {
        const capability = ctx.mcp_call_capability orelse break :registration null;
        break :registration tool_bridge.register(capability) catch |err| {
            traceError("bash call not registered with the bridge", err);
            break :registration null;
        };
    } else null;
    defer if (comptime tool_bridge.supported) if (bridge_registration) |registration| tool_bridge.unregister(registration);
    const extra_environment: []const managed_execution.EnvironmentVariable = if (bridge_registration) |registration| registration.environment() else &.{};
    // A save record that a program left after it ended, with its end never
    // delivered, is this program's to report. It is taken here, just before this
    // program starts, and its notice goes into this program's result.
    const leftover = takeSaveNotice(ctx.allocator, session, .previous) catch |err| return runtimeFailure(ctx, err);
    var prepared = runtime.startCaptured(ctx.allocator, .{
        .execution_id = execution_id,
        .command = command,
        .cwd = folder,
        .environment = environment,
        .authority = authority,
        .extra_environment = extra_environment,
        .after_startup = after_startup,
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
        if (err == error.Cancelled and cancelRequested(ctx)) {
            // A cancelled call returns an error, not a result, so the notices have no result to go in.
            if (leftover != null or notes.present()) {
                if (leftover) |text| ctx.allocator.free(text);
                logDroppedNotice(err);
            }
            return error.Cancelled;
        }
        return startFailure(ctx, err, leftover, notes);
    };
    defer prepared.deinit(ctx.allocator);
    const outcome = finish(ctx, runtime, &prepared, leftover, notes);
    // The program started and its result, with the state-lost notice, was delivered, so the loss has been reported.
    if (outcome) |_| {
        if (notes.state != null) session.clearLossPending();
    } else |_| {} // Not delivered: the notice did not reach the model, so the mark stays.
    return outcome;
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
    return finish(ctx, runtime, &prepared, null, .{});
}

/// Which program a save notice is about: `own` is the program whose result carries
/// the notice, and `previous` is a program that ended before that call.
const NoticeOwner = enum { own, previous };

/// The most bytes a decimal number of a 64-bit value takes, with its sign.
const max_decimal_bytes = 20;

/// The decimal text of `value`, written into `buf`.
fn decimal(buf: *[max_decimal_bytes]u8, value: i64) []u8 {
    return buf[0..std.fmt.printInt(buf, value, 10, .lower, .{})];
}

/// A new slice holding `parts` in order. The caller frees it.
fn joinParts(alloc: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    return std.mem.concat(alloc, u8, parts);
}

/// Takes the save record the last program's save left, if there is one, logs why
/// that program's state was not saved, and returns the notice for the result. The
/// caller frees a non-null result.
fn takeSaveNotice(alloc: Allocator, session: *bash_session.Session, owner: NoticeOwner) Allocator.Error!?[]u8 {
    const status = session.takeSaveStatus(io_mod.getIo()) orelse return null;
    const bytes: usize = switch (status) {
        .over_cap => |size| size,
        .failed, .not_saved => 0,
    };
    debug_trace.logf("bash", "bash state not saved: reason={s} bytes={d}", .{ @tagName(status), bytes });
    const previous = owner == .previous;
    var digits: [max_decimal_bytes]u8 = undefined;
    return switch (status) {
        .over_cap => |size| try joinParts(alloc, &.{
            if (previous) "fx: the previous program's bash state was " else "fx: this program's bash state is ",
            decimal(&digits, @intCast(size)),
            " bytes, over the " ++ max_state_text ++ "-byte limit, so it was not saved; ",
            if (previous) "the last saved state stays." else "the next program starts from the last saved state.",
        }),
        .failed => try alloc.dupe(u8, if (previous)
            "fx: the previous program's bash state could not be saved; the last saved state stays."
        else
            "fx: this program's bash state could not be saved; the next program starts from the last saved state."),
        .not_saved => try alloc.dupe(u8, if (previous)
            "fx: the previous program ended before fx could save its bash state, so it was not saved; the last saved state stays."
        else
            "fx: this program ended before fx could save its bash state, so it was not saved; the next program starts from the last saved state."),
    };
}

/// `body` with each present notice on its own line after it. Borrows `body`; the
/// caller frees the result.
fn withNotices(alloc: Allocator, body: []const u8, notices: []const ?[]const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, body);
    for (notices) |notice| {
        if (notice) |text| try appendLine(alloc, &out, &.{text});
    }
    return out.toOwnedSlice(alloc);
}

/// Refreshes the session's start folder, and logs a drop by its reason, never by
/// path, whichever caller refreshes. The session records the drop, and the notice
/// of the next call reports it, so nothing is returned.
fn refreshFolder(session: *bash_session.Session) void {
    const status = session.refreshStartFolder(io_mod.getIo());
    switch (status) {
        .kept, .no_record => {},
        .gone, .bad_record => debug_trace.logf("bash", "start folder dropped reason={s}", .{@tagName(status)}),
    }
}

/// The notices a call's result carries. Each is borrowed, and null when it does not
/// apply.
const CallNotes = struct {
    /// The start folder was dropped, so the program starts in the workspace root.
    folder: ?[]const u8 = null,
    /// The saved state was lost, so the program starts fresh.
    state: ?[]const u8 = null,

    fn present(self: CallNotes) bool {
        return self.folder != null or self.state != null;
    }
};

/// `text` as a failure result, with the notices after it.
fn failureWithNote(ctx: tool_dispatch.DispatchContext, text: []const u8, notes: CallNotes) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try withNotices(ctx.allocator, text, &.{ notes.folder, notes.state }) };
}

/// The text of a bash program that could not run because of `err`.
fn runtimeFailureText(alloc: Allocator, err: anyerror) Allocator.Error![]u8 {
    return joinParts(alloc, &.{ "bash could not run the program: ", @errorName(err), "." });
}

/// The result when the program did not start. The previous program's notice, if
/// it has one, goes after the failure text, so the model still reads it, and so
/// do the notices of this call, `notes`. Takes `leftover`.
fn startFailure(
    ctx: tool_dispatch.DispatchContext,
    err: anyerror,
    leftover: ?[]u8,
    notes: CallNotes,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    defer if (leftover) |text| ctx.allocator.free(text);
    if (err == error.OutOfMemory) {
        if (leftover != null or notes.present()) logDroppedNotice(err);
        return error.OutOfMemory;
    }
    const failure = runtimeFailureText(ctx.allocator, err) catch |alloc_err| {
        if (leftover != null or notes.present()) logDroppedNotice(alloc_err);
        return alloc_err;
    };
    defer ctx.allocator.free(failure);
    const notices = [_]?[]const u8{ leftover, notes.folder, notes.state };
    const body = withNotices(ctx.allocator, failure, &notices) catch |attach_err| {
        if (leftover != null or notes.present()) logDroppedNotice(attach_err);
        return attach_err;
    };
    if (leftover != null) traceError("the previous program's not-saved notice went with a start failure", err);
    return .{ .failure = body };
}

/// The failure result for a call whose program ran, but whose result could not be
/// delivered. Its save notices go after `text`, and the trace says so. Out of
/// memory leaves no result to carry them, so it is returned as an error and the
/// notices are logged as dropped.
fn undeliveredResult(ctx: tool_dispatch.DispatchContext, text: []const u8, notices: []const ?[]const u8, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const has_notice = hasNotice(notices);
    if (err == error.OutOfMemory) {
        if (has_notice) logDroppedNotice(err);
        return error.OutOfMemory;
    }
    const with_notices = withNotices(ctx.allocator, text, notices) catch |attach_err| {
        if (has_notice) logDroppedNotice(attach_err);
        return attach_err;
    };
    if (has_notice) traceError("a save notice went with a result failure", err);
    return .{ .failure = with_notices };
}

/// Whether any of `notices` is present.
fn hasNotice(notices: []const ?[]const u8) bool {
    for (notices) |notice| {
        if (notice != null) return true;
    }
    return false;
}

/// Logs `what` with the name of `err`. Every bash failure line goes through here, so
/// they share one format.
fn traceError(what: []const u8, err: anyerror) void {
    debug_trace.logf("bash", "{s} err={s}", .{ what, @errorName(err) });
}

/// Logs a repair `heal` made, by its kind and the name of the entry it changed.
fn traceRepair(what: []const u8, name: []const u8) void {
    debug_trace.logf("bash", "bash session healed what={s} name={s}", .{ what, name });
}

/// Logs that a save notice reached no result, and why.
fn logDroppedNotice(err: anyerror) void {
    traceError("a save notice was dropped with no result to carry it", err);
}

/// Cancels the reservation of `prepared`, after a failure in `what`. A cancel that
/// fails is logged, because the reservation may then stay.
fn cancelDelivery(runtime: *managed_execution.Runtime, prepared: *const managed_execution.PreparedSnapshot, what: []const u8) void {
    runtime.cancelDelivery(prepared.snapshot.execution_id, prepared.reservation_id) catch |err| {
        debug_trace.logf("bash", "delivery cancel failed after {s} err={s}", .{ what, @errorName(err) });
    };
}

/// Turns a program's snapshot into the result the model reads, then hands the
/// delivery to the runtime. `leftover` is a notice from a program that ended
/// before this one started, and it is freed here. `notes` are this call's notices,
/// borrowed. A program that has ended also reports its own save record, which is
/// taken here. A failed hand-off cancels the reservation, so none is left behind,
/// and frees the body.
fn finish(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    prepared: *managed_execution.PreparedSnapshot,
    leftover: ?[]u8,
    notes: CallNotes,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    defer if (leftover) |text| ctx.allocator.free(text);
    const own: ?[]u8 = if (ctx.bash_session) |session| blk: {
        if (std.meta.activeTag(prepared.snapshot.state) == .running) break :blk null;
        break :blk takeSaveNotice(ctx.allocator, session, .own) catch |err| {
            // The reservation is made, so it is cancelled on this failure too.
            cancelDelivery(runtime, prepared, "a notice error");
            if (leftover != null or notes.present()) logDroppedNotice(err);
            return err;
        };
    } else null;
    defer if (own) |text| ctx.allocator.free(text);
    const notices = [_]?[]const u8{ leftover, own, notes.folder, notes.state };
    const budget = @max(ctx.max_tool_result_bytes, min_result_bytes);
    const body = formatResult(ctx.allocator, prepared.snapshot, budget, &notices) catch |err| {
        cancelDelivery(runtime, prepared, "a format error");
        return undeliveredResult(ctx, "bash result is unavailable", &notices, err);
    };
    managed_delivery.handoff(ctx, runtime, prepared.reservation_id) catch |err| {
        traceError("result commit failed", err);
        ctx.allocator.free(body);
        cancelDelivery(runtime, prepared, "a commit failure");
        return undeliveredResult(ctx, "bash result commit failed", &notices, err);
    };
    // The program has ended, so the next program starts where it left off. A folder
    // dropped here is logged and recorded, and the next call's notice reports it.
    if (ctx.bash_session) |session| {
        if (std.meta.activeTag(prepared.snapshot.state) != .running) refreshFolder(session);
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
    return .{ .failure = try runtimeFailureText(ctx.allocator, err) };
}

/// The result when the session could not make a folder, so the program did not run.
/// Running out of memory is the caller's to report, so it is returned as is.
fn sessionFailure(ctx: tool_dispatch.DispatchContext, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try joinParts(ctx.allocator, &.{ "fx: bash could not make a folder for its session (", @errorName(err), "), so this program did not run." }) };
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
/// relative path would fail every call. `$`, a backquote, or a backslash also
/// falls back to `/tmp`, as a plain guard: the session quotes its path in the
/// shell text, so bash does not expand it, but an unusual temp root should not
/// reach that text at all.
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
/// to `max_bytes` when needed, then at most one status line, then the flags, then
/// `notices`, each on its own line. The caller frees the result.
fn formatResult(alloc: Allocator, snapshot: managed_execution.Snapshot, max_bytes: usize, notices: []const ?[]const u8) ![]u8 {
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
    try appendStatusLine(alloc, &out, snapshot);
    if (snapshot.output_truncated) try appendLine(alloc, &out, &.{"[some output was cut]"});
    if (snapshot.output_incomplete) try appendLine(alloc, &out, &.{"[some output could not be read]"});
    for (notices) |notice| {
        if (notice) |text| try appendLine(alloc, &out, &.{text});
    }
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
    var digits: [max_decimal_bytes]u8 = undefined;
    try out.appendSlice(alloc, text[0..head_end]);
    try appendLine(alloc, out, &.{ "[... ", decimal(&digits, @intCast(tail_start - head_end)), " bytes cut ...]" });
    try appendLine(alloc, out, &.{text[tail_start..]});
}

/// Appends `parts` on their own line, first adding a line end when `out` does not
/// already end with one.
fn appendLine(alloc: Allocator, out: *std.ArrayList(u8), parts: []const []const u8) Allocator.Error!void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
    for (parts) |part| try out.appendSlice(alloc, part);
}

/// Appends the one status line for `snapshot`, when its state needs one.
fn appendStatusLine(alloc: Allocator, out: *std.ArrayList(u8), snapshot: managed_execution.Snapshot) Allocator.Error!void {
    var digits: [max_decimal_bytes]u8 = undefined;
    const no_output = snapshot.output_delta.len == 0;
    switch (snapshot.state) {
        .running => if (snapshot.running_ms) |ms| {
            try appendLine(alloc, out, &.{ "[still running after ", decimal(&digits, @intCast(ms / 1000)), " s. ", wait_hint, "]" });
        } else {
            try appendLine(alloc, out, &.{"[still running. " ++ wait_hint ++ "]"});
        },
        .completed => |status| switch (status) {
            .exit_code => |code| if (code != 0) {
                try appendLine(alloc, out, &.{ "[exit ", decimal(&digits, code), "]" });
            } else if (no_output) {
                try appendLine(alloc, out, &.{"[done, no output]"});
            },
            .finished => if (no_output) try appendLine(alloc, out, &.{"[done, no output]"}),
            .signal => |signal| try appendLine(alloc, out, &.{ "[killed by signal ", decimal(&digits, @intCast(signal)), "]" }),
            .indeterminate => try appendLine(alloc, out, &.{"[ended; exit status unknown]"}),
        },
        .stopped => try appendLine(alloc, out, &.{"[stopped]"}),
        .lost => try appendLine(alloc, out, &.{"[fx lost this program]"}),
    }
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
        const got = try formatResult(alloc, snapshot, 4096, &.{});
        defer alloc.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "formatResult adds the cut and read flags on their own lines" {
    const alloc = std.testing.allocator;
    var snapshot = testSnapshot("ok\n", .{ .completed = .finished });
    snapshot.output_truncated = true;
    snapshot.output_incomplete = true;
    const got = try formatResult(alloc, snapshot, 4096, &.{});
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
    const got = try formatResult(alloc, snapshot, 2048, &.{});
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
        formatResult(std.testing.allocator, testSnapshot("x", .{ .completed = .finished }), 100, &.{}),
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
        _ = self.session.deinit(self.io);
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

    /// Writes `text` as the session's save record, as a program's save leaves one.
    fn writeSaveRecord(self: *TestBash, text: []const u8) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.session.dir.?, .{});
        defer dir.close(self.io);
        try dir.writeFile(self.io, .{ .sub_path = "save-status", .data = text });
    }

    /// Replaces the session folder's entry `name` with a FIFO, as a stray program can.
    fn makeSessionFifo(self: *TestBash, name: []const u8) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.session.dir.?, .{});
        defer dir.close(self.io);
        try dir.deleteFile(self.io, name);
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.mem.printSentinel(&path_buffer, "{s}/{s}", .{ self.session.dir.?, name }, 0);
        if (mkfifo(path, 0o600) != 0) return error.MkfifoFailed;
    }

    /// Replaces the session folder's entry `name` with a directory that holds a file, as a stray program can.
    fn makeSessionDir(self: *TestBash, name: []const u8) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.session.dir.?, .{});
        defer dir.close(self.io);
        try dir.deleteFile(self.io, name);
        try dir.createDirPath(self.io, name);
        var sub = try dir.openDir(self.io, name, .{});
        defer sub.close(self.io);
        try sub.writeFile(self.io, .{ .sub_path = "inside", .data = "keep\n" });
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

test "an over-cap program says so in its result, and the next program keeps the last saved state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    try bash.authorize(&ctx, "x=41");
    const first = try callRun(ctx, "x=41", program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    // The program ends with `exit 0`, so its own end is the only place its save can run.
    const big_command = "big=$(head -c 1100000 /dev/zero | tr '\\0' a); exit 0";
    try bash.authorize(&ctx, big_command);
    const big = try callRun(ctx, big_command, program_yield_ms);
    defer big.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(big, true), "over the 1048576-byte limit, so it was not saved; the next program starts from the last saved state.") != null);

    try bash.authorize(&ctx, "echo $((x+1))");
    const second = try callRun(ctx, "echo $((x+1))", program_yield_ms);
    defer second.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, try outcomeText(second, true), "42"));
}

test "an over-cap program logs why its state was not saved" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    const big_command = "big=$(head -c 1100000 /dev/zero | tr '\\0' a); exit 0";
    try bash.authorize(&ctx, big_command);
    const big = try callRun(ctx, big_command, program_yield_ms);
    defer big.deinit(alloc);

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash state not saved: reason=over_cap") != null);
}

test "a program that sets IFS to a tab keeps its state, and its result has no notice" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    const first_command = "IFS=$'\\t'; x=1";
    try bash.authorize(&ctx, first_command);
    const first = try callRun(ctx, first_command, program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    try bash.authorize(&ctx, "echo \"x=$x\"");
    const second = try callRun(ctx, "echo \"x=$x\"", program_yield_ms);
    defer second.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, try outcomeText(second, true), "x=1"));
}

test "a save record a program left unseen is reported with the next program's result" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    // The first call makes the session folder, which the record goes in.
    try bash.authorize(&ctx, "x=1");
    const first = try callRun(ctx, "x=1", program_yield_ms);
    defer first.deinit(alloc);

    try bash.writeSaveRecord("cap 2000000\n");
    try bash.authorize(&ctx, "echo next");
    const next = try callRun(ctx, "echo next", program_yield_ms);
    defer next.deinit(alloc);
    const text = try outcomeText(next, true);
    try std.testing.expect(std.mem.startsWith(u8, text, "next\n"));
    try std.testing.expect(std.mem.find(u8, text, "fx: the previous program's bash state was 2000000 bytes, over the 1048576-byte limit, so it was not saved; the last saved state stays.") != null);

    // A record left after the program that followed is reported by the call after it.
    try bash.writeSaveRecord("failed\n");
    try bash.authorize(&ctx, "echo later");
    const later = try callRun(ctx, "echo later", program_yield_ms);
    defer later.deinit(alloc);
    const later_text = try outcomeText(later, true);
    try std.testing.expect(std.mem.find(u8, later_text, "fx: the previous program's bash state could not be saved; the last saved state stays.") != null);

    // A program that ended without its save leaves `pending`, and the call after it reports that.
    try bash.writeSaveRecord("pending\n");
    try bash.authorize(&ctx, "echo ended");
    const ended = try callRun(ctx, "echo ended", program_yield_ms);
    defer ended.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(ended, true), "fx: the previous program ended before fx could save its bash state, so it was not saved; the last saved state stays.") != null);
}

/// The notice for a program that ended before its save ran.
const not_saved_notice = "fx: this program ended before fx could save its bash state, so it was not saved; the next program starts from the last saved state.";

test "a program that runs trap - EXIT says so in its result, and the next program keeps the last saved state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    try bash.authorize(&ctx, "x=41");
    const first = try callRun(ctx, "x=41", program_yield_ms);
    defer first.deinit(alloc);

    const untrapped = "builtin trap - EXIT; x=42";
    try bash.authorize(&ctx, untrapped);
    const second = try callRun(ctx, untrapped, program_yield_ms);
    defer second.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(second, true), not_saved_notice) != null);

    try bash.authorize(&ctx, "echo \"x=$x\"");
    const third = try callRun(ctx, "echo \"x=$x\"", program_yield_ms);
    defer third.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, try outcomeText(third, true), "x=41"));
}

test "a program that runs exec says so in its result, and the next program keeps the last saved state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    try bash.authorize(&ctx, "x=41");
    const first = try callRun(ctx, "x=41", program_yield_ms);
    defer first.deinit(alloc);

    const replaced = "x=42; exec true";
    try bash.authorize(&ctx, replaced);
    const second = try callRun(ctx, replaced, program_yield_ms);
    defer second.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(second, true), not_saved_notice) != null);

    try bash.authorize(&ctx, "echo \"x=$x\"");
    const third = try callRun(ctx, "echo \"x=$x\"", program_yield_ms);
    defer third.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, try outcomeText(third, true), "x=41"));
}

test "a program killed with SIGKILL says so in its result, and the next program keeps the last saved state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    try bash.authorize(&ctx, "x=41");
    const first = try callRun(ctx, "x=41", program_yield_ms);
    defer first.deinit(alloc);

    const killed = "x=42; kill -9 $$";
    try bash.authorize(&ctx, killed);
    const second = try callRun(ctx, killed, program_yield_ms);
    defer second.deinit(alloc);
    const second_text = try outcomeText(second, false);
    try std.testing.expect(std.mem.find(u8, second_text, "[killed by signal 9]") != null);
    try std.testing.expect(std.mem.find(u8, second_text, not_saved_notice) != null);

    try bash.authorize(&ctx, "echo \"x=$x\"");
    const third = try callRun(ctx, "echo \"x=$x\"", program_yield_ms);
    defer third.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, try outcomeText(third, true), "x=41"));
}

test "a program that fx stops at its timeout says so in its result, and the next program keeps the last saved state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    try bash.authorize(&ctx, "x=41");
    const first = try callRun(ctx, "x=41", program_yield_ms);
    defer first.deinit(alloc);

    // A loop that never ends, so only the timeout ends it.
    const endless = "x=42; while :; do :; done";
    try bash.authorize(&ctx, endless);
    ctx.command_timeout_ms = 200;
    const second = try callRun(ctx, endless, program_yield_ms);
    defer second.deinit(alloc);
    ctx.command_timeout_ms = null;
    const second_text = switch (second) {
        .success => |body| body,
        .failure => |body| body,
        .rich => return error.TestUnexpectedOutcome,
    };
    try std.testing.expect(std.mem.find(u8, second_text, not_saved_notice) != null);

    try bash.authorize(&ctx, "echo \"x=$x\"");
    const third = try callRun(ctx, "echo \"x=$x\"", program_yield_ms);
    defer third.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, try outcomeText(third, true), "x=41"));
}

test "a program that sets xtrace shows its own lines and no line from the save" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();

    const traced = "set -x; y=1";
    try bash.authorize(&ctx, traced);
    const run = try callRun(ctx, traced, program_yield_ms);
    defer run.deinit(alloc);
    const text = try outcomeText(run, true);
    try std.testing.expect(std.mem.find(u8, text, "+ y=1") != null);
    // The bootstrap's own lines are not asserted here: every snapshot run has them.
    for ([_][]const u8{ "__fx_save", "__fx_keep", "__fx_status" }) |name| {
        try std.testing.expect(std.mem.find(u8, text, name) == null);
    }

    // xtrace is not part of the saved state, so the next program is not traced.
    try bash.authorize(&ctx, "echo \"y=$y\"");
    const next = try callRun(ctx, "echo \"y=$y\"", program_yield_ms);
    defer next.deinit(alloc);
    try std.testing.expectEqualStrings("y=1\n", try outcomeText(next, true));
}

test "a notice a previous program left goes into the result of a call that fails to start, and the trace says so" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.authorize(&ctx, "x=41");
    const first = try callRun(ctx, "x=41", program_yield_ms);
    defer first.deinit(alloc);

    // The record is written after the call that makes the session folder, as the leftover test does.
    try bash.writeSaveRecord("pending\n");
    // A yield above the ceiling makes startCaptured refuse before the program runs.
    try bash.authorize(&ctx, "echo never");
    const refused = try callRun(ctx, "echo never", managed_contract.max_wait_ceiling_ms + 1);
    defer refused.deinit(alloc);
    const refused_text = try outcomeText(refused, false);
    try std.testing.expect(std.mem.startsWith(u8, refused_text, "bash could not run the program: InvalidYieldTime."));
    try std.testing.expect(std.mem.find(u8, refused_text, "fx: the previous program ended before fx could save its bash state, so it was not saved; the last saved state stays.") != null);

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "the previous program's not-saved notice went with a start failure err=InvalidYieldTime") != null);

    // The refused call took the record, so the next call starts from the last saved state.
    try bash.authorize(&ctx, "echo \"x=$x\"");
    const next = try callRun(ctx, "echo \"x=$x\"", program_yield_ms);
    defer next.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, try outcomeText(next, true), "x=41"));
}

test "a saved folder that a program removed after its save is dropped: the next program starts in the workspace root, with a notice and a trace line" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    // The program saves its folder, then its own EXIT trap removes that folder, as in review r31.
    const target = try alloc.print("{s}/gone-target", .{bash.workspace});
    defer alloc.free(target);
    const program = try alloc.print("mkdir '{s}' && cd '{s}' && trap 'rm -rf \"$PWD\"' EXIT", .{ target, target });
    defer alloc.free(program);
    try bash.authorize(&ctx, program);
    const ended = try callRun(ctx, program, program_yield_ms);
    defer ended.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(ended, true));

    // The next program starts in the workspace root, its result says so, and the trace names the reason, never the path.
    try bash.authorize(&ctx, "pwd");
    const next = try callRun(ctx, "pwd", program_yield_ms);
    defer next.deinit(alloc);
    const next_text = try outcomeText(next, true);
    const workspace_line = try alloc.print("{s}\n", .{bash.workspace});
    defer alloc.free(workspace_line);
    try std.testing.expect(std.mem.startsWith(u8, next_text, workspace_line));
    try std.testing.expect(std.mem.find(u8, next_text, start_folder_notice) != null);

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "start folder dropped reason=gone") != null);
    try std.testing.expect(std.mem.find(u8, trace, target) == null);
}

test "a saved folder that is not an absolute path is a bad record: the next program starts in the workspace root, with a notice and a trace line" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.writeSessionFolder("relative/folder");
    try bash.authorize(&ctx, "pwd");
    const result = try callRun(ctx, "pwd", program_yield_ms);
    defer result.deinit(alloc);
    const text = try outcomeText(result, true);
    const workspace_line = try alloc.print("{s}\n", .{bash.workspace});
    defer alloc.free(workspace_line);
    try std.testing.expect(std.mem.startsWith(u8, text, workspace_line));
    try std.testing.expect(std.mem.find(u8, text, start_folder_notice) != null);

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "start folder dropped reason=bad_record") != null);
}

test "a fresh session with no saved folder gives no notice and no trace line" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.authorize(&ctx, "pwd");
    const result = try callRun(ctx, "pwd", program_yield_ms);
    defer result.deinit(alloc);
    const text = try outcomeText(result, true);
    const workspace_line = try alloc.print("{s}\n", .{bash.workspace});
    defer alloc.free(workspace_line);
    try std.testing.expect(std.mem.startsWith(u8, text, workspace_line));
    try std.testing.expect(std.mem.find(u8, text, start_folder_notice) == null);

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "start folder dropped") == null);
}

test "a startup record that is a FIFO is replaced before the next program, which then runs and keeps its state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.authorize(&ctx, "x=1");
    const first = try callRun(ctx, "x=1", program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    // A FIFO where the functions record is. The next program's shell writes that record with `>|`, which would wait on it.
    try bash.makeSessionFifo("startup-functions");
    try bash.authorize(&ctx, "echo \"x=$x\"");
    const second = try callRun(ctx, "echo \"x=$x\"", program_yield_ms);
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings("x=1\n", try outcomeText(second, true));

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash session healed what=record_replaced name=startup-functions") != null);
}

test "a session folder a program removes is made again: the next call says the state was lost and starts fresh, and the one after keeps its state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.authorize(&ctx, "x=1");
    const first = try callRun(ctx, "x=1", program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    // The program removes its own session folder by path, as in review r30.
    const remove = "rm -rf -- \"${__fx_state%/*}\"";
    try bash.authorize(&ctx, remove);
    const removed = try callRun(ctx, remove, program_yield_ms);
    defer removed.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(removed, true));

    // The next program finds no saved state, and its result says so, in the exact wording.
    const read = "echo \"x=${x-unset}\"";
    try bash.authorize(&ctx, read);
    const fresh = try callRun(ctx, read, program_yield_ms);
    defer fresh.deinit(alloc);
    const fresh_text = try outcomeText(fresh, true);
    try std.testing.expect(std.mem.startsWith(u8, fresh_text, "x=unset\n"));
    try std.testing.expect(std.mem.find(u8, fresh_text, "fx: the bash session's saved state was lost because its files were removed or replaced, so programs start from a fresh state.") != null);

    // The program after that saves a state, and the one after keeps it.
    try bash.authorize(&ctx, "x=2");
    const saved = try callRun(ctx, "x=2", program_yield_ms);
    defer saved.deinit(alloc);
    const again = "echo \"x=$x\"";
    try bash.authorize(&ctx, again);
    const kept = try callRun(ctx, again, program_yield_ms);
    defer kept.deinit(alloc);
    try std.testing.expectEqualStrings("x=2\n", try outcomeText(kept, true));

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash session healed what=state_lost name=session") != null);
}

test "a state file that is a FIFO is removed before the next program, which starts fresh with the state-lost notice, and the one after keeps its state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.authorize(&ctx, "x=1");
    const first = try callRun(ctx, "x=1", program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    // A FIFO where the saved state was. The next program's shell would wait on it.
    try bash.makeSessionFifo("state.sh");
    const read = "echo \"x=${x-unset}\"";
    try bash.authorize(&ctx, read);
    const fresh = try callRun(ctx, read, program_yield_ms);
    defer fresh.deinit(alloc);
    const fresh_text = try outcomeText(fresh, true);
    try std.testing.expect(std.mem.startsWith(u8, fresh_text, "x=unset\n"));
    try std.testing.expect(std.mem.find(u8, fresh_text, state_lost_notice) != null);

    // The program after that saves a state, which the one after it keeps with no notice.
    try bash.authorize(&ctx, "x=3");
    const saved = try callRun(ctx, "x=3", program_yield_ms);
    defer saved.deinit(alloc);
    const again = "echo \"x=$x\"";
    try bash.authorize(&ctx, again);
    const kept = try callRun(ctx, again, program_yield_ms);
    defer kept.deinit(alloc);
    try std.testing.expectEqualStrings("x=3\n", try outcomeText(kept, true));

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash session healed what=state_lost name=state.sh") != null);
}

test "an env file that is a FIFO is written again before the next program, which keeps its state and gets no state notice" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.authorize(&ctx, "x=1");
    const first = try callRun(ctx, "x=1", program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    // A FIFO where env.sh is. The next program's shell sources it, which would wait on it.
    try bash.makeSessionFifo("env.sh");
    const read = "echo \"x=$x\"";
    try bash.authorize(&ctx, read);
    const second = try callRun(ctx, read, program_yield_ms);
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings("x=1\n", try outcomeText(second, true));

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash session healed what=env_rewritten name=env.sh") != null);
}

test "a program's EXIT trap that puts a FIFO at the folder file gives the next call the folder notice once, and none after" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);

    // The program's save writes the folder file, then its EXIT trap replaces it with a FIFO, as review PROBE1 does.
    const replace = "trap '/bin/rm -f -- \"$__fx_folder\"; /usr/bin/mkfifo \"$__fx_folder\"' EXIT; x=1";
    try bash.authorize(&ctx, replace);
    const first = try callRun(ctx, replace, program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    // The call after the drop carries the folder notice, once.
    try bash.authorize(&ctx, "echo hi");
    const second = try callRun(ctx, "echo hi", program_yield_ms);
    defer second.deinit(alloc);
    const second_text = try outcomeText(second, true);
    try std.testing.expect(std.mem.startsWith(u8, second_text, "hi\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, second_text, start_folder_notice));

    // The call after that has no folder file to report.
    try bash.authorize(&ctx, "echo hi");
    const third = try callRun(ctx, "echo hi", program_yield_ms);
    defer third.deinit(alloc);
    try std.testing.expectEqualStrings("hi\n", try outcomeText(third, true));
}

test "a directory at the save record, made after the program's save, is replaced before the next program, which keeps its state and gets no save notice" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    // The program sets x and ends, so its save runs first. Then a directory with a file in it is put where the save record is, as a stray process can leave one after the save.
    const leave = "x=1";
    try bash.authorize(&ctx, leave);
    const left = try callRun(ctx, leave, program_yield_ms);
    defer left.deinit(alloc);
    try bash.makeSessionDir("save-status");

    // The next program keeps the state, and its result has no save notice.
    const read = "echo \"x=$x\"";
    try bash.authorize(&ctx, read);
    const next = try callRun(ctx, read, program_yield_ms);
    defer next.deinit(alloc);
    try std.testing.expectEqualStrings("x=1\n", try outcomeText(next, true));

    // The record is an empty owner-only regular file again, and the trace names it.
    var dir = try std.Io.Dir.cwd().openDir(bash.io, bash.session.dir.?, .{});
    defer dir.close(bash.io);
    const record = try dir.statFile(bash.io, "save-status", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, record.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), record.permissions.toMode() & 0o777);
    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash session healed what=record_replaced name=save-status") != null);
}

test "a program that leaves a directory at its save record gets no save notice, and the next program sees its state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);

    // The program puts a directory where its save record is, then sets x. Its own result has no save notice.
    const leave = "rm -f -- \"$__fx_status\"; mkdir -p \"$__fx_status/x\"; x=1";
    try bash.authorize(&ctx, leave);
    const left = try callRun(ctx, leave, program_yield_ms);
    defer left.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(left, true));

    // The next program sees x=1, and its result has no save notice either.
    const read = "echo \"x=$x\"";
    try bash.authorize(&ctx, read);
    const next = try callRun(ctx, read, program_yield_ms);
    defer next.deinit(alloc);
    try std.testing.expectEqualStrings("x=1\n", try outcomeText(next, true));
}

test "a directory at a startup record is replaced before the next program, which keeps its state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.authorize(&ctx, "x=1");
    const first = try callRun(ctx, "x=1", program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    // A directory where the functions record is, as a stray program can leave one.
    try bash.makeSessionDir("startup-functions");
    const read = "echo \"x=$x\"";
    try bash.authorize(&ctx, read);
    const second = try callRun(ctx, read, program_yield_ms);
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings("x=1\n", try outcomeText(second, true));

    var dir = try std.Io.Dir.cwd().openDir(bash.io, bash.session.dir.?, .{});
    defer dir.close(bash.io);
    const record = try dir.statFile(bash.io, "startup-functions", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, record.kind);
    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash session healed what=record_replaced name=startup-functions") != null);
}

test "a program that puts a FIFO where its save record is returns its own result with no save notice, and the next program sees its state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);

    // The program replaces its own save record with a FIFO, then sets x. The call must return, not wait on the FIFO.
    const replace = "rm -f -- \"$__fx_status\"; /usr/bin/mkfifo \"$__fx_status\"; x=1";
    try bash.authorize(&ctx, replace);
    const first = try callRun(ctx, replace, program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    const read = "echo \"x=$x\"";
    try bash.authorize(&ctx, read);
    const second = try callRun(ctx, read, program_yield_ms);
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings("x=1\n", try outcomeText(second, true));
}

test "a repair that cannot complete starts a fresh session: the next program has the state-lost notice and the trace, and the one after keeps its state" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.authorize(&ctx, "x=1");
    const first = try callRun(ctx, "x=1", program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    // env.sh is removed, and the folder is read-only, so the repair cannot write env.sh.
    var old = try std.Io.Dir.cwd().openDir(bash.io, bash.session.dir.?, .{ .iterate = true });
    defer old.close(bash.io);
    try old.deleteFile(bash.io, "env.sh");
    try old.setPermissions(bash.io, std.Io.File.Permissions.fromMode(0o500));
    defer old.setPermissions(bash.io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: the mode is restored only so the temporary directory can be removed.
    // Root or a DAC-override user writes into the read-only folder, so the repair would not fail: skip.
    if (old.createFile(bash.io, "mode-probe", .{ .exclusive = true })) |probe| {
        probe.close(bash.io);
        return error.SkipZigTest;
    } else |_| {}

    // The next program runs in a fresh session, and its result says the state was lost.
    const read = "echo \"x=${x-unset}\"";
    try bash.authorize(&ctx, read);
    const fresh = try callRun(ctx, read, program_yield_ms);
    defer fresh.deinit(alloc);
    const fresh_text = try outcomeText(fresh, true);
    try std.testing.expect(std.mem.startsWith(u8, fresh_text, "x=unset\n"));
    try std.testing.expect(std.mem.find(u8, fresh_text, state_lost_notice) != null);

    // The program after it saves a state, and the one after that keeps it.
    try bash.authorize(&ctx, "x=3");
    const saved = try callRun(ctx, "x=3", program_yield_ms);
    defer saved.deinit(alloc);
    const again = "echo \"x=$x\"";
    try bash.authorize(&ctx, again);
    const kept = try callRun(ctx, again, program_yield_ms);
    defer kept.deinit(alloc);
    try std.testing.expectEqualStrings("x=3\n", try outcomeText(kept, true));

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash session repair failed err=") != null);
    try std.testing.expect(std.mem.find(u8, trace, "bash session healed what=state_lost name=session") != null);
}

test "a repair that cannot complete, with no new folder either, fails the call with the session text, and the program does not run" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    try bash.authorize(&ctx, "x=1");
    const first = try callRun(ctx, "x=1", program_yield_ms);
    defer first.deinit(alloc);
    try std.testing.expectEqualStrings("[done, no output]", try outcomeText(first, true));

    // The old folder is read-only without env.sh, and the workspace is read-only, so no folder can be made.
    var old = try std.Io.Dir.cwd().openDir(bash.io, bash.session.dir.?, .{ .iterate = true });
    defer old.close(bash.io);
    try old.deleteFile(bash.io, "env.sh");
    try old.setPermissions(bash.io, std.Io.File.Permissions.fromMode(0o500));
    defer old.setPermissions(bash.io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: the mode is restored only so the temporary directory can be removed.
    // Opened for iteration, so the handle is a real descriptor that setPermissions and access can use.
    var workspace = try std.Io.Dir.cwd().openDir(bash.io, bash.workspace, .{ .iterate = true });
    defer workspace.close(bash.io);
    try workspace.setPermissions(bash.io, std.Io.File.Permissions.fromMode(0o500));
    defer workspace.setPermissions(bash.io, std.Io.File.Permissions.fromMode(0o700)) catch {}; // Best effort: the mode is restored only so the temporary directory can be removed.
    // Root or a DAC-override user writes into the read-only folder, so the call would not fail: skip.
    if (old.createFile(bash.io, "mode-probe", .{ .exclusive = true })) |probe| {
        probe.close(bash.io);
        return error.SkipZigTest;
    } else |_| {}

    const marker = "ran.txt";
    const program = try alloc.print("echo ran > '{s}/{s}'", .{ bash.workspace, marker });
    defer alloc.free(program);
    try bash.authorize(&ctx, program);
    const refused = try callRun(ctx, program, program_yield_ms);
    defer refused.deinit(alloc);
    const text = try outcomeText(refused, false);
    try std.testing.expect(std.mem.startsWith(u8, text, "fx: bash could not make a folder for its session ("));
    try std.testing.expect(std.mem.endsWith(u8, text, "), so this program did not run."));
    try std.testing.expect(std.mem.find(u8, text, bash.workspace) == null);
    // Looking up the marker needs no write access, so its absence is checked while the workspace is read-only.
    try std.testing.expectError(error.FileNotFound, workspace.access(bash.io, marker, .{}));

    // The workspace is writable again. The next call makes a folder, and its heal retries the old folder, which is
    // still read-only, so the removal reaches it. Its program says the state was lost, and the one after keeps its state.
    try workspace.setPermissions(bash.io, std.Io.File.Permissions.fromMode(0o700));
    try bash.authorize(&ctx, "x=2");
    const started = try callRun(ctx, "x=2", program_yield_ms);
    defer started.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, try outcomeText(started, true), state_lost_notice) != null);
    const read_again = "echo \"x=$x\"";
    try bash.authorize(&ctx, read_again);
    const kept = try callRun(ctx, read_again, program_yield_ms);
    defer kept.deinit(alloc);
    try std.testing.expectEqualStrings("x=2\n", try outcomeText(kept, true));

    const trace = try std.Io.Dir.cwd().readFileAlloc(bash.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash session healed what=state_lost name=session") != null);
}

test "a refused call carries the folder notice, since the folder it was approved for was dropped" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);

    // The session keeps a folder, and the next program is approved to start in it.
    try bash.tmp.dir.createDirPath(bash.io, "refused-target");
    const target = try alloc.print("{s}/refused-target", .{bash.workspace});
    defer alloc.free(target);
    try bash.writeSessionFolder(target);
    refreshFolder(&bash.session);
    try std.testing.expect(!bash.session.takeFolderDropped());
    try bash.authorize(&ctx, "pwd");

    // The folder is removed before the call, so the call drops it and no longer matches its approval.
    try bash.tmp.dir.deleteTree(bash.io, "refused-target");
    const refused = try callRun(ctx, "pwd", program_yield_ms);
    defer refused.deinit(alloc);
    const text = try outcomeText(refused, false);
    try std.testing.expect(std.mem.startsWith(u8, text, folder_changed_text));
    try std.testing.expect(std.mem.find(u8, text, start_folder_notice) != null);
}

test "a failed start carries the folder notice too" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    _ = try bash.session.prepare(bash.io, bash.workspace, &fx_variables);

    // A folder file that is not a usable path: the next call drops it, and starts in the workspace root.
    try bash.writeSessionFolder("relative/folder");
    try bash.authorize(&ctx, "echo never");
    // A yield above the ceiling makes startCaptured refuse before the program runs.
    const failed = try callRun(ctx, "echo never", managed_contract.max_wait_ceiling_ms + 1);
    defer failed.deinit(alloc);
    const text = try outcomeText(failed, false);
    try std.testing.expect(std.mem.startsWith(u8, text, "bash could not run the program: InvalidYieldTime."));
    try std.testing.expect(std.mem.find(u8, text, start_folder_notice) != null);
}

test "the folder notice says programs start in the workspace root until one saves a new folder" {
    try std.testing.expectEqualStrings(
        "fx: the bash session's saved folder could not be used, so programs start in the workspace root until one saves a new folder.",
        start_folder_notice,
    );
}

test "a program that ends before its save logs reason not_saved" {
    const alloc = std.testing.allocator;
    var bash = try TestBash.init(alloc);
    defer bash.deinit();
    var ctx = bash.context();
    const trace_path = try alloc.print("{s}/trace.log", .{bash.workspace});
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    defer debug_trace.resetForTest();

    const untrapped = "builtin trap - EXIT; x=1";
    try bash.authorize(&ctx, untrapped);
    const run = try callRun(ctx, untrapped, program_yield_ms);
    defer run.deinit(alloc);

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(1 << 16));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "bash state not saved: reason=not_saved bytes=0") != null);
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
    _ = bash.session.refreshStartFolder(bash.io);
    try bash.authorize(&ctx, "pwd");
    const pwd = try callRun(ctx, "pwd", program_yield_ms);
    defer pwd.deinit(alloc);
    const expected = try alloc.print("{s}\n", .{bash.workspace});
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, try outcomeText(pwd, true));
}
