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

/// The types an argument written as text can be sent as.
pub const RepairType = enum { number, integer, boolean, array, object };

pub const RepairedField = struct {
    name: []const u8,
    json_type: RepairType,
};

pub const RepairedArguments = struct {
    arguments_json: []const u8,
    /// The top-level fields sent as their schema's type, in argument order.
    fields: []const RepairedField,
};

/// Some models write a number, boolean, array, or object argument as JSON
/// text, such as `"40"` for a `number` field, and a server that checks types
/// rejects the call. For each top-level argument whose property schema has a
/// single `type` other than `string`, a string that is exactly a value of
/// that type is sent as that value. A schema with such a `type` never accepts
/// a string there, so no value the schema accepts changes. Every other value
/// is left as the model wrote it, and numbers keep their text.
///
/// Null when nothing changes or either input isn't a JSON object, so the
/// caller sends the model's own bytes. Otherwise the arguments to send and
/// the fields that changed, allocated in `arena`.
/// (`tests/e2e/mcp-stdio.test.ts` "typed MCP arguments the model wrote as
/// text reach the server as their schema's types")
pub fn repairArgumentTypes(arena: Allocator, input_schema_json: []const u8, arguments_json: []const u8) Allocator.Error!?RepairedArguments {
    const limits: Limits = .{};
    if (arguments_json.len > limits.max_argument_bytes or input_schema_json.len > limits.max_schema_bytes) return null;
    var arguments = try parseRepairInput(arena, arguments_json) orelse return null;
    if (arguments != .object) return null;
    const schema = try parseRepairInput(arena, input_schema_json) orelse return null;
    if (schema != .object) return null;
    const properties = schema.object.get("properties") orelse return null;
    if (properties != .object) return null;

    var fields: std.ArrayList(RepairedField) = .empty;
    var entries = arguments.object.iterator();
    while (entries.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const property = properties.object.get(entry.key_ptr.*) orelse continue;
        const json_type = singleRepairType(property) orelse continue;
        entry.value_ptr.* = try decodeAs(arena, entry.value_ptr.string, json_type) orelse continue;
        try fields.append(arena, .{ .name = entry.key_ptr.*, .json_type = json_type });
    }
    if (fields.items.len == 0) return null;
    // The arguments sent stay within the bounds the model's had to meet.
    var remaining: usize = 4096;
    checkValueBounds(arguments, 0, &remaining) catch return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(arguments, .{}, &out.writer) catch return error.OutOfMemory;
    if (out.written().len > limits.max_argument_bytes) return null;
    return .{ .arguments_json = out.written(), .fields = fields.items };
}

