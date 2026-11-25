//! One decision for one shell command: the target, and why it differs from the
//! model's request. Pure: no I/O and no clock. `decide` does not allocate;
//! `reasonLine` formats into the caller's arena.

const std = @import("std");
const config = @import("config.zig");
const command_environment = @import("../execution/command_environment.zig");
const wildcard = @import("../shared/wildcard.zig");

const parse = config.parse;
const Diagnostic = config.Diagnostic;
const home_folder = "/Users/example";

/// Where the model asked the command to run. `decide` takes null for no request.
pub const Request = enum { local, remote };

/// Why the target is not the one the request named. `floor` is the `workspaces`
/// folder that forces isolation. `rule` is the pattern of the rule that chose
/// the target. Both borrow from the config.
pub const Reason = union(enum) {
    floor: []const u8,
    rule: []const u8,
};

pub const Decision = struct {
    target: config.Target,
    reason: ?Reason = null,
};

/// The line that says why a run went where it went, or null when the model's
/// request did not decide it. `placement` is the target's name (`local`,
/// `remote` or `isolated`) and fills the rule line. The text lives in `arena`.
pub fn reasonLine(arena: std.mem.Allocator, reason: ?Reason, placement: []const u8) std.mem.Allocator.Error!?[]u8 {
    const value = reason orelse return null;
    return switch (value) {
        .floor => |folder| try arena.print("fx: ran isolated because of your folder rule for {s}", .{folder}),
        .rule => |pattern| try arena.print("fx: ran on {s} because of your rule for {s}", .{ placement, pattern }),
    };
}

/// The host's line for a placed run that its own timeout stopped (spec N7). The
/// runner's N5 line, when it prints one, says whether the remote command was
/// killed. The text lives in `arena`.
pub fn timeoutLine(arena: std.mem.Allocator, timeout_ms: usize) std.mem.Allocator.Error![]u8 {
    return arena.print("fx: timed out after {d} ms", .{timeout_ms});
}

/// The host's line for a placed command that a force stop ended (spec N6). The remote
/// command was not killed, so it may still run in the sandbox. The text lives in `arena`.
pub fn forceStopLine(arena: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return arena.dupe(u8, "fx: force stop: the remote command may still run in the sandbox");
}

test "timeoutLine names the host's own timeout in milliseconds, and forceStopLine names a force stop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("fx: timed out after 1000 ms", try timeoutLine(arena_state.allocator(), 1000));
    try std.testing.expectEqualStrings(
        "fx: force stop: the remote command may still run in the sandbox",
        try forceStopLine(arena_state.allocator()),
    );
}

test "reasonLine gives the floor and rule lines, and nothing without a reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "fx: ran isolated because of your folder rule for /w/untrusted",
        (try reasonLine(arena, .{ .floor = "/w/untrusted" }, "isolated")).?,
    );
    try std.testing.expectEqualStrings(
        "fx: ran on local because of your rule for echo*",
        (try reasonLine(arena, .{ .rule = "echo*" }, "local")).?,
    );
    try std.testing.expectEqualStrings(
        "fx: ran on remote because of your rule for npm *",
        (try reasonLine(arena, .{ .rule = "npm *" }, "remote")).?,
    );
    try std.testing.expect((try reasonLine(arena, null, "local")) == null);
}

/// The target for `command` run in `workspace_root`, given the model's request.
/// D1: the folder default is the target of the longest `workspaces` folder that
/// contains the root. D2: an isolated folder default is a floor. Only rules that
/// choose an isolated target apply, and the target stays isolated whatever the
/// request. D3: otherwise the first matching rule sets the target. D4: otherwise
/// the request sets it. D5: otherwise the folder default, else local. Leading and
/// trailing whitespace in the command does not count.
pub fn decide(cfg: *const config.Config, workspace_root: []const u8, command: []const u8, request: ?Request) Decision {
    const trimmed = std.mem.trim(u8, command, &std.ascii.whitespace);
    const folder = config.longestCovering(cfg.workspaces, workspace_root);
    if (folder) |index| {
        const workspace = cfg.workspaces[index];
        if (workspace.target.placement == .isolated) {
            return floorDecision(cfg, workspace.folder, workspace.target, trimmed, request);
        }
    }
    if (firstMatch(cfg, trimmed, false)) |index| {
        const rule = cfg.rules[index];
        return .{ .target = rule.target, .reason = ruleReason(request, rule.pattern, rule.target) };
    }
    if (request) |asked| return .{ .target = requested(asked) };
    if (folder) |index| return .{ .target = cfg.workspaces[index].target };
    return .{ .target = .{ .placement = .local } };
}

