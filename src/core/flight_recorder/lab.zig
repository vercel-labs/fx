//! Test-only executable for driving the flight recorder across SIGKILL and
//! full-disk tests (`tests/tla/drivers/flight_recorder/`). Not part of `fx`.

const std = @import("std");
const testing = std.testing;
const fr = @import("flight_recorder.zig");
const lab_script = @import("lab_script.zig");

pub const default_payload_bytes: usize = 4 + 8 + 48;
pub const min_payload_bytes: usize = 4 + 8;
const default_sync_ms: u32 = 1000;
pub const default_max_session_bytes: u64 = 1024 * 1024 * 1024;
pub const max_gap_file_bytes: usize = 1024 * 1024;
// Tells a test driver that the recorder runs and its progress file is mapped.
const ready_line = "{\"ready\":true}\n";

const EmitConfig = struct {
    dir_path: []const u8,
    thread_count: u32,
    events_per_thread: u64,
    segment_bytes: usize = fr.format.segment_bytes,
    sync_ms: u32 = default_sync_ms,
    max_session_bytes: u64 = default_max_session_bytes,
    progress_path: ?[]const u8 = null,
    payload_bytes: usize = default_payload_bytes,
    delay_us: u64 = 0,
    instance: ?u64 = null,
};

const ThreadSummary = struct {
    thread: u32,
    count: u64,
    highest: ?u64,
    ranges: []const [2]u64,
};

const ReadSummary = struct {
    threads: []const ThreadSummary,
    frames: u64,
    torn: u64,
    holes: u64,
    missing: u64,
    overflowed: u64,
    dropped: u64,
    gap_events: u64,
    newer: u64,
};

const EmitSummary = struct {
    emitted: u64,
    startup_buffered: u64,
    startup_dropped: u64,
    segments: u64,
};

const GapJson = struct {
    events: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try writeUsageError(io, "expected subcommand: emit, read, or script\n");
        std.process.exit(2);
    }

    const sub = args[1];
    if (std.mem.eql(u8, sub, "emit")) {
        const cfg = parseEmitArgs(args[2..]) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.mem.print(&buf, "invalid emit arguments: {t}\n", .{err}) catch "invalid emit arguments\n";
            try writeUsageError(io, msg);
            std.process.exit(2);
        };
        try runEmit(gpa, io, cfg);
    } else if (std.mem.eql(u8, sub, "read")) {
        if (args.len != 3) {
            try writeUsageError(io, "usage: read <dir>\n");
            std.process.exit(2);
        }
        try runRead(gpa, io, args[2]);
    } else if (std.mem.eql(u8, sub, "script")) {
        if (args.len != 3) {
            try writeUsageError(io, "usage: script <dir>\n");
            std.process.exit(2);
        }
        try lab_script.run(gpa, io, args[2]);
    } else {
        try writeUsageError(io, "unknown subcommand (expected emit, read, or script)\n");
        std.process.exit(2);
    }
}

fn writeUsageError(io: std.Io, msg: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, msg);
}

fn parseEmitArgs(args: []const []const u8) !EmitConfig {
    if (args.len < 3) return error.MissingPositionalArgs;
    const dir_path = args[0];
    const thread_count = try std.fmt.parseInt(u32, args[1], 10);
    if (thread_count == 0) return error.ZeroThreads;
    const events_per_thread = try std.fmt.parseInt(u64, args[2], 10);

    var cfg: EmitConfig = .{
        .dir_path = dir_path,
        .thread_count = thread_count,
        .events_per_thread = events_per_thread,
    };

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (i + 1 >= args.len) return error.MissingFlagValue;
        const val = args[i + 1];
        i += 1;

        if (std.mem.eql(u8, flag, "--segment-bytes")) {
            cfg.segment_bytes = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, flag, "--sync-ms")) {
            cfg.sync_ms = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, flag, "--max-session-bytes")) {
            cfg.max_session_bytes = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, flag, "--progress")) {
            cfg.progress_path = val;
        } else if (std.mem.eql(u8, flag, "--payload-bytes")) {
            cfg.payload_bytes = try std.fmt.parseInt(usize, val, 10);
            if (cfg.payload_bytes < min_payload_bytes or cfg.payload_bytes > fr.format.max_payload_bytes) {
                return error.InvalidPayloadBytes;
            }
        } else if (std.mem.eql(u8, flag, "--delay-us")) {
            cfg.delay_us = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, flag, "--instance")) {
            cfg.instance = try std.fmt.parseInt(u64, val, 10);
        } else {
            return error.UnknownFlag;
        }
    }
    return cfg;
}

