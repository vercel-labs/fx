//! Lock-free producer reservation/commit and single recorder thread for
//! preallocation, periodic sync, segment sealing, startup buffering, and
//! size-cap eviction (`tests/tla/flight_recorder/FlightRecorder.tla`).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const format = @import("format.zig");
const reader = @import("reader.zig");
const segment = @import("segment.zig");

comptime {
    std.debug.assert(builtin.target.cpu.arch.endian() == .little);
}

pub const segment_bytes: usize = format.segment_bytes;
pub const max_session_bytes: u64 = 1024 * 1024 * 1024;
pub const sync_interval_ms: u32 = 1000;
pub const startup_buffer_bytes: usize = 256 * 1024;

pub const GapHook = *const fn (ctx: ?*anyopaque, gap_name: []const u8, seg_name: []const u8) void;

/// Recorder-thread steps that a test can make fail once.
pub const FaultSite = enum { sync, evict, seal };

pub const Options = struct {
    folder: std.Io.Dir,
    io: std.Io,
    instance: u64,
    segment_bytes: usize = segment_bytes,
    max_session_bytes: u64 = max_session_bytes,
    sync_interval_ms: u32 = sync_interval_ms,
    fail_prealloc_from_index: ?u64 = null,
    fault_once_for_test: ?FaultSite = null,
    on_gap_written_for_test: ?GapHook = null,
    test_ctx: ?*anyopaque = null,
};

const WakeState = enum(u32) {
    idle = 0,
    pending = 1,
    waiting = 2,
};

const SealedEntry = struct {
    name: []u8,
    instance: u64,
    index: u64,
    bytes: u64,
    mtime_ns: i96,
};

const GapRecord = struct {
    segment: []const u8,
    instance: u64,
    index: u64,
    events: u64,
    frames: u64,
    bytes: u64,
};

