const std = @import("std");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const json_number = @import("../json_number.zig");
const mcp_contract = @import("../mcp_contract.zig");
const mrtr = @import("../mrtr.zig");
const mem_utils = @import("../../shared/mem_utils.zig");

const Allocator = std.mem.Allocator;

pub const Protocol = enum { legacy, modern };

pub const Limits = struct {
    max_pages: usize = 64,
    max_tools: usize = 2048,
    max_cursor_bytes: usize = 4096,
    max_name_bytes: usize = 256,
    max_title_bytes: usize = 4096,
    max_description_bytes: usize = 64 * 1024,
    max_icons: usize = 16,
    max_icon_sizes: usize = 16,
    max_metadata_bytes: usize = 128 * 1024,
    max_content_items: usize = 256,
    max_content_field_bytes: usize = 1024 * 1024,
    /// A text item, or a resource's text, may be as large as the whole
    /// result: fx stores or cuts a big result itself.
    max_content_text_bytes: usize = @import("../../images/image_data.zig").max_result_frame_bytes,
    max_image_bytes: usize = @import("../../images/image_data.zig").max_encoded_image_bytes,
    max_input_requests: usize = 32,
    max_request_state_bytes: usize = 64 * 1024,
    max_schema_bytes: usize = 256 * 1024,
    max_argument_bytes: usize = 1024 * 1024,
};

pub const Error = error{
    InvalidEnvelope,
    ProtocolFailure,
    InvalidListResult,
    InvalidTool,
    DuplicateTool,
    DuplicateCursor,
    InconsistentCacheScope,
    PaginationLimitExceeded,
    ToolLimitExceeded,
    InvalidCallResult,
    UnsupportedResultType,
    InvalidContent,
    InvalidSchema,
    UnsupportedDialect,
    SchemaLimitExceeded,
    InstanceLimitExceeded,
    InvalidJson,
    InvalidInputRequired,
    MetadataLimitExceeded,
} || mrtr.Error || Allocator.Error || std.Io.Writer.Error;

