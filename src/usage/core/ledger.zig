//! The session ledger core, a state machine checked against a formal model:
//! each `Event` variant is one of the model's actions, `State` is a call's
//! state there, and every step reports one model transition for the trace.
//!
//! Pure: no I/O, no clock, no globals, and no allocation after `init`. The
//! caller runs the returned effects and feeds their results back as events.
//! An event the ledger refuses returns an error and changes nothing.
//!
//! Rules:
//! - Exact settlement never takes a lookup slot.
//! - A 401/403 lookup blocks the entry only for the credential that
//!   answered it; any other credential (or none) puts it back in `lookup`.
//! - Model rows: totals go to at most `max_models`
//!   per-model rows, because older readers reject more rows and require the
//!   rows to add up to the totals. A fact whose model would need a row when
//!   they are full stays out of the totals (`unpriced`), with an incident.
//!
//! Totals and per-model rows change exactly once per call, when its fact
//! arrives (an exact receipt or a found lookup), with checked arithmetic.
//! Usage history comes from AI Gateway's reports, so nothing is published.

const std = @import("std");
const trace = @import("../trace.zig");

pub const Sequence = u64;

/// SHA-256 of a credential secret. The ledger never sees the secret itself.
pub const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// The digest the ledger compares credentials by.
pub fn credentialDigest(secret: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &digest, .{});
    return digest;
}

pub const Provider = enum { gateway, codex, grok, configured };

pub const CredentialSource = enum {
    vercel_oidc_token,
    ai_gateway_api_key,
    fx_login,
    stored_key,
    chatgpt_subscription,
    grok_subscription,
    host_managed,
    configured,
};

/// A call's state, named exactly as in the formal model.
pub const State = enum { idle, active, unbilled, lookup, blocked, unpriced, settled };

pub const Availability = enum { complete, pending, incomplete, legacy };

pub const Completeness = enum { pending, incomplete };

pub const Incident = struct {
    occurred_at_ms: i64,
    completeness: Completeness,
};

/// Why calls are missing from the totals, as the views word it.
pub const UnpricedReason = enum { lookup_pending, sign_in_cannot_look_up, no_receipt };

/// Whether `source` may authorize lookups for `provider`, as fx's
/// `model_provider.authorizesCredential`. Snapshots must keep this rule.
pub fn authorizesCredential(provider: Provider, source: CredentialSource) bool {
    if (source == .host_managed) return true;
    return switch (provider) {
        .gateway => source != .chatgpt_subscription and source != .grok_subscription and source != .configured,
        .configured => source == .configured,
        .codex => source == .chatgpt_subscription,
        .grok => source == .grok_subscription,
    };
}

pub const max_model_bytes = 1024;
pub const max_origin_bytes = 2048;
pub const max_team_bytes = 255;
pub const max_account_bytes = 1024;
/// Older readers' cap on a snapshot's identifier bytes.
pub const max_identifier_bytes = 8 * 1024;

/// Bounds on the ledger's state. The defaults are production's: older
/// binaries reject snapshots with more pending entries, incidents, or model
/// rows.
pub const Limits = struct {
    max_active: u32 = 64,
    max_pending: u32 = 16,
    max_incidents: u32 = 16,
    max_models: u32 = 32,
    /// Model names plus the ids, origins, teams, and accounts of waiting
    /// entries.
    max_identifier_bytes: u32 = max_identifier_bytes,
    /// Pending entries a persisted snapshot holds. Older parsers reject more
    /// than 16. A snapshot an older binary saved counts its staged facts here
    /// too, one bridge entry each.
    max_persisted_pending: u32 = 16,

    /// Upper bound for every count limit; it also sizes `Output`.
    pub const ceiling = 64;

    fn valid(limits: Limits) bool {
        inline for (std.meta.fields(Limits)) |field| {
            const value = @field(limits, field.name);
            const max = if (comptime std.mem.eql(u8, field.name, "max_identifier_bytes")) max_identifier_bytes else ceiling;
            if (value == 0 or value > max) return false;
        }
        return true;
    }
};

pub const Start = enum {
    /// A new session: complete, with known reasoning and request counts.
    fresh,
    /// A session that predates usage accounting.
    legacy,
};