pub const Writer = struct {
    gpa: std.mem.Allocator,
    folder: std.Io.Dir,
    io: std.Io,
    instance: u64,
    segment_bytes: usize,
    max_session_bytes: u64,
    sync_interval_ms: u32,
    fail_prealloc_from_index: ?u64,
    fault_once_for_test: ?FaultSite,
    on_gap_written_for_test: ?GapHook,
    test_ctx: ?*anyopaque,

    current: std.atomic.Value(?*segment.Segment),
    next: std.atomic.Value(?*segment.Segment),
    next_seq: std.atomic.Value(u64),
    next_index: u64,

    // Two-epoch quiescent counter protecting `current` loads until `in_flight` is incremented.
    pin_epoch: std.atomic.Value(u8),
    pin_counts: [2]std.atomic.Value(u32),

    stopping: std.atomic.Value(bool),
    wake_state: std.atomic.Value(u32),
    tick_count: std.atomic.Value(u64),
    thread: ?std.Thread,
    open_segments: std.ArrayList(*segment.Segment),

    startup_mutex: std.Io.Mutex,
    startup_buf: ?[]u8,
    startup_len: usize,
    startup_count: u32,
    startup_dropped: u64,

    // Failures the recorder thread counts and recovers from, so recording goes on. Read through `Recorder.stats`.
    sync_failures: std.atomic.Value(u64),
    evict_failures: std.atomic.Value(u64),
    seal_failures: std.atomic.Value(u64),
    prealloc_failures: std.atomic.Value(u64),

    pub fn start(self: *Writer, gpa: std.mem.Allocator, options: Options) !void {
        if (options.segment_bytes <= format.segment_header_bytes) return error.CapacityTooSmall;

        const startup_buf = try gpa.alloc(u8, startup_buffer_bytes);
        errdefer gpa.free(startup_buf);

        self.* = .{
            .gpa = gpa,
            .folder = options.folder,
            .io = options.io,
            .instance = options.instance,
            .segment_bytes = options.segment_bytes,
            .max_session_bytes = options.max_session_bytes,
            .sync_interval_ms = options.sync_interval_ms,
            .fail_prealloc_from_index = options.fail_prealloc_from_index,
            .fault_once_for_test = options.fault_once_for_test,
            .on_gap_written_for_test = options.on_gap_written_for_test,
            .test_ctx = options.test_ctx,
            .current = .init(null),
            .next = .init(null),
            .next_seq = .init(1),
            .next_index = 0,
            .pin_epoch = .init(0),
            .pin_counts = .{ .init(0), .init(0) },
            .stopping = .init(false),
            .wake_state = .init(@backingInt(WakeState.idle)),
            .tick_count = .init(0),
            .thread = null,
            .open_segments = .empty,
            .startup_mutex = .init,
            .startup_buf = startup_buf,
            .startup_len = 0,
            .startup_count = 0,
            .startup_dropped = 0,
            .sync_failures = .init(0),
            .evict_failures = .init(0),
            .seal_failures = .init(0),
            .prealloc_failures = .init(0),
        };

        self.thread = try std.Thread.spawn(.{}, recorderMain, .{self});
    }

    pub fn emit(self: *Writer, kind: u16, thread: u32, payload: []const u8) void {
        const mono_ns = nowMonoNs(self.io);
        const wall_ms = nowWallMs(self.io);
        var splitter = format.splitPayload(payload.len);
        while (splitter.next()) |piece| {
            self.emitFrame(kind, piece.flags, thread, payload[piece.start..piece.end], mono_ns, wall_ms);
        }
    }

    pub fn stop(self: *Writer) void {
        self.stopping.store(true, .release);
        self.wake();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.finalizeOnStop();
    }

    fn emitFrame(
        self: *Writer,
        kind: u16,
        flags: u16,
        thread: u32,
        payload: []const u8,
        mono_ns: u64,
        wall_ms: u64,
    ) void {
        const needed = format.frameBytes(payload.len);
        if (needed > self.segment_bytes - format.segment_header_bytes) {
            if (self.acquireSegment()) |seg| {
                defer _ = seg.in_flight.fetchSub(1, .release);
                _ = seg.droppedPtr().fetchAdd(1, .monotonic);
            } else {
                self.emitStartup(kind, flags, thread, payload, mono_ns, wall_ms);
            }
            return;
        }

        while (true) {
            const seg = self.acquireSegment() orelse {
                self.emitStartup(kind, flags, thread, payload, mono_ns, wall_ms);
                return;
            };

            const prev_word = seg.cursorPtr().fetchAdd(@as(u64, needed) + format.cursor_count_one, .acq_rel);
            const prev = format.unpackCursor(prev_word);
            if (prev.offset + needed > seg.capacity) {
                // Model: ReserveOffset overflow -> SwitchSegment -> retry or drop.
                _ = seg.overflowedPtr().fetchAdd(1, .monotonic);
                const maybe_next = self.next.load(.acquire);
                if (maybe_next == null or maybe_next.? == seg) {
                    _ = seg.droppedPtr().fetchAdd(1, .monotonic);
                    _ = seg.in_flight.fetchSub(1, .release);
                    return;
                }
                const next_seg = maybe_next.?;
                if (self.current.cmpxchgStrong(seg, next_seg, .seq_cst, .acquire) == null) {
                    _ = self.next.cmpxchgStrong(next_seg, null, .release, .monotonic);
                    self.wake();
                }
                _ = seg.in_flight.fetchSub(1, .release);
                continue;
            }

            // Model: WriteHeader -> Copy -> Commit.
            const offset: usize = @intCast(prev.offset);
            const seq = self.next_seq.fetchAdd(1, .monotonic);
            const header = format.encodeFrameHeader(.{
                .payload_len = @intCast(payload.len),
                .kind = kind,
                .flags = flags,
                .thread = thread,
                .reservation_index = prev.count,
                .seq = seq,
                .mono_ns = mono_ns,
                .wall_ms = wall_ms,
            });
            @memcpy(seg.memory[offset..][0..format.frame_header_bytes], &header);

            const payload_start = offset + format.frame_header_bytes;
            const payload_end = payload_start + payload.len;
            @memcpy(seg.memory[payload_start..payload_end], payload);

            const padded_end = payload_start + format.align8(payload.len);
            @memset(seg.memory[payload_end..padded_end], 0);

            const trailer_ptr: *u64 = @ptrCast(@alignCast(seg.memory.ptr + padded_end));
            @atomicStore(u64, trailer_ptr, format.encodeTrailer(payload), .release);

            _ = seg.in_flight.fetchSub(1, .release);
            return;
        }
    }

    // Store-buffering pattern with `cmpxchgStrong` + `drainPinEpoch`: `pin_counts` fetchAdd
    // and `current` load use `.seq_cst` so a reclaimed segment is never unmapped while still
    // reachable (`flight_recorder.zig` "four producers stress tiny segments and fast sealing").
    fn acquireSegment(self: *Writer) ?*segment.Segment {
        const epoch: u1 = @truncate(self.pin_epoch.load(.acquire) & 1);
        _ = self.pin_counts[epoch].fetchAdd(1, .seq_cst);
        const maybe_seg = self.current.load(.seq_cst);
        if (maybe_seg) |seg| {
            _ = seg.in_flight.fetchAdd(1, .acq_rel);
        }
        _ = self.pin_counts[epoch].fetchSub(1, .release);
        return maybe_seg;
    }

    fn emitStartup(
        self: *Writer,
        kind: u16,
        flags: u16,
        thread: u32,
        payload: []const u8,
        mono_ns: u64,
        wall_ms: u64,
    ) void {
        self.startup_mutex.lockUncancelable(self.io);
        if (self.current.load(.acquire) != null) {
            self.startup_mutex.unlock(self.io);
            self.emitFrame(kind, flags, thread, payload, mono_ns, wall_ms);
            return;
        }
        defer self.startup_mutex.unlock(self.io);

        const buf = self.startup_buf orelse {
            self.startup_dropped += 1;
            return;
        };
        const max_usable = @min(buf.len, self.segment_bytes - format.segment_header_bytes);
        const needed = format.frameBytes(payload.len);
        if (self.startup_len + needed > max_usable) {
            self.startup_dropped += 1;
            return;
        }

        const seq = self.next_seq.fetchAdd(1, .monotonic);
        const written = format.encodeFrame(buf[self.startup_len..], .{
            .payload_len = @intCast(payload.len),
            .kind = kind,
            .flags = flags,
            .thread = thread,
            .reservation_index = self.startup_count,
            .seq = seq,
            .mono_ns = mono_ns,
            .wall_ms = wall_ms,
        }, payload) catch {
            self.startup_dropped += 1;
            return;
        };
        self.startup_len += written;
        self.startup_count += 1;
    }

    pub fn wake(self: *Writer) void {
        const prev = self.wake_state.swap(@backingInt(WakeState.pending), .acq_rel);
        if (prev == @backingInt(WakeState.waiting)) {
            self.io.futexWake(u32, &self.wake_state.raw, 1);
        }
    }

    fn waitForWakeOrTick(self: *Writer) void {
        if (self.stopping.load(.acquire)) return;
        if (self.wake_state.cmpxchgStrong(
            @backingInt(WakeState.idle),
            @backingInt(WakeState.waiting),
            .acq_rel,
            .acquire,
        ) != null) {
            self.wake_state.store(@backingInt(WakeState.idle), .release);
            return;
        }

        const timeout: std.Io.Timeout = .{
            .duration = .{
                .raw = .fromMilliseconds(self.sync_interval_ms),
                .clock = .awake,
            },
        };
        const deadline = timeout.toDeadline(self.io);
        while (true) {
            if (self.stopping.load(.acquire)) {
                self.wake_state.store(@backingInt(WakeState.idle), .release);
                return;
            }
            self.io.futexWaitTimeout(u32, &self.wake_state.raw, @backingInt(WakeState.waiting), deadline) catch |err| switch (err) {
                error.Canceled => {
                    _ = self.wake_state.cmpxchgStrong(
                        @backingInt(WakeState.waiting),
                        @backingInt(WakeState.idle),
                        .acq_rel,
                        .acquire,
                    );
                    return;
                },
            };
            if (self.wake_state.load(.acquire) != @backingInt(WakeState.waiting)) {
                self.wake_state.store(@backingInt(WakeState.idle), .release);
                return;
            }
            switch (deadline) {
                .deadline => |d| if (d.untilNow(self.io).raw.nanoseconds >= 0) {
                    _ = self.wake_state.cmpxchgStrong(
                        @backingInt(WakeState.waiting),
                        @backingInt(WakeState.idle),
                        .acq_rel,
                        .acquire,
                    );
                    return;
                },
                else => {},
            }
        }
    }

    fn recorderMain(self: *Writer) void {
        while (!self.stopping.load(.acquire)) {
            self.tickOnce();
            self.waitForWakeOrTick();
        }
    }

    fn tickOnce(self: *Writer) void {
        if (self.current.load(.acquire) == null) {
            self.initFirstSegment();
        }
        if (self.current.load(.acquire) != null and self.next.load(.acquire) == null and !self.stopping.load(.acquire)) {
            self.prepareNextSegment();
        }
        self.sealReadySegments();
        // A failed sync or eviction is counted and retried on a later tick, so recording goes on.
        if (self.current.load(.acquire)) |cur| {
            self.syncCurrent(cur) catch {
                _ = self.sync_failures.fetchAdd(1, .monotonic);
            };
        }
        self.evictIfNeeded() catch {
            _ = self.evict_failures.fetchAdd(1, .monotonic);
        };
        _ = self.tick_count.fetchAdd(1, .release);
    }

    fn syncCurrent(self: *Writer, cur: *segment.Segment) !void {
        const cursor = format.unpackCursor(cur.cursorPtr().load(.acquire));
        const written = @min(@as(usize, @intCast(cursor.offset)), cur.capacity);
        if (self.takeTestFault(.sync)) return error.InjectedFault;
        try cur.sync(written);
    }

    fn sealOne(self: *Writer, seg: *segment.Segment) !void {
        if (self.takeTestFault(.seal)) return error.InjectedFault;
        try seg.seal(self.gpa);
    }

    /// Only the recorder thread calls this after `start`, so the fault needs no atomics.
    fn takeTestFault(self: *Writer, site: FaultSite) bool {
        if (self.fault_once_for_test != site) return false;
        self.fault_once_for_test = null;
        return true;
    }

    fn shouldFailPrealloc(self: *const Writer, index: u64) bool {
        const threshold = self.fail_prealloc_from_index orelse return false;
        return index >= threshold;
    }

    /// Every null return counts as a prealloc failure, so the cause of later drops is visible.
    fn createNextSegment(self: *Writer) ?*segment.Segment {
        const index = self.next_index;
        const seg = segment.Segment.create(
            self.gpa,
            self.folder,
            self.io,
            self.instance,
            index,
            self.segment_bytes,
            nowWallMs(self.io),
            self.shouldFailPrealloc(index),
        ) catch {
            _ = self.prealloc_failures.fetchAdd(1, .monotonic);
            return null;
        };
        self.open_segments.append(self.gpa, seg) catch {
            seg.discardUnsealed(self.gpa);
            _ = self.prealloc_failures.fetchAdd(1, .monotonic);
            return null;
        };
        self.next_index += 1;
        return seg;
    }

    fn initFirstSegment(self: *Writer) void {
        const seg0 = self.createNextSegment() orelse return;
        var stale_buf: ?[]u8 = null;

        self.startup_mutex.lockUncancelable(self.io);
        if (self.startup_buf) |buf| {
            if (self.startup_len > 0) {
                @memcpy(seg0.memory[format.segment_header_bytes..][0..self.startup_len], buf[0..self.startup_len]);
                seg0.cursorPtr().store(format.packCursor(.{
                    .offset = format.segment_header_bytes + self.startup_len,
                    .count = self.startup_count,
                }), .release);
            }
            if (self.startup_dropped > 0) {
                seg0.droppedPtr().store(self.startup_dropped, .release);
            }
            stale_buf = buf;
            self.startup_buf = null;
        }
        self.current.store(seg0, .release);
        self.startup_mutex.unlock(self.io);

        if (stale_buf) |buf| self.gpa.free(buf);
    }

    fn prepareNextSegment(self: *Writer) void {
        const seg = self.createNextSegment() orelse return;
        self.next.store(seg, .release);
    }

    fn drainPinEpoch(self: *Writer) bool {
        const prev: u1 = @truncate(self.pin_epoch.load(.acquire) & 1);
        if (self.pin_counts[prev ^ 1].load(.seq_cst) != 0) return false;
        self.pin_epoch.store(prev ^ 1, .seq_cst);
        return self.pin_counts[prev].load(.seq_cst) == 0;
    }

    fn sealReadySegments(self: *Writer) void {
        const cur = self.current.load(.acquire);
        const nxt = self.next.load(.acquire);
        if (!self.drainPinEpoch()) return;

        var idx: usize = 0;
        while (idx < self.open_segments.items.len) {
            const seg = self.open_segments.items[idx];
            if (seg == cur or seg == nxt or !seg.canSeal()) {
                idx += 1;
                continue;
            }
            self.sealOne(seg) catch {
                _ = self.seal_failures.fetchAdd(1, .monotonic);
                idx += 1;
                continue;
            };
            _ = self.open_segments.orderedRemove(idx);
        }
    }

    fn finalizeOnStop(self: *Writer) void {
        if (self.current.load(.acquire) == null) {
            self.initFirstSegment();
        }
        if (self.startup_buf) |buf| {
            self.gpa.free(buf);
            self.startup_buf = null;
        }

        const next_seg = self.next.swap(null, .acq_rel);
        self.current.store(null, .seq_cst);

        while (!self.drainPinEpoch()) {
            std.atomic.spinLoopHint();
        }

        for (self.open_segments.items) |seg| {
            if (next_seg != null and seg == next_seg.?) {
                seg.discardUnsealed(self.gpa);
                continue;
            }
            while (!seg.canSeal()) {
                std.atomic.spinLoopHint();
            }
            // A failed seal keeps the .open file, which readers treat as unfinished, and its frames stay readable.
            self.sealOne(seg) catch {
                _ = self.seal_failures.fetchAdd(1, .monotonic);
                seg.closeAndUnmap(self.gpa);
            };
        }
        self.open_segments.deinit(self.gpa);
    }

    fn evictIfNeeded(self: *Writer) !void {
        if (self.takeTestFault(.evict)) return error.InjectedFault;
        var total_bytes: u64 = 0;
        var sealed: std.ArrayList(SealedEntry) = .empty;
        defer {
            for (sealed.items) |entry| self.gpa.free(entry.name);
            sealed.deinit(self.gpa);
        }

        var iter_dir = try self.folder.openDir(self.io, ".", .{ .iterate = true });
        defer iter_dir.close(self.io);
        var it = iter_dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const is_seg = std.mem.endsWith(u8, entry.name, ".seg");
            const is_open = std.mem.endsWith(u8, entry.name, ".open");
            const is_gap = std.mem.startsWith(u8, entry.name, "gap-") and std.mem.endsWith(u8, entry.name, ".json");
            if (!is_seg and !is_open and !is_gap) continue;

            const stat = self.folder.statFile(self.io, entry.name, .{}) catch continue;
            total_bytes += stat.size;
            if (!is_seg) continue;

            const parsed = segment.parseSealedName(entry.name) orelse continue;
            try sealed.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, entry.name),
                .instance = parsed.instance,
                .index = parsed.index,
                .bytes = stat.size,
                .mtime_ns = stat.mtime.nanoseconds,
            });
        }

        if (total_bytes <= self.max_session_bytes or sealed.items.len == 0) return;

        std.mem.sort(SealedEntry, sealed.items, {}, sealedOlderThan);

        for (sealed.items) |entry| {
            if (total_bytes <= self.max_session_bytes) break;
            const gap_bytes = try self.writeGapRecord(entry);
            try segment.unlink(self.folder, self.io, entry.name);
            total_bytes -|= entry.bytes;
            total_bytes +|= gap_bytes;
        }
    }

    fn sealedOlderThan(_: void, a: SealedEntry, b: SealedEntry) bool {
        if (a.instance == b.instance) return a.index < b.index;
        if (a.mtime_ns != b.mtime_ns) return a.mtime_ns < b.mtime_ns;
        if (a.index != b.index) return a.index < b.index;
        return a.instance < b.instance;
    }

    fn writeGapRecord(self: *Writer, entry: SealedEntry) !u64 {
        const counts = self.countSegmentEventsAndFrames(entry.name);

        var gap_buf: [segment.name_buf_bytes]u8 = undefined;
        const gap_name = segment.gapFileName(&gap_buf, entry.instance, entry.index);

        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try std.json.Stringify.value(GapRecord{
            .segment = entry.name,
            .instance = entry.instance,
            .index = entry.index,
            .events = counts.events,
            .frames = counts.frames,
            .bytes = entry.bytes,
        }, .{}, &out.writer);

        const payload = out.written();
        var file = try self.folder.createFile(self.io, gap_name, .{
            .read = false,
            .truncate = true,
            .exclusive = false,
            .permissions = .fromMode(0o600),
        });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, payload);
        try file.sync(self.io);

        if (self.on_gap_written_for_test) |hook| {
            hook(self.test_ctx, gap_name, entry.name);
        }
        return payload.len;
    }

    fn countSegmentEventsAndFrames(self: *Writer, name: []const u8) struct { events: u64, frames: u64 } {
        var file = self.folder.openFile(self.io, name, .{}) catch return .{ .events = 0, .frames = 0 };
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return .{ .events = 0, .frames = 0 };
        const size = std.math.cast(usize, stat.size) orelse return .{ .events = 0, .frames = 0 };
        const buf = self.gpa.alloc(u8, size) catch return .{ .events = 0, .frames = 0 };
        defer self.gpa.free(buf);
        var total: usize = 0;
        while (total < buf.len) {
            const n = file.readPositionalAll(self.io, buf[total..], total) catch return .{ .events = 0, .frames = 0 };
            if (n == 0) break;
            total += n;
        }
        var res = reader.read(self.gpa, buf[0..total]) catch return .{ .events = 0, .frames = 0 };
        defer res.deinit(self.gpa);
        var events: u64 = 0;
        for (res.frames.items) |frame| {
            if ((frame.flags & format.flag_continues) == 0) events += 1;
        }
        return .{ .events = events, .frames = res.frames.items.len };
    }
};

