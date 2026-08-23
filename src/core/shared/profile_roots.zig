const std = @import("std");
const builtin = @import("builtin");

const io_mod = @import("io.zig");
const profile_paths = @import("profile_paths.zig");

const Allocator = std.mem.Allocator;

/// Directory fx owns under each XDG base directory.
pub const app_dir_name = "fx";

/// Every profile entry now resolves through the roots below, so a fresh Linux profile adopts
/// the XDG layout. An installation that already holds a `~/.fx` profile still collapses onto
/// it, and no file is ever moved.
pub const xdg_layout_enabled = true;

pub const Layout = enum { legacy, xdg };
pub const RootKind = enum { config, state, data };

/// Profile roots relative to a home, for the platform the test binary was built for. macOS pins
/// every root to `~/.fx` while a fresh Linux profile splits across the XDG roots, so a test that
/// seeds a fixture or freezes an expected path goes through these instead of one literal that is
/// only true on Linux. Tests only: production reads the resolved roots.
pub const test_relative_roots = struct {
    pub const config = if (builtin.os.tag == .linux)
        ".config/" ++ app_dir_name
    else
        profile_paths.root_dir_name;
    pub const state = if (builtin.os.tag == .linux)
        ".local/state/" ++ app_dir_name
    else
        profile_paths.root_dir_name;
    pub const data = if (builtin.os.tag == .linux)
        ".local/share/" ++ app_dir_name
    else
        profile_paths.root_dir_name;
};

/// Absolute roots fx reads and writes under. All three are equal under the legacy layout.
pub const ProfileRoots = struct {
    config: []u8,
    state: []u8,
    data: []u8,
    layout: Layout,

    pub fn deinit(self: *ProfileRoots, alloc: Allocator) void {
        alloc.free(self.config);
        alloc.free(self.state);
        alloc.free(self.data);
        self.* = undefined;
    }
};

/// The environment inputs resolution reads. `fromProcess` is the only route that touches
/// the process environment, so every other entry point stays pure and injectable.
pub const Environment = struct {
    home: []const u8,
    config_home: ?[]const u8 = null,
    state_home: ?[]const u8 = null,
    data_home: ?[]const u8 = null,

    pub fn fromProcess(home: []const u8) Environment {
        return .{
            .home = home,
            .config_home = io_mod.getenv("XDG_CONFIG_HOME"),
            .state_home = io_mod.getenv("XDG_STATE_HOME"),
            .data_home = io_mod.getenv("XDG_DATA_HOME"),
        };
    }
};

pub const Policy = struct {
    os_tag: std.Target.Os.Tag = builtin.os.tag,
    has_legacy_profile: bool = false,
    allow_xdg_layout: bool = xdg_layout_enabled,
};

/// Absolute path of the legacy `~/.fx` profile root. The caller owns the slice.
pub fn legacyRoot(alloc: Allocator, home: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(alloc, &.{ home, profile_paths.root_dir_name });
}

/// Resolves the three roots from an environment and a policy. Pure: it reads no variable
/// and touches no file, so the decision is testable without a filesystem.
pub fn resolve(alloc: Allocator, env: Environment, policy: Policy) Allocator.Error!ProfileRoots {
    if (!policy.allow_xdg_layout or policy.os_tag != .linux or policy.has_legacy_profile) {
        return legacyRoots(alloc, env.home);
    }

    const config = try xdgRoot(alloc, env.config_home, env.home, &.{".config"});
    errdefer alloc.free(config);
    const state = try xdgRoot(alloc, env.state_home, env.home, &.{ ".local", "state" });
    errdefer alloc.free(state);
    const data = try xdgRoot(alloc, env.data_home, env.home, &.{ ".local", "share" });

    return .{ .config = config, .state = state, .data = data, .layout = .xdg };
}

/// Resolves for a real process: reads the environment, and probes for a legacy profile only
/// when the XDG layout could actually win. The caller owns the returned roots.
pub fn resolveForProcess(alloc: Allocator, home: []const u8, base: Policy) Allocator.Error!ProfileRoots {
    var policy = base;
    if (policy.allow_xdg_layout and policy.os_tag == .linux) {
        policy.has_legacy_profile = try hasLegacyProfile(alloc, home);
    } else {
        return legacyRoots(alloc, home);
    }
    return resolve(alloc, Environment.fromProcess(home), policy);
}

