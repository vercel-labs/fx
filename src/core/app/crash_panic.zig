//! Saves a crash record when fx panics, so `/trace` can show it as `last_crash`.
//!
//! When a panic starts, the handler writes two JSON lines to
//! `~/.fx/diagnostics/last-crash.jsonl.<pid>.tmp`, syncs it to disk, and renames
//! it over `last-crash.jsonl`, so a failed write keeps the last saved record. The lines
//! are the `fx_trace` header and a
//! `fatal_error` record whose error is `panic`. `trace_report.zig` reads that
//! file. The handler then calls `std.debug.defaultPanic`, so stderr and the
//! abort stay as they were.
//!
//! The handler can run on any thread and in any state, so it does not allocate
//! or take a lock. `prepare` computes the paths at startup. The handler creates
//! the fx folder and the `diagnostics` folder when they are missing, both private
//! to the user. A call that fails is ignored.
//! The renderer event ring is not saved, because reading it needs a blocking
//! lock that the handler does not take. Segfaults do not reach this handler:
//! `std.debug` prints them and aborts on its own.

const std = @import("std");
const build_options = @import("build_options");
const io_mod = @import("../shared/io.zig");
const local_time = @import("../shared/local_time.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const text_utils = @import("../shared/text_utils.zig");
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

/// The fx folder's path (`~/.fx` by default), with a zero after it. `prepare` sets it.
var fx_dir_buf: [path_max_bytes:0]u8 = undefined;
/// The diagnostics folder's path, with a zero after it. `prepare` sets it.
var dir_buf: [path_max_bytes:0]u8 = undefined;
/// The crash file's path, with a zero after it. `prepare` sets it.
var path_buf: [path_max_bytes:0]u8 = undefined;
/// The temporary file's path, with a zero after it. The handler writes the
/// record there, then renames it over the crash file. The name ends in the
/// process ID, so two fx processes that panic at once never share it.
/// `prepare` sets it.
var tmp_path_buf: [path_max_bytes:0]u8 = undefined;
/// Zero means no path is set, so the handler writes no record.
var path_len: usize = 0;
/// Set by the first panic. A panic that finds it set skips the save.
var handling: std.atomic.Value(bool) = .init(false);
/// Storage for the record, so the handler needs no stack space for it.
var record_buf: [record_buf_bytes]u8 = undefined;

/// Computes the fx folder, the diagnostics folder, the crash file's path, and the
/// temporary file's path under `home`, in the folder that `trace_report.zig` reads
/// `last-crash.jsonl` from. It allocates nothing, does no file I/O, and creates
/// no folder. A path that does not fit leaves no path set, so the handler writes
/// no record.
pub fn prepare(home: []const u8) void {
    path_len = 0;
    const fx_len = printPath(&fx_dir_buf, "{s}/{s}", .{
        profile_paths.rootParent(home),
        profile_paths.rootName(),
    }) orelse return;
    const dir_len = printPath(&dir_buf, "{s}/{s}", .{
        fx_dir_buf[0..fx_len],
        profile_paths.diagnostics_dir_name,
    }) orelse return;
    const dir = dir_buf[0..dir_len];
    const file_len = printPath(&path_buf, "{s}/{s}", .{ dir, profile_paths.last_crash_report_file_name }) orelse return;
    _ = printPath(&tmp_path_buf, "{s}/{s}.{d}.tmp", .{
        dir,
        profile_paths.last_crash_report_file_name,
        std.c.getpid(),
    }) orelse return;
    path_len = file_len;
}

/// Prints a path into `buf` with a zero after it, and returns its length. Null
/// when the path and its zero do not fit, so a path is never cut short.
fn printPath(buf: *[path_max_bytes:0]u8, comptime fmt: []const u8, args: anytype) ?usize {
    const text = std.mem.print(buf[0 .. path_max_bytes - 1], fmt, args) catch return null;
    buf[text.len] = 0;
    return text.len;
}

/// The root panic handler. The first panic saves its record, and every panic
/// then goes to `std.debug.defaultPanic`, which prints the message and aborts.
/// A panic that comes during the save, from any thread or from this handler,
/// skips the save.
pub fn handle(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (!handling.swap(true, .seq_cst)) saveRecord(msg);
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Writes the record to the temporary file, then renames it over the crash file.
/// Creates the fx folder and the diagnostics folder when they are missing. Every
/// error is ignored, because the panic must still reach `std.debug.defaultPanic`.
fn saveRecord(msg: []const u8) void {
    if (path_len == 0) return;
    // Creates the fx folder, then the diagnostics folder, both private to the user,
    // when they are missing. The results are not checked: "already exists" is
    // expected, and any other failure shows up in the open below.
    _ = std.c.mkdir(&fx_dir_buf, 0o700);
    _ = std.c.mkdir(&dir_buf, 0o700);
    const record = formatRecord(
        &record_buf,
        build_options.app_version,
        build_options.git_commit,
        io_mod.milliTimestamp(),
        msg,
    );
    if (record.len == 0) return;
    // The record goes to the temporary file first. The rename replaces the crash
    // file in one step, and only after every byte is written, so a failed write
    // leaves the last saved record in place. Any file already at the temporary path
    // is removed first, so a planted FIFO or an old file of any mode is never reused.
    // The unlink result is not checked: when nothing is there, it fails, as expected.
    // The open must then create a new file, private to the user. A symbolic link, or
    // anything else still in the way, makes the open fail, and the save is skipped
    // without blocking.
    _ = std.c.unlink(&tmp_path_buf);
    const fd = std.c.open(&tmp_path_buf, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0o600));
    if (fd < 0) return;
    const written = writeAll(fd, record);
    // The record reaches the disk before the rename makes it the crash file. The
    // result is ignored, as with the other calls here. A failed sync still renames,
    // so the newest record replaces the old one, but it may not survive a power loss.
    if (written) _ = std.c.fsync(fd);
    _ = std.c.close(fd);
    if (written and std.c.rename(&tmp_path_buf, &path_buf) == 0) return;
    _ = std.c.unlink(&tmp_path_buf);
}

/// Writes all of `bytes` to `fd`. Returns false when a write fails.
fn writeAll(fd: c_int, bytes: []const u8) bool {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (n <= 0) return false;
        written += @intCast(n);
    }
    return true;
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
    if (utc) |text| try writeTime(w, "written_at", text, now_ms);
    try w.writeAll(",\"notice\":");
    try writeJsonStr(trace_report.notice_text, w);
    try w.writeAll("}\n");

    try w.writeAll("{\"type\":\"fatal_error\",\"error\":\"panic\",\"message\":");
    try writeJsonStr(keptMessage(msg), w);
    if (utc) |text| try writeTime(w, "at", text, now_ms);
    try w.writeAll("}\n");
}

