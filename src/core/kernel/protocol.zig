//! The kernel JSONL vocabulary shared with runtime.py, and bounded UTF-8 output retention.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const max_frame_bytes = 32 * 1024 * 1024;
/// Must equal `PROTOCOL_VERSION` in runtime.py; bump both when the wire shape changes.
pub const version = 5;

/// One host-to-runtime frame. Request ids travel as decimal strings.
pub const Request = union(enum) {
    execute: struct { id: u64, code: []const u8 },
    interrupt: u64,
    /// Writes each changed global as a record into `dir`, the node's blob
    /// folder, and answers with the manifest (D99).
    snapshot: struct { id: u64, dir: []const u8 },
    /// Loads `records` from `dir`, or a legacy snapshot file at `path`.
    restore: struct { id: u64, dir: []const u8 = "", records: []const Record = &.{}, path: ?[]const u8 = null },
    shutdown: u64,

    pub fn jsonStringify(self: Request, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(@tagName(self));
        switch (self) {
            .execute => |request| {
                try writeId(jw, request.id);
                try jw.objectField("code");
                try jw.write(request.code);
            },
            .snapshot => |target| {
                try writeId(jw, target.id);
                try jw.objectField("dir");
                try jw.write(target.dir);
            },
            .restore => |target| {
                try writeId(jw, target.id);
                if (target.path) |path| {
                    try jw.objectField("path");
                    try jw.write(path);
                } else {
                    try jw.objectField("dir");
                    try jw.write(target.dir);
                    try jw.objectField("records");
                    try jw.beginArray();
                    for (target.records) |record| {
                        try jw.beginObject();
                        try jw.objectField("name");
                        try jw.write(record.name);
                        try jw.objectField("hash");
                        try jw.write(record.hash);
                        try jw.endObject();
                    }
                    try jw.endArray();
                }
            },
            .interrupt, .shutdown => |id| try writeId(jw, id),
        }
        try jw.endObject();
    }

    fn writeId(jw: anytype, id: u64) !void {
        var buf: [24]u8 = undefined;
        try jw.objectField("id");
        try jw.write(std.mem.print(&buf, "{d}", .{id}) catch unreachable);
    }
};

/// One global of a snapshot: its name, and the blob holding its record.
pub const Record = struct { name: []const u8 = "", hash: []const u8 = "", bytes: u64 = 0 };

/// A kernel's globals at one moment: the records that hold them, and the
/// globals a snapshot could not hold. Owns its slices.
pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    records: []const Record = &.{},
    failed: []const Event.Failure = &.{},
    /// Record bytes the snapshot that made it wrote, and their total.
    written: u64 = 0,
    bytes: u64 = 0,

    pub fn create(gpa: Allocator, records: []const Record, failed: []const Event.Failure) !*Manifest {
        const self = try gpa.create(Manifest);
        errdefer gpa.destroy(self);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const owned_records = try a.alloc(Record, records.len);
        for (records, owned_records) |record, *slot| slot.* = .{ .name = try a.dupe(u8, record.name), .hash = try a.dupe(u8, record.hash), .bytes = record.bytes };
        const owned_failed = try a.alloc(Event.Failure, failed.len);
        for (failed, owned_failed) |entry, *slot| slot.* = .{ .name = try a.dupe(u8, entry.name), .reason = try a.dupe(u8, entry.reason) };
        self.records = owned_records;
        self.failed = owned_failed;
        return self;
    }

    pub fn clone(self: *const Manifest, gpa: Allocator) !*Manifest {
        const copy = try create(gpa, self.records, self.failed);
        copy.written = self.written;
        copy.bytes = self.bytes;
        return copy;
    }

    pub fn destroy(self: *Manifest) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// One runtime-to-host frame. Unknown event names fail parsing, so the reader replaces the kernel.
pub const Event = struct {
    event: Kind,
    id: ?[]const u8 = null,
    text: []const u8 = "",
    protocol: i64 = -1,
    status: ?DoneStatus = null,
    ename: []const u8 = "",
    evalue: []const u8 = "",
    traceback: []const []const u8 = &.{},
    reason: ?[]const u8 = null,
    /// Names a restore could not revive, or a snapshot could not hold.
    failed: []const Failure = &.{},
    /// A snapshot's manifest (D99).
    records: []const Record = &.{},
    written: u64 = 0,
    bytes: u64 = 0,

    pub const Kind = enum { ready, stdout, stderr, result, @"error", done };
    pub const DoneStatus = enum { ok, @"error" };
    pub const Failure = struct { name: []const u8 = "", reason: []const u8 = "" };

    /// The numeric request id, or 0 when absent or not a request id.
    pub fn requestId(self: Event) u64 {
        const text = self.id orelse return 0;
        return std.fmt.parseInt(u64, text, 10) catch 0;
    }
};

