const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const jsonrpc = @import("jsonrpc.zig");
const text_utils = @import("../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const RequestId = jsonrpc.RequestId;

pub const max_message_bytes: usize = 64 * 1024;
pub const max_messages: usize = 64;
pub const max_queued_bytes: usize = 1024 * 1024;

const max_input_id_bytes: usize = 128;

pub const EnqueueError = Allocator.Error || error{
    EmptySteeringMessage,
    SteeringMessageTooLarge,
    SteeringQueueFull,
    SteeringNotActive,
};

/// A libfx input id that is malformed or already queued.
const InputError = EnqueueError || error{InvalidInputId};

const Entry = struct {
    text: []u8,
    /// The ACP `session/prompt` request that carried the text, answered when
    /// the turn that absorbed it ends. libfx steering carries no request.
    request_id: ?RequestId = null,
    /// The libfx input id a journaled session records the text under.
    input_id: ?[]u8 = null,
};

/// Steering drained at one boundary, allocated in the caller's allocator.
pub const Drained = struct {
    texts: [][]u8,
    request_ids: []?RequestId,
    input_ids: []?[]u8 = &.{},
};

/// A libfx input id: 1 to 128 letters, digits, `.`, `_`, or `-`.
pub fn validInputId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_input_id_bytes) return false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') return false;
    }
    return true;
}

/// Requests to answer when a turn ends. Allocated in the caller's allocator.
pub const Finished = struct {
    /// Steering the turn delivered to the model.
    absorbed: []RequestId,
    /// Steering still queued when the turn stopped taking input.
    dropped: []RequestId,

    pub fn deinit(self: Finished, alloc: Allocator) void {
        freeRequestIds(alloc, self.absorbed);
        freeRequestIds(alloc, self.dropped);
    }
};

