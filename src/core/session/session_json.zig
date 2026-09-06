const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const types = @import("../shared/types.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;
const legacy_schema_v1: i64 = 1;
const legacy_schema_v2: i64 = 2;

pub const LegacySchemaVersion = enum(u8) {
    v1 = 1,
    v2 = 2,
};

const TestStoredSession = struct {
    id: []u8,
    workspace_root: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    history: []session.HistoryTurn,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,

    fn deinit(self: *TestStoredSession, alloc: Allocator) void {
        if (self.id.len > 0) alloc.free(self.id);
        if (self.workspace_root) |workspace_root| alloc.free(workspace_root);
        session.freeHistoryTurnSlice(alloc, self.history);
        self.* = undefined;
    }
};

/// Renders one session record as JSON; caller owns the returned slice and frees with allocator.free.
pub const SessionTokenUsage = struct {
    input: u64 = 0,
    output: u64 = 0,
    web_search_requests: u64 = 0,
};

pub noinline fn renderSessionJson(
    alloc: Allocator,
    active_id: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    language: session.ConversationLanguage,
    workspace_root: []const u8,
    history: []const session.HistoryTurn,
    token_usage: SessionTokenUsage,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"schema_version\":1,\"id\":");
    try std.json.Stringify.value(active_id, .{}, &out.writer);
    try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{ created_at_ms, updated_at_ms });
    try out.writer.writeAll(",\"workspace_root\":");
    try std.json.Stringify.value(workspace_root, .{}, &out.writer);
    try out.writer.writeAll(",\"conversation_language\":");
    try std.json.Stringify.value(language.view(), .{}, &out.writer);
    if (token_usage.input > 0 or token_usage.output > 0) {
        try out.writer.print(",\"total_input_tokens\":{d},\"total_output_tokens\":{d}", .{ token_usage.input, token_usage.output });
    }
    if (token_usage.web_search_requests > 0) {
        try out.writer.print(",\"total_web_search_requests\":{d}", .{token_usage.web_search_requests});
    }
    try out.writer.print(",\"history_len\":{d},\"history\":[", .{history.len});

    for (history, 0..) |turn, i| {
        if (i > 0) try out.writer.writeByte(',');
        try writeHistoryTurnJson(&out.writer, turn);
    }

    try out.writer.writeAll("]}");
    return try out.toOwnedSlice();
}

