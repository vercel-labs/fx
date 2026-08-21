const std = @import("std");
const builtin = @import("builtin");
const secret = @import("../auth/secret.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const generation_fact_codec = @import("generation_fact_codec.zig");
const generation_usage = @import("generation_usage_provider.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
pub const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const max_models: usize = 32;
const max_pending_generations: usize = 16;
const max_publication_backlog: usize = 16;
const max_usage_incidents: usize = 16;
const max_model_bytes: usize = 1024;
const max_origin_bytes: usize = 2048;
const max_team_bytes: usize = 255;
const max_identifier_bytes: usize = 8 * 1024;
const max_active_invocations: usize = 64;
const shutdown_reconciliation_budget_ms: usize = 250;
pub const max_snapshot_bytes: usize = 256 * 1024;

/// Completeness of the saved billing window rendered by `/cost`.
pub const Availability = enum {
    /// Every billable invocation has an authoritative generation record.
    complete,
    /// Known generation identities still require reconciliation.
    pending,
    /// Billing may have occurred without a recoverable authoritative record.
    incomplete,
    /// The persisted session predates usage accounting.
    legacy,
};

/// Billing consequence of one logical Gateway invocation across retries.
pub const DeliveryOutcome = enum {
    /// Delivery was proven not to create a billable generation.
    unbilled,
    /// A validated generation identity can be reconciled.
    observed_generation,
    /// Delivery succeeded but no usable generation identity was returned.
    possibly_billed_without_identity,
    /// Transport evidence cannot prove whether a billable generation was created.
    ambiguous_delivery,
};

/// Host-owned durable sink. Its context and allocator remain borrowed until
/// the sink is unset; `persist` must not retain the snapshot, checkpoint, or
/// reconfigure the sink.
pub const UsageCheckpointSink = struct {
    context: *anyopaque,
    allocator: Allocator,
    persist: *const fn (context: *anyopaque, snapshot: Snapshot) anyerror!void,
};

/// Host-owned local-profile publication sink. The callback receives a borrowed
/// event and must return only after it is durably accepted or deduplicated.
pub const ProfilePublicationSink = struct {
    context: *anyopaque,
    allocator: Allocator,
    publish: *const fn (
        context: *anyopaque,
        event: usage_report.ProfileEvent,
    ) anyerror!void,
};

const ProfilePublicationBatch = struct {
    pending: []usage_report.PendingMarker,
    incidents: []usage_report.Incident,
    facts: []usage_report.GenerationFact,
    checkpoint_changed: bool,

    fn deinit(self: *ProfilePublicationBatch, alloc: Allocator) void {
        for (self.pending) |*marker| marker.deinit(alloc);
        alloc.free(self.pending);
        alloc.free(self.incidents);
        for (self.facts) |*fact| fact.deinit(alloc);
        alloc.free(self.facts);
        self.* = undefined;
    }
};

/// One Gateway invocation. `begin` durably reserves it before network I/O;
/// every successful reservation must terminate through `fail` or `complete`.
pub const GatewayObservation = struct {
    usage: ?*Usage,
    sequence: u64 = 0,
    started_at_ms: i64,

    pub fn begin(usage: ?*Usage) !GatewayObservation {
        return .{
            .usage = usage,
            .sequence = if (usage) |ledger| try ledger.reserveInvocationDurably() else 0,
            .started_at_ms = io_mod.milliTimestamp(),
        };
    }

    pub fn fail(self: GatewayObservation, outcome: DeliveryOutcome) !void {
        const ledger = self.usage orelse return;
        try ledger.finishInvocationDurably(self.sequence, self.elapsedMs(), outcome);
    }

    pub fn complete(
        self: GatewayObservation,
        alloc: Allocator,
        status: std.http.Status,
        completion: types.GatewayCompletion,
        origin: []const u8,
        team: ?[]const u8,
    ) !void {
        const ledger = self.usage orelse return;
        const generation_id = completion.generation_id;
        const delivery: DeliveryOutcome = if (completion.delivery_ambiguous)
            .ambiguous_delivery
        else if (status == .ok)
            if (!completion.generation_metadata_invalid and generation_id != null)
                .observed_generation
            else
                .possibly_billed_without_identity
        else
            .unbilled;
        const id = generation_id orelse {
            try ledger.finishInvocationDurably(self.sequence, self.elapsedMs(), delivery);
            if (delivery == .possibly_billed_without_identity) {
                debug_trace.logf(
                    "session",
                    "usage billing incomplete sequence={d} reason=generation_identity_missing",
                    .{self.sequence},
                );
            }
            return;
        };
        if (completion.generation_metadata_invalid or status != .ok) {
            try ledger.finishInvocationDurably(self.sequence, self.elapsedMs(), delivery);
            debug_trace.logf(
                "session",
                "usage generation ignored sequence={d} status={d} metadata_invalid={s}",
                .{
                    self.sequence,
                    @intFromEnum(status),
                    if (completion.generation_metadata_invalid) "true" else "false",
                },
            );
            return;
        }
        try ledger.finishObservedInvocationDurably(
            alloc,
            self.sequence,
            self.elapsedMs(),
            delivery,
            id,
            origin,
            team,
        );
        debug_trace.logf(
            "session",
            "usage generation queued sequence={d} id={s}",
            .{ self.sequence, id },
        );
        if (completion.billing) |billing| {
            ledger.applyGatewayBilling(alloc, id, billing) catch |err| {
                debug_trace.logf(
                    "session",
                    "usage stream billing apply failed id={s} reason={s}",
                    .{ id, @errorName(err) },
                );
                ledger.flushProfilePublications();
                return;
            };
            debug_trace.logf(
                "session",
                "usage stream billing settled sequence={d} id={s}",
                .{ self.sequence, id },
            );
        } else {
            ledger.flushProfilePublications();
        }
    }

    fn elapsedMs(self: GatewayObservation) u64 {
        const ended_at_ms = io_mod.milliTimestamp();
        if (ended_at_ms <= self.started_at_ms) return 0;
        return std.math.cast(u64, ended_at_ms - self.started_at_ms) orelse
            std.math.maxInt(u64);
    }
};

const GenerationRecord = generation_usage.Record;

pub const ModelAggregate = struct {
    model: []u8,
    first_sequence: u64,
    total_cost: f64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: ?u64 = null,
    request_count: ?u64 = null,
    billable_web_search_calls: u64 = 0,

    fn deinit(self: *ModelAggregate, alloc: Allocator) void {
        alloc.free(self.model);
        self.* = undefined;
    }

    fn dupe(self: ModelAggregate, alloc: Allocator) Allocator.Error!ModelAggregate {
        return .{
            .model = try alloc.dupe(u8, self.model),
            .first_sequence = self.first_sequence,
            .total_cost = self.total_cost,
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .cache_read_tokens = self.cache_read_tokens,
            .cache_write_tokens = self.cache_write_tokens,
            .reasoning_tokens = self.reasoning_tokens,
            .request_count = self.request_count,
            .billable_web_search_calls = self.billable_web_search_calls,
        };
    }
};

pub const PendingGeneration = struct {
    id: []u8,
    sequence: u64,
    origin: []u8,
    team: ?[]u8,
    observed_at_ms: ?i64 = null,

    fn deinit(self: *PendingGeneration, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.origin);
        if (self.team) |team| alloc.free(team);
        self.* = undefined;
    }

    fn dupe(self: PendingGeneration, alloc: Allocator) Allocator.Error!PendingGeneration {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const origin = try alloc.dupe(u8, self.origin);
        errdefer alloc.free(origin);
        const team = if (self.team) |value| try alloc.dupe(u8, value) else null;
        return .{
            .id = id,
            .sequence = self.sequence,
            .origin = origin,
            .team = team,
            .observed_at_ms = self.observed_at_ms,
        };
    }
};

pub const Snapshot = struct {
    billing: Availability,
    api_duration_complete: bool,
    wall_duration_complete: bool,
    code_complete: bool,
    next_sequence: u64,
    settled_through_sequence: u64,
    api_duration_ms: u64,
    wall_duration_ms: u64,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64 = null,
    request_count: ?u64 = null,
    billable_web_search_calls: u64,
    lines_added: u64,
    lines_removed: u64,
    models: []ModelAggregate,
    pending: []PendingGeneration,
    publication_backlog: []usage_report.GenerationFact = &.{},
    incidents: []usage_report.Incident = &.{},

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.models) |*model| model.deinit(alloc);
        alloc.free(self.models);
        for (self.pending) |*generation| generation.deinit(alloc);
        alloc.free(self.pending);
        for (self.publication_backlog) |*fact| fact.deinit(alloc);
        if (self.publication_backlog.len > 0) alloc.free(self.publication_backlog);
        if (self.incidents.len > 0) alloc.free(self.incidents);
        self.* = undefined;
    }
};

/// True when a durable session can still contribute profile usage that is not
/// proven present in the profile ledger.
pub fn needsProfileRecovery(snapshot: Snapshot) bool {
    return snapshot.settled_through_sequence != snapshot.next_sequence - 1 or
        snapshot.pending.len > 0 or
        snapshot.publication_backlog.len > 0 or
        snapshot.incidents.len > 0;
}

