const std = @import("std");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const json_number = @import("../json_number.zig");
const mcp_contract = @import("../mcp_contract.zig");
const mrtr = @import("../mrtr.zig");
const mem_utils = @import("../../shared/mem_utils.zig");

const Allocator = std.mem.Allocator;

pub const Protocol = enum { legacy, modern };
pub const CacheScope = enum { private, public };

pub const Limits = struct {
    max_name_bytes: usize = 256,
    max_uri_bytes: usize = 64 * 1024,
    max_title_bytes: usize = 4096,
    max_description_bytes: usize = 64 * 1024,
    max_metadata_bytes: usize = 128 * 1024,
    max_content_items: usize = 256,
    max_content_field_bytes: usize = 1024 * 1024,
    max_total_content_bytes: usize = 4 * 1024 * 1024,
    max_icons: usize = 16,
    max_icon_sizes: usize = 16,
    max_input_requests: usize = 32,
    max_request_state_bytes: usize = 64 * 1024,
    max_json_depth: usize = 32,
};

pub const Error = error{
    InvalidEnvelope,
    ProtocolFailure,
    InvalidResult,
    UnsupportedResultType,
    InvalidContent,
    MetadataLimitExceeded,
    JsonDepthLimitExceeded,
} || mrtr.Error || Allocator.Error || std.Io.Writer.Error;