/// `gen_` and 26 Crockford base32 characters (no I, L, O, or U).
pub const GenerationId = struct {
    bytes: [length]u8,

    pub const length = 30;

    pub fn parse(text: []const u8) error{InvalidGenerationId}!GenerationId {
        if (text.len != length or !std.mem.startsWith(u8, text, "gen_")) return error.InvalidGenerationId;
        for (text[4..]) |char| switch (char) {
            '0'...'9', 'A'...'H', 'J', 'K', 'M', 'N', 'P'...'T', 'V'...'Z' => {},
            else => return error.InvalidGenerationId,
        };
        return .{ .bytes = text[0..length].* };
    }

    pub fn slice(id: *const GenerationId) []const u8 {
        return &id.bytes;
    }

    fn eql(a: GenerationId, b: GenerationId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

/// 1..`max` bytes of printable ASCII (0x21-0x7e).
fn validText(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |char| if (char < 0x21 or char > 0x7e) return false;
    return true;
}

/// An account id as today's snapshots accept it: 1..1024 bytes of UTF-8
/// without control characters.
fn validAccount(value: []const u8) bool {
    if (value.len == 0 or value.len > max_account_bytes or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |char| if (std.ascii.isControl(char)) return false;
    return true;
}

/// Inline storage for a validated string, so steps never allocate.
fn Text(comptime max: usize) type {
    return struct {
        len: std.math.IntFittingRange(0, max),
        bytes: [max]u8,

        const Self = @This();

        /// `value` must already be validated to fit.
        fn init(value: []const u8) Self {
            std.debug.assert(value.len <= max);
            var text: Self = .{ .len = @intCast(value.len), .bytes = undefined };
            @memcpy(text.bytes[0..value.len], value);
            return text;
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const FactError = error{
    InvalidModel,
    InvalidCost,
    InvalidTime,
    CacheExceedsInput,
    ReasoningExceedsOutput,
};

/// An authoritative billing record for one generation: an exact receipt or a
/// found lookup. `model` is borrowed for the call; the ledger copies it.
pub const Fact = struct {
    id: GenerationId,
    created_at_ms: i64,
    model: []const u8,
    total_cost: f64,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: ?u64 = null,
    billable_web_search_calls: u64 = 0,

    pub fn validate(fact: Fact) FactError!void {
        if (!validText(fact.model, max_model_bytes)) return error.InvalidModel;
        if (!std.math.isFinite(fact.total_cost) or fact.total_cost < 0) return error.InvalidCost;
        if (fact.created_at_ms < 0) return error.InvalidTime;
        if (fact.cache_read_tokens > fact.input_tokens) return error.CacheExceedsInput;
        if (fact.cache_write_tokens > fact.input_tokens) return error.CacheExceedsInput;
        if (fact.reasoning_tokens) |reasoning| {
            if (reasoning > fact.output_tokens) return error.ReasoningExceedsOutput;
        }
    }
};

/// What a call that needs a lookup records. Strings are borrowed for the
/// call; the ledger copies them.
pub const LookupRequest = struct {
    id: GenerationId,
    origin: []const u8,
    team: ?[]const u8 = null,
    /// Null when the call didn't say, as older snapshots allow; an identity
    /// then can't be set.
    credential_source: ?CredentialSource,
    credential_identity: ?Digest = null,
    account_id: ?[]const u8 = null,
    observed_at_ms: i64,

    fn valid(request: LookupRequest) bool {
        if (!validText(request.origin, max_origin_bytes)) return false;
        if (request.team) |team| if (!validText(team, max_team_bytes)) return false;
        if (request.account_id) |account| if (!validAccount(account)) return false;
        if (request.credential_identity != null and request.credential_source == null) return false;
        return request.observed_at_ms >= 0;
    }

    fn identifierBytes(request: LookupRequest) usize {
        var total = GenerationId.length + request.origin.len;
        if (request.team) |team| total += team.len;
        if (request.account_id) |account| total += account.len;
        return total;
    }
};

pub const LookupStatus = enum { lookup, blocked };

/// A call waiting on `/v1/generation` (the model's `Waiting`).
pub const Pending = struct {
    sequence: Sequence,
    provider: Provider,
    id: GenerationId,
    origin: Text(max_origin_bytes),
    team: ?Text(max_team_bytes),
    credential_source: ?CredentialSource,
    credential_identity: ?Digest,
    account_id: ?Text(max_account_bytes),
    observed_at_ms: i64,
    status: LookupStatus = .lookup,
    /// The credential that answered 401/403, while `status` is `blocked`.
    blocked_by: ?Digest = null,

    fn init(sequence: Sequence, provider: Provider, request: LookupRequest) Pending {
        return .{
            .sequence = sequence,
            .provider = provider,
            .id = request.id,
            .origin = .init(request.origin),
            .team = if (request.team) |team| .init(team) else null,
            .credential_source = request.credential_source,
            .credential_identity = request.credential_identity,
            .account_id = if (request.account_id) |account| .init(account) else null,
            .observed_at_ms = request.observed_at_ms,
        };
    }

    pub fn originText(pending: *const Pending) []const u8 {
        return pending.origin.slice();
    }

    pub fn teamText(pending: *const Pending) ?[]const u8 {
        return if (pending.team) |*team| team.slice() else null;
    }

    pub fn accountText(pending: *const Pending) ?[]const u8 {
        return if (pending.account_id) |*account| account.slice() else null;
    }

    fn identifierBytes(pending: *const Pending) usize {
        var total = GenerationId.length + pending.originText().len;
        if (pending.teamText()) |team| total += team.len;
        if (pending.accountText()) |account| total += account.len;
        return total;
    }
};

pub const Totals = struct {
    total_cost: f64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    /// Null when unknown, as in a legacy session or after a fact without it.
    reasoning_tokens: ?u64 = 0,
    request_count: ?u64 = 0,
    billable_web_search_calls: u64 = 0,

    /// These totals plus one fact, or `error.Overflow`.
    fn add(totals: Totals, fact: Fact) error{Overflow}!Totals {
        const cost = totals.total_cost + fact.total_cost;
        if (!std.math.isFinite(cost)) return error.Overflow;
        return .{
            .total_cost = cost,
            .input_tokens = try std.math.add(u64, totals.input_tokens, fact.input_tokens),
            .output_tokens = try std.math.add(u64, totals.output_tokens, fact.output_tokens),
            .cache_read_tokens = try std.math.add(u64, totals.cache_read_tokens, fact.cache_read_tokens),
            .cache_write_tokens = try std.math.add(u64, totals.cache_write_tokens, fact.cache_write_tokens),
            .reasoning_tokens = try addKnown(totals.reasoning_tokens, fact.reasoning_tokens),
            .request_count = try addKnown(totals.request_count, 1),
            .billable_web_search_calls = try std.math.add(u64, totals.billable_web_search_calls, fact.billable_web_search_calls),
        };
    }
};

/// Unknown stays unknown.
fn addKnown(a: ?u64, b: ?u64) error{Overflow}!?u64 {
    const x = a orelse return null;
    const y = b orelse return null;
    return try std.math.add(u64, x, y);
}

/// One model's share of the totals. Rows are ordered by `first_sequence`.
pub const ModelRow = struct {
    model: Text(max_model_bytes),
    first_sequence: Sequence,
    totals: Totals,

    pub fn name(row: *const ModelRow) []const u8 {
        return row.model.slice();
    }
};

pub const Unpriced = struct {
    /// Every call missing from the totals: waiting, blocked, or without a receipt.
    count: u64,
    /// The most actionable reason first: a sign-in that can't look up cost,
    /// then lookups still running, then calls with no receipt. Null when
    /// `count` is 0.
    reason: ?UnpricedReason,
    lookup_pending: u32,
    sign_in_cannot_look_up: u32,
    no_receipt: u64,
};

/// What every surface draws for the session. Slices borrow the ledger and are
/// valid until its next step.
pub const View = struct {
    availability: Availability,
    totals: Totals,
    models: []const ModelRow,
    unpriced: Unpriced,
    active: u32,
    pending: u32,
    incidents: u32,
};

pub const Event = union(enum) {
    /// Reserve the next sequence for a call that is about to send.
    begin: Provider,
    /// A valid receipt or a subscription total arrived (no lookup slot).
    finish_exact: struct { sequence: Sequence, fact: Fact },
    /// A generation id but no usable receipt, including a cancel.
    finish_lookup: struct { sequence: Sequence, request: LookupRequest },
    /// Failed before anything was sent.
    finish_unbilled: Sequence,
    /// Possibly sent with no generation id: nothing to look up.
    finish_unpriced: struct { sequence: Sequence, at_ms: i64 },
    /// The host's credential changed. Null is signed out.
    set_credential: ?Digest,
    lookup_found: struct { sequence: Sequence, fact: Fact },
    /// 401 or 403 for the current credential.
    lookup_unauthorized: Sequence,
    /// A bad id, an identity mismatch, or another 4xx.
    lookup_rejected: Sequence,
    /// 404, 408, 425, 429, 5xx, or a transport error: ask again later.
    lookup_retry: Sequence,
};

pub const EventTag = std.meta.Tag(Event);

/// What a trace record names: an event, or `restore` (one record per call a
/// restored session brings back).
pub const TraceEvent = blk: {
    const events = std.meta.fields(EventTag);
    var names: [events.len + 1][]const u8 = undefined;
    var values: [events.len + 1]u8 = undefined;
    for (events, 0..) |field, index| {
        names[index] = field.name;
        values[index] = index;
    }
    names[events.len] = "restore";
    values[events.len] = events.len;
    break :blk @Enum(u8, .exhaustive, &names, &values);
};

pub const Effect = union(enum) {
    /// Persist a session snapshot before going on.
    persist_checkpoint,
    /// Ask `/v1/generation` about this pending entry (with backoff on retry).
    start_lookup: Sequence,
};

/// One model step, written to the trace by `writeTrace`.
pub const Transition = struct {
    event: TraceEvent,
    /// The call's sequence; 0 for `set_credential`, which has no single call.
    call: Sequence,
    /// Null when there is no single call (written as "-").
    from: ?State,
    to: ?State,
    /// The credential's trace ordinal after the step; 0 is none.
    cred: u32,
    /// Model rows after the step.
    rows: u32,
    /// The step recorded an incident for this call.
    incident: bool = false,
    /// The step applied this call to the totals.
    applied: bool = false,
    /// `set_credential`: blocked entries moved back to `lookup`.
    moved: u32 = 0,
    /// Which identifier-budget checks refused: 1 a waiting entry, 2 a new
    /// row (the model's `spent` arguments).
    budget: u2 = 0,
};

pub const max_effects = 1 + Limits.ceiling;

pub const Output = struct {
    effect_buffer: [max_effects]Effect = undefined,
    effect_count: usize = 0,
    transition: ?Transition = null,
    /// Set when the trace record could not be written. The step itself took
    /// effect; only its observation is missing.
    trace_error: ?std.Io.Writer.Error = null,

    pub fn effects(output: *const Output) []const Effect {
        return output.effect_buffer[0..output.effect_count];
    }

    fn push(output: *Output, effect: Effect) void {
        std.debug.assert(output.effect_count < max_effects);
        output.effect_buffer[output.effect_count] = effect;
        output.effect_count += 1;
    }
};

pub const StepError = FactError || error{
    /// `max_active` calls are already in flight.
    TooManyActive,
    SequenceExhausted,
    /// The sequence names no active call.
    NotActive,
    /// The sequence names no entry in `lookup` (it may be blocked).
    NotLookingUp,
    /// Lookups need a credential.
    NoCredential,
    InvalidGenerationId,
    InvalidLookupRequest,
    /// The generation id already belongs to another waiting call.
    DuplicateGenerationId,
    /// A found lookup returned a different generation id.
    GenerationIdMismatch,
    /// Adding the call would overflow a total.
    Overflow,
    CredentialOrdinalsExhausted,
};

const Active = struct {
    sequence: Sequence,
    provider: Provider,
};

const Credential = struct {
    digest: Digest,
    ordinal: u32,
};

/// Digests remembered for trace ordinals, in the order first seen.
const max_known_credentials = 16;

pub const Ledger = struct {
    limits: Limits,
    next_sequence: Sequence = 1,
    active: std.ArrayList(Active),
    pending: std.ArrayList(Pending),
    incidents: std.ArrayList(Incident),
    rows: std.ArrayList(ModelRow),
    totals: Totals,
    /// Calls that ended without a receipt or a row this session.
    no_receipt: u64 = 0,
    /// Sticky once an incident is recorded.
    incomplete: bool = false,
    legacy: bool,
    /// Every sequence up to this one has finished (today's
    /// `settled_through_sequence`).
    settled_through: Sequence = 0,
    activity: Activity = .{},
    /// The trace instance this core writes under. A restarted process traces
    /// a new instance: each process's core is its own behavior of the model.
    trace_instance: []const u8 = "session",
    credential: ?Credential = null,
    known: [max_known_credentials]Credential = undefined,
    known_count: usize = 0,
    next_ordinal: u32 = 1,

    pub const InitError = error{InvalidLimits} || std.mem.Allocator.Error;

    /// Allocates every bound up front with `gpa`; release with `deinit` and
    /// the same allocator.
    pub fn init(gpa: std.mem.Allocator, limits: Limits, start: Start) InitError!Ledger {
        if (!limits.valid()) return error.InvalidLimits;
        var active: std.ArrayList(Active) = try .initCapacity(gpa, limits.max_active);
        errdefer active.deinit(gpa);
        var pending: std.ArrayList(Pending) = try .initCapacity(gpa, limits.max_pending);
        errdefer pending.deinit(gpa);
        var incidents: std.ArrayList(Incident) = try .initCapacity(gpa, limits.max_incidents);
        errdefer incidents.deinit(gpa);
        const rows: std.ArrayList(ModelRow) = try .initCapacity(gpa, limits.max_models);
        return .{
            .limits = limits,
            .active = active,
            .pending = pending,
            .incidents = incidents,
            .rows = rows,
            .totals = switch (start) {
                .fresh => .{},
                .legacy => .{ .reasoning_tokens = null, .request_count = null },
            },
            .legacy = start == .legacy,
            .activity = if (start == .legacy) .unknown else .{},
        };
    }

    pub fn deinit(ledger: *Ledger, gpa: std.mem.Allocator) void {
        ledger.active.deinit(gpa);
        ledger.pending.deinit(gpa);
        ledger.incidents.deinit(gpa);
        ledger.rows.deinit(gpa);
        ledger.* = undefined;
    }

    pub fn availability(ledger: *const Ledger) Availability {
        if (ledger.incomplete) return .incomplete;
        if (ledger.legacy) return .legacy;
        if (ledger.pending.items.len > 0) return .pending;
        return .complete;
    }

    pub fn view(ledger: *const Ledger) View {
        var lookup_pending: u32 = 0;
        var blocked: u32 = 0;
        for (ledger.pending.items) |entry| switch (entry.status) {
            .lookup => lookup_pending += 1,
            .blocked => blocked += 1,
        };
        // Saturating: `no_receipt` near the u64 limit is a display bound only.
        const count = ledger.no_receipt +| lookup_pending +| blocked;
        const reason: ?UnpricedReason = if (blocked > 0)
            .sign_in_cannot_look_up
        else if (lookup_pending > 0)
            .lookup_pending
        else if (ledger.no_receipt > 0)
            .no_receipt
        else
            null;
        return .{
            .availability = ledger.availability(),
            .totals = ledger.totals,
            .models = ledger.rows.items,
            .unpriced = .{
                .count = count,
                .reason = reason,
                .lookup_pending = lookup_pending,
                .sign_in_cannot_look_up = blocked,
                .no_receipt = ledger.no_receipt,
            },
            .active = @intCast(ledger.active.items.len),
            .pending = @intCast(ledger.pending.items.len),
            .incidents = @intCast(ledger.incidents.items.len),
        };
    }

    /// Entries waiting on a lookup or blocked, oldest first. Valid until the
    /// next step.
    pub fn waiting(ledger: *const Ledger) []const Pending {
        return ledger.pending.items;
    }

    pub fn incidentList(ledger: *const Ledger) []const Incident {
        return ledger.incidents.items;
    }

    /// Applies one event. Resets `out` first. Errors leave the ledger
    /// unchanged. With a trace writer (and trace code compiled in), writes
    /// the step's record; a failed write sets `out.trace_error`.
    pub fn step(ledger: *Ledger, event: Event, out: *Output, tracer: ?*trace.Writer) StepError!void {
        out.* = .{};
        switch (event) {
            .begin => |provider| try ledger.begin(provider, out),
            .finish_exact => |e| try ledger.finishExact(e.sequence, e.fact, out),
            .finish_lookup => |e| try ledger.finishLookup(e.sequence, e.request, out),
            .finish_unbilled => |sequence| try ledger.finishUnbilled(sequence, out),
            .finish_unpriced => |e| try ledger.finishUnpriced(e.sequence, e.at_ms, out),
            .set_credential => |digest| try ledger.setCredential(digest, out),
            .lookup_found => |e| try ledger.lookupFound(e.sequence, e.fact, out),
            .lookup_unauthorized => |sequence| try ledger.lookupUnauthorized(sequence, out),
            .lookup_rejected => |sequence| try ledger.lookupRejected(sequence, out),
            .lookup_retry => |sequence| try ledger.lookupRetry(sequence, out),
        }
        if (trace.on(tracer)) |writer| writeTrace(writer, ledger.trace_instance, out) catch |err| {
            out.trace_error = err;
        };
    }

    fn credentialOrdinal(ledger: *const Ledger) u32 {
        return if (ledger.credential) |credential| credential.ordinal else 0;
    }

    fn transition(ledger: *const Ledger, event: TraceEvent, call: Sequence, from: State, to: State) Transition {
        return .{
            .event = event,
            .call = call,
            .from = from,
            .to = to,
            .cred = ledger.credentialOrdinal(),
            .rows = @intCast(ledger.rows.items.len),
        };
    }

    fn activeIndex(ledger: *const Ledger, sequence: Sequence) ?usize {
        for (ledger.active.items, 0..) |entry, index| {
            if (entry.sequence == sequence) return index;
        }
        return null;
    }

    fn pendingIndex(ledger: *const Ledger, sequence: Sequence) ?usize {
        for (ledger.pending.items, 0..) |entry, index| {
            if (entry.sequence == sequence) return index;
        }
        return null;
    }

    fn idInUse(ledger: *const Ledger, id: GenerationId) bool {
        for (ledger.pending.items) |entry| if (entry.id.eql(id)) return true;
        return false;
    }

    /// Today's rule: dedupe on (time, completeness); when full, collapse to
    /// one `incomplete` incident at the newest time. Always marks the
    /// session incomplete. `occurred_at_ms` is validated non-negative.
    fn recordIncident(ledger: *Ledger, occurred_at_ms: i64) void {
        std.debug.assert(occurred_at_ms >= 0);
        ledger.incomplete = true;
        const completeness: Completeness = .incomplete;
        for (ledger.incidents.items) |incident| {
            if (incident.occurred_at_ms == occurred_at_ms and incident.completeness == completeness) return;
        }
        if (ledger.incidents.items.len == ledger.limits.max_incidents) {
            var newest = occurred_at_ms;
            for (ledger.incidents.items) |incident| newest = @max(newest, incident.occurred_at_ms);
            ledger.incidents.items.len = 1;
            ledger.incidents.items[0] = .{ .occurred_at_ms = newest, .completeness = .incomplete };
            return;
        }
        ledger.incidents.appendAssumeCapacity(.{ .occurred_at_ms = occurred_at_ms, .completeness = completeness });
    }

    /// A call that ends missing from the totals: counted and made visible.
    fn leaveUnpriced(ledger: *Ledger, next_no_receipt: u64, at_ms: i64) void {
        ledger.no_receipt = next_no_receipt;
        ledger.recordIncident(at_ms);
    }

    fn begin(ledger: *Ledger, provider: Provider, out: *Output) StepError!void {
        if (ledger.active.items.len == ledger.limits.max_active) return error.TooManyActive;
        const sequence = ledger.next_sequence;
        if (sequence == std.math.maxInt(Sequence)) return error.SequenceExhausted;
        ledger.next_sequence = sequence + 1;
        ledger.active.appendAssumeCapacity(.{ .sequence = sequence, .provider = provider });
        out.push(.persist_checkpoint);
        out.transition = ledger.transition(.begin, sequence, .idle, .active);
    }

    /// Removes a finished call. With none left in flight, every sequence
    /// issued so far is settled through (today's `settled_through_sequence`).
    fn endActive(ledger: *Ledger, index: usize) Active {
        const removed = ledger.active.orderedRemove(index);
        if (ledger.active.items.len == 0) ledger.settled_through = ledger.next_sequence - 1;
        return removed;
    }

    fn finishExact(ledger: *Ledger, sequence: Sequence, fact: Fact, out: *Output) StepError!void {
        const index = ledger.activeIndex(sequence) orelse return error.NotActive;
        try fact.validate();
        if (ledger.idInUse(fact.id)) return error.DuplicateGenerationId;
        const plan = try ledger.planAccept(fact, 0);
        _ = ledger.endActive(index);
        ledger.accept(.finish_exact, sequence, .active, fact, plan, out);
    }

    fn finishLookup(ledger: *Ledger, sequence: Sequence, request: LookupRequest, out: *Output) StepError!void {
        const index = ledger.activeIndex(sequence) orelse return error.NotActive;
        if (!request.valid()) return error.InvalidLookupRequest;
        const provider = ledger.active.items[index].provider;
        if (request.credential_source) |source| {
            if (!authorizesCredential(provider, source)) return error.InvalidLookupRequest;
        }
        if (ledger.idInUse(request.id)) return error.DuplicateGenerationId;
        const room = ledger.pending.items.len < ledger.limits.max_pending;
        // The persisted array's cap counts as spent budget, as in the model.
        const fits = ledger.fitsIdentifiers(request.identifierBytes()) and
            ledger.pending.items.len < ledger.limits.max_persisted_pending;
        if (room and fits) {
            _ = ledger.endActive(index);
            ledger.pending.appendAssumeCapacity(.init(sequence, provider, request));
            out.push(.persist_checkpoint);
            if (ledger.credential != null) out.push(.{ .start_lookup = sequence });
            out.transition = ledger.transition(.finish_lookup, sequence, .active, .lookup);
            return;
        }
        // The lookup list is full, or the identifier budget is spent: never
        // dropped silently.
        const next_no_receipt = std.math.add(u64, ledger.no_receipt, 1) catch return error.Overflow;
        _ = ledger.endActive(index);
        ledger.leaveUnpriced(next_no_receipt, request.observed_at_ms);
        out.push(.persist_checkpoint);
        out.transition = ledger.transition(.finish_lookup, sequence, .active, .unpriced);
        out.transition.?.incident = true;
        if (room) out.transition.?.budget = budget_waiting;
    }

    fn finishUnbilled(ledger: *Ledger, sequence: Sequence, out: *Output) StepError!void {
        const index = ledger.activeIndex(sequence) orelse return error.NotActive;
        _ = ledger.endActive(index);
        out.push(.persist_checkpoint);
        out.transition = ledger.transition(.finish_unbilled, sequence, .active, .unbilled);
    }

    fn finishUnpriced(ledger: *Ledger, sequence: Sequence, at_ms: i64, out: *Output) StepError!void {
        const index = ledger.activeIndex(sequence) orelse return error.NotActive;
        if (at_ms < 0) return error.InvalidTime;
        const next_no_receipt = std.math.add(u64, ledger.no_receipt, 1) catch return error.Overflow;
        _ = ledger.endActive(index);
        ledger.leaveUnpriced(next_no_receipt, at_ms);
        out.push(.persist_checkpoint);
        out.transition = ledger.transition(.finish_unpriced, sequence, .active, .unpriced);
        out.transition.?.incident = true;
    }

    /// The trace ordinal for `digest`: the one it got when first seen, or the
    /// next unused one. When the table is full the oldest digest that isn't
    /// current is forgotten; if it returns, it gets a fresh ordinal, which
    /// the model reads as a different credential. That is sound because a
    /// forgotten digest blocks nothing (blocked entries always belong to the
    /// current credential).
    fn ordinalFor(ledger: *Ledger, digest: Digest) StepError!u32 {
        for (ledger.known[0..ledger.known_count]) |known| {
            if (std.mem.eql(u8, &known.digest, &digest)) return known.ordinal;
        }
        const ordinal = ledger.next_ordinal;
        if (ordinal == std.math.maxInt(u32)) return error.CredentialOrdinalsExhausted;
        if (ledger.known_count == max_known_credentials) {
            const current = ledger.credentialOrdinal();
            const victim = for (ledger.known[0..ledger.known_count], 0..) |known, index| {
                if (known.ordinal != current) break index;
            } else unreachable; // At most one entry is current.
            std.mem.copyForwards(Credential, ledger.known[victim .. ledger.known_count - 1], ledger.known[victim + 1 .. ledger.known_count]);
            ledger.known_count -= 1;
        }
        ledger.known[ledger.known_count] = .{ .digest = digest, .ordinal = ordinal };
        ledger.known_count += 1;
        ledger.next_ordinal = ordinal + 1;
        return ordinal;
    }

    /// A different credential (or none) retries every entry it didn't
    /// block. The same credential again changes nothing.
    fn setCredential(ledger: *Ledger, digest: ?Digest, out: *Output) StepError!void {
        const same = if (ledger.credential) |current|
            (if (digest) |next| std.mem.eql(u8, &current.digest, &next) else false)
        else
            digest == null;
        if (!same) {
            ledger.credential = if (digest) |next| .{ .digest = next, .ordinal = try ledger.ordinalFor(next) } else null;
        }
        var moved: u32 = 0;
        for (ledger.pending.items) |*entry| {
            if (entry.status != .blocked) continue;
            const refused_by = entry.blocked_by.?;
            const refused_now = if (digest) |next| std.mem.eql(u8, &refused_by, &next) else false;
            if (refused_now) continue;
            entry.status = .lookup;
            entry.blocked_by = null;
            moved += 1;
        }
        if (!same and digest != null) {
            for (ledger.pending.items) |entry| {
                if (entry.status == .lookup) out.push(.{ .start_lookup = entry.sequence });
            }
        }
        out.transition = .{
            .event = .set_credential,
            .call = 0,
            .from = null,
            .to = null,
            .cred = ledger.credentialOrdinal(),
            .rows = @intCast(ledger.rows.items.len),
            .moved = moved,
        };
    }

    /// The entry in `lookup` for a lookup answer, under a credential.
    fn lookingUp(ledger: *const Ledger, sequence: Sequence) StepError!usize {
        if (ledger.credential == null) return error.NoCredential;
        const index = ledger.pendingIndex(sequence) orelse return error.NotLookingUp;
        if (ledger.pending.items[index].status != .lookup) return error.NotLookingUp;
        return index;
    }

    fn lookupFound(ledger: *Ledger, sequence: Sequence, fact: Fact, out: *Output) StepError!void {
        const index = try ledger.lookingUp(sequence);
        try fact.validate();
        if (!ledger.pending.items[index].id.eql(fact.id)) return error.GenerationIdMismatch;
        // The entry's bytes are freed by this step, so a new row may use them.
        const plan = try ledger.planAccept(fact, ledger.pending.items[index].identifierBytes());
        _ = ledger.pending.orderedRemove(index);
        ledger.accept(.lookup_found, sequence, .lookup, fact, plan, out);
    }

    fn lookupUnauthorized(ledger: *Ledger, sequence: Sequence, out: *Output) StepError!void {
        const index = try ledger.lookingUp(sequence);
        const entry = &ledger.pending.items[index];
        entry.status = .blocked;
        entry.blocked_by = ledger.credential.?.digest;
        out.transition = ledger.transition(.lookup_unauthorized, sequence, .lookup, .blocked);
    }

    fn lookupRejected(ledger: *Ledger, sequence: Sequence, out: *Output) StepError!void {
        const index = try ledger.lookingUp(sequence);
        const next_no_receipt = std.math.add(u64, ledger.no_receipt, 1) catch return error.Overflow;
        const removed = ledger.pending.orderedRemove(index);
        ledger.leaveUnpriced(next_no_receipt, removed.observed_at_ms);
        out.push(.persist_checkpoint);
        out.transition = ledger.transition(.lookup_rejected, sequence, .lookup, .unpriced);
        out.transition.?.incident = true;
    }

    fn lookupRetry(ledger: *Ledger, sequence: Sequence, out: *Output) StepError!void {
        _ = try ledger.lookingUp(sequence);
        out.push(.{ .start_lookup = sequence });
        out.transition = ledger.transition(.lookup_retry, sequence, .lookup, .lookup);
    }

    const RowPlan = struct {
        /// Null: insert a new row.
        index: ?usize,
        totals: Totals,
        row_totals: Totals,
    };

    const SettlePlan = union(enum) {
        row: RowPlan,
        /// The fact's model needs a row and the rows are full, or the
        /// identifier budget is spent (`budget_row`).
        no_row: u2,
    };

    /// Everything a settle would change, computed without changing anything.
    /// `budget_free` is the identifier budget left for a new row, or null when
    /// the settle frees more than a row needs (a restored staged fact).
    fn planSettle(ledger: *const Ledger, fact: Fact, budget_free: ?usize) error{Overflow}!SettlePlan {
        const index: ?usize = for (ledger.rows.items, 0..) |*row, i| {
            if (std.mem.eql(u8, row.name(), fact.model)) break i;
        } else null;
        if (index == null and ledger.rows.items.len == ledger.limits.max_models) return .{ .no_row = 0 };
        if (index == null) {
            if (budget_free) |free| if (fact.model.len > free) return .{ .no_row = budget_row };
        }
        const row_before: Totals = if (index) |i| ledger.rows.items[i].totals else .{};
        return .{ .row = .{
            .index = index,
            .totals = try ledger.totals.add(fact),
            .row_totals = try row_before.add(fact),
        } };
    }

    /// The settle for a fact arriving now, with `freed` identifier bytes
    /// leaving the ledger in the same step.
    fn planAccept(ledger: *const Ledger, fact: Fact, freed: usize) StepError!SettlePlan {
        const used = ledger.identifierBytes() -| freed;
        const plan = try ledger.planSettle(fact, ledger.limits.max_identifier_bytes -| used);
        if (plan == .no_row) _ = std.math.add(u64, ledger.no_receipt, 1) catch return error.Overflow;
        return plan;
    }

    fn commitSettle(ledger: *Ledger, sequence: Sequence, fact: Fact, plan: RowPlan) void {
        ledger.totals = plan.totals;
        if (plan.index) |index| {
            const row = &ledger.rows.items[index];
            row.totals = plan.row_totals;
            row.first_sequence = @min(row.first_sequence, sequence);
        } else {
            ledger.rows.appendAssumeCapacity(.{ .model = .init(fact.model), .first_sequence = sequence, .totals = plan.row_totals });
        }
        sortRows(ledger.rows.items);
    }

    /// Settles the fact into the totals once, or leaves it unpriced when its
    /// model finds no row, as `plan` decided.
    fn accept(ledger: *Ledger, event: TraceEvent, sequence: Sequence, from: State, fact: Fact, plan: SettlePlan, out: *Output) void {
        out.push(.persist_checkpoint);
        switch (plan) {
            .row => |row| {
                ledger.commitSettle(sequence, fact, row);
                out.transition = ledger.transition(event, sequence, from, .settled);
                out.transition.?.applied = true;
            },
            .no_row => |budget| {
                // Checked in planAccept.
                ledger.leaveUnpriced(ledger.no_receipt + 1, fact.created_at_ms);
                out.transition = ledger.transition(event, sequence, from, .unpriced);
                out.transition.?.incident = true;
                out.transition.?.budget = budget;
            },
        }
    }

    // Identifier budget --------------------------------------------------------

    /// Bytes older readers count against `max_identifier_bytes`: model
    /// names, and waiting entries' id, origin, team, and account
    /// (`validateSnapshotContract`).
    fn identifierBytes(ledger: *const Ledger) usize {
        var total: usize = 0;
        for (ledger.rows.items) |*row| total += row.name().len;
        for (ledger.pending.items) |*entry| total += entry.identifierBytes();
        return total;
    }

    fn fitsIdentifiers(ledger: *const Ledger, extra: usize) bool {
        return ledger.identifierBytes() + extra <= ledger.limits.max_identifier_bytes;
    }

    // Restore -------------------------------------------------------------------

    pub const RestoreError = error{
        /// `restore` runs once, on a ledger no event has touched.
        AlreadyStarted,
        /// The saved state breaks a rule the ledger keeps: a bound, a
        /// sequence, an id, a field, or the identifier budget.
        InvalidRestore,
    };

    /// Loads a saved session. Calls that were waiting come back in
    /// `lookup` (blocking is runtime-only), and earlier calls survive as
    /// rows. A snapshot an older binary saved may still stage facts for its
    /// profile ledger: each settles into the totals now, or is left unpriced
    /// with an incident when its model finds no row, so no call goes missing.
    /// Asks for a checkpoint only when it settled one. With a trace writer,
    /// writes one `restore` record per restored waiting or staged call.
    pub fn restore(ledger: *Ledger, saved: Restored, out: *Output, tracer: ?*trace.Writer) RestoreError!void {
        out.* = .{};
        if (ledger.next_sequence != 1 or ledger.active.items.len != 0 or ledger.pending.items.len != 0 or
            ledger.rows.items.len != 0 or ledger.incidents.items.len != 0 or ledger.credential != null)
        {
            return error.AlreadyStarted;
        }
        try validateRestored(ledger.limits, saved);

        ledger.next_sequence = saved.next_sequence;
        ledger.settled_through = saved.settled_through;
        ledger.totals = saved.totals;
        ledger.activity = saved.activity;
        ledger.legacy = saved.availability == .legacy;
        ledger.incomplete = saved.availability == .incomplete;
        for (saved.rows) |row| {
            ledger.rows.appendAssumeCapacity(.{ .model = .init(row.model), .first_sequence = row.first_sequence, .totals = row.totals });
        }
        sortRows(ledger.rows.items);
        for (saved.pending) |entry| {
            ledger.pending.appendAssumeCapacity(.init(entry.sequence, entry.provider, entry.request));
        }
        ledger.incidents.appendSliceAssumeCapacity(saved.incidents);
        if (saved.incidents.len > 0) ledger.incomplete = true;
        // Bounded by `max_persisted_pending` (validated), at most the ceiling.
        var outcomes: [Limits.ceiling]State = undefined;
        for (saved.backlog, 0..) |entry, index| outcomes[index] = ledger.settleRestored(entry);
        if (saved.backlog.len > 0) out.push(.persist_checkpoint);

        if (trace.on(tracer)) |writer| ledger.writeRestored(writer, saved.backlog, outcomes[0..saved.backlog.len]) catch |err| {
            out.trace_error = err;
        };
    }

    /// Settles a staged fact from an older binary's snapshot, as its publish
    /// would have, and returns where the call ended. Needs no identifier
    /// bytes: a new row's name is smaller than the staged fact it replaces.
    /// A total that would overflow leaves the call unpriced instead.
    fn settleRestored(ledger: *Ledger, entry: Restored.StagedFact) State {
        const plan = ledger.planSettle(entry.fact, null) catch SettlePlan{ .no_row = 0 };
        switch (plan) {
            .row => |row| {
                ledger.commitSettle(entry.sequence, entry.fact, row);
                return .settled;
            },
            .no_row => {
                // At most `max_persisted_pending` restored facts: no overflow.
                ledger.leaveUnpriced(ledger.no_receipt + 1, entry.fact.created_at_ms);
                return .unpriced;
            },
        }
    }

    fn writeRestored(
        ledger: *const Ledger,
        writer: *trace.Writer,
        staged: []const Restored.StagedFact,
        outcomes: []const State,
    ) std.Io.Writer.Error!void {
        // A summary first (the restored rows), then one record per call in
        // sequence order.
        var summary: Output = .{};
        summary.transition = .{ .event = .restore, .call = 0, .from = null, .to = null, .cred = 0, .rows = @intCast(ledger.rows.items.len) };
        try writeTrace(writer, ledger.trace_instance, &summary);
        var last: Sequence = 0;
        while (true) {
            var next: ?Sequence = null;
            var state: State = .lookup;
            for (ledger.pending.items) |entry| {
                if (entry.sequence > last and (next == null or entry.sequence < next.?)) {
                    next = entry.sequence;
                    state = .lookup;
                }
            }
            for (staged, outcomes) |entry, outcome| {
                if (entry.sequence > last and (next == null or entry.sequence < next.?)) {
                    next = entry.sequence;
                    state = outcome;
                }
            }
            const call = next orelse return;
            var out: Output = .{};
            out.transition = ledger.transition(.restore, call, state, state);
            try writeTrace(writer, ledger.trace_instance, &out);
            last = call;
        }
    }

    // Activity --------------------------------------------------------------------

    /// Adds activity the host measured (API time, committed lines). Not a
    /// model step: activity rides along in the next checkpoint. An overflow
    /// saturates and marks the metric incomplete, as today.
    pub fn recordActivity(ledger: *Ledger, delta: ActivityDelta) void {
        const a = &ledger.activity;
        a.api_duration_ms, const api_overflow = @addWithOverflow(a.api_duration_ms, delta.api_ms);
        if (api_overflow != 0) {
            a.api_duration_ms = std.math.maxInt(u64);
            a.api_duration_complete = false;
        }
        a.lines_added, const added_overflow = @addWithOverflow(a.lines_added, delta.lines_added);
        a.lines_removed, const removed_overflow = @addWithOverflow(a.lines_removed, delta.lines_removed);
        if (added_overflow != 0) a.lines_added = std.math.maxInt(u64);
        if (removed_overflow != 0) a.lines_removed = std.math.maxInt(u64);
        if (added_overflow != 0 or removed_overflow != 0 or delta.code_incomplete) a.code_complete = false;
    }
};

/// A trace record's `budget`: which identifier-budget checks refused.
const budget_waiting: u2 = 1;
const budget_row: u2 = 2;

/// Session activity that rides along in checkpoints; the model doesn't need
/// it. `wall_duration_ms` is the time saved before this run.
pub const Activity = struct {
    api_duration_ms: u64 = 0,
    api_duration_complete: bool = true,
    wall_duration_ms: u64 = 0,
    wall_duration_complete: bool = true,
    code_complete: bool = true,
    lines_added: u64 = 0,
    lines_removed: u64 = 0,

    const unknown: Activity = .{ .api_duration_complete = false, .wall_duration_complete = false, .code_complete = false };
};

pub const ActivityDelta = struct {
    api_ms: u64 = 0,
    lines_added: u64 = 0,
    lines_removed: u64 = 0,
    code_incomplete: bool = false,
};

/// A saved session, as `Ledger.restore` takes it. Every slice and string is
/// borrowed for the call.
pub const Restored = struct {
    availability: Availability,
    next_sequence: Sequence,
    settled_through: Sequence,
    totals: Totals,
    rows: []const Row = &.{},
    pending: []const Waiting = &.{},
    /// Facts an older binary staged for its profile ledger; `restore`
    /// settles them.
    backlog: []const StagedFact = &.{},
    incidents: []const Incident = &.{},
    activity: Activity = .{},

    pub const Row = struct { model: []const u8, first_sequence: Sequence, totals: Totals };
    pub const Waiting = struct { sequence: Sequence, provider: Provider, request: LookupRequest };
    pub const StagedFact = struct { sequence: Sequence, fact: Fact };
};

fn validateRestored(limits: Limits, saved: Restored) Ledger.RestoreError!void {
    const bad = error.InvalidRestore;
    if (saved.next_sequence == 0 or saved.next_sequence == std.math.maxInt(Sequence)) return bad;
    if (saved.settled_through >= saved.next_sequence) return bad;
    if (saved.rows.len > limits.max_models or saved.pending.len > limits.max_pending or
        saved.incidents.len > limits.max_incidents or
        saved.pending.len + saved.backlog.len > limits.max_persisted_pending)
    {
        return bad;
    }
    if (!std.math.isFinite(saved.totals.total_cost) or saved.totals.total_cost < 0) return bad;
    if (saved.availability == .pending and saved.pending.len == 0) return bad;
    if (saved.availability == .complete and saved.pending.len != 0) return bad;
    var bytes: usize = 0;
    for (saved.rows, 0..) |row, index| {
        if (!validText(row.model, max_model_bytes)) return bad;
        if (row.first_sequence == 0 or row.first_sequence >= saved.next_sequence) return bad;
        for (saved.rows[0..index]) |prior| {
            if (std.mem.eql(u8, prior.model, row.model) or prior.first_sequence == row.first_sequence) return bad;
        }
        bytes += row.model.len;
    }
    for (saved.pending, 0..) |entry, index| {
        if (!entry.request.valid()) return bad;
        if (entry.request.credential_source) |source| {
            if (!authorizesCredential(entry.provider, source)) return bad;
        }
        if (entry.sequence == 0 or entry.sequence >= saved.next_sequence) return bad;
        for (saved.pending[0..index]) |prior| {
            if (prior.sequence == entry.sequence or prior.request.id.eql(entry.request.id)) return bad;
        }
        bytes += entry.request.identifierBytes();
    }
    for (saved.backlog, 0..) |entry, index| {
        entry.fact.validate() catch return bad;
        if (entry.sequence == 0 or entry.sequence >= saved.next_sequence) return bad;
        for (saved.backlog[0..index]) |prior| {
            if (prior.sequence == entry.sequence or prior.fact.id.eql(entry.fact.id)) return bad;
        }
        for (saved.pending) |waiting| {
            if (waiting.sequence == entry.sequence or waiting.request.id.eql(entry.fact.id)) return bad;
        }
        bytes += GenerationId.length + entry.fact.model.len;
    }
    for (saved.incidents) |incident| if (incident.occurred_at_ms < 0) return bad;
    if (bytes > limits.max_identifier_bytes) return bad;
}

/// Rows stay ordered by first sequence, as older readers require.
fn sortRows(rows: []ModelRow) void {
    var index: usize = 1;
    while (index < rows.len) : (index += 1) {
        var current = index;
        while (current > 0 and rows[current - 1].first_sequence > rows[current].first_sequence) : (current -= 1) {
            std.mem.swap(ModelRow, &rows[current - 1], &rows[current]);
        }
    }
}

/// Writes the step in `out` as one trace line for machine `ledger`, instance
/// `session`. Data holds only sequence numbers, ordinals, counts, and flags.
/// `instance` names the core's process: each process's ledger is one
/// behavior of the model (see `Ledger.trace_instance`).
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, out: *const Output) std.Io.Writer.Error!void {
    const t = out.transition orelse return;
    var fields: [7]trace.Field = undefined;
    var count: usize = 0;
    fields[count] = .{ .name = "call", .value = .{ .int = std.math.cast(i64, t.call) orelse return error.WriteFailed } };
    count += 1;
    fields[count] = .{ .name = "cred", .value = .{ .int = t.cred } };
    count += 1;
    fields[count] = .{ .name = "rows", .value = .{ .int = t.rows } };
    count += 1;
    if (t.event == .set_credential) {
        fields[count] = .{ .name = "moved", .value = .{ .int = t.moved } };
        count += 1;
    } else if (t.call != 0) {
        fields[count] = .{ .name = "incident", .value = .{ .boolean = t.incident } };
        fields[count + 1] = .{ .name = "applied", .value = .{ .boolean = t.applied } };
        fields[count + 2] = .{ .name = "budget", .value = .{ .int = t.budget } };
        count += 3;
    }
    var effect_names: [max_effects][]const u8 = undefined;
    for (out.effects(), 0..) |effect, index| effect_names[index] = @tagName(effect);
    try writer.write(.{
        .machine = "ledger",
        .instance = instance,
        .event = @tagName(t.event),
        .from = if (t.from) |s| @tagName(s) else "-",
        .to = if (t.to) |s| @tagName(s) else "-",
        .effects = effect_names[0..out.effect_count],
        .data = fields[0..count],
    });
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;

const test_model = "openai/gpt-4.1-nano";

/// `gen_` plus the sequence in Crockford base32, padded to 26 characters.
fn testId(n: u64) GenerationId {
    const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    var bytes: [GenerationId.length]u8 = undefined;
    @memcpy(bytes[0..4], "gen_");
    var value = n;
    var index: usize = GenerationId.length;
    while (index > 4) : (index -= 1) {
        bytes[index - 1] = alphabet[@intCast(value % 32)];
        value /= 32;
    }
    return GenerationId.parse(&bytes) catch unreachable;
}

fn testFact(n: u64, model: []const u8, cost: f64) Fact {
    return .{
        .id = testId(n),
        .created_at_ms = @intCast(1_000 + n),
        .model = model,
        .total_cost = cost,
        .input_tokens = 10,
        .output_tokens = 5,
        .cache_read_tokens = 2,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 1,
    };
}

fn testRequest(n: u64) LookupRequest {
    return .{
        .id = testId(n),
        .origin = "https://ai-gateway.vercel.sh",
        .team = "team_lab",
        .credential_source = .ai_gateway_api_key,
        .account_id = "acct_1",
        .observed_at_ms = @intCast(2_000 + n),
    };
}

const login = blk: {
    @setEvalBranchQuota(100_000);
    break :blk credentialDigest("fx-login-token");
};
const api_key = blk: {
    @setEvalBranchQuota(100_000);
    break :blk credentialDigest("ai-gateway-api-key");
};

/// A ledger with a shadow copy of the model's variables, kept from the
/// transitions alone, so every step can be checked against the model's
/// invariants and the transition can be checked against the ledger.
const Harness = struct {
    ledger: Ledger,
    out: Output = .{},
    calls: std.AutoHashMapUnmanaged(Sequence, Shadow) = .empty,

    const Shadow = struct {
        state: State,
        totals: u8 = 0,
        incident: bool = false,
    };

    fn init(limits: Limits) !Harness {
        return .{ .ledger = try .init(testing.allocator, limits, .fresh) };
    }

    fn deinit(h: *Harness) void {
        h.calls.deinit(testing.allocator);
        h.ledger.deinit(testing.allocator);
    }

    fn step(h: *Harness, event: Event) !void {
        const before = fingerprint(&h.ledger);
        h.ledger.step(event, &h.out, null) catch |err| {
            try testing.expectEqual(before, fingerprint(&h.ledger));
            return err;
        };
        const t = h.out.transition.?;
        try testing.expectEqualStrings(@tagName(@as(EventTag, event)), @tagName(t.event));
        if (t.event == .set_credential) {
            try testing.expectEqual(@as(Sequence, 0), t.call);
            try testing.expect(t.from == null and t.to == null);
            // SetCredential: blocked calls the new credential didn't refuse move.
            var moved: u32 = 0;
            var it = h.calls.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.state != .blocked) continue;
                const index = h.ledger.pendingIndex(entry.key_ptr.*).?;
                if (h.ledger.pending.items[index].status == .lookup) {
                    entry.value_ptr.state = .lookup;
                    moved += 1;
                }
            }
            try testing.expectEqual(t.moved, moved);
        } else {
            const entry = try h.calls.getOrPut(testing.allocator, t.call);
            if (!entry.found_existing) entry.value_ptr.* = .{ .state = .idle };
            const shadow = entry.value_ptr;
            try testing.expectEqual(shadow.state, t.from.?);
            shadow.state = t.to.?;
            if (t.applied) shadow.totals += 1;
            if (t.incident) shadow.incident = true;
        }
        try h.checkInvariants();
    }

    /// Restores `saved` and seeds the shadow from what came back. A staged
    /// fact settled exactly when its model has a row now (the tests never
    /// overflow a total).
    fn restore(h: *Harness, saved: Restored) !void {
        try h.ledger.restore(saved, &h.out, null);
        for (h.ledger.waiting()) |entry| try h.calls.put(testing.allocator, entry.sequence, .{ .state = .lookup });
        for (saved.backlog) |entry| {
            const has_row = for (h.ledger.rows.items) |*row| {
                if (std.mem.eql(u8, row.name(), entry.fact.model)) break true;
            } else false;
            const shadow: Shadow = if (has_row) .{ .state = .settled, .totals = 1 } else .{ .state = .unpriced, .incident = true };
            try h.calls.put(testing.allocator, entry.sequence, shadow);
        }
        try h.checkInvariants();
    }

    fn begin(h: *Harness) !Sequence {
        try h.step(.{ .begin = .gateway });
        return h.out.transition.?.call;
    }

    fn state(h: *const Harness, sequence: Sequence) State {
        return if (h.calls.get(sequence)) |shadow| shadow.state else .idle;
    }

    fn effectCount(h: *const Harness, tag: std.meta.Tag(Effect)) usize {
        var count: usize = 0;
        for (h.out.effects()) |effect| count += @intFromBool(effect == tag);
        return count;
    }

    /// Every invariant of the formal model, plus the snapshot contract older
    /// readers enforce on rows and totals.
    fn checkInvariants(h: *const Harness) !void {
        const ledger = &h.ledger;
        const limits = ledger.limits;
        // PendingBounded, RowsBounded.
        try testing.expect(ledger.pending.items.len <= limits.max_pending);
        try testing.expect(ledger.pending.items.len <= limits.max_persisted_pending);
        try testing.expect(ledger.rows.items.len <= limits.max_models);
        try testing.expect(ledger.incidents.items.len <= limits.max_incidents);
        try testing.expect(ledger.active.items.len <= limits.max_active);

        var it = h.calls.iterator();
        while (it.next()) |entry| {
            const sequence = entry.key_ptr.*;
            const shadow = entry.value_ptr.*;
            // NoDoubleCount.
            try testing.expect(shadow.totals <= 1);
            // SettledCountedOnce.
            try testing.expectEqual(shadow.state == .settled, shadow.totals == 1);
            // NeverSilent: the incident keeps the session incomplete.
            if (shadow.state == .unpriced) {
                try testing.expect(shadow.incident);
                try testing.expect(ledger.incomplete);
            }
            // UnpricedNotCounted.
            if (shadow.state == .unpriced) try testing.expectEqual(@as(u8, 0), shadow.totals);
            // The shadow and the ledger agree on where each call is.
            const in_active = ledger.activeIndex(sequence) != null;
            const in_pending = ledger.pendingIndex(sequence);
            try testing.expectEqual(shadow.state == .active, in_active);
            try testing.expectEqual(shadow.state == .lookup or shadow.state == .blocked, in_pending != null);
            if (in_pending) |index| {
                const status = ledger.pending.items[index].status;
                try testing.expectEqual(shadow.state == .blocked, status == .blocked);
            }
        }
        // BlockedOnlyForCurrentCred.
        for (ledger.pending.items) |entry| {
            if (entry.status != .blocked) {
                try testing.expect(entry.blocked_by == null);
                continue;
            }
            const current = ledger.credential orelse return error.TestBlockedWithoutCredential;
            try testing.expectEqualSlices(u8, &current.digest, &entry.blocked_by.?);
        }
        // The identifier budget older readers enforce.
        try testing.expect(ledger.identifierBytes() <= limits.max_identifier_bytes);
        // Settled through every sequence when nothing is in flight.
        try testing.expect(ledger.settled_through < ledger.next_sequence);
        if (ledger.active.items.len == 0 and ledger.next_sequence > 1 and h.calls.count() > 0) {
            try testing.expectEqual(ledger.next_sequence - 1, ledger.settled_through);
        }
        // Rows are ordered and add up to the totals.
        var sum: Totals = .{};
        for (ledger.rows.items, 0..) |row, index| {
            if (index > 0) try testing.expect(ledger.rows.items[index - 1].first_sequence < row.first_sequence);
            try testing.expect(row.first_sequence < ledger.next_sequence);
            sum.total_cost += row.totals.total_cost;
            sum.input_tokens += row.totals.input_tokens;
            sum.output_tokens += row.totals.output_tokens;
            sum.cache_read_tokens += row.totals.cache_read_tokens;
            sum.cache_write_tokens += row.totals.cache_write_tokens;
            sum.billable_web_search_calls += row.totals.billable_web_search_calls;
        }
        const totals = ledger.totals;
        try testing.expectApproxEqAbs(totals.total_cost, sum.total_cost, @max(1e-12, totals.total_cost * 1e-12));
        try testing.expectEqual(totals.input_tokens, sum.input_tokens);
        try testing.expectEqual(totals.output_tokens, sum.output_tokens);
        try testing.expectEqual(totals.cache_read_tokens, sum.cache_read_tokens);
        try testing.expectEqual(totals.cache_write_tokens, sum.cache_write_tokens);
        try testing.expectEqual(totals.billable_web_search_calls, sum.billable_web_search_calls);
        // Availability as today.
        const expected: Availability = if (ledger.incomplete) .incomplete else if (ledger.legacy) .legacy else if (ledger.pending.items.len > 0) .pending else .complete;
        try testing.expectEqual(expected, ledger.availability());
    }
};

/// A hash of every meaningful field, to prove refused steps change nothing.
fn fingerprint(ledger: *const Ledger) u64 {
    var h = std.hash.Wyhash.init(0);
    const scalar = struct {
        fn add(hasher: *std.hash.Wyhash, value: anytype) void {
            hasher.update(std.mem.asBytes(&value));
        }
    }.add;
    scalar(&h, ledger.next_sequence);
    scalar(&h, ledger.no_receipt);
    scalar(&h, ledger.incomplete);
    scalar(&h, ledger.next_ordinal);
    scalar(&h, ledger.known_count);
    scalar(&h, ledger.credentialOrdinal());
    scalar(&h, ledger.totals.total_cost);
    scalar(&h, ledger.totals.input_tokens);
    scalar(&h, ledger.totals.output_tokens);
    scalar(&h, ledger.totals.reasoning_tokens orelse std.math.maxInt(u64));
    scalar(&h, ledger.totals.request_count orelse std.math.maxInt(u64));
    for (ledger.active.items) |entry| scalar(&h, entry.sequence);
    for (ledger.pending.items) |entry| {
        scalar(&h, entry.sequence);
        scalar(&h, entry.status);
        h.update(&entry.id.bytes);
    }
    for (ledger.incidents.items) |incident| scalar(&h, incident.occurred_at_ms);
    for (ledger.rows.items) |row| {
        scalar(&h, row.first_sequence);
        scalar(&h, row.totals.input_tokens);
        h.update(row.model.slice());
    }
    return h.final();
}

test "begin reserves sequences from 1 and asks for a checkpoint first" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    try testing.expectEqual(@as(Sequence, 1), try h.begin());
    try testing.expectEqual(@as(usize, 1), h.effectCount(.persist_checkpoint));
    try testing.expectEqual(@as(Sequence, 2), try h.begin());
    try testing.expectEqual(State.active, h.state(2));
    try testing.expectEqual(@as(u32, 2), h.ledger.view().active);
}

test "begin refuses past max_active, and the refusal changes nothing" {
    var h: Harness = try .init(.{ .max_active = 2 });
    defer h.deinit();
    _ = try h.begin();
    _ = try h.begin();
    try testing.expectError(error.TooManyActive, h.step(.{ .begin = .codex }));
    try h.step(.{ .finish_unbilled = 1 });
    try testing.expectEqual(@as(Sequence, 3), try h.begin());
}

test "the last sequence is never handed out" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    h.ledger.next_sequence = std.math.maxInt(Sequence) - 1;
    _ = try h.begin();
    try testing.expectError(error.SequenceExhausted, h.step(.{ .begin = .gateway }));
}

test "an exact fact settles into the totals once" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const call = try h.begin();
    try h.step(.{ .finish_exact = .{ .sequence = call, .fact = testFact(call, test_model, 0.25) } });
    try testing.expectEqual(State.settled, h.state(call));
    try testing.expect(h.out.transition.?.applied);
    try testing.expect(!h.out.transition.?.incident);
    try testing.expectEqual(@as(usize, 1), h.out.effects().len);
    try testing.expectEqual(@as(usize, 1), h.effectCount(.persist_checkpoint));
    const view = h.ledger.view();
    try testing.expectEqual(@as(f64, 0.25), view.totals.total_cost);
    try testing.expectEqual(@as(u64, 10), view.totals.input_tokens);
    try testing.expectEqual(@as(?u64, 3), view.totals.reasoning_tokens);
    try testing.expectEqual(@as(?u64, 1), view.totals.request_count);
    try testing.expectEqual(@as(usize, 1), view.models.len);
    try testing.expectEqualStrings(test_model, view.models[0].name());
    try testing.expectEqual(Availability.complete, view.availability);

    // The call is finished: it settles once.
    try testing.expectError(error.NotActive, h.step(.{ .finish_exact = .{ .sequence = call, .fact = testFact(call + 1, test_model, 1) } }));
}

test "exact settlement never needs a lookup slot" {
    var h: Harness = try .init(.{ .max_pending = 2 });
    defer h.deinit();
    const a = try h.begin();
    const b = try h.begin();
    const c = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try h.step(.{ .finish_lookup = .{ .sequence = b, .request = testRequest(b) } });
    try testing.expectEqual(@as(u32, 2), h.ledger.view().pending);
    try h.step(.{ .finish_exact = .{ .sequence = c, .fact = testFact(c, test_model, 0.5) } });
    try testing.expectEqual(State.settled, h.state(c));
    try testing.expectEqual(@as(f64, 0.5), h.ledger.view().totals.total_cost);
    try testing.expectEqual(Availability.pending, h.ledger.availability());
}

test "a lookup starts only when there is a credential" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const a = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try testing.expectEqual(State.lookup, h.state(a));
    try testing.expectEqual(@as(usize, 0), h.effectCount(.start_lookup));
    try testing.expectEqual(Availability.pending, h.ledger.availability());
    try testing.expectEqual(UnpricedReason.lookup_pending, h.ledger.view().unpriced.reason.?);
    try testing.expectError(error.NoCredential, h.step(.{ .lookup_retry = a }));

    try h.step(.{ .set_credential = api_key });
    try testing.expectEqual(@as(usize, 1), h.effectCount(.start_lookup));
    try testing.expectEqual(a, h.out.effects()[0].start_lookup);

    const b = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = b, .request = testRequest(b) } });
    try testing.expectEqual(@as(usize, 1), h.effectCount(.start_lookup));
    const stored = h.ledger.waiting()[1];
    try testing.expectEqualStrings("https://ai-gateway.vercel.sh", stored.originText());
    try testing.expectEqualStrings("team_lab", stored.teamText().?);
    try testing.expectEqualStrings("acct_1", stored.accountText().?);
    try testing.expectEqual(Provider.gateway, stored.provider);
}

