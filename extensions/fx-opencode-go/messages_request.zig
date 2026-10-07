//! Messages history keeps native tool identities authoritative and reasoning replay family-bound.
const std = @import("std");
const wire = @import("wire.zig");
const image_parts = @import("image_parts.zig");
const replay = @import("replay.zig");
const function_groups = [_][]const u8{ "functions", "additional_functions", "dynamic_functions" };
const allowed_efforts = [_][]const u8{ "low", "medium", "xhigh" };
const system_roles = [_][]const u8{ "system", "developer" };
const user_role = "user";
const assistant_role = "assistant";
const tool_role = "tool";
const text_type = "text";
const tool_use_type = "tool_use";
const tool_result_type = "tool_result";
const thinking_type = "thinking";
const redacted_type = "redacted_thinking";
const schema_type = "json_schema";
const auto_choice = "auto";
const none_choice = "none";
const required_choice = "required";
const any_choice = "any";
const max_replay_block_bytes = 1024 * 1024;
const terminal_delete_byte = 0x7f;

/// Only typed thinking and opaque redacted blocks can acquire same-family replay authority.
pub fn validate_replay_block(item: wire.Value) !void {
    if (item != .object) return error.InvalidReplayState;
    const kind = try wire.text(try wire.field(item, "type"));
    if (std.mem.eql(u8, kind, thinking_type)) {
        if (item.object.count() != 3) return error.InvalidReplayState;
        const thinking = try wire.text(try wire.field(item, "thinking"));
        if (thinking.len > max_replay_block_bytes) return error.InvalidReplayState;
        // Qwen's documented signature is an empty string; field presence still binds the shape.
        try validate_opaque(try wire.text(try wire.field(item, "signature")), true);
    } else if (std.mem.eql(u8, kind, redacted_type)) {
        if (item.object.count() != 2) return error.InvalidReplayState;
        try validate_opaque(try wire.text(try wire.field(item, "data")), false);
    } else return error.InvalidReplayState;
}

/// Signature bytes stay opaque; bounded terminal-safe strings prevent metadata smuggling.
fn validate_opaque(value: []const u8, allow_empty: bool) !void {
    if ((!allow_empty and value.len == 0) or value.len > max_replay_block_bytes) return error.InvalidReplayState;
    for (value) |byte| if (std.ascii.isControl(byte) or byte == terminal_delete_byte) return error.InvalidReplayState;
}