pub const CacheHints = struct {
    ttl_ms: u64 = 0,
    ttl_present: bool = false,
    scope: CacheScope = .private,
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

pub const ResourceData = union(enum) {
    text: []u8,
    blob: []u8,

    pub fn deinit(self: *ResourceData, alloc: Allocator) void {
        switch (self.*) {
            .text => |value| alloc.free(value),
            .blob => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

pub const ResourceContent = struct {
    uri: []u8,
    mime_type: ?[]u8 = null,
    annotations_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,
    data: ResourceData,

    pub fn deinit(self: *ResourceContent, alloc: Allocator) void {
        alloc.free(self.uri);
        if (self.mime_type) |value| alloc.free(value);
        if (self.annotations_json) |value| alloc.free(value);
        if (self.metadata_json) |value| alloc.free(value);
        self.data.deinit(alloc);
        self.* = undefined;
    }
};

pub fn parseEnvelope(
    alloc: Allocator,
    response: []const u8,
    limits: Limits,
) Error!std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvelope,
    };
    errdefer parsed.deinit();
    try validateJsonDepth(parsed.value, limits.max_json_depth);
    mcp_contract.validateJsonRpcResponseEnvelope(parsed.value) catch
        return error.InvalidEnvelope;
    return parsed;
}

pub fn completeResult(value: std.json.Value, protocol: Protocol) Error!std.json.Value {
    _ = protocol;
    if (value.object.get("error") != null) return error.ProtocolFailure;
    const result = value.object.get("result") orelse return error.InvalidResult;
    if (result != .object) return error.InvalidResult;
    if (result.object.get("resultType")) |result_type| {
        if (result_type != .string or !std.mem.eql(u8, result_type.string, "complete")) {
            return error.UnsupportedResultType;
        }
    }
    return result;
}

pub fn parseCacheHints(alloc: Allocator, result: std.json.Value) Error!CacheHints {
    const ttl_value = result.object.get("ttlMs");
    const ttl_ms = if (ttl_value) |value|
        (try ttlMilliseconds(alloc, value)) orelse return error.InvalidResult
    else
        0;
    const scope: CacheScope = if (result.object.get("cacheScope")) |value| blk: {
        if (value != .string) return error.InvalidResult;
        if (std.mem.eql(u8, value.string, "public")) break :blk .public;
        if (std.mem.eql(u8, value.string, "private")) break :blk .private;
        return error.InvalidResult;
    } else .private;
    return .{ .ttl_ms = ttl_ms, .ttl_present = ttl_value != null, .scope = scope };
}

pub fn parseProtocolError(alloc: Allocator, value: std.json.Value, limits: Limits) Error!ProtocolError {
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
        try stringifyValueAlloc(alloc, data, limits.max_metadata_bytes, limits.max_json_depth)
    else
        null;
    return .{ .code = parsed_code, .message = owned_message, .data_json = data_json };
}

pub fn parseResourceContent(alloc: Allocator, value: std.json.Value, limits: Limits) Error!ResourceContent {
    if (value != .object) return error.InvalidContent;
    const uri = try requiredString(value.object, "uri", limits.max_uri_bytes);
    const text = value.object.get("text");
    const blob = value.object.get("blob");
    if ((text == null) == (blob == null)) return error.InvalidContent;
    const mime_type = try optionalString(value.object, "mimeType", limits.max_title_bytes);
    if (value.object.get("annotations")) |annotations| try validateAnnotations(annotations, limits);
    if (value.object.get("_meta")) |metadata| {
        if (metadata != .object) return error.InvalidContent;
        _ = try boundedJsonLength(metadata, limits.max_metadata_bytes, limits.max_json_depth);
    }

    const owned_uri = try alloc.dupe(u8, uri);
    errdefer mem_utils.free(alloc, owned_uri);
    const owned_mime_type = if (mime_type) |item| try alloc.dupe(u8, item) else null;
    errdefer if (owned_mime_type) |item| mem_utils.free(alloc, item);
    const annotations_json = if (value.object.get("annotations")) |annotations|
        try stringifyValueAlloc(alloc, annotations, limits.max_metadata_bytes, limits.max_json_depth)
    else
        null;
    errdefer if (annotations_json) |item| mem_utils.free(alloc, item);
    const metadata_json = if (value.object.get("_meta")) |metadata|
        try stringifyValueAlloc(alloc, metadata, limits.max_metadata_bytes, limits.max_json_depth)
    else
        null;
    errdefer if (metadata_json) |item| mem_utils.free(alloc, item);

    const data: ResourceData = if (text) |content| text_data: {
        if (content != .string or content.string.len > limits.max_content_field_bytes) {
            return error.InvalidContent;
        }
        break :text_data .{ .text = try alloc.dupe(u8, content.string) };
    } else blob_data: {
        const content = blob.?;
        if (content != .string or content.string.len > limits.max_content_field_bytes or
            !try validBase64(alloc, content.string))
        {
            return error.InvalidContent;
        }
        break :blob_data .{ .blob = try alloc.dupe(u8, content.string) };
    };
    return .{
        .uri = owned_uri,
        .mime_type = owned_mime_type,
        .annotations_json = annotations_json,
        .metadata_json = metadata_json,
        .data = data,
    };
}

pub fn validatePromptContent(alloc: Allocator, value: std.json.Value, limits: Limits) Error!void {
    if (value != .object) return error.InvalidContent;
    const type_value = value.object.get("type") orelse return error.InvalidContent;
    if (type_value != .string) return error.InvalidContent;
    if (value.object.get("annotations")) |annotations| try validateAnnotations(annotations, limits);
    if (value.object.get("_meta")) |metadata| {
        if (metadata != .object) return error.InvalidContent;
        _ = try boundedJsonLength(metadata, limits.max_metadata_bytes, limits.max_json_depth);
    }
    if (std.mem.eql(u8, type_value.string, "text")) {
        _ = try requiredStringAllowEmpty(value.object, "text", limits.max_content_field_bytes);
        return;
    }
    if (std.mem.eql(u8, type_value.string, "image") or std.mem.eql(u8, type_value.string, "audio")) {
        const data = try requiredStringAllowEmpty(value.object, "data", limits.max_content_field_bytes);
        _ = try requiredString(value.object, "mimeType", limits.max_title_bytes);
        if (!try validBase64(alloc, data)) return error.InvalidContent;
        return;
    }
    if (std.mem.eql(u8, type_value.string, "resource_link")) {
        try validateResourceLink(alloc, value.object, limits);
        return;
    }
    if (std.mem.eql(u8, type_value.string, "resource")) {
        const resource = value.object.get("resource") orelse return error.InvalidContent;
        var parsed = try parseResourceContent(alloc, resource, limits);
        parsed.deinit(alloc);
        return;
    }
    return error.InvalidContent;
}

pub fn validateAnnotations(value: std.json.Value, limits: Limits) Error!void {
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
    _ = try optionalString(value.object, "lastModified", limits.max_title_bytes);
    _ = try boundedJsonLength(value, limits.max_metadata_bytes, limits.max_json_depth);
}

pub fn validateIcons(value: std.json.Value, limits: Limits) Error!void {
    if (value != .array or value.array.items.len > limits.max_icons) return error.InvalidContent;
    for (value.array.items) |icon| {
        if (icon != .object) return error.InvalidContent;
        _ = try requiredString(icon.object, "src", limits.max_uri_bytes);
        _ = try optionalString(icon.object, "mimeType", limits.max_title_bytes);
        if (icon.object.get("sizes")) |sizes| {
            if (sizes != .array or sizes.array.items.len > limits.max_icon_sizes) return error.InvalidContent;
            for (sizes.array.items) |size| {
                if (size != .string or size.string.len > limits.max_title_bytes) return error.InvalidContent;
            }
        }
        if (icon.object.get("theme")) |theme| {
            if (theme != .string or
                (!std.mem.eql(u8, theme.string, "light") and !std.mem.eql(u8, theme.string, "dark")))
            {
                return error.InvalidContent;
            }
        }
    }
}

pub fn requiredString(object: std.json.ObjectMap, name: []const u8, max_bytes: usize) Error![]const u8 {
    const value = object.get(name) orelse return error.InvalidContent;
    if (value != .string or value.string.len == 0 or value.string.len > max_bytes) {
        return error.InvalidContent;
    }
    return value.string;
}

fn requiredStringAllowEmpty(object: std.json.ObjectMap, name: []const u8, max_bytes: usize) Error![]const u8 {
    const value = object.get(name) orelse return error.InvalidContent;
    if (value != .string or value.string.len > max_bytes) return error.InvalidContent;
    return value.string;
}

pub fn optionalString(object: std.json.ObjectMap, name: []const u8, max_bytes: usize) Error!?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string or value.string.len > max_bytes) return error.InvalidContent;
    return value.string;
}

