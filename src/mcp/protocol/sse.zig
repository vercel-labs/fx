//! Server-Sent Events, the parts MCP uses: `data` lines joined
//! into one event, which a blank line ends; the `id` field, which sets the
//! stream's last event id; and `retry`, the reconnection time. Comments (lines
//! starting with `:`) and `event` are ignored. 2026 streams can't be
//! resumed, so only 2025 sessions use `id` and `retry`.
//! Pure: the caller feeds lines without their line endings (`io/lines.zig`)
//! and owns the buffer.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    /// An event over the limit ends the stream.
    EventTooLarge,
};

/// One dispatched event. Slices are valid until the next call.
pub const Event = struct {
    /// The joined `data` lines; null when the event had none.
    data: ?[]const u8,
    /// The stream's last event id, when this event set it.
    id: ?[]const u8,
    /// The reconnection time, when this event set it.
    retry_ms: ?u32,
};

pub const Parser = struct {
    data: std.ArrayList(u8) = .empty,
    last_id: std.ArrayList(u8) = .empty,
    has_data: bool = false,
    set_id: bool = false,
    retry_ms: ?u32 = null,
    /// The last call returned an event, so its fields are cleared on the next.
    returned: bool = false,
    max_event: usize,

    pub fn init(max_event: usize) Parser {
        return .{ .max_event = max_event };
    }

    pub fn deinit(p: *Parser, gpa: std.mem.Allocator) void {
        p.data.deinit(gpa);
        p.last_id.deinit(gpa);
    }

    /// Feeds one line. When the line ends an event that carried data, an id,
    /// or a retry, returns it.
    pub fn line(p: *Parser, gpa: std.mem.Allocator, text: []const u8) Error!?Event {
        if (p.returned) {
            p.data.clearRetainingCapacity();
            p.has_data = false;
            p.set_id = false;
            p.retry_ms = null;
            p.returned = false;
        }
        if (text.len == 0) {
            if (!p.has_data and !p.set_id and p.retry_ms == null) return null;
            p.returned = true;
            return .{
                .data = if (p.has_data) p.data.items else null,
                .id = if (p.set_id) p.last_id.items else null,
                .retry_ms = p.retry_ms,
            };
        }
        if (text[0] == ':') return null;
        const colon = std.mem.findScalar(u8, text, ':');
        const field = text[0 .. colon orelse text.len];
        var value = if (colon) |c| text[c + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, field, "data")) {
            const extra = value.len + @intFromBool(p.has_data);
            if (p.data.items.len + extra > p.max_event) return error.EventTooLarge;
            if (p.has_data) try p.data.append(gpa, '\n');
            try p.data.appendSlice(gpa, value);
            p.has_data = true;
        } else if (std.mem.eql(u8, field, "id")) {
            // The SSE standard ignores an id containing NUL.
            if (std.mem.findScalar(u8, value, 0) != null) return null;
            if (value.len > p.max_event) return error.EventTooLarge;
            p.last_id.clearRetainingCapacity();
            try p.last_id.appendSlice(gpa, value);
            p.set_id = true;
        } else if (std.mem.eql(u8, field, "retry")) {
            // Only ASCII digits count; larger values saturate.
            if (value.len == 0) return null;
            var ms: u32 = 0;
            for (value) |c| {
                if (c < '0' or c > '9') return null;
                ms = std.math.mul(u32, ms, 10) catch std.math.maxInt(u32);
                ms = std.math.add(u32, ms, c - '0') catch std.math.maxInt(u32);
            }
            p.retry_ms = ms;
        }
        return null;
    }
};

const testing = std.testing;

const Seen = struct { data: ?[]const u8, id: ?[]const u8, retry_ms: ?u32 };

fn feed(p: *Parser, text: []const u8, out: *std.ArrayList(Seen)) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (try p.line(testing.allocator, l)) |e| try out.append(testing.allocator, .{
        .data = if (e.data) |d| try testing.allocator.dupe(u8, d) else null,
        .id = if (e.id) |i| try testing.allocator.dupe(u8, i) else null,
        .retry_ms = e.retry_ms,
    });
}

fn freeAll(events: *std.ArrayList(Seen)) void {
    for (events.items) |e| {
        if (e.data) |d| testing.allocator.free(d);
        if (e.id) |i| testing.allocator.free(i);
    }
    events.deinit(testing.allocator);
}

test "joins data lines into events and ignores comments and the event field" {
    var p: Parser = .init(1024);
    defer p.deinit(testing.allocator);
    var events: std.ArrayList(Seen) = .empty;
    defer freeAll(&events);
    try feed(&p, ":\n: keep-alive\nevent: message\ndata: {\"a\":1}\n\n\n" ++
        "data:{\"b\":\ndata:  2}\n\ndata\n\ndatum: x\n\n", &events);
    try testing.expectEqual(@as(usize, 3), events.items.len);
    try testing.expectEqualStrings("{\"a\":1}", events.items[0].data.?);
    try testing.expectEqualStrings("{\"b\":\n 2}", events.items[1].data.?);
    try testing.expectEqualStrings("", events.items[2].data.?);
}

test "reports ids and retry values, including a priming event" {
    var p: Parser = .init(1024);
    defer p.deinit(testing.allocator);
    var events: std.ArrayList(Seen) = .empty;
    defer freeAll(&events);
    try feed(&p, "id: e-1\nretry: 500\ndata: \n\n" ++ // priming: an id and empty data
        "data: {\"x\":1}\n\n" ++ // no id: the last one stays, but this event didn't set it
        "id: e-2\n\n" ++ // an id alone is still an event
        "retry: 5x\nid: bad\x00\n\n" ++ // ignored: non-digit retry, an id with NUL
        "retry: 99999999999\n\n", &events);
    try testing.expectEqual(@as(usize, 4), events.items.len);
    try testing.expectEqualStrings("", events.items[0].data.?);
    try testing.expectEqualStrings("e-1", events.items[0].id.?);
    try testing.expectEqual(@as(?u32, 500), events.items[0].retry_ms);
    try testing.expectEqual(@as(?[]const u8, null), events.items[1].id);
    try testing.expectEqual(@as(?[]const u8, null), events.items[2].data);
    try testing.expectEqualStrings("e-2", events.items[2].id.?);
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), events.items[3].retry_ms);
}

test "an event over the limit is an error" {
    var p: Parser = .init(8);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(?Event, null), try p.line(testing.allocator, "data: 1234"));
    try testing.expectError(error.EventTooLarge, p.line(testing.allocator, "data: 5678"));
}