/// Parses JSON with every number kept as its text. Null for text that isn't
/// JSON.
fn parseRepairInput(arena: Allocator, text: []const u8) Allocator.Error!?std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{
        .parse_numbers = false,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// The property's one `type`, when it names a type other than `string`. A
/// list of types, a missing `type`, and `string` or `null` give null.
fn singleRepairType(property: std.json.Value) ?RepairType {
    if (property != .object) return null;
    const kind = property.object.get("type") orelse return null;
    if (kind != .string) return null;
    return std.meta.stringToEnum(RepairType, kind.string);
}

/// `text` as a value of `json_type`, or null when it is not exactly one.
fn decodeAs(arena: Allocator, text: []const u8, json_type: RepairType) Allocator.Error!?std.json.Value {
    switch (json_type) {
        .number, .integer => {
            const number = json_number.Number.parse(arena, text, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            if (json_type == .integer and !number.isInteger()) return null;
            return .{ .number_string = text };
        },
        .boolean => {
            if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
            if (std.mem.eql(u8, text, "false")) return .{ .bool = false };
            return null;
        },
        .array, .object => {
            const decoded = try parseRepairInput(arena, text) orelse return null;
            const wanted: std.meta.Tag(std.json.Value) = if (json_type == .array) .array else .object;
            if (std.meta.activeTag(decoded) != wanted) return null;
            return decoded;
        },
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

const repair_test_schema =
    \\{"type":"object","properties":{
    \\"text":{"type":"string"},"limit":{"type":"number"},"count":{"type":"integer"},"verbose":{"type":"boolean"},
    \\"queries":{"type":"array","items":{"oneOf":[{"type":"string"},{"type":"object"}]}},"filter":{"type":"object"},
    \\"either":{"type":["string","number"]},"nullable":{"type":["integer","null"]},
    \\"branches":{"anyOf":[{"type":"number"},{"type":"boolean"}]},"untyped":{},"nothing":{"type":"null"}}}
;

/// Repairs `arguments` against `repair_test_schema` and compares the
/// arguments sent with `expected`; null expects the model's own bytes.
fn expectRepair(arguments: []const u8, expected: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const repaired = try repairArgumentTypes(arena_state.allocator(), repair_test_schema, arguments);
    if (expected) |wanted| {
        const sent = repaired orelse {
            std.debug.print("no repair of {s}\n", .{arguments});
            return error.TestExpectedRepair;
        };
        try std.testing.expectEqualStrings(wanted, sent.arguments_json);
    } else if (repaired) |sent| {
        std.debug.print("unexpected repair of {s} to {s}\n", .{ arguments, sent.arguments_json });
        return error.TestUnexpectedRepair;
    }
}

/// `{"<field>":"<text>"}`, with the text escaped as a JSON string.
fn oneStringArgument(alloc: Allocator, field: []const u8, text: []const u8) ![]u8 {
    return alloc.print("{{\"{s}\":{f}}}", .{ field, std.json.fmt(text, .{}) });
}

test "MCP argument repair sends text as the one non-string type its schema names" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const repaired = (try repairArgumentTypes(arena_state.allocator(), repair_test_schema,
        \\{"text":"40","limit":"40","count":"7","verbose":"true","queries":"[\"sum:a{*}\"]","filter":"{\"env\":\"prod\"}"}
    )).?;
    try std.testing.expectEqualStrings(
        \\{"text":"40","limit":40,"count":7,"verbose":true,"queries":["sum:a{*}"],"filter":{"env":"prod"}}
    , repaired.arguments_json);
    const fields = [_]RepairedField{
        .{ .name = "limit", .json_type = .number },
        .{ .name = "count", .json_type = .integer },
        .{ .name = "verbose", .json_type = .boolean },
        .{ .name = "queries", .json_type = .array },
        .{ .name = "filter", .json_type = .object },
    };
    try std.testing.expectEqual(fields.len, repaired.fields.len);
    for (fields, repaired.fields) |wanted, field| {
        try std.testing.expectEqualStrings(wanted.name, field.name);
        try std.testing.expectEqual(wanted.json_type, field.json_type);
    }

    try expectRepair("{\"limit\":\"4.5\",\"count\":\"4.0\"}", "{\"limit\":4.5,\"count\":4.0}");
    try expectRepair("{\"limit\":\"-0\",\"count\":\"1e3\"}", "{\"limit\":-0,\"count\":1e3}");
    try expectRepair("{\"verbose\":\"false\"}", "{\"verbose\":false}");
    // A number keeps every digit the model wrote.
    try expectRepair(
        "{\"count\":\"123456789012345678901234567890\",\"limit\":\"1.000000000000000000001\"}",
        "{\"count\":123456789012345678901234567890,\"limit\":1.000000000000000000001}",
    );
    try expectRepair("{\"queries\":\"[]\",\"filter\":\"{}\"}", "{\"queries\":[],\"filter\":{}}");
}

test "MCP argument repair keeps text that isn't exactly a value of the field's type" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kept = [_]struct { []const u8, []const []const u8 }{
        .{ "limit", &.{ "", " 40", "40 ", "0x10", "NaN", "Infinity", "+1", "01", "1.", ".5", "forty", "1e", "--1" } },
        .{ "count", &.{ "4.5", "1e-1", "7 ", "seven" } },
        .{ "verbose", &.{ "True", "TRUE", "yes", "1", "", " true", "null" } },
        .{ "queries", &.{ "[1", "{}", "1", "null", "\"[]\"", "" } },
        .{ "filter", &.{ "[1]", "{", "null", "\"x\"", "{\"a\":1}x", "" } },
    };
    for (kept) |case| {
        for (case[1]) |text| try expectRepair(try oneStringArgument(arena, case[0], text), null);
    }
}

test "MCP argument repair keeps every string its schema could accept" {
    // A string field, a type list, anyOf branches, no type, a null type, and
    // a field the schema doesn't name.
    try expectRepair(
        \\{"text":"40","either":"40","nullable":"40","branches":"40","untyped":"true","nothing":"null","unknown":"40"}
    , null);
    // Nested text stays as written, even where it holds a number.
    try expectRepair("{\"queries\":[\"40\",{\"count\":\"7\"}],\"filter\":{\"limit\":\"40\"}}", null);
    try expectRepair("{\"queries\":\"[\\\"40\\\"]\"}", "{\"queries\":[\"40\"]}");
}

test "MCP argument repair sends the model's bytes when nothing changes" {
    try expectRepair("{\"limit\":40,\"count\":7,\"verbose\":true,\"queries\":[],\"filter\":{}}", null);
    try expectRepair("{}", null);
    try expectRepair("[\"40\"]", null);
    try expectRepair("\"40\"", null);
    try expectRepair("{\"limit\":\"40\"", null);
    try expectRepair("", null);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const arguments = "{\"limit\":\"40\"}";
    for ([_][]const u8{ "", "{", "[]", "{\"type\":\"object\"}", "{\"type\":\"object\",\"properties\":[]}", "{\"properties\":{\"limit\":\"number\"}}" }) |schema| {
        try std.testing.expect((try repairArgumentTypes(arena, schema, arguments)) == null);
    }
}

test "MCP argument repair keeps a decoded value past the argument bounds" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 64 levels of arrays fit under the top-level object; 65 do not.
    for ([_]struct { usize, bool }{ .{ 64, true }, .{ 65, false } }) |case| {
        const depth, const fits = case;
        var text: std.ArrayList(u8) = .empty;
        try text.appendNTimes(arena, '[', depth);
        try text.appendNTimes(arena, ']', depth);
        const repaired = try repairArgumentTypes(arena, repair_test_schema, try oneStringArgument(arena, "queries", text.items));
        try std.testing.expectEqual(fits, repaired != null);
    }
    // 4096 values in all.
    for ([_]struct { usize, bool }{ .{ 4094, true }, .{ 4095, false } }) |case| {
        const items, const fits = case;
        var text: std.ArrayList(u8) = .empty;
        try text.append(arena, '[');
        for (0..items) |index| try text.appendSlice(arena, if (index == 0) "0" else ",0");
        try text.append(arena, ']');
        const repaired = try repairArgumentTypes(arena, repair_test_schema, try oneStringArgument(arena, "queries", text.items));
        try std.testing.expectEqual(fits, repaired != null);
    }
}

fn repairArgumentTypesAllocationFailures(alloc: Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    _ = try repairArgumentTypes(arena_state.allocator(), repair_test_schema,
        \\{"limit":"40","count":"7","verbose":"true","queries":"[\"a\",{\"b\":[1]}]","filter":"{\"env\":\"prod\"}","text":"x"}
    );
}

test "MCP argument repair reports running out of memory instead of sending the model's text" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, repairArgumentTypesAllocationFailures, .{});
}

