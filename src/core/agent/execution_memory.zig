const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const message = @import("../shared/message.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

pub fn makePersistedToolResult(
    alloc: Allocator,
    tool_call_id_src: []const u8,
    tool_name_src: []const u8,
    status: types.PersistedToolStatus,
    output_src: []const u8,
    memory: ?types.ToolResultMemory,
) !types.PersistedToolResult {
    const tool_call_id = try durableIdentifier(alloc, tool_call_id_src);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, tool_name_src);
    errdefer alloc.free(tool_name);
    const output = try redactText(alloc, output_src);
    errdefer alloc.free(output);
    const output_handle = if (memory) |info| if (info.output_handle) |handle| try alloc.dupe(u8, handle) else null else null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (memory) |info| if (info.preview) |text| try redactText(alloc, text) else null else null;
    errdefer if (preview) |text| alloc.free(text);
    const command_output_replay = if (memory) |info| if (info.command_output_replay) |replay|
        try types.dupeCommandOutputReplay(alloc, replay)
    else
        null else null;
    errdefer if (command_output_replay) |replay| types.freeCommandOutputReplay(alloc, replay);
    var result: types.PersistedToolResult = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = status,
        .output = output,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = if (memory) |info| info.output_bytes else output_src.len,
        .stored_output_bytes = if (memory) |info| info.stored_output_bytes else output.len,
        .truncated = if (memory) |info| info.truncated else false,
        .provider_native = false,
        .created_at_ms = io_mod.milliTimestamp(),
        .command_output_replay = command_output_replay,
        .command_process_presentation = if (memory) |info| info.command_process_presentation else null,
    };
    if (memory) |info| {
        if (info.committed_file_presentation) |presentation| {
            result.committed_file_presentation = dupeRedactedCommittedFilePresentation(
                alloc,
                presentation,
            ) catch |err| blk: {
                debug_trace.logf(
                    "session",
                    "committed file resume presentation unavailable call_id={s} err={s}",
                    .{ tool_call_id_src, @errorName(err) },
                );
                break :blk null;
            };
        }
    }
    return result;
}

pub fn buildNormalChatExecutionMemory(
    alloc: Allocator,
    messages: []const types.ChatMessage,
) !types.ExecutionMemory {
    return buildNormalExecutionMemory(ChatMessageAdapter, alloc, messages);
}

pub fn buildNormalMessageExecutionMemory(
    alloc: Allocator,
    messages: []const message.Message,
) !types.ExecutionMemory {
    return buildNormalExecutionMemory(MessageAdapter, alloc, messages);
}

pub fn dupeCompletedRedactedToolCalls(
    alloc: Allocator,
    calls: []const ToolCall,
    results: []const types.PersistedToolResult,
) ![]ToolCall {
    if (calls.len == 0 or results.len == 0) return &.{};

    var copy: std.ArrayList(ToolCall) = .empty;
    errdefer {
        for (copy.items) |call| types.freeToolCall(alloc, call);
        copy.deinit(alloc);
    }
    for (calls) |call| {
        const completed = blk: {
            const durable_id = try durableIdentifier(alloc, call.id);
            defer alloc.free(durable_id);
            break :blk hasPersistedResultForCall(results, durable_id);
        };
        if (!completed) continue;

        const duplicated = try dupeRedactedToolCall(alloc, call);
        copy.append(alloc, duplicated) catch |err| {
            types.freeToolCall(alloc, duplicated);
            return err;
        };
    }
    return copy.toOwnedSlice(alloc);
}

pub fn redactText(alloc: Allocator, text: []const u8) ![]u8 {
    const masked = text_utils.maskSecrets(alloc, text) catch
        return error.OutOfMemory;
    if (masked.ptr == text.ptr) return alloc.dupe(u8, text);
    return @constCast(masked);
}

