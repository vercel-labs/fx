//! The read_file targets beyond a plain text file (D160): URLs, `skill://`,
//! directories, archives, gzip streams, SQLite, documents and notebooks.
//! Each turns its target into text and hands it to read_file's numbered
//! line window, so selectors work the same everywhere.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const read_target = @import("../../core/workspace/read_target.zig");
const skill_invocation = @import("../../core/skills/skill_invocation.zig");
const read_file = @import("../filesystem/read_file.zig");
const web_fetch = @import("../web/fetch.zig");
const archive = @import("archive.zig");
const convert = @import("convert.zig");
const directory = @import("directory.zig");
const notebook = @import("notebook.zig");

const Allocator = std.mem.Allocator;
const ToolResult = tool_dispatch.ToolResult;
const DispatchError = tool_dispatch.DispatchError;
const Ctx = tool_dispatch.DispatchContext;
const Input = read_file.Input;

/// Largest archive member or decompressed stream read into memory.
const max_member_bytes: usize = 10 * 1024 * 1024;

pub fn isDirectory(path: []const u8) bool {
    const io = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

pub fn readDirectory(ctx: Ctx, input: *Input, path: []const u8, display_path: []const u8) DispatchError!ToolResult {
    const display = if (display_path.len == 0) "." else display_path;
    const text = directory.list(ctx.allocator, path, display, ctx.cancel_flag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Cancelled,
        else => return failure(ctx.allocator, "Listing {s} failed: {s}", .{ display, @errorName(err) }),
    };
    defer ctx.allocator.free(text);
    return read_file.windowedText(ctx, input, display, "", text);
}

pub fn readNotebook(ctx: Ctx, input: *Input, json_text: []const u8, display: []const u8) DispatchError!ToolResult {
    const text = notebook.render(ctx.allocator, json_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "{s} is not a valid notebook; read it with {s}:raw for the JSON.", .{ display, display }),
    };
    defer ctx.allocator.free(text);
    return read_file.windowedText(ctx, input, display, "", text);
}

pub fn readDocument(ctx: Ctx, input: *Input, kind: convert.Kind, path: []const u8, display: []const u8) DispatchError!ToolResult {
    const outcome = try runConverter(ctx, kind, path, "");
    defer outcome.deinit(ctx.allocator);
    return switch (outcome) {
        .failure => |message| failure(ctx.allocator, "{s}: {s}", .{ display, message }),
        .text => |text| read_file.windowedText(ctx, input, display, "", text),
    };
}

fn runConverter(ctx: Ctx, kind: convert.Kind, path: []const u8, arg: []const u8) DispatchError!convert.Outcome {
    return convert.run(ctx, kind, path, arg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.print("the {s} converter failed: {s}", .{ @tagName(kind), @errorName(err) }) },
    };
}

pub fn readContainer(ctx: Ctx, input: *Input, target: read_target.Target, path: []const u8, display: []const u8) DispatchError!ToolResult {
    const alloc = ctx.allocator;
    switch (target.container) {
        .none => unreachable,
        .sqlite => {
            const outcome = try runConverter(ctx, .sqlite, path, target.inner);
            defer outcome.deinit(alloc);
            const label = try labelFor(alloc, display, target.inner);
            defer alloc.free(label);
            return switch (outcome) {
                .failure => |message| failure(alloc, "{s}: {s}", .{ label, message }),
                .text => |text| read_file.windowedText(ctx, input, label, "", text),
            };
        },
        .gzip => {
            const bytes = archive.readGzip(alloc, path, max_member_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return failure(alloc, "Decompressing {s} failed: {s}", .{ display, @errorName(err) }),
            };
            defer alloc.free(bytes);
            return memberText(ctx, input, display, bytes);
        },
        .archive => {},
    }
    const inner = target.inner;
    if (inner.len == 0 or inner[inner.len - 1] == '/') return listArchive(ctx, input, path, display, inner);
    const bytes = archive.readMember(alloc, path, inner, max_member_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MemberIsDirectory => {
            const prefix = try alloc.print("{s}/", .{std.mem.trimEnd(u8, inner, "/")});
            defer alloc.free(prefix);
            return listArchive(ctx, input, path, display, prefix);
        },
        error.MemberNotFound => return failure(alloc, "{s} has no member {s}; read {s} to list its members.", .{ display, inner, display }),
        error.MemberTooLarge => return failure(alloc, "{s} in {s} is larger than 10 MiB; extract it with the shell instead.", .{ inner, display }),
        else => return failure(alloc, "Reading {s} from {s} failed: {s}", .{ inner, display, @errorName(err) }),
    };
    defer alloc.free(bytes);
    const label = try labelFor(alloc, display, inner);
    defer alloc.free(label);
    if (!input.selector.raw and notebook.isNotebookPath(inner)) return readNotebook(ctx, input, bytes, label);
    return memberText(ctx, input, label, bytes);
}