fn writeHistoryTurnJson(writer: *std.Io.Writer, turn: session.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.writeAll("{\"kind\":\"compacted_summary\",\"summary\":");
            try std.json.Stringify.value(entry.summary, .{}, writer);
            try writer.print(",\"removed_turn_count\":{d},\"compaction_count\":{d}", .{ entry.removed_turn_count, entry.compaction_count });
            try writer.writeByte('}');
        },
        .assistant => |entry| {
            try writer.writeAll("{\"kind\":\"assistant\",\"user\":");
            try writeUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            try std.json.Stringify.value(entry.assistant, .{}, writer);
            if (!entry.execution.isEmpty()) {
                try writer.writeAll(",\"execution\":");
                try writeExecutionMemoryJson(writer, entry.execution);
            }
            try writer.writeByte('}');
        },
        .interrupted => |entry| {
            try writer.writeAll("{\"kind\":\"interrupted\",\"user\":");
            try writeUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            if (entry.assistant) |assistant| {
                try std.json.Stringify.value(assistant, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"tool_call\":");
            if (entry.tool_call) |tool_call| {
                try writeToolCallJson(writer, tool_call);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"completed_tool_names\":");
            try writeStringArrayJson(writer, entry.completed_tool_names);
            try writer.writeAll(",\"terminal_reason\":");
            try std.json.Stringify.value(@tagName(entry.terminal_reason), .{}, writer);
            if (!entry.execution.isEmpty()) {
                try writer.writeAll(",\"execution\":");
                try writeExecutionMemoryJson(writer, entry.execution);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeToolCallJson(writer: *std.Io.Writer, tool_call: session.ToolCall) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(tool_call.id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(tool_call.name, .{}, writer);
    try writer.writeAll(",\"arguments_json\":");
    try std.json.Stringify.value(tool_call.arguments_json, .{}, writer);
    try writer.writeAll(",\"provider_result\":");
    if (tool_call.provider_result) |provider_result| {
        try std.json.Stringify.value(provider_result, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

pub fn writeExecutionMemoryJson(writer: *std.Io.Writer, execution: session.ExecutionMemory) !void {
    try writer.writeAll("{\"schema_version\":3,\"tool_steps\":[");
    for (execution.tool_steps, 0..) |step, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"assistant\":");
        if (step.assistant) |assistant| {
            try std.json.Stringify.value(assistant, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"tool_calls\":[");
        for (step.tool_calls, 0..) |tool_call, call_index| {
            if (call_index > 0) try writer.writeByte(',');
            try writeToolCallJson(writer, tool_call);
        }
        try writer.writeAll("],\"tool_results\":[");
        for (step.tool_results, 0..) |result, result_index| {
            if (result_index > 0) try writer.writeByte(',');
            try writePersistedToolResultJson(writer, result);
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("],\"files\":[");
    for (execution.files, 0..) |file, i| {
        if (i > 0) try writer.writeByte(',');
        try writeFileEvidenceJson(writer, file);
    }
    try writer.writeAll("],\"steering\":[");
    for (execution.steering, 0..) |steering, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"text\":");
        try std.json.Stringify.value(steering.text, .{}, writer);
        try writer.writeAll(",\"assistant_prefix\":");
        if (steering.assistant_prefix) |prefix| {
            try std.json.Stringify.value(prefix, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"after_tool_step_count\":{d}}}", .{steering.after_tool_step_count});
    }
    try writer.writeAll("]}");
}

fn writePersistedToolResultJson(writer: *std.Io.Writer, result: session.PersistedToolResult) !void {
    try writer.writeAll("{\"tool_call_id\":");
    try std.json.Stringify.value(result.tool_call_id, .{}, writer);
    try writer.writeAll(",\"tool_name\":");
    try std.json.Stringify.value(result.tool_name, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(@tagName(result.status), .{}, writer);
    try writer.writeAll(",\"output\":");
    try std.json.Stringify.value(result.output, .{}, writer);
    if (result.output_handle) |handle| {
        try writer.writeAll(",\"output_handle\":");
        try std.json.Stringify.value(handle, .{}, writer);
    }
    if (result.preview) |preview| {
        try writer.writeAll(",\"preview\":");
        try std.json.Stringify.value(preview, .{}, writer);
    }
    try writer.print(",\"output_bytes\":{d},\"stored_output_bytes\":{d},\"truncated\":{s},\"provider_native\":{s},\"created_at_ms\":{d}", .{
        result.output_bytes,
        result.stored_output_bytes,
        if (result.truncated) "true" else "false",
        if (result.provider_native) "true" else "false",
        result.created_at_ms,
    });
    try writer.writeAll(",\"permission_feedback\":[");
    for (result.permission_feedback, 0..) |feedback, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.value(feedback, .{}, writer);
    }
    try writer.writeByte(']');
    if (result.committed_file_presentation) |presentation| {
        try writer.writeAll(",\"committed_file_presentation\":");
        try writeCommittedFilePresentationJson(writer, presentation);
    }
    try writer.writeByte('}');
}

fn writeCommittedFilePresentationJson(
    writer: *std.Io.Writer,
    presentation: types.CommittedFilePresentation,
) !void {
    try writer.writeAll("{\"path\":");
    try std.json.Stringify.value(presentation.path, .{}, writer);
    try writer.writeAll(",\"kind\":");
    try std.json.Stringify.value(@tagName(presentation.kind), .{}, writer);
    try writer.writeAll(",\"lines\":[");
    for (presentation.lines, 0..) |line, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"kind\":");
        try std.json.Stringify.value(@tagName(line.kind), .{}, writer);
        try writer.writeAll(",\"old_line\":");
        try writeOptionalU32Json(writer, line.old_line);
        try writer.writeAll(",\"new_line\":");
        try writeOptionalU32Json(writer, line.new_line);
        try writer.writeAll(",\"text\":");
        try std.json.Stringify.value(line.text, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.print("],\"additions\":{d},\"deletions\":{d},\"truncated\":{s},\"previous_content\":", .{
        presentation.additions,
        presentation.deletions,
        if (presentation.truncated) "true" else "false",
    });
    try writeOptionalStringJson(writer, presentation.previous_content);
    try writer.writeAll(",\"after_content\":");
    try writeOptionalStringJson(writer, presentation.after_content);
    try writer.writeAll(",\"lifecycle_id\":");
    if (presentation.lifecycle_id) |id| {
        try writer.print("{{\"turn_id\":{d},\"call_id\":", .{id.turn_id});
        try std.json.Stringify.value(id.call_id, .{}, writer);
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeOptionalU32Json(writer: *std.Io.Writer, value: ?u32) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalStringJson(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn writeFileEvidenceJson(writer: *std.Io.Writer, file: session.FileEvidence) !void {
    try writer.writeAll("{\"path\":");
    try std.json.Stringify.value(file.path, .{}, writer);
    try writer.writeAll(",\"new_path\":");
    if (file.new_path) |new_path| {
        try std.json.Stringify.value(new_path, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"tool_call_id\":");
    try std.json.Stringify.value(file.tool_call_id, .{}, writer);
    try writer.writeAll(",\"tool_name\":");
    try std.json.Stringify.value(file.tool_name, .{}, writer);
    try writer.writeAll(",\"action\":");
    try std.json.Stringify.value(@tagName(file.action), .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(@tagName(file.status), .{}, writer);
    try writer.print(",\"model_view_covers_full_file\":{s},\"stale\":{s}", .{
        if (file.model_view_covers_full_file) "true" else "false",
        if (file.stale) "true" else "false",
    });
    try writer.writeByte('}');
}

fn writeUserTurnJson(writer: *std.Io.Writer, user: session.UserTurn) !void {
    try writer.writeAll("{\"text\":");
    try std.json.Stringify.value(user.text, .{}, writer);
    try writer.writeAll(",\"images\":[");
    for (user.images, 0..) |image, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(image.path, .{}, writer);
        try writer.writeAll(",\"media_type\":");
        try std.json.Stringify.value(image.media_type, .{}, writer);
        try writer.writeAll(",\"snapshot_path\":");
        try writeImageSnapshotLocatorJson(writer, image.snapshot_path);
        try writer.writeAll(",\"snapshot_sha256\":");
        try std.json.Stringify.value(image.snapshot_sha256, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn writeImageSnapshotLocatorJson(writer: *std.Io.Writer, value: ?[]const u8) !void {
    const path = value orelse {
        try writer.writeAll("null");
        return;
    };
    var locator_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const locator = try session.projectSnapshotLocator(&locator_buffer, path);
    try std.json.Stringify.value(locator, .{}, writer);
}

test "ordinary session JSON presentation omits per-turn work provenance" {
    const alloc = std.testing.allocator;
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{
            .text = @constCast("canonical prompt"),
            .work_id = @constCast("work-private"),
        },
        .assistant = @constCast("canonical reply"),
    } }};
    const json = try renderSessionJson(
        alloc,
        "presentation",
        1,
        2,
        session.ConversationLanguage.literal("en"),
        "/tmp/workspace",
        &history,
        .{},
    );
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "work-private") == null);
    try std.testing.expect(std.mem.find(u8, json, "work_id") == null);
    try std.testing.expect(std.mem.find(u8, json, "canonical prompt") != null);
}

fn writeStringArrayJson(writer: *std.Io.Writer, items: anytype) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.value(item, .{}, writer);
    }
    try writer.writeByte(']');
}

/// Parses a session summary; caller owns returned fields and frees with SessionSummary.deinit.
pub fn parseSessionSummary(comptime SessionSummary: type, alloc: Allocator, json_text: []const u8) !SessionSummary {
    var source = std.Io.Reader.fixed(json_text);
    return parseLegacySummaryStreaming(SessionSummary, alloc, &source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedSessionSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
}

pub fn parseLegacySummaryStreaming(
    comptime LegacySummary: type,
    alloc: Allocator,
    source: *std.Io.Reader,
) !LegacySummary {
    return parseLegacySummaryStreamingImpl(LegacySummary, alloc, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
        error.UnsupportedSessionSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
}

fn parseLegacySummaryStreamingImpl(
    comptime LegacySummary: type,
    alloc: Allocator,
    source: *std.Io.Reader,
) !LegacySummary {
    var reader = std.json.Reader.init(alloc, source);
    defer reader.deinit();
    try expectToken(try reader.next(), .object_begin);

    var schema_version: ?i64 = null;
    var id: ?[]u8 = null;
    errdefer if (id) |owned| alloc.free(owned);
    var workspace_root: ?[]u8 = null;
    errdefer if (workspace_root) |owned| alloc.free(owned);
    var workspace_root_seen = false;
    var created_at_ms: ?i64 = null;
    var updated_at_ms: ?i64 = null;
    var conversation_language: ?session.ConversationLanguage = null;
    var history_len: ?usize = null;

    while (true) {
        const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 64);
        defer freeToken(alloc, token);
        if (token == .object_end) break;
        const key = switch (token) {
            .string => |value| value,
            .allocated_string => |value| value,
            else => return error.InvalidSessionFormat,
        };

        if (std.mem.eql(u8, key, "history")) {
            if (summaryComplete(
                schema_version,
                id,
                created_at_ms,
                updated_at_ms,
                conversation_language,
                history_len,
            )) {
                try requireLegacySchema(schema_version.?);
                var result: LegacySummary = .{
                    .id = id.?,
                    .workspace_root = workspace_root,
                    .created_at_ms = created_at_ms.?,
                    .updated_at_ms = updated_at_ms.?,
                    .conversation_language = conversation_language.?,
                    .history_len = history_len.?,
                };
                if (@hasField(LegacySummary, "schema_version")) {
                    @field(result, "schema_version") = try legacySchemaVersion(schema_version.?);
                }
                return result;
            }
            try reader.skipValue();
            continue;
        }
        if (std.mem.eql(u8, key, "schema_version")) {
            if (schema_version != null) return error.InvalidSessionFormat;
            schema_version = try readI64Token(&reader, alloc);
        } else if (std.mem.eql(u8, key, "id")) {
            if (id != null) return error.InvalidSessionFormat;
            id = try readStringOwned(&reader, alloc, 255);
        } else if (std.mem.eql(u8, key, "workspace_root")) {
            if (workspace_root_seen) return error.InvalidSessionFormat;
            workspace_root_seen = true;
            workspace_root = try readOptionalStringOwned(
                &reader,
                alloc,
                std.Io.Dir.max_path_bytes,
            );
        } else if (std.mem.eql(u8, key, "created_at_ms")) {
            if (created_at_ms != null) return error.InvalidSessionFormat;
            created_at_ms = try readI64Token(&reader, alloc);
        } else if (std.mem.eql(u8, key, "updated_at_ms")) {
            if (updated_at_ms != null) return error.InvalidSessionFormat;
            updated_at_ms = try readI64Token(&reader, alloc);
        } else if (std.mem.eql(u8, key, "conversation_language")) {
            if (conversation_language != null) return error.InvalidSessionFormat;
            const raw = try readStringOwned(
                &reader,
                alloc,
                session.ConversationLanguage.max_len,
            );
            defer alloc.free(raw);
            conversation_language = try parseConversationLanguage(raw);
        } else if (std.mem.eql(u8, key, "history_len")) {
            if (history_len != null) return error.InvalidSessionFormat;
            const value = try readU64Token(&reader, alloc);
            if (value > std.math.maxInt(usize)) return error.InvalidSessionFormat;
            history_len = @intCast(value);
        } else {
            try reader.skipValue();
        }
    }

    if (!summaryComplete(
        schema_version,
        id,
        created_at_ms,
        updated_at_ms,
        conversation_language,
        history_len,
    )) return error.InvalidSessionFormat;
    try requireLegacySchema(schema_version.?);
    try expectToken(try reader.next(), .end_of_document);
    var result: LegacySummary = .{
        .id = id.?,
        .workspace_root = workspace_root,
        .created_at_ms = created_at_ms.?,
        .updated_at_ms = updated_at_ms.?,
        .conversation_language = conversation_language.?,
        .history_len = history_len.?,
    };
    if (@hasField(LegacySummary, "schema_version")) {
        @field(result, "schema_version") = try legacySchemaVersion(schema_version.?);
    }
    return result;
}

/// Parses a full stored session; caller owns returned fields and frees with StoredSession.deinit.
pub noinline fn parseStoredSession(comptime StoredSession: type, alloc: Allocator, json_text: []const u8) !StoredSession {
    return parseLegacyExact(StoredSession, alloc, json_text);
}

pub fn parseLegacyExact(
    comptime LegacySession: type,
    alloc: Allocator,
    json_text: []const u8,
) !LegacySession {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();

    const root = try requireObject(parsed.value);
    try requireSchemaVersion(root);

    const history_value = root.get("history") orelse return error.InvalidSessionFormat;
    if (history_value != .array) return error.InvalidSessionFormat;

    const history: []session.HistoryTurn = if (history_value.array.items.len > 0)
        try alloc.alloc(session.HistoryTurn, history_value.array.items.len)
    else
        &.{};
    errdefer if (history.len > 0) alloc.free(history);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) session.freeHistoryTurn(alloc, history[i]);
    }
    for (history_value.array.items, 0..) |entry, i| {
        history[i] = try parseLegacyHistoryTurn(alloc, entry);
        parsed_count += 1;
    }

    if (try requireUsize(root, "history_len") != history.len) return error.InvalidSessionFormat;
    const id = try alloc.dupe(u8, try requireString(root, "id"));
    errdefer alloc.free(id);
    const workspace_root = try optionalStringDup(alloc, root.get("workspace_root"));
    errdefer if (workspace_root) |wr| alloc.free(wr);
    const language = try parseConversationLanguage(try requireString(root, "conversation_language"));

    const total_input_tokens: u64 = if (root.get("total_input_tokens")) |v| blk: {
        if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        break :blk 0;
    } else 0;
    const total_output_tokens: u64 = if (root.get("total_output_tokens")) |v| blk: {
        if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        break :blk 0;
    } else 0;
    const total_web_search_requests: u64 = if (root.get("total_web_search_requests")) |v| blk: {
        if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        break :blk 0;
    } else 0;

    return .{
        .id = id,
        .workspace_root = workspace_root,
        .created_at_ms = try requireI64(root, "created_at_ms"),
        .updated_at_ms = try requireI64(root, "updated_at_ms"),
        .conversation_language = language,
        .history = history,
        .total_input_tokens = total_input_tokens,
        .total_output_tokens = total_output_tokens,
        .total_web_search_requests = total_web_search_requests,
    };
}

pub fn parseLegacySchemaVersion(
    alloc: Allocator,
    json_text: []const u8,
) !LegacySchemaVersion {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        json_text,
        .{},
    ) catch return error.InvalidSessionFormat;
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    return legacySchemaVersion(try requireI64(root, "schema_version"));
}

fn formatLegacyBackgroundAssistant(
    alloc: Allocator,
    assistant: ?[]const u8,
    log_path: []const u8,
    url: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    if (assistant) |text| {
        if (text.len != 0) {
            try out.writer.writeAll(text);
            if (!std.mem.endsWith(u8, text, "\n")) try out.writer.writeByte('\n');
        }
    }
    try out.writer.writeAll(
        "[Historical command record: fx no longer owns or controls this process",
    );
    if (log_path.len != 0) try out.writer.print("; former log={s}", .{log_path});
    if (url) |value| try out.writer.print("; recorded url={s}", .{value});
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn parseLegacyHistoryTurn(alloc: Allocator, value: std.json.Value) !session.HistoryTurn {
    const object = try requireObject(value);
    const kind = try requireString(object, "kind");

    if (std.mem.eql(u8, kind, "compacted_summary")) {
        const root_user_messages: [][]u8 = if (object.get("root_user_messages")) |messages_value| blk: {
            if (messages_value != .array) return error.InvalidSessionFormat;
            const messages = try alloc.alloc([]u8, messages_value.array.items.len);
            errdefer alloc.free(messages);
            var copied: usize = 0;
            errdefer for (messages[0..copied]) |message| alloc.free(message);
            for (messages_value.array.items, 0..) |item, index| {
                if (item != .string) return error.InvalidSessionFormat;
                messages[index] = try alloc.dupe(u8, item.string);
                copied += 1;
            }
            break :blk messages;
        } else &.{};
        errdefer session.freeCompletedToolNames(alloc, root_user_messages);
        const permission_feedback = try parseOptionalStringArray(
            alloc,
            object.get("permission_feedback"),
        );
        errdefer types.freePermissionFeedback(alloc, permission_feedback);
        const removed_turn_count = try requireUsize(object, "removed_turn_count");
        return .{ .compacted_summary = .{
            .summary = try alloc.dupe(u8, try requireString(object, "summary")),
            .removed_turn_count = removed_turn_count,
            .compaction_count = try requireUsize(object, "compaction_count"),
            .root_user_messages = root_user_messages,
            .root_user_messages_complete = if (object.get("root_user_messages_complete") != null)
                try requireBool(object, "root_user_messages_complete")
            else
                object.get("root_user_messages") != null or removed_turn_count == 0,
            .permission_feedback = permission_feedback,
            .permission_feedback_complete = if (object.get("permission_feedback_complete") != null)
                try requireBool(object, "permission_feedback_complete")
            else
                removed_turn_count == 0,
        } };
    }
    if (std.mem.eql(u8, kind, "assistant")) {
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const assistant = try alloc.dupe(u8, try requireString(object, "assistant"));
        errdefer alloc.free(assistant);
        const execution = try parseOptionalExecutionMemory(alloc, object.get("execution"));
        errdefer session.freeExecutionMemory(alloc, execution);
        return .{ .assistant = .{
            .user = user,
            .assistant = assistant,
            .execution = execution,
        } };
    }
    if (std.mem.eql(u8, kind, "background_command")) {
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const legacy_assistant = try optionalStringDup(alloc, object.get("assistant"));
        defer if (legacy_assistant) |text| alloc.free(text);
        const execution = try parseOptionalExecutionMemory(alloc, object.get("execution"));
        errdefer session.freeExecutionMemory(alloc, execution);
        const log_path = try alloc.dupe(u8, try requireString(object, "log_path"));
        defer alloc.free(log_path);
        const url = try optionalStringDup(alloc, object.get("url"));
        defer if (url) |value_copy| alloc.free(value_copy);
        _ = try requireBool(object, "expect_url");
        _ = try parseOptionalBackgroundRecordId(
            object.get("background_record_id"),
        );
        const assistant = try formatLegacyBackgroundAssistant(
            alloc,
            legacy_assistant,
            log_path,
            url,
        );
        return .{ .assistant = .{
            .user = user,
            .assistant = assistant,
            .execution = execution,
        } };
    }
    if (std.mem.eql(u8, kind, "interrupted")) {
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const assistant = try optionalStringDup(alloc, object.get("assistant"));
        errdefer if (assistant) |text| alloc.free(text);
        const tool_call = try parseOptionalToolCall(alloc, object.get("tool_call"));
        errdefer if (tool_call) |call| session.freeToolCall(alloc, call);
        const completed_tool_names = try parseOptionalStringArray(alloc, object.get("completed_tool_names"));
        errdefer session.freeCompletedToolNames(alloc, completed_tool_names);
        const terminal_reason = try parseLegacyInterruptedTerminalReason(object.get("terminal_reason"));
        const execution = try parseOptionalExecutionMemory(alloc, object.get("execution"));
        return .{ .interrupted = .{
            .user = user,
            .assistant = assistant,
            .tool_call = tool_call,
            .completed_tool_names = completed_tool_names,
            .execution = execution,
            .terminal_reason = terminal_reason,
        } };
    }

    return error.InvalidSessionFormat;
}

fn parseLegacyInterruptedTerminalReason(
    value: ?std.json.Value,
) !session.InterruptedTerminalReason {
    const raw = value orelse return .cancelled;
    if (raw != .string) return error.InvalidSessionFormat;
    if (std.mem.eql(u8, raw.string, "cancelled")) return .cancelled;
    if (std.mem.eql(u8, raw.string, "failed")) return .failed;
    return error.InvalidSessionFormat;
}

fn parseOptionalToolCall(alloc: Allocator, maybe_value: ?std.json.Value) !?session.ToolCall {
    const value = maybe_value orelse return null;
    var call: ?session.ToolCall = switch (value) {
        .null => null,
        .object => try parseToolCall(alloc, value),
        else => return error.InvalidSessionFormat,
    };
    errdefer if (call) |owned| session.freeToolCall(alloc, owned);
    if (call) |*parsed| {
        try session.repairPersistedInterruptedToolArguments(alloc, parsed, .legacy);
    }
    return call;
}

fn parseToolCall(alloc: Allocator, value: std.json.Value) !session.ToolCall {
    const object = try requireObject(value);
    const id = try alloc.dupe(u8, try requireString(object, "id"));
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, try requireString(object, "name"));
    errdefer alloc.free(name);
    const raw_arguments_json = try requireString(object, "arguments_json");
    const argument_integrity = try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, raw_arguments_json);
    const arguments_json = try alloc.dupe(u8, if (argument_integrity == .malformed_json) "{}" else raw_arguments_json);
    errdefer alloc.free(arguments_json);
    const provider_result = try optionalStringDup(alloc, object.get("provider_result"));
    errdefer if (provider_result) |result| alloc.free(result);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .argument_integrity = argument_integrity,
        .provider_result = provider_result,
    };
}

fn parseOptionalExecutionMemory(alloc: Allocator, maybe_value: ?std.json.Value) !session.ExecutionMemory {
    const value = maybe_value orelse return .{};
    if (value == .null) return .{};
    const object = try requireObject(value);
    const schema_version: i64 = if (object.get("schema_version")) |version| blk: {
        if (version != .integer or version.integer < 1 or version.integer > 3) {
            return error.InvalidSessionFormat;
        }
        break :blk version.integer;
    } else 1;
    const tool_steps = try parseToolExecutionSteps(
        alloc,
        object.get("tool_steps"),
        schema_version,
    );
    errdefer session.freeExecutionMemory(alloc, .{ .tool_steps = tool_steps });
    const steering = try parseOptionalSteering(
        alloc,
        object.get("steering"),
        schema_version,
        tool_steps.len,
    );
    errdefer types.freePersistedSteering(alloc, steering);
    const files = try parseFileEvidenceSlice(alloc, object.get("files"));
    return .{ .tool_steps = tool_steps, .files = files, .steering = steering };
}

fn parseOptionalSteering(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
    schema_version: i64,
    tool_step_count: usize,
) ![]types.PersistedSteering {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const steering = try alloc.alloc(types.PersistedSteering, value.array.items.len);
    errdefer alloc.free(steering);
    var parsed_count: usize = 0;
    errdefer for (steering[0..parsed_count]) |item| {
        alloc.free(item.text);
        if (item.assistant_prefix) |prefix| alloc.free(prefix);
    };
    var prior_tool_step_count: usize = 0;
    for (value.array.items, 0..) |item, index| {
        const parsed = if (schema_version <= 2)
            types.PersistedSteering{
                .text = try alloc.dupe(u8, if (item == .string) item.string else return error.InvalidSessionFormat),
                .after_tool_step_count = tool_step_count,
            }
        else blk: {
            const object = try requireObject(item);
            const after_tool_step_count = try requireUsize(object, "after_tool_step_count");
            if (after_tool_step_count > tool_step_count or
                (index > 0 and after_tool_step_count < prior_tool_step_count))
            {
                return error.InvalidSessionFormat;
            }
            const text = try alloc.dupe(u8, try requireString(object, "text"));
            const assistant_prefix = optionalStringDup(
                alloc,
                object.get("assistant_prefix"),
            ) catch |err| {
                alloc.free(text);
                return err;
            };
            break :blk types.PersistedSteering{
                .text = text,
                .assistant_prefix = assistant_prefix,
                .after_tool_step_count = after_tool_step_count,
            };
        };
        steering[index] = parsed;
        parsed_count += 1;
        prior_tool_step_count = parsed.after_tool_step_count;
    }
    return steering;
}

fn parseToolExecutionSteps(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
    schema_version: i64,
) ![]session.ToolExecutionStep {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const steps = try alloc.alloc(session.ToolExecutionStep, value.array.items.len);
    errdefer alloc.free(steps);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) freeParsedToolExecutionStep(alloc, steps[i]);
    }

    for (value.array.items, 0..) |item, i| {
        const object = try requireObject(item);
        const assistant = try optionalStringDup(alloc, object.get("assistant"));
        errdefer if (assistant) |text| alloc.free(text);
        const tool_calls = try parseToolCallArray(alloc, object.get("tool_calls"));
        errdefer session.freeToolCallSlice(alloc, tool_calls);
        const tool_results = try parsePersistedToolResultArray(
            alloc,
            object.get("tool_results"),
            schema_version,
        );
        errdefer session.freePersistedToolResults(alloc, tool_results);
        try session.repairPersistedToolArguments(alloc, tool_calls, tool_results, .legacy);
        steps[i] = .{
            .assistant = assistant,
            .tool_calls = tool_calls,
            .tool_results = tool_results,
        };
        parsed_count += 1;
    }
    return steps;
}

