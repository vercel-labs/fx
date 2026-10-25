//! `fs.*`: file reads and edits for Python, through the agent's own file
//! tools, plus the two requests behind the stale-write guard.
//!
//! - `fs.read` returns a file's text and hash and records that the agent
//!   saw it.
//! - `fs.replace` checks that `old` occurs exactly `count` times, then edits
//!   through `edit_file` (one anchor) or `write_file` (several), so the edit
//!   takes the node's permission request, is shown as a diff, and is
//!   recorded and undoable like a model edit.
//! - `fs.write` writes through `write_file` after checking `expect`, a hash
//!   from `fs.read`, or, without one, that the file did not change since the
//!   agent last saw it.
//! - `fs.check` answers the guard in a fresh Python before it opens an
//!   existing file for writing; `fs.seen` records the reads it reported.
//!
//! The client sends absolute paths: Python resolves them against its own
//! working directory, which the host does not know.
const std = @import("std");
const protocol = @import("../protocol.zig");
const op_tool = @import("../op_tool.zig");
const seen = @import("../seen.zig");
const io_mod = @import("../../shared/io.zig");
const Allocator = std.mem.Allocator;

/// The file tools' own limit on what they prepare.
const max_text_bytes: usize = 4 << 20;

pub const read = struct {
    pub const name = "fs.read";
    pub const Args = struct { path: []const u8 };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const path = (try absolute(call, args.path)) orelse return badPath(call, args.path);
        const text = switch (try load(call.arena, path)) {
            .text => |text| text,
            .missing => return call.fail(.tool_failed, "{s} does not exist", .{path}),
            .failed => |reason| return call.fail(.tool_failed, "cannot read {s}: {s}", .{ path, reason }),
        };
        seen.noteFile(call.lease.node_id, path);
        const hash = seen.hex(hashOf(text));
        return call.ok(.{ .path = path, .text = text, .hash = &hash });
    }
};

pub const replace = struct {
    pub const name = "fs.replace";
    pub const Args = struct {
        path: []const u8,
        old: []const u8,
        new: []const u8,
        count: u32 = 1,
    };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const path = (try absolute(call, args.path)) orelse return badPath(call, args.path);
        if (args.old.len == 0) return call.fail(.bad_request, "fs.replace needs a non-empty old text", .{});
        if (args.count == 0) return call.fail(.bad_request, "fs.replace count must be at least 1", .{});
        if (std.mem.eql(u8, args.old, args.new)) return call.fail(.bad_request, "fs.replace old and new are the same text", .{});
        const before = switch (try load(call.arena, path)) {
            .text => |text| text,
            .missing => return call.fail(.tool_failed, "{s} does not exist", .{path}),
            .failed => |reason| return call.fail(.tool_failed, "cannot read {s}: {s}", .{ path, reason }),
        };
        const found = std.mem.count(u8, before, args.old);
        if (found != args.count) return .{ .failure = .{
            .kind = .anchor_mismatch,
            .message = try call.arena.print("expected {d} occurrence{s} of the old text in {s}, found {d}; nothing was written", .{ args.count, if (args.count == 1) "" else "s", path, found }),
        } };
        var json: std.Io.Writer.Allocating = .init(call.arena);
        const after = try std.mem.replaceOwned(u8, call.arena, before, args.old, args.new);
        if (after.len > max_text_bytes) return call.fail(.refused, "the edited {s} would exceed the 4 MiB edit limit", .{path});
        const tool_name = if (args.count == 1) "edit_file" else "write_file";
        if (args.count == 1) {
            try std.json.Stringify.value(.{ .path = path, .old_string = args.old, .new_string = args.new }, .{}, &json.writer);
        } else {
            try std.json.Stringify.value(.{ .path = path, .content = after }, .{}, &json.writer);
        }
        if (try runTool(call, tool_name, json.written())) |failure| return failure;
        const hash = seen.hex(hashOf(after));
        return call.ok(.{ .path = path, .replaced = args.count, .hash = &hash });
    }
};