pub const Usage = struct {
    mutex: std.Io.Mutex = .init,
    checkpoint_mutex: std.Io.Mutex = .init,
    checkpoint_sink: ?UsageCheckpointSink = null,
    publication_mutex: std.Io.Mutex = .init,
    publication_sink: ?ProfilePublicationSink = null,
    billing: Availability,
    api_duration_complete: bool,
    wall_duration_complete: bool,
    code_complete: bool,
    next_sequence: u64 = 1,
    settled_through_sequence: u64 = 0,
    api_duration_ms: u64 = 0,
    wall_duration_ms: u64 = 0,
    active_started_at_ms: i64 = 0,
    active_sequences: [max_active_invocations]u64 = undefined,
    active_sequence_count: usize = 0,
    total_cost: f64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: ?u64,
    request_count: ?u64,
    billable_web_search_calls: u64 = 0,
    lines_added: u64 = 0,
    lines_removed: u64 = 0,
    models: std.ArrayList(ModelAggregate) = .empty,
    pending: std.ArrayList(PendingGeneration) = .empty,
    publication_backlog: std.ArrayList(usage_report.GenerationFact) = .empty,
    incidents: [max_usage_incidents]usage_report.Incident = undefined,
    incident_count: usize = 0,
    dirty: bool = false,
    reconciliation_mutex: std.Io.Mutex = .init,
    reconciliation_thread: ?std.Thread = null,
    reconciliation_done: std.atomic.Value(bool) = .init(true),
    reconciliation_cancel: std.atomic.Value(bool) = .init(false),
    reconciliation_work_epoch: std.atomic.Value(u64) = .init(0),
    reconciliation_key_digest: ?[Sha256.digest_length]u8 = null,
    reconciliation_credential_blocked: bool = false,
    generation_usage_provider: generation_usage.Provider = generation_usage.unavailable_provider,

    pub fn initFresh() Usage {
        return .{
            .billing = .complete,
            .api_duration_complete = true,
            .wall_duration_complete = true,
            .code_complete = true,
            .reasoning_tokens = 0,
            .request_count = 0,
        };
    }

    pub fn initFreshWithProvider(provider: generation_usage.Provider) Usage {
        var usage = initFresh();
        usage.generation_usage_provider = provider;
        return usage;
    }

    pub fn initLegacy() Usage {
        return .{
            .billing = .legacy,
            .api_duration_complete = false,
            .wall_duration_complete = false,
            .code_complete = false,
            .reasoning_tokens = null,
            .request_count = null,
        };
    }

    pub fn deinit(self: *Usage, alloc: Allocator) void {
        self.stopReconciliation();
        self.clearOwned(alloc);
        self.* = undefined;
    }

    pub fn resetFresh(self: *Usage, alloc: Allocator) void {
        self.stopReconciliation();
        self.reset(alloc, true);
    }

    pub fn resetLegacy(self: *Usage, alloc: Allocator) void {
        self.stopReconciliation();
        self.reset(alloc, false);
    }

    pub fn restoreLegacyWallDuration(
        self: *Usage,
        session_started_at_ms: i64,
    ) void {
        const now_ms = io_mod.milliTimestamp();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (session_started_at_ms <= 0 or session_started_at_ms > now_ms) return;
        self.wall_duration_complete = true;
        self.active_started_at_ms = session_started_at_ms;
    }

    pub fn reserveInvocation(self: *Usage) !u64 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.active_started_at_ms == 0) {
            self.active_started_at_ms = io_mod.milliTimestamp();
        }
        const sequence = self.next_sequence;
        if (self.active_sequence_count == max_active_invocations) {
            debug_trace.logf(
                "session",
                "usage invocation reservation failed reason=active_capacity limit={d}",
                .{max_active_invocations},
            );
            return error.UsageCapacityExceeded;
        }
        const next_sequence = std.math.add(u64, sequence, 1) catch {
            debug_trace.logf(
                "session",
                "usage invocation reservation failed reason=sequence_overflow sequence={d}",
                .{sequence},
            );
            return error.UsageSequenceOverflow;
        };
        self.next_sequence = next_sequence;
        self.active_sequences[self.active_sequence_count] = sequence;
        self.active_sequence_count += 1;
        self.dirty = true;
        return sequence;
    }

    pub fn configureCheckpointSink(self: *Usage, sink: ?UsageCheckpointSink) void {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        defer self.checkpoint_mutex.unlock(io_mod.getIo());
        self.checkpoint_sink = sink;
    }

    pub fn configurePublicationSink(
        self: *Usage,
        sink: ?ProfilePublicationSink,
    ) void {
        self.publication_mutex.lockUncancelable(io_mod.getIo());
        self.publication_sink = sink;
        self.publication_mutex.unlock(io_mod.getIo());
        if (sink != null) self.flushProfilePublications();
    }

    pub fn persistCheckpoint(self: *Usage) bool {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        defer self.checkpoint_mutex.unlock(io_mod.getIo());
        return self.persistCheckpointBestEffortLocked();
    }

    fn reserveInvocationDurably(self: *Usage) !u64 {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        defer self.checkpoint_mutex.unlock(io_mod.getIo());
        const sequence = try self.reserveInvocation();
        self.persistCheckpointRequiredLocked() catch |err| {
            self.finishInvocation(sequence, 0, .unbilled);
            return err;
        };
        return sequence;
    }

    fn finishInvocationDurably(
        self: *Usage,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
    ) !void {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        self.finishInvocation(sequence, duration_ms, outcome);
        _ = self.persistCheckpointBestEffortLocked();
        self.checkpoint_mutex.unlock(io_mod.getIo());
        self.flushProfilePublications();
    }

    fn finishObservedInvocationDurably(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        id: []const u8,
        origin: []const u8,
        team: ?[]const u8,
    ) !void {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        self.finishObservedInvocation(
            alloc,
            sequence,
            duration_ms,
            outcome,
            id,
            origin,
            team,
        ) catch |err| {
            self.markBillingIncomplete();
            _ = self.persistCheckpointBestEffortLocked();
            debug_trace.logf(
                "session",
                "usage generation checkpointed incomplete reason={s}",
                .{@errorName(err)},
            );
            self.checkpoint_mutex.unlock(io_mod.getIo());
            self.flushProfilePublications();
            return;
        };
        _ = self.persistCheckpointBestEffortLocked();
        self.checkpoint_mutex.unlock(io_mod.getIo());
    }

    fn persistCheckpointRequiredLocked(self: *Usage) !void {
        const sink = self.checkpoint_sink orelse return;
        var persisted = try self.snapshotCurrent(sink.allocator);
        defer persisted.deinit(sink.allocator);
        try sink.persist(sink.context, persisted);
        self.markClean(persisted);
    }

    fn persistCheckpointBestEffortLocked(self: *Usage) bool {
        const sink = self.checkpoint_sink orelse return true;
        var persisted = self.snapshotCurrent(sink.allocator) catch |err| {
            self.markBillingIncomplete();
            debug_trace.logf(
                "session",
                "usage checkpoint unavailable; billing marked incomplete reason={s}",
                .{@errorName(err)},
            );
            return false;
        };
        defer persisted.deinit(sink.allocator);
        sink.persist(sink.context, persisted) catch |err| {
            self.markBillingIncomplete();
            debug_trace.logf(
                "session",
                "usage checkpoint unavailable; billing marked incomplete reason={s}",
                .{@errorName(err)},
            );
            return false;
        };
        self.markClean(persisted);
        return true;
    }

    pub fn finishInvocation(
        self: *Usage,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        _ = self.finishInvocationUnlocked(sequence, duration_ms, outcome);
    }

    pub fn finishObservedInvocation(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        id: []const u8,
        origin: []const u8,
        team: ?[]const u8,
    ) !void {
        try validateGenerationId(id);
        try validateOrigin(origin);
        if (team) |value| try validateTeam(value);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.finishInvocationUnlocked(sequence, duration_ms, outcome)) return;
        self.observeGenerationUnlocked(alloc, sequence, id, origin, team) catch |err| {
            self.billing = .incomplete;
            self.dirty = true;
            return err;
        };
    }

    fn finishInvocationUnlocked(
        self: *Usage,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
    ) bool {
        if (sequence == 0 or sequence >= self.next_sequence) {
            self.billing = .incomplete;
            self.api_duration_complete = false;
            self.dirty = true;
            return false;
        }
        const active_index = for (self.active_sequences[0..self.active_sequence_count], 0..) |active, index| {
            if (active == sequence) break index;
        } else return false;
        self.active_sequence_count -= 1;
        self.active_sequences[active_index] = self.active_sequences[self.active_sequence_count];
        self.api_duration_ms = std.math.add(u64, self.api_duration_ms, duration_ms) catch {
            self.billing = .incomplete;
            self.api_duration_complete = false;
            self.dirty = true;
            return false;
        };
        switch (outcome) {
            .unbilled, .observed_generation => {},
            .possibly_billed_without_identity, .ambiguous_delivery => {
                self.billing = .incomplete;
                self.recordIncidentUnlocked(.incomplete, io_mod.milliTimestamp());
            },
        }
        if (self.active_sequence_count == 0) {
            self.settled_through_sequence = self.next_sequence - 1;
        }
        self.dirty = true;
        return true;
    }

    fn observeGenerationUnlocked(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        id: []const u8,
        origin: []const u8,
        team: ?[]const u8,
    ) !void {
        for (self.pending.items) |pending| {
            if (pending.sequence == sequence and !std.mem.eql(u8, pending.id, id)) {
                self.billing = .incomplete;
                self.dirty = true;
                return error.ConflictingGenerationIdentity;
            }
            if (std.mem.eql(u8, pending.id, id)) {
                if (pending.sequence != sequence or
                    !std.mem.eql(u8, pending.origin, origin) or
                    !optionalStringsEqual(pending.team, team))
                {
                    self.billing = .incomplete;
                    self.dirty = true;
                    return error.ConflictingGenerationIdentity;
                }
                return;
            }
        }
        if (self.pending.items.len >= max_pending_generations) {
            self.billing = .incomplete;
            self.dirty = true;
            return error.UsageCapacityExceeded;
        }
        var added_identifier_bytes = std.math.add(usize, id.len, origin.len) catch
            return self.failOverflow();
        if (team) |value| {
            added_identifier_bytes = std.math.add(
                usize,
                added_identifier_bytes,
                value.len,
            ) catch return self.failOverflow();
        }
        const next_identifier_bytes = std.math.add(
            usize,
            self.identifierBytesUnlocked(),
            added_identifier_bytes,
        ) catch return self.failOverflow();
        if (next_identifier_bytes > max_identifier_bytes) {
            self.billing = .incomplete;
            self.dirty = true;
            return error.UsageCapacityExceeded;
        }
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_origin = try alloc.dupe(u8, origin);
        errdefer alloc.free(owned_origin);
        const owned_team = if (team) |value| try alloc.dupe(u8, value) else null;
        errdefer if (owned_team) |value| alloc.free(value);
        try self.pending.append(alloc, .{
            .id = owned_id,
            .sequence = sequence,
            .origin = owned_origin,
            .team = owned_team,
            .observed_at_ms = io_mod.milliTimestamp(),
        });
        if (self.billing == .complete) self.billing = .pending;
        self.dirty = true;
    }

    pub fn applyGeneration(self: *Usage, alloc: Allocator, record: GenerationRecord) !void {
        try validateGenerationRecord(record);
        const fact = generationFactBorrowed(record);

        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        const publication = self.publishFact(fact);
        if (publication != .durable and self.checkpoint_sink != null) {
            self.stagePublicationBacklog(alloc, fact) catch |err| {
                self.checkpoint_mutex.unlock(io_mod.getIo());
                self.flushProfilePublications();
                return err;
            };
            if (!self.persistCheckpointBestEffortLocked()) {
                self.checkpoint_mutex.unlock(io_mod.getIo());
                self.flushProfilePublications();
                return error.ProfilePublicationRecoveryUnavailable;
            }
            self.checkpoint_mutex.unlock(io_mod.getIo());
            self.flushProfilePublications();
            // The rollback-readable event omits the richer publication fact,
            // so the pending generation remains the canonical recovery bridge
            // even when the sidecar preserves the full backlog.
            return;
        }
        if (publication == .failed) {
            self.stagePublicationBacklog(alloc, fact) catch |err| {
                self.checkpoint_mutex.unlock(io_mod.getIo());
                self.flushProfilePublications();
                return err;
            };
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        self.applyGenerationUnlocked(
            alloc,
            record,
            publication == .durable,
        ) catch |err| {
            self.mutex.unlock(io_mod.getIo());
            self.checkpoint_mutex.unlock(io_mod.getIo());
            self.flushProfilePublications();
            return err;
        };
        self.mutex.unlock(io_mod.getIo());
        _ = self.persistCheckpointBestEffortLocked();
        self.checkpoint_mutex.unlock(io_mod.getIo());
        if (publication == .failed) self.flushProfilePublications();
    }

    fn applyGatewayBilling(
        self: *Usage,
        alloc: Allocator,
        generation_id: []const u8,
        billing: types.GatewayBilling,
    ) !void {
        try self.applyGeneration(alloc, .{
            .id = generation_id,
            .created_at_ms = billing.created_at_ms,
            .model = billing.model,
            .total_cost = billing.total_cost,
            .input_tokens = billing.input_tokens,
            .output_tokens = billing.output_tokens,
            .cache_read_tokens = billing.cache_read_tokens,
            .cache_write_tokens = billing.cache_write_tokens,
            .reasoning_tokens = billing.reasoning_tokens,
            .billable_web_search_calls = billing.billable_web_search_calls,
        });
    }

    fn applyGenerationUnlocked(
        self: *Usage,
        alloc: Allocator,
        record: GenerationRecord,
        published: bool,
    ) !void {
        const pending_index = for (self.pending.items, 0..) |pending, index| {
            if (std.mem.eql(u8, pending.id, record.id)) break index;
        } else {
            if (published) self.removePublicationBacklogUnlocked(alloc, record.id);
            return;
        };
        const pending_sequence = self.pending.items[pending_index].sequence;

        const model_index = for (self.models.items, 0..) |model, index| {
            if (std.mem.eql(u8, model.model, record.model)) break index;
        } else null;
        if (model_index == null and self.models.items.len >= max_models) {
            self.billing = .incomplete;
            self.dirty = true;
            return error.UsageCapacityExceeded;
        }
        if (model_index == null) {
            const resolved_pending = self.pending.items[pending_index];
            var removed_identifier_bytes = resolved_pending.id.len +|
                resolved_pending.origin.len;
            if (resolved_pending.team) |team| removed_identifier_bytes +|= team.len;
            const next_identifier_bytes = std.math.add(
                usize,
                self.identifierBytesUnlocked() -| removed_identifier_bytes,
                record.model.len,
            ) catch return self.failOverflow();
            if (next_identifier_bytes > max_identifier_bytes) {
                self.billing = .incomplete;
                self.dirty = true;
                return error.UsageCapacityExceeded;
            }
        }

        const next_total_cost = self.total_cost + record.total_cost;
        if (!std.math.isFinite(next_total_cost)) {
            self.billing = .incomplete;
            self.dirty = true;
            return error.UsageOverflow;
        }
        const next_input_tokens = std.math.add(u64, self.input_tokens, record.input_tokens) catch return self.failOverflow();
        const next_output_tokens = std.math.add(u64, self.output_tokens, record.output_tokens) catch return self.failOverflow();
        const next_cache_read_tokens = std.math.add(u64, self.cache_read_tokens, record.cache_read_tokens) catch return self.failOverflow();
        const next_cache_write_tokens = std.math.add(u64, self.cache_write_tokens, record.cache_write_tokens) catch return self.failOverflow();
        const next_reasoning_tokens = try addOptionalCounter(
            self.reasoning_tokens,
            record.reasoning_tokens,
        );
        const next_request_count = if (self.request_count) |requests|
            std.math.add(u64, requests, 1) catch return self.failOverflow()
        else
            null;
        const next_web_search_calls = std.math.add(
            u64,
            self.billable_web_search_calls,
            record.billable_web_search_calls,
        ) catch return self.failOverflow();

        var owned_model: ?[]u8 = null;
        errdefer if (owned_model) |model| alloc.free(model);
        if (model_index == null) {
            owned_model = try alloc.dupe(u8, record.model);
            try self.models.ensureUnusedCapacity(alloc, 1);
        }

        if (model_index) |index| {
            try addRecordToModel(&self.models.items[index], record, pending_sequence);
        } else {
            var model = ModelAggregate{
                .model = owned_model.?,
                .first_sequence = pending_sequence,
                .reasoning_tokens = 0,
                .request_count = 0,
            };
            owned_model = null;
            try addRecordToModel(&model, record, pending_sequence);
            self.models.appendAssumeCapacity(model);
        }
        self.sortModelsBySequenceUnlocked();

        self.total_cost = next_total_cost;
        self.input_tokens = next_input_tokens;
        self.output_tokens = next_output_tokens;
        self.cache_read_tokens = next_cache_read_tokens;
        self.cache_write_tokens = next_cache_write_tokens;
        self.reasoning_tokens = next_reasoning_tokens;
        self.request_count = next_request_count;
        self.billable_web_search_calls = next_web_search_calls;

        var removed = self.pending.orderedRemove(pending_index);
        removed.deinit(alloc);
        if (published) self.removePublicationBacklogUnlocked(alloc, record.id);
        if (self.billing == .pending and self.pending.items.len == 0) {
            self.billing = .complete;
        }
        self.dirty = true;
    }

    const PublicationResult = enum {
        not_configured,
        durable,
        failed,
    };

    fn publishFact(
        self: *Usage,
        fact: usage_report.GenerationFact,
    ) PublicationResult {
        self.publication_mutex.lockUncancelable(io_mod.getIo());
        defer self.publication_mutex.unlock(io_mod.getIo());
        const sink = self.publication_sink orelse return .not_configured;
        sink.publish(sink.context, .{ .generation = fact }) catch |err| {
            debug_trace.logf(
                "session",
                "usage profile publication failed id={s} reason={s}",
                .{ fact.id, @errorName(err) },
            );
            return .failed;
        };
        return .durable;
    }

    fn stagePublicationBacklog(
        self: *Usage,
        alloc: Allocator,
        fact: usage_report.GenerationFact,
    ) !void {
        var owned = try fact.dupe(alloc);
        var owns_fact = true;
        defer if (owns_fact) owned.deinit(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const pending_exists = for (self.pending.items) |pending| {
            if (std.mem.eql(u8, pending.id, fact.id)) break true;
        } else false;
        if (!pending_exists) return;
        for (self.publication_backlog.items) |existing| {
            if (!std.mem.eql(u8, existing.id, fact.id)) continue;
            if (!usage_report.GenerationFact.eql(existing, fact)) {
                self.billing = .incomplete;
                self.recordIncidentUnlocked(.incomplete, fact.created_at_ms);
                self.dirty = true;
                return error.ConflictingGenerationRecord;
            }
            return;
        }
        if (self.publication_backlog.items.len == max_publication_backlog) {
            self.billing = .incomplete;
            self.recordIncidentUnlocked(.incomplete, fact.created_at_ms);
            self.dirty = true;
            return error.UsageCapacityExceeded;
        }
        try self.publication_backlog.append(alloc, owned);
        owns_fact = false;
        self.dirty = true;
    }

    fn snapshotProfilePublications(
        self: *Usage,
        alloc: Allocator,
    ) !ProfilePublicationBatch {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        const observed_at_ms = @max(io_mod.milliTimestamp(), 0);
        var checkpoint_changed = false;
        for (self.pending.items) |*pending| {
            if (pending.observed_at_ms != null) continue;
            pending.observed_at_ms = observed_at_ms;
            self.dirty = true;
            checkpoint_changed = true;
        }

        const pending = try alloc.alloc(
            usage_report.PendingMarker,
            self.pending.items.len,
        );
        errdefer alloc.free(pending);
        var copied_pending: usize = 0;
        errdefer for (pending[0..copied_pending]) |*marker| marker.deinit(alloc);
        for (self.pending.items, 0..) |generation, index| {
            pending[index] = .{
                .id = try alloc.dupe(u8, generation.id),
                .observed_at_ms = generation.observed_at_ms.?,
            };
            copied_pending += 1;
        }

        const incidents = try alloc.dupe(
            usage_report.Incident,
            self.incidents[0..self.incident_count],
        );
        errdefer alloc.free(incidents);

        const facts = try alloc.alloc(
            usage_report.GenerationFact,
            self.publication_backlog.items.len,
        );
        errdefer alloc.free(facts);
        var copied_facts: usize = 0;
        errdefer for (facts[0..copied_facts]) |*fact| fact.deinit(alloc);
        for (self.publication_backlog.items, 0..) |fact, index| {
            facts[index] = try fact.dupe(alloc);
            copied_facts += 1;
        }

        return .{
            .pending = pending,
            .incidents = incidents,
            .facts = facts,
            .checkpoint_changed = checkpoint_changed,
        };
    }

    fn flushProfilePublications(self: *Usage) void {
        self.publication_mutex.lockUncancelable(io_mod.getIo());
        const sink = self.publication_sink orelse {
            self.publication_mutex.unlock(io_mod.getIo());
            return;
        };

        var batch = self.snapshotProfilePublications(sink.allocator) catch |err| {
            self.publication_mutex.unlock(io_mod.getIo());
            debug_trace.logf(
                "session",
                "usage profile publication copy failed reason={s}",
                .{@errorName(err)},
            );
            return;
        };
        defer batch.deinit(sink.allocator);

        for (batch.pending) |marker| {
            sink.publish(sink.context, .{ .pending = marker }) catch |err| {
                debug_trace.logf(
                    "session",
                    "usage profile pending publication failed id={s} reason={s}",
                    .{ marker.id, @errorName(err) },
                );
            };
        }
        var published_any = false;
        for (batch.incidents) |incident| {
            sink.publish(sink.context, .{ .incident = incident }) catch |err| {
                debug_trace.logf(
                    "session",
                    "usage profile incident publication failed reason={s}",
                    .{@errorName(err)},
                );
                continue;
            };
            self.mutex.lockUncancelable(io_mod.getIo());
            self.removeIncidentUnlocked(incident);
            self.mutex.unlock(io_mod.getIo());
            published_any = true;
        }

        for (batch.facts) |fact| {
            sink.publish(sink.context, .{ .generation = fact }) catch |err| {
                debug_trace.logf(
                    "session",
                    "usage profile backlog retry failed id={s} reason={s}",
                    .{ fact.id, @errorName(err) },
                );
                continue;
            };
            self.mutex.lockUncancelable(io_mod.getIo());
            self.applyGenerationUnlocked(
                sink.allocator,
                generationRecordBorrowed(fact),
                true,
            ) catch |err| {
                self.billing = .incomplete;
                self.recordIncidentUnlocked(.incomplete, fact.created_at_ms);
                self.removePublicationBacklogUnlocked(sink.allocator, fact.id);
                self.dirty = true;
                debug_trace.logf(
                    "session",
                    "usage profile backlog settlement failed id={s} reason={s}",
                    .{ fact.id, @errorName(err) },
                );
            };
            self.mutex.unlock(io_mod.getIo());
            published_any = true;
        }
        self.publication_mutex.unlock(io_mod.getIo());

        if (batch.checkpoint_changed or published_any) {
            self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
            _ = self.persistCheckpointBestEffortLocked();
            self.checkpoint_mutex.unlock(io_mod.getIo());
        }
    }

    fn removePublicationBacklogUnlocked(
        self: *Usage,
        alloc: Allocator,
        id: []const u8,
    ) void {
        const index = for (self.publication_backlog.items, 0..) |fact, fact_index| {
            if (std.mem.eql(u8, fact.id, id)) break fact_index;
        } else return;
        var removed = self.publication_backlog.orderedRemove(index);
        removed.deinit(alloc);
    }

    fn removeIncidentUnlocked(
        self: *Usage,
        incident: usage_report.Incident,
    ) void {
        const index = for (self.incidents[0..self.incident_count], 0..) |existing, incident_index| {
            if (existing.occurred_at_ms == incident.occurred_at_ms and
                existing.completeness == incident.completeness)
            {
                break incident_index;
            }
        } else return;
        if (index + 1 < self.incident_count) {
            std.mem.copyForwards(
                usage_report.Incident,
                self.incidents[index .. self.incident_count - 1],
                self.incidents[index + 1 .. self.incident_count],
            );
        }
        self.incident_count -= 1;
        self.dirty = true;
    }

    fn recordIncidentUnlocked(
        self: *Usage,
        completeness: usage_report.Completeness,
        occurred_at_ms: i64,
    ) void {
        if (occurred_at_ms < 0) return;
        for (self.incidents[0..self.incident_count]) |incident| {
            if (incident.occurred_at_ms == occurred_at_ms and
                incident.completeness == completeness)
            {
                return;
            }
        }
        if (self.incident_count == max_usage_incidents) {
            var newest_at_ms = occurred_at_ms;
            for (self.incidents[0..self.incident_count]) |incident| {
                newest_at_ms = @max(newest_at_ms, incident.occurred_at_ms);
            }
            self.incidents[0] = .{
                .occurred_at_ms = newest_at_ms,
                .completeness = .incomplete,
            };
            self.incident_count = 1;
            return;
        }
        self.incidents[self.incident_count] = .{
            .occurred_at_ms = occurred_at_ms,
            .completeness = completeness,
        };
        self.incident_count += 1;
    }

    fn sortModelsBySequenceUnlocked(self: *Usage) void {
        var index: usize = 1;
        while (index < self.models.items.len) : (index += 1) {
            var current = index;
            while (current > 0 and
                self.models.items[current - 1].first_sequence >
                    self.models.items[current].first_sequence)
            {
                std.mem.swap(
                    ModelAggregate,
                    &self.models.items[current - 1],
                    &self.models.items[current],
                );
                current -= 1;
            }
        }
    }

    pub fn recordCommittedLines(self: *Usage, additions: usize, deletions: usize) !void {
        const additions_u64 = std.math.cast(u64, additions) orelse return error.UsageOverflow;
        const deletions_u64 = std.math.cast(u64, deletions) orelse return error.UsageOverflow;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.lines_added = std.math.add(u64, self.lines_added, additions_u64) catch {
            self.code_complete = false;
            self.dirty = true;
            return error.UsageOverflow;
        };
        self.lines_removed = std.math.add(u64, self.lines_removed, deletions_u64) catch {
            self.code_complete = false;
            self.dirty = true;
            return error.UsageOverflow;
        };
        self.dirty = true;
    }

    /// Returns an owned point-in-time snapshot. The caller must call `deinit`.
    pub fn snapshot(self: *Usage, alloc: Allocator) !Snapshot {
        self.finishReconciliationIfDone();
        return self.snapshotCurrent(alloc);
    }

    fn snapshotCurrent(self: *Usage, alloc: Allocator) !Snapshot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        const models = try alloc.alloc(ModelAggregate, self.models.items.len);
        errdefer alloc.free(models);
        var copied_models: usize = 0;
        errdefer for (models[0..copied_models]) |*model| model.deinit(alloc);
        for (self.models.items, 0..) |model, index| {
            models[index] = try model.dupe(alloc);
            copied_models += 1;
        }

        const pending = try alloc.alloc(PendingGeneration, self.pending.items.len);
        errdefer alloc.free(pending);
        var copied_pending: usize = 0;
        errdefer for (pending[0..copied_pending]) |*generation| generation.deinit(alloc);
        for (self.pending.items, 0..) |generation, index| {
            pending[index] = try generation.dupe(alloc);
            copied_pending += 1;
        }

        const publication_backlog = try alloc.alloc(
            usage_report.GenerationFact,
            self.publication_backlog.items.len,
        );
        errdefer alloc.free(publication_backlog);
        var copied_publications: usize = 0;
        errdefer for (publication_backlog[0..copied_publications]) |*fact| {
            fact.deinit(alloc);
        };
        for (self.publication_backlog.items, 0..) |fact, index| {
            publication_backlog[index] = try fact.dupe(alloc);
            copied_publications += 1;
        }

        const incidents = try alloc.dupe(
            usage_report.Incident,
            self.incidents[0..self.incident_count],
        );
        errdefer alloc.free(incidents);

        const now_ms = io_mod.milliTimestamp();
        if (self.active_started_at_ms == 0) self.active_started_at_ms = now_ms;
        const active_elapsed_ms = if (now_ms > self.active_started_at_ms)
            std.math.cast(u64, now_ms - self.active_started_at_ms) orelse
                std.math.maxInt(u64)
        else
            0;
        const wall_duration_ms = std.math.add(
            u64,
            self.wall_duration_ms,
            active_elapsed_ms,
        ) catch std.math.maxInt(u64);
        return .{
            .billing = if (self.active_sequence_count > 0)
                .incomplete
            else
                self.billing,
            .api_duration_complete = self.api_duration_complete and
                self.active_sequence_count == 0,
            .wall_duration_complete = self.wall_duration_complete and
                wall_duration_ms != std.math.maxInt(u64),
            .code_complete = self.code_complete,
            .next_sequence = self.next_sequence,
            .settled_through_sequence = self.settled_through_sequence,
            .api_duration_ms = self.api_duration_ms,
            .wall_duration_ms = wall_duration_ms,
            .total_cost = self.total_cost,
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .cache_read_tokens = self.cache_read_tokens,
            .cache_write_tokens = self.cache_write_tokens,
            .reasoning_tokens = self.reasoning_tokens,
            .request_count = self.request_count,
            .billable_web_search_calls = self.billable_web_search_calls,
            .lines_added = self.lines_added,
            .lines_removed = self.lines_removed,
            .models = models,
            .pending = pending,
            .publication_backlog = publication_backlog,
            .incidents = incidents,
        };
    }

    /// Returns the current session through the shared usage-report contract.
    pub fn reportSnapshot(
        self: *Usage,
        alloc: Allocator,
    ) !usage_report.Snapshot {
        var source_snapshot = try self.snapshot(alloc);
        defer source_snapshot.deinit(alloc);

        const models = try alloc.alloc(
            usage_report.SessionModelSource,
            source_snapshot.models.len,
        );
        defer alloc.free(models);
        for (source_snapshot.models, 0..) |model, index| {
            models[index] = .{
                .model = model.model,
                .total_cost = model.total_cost,
                .input_tokens = model.input_tokens,
                .output_tokens = model.output_tokens,
                .cache_read_tokens = model.cache_read_tokens,
                .cache_write_tokens = model.cache_write_tokens,
                .reasoning_tokens = model.reasoning_tokens,
                .request_count = model.request_count,
            };
        }

        const snapshot_time_ms = @max(io_mod.milliTimestamp(), 0);
        const wall_duration_ms = std.math.cast(i64, source_snapshot.wall_duration_ms) orelse
            snapshot_time_ms;
        return usage_report.buildSessionSnapshot(alloc, .{
            .snapshot_time_ms = snapshot_time_ms,
            .session_started_at_ms = @max(snapshot_time_ms -| wall_duration_ms, 0),
            .completeness = switch (source_snapshot.billing) {
                .complete => .complete,
                .pending => .pending,
                .incomplete => .incomplete,
                .legacy => .legacy,
            },
            .total_cost = source_snapshot.total_cost,
            .input_tokens = source_snapshot.input_tokens,
            .output_tokens = source_snapshot.output_tokens,
            .cache_read_tokens = source_snapshot.cache_read_tokens,
            .cache_write_tokens = source_snapshot.cache_write_tokens,
            .reasoning_tokens = source_snapshot.reasoning_tokens,
            .request_count = source_snapshot.request_count,
            .models = models,
            .activity = .{
                .api_duration_complete = source_snapshot.api_duration_complete,
                .wall_duration_complete = source_snapshot.wall_duration_complete,
                .code_complete = source_snapshot.code_complete,
                .api_duration_ms = source_snapshot.api_duration_ms,
                .wall_duration_ms = source_snapshot.wall_duration_ms,
                .lines_added = source_snapshot.lines_added,
                .lines_removed = source_snapshot.lines_removed,
            },
        });
    }

    pub fn restore(
        self: *Usage,
        alloc: Allocator,
        source: Snapshot,
        session_started_at_ms: i64,
    ) !void {
        self.stopReconciliation();
        try validateSnapshot(source);

        var copied = try dupeSnapshotOwned(alloc, source);
        errdefer copied.deinit(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        self.clearOwnedUnlocked(alloc);
        self.billing = copied.billing;
        self.api_duration_complete = copied.api_duration_complete;
        self.wall_duration_complete = copied.wall_duration_complete;
        self.code_complete = copied.code_complete;
        self.next_sequence = copied.next_sequence;
        self.settled_through_sequence = copied.settled_through_sequence;
        self.api_duration_ms = copied.api_duration_ms;
        // Wall time is derived from durable session creation; restoring a
        // checkpoint's elapsed value as well would count the same span twice.
        self.wall_duration_ms = 0;
        const now_ms = io_mod.milliTimestamp();
        if (session_started_at_ms <= 0 or session_started_at_ms > now_ms) {
            self.wall_duration_complete = false;
            self.active_started_at_ms = now_ms;
        } else {
            self.active_started_at_ms = session_started_at_ms;
        }
        self.active_sequence_count = 0;
        self.total_cost = copied.total_cost;
        self.input_tokens = copied.input_tokens;
        self.output_tokens = copied.output_tokens;
        self.cache_read_tokens = copied.cache_read_tokens;
        self.cache_write_tokens = copied.cache_write_tokens;
        self.reasoning_tokens = copied.reasoning_tokens;
        self.request_count = copied.request_count;
        self.billable_web_search_calls = copied.billable_web_search_calls;
        self.lines_added = copied.lines_added;
        self.lines_removed = copied.lines_removed;
        self.models = .fromOwnedSlice(copied.models);
        self.pending = .fromOwnedSlice(copied.pending);
        self.publication_backlog = .fromOwnedSlice(copied.publication_backlog);
        self.incident_count = copied.incidents.len;
        std.mem.copyForwards(
            usage_report.Incident,
            self.incidents[0..self.incident_count],
            copied.incidents,
        );
        if (copied.incidents.len > 0) alloc.free(copied.incidents);
        copied = undefined;
        self.dirty = false;
        self.mutex.unlock(io_mod.getIo());
        self.flushProfilePublications();
    }

    pub fn isDirty(self: *Usage) bool {
        self.finishReconciliationIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.dirty;
    }

    pub fn startReconciliation(
        self: *Usage,
        alloc: Allocator,
        api_key: []const u8,
    ) void {
        self.startReconciliationWithCredential(alloc, api_key, false, null);
    }

    /// Installs the host's authoritative credential regardless of the prior key.
    pub fn replaceReconciliationCredential(
        self: *Usage,
        alloc: Allocator,
        api_key: []const u8,
    ) void {
        self.startReconciliationWithCredential(alloc, api_key, true, null);
    }

    /// Replaces a producer's key only while that key is still authoritative.
    pub fn refreshReconciliationCredential(
        self: *Usage,
        alloc: Allocator,
        expected_api_key: []const u8,
        refreshed_api_key: []const u8,
    ) void {
        self.startReconciliationWithCredential(
            alloc,
            refreshed_api_key,
            true,
            expected_api_key,
        );
    }

    /// Cancels credential work and rejects stale producer starts until replaced.
    pub fn clearReconciliationCredential(self: *Usage) void {
        self.reconciliation_cancel.store(true, .seq_cst);
        self.reconciliation_mutex.lockUncancelable(io_mod.getIo());
        defer self.reconciliation_mutex.unlock(io_mod.getIo());
        self.reconciliation_cancel.store(true, .seq_cst);
        if (comptime builtin.os.tag != .wasi) {
            _ = self.reconciliation_work_epoch.fetchAdd(1, .seq_cst);
        }
        const thread = self.reconciliation_thread;
        self.reconciliation_thread = null;
        if (thread) |handle| handle.join();
        self.reconciliation_done.store(true, .seq_cst);
        self.reconciliation_cancel.store(false, .seq_cst);
        self.reconciliation_key_digest = null;
        self.reconciliation_credential_blocked = true;
    }

    fn startReconciliationWithCredential(
        self: *Usage,
        alloc: Allocator,
        api_key: []const u8,
        replace_existing: bool,
        expected_api_key: ?[]const u8,
    ) void {
        if (api_key.len == 0) return;
        const key_digest = reconciliationKeyDigest(api_key);
        const expected_digest = if (expected_api_key) |expected|
            reconciliationKeyDigest(expected)
        else
            null;
        self.reconciliation_mutex.lockUncancelable(io_mod.getIo());
        defer self.reconciliation_mutex.unlock(io_mod.getIo());
        const authoritative_replace =
            replace_existing and expected_api_key == null;
        if (self.reconciliation_credential_blocked and
            !authoritative_replace)
        {
            return;
        }
        if (authoritative_replace) {
            self.reconciliation_credential_blocked = false;
        }
        const same_key = if (self.reconciliation_key_digest) |active_digest|
            std.mem.eql(u8, &active_digest, &key_digest)
        else
            false;
        if (self.reconciliation_key_digest) |active_digest| {
            if (!same_key) {
                if (!replace_existing) return;
                if (expected_digest) |expected| {
                    if (!std.mem.eql(u8, &active_digest, &expected)) return;
                }
            }
        }
        if (comptime builtin.os.tag != .wasi) {
            _ = self.reconciliation_work_epoch.fetchAdd(1, .seq_cst);
        }
        if (self.reconciliation_thread) |thread| {
            if (same_key and !self.reconciliation_done.load(.seq_cst)) return;
            self.reconciliation_cancel.store(true, .seq_cst);
            self.reconciliation_thread = null;
            thread.join();
            self.reconciliation_done.store(true, .seq_cst);
            self.reconciliation_cancel.store(false, .seq_cst);
        }
        self.reconciliation_key_digest = key_digest;
        if (builtin.is_test) return;
        if (comptime builtin.os.tag == .wasi) return;

        self.mutex.lockUncancelable(io_mod.getIo());
        const still_has_pending = self.pending.items.len > 0;
        self.mutex.unlock(io_mod.getIo());
        if (!still_has_pending) return;

        const api_key_copy = alloc.dupe(u8, api_key) catch |err| {
            debug_trace.logf(
                "session",
                "usage reconciliation start failed reason={s}",
                .{@errorName(err)},
            );
            return;
        };
        self.reconciliation_cancel.store(false, .seq_cst);
        self.reconciliation_done.store(false, .seq_cst);
        self.reconciliation_key_digest = key_digest;
        self.reconciliation_thread = std.Thread.spawn(
            .{},
            reconciliationThreadMain,
            .{ self, alloc, api_key_copy, self.generation_usage_provider },
        ) catch |err| {
            self.reconciliation_done.store(true, .seq_cst);
            debug_trace.logf(
                "session",
                "usage reconciliation start failed reason={s}",
                .{@errorName(err)},
            );
            secret.zeroAndFree(alloc, api_key_copy);
            return;
        };
    }

    pub fn cancelReconciliation(self: *Usage) void {
        self.stopReconciliation();
    }

    /// Gives the current worker a bounded drain, then cancels it so one-shot
    /// hosts can persist prompt results without turning exit into an API wait.
    pub fn finishReconciliationBeforeShutdown(self: *Usage) void {
        for (0..shutdown_reconciliation_budget_ms / 5) |_| {
            if (self.reconciliation_done.load(.seq_cst)) {
                self.finishReconciliationIfDone();
                return;
            }
            io_mod.sleep(5 * std.time.ns_per_ms);
        }
        self.stopReconciliation();
    }

    pub fn finishProfilePublicationsBeforeShutdown(self: *Usage) void {
        self.flushProfilePublications();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.publication_backlog.items.len > 0) {
            debug_trace.logf(
                "session",
                "usage profile publication incomplete facts={d}",
                .{self.publication_backlog.items.len},
            );
        }
    }

    fn finishReconciliationIfDone(self: *Usage) void {
        if (!self.reconciliation_done.load(.seq_cst)) return;
        self.reconciliation_mutex.lockUncancelable(io_mod.getIo());
        if (!self.reconciliation_done.load(.seq_cst)) {
            self.reconciliation_mutex.unlock(io_mod.getIo());
            return;
        }
        const thread = self.reconciliation_thread;
        self.reconciliation_thread = null;
        if (thread) |handle| {
            self.reconciliation_cancel.store(true, .seq_cst);
            handle.join();
            self.reconciliation_cancel.store(false, .seq_cst);
        }
        self.reconciliation_done.store(true, .seq_cst);
        self.reconciliation_mutex.unlock(io_mod.getIo());
    }

    fn stopReconciliation(self: *Usage) void {
        self.reconciliation_cancel.store(true, .seq_cst);
        self.reconciliation_mutex.lockUncancelable(io_mod.getIo());
        self.reconciliation_cancel.store(true, .seq_cst);
        const thread = self.reconciliation_thread;
        self.reconciliation_thread = null;
        if (thread) |handle| handle.join();
        self.reconciliation_done.store(true, .seq_cst);
        self.reconciliation_cancel.store(false, .seq_cst);
        self.reconciliation_mutex.unlock(io_mod.getIo());
    }

    fn markBillingIncomplete(self: *Usage) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.billing = .incomplete;
        self.recordIncidentUnlocked(.incomplete, @max(io_mod.milliTimestamp(), 0));
        self.dirty = true;
    }

    fn rejectPendingGeneration(self: *Usage, alloc: Allocator, id: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const pending_index = for (self.pending.items, 0..) |pending, index| {
            if (std.mem.eql(u8, pending.id, id)) break index;
        } else null;
        if (pending_index) |index| {
            var removed = self.pending.orderedRemove(index);
            self.recordIncidentUnlocked(
                .incomplete,
                removed.observed_at_ms orelse io_mod.milliTimestamp(),
            );
            removed.deinit(alloc);
        }
        self.billing = .incomplete;
        self.dirty = true;
        self.mutex.unlock(io_mod.getIo());
        self.flushProfilePublications();
    }

    pub fn markCodeIncomplete(self: *Usage) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.code_complete = false;
        self.dirty = true;
    }

    pub fn markClean(self: *Usage, persisted: Snapshot) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.matchesSnapshotUnlocked(persisted)) return;
        self.dirty = false;
    }

    fn failOverflow(self: *Usage) error{UsageOverflow} {
        self.billing = .incomplete;
        self.dirty = true;
        return error.UsageOverflow;
    }

    fn identifierBytesUnlocked(self: *const Usage) usize {
        var total: usize = 0;
        for (self.models.items) |model| total +|= model.model.len;
        for (self.pending.items) |generation| {
            total +|= generation.id.len;
            total +|= generation.origin.len;
            if (generation.team) |team| total +|= team.len;
        }
        for (self.publication_backlog.items) |fact| {
            total +|= fact.id.len;
            total +|= fact.model.len;
        }
        return total;
    }

    fn matchesSnapshotUnlocked(self: *const Usage, snapshot_value: Snapshot) bool {
        if (self.active_sequence_count > 0) return false;
        if (self.billing != snapshot_value.billing or
            self.api_duration_complete != snapshot_value.api_duration_complete or
            self.wall_duration_complete != snapshot_value.wall_duration_complete or
            self.code_complete != snapshot_value.code_complete or
            self.next_sequence != snapshot_value.next_sequence or
            self.settled_through_sequence != snapshot_value.settled_through_sequence or
            self.api_duration_ms != snapshot_value.api_duration_ms or
            self.total_cost != snapshot_value.total_cost or
            self.input_tokens != snapshot_value.input_tokens or
            self.output_tokens != snapshot_value.output_tokens or
            self.cache_read_tokens != snapshot_value.cache_read_tokens or
            self.cache_write_tokens != snapshot_value.cache_write_tokens or
            self.reasoning_tokens != snapshot_value.reasoning_tokens or
            self.request_count != snapshot_value.request_count or
            self.billable_web_search_calls != snapshot_value.billable_web_search_calls or
            self.lines_added != snapshot_value.lines_added or
            self.lines_removed != snapshot_value.lines_removed or
            self.models.items.len != snapshot_value.models.len or
            self.pending.items.len != snapshot_value.pending.len or
            self.publication_backlog.items.len != snapshot_value.publication_backlog.len or
            self.incident_count != snapshot_value.incidents.len)
        {
            return false;
        }
        for (self.models.items, snapshot_value.models) |model, saved| {
            if (!std.mem.eql(u8, model.model, saved.model) or
                model.first_sequence != saved.first_sequence or
                model.total_cost != saved.total_cost or
                model.input_tokens != saved.input_tokens or
                model.output_tokens != saved.output_tokens or
                model.cache_read_tokens != saved.cache_read_tokens or
                model.cache_write_tokens != saved.cache_write_tokens or
                model.reasoning_tokens != saved.reasoning_tokens or
                model.request_count != saved.request_count or
                model.billable_web_search_calls != saved.billable_web_search_calls)
            {
                return false;
            }
        }
        for (self.pending.items, snapshot_value.pending) |generation, saved| {
            if (!std.mem.eql(u8, generation.id, saved.id) or
                generation.sequence != saved.sequence or
                !std.mem.eql(u8, generation.origin, saved.origin) or
                !optionalStringsEqual(generation.team, saved.team) or
                generation.observed_at_ms != saved.observed_at_ms)
            {
                return false;
            }
        }
        for (self.publication_backlog.items, snapshot_value.publication_backlog) |fact, saved| {
            if (!usage_report.GenerationFact.eql(fact, saved)) return false;
        }
        for (self.incidents[0..self.incident_count], snapshot_value.incidents) |incident, saved| {
            if (incident.occurred_at_ms != saved.occurred_at_ms or
                incident.completeness != saved.completeness)
            {
                return false;
            }
        }
        return true;
    }

    fn clearOwned(self: *Usage, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.clearOwnedUnlocked(alloc);
    }

    fn reset(self: *Usage, alloc: Allocator, fresh: bool) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.pending.items.len > 0 or self.active_sequence_count > 0) {
            debug_trace.logf(
                "session",
                "usage reset drops live state pending={d} active={d}",
                .{ self.pending.items.len, self.active_sequence_count },
            );
        }
        self.clearOwnedUnlocked(alloc);
        self.billing = if (fresh) .complete else .legacy;
        self.api_duration_complete = fresh;
        self.wall_duration_complete = fresh;
        self.code_complete = fresh;
        self.next_sequence = 1;
        self.settled_through_sequence = 0;
        self.api_duration_ms = 0;
        self.wall_duration_ms = 0;
        self.active_started_at_ms = io_mod.milliTimestamp();
        self.active_sequence_count = 0;
        self.total_cost = 0;
        self.input_tokens = 0;
        self.output_tokens = 0;
        self.cache_read_tokens = 0;
        self.cache_write_tokens = 0;
        self.reasoning_tokens = if (fresh) 0 else null;
        self.request_count = if (fresh) 0 else null;
        self.billable_web_search_calls = 0;
        self.lines_added = 0;
        self.lines_removed = 0;
        self.incident_count = 0;
        self.dirty = false;
    }

    fn clearOwnedUnlocked(self: *Usage, alloc: Allocator) void {
        for (self.models.items) |*model| model.deinit(alloc);
        self.models.deinit(alloc);
        self.models = .empty;
        for (self.pending.items) |*generation| generation.deinit(alloc);
        self.pending.deinit(alloc);
        self.pending = .empty;
        for (self.publication_backlog.items) |*fact| fact.deinit(alloc);
        self.publication_backlog.deinit(alloc);
        self.publication_backlog = .empty;
    }
};

