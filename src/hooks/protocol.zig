//! Builds the JSON fx writes to a hook's stdin, and reads what a command hook
//! printed into the answer fx acts on.

const std = @import("std");
const event = @import("event.zig");
const answer = @import("answer.zig");

/// What a command hook left behind when it exited.
const Exit = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Builds the JSON object fx writes to a hook's stdin. The caller owns the result.
pub fn buildInput(alloc: std.mem.Allocator, ev: event.Event) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    writeInputObject(&json, ev) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

fn writeInputObject(json: *std.json.Stringify, ev: event.Event) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("session_id");
    try json.write(ev.scope.session_id);
    try json.objectField("transcript_path");
    try json.write(ev.scope.transcript_path);
    try json.objectField("cwd");
    try json.write(ev.scope.cwd);
    try json.objectField("permission_mode");
    try json.write(ev.scope.permission_mode);
    try json.objectField("hook_event_name");
    try json.write(ev.name.fileName());
    try json.objectField("fx_surface");
    try json.write(@tagName(ev.scope.surface));
    if (ev.scope.turn_id) |turn| {
        try json.objectField("fx_turn_id");
        try json.write(turn);
    }
    if (ev.scope.subagent_id) |subagent| {
        try json.objectField("agent_id");
        var buffer: [20]u8 = undefined;
        const text = std.mem.print(&buffer, "{d}", .{subagent}) catch unreachable;
        try json.write(text);
    }
    for (ev.fields) |field| {
        try json.objectField(field.key);
        switch (field.value) {
            .string => |text| try json.write(text),
            .json => |raw| {
                try json.beginWriteRaw();
                try json.writer.writeAll(raw);
                json.endWriteRaw();
            },
            .boolean => |flag| try json.write(flag),
            .integer => |number| try json.write(number),
            .null_value => try json.write(null),
        }
    }
    try json.endObject();
}

/// What a shell prints when `sh <script>` cannot open the script. dash says "No such file",
/// bash says "No such file or directory", and older dash says "Can't open". A Stop hook whose
/// script is missing exits 2 with one of these, and that must stay a failure, not a continue.
const missing_script_texts = [_][]const u8{ "No such file", "Can't open" };

/// The first line of `text`, without the white space around it. Borrows `text`.
pub fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed[0..(std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len)];
}

/// Whether stderr names a script that the shell could not open.
fn namesMissingScript(err: []const u8) bool {
    for (missing_script_texts) |text| {
        if (std.mem.find(u8, err, text) != null) return true;
    }
    return false;
}

/// Reads what a command hook printed, following Claude Code's rules for `name`.
/// Slices in the result borrow `exit` or memory from `arena`, which must outlive the result.
pub fn readOutput(
    arena: std.mem.Allocator,
    name: event.EventName,
    on_failure: answer.OnFailure,
    exit: Exit,
) std.mem.Allocator.Error!answer.Result {
    const out = std.mem.trim(u8, exit.stdout, " \t\r\n");
    const err = std.mem.trim(u8, exit.stderr, " \t\r\n");
    const first_line = firstLine(err);
    const looks_json = out.len >= 2 and out[0] == '{' and out[out.len - 1] == '}';

    if (exit.code == 2) {
        if ((name == .stop or name == .subagent_stop) and out.len == 0 and namesMissingScript(err)) {
            return exitFailure(2, first_line);
        }
        return .{ .answer = exit2Answer(name, err) };
    }

    if (exit.code == 0) {
        if (looks_json) {
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{}) catch |caught| switch (caught) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalidOutput("stdout is not valid JSON"),
            };
            return jsonResult(arena, name, value);
        }
        if (out.len > 0 and takesPlainText(name)) {
            return .{ .answer = .{ .additional_context = out } };
        }
        return .{ .answer = .{} };
    }

    if (on_failure == .block) return exitFailure(exit.code, first_line);
    if (looks_json) {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{})) |value| {
            return jsonResult(arena, name, value);
        } else |caught| switch (caught) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
    }
    return exitFailure(exit.code, first_line);
}

