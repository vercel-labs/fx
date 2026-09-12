const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const sse = @import("sse.zig");
const configured_provider = @import("../core/config/configured_provider.zig");

const Allocator = std.mem.Allocator;

pub const ToolChoiceMode = configured_provider.ToolChoiceMode;
pub const Options = struct {
    tool_choice_mode: ToolChoiceMode = .omit,
};

pub const Error = error{
    OutOfMemory,
    InvalidProviderPrompt,
    InvalidModel,
    UnsupportedProviderOption,
    UnsupportedVision,
    UnsupportedResponseFormat,
    UnsupportedReplay,
    UnsupportedToolProvenance,
    InvalidOutputLimit,
    InvalidToolSelection,
    InvalidToolSchema,
    InvalidToolCallId,
    InvalidToolName,
    InvalidToolArguments,
    InvalidToolHistory,
    RequiredToolMissing,
    UnexpectedToolCall,
    InvalidChunk,
    ConflictingIdentity,
    InvalidFinishReason,
    InconsistentFinishReason,
    IncompleteStream,
    StreamClosed,
    ProviderError,
    OutputTruncated,
    ContentFiltered,
    Refused,
    EventTooLarge,
    StreamTooLarge,
    TooManyEvents,
    TooManyTools,
    IdentityTooLarge,
    ArgumentsTooLarge,
    ContentTooLarge,
    JsonTooDeep,
    Cancelled,
    ReadFailed,
};

const max_selected_tools = 256;
const max_name_bytes = 128;
const max_history_arguments_bytes = 1024 * 1024;
const max_json_depth = 64;

const Function = struct {
    name: []const u8,
    description: []const u8,
    schema: union(enum) {
        builtin: model_tool_schema.ObjectSchema,
        dynamic: std.json.Value,
    },
};

fn contains_name(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn validate_name(name: []const u8) Error!void {
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
fn select_functions(alloc: Allocator, tools: stream_provider.ToolSelection, choice: types.ToolChoice) Error!std.ArrayList(Function) {
    var functions: std.ArrayList(Function) = .empty;
    errdefer functions.deinit(alloc);
    if (choice == .none) return functions;
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
    if (choice == .required and functions.items.len == 0) return error.RequiredToolMissing;
    return functions;
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

fn validate_request(request: stream_provider.RequestData) Error!void {
    try request.validatePrompt();
    configured_provider.validate_model_id(request.model) catch return error.InvalidModel;
    const options = request.provider_options;
    if (options.reasoning != null or options.fast or options.prompt_caching) return error.UnsupportedProviderOption;
    if (request.response_format != null) return error.UnsupportedResponseFormat;
    if (request.vision_mode != .unavailable or (request.verified_images != null and request.verified_images.?.len != 0)) return error.UnsupportedVision;
    if (request.max_output_tokens == 0) return error.InvalidOutputLimit;
    for (request.messages) |message| {
        if (message.images.len != 0) return error.UnsupportedVision;
        if (message.provider_replay != null) return error.UnsupportedReplay;
        if (message.role != .assistant and message.tool_calls.len != 0) return error.InvalidToolHistory;
        if (message.role != .tool and message.tool_call_id != null) return error.InvalidToolHistory;
        if (message.role != .assistant and message.content == null) return error.InvalidProviderPrompt;
        if (message.role == .assistant and message.content == null and message.tool_calls.len == 0) return error.InvalidProviderPrompt;
    }
}

fn check_json_depth(text: []const u8) Error!void {
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (text) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                if (depth == max_json_depth) return error.JsonTooDeep;
                depth += 1;
            },
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }
}

/// Caller owns the bounded diagnostic. Normalize JSON before masking so later
/// diagnostic decoding cannot restore an escaped credential.
pub fn redact_error_detail(alloc: Allocator, raw: []const u8, credential: []const u8) Allocator.Error![]u8 {
    if (raw.len > 64 * 1024 or credential.len > 16 * 1024) return alloc.dupe(u8, "Provider error details exceeded the local limit");
    check_json_depth(raw) catch return alloc.dupe(u8, "Provider error details exceeded the nesting limit");
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const json_shaped = trimmed.len != 0 and (trimmed[0] == '{' or trimmed[0] == '[' or trimmed[0] == '"');
    var parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (json_shaped) return alloc.dupe(u8, "Provider error details could not be decoded") else null,
    };
    defer if (parsed) |*value| value.deinit();
    const detail = if (parsed) |value| try std.json.Stringify.valueAlloc(alloc, value.value, .{}) else try alloc.dupe(u8, raw);
    if (detail.len > 64 * 1024) {
        defer alloc.free(detail);
        return alloc.dupe(u8, "Provider error details exceeded the local limit");
    }
    errdefer alloc.free(detail);
    const encoded = try std.json.Stringify.valueAlloc(alloc, credential, .{});
    defer alloc.free(encoded);
    mask_error_bytes(detail, encoded[1 .. encoded.len - 1]);
    mask_error_bytes(detail, credential);
    return detail;
}

fn mask_error_bytes(detail: []u8, value: []const u8) void {
    if (value.len == 0) return;
    var remaining = detail;
    while (std.mem.find(u8, remaining, value)) |index| {
        @memset(remaining[index..][0..value.len], '*');
        remaining = remaining[index + value.len ..];
    }
}

test "chat completions error masking survives JSON and recovery decoding" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { raw: []const u8, key: []const u8 }{
        .{ .raw = "{\"error\":{\"message\":\"rejected alpha\\/beta\",\"code\":\"alpha\\/beta\"}}", .key = "alpha/beta" },
        .{ .raw = "{\"error\":{\"message\":\"rejected \\u0061lpha\"}}", .key = "alpha" },
        .{ .raw = "{\"error\":{\"message\":\"rejected alpha\\\"beta\"}}", .key = "alpha\"beta" },
        .{ .raw = "rejected alpha/beta", .key = "alpha/beta" },
    };
    for (cases) |case| {
        const detail = try redact_error_detail(alloc, case.raw, case.key);
        defer alloc.free(detail);
        const message = try @import("../core/shared/gateway_error_format.zig").formatHttpRecoveryDiagnostic(alloc, .bad_request, detail);
        defer alloc.free(message);
        try std.testing.expect(std.mem.find(u8, message, case.key) == null);
        try std.testing.expect(std.mem.find(u8, message, "rejected") != null);
    }
    const duplicate = try redact_error_detail(alloc, "{\"error\":{\"message\":\"alpha\\/beta\"},\"alpha/beta\":0,\"alpha\\/beta\":1}", "alpha/beta");
    defer alloc.free(duplicate);
    try std.testing.expectEqualStrings("Provider error details could not be decoded", duplicate);
    const nested = "[" ** 65 ++ "0" ++ "]" ** 65;
    const bounded = try redact_error_detail(alloc, nested, "alpha");
    defer alloc.free(bounded);
    try std.testing.expectEqualStrings("Provider error details exceeded the nesting limit", bounded);
}