/// D2: the folder default is isolated. Only isolated rules apply, so a rule may
/// choose the profile, but the placement stays isolated.
fn floorDecision(
    cfg: *const config.Config,
    folder: []const u8,
    folder_target: config.Target,
    trimmed: []const u8,
    request: ?Request,
) Decision {
    const reason: ?Reason = if (request) |_| Reason{ .floor = folder } else null;
    if (firstMatch(cfg, trimmed, true)) |index| {
        return .{ .target = cfg.rules[index].target, .reason = reason };
    }
    return .{ .target = folder_target, .reason = reason };
}

/// The index of the first rule whose pattern matches the trimmed command. With
/// `isolated_only`, rules that choose a shared target are skipped.
fn firstMatch(cfg: *const config.Config, trimmed: []const u8, isolated_only: bool) ?usize {
    for (cfg.rules, 0..) |rule, index| {
        if (isolated_only and rule.target.placement != .isolated) continue;
        if (wildcard.match(rule.pattern, trimmed)) return index;
    }
    return null;
}

/// D3: the rule's reason, given only when the model asked for another place.
fn ruleReason(request: ?Request, pattern: []const u8, target: config.Target) ?Reason {
    const asked = request orelse return null;
    if (!differs(asked, target)) return null;
    return Reason{ .rule = pattern };
}

/// D4: the request as a target. A request never names isolated.
fn requested(asked: Request) config.Target {
    return switch (asked) {
        .local => .{ .placement = .local },
        .remote => .{ .placement = .remote },
    };
}

/// True when `target` is not the place the request names.
fn differs(asked: Request, target: config.Target) bool {
    return switch (asked) {
        .local => target.placement != .local,
        .remote => target.placement != .remote,
    };
}

const floor_config =
    "{\"workspaces\":{\"/w/untrusted\":\"isolated\"}," ++
    "\"rules\":[{\"command\":\"ls*\",\"runner\":\"remote\"},{\"command\":\"make*\",\"runner\":\"isolated:x\"}]," ++
    "\"profiles\":{\"x\":[\"--x\"]}}";

const repo_config =
    "{\"workspaces\":{\"/w/repo\":\"remote\"}," ++
    "\"rules\":[{\"command\":\"git status*\",\"runner\":\"local\"},{\"command\":\"zig build*\",\"runner\":\"remote\"}," ++
    "{\"command\":\"make*\",\"runner\":\"isolated\"}]}";

const empty_config = "{}";