pub fn validateSnapshot(snapshot: Snapshot) !void {
    if (snapshot.next_sequence == 0) return error.InvalidUsageSnapshot;
    if (snapshot.settled_through_sequence >= snapshot.next_sequence) {
        return error.InvalidUsageSnapshot;
    }
    if (!std.math.isFinite(snapshot.total_cost) or snapshot.total_cost < 0) {
        return error.InvalidUsageSnapshot;
    }
    if (snapshot.models.len > max_models or
        snapshot.pending.len > max_pending_generations or
        snapshot.publication_backlog.len > max_publication_backlog or
        snapshot.incidents.len > max_usage_incidents)
    {
        return error.UsageCapacityExceeded;
    }
    if (snapshot.billing == .complete and snapshot.pending.len != 0) {
        return error.InvalidUsageSnapshot;
    }
    if (snapshot.billing == .pending and snapshot.pending.len == 0) {
        return error.InvalidUsageSnapshot;
    }
    var identifier_bytes: usize = 0;
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;
    var cache_read_tokens: u64 = 0;
    var cache_write_tokens: u64 = 0;
    var reasoning_tokens: ?u64 = if (snapshot.reasoning_tokens == null)
        null
    else
        0;
    var request_count: ?u64 = if (snapshot.request_count == null)
        null
    else
        0;
    var billable_web_search_calls: u64 = 0;
    var total_cost: f64 = 0;
    for (snapshot.models, 0..) |model, index| {
        try validateModel(model.model);
        if (model.first_sequence == 0 or model.first_sequence >= snapshot.next_sequence) {
            return error.InvalidUsageSnapshot;
        }
        if (!std.math.isFinite(model.total_cost) or model.total_cost < 0) {
            return error.InvalidUsageSnapshot;
        }
        total_cost += model.total_cost;
        if (!std.math.isFinite(total_cost)) return error.InvalidUsageSnapshot;
        identifier_bytes = std.math.add(usize, identifier_bytes, model.model.len) catch
            return error.UsageCapacityExceeded;
        input_tokens = std.math.add(u64, input_tokens, model.input_tokens) catch
            return error.InvalidUsageSnapshot;
        output_tokens = std.math.add(u64, output_tokens, model.output_tokens) catch
            return error.InvalidUsageSnapshot;
        cache_read_tokens = std.math.add(u64, cache_read_tokens, model.cache_read_tokens) catch
            return error.InvalidUsageSnapshot;
        cache_write_tokens = std.math.add(u64, cache_write_tokens, model.cache_write_tokens) catch
            return error.InvalidUsageSnapshot;
        reasoning_tokens = addOptionalCounter(
            reasoning_tokens,
            model.reasoning_tokens,
        ) catch return error.InvalidUsageSnapshot;
        request_count = addOptionalCounter(
            request_count,
            model.request_count,
        ) catch return error.InvalidUsageSnapshot;
        if (model.cache_read_tokens > model.input_tokens or
            model.cache_write_tokens > model.input_tokens)
        {
            return error.InvalidUsageSnapshot;
        }
        if (model.reasoning_tokens) |reasoning| {
            if (reasoning > model.output_tokens) return error.InvalidUsageSnapshot;
        }
        billable_web_search_calls = std.math.add(
            u64,
            billable_web_search_calls,
            model.billable_web_search_calls,
        ) catch return error.InvalidUsageSnapshot;
        for (snapshot.models[0..index]) |prior| {
            if (std.mem.eql(u8, prior.model, model.model)) return error.InvalidUsageSnapshot;
        }
        if (index > 0 and
            snapshot.models[index - 1].first_sequence >= model.first_sequence)
        {
            return error.InvalidUsageSnapshot;
        }
    }
    if (input_tokens != snapshot.input_tokens or
        output_tokens != snapshot.output_tokens or
        cache_read_tokens != snapshot.cache_read_tokens or
        cache_write_tokens != snapshot.cache_write_tokens or
        reasoning_tokens != snapshot.reasoning_tokens or
        request_count != snapshot.request_count or
        billable_web_search_calls != snapshot.billable_web_search_calls)
    {
        return error.InvalidUsageSnapshot;
    }
    const cost_tolerance = @max(1e-12, snapshot.total_cost * 1e-12);
    if (@abs(total_cost - snapshot.total_cost) > cost_tolerance) {
        return error.InvalidUsageSnapshot;
    }
    for (snapshot.pending, 0..) |generation, index| {
        try validateGenerationId(generation.id);
        try validateOrigin(generation.origin);
        if (generation.team) |team| try validateTeam(team);
        if (generation.sequence == 0 or generation.sequence >= snapshot.next_sequence) {
            return error.InvalidUsageSnapshot;
        }
        if (generation.observed_at_ms) |observed_at_ms| {
            if (observed_at_ms < 0) return error.InvalidUsageSnapshot;
        }
        identifier_bytes = std.math.add(usize, identifier_bytes, generation.id.len) catch
            return error.UsageCapacityExceeded;
        identifier_bytes = std.math.add(usize, identifier_bytes, generation.origin.len) catch
            return error.UsageCapacityExceeded;
        if (generation.team) |team| {
            identifier_bytes = std.math.add(usize, identifier_bytes, team.len) catch
                return error.UsageCapacityExceeded;
        }
        for (snapshot.pending[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, generation.id) or
                prior.sequence == generation.sequence)
            {
                return error.InvalidUsageSnapshot;
            }
        }
    }
    for (snapshot.publication_backlog, 0..) |fact, index| {
        usage_report.validateFact(fact) catch return error.InvalidUsageSnapshot;
        identifier_bytes = std.math.add(usize, identifier_bytes, fact.id.len) catch
            return error.UsageCapacityExceeded;
        identifier_bytes = std.math.add(usize, identifier_bytes, fact.model.len) catch
            return error.UsageCapacityExceeded;
        for (snapshot.publication_backlog[0..index]) |prior| {
            if (!std.mem.eql(u8, prior.id, fact.id)) continue;
            if (!usage_report.GenerationFact.eql(prior, fact)) {
                return error.InvalidUsageSnapshot;
            }
            return error.InvalidUsageSnapshot;
        }
    }
    for (snapshot.incidents) |incident| {
        if (incident.occurred_at_ms < 0 or
            (incident.completeness != .pending and
                incident.completeness != .incomplete))
        {
            return error.InvalidUsageSnapshot;
        }
    }
    if (identifier_bytes > max_identifier_bytes) return error.UsageCapacityExceeded;
}

