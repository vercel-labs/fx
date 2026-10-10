//! Byte-exact codecs for the session usage snapshot in every place fx keeps it:
//!
//! - the 18-key rollback shape (no `schema_version`) that older binaries read
//!   inside legacy v3 events and durable state blobs (`writeLegacy18`),
//! - the rich shape, 23 keys, written as schema 3 with schema 2 accepted
//!   (`writeRich`),
//! - the v1 sidecar `sessions/<id>/usage-v2.json`
//!   `{"schema_version":1,"session_id":..,"snapshot":<rich>}` (`encodeSidecar`),
//! - the sessions-v2 `set usage` value `{"at_ms":N,"snapshot":<rich>}`
//!   (`encodeV2Value`).
//!
//! Every shape is byte-identical to what older fx binaries write and read,
//! and error names are the ones fx has always used, so callers keep their
//! mappings.
//!
//! Parsers return owned snapshots; free them with `Snapshot.deinit`. Writers
//! borrow and validate first, so every written snapshot parses again.

const std = @import("std");
const record = @import("record.zig");
const core = @import("../core/ledger.zig");

const Allocator = std.mem.Allocator;

pub const GenerationFact = record.GenerationFact;
pub const Incident = record.Incident;

pub const max_models: usize = 32;
pub const max_pending: usize = 16;
pub const max_backlog: usize = 16;
pub const max_incidents: usize = 16;
pub const max_model_bytes: usize = 1024;
pub const max_origin_bytes: usize = 2048;
pub const max_team_bytes: usize = 255;
pub const max_identifier_bytes: usize = 8 * 1024;
/// Parse budget fx gives a state blob's `usage` value.
pub const max_snapshot_bytes: usize = 256 * 1024;
pub const max_sidecar_bytes: usize = max_snapshot_bytes + 512;
/// Longest configured provider id fx accepts in a pending entry.
pub const max_provider_id_bytes: usize = 64;

const legacy_key_count = 18;
const rich_key_count = 23;

pub const Billing = enum { complete, pending, incomplete, legacy };

/// Provider that owns a pending generation. fx writes `@tagName` of its
/// provider union, so every configured provider is written as `configured`.
pub const Provider = core.Provider;

/// Matches `types.CredentialSource` and `parseRuntimeCredentialSource`.
pub const CredentialSource = core.CredentialSource;

/// SHA-256 credential authority digest, persisted as 64 lowercase hex digits.
pub const CredentialIdentity = [32]u8;

pub const Model = struct {
    model: []const u8,
    first_sequence: u64,
    total_cost: f64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: ?u64 = null,
    request_count: ?u64 = null,
    billable_web_search_calls: u64 = 0,
};

pub const Pending = struct {
    id: []const u8,
    sequence: u64,
    provider: Provider = .gateway,
    origin: []const u8,
    team: ?[]const u8,
    credential_source: ?CredentialSource = null,
    credential_identity: ?CredentialIdentity = null,
    account_id: ?[]const u8 = null,
    observed_at_ms: ?i64 = null,
};

/// Parsed snapshots own every slice and string; free with `deinit`.
/// Caller-built snapshots may borrow and need no `deinit`.
pub const Snapshot = struct {
    billing: Billing,
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
    models: []const Model,
    pending: []const Pending,
    publication_backlog: []const GenerationFact = &.{},
    incidents: []const Incident = &.{},

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        freeModels(alloc, self.models);
        freePending(alloc, self.pending);
        freeBacklog(alloc, self.publication_backlog);
        alloc.free(self.incidents);
        self.* = undefined;
    }
};

/// The zero snapshot fx substitutes for an unversioned snapshot whose only
/// fault is separate-cache accounting (`parseLegacySnapshotValue`).
pub const legacy_unavailable = Snapshot{
    .billing = .legacy,
    .api_duration_complete = false,
    .wall_duration_complete = false,
    .code_complete = false,
    .next_sequence = 1,
    .settled_through_sequence = 0,
    .api_duration_ms = 0,
    .wall_duration_ms = 0,
    .total_cost = 0,
    .input_tokens = 0,
    .output_tokens = 0,
    .cache_read_tokens = 0,
    .cache_write_tokens = 0,
    .billable_web_search_calls = 0,
    .lines_added = 0,
    .lines_removed = 0,
    .models = &.{},
    .pending = &.{},
};

pub const ValidateError = error{
    InvalidUsageSnapshot,
    UsageCapacityExceeded,
    UsageOverflow,
    InvalidModel,
    InvalidGenerationId,
    InvalidGatewayOrigin,
    InvalidGatewayTeam,
    InvalidCredentialIdentity,
};

/// `InvalidGenerationRecord` is fx's error for a malformed number field.
pub const ParseError = Allocator.Error || ValidateError || error{InvalidGenerationRecord};
pub const WriteError = std.Io.Writer.Error || ValidateError || record.FactError;
pub const SidecarError = ParseError || error{InvalidUsageSidecar};
pub const V2Error = ParseError || error{InvalidUsageCheckpoint};

// ---------------------------------------------------------------------------
// Validation (`validateSnapshotContract`)

/// The rules every persisted snapshot must satisfy.
pub fn validate(snapshot: Snapshot) ValidateError!void {
    _ = try validateContract(snapshot, false);
}

/// Returns false only when `allow_legacy_cache` is set and the snapshot's sole
/// fault is a model with cache tokens above its input tokens.
fn validateContract(snapshot: Snapshot, allow_legacy_cache: bool) ValidateError!bool {
    var cache_totals_valid = true;
    if (snapshot.next_sequence == 0) return error.InvalidUsageSnapshot;
    if (snapshot.settled_through_sequence >= snapshot.next_sequence) return error.InvalidUsageSnapshot;
    if (!std.math.isFinite(snapshot.total_cost) or snapshot.total_cost < 0) return error.InvalidUsageSnapshot;
    if (snapshot.models.len > max_models or
        snapshot.pending.len > max_pending or
        snapshot.publication_backlog.len > max_backlog or
        snapshot.incidents.len > max_incidents)
    {
        return error.UsageCapacityExceeded;
    }
    if (snapshot.billing == .complete and snapshot.pending.len != 0) return error.InvalidUsageSnapshot;
    if (snapshot.billing == .pending and snapshot.pending.len == 0) return error.InvalidUsageSnapshot;

    var identifier_bytes: usize = 0;
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;
    var cache_read_tokens: u64 = 0;
    var cache_write_tokens: u64 = 0;
    var reasoning_tokens: ?u64 = if (snapshot.reasoning_tokens == null) null else 0;
    var request_count: ?u64 = if (snapshot.request_count == null) null else 0;
    var billable_web_search_calls: u64 = 0;
    var total_cost: f64 = 0;
    for (snapshot.models, 0..) |model, index| {
        try validateModelName(model.model);
        if (model.first_sequence == 0 or model.first_sequence >= snapshot.next_sequence) {
            return error.InvalidUsageSnapshot;
        }
        if (!std.math.isFinite(model.total_cost) or model.total_cost < 0) return error.InvalidUsageSnapshot;
        total_cost += model.total_cost;
        if (!std.math.isFinite(total_cost)) return error.InvalidUsageSnapshot;
        identifier_bytes = std.math.add(usize, identifier_bytes, model.model.len) catch
            return error.UsageCapacityExceeded;
        input_tokens = std.math.add(u64, input_tokens, model.input_tokens) catch return error.InvalidUsageSnapshot;
        output_tokens = std.math.add(u64, output_tokens, model.output_tokens) catch return error.InvalidUsageSnapshot;
        cache_read_tokens = std.math.add(u64, cache_read_tokens, model.cache_read_tokens) catch
            return error.InvalidUsageSnapshot;
        cache_write_tokens = std.math.add(u64, cache_write_tokens, model.cache_write_tokens) catch
            return error.InvalidUsageSnapshot;
        reasoning_tokens = addOptionalCounter(reasoning_tokens, model.reasoning_tokens) catch
            return error.InvalidUsageSnapshot;
        request_count = addOptionalCounter(request_count, model.request_count) catch
            return error.InvalidUsageSnapshot;
        if (model.cache_read_tokens > model.input_tokens or model.cache_write_tokens > model.input_tokens) {
            if (!allow_legacy_cache) return error.InvalidUsageSnapshot;
            cache_totals_valid = false;
        }
        if (model.reasoning_tokens) |reasoning| {
            if (reasoning > model.output_tokens) return error.InvalidUsageSnapshot;
        }
        billable_web_search_calls = std.math.add(u64, billable_web_search_calls, model.billable_web_search_calls) catch
            return error.InvalidUsageSnapshot;
        for (snapshot.models[0..index]) |prior| {
            if (std.mem.eql(u8, prior.model, model.model)) return error.InvalidUsageSnapshot;
        }
        if (index > 0 and snapshot.models[index - 1].first_sequence >= model.first_sequence) {
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
    if (@abs(total_cost - snapshot.total_cost) > cost_tolerance) return error.InvalidUsageSnapshot;

    for (snapshot.pending, 0..) |generation, index| {
        if (!record.validGenerationId(generation.id)) return error.InvalidGenerationId;
        try validatePrintable(generation.origin, max_origin_bytes, error.InvalidGatewayOrigin);
        if (generation.team) |team| try validatePrintable(team, max_team_bytes, error.InvalidGatewayTeam);
        if (generation.account_id) |account_id| try validateIdentifier(account_id);
        if (generation.credential_identity != null and generation.credential_source == null) {
            return error.InvalidUsageSnapshot;
        }
        if (generation.credential_source) |source| {
            if (!authorizesCredential(generation.provider, source)) return error.InvalidUsageSnapshot;
        }
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
        if (generation.account_id) |account_id| {
            identifier_bytes = std.math.add(usize, identifier_bytes, account_id.len) catch
                return error.UsageOverflow;
        }
        for (snapshot.pending[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, generation.id) or prior.sequence == generation.sequence) {
                return error.InvalidUsageSnapshot;
            }
        }
    }
    for (snapshot.publication_backlog, 0..) |fact, index| {
        record.validateFact(fact) catch return error.InvalidUsageSnapshot;
        identifier_bytes = std.math.add(usize, identifier_bytes, fact.id.len) catch
            return error.UsageCapacityExceeded;
        identifier_bytes = std.math.add(usize, identifier_bytes, fact.model.len) catch
            return error.UsageCapacityExceeded;
        for (snapshot.publication_backlog[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, fact.id)) return error.InvalidUsageSnapshot;
        }
    }
    for (snapshot.incidents) |incident| {
        if (incident.occurred_at_ms < 0) return error.InvalidUsageSnapshot;
    }
    if (identifier_bytes > max_identifier_bytes) return error.UsageCapacityExceeded;
    return cache_totals_valid;
}