test "decide gives the floor, rule, request, and folder default in that order" {
    const Case = struct {
        config_text: []const u8,
        root: []const u8,
        command: []const u8,
        request: ?Request,
        want: []const u8,
        reason: []const u8,
    };
    const cases = [_]Case{
        .{ .config_text = floor_config, .root = "/w/untrusted/app", .command = "ls", .request = .local, .want = "isolated", .reason = "floor /w/untrusted" },
        .{ .config_text = floor_config, .root = "/w/untrusted/app", .command = "ls", .request = .remote, .want = "isolated", .reason = "floor /w/untrusted" },
        .{ .config_text = floor_config, .root = "/w/untrusted/app", .command = "make all", .request = .remote, .want = "isolated:x", .reason = "floor /w/untrusted" },
        .{ .config_text = floor_config, .root = "/w/untrusted/app", .command = "make all", .request = null, .want = "isolated:x", .reason = "none" },
        .{ .config_text = floor_config, .root = "/w/untrusted/app", .command = "ls", .request = null, .want = "isolated", .reason = "none" },
        .{ .config_text = repo_config, .root = "/w/repo/app", .command = "zig build test", .request = .local, .want = "remote", .reason = "rule zig build*" },
        .{ .config_text = repo_config, .root = "/w/repo/app", .command = "zig build test", .request = .remote, .want = "remote", .reason = "none" },
        .{ .config_text = repo_config, .root = "/w/repo", .command = "git status -s", .request = .remote, .want = "local", .reason = "rule git status*" },
        .{ .config_text = repo_config, .root = "/w/repo", .command = "npm test", .request = .local, .want = "local", .reason = "none" },
        .{ .config_text = repo_config, .root = "/w/repo", .command = "npm test", .request = null, .want = "remote", .reason = "none" },
        .{ .config_text = repo_config, .root = "/w/repo", .command = "make all", .request = .remote, .want = "isolated", .reason = "rule make*" },
        .{ .config_text = empty_config, .root = "/w/other", .command = "ls", .request = .remote, .want = "remote", .reason = "none" },
        .{ .config_text = empty_config, .root = "/w/other", .command = "ls", .request = null, .want = "local", .reason = "none" },
        .{ .config_text = empty_config, .root = "/w/other", .command = "ls", .request = .local, .want = "local", .reason = "none" },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};
    for (cases) |case| {
        const cfg = try parse(arena, case.config_text, home_folder, &diagnostic);
        const got = decide(&cfg, case.root, case.command, case.request);
        try std.testing.expectEqualStrings(case.want, try describe(arena, got.target));
        try std.testing.expectEqualStrings(case.reason, try describeReason(arena, got.reason));
    }
}

test "decide with no request gives the target the old decide gave for each config and command" {
    const Case = struct {
        config_text: []const u8,
        root: []const u8,
        command: []const u8,
        want: []const u8,
    };
    const cases = [_]Case{
        .{ .config_text = "{}", .root = "/Users/example/repo", .command = "zig build test", .want = "local" },
        .{ .config_text = "{}", .root = "/", .command = "rm -rf /", .want = "local" },
        .{ .config_text = "{\"workspaces\":{\"/Users/example/repo\":\"remote\"}}", .root = "/Users/example/repo/app", .command = "ls", .want = "remote" },
        .{ .config_text = "{\"workspaces\":{\"/Users/example/repo\":\"remote\"}}", .root = "/Users/example/other", .command = "ls", .want = "local" },
        .{
            .config_text = "{\"workspaces\":{\"/Users/example/repo\":\"remote\",\"/Users/example/repo/app\":\"isolated:media\"},\"profiles\":{\"media\":[\"--gpu\"]}}",
            .root = "/Users/example/repo/app/src",
            .command = "convert a.png",
            .want = "isolated:media",
        },
        .{
            .config_text = "{\"workspaces\":{\"/Users/example/repo\":\"remote\",\"/Users/example/repo/app\":\"isolated:media\"},\"profiles\":{\"media\":[\"--gpu\"]}}",
            .root = "/Users/example/repo/lib",
            .command = "ls",
            .want = "remote",
        },
        .{ .config_text = "{\"rules\":[{\"command\":\"zig build*\",\"runner\":\"remote\"},{\"command\":\"zig*\",\"runner\":\"local\"}]}", .root = "/Users/example/repo", .command = "zig build test", .want = "remote" },
        .{ .config_text = "{\"rules\":[{\"command\":\"zig build*\",\"runner\":\"remote\"},{\"command\":\"zig*\",\"runner\":\"local\"}]}", .root = "/Users/example/repo", .command = "zig fmt src", .want = "local" },
        .{ .config_text = "{\"rules\":[{\"command\":\"zig build*\",\"runner\":\"remote\"},{\"command\":\"zig*\",\"runner\":\"local\"}]}", .root = "/Users/example/repo", .command = "ls", .want = "local" },
        .{ .config_text = floor_config, .root = "/w/untrusted/app", .command = "ls -la", .want = "isolated" },
        .{ .config_text = floor_config, .root = "/w/untrusted/app", .command = "make all", .want = "isolated:x" },
        .{ .config_text = floor_config, .root = "/w/trusted", .command = "ls -la", .want = "remote" },
        .{ .config_text = "{\"workspaces\":{\"/Users/example/repo\":\"remote\"},\"rules\":[{\"command\":\"git status*\",\"runner\":\"local\"}]}", .root = "/Users/example/repo", .command = "git status -s", .want = "local" },
        .{ .config_text = "{\"workspaces\":{\"/Users/example/repo\":\"remote\"},\"rules\":[{\"command\":\"git status*\",\"runner\":\"local\"}]}", .root = "/Users/example/repo", .command = "npm test", .want = "remote" },
        .{ .config_text = "{\"rules\":[{\"command\":\"  git status  \",\"runner\":\"remote\"}]}", .root = "/Users/example/repo", .command = "\n\tgit status\t", .want = "remote" },
        .{ .config_text = "{\"workspaces\":{\"/w/x\":\"isolated:default\"}}", .root = "/w/x", .command = "ls", .want = "isolated" },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};
    for (cases) |case| {
        const cfg = try parse(arena, case.config_text, home_folder, &diagnostic);
        const got = decide(&cfg, case.root, case.command, null);
        try std.testing.expectEqualStrings(case.want, try describe(arena, got.target));
        try std.testing.expect(got.reason == null);
    }
}