fn dupeRedactedCommittedFilePresentation(
    alloc: Allocator,
    presentation: types.CommittedFilePresentation,
) !types.CommittedFilePresentation {
    const path = try redactText(alloc, presentation.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, presentation.lines.len);
    errdefer alloc.free(lines);
    var copied_lines: usize = 0;
    errdefer {
        for (lines[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (presentation.lines, 0..) |line, index| {
        lines[index] = .{
            .kind = line.kind,
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = try redactText(alloc, line.text),
        };
        copied_lines += 1;
    }
    const previous_content = if (presentation.previous_content) |content|
        try redactText(alloc, content)
    else
        null;
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = if (presentation.after_content) |content|
        try redactText(alloc, content)
    else
        null;
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id: ?types.ToolLifecycleId = if (presentation.lifecycle_id) |id| .{
        .turn_id = id.turn_id,
        .call_id = try durableIdentifier(alloc, id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    return .{
        .path = path,
        .kind = presentation.kind,
        .lines = lines,
        .additions = presentation.additions,
        .deletions = presentation.deletions,
        .truncated = presentation.truncated,
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
    };
}

pub fn appendFileEvidenceForTool(
    alloc: Allocator,
    files: *std.ArrayList(types.FileEvidence),
    call: ToolCall,
    status: types.PersistedToolStatus,
    memory: ?types.ToolResultMemory,
) !void {
    const action = fileEvidenceActionForTool(call.name);
    if (action == .unknown) return;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const object = parsed.value.object;

    const path = switch (action) {
        .rename => stringField(object, "old_path"),
        .copy => stringField(object, "source"),
        .search, .list => stringField(object, "path") orelse stringField(object, "directory") orelse stringField(object, "query"),
        else => stringField(object, "path"),
    } orelse return;
    const new_path = switch (action) {
        .rename => stringField(object, "new_path"),
        .copy => stringField(object, "destination"),
        else => null,
    };

    const evidence = try makeFileEvidence(
        alloc,
        call,
        path,
        new_path,
        action,
        status,
        memory,
    );
    var owns_evidence = true;
    errdefer if (owns_evidence) freeTransientFileEvidence(alloc, evidence);
    try files.append(alloc, evidence);
    owns_evidence = false;
}

pub fn markStaleFileEvidence(files: []types.FileEvidence) void {
    for (files, 0..) |file, i| {
        if (file.status != .success or !isMutationFileAction(file.action)) continue;
        var prior_index: usize = 0;
        while (prior_index < i) : (prior_index += 1) {
            if (files[prior_index].action != .read) continue;
            if (file.action != .copy and
                std.mem.eql(u8, files[prior_index].path, file.path))
            {
                files[prior_index].stale = true;
            }
            if (file.new_path) |new_path| {
                if (std.mem.eql(u8, files[prior_index].path, new_path)) {
                    files[prior_index].stale = true;
                }
            }
        }
    }
}

pub fn findToolCallById(calls: []const ToolCall, id: []const u8) ?ToolCall {
    for (calls) |call| {
        if (std.mem.eql(u8, call.id, id)) return call;
    }
    return null;
}

const ChatMessageAdapter = struct {
    pub const Message = types.ChatMessage;

    fn isAssistant(value: Message) bool {
        return value.role == .assistant;
    }

    fn isTool(value: Message) bool {
        return value.role == .tool;
    }

    fn isUser(value: Message) bool {
        return value.role == .user;
    }

    fn isPermissionFeedback(value: Message) bool {
        return value.role == .user and value.permission_feedback;
    }

    fn toolCalls(value: Message) []const ToolCall {
        return value.tool_calls;
    }

    fn toolCallId(value: Message) ?[]const u8 {
        return value.tool_call_id;
    }

    fn toolName(value: Message) ?[]const u8 {
        return value.tool_name;
    }

    fn toolResultStatus(value: Message) ?types.PersistedToolStatus {
        return value.tool_result_status;
    }

    fn toolResultMemory(value: Message) ?types.ToolResultMemory {
        return value.tool_result_memory;
    }

    fn content(value: Message) ?[]const u8 {
        return value.content;
    }
};

const MessageAdapter = struct {
    pub const Message = message.Message;

    fn isAssistant(value: Message) bool {
        return value.role == .assistant;
    }

    fn isTool(value: Message) bool {
        return value.role == .tool;
    }

    fn isUser(value: Message) bool {
        return value.role == .user;
    }

    fn isPermissionFeedback(value: Message) bool {
        return value.role == .user and value.permission_feedback;
    }

    fn toolCalls(value: Message) []const ToolCall {
        return value.tool_calls;
    }

    fn toolCallId(value: Message) ?[]const u8 {
        return value.tool_call_id;
    }

    fn toolName(value: Message) ?[]const u8 {
        return value.tool_name;
    }

    fn toolResultStatus(value: Message) ?types.PersistedToolStatus {
        return value.tool_result_status;
    }

    fn toolResultMemory(value: Message) ?types.ToolResultMemory {
        return value.tool_result_memory;
    }

    fn content(value: Message) ?[]const u8 {
        return if (value.content) |content_value| content_value.asText() else null;
    }
};

fn buildNormalExecutionMemory(
    comptime Adapter: type,
    alloc: Allocator,
    messages: []const Adapter.Message,
) !types.ExecutionMemory {
    var tool_steps: std.ArrayList(types.ToolExecutionStep) = .empty;
    errdefer {
        for (tool_steps.items) |step| {
            freeTransientToolExecutionStep(alloc, step);
        }
        tool_steps.deinit(alloc);
    }
    var files: std.ArrayList(types.FileEvidence) = .empty;
    errdefer {
        for (files.items) |file| {
            freeTransientFileEvidence(alloc, file);
        }
        files.deinit(alloc);
    }

    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];
        const tool_calls = Adapter.toolCalls(msg);
        if (!Adapter.isAssistant(msg) or tool_calls.len == 0) {
            i += 1;
            continue;
        }

        var results: std.ArrayList(types.PersistedToolResult) = .empty;
        errdefer {
            for (results.items) |result| {
                freeTransientPersistedToolResult(alloc, result);
            }
            results.deinit(alloc);
        }
        var result_source_call_ids: std.ArrayList([]const u8) = .empty;
        defer result_source_call_ids.deinit(alloc);

        var j = i + 1;
        var last_result_index: ?usize = null;
        while (j < messages.len and Adapter.isTool(messages[j])) : (j += 1) {
            const result_msg = messages[j];
            const tool_call_id = Adapter.toolCallId(result_msg) orelse continue;
            const call = findToolCallById(tool_calls, tool_call_id) orelse continue;
            const output = Adapter.content(result_msg) orelse "";
            const status = Adapter.toolResultStatus(result_msg) orelse
                return error.MissingToolResultStatus;
            const result_memory = Adapter.toolResultMemory(result_msg);
            const record = try makePersistedToolResult(
                alloc,
                tool_call_id,
                Adapter.toolName(result_msg) orelse call.name,
                status,
                output,
                result_memory,
            );
            var owns_record = true;
            errdefer if (owns_record) {
                freeTransientPersistedToolResult(alloc, record);
            };
            try results.append(alloc, record);
            owns_record = false;
            try result_source_call_ids.append(alloc, tool_call_id);
            last_result_index = results.items.len - 1;
            try appendFileEvidenceForTool(
                alloc,
                &files,
                call,
                status,
                result_memory,
            );
        }

        while (j < messages.len and Adapter.isUser(messages[j])) : (j += 1) {
            const feedback_msg = messages[j];
            if (!Adapter.isPermissionFeedback(feedback_msg)) continue;
            const text = Adapter.content(feedback_msg) orelse
                return error.MissingPermissionFeedbackContent;
            const index = if (Adapter.toolCallId(feedback_msg)) |tool_call_id|
                findResultIndexBySourceCallId(result_source_call_ids.items, tool_call_id) orelse continue
            else
                last_result_index orelse return error.PermissionFeedbackWithoutResult;
            try appendPersistedPermissionFeedback(alloc, &results.items[index], text);
        }

        if (results.items.len == 0) {
            results.deinit(alloc);
            i = j;
            continue;
        }

        const assistant = if (Adapter.content(msg)) |content|
            try redactText(alloc, content)
        else
            null;
        errdefer if (assistant) |text| alloc.free(text);
        const persisted_calls = try dupeCompletedRedactedToolCalls(
            alloc,
            tool_calls,
            results.items,
        );
        errdefer types.freeToolCallSlice(alloc, persisted_calls);
        const owned_results = try results.toOwnedSlice(alloc);
        errdefer types.freePersistedToolResults(alloc, owned_results);
        const step = types.ToolExecutionStep{
            .assistant = assistant,
            .tool_calls = persisted_calls,
            .tool_results = owned_results,
        };
        try tool_steps.append(alloc, step);
        i = j;
    }

    const owned_files = try files.toOwnedSlice(alloc);
    errdefer types.freeFileEvidenceSlice(alloc, owned_files);
    markStaleFileEvidence(owned_files);
    return .{
        .tool_steps = try tool_steps.toOwnedSlice(alloc),
        .files = owned_files,
    };
}

fn hasPersistedResultForCall(
    results: []const types.PersistedToolResult,
    call_id: []const u8,
) bool {
    for (results) |result| {
        if (std.mem.eql(u8, result.tool_call_id, call_id)) return true;
    }
    return false;
}

fn findResultIndexBySourceCallId(
    source_call_ids: []const []const u8,
    call_id: []const u8,
) ?usize {
    for (source_call_ids, 0..) |source_call_id, index| {
        if (std.mem.eql(u8, source_call_id, call_id)) return index;
    }
    return null;
}

pub fn freeTransientToolExecutionStep(
    alloc: Allocator,
    step: types.ToolExecutionStep,
) void {
    if (step.assistant) |assistant| alloc.free(assistant);
    types.freeToolCallSlice(alloc, step.tool_calls);
    types.freePersistedToolResults(alloc, step.tool_results);
}

pub fn freeTransientPersistedToolResult(
    alloc: Allocator,
    result: types.PersistedToolResult,
) void {
    alloc.free(result.tool_call_id);
    alloc.free(result.tool_name);
    alloc.free(result.output);
    if (result.output_handle) |handle| alloc.free(handle);
    if (result.preview) |preview| alloc.free(preview);
    types.freePermissionFeedback(alloc, result.permission_feedback);
    if (result.committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    }
    if (result.command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    }
}

fn appendPersistedPermissionFeedback(
    alloc: Allocator,
    result: *types.PersistedToolResult,
    text: []const u8,
) !void {
    const redacted = try redactText(alloc, text);
    errdefer alloc.free(redacted);

    const prior = result.permission_feedback;
    const appended = try alloc.alloc([]u8, prior.len + 1);
    errdefer alloc.free(appended);
    @memcpy(appended[0..prior.len], prior);
    appended[prior.len] = redacted;
    if (prior.len > 0) alloc.free(prior);
    result.permission_feedback = appended;
}

pub fn freeTransientFileEvidence(
    alloc: Allocator,
    file: types.FileEvidence,
) void {
    alloc.free(file.path);
    if (file.new_path) |new_path| alloc.free(new_path);
    alloc.free(file.tool_call_id);
    alloc.free(file.tool_name);
}

pub fn dupeRedactedToolCall(alloc: Allocator, call: ToolCall) !ToolCall {
    const id = try durableIdentifier(alloc, call.id);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(name);
    const arguments_json = try redactToolArgumentsJsonForTool(
        alloc,
        call.name,
        call.arguments_json,
    );
    errdefer alloc.free(arguments_json);
    const provisional_id = if (call.provisional_id) |value| try durableIdentifier(alloc, value) else null;
    errdefer if (provisional_id) |value| alloc.free(value);
    const provider_result = if (call.provider_result) |result| try redactText(alloc, result) else null;
    errdefer if (provider_result) |result| alloc.free(result);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .provisional_id = provisional_id,
        .provider_result = provider_result,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

const ArgumentRedactionPolicy = struct {
    web_fetch: bool = false,
};

fn redactToolArgumentsJsonForTool(
    alloc: Allocator,
    tool_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch {
        return redactText(alloc, arguments_json);
    };
    defer parsed.deinit();

    const policy = ArgumentRedactionPolicy{
        .web_fetch = std.mem.eql(u8, tool_name, "web_fetch"),
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeRedactedJsonValue(alloc, &out.writer, parsed.value, policy, false);
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeRedactedJsonValue(
    alloc: Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
    policy: ArgumentRedactionPolicy,
    redact_value: bool,
) !void {
    if (redact_value) {
        try std.json.Stringify.value("[REDACTED]", .{}, writer);
        return;
    }

    switch (value) {
        .object => |object| {
            try writer.writeByte('{');
            var iter = object.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                if (policy.web_fetch and
                    std.mem.eql(u8, entry.key_ptr.*, "url") and
                    entry.value_ptr.* == .string)
                {
                    const display_url = try text_utils.redactUrlForDisplay(
                        alloc,
                        entry.value_ptr.string,
                    );
                    defer alloc.free(display_url);
                    try writeMaskedJsonString(alloc, writer, display_url);
                } else {
                    try writeRedactedJsonValue(
                        alloc,
                        writer,
                        entry.value_ptr.*,
                        policy,
                        shouldRedactArgumentValue(entry.key_ptr.*),
                    );
                }
            }
            try writer.writeByte('}');
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try writeRedactedJsonValue(alloc, writer, item, policy, false);
            }
            try writer.writeByte(']');
        },
        .string => |text| try writeMaskedJsonString(alloc, writer, text),
        else => try std.json.Stringify.value(value, .{}, writer),
    }
}

fn writeMaskedJsonString(
    alloc: Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
) !void {
    const masked = text_utils.maskSecrets(alloc, text) catch return error.OutOfMemory;
    defer if (masked.ptr != text.ptr) alloc.free(@constCast(masked));
    try std.json.Stringify.value(masked, .{}, writer);
}

fn shouldRedactArgumentValue(key: []const u8) bool {
    if (isCredentialArgumentKey(key)) return true;
    return false;
}

fn isCredentialArgumentKey(key: []const u8) bool {
    const exact = [_][]const u8{
        "password",
        "passwd",
        "token",
        "api_key",
        "apikey",
        "secret",
        "secret_key",
        "secretkey",
        "client_secret",
        "clientsecret",
        "access_token",
        "accesstoken",
        "refresh_token",
        "refreshtoken",
        "auth_token",
        "authtoken",
        "id_token",
        "idtoken",
        "private_key",
        "privatekey",
        "access_key",
        "accesskey",
        "authorization",
        "cookie",
        "set_cookie",
        "setcookie",
        "credential",
        "credentials",
    };
    for (exact) |candidate| {
        if (std.ascii.eqlIgnoreCase(key, candidate)) return true;
    }
    return false;
}

fn makeFileEvidence(
    alloc: Allocator,
    call: ToolCall,
    path_src: []const u8,
    new_path_src: ?[]const u8,
    action: types.FileEvidenceAction,
    status: types.PersistedToolStatus,
    memory: ?types.ToolResultMemory,
) !types.FileEvidence {
    const path = try redactText(alloc, path_src);
    errdefer alloc.free(path);
    const new_path = if (new_path_src) |value| try redactText(alloc, value) else null;
    errdefer if (new_path) |value| alloc.free(value);
    const tool_call_id = try durableIdentifier(alloc, call.id);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(tool_name);
    const model_view_covers_full_file = if (memory) |info|
        (info.model_view_covers_full_file orelse false) and
            !info.truncated and
            info.output_handle == null
    else
        false;
    return .{
        .path = path,
        .new_path = new_path,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .action = action,
        .status = status,
        .model_view_covers_full_file = status == .success and
            action == .read and
            model_view_covers_full_file,
        .stale = false,
    };
}

fn fileEvidenceActionForTool(tool_name: []const u8) types.FileEvidenceAction {
    if (std.mem.eql(u8, tool_name, "read_file")) return .read;
    if (std.mem.eql(u8, tool_name, "write_file")) return .write;
    if (std.mem.eql(u8, tool_name, "edit_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "delete_file")) return .delete;
    if (std.mem.eql(u8, tool_name, "rename_file")) return .rename;
    if (std.mem.eql(u8, tool_name, "copy_file")) return .copy;
    if (std.mem.eql(u8, tool_name, "grep_files")) return .search;
    if (std.mem.eql(u8, tool_name, "glob_files")) return .search;
    if (std.mem.eql(u8, tool_name, "list_files")) return .list;
    return .unknown;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn isMutationFileAction(action: types.FileEvidenceAction) bool {
    return switch (action) {
        .write, .edit, .delete, .rename, .copy => true,
        else => false,
    };
}

fn durableIdentifier(alloc: Allocator, value: []const u8) ![]u8 {
    const masked = text_utils.maskSecrets(alloc, value) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    if (masked.ptr == value.ptr) return alloc.dupe(u8, value);
    defer alloc.free(@constCast(masked));

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..12].*, .lower);
    return std.fmt.allocPrint(alloc, "redacted-{s}", .{&hex});
}

test "execution memory redacts secret values from arguments results and provider output" {
    const runtime_execution_memory = @import("runtime/execution_memory.zig");
    const ChatMessage = types.ChatMessage;
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_secret",
        .name = "run_command",
        .arguments_json = "{\"command\":\"echo ok && AI_GATEWAY_API_KEY=abcdefghijklmnop && curl -H 'Authorization: Bearer abcdefghijklmnop' https://example.com\",\"api_key\":\"secret-value\"}",
        .provider_result = "github_pat_abcdefghijklmnop",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "sk-abcdefghijklmnop xoxb-abcdefghijklmnop", .tool_call_id = "call_secret", .tool_name = "run_command", .tool_result_status = .success },
    };

    const memory = try runtime_execution_memory.buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);
    try std.testing.expectEqual(@as(usize, 1), memory.tool_steps.len);
    const persisted_call = memory.tool_steps[0].tool_calls[0];
    const persisted_result = memory.tool_steps[0].tool_results[0];
    const args = persisted_call.arguments_json;
    const secret_needles = [_][]const u8{
        "abcdefghijklmnop",
        "secret-value",
        "Bearer ",
        "github_pat_",
        "sk-",
        "xoxb-",
    };
    for (secret_needles) |needle| {
        try std.testing.expect(std.mem.find(u8, args, needle) == null);
        try std.testing.expect(std.mem.find(u8, persisted_result.output, needle) == null);
        try std.testing.expect(std.mem.find(u8, persisted_call.provider_result.?, needle) == null);
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, args, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("[REDACTED]", parsed.value.object.get("api_key").?.string);
    try std.testing.expect(std.mem.startsWith(u8, parsed.value.object.get("command").?.string, "echo ok"));
    try std.testing.expect(std.mem.find(u8, parsed.value.object.get("command").?.string, "[redacted]") != null);
}

test "execution memory removes token-shaped call ids from JSON and replay" {
    const runtime_execution_memory = @import("runtime/execution_memory.zig");
    const session_runtime = @import("../session/session.zig");
    const testing_session_json = @import("../session/session_json.zig");
    const ChatMessage = types.ChatMessage;
    const alloc = std.testing.allocator;
    const secret_id = "sk-abcdefghijklmnop";
    var calls = [_]ToolCall{.{
        .id = secret_id,
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
        .provisional_id = secret_id,
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{
            .role = .tool,
            .content = "README",
            .tool_call_id = secret_id,
            .tool_name = "read_file",
            .tool_result_status = .success,
            .tool_result_memory = .{
                .model_view_covers_full_file = true,
            },
        },
    };

    const memory = try runtime_execution_memory.buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);
    try std.testing.expectEqualStrings(
        memory.tool_steps[0].tool_calls[0].id,
        memory.tool_steps[0].tool_results[0].tool_call_id,
    );
    try std.testing.expectEqualStrings(
        memory.tool_steps[0].tool_calls[0].id,
        memory.files[0].tool_call_id,
    );

    var json: std.Io.Writer.Allocating = .init(alloc);
    defer json.deinit();
    try testing_session_json.writeExecutionMemoryJson(
        &json.writer,
        memory,
    );
    try std.testing.expect(std.mem.find(u8, json.written(), secret_id) == null);

    const replay = (try session_runtime.formatExecutionReplayContext(
        alloc,
        memory,
    )).?;
    defer alloc.free(replay);
    try std.testing.expect(std.mem.find(u8, replay, secret_id) == null);
}

test "durable execution memory masks token-shaped values" {
    const alloc = std.testing.allocator;
    const call = ToolCall{
        .id = "call_secret",
        .name = "mcp__fixture__echo",
        .arguments_json =
        \\{"command":"AI_GATEWAY_API_KEY=abcdefghijklmnop curl -H 'Authorization: Bearer abcdefghijklmnop' https://example.com sk-abcdefghijklmnop","nested":{"values":["github_pat_abcdefghijklmnop","xoxb-abcdefghijklmnop","plain"]},"api_key":"named-secret"}
        ,
    };
    const result = try makePersistedToolResult(
        alloc,
        call.id,
        call.name,
        .success,
        "sk-abcdefghijklmnop github_pat_abcdefghijklmnop xoxb-abcdefghijklmnop",
        .{
            .preview = "Bearer abcdefghijklmnop",
            .output_bytes = 128,
            .stored_output_bytes = 64,
            .truncated = true,
        },
    );
    defer freeTransientPersistedToolResult(alloc, result);

    const calls = [_]ToolCall{call};
    const results = [_]types.PersistedToolResult{result};
    const persisted_calls = try dupeCompletedRedactedToolCalls(alloc, &calls, &results);
    defer types.freeToolCallSlice(alloc, persisted_calls);

    const secret_needles = [_][]const u8{
        "abcdefghijklmnop",
        "named-secret",
        "sk-",
        "github_pat_",
        "xoxb-",
        "Bearer ",
    };
    for (secret_needles) |needle| {
        try std.testing.expect(std.mem.find(u8, persisted_calls[0].arguments_json, needle) == null);
        try std.testing.expect(std.mem.find(u8, result.output, needle) == null);
        try std.testing.expect(std.mem.find(u8, result.preview.?, needle) == null);
    }

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        persisted_calls[0].arguments_json,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "[REDACTED]",
        parsed.value.object.get("api_key").?.string,
    );
    try std.testing.expect(
        std.mem.find(
            u8,
            parsed.value.object.get("command").?.string,
            "curl -H 'Authorization: [redacted]'",
        ) != null,
    );
    try std.testing.expectEqualStrings(
        "plain",
        parsed.value.object.get("nested").?.object.get("values").?.array.items[2].string,
    );
}

test "durable execution memory preserves benign secret-like words" {
    const alloc = std.testing.allocator;
    const input =
        "The tokenizer counts ordinary tokens.\n" ++
        "The secretariat published a public report.\n" ++
        "A token is a lexical unit.\n" ++
        "Authorization is an HTTP header.\n" ++
        "A cookie policy can be public.";
    const redacted = try redactText(alloc, input);
    defer alloc.free(redacted);

    try std.testing.expectEqualStrings(input, redacted);
}

test "durable execution memory redacts credential keys without hiding benign metadata" {
    const alloc = std.testing.allocator;
    const call = ToolCall{
        .id = "call_metadata",
        .name = "mcp__fixture__echo",
        .arguments_json =
        \\{"token_count":128,"authorization_docs":"public","cookie_policy":"strict","token":"secret-value","client_secret":"hidden"}
        ,
    };
    const redacted = try dupeRedactedToolCall(alloc, call);
    defer types.freeToolCall(alloc, redacted);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        redacted.arguments_json,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(
        @as(i64, 128),
        parsed.value.object.get("token_count").?.integer,
    );
    try std.testing.expectEqualStrings(
        "public",
        parsed.value.object.get("authorization_docs").?.string,
    );
    try std.testing.expectEqualStrings(
        "strict",
        parsed.value.object.get("cookie_policy").?.string,
    );
    try std.testing.expectEqualStrings(
        "[REDACTED]",
        parsed.value.object.get("token").?.string,
    );
    try std.testing.expectEqualStrings(
        "[REDACTED]",
        parsed.value.object.get("client_secret").?.string,
    );
}

test "durable execution memory pseudonymizes sensitive call ids consistently" {
    const alloc = std.testing.allocator;
    const secret_id = "sk-abcdefghijklmnop";
    const call = ToolCall{
        .id = secret_id,
        .name = "read_file",
        .arguments_json = "{\"path\":\"notes.txt\"}",
        .provisional_id = secret_id,
    };
    const result = try makePersistedToolResult(
        alloc,
        call.id,
        call.name,
        .success,
        "notes",
        .{ .model_view_covers_full_file = true },
    );
    defer freeTransientPersistedToolResult(alloc, result);

    const persisted_calls = try dupeCompletedRedactedToolCalls(
        alloc,
        &.{call},
        &.{result},
    );
    defer types.freeToolCallSlice(alloc, persisted_calls);

    var files: std.ArrayList(types.FileEvidence) = .empty;
    defer {
        for (files.items) |file| freeTransientFileEvidence(alloc, file);
        files.deinit(alloc);
    }
    try appendFileEvidenceForTool(
        alloc,
        &files,
        call,
        .success,
        .{ .model_view_covers_full_file = true },
    );

    try std.testing.expectEqual(@as(usize, 1), persisted_calls.len);
    try std.testing.expectEqual(@as(usize, 1), files.items.len);
    try std.testing.expect(!std.mem.eql(u8, secret_id, result.tool_call_id));
    try std.testing.expectEqualStrings(result.tool_call_id, persisted_calls[0].id);
    try std.testing.expectEqualStrings(result.tool_call_id, persisted_calls[0].provisional_id.?);
    try std.testing.expectEqualStrings(result.tool_call_id, files.items[0].tool_call_id);
}

test "durable execution memory redacts committed file presentation and reuses the call identity" {
    const alloc = std.testing.allocator;
    const secret = "sk-abcdefghijklmnop";
    const preview_lines = [_]types.CommittedFilePresentationLine{
        .{ .kind = .addition, .new_line = 1, .text = secret },
        .{ .kind = .elision, .text = "more secret rows omitted" },
    };
    const calls = [_]ToolCall{.{
        .id = secret,
        .name = "write_file",
        .arguments_json = "{\"path\":\"notes.txt\",\"content\":\"secret\"}",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{
            .role = .tool,
            .content = "wrote notes.txt",
            .tool_call_id = secret,
            .tool_name = "write_file",
            .tool_result_status = .success,
            .tool_result_memory = .{
                .committed_file_presentation = .{
                    .path = "secrets/sk-abcdefghijklmnop.md",
                    .kind = .added,
                    .lines = &preview_lines,
                    .additions = 120,
                    .deletions = 0,
                    .truncated = true,
                    .after_content = "sk-abcdefghijklmnop\n",
                    .lifecycle_id = .{ .turn_id = 8, .call_id = secret },
                },
            },
        },
    };

    const memory = try buildNormalChatExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);
    const result = memory.tool_steps[0].tool_results[0];
    const presentation = result.committed_file_presentation orelse return error.TestExpectedPresentation;

    try std.testing.expect(std.mem.find(u8, presentation.path, secret) == null);
    try std.testing.expect(std.mem.find(u8, presentation.lines[0].text, secret) == null);
    try std.testing.expect(std.mem.find(u8, presentation.after_content.?, secret) == null);
    try std.testing.expectEqualStrings(result.tool_call_id, presentation.lifecycle_id.?.call_id);
    try std.testing.expectEqualStrings(memory.tool_steps[0].tool_calls[0].id, presentation.lifecycle_id.?.call_id);
}

test "file evidence does not parse unknown tool arguments" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing_allocator.allocator();
    var files: std.ArrayList(types.FileEvidence) = .empty;
    defer files.deinit(alloc);

    try appendFileEvidenceForTool(
        alloc,
        &files,
        .{
            .id = "large_command",
            .name = "run_command",
            .arguments_json = "{\"command\":\"" ++ ("x\\n" ** 20_000) ++ "\"}",
        },
        .success,
        null,
    );

    try std.testing.expectEqual(@as(usize, 0), failing_allocator.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), files.items.len);
}