/// `model_provider.authorizesCredential` for a non-null source.
pub const authorizesCredential = core.authorizesCredential;

fn validateModelName(model: []const u8) error{InvalidModel}!void {
    return validatePrintable(model, max_model_bytes, error.InvalidModel);
}

fn validatePrintable(value: []const u8, max_bytes: usize, comptime err: anytype) @TypeOf(err)!void {
    if (value.len == 0 or value.len > max_bytes) return err;
    for (value) |byte| {
        if (byte < 0x21 or byte > 0x7e) return err;
    }
}

fn validateIdentifier(value: []const u8) error{InvalidCredentialIdentity}!void {
    if (value.len == 0 or value.len > max_model_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidCredentialIdentity;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidCredentialIdentity;
}

fn addOptionalCounter(first: ?u64, second: ?u64) error{UsageOverflow}!?u64 {
    if (first == null or second == null) return null;
    return std.math.add(u64, first.?, second.?) catch error.UsageOverflow;
}

// ---------------------------------------------------------------------------
// Writers

/// The 18-key rollback shape (`writeSnapshot`). Drops reasoning, request
/// counts, `observed_at_ms`, the backlog, and incidents, as fx does.
pub fn writeLegacy18(writer: *std.Io.Writer, snapshot: Snapshot) WriteError!void {
    try validate(snapshot);
    try writeHead(writer, snapshot, false);
    try writer.print(
        ",\"billable_web_search_calls\":{d},\"lines_added\":{d},\"lines_removed\":{d},\"models\":[",
        .{ snapshot.billable_web_search_calls, snapshot.lines_added, snapshot.lines_removed },
    );
    for (snapshot.models, 0..) |model, index| {
        if (index > 0) try writer.writeByte(',');
        try writeModelHead(writer, model);
        try writer.print(",\"billable_web_search_calls\":{d}}}", .{model.billable_web_search_calls});
    }
    try writer.writeAll("],\"pending\":[");
    for (snapshot.pending, 0..) |pending, index| {
        if (index > 0) try writer.writeByte(',');
        try writePendingHead(writer, pending);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

/// The rich shape, always written as schema 3 (`writeRichSnapshot`).
pub fn writeRich(writer: *std.Io.Writer, snapshot: Snapshot) WriteError!void {
    try validate(snapshot);
    try writeHead(writer, snapshot, true);
    try writer.writeAll(",\"reasoning_tokens\":");
    try writeOptionalU64(writer, snapshot.reasoning_tokens);
    try writer.writeAll(",\"request_count\":");
    try writeOptionalU64(writer, snapshot.request_count);
    try writer.print(
        ",\"billable_web_search_calls\":{d},\"lines_added\":{d},\"lines_removed\":{d},\"models\":[",
        .{ snapshot.billable_web_search_calls, snapshot.lines_added, snapshot.lines_removed },
    );
    for (snapshot.models, 0..) |model, index| {
        if (index > 0) try writer.writeByte(',');
        try writeModelHead(writer, model);
        try writer.writeAll(",\"reasoning_tokens\":");
        try writeOptionalU64(writer, model.reasoning_tokens);
        try writer.writeAll(",\"request_count\":");
        try writeOptionalU64(writer, model.request_count);
        try writer.print(",\"billable_web_search_calls\":{d}}}", .{model.billable_web_search_calls});
    }
    try writer.writeAll("],\"pending\":[");
    for (snapshot.pending, 0..) |pending, index| {
        if (index > 0) try writer.writeByte(',');
        try writePendingHead(writer, pending);
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
        try record.writeFact(writer, fact);
    }
    try writer.writeAll("],\"incidents\":[");
    for (snapshot.incidents, 0..) |incident, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"occurred_at_ms\":{d},\"completeness\":", .{incident.occurred_at_ms});
        try std.json.Stringify.value(@tagName(incident.completeness), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

/// Shared prefix through `cache_write_tokens`; the rich form leads with
/// `"schema_version":3`.
fn writeHead(writer: *std.Io.Writer, snapshot: Snapshot, rich: bool) std.Io.Writer.Error!void {
    try writer.writeAll(if (rich) "{\"schema_version\":3,\"billing\":" else "{\"billing\":");
    try std.json.Stringify.value(@tagName(snapshot.billing), .{}, writer);
    try writer.print(
        ",\"api_duration_complete\":{s},\"wall_duration_complete\":{s},\"code_complete\":{s},\"next_sequence\":{d},\"settled_through_sequence\":{d},\"api_duration_ms\":{d},\"wall_duration_ms\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d}",
        .{
            boolText(snapshot.api_duration_complete),
            boolText(snapshot.wall_duration_complete),
            boolText(snapshot.code_complete),
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
}

fn writeModelHead(writer: *std.Io.Writer, model: Model) std.Io.Writer.Error!void {
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model.model, .{}, writer);
    try writer.print(
        ",\"first_sequence\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d}",
        .{
            model.first_sequence,
            model.total_cost,
            model.input_tokens,
            model.output_tokens,
            model.cache_read_tokens,
            model.cache_write_tokens,
        },
    );
}

/// Pending keys shared by both shapes, without the closing brace.
fn writePendingHead(writer: *std.Io.Writer, pending: Pending) std.Io.Writer.Error!void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(pending.id, .{}, writer);
    try writer.print(",\"sequence\":{d},\"provider\":", .{pending.sequence});
    try std.json.Stringify.value(@tagName(pending.provider), .{}, writer);
    try writer.writeAll(",\"origin\":");
    try std.json.Stringify.value(pending.origin, .{}, writer);
    try writer.writeAll(",\"team\":");
    try writeOptionalString(writer, pending.team);
    try writer.writeAll(",\"credential_source\":");
    if (pending.credential_source) |source| {
        try std.json.Stringify.value(@tagName(source), .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"credential_identity\":");
    if (pending.credential_identity) |identity| {
        const hex = std.fmt.bytesToHex(identity, .lower);
        try std.json.Stringify.value(&hex, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"account_id\":");
    try writeOptionalString(writer, pending.account_id);
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn writeOptionalU64(writer: *std.Io.Writer, value: ?u64) std.Io.Writer.Error!void {
    if (value) |number| try writer.print("{d}", .{number}) else try writer.writeAll("null");
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) std.Io.Writer.Error!void {
    if (value) |text| try std.json.Stringify.value(text, .{}, writer) else try writer.writeAll("null");
}

// ---------------------------------------------------------------------------
// Parsers

/// Parses either shape strictly (`parseSnapshotValue`): an object with
/// exactly 18 keys is the rollback shape; anything else must have exactly 23
/// keys and `schema_version` 2 or 3. The caller owns the result.
pub fn parseValue(alloc: Allocator, value: std.json.Value) ParseError!Snapshot {
    var snapshot = try parseFields(alloc, value);
    errdefer snapshot.deinit(alloc);
    try validate(snapshot);
    return snapshot;
}

/// Lenient reader for legacy v3 events and state blobs
/// (`parseLegacySnapshotValue`): an 18-key snapshot whose only fault is a
/// model with cache tokens above input becomes `legacy_unavailable`. Every
/// other fault, and every versioned snapshot, is still an error.
pub fn parseLegacyValue(alloc: Allocator, value: std.json.Value) ParseError!Snapshot {
    var snapshot = try parseFields(alloc, value);
    errdefer snapshot.deinit(alloc);
    if (try validateContract(snapshot, isLegacyShape(value))) return snapshot;
    snapshot.deinit(alloc);
    return legacy_unavailable;
}

/// fx accepts these rich schema versions and parses them identically.
pub fn supportsSchema(schema_version: u64) bool {
    return schema_version == 2 or schema_version == 3;
}

fn isLegacyShape(value: std.json.Value) bool {
    return value == .object and value.object.count() == legacy_key_count;
}

fn parseFields(alloc: Allocator, value: std.json.Value) ParseError!Snapshot {
    if (value != .object) return error.InvalidUsageSnapshot;
    const object = value.object;
    const legacy = isLegacyShape(value);
    if (!legacy) {
        const schema_version = try parseU64(object.get("schema_version"));
        if (object.count() != rich_key_count or !supportsSchema(schema_version)) return error.InvalidUsageSnapshot;
    }
    const billing_value = object.get("billing") orelse return error.InvalidUsageSnapshot;
    if (billing_value != .string) return error.InvalidUsageSnapshot;
    const billing = std.meta.stringToEnum(Billing, billing_value.string) orelse return error.InvalidUsageSnapshot;
    const api_duration_complete = try parseBool(object.get("api_duration_complete"));
    const wall_duration_complete = try parseBool(object.get("wall_duration_complete"));
    const code_complete = try parseBool(object.get("code_complete"));
    const next_sequence = try parseU64(object.get("next_sequence"));
    const settled_through_sequence = try parseU64(object.get("settled_through_sequence"));
    const api_duration_ms = try parseU64(object.get("api_duration_ms"));
    const wall_duration_ms = try parseU64(object.get("wall_duration_ms"));
    const total_cost = try parseCost(object.get("total_cost"));
    const input_tokens = try parseU64(object.get("input_tokens"));
    const output_tokens = try parseU64(object.get("output_tokens"));
    const cache_read_tokens = try parseU64(object.get("cache_read_tokens"));
    const cache_write_tokens = try parseU64(object.get("cache_write_tokens"));
    const reasoning_tokens = if (legacy) null else try parseOptionalU64(object.get("reasoning_tokens") orelse
        return error.InvalidUsageSnapshot);
    const request_count = if (legacy) null else try parseOptionalU64(object.get("request_count") orelse
        return error.InvalidUsageSnapshot);
    const billable_web_search_calls = try parseU64(object.get("billable_web_search_calls"));
    const lines_added = try parseU64(object.get("lines_added"));
    const lines_removed = try parseU64(object.get("lines_removed"));
    const models_value = object.get("models") orelse return error.InvalidUsageSnapshot;
    const pending_value = object.get("pending") orelse return error.InvalidUsageSnapshot;
    if (models_value != .array or pending_value != .array) return error.InvalidUsageSnapshot;
    if (models_value.array.items.len > max_models or pending_value.array.items.len > max_pending) {
        return error.UsageCapacityExceeded;
    }

    const models = try parseModels(alloc, models_value.array.items, legacy);
    errdefer freeModels(alloc, models);
    const pending = try parsePendingList(alloc, pending_value.array.items);
    errdefer freePending(alloc, pending);
    const backlog = try parseBacklog(alloc, object, legacy);
    errdefer freeBacklog(alloc, backlog);
    const incidents = try parseIncidents(alloc, object, legacy);

    return .{
        .billing = billing,
        .api_duration_complete = api_duration_complete,
        .wall_duration_complete = wall_duration_complete,
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
        .publication_backlog = backlog,
        .incidents = incidents,
    };
}

fn parseModels(alloc: Allocator, values: []const std.json.Value, legacy: bool) ParseError![]Model {
    const models = try alloc.alloc(Model, values.len);
    var count: usize = 0;
    errdefer {
        for (models[0..count]) |model| alloc.free(model.model);
        alloc.free(models);
    }
    const expected_keys: usize = if (legacy) 8 else 10;
    for (values) |value| {
        if (value != .object or value.object.count() != expected_keys) return error.InvalidUsageSnapshot;
        const object = value.object;
        const name = object.get("model") orelse return error.InvalidUsageSnapshot;
        if (name != .string) return error.InvalidUsageSnapshot;
        const first_sequence = try parseU64(object.get("first_sequence"));
        const total_cost = try parseCost(object.get("total_cost"));
        const input_tokens = try parseU64(object.get("input_tokens"));
        const output_tokens = try parseU64(object.get("output_tokens"));
        const cache_read_tokens = try parseU64(object.get("cache_read_tokens"));
        const cache_write_tokens = try parseU64(object.get("cache_write_tokens"));
        const reasoning_tokens = if (legacy) null else try parseOptionalU64(object.get("reasoning_tokens") orelse
            return error.InvalidUsageSnapshot);
        const request_count = if (legacy) null else try parseOptionalU64(object.get("request_count") orelse
            return error.InvalidUsageSnapshot);
        const billable_web_search_calls = try parseU64(object.get("billable_web_search_calls"));
        models[count] = .{
            .model = try alloc.dupe(u8, name.string),
            .first_sequence = first_sequence,
            .total_cost = total_cost,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .cache_read_tokens = cache_read_tokens,
            .cache_write_tokens = cache_write_tokens,
            .reasoning_tokens = reasoning_tokens,
            .request_count = request_count,
            .billable_web_search_calls = billable_web_search_calls,
        };
        count += 1;
    }
    return models;
}

/// Pending entries take 4 or 5 keys without `provider` (gateway implied) and
/// 8 or 9 with it; the extra key is `observed_at_ms`. fx does not tie these
/// counts to the snapshot shape, so an 18-key snapshot may carry 9-key
/// entries and a rich one 4-key entries.
fn parsePendingList(alloc: Allocator, values: []const std.json.Value) ParseError![]Pending {
    const list = try alloc.alloc(Pending, values.len);
    var count: usize = 0;
    errdefer {
        for (list[0..count]) |entry| freePendingEntry(alloc, entry);
        alloc.free(list);
    }
    for (values) |value| {
        list[count] = try parsePendingEntry(alloc, value);
        count += 1;
    }
    return list;
}

fn parsePendingEntry(alloc: Allocator, value: std.json.Value) ParseError!Pending {
    if (value != .object) return error.InvalidUsageSnapshot;
    const object = value.object;
    const provider_scoped = object.contains("provider");
    const has_observed_at = object.contains("observed_at_ms");
    const expected_keys: usize = if (provider_scoped)
        (if (has_observed_at) 9 else 8)
    else if (has_observed_at) 5 else 4;
    if (object.count() != expected_keys) return error.InvalidUsageSnapshot;
    const id_value = object.get("id") orelse return error.InvalidUsageSnapshot;
    const origin_value = object.get("origin") orelse return error.InvalidUsageSnapshot;
    const team_value = object.get("team") orelse return error.InvalidUsageSnapshot;
    if (id_value != .string or origin_value != .string) return error.InvalidUsageSnapshot;
    const sequence = try parseU64(object.get("sequence"));
    const observed_at_ms = if (has_observed_at) try parseOptionalI64(object.get("observed_at_ms").?) else null;
    if (team_value != .null and team_value != .string) return error.InvalidUsageSnapshot;

    const id = try alloc.dupe(u8, id_value.string);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, origin_value.string);
    errdefer alloc.free(origin);
    const team: ?[]const u8 = if (team_value == .string) try alloc.dupe(u8, team_value.string) else null;
    errdefer if (team) |text| alloc.free(text);

    var entry = Pending{ .id = id, .sequence = sequence, .origin = origin, .team = team, .observed_at_ms = observed_at_ms };
    if (provider_scoped) {
        const provider_value = object.get("provider").?;
        if (provider_value != .string) return error.InvalidUsageSnapshot;
        entry.provider = parseProvider(provider_value.string) orelse return error.InvalidUsageSnapshot;
        entry.credential_source = try parseCredentialSource(object.get("credential_source"));
        entry.credential_identity = try parseCredentialIdentity(object.get("credential_identity"));
        entry.account_id = try parseOptionalString(alloc, object.get("account_id"));
    }
    return entry;
}

/// `model_provider.parse`: built-in names match case-insensitively; anything
/// else must be a valid configured provider id.
pub fn parseProvider(text: []const u8) ?Provider {
    if (std.ascii.eqlIgnoreCase(text, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(text, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(text, "grok")) return .grok;
    if (text.len == 0 or text.len > max_provider_id_bytes or !std.ascii.isAlphabetic(text[0])) return null;
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return null;
    }
    return .configured;
}

fn parseCredentialSource(value: ?std.json.Value) ParseError!?CredentialSource {
    const actual = value orelse return error.InvalidUsageSnapshot;
    return switch (actual) {
        .null => null,
        .string => |text| std.meta.stringToEnum(CredentialSource, text) orelse error.InvalidUsageSnapshot,
        else => error.InvalidUsageSnapshot,
    };
}

/// Exactly 64 lowercase hex digits, as fx's hexToBytes plus canonical check.
fn parseCredentialIdentity(value: ?std.json.Value) ParseError!?CredentialIdentity {
    const actual = value orelse return error.InvalidUsageSnapshot;
    switch (actual) {
        .null => return null,
        .string => |hex| {
            if (hex.len != 64) return error.InvalidUsageSnapshot;
            var bytes: CredentialIdentity = undefined;
            _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidUsageSnapshot;
            const canonical = std.fmt.bytesToHex(bytes, .lower);
            if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidUsageSnapshot;
            return bytes;
        },
        else => return error.InvalidUsageSnapshot,
    }
}

fn parseOptionalString(alloc: Allocator, value: ?std.json.Value) ParseError!?[]const u8 {
    const actual = value orelse return error.InvalidUsageSnapshot;
    return switch (actual) {
        .null => null,
        .string => |text| try alloc.dupe(u8, text),
        else => error.InvalidUsageSnapshot,
    };
}

fn parseBacklog(alloc: Allocator, object: std.json.ObjectMap, legacy: bool) ParseError![]GenerationFact {
    if (legacy) return &.{};
    const value = object.get("publication_backlog") orelse return error.InvalidUsageSnapshot;
    if (value != .array or value.array.items.len > max_backlog) return error.InvalidUsageSnapshot;
    const backlog = try alloc.alloc(GenerationFact, value.array.items.len);
    var count: usize = 0;
    errdefer {
        for (backlog[0..count]) |*fact| fact.deinit(alloc);
        alloc.free(backlog);
    }
    for (value.array.items) |item| {
        backlog[count] = record.parseFact(alloc, item) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidGenerationFact => return error.InvalidUsageSnapshot,
        };
        count += 1;
    }
    return backlog;
}

fn parseIncidents(alloc: Allocator, object: std.json.ObjectMap, legacy: bool) ParseError![]Incident {
    if (legacy) return &.{};
    const value = object.get("incidents") orelse return error.InvalidUsageSnapshot;
    if (value != .array or value.array.items.len > max_incidents) return error.InvalidUsageSnapshot;
    const incidents = try alloc.alloc(Incident, value.array.items.len);
    errdefer alloc.free(incidents);
    for (value.array.items, incidents) |item, *incident| {
        if (item != .object or item.object.count() != 2) return error.InvalidUsageSnapshot;
        const completeness_value = item.object.get("completeness") orelse return error.InvalidUsageSnapshot;
        if (completeness_value != .string) return error.InvalidUsageSnapshot;
        // fx's enum also has `complete` and `legacy`, which its validator
        // then rejects with the same error; this enum rejects them here.
        const completeness = std.meta.stringToEnum(record.IncidentCompleteness, completeness_value.string) orelse
            return error.InvalidUsageSnapshot;
        incident.* = .{
            .occurred_at_ms = try parseI64(item.object.get("occurred_at_ms")),
            .completeness = completeness,
        };
    }
    return incidents;
}

fn parseBool(value: ?std.json.Value) ParseError!bool {
    const actual = value orelse return error.InvalidUsageSnapshot;
    if (actual != .bool) return error.InvalidUsageSnapshot;
    return actual.bool;
}

fn parseU64(value: ?std.json.Value) ParseError!u64 {
    const actual = value orelse return error.InvalidGenerationRecord;
    return switch (actual) {
        .integer => |number| if (number >= 0)
            std.math.cast(u64, number) orelse error.InvalidGenerationRecord
        else
            error.InvalidGenerationRecord,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch error.InvalidGenerationRecord,
        else => error.InvalidGenerationRecord,
    };
}

fn parseI64(value: ?std.json.Value) ParseError!i64 {
    return std.math.cast(i64, try parseU64(value)) orelse error.InvalidGenerationRecord;
}

fn parseOptionalU64(value: std.json.Value) ParseError!?u64 {
    if (value == .null) return null;
    return try parseU64(value);
}

fn parseOptionalI64(value: std.json.Value) ParseError!?i64 {
    if (value == .null) return null;
    return try parseI64(value);
}

fn parseCost(value: ?std.json.Value) ParseError!f64 {
    const actual = value orelse return error.InvalidGenerationRecord;
    const number: f64 = switch (actual) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch return error.InvalidGenerationRecord,
        else => return error.InvalidGenerationRecord,
    };
    if (!std.math.isFinite(number) or number < 0) return error.InvalidGenerationRecord;
    return number;
}

/// An owned deep copy of `source`, which may borrow; free with
/// `Snapshot.deinit`.
pub fn dupe(alloc: Allocator, source: Snapshot) Allocator.Error!Snapshot {
    var copy = source;
    copy.models = &.{};
    copy.pending = &.{};
    copy.publication_backlog = &.{};
    copy.incidents = &.{};
    errdefer copy.deinit(alloc);
    copy.models = try dupeModels(alloc, source.models);
    copy.pending = try dupePending(alloc, source.pending);
    copy.publication_backlog = try dupeBacklog(alloc, source.publication_backlog);
    copy.incidents = try alloc.dupe(Incident, source.incidents);
    return copy;
}

fn dupeModels(alloc: Allocator, models: []const Model) Allocator.Error![]const Model {
    const out = try alloc.alloc(Model, models.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |model| alloc.free(model.model);
        alloc.free(out);
    }
    for (models, out) |model, *dst| {
        dst.* = model;
        dst.model = try alloc.dupe(u8, model.model);
        done += 1;
    }
    return out;
}

fn dupePending(alloc: Allocator, pending: []const Pending) Allocator.Error![]const Pending {
    const out = try alloc.alloc(Pending, pending.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |entry| freePendingEntry(alloc, entry);
        alloc.free(out);
    }
    for (pending, out) |entry, *dst| {
        const id = try alloc.dupe(u8, entry.id);
        errdefer alloc.free(id);
        const origin = try alloc.dupe(u8, entry.origin);
        errdefer alloc.free(origin);
        const team = if (entry.team) |value| try alloc.dupe(u8, value) else null;
        errdefer if (team) |value| alloc.free(value);
        const account_id = if (entry.account_id) |value| try alloc.dupe(u8, value) else null;
        dst.* = entry;
        dst.id = id;
        dst.origin = origin;
        dst.team = team;
        dst.account_id = account_id;
        done += 1;
    }
    return out;
}

fn dupeBacklog(alloc: Allocator, backlog: []const GenerationFact) Allocator.Error![]const GenerationFact {
    const out = try alloc.alloc(GenerationFact, backlog.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |fact| {
            alloc.free(fact.id);
            alloc.free(fact.model);
        }
        alloc.free(out);
    }
    for (backlog, out) |fact, *dst| {
        const id = try alloc.dupe(u8, fact.id);
        errdefer alloc.free(id);
        dst.* = fact;
        dst.id = id;
        dst.model = try alloc.dupe(u8, fact.model);
        done += 1;
    }
    return out;
}

fn freeModels(alloc: Allocator, models: []const Model) void {
    for (models) |model| alloc.free(model.model);
    alloc.free(models);
}

fn freePendingEntry(alloc: Allocator, entry: Pending) void {
    alloc.free(entry.id);
    alloc.free(entry.origin);
    if (entry.team) |team| alloc.free(team);
    if (entry.account_id) |account_id| alloc.free(account_id);
}

fn freePending(alloc: Allocator, pending: []const Pending) void {
    for (pending) |entry| freePendingEntry(alloc, entry);
    alloc.free(pending);
}

fn freeBacklog(alloc: Allocator, backlog: []const GenerationFact) void {
    for (backlog) |fact| {
        alloc.free(fact.id);
        alloc.free(fact.model);
    }
    alloc.free(backlog);
}

// ---------------------------------------------------------------------------
// v1 sidecar: sessions/<id>/usage-v2.json

pub const Sidecar = struct {
    session_id: []const u8,
    snapshot: Snapshot,

    pub fn deinit(self: *Sidecar, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

/// Encodes the sidecar (`session_usage_sidecar.encode`). The caller owns the
/// bytes. Fails with `UsageSidecarTooLarge` above `max_sidecar_bytes`.
pub fn encodeSidecar(
    alloc: Allocator,
    session_id: []const u8,
    snapshot: Snapshot,
) (Allocator.Error || ValidateError || record.FactError || error{UsageSidecarTooLarge})![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeEnvelope(&out.writer, session_id, snapshot) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    if (out.written().len > max_sidecar_bytes) return error.UsageSidecarTooLarge;
    return out.toOwnedSlice();
}

fn writeEnvelope(writer: *std.Io.Writer, session_id: []const u8, snapshot: Snapshot) WriteError!void {
    try writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, writer);
    try writer.writeAll(",\"snapshot\":");
    try writeRich(writer, snapshot);
    try writer.writeByte('}');
}

/// Decodes the sidecar (`session_usage_sidecar.decode`): 1..max bytes, an
/// object of exactly 3 keys, integer `schema_version` 1, a non-empty string
/// `session_id`, and a versioned snapshot object (the 18-key shape is
/// rejected here). Snapshot faults keep their snapshot error names. The
/// caller checks that `session_id` matches the folder.
pub fn parseSidecar(alloc: Allocator, bytes: []const u8) SidecarError!Sidecar {
    if (bytes.len == 0 or bytes.len > max_sidecar_bytes) return error.InvalidUsageSidecar;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUsageSidecar,
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object or root.object.count() != 3) return error.InvalidUsageSidecar;
    const schema = root.object.get("schema_version") orelse return error.InvalidUsageSidecar;
    if (schema != .integer or schema.integer != 1) return error.InvalidUsageSidecar;
    const id_value = root.object.get("session_id") orelse return error.InvalidUsageSidecar;
    if (id_value != .string or id_value.string.len == 0) return error.InvalidUsageSidecar;
    const snapshot_value = root.object.get("snapshot") orelse return error.InvalidUsageSidecar;
    if (snapshot_value != .object or snapshot_value.object.get("schema_version") == null) {
        return error.InvalidUsageSidecar;
    }
    const session_id = try alloc.dupe(u8, id_value.string);
    errdefer alloc.free(session_id);
    return .{ .session_id = session_id, .snapshot = try parseValue(alloc, snapshot_value) };
}

// ---------------------------------------------------------------------------
// sessions-v2 `set usage` value

pub const V2Value = struct {
    at_ms: i64,
    snapshot: Snapshot,

    pub fn deinit(self: *V2Value, alloc: Allocator) void {
        self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

/// Encodes `{"at_ms":N,"snapshot":<rich>}` (`session_adapter.encodeUsage`).
/// The caller owns the bytes.
pub fn encodeV2Value(
    alloc: Allocator,
    snapshot: Snapshot,
    at_ms: i64,
) (Allocator.Error || ValidateError || record.FactError)![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeV2Value(&out.writer, snapshot, at_ms) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

fn writeV2Value(writer: *std.Io.Writer, snapshot: Snapshot, at_ms: i64) WriteError!void {
    try writer.print("{{\"at_ms\":{d},\"snapshot\":", .{at_ms});
    try writeRich(writer, snapshot);
    try writer.writeByte('}');
}

/// Decodes a `set usage` value (`session_adapter.decodeUsage`). Like fx, it
/// requires only an object with an integer `at_ms` (any sign) and a
/// `snapshot` that `parseValue` accepts, so extra keys pass and the snapshot
/// may be the 18-key shape. JSON syntax errors map to
/// `InvalidUsageCheckpoint`. The caller owns the result.
pub fn parseV2Value(alloc: Allocator, bytes: []const u8) V2Error!V2Value {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUsageCheckpoint,
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidUsageCheckpoint;
    const at = root.object.get("at_ms") orelse return error.InvalidUsageCheckpoint;
    if (at != .integer) return error.InvalidUsageCheckpoint;
    const snapshot = root.object.get("snapshot") orelse return error.InvalidUsageCheckpoint;
    return .{ .at_ms = at.integer, .snapshot = try parseValue(alloc, snapshot) };
}

// ---------------------------------------------------------------------------
// Tests. Fixture tests read the compat fixtures embedded from
// testdata/compat/, so they run from any working directory.

const testing = std.testing;
const testdata = @import("../testdata/dir.zig");
const max_fixture_bytes = 1 << 22;

fn openFixtures() !testdata.Dir {
    return testdata.Dir.open("compat");
}

fn readFixture(alloc: Allocator, dir: testdata.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, path, alloc, .limited(max_fixture_bytes));
}

/// Directory entry names under `path`, sorted. Caller frees with `freeNames`.
fn listNames(alloc: Allocator, dir: testdata.Dir, path: []const u8, kind: std.Io.File.Kind) ![][]u8 {
    var sub = try dir.openDir(testing.io, path, .{ .iterate = true });
    defer sub.close(testing.io);
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var it = sub.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != kind) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.toOwnedSlice(alloc);
}

fn freeNames(alloc: Allocator, names: [][]u8) void {
    for (names) |name| alloc.free(name);
    alloc.free(names);
}

fn richOf(alloc: Allocator, snapshot: Snapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeRich(&out.writer, snapshot);
    return out.toOwnedSlice();
}

fn legacyOf(alloc: Allocator, snapshot: Snapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeLegacy18(&out.writer, snapshot);
    return out.toOwnedSlice();
}

fn parseText(alloc: Allocator, text: []const u8, parse_numbers: bool) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, text, .{ .parse_numbers = parse_numbers });
}

/// Parses 18-key bytes the way each legacy reader does and requires that
/// both readers, in both number modes, re-encode them unchanged.
fn expectLegacyStable(alloc: Allocator, bytes: []const u8) !void {
    for ([_]bool{ true, false }) |parse_numbers| {
        var parsed = try parseText(alloc, bytes, parse_numbers);
        defer parsed.deinit();
        var strict = try parseValue(alloc, parsed.value);
        defer strict.deinit(alloc);
        var lenient = try parseLegacyValue(alloc, parsed.value);
        defer lenient.deinit(alloc);
        for ([_]Snapshot{ strict, lenient }) |snapshot| {
            const again = try legacyOf(alloc, snapshot);
            defer alloc.free(again);
            try testing.expectEqualStrings(bytes, again);
        }
    }
}

test "captured v1 sidecars round-trip byte-identically and match fx's 18-key bytes" {
    const alloc = testing.allocator;
    var root = try openFixtures();
    defer root.close(testing.io);
    const names = try listNames(alloc, root, "fx-home/sessions", .directory);
    defer freeNames(alloc, names);
    var checked: usize = 0;
    for (names) |name| {
        if (std.mem.eql(u8, name, "v2")) continue;
        const path = try std.fmt.allocPrint(alloc, "fx-home/sessions/{s}/usage-v2.json", .{name});
        defer alloc.free(path);
        const bytes = try readFixture(alloc, root, path);
        defer alloc.free(bytes);
        var sidecar = try parseSidecar(alloc, bytes);
        defer sidecar.deinit(alloc);
        try testing.expectEqualStrings(name, sidecar.session_id);
        const encoded = try encodeSidecar(alloc, sidecar.session_id, sidecar.snapshot);
        defer alloc.free(encoded);
        try testing.expectEqualStrings(bytes, encoded);

        // fx's writeSnapshot output for this snapshot (derive.sh).
        const legacy_path = try std.fmt.allocPrint(alloc, "derived/legacy18/v1-{s}.json", .{name});
        defer alloc.free(legacy_path);
        const fx_legacy = try readFixture(alloc, root, legacy_path);
        defer alloc.free(fx_legacy);
        const legacy = try legacyOf(alloc, sidecar.snapshot);
        defer alloc.free(legacy);
        try testing.expectEqualStrings(fx_legacy, legacy);
        try expectLegacyStable(alloc, fx_legacy);
        checked += 1;
    }
    try testing.expect(checked >= 8);
}

test "captured v2 set usage values round-trip byte-identically and match fx's 18-key bytes" {
    const alloc = testing.allocator;
    var root = try openFixtures();
    defer root.close(testing.io);
    const names = try listNames(alloc, root, "fx-home/sessions/v2", .directory);
    defer freeNames(alloc, names);
    const value_key = ",\"kind\":\"set\",\"key\":\"usage\",\"value\":";
    var checked: usize = 0;
    for (names) |name| {
        const path = try std.fmt.allocPrint(alloc, "fx-home/sessions/v2/{s}/log.jsonl", .{name});
        defer alloc.free(path);
        const log = try readFixture(alloc, root, path);
        defer alloc.free(log);
        var lines = std.mem.splitScalar(u8, log, '\n');
        while (lines.next()) |line| {
            const key_at = std.mem.indexOf(u8, line, value_key) orelse continue;
            const crc_at = std.mem.lastIndexOf(u8, line, ",\"crc\":\"") orelse return error.MalformedV2Line;
            const value = line[key_at + value_key.len .. crc_at];
            var decoded = try parseV2Value(alloc, value);
            defer decoded.deinit(alloc);
            const encoded = try encodeV2Value(alloc, decoded.snapshot, decoded.at_ms);
            defer alloc.free(encoded);
            try testing.expectEqualStrings(value, encoded);

            const seq_start = (std.mem.indexOf(u8, line, "\"seq\":") orelse return error.MalformedV2Line) + 6;
            const seq_end = std.mem.indexOfScalarPos(u8, line, seq_start, ',') orelse return error.MalformedV2Line;
            const legacy_path = try std.fmt.allocPrint(alloc, "derived/legacy18/v2-{s}-seq{s}.json", .{ name, line[seq_start..seq_end] });
            defer alloc.free(legacy_path);
            const fx_legacy = try readFixture(alloc, root, legacy_path);
            defer alloc.free(fx_legacy);
            const legacy = try legacyOf(alloc, decoded.snapshot);
            defer alloc.free(legacy);
            try testing.expectEqualStrings(fx_legacy, legacy);
            checked += 1;
        }
    }
    try testing.expect(checked >= 5);
}

test "legacy v3 usage_checkpointed frames carry the 18-key bytes unchanged" {
    const alloc = testing.allocator;
    var root = try openFixtures();
    defer root.close(testing.io);
    const names = try listNames(alloc, root, "derived/v3-events", .file);
    defer freeNames(alloc, names);
    const prefix = "\"kind\":\"usage_checkpointed\",\"payload\":{\"usage\":";
    for (names) |name| {
        const path = try std.fmt.allocPrint(alloc, "derived/v3-events/{s}", .{name});
        defer alloc.free(path);
        const frame = try readFixture(alloc, root, path);
        defer alloc.free(frame);
        try testing.expect(std.mem.endsWith(u8, frame, "}}\n"));
        const start = (std.mem.indexOf(u8, frame, prefix) orelse return error.MalformedFrame) + prefix.len;
        const usage_bytes = frame[start .. frame.len - 3];
        // The v3 decoder parses frames with parse_numbers=false.
        var parsed = try parseText(alloc, frame[0 .. frame.len - 1], false);
        defer parsed.deinit();
        const usage_value = parsed.value.object.get("payload").?.object.get("usage").?;
        var snapshot = try parseLegacyValue(alloc, usage_value);
        defer snapshot.deinit(alloc);
        const again = try legacyOf(alloc, snapshot);
        defer alloc.free(again);
        try testing.expectEqualStrings(usage_bytes, again);
    }
    try testing.expect(names.len >= 13);
}

const CorpusCase = struct { name: []const u8, parser: []const u8, input: []const u8 };
const CorpusVerdict = struct {
    name: []const u8,
    ok: bool,
    @"error": ?[]const u8 = null,
    rich: ?[]const u8 = null,
    legacy18: ?[]const u8 = null,
    sidecar: ?[]const u8 = null,
    v2: ?[]const u8 = null,
    record: ?[]const u8 = null,
};

/// Runs one corpus case through this codec and returns its verdict in the
/// same shape derive.sh records for fx. Strings live in `arena`.
fn judgeCase(arena: Allocator, case: CorpusCase) !CorpusVerdict {
    var verdict = CorpusVerdict{ .name = case.name, .ok = false };
    if (std.mem.eql(u8, case.parser, "strict") or std.mem.eql(u8, case.parser, "lenient")) {
        const lenient = std.mem.eql(u8, case.parser, "lenient");
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, case.input, .{
            .parse_numbers = !lenient,
        }) catch |err| {
            verdict.@"error" = @errorName(err);
            return verdict;
        };
        const snapshot = (if (lenient) parseLegacyValue(arena, value) else parseValue(arena, value)) catch |err| {
            verdict.@"error" = @errorName(err);
            return verdict;
        };
        verdict.ok = true;
        verdict.rich = try richOf(arena, snapshot);
        verdict.legacy18 = try legacyOf(arena, snapshot);
    } else if (std.mem.eql(u8, case.parser, "sidecar")) {
        const sidecar = parseSidecar(arena, case.input) catch |err| {
            verdict.@"error" = @errorName(err);
            return verdict;
        };
        verdict.ok = true;
        verdict.sidecar = try encodeSidecar(arena, sidecar.session_id, sidecar.snapshot);
    } else if (std.mem.eql(u8, case.parser, "v2")) {
        const decoded = parseV2Value(arena, case.input) catch |err| {
            verdict.@"error" = @errorName(err);
            return verdict;
        };
        verdict.ok = true;
        verdict.v2 = try encodeV2Value(arena, decoded.snapshot, decoded.at_ms);
    } else return error.UnknownCaseParser;
    return verdict;
}

fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected == null or actual == null) return testing.expectEqual(expected == null, actual == null);
    try testing.expectEqualStrings(expected.?, actual.?);
}

test "differential corpus: every snapshot reader rule agrees with fx" {
    const alloc = testing.allocator;
    var root = try openFixtures();
    defer root.close(testing.io);
    const corpus = try readFixture(alloc, root, "cases/snapshot.jsonl");
    defer alloc.free(corpus);
    const expected = try readFixture(alloc, root, "derived/cases/snapshot.expected.jsonl");
    defer alloc.free(expected);

    var case_lines = std.mem.splitScalar(u8, corpus, '\n');
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var count: usize = 0;
    var rejected: usize = 0;
    while (case_lines.next()) |case_line| {
        if (case_line.len == 0) continue;
        const expected_line = expected_lines.next() orelse return error.ExpectedVerdictMissing;
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const case = try std.json.parseFromSliceLeaky(CorpusCase, arena, case_line, .{});
        const want = try std.json.parseFromSliceLeaky(CorpusVerdict, arena, expected_line, .{});
        try testing.expectEqualStrings(want.name, case.name);
        const got = try judgeCase(arena, case);
        if (got.ok != want.ok) {
            std.debug.print("case {s}: fx ok={} error={?s}, codec ok={} error={?s}\n", .{ case.name, want.ok, want.@"error", got.ok, got.@"error" });
            return error.VerdictMismatch;
        }
        expectOptionalString(want.@"error", got.@"error") catch |err| {
            std.debug.print("case {s}\n", .{case.name});
            return err;
        };
        try expectOptionalString(want.rich, got.rich);
        try expectOptionalString(want.legacy18, got.legacy18);
        try expectOptionalString(want.sidecar, got.sidecar);
        try expectOptionalString(want.v2, got.v2);
        if (!want.ok) rejected += 1;
        count += 1;
    }
    try testing.expect(expected_lines.next() == null or expected_lines.rest().len == 0);
    try testing.expectEqual(@as(usize, 178), count);
    try testing.expectEqual(@as(usize, 128), rejected);
}

// fx `legacyUsageForTest` (session_usage.zig:4489).
const fx_legacy_vector =
    \\{"billing":"complete","api_duration_complete":true,"wall_duration_complete":true,"code_complete":true,"next_sequence":2,"settled_through_sequence":1,
    \\"api_duration_ms":10,"wall_duration_ms":20,"total_cost":1,"input_tokens":10,"output_tokens":3,"cache_read_tokens":2,"cache_write_tokens":0,"billable_web_search_calls":0,"lines_added":0,"lines_removed":0,
    \\"models":[{"model":"test/model","first_sequence":1,"total_cost":1,"input_tokens":10,"output_tokens":3,"cache_read_tokens":2,"cache_write_tokens":0,"billable_web_search_calls":0}],"pending":[]}
;

test "fx vector: legacy compatibility preserves valid snapshots and strict parsing" {
    const alloc = testing.allocator;
    var parsed = try parseText(alloc, fx_legacy_vector, true);
    defer parsed.deinit();
    var strict = try parseValue(alloc, parsed.value);
    defer strict.deinit(alloc);
    var compatible = try parseLegacyValue(alloc, parsed.value);
    defer compatible.deinit(alloc);
    const strict_rich = try richOf(alloc, strict);
    defer alloc.free(strict_rich);
    const compatible_rich = try richOf(alloc, compatible);
    defer alloc.free(compatible_rich);
    try testing.expectEqualStrings(strict_rich, compatible_rich);

    for ([_][]const u8{ "cache_read_tokens", "cache_write_tokens" }) |field| {
        const global = parsed.value.object.getPtr(field).?;
        const model = parsed.value.object.getPtr("models").?.array.items[0].object.getPtr(field).?;
        const saved = global.*;
        global.* = .{ .integer = 11 };
        model.* = global.*;
        var unavailable = try parseLegacyValue(alloc, parsed.value);
        defer unavailable.deinit(alloc);
        try validate(unavailable);
        try testing.expectEqual(Billing.legacy, unavailable.billing);
        try testing.expectEqual(@as(usize, 0), unavailable.models.len);
        try testing.expectEqual(@as(usize, 0), unavailable.pending.len);
        try testing.expectError(error.InvalidUsageSnapshot, parseValue(alloc, parsed.value));
        global.* = saved;
        model.* = saved;
    }

    // A rich snapshot is never downgraded, even by the lenient reader.
    var rich = try parseText(alloc, strict_rich, true);
    defer rich.deinit();
    var rich_copy = try parseLegacyValue(alloc, rich.value);
    defer rich_copy.deinit(alloc);
    rich.value.object.getPtr("cache_read_tokens").?.* = .{ .integer = 11 };
    rich.value.object.getPtr("models").?.array.items[0].object.getPtr("cache_read_tokens").?.* = .{ .integer = 11 };
    try testing.expectError(error.InvalidUsageSnapshot, parseLegacyValue(alloc, rich.value));
}

test "fx vector: legacy compatibility does not hide malformed accounting" {
    const alloc = testing.allocator;
    var parsed = try parseText(alloc, fx_legacy_vector, true);
    defer parsed.deinit();
    parsed.value.object.getPtr("cache_read_tokens").?.* = .{ .integer = 11 };
    const model = &parsed.value.object.getPtr("models").?.array.items[0];
    model.object.getPtr("cache_read_tokens").?.* = .{ .integer = 11 };

    const cases = [_]struct { field: []const u8, value: std.json.Value, want: ParseError }{
        .{ .field = "total_cost", .value = .{ .float = -1 }, .want = error.InvalidGenerationRecord },
        .{ .field = "total_cost", .value = .{ .float = std.math.inf(f64) }, .want = error.InvalidGenerationRecord },
        .{ .field = "input_tokens", .value = .{ .integer = 9 }, .want = error.InvalidUsageSnapshot },
        .{ .field = "next_sequence", .value = .{ .integer = 0 }, .want = error.InvalidUsageSnapshot },
    };
    for (cases) |case| {
        const field = parsed.value.object.getPtr(case.field).?;
        const saved = field.*;
        field.* = case.value;
        try testing.expectError(case.want, parseLegacyValue(alloc, parsed.value));
        try testing.expectError(case.want, parseValue(alloc, parsed.value));
        field.* = saved;
    }
    model.object.getPtr("first_sequence").?.* = .{ .integer = 0 };
    try testing.expectError(error.InvalidUsageSnapshot, parseLegacyValue(alloc, parsed.value));
    model.object.getPtr("first_sequence").?.* = .{ .integer = 1 };
    try parsed.value.object.put(parsed.arena.allocator(), "unknown", .null);
    try testing.expectError(error.InvalidGenerationRecord, parseLegacyValue(alloc, parsed.value));
    try testing.expectError(error.InvalidUsageSnapshot, parseLegacyValue(alloc, .null));
}

test "parsers release every partial allocation" {
    const alloc = testing.allocator;
    var root = try openFixtures();
    defer root.close(testing.io);
    const corpus = try readFixture(alloc, root, "cases/snapshot.jsonl");
    defer alloc.free(corpus);
    // rich.base exercises every owned field: models, pending strings,
    // backlog facts, incidents.
    const first_line = corpus[0 .. std.mem.indexOfScalar(u8, corpus, '\n') orelse corpus.len];
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const case = try std.json.parseFromSliceLeaky(CorpusCase, arena_state.allocator(), first_line, .{});
    try testing.expectEqualStrings("rich.base", case.name);

    var parsed = try parseText(alloc, case.input, true);
    defer parsed.deinit();
    const Check = struct {
        fn run(a: Allocator, value: std.json.Value) !void {
            var snapshot = try parseValue(a, value);
            snapshot.deinit(a);
            var lenient = try parseLegacyValue(a, value);
            lenient.deinit(a);
        }
    };
    try testing.checkAllAllocationFailures(alloc, Check.run, .{parsed.value});

    const sidecar = try std.fmt.allocPrint(alloc, "{{\"schema_version\":1,\"session_id\":\"s\",\"snapshot\":{s}}}", .{case.input});
    defer alloc.free(sidecar);
    const SidecarCheck = struct {
        fn run(a: Allocator, bytes: []const u8) !void {
            var decoded = try parseSidecar(a, bytes);
            decoded.deinit(a);
        }
    };
    try testing.checkAllAllocationFailures(alloc, SidecarCheck.run, .{sidecar});
}

const test_identity: CredentialIdentity = @splat(0xab);

fn validFixtureSnapshot() Snapshot {
    const S = struct {
        const models = [_]Model{
            .{ .model = "a/one", .first_sequence = 1, .total_cost = 0.5, .input_tokens = 4, .output_tokens = 2, .reasoning_tokens = 1, .request_count = 1 },
        };
        const pending = [_]Pending{
            .{ .id = "gen_01M4BNAYQN549RDT01D45TGP5T", .sequence = 2, .origin = "https://ai-gateway.vercel.sh", .team = null, .credential_source = .fx_login, .credential_identity = test_identity, .observed_at_ms = 7 },
        };
    };
    return .{
        .billing = .pending,
        .api_duration_complete = true,
        .wall_duration_complete = true,
        .code_complete = true,
        .next_sequence = 3,
        .settled_through_sequence = 1,
        .api_duration_ms = 1,
        .wall_duration_ms = 2,
        .total_cost = 0.5,
        .input_tokens = 4,
        .output_tokens = 2,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .request_count = 1,
        .billable_web_search_calls = 0,
        .lines_added = 0,
        .lines_removed = 0,
        .models = &S.models,
        .pending = &S.pending,
    };
}

test "writers validate first and refuse snapshots no reader accepts" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var snapshot = validFixtureSnapshot();
    try writeRich(&writer, snapshot);
    writer = .fixed(&buffer);
    try writeLegacy18(&writer, snapshot);

    snapshot.settled_through_sequence = 3;
    writer = .fixed(&buffer);
    try testing.expectError(error.InvalidUsageSnapshot, writeRich(&writer, snapshot));
    try testing.expectError(error.InvalidUsageSnapshot, writeLegacy18(&writer, snapshot));
    try testing.expectError(error.InvalidUsageSnapshot, encodeV2Value(testing.allocator, snapshot, 0));
    try testing.expectError(error.InvalidUsageSnapshot, encodeSidecar(testing.allocator, "s", snapshot));
}

