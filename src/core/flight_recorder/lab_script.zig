//! Scripted JSONL mode for `flight-recorder-lab` (`tests/tla/drivers/flight_recorder/trace.test.ts`).
//! Reads JSONL actions from stdin and prints one JSONL observation per action to stdout.

const std = @import("std");
const testing = std.testing;
const fr = @import("flight_recorder.zig");
const lab = @import("lab.zig");

const script_default_segment_bytes: usize = 4096;
const script_default_sync_ms: u32 = 60_000;
const max_script_scan_retries: usize = 5;
const wake_state_waiting: u32 = 2;
const max_wait_recorder_yields: usize = 1_000_000;

const ScriptAction = struct {
    op: []const u8,
    segment_bytes: ?usize = null,
    max_session_bytes: ?u64 = null,
    sync_ms: ?u32 = null,
    instance: ?u64 = null,
    fail_prealloc: ?bool = null,
    thread: ?[]const u8 = null,
    payload_bytes: ?usize = null,
    mode: ?[]const u8 = null,
    enabled: ?bool = null,
    threads: ?u32 = null,
    events_per_thread: ?u64 = null,
    delay_us: ?u64 = null,
    progress_path: ?[]const u8 = null,
    signal_after_started: ?u64 = null,
};

const SegObservation = struct {
    name: []const u8,
    instance: u64,
    index: u64,
    sealed: bool,
    is_current: bool,
    is_next: bool,
    frames: u64,
    torn: u64,
    holes: u64,
    missing: u64,
    overflowed: u64,
    dropped: u64,
};

const GapObservation = struct {
    name: []const u8,
    instance: u64,
    index: u64,
    events: u64,
    frames: u64,
    bytes: u64,
};

const ScriptObservation = struct {
    op: []const u8,
    ok: bool,
    running: bool,
    instance: u64,
    next_ready: bool,
    fail_prealloc: bool,
    segments: []const SegObservation,
    gaps: []const GapObservation,
    total_frames: u64,
    total_torn: u64,
    total_holes: u64,
    total_missing: u64,
    total_overflowed: u64,
    total_dropped: u64,
    total_gap_events: u64,
    emitted_count: u64,
    @"error": ?[]const u8 = null,
};

const GapDetailJson = struct {
    instance: u64 = 0,
    index: u64 = 0,
    events: u64 = 0,
    frames: u64 = 0,
    bytes: u64 = 0,
};

const ScriptSession = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rec: ?*fr.Recorder = null,
    instance: u64 = 1,
    segment_bytes: usize = script_default_segment_bytes,
    max_session_bytes: u64 = lab.default_max_session_bytes,
    sync_ms: u32 = script_default_sync_ms,
    payload_bytes: usize = lab.default_payload_bytes,
    fail_prealloc: bool = false,
    thread_seq: [2]u64 = .{ 0, 0 },
    emitted_count: u64 = 0,

    fn deinit(self: *ScriptSession) void {
        if (self.rec) |rec| {
            rec.stop();
            self.rec = null;
        }
        self.dir.close(self.io);
    }
};

fn writeStartedLine(io: std.Io, count: u64) !void {
    var buf: [64]u8 = undefined;
    const msg = std.mem.print(&buf, "{{\"started\":{d}}}\n", .{count}) catch return;
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}

fn parseScriptThread(name: ?[]const u8) !u32 {
    const raw = name orelse return 0;
    if (std.mem.eql(u8, raw, "ui")) return 0;
    if (std.mem.eql(u8, raw, "worker")) return 1;
    return error.UnknownThread;
}

fn parseFailPreallocMode(action: ScriptAction) !bool {
    if (action.enabled) |v| return v;
    if (action.mode) |m| {
        if (std.mem.eql(u8, m, "on")) return true;
        if (std.mem.eql(u8, m, "off")) return false;
    }
    if (action.fail_prealloc) |v| return v;
    return error.InvalidFailPreallocMode;
}