fn parseToolCallArray(alloc: Allocator, maybe_value: ?std.json.Value) ![]session.ToolCall {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const calls = try alloc.alloc(session.ToolCall, value.array.items.len);
    errdefer alloc.free(calls);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) session.freeToolCall(alloc, calls[i]);
    }

    for (value.array.items, 0..) |item, i| {
        calls[i] = try parseToolCall(alloc, item);
        parsed_count += 1;
    }
    return calls;
}

fn parsePersistedToolResultArray(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
    schema_version: i64,
) ![]session.PersistedToolResult {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const results = try alloc.alloc(session.PersistedToolResult, value.array.items.len);
    errdefer alloc.free(results);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) freeParsedPersistedToolResult(alloc, results[i]);
    }

    for (value.array.items, 0..) |item, i| {
        results[i] = try parsePersistedToolResult(alloc, item, schema_version);
        parsed_count += 1;
    }
    return results;
}

fn parsePersistedToolResult(
    alloc: Allocator,
    value: std.json.Value,
    schema_version: i64,
) !session.PersistedToolResult {
    const object = try requireObject(value);
    const tool_call_id = try alloc.dupe(u8, try requireString(object, "tool_call_id"));
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, try requireString(object, "tool_name"));
    errdefer alloc.free(tool_name);
    const output = try alloc.dupe(u8, try requireString(object, "output"));
    errdefer alloc.free(output);
    const output_handle = try optionalStringDup(alloc, object.get("output_handle"));
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = try optionalStringDup(alloc, object.get("preview"));
    errdefer if (preview) |text| alloc.free(text);
    const permission_feedback: [][]u8 = if (schema_version == 1)
        &.{}
    else blk: {
        const feedback_value = object.get("permission_feedback") orelse return error.InvalidSessionFormat;
        if (feedback_value != .array) return error.InvalidSessionFormat;
        break :blk try parseOptionalStringArray(alloc, feedback_value);
    };
    errdefer types.freePermissionFeedback(alloc, permission_feedback);
    const committed_file_presentation = if (object.get("committed_file_presentation")) |presentation_value|
        try parseCommittedFilePresentation(alloc, presentation_value)
    else
        null;
    errdefer if (committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    };
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = try parsePersistedToolStatus(try requireString(object, "status")),
        .output = output,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = try requireUsize(object, "output_bytes"),
        .stored_output_bytes = try requireUsize(object, "stored_output_bytes"),
        .truncated = try requireBool(object, "truncated"),
        .provider_native = try requireBool(object, "provider_native"),
        .created_at_ms = try requireI64(object, "created_at_ms"),
        .permission_feedback = permission_feedback,
        .committed_file_presentation = committed_file_presentation,
    };
}

