//! Decides whether the TUI must ask the user to trust the folder fx starts in,
//! and which saved record covers that folder. The decisions are pure;
//! `trust_key.zig` holds the file reads that supply real paths.
//! Model: `tests/tla/workspace_trust/WorkspaceTrust.tla`.

const std = @import("std");
const trust_key = @import("trust_key.zig");
pub const prompt = @import("prompt.zig");
pub const gate = @import("gate.zig");

pub const resolveKey = trust_key.resolveKey;
pub const OwnedPlaces = trust_key.OwnedPlaces;
pub const resolvePlaces = trust_key.resolvePlaces;

pub const Scope = union(enum) {
    /// The answer is saved under this key, borrowed from the caller.
    saved: []const u8,
    /// Ask every time and never save (model property `HomeNeverSaved`).
    session_only,
};

pub const Decision = enum { proceed, ask };

/// Real paths of the home and fx profile folders; null when unknown.
pub const Places = struct { home: ?[]const u8 = null, profile: ?[]const u8 = null };

pub fn scopeFor(key: []const u8, places: Places) Scope {
    if (std.mem.trimEnd(u8, key, "/").len == 0) return .session_only;
    if (places.home) |home| {
        if (isWithin(home, key)) return .session_only;
    }
    if (places.profile) |profile| {
        if (isWithin(key, profile)) return .session_only;
    }
    return .{ .saved = key };
}

/// The start folder that asks every time keeps its own key; a repository at or above home covers too much.
pub fn keyFor(start: []const u8, repository_root: ?[]const u8, places: Places) []const u8 {
    if (std.meta.activeTag(scopeFor(start, places)) == .session_only) return start;
    const root = repository_root orelse return start;
    if (std.mem.trimEnd(u8, root, "/").len == 0) return start;
    if (places.home) |home| {
        if (isWithin(home, root)) return start;
    }
    return root;
}

/// What the answer on screen applies to. Paths are borrowed.
pub const Cover = union(enum) {
    /// The answer is saved for the start folder.
    this_folder,
    /// The start folder is inside this repository root.
    whole_repository: []const u8,
    /// The start folder is a worktree of this main repository.
    main_repository: []const u8,
    /// The home folder: asks every time.
    home_folder,
    /// `/` or a folder in the fx profile: asks every time.
    special_folder,
};

pub fn coverFor(start: []const u8, key: []const u8, scope: Scope, places: Places) Cover {
    switch (scope) {
        .session_only => {
            if (places.home) |home| {
                if (sameFolder(home, key)) return .home_folder;
            }
            return .special_folder;
        },
        .saved => {
            if (sameFolder(start, key)) return .this_folder;
            if (isWithin(start, key)) return .{ .whole_repository = key };
            return .{ .main_repository = key };
        },
    }
}

pub fn decide(scope: Scope, saved_trusted: bool) Decision {
    return switch (scope) {
        .session_only => .ask,
        .saved => if (saved_trusted) .proceed else .ask,
    };
}

fn sameFolder(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

fn isWithin(path: []const u8, parent: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const base = std.mem.trimEnd(u8, parent, "/");
    if (std.mem.eql(u8, trimmed, base)) return true;
    // An empty base is the root, so every path below it continues with "/".
    return trimmed.len > base.len and
        std.mem.startsWith(u8, trimmed, base) and
        trimmed[base.len] == '/';
}

const law_rounds = 2000;
const law_seed = 0x7ab5;
const max_depth = 4;
const max_path_bytes = 64;
const segment_names = [_][]const u8{ "a", "b", "ab", ".fx" };

fn expectSessionOnly(scope: Scope) !void {
    try std.testing.expectEqual(std.meta.Tag(Scope).session_only, std.meta.activeTag(scope));
}

fn expectSaved(scope: Scope, key: []const u8) !void {
    try std.testing.expectEqual(std.meta.Tag(Scope).saved, std.meta.activeTag(scope));
    try std.testing.expectEqualStrings(key, scope.saved);
}

fn randomPath(random: std.Random, buf: []u8) []const u8 {
    const depth = random.uintLessThan(usize, max_depth + 1);
    if (depth == 0) return "/";
    var len: usize = 0;
    for (0..depth) |_| {
        const segment = segment_names[random.uintLessThan(usize, segment_names.len)];
        buf[len] = '/';
        @memcpy(buf[len + 1 ..][0..segment.len], segment);
        len += 1 + segment.len;
    }
    return buf[0..len];
}

const Segments = struct {
    items: [max_depth][]const u8 = undefined,
    len: usize = 0,

    fn parse(path: []const u8) Segments {
        var result: Segments = .{};
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            result.items[result.len] = part;
            result.len += 1;
        }
        return result;
    }

    fn startsWith(self: Segments, prefix: Segments) bool {
        if (prefix.len > self.len) return false;
        for (self.items[0..prefix.len], prefix.items[0..prefix.len]) |have, want| {
            if (!std.mem.eql(u8, have, want)) return false;
        }
        return true;
    }
};

fn referenceIsSessionOnly(key: []const u8, home: ?[]const u8, profile: ?[]const u8) bool {
    const key_segments = Segments.parse(key);
    if (key_segments.len == 0) return true;
    if (home) |home_path| {
        if (Segments.parse(home_path).startsWith(key_segments)) return true;
    }
    if (profile) |profile_path| {
        if (key_segments.startsWith(Segments.parse(profile_path))) return true;
    }
    return false;
}