const fuzz_repair_schema =
    \\{"type":"object","properties":{"s":{"type":"string"},"n":{"type":"number"},"i":{"type":"integer"},
    \\"b":{"type":"boolean"},"a":{"type":"array"},"o":{"type":"object"},"l":{"type":["string","number"]},"u":{}}}
;
const fuzz_repair_fields = [_][]const u8{ "s", "n", "i", "b", "a", "o", "l", "u", "x" };
const fuzz_repair_pieces = [_][]const u8{
    "40", "-0",        "4.5", "4.0",       "1e3", "1e-1", "01",   " 40",   "0x10", "true",                           "false",     "True",
    "[]", "[1,\"a\"]", "{}",  "{\"a\":1}", "[",   "{",    "null", "\"x\"", "NaN",  "123456789012345678901234567890", "[[[[1]]]]", "",
};

fn fuzzArgumentRepair(_: void, smith: *std.testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var raw: [512]u8 = undefined;
    const text = raw[0..smith.slice(&raw)];
    // The bytes as the arguments, and as a schema.
    try expectRepairLaws(arena, fuzz_repair_schema, text);
    try expectRepairLaws(arena, text, "{\"n\":\"40\",\"a\":\"[]\"}");

    // Each field gets nothing, the bytes or a piece as a string, or a piece as
    // JSON when it is JSON.
    var arguments: std.Io.Writer.Allocating = .init(arena);
    try arguments.writer.writeByte('{');
    var first = true;
    for (fuzz_repair_fields) |field| {
        const choice = smith.valueRangeAtMost(u8, 0, 3);
        if (choice == 0) continue;
        const piece = fuzz_repair_pieces[smith.index(fuzz_repair_pieces.len)];
        const value = switch (choice) {
            1 => try jsonStringAlloc(arena, text),
            2 => try jsonStringAlloc(arena, piece),
            else => if ((try parseRepairInput(arena, piece)) != null) piece else try jsonStringAlloc(arena, piece),
        };
        if (!first) try arguments.writer.writeByte(',');
        first = false;
        try arguments.writer.print("\"{s}\":{s}", .{ field, value });
    }
    try arguments.writer.writeByte('}');
    try expectRepairLaws(arena, fuzz_repair_schema, arguments.written());
}