pub const Tool = struct {
    name: []u8,
    title: ?[]u8 = null,
    description: []u8,
    input_schema_json: []u8,
    output_schema_json: ?[]u8 = null,
    icons_json: ?[]u8 = null,
    annotations_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,

    pub fn deinit(self: *Tool, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        alloc.free(self.description);
        alloc.free(self.input_schema_json);
        if (self.output_schema_json) |value| alloc.free(value);
        if (self.icons_json) |value| alloc.free(value);
        if (self.annotations_json) |value| alloc.free(value);
        if (self.metadata_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const ProtocolError = struct {
    code: i64,
    message: []u8,
    data_json: ?[]u8 = null,

    pub fn deinit(self: *ProtocolError, alloc: Allocator) void {
        alloc.free(self.message);
        if (self.data_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const InputRequest = mrtr.InputRequest;
pub const InputRequired = mrtr.InputRequired;

pub const CompleteResult = struct {
    result_json: []u8,
    is_error: bool,

    pub fn deinit(self: *CompleteResult, alloc: Allocator) void {
        alloc.free(self.result_json);
        self.* = undefined;
    }
};

pub const CallOutcome = union(enum) {
    complete: CompleteResult,
    input_required: InputRequired,
    protocol_failure: ProtocolError,

    pub fn deinit(self: *CallOutcome, alloc: Allocator) void {
        switch (self.*) {
            .complete => |*value| value.deinit(alloc),
            .input_required => |*value| value.deinit(alloc),
            .protocol_failure => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub fn parseCallOutcome(
    alloc: Allocator,
    response: []const u8,
    protocol: Protocol,
    output_schema_json: ?[]const u8,
    max_result_bytes: usize,
    limits: Limits,
) Error!CallOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvelope,
    };
    defer parsed.deinit();
    mcp_contract.validateJsonRpcResponseEnvelope(parsed.value) catch
        return error.InvalidEnvelope;
    if (parsed.value.object.get("error")) |protocol_error| {
        return .{ .protocol_failure = try parseProtocolError(alloc, protocol_error, limits) };
    }
    const result = parsed.value.object.get("result") orelse return error.InvalidCallResult;
    if (result != .object) return error.InvalidCallResult;
    const result_type = result.object.get("resultType");
    if (result_type) |value| {
        if (value != .string) return error.InvalidCallResult;
        if (std.mem.eql(u8, value.string, "input_required")) {
            if (protocol != .modern) return error.UnsupportedResultType;
            return .{ .input_required = try mrtr.parseInputRequired(
                alloc,
                result,
                mrtrLimits(limits),
            ) };
        }
        if (!std.mem.eql(u8, value.string, "complete")) return error.UnsupportedResultType;
    }

    const content = result.object.get("content") orelse return error.InvalidCallResult;
    if (content != .array or content.array.items.len > limits.max_content_items) {
        return error.InvalidContent;
    }
    for (content.array.items) |item| try validateContentItem(alloc, item, limits);

    const is_error = if (result.object.get("isError")) |value| blk: {
        if (value != .bool) return error.InvalidCallResult;
        break :blk value.bool;
    } else false;
    _ = output_schema_json; // Tool semantics, including output assertions, belong to the server.
    const serialization_limit = std.math.add(usize, max_result_bytes, 16 * 1024) catch
        return error.MetadataLimitExceeded;
    const result_json = try stringifyValueAlloc(alloc, result, serialization_limit);
    return .{ .complete = .{
        .result_json = result_json,
        .is_error = is_error,
    } };
}

/// Check the wire boundary only. The server owns its tool's semantic assertions.
pub fn validateArguments(alloc: Allocator, arguments_json: []const u8, limits: Limits) Error!void {
    if (arguments_json.len > limits.max_argument_bytes) return error.InstanceLimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{ .parse_numbers = false }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidJson;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    var remaining: usize = 4096;
    checkValueBounds(parsed.value, 0, &remaining) catch return error.InstanceLimitExceeded;
}

fn checkValueBounds(value: std.json.Value, depth: usize, remaining: *usize) error{SchemaLimitExceeded}!void {
    if (depth > 64 or remaining.* == 0) return error.SchemaLimitExceeded;
    remaining.* -= 1;
    switch (value) {
        .array => |array| for (array.items) |item| {
            try checkValueBounds(item, depth + 1, remaining);
        },
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| try checkValueBounds(entry.value_ptr.*, depth + 1, remaining);
        },
        else => {},
    }
}

fn prepareSchema(schema: std.json.Value, object_root: bool) Error!void {
    if (schema != .object) return error.InvalidSchema;
    if (object_root) {
        const kind = schema.object.get("type") orelse return error.InvalidSchema;
        if (kind != .string or !std.mem.eql(u8, kind.string, "object")) return error.InvalidSchema;
    }
    if (schema.object.get("$schema")) |dialect| {
        if (dialect != .string) return error.InvalidSchema;
        const uri = std.mem.trimEnd(u8, dialect.string, "#");
        if (!std.mem.eql(u8, uri, "https://json-schema.org/draft/2020-12/schema") and
            !std.mem.eql(u8, uri, "http://json-schema.org/draft-07/schema")) return error.UnsupportedDialect;
    }
    var remaining: usize = 4096;
    try checkValueBounds(schema, 0, &remaining);
}

/// Parses one tool object from a `tools/list` result, with the same checks a
/// listed page applies. The caller owns the tool.
pub fn parseToolJson(alloc: Allocator, json: []const u8, limits: Limits) Error!Tool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTool,
    };
    defer parsed.deinit();
    return parseTool(alloc, parsed.value, limits);
}

fn parseTool(alloc: Allocator, value: std.json.Value, limits: Limits) Error!Tool {
    if (value != .object) return error.InvalidTool;
    const name_value = value.object.get("name") orelse return error.InvalidTool;
    if (name_value != .string or name_value.string.len == 0 or name_value.string.len > limits.max_name_bytes) {
        return error.InvalidTool;
    }
    const description_value = value.object.get("description");
    if (description_value) |description| {
        if (description != .string or description.string.len > limits.max_description_bytes) return error.InvalidTool;
    }
    const title_value = value.object.get("title");
    if (title_value) |title| {
        if (title != .string or title.string.len > limits.max_title_bytes) return error.InvalidTool;
    }
    const input_schema = value.object.get("inputSchema") orelse return error.InvalidTool;
    try prepareSchema(input_schema, true);
    if (value.object.get("outputSchema")) |output_schema| {
        try prepareSchema(output_schema, false);
    }
    if (value.object.get("icons")) |icons| try validateIcons(icons, limits);
    if (value.object.get("annotations")) |annotations| try validateToolAnnotations(annotations, limits);
    if (value.object.get("_meta")) |metadata| if (metadata != .object) return error.InvalidTool;

    const name = try alloc.dupe(u8, name_value.string);
    errdefer mem_utils.free(alloc, name);
    const title = if (title_value) |title| try alloc.dupe(u8, title.string) else null;
    errdefer if (title) |owned| mem_utils.free(alloc, owned);
    const description = try alloc.dupe(u8, if (description_value) |description| description.string else "");
    errdefer mem_utils.free(alloc, description);
    const input_schema_json = try stringifyValueAlloc(alloc, input_schema, limits.max_schema_bytes);
    errdefer mem_utils.free(alloc, input_schema_json);
    const output_schema_json = if (value.object.get("outputSchema")) |output_schema|
        try stringifyValueAlloc(alloc, output_schema, limits.max_schema_bytes)
    else
        null;
    errdefer if (output_schema_json) |owned| mem_utils.free(alloc, owned);
    const icons_json = if (value.object.get("icons")) |icons|
        try stringifyValueAlloc(alloc, icons, limits.max_metadata_bytes)
    else
        null;
    errdefer if (icons_json) |owned| mem_utils.free(alloc, owned);
    const annotations_json = if (value.object.get("annotations")) |annotations|
        try stringifyValueAlloc(alloc, annotations, limits.max_metadata_bytes)
    else
        null;
    errdefer if (annotations_json) |owned| mem_utils.free(alloc, owned);
    const metadata_json = if (value.object.get("_meta")) |metadata|
        try stringifyValueAlloc(alloc, metadata, limits.max_metadata_bytes)
    else
        null;
    errdefer if (metadata_json) |owned| mem_utils.free(alloc, owned);
    return .{
        .name = name,
        .title = title,
        .description = description,
        .input_schema_json = input_schema_json,
        .output_schema_json = output_schema_json,
        .icons_json = icons_json,
        .annotations_json = annotations_json,
        .metadata_json = metadata_json,
    };
}

fn parseProtocolError(alloc: Allocator, value: std.json.Value, limits: Limits) Error!ProtocolError {
    if (value != .object) return error.InvalidEnvelope;
    const code = value.object.get("code") orelse return error.InvalidEnvelope;
    const message = value.object.get("message") orelse return error.InvalidEnvelope;
    const parsed_code: i64 = switch (code) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch
            return error.InvalidEnvelope,
        else => return error.InvalidEnvelope,
    };
    if (message != .string or message.string.len > limits.max_description_bytes) {
        return error.InvalidEnvelope;
    }
    const owned_message = try alloc.dupe(u8, message.string);
    errdefer mem_utils.free(alloc, owned_message);
    const data_json = if (value.object.get("data")) |data|
        try stringifyValueAlloc(alloc, data, limits.max_metadata_bytes)
    else
        null;
    return .{ .code = parsed_code, .message = owned_message, .data_json = data_json };
}

fn validateContentItem(alloc: Allocator, value: std.json.Value, limits: Limits) Error!void {
    if (value != .object) return error.InvalidContent;
    const type_value = value.object.get("type") orelse return error.InvalidContent;
    if (type_value != .string) return error.InvalidContent;
    if (value.object.get("annotations")) |annotations| try validateAnnotations(annotations, limits);
    if (value.object.get("_meta")) |metadata| {
        if (metadata != .object) return error.InvalidContent;
        _ = try boundedJsonLength(metadata, limits.max_metadata_bytes);
    }
    if (std.mem.eql(u8, type_value.string, "text")) {
        _ = try requireBoundedString(value.object, "text", limits.max_content_text_bytes);
        return;
    }
    if (std.mem.eql(u8, type_value.string, "image") or std.mem.eql(u8, type_value.string, "audio")) {
        const data = try requireBoundedString(value.object, "data", if (std.mem.eql(u8, type_value.string, "image")) limits.max_image_bytes else limits.max_content_field_bytes);
        _ = try requireBoundedString(value.object, "mimeType", limits.max_title_bytes);
        if (!try validBase64(alloc, data)) return error.InvalidContent;
        return;
    }
    if (std.mem.eql(u8, type_value.string, "resource_link")) {
        try validateResourceLink(alloc, value.object, limits);
        return;
    }
    if (std.mem.eql(u8, type_value.string, "resource")) {
        const resource = value.object.get("resource") orelse return error.InvalidContent;
        try validateEmbeddedResource(alloc, resource, limits);
        return;
    }
    return error.InvalidContent;
}

fn mrtrLimits(limits: Limits) mrtr.Limits {
    return .{
        .max_requests = limits.max_input_requests,
        .max_name_bytes = limits.max_name_bytes,
        .max_json_bytes = limits.max_metadata_bytes,
        .max_string_bytes = limits.max_request_state_bytes,
        .max_collection_items = limits.max_content_items,
    };
}

fn validateResourceLink(alloc: Allocator, object: std.json.ObjectMap, limits: Limits) Error!void {
    _ = try requireBoundedString(object, "uri", limits.max_content_field_bytes);
    _ = try requireBoundedString(object, "name", limits.max_title_bytes);
    try optionalBoundedString(object, "title", limits.max_title_bytes);
    try optionalBoundedString(object, "description", limits.max_description_bytes);
    try optionalBoundedString(object, "mimeType", limits.max_title_bytes);
    if (object.get("icons")) |icons| try validateIcons(icons, limits);
    if (object.get("size")) |size| _ = nonNegativeU64(alloc, size) orelse return error.InvalidContent;
}

fn validateEmbeddedResource(alloc: Allocator, value: std.json.Value, limits: Limits) Error!void {
    if (value != .object) return error.InvalidContent;
    _ = try requireBoundedString(value.object, "uri", limits.max_content_field_bytes);
    try optionalBoundedString(value.object, "mimeType", limits.max_title_bytes);
    if (value.object.get("_meta")) |metadata| {
        if (metadata != .object) return error.InvalidContent;
        _ = try boundedJsonLength(metadata, limits.max_metadata_bytes);
    }
    const text = value.object.get("text");
    const blob = value.object.get("blob");
    if ((text == null) == (blob == null)) return error.InvalidContent;
    if (text) |content| {
        if (content != .string or content.string.len > limits.max_content_text_bytes) {
            return error.InvalidContent;
        }
    }
    if (blob) |content| {
        if (content != .string or content.string.len > limits.max_content_field_bytes or
            !try validBase64(alloc, content.string))
        {
            return error.InvalidContent;
        }
    }
}

fn validateIcons(value: std.json.Value, limits: Limits) Error!void {
    if (value != .array or value.array.items.len > limits.max_icons) return error.InvalidTool;
    for (value.array.items) |icon| {
        if (icon != .object) return error.InvalidTool;
        _ = requireBoundedString(icon.object, "src", limits.max_content_field_bytes) catch return error.InvalidTool;
        optionalBoundedString(icon.object, "mimeType", limits.max_title_bytes) catch return error.InvalidTool;
        if (icon.object.get("sizes")) |sizes| {
            if (sizes != .array or sizes.array.items.len > limits.max_icon_sizes) return error.InvalidTool;
            for (sizes.array.items) |size| {
                if (size != .string or size.string.len > limits.max_title_bytes) return error.InvalidTool;
            }
        }
        if (icon.object.get("theme")) |theme| {
            if (theme != .string or
                (!std.mem.eql(u8, theme.string, "light") and !std.mem.eql(u8, theme.string, "dark")))
            {
                return error.InvalidTool;
            }
        }
    }
}

fn validateToolAnnotations(value: std.json.Value, limits: Limits) Error!void {
    if (value != .object) return error.InvalidTool;
    optionalBoundedString(value.object, "title", limits.max_title_bytes) catch return error.InvalidTool;
    const booleans = [_][]const u8{ "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint" };
    for (booleans) |name| if (value.object.get(name)) |hint| if (hint != .bool) return error.InvalidTool;
    _ = try boundedJsonLength(value, limits.max_metadata_bytes);
}

fn validateAnnotations(value: std.json.Value, limits: Limits) Error!void {
    if (value != .object) return error.InvalidContent;
    if (value.object.get("audience")) |audience| {
        if (audience != .array or audience.array.items.len > 2) return error.InvalidContent;
        for (audience.array.items) |role| {
            if (role != .string or
                (!std.mem.eql(u8, role.string, "user") and !std.mem.eql(u8, role.string, "assistant")))
            {
                return error.InvalidContent;
            }
        }
    }
    if (value.object.get("priority")) |priority| {
        const number = jsonNumber(priority) orelse return error.InvalidContent;
        if (number < 0 or number > 1) return error.InvalidContent;
    }
    try optionalBoundedString(value.object, "lastModified", limits.max_title_bytes);
    _ = try boundedJsonLength(value, limits.max_metadata_bytes);
}

fn requireBoundedString(object: std.json.ObjectMap, name: []const u8, max_bytes: usize) Error![]const u8 {
    const value = object.get(name) orelse return error.InvalidContent;
    if (value != .string or value.string.len > max_bytes) return error.InvalidContent;
    return value.string;
}

fn optionalBoundedString(object: std.json.ObjectMap, name: []const u8, max_bytes: usize) Error!void {
    if (object.get(name)) |value| {
        if (value != .string or value.string.len > max_bytes) return error.InvalidContent;
    }
}

fn boundedJsonLength(value: std.json.Value, max_bytes: usize) Error!usize {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    std.json.Stringify.value(value, .{}, &counter.writer) catch return error.MetadataLimitExceeded;
    if (counter.fullCount() > max_bytes) return error.MetadataLimitExceeded;
    return @intCast(counter.fullCount());
}

fn stringifyValueAlloc(alloc: Allocator, value: std.json.Value, max_bytes: usize) Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    std.json.Stringify.value(value, .{}, &output.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    if (output.writer.buffered().len > max_bytes) return error.MetadataLimitExceeded;
    return try output.toOwnedSlice();
}

fn validBase64(alloc: Allocator, value: []const u8) Error!bool {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(value) catch return false;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, value) catch return false;
    return true;
}

fn nonNegativeU64(alloc: Allocator, value: std.json.Value) ?u64 {
    const parsed = json_number.fromValue(alloc, value, .{}) catch return null;
    if (parsed == null) return null;
    var number = parsed.?;
    defer number.deinit(alloc);
    const result = number.toNonNegativeUsize() orelse return null;
    return std.math.cast(u64, result);
}

fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| if (std.math.isFinite(number)) number else null,
        .number_string => |number| std.fmt.parseFloat(f64, number) catch null,
        else => null,
    };
}

