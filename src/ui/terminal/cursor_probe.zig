const std = @import("std");

pub const Position = struct {
    row: u16,
    col: u16,
};

pub const ResponseParseError = error{
    CursorPositionUnavailable,
};

pub const Protocol = enum {
    private,
    ansi_tagged,
};

// A resize probe emits adjacent reports at columns 1 and 2. A single
// CPR-shaped input sequence is forwarded; only the matching pair is terminal
// protocol traffic.
pub const first_tag_column: u16 = 1;
pub const confirmation_tag_column: u16 = 2;
const max_response_bytes = 16;
const max_candidate_bytes = 64;
const max_deferred_bytes = max_response_bytes + max_candidate_bytes;
const max_forward_bytes = max_deferred_bytes + 1;
pub const response_idle_timeout_ms: i64 = 100;

pub const ForwardBytes = struct {
    storage: [max_forward_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const ForwardBytes) []const u8 {
        return self.storage[0..self.len];
    }
};

pub const FeedResult = union(enum) {
    pending,
    forward: ForwardBytes,
    position: Position,
    late_response,
};

pub const PollResult = enum {
    none,
    probe_timed_out,
    late_window_expired,
};

const Mode = enum {
    idle,
    waiting,
    discarding_late,
    waiting_for_paste_end,
    discarding_late_for_paste_end,
};

const CandidateStatus = union(enum) {
    prefix,
    complete: Position,
    invalid,
};