test "chat completions error masking releases partial allocations" {
    const Probe = struct {
        fn run(alloc: Allocator) !void {
            const detail = try redact_error_detail(alloc, "{\"error\":{\"message\":\"alpha\\/beta\"}}", "alpha/beta");
            defer alloc.free(detail);
            const invalid = try redact_error_detail(alloc, "{\"x\":0,\"x\":1}", "alpha/beta");
            defer alloc.free(invalid);
            const plain = try redact_error_detail(alloc, "rejected alpha/beta", "alpha/beta");
            defer alloc.free(plain);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

fn validate_arguments(alloc: Allocator, text: []const u8) Error!void {
    try check_json_depth(text);
    if (try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, text) != .valid) return error.InvalidToolArguments;
}

fn validate_history(alloc: Allocator, messages: []const types.ChatMessage) Error!void {
    var pending: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer pending.deinit(alloc);
    for (messages) |message| {
        if (message.role == .tool) {
            const id = message.tool_call_id orelse return error.InvalidToolCallId;
            const name = pending.get(id) orelse return error.InvalidToolHistory;
            if (message.tool_name) |tool_name| if (!std.mem.eql(u8, tool_name, name)) return error.InvalidToolHistory;
            _ = pending.remove(id);
            continue;
        }
        if (pending.count() != 0) return error.InvalidToolHistory;
        if (message.tool_calls.len > max_selected_tools) return error.TooManyTools;
        for (message.tool_calls) |call| {
            if (call.provenance != .fx_local or call.provider_result != null) return error.UnsupportedToolProvenance;
            if (call.id.len == 0 or call.final_identity != .valid) return error.InvalidToolCallId;
            try validate_name(call.name);
            if (call.argument_integrity != .valid) return error.InvalidToolArguments;
            if (call.arguments_json.len > max_history_arguments_bytes) return error.ArgumentsTooLarge;
            try validate_arguments(alloc, call.arguments_json);
            const entry = try pending.getOrPut(alloc, call.id);
            if (entry.found_existing) return error.InvalidToolHistory;
            entry.value_ptr.* = call.name;
        }
    }
    if (pending.count() != 0) return error.InvalidToolHistory;
}

/// Pure Chat Completions serialization. Caller owns the returned bytes. Model
/// IDs are opaque: no catalog lookup, prefix inference, or provider defaults.
/// max_output_tokens deliberately maps to max_tokens, not max_completion_tokens.
/// Deadline enforcement and prepared-body reuse belong to the transport owner.
pub fn build_request(alloc: Allocator, request: stream_provider.RequestData, options: Options) Error![]u8 {
    try validate_request(request);
    try validate_history(alloc, request.messages);
    var functions = try select_functions(alloc, request.tools, request.tool_choice);
    defer functions.deinit(alloc);
    var projection = tool_call_ids.Projection.init(alloc, request.messages) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolCallId,
    };
    defer projection.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    write_request(&out.writer, alloc, request, options, functions.items, &projection) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    return out.toOwnedSlice();
}

fn write_request(writer: *std.Io.Writer, alloc: Allocator, request: stream_provider.RequestData, options: Options, functions: []const Function, projection: *const tool_call_ids.Projection) !void {
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    var count: usize = 0;
    for ([_][]const types.ChatMessage{ request.instructions, request.messages }) |lane| for (lane) |message| {
        if (count != 0) try writer.writeByte(',');
        count += 1;
        try writer.writeAll("{\"role\":");
        try std.json.Stringify.value(@tagName(message.role), .{}, writer);
        try writer.writeAll(",\"content\":");
        try std.json.Stringify.value(message.content, .{}, writer);
        if (message.role == .tool) {
            try writer.writeAll(",\"tool_call_id\":");
            try std.json.Stringify.value(projection.resolve(message.tool_call_id.?), .{}, writer);
        }
        if (message.tool_calls.len != 0) {
            try writer.writeAll(",\"tool_calls\":[");
            for (message.tool_calls, 0..) |call, index| {
                if (index != 0) try writer.writeByte(',');
                try writer.writeAll("{\"id\":");
                try std.json.Stringify.value(projection.resolve(call.id), .{}, writer);
                try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                try std.json.Stringify.value(call.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(call.arguments_json, .{}, writer);
                try writer.writeAll("}}");
            }
            try writer.writeByte(']');
        }
        try writer.writeByte('}');
    };
    try writer.writeByte(']');
    if (functions.len != 0) {
        try writer.writeAll(",\"tools\":[");
        for (functions, 0..) |function, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try std.json.Stringify.value(function.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, function.description);
            try writer.writeAll(",\"parameters\":");
            switch (function.schema) {
                .builtin => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
                .dynamic => |schema| try std.json.Stringify.value(schema, .{}, writer),
            }
            try writer.writeAll("}}");
        }
        try writer.writeByte(']');
    }
    if (options.tool_choice_mode == .send) {
        try writer.writeAll(",\"tool_choice\":");
        try std.json.Stringify.value(@tagName(request.tool_choice), .{}, writer);
    }
    if (request.provider_options.parallel_tool_calls) |parallel| {
        try writer.writeAll(",\"parallel_tool_calls\":");
        try std.json.Stringify.value(parallel, .{}, writer);
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    try writer.writeByte('}');
}

pub const Limits = struct {
    event_bytes: usize = 1024 * 1024,
    total_wire_bytes: usize = 32 * 1024 * 1024,
    events: usize = 100_000,
    tool_calls: usize = 128,
    identity_bytes: usize = 256,
    arguments_bytes: usize = 1024 * 1024,
    content_bytes: usize = 8 * 1024 * 1024,
};

const Tool = struct {
    id: ?[]u8 = null,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *Tool, alloc: Allocator) void {
        if (self.id) |id| alloc.free(id);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

/// Single-owner, request-local state machine. No I/O, callbacks, tool execution,
/// or hidden cancellation reads. Owns all retained input (including selected
/// names) until deinit. Any accept/finish failure poisons the reducer; deinit
/// remains mandatory. A successful finish transfers independent owned results.
pub const Reducer = struct {
    alloc: Allocator,
    limits: Limits,
    choice: types.ToolChoice,
    names: std.ArrayList([]u8) = .empty,
    tools: std.ArrayList(Tool) = .empty,
    content: std.ArrayList(u8) = .empty,
    generation_id: ?[]u8 = null,
    response_model: ?[]u8 = null,
    usage: types.Usage = .{},
    usage_seen: bool = false,
    refusal_seen: bool = false,
    finish_reason: ?types.ProviderFinishReason = null,
    phase: enum { receiving, finished, done, closed } = .receiving,
    event_count: usize = 0,
    json_bytes: usize = 0,

    pub fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits) Error!Reducer {
        try validate_request(request);
        var functions = try select_functions(alloc, request.tools, request.tool_choice);
        defer functions.deinit(alloc);
        var self = Reducer{ .alloc = alloc, .limits = limits, .choice = request.tool_choice };
        errdefer self.deinit();
        for (functions.items) |function| {
            const name = try alloc.dupe(u8, function.name);
            errdefer alloc.free(name);
            try self.names.append(alloc, name);
        }
        return self;
    }

    pub fn deinit(self: *Reducer) void {
        for (self.names.items) |name| self.alloc.free(name);
        self.names.deinit(self.alloc);
        for (self.tools.items) |*tool| tool.deinit(self.alloc);
        self.tools.deinit(self.alloc);
        self.content.deinit(self.alloc);
        if (self.generation_id) |id| self.alloc.free(id);
        if (self.response_model) |model| self.alloc.free(model);
        self.* = undefined;
    }

    /// Accepts one already-framed data event. Returns presentation-only content
    /// borrowed until the next mutation or deinit. JSON-only callers must also
    /// bound their framing wire; consume_stream does this including comments.
    pub fn accept(self: *Reducer, data: []const u8, cancelled: bool) Error!?[]const u8 {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase == .closed or self.phase == .done) return error.StreamClosed;
        if (data.len > self.limits.event_bytes) return error.EventTooLarge;
        if (data.len > self.limits.total_wire_bytes - self.json_bytes) return error.StreamTooLarge;
        self.json_bytes += data.len;
        if (self.event_count == self.limits.events) return error.TooManyEvents;
        self.event_count += 1;
        if (std.mem.eql(u8, data, "[DONE]")) {
            if (self.phase != .finished) return error.IncompleteStream;
            self.phase = .done;
            return null;
        }
        try check_json_depth(data);
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidChunk,
        };
        defer parsed.deinit();
        const root = try object(parsed.value);
        if (non_null(root, "error") != null) return error.ProviderError;
        try self.accept_identity(&self.generation_id, non_null(root, "id"), self.limits.identity_bytes);
        try self.accept_identity(&self.response_model, non_null(root, "model"), configured_provider.max_model_bytes);
        const choices_value = root.get("choices") orelse return error.InvalidChunk;
        if (choices_value != .array) return error.InvalidChunk;
        const choices = choices_value.array.items;
        if (choices.len > 1) return error.InvalidChunk;
        if (choices.len == 0) {
            if (self.phase != .finished) return error.InvalidChunk;
            try self.accept_usage(non_null(root, "usage") orelse return error.InvalidChunk);
            return null;
        }
        const choice = try object(choices[0]);
        if (try index_value(choice.get("index") orelse return error.InvalidChunk) != 0) return error.InvalidChunk;
        const delta = try object(choice.get("delta") orelse return error.InvalidChunk);
        if (self.phase == .finished) {
            const reason = try string(non_null(choice, "finish_reason") orelse return error.InconsistentFinishReason);
            if (!std.mem.eql(u8, reason, @tagName(self.finish_reason.?))) return error.InconsistentFinishReason;
            var fields = delta.iterator();
            while (fields.next()) |field| {
                if (std.mem.eql(u8, field.key_ptr.*, "role")) {
                    if (field.value_ptr.* != .string or !std.mem.eql(u8, field.value_ptr.string, "assistant")) return error.InconsistentFinishReason;
                } else if (std.mem.eql(u8, field.key_ptr.*, "content")) {
                    if (field.value_ptr.* != .null and (field.value_ptr.* != .string or field.value_ptr.string.len != 0)) return error.InconsistentFinishReason;
                } else return error.InconsistentFinishReason;
            }
            try self.accept_usage(non_null(root, "usage") orelse return error.InconsistentFinishReason);
            return null;
        }
        if (non_null(delta, "role")) |role| if (!std.mem.eql(u8, try string(role), "assistant")) return error.InvalidChunk;
        // These fields carry semantics outside this codec's text/function subset.
        for ([_][]const u8{ "function_call", "reasoning", "reasoning_content", "audio" }) |key| if (non_null(delta, key) != null) return error.InvalidChunk;
        const content_start = self.content.items.len;
        if (non_null(delta, "content")) |value| try append_bounded(self.alloc, &self.content, try string(value), self.limits.content_bytes, error.ContentTooLarge);
        if (non_null(delta, "refusal")) |value| {
            const refusal = try string(value);
            self.refusal_seen = self.refusal_seen or refusal.len != 0;
        }
        if (non_null(delta, "tool_calls")) |value| try self.accept_tools(value);
        if (non_null(root, "usage")) |usage| try self.accept_usage(usage);
        if (non_null(choice, "finish_reason")) |value| {
            const reason = try string(value);
            self.finish_reason = if (std.mem.eql(u8, reason, "stop")) .stop else if (std.mem.eql(u8, reason, "tool_calls")) .tool_calls else if (std.mem.eql(u8, reason, "length")) .length else if (std.mem.eql(u8, reason, "content_filter")) .content_filter else return error.InvalidFinishReason;
            self.phase = .finished;
        }
        return if (self.content.items.len > content_start) self.content.items[content_start..] else null;
    }

    fn accept_identity(self: *Reducer, destination: *?[]u8, value: ?std.json.Value, max_bytes: usize) Error!void {
        const text = try string(value orelse return);
        if (text.len == 0) return error.InvalidChunk;
        if (text.len > max_bytes) return error.IdentityTooLarge;
        if (destination.*) |prior| {
            if (!std.mem.eql(u8, prior, text)) return error.ConflictingIdentity;
        } else destination.* = try self.alloc.dupe(u8, text);
    }

    fn accept_tools(self: *Reducer, value: std.json.Value) Error!void {
        if (value != .array) return error.InvalidChunk;
        if (value.array.items.len > self.limits.tool_calls) return error.TooManyTools;
        if (value.array.items.len != 0 and self.choice == .none) return error.UnexpectedToolCall;
        for (value.array.items, 0..) |item, delta_index| {
            const delta = try object(item);
            const index = try index_value(delta.get("index") orelse return error.InvalidChunk);
            if (index >= self.limits.tool_calls) return error.TooManyTools;
            for (value.array.items[0..delta_index]) |prior| {
                if (try index_value((try object(prior)).get("index") orelse return error.InvalidChunk) == index) return error.ConflictingIdentity;
            }
            while (self.tools.items.len <= index) try self.tools.append(self.alloc, .{});
            const tool = &self.tools.items[index];
            if (non_null(delta, "type")) |kind| if (!std.mem.eql(u8, try string(kind), "function")) return error.InvalidChunk;
            try self.accept_identity(&tool.id, non_null(delta, "id"), self.limits.identity_bytes);
            if (tool.id) |id| for (self.tools.items, 0..) |other, other_index| {
                if (other_index != index and other.id != null and std.mem.eql(u8, id, other.id.?)) return error.ConflictingIdentity;
            };
            if (non_null(delta, "function")) |function_value| {
                const function = try object(function_value);
                if (non_null(function, "name")) |name_value| {
                    const fragment = try string(name_value);
                    try append_bounded(self.alloc, &tool.name, fragment, @min(max_name_bytes, self.limits.identity_bytes), error.IdentityTooLarge);
                    var prefix = false;
                    for (self.names.items) |name| prefix = prefix or std.mem.startsWith(u8, name, tool.name.items);
                    if (!prefix) return error.InvalidToolName;
                }
                if (non_null(function, "arguments")) |arguments| try append_bounded(self.alloc, &tool.arguments, try string(arguments), self.limits.arguments_bytes, error.ArgumentsTooLarge);
            }
        }
    }

    fn known_name(self: *const Reducer, name: []const u8) bool {
        for (self.names.items) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
        return false;
    }

    fn accept_usage(self: *Reducer, value: std.json.Value) Error!void {
        const fields = try object(value);
        const usage = types.Usage{
            .input_tokens = try token_count(fields, "prompt_tokens"),
            .output_tokens = try token_count(fields, "completion_tokens"),
        };
        const total = try token_count(fields, "total_tokens");
        if (total) |tokens| if (usage.input_tokens != null and usage.output_tokens != null) {
            const sum = std.math.add(u64, usage.input_tokens.?, usage.output_tokens.?) catch return error.InvalidChunk;
            if (tokens != sum) return error.InvalidChunk;
        };
        if (self.usage_seen) {
            if (!std.meta.eql(self.usage, usage)) return error.ConflictingIdentity;
        } else {
            self.usage = usage;
            self.usage_seen = true;
        }
    }

    /// Requires finish_reason followed by [DONE]. Length/filter/refusal are
    /// explicit errors, never executable partial calls or successful tool turns.
    /// Results use stream_provider.Result.deinit with this reducer's allocator.
    /// Observed tokens are not exact billing; no deferred lookup is invented.
    pub fn finish(self: *Reducer, cancelled: bool) Error!stream_provider.Result {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase == .closed) return error.StreamClosed;
        if (self.phase != .done) return error.IncompleteStream;
        const reason = self.finish_reason.?;
        switch (reason) {
            .length => return error.OutputTruncated,
            .content_filter => return error.ContentFiltered,
            .stop, .tool_calls => {},
            else => return error.InvalidFinishReason,
        }
        if (self.refusal_seen) return error.Refused;
        if ((reason == .tool_calls) != (self.tools.items.len != 0)) return error.InconsistentFinishReason;
        if (self.choice == .required and self.tools.items.len == 0) return error.RequiredToolMissing;
        for (self.tools.items) |tool| {
            if (tool.id == null) return error.InvalidToolCallId;
            if (!self.known_name(tool.name.items)) return error.InvalidToolName;
            try validate_arguments(self.alloc, tool.arguments.items);
        }
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| {
                self.alloc.free(call.id);
                self.alloc.free(call.name);
                self.alloc.free(call.arguments_json);
            }
            calls.deinit(self.alloc);
        }
        for (self.tools.items) |*tool| {
            // finish() is terminal: ownership moves to the result and the
            // emptied accumulators cost nothing at reducer deinit.
            const id = tool.id.?;
            tool.id = null;
            errdefer self.alloc.free(id);
            const name = try tool.name.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(name);
            const arguments = try tool.arguments.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(arguments);
            try calls.append(self.alloc, .{ .id = id, .name = name, .arguments_json = arguments });
        }
        const content = if (self.content.items.len != 0) try self.content.toOwnedSlice(self.alloc) else null;
        errdefer if (content) |text| self.alloc.free(text);
        const generation_id = self.generation_id;
        self.generation_id = null;
        errdefer if (generation_id) |id| self.alloc.free(id);
        const owned_calls = try calls.toOwnedSlice(self.alloc);
        self.phase = .closed;
        return .{ .completed = .{
            .completion = .{ .content = content, .tool_calls = owned_calls, .generation_id = generation_id, .finish_reason = reason, .usage = self.usage },
            .ownership = .owned,
            .usage = .{ .unavailable = .possibly_billed },
        } };
    }
};

