const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const CanonicalizeError = error{OutOfMemory};

pub const Stream = enum {
    stdout,
    stderr,
};

/// Receives borrowed foreground output. Returning an error aborts the command.
pub const Callback = *const fn (
    ctx: *anyopaque,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: Stream,
    chunk: []const u8,
) anyerror!void;

/// Maximum bytes added around unchanged stdout/stderr bodies by
/// `formatCommandResult`.
pub const max_foreground_result_envelope_bytes: usize =
    "exit_code=-9223372036854775808\n".len +
    "<stdout>\n".len + "\n</stdout>\n".len +
    "<stderr>\n".len + "\n</stderr>\n".len;

const EscapeState = enum {
    none,
    escape,
    csi,
    osc,
    osc_escape,
};

const TransformKind = enum {
    byte_escape,
    c1_escape,
    escape_byte,
    bare_cr,
};

const TransformEvent = struct {
    visible_offset: usize,
    kind: TransformKind,
    byte: u8,
};

/// Incrementally converts raw command bytes into presentation-safe logical
/// record operations. The caller owns record storage and line identity.
pub const Decoder = struct {
    utf8_pending: [4]u8 = undefined,
    utf8_pending_len: usize = 0,
    pending_cr: bool = false,
    escape_state: EscapeState = .none,
    escape_bytes: [64]u8 = undefined,
    escape_len: usize = 0,
    escape_overflow: bool = false,

    pub fn append(self: *Decoder, raw: []const u8, sink: anytype) !void {
        var index: usize = 0;
        while (index < raw.len) : (index += 1) {
            try self.consumeByte(raw[index], sink);
        }
    }

    pub fn finish(self: *Decoder, sink: anytype) !void {
        self.pending_cr = false;
        try self.flushUtf8(sink, true);
        if (self.escape_state != .none) try self.flushIncompleteEscape(sink);
    }

    /// Returns true when the next callback has no dependency on prior bytes.
    pub fn isIdle(self: *const Decoder) bool {
        return self.utf8_pending_len == 0 and
            !self.pending_cr and
            self.escape_state == .none;
    }

    fn consumeByte(self: *Decoder, byte: u8, sink: anytype) !void {
        if (self.escape_state != .none) {
            if (try self.consumeEscapeByte(byte, sink)) return;
        }

        if (self.pending_cr) {
            self.pending_cr = false;
            if (byte == '\n') {
                try self.flushUtf8(sink, true);
                try sink.finishLine();
                return;
            }
            try sink.replaceLine();
            try emitTransformProvenance(sink, .bare_cr, '\r');
        }

        if (byte == 0x1b) {
            try self.flushUtf8(sink, true);
            try emitTransformProvenance(sink, .escape_byte, byte);
            self.startEscape();
            return;
        }
        if (byte == '\r') {
            try self.flushUtf8(sink, true);
            self.pending_cr = true;
            return;
        }
        if (byte == '\n') {
            try self.flushUtf8(sink, true);
            try sink.finishLine();
            return;
        }
        if (byte >= 0x80) {
            try self.appendUtf8Byte(byte, sink);
            return;
        }

        try self.flushUtf8(sink, true);
        if (byte == '\t' or (byte >= 0x20 and byte < 0x7f)) {
            const bytes = [_]u8{byte};
            try sink.appendText(&bytes);
            return;
        }
        try emitEscapedByte(sink, .byte_escape, byte);
    }

    fn appendUtf8Byte(self: *Decoder, byte: u8, sink: anytype) !void {
        if (self.utf8_pending_len == self.utf8_pending.len) {
            try emitEscapedByte(sink, .byte_escape, self.utf8_pending[0]);
            self.shiftUtf8Pending(1);
        }
        self.utf8_pending[self.utf8_pending_len] = byte;
        self.utf8_pending_len += 1;
        try self.flushUtf8(sink, false);
    }

    fn flushUtf8(self: *Decoder, sink: anytype, final: bool) !void {
        while (self.utf8_pending_len > 0) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(
                self.utf8_pending[0],
            ) catch 1;
            if (sequence_len == 1) {
                try emitEscapedByte(sink, .byte_escape, self.utf8_pending[0]);
                self.shiftUtf8Pending(1);
                continue;
            }
            if (self.utf8_pending_len < sequence_len) {
                if (!final) return;
                try emitEscapedByte(sink, .byte_escape, self.utf8_pending[0]);
                self.shiftUtf8Pending(1);
                continue;
            }

            const sequence = self.utf8_pending[0..sequence_len];
            const scalar = std.unicode.utf8Decode(sequence) catch {
                try emitEscapedByte(sink, .byte_escape, self.utf8_pending[0]);
                self.shiftUtf8Pending(1);
                continue;
            };
            if (scalar >= 0x80 and scalar <= 0x9f) {
                for (sequence) |byte| {
                    try emitTransformProvenance(sink, .c1_escape, byte);
                }
                const value: u8 = @intCast(scalar);
                const digits = "0123456789abcdef";
                const escaped = [_]u8{
                    '\\',               'u',                  '{', '0', '0',
                    digits[value >> 4], digits[value & 0x0f], '}',
                };
                try sink.appendText(&escaped);
            } else {
                try sink.appendText(sequence);
            }
            self.shiftUtf8Pending(sequence_len);
        }
    }

    fn shiftUtf8Pending(self: *Decoder, count: usize) void {
        const remaining = self.utf8_pending_len - count;
        if (remaining > 0) {
            std.mem.copyForwards(
                u8,
                self.utf8_pending[0..remaining],
                self.utf8_pending[count..self.utf8_pending_len],
            );
        }
        self.utf8_pending_len = remaining;
    }

    fn startEscape(self: *Decoder) void {
        self.escape_state = .escape;
        self.escape_len = 0;
        self.escape_overflow = false;
        self.recordEscapeByte(0x1b);
    }

    fn consumeEscapeByte(self: *Decoder, byte: u8, sink: anytype) !bool {
        switch (self.escape_state) {
            .none => unreachable,
            .escape => switch (byte) {
                '[' => {
                    try emitTransformProvenance(sink, .escape_byte, byte);
                    self.recordEscapeByte(byte);
                    self.escape_state = .csi;
                    return true;
                },
                ']' => {
                    try emitTransformProvenance(sink, .escape_byte, byte);
                    self.recordEscapeByte(byte);
                    self.escape_state = .osc;
                    return true;
                },
                else => {
                    if (byte >= 0x40 and byte <= 0x5f) {
                        try emitTransformProvenance(sink, .escape_byte, byte);
                        self.resetEscape();
                        return true;
                    }
                    try self.flushIncompleteEscape(sink);
                    return false;
                },
            },
            .csi => {
                try emitTransformProvenance(sink, .escape_byte, byte);
                self.recordEscapeByte(byte);
                if (byte >= 0x40 and byte <= 0x7e) {
                    self.resetEscape();
                } else if (byte < 0x20 or byte == 0x7f) {
                    try self.flushIncompleteEscape(sink);
                }
                return true;
            },
            .osc => {
                try emitTransformProvenance(sink, .escape_byte, byte);
                self.recordEscapeByte(byte);
                if (byte == 0x07) {
                    self.resetEscape();
                } else if (byte == 0x1b) {
                    self.escape_state = .osc_escape;
                }
                return true;
            },
            .osc_escape => {
                try emitTransformProvenance(sink, .escape_byte, byte);
                self.recordEscapeByte(byte);
                if (byte == '\\') {
                    self.resetEscape();
                } else if (byte != 0x1b) {
                    self.escape_state = .osc;
                }
                return true;
            },
        }
    }

    fn recordEscapeByte(self: *Decoder, byte: u8) void {
        if (self.escape_len < self.escape_bytes.len) {
            self.escape_bytes[self.escape_len] = byte;
            self.escape_len += 1;
        } else {
            self.escape_overflow = true;
        }
    }

    fn flushIncompleteEscape(self: *Decoder, sink: anytype) !void {
        for (self.escape_bytes[0..self.escape_len]) |byte| {
            if (byte < 0x20 or byte == 0x7f) {
                try emitByteEscape(sink, byte);
            } else {
                const bytes = [_]u8{byte};
                try sink.appendText(&bytes);
            }
        }
        if (self.escape_overflow) try sink.appendText("...");
        self.resetEscape();
    }

    fn resetEscape(self: *Decoder) void {
        self.escape_state = .none;
        self.escape_len = 0;
        self.escape_overflow = false;
    }
};

