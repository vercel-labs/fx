const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const command_contract = @import("../execution/command_contract.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const background_launch_identity = @import("../background/background_launch_identity.zig");
const background_runtime = @import("../background/background_runtime.zig");
const tool_result_errors = @import("tool_result_errors.zig");

const Allocator = std.mem.Allocator;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;

pub const Foreground = struct {
    pub fn cancelledFailure(
        arena: Allocator,
        result: command_contract.RunCommandResult,
    ) !?ToolExecutionResult {
        if (!result.cancelled) return null;
        const command_result_json = if (result.command_result) |command_result|
            command_result.toJson(arena) catch |err| {
                debug_trace.logf("tool", "cancelled command result metadata omitted err={s}", .{@errorName(err)});
                return error.Cancelled;
            }
        else
            null;
        return .{
            .status = .failure,
            .cancelled = true,
            .model_output = "command cancelled\n",
            .command_result_json = command_result_json,
        };
    }

    pub fn nonZeroFailure(
        arena: Allocator,
        result: command_contract.RunCommandResult,
    ) !?ToolExecutionResult {
        const command_result = result.command_result orelse return null;
        const foreground = switch (command_result) {
            .foreground => |foreground| foreground,
            .background => return null,
        };
        if ((foreground.exit_code == null or foreground.exit_code.? == 0) and
            foreground.signal == null and
            !foreground.timed_out) return null;

        var details: [6]tool_result_errors.Detail = undefined;
        var count: usize = 0;
        details[count] = .{ .name = "command", .value = .{ .string = foreground.command } };
        count += 1;
        details[count] = .{ .name = "cwd", .value = .{ .string = foreground.cwd } };
        count += 1;
        if (foreground.exit_code) |code| {
            details[count] = .{ .name = "exit_code", .value = .{ .integer = code } };
            count += 1;
        }
        if (foreground.signal) |signal| {
            details[count] = .{ .name = "signal", .value = .{ .unsigned = signal } };
            count += 1;
        }
        const stderr_text = extractEnvelope(result.output, "<stderr>\n", "\n</stderr>");
        if (stderr_text.len > 0) {
            details[count] = .{ .name = "stderr", .value = .{ .string = stderr_text } };
            count += 1;
        }

        return .{
            .status = .failure,
            .model_output = try tool_result_errors.toolExecutionFailureJson(arena, .{
                .tool_name = "terminal",
                .message = if (foreground.exit_code != null) "Command exited with non-zero status" else "Command terminated before completing successfully",
                .details = details[0..count],
                .suggestion = "Inspect stderr and the command context, then fix the command or explain the blocker rather than retrying unchanged.",
            }),
            .command_result_json = try command_result.toJson(arena),
        };
    }

    pub fn timeoutFailure(
        arena: Allocator,
        command: []const u8,
        cwd: []const u8,
        timeout_ms: ?usize,
        started_ms: ?i64,
    ) !ToolExecutionResult {
        const output = if (timeout_ms) |ms|
            try std.fmt.allocPrint(arena, "timeout=true\ntimeout_ms={d}\ncommand timed out and was terminated\n", .{ms})
        else
            try arena.dupe(u8, "timeout=true\ncommand timed out and was terminated\n");
        return .{
            .status = .failure,
            .model_output = output,
            .command_result_json = try (command_contract.CommandResult{ .foreground = .{
                .command = command,
                .cwd = cwd,
                .timed_out = true,
                .duration_ms = if (started_ms) |started| elapsedMs(started, io_mod.milliTimestamp()) else null,
            } }).toJson(arena),
        };
    }
};

pub const Background = struct {
    pub fn persistenceUnavailableFailure(arena: Allocator) !ToolExecutionResult {
        const output = try arena.dupe(
            u8,
            "background_persistence_required=true\n" ++
                "background_persistence_available=false\n" ++
                "mode=headless\n" ++
                "reason=session_store_unavailable\n" ++
                "message=headless background commands require session persistence so they can be inspected after fx ask exits. Remove --no-save or restore access to the session store, then retry.\n",
        );
        return .{ .status = .failure, .model_output = output, .finish_turn = true, .system_notice = output };
    }

    pub fn launchPreparationFailure(arena: Allocator, err: anyerror) !ToolExecutionResult {
        const output = try std.fmt.allocPrint(
            arena,
            "background_launch_failed=true\n" ++
                "error={s}\n" ++
                "message=background launch preparation failed before a job was started.\n",
            .{@errorName(err)},
        );
        return .{
            .status = .failure,
            .model_output = output,
            .finish_turn = true,
            .system_notice = output,
            .interactive_notice = .{
                .topic = "background",
                .tone = .@"error",
                .body = try std.fmt.allocPrint(
                    arena,
                    "Command launch preparation failed ({s}).",
                    .{@errorName(err)},
                ),
            },
        };
    }

    pub fn persistenceSaveFailure(
        arena: Allocator,
        err: anyerror,
        launch_identity_fields: []const u8,
    ) !ToolExecutionResult {
        const identity_fields = switch (err) {
            error.BackgroundTerminationIndeterminate,
            error.BackgroundProcessIdentityIndeterminate,
            => launch_identity_fields,
            else => "",
        };
        const details = switch (err) {
            error.BackgroundPersistenceRequired => "background_persistence_required=true\n" ++
                "background_started=true\n" ++
                "background_stopped=true\n" ++
                "reason=metadata_persist_failed\n" ++
                "message=headless background command metadata could not be confirmed, so the launched job was stopped instead of being reported as manageable.\n",
            error.BackgroundTerminationIndeterminate => "background_termination_indeterminate=true\n" ++
                "background_started=true\n" ++
                "background_stopped=unknown\n" ++
                "reason=termination_unconfirmed\n" ++
                "message=headless background command metadata could not be confirmed and termination could not be confirmed; the job may still be running.\n",
            error.BackgroundProcessIdentityIndeterminate => "background_process_identity_indeterminate=true\n" ++
                "background_command_released=false\n" ++
                "background_stopped=unknown\n" ++
                "reason=wrapper_cleanup_unconfirmed\n" ++
                "message=background wrapper cleanup could not be confirmed; the command was not reported as released and the wrapper process may still exist.\n",
            else => "background_launch_failed=true\n" ++
                "background_started=false\n" ++
                "reason=launch_failed\n" ++
                "message=background launch failed before a manageable job was confirmed.\n",
        };
        const output = try std.fmt.allocPrint(
            arena,
            "mode=headless\n" ++
                "error={s}\n" ++
                "{s}" ++
                "{s}",
            .{ @errorName(err), identity_fields, details },
        );
        const interactive_body = switch (err) {
            error.BackgroundPersistenceRequired => try arena.dupe(
                u8,
                "Command metadata could not be saved; the launched job was stopped.",
            ),
            error.BackgroundTerminationIndeterminate => try arena.dupe(
                u8,
                "Command metadata could not be saved; whether the launched job stopped could not be confirmed.",
            ),
            error.BackgroundProcessIdentityIndeterminate => try arena.dupe(
                u8,
                "Command cleanup could not be confirmed; the wrapper process may still exist.",
            ),
            else => try std.fmt.allocPrint(
                arena,
                "Command launch failed before a manageable job was confirmed ({s}).",
                .{@errorName(err)},
            ),
        };
        return .{
            .status = .failure,
            .model_output = output,
            .finish_turn = true,
            .system_notice = output,
            .interactive_notice = .{
                .topic = "background",
                .tone = .@"error",
                .body = interactive_body,
            },
        };
    }

    pub fn launchFailure(arena: Allocator, err: anyerror) !ToolExecutionResult {
        return .{ .model_output = try std.fmt.allocPrint(
            arena,
            "background launch failed\nreason={s}",
            .{@errorName(err)},
        ) };
    }

    pub fn fromTaskSnapshot(
        arena: Allocator,
        task: background_runtime.TaskSnapshot,
    ) !command_contract.BackgroundCommand {
        return .{
            .pid = try arena.dupe(u8, task.pid),
            .command = try arena.dupe(u8, task.command),
            .cwd = try arena.dupe(u8, task.cwd),
            .log_path = try arena.dupe(u8, task.log_path),
            .url = if (task.server_url) |url| try arena.dupe(u8, url) else null,
            .expect_url = task.expect_url,
        };
    }

    pub fn taskCommandResultJson(
        arena: Allocator,
        task: background_runtime.TaskSnapshot,
        state: []const u8,
    ) ![]const u8 {
        return (command_contract.CommandResult{ .background = .{
            .command = task.command,
            .cwd = task.cwd,
            .background_id = task.id,
            .pid = task.pid,
            .log_path = task.log_path,
            .state = state,
            .server_url = task.server_url,
        } }).toJson(arena);
    }

    pub fn commandResultJson(
        arena: Allocator,
        background: command_contract.BackgroundCommand,
        background_id: u64,
        state: []const u8,
    ) ![]const u8 {
        return (command_contract.CommandResult{ .background = .{
            .command = background.command,
            .cwd = background.cwd,
            .background_id = background_id,
            .pid = background.pid,
            .log_path = background.log_path,
            .state = state,
            .server_url = background.url,
        } }).toJson(arena);
    }

    pub fn formatReuseOutput(arena: Allocator, task: background_runtime.TaskSnapshot) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();

        try out.writer.writeAll("reused existing background command\n");
        try out.writer.print("id={d}\n", .{task.id});
        try out.writer.print("pid={s}\n", .{task.pid});
        try out.writer.print("log={s}\n", .{task.log_path});
        if (task.server_url) |url| {
            try out.writer.print("url={s}\n", .{url});
        }
        return try out.toOwnedSlice();
    }

    pub fn formatReuseNotice(arena: Allocator, task: background_runtime.TaskSnapshot) ![]const u8 {
        if (task.server_url) |url| {
            return std.fmt.allocPrint(arena, "Background #{d}: reusing running server at {s}", .{ task.id, url });
        }
        if (task.expect_url) {
            return std.fmt.allocPrint(arena, "Background #{d}: reusing running server. Waiting for local URL.", .{task.id});
        }
        return std.fmt.allocPrint(arena, "Background #{d}: reusing running command. Log: {s}", .{ task.id, task.log_path });
    }

    pub fn interactiveReuseNotice(arena: Allocator, task: background_runtime.TaskSnapshot) !types.SemanticNotice {
        const body = if (task.server_url) |url|
            try std.fmt.allocPrint(arena, "Command #{d} reused. Server: {s}.", .{ task.id, url })
        else if (task.expect_url)
            try std.fmt.allocPrint(arena, "Command #{d} reused. Waiting for local URL.", .{task.id})
        else
            try std.fmt.allocPrint(arena, "Command #{d} reused. Log: {s}", .{ task.id, task.log_path });
        return .{
            .topic = "background",
            .tone = .neutral,
            .body = body,
        };
    }
};