/// Resolves one root without allocating the two roots a caller does not use. The caller owns
/// the returned path. Non-Linux targets return before reading any XDG variable.
pub fn resolveRootForProcess(
    alloc: Allocator,
    home: []const u8,
    kind: RootKind,
    base: Policy,
) Allocator.Error![]u8 {
    if (!base.allow_xdg_layout or base.os_tag != .linux or base.has_legacy_profile or try hasLegacyProfile(alloc, home)) {
        return legacyRoot(alloc, home);
    }

    return switch (kind) {
        .config => xdgRoot(alloc, io_mod.getenv("XDG_CONFIG_HOME"), home, &.{".config"}),
        .state => xdgRoot(alloc, io_mod.getenv("XDG_STATE_HOME"), home, &.{ ".local", "state" }),
        .data => xdgRoot(alloc, io_mod.getenv("XDG_DATA_HOME"), home, &.{ ".local", "share" }),
    };
}

/// True when `~/.fx` already exists. Any existing entry selects the legacy layout so fx never
/// splits or migrates an installation implicitly. Allocation failures are propagated.
pub fn hasLegacyProfile(alloc: Allocator, home: []const u8) Allocator.Error!bool {
    const root = try legacyRoot(alloc, home);
    defer alloc.free(root);

    const zio = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(zio, root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    dir.close(zio);
    return true;
}

fn legacyRoots(alloc: Allocator, home: []const u8) Allocator.Error!ProfileRoots {
    const config = try legacyRoot(alloc, home);
    errdefer alloc.free(config);
    const state = try legacyRoot(alloc, home);
    errdefer alloc.free(state);
    const data = try legacyRoot(alloc, home);

    return .{ .config = config, .state = state, .data = data, .layout = .legacy };
}

fn xdgRoot(
    alloc: Allocator,
    value: ?[]const u8,
    home: []const u8,
    default_segments: []const []const u8,
) Allocator.Error![]u8 {
    if (xdgBase(value)) |base| return std.fs.path.join(alloc, &.{ base, app_dir_name });

    var segments: [4][]const u8 = undefined;
    segments[0] = home;
    for (default_segments, 1..) |segment, index| segments[index] = segment;
    const count = default_segments.len + 1;
    segments[count] = app_dir_name;
    return std.fs.path.join(alloc, segments[0 .. count + 1]);
}

/// The specification ignores an unset, empty, or relative value and falls back to the
/// default: "If an implementation encounters a relative path in any of these variables it
/// should consider the path invalid and ignore it."
fn xdgBase(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    if (raw.len == 0) return null;
    if (!std.fs.path.isAbsolute(raw)) return null;
    return raw;
}

const testing = std.testing;

const linux_xdg_policy: Policy = .{ .os_tag = .linux, .allow_xdg_layout = true };
var stable_test_environ: std.process.Environ.Map = undefined;
var stable_test_environ_initialized = false;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (!stable_test_environ_initialized) {
        stable_test_environ = std.process.Environ.Map.init(testing.allocator);
        stable_test_environ_initialized = true;
    }
    return &stable_test_environ;
}

fn expectRoots(roots: ProfileRoots, config: []const u8, state: []const u8, data: []const u8) !void {
    try testing.expectEqualStrings(config, roots.config);
    try testing.expectEqualStrings(state, roots.state);
    try testing.expectEqualStrings(data, roots.data);
}

test "resolve honors XDG variables that are set" {
    var roots = try resolve(testing.allocator, .{
        .home = "/home/tester",
        .config_home = "/x/cfg",
        .state_home = "/x/st",
        .data_home = "/x/dat",
    }, linux_xdg_policy);
    defer roots.deinit(testing.allocator);

    try expectRoots(roots, "/x/cfg/fx", "/x/st/fx", "/x/dat/fx");
    try testing.expectEqual(Layout.xdg, roots.layout);
}

