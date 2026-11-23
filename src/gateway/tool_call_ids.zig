const std = @import("std");
const testing_allocator = @import("../core/shared/testing_allocator.zig");
const types = @import("../core/shared/types.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const json_comparison = @import("../core/shared/json_comparison.zig");
const tool_args = @import("../core/tooling/tool_args.zig");
const json_depth = @import("../core/shared/json_depth.zig");

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
                    const candidate = try std.mem.print(&buffer, "fx_{s}_{d}", .{ &hex, attempt });
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

/// What a reply's calls answer: the messages its request sent, and this
/// turn's messages so far, which compaction may have taken out of them.
/// Both are borrowed.
pub const Conversation = struct {
    messages: []const types.ChatMessage = &.{},
    current_turn_messages: []const types.ChatMessage = &.{},
};

const fx_id_prefix = "fx_call_";

/// Gives each call of one reply the id it keeps in fx. A call keeps the
/// provider's id when fx can store it and no call in the conversation, or
/// earlier in this reply, has it, or when it is a call from an earlier reply
/// sent again (`sameCallAgain`); any other call gets a new `fx_call_<n>`.
/// It borrows the conversation's messages until deinit, and owns every id it
/// returns until then.
pub const ReplyIds = struct {
    arena: std.heap.ArenaAllocator,
    taken: std.StringHashMapUnmanaged(void) = .empty,
    /// The conversation's calls, borrowed, for telling a call sent again.
    earlier_calls: std.ArrayList(types.ToolCall) = .empty,
    /// The ids this reply's calls kept as calls sent again.
    sent_again: std.StringHashMapUnmanaged(void) = .empty,
    next_number: usize = 1,

    /// Fails with `InvalidToolCallId` where the request builders' projection
    /// does, which no request that was sent can do.
    pub fn init(gpa: std.mem.Allocator, conversation: Conversation) error{ OutOfMemory, InvalidToolCallId }!ReplyIds {
        var self: ReplyIds = .{ .arena = .init(gpa) };
        errdefer self.deinit();
        const alloc = self.arena.allocator();
        for (conversation.messages) |message| try self.takeIdsOf(message);
        for (conversation.current_turn_messages) |message| try self.takeIdsOf(message);
        // The request sends these aliases in place of non-portable ids.
        const projection = Projection.init(alloc, conversation.messages) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolCallId,
        };
        for (projection.owned.items) |alias| try self.taken.put(alloc, alias, {});
        return self;
    }

    pub fn deinit(self: *ReplyIds) void {
        self.arena.deinit();
    }

    /// The id of a call that fx runs. `source` is the id the provider sent,
    /// or null when it sent none.
    pub fn assign(self: *ReplyIds, source: ?[]const u8) std.mem.Allocator.Error![]const u8 {
        if (source) |id| {
            if (usable(id) and !self.taken.contains(id)) return self.take(id);
        }
        return self.newId();
    }

    /// Whether a call the provider sent with id `source` is a call from an
    /// earlier reply sent again: the same id, the same tool, and the same
    /// arguments (`sameArguments`). Such a call keeps its id, so work keyed
    /// by it, such as a subagent message, is not done twice; only one call
    /// per reply may.
    pub fn sameCallAgain(self: *ReplyIds, source: ?[]const u8, name: []const u8, arguments_json: []const u8) std.mem.Allocator.Error!bool {
        const id = source orelse return false;
        if (!usable(id) or self.sent_again.contains(id)) return false;
        const alloc = self.arena.allocator();
        for (self.earlier_calls.items) |call| {
            if (!std.mem.eql(u8, call.id, id) or !std.mem.eql(u8, call.name, name)) continue;
            if (!try sameArguments(alloc, call.arguments_json, arguments_json)) continue;
            try self.sent_again.put(alloc, try alloc.dupe(u8, id), {});
            return true;
        }
        return false;
    }

    /// Takes the id of a call the provider ran: its result comes back under
    /// that id, so it keeps it, and no later call may take it.
    pub fn keep(self: *ReplyIds, id: []const u8) std.mem.Allocator.Error!void {
        if (!usable(id) or self.taken.contains(id)) return;
        _ = try self.take(id);
    }

    fn takeIdsOf(self: *ReplyIds, message: types.ChatMessage) std.mem.Allocator.Error!void {
        const alloc = self.arena.allocator();
        switch (message.role) {
            .assistant => for (message.tool_calls) |call| {
                try self.taken.put(alloc, call.id, {});
                try self.earlier_calls.append(alloc, call);
            },
            .tool => if (message.tool_call_id) |id| try self.taken.put(alloc, id, {}),
            else => {},
        }
    }

    fn take(self: *ReplyIds, id: []const u8) std.mem.Allocator.Error![]const u8 {
        const alloc = self.arena.allocator();
        const owned = try alloc.dupe(u8, id);
        try self.taken.put(alloc, owned, {});
        return owned;
    }

    fn newId(self: *ReplyIds) std.mem.Allocator.Error![]const u8 {
        var buffer: [max_id_bytes]u8 = undefined;
        while (true) {
            // The buffer holds the prefix and the digits of any usize.
            const candidate = std.mem.print(&buffer, fx_id_prefix ++ "{d}", .{self.next_number}) catch unreachable;
            self.next_number += 1;
            if (!self.taken.contains(candidate)) return self.take(candidate);
        }
    }
};

