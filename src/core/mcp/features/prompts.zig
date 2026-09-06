const std = @import("std");
const common = @import("common.zig");
const catalog_freshness = @import("../catalog_freshness.zig");
const mrtr = @import("../mrtr.zig");
const sort_utils = @import("../../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

pub const Protocol = common.Protocol;
pub const CacheScope = common.CacheScope;
pub const ProtocolError = common.ProtocolError;
pub const InputRequired = mrtr.InputRequired;

pub const Limits = struct {
    max_pages: usize = 64,
    max_prompts: usize = 4096,
    max_arguments: usize = 128,
    max_messages: usize = 256,
    max_cursor_bytes: usize = 4096,
    max_arguments_json_bytes: usize = 128 * 1024,
    max_result_json_bytes: usize = 4 * 1024 * 1024,
    common: common.Limits = .{},
};

pub const Error = error{
    InvalidListResult,
    InvalidPrompt,
    InvalidArgument,
    DuplicatePrompt,
    DuplicateArgument,
    DuplicateCursor,
    InconsistentCacheScope,
    PaginationLimitExceeded,
    PromptLimitExceeded,
    ArgumentLimitExceeded,
    InvalidGetResult,
    MessageLimitExceeded,
    InvalidMessage,
    InvalidArguments,
} || common.Error || Allocator.Error || std.Io.Writer.Error;

pub const Argument = struct {
    name: []u8,
    description: ?[]u8 = null,
    required: bool = false,

    pub fn deinit(self: *Argument, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.description) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Prompt = struct {
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    arguments: []Argument,
    icons_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,

    pub fn deinit(self: *Prompt, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        for (self.arguments) |*argument| argument.deinit(alloc);
        alloc.free(self.arguments);
        if (self.icons_json) |value| alloc.free(value);
        if (self.metadata_json) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn argumentNamed(self: Prompt, name: []const u8) ?*const Argument {
        for (self.arguments) |*argument| {
            if (std.mem.eql(u8, argument.name, name)) return argument;
        }
        return null;
    }
};

pub const Page = struct {
    prompts: []Prompt,
    next_cursor: ?[]u8 = null,
    cache: common.CacheHints,

    pub fn deinit(self: *Page, alloc: Allocator) void {
        for (self.prompts) |*prompt| prompt.deinit(alloc);
        alloc.free(self.prompts);
        if (self.next_cursor) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    prompts: []Prompt,
    fetched_at_ms: u64,
    expires_at_ms: u64,
    cache_scope: CacheScope,

    pub fn deinit(self: *Catalog, alloc: Allocator) void {
        for (self.prompts) |*prompt| prompt.deinit(alloc);
        alloc.free(self.prompts);
        self.* = undefined;
    }

    pub fn find(self: Catalog, name: []const u8) ?*const Prompt {
        for (self.prompts) |*prompt| if (std.mem.eql(u8, prompt.name, name)) return prompt;
        return null;
    }
};

pub const CatalogBuilder = struct {
    prompts: std.ArrayList(Prompt) = .empty,
    cursors: std.StringHashMap(void),
    protocol: Protocol,
    pages: usize = 0,
    first_received_at_ms: ?u64 = null,
    expires_at_ms: ?u64 = null,
    cache_scope: ?CacheScope = null,

    pub fn init(alloc: Allocator, protocol: Protocol) CatalogBuilder {
        return .{ .cursors = std.StringHashMap(void).init(alloc), .protocol = protocol };
    }

    pub fn deinit(self: *CatalogBuilder, alloc: Allocator) void {
        for (self.prompts.items) |*prompt| prompt.deinit(alloc);
        self.prompts.deinit(alloc);
        var iterator = self.cursors.keyIterator();
        while (iterator.next()) |cursor| alloc.free(cursor.*);
        self.cursors.deinit();
        self.* = undefined;
    }

    pub fn appendPage(self: *CatalogBuilder, alloc: Allocator, page: *Page, received_at_ms: u64, limits: Limits) Error!void {
        const next_pages = std.math.add(usize, self.pages, 1) catch
            return error.PaginationLimitExceeded;
        if (next_pages > limits.max_pages) return error.PaginationLimitExceeded;
        const total = std.math.add(usize, self.prompts.items.len, page.prompts.len) catch
            return error.PromptLimitExceeded;
        if (total > limits.max_prompts) return error.PromptLimitExceeded;
        if (page.next_cursor) |cursor| {
            if (self.cursors.contains(cursor)) return error.DuplicateCursor;
        }
        if (self.cache_scope) |scope| {
            if (scope != page.cache.scope) return error.InconsistentCacheScope;
        }
        for (page.prompts, 0..) |prompt, index| {
            for (self.prompts.items) |existing| {
                if (std.mem.eql(u8, existing.name, prompt.name)) return error.DuplicatePrompt;
            }
            for (page.prompts[0..index]) |previous| {
                if (std.mem.eql(u8, previous.name, prompt.name)) return error.DuplicatePrompt;
            }
        }
        if (page.next_cursor) |cursor| {
            const owned = try alloc.dupe(u8, cursor);
            errdefer alloc.free(owned);
            try self.cursors.put(owned, {});
        }
        self.pages = next_pages;
        if (self.first_received_at_ms == null) self.first_received_at_ms = received_at_ms;
        self.cache_scope = self.cache_scope orelse page.cache.scope;
        const page_expiry = catalog_freshness.pageExpiry(
            switch (self.protocol) {
                .legacy => .legacy,
                .modern => .modern,
            },
            received_at_ms,
            page.cache.ttl_present,
            page.cache.ttl_ms,
        );
        self.expires_at_ms = catalog_freshness.earliestExpiry(self.expires_at_ms, page_expiry);
        try self.prompts.ensureUnusedCapacity(alloc, page.prompts.len);
        for (page.prompts) |*prompt| {
            self.prompts.appendAssumeCapacity(prompt.*);
            prompt.* = undefined;
        }
        alloc.free(page.prompts);
        page.prompts = &.{};
    }

    pub fn finish(self: *CatalogBuilder, alloc: Allocator) Error!Catalog {
        if (self.pages == 0) return error.InvalidListResult;
        sort_utils.sort(Prompt, self.prompts.items, {}, lessPrompt);
        return .{
            .prompts = try self.prompts.toOwnedSlice(alloc),
            .fetched_at_ms = self.first_received_at_ms.?,
            .expires_at_ms = self.expires_at_ms.?,
            .cache_scope = self.cache_scope orelse .private,
        };
    }
};

pub const Role = enum { user, assistant };
pub const ContentKind = enum { text, image, audio, resource_link, resource };

pub const Message = struct {
    role: Role,
    content_kind: ContentKind,
    content_json: []u8,

    pub fn deinit(self: *Message, alloc: Allocator) void {
        alloc.free(self.content_json);
        self.* = undefined;
    }
};

pub const GetResult = struct {
    description: ?[]u8,
    messages: []Message,
    cache: common.CacheHints,

    pub fn deinit(self: *GetResult, alloc: Allocator) void {
        if (self.description) |value| alloc.free(value);
        for (self.messages) |*message| message.deinit(alloc);
        alloc.free(self.messages);
        self.* = undefined;
    }
};

pub const GetOutcome = union(enum) {
    complete: GetResult,
    input_required: InputRequired,
    protocol_failure: ProtocolError,

    pub fn deinit(self: *GetOutcome, alloc: Allocator) void {
        switch (self.*) {
            .complete => |*value| value.deinit(alloc),
            .input_required => |*value| value.deinit(alloc),
            .protocol_failure => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub fn parseListPage(alloc: Allocator, response: []const u8, protocol: Protocol, limits: Limits) Error!Page {
    var parsed = try common.parseEnvelope(alloc, response, limits.common);
    defer parsed.deinit();
    const result = common.completeResult(parsed.value, protocol) catch |err| return mapCommonListError(err);
    const prompts_value = result.object.get("prompts") orelse return error.InvalidListResult;
    if (prompts_value != .array or prompts_value.array.items.len > limits.max_prompts) {
        return error.InvalidListResult;
    }
    const prompts = try alloc.alloc(Prompt, prompts_value.array.items.len);
    var count: usize = 0;
    errdefer {
        for (prompts[0..count]) |*prompt| prompt.deinit(alloc);
        alloc.free(prompts);
    }
    for (prompts_value.array.items, 0..) |prompt, index| {
        prompts[index] = try parsePrompt(alloc, prompt, limits);
        count += 1;
    }
    const next_cursor = if (result.object.get("nextCursor")) |cursor| blk: {
        if (cursor != .string or cursor.string.len > limits.max_cursor_bytes) {
            return error.InvalidListResult;
        }
        break :blk try alloc.dupe(u8, cursor.string);
    } else null;
    errdefer if (next_cursor) |cursor| alloc.free(cursor);
    return .{ .prompts = prompts, .next_cursor = next_cursor, .cache = try common.parseCacheHints(alloc, result) };
}

pub fn parseGetOutcome(alloc: Allocator, response: []const u8, protocol: Protocol, limits: Limits) Error!GetOutcome {
    var parsed = try common.parseEnvelope(alloc, response, limits.common);
    defer parsed.deinit();
    if (parsed.value.object.get("error")) |protocol_error| {
        return .{ .protocol_failure = try common.parseProtocolError(alloc, protocol_error, limits.common) };
    }
    const result = parsed.value.object.get("result") orelse return error.InvalidGetResult;
    if (result != .object) return error.InvalidGetResult;
    if (result.object.get("resultType")) |result_type| {
        if (result_type != .string) return error.InvalidGetResult;
        if (std.mem.eql(u8, result_type.string, "input_required")) {
            if (protocol != .modern) return error.UnsupportedResultType;
            return .{ .input_required = try mrtr.parseInputRequired(
                alloc,
                result,
                common.mrtrLimits(limits.common),
            ) };
        }
        if (!std.mem.eql(u8, result_type.string, "complete")) return error.UnsupportedResultType;
    }
    const description = try common.optionalString(result.object, "description", limits.common.max_description_bytes);
    const messages_value = result.object.get("messages") orelse return error.InvalidGetResult;
    if (messages_value != .array or messages_value.array.items.len > limits.max_messages) {
        return error.MessageLimitExceeded;
    }
    const messages = try alloc.alloc(Message, messages_value.array.items.len);
    var count: usize = 0;
    var total_content_bytes = description: {
        if (description) |value| break :description value.len;
        break :description @as(usize, 0);
    };
    errdefer {
        for (messages[0..count]) |*message| message.deinit(alloc);
        alloc.free(messages);
    }
    for (messages_value.array.items, 0..) |message, index| {
        messages[index] = try parseMessage(alloc, message, limits);
        count += 1;
        total_content_bytes = std.math.add(
            usize,
            total_content_bytes,
            messages[index].content_json.len,
        ) catch return error.MessageLimitExceeded;
        if (total_content_bytes > limits.common.max_total_content_bytes) {
            return error.MessageLimitExceeded;
        }
    }
    const owned_description = if (description) |value| try alloc.dupe(u8, value) else null;
    return .{ .complete = .{
        .description = owned_description,
        .messages = messages,
        .cache = try common.parseCacheHints(alloc, result),
    } };
}

pub fn validateArgumentsJson(alloc: Allocator, prompt: Prompt, arguments_json: []const u8, limits: Limits) Error!void {
    if (arguments_json.len > limits.max_arguments_json_bytes) return error.InvalidArguments;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() > limits.max_arguments) {
        return error.InvalidArguments;
    }
    common.validateJsonDepth(parsed.value, limits.common.max_json_depth) catch
        return error.InvalidArguments;
    for (prompt.arguments) |argument| {
        const value = parsed.value.object.get(argument.name);
        if (argument.required and value == null) return error.InvalidArguments;
        if (value) |item| if (item != .string) return error.InvalidArguments;
    }
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (prompt.argumentNamed(entry.key_ptr.*) == null) return error.InvalidArguments;
    }
}

pub fn buildListRequest(alloc: Allocator, request_id: u64, protocol: Protocol, cursor: ?[]const u8, write_modern_metadata: *const fn (*std.Io.Writer) anyerror!void) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"prompts/list\",\"params\":{{", .{request_id});
    var wrote = false;
    if (protocol == .modern) {
        try out.writer.writeAll("\"_meta\":");
        try write_modern_metadata(&out.writer);
        wrote = true;
    }
    if (cursor) |value| {
        if (wrote) try out.writer.writeByte(',');
        try out.writer.writeAll("\"cursor\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

pub fn buildGetRequest(
    alloc: Allocator,
    request_id: u64,
    protocol: Protocol,
    name: []const u8,
    arguments_json: []const u8,
    write_modern_metadata: *const fn (*std.Io.Writer) anyerror!void,
    input_responses_json: ?[]const u8,
    request_state_json: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"prompts/get\",\"params\":{{", .{request_id});
    if (protocol == .modern) {
        try out.writer.writeAll("\"_meta\":");
        try write_modern_metadata(&out.writer);
        try out.writer.writeByte(',');
    }
    try out.writer.writeAll("\"name\":");
    try std.json.Stringify.value(name, .{}, &out.writer);
    try out.writer.writeAll(",\"arguments\":");
    try writeCompactJson(alloc, &out.writer, arguments_json);
    if (input_responses_json) |responses| {
        try out.writer.writeAll(",\"inputResponses\":");
        try writeCompactJson(alloc, &out.writer, responses);
        if (request_state_json) |state| {
            try out.writer.writeAll(",\"requestState\":");
            try writeCompactJson(alloc, &out.writer, state);
        }
    }
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn parsePrompt(alloc: Allocator, value: std.json.Value, limits: Limits) Error!Prompt {
    if (value != .object) return error.InvalidPrompt;
    const name = common.requiredString(value.object, "name", limits.common.max_name_bytes) catch return error.InvalidPrompt;
    const title = common.optionalString(value.object, "title", limits.common.max_title_bytes) catch return error.InvalidPrompt;
    const description = common.optionalString(value.object, "description", limits.common.max_description_bytes) catch return error.InvalidPrompt;
    if (value.object.get("icons")) |icons| common.validateIcons(icons, limits.common) catch return error.InvalidPrompt;
    if (value.object.get("_meta")) |metadata| {
        if (metadata != .object) return error.InvalidPrompt;
        _ = common.boundedJsonLength(
            metadata,
            limits.common.max_metadata_bytes,
            limits.common.max_json_depth,
        ) catch return error.InvalidPrompt;
    }
    const arguments_value = value.object.get("arguments");
    const argument_values: []const std.json.Value = if (arguments_value) |arguments| blk: {
        if (arguments != .array or arguments.array.items.len > limits.max_arguments) {
            return error.ArgumentLimitExceeded;
        }
        break :blk arguments.array.items;
    } else &.{};
    const arguments = try alloc.alloc(Argument, argument_values.len);
    var count: usize = 0;
    errdefer {
        for (arguments[0..count]) |*argument| argument.deinit(alloc);
        alloc.free(arguments);
    }
    for (argument_values, 0..) |argument_value, index| {
        arguments[index] = try parseArgument(alloc, argument_value, limits.common);
        for (arguments[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, arguments[index].name)) return error.DuplicateArgument;
        }
        count += 1;
    }
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_title = if (title) |item| try alloc.dupe(u8, item) else null;
    errdefer if (owned_title) |item| alloc.free(item);
    const owned_description = if (description) |item| try alloc.dupe(u8, item) else null;
    errdefer if (owned_description) |item| alloc.free(item);
    const icons_json = if (value.object.get("icons")) |icons|
        try common.stringifyValueAlloc(
            alloc,
            icons,
            limits.common.max_metadata_bytes,
            limits.common.max_json_depth,
        )
    else
        null;
    errdefer if (icons_json) |item| alloc.free(item);
    const metadata_json = if (value.object.get("_meta")) |metadata|
        try common.stringifyValueAlloc(
            alloc,
            metadata,
            limits.common.max_metadata_bytes,
            limits.common.max_json_depth,
        )
    else
        null;
    return .{
        .name = owned_name,
        .title = owned_title,
        .description = owned_description,
        .arguments = arguments,
        .icons_json = icons_json,
        .metadata_json = metadata_json,
    };
}

fn parseArgument(alloc: Allocator, value: std.json.Value, limits: common.Limits) Error!Argument {
    if (value != .object) return error.InvalidArgument;
    const name = common.requiredString(value.object, "name", limits.max_name_bytes) catch return error.InvalidArgument;
    const description = common.optionalString(value.object, "description", limits.max_description_bytes) catch return error.InvalidArgument;
    const required = if (value.object.get("required")) |required_value| blk: {
        if (required_value != .bool) return error.InvalidArgument;
        break :blk required_value.bool;
    } else false;
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_description = if (description) |item| try alloc.dupe(u8, item) else null;
    return .{ .name = owned_name, .description = owned_description, .required = required };
}

fn parseMessage(alloc: Allocator, value: std.json.Value, limits: Limits) Error!Message {
    if (value != .object) return error.InvalidMessage;
    const role_value = value.object.get("role") orelse return error.InvalidMessage;
    if (role_value != .string) return error.InvalidMessage;
    const role: Role = if (std.mem.eql(u8, role_value.string, "user"))
        .user
    else if (std.mem.eql(u8, role_value.string, "assistant"))
        .assistant
    else
        return error.InvalidMessage;
    const content = value.object.get("content") orelse return error.InvalidMessage;
    try common.validatePromptContent(alloc, content, limits.common);
    const type_value = content.object.get("type").?;
    const kind: ContentKind = if (std.mem.eql(u8, type_value.string, "text"))
        .text
    else if (std.mem.eql(u8, type_value.string, "image"))
        .image
    else if (std.mem.eql(u8, type_value.string, "audio"))
        .audio
    else if (std.mem.eql(u8, type_value.string, "resource_link"))
        .resource_link
    else
        .resource;
    return .{
        .role = role,
        .content_kind = kind,
        .content_json = try common.stringifyValueAlloc(
            alloc,
            content,
            limits.max_result_json_bytes,
            limits.common.max_json_depth,
        ),
    };
}

fn mapCommonListError(err: common.Error) Error {
    return switch (err) {
        error.ProtocolFailure => error.ProtocolFailure,
        error.UnsupportedResultType => error.UnsupportedResultType,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidListResult,
    };
}

fn lessPrompt(_: void, left: Prompt, right: Prompt) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn writeCompactJson(alloc: Allocator, writer: *std.Io.Writer, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

fn writeMetadata(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"io.modelcontextprotocol/related-task\":{\"taskId\":\"fx-test\"}}");
}

test "prompt pagination owns arguments and sorts stable names" {
    const alloc = std.testing.allocator;
    var builder = CatalogBuilder.init(alloc, .modern);
    defer builder.deinit(alloc);
    var first = try parseListPage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"prompts\":[{\"name\":\"review\",\"description\":\"Review code\",\"arguments\":[{\"name\":\"focus\",\"required\":true}]}],\"nextCursor\":\"next\",\"ttlMs\":100}}",
        .modern,
        .{},
    );
    defer first.deinit(alloc);
    try builder.appendPage(alloc, &first, 1000, .{});
    var second = try parseListPage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"prompts\":[{\"name\":\"explain\",\"arguments\":[]}],\"ttlMs\":50}}",
        .modern,
        .{},
    );
    defer second.deinit(alloc);
    try builder.appendPage(alloc, &second, 1010, .{});
    var catalog = try builder.finish(alloc);
    defer catalog.deinit(alloc);
    try std.testing.expectEqualStrings("explain", catalog.prompts[0].name);
    try std.testing.expectEqual(@as(u64, 1060), catalog.expires_at_ms);
    try std.testing.expectError(
        error.InvalidArguments,
        validateArgumentsJson(alloc, catalog.prompts[1], "{}", .{}),
    );
}

test "prompt get preserves every permitted content type" {
    const alloc = std.testing.allocator;
    var outcome = try parseGetOutcome(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"description\":\"fixture\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hello\"}},{\"role\":\"assistant\",\"content\":{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"aGVsbG8=\"}},{\"role\":\"user\",\"content\":{\"type\":\"audio\",\"mimeType\":\"audio/wav\",\"data\":\"aGVsbG8=\"}},{\"role\":\"assistant\",\"content\":{\"type\":\"resource_link\",\"uri\":\"git://repo\",\"name\":\"repo\"}},{\"role\":\"user\",\"content\":{\"type\":\"resource\",\"resource\":{\"uri\":\"memory://one\",\"text\":\"body\"}}}]}}",
        .modern,
        .{},
    );
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 5), outcome.complete.messages.len);
    try std.testing.expectEqual(ContentKind.resource, outcome.complete.messages[4].content_kind);
    try std.testing.expectError(
        error.MessageLimitExceeded,
        parseGetOutcome(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hello\"}}]}}",
            .modern,
            .{ .common = .{ .max_total_content_bytes = 4 } },
        ),
    );
}

test "prompt content preserves schema-valid empty text and zero-byte media" {
    const alloc = std.testing.allocator;
    var outcome = try parseGetOutcome(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"\"}},{\"role\":\"assistant\",\"content\":{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"\"}},{\"role\":\"user\",\"content\":{\"type\":\"audio\",\"mimeType\":\"audio/wav\",\"data\":\"\"}}]}}",
        .modern,
        .{},
    );
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), outcome.complete.messages.len);
    try std.testing.expect(std.mem.find(
        u8,
        outcome.complete.messages[0].content_json,
        "\"text\":\"\"",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        outcome.complete.messages[1].content_json,
        "\"data\":\"\"",
    ) != null);
}