pub fn appendIncidentOwned(
    alloc: Allocator,
    snapshot: *Snapshot,
    incident: usage_report.Incident,
) !void {
    if (incident.occurred_at_ms < 0 or
        (incident.completeness != .pending and
            incident.completeness != .incomplete))
    {
        return error.InvalidUsageSnapshot;
    }
    for (snapshot.incidents) |existing| {
        if (existing.occurred_at_ms == incident.occurred_at_ms and
            existing.completeness == incident.completeness)
        {
            return;
        }
    }

    if (snapshot.incidents.len == max_usage_incidents) {
        var newest_at_ms = incident.occurred_at_ms;
        for (snapshot.incidents) |existing| {
            newest_at_ms = @max(newest_at_ms, existing.occurred_at_ms);
        }
        const next = try alloc.alloc(usage_report.Incident, 1);
        next[0] = .{
            .occurred_at_ms = newest_at_ms,
            .completeness = .incomplete,
        };
        alloc.free(snapshot.incidents);
        snapshot.incidents = next;
        return;
    }

    const next = try alloc.alloc(
        usage_report.Incident,
        snapshot.incidents.len + 1,
    );
    if (snapshot.incidents.len > 0) {
        std.mem.copyForwards(
            usage_report.Incident,
            next[0..snapshot.incidents.len],
            snapshot.incidents,
        );
    }
    next[snapshot.incidents.len] = incident;
    if (snapshot.incidents.len > 0) alloc.free(snapshot.incidents);
    snapshot.incidents = next;
}

/// Returns whether two snapshots have the same rollback-readable usage shape.
pub fn rollbackProjectionEql(first: Snapshot, second: Snapshot) bool {
    return billingProjectionEql(first, second) and
        first.api_duration_complete == second.api_duration_complete and
        first.wall_duration_complete == second.wall_duration_complete and
        first.code_complete == second.code_complete and
        first.api_duration_ms == second.api_duration_ms and
        first.wall_duration_ms == second.wall_duration_ms and
        first.lines_added == second.lines_added and
        first.lines_removed == second.lines_removed;
}

/// Returns whether two current-schema snapshots contain the same usage state.
pub fn snapshotEql(first: Snapshot, second: Snapshot) bool {
    if (!rollbackProjectionEql(first, second) or
        first.reasoning_tokens != second.reasoning_tokens or
        first.request_count != second.request_count or
        first.publication_backlog.len != second.publication_backlog.len or
        first.incidents.len != second.incidents.len)
    {
        return false;
    }
    for (first.models, second.models) |left, right| {
        if (left.reasoning_tokens != right.reasoning_tokens or
            left.request_count != right.request_count)
        {
            return false;
        }
    }
    for (first.pending, second.pending) |left, right| {
        if (left.observed_at_ms != right.observed_at_ms) return false;
    }
    for (first.publication_backlog, second.publication_backlog) |left, right| {
        if (!usage_report.GenerationFact.eql(left, right)) return false;
    }
    for (first.incidents, second.incidents) |left, right| {
        if (left.occurred_at_ms != right.occurred_at_ms or
            left.completeness != right.completeness)
        {
            return false;
        }
    }
    return true;
}

/// Returns whether two snapshots have the same billing-relevant projection.
pub fn billingProjectionEql(first: Snapshot, second: Snapshot) bool {
    if (first.billing != second.billing or
        first.next_sequence != second.next_sequence or
        first.settled_through_sequence != second.settled_through_sequence or
        first.total_cost != second.total_cost or
        first.input_tokens != second.input_tokens or
        first.output_tokens != second.output_tokens or
        first.cache_read_tokens != second.cache_read_tokens or
        first.cache_write_tokens != second.cache_write_tokens or
        first.billable_web_search_calls !=
            second.billable_web_search_calls or
        first.models.len != second.models.len or
        first.pending.len != second.pending.len)
    {
        return false;
    }
    for (first.models, second.models) |left, right| {
        if (!std.mem.eql(u8, left.model, right.model) or
            left.first_sequence != right.first_sequence or
            left.total_cost != right.total_cost or
            left.input_tokens != right.input_tokens or
            left.output_tokens != right.output_tokens or
            left.cache_read_tokens != right.cache_read_tokens or
            left.cache_write_tokens != right.cache_write_tokens or
            left.billable_web_search_calls !=
                right.billable_web_search_calls)
        {
            return false;
        }
    }
    for (first.pending, second.pending) |left, right| {
        if (!std.mem.eql(u8, left.id, right.id) or
            left.sequence != right.sequence or
            !std.mem.eql(u8, left.origin, right.origin) or
            !optionalStringsEqual(left.team, right.team))
        {
            return false;
        }
    }
    return true;
}

