//! Saves each auto-mode safety review request and the reviewer's answer on this machine when FX_DEBUG_REVIEW_RECORD=1, so real reviews can be replayed. fx never reads or uploads these files. They hold the exact request, which can include the action's full text and the tool results the reviewer saw.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const testing = std.testing;

/// One review send and its outcome, as `append` saves it.
pub const Send = struct {
    /// The tool call whose action this review judged.
    target_call_id: []const u8,
    /// Which send this is for the review, starting at 1.
    attempt: u8,
    /// "first" for the review itself, "confirm" for the fresh second review that checks a caution.
    review: []const u8,
    /// The reviewer model the request was sent to.
    model: []const u8,
    /// The exact request body fx sent.
    payload: []const u8,
    /// The send's outcome name, such as `answered` or `timed_out`.
    result: []const u8,
    /// The reviewer's decision arguments when it answered, empty otherwise.
    answer: []const u8,
    /// Milliseconds from the send to its outcome.
    elapsed_ms: u32,
};

/// The JSON object one saved line holds. Its fields are written in this order.
const Line = struct {
    v: u8,
    at_ms: i64,
    target_call_id: []const u8,
    attempt: u8,
    review: []const u8,
    model: []const u8,
    result: []const u8,
    elapsed_ms: u32,
    answer: []const u8,
    payload: []const u8,
};

const format_version: u8 = 1;

var write_mutex: std.Io.Mutex = .init;

/// Whether `FX_DEBUG_REVIEW_RECORD` turns recording on. Only the exact value `1` does.
pub fn enabled() bool {
    return isOn(io_mod.getenv("FX_DEBUG_REVIEW_RECORD"));
}

fn isOn(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.mem.eql(u8, text, "1");
}

/// Saves `send` as one line of today's UTC record file in the profile's review
/// records folder. Does nothing unless recording is on. Never fails: a record
/// that cannot be saved is dropped, and a trace line names what was dropped and why.
pub fn append(send: Send) void {
    if (!enabled()) return;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const zio = io_mod.getIo();

    const home = homeFolder() orelse {
        logDropped(send, "home folder", "NoHomeFolder");
        return;
    };
    const dir_path = profile_paths.reviewRecordsDir(alloc, home) catch |err| {
        logDropped(send, "folder path", @errorName(err));
        return;
    };
    ensureReviewRecordsDir(zio, dir_path) catch |err| {
        logDropped(send, "create folder", @errorName(err));
        return;
    };
    var dir = std.Io.Dir.openDirAbsolute(zio, dir_path, .{}) catch |err| {
        logDropped(send, "open folder", @errorName(err));
        return;
    };
    defer dir.close(zio);
    const at_ms = io_mod.milliTimestamp();
    const file_name = fileNameFor(alloc, at_ms, currentProcessId()) catch |err| {
        logDropped(send, "file name", @errorName(err));
        return;
    };
    appendIn(zio, dir, file_name, send, at_ms) catch |err| {
        logDropped(send, "write", @errorName(err));
    };
}

fn logDropped(send: Send, step: []const u8, err_name: []const u8) void {
    debug_trace.logf(
        "review_record",
        "review record dropped call={s} attempt={d} step={s} err={s}",
        .{ send.target_call_id, send.attempt, step, err_name },
    );
}

