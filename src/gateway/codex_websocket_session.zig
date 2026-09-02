const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");
const websocket_transport = @import("websocket_transport.zig");

const Allocator = std.mem.Allocator;
const pool_alloc = std.heap.c_allocator;

pub const health_budget: u8 = 3;
pub const default_max_connection_age_ms: i64 = 55 * 60 * 1000;
const default_max_lanes: usize = 4;
const default_max_slots: usize = 32;
const max_connection_age_env = "FX_CODEX_WEBSOCKET_MAX_CONNECTION_AGE_MS";
const max_lanes_env = "FX_CODEX_WEBSOCKET_MAX_LANES";
const max_slots_env = "FX_CODEX_WEBSOCKET_MAX_SLOTS";

const Slot = struct {
    session_id: []u8,
    account_id: []u8,
    model: []u8,
    endpoint: []u8,
    authorization_fingerprint: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    connection: ?*websocket_transport.Connection,
    busy: bool,
    health_failures: u8,
    opened_at_ms: i64,
    last_used_at_ms: i64,
    continuation_response_id: ?[]u8,
    continuation_baseline: ?[]u8,
    continuation_durable_baseline: ?[]u8,
    continuation_shape: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    continuation_valid: bool,

    fn clearContinuation(self: *Slot) void {
        if (self.continuation_response_id) |value| pool_alloc.free(value);
        if (self.continuation_baseline) |value| pool_alloc.free(value);
        if (self.continuation_durable_baseline) |value| pool_alloc.free(value);
        self.continuation_response_id = null;
        self.continuation_baseline = null;
        self.continuation_durable_baseline = null;
        self.continuation_valid = false;
    }

    fn deinit(self: *Slot) void {
        if (self.connection) |connection| websocket_transport.close(connection, pool_alloc);
        self.clearContinuation();
        pool_alloc.free(self.session_id);
        pool_alloc.free(self.account_id);
        pool_alloc.free(self.model);
        pool_alloc.free(self.endpoint);
        self.* = undefined;
    }
};

var pool_mutex: std.Io.Mutex = .init;
var slots: std.ArrayList(Slot) = .empty;

pub const AcquireArgs = struct {
    session_id: ?[]const u8,
    account_id: []const u8,
    model: []const u8,
    endpoint: []const u8,
    authorization: []const u8,
    deadline: ?std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
    delivery: *gateway_client.DeliveryCertainty,
    continuation_input: ?[]const u8 = null,
    continuation_shape: ?[std.crypto.hash.sha2.Sha256.digest_length]u8 = null,
};

pub const Checkout = struct {
    slot: ?usize,
    connection: *websocket_transport.Connection,
    reused: bool,
    retained: bool,
    handshake_ms: i64,
    health_failures: u8,
};

pub const Continuation = struct {
    previous_response_id: []const u8,
    delta_input: []const u8,
};

fn continuationDelta(full_input: []const u8, baseline: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, full_input, baseline)) return null;
    if (full_input.len == baseline.len) return "";
    if (full_input[baseline.len] != ',') return null;
    return full_input[baseline.len + 1 ..];
}

pub const Outcome = enum { completed, failed };

fn sessionKey(session_id: ?[]const u8) []const u8 {
    const value = session_id orelse return "";
    return if (value.len == 0) "" else value;
}

fn authorizationFingerprint(authorization: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(authorization, &digest, .{});
    return digest;
}

fn matches(slot: *const Slot, args: AcquireArgs) bool {
    const fingerprint = authorizationFingerprint(args.authorization);
    return std.mem.eql(u8, slot.session_id, sessionKey(args.session_id)) and
        std.mem.eql(u8, slot.account_id, args.account_id) and
        std.mem.eql(u8, slot.model, args.model) and
        std.mem.eql(u8, slot.endpoint, args.endpoint) and
        std.mem.eql(u8, &slot.authorization_fingerprint, &fingerprint);
}

fn maxConnectionAgeMs() !i64 {
    const value = io_mod.getenv(max_connection_age_env) orelse return default_max_connection_age_ms;
    const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidOpenAICodexTransport;
    if (parsed < 0) return error.InvalidOpenAICodexTransport;
    return parsed;
}

fn maxLanes() !usize {
    const value = io_mod.getenv(max_lanes_env) orelse return default_max_lanes;
    const parsed = std.fmt.parseInt(usize, value, 10) catch return error.InvalidOpenAICodexTransport;
    if (parsed == 0) return error.InvalidOpenAICodexTransport;
    return parsed;
}

