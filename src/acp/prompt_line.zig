//! The prompts that wait for a session's running turn to end, in the order fx
//! runs them: first the steers for the next turn, which run together as one
//! turn, then the queued prompts, one turn each (src/protocol/spec/sh-fx.md,
//! "Steering and queued prompts"). The connection reader adds to the line and
//! the prompt worker takes from it, both holding `mutex`. A caller that also
//! takes a steering runtime's mutex takes this one first.
//!
//! TLA+ model: tests/tla/acp/AcpPromptDelivery.tla, whose `late` and `queue`
//! the line holds.

const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const jsonrpc = @import("jsonrpc.zig");
const libfx_steering = @import("libfx_steering.zig");

const Allocator = std.mem.Allocator;
const RequestId = jsonrpc.RequestId;
const Steer = libfx_steering.Steer;

/// A session holds at most this many queued prompts.
pub const max_queued_prompts: usize = 64;

/// What runs after a turn ends. Owned by the caller.
pub const Next = union(enum) {
    /// The steers for the next turn, in order, run together as one turn.
    steers: std.ArrayList(Steer),
    /// A queued prompt, as the client sent it.
    prompt: jsonrpc.Message,

    pub fn deinit(self: *Next, alloc: Allocator) void {
        switch (self.*) {
            .steers => |*steers| {
                libfx_steering.freeSteers(alloc, steers.items);
                steers.deinit(alloc);
            },
            .prompt => |*msg| jsonrpc.freeMessage(alloc, msg),
        }
    }
};

/// Everything a closing session's line held, to answer with `-32800`. Owned
/// by the caller.
pub const Drained = struct {
    late: std.ArrayList(Steer) = .empty,
    queue: std.ArrayList(jsonrpc.Message) = .empty,

    pub fn deinit(self: *Drained, alloc: Allocator) void {
        libfx_steering.freeSteers(alloc, self.late.items);
        self.late.deinit(alloc);
        for (self.queue.items) |*msg| jsonrpc.freeMessage(alloc, msg);
        self.queue.deinit(alloc);
    }
};

pub const Line = struct {
    mutex: std.Io.Mutex = .init,
    /// Steers that arrived after the running turn stopped taking input, and
    /// those it never took. They run together as the next turn.
    late: std.ArrayList(Steer) = .empty,
    late_bytes: usize = 0,
    /// Queued prompts, in the order fx received them.
    queue: std.ArrayList(jsonrpc.Message) = .empty,
    /// A prompt worker runs and takes what the line holds when its turn
    /// ends. While false, a prompt that arrives starts a turn of its own.
    worker_running: bool = false,
    /// The session is closing: its worker starts nothing more.
    closing: bool = false,

    pub fn lock(self: *Line) void {
        self.mutex.lockUncancelable(io_mod.getIo());
    }

    pub fn unlock(self: *Line) void {
        self.mutex.unlock(io_mod.getIo());
    }

    /// Whether nothing waits.
    pub fn emptyLocked(self: *const Line) bool {
        return self.late.items.len == 0 and self.queue.items.len == 0;
    }

    /// Adds a steer that arrived after the running turn stopped taking input.
    /// The steer limits count the steers that already wait here.
    pub fn addLateLocked(
        self: *Line,
        alloc: Allocator,
        text: []const u8,
        id: RequestId,
    ) (Allocator.Error || error{SteeringQueueFull})!void {
        if (self.late.items.len >= libfx_steering.max_messages or
            self.late_bytes > libfx_steering.max_queued_bytes - text.len)
        {
            return error.SteeringQueueFull;
        }
        try self.late.ensureUnusedCapacity(alloc, 1);
        const owned_text = try alloc.dupe(u8, text);
        errdefer alloc.free(owned_text);
        self.late.appendAssumeCapacity(.{ .text = owned_text, .request_id = try jsonrpc.dupeRequestId(alloc, id) });
        self.late_bytes += owned_text.len;
    }

    /// Puts the steers a turn never took ahead of the late ones, which arrived
    /// after them. On success the line owns the steers, and the caller frees
    /// only the slice that held them.
    pub fn handBackLocked(self: *Line, alloc: Allocator, untaken: []const Steer) Allocator.Error!void {
        try self.late.ensureUnusedCapacity(alloc, untaken.len);
        self.late.insertSliceAssumeCapacity(0, untaken);
        for (untaken) |steer| self.late_bytes += steer.text.len;
    }

    /// Queues a prompt. On success the line owns `msg`.
    pub fn addQueuedLocked(
        self: *Line,
        alloc: Allocator,
        msg: jsonrpc.Message,
    ) (Allocator.Error || error{PromptQueueFull})!void {
        if (self.queue.items.len >= max_queued_prompts) return error.PromptQueueFull;
        try self.queue.append(alloc, msg);
    }

    /// Takes what runs next: every late steer together, else the first
    /// queued prompt. Null when nothing waits.
    pub fn takeNextLocked(self: *Line) ?Next {
        if (self.late.items.len > 0) {
            const steers = self.late;
            self.late = .empty;
            self.late_bytes = 0;
            return .{ .steers = steers };
        }
        if (self.queue.items.len > 0) return .{ .prompt = self.queue.orderedRemove(0) };
        return null;
    }

    /// Removes the late steer or queued prompt that request `id` sent. False
    /// when the line holds no such request.
    pub fn withdrawLocked(self: *Line, alloc: Allocator, id: RequestId) bool {
        for (self.late.items, 0..) |steer, index| {
            if (!jsonrpc.requestIdsEqual(steer.request_id, id)) continue;
            const removed = self.late.orderedRemove(index);
            self.late_bytes -= removed.text.len;
            removed.deinit(alloc);
            return true;
        }
        for (self.queue.items, 0..) |queued, index| {
            const queued_id = queued.id orelse continue;
            if (!jsonrpc.requestIdsEqual(queued_id, id)) continue;
            var removed = self.queue.orderedRemove(index);
            jsonrpc.freeMessage(alloc, &removed);
            return true;
        }
        return false;
    }

    /// Takes everything the line holds, for a closing session to answer.
    pub fn drainLocked(self: *Line) Drained {
        const drained: Drained = .{ .late = self.late, .queue = self.queue };
        self.late = .empty;
        self.late_bytes = 0;
        self.queue = .empty;
        return drained;
    }

    pub fn deinit(self: *Line, alloc: Allocator) void {
        var drained = self.drainLocked();
        drained.deinit(alloc);
        self.* = .{};
    }
};

