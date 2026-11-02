//! When a libfx steer interrupts, waits, joins, or hands off a turn. TLA+
//! model: `tests/tla/sdk/DurableSteer.tla`.

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

/// What the model is doing in the running turn's current step, as steering
/// sees it: streaming a reply it can cut short, or working on tool calls,
/// from the first streamed argument until the next step.
pub const Phase = enum { reply, tools };

/// Owns bounded steering text shared by the ACP reader and prompt worker.
///
/// For libfx it also decides when a steer interrupts the turn, as the fx
/// CLI does: a steer that arrives while the model streams a reply, with no
/// tool call in flight, cuts the reply short and the turn continues with it.
/// The steer sets the turn's cancel flag; the cancel boundary that follows
/// takes the steering and continues. A user cancel at any point wins. The
/// mutex orders every change to that flag made here.
pub const Runtime = struct {
    mutex: std.Io.Mutex = .init,
    messages: std.ArrayList(Entry) = .empty,
    absorbed: std.ArrayList(RequestId) = .empty,
    queued_bytes: usize = 0,
    accepting: bool = false,
    /// The current step and what it does; null before the first one.
    step: ?u64 = null,
    phase: Phase = .reply,
    /// Tool calls started and not ended, by call id. Owned by the
    /// allocator the runtime's callers pass.
    tool_calls: std.ArrayList([]u8) = .empty,
    /// A steer has set the cancel flag to interrupt the reply.
    interrupt_pending: bool = false,
    /// The user cancelled the turn: it takes no more steering.
    user_cancelled: bool = false,
    /// A steer that cannot join the turn, such as one with images, waits to
    /// run next: the turn ends at its next safe point.
    handoff_pending: bool = false,

    pub fn open(self: *Runtime, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.clearLocked(alloc, "new_turn");
        self.accepting = true;
        self.step = null;
        self.phase = .reply;
        self.clearToolCallsLocked(alloc);
        self.interrupt_pending = false;
        self.user_cancelled = false;
        self.handoff_pending = false;
    }

    /// Records what step `step` of the running turn does. Once a step works
    /// on tool calls it stays that way, as a reply that resumes text after a
    /// tool call's arguments still ends in that call. Sets `cancel_flag` and
    /// returns true when a queued steer should now cut the reply short.
    pub fn notePhase(self: *Runtime, step: u64, phase: Phase, cancel_flag: *std.atomic.Value(bool)) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.step != step) {
            self.step = step;
            self.phase = phase;
        } else if (phase == .tools) {
            self.phase = .tools;
        }
        return self.claimInterruptLocked(cancel_flag);
    }

    /// Records tool call `call_id` starting. If it cannot be tracked, the
    /// current step counts as working on tools, so no steer cuts it short.
    pub fn noteToolStarted(self: *Runtime, alloc: Allocator, call_id: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.tool_calls.items) |id| if (std.mem.eql(u8, id, call_id)) return;
        const owned = alloc.dupe(u8, call_id) catch return self.untrackedToolLocked();
        self.tool_calls.append(alloc, owned) catch {
            alloc.free(owned);
            return self.untrackedToolLocked();
        };
    }

    /// Records that the current step works on a tool call the model has
    /// announced, before its arguments or its run are known.
    pub fn noteToolsPhase(self: *Runtime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.step != null) self.phase = .tools;
    }

    fn untrackedToolLocked(self: *Runtime) void {
        debug_trace.logf("acp", "libfx steering could not track a tool call; the step waits for its boundary", .{});
        self.phase = .tools;
    }

    /// Records tool call `call_id` ending. A call never started is ignored.
    pub fn noteToolEnded(self: *Runtime, alloc: Allocator, call_id: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.tool_calls.items, 0..) |id, index| {
            if (!std.mem.eql(u8, id, call_id)) continue;
            alloc.free(self.tool_calls.swapRemove(index));
            return;
        }
    }

    fn clearToolCallsLocked(self: *Runtime, alloc: Allocator) void {
        for (self.tool_calls.items) |id| alloc.free(id);
        self.tool_calls.clearRetainingCapacity();
    }

    /// Called after a steer is queued: sets `cancel_flag` and returns true
    /// when the steer should cut the streaming reply short.
    pub fn claimInterrupt(self: *Runtime, cancel_flag: *std.atomic.Value(bool)) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.claimInterruptLocked(cancel_flag);
    }

    /// For a host that keeps the steering queue itself, as the web core's
    /// does, with `queued` steers in it: sets `cancel_flag` and returns true
    /// when they should cut the streaming reply short.
    pub fn claimHostInterrupt(self: *Runtime, queued: usize, cancel_flag: *std.atomic.Value(bool)) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.claimInterruptForLocked(queued > 0, cancel_flag);
    }

    /// A boundary of a turn whose host keeps the steering queue: until the
    /// next step streams, nothing is cut short.
    pub fn noteBoundary(self: *Runtime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.step = null;
    }

    fn claimInterruptLocked(self: *Runtime, cancel_flag: *std.atomic.Value(bool)) bool {
        return self.claimInterruptForLocked(self.messages.items.len > 0 or self.handoff_pending, cancel_flag);
    }

    /// A steer that cannot join the turn, such as one with images, asks the
    /// turn to end at its next safe point so it can run next, as the fx CLI
    /// hands off: at once while the model streams a reply, else at the next
    /// boundary. Returns true when it interrupts the reply now. A turn that
    /// takes no more steering is ending anyway, and the request does nothing.
    pub fn requestHandoff(self: *Runtime, cancel_flag: *std.atomic.Value(bool)) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.accepting or self.user_cancelled) return false;
        self.handoff_pending = true;
        return self.claimInterruptLocked(cancel_flag);
    }

    /// Whether the turn should end at this boundary for a handoff.
    pub fn handoffPending(self: *Runtime) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.handoff_pending and !self.user_cancelled;
    }

    fn claimInterruptForLocked(self: *Runtime, steering_queued: bool, cancel_flag: *std.atomic.Value(bool)) bool {
        if (!self.accepting or self.user_cancelled or self.interrupt_pending) return false;
        if (self.step == null or self.phase != .reply or self.tool_calls.items.len > 0) return false;
        if (!steering_queued) return false;
        self.interrupt_pending = true;
        cancel_flag.store(true, .seq_cst);
        return true;
    }

    /// Why steering cancelled the turn.
    pub const Interrupt = enum {
        /// A steer cut the reply short; the turn continues with it.
        steering,
        /// A handoff ends the turn.
        handoff,
    };

    /// At a cancel boundary: whether steering, not the user, cancelled the
    /// turn, and why. A steer's cancel is spent: `cancel_flag` is cleared and
    /// the turn continues with the steering. A handoff's ends the turn.
    pub fn takeInterrupt(self: *Runtime, cancel_flag: *std.atomic.Value(bool)) ?Interrupt {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.interrupt_pending) return null;
        self.interrupt_pending = false;
        if (self.user_cancelled) return null;
        if (self.handoff_pending) return .handoff;
        cancel_flag.store(false, .seq_cst);
        return .steering;
    }

    /// A steer's interrupt the turn no longer needs, because a boundary
    /// placed its steer or the turn ended first, is spent: `cancel_flag` is
    /// cleared. A user cancel stays.
    pub fn releaseInterrupt(self: *Runtime, cancel_flag: *std.atomic.Value(bool)) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.interrupt_pending or self.user_cancelled) return;
        self.interrupt_pending = false;
        cancel_flag.store(false, .seq_cst);
    }

    /// The user cancels the turn: it stops taking steering, a steer's
    /// interrupt is overridden, and `cancel_flag` is set. Queued steering is
    /// kept, so the turn's end can hand back the libfx inputs among it.
    pub fn cancelForUser(self: *Runtime, cancel_flag: *std.atomic.Value(bool)) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.accepting = false;
        self.user_cancelled = true;
        self.interrupt_pending = false;
        cancel_flag.store(true, .seq_cst);
    }

    /// Removes the queued libfx inputs, which the model never saw, and returns
    /// their ids in order, owned by `result_alloc`. Called as a turn ends, so
    /// a journaled session records them as withdrawn while they still belong
    /// to that turn, and its host can run them next. The turn takes no more
    /// steering from here: a later steer is refused instead of dropped.
    pub fn takeUnplacedInputs(self: *Runtime, backing: Allocator, result_alloc: Allocator) Allocator.Error![][]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.accepting = false;
        var count: usize = 0;
        for (self.messages.items) |entry| {
            if (entry.input_id != null) count += 1;
        }
        if (count == 0) return &.{};
        const ids = try result_alloc.alloc([]u8, count);
        errdefer result_alloc.free(ids);
        var copied: usize = 0;
        errdefer for (ids[0..copied]) |id| result_alloc.free(id);
        for (self.messages.items) |entry| {
            const id = entry.input_id orelse continue;
            ids[copied] = try result_alloc.dupe(u8, id);
            copied += 1;
        }
        var index: usize = 0;
        while (index < self.messages.items.len) {
            if (self.messages.items[index].input_id == null) {
                index += 1;
                continue;
            }
            const removed = self.messages.orderedRemove(index);
            self.queued_bytes -= removed.text.len;
            freeEntry(backing, removed);
        }
        return ids;
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
    /// After a user cancel it takes nothing: the turn is ending, and its end
    /// reports what was still queued.
    pub fn takeAll(
        self: *Runtime,
        backing: Allocator,
        result_alloc: Allocator,
        close_if_empty: bool,
    ) Allocator.Error!Drained {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.user_cancelled) return .{ .texts = &.{}, .request_ids = &.{} };
        // A boundary comes before the next step's request: until that step
        // streams, a compaction or the request itself may run, and neither is
        // a reply a steer cuts short.
        self.step = null;
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
        self.clearToolCallsLocked(alloc);
        self.messages.deinit(alloc);
        self.absorbed.deinit(alloc);
        self.tool_calls.deinit(alloc);
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