fn parseCommittedFilePresentation(
    alloc: Allocator,
    value: std.json.Value,
) !types.CommittedFilePresentation {
    const object = try requireObject(value);
    const path = try alloc.dupe(u8, try requireString(object, "path"));
    errdefer alloc.free(path);
    const lines = try parseCommittedFilePresentationLines(alloc, object.get("lines"));
    errdefer {
        for (lines) |line| alloc.free(@constCast(line.text));
        if (lines.len > 0) alloc.free(@constCast(lines));
    }
    const previous_content = try optionalStringDup(alloc, object.get("previous_content"));
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = try optionalStringDup(alloc, object.get("after_content"));
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id = try parseOptionalLifecycleId(alloc, object.get("lifecycle_id"));
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    return .{
        .path = path,
        .kind = try parseCommittedFilePresentationKind(try requireString(object, "kind")),
        .lines = lines,
        .additions = try requireUsize(object, "additions"),
        .deletions = try requireUsize(object, "deletions"),
        .truncated = try requireBool(object, "truncated"),
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
    };
}

fn parseCommittedFilePresentationLines(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
) ![]types.CommittedFilePresentationLine {
    const value = maybe_value orelse return error.InvalidSessionFormat;
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, value.array.items.len);
    errdefer alloc.free(lines);
    var parsed_count: usize = 0;
    errdefer for (lines[0..parsed_count]) |line| alloc.free(@constCast(line.text));
    for (value.array.items, 0..) |item, index| {
        const object = try requireObject(item);
        lines[index] = .{
            .kind = try parseCommittedFilePresentationLineKind(try requireString(object, "kind")),
            .old_line = try optionalU32(object.get("old_line")),
            .new_line = try optionalU32(object.get("new_line")),
            .text = try alloc.dupe(u8, try requireString(object, "text")),
        };
        parsed_count += 1;
    }
    return lines;
}

fn parseOptionalLifecycleId(
    alloc: Allocator,
    maybe_value: ?std.json.Value,
) !?types.ToolLifecycleId {
    const value = maybe_value orelse return null;
    if (value == .null) return null;
    const object = try requireObject(value);
    const call_id = try alloc.dupe(u8, try requireString(object, "call_id"));
    errdefer alloc.free(call_id);
    return .{
        .turn_id = @intCast(try requireUsize(object, "turn_id")),
        .call_id = call_id,
    };
}

test "session JSON frees lifecycle call id when turn id is invalid" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"call_id\":\"call_lifecycle\",\"turn_id\":-1}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidSessionFormat,
        parseOptionalLifecycleId(alloc, parsed.value),
    );
}

fn optionalU32(maybe_value: ?std.json.Value) !?u32 {
    const value = maybe_value orelse return error.InvalidSessionFormat;
    if (value == .null) return null;
    if (value != .integer or value.integer < 0) return error.InvalidSessionFormat;
    return std.math.cast(u32, value.integer) orelse error.InvalidSessionFormat;
}

fn parseCommittedFilePresentationKind(
    value: []const u8,
) !types.CommittedFilePresentationKind {
    if (std.mem.eql(u8, value, "added")) return .added;
    if (std.mem.eql(u8, value, "edited")) return .edited;
    return error.InvalidSessionFormat;
}

fn parseCommittedFilePresentationLineKind(
    value: []const u8,
) !types.CommittedFilePresentationLineKind {
    if (std.mem.eql(u8, value, "context")) return .context;
    if (std.mem.eql(u8, value, "addition")) return .addition;
    if (std.mem.eql(u8, value, "deletion")) return .deletion;
    if (std.mem.eql(u8, value, "elision")) return .elision;
    if (std.mem.eql(u8, value, "notice")) return .notice;
    return error.InvalidSessionFormat;
}

fn parseFileEvidenceSlice(alloc: Allocator, maybe_value: ?std.json.Value) ![]session.FileEvidence {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const files = try alloc.alloc(session.FileEvidence, value.array.items.len);
    errdefer alloc.free(files);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) freeParsedFileEvidence(alloc, files[i]);
    }

    for (value.array.items, 0..) |item, i| {
        files[i] = try parseFileEvidence(alloc, item);
        parsed_count += 1;
    }
    return files;
}

fn parseFileEvidence(alloc: Allocator, value: std.json.Value) !session.FileEvidence {
    const object = try requireObject(value);
    const path = try alloc.dupe(u8, try requireString(object, "path"));
    errdefer alloc.free(path);
    const new_path = try optionalStringDup(alloc, object.get("new_path"));
    errdefer if (new_path) |path_copy| alloc.free(path_copy);
    const tool_call_id = try alloc.dupe(u8, try requireString(object, "tool_call_id"));
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, try requireString(object, "tool_name"));
    errdefer alloc.free(tool_name);
    return .{
        .path = path,
        .new_path = new_path,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .action = try parseFileEvidenceAction(try requireString(object, "action")),
        .status = try parsePersistedToolStatus(try requireString(object, "status")),
        .model_view_covers_full_file = try requireBool(object, "model_view_covers_full_file"),
        .stale = try requireBool(object, "stale"),
    };
}

fn parsePersistedToolStatus(value: []const u8) !session.PersistedToolStatus {
    if (std.mem.eql(u8, value, "success")) return .success;
    if (std.mem.eql(u8, value, "failure")) return .failure;
    return error.InvalidSessionFormat;
}

fn parseFileEvidenceAction(value: []const u8) !session.FileEvidenceAction {
    if (std.mem.eql(u8, value, "read")) return .read;
    if (std.mem.eql(u8, value, "write")) return .write;
    if (std.mem.eql(u8, value, "edit")) return .edit;
    if (std.mem.eql(u8, value, "delete")) return .delete;
    if (std.mem.eql(u8, value, "rename")) return .rename;
    if (std.mem.eql(u8, value, "copy")) return .copy;
    if (std.mem.eql(u8, value, "search")) return .search;
    if (std.mem.eql(u8, value, "list")) return .list;
    if (std.mem.eql(u8, value, "unknown")) return .unknown;
    return error.InvalidSessionFormat;
}

fn freeParsedToolExecutionStep(alloc: Allocator, step: session.ToolExecutionStep) void {
    if (step.assistant) |assistant| alloc.free(assistant);
    session.freeToolCallSlice(alloc, step.tool_calls);
    session.freePersistedToolResults(alloc, step.tool_results);
}

