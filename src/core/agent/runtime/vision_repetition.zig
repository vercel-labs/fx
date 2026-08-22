const std = @import("std");
const types = @import("../../shared/types.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const vision_contracts = @import("vision_contracts.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

const warning_after_successes: usize = 3;
const block_after_successes: usize = 5;

pub const warning_notice =
    "Vision has already inspected this same image set successfully three times in this turn. " ++
    "Use the evidence returned so far. Only inspect these images again if another focused pass is essential; " ++
    "a sixth inspection without an intervening action will be blocked.";

pub const blocked_message =
    "Vision was blocked because the same unchanged image set has already been inspected successfully five times in this turn.";

pub const blocked_suggestion =
    "Use the existing visual evidence, inspect a different image set, or wait for new user input.";

pub const stopped_notice =
    "Stopped a repeated Vision loop after five successful inspections of the same unchanged image set.";

pub const Disposition = enum {
    untracked,
    allow,
    block,
};

pub const CanonicalPathTarget = struct {
    path: []const u8,
    identity: file_mutation_contract.FileIdentity,
};

const StoredPathTarget = struct {
    path: []u8,
    identity: ?file_mutation_contract.FileIdentity,
};

const Target = union(enum) {
    image_ids: []usize,
    paths: []StoredPathTarget,

    fn clone(
        alloc: Allocator,
        request: vision_contracts.VisionRequest,
        canonical_targets: ?[]const CanonicalPathTarget,
    ) Allocator.Error!Target {
        if (request.image_ids()) |image_ids| {
            return .{ .image_ids = try alloc.dupe(usize, image_ids) };
        }

        const requested_paths = request.paths().?;
        const target_count = if (canonical_targets) |targets|
            targets.len
        else
            requested_paths.len;
        const owned = try alloc.alloc(StoredPathTarget, target_count);
        errdefer alloc.free(owned);
        var copied: usize = 0;
        errdefer for (owned[0..copied]) |target| alloc.free(target.path);
        for (owned, 0..) |*destination, index| {
            const path = if (canonical_targets) |targets|
                targets[index].path
            else
                requested_paths[index];
            destination.* = .{
                .path = try alloc.dupe(u8, path),
                .identity = if (canonical_targets) |targets|
                    targets[index].identity
                else
                    null,
            };
            copied += 1;
        }
        return .{ .paths = owned };
    }

    fn deinit(self: Target, alloc: Allocator) void {
        switch (self) {
            .image_ids => |image_ids| alloc.free(image_ids),
            .paths => |paths| {
                for (paths) |target| alloc.free(target.path);
                alloc.free(paths);
            },
        }
    }

    fn matches(
        self: Target,
        request: vision_contracts.VisionRequest,
        canonical_targets: ?[]const CanonicalPathTarget,
    ) bool {
        return switch (self) {
            .image_ids => |stored| blk: {
                const requested = request.image_ids() orelse break :blk false;
                if (stored.len != requested.len) break :blk false;
                for (stored) |candidate| {
                    if (!containsImageId(requested, candidate)) break :blk false;
                }
                break :blk true;
            },
            .paths => |stored| blk: {
                const requested_paths = request.paths() orelse break :blk false;
                if (canonical_targets) |targets| {
                    if (stored.len != targets.len) break :blk false;
                    for (stored) |candidate| {
                        if (!containsCanonicalTarget(targets, candidate)) break :blk false;
                    }
                } else {
                    if (stored.len != requested_paths.len) break :blk false;
                    for (stored) |candidate| {
                        if (!containsPath(requested_paths, candidate.path)) break :blk false;
                    }
                }
                break :blk true;
            },
        };
    }
};

pub const State = struct {
    target: ?Target = null,
    successful_calls: usize = 0,
    warning_emitted: bool = false,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.clear(alloc);
    }

    pub fn clear(self: *State, alloc: Allocator) void {
        if (self.target) |target| target.deinit(alloc);
        self.* = .{};
    }

    /// Starts tracking only valid local Vision calls made without assistant
    /// prose. Any actually executable non-Vision action clears the streak.
    pub fn beginCall(
        self: *State,
        alloc: Allocator,
        call: ToolCall,
        silent_step: bool,
        canonical_targets: ?[]const CanonicalPathTarget,
    ) Allocator.Error!Disposition {
        if (!silent_step or
            call.provenance != .fx_local or
            call.argument_integrity != .valid)
        {
            self.clear(alloc);
            return .untracked;
        }
        if (!std.mem.eql(u8, call.name, "vision")) {
            self.clear(alloc);
            return .untracked;
        }

        const request = vision_contracts.parse_vision_request(
            alloc,
            call.arguments_json,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.clear(alloc);
                return .untracked;
            },
        };
        defer request.deinit(alloc);

        if (canonical_targets) |targets| {
            const paths = request.paths() orelse {
                self.clear(alloc);
                return .untracked;
            };
            if (targets.len != paths.len) {
                self.clear(alloc);
                return .untracked;
            }
        }

        if (self.target == null or !self.target.?.matches(request, canonical_targets)) {
            const replacement = try Target.clone(alloc, request, canonical_targets);
            self.clear(alloc);
            self.target = replacement;
        }

        return if (self.successful_calls >= block_after_successes)
            .block
        else
            .allow;
    }

    /// Returns true exactly once, after the third successful call in a streak.
    pub fn finishCall(self: *State, disposition: Disposition, success: bool) bool {
        if (disposition != .allow) return false;
        if (!success) {
            self.successful_calls = 0;
            self.warning_emitted = false;
            return false;
        }

        self.successful_calls += 1;
        if (!self.warning_emitted and
            self.successful_calls == warning_after_successes)
        {
            self.warning_emitted = true;
            return true;
        }
        return false;
    }
};

