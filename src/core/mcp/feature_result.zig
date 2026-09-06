const std = @import("std");
const resources_feature = @import("features/resources.zig");
const prompts_feature = @import("features/prompts.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const image_data = @import("../images/image_data.zig");
const types = @import("../shared/types.zig");
const tool_content = @import("../tooling/tool_content.zig");
const Allocator = std.mem.Allocator;

pub const ResourceSummary = struct {
    server_name: []u8,
    uri: []u8,
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    mime_type: ?[]u8 = null,
    is_template: bool = false,

    pub fn deinit(self: *ResourceSummary, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.uri);
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        if (self.mime_type) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const ResourceCatalogResult = struct {
    items: []ResourceSummary,

    pub fn deinit(self: *ResourceCatalogResult, alloc: Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = undefined;
    }
};

pub const PromptSummary = struct {
    server_name: []u8,
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    arguments: []prompts_feature.Argument,

    pub fn deinit(self: *PromptSummary, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        for (self.arguments) |*argument| argument.deinit(alloc);
        alloc.free(self.arguments);
        self.* = undefined;
    }
};

pub const PromptCatalogResult = struct {
    items: []PromptSummary,

    pub fn deinit(self: *PromptCatalogResult, alloc: Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = undefined;
    }
};

pub const FeatureCallOptions = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    input_responder: ?tool_mcp_runtime.InputResponder = null,
    access: tool_mcp_runtime.Access = .unrestricted,
    protocol_diagnostic: ?*?[]u8 = null,
};

pub const ResourceReadResult = struct {
    server_name: []u8,
    uri: []u8,
    contents: []resources_feature.ResourceContent,
    untrusted: bool = true,

    pub fn deinit(self: *ResourceReadResult, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.uri);
        for (self.contents) |*content| content.deinit(alloc);
        alloc.free(self.contents);
        self.* = undefined;
    }
};

pub const PromptGetResult = struct {
    server_name: []u8,
    name: []u8,
    description: ?[]u8,
    messages: []prompts_feature.Message,
    untrusted: bool = true,

    pub fn deinit(self: *PromptGetResult, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.name);
        if (self.description) |value| alloc.free(value);
        for (self.messages) |*message| message.deinit(alloc);
        alloc.free(self.messages);
        self.* = undefined;
    }
};

pub const CompletionResult = struct {
    server_name: []u8,
    values: []const []u8,
    total: ?u64,
    has_more: ?bool,

    pub fn deinit(self: *CompletionResult, alloc: Allocator) void {
        alloc.free(self.server_name);
        for (self.values) |value| alloc.free(value);
        alloc.free(self.values);
        self.* = undefined;
    }
};

