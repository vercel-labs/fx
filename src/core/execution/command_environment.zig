const std = @import("std");
const host_target = @import("../hosts/target.zig");
const types = @import("../shared/types.zig");

pub const Profile = enum {
    clean,
    user,
};

/// Captured-command startup semantics bound into permission admission.
///
/// The shell path is part of explicit native profiles so execution cannot
/// silently switch environments after permission has been granted.
pub const Environment = union(enum) {
    legacy,
    clean: []const u8,
    user: []const u8,
    workspace_clean,

    pub fn eql(self: Environment, other: Environment) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .legacy, .workspace_clean => true,
            .clean => |path| std.mem.eql(u8, path, other.clean),
            .user => |path| std.mem.eql(u8, path, other.user),
        };
    }

    pub fn requiresShellRoute(self: Environment) bool {
        return switch (self) {
            .clean, .user => true,
            .legacy, .workspace_clean => false,
        };
    }
};

/// Where an admitted command runs: this machine, the kept remote
/// sandbox, or a fresh isolated sandbox. A grant binds it, so a grant for one
/// placement never approves another.
pub const Placement = types.CommandPlacement;

const permission_identity_prefix = "@fx-terminal-env:";
const tty_permission_identity_prefix = "@fx-shell-mode:tty:";
const placement_permission_identity_prefix = "@fx-placement:";
const remote_placement_tag = "remote:";
const isolated_placement_tag = "isolated/";
/// The name of the default profile, which every isolated run without a profile uses.
pub const default_profile_name = "default";
/// The longest profile name fx accepts. The error texts that name the rule use it too.
pub const max_profile_name_len: usize = 40;

pub fn isExplicitPermissionCommandIdentity(value: []const u8) bool {
    return std.mem.startsWith(u8, value, permission_identity_prefix) or
        std.mem.startsWith(u8, value, tty_permission_identity_prefix) or
        std.mem.startsWith(u8, value, placement_permission_identity_prefix);
}

/// Binds shell startup to a retained command grant. Legacy callers keep the
/// plain-command identity; terminal profile calls bind the selected shell.
pub fn permissionCommandIdentity(
    alloc: std.mem.Allocator,
    environment: Environment,
    command: []const u8,
) ![]u8 {
    return switch (environment) {
        .legacy, .workspace_clean => alloc.dupe(u8, command),
        .clean => |path| formatPermissionCommandIdentity(alloc, "clean", path, command),
        .user => |path| formatPermissionCommandIdentity(alloc, "user", path, command),
    };
}

pub fn ttyPermissionCommandIdentity(
    alloc: std.mem.Allocator,
    environment: Environment,
    command: []const u8,
) ![]u8 {
    const identity = try permissionCommandIdentity(alloc, environment, command);
    defer alloc.free(identity);
    return std.mem.concat(alloc, u8, &.{ tty_permission_identity_prefix, identity });
}

/// Which project a placed command runs in. A grant names the project, so it
/// never covers another project, and a grant made before a project exists does
/// not cover a run after setup (spec A1). `setup` is a remote run whose project is
/// not set up yet. `provider` is a third-party provider, which names no project.
pub const Destination = union(enum) {
    project: []const u8,
    setup,
    provider,
};

const setup_destination_text = "setup";
const provider_destination_text = "provider";

/// Writes a project id so it holds no `:`. Letters, digits, `_` and `-` stay as
/// they are; every other byte becomes `%xx`, so the id stays readable to a
/// reviewer and cannot end the destination early.
fn writeProjectId(writer: *std.Io.Writer, id: []const u8) !void {
    for (id) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') {
            try writer.writeByte(byte);
        } else {
            try writer.print("%{x:0>2}", .{byte});
        }
    }
}