test "a libfx steer interrupts a streaming reply and the cancel boundary continues the turn" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    runtime.open(alloc);

    // No step has started: nothing to interrupt yet.
    try runtime.enqueueInput(alloc, "use tabs", "in_1");
    try std.testing.expect(!runtime.claimInterrupt(&cancel_flag));
    // The reply starts streaming with the steer queued: it interrupts at once.
    try std.testing.expect(runtime.notePhase(1, .reply, &cancel_flag));
    try std.testing.expect(cancel_flag.load(.seq_cst));
    // One interrupt at a time.
    try runtime.enqueueInput(alloc, "be brief", "in_2");
    try std.testing.expect(!runtime.claimInterrupt(&cancel_flag));

    try std.testing.expectEqual(Runtime.Interrupt.steering, runtime.takeInterrupt(&cancel_flag).?);
    try std.testing.expect(!cancel_flag.load(.seq_cst));
    try std.testing.expectEqual(@as(?Runtime.Interrupt, null), runtime.takeInterrupt(&cancel_flag));
    const drained = try runtime.takeAll(alloc, alloc, false);
    defer freeDrained(alloc, drained);
    try std.testing.expectEqual(@as(usize, 2), drained.texts.len);
    try std.testing.expectEqualStrings("in_1", drained.input_ids[0].?);

    // Between the boundary and the next step's reply nothing is cut short;
    // that reply is.
    try runtime.enqueueInput(alloc, "also this", "in_3");
    try std.testing.expect(!runtime.claimInterrupt(&cancel_flag));
    try std.testing.expect(runtime.notePhase(2, .reply, &cancel_flag));
}