/// The answer an exit code of 2 stands for on this event.
fn exit2Answer(name: event.EventName, err: []const u8) answer.Answer {
    switch (name) {
        .pre_tool_use, .permission_request, .user_prompt_submit, .instructions_loaded, .pre_compact, .config_change, .pre_model_switch => {
            return .{ .decision = .deny, .reason = if (err.len > 0) err else "blocked by a hook" };
        },
        .stop, .subagent_stop => {
            return .{ .continue_reason = if (err.len > 0) err else "A Stop hook asked fx to keep going." };
        },
        .post_tool_use, .post_tool_use_failure => {
            return .{ .additional_context = if (err.len > 0) err else null };
        },
        .post_tool_batch => {
            return .{ .stop_reason = if (err.len > 0) err else "A hook stopped the turn." };
        },
        else => return .{ .system_message = if (err.len > 0) err else null },
    }
}

/// Whether plain stdout text becomes added context for this event.
fn takesPlainText(name: event.EventName) bool {
    return switch (name) {
        .user_prompt_submit, .session_start, .post_model_switch, .pre_compact => true,
        else => false,
    };
}

fn invalidOutput(detail: []const u8) answer.Result {
    return .{ .failure = .{ .kind = .invalid_output, .detail = detail } };
}

fn exitFailure(code: u8, detail: []const u8) answer.Result {
    return .{ .failure = .{ .kind = .exit_code, .exit_code = code, .detail = detail } };
}

