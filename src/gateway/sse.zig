const std = @import("std");

const Error = error{ OutOfMemory, ReadFailed, Cancelled, EventTooLarge, StreamTooLarge };

const Line = union(enum) { boundary, data: []const u8, ignored };

fn classify(line: []const u8) Line {
    if (line.len == 0) return .boundary;
    const colon = std.mem.findScalar(u8, line, ':') orelse line.len;
    if (!std.mem.eql(u8, line[0..colon], "data")) return .ignored;
    var value = if (colon < line.len) line[colon + 1 ..] else "";
    if (value.len > 0 and value[0] == ' ') value = value[1..];
    return .{ .data = value };
}

fn line_end(bytes: []const u8) usize {
    var offset: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |width| {
        const Vector = @Vector(width, u8);
        while (bytes.len - offset >= width) : (offset += width) {
            const chunk: Vector = bytes[offset..][0..width].*;
            const matches = @select(bool, chunk == @as(Vector, @splat('\r')), @as(@Vector(width, bool), @splat(true)), chunk == @as(Vector, @splat('\n')));
            if (std.simd.firstTrue(matches)) |index| return offset + index;
        }
    }
    for (bytes[offset..], offset..) |byte, index| {
        if (byte == '\r' or byte == '\n') return index;
    }
    return bytes.len;
}

/// Request-local SSE framing. The caller owns the source and all allocations.
/// Returned data is borrowed until the next next() call or deinit().
pub const Reader = struct {
    max_event_bytes: usize,
    max_total_bytes: ?usize = null,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    total_bytes: usize = 0,
    first_line: bool = true,
    skip_lf: bool = false,

    pub fn deinit(self: *Reader, alloc: std.mem.Allocator) void {
        self.line.deinit(alloc);
        self.data.deinit(alloc);
        self.* = undefined;
    }

    /// Reads through one blank-line delimiter without waiting for the next event.
    /// Cancellation is checked before reads; blocked I/O remains source-owned.
    pub fn next(self: *Reader, alloc: std.mem.Allocator, source: *std.Io.Reader, cancelled: *const std.atomic.Value(bool)) Error!?[]const u8 {
        self.data.clearRetainingCapacity();
        var saw_data = false;
        while (try self.read_line(alloc, source, cancelled)) |raw| {
            const line = if (self.first_line and std.mem.startsWith(u8, raw, "\xef\xbb\xbf")) raw[3..] else raw;
            self.first_line = false;
            switch (classify(line)) {
                .ignored => {},
                .boundary => if (saw_data) return self.data.items,
                .data => |value| {
                    if (saw_data) {
                        if (self.data.items.len == self.max_event_bytes) return error.EventTooLarge;
                        try self.data.append(alloc, '\n');
                    }
                    if (value.len > self.max_event_bytes - self.data.items.len) return error.EventTooLarge;
                    if (!saw_data and self.line.items.len > 0) {
                        // Reuse owned split-line storage instead of retaining a second large payload.
                        std.mem.copyForwards(u8, self.line.items[0..value.len], value);
                        self.line.items.len = value.len;
                        std.mem.swap(std.ArrayList(u8), &self.line, &self.data);
                    } else try self.data.appendSlice(alloc, value);
                    saw_data = true;
                },
            }
        }
        // EOF is not an event delimiter; consumers still require terminal proof.
        return null;
    }

    fn consume(self: *Reader, source: *std.Io.Reader, count: usize) Error!void {
        if (self.max_total_bytes) |limit| {
            if (count > limit - self.total_bytes) return error.StreamTooLarge;
            self.total_bytes += count;
        }
        source.toss(count);
    }

    fn read_line(self: *Reader, alloc: std.mem.Allocator, source: *std.Io.Reader, cancelled: *const std.atomic.Value(bool)) Error!?[]const u8 {
        self.line.clearRetainingCapacity();
        while (true) {
            if (cancelled.load(.seq_cst)) return error.Cancelled;
            var bytes = source.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return null,
                error.ReadFailed => return error.ReadFailed,
            };
            if (cancelled.load(.seq_cst)) return error.Cancelled;
            if (self.skip_lf) {
                self.skip_lf = false;
                if (bytes[0] == '\n') {
                    try self.consume(source, 1);
                    bytes = bytes[1..];
                    if (bytes.len == 0) continue;
                }
            }
            const end = line_end(bytes);
            if (end > self.max_event_bytes - self.line.items.len) return error.EventTooLarge;
            if (end < bytes.len) {
                self.skip_lf = bytes[end] == '\r';
                try self.consume(source, end + 1);
                if (self.line.items.len == 0) return bytes[0..end];
                try self.line.appendSlice(alloc, bytes[0..end]);
                return self.line.items;
            }
            try self.consume(source, end);
            try self.line.appendSlice(alloc, bytes);
        }
    }
};