test "a libfx steer waits while the step works on tool calls or a tool runs" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    runtime.open(alloc);

    try std.testing.expect(!runtime.notePhase(1, .tools, &cancel_flag));
    try runtime.enqueueInput(alloc, "use tabs", "in_1");
    try std.testing.expect(!runtime.claimInterrupt(&cancel_flag));
    // Text after a tool call's arguments in the same step is still that step.
    try std.testing.expect(!runtime.notePhase(1, .reply, &cancel_flag));
    runtime.noteToolStarted(alloc, "call-1");
    runtime.noteToolStarted(alloc, "call-1");
    // A tool still runs while the next step starts.
    try std.testing.expect(!runtime.notePhase(2, .reply, &cancel_flag));
    // An end for a call that never started changes nothing.
    runtime.noteToolEnded(alloc, "call-9");
    try std.testing.expect(!runtime.claimInterrupt(&cancel_flag));
    runtime.noteToolEnded(alloc, "call-1");
    try std.testing.expect(!cancel_flag.load(.seq_cst));
    // The boundary before the next request takes the steer; with it queued
    // instead, the next streaming reply is cut short.
    try std.testing.expect(runtime.notePhase(3, .reply, &cancel_flag));
    try std.testing.expect(cancel_flag.load(.seq_cst));
}

test "a user cancel overrides a libfx steer's interrupt and keeps queued inputs for the turn's end" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    runtime.open(alloc);

    _ = runtime.notePhase(1, .reply, &cancel_flag);
    try runtime.enqueueInput(alloc, "use tabs", "in_1");
    try runtime.enqueue(alloc, "no id");
    try std.testing.expect(runtime.claimInterrupt(&cancel_flag));
    runtime.cancelForUser(&cancel_flag);
    try std.testing.expect(cancel_flag.load(.seq_cst));
    // The cancel boundary ends the turn, which takes nothing more.
    try std.testing.expectEqual(@as(?Runtime.Interrupt, null), runtime.takeInterrupt(&cancel_flag));
    try std.testing.expect(cancel_flag.load(.seq_cst));
    const drained = try runtime.takeAll(alloc, alloc, false);
    defer freeDrained(alloc, drained);
    try std.testing.expectEqual(@as(usize, 0), drained.texts.len);
    try std.testing.expectError(error.SteeringNotActive, runtime.enqueueInput(alloc, "late", "in_2"));

    // As the turn ends, the libfx input is handed back; the rest stays for
    // the turn's end to report.
    const unplaced = try runtime.takeUnplacedInputs(alloc, alloc);
    defer {
        for (unplaced) |id| alloc.free(id);
        alloc.free(unplaced);
    }
    try std.testing.expectEqual(@as(usize, 1), unplaced.len);
    try std.testing.expectEqualStrings("in_1", unplaced[0]);
    try std.testing.expectEqual(@as(usize, 1), runtime.messages.items.len);
    try std.testing.expectEqual(@as(usize, "no id".len), runtime.queued_bytes);
    const finished = try runtime.finishTurn(alloc, alloc, "test");
    defer finished.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.messages.items.len);

    // The next turn starts with no cancel and no interrupt.
    runtime.open(alloc);
    try std.testing.expect(!runtime.user_cancelled);
    try runtime.enqueueInput(alloc, "next", "in_3");
}

