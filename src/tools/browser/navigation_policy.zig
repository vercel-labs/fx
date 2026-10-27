//! The domain policy every navigation the browser tool performs answers to
//! (D235): the one `open` meets at admission (D198). An http(s) URL answers
//! to web_fetch's `domain:<host>` rules; a deny refuses it, and so does an
//! ask, since a script cannot stop to ask the person (`open` can). Other
//! schemes than about:blank are refused, as `open` refuses them.
const std = @import("std");
const types = @import("../../core/shared/types.zig");
const permissions = @import("../../core/permissions/permissions.zig");
const browser_mod = @import("../../core/browser/browser.zig");

const Allocator = std.mem.Allocator;

pub const Policy = struct {
    /// The configured rules; empty in full access, as admission skips them.
    rules: types.PermissionRuleSet = .{},

    pub fn guard(self: *const Policy) browser_mod.NavigationGuard {
        return .{ .ctx = self, .refuse_fn = refuseErased };
    }

    fn refuseErased(ctx: *const anyopaque, alloc: Allocator, url: []const u8) ?[]u8 {
        const self: *const Policy = @ptrCast(@alignCast(ctx));
        return self.refusal(alloc, url) catch null;
    }

    /// Why `url` may not load, owned by `alloc`, or null when it may.
    pub fn refusal(self: *const Policy, alloc: Allocator, url: []const u8) Allocator.Error!?[]u8 {
        if (std.mem.eql(u8, url, "about:blank")) return null;
        const web = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
        if (!web) return try alloc.print("{s} is not an http(s) URL; the browser tool loads only web pages", .{shortUrl(url)});
        const target = permissions.webFetchDomainTargetForUrl(alloc, url) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return try alloc.print("{s} has no host the domain rules can check", .{shortUrl(url)}),
        };
        defer alloc.free(target);
        return switch (permissions.ruleDecisionForPermissionPattern(self.rules, permissions.web_fetch_permission, target, .none)) {
            .deny => try alloc.print("{s} is denied by the web_fetch rule for {s}", .{ shortUrl(url), target }),
            .ask => try alloc.print("{s} needs approval under the web_fetch rule for {s}; open it with the browser tool's open action, which asks", .{ shortUrl(url), target }),
            else => null,
        };
    }
};

fn shortUrl(url: []const u8) []const u8 {
    return url[0..@min(url.len, 200)];
}

test "navigations answer to web_fetch domain rules and refuse other schemes" {
    const testing = std.testing;
    var rules = [_]types.PermissionRule{
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:blocked.example"), .action = .deny },
        .{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:careful.example"), .action = .ask },
    };
    const policy: Policy = .{ .rules = .{ .rules = rules[0..] } };
    const denied = (try policy.refusal(testing.allocator, "https://blocked.example/login")).?;
    defer testing.allocator.free(denied);
    try testing.expectEqualStrings("https://blocked.example/login is denied by the web_fetch rule for domain:blocked.example", denied);
    const asked = (try policy.refusal(testing.allocator, "http://Careful.Example:8080/")).?;
    defer testing.allocator.free(asked);
    try testing.expect(std.mem.find(u8, asked, "needs approval") != null);
    const local = (try policy.refusal(testing.allocator, "file:///etc/passwd")).?;
    defer testing.allocator.free(local);
    try testing.expect(std.mem.find(u8, local, "not an http(s) URL") != null);
    try testing.expectEqual(@as(?[]u8, null), try policy.refusal(testing.allocator, "https://example.com/"));
    try testing.expectEqual(@as(?[]u8, null), try policy.refusal(testing.allocator, "about:blank"));
    const open: Policy = .{};
    try testing.expectEqual(@as(?[]u8, null), try open.refusal(testing.allocator, "https://blocked.example/"));
}