fn freeParsedPersistedToolResult(alloc: Allocator, result: session.PersistedToolResult) void {
    alloc.free(result.tool_call_id);
    alloc.free(result.tool_name);
    alloc.free(result.output);
    if (result.output_handle) |handle| alloc.free(handle);
    if (result.preview) |preview| alloc.free(preview);
    types.freePermissionFeedback(alloc, result.permission_feedback);
    if (result.committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    }
}

fn freeParsedFileEvidence(alloc: Allocator, file: session.FileEvidence) void {
    alloc.free(file.path);
    if (file.new_path) |new_path| alloc.free(new_path);
    alloc.free(file.tool_call_id);
    alloc.free(file.tool_name);
}

fn parseUserTurn(alloc: Allocator, value: std.json.Value) !session.UserTurn {
    const object = try requireObject(value);
    const text = try alloc.dupe(u8, try requireString(object, "text"));
    errdefer alloc.free(text);
    const images = try validateImagesArray(alloc, object.get("images"));
    errdefer session.freeImageAttachmentSlice(alloc, images);
    return .{ .text = text, .images = images };
}

fn parseConversationLanguage(raw: []const u8) !session.ConversationLanguage {
    return session.ConversationLanguage.fromSlice(raw) catch error.InvalidSessionFormat;
}

/// Parses only the workspace_root field; caller owns a returned string and frees with allocator.free.
pub fn parseWorkspaceRoot(alloc: Allocator, json_text: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidSessionFormat;
    defer parsed.deinit();
    const root = try requireObject(parsed.value);
    return try optionalStringDup(alloc, root.get("workspace_root"));
}

fn validateImagesArray(alloc: Allocator, maybe_value: ?std.json.Value) ![]session.ImageAttachment {
    const value = maybe_value orelse return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const images = try alloc.alloc(session.ImageAttachment, value.array.items.len);
    errdefer alloc.free(images);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) {
            types.freeImageAttachment(alloc, images[i]);
        }
    }

    for (value.array.items, 0..) |entry, i| {
        const object = try requireObject(entry);
        const snapshot_path = try optionalStringDup(alloc, object.get("snapshot_path"));
        var owns_snapshot_path = true;
        errdefer if (owns_snapshot_path) {
            if (snapshot_path) |path| alloc.free(path);
        };
        const snapshot_sha256 = try optionalStringDup(alloc, object.get("snapshot_sha256"));
        var owns_snapshot_sha256 = true;
        errdefer if (owns_snapshot_sha256) {
            if (snapshot_sha256) |sha256| alloc.free(sha256);
        };
        if ((snapshot_path == null) != (snapshot_sha256 == null)) return error.InvalidSessionFormat;
        images[i] = try dupeParsedImageAttachment(
            alloc,
            if (object.get("id") != null) try requireUsize(object, "id") else 0,
            try requireString(object, "path"),
            try requireString(object, "media_type"),
            snapshot_path,
            snapshot_sha256,
        );
        owns_snapshot_path = false;
        owns_snapshot_sha256 = false;
        parsed_count += 1;
    }
    return images;
}

fn dupeParsedImageAttachment(
    alloc: Allocator,
    id: usize,
    path_src: []const u8,
    media_type_src: []const u8,
    snapshot_path_src: ?[]u8,
    snapshot_sha256_src: ?[]u8,
) !session.ImageAttachment {
    const path = try alloc.dupe(u8, path_src);
    errdefer alloc.free(path);
    const media_type = try alloc.dupe(u8, media_type_src);
    errdefer alloc.free(media_type);
    return .{
        .id = id,
        .path = path,
        .media_type = media_type,
        .snapshot_path = snapshot_path_src,
        .snapshot_sha256 = snapshot_sha256_src,
    };
}

fn requireSchemaVersion(object: std.json.ObjectMap) !void {
    try requireLegacySchema(try requireI64(object, "schema_version"));
}

fn requireLegacySchema(version: i64) !void {
    _ = try legacySchemaVersion(version);
}

fn legacySchemaVersion(version: i64) !LegacySchemaVersion {
    return switch (version) {
        legacy_schema_v1 => .v1,
        legacy_schema_v2 => .v2,
        else => error.UnsupportedSessionSchema,
    };
}

fn summaryComplete(
    schema_version: ?i64,
    id: ?[]u8,
    created_at_ms: ?i64,
    updated_at_ms: ?i64,
    conversation_language: ?session.ConversationLanguage,
    history_len: ?usize,
) bool {
    return schema_version != null and id != null and created_at_ms != null and
        updated_at_ms != null and conversation_language != null and history_len != null;
}

fn readStringOwned(
    reader: *std.json.Reader,
    alloc: Allocator,
    max_len: usize,
) ![]u8 {
    const token = try reader.nextAllocMax(alloc, .alloc_always, max_len);
    return switch (token) {
        .allocated_string => |value| value,
        .string => |value| try alloc.dupe(u8, value),
        else => {
            freeToken(alloc, token);
            return error.InvalidSessionFormat;
        },
    };
}

fn readOptionalStringOwned(
    reader: *std.json.Reader,
    alloc: Allocator,
    max_len: usize,
) !?[]u8 {
    const token = try reader.nextAllocMax(alloc, .alloc_always, max_len);
    return switch (token) {
        .null => null,
        .allocated_string => |value| value,
        .string => |value| try alloc.dupe(u8, value),
        else => {
            freeToken(alloc, token);
            return error.InvalidSessionFormat;
        },
    };
}

fn readI64Token(reader: *std.json.Reader, alloc: Allocator) !i64 {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeToken(alloc, token);
    const raw = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return error.InvalidSessionFormat,
    };
    return std.fmt.parseInt(i64, raw, 10) catch error.InvalidSessionFormat;
}

fn readU64Token(reader: *std.json.Reader, alloc: Allocator) !u64 {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeToken(alloc, token);
    const raw = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return error.InvalidSessionFormat,
    };
    return std.fmt.parseUnsigned(u64, raw, 10) catch error.InvalidSessionFormat;
}

fn expectToken(actual: std.json.Token, comptime expected: std.meta.Tag(std.json.Token)) !void {
    if (std.meta.activeTag(actual) != expected) return error.InvalidSessionFormat;
}

fn freeToken(alloc: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number => |value| alloc.free(value),
        .allocated_string => |value| alloc.free(value),
        else => {},
    }
}

fn parseOptionalBackgroundRecordId(
    maybe_value: ?std.json.Value,
) !?[16]u8 {
    const value = maybe_value orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len != 32) return error.InvalidSessionFormat;
    var id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, value.string) catch return error.InvalidSessionFormat;
    const canonical = std.fmt.bytesToHex(id, .lower);
    if (!std.mem.eql(u8, &canonical, value.string)) return error.InvalidSessionFormat;
    return id;
}

fn writeHexString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
    try writer.writeByte('"');
}

noinline fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidSessionFormat;
    return value.object;
}

noinline fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .string) return error.InvalidSessionFormat;
    return value.string;
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .bool) return error.InvalidSessionFormat;
    return value.bool;
}

noinline fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .integer) return error.InvalidSessionFormat;
    if (value.integer < std.math.minInt(i64) or value.integer > std.math.maxInt(i64)) {
        return error.InvalidSessionFormat;
    }
    return @intCast(value.integer);
}

noinline fn requireUsize(object: std.json.ObjectMap, key: []const u8) !usize {
    const value = try requireI64(object, key);
    if (value < 0) return error.InvalidSessionFormat;
    return @intCast(value);
}

noinline fn optionalStringDup(alloc: Allocator, maybe_value: ?std.json.Value) !?[]u8 {
    const value = maybe_value orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try alloc.dupe(u8, text),
        else => error.InvalidSessionFormat,
    };
}

fn parseOptionalStringArray(alloc: Allocator, maybe_value: ?std.json.Value) ![][]u8 {
    const value = maybe_value orelse return &.{};
    if (value == .null) return &.{};
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};

    const items = try alloc.alloc([]u8, value.array.items.len);
    errdefer alloc.free(items);

    var parsed_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed_count) : (i += 1) alloc.free(items[i]);
    }

    for (value.array.items, 0..) |entry, i| {
        if (entry != .string) return error.InvalidSessionFormat;
        items[i] = try alloc.dupe(u8, entry.string);
        parsed_count += 1;
    }
    return items;
}

test "validateImagesArray frees path when media_type allocation fails" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"images\":[{\"path\":\"/tmp/a.png\",\"media_type\":\"image/png\"}]}", .{});
    defer parsed.deinit();
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, validateImagesArray(failing.allocator(), parsed.value.object.get("images")));
}

test "parseSessionSummary rejects integer above i64 range" {
    const session_store = @import("session_store.zig");
    const alloc = std.testing.allocator;
    const json_text =
        "{\"schema_version\":1,\"id\":\"overflow\",\"created_at_ms\":9223372036854775808,\"updated_at_ms\":1," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}";

    try std.testing.expectError(error.InvalidSessionFormat, parseSessionSummary(session_store.SessionSummary, alloc, json_text));
}

test "parseSessionSummary rejects integer below i64 range" {
    const session_store = @import("session_store.zig");
    const alloc = std.testing.allocator;
    const json_text =
        "{\"schema_version\":1,\"id\":\"underflow\",\"created_at_ms\":1,\"updated_at_ms\":-9223372036854775809," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}";

    try std.testing.expectError(error.InvalidSessionFormat, parseSessionSummary(session_store.SessionSummary, alloc, json_text));
}