fn emitEscapedByte(sink: anytype, kind: TransformKind, byte: u8) !void {
    try emitTransformProvenance(sink, kind, byte);
    try emitByteEscape(sink, byte);
}

fn emitTransformProvenance(
    sink: anytype,
    kind: TransformKind,
    byte: u8,
) !void {
    const Sink = @TypeOf(sink.*);
    if (comptime @hasDecl(Sink, "recordTransform")) {
        try sink.recordTransform(kind, byte);
    }
}

fn emitByteEscape(sink: anytype, byte: u8) !void {
    const digits = "0123456789abcdef";
    const escaped = [_]u8{
        '\\', 'x', digits[byte >> 4], digits[byte & 0x0f],
    };
    try sink.appendText(&escaped);
}

pub const CanonicalRecord = struct {
    stream: Stream,
    text: std.ArrayList(u8) = .empty,
    transforms: std.ArrayList(TransformEvent) = .empty,
    terminated: bool = false,

    fn deinit(self: *CanonicalRecord, alloc: Allocator) void {
        self.text.deinit(alloc);
        self.transforms.deinit(alloc);
    }
};

pub const CanonicalOutput = struct {
    records: std.ArrayList(CanonicalRecord) = .empty,
    decoders: [2]Decoder = .{ .{}, .{} },
    open_record_indices: [2]?usize = .{ null, null },

    pub fn deinit(self: *CanonicalOutput, alloc: Allocator) void {
        for (self.records.items) |*record| record.deinit(alloc);
        self.records.deinit(alloc);
        self.* = undefined;
    }

    pub fn append(
        self: *CanonicalOutput,
        alloc: Allocator,
        stream: Stream,
        raw: []const u8,
    ) CanonicalizeError!void {
        var sink = CollectorSink{
            .alloc = alloc,
            .output = self,
            .stream = stream,
        };
        // Reserve source ownership before decoding. A callback may contain
        // only a partial UTF-8/escape sequence, but a later callback on the
        // other stream must not overtake its eventual visible record.
        if (raw.len > 0) try sink.beginRecord();
        try self.decoders[streamIndex(stream)].append(raw, &sink);
    }

    pub fn finish(
        self: *CanonicalOutput,
        alloc: Allocator,
    ) CanonicalizeError!void {
        inline for ([_]Stream{ .stdout, .stderr }) |stream| {
            var sink = CollectorSink{
                .alloc = alloc,
                .output = self,
                .stream = stream,
            };
            try self.decoders[streamIndex(stream)].finish(&sink);
            const index = streamIndex(stream);
            if (self.open_record_indices[index]) |record_index| {
                const record = self.records.items[record_index];
                if (record.text.items.len == 0 and !record.terminated) {
                    self.removeRecord(alloc, record_index);
                }
            }
            self.open_record_indices[index] = null;
        }
    }

    fn removeRecord(
        self: *CanonicalOutput,
        alloc: Allocator,
        record_index: usize,
    ) void {
        var removed = self.records.orderedRemove(record_index);
        removed.deinit(alloc);
        for (&self.open_record_indices) |*maybe_index| {
            const index = maybe_index.* orelse continue;
            if (index == record_index) {
                maybe_index.* = null;
            } else if (index > record_index) {
                maybe_index.* = index - 1;
            }
        }
    }
};

