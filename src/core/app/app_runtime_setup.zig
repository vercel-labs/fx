const std = @import("std");
const command_specs = @import("../slash_commands/command_specs.zig");
const custom_commands = @import("../slash_commands/custom_commands.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");

const Allocator = std.mem.Allocator;
pub const LoadSkillsError = Allocator.Error;
const LoadCustomCommandsError = Allocator.Error;

pub const LoadedSkills = struct {
    dir: []u8 = &.{},
    skills: []skill_runtime.Skill = &.{},
    diagnostics: []skill_runtime.SkillDiagnostic = &.{},

    pub fn deinit(self: *LoadedSkills, alloc: Allocator) void {
        if (self.dir.len > 0) alloc.free(self.dir);
        skill_runtime.freeSkills(alloc, self.skills);
        skill_runtime.freeSkillDiagnostics(alloc, self.diagnostics);
        self.* = .{};
    }
};

pub fn loadSkills(
    alloc: Allocator,
    workspace_root: []const u8,
    root_policy: skill_contract.RootPolicy,
) LoadSkillsError!LoadedSkills {
    const configured_home = io_mod.getenv("HOME") orelse return .{};
    const canonical_home = io_mod.realpathAlloc(alloc, configured_home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (canonical_home) |home| alloc.free(home);
    const home = canonical_home orelse configured_home;
    const dir = try profile_paths.managedSkillsDir(alloc, home);
    errdefer alloc.free(dir);
    const discovery = try skill_runtime.loadVisibleSkills(alloc, workspace_root, home, dir, root_policy);

    return .{
        .dir = dir,
        .skills = discovery.skills,
        .diagnostics = discovery.diagnostics,
    };
}

/// Discovers custom slash commands from the workspace roots and the user root.
/// A missing HOME leaves the user root out and limits workspace discovery to
/// the workspace itself, because no safe ancestor boundary is then known.
pub fn loadCustomCommands(
    alloc: Allocator,
    workspace_root: []const u8,
    root_policy: skill_contract.RootPolicy,
    reserved: command_specs.SlashRegistry,
) LoadCustomCommandsError!custom_commands.CommandDiscovery {
    const configured_home = io_mod.getenv("HOME") orelse {
        return custom_commands.loadCustomCommands(alloc, workspace_root, null, "", .{
            .workspace_roots = root_policy.workspace_roots,
            .managed_root_source = null,
        }, reserved);
    };
    const canonical_home = io_mod.realpathAlloc(alloc, configured_home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (canonical_home) |home| alloc.free(home);
    const home = canonical_home orelse configured_home;
    // The only `profile_paths` call site for the command root, so PR #278's
    // signature change touches one line.
    const dir = try profile_paths.promptsDir(alloc, home);
    defer alloc.free(dir);
    return custom_commands.loadCustomCommands(alloc, workspace_root, home, dir, root_policy, reserved);
}

/// Replaces the live custom-command registry only after discovery and registry
/// construction both succeed. The caller's allocator owns the full runtime.
pub fn reloadCustomCommandRuntime(
    alloc: Allocator,
    runtime: *custom_commands.CommandRuntime,
    workspace_root: []const u8,
    root_policy: skill_contract.RootPolicy,
    reserved: command_specs.SlashRegistry,
    surface: []const u8,
) LoadCustomCommandsError!void {
    var discovered = try loadCustomCommands(alloc, workspace_root, root_policy, reserved);
    custom_commands.traceDiagnostics(surface, discovered.diagnostics);
    const replacement = custom_commands.buildRuntime(alloc, reserved, discovered) catch |err| {
        discovered.deinit(alloc);
        return err;
    };
    runtime.deinit(alloc);
    runtime.* = replacement;
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const TestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: ?[]const u8) !*TestHome {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestHome) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn tmpPath(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, dir, sub_path);
}

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

const test_root_policy: skill_contract.RootPolicy = .{
    .managed_root_source = .global_fx,
};

test "loadSkills returns empty defaults when HOME is missing" {
    const alloc = std.testing.allocator;
    const home = try TestHome.install(alloc, null);
    defer home.deinit();

    var loaded = try loadSkills(alloc, "/tmp/workspace", test_root_policy);
    defer loaded.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), loaded.dir.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.skills.len);
}