/// All fields belong to the caller's arena; dispatch supplies a positive admitted output limit.
pub fn project(alloc: wire.Allocator, request: wire.Value) !wire.Value {
    var body = wire.object();
    const limit = try wire.field(request, "max_output_tokens");
    if (limit != .integer or limit.integer <= 0) return error.InvalidRequest;
    try wire.put(alloc, &body, "max_tokens", limit);
    const messages = try wire.field(request, "messages");
    if (messages != .array) return error.InvalidRequest;
    var system: std.json.Array = .init(alloc);
    var output: std.json.Array = .init(alloc);
    for (messages.array.items) |message| {
        const role = try wire.text(try wire.field(message, "role"));
        const content = try wire.field(message, "content");
        const images = try wire.field(message, "images");
        const calls = try wire.field(message, "tool_calls");
        if (images != .array or calls != .array) return error.InvalidRequest;
        var is_system = false;
        for (system_roles) |candidate| if (std.mem.eql(u8, role, candidate)) {
            is_system = true;
            break;
        };
        if (is_system) {
            if (images.array.items.len != 0 or calls.array.items.len != 0) return error.InvalidRequest;
            if (content != .null) try append_text(alloc, &system, content);
            continue;
        }
        const assistant = std.mem.eql(u8, role, assistant_role);
        const tool = std.mem.eql(u8, role, tool_role);
        if (!assistant and !tool and !std.mem.eql(u8, role, user_role)) return error.InvalidRequest;
        if (!assistant and calls.array.items.len > 0) return error.InvalidRequest;
        var blocks: std.json.Array = .init(alloc);
        if (tool) {
            if (images.array.items.len != 0) return error.InvalidRequest;
            var block = wire.object();
            try wire.put(alloc, &block, "type", wire.string(tool_result_type));
            try wire.put(alloc, &block, "tool_use_id", wire.string(try wire.text(try wire.field(message, "tool_call_id"))));
            try wire.put(alloc, &block, "content", wire.string(try wire.text(content)));
            try blocks.append(block);
        } else {
            const state = try wire.field(message, "provider_state_json");
            if (assistant and state != .null) if (try replay.items(alloc, state, .messages)) |saved| {
                for (saved.array.items) |block| {
                    try validate_replay_block(block);
                    try blocks.append(block);
                }
            };
            const parts = try image_parts.messages_content(alloc, content, images);
            try blocks.appendSlice(parts.array.items);
            for (calls.array.items) |call| {
                var block = wire.object();
                const arguments = try std.json.parseFromSliceLeaky(wire.Value, alloc, try wire.text(try wire.field(call, "arguments_json")), .{ .allocate = .alloc_always });
                if (arguments != .object) return error.InvalidRequest;
                try wire.put(alloc, &block, "type", wire.string(tool_use_type));
                try wire.put(alloc, &block, "id", try wire.field(call, "id"));
                try wire.put(alloc, &block, "name", try wire.field(call, "name"));
                try wire.put(alloc, &block, "input", arguments);
                try blocks.append(block);
            }
        }
        if (blocks.items.len == 0) continue;
        const projected_role = if (assistant) assistant_role else user_role;
        // Grouped user results retain parallel tool associations while respecting alternating roles.
        if (output.items.len > 0 and std.mem.eql(u8, try wire.text(try wire.field(output.items[output.items.len - 1], "role")), projected_role)) {
            const previous = &output.items[output.items.len - 1].object.getPtr("content").?.array;
            try previous.appendSlice(blocks.items);
        } else {
            var projected = wire.object();
            try wire.put(alloc, &projected, "role", wire.string(projected_role));
            try wire.put(alloc, &projected, "content", .{ .array = blocks });
            try output.append(projected);
        }
    }
    if (system.items.len > 0) try wire.put(alloc, &body, "system", .{ .array = system });
    try wire.put(alloc, &body, "messages", .{ .array = output });
    var tools: std.json.Array = .init(alloc);
    for (function_groups) |group| {
        const functions = try wire.field(request, group);
        if (functions != .array) return error.InvalidRequest;
        for (functions.array.items) |function| {
            var tool = wire.object();
            try wire.put(alloc, &tool, "name", try wire.field(function, "name"));
            try wire.put(alloc, &tool, "description", try wire.field(function, "description"));
            try wire.put(alloc, &tool, "input_schema", try wire.field(function, "inputSchema"));
            try tools.append(tool);
        }
    }
    if (tools.items.len > 0) {
        try wire.put(alloc, &body, "tools", .{ .array = tools });
        const choice = try wire.text(try wire.field(request, "tool_choice"));
        if (!std.mem.eql(u8, choice, auto_choice) and !std.mem.eql(u8, choice, none_choice) and !std.mem.eql(u8, choice, required_choice)) return error.InvalidRequest;
        var tool_choice = wire.object();
        try wire.put(alloc, &tool_choice, "type", wire.string(if (std.mem.eql(u8, choice, required_choice)) any_choice else choice));
        const parallel = try wire.field(request, "parallel_tool_calls");
        if (parallel != .null) {
            if (parallel != .bool) return error.InvalidRequest;
            // Unset and enabled options retain the Messages default; none cannot call tools.
            if (!parallel.bool and !std.mem.eql(u8, choice, none_choice)) try wire.put(alloc, &tool_choice, "disable_parallel_tool_use", .{ .bool = true });
        }
        try wire.put(alloc, &body, "tool_choice", tool_choice);
    }
    var config = wire.object();
    const effort = try wire.field(request, "reasoning_effort");
    if (effort != .null) {
        const label = try wire.text(effort);
        var valid = false;
        for (allowed_efforts) |allowed| if (std.mem.eql(u8, label, allowed)) {
            valid = true;
            break;
        };
        if (!valid) return error.InvalidReasoningEffort;
        try wire.put(alloc, &config, "effort", effort);
    }
    const format = try wire.field(request, "response_format");
    if (format != .null) {
        var schema = wire.object();
        try wire.put(alloc, &schema, "type", wire.string(schema_type));
        try wire.put(alloc, &schema, "schema", try wire.field(format, "schema"));
        try wire.put(alloc, &config, "format", schema);
    }
    // Effort and strict schema share one provider object and must survive together.
    if (config.object.count() > 0) try wire.put(alloc, &body, "output_config", config);
    return body;
}

/// Separate policy blocks preserve system precedence without inventing user turns.
fn append_text(alloc: wire.Allocator, blocks: *std.json.Array, value: wire.Value) !void {
    const text = try wire.text(value);
    if (text.len == 0) return;
    var block = wire.object();
    try wire.put(alloc, &block, "type", wire.string(text_type));
    try wire.put(alloc, &block, "text", value);
    try blocks.append(block);
}