fn parseSegName(name: []const u8) ?struct { instance: u64, index: u64, sealed: bool } {
    const sealed = std.mem.endsWith(u8, name, ".seg");
    const open = std.mem.endsWith(u8, name, ".open");
    if (!sealed and !open) return null;
    const suffix_len: usize = if (sealed) 4 else 5;
    const stem = name[0 .. name.len - suffix_len];
    const dash = std.mem.findScalar(u8, stem, '-') orelse return null;
    if (dash != 16) return null;
    const instance = std.fmt.parseInt(u64, stem[0..dash], 16) catch return null;
    const index = std.fmt.parseInt(u64, stem[dash + 1 ..], 10) catch return null;
    return .{ .instance = instance, .index = index, .sealed = sealed };
}

fn emitOneScriptEvent(session: *ScriptSession, tid: u32, payload_bytes: usize) !void {
    const rec = session.rec orelse return error.NotRunning;
    if (payload_bytes < lab.min_payload_bytes or payload_bytes > fr.format.max_payload_bytes) {
        return error.InvalidPayloadBytes;
    }
    const buf = try session.gpa.alloc(u8, payload_bytes);
    defer session.gpa.free(buf);
    @memset(buf[lab.min_payload_bytes..], 0xA5);

    const slot: usize = @min(@as(usize, tid), session.thread_seq.len - 1);
    const local_idx = session.thread_seq[slot];
    session.thread_seq[slot] += 1;
    session.emitted_count += 1;

    std.mem.writeInt(u32, buf[0..4], tid, .little);
    std.mem.writeInt(u64, buf[4..12], local_idx, .little);
    rec.emit(1, tid, buf);
}

const BurstCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    rec: *fr.Recorder,
    tid: u32,
    start_idx: u64,
    events_per_thread: u64,
    payload_bytes: usize,
    delay_us: u64,
    started_slot: ?*u64,
    completed_slot: ?*u64,
    started_counter: *std.atomic.Value(u64),
    signal_after_started: ?u64,
};

fn burstWorkerMain(ctx: BurstCtx) void {
    const buf = ctx.gpa.alloc(u8, ctx.payload_bytes) catch @panic("oom in script burst worker");
    defer ctx.gpa.free(buf);
    @memset(buf[lab.min_payload_bytes..], 0xA5);

    var i: u64 = 0;
    while (i < ctx.events_per_thread) : (i += 1) {
        if (ctx.started_slot) |slot| {
            @atomicStore(u64, slot, i, .release);
        }
        const total_started = ctx.started_counter.fetchAdd(1, .acq_rel) + 1;
        if (ctx.signal_after_started) |target| {
            if (total_started == target) {
                writeStartedLine(ctx.io, total_started) catch |err| {
                    std.debug.print("lab: started line not written: {s}\n", .{@errorName(err)});
                };
            }
        }
        std.mem.writeInt(u32, buf[0..4], ctx.tid, .little);
        std.mem.writeInt(u64, buf[4..12], ctx.start_idx + i, .little);
        ctx.rec.emit(1, ctx.tid, buf);
        if (ctx.completed_slot) |slot| {
            @atomicStore(u64, slot, i, .release);
        }
        if (ctx.delay_us > 0) {
            // Pacing only: --delay-us spaces out the emits, and a cancelled sleep just emits sooner.
            ctx.io.sleep(.fromNanoseconds(@as(i96, ctx.delay_us) * 1000), .awake) catch {};
        }
    }
}