test "read evidence trusts typed model coverage instead of output text" {
    const alloc = std.testing.allocator;
    var files: std.ArrayList(types.FileEvidence) = .empty;
    defer {
        for (files.items) |file| freeTransientFileEvidence(alloc, file);
        files.deinit(alloc);
    }

    const call = ToolCall{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"notes.txt\"}",
    };
    try appendFileEvidenceForTool(
        alloc,
        &files,
        call,
        .success,
        null,
    );
    try appendFileEvidenceForTool(
        alloc,
        &files,
        call,
        .success,
        .{ .model_view_covers_full_file = false },
    );
    try appendFileEvidenceForTool(
        alloc,
        &files,
        call,
        .success,
        .{ .model_view_covers_full_file = true },
    );
    try appendFileEvidenceForTool(
        alloc,
        &files,
        call,
        .success,
        .{
            .model_view_covers_full_file = true,
            .truncated = true,
        },
    );

    try std.testing.expectEqual(@as(usize, 4), files.items.len);
    try std.testing.expect(!files.items[0].model_view_covers_full_file);
    try std.testing.expect(!files.items[1].model_view_covers_full_file);
    try std.testing.expect(files.items[2].model_view_covers_full_file);
    try std.testing.expect(!files.items[3].model_view_covers_full_file);
}

