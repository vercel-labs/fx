//! Bounded, work-local transport of native child presentation callbacks.
//! Durable turns remain the history authority; this tail exists only while a
//! managed work slot runs and never contains credentials or permission grants.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const Allocator = std.mem.Allocator;

pub const byte_limit = 512 * 1024;
pub const event_limit = 1024;
const frame_limit = 64 * 1024;
/// One encoded frame, kept as the exact JSON object a snapshot lists.
const Frame = struct { sequence: u64, json: []u8 };

/// The wire shape of one frame: a cursor sequence and either streamed text or
/// a projected presentation event.
const WireFrame = struct {
    sequence: u64,
    text: ?[]const u8 = null,
    event: ?PresentationEvent = null,

    /// A frame names only the part it carries, but its event keeps every
    /// field, null ones too: the viewer parses it as the root lane's
    /// events, whose optional fields have no defaults.
    pub fn jsonStringify(self: WireFrame, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("sequence");
        try jw.write(self.sequence);
        if (self.text) |text| {
            try jw.objectField("text");
            try jw.write(text);
        }
        if (self.event) |event| {
            try jw.objectField("event");
            try jw.write(event);
        }
        try jw.endObject();
    }
};

pub const Snapshot = struct {
    sequence: u64 = 0,
    oldest_sequence: u64 = 1,
    reset: bool = false,
    events_json: []const u8 = "[]",
};

pub const Tail = struct {
    mutex: std.Io.Mutex = .init,
    /// Oldest first; the oldest frames drop when a limit is reached.
    frames: std.Deque(Frame) = .empty,
    bytes: usize = 0,
    sequence: u64 = 0,
    scratch: []u8 = &.{},

    pub fn deinit(self: *Tail, alloc: Allocator) void {
        self.clear(alloc);
        self.frames.deinit(alloc);
        if (self.scratch.len > 0) alloc.free(self.scratch);
        self.* = .{};
    }

    fn clear(self: *Tail, alloc: Allocator) void {
        while (self.frames.popFront()) |frame| alloc.free(frame.json);
        self.bytes = 0;
    }

    pub fn appendText(self: *Tail, alloc: Allocator, text: []const u8) void {
        if (text.len == 0) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.appendLocked(alloc, .{ .sequence = self.sequence + 1, .text = text });
    }

    pub fn appendEvent(self: *Tail, alloc: Allocator, event: worker_runtime.WorkerEvent) void {
        // Payloads are borrowed only for this call. Serialize before the native
        // callback returns and releases them; never enqueue raw event pointers.
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const projected = project(event) orelse return;
        self.appendLocked(alloc, .{ .sequence = self.sequence + 1, .event = projected });
    }

    fn appendLocked(self: *Tail, alloc: Allocator, frame: WireFrame) void {
        self.sequence = frame.sequence;
        while (true) {
            if (self.scratch.len == 0) self.scratch = alloc.alloc(u8, 4096) catch {
                self.clear(alloc);
                return;
            };
            var writer: std.Io.Writer = .fixed(self.scratch);
            std.json.Stringify.value(frame, .{}, &writer) catch {
                if (self.scratch.len == frame_limit) {
                    // An oversized event creates an explicit cursor gap, not
                    // unbounded allocations or a partially encoded payload.
                    self.clear(alloc);
                    return;
                }
                const next = alloc.alloc(u8, @min(self.scratch.len * 2, frame_limit)) catch {
                    self.clear(alloc);
                    return;
                };
                alloc.free(self.scratch);
                self.scratch = next;
                continue;
            };
            const json = alloc.dupe(u8, writer.buffered()) catch {
                self.clear(alloc);
                return;
            };
            while (self.frames.len >= event_limit or self.bytes + json.len > byte_limit) {
                const old = self.frames.popFront().?;
                self.bytes -= old.json.len;
                alloc.free(old.json);
            }
            self.frames.pushBack(alloc, .{ .sequence = frame.sequence, .json = json }) catch {
                alloc.free(json);
                self.clear(alloc);
                return;
            };
            self.bytes += json.len;
            return;
        }
    }

    /// Caller owns the encoded snapshot in its request arena. Taking it never
    /// consumes another viewer's cursor or the running child's output.
    pub fn snapshot(self: *Tail, alloc: Allocator, after: u64, force_reset: bool) !Snapshot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const oldest = if (self.frames.front()) |frame| frame.sequence else self.sequence + 1;
        const reset = force_reset or after > self.sequence or after < oldest - 1;
        var writer: std.Io.Writer.Allocating = .init(alloc);
        defer writer.deinit();
        try writer.writer.writeByte('[');
        var comma = false;
        var frames = self.frames.iterator();
        while (frames.next()) |frame| {
            if (!reset and frame.sequence <= after) continue;
            if (comma) try writer.writer.writeByte(',');
            comma = true;
            try writer.writer.writeAll(frame.json);
        }
        try writer.writer.writeByte(']');
        return .{ .sequence = self.sequence, .oldest_sequence = oldest, .reset = reset, .events_json = try writer.toOwnedSlice() };
    }
};

