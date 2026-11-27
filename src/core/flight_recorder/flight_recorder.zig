//! Front door for the flight recorder. Outside code imports only this file.

const std = @import("std");
const testing = std.testing;

pub const format = @import("format.zig");
pub const reader = @import("reader.zig");
const segment = @import("segment.zig");
const writer = @import("writer.zig");

pub const Result = reader.Result;
pub const read = reader.read;

pub const Options = struct {
    folder: std.Io.Dir,
    io: std.Io,
    instance: u64,
    segment_bytes: usize = writer.segment_bytes,
    max_session_bytes: u64 = writer.max_session_bytes,
    sync_interval_ms: u32 = writer.sync_interval_ms,
    fail_prealloc_for_test: bool = false,
    fault_once_for_test: ?writer.FaultSite = null,
    on_gap_written_for_test: ?writer.GapHook = null,
    test_ctx: ?*anyopaque = null,
};

/// Failures the recorder thread counted and recovered from. Each counts one failed step.
/// `prealloc_failures` counts each segment the recorder could not create or track.
pub const Stats = struct {
    sync_failures: u64,
    evict_failures: u64,
    seal_failures: u64,
    prealloc_failures: u64,
};

pub const Recorder = struct {
    inner: writer.Writer,

    pub fn start(gpa: std.mem.Allocator, options: Options) !*Recorder {
        const self = try gpa.create(Recorder);
        errdefer gpa.destroy(self);
        try self.inner.start(gpa, .{
            .folder = options.folder,
            .io = options.io,
            .instance = options.instance,
            .segment_bytes = options.segment_bytes,
            .max_session_bytes = options.max_session_bytes,
            .sync_interval_ms = options.sync_interval_ms,
            .fail_prealloc_from_index = if (options.fail_prealloc_for_test) 1 else null,
            .fault_once_for_test = options.fault_once_for_test,
            .on_gap_written_for_test = options.on_gap_written_for_test,
            .test_ctx = options.test_ctx,
        });
        return self;
    }

    pub fn emit(self: *Recorder, kind: u16, thread: u32, payload: []const u8) void {
        self.inner.emit(kind, thread, payload);
    }

    pub fn stats(self: *const Recorder) Stats {
        return .{
            .sync_failures = self.inner.sync_failures.load(.monotonic),
            .evict_failures = self.inner.evict_failures.load(.monotonic),
            .seal_failures = self.inner.seal_failures.load(.monotonic),
            .prealloc_failures = self.inner.prealloc_failures.load(.monotonic),
        };
    }

    pub fn stop(self: *Recorder) void {
        const gpa = self.inner.gpa;
        self.inner.stop();
        gpa.destroy(self);
    }
};

fn readFileBytes(gpa: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, name: []const u8) ![]u8 {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try gpa.alloc(u8, @intCast(stat.size));
    errdefer gpa.free(buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.readPositionalAll(io, buf[total..], total);
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

test "emit then stop reads frames in order and splits 3x max_payload_bytes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x1234,
        .segment_bytes = 512 * 1024,
    });

    rec.emit(1, 10, "alpha");
    rec.emit(2, 10, "beta");

    const big_len = 3 * format.max_payload_bytes;
    const big = try testing.allocator.alloc(u8, big_len);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);
    rec.emit(3, 10, big);

    rec.stop();

    var seg_names: std.ArrayList([]u8) = .empty;
    defer {
        for (seg_names.items) |name| testing.allocator.free(name);
        seg_names.deinit(testing.allocator);
    }
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".seg")) {
            try seg_names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
        }
    }
    try testing.expectEqual(@as(usize, 1), seg_names.items.len);

    const bytes = try readFileBytes(testing.allocator, tmp.dir, testing.io, seg_names.items[0]);
    defer testing.allocator.free(bytes);
    var res = try read(testing.allocator, bytes);
    defer res.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), res.frames.items.len);
    try testing.expectEqualStrings("alpha", res.frames.items[0].payload);
    try testing.expectEqualStrings("beta", res.frames.items[1].payload);
    try testing.expectEqual(@as(u16, format.flag_continues), res.frames.items[2].flags);
    try testing.expectEqual(@as(u16, format.flag_continues), res.frames.items[3].flags);
    try testing.expectEqual(@as(u16, 0), res.frames.items[4].flags);
    try testing.expectEqualSlices(u8, big[0..format.max_payload_bytes], res.frames.items[2].payload);
    try testing.expectEqualSlices(u8, big[format.max_payload_bytes .. 2 * format.max_payload_bytes], res.frames.items[3].payload);
    try testing.expectEqualSlices(u8, big[2 * format.max_payload_bytes .. 3 * format.max_payload_bytes], res.frames.items[4].payload);
}