/// Owns bounded steering text shared by the ACP reader and prompt worker.
pub const Runtime = struct {
    mutex: std.Io.Mutex = .init,
    messages: std.ArrayList(Entry) = .empty,
    absorbed: std.ArrayList(RequestId) = .empty,
    queued_bytes: usize = 0,
    accepting: bool = false,

    pub fn open(self: *Runtime, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.clearLocked(alloc, "new_turn");
        self.accepting = true;
    }

    pub fn enqueue(self: *Runtime, alloc: Allocator, text: []const u8) EnqueueError!void {
        return self.enqueueRequest(alloc, text, null);
    }

    /// Queues a libfx input under `input_id`, which no queued entry may share.
    pub fn enqueueInput(self: *Runtime, alloc: Allocator, text: []const u8, input_id: []const u8) InputError!void {
        if (!validInputId(input_id)) return error.InvalidInputId;
        return self.enqueueEntry(alloc, text, null, input_id);
    }

    /// Removes the queued input `input_id`. False when it is not queued: the
    /// turn already took it for a model request, or it never arrived.
    pub fn withdraw(self: *Runtime, alloc: Allocator, input_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.messages.items, 0..) |entry, index| {
            const id = entry.input_id orelse continue;
            if (!std.mem.eql(u8, id, input_id)) continue;
            const removed = self.messages.orderedRemove(index);
            self.queued_bytes -= removed.text.len;
            freeEntry(alloc, removed);
            return true;
        }
        return false;
    }

    /// Queues text for the running turn. A supplied request ID is copied and
    /// reported by `finishTurn`.
    pub fn enqueueRequest(
        self: *Runtime,
        alloc: Allocator,
        text: []const u8,
        request_id: ?RequestId,
    ) EnqueueError!void {
        return self.enqueueEntry(alloc, text, request_id, null) catch |err| switch (err) {
            // Only an input id can be invalid, and none is given here.
            error.InvalidInputId => unreachable,
            else => |other| other,
        };
    }

    fn enqueueEntry(
        self: *Runtime,
        alloc: Allocator,
        text: []const u8,
        request_id: ?RequestId,
        input_id: ?[]const u8,
    ) InputError!void {
        if (text.len == 0) return error.EmptySteeringMessage;
        if (text.len > max_message_bytes) return error.SteeringMessageTooLarge;

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.accepting) return error.SteeringNotActive;
        if (self.messages.items.len >= max_messages or
            self.queued_bytes > max_queued_bytes - text.len)
        {
            return error.SteeringQueueFull;
        }
        if (input_id) |id| {
            for (self.messages.items) |entry| {
                if (entry.input_id) |queued| if (std.mem.eql(u8, queued, id)) return error.InvalidInputId;
            }
        }
        try self.messages.ensureUnusedCapacity(alloc, 1);
        try self.absorbed.ensureTotalCapacity(alloc, self.absorbed.items.len + self.messages.items.len + 1);
        const owned = try alloc.dupe(u8, text);
        errdefer alloc.free(owned);
        const owned_input = if (input_id) |id| try alloc.dupe(u8, id) else null;
        errdefer if (owned_input) |id| alloc.free(id);
        const owned_id = if (request_id) |id| try dupeRequestId(alloc, id) else null;
        self.messages.appendAssumeCapacity(.{ .text = owned, .request_id = owned_id, .input_id = owned_input });
        self.queued_bytes += owned.len;
    }

    /// Returns result-allocator-owned text and releases the queue-owned copies.
    pub fn takeAll(
        self: *Runtime,
        backing: Allocator,
        result_alloc: Allocator,
        close_if_empty: bool,
    ) Allocator.Error!Drained {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.messages.items.len == 0) {
            if (close_if_empty) self.accepting = false;
            return .{ .texts = &.{}, .request_ids = &.{} };
        }

        const count = self.messages.items.len;
        const texts = try result_alloc.alloc([]u8, count);
        errdefer result_alloc.free(texts);
        const request_ids = try result_alloc.alloc(?RequestId, count);
        errdefer result_alloc.free(request_ids);
        const input_ids = try result_alloc.alloc(?[]u8, count);
        errdefer result_alloc.free(input_ids);
        var copied: usize = 0;
        errdefer for (0..copied) |index| {
            result_alloc.free(texts[index]);
            if (request_ids[index]) |id| freeRequestId(result_alloc, id);
            if (input_ids[index]) |id| result_alloc.free(id);
        };
        for (self.messages.items, 0..) |entry, index| {
            texts[index] = try result_alloc.dupe(u8, entry.text);
            errdefer result_alloc.free(texts[index]);
            input_ids[index] = if (entry.input_id) |id| try result_alloc.dupe(u8, id) else null;
            errdefer if (input_ids[index]) |id| result_alloc.free(id);
            request_ids[index] = if (entry.request_id) |id| try dupeRequestId(result_alloc, id) else null;
            copied += 1;
        }
        // Capacity for every queued request was reserved at enqueue.
        for (self.messages.items) |entry| {
            backing.free(entry.text);
            if (entry.input_id) |id| backing.free(id);
            if (entry.request_id) |id| self.absorbed.appendAssumeCapacity(id);
        }
        self.messages.clearRetainingCapacity();
        self.queued_bytes = 0;
        return .{ .texts = texts, .request_ids = request_ids, .input_ids = input_ids };
    }

    /// Stops accepting steering for the finished turn and reports which
    /// requests it absorbed or dropped. Dropped text is released.
    pub fn finishTurn(
        self: *Runtime,
        backing: Allocator,
        result_alloc: Allocator,
        reason: []const u8,
    ) Allocator.Error!Finished {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.accepting = false;

        var dropped_count: usize = 0;
        for (self.messages.items) |entry| {
            if (entry.request_id != null) dropped_count += 1;
        }
        const absorbed = try result_alloc.alloc(RequestId, self.absorbed.items.len);
        errdefer result_alloc.free(absorbed);
        const dropped = try result_alloc.alloc(RequestId, dropped_count);
        errdefer result_alloc.free(dropped);
        var copied_absorbed: usize = 0;
        errdefer freeRequestIdItems(result_alloc, absorbed[0..copied_absorbed]);
        for (self.absorbed.items, 0..) |id, index| {
            absorbed[index] = try dupeRequestId(result_alloc, id);
            copied_absorbed += 1;
        }
        var copied_dropped: usize = 0;
        errdefer freeRequestIdItems(result_alloc, dropped[0..copied_dropped]);
        for (self.messages.items) |entry| {
            const id = entry.request_id orelse continue;
            dropped[copied_dropped] = try dupeRequestId(result_alloc, id);
            copied_dropped += 1;
        }
        self.clearLocked(backing, reason);
        return .{ .absorbed = absorbed, .dropped = dropped };
    }

    pub fn close(self: *Runtime, alloc: Allocator, reason: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.accepting = false;
        self.clearLocked(alloc, reason);
    }

    pub fn clear(self: *Runtime, alloc: Allocator, reason: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.clearLocked(alloc, reason);
    }

    fn clearLocked(self: *Runtime, alloc: Allocator, reason: []const u8) void {
        if (self.messages.items.len > 0) {
            debug_trace.logf(
                "acp",
                "dropped steering messages={d} bytes={d} reason={s}",
                .{ self.messages.items.len, self.queued_bytes, reason },
            );
        }
        for (self.messages.items) |entry| freeEntry(alloc, entry);
        self.messages.clearRetainingCapacity();
        freeRequestIdItems(alloc, self.absorbed.items);
        self.absorbed.clearRetainingCapacity();
        self.queued_bytes = 0;
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.close(alloc, "runtime_deinit");
        self.messages.deinit(alloc);
        self.absorbed.deinit(alloc);
        self.* = .{};
    }
};

pub fn freeDrained(alloc: Allocator, drained: Drained) void {
    for (drained.texts) |text| alloc.free(text);
    if (drained.texts.len > 0) alloc.free(drained.texts);
    for (drained.request_ids) |maybe_id| if (maybe_id) |id| freeRequestId(alloc, id);
    if (drained.request_ids.len > 0) alloc.free(drained.request_ids);
    for (drained.input_ids) |maybe_id| if (maybe_id) |id| alloc.free(id);
    if (drained.input_ids.len > 0) alloc.free(drained.input_ids);
}

