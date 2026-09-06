const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");

const Allocator = std.mem.Allocator;
pub const LoadSkillsError = Allocator.Error;

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

pub fn resolveSkillsHome(alloc: Allocator) Allocator.Error!?[]u8 {
    const configured_home = io_mod.getenv("HOME") orelse return null;
    return io_mod.realpathAlloc(alloc, configured_home) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => try alloc.dupe(u8, configured_home),
    };
}

pub fn loadSkills(
    alloc: Allocator,
    workspace_root: []const u8,
    root_policy: skill_contract.RootPolicy,
) LoadSkillsError!LoadedSkills {
    const home = (try resolveSkillsHome(alloc)) orelse return .{};
    defer alloc.free(home);
    const dir = try profile_paths.managedSkillsDir(alloc, home);
    errdefer alloc.free(dir);
    const discovery = try skill_runtime.loadVisibleSkills(alloc, workspace_root, home, dir, root_policy);

    return .{
        .dir = dir,
        .skills = discovery.skills,
        .diagnostics = discovery.diagnostics,
    };
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