pub fn writeSnapshot(writer: *std.Io.Writer, snapshot: Snapshot) !void {
    try validateSnapshot(snapshot);
    // Keep the durable session payload in the exact pre-usage-dashboard
    // shape. Older fx binaries reject unknown snapshot fields instead of
    // ignoring them; richer metrics and recovery hints live in the validated
    // session sidecar.
    try writer.writeAll("{\"billing\":");
    try std.json.Stringify.value(@tagName(snapshot.billing), .{}, writer);
    try writer.print(
        ",\"api_duration_complete\":{s},\"wall_duration_complete\":{s},\"code_complete\":{s},\"next_sequence\":{d},\"settled_through_sequence\":{d},\"api_duration_ms\":{d},\"wall_duration_ms\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"billable_web_search_calls\":{d},\"lines_added\":{d},\"lines_removed\":{d},\"models\":[",
        .{
            if (snapshot.api_duration_complete) "true" else "false",
            if (snapshot.wall_duration_complete) "true" else "false",
            if (snapshot.code_complete) "true" else "false",
            snapshot.next_sequence,
            snapshot.settled_through_sequence,
            snapshot.api_duration_ms,
            snapshot.wall_duration_ms,
            snapshot.total_cost,
            snapshot.input_tokens,
            snapshot.output_tokens,
            snapshot.cache_read_tokens,
            snapshot.cache_write_tokens,
            snapshot.billable_web_search_calls,
            snapshot.lines_added,
            snapshot.lines_removed,
        },
    );
    for (snapshot.models, 0..) |model, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"model\":");
        try std.json.Stringify.value(model.model, .{}, writer);
        try writer.print(
            ",\"first_sequence\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"billable_web_search_calls\":{d}}}",
            .{
                model.first_sequence,
                model.total_cost,
                model.input_tokens,
                model.output_tokens,
                model.cache_read_tokens,
                model.cache_write_tokens,
                model.billable_web_search_calls,
            },
        );
    }
    try writer.writeAll("],\"pending\":[");
    for (snapshot.pending, 0..) |pending, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(pending.id, .{}, writer);
        try writer.print(",\"sequence\":{d},\"origin\":", .{pending.sequence});
        try std.json.Stringify.value(pending.origin, .{}, writer);
        try writer.writeAll(",\"team\":");
        if (pending.team) |team| {
            try std.json.Stringify.value(team, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

/// Writes the current usage schema for storage outside the rollback-readable
/// session event stream.
pub fn writeRichSnapshot(writer: *std.Io.Writer, snapshot: Snapshot) !void {
    try validateSnapshot(snapshot);
    try writer.writeAll("{\"schema_version\":2,\"billing\":");
    try std.json.Stringify.value(@tagName(snapshot.billing), .{}, writer);
    try writer.print(
        ",\"api_duration_complete\":{s},\"wall_duration_complete\":{s},\"code_complete\":{s},\"next_sequence\":{d},\"settled_through_sequence\":{d},\"api_duration_ms\":{d},\"wall_duration_ms\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
        .{
            if (snapshot.api_duration_complete) "true" else "false",
            if (snapshot.wall_duration_complete) "true" else "false",
            if (snapshot.code_complete) "true" else "false",
            snapshot.next_sequence,
            snapshot.settled_through_sequence,
            snapshot.api_duration_ms,
            snapshot.wall_duration_ms,
            snapshot.total_cost,
            snapshot.input_tokens,
            snapshot.output_tokens,
            snapshot.cache_read_tokens,
            snapshot.cache_write_tokens,
        },
    );
    try writeOptionalU64(writer, snapshot.reasoning_tokens);
    try writer.writeAll(",\"request_count\":");
    try writeOptionalU64(writer, snapshot.request_count);
    try writer.print(
        ",\"billable_web_search_calls\":{d},\"lines_added\":{d},\"lines_removed\":{d},\"models\":[",
        .{
            snapshot.billable_web_search_calls,
            snapshot.lines_added,
            snapshot.lines_removed,
        },
    );
    for (snapshot.models, 0..) |model, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"model\":");
        try std.json.Stringify.value(model.model, .{}, writer);
        try writer.print(
            ",\"first_sequence\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
            .{
                model.first_sequence,
                model.total_cost,
                model.input_tokens,
                model.output_tokens,
                model.cache_read_tokens,
                model.cache_write_tokens,
            },
        );
        try writeOptionalU64(writer, model.reasoning_tokens);
        try writer.writeAll(",\"request_count\":");
        try writeOptionalU64(writer, model.request_count);
        try writer.print(
            ",\"billable_web_search_calls\":{d}}}",
            .{model.billable_web_search_calls},
        );
    }
    try writer.writeAll("],\"pending\":[");
    for (snapshot.pending, 0..) |pending, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(pending.id, .{}, writer);
        try writer.print(",\"sequence\":{d},\"origin\":", .{pending.sequence});
        try std.json.Stringify.value(pending.origin, .{}, writer);
        try writer.writeAll(",\"team\":");
        if (pending.team) |team| {
            try std.json.Stringify.value(team, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"observed_at_ms\":");
        if (pending.observed_at_ms) |observed_at_ms| {
            try writer.print("{d}", .{observed_at_ms});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"publication_backlog\":[");
    for (snapshot.publication_backlog, 0..) |fact, index| {
        if (index > 0) try writer.writeByte(',');
        try generation_fact_codec.write(writer, fact);
    }
    try writer.writeAll("],\"incidents\":[");
    for (snapshot.incidents, 0..) |incident, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print(
            "{{\"occurred_at_ms\":{d},\"completeness\":",
            .{incident.occurred_at_ms},
        );
        try std.json.Stringify.value(@tagName(incident.completeness), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

/// Parses either the rollback-readable or current usage snapshot schema.
pub fn parseSnapshotValue(alloc: Allocator, value: std.json.Value) !Snapshot {
    if (value != .object) {
        return error.InvalidUsageSnapshot;
    }
    const legacy = value.object.count() == 18;
    if (!legacy) {
        if (value.object.count() != 23 or
            try parseNonNegativeInteger(value.object.get("schema_version")) != 2)
        {
            return error.InvalidUsageSnapshot;
        }
    }
    const billing_value = value.object.get("billing") orelse return error.InvalidUsageSnapshot;
    if (billing_value != .string) return error.InvalidUsageSnapshot;
    const billing = std.meta.stringToEnum(Availability, billing_value.string) orelse
        return error.InvalidUsageSnapshot;
    const api_complete = try parseBool(value.object.get("api_duration_complete"));
    const wall_complete = try parseBool(value.object.get("wall_duration_complete"));
    const code_complete = try parseBool(value.object.get("code_complete"));
    const next_sequence = try parseNonNegativeInteger(value.object.get("next_sequence"));
    const settled_through_sequence = try parseNonNegativeInteger(
        value.object.get("settled_through_sequence"),
    );
    const api_duration_ms = try parseNonNegativeInteger(value.object.get("api_duration_ms"));
    const wall_duration_ms = try parseNonNegativeInteger(value.object.get("wall_duration_ms"));
    const total_cost = try parseNonNegativeNumber(value.object.get("total_cost"));
    const input_tokens = try parseNonNegativeInteger(value.object.get("input_tokens"));
    const output_tokens = try parseNonNegativeInteger(value.object.get("output_tokens"));
    const cache_read_tokens = try parseNonNegativeInteger(value.object.get("cache_read_tokens"));
    const cache_write_tokens = try parseNonNegativeInteger(value.object.get("cache_write_tokens"));
    const reasoning_tokens = if (legacy)
        null
    else blk: {
        const field = value.object.get("reasoning_tokens") orelse
            return error.InvalidUsageSnapshot;
        break :blk try parseOptionalNonNegativeInteger(field);
    };
    const request_count = if (legacy)
        null
    else blk: {
        const field = value.object.get("request_count") orelse
            return error.InvalidUsageSnapshot;
        break :blk try parseOptionalNonNegativeInteger(field);
    };
    const billable_web_search_calls = try parseNonNegativeInteger(
        value.object.get("billable_web_search_calls"),
    );
    const lines_added = try parseNonNegativeInteger(value.object.get("lines_added"));
    const lines_removed = try parseNonNegativeInteger(value.object.get("lines_removed"));
    const models_value = value.object.get("models") orelse return error.InvalidUsageSnapshot;
    const pending_value = value.object.get("pending") orelse return error.InvalidUsageSnapshot;
    if (models_value != .array or pending_value != .array) return error.InvalidUsageSnapshot;
    if (models_value.array.items.len > max_models or pending_value.array.items.len > max_pending_generations) {
        return error.UsageCapacityExceeded;
    }

    const models = try alloc.alloc(ModelAggregate, models_value.array.items.len);
    errdefer alloc.free(models);
    var model_count: usize = 0;
    errdefer for (models[0..model_count]) |*model| model.deinit(alloc);
    for (models_value.array.items, 0..) |model_value, index| {
        const expected_model_fields: usize = if (legacy) 8 else 10;
        if (model_value != .object or
            model_value.object.count() != expected_model_fields)
        {
            return error.InvalidUsageSnapshot;
        }
        const model_name = model_value.object.get("model") orelse return error.InvalidUsageSnapshot;
        if (model_name != .string) return error.InvalidUsageSnapshot;
        const first_sequence = try parseNonNegativeInteger(model_value.object.get("first_sequence"));
        const model_total_cost = try parseNonNegativeNumber(model_value.object.get("total_cost"));
        const model_input_tokens = try parseNonNegativeInteger(model_value.object.get("input_tokens"));
        const model_output_tokens = try parseNonNegativeInteger(model_value.object.get("output_tokens"));
        const model_cache_read_tokens = try parseNonNegativeInteger(model_value.object.get("cache_read_tokens"));
        const model_cache_write_tokens = try parseNonNegativeInteger(model_value.object.get("cache_write_tokens"));
        const model_reasoning_tokens = if (legacy)
            null
        else blk: {
            const field = model_value.object.get("reasoning_tokens") orelse
                return error.InvalidUsageSnapshot;
            break :blk try parseOptionalNonNegativeInteger(field);
        };
        const model_request_count = if (legacy)
            null
        else blk: {
            const field = model_value.object.get("request_count") orelse
                return error.InvalidUsageSnapshot;
            break :blk try parseOptionalNonNegativeInteger(field);
        };
        const model_web_search_calls = try parseNonNegativeInteger(
            model_value.object.get("billable_web_search_calls"),
        );
        models[index] = .{
            .model = try alloc.dupe(u8, model_name.string),
            .first_sequence = first_sequence,
            .total_cost = model_total_cost,
            .input_tokens = model_input_tokens,
            .output_tokens = model_output_tokens,
            .cache_read_tokens = model_cache_read_tokens,
            .cache_write_tokens = model_cache_write_tokens,
            .reasoning_tokens = model_reasoning_tokens,
            .request_count = model_request_count,
            .billable_web_search_calls = model_web_search_calls,
        };
        model_count += 1;
    }

    const pending = try alloc.alloc(PendingGeneration, pending_value.array.items.len);
    errdefer alloc.free(pending);
    var pending_count: usize = 0;
    errdefer for (pending[0..pending_count]) |*generation| generation.deinit(alloc);
    for (pending_value.array.items, 0..) |pending_entry, index| {
        const expected_pending_fields: usize = if (legacy) 4 else 5;
        if (pending_entry != .object or
            pending_entry.object.count() != expected_pending_fields)
        {
            return error.InvalidUsageSnapshot;
        }
        const id_value = pending_entry.object.get("id") orelse return error.InvalidUsageSnapshot;
        const origin_value = pending_entry.object.get("origin") orelse return error.InvalidUsageSnapshot;
        const team_value = pending_entry.object.get("team") orelse return error.InvalidUsageSnapshot;
        if (id_value != .string or origin_value != .string) return error.InvalidUsageSnapshot;
        const sequence = try parseNonNegativeInteger(pending_entry.object.get("sequence"));
        const observed_at_ms = if (legacy)
            null
        else blk: {
            const field = pending_entry.object.get("observed_at_ms") orelse
                return error.InvalidUsageSnapshot;
            break :blk try parseOptionalNonNegativeI64(field);
        };
        if (team_value != .null and team_value != .string) return error.InvalidUsageSnapshot;
        const id = try alloc.dupe(u8, id_value.string);
        errdefer alloc.free(id);
        const origin = try alloc.dupe(u8, origin_value.string);
        errdefer alloc.free(origin);
        const team = switch (team_value) {
            .null => null,
            .string => |text| try alloc.dupe(u8, text),
            else => unreachable,
        };
        errdefer if (team) |text| alloc.free(text);
        pending[index] = .{
            .id = id,
            .sequence = sequence,
            .origin = origin,
            .team = team,
            .observed_at_ms = observed_at_ms,
        };
        pending_count += 1;
    }

    const publication_backlog = if (legacy) blk: {
        break :blk try alloc.alloc(usage_report.GenerationFact, 0);
    } else blk: {
        const backlog_value = value.object.get("publication_backlog") orelse
            return error.InvalidUsageSnapshot;
        if (backlog_value != .array or
            backlog_value.array.items.len > max_publication_backlog)
        {
            return error.InvalidUsageSnapshot;
        }
        const backlog = try alloc.alloc(
            usage_report.GenerationFact,
            backlog_value.array.items.len,
        );
        errdefer alloc.free(backlog);
        var backlog_count: usize = 0;
        errdefer for (backlog[0..backlog_count]) |*fact| fact.deinit(alloc);
        for (backlog_value.array.items, 0..) |fact_value, index| {
            backlog[index] = generation_fact_codec.parse(
                alloc,
                fact_value,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidGenerationFact => return error.InvalidUsageSnapshot,
            };
            backlog_count += 1;
        }
        break :blk backlog;
    };
    errdefer {
        for (publication_backlog) |*fact| fact.deinit(alloc);
        if (publication_backlog.len > 0) alloc.free(publication_backlog);
    }

    const incidents = if (legacy) blk: {
        break :blk try alloc.alloc(usage_report.Incident, 0);
    } else blk: {
        const incidents_value = value.object.get("incidents") orelse
            return error.InvalidUsageSnapshot;
        if (incidents_value != .array or
            incidents_value.array.items.len > max_usage_incidents)
        {
            return error.InvalidUsageSnapshot;
        }
        const owned_incidents = try alloc.alloc(
            usage_report.Incident,
            incidents_value.array.items.len,
        );
        errdefer alloc.free(owned_incidents);
        for (incidents_value.array.items, 0..) |incident_value, index| {
            if (incident_value != .object or incident_value.object.count() != 2) {
                return error.InvalidUsageSnapshot;
            }
            const completeness_value = incident_value.object.get("completeness") orelse
                return error.InvalidUsageSnapshot;
            if (completeness_value != .string) return error.InvalidUsageSnapshot;
            const completeness = std.meta.stringToEnum(
                usage_report.Completeness,
                completeness_value.string,
            ) orelse return error.InvalidUsageSnapshot;
            owned_incidents[index] = .{
                .occurred_at_ms = try parseNonNegativeI64(
                    incident_value.object.get("occurred_at_ms"),
                ),
                .completeness = completeness,
            };
        }
        break :blk owned_incidents;
    };
    errdefer if (incidents.len > 0) alloc.free(incidents);

    const snapshot = Snapshot{
        .billing = billing,
        .api_duration_complete = api_complete,
        .wall_duration_complete = wall_complete,
        .code_complete = code_complete,
        .next_sequence = next_sequence,
        .settled_through_sequence = settled_through_sequence,
        .api_duration_ms = api_duration_ms,
        .wall_duration_ms = wall_duration_ms,
        .total_cost = total_cost,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = cache_read_tokens,
        .cache_write_tokens = cache_write_tokens,
        .reasoning_tokens = reasoning_tokens,
        .request_count = request_count,
        .billable_web_search_calls = billable_web_search_calls,
        .lines_added = lines_added,
        .lines_removed = lines_removed,
        .models = models,
        .pending = pending,
        .publication_backlog = publication_backlog,
        .incidents = incidents,
    };
    try validateSnapshot(snapshot);
    return snapshot;
}

fn parseBool(value: ?std.json.Value) !bool {
    const actual = value orelse return error.InvalidUsageSnapshot;
    if (actual != .bool) return error.InvalidUsageSnapshot;
    return actual.bool;
}

fn writeOptionalU64(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn reconciliationThreadMain(
    usage: *Usage,
    alloc: Allocator,
    api_key: []u8,
    provider: generation_usage.Provider,
) void {
    defer secret.zeroAndFree(alloc, api_key);
    defer usage.reconciliation_done.store(true, .seq_cst);
    var observed_epoch = usage.reconciliation_work_epoch.load(.seq_cst);
    while (!usage.reconciliation_cancel.load(.seq_cst)) {
        reconcilePendingBlocking(
            usage,
            alloc,
            api_key,
            &usage.reconciliation_cancel,
            provider,
            30,
        );
        if (usage.reconciliation_cancel.load(.seq_cst)) return;
        const current_epoch = usage.reconciliation_work_epoch.load(.seq_cst);
        if (current_epoch != observed_epoch) {
            observed_epoch = current_epoch;
            continue;
        }
        usage.reconciliation_done.store(true, .seq_cst);
        if (usage.reconciliation_cancel.load(.seq_cst)) return;
        const confirmed_epoch = usage.reconciliation_work_epoch.load(.seq_cst);
        if (confirmed_epoch == observed_epoch) return;
        usage.reconciliation_done.store(false, .seq_cst);
        observed_epoch = confirmed_epoch;
    }
}

fn reconciliationKeyDigest(api_key: []const u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(api_key, &digest, .{});
    return digest;
}

fn reconcilePendingBlocking(
    usage: *Usage,
    alloc: Allocator,
    api_key: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    provider: generation_usage.Provider,
    max_attempts: usize,
) void {
    if (api_key.len == 0 or cancel_flag.load(.seq_cst)) return;
    var attempt: usize = 0;
    while (attempt < max_attempts and !cancel_flag.load(.seq_cst)) : (attempt += 1) {
        var current = usage.snapshot(alloc) catch |err| {
            debug_trace.logf(
                "session",
                "usage reconciliation snapshot failed reason={s}",
                .{@errorName(err)},
            );
            usage.markBillingIncomplete();
            return;
        };
        defer current.deinit(alloc);
        if (current.pending.len == 0) return;

        var retry_needed = false;
        for (current.pending) |pending| {
            var outcome = provider.lookup(alloc, .{
                .credential = api_key,
                .tenant = pending.team,
                .origin = pending.origin,
                .generation_id = pending.id,
                .cancel_flag = cancel_flag,
            }) catch |err| {
                if (err == error.Cancelled) return;
                debug_trace.logf(
                    "session",
                    "usage generation lookup failed attempt={d} reason={s}",
                    .{ attempt + 1, @errorName(err) },
                );
                retry_needed = true;
                continue;
            };
            defer outcome.deinit(alloc);
            switch (outcome) {
                .retry => {
                    debug_trace.logf(
                        "session",
                        "usage generation lookup retry attempt={d}",
                        .{attempt + 1},
                    );
                    retry_needed = true;
                    continue;
                },
                .preserve_pending => {
                    debug_trace.logf(
                        "session",
                        "usage generation lookup preserved attempt={d}",
                        .{attempt + 1},
                    );
                    continue;
                },
                .reject => {
                    debug_trace.logf(
                        "session",
                        "usage generation lookup rejected attempt={d}",
                        .{attempt + 1},
                    );
                    usage.rejectPendingGeneration(alloc, pending.id);
                },
                .found => |record| {
                    usage.applyGeneration(alloc, record) catch |err| {
                        debug_trace.logf(
                            "session",
                            "usage generation apply failed reason={s}",
                            .{@errorName(err)},
                        );
                        usage.markBillingIncomplete();
                    };
                },
            }
        }
        if (!retry_needed) return;
        if (attempt + 1 < max_attempts and
            !waitForReconciliationRetry(cancel_flag))
        {
            return;
        }
    }
}

fn waitForReconciliationRetry(cancel_flag: *std.atomic.Value(bool)) bool {
    const slices: usize = 200;
    for (0..slices) |_| {
        if (cancel_flag.load(.seq_cst)) return false;
        io_mod.getIo().sleep(.fromMilliseconds(5), .awake) catch |err| {
            debug_trace.logf(
                "session",
                "usage reconciliation retry wait failed reason={s}",
                .{@errorName(err)},
            );
            return false;
        };
    }
    return !cancel_flag.load(.seq_cst);
}

fn addRecordToModel(model: *ModelAggregate, record: GenerationRecord, sequence: u64) !void {
    const total_cost = model.total_cost + record.total_cost;
    if (!std.math.isFinite(total_cost)) return error.UsageOverflow;
    const input_tokens = std.math.add(u64, model.input_tokens, record.input_tokens) catch
        return error.UsageOverflow;
    const output_tokens = std.math.add(u64, model.output_tokens, record.output_tokens) catch
        return error.UsageOverflow;
    const cache_read_tokens = std.math.add(u64, model.cache_read_tokens, record.cache_read_tokens) catch
        return error.UsageOverflow;
    const cache_write_tokens = std.math.add(u64, model.cache_write_tokens, record.cache_write_tokens) catch
        return error.UsageOverflow;
    const reasoning_tokens = try addOptionalCounter(
        model.reasoning_tokens,
        record.reasoning_tokens,
    );
    const request_count = if (model.request_count) |requests|
        std.math.add(u64, requests, 1) catch return error.UsageOverflow
    else
        null;
    const web_search_calls = std.math.add(
        u64,
        model.billable_web_search_calls,
        record.billable_web_search_calls,
    ) catch return error.UsageOverflow;
    model.total_cost = total_cost;
    model.input_tokens = input_tokens;
    model.output_tokens = output_tokens;
    model.cache_read_tokens = cache_read_tokens;
    model.cache_write_tokens = cache_write_tokens;
    model.reasoning_tokens = reasoning_tokens;
    model.request_count = request_count;
    model.billable_web_search_calls = web_search_calls;
    model.first_sequence = @min(model.first_sequence, sequence);
}

fn validateGenerationRecord(record: GenerationRecord) !void {
    usage_report.validateFact(generationFactBorrowed(record)) catch {
        return error.InvalidGenerationRecord;
    };
}

fn generationFactBorrowed(record: GenerationRecord) usage_report.GenerationFact {
    return .{
        .id = @constCast(record.id),
        .created_at_ms = record.created_at_ms,
        .model = @constCast(record.model),
        .input_tokens = record.input_tokens,
        .output_tokens = record.output_tokens,
        .cache_read_tokens = record.cache_read_tokens,
        .cache_write_tokens = record.cache_write_tokens,
        .reasoning_tokens = record.reasoning_tokens,
        .billable_web_search_calls = record.billable_web_search_calls,
        .total_cost = record.total_cost,
    };
}

fn generationRecordBorrowed(
    fact: usage_report.GenerationFact,
) GenerationRecord {
    return .{
        .id = fact.id,
        .created_at_ms = fact.created_at_ms,
        .model = fact.model,
        .total_cost = fact.total_cost,
        .input_tokens = fact.input_tokens,
        .output_tokens = fact.output_tokens,
        .cache_read_tokens = fact.cache_read_tokens,
        .cache_write_tokens = fact.cache_write_tokens,
        .reasoning_tokens = fact.reasoning_tokens,
        .billable_web_search_calls = fact.billable_web_search_calls,
    };
}

fn addOptionalCounter(first: ?u64, second: ?u64) error{UsageOverflow}!?u64 {
    if (first == null or second == null) return null;
    return std.math.add(u64, first.?, second.?) catch error.UsageOverflow;
}

pub fn dupeSnapshotOwned(alloc: Allocator, source: Snapshot) !Snapshot {
    const models = try alloc.alloc(ModelAggregate, source.models.len);
    errdefer alloc.free(models);
    var copied_models: usize = 0;
    errdefer for (models[0..copied_models]) |*model| model.deinit(alloc);
    for (source.models, 0..) |model, index| {
        models[index] = try model.dupe(alloc);
        copied_models += 1;
    }

    const pending = try alloc.alloc(PendingGeneration, source.pending.len);
    errdefer alloc.free(pending);
    var copied_pending: usize = 0;
    errdefer for (pending[0..copied_pending]) |*generation| generation.deinit(alloc);
    for (source.pending, 0..) |generation, index| {
        pending[index] = try generation.dupe(alloc);
        copied_pending += 1;
    }

    const publication_backlog = try alloc.alloc(
        usage_report.GenerationFact,
        source.publication_backlog.len,
    );
    errdefer alloc.free(publication_backlog);
    var copied_publications: usize = 0;
    errdefer for (publication_backlog[0..copied_publications]) |*fact| {
        fact.deinit(alloc);
    };
    for (source.publication_backlog, 0..) |fact, index| {
        publication_backlog[index] = try fact.dupe(alloc);
        copied_publications += 1;
    }

    const incidents = try alloc.dupe(usage_report.Incident, source.incidents);
    errdefer alloc.free(incidents);

    return .{
        .billing = source.billing,
        .api_duration_complete = source.api_duration_complete,
        .wall_duration_complete = source.wall_duration_complete,
        .code_complete = source.code_complete,
        .next_sequence = source.next_sequence,
        .settled_through_sequence = source.settled_through_sequence,
        .api_duration_ms = source.api_duration_ms,
        .wall_duration_ms = source.wall_duration_ms,
        .total_cost = source.total_cost,
        .input_tokens = source.input_tokens,
        .output_tokens = source.output_tokens,
        .cache_read_tokens = source.cache_read_tokens,
        .cache_write_tokens = source.cache_write_tokens,
        .reasoning_tokens = source.reasoning_tokens,
        .request_count = source.request_count,
        .billable_web_search_calls = source.billable_web_search_calls,
        .lines_added = source.lines_added,
        .lines_removed = source.lines_removed,
        .models = models,
        .pending = pending,
        .publication_backlog = publication_backlog,
        .incidents = incidents,
    };
}

fn validateGenerationId(id: []const u8) !void {
    if (!types.validGatewayGenerationId(id)) return error.InvalidGenerationId;
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > max_model_bytes) {
        return error.InvalidModel;
    }
    for (model) |char| {
        if (char < 0x21 or char > 0x7e) return error.InvalidModel;
    }
}

fn validateOrigin(origin: []const u8) !void {
    if (origin.len == 0 or origin.len > max_origin_bytes) {
        return error.InvalidGatewayOrigin;
    }
    for (origin) |char| {
        if (char < 0x21 or char > 0x7e) return error.InvalidGatewayOrigin;
    }
}

fn validateTeam(team: []const u8) !void {
    if (team.len == 0 or team.len > max_team_bytes) {
        return error.InvalidGatewayTeam;
    }
    for (team) |char| {
        if (char < 0x21 or char > 0x7e) return error.InvalidGatewayTeam;
    }
}

fn parseNonNegativeNumber(value: ?std.json.Value) !f64 {
    const actual = value orelse return error.InvalidGenerationRecord;
    const number: f64 = switch (actual) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch
            return error.InvalidGenerationRecord,
        else => return error.InvalidGenerationRecord,
    };
    if (!std.math.isFinite(number) or number < 0) return error.InvalidGenerationRecord;
    return number;
}

fn parseNonNegativeInteger(value: ?std.json.Value) !u64 {
    const actual = value orelse return error.InvalidGenerationRecord;
    return switch (actual) {
        .integer => |integer| if (integer >= 0)
            std.math.cast(u64, integer) orelse error.InvalidGenerationRecord
        else
            error.InvalidGenerationRecord,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch
            error.InvalidGenerationRecord,
        else => error.InvalidGenerationRecord,
    };
}

fn parseOptionalNonNegativeInteger(value: ?std.json.Value) !?u64 {
    const actual = value orelse return null;
    if (actual == .null) return null;
    return try parseNonNegativeInteger(actual);
}

fn parseNonNegativeI64(value: ?std.json.Value) !i64 {
    const parsed = try parseNonNegativeInteger(value);
    return std.math.cast(i64, parsed) orelse error.InvalidGenerationRecord;
}

fn parseOptionalNonNegativeI64(value: ?std.json.Value) !?i64 {
    const actual = value orelse return null;
    if (actual == .null) return null;
    return try parseNonNegativeI64(actual);
}

fn optionalStringsEqual(first: ?[]const u8, second: ?[]const u8) bool {
    if (first == null or second == null) return first == null and second == null;
    return std.mem.eql(u8, first.?, second.?);
}

test "usage snapshot JSON round trips" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeSnapshot(&encoded.writer, snapshot);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
    defer parsed.deinit();
    var decoded = try parseSnapshotValue(alloc, parsed.value);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(snapshot.billing, decoded.billing);
    try std.testing.expectEqual(snapshot.wall_duration_ms, decoded.wall_duration_ms);
}

test "profile recovery hint follows unresolved durable usage" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    var settled = try usage.snapshot(alloc);
    defer settled.deinit(alloc);
    try std.testing.expect(!needsProfileRecovery(settled));

    const sequence = try usage.reserveInvocation();
    var active = try usage.snapshot(alloc);
    defer active.deinit(alloc);
    try std.testing.expect(needsProfileRecovery(active));

    usage.finishInvocation(sequence, 1, .unbilled);
    var finished = try usage.snapshot(alloc);
    defer finished.deinit(alloc);
    try std.testing.expect(!needsProfileRecovery(finished));
}