test "a full lookup list makes the call unpriced with an incident, never silently" {
    var h: Harness = try .init(.{ .max_pending = 1 });
    defer h.deinit();
    const a = try h.begin();
    const b = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try h.step(.{ .finish_lookup = .{ .sequence = b, .request = testRequest(b) } });
    try testing.expectEqual(State.unpriced, h.state(b));
    try testing.expect(h.out.transition.?.incident);
    const view = h.ledger.view();
    try testing.expectEqual(Availability.incomplete, view.availability);
    try testing.expectEqual(@as(u64, 1), view.unpriced.no_receipt);
    try testing.expectEqual(@as(u64, 2), view.unpriced.count);
    try testing.expectEqual(@as(i64, @intCast(2_000 + b)), h.ledger.incidentList()[0].occurred_at_ms);
}

test "unbilled calls change nothing else; unpriced ones record an incident" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const a = try h.begin();
    const b = try h.begin();
    try h.step(.{ .finish_unbilled = a });
    try testing.expectEqual(State.unbilled, h.state(a));
    try testing.expectEqual(Availability.complete, h.ledger.availability());
    try testing.expectError(error.NotActive, h.step(.{ .finish_unbilled = a }));
    try testing.expectError(error.InvalidTime, h.step(.{ .finish_unpriced = .{ .sequence = b, .at_ms = -1 } }));
    try h.step(.{ .finish_unpriced = .{ .sequence = b, .at_ms = 77 } });
    try testing.expectEqual(State.unpriced, h.state(b));
    const view = h.ledger.view();
    try testing.expectEqual(Availability.incomplete, view.availability);
    try testing.expectEqual(UnpricedReason.no_receipt, view.unpriced.reason.?);
    try testing.expectEqual(@as(i64, 77), h.ledger.incidentList()[0].occurred_at_ms);
    try testing.expectError(error.NotActive, h.step(.{ .finish_exact = .{ .sequence = 99, .fact = testFact(99, test_model, 1) } }));
}