fn object(value: std.json.Value) Error!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidChunk;
}

fn string(value: std.json.Value) Error![]const u8 {
    return if (value == .string) value.string else error.InvalidChunk;
}

fn non_null(fields: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const value = fields.get(key) orelse return null;
    return if (value == .null) null else value;
}

fn index_value(value: std.json.Value) Error!usize {
    if (value != .integer) return error.InvalidChunk;
    return std.math.cast(usize, value.integer) orelse error.InvalidChunk;
}

fn token_count(fields: std.json.ObjectMap, key: []const u8) Error!?u64 {
    const value = non_null(fields, key) orelse return null;
    if (value != .integer) return error.InvalidChunk;
    return std.math.cast(u64, value.integer) orelse error.InvalidChunk;
}

fn append_bounded(alloc: Allocator, destination: *std.ArrayList(u8), text: []const u8, limit: usize, failure: Error) Error!void {
    if (text.len > limit - destination.items.len) return failure;
    try destination.appendSlice(alloc, text);
}

/// Thin stream consumer, not a network transport. The source owns blocking-I/O
/// cancellation. EventSink receives synchronous presentation-only text. Stops
/// exactly at framed [DONE], without waiting for EOF or consuming another event.
/// event_bytes also bounds all wire between dispatched data events (including
/// ignored fields/comments); total_wire_bytes bounds the entire consumed stream.
pub fn consume_stream(alloc: Allocator, source: *std.Io.Reader, request: stream_provider.RequestData, limits: Limits, events: ?stream_provider.EventSink, cancel_flag: *const std.atomic.Value(bool)) Error!stream_provider.Result {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var reducer = try Reducer.init(alloc, request, limits);
    defer reducer.deinit();
    var framing = sse.Reader{ .max_event_bytes = limits.event_bytes };
    defer framing.deinit(alloc);
    while (true) {
        const remaining = limits.total_wire_bytes - framing.total_bytes;
        const event_limited = limits.event_bytes < remaining;
        framing.max_total_bytes = framing.total_bytes + @min(limits.event_bytes, remaining);
        const data = framing.next(alloc, source, cancel_flag) catch |err| switch (err) {
            error.StreamTooLarge => return if (event_limited) error.EventTooLarge else error.StreamTooLarge,
            else => return err,
        };
        const chunk = data orelse return error.IncompleteStream;
        if (try reducer.accept(chunk, cancel_flag.load(.seq_cst))) |text| if (events) |sink| sink.emit(.{ .content_delta = text });
        if (reducer.phase == .done) return reducer.finish(cancel_flag.load(.seq_cst));
    }
}