/// Whether a stored call's arguments and a sent call's are the same: they
/// parse to the same JSON value (`json_comparison.serializedEqual`: any key
/// order and whitespace, equal escapes; text that is not JSON matches only
/// byte for byte), as sent or with an exact `{"request": ...}` wrapper taken
/// off, as fx takes it off before it stores some calls (`tool_args.unwrapRequest`).
fn sameArguments(arena: std.mem.Allocator, stored: []const u8, sent: []const u8) std.mem.Allocator.Error!bool {
    if (try json_comparison.serializedEqual(arena, stored, sent)) return true;
    const stored_request = try requestArguments(arena, stored);
    const sent_request = try requestArguments(arena, sent);
    if (stored_request == null and sent_request == null) return false;
    return json_comparison.serializedEqual(arena, stored_request orelse stored, sent_request orelse sent);
}

/// The arguments inside an exact `{"request": ...}` wrapper, as JSON, or
/// null when there is none or when the text nests past `json_depth.max_depth`,
/// which std.json.Stringify must never see. Allocated in `arena`.
fn requestArguments(arena: std.mem.Allocator, arguments_json: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (json_depth.exceeds(arguments_json)) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .object or parsed.object.count() != 1 or parsed.object.get("request") == null) return null;
    const request = (try tool_args.unwrapRequest(arena, parsed.object)) orelse return null;
    return try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = request }, .{});
}

/// An id fx can store and admit as a call's own: the same rules
/// `types.authoritativeToolAdmission` checks.
fn usable(id: []const u8) bool {
    return types.ConversationIdentity.invalidReason(id) == null and
        !types.ConversationIdentity.isBlank(id);
}

test "a reply keeps every provider id no other call has, byte for byte" {
    const alloc = std.testing.allocator;
    const earlier = [_]types.ToolCall{.{ .id = "call_1", .name = "read", .arguments_json = "{}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &earlier },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "one" },
    };
    var ids = try ReplyIds.init(alloc, .{ .messages = &messages });
    defer ids.deinit();
    for ([_][]const u8{ "call_2", "functions.read:0", "a\x1bb", "fx_other", text_utils.repeat("x", 256) }) |source| {
        try std.testing.expectEqualStrings(source, try ids.assign(source));
    }
}

test "a reply's repeated, missing, blank, or unstorable ids get fx ids" {
    const alloc = std.testing.allocator;
    var ids = try ReplyIds.init(alloc, .{});
    defer ids.deinit();
    try std.testing.expectEqualStrings("same", try ids.assign("same"));
    try std.testing.expectEqualStrings("fx_call_1", try ids.assign("same"));
    try std.testing.expectEqualStrings("fx_call_2", try ids.assign(null));
    try std.testing.expectEqualStrings("fx_call_3", try ids.assign(""));
    try std.testing.expectEqualStrings("fx_call_4", try ids.assign(" \t"));
    try std.testing.expectEqualStrings("fx_call_5", try ids.assign(text_utils.repeat("x", 257)));
    try std.testing.expectEqualStrings("fx_call_6", try ids.assign("bad\xff"));
}

test "an id an earlier step or this turn's compacted steps used gets an fx id" {
    const alloc = std.testing.allocator;
    const step = [_]types.ToolCall{.{ .id = "dup", .name = "edit", .arguments_json = "{}" }};
    const compacted = [_]types.ToolCall{.{ .id = "gone", .name = "edit", .arguments_json = "{}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &step },
        .{ .role = .tool, .tool_call_id = "dup", .content = "done" },
        .{ .role = .tool, .tool_call_id = "result_only", .content = "done" },
    };
    const current_turn_messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &compacted },
        .{ .role = .user, .content = "ignored", .tool_call_id = "user_field" },
    };
    var ids = try ReplyIds.init(alloc, .{ .messages = &messages, .current_turn_messages = &current_turn_messages });
    defer ids.deinit();
    try std.testing.expectEqualStrings("fx_call_1", try ids.assign("dup"));
    try std.testing.expectEqualStrings("fx_call_2", try ids.assign("gone"));
    try std.testing.expectEqualStrings("fx_call_3", try ids.assign("result_only"));
    try std.testing.expectEqualStrings("user_field", try ids.assign("user_field"));
}