test "two threads emit 10000 events each across small segments without loss" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x5678,
        .segment_bytes = 64 * 1024,
        .max_session_bytes = 64 * 1024 * 1024,
        .sync_interval_ms = 20,
    });
    // Wait until seg0 is active so startup buffer does not drop small-segment overflows.
    while (rec.inner.current.load(.acquire) == null) {
        try std.Thread.yield();
    }

    const Worker = struct {
        fn run(r: *Recorder, tid: u32) void {
            var buf: [16]u8 = undefined;
            for (0..10_000) |i| {
                std.mem.writeInt(u32, buf[0..4], tid, .little);
                std.mem.writeInt(u64, buf[4..12], @intCast(i), .little);
                std.mem.writeInt(u32, buf[12..16], 0, .little);
                r.emit(7, tid, &buf);
                if (i % 500 == 0) {
                    // A failed yield only skips a scheduling hint, so the producers do not depend on it.
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ rec, 1 });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ rec, 2 });
    t1.join();
    t2.join();
    rec.stop();

    var seen_1 = try testing.allocator.alloc(bool, 10_000);
    defer testing.allocator.free(seen_1);
    @memset(seen_1, false);
    var seen_2 = try testing.allocator.alloc(bool, 10_000);
    defer testing.allocator.free(seen_2);
    @memset(seen_2, false);

    var seg_indices: std.ArrayList(u64) = .empty;
    defer seg_indices.deinit(testing.allocator);

    var total_frames: u64 = 0;
    var total_dropped: u64 = 0;
    var total_overflowed: u64 = 0;
    var open_count: usize = 0;

    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".open")) {
            open_count += 1;
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".seg")) continue;
        const parsed = segment.parseSealedName(entry.name) orelse return error.InvalidSegmentName;
        try seg_indices.append(testing.allocator, parsed.index);

        const bytes = try readFileBytes(testing.allocator, tmp.dir, testing.io, entry.name);
        defer testing.allocator.free(bytes);
        var res = try read(testing.allocator, bytes);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 0), res.missing);
        total_dropped += res.dropped;
        total_overflowed += res.overflowed;

        for (res.frames.items) |frame| {
            total_frames += 1;
            const tid = std.mem.readInt(u32, frame.payload[0..4], .little);
            const idx = std.mem.readInt(u64, frame.payload[4..12], .little);
            if (tid == 1) {
                try testing.expect(!seen_1[idx]);
                seen_1[idx] = true;
            } else if (tid == 2) {
                try testing.expect(!seen_2[idx]);
                seen_2[idx] = true;
            } else {
                return error.UnexpectedThread;
            }
        }
    }

    std.mem.sort(u64, seg_indices.items, {}, std.sort.asc(u64));
    try testing.expect(seg_indices.items.len > 5);
    for (seg_indices.items, 0..) |seg_idx, expected_idx| {
        try testing.expectEqual(@as(u64, @intCast(expected_idx)), seg_idx);
    }
    try testing.expectEqual(@as(usize, 0), open_count);
    try testing.expect(total_overflowed > 0);
    try testing.expectEqual(@as(u64, 20_000), total_frames + total_dropped);
    if (total_dropped == 0) {
        try testing.expectEqual(@as(u64, 20_000), total_frames);
    }
}