/// Writes the `"<name>":<utc>,"<name>_ms":<now_ms>` pair that the record uses for
/// each time. `utc` is the UTC text of `now_ms`.
fn writeTime(w: *std.Io.Writer, name: []const u8, utc: []const u8, now_ms: i64) !void {
    try w.print(",\"{s}\":", .{name});
    try writeJsonStr(utc, w);
    try w.print(",\"{s}_ms\":{d}", .{ name, now_ms });
}

/// The message cut to `max_message_bytes` at a UTF-8 boundary, which
/// `text_utils.utf8PrefixByBytes` does without allocating. When the kept bytes
/// are not valid UTF-8, the record holds a fixed note instead.
fn keptMessage(msg: []const u8) []const u8 {
    const kept = text_utils.utf8PrefixByBytes(msg, max_message_bytes);
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

/// The message of the `fatal_error` line in `record`.
fn fatalMessage(arena: std.mem.Allocator, record: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, record, "\n"), '\n');
    _ = lines.next();
    const fatal = try parseRecordLine(arena, lines.next().?);
    return fatal.get("message").?.string;
}

test "crash panic cut at 512 bytes drops a character that the cut splits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The two bytes of the character sit at 511 and 512, so the cut at 512 splits it.
    var msg: [514]u8 = @splat('x');
    msg[511] = 0xc3;
    msg[512] = 0xa9;
    msg[513] = 't';
    var buf: [record_buf_bytes]u8 = undefined;
    const record = formatRecord(&buf, "0.0.17", "abc1234", 1_700_000_000_123, &msg);
    try std.testing.expectEqualSlices(u8, msg[0..511], try fatalMessage(arena.allocator(), record));
}

