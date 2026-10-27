//! Follows the newest tool call's arguments as the model streams them and
//! turns them into display previews. A single pass decodes only the string
//! fields the preview shows (command, path, content, query, worker task),
//! so the cost per delta is the delta's own bytes: nothing is reparsed and
//! the body is kept as a bounded tail.
const std = @import("std");
const preview_contract = @import("../../shared/tool_input_preview.zig");

const Allocator = std.mem.Allocator;
const Preview = preview_contract.Preview;
const BodyKind = preview_contract.BodyKind;

/// Which argument fields a tool's preview shows.
pub const Fields = struct {
    subject: ?[]const u8 = null,
    /// Body fields in the order the preview joins them. An edit's two fields
    /// mark their lines `-` and `+`.
    body: []const []const u8 = &.{},
    markers: []const u8 = "",
    kind: BodyKind = .text,
};

/// The preview fields of a tool, or null when its arguments say nothing a
/// person needs to watch arrive.
pub fn fieldsFor(tool_name: []const u8) ?Fields {
    const table = [_]struct { []const u8, Fields }{
        .{ "shell", .{ .body = &.{ "command", "chars" }, .kind = .command } },
        .{ "run_command", .{ .body = &.{"command"}, .kind = .command } },
        .{ "write_file", .{ .subject = "path", .body = &.{"content"}, .kind = .content } },
        .{ "edit_file", .{ .subject = "path", .body = &.{ "old_string", "new_string" }, .markers = "-+", .kind = .diff } },
        .{ "web_search", .{ .subject = "query" } },
        .{ "web_fetch", .{ .subject = "url" } },
        .{ "fleet", .{ .subject = "label", .body = &.{"message"} } },
        .{ "jobs", .{ .subject = "id", .body = &.{"text"} } },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], tool_name)) return entry[1];
    }
    return null;
}

