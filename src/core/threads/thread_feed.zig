//! Live feed of one thread: a bounded ring of terminal-safe text lines that
//! the thread's agent thread appends to and the UI thread tails.
//!
//! The agent thread owns appending; any thread may read. Every byte stored is
//! copied, so callers keep ownership of what they pass in.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;

pub const default_max_lines: usize = 400;
pub const max_line_bytes: usize = 2048;

pub const Feed = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    lines: std.ArrayList([]u8) = .empty,
    /// Text of a line the producer has not finished with a newline yet.
    partial: std.ArrayList(u8) = .empty,
    /// Where the producer is inside an escape sequence, so one split across
    /// two chunks is still dropped whole.
    escape: EscapeState = .none,
    /// Sequence number of `lines.items[0]`.
    first_seq: u64 = 0,
    max_lines: usize = default_max_lines,
    last_activity_ms: std.atomic.Value(i64) = .init(0),

    pub fn init(alloc: Allocator) Feed {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Feed) void {
        for (self.lines.items) |line| self.alloc.free(line);
        self.lines.deinit(self.alloc);
        self.partial.deinit(self.alloc);
        self.* = undefined;
    }

    /// Appends streamed text. Complete lines enter the ring; the tail waits
    /// for its newline.
    pub fn appendText(self: *Feed, text: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (text) |byte| {
            if (self.escape.consume(byte)) continue;
            if (byte == '\n') {
                self.flushPartialLocked();
                continue;
            }
            if (self.partial.items.len >= max_line_bytes) {
                self.flushPartialLocked();
            }
            self.partial.append(self.alloc, safeByte(byte)) catch return;
        }
        self.touch();
    }

    /// Appends one whole line, finishing any pending partial line first.
    pub fn appendLine(self: *Feed, line: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.flushPartialLocked();
        self.pushLineLocked(line);
        self.touch();
    }

    /// Records the events that matter to someone watching. Anything else is
    /// ignored; the event stays owned by the caller.
    pub fn appendEvent(self: *Feed, event: worker_runtime.WorkerEvent) void {
        switch (event) {
            .tool_lifecycle => |lifecycle| switch (lifecycle) {
                .authoritative_started => |started| {
                    var buf: [160]u8 = undefined;
                    const line = std.mem.print(&buf, "tool {s}", .{started.tool_name}) catch return;
                    self.appendLine(line);
                },
                .terminal => |terminal| {
                    var buf: [64]u8 = undefined;
                    const line = std.mem.print(&buf, "tool finished: {s}", .{@tagName(terminal.outcome.kind)}) catch return;
                    self.appendLine(line);
                },
                else => {},
            },
            .semantic_notice, .error_text => |notice| {
                var buf: [max_line_bytes]u8 = undefined;
                const line = std.mem.print(&buf, "{s}: {s}", .{ notice.topic, notice.body }) catch return;
                self.appendLine(line);
            },
            else => {},
        }
    }

    pub const Read = struct {
        /// Owned by the caller; free each line and the slice.
        lines: [][]u8,
        /// Pass this as `since` on the next read.
        next_seq: u64,
        /// Lines the caller missed because the ring dropped them.
        dropped: u64,

        pub fn deinit(self: Read, alloc: Allocator) void {
            for (self.lines) |line| alloc.free(line);
            alloc.free(self.lines);
        }
    };

    /// Complete lines with sequence number >= `since`, copied for the caller.
    pub fn readSince(self: *Feed, alloc: Allocator, since: u64) Allocator.Error!Read {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const end = self.first_seq + self.lines.items.len;
        const start = @max(since, self.first_seq);
        const dropped = start -| since;
        const from: usize = @intCast(@min(start, end) - self.first_seq);
        const out = try alloc.alloc([]u8, self.lines.items.len - from);
        var made: usize = 0;
        errdefer {
            for (out[0..made]) |line| alloc.free(line);
            alloc.free(out);
        }
        for (self.lines.items[from..]) |line| {
            out[made] = try alloc.dupe(u8, line);
            made += 1;
        }
        return .{ .lines = out, .next_seq = end, .dropped = dropped };
    }

    pub const Tail = struct {
        /// Owned by the caller; free each line and the slice. The last line
        /// is the unfinished one when the producer is mid-line.
        lines: [][]u8,
        /// Complete lines the feed has held in all, including dropped ones.
        total_lines: u64,

        pub fn deinit(self: Tail, alloc: Allocator) void {
            for (self.lines) |line| alloc.free(line);
            alloc.free(self.lines);
        }
    };

    /// The newest `max` lines for a live view, counting the unfinished line.
    pub fn tail(self: *Feed, alloc: Allocator, max: usize) Allocator.Error!Tail {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const have_partial = self.partial.items.len > 0;
        const available = self.lines.items.len + @intFromBool(have_partial);
        const count = @min(max, available);
        const out = try alloc.alloc([]u8, count);
        var made: usize = 0;
        errdefer {
            for (out[0..made]) |line| alloc.free(line);
            alloc.free(out);
        }
        const skip = available - count;
        var index: usize = skip;
        while (index < available) : (index += 1) {
            const source = if (index < self.lines.items.len) self.lines.items[index] else self.partial.items;
            out[made] = try alloc.dupe(u8, source);
            made += 1;
        }
        return .{ .lines = out, .total_lines = self.first_seq + self.lines.items.len };
    }

    /// Wall-clock milliseconds of the last append, or 0 before the first.
    pub fn lastActivityMs(self: *const Feed) i64 {
        return self.last_activity_ms.load(.monotonic);
    }

    fn touch(self: *Feed) void {
        self.last_activity_ms.store(io_mod.milliTimestamp(), .monotonic);
    }

    fn flushPartialLocked(self: *Feed) void {
        if (self.partial.items.len == 0) return;
        self.pushLineLocked(self.partial.items);
        self.partial.clearRetainingCapacity();
    }

    fn pushLineLocked(self: *Feed, line: []const u8) void {
        var cleaned: std.ArrayList(u8) = .empty;
        defer cleaned.deinit(self.alloc);
        var escape: EscapeState = .none;
        for (line[0..@min(line.len, max_line_bytes)]) |byte| {
            if (escape.consume(byte)) continue;
            cleaned.append(self.alloc, safeByte(byte)) catch return;
        }
        const copy = self.alloc.dupe(u8, cleaned.items) catch return;
        if (self.lines.items.len >= self.max_lines) {
            self.alloc.free(self.lines.orderedRemove(0));
            self.first_seq += 1;
        }
        self.lines.append(self.alloc, copy) catch {
            self.alloc.free(copy);
        };
    }
};