const test_functions = [_]model_tool_schema.FunctionSchema{
    .{ .name = "read_file", .description = "Read a file.", .input_schema = .{
        .properties = &.{.{ .name = "path", .json_type = .string }},
        .required = &.{"path"},
        .additional_properties = false,
    } },
    .{ .name = "shell", .description = "Run a command.", .input_schema = .{
        .properties = &.{.{ .name = "request", .json_type = .object, .shape = &.{ .object = &.{
            .properties = &.{.{ .name = "command", .json_type = .string }},
            .required = &.{"command"},
        } } }},
    } },
};

fn test_request() stream_provider.RequestData {
    return .{
        .model = "opaque/local-model:8b",
        .instructions = &.{ .{ .role = .system, .content = "first" }, .{ .role = .system, .content = "second" } },
        .messages = &.{.{ .role = .user, .content = "hi" }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

fn test_tool_request() stream_provider.RequestData {
    var request = test_request();
    request.tools = .{ .advertised_names = &.{ "read_file", "shell" }, .advertised_functions = &test_functions };
    return request;
}

const test_stop = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}";
const test_tools_finish = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}";
const test_text = "{\"id\":\"chat-1\",\"model\":\"resolved-model\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":null}]}";
const test_call = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"x\\\"}\"}}]}}]}";

fn test_accept(reducer: *Reducer, data: []const u8) Error!void {
    _ = try reducer.accept(data, false);
}

fn test_finish(reducer: *Reducer, terminal: []const u8) Error!stream_provider.Result {
    try test_accept(reducer, terminal);
    try test_accept(reducer, "[DONE]");
    return reducer.finish(false);
}

test "chat completions exact text wire preserves instruction order and opaque model" {
    const alloc = std.testing.allocator;
    const body = try build_request(alloc, test_request(), .{});
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"model\":\"opaque/local-model:8b\",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[{\"role\":\"system\",\"content\":\"first\"},{\"role\":\"system\",\"content\":\"second\"},{\"role\":\"user\",\"content\":\"hi\"}]}", body);
    const again = try build_request(alloc, test_request(), .{});
    defer alloc.free(again);
    try std.testing.expectEqualStrings(body, again);
}

test "chat completions nested builtin additional and dynamic tool wire" {
    const alloc = std.testing.allocator;
    var dynamic_schema = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}", .{});
    defer dynamic_schema.deinit();
    var request = test_tool_request();
    request.tools.additional_functions = &.{.{ .name = "permission_decision", .description = "Decide." }};
    request.tools.selected_dynamic = &.{.{ .name = "mcp_docs", .description = "Find docs.", .input_schema = dynamic_schema.value }};
    const body = try build_request(alloc, request, .{});
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), tools.len);
    for (tools) |tool| {
        try std.testing.expectEqual(@as(u32, 2), tool.object.count());
        try std.testing.expectEqualStrings("function", tool.object.get("type").?.string);
        const function = tool.object.get("function").?.object;
        try std.testing.expectEqual(@as(u32, 3), function.count());
        try std.testing.expect(function.get("parameters").? == .object);
        try std.testing.expect(tool.object.get("inputSchema") == null);
    }
    const shell = tools[1].object.get("function").?.object;
    const nested = shell.get("parameters").?.object.get("properties").?.object.get("request").?.object;
    try std.testing.expectEqualStrings("command", nested.get("required").?.array.items[0].string);
    try std.testing.expectEqualStrings("mcp_docs", tools[3].object.get("function").?.object.get("name").?.string);
    var reducer = try Reducer.init(alloc, request, .{});
    defer reducer.deinit();
    try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"mcp-1\",\"function\":{\"name\":\"mcp_docs\",\"arguments\":\"{\\\"query\\\":\\\"zig\\\"}\"}}]}}]}");
    var result = try test_finish(&reducer, test_tools_finish);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("mcp_docs", result.completed.completion.tool_calls[0].name);
}

test "chat completions bounds dynamic schema traversal before serialization" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"items\":" ** 65 ++ "{}" ++ "}" ** 65, .{});
    defer parsed.deinit();
    var request = test_request();
    request.tools.selected_dynamic = &.{.{ .name = "deep", .description = "Deep schema.", .input_schema = parsed.value }};
    try std.testing.expectError(error.JsonTooDeep, build_request(alloc, request, .{}));

    var exhausted_nodes = SchemaBudget{ .nodes = 0 };
    try std.testing.expectError(error.InvalidToolSchema, validate_dynamic_schema(.null, 0, &exhausted_nodes));
    var exhausted_strings = SchemaBudget{ .string_bytes = 2 };
    try std.testing.expectError(error.InvalidToolSchema, validate_dynamic_schema(.{ .string = "abc" }, 0, &exhausted_strings));
    var budget: SchemaBudget = .{};
    try std.testing.expectError(error.InvalidToolSchema, validate_dynamic_schema(.{ .float = std.math.inf(f64) }, 0, &budget));
}