fn nowMonoNs(io: std.Io) u64 {
    return std.math.cast(u64, std.Io.Clock.boot.now(io).toNanoseconds()) orelse 0;
}

fn nowWallMs(io: std.Io) u64 {
    return std.math.cast(u64, std.Io.Clock.real.now(io).toMilliseconds()) orelse 0;
}

test "a switched-away segment stays unsealed while in_flight is nonzero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var w: Writer = undefined;
    try w.start(testing.allocator, .{
        .folder = tmp.dir,
        .io = testing.io,
        .instance = 0x2222,
        .segment_bytes = 4096,
        .sync_interval_ms = 5000,
    });
    // Wait until segment 0 is ready so we can hold an in-flight count on it.
    while (w.current.load(.acquire) == null) {
        try std.Thread.yield();
    }
    const seg0 = w.current.load(.acquire).?;
    _ = seg0.in_flight.fetchAdd(1, .acq_rel);

    // Ensure `next` is preallocated before filling seg0 so the switch succeeds.
    while (w.next.load(.acquire) == null) {
        try std.Thread.yield();
    }

    // Fill seg0 past capacity via normal emits until it switches to seg1.
    while (w.current.load(.acquire) == seg0) {
        w.emit(1, 1, "fill-to-switch-segment");
    }
    const ticks_after_switch = w.tick_count.load(.acquire);
    w.wake();
    while (w.tick_count.load(.acquire) == ticks_after_switch) {
        try std.Thread.yield();
    }
    _ = try tmp.dir.statFile(testing.io, "0000000000002222-00000000.open", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "0000000000002222-00000000.seg", .{}));

    _ = seg0.in_flight.fetchSub(1, .release);
    w.stop();
    _ = try tmp.dir.statFile(testing.io, "0000000000002222-00000000.seg", .{});
}
