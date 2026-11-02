const std = @import("std");
const catalog_freshness = @import("catalog_freshness.zig");
const text_utils = @import("../shared/text_utils.zig");
const Allocator = std.mem.Allocator;

const max_tool_display_title_bytes: usize = 200;

/// Who a tool call went to, as an editor shows it.
pub const ToolIdentity = struct {
    server: []u8,
    /// The tool's name on its server, before fx exposes it to the model.
    tool: []u8,
    /// The server's display title, when it declares one.
    title: ?[]u8 = null,

    pub fn deinit(self: ToolIdentity, alloc: Allocator) void {
        alloc.free(self.server);
        alloc.free(self.tool);
        if (self.title) |title| alloc.free(title);
    }
};

/// Returns the displayable part of a server-provided tool title, or null when
/// it has none.
pub fn usableDisplayTitle(title: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, title, " \t\r\n");
    if (trimmed.len == 0 or !std.unicode.utf8ValidateSlice(trimmed)) return null;
    for (trimmed) |byte| if (byte < 0x20 or byte == 0x7f) return null;
    return text_utils.utf8PrefixByBytes(trimmed, max_tool_display_title_bytes);
}

/// A tool's title, else its `annotations.title`; owned by the caller.
pub fn displayTitle(alloc: Allocator, tool: McpTool) Allocator.Error!?[]u8 {
    if (tool.title) |title| {
        if (usableDisplayTitle(title)) |value| return try alloc.dupe(u8, value);
    }
    const annotations = tool.annotations_json orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, annotations, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const title = parsed.value.object.get("title") orelse return null;
    if (title != .string) return null;
    const value = usableDisplayTitle(title.string) orelse return null;
    return try alloc.dupe(u8, value);
}

pub const McpTool = struct {
    original_name: []const u8,
    prefixed_name: []u8,
    title: ?[]u8 = null,
    description: []u8,
    input_schema_json: []u8,
    output_schema_json: ?[]u8 = null,
    icons_json: ?[]u8 = null,
    annotations_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,
    tags: []const []u8,
};

pub fn digestTools(tools: []const McpTool) catalog_freshness.Digest {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hasher = Sha256.init(.{});
    for (tools) |tool| {
        hashField(&hasher, tool.original_name);
        hashField(&hasher, tool.prefixed_name);
        hashOptionalField(&hasher, tool.title);
        hashField(&hasher, tool.description);
        hashField(&hasher, tool.input_schema_json);
        hashOptionalField(&hasher, tool.output_schema_json);
        hashOptionalField(&hasher, tool.icons_json);
        hashOptionalField(&hasher, tool.annotations_json);
        hashOptionalField(&hasher, tool.metadata_json);
        for (tool.tags) |tag| hashField(&hasher, tag);
    }
    var result: catalog_freshness.Digest = undefined;
    hasher.final(&result);
    return result;
}

/// What a tool was when the model saw it: its fields and its server's
/// instructions.
pub fn definitionDigest(tool: McpTool, instructions: ?[]const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&digestTools(&.{tool}));
    hashOptionalField(&hasher, instructions);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hasher.update(&length);
    hasher.update(value);
}

fn hashOptionalField(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: ?[]const u8,
) void {
    const present = [_]u8{@intFromBool(value != null)};
    hasher.update(&present);
    if (value) |bytes| hashField(hasher, bytes);
}