test "generation ids are gen_ plus 26 Crockford base32 characters" {
    _ = try GenerationId.parse("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV");
    for ([_][]const u8{
        "",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FA",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAVX",
        "gem_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAI",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAL",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAO",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAU",
        "gen_01arz3ndektsv4rrffq69g5fav",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FA-",
    }) |bad| try testing.expectError(error.InvalidGenerationId, GenerationId.parse(bad));
}

test "facts are validated before anything changes" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const call = try h.begin();
    const good = testFact(call, test_model, 0.1);
    const cases = [_]struct { fact: Fact, err: StepError }{
        .{ .fact = blk: {
            var f = good;
            f.model = "";
            break :blk f;
        }, .err = error.InvalidModel },
        .{ .fact = blk: {
            var f = good;
            f.model = "has space";
            break :blk f;
        }, .err = error.InvalidModel },
        .{ .fact = blk: {
            var f = good;
            f.model = &([_]u8{'m'} ** (max_model_bytes + 1));
            break :blk f;
        }, .err = error.InvalidModel },
        .{ .fact = blk: {
            var f = good;
            f.total_cost = -0.01;
            break :blk f;
        }, .err = error.InvalidCost },
        .{ .fact = blk: {
            var f = good;
            f.total_cost = std.math.nan(f64);
            break :blk f;
        }, .err = error.InvalidCost },
        .{ .fact = blk: {
            var f = good;
            f.total_cost = std.math.inf(f64);
            break :blk f;
        }, .err = error.InvalidCost },
        .{ .fact = blk: {
            var f = good;
            f.created_at_ms = -1;
            break :blk f;
        }, .err = error.InvalidTime },
        .{ .fact = blk: {
            var f = good;
            f.cache_read_tokens = f.input_tokens + 1;
            break :blk f;
        }, .err = error.CacheExceedsInput },
        .{ .fact = blk: {
            var f = good;
            f.cache_write_tokens = f.input_tokens + 1;
            break :blk f;
        }, .err = error.CacheExceedsInput },
        .{ .fact = blk: {
            var f = good;
            f.reasoning_tokens = f.output_tokens + 1;
            break :blk f;
        }, .err = error.ReasoningExceedsOutput },
    };
    for (cases) |case| {
        try testing.expectError(case.err, h.step(.{ .finish_exact = .{ .sequence = call, .fact = case.fact } }));
    }
    var edge = good;
    edge.model = &([_]u8{'~'} ** max_model_bytes);
    edge.cache_read_tokens = edge.input_tokens;
    edge.cache_write_tokens = edge.input_tokens;
    edge.reasoning_tokens = edge.output_tokens;
    edge.total_cost = 0;
    try h.step(.{ .finish_exact = .{ .sequence = call, .fact = edge } });
    try testing.expectEqual(State.settled, h.state(call));
}