const max_supported_json_depth: usize = 128;

const JsonDepthFrame = struct {
    value: std.json.Value,
    next_child: usize = 0,
};

pub fn validateJsonDepth(value: std.json.Value, max_depth: usize) Error!void {
    if (max_depth > max_supported_json_depth) return error.JsonDepthLimitExceeded;
    var stack: [max_supported_json_depth + 1]JsonDepthFrame = undefined;
    stack[0] = .{ .value = value };
    var stack_len: usize = 1;

    while (stack_len > 0) {
        const frame = &stack[stack_len - 1];
        const children: []const std.json.Value = switch (frame.value) {
            .array => |array| array.items,
            .object => |object| object.values(),
            else => {
                stack_len -= 1;
                continue;
            },
        };
        if (frame.next_child >= children.len) {
            stack_len -= 1;
            continue;
        }
        const child = children[frame.next_child];
        frame.next_child += 1;
        const child_depth = stack_len;
        if (child_depth > max_depth or stack_len >= stack.len) {
            return error.JsonDepthLimitExceeded;
        }
        stack[stack_len] = .{ .value = child };
        stack_len += 1;
    }
}

pub fn boundedJsonLength(value: std.json.Value, max_bytes: usize, max_depth: usize) Error!usize {
    try validateJsonDepth(value, max_depth);
    var counter: std.Io.Writer.Discarding = .init(&.{});
    std.json.Stringify.value(value, .{}, &counter.writer) catch return error.MetadataLimitExceeded;
    if (counter.fullCount() > max_bytes) return error.MetadataLimitExceeded;
    return @intCast(counter.fullCount());
}