/// Turns one parsed JSON object on stdout into an answer.
fn jsonResult(
    arena: std.mem.Allocator,
    name: event.EventName,
    value: std.json.Value,
) std.mem.Allocator.Error!answer.Result {
    if (value != .object) return invalidOutput("stdout must be one JSON object");
    const object = value.object;
    var a = answer.Answer{};

    if (object.get("systemMessage")) |field| {
        if (field != .string) return invalidOutput("systemMessage must be a string");
        a.system_message = field.string;
    }

    if (object.get("continue")) |field| {
        if (field != .bool) return invalidOutput("continue must be a boolean");
        if (!field.bool and name != .stop and name != .subagent_stop) {
            if (object.get("stopReason")) |reason_field| {
                if (reason_field != .string) return invalidOutput("stopReason must be a string");
                a.stop_reason = reason_field.string;
            } else {
                a.stop_reason = "A hook stopped the turn.";
            }
        }
    }

    // "suppressOutput" is accepted and ignored.

    if (object.get("decision")) |field| {
        if (field != .string) return invalidOutput("decision must be a string");
        var reason: ?[]const u8 = null;
        if (object.get("reason")) |reason_field| {
            if (reason_field != .string) return invalidOutput("reason must be a string");
            reason = reason_field.string;
        }
        if (std.mem.eql(u8, field.string, "block")) {
            switch (name) {
                .user_prompt_submit, .instructions_loaded, .config_change, .pre_compact, .pre_model_switch, .pre_tool_use => {
                    a.decision = .deny;
                    a.reason = reason;
                },
                .post_tool_use, .post_tool_use_failure => {
                    if (reason) |text| a.additional_context = text;
                },
                .post_tool_batch => a.stop_reason = reason orelse "A hook stopped the turn.",
                .stop, .subagent_stop => a.continue_reason = reason orelse "A Stop hook asked fx to keep going.",
                // A permission request takes its decision only from hookSpecificOutput.decision,
                // so a top-level block there is ignored.
                .permission_request => {},
                // Any other event that cannot deny gets the deny here, and the merge drops it
                // with a notice, as it does for every answer the event does not accept.
                else => {
                    a.decision = .deny;
                    a.reason = reason;
                },
            }
        } else if (std.mem.eql(u8, field.string, "approve")) {
            // Same rule as block: a permission request reads only hookSpecificOutput.decision.
            if (name != .permission_request) {
                a.decision = .allow;
                a.reason = reason;
            }
        }
    }

    if (object.get("hookSpecificOutput")) |specific| {
        if (specific != .object) return invalidOutput("hookSpecificOutput must be an object");
        const inner = specific.object;

        if (inner.get("hookEventName")) |event_field| {
            if (event_field != .string) return invalidOutput("hookEventName must be a string");
            if (!std.mem.eql(u8, event_field.string, name.fileName())) {
                const detail = try arena.print("hookEventName is \"{s}\", not \"{s}\"", .{
                    event_field.string,
                    name.fileName(),
                });
                return invalidOutput(detail);
            }
        }

        if (name == .pre_tool_use or name == .pre_model_switch) {
            if (inner.get("permissionDecision")) |field| {
                if (field != .string) return invalidOutput("permissionDecision must be a string");
                if (std.mem.eql(u8, field.string, "allow")) {
                    a.decision = .allow;
                } else if (std.mem.eql(u8, field.string, "deny")) {
                    a.decision = .deny;
                } else if (std.mem.eql(u8, field.string, "ask")) {
                    a.decision = .ask;
                } else if (std.mem.eql(u8, field.string, "defer")) {
                    a.decision = .proceed;
                } else {
                    return invalidOutput("permissionDecision must be allow, deny, ask, or defer");
                }
            }
            if (inner.get("permissionDecisionReason")) |field| {
                if (field != .string) return invalidOutput("permissionDecisionReason must be a string");
                a.reason = field.string;
            }
        }

        if (name == .pre_tool_use) {
            if (inner.get("updatedInput")) |field| {
                if (field != .object) return invalidOutput("updatedInput must be an object");
                a.updated_input = try writeJson(arena, field);
            }
            if (inner.get("additionalContext")) |field| {
                if (field != .string) return invalidOutput("additionalContext must be a string");
                a.additional_context = field.string;
            }
        }

        if (name == .permission_request) {
            if (inner.get("decision")) |field| {
                if (field != .object) return invalidOutput("decision must be an object");
                const behavior = field.object.get("behavior") orelse
                    return invalidOutput("decision.behavior must be allow or deny");
                if (behavior != .string) return invalidOutput("decision.behavior must be allow or deny");
                if (std.mem.eql(u8, behavior.string, "allow")) {
                    a.decision = .allow;
                } else if (std.mem.eql(u8, behavior.string, "deny")) {
                    a.decision = .deny;
                } else {
                    return invalidOutput("decision.behavior must be allow or deny");
                }
                if (field.object.get("message")) |message| {
                    if (message != .string) return invalidOutput("decision.message must be a string");
                    a.reason = message.string;
                }
            }
        }

        if (name == .permission_denied) {
            if (inner.get("retry")) |field| {
                if (field != .bool) return invalidOutput("retry must be a boolean");
                a.retry = field.bool;
            }
        }

        if (name == .post_tool_use) {
            if (inner.get("additionalContext")) |field| {
                if (field != .string) return invalidOutput("additionalContext must be a string");
                a.additional_context = field.string;
            }
            if (inner.get("updatedToolOutput") orelse inner.get("updatedMCPToolOutput")) |output| {
                if (output == .string) {
                    a.updated_output = output.string;
                } else {
                    a.updated_output = try writeJson(arena, output);
                }
            }
        }

        if (name == .user_prompt_submit) {
            if (inner.get("additionalContext")) |field| {
                if (field != .string) return invalidOutput("additionalContext must be a string");
                a.additional_context = field.string;
            }
            if (inner.get("updatedPrompt")) |field| {
                if (field != .string) return invalidOutput("updatedPrompt must be a string");
                a.updated_input = field.string;
            }
        }

        if ((name == .stop or name == .subagent_stop) and a.continue_reason == null) {
            if (inner.get("additionalContext")) |field| {
                if (field != .string) return invalidOutput("additionalContext must be a string");
                a.continue_reason = field.string;
            }
        }

        switch (name) {
            .post_tool_use_failure, .post_tool_batch, .subagent_start, .post_model_switch, .session_start, .pre_compact => {
                if (inner.get("additionalContext")) |field| {
                    if (field != .string) return invalidOutput("additionalContext must be a string");
                    a.additional_context = field.string;
                }
            },
            else => {},
        }
    }

    return .{ .answer = a };
}