/// Binds a permission identity to its placement and destination. A local command
/// keeps the identity it had before placements existed, so saved grants still
/// match it. An isolated command names its profile, and a null profile means
/// `default`, so the two bind the same grant. The caller owns the returned slice.
pub fn placementPermissionCommandIdentity(
    alloc: std.mem.Allocator,
    placement: Placement,
    profile: ?[]const u8,
    destination: Destination,
    identity: []const u8,
) ![]u8 {
    if (comptime host_target.is_wasm) return alloc.dupe(u8, identity);
    if (placement == .local) return alloc.dupe(u8, identity);
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    switch (destination) {
        .project => |id| try writeProjectId(&text.writer, id),
        .setup => try text.writer.writeAll(setup_destination_text),
        .provider => try text.writer.writeAll(provider_destination_text),
    }
    const destination_text = text.written();
    return switch (placement) {
        .local => unreachable,
        .remote => alloc.print(
            placement_permission_identity_prefix ++ remote_placement_tag ++ "{s}:{s}",
            .{ destination_text, identity },
        ),
        .isolated => alloc.print(
            placement_permission_identity_prefix ++ isolated_placement_tag ++ "{s}:{s}:{s}",
            .{ profile orelse default_profile_name, destination_text, identity },
        ),
    };
}

/// Removes the prefix that `placementPermissionCommandIdentity` writes: the
/// placement, the profile of an isolated run, and the destination. An unknown
/// placement name, a profile name outside `a-z 0-9 _ -`, or a missing destination
/// leaves the identity unchanged.
fn withoutPlacement(identity: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, identity, placement_permission_identity_prefix)) return identity;
    const rest = identity[placement_permission_identity_prefix.len..];
    if (std.mem.startsWith(u8, rest, remote_placement_tag)) {
        return withoutDestination(rest[remote_placement_tag.len..], identity);
    }
    if (std.mem.startsWith(u8, rest, isolated_placement_tag)) {
        const after_tag = rest[isolated_placement_tag.len..];
        const name_end = std.mem.findScalar(u8, after_tag, ':') orelse return identity;
        if (!isProfileName(after_tag[0..name_end])) return identity;
        return withoutDestination(after_tag[name_end + 1 ..], identity);
    }
    return identity;
}

/// Skips the destination that starts `text`, up to its `:`. `unchanged` is the
/// whole identity, returned when no destination ends in `text`.
fn withoutDestination(text: []const u8, unchanged: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, text, ':') orelse return unchanged;
    return text[end + 1 ..];
}

/// A profile name is 1 to 40 characters of `a-z`, `0-9`, `_`, and `-`.
pub fn isProfileName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_profile_name_len) return false;
    for (name) |byte| {
        const allowed = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or
            byte == '-';
        if (!allowed) return false;
    }
    return true;
}

fn formatPermissionCommandIdentity(
    alloc: std.mem.Allocator,
    profile: []const u8,
    shell_path: []const u8,
    command: []const u8,
) ![]u8 {
    return alloc.print(
        permission_identity_prefix ++ "{s}:{d}:{s}::{s}",
        .{ profile, shell_path.len, shell_path, command },
    );
}

/// Removes the opaque placement and environment prefixes only for configured permission-rule
/// matching and human-facing policy display. Session grants retain it.
pub fn commandFromPermissionIdentity(identity: []const u8) []const u8 {
    const placed_identity = withoutPlacement(identity);
    const environment_identity = if (std.mem.startsWith(
        u8,
        placed_identity,
        tty_permission_identity_prefix,
    ))
        placed_identity[tty_permission_identity_prefix.len..]
    else
        placed_identity;
    if (!std.mem.startsWith(u8, environment_identity, permission_identity_prefix)) {
        return environment_identity;
    }
    var rest = environment_identity[permission_identity_prefix.len..];
    const profile_end = std.mem.findScalar(u8, rest, ':') orelse return identity;
    rest = rest[profile_end + 1 ..];
    const length_end = std.mem.findScalar(u8, rest, ':') orelse return identity;
    const shell_len = std.fmt.parseInt(usize, rest[0..length_end], 10) catch return identity;
    rest = rest[length_end + 1 ..];
    if (shell_len > rest.len or rest.len - shell_len < 2) return identity;
    if (!std.mem.eql(u8, rest[shell_len .. shell_len + 2], "::")) return identity;
    return rest[shell_len + 2 ..];
}