test "validation rules JSON cannot express" {
    const base = validFixtureSnapshot();
    try validate(base);

    var snapshot = base;
    snapshot.total_cost = std.math.inf(f64);
    try testing.expectError(error.InvalidUsageSnapshot, validate(snapshot));
    snapshot.total_cost = std.math.nan(f64);
    try testing.expectError(error.InvalidUsageSnapshot, validate(snapshot));

    const nan_model = [_]Model{.{ .model = "a/one", .first_sequence = 1, .total_cost = std.math.nan(f64), .input_tokens = 4, .output_tokens = 2, .reasoning_tokens = 1, .request_count = 1 }};
    snapshot = base;
    snapshot.models = &nan_model;
    try testing.expectError(error.InvalidUsageSnapshot, validate(snapshot));

    const overflow_models = [_]Model{
        .{ .model = "a/one", .first_sequence = 1, .input_tokens = std.math.maxInt(u64) },
        .{ .model = "a/two", .first_sequence = 2, .input_tokens = 1 },
    };
    snapshot = base;
    snapshot.models = &overflow_models;
    snapshot.reasoning_tokens = null;
    snapshot.request_count = null;
    try testing.expectError(error.InvalidUsageSnapshot, validate(snapshot));

    const negative_observed = [_]Pending{.{ .id = "gen_01M4BNAYQN549RDT01D45TGP5T", .sequence = 2, .origin = "o", .team = null, .observed_at_ms = -1 }};
    snapshot = base;
    snapshot.pending = &negative_observed;
    try testing.expectError(error.InvalidUsageSnapshot, validate(snapshot));

    const negative_incident = [_]Incident{.{ .occurred_at_ms = -1, .completeness = .pending }};
    snapshot = base;
    snapshot.incidents = &negative_incident;
    try testing.expectError(error.InvalidUsageSnapshot, validate(snapshot));

    // Caps are UsageCapacityExceeded in validation even where the parser
    // reports InvalidUsageSnapshot (backlog, incidents).
    const many_incidents = [_]Incident{.{ .occurred_at_ms = 1, .completeness = .pending }} ** (max_incidents + 1);
    snapshot = base;
    snapshot.incidents = &many_incidents;
    try testing.expectError(error.UsageCapacityExceeded, validate(snapshot));
    const fact = GenerationFact{ .id = "gen_01M4BNAZ8NS50TRNYFRJJESTF4", .created_at_ms = 0, .model = "m", .input_tokens = 0, .output_tokens = 0, .cache_read_tokens = 0, .cache_write_tokens = 0, .reasoning_tokens = null, .total_cost = 0 };
    const many_facts = [_]GenerationFact{fact} ** (max_backlog + 1);
    snapshot = base;
    snapshot.publication_backlog = &many_facts;
    try testing.expectError(error.UsageCapacityExceeded, validate(snapshot));
}