test "chat completions history correlation preserves canonical IDs and JSON strings" {
    const alloc = std.testing.allocator;
    const call: types.ToolCall = .{ .id = "functions/read:0", .name = "read_file", .arguments_json = "{\"path\":\"a\\\"b\"}" };
    var request = test_tool_request();
    request.messages = &.{
        .{ .role = .assistant, .content = "reading", .tool_calls = &.{call} },
        .{ .role = .tool, .tool_call_id = call.id, .tool_name = call.name, .content = "result" },
        .{ .role = .user, .content = "continue" },
    };
    const body = try build_request(alloc, request, .{});
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    const wire_call = messages[2].object.get("tool_calls").?.array.items[0].object;
    const wire_id = wire_call.get("id").?.string;
    try std.testing.expect(std.mem.startsWith(u8, wire_id, "fx_"));
    try std.testing.expectEqualStrings(wire_id, messages[3].object.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings(call.arguments_json, wire_call.get("function").?.object.get("arguments").?.string);
    try std.testing.expectEqualStrings("functions/read:0", call.id);
    try std.testing.expectEqualStrings(call.id, request.messages[1].tool_call_id.?);
}

test "chat completions tool choice controls and deliberate basic option mapping" {
    const alloc = std.testing.allocator;
    for ([_]types.ToolChoice{ .auto, .none, .required }) |choice| for ([_]ToolChoiceMode{ .omit, .send }) |mode| {
        var request = test_tool_request();
        request.tool_choice = choice;
        request.max_output_tokens = 73;
        request.provider_options.parallel_tool_calls = false;
        const body = try build_request(alloc, request, .{ .tool_choice_mode = mode });
        defer alloc.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer parsed.deinit();
        const fields = parsed.value.object;
        try std.testing.expectEqual(choice != .none, fields.get("tools") != null);
        try std.testing.expectEqual(mode == .send, fields.get("tool_choice") != null);
        if (mode == .send) try std.testing.expectEqualStrings(@tagName(choice), fields.get("tool_choice").?.string);
        try std.testing.expectEqual(@as(i64, 73), fields.get("max_tokens").?.integer);
        try std.testing.expect(!fields.get("parallel_tool_calls").?.bool);
        try std.testing.expect(fields.get("providerOptions") == null);
        try std.testing.expect(fields.get("max_completion_tokens") == null);
    };
    var request = test_request();
    request.tool_choice = .required;
    try std.testing.expectError(error.RequiredToolMissing, build_request(alloc, request, .{}));
    request = test_tool_request();
    request.tool_choice = .none;
    var none = try Reducer.init(alloc, request, .{});
    defer none.deinit();
    try std.testing.expectError(error.UnexpectedToolCall, none.accept(test_call, false));
    request.tool_choice = .required;
    var required = try Reducer.init(alloc, request, .{});
    defer required.deinit();
    try test_accept(&required, test_text);
    try std.testing.expectError(error.RequiredToolMissing, test_finish(&required, test_stop));
}

test "chat completions rejects unsupported requests and ambiguous selection" {
    const alloc = std.testing.allocator;
    var request = test_request();
    request.provider_options.reasoning = .auto;
    try std.testing.expectError(error.UnsupportedProviderOption, build_request(alloc, request, .{}));
    request.provider_options = .{ .fast = true };
    try std.testing.expectError(error.UnsupportedProviderOption, build_request(alloc, request, .{}));
    request.provider_options = .{ .prompt_caching = true };
    try std.testing.expectError(error.UnsupportedProviderOption, build_request(alloc, request, .{}));
    request = test_request();
    request.vision_mode = .optional;
    try std.testing.expectError(error.UnsupportedVision, build_request(alloc, request, .{}));
    request = test_request();
    request.response_format = .{ .name = "answer", .description = "", .schema = .null };
    try std.testing.expectError(error.UnsupportedResponseFormat, build_request(alloc, request, .{}));
    request = test_request();
    request.max_output_tokens = 0;
    try std.testing.expectError(error.InvalidOutputLimit, build_request(alloc, request, .{}));
    request = test_request();
    request.model = "";
    try std.testing.expectError(error.InvalidModel, build_request(alloc, request, .{}));
    request = test_request();
    request.messages = &.{.{ .role = .system, .content = "untrusted" }};
    try std.testing.expectError(error.InvalidProviderPrompt, build_request(alloc, request, .{}));
    request = test_tool_request();
    request.tools.advertised_names = &.{"provider_native_search"};
    try std.testing.expectError(error.InvalidToolSelection, build_request(alloc, request, .{}));
    request.tools.advertised_names = &.{ "read_file", "read_file" };
    try std.testing.expectError(error.InvalidToolSelection, build_request(alloc, request, .{}));
    request.tools.advertised_names = &.{"read_file"};
    request.tools.advertised_functions = &.{ test_functions[0], test_functions[0] };
    try std.testing.expectError(error.InvalidToolSelection, build_request(alloc, request, .{}));
    request = test_request();
    request.tools.additional_functions = &.{ test_functions[0], test_functions[0] };
    try std.testing.expectError(error.InvalidToolSelection, build_request(alloc, request, .{}));
}

test "chat completions rejects unmatched native malformed and duplicate history calls" {
    const alloc = std.testing.allocator;
    var request = test_request();
    var call: types.ToolCall = .{ .id = "call-1", .name = "read_file", .arguments_json = "{}" };
    var messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{call} },
        .{ .role = .tool, .tool_call_id = call.id, .content = "result" },
    };
    request.messages = &messages;
    messages[1].tool_call_id = "other";
    try std.testing.expectError(error.InvalidToolHistory, build_request(alloc, request, .{}));
    messages[1].tool_call_id = call.id;
    call.provenance = .provider_executed;
    messages[0].tool_calls = &.{call};
    try std.testing.expectError(error.UnsupportedToolProvenance, build_request(alloc, request, .{}));
    call.provenance = .fx_local;
    call.arguments_json = "[]";
    messages[0].tool_calls = &.{call};
    try std.testing.expectError(error.InvalidToolArguments, build_request(alloc, request, .{}));
    call.arguments_json = "{}";
    messages[0].tool_calls = &.{ call, call };
    try std.testing.expectError(error.InvalidToolHistory, build_request(alloc, request, .{}));
    messages[0].tool_calls = &.{call};
    messages[0].provider_replay = .{ .source = .{ .provider = .gateway, .model = "old" }, .parts_json = "[]" };
    try std.testing.expectError(error.UnsupportedReplay, build_request(alloc, request, .{}));
}

test "chat completions accepts matching empty terminal usage choices" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |with_tools| {
        var reducer = try Reducer.init(alloc, test_tool_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, if (with_tools) test_call else test_text);
        try test_accept(&reducer, if (with_tools) test_tools_finish else test_stop);
        const trailer = try std.fmt.allocPrint(alloc, "{{\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"\"}},\"finish_reason\":\"{s}\"}}],\"usage\":{{\"prompt_tokens\":16,\"completion_tokens\":6,\"total_tokens\":22}}}}", .{if (with_tools) "tool_calls" else "stop"});
        defer alloc.free(trailer);
        try std.testing.expect((try reducer.accept(trailer, false)) == null);
        try test_accept(&reducer, "[DONE]");
        var result = try reducer.finish(false);
        defer result.deinit(alloc);
        try std.testing.expectEqual(@as(?u64, 16), result.completed.completion.usage.input_tokens);
        try std.testing.expectEqual(@as(?u64, 6), result.completed.completion.usage.output_tokens);
        try std.testing.expectEqual(@as(usize, if (with_tools) 1 else 0), result.completed.completion.tool_calls.len);
        try std.testing.expectEqual(stream_provider.UsageUnavailable.possibly_billed, result.completed.usage.unavailable);
    }
}

test "chat completions terminal usage cannot introduce content tools or a different finish" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { delta: []const u8, reason: []const u8 }{
        .{ .delta = "{\"content\":\"late\"}", .reason = "stop" },
        .{ .delta = "{\"tool_calls\":[{}]}", .reason = "stop" },
        .{ .delta = "{\"refusal\":\"blocked\"}", .reason = "stop" },
        .{ .delta = "{\"reasoning\":\"late\"}", .reason = "stop" },
        .{ .delta = "{\"role\":\"user\"}", .reason = "stop" },
        .{ .delta = "{}", .reason = "tool_calls" },
    };
    for (cases) |case| {
        var reducer = try Reducer.init(alloc, test_tool_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, test_stop);
        const trailer = try std.fmt.allocPrint(alloc, "{{\"choices\":[{{\"index\":0,\"delta\":{s},\"finish_reason\":\"{s}\"}}],\"usage\":{{\"prompt_tokens\":16,\"completion_tokens\":6,\"total_tokens\":22}}}}", .{ case.delta, case.reason });
        defer alloc.free(trailer);
        try std.testing.expectError(error.InconsistentFinishReason, reducer.accept(trailer, false));
        try std.testing.expectError(error.StreamClosed, reducer.finish(false));
    }
    var reducer = try Reducer.init(alloc, test_request(), .{});
    defer reducer.deinit();
    try test_accept(&reducer, test_stop);
    try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}");
    try std.testing.expectError(error.IncompleteStream, reducer.finish(false));
}