pub const Parser = struct {
    mode: Mode = .idle,
    protocol: Protocol = .private,
    deadline_ms: i64 = 0,
    candidate: [max_candidate_bytes]u8 = undefined,
    candidate_len: u8 = 0,
    pending_response: [max_response_bytes]u8 = undefined,
    pending_response_len: u8 = 0,
    pending_position: ?Position = null,
    deferred: [max_deferred_bytes]u8 = undefined,
    deferred_start: u8 = 0,
    deferred_len: u8 = 0,
    deferred_input_in_flight: bool = false,

    pub fn begin(self: *Parser, protocol: Protocol, deadline_ms: i64) !void {
        if (!self.canBegin()) return error.CursorProbeBusy;
        self.mode = .waiting;
        self.protocol = protocol;
        self.deadline_ms = deadline_ms;
        self.candidate_len = 0;
        self.pending_response_len = 0;
        self.pending_position = null;
    }

    pub fn cancel(self: *Parser) void {
        self.deferProbeBytes();
        self.mode = .idle;
        self.deadline_ms = 0;
    }

    pub fn canBegin(self: *const Parser) bool {
        return self.mode == .idle and
            self.deferred_start == self.deferred_len and
            !self.deferred_input_in_flight;
    }

    pub fn interceptsInput(self: *const Parser) bool {
        return self.mode != .idle;
    }

    pub fn hasPendingInput(self: *const Parser) bool {
        return self.candidate_len > 0 or
            self.pending_response_len > 0 or
            self.deferred_start < self.deferred_len or
            self.deferred_input_in_flight;
    }

    pub fn noteInputActivity(self: *Parser, now_ms: i64) void {
        switch (self.mode) {
            .waiting, .discarding_late => {
                self.deadline_ms = addMillis(now_ms, response_idle_timeout_ms);
            },
            .idle, .waiting_for_paste_end, .discarding_late_for_paste_end => {},
        }
    }

    pub fn suspendForPaste(self: *Parser) bool {
        const interrupted_measurement = switch (self.mode) {
            .idle, .waiting_for_paste_end, .discarding_late_for_paste_end => return false,
            .waiting => blk: {
                self.mode = .waiting_for_paste_end;
                break :blk true;
            },
            .discarding_late => blk: {
                self.mode = .discarding_late_for_paste_end;
                break :blk false;
            },
        };

        self.deadline_ms = 0;
        return interrupted_measurement;
    }

    pub fn resumeAfterPaste(self: *Parser, now_ms: i64) bool {
        const resumed_measurement = switch (self.mode) {
            .waiting_for_paste_end => blk: {
                self.mode = .waiting;
                break :blk true;
            },
            .discarding_late_for_paste_end => blk: {
                self.mode = .discarding_late;
                break :blk false;
            },
            .idle, .waiting, .discarding_late => return false,
        };
        self.deadline_ms = addMillis(now_ms, response_idle_timeout_ms);
        return resumed_measurement;
    }

    pub fn poll(self: *Parser, now_ms: i64) PollResult {
        if (self.mode == .idle or
            self.mode == .waiting_for_paste_end or
            self.mode == .discarding_late_for_paste_end)
        {
            return .none;
        }
        if (now_ms < self.deadline_ms) return .none;

        return switch (self.mode) {
            .idle, .waiting_for_paste_end, .discarding_late_for_paste_end => unreachable,
            .waiting => blk: {
                self.deferProbeBytes();
                self.mode = .discarding_late;
                self.deadline_ms = addMillis(now_ms, response_idle_timeout_ms);
                break :blk .probe_timed_out;
            },
            .discarding_late => blk: {
                self.deferProbeBytes();
                self.mode = .idle;
                self.deadline_ms = 0;
                break :blk .late_window_expired;
            },
        };
    }

    pub fn expire(self: *Parser, now_ms: i64) bool {
        if (self.mode != .waiting) return false;
        self.deferProbeBytes();
        self.mode = .discarding_late;
        self.deadline_ms = addMillis(now_ms, response_idle_timeout_ms);
        return true;
    }

    pub fn feed(self: *Parser, byte: u8) FeedResult {
        if (!self.interceptsInput()) return forwardByte(byte);
        return switch (self.protocol) {
            .private => self.feedPrivate(byte),
            .ansi_tagged => self.feedAnsiTagged(byte),
        };
    }

    pub fn takeDeferredByte(self: *Parser) ?u8 {
        std.debug.assert(!self.deferred_input_in_flight);
        if (self.deferred_start >= self.deferred_len) return null;
        const byte = self.deferred[self.deferred_start];
        self.deferred_start += 1;
        if (self.deferred_start == self.deferred_len) {
            self.deferred_start = 0;
            self.deferred_len = 0;
        }
        self.deferred_input_in_flight = true;
        return byte;
    }

    pub fn consumeDeferredInputDispatch(self: *Parser) bool {
        const in_flight = self.deferred_input_in_flight;
        self.deferred_input_in_flight = false;
        return in_flight;
    }

    fn feedPrivate(self: *Parser, byte: u8) FeedResult {
        if (self.candidate_len == self.candidate.len) {
            return self.forwardOverflow(byte);
        }
        self.candidate[self.candidate_len] = byte;
        self.candidate_len += 1;

        return switch (classifyPrivateCandidate(self.candidate[0..self.candidate_len])) {
            .prefix => .pending,
            .complete => |position| self.handlePosition(position),
            .invalid => self.forwardInvalidCandidate(.private),
        };
    }

    fn feedAnsiTagged(self: *Parser, byte: u8) FeedResult {
        if (self.candidate_len == self.candidate.len) {
            return self.forwardOverflow(byte);
        }
        self.candidate[self.candidate_len] = byte;
        self.candidate_len += 1;

        return switch (classifyAnsiCandidate(self.candidate[0..self.candidate_len])) {
            .prefix => .pending,
            .complete => |position| self.handlePosition(position),
            .invalid => self.forwardInvalidCandidate(.ansi_tagged),
        };
    }

    fn handlePosition(self: *Parser, position: Position) FeedResult {
        const pending = self.pending_position;
        if (pending) |first| {
            if (position.row == first.row and position.col == confirmation_tag_column) {
                self.candidate_len = 0;
                return self.complete(first);
            }

            var forwarded = ForwardBytes{};
            @memcpy(
                forwarded.storage[0..self.pending_response_len],
                self.pending_response[0..self.pending_response_len],
            );
            forwarded.len = self.pending_response_len;
            self.pending_response_len = 0;
            self.pending_position = null;

            if (position.col == first_tag_column) {
                self.storePendingPosition(position);
            } else {
                @memcpy(
                    forwarded.storage[forwarded.len..][0..self.candidate_len],
                    self.candidate[0..self.candidate_len],
                );
                forwarded.len += self.candidate_len;
                self.candidate_len = 0;
            }
            return .{ .forward = forwarded };
        }

        if (position.col != first_tag_column) {
            return self.forwardInvalidCandidate(self.protocol);
        }
        self.storePendingPosition(position);
        return .pending;
    }

    fn storePendingPosition(self: *Parser, position: Position) void {
        std.debug.assert(self.candidate_len <= self.pending_response.len);
        @memcpy(
            self.pending_response[0..self.candidate_len],
            self.candidate[0..self.candidate_len],
        );
        self.pending_response_len = self.candidate_len;
        self.pending_position = position;
        self.candidate_len = 0;
    }

    fn complete(self: *Parser, position: Position) FeedResult {
        const prior_mode = self.mode;
        self.candidate_len = 0;
        self.pending_response_len = 0;
        self.pending_position = null;
        self.mode = .idle;
        self.deadline_ms = 0;
        return if (prior_mode == .waiting or prior_mode == .waiting_for_paste_end)
            .{ .position = position }
        else
            .late_response;
    }

    fn forwardInvalidCandidate(self: *Parser, protocol: Protocol) FeedResult {
        const bytes = self.candidate[0..self.candidate_len];
        const suffix_start = prefixSuffixStart(bytes, protocol);
        const forward_len = suffix_start orelse bytes.len;

        var forwarded = ForwardBytes{};
        if (self.pending_response_len > 0) {
            @memcpy(
                forwarded.storage[0..self.pending_response_len],
                self.pending_response[0..self.pending_response_len],
            );
            forwarded.len = self.pending_response_len;
            self.pending_response_len = 0;
            self.pending_position = null;
        }
        @memcpy(
            forwarded.storage[forwarded.len..][0..forward_len],
            bytes[0..forward_len],
        );
        forwarded.len += @intCast(forward_len);

        if (suffix_start) |start| {
            const retained_len = bytes.len - start;
            @memmove(
                self.candidate[0..retained_len],
                bytes[start..],
            );
            self.candidate_len = @intCast(retained_len);
        } else {
            self.candidate_len = 0;
        }

        return .{ .forward = forwarded };
    }

    fn forwardOverflow(self: *Parser, byte: u8) FeedResult {
        var forwarded = ForwardBytes{};
        if (self.pending_response_len > 0) {
            @memcpy(
                forwarded.storage[0..self.pending_response_len],
                self.pending_response[0..self.pending_response_len],
            );
            forwarded.len = self.pending_response_len;
            self.pending_response_len = 0;
            self.pending_position = null;
        }
        @memcpy(
            forwarded.storage[forwarded.len..][0..self.candidate_len],
            self.candidate[0..self.candidate_len],
        );
        forwarded.len += self.candidate_len;
        forwarded.storage[forwarded.len] = byte;
        forwarded.len += 1;
        self.candidate_len = 0;
        return .{ .forward = forwarded };
    }

    fn deferProbeBytes(self: *Parser) void {
        if (self.pending_response_len == 0 and self.candidate_len == 0) return;
        std.debug.assert(self.deferred_start == self.deferred_len);
        if (self.pending_response_len > 0) {
            @memcpy(
                self.deferred[0..self.pending_response_len],
                self.pending_response[0..self.pending_response_len],
            );
        }
        @memcpy(
            self.deferred[self.pending_response_len..][0..self.candidate_len],
            self.candidate[0..self.candidate_len],
        );
        self.deferred_start = 0;
        self.deferred_len = self.pending_response_len + self.candidate_len;
        self.pending_response_len = 0;
        self.pending_position = null;
        self.candidate_len = 0;
    }
};