pub fn renderResourceCatalogForModel(
    alloc: Allocator,
    action: tool_mcp_runtime.FeatureAction,
    server_name: []const u8,
    result: ResourceCatalogResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, action, server_name);
    try out.writer.writeAll(",\"items\":[");
    for (result.items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"server\":");
        try std.json.Stringify.value(item.server_name, .{}, &out.writer);
        try out.writer.writeAll(",\"identity\":");
        try std.json.Stringify.value(item.uri, .{}, &out.writer);
        try out.writer.writeAll(",\"name\":");
        try std.json.Stringify.value(item.name, .{}, &out.writer);
        if (item.title) |value| {
            try out.writer.writeAll(",\"title\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        if (item.description) |value| {
            try out.writer.writeAll(",\"description\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        if (item.mime_type) |value| {
            try out.writer.writeAll(",\"mimeType\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        try out.writer.writeAll(",\"template\":");
        try out.writer.writeAll(if (item.is_template) "true" else "false");
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

pub fn renderResourceReadForModel(alloc: Allocator, result: ResourceReadResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, .resource_read, result.server_name);
    try out.writer.writeAll(",\"identity\":");
    try std.json.Stringify.value(result.uri, .{}, &out.writer);
    try out.writer.writeAll(",\"contents\":[");
    for (result.contents, 0..) |content, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"uri\":");
        try std.json.Stringify.value(content.uri, .{}, &out.writer);
        if (content.mime_type) |value| {
            try out.writer.writeAll(",\"mimeType\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        if (content.annotations_json) |value| {
            try out.writer.writeAll(",\"annotations\":");
            try out.writer.writeAll(value);
        }
        if (content.metadata_json) |value| {
            try out.writer.writeAll(",\"_meta\":");
            try out.writer.writeAll(value);
        }
        switch (content.data) {
            .text => |value| {
                try out.writer.writeAll(",\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
            },
            .blob => {
                try out.writer.writeAll(",\"type\":\"blob\",\"delivery\":");
                const supported = if (content.mime_type) |mime| image_data.supportedMediaType(mime) else false;
                try std.json.Stringify.value(if (supported) "image content" else "binary resource content was not sent to the model", .{}, &out.writer);
            },
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

pub fn renderPromptCatalogForModel(
    alloc: Allocator,
    server_name: []const u8,
    result: PromptCatalogResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, .prompt_list, server_name);
    try out.writer.writeAll(",\"items\":[");
    for (result.items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"server\":");
        try std.json.Stringify.value(item.server_name, .{}, &out.writer);
        try out.writer.writeAll(",\"identity\":");
        try std.json.Stringify.value(item.name, .{}, &out.writer);
        if (item.title) |value| {
            try out.writer.writeAll(",\"title\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        if (item.description) |value| {
            try out.writer.writeAll(",\"description\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        try out.writer.writeAll(",\"arguments\":[");
        for (item.arguments, 0..) |argument, argument_index| {
            if (argument_index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"name\":");
            try std.json.Stringify.value(argument.name, .{}, &out.writer);
            try out.writer.writeAll(",\"required\":");
            try out.writer.writeAll(if (argument.required) "true" else "false");
            if (argument.description) |value| {
                try out.writer.writeAll(",\"description\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

pub fn renderPromptGetForModel(alloc: Allocator, result: PromptGetResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, .prompt_get, result.server_name);
    try out.writer.writeAll(",\"identity\":");
    try std.json.Stringify.value(result.name, .{}, &out.writer);
    if (result.description) |value| {
        try out.writer.writeAll(",\"description\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeAll(",\"messages\":[");
    for (result.messages, 0..) |message, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"role\":");
        try std.json.Stringify.value(@tagName(message.role), .{}, &out.writer);
        try out.writer.writeAll(",\"contentKind\":");
        try std.json.Stringify.value(@tagName(message.content_kind), .{}, &out.writer);
        try out.writer.writeAll(",\"content\":");
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, message.content_json, .{ .parse_numbers = false });
        defer parsed.deinit();
        try tool_content.projectMediaForText(parsed.arena.allocator(), &parsed.value);
        try std.json.Stringify.value(parsed.value, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

pub fn renderCompletionForModel(
    alloc: Allocator,
    action: tool_mcp_runtime.FeatureAction,
    request: tool_mcp_runtime.FeatureRequest,
    result: CompletionResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, action, result.server_name);
    try out.writer.writeAll(",\"identity\":");
    try std.json.Stringify.value(request.identity, .{}, &out.writer);
    try out.writer.writeAll(",\"argument\":");
    try std.json.Stringify.value(request.argument_name, .{}, &out.writer);
    try out.writer.writeAll(",\"values\":[");
    for (result.values, 0..) |value, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeByte(']');
    if (result.total) |value| try out.writer.print(",\"total\":{d}", .{value});
    if (result.has_more) |value| {
        try out.writer.writeAll(",\"hasMore\":");
        try out.writer.writeAll(if (value) "true" else "false");
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeFeatureEnvelopeStart(
    writer: *std.Io.Writer,
    action: tool_mcp_runtime.FeatureAction,
    server_name: []const u8,
) !void {
    try writer.writeAll("{\"trust\":\"untrusted_external\",\"authority\":\"none\",\"action\":");
    try std.json.Stringify.value(@tagName(action), .{}, writer);
    try writer.writeAll(",\"server\":");
    try std.json.Stringify.value(server_name, .{}, writer);
}

pub fn resourceImages(alloc: Allocator, result: ResourceReadResult) ![]types.ToolImage {
    var images = image_data.ImageList{ .alloc = alloc };
    defer images.deinit();
    for (result.contents) |content| {
        const mime = content.mime_type orelse continue;
        if (content.data == .blob and image_data.supportedMediaType(mime)) try images.append(content.data.blob, mime);
    }
    return images.take();
}

pub fn promptImages(alloc: Allocator, result: PromptGetResult) ![]types.ToolImage {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var content: std.ArrayList(std.json.Value) = .empty;
    for (result.messages) |message| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), message.content_json, .{ .parse_numbers = false });
        if (value == .array) try content.appendSlice(arena.allocator(), value.array.items) else try content.append(arena.allocator(), value);
    }
    return image_data.parseToolImages(alloc, content.items);
}