/// Writes a JSON value back as text in the arena.
fn writeJson(arena: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    json.write(value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

fn answerOf(result: answer.Result) !answer.Answer {
    return switch (result) {
        .answer => |value| value,
        .failure => error.ExpectedAnswer,
    };
}

fn failureOf(result: answer.Result) !answer.Failure {
    return switch (result) {
        .answer => error.ExpectedFailure,
        .failure => |value| value,
    };
}

test "hook input holds the scope and the fields in order" {
    const alloc = std.testing.allocator;
    const fields = [_]event.Field{
        .{ .key = "tool_name", .value = .{ .string = "shell" } },
        .{ .key = "tool_input", .value = .{ .json = "{\"command\":\"ls\"}" } },
        .{ .key = "tool_use_id", .value = .{ .string = "c1" } },
    };
    const ev = event.Event{
        .name = .pre_tool_use,
        .scope = .{
            .surface = .interactive,
            .session_id = "s1",
            .turn_id = 7,
            .cwd = "/Users/example/p",
            .project_dir = "/Users/example/p",
            .permission_mode = "auto",
        },
        .fields = &fields,
    };

    const text = try buildInput(alloc, ev);
    defer alloc.free(text);

    try std.testing.expectEqualStrings(
        "{\"session_id\":\"s1\",\"transcript_path\":null,\"cwd\":\"/Users/example/p\",\"permission_mode\":\"auto\"," ++
            "\"hook_event_name\":\"PreToolUse\",\"fx_surface\":\"interactive\",\"fx_turn_id\":7," ++
            "\"tool_name\":\"shell\",\"tool_input\":{\"command\":\"ls\"},\"tool_use_id\":\"c1\"}",
        text,
    );

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("PreToolUse", object.get("hook_event_name").?.string);
    try std.testing.expectEqual(@as(i64, 7), object.get("fx_turn_id").?.integer);
    try std.testing.expectEqualStrings("ls", object.get("tool_input").?.object.get("command").?.string);
}

test "hook input carries a subagent id and leaves a missing turn out" {
    const alloc = std.testing.allocator;
    const ev = event.Event{
        .name = .pre_tool_use,
        .scope = .{
            .surface = .subagent,
            .subagent_id = 3,
            .cwd = "/Users/example/p",
            .project_dir = "/Users/example/p",
            .permission_mode = "ask",
        },
    };

    const text = try buildInput(alloc, ev);
    defer alloc.free(text);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("session_id").? == .null);
    try std.testing.expectEqualStrings("3", object.get("agent_id").?.string);
    try std.testing.expect(object.get("fx_turn_id") == null);
}

test "a SubagentStart input carries the subagent id once" {
    const alloc = std.testing.allocator;
    const ev = event.Event{
        .name = .subagent_start,
        .scope = .{
            .surface = .subagent,
            .session_id = "child-1",
            .subagent_id = 3,
            .cwd = "/Users/example/p",
            .project_dir = "/Users/example/p",
            .permission_mode = "auto",
        },
    };

    const text = try buildInput(alloc, ev);
    defer alloc.free(text);

    var count: usize = 0;
    var rest: []const u8 = text;
    while (std.mem.find(u8, rest, "\"agent_id\"")) |at| {
        count += 1;
        rest = rest[at + "\"agent_id\"".len ..];
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.find(u8, text, "\"agent_id\":\"3\"") != null);
}

test "hook input escapes strings and writes other values as JSON" {
    const alloc = std.testing.allocator;
    const text_with_escapes = "a \"q\" \\ b\nc";
    const fields = [_]event.Field{
        .{ .key = "text", .value = .{ .string = text_with_escapes } },
        .{ .key = "flag", .value = .{ .boolean = true } },
        .{ .key = "count", .value = .{ .integer = -3 } },
        .{ .key = "none", .value = .null_value },
    };
    const ev = event.Event{
        .name = .notification,
        .scope = .{
            .surface = .acp,
            .cwd = "/tmp",
            .project_dir = "/tmp",
            .permission_mode = "auto",
        },
        .fields = &fields,
    };

    const text = try buildInput(alloc, ev);
    defer alloc.free(text);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings(text_with_escapes, object.get("text").?.string);
    try std.testing.expect(object.get("flag").?.bool);
    try std.testing.expectEqual(@as(i64, -3), object.get("count").?.integer);
    try std.testing.expect(object.get("none").? == .null);
    try std.testing.expectEqualStrings("acp", object.get("fx_surface").?.string);
}

test "an empty successful run answers nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try answerOf(try readOutput(arena_state.allocator(), .pre_tool_use, .proceed, .{
        .code = 0,
        .stdout = "",
        .stderr = "",
    }));

    try std.testing.expectEqual(answer.Decision.proceed, a.decision);
    try std.testing.expect(a.reason == null);
    try std.testing.expect(a.additional_context == null);
}

