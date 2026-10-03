const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");
const websocket_transport = @import("websocket_transport.zig");

const Allocator = std.mem.Allocator;
const pool_alloc = if (@import("builtin").is_test) std.testing.allocator else std.heap.c_allocator;

pub const default_max_connection_age_ms: i64 = 55 * 60 * 1000;
const default_idle_timeout_ms: i64 = 5 * 60 * 1000;
const default_max_lanes: usize = 4;
const default_max_slots: usize = 32;
const max_connection_age_env = "FX_CODEX_WEBSOCKET_MAX_CONNECTION_AGE_MS";
const max_lanes_env = "FX_CODEX_WEBSOCKET_MAX_LANES";
const max_slots_env = "FX_CODEX_WEBSOCKET_MAX_SLOTS";
const idle_timeout_env = "FX_CODEX_WEBSOCKET_IDLE_TIMEOUT_MS";

const Slot = struct {
    session_id: []u8,
    account_id: []u8,
    model: []u8,
    endpoint: []u8,
    authorization_fingerprint: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    connection: ?*websocket_transport.Connection,
    busy: bool,
    retired: bool = false,
    lane_id: u64 = 0,
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
        pool_alloc.destroy(self);
    }
};

var pool_mutex: std.Io.Mutex = .init;
var slots: std.ArrayList(*Slot) = .empty;
var next_lane_id: u64 = 1;

pub const AcquireArgs = struct {
    session_id: ?[]const u8,
    account_id: []const u8,
    model: []const u8,
    endpoint: []const u8,
    authorization: []const u8,
    deadline: ?std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
    delivery: *gateway_client.DeliveryCertainty,
    upgrade_status: ?*?std.http.Status = null,
    force_fresh_connection: bool = false,
    continuation_input: ?[]const u8 = null,
    continuation_shape: ?[std.crypto.hash.sha2.Sha256.digest_length]u8 = null,
};

pub const Checkout = struct {
    slot: ?*Slot,
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

fn parse_idle_timeout(value: ?[]const u8) !i64 {
    const raw = value orelse return default_idle_timeout_ms;
    const parsed = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidOpenAICodexTransport;
    if (parsed <= 0) return error.InvalidOpenAICodexTransport;
    return parsed;
}

fn connection_expired(opened_at_ms: i64, last_used_at_ms: i64, now_ms: i64, age_limit: i64, idle_limit: i64) bool {
    return (age_limit != 0 and now_ms - opened_at_ms >= age_limit) or
        now_ms - last_used_at_ms >= idle_limit;
}

fn caller_deadline_expired(deadline: ?std.Io.Clock.Timestamp) bool {
    const limit = deadline orelse return false;
    return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake), .lt, limit);
}

