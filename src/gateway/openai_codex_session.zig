//! Provider-owned state for Codex's reusable Responses transport.
const std = @import("std");
const secret = @import("../core/auth/secret.zig");
const websocket = @import("openai_codex_websocket.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const max_sessions: usize = 128;

const EffortTransition = struct {
    index: usize,
    anchor: []u8,
    effort: []u8,
};

pub const SessionState = struct {
    alloc: Allocator,
    session_id: []u8,
    model: []u8,
    account_id: []u8,
    endpoint: []u8,
    authorization: []u8,
    connection: ?websocket.Client = null,
    last_request_json: ?[]u8 = null,
    last_response_id: ?[]u8 = null,
    last_response_items_json: ?[]u8 = null,
    models_etag: ?[]u8 = null,
    turn_state: ?[]u8 = null,
    effort_base: ?[]u8 = null,
    effort_current: ?[]u8 = null,
    effort_transitions: std.ArrayList(EffortTransition) = .empty,
    can_append: bool = false,
    active: bool = false,
    last_used_ms: i64 = 0,

    fn init(
        alloc: Allocator,
        session_id: []const u8,
        model: []const u8,
        account_id: []const u8,
        endpoint: []const u8,
        authorization: []const u8,
    ) !SessionState {
        var state = SessionState{
            .alloc = alloc,
            .session_id = try alloc.dupe(u8, session_id),
            .model = undefined,
            .account_id = undefined,
            .endpoint = undefined,
            .authorization = undefined,
        };
        errdefer state.deinit();
        state.model = try alloc.dupe(u8, model);
        state.account_id = try alloc.dupe(u8, account_id);
        state.endpoint = try alloc.dupe(u8, endpoint);
        state.authorization = try alloc.dupe(u8, authorization);
        return state;
    }

    pub fn deinit(self: *SessionState) void {
        if (self.connection) |*connection| connection.deinit();
        self.freeOptional(&self.last_request_json);
        self.freeOptional(&self.last_response_id);
        self.freeOptional(&self.last_response_items_json);
        self.freeOptional(&self.models_etag);
        self.freeOptional(&self.turn_state);
        self.clearEffortControl();
        secret.zeroAndFree(self.alloc, self.authorization);
        self.alloc.free(self.session_id);
        self.alloc.free(self.model);
        self.alloc.free(self.account_id);
        self.alloc.free(self.endpoint);
        self.* = undefined;
    }

    fn freeOptional(self: *SessionState, value: *?[]u8) void {
        if (value.*) |bytes| self.alloc.free(bytes);
        value.* = null;
    }

    pub fn resetAppend(self: *SessionState) void {
        self.freeOptional(&self.last_request_json);
        self.freeOptional(&self.last_response_id);
        self.freeOptional(&self.last_response_items_json);
        self.models_etag = self.replaceOptional(self.models_etag, null);
        self.can_append = false;
    }

    fn clearEffortControl(self: *SessionState) void {
        self.freeOptional(&self.effort_base);
        self.freeOptional(&self.effort_current);
        for (self.effort_transitions.items) |transition| {
            self.alloc.free(transition.anchor);
            self.alloc.free(transition.effort);
        }
        self.effort_transitions.deinit(self.alloc);
        self.effort_transitions = .empty;
    }

    fn setOptionalOwned(self: *SessionState, slot: *?[]u8, value: []const u8) !void {
        const copy = try self.alloc.dupe(u8, value);
        if (slot.*) |old| self.alloc.free(old);
        slot.* = copy;
    }

    fn stableAnchor(self: *SessionState, value: std.json.Value) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer out.deinit();
        if (value == .object) {
            try out.writer.writeByte('{');
            var first = true;
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "id") or std.mem.eql(u8, entry.key_ptr.*, "status")) continue;
                if (!first) try out.writer.writeByte(',');
                first = false;
                try std.json.Stringify.value(entry.key_ptr.*, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(entry.value_ptr.*, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        } else {
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        return out.toOwnedSlice();
    }

    fn transitionPrecedingEffort(self: *SessionState, index: usize) []const u8 {
        const base = self.effort_base orelse return "";
        var result = base;
        var preceding: usize = 0;
        for (self.effort_transitions.items) |transition| {
            if (transition.index < index and (preceding == 0 or transition.index >= preceding)) {
                result = transition.effort;
                preceding = transition.index;
            }
        }
        return result;
    }

    fn makeConfigurationUpdate(alloc: Allocator, effort: []const u8) !std.json.Value {
        var reasoning = std.json.ObjectMap.empty;
        errdefer reasoning.deinit(alloc);
        try reasoning.put(alloc, "effort", .{ .string = effort });
        var item = std.json.ObjectMap.empty;
        errdefer item.deinit(alloc);
        try item.put(alloc, "type", .{ .string = "configuration_update" });
        try item.put(alloc, "reasoning", .{ .object = reasoning });
        return .{ .object = item };
    }

    /// Plans stable Responses reasoning effort for one stateful Codex session.
    /// The request-level effort is pinned to the first named effort and later
    /// changes are replayed as configuration_update input items.
    pub fn planEffort(
        self: *SessionState,
        json_alloc: Allocator,
        input: *std.json.Array,
        requested: ?[]const u8,
    ) !?[]const u8 {
        const effort = requested orelse return null;
        if (effort.len == 0 or std.mem.eql(u8, effort, "auto") or std.mem.eql(u8, effort, "none")) return null;

        for (self.effort_transitions.items) |transition| {
            if (transition.index > input.items.len) {
                self.clearEffortControl();
                break;
            }
            const anchor = if (transition.index == 0)
                try self.alloc.dupe(u8, "")
            else
                try self.stableAnchor(input.items[transition.index - 1]);
            defer self.alloc.free(anchor);
            if (!std.mem.eql(u8, anchor, transition.anchor)) {
                self.clearEffortControl();
                break;
            }
        }

        if (self.effort_base == null) {
            try self.setOptionalOwned(&self.effort_base, effort);
            try self.setOptionalOwned(&self.effort_current, effort);
        } else if (!std.mem.eql(u8, self.effort_current.?, effort)) {
            var index: usize = input.items.len;
            if (input.items.len > 0) {
                const last = input.items[input.items.len - 1];
                if (last == .object) {
                    if (last.object.get("role")) |role| {
                        if (role == .string and std.mem.eql(u8, role.string, "user")) index -= 1;
                    }
                }
            }
            const anchor = if (index == 0) try self.alloc.dupe(u8, "") else try self.stableAnchor(input.items[index - 1]);
            errdefer self.alloc.free(anchor);
            var found: ?usize = null;
            for (self.effort_transitions.items, 0..) |transition, transition_index| {
                if (transition.index == index) {
                    found = transition_index;
                    break;
                }
            }
            try self.setOptionalOwned(&self.effort_current, effort);
            if (found) |transition_index| {
                const effort_copy = try self.alloc.dupe(u8, effort);
                self.alloc.free(self.effort_transitions.items[transition_index].anchor);
                self.alloc.free(self.effort_transitions.items[transition_index].effort);
                self.effort_transitions.items[transition_index] = .{ .index = index, .anchor = anchor, .effort = effort_copy };
            } else {
                try self.effort_transitions.append(self.alloc, .{ .index = index, .anchor = anchor, .effort = try self.alloc.dupe(u8, effort) });
            }
            const preceding = self.transitionPrecedingEffort(index);
            if (std.mem.eql(u8, preceding, effort)) {
                var remove_index: ?usize = null;
                for (self.effort_transitions.items, 0..) |transition, transition_index| {
                    if (transition.index == index) {
                        remove_index = transition_index;
                        break;
                    }
                }
                if (remove_index) |transition_index| {
                    const removed = self.effort_transitions.orderedRemove(transition_index);
                    self.alloc.free(removed.anchor);
                    self.alloc.free(removed.effort);
                }
            }
        }

        var offset: usize = 0;
        for (self.effort_transitions.items) |transition| {
            var item = try makeConfigurationUpdate(json_alloc, transition.effort);
            input.insert(transition.index + offset, item) catch |err| {
                if (item == .object) item.object.deinit(json_alloc);
                return err;
            };
            offset += 1;
        }
        return self.effort_base;
    }

    pub fn replaceOptional(self: *SessionState, old: ?[]u8, value: ?[]const u8) ?[]u8 {
        if (old) |bytes| self.alloc.free(bytes);
        return if (value) |bytes| self.alloc.dupe(u8, bytes) catch null else null;
    }

    pub fn setRequest(self: *SessionState, value: []const u8) !void {
        self.freeOptional(&self.last_request_json);
        self.last_request_json = try self.alloc.dupe(u8, value);
    }

    pub fn setResponse(self: *SessionState, id: []const u8, items: []const u8) !void {
        self.freeOptional(&self.last_response_id);
        self.freeOptional(&self.last_response_items_json);
        self.last_response_id = try self.alloc.dupe(u8, id);
        self.last_response_items_json = try self.alloc.dupe(u8, items);
        self.can_append = true;
    }
};

pub const TransportState = struct {
    alloc: Allocator,
    sessions: std.ArrayList(SessionState) = .empty,

    pub fn init(alloc: Allocator) TransportState {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *TransportState) void {
        for (self.sessions.items) |*session| session.deinit();
        self.sessions.deinit(self.alloc);
        self.* = undefined;
    }

    /// Returns the per-conversation state. A null session deliberately opts
    /// out of reuse because there is no durable conversation identity.
    pub fn get(
        self: *TransportState,
        session_id: ?[]const u8,
        model: []const u8,
        account_id: []const u8,
        endpoint: []const u8,
        authorization: []const u8,
    ) !?*SessionState {
        const id = session_id orelse return null;
        if (id.len == 0) return null;
        for (self.sessions.items) |*session| {
            if (!std.mem.eql(u8, session.session_id, id)) continue;
            if (!std.mem.eql(u8, session.model, model) or
                !std.mem.eql(u8, session.account_id, account_id) or
                !std.mem.eql(u8, session.endpoint, endpoint) or
                !std.mem.eql(u8, session.authorization, authorization))
            {
                session.resetAppend();
                session.clearEffortControl();
                if (session.connection) |*connection| connection.deinit();
                session.connection = null;
                self.alloc.free(session.model);
                self.alloc.free(session.account_id);
                self.alloc.free(session.endpoint);
                secret.zeroAndFree(self.alloc, session.authorization);
                session.model = try self.alloc.dupe(u8, model);
                session.account_id = try self.alloc.dupe(u8, account_id);
                session.endpoint = try self.alloc.dupe(u8, endpoint);
                session.authorization = try self.alloc.dupe(u8, authorization);
            }
            session.last_used_ms = io_mod.monotonicMilliTimestamp();
            return session;
        }
        if (self.sessions.items.len >= max_sessions) {
            var oldest: usize = 0;
            for (self.sessions.items[1..], 1..) |session, index| {
                if (session.active) continue;
                if (self.sessions.items[oldest].active or session.last_used_ms < self.sessions.items[oldest].last_used_ms) oldest = index;
            }
            if (self.sessions.items[oldest].active) return error.CodexTransportStateBusy;
            self.sessions.items[oldest].deinit();
            _ = self.sessions.orderedRemove(oldest);
        }
        try self.sessions.append(self.alloc, try SessionState.init(self.alloc, id, model, account_id, endpoint, authorization));
        self.sessions.items[self.sessions.items.len - 1].last_used_ms = io_mod.monotonicMilliTimestamp();
        return &self.sessions.items[self.sessions.items.len - 1];
    }
};

test "Codex transport state resets a stale conversation when credentials change" {
    var state = TransportState.init(std.testing.allocator);
    defer state.deinit();
    const first = (try state.get("s", "m", "a", "u", "Bearer one")).?;
    try first.setRequest("{}");
    first.can_append = true;
    const second = (try state.get("s", "m", "a", "u", "Bearer two")).?;
    try std.testing.expect(first == second);
    try std.testing.expect(!second.can_append);
    try std.testing.expectEqualStrings("Bearer two", second.authorization);
}

test "Codex configuration update keeps baseline effort and replays transitions" {
    var state = TransportState.init(std.testing.allocator);
    defer state.deinit();
    const session = (try state.get("s", "m", "a", "u", "")).?;

    var first = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"reasoning\":{\"effort\":\"low\"},\"input\":[{\"role\":\"user\",\"content\":\"one\"}]}", .{});
    defer first.deinit();
    const baseline = (try session.planEffort(
        first.arena.allocator(),
        &first.value.object.getPtr("input").?.array,
        "low",
    )).?;
    try std.testing.expectEqualStrings("low", baseline);

    var second = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"reasoning\":{\"effort\":\"high\"},\"input\":[{\"role\":\"user\",\"content\":\"one\"},{\"role\":\"user\",\"content\":\"two\"}]}", .{});
    defer second.deinit();
    const second_input = second.value.object.getPtr("input").?;
    _ = try session.planEffort(second.arena.allocator(), &second_input.array, "high");
    try std.testing.expectEqual(@as(usize, 3), second_input.array.items.len);
    try std.testing.expectEqualStrings(
        "configuration_update",
        second_input.array.items[1].object.get("type").?.string,
    );
    try std.testing.expectEqualStrings(
        "high",
        second_input.array.items[1].object.get("reasoning").?.object.get("effort").?.string,
    );
}