test "chat completions repeated terminal choices reject invalid or conflicting usage" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { usage: []const u8, seed_usage: bool = false, expected: Error = error.InvalidChunk }{
        .{ .usage = "{\"prompt_tokens\":-1}" },
        .{ .usage = "{\"prompt_tokens\":1.5}" },
        .{ .usage = "{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":3}" },
        .{ .usage = "{\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3}", .seed_usage = true, .expected = error.ConflictingIdentity },
    };
    for (cases) |case| {
        var reducer = try Reducer.init(alloc, test_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, test_stop);
        if (case.seed_usage) try test_accept(&reducer, "{\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}");
        const trailer = try std.fmt.allocPrint(alloc, "{{\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}],\"usage\":{s}}}", .{case.usage});
        defer alloc.free(trailer);
        try std.testing.expectError(case.expected, reducer.accept(trailer, false));
        try std.testing.expectError(error.StreamClosed, reducer.finish(false));
    }
}

test "chat completions owns fragmented interleaved tools and results independently" {
    const alloc = std.testing.allocator;
    var reducer = try Reducer.init(alloc, test_tool_request(), .{});
    var result: stream_provider.Result = undefined;
    {
        defer reducer.deinit();
        const fragment = try alloc.dupe(u8, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call-2\",\"function\":{\"name\":\"sh\",\"arguments\":\"{\\\"request\\\":\"}},{\"index\":0,\"id\":\"call-1\",\"function\":{\"name\":\"read_\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}");
        defer alloc.free(fragment);
        try test_accept(&reducer, fragment);
        @memset(fragment, 'x');
        try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"file\",\"arguments\":\"\\\"a\\\"}\"}},{\"index\":1,\"function\":{\"name\":\"ell\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}}\"}}]}}]}");
        result = try test_finish(&reducer, test_tools_finish);
    }
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqual(@as(usize, 2), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call-1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("{\"request\":{\"command\":\"pwd\"}}", completion.tool_calls[1].arguments_json);
    try std.testing.expectEqual(types.ToolExecutionProvenance.fx_local, completion.tool_calls[1].provenance);
    try std.testing.expect(completion.billing == null);
    try std.testing.expectEqual(stream_provider.UsageUnavailable.possibly_billed, result.completed.usage.unavailable);
}

test "chat completions malformed and nonobject final arguments never become tools" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "", "{", "[]", "null", "3", "{}junk", "{\"x\":1,\"x\":2}" }) |arguments| {
        var reducer = try Reducer.init(alloc, test_tool_request(), .{});
        defer reducer.deinit();
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"function\":{\"name\":\"read_file\",\"arguments\":");
        try std.json.Stringify.value(arguments, .{}, &out.writer);
        try out.writer.writeAll("}}]}}]}");
        try test_accept(&reducer, out.written());
        try std.testing.expectError(error.InvalidToolArguments, test_finish(&reducer, test_tools_finish));
        try std.testing.expectError(error.StreamClosed, reducer.finish(false));
    }
}

test "chat completions terminal evidence and finish reasons are strict" {
    const alloc = std.testing.allocator;
    {
        var reducer = try Reducer.init(alloc, test_request(), .{});
        defer reducer.deinit();
        try std.testing.expectError(error.IncompleteStream, reducer.accept("[DONE]", false));
    }
    {
        var reducer = try Reducer.init(alloc, test_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, test_stop);
        try std.testing.expectError(error.IncompleteStream, reducer.finish(false));
    }
    for ([_]struct { reason: []const u8, failure: Error }{
        .{ .reason = "length", .failure = error.OutputTruncated },
        .{ .reason = "content_filter", .failure = error.ContentFiltered },
        .{ .reason = "stop", .failure = error.InconsistentFinishReason },
    }) |case| {
        var reducer = try Reducer.init(alloc, test_tool_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, test_call);
        const terminal = try std.fmt.allocPrint(alloc, "{{\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}]}}", .{case.reason});
        defer alloc.free(terminal);
        try std.testing.expectError(case.failure, test_finish(&reducer, terminal));
    }
    {
        var reducer = try Reducer.init(alloc, test_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{\"refusal\":\"No.\"},\"finish_reason\":\"stop\"}]}");
        try test_accept(&reducer, "[DONE]");
        try std.testing.expectError(error.Refused, reducer.finish(false));
    }
    {
        var reducer = try Reducer.init(alloc, test_tool_request(), .{});
        defer reducer.deinit();
        try std.testing.expectError(error.InconsistentFinishReason, test_finish(&reducer, test_tools_finish));
    }
}

test "chat completions rejects malformed chunks contradictory identities and extra choices" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { first: ?[]const u8 = null, chunk: []const u8, failure: Error }{
        .{ .chunk = "not JSON", .failure = error.InvalidChunk },
        .{ .chunk = "{\"choices\":[],\"choices\":[]}", .failure = error.InvalidChunk },
        .{ .chunk = "{\"error\":{\"message\":\"bad request\"}}", .failure = error.ProviderError },
        .{ .chunk = "{\"choices\":[{\"index\":1,\"delta\":{}}]}", .failure = error.InvalidChunk },
        .{ .chunk = "{\"choices\":[{\"index\":0,\"delta\":{}},{\"index\":1,\"delta\":{}}]}", .failure = error.InvalidChunk },
        .{ .chunk = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"unknown\"}]}", .failure = error.InvalidFinishReason },
        .{ .first = test_stop, .chunk = test_stop, .failure = error.InconsistentFinishReason },
        .{ .first = test_text, .chunk = "{\"id\":\"other\",\"choices\":[]}", .failure = error.ConflictingIdentity },
        .{ .first = test_text, .chunk = "{\"model\":\"other\",\"choices\":[]}", .failure = error.ConflictingIdentity },
        .{ .first = test_call, .chunk = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"other\"}]}}]}", .failure = error.ConflictingIdentity },
        .{ .first = test_call, .chunk = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"shell\"}}]}}]}", .failure = error.InvalidToolName },
        .{ .first = test_call, .chunk = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call-1\"}]}}]}", .failure = error.ConflictingIdentity },
        .{ .chunk = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":-1}]}}]}", .failure = error.InvalidChunk },
        .{ .chunk = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0},{\"index\":0}]}}]}", .failure = error.ConflictingIdentity },
        .{ .chunk = "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"web_search\"}]}}]}", .failure = error.InvalidChunk },
        .{ .chunk = "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"thinking\"}}]}", .failure = error.InvalidChunk },
    };
    for (cases) |case| {
        var reducer = try Reducer.init(alloc, test_tool_request(), .{});
        defer reducer.deinit();
        if (case.first) |first| try test_accept(&reducer, first);
        try std.testing.expectError(case.failure, reducer.accept(case.chunk, false));
        try std.testing.expectError(error.StreamClosed, reducer.accept(test_stop, false));
    }
}

test "chat completions usage trailers preserve observations without billing" {
    const alloc = std.testing.allocator;
    var reducer = try Reducer.init(alloc, test_request(), .{});
    defer reducer.deinit();
    try test_accept(&reducer, test_text);
    try test_accept(&reducer, test_stop);
    const usage = "{\"choices\":[],\"usage\":{\"prompt_tokens\":17,\"completion_tokens\":3,\"total_tokens\":20}}";
    try test_accept(&reducer, usage);
    try test_accept(&reducer, usage);
    try test_accept(&reducer, "[DONE]");
    var result = try reducer.finish(false);
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("hello", completion.content.?);
    try std.testing.expectEqualStrings("chat-1", completion.generation_id.?);
    try std.testing.expectEqual(@as(?u64, 17), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 3), completion.usage.output_tokens);
    try std.testing.expect(completion.billing == null);
    try std.testing.expectError(error.StreamClosed, reducer.finish(false));
    for ([_][]const u8{
        "{\"choices\":[],\"usage\":{\"prompt_tokens\":-1}}",
        "{\"choices\":[],\"usage\":{\"completion_tokens\":1.5}}",
        "{\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":8}}",
    }) |invalid| {
        var bad = try Reducer.init(alloc, test_request(), .{});
        defer bad.deinit();
        try test_accept(&bad, test_stop);
        try std.testing.expectError(error.InvalidChunk, bad.accept(invalid, false));
    }
}