fn extractEnvelope(output: []const u8, open: []const u8, close: []const u8) []const u8 {
    const start = std.mem.find(u8, output, open) orelse return "";
    const body = output[start + open.len ..];
    const end = std.mem.find(u8, body, close) orelse return "";
    return body[0..end];
}

fn elapsedMs(started_ms: i64, finished_ms: i64) u64 {
    return if (finished_ms > started_ms) @intCast(finished_ms - started_ms) else 0;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn freeBackgroundCommand(alloc: Allocator, background: command_contract.BackgroundCommand) void {
    alloc.free(background.pid);
    alloc.free(background.command);
    alloc.free(background.cwd);
    alloc.free(background.log_path);
    if (background.url) |url| alloc.free(url);
}

test "command result mapping preserves non-zero stderr envelope and JSON" {
    const alloc = std.testing.allocator;
    const result = try Foreground.nonZeroFailure(alloc, .{
        .output = "<stderr>\nbad [redacted]\n</stderr>",
        .command_result = .{ .foreground = .{
            .command = "printf bad >&2; exit 7",
            .cwd = "/tmp/workspace",
            .exit_code = 7,
            .stderr_bytes = 15,
        } },
    }) orelse return error.TestExpectedEqual;
    defer alloc.free(result.model_output);
    defer alloc.free(result.command_result_json.?);

    try expectContains(result.model_output, "Command exited with non-zero status");
    try expectContains(result.model_output, "\"stderr\":\"bad [redacted]\"");
    try expectContains(result.command_result_json.?, "\"kind\":\"foreground\"");
    try expectContains(result.command_result_json.?, "\"exit_code\":7");
}

test "cancelled command mapping survives metadata serialization failure" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.Cancelled,
        Foreground.cancelledFailure(failing.allocator(), .{
            .output = "ignored",
            .cancelled = true,
            .command_result = .{ .foreground = .{
                .command = "sleep 5",
                .cwd = "/tmp",
            } },
        }),
    );
}