test "parseWorkspaceRoot probes workspace without requiring supported schema" {
    const alloc = std.testing.allocator;
    const workspace = try parseWorkspaceRoot(alloc, "{\"schema_version\":99,\"workspace_root\":\"/tmp/workspace\"}") orelse return error.TestExpectedEqual;
    defer alloc.free(workspace);

    try std.testing.expectEqualStrings("/tmp/workspace", workspace);
    try std.testing.expect(try parseWorkspaceRoot(alloc, "{\"schema_version\":99}") == null);
    try std.testing.expect(try parseWorkspaceRoot(alloc, "{\"schema_version\":99,\"workspace_root\":null}") == null);
}

test "parseWorkspaceRoot rejects non-object and non-string workspace root" {
    try std.testing.expectError(error.InvalidSessionFormat, parseWorkspaceRoot(std.testing.allocator, "[]"));
    try std.testing.expectError(error.InvalidSessionFormat, parseWorkspaceRoot(std.testing.allocator, "{\"workspace_root\":123}"));
}

test "legacy session migration keeps missing compacted authority incomplete" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"kind\":\"compacted_summary\",\"summary\":\"legacy\",\"removed_turn_count\":2,\"compaction_count\":1}",
        .{},
    );
    defer parsed.deinit();
    const migrated = try parseLegacyHistoryTurn(alloc, parsed.value);
    defer session.freeHistoryTurn(alloc, migrated);
    try std.testing.expect(!migrated.compacted_summary.root_user_messages_complete);
    try std.testing.expect(!migrated.compacted_summary.permission_feedback_complete);

    const history = [_]session.HistoryTurn{migrated};
    const json = try renderSessionJson(
        alloc,
        "legacy-incomplete",
        1,
        2,
        session.ConversationLanguage.literal("und-Latn"),
        "/tmp/workspace",
        &history,
        .{},
    );
    defer alloc.free(json);
    var reloaded = try parseStoredSession(TestStoredSession, alloc, json);
    defer reloaded.deinit(alloc);
    try std.testing.expect(!reloaded.history[0].compacted_summary.root_user_messages_complete);
    try std.testing.expect(!reloaded.history[0].compacted_summary.permission_feedback_complete);
}

test "session JSON round-trips assistant execution memory" {
    const alloc = std.testing.allocator;

    var feedback = [_][]u8{@constCast("read it after writing")};
    var calls = [_]session.ToolCall{.{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("<path>src/main.zig</path>\nconst std = @import(\"std\");"),
        .output_bytes = 54,
        .stored_output_bytes = 54,
        .truncated = false,
        .provider_native = false,
        .created_at_ms = 1234,
        .permission_feedback = feedback[0..],
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .assistant = @constCast("I'll inspect it."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var steering = [_]types.PersistedSteering{.{
        .text = @constCast("focus on rendering"),
        .assistant_prefix = @constCast("partial assistant"),
        .after_tool_step_count = 1,
    }};
    var files = [_]session.FileEvidence{.{
        .path = @constCast("src/main.zig"),
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .success,
        .model_view_covers_full_file = true,
        .stale = false,
    }};
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("what is main") },
        .assistant = @constCast("main wires the app"),
        .execution = .{ .tool_steps = steps[0..], .files = files[0..], .steering = steering[0..] },
    } }};

    const json = try renderSessionJson(alloc, "exec-json", 1, 2, session.ConversationLanguage.literal("en"), "/tmp/workspace", &history, .{});
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"execution\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"tool_steps\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"files\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"execution\":{\"schema_version\":3") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"permission_feedback\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"text\":\"focus on rendering\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"assistant_prefix\":\"partial assistant\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"after_tool_step_count\":1") != null);

    var loaded = try parseStoredSession(TestStoredSession, alloc, json);
    defer loaded.deinit(alloc);
    const execution = loaded.history[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    try std.testing.expectEqualStrings("I'll inspect it.", execution.tool_steps[0].assistant.?);
    try std.testing.expectEqualStrings("call_read", execution.tool_steps[0].tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", execution.tool_steps[0].tool_results[0].tool_name);
    try std.testing.expectEqual(@as(usize, 54), execution.tool_steps[0].tool_results[0].stored_output_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        execution.tool_steps[0].tool_results[0].permission_feedback.len,
    );
    try std.testing.expectEqualStrings(
        "read it after writing",
        execution.tool_steps[0].tool_results[0].permission_feedback[0],
    );
    try std.testing.expectEqual(@as(usize, 1), execution.files.len);
    try std.testing.expectEqual(.read, execution.files[0].action);
    try std.testing.expect(execution.files[0].model_view_covers_full_file);
    try std.testing.expectEqual(@as(usize, 1), execution.steering.len);
    try std.testing.expectEqualStrings("focus on rendering", execution.steering[0].text);
    try std.testing.expectEqualStrings("partial assistant", execution.steering[0].assistant_prefix.?);
    try std.testing.expectEqual(@as(usize, 1), execution.steering[0].after_tool_step_count);
}

fn checkV3SteeringAllocationFailures(alloc: Allocator) !void {
    const json =
        "[{\"text\":\"first\",\"assistant_prefix\":\"prefix one\",\"after_tool_step_count\":0}," ++
        "{\"text\":\"second\",\"assistant_prefix\":\"prefix two\",\"after_tool_step_count\":1}]";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const steering = try parseOptionalSteering(alloc, parsed.value, 3, 1);
    defer types.freePersistedSteering(alloc, steering);
    try std.testing.expectEqual(@as(usize, 2), steering.len);
}

test "session JSON steering cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkV3SteeringAllocationFailures,
        .{},
    );
}

const legacy_execution_memory_fixture =
    "{\"schema_version\":1,\"id\":\"execution-ownership\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
    "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
    "{\"kind\":\"assistant\",\"user\":{\"text\":\"inspect\",\"images\":[]},\"assistant\":\"done\"," ++
    "\"execution\":{\"schema_version\":2,\"tool_steps\":[" ++
    "{\"assistant\":\"checking\",\"tool_calls\":[{\"id\":\"call_write\",\"name\":\"write_file\",\"arguments_json\":\"{}\",\"provider_result\":null}],\"tool_results\":[{\"tool_call_id\":\"call_write\",\"tool_name\":\"write_file\",\"status\":\"success\",\"output\":\"wrote\",\"output_handle\":null,\"preview\":null,\"output_bytes\":5,\"stored_output_bytes\":5,\"truncated\":false,\"provider_native\":false,\"created_at_ms\":1,\"permission_feedback\":[\"read it\"]}]}],\"files\":[" ++
    "{\"path\":\"src/main.zig\",\"new_path\":null,\"tool_call_id\":\"call_read\",\"tool_name\":\"read_file\"," ++
    "\"action\":\"read\",\"status\":\"success\",\"model_view_covers_full_file\":true,\"stale\":false}]," ++
    "\"steering\":[\"legacy steer\"]}}]}";

fn checkLegacyExecutionMemoryAllocationFailures(alloc: Allocator) !void {
    var loaded = try parseStoredSession(
        TestStoredSession,
        alloc,
        legacy_execution_memory_fixture,
    );
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 1),
        loaded.history[0].assistant.execution.tool_steps.len,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        loaded.history[0].assistant.execution.files.len,
    );
    try std.testing.expectEqualStrings(
        "legacy steer",
        loaded.history[0].assistant.execution.steering[0].text,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        loaded.history[0].assistant.execution.steering[0].after_tool_step_count,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        loaded.history[0].assistant.execution.tool_steps[0].tool_results[0].permission_feedback.len,
    );
}

test "legacy execution memory frees parsed tool steps when files are malformed" {
    const json =
        "{\"schema_version\":1,\"id\":\"execution-malformed\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"inspect\",\"images\":[]},\"assistant\":\"done\"," ++
        "\"execution\":{\"schema_version\":1,\"tool_steps\":[" ++
        "{\"assistant\":\"checking\",\"tool_calls\":[],\"tool_results\":[]}],\"files\":{}}}]}";

    try std.testing.expectError(
        error.InvalidSessionFormat,
        parseStoredSession(TestStoredSession, std.testing.allocator, json),
    );
}

test "legacy execution memory cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLegacyExecutionMemoryAllocationFailures,
        .{},
    );
}

test "session JSON persists malformed argument recovery as a safe failed pair" {
    const alloc = std.testing.allocator;
    const failure_output =
        "{\"error\":{\"type\":\"tool_execution_failed\",\"tool_name\":\"read_file\"," ++
        "\"message\":\"Tool arguments were not valid JSON.\",\"suggestion\":" ++
        "\"Reissue the tool call with complete valid JSON arguments matching the tool schema.\"}}";

    var calls = [_]session.ToolCall{.{
        .id = "call_bad",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_bad"),
        .tool_name = @constCast("read_file"),
        .status = .failure,
        .output = @constCast(failure_output),
        .output_bytes = failure_output.len,
        .stored_output_bytes = failure_output.len,
        .truncated = false,
        .provider_native = false,
        .created_at_ms = 1234,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .assistant = @constCast("I'll inspect it."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("inspect it") },
        .assistant = @constCast("Recovered."),
        .execution = .{ .tool_steps = steps[0..] },
    } }};

    const json = try renderSessionJson(
        alloc,
        "malformed-recovery",
        1,
        2,
        session.ConversationLanguage.literal("en"),
        "/tmp/workspace",
        &history,
        .{},
    );
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"arguments_json\":\"{}\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "malformed_json") == null);

    var loaded = try parseStoredSession(TestStoredSession, alloc, json);
    defer loaded.deinit(alloc);
    const execution = loaded.history[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    try std.testing.expectEqualStrings("{}", execution.tool_steps[0].tool_calls[0].arguments_json);
    try std.testing.expectEqual(.valid, execution.tool_steps[0].tool_calls[0].argument_integrity);
    try std.testing.expectEqual(session.PersistedToolStatus.failure, execution.tool_steps[0].tool_results[0].status);
    try std.testing.expectEqualStrings(failure_output, execution.tool_steps[0].tool_results[0].output);
}

