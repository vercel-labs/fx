const std = @import("std");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("secret.zig");
const opencode_session = @import("opencode_session.zig");

const Allocator = std.mem.Allocator;
pub const auth_url = "https://opencode.ai/auth";

pub fn productName(kind: opencode_session.Kind) []const u8 {
    return switch (kind) {
        .zen => "OpenCode Zen",
        .go => "OpenCode Go",
    };
}

pub fn runLogin(alloc: Allocator, kind: opencode_session.Kind) !void {
    if (comptime host_target.is_wasm) return error.OpenCodeAuthUnavailable;
    try writeStdout("Get an API key at ");
    try writeStdout(auth_url);
    try writeStdout("\nPaste the ");
    try writeStdout(productName(kind));
    try writeStdout(" API key, then press Enter.\nAPI key: ");

    const input = try readLine(alloc);
    defer secret.zeroAndFree(alloc, input);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!opencode_session.validApiKey(trimmed)) return error.InvalidOpenCodeApiKey;

    const owned = try alloc.dupe(u8, trimmed);
    var session = opencode_session.Session{ .api_key = owned };
    defer session.deinit(alloc);
    try opencode_session.saveNewSession(alloc, kind, session);
    try writeStdout("Signed in to ");
    try writeStdout(productName(kind));
    try writeStdout(".\n");
}

pub fn saveApiKey(alloc: Allocator, kind: opencode_session.Kind, api_key: []const u8) !void {
    const trimmed = std.mem.trim(u8, api_key, " \t\r\n");
    if (!opencode_session.validApiKey(trimmed)) return error.InvalidOpenCodeApiKey;
    const owned = try alloc.dupe(u8, trimmed);
    var session = opencode_session.Session{ .api_key = owned };
    defer session.deinit(alloc);
    try opencode_session.saveNewSession(alloc, kind, session);
}

fn readLine(alloc: Allocator) ![]u8 {
    var read_buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io_mod.getIo(), &read_buf);
    const line = reader.interface.takeDelimiter('\n') catch return try alloc.dupe(u8, "");
    return try alloc.dupe(u8, line orelse "");
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}