test "provider framing preserves data across encoding and chunk boundaries" {
    const payloads = [_][]const u8{
        "data: one\ndata:  two \n\ndata:three\n\n",
        "\xef\xbb\xbf: heartbeat\r\nevent: message\r\ndata: one\r\ndata:  two \r\n\r\ndata:three\r\n\r\n",
        "data: one\rdata:  two \r\rdata:three\r\r",
    };
    for (payloads) |payload| for (1..payload.len + 1) |size| {
        const buffer = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(buffer);
        var fixed = std.Io.Reader.fixed(payload);
        var source = fixed.limited(.unlimited, buffer);
        var reader = Reader{ .max_event_bytes = 128 };
        defer reader.deinit(std.testing.allocator);
        const cancelled = std.atomic.Value(bool).init(false);
        try std.testing.expectEqualStrings("one\n two ", (try reader.next(std.testing.allocator, &source.interface, &cancelled)).?);
        try std.testing.expectEqualStrings("three", (try reader.next(std.testing.allocator, &source.interface, &cancelled)).?);
        try std.testing.expectEqual(null, try reader.next(std.testing.allocator, &source.interface, &cancelled));
    };
}

test "provider framing never dispatches an unfinished event" {
    for ([_][]const u8{ "", ": comment\n\n", "data: partial", "data: partial\n", "data: one\ndata: two\n" }) |payload| {
        var source = std.Io.Reader.fixed(payload);
        var reader = Reader{ .max_event_bytes = 128 };
        defer reader.deinit(std.testing.allocator);
        const cancelled = std.atomic.Value(bool).init(false);
        try std.testing.expectEqual(null, try reader.next(std.testing.allocator, &source, &cancelled));
    }
}

test "provider framing preserves long fields with mixed delimiters" {
    var text: [129]u8 = undefined;
    @memset(&text, 'x');
    const alloc = std.testing.allocator;
    for (0..text.len + 1) |size| {
        const wire = try std.mem.concat(alloc, u8, &.{ "data:", text[0..size], "\r\rdata:tail\n\n" });
        defer alloc.free(wire);
        var source = std.Io.Reader.fixed(wire);
        var reader = Reader{ .max_event_bytes = 256 };
        defer reader.deinit(alloc);
        const cancelled = std.atomic.Value(bool).init(false);
        try std.testing.expectEqualStrings(text[0..size], (try reader.next(alloc, &source, &cancelled)).?);
        try std.testing.expectEqualStrings("tail", (try reader.next(alloc, &source, &cancelled)).?);
    }
}

test "provider framing stops at the delimiter and observes cancellation" {
    const payload = "data: first\r\r";
    var source = std.Io.Reader.failing;
    source.buffer = @constCast(payload);
    source.end = payload.len;
    var reader = Reader{ .max_event_bytes = 128 };
    defer reader.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectEqualStrings("first", (try reader.next(std.testing.allocator, &source, &cancelled)).?);
    cancelled.store(true, .seq_cst);
    try std.testing.expectError(error.Cancelled, reader.next(std.testing.allocator, &source, &cancelled));
    cancelled.store(false, .seq_cst);
    try std.testing.expectError(error.ReadFailed, reader.next(std.testing.allocator, &source, &cancelled));
}

test "provider framing bounds lines assembled events and ignored wire" {
    const cases = [_]struct { wire: []const u8, max: usize, expected: ?[]const u8 }{
        .{ .wire = "data: 12\n\n", .max = 8, .expected = "12" },
        .{ .wire = "data: 12\n\n", .max = 7, .expected = null },
        .{ .wire = "data:12\ndata:34\ndata:56\n\n", .max = 8, .expected = "12\n34\n56" },
        .{ .wire = "data:12\ndata:34\ndata:56\n\n", .max = 7, .expected = null },
    };
    for (cases) |case| {
        var source = std.Io.Reader.fixed(case.wire);
        var reader = Reader{ .max_event_bytes = case.max };
        defer reader.deinit(std.testing.allocator);
        const cancelled = std.atomic.Value(bool).init(false);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, (try reader.next(std.testing.allocator, &source, &cancelled)).?);
        } else try std.testing.expectError(error.EventTooLarge, reader.next(std.testing.allocator, &source, &cancelled));
    }
    const wire = ": ignored\r\nevent: message\r\ndata:x\r\n\r\n";
    for ([_]usize{ wire.len, wire.len - 2 }) |limit| {
        var source = std.Io.Reader.fixed(wire);
        var reader = Reader{ .max_event_bytes = 64, .max_total_bytes = limit };
        defer reader.deinit(std.testing.allocator);
        const cancelled = std.atomic.Value(bool).init(false);
        if (limit == wire.len) {
            try std.testing.expectEqualStrings("x", (try reader.next(std.testing.allocator, &source, &cancelled)).?);
            try std.testing.expectEqual(null, try reader.next(std.testing.allocator, &source, &cancelled));
        } else try std.testing.expectError(error.StreamTooLarge, reader.next(std.testing.allocator, &source, &cancelled));
    }
}

