//! Reader-owned copies keep application events and cooperative pulses on the requesting thread.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const streams = @import("../agent/stream_provider.zig");

const Allocator = std.mem.Allocator;
const notification_method = "extension.event";
const max_pending_events = 64;
const max_pending_payload_bytes = 256 * 1024;
const max_delta_bytes = 64 * 1024;
const max_identifier_bytes = 1024;
const terminal_delete_byte = 0x7f;

const Kind = enum { content_delta, reasoning_delta, tool_started, tool_input_delta };
const WireEvent = struct {
    request_id: u64,
    handle: []const u8,
    type: Kind,
    delta: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

/// The caller clears its notification sink before releasing this borrowed request scope.
pub const Handoff = struct {
    alloc: Allocator,
    request_id: u64,
    handle: []const u8,
    sink: streams.EventSink,
    pulse: ?streams.CooperativePulse,
    mutex: std.Io.Mutex = .init,
    capacity_changed: std.Io.Condition = .init,
    stopped: bool = false,
    pending: std.ArrayList(std.json.Parsed(WireEvent)) = .empty,
    pending_bytes: usize = 0,
    failure: ?anyerror = null,
    content_seen: bool = false,
    content_bytes: usize = 0,
    content_hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    active_tool_id: ?[]u8 = null,

    /// Only the owner thread destroys copied events after the reader sink becomes quiescent.
    pub fn deinit(self: *Handoff) void {
        for (self.pending.items) |*event| event.deinit();
        self.pending.deinit(self.alloc);
        if (self.active_tool_id) |id| self.alloc.free(id);
    }

    /// The reader never invokes application callbacks or retains dispatcher parser storage.
    pub fn on_notification(raw: *anyopaque, message: std.json.Value) void {
        const self: *Handoff = @ptrCast(@alignCast(raw));
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.stopped or self.failure != null) return;
        self.capture(message) catch |err| {
            self.failure = err;
        };
    }

    /// The waiter moves ownership before emitting so the reader cannot hold an application lock.
    pub fn on_wait(raw: *anyopaque) !void {
        const self: *Handoff = @ptrCast(@alignCast(raw));
        try self.drain();
        if (self.pulse) |pulse| try pulse.pulse();
    }

    /// The owner releases backpressure before removing a sink or awaiting a cancellation reply.
    pub fn stop(self: *Handoff) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.stopped = true;
        self.capacity_changed.broadcast(io_mod.getIo());
    }

    /// A final drain closes the race between the last notification and response publication.
    pub fn drain(self: *Handoff) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.failure) |err| {
            self.mutex.unlock(io_mod.getIo());
            return err;
        }
        var batch = self.pending;
        self.pending = .empty;
        self.pending_bytes = 0;
        self.capacity_changed.signal(io_mod.getIo());
        self.mutex.unlock(io_mod.getIo());
        defer batch.deinit(self.alloc);
        defer for (batch.items) |*event| event.deinit();
        for (batch.items) |event| try self.emit(event.value);
        self.sink.flush();
    }

    /// Buffered completion text must agree with content already exposed to the human.
    pub fn validate_content(self: *const Handoff, content: ?[]const u8) !void {
        if (!self.content_seen) return;
        const text = content orelse return error.ExtensionEventContentMismatch;
        if (text.len != self.content_bytes) return error.ExtensionEventContentMismatch;
        var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &expected, .{});
        var observed: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        var state = self.content_hash;
        state.final(&observed);
        if (!std.mem.eql(u8, &observed, &expected)) return error.ExtensionEventContentMismatch;
    }

    /// Stale request frames never acquire storage or influence the active transcript.
    fn capture(self: *Handoff, message: std.json.Value) !void {
        if (message != .object) return error.ExtensionEventInvalid;
        const method = message.object.get("method") orelse return error.ExtensionEventInvalid;
        if (method != .string) return error.ExtensionEventInvalid;
        if (!std.mem.eql(u8, method.string, notification_method)) return;
        const params = message.object.get("params") orelse return error.ExtensionEventInvalid;
        if (params != .object) return error.ExtensionEventInvalid;
        const request_id = params.object.get("request_id") orelse return error.ExtensionEventInvalid;
        if (request_id != .integer or request_id.integer < 0) return error.ExtensionEventInvalid;
        if (@as(u64, @intCast(request_id.integer)) != self.request_id) return;
        var parsed = std.json.parseFromValue(WireEvent, self.alloc, params, .{ .allocate = .alloc_always }) catch |err| {
            return if (err == error.OutOfMemory) err else error.ExtensionEventInvalid;
        };
        errdefer parsed.deinit();
        const event = parsed.value;
        if (!std.mem.eql(u8, event.handle, self.handle)) return error.ExtensionEventCorrelationInvalid;
        const payload_bytes = try validate(event);
        if (payload_bytes > max_pending_payload_bytes) return error.ExtensionEventOverflow;
        // Pausing the reader propagates pressure to the pipe without discarding valid provider output.
        while (!self.stopped and (self.pending.items.len >= max_pending_events or payload_bytes > max_pending_payload_bytes - self.pending_bytes)) {
            self.capacity_changed.waitUncancelable(io_mod.getIo(), &self.mutex);
        }
        if (self.stopped) {
            parsed.deinit();
            return;
        }
        try self.pending.append(self.alloc, parsed);
        self.pending_bytes += payload_bytes;
    }

    /// Tool deltas cannot borrow another tool's active identity.
    fn emit(self: *Handoff, event: WireEvent) !void {
        switch (event.type) {
            .content_delta => {
                self.content_seen = true;
                self.content_bytes = std.math.add(usize, self.content_bytes, event.delta.?.len) catch return error.ExtensionEventOverflow;
                self.content_hash.update(event.delta.?);
                self.sink.emit(.{ .content_delta = event.delta.? });
            },
            .reasoning_delta => self.sink.emit(.{ .reasoning_delta = event.delta.? }),
            .tool_started => {
                const id = try self.alloc.dupe(u8, event.id.?);
                if (self.active_tool_id) |previous| self.alloc.free(previous);
                self.active_tool_id = id;
                self.sink.emit(.{ .tool_started = .{ .id = event.id.?, .name = event.name.?, .label = event.label } });
            },
            .tool_input_delta => {
                const active = self.active_tool_id orelse return error.ExtensionEventCorrelationInvalid;
                if (!std.mem.eql(u8, active, event.id.?)) return error.ExtensionEventCorrelationInvalid;
                self.sink.emit(.{ .tool_input_delta = event.delta.? });
            },
        }
    }
};

/// Reject malformed shapes before any untrusted value can reach transcript or tool activity state.
fn validate(event: WireEvent) !usize {
    var bytes: usize = event.handle.len;
    for ([_]?[]const u8{ event.id, event.name, event.label }) |value| if (value) |text| {
        if (text.len == 0 or text.len > max_identifier_bytes) return error.ExtensionEventInvalid;
        for (text) |byte| if (std.ascii.isControl(byte) or byte == terminal_delete_byte) return error.ExtensionEventInvalid;
        bytes += text.len;
    };
    if (event.delta) |text| {
        if (text.len > max_delta_bytes) return error.ExtensionEventOverflow;
        bytes += text.len;
    }
    switch (event.type) {
        .content_delta, .reasoning_delta => if (event.delta == null or event.id != null or event.name != null or event.label != null) return error.ExtensionEventInvalid,
        .tool_started => if (event.id == null or event.name == null or event.delta != null) return error.ExtensionEventInvalid,
        .tool_input_delta => if (event.id == null or event.delta == null or event.name != null or event.label != null) return error.ExtensionEventInvalid,
    }
    return bytes;
}
