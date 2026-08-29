const std = @import("std");
const domain = @import("domain.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_description_bytes: usize = 512;
pub const max_file_bytes: usize = 72 * 1024;
pub const max_profiles: usize = 128;

pub const Profile = struct {
    name: []u8,
    description: []u8,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
    permission_mode: ?types.PermissionMode = null,
    instructions: []u8,

    pub fn deinit(self: *Profile, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        if (self.model) |model| alloc.free(model);
        alloc.free(self.instructions);
        self.* = undefined;
    }
};

pub const Summary = struct {
    name: []u8,
    description: []u8,

    pub fn deinit(self: *Summary, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        self.* = undefined;
    }
};

pub const Error = error{
    OutOfMemory,
    HomeUnavailable,
    InvalidProfileName,
    ProfileNotFound,
    ProfileUnreadable,
    ProfileTooLarge,
    InvalidProfile,
    TooManyProfiles,
};

pub fn load(alloc: Allocator, name: []const u8) Error!Profile {
    const home = io_mod.getenv("HOME") orelse return error.HomeUnavailable;
    return loadFromHome(alloc, home, name);
}

pub fn loadFromHome(alloc: Allocator, home: []const u8, name: []const u8) Error!Profile {
    try validateProfileName(name);
    const logical_dir_path = try profile_paths.agentsDir(alloc, home);
    defer alloc.free(logical_dir_path);
    const dir_path = io_mod.realpathAlloc(alloc, logical_dir_path) catch |err| return switch (err) {
        error.FileNotFound => error.ProfileNotFound,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProfileUnreadable,
    };
    defer alloc.free(dir_path);
    var dir = io_mod.openDirAbsoluteNoFollow(dir_path, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => error.ProfileNotFound,
        else => error.ProfileUnreadable,
    };
    defer dir.close(io_mod.getIo());
    const file_name = try std.fmt.allocPrint(alloc, "{s}.md", .{name});
    defer alloc.free(file_name);
    var file = io_mod.openExistingRegularFile(dir, file_name, .read_only) catch |err| return switch (err) {
        error.FileNotFound => error.ProfileNotFound,
        else => error.ProfileUnreadable,
    };
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.ProfileTooLarge,
        else => error.ProfileUnreadable,
    };
    defer alloc.free(bytes);
    var profile = try parse(alloc, bytes);
    errdefer profile.deinit(alloc);
    if (!std.mem.eql(u8, profile.name, name)) return error.InvalidProfile;
    return profile;
}

fn initSummary(alloc: Allocator, name: []const u8, description: []const u8) !Summary {
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    return .{
        .name = owned_name,
        .description = try alloc.dupe(u8, description),
    };
}

pub fn list(alloc: Allocator) Error![]Summary {
    const home = io_mod.getenv("HOME") orelse return error.HomeUnavailable;
    return listFromHome(alloc, home);
}

