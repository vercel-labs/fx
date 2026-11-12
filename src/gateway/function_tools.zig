//! The function tools a custom model connection's request offers, and the
//! checks on them that its codecs share (`chat_completions_protocol.zig`,
//! `anthropic_messages_protocol.zig`).
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const json_depth = @import("json_depth.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    InvalidToolName,
    TooManyTools,
    InvalidToolSelection,
    InvalidToolSchema,
    JsonTooDeep,
    RequiredToolMissing,
};

pub const max_selected_tools = 256;
pub const max_name_bytes = 128;
const max_json_depth = json_depth.max_depth;

pub const Function = struct {
    name: []const u8,
    description: []const u8,
    schema: union(enum) {
        builtin: model_tool_schema.ObjectSchema,
        dynamic: std.json.Value,
    },
};

pub fn contains_name(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

pub fn validate_name(name: []const u8) error{InvalidToolName}!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidToolName;
    // fx advertises dotted built-in names as well as MCP names. Keep those
    // literal identities; do not invent aliases that core cannot resolve.
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return error.InvalidToolName;
}

fn append_function(alloc: Allocator, functions: *std.ArrayList(Function), function: Function) Error!void {
    try validate_name(function.name);
    if (functions.items.len == max_selected_tools) return error.TooManyTools;
    for (functions.items) |prior| if (std.mem.eql(u8, prior.name, function.name)) return error.InvalidToolSelection;
    try functions.append(alloc, function);
}

// Provider-native advertisements are not Chat Completions function tools.
// Omit only registered provider-executed tools; missing ordinary schemas fail.
// The image fallback's `vision` tool joins the list when the request may use
// it, and is the only tool when the request must, as the gateway sends it.
pub fn select_functions(alloc: Allocator, tools: stream_provider.ToolSelection, choice: types.ToolChoice, vision_mode: stream_provider.VisionMode) Error!std.ArrayList(Function) {
    var functions: std.ArrayList(Function) = .empty;
    errdefer functions.deinit(alloc);
    if (choice == .none) return functions;
    if (vision_mode == .required) {
        try append_vision(alloc, &functions, tools);
        return functions;
    }
    if (tools.advertised_names.len > max_selected_tools or tools.advertised_functions.len > max_selected_tools or tools.additional_functions.len > max_selected_tools or tools.selected_dynamic.len > max_selected_tools) return error.TooManyTools;
    for (tools.advertised_names) |name| {
        const function = tools.advertisedFunction(name) orelse {
            const registered = tools.registry.lookup(name) orelse return error.InvalidToolSelection;
            if (registered.provider_executed) continue;
            return error.InvalidToolSelection;
        };
        // A repeated definition must not be selected by accidental first match.
        var matches: usize = 0;
        for (tools.advertised_functions) |candidate| if (std.mem.eql(u8, candidate.name, name)) {
            matches += 1;
        };
        if (matches != 1) return error.InvalidToolSelection;
        try append_function(alloc, &functions, .{ .name = name, .description = function.description, .schema = .{ .builtin = function.input_schema } });
    }
    for (tools.additional_functions) |function| {
        if (contains_name(tools.advertised_names, function.name)) continue;
        try append_function(alloc, &functions, .{ .name = function.name, .description = function.description, .schema = .{ .builtin = function.input_schema } });
    }
    var schema_budget: SchemaBudget = .{};
    for (tools.selected_dynamic) |function| {
        if (contains_name(tools.advertised_names, function.name)) continue;
        if (function.input_schema != .object) return error.InvalidToolSchema;
        try validate_dynamic_schema(function.input_schema, 0, &schema_budget);
        try append_function(alloc, &functions, .{ .name = function.name, .description = function.description, .schema = .{ .dynamic = function.input_schema } });
    }
    if (vision_mode == .optional and !contains_name(tools.advertised_names, "vision")) try append_vision(alloc, &functions, tools);
    if (choice == .required and functions.items.len == 0) return error.RequiredToolMissing;
    return functions;
}

fn append_vision(alloc: Allocator, functions: *std.ArrayList(Function), tools: stream_provider.ToolSelection) Error!void {
    const vision = tools.registry.lookup("vision") orelse return error.InvalidToolSelection;
    const schema = vision.model_schema;
    try append_function(alloc, functions, .{ .name = schema.name, .description = schema.description, .schema = .{ .builtin = schema.input_schema } });
}

const SchemaBudget = struct {
    nodes: usize = 16 * 1024,
    string_bytes: usize = 1024 * 1024,

    fn consume_string(self: *SchemaBudget, text: []const u8) Error!void {
        if (text.len > self.string_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidToolSchema;
        self.string_bytes -= text.len;
    }
};

fn validate_dynamic_schema(value: std.json.Value, depth: usize, budget: *SchemaBudget) Error!void {
    if (depth > max_json_depth) return error.JsonTooDeep;
    if (budget.nodes == 0) return error.InvalidToolSchema;
    budget.nodes -= 1;
    switch (value) {
        .object => |fields| {
            var iterator = fields.iterator();
            while (iterator.next()) |entry| {
                try budget.consume_string(entry.key_ptr.*);
                try validate_dynamic_schema(entry.value_ptr.*, depth + 1, budget);
            }
        },
        .array => |items| for (items.items) |item| try validate_dynamic_schema(item, depth + 1, budget),
        .string => |text| try budget.consume_string(text),
        .number_string => return error.InvalidToolSchema,
        .float => |number| if (!std.math.isFinite(number)) return error.InvalidToolSchema,
        .integer, .bool, .null => {},
    }
}

pub fn toolResultDenied(message: types.ChatMessage) bool {
    const failed = if (message.tool_result_status) |status|
        status == .failure
    else
        false;
    return failed and tool_result_errors.toolPermissionDenialReason(message.content orelse "") != null;
}

pub fn last_user_index(messages: []const types.ChatMessage) ?usize {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        if (messages[index].role == .user) return index;
    }
    return null;
}

test "function tools bound dynamic schema traversal" {
    var exhausted_nodes = SchemaBudget{ .nodes = 0 };
    try std.testing.expectError(error.InvalidToolSchema, validate_dynamic_schema(.null, 0, &exhausted_nodes));
    var exhausted_strings = SchemaBudget{ .string_bytes = 2 };
    try std.testing.expectError(error.InvalidToolSchema, validate_dynamic_schema(.{ .string = "abc" }, 0, &exhausted_strings));
    var budget: SchemaBudget = .{};
    try std.testing.expectError(error.InvalidToolSchema, validate_dynamic_schema(.{ .float = std.math.inf(f64) }, 0, &budget));
}