/// The target as the tests compare it: `local`, `remote`, `isolated`, or
/// `isolated:<profile>`.
fn describe(arena: std.mem.Allocator, target: config.Target) std.mem.Allocator.Error![]const u8 {
    switch (target.placement) {
        .local => return "local",
        .remote => return "remote",
        .isolated => {},
    }
    if (target.profile) |name| return arena.print("isolated:{s}", .{name});
    return "isolated";
}

/// The reason as the tests compare it: `none`, `floor <folder>`, or `rule <pattern>`.
fn describeReason(arena: std.mem.Allocator, reason: ?Reason) std.mem.Allocator.Error![]const u8 {
    const value = reason orelse return "none";
    return switch (value) {
        .floor => |folder| arena.print("floor {s}", .{folder}),
        .rule => |pattern| arena.print("rule {s}", .{pattern}),
    };
}

test "an empty config gives local for every command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(arena_state.allocator(), "{}", home_folder, &diagnostic);

    try std.testing.expectEqual(@as(?[]const []const u8, null), cfg.provider);
    try std.testing.expectEqual(@as(u32, 5000), cfg.grace_ms);
    try std.testing.expectEqual(@as(usize, 0), cfg.rules.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.workspaces.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.env.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.profiles.len);

    const roots = [_][]const u8{ "/Users/example/repo", "/", "" };
    const commands = [_][]const u8{ "zig build test", "rm -rf /", "" };
    for (roots) |root| {
        for (commands) |command| {
            const target = decide(&cfg, root, command, null).target;
            try std.testing.expectEqual(command_environment.Placement.local, target.placement);
            try std.testing.expectEqual(@as(?[]const u8, null), target.profile);
        }
    }
}

test "~/ expands in workspace folders and home may end with a slash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const cfg = try parse(
        arena,
        "{\"workspaces\":{\"~/repo/\":\"remote\"}}",
        "/Users/example/",
        &diagnostic,
    );
    try std.testing.expectEqualStrings("/Users/example/repo", cfg.workspaces[0].folder);
    const target = decide(&cfg, "/Users/example/repo/app", "ls", null).target;
    try std.testing.expectEqual(command_environment.Placement.remote, target.placement);
}

test "the longest workspaces folder that contains the root is the default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"workspaces\":{\"/Users/example/repo\":\"remote\",\"/Users/example/repo/app\":\"isolated\"}}",
        home_folder,
        &diagnostic,
    );

    try std.testing.expectEqual(
        command_environment.Placement.isolated,
        decide(&cfg, "/Users/example/repo/app/src", "ls", null).target.placement,
    );
    try std.testing.expectEqual(
        command_environment.Placement.remote,
        decide(&cfg, "/Users/example/repo/lib", "ls", null).target.placement,
    );
    try std.testing.expectEqual(
        command_environment.Placement.remote,
        decide(&cfg, "/Users/example/repo", "ls", null).target.placement,
    );
    // `repository` shares a prefix with `repo` but is not inside it.
    try std.testing.expectEqual(
        command_environment.Placement.local,
        decide(&cfg, "/Users/example/repository", "ls", null).target.placement,
    );
}