fn jsonStringAlloc(arena: Allocator, text: []const u8) ![]u8 {
    return arena.print("{f}", .{std.json.fmt(text, .{})});
}

/// What holds for every repair: an object goes out with the same fields in
/// the same order; only the fields it names change, each from text to a
/// value of the one non-string type its schema names; the rest are as the
/// model wrote them; and repairing the result changes nothing more.
fn expectRepairLaws(arena: Allocator, schema_json: []const u8, arguments_json: []const u8) !void {
    const repaired = try repairArgumentTypes(arena, schema_json, arguments_json) orelse return;
    try std.testing.expect(repaired.fields.len > 0);
    const before = (try parseRepairInput(arena, arguments_json)).?;
    const after = (try parseRepairInput(arena, repaired.arguments_json)) orelse return error.TestRepairNotJson;
    try std.testing.expect(before == .object and after == .object);
    try std.testing.expectEqual(before.object.count(), after.object.count());
    const properties = (try parseRepairInput(arena, schema_json)).?.object.get("properties").?.object;
    var changed: usize = 0;
    for (before.object.keys(), before.object.values(), after.object.keys(), after.object.values()) |name, old, new_name, new| {
        try std.testing.expectEqualStrings(name, new_name);
        const field = for (repaired.fields) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) break candidate;
        } else null;
        if (field) |repair| {
            changed += 1;
            try std.testing.expect(old == .string);
            try std.testing.expectEqual(singleRepairType(properties.get(name).?).?, repair.json_type);
            try std.testing.expect(switch (repair.json_type) {
                .number, .integer => new == .number_string and std.mem.eql(u8, new.number_string, old.string),
                .boolean => new == .bool,
                .array => new == .array,
                .object => new == .object,
            });
        } else {
            var old_text: std.Io.Writer.Allocating = .init(arena);
            var new_text: std.Io.Writer.Allocating = .init(arena);
            try std.json.Stringify.value(old, .{}, &old_text.writer);
            try std.json.Stringify.value(new, .{}, &new_text.writer);
            try std.testing.expectEqualStrings(old_text.written(), new_text.written());
        }
    }
    try std.testing.expectEqual(repaired.fields.len, changed);
    try std.testing.expect((try repairArgumentTypes(arena, schema_json, repaired.arguments_json)) == null);
}

test "MCP argument repair keeps its laws on fuzzed schemas and arguments" {
    try std.testing.fuzz({}, fuzzArgumentRepair, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "40",
            "{\"n\":\"40\",\"i\":\"4.5\",\"b\":\"true\",\"a\":\"[1]\",\"o\":\"{}\",\"s\":\"40\",\"l\":\"40\"}",
            "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\"},\"a\":{\"type\":\"array\"}}}",
            "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]",
        }) ++ @import("fuzz_corpus").mcp_argument_repair.*),
    });
}