test "fx ids skip every id the conversation holds, fx's own forms too" {
    const alloc = std.testing.allocator;
    const nonportable = "functions.read:0";
    var projection = try Projection.init(alloc, &.{.{ .role = .assistant, .tool_calls = &.{.{ .id = nonportable, .name = "read", .arguments_json = "{}" }} }});
    defer projection.deinit(alloc);
    const alias = projection.resolve(nonportable);
    const earlier = [_]types.ToolCall{
        .{ .id = nonportable, .name = "read", .arguments_json = "{}" },
        .{ .id = "fx_call_1", .name = "read", .arguments_json = "{}" },
        .{ .id = "fx_call_3", .name = "read", .arguments_json = "{}" },
    };
    const messages = [_]types.ChatMessage{.{ .role = .assistant, .tool_calls = &earlier }};
    var ids = try ReplyIds.init(alloc, .{ .messages = &messages });
    defer ids.deinit();
    try std.testing.expectEqualStrings("fx_call_2", try ids.assign(alias));
    try std.testing.expectEqualStrings("fx_call_4", try ids.assign("fx_call_1"));
    try std.testing.expectEqualStrings("fx_call_5", try ids.assign(null));
    try std.testing.expectEqualStrings("fx_call_6", try ids.assign("fx_call_5"));
}