test "copy evidence uses real schema and preserves source read freshness" {
    const alloc = std.testing.allocator;
    var files: std.ArrayList(types.FileEvidence) = .empty;
    defer {
        for (files.items) |file| freeTransientFileEvidence(alloc, file);
        files.deinit(alloc);
    }

    try appendFileEvidenceForTool(
        alloc,
        &files,
        .{
            .id = "call_source_read",
            .name = "read_file",
            .arguments_json = "{\"path\":\"source.txt\"}",
        },
        .success,
        null,
    );
    try appendFileEvidenceForTool(
        alloc,
        &files,
        .{
            .id = "call_destination_read",
            .name = "read_file",
            .arguments_json = "{\"path\":\"destination.txt\"}",
        },
        .success,
        null,
    );
    try appendFileEvidenceForTool(
        alloc,
        &files,
        .{
            .id = "call_copy",
            .name = "copy_file",
            .arguments_json = "{\"source\":\"source.txt\",\"destination\":\"destination.txt\"}",
        },
        .success,
        null,
    );
    markStaleFileEvidence(files.items);

    try std.testing.expectEqual(@as(usize, 3), files.items.len);
    try std.testing.expectEqualStrings("source.txt", files.items[2].path);
    try std.testing.expectEqualStrings("destination.txt", files.items[2].new_path.?);
    try std.testing.expect(!files.items[0].stale);
    try std.testing.expect(files.items[1].stale);
}