const CollectorSink = struct {
    alloc: Allocator,
    output: *CanonicalOutput,
    stream: Stream,

    fn beginRecord(self: *CollectorSink) !void {
        _ = try self.ensureOpenRecord();
    }

    fn appendText(self: *CollectorSink, bytes: []const u8) !void {
        const index = try self.ensureOpenRecord();
        try self.output.records.items[index].text.appendSlice(self.alloc, bytes);
    }

    fn recordTransform(
        self: *CollectorSink,
        kind: TransformKind,
        byte: u8,
    ) !void {
        const index = try self.ensureOpenRecord();
        const record = &self.output.records.items[index];
        try record.transforms.append(self.alloc, .{
            .visible_offset = record.text.items.len,
            .kind = kind,
            .byte = byte,
        });
    }

    fn finishLine(self: *CollectorSink) !void {
        const stream_index = streamIndex(self.stream);
        const index = try self.ensureOpenRecord();
        self.output.records.items[index].terminated = true;
        self.output.open_record_indices[stream_index] = null;
    }

    fn replaceLine(self: *CollectorSink) !void {
        const index = try self.ensureOpenRecord();
        self.output.records.items[index].text.clearRetainingCapacity();
        self.output.records.items[index].transforms.clearRetainingCapacity();
        self.output.records.items[index].terminated = false;
    }

    fn ensureOpenRecord(self: *CollectorSink) !usize {
        const index = streamIndex(self.stream);
        if (self.output.open_record_indices[index]) |record_index| {
            return record_index;
        }
        try self.output.records.append(self.alloc, .{ .stream = self.stream });
        const record_index = self.output.records.items.len - 1;
        self.output.open_record_indices[index] = record_index;
        return record_index;
    }
};