test "a call from an earlier reply sent again keeps its id, once per reply" {
    const alloc = std.testing.allocator;
    const earlier = [_]types.ToolCall{
        .{ .id = "dup", .name = "subagent", .arguments_json = "{\"agent\":\"a\",\"message\":\"go\",\"n\":1}" },
        .{ .id = "raw", .name = "shell", .arguments_json = "not json" },
    };
    const compacted = [_]types.ToolCall{.{ .id = "gone", .name = "read", .arguments_json = "{}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &earlier },
        .{ .role = .tool, .tool_call_id = "result_only", .content = "done" },
    };
    var ids = try ReplyIds.init(alloc, .{ .messages = &messages, .current_turn_messages = &.{.{ .role = .assistant, .tool_calls = &compacted }} });
    defer ids.deinit();
    // Key order, whitespace, and escapes do not make arguments differ.
    try std.testing.expect(try ids.sameCallAgain("dup", "subagent", " { \"n\" : 1, \"message\":\"g\\u006f\", \"agent\":\"a\" } "));
    // Only one call of a reply keeps the id.
    try std.testing.expect(!try ids.sameCallAgain("dup", "subagent", "{\"agent\":\"a\",\"message\":\"go\",\"n\":1}"));
    try std.testing.expect(try ids.sameCallAgain("raw", "shell", "not json"));
    try std.testing.expect(try ids.sameCallAgain("gone", "read", "{}"));
    var other = try ReplyIds.init(alloc, .{ .messages = &messages });
    defer other.deinit();
    try std.testing.expect(!try other.sameCallAgain("dup", "subagent", "{\"agent\":\"a\",\"message\":\"go\",\"n\":1.0}"));
    try std.testing.expect(!try other.sameCallAgain("dup", "shell", "{\"agent\":\"a\",\"message\":\"go\",\"n\":1}"));
    try std.testing.expect(!try other.sameCallAgain("raw", "shell", "not  json"));
    try std.testing.expect(!try other.sameCallAgain("result_only", "read", "{}"));
    try std.testing.expect(!try other.sameCallAgain(null, "read", "{}"));
    try std.testing.expect(!try other.sameCallAgain("fresh", "read", "{}"));
}

test "a call sent again matches with or without the request wrapper fx takes off" {
    const alloc = std.testing.allocator;
    const earlier = [_]types.ToolCall{
        .{ .id = "unwrapped", .name = "subagent", .arguments_json = "{\"action\":\"message\",\"agent\":\"a\",\"message\":\"go\"}" },
        .{ .id = "wrapped", .name = "subagent", .arguments_json = "{\"request\":{\"action\":\"message\",\"agent\":\"a\",\"message\":\"go\"}}" },
    };
    var ids = try ReplyIds.init(alloc, .{ .messages = &.{.{ .role = .assistant, .tool_calls = &earlier }} });
    defer ids.deinit();
    try std.testing.expect(try ids.sameCallAgain("unwrapped", "subagent", "{\"request\":{\"message\":\"go\",\"agent\":\"a\",\"action\":\"message\"}}"));
    try std.testing.expect(try ids.sameCallAgain("wrapped", "subagent", "{\"action\":\"message\",\"agent\":\"a\",\"message\":\"go\"}"));
    var text = try ReplyIds.init(alloc, .{ .messages = &.{.{ .role = .assistant, .tool_calls = &earlier }} });
    defer text.deinit();
    try std.testing.expect(try text.sameCallAgain("unwrapped", "subagent", "{\"request\":\"{\\\"action\\\":\\\"message\\\",\\\"agent\\\":\\\"a\\\",\\\"message\\\":\\\"go\\\"}\"}"));
    try std.testing.expect(!try text.sameCallAgain("wrapped", "subagent", "{\"request\":{\"action\":\"message\",\"agent\":\"b\",\"message\":\"go\"}}"));
    try std.testing.expect(!try text.sameCallAgain("wrapped", "subagent", "{\"request\":{\"action\":\"message\",\"agent\":\"a\",\"message\":\"go\"},\"extra\":1}"));
}

test "a call sent again with arguments nested too deep to unwrap is compared as sent" {
    const alloc = std.testing.allocator;
    const opens: [300]u8 = @splat('[');
    const closes: [300]u8 = @splat(']');
    const inner = try std.mem.concat(alloc, u8, &.{ &opens, &closes });
    defer alloc.free(inner);
    const stored = try std.mem.concat(alloc, u8, &.{ "{\"a\":", inner, "}" });
    defer alloc.free(stored);
    const wrapped = try std.mem.concat(alloc, u8, &.{ "{\"request\":{\"a\":", inner, "}}" });
    defer alloc.free(wrapped);
    const spaced = try std.mem.concat(alloc, u8, &.{ "{ \"a\" : ", inner, " }" });
    defer alloc.free(spaced);
    const earlier = [_]types.ToolCall{
        .{ .id = "deep", .name = "subagent", .arguments_json = stored },
        .{ .id = "deep_too", .name = "subagent", .arguments_json = stored },
    };
    var ids = try ReplyIds.init(alloc, .{ .messages = &.{.{ .role = .assistant, .tool_calls = &earlier }} });
    defer ids.deinit();
    try std.testing.expect(!try ids.sameCallAgain("deep", "subagent", wrapped));
    try std.testing.expect(try ids.sameCallAgain("deep_too", "subagent", spaced));
}

test "a provider-run call keeps its id and later calls may not take it" {
    const alloc = std.testing.allocator;
    var ids = try ReplyIds.init(alloc, .{});
    defer ids.deinit();
    try ids.keep("ws_1");
    try ids.keep("");
    try std.testing.expectEqualStrings("fx_call_1", try ids.assign("ws_1"));
}

fn fuzzId(arena: std.mem.Allocator, smith: *std.testing.Smith) ![]const u8 {
    var buffer: [types.ConversationIdentity.max_bytes + 44]u8 = undefined;
    return arena.dupe(u8, buffer[0..smith.slice(&buffer)]);
}

/// A history and a reply of ids from the input, any bytes: every id fx
/// keeps is usable and new to the history, its aliases, and the reply, and
/// a usable id no other call has stays the call's id byte for byte.
fn fuzzReplyIds(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const history = try arena.alloc(types.ToolCall, smith.valueRangeAtMost(u8, 0, 6));
    for (history) |*call| {
        const id = try fuzzId(arena, smith);
        // A saved call always has an id.
        call.* = .{ .id = if (id.len == 0) "saved" else id, .name = "read", .arguments_json = "{}" };
    }
    const messages = [_]types.ChatMessage{.{ .role = .assistant, .tool_calls = history }};
    var ids = try ReplyIds.init(std.testing.allocator, .{ .messages = &messages });
    defer ids.deinit();

    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (history) |call| try used.put(arena, call.id, {});
    const projection = try Projection.init(arena, &messages);
    for (projection.owned.items) |alias| try used.put(arena, alias, {});
    for (0..smith.valueRangeAtMost(u8, 0, 12)) |_| {
        const source: ?[]const u8 = if (smith.value(bool)) try fuzzId(arena, smith) else null;
        const free = if (source) |id| usable(id) and !used.contains(id) else false;
        const id = try ids.assign(source);
        try std.testing.expect(usable(id));
        try std.testing.expect(!used.contains(id));
        if (free) {
            try std.testing.expectEqualStrings(source.?, id);
        } else {
            try std.testing.expect(std.mem.startsWith(u8, id, fx_id_prefix));
        }
        try used.put(arena, try arena.dupe(u8, id), {});
    }
}

test "reply call ids stay usable, new, and the provider's own when they can" {
    try std.testing.fuzz({}, fuzzReplyIds, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "\x02dup\x03dup\x01\x03dup\x01\x03dup",
            "\x01\x09fx_call_1\x04\x01\x00\x01\x09fx_call_1\x00",
            "\x02\x10functions.read:0\x02 \t\x03\x01\x04bad\xff\x01\x00",
        }) ++ @import("fuzz_corpus").reply_call_ids.*),
    });
}

