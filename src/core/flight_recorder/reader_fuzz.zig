//! Fuzz target `flight_recorder_segment` (`tests/fuzz/targets.json`). Reading
//! fuzzed bytes either refuses them or gives a result that stays inside them,
//! and a segment written from fuzzed frames reads back the same.

const std = @import("std");
const testing = std.testing;
const format = @import("format.zig");
const reader = @import("reader.zig");

const max_segment_bytes: usize = 4096;
const max_frames: usize = 4;
const max_payload_input_bytes: usize = 512;

const FramePlan = struct {
    kind: u16,
    thread: u32,
    seq: u64,
    mono_ns: u64,
    wall_ms: u64,
    payload_len: u32,
};

fn fuzzSegment(_: void, smith: *testing.Smith) !void {
    var input: [max_segment_bytes]u8 = undefined;
    const input_len = smith.slice(&input);
    try expectReadsOrRefuses(input[0..input_len]);
    try expectWrittenSegmentReadsBack(smith);
}

fn expectReadsOrRefuses(bytes: []const u8) !void {
    var result = reader.read(testing.allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer result.deinit(testing.allocator);
    try expectResultInside(bytes, result);
}

fn expectResultInside(bytes: []const u8, result: reader.Result) !void {
    const start = @intFromPtr(bytes.ptr);
    const stop = start + bytes.len;
    for (result.frames.items) |frame| {
        try testing.expect(frame.offset % 8 == 0);
        try testing.expect(frame.offset >= format.segment_header_bytes);
        const payload_start = @intFromPtr(frame.payload.ptr);
        try testing.expect(payload_start >= start);
        try testing.expect(payload_start + frame.payload.len <= stop);
    }
    for (result.holes.items) |hole| {
        try testing.expect(hole.offset + hole.len <= bytes.len);
    }
}

fn expectWrittenSegmentReadsBack(smith: *testing.Smith) !void {
    var payloads: [max_frames][max_payload_input_bytes]u8 = undefined;
    var plans: [max_frames]FramePlan = undefined;
    const frame_count: usize = smith.valueRangeAtMost(u8, 0, max_frames);
    for (0..frame_count) |index| {
        plans[index] = .{
            .kind = smith.value(u16),
            .thread = smith.value(u32),
            .seq = smith.value(u64),
            .mono_ns = smith.value(u64),
            .wall_ms = smith.value(u64),
            .payload_len = smith.slice(&payloads[index]),
        };
    }
    const dropped = smith.value(u64);

    var segment: [max_segment_bytes]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    for (plans[0..frame_count], 0..) |plan, index| {
        const written = try format.encodeFrame(segment[end..], .{
            .payload_len = plan.payload_len,
            .kind = plan.kind,
            .flags = 0,
            .thread = plan.thread,
            .reservation_index = @intCast(index),
            .seq = plan.seq,
            .mono_ns = plan.mono_ns,
            .wall_ms = plan.wall_ms,
        }, payloads[index][0..plan.payload_len]);
        end += written;
    }
    segment[0..format.segment_header_bytes].* = format.encodeSegmentHeader(.{
        .format_version = format.format_version,
        .header_bytes = format.segment_header_bytes,
        .instance = 1,
        .index = 0,
        .created_wall_ms = 0,
        .capacity = segment.len,
        .cursor = .{ .offset = end, .count = @intCast(frame_count) },
        .overflowed = 0,
        .dropped = dropped,
    });

    try expectReadBack(&segment, plans[0..frame_count], payloads[0..frame_count], dropped);
}

fn expectReadBack(segment: []const u8, plans: []const FramePlan, payloads: []const [max_payload_input_bytes]u8, dropped: u64) !void {
    var result = try reader.read(testing.allocator, segment);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(plans.len, result.frames.items.len);
    try testing.expectEqual(@as(usize, 0), result.torn.items.len);
    try testing.expectEqual(@as(usize, 0), result.holes.items.len);
    try testing.expectEqual(@as(u64, 0), result.missing);
    try testing.expectEqual(dropped, result.dropped);
    for (plans, result.frames.items, 0..) |plan, frame, index| {
        try testing.expectEqual(@as(u32, @intCast(index)), frame.reservation_index);
        try testing.expectEqual(plan.kind, frame.kind);
        try testing.expectEqual(plan.thread, frame.thread);
        try testing.expectEqual(plan.seq, frame.seq);
        try testing.expectEqual(plan.mono_ns, frame.mono_ns);
        try testing.expectEqual(plan.wall_ms, frame.wall_ms);
        try testing.expectEqualSlices(u8, payloads[index][0..plan.payload_len], frame.payload);
    }
}

test "a flight recorder segment reads or is refused on fuzzed bytes, and a written segment reads back the same" {
    try testing.fuzz({}, fuzzSegment, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "FXFR",
        }) ++ @import("fuzz_corpus").flight_recorder_segment.*),
    });
}