test "identifier budget is inclusive at 8 KiB" {
    // One model name ("a/one", 5 bytes) plus three pending entries of
    // 30 + 2048 bytes is 6239; a fourth entry with a 1923-byte origin lands
    // exactly on 8192, and one more byte exceeds the budget.
    const per_entry = 2048;
    const entry_origin = [_]u8{'o'} ** per_entry;
    const last_len = max_identifier_bytes - 5 - 3 * (30 + per_entry) - 30;
    const last_origin = [_]u8{'o'} ** last_len;
    const last_over = [_]u8{'o'} ** (last_len + 1);
    const ids = [_][]const u8{ "gen_01M4BNAYQN549RDT01D45TG001", "gen_01M4BNAYQN549RDT01D45TG002", "gen_01M4BNAYQN549RDT01D45TG003", "gen_01M4BNAYQN549RDT01D45TG004" };
    var entries: [4]Pending = undefined;
    for (&entries, ids, 0..) |*entry, id, index| {
        entry.* = .{ .id = id, .sequence = index + 2, .origin = &entry_origin, .team = null };
    }
    entries[3].origin = &last_origin;
    var snapshot = validFixtureSnapshot();
    snapshot.next_sequence = 6;
    snapshot.pending = &entries;
    try validate(snapshot);
    entries[3].origin = &last_over;
    try testing.expectError(error.UsageCapacityExceeded, validate(snapshot));
}