test "no next segment ready counts dropped in mapped header without waiting" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x9ABC,
        .segment_bytes = 4096,
        .fail_prealloc_for_test = true,
    });
    while (rec.inner.current.load(.acquire) == null) {
        try std.Thread.yield();
    }

    for (0..200) |_| {
        rec.emit(1, 1, "payload-data-that-fills-a-small-segment");
    }
    rec.stop();

    var seg_count: usize = 0;
    var open_count: usize = 0;
    var total_dropped: u64 = 0;
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".open")) open_count += 1;
        if (!std.mem.endsWith(u8, entry.name, ".seg")) continue;
        seg_count += 1;
        const bytes = try readFileBytes(testing.allocator, tmp.dir, testing.io, entry.name);
        defer testing.allocator.free(bytes);
        var res = try read(testing.allocator, bytes);
        defer res.deinit(testing.allocator);
        total_dropped += res.dropped;
    }

    try testing.expectEqual(@as(usize, 1), seg_count);
    try testing.expectEqual(@as(usize, 0), open_count);
    try testing.expect(total_dropped > 0);
}

test "cap writes gap record before unlinking oldest sealed segment and never removes open" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const Probe = struct {
        dir: std.Io.Dir,
        io: std.Io,
        checked: bool = false,
        saw_seg_while_gap_present: bool = false,
        saw_open_present: bool = false,

        fn onGap(ctx: ?*anyopaque, gap_name: []const u8, seg_name: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.checked = true;
            _ = self.dir.statFile(self.io, gap_name, .{}) catch return;
            _ = self.dir.statFile(self.io, seg_name, .{}) catch return;
            self.saw_seg_while_gap_present = true;

            var it = self.dir.iterate();
            while (it.next(self.io) catch null) |entry| {
                if (std.mem.endsWith(u8, entry.name, ".open")) {
                    self.saw_open_present = true;
                    break;
                }
            }
        }
    };
    var probe: Probe = .{ .dir = tmp.dir, .io = testing.io };

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0xDEF0,
        .segment_bytes = 4096,
        .max_session_bytes = 8192,
        .sync_interval_ms = 10,
        .on_gap_written_for_test = Probe.onGap,
        .test_ctx = &probe,
    });
    while (rec.inner.current.load(.acquire) == null) {
        try std.Thread.yield();
    }

    for (0..400) |i| {
        rec.emit(1, 1, "0123456789abcdef0123456789abcdef");
        if (i % 50 == 0) {
            const ticks = rec.inner.tick_count.load(.acquire);
            rec.inner.wake();
            while (rec.inner.tick_count.load(.acquire) == ticks) {
                try std.Thread.yield();
            }
        }
    }
    rec.stop();

    try testing.expect(probe.checked);
    try testing.expect(probe.saw_seg_while_gap_present);
    try testing.expect(probe.saw_open_present);

    var gap_names: std.ArrayList([]u8) = .empty;
    defer {
        for (gap_names.items) |n| testing.allocator.free(n);
        gap_names.deinit(testing.allocator);
    }
    var seg_indices: std.ArrayList(u64) = .empty;
    defer seg_indices.deinit(testing.allocator);

    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "gap-") and std.mem.endsWith(u8, entry.name, ".json")) {
            try gap_names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
        } else if (std.mem.endsWith(u8, entry.name, ".seg")) {
            const parsed = segment.parseSealedName(entry.name) orelse return error.InvalidSegmentName;
            try seg_indices.append(testing.allocator, parsed.index);
        }
    }

    try testing.expect(gap_names.items.len > 0);
    try testing.expect(seg_indices.items.len >= 1);

    // Gap record for segment 0 exists, names it, and segment 0 itself was unlinked.
    const first_gap = try readFileBytes(testing.allocator, tmp.dir, testing.io, "gap-000000000000def0-00000000.json");
    defer testing.allocator.free(first_gap);
    try testing.expect(std.mem.find(u8, first_gap, "000000000000def0-00000000.seg") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "000000000000def0-00000000.seg", .{}));
}

test "segment with nonzero in-flight count is not sealed until count is zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const seg = try segment.Segment.create(testing.allocator, tmp.dir, testing.io, 0x1111, 0, 4096, 1000, false);
    _ = seg.in_flight.fetchAdd(1, .acq_rel);
    try testing.expect(!seg.canSeal());
    _ = seg.in_flight.fetchSub(1, .release);
    try testing.expect(seg.canSeal());
    try seg.seal(testing.allocator);
}