/// Drops terminal escape sequences (CSI and OSC) whole, so styling the model
/// or a tool emitted never reaches the screen and never shows as stray text.
const EscapeState = enum {
    none,
    esc,
    csi,
    osc,
    osc_esc,

    /// True when `byte` belongs to an escape sequence and must be dropped.
    fn consume(self: *EscapeState, byte: u8) bool {
        switch (self.*) {
            .none => {
                if (byte == 0x1b) {
                    self.* = .esc;
                    return true;
                }
                return false;
            },
            .esc => {
                self.* = switch (byte) {
                    '[' => .csi,
                    ']' => .osc,
                    else => .none,
                };
                return true;
            },
            // A CSI sequence ends at its first final byte, 0x40 to 0x7e.
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) self.* = .none;
                return true;
            },
            // An OSC string ends at BEL or ESC backslash.
            .osc => {
                if (byte == 0x07) self.* = .none;
                if (byte == 0x1b) self.* = .osc_esc;
                return true;
            },
            .osc_esc => {
                self.* = if (byte == '\\') .none else .osc;
                return true;
            },
        }
    }
};

/// Control bytes never reach a terminal through the feed.
fn safeByte(byte: u8) u8 {
    return if (byte < 0x20 and byte != '\t' or byte == 0x7f) '?' else byte;
}

test "feed splits streamed text into lines and keeps the unfinished tail back" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.appendText("hello wor");
    feed.appendText("ld\nsecond");
    const first = try feed.readSince(alloc, 0);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), first.lines.len);
    try std.testing.expectEqualStrings("hello world", first.lines[0]);
    try std.testing.expectEqual(@as(u64, 1), first.next_seq);
    feed.appendText("\n");
    const second = try feed.readSince(alloc, first.next_seq);
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings("second", second.lines[0]);
}

test "feed drops the oldest lines past its bound and reports the gap" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.max_lines = 3;
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |line| feed.appendLine(line);
    const read = try feed.readSince(alloc, 0);
    defer read.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), read.lines.len);
    try std.testing.expectEqualStrings("c", read.lines[0]);
    try std.testing.expectEqual(@as(u64, 2), read.dropped);
    try std.testing.expectEqual(@as(u64, 5), read.next_seq);
}

test "feed replaces control bytes other than escape sequences" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.appendLine("a\x07b\x7fc");
    const read = try feed.readSince(alloc, 0);
    defer read.deinit(alloc);
    try std.testing.expectEqualStrings("a?b?c", read.lines[0]);
}

test "feed records tool lifecycle and notices from worker events" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.appendEvent(.{ .error_text = .{ .topic = "model", .tone = .warning, .body = "slow" } });
    const read = try feed.readSince(alloc, 0);
    defer read.deinit(alloc);
    try std.testing.expectEqualStrings("model: slow", read.lines[0]);
    try std.testing.expect(feed.lastActivityMs() > 0);
}

test "feed drops escape sequences, even when a chunk boundary splits one" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.appendText("\x1b[2m1.\x1b[22m Cross \x1b");
    feed.appendText("[1;31mthe\x1b[0m line\n");
    feed.appendText("link \x1b]8;;https://example.com\x07here\x1b]8;;\x07\n");
    feed.appendLine("\x1b[31mred\x1b[0m");
    const read = try feed.readSince(alloc, 0);
    defer read.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), read.lines.len);
    try std.testing.expectEqualStrings("1. Cross the line", read.lines[0]);
    try std.testing.expectEqualStrings("link here", read.lines[1]);
    try std.testing.expectEqualStrings("red", read.lines[2]);
}

test "feed tail includes the unfinished line and counts total lines" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.appendText("one\ntwo\nthr");
    const tail = try feed.tail(alloc, 2);
    defer tail.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), tail.lines.len);
    try std.testing.expectEqualStrings("two", tail.lines[0]);
    try std.testing.expectEqualStrings("thr", tail.lines[1]);
    try std.testing.expectEqual(@as(u64, 2), tail.total_lines);
}