fn freeEntry(alloc: Allocator, entry: Entry) void {
    alloc.free(entry.text);
    if (entry.request_id) |id| freeRequestId(alloc, id);
    if (entry.input_id) |id| alloc.free(id);
}

fn dupeRequestId(alloc: Allocator, id: RequestId) Allocator.Error!RequestId {
    return switch (id) {
        .integer => |value| .{ .integer = value },
        .string => |value| .{ .string = try alloc.dupe(u8, value) },
        .null => .null,
    };
}

fn freeRequestId(alloc: Allocator, id: RequestId) void {
    switch (id) {
        .string => |value| alloc.free(value),
        .integer, .null => {},
    }
}

fn freeRequestIdItems(alloc: Allocator, ids: []const RequestId) void {
    for (ids) |id| freeRequestId(alloc, id);
}

fn freeRequestIds(alloc: Allocator, ids: []RequestId) void {
    freeRequestIdItems(alloc, ids);
    alloc.free(ids);
}

test "libfx steering runtime preserves order and releases drained storage" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.open(alloc);

    try runtime.enqueue(alloc, "first");
    try runtime.enqueue(alloc, "second");
    const drained = try runtime.takeAll(alloc, alloc, false);
    defer freeDrained(alloc, drained);
    try std.testing.expectEqual(@as(usize, 2), drained.texts.len);
    try std.testing.expectEqualStrings("first", drained.texts[0]);
    try std.testing.expectEqualStrings("second", drained.texts[1]);
    try std.testing.expect(drained.request_ids[0] == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.queued_bytes);
}

test "libfx steering runtime bounds each message and total queue" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.open(alloc);

    try std.testing.expectError(error.EmptySteeringMessage, runtime.enqueue(alloc, ""));
    const oversized = try alloc.alloc(u8, max_message_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.SteeringMessageTooLarge, runtime.enqueue(alloc, oversized));

    const message = text_utils.repeat("x", max_queued_bytes / max_messages);
    for (0..max_messages) |_| try runtime.enqueue(alloc, message);
    try std.testing.expectError(error.SteeringQueueFull, runtime.enqueue(alloc, "overflow"));
    runtime.clear(alloc, "test");
    try std.testing.expectEqual(@as(usize, 0), runtime.queued_bytes);
}

test "steering runtime reports absorbed and dropped prompt requests when a turn ends" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    try std.testing.expectError(error.SteeringNotActive, runtime.enqueueRequest(alloc, "early", .{ .integer = 1 }));
    runtime.open(alloc);
    try runtime.enqueueRequest(alloc, "the other tab", .{ .string = "steer-1" });
    const drained = try runtime.takeAll(alloc, alloc, false);
    defer freeDrained(alloc, drained);
    try std.testing.expectEqualStrings("the other tab", drained.texts[0]);
    try std.testing.expectEqualStrings("steer-1", drained.request_ids[0].?.string);

    try runtime.enqueueRequest(alloc, "just summarize", .{ .integer = 7 });
    const finished = try runtime.finishTurn(alloc, alloc, "test");
    defer finished.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), finished.absorbed.len);
    try std.testing.expectEqualStrings("steer-1", finished.absorbed[0].string);
    try std.testing.expectEqual(@as(usize, 1), finished.dropped.len);
    try std.testing.expectEqual(@as(i64, 7), finished.dropped[0].integer);
    try std.testing.expectError(error.SteeringNotActive, runtime.enqueueRequest(alloc, "late", .{ .integer = 8 }));
    try std.testing.expectEqual(@as(usize, 0), runtime.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.absorbed.items.len);
}

test "libfx steering withdraws a queued input until the turn takes it" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.open(alloc);

    try std.testing.expectError(error.InvalidInputId, runtime.enqueueInput(alloc, "text", "bad id"));
    try runtime.enqueueInput(alloc, "use tabs", "in_1");
    try runtime.enqueueInput(alloc, "skip tests", "in_2");
    try std.testing.expectError(error.InvalidInputId, runtime.enqueueInput(alloc, "again", "in_2"));
    try runtime.enqueueInput(alloc, "be brief", "in_3");
    try std.testing.expect(runtime.withdraw(alloc, "in_2"));
    try std.testing.expect(!runtime.withdraw(alloc, "in_2"));
    try std.testing.expectEqual(@as(usize, "use tabs".len + "be brief".len), runtime.queued_bytes);

    const drained = try runtime.takeAll(alloc, alloc, false);
    defer freeDrained(alloc, drained);
    try std.testing.expectEqual(@as(usize, 2), drained.texts.len);
    try std.testing.expectEqualStrings("in_1", drained.input_ids[0].?);
    try std.testing.expectEqualStrings("be brief", drained.texts[1]);
    try std.testing.expectEqualStrings("in_3", drained.input_ids[1].?);
    // Taken for a model request: too late to withdraw.
    try std.testing.expect(!runtime.withdraw(alloc, "in_1"));
}