pub fn formatApprovalCommand(
    alloc: std.mem.Allocator,
    environment: Environment,
    command: []const u8,
) ![]u8 {
    return switch (environment) {
        .legacy => alloc.print(
            "# shell.run profile=omitted (legacy)\n{s}",
            .{command},
        ),
        .workspace_clean => alloc.print(
            "# shell.run profile=clean workspace=root-fixed\n{s}",
            .{command},
        ),
        .clean => |path| alloc.print(
            "# shell.run profile=clean shell={s}\n{s}",
            .{ path, command },
        ),
        .user => |path| alloc.print(
            "# shell.run profile=user shell={s}\n{s}",
            .{ path, command },
        ),
    };
}

pub const Host = enum {
    native,
    workspace_clean,
};

test "a profile name is 1 to max_profile_name_len characters of a-z, 0-9, _ or -, and default names the default profile" {
    const longest: [max_profile_name_len]u8 = @splat('a');
    const too_long: [max_profile_name_len + 1]u8 = @splat('a');
    try std.testing.expect(isProfileName(&longest));
    try std.testing.expect(!isProfileName(&too_long));
    try std.testing.expect(!isProfileName(""));
    try std.testing.expect(!isProfileName("Work"));
    try std.testing.expect(isProfileName("ok_-9"));
    try std.testing.expect(isProfileName(default_profile_name));
    try std.testing.expectEqualStrings("default", default_profile_name);
}

test "command environment equality includes explicit shell identity" {
    try std.testing.expect((Environment{ .legacy = {} }).eql(.legacy));
    try std.testing.expect((Environment{ .workspace_clean = {} }).eql(.workspace_clean));
    try std.testing.expect((Environment{ .clean = "/bin/zsh" }).eql(.{ .clean = "/bin/zsh" }));
    try std.testing.expect(!(Environment{ .clean = "/bin/zsh" }).eql(.{ .clean = "/bin/bash" }));
    try std.testing.expect(!(Environment{ .clean = "/bin/zsh" }).eql(.{ .user = "/bin/zsh" }));
}

test "explicit profiles require their selected shell route" {
    try std.testing.expect(!(Environment{ .legacy = {} }).requiresShellRoute());
    try std.testing.expect((Environment{ .clean = "/bin/zsh" }).requiresShellRoute());
    try std.testing.expect((Environment{ .user = "/bin/zsh" }).requiresShellRoute());
    try std.testing.expect(!(Environment{ .workspace_clean = {} }).requiresShellRoute());
}

test "explicit permission identities bind profile and exact shell" {
    const alloc = std.testing.allocator;
    const command = "printf 'a::b'";
    const clean = try permissionCommandIdentity(alloc, .{ .clean = "/bin/zsh" }, command);
    defer alloc.free(clean);
    const user = try permissionCommandIdentity(alloc, .{ .user = "/bin/zsh" }, command);
    defer alloc.free(user);
    const other_shell = try permissionCommandIdentity(alloc, .{ .clean = "/opt/bin::zsh" }, command);
    defer alloc.free(other_shell);

    try std.testing.expect(!std.mem.eql(u8, clean, user));
    try std.testing.expect(!std.mem.eql(u8, clean, other_shell));
    try std.testing.expectEqualStrings(command, commandFromPermissionIdentity(clean));
    try std.testing.expectEqualStrings(command, commandFromPermissionIdentity(other_shell));

    const tty = try ttyPermissionCommandIdentity(
        alloc,
        .{ .clean = "/bin/zsh" },
        command,
    );
    defer alloc.free(tty);
    try std.testing.expect(isExplicitPermissionCommandIdentity(tty));
    try std.testing.expect(!std.mem.eql(u8, clean, tty));
    try std.testing.expectEqualStrings(command, commandFromPermissionIdentity(tty));

    const legacy = try permissionCommandIdentity(alloc, .legacy, command);
    defer alloc.free(legacy);
    try std.testing.expectEqualStrings(command, legacy);
    try std.testing.expectEqualStrings(command, commandFromPermissionIdentity(legacy));
}