/// Incremental reader of one JSON object's top-level string fields. It
/// tolerates a prefix that stops anywhere, including inside an escape, and
/// skips every value it is not asked for.
pub const Extractor = struct {
    state: State = .before_object,
    key_buf: [32]u8 = undefined,
    key_len: usize = 0,
    key_overflow: bool = false,
    /// The watched field the current string value belongs to.
    field: ?usize = null,
    depth: usize = 0,
    skip_string: bool = false,
    skip_escape: bool = false,
    escape: Escape = .none,
    hex: u16 = 0,
    hex_digits: u3 = 0,
    high_surrogate: ?u16 = null,

    const State = enum { before_object, expect_key, in_key, key_escape, after_key, before_value, in_string, skip_value, done };
    const Escape = enum { none, backslash, unicode };

    /// Feeds the next argument bytes. `sink.text(field_index, bytes)` gets
    /// decoded string bytes of watched fields in order; `keys` lists them.
    pub fn feed(self: *Extractor, bytes: []const u8, keys: []const []const u8, sink: anytype) void {
        var out: [256]u8 = undefined;
        var out_len: usize = 0;
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            const byte = bytes[index];
            switch (self.state) {
                .done => return,
                .before_object => if (byte == '{') {
                    self.state = .expect_key;
                },
                .expect_key => switch (byte) {
                    '"' => {
                        self.state = .in_key;
                        self.key_len = 0;
                        self.key_overflow = false;
                    },
                    '}' => self.state = .done,
                    else => {},
                },
                .in_key => switch (byte) {
                    '"' => self.state = .after_key,
                    '\\' => self.state = .key_escape,
                    else => self.pushKey(byte),
                },
                .key_escape => {
                    self.pushKey(byte);
                    self.state = .in_key;
                },
                .after_key => if (byte == ':') {
                    self.state = .before_value;
                },
                .before_value => switch (byte) {
                    ' ', '\t', '\r', '\n' => {},
                    '"' => {
                        self.field = self.watched(keys);
                        self.state = .in_string;
                        self.escape = .none;
                        self.high_surrogate = null;
                    },
                    else => {
                        self.state = .skip_value;
                        self.depth = 0;
                        self.skip_string = false;
                        self.skipByte(byte);
                    },
                },
                .in_string => {
                    if (self.decode(byte, &out, &out_len)) {
                        // The value closed.
                        if (self.field) |field| if (out_len > 0) sink.text(field, out[0..out_len]);
                        out_len = 0;
                        self.field = null;
                        self.state = .expect_key;
                    } else if (out_len + 4 > out.len) {
                        if (self.field) |field| sink.text(field, out[0..out_len]);
                        out_len = 0;
                    }
                },
                .skip_value => self.skipByte(byte),
            }
        }
        if (self.state == .in_string) if (self.field) |field| if (out_len > 0) sink.text(field, out[0..out_len]);
    }

    fn pushKey(self: *Extractor, byte: u8) void {
        if (self.key_len == self.key_buf.len) {
            self.key_overflow = true;
            return;
        }
        self.key_buf[self.key_len] = byte;
        self.key_len += 1;
    }

    fn watched(self: *const Extractor, keys: []const []const u8) ?usize {
        if (self.key_overflow) return null;
        for (keys, 0..) |key, index| {
            if (std.mem.eql(u8, key, self.key_buf[0..self.key_len])) return index;
        }
        return null;
    }

    fn skipByte(self: *Extractor, byte: u8) void {
        if (self.skip_string) {
            if (self.skip_escape) {
                self.skip_escape = false;
            } else if (byte == '\\') {
                self.skip_escape = true;
            } else if (byte == '"') {
                self.skip_string = false;
            }
            return;
        }
        switch (byte) {
            '"' => self.skip_string = true,
            '{', '[' => self.depth += 1,
            '}', ']' => if (self.depth == 0) {
                self.state = .done;
            } else {
                self.depth -= 1;
            },
            ',' => if (self.depth == 0) {
                self.state = .expect_key;
            },
            else => {},
        }
    }

    /// Decodes one byte of a string value into `out`. True when the byte
    /// closed the string.
    fn decode(self: *Extractor, byte: u8, out: *[256]u8, len: *usize) bool {
        switch (self.escape) {
            .none => {
                if (byte == '"') return true;
                if (byte == '\\') {
                    self.escape = .backslash;
                    return false;
                }
                self.flushSurrogate(out, len);
                out[len.*] = byte;
                len.* += 1;
            },
            .backslash => {
                self.escape = .none;
                if (byte == 'u') {
                    self.escape = .unicode;
                    self.hex = 0;
                    self.hex_digits = 0;
                    return false;
                }
                self.flushSurrogate(out, len);
                const decoded: ?u8 = switch (byte) {
                    'n' => '\n',
                    't' => '\t',
                    'r', 'b', 'f' => null,
                    else => byte,
                };
                if (decoded) |value| {
                    out[len.*] = value;
                    len.* += 1;
                }
            },
            .unicode => {
                const digit = std.fmt.charToDigit(byte, 16) catch {
                    self.escape = .none;
                    return false;
                };
                self.hex = (self.hex << 4) | digit;
                self.hex_digits += 1;
                if (self.hex_digits < 4) return false;
                self.escape = .none;
                const unit = self.hex;
                if (unit >= 0xd800 and unit <= 0xdbff) {
                    self.flushSurrogate(out, len);
                    self.high_surrogate = unit;
                    return false;
                }
                var codepoint: u21 = unit;
                if (unit >= 0xdc00 and unit <= 0xdfff) {
                    const high = self.high_surrogate orelse return false;
                    self.high_surrogate = null;
                    codepoint = 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (unit - 0xdc00);
                } else {
                    self.flushSurrogate(out, len);
                }
                const written = std.unicode.utf8Encode(codepoint, out[len.*..][0..4]) catch return false;
                len.* += written;
            },
        }
        return false;
    }

    /// A lone high surrogate reads as the replacement character.
    fn flushSurrogate(self: *Extractor, out: *[256]u8, len: *usize) void {
        if (self.high_surrogate == null) return;
        self.high_surrogate = null;
        @memcpy(out[len.*..][0..3], "\u{fffd}");
        len.* += 3;
    }
};