fn checkToolParsingAllocationFailures(alloc: Allocator) !void {
    var tool = try parseToolJson(
        alloc,
        \\{"name":"echo","title":"Echo","description":"Echo input","icons":[{"src":"data:image/png;base64,AA=="}],"annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]},"outputSchema":{"type":"object"},"_meta":{"vendor":"test"}}
    ,
        .{},
    );
    defer tool.deinit(alloc);
    var outcome = try parseCallOutcome(
        alloc,
        \\{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"image","data":"AA==","mimeType":"image/png"}],"structuredContent":{}}}
    ,
        .modern,
        tool.output_schema_json,
        64 * 1024,
        .{},
    );
    defer outcome.deinit(alloc);
}

test "tool protocol parsing releases every allocation failure path" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkToolParsingAllocationFailures,
        .{},
    );
}

test "MCP tool call results preserve content types errors and server output" {
    const alloc = std.testing.allocator;
    var outcome = try parseCallOutcome(
        alloc,
        \\{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","content":[{"type":"text","text":"ok"},{"type":"image","data":"AA==","mimeType":"image/png"},{"type":"audio","data":"AA==","mimeType":"audio/wav"},{"type":"resource_link","uri":"file:///a","name":"a"},{"type":"resource","resource":{"uri":"file:///b","text":"body"}},{"type":"resource","resource":{"uri":"file:///c","blob":"AA=="}}],"structuredContent":[1,2],"isError":false}}
    ,
        .modern,
        \\{"type":"array","items":{"type":"integer"}}
    ,
        64 * 1024,
        .{},
    );
    defer outcome.deinit(alloc);
    try std.testing.expect(!outcome.complete.is_error);
    try std.testing.expect(std.mem.find(u8, outcome.complete.result_json, "resource_link") != null);

    var error_outcome = try parseCallOutcome(
        alloc,
        \\{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"No active project"}],"isError":true}}
    ,
        .legacy,
        \\{"type":"object","properties":{"result":{"type":"string"}},"required":["result"]}
    ,
        64 * 1024,
        .{},
    );
    defer error_outcome.deinit(alloc);
    try std.testing.expect(error_outcome.complete.is_error);
    try std.testing.expect(std.mem.find(
        u8,
        error_outcome.complete.result_json,
        "No active project",
    ) != null);

    var different_output = try parseCallOutcome(alloc,
        \\{"jsonrpc":"2.0","id":3,"result":{"content":[],"structuredContent":"server result"}}
    , .modern, "{\"type\":\"array\"}", 64 * 1024, .{});
    defer different_output.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, different_output.complete.result_json, "server result") != null);
}

