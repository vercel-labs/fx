//! Client-provided system prompt for ACP sessions: ACP v1's `systemPrompt` in
//! `append` mode. The prompt is validated before a session exists, persisted
//! with the session, restored on load and resume, and delivered in the system
//! slot after fx's own instructions.

const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const session_child_store = @import("../core/session/session_child_store.zig");

const Allocator = std.mem.Allocator;

pub const max_bytes: usize = 64 * 1024;
/// The side file a v1 session keeps the prompt in.
pub const file_name = "system-prompt.txt";
const block_separator = "\n\n";

pub const ParseError = Allocator.Error || error{
    InvalidParams,
    InvalidSystemPrompt,
    EmptySystemPrompt,
    BlankSystemPrompt,
    UnsupportedSystemPromptBlock,
    SystemPromptTooLarge,
    InvalidSystemPromptText,
    MissingSystemPromptMode,
    UnsupportedSystemPromptMode,
};

/// Returns the owned prompt from `session/new` params, or null when the params
/// omit `systemPrompt` or set it to null. ACP v1's `systemPrompt` is
/// `{"mode": ..., "content": [...]}`; fx supports the `append` mode, which every
/// Agent that advertises the capability must, and text content blocks.
pub fn parse(alloc: Allocator, params_raw: ?[]const u8) ParseError!?[]u8 {
    const raw = params_raw orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidParams;
    const params = parsed.value.object;

    const prompt = params.get("systemPrompt") orelse return null;
    if (prompt == .null) return null;
    if (prompt != .object) return error.InvalidSystemPrompt;
    const mode = prompt.object.get("mode") orelse return error.MissingSystemPromptMode;
    if (mode != .string or !std.mem.eql(u8, mode.string, "append")) return error.UnsupportedSystemPromptMode;
    return try joinTextBlocks(alloc, prompt.object.get("content") orelse return error.InvalidSystemPrompt);
}

pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "Out of memory",
        error.InvalidParams => "Invalid params",
        error.InvalidSystemPrompt => "systemPrompt must be an object with a mode and a content array",
        error.EmptySystemPrompt => "systemPrompt.content must contain at least one content block",
        error.BlankSystemPrompt => "systemPrompt text cannot be empty",
        error.UnsupportedSystemPromptBlock => "systemPrompt supports text content blocks only",
        error.SystemPromptTooLarge => "systemPrompt exceeds the 64 KiB limit",
        error.InvalidSystemPromptText => "systemPrompt text must be valid UTF-8 without NUL bytes",
        error.MissingSystemPromptMode => "systemPrompt.mode is required",
        error.UnsupportedSystemPromptMode => "systemPrompt.mode supports only \"append\"",
    };
}

fn joinTextBlocks(alloc: Allocator, blocks: std.json.Value) ParseError![]u8 {
    if (blocks != .array) return error.InvalidSystemPrompt;
    if (blocks.array.items.len == 0) return error.EmptySystemPrompt;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    for (blocks.array.items, 0..) |block, index| {
        if (block != .object) return error.UnsupportedSystemPromptBlock;
        const kind = block.object.get("type") orelse return error.UnsupportedSystemPromptBlock;
        const value = block.object.get("text") orelse return error.UnsupportedSystemPromptBlock;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text") or value != .string) {
            return error.UnsupportedSystemPromptBlock;
        }
        // `text` never exceeds `max_bytes`, so the subtraction cannot wrap.
        const separator_len: usize = if (index == 0) 0 else block_separator.len;
        const added = value.string.len + separator_len;
        if (added > max_bytes - text.items.len) return error.SystemPromptTooLarge;
        if (index > 0) try text.appendSlice(alloc, block_separator);
        try text.appendSlice(alloc, value.string);
    }
    if (std.mem.trim(u8, text.items, " \t\r\n").len == 0) return error.BlankSystemPrompt;
    if (!validText(text.items)) return error.InvalidSystemPromptText;
    return text.toOwnedSlice(alloc);
}

fn validText(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text) and std.mem.findScalar(u8, text, 0) == null;
}

/// Stores the prompt with its session so load and resume restore it.
pub fn persist(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    text: []const u8,
) !void {
    var entry = try capability.atomicReplace(alloc, .client_context, file_name, text);
    entry.deinit(alloc);
}