pub fn queryBytes(protocol: Protocol) []const u8 {
    return switch (protocol) {
        .private => "\x1b[?2026h\x1b7\x1b[1G\x1b[?6n\x1b[2G\x1b[?6n\x1b8\x1b[?2026l",
        .ansi_tagged => "\x1b[?2026h\x1b7\x1b[1G\x1b[6n\x1b[2G\x1b[6n\x1b8\x1b[?2026l",
    };
}

pub fn findPositionResponse(bytes: []const u8) ?Position {
    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 1) {
        if (bytes[i] != 0x1b) continue;
        if (i + 2 >= bytes.len or bytes[i + 1] != '[') continue;

        var row_end = i + 2;
        while (row_end < bytes.len and std.ascii.isDigit(bytes[row_end])) : (row_end += 1) {}
        if (row_end == i + 2 or row_end >= bytes.len or bytes[row_end] != ';') continue;

        var col_end = row_end + 1;
        while (col_end < bytes.len and std.ascii.isDigit(bytes[col_end])) : (col_end += 1) {}
        if (col_end == row_end + 1 or col_end >= bytes.len or bytes[col_end] != 'R') continue;

        const row = std.fmt.parseUnsigned(u16, bytes[i + 2 .. row_end], 10) catch continue;
        const col = std.fmt.parseUnsigned(u16, bytes[row_end + 1 .. col_end], 10) catch continue;
        if (row == 0 or col == 0) continue;

        return .{ .row = row, .col = col };
    }

    return null;
}