test "durable incident publication retires profile recovery" {
    const alloc = std.testing.allocator;
    const CheckpointProbe = struct {
        calls: usize = 0,
        recovery_pending: bool = true,

        fn persist(raw: *anyopaque, snapshot: Snapshot) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.recovery_pending = needsProfileRecovery(snapshot);
        }
    };
    const PublicationProbe = struct {
        fail: bool = true,
        incidents: usize = 0,

        fn publish(
            raw: *anyopaque,
            event: usage_report.ProfileEvent,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .incident => {},
                .pending, .generation => return,
            }
            if (self.fail) return error.InjectedPublicationFailure;
            self.incidents += 1;
        }
    };

    var checkpoint = CheckpointProbe{};
    var publication = PublicationProbe{};
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configureCheckpointSink(.{
        .context = &checkpoint,
        .allocator = alloc,
        .persist = CheckpointProbe.persist,
    });
    usage.markBillingIncomplete();
    usage.configurePublicationSink(.{
        .context = &publication,
        .allocator = alloc,
        .publish = PublicationProbe.publish,
    });

    var unresolved = try usage.snapshot(alloc);
    defer unresolved.deinit(alloc);
    try std.testing.expect(needsProfileRecovery(unresolved));
    try std.testing.expectEqual(@as(usize, 1), unresolved.incidents.len);

    usage.configurePublicationSink(null);
    publication.fail = false;
    usage.configurePublicationSink(.{
        .context = &publication,
        .allocator = alloc,
        .publish = PublicationProbe.publish,
    });

    var durable = try usage.snapshot(alloc);
    defer durable.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, durable.billing);
    try std.testing.expectEqual(@as(usize, 0), durable.incidents.len);
    try std.testing.expect(!needsProfileRecovery(durable));
    try std.testing.expectEqual(@as(usize, 1), publication.incidents);
    try std.testing.expect(checkpoint.calls > 0);
    try std.testing.expect(!checkpoint.recovery_pending);
}

test "profile publication failure preserves session totals and retries backlog" {
    const alloc = std.testing.allocator;
    const PublicationProbe = struct {
        fail: bool = true,
        calls: usize = 0,

        fn publish(
            raw: *anyopaque,
            _: usage_report.ProfileEvent,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.fail) return error.InjectedPublicationFailure;
        }
    };

    var probe = PublicationProbe{};
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configurePublicationSink(.{
        .context = &probe,
        .allocator = alloc,
        .publish = PublicationProbe.publish,
    });

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 1000,
        .model = "provider/model",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 0,
    });

    var failed = try usage.snapshot(alloc);
    defer failed.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, failed.billing);
    try std.testing.expectEqual(@as(u64, 12), failed.input_tokens + failed.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), failed.publication_backlog.len);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);

    probe.fail = false;
    usage.configurePublicationSink(.{
        .context = &probe,
        .allocator = alloc,
        .publish = PublicationProbe.publish,
    });
    var retried = try usage.snapshot(alloc);
    defer retried.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), retried.publication_backlog.len);
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
}

test "restored publication backlog settles the pending generation exactly" {
    const alloc = std.testing.allocator;
    const Checkpoint = struct {
        fn persist(_: *anyopaque, _: Snapshot) !void {}
    };
    const PublicationProbe = struct {
        fail_generation: bool = true,
        successful_generations: usize = 0,

        fn publish(
            raw: *anyopaque,
            event: usage_report.ProfileEvent,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .generation => {
                    if (self.fail_generation) return error.InjectedPublicationFailure;
                    self.successful_generations += 1;
                },
                .pending, .incident => {},
            }
        }
    };

    var checkpoint_context: u8 = 0;
    var probe = PublicationProbe{};
    var source = Usage.initFresh();
    defer source.deinit(alloc);
    source.configureCheckpointSink(.{
        .context = &checkpoint_context,
        .allocator = alloc,
        .persist = Checkpoint.persist,
    });
    source.configurePublicationSink(.{
        .context = &probe,
        .allocator = alloc,
        .publish = PublicationProbe.publish,
    });

    const sequence = try source.reserveInvocationDurably();
    try source.finishObservedInvocationDurably(
        alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try source.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 1000,
        .model = "provider/model",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 2,
    });

    var saved = try source.snapshot(alloc);
    defer saved.deinit(alloc);
    try std.testing.expectEqual(Availability.pending, saved.billing);
    try std.testing.expectEqual(@as(usize, 1), saved.pending.len);
    try std.testing.expectEqual(@as(usize, 1), saved.publication_backlog.len);
    try std.testing.expectEqual(@as(u64, 0), saved.input_tokens);
    source.configurePublicationSink(null);

    probe.fail_generation = false;
    var resumed = Usage.initFresh();
    defer resumed.deinit(alloc);
    resumed.configurePublicationSink(.{
        .context = &probe,
        .allocator = alloc,
        .publish = PublicationProbe.publish,
    });
    try resumed.restore(alloc, saved, 1);

    var settled = try resumed.snapshot(alloc);
    defer settled.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, settled.billing);
    try std.testing.expectEqual(@as(usize, 0), settled.pending.len);
    try std.testing.expectEqual(@as(usize, 0), settled.publication_backlog.len);
    try std.testing.expectEqual(@as(u64, 10), settled.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), settled.output_tokens);
    try std.testing.expectEqual(@as(u64, 2), settled.billable_web_search_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.successful_generations);
}

test "no-checkpoint usage drains a transient publication failure" {
    const alloc = std.testing.allocator;
    const PublicationProbe = struct {
        generation_failures: usize = 1,
        successful_generations: usize = 0,
        published_search_calls: u64 = 0,

        fn publish(
            raw: *anyopaque,
            event: usage_report.ProfileEvent,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .generation => |fact| {
                    if (self.generation_failures > 0) {
                        self.generation_failures -= 1;
                        return error.InjectedPublicationFailure;
                    }
                    self.successful_generations += 1;
                    self.published_search_calls = fact.billable_web_search_calls;
                },
                .pending, .incident => {},
            }
        }
    };

    var probe = PublicationProbe{};
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configurePublicationSink(.{
        .context = &probe,
        .allocator = alloc,
        .publish = PublicationProbe.publish,
    });

    const sequence = try usage.reserveInvocationDurably();
    try usage.finishObservedInvocationDurably(
        alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 1000,
        .model = "provider/model",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 3,
    });

    var settled = try usage.snapshot(alloc);
    defer settled.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, settled.billing);
    try std.testing.expectEqual(@as(usize, 0), settled.pending.len);
    try std.testing.expectEqual(@as(usize, 0), settled.publication_backlog.len);
    try std.testing.expectEqual(@as(usize, 1), probe.successful_generations);
    try std.testing.expectEqual(@as(u64, 3), probe.published_search_calls);
}

test "missing profile publication sink keeps the durable pending bridge" {
    const alloc = std.testing.allocator;
    const Checkpoint = struct {
        calls: usize = 0,

        fn persist(raw: *anyopaque, _: Snapshot) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    var checkpoint = Checkpoint{};
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configureCheckpointSink(.{
        .context = &checkpoint,
        .allocator = alloc,
        .persist = Checkpoint.persist,
    });

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 1000,
        .model = "provider/model",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 0,
    });

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.pending, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.publication_backlog.len);
    try std.testing.expectEqual(@as(u64, 0), snapshot.input_tokens);
    try std.testing.expectEqualStrings(
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        snapshot.publication_backlog[0].id,
    );
    try std.testing.expectEqual(@as(usize, 1), checkpoint.calls);
}

test "session report preserves usage-first totals and session activity" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    try usage.recordCommittedLines(3, 1);
    var report = try usage.reportSnapshot(alloc);
    defer report.deinit(alloc);
    try std.testing.expectEqual(usage_report.Scope.session, report.scope);
    try std.testing.expectEqual(@as(u64, 0), report.totals.?.total_tokens);
    try std.testing.expectEqual(@as(u64, 3), report.session_activity.?.lines_added);
}

test "incident overflow retains the newest incomplete boundary" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const newest_at_ms: i64 = 10_000;
    for (0..max_usage_incidents) |index| {
        usage.recordIncidentUnlocked(
            .incomplete,
            newest_at_ms - @as(i64, @intCast(index)),
        );
    }
    usage.recordIncidentUnlocked(.incomplete, 100);

    try std.testing.expectEqual(@as(usize, 1), usage.incident_count);
    try std.testing.expectEqual(
        newest_at_ms,
        usage.incidents[0].occurred_at_ms,
    );
    try std.testing.expectEqual(
        usage_report.Completeness.incomplete,
        usage.incidents[0].completeness,
    );
}

test "usage snapshot parsing releases every partial allocation" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const resolved_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        resolved_sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "anthropic/claude-opus-4.8",
        .total_cost = 0.1,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .billable_web_search_calls = 0,
    });
    const pending_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        pending_sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        "https://ai-gateway.vercel.sh",
        "team_1",
    );

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeSnapshot(&encoded.writer, snapshot);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded.written(),
        .{},
    );
    defer parsed.deinit();

    var probe = std.testing.FailingAllocator.init(alloc, .{});
    var decoded = try parseSnapshotValue(probe.allocator(), parsed.value);
    decoded.deinit(probe.allocator());
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        if (parseSnapshotValue(failing.allocator(), parsed.value)) |value| {
            var owned = value;
            owned.deinit(failing.allocator());
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "fresh usage aggregates authoritative generations in invocation order" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const first_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        first_sequence,
        125,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        "team_1",
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "anthropic/claude-opus-4.8",
        .total_cost = 0.00123,
        .input_tokens = 100,
        .output_tokens = 50,
        .cache_read_tokens = 20,
        .cache_write_tokens = 10,
        .billable_web_search_calls = 1,
    });

    const second_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        second_sequence,
        75,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        "https://ai-gateway.vercel.sh",
        "team_1",
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        .model = "openai/gpt-5.5",
        .total_cost = 0.004,
        .input_tokens = 200,
        .output_tokens = 25,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .billable_web_search_calls = 0,
    });

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00523), snapshot.total_cost, 1e-12);
    try std.testing.expectEqual(@as(u64, 200), snapshot.api_duration_ms);
    try std.testing.expectEqual(@as(u64, 300), snapshot.input_tokens);
    try std.testing.expectEqual(@as(u64, 75), snapshot.output_tokens);
    try std.testing.expectEqual(@as(u64, 20), snapshot.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 10), snapshot.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 1), snapshot.billable_web_search_calls);
    try std.testing.expectEqual(@as(usize, 2), snapshot.models.len);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.8", snapshot.models[0].model);
    try std.testing.expectEqual(first_sequence, snapshot.models[0].first_sequence);
    try std.testing.expectEqualStrings("openai/gpt-5.5", snapshot.models[1].model);
    try std.testing.expectEqual(second_sequence, snapshot.models[1].first_sequence);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending.len);

    snapshot.input_tokens += 1;
    try std.testing.expectError(error.InvalidUsageSnapshot, validateSnapshot(snapshot));
    snapshot.input_tokens -= 1;
    snapshot.total_cost += 1;
    try std.testing.expectError(error.InvalidUsageSnapshot, validateSnapshot(snapshot));
}