test "normal execution memory attaches marked permission feedback to its tool result" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_feedback",
        .name = "write_file",
        .arguments_json = "{\"path\":\"note.txt\",\"content\":\"original\"}",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{
            .role = .tool,
            .content = "wrote note.txt",
            .tool_call_id = "call_feedback",
            .tool_name = "write_file",
            .tool_result_status = .success,
        },
        .{
            .role = .user,
            .content = "read it after writing",
            .permission_feedback = true,
        },
        .{
            .role = .user,
            .content = "then summarize the exact contents",
            .permission_feedback = true,
        },
    };

    const memory = try buildNormalChatExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);

    try std.testing.expectEqual(@as(usize, 1), memory.tool_steps.len);
    const result = memory.tool_steps[0].tool_results[0];
    try std.testing.expectEqual(@as(usize, 2), result.permission_feedback.len);
    try std.testing.expectEqualStrings("read it after writing", result.permission_feedback[0]);
    try std.testing.expectEqualStrings(
        "then summarize the exact contents",
        result.permission_feedback[1],
    );
}

test "normal execution memory scans the deferred user tail by source call" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{
        .{ .id = "call_first", .name = "run_command", .arguments_json = "{\"command\":\"printf first\"}" },
        .{ .id = "call_second", .name = "run_command", .arguments_json = "{\"command\":\"printf second\"}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "first command completed", .tool_call_id = calls[0].id, .tool_name = calls[0].name, .tool_result_status = .success },
        .{ .role = .tool, .content = "second command completed", .tool_call_id = calls[1].id, .tool_name = calls[1].name, .tool_result_status = .success },
        .{ .role = .user, .content = "first command feedback marker", .tool_call_id = calls[0].id, .permission_feedback = true },
        .{ .role = .user, .content = "custom hint", .permission_feedback = false },
        .{ .role = .user, .content = "second command feedback marker", .tool_call_id = calls[1].id, .permission_feedback = true },
    };

    const memory = try buildNormalChatExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);

    const results = memory.tool_steps[0].tool_results;
    try std.testing.expectEqual(@as(usize, 1), results[0].permission_feedback.len);
    try std.testing.expectEqualStrings("first command feedback marker", results[0].permission_feedback[0]);
    try std.testing.expectEqual(@as(usize, 1), results[1].permission_feedback.len);
    try std.testing.expectEqualStrings("second command feedback marker", results[1].permission_feedback[0]);
}

