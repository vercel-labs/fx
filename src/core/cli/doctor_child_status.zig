//! Reads the answer of a doctor check child, `fx mcp show NAME --json`, as
//! it arrives on the pipe, in fixed memory.
const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");

const ChildStatus = struct {
    status: []const u8,
    err: ?[]const u8 = null,
    tools: usize = 0,
};

/// Reads `fx mcp show NAME --json` output as it arrives and keeps only what
/// doctor reports: the status, the error, and how many tools there are. Its
/// memory is fixed, so an answer of any size is read whole. Strings longer
/// than doctor shows are cut at a whole character.
pub const ChildStatusReader = struct {
    /// Nesting deeper than fx mcp show writes is unreadable.
    const max_depth = 32;
    /// Room for the scanner's stack of one bit per level of nesting.
    const nesting_bytes = 256;
    /// The longest member name doctor looks for, `status`, fits.
    const name_capacity = 8;
    const status_capacity = 64;
    const error_capacity = 1024;
    /// The scanner's stack height after a token: inside the top-level
    /// object, inside a member's array or object, and inside one element of
    /// that array.
    const in_object = 1;
    const in_member = 2;
    const in_element = 3;

    const Member = enum { other, status, err, tools };
    /// Which part of a string a token holds.
    const Part = enum { middle, last };

    nesting: [nesting_bytes]u8 = undefined,
    nesting_alloc: std.heap.FixedBufferAllocator = undefined,
    scanner: std.json.Scanner = undefined,
    unreadable: bool = false,
    ended: bool = false,
    complete: bool = false,
    began: bool = false,
    /// In the top-level object, the next string is a member name.
    want_name: bool = false,
    member: Member = .other,
    name: Text(name_capacity) = .{},
    status: Text(status_capacity) = .{},
    status_is_string: bool = false,
    err: Text(error_capacity) = .{},
    err_is_string: bool = false,
    in_tools: bool = false,
    tools: usize = 0,

    /// Sets the reader up in place. It must not move afterward.
    pub fn init(self: *ChildStatusReader) void {
        self.* = .{};
        self.nesting_alloc = .init(&self.nesting);
        self.scanner = .initStreaming(self.nesting_alloc.allocator());
    }

    pub fn feed(self: *ChildStatusReader, bytes: []const u8) void {
        if (self.unreadable or self.ended) return;
        self.scanner.feedInput(bytes);
        self.drain();
    }

    /// Ends the input, at the end of the child's pipe.
    pub fn end(self: *ChildStatusReader) void {
        if (self.ended) return;
        self.ended = true;
        if (self.unreadable) return;
        self.scanner.endInput();
        self.drain();
    }

    /// What `end` found. Anything but the object fx mcp show writes, with a
    /// string status, is `error.Unreadable`. Strings borrow the reader.
    pub fn result(self: *const ChildStatusReader) error{Unreadable}!ChildStatus {
        if (self.unreadable or !self.complete or !self.status_is_string) return error.Unreadable;
        return .{
            .status = self.status.slice(),
            .err = if (self.err_is_string) self.err.slice() else null,
            .tools = self.tools,
        };
    }

    fn drain(self: *ChildStatusReader) void {
        while (true) {
            const token = self.scanner.next() catch |err| {
                if (err != error.BufferUnderrun) self.unreadable = true;
                return;
            };
            if (token == .end_of_document) {
                self.complete = true;
                return;
            }
            if (!self.take(token, self.scanner.stackHeight())) {
                self.unreadable = true;
                return;
            }
        }
    }

    /// Takes one token, with `height` the nesting after it. False when the
    /// output is not an object.
    fn take(self: *ChildStatusReader, token: std.json.Token, height: usize) bool {
        if (height > max_depth) return false;
        if (!self.began) {
            if (token != .object_begin) return false;
            self.began = true;
            self.want_name = true;
            return true;
        }
        switch (token) {
            .object_begin, .array_begin => {
                if (height == in_member) {
                    self.in_tools = self.member == .tools and token == .array_begin;
                } else if (height == in_element and self.in_tools) {
                    self.tools += 1;
                }
            },
            .object_end, .array_end => if (height == in_object) {
                self.in_tools = false;
                self.want_name = true;
            },
            .partial_string => |bytes| self.piece(bytes, height, .middle),
            .partial_string_escaped_1 => |bytes| self.piece(&bytes, height, .middle),
            .partial_string_escaped_2 => |bytes| self.piece(&bytes, height, .middle),
            .partial_string_escaped_3 => |bytes| self.piece(&bytes, height, .middle),
            .partial_string_escaped_4 => |bytes| self.piece(&bytes, height, .middle),
            .string => |bytes| self.piece(bytes, height, .last),
            .number, .true, .false, .null => {
                if (height == in_object) {
                    self.want_name = true;
                } else if (height == in_member and self.in_tools) {
                    self.tools += 1;
                }
            },
            else => {},
        }
        return true;
    }

    /// One part of a string token.
    fn piece(self: *ChildStatusReader, bytes: []const u8, height: usize, part: Part) void {
        if (height == in_object and self.want_name) {
            self.name.append(bytes);
            if (part == .middle) return;
            self.member = memberNamed(&self.name);
            self.name = .{};
            self.want_name = false;
            switch (self.member) {
                .status => {
                    self.status = .{};
                    self.status_is_string = false;
                },
                .err => {
                    self.err = .{};
                    self.err_is_string = false;
                },
                .tools => {
                    self.tools = 0;
                    self.in_tools = false;
                },
                .other => {},
            }
            return;
        }
        if (height == in_object) {
            switch (self.member) {
                .status => self.status.append(bytes),
                .err => self.err.append(bytes),
                .tools, .other => {},
            }
            if (part == .middle) return;
            if (self.member == .status) self.status_is_string = true;
            if (self.member == .err) self.err_is_string = true;
            self.want_name = true;
            return;
        }
        if (part == .last and height == in_member and self.in_tools) self.tools += 1;
    }

    fn memberNamed(name: *const Text(name_capacity)) Member {
        if (name.full) return .other;
        const text = name.slice();
        if (std.mem.eql(u8, text, "status")) return .status;
        if (std.mem.eql(u8, text, "error")) return .err;
        if (std.mem.eql(u8, text, "tools")) return .tools;
        return .other;
    }
};