test "chat completions stream framing handles chunks trailers truncation and wire caps" {
    const alloc = std.testing.allocator;
    const wire = "data: " ++ test_text ++ "\n\ndata: " ++ test_stop ++ "\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":1}}\n\ndata: [DONE]\n\n";
    const cancelled = std.atomic.Value(bool).init(false);
    for ([_]usize{ 1, 2, 7, 31, 1024 }) |size| {
        const buffer = try alloc.alloc(u8, size);
        defer alloc.free(buffer);
        var fixed = std.Io.Reader.fixed(wire);
        var source = fixed.limited(.unlimited, buffer);
        var result = try consume_stream(alloc, &source.interface, test_request(), .{}, null, &cancelled);
        defer result.deinit(alloc);
        try std.testing.expectEqualStrings("hello", result.completed.completion.content.?);
        try std.testing.expectEqual(@as(?u64, 5), result.completed.completion.usage.input_tokens);
    }
    for ([_][]const u8{ "", "data: [DONE]\n\n", "data: " ++ test_stop ++ "\n\n", "data: " ++ test_stop ++ "\n\ndata: [DONE]", "data: " ++ test_stop ++ "\n\ndata: [DONE]\n" }) |truncated| {
        var source = std.Io.Reader.fixed(truncated);
        try std.testing.expectError(error.IncompleteStream, consume_stream(alloc, &source, test_request(), .{}, null, &cancelled));
    }
    {
        var source = std.Io.Reader.fixed(": comment\n" ** 20);
        try std.testing.expectError(error.EventTooLarge, consume_stream(alloc, &source, test_request(), .{ .event_bytes = 30 }, null, &cancelled));
    }
    {
        var source = std.Io.Reader.fixed(": comment\n\n" ** 20);
        try std.testing.expectError(error.StreamTooLarge, consume_stream(alloc, &source, test_request(), .{ .total_wire_bytes = 30 }, null, &cancelled));
    }
    {
        var source = std.Io.Reader.fixed(wire);
        try std.testing.expectError(error.StreamTooLarge, consume_stream(alloc, &source, test_request(), .{ .total_wire_bytes = wire.len - 1 }, null, &cancelled));
    }
    // A terminal delimiter is sufficient: never wait for a failing next read.
    var source = std.Io.Reader.failing;
    source.buffer = @constCast(wire);
    source.end = wire.len;
    var result = try consume_stream(alloc, &source, test_request(), .{}, null, &cancelled);
    defer result.deinit(alloc);
}

test "chat completions reducer caps events content identities arguments tools and nesting" {
    const alloc = std.testing.allocator;
    for ([_]struct { limits: Limits, chunk: []const u8, failure: Error }{
        .{ .limits = .{ .event_bytes = 1 }, .chunk = test_text, .failure = error.EventTooLarge },
        .{ .limits = .{ .total_wire_bytes = 1 }, .chunk = test_text, .failure = error.StreamTooLarge },
        .{ .limits = .{ .events = 0 }, .chunk = test_text, .failure = error.TooManyEvents },
        .{ .limits = .{ .identity_bytes = 2 }, .chunk = test_text, .failure = error.IdentityTooLarge },
        .{ .limits = .{ .content_bytes = 4 }, .chunk = test_text, .failure = error.ContentTooLarge },
        .{ .limits = .{ .arguments_bytes = 2 }, .chunk = test_call, .failure = error.ArgumentsTooLarge },
        .{ .limits = .{ .tool_calls = 0 }, .chunk = test_call, .failure = error.TooManyTools },
        .{ .limits = .{}, .chunk = "[" ** 65 ++ "]" ** 65, .failure = error.JsonTooDeep },
    }) |case| {
        var reducer = try Reducer.init(alloc, test_tool_request(), case.limits);
        defer reducer.deinit();
        try std.testing.expectError(case.failure, reducer.accept(case.chunk, false));
    }
    var reducer = try Reducer.init(alloc, test_request(), .{ .content_bytes = 5, .events = 3 });
    defer reducer.deinit();
    try test_accept(&reducer, test_text);
    var result = try test_finish(&reducer, test_stop);
    defer result.deinit(alloc);
}

test "chat completions cancellation poisons retained state and progress cannot execute tools" {
    const alloc = std.testing.allocator;
    var reducer = try Reducer.init(alloc, test_tool_request(), .{});
    defer reducer.deinit();
    try test_accept(&reducer, test_call);
    try std.testing.expectError(error.Cancelled, reducer.accept(test_tools_finish, true));
    try std.testing.expectError(error.StreamClosed, reducer.finish(false));
    var cancelled = std.atomic.Value(bool).init(true);
    var source = std.Io.Reader.fixed("data: " ++ test_text ++ "\n\n");
    try std.testing.expectError(error.Cancelled, consume_stream(alloc, &source, test_request(), .{}, null, &cancelled));
    var request = test_request();
    request.budget = .{ .cancel_flag = &cancelled };
    const serialized = try build_request(alloc, request, .{});
    defer alloc.free(serialized);
    const Observer = struct {
        flag: *std.atomic.Value(bool),
        count: usize = 0,
        fn emit(context: *anyopaque, event: stream_provider.Event) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (event == .content_delta) self.count += 1;
            self.flag.store(true, .seq_cst);
        }
    };
    var observer = Observer{ .flag = &cancelled };
    cancelled.store(false, .seq_cst);
    source = std.Io.Reader.fixed("data: " ++ test_text ++ "\n\ndata: " ++ test_stop ++ "\n\ndata: [DONE]\n\n");
    try std.testing.expectError(error.Cancelled, consume_stream(alloc, &source, test_request(), .{}, .{ .context = &observer, .emit_fn = Observer.emit }, &cancelled));
    try std.testing.expectEqual(@as(usize, 1), observer.count);
}

fn test_allocation_paths(alloc: Allocator) !void {
    var request = test_tool_request();
    request.tool_choice = .required;
    const call: types.ToolCall = .{ .id = "functions/read:0", .name = "read_file", .arguments_json = "{\"path\":\"x\"}" };
    request.messages = &.{ .{ .role = .assistant, .tool_calls = &.{call} }, .{ .role = .tool, .tool_call_id = call.id, .content = "result" } };
    const body = try build_request(alloc, request, .{ .tool_choice_mode = .send });
    defer alloc.free(body);
    var source = std.Io.Reader.fixed("data: " ++ test_text ++ "\n\ndata: " ++ test_call ++ "\n\ndata: " ++ test_tools_finish ++ "\n\ndata: [DONE]\n\n");
    const cancelled = std.atomic.Value(bool).init(false);
    var result = try consume_stream(alloc, &source, request, .{}, null, &cancelled);
    defer result.deinit(alloc);
}

test "chat completions allocation failure cleanup covers serialization framing reduction and result transfer" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_allocation_paths, .{});
}

test "chat completions name fragments preserve repeated bytes and shared prefixes" {
    const alloc = std.testing.allocator;
    var request = test_request();
    request.tools.additional_functions = &.{
        .{ .name = "read", .description = "Read." },
        .{ .name = "read_file", .description = "Read file." },
        .{ .name = "aa", .description = "Repeated bytes." },
    };
    var reducer = try Reducer.init(alloc, request, .{});
    defer reducer.deinit();
    try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"one\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}},{\"index\":1,\"id\":\"two\",\"function\":{\"name\":\"a\",\"arguments\":\"{}\"}}]}}]}");
    try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"_file\"}},{\"index\":1,\"function\":{\"name\":\"a\"}}]}}]}");
    var result = try test_finish(&reducer, test_tools_finish);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("read_file", result.completed.completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("aa", result.completed.completion.tool_calls[1].name);
}