test "resolve falls back to the specification defaults when no variable is set" {
    var roots = try resolve(testing.allocator, .{ .home = "/home/tester" }, linux_xdg_policy);
    defer roots.deinit(testing.allocator);

    try expectRoots(
        roots,
        "/home/tester/.config/fx",
        "/home/tester/.local/state/fx",
        "/home/tester/.local/share/fx",
    );
}

test "resolve ignores empty and relative XDG values" {
    var empty = try resolve(testing.allocator, .{
        .home = "/home/tester",
        .config_home = "",
        .state_home = "",
        .data_home = "",
    }, linux_xdg_policy);
    defer empty.deinit(testing.allocator);

    try expectRoots(
        empty,
        "/home/tester/.config/fx",
        "/home/tester/.local/state/fx",
        "/home/tester/.local/share/fx",
    );

    var relative = try resolve(testing.allocator, .{
        .home = "/home/tester",
        .config_home = "cfg",
        .state_home = "./st",
        .data_home = "../dat",
    }, linux_xdg_policy);
    defer relative.deinit(testing.allocator);

    try expectRoots(
        relative,
        "/home/tester/.config/fx",
        "/home/tester/.local/state/fx",
        "/home/tester/.local/share/fx",
    );
}

test "resolve mixes a set variable with defaults for the others" {
    var roots = try resolve(testing.allocator, .{
        .home = "/home/tester",
        .state_home = "/var/lib/fx-state",
    }, linux_xdg_policy);
    defer roots.deinit(testing.allocator);

    try expectRoots(
        roots,
        "/home/tester/.config/fx",
        "/var/lib/fx-state/fx",
        "/home/tester/.local/share/fx",
    );
}

test "resolve pins non-Linux targets to the legacy root" {
    for ([_]std.Target.Os.Tag{ .macos, .windows }) |os_tag| {
        var roots = try resolve(testing.allocator, .{
            .home = "/home/tester",
            .config_home = "/x/cfg",
            .state_home = "/x/st",
            .data_home = "/x/dat",
        }, .{ .os_tag = os_tag, .allow_xdg_layout = true });
        defer roots.deinit(testing.allocator);

        try expectRoots(roots, "/home/tester/.fx", "/home/tester/.fx", "/home/tester/.fx");
        try testing.expectEqual(Layout.legacy, roots.layout);
    }
}

test "resolve collapses every root onto a detected legacy profile" {
    var roots = try resolve(testing.allocator, .{
        .home = "/home/tester",
        .config_home = "/x/cfg",
        .state_home = "/x/st",
        .data_home = "/x/dat",
    }, .{ .os_tag = .linux, .allow_xdg_layout = true, .has_legacy_profile = true });
    defer roots.deinit(testing.allocator);

    try expectRoots(roots, "/home/tester/.fx", "/home/tester/.fx", "/home/tester/.fx");
    try testing.expectEqual(Layout.legacy, roots.layout);
}

test "resolve reads the injected process environment through io getenv" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", "/injected/cfg");
    try env.put("XDG_STATE_HOME", "/injected/st");
    try env.put("XDG_DATA_HOME", "/injected/dat");

    const previous = io_mod.environMap() orelse try stableEmptyTestEnviron();
    defer io_mod.setEnvironMap(previous);
    io_mod.setEnvironMap(&env);

    var roots = try resolve(
        testing.allocator,
        Environment.fromProcess("/home/tester"),
        linux_xdg_policy,
    );
    defer roots.deinit(testing.allocator);

    try expectRoots(roots, "/injected/cfg/fx", "/injected/st/fx", "/injected/dat/fx");
}

fn makeLegacyEntry(dir: std.Io.Dir, name: []const u8, kind: enum { file, directory }) !void {
    const zio = std.testing.io;
    switch (kind) {
        .file => {
            var file = try dir.createFile(zio, name, .{});
            file.close(zio);
        },
        .directory => try dir.createDir(zio, name, std.Io.File.Permissions.fromMode(0o700)),
    }
}

test "legacy detection accepts any existing profile directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home");

    const home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "home");
    defer testing.allocator.free(home);

    try testing.expect(!(try hasLegacyProfile(testing.allocator, home)));

    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try testing.expect(try hasLegacyProfile(testing.allocator, home));

    var roots = try resolveForProcess(testing.allocator, home, linux_xdg_policy);
    defer roots.deinit(testing.allocator);
    try testing.expectEqual(Layout.legacy, roots.layout);
}

