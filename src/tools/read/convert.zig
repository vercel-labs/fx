//! Documents and databases read_file converts to text through Python
//! (D163): PDF, docx, pptx, xlsx and epub, and read-only SQLite. With a
//! session kernel slot the converter runs in the node's pooled `fx-read`
//! kernel, warm after the first read and kept apart from the user's own
//! namespace; without one it runs once as `python3 -I`. SQLite falls back to
//! the system `sqlite3 -readonly` when no Python exists. Office formats and
//! SQLite need only the standard library; PDF uses pypdf or markitdown when
//! installed and a rough built-in text extractor otherwise.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const kernel_slot = @import("../../core/kernel/slot.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

const script = @embedFile("convert.py");
const kernel_name = "fx-read";
const max_output_bytes: usize = 8 * 1024 * 1024;
const timeout_ms: u64 = 60_000;

pub const Kind = enum { pdf, docx, pptx, xlsx, epub, sqlite };

/// The document kind a path's extension names, or null.
pub fn documentKind(path: []const u8) ?Kind {
    const ext = std.Io.Dir.path.extension(path);
    inline for (.{ .pdf, .docx, .pptx, .xlsx, .epub }) |kind| {
        if (std.ascii.eqlIgnoreCase(ext, "." ++ @tagName(kind))) return kind;
    }
    return null;
}

pub const Outcome = union(enum) {
    text: []u8,
    failure: []u8,

    pub fn deinit(self: Outcome, alloc: Allocator) void {
        switch (self) {
            inline else => |bytes| alloc.free(bytes),
        }
    }
};

/// Converts the absolute `path`. `arg` is the SQLite table spec. Caller
/// owns the outcome.
pub fn run(ctx: tool_dispatch.DispatchContext, kind: Kind, path: []const u8, arg: []const u8) !Outcome {
    const alloc = ctx.allocator;
    const reply = blk: {
        if (ctx.kernel) |slot| {
            if (try runInKernel(ctx, slot, kind, path, arg)) |reply| {
                debug_trace.logf("read", "convert kind={s} via=kernel bytes={d}", .{ @tagName(kind), reply.len });
                break :blk reply;
            }
        }
        debug_trace.logf("read", "convert kind={s} via=python3", .{@tagName(kind)});
        break :blk runOnce(alloc, kind, path, arg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => {
                if (kind == .sqlite) return sqliteCli(alloc, path, arg);
                return .{ .failure = try alloc.print("Reading {s} files needs Python 3 on PATH; none was found.", .{@tagName(kind)}) };
            },
            else => return .{ .failure = try alloc.print("The {s} converter failed to start: {s}", .{ @tagName(kind), @errorName(err) }) },
        };
    };
    defer alloc.free(reply);
    return parseReply(alloc, kind, reply);
}

fn parseReply(alloc: Allocator, kind: Kind, reply: []const u8) !Outcome {
    const start = std.mem.find(u8, reply, "{\"ok\"") orelse
        return .{ .failure = try alloc.print("The {s} converter returned no result: {s}", .{ @tagName(kind), clip(reply, 400) }) };
    const Reply = struct { ok: bool, text: ?[]const u8 = null, @"error": ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Reply, alloc, std.mem.trimEnd(u8, reply[start..], " \r\n"), .{ .ignore_unknown_fields = true }) catch
        return .{ .failure = try alloc.print("The {s} converter returned malformed output.", .{@tagName(kind)}) };
    defer parsed.deinit();
    if (parsed.value.ok) return .{ .text = try alloc.dupe(u8, parsed.value.text orelse "") };
    return .{ .failure = try alloc.print("Converting the {s} failed: {s}", .{ @tagName(kind), parsed.value.@"error" orelse "unknown error" }) };
}

fn clip(text: []const u8, max: usize) []const u8 {
    return if (text.len <= max) text else text[0..max];
}