fn listArchive(ctx: Ctx, input: *Input, path: []const u8, display: []const u8, prefix: []const u8) DispatchError!ToolResult {
    const text = archive.list(ctx.allocator, path, display, prefix) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "Reading archive {s} failed: {s}", .{ display, @errorName(err) }),
    };
    defer ctx.allocator.free(text);
    return read_file.windowedText(ctx, input, display, "", text);
}

fn memberText(ctx: Ctx, input: *Input, label: []const u8, bytes: []const u8) DispatchError!ToolResult {
    if (!text_utils.isModelSafeText(bytes)) {
        return .{ .success = try ctx.allocator.print("<path>{s}</path>\n<content>binary or non-utf8 content omitted ({d} bytes)</content>", .{ label, bytes.len }) };
    }
    return read_file.windowedText(ctx, input, label, "", bytes);
}

fn labelFor(alloc: Allocator, display: []const u8, inner: []const u8) ![]u8 {
    if (inner.len == 0) return alloc.dupe(u8, display);
    if (inner[0] == '?') return alloc.print("{s}{s}", .{ display, inner });
    return alloc.print("{s}:{s}", .{ display, inner });
}

/// Fetches through web_fetch, so the URL policy, its cache and its
/// artifacts apply as they do to web_fetch; the admission layer already
/// checked the call against the web_fetch permission rules.
pub fn readUrl(ctx: Ctx, input: *Input, target: read_target.Target) DispatchError!ToolResult {
    const alloc = ctx.allocator;
    var fetch_input: web_fetch.Input = .{ .url = try alloc.dupe(u8, target.base) };
    defer fetch_input.deinit(alloc);
    const erased: tool_dispatch.ToolInput = .{ .ptr = &fetch_input, .deinit_fn = noopDeinit };
    if (try web_fetch.validate(ctx, erased)) |message| {
        defer alloc.free(message);
        const rewritten = try std.mem.replaceOwned(u8, alloc, message, "web_fetch field \"url\"", "read_file URL");
        defer alloc.free(rewritten);
        return .{ .failure = try std.mem.replaceOwned(u8, alloc, rewritten, "web_fetch", "read_file") };
    }
    const result = try web_fetch.call(ctx, erased);
    const body = switch (result) {
        .success => |body| body,
        else => return result,
    };
    defer alloc.free(body);
    const open_tag = "<content>\n";
    const start = std.mem.find(u8, body, open_tag) orelse return .{ .success = try alloc.dupe(u8, body) };
    const end = std.mem.findLast(u8, body, "\n</content>") orelse body.len;
    if (end < start + open_tag.len) return .{ .success = try alloc.dupe(u8, body) };
    return read_file.windowedText(ctx, input, target.base, body[0..start], body[start + open_tag.len .. end]);
}

fn noopDeinit(_: *anyopaque, _: Allocator) void {}

/// `skill://<name>` reads a skill's SKILL.md and `skill://<name>/<path>` one
/// of its resources, through the same loader as the skill tool.
pub fn readSkill(ctx: Ctx, input: *Input, target: read_target.Target) DispatchError!ToolResult {
    _ = input;
    const alloc = ctx.allocator;
    const rest = target.base["skill://".len..];
    const slash = std.mem.findScalar(u8, rest, '/');
    const name = rest[0 .. slash orelse rest.len];
    const resource: ?[]const u8 = if (slash) |at| (if (at + 1 < rest.len) rest[at + 1 ..] else null) else null;
    const skills = if (ctx.skill_locations) |locations| locations.skills else &.{};
    const skill = for (skills) |*candidate| {
        if (std.mem.eql(u8, candidate.name, name)) break candidate;
    } else {
        var names: std.Io.Writer.Allocating = .init(alloc);
        defer names.deinit();
        for (skills, 0..) |candidate, i| names.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", candidate.name }) catch return error.OutOfMemory;
        return failure(alloc, "Unknown skill {s}. Installed: {s}", .{ name, if (skills.len == 0) "none" else names.written() });
    };
    const catalog: skill_invocation.Catalog = .{ .skills = &.{skill.*} };
    const result = skill_invocation.loadWholeByLocation(alloc, catalog, skill.path, resource, ctx.context_limits, ctx.max_tool_result_bytes, ctx.cancel_flag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return failure(alloc, "Reading {s} failed: {s}", .{ target.base, @errorName(err) }),
    };
    return switch (result) {
        .failure => .{ .failure = skill_invocation.takeModelOutput(alloc, result) },
        .loaded => .{ .success = skill_invocation.takeModelOutput(alloc, result) },
    };
}

fn failure(alloc: Allocator, comptime fmt: []const u8, args: anytype) DispatchError!ToolResult {
    return .{ .failure = try alloc.print(fmt, args) };
}