test "cost tolerance follows fx: max(1e-12, total * 1e-12)" {
    var snapshot = validFixtureSnapshot();
    snapshot.total_cost = 0.5 + 0.9e-12;
    try validate(snapshot);
    snapshot.total_cost = 0.5 + 1.1e-12;
    try testing.expectError(error.InvalidUsageSnapshot, validate(snapshot));
}

test "sidecar size limits" {
    const alloc = testing.allocator;
    const long_id = try alloc.alloc(u8, max_sidecar_bytes);
    defer alloc.free(long_id);
    @memset(long_id, 'a');
    try testing.expectError(error.UsageSidecarTooLarge, encodeSidecar(alloc, long_id, validFixtureSnapshot()));

    const oversized = try alloc.alloc(u8, max_sidecar_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, ' ');
    try testing.expectError(error.InvalidUsageSidecar, parseSidecar(alloc, oversized));
    try testing.expectError(error.InvalidUsageSidecar, parseSidecar(alloc, ""));
}

test "v2 value JSON syntax errors map to InvalidUsageCheckpoint" {
    // fx propagates std.json's error here; a v2 log line is already valid
    // JSON when this runs, so only the name differs.
    try testing.expectError(error.InvalidUsageCheckpoint, parseV2Value(testing.allocator, "{"));
}