test "tool argument boundary leaves semantic validation to the server" {
    try validateArguments(std.testing.allocator, "{\"email\":42,\"optional_header\":null}", .{});
    try std.testing.expectError(error.InvalidJson, validateArguments(std.testing.allocator, "[]", .{}));
    try std.testing.expectError(error.InvalidJson, validateArguments(std.testing.allocator, "{", .{}));
    try std.testing.expectError(error.InstanceLimitExceeded, validateArguments(std.testing.allocator, "{}", .{ .max_argument_bytes = 1 }));
}

test "tool call content rejects malformed payloads and enforces item limits" {
    const alloc = std.testing.allocator;
    const malformed = [_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text"}]}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"image","data":"A..A","mimeType":"image/png"}]}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"audio","data":"AA=="}]}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"resource_link","uri":"file:///a"}]}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"resource","resource":{"uri":"file:///a","text":"x","blob":"AA=="}}]}}
        ,
    };
    for (malformed) |response| {
        try std.testing.expectError(
            error.InvalidContent,
            parseCallOutcome(alloc, response, .modern, null, 64 * 1024, .{}),
        );
    }
    try std.testing.expectError(
        error.InvalidContent,
        parseCallOutcome(
            alloc,
            \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}
        ,
            .modern,
            null,
            64 * 1024,
            .{ .max_content_items = 1 },
        ),
    );
}