pub const ProgressMap = struct {
    file: std.Io.File,
    memory: []align(std.heap.page_size_min) u8,

    pub fn open(io: std.Io, path: []const u8, thread_count: u32) !ProgressMap {
        const byte_len = @as(usize, thread_count) * @sizeOf(u64);
        var file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = true,
            .exclusive = false,
            .permissions = .fromMode(0o600),
        });
        errdefer file.close(io);
        try file.setLength(io, byte_len);

        const memory = try std.posix.mmap(
            null,
            byte_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(memory);

        @memset(memory[0..byte_len], 0xff);
        try file.sync(io);
        return .{ .file = file, .memory = memory };
    }

    pub fn slotFor(self: *ProgressMap, tid: u32) *u64 {
        const ptr: [*]align(8) u64 = @ptrCast(@alignCast(self.memory.ptr));
        return &ptr[tid];
    }

    pub fn close(self: *ProgressMap, io: std.Io) void {
        std.posix.munmap(self.memory);
        self.file.close(io);
    }
};

pub fn openPrivateDir(io: std.Io, dir_path: []const u8) !std.Io.Dir {
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    errdefer dir.close(io);
    const st = try dir.stat(io);
    if (st.permissions.toMode() & 0o777 != 0o700) {
        try dir.setPermissions(io, .fromMode(0o700));
    }
    return dir;
}

fn randomInstance(io: std.Io) u64 {
    var buf: [8]u8 = undefined;
    io.random(&buf);
    const val = std.mem.readInt(u64, &buf, .little);
    return if (val == 0) 1 else val;
}

const WorkerCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    rec: *fr.Recorder,
    tid: u32,
    events_per_thread: u64,
    payload_bytes: usize,
    delay_us: u64,
    progress_slot: ?*u64,
};

fn workerMain(ctx: WorkerCtx) void {
    const buf = ctx.gpa.alloc(u8, ctx.payload_bytes) catch @panic("oom in lab worker");
    defer ctx.gpa.free(buf);
    @memset(buf[min_payload_bytes..], 0xA5);

    var i: u64 = 0;
    while (i < ctx.events_per_thread) : (i += 1) {
        std.mem.writeInt(u32, buf[0..4], ctx.tid, .little);
        std.mem.writeInt(u64, buf[4..12], i, .little);
        ctx.rec.emit(1, ctx.tid, buf);
        if (ctx.progress_slot) |slot| {
            @atomicStore(u64, slot, i, .release);
        }
        if (ctx.delay_us > 0) {
            // Pacing only: --delay-us spaces out the emits, and a cancelled sleep just emits sooner.
            ctx.io.sleep(.fromNanoseconds(@as(i96, ctx.delay_us) * 1000), .awake) catch {};
        }
    }
}