test "legacy detection propagates allocation failure" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        hasLegacyProfile(failing.allocator(), "/home/tester"),
    );
}

test "legacy detection accepts a profile holding only sessions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");

    var fx = try tmp.dir.openDir(std.testing.io, "home/.fx", .{});
    defer fx.close(std.testing.io);
    try makeLegacyEntry(fx, profile_paths.sessions_dir_name, .directory);

    const home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "home");
    defer testing.allocator.free(home);

    try testing.expect(try hasLegacyProfile(testing.allocator, home));

    var roots = try resolveForProcess(testing.allocator, home, linux_xdg_policy);
    defer roots.deinit(testing.allocator);

    const expected = try legacyRoot(testing.allocator, home);
    defer testing.allocator.free(expected);
    try expectRoots(roots, expected, expected, expected);
    try testing.expectEqual(Layout.legacy, roots.layout);
}

test "legacy detection accepts a profile holding only a provider session" {
    for ([_][]const u8{
        profile_paths.chatgpt_auth_file_name,
        profile_paths.grok_auth_file_name,
    }) |entry| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "home/.fx");

        var fx = try tmp.dir.openDir(std.testing.io, "home/.fx", .{});
        defer fx.close(std.testing.io);
        try makeLegacyEntry(fx, entry, .file);

        const home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "home");
        defer testing.allocator.free(home);

        try testing.expect(try hasLegacyProfile(testing.allocator, home));

        var roots = try resolveForProcess(testing.allocator, home, linux_xdg_policy);
        defer roots.deinit(testing.allocator);
        try testing.expectEqual(Layout.legacy, roots.layout);
    }
}

test "legacy detection accepts a profile holding only global instructions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");

    var fx = try tmp.dir.openDir(std.testing.io, "home/.fx", .{});
    defer fx.close(std.testing.io);
    try makeLegacyEntry(fx, profile_paths.global_instructions_file_name, .file);

    const home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "home");
    defer testing.allocator.free(home);

    // A user who only ever wrote global instructions still owns a profile: splitting the roots
    // here would silently stop loading `~/.fx/AGENTS.md` without moving or reporting anything.
    try testing.expect(try hasLegacyProfile(testing.allocator, home));

    var roots = try resolveForProcess(testing.allocator, home, linux_xdg_policy);
    defer roots.deinit(testing.allocator);

    const expected = try legacyRoot(testing.allocator, home);
    defer testing.allocator.free(expected);
    try expectRoots(roots, expected, expected, expected);
    try testing.expectEqual(Layout.legacy, roots.layout);
}

test "legacy detection accepts a settings-only profile despite XDG variables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");

    var fx = try tmp.dir.openDir(std.testing.io, "home/.fx", .{});
    defer fx.close(std.testing.io);
    try makeLegacyEntry(fx, "settings.json", .file);

    const home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "home");
    defer testing.allocator.free(home);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", "/injected/cfg");
    try env.put("XDG_STATE_HOME", "/injected/st");
    try env.put("XDG_DATA_HOME", "/injected/dat");

    const previous = io_mod.environMap() orelse try stableEmptyTestEnviron();
    defer io_mod.setEnvironMap(previous);
    io_mod.setEnvironMap(&env);

    var roots = try resolveForProcess(testing.allocator, home, linux_xdg_policy);
    defer roots.deinit(testing.allocator);

    const expected = try legacyRoot(testing.allocator, home);
    defer testing.allocator.free(expected);
    try expectRoots(roots, expected, expected, expected);
}

test "legacy detection keeps a non-directory profile root on the legacy layout" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home");

    var fx = try tmp.dir.createFile(std.testing.io, "home/.fx", .{});
    fx.close(std.testing.io);

    const home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "home");
    defer testing.allocator.free(home);

    try testing.expect(try hasLegacyProfile(testing.allocator, home));
}