/// Null when the kernel cannot start, so the caller runs Python once instead.
fn runInKernel(ctx: tool_dispatch.DispatchContext, slot: *kernel_slot.Slot, kind: Kind, path: []const u8, arg: []const u8) !?[]u8 {
    const alloc = ctx.allocator;
    const manager = slot.ensureNamed(ctx.lifecycle_allocator, .{ .cwd = ctx.workspace_root, .session_id = null }, kernel_name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var code: std.Io.Writer.Allocating = .init(alloc);
    defer code.deinit();
    const w = &code.writer;
    try w.writeAll("_fxr = globals().get('_fx_read')\nif _fxr is None:\n    _fxr = {'__name__': '_fx_read'}\n    exec(");
    try std.json.Stringify.value(script, .{}, w);
    try w.writeAll(", _fxr)\n    globals()['_fx_read'] = _fxr\nimport json as _fx_json\nprint(_fx_json.dumps(_fxr['run'](");
    try std.json.Stringify.value(@tagName(kind), .{}, w);
    try w.writeAll(", ");
    try std.json.Stringify.value(path, .{}, w);
    try w.writeAll(", ");
    try std.json.Stringify.value(arg, .{}, w);
    try w.writeAll(")))\n");
    const result = manager.execute(alloc, code.written(), .{
        .cancel = ctx.cancel_flag,
        .timeout_ms = timeout_ms,
        .max_output_chars = max_output_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer result.deinit(alloc);
    if (result.status != .ok) return null;
    return try alloc.dupe(u8, result.stdout);
}

fn runOnce(alloc: Allocator, kind: Kind, path: []const u8, arg: []const u8) ![]u8 {
    const io = io_mod.getIo();
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "python3", "-I", "-c", script, @tagName(kind), path, arg },
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    });
    defer alloc.free(result.stderr);
    return result.stdout;
}

/// Read-only SQLite through the system `sqlite3` shell, for hosts without
/// Python. It lists tables or shows a table's schema and first rows.
fn sqliteCli(alloc: Allocator, path: []const u8, spec: []const u8) !Outcome {
    const table = spec[0 .. std.mem.findAny(u8, spec, ":?") orelse spec.len];
    for (table) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
        return .{ .failure = try alloc.dupe(u8, "Without Python, SQLite reads support only plain table names.") };
    };
    const sql = if (table.len == 0)
        try alloc.dupe(u8, ".tables")
    else
        try alloc.print(".schema {s}\n.headers on\n.mode markdown\nSELECT * FROM \"{s}\" LIMIT 20;", .{ table, table });
    defer alloc.free(sql);
    const io = io_mod.getIo();
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "sqlite3", "-readonly", "-batch", path, sql },
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try alloc.dupe(u8, "Reading SQLite needs Python 3 or the sqlite3 shell on PATH; neither was found.") },
    };
    defer alloc.free(result.stderr);
    if (result.stderr.len > 0 and result.stdout.len == 0) {
        defer alloc.free(result.stdout);
        return .{ .failure = try alloc.print("sqlite3 failed: {s}", .{clip(result.stderr, 400)}) };
    }
    return .{ .text = result.stdout };
}

test "document kinds come from the extension" {
    try std.testing.expectEqual(Kind.pdf, documentKind("a/Report.PDF").?);
    try std.testing.expectEqual(Kind.xlsx, documentKind("q.xlsx").?);
    try std.testing.expect(documentKind("a.txt") == null);
}

test "converter replies parse into text or a failure" {
    const alloc = std.testing.allocator;
    const ok = try parseReply(alloc, .pdf, "noise\n{\"ok\": true, \"text\": \"hello\"}\n");
    defer ok.deinit(alloc);
    try std.testing.expectEqualStrings("hello", ok.text);
    const bad = try parseReply(alloc, .docx, "{\"ok\": false, \"error\": \"KeyError: x\"}");
    defer bad.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, bad.failure, "KeyError: x") != null);
}

test "the python converter reads sqlite read-only and office files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const db = try std.Io.Dir.path.join(alloc, &.{ root, "app.db" });
    defer alloc.free(db);
    const setup = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "python3", "-I", "-c", "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('create table users(id integer primary key, name text)'); c.executemany('insert into users(name) values (?)', [('ada',),('lin',)]); c.commit()", db },
    }) catch return error.SkipZigTest;
    alloc.free(setup.stdout);
    alloc.free(setup.stderr);

    const ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc };
    const tables = try run(ctx, .sqlite, db, "");
    defer tables.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, tables.text, "- users (table, 2 rows): id, name") != null);
    const rows = try run(ctx, .sqlite, db, "users");
    defer rows.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, rows.text, "| 2 | lin |") != null);
    const row = try run(ctx, .sqlite, db, "users:1");
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.text, "name: 'ada'") != null);
    const refused = try run(ctx, .sqlite, db, "?q=DELETE FROM users");
    defer refused.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, refused.text, "Refused"));
    const query = try run(ctx, .sqlite, db, "?q=SELECT count(*) AS n FROM users");
    defer query.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, query.text, "| 2 |") != null);
}