fn maxSlots() !usize {
    const value = io_mod.getenv(max_slots_env) orelse return default_max_slots;
    const parsed = std.fmt.parseInt(usize, value, 10) catch return error.InvalidOpenAICodexTransport;
    if (parsed == 0) return error.InvalidOpenAICodexTransport;
    return parsed;
}

fn initSlot(args: AcquireArgs, busy: bool) !Slot {
    const session_id = try pool_alloc.dupe(u8, sessionKey(args.session_id));
    errdefer pool_alloc.free(session_id);
    const account_id = try pool_alloc.dupe(u8, args.account_id);
    errdefer pool_alloc.free(account_id);
    const model = try pool_alloc.dupe(u8, args.model);
    errdefer pool_alloc.free(model);
    const endpoint = try pool_alloc.dupe(u8, args.endpoint);
    errdefer pool_alloc.free(endpoint);
    return .{
        .session_id = session_id,
        .account_id = account_id,
        .model = model,
        .endpoint = endpoint,
        .authorization_fingerprint = authorizationFingerprint(args.authorization),
        .connection = null,
        .busy = busy,
        .health_failures = 0,
        .opened_at_ms = 0,
        .last_used_at_ms = io_mod.milliTimestamp(),
        .continuation_response_id = null,
        .continuation_baseline = null,
        .continuation_durable_baseline = null,
        .continuation_shape = undefined,
        .continuation_valid = false,
    };
}

fn appendSlot(args: AcquireArgs, busy: bool) !usize {
    try slots.append(pool_alloc, try initSlot(args, busy));
    return slots.items.len - 1;
}

fn continuationMatches(slot: *const Slot, full_input: []const u8, shape: [std.crypto.hash.sha2.Sha256.digest_length]u8) bool {
    if (!slot.continuation_valid or !std.mem.eql(u8, &slot.continuation_shape, &shape)) return false;
    if (slot.continuation_baseline) |baseline| {
        if (continuationDelta(full_input, baseline) != null) return true;
    }
    if (slot.continuation_durable_baseline) |baseline| {
        if (continuationDelta(full_input, baseline) != null) return true;
    }
    return false;
}

const LaneSelection = struct {
    index: ?usize,
    matching_count: usize,
};

fn selectIdleLane(slot_items: []Slot, args: AcquireArgs) LaneSelection {
    var first_idle: ?usize = null;
    var continuation_idle: ?usize = null;
    var matching_count: usize = 0;
    for (slot_items, 0..) |*slot, index| {
        if (!matches(slot, args)) continue;
        matching_count += 1;
        if (slot.busy) continue;
        if (first_idle == null) first_idle = index;
        if (args.continuation_input) |full_input| {
            if (args.continuation_shape) |shape| {
                if (continuationMatches(slot, full_input, shape)) {
                    continuation_idle = index;
                    break;
                }
            }
        }
    }
    return .{ .index = continuation_idle orelse first_idle, .matching_count = matching_count };
}

const LaneChoice = union(enum) {
    existing: usize,
    append,
    temporary,
};

fn chooseLane(slot_items: []Slot, args: AcquireArgs, lane_limit: usize) LaneChoice {
    const selection = selectIdleLane(slot_items, args);
    if (selection.index) |index| return .{ .existing = index };
    if (selection.matching_count < lane_limit) return .append;
    return .temporary;
}

fn incrementFailure(slot: *Slot) void {
    slot.health_failures = std.math.add(u8, slot.health_failures, 1) catch std.math.maxInt(u8);
}

fn leastRecentlyUsedIdle(slot_items: []Slot) ?usize {
    var selected: ?usize = null;
    for (slot_items, 0..) |*slot, index| {
        if (slot.busy) continue;
        if (selected == null or slot.last_used_at_ms < slot_items[selected.?].last_used_at_ms) {
            selected = index;
        }
    }
    return selected;
}

fn incompatibleIdle(slot_items: []Slot, args: AcquireArgs) ?usize {
    for (slot_items, 0..) |*slot, index| {
        if (slot.busy or matches(slot, args)) continue;
        if (std.mem.eql(u8, slot.session_id, sessionKey(args.session_id))) return index;
    }
    return null;
}

fn replaceSlot(index: usize, args: AcquireArgs) !?*websocket_transport.Connection {
    const replacement = try initSlot(args, true);
    const displaced = slots.items[index].connection;
    slots.items[index].connection = null;
    slots.items[index].deinit();
    slots.items[index] = replacement;
    return displaced;
}