test "prompt catalog metadata enforces the shared JSON depth boundary" {
    const alloc = std.testing.allocator;
    const limits = Limits{ .common = .{ .max_json_depth = 6 } };

    var below = try parseListPage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"prompts\":[{\"name\":\"below\",\"_meta\":{\"value\":1}}]}}",
        .modern,
        limits,
    );
    below.deinit(alloc);
    var at = try parseListPage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"prompts\":[{\"name\":\"at\",\"_meta\":{\"nested\":{\"value\":1}}}]}}",
        .modern,
        limits,
    );
    at.deinit(alloc);
    try std.testing.expectError(
        error.JsonDepthLimitExceeded,
        parseListPage(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"prompts\":[{\"name\":\"above\",\"_meta\":{\"nested\":{\"again\":{\"value\":1}}}}]}}",
            .modern,
            limits,
        ),
    );
}

test "prompt content enforces the shared JSON depth boundary" {
    const alloc = std.testing.allocator;
    const limits = Limits{ .common = .{ .max_json_depth = 7 } };

    var below = try parseGetOutcome(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"ok\",\"_meta\":{\"value\":1}}}]}}",
        .modern,
        limits,
    );
    below.deinit(alloc);
    var at = try parseGetOutcome(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"ok\",\"_meta\":{\"nested\":{\"value\":1}}}}]}}",
        .modern,
        limits,
    );
    at.deinit(alloc);
    try std.testing.expectError(
        error.JsonDepthLimitExceeded,
        parseGetOutcome(
            alloc,
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"no\",\"_meta\":{\"nested\":{\"again\":{\"value\":1}}}}}]}}",
            .modern,
            limits,
        ),
    );
}