test "lookup requests are validated before anything changes" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const call = try h.begin();
    const good = testRequest(call);
    var bad = [_]LookupRequest{ good, good, good, good, good, good };
    bad[0].origin = "";
    bad[1].origin = &([_]u8{'o'} ** (max_origin_bytes + 1));
    bad[2].team = &([_]u8{'t'} ** (max_team_bytes + 1));
    bad[3].account_id = "has\nnewline";
    bad[4].observed_at_ms = -5;
    bad[5].team = "";
    for (bad) |request| {
        try testing.expectError(error.InvalidLookupRequest, h.step(.{ .finish_lookup = .{ .sequence = call, .request = request } }));
    }
    var edge = good;
    edge.origin = &([_]u8{'o'} ** max_origin_bytes);
    edge.team = &([_]u8{'t'} ** max_team_bytes);
    edge.account_id = &([_]u8{'a'} ** max_account_bytes);
    try h.step(.{ .finish_lookup = .{ .sequence = call, .request = edge } });
    try testing.expectEqual(@as(usize, max_team_bytes), h.ledger.waiting()[0].teamText().?.len);
    const other = try h.begin();
    var no_team = testRequest(other);
    no_team.team = null;
    no_team.account_id = null;
    try h.step(.{ .finish_lookup = .{ .sequence = other, .request = no_team } });
    try testing.expectEqual(@as(?[]const u8, null), h.ledger.waiting()[1].teamText());
    try testing.expectEqual(@as(?[]const u8, null), h.ledger.waiting()[1].accountText());
}

