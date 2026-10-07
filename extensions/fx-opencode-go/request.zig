//! Native conversation projection preserves tools and provider-owned reasoning without importing fx internals.
const std = @import("std");
const wire = @import("wire.zig");
const image_parts = @import("image_parts.zig");
const routes = @import("routes.zig");
const responses_request = @import("responses_request.zig");
const messages_request = @import("messages_request.zig");
const replay = @import("replay.zig");
const Allocator = wire.Allocator;
const Value = wire.Value;
const provider_id = "opencode-go";
const completion_path = "/chat/completions";
const responses_path = "/responses";
const messages_path = "/messages";
const max_output_limit = std.math.maxInt(u32);
const path_separator = "/";
const allowed_efforts = [_][]const u8{ "low", "high", "max" };

/// The worker receives a credential-free prepared body; its arena owns all request strings.
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    handle: []const u8,
    endpoint: []const u8,
    body: []const u8,
    api: routes.Api,

    pub fn deinit(self: *Prepared) void {
        self.arena.deinit();
    }

    /// Each prepare identity is single-use, preventing a stale stream from borrowing another body.
    pub fn create(backing: Allocator, id: u64, params: Value) !Prepared {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const provider = try wire.field(params, "provider");
        if (!std.mem.eql(u8, try wire.text(try wire.field(provider, "id")), provider_id)) return error.InvalidProvider;
        const model = try wire.field(params, "model");
        const wire_id = try wire.text(try wire.field(model, "wire_id"));
        const api = try routes.resolve(wire_id);
        const base = try wire.text(try wire.field(provider, "base_url"));
        var uri = try std.Uri.parse(base);
        const base_path = switch (uri.path) {
            .raw, .percent_encoded => |path| path,
        };
        // Encoded path ownership preserves proxy routing without rewriting query values.
        const api_path = switch (api) {
            .chat_completions => completion_path,
            .responses => responses_path,
            .messages => messages_path,
        };
        uri.path = .{ .percent_encoded = try std.fmt.allocPrint(alloc, "{s}{s}", .{ std.mem.trimEnd(u8, base_path, path_separator), api_path }) };
        const endpoint = try std.fmt.allocPrint(alloc, "{f}", .{uri.fmt(.all)});
        var request = try wire.field(params, "request");
        if (api == .messages) {
            // Messages requires a limit even when the native turn leaves it to catalog admission.
            const admitted = try wire.field(model, "max_output_tokens");
            if (admitted != .integer or admitted.integer <= 0 or admitted.integer > max_output_limit) return error.InvalidRequest;
            const requested = try wire.field(request, "max_output_tokens");
            const limit = if (requested == .null) admitted else requested;
            if (limit != .integer or limit.integer <= 0 or limit.integer > admitted.integer) return error.InvalidRequest;
            try wire.put(alloc, &request, "max_output_tokens", limit);
        }
        var body = switch (api) {
            .chat_completions => try chat_body(alloc, request),
            .responses => try responses_request.project(alloc, request),
            .messages => try messages_request.project(alloc, request),
        };
        try wire.put(alloc, &body, "model", try wire.field(model, "wire_id"));
        try wire.put(alloc, &body, "stream", .{ .bool = true });
        if (api == .responses) {
            try responses_request.validate_effort(wire_id, try wire.field(request, "reasoning_effort"));
            try responses_request.apply_model_grammar(alloc, wire_id, &body);
        }
        const handle = try std.fmt.allocPrint(alloc, "prepared-{d}", .{id});
        const encoded = try std.json.Stringify.valueAlloc(alloc, body, .{});
        return .{ .arena = arena, .handle = handle, .endpoint = endpoint, .body = encoded, .api = api };
    }
};

