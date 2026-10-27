//! What every configured-provider transport checks and sends besides the
//! body: the credential against the definition's auth slot, and the
//! definition's extra headers with `!command` values resolved (D148).
const std = @import("std");
const definitions = @import("../core/config/configured_provider.zig");
const secret_command = @import("../core/config/secret_command.zig");
const Allocator = std.mem.Allocator;

/// Rejects a token the slot does not expect, a missing one it does, and bytes
/// no HTTP header may carry.
pub fn checkToken(definition: *const definitions.Definition, token: ?[]const u8) !void {
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (definition.auth) {
        .none => if (token != null and token.?.len != 0) return error.UnexpectedConfiguredProviderCredential,
        .bearer, .command, .login => if (token == null or token.?.len == 0) return error.MissingConfiguredProviderCredential,
    }
}

/// Resolved extra headers. Values are owned; names borrow the definition.
pub const Headers = struct {
    items: []std.http.Header = &.{},

    pub fn deinit(self: *Headers, alloc: Allocator) void {
        for (self.items) |header| alloc.free(header.value);
        alloc.free(self.items);
        self.* = .{};
    }
};

pub fn resolveHeaders(alloc: Allocator, definition: *const definitions.Definition) !Headers {
    const items = try alloc.alloc(std.http.Header, definition.headers.len);
    var resolved: usize = 0;
    errdefer {
        for (items[0..resolved]) |header| alloc.free(header.value);
        alloc.free(items);
    }
    for (definition.headers, items) |header, *out| {
        const value = secret_command.resolve(alloc, header.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ConfiguredHeaderCommandFailed,
        };
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) {
            alloc.free(value);
            return error.ConfiguredHeaderCommandFailed;
        };
        out.* = .{ .name = header.name, .value = value };
        resolved += 1;
    }
    return .{ .items = items };
}

test "configured request checks the slot and resolves header commands" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"k":{"protocol":"openai-chat-completions","base_url":"https://e.com","auth":{"type":"login"},"headers":{"X-Lit":"v","X-Cmd":"!printf from-command","X-Bang":"!!x"}},
        \\"n":{"protocol":"openai-chat-completions","base_url":"https://e.com","auth":{"type":"none"}}}
    );
    defer registry.deinit(alloc);
    const keyed = registry.get("k").?;
    try checkToken(keyed, "sk-or-1");
    try std.testing.expectError(error.MissingConfiguredProviderCredential, checkToken(keyed, null));
    try std.testing.expectError(error.InvalidConfiguredProviderCredential, checkToken(keyed, "a b"));
    try checkToken(registry.get("n").?, "");
    try std.testing.expectError(error.UnexpectedConfiguredProviderCredential, checkToken(registry.get("n").?, "k"));
    var headers = try resolveHeaders(alloc, keyed);
    defer headers.deinit(alloc);
    for (headers.items) |header| {
        const expected = if (std.mem.eql(u8, header.name, "X-Lit")) "v" else if (std.mem.eql(u8, header.name, "X-Cmd")) "from-command" else "!x";
        try std.testing.expectEqualStrings(expected, header.value);
    }
}