test "chat completions accepts empty name fragments without losing arguments" {
    const alloc = std.testing.allocator;
    var reducer = try Reducer.init(alloc, test_tool_request(), .{});
    defer reducer.deinit();
    try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\"}}]}}]}");
    try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"\",\"arguments\":\"\\\"path\\\":\\\"x\\\"}\"}}]}}]}");
    var result = try test_finish(&reducer, test_tools_finish);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("read_file", result.completed.completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", result.completed.completion.tool_calls[0].arguments_json);
}

test "chat completions accepts echoed models up to the request model limit" {
    const alloc = std.testing.allocator;
    var request = test_request();
    request.model = "m" ** configured_provider.max_model_bytes;
    const body = try build_request(alloc, request, .{});
    defer alloc.free(body);
    var reducer = try Reducer.init(alloc, request, .{});
    defer reducer.deinit();
    const chunk = try std.fmt.allocPrint(alloc, "{{\"model\":\"{s}\",\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"ok\"}},\"finish_reason\":\"stop\"}}]}}", .{request.model});
    defer alloc.free(chunk);
    try test_accept(&reducer, chunk);
    try test_accept(&reducer, "[DONE]");
    var result = try reducer.finish(false);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("ok", result.completed.completion.content.?);
}

test "chat completions model bounds and serializer ignore external cancellation state" {
    const alloc = std.testing.allocator;
    var request = test_request();
    for ([_][]const u8{ " leading", "trailing ", "bad\xff", "m" ** (configured_provider.max_model_bytes + 1) }) |invalid| {
        request.model = invalid;
        try std.testing.expectError(error.InvalidModel, build_request(alloc, request, .{}));
    }
    request.model = "m" ** configured_provider.max_model_bytes;
    var cancelled = std.atomic.Value(bool).init(false);
    request.budget = .{ .cancel_flag = &cancelled };
    const before = try build_request(alloc, request, .{});
    defer alloc.free(before);
    cancelled.store(true, .seq_cst);
    const after = try build_request(alloc, request, .{});
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "chat completions missing tool fields sparse indexes and invalid identities fail closed" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { delta: []const u8, failure: Error, at_finish: bool = false }{
        .{ .delta = "{\"index\":0,\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}", .failure = error.InvalidToolCallId, .at_finish = true },
        .{ .delta = "{\"index\":0,\"id\":\"x\",\"function\":{\"arguments\":\"{}\"}}", .failure = error.InvalidToolName, .at_finish = true },
        .{ .delta = "{\"index\":0,\"id\":\"x\",\"function\":{\"name\":\"read_file\"}}", .failure = error.InvalidToolArguments, .at_finish = true },
        .{ .delta = "{\"index\":1,\"id\":\"x\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}", .failure = error.InvalidToolCallId, .at_finish = true },
        .{ .delta = "{\"index\":0,\"id\":\"\"}", .failure = error.InvalidChunk },
        .{ .delta = "{\"index\":0,\"id\":7}", .failure = error.InvalidChunk },
        .{ .delta = "{\"index\":0,\"function\":{\"name\":\"not_advertised\"}}", .failure = error.InvalidToolName },
        .{ .delta = "{\"index\":0,\"function\":{\"name\":3}}", .failure = error.InvalidChunk },
        .{ .delta = "{\"index\":0,\"function\":{\"arguments\":{}}}", .failure = error.InvalidChunk },
        .{ .delta = "{\"index\":999999999}", .failure = error.TooManyTools },
    };
    for (cases) |case| {
        var reducer = try Reducer.init(alloc, test_tool_request(), .{});
        defer reducer.deinit();
        const chunk = try std.mem.concat(alloc, u8, &.{ "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[", case.delta, "]}}]}" });
        defer alloc.free(chunk);
        if (case.at_finish) {
            try test_accept(&reducer, chunk);
            try std.testing.expectError(case.failure, test_finish(&reducer, test_tools_finish));
        } else try std.testing.expectError(case.failure, reducer.accept(chunk, false));
    }
}

test "chat completions repeated consistent identity preserves one call and selected names are owned" {
    const alloc = std.testing.allocator;
    var request = test_request();
    const name = try alloc.dupe(u8, "read_file");
    defer alloc.free(name);
    const function: model_tool_schema.FunctionSchema = .{ .name = name, .description = "Read." };
    request.tools.additional_functions = &.{function};
    var reducer = try Reducer.init(alloc, request, .{});
    defer reducer.deinit();
    @memset(name, 'x');
    try test_accept(&reducer, test_call);
    try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"arguments\":\"\"}}]}}]}");
    var result = try test_finish(&reducer, test_tools_finish);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), result.completed.completion.tool_calls.len);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", result.completed.completion.tool_calls[0].arguments_json);
}

test "chat completions usage conflicts late errors and post terminal data cannot succeed" {
    const alloc = std.testing.allocator;
    {
        var reducer = try Reducer.init(alloc, test_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, test_stop);
        try test_accept(&reducer, "{\"choices\":[],\"usage\":{\"prompt_tokens\":1}}");
        try std.testing.expectError(error.ConflictingIdentity, reducer.accept("{\"choices\":[],\"usage\":{\"prompt_tokens\":2}}", false));
    }
    {
        var reducer = try Reducer.init(alloc, test_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, test_stop);
        try std.testing.expectError(error.ProviderError, reducer.accept("{\"error\":{\"message\":\"late error\"}}", false));
    }
    {
        var reducer = try Reducer.init(alloc, test_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, test_stop);
        try std.testing.expectError(error.InconsistentFinishReason, reducer.accept(test_text, false));
    }
    {
        var reducer = try Reducer.init(alloc, test_request(), .{});
        defer reducer.deinit();
        try test_accept(&reducer, test_stop);
        try test_accept(&reducer, "[DONE]");
        try std.testing.expectError(error.StreamClosed, reducer.accept("[DONE]", false));
        try std.testing.expectError(error.StreamClosed, reducer.finish(false));
    }
}

test "chat completions exact wire and aggregate delta bounds include the terminal marker" {
    const alloc = std.testing.allocator;
    const wire = "data: " ++ test_text ++ "\n\ndata: " ++ test_stop ++ "\n\ndata: [DONE]\n\n";
    const cancelled = std.atomic.Value(bool).init(false);
    var source = std.Io.Reader.fixed(wire);
    var result = try consume_stream(alloc, &source, test_request(), .{ .total_wire_bytes = wire.len }, null, &cancelled);
    defer result.deinit(alloc);
    for ([_]struct { limits: Limits, failure: Error }{
        .{ .limits = .{ .total_wire_bytes = test_text.len }, .failure = error.StreamTooLarge },
        .{ .limits = .{ .events = 1 }, .failure = error.TooManyEvents },
        .{ .limits = .{ .content_bytes = 9 }, .failure = error.ContentTooLarge },
    }) |case| {
        var reducer = try Reducer.init(alloc, test_request(), case.limits);
        defer reducer.deinit();
        try test_accept(&reducer, test_text);
        try std.testing.expectError(case.failure, reducer.accept(test_text, false));
    }
    var reducer = try Reducer.init(alloc, test_tool_request(), .{ .arguments_bytes = 12 });
    defer reducer.deinit();
    try test_accept(&reducer, test_call);
    try std.testing.expectError(error.ArgumentsTooLarge, reducer.accept("{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\" \"}}]}}]}", false));
}

test "chat completions prose resembling a call stays prose and cancellation after DONE wins" {
    const alloc = std.testing.allocator;
    var reducer = try Reducer.init(alloc, test_tool_request(), .{});
    defer reducer.deinit();
    try test_accept(&reducer, "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"{\\\"name\\\":\\\"shell\\\",\\\"arguments\\\":{}}\"}}]}");
    var result = try test_finish(&reducer, test_stop);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), result.completed.completion.tool_calls.len);
    try std.testing.expectEqualStrings("{\"name\":\"shell\",\"arguments\":{}}", result.completed.completion.content.?);
    var cancelled = try Reducer.init(alloc, test_request(), .{});
    defer cancelled.deinit();
    try test_accept(&cancelled, test_stop);
    try test_accept(&cancelled, "[DONE]");
    try std.testing.expectError(error.Cancelled, cancelled.finish(true));
}
