//! What a tool call looks like while the model is still writing its
//! arguments: the newest call's subject (a path, a query, a worker label)
//! and the end of its body (a command, file content, or an edit as diff
//! lines). The runtime sends a `Preview` as the arguments stream; both
//! terminal backends keep the newest one in a `Tail` until the call starts.
const std = @import("std");
const text_utils = @import("text_utils.zig");

pub const BodyKind = enum {
    /// Prose or a value with no syntax: a query, a worker task.
    text,
    /// A shell command.
    command,
    /// A file's new content; `subject` names the file.
    content,
    /// An edit: removed lines start with `-`, added lines with `+`.
    diff,
};

/// One preview of the newest streaming call. Slices are owned by the event
/// that carries it and travel to a detached view as JSON.
pub const Preview = struct {
    call_id: []const u8,
    tool_name: []const u8,
    subject: []const u8 = "",
    body: []const u8 = "",
    body_kind: BodyKind = .text,
    /// Lines before `body` that the runtime no longer sends.
    earlier_lines: u32 = 0,

    pub fn dupe(self: Preview, alloc: std.mem.Allocator) !Preview {
        const call_id = try alloc.dupe(u8, self.call_id);
        errdefer alloc.free(call_id);
        const tool_name = try alloc.dupe(u8, self.tool_name);
        errdefer alloc.free(tool_name);
        const subject = try alloc.dupe(u8, self.subject);
        errdefer alloc.free(subject);
        const body = try alloc.dupe(u8, self.body);
        return .{
            .call_id = call_id,
            .tool_name = tool_name,
            .subject = subject,
            .body = body,
            .body_kind = self.body_kind,
            .earlier_lines = self.earlier_lines,
        };
    }

    pub fn deinit(self: Preview, alloc: std.mem.Allocator) void {
        alloc.free(self.call_id);
        alloc.free(self.tool_name);
        alloc.free(self.subject);
        alloc.free(self.body);
    }
};

/// The most body bytes a preview carries; the display shows fewer lines.
pub const body_capacity: usize = 2048;
pub const subject_capacity: usize = 256;

/// The display's copy of the newest preview, in fixed storage so the stream
/// state stays a plain value. `version` changes whenever the content does,
/// so a renderer can cache its rows.
pub const Tail = struct {
    call_id_buf: [128]u8 = undefined,
    call_id_len: usize = 0,
    tool_name_buf: [64]u8 = undefined,
    tool_name_len: usize = 0,
    subject_buf: [subject_capacity]u8 = undefined,
    subject_len: usize = 0,
    body_buf: [body_capacity]u8 = undefined,
    body_len: usize = 0,
    body_kind: BodyKind = .text,
    earlier_lines: u32 = 0,
    active: bool = false,
    version: u32 = 0,

    pub fn callId(self: *const Tail) []const u8 {
        return self.call_id_buf[0..self.call_id_len];
    }

    pub fn toolName(self: *const Tail) []const u8 {
        return self.tool_name_buf[0..self.tool_name_len];
    }

    pub fn subject(self: *const Tail) []const u8 {
        return self.subject_buf[0..self.subject_len];
    }

    pub fn body(self: *const Tail) []const u8 {
        return self.body_buf[0..self.body_len];
    }

    /// Replaces the shown call with `preview`. Terminal-unsafe bytes are
    /// blanked so a streamed argument cannot drive the terminal.
    pub fn apply(self: *Tail, preview: Preview) void {
        self.call_id_len = copyHead(&self.call_id_buf, preview.call_id);
        self.tool_name_len = copyHead(&self.tool_name_buf, preview.tool_name);
        self.subject_len = copyHead(&self.subject_buf, preview.subject);
        var source = preview.body;
        var dropped: u32 = 0;
        if (source.len > body_capacity) {
            source = source[source.len - body_capacity ..];
            while (source.len > 0 and (source[0] & 0xc0) == 0x80) source = source[1..];
            // The cut line is partial; drop it whole.
            if (std.mem.findScalar(u8, source, '\n')) |newline| source = source[newline + 1 ..];
            dropped = @intCast(@min(std.math.maxInt(u32), std.mem.count(u8, preview.body[0 .. preview.body.len - source.len], "\n")));
        }
        @memcpy(self.body_buf[0..source.len], source);
        self.body_len = source.len;
        _ = text_utils.blankTerminalUnsafe(self.body_buf[0..self.body_len]);
        _ = text_utils.blankTerminalUnsafe(self.subject_buf[0..self.subject_len]);
        self.body_kind = preview.body_kind;
        self.earlier_lines = preview.earlier_lines +| dropped;
        self.active = true;
        self.version +%= 1;
    }

    /// Hides the preview: the call started, or the step or turn moved on.
    /// True when something was shown.
    pub fn clear(self: *Tail) bool {
        if (!self.active) return false;
        self.active = false;
        self.version +%= 1;
        return true;
    }

    fn copyHead(dest: []u8, source: []const u8) usize {
        var len = @min(dest.len, source.len);
        while (len > 0 and len < source.len and (source[len] & 0xc0) == 0x80) len -= 1;
        @memcpy(dest[0..len], source[0..len]);
        return len;
    }
};

test "a tail keeps the newest body lines and counts the ones it drops" {
    var tail: Tail = .{};
    try std.testing.expect(!tail.clear());
    tail.apply(.{ .call_id = "c1", .tool_name = "shell", .body = "ls\x1b[2J", .body_kind = .command });
    try std.testing.expect(tail.active);
    try std.testing.expectEqualStrings("shell", tail.toolName());
    try std.testing.expect(std.mem.findScalar(u8, tail.body(), 0x1b) == null);
    const version = tail.version;

    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(std.testing.allocator);
    for (0..400) |index| try long.print(std.testing.allocator, "line {d}\n", .{index});
    tail.apply(.{ .call_id = "c2", .tool_name = "write_file", .subject = "a.txt", .body = long.items, .body_kind = .content, .earlier_lines = 10 });
    try std.testing.expect(tail.version != version);
    try std.testing.expect(tail.body().len <= body_capacity);
    try std.testing.expect(std.mem.startsWith(u8, tail.body(), "line "));
    try std.testing.expect(std.mem.endsWith(u8, tail.body(), "line 399\n"));
    const kept = std.mem.count(u8, tail.body(), "\n");
    try std.testing.expectEqual(@as(u32, @intCast(400 - kept + 10)), tail.earlier_lines);
    try std.testing.expect(tail.clear());
    try std.testing.expect(!tail.active);
}
