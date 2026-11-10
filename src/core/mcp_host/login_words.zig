//! Why an MCP server needs a login, and the words for it. Every surface that
//! says it, `fx mcp show` and its JSON, the `/mcp` status line, `/trace`,
//! the model's `capability_search` answer, and the sign-in's own report, gets
//! the words from here, so they can't drift apart.
//!
//! The reason is the server's own answer, so its text is untrusted: it is
//! made terminal-safe and cut where it is written, never earlier. Pure, and
//! it imports only the standard library and `text_utils`.
//!
//! `tests/tla/mcp_host/SignIn.tla` says when each reason can happen.
const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

/// The longest `error` the server names that fx keeps, and the longest
/// `error_description`: the engine's bounds (`src/mcp/auth/discovery.zig`).
pub const max_code_bytes = 64;
pub const max_description_bytes = 240;

pub const Reason = struct {
    kind: Kind = .none,
    /// `login_refused`: the `error` and `error_description` the server's
    /// 401 named, or null when it named none. `refresh_refused`: the
    /// authorization server's error. Borrowed from whoever made the reason.
    code: ?[]const u8 = null,
    description: ?[]const u8 = null,

    pub const Kind = enum {
        /// No login is held, or nothing more is known: the words say `needs login`.
        none,
        /// The server refused the login fx sent: a 401 to a request that
        /// carried its token, which no refresh could fix.
        login_refused,
        /// The authorization server refused the refresh that would have
        /// kept the login. The words stay as they were.
        refresh_refused,
        /// The server wants more scopes than the login has.
        more_scopes,
    };
};

/// A reason kept in place, so a server's flags hold it without an
/// allocation: the text is cut at the bounds.
pub const Held = struct {
    kind: Reason.Kind = .none,
    code_len: u8 = 0,
    code: [max_code_bytes]u8 = undefined,
    description_len: u16 = 0,
    description: [max_description_bytes]u8 = undefined,

    pub fn set(h: *Held, reason: Reason) void {
        h.* = .{ .kind = reason.kind };
        if (reason.code) |text| {
            h.code_len = @intCast(@min(text.len, h.code.len));
            @memcpy(h.code[0..h.code_len], text[0..h.code_len]);
        }
        if (reason.description) |text| {
            h.description_len = @intCast(@min(text.len, h.description.len));
            @memcpy(h.description[0..h.description_len], text[0..h.description_len]);
        }
    }

    pub fn clear(h: *Held) void {
        h.kind = .none;
        h.code_len = 0;
        h.description_len = 0;
    }

    /// The reason, borrowing `h`.
    pub fn view(h: *const Held) Reason {
        return .{
            .kind = h.kind,
            .code = if (h.code_len > 0) h.code[0..h.code_len] else null,
            .description = if (h.description_len > 0) h.description[0..h.description_len] else null,
        };
    }
};

/// `reason` with its text copied into `alloc`.
pub fn copy(alloc: Allocator, reason: Reason) Allocator.Error!Reason {
    return .{
        .kind = reason.kind,
        .code = if (reason.code) |text| try alloc.dupe(u8, text) else null,
        .description = if (reason.description) |text| try alloc.dupe(u8, text) else null,
    };
}

/// Which login the server refused.
pub const Which = enum { saved, new };

/// `NAME refused the saved login (invalid_token: No authorization provided)`,
/// with no closing period, so a caller puts it in a sentence. Without the
/// server's words it is `NAME refused the saved login`. Null when the
/// reason isn't a refused login. The server's words are terminal-safe and cut
/// at their bounds.
pub fn refusal(arena: Allocator, name: []const u8, reason: Reason, which: Which) Allocator.Error!?[]const u8 {
    if (reason.kind != .login_refused) return null;
    const server = try safe(arena, name, 160);
    const what = switch (which) {
        .saved => "saved",
        .new => "new",
    };
    const code = if (reason.code) |text| try safe(arena, text, max_code_bytes) else "";
    const description = if (reason.description) |text| try safe(arena, text, max_description_bytes) else "";
    if (code.len > 0 and description.len > 0) return try arena.print("{s} refused the {s} login ({s}: {s})", .{ server, what, code, description });
    if (code.len > 0 or description.len > 0) return try arena.print("{s} refused the {s} login ({s})", .{ server, what, if (code.len > 0) code else description });
    return try arena.print("{s} refused the {s} login", .{ server, what });
}

/// What a server that waits for a login is short of, in a few words, for the
/// status line and the `/trace` problem: the refusal, or `needs login`.
pub fn attention(reason: Reason) []const u8 {
    return switch (reason.kind) {
        .login_refused => "refused the saved login",
        .none, .refresh_refused, .more_scopes => "needs login",
    };
}