test "usage deduplicates terminal and generation callbacks" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        10,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        10,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    const record = GenerationRecord{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "anthropic/claude-opus-4.8",
        .total_cost = 1.5,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 3,
        .cache_write_tokens = 1,
        .billable_web_search_calls = 0,
    };
    try usage.applyGeneration(alloc, record);
    try usage.applyGeneration(alloc, record);

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 10), snapshot.api_duration_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), snapshot.total_cost, 1e-12);
    try std.testing.expectEqual(@as(u64, 10), snapshot.input_tokens);
    try std.testing.expectEqual(@as(usize, 1), snapshot.models.len);
}

test "usage deduplicates callbacks after the durable settlement boundary" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        10,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "anthropic/claude-opus-4.8",
        .total_cost = 1.5,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 3,
        .cache_write_tokens = 1,
        .billable_web_search_calls = 0,
    });

    var persisted = try usage.snapshot(alloc);
    defer persisted.deinit(alloc);
    usage.markClean(persisted);

    usage.finishInvocation(sequence, 10, .observed_generation);
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        10,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );

    var current = try usage.snapshot(alloc);
    defer current.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 10), current.api_duration_ms);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), current.total_cost, 1e-12);
    try std.testing.expectEqual(@as(usize, 0), current.pending.len);
}

test "model aggregates remain ordered by invocation when reconciliation finishes out of order" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const first_sequence = try usage.reserveInvocation();
    const second_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        first_sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.finishObservedInvocation(
        alloc,
        second_sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        "https://ai-gateway.vercel.sh",
        null,
    );

    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        .model = "openai/gpt-5.5",
        .total_cost = 1,
        .input_tokens = 1,
        .output_tokens = 1,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .billable_web_search_calls = 0,
    });
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "anthropic/claude-opus-4.8",
        .total_cost = 1,
        .input_tokens = 1,
        .output_tokens = 1,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .billable_web_search_calls = 0,
    });

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.8", snapshot.models[0].model);
    try std.testing.expectEqualStrings("openai/gpt-5.5", snapshot.models[1].model);
}

test "active invocation does not render partial usage as complete" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const sequence = try usage.reserveInvocation();
    var active = try usage.snapshot(alloc);
    defer active.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, active.billing);
    try std.testing.expect(!active.api_duration_complete);

    usage.finishInvocation(sequence, 10, .unbilled);
    var finished = try usage.snapshot(alloc);
    defer finished.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, finished.billing);
    try std.testing.expect(finished.api_duration_complete);
}

test "active invocation dominates separate pending and publication state" {
    const alloc = std.testing.allocator;
    const Checkpoint = struct {
        fn persist(_: *anyopaque, _: Snapshot) !void {}
    };
    var checkpoint_context: u8 = 0;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const active_sequence = try usage.reserveInvocation();
    const observed_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        observed_sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );

    var pending = try usage.snapshot(alloc);
    defer pending.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, pending.billing);
    try std.testing.expectEqual(@as(u64, 0), pending.settled_through_sequence);
    try std.testing.expectEqual(@as(usize, 1), pending.pending.len);

    usage.configureCheckpointSink(.{
        .context = &checkpoint_context,
        .allocator = alloc,
        .persist = Checkpoint.persist,
    });
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 1000,
        .model = "provider/model",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 0,
    });

    var backlogged = try usage.snapshot(alloc);
    defer backlogged.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, backlogged.billing);
    try std.testing.expectEqual(@as(u64, 0), backlogged.settled_through_sequence);
    try std.testing.expectEqual(@as(usize, 1), backlogged.pending.len);
    try std.testing.expectEqual(
        @as(usize, 1),
        backlogged.publication_backlog.len,
    );

    usage.finishInvocation(active_sequence, 1, .unbilled);
    var settled = try usage.snapshot(alloc);
    defer settled.deinit(alloc);
    try std.testing.expectEqual(Availability.pending, settled.billing);
    try std.testing.expectEqual(@as(u64, 2), settled.settled_through_sequence);
}

test "active invocation capacity fails before Gateway admission" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    var observations: [max_active_invocations]GatewayObservation = undefined;

    for (&observations) |*observation| {
        observation.* = try GatewayObservation.begin(&usage);
    }
    try std.testing.expectError(
        error.UsageCapacityExceeded,
        GatewayObservation.begin(&usage),
    );

    for (observations) |observation| try observation.fail(.unbilled);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
}

test "generation allocation failure marks billing incomplete before snapshot" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        usage.finishObservedInvocation(
            failing.allocator(),
            sequence,
            1,
            .observed_generation,
            "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
            "https://ai-gateway.vercel.sh",
            null,
        ),
    );
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending.len);
}

test "concurrent invocation completion and snapshots stay internally consistent" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    var start = std.atomic.Value(bool).init(false);
    var reservation_failed = std.atomic.Value(bool).init(false);
    const Context = struct {
        ledger: *Usage,
        gate: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(ctx: *@This()) void {
            while (!ctx.gate.load(.seq_cst)) std.atomic.spinLoopHint();
            const sequence = ctx.ledger.reserveInvocation() catch {
                ctx.failed.store(true, .seq_cst);
                return;
            };
            ctx.ledger.finishInvocation(sequence, 1, .unbilled);
        }
    };
    var contexts: [8]Context = undefined;
    var threads: [contexts.len]std.Thread = undefined;
    for (&contexts, &threads) |*context, *thread| {
        context.* = .{
            .ledger = &usage,
            .gate = &start,
            .failed = &reservation_failed,
        };
        thread.* = try std.Thread.spawn(.{}, Context.run, .{context});
    }

    start.store(true, .seq_cst);
    for (0..8) |_| {
        var current = try usage.snapshot(alloc);
        defer current.deinit(alloc);
        if (current.billing == .complete) {
            try std.testing.expect(current.api_duration_complete);
        }
    }
    for (threads) |thread| thread.join();
    try std.testing.expect(!reservation_failed.load(.seq_cst));

    var finished = try usage.snapshot(alloc);
    defer finished.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, finished.billing);
    try std.testing.expect(finished.api_duration_complete);
    try std.testing.expectEqual(@as(u64, contexts.len), finished.api_duration_ms);
}

test "pending and ambiguous generation states remain honest" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const pending_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        pending_sequence,
        8,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );

    var pending = try usage.snapshot(alloc);
    defer pending.deinit(alloc);
    try std.testing.expectEqual(Availability.pending, pending.billing);
    try std.testing.expectEqual(@as(usize, 1), pending.pending.len);

    const ambiguous_sequence = try usage.reserveInvocation();
    usage.finishInvocation(ambiguous_sequence, 12, .ambiguous_delivery);

    var incomplete = try usage.snapshot(alloc);
    defer incomplete.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, incomplete.billing);
    try std.testing.expectEqual(@as(u64, 20), incomplete.api_duration_ms);
}

test "successful response without generation identity marks billing incomplete" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const observation = try GatewayObservation.begin(&usage);
    try observation.complete(
        alloc,
        .ok,
        .{},
        "https://ai-gateway.vercel.sh",
        null,
    );

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending.len);
}

const TestGenerationUsageProvider = struct {
    outcome: enum {
        found,
        retry,
        preserve_pending,
        reject,
        unavailable,
        cancelled,
    },
    calls: usize = 0,
    saw_expected_input: bool = false,

    fn lookup(
        raw_context: ?*anyopaque,
        alloc: Allocator,
        input: generation_usage.LookupInput,
    ) generation_usage.LookupError!generation_usage.LookupOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw_context.?));
        self.calls += 1;
        self.saw_expected_input =
            std.mem.eql(u8, input.credential, "credential") and
            std.mem.eql(
                u8,
                input.generation_id,
                "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
            ) and
            std.mem.eql(u8, input.origin, "https://provider.example");
        return switch (self.outcome) {
            .found => blk: {
                const id = try alloc.dupe(u8, input.generation_id);
                errdefer alloc.free(id);
                const model = try alloc.dupe(u8, "provider/model");
                break :blk .{ .found = .{
                    .id = id,
                    .model = model,
                    .total_cost = 0.25,
                    .input_tokens = 10,
                    .output_tokens = 2,
                    .cache_read_tokens = 3,
                    .cache_write_tokens = 1,
                    .billable_web_search_calls = 0,
                } };
            },
            .retry => .retry,
            .preserve_pending => .preserve_pending,
            .reject => .reject,
            .unavailable => error.Unavailable,
            .cancelled => error.Cancelled,
        };
    }

    fn provider(self: *@This()) generation_usage.Provider {
        return .{
            .context = self,
            .lookup_fn = lookup,
        };
    }
};

test "usage restore and reset retain the injected generation provider" {
    const alloc = std.testing.allocator;
    var fake = TestGenerationUsageProvider{ .outcome = .found };
    const provider = fake.provider();
    var usage = Usage.initFreshWithProvider(provider);
    defer usage.deinit(alloc);

    var saved = try usage.snapshot(alloc);
    defer saved.deinit(alloc);

    usage.resetFresh(alloc);
    try std.testing.expect(
        usage.generation_usage_provider.lookup_fn == provider.lookup_fn,
    );
    try usage.restore(alloc, saved, 1);
    try std.testing.expect(
        usage.generation_usage_provider.lookup_fn == provider.lookup_fn,
    );
    usage.resetLegacy(alloc);
    try std.testing.expect(
        usage.generation_usage_provider.lookup_fn == provider.lookup_fn,
    );
}

test "reconciliation settles usage through the injected provider" {
    const alloc = std.testing.allocator;
    var fake = TestGenerationUsageProvider{ .outcome = .found };
    var usage = Usage.initFreshWithProvider(fake.provider());
    defer usage.deinit(alloc);

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        5,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://provider.example",
        null,
    );
    var cancel = std.atomic.Value(bool).init(false);
    const provider = usage.generation_usage_provider;
    reconcilePendingBlocking(
        &usage,
        alloc,
        "credential",
        &cancel,
        provider,
        1,
    );

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(fake.saw_expected_input);
    try std.testing.expectEqual(Availability.complete, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), snapshot.total_cost, 1e-12);
    try std.testing.expectEqual(@as(u64, 10), snapshot.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), snapshot.output_tokens);
}

test "terminal Gateway billing settles the durable observation immediately" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    const observation = try GatewayObservation.begin(&usage);
    try observation.complete(
        alloc,
        .ok,
        .{
            .generation_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
            .billing = .{
                .created_at_ms = 100,
                .model = "provider/model",
                .total_cost = 0.0123,
                .input_tokens = 130,
                .output_tokens = 25,
                .cache_read_tokens = 20,
                .cache_write_tokens = 10,
                .reasoning_tokens = 5,
                .billable_web_search_calls = 2,
            },
        },
        "https://ai-gateway.vercel.sh",
        null,
    );

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 0), snapshot.pending.len);
    try std.testing.expectEqual(@as(u64, 130), snapshot.input_tokens);
    try std.testing.expectEqual(@as(u64, 25), snapshot.output_tokens);
    try std.testing.expectEqual(@as(u64, 2), snapshot.billable_web_search_calls);
}

test "successful retry after ambiguous delivery retains known generation" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const observation = try GatewayObservation.begin(&usage);
    try observation.complete(
        alloc,
        .ok,
        .{
            .generation_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
            .delivery_ambiguous = true,
        },
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "anthropic/claude-opus-4.8",
        .total_cost = 0.25,
        .input_tokens = 10,
        .output_tokens = 2,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .billable_web_search_calls = 0,
    });

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), snapshot.models.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), snapshot.total_cost, 1e-12);
}

test "wall duration resumes from the session creation time" {
    const alloc = std.testing.allocator;
    var first = Usage.initFresh();
    defer first.deinit(alloc);
    var saved = try first.snapshot(alloc);
    defer saved.deinit(alloc);
    const session_started_at_ms = io_mod.milliTimestamp() - 500;

    var resumed = Usage.initLegacy();
    defer resumed.deinit(alloc);
    try resumed.restore(alloc, saved, session_started_at_ms);
    var current = try resumed.snapshot(alloc);
    defer current.deinit(alloc);
    try std.testing.expect(current.wall_duration_complete);
    try std.testing.expect(current.wall_duration_ms >= 500);
    try std.testing.expect(!resumed.isDirty());
}

test "legacy sessions retain exact wall duration from durable creation" {
    const alloc = std.testing.allocator;
    var usage = Usage.initLegacy();
    defer usage.deinit(alloc);
    usage.restoreLegacyWallDuration(io_mod.milliTimestamp() - 500);

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.wall_duration_complete);
    try std.testing.expect(snapshot.wall_duration_ms >= 500);
    try std.testing.expectEqual(Availability.legacy, snapshot.billing);
}

test "mark clean preserves mutations newer than the persisted snapshot" {
    const alloc = std.testing.allocator;
    var usage = Usage.initLegacy();
    defer usage.deinit(alloc);

    try usage.recordCommittedLines(3, 1);
    var persisted = try usage.snapshot(alloc);
    defer persisted.deinit(alloc);
    try usage.recordCommittedLines(2, 4);

    usage.markClean(persisted);
    try std.testing.expect(usage.isDirty());

    var latest = try usage.snapshot(alloc);
    defer latest.deinit(alloc);
    usage.markClean(latest);
    try std.testing.expect(!usage.isDirty());
}

test "usage keeps more than sixteen exact resolved models" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const suffixes = "ABCDEFGHJKMNPQRST";
    for (suffixes, 0..) |suffix, index| {
        var id_buf: [30]u8 = undefined;
        const id = try std.fmt.bufPrint(
            &id_buf,
            "gen_01ARZ3NDEKTSV4RRFFQ69G5FA{c}",
            .{suffix},
        );
        var model_buf: [64]u8 = undefined;
        const model = try std.fmt.bufPrint(&model_buf, "provider/model-{d}", .{index});
        const sequence = try usage.reserveInvocation();
        try usage.finishObservedInvocation(
            alloc,
            sequence,
            1,
            .observed_generation,
            id,
            "https://ai-gateway.vercel.sh",
            null,
        );
        try usage.applyGeneration(alloc, .{
            .id = id,
            .model = model,
            .total_cost = 0.001,
            .input_tokens = 1,
            .output_tokens = 1,
            .cache_read_tokens = 0,
            .cache_write_tokens = 0,
            .billable_web_search_calls = 0,
        });
    }

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 17), snapshot.models.len);
    try std.testing.expectEqualStrings("provider/model-16", snapshot.models[16].model);
}

test "usage records committed lines once and restores a bounded snapshot" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    try usage.recordCommittedLines(4, 2);

    var saved = try usage.snapshot(alloc);
    defer saved.deinit(alloc);
    try std.testing.expect(saved.code_complete);
    try std.testing.expectEqual(@as(u64, 4), saved.lines_added);
    try std.testing.expectEqual(@as(u64, 2), saved.lines_removed);
    try validateSnapshot(saved);

    var restored = Usage.initLegacy();
    defer restored.deinit(alloc);
    try restored.restore(alloc, saved, io_mod.milliTimestamp());

    var round_trip = try restored.snapshot(alloc);
    defer round_trip.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, round_trip.billing);
    try std.testing.expect(round_trip.code_complete);
    try std.testing.expectEqual(@as(u64, 4), round_trip.lines_added);
    try std.testing.expectEqual(@as(u64, 2), round_trip.lines_removed);
}

test "sixteenth pending generation is the capacity boundary" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    // Every suffix is a valid Crockford identifier character, so each id is a
    // distinct, well-formed generation id.
    const suffixes = "ABCDEFGHJKMNPQRST";
    try std.testing.expect(suffixes.len > max_pending_generations);

    for (suffixes[0..max_pending_generations]) |suffix| {
        var id_buf: [30]u8 = undefined;
        const id = try std.fmt.bufPrint(
            &id_buf,
            "gen_01ARZ3NDEKTSV4RRFFQ69G5FA{c}",
            .{suffix},
        );
        const sequence = try usage.reserveInvocation();
        try usage.finishObservedInvocation(
            alloc,
            sequence,
            1,
            .observed_generation,
            id,
            "https://ai-gateway.vercel.sh",
            null,
        );
    }

    var at_capacity = try usage.snapshot(alloc);
    defer at_capacity.deinit(alloc);
    try std.testing.expectEqual(Availability.pending, at_capacity.billing);
    try std.testing.expectEqual(
        @as(usize, max_pending_generations),
        at_capacity.pending.len,
    );

    var overflow_id_buf: [30]u8 = undefined;
    const overflow_id = try std.fmt.bufPrint(
        &overflow_id_buf,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FA{c}",
        .{suffixes[max_pending_generations]},
    );
    const overflow_sequence = try usage.reserveInvocation();
    try std.testing.expectError(
        error.UsageCapacityExceeded,
        usage.finishObservedInvocation(
            alloc,
            overflow_sequence,
            1,
            .observed_generation,
            overflow_id,
            "https://ai-gateway.vercel.sh",
            null,
        ),
    );

    var overflowed = try usage.snapshot(alloc);
    defer overflowed.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, overflowed.billing);
    try std.testing.expectEqual(
        @as(usize, max_pending_generations),
        overflowed.pending.len,
    );
}

