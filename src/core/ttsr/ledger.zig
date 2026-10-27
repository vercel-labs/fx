//! The repeat ledger: when each rule was last injected, counted in
//! assistant messages, which decides whether it may fire again.
//!
//! proto keeps the ledger as `ttsr_injection` session entries. proto-fx
//! derives it from the conversation itself: every injection persists as its
//! envelope (an interrupt or deferred rule as a steering message, a reminder
//! at the head of a tool result), so the saved turns already say which rules
//! were injected and after how many assistant messages. A resumed session
//! rebuilds the same ledger, and a compaction that drops an injection lets
//! its rule fire again, since the model no longer has it.
const std = @import("std");
const envelope = @import("envelope.zig");
const settings_mod = @import("settings.zig");

const Allocator = std.mem.Allocator;

pub const Ledger = struct {
    alloc: Allocator,
    last_injected: std.StringArrayHashMapUnmanaged(usize) = .empty,
    /// Assistant messages so far, history included.
    message_count: usize = 0,

    pub fn init(alloc: Allocator) Ledger {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.last_injected.keys()) |key| self.alloc.free(key);
        self.last_injected.deinit(self.alloc);
    }

    pub fn mark(self: *Ledger, name: []const u8) !void {
        try self.markAt(name, self.message_count);
    }

    fn markAt(self: *Ledger, name: []const u8, at: usize) !void {
        const trimmed = std.mem.trim(u8, name, " ");
        if (trimmed.len == 0) return;
        if (self.last_injected.getPtr(trimmed)) |slot| {
            slot.* = at;
            return;
        }
        const key = try self.alloc.dupe(u8, trimmed);
        errdefer self.alloc.free(key);
        try self.last_injected.put(self.alloc, key, at);
    }

    pub fn canTrigger(self: *const Ledger, settings: settings_mod.Settings, name: []const u8) bool {
        const at = self.last_injected.get(name) orelse return true;
        return switch (settings.repeat_mode) {
            .once => false,
            .after_gap => self.message_count -| at >= settings.repeat_gap,
        };
    }

    pub fn injectedNames(self: *const Ledger) []const []const u8 {
        return self.last_injected.keys();
    }

    /// Rebuilds the ledger from a conversation, oldest message first. Each
    /// message has a `role` enum (`assistant`, `user`, `tool`, ...) and an
    /// optional `content`, as `types.ChatMessage` does.
    pub fn seed(self: *Ledger, messages: anytype) !void {
        // An injection the conversation no longer holds is forgotten.
        for (self.last_injected.keys()) |key| self.alloc.free(key);
        self.last_injected.clearRetainingCapacity();
        self.message_count = 0;
        for (messages) |message| {
            const role = @tagName(message.role);
            if (std.mem.eql(u8, role, "assistant")) {
                self.message_count += 1;
            } else if (std.mem.eql(u8, role, "user") or std.mem.eql(u8, role, "tool")) {
                if (message.content) |content| try self.seedText(content);
            }
        }
    }

    fn seedText(self: *Ledger, text: []const u8) !void {
        const Visit = struct {
            ledger: *Ledger,
            failed: bool = false,
            fn visit(state: *@This(), name: []const u8) void {
                state.ledger.mark(name) catch {
                    state.failed = true;
                };
            }
        };
        var state: Visit = .{ .ledger = self };
        envelope.eachRuleName(text, &state, Visit.visit);
        if (state.failed) return error.OutOfMemory;
    }
};

test "the ledger rebuilds from saved injections and honors the repeat mode" {
    const alloc = std.testing.allocator;
    const injection = try envelope.renderAll(alloc, .interrupt, &.{.{ .name = "no-force", .path = "p", .content = "c" }});
    defer alloc.free(injection);
    const reminder = try envelope.renderAll(alloc, .reminder, &.{.{ .name = "py-print", .path = "p", .content = "c" }});
    defer alloc.free(reminder);
    const tool_result = try std.mem.concat(alloc, u8, &.{ reminder, "\n\nexit 0" });
    defer alloc.free(tool_result);
    const Message = struct { role: enum { system, user, assistant, tool }, content: ?[]const u8 };
    const messages = [_]Message{
        .{ .role = .user, .content = "go" },
        .{ .role = .assistant, .content = "a" },
        .{ .role = .user, .content = injection },
        .{ .role = .assistant, .content = null },
        .{ .role = .tool, .content = tool_result },
        .{ .role = .assistant, .content = "c" },
    };
    var ledger = Ledger.init(alloc);
    defer ledger.deinit();
    try ledger.seed(&messages);
    try std.testing.expectEqual(@as(usize, 3), ledger.message_count);
    try std.testing.expectEqual(@as(usize, 1), ledger.last_injected.get("no-force").?);
    try std.testing.expectEqual(@as(usize, 2), ledger.last_injected.get("py-print").?);
    const once: settings_mod.Settings = .{};
    try std.testing.expect(!ledger.canTrigger(once, "no-force"));
    try std.testing.expect(ledger.canTrigger(once, "other"));
    const gap: settings_mod.Settings = .{ .repeat_mode = .after_gap, .repeat_gap = 2 };
    try std.testing.expect(ledger.canTrigger(gap, "no-force"));
    try std.testing.expect(!ledger.canTrigger(gap, "py-print"));
    ledger.message_count += 1;
    try std.testing.expect(ledger.canTrigger(gap, "py-print"));
    // A compaction that drops the injections frees their rules.
    try ledger.seed(messages[0..2]);
    try std.testing.expect(ledger.canTrigger(once, "no-force"));
}
