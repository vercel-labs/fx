//! Which hosts `gh` could publish this repository to, read from its git
//! remotes as data, for doctor's gh check.
const std = @import("std");
const indexer = @import("../indexer/indexer.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// At most this many hosts get a gh check.
const max_hosts = 4;

pub const GhHost = struct {
    host: []const u8,
    /// The remote the host came from; null when GH_HOST named it.
    remote: ?[]const u8,
};

/// Where `gh pr create` would publish from, as doctor read the remotes.
pub const GhTarget = union(enum) {
    /// Distinct hosts, the one the fix names first.
    hosts: []const GhHost,
    no_remote,
    /// No remote URL with a host fx can read, or a GH_HOST that is not a
    /// host name: where it came from and what it said.
    unreadable: struct { source: []const u8, value: []const u8 },
    config_unavailable,
};

/// Where `gh pr create`, which fx pr --create runs with no `--repo`, would
/// publish from `workspace_root`. gh takes the repository from the git
/// remotes and drops remotes on hosts it is not signed in to, so a sign-in on
/// any remote's host is enough; GH_HOST, when set, is the only host it keeps.
/// Not followed: an SSH host alias from ~/.ssh/config, which gh resolves with
/// `ssh -G` (`git@work:org/repo` is read as host `work`), and GH_REPO. Memory
/// belongs to `arena`.
pub fn read(arena: Allocator, workspace_root: []const u8) Allocator.Error!GhTarget {
    const remotes = indexer.repoRemotes(arena, workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RepoConfigUnavailable => return .config_unavailable,
    };
    return fromRemotes(arena, remotes, io_mod.getenv("GH_HOST"));
}

/// gh's order for the repository it picks: a remote `gh repo set-default`
/// marked, then upstream, github, origin, and the rest. Only the host the fix
/// names depends on it.
const RemoteRank = enum { marked, upstream, github, origin, other };

fn rankOf(remote: indexer.Remote) RemoteRank {
    if (remote.gh_resolved) return .marked;
    inline for (.{ .upstream, .github, .origin }) |rank| {
        if (std.ascii.eqlIgnoreCase(remote.name, @tagName(rank))) return rank;
    }
    return .other;
}

fn fromRemotes(arena: Allocator, remotes: []const indexer.Remote, gh_host: ?[]const u8) Allocator.Error!GhTarget {
    if (remotes.len == 0) return .no_remote;
    if (gh_host) |only| {
        if (only.len > 0) {
            if (!isHostName(only)) return .{ .unreadable = .{ .source = "GH_HOST", .value = only } };
            const hosts = try arena.alloc(GhHost, 1);
            hosts[0] = .{ .host = try std.ascii.allocLowerString(arena, only), .remote = null };
            return .{ .hosts = hosts };
        }
    }
    var hosts: std.ArrayList(GhHost) = .empty;
    var first: ?indexer.Remote = null;
    for (std.enums.values(RemoteRank)) |rank| {
        for (remotes) |remote| {
            if (rankOf(remote) != rank) continue;
            if (first == null) first = remote;
            const host = try remoteHost(arena, remote.url) orelse continue;
            const known = for (hosts.items) |seen| {
                if (std.mem.eql(u8, seen.host, host)) break true;
            } else false;
            if (known or hosts.items.len == max_hosts) continue;
            try hosts.append(arena, .{ .host = host, .remote = remote.name });
        }
    }
    if (hosts.items.len == 0) {
        const remote = first.?;
        return .{ .unreadable = .{ .source = try arena.print("remote {s}", .{remote.name}), .value = remote.url } };
    }
    return .{ .hosts = try hosts.toOwnedSlice(arena) };
}

/// The host of a git remote URL, in lowercase: `scheme://[user@]host[:port]/path`
/// or scp-style `[user@]host:path`. Null for a local path, a file URL, or a
/// host with a character a host name does not have.
fn remoteHost(arena: Allocator, url: []const u8) Allocator.Error!?[]const u8 {
    var authority: []const u8 = undefined;
    if (std.mem.find(u8, url, "://")) |at| {
        if (std.ascii.eqlIgnoreCase(url[0..at], "file")) return null;
        const rest = url[at + "://".len ..];
        authority = rest[0 .. std.mem.findScalar(u8, rest, '/') orelse rest.len];
        if (std.mem.findScalarLast(u8, authority, '@')) |user_end| authority = authority[user_end + 1 ..];
        if (std.mem.findScalar(u8, authority, ':')) |port| authority = authority[0..port];
    } else {
        // scp-style has a colon before any slash; anything else is a path.
        const colon = std.mem.findScalar(u8, url, ':') orelse return null;
        if (std.mem.findScalar(u8, url[0..colon], '/') != null) return null;
        authority = url[0..colon];
        if (std.mem.findScalarLast(u8, authority, '@')) |user_end| authority = authority[user_end + 1 ..];
    }
    if (!isHostName(authority)) return null;
    return try std.ascii.allocLowerString(arena, authority);
}

fn isHostName(text: []const u8) bool {
    if (text.len == 0 or text.len > 253 or text[0] == '-' or text[0] == '.') return false;
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_') return false;
    }
    return true;
}

test "gh is checked on each host the remotes name, with the fix on the one gh ranks first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const remotes = [_]indexer.Remote{
        .{ .name = "origin", .url = "git@github.com:me/fork.git", .gh_resolved = false },
        .{ .name = "mirror", .url = "ssh://git@GHE.example.com:2222/team/repo", .gh_resolved = false },
        .{ .name = "upstream", .url = "https://user:token@github.com/org/repo", .gh_resolved = false },
        .{ .name = "local", .url = "/srv/git/repo.git", .gh_resolved = false },
        .{ .name = "file", .url = "file:///srv/git/repo.git", .gh_resolved = false },
    };
    const found = (try fromRemotes(arena, &remotes, null)).hosts;
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("github.com", found[0].host);
    try std.testing.expectEqualStrings("upstream", found[0].remote.?);
    try std.testing.expectEqualStrings("ghe.example.com", found[1].host);

    // A remote `gh repo set-default` marked comes first.
    var marked = remotes;
    marked[1].gh_resolved = true;
    try std.testing.expectEqualStrings("ghe.example.com", (try fromRemotes(arena, &marked, null)).hosts[0].host);

    // GH_HOST is the only host gh keeps.
    const only = (try fromRemotes(arena, &remotes, "GHE.example.com")).hosts;
    try std.testing.expectEqual(@as(usize, 1), only.len);
    try std.testing.expectEqualStrings("ghe.example.com", only[0].host);
    try std.testing.expect(only[0].remote == null);
    try std.testing.expectEqualStrings("GH_HOST", (try fromRemotes(arena, &remotes, "not a host")).unreadable.source);

    try std.testing.expect(try fromRemotes(arena, &.{}, null) == .no_remote);
    const unreadable = (try fromRemotes(arena, remotes[3..], null)).unreadable;
    try std.testing.expectEqualStrings("remote local", unreadable.source);
    try std.testing.expectEqualStrings("/srv/git/repo.git", unreadable.value);

    var many: [max_hosts + 2]indexer.Remote = undefined;
    for (&many, 0..) |*remote, i| remote.* = .{ .name = try arena.print("r{d}", .{i}), .url = try arena.print("https://h{d}.example.com/x", .{i}), .gh_resolved = false };
    try std.testing.expectEqual(@as(usize, max_hosts), (try fromRemotes(arena, &many, null)).hosts.len);
}