pub const write = struct {
    pub const name = "fs.write";
    pub const Args = struct {
        path: []const u8,
        text: []const u8,
        /// The hash `fs.read` returned; the write happens only if the file
        /// still has it. Null checks the guard instead.
        expect: ?[]const u8 = null,
    };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const path = (try absolute(call, args.path)) orelse return badPath(call, args.path);
        if (args.text.len > max_text_bytes) return call.fail(.refused, "fs.write text exceeds the 4 MiB edit limit", .{});
        if (args.expect) |expected| {
            const current: ?[]const u8 = switch (try load(call.arena, path)) {
                .text => |text| try call.arena.dupe(u8, &seen.hex(hashOf(text))),
                .missing => null,
                .failed => |reason| return call.fail(.tool_failed, "cannot read {s}: {s}", .{ path, reason }),
            };
            if (current == null or !std.ascii.eqlIgnoreCase(current.?, expected)) return .{ .failure = .{
                .kind = .stale,
                .message = try call.arena.print("{s} is not the version you read (expected hash {s}, the file {s}); read it again and redo the change", .{ path, expected, if (current == null) "is gone" else "has changed" }),
            } };
        } else if (try staleFailure(call, path)) |failure| return failure;
        var json: std.Io.Writer.Allocating = .init(call.arena);
        try std.json.Stringify.value(.{ .path = path, .content = args.text }, .{}, &json.writer);
        if (try runTool(call, "write_file", json.written())) |failure| return failure;
        const hash = seen.hex(hashOf(args.text));
        return call.ok(.{ .path = path, .hash = &hash });
    }
};

pub const check = struct {
    pub const name = "fs.check";
    pub const Args = struct {
        path: []const u8,
        /// Reads the process made before this write, not yet reported.
        seen: []const Seen = &.{},
    };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        noteAll(call, args.seen);
        const path = (try absolute(call, args.path)) orelse return call.ok(.{ .stale = false });
        if (try staleFailure(call, path)) |failure| return failure;
        // This process writes the file now; until the agent reads it again,
        // there is nothing it saw to protect.
        seen.forget(call.lease.node_id, path);
        return call.ok(.{ .stale = false });
    }
};

pub const Seen = struct { path: []const u8, mtime_ns: i64, size: u64 };

pub const note = struct {
    pub const name = "fs.seen";
    pub const Args = struct { seen: []const Seen };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        noteAll(call, args.seen);
        return .none;
    }
};

fn noteAll(call: *protocol.Call, reads: []const Seen) void {
    for (reads[0..@min(reads.len, 1024)]) |entry| {
        if (!std.Io.Dir.path.isAbsolute(entry.path)) continue;
        seen.noteReported(call.lease.node_id, entry.path, entry.mtime_ns, entry.size);
    }
}

fn staleFailure(call: *protocol.Call, path: []const u8) !?protocol.Reply {
    return switch (seen.check(call.lease.node_id, path)) {
        .unknown, .fresh => null,
        .stale => |change| .{ .failure = .{
            .kind = .stale,
            .message = try call.arena.print("{s} changed on disk since the agent last read it ({d} bytes then, {d} now); read it again and redo the change", .{ path, change.seen.size, change.now.size }),
        } },
    };
}

/// Runs a file tool for the node; null when it succeeded, otherwise the
/// reply that says why not.
fn runTool(call: *protocol.Call, tool_name: []const u8, arguments_json: []const u8) !?protocol.Reply {
    const reply = try op_tool.callTool(call, tool_name, arguments_json);
    const value = switch (reply) {
        .value => |value| value,
        else => return reply,
    };
    const Ran = struct { status: []const u8, output: []const u8 };
    const ran = std.json.parseFromSliceLeaky(Ran, call.arena, value, .{}) catch return try call.fail(.internal, "{s} answered in an unexpected form", .{tool_name});
    if (std.mem.eql(u8, ran.status, "success")) return null;
    return .{ .failure = .{ .kind = .tool_failed, .message = try call.arena.print("{s} failed", .{tool_name}), .output = ran.output } };
}

fn absolute(call: *protocol.Call, path: []const u8) !?[]const u8 {
    if (path.len == 0 or !std.Io.Dir.path.isAbsolute(path) or std.mem.findScalar(u8, path, 0) != null) return null;
    return try std.Io.Dir.path.resolveAlloc(call.arena, &.{path});
}

fn badPath(call: *protocol.Call, path: []const u8) !protocol.Reply {
    return call.fail(.bad_request, "fs needs an absolute path, not \"{s}\"", .{path});
}

const Loaded = union(enum) { text: []const u8, missing, failed: []const u8 };

fn load(arena: Allocator, path: []const u8) !Loaded {
    const io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        else => .{ .failed = @errorName(err) },
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| return .{ .failed = @errorName(err) };
    if (stat.kind != .file) return .{ .failed = "not a regular file" };
    if (stat.size > max_text_bytes) return .{ .failed = "larger than the 4 MiB edit limit" };
    const bytes = io_mod.readFileToEnd(arena, &file, max_text_bytes) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => .{ .failed = @errorName(err) },
    };
    if (!std.unicode.utf8ValidateSlice(bytes)) return .{ .failed = "not UTF-8 text" };
    return .{ .text = bytes };
}

fn hashOf(text: []const u8) seen.Hash {
    var hash: seen.Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return hash;
}

test "fs paths must be absolute and anchors are counted without overlap" {
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, "aaaa", "aa"));
    try std.testing.expect(!std.Io.Dir.path.isAbsolute("rel/a.txt"));
}