pub fn acquire(_: Allocator, args: AcquireArgs) !Checkout {
    if (args.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (args.deadline) |deadline| {
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) return error.Timeout;
    }

    const lane_limit = try maxLanes();
    const slot_limit = try maxSlots();
    const age_limit = try maxConnectionAgeMs();
    var index: ?usize = null;
    var retained = true;
    var reusable: ?*websocket_transport.Connection = null;
    var displaced: ?*websocket_transport.Connection = null;
    var prior_health: u8 = 0;

    pool_mutex.lockUncancelable(io_mod.getIo());
    switch (chooseLane(slots.items, args, lane_limit)) {
        .existing => |existing| {
            index = existing;
            const slot = &slots.items[existing];
            slot.busy = true;
            prior_health = slot.health_failures;
            const expired = age_limit != 0 and
                io_mod.milliTimestamp() - slot.opened_at_ms > age_limit;
            if (slot.connection != null and slot.health_failures < health_budget and !expired) {
                reusable = slot.connection;
            } else {
                displaced = slot.connection;
                slot.connection = null;
                slot.clearContinuation();
            }
        },
        .append => {
            if (incompatibleIdle(slots.items, args)) |victim| {
                index = victim;
                displaced = replaceSlot(victim, args) catch |err| {
                    pool_mutex.unlock(io_mod.getIo());
                    return err;
                };
            } else if (slots.items.len < slot_limit) {
                index = appendSlot(args, true) catch |err| {
                    pool_mutex.unlock(io_mod.getIo());
                    return err;
                };
            } else if (leastRecentlyUsedIdle(slots.items)) |victim| {
                index = victim;
                displaced = replaceSlot(victim, args) catch |err| {
                    pool_mutex.unlock(io_mod.getIo());
                    return err;
                };
            } else {
                retained = false;
            }
        },
        .temporary => retained = false,
    }
    pool_mutex.unlock(io_mod.getIo());

    // Socket close, health checks, and connection establishment are all
    // deliberately outside the global pool mutex.
    if (displaced) |connection| websocket_transport.close(connection, pool_alloc);
    if (reusable) |connection| {
        websocket_transport.ping(connection, args.cancel_flag, args.deadline, args.delivery) catch |err| {
            websocket_transport.close(connection, pool_alloc);
            pool_mutex.lockUncancelable(io_mod.getIo());
            if (index) |slot_index| {
                const slot = &slots.items[slot_index];
                if (slot.connection == connection) slot.connection = null;
                slot.clearContinuation();
                incrementFailure(slot);
                prior_health = slot.health_failures;
            }
            pool_mutex.unlock(io_mod.getIo());
            if (err == error.Cancelled) {
                rollbackReservation(index);
                return err;
            }
            reusable = null;
        };
        if (reusable != null) {
            return .{
                .slot = index,
                .connection = connection,
                .reused = true,
                .retained = retained,
                .handshake_ms = 0,
                .health_failures = prior_health,
            };
        }
    }

    const started_at_ms = io_mod.milliTimestamp();
    const connection = websocket_transport.connect(pool_alloc, .{
        .endpoint = args.endpoint,
        .authorization = args.authorization,
        .account_id = args.account_id,
        .session_id = args.session_id,
        .deadline = args.deadline,
        .cancel_flag = args.cancel_flag,
        .delivery = args.delivery,
    }) catch |err| {
        rollbackReservation(index);
        return err;
    };
    if (index) |slot_index| {
        pool_mutex.lockUncancelable(io_mod.getIo());
        const slot = &slots.items[slot_index];
        slot.connection = connection;
        slot.clearContinuation();
        slot.opened_at_ms = connection.opened_at_ms;
        slot.last_used_at_ms = io_mod.milliTimestamp();
        pool_mutex.unlock(io_mod.getIo());
    }
    return .{
        .slot = index,
        .connection = connection,
        .reused = false,
        .retained = retained,
        .handshake_ms = @max(io_mod.milliTimestamp() - started_at_ms, 0),
        .health_failures = prior_health,
    };
}

fn rollbackReservation(index: ?usize) void {
    const slot_index = index orelse return;
    pool_mutex.lockUncancelable(io_mod.getIo());
    if (slot_index < slots.items.len) slots.items[slot_index].busy = false;
    pool_mutex.unlock(io_mod.getIo());
}