fn stale_connection_error(err: anyerror) bool {
    return gateway_client.isConnectivityFailure(err) or gateway_client.isRetryableGatewayError(err) or
        switch (err) {
            error.Timeout, error.ReadFailed, error.WriteFailed, error.WouldBlock, error.EndOfStream, error.WebSocketClosedBeforeCompletion => true,
            else => false,
        };
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

fn initSlot(args: AcquireArgs, busy: bool) !*Slot {
    const slot = try pool_alloc.create(Slot);
    errdefer pool_alloc.destroy(slot);
    const session_id = try pool_alloc.dupe(u8, sessionKey(args.session_id));
    errdefer pool_alloc.free(session_id);
    const account_id = try pool_alloc.dupe(u8, args.account_id);
    errdefer pool_alloc.free(account_id);
    const model = try pool_alloc.dupe(u8, args.model);
    errdefer pool_alloc.free(model);
    const endpoint = try pool_alloc.dupe(u8, args.endpoint);
    errdefer pool_alloc.free(endpoint);
    slot.* = .{
        .session_id = session_id,
        .account_id = account_id,
        .model = model,
        .endpoint = endpoint,
        .authorization_fingerprint = authorizationFingerprint(args.authorization),
        .connection = null,
        .busy = busy,
        .lane_id = next_lane_id,
        .health_failures = 0,
        .opened_at_ms = 0,
        .last_used_at_ms = io_mod.milliTimestamp(),
        .continuation_response_id = null,
        .continuation_baseline = null,
        .continuation_durable_baseline = null,
        .continuation_shape = undefined,
        .continuation_valid = false,
    };
    next_lane_id += 1;
    return slot;
}

fn appendSlot(args: AcquireArgs, busy: bool) !*Slot {
    const slot = try initSlot(args, busy);
    errdefer slot.deinit();
    try slots.append(pool_alloc, slot);
    return slot;
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

fn selectIdleLane(slot_items: []const *Slot, args: AcquireArgs) LaneSelection {
    var first_idle: ?usize = null;
    var continuation_idle: ?usize = null;
    var matching_count: usize = 0;
    for (slot_items, 0..) |slot, index| {
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

fn chooseLane(slot_items: []const *Slot, args: AcquireArgs, lane_limit: usize) LaneChoice {
    const selection = selectIdleLane(slot_items, args);
    if (selection.index) |index| return .{ .existing = index };
    if (selection.matching_count < lane_limit) return .append;
    return .temporary;
}

fn incrementFailure(slot: *Slot) void {
    slot.health_failures = std.math.add(u8, slot.health_failures, 1) catch std.math.maxInt(u8);
}

fn leastRecentlyUsedIdle(slot_items: []const *Slot) ?usize {
    var selected: ?usize = null;
    for (slot_items, 0..) |slot, index| {
        if (slot.busy) continue;
        if (selected == null or slot.last_used_at_ms < slot_items[selected.?].last_used_at_ms) {
            selected = index;
        }
    }
    return selected;
}

fn incompatibleIdle(slot_items: []const *Slot, args: AcquireArgs) ?usize {
    for (slot_items, 0..) |slot, index| {
        if (slot.busy or matches(slot, args)) continue;
        if (std.mem.eql(u8, slot.session_id, sessionKey(args.session_id))) return index;
    }
    return null;
}

fn replaceSlot(index: usize, args: AcquireArgs) !*Slot {
    const replacement = try initSlot(args, true);
    const displaced = slots.items[index];
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
    const idle_limit = try parse_idle_timeout(io_mod.getenv(idle_timeout_env));
    var reserved: ?*Slot = null;
    var retained = true;
    var reusable: ?*websocket_transport.Connection = null;
    var displaced: ?*websocket_transport.Connection = null;
    var displaced_slot: ?*Slot = null;
    var prior_health: u8 = 0;

    pool_mutex.lockUncancelable(io_mod.getIo());
    switch (chooseLane(slots.items, args, lane_limit)) {
        .existing => |existing| {
            const slot = slots.items[existing];
            reserved = slot;
            slot.busy = true;
            prior_health = slot.health_failures;
            const expired = connection_expired(slot.opened_at_ms, slot.last_used_at_ms, io_mod.milliTimestamp(), age_limit, idle_limit);
            if (slot.connection != null and !expired and !args.force_fresh_connection) {
                reusable = slot.connection;
            } else {
                displaced = slot.connection;
                slot.connection = null;
                slot.clearContinuation();
            }
        },
        .append => {
            if (incompatibleIdle(slots.items, args)) |victim| {
                displaced_slot = replaceSlot(victim, args) catch |err| {
                    pool_mutex.unlock(io_mod.getIo());
                    return err;
                };
                reserved = slots.items[victim];
            } else if (slots.items.len < slot_limit) {
                reserved = appendSlot(args, true) catch |err| {
                    pool_mutex.unlock(io_mod.getIo());
                    return err;
                };
            } else if (leastRecentlyUsedIdle(slots.items)) |victim| {
                displaced_slot = replaceSlot(victim, args) catch |err| {
                    pool_mutex.unlock(io_mod.getIo());
                    return err;
                };
                reserved = slots.items[victim];
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
    if (displaced_slot) |slot| slot.deinit();
    if (reusable) |connection| {
        websocket_transport.ping(connection, args.cancel_flag, args.deadline, args.delivery) catch |err| {
            websocket_transport.abort(connection, pool_alloc);
            pool_mutex.lockUncancelable(io_mod.getIo());
            if (reserved) |slot| {
                if (slot.connection == connection) slot.connection = null;
                slot.clearContinuation();
                incrementFailure(slot);
                prior_health = slot.health_failures;
            }
            pool_mutex.unlock(io_mod.getIo());
            if (err == error.Cancelled or caller_deadline_expired(args.deadline) or !stale_connection_error(err)) {
                rollbackReservation(reserved);
                return err;
            }
            reusable = null;
        };
        if (reusable != null) {
            pool_mutex.lockUncancelable(io_mod.getIo());
            if (reserved) |slot| retained = !slot.retired;
            pool_mutex.unlock(io_mod.getIo());
            return .{
                .slot = reserved,
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
        .upgrade_status = args.upgrade_status,
    }) catch |err| {
        rollbackReservation(reserved);
        return err;
    };
    if (reserved) |slot| {
        pool_mutex.lockUncancelable(io_mod.getIo());
        retained = !slot.retired;
        slot.connection = connection;
        slot.clearContinuation();
        slot.opened_at_ms = connection.opened_at_ms;
        slot.last_used_at_ms = io_mod.milliTimestamp();
        pool_mutex.unlock(io_mod.getIo());
    }
    return .{
        .slot = reserved,
        .connection = connection,
        .reused = false,
        .retained = retained,
        .handshake_ms = @max(io_mod.milliTimestamp() - started_at_ms, 0),
        .health_failures = prior_health,
    };
}

fn rollbackReservation(reserved: ?*Slot) void {
    const slot = reserved orelse return;
    pool_mutex.lockUncancelable(io_mod.getIo());
    const retired = slot.retired;
    slot.busy = false;
    pool_mutex.unlock(io_mod.getIo());
    if (retired) slot.deinit();
}

pub fn continuation(
    checkout: Checkout,
    full_input: []const u8,
    shape: [std.crypto.hash.sha2.Sha256.digest_length]u8,
) ?Continuation {
    const slot = checkout.slot orelse return null;
    pool_mutex.lockUncancelable(io_mod.getIo());
    defer pool_mutex.unlock(io_mod.getIo());
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
    checkout: Checkout,
    response_id: []const u8,
    baseline: []const u8,
    durable_baseline: []const u8,
    shape: [std.crypto.hash.sha2.Sha256.digest_length]u8,
) void {
    const slot = checkout.slot orelse return;
    pool_mutex.lockUncancelable(io_mod.getIo());
    defer pool_mutex.unlock(io_mod.getIo());
    if (!slot.busy) return;
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
    const slot = checkout.slot orelse {
        if (outcome == .failed)
            websocket_transport.abort(checkout.connection, pool_alloc)
        else
            websocket_transport.close(checkout.connection, pool_alloc);
        return;
    };
    var discarded: ?*websocket_transport.Connection = null;
    pool_mutex.lockUncancelable(io_mod.getIo());
    const retired = slot.retired;
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
    slot.busy = false;
    pool_mutex.unlock(io_mod.getIo());
    if (discarded) |connection| websocket_transport.abort(connection, pool_alloc);
    if (retired) slot.deinit();
}

pub fn shutdown() void {
    pool_mutex.lockUncancelable(io_mod.getIo());
    var owned = slots;
    slots = .empty;
    // Compact the detached array to idle owners while holding the mutex.
    // Busy owners retain their slot and borrowed continuation until release.
    var idle_count: usize = 0;
    for (owned.items) |slot| {
        slot.retired = true;
        if (!slot.busy) {
            owned.items[idle_count] = slot;
            idle_count += 1;
        }
    }
    owned.items.len = idle_count;
    pool_mutex.unlock(io_mod.getIo());
    for (owned.items) |slot| slot.deinit();
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
    first.busy = true;
    defer first.busy = false;
    const second = try appendSlot(args, false);
    second.busy = true;
    defer second.busy = false;
    recordCompletion(test_checkout(second), "response-2", "{\"type\":\"message\"}", "{\"type\":\"message\"}", shape);
    second.busy = false;

    const selection = chooseLane(slots.items, args, 2);
    try std.testing.expectEqual(second, slots.items[selection.existing]);

    second.busy = true;
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
    defer slots.items[1].busy = false;

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
            const displaced = try replaceSlot(victim, args);
            displaced.deinit();
            slots.items[victim].busy = false;
            slots.items[victim].last_used_at_ms = @intCast(identity);
        }
        try std.testing.expect(slots.items.len <= limit);
    }
    try std.testing.expectEqual(limit, slots.items.len);
}

test "Codex WebSocket shutdown rollback cannot release a new reservation" {
    shutdown();
    defer shutdown();
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const args = AcquireArgs{
        .session_id = "shutdown-race",
        .account_id = "test",
        .model = "test",
        .endpoint = "http://127.0.0.1/responses",
        .authorization = "Bearer test",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    };
    const old = try appendSlot(args, true);
    shutdown();
    const fresh = try appendSlot(args, true);
    defer fresh.busy = false;
    rollbackReservation(old);
    try std.testing.expect(fresh.busy);
}

fn test_checkout(slot: *Slot) Checkout {
    return .{
        .slot = slot,
        .connection = slot.connection orelse undefined,
        .reused = false,
        .retained = !slot.retired,
        .handshake_ms = 0,
        .health_failures = slot.health_failures,
    };
}

test "Codex WebSocket shutdown preserves borrowed continuation until owner release" {
    shutdown();
    defer shutdown();
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = gateway_client.DeliveryCertainty.init();
    const args = AcquireArgs{
        .session_id = "borrowed-continuation",
        .account_id = "test",
        .model = "test",
        .endpoint = "http://127.0.0.1/responses",
        .authorization = "Bearer test",
        .deadline = null,
        .cancel_flag = &cancelled,
        .delivery = &delivery,
    };
    const shape = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length;
    const old = try appendSlot(args, true);
    const checkout = test_checkout(old);
    recordCompletion(checkout, "old-response", "first", "first", shape);
    const borrowed = continuation(checkout, "first,second", shape).?;
    shutdown();
    shutdown();
    const fresh = try appendSlot(args, true);
    defer fresh.busy = false;
    const fresh_checkout = test_checkout(fresh);
    recordCompletion(fresh_checkout, "fresh-response", "new", "new", shape);
    try std.testing.expect(old.retired);
    try std.testing.expect(old.lane_id != fresh.lane_id);
    try std.testing.expectEqualStrings("old-response", borrowed.previous_response_id);
    try std.testing.expectEqualStrings("second", borrowed.delta_input);
    release(checkout, .completed);
    try std.testing.expect(fresh.busy);
    try std.testing.expectEqualStrings("fresh-response", continuation(fresh_checkout, "new,next", shape).?.previous_response_id);
}

test "Codex WebSocket expiration includes idle and age boundaries" {
    try std.testing.expect(!connection_expired(0, 900, 999, 1_000, 100));
    try std.testing.expect(connection_expired(0, 900, 1_000, 1_000, 100));
    try std.testing.expect(connection_expired(0, 950, 1_000, 1_000, 100));
    try std.testing.expect(connection_expired(0, 900, 1_000, 0, 100));
    try std.testing.expect(!connection_expired(0, 950, 1_000, 0, 100));
    try std.testing.expect(!connection_expired(1_000, 1_000, 999, 1_000, 100));
    try std.testing.expectEqual(@as(i64, 1), try parse_idle_timeout("1"));
    for ([_][]const u8{ "0", "-1", "", "nan", "9223372036854775808" }) |invalid|
        try std.testing.expectError(error.InvalidOpenAICodexTransport, parse_idle_timeout(invalid));
}