test "tool call outcomes distinguish protocol tool and MRTR results" {
    const alloc = std.testing.allocator;
    var protocol_failure = try parseCallOutcome(
        alloc,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad args","data":{"field":"x"}}}
    ,
        .modern,
        null,
        4096,
        .{},
    );
    defer protocol_failure.deinit(alloc);
    try std.testing.expectEqual(@as(i64, -32602), protocol_failure.protocol_failure.code);

    var tool_failure = try parseCallOutcome(
        alloc,
        \\{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"try again"}],"isError":true}}
    ,
        .modern,
        null,
        4096,
        .{},
    );
    defer tool_failure.deinit(alloc);
    try std.testing.expect(tool_failure.complete.is_error);

    var input_required = try parseCallOutcome(
        alloc,
        \\{"jsonrpc":"2.0","id":3,"result":{"resultType":"input_required","inputRequests":{"confirm":{"method":"elicitation/create","params":{"message":"Continue?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}}}}},"requestState":"opaque"}}
    ,
        .modern,
        null,
        4096,
        .{},
    );
    defer input_required.deinit(alloc);
    try std.testing.expectEqualStrings(
        "\"opaque\"",
        input_required.input_required.request_state_json.?,
    );
    try std.testing.expectEqualStrings("confirm", input_required.input_required.requests[0].key);
    try std.testing.expectEqualStrings(
        "elicitation/create",
        input_required.input_required.requests[0].payload.method(),
    );
}

test "a text item may be as large as the whole result, and other fields keep their limit" {
    const alloc = std.testing.allocator;
    const limits: Limits = .{};
    const big = try alloc.alloc(u8, 1536 * 1024);
    defer alloc.free(big);
    @memset(big, 'a');
    const text = try alloc.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{big});
    defer alloc.free(text);
    var outcome = try parseCallOutcome(alloc, text, .modern, null, limits.max_content_text_bytes, limits);
    outcome.deinit(alloc);
    const resource = try alloc.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"content\":[{{\"type\":\"resource\",\"resource\":{{\"uri\":\"file:///big.txt\",\"text\":\"{s}\"}}}}]}}}}", .{big});
    defer alloc.free(resource);
    outcome = try parseCallOutcome(alloc, resource, .modern, null, limits.max_content_text_bytes, limits);
    outcome.deinit(alloc);
    const link = try alloc.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"content\":[{{\"type\":\"resource_link\",\"uri\":\"{s}\",\"name\":\"n\"}}]}}}}", .{big});
    defer alloc.free(link);
    try std.testing.expectError(error.InvalidContent, parseCallOutcome(alloc, link, .modern, null, limits.max_content_text_bytes, limits));
    const huge = try alloc.alloc(u8, limits.max_content_text_bytes + 1);
    defer alloc.free(huge);
    @memset(huge, 'a');
    const over = try alloc.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{huge});
    defer alloc.free(over);
    try std.testing.expectError(error.InvalidContent, parseCallOutcome(alloc, over, .modern, null, limits.max_content_text_bytes, limits));
}
