//! `local://`, the session tree's scratch folder (D243), after proto's
//! local protocol: `local://` lists it and `local://<path>` reads a file or
//! folder in it like any other read_file target, selectors included. The
//! folder is `~/.proto-fx/local/<root session id>/`, private, shared by the
//! session and its subagents, so large intermediate data and handoffs
//! survive across turns. A path never leaves the folder, through `..` or
//! through a symlink, so a read here needs no file permission.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const profile_paths = @import("../../core/shared/profile_paths.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const read_target = @import("../../core/workspace/read_target.zig");
const read_file = @import("../filesystem/read_file.zig");
const local_folder = @import("../../core/session/local_folder.zig");

const Allocator = std.mem.Allocator;
const ToolResult = tool_dispatch.ToolResult;
const DispatchError = tool_dispatch.DispatchError;
const Ctx = tool_dispatch.DispatchContext;

pub const prefix = "local://";
const max_listed_files: usize = 500;

pub fn read(ctx: Ctx, input: *read_file.Input, target: read_target.Target) DispatchError!ToolResult {
    const home = io_mod.homeDir() orelse return failure(ctx.allocator, "{s} is unavailable: HOME is not set.", .{target.base});
    return readIn(ctx, input, target, home);
}

/// `read` with the profile under `home`.
fn readIn(ctx: Ctx, input: *read_file.Input, target: read_target.Target, home: []const u8) DispatchError!ToolResult {
    const alloc = ctx.allocator;
    const view = ctx.node_view orelse return failure(alloc, "{s} is unavailable: this run has no saved session.", .{target.base});
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = openRoot(arena, home, view.root_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(alloc, "The local:// folder is unavailable: {s}", .{@errorName(err)}),
    };
    const relative = std.mem.trimStart(u8, target.base[prefix.len..], "/");
    if (!validRelative(relative)) return failure(alloc, "{s} must name a path inside the local:// folder, without .. or backslashes.", .{target.base});
    if (relative.len == 0) return listing(ctx, input, root);

    // The suffix after the internal URL (a selector) and any archive
    // member or table inside it parse as they would on a plain path.
    const suffix = input.path[@min(input.path.len, target.base.len)..];
    const absolute = try std.mem.concat(arena, u8, &.{ root, "/", relative, suffix });
    const parsed = read_target.parse(absolute);
    const real = io_mod.realpathAlloc(arena, parsed.base) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return failure(alloc, "Local file not found: {s}. Read local:// to list the folder.", .{target.base}),
        else => return failure(alloc, "Reading {s} failed: {s}", .{ target.base, @errorName(err) }),
    };
    if (!pathing.pathInside(root, real)) return failure(alloc, "{s} leaves the local:// folder.", .{target.base});
    const owned = try alloc.dupe(u8, try std.mem.concat(arena, u8, &.{ real, absolute[parsed.base.len..] }));
    alloc.free(input.path);
    input.path = owned;
    return read_file.call(ctx, .{ .ptr = input, .deinit_fn = noopDeinit });
}

fn noopDeinit(_: *anyopaque, _: Allocator) void {}

/// Creates `<home>/.proto-fx/local/<root_id>` as a private folder and
/// returns its real path, owned by `arena`.
fn openRoot(arena: Allocator, home: []const u8, root_id: []const u8) ![]const u8 {
    return local_folder.open(arena, home, root_id);
}