pub fn stringifyValueAlloc(
    alloc: Allocator,
    value: std.json.Value,
    max_bytes: usize,
    max_depth: usize,
) Error![]u8 {
    try validateJsonDepth(value, max_depth);
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    std.json.Stringify.value(value, .{}, &output.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    if (output.writer.buffered().len > max_bytes) return error.MetadataLimitExceeded;
    return try output.toOwnedSlice();
}

pub fn mrtrLimits(limits: Limits) mrtr.Limits {
    return .{
        .max_requests = limits.max_input_requests,
        .max_name_bytes = limits.max_name_bytes,
        .max_json_bytes = limits.max_metadata_bytes,
        .max_string_bytes = limits.max_request_state_bytes,
        .max_collection_items = limits.max_content_items,
    };
}

fn validateResourceLink(alloc: Allocator, object: std.json.ObjectMap, limits: Limits) Error!void {
    _ = try requiredString(object, "uri", limits.max_uri_bytes);
    _ = try requiredString(object, "name", limits.max_title_bytes);
    _ = try optionalString(object, "title", limits.max_title_bytes);
    _ = try optionalString(object, "description", limits.max_description_bytes);
    _ = try optionalString(object, "mimeType", limits.max_title_bytes);
    if (object.get("icons")) |icons| try validateIcons(icons, limits);
    if (object.get("size")) |size| _ = (try nonNegativeU64(alloc, size)) orelse return error.InvalidContent;
}

fn validBase64(alloc: Allocator, value: []const u8) Error!bool {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(value) catch return false;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, value) catch return false;
    return true;
}

fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |number| std.fmt.parseFloat(f64, number) catch null,
        else => null,
    };
}

fn nonNegativeU64(alloc: Allocator, value: std.json.Value) Error!?u64 {
    const parsed = json_number.fromValue(alloc, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed == null) return null;
    var number = parsed.?;
    defer number.deinit(alloc);
    const result = number.toNonNegativeUsize() orelse return null;
    return std.math.cast(u64, result);
}

fn ttlMilliseconds(alloc: Allocator, value: std.json.Value) Error!?u64 {
    const parsed = json_number.fromValue(alloc, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed == null) return null;
    var number = parsed.?;
    defer number.deinit(alloc);
    if (number.negative) return 0;
    const result = number.toNonNegativeUsize() orelse return null;
    return std.math.cast(u64, result);
}

test "shared resource content owns text blob annotations and metadata" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "{\"uri\":\"git://repo/a\",\"mimeType\":\"text/plain\",\"text\":\"hello\",\"annotations\":{\"audience\":[\"user\"],\"priority\":0.5},\"_meta\":{\"revision\":1}}",
        "{\"uri\":\"memory://image\",\"blob\":\"aGVsbG8=\"}",
    };
    for (cases) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        var content = try parseResourceContent(alloc, parsed.value, .{});
        defer content.deinit(alloc);
        try std.testing.expect(content.uri.len > 0);
    }
}

fn checkResourceContentAllocationFailures(alloc: Allocator) !void {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"uri\":\"custom://one\",\"mimeType\":\"text/plain\",\"text\":\"hello\",\"annotations\":{\"audience\":[\"assistant\"]},\"_meta\":{\"source\":\"fixture\"}}",
        .{},
    );
    defer parsed.deinit();
    var content = try parseResourceContent(alloc, parsed.value, .{});
    defer content.deinit(alloc);
}

test "shared resource content construction is allocation failure safe" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkResourceContentAllocationFailures,
        .{},
    );
}

test "iterative JSON depth validation accepts the limit and rejects the next level" {
    const alloc = std.testing.allocator;
    var below = try std.json.parseFromSlice(std.json.Value, alloc, "{\"a\":{\"b\":1}}", .{});
    defer below.deinit();
    try validateJsonDepth(below.value, 2);
    try std.testing.expectError(error.JsonDepthLimitExceeded, validateJsonDepth(below.value, 1));

    var scalar = try std.json.parseFromSlice(std.json.Value, alloc, "1", .{});
    defer scalar.deinit();
    try validateJsonDepth(scalar.value, 0);
}
