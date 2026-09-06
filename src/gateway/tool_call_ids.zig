const std = @import("std");
const types = @import("../core/shared/types.zig");

const max_id_bytes = 64;

/// Request-local wire IDs. Source IDs remain borrowed and unchanged; generated
/// IDs are owned until deinit. Portable requests allocate nothing.
pub const Projection = struct {
    const Entry = struct { wire: []const u8, protected: bool };

    ids: std.StringHashMapUnmanaged(Entry) = .empty,
    owned: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: std.mem.Allocator, messages: []const types.ChatMessage) !Projection {
        var needed = false;
        var opaque_history = false;
        for (messages) |message| {
            if (message.role == .tool) {
                const id = message.tool_call_id orelse return error.InvalidToolCallId;
                if (id.len == 0) return error.InvalidToolCallId;
                needed = needed or !portable(id);
            }
            if (message.role != .assistant) continue;
            opaque_history = opaque_history or message.provider_replay != null;
            for (message.tool_calls) |call| {
                if (call.id.len == 0) return error.InvalidToolCallId;
                if (portable(call.id)) continue;
                needed = true;
            }
        }
        if (!needed) return .{};

        var self: Projection = .{};
        errdefer self.deinit(alloc);
        for (messages) |message| {
            if (message.role == .assistant) {
                for (message.tool_calls) |call| {
                    const entry = try self.ids.getOrPut(alloc, call.id);
                    const protected = call.provenance == .provider_executed or message.provider_replay != null;
                    if (!entry.found_existing) entry.value_ptr.* = .{ .wire = call.id, .protected = false };
                    entry.value_ptr.protected = entry.value_ptr.protected or protected;
                }
            }
            if (message.role == .tool) {
                const id = message.tool_call_id.?;
                const entry = try self.ids.getOrPut(alloc, id);
                if (!entry.found_existing) entry.value_ptr.* = .{ .wire = id, .protected = false };
            }
        }
        for (messages) |message| {
            if (message.role != .assistant) continue;
            for (message.tool_calls) |call| {
                if (portable(self.resolve(call.id))) continue;
                if (call.provenance == .provider_executed or message.provider_replay != null) continue;
                if (self.ids.get(call.id).?.protected) return error.ProtectedToolCallId;
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(call.id, &digest, .{});
                const hex = std.fmt.bytesToHex(digest[0..20].*, .lower);
                const attempts = try std.math.add(usize, self.ids.count(), 1);
                for (0..attempts) |attempt| {
                    var buffer: [max_id_bytes]u8 = undefined;
                    const candidate = try std.fmt.bufPrint(&buffer, "fx_{s}_{d}", .{ &hex, attempt });
                    if (self.ids.contains(candidate)) {
                        // Opaque state may refer to an alias from an earlier request.
                        if (opaque_history) return error.ProtectedToolCallId;
                        continue;
                    }
                    const alias = try alloc.dupe(u8, candidate);
                    errdefer alloc.free(alias);
                    try self.ids.ensureUnusedCapacity(alloc, 1);
                    try self.owned.ensureUnusedCapacity(alloc, 1);
                    self.ids.putAssumeCapacity(alias, .{ .wire = alias, .protected = false });
                    self.ids.getPtr(call.id).?.wire = alias;
                    self.owned.appendAssumeCapacity(alias);
                    break;
                } else return error.ToolCallIdMappingExhausted;
            }
        }
        for (messages) |message| {
            if (message.role == .tool) {
                const entry = self.ids.get(message.tool_call_id.?).?;
                if (!entry.protected and !portable(entry.wire)) return error.InvalidToolCallId;
            }
        }
        return self;
    }

    pub fn deinit(self: *Projection, alloc: std.mem.Allocator) void {
        self.ids.deinit(alloc);
        for (self.owned.items) |id| alloc.free(id);
        self.owned.deinit(alloc);
    }

    /// The result borrows either source or this projection's storage.
    pub fn resolve(self: *const Projection, source: []const u8) []const u8 {
        return if (self.ids.get(source)) |entry| entry.wire else source;
    }
};

fn portable(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_bytes) return false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

test "portable tool call ids use an allocation-free identity projection" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const calls = [_]types.ToolCall{
        .{ .id = "call_ABC-123", .name = "read", .arguments_json = "{}" },
        .{ .id = "x" ** 64, .name = "read", .arguments_json = "{}" },
    };
    var projection = try Projection.init(failing.allocator(), &.{.{ .role = .assistant, .tool_calls = &calls }});
    defer projection.deinit(failing.allocator());
    for (calls) |call| try std.testing.expect(projection.resolve(call.id).ptr == call.id.ptr);
}

test "tool call id projection ignores fields not serialized for a role" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const calls = [_]types.ToolCall{.{ .id = "", .name = "ignored", .arguments_json = "{}" }};
    var projection = try Projection.init(failing.allocator(), &.{.{
        .role = .user,
        .content = "question",
        .tool_calls = &calls,
        .tool_call_id = "ignored:0",
        .provider_replay = .{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "ignored" },
    }});
    defer projection.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), projection.owned.items.len);
}