pub fn parsePositionResponse(bytes: []const u8) ResponseParseError!Position {
    return findPositionResponse(bytes) orelse error.CursorPositionUnavailable;
}

fn addMillis(now_ms: i64, duration_ms: i64) i64 {
    return std.math.add(i64, now_ms, duration_ms) catch std.math.maxInt(i64);
}

fn forwardByte(byte: u8) FeedResult {
    var forwarded = ForwardBytes{};
    forwarded.storage[0] = byte;
    forwarded.len = 1;
    return .{ .forward = forwarded };
}

fn prefixSuffixStart(bytes: []const u8, protocol: Protocol) ?usize {
    if (bytes.len < 2) return null;
    var start: usize = 1;
    while (start < bytes.len) : (start += 1) {
        const is_prefix = switch (protocol) {
            .private => classifyPrivateCandidate(bytes[start..]) == .prefix,
            .ansi_tagged => classifyAnsiCandidate(bytes[start..]) == .prefix,
        };
        if (is_prefix) return start;
    }
    return null;
}

fn csiParameterStart(bytes: []const u8) ?usize {
    if (bytes.len == 0) return 0;
    return switch (bytes[0]) {
        0x1b => blk: {
            if (bytes.len == 1) return null;
            if (bytes[1] != '[') return std.math.maxInt(usize);
            break :blk 2;
        },
        0x9b => 1,
        else => std.math.maxInt(usize),
    };
}

fn classifyPrivateCandidate(bytes: []const u8) CandidateStatus {
    if (bytes.len == 0) return .prefix;

    var index = csiParameterStart(bytes) orelse return .prefix;
    if (index == std.math.maxInt(usize)) return .invalid;

    if (index == bytes.len) return .prefix;
    if (bytes[index] != '?') return .invalid;
    index += 1;

    const row_start = index;
    while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) {}
    const row_len = index - row_start;
    if (row_len > 5) return .invalid;
    if (index == bytes.len) return .prefix;
    if (row_len == 0 or bytes[index] != ';') return .invalid;
    index += 1;

    const col_start = index;
    while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) {}
    const col_len = index - col_start;
    if (col_len > 5) return .invalid;
    if (index == bytes.len) return .prefix;
    if (col_len == 0 or bytes[index] != 'R' or index + 1 != bytes.len) return .invalid;

    const row = std.fmt.parseUnsigned(u16, bytes[row_start .. row_start + row_len], 10) catch
        return .invalid;
    const col = std.fmt.parseUnsigned(u16, bytes[col_start .. col_start + col_len], 10) catch
        return .invalid;
    if (row == 0 or col == 0) return .invalid;
    return .{ .complete = .{ .row = row, .col = col } };
}

fn classifyAnsiCandidate(bytes: []const u8) CandidateStatus {
    if (bytes.len == 0) return .prefix;

    var index = csiParameterStart(bytes) orelse return .prefix;
    if (index == std.math.maxInt(usize)) return .invalid;
    if (index == bytes.len) return .prefix;

    const row_start = index;
    while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) {}
    const row_len = index - row_start;
    if (row_len > 5) return .invalid;
    if (index == bytes.len) return .prefix;
    if (row_len == 0 or bytes[index] != ';') return .invalid;
    index += 1;

    const col_start = index;
    while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) {}
    const col_len = index - col_start;
    if (col_len > 5) return .invalid;
    if (index == bytes.len) return .prefix;
    if (col_len == 0 or bytes[index] != 'R' or index + 1 != bytes.len) return .invalid;

    const row = std.fmt.parseUnsigned(u16, bytes[row_start .. row_start + row_len], 10) catch
        return .invalid;
    const col = std.fmt.parseUnsigned(u16, bytes[col_start .. col_start + col_len], 10) catch
        return .invalid;
    if (row == 0 or col == 0) return .invalid;
    return .{ .complete = .{ .row = row, .col = col } };
}