fn streamIndex(stream: Stream) usize {
    return @intFromEnum(stream);
}

pub fn eql(lhs: CanonicalOutput, rhs: CanonicalOutput) bool {
    if (lhs.records.items.len != rhs.records.items.len) return false;
    for (lhs.records.items, rhs.records.items) |left, right| {
        if (left.stream != right.stream or
            !std.mem.eql(u8, left.text.items, right.text.items) or
            !transformEventsEqual(left.transforms.items, right.transforms.items)) return false;
    }
    return true;
}

fn transformEventsEqual(
    lhs: []const TransformEvent,
    rhs: []const TransformEvent,
) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (left.visible_offset != right.visible_offset or
            left.kind != right.kind or
            left.byte != right.byte) return false;
    }
    return true;
}

/// Parses the complete foreground command result grammar and returns its
/// canonical stdout/stderr records. Ambiguous or partial envelopes return
/// null so callers retain ordered replay evidence instead of guessing.
pub fn canonicalizeForegroundResult(
    alloc: Allocator,
    result: []const u8,
) CanonicalizeError!?CanonicalOutput {
    const status_end = std.mem.findScalar(u8, result, '\n') orelse return null;
    if (!validForegroundStatus(result[0..status_end])) return null;

    var remaining = result[status_end + 1 ..];
    var output: CanonicalOutput = .{};
    errdefer output.deinit(alloc);
    if (std.mem.eql(u8, remaining, "(no output)\n")) {
        try output.finish(alloc);
        return output;
    }

    var parsed_any = false;
    for ([_]Stream{ .stdout, .stderr }) |stream| {
        const label = @tagName(stream);
        var open_buf: [16]u8 = undefined;
        const open = std.fmt.bufPrint(&open_buf, "<{s}>\n", .{label}) catch
            unreachable;
        if (!std.mem.startsWith(u8, remaining, open)) continue;

        var close_buf: [20]u8 = undefined;
        const close = std.fmt.bufPrint(&close_buf, "\n</{s}>\n", .{label}) catch
            unreachable;
        const body_and_tail = remaining[open.len..];
        const close_start = std.mem.find(u8, body_and_tail, close) orelse {
            output.deinit(alloc);
            return null;
        };
        try output.append(alloc, stream, body_and_tail[0..close_start]);
        remaining = body_and_tail[close_start + close.len ..];
        parsed_any = true;
    }
    if (!parsed_any or remaining.len != 0) {
        output.deinit(alloc);
        return null;
    }
    try output.finish(alloc);
    return output;
}