/// Returns the owned persisted prompt, or null when the session has none.
pub fn load(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !?[]u8 {
    var file = capability.openFileReadOnly(alloc, .client_context, file_name) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.deinit();
    // The reader rejects a file that reaches its limit, so allow one byte
    // more to accept a prompt of exactly `max_bytes`.
    const text = try file.readToEnd(alloc, max_bytes + 1);
    errdefer alloc.free(text);
    if (text.len == 0 or !validText(text)) return error.InvalidSystemPromptText;
    return text;
}

/// Joins host instructions with the client prompt for the system slot, after
/// fx's built-in instructions. Caller owns the result.
pub fn compose(alloc: Allocator, host_instructions: []const u8, client_prompt: []const u8) ![]u8 {
    if (client_prompt.len == 0) return alloc.dupe(u8, host_instructions);
    const separator = if (host_instructions.len > 0) "\n\n" else "";
    return std.mem.concat(alloc, u8, &.{
        host_instructions,
        separator,
        "<client_instructions>\n",
        client_prompt,
        "\n</client_instructions>",
    });
}

test "client system prompt parses ACP v1 text blocks in append mode" {
    const alloc = std.testing.allocator;
    const text = (try parse(alloc,
        \\{"cwd":"/tmp","systemPrompt":{"mode":"append","content":[{"type":"text","text":"You run inside Mini."},{"type":"text","text":"Use browser tools."}]}}
    )).?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("You run inside Mini.\n\nUse browser tools.", text);

    try std.testing.expect((try parse(alloc, "{\"cwd\":\"/tmp\"}")) == null);
    try std.testing.expect((try parse(alloc, "{\"cwd\":\"/tmp\",\"systemPrompt\":null}")) == null);
    // The removed forms are no longer read: a `_meta.fx` copy and a root mode.
    try std.testing.expect((try parse(alloc,
        \\{"_meta":{"fx":{"systemPrompt":[{"type":"text","text":"From meta."}]}},"systemPromptMode":"append"}
    )) == null);
}

test "client system prompt rejects invalid combinations before a session exists" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, expected: ParseError }{
        .{ .json = "{\"systemPrompt\":{\"mode\":\"append\",\"content\":[]}}", .expected = error.EmptySystemPrompt },
        .{ .json = "{\"systemPrompt\":{\"mode\":\"append\",\"content\":[{\"type\":\"text\",\"text\":\" \"}]}}", .expected = error.BlankSystemPrompt },
        .{ .json = "{\"systemPrompt\":\"text\"}", .expected = error.InvalidSystemPrompt },
        // The older RFD shape, a bare array of blocks.
        .{ .json = "{\"systemPrompt\":[{\"type\":\"text\",\"text\":\"x\"}]}", .expected = error.InvalidSystemPrompt },
        .{ .json = "{\"systemPrompt\":{\"mode\":\"append\"}}", .expected = error.InvalidSystemPrompt },
        .{ .json = "{\"systemPrompt\":{\"mode\":\"append\",\"content\":\"x\"}}", .expected = error.InvalidSystemPrompt },
        .{ .json = "{\"systemPrompt\":{\"mode\":\"append\",\"content\":[{\"type\":\"image\",\"data\":\"x\"}]}}", .expected = error.UnsupportedSystemPromptBlock },
        .{ .json = "{\"systemPrompt\":{\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}}", .expected = error.MissingSystemPromptMode },
        .{ .json = "{\"systemPrompt\":{\"mode\":\"override\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}}", .expected = error.UnsupportedSystemPromptMode },
        .{ .json = "{\"systemPrompt\":{\"mode\":\"_fx\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}}", .expected = error.UnsupportedSystemPromptMode },
        .{ .json = "{\"systemPrompt\":{\"mode\":\"append\",\"content\":[{\"type\":\"text\",\"text\":\"a\\u0000b\"}]}}", .expected = error.InvalidSystemPromptText },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, parse(alloc, case.json));
    }

    const oversized = try alloc.alloc(u8, max_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    const json = try alloc.print("{{\"systemPrompt\":{{\"mode\":\"append\",\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{oversized});
    defer alloc.free(json);
    try std.testing.expectError(error.SystemPromptTooLarge, parse(alloc, json));
}

test "client system prompt composes after host instructions" {
    const alloc = std.testing.allocator;
    const only_host = try compose(alloc, "host", "");
    defer alloc.free(only_host);
    try std.testing.expectEqualStrings("host", only_host);

    const both = try compose(alloc, "host", "client");
    defer alloc.free(both);
    try std.testing.expectEqualStrings("host\n\n<client_instructions>\nclient\n</client_instructions>", both);

    const only_client = try compose(alloc, "", "client");
    defer alloc.free(only_client);
    try std.testing.expectEqualStrings("<client_instructions>\nclient\n</client_instructions>", only_client);
}

test "client system prompt of exactly the size limit survives a restore" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Session directories must be private for the child store to open them.
    try tmp.dir.createDir(std.testing.io, "session", std.Io.File.Permissions.fromMode(0o700));
    var session_dir = try tmp.dir.openDir(std.testing.io, "session", .{ .iterate = true, .follow_symlinks = false });
    defer session_dir.close(std.testing.io);
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(alloc, session_dir, session_path, .writable, .{});
    defer capability.deinit();

    const text = try alloc.alloc(u8, max_bytes);
    defer alloc.free(text);
    @memset(text, 'a');
    try persist(alloc, &capability, text);
    const restored = (try load(alloc, &capability)).?;
    defer alloc.free(restored);
    try std.testing.expectEqual(max_bytes, restored.len);
}