test "crash panic keeps a message of exactly 512 bytes, and a character that ends at the cut" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [record_buf_bytes]u8 = undefined;

    const ascii: [512]u8 = @splat('x');
    const kept_ascii = try fatalMessage(arena.allocator(), formatRecord(&buf, "0.0.17", "abc1234", 1_700_000_000_123, &ascii));
    try std.testing.expectEqualSlices(u8, &ascii, kept_ascii);

    // The two bytes of the character end at 512, so the whole character is kept.
    var ending: [512]u8 = @splat('x');
    ending[510] = 0xc3;
    ending[511] = 0xa9;
    const kept_ending = try fatalMessage(arena.allocator(), formatRecord(&buf, "0.0.17", "abc1234", 1_700_000_000_123, &ending));
    try std.testing.expectEqualSlices(u8, &ending, kept_ending);
}

test "crash panic keeps a note instead of a message that is not UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [record_buf_bytes]u8 = undefined;
    const record = formatRecord(&buf, "0.0.17", "abc1234", 1_700_000_000_123, "bad \xff byte");
    try std.testing.expectEqualStrings(not_utf8_note, try fatalMessage(arena.allocator(), record));
}

test "crash panic writes the record when only the fx folder exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".fx");
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(home);
    defer path_len = 0;

    prepare(home);
    saveRecord("no folder yet");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path_buf[0..path_len], std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "no folder yet") != null);
}

test "crash panic renames the temporary file over the crash file and leaves none" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".fx/diagnostics");
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(home);
    defer path_len = 0;

    prepare(home);
    saveRecord("renamed into place");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path_buf[0..path_len], std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "renamed into place") != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, std.mem.sliceTo(&tmp_path_buf, 0), .{}));
}

test "crash panic keeps the last record when the temporary file cannot be written" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".fx/diagnostics");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".fx/diagnostics/last-crash.jsonl", .data = "last saved record\n" });
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(home);
    defer path_len = 0;

    prepare(home);
    // A folder at the temporary file's path makes the open of that path fail.
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.mem.sliceTo(&tmp_path_buf, 0));
    saveRecord("not saved");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path_buf[0..path_len], std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("last saved record\n", bytes);
}

test "crash panic saves the record when a FIFO sits at the temporary path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".fx/diagnostics");
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(home);
    defer path_len = 0;

    prepare(home);
    // A FIFO with no reader. Opening it for writing would block the handler forever.
    const fifo_c = struct {
        extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
    };
    try std.testing.expectEqual(@as(c_int, 0), fifo_c.mkfifo(&tmp_path_buf, 0o600));
    saveRecord("saved past a fifo");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path_buf[0..path_len], std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "saved past a fifo") != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, std.mem.sliceTo(&tmp_path_buf, 0), .{}));
}

test "crash panic saves a private file over a leftover file of another mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".fx/diagnostics");
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(home);
    defer path_len = 0;

    prepare(home);
    // A file that fx did not create, at the temporary path.
    const leftover = try std.testing.allocator.print(".fx/diagnostics/last-crash.jsonl.{d}.tmp", .{std.c.getpid()});
    defer std.testing.allocator.free(leftover);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = leftover, .data = "stale\n" });
    // chmod ignores the umask, so the leftover file is 0644 even under a strict umask.
    if (std.c.chmod(&tmp_path_buf, 0o644) != 0) return error.TestChmodFailed;
    const before = try std.Io.Dir.cwd().statFile(std.testing.io, std.mem.sliceTo(&tmp_path_buf, 0), .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), before.permissions.toMode() & 0o777);

    saveRecord("saved over a leftover file");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path_buf[0..path_len], std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "saved over a leftover file") != null);
    const saved = try std.Io.Dir.cwd().statFile(std.testing.io, path_buf[0..path_len], .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), saved.permissions.toMode() & 0o777);
}

test "crash panic creates the fx folder and the diagnostics folder when both are missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(home);
    defer path_len = 0;

    prepare(home);
    saveRecord("no fx folder at all");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path_buf[0..path_len], std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "no fx folder at all") != null);
    for ([_][]const u8{ std.mem.sliceTo(&fx_dir_buf, 0), std.mem.sliceTo(&dir_buf, 0) }) |folder| {
        const st = try std.Io.Dir.cwd().statFile(std.testing.io, folder, .{});
        try std.testing.expect(st.kind == .directory);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), st.permissions.toMode() & 0o777);
    }
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
    const expected_tmp = try std.testing.allocator.print("/tmp/fake-home/.fx/diagnostics/last-crash.jsonl.{d}.tmp", .{std.c.getpid()});
    defer std.testing.allocator.free(expected_tmp);
    try std.testing.expectEqualStrings(expected_tmp, std.mem.sliceTo(&tmp_path_buf, 0));
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