fn containsImageId(image_ids: []const usize, candidate: usize) bool {
    for (image_ids) |image_id| {
        if (image_id == candidate) return true;
    }
    return false;
}

fn containsPath(paths: []const []const u8, candidate: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn containsCanonicalTarget(
    targets: []const CanonicalPathTarget,
    candidate: StoredPathTarget,
) bool {
    const identity = candidate.identity orelse return false;
    for (targets) |target| {
        if (std.mem.eql(u8, target.path, candidate.path) and
            std.meta.eql(target.identity, identity)) return true;
    }
    return false;
}

fn visionCall(id: []const u8, arguments_json: []const u8) ToolCall {
    return .{
        .id = id,
        .name = "vision",
        .arguments_json = arguments_json,
    };
}

test "Vision repetition allows five silent successes then blocks the sixth" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const calls = [_]ToolCall{
        visionCall("one", "{\"image_ids\":[2,1],\"focus\":\"inspect cost\"}"),
        visionCall("two", "{\"image_ids\":[1,2],\"focus\":\"find the price\"}"),
        visionCall("three", "{\"image_ids\":[2,1],\"focus\":\"read dollar values\"}"),
        visionCall("four", "{\"image_ids\":[1,2],\"focus\":\"check the total\"}"),
        visionCall("five", "{\"image_ids\":[2,1],\"focus\":\"inspect the footer\"}"),
        visionCall("six", "{\"image_ids\":[1,2],\"focus\":\"look once more\"}"),
    };

    for (calls[0..5], 0..) |call, index| {
        const disposition = try state.beginCall(alloc, call, true, null);
        try std.testing.expectEqual(Disposition.allow, disposition);
        try std.testing.expectEqual(index == 2, state.finishCall(disposition, true));
    }
    try std.testing.expectEqual(
        Disposition.block,
        try state.beginCall(alloc, calls[5], true, null),
    );
}

test "Vision repetition resets for progress and failed inspections" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const first = visionCall(
        "first",
        "{\"paths\":[\"one.png\",\"two.png\"],\"focus\":\"inspect\"}",
    );
    const reordered = visionCall(
        "reordered",
        "{\"paths\":[\"two.png\",\"one.png\"],\"focus\":\"compare\"}",
    );
    const changed = visionCall(
        "changed",
        "{\"paths\":[\"three.png\"],\"focus\":\"inspect\"}",
    );
    const read = ToolCall{
        .id = "read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"notes.txt\"}",
    };

    var disposition = try state.beginCall(alloc, first, true, null);
    try std.testing.expect(!state.finishCall(disposition, true));
    disposition = try state.beginCall(alloc, reordered, true, null);
    try std.testing.expect(!state.finishCall(disposition, true));
    try std.testing.expectEqual(@as(usize, 2), state.successful_calls);

    disposition = try state.beginCall(alloc, changed, true, null);
    try std.testing.expect(!state.finishCall(disposition, true));
    try std.testing.expectEqual(@as(usize, 1), state.successful_calls);

    disposition = try state.beginCall(alloc, changed, true, null);
    try std.testing.expect(!state.finishCall(disposition, false));
    try std.testing.expectEqual(@as(usize, 0), state.successful_calls);

    disposition = try state.beginCall(alloc, changed, true, null);
    try std.testing.expect(!state.finishCall(disposition, true));
    try std.testing.expectEqual(Disposition.untracked, try state.beginCall(alloc, read, true, null));
    try std.testing.expect(state.target == null);

    disposition = try state.beginCall(alloc, changed, true, null);
    try std.testing.expect(!state.finishCall(disposition, true));
    try std.testing.expectEqual(Disposition.untracked, try state.beginCall(alloc, changed, false, null));
    try std.testing.expect(state.target == null);
}

test "Vision repetition matches canonical paths across equivalent spellings" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const calls = [_]ToolCall{
        visionCall("one", "{\"paths\":[\"image.png\"],\"focus\":\"inspect\"}"),
        visionCall("two", "{\"paths\":[\"./image.png\"],\"focus\":\"compare\"}"),
        visionCall("three", "{\"paths\":[\"/workspace/image.png\"],\"focus\":\"read\"}"),
        visionCall("four", "{\"paths\":[\"image.png\"],\"focus\":\"check\"}"),
        visionCall("five", "{\"paths\":[\"./image.png\"],\"focus\":\"verify\"}"),
        visionCall("six", "{\"paths\":[\"/workspace/image.png\"],\"focus\":\"again\"}"),
    };
    const canonical_targets: []const CanonicalPathTarget = &.{.{
        .path = "/workspace/image.png",
        .identity = .{ .device = 1, .inode = 2, .kind = .file },
    }};

    for (calls[0..5]) |call| {
        const disposition = try state.beginCall(
            alloc,
            call,
            true,
            canonical_targets,
        );
        try std.testing.expectEqual(Disposition.allow, disposition);
        _ = state.finishCall(disposition, true);
    }
    try std.testing.expectEqual(
        Disposition.block,
        try state.beginCall(alloc, calls[5], true, canonical_targets),
    );
}