test "fx vector: providers authorize only their own credential origins" {
    // model_provider.zig "explicit providers authorize only their own credential origins"
    try testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key));
    try testing.expect(authorizesCredential(.gateway, .fx_login));
    try testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription));
    try testing.expect(authorizesCredential(.codex, .chatgpt_subscription));
    try testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key));
    try testing.expect(authorizesCredential(.grok, .grok_subscription));
    try testing.expect(!authorizesCredential(.grok, .chatgpt_subscription));
    try testing.expect(!authorizesCredential(.gateway, .grok_subscription));
    try testing.expect(!authorizesCredential(.gateway, .configured));
    try testing.expect(authorizesCredential(.configured, .configured));
    for (std.meta.tags(Provider)) |provider| try testing.expect(authorizesCredential(provider, .host_managed));
}

test "provider names parse like model_provider.parse" {
    try testing.expectEqual(Provider.gateway, parseProvider("GaTeWaY").?);
    try testing.expectEqual(Provider.codex, parseProvider("CODEX").?);
    try testing.expectEqual(Provider.grok, parseProvider("grok").?);
    try testing.expectEqual(Provider.configured, parseProvider("configured").?);
    try testing.expectEqual(Provider.configured, parseProvider("local_ollama-2").?);
    try testing.expectEqual(Provider.configured, parseProvider("a" ** 64).?);
    try testing.expect(parseProvider("a" ** 65) == null);
    try testing.expect(parseProvider("") == null);
    try testing.expect(parseProvider("_local") == null);
    try testing.expect(parseProvider("lo cal") == null);
}