fn validRelative(relative: []const u8) bool {
    if (std.mem.findAny(u8, relative, "\\\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Every file under the folder, as `local://` links, sorted.
fn listing(ctx: Ctx, input: *read_file.Input, root: []const u8) DispatchError!ToolResult {
    const alloc = ctx.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = io_mod.getIo();
    var files: std.ArrayList([]const u8) = .empty;
    var more = false;
    {
        var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch |err| return failure(alloc, "Listing local:// failed: {s}", .{@errorName(err)});
        defer dir.close(io);
        var walker = dir.walk(arena) catch return error.OutOfMemory;
        defer walker.deinit();
        while (walker.next(io) catch |err| return failure(alloc, "Listing local:// failed: {s}", .{@errorName(err)})) |entry| {
            if (entry.kind != .file) continue;
            if (files.items.len == max_listed_files) {
                more = true;
                break;
            }
            try files.append(arena, try arena.dupe(u8, entry.path));
        }
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("# Local\n\nSession scratch space for large intermediate data, subagent handoffs and reusable plans. It lasts as long as the session.\n\nRoot: {s}\nWrite files there with your write tools; read them back here as local://<path>.\n\n", .{root}) catch return error.OutOfMemory;
    if (files.items.len == 0) {
        w.writeAll("(empty)\n") catch return error.OutOfMemory;
    } else {
        w.print("{d} file{s}{s}:\n\n", .{ files.items.len, if (files.items.len == 1) "" else "s", if (more) " shown" else "" }) catch return error.OutOfMemory;
        for (files.items) |file| w.print("- local://{s}\n", .{file}) catch return error.OutOfMemory;
    }
    return read_file.windowedText(ctx, input, prefix, "", out.written());
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn failure(alloc: Allocator, comptime fmt: []const u8, args: anytype) DispatchError!ToolResult {
    return .{ .failure = try alloc.print(fmt, args) };
}

const testing = std.testing;

fn testRead(alloc: Allocator, home: []const u8, workspace: []const u8, path: []const u8) !ToolResult {
    var input: read_file.Input = .{ .path = try alloc.dupe(u8, path) };
    defer input.deinit(alloc);
    const view: @import("../../core/recall/recall.zig").NodeView = .{ .source = undefined, .cache = undefined, .root_id = "root-1", .node_id = "child-2" };
    const ctx: Ctx = .{ .allocator = alloc, .workspace_root = workspace, .node_view = view };
    const erased: tool_dispatch.ToolInput = .{ .ptr = &input, .deinit_fn = noopDeinit };
    if (try read_file.validate(ctx, erased)) |message| {
        defer alloc.free(message);
        return error.TestUnexpectedResult;
    }
    return readIn(ctx, &input, read_target.parse(input.path), home);
}

fn resultText(result: ToolResult) []const u8 {
    return switch (result) {
        .success => |text| text,
        .failure => |text| text,
        else => "",
    };
}

test "local:// lists and reads the session tree's scratch folder and never leaves it" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "home");
    try tmp.dir.createDirPath(testing.io, "ws");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "secret.txt", .data = "SECRET" });
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "ws");
    defer alloc.free(workspace);

    const empty = try testRead(alloc, home, workspace, "local://");
    defer empty.deinit(alloc);
    try testing.expect(empty == .success);
    try testing.expect(std.mem.find(u8, resultText(empty), "(empty)") != null);

    // The root is keyed by the tree's root session, so a child shares it.
    try tmp.dir.createDirPath(testing.io, "home/.proto-fx/local/root-1/plans");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.proto-fx/local/root-1/plans/step.md", .data = "one\ntwo\nthree\n" });
    const listed = try testRead(alloc, home, workspace, "local:///");
    defer listed.deinit(alloc);
    try testing.expect(std.mem.find(u8, resultText(listed), "local://plans/step.md") != null);

    const ranged = try testRead(alloc, home, workspace, "local://plans/step.md:2-2");
    defer ranged.deinit(alloc);
    try testing.expect(ranged == .success);
    try testing.expect(std.mem.find(u8, resultText(ranged), "two") != null);
    try testing.expect(std.mem.find(u8, resultText(ranged), "three") == null);

    const folder = try testRead(alloc, home, workspace, "local://plans");
    defer folder.deinit(alloc);
    try testing.expect(std.mem.find(u8, resultText(folder), "step.md") != null);

    const missing = try testRead(alloc, home, workspace, "local://nope.txt");
    defer missing.deinit(alloc);
    try testing.expect(missing == .failure);

    const dotdot = try testRead(alloc, home, workspace, "local://../../../secret.txt");
    defer dotdot.deinit(alloc);
    try testing.expect(dotdot == .failure);
    try testing.expect(std.mem.find(u8, resultText(dotdot), "SECRET") == null);

    // A symlink inside the folder cannot reach a file outside it.
    const secret = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "secret.txt");
    defer alloc.free(secret);
    try tmp.dir.symLink(testing.io, secret, "home/.proto-fx/local/root-1/link.txt", .{});
    const linked = try testRead(alloc, home, workspace, "local://link.txt");
    defer linked.deinit(alloc);
    try testing.expect(linked == .failure);
    try testing.expect(std.mem.find(u8, resultText(linked), "SECRET") == null);
}

test "local:// needs a saved session" {
    const alloc = testing.allocator;
    var input: read_file.Input = .{ .path = try alloc.dupe(u8, "local://") };
    defer input.deinit(alloc);
    const result = try readIn(.{ .allocator = alloc }, &input, read_target.parse(input.path), "/nonexistent-home");
    defer result.deinit(alloc);
    try testing.expect(result == .failure);
}