test "exit code 2 denies with the stderr text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try answerOf(try readOutput(arena, .pre_tool_use, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "  no rm here\n",
    }));
    try std.testing.expectEqual(answer.Decision.deny, a.decision);
    try std.testing.expectEqualStrings("no rm here", a.reason.?);

    const b = try answerOf(try readOutput(arena, .pre_tool_use, .proceed, .{
        .code = 2,
        .stdout = "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}",
        .stderr = "no rm here",
    }));
    try std.testing.expectEqual(answer.Decision.deny, b.decision);
}

test "exit code 2 on a prompt submit has a default reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try answerOf(try readOutput(arena_state.allocator(), .user_prompt_submit, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "",
    }));

    try std.testing.expectEqual(answer.Decision.deny, a.decision);
    try std.testing.expectEqualStrings("blocked by a hook", a.reason.?);
}

test "exit code 2 on Stop asks fx to keep going" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try answerOf(try readOutput(arena_state.allocator(), .stop, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "check the tests",
    }));

    try std.testing.expectEqualStrings("check the tests", a.continue_reason.?);
}

test "a missing Stop script is a failure, not a continue" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dash = try failureOf(try readOutput(arena, .stop, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "sh: 0: cannot open ./x.sh: No such file",
    }));
    try std.testing.expectEqual(answer.FailureKind.exit_code, dash.kind);
    try std.testing.expectEqual(@as(?u8, 2), dash.exit_code);

    const bash = try failureOf(try readOutput(arena, .subagent_stop, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "bash: ./x.sh: No such file or directory",
    }));
    try std.testing.expectEqual(answer.FailureKind.exit_code, bash.kind);

    const older = try failureOf(try readOutput(arena, .stop, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "sh: 0: Can't open ./x.sh",
    }));
    try std.testing.expectEqual(answer.FailureKind.exit_code, older.kind);

    const denied = try answerOf(try readOutput(arena, .pre_tool_use, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "sh: 0: cannot open ./x.sh: No such file",
    }));
    try std.testing.expectEqual(answer.Decision.deny, denied.decision);
}

test "exit code 2 feeds the events that only listen" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tool = try answerOf(try readOutput(arena, .post_tool_use, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "lint failed",
    }));
    try std.testing.expectEqualStrings("lint failed", tool.additional_context.?);

    const batch = try answerOf(try readOutput(arena, .post_tool_batch, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("A hook stopped the turn.", batch.stop_reason.?);

    const note = try answerOf(try readOutput(arena, .notification, .proceed, .{
        .code = 2,
        .stdout = "",
        .stderr = "hey",
    }));
    try std.testing.expectEqualStrings("hey", note.system_message.?);
}

test "a permission decision in the output is read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try answerOf(try readOutput(arena_state.allocator(), .pre_tool_use, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"nope\"}}",
        .stderr = "",
    }));

    try std.testing.expectEqual(answer.Decision.deny, a.decision);
    try std.testing.expectEqualStrings("nope", a.reason.?);
}