test "prompt arguments enforce the shared JSON depth boundary" {
    const alloc = std.testing.allocator;
    var arguments = [_]Argument{.{ .name = @constCast("focus") }};
    const prompt = Prompt{
        .name = @constCast("review"),
        .arguments = &arguments,
    };
    const limits = Limits{ .common = .{ .max_json_depth = 1 } };
    try validateArgumentsJson(alloc, prompt, "{}", limits);
    try validateArgumentsJson(alloc, prompt, "{\"focus\":\"security\"}", limits);
    try std.testing.expectError(
        error.InvalidArguments,
        validateArgumentsJson(alloc, prompt, "{\"focus\":{\"nested\":\"no\"}}", limits),
    );
}

test "MRTR request state enforces the shared JSON depth boundary" {
    const alloc = std.testing.allocator;
    const limits = Limits{ .common = .{ .max_json_depth = 10 } };
    const below_response =
        \\{"jsonrpc":"2.0","id":1,"result":{"resultType":"input_required","inputRequests":{"confirm":{"method":"elicitation/create","params":{"message":"Continue?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}}}}},"requestState":{"a":{"b":{"c":{"d":{"e":{"f":{"g":1}}}}}}}}}
    ;
    var below = try parseGetOutcome(alloc, below_response, .modern, limits);
    below.deinit(alloc);

    const at_response =
        \\{"jsonrpc":"2.0","id":2,"result":{"resultType":"input_required","inputRequests":{"confirm":{"method":"elicitation/create","params":{"message":"Continue?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}}}}},"requestState":{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":1}}}}}}}}}}
    ;
    var at = try parseGetOutcome(alloc, at_response, .modern, limits);
    at.deinit(alloc);

    const above_response =
        \\{"jsonrpc":"2.0","id":3,"result":{"resultType":"input_required","inputRequests":{"confirm":{"method":"elicitation/create","params":{"message":"Continue?","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}}}}},"requestState":{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"i":1}}}}}}}}}}}
    ;
    try std.testing.expectError(
        error.JsonDepthLimitExceeded,
        parseGetOutcome(alloc, above_response, .modern, limits),
    );
}

test "prompt get request preserves exact MRTR continuation" {
    const alloc = std.testing.allocator;
    const request = try buildGetRequest(
        alloc,
        4,
        .modern,
        "review",
        "{\"focus\":\"security\"}",
        writeMetadata,
        "{\"choice\":\"continue\"}",
        "{\"opaque\":true}",
    );
    defer alloc.free(request);
    try std.testing.expect(std.mem.find(u8, request, "\"name\":\"review\"") != null);
    try std.testing.expect(std.mem.find(u8, request, "\"requestState\":{\"opaque\":true}") != null);
}

fn checkPromptCatalogAllocationFailures(alloc: Allocator) !void {
    var page = try parseListPage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"prompts\":[{\"name\":\"review\",\"title\":\"Review\",\"description\":\"Review code\",\"arguments\":[{\"name\":\"focus\",\"description\":\"Area\",\"required\":true}],\"icons\":[{\"src\":\"data:image/png;base64,AA==\"}],\"_meta\":{\"version\":1}}]}}",
        .modern,
        .{},
    );
    defer page.deinit(alloc);
    var builder = CatalogBuilder.init(alloc, .modern);
    defer builder.deinit(alloc);
    try builder.appendPage(alloc, &page, 1, .{});
    var catalog = try builder.finish(alloc);
    defer catalog.deinit(alloc);
}

test "prompt catalog construction is allocation failure safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPromptCatalogAllocationFailures,
        .{},
    );
}