fn executeScriptAction(session: *ScriptSession, action: ScriptAction) ?[]const u8 {
    const op = action.op;
    if (std.mem.eql(u8, op, "start")) {
        if (session.rec != null) return "already running";
        if (action.segment_bytes) |v| session.segment_bytes = v;
        if (action.max_session_bytes) |v| session.max_session_bytes = v;
        if (action.sync_ms) |v| session.sync_ms = v;
        if (action.instance) |v| session.instance = v;
        if (action.payload_bytes) |v| session.payload_bytes = v;
        if (action.fail_prealloc) |v| session.fail_prealloc = v;

        const rec = fr.Recorder.start(session.gpa, .{
            .folder = session.dir,
            .io = session.io,
            .instance = session.instance,
            .segment_bytes = session.segment_bytes,
            .max_session_bytes = session.max_session_bytes,
            .sync_interval_ms = session.sync_ms,
            .fail_prealloc_for_test = session.fail_prealloc,
        }) catch |err| return @errorName(err);
        session.rec = rec;
        while (rec.inner.tick_count.load(.acquire) == 0) {
            std.Thread.yield() catch |err| return @errorName(err);
        }
        return null;
    }

    if (std.mem.eql(u8, op, "emit")) {
        const tid = parseScriptThread(action.thread) catch return "invalid thread";
        const pbytes = action.payload_bytes orelse session.payload_bytes;
        emitOneScriptEvent(session, tid, pbytes) catch |err| return @errorName(err);
        return null;
    }

    if (std.mem.eql(u8, op, "tick")) {
        const rec = session.rec orelse return "not running";
        const before = rec.inner.tick_count.load(.acquire);
        rec.inner.wake();
        while (rec.inner.tick_count.load(.acquire) == before) {
            std.Thread.yield() catch |err| return @errorName(err);
        }
        return null;
    }

    if (std.mem.eql(u8, op, "fail_prealloc")) {
        const enabled = parseFailPreallocMode(action) catch return "invalid fail_prealloc mode";
        session.fail_prealloc = enabled;
        if (session.rec) |rec| {
            rec.inner.fail_prealloc_from_index = if (enabled) 0 else null;
        }
        return null;
    }

    if (std.mem.eql(u8, op, "fill_segment")) {
        const rec = session.rec orelse return "not running";
        const tid = parseScriptThread(action.thread) catch return "invalid thread";
        const pbytes = action.payload_bytes orelse session.payload_bytes;
        const seg_before = rec.inner.current.load(.acquire);
        if (seg_before == null) {
            emitOneScriptEvent(session, tid, pbytes) catch |err| return @errorName(err);
            return null;
        }
        const dropped_before = seg_before.?.droppedPtr().load(.acquire);
        const max_iters = session.segment_bytes / fr.format.frame_header_bytes + 16;
        var iter: usize = 0;
        while (iter < max_iters) : (iter += 1) {
            emitOneScriptEvent(session, tid, pbytes) catch |err| return @errorName(err);
            if (rec.inner.current.load(.acquire) != seg_before) break;
            if (seg_before.?.droppedPtr().load(.acquire) > dropped_before) break;
        }
        return null;
    }

    if (std.mem.eql(u8, op, "burst")) {
        const rec = session.rec orelse return "not running";
        const thread_count = action.threads orelse 2;
        if (thread_count == 0 or thread_count > 2) return "invalid burst threads";
        const events_per_thread = action.events_per_thread orelse 4;
        const pbytes = action.payload_bytes orelse session.payload_bytes;
        const delay_us = action.delay_us orelse 0;

        var progress: ?lab.ProgressMap = if (action.progress_path) |p|
            lab.ProgressMap.open(session.io, p, thread_count * 2) catch |err| return @errorName(err)
        else
            null;
        defer if (progress) |*pm| pm.close(session.io);
        if (progress != null) lab.writeReadyLine(session.io) catch |err| return @errorName(err);

        var started_counter: std.atomic.Value(u64) = .init(0);
        var threads: [2]std.Thread = undefined;
        var spawned: usize = 0;
        errdefer for (threads[0..spawned]) |t| t.join();

        while (spawned < thread_count) : (spawned += 1) {
            const tid: u32 = @intCast(spawned);
            const start_idx = session.thread_seq[spawned];
            session.thread_seq[spawned] += events_per_thread;
            threads[spawned] = std.Thread.spawn(.{}, burstWorkerMain, .{BurstCtx{
                .gpa = session.gpa,
                .io = session.io,
                .rec = rec,
                .tid = tid,
                .start_idx = start_idx,
                .events_per_thread = events_per_thread,
                .payload_bytes = pbytes,
                .delay_us = delay_us,
                .started_slot = if (progress) |*pm| pm.slotFor(tid * 2) else null,
                .completed_slot = if (progress) |*pm| pm.slotFor(tid * 2 + 1) else null,
                .started_counter = &started_counter,
                .signal_after_started = action.signal_after_started,
            }}) catch |err| return @errorName(err);
        }
        for (threads[0..spawned]) |t| t.join();
        session.emitted_count += @as(u64, thread_count) * events_per_thread;
        return null;
    }

    if (std.mem.eql(u8, op, "stop")) {
        const rec = session.rec orelse return "not running";
        rec.stop();
        session.rec = null;
        return null;
    }

    return "unknown op";
}