test "placement identities keep local grants and separate sandbox grants" {
    const alloc = std.testing.allocator;
    const base = try permissionCommandIdentity(alloc, .legacy, "zig build test");
    defer alloc.free(base);
    const project: Destination = .{ .project = "prj_1" };
    const local = try placementPermissionCommandIdentity(alloc, .local, null, project, base);
    defer alloc.free(local);
    const remote = try placementPermissionCommandIdentity(alloc, .remote, null, project, base);
    defer alloc.free(remote);
    const isolated = try placementPermissionCommandIdentity(alloc, .isolated, null, project, base);
    defer alloc.free(isolated);

    try std.testing.expectEqualStrings(base, local);
    try std.testing.expect(!std.mem.eql(u8, local, remote));
    try std.testing.expect(!std.mem.eql(u8, local, isolated));
    try std.testing.expect(!std.mem.eql(u8, remote, isolated));
    try std.testing.expect(isExplicitPermissionCommandIdentity(remote));
    try std.testing.expect(isExplicitPermissionCommandIdentity(isolated));
    try std.testing.expectEqualStrings("@fx-placement:remote:prj_1:zig build test", remote);
    try std.testing.expectEqualStrings("zig build test", commandFromPermissionIdentity(remote));
    try std.testing.expectEqualStrings("zig build test", commandFromPermissionIdentity(isolated));

    const tty = try ttyPermissionCommandIdentity(alloc, .{ .clean = "/bin/zsh" }, "python3");
    defer alloc.free(tty);
    const tty_isolated = try placementPermissionCommandIdentity(alloc, .isolated, "media", project, tty);
    defer alloc.free(tty_isolated);
    try std.testing.expectEqualStrings("python3", commandFromPermissionIdentity(tty_isolated));

    const media = try placementPermissionCommandIdentity(alloc, .isolated, "media", project, base);
    defer alloc.free(media);
    const open = try placementPermissionCommandIdentity(alloc, .isolated, "open", project, base);
    defer alloc.free(open);
    const isolated_default = try placementPermissionCommandIdentity(alloc, .isolated, "default", project, base);
    defer alloc.free(isolated_default);

    try std.testing.expectEqualStrings("@fx-placement:isolated/media:prj_1:zig build test", media);
    try std.testing.expect(!std.mem.eql(u8, media, open));
    try std.testing.expectEqualStrings(isolated, isolated_default);
    try std.testing.expectEqualStrings("zig build test", commandFromPermissionIdentity(media));

    // A grant for one project never covers another project, and a grant made
    // before setup (`setup`) never covers the run after it.
    const other_project = try placementPermissionCommandIdentity(alloc, .remote, null, .{ .project = "prj_2" }, base);
    defer alloc.free(other_project);
    const before_setup = try placementPermissionCommandIdentity(alloc, .remote, null, .setup, base);
    defer alloc.free(before_setup);
    const provider = try placementPermissionCommandIdentity(alloc, .remote, null, .provider, base);
    defer alloc.free(provider);
    try std.testing.expect(!std.mem.eql(u8, remote, other_project));
    try std.testing.expect(!std.mem.eql(u8, remote, before_setup));
    try std.testing.expect(!std.mem.eql(u8, remote, provider));
    try std.testing.expectEqualStrings("@fx-placement:remote:setup:zig build test", before_setup);
    try std.testing.expectEqualStrings("zig build test", commandFromPermissionIdentity(before_setup));
    try std.testing.expectEqualStrings("zig build test", commandFromPermissionIdentity(provider));

    // A project id with a colon or a space cannot end the destination early.
    const odd = try placementPermissionCommandIdentity(alloc, .remote, null, .{ .project = "a:b c" }, base);
    defer alloc.free(odd);
    try std.testing.expectEqualStrings("@fx-placement:remote:a%3ab%20c:zig build test", odd);
    try std.testing.expectEqualStrings("zig build test", commandFromPermissionIdentity(odd));
    try std.testing.expectEqualStrings(
        "@fx-placement:isolated/Bad Name:ls",
        commandFromPermissionIdentity("@fx-placement:isolated/Bad Name:ls"),
    );

    try std.testing.expectEqualStrings(
        "@fx-placement:elsewhere:ls",
        commandFromPermissionIdentity("@fx-placement:elsewhere:ls"),
    );
}