/// Keeps a bounded tail of text and how many whole lines fell off its front.
const BodyTail = struct {
    const capacity = preview_contract.body_capacity * 2;

    bytes: std.ArrayList(u8) = .empty,
    dropped_lines: u32 = 0,
    at_line_start: bool = true,

    fn append(self: *BodyTail, alloc: Allocator, text: []const u8, marker: ?u8) !void {
        for (text) |byte| {
            if (self.at_line_start) if (marker) |value| try self.bytes.append(alloc, value);
            try self.bytes.append(alloc, byte);
            self.at_line_start = byte == '\n';
        }
        if (self.bytes.items.len > capacity) {
            var cut = self.bytes.items.len - capacity / 2;
            const newline = std.mem.findScalarPos(u8, self.bytes.items, cut, '\n') orelse return;
            cut = newline + 1;
            self.dropped_lines +|= @intCast(std.mem.count(u8, self.bytes.items[0..cut], "\n"));
            const rest = self.bytes.items.len - cut;
            @memmove(self.bytes.items[0..rest], self.bytes.items[cut..]);
            self.bytes.shrinkRetainingCapacity(rest);
        }
    }

    /// Starts a new field's lines on their own row.
    fn breakLine(self: *BodyTail, alloc: Allocator) !void {
        if (self.at_line_start) return;
        try self.bytes.append(alloc, '\n');
        self.at_line_start = true;
    }
};

/// The newest call's streaming state. One per model step.
pub const Tracker = struct {
    call_id: std.ArrayList(u8) = .empty,
    tool_name: std.ArrayList(u8) = .empty,
    fields: ?Fields = null,
    extractor: Extractor = .{},
    subject: std.ArrayList(u8) = .empty,
    body: BodyTail = .{},
    last_body_field: ?usize = null,
    dirty: bool = false,
    sent_ms: i64 = 0,

    /// Previews go out at most this often while a call streams.
    pub const interval_ms: i64 = 50;

    pub fn deinit(self: *Tracker, alloc: Allocator) void {
        self.call_id.deinit(alloc);
        self.tool_name.deinit(alloc);
        self.subject.deinit(alloc);
        self.body.bytes.deinit(alloc);
    }

    /// A call started. Its preview replaces the previous call's.
    pub fn start(self: *Tracker, alloc: Allocator, call_id: []const u8, tool_name: []const u8) !void {
        self.reset();
        self.fields = fieldsFor(tool_name) orelse return;
        try self.call_id.appendSlice(alloc, call_id);
        try self.tool_name.appendSlice(alloc, tool_name);
    }

    fn reset(self: *Tracker) void {
        self.call_id.clearRetainingCapacity();
        self.tool_name.clearRetainingCapacity();
        self.subject.clearRetainingCapacity();
        self.body.bytes.clearRetainingCapacity();
        self.body = .{ .bytes = self.body.bytes };
        self.fields = null;
        self.extractor = .{};
        self.last_body_field = null;
        self.dirty = false;
        self.sent_ms = 0;
    }

    /// Feeds an argument fragment for `call_id`. Fragments for an older call
    /// are ignored: only the newest call is shown.
    pub fn feed(self: *Tracker, alloc: Allocator, call_id: []const u8, chunk: []const u8) void {
        const fields = self.fields orelse return;
        if (call_id.len > 0 and !std.mem.eql(u8, call_id, self.call_id.items)) return;
        var keys_buf: [3][]const u8 = undefined;
        var keys_len: usize = 0;
        if (fields.subject) |subject| {
            keys_buf[0] = subject;
            keys_len = 1;
        }
        for (fields.body) |key| {
            if (keys_len == keys_buf.len) break;
            keys_buf[keys_len] = key;
            keys_len += 1;
        }
        var sink: Sink = .{ .tracker = self, .alloc = alloc, .fields = fields };
        self.extractor.feed(chunk, keys_buf[0..keys_len], &sink);
    }

    const Sink = struct {
        tracker: *Tracker,
        alloc: Allocator,
        fields: Fields,

        pub fn text(self: *Sink, field: usize, bytes: []const u8) void {
            const tracker = self.tracker;
            tracker.dirty = true;
            const body_index = if (self.fields.subject != null) if (field == 0) {
                const room = preview_contract.subject_capacity -| tracker.subject.items.len;
                tracker.subject.appendSlice(self.alloc, bytes[0..@min(room, bytes.len)]) catch {};
                return;
            } else field - 1 else field;
            if (tracker.last_body_field != null and tracker.last_body_field.? != body_index) {
                tracker.body.breakLine(self.alloc) catch {};
            }
            tracker.last_body_field = body_index;
            const marker: ?u8 = if (body_index < self.fields.markers.len) self.fields.markers[body_index] else null;
            tracker.body.append(self.alloc, bytes, marker) catch {};
        }
    };

    /// A preview due now, or null when nothing changed or the last one went
    /// out less than `interval_ms` ago. `force` ignores the interval. The
    /// preview borrows tracker storage until the next feed.
    pub fn due(self: *Tracker, now_ms: i64, force: bool) ?Preview {
        if (!self.dirty or self.fields == null) return null;
        if (!force and self.sent_ms != 0 and now_ms - self.sent_ms < interval_ms) return null;
        self.dirty = false;
        self.sent_ms = now_ms;
        var body = self.body.bytes.items;
        var earlier = self.body.dropped_lines;
        if (body.len > preview_contract.body_capacity) {
            const from = body.len - preview_contract.body_capacity;
            const cut = if (std.mem.findScalarPos(u8, body, from, '\n')) |newline| newline + 1 else from;
            earlier +|= @intCast(std.mem.count(u8, body[0..cut], "\n"));
            body = body[cut..];
        }
        return .{
            .call_id = self.call_id.items,
            .tool_name = self.tool_name.items,
            .subject = self.subject.items,
            .body = body,
            .body_kind = self.fields.?.kind,
            .earlier_lines = earlier,
        };
    }
};