test "a pre tool use hook may allow with new input and context" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try answerOf(try readOutput(arena, .pre_tool_use, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"ls -la\"},\"additionalContext\":\"ctx\"}}",
        .stderr = "",
    }));

    try std.testing.expectEqual(answer.Decision.allow, a.decision);
    try std.testing.expectEqualStrings("ctx", a.additional_context.?);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, a.updated_input.?, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ls -la", parsed.value.object.get("command").?.string);
}

test "a hook event name that does not match is a failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const failure = try failureOf(try readOutput(arena_state.allocator(), .pre_tool_use, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"hookEventName\":\"Stop\"}}",
        .stderr = "",
    }));

    try std.testing.expectEqual(answer.FailureKind.invalid_output, failure.kind);
    try std.testing.expectEqualStrings("hookEventName is \"Stop\", not \"PreToolUse\"", failure.detail);
}

test "a block decision follows the event" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "{\"decision\":\"block\",\"reason\":\"r\"}";

    const prompt = try answerOf(try readOutput(arena, .user_prompt_submit, .proceed, .{
        .code = 0,
        .stdout = text,
        .stderr = "",
    }));
    try std.testing.expectEqual(answer.Decision.deny, prompt.decision);
    try std.testing.expectEqualStrings("r", prompt.reason.?);

    const stop = try answerOf(try readOutput(arena, .stop, .proceed, .{
        .code = 0,
        .stdout = text,
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("r", stop.continue_reason.?);

    const tool = try answerOf(try readOutput(arena, .post_tool_use, .proceed, .{
        .code = 0,
        .stdout = text,
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("r", tool.additional_context.?);

    const batch = try answerOf(try readOutput(arena, .post_tool_batch, .proceed, .{
        .code = 0,
        .stdout = text,
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("r", batch.stop_reason.?);

    const session = try answerOf(try readOutput(arena, .session_start, .proceed, .{
        .code = 0,
        .stdout = text,
        .stderr = "",
    }));
    // SessionStart cannot deny. The answer still arrives as a deny, and the merge drops it with a notice.
    try std.testing.expectEqual(answer.Decision.deny, session.decision);
    try std.testing.expectEqualStrings("r", session.reason.?);
    try std.testing.expect(session.additional_context == null);
    try std.testing.expect(session.continue_reason == null);
    try std.testing.expect(session.stop_reason == null);

    // A permission request reads only hookSpecificOutput.decision, so a top-level block is ignored.
    const permission = try answerOf(try readOutput(arena, .permission_request, .proceed, .{
        .code = 0,
        .stdout = text,
        .stderr = "",
    }));
    try std.testing.expectEqual(answer.Decision.proceed, permission.decision);

    const approve = try answerOf(try readOutput(arena, .session_start, .proceed, .{
        .code = 0,
        .stdout = "{\"decision\":\"approve\",\"reason\":\"fine\"}",
        .stderr = "",
    }));
    try std.testing.expectEqual(answer.Decision.allow, approve.decision);
}

test "an approve decision is read on pre tool use" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try answerOf(try readOutput(arena_state.allocator(), .pre_tool_use, .proceed, .{
        .code = 0,
        .stdout = "{\"decision\":\"approve\",\"reason\":\"fine\"}",
        .stderr = "",
    }));

    try std.testing.expectEqual(answer.Decision.allow, a.decision);
    try std.testing.expectEqualStrings("fine", a.reason.?);
}

test "continue false stops the turn where the event takes a stop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "{\"continue\":false,\"stopReason\":\"enough\"}";

    const tool = try answerOf(try readOutput(arena, .post_tool_use, .proceed, .{
        .code = 0,
        .stdout = text,
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("enough", tool.stop_reason.?);

    const stop = try answerOf(try readOutput(arena, .stop, .proceed, .{
        .code = 0,
        .stdout = text,
        .stderr = "",
    }));
    try std.testing.expect(stop.stop_reason == null);
}

test "a system message reaches the user" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try answerOf(try readOutput(arena, .notification, .proceed, .{
        .code = 0,
        .stdout = "{\"systemMessage\":\"hello\"}",
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("hello", a.system_message.?);

    const failure = try failureOf(try readOutput(arena, .notification, .proceed, .{
        .code = 0,
        .stdout = "{\"systemMessage\":5}",
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("systemMessage must be a string", failure.detail);
}

test "stdout that is not JSON is a failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const failure = try failureOf(try readOutput(arena_state.allocator(), .pre_tool_use, .proceed, .{
        .code = 0,
        .stdout = "{not json}",
        .stderr = "",
    }));

    try std.testing.expectEqual(answer.FailureKind.invalid_output, failure.kind);
    try std.testing.expectEqualStrings("stdout is not valid JSON", failure.detail);
}

test "plain stdout text is context only where the event takes it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = try answerOf(try readOutput(arena, .user_prompt_submit, .proceed, .{
        .code = 0,
        .stdout = "remember the style guide",
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("remember the style guide", prompt.additional_context.?);

    const tool = try answerOf(try readOutput(arena, .pre_tool_use, .proceed, .{
        .code = 0,
        .stdout = "remember the style guide",
        .stderr = "",
    }));
    try std.testing.expect(tool.additional_context == null);
    try std.testing.expectEqual(answer.Decision.proceed, tool.decision);
}

test "a permission request reads its own decision object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try answerOf(try readOutput(arena, .permission_request, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"deny\",\"message\":\"no\"}}}",
        .stderr = "",
    }));
    try std.testing.expectEqual(answer.Decision.deny, a.decision);
    try std.testing.expectEqualStrings("no", a.reason.?);

    const failure = try failureOf(try readOutput(arena, .permission_request, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"maybe\"}}}",
        .stderr = "",
    }));
    try std.testing.expectEqual(answer.FailureKind.invalid_output, failure.kind);
}

test "a post tool use hook may replace the tool output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const object = try answerOf(try readOutput(arena, .post_tool_use, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"updatedToolOutput\":{\"ok\":true}}}",
        .stderr = "",
    }));
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, object.updated_output.?, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool);

    const text = try answerOf(try readOutput(arena, .post_tool_use, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"updatedToolOutput\":\"plain\"}}",
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("plain", text.updated_output.?);
}

test "a prompt submit hook may replace the prompt" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try answerOf(try readOutput(arena_state.allocator(), .user_prompt_submit, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"updatedPrompt\":\"new text\"}}",
        .stderr = "",
    }));

    try std.testing.expectEqualStrings("new text", a.updated_input.?);
}