test "a generation id belongs to one waiting call" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const a = try h.begin();
    const b = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try testing.expectError(error.DuplicateGenerationId, h.step(.{ .finish_lookup = .{ .sequence = b, .request = testRequest(a) } }));
    try testing.expectError(error.DuplicateGenerationId, h.step(.{ .finish_exact = .{ .sequence = b, .fact = testFact(a, test_model, 1) } }));
    try h.step(.{ .finish_exact = .{ .sequence = b, .fact = testFact(b, test_model, 1) } });
    try testing.expectEqual(State.settled, h.state(b));
}

test "an fx login 401 blocks only that credential, and an API key retries it" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    try h.step(.{ .set_credential = login });
    const a = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try testing.expectEqual(@as(usize, 1), h.effectCount(.start_lookup));
    try h.step(.{ .lookup_unauthorized = a });
    try testing.expectEqual(State.blocked, h.state(a));
    try testing.expectEqual(@as(usize, 0), h.out.effect_count);
    try testing.expectEqual(UnpricedReason.sign_in_cannot_look_up, h.ledger.view().unpriced.reason.?);
    try testing.expectEqual(Availability.pending, h.ledger.availability());
    try testing.expectError(error.NotLookingUp, h.step(.{ .lookup_retry = a }));
    try testing.expectError(error.NotLookingUp, h.step(.{ .lookup_found = .{ .sequence = a, .fact = testFact(a, test_model, 1) } }));

    // The same credential again changes nothing.
    try h.step(.{ .set_credential = login });
    try testing.expectEqual(@as(u32, 0), h.out.transition.?.moved);
    try testing.expectEqual(State.blocked, h.state(a));
    try testing.expectEqual(@as(usize, 0), h.out.effect_count);

    try h.step(.{ .set_credential = api_key });
    try testing.expectEqual(@as(u32, 1), h.out.transition.?.moved);
    try testing.expectEqual(State.lookup, h.state(a));
    try testing.expectEqual(a, h.out.effects()[0].start_lookup);
    try h.step(.{ .lookup_found = .{ .sequence = a, .fact = testFact(a, test_model, 0.75) } });
    try testing.expectEqual(State.settled, h.state(a));
    try testing.expectEqual(Availability.complete, h.ledger.availability());
    try testing.expectEqual(@as(f64, 0.75), h.ledger.view().totals.total_cost);
    try testing.expectEqual(@as(u64, 0), h.ledger.view().unpriced.count);
}

test "signing out puts blocked lookups back to wait for a credential" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    try h.step(.{ .set_credential = login });
    const a = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try h.step(.{ .lookup_unauthorized = a });
    try h.step(.{ .set_credential = null });
    try testing.expectEqual(@as(u32, 1), h.out.transition.?.moved);
    try testing.expectEqual(@as(u32, 0), h.out.transition.?.cred);
    try testing.expectEqual(@as(usize, 0), h.out.effect_count);
    try testing.expectEqual(State.lookup, h.state(a));
    try testing.expectEqual(UnpricedReason.lookup_pending, h.ledger.view().unpriced.reason.?);
    try testing.expectError(error.NoCredential, h.step(.{ .lookup_found = .{ .sequence = a, .fact = testFact(a, test_model, 1) } }));
    try testing.expectError(error.NoCredential, h.step(.{ .lookup_unauthorized = a }));
    try testing.expectError(error.NoCredential, h.step(.{ .lookup_rejected = a }));
    // Signing out twice is a no-op.
    try h.step(.{ .set_credential = null });
    try testing.expectEqual(@as(u32, 0), h.out.transition.?.moved);
    // Signing back in with the same token retries: it no longer blocks anything.
    try h.step(.{ .set_credential = login });
    try testing.expectEqual(@as(usize, 1), h.effectCount(.start_lookup));
}

test "a rejected lookup is unpriced with an incident at its observed time" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    try h.step(.{ .set_credential = api_key });
    const a = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try h.step(.{ .lookup_retry = a });
    try testing.expectEqual(State.lookup, h.state(a));
    try testing.expectEqual(a, h.out.effects()[0].start_lookup);
    try h.step(.{ .lookup_rejected = a });
    try testing.expectEqual(State.unpriced, h.state(a));
    try testing.expectEqual(@as(usize, 1), h.effectCount(.persist_checkpoint));
    try testing.expectEqual(@as(i64, @intCast(2_000 + a)), h.ledger.incidentList()[0].occurred_at_ms);
    // Incomplete is sticky even with nothing left pending.
    try testing.expectEqual(@as(u32, 0), h.ledger.view().pending);
    try testing.expectEqual(Availability.incomplete, h.ledger.availability());
    try testing.expectError(error.NotLookingUp, h.step(.{ .lookup_retry = a }));
}

test "a found lookup must carry the entry's generation id" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    try h.step(.{ .set_credential = api_key });
    const a = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try testing.expectError(error.GenerationIdMismatch, h.step(.{ .lookup_found = .{ .sequence = a, .fact = testFact(a + 1, test_model, 1) } }));
    try testing.expectError(error.NotLookingUp, h.step(.{ .lookup_found = .{ .sequence = a + 1, .fact = testFact(a + 1, test_model, 1) } }));
    var bad = testFact(a, test_model, 1);
    bad.total_cost = -1;
    try testing.expectError(error.InvalidCost, h.step(.{ .lookup_found = .{ .sequence = a, .fact = bad } }));
}

test "model rows are bounded; a fact needing one more stays out of the totals" {
    var h: Harness = try .init(.{ .max_models = 1 });
    defer h.deinit();
    const a = try h.begin();
    const b = try h.begin();
    const c = try h.begin();
    try h.step(.{ .finish_exact = .{ .sequence = a, .fact = testFact(a, "model/a", 1) } });
    try h.step(.{ .finish_exact = .{ .sequence = b, .fact = testFact(b, "model/b", 2) } });
    try testing.expectEqual(State.unpriced, h.state(b));
    try testing.expect(h.out.transition.?.incident and !h.out.transition.?.applied);
    try testing.expectEqual(@as(f64, 1), h.ledger.view().totals.total_cost);
    try testing.expectEqual(@as(u64, 1), h.ledger.view().unpriced.no_receipt);
    try testing.expectEqual(@as(usize, 1), h.ledger.view().models.len);
    try testing.expectEqual(Availability.incomplete, h.ledger.availability());
    try testing.expectEqual(@as(i64, @intCast(1_000 + b)), h.ledger.incidentList()[0].occurred_at_ms);
    // An existing row still takes more.
    try h.step(.{ .finish_exact = .{ .sequence = c, .fact = testFact(c, "model/a", 4) } });
    try testing.expectEqual(State.settled, h.state(c));
    try testing.expectEqual(@as(f64, 5), h.ledger.view().totals.total_cost);

    // A found lookup takes the same path.
    try h.step(.{ .set_credential = api_key });
    const d = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = d, .request = testRequest(d) } });
    try h.step(.{ .lookup_found = .{ .sequence = d, .fact = testFact(d, "model/d", 8) } });
    try testing.expectEqual(State.unpriced, h.state(d));
    try testing.expectEqual(@as(u64, 2), h.ledger.view().unpriced.no_receipt);
}

test "rows stay ordered by first sequence when facts settle out of order" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    try h.step(.{ .set_credential = api_key });
    var calls: [3]Sequence = undefined;
    for (&calls) |*call| call.* = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = calls[0], .request = testRequest(calls[0]) } });
    try h.step(.{ .finish_exact = .{ .sequence = calls[1], .fact = testFact(calls[1], "model/y", 1) } });
    try h.step(.{ .finish_exact = .{ .sequence = calls[2], .fact = testFact(calls[2], "model/x", 1) } });
    try testing.expectEqualStrings("model/y", h.ledger.view().models[0].name());
    try h.step(.{ .lookup_found = .{ .sequence = calls[0], .fact = testFact(calls[0], "model/x", 1) } });
    const models = h.ledger.view().models;
    try testing.expectEqualStrings("model/x", models[0].name());
    try testing.expectEqual(calls[0], models[0].first_sequence);
    try testing.expectEqual(@as(?u64, 2), models[0].totals.request_count);
    try testing.expectEqualStrings("model/y", models[1].name());
}

test "totals use checked arithmetic, and an overflow changes nothing" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const a = try h.begin();
    const b = try h.begin();
    var big = testFact(a, test_model, 1);
    big.input_tokens = std.math.maxInt(u64);
    try h.step(.{ .finish_exact = .{ .sequence = a, .fact = big } });
    try testing.expectError(error.Overflow, h.step(.{ .finish_exact = .{ .sequence = b, .fact = testFact(b, test_model, 1) } }));
    try testing.expectEqual(State.active, h.state(b));

    // The same for cost, across rows.
    var costly: Harness = try .init(.{});
    defer costly.deinit();
    const x = try costly.begin();
    const y = try costly.begin();
    try costly.step(.{ .finish_exact = .{ .sequence = x, .fact = testFact(x, test_model, std.math.floatMax(f64)) } });
    try testing.expectError(error.Overflow, costly.step(.{ .finish_exact = .{ .sequence = y, .fact = testFact(y, "model/other", std.math.floatMax(f64)) } }));
    try testing.expectEqual(State.active, costly.state(y));
}

test "unknown reasoning makes the total unknown; a legacy session starts unknown" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const a = try h.begin();
    var fact = testFact(a, test_model, 1);
    fact.reasoning_tokens = null;
    try h.step(.{ .finish_exact = .{ .sequence = a, .fact = fact } });
    try testing.expectEqual(@as(?u64, null), h.ledger.view().totals.reasoning_tokens);
    try testing.expectEqual(@as(?u64, 1), h.ledger.view().totals.request_count);

    var legacy: Ledger = try .init(testing.allocator, .{}, .legacy);
    defer legacy.deinit(testing.allocator);
    try testing.expectEqual(Availability.legacy, legacy.availability());
    try testing.expectEqual(@as(?u64, null), legacy.view().totals.request_count);
    var out: Output = .{};
    try legacy.step(.{ .begin = .gateway }, &out, null);
    try legacy.step(.{ .finish_lookup = .{ .sequence = 1, .request = testRequest(1) } }, &out, null);
    try testing.expectEqual(Availability.legacy, legacy.availability());
    try legacy.step(.{ .begin = .gateway }, &out, null);
    try legacy.step(.{ .finish_unpriced = .{ .sequence = 2, .at_ms = 5 } }, &out, null);
    try testing.expectEqual(Availability.incomplete, legacy.availability());
}

