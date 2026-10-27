//! A session's bounded replay log of host frames. A viewer that attaches or
//! reconnects replays the frames after the sequence it last saw; the oldest
//! frames fall out once the log holds `max_bytes`.
const std = @import("std");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

pub const max_bytes = 2 * 1024 * 1024;

pub const EventLog = struct {
    events: std.ArrayList(Event) = .empty,
    bytes: usize = 0,
    /// The sequence of the newest frame, 0 before the first.
    sequence: u64 = 0,

    const Event = struct { sequence: u64, frame: []u8 };

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
        while (self.events.items.len > 0 and self.bytes + copy.len > max_bytes) {
            const dropped = self.events.orderedRemove(0);
            self.bytes -= dropped.frame.len;
            alloc.free(dropped.frame);
        }
        try self.events.ensureUnusedCapacity(alloc, 1);
        self.sequence += 1;
        self.events.appendAssumeCapacity(.{ .sequence = self.sequence, .frame = copy });
        self.bytes += copy.len;
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

    /// The oldest sequence a viewer can still replay from.
    pub fn oldest(self: *const EventLog) u64 {
        return if (self.events.items.len > 0) self.events.items[0].sequence else self.sequence;
    }
};