pub fn listFromHome(alloc: Allocator, home: []const u8) Error![]Summary {
    const logical_dir_path = try profile_paths.agentsDir(alloc, home);
    defer alloc.free(logical_dir_path);
    const dir_path = io_mod.realpathAlloc(alloc, logical_dir_path) catch |err| return switch (err) {
        error.FileNotFound => try alloc.alloc(Summary, 0),
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProfileUnreadable,
    };
    defer alloc.free(dir_path);
    var dir = io_mod.openDirAbsoluteNoFollow(dir_path, .{ .iterate = true }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => try alloc.alloc(Summary, 0),
        else => error.ProfileUnreadable,
    };
    defer dir.close(io_mod.getIo());
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var iterator = dir.iterate();
    while (iterator.next(io_mod.getIo()) catch return error.ProfileUnreadable) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const name = entry.name[0 .. entry.name.len - 3];
        validateProfileName(name) catch continue;
        if (names.items.len == max_profiles) return error.TooManyProfiles;
        try names.append(alloc, try alloc.dupe(u8, name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    const summaries = try alloc.alloc(Summary, names.items.len);
    var built: usize = 0;
    errdefer {
        for (summaries[0..built]) |*summary| summary.deinit(alloc);
        alloc.free(summaries);
    }
    for (names.items) |name| {
        var profile = try loadFromHome(alloc, home, name);
        defer profile.deinit(alloc);
        summaries[built] = try initSummary(alloc, profile.name, profile.description);
        built += 1;
    }
    return summaries;
}

pub fn freeSummaries(alloc: Allocator, summaries: []Summary) void {
    for (summaries) |*summary| summary.deinit(alloc);
    alloc.free(summaries);
}

pub fn parse(alloc: Allocator, bytes: []const u8) Error!Profile {
    if (bytes.len > max_file_bytes or !text_utils.isModelSafeText(bytes)) return error.InvalidProfile;
    if (!std.mem.startsWith(u8, bytes, "---\n")) return error.InvalidProfile;
    const end = std.mem.find(u8, bytes[4..], "\n---\n") orelse return error.InvalidProfile;
    const header = bytes[4 .. 4 + end];
    const body = std.mem.trim(u8, bytes[4 + end + 5 ..], " \t\r\n");
    if (body.len == 0 or body.len > domain.max_profile_instructions_bytes) return error.InvalidProfile;

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var effort: ?types.ReasoningEffort = null;
    var permission_mode: ?types.PermissionMode = null;
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.InvalidProfile;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) return error.InvalidProfile;
        if (std.mem.eql(u8, key, "name")) {
            if (name != null) return error.InvalidProfile;
            name = value;
        } else if (std.mem.eql(u8, key, "description")) {
            if (description != null or value.len > max_description_bytes) return error.InvalidProfile;
            description = value;
        } else if (std.mem.eql(u8, key, "model")) {
            if (model != null or value.len > 256) return error.InvalidProfile;
            model = value;
        } else if (std.mem.eql(u8, key, "effort")) {
            if (effort != null) return error.InvalidProfile;
            effort = types.ReasoningEffort.parse(value) orelse return error.InvalidProfile;
        } else if (std.mem.eql(u8, key, "permission_mode")) {
            if (permission_mode != null) return error.InvalidProfile;
            permission_mode = std.meta.stringToEnum(types.PermissionMode, value) orelse return error.InvalidProfile;
        } else return error.InvalidProfile;
    }
    const profile_name = name orelse return error.InvalidProfile;
    try validateProfileName(profile_name);
    const profile_description = description orelse return error.InvalidProfile;
    const owned_name = try alloc.dupe(u8, profile_name);
    errdefer alloc.free(owned_name);
    const owned_description = try alloc.dupe(u8, profile_description);
    errdefer alloc.free(owned_description);
    const owned_model = if (model) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_model) |value| alloc.free(value);
    return .{
        .name = owned_name,
        .description = owned_description,
        .model = owned_model,
        .effort = effort,
        .permission_mode = permission_mode,
        .instructions = try alloc.dupe(u8, body),
    };
}

pub fn validateProfileName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > domain.max_profile_name_bytes) return error.InvalidProfileName;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
            return error.InvalidProfileName;
        }
    }
}

test "profile parser reads minimal frontmatter and instructions" {
    var profile = try parse(std.testing.allocator,
        \\---
        \\name: reviewer
        \\description: Reviews code for regressions
        \\model: anthropic/claude-sonnet-4
        \\effort: high
        \\permission_mode: ask
        \\---
        \\Review independently and report concrete findings.
    );
    defer profile.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("reviewer", profile.name);
    try std.testing.expectEqualStrings("Reviews code for regressions", profile.description);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", profile.model.?);
    try std.testing.expectEqual(types.PermissionMode.ask, profile.permission_mode.?);
    try std.testing.expectEqualStrings("Review independently and report concrete findings.", profile.instructions);
}

test "profile parser rejects unknown fields" {
    try std.testing.expectError(error.InvalidProfile, parse(std.testing.allocator,
        \\---
        \\name: reviewer
        \\description: Review code
        \\tools: all
        \\---
        \\Review.
    ));
}

test "profile loader rejects hardlinked files" {
    if (comptime @import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/agents");
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "source.md",
        .data =
        \\---
        \\name: reviewer
        \\description: Reviews code
        \\---
        \\Review independently.
        ,
    });
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.linkat(
            tmp.dir.handle,
            "source.md",
            tmp.dir.handle,
            "home/.fx/agents/reviewer.md",
            0,
        ),
    );
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    try std.testing.expectError(
        error.ProfileUnreadable,
        loadFromHome(alloc, home, "reviewer"),
    );
}

fn checkParseAllocationFailures(alloc: Allocator) !void {
    var profile = try parse(alloc,
        \\---
        \\name: reviewer
        \\description: Reviews code
        \\model: test/model
        \\---
        \\Review independently.
    );
    profile.deinit(alloc);
}

fn checkSummaryAllocationFailures(alloc: Allocator) !void {
    var summary = try initSummary(alloc, "reviewer", "Reviews code");
    summary.deinit(alloc);
}

test "profile owned values clean every failing allocation path" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkParseAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSummaryAllocationFailures,
        .{},
    );
}
