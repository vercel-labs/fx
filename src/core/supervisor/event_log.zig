//! A session's bounded replay log of host frames. A viewer that attaches or
//! reconnects replays the frames after the sequence it last saw. Once the
//! log holds `max_bytes`, the oldest tool-input previews fall out first:
//! each one only repeats the tail of a call's streaming arguments, which
//! the call itself replaces, and a long argument stream sends one every
//! 50 ms. Only when no preview is left do the oldest other frames go.
const std = @import("std");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

pub const max_bytes = 2 * 1024 * 1024;

pub const EventLog = struct {
    events: std.ArrayList(Event) = .empty,
    bytes: usize = 0,
    /// The sequence of the newest frame, 0 before the first.
    sequence: u64 = 0,
    /// The newest sequence whose frame fell out and was not a preview: a
    /// viewer at or before it cannot replay what it missed.
    dropped_through: u64 = 0,
    transient_count: usize = 0,

    const Event = struct { sequence: u64, frame: []u8, transient: bool = false };

    pub fn deinit(self: *EventLog, alloc: Allocator) void {
        for (self.events.items) |event| alloc.free(event.frame);
        self.events.deinit(alloc);
    }

    /// Appends a copy of `frame`, or a gap marker for a frame too large to
    /// keep; its content stays in the saved history.
    pub fn append(self: *EventLog, alloc: Allocator, frame: []const u8) !void {
        const kept = if (frame.len <= max_bytes)
            frame
        else
            "{\"method\":\"" ++ protocol.replay_gap_method ++ "\",\"params\":{\"reason\":\"large event is available in saved history\"}}";
        const copy = try alloc.dupe(u8, kept);
        errdefer alloc.free(copy);
        while (self.events.items.len > 0 and self.bytes + copy.len > max_bytes) self.dropOne(alloc);
        try self.events.ensureUnusedCapacity(alloc, 1);
        self.sequence += 1;
        const transient = isTransient(copy);
        self.events.appendAssumeCapacity(.{ .sequence = self.sequence, .frame = copy, .transient = transient });
        self.bytes += copy.len;
        if (transient) self.transient_count += 1;
    }

    /// Drops the oldest preview, or the oldest frame when none is left.
    fn dropOne(self: *EventLog, alloc: Allocator) void {
        var index: usize = 0;
        if (self.transient_count > 0) {
            while (!self.events.items[index].transient) index += 1;
        }
        const dropped = self.events.orderedRemove(index);
        self.bytes -= dropped.frame.len;
        alloc.free(dropped.frame);
        if (dropped.transient) {
            self.transient_count -= 1;
        } else {
            self.dropped_through = @max(self.dropped_through, dropped.sequence);
        }
    }

    /// A native frame carrying a tool-input preview. Quotes inside JSON
    /// strings are escaped, so the key path cannot come from text.
    fn isTransient(frame: []const u8) bool {
        const head = frame[0..@min(frame.len, 512)];
        return std.mem.find(u8, head, "\"method\":\"proto/native_presentation\"") != null and
            std.mem.find(u8, head, "\"event\":{\"tool_input_preview\":") != null;
    }

    /// The frames after `checkpoint`, borrowing the log's bytes.
    pub fn after(self: *const EventLog, arena: Allocator, checkpoint: u64) ![]protocol.Event(protocol.RawJson) {
        var out: std.ArrayList(protocol.Event(protocol.RawJson)) = .empty;
        for (self.events.items) |event| {
            if (event.sequence <= checkpoint) continue;
            try out.append(arena, .{ .sequence = event.sequence, .frame = .{ .bytes = event.frame } });
        }
        return out.items;
    }

    /// The oldest sequence a viewer can still replay from: a viewer whose
    /// last seen sequence is below `oldest() - 1` missed frames for good.
    pub fn oldest(self: *const EventLog) u64 {
        return self.dropped_through + 1;
    }
};

fn previewFrame(alloc: Allocator, body: usize) ![]u8 {
    const filler = try alloc.alloc(u8, body);
    defer alloc.free(filler);
    @memset(filler, 'x');
    return alloc.print("{{\"jsonrpc\":\"2.0\",\"method\":\"proto/native_presentation\",\"params\":{{\"session_id\":\"s\",\"event\":{{\"tool_input_preview\":{{\"body\":\"{s}\"}}}}}}}}", .{filler});
}

test "a full log drops tool-input previews before the frames a reattach replays" {
    const alloc = std.testing.allocator;
    var log: EventLog = .{};
    defer log.deinit(alloc);
    try log.append(alloc, "{\"method\":\"proto/native_presentation\",\"params\":{\"event\":{\"user_prompt\":\"first\"}}}");
    const preview = try previewFrame(alloc, 64 * 1024);
    defer alloc.free(preview);
    // Far more preview bytes than the log holds, as a long write streams.
    for (0..80) |_| try log.append(alloc, preview);
    try log.append(alloc, "{\"method\":\"proto/native_presentation\",\"params\":{\"event\":{\"tool_lifecycle\":\"started\"}}}");

    try std.testing.expect(log.bytes <= max_bytes);
    try std.testing.expectEqual(@as(u64, 1), log.oldest());
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const replay = try log.after(arena.allocator(), 0);
    try std.testing.expectEqual(@as(u64, 1), replay[0].sequence);
    try std.testing.expect(std.mem.find(u8, replay[0].frame.bytes, "first") != null);
    try std.testing.expect(std.mem.find(u8, replay[replay.len - 1].frame.bytes, "tool_lifecycle") != null);
}

test "a log full of other frames names the sequences it can no longer replay" {
    const alloc = std.testing.allocator;
    var log: EventLog = .{};
    defer log.deinit(alloc);
    const filler = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(filler);
    @memset(filler, 'a');
    const frame = try alloc.print("{{\"method\":\"session/update\",\"text\":\"{s}\"}}", .{filler});
    defer alloc.free(frame);
    for (0..12) |_| try log.append(alloc, frame);
    try std.testing.expect(log.oldest() > 1);
    try std.testing.expectEqual(log.events.items[0].sequence, log.oldest());
}