/// Keeping each wire grammar separate prevents one API family's options leaking into another.
fn chat_body(alloc: Allocator, request: Value) !Value {
    var body = wire.object();
    var options = wire.object();
    try wire.put(alloc, &options, "include_usage", .{ .bool = true });
    try wire.put(alloc, &body, "stream_options", options);
    try wire.put(alloc, &body, "messages", try messages(alloc, try wire.field(request, "messages")));
    const effort = try wire.field(request, "reasoning_effort");
    if (effort != .null) {
        const label = try wire.text(effort);
        var valid = false;
        for (allowed_efforts) |allowed| if (std.mem.eql(u8, label, allowed)) {
            valid = true;
            break;
        };
        if (!valid) return error.InvalidReasoningEffort;
        try wire.put(alloc, &body, "reasoning_effort", effort);
    }
    const output_limit = try wire.field(request, "max_output_tokens");
    if (output_limit != .null) try wire.put(alloc, &body, "max_tokens", output_limit);
    var tools: std.json.Array = .init(alloc);
    for ([_][]const u8{ "functions", "additional_functions", "dynamic_functions" }) |name| {
        const functions = try wire.field(request, name);
        if (functions != .array) return error.InvalidRequest;
        for (functions.array.items) |function| {
            var projected = wire.object();
            try wire.put(alloc, &projected, "name", try wire.field(function, "name"));
            try wire.put(alloc, &projected, "description", try wire.field(function, "description"));
            try wire.put(alloc, &projected, "parameters", try wire.field(function, "inputSchema"));
            var tool = wire.object();
            try wire.put(alloc, &tool, "type", wire.string("function"));
            try wire.put(alloc, &tool, "function", projected);
            try tools.append(tool);
        }
    }
    if (tools.items.len > 0) {
        try wire.put(alloc, &body, "tools", .{ .array = tools });
        try wire.put(alloc, &body, "tool_choice", try wire.field(request, "tool_choice"));
        // Unset native options retain the API default rather than encoding an invalid null.
        const parallel = try wire.field(request, "parallel_tool_calls");
        if (parallel != .null) {
            if (parallel != .bool) return error.InvalidRequest;
            try wire.put(alloc, &body, "parallel_tool_calls", parallel);
        }
    }
    const format = try wire.field(request, "response_format");
    if (format != .null) {
        var schema = wire.object();
        try wire.put(alloc, &schema, "name", try wire.field(format, "name"));
        try wire.put(alloc, &schema, "description", try wire.field(format, "description"));
        try wire.put(alloc, &schema, "schema", try wire.field(format, "schema"));
        try wire.put(alloc, &schema, "strict", .{ .bool = true });
        var response = wire.object();
        try wire.put(alloc, &response, "type", wire.string("json_schema"));
        try wire.put(alloc, &response, "json_schema", schema);
        try wire.put(alloc, &body, "response_format", response);
    }
    return body;
}

/// Replay is owned by this provider only; raw fx metadata never reaches the HTTP message shape.
fn messages(alloc: Allocator, input: Value) !Value {
    if (input != .array) return error.InvalidRequest;
    var items: std.json.Array = .init(alloc);
    for (input.array.items) |message| {
        var projected = wire.object();
        const role = try wire.field(message, "role");
        try wire.put(alloc, &projected, "role", role);
        try wire.put(alloc, &projected, "content", try image_parts.content(alloc, try wire.field(message, "content"), try wire.field(message, "images")));
        const tool_id = try wire.field(message, "tool_call_id");
        if (tool_id != .null) try wire.put(alloc, &projected, "tool_call_id", tool_id);
        const calls = try wire.field(message, "tool_calls");
        if (calls != .array) return error.InvalidRequest;
        if (calls.array.items.len > 0) {
            var output_calls: std.json.Array = .init(alloc);
            for (calls.array.items) |call| {
                var function = wire.object();
                try wire.put(alloc, &function, "name", try wire.field(call, "name"));
                try wire.put(alloc, &function, "arguments", try wire.field(call, "arguments_json"));
                var output = wire.object();
                try wire.put(alloc, &output, "id", try wire.field(call, "id"));
                try wire.put(alloc, &output, "type", wire.string("function"));
                try wire.put(alloc, &output, "function", function);
                try output_calls.append(output);
            }
            try wire.put(alloc, &projected, "tool_calls", .{ .array = output_calls });
        }
        const state = try wire.field(message, "provider_state_json");
        if (state != .null and std.mem.eql(u8, try wire.text(role), "assistant")) {
            if (try replay.items(alloc, state, .chat_completions)) |saved| {
                if (saved.array.items.len != 1) return error.InvalidReplayState;
                const reasoning = try wire.field(saved.array.items[0], "reasoning_content");
                if (reasoning != .string) return error.InvalidReplayState;
                try wire.put(alloc, &projected, "reasoning_content", reasoning);
            }
        }
        try items.append(projected);
    }
    return .{ .array = items };
}