pub const Buffer = struct {
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    head_chars: usize = 0,
    tail_chars: usize = 0,
    omitted: usize = 0,

    pub fn deinit(self: *Buffer, alloc: Allocator) void {
        self.head.deinit(alloc);
        self.tail.deinit(alloc);
        self.* = .{};
    }

    pub fn clear(self: *Buffer) void {
        self.head.clearRetainingCapacity();
        self.tail.clearRetainingCapacity();
        self.head_chars = 0;
        self.tail_chars = 0;
        self.omitted = 0;
    }

    pub fn append(self: *Buffer, alloc: Allocator, text: []const u8, cap: usize) !void {
        const tail_cap = cap / 4;
        const head_cap = cap - tail_cap;
        const take = prefix(text, head_cap -| self.head_chars);
        try self.head.appendSlice(alloc, text[0..take.bytes]);
        self.head_chars += take.chars;
        const rest = text[take.bytes..];
        const count = chars(rest);
        if (count >= tail_cap) {
            self.omitted += self.tail_chars + count - tail_cap;
            const skip = prefix(rest, count - tail_cap).bytes;
            self.tail.clearRetainingCapacity();
            try self.tail.appendSlice(alloc, rest[skip..]);
            self.tail_chars = tail_cap;
        } else {
            try self.tail.appendSlice(alloc, rest);
            self.tail_chars += count;
            if (self.tail_chars > tail_cap * 2) self.trimTail(tail_cap);
        }
    }

    fn trimTail(self: *Buffer, cap: usize) void {
        if (self.tail_chars <= cap) return;
        const dropped = self.tail_chars - cap;
        const bytes = prefix(self.tail.items, dropped).bytes;
        @memmove(self.tail.items[0 .. self.tail.items.len - bytes], self.tail.items[bytes..]);
        self.tail.items.len -= bytes;
        self.tail_chars = cap;
        self.omitted += dropped;
    }

    /// Caller owns the returned string.
    pub fn finish(self: *Buffer, alloc: Allocator, cap: usize) ![]u8 {
        self.trimTail(cap / 4);
        if (self.omitted == 0) return std.mem.concat(alloc, u8, &.{ self.head.items, self.tail.items });
        return alloc.print("{s}\n[... {d} chars omitted ...]\n{s}", .{ self.head.items, self.omitted, self.tail.items });
    }
};

fn chars(text: []const u8) usize {
    var n: usize = 0;
    for (text) |byte| if (byte & 0xc0 != 0x80) {
        n += 1;
    };
    return n;
}

fn prefix(text: []const u8, count: usize) struct { bytes: usize, chars: usize } {
    var n: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte & 0xc0 != 0x80) {
            if (n == count) return .{ .bytes = i, .chars = n };
            n += 1;
        }
    }
    return .{ .bytes = text.len, .chars = n };
}

test "kernel output keeps UTF-8 head and tail with bounded storage" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);
    try buffer.append(std.testing.allocator, "αβγδεζηθικλμ", 8);
    const text = try buffer.finish(std.testing.allocator, 8);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("αβγδεζ\n[... 4 chars omitted ...]\nλμ", text);
}

test "kernel requests serialize with string ids and a type tag" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(Request{ .execute = .{ .id = 7, .code = "x = 1" } }, .{}, &out.writer);
    try std.testing.expectEqualStrings("{\"type\":\"execute\",\"id\":\"7\",\"code\":\"x = 1\"}", out.written());
    out.clearRetainingCapacity();
    try std.json.Stringify.value(Request{ .snapshot = .{ .id = 8, .dir = "/s" } }, .{}, &out.writer);
    try std.testing.expectEqualStrings("{\"type\":\"snapshot\",\"id\":\"8\",\"dir\":\"/s\"}", out.written());
    out.clearRetainingCapacity();
    try std.json.Stringify.value(Request{ .restore = .{ .id = 9, .dir = "/b", .records = &.{.{ .name = "x", .hash = "h" }} } }, .{}, &out.writer);
    try std.testing.expectEqualStrings("{\"type\":\"restore\",\"id\":\"9\",\"dir\":\"/b\",\"records\":[{\"name\":\"x\",\"hash\":\"h\"}]}", out.written());
    out.clearRetainingCapacity();
    try std.json.Stringify.value(Request{ .interrupt = 9 }, .{}, &out.writer);
    try std.testing.expectEqualStrings("{\"type\":\"interrupt\",\"id\":\"9\"}", out.written());
}

test "kernel events parse typed tags and reject unknown events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const done = try std.json.parseFromSliceLeaky(Event, arena.allocator(), "{\"event\":\"done\",\"id\":\"3\",\"status\":\"ok\",\"restored\":[\"x\"],\"failed\":[{\"name\":\"y\",\"reason\":\"z\"}]}", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(Event.Kind.done, done.event);
    try std.testing.expectEqual(@as(u64, 3), done.requestId());
    try std.testing.expectEqual(Event.DoneStatus.ok, done.status.?);
    try std.testing.expectEqual(@as(usize, 1), done.failed.len);
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSliceLeaky(Event, arena.allocator(), "{\"event\":\"display\"}", .{ .ignore_unknown_fields = true }));
}

test "kernel runtime embeds this protocol version" {
    const marker = std.fmt.comptimePrint("\nPROTOCOL_VERSION = {d}\n", .{version});
    try std.testing.expect(std.mem.find(u8, @embedFile("runtime.py"), marker) != null);
}