test "non-object legacy function inputs are repaired without changing recorded outcomes" {
    const alloc = std.testing.allocator;
    for ([_]session.PersistedToolStatus{ .success, .failure }) |status| {
        for (0..3) |native_kind| {
            var calls = [_]session.ToolCall{.{ .id = "call", .name = "read_file", .arguments_json = "[]" }};
            calls[0].provider_result = if (native_kind == 1) "provider result" else null;
            var results = [_]session.PersistedToolResult{.{
                .tool_call_id = @constCast("call"),
                .tool_name = @constCast("read_file"),
                .status = status,
                .output = @constCast("recorded"),
                .output_bytes = 8,
                .stored_output_bytes = 8,
                .truncated = false,
                .provider_native = native_kind == 2,
                .created_at_ms = 1,
            }};
            var steps = [_]session.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
            var encoded: std.Io.Writer.Allocating = .init(alloc);
            defer encoded.deinit();
            try writeExecutionMemoryJson(&encoded.writer, .{ .tool_steps = &steps });
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
            defer parsed.deinit();
            const decoded = try parseOptionalExecutionMemory(alloc, parsed.value);
            defer session.freeExecutionMemory(alloc, decoded);
            const step = decoded.tool_steps[0];
            try std.testing.expectEqualStrings(if (native_kind == 0) "{}" else "[]", step.tool_calls[0].arguments_json);
            try std.testing.expectEqual(if (native_kind == 0) types.ToolExecutionProvenance.fx_local else .provider_executed, step.tool_calls[0].provenance);
            try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, step.tool_calls[0].argument_integrity);
            try std.testing.expectEqual(status, step.tool_results[0].status);
            try std.testing.expectEqualStrings("recorded", step.tool_results[0].output);
            try std.testing.expectEqual(@as(usize, 8), step.tool_results[0].stored_output_bytes);
        }
    }
}

fn checkNonObjectLegacyInterruptedAllocationFailures(alloc: Allocator, value: std.json.Value) !void {
    const call = (try parseOptionalToolCall(alloc, value)).?;
    defer session.freeToolCall(alloc, call);
    try std.testing.expectEqualStrings("{}", call.arguments_json);
}

test "non-object legacy interrupted repair cleans every allocation failure" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"id":"pending","name":"read_file","arguments_json":"[]","provider_result":null}
    , .{});
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(alloc, checkNonObjectLegacyInterruptedAllocationFailures, .{parsed.value});
}

test "old assistant session JSON without execution parses as empty memory" {
    const alloc = std.testing.allocator;
    const json =
        "{\"schema_version\":1,\"id\":\"old\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"hello\",\"images\":[]},\"assistant\":\"world\"}" ++
        "]}";

    var loaded = try parseStoredSession(TestStoredSession, alloc, json);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), loaded.history.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.history[0].assistant.execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.history[0].assistant.execution.files.len);
}

test "legacy session JSON repairs duplicate-key tool arguments before projection" {
    const io_mod = @import("../shared/io.zig");
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "legacy-repair-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "session");

    const json =
        "{\"schema_version\":1,\"id\":\"legacy-malformed\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"inspect\",\"images\":[]},\"assistant\":\"failed\"," ++
        "\"execution\":{\"schema_version\":1,\"tool_steps\":[{\"assistant\":null,\"tool_calls\":[" ++
        "{\"id\":\"call_bad\",\"name\":\"read_file\",\"arguments_json\":\"{\\\"depth\\\":1,\\\"depth\\\":2}\",\"provider_result\":null}" ++
        "],\"tool_results\":[{\"tool_call_id\":\"call_bad\",\"tool_name\":\"read_file\",\"status\":\"success\"," ++
        "\"output\":\"stale success\",\"output_handle\":null,\"preview\":null,\"output_bytes\":13,\"stored_output_bytes\":13," ++
        "\"truncated\":false,\"provider_native\":false,\"created_at_ms\":1}]}],\"files\":[]}}]}";

    var loaded = try parseStoredSession(TestStoredSession, alloc, json);
    defer loaded.deinit(alloc);
    const step = loaded.history[0].assistant.execution.tool_steps[0];
    try std.testing.expectEqualStrings("{}", step.tool_calls[0].arguments_json);
    try std.testing.expectEqual(.valid, step.tool_calls[0].argument_integrity);
    try std.testing.expectEqual(session.PersistedToolStatus.failure, step.tool_results[0].status);
    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(step.tool_results[0].output));

    const rendered = try renderSessionJson(
        alloc,
        loaded.id,
        loaded.created_at_ms,
        loaded.updated_at_ms,
        loaded.conversation_language,
        loaded.workspace_root.?,
        loaded.history,
        .{},
    );
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "\"depth\":1") == null);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    defer messages.deinit(arena);
    try session.appendHistoryChatMessages(arena, &messages, loaded.history);
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqualStrings("{}", messages.items[1].tool_calls[0].arguments_json);
    try std.testing.expect(std.mem.find(u8, messages.items[1].tool_calls[0].arguments_json, "\"depth\":1") == null);
    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(messages.items[2].content.?));
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?, "\"depth\":1") == null);

    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event=persisted_tool_arguments_repaired") != null);
    try std.testing.expect(std.mem.find(u8, trace, "source=legacy") != null);
    try std.testing.expect(std.mem.find(u8, trace, "call_id=call_bad") != null);
    try std.testing.expect(std.mem.find(u8, trace, "\"depth\":1") == null);
}

test "legacy interrupted session sanitizes duplicate-key tool arguments" {
    const json =
        "{\"schema_version\":1,\"id\":\"legacy-interrupted\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
        "{\"kind\":\"interrupted\",\"user\":{\"text\":\"inspect\",\"images\":[]},\"assistant\":\"working\"," ++
        "\"tool_call\":{\"id\":\"call_bad\",\"name\":\"glob_files\",\"arguments_json\":\"{\\\"depth\\\":1,\\\"depth\\\":2}\",\"provider_result\":null}," ++
        "\"completed_tool_names\":[]}]}";

    var loaded = try parseStoredSession(TestStoredSession, std.testing.allocator, json);
    defer loaded.deinit(std.testing.allocator);
    const call = loaded.history[0].interrupted.tool_call.?;
    try std.testing.expectEqualStrings("{}", call.arguments_json);
    try std.testing.expectEqual(.valid, call.argument_integrity);
}

test "legacy session JSON rejects ambiguous malformed tool result pairings" {
    const read_result =
        "{\"tool_call_id\":\"call_bad\",\"tool_name\":\"read_file\",\"status\":\"success\"," ++
        "\"output\":\"stale\",\"output_handle\":null,\"preview\":null,\"output_bytes\":5,\"stored_output_bytes\":5," ++
        "\"truncated\":false,\"provider_native\":false,\"created_at_ms\":1}";
    const list_result =
        "{\"tool_call_id\":\"call_bad\",\"tool_name\":\"glob_files\",\"status\":\"success\"," ++
        "\"output\":\"stale\",\"output_handle\":null,\"preview\":null,\"output_bytes\":5,\"stored_output_bytes\":5," ++
        "\"truncated\":false,\"provider_native\":false,\"created_at_ms\":1}";
    const cases = [_]struct {
        calls: []const u8,
        results: []const u8,
    }{
        .{
            .calls = "{\"id\":\"call_bad\",\"name\":\"read_file\",\"arguments_json\":\"{]\",\"provider_result\":null}," ++
                "{\"id\":\"call_bad\",\"name\":\"read_file\",\"arguments_json\":\"{]\",\"provider_result\":null}",
            .results = read_result,
        },
        .{
            .calls = "{\"id\":\"call_bad\",\"name\":\"read_file\",\"arguments_json\":\"{]\",\"provider_result\":null}",
            .results = "",
        },
        .{
            .calls = "{\"id\":\"call_bad\",\"name\":\"read_file\",\"arguments_json\":\"{]\",\"provider_result\":null}",
            .results = read_result ++ "," ++ read_result,
        },
        .{
            .calls = "{\"id\":\"call_bad\",\"name\":\"read_file\",\"arguments_json\":\"{]\",\"provider_result\":null}",
            .results = list_result,
        },
    };

    for (cases) |case| {
        const json = try legacySessionWithToolStep(std.testing.allocator, case.calls, case.results);
        defer std.testing.allocator.free(json);
        try std.testing.expectError(
            error.InvalidSessionFormat,
            parseStoredSession(TestStoredSession, std.testing.allocator, json),
        );
    }
}

test "legacy duplicate-key repair preserves allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLegacyToolArgumentRepairAllocationFailures,
        .{},
    );
}

fn legacySessionWithToolStep(
    alloc: Allocator,
    calls: []const u8,
    results: []const u8,
) ![]u8 {
    return std.mem.concat(alloc, u8, &.{
        "{\"schema_version\":1,\"id\":\"legacy-malformed\",\"created_at_ms\":1,\"updated_at_ms\":2,",
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"inspect\",\"images\":[]},\"assistant\":\"failed\",",
        "\"execution\":{\"schema_version\":1,\"tool_steps\":[{\"assistant\":null,\"tool_calls\":[",
        calls,
        "],\"tool_results\":[",
        results,
        "]}],\"files\":[]}}]}",
    });
}