/// Up to `capacity` bytes of a string. Past that, the rest is dropped, and a
/// character the limit cut in two is dropped too.
fn Text(comptime capacity: usize) type {
    return struct {
        /// One byte past `capacity`, so the cut can tell whether the byte
        /// after it continues a character, even when a character spans two
        /// parts.
        bytes: [capacity + 1]u8 = undefined,
        len: usize = 0,
        full: bool = false,

        fn append(self: *@This(), part: []const u8) void {
            if (self.full) return;
            const n = @min(self.bytes.len - self.len, part.len);
            @memcpy(self.bytes[self.len..][0..n], part[0..n]);
            self.len += n;
            if (self.len <= capacity) return;
            self.full = true;
            self.len = text_utils.utf8BackwardBoundary(&self.bytes, capacity);
        }

        fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// Reads `bytes` as one whole answer. The result borrows `reader`.
fn parseChildStatus(reader: *ChildStatusReader, bytes: []const u8) error{Unreadable}!ChildStatus {
    reader.init();
    reader.feed(bytes);
    reader.end();
    return reader.result();
}

test "child status parser reads fx mcp show output and refuses anything else" {
    var reader: ChildStatusReader = undefined;
    const ready = try parseChildStatus(&reader, "{\"name\":\"a\",\"status\":\"ready\",\"error\":null,\"tools\":[{\"name\":\"x\"},{\"name\":\"y\"}]}\n");
    try std.testing.expectEqualStrings("ready", ready.status);
    try std.testing.expect(ready.err == null);
    try std.testing.expectEqual(@as(usize, 2), ready.tools);
    const failed = try parseChildStatus(&reader, "{\"status\":\"failed\",\"error\":\"boom\"}");
    try std.testing.expectEqualStrings("boom", failed.err.?);
    const escaped = try parseChildStatus(&reader, "{\"st\\u0061tus\":\"ready\",\"tools\":[1,\"two\",[3],null,{\"tools\":[4,5]}],\"other\":{\"status\":\"no\"}}");
    try std.testing.expectEqualStrings("ready", escaped.status);
    try std.testing.expectEqual(@as(usize, 5), escaped.tools);
    for ([_][]const u8{ "", "null", "[]", "{\"status\":1}", "{\"tools\":[]}", "{\"status\":\"ready\"", "{\"status\":\"ready\"} x", "\xff" }) |bad| {
        try std.testing.expectError(error.Unreadable, parseChildStatus(&reader, bad));
    }
    const deep = "{\"status\":\"ready\",\"x\":" ++ text_utils.repeat("[", 40) ++ text_utils.repeat("]", 40) ++ "}";
    try std.testing.expectError(error.Unreadable, parseChildStatus(&reader, deep));
}

test "child status reader counts any number of tools in fixed memory" {
    var reader: ChildStatusReader = undefined;
    reader.init();
    reader.feed("{\"name\":\"big\",\"status\":\"rea");
    reader.feed("dy\",\"error\":null,\"tools\":[");
    const tool = "{\"name\":\"tool\",\"description\":\"" ++ text_utils.repeat("d", 200) ++ "\",\"inputSchema\":{\"type\":\"object\"}}";
    for (0..5_000) |i| reader.feed(if (i == 0) tool else "," ++ tool);
    reader.feed("]}\n");
    reader.end();
    const parsed = try reader.result();
    try std.testing.expectEqualStrings("ready", parsed.status);
    try std.testing.expectEqual(@as(usize, 5_000), parsed.tools);
}

test "child status reader cuts a long error at a whole character" {
    var reader: ChildStatusReader = undefined;
    const long = "{\"status\":\"failed\",\"error\":\"" ++ text_utils.repeat("a", ChildStatusReader.error_capacity - 1) ++ "\u{e9}tail\"}";
    const parsed = try parseChildStatus(&reader, long);
    try std.testing.expectEqual(ChildStatusReader.error_capacity - 1, parsed.err.?.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(parsed.err.?));
}

fn fuzzChildStatus(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var whole: ChildStatusReader = undefined;
    const expected = parseChildStatus(&whole, bytes);
    // The same bytes in the pieces a pipe could hand over read the same.
    var pieces: ChildStatusReader = undefined;
    pieces.init();
    var rest = bytes;
    while (rest.len > 0) {
        const n = smith.valueRangeAtMost(u32, 1, @intCast(rest.len));
        pieces.feed(rest[0..n]);
        rest = rest[n..];
    }
    pieces.end();
    const got = pieces.result();
    const want = expected catch return std.testing.expectError(error.Unreadable, got);
    const have = try got;
    try std.testing.expectEqualStrings(want.status, have.status);
    try std.testing.expectEqual(want.err == null, have.err == null);
    if (want.err) |text| try std.testing.expectEqualStrings(text, have.err.?);
    try std.testing.expectEqual(want.tools, have.tools);
    // A status fx reads came from the bytes, so it is no longer than them.
    try std.testing.expect(want.status.len <= bytes.len);
}

test "doctor child status parser tolerates arbitrary bytes" {
    try std.testing.fuzz({}, fuzzChildStatus, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"name\":\"a\",\"status\":\"ready\",\"error\":null,\"tools\":[{\"name\":\"x\"}]}",
            "{\"status\":\"needs_login\",\"error\":\"sign in\"}",
            "{\"status\":\"ready\"",
            "[]",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").doctor_child_status.*),
    });
}