test "Stop continues with the first continue request it finds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const context = try answerOf(try readOutput(arena, .stop, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"additionalContext\":\"keep going\"}}",
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("keep going", context.continue_reason.?);

    const first = try answerOf(try readOutput(arena, .stop, .proceed, .{
        .code = 0,
        .stdout = "{\"decision\":\"block\",\"reason\":\"first\",\"hookSpecificOutput\":{\"additionalContext\":\"second\"}}",
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("first", first.continue_reason.?);
}

test "a denied permission may ask for a retry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try answerOf(try readOutput(arena_state.allocator(), .permission_denied, .proceed, .{
        .code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"retry\":true}}",
        .stderr = "",
    }));

    try std.testing.expect(a.retry);
}

test "another exit code follows the failure policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const failure = try failureOf(try readOutput(arena, .pre_tool_use, .proceed, .{
        .code = 1,
        .stdout = "",
        .stderr = "boom\nmore",
    }));
    try std.testing.expectEqual(answer.FailureKind.exit_code, failure.kind);
    try std.testing.expectEqual(@as(?u8, 1), failure.exit_code);
    try std.testing.expectEqualStrings("boom", failure.detail);

    const a = try answerOf(try readOutput(arena, .pre_tool_use, .proceed, .{
        .code = 1,
        .stdout = "{\"systemMessage\":\"m\"}",
        .stderr = "",
    }));
    try std.testing.expectEqualStrings("m", a.system_message.?);

    const blocked = try failureOf(try readOutput(arena, .pre_tool_use, .block, .{
        .code = 1,
        .stdout = "{\"systemMessage\":\"m\"}",
        .stderr = "",
    }));
    try std.testing.expectEqual(answer.FailureKind.exit_code, blocked.kind);
}