test "the filesystem root always asks" {
    try expectSessionOnly(scopeFor("/", .{}));
    try expectSessionOnly(scopeFor("//", .{}));
}

test "the home folder and its parents always ask" {
    const places: Places = .{ .home = "/Users/example" };
    try expectSessionOnly(scopeFor("/Users/example", places));
    try expectSessionOnly(scopeFor("/Users/example/", places));
    try expectSessionOnly(scopeFor("/Users", places));
    try expectSessionOnly(scopeFor("/", places));
    try expectSaved(scopeFor("/Users/example/code", places), "/Users/example/code");
}

test "folders in the fx profile always ask" {
    const places: Places = .{ .profile = "/Users/example/.fx" };
    try expectSessionOnly(scopeFor("/Users/example/.fx", places));
    try expectSessionOnly(scopeFor("/Users/example/.fx/sessions", places));
}

test "a sibling that shares a prefix is not inside" {
    try expectSaved(scopeFor("/Users/ab", .{ .home = "/Users/example" }), "/Users/ab");
    try expectSaved(scopeFor("/Users/example/.fxx", .{ .profile = "/Users/example/.fx" }), "/Users/example/.fxx");
}

test "unknown places save every non-root folder" {
    try expectSaved(scopeFor("/tmp/x", .{}), "/tmp/x");
}

test "a repository at or above the home folder does not cover the folders under it" {
    const start = "/Users/example/Downloads/x";
    const places: Places = .{ .home = "/Users/example" };
    try std.testing.expectEqualStrings(start, keyFor(start, "/Users/example", places));
    try std.testing.expectEqualStrings(start, keyFor(start, "/", places));
    try std.testing.expectEqualStrings(start, keyFor(start, "/Users", places));
    try std.testing.expectEqualStrings("/Users/example/code/r", keyFor("/Users/example/code/r/src", "/Users/example/code/r", places));
    try std.testing.expectEqualStrings("/tmp/x", keyFor("/tmp/x", null, places));
    try std.testing.expectEqualStrings("/Users/example", keyFor("/Users/example/x", "/Users/example", .{}));
}

test "a start folder that asks every time keeps its own key" {
    const home_places: Places = .{ .home = "/Users/example" };
    try std.testing.expectEqualStrings("/Users/example", keyFor("/Users/example", "/elsewhere/main", home_places));
    try std.testing.expectEqualStrings("/Users", keyFor("/Users", "/elsewhere/main", home_places));
    try std.testing.expectEqualStrings("/Users/example/.fx/x", keyFor("/Users/example/.fx/x", "/elsewhere/main", .{ .profile = "/Users/example/.fx" }));
    try std.testing.expectEqualStrings("/elsewhere/main", keyFor("/Users/example/code/r", "/elsewhere/main", home_places));
}

test "only a saved trusted record proceeds" {
    const saved: Scope = .{ .saved = "/tmp/x" };
    try std.testing.expectEqual(Decision.ask, decide(.session_only, true));
    try std.testing.expectEqual(Decision.ask, decide(.session_only, false));
    try std.testing.expectEqual(Decision.proceed, decide(saved, true));
    try std.testing.expectEqual(Decision.ask, decide(saved, false));
}

test "scope matches a segment reference on random paths" {
    var prng = std.Random.DefaultPrng.init(law_seed);
    const random = prng.random();
    var key_buf: [max_path_bytes]u8 = undefined;
    var home_buf: [max_path_bytes]u8 = undefined;
    var profile_buf: [max_path_bytes]u8 = undefined;
    for (0..law_rounds) |_| {
        const key = randomPath(random, &key_buf);
        const home: ?[]const u8 = if (random.boolean()) randomPath(random, &home_buf) else null;
        const profile: ?[]const u8 = if (random.boolean()) randomPath(random, &profile_buf) else null;
        const scope = scopeFor(key, .{ .home = home, .profile = profile });
        if (referenceIsSessionOnly(key, home, profile)) {
            try expectSessionOnly(scope);
        } else {
            try expectSaved(scope, key);
        }
    }
}

fn expectCover(expected: Cover, actual: Cover) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .this_folder, .home_folder, .special_folder => {},
        .whole_repository => |path| try std.testing.expectEqualStrings(path, actual.whole_repository),
        .main_repository => |path| try std.testing.expectEqualStrings(path, actual.main_repository),
    }
}

test "the cover names what the answer applies to" {
    const saved_r: Scope = .{ .saved = "/r" };
    const home_places: Places = .{ .home = "/Users/example" };
    try expectCover(.this_folder, coverFor("/r", "/r", saved_r, .{}));
    try expectCover(.{ .whole_repository = "/r" }, coverFor("/r/src", "/r", saved_r, .{}));
    try expectCover(.{ .main_repository = "/main" }, coverFor("/wt", "/main", .{ .saved = "/main" }, .{}));
    try expectCover(.home_folder, coverFor("/Users/example", "/Users/example", .session_only, home_places));
    try expectCover(.special_folder, coverFor("/", "/", .session_only, home_places));
    try expectCover(.special_folder, coverFor("/Users/example/.fx", "/Users/example/.fx", .session_only, home_places));
}

test {
    _ = trust_key;
    _ = prompt;
    _ = gate;
}