test "incidents dedupe by time and collapse to one incomplete incident when full" {
    var h: Harness = try .init(.{ .max_incidents = 3 });
    defer h.deinit();
    for ([_]i64{ 50, 50, 10, 30 }) |at_ms| {
        const call = try h.begin();
        try h.step(.{ .finish_unpriced = .{ .sequence = call, .at_ms = at_ms } });
    }
    try testing.expectEqual(@as(usize, 3), h.ledger.incidentList().len);
    const call = try h.begin();
    try h.step(.{ .finish_unpriced = .{ .sequence = call, .at_ms = 20 } });
    try testing.expectEqual(@as(usize, 1), h.ledger.incidentList().len);
    try testing.expectEqual(Incident{ .occurred_at_ms = 50, .completeness = .incomplete }, h.ledger.incidentList()[0]);
    try testing.expectEqual(@as(u64, 5), h.ledger.view().unpriced.no_receipt);
    const later = try h.begin();
    try h.step(.{ .finish_unpriced = .{ .sequence = later, .at_ms = 90 } });
    try testing.expectEqual(@as(usize, 2), h.ledger.incidentList().len);
}

test "availability follows today's rules" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    try testing.expectEqual(Availability.complete, h.ledger.availability());
    try h.step(.{ .set_credential = api_key });
    const a = try h.begin();
    try testing.expectEqual(Availability.complete, h.ledger.availability());
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try testing.expectEqual(Availability.pending, h.ledger.availability());
    try h.step(.{ .lookup_found = .{ .sequence = a, .fact = testFact(a, test_model, 1) } });
    // Only waiting entries make it pending.
    try testing.expectEqual(Availability.complete, h.ledger.availability());
}

test "credential ordinals follow first sight and are never reused" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    try h.step(.{ .set_credential = login });
    try testing.expectEqual(@as(u32, 1), h.out.transition.?.cred);
    try h.step(.{ .set_credential = api_key });
    try testing.expectEqual(@as(u32, 2), h.out.transition.?.cred);
    try h.step(.{ .set_credential = login });
    try testing.expectEqual(@as(u32, 1), h.out.transition.?.cred);
    var index: u8 = 0;
    while (index < max_known_credentials) : (index += 1) {
        try h.step(.{ .set_credential = credentialDigest(&.{index}) });
    }
    try testing.expectEqual(@as(usize, max_known_credentials), h.ledger.known_count);
    // `login` was forgotten, so it comes back as a new credential.
    try h.step(.{ .set_credential = login });
    try testing.expectEqual(@as(u32, 2 + max_known_credentials + 1), h.out.transition.?.cred);

    h.ledger.next_ordinal = std.math.maxInt(u32);
    try testing.expectError(error.CredentialOrdinalsExhausted, h.step(.{ .set_credential = credentialDigest("new") }));
}

test "one credential change starts every waiting lookup" {
    var h: Harness = try .init(.{ .max_pending = Limits.ceiling, .max_active = Limits.ceiling, .max_persisted_pending = Limits.ceiling });
    defer h.deinit();
    var count: u32 = 0;
    while (count < Limits.ceiling) : (count += 1) {
        const call = try h.begin();
        try h.step(.{ .finish_lookup = .{ .sequence = call, .request = testRequest(call) } });
    }
    try h.step(.{ .set_credential = api_key });
    try testing.expectEqual(@as(usize, Limits.ceiling), h.effectCount(.start_lookup));
}

test "limits must be between 1 and the ceiling" {
    try testing.expectError(error.InvalidLimits, Ledger.init(testing.allocator, .{ .max_pending = 0 }, .fresh));
    try testing.expectError(error.InvalidLimits, Ledger.init(testing.allocator, .{ .max_models = Limits.ceiling + 1 }, .fresh));
    try testing.expectError(error.InvalidLimits, Ledger.init(testing.allocator, .{ .max_active = 0 }, .fresh));
}

test "init frees what it allocated when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var ledger: Ledger = try .init(gpa, .{}, .fresh);
            ledger.deinit(gpa);
        }
    }.run, .{});
}

test "each step writes one ledger record with model state names" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var writer: trace.Writer = .init(&buffer.writer);
    var ledger: Ledger = try .init(testing.allocator, .{}, .fresh);
    defer ledger.deinit(testing.allocator);
    var out: Output = .{};
    try ledger.step(.{ .set_credential = login }, &out, &writer);
    try ledger.step(.{ .begin = .gateway }, &out, &writer);
    try ledger.step(.{ .finish_lookup = .{ .sequence = 1, .request = testRequest(1) } }, &out, &writer);
    try ledger.step(.{ .lookup_unauthorized = 1 }, &out, &writer);
    try ledger.step(.{ .set_credential = api_key }, &out, &writer);
    try testing.expectError(error.NotActive, ledger.step(.{ .finish_unbilled = 9 }, &out, &writer));
    try testing.expect(out.trace_error == null);
    try testing.expectEqualStrings(
        "{\"v\":1,\"seq\":1,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"set_credential\",\"from\":\"-\",\"to\":\"-\",\"effects\":[],\"data\":{\"call\":0,\"cred\":1,\"rows\":0,\"moved\":0}}\n" ++
            "{\"v\":1,\"seq\":2,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"begin\",\"from\":\"idle\",\"to\":\"active\",\"effects\":[\"persist_checkpoint\"],\"data\":{\"call\":1,\"cred\":1,\"rows\":0,\"incident\":false,\"applied\":false,\"budget\":0}}\n" ++
            "{\"v\":1,\"seq\":3,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"finish_lookup\",\"from\":\"active\",\"to\":\"lookup\",\"effects\":[\"persist_checkpoint\",\"start_lookup\"],\"data\":{\"call\":1,\"cred\":1,\"rows\":0,\"incident\":false,\"applied\":false,\"budget\":0}}\n" ++
            "{\"v\":1,\"seq\":4,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"lookup_unauthorized\",\"from\":\"lookup\",\"to\":\"blocked\",\"effects\":[],\"data\":{\"call\":1,\"cred\":1,\"rows\":0,\"incident\":false,\"applied\":false,\"budget\":0}}\n" ++
            "{\"v\":1,\"seq\":5,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"set_credential\",\"from\":\"-\",\"to\":\"-\",\"effects\":[\"start_lookup\"],\"data\":{\"call\":0,\"cred\":2,\"rows\":0,\"moved\":1}}\n",
        buffer.written(),
    );
}

test "a trace write failure is reported and the step still takes effect" {
    var storage: [16]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&storage);
    var writer: trace.Writer = .init(&fixed);
    var ledger: Ledger = try .init(testing.allocator, .{}, .fresh);
    defer ledger.deinit(testing.allocator);
    var out: Output = .{};
    try ledger.step(.{ .begin = .gateway }, &out, &writer);
    try testing.expectEqual(@as(?std.Io.Writer.Error, error.WriteFailed), out.trace_error);
    try testing.expectEqual(@as(u32, 1), ledger.view().active);
}

test "random event streams keep every model invariant" {
    var seed: u64 = 1;
    while (seed <= 40) : (seed += 1) {
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        var h: Harness = try .init(.{
            .max_active = random.intRangeAtMost(u32, 1, 4),
            .max_pending = random.intRangeAtMost(u32, 1, 3),
            .max_persisted_pending = random.intRangeAtMost(u32, 1, 3),
            .max_incidents = random.intRangeAtMost(u32, 1, 3),
            .max_models = random.intRangeAtMost(u32, 1, 3),
            // Small enough that the budget refuses some additions.
            .max_identifier_bytes = random.intRangeAtMost(u32, 60, 400),
        });
        defer h.deinit();
        const models = [_][]const u8{ "model/a", "model/b", "model/c", "model/d" };
        const credentials = [_]?Digest{ null, login, api_key, credentialDigest("other") };
        var steps: u32 = 0;
        while (steps < 400) : (steps += 1) {
            const call = random.intRangeAtMost(Sequence, 1, h.ledger.next_sequence);
            const fact = testFact(call, models[random.uintLessThan(usize, models.len)], @as(f64, @floatFromInt(random.uintLessThan(u8, 100))) / 64);
            const event: Event = switch (random.uintLessThan(u8, 10)) {
                0 => .{ .begin = .gateway },
                1 => .{ .finish_exact = .{ .sequence = call, .fact = fact } },
                2 => .{ .finish_lookup = .{ .sequence = call, .request = testRequest(call) } },
                3 => .{ .finish_unbilled = call },
                4 => .{ .finish_unpriced = .{ .sequence = call, .at_ms = random.intRangeAtMost(i64, 0, 9) } },
                5 => .{ .set_credential = credentials[random.uintLessThan(usize, credentials.len)] },
                6 => .{ .lookup_found = .{ .sequence = call, .fact = fact } },
                7 => .{ .lookup_unauthorized = call },
                8 => .{ .lookup_rejected = call },
                else => .{ .lookup_retry = call },
            };
            // Refusals are checked for leaving the ledger unchanged inside
            // `Harness.step`; only the expected ones may occur.
            h.step(event) catch |err| switch (err) {
                error.TooManyActive, error.NotActive, error.NotLookingUp, error.NoCredential, error.DuplicateGenerationId => {},
                else => return err,
            };
        }
        // With a credential that finds them, every lookup resolves
        // (LookupsResolve).
        try h.step(.{ .set_credential = credentialDigest("resolver") });
        while (h.ledger.waiting().len > 0) {
            const entry = h.ledger.waiting()[0];
            try h.step(.{ .lookup_found = .{ .sequence = entry.sequence, .fact = testFact(entry.sequence, "model/a", 1) } });
        }
        var it = h.calls.valueIterator();
        while (it.next()) |shadow| try testing.expect(shadow.state != .lookup and shadow.state != .blocked);
    }
}

test "the identifier budget refuses a waiting entry and a new row, never an existing row" {
    // One request is 30 (id) + 28 (origin) + 8 (team) + 6 (account) = 72 bytes.
    var h: Harness = try .init(.{ .max_identifier_bytes = 72 + 7 });
    defer h.deinit();
    const a = try h.begin();
    const b = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try testing.expectEqual(@as(u2, 0), h.out.transition.?.budget);
    // A second entry doesn't fit: unpriced, and the record says the budget did it.
    try h.step(.{ .finish_lookup = .{ .sequence = b, .request = testRequest(b) } });
    try testing.expectEqual(State.unpriced, h.state(b));
    try testing.expectEqual(@as(u2, 1), h.out.transition.?.budget);

    // 7 bytes are left: a 7-byte model takes a new row, an 8-byte one can't.
    const c = try h.begin();
    const d = try h.begin();
    try h.step(.{ .finish_exact = .{ .sequence = c, .fact = testFact(c, "model/x", 1) } });
    try testing.expectEqual(State.settled, h.state(c));
    try testing.expectEqual(@as(u2, 0), h.out.transition.?.budget);
    try h.step(.{ .finish_exact = .{ .sequence = d, .fact = testFact(d, "model/xy", 2) } });
    try testing.expectEqual(State.unpriced, h.state(d));
    try testing.expectEqual(@as(u2, 2), h.out.transition.?.budget);
    // No bytes are left, but settling into an existing row needs none.
    const e = try h.begin();
    try h.step(.{ .finish_exact = .{ .sequence = e, .fact = testFact(e, "model/x", 4) } });
    try testing.expectEqual(State.settled, h.state(e));
    try testing.expectEqual(@as(f64, 5), h.ledger.view().totals.total_cost);
}

test "a found lookup may reuse the bytes its waiting entry frees" {
    var h: Harness = try .init(.{ .max_identifier_bytes = 72 });
    defer h.deinit();
    try h.step(.{ .set_credential = api_key });
    const a = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try h.step(.{ .lookup_found = .{ .sequence = a, .fact = testFact(a, "model/x", 1) } });
    try testing.expectEqual(State.settled, h.state(a));
    try testing.expectEqual(@as(u2, 0), h.out.transition.?.budget);
}

test "the persisted pending array bounds waiting entries, never an exact fact" {
    var h: Harness = try .init(.{ .max_persisted_pending = 2 });
    defer h.deinit();
    try h.step(.{ .set_credential = api_key });
    const a = try h.begin();
    const b = try h.begin();
    const c = try h.begin();
    const d = try h.begin();
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = testRequest(a) } });
    try h.step(.{ .finish_lookup = .{ .sequence = b, .request = testRequest(b) } });
    // Full: a lookup is unpriced. That is spent budget, not a full list, and
    // it is not dropped silently.
    try h.step(.{ .finish_lookup = .{ .sequence = c, .request = testRequest(c) } });
    try testing.expectEqual(State.unpriced, h.state(c));
    try testing.expectEqual(@as(u2, 1), h.out.transition.?.budget);
    try testing.expect(h.out.transition.?.incident);
    // An exact fact still settles.
    try h.step(.{ .finish_exact = .{ .sequence = d, .fact = testFact(d, "model/x", 2) } });
    try testing.expectEqual(State.settled, h.state(d));
    // A found lookup frees its entry.
    try h.step(.{ .lookup_found = .{ .sequence = a, .fact = testFact(a, "model/x", 4) } });
    try testing.expectEqual(State.settled, h.state(a));
    try testing.expectEqual(@as(usize, 1), h.ledger.waiting().len);
}