fn waitForRecorderParked(rec: *fr.Recorder) !void {
    var yields: usize = 0;
    while (yields < max_wait_recorder_yields) : (yields += 1) {
        if (rec.inner.stopping.load(.acquire)) return;
        if (rec.inner.wake_state.load(.acquire) == wake_state_waiting) return;
        try std.Thread.yield();
    }
    return error.RecorderNotParked;
}

fn scanScriptFolder(
    session: *ScriptSession,
    scratch: std.mem.Allocator,
    cur_index: ?u64,
    next_index: ?u64,
    segments: *std.ArrayList(SegObservation),
    gaps: *std.ArrayList(GapObservation),
) !void {
    var it = session.dir.iterate();
    while (try it.next(session.io)) |entry| {
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (parseSegName(entry.name)) |meta| {
            const bytes = lab.readFileBytes(session.gpa, session.dir, session.io, entry.name, null) catch |err| {
                if (err == error.FileNotFound) return err;
                return err;
            };
            defer session.gpa.free(bytes);

            var res = fr.read(session.gpa, bytes) catch |err| {
                if (!meta.sealed and (err == error.TooShort or err == error.BadMagic)) continue;
                return err;
            };
            defer res.deinit(session.gpa);

            const is_cur = cur_index != null and meta.instance == session.instance and meta.index == cur_index.?;
            const is_nxt = next_index != null and meta.instance == session.instance and meta.index == next_index.?;
            try segments.append(scratch, .{
                .name = try scratch.dupe(u8, entry.name),
                .instance = meta.instance,
                .index = meta.index,
                .sealed = meta.sealed,
                .is_current = is_cur,
                .is_next = is_nxt,
                .frames = res.frames.items.len,
                .torn = res.torn.items.len,
                .holes = res.holes.items.len,
                .missing = res.missing,
                .overflowed = res.overflowed,
                .dropped = res.dropped,
            });
        } else if (std.mem.startsWith(u8, entry.name, "gap-") and std.mem.endsWith(u8, entry.name, ".json")) {
            const bytes = lab.readFileBytes(session.gpa, session.dir, session.io, entry.name, lab.max_gap_file_bytes) catch |err| {
                if (err == error.FileNotFound) return err;
                return err;
            };
            defer session.gpa.free(bytes);
            const gap = try std.json.parseFromSliceLeaky(GapDetailJson, scratch, bytes, .{ .ignore_unknown_fields = true });
            try gaps.append(scratch, .{
                .name = try scratch.dupe(u8, entry.name),
                .instance = gap.instance,
                .index = gap.index,
                .events = gap.events,
                .frames = gap.frames,
                .bytes = gap.bytes,
            });
        }
    }
}