fn checkLegacyToolArgumentRepairAllocationFailures(alloc: Allocator) !void {
    const json =
        "{\"schema_version\":1,\"id\":\"legacy-oom\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"inspect\",\"images\":[]},\"assistant\":\"failed\"," ++
        "\"execution\":{\"schema_version\":1,\"tool_steps\":[{\"assistant\":null,\"tool_calls\":[" ++
        "{\"id\":\"call_bad\",\"name\":\"read_file\",\"arguments_json\":\"{\\\"depth\\\":1,\\\"depth\\\":2}\",\"provider_result\":null}" ++
        "],\"tool_results\":[{\"tool_call_id\":\"call_bad\",\"tool_name\":\"read_file\",\"status\":\"success\"," ++
        "\"output\":\"stale\",\"output_handle\":null,\"preview\":null,\"output_bytes\":5,\"stored_output_bytes\":5," ++
        "\"truncated\":false,\"provider_native\":false,\"created_at_ms\":1}]}],\"files\":[]}}]}";

    var loaded = try parseStoredSession(TestStoredSession, alloc, json);
    defer loaded.deinit(alloc);
    const step = loaded.history[0].assistant.execution.tool_steps[0];
    try std.testing.expectEqualStrings("{}", step.tool_calls[0].arguments_json);
    try std.testing.expectEqual(session.PersistedToolStatus.failure, step.tool_results[0].status);
}

test "session JSON round-trips large result handle metadata and accepts old inline results" {
    const alloc = std.testing.allocator;

    var calls = [_]session.ToolCall{.{
        .id = "call_large",
        .name = "read_file",
        .arguments_json = "{\"path\":\"large.txt\"}",
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_large"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("<tool_result_preview handle=\"result-call_large-abc.txt\">\nevidence\n</tool_result_preview>"),
        .output_bytes = 90_000,
        .stored_output_bytes = 90_000,
        .truncated = true,
        .provider_native = false,
        .created_at_ms = 1234,
        .output_handle = @constCast("result-call_large-abc.txt"),
        .preview = @constCast("evidence"),
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var files = [_]session.FileEvidence{.{
        .path = @constCast("large.txt"),
        .tool_call_id = @constCast("call_large"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .success,
        .model_view_covers_full_file = false,
    }};
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("read large file") },
        .assistant = @constCast("captured"),
        .execution = .{
            .tool_steps = steps[0..],
            .files = files[0..],
        },
    } }};

    const json = try renderSessionJson(alloc, "large-json", 1, 2, session.ConversationLanguage.literal("en"), "/tmp/workspace", &history, .{});
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"output_handle\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"preview\"") != null);

    var loaded = try parseStoredSession(TestStoredSession, alloc, json);
    defer loaded.deinit(alloc);
    const result = loaded.history[0].assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("result-call_large-abc.txt", result.output_handle.?);
    try std.testing.expectEqualStrings("evidence", result.preview.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.history[0].assistant.execution.files.len);
    try std.testing.expect(!loaded.history[0].assistant.execution.files[0].model_view_covers_full_file);

    const old_json =
        "{\"schema_version\":1,\"id\":\"old-inline\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"u\",\"images\":[]},\"assistant\":\"a\",\"execution\":{\"schema_version\":1,\"tool_steps\":[" ++
        "{\"assistant\":null,\"tool_calls\":[{\"id\":\"c\",\"name\":\"read_file\",\"arguments_json\":\"{}\",\"provider_result\":null}],\"tool_results\":[" ++
        "{\"tool_call_id\":\"c\",\"tool_name\":\"read_file\",\"status\":\"success\",\"output\":\"inline\",\"output_bytes\":6,\"stored_output_bytes\":6,\"truncated\":false,\"provider_native\":false,\"created_at_ms\":1}" ++
        "]}],\"files\":[]}}" ++
        "]}";
    var old_loaded = try parseStoredSession(TestStoredSession, alloc, old_json);
    defer old_loaded.deinit(alloc);
    const old_result = old_loaded.history[0].assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expect(old_result.output_handle == null);
    try std.testing.expect(old_result.preview == null);
}

test "interactive session round trips total web search requests and loads absent value as zero" {
    const alloc = std.testing.allocator;

    const json = try renderSessionJson(alloc, "search-usage", 1, 2, session.ConversationLanguage.literal("en"), "/tmp/workspace", &.{}, .{
        .web_search_requests = 7,
    });
    defer alloc.free(json);
    var loaded = try parseStoredSession(TestStoredSession, alloc, json);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 7), loaded.total_web_search_requests);

    var old_loaded = try parseStoredSession(
        TestStoredSession,
        alloc,
        "{\"schema_version\":1,\"id\":\"old\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}",
    );
    defer old_loaded.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 0), old_loaded.total_web_search_requests);
}

test "legacy summary streaming stops before writer-produced history payload" {
    const session_store = @import("session_store.zig");
    const alloc = std.testing.allocator;
    const large_text = try alloc.alloc(u8, 128 * 1024);
    defer alloc.free(large_text);
    @memset(large_text, 'h');
    const history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("prompt") },
        .assistant = large_text,
    } }};
    const json = try renderSessionJson(
        alloc,
        "stream-summary",
        10,
        20,
        session.ConversationLanguage.literal("en"),
        "/tmp/workspace",
        &history,
        .{},
    );
    defer alloc.free(json);
    const history_start = std.mem.indexOf(u8, json, "\"history\":[") orelse
        return error.TestExpectedEqual;

    const summary_prefix_end = history_start + "\"history\":".len;
    var source = std.Io.Reader.fixed(json[0..summary_prefix_end]);
    var summary = try parseLegacySummaryStreaming(
        session_store.SessionSummary,
        alloc,
        &source,
    );
    defer summary.deinit(alloc);
    try std.testing.expectEqualStrings("stream-summary", summary.id);
    try std.testing.expectEqual(@as(usize, 1), summary.history_len);
}

test "legacy summary streaming structurally skips externally reordered history" {
    const session_store = @import("session_store.zig");
    const alloc = std.testing.allocator;
    const json =
        "{\"schema_version\":2,\"history\":[{\"kind\":\"compacted_summary\",\"summary\":\"x\"," ++
        "\"removed_turn_count\":1,\"compaction_count\":1}],\"id\":\"reordered\"," ++
        "\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":null," ++
        "\"conversation_language\":\"en\",\"history_len\":1}";
    var source = std.Io.Reader.fixed(json);
    var summary = try parseLegacySummaryStreaming(
        session_store.SessionSummary,
        alloc,
        &source,
    );
    defer summary.deinit(alloc);
    try std.testing.expectEqualStrings("reordered", summary.id);
    try std.testing.expect(summary.workspace_root == null);
    try std.testing.expectEqual(@as(usize, 1), summary.history_len);
}

test "schema v2 legacy exact reader migrates background ownership to inert history" {
    const alloc = std.testing.allocator;
    const json =
        "{\"schema_version\":2,\"id\":\"legacy-v2\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":2,\"history\":[" ++
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"u\",\"images\":[{\"id\":7,\"path\":\"/tmp/a.png\",\"media_type\":\"image/png\"}]}," ++
        "\"assistant\":\"a\",\"execution\":{\"schema_version\":1,\"tool_steps\":[],\"files\":[]}}," ++
        "{\"kind\":\"background_command\",\"user\":{\"text\":\"run\",\"images\":[]},\"log_path\":\"/tmp/log\"," ++
        "\"expect_url\":false,\"url\":null,\"background_record_id\":\"00112233445566778899aabbccddeeff\"}" ++
        "]}";
    var loaded = try parseLegacyExact(TestStoredSession, alloc, json);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 7), loaded.history[0].assistant.user.images[0].id);
    try std.testing.expect(loaded.history[1] == .assistant);
    try std.testing.expect(std.mem.find(
        u8,
        loaded.history[1].assistant.assistant,
        "fx no longer owns or controls this process",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        loaded.history[1].assistant.assistant,
        "former log=/tmp/log",
    ) != null);
}

test "legacy exact reader rejects durable byte objects in string fields" {
    const alloc = std.testing.allocator;
    const snapshots = [_][]const u8{
        "{\"schema_version\":1,\"id\":\"legacy-v1\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
            "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
            "{\"kind\":\"compacted_summary\",\"summary\":{\"encoding\":\"base64\",\"data\":\"/w==\"}," ++
            "\"removed_turn_count\":1,\"compaction_count\":1}]}",
        "{\"schema_version\":2,\"id\":\"legacy-v2\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
            "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":1,\"history\":[" ++
            "{\"kind\":\"compacted_summary\",\"summary\":{\"encoding\":\"base64\",\"data\":\"/w==\"}," ++
            "\"removed_turn_count\":1,\"compaction_count\":1}]}",
    };

    for (snapshots) |snapshot| {
        try std.testing.expectError(
            error.InvalidSessionFormat,
            parseLegacyExact(TestStoredSession, alloc, snapshot),
        );
    }
}

test "legacy exact and summary readers preserve resource exhaustion" {
    const session_store = @import("session_store.zig");
    const json =
        "{\"schema_version\":1,\"id\":\"oom\",\"created_at_ms\":1,\"updated_at_ms\":2," ++
        "\"workspace_root\":\"/tmp/workspace\",\"conversation_language\":\"en\",\"history_len\":0,\"history\":[]}";

    var exact_failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        parseLegacyExact(TestStoredSession, exact_failing.allocator(), json),
    );

    var source = std.Io.Reader.fixed(json);
    var summary_failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        parseLegacySummaryStreaming(
            session_store.SessionSummary,
            summary_failing.allocator(),
            &source,
        ),
    );
}

test {
    _ = @import("session_codec.zig");
    _ = @import("session_event.zig");
    _ = @import("session_projection.zig");
}