const TestSink = struct {
    fields: [3]std.ArrayList(u8) = @splat(.empty),

    pub fn text(self: *TestSink, field: usize, bytes: []const u8) void {
        self.fields[field].appendSlice(std.testing.allocator, bytes) catch unreachable;
    }

    fn deinit(self: *TestSink) void {
        for (&self.fields) |*field| field.deinit(std.testing.allocator);
    }
};

test "the extractor decodes watched fields from any split of the stream" {
    const json =
        \\{"action":"run","nested":{"command":"no","list":[1,"]}"]},"command":"python3 - <<'PY'\nprint(\"h\u00e9 \ud835\udcd5\")\nPY","tty":false}
    ;
    const keys = [_][]const u8{"command"};
    for (1..json.len + 1) |step| {
        var extractor: Extractor = .{};
        var sink: TestSink = .{};
        defer sink.deinit();
        var index: usize = 0;
        while (index < json.len) : (index += step) extractor.feed(json[index..@min(json.len, index + step)], &keys, &sink);
        try std.testing.expectEqualStrings("python3 - <<'PY'\nprint(\"h\u{e9} \u{1d4d5}\")\nPY", sink.fields[0].items);
        try std.testing.expectEqual(Extractor.State.done, extractor.state);
    }
}

test "the tracker previews the newest call and throttles its updates" {
    const alloc = std.testing.allocator;
    var tracker: Tracker = .{};
    defer tracker.deinit(alloc);
    try tracker.start(alloc, "a", "read_file");
    tracker.feed(alloc, "a", "{\"path\":\"x\"}");
    try std.testing.expect(tracker.due(1000, true) == null);

    try tracker.start(alloc, "b", "edit_file");
    tracker.feed(alloc, "b", "{\"path\":\"src/app.py\",\"old_string\":\"return 1\\nx\",\"new_");
    const first = tracker.due(1000, false).?;
    try std.testing.expectEqualStrings("src/app.py", first.subject);
    try std.testing.expectEqualStrings("-return 1\n-x", first.body);
    try std.testing.expectEqual(BodyKind.diff, first.body_kind);
    tracker.feed(alloc, "b", "string\":\"return 2\"}");
    tracker.feed(alloc, "other", "{\"path\":\"ignored\"}");
    try std.testing.expect(tracker.due(1010, false) == null);
    const second = tracker.due(1060, false).?;
    try std.testing.expectEqualStrings("-return 1\n-x\n+return 2", second.body);
    try std.testing.expect(tracker.due(2000, true) == null);
}

test "a long body keeps its tail and counts earlier lines" {
    const alloc = std.testing.allocator;
    var tracker: Tracker = .{};
    defer tracker.deinit(alloc);
    try tracker.start(alloc, "w", "write_file");
    tracker.feed(alloc, "w", "{\"path\":\"big.txt\",\"content\":\"");
    var line_buf: [32]u8 = undefined;
    for (0..5000) |index| tracker.feed(alloc, "w", try std.mem.print(&line_buf, "row {d}\\n", .{index}));
    const preview = tracker.due(0, true).?;
    try std.testing.expect(preview.body.len <= preview_contract.body_capacity);
    try std.testing.expect(std.mem.endsWith(u8, preview.body, "row 4999\n"));
    try std.testing.expectEqual(@as(u32, 5000), preview.earlier_lines + @as(u32, @intCast(std.mem.count(u8, preview.body, "\n"))));
    try std.testing.expect(tracker.body.bytes.items.len <= BodyTail.capacity + 64);
}