test "normal execution-memory builders produce identical durable projection" {
    const alloc = std.testing.allocator;
    var first_calls = [_]ToolCall{
        .{
            .id = "sk-abcdefghijklmnop",
            .name = "read_file",
            .arguments_json = "{\"path\":\"notes.txt\"}",
        },
        .{
            .id = "call_search",
            .name = "grep_files",
            .arguments_json = "{\"path\":\"src\",\"query\":\"needle\"}",
        },
    };
    var second_calls = [_]ToolCall{.{
        .id = "call_write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"notes.txt\",\"content\":\"updated\"}",
    }};
    const chat_messages = [_]types.ChatMessage{
        .{
            .role = .assistant,
            .content = "first assistant sk-abcdefghijklmnop",
            .tool_calls = first_calls[0..],
        },
        .{
            .role = .tool,
            .content = "ignored unmatched result",
            .tool_call_id = "unmatched",
        },
        .{
            .role = .tool,
            .content = "sk-abcdefghijklmnop full file",
            .tool_call_id = first_calls[0].id,
            .tool_name = "read_file",
            .tool_result_status = .success,
            .tool_result_memory = .{
                .model_view_covers_full_file = true,
            },
        },
        .{
            .role = .tool,
            .content = "search failed",
            .tool_call_id = first_calls[1].id,
            .tool_name = "grep_files",
            .tool_result_status = .failure,
            .tool_result_memory = .{
                .output_handle = "result-call_search-grep_files.txt",
                .preview = "search preview",
                .output_bytes = 128,
                .stored_output_bytes = 64,
                .truncated = true,
            },
        },
        .{
            .role = .user,
            .content = "after reading, summarize the file",
            .tool_call_id = first_calls[0].id,
            .permission_feedback = true,
        },
        .{ .role = .user, .content = "separator" },
        .{
            .role = .assistant,
            .tool_calls = second_calls[0..],
        },
        .{
            .role = .tool,
            .tool_call_id = second_calls[0].id,
            .tool_name = "write_file",
            .tool_result_status = .success,
        },
    };
    const message_messages = [_]message.Message{
        message.Message.assistantBorrowed(
            "first assistant sk-abcdefghijklmnop",
            first_calls[0..],
        ),
        .{
            .role = .tool,
            .content = .{ .text = "ignored unmatched result" },
            .tool_call_id = "unmatched",
        },
        .{
            .role = .tool,
            .content = .{ .text = "sk-abcdefghijklmnop full file" },
            .tool_call_id = first_calls[0].id,
            .tool_name = "read_file",
            .tool_result_status = .success,
            .tool_result_memory = .{
                .model_view_covers_full_file = true,
            },
        },
        .{
            .role = .tool,
            .content = .{ .text = "search failed" },
            .tool_call_id = first_calls[1].id,
            .tool_name = "grep_files",
            .tool_result_status = .failure,
            .tool_result_memory = .{
                .output_handle = "result-call_search-grep_files.txt",
                .preview = "search preview",
                .output_bytes = 128,
                .stored_output_bytes = 64,
                .truncated = true,
            },
        },
        .{
            .role = .user,
            .content = .{ .text = "after reading, summarize the file" },
            .tool_call_id = first_calls[0].id,
            .permission_feedback = true,
        },
        message.Message.userText("separator"),
        message.Message.assistantBorrowed(null, second_calls[0..]),
        .{
            .role = .tool,
            .tool_call_id = second_calls[0].id,
            .tool_name = "write_file",
            .tool_result_status = .success,
        },
    };

    const chat_memory = try buildNormalChatExecutionMemory(alloc, &chat_messages);
    defer types.freeExecutionMemory(alloc, chat_memory);
    const message_memory = try buildNormalMessageExecutionMemory(
        alloc,
        &message_messages,
    );
    defer types.freeExecutionMemory(alloc, message_memory);

    try expectEquivalentNormalExecutionMemory(chat_memory, message_memory);
    try std.testing.expectEqual(@as(usize, 2), chat_memory.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 3), chat_memory.files.len);
    try std.testing.expectEqualStrings(
        "read_file",
        chat_memory.tool_steps[0].tool_calls[0].name,
    );
    try std.testing.expectEqualStrings(
        "grep_files",
        chat_memory.tool_steps[0].tool_calls[1].name,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        chat_memory.tool_steps[0].tool_results[0].tool_name,
    );
    try std.testing.expectEqualStrings(
        "grep_files",
        chat_memory.tool_steps[0].tool_results[1].tool_name,
    );
    try std.testing.expectEqualStrings("notes.txt", chat_memory.files[0].path);
    try std.testing.expectEqualStrings("src", chat_memory.files[1].path);
    try std.testing.expectEqualStrings("notes.txt", chat_memory.files[2].path);
    try std.testing.expect(chat_memory.files[0].stale);
    try std.testing.expect(chat_memory.files[0].model_view_covers_full_file);
    try std.testing.expectEqual(types.PersistedToolStatus.failure, chat_memory.tool_steps[0].tool_results[1].status);
    try std.testing.expectEqual(
        @as(usize, 1),
        chat_memory.tool_steps[0].tool_results[0].permission_feedback.len,
    );
    try std.testing.expectEqualStrings(
        "after reading, summarize the file",
        chat_memory.tool_steps[0].tool_results[0].permission_feedback[0],
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        chat_memory.tool_steps[0].tool_results[1].permission_feedback.len,
    );
    try std.testing.expectEqualStrings("", chat_memory.tool_steps[1].tool_results[0].output);
    try std.testing.expect(std.mem.find(
        u8,
        chat_memory.tool_steps[0].tool_calls[0].id,
        "sk-abcdefghijklmnop",
    ) == null);
    try std.testing.expect(std.mem.find(
        u8,
        chat_memory.tool_steps[0].tool_results[0].output,
        "sk-abcdefghijklmnop",
    ) == null);
}