pub fn validForegroundStatus(status: []const u8) bool {
    if (std.mem.eql(u8, status, "process finished")) return true;
    for ([_][]const u8{ "exit_code=", "signal=" }) |prefix| {
        if (!std.mem.startsWith(u8, status, prefix)) continue;
        _ = std.fmt.parseInt(i64, status[prefix.len..], 10) catch return false;
        return true;
    }
    return false;
}

fn normalizeForTest(alloc: Allocator, chunks: []const []const u8) !CanonicalOutput {
    var output: CanonicalOutput = .{};
    errdefer output.deinit(alloc);
    for (chunks) |chunk| try output.append(alloc, .stdout, chunk);
    try output.finish(alloc);
    return output;
}

fn expectCanonicalEqual(expected: CanonicalOutput, actual: CanonicalOutput) !void {
    try std.testing.expectEqual(expected.records.items.len, actual.records.items.len);
    for (expected.records.items, actual.records.items) |left, right| {
        try std.testing.expectEqual(left.stream, right.stream);
        try std.testing.expectEqualStrings(left.text.items, right.text.items);
        try std.testing.expect(transformEventsEqual(
            left.transforms.items,
            right.transforms.items,
        ));
    }
}

test "command output normalization is chunk independent" {
    const alloc = std.testing.allocator;
    const input = "progress 1\rprogress 2\rDONE\n\n" ++
        "\x1b[31mred\x1b[0m\tutf8:\xe2\x82\xac invalid:\xff literal:\\x0d";

    var expected = try normalizeForTest(alloc, &.{input});
    defer expected.deinit(alloc);

    for (0..input.len + 1) |split| {
        var actual = try normalizeForTest(alloc, &.{ input[0..split], input[split..] });
        defer actual.deinit(alloc);
        try expectCanonicalEqual(expected, actual);
    }

    try std.testing.expectEqual(@as(usize, 3), expected.records.items.len);
    try std.testing.expectEqualStrings("DONE", expected.records.items[0].text.items);
    try std.testing.expectEqualStrings("", expected.records.items[1].text.items);
    try std.testing.expectEqualStrings(
        "red\tutf8:\xe2\x82\xac invalid:\\xff literal:\\x0d",
        expected.records.items[2].text.items,
    );
}

test "canonical output keeps first-record stream order across callbacks" {
    const alloc = std.testing.allocator;
    var output: CanonicalOutput = .{};
    defer output.deinit(alloc);

    try output.append(alloc, .stdout, "A");
    try output.append(alloc, .stderr, "B\n");
    try output.append(alloc, .stdout, "\n");
    try output.finish(alloc);

    try std.testing.expectEqual(@as(usize, 2), output.records.items.len);
    try std.testing.expectEqual(Stream.stdout, output.records.items[0].stream);
    try std.testing.expectEqualStrings("A", output.records.items[0].text.items);
    try std.testing.expectEqual(Stream.stderr, output.records.items[1].stream);
    try std.testing.expectEqualStrings("B", output.records.items[1].text.items);
}

test "pending decoder bytes reserve cross-stream record order" {
    const alloc = std.testing.allocator;
    for ([_][3][]const u8{
        .{ "\xe2", "\x82\xac\n", "€" },
        .{ "\x1b[", "31mred\n", "red" },
    }) |case| {
        var output: CanonicalOutput = .{};
        defer output.deinit(alloc);
        try output.append(alloc, .stdout, case[0]);
        try output.append(alloc, .stderr, "err\n");
        try output.append(alloc, .stdout, case[1]);
        try output.finish(alloc);

        try std.testing.expectEqual(@as(usize, 2), output.records.items.len);
        try std.testing.expectEqual(Stream.stdout, output.records.items[0].stream);
        try std.testing.expectEqualStrings(case[2], output.records.items[0].text.items);
        try std.testing.expectEqual(Stream.stderr, output.records.items[1].stream);
        try std.testing.expectEqualStrings("err", output.records.items[1].text.items);
    }
}

