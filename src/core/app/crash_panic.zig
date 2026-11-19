//! Saves a crash record when fx panics, so `/trace` can show it as `last_crash`.
//!
//! When a panic starts, the handler writes two JSON lines to
//! `~/.fx/diagnostics/last-crash.jsonl`: the `fx_trace` header and a
//! `fatal_error` record whose error is `panic`. `trace_report.zig` reads that
//! file. The handler then calls `std.debug.defaultPanic`, so stderr and the
//! abort stay as they were.
//!
//! The handler can run on any thread and in any state, so it does not allocate,
//! take a lock, or create folders. `prepare` computes the path at startup, and
//! the `diagnostics` folder must already exist. A write that fails is ignored.
//! The renderer event ring is not saved, because reading it needs a blocking
//! lock that the handler does not take. Segfaults do not reach this handler:
//! `std.debug` prints them and aborts on its own.

const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");
const local_time = @import("../shared/local_time.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const trace_report = @import("trace_report.zig");
const writeJsonStr = @import("../../acp/jsonrpc.zig").writeJsonStr;

/// The most bytes of a panic message that the record keeps. Escaping can make
/// the kept text up to six times longer, which still fits `record_buf_bytes`.
const max_message_bytes = 512;
/// Holds both lines at the longest kept message, with room for long version
/// and commit text.
const record_buf_bytes = 8192;
const path_max_bytes = 1024;
const not_utf8_note = "panic message is not valid UTF-8";

/// The crash file's path, with a zero after it. `prepare` sets it.
var path_buf: [path_max_bytes:0]u8 = undefined;
/// Zero means no path is set, so the handler writes no record.
var path_len: usize = 0;
/// Set by the first panic. A panic that finds it set skips the save.
var handling: std.atomic.Value(bool) = .init(false);
/// Storage for the record, so the handler needs no stack space for it.
var record_buf: [record_buf_bytes]u8 = undefined;

/// Computes the crash file's path under `home`, in the same folder that
/// `trace_report.zig` writes `last-crash.jsonl` to. It allocates nothing, does
/// no file I/O, and creates no folder. A path that does not fit leaves no path
/// set, so the handler writes no record.
pub fn prepare(home: []const u8) void {
    path_len = 0;
    const path = std.mem.print(path_buf[0..path_max_bytes], "{s}/{s}/{s}/{s}", .{
        profile_paths.rootParent(home),
        profile_paths.rootName(),
        profile_paths.diagnostics_dir_name,
        profile_paths.last_crash_report_file_name,
    }) catch return;
    path_buf[path.len] = 0;
    path_len = path.len;
}

/// The root panic handler. The first panic saves its record, and every panic
/// then goes to `std.debug.defaultPanic`, which prints the message and aborts.
/// A panic that comes during the save, from any thread or from this handler,
/// skips the save.
pub fn handle(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (!handling.swap(true, .seq_cst)) saveRecord(msg);
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Writes the record to the prepared path and replaces the file. Every error is
/// ignored, because the panic must still reach `std.debug.defaultPanic`.
fn saveRecord(msg: []const u8) void {
    if (path_len == 0) return;
    const record = formatRecord(
        &record_buf,
        build_options.app_version,
        build_options.git_commit,
        io_mod.milliTimestamp(),
        msg,
    );
    if (record.len == 0) return;
    // The file is created private to the user, and a symbolic link at the last
    // path component is refused.
    const fd = std.c.open(&path_buf, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < record.len) {
        const n = std.c.write(fd, record[written..].ptr, record.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

/// Writes the record's two lines into `buf` and returns them. The first line is
/// the `fx_trace` header that `trace_report.zig` writes, and the second is a
/// `fatal_error` record whose error is `panic`. Returns an empty slice when
/// `buf` is too small, so a partial record is never saved.
pub fn formatRecord(buf: []u8, fx_version: []const u8, git_commit: []const u8, now_ms: i64, msg: []const u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writeLines(&writer, fx_version, git_commit, now_ms, msg) catch return buf[0..0];
    return writer.buffered();
}

fn writeLines(w: *std.Io.Writer, fx_version: []const u8, git_commit: []const u8, now_ms: i64, msg: []const u8) !void {
    // Like `trace_report.zig`, leave out a time that is unknown or outside the
    // years 1970 to 9999.
    var utc_buf: [40]u8 = undefined;
    const utc: ?[]const u8 = if (now_ms > 0 and now_ms <= local_time.max_timestamp_ms)
        try trace_report.formatUtc(&utc_buf, now_ms)
    else
        null;

    try w.writeAll("{\"type\":\"fx_trace\",\"format_version\":");
    try w.print("{d}", .{trace_report.format_version});
    try w.writeAll(",\"fx_version\":");
    try writeJsonStr(fx_version, w);
    try w.writeAll(",\"git_commit\":");
    try writeJsonStr(git_commit, w);
    if (utc) |text| {
        try w.writeAll(",\"written_at\":");
        try writeJsonStr(text, w);
        try w.print(",\"written_at_ms\":{d}", .{now_ms});
    }
    try w.writeAll(",\"notice\":");
    try writeJsonStr(trace_report.notice_text, w);
    try w.writeAll("}\n");

    try w.writeAll("{\"type\":\"fatal_error\",\"error\":\"panic\",\"message\":");
    try writeJsonStr(keptMessage(msg), w);
    if (utc) |text| {
        try w.writeAll(",\"at\":");
        try writeJsonStr(text, w);
        try w.print(",\"at_ms\":{d}", .{now_ms});
    }
    try w.writeAll("}\n");
}

/// The message cut to `max_message_bytes` at a UTF-8 boundary. When the kept
/// bytes are not valid UTF-8, the record holds a fixed note instead.
fn keptMessage(msg: []const u8) []const u8 {
    var end = @min(msg.len, max_message_bytes);
    // Step back past continuation bytes, so the cut does not split a character.
    while (end > 0 and end < msg.len and (msg[end] & 0xc0) == 0x80) : (end -= 1) {}
    const kept = msg[0..end];
    if (!std.unicode.utf8ValidateSlice(kept)) return not_utf8_note;
    return kept;
}

fn parseRecordLine(arena: std.mem.Allocator, line: []const u8) !std.json.ObjectMap {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    try std.testing.expect(value == .object);
    return value.object;
}

test "crash panic record is two JSON lines the reader takes" {
    var buf: [record_buf_bytes]u8 = undefined;
    const record = formatRecord(&buf, "0.0.17", "abc1234", 1_700_000_000_123, "boom");
    try std.testing.expect(record.len > 0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, record, "\n"), '\n');
    const header = try parseRecordLine(a, lines.next().?);
    try std.testing.expectEqualStrings("fx_trace", header.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), header.get("format_version").?.integer);
    try std.testing.expectEqualStrings("0.0.17", header.get("fx_version").?.string);
    try std.testing.expectEqualStrings("abc1234", header.get("git_commit").?.string);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.123Z", header.get("written_at").?.string);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_123), header.get("written_at_ms").?.integer);
    try std.testing.expectEqualStrings(trace_report.notice_text, header.get("notice").?.string);

    const fatal = try parseRecordLine(a, lines.next().?);
    try std.testing.expectEqualStrings("fatal_error", fatal.get("type").?.string);
    try std.testing.expectEqualStrings("panic", fatal.get("error").?.string);
    try std.testing.expectEqualStrings("boom", fatal.get("message").?.string);
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.123Z", fatal.get("at").?.string);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_123), fatal.get("at_ms").?.integer);
    try std.testing.expect(lines.next() == null);
}

test "crash panic record escapes a long message and cuts it to fit" {
    var message: [5000]u8 = @splat('x');
    const head = "say \"hi\"\nline";
    @memcpy(message[0..head.len], head);
    var buf: [4096]u8 = undefined;
    const record = formatRecord(&buf, "0.0.17", "abc1234", 1_700_000_000_123, &message);
    try std.testing.expect(record.len > 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, record, "\n"), '\n');
    _ = try parseRecordLine(arena.allocator(), lines.next().?);
    const fatal = try parseRecordLine(arena.allocator(), lines.next().?);
    const kept = fatal.get("message").?.string;
    try std.testing.expectEqual(@as(usize, max_message_bytes), kept.len);
    try std.testing.expect(std.mem.startsWith(u8, kept, head));
}

test "crash panic record fits a message made of control bytes" {
    // Each control byte escapes to six bytes, so the kept text grows to 3072.
    const controls: [max_message_bytes + 88]u8 = @splat(0x01);
    var buf: [4096]u8 = undefined;
    const record = formatRecord(&buf, "0.0.17", "abc1234", 1_700_000_000_123, &controls);
    try std.testing.expect(record.len > 0);
    try std.testing.expect(record.len <= buf.len);
}

test "crash panic prepare sets no path when the crash file path is too long" {
    defer path_len = 0;
    const long_home: [path_max_bytes]u8 = @splat('h');
    prepare(&long_home);
    try std.testing.expectEqual(@as(usize, 0), path_len);

    prepare("/tmp/fake-home");
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.fx/diagnostics/last-crash.jsonl",
        path_buf[0..path_len],
    );
}

test "crash panic writes the record to the prepared file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".fx/diagnostics");
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(home);
    defer path_len = 0;

    prepare(home);
    saveRecord("boom from the file test");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path_buf[0..path_len], std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, bytes, "\n"), '\n');
    _ = try parseRecordLine(arena.allocator(), lines.next().?);
    const fatal = try parseRecordLine(arena.allocator(), lines.next().?);
    try std.testing.expectEqualStrings("boom from the file test", fatal.get("message").?.string);
}