/// The line `fx mcp show` and its JSON `error` carry for a server that needs
/// a login: the refusal with a closing period, or null when the reason adds
/// nothing to `needs login`.
pub fn errorText(arena: Allocator, name: []const u8, reason: Reason) Allocator.Error!?[]const u8 {
    const sentence = try refusal(arena, name, reason, .saved) orelse return null;
    return try arena.print("{s}.", .{sentence});
}

fn safe(arena: Allocator, raw: []const u8, max: usize) Allocator.Error![]const u8 {
    return (try text_utils.encodeTerminalSafeInline(arena, raw, max)).bytes;
}

/// An `error` that is a plain token, which may go in a log; anything else is
/// not named there.
pub fn isLogSafeCode(code: []const u8) bool {
    if (code.len == 0 or code.len > max_code_bytes) return false;
    for (code) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    return true;
}

const testing = std.testing;

test "a refused login names the server's error and description" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full: Reason = .{ .kind = .login_refused, .code = "invalid_token", .description = "No authorization provided" };
    try testing.expectEqualStrings("fixture refused the saved login (invalid_token: No authorization provided)", (try refusal(a, "fixture", full, .saved)).?);
    try testing.expectEqualStrings("fixture refused the new login (invalid_token: No authorization provided)", (try refusal(a, "fixture", full, .new)).?);
    try testing.expectEqualStrings("fixture refused the saved login (invalid_token: No authorization provided).", (try errorText(a, "fixture", full)).?);
    try testing.expectEqualStrings("fixture refused the saved login (invalid_token)", (try refusal(a, "fixture", .{ .kind = .login_refused, .code = "invalid_token" }, .saved)).?);
    try testing.expectEqualStrings("fixture refused the saved login (No authorization provided)", (try refusal(a, "fixture", .{ .kind = .login_refused, .description = "No authorization provided" }, .saved)).?);
    try testing.expectEqualStrings("fixture refused the saved login", (try refusal(a, "fixture", .{ .kind = .login_refused }, .saved)).?);
    try testing.expectEqualStrings("refused the saved login", attention(full));
}

test "the other reasons add nothing to needs login" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Reason.Kind{ .none, .refresh_refused, .more_scopes }) |kind| {
        const reason: Reason = .{ .kind = kind, .code = "invalid_grant" };
        try testing.expectEqual(@as(?[]const u8, null), try refusal(a, "fixture", reason, .saved));
        try testing.expectEqual(@as(?[]const u8, null), try errorText(a, "fixture", reason));
        try testing.expectEqualStrings("needs login", attention(reason));
    }
}

test "the server's words are terminal-safe and bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rude: Reason = .{ .kind = .login_refused, .code = "bad\x1b[31m", .description = "line\nbreak \x7f \xc2\x9b end" };
    const text = (try refusal(a, "fixture", rude, .saved)).?;
    for (text) |c| try testing.expect(c >= 0x20 and c < 0x7f);
    try testing.expect(std.mem.startsWith(u8, text, "fixture refused the saved login ("));
    const long: Reason = .{ .kind = .login_refused, .code = "invalid_token", .description = text_utils.repeat("x", 5000) };
    const cut = (try refusal(a, "fixture", long, .saved)).?;
    try testing.expect(cut.len < 400);
}

test "a held reason keeps its text in place, cut at the bounds" {
    var held: Held = .{};
    held.set(.{ .kind = .login_refused, .code = "invalid_token", .description = "No authorization provided" });
    const reason = held.view();
    try testing.expectEqual(Reason.Kind.login_refused, reason.kind);
    try testing.expectEqualStrings("invalid_token", reason.code.?);
    try testing.expectEqualStrings("No authorization provided", reason.description.?);
    held.set(.{ .kind = .login_refused, .code = text_utils.repeat("c", 500), .description = text_utils.repeat("d", 500) });
    try testing.expectEqual(@as(usize, max_code_bytes), held.view().code.?.len);
    try testing.expectEqual(@as(usize, max_description_bytes), held.view().description.?.len);
    held.clear();
    try testing.expectEqual(Reason.Kind.none, held.view().kind);
    try testing.expectEqual(@as(?[]const u8, null), held.view().description);
}

test "only a plain token is named in a log" {
    try testing.expect(isLogSafeCode("invalid_token"));
    try testing.expect(!isLogSafeCode(""));
    try testing.expect(!isLogSafeCode("bad code"));
    try testing.expect(!isLogSafeCode("a\x1b"));
    try testing.expect(!isLogSafeCode(text_utils.repeat("x", 65)));
}
