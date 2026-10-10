//! The session ledger as the session store keeps it: the ledger core
//! (core/ledger.zig) to the snapshot codec (codec/snapshot.zig) and back.
//!
//! Writing borrows: the snapshot points into the ledger and a caller's
//! `Buffers`, so a checkpoint allocates nothing. Today's rules apply:
//!
//! - `billing` reads `incomplete` while a call is in flight, and the API
//!   duration counts as incomplete then (`snapshotCurrent`).
//! - Wall time is the saved time plus this run's.
//!
//! - Each staged fact is also written as a pending "bridge" entry with the
//!   same id and the call's sequence, and `billing` reads `pending` while
//!   one exists. That is today's shape: older binaries count a backlog fact
//!   through its bridge when they publish it, and the 18-key shape, which
//!   has no backlog, keeps it as a lookup. The core keeps waiting
//!   entries plus bridges within the 16 every parser accepts.
//!
//! Reading:
//!
//! - A waiting entry without `observed_at_ms` (the 18-key shape) is observed
//!   at the saved checkpoint's time, as today's recovery reads it. A missing
//!   `credential_source` stays null, as today.
//! - A backlog fact with a bridge is staged with the bridge's sequence; the
//!   bridge is not a waiting entry.
//! - A backlog fact without one is already in the totals (older binaries
//!   count it when no session sink is configured). It can't be staged again
//!   without counting it twice, so it restores as an `incomplete` incident
//!   and is not published from here.

const std = @import("std");
const core = @import("core/ledger.zig");
const snapshot = @import("codec/snapshot.zig");
const record = @import("codec/record.zig");

const ceiling = core.Limits.ceiling;

/// Storage a written snapshot borrows.
pub const Buffers = struct {
    models: [ceiling]snapshot.Model = undefined,
    pending: [2 * ceiling]snapshot.Pending = undefined,
    backlog: [ceiling]record.GenerationFact = undefined,
    incidents: [ceiling]record.Incident = undefined,
};

pub const Times = struct {
    at_ms: i64,
    /// When this run opened the session.
    opened_at_ms: i64,
    /// A live reading, not a checkpoint: calls in flight leave billing and
    /// API time as they are instead of marking them incomplete.
    live: bool = false,
};