/// The profile's home folder with surrounding whitespace removed, or null when there is none.
fn homeFolder() ?[]const u8 {
    const value = io_mod.homeDir() orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

/// Creates the review records folder when it is missing, private to the user.
/// Its parent folders are created as usual.
fn ensureReviewRecordsDir(io: std.Io, path: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try io_mod.makeDirRecursive(parent);
    std.Io.Dir.createDirAbsolute(io, path, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// The record file for `at_ms`'s UTC day and process `pid`: `YYYY-MM-DD-<pid>.jsonl`.
/// The caller frees the result.
fn fileNameFor(alloc: std.mem.Allocator, at_ms: i64, pid: i64) ![]u8 {
    const secs: u64 = @intCast(@max(@divFloor(at_ms, 1000), 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return alloc.print("{d:0>4}-{d:0>2}-{d:0>2}-{d}.jsonl", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
        pid,
    });
}

fn currentProcessId() i64 {
    if (comptime host_target.is_wasm or builtin.target.os.tag == .windows) return 0;
    return std.c.getpid();
}

/// Appends `send` to `file_name` in `dir` as one JSON line, creating the file
/// with owner-only permissions. Appends in this process are serialized. The
/// line buffer lives in an arena that this function frees before it returns.
fn appendIn(io: std.Io, dir: std.Io.Dir, file_name: []const u8, send: Send, at_ms: i64) !void {
    write_mutex.lockUncancelable(io);
    defer write_mutex.unlock(io);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var line: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.json.Stringify.value(Line{
        .v = format_version,
        .at_ms = at_ms,
        .target_call_id = send.target_call_id,
        .attempt = send.attempt,
        .review = send.review,
        .model = send.model,
        .result = send.result,
        .elapsed_ms = send.elapsed_ms,
        .answer = send.answer,
        .payload = send.payload,
    }, .{}, &line.writer);
    try line.writer.writeByte('\n');

    var file = try dir.createFile(io, file_name, .{
        .truncate = false,
        .permissions = .fromMode(0o600),
    });
    defer file.close(io);
    try file.writePositionalAll(io, line.writer.buffered(), try file.length(io));
}

const sample_send: Send = .{
    .target_call_id = "call_1",
    .attempt = 1,
    .review = "first",
    .model = "openai/gpt-5.6-luna",
    .payload = "{}",
    .result = "answered",
    .answer = "{}",
    .elapsed_ms = 7,
};

test "a recorded review line holds every field and the exact request" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "a \"quoted\" word, a back\\slash, a newline\nand \u{e9}t\u{e9}";
    const send: Send = .{
        .target_call_id = "call_7",
        .attempt = 2,
        .review = "confirm",
        .model = "openai/gpt-5.6-luna",
        .payload = payload,
        .result = "answered",
        .answer = "{\"decision\":\"clear\"}",
        .elapsed_ms = 1234,
    };
    try appendIn(io, tmp.dir, "records.jsonl", send, 1_700_000_000_123);

    const bytes = try tmp.dir.readFileAlloc(io, "records.jsonl", alloc, .limited(64 * 1024));
    defer alloc.free(bytes);
    try testing.expect(bytes.len > 1 and bytes[bytes.len - 1] == '\n');
    const line = bytes[0 .. bytes.len - 1];
    try testing.expect(std.mem.findScalar(u8, line, '\n') == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqual(@as(usize, 10), object.count());
    try testing.expectEqual(@as(i64, format_version), object.get("v").?.integer);
    try testing.expectEqual(@as(i64, 1_700_000_000_123), object.get("at_ms").?.integer);
    try testing.expectEqualStrings("call_7", object.get("target_call_id").?.string);
    try testing.expectEqual(@as(i64, 2), object.get("attempt").?.integer);
    try testing.expectEqualStrings("confirm", object.get("review").?.string);
    try testing.expectEqualStrings("openai/gpt-5.6-luna", object.get("model").?.string);
    try testing.expectEqualStrings("answered", object.get("result").?.string);
    try testing.expectEqual(@as(i64, 1234), object.get("elapsed_ms").?.integer);
    try testing.expectEqualStrings("{\"decision\":\"clear\"}", object.get("answer").?.string);
    try testing.expectEqualStrings(payload, object.get("payload").?.string);
}

test "review records are private to the user" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(base);
    const records_dir = try std.Io.Dir.path.join(alloc, &.{ base, "review-records" });
    defer alloc.free(records_dir);

    try ensureReviewRecordsDir(io, records_dir);
    try ensureReviewRecordsDir(io, records_dir);
    const folder = try std.Io.Dir.cwd().statFile(io, records_dir, .{});
    try testing.expect(folder.kind == .directory);
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), folder.permissions.toMode() & 0o777);

    var dir = try std.Io.Dir.openDirAbsolute(io, records_dir, .{});
    defer dir.close(io);
    try appendIn(io, dir, "2024-02-29-1.jsonl", sample_send, 1);
    const file = try dir.statFile(io, "2024-02-29-1.jsonl", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), file.permissions.toMode() & 0o777);
}

test "two appends make two lines" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var second = sample_send;
    second.target_call_id = "call_2";
    second.review = "confirm";
    second.result = "timed_out";
    second.answer = "";
    try appendIn(io, tmp.dir, "two.jsonl", sample_send, 1);
    try appendIn(io, tmp.dir, "two.jsonl", second, 2);

    const bytes = try tmp.dir.readFileAlloc(io, "two.jsonl", alloc, .limited(64 * 1024));
    defer alloc.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first_line = lines.next().?;
    const second_line = lines.next().?;
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expect(lines.next() == null);

    var first = try std.json.parseFromSlice(std.json.Value, alloc, first_line, .{});
    defer first.deinit();
    try testing.expectEqualStrings("call_1", first.value.object.get("target_call_id").?.string);
    try testing.expectEqualStrings("first", first.value.object.get("review").?.string);
    var later = try std.json.parseFromSlice(std.json.Value, alloc, second_line, .{});
    defer later.deinit();
    try testing.expectEqualStrings("call_2", later.value.object.get("target_call_id").?.string);
    try testing.expectEqualStrings("confirm", later.value.object.get("review").?.string);
    try testing.expectEqualStrings("timed_out", later.value.object.get("result").?.string);
}

test "recording is off unless FX_DEBUG_REVIEW_RECORD is 1" {
    try testing.expect(!isOn(null));
    try testing.expect(!isOn("0"));
    try testing.expect(!isOn("true"));
    try testing.expect(!isOn(" 1"));
    try testing.expect(isOn("1"));
}

test "review record file names carry the UTC day and the process id" {
    const alloc = testing.allocator;

    const leap_day = try fileNameFor(alloc, 1_709_164_800_000, 42);
    defer alloc.free(leap_day);
    try testing.expectEqualStrings("2024-02-29-42.jsonl", leap_day);

    const last_ms_of_epoch = try fileNameFor(alloc, 86_399_999, 42);
    defer alloc.free(last_ms_of_epoch);
    try testing.expectEqualStrings("1970-01-01-42.jsonl", last_ms_of_epoch);
}