fn reply_ids_allocation_case(alloc: std.mem.Allocator) !void {
    const calls = [_]types.ToolCall{
        .{ .id = "functions.read:0", .name = "read", .arguments_json = "{}" },
        .{ .id = "dup", .name = "read", .arguments_json = "{}" },
    };
    var ids = try ReplyIds.init(alloc, .{ .messages = &.{.{ .role = .assistant, .tool_calls = &calls }} });
    defer ids.deinit();
    try std.testing.expectEqualStrings("fx_call_1", try ids.assign("dup"));
    try std.testing.expectEqualStrings("kept", try ids.assign("kept"));
}

test "reply ids clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, reply_ids_allocation_case, .{});
}

test "portable tool call ids use an allocation-free identity projection" {
    var failing = std.testing.FailingAllocator.init(testing_allocator.no_resize, .{ .fail_index = 0 });
    const calls = [_]types.ToolCall{
        .{ .id = "call_ABC-123", .name = "read", .arguments_json = "{}" },
        .{ .id = text_utils.repeat("x", 64), .name = "read", .arguments_json = "{}" },
    };
    var projection = try Projection.init(failing.allocator(), &.{.{ .role = .assistant, .tool_calls = &calls }});
    defer projection.deinit(failing.allocator());
    for (calls) |call| try std.testing.expect(projection.resolve(call.id).ptr == call.id.ptr);
}

test "tool call id projection ignores fields not serialized for a role" {
    var failing = std.testing.FailingAllocator.init(testing_allocator.no_resize, .{ .fail_index = 0 });
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
    const sources = [_][]const u8{ "functions.read:0", "functions/read:0", " ", "\t\n", "é", text_utils.repeat("x", 65), text_utils.repeat("x", 256) };
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
        .{ .id = text_utils.repeat("x", 65), .name = "read", .arguments_json = "{}" },
    };
    var projection = try Projection.init(alloc, &.{.{ .role = .assistant, .tool_calls = &calls }});
    defer projection.deinit(alloc);
    for (calls) |call| try std.testing.expect(portable(projection.resolve(call.id)));
}

test "tool call id projection cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, allocation_failure_case, .{});
}