test "unterminated ansi-only callback does not create a blank record" {
    const alloc = std.testing.allocator;
    var output: CanonicalOutput = .{};
    defer output.deinit(alloc);
    try output.append(alloc, .stdout, "\x1b[31m");
    try output.finish(alloc);
    try std.testing.expectEqual(@as(usize, 0), output.records.items.len);
}

test "foreground result extraction is exact and rejects delimiter collisions" {
    const alloc = std.testing.allocator;

    var live: CanonicalOutput = .{};
    defer live.deinit(alloc);
    try live.append(alloc, .stdout, "one\n");
    try live.finish(alloc);

    var extracted = (try canonicalizeForegroundResult(
        alloc,
        "exit_code=0\n<stdout>\none\n</stdout>\n",
    )).?;
    defer extracted.deinit(alloc);
    try std.testing.expect(eql(live, extracted));

    var whitespace = (try canonicalizeForegroundResult(
        alloc,
        "exit_code=0\n<stdout>\n one \n</stdout>\n",
    )).?;
    defer whitespace.deinit(alloc);
    try std.testing.expect(!eql(live, whitespace));

    try std.testing.expect((try canonicalizeForegroundResult(
        alloc,
        "exit_code=0\n<stdout>\nliteral\n</stdout>\ntail\n</stdout>\n",
    )) == null);
    try std.testing.expect((try canonicalizeForegroundResult(
        alloc,
        "timeout=true\ncleanup_guarantee=best_effort\n",
    )) == null);
}

test "canonical equality distinguishes transforms from literal projections" {
    const alloc = std.testing.allocator;
    const Case = struct {
        raw: []const u8,
        projected: []const u8,
    };
    for ([_]Case{
        .{ .raw = "\x00\n", .projected = "\\x00\n" },
        .{ .raw = "\xff\n", .projected = "\\xff\n" },
        .{ .raw = "\xc2\x80\n", .projected = "\\u{0080}\n" },
        .{ .raw = "\x1b[31mred\x1b[0m\n", .projected = "red\n" },
        .{ .raw = "old\rnew\n", .projected = "new\n" },
    }) |case| {
        var raw: CanonicalOutput = .{};
        defer raw.deinit(alloc);
        try raw.append(alloc, .stdout, case.raw);
        try raw.finish(alloc);

        var preserved: CanonicalOutput = .{};
        defer preserved.deinit(alloc);
        try preserved.append(alloc, .stdout, case.raw);
        try preserved.finish(alloc);
        try std.testing.expect(eql(raw, preserved));

        var projected: CanonicalOutput = .{};
        defer projected.deinit(alloc);
        try projected.append(alloc, .stdout, case.projected);
        try projected.finish(alloc);
        try std.testing.expect(!eql(raw, projected));
    }

    var literal_live: CanonicalOutput = .{};
    defer literal_live.deinit(alloc);
    try literal_live.append(alloc, .stdout, "\\x00\n");
    try literal_live.finish(alloc);
    var literal_result: CanonicalOutput = .{};
    defer literal_result.deinit(alloc);
    try literal_result.append(alloc, .stdout, "\\x00");
    try literal_result.finish(alloc);
    try std.testing.expect(eql(literal_live, literal_result));
}

fn fuzzCommandOutputContent(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var input_buffer: [4096]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];
    const split = input.len / 2;
    var output: CanonicalOutput = .{};
    defer output.deinit(alloc);
    try output.append(alloc, .stdout, input[0..split]);
    try output.append(alloc, .stdout, input[split..]);
    try output.finish(alloc);

    if (try canonicalizeForegroundResult(alloc, input)) |parsed_value| {
        var parsed = parsed_value;
        parsed.deinit(alloc);
    }
}

test "fuzz command output content" {
    try std.testing.fuzz({}, fuzzCommandOutputContent, .{
        .corpus = &.{
            "progress\roverwrite\n",
            "\x1b[31mred\x1b[0m\n",
            "exit_code=0\n<stdout>\none\n</stdout>\n",
            "\xff\x00\xe2\x82",
        },
    });
}