test "command result mapping preserves timeout JSON" {
    const alloc = std.testing.allocator;
    const timeout = try Foreground.timeoutFailure(
        alloc,
        "sleep 5",
        "/tmp/workspace",
        5,
        null,
    );
    defer alloc.free(timeout.model_output);
    defer alloc.free(timeout.command_result_json.?);
    try std.testing.expectEqualStrings(
        "timeout=true\ntimeout_ms=5\ncommand timed out and was terminated\n",
        timeout.model_output,
    );
    try expectContains(timeout.command_result_json.?, "\"timed_out\":true");
}

test "command result mapping projects background reuse output and JSON" {
    const alloc = std.testing.allocator;
    var pid = [_]u8{ '4', '2' };
    var command = [_]u8{ 'n', 'p', 'm', ' ', 'r', 'u', 'n', ' ', 'd', 'e', 'v' };
    var cwd = [_]u8{ '/', 't', 'm', 'p' };
    var log_path = [_]u8{ '/', 't', 'm', 'p', '/', 's', 'e', 'r', 'v', 'e', 'r', '.', 'l', 'o', 'g' };
    var url = [_]u8{ 'h', 't', 't', 'p', ':', '/', '/', 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't', ':', '4', '2', '0', '0' };
    const task = background_runtime.TaskSnapshot{
        .id = 9,
        .pid = pid[0..],
        .command = command[0..],
        .cwd = cwd[0..],
        .log_path = log_path[0..],
        .expect_url = true,
        .server_url = url[0..],
        .started_at_ms = 0,
        .state = .running,
    };

    const background = try Background.fromTaskSnapshot(alloc, task);
    defer freeBackgroundCommand(alloc, background);
    const output = try Background.formatReuseOutput(alloc, task);
    defer alloc.free(output);
    const notice = try Background.formatReuseNotice(alloc, task);
    defer alloc.free(notice);
    const interactive_notice = try Background.interactiveReuseNotice(alloc, task);
    defer alloc.free(interactive_notice.body);
    const json = try Background.taskCommandResultJson(alloc, task, "running");
    defer alloc.free(json);
    const started_json = try Background.commandResultJson(alloc, background, 10, "running");
    defer alloc.free(started_json);

    try expectContains(output, "reused existing background command\n");
    try expectContains(output, "url=http://localhost:4200\n");
    try std.testing.expectEqualStrings("npm run dev", background.command);
    try std.testing.expectEqualStrings("Background #9: reusing running server at http://localhost:4200", notice);
    try std.testing.expectEqualStrings("background", interactive_notice.topic);
    try std.testing.expectEqual(types.NoticeTone.neutral, interactive_notice.tone);
    try std.testing.expectEqualStrings("Command #9 reused. Server: http://localhost:4200.", interactive_notice.body);
    try std.testing.expect(std.mem.find(u8, interactive_notice.body, "Background") == null);
    try expectContains(json, "\"background_id\":9");
    try expectContains(json, "\"state\":\"running\"");
    try expectContains(started_json, "\"background_id\":10");
}

