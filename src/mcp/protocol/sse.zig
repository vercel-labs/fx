//! Server-Sent Events, the parts MCP uses: `data` lines joined
//! into one event, which a blank line ends; the `id` field, which sets the
//! stream's last event id; and `retry`, the reconnection time. Comments (lines
//! starting with `:`) and `event` are ignored. 2026 streams can't be
//! resumed, so only 2025 sessions use `id` and `retry`.
//! Pure: the caller reads each line, without its ending, onto the end of the
//! event's buffer (`io/lines.zig`), which it owns, so a large event is read
//! into one buffer once.

const std = @import("std");

pub const Error = error{OutOfMemory};

/// One dispatched event. `id` is valid until the next call.
pub const Event = struct {
    /// The joined `data` lines, the event's buffer; null when it had none.
    data: ?[]const u8,
    /// The stream's last event id, when this event set it.
    id: ?[]const u8,
    /// The reconnection time, when this event set it.
    retry_ms: ?u32,
};

pub const Parser = struct {
    last_id: std.ArrayList(u8) = .empty,
    has_data: bool = false,
    set_id: bool = false,
    retry_ms: ?u32 = null,

    pub fn deinit(p: *Parser, gpa: std.mem.Allocator) void {
        p.last_id.deinit(gpa);
    }

    /// Takes the line at the end of `buf`, from `mark`. A data line's value
    /// stays there, after a LF when data came before, so `buf` holds the
    /// event's data and nothing else; any other line is read and cut off.
    /// An empty line ends the event: when it carried data, an id, or a
    /// retry, returns it, its data `buf`'s items, which the caller then takes
    /// or clears.
    pub fn line(p: *Parser, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), mark: usize) Error!?Event {
        const text = buf.items[mark..];
        if (text.len == 0) {
            if (!p.has_data and !p.set_id and p.retry_ms == null) return null;
            const event: Event = .{
                .data = if (p.has_data) buf.items else null,
                .id = if (p.set_id) p.last_id.items else null,
                .retry_ms = p.retry_ms,
            };
            p.has_data = false;
            p.set_id = false;
            p.retry_ms = null;
            return event;
        }
        const colon = std.mem.findScalar(u8, text, ':');
        const field = text[0 .. colon orelse text.len];
        var start = if (colon) |c| c + 1 else text.len;
        if (start < text.len and text[start] == ' ') start += 1;
        if (text[0] != ':' and std.mem.eql(u8, field, "data")) {
            const len = text.len - start;
            const at = mark + @intFromBool(p.has_data);
            if (p.has_data) buf.items[mark] = '\n';
            @memmove(buf.items[at..][0..len], buf.items[mark + start ..][0..len]);
            buf.shrinkRetainingCapacity(at + len);
            p.has_data = true;
            return null;
        }
        defer buf.shrinkRetainingCapacity(mark);
        if (text[0] == ':') return null;
        const value = text[start..];
        if (std.mem.eql(u8, field, "id")) {
            // The SSE standard ignores an id containing NUL.
            if (std.mem.findScalar(u8, value, 0) != null) return null;
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

/// Reads each line onto the buffer, as `io/lines.zig` does, and takes each
/// event's data as the HTTP reader does.
fn feed(p: *Parser, text: []const u8, out: *std.ArrayList(Seen)) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const mark = buf.items.len;
        try buf.appendSlice(testing.allocator, l);
        if (try p.line(testing.allocator, &buf, mark)) |e| {
            try out.append(testing.allocator, .{
                .data = if (e.data) |d| try testing.allocator.dupe(u8, d) else null,
                .id = if (e.id) |i| try testing.allocator.dupe(u8, i) else null,
                .retry_ms = e.retry_ms,
            });
            buf.clearRetainingCapacity();
        }
    }
}

fn freeAll(events: *std.ArrayList(Seen)) void {
    for (events.items) |e| {
        if (e.data) |d| testing.allocator.free(d);
        if (e.id) |i| testing.allocator.free(i);
    }
    events.deinit(testing.allocator);
}

test "joins data lines into events and ignores comments and the event field" {
    var p: Parser = .{};
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
    var p: Parser = .{};
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

test "the buffer keeps only the event's data: comments, ids, and retries are cut off" {
    var p: Parser = .{};
    defer p.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for ([_][]const u8{ "data: ab", ": a comment between data lines", "id: 7", "retry: 10", "data:c", "event: x" }) |l| {
        const mark = buf.items.len;
        try buf.appendSlice(testing.allocator, l);
        try testing.expectEqual(@as(?Event, null), try p.line(testing.allocator, &buf, mark));
    }
    try testing.expectEqualStrings("ab\nc", buf.items);
    const e = (try p.line(testing.allocator, &buf, buf.items.len)).?;
    try testing.expectEqualStrings("ab\nc", e.data.?);
    try testing.expectEqualStrings("7", e.id.?);
    try testing.expectEqual(@as(?u32, 10), e.retry_ms);
}