fn runEmit(gpa: std.mem.Allocator, io: std.Io, cfg: EmitConfig) !void {
    var dir = try openPrivateDir(io, cfg.dir_path);
    defer dir.close(io);

    var progress: ?ProgressMap = if (cfg.progress_path) |p|
        try ProgressMap.open(io, p, cfg.thread_count)
    else
        null;
    defer if (progress) |*pm| pm.close(io);

    const instance = cfg.instance orelse randomInstance(io);
    const rec = try fr.Recorder.start(gpa, .{
        .folder = dir,
        .io = io,
        .instance = instance,
        .segment_bytes = cfg.segment_bytes,
        .max_session_bytes = cfg.max_session_bytes,
        .sync_interval_ms = cfg.sync_ms,
    });

    // Wait for the recorder thread's first tick so segment 0 is active before
    // producers advance progress (when disk is full, tick_count still reaches 1).
    while (rec.inner.tick_count.load(.acquire) == 0) {
        try std.Thread.yield();
    }
    try writeReadyLine(io);

    const threads = try gpa.alloc(std.Thread, cfg.thread_count);
    defer gpa.free(threads);

    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |t| t.join();

    while (spawned < cfg.thread_count) : (spawned += 1) {
        const tid: u32 = @intCast(spawned);
        threads[spawned] = try std.Thread.spawn(.{}, workerMain, .{WorkerCtx{
            .gpa = gpa,
            .io = io,
            .rec = rec,
            .tid = tid,
            .events_per_thread = cfg.events_per_thread,
            .payload_bytes = cfg.payload_bytes,
            .delay_us = cfg.delay_us,
            .progress_slot = if (progress) |*pm| pm.slotFor(tid) else null,
        }});
    }
    for (threads) |t| t.join();

    const had_segment_before_stop = rec.inner.current.load(.acquire) != null;
    const pre_stop_startup_buffered: u64 = if (had_segment_before_stop) 0 else rec.inner.startup_count;
    const pre_stop_startup_dropped: u64 = if (had_segment_before_stop) 0 else rec.inner.startup_dropped;

    rec.stop();

    const seg_count = try countSegmentFiles(io, dir);
    const summary: EmitSummary = .{
        .emitted = @as(u64, cfg.thread_count) * cfg.events_per_thread,
        .startup_buffered = if (seg_count == 0) pre_stop_startup_buffered else 0,
        .startup_dropped = if (seg_count == 0) pre_stop_startup_dropped else 0,
        .segments = seg_count,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(summary, .{}, &out.writer);
    try out.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
}

pub fn writeReadyLine(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, ready_line);
}

fn countSegmentFiles(io: std.Io, dir: std.Io.Dir) !u64 {
    var count: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (std.mem.endsWith(u8, entry.name, ".seg") or std.mem.endsWith(u8, entry.name, ".open")) {
            count += 1;
        }
    }
    return count;
}

pub fn readFileBytes(gpa: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, name: []const u8, max_bytes: ?usize) ![]u8 {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const limit = max_bytes orelse std.math.maxInt(usize);
    if (stat.size > limit) return error.FileTooLarge;
    const size: usize = @intCast(stat.size);
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.readPositionalAll(io, buf[total..], total);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

fn runRead(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var per_thread: std.AutoHashMapUnmanaged(u32, std.ArrayList(u64)) = .empty;
    defer {
        var val_it = per_thread.valueIterator();
        while (val_it.next()) |list| list.deinit(gpa);
        per_thread.deinit(gpa);
    }

    var total_frames: u64 = 0;
    var total_torn: u64 = 0;
    var total_holes: u64 = 0;
    var total_missing: u64 = 0;
    var total_overflowed: u64 = 0;
    var total_dropped: u64 = 0;
    var total_gap_events: u64 = 0;
    var total_newer: u64 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .unknown) continue;
        const is_seg = std.mem.endsWith(u8, entry.name, ".seg");
        const is_open = std.mem.endsWith(u8, entry.name, ".open");
        if (is_seg or is_open) {
            const bytes = try readFileBytes(gpa, dir, io, entry.name, null);
            defer gpa.free(bytes);

            var res = fr.read(gpa, bytes) catch |err| {
                // An `.open` file left by SIGKILL before header initialization has no events.
                if (is_open and (err == error.TooShort or err == error.BadMagic)) continue;
                return err;
            };
            defer res.deinit(gpa);

            if (res.version_status == .newer) {
                total_newer += 1;
                continue;
            }

            total_frames += res.frames.items.len;
            total_torn += res.torn.items.len;
            total_holes += res.holes.items.len;
            total_missing += res.missing;
            total_overflowed += res.overflowed;
            total_dropped += res.dropped;

            for (res.frames.items) |frame| {
                if (frame.payload.len < min_payload_bytes) continue;
                const tid = std.mem.readInt(u32, frame.payload[0..4], .little);
                const local_idx = std.mem.readInt(u64, frame.payload[4..12], .little);
                const gop = try per_thread.getOrPut(gpa, tid);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, local_idx);
            }
        } else if (std.mem.startsWith(u8, entry.name, "gap-") and std.mem.endsWith(u8, entry.name, ".json")) {
            const bytes = try readFileBytes(gpa, dir, io, entry.name, max_gap_file_bytes);
            defer gpa.free(bytes);
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const gap = try std.json.parseFromSliceLeaky(GapJson, scratch.allocator(), bytes, .{ .ignore_unknown_fields = true });
            total_gap_events += gap.events;
        }
    }

    var summaries: std.ArrayList(ThreadSummary) = .empty;
    defer {
        for (summaries.items) |s| gpa.free(s.ranges);
        summaries.deinit(gpa);
    }

    var key_it = per_thread.iterator();
    while (key_it.next()) |kv| {
        try summaries.append(gpa, try summarizeThread(gpa, kv.key_ptr.*, kv.value_ptr.items));
    }

    std.mem.sort(ThreadSummary, summaries.items, {}, struct {
        fn lessThan(_: void, a: ThreadSummary, b: ThreadSummary) bool {
            return a.thread < b.thread;
        }
    }.lessThan);

    const report: ReadSummary = .{
        .threads = summaries.items,
        .frames = total_frames,
        .torn = total_torn,
        .holes = total_holes,
        .missing = total_missing,
        .overflowed = total_overflowed,
        .dropped = total_dropped,
        .gap_events = total_gap_events,
        .newer = total_newer,
    };

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(report, .{}, &out.writer);
    try out.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
}