fn appendForwarded(
    result: FeedResult,
    forwarded: *std.ArrayList(u8),
) !?Position {
    return switch (result) {
        .pending => null,
        .position => |position| position,
        .late_response => null,
        .forward => |bytes| blk: {
            try forwarded.appendSlice(std.testing.allocator, bytes.slice());
            break :blk null;
        },
    };
}

test "private cursor probe preserves arbitrary backlog before the response" {
    const backlog_sizes = [_]usize{ 255, 256, 257, 5_000_000 };

    for (backlog_sizes) |backlog_size| {
        var probe = Parser{};
        try probe.begin(.private, 100);

        var forwarded: std.ArrayList(u8) = .empty;
        defer forwarded.deinit(std.testing.allocator);

        var i: usize = 0;
        while (i < backlog_size) : (i += 1) {
            try std.testing.expectEqual(
                @as(?Position, null),
                try appendForwarded(probe.feed('x'), &forwarded),
            );
        }
        for ("\x1b[?12;1R\x1b[?12;2R") |byte| {
            if (try appendForwarded(probe.feed(byte), &forwarded)) |position| {
                try std.testing.expectEqual(Position{ .row = 12, .col = 1 }, position);
            }
        }

        try std.testing.expectEqual(backlog_size, forwarded.items.len);
        for (forwarded.items) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
        try std.testing.expect(probe.canBegin());
    }
}

test "private cursor probe survives a response split across reads" {
    var probe = Parser{};
    try probe.begin(.private, 100);

    var forwarded: std.ArrayList(u8) = .empty;
    defer forwarded.deinit(std.testing.allocator);

    for ("\x1b[?7;") |byte| {
        try std.testing.expectEqual(
            @as(?Position, null),
            try appendForwarded(probe.feed(byte), &forwarded),
        );
    }
    try std.testing.expectEqual(@as(usize, 0), forwarded.items.len);

    var position: ?Position = null;
    for ("1R") |byte| {
        position = try appendForwarded(probe.feed(byte), &forwarded) orelse position;
    }
    try std.testing.expect(probe.hasPendingInput());
    for ("\x1b[?7;2R") |byte| {
        position = try appendForwarded(probe.feed(byte), &forwarded) orelse position;
    }
    try std.testing.expectEqual(@as(?Position, .{ .row = 7, .col = 1 }), position);
    try std.testing.expectEqual(@as(usize, 0), forwarded.items.len);
    try std.testing.expect(!probe.hasPendingInput());
}

test "private cursor probe forwards modified F3 and consumes only the private report" {
    var probe = Parser{};
    try probe.begin(.private, 100);

    var forwarded: std.ArrayList(u8) = .empty;
    defer forwarded.deinit(std.testing.allocator);

    for ("\x1b[1;2R") |byte| {
        _ = try appendForwarded(probe.feed(byte), &forwarded);
    }
    try std.testing.expectEqualStrings("\x1b[1;2R", forwarded.items);

    var position: ?Position = null;
    for ("\x1b[?5;1R\x1b[?5;2R") |byte| {
        position = try appendForwarded(probe.feed(byte), &forwarded) orelse position;
    }
    try std.testing.expectEqual(@as(?Position, .{ .row = 5, .col = 1 }), position);
}

test "private cursor probe timeout replays a partial candidate and discards a late response" {
    var probe = Parser{};
    try probe.begin(.private, 100);

    for ("\x1b[?12") |byte| {
        try std.testing.expectEqual(FeedResult.pending, probe.feed(byte));
    }
    try std.testing.expect(probe.hasPendingInput());

    try std.testing.expectEqual(PollResult.probe_timed_out, probe.poll(100));

    var replay: [128]u8 = undefined;
    var replay_len: usize = 0;
    while (probe.takeDeferredByte()) |byte| {
        try std.testing.expect(probe.hasPendingInput());
        try std.testing.expect(probe.consumeDeferredInputDispatch());
        try std.testing.expect(!probe.consumeDeferredInputDispatch());
        replay[replay_len] = byte;
        replay_len += 1;
    }
    try std.testing.expectEqualStrings("\x1b[?12", replay[0..replay_len]);
    try std.testing.expect(!probe.canBegin());
    try std.testing.expect(!probe.hasPendingInput());

    var saw_late_response = false;
    for ("\x1b[?8;1R\x1b[?8;2R") |byte| {
        switch (probe.feed(byte)) {
            .late_response => saw_late_response = true,
            .pending => {},
            .forward, .position => return error.UnexpectedProbeResult,
        }
    }
    try std.testing.expect(saw_late_response);
    try std.testing.expect(probe.canBegin());
}