test "tool call id projection is deterministic and preserves source IDs" {
    const alloc = std.testing.allocator;
    const sources = [_][]const u8{ "functions.read:0", "functions/read:0", " ", "\t\n", "é", "x" ** 65, "x" ** 256 };
    var calls: [sources.len]types.ToolCall = undefined;
    for (sources, 0..) |source, i| calls[i] = .{ .id = source, .name = "read", .arguments_json = "{}" };
    const messages = [_]types.ChatMessage{.{ .role = .assistant, .tool_calls = &calls }};
    var first = try Projection.init(alloc, &messages);
    defer first.deinit(alloc);
    var second = try Projection.init(alloc, &messages);
    defer second.deinit(alloc);
    for (sources, 0..) |source, i| {
        const id = first.resolve(source);
        try std.testing.expect(portable(id));
        try std.testing.expectEqualStrings(id, second.resolve(source));
        try std.testing.expectEqualStrings(source, calls[i].id);
        for (sources[0..i]) |prior| try std.testing.expect(!std.mem.eql(u8, id, first.resolve(prior)));
    }
}

test "tool call id projection avoids aliases reserved by portable calls" {
    const alloc = std.testing.allocator;
    const source = "functions.read:0";
    var calls = [_]types.ToolCall{.{ .id = source, .name = "read", .arguments_json = "{}" }};
    var first = try Projection.init(alloc, &.{.{ .role = .assistant, .tool_calls = &calls }});
    defer first.deinit(alloc);
    const original_alias = first.resolve(source);
    const colliding_calls = [_]types.ToolCall{
        calls[0],
        .{ .id = original_alias, .name = "read", .arguments_json = "{}" },
    };
    var second = try Projection.init(alloc, &.{.{ .role = .assistant, .tool_calls = &colliding_calls }});
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings(original_alias, second.resolve(original_alias));
    try std.testing.expect(!std.mem.eql(u8, original_alias, second.resolve(source)));
    try std.testing.expect(portable(second.resolve(source)));
    try std.testing.expectError(error.ProtectedToolCallId, Projection.init(alloc, &.{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .assistant, .tool_calls = colliding_calls[1..], .provider_replay = .{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "opaque" } },
    }));
}

test "tool call id projection never rewrites protected identities" {
    const alloc = std.testing.allocator;
    var call = types.ToolCall{ .id = "native:0", .name = "native", .arguments_json = "{}", .provenance = .provider_executed };
    var native = try Projection.init(alloc, &.{.{ .role = .assistant, .tool_calls = &.{call} }});
    defer native.deinit(alloc);
    try std.testing.expectEqualStrings(call.id, native.resolve(call.id));
    call.provenance = .fx_local;
    var projection = try Projection.init(alloc, &.{.{ .role = .assistant, .tool_calls = &.{call}, .provider_replay = .{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "opaque" } }});
    defer projection.deinit(alloc);
    try std.testing.expectEqualStrings(call.id, projection.resolve(call.id));
    const native_call = types.ToolCall{ .id = call.id, .name = "native", .arguments_json = "{}", .provenance = .provider_executed };
    try std.testing.expectError(error.ProtectedToolCallId, Projection.init(alloc, &.{
        .{ .role = .assistant, .tool_calls = &.{call} },
        .{ .role = .assistant, .tool_calls = &.{native_call} },
    }));
}

test "tool call id projection reuses aliases across settled steps" {
    const alloc = std.testing.allocator;
    const call = types.ToolCall{ .id = "call:0", .name = "read", .arguments_json = "{}" };
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{call} },
        .{ .role = .tool, .tool_call_id = call.id, .content = "one" },
        .{ .role = .assistant, .tool_calls = &.{call} },
        .{ .role = .tool, .tool_call_id = call.id, .content = "two" },
    };
    var projection = try Projection.init(alloc, &messages);
    defer projection.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), projection.owned.items.len);
    for (messages) |message| {
        const id = message.tool_call_id orelse message.tool_calls[0].id;
        try std.testing.expectEqualStrings(projection.owned.items[0], projection.resolve(id));
    }
}

test "tool call id projection rejects unpaired nonportable result ids" {
    try std.testing.expectError(error.InvalidToolCallId, Projection.init(std.testing.allocator, &.{.{ .role = .tool, .tool_call_id = "missing:0" }}));
}

fn allocation_failure_case(alloc: std.mem.Allocator) !void {
    const calls = [_]types.ToolCall{
        .{ .id = "functions.read:0", .name = "read", .arguments_json = "{}" },
        .{ .id = "x" ** 65, .name = "read", .arguments_json = "{}" },
    };
    var projection = try Projection.init(alloc, &.{.{ .role = .assistant, .tool_calls = &calls }});
    defer projection.deinit(alloc);
    for (calls) |call| try std.testing.expect(portable(projection.resolve(call.id)));
}

test "tool call id projection cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocation_failure_case, .{});
}