test "saved-headless background failures distinguish confirmed and indeterminate outcomes" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source_session_id = try alloc.dupe(u8, "session-plan-06");
    defer alloc.free(source_session_id);
    const identity = background_launch_identity.Identity{
        .saved_headless = .{
            .display_id = 41,
            .source_session_id = source_session_id,
            .background_record_id = .{
                0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
            },
        },
    };
    const identity_fields = try background_launch_identity.format(
        arena,
        identity,
    );

    const confirmed = try Background.persistenceSaveFailure(
        arena,
        error.BackgroundPersistenceRequired,
        identity_fields,
    );
    try expectContains(confirmed.model_output, "background_started=true\n");
    try expectContains(confirmed.model_output, "background_stopped=true\n");
    try expectContains(confirmed.model_output, "was stopped");
    try std.testing.expect(std.mem.find(u8, confirmed.model_output, "source_session_id=") == null);
    try std.testing.expect(std.mem.find(u8, confirmed.model_output, "background_record_id=") == null);
    const confirmed_notice = confirmed.interactive_notice orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("background", confirmed_notice.topic);
    try std.testing.expectEqual(types.NoticeTone.@"error", confirmed_notice.tone);
    try std.testing.expectEqualStrings(
        "Command metadata could not be saved; the launched job was stopped.",
        confirmed_notice.body,
    );

    const termination = try Background.persistenceSaveFailure(
        arena,
        error.BackgroundTerminationIndeterminate,
        identity_fields,
    );
    try expectContains(termination.model_output, "background_termination_indeterminate=true\n");
    try expectContains(termination.model_output, "background_stopped=unknown\n");
    try expectContains(termination.model_output, "launch_policy=saved_headless\n");
    try expectContains(termination.model_output, "display_id=41\n");
    try expectContains(termination.model_output, "source_session_id=session-plan-06\n");
    try expectContains(termination.model_output, "background_record_id=000102030405060708090a0b0c0d0e0f\n");
    try std.testing.expect(std.mem.find(u8, termination.model_output, "was stopped") == null);
    const termination_notice = termination.interactive_notice orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("background", termination_notice.topic);
    try std.testing.expectEqual(types.NoticeTone.@"error", termination_notice.tone);
    try std.testing.expectEqualStrings(
        "Command metadata could not be saved; whether the launched job stopped could not be confirmed.",
        termination_notice.body,
    );

    const identity_indeterminate = try Background.persistenceSaveFailure(
        arena,
        error.BackgroundProcessIdentityIndeterminate,
        identity_fields,
    );
    try expectContains(identity_indeterminate.model_output, "background_process_identity_indeterminate=true\n");
    try expectContains(identity_indeterminate.model_output, "background_command_released=false\n");
    try expectContains(identity_indeterminate.model_output, "background_stopped=unknown\n");
    try expectContains(identity_indeterminate.model_output, "launch_policy=saved_headless\n");
    try std.testing.expect(std.mem.find(u8, identity_indeterminate.model_output, "was stopped") == null);
    const identity_notice = identity_indeterminate.interactive_notice orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("background", identity_notice.topic);
    try std.testing.expectEqual(types.NoticeTone.@"error", identity_notice.tone);
    try std.testing.expectEqualStrings(
        "Command cleanup could not be confirmed; the wrapper process may still exist.",
        identity_notice.body,
    );
}

test "background launch preparation failure preserves raw output and adds semantic error projection" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();

    const result = try Background.launchPreparationFailure(
        arena_state.allocator(),
        error.TestLaunchPreparationFailure,
    );
    const expected_raw =
        "background_launch_failed=true\n" ++
        "error=TestLaunchPreparationFailure\n" ++
        "message=background launch preparation failed before a job was started.\n";
    try std.testing.expectEqualStrings(expected_raw, result.model_output);
    try std.testing.expectEqualStrings(expected_raw, result.system_notice.?);
    const notice = result.interactive_notice orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("background", notice.topic);
    try std.testing.expectEqual(types.NoticeTone.@"error", notice.tone);
    try std.testing.expectEqualStrings(
        "Command launch preparation failed (TestLaunchPreparationFailure).",
        notice.body,
    );

    const launch_failure = try Background.launchFailure(
        arena_state.allocator(),
        error.TestLaunchFailure,
    );
    try std.testing.expect(launch_failure.system_notice == null);
    try std.testing.expect(launch_failure.interactive_notice == null);
}