test "provider framing cancellation during a read prevents publication" {
    const Source = struct {
        reader: std.Io.Reader,
        cancelled: std.atomic.Value(bool) = .init(false),

        fn read_vec(raw: *std.Io.Reader, _: [][]u8) std.Io.Reader.Error!usize {
            const self: *@This() = @fieldParentPtr("reader", raw);
            self.cancelled.store(true, .seq_cst);
            raw.buffer[raw.end] = '\n';
            raw.end += 1;
            return 0;
        }
    };
    var buffer: [12]u8 = undefined;
    @memcpy(buffer[0..8], "data: x\n");
    var source = Source{ .reader = .{ .buffer = &buffer, .seek = 0, .end = 8, .vtable = &.{ .stream = std.Io.Reader.failing.vtable.stream, .readVec = Source.read_vec } } };
    var reader = Reader{ .max_event_bytes = 64 };
    defer reader.deinit(std.testing.allocator);
    try std.testing.expectError(error.Cancelled, reader.next(std.testing.allocator, &source.reader, &source.cancelled));
}

test "provider framing fuzzes chunk-invariant event data" {
    const Probe = struct {
        fn run(_: void, smith: *std.testing.Smith) !void {
            var text: [128]u8 = undefined;
            const len = smith.slice(&text);
            const bytes = text[0..len];
            for (bytes) |*byte| byte.* = 'a' + byte.* % 26;
            const alloc = std.testing.allocator;
            const wire = try std.mem.concat(alloc, u8, &.{ "\xef\xbb\xbfdata:", bytes, "\r\ndata: tail\r\n\r\n" });
            defer alloc.free(wire);
            const expected = try std.mem.concat(alloc, u8, &.{ bytes, "\ntail" });
            defer alloc.free(expected);
            var fixed = std.Io.Reader.fixed(wire);
            var buffer: [32]u8 = undefined;
            var source = fixed.limited(.unlimited, buffer[0 .. 1 + bytes.len % buffer.len]);
            var reader = Reader{ .max_event_bytes = 256 };
            defer reader.deinit(alloc);
            const cancelled = std.atomic.Value(bool).init(false);
            try std.testing.expectEqualStrings(expected, (try reader.next(alloc, &source.interface, &cancelled)).?);
            try std.testing.expectEqual(null, try reader.next(alloc, &source.interface, &cancelled));
        }
    };
    try std.testing.fuzz({}, Probe.run, .{ .corpus = &.{ "", "one", "split every field" } });
}

fn check_allocations(alloc: std.mem.Allocator) !void {
    var fixed = std.Io.Reader.fixed("data: first\ndata: second\n\n");
    var buffer: [3]u8 = undefined;
    var source = fixed.limited(.unlimited, &buffer);
    var reader = Reader{ .max_event_bytes = 128 };
    defer reader.deinit(alloc);
    const cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectEqualStrings("first\nsecond", (try reader.next(alloc, &source.interface, &cancelled)).?);
}

test "provider framing releases allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_allocations, .{});
}

test "provider framing reuses split-line storage for large events" {
    const alloc = std.testing.allocator;
    const text = "x" ** (64 * 1024);
    var fixed = std.Io.Reader.fixed("data: " ++ text ++ "\n\n");
    var buffer: [128]u8 = undefined;
    var source = fixed.limited(.unlimited, &buffer);
    var tracked = std.testing.FailingAllocator.init(alloc, .{});
    var reader = Reader{ .max_event_bytes = 128 * 1024 };
    defer reader.deinit(tracked.allocator());
    const cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectEqualStrings(text, (try reader.next(tracked.allocator(), &source.interface, &cancelled)).?);
    try std.testing.expect(tracked.allocated_bytes - tracked.freed_bytes < 2 * text.len);
}