fn writeScriptObservation(
    session: *ScriptSession,
    op: []const u8,
    err_msg: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    var arena = std.heap.ArenaAllocator.init(session.gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    if (session.rec) |rec| {
        try waitForRecorderParked(rec);
    }

    const cur_index: ?u64 = if (session.rec) |rec|
        if (rec.inner.current.load(.acquire)) |seg| seg.index else null
    else
        null;
    const next_index: ?u64 = if (session.rec) |rec|
        if (rec.inner.next.load(.acquire)) |seg| seg.index else null
    else
        null;

    var segments: std.ArrayList(SegObservation) = .empty;
    var gaps: std.ArrayList(GapObservation) = .empty;

    var attempt: usize = 0;
    while (attempt < max_script_scan_retries) : (attempt += 1) {
        segments.clearRetainingCapacity();
        gaps.clearRetainingCapacity();
        scanScriptFolder(session, scratch, cur_index, next_index, &segments, &gaps) catch |err| {
            if (err == error.FileNotFound and attempt + 1 < max_script_scan_retries) continue;
            return err;
        };
        break;
    }

    std.mem.sort(SegObservation, segments.items, {}, struct {
        fn lessThan(_: void, a: SegObservation, b: SegObservation) bool {
            if (a.instance != b.instance) return a.instance < b.instance;
            return a.index < b.index;
        }
    }.lessThan);

    std.mem.sort(GapObservation, gaps.items, {}, struct {
        fn lessThan(_: void, a: GapObservation, b: GapObservation) bool {
            if (a.instance != b.instance) return a.instance < b.instance;
            return a.index < b.index;
        }
    }.lessThan);

    var total_frames: u64 = 0;
    var total_torn: u64 = 0;
    var total_holes: u64 = 0;
    var total_missing: u64 = 0;
    var total_overflowed: u64 = 0;
    var total_dropped: u64 = 0;
    for (segments.items) |seg| {
        total_frames += seg.frames;
        total_torn += seg.torn;
        total_holes += seg.holes;
        total_missing += seg.missing;
        total_overflowed += seg.overflowed;
        total_dropped += seg.dropped;
    }

    var total_gap_events: u64 = 0;
    for (gaps.items) |g| total_gap_events += g.events;

    const next_ready = next_index != null;
    const obs: ScriptObservation = .{
        .op = op,
        .ok = err_msg == null,
        .running = session.rec != null,
        .instance = session.instance,
        .next_ready = next_ready,
        .fail_prealloc = session.fail_prealloc,
        .segments = segments.items,
        .gaps = gaps.items,
        .total_frames = total_frames,
        .total_torn = total_torn,
        .total_holes = total_holes,
        .total_missing = total_missing,
        .total_overflowed = total_overflowed,
        .total_dropped = total_dropped,
        .total_gap_events = total_gap_events,
        .emitted_count = session.emitted_count,
        .@"error" = err_msg,
    };

    try std.json.Stringify.value(obs, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    const dir = try lab.openPrivateDir(io, dir_path);
    var session: ScriptSession = .{
        .gpa = gpa,
        .io = io,
        .dir = dir,
    };
    defer session.deinit();

    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);

    while (try stdin.interface.takeDelimiter('\n')) |raw| {
        const text = std.mem.trim(u8, raw, " \r\t");
        if (text.len == 0) continue;

        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();

        const action = std.json.parseFromSliceLeaky(ScriptAction, scratch.allocator(), text, .{}) catch {
            try writeScriptObservation(&session, "invalid_json", "invalid json", &stdout.interface);
            continue;
        };
        const err_msg = executeScriptAction(&session, action);
        try writeScriptObservation(&session, action.op, err_msg, &stdout.interface);
    }
}

test "parseSegName parses open and sealed segment file names" {
    const open = parseSegName("000000000000002a-00000003.open").?;
    try testing.expectEqual(@as(u64, 0x2a), open.instance);
    try testing.expectEqual(@as(u64, 3), open.index);
    try testing.expect(!open.sealed);

    const sealed = parseSegName("000000000000002a-00000004.seg").?;
    try testing.expectEqual(@as(u64, 0x2a), sealed.instance);
    try testing.expectEqual(@as(u64, 4), sealed.index);
    try testing.expect(sealed.sealed);

    try testing.expect(parseSegName("gap-000000000000002a-00000000.json") == null);
}