fn testPrompt(alloc: Allocator, id: i64) !jsonrpc.Message {
    return .{
        .method = try alloc.dupe(u8, "session/prompt"),
        .id = .{ .integer = id },
        .params_raw = try alloc.dupe(u8, "{\"sessionId\":\"s1\",\"prompt\":[]}"),
    };
}

test "the next turn runs every late steer together, then each queued prompt in order" {
    const alloc = std.testing.allocator;
    var line: Line = .{};
    defer line.deinit(alloc);

    try line.addQueuedLocked(alloc, try testPrompt(alloc, 10));
    try line.addQueuedLocked(alloc, try testPrompt(alloc, 11));
    try line.addLateLocked(alloc, "late one", .{ .integer = 1 });
    try line.addLateLocked(alloc, "late two", .{ .string = "s2" });

    var first = line.takeNextLocked().?;
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), first.steers.items.len);
    try std.testing.expectEqualStrings("late one", first.steers.items[0].text);
    try std.testing.expectEqualStrings("s2", first.steers.items[1].request_id.string);
    try std.testing.expectEqual(@as(usize, 0), line.late_bytes);

    var second = line.takeNextLocked().?;
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 10), second.prompt.id.?.integer);
    var third = line.takeNextLocked().?;
    defer third.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 11), third.prompt.id.?.integer);
    try std.testing.expect(line.takeNextLocked() == null);
    try std.testing.expect(line.emptyLocked());
}

test "steers a turn never took go ahead of the steers that arrived after it" {
    const alloc = std.testing.allocator;
    var line: Line = .{};
    defer line.deinit(alloc);
    try line.addLateLocked(alloc, "after input closed", .{ .integer = 3 });

    const untaken = try alloc.alloc(Steer, 2);
    defer alloc.free(untaken);
    untaken[0] = .{ .text = try alloc.dupe(u8, "first"), .request_id = .{ .integer = 1 } };
    untaken[1] = .{ .text = try alloc.dupe(u8, "second"), .request_id = .{ .string = try alloc.dupe(u8, "s2") } };
    try line.handBackLocked(alloc, untaken);

    try std.testing.expectEqual(@as(usize, "first".len + "second".len + "after input closed".len), line.late_bytes);
    var next = line.takeNextLocked().?;
    defer next.deinit(alloc);
    const steers = next.steers.items;
    try std.testing.expectEqualStrings("first", steers[0].text);
    try std.testing.expectEqualStrings("second", steers[1].text);
    try std.testing.expectEqualStrings("after input closed", steers[2].text);
}

test "a full line refuses the next queued prompt and the next late steer" {
    const alloc = std.testing.allocator;
    var line: Line = .{};
    defer line.deinit(alloc);
    for (0..max_queued_prompts) |index| try line.addQueuedLocked(alloc, try testPrompt(alloc, @intCast(index)));
    var overflow = try testPrompt(alloc, 99);
    defer jsonrpc.freeMessage(alloc, &overflow);
    try std.testing.expectError(error.PromptQueueFull, line.addQueuedLocked(alloc, overflow));

    for (0..libfx_steering.max_messages) |index| try line.addLateLocked(alloc, "x", .{ .integer = @intCast(index) });
    try std.testing.expectError(error.SteeringQueueFull, line.addLateLocked(alloc, "x", .{ .integer = 99 }));
}

test "a late steer or queued prompt is withdrawn by its request id" {
    const alloc = std.testing.allocator;
    var line: Line = .{};
    defer line.deinit(alloc);
    try line.addLateLocked(alloc, "steer", .{ .integer = 1 });
    try line.addQueuedLocked(alloc, try testPrompt(alloc, 2));

    try std.testing.expect(line.withdrawLocked(alloc, .{ .integer = 2 }));
    try std.testing.expect(!line.withdrawLocked(alloc, .{ .integer = 2 }));
    try std.testing.expect(line.withdrawLocked(alloc, .{ .integer = 1 }));
    try std.testing.expectEqual(@as(usize, 0), line.late_bytes);
    try std.testing.expect(line.emptyLocked());
}

test "a closing session drains the whole line to answer it" {
    const alloc = std.testing.allocator;
    var line: Line = .{};
    defer line.deinit(alloc);
    try line.addLateLocked(alloc, "steer", .{ .integer = 1 });
    try line.addQueuedLocked(alloc, try testPrompt(alloc, 2));

    var drained = line.drainLocked();
    defer drained.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), drained.late.items.len);
    try std.testing.expectEqual(@as(usize, 1), drained.queue.items.len);
    try std.testing.expect(line.emptyLocked());
    try std.testing.expectEqual(@as(usize, 0), line.late_bytes);
}