test "populated usage snapshot keeps the rollback-readable durable shape" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const first_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        first_sequence,
        120,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        "team_alpha",
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "anthropic/claude-opus-4.8",
        .total_cost = 0.0125,
        .input_tokens = 100,
        .output_tokens = 40,
        .cache_read_tokens = 12,
        .cache_write_tokens = 8,
        .billable_web_search_calls = 1,
    });

    const second_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        second_sequence,
        90,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        .model = "openai/gpt-5.5",
        .total_cost = 0.004,
        .input_tokens = 200,
        .output_tokens = 25,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .billable_web_search_calls = 0,
    });

    // Leave the third invocation unresolved so the snapshot carries pending
    // identity that validation cannot reconstruct.
    const pending_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        pending_sequence,
        30,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAX",
        "https://ai-gateway.vercel.sh",
        "team_beta",
    );
    try usage.recordCommittedLines(5, 3);

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.pending, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 2), snapshot.models.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending.len);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeSnapshot(&encoded.writer, snapshot);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 18), parsed.value.object.count());
    try std.testing.expect(parsed.value.object.get("schema_version") == null);
    const persisted_models = parsed.value.object.get("models").?.array.items;
    for (persisted_models) |model| {
        try std.testing.expectEqual(@as(usize, 8), model.object.count());
    }
    const persisted_pending = parsed.value.object.get("pending").?.array.items;
    for (persisted_pending) |pending| {
        try std.testing.expectEqual(@as(usize, 4), pending.object.count());
    }
    var decoded = try parseSnapshotValue(alloc, parsed.value);
    defer decoded.deinit(alloc);

    try std.testing.expectEqual(snapshot.billing, decoded.billing);
    try std.testing.expectEqual(snapshot.api_duration_complete, decoded.api_duration_complete);
    try std.testing.expectEqual(snapshot.wall_duration_complete, decoded.wall_duration_complete);
    try std.testing.expectEqual(snapshot.code_complete, decoded.code_complete);
    try std.testing.expectEqual(snapshot.next_sequence, decoded.next_sequence);
    try std.testing.expectEqual(snapshot.settled_through_sequence, decoded.settled_through_sequence);
    try std.testing.expectEqual(snapshot.api_duration_ms, decoded.api_duration_ms);
    try std.testing.expectEqual(snapshot.wall_duration_ms, decoded.wall_duration_ms);
    try std.testing.expectEqual(snapshot.lines_added, decoded.lines_added);
    try std.testing.expectEqual(snapshot.lines_removed, decoded.lines_removed);
    try std.testing.expect(snapshot.request_count != null);
    try std.testing.expect(decoded.request_count == null);
    try std.testing.expectEqual(@as(usize, 0), decoded.publication_backlog.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.incidents.len);

    try std.testing.expectEqual(snapshot.models.len, decoded.models.len);
    for (snapshot.models, decoded.models) |expected, actual| {
        try std.testing.expectEqualStrings(expected.model, actual.model);
        try std.testing.expectEqual(expected.first_sequence, actual.first_sequence);
        try std.testing.expectApproxEqAbs(expected.total_cost, actual.total_cost, 1e-12);
        try std.testing.expectEqual(expected.input_tokens, actual.input_tokens);
        try std.testing.expectEqual(expected.output_tokens, actual.output_tokens);
        try std.testing.expectEqual(expected.cache_read_tokens, actual.cache_read_tokens);
        try std.testing.expectEqual(expected.cache_write_tokens, actual.cache_write_tokens);
        try std.testing.expectEqual(
            expected.billable_web_search_calls,
            actual.billable_web_search_calls,
        );
    }

    try std.testing.expectEqual(snapshot.pending.len, decoded.pending.len);
    for (snapshot.pending, decoded.pending) |expected, actual| {
        try std.testing.expectEqualStrings(expected.id, actual.id);
        try std.testing.expectEqual(expected.sequence, actual.sequence);
        try std.testing.expectEqualStrings(expected.origin, actual.origin);
        try std.testing.expect(optionalStringsEqual(expected.team, actual.team));
    }

    const Publisher = struct {
        fn publish(_: *anyopaque, _: usage_report.ProfileEvent) !void {}
    };
    var publisher_context: u8 = 0;
    var resumed = Usage.initFresh();
    defer resumed.deinit(alloc);
    resumed.configurePublicationSink(.{
        .context = &publisher_context,
        .allocator = alloc,
        .publish = Publisher.publish,
    });
    try resumed.restore(alloc, decoded, 1);
    try resumed.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAX",
        .model = "provider/new",
        .total_cost = 0.001,
        .input_tokens = 2,
        .output_tokens = 1,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .billable_web_search_calls = 0,
    });
    var continued = try resumed.snapshot(alloc);
    defer continued.deinit(alloc);
    try validateSnapshot(continued);
    try std.testing.expect(continued.reasoning_tokens == null);
    try std.testing.expect(continued.request_count == null);
    try std.testing.expectEqual(Availability.complete, continued.billing);
}

test "rich usage snapshot preserves optional metrics and recovery state" {
    const alloc = std.testing.allocator;
    const Publisher = struct {
        fn fail(_: *anyopaque, _: usage_report.ProfileEvent) !void {
            return error.InjectedPublicationFailure;
        }
    };
    var publisher_context: u8 = 0;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configurePublicationSink(.{
        .context = &publisher_context,
        .allocator = alloc,
        .publish = Publisher.fail,
    });

    const resolved_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        resolved_sequence,
        5,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 100,
        .model = "provider/model",
        .total_cost = 0.01,
        .input_tokens = 10,
        .output_tokens = 4,
        .cache_read_tokens = 2,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 0,
    });
    const pending_sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        pending_sequence,
        6,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        "https://ai-gateway.vercel.sh",
        "team_alpha",
    );

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try appendIncidentOwned(alloc, &snapshot, .{
        .occurred_at_ms = 90,
        .completeness = .incomplete,
    });
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeRichSnapshot(&encoded.writer, snapshot);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded.written(),
        .{},
    );
    defer parsed.deinit();
    var decoded = try parseSnapshotValue(alloc, parsed.value);
    defer decoded.deinit(alloc);

    try std.testing.expectEqual(snapshot.reasoning_tokens, decoded.reasoning_tokens);
    try std.testing.expectEqual(snapshot.request_count, decoded.request_count);
    try std.testing.expectEqual(
        snapshot.models[0].reasoning_tokens,
        decoded.models[0].reasoning_tokens,
    );
    try std.testing.expectEqual(
        snapshot.models[0].request_count,
        decoded.models[0].request_count,
    );
    try std.testing.expectEqual(
        snapshot.pending[0].observed_at_ms,
        decoded.pending[0].observed_at_ms,
    );
    try std.testing.expectEqual(@as(usize, 1), decoded.publication_backlog.len);
    try std.testing.expect(usage_report.GenerationFact.eql(
        snapshot.publication_backlog[0],
        decoded.publication_backlog[0],
    ));
    try std.testing.expectEqualSlices(
        usage_report.Incident,
        snapshot.incidents,
        decoded.incidents,
    );
}

test "owned snapshot incident overflow matches runtime retention" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);

    for (0..max_usage_incidents) |index| {
        try appendIncidentOwned(alloc, &snapshot, .{
            .occurred_at_ms = @intCast(index + 1),
            .completeness = .pending,
        });
    }
    try std.testing.expectEqual(max_usage_incidents, snapshot.incidents.len);
    try appendIncidentOwned(alloc, &snapshot, .{
        .occurred_at_ms = max_usage_incidents + 1,
        .completeness = .pending,
    });
    try std.testing.expectEqual(@as(usize, 1), snapshot.incidents.len);
    try std.testing.expectEqual(
        @as(i64, max_usage_incidents + 1),
        snapshot.incidents[0].occurred_at_ms,
    );
    try std.testing.expectEqual(
        usage_report.Completeness.incomplete,
        snapshot.incidents[0].completeness,
    );
}

test "provider rejection removes pending generation and marks billing incomplete" {
    const alloc = std.testing.allocator;
    var fake = TestGenerationUsageProvider{ .outcome = .reject };
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        5,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://provider.example",
        null,
    );
    var cancel = std.atomic.Value(bool).init(false);
    reconcilePendingBlocking(
        &usage,
        alloc,
        "credential",
        &cancel,
        fake.provider(),
        1,
    );

    var rejected = try usage.snapshot(alloc);
    defer rejected.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(Availability.incomplete, rejected.billing);
    try std.testing.expectEqual(@as(usize, 0), rejected.pending.len);
}

test "provider preserve outcome keeps pending generation for a future credential" {
    const alloc = std.testing.allocator;
    var fake = TestGenerationUsageProvider{ .outcome = .preserve_pending };
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        5,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://provider.example",
        null,
    );
    var cancel = std.atomic.Value(bool).init(false);
    reconcilePendingBlocking(
        &usage,
        alloc,
        "credential",
        &cancel,
        fake.provider(),
        1,
    );

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(Availability.pending, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending.len);
    try std.testing.expectEqualStrings(
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        snapshot.pending[0].id,
    );
}

test "provider retry outcome leaves pending generation unchanged" {
    const alloc = std.testing.allocator;
    var fake = TestGenerationUsageProvider{ .outcome = .retry };
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        5,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://provider.example",
        null,
    );
    var cancel = std.atomic.Value(bool).init(false);
    reconcilePendingBlocking(
        &usage,
        alloc,
        "credential",
        &cancel,
        fake.provider(),
        1,
    );

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(Availability.pending, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending.len);
}

test "provider failure leaves pending generation unchanged" {
    const alloc = std.testing.allocator;
    var fake = TestGenerationUsageProvider{ .outcome = .unavailable };
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        5,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://provider.example",
        null,
    );
    var cancel = std.atomic.Value(bool).init(false);
    reconcilePendingBlocking(
        &usage,
        alloc,
        "credential",
        &cancel,
        fake.provider(),
        1,
    );

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(Availability.pending, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending.len);
}

test "provider cancellation stops reconciliation and preserves pending usage" {
    const alloc = std.testing.allocator;
    var fake = TestGenerationUsageProvider{ .outcome = .cancelled };
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        5,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://provider.example",
        null,
    );
    var cancel = std.atomic.Value(bool).init(false);
    reconcilePendingBlocking(
        &usage,
        alloc,
        "credential",
        &cancel,
        fake.provider(),
        2,
    );

    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(Availability.pending, snapshot.billing);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending.len);
}

test "checkpoint snapshot does not join a completed reconciliation worker" {
    const Capture = struct {
        calls: usize = 0,

        fn persist(raw: *anyopaque, _: Snapshot) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    const Worker = struct {
        gate: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            while (!self.gate.load(.seq_cst)) std.atomic.spinLoopHint();
        }
    };

    const alloc = std.testing.allocator;
    var capture = Capture{};
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configureCheckpointSink(.{
        .context = &capture,
        .allocator = alloc,
        .persist = Capture.persist,
    });

    var gate = std.atomic.Value(bool).init(false);
    var worker = Worker{ .gate = &gate };
    usage.reconciliation_thread = try std.Thread.spawn(
        .{},
        Worker.run,
        .{&worker},
    );
    usage.reconciliation_done.store(true, .seq_cst);
    defer gate.store(true, .seq_cst);

    try std.testing.expect(usage.persistCheckpoint());
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(usage.reconciliation_thread != null);

    gate.store(true, .seq_cst);
    usage.finishReconciliationIfDone();
    try std.testing.expect(usage.reconciliation_thread == null);
}

test "gateway observation checkpoints active and terminal usage states" {
    const Capture = struct {
        calls: usize = 0,
        billing: [2]Availability = undefined,
        api_duration_complete: [2]bool = undefined,
        pending_count: [2]usize = undefined,

        fn persist(raw: *anyopaque, snapshot: Snapshot) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const index = self.calls;
            self.billing[index] = snapshot.billing;
            self.api_duration_complete[index] = snapshot.api_duration_complete;
            self.pending_count[index] = snapshot.pending.len;
            self.calls += 1;
        }
    };

    const alloc = std.testing.allocator;
    var capture = Capture{};
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configureCheckpointSink(.{
        .context = &capture,
        .allocator = alloc,
        .persist = Capture.persist,
    });

    const observation = try GatewayObservation.begin(&usage);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(Availability.incomplete, capture.billing[0]);
    try std.testing.expect(!capture.api_duration_complete[0]);
    try std.testing.expectEqual(@as(usize, 0), capture.pending_count[0]);

    try observation.complete(
        alloc,
        .ok,
        .{ .generation_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV" },
        "https://ai-gateway.vercel.sh",
        null,
    );
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(Availability.pending, capture.billing[1]);
    try std.testing.expect(capture.api_duration_complete[1]);
    try std.testing.expectEqual(@as(usize, 1), capture.pending_count[1]);
}

test "gateway observation does not proceed when active checkpoint fails" {
    const Reject = struct {
        calls: usize = 0,

        fn persist(raw: *anyopaque, _: Snapshot) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return error.CheckpointRejected;
        }
    };

    const alloc = std.testing.allocator;
    var reject = Reject{};
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configureCheckpointSink(.{
        .context = &reject,
        .allocator = alloc,
        .persist = Reject.persist,
    });

    try std.testing.expectError(
        error.CheckpointRejected,
        GatewayObservation.begin(&usage),
    );
    try std.testing.expectEqual(@as(usize, 1), reject.calls);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.complete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "terminal checkpoint failure preserves request progress as incomplete" {
    const Reject = struct {
        calls: usize = 0,

        fn persist(raw: *anyopaque, _: Snapshot) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls == 2) return error.CheckpointRejected;
        }
    };

    const alloc = std.testing.allocator;
    var reject = Reject{};
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);
    usage.configureCheckpointSink(.{
        .context = &reject,
        .allocator = alloc,
        .persist = Reject.persist,
    });

    const observation = try GatewayObservation.begin(&usage);
    try observation.fail(.unbilled);
    try std.testing.expectEqual(@as(usize, 2), reject.calls);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(Availability.incomplete, snapshot.billing);
    try std.testing.expect(snapshot.api_duration_complete);
    try std.testing.expectEqual(@as(u64, 1), snapshot.settled_through_sequence);
}

test "pending generation origins remain bounded transport inputs" {
    try validateOrigin("https://ai-gateway.vercel.sh");
    try validateOrigin("http://127.0.0.1:3000");
    try validateOrigin("https://provider.example");

    try std.testing.expectError(
        error.InvalidGatewayOrigin,
        validateOrigin(""),
    );
    try std.testing.expectError(
        error.InvalidGatewayOrigin,
        validateOrigin("https://provider.example\ninjected"),
    );
    var oversized: [max_origin_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(
        error.InvalidGatewayOrigin,
        validateOrigin(&oversized),
    );
}

test "reconciliation retry delay observes cancellation promptly" {
    var cancel = std.atomic.Value(bool).init(false);
    var cancelled_at_ms = std.atomic.Value(i64).init(0);
    const Trigger = struct {
        fn run(flag: *std.atomic.Value(bool), signal_time: *std.atomic.Value(i64)) void {
            var io_backend: std.Io.Threaded = .init_single_threaded;
            io_backend.io().sleep(.fromMilliseconds(20), .real) catch {};
            signal_time.store(io_mod.milliTimestamp(), .seq_cst);
            flag.store(true, .seq_cst);
        }
    };
    const thread = try std.Thread.spawn(.{}, Trigger.run, .{ &cancel, &cancelled_at_ms });
    const completed = waitForReconciliationRetry(&cancel);
    const completed_at_ms = io_mod.milliTimestamp();
    thread.join();

    try std.testing.expect(!completed);
    const signalled_at_ms = cancelled_at_ms.load(.seq_cst);
    try std.testing.expect(signalled_at_ms > 0);
    const cancellation_response_bound_ms = 250;
    try std.testing.expect(completed_at_ms - signalled_at_ms < cancellation_response_bound_ms);
}

test "stale reconciliation credential cannot replace a refreshed credential" {
    const alloc = std.testing.allocator;
    var usage = Usage.initFresh();
    defer usage.deinit(alloc);

    usage.startReconciliation(alloc, "initial-key");
    usage.replaceReconciliationCredential(alloc, "refreshed-key");
    usage.startReconciliation(alloc, "initial-key");
    usage.refreshReconciliationCredential(
        alloc,
        "initial-key",
        "stale-producer-key",
    );

    const expected = reconciliationKeyDigest("refreshed-key");
    try std.testing.expectEqualSlices(
        u8,
        &expected,
        &(usage.reconciliation_key_digest orelse return error.TestUnexpectedResult),
    );

    usage.refreshReconciliationCredential(
        alloc,
        "refreshed-key",
        "next-key",
    );
    const next_expected = reconciliationKeyDigest("next-key");
    try std.testing.expectEqualSlices(
        u8,
        &next_expected,
        &(usage.reconciliation_key_digest orelse return error.TestUnexpectedResult),
    );

    usage.clearReconciliationCredential();
    usage.refreshReconciliationCredential(
        alloc,
        "next-key",
        "stale-after-clear",
    );
    try std.testing.expect(usage.reconciliation_key_digest == null);
    try std.testing.expect(usage.reconciliation_credential_blocked);

    usage.replaceReconciliationCredential(alloc, "replacement-key");
    const replacement_expected = reconciliationKeyDigest("replacement-key");
    try std.testing.expectEqualSlices(
        u8,
        &replacement_expected,
        &(usage.reconciliation_key_digest orelse return error.TestUnexpectedResult),
    );
    try std.testing.expect(!usage.reconciliation_credential_blocked);
}