fn summarizeThread(gpa: std.mem.Allocator, tid: u32, raw_indexes: []u64) !ThreadSummary {
    if (raw_indexes.len == 0) {
        return .{ .thread = tid, .count = 0, .highest = null, .ranges = try gpa.alloc([2]u64, 0) };
    }
    std.mem.sort(u64, raw_indexes, {}, std.sort.asc(u64));

    var ranges: std.ArrayList([2]u64) = .empty;
    errdefer ranges.deinit(gpa);

    var unique_count: u64 = 1;
    var range_start: u64 = raw_indexes[0];
    var range_end: u64 = raw_indexes[0];

    for (raw_indexes[1..]) |idx| {
        if (idx == range_end) continue;
        unique_count += 1;
        if (idx == range_end + 1) {
            range_end = idx;
        } else {
            try ranges.append(gpa, .{ range_start, range_end });
            range_start = idx;
            range_end = idx;
        }
    }
    try ranges.append(gpa, .{ range_start, range_end });

    return .{
        .thread = tid,
        .count = unique_count,
        .highest = range_end,
        .ranges = try ranges.toOwnedSlice(gpa),
    };
}

test "summarizeThread collapses contiguous runs and counts unique indexes" {
    var input = [_]u64{ 5, 0, 2, 1, 2, 6, 8 };
    const summary = try summarizeThread(testing.allocator, 3, &input);
    defer testing.allocator.free(summary.ranges);

    try testing.expectEqual(@as(u32, 3), summary.thread);
    try testing.expectEqual(@as(u64, 6), summary.count);
    try testing.expectEqual(@as(?u64, 8), summary.highest);
    try testing.expectEqualSlices([2]u64, &.{ .{ 0, 2 }, .{ 5, 6 }, .{ 8, 8 } }, summary.ranges);
}

test "lab emit and read round trip preserves all indexes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try fr.Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x42,
        .segment_bytes = 8192,
        .sync_interval_ms = 20,
    });
    while (rec.inner.tick_count.load(.acquire) == 0) {
        try std.Thread.yield();
    }
    var payload: [default_payload_bytes]u8 = @splat(0xA5);
    for (0..5) |i| {
        std.mem.writeInt(u32, payload[0..4], 0, .little);
        std.mem.writeInt(u64, payload[4..12], @intCast(i), .little);
        rec.emit(1, 0, &payload);
    }
    rec.stop();

    var it = tmp.dir.iterate();
    var seg_count: usize = 0;
    while (try it.next(testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".seg")) seg_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), seg_count);
}

test {
    _ = lab_script;
}