pub fn continuation(
    index: ?usize,
    full_input: []const u8,
    shape: [std.crypto.hash.sha2.Sha256.digest_length]u8,
) ?Continuation {
    const slot_index = index orelse return null;
    pool_mutex.lockUncancelable(io_mod.getIo());
    defer pool_mutex.unlock(io_mod.getIo());
    if (slot_index >= slots.items.len) return null;
    const slot = &slots.items[slot_index];
    if (!slot.busy or !slot.continuation_valid) return null;
    if (!std.mem.eql(u8, &slot.continuation_shape, &shape)) {
        slot.clearContinuation();
        return null;
    }
    const response_id = slot.continuation_response_id orelse return null;
    const baseline = slot.continuation_baseline orelse return null;
    const delta = continuationDelta(full_input, baseline) orelse durable: {
        const durable_baseline = slot.continuation_durable_baseline orelse {
            slot.clearContinuation();
            return null;
        };
        break :durable continuationDelta(full_input, durable_baseline) orelse {
            slot.clearContinuation();
            return null;
        };
    };
    return .{
        .previous_response_id = response_id,
        .delta_input = delta,
    };
}

pub fn recordCompletion(
    index: ?usize,
    response_id: []const u8,
    baseline: []const u8,
    durable_baseline: []const u8,
    shape: [std.crypto.hash.sha2.Sha256.digest_length]u8,
) void {
    const slot_index = index orelse return;
    pool_mutex.lockUncancelable(io_mod.getIo());
    defer pool_mutex.unlock(io_mod.getIo());
    if (slot_index >= slots.items.len) return;
    const slot = &slots.items[slot_index];
    slot.clearContinuation();
    const owned_id = pool_alloc.dupe(u8, response_id) catch return;
    const owned_baseline = pool_alloc.dupe(u8, baseline) catch {
        pool_alloc.free(owned_id);
        return;
    };
    const owned_durable_baseline = pool_alloc.dupe(u8, durable_baseline) catch {
        pool_alloc.free(owned_id);
        pool_alloc.free(owned_baseline);
        return;
    };
    slot.continuation_response_id = owned_id;
    slot.continuation_baseline = owned_baseline;
    slot.continuation_durable_baseline = owned_durable_baseline;
    slot.continuation_shape = shape;
    slot.continuation_valid = true;
}

pub fn release(checkout: Checkout, outcome: Outcome) void {
    const index = checkout.slot orelse {
        websocket_transport.close(checkout.connection, pool_alloc);
        return;
    };
    var discarded: ?*websocket_transport.Connection = null;
    pool_mutex.lockUncancelable(io_mod.getIo());
    if (index >= slots.items.len) {
        pool_mutex.unlock(io_mod.getIo());
        websocket_transport.close(checkout.connection, pool_alloc);
        return;
    }
    const slot = &slots.items[index];
    slot.busy = false;
    slot.last_used_at_ms = io_mod.milliTimestamp();
    switch (outcome) {
        .completed => slot.health_failures = 0,
        .failed => {
            incrementFailure(slot);
            discarded = slot.connection;
            slot.connection = null;
            slot.clearContinuation();
        },
    }
    pool_mutex.unlock(io_mod.getIo());
    if (discarded) |connection| websocket_transport.close(connection, pool_alloc);
}

pub fn shutdown() void {
    pool_mutex.lockUncancelable(io_mod.getIo());
    const retired = slots;
    slots = .empty;
    pool_mutex.unlock(io_mod.getIo());
    var owned = retired;
    for (owned.items) |*slot| slot.deinit();
    owned.deinit(pool_alloc);
}

test "retained Codex WebSocket identity includes authorization without storing it" {
    const slot = Slot{
        .session_id = @constCast("session-a"),
        .account_id = @constCast("account-a"),
        .model = @constCast("gpt-5.6-sol"),
        .endpoint = @constCast("http://127.0.0.1/responses"),
        .authorization_fingerprint = authorizationFingerprint("Bearer token-a"),
        .connection = null,
        .busy = false,
        .health_failures = 0,
        .opened_at_ms = 0,
        .last_used_at_ms = 0,
        .continuation_response_id = null,
        .continuation_baseline = null,
        .continuation_durable_baseline = null,
        .continuation_shape = undefined,
        .continuation_valid = false,
    };
    const base = AcquireArgs{
        .session_id = "session-a",
        .account_id = "account-a",
        .model = "gpt-5.6-sol",
        .endpoint = "http://127.0.0.1/responses",
        .authorization = "Bearer token-a",
        .deadline = null,
        .cancel_flag = undefined,
        .delivery = undefined,
    };

    try std.testing.expect(matches(&slot, base));

    var rotated = base;
    rotated.authorization = "Bearer token-b";
    try std.testing.expect(!matches(&slot, rotated));

    var changed_model = base;
    changed_model.model = "gpt-5.4";
    try std.testing.expect(!matches(&slot, changed_model));
}