test "dupe copies every owned string and survives allocation failure" {
    const borrowed: Snapshot = .{
        .billing = .pending,
        .api_duration_complete = true,
        .wall_duration_complete = true,
        .code_complete = true,
        .next_sequence = 3,
        .settled_through_sequence = 2,
        .api_duration_ms = 5,
        .wall_duration_ms = 9,
        .total_cost = 0.5,
        .input_tokens = 1,
        .output_tokens = 2,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .billable_web_search_calls = 0,
        .lines_added = 0,
        .lines_removed = 0,
        .models = &.{.{ .model = "m/one", .first_sequence = 1, .total_cost = 0.5, .input_tokens = 1, .output_tokens = 2 }},
        .pending = &.{.{ .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV", .sequence = 2, .origin = "https://ai-gateway.vercel.sh", .team = "t", .account_id = "a" }},
        .publication_backlog = &.{.{ .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW", .created_at_ms = 1, .model = "m/two", .input_tokens = 1, .output_tokens = 1, .cache_read_tokens = 0, .cache_write_tokens = 0, .reasoning_tokens = null, .total_cost = 0.1 }},
        .incidents = &.{.{ .occurred_at_ms = 4, .completeness = .incomplete }},
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: Allocator, source: Snapshot) !void {
            var copy = try dupe(alloc, source);
            defer copy.deinit(alloc);
            try std.testing.expectEqualStrings("m/one", copy.models[0].model);
            try std.testing.expect(copy.models[0].model.ptr != source.models[0].model.ptr);
            try std.testing.expectEqualStrings("a", copy.pending[0].account_id.?);
            try std.testing.expectEqualStrings("m/two", copy.publication_backlog[0].model);
            try std.testing.expectEqual(@as(usize, 1), copy.incidents.len);
        }
    }.run, .{borrowed});
}
