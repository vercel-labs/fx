//! Stateless Responses input keeps native history authoritative across tool continuations.
const std = @import("std");
const wire = @import("wire.zig");
const image_parts = @import("image_parts.zig");
const replay = @import("replay.zig");
const contributor_model = "muse-spark-1.3-contributor";
const encrypted_include = "reasoning.encrypted_content";
const function_groups = [_][]const u8{ "functions", "additional_functions", "dynamic_functions" };
const message_roles = [_][]const u8{ "system", "developer", "user", "assistant" };
const assistant_role = "assistant";
const tool_role = "tool";
const function_type = "function";
const call_type = "function_call";
const call_output_type = "function_call_output";
const schema_type = "json_schema";
const commentary_phase = "commentary";

/// Contributor's documented continuation grammar must not add unverified fields to Grok requests.
pub fn apply_model_grammar(alloc: wire.Allocator, model: []const u8, body: *wire.Value) !void {
    if (!std.mem.eql(u8, model, contributor_model)) return;
    const input = try wire.field(body.*, "input");
    for (input.array.items, 0..) |*item, index| {
        const role = item.object.get("role") orelse continue;
        if (!std.mem.eql(u8, try wire.text(role), assistant_role) or index + 1 >= input.array.items.len) continue;
        const next = input.array.items[index + 1];
        const kind = next.object.get("type") orelse continue;
        // Contributor rejects pre-tool assistant text unless it is marked as commentary.
        if (std.mem.eql(u8, try wire.text(kind), call_type)) try wire.put(alloc, item, "phase", wire.string(commentary_phase));
    }
}

/// All returned values belong to the caller's request arena, including decoded replay strings.
pub fn project(alloc: wire.Allocator, request: wire.Value) !wire.Value {
    var body = wire.object();
    try wire.put(alloc, &body, "store", .{ .bool = false });
    var include: std.json.Array = .init(alloc);
    try include.append(wire.string(encrypted_include));
    try wire.put(alloc, &body, "include", .{ .array = include });
    const messages = try wire.field(request, "messages");
    if (messages != .array) return error.InvalidRequest;
    var input: std.json.Array = .init(alloc);
    for (messages.array.items) |message| {
        const role = try wire.text(try wire.field(message, "role"));
        const content = try wire.field(message, "content");
        const images = try wire.field(message, "images");
        const calls = try wire.field(message, "tool_calls");
        if (images != .array or calls != .array) return error.InvalidRequest;
        if (std.mem.eql(u8, role, tool_role)) {
            if (images.array.items.len != 0 or calls.array.items.len != 0) return error.InvalidRequest;
            var output = wire.object();
            try wire.put(alloc, &output, "type", wire.string(call_output_type));
            try wire.put(alloc, &output, "call_id", try wire.field(message, "tool_call_id"));
            try wire.put(alloc, &output, "output", wire.string(try wire.text(content)));
            try input.append(output);
            continue;
        }
        var valid_role = false;
        for (message_roles) |allowed| if (std.mem.eql(u8, role, allowed)) {
            valid_role = true;
            break;
        };
        if (!valid_role) return error.InvalidRequest;
        const assistant = std.mem.eql(u8, role, assistant_role);
        if (!assistant and calls.array.items.len > 0) return error.InvalidRequest;
        const state = try wire.field(message, "provider_state_json");
        if (assistant and state != .null) if (try replay.items(alloc, state, .responses)) |saved| {
            for (saved.array.items) |item| {
                try replay.responses_item(item);
                try input.append(item);
            }
        };
        if (content != .null or images.array.items.len > 0) {
            var projected = wire.object();
            try wire.put(alloc, &projected, "role", wire.string(role));
            try wire.put(alloc, &projected, "content", try image_parts.responses_content(alloc, content, images));
            try input.append(projected);
        }
        for (calls.array.items) |call| {
            var projected = wire.object();
            try wire.put(alloc, &projected, "type", wire.string(call_type));
            try wire.put(alloc, &projected, "call_id", try wire.field(call, "id"));
            try wire.put(alloc, &projected, "name", try wire.field(call, "name"));
            try wire.put(alloc, &projected, "arguments", try wire.field(call, "arguments_json"));
            try input.append(projected);
        }
    }
    try wire.put(alloc, &body, "input", .{ .array = input });
    const effort = try wire.field(request, "reasoning_effort");
    if (effort != .null) {
        var reasoning = wire.object();
        try wire.put(alloc, &reasoning, "effort", effort);
        try wire.put(alloc, &body, "reasoning", reasoning);
    }
    const limit = try wire.field(request, "max_output_tokens");
    if (limit != .null) try wire.put(alloc, &body, "max_output_tokens", limit);
    var tools: std.json.Array = .init(alloc);
    for (function_groups) |group| {
        const functions = try wire.field(request, group);
        if (functions != .array) return error.InvalidRequest;
        for (functions.array.items) |function| {
            var tool = wire.object();
            try wire.put(alloc, &tool, "type", wire.string(function_type));
            try wire.put(alloc, &tool, "name", try wire.field(function, "name"));
            try wire.put(alloc, &tool, "description", try wire.field(function, "description"));
            try wire.put(alloc, &tool, "parameters", try wire.field(function, "inputSchema"));
            // Native tool schemas contain optional fields that Responses strict mode would require.
            try wire.put(alloc, &tool, "strict", .{ .bool = false });
            try tools.append(tool);
        }
    }
    if (tools.items.len > 0) {
        try wire.put(alloc, &body, "tools", .{ .array = tools });
        try wire.put(alloc, &body, "tool_choice", try wire.field(request, "tool_choice"));
        const parallel = try wire.field(request, "parallel_tool_calls");
        if (parallel != .null) {
            if (parallel != .bool) return error.InvalidRequest;
            try wire.put(alloc, &body, "parallel_tool_calls", parallel);
        }
    }
    const format = try wire.field(request, "response_format");
    if (format != .null) {
        var schema = wire.object();
        try wire.put(alloc, &schema, "type", wire.string(schema_type));
        for ([_][]const u8{ "name", "description", "schema" }) |field| try wire.put(alloc, &schema, field, try wire.field(format, field));
        try wire.put(alloc, &schema, "strict", .{ .bool = true });
        var text = wire.object();
        try wire.put(alloc, &text, "format", schema);
        try wire.put(alloc, &body, "text", text);
    }
    return body;
}