test "normal execution-memory builders reject missing tool result status identically" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_missing_status",
        .name = "read_file",
        .arguments_json = "{\"path\":\"missing.txt\"}",
    }};
    const chat_messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{
            .role = .tool,
            .content = "ignored unmatched",
            .tool_call_id = "unmatched",
        },
        .{
            .role = .tool,
            .content = "missing status",
            .tool_call_id = calls[0].id,
            .tool_name = calls[0].name,
        },
    };
    const message_messages = [_]message.Message{
        message.Message.assistantBorrowed(null, calls[0..]),
        .{
            .role = .tool,
            .content = .{ .text = "ignored unmatched" },
            .tool_call_id = "unmatched",
        },
        .{
            .role = .tool,
            .content = .{ .text = "missing status" },
            .tool_call_id = calls[0].id,
            .tool_name = calls[0].name,
        },
    };

    try std.testing.expectError(
        error.MissingToolResultStatus,
        buildNormalChatExecutionMemory(alloc, &chat_messages),
    );
    try std.testing.expectError(
        error.MissingToolResultStatus,
        buildNormalMessageExecutionMemory(alloc, &message_messages),
    );
}

test "normal execution-memory builders clean every allocation failure" {
    const ChatCheck = struct {
        fn run(alloc: Allocator) !void {
            var calls = [_]ToolCall{
                .{
                    .id = "call_read",
                    .name = "read_file",
                    .arguments_json = "{\"path\":\"notes.txt\"}",
                },
                .{
                    .id = "call_write",
                    .name = "write_file",
                    .arguments_json = "{\"path\":\"notes.txt\",\"content\":\"updated\"}",
                },
            };
            const messages = [_]types.ChatMessage{
                .{
                    .role = .assistant,
                    .content = "assistant",
                    .tool_calls = calls[0..],
                },
                .{
                    .role = .tool,
                    .content = "read result",
                    .tool_call_id = calls[0].id,
                    .tool_name = calls[0].name,
                    .tool_result_status = .success,
                    .tool_result_memory = .{
                        .model_view_covers_full_file = true,
                    },
                },
                .{
                    .role = .tool,
                    .content = "write result",
                    .tool_call_id = calls[1].id,
                    .tool_name = calls[1].name,
                    .tool_result_status = .success,
                    .tool_result_memory = .{
                        .output_handle = "result-call_write-write_file.txt",
                        .preview = "write preview",
                        .output_bytes = 256,
                        .stored_output_bytes = 128,
                        .truncated = true,
                    },
                },
            };

            const memory = buildNormalChatExecutionMemory(alloc, &messages) catch |err|
                return switch (err) {
                    error.WriteFailed => error.OutOfMemory,
                    else => err,
                };
            defer types.freeExecutionMemory(alloc, memory);
            try std.testing.expectEqual(@as(usize, 2), memory.files.len);
            try std.testing.expect(memory.files[0].stale);
        }
    };
    const MessageCheck = struct {
        fn run(alloc: Allocator) !void {
            var calls = [_]ToolCall{
                .{
                    .id = "call_read",
                    .name = "read_file",
                    .arguments_json = "{\"path\":\"notes.txt\"}",
                },
                .{
                    .id = "call_write",
                    .name = "write_file",
                    .arguments_json = "{\"path\":\"notes.txt\",\"content\":\"updated\"}",
                },
            };
            const messages = [_]message.Message{
                message.Message.assistantBorrowed("assistant", calls[0..]),
                .{
                    .role = .tool,
                    .content = .{ .text = "read result" },
                    .tool_call_id = calls[0].id,
                    .tool_name = calls[0].name,
                    .tool_result_status = .success,
                    .tool_result_memory = .{
                        .model_view_covers_full_file = true,
                    },
                },
                .{
                    .role = .tool,
                    .content = .{ .text = "write result" },
                    .tool_call_id = calls[1].id,
                    .tool_name = calls[1].name,
                    .tool_result_status = .success,
                    .tool_result_memory = .{
                        .output_handle = "result-call_write-write_file.txt",
                        .preview = "write preview",
                        .output_bytes = 256,
                        .stored_output_bytes = 128,
                        .truncated = true,
                    },
                },
            };

            const memory = buildNormalMessageExecutionMemory(alloc, &messages) catch |err|
                return switch (err) {
                    error.WriteFailed => error.OutOfMemory,
                    else => err,
                };
            defer types.freeExecutionMemory(alloc, memory);
            try std.testing.expectEqual(@as(usize, 2), memory.files.len);
            try std.testing.expect(memory.files[0].stale);
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ChatCheck.run,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        MessageCheck.run,
        .{},
    );
}

test "normal execution-memory builders skip non-tool messages without allocation" {
    const chat_messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "ignored" },
        .{ .role = .user, .content = "ignored" },
        .{ .role = .assistant, .content = "ignored" },
    };
    const message_messages = [_]message.Message{
        message.Message.systemText("ignored"),
        message.Message.userText("ignored"),
        message.Message.assistantBorrowed("ignored", &.{}),
    };
    var chat_failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var message_failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    const chat_memory = try buildNormalChatExecutionMemory(
        chat_failing.allocator(),
        &chat_messages,
    );
    defer types.freeExecutionMemory(chat_failing.allocator(), chat_memory);
    const message_memory = try buildNormalMessageExecutionMemory(
        message_failing.allocator(),
        &message_messages,
    );
    defer types.freeExecutionMemory(message_failing.allocator(), message_memory);

    try std.testing.expect(chat_memory.isEmpty());
    try std.testing.expect(message_memory.isEmpty());
}