// Deliberately excludes finish_prompt (durable history), credentials, grants,
// notifications, and full_detail_record (not a transcript event).
pub const PresentationEvent = union(enum) {
    assistant_presentation: @FieldType(worker_runtime.WorkerEvent, "assistant_presentation"),
    tool_lifecycle: @FieldType(worker_runtime.WorkerEvent, "tool_lifecycle"),
    command_output: @FieldType(worker_runtime.WorkerEvent, "command_output"),
    command_output_complete: @FieldType(worker_runtime.WorkerEvent, "command_output_complete"),
    turn_phase_update: @FieldType(worker_runtime.WorkerEvent, "turn_phase_update"),
    turn_token_update: @FieldType(worker_runtime.WorkerEvent, "turn_token_update"),
    route_recovery_status: @FieldType(worker_runtime.WorkerEvent, "route_recovery_status"),
    clear_route_recovery_status,
    semantic_notice: @FieldType(worker_runtime.WorkerEvent, "semantic_notice"),
    error_text: @FieldType(worker_runtime.WorkerEvent, "error_text"),
    diff_block: @FieldType(worker_runtime.WorkerEvent, "diff_block"),
    append_user_feedback: @FieldType(worker_runtime.WorkerEvent, "append_user_feedback"),
};

/// Borrowed projection shared by native root and child transports. Serialize
/// synchronously; callers retain ownership of the original WorkerEvent.
pub fn project(event: worker_runtime.WorkerEvent) ?PresentationEvent {
    return switch (event) {
        inline .assistant_presentation,
        .tool_lifecycle,
        .command_output,
        .command_output_complete,
        .turn_phase_update,
        .turn_token_update,
        .route_recovery_status,
        .clear_route_recovery_status,
        .semantic_notice,
        .error_text,
        .diff_block,
        .append_user_feedback,
        => |payload, tag| @unionInit(PresentationEvent, @tagName(tag), payload),
        else => null,
    };
}

test "child live presentation owns in-flight events and bounds cursor replay" {
    const alloc = std.testing.allocator;
    var tail: Tail = .{};
    defer tail.deinit(alloc);
    var source = [_]u8{ 'l', 'i', 'v', 'e' };
    tail.appendText(alloc, &source);
    source[0] = 'x';
    tail.appendEvent(alloc, .{ .tool_lifecycle = .{ .authoritative_started = .{
        .id = .{ .turn_id = 1, .call_id = "shell-1" },
        .reconciles_provisional_call_id = null,
        .tool_name = "shell",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf live; sleep 5\"}",
    } } });
    tail.appendEvent(alloc, .{ .command_output = .{ .lifecycle_id = .{ .turn_id = 1, .call_id = "shell-1" }, .stream = .stdout, .text = @constCast("running now") } });
    tail.appendEvent(alloc, .open_model_picker);
    tail.appendEvent(alloc, .{ .session_grant = .{ .tool_name = @constCast("private-grant"), .target_path = @constCast("not-for-transcript") } });
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const first = try tail.snapshot(arena.allocator(), 0, true);
    try std.testing.expectEqual(@as(u64, 3), first.sequence);
    try std.testing.expect(std.mem.startsWith(u8, first.events_json, "[{\"sequence\":1,\"text\":\"live\"},{\"sequence\":2,\"event\":{"));
    try std.testing.expect(std.mem.find(u8, first.events_json, "authoritative_started") != null);
    // The viewer's parser needs the event's null fields.
    try std.testing.expect(std.mem.find(u8, first.events_json, "\"reconciles_provisional_call_id\":null") != null);
    try std.testing.expect(std.mem.find(u8, first.events_json, "running now") != null);
    const unchanged = try tail.snapshot(arena.allocator(), first.sequence, false);
    try std.testing.expectEqualStrings("[]", unchanged.events_json);
    try std.testing.expect(!unchanged.reset);
    for (0..event_limit + 1) |_| tail.appendText(alloc, "next");
    try std.testing.expectEqual(event_limit, tail.frames.len);
    try std.testing.expect(tail.bytes <= byte_limit);
    const gap = try tail.snapshot(arena.allocator(), 1, false);
    try std.testing.expect(gap.reset);
    try std.testing.expect(gap.oldest_sequence > 1);
    const large: [16 * 1024]u8 = @splat('a');
    for (0..40) |_| tail.appendText(alloc, &large);
    try std.testing.expect(tail.bytes <= byte_limit);
    try std.testing.expect(tail.frames.len < 40);
    const oversized: [frame_limit + 1]u8 = @splat('b');
    tail.appendText(alloc, &oversized);
    try std.testing.expectEqual(@as(usize, 0), tail.frames.len);
    try std.testing.expect(tail.scratch.len <= frame_limit);
    const skipped = try tail.snapshot(arena.allocator(), first.sequence, false);
    try std.testing.expect(skipped.reset);
    try std.testing.expectEqualStrings("[]", skipped.events_json);
}