test "private cursor probe supports consecutive measurements" {
    var probe = Parser{};

    try probe.begin(.private, 100);
    for ("\x1b[?2;1R\x1b[?2;2R") |byte| {
        const result = probe.feed(byte);
        if (result == .position) {
            try std.testing.expectEqual(FeedResult{ .position = .{ .row = 2, .col = 1 } }, result);
        }
    }

    try probe.begin(.private, 200);
    for ("\x9b?4;1R\x9b?4;2R") |byte| {
        const result = probe.feed(byte);
        if (result == .position) {
            try std.testing.expectEqual(FeedResult{ .position = .{ .row = 4, .col = 1 } }, result);
        }
    }
}

test "tagged ANSI cursor probe forwards modified F3 before the response" {
    var probe = Parser{};
    try probe.begin(.ansi_tagged, 100);

    var forwarded: std.ArrayList(u8) = .empty;
    defer forwarded.deinit(std.testing.allocator);

    for ("\x1b[1;2R") |byte| {
        _ = try appendForwarded(probe.feed(byte), &forwarded);
    }
    try std.testing.expectEqualStrings("\x1b[1;2R", forwarded.items);

    var position: ?Position = null;
    for ("\x1b[12;1R\x1b[12;2R") |byte| {
        position = try appendForwarded(probe.feed(byte), &forwarded) orelse position;
    }
    try std.testing.expectEqual(@as(?Position, .{ .row = 12, .col = 1 }), position);
    try std.testing.expectEqualStrings("\x1b[1;2R", forwarded.items);
}

test "tagged ANSI cursor probe forwards every legacy F3 modifier parameter" {
    var modifier: u8 = 2;
    while (modifier <= 64) : (modifier += 1) {
        var probe = Parser{};
        try probe.begin(.ansi_tagged, 100);

        var sequence_buf: [16]u8 = undefined;
        const sequence = try std.mem.print(&sequence_buf, "\x1b[1;{d}R", .{modifier});
        var forwarded: std.ArrayList(u8) = .empty;
        defer forwarded.deinit(std.testing.allocator);

        for (sequence) |byte| {
            _ = try appendForwarded(probe.feed(byte), &forwarded);
        }
        try std.testing.expectEqualStrings(sequence, forwarded.items);
    }
}

test "tagged ANSI cursor probe forwards the modified F3 three and four pair" {
    var probe = Parser{};
    try probe.begin(.ansi_tagged, 100);

    var forwarded: std.ArrayList(u8) = .empty;
    defer forwarded.deinit(std.testing.allocator);
    for ("\x1b[1;3R\x1b[1;4R") |byte| {
        _ = try appendForwarded(probe.feed(byte), &forwarded);
    }

    try std.testing.expectEqualStrings("\x1b[1;3R\x1b[1;4R", forwarded.items);
    var position: ?Position = null;
    for ("\x1b[12;1R\x1b[12;2R") |byte| {
        position = try appendForwarded(probe.feed(byte), &forwarded) orelse position;
    }
    try std.testing.expectEqual(@as(?Position, .{ .row = 12, .col = 1 }), position);
}

test "tagged ANSI cursor probe preserves CPR-shaped input after the terminal response" {
    var probe = Parser{};
    try probe.begin(.ansi_tagged, 100);

    var forwarded: std.ArrayList(u8) = .empty;
    defer forwarded.deinit(std.testing.allocator);

    var position: ?Position = null;
    for ("\x1b[12;1R\x1b[12;2R\x1b[1;2R") |byte| {
        position = try appendForwarded(probe.feed(byte), &forwarded) orelse position;
    }

    try std.testing.expectEqual(@as(?Position, .{ .row = 12, .col = 1 }), position);
    try std.testing.expectEqualStrings("\x1b[1;2R", forwarded.items);
}