fn expectEquivalentNormalExecutionMemory(
    expected: types.ExecutionMemory,
    actual: types.ExecutionMemory,
) !void {
    try std.testing.expectEqual(expected.tool_steps.len, actual.tool_steps.len);
    try std.testing.expectEqual(expected.files.len, actual.files.len);
    for (expected.tool_steps, actual.tool_steps) |expected_step, actual_step| {
        try expectOptionalStringEqual(expected_step.assistant, actual_step.assistant);
        try std.testing.expectEqual(expected_step.tool_calls.len, actual_step.tool_calls.len);
        try std.testing.expectEqual(expected_step.tool_results.len, actual_step.tool_results.len);
        for (expected_step.tool_calls, actual_step.tool_calls) |expected_call, actual_call| {
            try std.testing.expectEqualStrings(expected_call.id, actual_call.id);
            try std.testing.expectEqualStrings(expected_call.name, actual_call.name);
            try std.testing.expectEqualStrings(
                expected_call.arguments_json,
                actual_call.arguments_json,
            );
            try expectOptionalStringEqual(
                expected_call.provisional_id,
                actual_call.provisional_id,
            );
            try expectOptionalStringEqual(
                expected_call.provider_result,
                actual_call.provider_result,
            );
            try std.testing.expectEqual(
                expected_call.final_identity,
                actual_call.final_identity,
            );
            try std.testing.expectEqual(
                expected_call.provenance,
                actual_call.provenance,
            );
        }
        for (expected_step.tool_results, actual_step.tool_results) |expected_result, actual_result| {
            try std.testing.expectEqualStrings(
                expected_result.tool_call_id,
                actual_result.tool_call_id,
            );
            try std.testing.expectEqualStrings(
                expected_result.tool_name,
                actual_result.tool_name,
            );
            try std.testing.expectEqual(expected_result.status, actual_result.status);
            try std.testing.expectEqualStrings(expected_result.output, actual_result.output);
            try expectOptionalStringEqual(
                expected_result.output_handle,
                actual_result.output_handle,
            );
            try expectOptionalStringEqual(expected_result.preview, actual_result.preview);
            try std.testing.expectEqual(
                expected_result.output_bytes,
                actual_result.output_bytes,
            );
            try std.testing.expectEqual(
                expected_result.stored_output_bytes,
                actual_result.stored_output_bytes,
            );
            try std.testing.expectEqual(expected_result.truncated, actual_result.truncated);
            try std.testing.expectEqual(
                expected_result.provider_native,
                actual_result.provider_native,
            );
            try std.testing.expectEqual(
                expected_result.permission_feedback.len,
                actual_result.permission_feedback.len,
            );
            for (expected_result.permission_feedback, actual_result.permission_feedback) |expected_feedback, actual_feedback| {
                try std.testing.expectEqualStrings(expected_feedback, actual_feedback);
            }
            try std.testing.expect(expected_result.created_at_ms > 0);
            try std.testing.expect(actual_result.created_at_ms > 0);
        }
    }
    for (expected.files, actual.files) |expected_file, actual_file| {
        try std.testing.expectEqualStrings(expected_file.path, actual_file.path);
        try expectOptionalStringEqual(expected_file.new_path, actual_file.new_path);
        try std.testing.expectEqualStrings(
            expected_file.tool_call_id,
            actual_file.tool_call_id,
        );
        try std.testing.expectEqualStrings(expected_file.tool_name, actual_file.tool_name);
        try std.testing.expectEqual(expected_file.action, actual_file.action);
        try std.testing.expectEqual(expected_file.status, actual_file.status);
        try std.testing.expectEqual(
            expected_file.model_view_covers_full_file,
            actual_file.model_view_covers_full_file,
        );
        try std.testing.expectEqual(expected_file.stale, actual_file.stale);
    }
}

fn expectOptionalStringEqual(
    expected: ?[]const u8,
    actual: ?[]const u8,
) !void {
    if (expected) |expected_text| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(expected_text, actual.?);
    } else {
        try std.testing.expect(actual == null);
    }
}
