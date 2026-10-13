const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");

const Allocator = std.mem.Allocator;

pub const max_retry_ms: u32 = 60_000;

pub const Event = struct {
    kind: ?[]u8 = null,
    data: []u8,
    id: ?[]u8 = null,
    retry_ms: ?u32 = null,

    pub fn deinit(self: *Event, alloc: Allocator) void {
        if (self.kind) |value| alloc.free(value);
        alloc.free(self.data);
        if (self.id) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Parser = struct {
    alloc: Allocator,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    kind: std.ArrayList(u8) = .empty,
    id: std.ArrayList(u8) = .empty,
    retry_ms: ?u32 = null,
    saw_data: bool = false,
    saw_kind: bool = false,
    saw_id: bool = false,
    saw_retry: bool = false,
    total_bytes: usize = 0,
    event_count: usize = 0,
    max_total_bytes: usize,
    max_event_bytes: usize,
    max_events: usize,
    pending_cr: bool = false,

    pub fn init(
        alloc: Allocator,
        max_total_bytes: usize,
        max_event_bytes: usize,
        max_events: usize,
    ) Parser {
        return .{
            .alloc = alloc,
            .max_total_bytes = max_total_bytes,
            .max_event_bytes = max_event_bytes,
            .max_events = max_events,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.line.deinit(self.alloc);
        self.data.deinit(self.alloc);
        self.kind.deinit(self.alloc);
        self.id.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn feed(self: *Parser, chunk: []const u8, events: *std.ArrayList(Event)) !void {
        self.total_bytes = std.math.add(usize, self.total_bytes, chunk.len) catch
            return error.ResponseTooLarge;
        if (self.max_total_bytes != 0 and self.total_bytes > self.max_total_bytes) {
            return error.ResponseTooLarge;
        }

        for (chunk) |byte| {
            if (self.pending_cr) {
                self.pending_cr = false;
                if (byte == '\n') continue;
            }
            if (byte == '\r') {
                try self.processLine(self.line.items, events);
                self.line.clearRetainingCapacity();
                self.pending_cr = true;
                continue;
            }
            if (byte == '\n') {
                try self.processLine(self.line.items, events);
                self.line.clearRetainingCapacity();
                continue;
            }
            if (self.line.items.len >= self.max_event_bytes) {
                return error.SseEventTooLarge;
            }
            try self.line.append(self.alloc, byte);
        }
    }

    pub fn finish(self: *Parser) !void {
        if (self.line.items.len != 0 or self.hasPendingEvent()) {
            return error.BrokenSseStream;
        }
    }

    fn processLine(
        self: *Parser,
        line: []const u8,
        events: *std.ArrayList(Event),
    ) !void {
        if (line.len == 0) {
            if (!self.hasPendingEvent()) return;
            self.event_count = std.math.add(usize, self.event_count, 1) catch
                return error.TooManySseEvents;
            if (self.max_events != 0 and self.event_count > self.max_events) {
                return error.TooManySseEvents;
            }

            const kind = if (self.saw_kind)
                try self.kind.toOwnedSlice(self.alloc)
            else
                null;
            errdefer if (kind) |value| self.alloc.free(value);
            const data = if (self.saw_data)
                try self.data.toOwnedSlice(self.alloc)
            else
                try self.alloc.dupe(u8, "");
            errdefer self.alloc.free(data);
            const id = if (self.saw_id)
                try self.id.toOwnedSlice(self.alloc)
            else
                null;
            errdefer if (id) |value| self.alloc.free(value);
            const event = Event{
                .kind = kind,
                .data = data,
                .id = id,
                .retry_ms = self.retry_ms,
            };
            try events.append(self.alloc, event);
            self.resetEvent();
            return;
        }
        if (line[0] == ':') return;

        const colon = std.mem.findScalar(u8, line, ':') orelse line.len;
        const field = line[0..colon];
        var value = if (colon < line.len) line[colon + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "data")) {
            const separator_len: usize = if (self.saw_data) 1 else 0;
            const next_len = std.math.add(
                usize,
                self.data.items.len,
                separator_len + value.len,
            ) catch return error.SseEventTooLarge;
            if (next_len > self.max_event_bytes) return error.SseEventTooLarge;
            if (separator_len == 1) try self.data.append(self.alloc, '\n');
            try self.data.appendSlice(self.alloc, value);
            self.saw_data = true;
            return;
        }
        if (std.mem.eql(u8, field, "event")) {
            try self.replaceField(&self.kind, value);
            self.saw_kind = true;
            return;
        }
        if (std.mem.eql(u8, field, "id")) {
            if (std.mem.findScalar(u8, value, 0) != null) return;
            try self.replaceField(&self.id, value);
            self.saw_id = true;
            return;
        }
        if (std.mem.eql(u8, field, "retry")) {
            const parsed = std.fmt.parseInt(u32, value, 10) catch return;
            self.retry_ms = @min(parsed, max_retry_ms);
            self.saw_retry = true;
        }
    }

    fn replaceField(
        self: *Parser,
        target: *std.ArrayList(u8),
        value: []const u8,
    ) !void {
        if (value.len > self.max_event_bytes) return error.SseEventTooLarge;
        target.clearRetainingCapacity();
        try target.appendSlice(self.alloc, value);
    }

    fn hasPendingEvent(self: *const Parser) bool {
        return self.saw_data or self.saw_kind or self.saw_id or self.saw_retry;
    }

    fn resetEvent(self: *Parser) void {
        self.data.clearRetainingCapacity();
        self.kind.clearRetainingCapacity();
        self.id.clearRetainingCapacity();
        self.retry_ms = null;
        self.saw_data = false;
        self.saw_kind = false;
        self.saw_id = false;
        self.saw_retry = false;
    }

    pub fn setMaxEventBytes(self: *Parser, value: usize) void {
        self.max_event_bytes = value;
    }
};

test "legacy SSE parser preserves event data id and bounded retry" {
    const alloc = std.testing.allocator;
    var parser = Parser.init(alloc, 1024, 256, 4);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer {
        for (events.items) |*event| event.deinit(alloc);
        events.deinit(alloc);
    }

    try parser.feed(
        "event: message\r\ndata: one\ndata: two\nid: event-7\nretry: 90000\n\n",
        &events,
    );
    try parser.finish();

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("message", events.items[0].kind.?);
    try std.testing.expectEqualStrings("one\ntwo", events.items[0].data);
    try std.testing.expectEqualStrings("event-7", events.items[0].id.?);
    try std.testing.expectEqual(max_retry_ms, events.items[0].retry_ms.?);
}

fn expectLegacySseDelimiterSplits(payload: []const u8) !void {
    const alloc = std.testing.allocator;
    for (0..payload.len + 1) |split| {
        var parser = Parser.init(alloc, payload.len, 128, 1);
        defer parser.deinit();
        var events: std.ArrayList(Event) = .empty;
        defer {
            for (events.items) |*event| event.deinit(alloc);
            events.deinit(alloc);
        }
        try parser.feed(payload[0..split], &events);
        try parser.feed(payload[split..], &events);
        try parser.finish();
        try std.testing.expectEqual(@as(usize, 1), events.items.len);
        try std.testing.expectEqualStrings("message", events.items[0].kind.?);
        try std.testing.expectEqualStrings("one\ntwo", events.items[0].data);
        try std.testing.expectEqualStrings("event-1", events.items[0].id.?);
    }
}

test "legacy SSE parser accepts CR LF and CRLF across every chunk split" {
    for ([_][]const u8{
        "event: message\ndata: one\ndata: two\nid: event-1\n\n",
        "event: message\rdata: one\rdata: two\rid: event-1\r\r",
        "event: message\r\ndata: one\r\ndata: two\r\nid: event-1\r\n\r\n",
        "event: message\r\ndata: one\rdata: two\r\nid: event-1\r\r\n",
    }) |payload| {
        try expectLegacySseDelimiterSplits(payload);
    }
}

fn checkCompleteEventAllocationFailures(alloc: Allocator) !void {
    var parser = Parser.init(alloc, 1024, 256, 4);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer {
        for (events.items) |*event| event.deinit(alloc);
        events.deinit(alloc);
    }

    try parser.feed("event: message\ndata: payload\nid: event-1\n\n", &events);
}

test "legacy SSE parser releases complete event fields across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkCompleteEventAllocationFailures,
        .{},
    );
}

test "legacy SSE parser emits empty priming events" {
    const alloc = std.testing.allocator;
    var parser = Parser.init(alloc, 256, 64, 2);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer {
        for (events.items) |*event| event.deinit(alloc);
        events.deinit(alloc);
    }

    try parser.feed("id:\ndata:\n\n", &events);
    try parser.finish();

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("", events.items[0].data);
    try std.testing.expectEqualStrings("", events.items[0].id.?);
}

test "legacy SSE parser rejects partial and over-limit streams" {
    const alloc = std.testing.allocator;
    var partial = Parser.init(alloc, 64, 32, 1);
    defer partial.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(alloc);
    try partial.feed("data: unfinished", &events);
    try std.testing.expectError(error.BrokenSseStream, partial.finish());

    var over_limit = Parser.init(alloc, 8, 8, 1);
    defer over_limit.deinit();
    try std.testing.expectError(
        error.ResponseTooLarge,
        over_limit.feed("data: too long\n\n", &events),
    );
}

fn fuzzParser(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var input_buffer: [1024]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];
    const split = input.len / 2;

    var parser = Parser.init(alloc, input_buffer.len, 256, 16);
    defer parser.deinit();
    var events: std.ArrayList(Event) = .empty;
    defer {
        for (events.items) |*event| event.deinit(alloc);
        events.deinit(alloc);
    }

    parser.feed(input[0..split], &events) catch return;
    parser.feed(input[split..], &events) catch return;
    parser.finish() catch return;
}

test "legacy SSE parser handles fuzzed event bytes" {
    try std.testing.fuzz({}, fuzzParser, .{
        .corpus = &.{
            "",
            "\n",
            "data: {}\n\n",
            "data: {}\r\r",
            "event: message\nid: event-1\nretry: 500\ndata: {\"jsonrpc\":\"2.0\"}\n\n",
            "data: one\r\ndata: two\r\n\r\n",
            "data: one\r\ndata: two\r\r\n",
            "\xff\x00\n\n",
        },
    });
}