test "tagged ANSI cursor probe forwards untagged cursor reports in order" {
    var probe = Parser{};
    try probe.begin(.ansi_tagged, 100);

    var forwarded: std.ArrayList(u8) = .empty;
    defer forwarded.deinit(std.testing.allocator);

    for ("\x1b[1;2Rx") |byte| {
        _ = try appendForwarded(probe.feed(byte), &forwarded);
    }
    try std.testing.expectEqualStrings("\x1b[1;2Rx", forwarded.items);

    var position: ?Position = null;
    for ("\x1b[7;1R\x1b[7;2R") |byte| {
        position = try appendForwarded(probe.feed(byte), &forwarded) orelse position;
    }
    try std.testing.expectEqual(@as(?Position, .{ .row = 7, .col = 1 }), position);
    try std.testing.expectEqualStrings("\x1b[1;2Rx", forwarded.items);
}

test "tagged ANSI cursor probe preserves CPR-shaped paste before the terminal response pair" {
    var probe = Parser{};
    try probe.begin(.ansi_tagged, 100);

    try std.testing.expect(probe.suspendForPaste());
    try std.testing.expect(probe.interceptsInput());
    try std.testing.expectEqual(PollResult.none, probe.poll(1_000));

    var forwarded: std.ArrayList(u8) = .empty;
    defer forwarded.deinit(std.testing.allocator);
    for ("\x1b[1;1R") |byte| {
        _ = try appendForwarded(probe.feed(byte), &forwarded);
    }
    try std.testing.expectEqual(@as(usize, 0), forwarded.items.len);

    var position: ?Position = null;
    for ("x\x1b[12;1R\x1b[12;2R") |byte| {
        position = try appendForwarded(probe.feed(byte), &forwarded) orelse position;
    }
    try std.testing.expectEqual(@as(?Position, .{ .row = 12, .col = 1 }), position);
    try std.testing.expectEqualStrings("\x1b[1;1Rx", forwarded.items);
    try std.testing.expect(probe.canBegin());
}

test "tagged ANSI late-response window suspends for paste and still discards the reply" {
    var probe = Parser{};
    try probe.begin(.ansi_tagged, 100);
    try std.testing.expectEqual(PollResult.probe_timed_out, probe.poll(100));

    try std.testing.expect(!probe.suspendForPaste());
    try std.testing.expect(probe.interceptsInput());
    try std.testing.expectEqual(PollResult.none, probe.poll(1_000));

    var saw_late_response = false;
    for ("\x1b[12;1R\x1b[12;2R") |byte| {
        switch (probe.feed(byte)) {
            .late_response => saw_late_response = true,
            .pending => {},
            .forward, .position => return error.UnexpectedProbeResult,
        }
    }
    try std.testing.expect(saw_late_response);
    try std.testing.expect(probe.canBegin());
}

test "tagged ANSI query synchronizes transient cursor moves" {
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b7\x1b[1G\x1b[6n\x1b[2G\x1b[6n\x1b8\x1b[?2026l",
        queryBytes(.ansi_tagged),
    );
}

test "private query synchronizes transient cursor moves" {
    try std.testing.expectEqualStrings(
        "\x1b[?2026h\x1b7\x1b[1G\x1b[?6n\x1b[2G\x1b[?6n\x1b8\x1b[?2026l",
        queryBytes(.private),
    );
}

test "one-shot cursor response parser finds a response with leading and trailing bytes" {
    const position = try parsePositionResponse("noise\x1b[42;7Rtail");

    try std.testing.expectEqual(Position{ .row = 42, .col = 7 }, position);
}

test "one-shot cursor response parser rejects invalid rows and columns" {
    const invalid = [_][]const u8{
        "",
        "\x1b[0;1R",
        "\x1b[1;0R",
        "\x1b[;1R",
        "\x1b[1;R",
        "\x1b[1;1",
        "\x1b[999999;1R",
        "\x1b[1;999999R",
        "\x9b1;1R",
    };

    for (invalid) |sample| {
        try std.testing.expect(findPositionResponse(sample) == null);
        try std.testing.expectError(error.CursorPositionUnavailable, parsePositionResponse(sample));
    }
}

test "cursor probe timeout measures input silence rather than total backlog time" {
    var probe = Parser{};
    try probe.begin(.private, 100);

    probe.noteInputActivity(90);
    try std.testing.expectEqual(PollResult.none, probe.poll(189));
    try std.testing.expectEqual(PollResult.probe_timed_out, probe.poll(190));
}