test "Codex WebSocket continuation requires an exact item boundary prefix" {
    try std.testing.expectEqualStrings(
        "{\"role\":\"user\",\"content\":[]}",
        continuationDelta(
            "{\"type\":\"message\"},{\"role\":\"user\",\"content\":[]}",
            "{\"type\":\"message\"}",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "",
        continuationDelta("{\"type\":\"message\"}", "{\"type\":\"message\"}").?,
    );
    try std.testing.expect(continuationDelta("{\"type\":\"message\"}suffix", "{\"type\":\"message\"}") == null);
    try std.testing.expect(continuationDelta("{\"type\":\"other\"}", "{\"type\":\"message\"}") == null);
}

test "Codex WebSocket lane selection preserves continuation affinity" {
    shutdown();
    defer shutdown();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    var shape: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("shape", &shape, .{});
    const args = AcquireArgs{
        .session_id = "session-a",
        .account_id = "account-a",
        .model = "gpt-5.6-sol",
        .endpoint = "http://127.0.0.1/responses",
        .authorization = "Bearer token-a",
        .deadline = null,
        .cancel_flag = &cancel_flag,
        .delivery = &delivery,
        .continuation_input = "{\"type\":\"message\"},{\"role\":\"user\"}",
        .continuation_shape = shape,
    };

    const first = try appendSlot(args, false);
    slots.items[first].busy = true;
    const second = try appendSlot(args, false);
    slots.items[second].busy = true;
    recordCompletion(second, "response-2", "{\"type\":\"message\"}", "{\"type\":\"message\"}", shape);
    slots.items[second].busy = false;

    const selection = chooseLane(slots.items, args, 2);
    try std.testing.expectEqual(second, selection.existing);

    slots.items[second].busy = true;
    try std.testing.expect(chooseLane(slots.items, args, 2) == .temporary);
    try std.testing.expect(chooseLane(slots.items, args, 3) == .append);
}

test "Codex WebSocket global slot eviction selects the least recently used idle lane" {
    shutdown();
    defer shutdown();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const args = AcquireArgs{
        .session_id = "session-a",
        .account_id = "account-a",
        .model = "gpt-5.6-sol",
        .endpoint = "http://127.0.0.1/responses",
        .authorization = "Bearer token-a",
        .deadline = null,
        .cancel_flag = &cancel_flag,
        .delivery = &delivery,
    };
    _ = try appendSlot(args, false);
    _ = try appendSlot(args, false);
    _ = try appendSlot(args, false);
    slots.items[0].last_used_at_ms = 30;
    slots.items[1].last_used_at_ms = 10;
    slots.items[2].last_used_at_ms = 20;
    slots.items[1].busy = true;

    try std.testing.expectEqual(@as(?usize, 2), leastRecentlyUsedIdle(slots.items));
    try std.testing.expectEqual(@as(usize, 3), slots.items.len);
}

test "Codex WebSocket slot storage remains bounded under identity churn" {
    shutdown();
    defer shutdown();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    var session_buffer: [32]u8 = undefined;
    var args = AcquireArgs{
        .session_id = "",
        .account_id = "account-a",
        .model = "gpt-5.6-sol",
        .endpoint = "http://127.0.0.1/responses",
        .authorization = "Bearer token-a",
        .deadline = null,
        .cancel_flag = &cancel_flag,
        .delivery = &delivery,
    };
    const limit: usize = 3;
    for (0..64) |identity| {
        args.session_id = try std.fmt.bufPrint(&session_buffer, "session-{d}", .{identity});
        if (slots.items.len < limit) {
            _ = try appendSlot(args, false);
        } else {
            const victim = leastRecentlyUsedIdle(slots.items).?;
            _ = try replaceSlot(victim, args);
            slots.items[victim].busy = false;
            slots.items[victim].last_used_at_ms = @intCast(identity);
        }
        try std.testing.expect(slots.items.len <= limit);
    }
    try std.testing.expectEqual(limit, slots.items.len);
}