test "settled_through follows the calls in flight" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const a = try h.begin();
    const b = try h.begin();
    try h.step(.{ .finish_unbilled = b });
    try testing.expectEqual(@as(Sequence, 0), h.ledger.settled_through);
    try h.step(.{ .finish_unbilled = a });
    try testing.expectEqual(@as(Sequence, 2), h.ledger.settled_through);
}

test "activity saturates and marks the metric incomplete on overflow" {
    var ledger: Ledger = try .init(testing.allocator, .{}, .fresh);
    defer ledger.deinit(testing.allocator);
    ledger.recordActivity(.{ .api_ms = 5, .lines_added = 3, .lines_removed = 1 });
    try testing.expectEqual(@as(u64, 5), ledger.activity.api_duration_ms);
    try testing.expect(ledger.activity.api_duration_complete and ledger.activity.code_complete);
    ledger.recordActivity(.{ .api_ms = std.math.maxInt(u64) });
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), ledger.activity.api_duration_ms);
    try testing.expect(!ledger.activity.api_duration_complete);
    ledger.recordActivity(.{ .lines_added = std.math.maxInt(u64) });
    try testing.expect(!ledger.activity.code_complete);
    var marked: Ledger = try .init(testing.allocator, .{}, .fresh);
    defer marked.deinit(testing.allocator);
    marked.recordActivity(.{ .code_incomplete = true });
    try testing.expect(!marked.activity.code_complete);
    var legacy: Ledger = try .init(testing.allocator, .{}, .legacy);
    defer legacy.deinit(testing.allocator);
    try testing.expect(!legacy.activity.api_duration_complete and !legacy.activity.wall_duration_complete and !legacy.activity.code_complete);
}

test "credential sources follow today's snapshot rules" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const a = try h.begin();
    var no_source = testRequest(a);
    no_source.credential_source = null;
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = no_source } });
    try testing.expectEqual(@as(?CredentialSource, null), h.ledger.waiting()[0].credential_source);

    const b = try h.begin();
    var identity_only = testRequest(b);
    identity_only.credential_source = null;
    identity_only.credential_identity = login;
    try testing.expectError(error.InvalidLookupRequest, h.step(.{ .finish_lookup = .{ .sequence = b, .request = identity_only } }));

    try h.step(.{ .finish_unbilled = b });
    try h.step(.{ .begin = .codex });
    const c = h.out.transition.?.call;
    try testing.expectError(error.InvalidLookupRequest, h.step(.{ .finish_lookup = .{ .sequence = c, .request = testRequest(c) } }));
    var subscription = testRequest(c);
    subscription.credential_source = .chatgpt_subscription;
    try h.step(.{ .finish_lookup = .{ .sequence = c, .request = subscription } });
    try testing.expectEqual(Provider.codex, h.ledger.waiting()[1].provider);

    try testing.expect(authorizesCredential(.grok, .host_managed));
    try testing.expect(!authorizesCredential(.gateway, .configured));
    try testing.expect(authorizesCredential(.configured, .configured));
}

test "account ids are UTF-8 without control characters, as today" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const a = try h.begin();
    var request = testRequest(a);
    request.account_id = "équipe 1";
    try h.step(.{ .finish_lookup = .{ .sequence = a, .request = request } });
    try testing.expectEqualStrings("équipe 1", h.ledger.waiting()[0].accountText().?);
    const b = try h.begin();
    var bad = testRequest(b);
    for ([_][]const u8{ "tab\there", "\xff\xfe", "" }) |account| {
        bad.account_id = account;
        try testing.expectError(error.InvalidLookupRequest, h.step(.{ .finish_lookup = .{ .sequence = b, .request = bad } }));
    }
}

test "the identifier limit must fit older readers" {
    try testing.expectError(error.InvalidLimits, Ledger.init(testing.allocator, .{ .max_identifier_bytes = max_identifier_bytes + 1 }, .fresh));
    try testing.expectError(error.InvalidLimits, Ledger.init(testing.allocator, .{ .max_identifier_bytes = 0 }, .fresh));
}

fn testRestored(rows: []const Restored.Row, pending: []const Restored.Waiting, backlog: []const Restored.StagedFact) Restored {
    var totals: Totals = .{};
    for (rows) |row| {
        totals.total_cost += row.totals.total_cost;
        totals.input_tokens += row.totals.input_tokens;
    }
    return .{
        .availability = if (pending.len > 0) .pending else .complete,
        .next_sequence = 10,
        .settled_through = 9,
        .totals = totals,
        .rows = rows,
        .pending = pending,
        .backlog = backlog,
        .activity = .{ .api_duration_ms = 70, .lines_added = 4 },
    };
}

test "a restored session picks up where it was saved" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const rows = [_]Restored.Row{.{ .model = "model/a", .first_sequence = 1, .totals = .{ .total_cost = 2, .input_tokens = 10 } }};
    const pending = [_]Restored.Waiting{.{ .sequence = 4, .provider = .gateway, .request = testRequest(4) }};
    // An older binary staged this fact for its profile ledger.
    const backlog = [_]Restored.StagedFact{.{ .sequence = 6, .fact = testFact(6, "model/a", 1) }};
    try h.restore(testRestored(&rows, &pending, &backlog));
    // The staged fact settled into its row, and that is checkpointed.
    try testing.expectEqual(State.settled, h.state(6));
    try testing.expectEqual(@as(f64, 3), h.ledger.view().totals.total_cost);
    try testing.expectEqual(@as(usize, 1), h.ledger.view().models.len);
    try testing.expectEqual(@as(usize, 1), h.out.effects().len);
    try testing.expectEqual(@as(usize, 1), h.effectCount(.persist_checkpoint));
    try testing.expectEqual(Availability.pending, h.ledger.availability());
    try testing.expectEqual(@as(u64, 70), h.ledger.activity.api_duration_ms);

    // New calls continue after the saved sequence.
    try testing.expectEqual(@as(Sequence, 10), try h.begin());
    // A credential looks the restored entry up.
    try h.step(.{ .set_credential = api_key });
    try testing.expectEqual(@as(Sequence, 4), h.out.effects()[0].start_lookup);
    try h.step(.{ .lookup_found = .{ .sequence = 4, .fact = testFact(4, "model/b", 4) } });
    try testing.expectEqual(@as(f64, 7), h.ledger.view().totals.total_cost);
    try testing.expectEqualStrings("model/a", h.ledger.view().models[0].name());

    try testing.expectError(error.AlreadyStarted, h.ledger.restore(testRestored(&.{}, &.{}, &.{}), &h.out, null));
}

test "a restored session with nothing staged needs no checkpoint" {
    var h: Harness = try .init(.{});
    defer h.deinit();
    const pending = [_]Restored.Waiting{.{ .sequence = 4, .provider = .gateway, .request = testRequest(4) }};
    try h.restore(testRestored(&.{}, &pending, &.{}));
    try testing.expectEqual(@as(usize, 0), h.out.effects().len);
}

test "a restored staged fact with no row left is unpriced with an incident" {
    var h: Harness = try .init(.{ .max_models = 1 });
    defer h.deinit();
    const rows = [_]Restored.Row{.{ .model = "model/a", .first_sequence = 1, .totals = .{ .total_cost = 2, .input_tokens = 10 } }};
    const backlog = [_]Restored.StagedFact{
        .{ .sequence = 5, .fact = testFact(5, "model/b", 1) },
        .{ .sequence = 6, .fact = testFact(6, "model/a", 4) },
    };
    try h.restore(testRestored(&rows, &.{}, &backlog));
    try testing.expectEqual(State.unpriced, h.state(5));
    try testing.expectEqual(State.settled, h.state(6));
    try testing.expectEqual(@as(f64, 6), h.ledger.view().totals.total_cost);
    try testing.expectEqual(@as(u64, 1), h.ledger.view().unpriced.no_receipt);
    try testing.expectEqual(Availability.incomplete, h.ledger.availability());
    try testing.expectEqual(@as(i64, 1_005), h.ledger.incidentList()[0].occurred_at_ms);
}

test "restore keeps incomplete, legacy, and incidents" {
    var ledger: Ledger = try .init(testing.allocator, .{}, .fresh);
    defer ledger.deinit(testing.allocator);
    var out: Output = .{};
    var saved = testRestored(&.{}, &.{}, &.{});
    saved.availability = .incomplete;
    saved.incidents = &.{.{ .occurred_at_ms = 3, .completeness = .pending }};
    try ledger.restore(saved, &out, null);
    try testing.expectEqual(Availability.incomplete, ledger.availability());
    try testing.expectEqual(@as(usize, 0), out.effect_count);
    try testing.expectEqual(Completeness.pending, ledger.incidentList()[0].completeness);

    var legacy: Ledger = try .init(testing.allocator, .{}, .fresh);
    defer legacy.deinit(testing.allocator);
    saved = testRestored(&.{}, &.{}, &.{});
    saved.availability = .legacy;
    saved.totals.reasoning_tokens = null;
    try legacy.restore(saved, &out, null);
    try testing.expectEqual(Availability.legacy, legacy.availability());
}

test "restore refuses state the ledger could not have saved" {
    const one_row = [_]Restored.Row{.{ .model = "model/a", .first_sequence = 1, .totals = .{} }};
    const pending = [_]Restored.Waiting{.{ .sequence = 4, .provider = .gateway, .request = testRequest(4) }};
    const dup_pending = [_]Restored.Waiting{ pending[0], .{ .sequence = 4, .provider = .gateway, .request = testRequest(5) } };
    const backlog = [_]Restored.StagedFact{.{ .sequence = 4, .fact = testFact(6, "model/a", 1) }};
    const same_id = [_]Restored.StagedFact{.{ .sequence = 6, .fact = testFact(4, "model/a", 1) }};
    const future = [_]Restored.StagedFact{.{ .sequence = 10, .fact = testFact(10, "model/a", 1) }};
    const rows_dup = [_]Restored.Row{ one_row[0], one_row[0] };
    var cases: [9]Restored = undefined;
    cases[0] = testRestored(&.{}, &dup_pending, &.{});
    cases[1] = testRestored(&.{}, &pending, &backlog);
    cases[2] = testRestored(&.{}, &pending, &same_id);
    cases[3] = testRestored(&.{}, &.{}, &future);
    cases[4] = testRestored(&rows_dup, &.{}, &.{});
    cases[5] = testRestored(&.{}, &.{}, &.{});
    cases[5].availability = .pending;
    cases[6] = testRestored(&.{}, &pending, &.{});
    cases[6].availability = .complete;
    cases[7] = testRestored(&.{}, &.{}, &.{});
    cases[7].settled_through = 10;
    cases[8] = testRestored(&one_row, &.{}, &.{});
    cases[8].incidents = &.{.{ .occurred_at_ms = -1, .completeness = .incomplete }};
    for (cases) |saved| {
        var ledger: Ledger = try .init(testing.allocator, .{}, .fresh);
        defer ledger.deinit(testing.allocator);
        var out: Output = .{};
        try testing.expectError(error.InvalidRestore, ledger.restore(saved, &out, null));
    }
    // Over a bound, and over the identifier budget.
    var small: Ledger = try .init(testing.allocator, .{ .max_pending = 1, .max_identifier_bytes = 71 }, .fresh);
    defer small.deinit(testing.allocator);
    var out: Output = .{};
    try testing.expectError(error.InvalidRestore, small.restore(testRestored(&.{}, &dup_pending, &.{}), &out, null));
    try testing.expectError(error.InvalidRestore, small.restore(testRestored(&.{}, &pending, &.{}), &out, null));
}

test "a restored session writes one restore record per call it brings back" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var writer: trace.Writer = .init(&buffer.writer);
    var ledger: Ledger = try .init(testing.allocator, .{}, .fresh);
    defer ledger.deinit(testing.allocator);
    var out: Output = .{};
    const rows = [_]Restored.Row{.{ .model = "model/a", .first_sequence = 1, .totals = .{ .total_cost = 2, .input_tokens = 10 } }};
    const pending = [_]Restored.Waiting{.{ .sequence = 7, .provider = .gateway, .request = testRequest(7) }};
    const backlog = [_]Restored.StagedFact{.{ .sequence = 3, .fact = testFact(3, "model/a", 1) }};
    try ledger.restore(testRestored(&rows, &pending, &backlog), &out, &writer);
    try testing.expectEqualStrings(
        "{\"v\":1,\"seq\":1,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"restore\",\"from\":\"-\",\"to\":\"-\",\"effects\":[],\"data\":{\"call\":0,\"cred\":0,\"rows\":1}}\n" ++
            "{\"v\":1,\"seq\":2,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"restore\",\"from\":\"settled\",\"to\":\"settled\",\"effects\":[],\"data\":{\"call\":3,\"cred\":0,\"rows\":1,\"incident\":false,\"applied\":false,\"budget\":0}}\n" ++
            "{\"v\":1,\"seq\":3,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"restore\",\"from\":\"lookup\",\"to\":\"lookup\",\"effects\":[],\"data\":{\"call\":7,\"cred\":0,\"rows\":1,\"incident\":false,\"applied\":false,\"budget\":0}}\n",
        buffer.written(),
    );
}