/// What `ledger` is persisted as. `bridge_origin` is the session's Gateway
/// origin, written on each staged fact's bridge entry; empty writes none
/// (dev labs). Borrows `ledger`, `bridge_origin`, and `buffers` until any
/// changes.
pub fn snapshotOf(ledger: *const core.Ledger, times: Times, bridge_origin: []const u8, buffers: *Buffers) snapshot.Snapshot {
    const at_ms = times.at_ms;
    const opened_at_ms = times.opened_at_ms;
    const in_flight = !times.live and ledger.active.items.len > 0;
    const activity = ledger.activity;
    const run_ms: u64 = if (at_ms > opened_at_ms) @intCast(at_ms - opened_at_ms) else 0;
    const wall_ms, const wall_overflow = @addWithOverflow(activity.wall_duration_ms, run_ms);

    for (ledger.rows.items, 0..) |*row, index| {
        const totals = row.totals;
        buffers.models[index] = .{
            .model = row.name(),
            .first_sequence = row.first_sequence,
            .total_cost = totals.total_cost,
            .input_tokens = totals.input_tokens,
            .output_tokens = totals.output_tokens,
            .cache_read_tokens = totals.cache_read_tokens,
            .cache_write_tokens = totals.cache_write_tokens,
            .reasoning_tokens = totals.reasoning_tokens,
            .request_count = totals.request_count,
            .billable_web_search_calls = totals.billable_web_search_calls,
        };
    }
    for (ledger.waiting(), 0..) |*entry, index| {
        buffers.pending[index] = .{
            .id = entry.id.slice(),
            .sequence = entry.sequence,
            .provider = entry.provider,
            .origin = entry.originText(),
            .team = entry.teamText(),
            .credential_source = entry.credential_source,
            .credential_identity = entry.credential_identity,
            .account_id = entry.accountText(),
            .observed_at_ms = entry.observed_at_ms,
        };
    }
    var pending_count = ledger.waiting().len;
    for (ledger.staged(), 0..) |*entry, index| {
        const fact = entry.fact();
        if (bridge_origin.len > 0) {
            buffers.pending[pending_count] = .{
                .id = entry.id.slice(),
                .sequence = entry.sequence,
                .provider = .gateway,
                .origin = bridge_origin,
                .team = null,
                .observed_at_ms = @max(fact.created_at_ms, 0),
            };
            pending_count += 1;
        }
        buffers.backlog[index] = .{
            .id = entry.id.slice(),
            .created_at_ms = fact.created_at_ms,
            .model = fact.model,
            .input_tokens = fact.input_tokens,
            .output_tokens = fact.output_tokens,
            .cache_read_tokens = fact.cache_read_tokens,
            .cache_write_tokens = fact.cache_write_tokens,
            .reasoning_tokens = fact.reasoning_tokens,
            .billable_web_search_calls = fact.billable_web_search_calls,
            .total_cost = fact.total_cost,
        };
    }
    for (ledger.incidentList(), 0..) |incident, index| {
        buffers.incidents[index] = .{
            .occurred_at_ms = incident.occurred_at_ms,
            .completeness = switch (incident.completeness) {
                .pending => .pending,
                .incomplete => .incomplete,
            },
        };
    }
    const totals = ledger.totals;
    return .{
        .billing = if (in_flight) .incomplete else switch (ledger.availability()) {
            .complete => if (pending_count > 0) .pending else .complete,
            .pending => .pending,
            .incomplete => .incomplete,
            .legacy => .legacy,
        },
        .api_duration_complete = activity.api_duration_complete and !in_flight,
        .wall_duration_complete = activity.wall_duration_complete and wall_overflow == 0,
        .code_complete = activity.code_complete,
        .next_sequence = ledger.next_sequence,
        .settled_through_sequence = ledger.settled_through,
        .api_duration_ms = activity.api_duration_ms,
        .wall_duration_ms = if (wall_overflow != 0) std.math.maxInt(u64) else wall_ms,
        .total_cost = totals.total_cost,
        .input_tokens = totals.input_tokens,
        .output_tokens = totals.output_tokens,
        .cache_read_tokens = totals.cache_read_tokens,
        .cache_write_tokens = totals.cache_write_tokens,
        .reasoning_tokens = totals.reasoning_tokens,
        .request_count = totals.request_count,
        .billable_web_search_calls = totals.billable_web_search_calls,
        .lines_added = activity.lines_added,
        .lines_removed = activity.lines_removed,
        .models = buffers.models[0..ledger.rows.items.len],
        .pending = buffers.pending[0..pending_count],
        .publication_backlog = buffers.backlog[0..ledger.staged().len],
        .incidents = buffers.incidents[0..ledger.incidentList().len],
    };
}

/// Storage a restored ledger input borrows.
pub const RestoreBuffers = struct {
    rows: [ceiling]core.Restored.Row = undefined,
    pending: [ceiling]core.Restored.Waiting = undefined,
    backlog: [ceiling]core.Restored.StagedFact = undefined,
    incidents: [ceiling]core.Incident = undefined,
};

pub const ReadError = error{
    /// The snapshot holds more than the ledger can (`Limits.ceiling`), or an
    /// id the ledger can't take.
    InvalidRestore,
};