test "four producers stress tiny segments and fast sealing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0xCAFE,
        .segment_bytes = 8192,
        .max_session_bytes = 128 * 1024 * 1024,
        .sync_interval_ms = 1,
    });
    while (rec.inner.current.load(.acquire) == null) {
        try std.Thread.yield();
    }

    const thread_count = 4;
    const emits_per_thread = 50_000;

    const Worker = struct {
        fn run(r: *Recorder, tid: u32) void {
            var buf: [12]u8 = undefined;
            for (0..emits_per_thread) |i| {
                std.mem.writeInt(u32, buf[0..4], tid, .little);
                std.mem.writeInt(u64, buf[4..12], @intCast(i), .little);
                r.emit(9, tid, &buf);
            }
        }
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ rec, @as(u32, @intCast(idx)) });
    }
    for (&threads) |*t| t.join();
    rec.stop();

    var seen: [thread_count][]bool = undefined;
    for (&seen) |*s| {
        s.* = try testing.allocator.alloc(bool, emits_per_thread);
        @memset(s.*, false);
    }
    defer for (&seen) |s| testing.allocator.free(s);

    var total_frames: u64 = 0;
    var total_dropped: u64 = 0;
    var seg_count: usize = 0;
    var open_count: usize = 0;

    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".open")) {
            open_count += 1;
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".seg")) continue;
        seg_count += 1;

        const bytes = try readFileBytes(testing.allocator, tmp.dir, testing.io, entry.name);
        defer testing.allocator.free(bytes);
        var res = try read(testing.allocator, bytes);
        defer res.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 0), res.missing);
        total_dropped += res.dropped;

        for (res.frames.items) |frame| {
            total_frames += 1;
            const tid = std.mem.readInt(u32, frame.payload[0..4], .little);
            const idx = std.mem.readInt(u64, frame.payload[4..12], .little);
            try testing.expect(tid < thread_count);
            try testing.expect(!seen[tid][idx]);
            seen[tid][idx] = true;
        }
    }

    try testing.expectEqual(@as(usize, 0), open_count);
    try testing.expect(seg_count >= 10);
    try testing.expect(total_frames > 0);
    try testing.expectEqual(@as(u64, thread_count * emits_per_thread), total_frames + total_dropped);
}

const seal_test_events: u64 = 300;
const seal_test_tick_every: usize = 50;
const seal_test_max_extra_ticks: usize = 100;

fn waitForTicks(rec: *Recorder, ticks: u64) !void {
    while (rec.inner.tick_count.load(.acquire) < ticks) {
        try std.Thread.yield();
    }
}

fn tickAndWait(rec: *Recorder) !void {
    const before = rec.inner.tick_count.load(.acquire);
    rec.inner.wake();
    try waitForTicks(rec, before + 1);
}

const SegmentTotals = struct {
    frames: u64,
    dropped: u64,
    open_files: u64,
};

fn totalSegments(dir: std.Io.Dir) !SegmentTotals {
    var totals: SegmentTotals = .{ .frames = 0, .dropped = 0, .open_files = 0 };
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".open")) totals.open_files += 1;
        if (!std.mem.endsWith(u8, entry.name, ".seg")) continue;
        const bytes = try readFileBytes(testing.allocator, dir, testing.io, entry.name);
        defer testing.allocator.free(bytes);
        var res = try read(testing.allocator, bytes);
        defer res.deinit(testing.allocator);
        totals.frames += res.frames.items.len;
        totals.dropped += res.dropped;
    }
    return totals;
}

test "a failed sync is counted once and later emits still land" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x5101,
        .segment_bytes = 64 * 1024,
        .fault_once_for_test = .sync,
    });
    try waitForTicks(rec, 1);
    rec.emit(1, 1, "after-failed-sync");
    rec.emit(1, 1, "after-failed-sync");
    const stats = rec.stats();
    rec.stop();

    try testing.expectEqual(@as(u64, 1), stats.sync_failures);
    try testing.expectEqual(@as(u64, 0), stats.evict_failures);
    try testing.expectEqual(@as(u64, 0), stats.seal_failures);
    const totals = try totalSegments(tmp.dir);
    try testing.expectEqual(@as(u64, 2), totals.frames);
    try testing.expectEqual(@as(u64, 0), totals.open_files);
}