test "a libfx handoff ends a streaming reply at once and a tool step at its boundary" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    runtime.open(alloc);

    // While the model streams a reply, a handoff cuts it short, and the cancel
    // boundary that follows ends the turn with the cancel still set.
    _ = runtime.notePhase(1, .reply, &cancel_flag);
    try std.testing.expect(runtime.requestHandoff(&cancel_flag));
    try std.testing.expect(cancel_flag.load(.seq_cst));
    try std.testing.expectEqual(Runtime.Interrupt.handoff, runtime.takeInterrupt(&cancel_flag).?);
    try std.testing.expect(cancel_flag.load(.seq_cst));

    // While the step works on a tool call, the handoff waits for the boundary.
    cancel_flag.store(false, .seq_cst);
    runtime.open(alloc);
    try std.testing.expect(!runtime.notePhase(1, .tools, &cancel_flag));
    try std.testing.expect(!runtime.requestHandoff(&cancel_flag));
    try std.testing.expect(!cancel_flag.load(.seq_cst));
    try std.testing.expect(runtime.handoffPending());

    // A cancelled turn takes no handoff.
    runtime.open(alloc);
    runtime.cancelForUser(&cancel_flag);
    try std.testing.expect(!runtime.requestHandoff(&cancel_flag));
    try std.testing.expect(!runtime.handoffPending());
}

test "a libfx steer's interrupt is spent once its steer is placed or its turn ends, and the turn's end refuses more" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    runtime.open(alloc);

    // A model announcing a tool call ends what a steer may cut short.
    _ = runtime.notePhase(1, .reply, &cancel_flag);
    runtime.noteToolsPhase();
    try runtime.enqueueInput(alloc, "use tabs", "in_1");
    try std.testing.expect(!runtime.claimInterrupt(&cancel_flag));

    // An interrupt a boundary no longer needs is spent; a user cancel is not.
    try std.testing.expect(runtime.notePhase(2, .reply, &cancel_flag));
    runtime.releaseInterrupt(&cancel_flag);
    try std.testing.expect(!cancel_flag.load(.seq_cst));
    try std.testing.expectEqual(@as(?Runtime.Interrupt, null), runtime.takeInterrupt(&cancel_flag));
    runtime.cancelForUser(&cancel_flag);
    runtime.releaseInterrupt(&cancel_flag);
    try std.testing.expect(cancel_flag.load(.seq_cst));

    // After the turn's end hands back its inputs, a late steer is refused.
    runtime.open(alloc);
    try runtime.enqueueInput(alloc, "late enough", "in_2");
    const unplaced = try runtime.takeUnplacedInputs(alloc, alloc);
    defer {
        for (unplaced) |id| alloc.free(id);
        alloc.free(unplaced);
    }
    try std.testing.expectEqual(@as(usize, 1), unplaced.len);
    try std.testing.expectError(error.SteeringNotActive, runtime.enqueueInput(alloc, "too late", "in_3"));
}

test "steering a web host keeps interrupts the reply under the same rule" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    var cancel_flag = std.atomic.Value(bool).init(false);
    runtime.open(alloc);

    try std.testing.expect(!runtime.claimHostInterrupt(1, &cancel_flag));
    _ = runtime.notePhase(1, .reply, &cancel_flag);
    try std.testing.expect(!runtime.claimHostInterrupt(0, &cancel_flag));
    try std.testing.expect(runtime.claimHostInterrupt(1, &cancel_flag));
    try std.testing.expectEqual(Runtime.Interrupt.steering, runtime.takeInterrupt(&cancel_flag).?);
    runtime.noteBoundary();
    try std.testing.expect(!runtime.claimHostInterrupt(1, &cancel_flag));
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