/// The ledger input for a parsed snapshot saved at `saved_at_ms`. Borrows
/// `saved` and `buffers`.
pub fn restoredOf(saved: *const snapshot.Snapshot, saved_at_ms: i64, buffers: *RestoreBuffers) ReadError!core.Restored {
    if (saved.models.len > ceiling or saved.pending.len > ceiling or
        saved.publication_backlog.len > ceiling or saved.incidents.len > ceiling)
    {
        return error.InvalidRestore;
    }
    for (saved.models, 0..) |model, index| {
        buffers.rows[index] = .{ .model = model.model, .first_sequence = model.first_sequence, .totals = .{
            .total_cost = model.total_cost,
            .input_tokens = model.input_tokens,
            .output_tokens = model.output_tokens,
            .cache_read_tokens = model.cache_read_tokens,
            .cache_write_tokens = model.cache_write_tokens,
            .reasoning_tokens = model.reasoning_tokens,
            .request_count = model.request_count,
            .billable_web_search_calls = model.billable_web_search_calls,
        } };
    }

    // Bridge entries: a staged fact's pending entry with the same id.
    var bridged: [ceiling]bool = @splat(false);
    var staged: usize = 0;
    var counted_at_ms: ?i64 = null;
    for (saved.publication_backlog) |fact| {
        const bridge = for (saved.pending, 0..) |entry, entry_index| {
            if (!bridged[entry_index] and std.mem.eql(u8, entry.id, fact.id)) break entry_index;
        } else null;
        const entry_index = bridge orelse {
            counted_at_ms = @max(saved_at_ms, 0);
            continue;
        };
        bridged[entry_index] = true;
        buffers.backlog[staged] = .{ .sequence = saved.pending[entry_index].sequence, .fact = .{
            .id = core.GenerationId.parse(fact.id) catch return error.InvalidRestore,
            .created_at_ms = fact.created_at_ms,
            .model = fact.model,
            .total_cost = fact.total_cost,
            .input_tokens = fact.input_tokens,
            .output_tokens = fact.output_tokens,
            .cache_read_tokens = fact.cache_read_tokens,
            .cache_write_tokens = fact.cache_write_tokens,
            .reasoning_tokens = fact.reasoning_tokens,
            .billable_web_search_calls = fact.billable_web_search_calls,
        } };
        staged += 1;
    }

    var waiting: usize = 0;
    for (saved.pending, 0..) |entry, index| {
        if (bridged[index]) continue;
        buffers.pending[waiting] = .{ .sequence = entry.sequence, .provider = entry.provider, .request = .{
            .id = core.GenerationId.parse(entry.id) catch return error.InvalidRestore,
            .origin = entry.origin,
            .team = entry.team,
            .credential_source = entry.credential_source,
            .credential_identity = entry.credential_identity,
            .account_id = entry.account_id,
            .observed_at_ms = entry.observed_at_ms orelse @max(saved_at_ms, 0),
        } };
        waiting += 1;
    }

    for (saved.incidents, 0..) |incident, incident_index| {
        buffers.incidents[incident_index] = .{
            .occurred_at_ms = incident.occurred_at_ms,
            .completeness = switch (incident.completeness) {
                .pending => .pending,
                .incomplete => .incomplete,
            },
        };
    }
    var incident_count = saved.incidents.len;
    if (counted_at_ms) |at_ms| {
        if (incident_count < snapshot.max_incidents) {
            buffers.incidents[incident_count] = .{ .occurred_at_ms = at_ms, .completeness = .incomplete };
            incident_count += 1;
        } else {
            // Today's collapse rule: one `incomplete` incident at the newest time.
            var newest = at_ms;
            for (buffers.incidents[0..incident_count]) |incident| newest = @max(newest, incident.occurred_at_ms);
            buffers.incidents[0] = .{ .occurred_at_ms = newest, .completeness = .incomplete };
            incident_count = 1;
        }
    }
    const availability: core.Availability = if (counted_at_ms != null) .incomplete else switch (saved.billing) {
        .complete => .complete,
        // Bridges were all the pending entries there were.
        .pending => if (waiting == 0) .complete else .pending,
        .incomplete => .incomplete,
        .legacy => .legacy,
    };
    return .{
        .availability = availability,
        .next_sequence = saved.next_sequence,
        .settled_through = saved.settled_through_sequence,
        .totals = .{
            .total_cost = saved.total_cost,
            .input_tokens = saved.input_tokens,
            .output_tokens = saved.output_tokens,
            .cache_read_tokens = saved.cache_read_tokens,
            .cache_write_tokens = saved.cache_write_tokens,
            .reasoning_tokens = saved.reasoning_tokens,
            .request_count = saved.request_count,
            .billable_web_search_calls = saved.billable_web_search_calls,
        },
        .rows = buffers.rows[0..saved.models.len],
        .pending = buffers.pending[0..waiting],
        .backlog = buffers.backlog[0..staged],
        .incidents = buffers.incidents[0..incident_count],
        .activity = .{
            .api_duration_ms = saved.api_duration_ms,
            .api_duration_complete = saved.api_duration_complete,
            .wall_duration_ms = saved.wall_duration_ms,
            .wall_duration_complete = saved.wall_duration_complete,
            .code_complete = saved.code_complete,
            .lines_added = saved.lines_added,
            .lines_removed = saved.lines_removed,
        },
    };
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const origin = "https://ai-gateway.vercel.sh";

fn testId(n: u64) core.GenerationId {
    const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    var bytes: [core.GenerationId.length]u8 = undefined;
    @memcpy(bytes[0..4], "gen_");
    var value = n;
    var index: usize = bytes.len;
    while (index > 4) : (index -= 1) {
        bytes[index - 1] = alphabet[@intCast(value % 32)];
        value /= 32;
    }
    return core.GenerationId.parse(&bytes) catch unreachable;
}

fn testFact(n: u64, model: []const u8, cost: f64) core.Fact {
    return .{ .id = testId(n), .created_at_ms = @intCast(1_000 + n), .model = model, .total_cost = cost, .input_tokens = 10, .output_tokens = 5, .reasoning_tokens = 1 };
}

/// A ledger with one settled row, one waiting entry, one staged fact, and an
/// incident.
fn busyLedger() !core.Ledger {
    var ledger: core.Ledger = try .init(testing.allocator, .{}, .fresh);
    errdefer ledger.deinit(testing.allocator);
    var out: core.Output = .{};
    for (0..5) |_| try ledger.step(.{ .begin = .gateway }, &out, null);
    try ledger.step(.{ .finish_exact = .{ .sequence = 1, .fact = testFact(1, "model/a", 0.5) } }, &out, null);
    try ledger.step(.{ .publish = .{ .sequence = 1, .result = .appended } }, &out, null);
    try ledger.step(.{ .finish_lookup = .{ .sequence = 2, .request = .{
        .id = testId(2),
        .origin = "https://ai-gateway.vercel.sh",
        .team = "team_x",
        .credential_source = .fx_login,
        .account_id = "acct",
        .observed_at_ms = 2_000,
    } } }, &out, null);
    try ledger.step(.{ .finish_exact = .{ .sequence = 3, .fact = testFact(3, "model/b", 0.25) } }, &out, null);
    try ledger.step(.{ .finish_unpriced = .{ .sequence = 4, .at_ms = 77 } }, &out, null);
    try ledger.step(.{ .finish_unbilled = 5 }, &out, null);
    ledger.recordActivity(.{ .api_ms = 900, .lines_added = 7, .lines_removed = 2 });
    return ledger;
}

test "a checkpoint is a valid snapshot that restores to the same ledger" {
    var ledger = try busyLedger();
    defer ledger.deinit(testing.allocator);
    var buffers: Buffers = .{};
    const snap = snapshotOf(&ledger, .{ .at_ms = 10_000, .opened_at_ms = 4_000 }, origin, &buffers);
    try snapshot.validate(snap);
    try testing.expectEqual(snapshot.Billing.incomplete, snap.billing);
    try testing.expectEqual(@as(u64, 6_000), snap.wall_duration_ms);
    try testing.expectEqual(@as(u64, 5), snap.settled_through_sequence);
    // The waiting entry, then the staged fact's bridge.
    try testing.expectEqual(@as(usize, 2), snap.pending.len);
    try testing.expectEqual(@as(u64, 3), snap.pending[1].sequence);
    try testing.expectEqualStrings(snap.publication_backlog[0].id, snap.pending[1].id);
    try testing.expectEqual(@as(usize, 1), snap.publication_backlog.len);
    try testing.expectEqual(@as(?snapshot.CredentialSource, .fx_login), snap.pending[0].credential_source);

    // Through the rich bytes, as a sidecar holds them.
    const bytes = try snapshot.encodeSidecar(testing.allocator, "sess-1", snap);
    defer testing.allocator.free(bytes);
    var parsed = try snapshot.parseSidecar(testing.allocator, bytes);
    defer parsed.deinit(testing.allocator);
    var restore_buffers: RestoreBuffers = .{};
    const restored = try restoredOf(&parsed.snapshot, 10_000, &restore_buffers);
    try testing.expectEqual(@as(core.Sequence, 3), restored.backlog[0].sequence);
    try testing.expectEqual(@as(usize, 1), restored.pending.len);

    var again: core.Ledger = try .init(testing.allocator, .{}, .fresh);
    defer again.deinit(testing.allocator);
    var out: core.Output = .{};
    try again.restore(restored, &out, null);
    var again_buffers: Buffers = .{};
    const resaved = snapshotOf(&again, .{ .at_ms = 10_000, .opened_at_ms = 10_000 }, origin, &again_buffers);
    // Same bytes, apart from the wall time already folded in, and billing:
    // nothing is in flight after a restore.
    var expected = snap;
    expected.wall_duration_ms = resaved.wall_duration_ms;
    expected.billing = .incomplete;
    expected.api_duration_complete = resaved.api_duration_complete;
    var a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try snapshot.writeRich(&a.writer, expected);
    try snapshot.writeRich(&b.writer, resaved);
    try testing.expectEqualStrings(a.written(), b.written());
}

test "bridges make billing pending, as today, and none are written without an origin" {
    var ledger: core.Ledger = try .init(testing.allocator, .{}, .fresh);
    defer ledger.deinit(testing.allocator);
    var out: core.Output = .{};
    try ledger.step(.{ .begin = .gateway }, &out, null);
    try ledger.step(.{ .finish_exact = .{ .sequence = 1, .fact = testFact(1, "model/a", 0.5) } }, &out, null);
    var buffers: Buffers = .{};
    var snap = snapshotOf(&ledger, .{ .at_ms = 5, .opened_at_ms = 5 }, origin, &buffers);
    try testing.expectEqual(snapshot.Billing.pending, snap.billing);
    try snapshot.validate(snap);
    // The 18-key shape keeps the bridge, so a rollback can still count it.
    var legacy: std.Io.Writer.Allocating = .init(testing.allocator);
    defer legacy.deinit();
    try snapshot.writeLegacy18(&legacy.writer, snap);
    try testing.expect(std.mem.indexOf(u8, legacy.written(), testId(1).slice()) != null);
    snap = snapshotOf(&ledger, .{ .at_ms = 5, .opened_at_ms = 5 }, "", &buffers);
    try testing.expectEqual(snapshot.Billing.complete, snap.billing);
    try testing.expectEqual(@as(usize, 0), snap.pending.len);
}

test "a quiet ledger reads complete, and API time is incomplete only while a call is in flight" {
    var ledger: core.Ledger = try .init(testing.allocator, .{}, .fresh);
    defer ledger.deinit(testing.allocator);
    var buffers: Buffers = .{};
    var snap = snapshotOf(&ledger, .{ .at_ms = 0, .opened_at_ms = 0 }, origin, &buffers);
    try testing.expectEqual(snapshot.Billing.complete, snap.billing);
    try testing.expect(snap.api_duration_complete);
    var out: core.Output = .{};
    try ledger.step(.{ .begin = .gateway }, &out, null);
    snap = snapshotOf(&ledger, .{ .at_ms = 0, .opened_at_ms = 0 }, origin, &buffers);
    try testing.expect(!snap.api_duration_complete);
    try testing.expectEqual(snapshot.Billing.incomplete, snap.billing);
    try snapshot.validate(snap);
}

fn gatewayFact(id: *const core.GenerationId, cost: f64) record.GenerationFact {
    return .{ .id = id.slice(), .created_at_ms = 1, .model = "m/a", .input_tokens = 1, .output_tokens = 1, .cache_read_tokens = 0, .cache_write_tokens = 0, .reasoning_tokens = null, .total_cost = cost };
}

test "an older binary's bridged fact is staged; an unbridged one was counted and becomes an incident" {
    const id6 = testId(6);
    const id8 = testId(8);
    const id9 = testId(9);
    const pending = [_]snapshot.Pending{
        .{ .id = id6.slice(), .sequence = 6, .origin = origin, .team = null },
        .{ .id = id8.slice(), .sequence = 11, .origin = origin, .team = null },
    };
    const backlog = [_]record.GenerationFact{ gatewayFact(&id6, 0.1), gatewayFact(&id9, 0.2) };
    var saved = snapshot.legacy_unavailable;
    saved.billing = .pending;
    saved.next_sequence = 12;
    saved.settled_through_sequence = 11;
    saved.pending = &pending;
    saved.publication_backlog = &backlog;
    var buffers: RestoreBuffers = .{};
    const restored = try restoredOf(&saved, 500, &buffers);
    try testing.expectEqual(@as(usize, 1), restored.pending.len);
    try testing.expectEqual(@as(core.Sequence, 11), restored.pending[0].sequence);
    try testing.expectEqual(@as(i64, 500), restored.pending[0].request.observed_at_ms);
    try testing.expectEqual(@as(?core.CredentialSource, null), restored.pending[0].request.credential_source);
    try testing.expectEqual(@as(usize, 1), restored.backlog.len);
    try testing.expectEqual(@as(core.Sequence, 6), restored.backlog[0].sequence);
    try testing.expectEqual(@as(usize, 1), restored.incidents.len);
    try testing.expectEqual(core.Availability.incomplete, restored.availability);
    var ledger: core.Ledger = try .init(testing.allocator, .{}, .fresh);
    defer ledger.deinit(testing.allocator);
    var out: core.Output = .{};
    try ledger.restore(restored, &out, null);
}

test "bridges alone restore to complete, and a full incident list collapses" {
    const id2 = testId(2);
    const pending = [_]snapshot.Pending{.{ .id = id2.slice(), .sequence = 2, .origin = origin, .team = null }};
    const backlog = [_]record.GenerationFact{gatewayFact(&id2, 0.1)};
    var saved = snapshot.legacy_unavailable;
    saved.billing = .pending;
    saved.next_sequence = 3;
    saved.settled_through_sequence = 2;
    saved.pending = &pending;
    saved.publication_backlog = &backlog;
    var buffers: RestoreBuffers = .{};
    var restored = try restoredOf(&saved, 0, &buffers);
    try testing.expectEqual(core.Availability.complete, restored.availability);
    try testing.expectEqual(@as(usize, 0), restored.pending.len);

    var incidents: [snapshot.max_incidents]record.Incident = undefined;
    for (&incidents, 0..) |*incident, index| incident.* = .{ .occurred_at_ms = @intCast(index), .completeness = .pending };
    saved.billing = .incomplete;
    saved.pending = &.{};
    saved.incidents = &incidents;
    restored = try restoredOf(&saved, 3, &buffers);
    try testing.expectEqual(@as(usize, 1), restored.incidents.len);
    try testing.expectEqual(core.Incident{ .occurred_at_ms = 15, .completeness = .incomplete }, restored.incidents[0]);
}