test "a failed eviction is counted once and later emits still land" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x5102,
        .segment_bytes = 64 * 1024,
        .fault_once_for_test = .evict,
    });
    try waitForTicks(rec, 1);
    rec.emit(1, 1, "after-failed-evict");
    rec.emit(1, 1, "after-failed-evict");
    const stats = rec.stats();
    rec.stop();

    try testing.expectEqual(@as(u64, 1), stats.evict_failures);
    try testing.expectEqual(@as(u64, 0), stats.sync_failures);
    try testing.expectEqual(@as(u64, 0), stats.seal_failures);
    const totals = try totalSegments(tmp.dir);
    try testing.expectEqual(@as(u64, 2), totals.frames);
    try testing.expectEqual(@as(u64, 0), totals.open_files);
}

test "a failed seal is counted once, the segment seals later, and no event is lost" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x5103,
        .segment_bytes = 4096,
        .max_session_bytes = 64 * 1024 * 1024,
        .fault_once_for_test = .seal,
    });
    try waitForTicks(rec, 1);
    for (0..seal_test_events) |i| {
        rec.emit(1, 1, "0123456789abcdef0123456789abcdef");
        if (i % seal_test_tick_every == 0) try tickAndWait(rec);
    }
    var extra_ticks: usize = 0;
    while (rec.stats().seal_failures == 0 and extra_ticks < seal_test_max_extra_ticks) : (extra_ticks += 1) {
        try tickAndWait(rec);
    }
    const stats = rec.stats();
    rec.stop();

    try testing.expectEqual(@as(u64, 1), stats.seal_failures);
    try testing.expectEqual(@as(u64, 0), stats.sync_failures);
    try testing.expectEqual(@as(u64, 0), stats.evict_failures);
    const totals = try totalSegments(tmp.dir);
    try testing.expectEqual(seal_test_events, totals.frames + totals.dropped);
    try testing.expectEqual(@as(u64, 0), totals.open_files);
}

const prealloc_test_events: u64 = 200;

test "a failed preallocation is counted and the events it cannot hold are counted as dropped" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x5104,
        .segment_bytes = 4096,
        .fail_prealloc_for_test = true,
    });
    try waitForTicks(rec, 1);
    for (0..prealloc_test_events) |_| {
        rec.emit(1, 1, "0123456789abcdef0123456789abcdef");
    }
    const stats = rec.stats();
    rec.stop();

    try testing.expect(stats.prealloc_failures >= 1);
    try testing.expectEqual(@as(u64, 0), stats.sync_failures);
    try testing.expectEqual(@as(u64, 0), stats.seal_failures);
    const totals = try totalSegments(tmp.dir);
    try testing.expect(totals.frames > 0);
    try testing.expect(totals.dropped > 0);
    try testing.expectEqual(prealloc_test_events, totals.frames + totals.dropped);
}

test "a failed seal at stop is counted, and its events stay readable in the open file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const rec = try Recorder.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x5105,
        .segment_bytes = 64 * 1024,
        .fault_once_for_test = .seal,
    });
    try waitForTicks(rec, 1);
    rec.emit(1, 1, "stop-time-seal");
    rec.emit(1, 1, "stop-time-seal");

    // Stop the writer directly so the stats are read after the stop-time seal and before the recorder is freed.
    rec.inner.stop();
    const stats = rec.stats();
    testing.allocator.destroy(rec);

    try testing.expectEqual(@as(u64, 1), stats.seal_failures);
    try testing.expectEqual(@as(u64, 0), stats.sync_failures);
    const totals = try totalSegments(tmp.dir);
    try testing.expectEqual(@as(u64, 1), totals.open_files);

    const bytes = try readFileBytes(testing.allocator, tmp.dir, testing.io, "0000000000005105-00000000.open");
    defer testing.allocator.free(bytes);
    var res = try read(testing.allocator, bytes);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), res.frames.items.len);
}

test {
    _ = @import("format.zig");
    _ = @import("reader.zig");
    _ = @import("segment.zig");
    _ = @import("writer.zig");
}