test "the first matching rule wins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"rules\":[{\"command\":\"zig build*\",\"runner\":\"remote\"},{\"command\":\"zig*\",\"runner\":\"isolated\"}]}",
        home_folder,
        &diagnostic,
    );

    try std.testing.expectEqual(
        command_environment.Placement.remote,
        decide(&cfg, "/Users/example/repo", "zig build test", null).target.placement,
    );
    try std.testing.expectEqual(
        command_environment.Placement.isolated,
        decide(&cfg, "/Users/example/repo", "zig fmt src", null).target.placement,
    );
    try std.testing.expectEqual(
        command_environment.Placement.local,
        decide(&cfg, "/Users/example/repo", "git status", null).target.placement,
    );
}

test "an isolated default ignores local and remote rules but takes an isolated rule" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"workspaces\":{\"/w/untrusted\":\"isolated\"}," ++
            "\"rules\":[" ++
            "{\"command\":\"ls*\",\"runner\":\"local\"}," ++
            "{\"command\":\"ls*\",\"runner\":\"remote\"}," ++
            "{\"command\":\"make*\",\"runner\":\"isolated:x\"}," ++
            "{\"command\":\"make*\",\"runner\":\"local\"}]," ++
            "\"profiles\":{\"x\":[\"--x\"]}}",
        home_folder,
        &diagnostic,
    );

    const ls = decide(&cfg, "/w/untrusted/app", "ls -la", null).target;
    try std.testing.expectEqual(command_environment.Placement.isolated, ls.placement);
    try std.testing.expectEqual(@as(?[]const u8, null), ls.profile);

    const make = decide(&cfg, "/w/untrusted/app", "make all", null).target;
    try std.testing.expectEqual(command_environment.Placement.isolated, make.placement);
    try std.testing.expectEqualStrings("x", make.profile.?);

    const other = decide(&cfg, "/w/untrusted/app", "rm -rf build", null).target;
    try std.testing.expectEqual(command_environment.Placement.isolated, other.placement);
    try std.testing.expectEqual(@as(?[]const u8, null), other.profile);

    // A trusted root has no isolated default, so the first matching rule applies.
    const trusted = decide(&cfg, "/w/trusted", "ls -la", null).target;
    try std.testing.expectEqual(command_environment.Placement.local, trusted.placement);
}

test "rule patterns and commands are trimmed before matching" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"rules\":[{\"command\":\"  git status  \",\"runner\":\"remote\"}," ++
            "{\"command\":\"npm test*\",\"runner\":\"isolated:default\"}]}",
        home_folder,
        &diagnostic,
    );

    try std.testing.expectEqual(
        command_environment.Placement.remote,
        decide(&cfg, "/Users/example/repo", "\n\tgit status\t", null).target.placement,
    );
    const npm = decide(&cfg, "/Users/example/repo", "  npm test --watch ", null).target;
    try std.testing.expectEqual(command_environment.Placement.isolated, npm.placement);
    try std.testing.expectEqual(@as(?[]const u8, null), npm.profile);
    try std.testing.expectEqual(
        command_environment.Placement.local,
        decide(&cfg, "/Users/example/repo", "git status -s", null).target.placement,
    );
}

test "an isolated rule names its profile, and isolated:default is the default profile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    const cfg = try parse(
        arena_state.allocator(),
        "{\"profiles\":{\"media\":[]},\"rules\":[" ++
            "{\"command\":\"convert *\",\"runner\":\"isolated:media\"}," ++
            "{\"command\":\"ls\",\"runner\":\"isolated:default\"}]}",
        home_folder,
        &diagnostic,
    );

    const convert = decide(&cfg, "/Users/example/repo", "convert a.png b.jpg", null).target;
    try std.testing.expectEqual(command_environment.Placement.isolated, convert.placement);
    try std.testing.expectEqualStrings("media", convert.profile.?);

    const ls = decide(&cfg, "/Users/example/repo", "ls", null).target;
    try std.testing.expectEqual(command_environment.Placement.isolated, ls.placement);
    try std.testing.expectEqual(@as(?[]const u8, null), ls.profile);
}