test "legacy detection keeps a symlinked profile root on the legacy layout" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    tmp.dir.symLink(std.testing.io, "../outside", "home/.fx", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    const home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "home");
    defer testing.allocator.free(home);

    try testing.expect(try hasLegacyProfile(testing.allocator, home));
}

test "production resolves the XDG layout for a Linux profile with no legacy root" {
    try testing.expect(xdg_layout_enabled);

    // An empty environment pins the defaults: the host must not decide what these roots are.
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const previous = io_mod.environMap() orelse try stableEmptyTestEnviron();
    defer io_mod.setEnvironMap(previous);
    io_mod.setEnvironMap(&env);

    var roots = try resolveForProcess(testing.allocator, "/home/tester", .{ .os_tag = .linux });
    defer roots.deinit(testing.allocator);

    try expectRoots(
        roots,
        "/home/tester/.config/fx",
        "/home/tester/.local/state/fx",
        "/home/tester/.local/share/fx",
    );
    try testing.expectEqual(Layout.xdg, roots.layout);
}

test "production pins macOS to the legacy root whatever the environment exports" {
    // The whole macOS decision lives in the target tag `resolve` reads, so a Linux test host can
    // assert the branch the macOS CI jobs actually take.
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", "/Users/tester/xdg-config");
    try env.put("XDG_STATE_HOME", "/Users/tester/xdg-state");
    try env.put("XDG_DATA_HOME", "/Users/tester/xdg-data");

    const previous = io_mod.environMap() orelse try stableEmptyTestEnviron();
    defer io_mod.setEnvironMap(previous);
    io_mod.setEnvironMap(&env);

    var macos = try resolveForProcess(testing.allocator, "/Users/tester", .{ .os_tag = .macos });
    defer macos.deinit(testing.allocator);

    try expectRoots(macos, "/Users/tester/.fx", "/Users/tester/.fx", "/Users/tester/.fx");
    try testing.expectEqual(Layout.legacy, macos.layout);

    // Same environment, same home shape: only the target tag separates the two layouts.
    var linux = try resolveForProcess(testing.allocator, "/Users/tester", .{ .os_tag = .linux });
    defer linux.deinit(testing.allocator);

    try expectRoots(
        linux,
        "/Users/tester/xdg-config/fx",
        "/Users/tester/xdg-state/fx",
        "/Users/tester/xdg-data/fx",
    );
    try testing.expectEqual(Layout.xdg, linux.layout);
}

test "every macOS profile path stays under the legacy root" {
    const alloc = testing.allocator;
    var roots = try resolve(alloc, .{
        .home = "/Users/tester",
        .config_home = "/Users/tester/xdg-config",
        .state_home = "/Users/tester/xdg-state",
        .data_home = "/Users/tester/xdg-data",
    }, .{ .os_tag = .macos, .allow_xdg_layout = true });
    defer roots.deinit(alloc);

    const settings = try profile_paths.settingsPath(alloc, roots.config);
    defer alloc.free(settings);
    const sessions = try profile_paths.sessionsDir(alloc, roots.state);
    defer alloc.free(sessions);
    const skills = try profile_paths.managedSkillsDir(alloc, roots.data);
    defer alloc.free(skills);

    try testing.expectEqualStrings("/Users/tester/.fx/settings.json", settings);
    try testing.expectEqualStrings("/Users/tester/.fx/sessions", sessions);
    try testing.expectEqualStrings("/Users/tester/.fx/skills", skills);
}

test "credentials never resolve under the config root" {
    const alloc = testing.allocator;
    var roots = try resolve(alloc, .{
        .home = "/home/tester",
        .config_home = "/x/cfg",
        .state_home = "/x/st",
    }, linux_xdg_policy);
    defer roots.deinit(alloc);

    const credential_paths = [_][]u8{
        try profile_paths.authPath(alloc, roots.state),
        try profile_paths.apiKeyPath(alloc, roots.state),
        try profile_paths.mcpCredentialsPath(alloc, roots.state),
    };
    defer for (credential_paths) |path| alloc.free(path);

    for (credential_paths) |path| {
        try testing.expect(std.mem.startsWith(u8, path, roots.state));
        try testing.expect(!std.mem.startsWith(u8, path, roots.config));
    }
}