test "loadSkills loads managed skills under HOME" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/.fx/skills/demo/SKILL.md",
        \\---
        \\name: demo
        \\description: Demo skill
        \\---
        \\Use this for tests.
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");

    const home_path = try tmpPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const workspace_path = try tmpPath(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_path);

    const home = try TestHome.install(alloc, home_path);
    defer home.deinit();

    var loaded = try loadSkills(alloc, workspace_path, test_root_policy);
    defer loaded.deinit(alloc);

    const expected_dir = try profile_paths.managedSkillsDir(alloc, home_path);
    defer alloc.free(expected_dir);

    try std.testing.expectEqualStrings(expected_dir, loaded.dir);
    try std.testing.expectEqual(@as(usize, 1), loaded.skills.len);
    try std.testing.expectEqualStrings("demo", loaded.skills[0].name);
    try std.testing.expectEqualStrings("Demo skill", loaded.skills[0].description);
    try std.testing.expectEqual(skill_runtime.SkillSource.global_fx, loaded.skills[0].source);
    try std.testing.expectEqual(@as(usize, 0), loaded.diagnostics.len);
}

test "loadSkills canonicalizes a symlinked HOME before discovering optional roots" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "real-home/workspace");
    tmp.dir.symLink(std.testing.io, "real-home", "linked-home", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };
    const tmp_root = try tmpPath(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const linked_home = try std.fs.path.join(alloc, &.{ tmp_root, "linked-home" });
    defer alloc.free(linked_home);
    const workspace_path = try tmpPath(alloc, tmp.dir, "real-home/workspace");
    defer alloc.free(workspace_path);

    const home = try TestHome.install(alloc, linked_home);
    defer home.deinit();

    var loaded = try loadSkills(alloc, workspace_path, test_root_policy);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.skills.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.diagnostics.len);
}

test "loadSkills propagates allocation failure instead of returning an empty inventory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");

    const home_path = try tmpPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const workspace_path = try tmpPath(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_path);
    const home = try TestHome.install(alloc, home_path);
    defer home.deinit();

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        loadSkills(failing.allocator(), workspace_path, test_root_policy),
    );
}

const test_command_root_policy: skill_contract.RootPolicy = .{
    .workspace_roots = &[_]skill_contract.RootSpec{
        .{ .source = .workspace_fx, .path = ".fx/prompts" },
    },
    .managed_root_source = .global_fx,
};

const test_command_reserved_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help" },
};
const test_command_reserved: command_specs.SlashRegistry = .{ .commands = &test_command_reserved_specs };

test "loadCustomCommands without HOME loads only the immediate workspace root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "parent/workspace/.fx/prompts/local.md", "Local prompt.");
    try writeTempFile(&tmp, "parent/.fx/prompts/ancestor.md", "Must stay outside the unknown boundary.");
    const workspace_path = try tmpPath(alloc, tmp.dir, "parent/workspace");
    defer alloc.free(workspace_path);

    const home = try TestHome.install(alloc, null);
    defer home.deinit();

    var discovery = try loadCustomCommands(alloc, workspace_path, test_command_root_policy, test_command_reserved);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try std.testing.expectEqualStrings("local", discovery.commands[0].name);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}

test "loadCustomCommands loads workspace and user commands through the profile path helper" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/.fx/prompts/notes.md", "Take notes about $ARGUMENTS.");
    try writeTempFile(&tmp, "home/workspace/.fx/prompts/deploy.md",
        \\---
        \\description: Deploy a service
        \\argument-hint: <service>
        \\---
        \\Deploy $1 to production.
    );
    try writeTempFile(&tmp, "home/workspace/.fx/prompts/help.md", "Shadows a builtin.");

    const home_path = try tmpPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const workspace_path = try tmpPath(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_path);

    const home = try TestHome.install(alloc, home_path);
    defer home.deinit();

    var discovery = try loadCustomCommands(alloc, workspace_path, test_command_root_policy, test_command_reserved);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), discovery.commands.len);
    try std.testing.expectEqualStrings("deploy", discovery.commands[0].name);
    try std.testing.expectEqualStrings("Deploy a service", discovery.commands[0].description);
    try std.testing.expectEqualStrings("<service>", discovery.commands[0].argument_hint.?);
    try std.testing.expectEqual(skill_contract.SkillSource.workspace_fx, discovery.commands[0].source);
    try std.testing.expectEqualStrings("notes", discovery.commands[1].name);
    try std.testing.expectEqual(skill_contract.SkillSource.global_fx, discovery.commands[1].source);

    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqual(
        custom_commands.CommandDiagnosticCause.builtin_collision,
        discovery.diagnostics[0].cause,
    );
}

test "loadCustomCommands leaves fx unaffected when no command root exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    const home_path = try tmpPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const workspace_path = try tmpPath(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_path);

    const home = try TestHome.install(alloc, home_path);
    defer home.deinit();

    var discovery = try loadCustomCommands(alloc, workspace_path, test_command_root_policy, test_command_reserved);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), discovery.commands.len);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}
