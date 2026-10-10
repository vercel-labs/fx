//! AI Gateway usage receipts.
//!
//! `Observation` takes the JSON payload of every SSE `data:` line of one
//! Gateway language-model call and keeps only the facts usage needs. When the
//! stream proves exactly what was billed, `Observation.receipt` returns them.
//! Otherwise the caller looks the generation up with `GET /v1/generation` and
//! reads the response with `classifyStatus` and `parseLookup`.
//!
//! The accept and reject rules are the ones fx's Gateway client and
//! generation lookup always used, except:
//!
//! - The exact cost is `gatewayCost`, else `cost + surchargeCost`, else no
//!   receipt: what the Gateway debited. Older fx stored `cost` alone.
//! - A stream without `response-metadata.timestamp` still yields a receipt,
//!   created at the call's start time. Older fx yielded none.
//! - 401 and 403 lookups are `unauthorized`. Older fx kept them pending.
//!
//! An invalid field never produces a guessed receipt; it produces none.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// Longest accepted billed model slug, in bytes.
const max_model_bytes: usize = 1024;
/// Longest accepted `response-metadata.modelId`, in bytes.
const max_response_model_id_bytes: usize = 128;

/// Exact usage facts for one Gateway generation, read from its stream.
///
/// `generation_id` and `model` are borrowed from the `Observation` that made
/// the receipt and stay valid until that observation's `deinit`.
pub const Receipt = struct {
    generation_id: []const u8,
    created_at_ms: i64,
    model: []const u8,
    /// The debited amount in USD.
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    billable_web_search_calls: u64,
};

/// What the stream said about which generation it was.
pub const Identity = union(enum) {
    /// No event carried a generation id.
    none,
    /// One valid id, borrowed from the observation until its `deinit`.
    valid: []const u8,
    /// Malformed or conflicting identity metadata. The call must not be
    /// attributed to any generation.
    invalid,
};

/// Usage evidence from one Gateway stream.
///
/// Initialize with `.{}` (or set `expected_provider_tool`), pass every SSE
/// `data:` payload in order to `observe`, then read `receipt` or `identity`.
/// The observation owns everything it keeps. Pass the same allocator to every
/// `observe` call and to `deinit`. Fields other than `expected_provider_tool`
/// are internal state.
pub const Observation = struct {
    /// Name of the Gateway provider search tool the request advertised, if
    /// any. A `tool-call` without a `providerExecuted` field counts as
    /// provider-executed only when its name matches. Borrowed; must outlive
    /// the observation.
    expected_provider_tool: ?[]const u8 = null,

    phase: Phase = .open,
    generation_id: ?[]u8 = null,
    identity_invalid: bool = false,
    timestamp: Timestamp = .absent,
    response_model_id: ?[]u8 = null,
    tool_inputs: std.ArrayList(ToolInput) = .empty,
    web_search_calls: u64 = 0,
    web_search_overflow: bool = false,
    billing: ?Billing = null,

    /// Frees everything the observation owns. Receipts and identities taken
    /// from it become invalid.
    pub fn deinit(self: *Observation, alloc: Allocator) void {
        if (self.generation_id) |id| alloc.free(id);
        if (self.response_model_id) |model_id| alloc.free(model_id);
        for (self.tool_inputs.items) |input| input.deinit(alloc);
        self.tool_inputs.deinit(alloc);
        if (self.billing) |billing| alloc.free(billing.model);
        self.* = undefined;
    }

    /// Records one SSE `data:` payload. `[DONE]` and the first `finish` end
    /// the stream, and later payloads are ignored, as in fx's client.
    /// Malformed JSON, a `finish` without a known `finishReason.unified`, or
    /// running out of memory make the stream unusable for a receipt. The
    /// identity seen so far is kept.
    pub fn observe(
        self: *Observation,
        alloc: Allocator,
        event_json: []const u8,
    ) Allocator.Error!void {
        if (self.phase != .open) return;
        if (std.mem.eql(u8, event_json, "[DONE]")) {
            self.phase = .done;
            return;
        }
        var parsed = std.json.parseFromSlice(Value, alloc, event_json, .{}) catch |err| {
            self.phase = .failed;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return;
        };
        defer parsed.deinit();
        self.observeValue(alloc, parsed.value) catch |err| {
            self.phase = .failed;
            return err;
        };
    }

    /// `observe` for an event the caller already parsed. `root` is borrowed
    /// for the call.
    pub fn observeParsed(self: *Observation, alloc: Allocator, root: Value) Allocator.Error!void {
        if (self.phase != .open) return;
        self.observeValue(alloc, root) catch |err| {
            self.phase = .failed;
            return err;
        };
    }

    /// The generation identity seen so far.
    pub fn identity(self: *const Observation) Identity {
        if (self.identity_invalid) return .invalid;
        if (self.generation_id) |id| return .{ .valid = id };
        return .none;
    }

    /// The exact receipt, or null when the stream does not prove one and the
    /// caller must look the generation up (or record an incomplete call).
    /// `started_at_ms` is the call's begin time, used as `created_at_ms` when
    /// the stream sent no timestamp. It must not be negative.
    pub fn receipt(self: *const Observation, started_at_ms: i64) ?Receipt {
        if (self.phase != .finished or self.web_search_overflow) return null;
        const billing = self.billing orelse return null;
        const generation_id = switch (self.identity()) {
            .valid => |id| id,
            .none, .invalid => return null,
        };
        const created_at_ms = switch (self.timestamp) {
            .absent => started_at_ms,
            .valid => |timestamp_ms| timestamp_ms,
            .invalid => return null,
        };
        if (created_at_ms < 0) return null;
        return .{
            .generation_id = generation_id,
            .created_at_ms = created_at_ms,
            .model = billing.model,
            .total_cost = billing.total_cost,
            .input_tokens = billing.input_tokens,
            .output_tokens = billing.output_tokens,
            .cache_read_tokens = billing.cache_read_tokens,
            .cache_write_tokens = billing.cache_write_tokens,
            .reasoning_tokens = billing.reasoning_tokens,
            .billable_web_search_calls = self.web_search_calls,
        };
    }

    fn observeValue(self: *Observation, alloc: Allocator, root: Value) Allocator.Error!void {
        if (root != .object) return;
        const event = root.object;
        try self.captureGenerationId(alloc, event);

        const type_value = event.get("type") orelse return;
        if (type_value != .string) return;
        const event_type = type_value.string;
        if (std.mem.eql(u8, event_type, "response-metadata")) {
            try self.observeResponseMetadata(alloc, event);
        } else if (std.mem.eql(u8, event_type, "tool-input-start")) {
            try self.observeToolInputStart(alloc, event);
        } else if (std.mem.eql(u8, event_type, "tool-call")) {
            self.observeToolCall(event);
        } else if (std.mem.eql(u8, event_type, "finish")) {
            try self.observeFinish(alloc, event);
        }
    }

    /// Mirrors fx `captureGenerationMetadata`: runs on every object event.
    fn captureGenerationId(self: *Observation, alloc: Allocator, event: ObjectMap) Allocator.Error!void {
        const provider_metadata = event.get("providerMetadata") orelse return;
        if (provider_metadata != .object) {
            self.identity_invalid = true;
            return;
        }
        const gateway = provider_metadata.object.get("gateway") orelse return;
        if (gateway != .object) {
            self.identity_invalid = true;
            return;
        }
        const id_value = gateway.object.get("generationId") orelse return;
        if (id_value != .string or !validGatewayGenerationId(id_value.string)) {
            self.identity_invalid = true;
            return;
        }
        if (self.generation_id) |existing| {
            if (!std.mem.eql(u8, existing, id_value.string)) self.identity_invalid = true;
            return;
        }
        self.generation_id = try alloc.dupe(u8, id_value.string);
    }

    fn observeResponseMetadata(self: *Observation, alloc: Allocator, event: ObjectMap) Allocator.Error!void {
        if (event.get("timestamp")) |value| self.timestamp = self.timestamp.next(value);
        const model_value = event.get("modelId") orelse return;
        if (model_value != .string or
            model_value.string.len == 0 or
            model_value.string.len > max_response_model_id_bytes)
        {
            self.identity_invalid = true;
            return;
        }
        if (self.response_model_id) |existing| {
            if (!std.mem.eql(u8, existing, model_value.string)) self.identity_invalid = true;
            return;
        }
        self.response_model_id = try alloc.dupe(u8, model_value.string);
    }

    /// Keeps the first name streamed for each tool input id, which fx uses
    /// when a final `tool-call` omits `toolName`.
    fn observeToolInputStart(self: *Observation, alloc: Allocator, event: ObjectMap) Allocator.Error!void {
        const id_value = event.get("id") orelse return;
        if (id_value != .string or id_value.string.len == 0) return;
        if (self.findToolInput(id_value.string) != null) return;
        const name: []const u8 = if (event.get("toolName")) |value|
            if (value == .string) value.string else ""
        else
            "";

        try self.tool_inputs.ensureUnusedCapacity(alloc, 1);
        const id = try alloc.dupe(u8, id_value.string);
        errdefer alloc.free(id);
        const owned_name = try alloc.dupe(u8, name);
        self.tool_inputs.appendAssumeCapacity(.{ .id = id, .name = owned_name });
    }

    /// Counts provider-executed web search calls by fx's name rule: the tool
    /// is `web_search` or ends in `_search`. Every final `tool-call` counts,
    /// including repeated ids.
    fn observeToolCall(self: *Observation, event: ObjectMap) void {
        const streamed: ?ToolInput = if (event.get("toolCallId")) |id_value|
            if (id_value == .string and id_value.string.len > 0)
                self.findToolInput(id_value.string)
            else
                null
        else
            null;

        const name_value = event.get("toolName");
        const name: []const u8 = if (name_value) |value|
            if (value == .string) value.string else ""
        else if (streamed) |input|
            input.name
        else
            "";
        const name_compatible = if (streamed) |input|
            if (name_value) |value|
                value == .string and std.mem.eql(u8, value.string, input.name)
            else
                true
        else
            true;

        const provider_executed = if (event.get("providerExecuted")) |value|
            value == .bool and value.bool
        else if (self.expected_provider_tool) |expected|
            name_compatible and std.mem.eql(u8, name, expected)
        else
            false;
        if (!provider_executed or !isWebSearchToolName(name)) return;
        self.web_search_calls = std.math.add(u64, self.web_search_calls, 1) catch {
            self.web_search_overflow = true;
            return;
        };
    }

    fn observeFinish(self: *Observation, alloc: Allocator, event: ObjectMap) Allocator.Error!void {
        if (!validFinishReason(event)) {
            self.phase = .failed;
            return;
        }
        var billing = parseBilling(event) catch {
            self.phase = .finished;
            return;
        };
        billing.model = try alloc.dupe(u8, billing.model);
        self.billing = billing;
        self.phase = .finished;
    }

    fn findToolInput(self: *const Observation, id: []const u8) ?ToolInput {
        for (self.tool_inputs.items) |input| {
            if (std.mem.eql(u8, input.id, id)) return input;
        }
        return null;
    }
};

const Phase = enum {
    /// Accepting events.
    open,
    /// The first `finish` arrived; `billing` holds its valid facts, if any.
    finished,
    /// `[DONE]` arrived before any `finish`.
    done,
    /// Malformed JSON, an invalid finish reason, or out of memory.
    failed,
};

/// `response-metadata.timestamp` state. Once invalid it stays invalid, as in
/// fx's client.
const Timestamp = union(enum) {
    absent,
    valid: i64,
    invalid,

    fn next(self: Timestamp, value: Value) Timestamp {
        if (value != .string) return .invalid;
        const timestamp_ms = parseGatewayTimestamp(value.string) catch return .invalid;
        return switch (self) {
            .absent => .{ .valid = timestamp_ms },
            .valid => |existing| if (existing == timestamp_ms) self else .invalid,
            .invalid => .invalid,
        };
    }
};

const ToolInput = struct {
    id: []u8,
    name: []u8,

    fn deinit(self: ToolInput, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
    }
};

/// Terminal billing facts. `model` borrows the event until the observation
/// dupes it, then is owned by the observation.
const Billing = struct {
    model: []const u8,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
};

const InvalidBilling = error{InvalidBilling};

fn isWebSearchToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "web_search") or std.mem.endsWith(u8, name, "_search");
}

/// fx fails the whole stream unless `finishReason.unified` is a known value.
fn validFinishReason(event: ObjectMap) bool {
    const reason = event.get("finishReason") orelse return false;
    if (reason != .object) return false;
    const unified = reason.object.get("unified") orelse return false;
    if (unified != .string) return false;
    const known = [_][]const u8{ "stop", "length", "content-filter", "tool-calls", "error", "other" };
    for (known) |candidate| {
        if (std.mem.eql(u8, unified.string, candidate)) return true;
    }
    return false;
}

/// The Gateway client's finish-event billing rules, except for the timestamp
/// (checked by `Observation.receipt`), the cost, and the web search count
/// (kept by the observation).
fn parseBilling(event: ObjectMap) InvalidBilling!Billing {
    const usage = event.get("usage") orelse return error.InvalidBilling;
    if (usage != .object) return error.InvalidBilling;
    const input = usage.object.get("inputTokens") orelse return error.InvalidBilling;
    const output = usage.object.get("outputTokens") orelse return error.InvalidBilling;
    if (input != .object or output != .object) return error.InvalidBilling;

    const provider_metadata = event.get("providerMetadata") orelse return error.InvalidBilling;
    if (provider_metadata != .object) return error.InvalidBilling;
    const gateway = provider_metadata.object.get("gateway") orelse return error.InvalidBilling;
    if (gateway != .object) return error.InvalidBilling;
    const routing = gateway.object.get("routing") orelse return error.InvalidBilling;
    if (routing != .object) return error.InvalidBilling;
    const model = routing.object.get("canonicalSlug") orelse return error.InvalidBilling;
    if (model != .string or !validModel(model.string)) return error.InvalidBilling;

    const total_cost = try parseDebitedCost(gateway.object);

    const input_tokens = try billingInteger(input.object.get("total"));
    const output_tokens = try billingInteger(output.object.get("total"));
    const cache_read_tokens = try optionalBillingInteger(input.object.get("cacheRead"));
    const cache_write_tokens = try optionalBillingInteger(input.object.get("cacheWrite"));
    const reasoning_tokens = try optionalNullableBillingInteger(output.object.get("reasoning"));
    if (cache_read_tokens > input_tokens or
        cache_write_tokens > input_tokens or
        (reasoning_tokens != null and reasoning_tokens.? > output_tokens))
    {
        return error.InvalidBilling;
    }

    return .{
        .model = model.string,
        .total_cost = total_cost,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = cache_read_tokens,
        .cache_write_tokens = cache_write_tokens,
        .reasoning_tokens = reasoning_tokens,
    };
}

/// The debited cost: `gatewayCost` when present (even if invalid, nothing falls back past
/// it), else `cost + surchargeCost` when both are present.
fn parseDebitedCost(gateway: ObjectMap) InvalidBilling!f64 {
    if (gateway.get("gatewayCost")) |gateway_cost| return parseCostString(gateway_cost);
    const cost = gateway.get("cost") orelse return error.InvalidBilling;
    const surcharge = gateway.get("surchargeCost") orelse return error.InvalidBilling;
    const total = try parseCostString(cost) + try parseCostString(surcharge);
    if (!std.math.isFinite(total)) return error.InvalidBilling;
    return total;
}

/// fx's rule for `gateway.cost`: a string holding a finite number >= 0.
fn parseCostString(value: Value) InvalidBilling!f64 {
    if (value != .string) return error.InvalidBilling;
    const cost = std.fmt.parseFloat(f64, value.string) catch return error.InvalidBilling;
    if (!std.math.isFinite(cost) or cost < 0) return error.InvalidBilling;
    return cost;
}

fn billingInteger(value: ?Value) InvalidBilling!u64 {
    const actual = value orelse return error.InvalidBilling;
    if (actual != .integer or actual.integer < 0) return error.InvalidBilling;
    return @intCast(actual.integer);
}

fn optionalBillingInteger(value: ?Value) InvalidBilling!u64 {
    return if (value) |actual| try billingInteger(actual) else 0;
}

fn optionalNullableBillingInteger(value: ?Value) InvalidBilling!?u64 {
    const actual = value orelse return null;
    if (actual == .null) return null;
    return try billingInteger(actual);
}

/// Billed model slugs: 1 to 1024 bytes, each printable ASCII without space.
fn validModel(model: []const u8) bool {
    if (model.len == 0 or model.len > max_model_bytes) return false;
    for (model) |byte| {
        if (byte < 0x21 or byte > 0x7e) return false;
    }
    return true;
}

/// One `GET /v1/generation` record. Owns `id` and `model`; free with `deinit`.
pub const LookupRecord = struct {
    id: []const u8,
    created_at_ms: i64,
    model: []const u8,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    billable_web_search_calls: u64,

    pub fn deinit(self: *LookupRecord, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.model);
        self.* = undefined;
    }
};

/// What to do with a `/v1/generation` response status.
pub const LookupStatus = enum {
    /// 200: parse the body with `parseLookup`.
    found_or_parse,
    /// Not ready or temporarily unavailable: try again later.
    retry,
    /// 401/403: this credential cannot look the generation up.
    unauthorized,
    /// Any other status: the lookup can never succeed.
    rejected,
};

pub fn classifyStatus(status: std.http.Status) LookupStatus {
    if (status == .ok) return .found_or_parse;
    const code = @intFromEnum(status);
    if (code == 404 or code == 408 or code == 425 or code == 429 or code >= 500) {
        return .retry;
    }
    if (status == .unauthorized or status == .forbidden) return .unauthorized;
    return .rejected;
}

pub const LookupParseError = Allocator.Error || error{
    InvalidGenerationId,
    InvalidGenerationRecord,
    GenerationIdentityMismatch,
    InvalidModel,
};

/// Parses a 200 `/v1/generation` body for `expected_id`, with exactly fx's
/// `parseGenerationRecord` rules: input = prompt + cached + cache_creation,
/// output = completion + reasoning. fx treats every error, including
/// `OutOfMemory`, as a terminal rejection. The record is owned by the caller.
pub fn parseLookup(
    alloc: Allocator,
    body: []const u8,
    expected_id: []const u8,
) LookupParseError!LookupRecord {
    if (!validGatewayGenerationId(expected_id)) return error.InvalidGenerationId;
    var parsed = std.json.parseFromSlice(Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGenerationRecord,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGenerationRecord;
    const data = parsed.value.object.get("data") orelse return error.InvalidGenerationRecord;
    if (data != .object) return error.InvalidGenerationRecord;

    const id_value = data.object.get("id") orelse return error.InvalidGenerationRecord;
    if (id_value != .string or !validGatewayGenerationId(id_value.string)) {
        return error.InvalidGenerationRecord;
    }
    if (!std.mem.eql(u8, id_value.string, expected_id)) return error.GenerationIdentityMismatch;

    const model_value = data.object.get("model") orelse return error.InvalidGenerationRecord;
    if (model_value != .string) return error.InvalidGenerationRecord;
    if (!validModel(model_value.string)) return error.InvalidModel;

    const created_at_value = data.object.get("created_at") orelse
        return error.InvalidGenerationRecord;
    if (created_at_value != .string) return error.InvalidGenerationRecord;
    const created_at_ms = parseGatewayTimestamp(created_at_value.string) catch
        return error.InvalidGenerationRecord;
    const total_cost = try lookupNumber(data.object.get("total_cost"));
    const prompt_tokens = try lookupInteger(data.object.get("native_tokens_prompt"));
    const completion_tokens = try lookupInteger(data.object.get("native_tokens_completion"));
    const cache_read_tokens = try lookupInteger(data.object.get("native_tokens_cached"));
    const cache_write_tokens = try lookupInteger(data.object.get("native_tokens_cache_creation"));
    var input_tokens = std.math.add(u64, prompt_tokens, cache_read_tokens) catch
        return error.InvalidGenerationRecord;
    input_tokens = std.math.add(u64, input_tokens, cache_write_tokens) catch
        return error.InvalidGenerationRecord;
    const reasoning_tokens = try optionalLookupInteger(data.object.get("native_tokens_reasoning"));
    const output_tokens = std.math.add(u64, completion_tokens, reasoning_tokens orelse 0) catch
        return error.InvalidGenerationRecord;
    const billable_web_search_calls = try lookupInteger(data.object.get("billable_web_search_calls"));

    const id = try alloc.dupe(u8, id_value.string);
    errdefer alloc.free(id);
    const model = try alloc.dupe(u8, model_value.string);
    return .{
        .id = id,
        .created_at_ms = created_at_ms,
        .model = model,
        .total_cost = total_cost,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = cache_read_tokens,
        .cache_write_tokens = cache_write_tokens,
        .reasoning_tokens = reasoning_tokens,
        .billable_web_search_calls = billable_web_search_calls,
    };
}

fn lookupNumber(value: ?Value) error{InvalidGenerationRecord}!f64 {
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

fn lookupInteger(value: ?Value) error{InvalidGenerationRecord}!u64 {
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

fn optionalLookupInteger(value: ?Value) error{InvalidGenerationRecord}!?u64 {
    const actual = value orelse return null;
    if (actual == .null) return null;
    return try lookupInteger(actual);
}

/// `gen_` followed by 26 Crockford base32 characters (no I, L, O, or U).
fn validGatewayGenerationId(id: []const u8) bool {
    if (id.len != 30 or !std.mem.startsWith(u8, id, "gen_")) return false;
    for (id[4..]) |char| switch (char) {
        '0'...'9', 'A'...'H', 'J'...'K', 'M'...'N', 'P'...'T', 'V'...'Z' => {},
        else => return false,
    };
    return true;
}

/// `YYYY-MM-DDTHH:MM:SS[.1-9 digits]Z`, UTC only, year >= 1970,
/// calendar-checked. Returns Unix milliseconds.
fn parseGatewayTimestamp(text: []const u8) error{InvalidGatewayTimestamp}!i64 {
    if (text.len < 20 or
        text[4] != '-' or
        text[7] != '-' or
        text[10] != 'T' or
        text[13] != ':' or
        text[16] != ':')
    {
        return error.InvalidGatewayTimestamp;
    }
    const year = try parseTimestampDigits(text[0..4]);
    const month = try parseTimestampDigits(text[5..7]);
    const day = try parseTimestampDigits(text[8..10]);
    const hour = try parseTimestampDigits(text[11..13]);
    const minute = try parseTimestampDigits(text[14..16]);
    const second = try parseTimestampDigits(text[17..19]);
    if (year < 1970 or
        month < 1 or
        month > 12 or
        day < 1 or
        day > daysInMonth(year, month) or
        hour > 23 or
        minute > 59 or
        second > 59)
    {
        return error.InvalidGatewayTimestamp;
    }

    var cursor: usize = 19;
    var fractional_ms: i64 = 0;
    if (cursor < text.len and text[cursor] == '.') {
        cursor += 1;
        const fraction_start = cursor;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
        const fraction = text[fraction_start..cursor];
        if (fraction.len == 0 or fraction.len > 9) return error.InvalidGatewayTimestamp;
        const digits = @min(fraction.len, 3);
        // At most three digits, so the value is below 1000.
        fractional_ms = @intCast(try parseTimestampDigits(fraction[0..digits]));
        if (digits == 1) fractional_ms *= 100;
        if (digits == 2) fractional_ms *= 10;
    }
    if (cursor + 1 != text.len or text[cursor] != 'Z') return error.InvalidGatewayTimestamp;

    const days = daysFromCivil(year, month, day);
    if (days < 0) return error.InvalidGatewayTimestamp;
    const seconds = std.math.add(
        i64,
        std.math.mul(i64, days, std.time.s_per_day) catch return error.InvalidGatewayTimestamp,
        // hour <= 23, minute <= 59, second <= 59: at most 86399.
        @as(i64, @intCast(hour * std.time.s_per_hour + minute * std.time.s_per_min + second)),
    ) catch return error.InvalidGatewayTimestamp;
    return std.math.add(
        i64,
        std.math.mul(i64, seconds, std.time.ms_per_s) catch return error.InvalidGatewayTimestamp,
        fractional_ms,
    ) catch return error.InvalidGatewayTimestamp;
}

fn parseTimestampDigits(text: []const u8) error{InvalidGatewayTimestamp}!u32 {
    if (text.len == 0) return error.InvalidGatewayTimestamp;
    var result: u32 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidGatewayTimestamp;
        result = std.math.mul(u32, result, 10) catch return error.InvalidGatewayTimestamp;
        result = std.math.add(u32, result, byte - '0') catch return error.InvalidGatewayTimestamp;
    }
    return result;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(year_value: u32, month_value: u32, day_value: u32) i64 {
    var year: i64 = year_value;
    const month: i64 = month_value;
    const day: i64 = day_value;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV";
const other_test_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW";
const test_started_at_ms: i64 = 1_791_392_800_000;

/// Gateway fixtures, embedded from `testdata/gateway/`.
const testdata = @import("testdata/dir.zig");

const FixtureRoute = struct {
    name: []const u8,
    /// `response-metadata.timestamp` on the wire, or null when absent.
    timestamp: ?[]const u8,
};

const streamed_routes = [_]FixtureRoute{
    .{ .name = "amazon_nova-micro", .timestamp = "2026-10-07T17:07:22.000Z" },
    .{ .name = "anthropic_claude-haiku-4.5", .timestamp = null },
    .{ .name = "google_gemini-2.5-flash-lite", .timestamp = null },
    .{ .name = "openai_gpt-4.1-nano", .timestamp = "2026-10-07T17:07:21.000Z" },
    .{ .name = "spacexai_grok-4.1-fast-non-reasoning", .timestamp = "2026-10-07T17:07:21.000Z" },
};

fn readFixture(alloc: Allocator, name: []const u8, suffix: []const u8) ![]u8 {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ name, suffix });
    const dir = try testdata.Dir.open("gateway");
    return dir.readFileAlloc(testing.io, path, alloc, .limited(1 << 20));
}

/// Feeds every `data: ` line of a captured SSE body, in order.
fn feedSse(observation: *Observation, alloc: Allocator, sse: []const u8) !void {
    var lines = std.mem.splitScalar(u8, sse, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "data: ")) try observation.observe(alloc, line["data: ".len..]);
    }
}

fn dataEvents(alloc: Allocator, sse: []const u8) !std.ArrayList([]const u8) {
    var events: std.ArrayList([]const u8) = .empty;
    errdefer events.deinit(alloc);
    var lines = std.mem.splitScalar(u8, sse, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "data: ")) try events.append(alloc, line["data: ".len..]);
    }
    return events;
}

fn observeAll(alloc: Allocator, events: []const []const u8) !Observation {
    var observation: Observation = .{};
    errdefer observation.deinit(alloc);
    for (events) |event| try observation.observe(alloc, event);
    return observation;
}

fn expectNoReceipt(events: []const []const u8) !void {
    var observation = try observeAll(testing.allocator, events);
    defer observation.deinit(testing.allocator);
    try testing.expect(observation.receipt(test_started_at_ms) == null);
}

fn requireReceipt(observation: *const Observation, started_at_ms: i64) !Receipt {
    return observation.receipt(started_at_ms) orelse error.TestExpectedReceipt;
}

fn requireId(observation: *const Observation) ![]const u8 {
    return switch (observation.identity()) {
        .valid => |id| id,
        .none, .invalid => error.TestExpectedValidIdentity,
    };
}

fn expectReceiptInvariants(receipt_value: Receipt) !void {
    try testing.expect(validGatewayGenerationId(receipt_value.generation_id));
    try testing.expect(validModel(receipt_value.model));
    try testing.expect(std.math.isFinite(receipt_value.total_cost));
    try testing.expect(receipt_value.total_cost >= 0);
    try testing.expect(receipt_value.created_at_ms >= 0);
    try testing.expect(receipt_value.cache_read_tokens <= receipt_value.input_tokens);
    try testing.expect(receipt_value.cache_write_tokens <= receipt_value.input_tokens);
    if (receipt_value.reasoning_tokens) |reasoning| {
        try testing.expect(reasoning <= receipt_value.output_tokens);
    }
}

const metadata_with_timestamp =
    \\{"type":"response-metadata","modelId":"provider/resolved","timestamp":"2026-07-29T03:31:07.000Z"}
;
const id_event =
    \\{"type":"text-start","id":"t1","providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"}}}
;
const valid_finish =
    \\{"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":130,"cacheRead":20,"cacheWrite":10},"outputTokens":{"total":25,"reasoning":5}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","gatewayCost":"0.0123","routing":{"canonicalSlug":"provider/canonical"}}}}
;

/// A finish event with every billing field valid except the parts given.
fn finishEvent(
    comptime usage: []const u8,
    comptime gateway_cost_fields: []const u8,
    comptime slug: []const u8,
) []const u8 {
    return "{\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"},\"usage\":" ++ usage ++
        ",\"providerMetadata\":{\"gateway\":{\"generationId\":\"" ++ test_id ++ "\"," ++
        gateway_cost_fields ++ ",\"routing\":{\"canonicalSlug\":" ++ slug ++ "}}}}";
}

const default_usage =
    \\{"inputTokens":{"total":10},"outputTokens":{"total":5}}
;
const default_cost =
    \\"gatewayCost":"0.5"
;
const default_slug =
    \\"provider/canonical"
;

test "every streamed fixture route yields a receipt equal to its /v1/generation record" {
    const alloc = testing.allocator;
    for (streamed_routes) |route| {
        const sse = try readFixture(alloc, route.name, ".sse");
        defer alloc.free(sse);
        const body = try readFixture(alloc, route.name, ".generation.json");
        defer alloc.free(body);

        var observation: Observation = .{};
        defer observation.deinit(alloc);
        try feedSse(&observation, alloc, sse);
        const got = observation.receipt(test_started_at_ms) orelse {
            std.debug.print("no receipt for fixture route {s}\n", .{route.name});
            return error.TestExpectedReceipt;
        };
        try expectReceiptInvariants(got);

        var record = try parseLookup(alloc, body, got.generation_id);
        defer record.deinit(alloc);

        try testing.expectEqualStrings(record.id, got.generation_id);
        try testing.expectEqual(record.total_cost, got.total_cost);
        try testing.expectEqualStrings(record.model, got.model);
        try testing.expectEqual(record.input_tokens, got.input_tokens);
        try testing.expectEqual(record.output_tokens, got.output_tokens);
        try testing.expectEqual(record.cache_read_tokens, got.cache_read_tokens);
        try testing.expectEqual(record.cache_write_tokens, got.cache_write_tokens);
        try testing.expectEqual(record.reasoning_tokens orelse 0, got.reasoning_tokens orelse 0);
        try testing.expectEqual(record.billable_web_search_calls, got.billable_web_search_calls);

        const expected_created_at = if (route.timestamp) |text|
            try parseGatewayTimestamp(text)
        else
            test_started_at_ms;
        try testing.expectEqual(expected_created_at, got.created_at_ms);
    }
}

test "anthropic and google fixtures carry no timestamp and take started_at" {
    const alloc = testing.allocator;
    for ([_][]const u8{ "anthropic_claude-haiku-4.5", "google_gemini-2.5-flash-lite" }) |name| {
        const sse = try readFixture(alloc, name, ".sse");
        defer alloc.free(sse);
        var observation: Observation = .{};
        defer observation.deinit(alloc);
        try feedSse(&observation, alloc, sse);
        try testing.expectEqual(Timestamp.absent, observation.timestamp);
        try testing.expectEqual(@as(i64, 42), (try requireReceipt(&observation, 42)).created_at_ms);
        try testing.expectEqual(test_started_at_ms, (try requireReceipt(&observation, test_started_at_ms)).created_at_ms);
    }
}

test "failed claude-3-haiku route has an id but no receipt and looks up at zero cost" {
    const alloc = testing.allocator;
    const error_body = try readFixture(alloc, "anthropic_claude-3-haiku", ".sse");
    defer alloc.free(error_body);
    const lookup_body = try readFixture(alloc, "anthropic_claude-3-haiku", ".generation.json");
    defer alloc.free(lookup_body);

    // The capture is an HTTP error body with no SSE `data:` lines.
    var empty: Observation = .{};
    defer empty.deinit(alloc);
    try feedSse(&empty, alloc, error_body);
    try testing.expectEqual(Identity.none, empty.identity());
    try testing.expect(empty.receipt(test_started_at_ms) == null);

    // Its JSON still carries the generation id if a host feeds it as an event.
    var observation: Observation = .{};
    defer observation.deinit(alloc);
    try observation.observe(alloc, std.mem.trimEnd(u8, error_body, "\n"));
    const id = (try requireId(&observation));
    try testing.expect(observation.receipt(test_started_at_ms) == null);

    var record = try parseLookup(alloc, lookup_body, id);
    defer record.deinit(alloc);
    try testing.expectEqual(@as(f64, 0), record.total_cost);
    try testing.expectEqual(@as(u64, 0), record.input_tokens);
    try testing.expectEqualStrings("anthropic/claude-3-haiku", record.model);
}

test "fixture lookup tokens: prompt excludes cached tokens" {
    // Grok's stream reports total input 678 with cacheRead 664. The lookup
    // reports prompt 14 and cached 664, so input = prompt + cached matches.
    const alloc = testing.allocator;
    const body = try readFixture(alloc, "spacexai_grok-4.1-fast-non-reasoning", ".generation.json");
    defer alloc.free(body);
    var record = try parseLookup(alloc, body, "gen_01M4BNAZXV1816PVAK719WGD3C");
    defer record.deinit(alloc);
    try testing.expectEqual(@as(u64, 678), record.input_tokens);
    try testing.expectEqual(@as(u64, 664), record.cache_read_tokens);
}

test "cost + surchargeCost prices a receipt when gatewayCost is absent" {
    const finish = comptime finishEvent(default_usage,
        \\"cost":"0.000000525","surchargeCost":"0.0001"
    , default_slug);
    var observation = try observeAll(testing.allocator, &.{finish});
    defer observation.deinit(testing.allocator);
    const got = (try requireReceipt(&observation, test_started_at_ms));
    try testing.expectApproxEqAbs(@as(f64, 0.000100525), got.total_cost, 1e-15);
}

test "gatewayCost wins over cost + surchargeCost" {
    const finish = comptime finishEvent(default_usage,
        \\"cost":"1","surchargeCost":"2","gatewayCost":"0.25"
    , default_slug);
    var observation = try observeAll(testing.allocator, &.{finish});
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0.25), (try requireReceipt(&observation, test_started_at_ms)).total_cost);
}

test "missing or invalid cost fields give no receipt" {
    const cases = comptime [_][]const u8{
        // fx today stores `cost` alone; looks these calls up instead.
        finishEvent(default_usage,
            \\"cost":"0.0123"
        , default_slug),
        finishEvent(default_usage,
            \\"surchargeCost":"0.0001"
        , default_slug),
        finishEvent(default_usage,
            \\"marketCost":"0.0001"
        , default_slug),
        // A present but invalid gatewayCost never falls back.
        finishEvent(default_usage,
            \\"gatewayCost":"invalid","cost":"1","surchargeCost":"1"
        , default_slug),
        finishEvent(default_usage,
            \\"gatewayCost":0.5
        , default_slug),
        finishEvent(default_usage,
            \\"gatewayCost":null
        , default_slug),
        finishEvent(default_usage,
            \\"gatewayCost":"-0.1"
        , default_slug),
        finishEvent(default_usage,
            \\"gatewayCost":"inf"
        , default_slug),
        finishEvent(default_usage,
            \\"gatewayCost":"nan"
        , default_slug),
        finishEvent(default_usage,
            \\"gatewayCost":""
        , default_slug),
        finishEvent(default_usage,
            \\"cost":0.1,"surchargeCost":"0.1"
        , default_slug),
        finishEvent(default_usage,
            \\"cost":"0.1","surchargeCost":"-0.1"
        , default_slug),
        finishEvent(default_usage,
            \\"cost":"1e308","surchargeCost":"1e308"
        , default_slug),
    };
    for (cases) |finish| try expectNoReceipt(&.{finish});
}

test "stream: generation identity metadata without billing" {
    // consumeSseStream captures generation identity metadata.
    var observation = try observeAll(testing.allocator, &.{
        \\{"type":"response-metadata","modelId":"provider/resolved"}
        ,
        id_event,
        \\{"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}
        ,
    });
    defer observation.deinit(testing.allocator);
    try testing.expectEqualStrings(test_id, (try requireId(&observation)));
    try testing.expect(observation.receipt(test_started_at_ms) == null);
}

test "stream: rejected terminal billing for an invalid cost" {
    // consumeSseStream traces rejected terminal billing before fallback.
    try expectNoReceipt(&.{
        metadata_with_timestamp,
        \\{"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","cost":"invalid","routing":{"canonicalSlug":"provider/resolved"}}}}
        ,
    });
}

test "stream: routing without cost gives no receipt" {
    // consumeSseStream captures the resolved routing provider (no cost).
    try expectNoReceipt(&.{
        id_event,
        \\{"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}},"providerMetadata":{"gateway":{"routing":{"originalModelId":"anthropic/claude-sonnet-5","resolvedProvider":"bedrock","canonicalSlug":"anthropic/claude-sonnet-5","finalProvider":"bedrock"}}}}
        ,
    });
}

const exact_billing_prefix = [_][]const u8{
    metadata_with_timestamp,
    \\{"type":"tool-call","toolCallId":"call_1","toolName":"web_search","input":{},"providerExecuted":true,"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"}}}
    ,
    \\{"type":"tool-call","toolCallId":"call_2","toolName":"image_search","input":{},"providerExecuted":true}
    ,
    \\{"type":"tool-call","toolCallId":"call_3","toolName":"read_file","input":{},"providerExecuted":true}
    ,
    \\{"type":"tool-call","toolCallId":"call_4","toolName":"web_search","input":{}}
    ,
};

test "exact terminal billing prices the debited cost" {
    const alloc = testing.allocator;
    // Older fx priced this call with `cost` alone. Now it has no
    // receipt and is looked up instead.
    const cost_only =
        \\{"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":130,"cacheRead":20,"cacheWrite":10},"outputTokens":{"total":25,"reasoning":5}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","cost":"0.0123","routing":{"canonicalSlug":"provider/canonical"}}}}
    ;
    try expectNoReceipt(&(exact_billing_prefix ++ [_][]const u8{cost_only}));

    // The same stream with the debited amount gives fx's exact facts.
    var observation = try observeAll(alloc, &(exact_billing_prefix ++ [_][]const u8{valid_finish}));
    defer observation.deinit(alloc);
    const got = (try requireReceipt(&observation, test_started_at_ms));
    try testing.expectEqualStrings(test_id, got.generation_id);
    try testing.expectEqualStrings("provider/canonical", got.model);
    try testing.expectApproxEqAbs(@as(f64, 0.0123), got.total_cost, 1e-12);
    try testing.expectEqual(@as(u64, 130), got.input_tokens);
    try testing.expectEqual(@as(u64, 25), got.output_tokens);
    try testing.expectEqual(@as(u64, 20), got.cache_read_tokens);
    try testing.expectEqual(@as(u64, 10), got.cache_write_tokens);
    try testing.expectEqual(@as(?u64, 5), got.reasoning_tokens);
    try testing.expectEqual(@as(u64, 2), got.billable_web_search_calls);
    try testing.expectEqual(try parseGatewayTimestamp("2026-07-29T03:31:07.000Z"), got.created_at_ms);
}

test "stream: malformed finish usage totals give no receipt" {
    // consumeSseStream ignores malformed finish usage totals.
    try expectNoReceipt(&.{comptime finishEvent(
        \\{"inputTokens":{"total":-1},"outputTokens":{"total":"5"}}
    , default_cost, default_slug)});
}

test "stream: a non-integer reasoning count gives no receipt" {
    // consumeSseStream surfaces finish reasoning tokens (malformed case).
    try expectNoReceipt(&.{comptime finishEvent(
        \\{"inputTokens":{"total":10},"outputTokens":{"total":25,"reasoning":"5"}}
    , default_cost, default_slug)});
}

test "stream: malformed finish reasons fail the stream" {
    // consumeSseStream rejects malformed provider finish reasons.
    const reasons = [_][]const u8{
        \\{"unified":""}
        ,
        \\{"unified":"future-reason"}
        ,
        \\{"unified":7}
        ,
        \\{"raw":"stop"}
        ,
        \\"stop"
        ,
    };
    inline for (reasons) |reason| {
        const finish = "{\"type\":\"finish\",\"finishReason\":" ++ reason ++
            ",\"usage\":" ++ default_usage ++ ",\"providerMetadata\":{\"gateway\":{\"generationId\":\"" ++
            test_id ++ "\"," ++ default_cost ++ ",\"routing\":{\"canonicalSlug\":" ++ default_slug ++ "}}}}";
        var observation = try observeAll(testing.allocator, &.{finish});
        defer observation.deinit(testing.allocator);
        try testing.expectEqual(Phase.failed, observation.phase);
        try testing.expect(observation.receipt(test_started_at_ms) == null);
    }
    // Every known reason is accepted.
    inline for (.{ "stop", "length", "content-filter", "tool-calls", "error", "other" }) |reason| {
        const finish = "{\"type\":\"finish\",\"finishReason\":{\"unified\":\"" ++ reason ++
            "\"},\"usage\":" ++ default_usage ++ ",\"providerMetadata\":{\"gateway\":{\"generationId\":\"" ++
            test_id ++ "\"," ++ default_cost ++ ",\"routing\":{\"canonicalSlug\":" ++ default_slug ++ "}}}}";
        var observation = try observeAll(testing.allocator, &.{finish});
        defer observation.deinit(testing.allocator);
        try testing.expect(observation.receipt(test_started_at_ms) != null);
    }
}

test "stream: events after a valid finish are ignored" {
    // consumeSseStream returns immediately after valid finish.
    var observation = try observeAll(testing.allocator, &.{
        valid_finish,
        \\{"type":"text-delta","id":"t2","providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAW"}}}
        ,
        \\{"type":"response-metadata","timestamp":"bad"}
        ,
        "not json",
    });
    defer observation.deinit(testing.allocator);
    try testing.expectEqualStrings(test_id, (try requireId(&observation)));
    try testing.expect(observation.receipt(test_started_at_ms) != null);
}

test "stream: [DONE] before finish is framing only" {
    // consumeSseStream treats done before finish as framing only.
    var observation = try observeAll(testing.allocator, &.{ id_event, "[DONE]", valid_finish });
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(Phase.done, observation.phase);
    try testing.expectEqualStrings(test_id, (try requireId(&observation)));
    try testing.expect(observation.receipt(test_started_at_ms) == null);
}

test "stream: a final tool call without a name uses the streamed name" {
    // checkConsumeSseAllocationFailures: tool B streams parallel_search and
    // finalizes without toolName.
    var observation = try observeAll(testing.allocator, &.{
        \\{"type":"tool-input-start","id":"A","toolName":"read_file"}
        ,
        \\{"type":"tool-input-start","id":"B","toolName":"parallel_search"}
        ,
        \\{"type":"tool-input-delta","id":"B","delta":"{\"query\":\"zig\"}"}
        ,
        \\{"type":"tool-input-end","id":"A"}
        ,
        \\{"type":"tool-call","toolCallId":"final_A","toolName":"read_file","input":{"line_end":2,"path":"alpha.txt"}}
        ,
        \\{"type":"tool-input-end","id":"B"}
        ,
        \\{"type":"tool-call","toolCallId":"B","input":{"query":"zig"},"providerExecuted":true}
        ,
        \\{"type":"tool-result","toolCallId":"B","result":{"results":[{"title":"final"}]}}
        ,
        \\{"type":"tool-call","toolCallId":"C","toolName":"dynamic_tool","input":[1,{"nested":true}]}
        ,
        valid_finish,
    });
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), (try requireReceipt(&observation, test_started_at_ms)).billable_web_search_calls);
}

test "stream: providerExecuted must be the boolean true" {
    var observation = try observeAll(testing.allocator, &.{
        \\{"type":"tool-call","toolCallId":"call_1","toolName":"parallel_search","input":{},"providerExecuted":"yes"}
        ,
        \\{"type":"tool-call","toolCallId":"call_2","toolName":"parallel_search","input":{},"providerExecuted":false}
        ,
        \\{"type":"tool-call","toolCallId":"call_3","toolName":"web_search","input":{},"providerExecuted":null}
        ,
        valid_finish,
    });
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), (try requireReceipt(&observation, test_started_at_ms)).billable_web_search_calls);
}

test "stream: repeated final tool call ids each count" {
    var observation = try observeAll(testing.allocator, &.{
        \\{"type":"tool-call","toolCallId":"duplicate_1","toolName":"parallel_search","input":{},"providerExecuted":true}
        ,
        \\{"type":"tool-call","toolCallId":"duplicate_1","toolName":"parallel_search","input":{},"providerExecuted":true}
        ,
        \\{"type":"tool-call","toolName":"exa_search","input":{},"providerExecuted":true}
        ,
        valid_finish,
    });
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 3), (try requireReceipt(&observation, test_started_at_ms)).billable_web_search_calls);
}

test "stream: an advertised provider tool counts without providerExecuted" {
    const alloc = testing.allocator;
    const events = [_][]const u8{
        // Counts: name matches the advertised tool.
        \\{"type":"tool-call","toolCallId":"a","toolName":"exa_search","input":{}}
        ,
        // Counts: the name comes from the streamed input.
        \\{"type":"tool-input-start","id":"b","toolName":"exa_search"}
        ,
        \\{"type":"tool-call","toolCallId":"b","input":{}}
        ,
        // Does not count: the final name conflicts with the streamed one.
        \\{"type":"tool-input-start","id":"c","toolName":"read_file"}
        ,
        \\{"type":"tool-call","toolCallId":"c","toolName":"exa_search","input":{}}
        ,
        // Does not count: a different search tool was not advertised.
        \\{"type":"tool-call","toolCallId":"d","toolName":"parallel_search","input":{}}
        ,
        // Does not count: explicitly not provider-executed.
        \\{"type":"tool-call","toolCallId":"e","toolName":"exa_search","input":{},"providerExecuted":false}
        ,
        valid_finish,
    };
    var advertised: Observation = .{ .expected_provider_tool = "exa_search" };
    defer advertised.deinit(alloc);
    for (events) |event| try advertised.observe(alloc, event);
    try testing.expectEqual(@as(u64, 2), (try requireReceipt(&advertised, test_started_at_ms)).billable_web_search_calls);

    var unadvertised = try observeAll(alloc, &events);
    defer unadvertised.deinit(alloc);
    try testing.expectEqual(@as(u64, 0), (try requireReceipt(&unadvertised, test_started_at_ms)).billable_web_search_calls);
}

test "tool calls after finish are not counted" {
    var observation = try observeAll(testing.allocator, &.{
        valid_finish,
        \\{"type":"tool-call","toolCallId":"late","toolName":"web_search","input":{},"providerExecuted":true}
        ,
    });
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), (try requireReceipt(&observation, test_started_at_ms)).billable_web_search_calls);
}

test "identity: malformed or conflicting generation metadata is invalid" {
    const cases = [_][]const u8{
        \\{"type":"text-start","providerMetadata":"gateway"}
        ,
        \\{"type":"text-start","providerMetadata":null}
        ,
        \\{"type":"text-start","providerMetadata":{"gateway":[]}}
        ,
        \\{"type":"text-start","providerMetadata":{"gateway":{"generationId":7}}}
        ,
        \\{"type":"text-start","providerMetadata":{"gateway":{"generationId":"gen_short"}}}
        ,
        \\{"type":"text-start","providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAI"}}}
        ,
        \\{"type":"text-start","providerMetadata":{"gateway":{"generationId":"gen_01arz3ndektsv4rrffq69g5fav"}}}
        ,
        \\{"type":"text-start","providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAW"}}}
        ,
        // No type field: identity is still captured, as in fx.
        \\{"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAW"}}}
        ,
    };
    for (cases) |bad| {
        var observation = try observeAll(testing.allocator, &.{ id_event, bad, valid_finish });
        defer observation.deinit(testing.allocator);
        try testing.expectEqual(Identity.invalid, observation.identity());
        try testing.expect(observation.receipt(test_started_at_ms) == null);
    }
}

test "identity: a repeated id stays valid, and metadata without an id is ignored" {
    var observation = try observeAll(testing.allocator, &.{
        id_event,
        id_event,
        \\{"type":"text-start","providerMetadata":{"anthropic":{"id":"msg"}}}
        ,
        \\{"type":"text-start","providerMetadata":{"gateway":{"routing":{}}}}
        ,
        valid_finish,
    });
    defer observation.deinit(testing.allocator);
    try testing.expectEqualStrings(test_id, (try requireId(&observation)));
    try testing.expect(observation.receipt(test_started_at_ms) != null);
}

test "identity: a receipt needs a generation id" {
    const finish_without_id =
        \\{"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}},"providerMetadata":{"gateway":{"gatewayCost":"0.1","routing":{"canonicalSlug":"a/b"}}}}
    ;
    var observation = try observeAll(testing.allocator, &.{finish_without_id});
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(Identity.none, observation.identity());
    try testing.expect(observation.receipt(test_started_at_ms) == null);
}

test "timestamp: malformed, non-string, or conflicting values give no receipt" {
    const cases = [_][]const []const u8{
        &.{
            \\{"type":"response-metadata","timestamp":"2026-02-30T12:11:07Z"}
        },
        &.{
            \\{"type":"response-metadata","timestamp":"2026-04-01T12:11:07+00:00"}
        },
        &.{
            \\{"type":"response-metadata","timestamp":1775045467000}
        },
        &.{
            \\{"type":"response-metadata","timestamp":null}
        },
        &.{
            \\{"type":"response-metadata","timestamp":"2026-04-01T12:11:07Z"}
            ,
            \\{"type":"response-metadata","timestamp":"2026-04-01T12:11:08Z"}
        },
        // Once invalid, a later valid timestamp does not restore it.
        &.{
            \\{"type":"response-metadata","timestamp":"bad"}
            ,
            \\{"type":"response-metadata","timestamp":"2026-04-01T12:11:07Z"}
        },
        &.{
            \\{"type":"response-metadata","timestamp":"2026-04-01T12:11:07Z"}
            ,
            \\{"type":"response-metadata","timestamp":"2026-04-01T12:11:08Z"}
            ,
            \\{"type":"response-metadata","timestamp":"2026-04-01T12:11:07Z"}
        },
    };
    for (cases) |metadata| {
        var observation: Observation = .{};
        defer observation.deinit(testing.allocator);
        for (metadata) |event| try observation.observe(testing.allocator, event);
        try observation.observe(testing.allocator, valid_finish);
        try testing.expectEqual(Timestamp.invalid, observation.timestamp);
        try testing.expectEqualStrings(test_id, (try requireId(&observation)));
        try testing.expect(observation.receipt(test_started_at_ms) == null);
    }
}

test "timestamp: a repeated equal value is kept; other event types are ignored" {
    var observation = try observeAll(testing.allocator, &.{
        \\{"type":"response-metadata","timestamp":"2026-04-01T12:11:07.123456Z"}
        ,
        \\{"type":"response-metadata","timestamp":"2026-04-01T12:11:07.123Z"}
        ,
        \\{"type":"text-start","timestamp":"bad"}
        ,
        valid_finish,
    });
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 1_775_045_467_123), (try requireReceipt(&observation, test_started_at_ms)).created_at_ms);
}

test "a negative start time gives no receipt" {
    var observation = try observeAll(testing.allocator, &.{valid_finish});
    defer observation.deinit(testing.allocator);
    try testing.expect(observation.receipt(-1) == null);
    try testing.expectEqual(@as(i64, 0), (try requireReceipt(&observation, 0)).created_at_ms);
}

test "modelId: invalid or conflicting values make the identity invalid" {
    const cases = [_][]const []const u8{
        &.{
            \\{"type":"response-metadata","modelId":""}
        },
        &.{
            \\{"type":"response-metadata","modelId":7}
        },
        &.{"{\"type\":\"response-metadata\",\"modelId\":\"" ++ ("m" ** 129) ++ "\"}"},
        &.{
            \\{"type":"response-metadata","modelId":"a"}
            ,
            \\{"type":"response-metadata","modelId":"b"}
        },
    };
    for (cases) |metadata| {
        var observation: Observation = .{};
        defer observation.deinit(testing.allocator);
        for (metadata) |event| try observation.observe(testing.allocator, event);
        try observation.observe(testing.allocator, valid_finish);
        try testing.expectEqual(Identity.invalid, observation.identity());
        try testing.expect(observation.receipt(test_started_at_ms) == null);
    }

    var long_ok: Observation = .{};
    defer long_ok.deinit(testing.allocator);
    try long_ok.observe(testing.allocator, "{\"type\":\"response-metadata\",\"modelId\":\"" ++ ("m" ** 128) ++ "\"}");
    try long_ok.observe(testing.allocator, valid_finish);
    try testing.expect(long_ok.receipt(test_started_at_ms) != null);
}

test "malformed JSON fails the stream but keeps the id" {
    var observation = try observeAll(testing.allocator, &.{ id_event, "{\"type\":", valid_finish });
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(Phase.failed, observation.phase);
    try testing.expectEqualStrings(test_id, (try requireId(&observation)));
    try testing.expect(observation.receipt(test_started_at_ms) == null);
}

test "non-object events are skipped like fx" {
    var observation = try observeAll(testing.allocator, &.{ "[1,2]", "\"text\"", "7", "null", valid_finish });
    defer observation.deinit(testing.allocator);
    try testing.expect(observation.receipt(test_started_at_ms) != null);
}

test "token rules: totals, optional subtotals, and their bounds" {
    const bad_usages = comptime [_][]const u8{
        \\{"inputTokens":{"total":10,"cacheRead":11},"outputTokens":{"total":5}}
        ,
        \\{"inputTokens":{"total":10,"cacheWrite":11},"outputTokens":{"total":5}}
        ,
        \\{"inputTokens":{"total":10},"outputTokens":{"total":5,"reasoning":6}}
        ,
        \\{"inputTokens":{"total":10},"outputTokens":{}}
        ,
        \\{"inputTokens":{"cacheRead":0},"outputTokens":{"total":5}}
        ,
        \\{"inputTokens":{"total":1.5},"outputTokens":{"total":5}}
        ,
        \\{"inputTokens":{"total":10,"cacheRead":null},"outputTokens":{"total":5}}
        ,
        \\{"inputTokens":{"total":10,"cacheRead":-1},"outputTokens":{"total":5}}
        ,
        \\{"inputTokens":{"total":18446744073709551615},"outputTokens":{"total":5}}
        ,
        \\{"inputTokens":10,"outputTokens":{"total":5}}
        ,
        \\{"outputTokens":{"total":5}}
        ,
        \\[]
        ,
    };
    inline for (bad_usages) |usage| try expectNoReceipt(&.{comptime finishEvent(usage, default_cost, default_slug)});
    try expectNoReceipt(&.{
        \\{"type":"finish","finishReason":{"unified":"stop"},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","gatewayCost":"0.5","routing":{"canonicalSlug":"a/b"}}}}
    });

    const Accepted = struct { usage: []const u8, cache_read: u64, cache_write: u64, reasoning: ?u64 };
    const accepted = comptime [_]Accepted{
        .{ .usage =
        \\{"inputTokens":{"total":10},"outputTokens":{"total":5}}
        , .cache_read = 0, .cache_write = 0, .reasoning = null },
        .{ .usage =
        \\{"inputTokens":{"total":10,"cacheRead":10,"cacheWrite":10},"outputTokens":{"total":5,"reasoning":5}}
        , .cache_read = 10, .cache_write = 10, .reasoning = 5 },
        .{ .usage =
        \\{"inputTokens":{"total":10},"outputTokens":{"total":5,"reasoning":null}}
        , .cache_read = 0, .cache_write = 0, .reasoning = null },
        .{ .usage =
        \\{"inputTokens":{"total":9223372036854775807},"outputTokens":{"total":0,"reasoning":0}}
        , .cache_read = 0, .cache_write = 0, .reasoning = 0 },
    };
    inline for (accepted) |case| {
        var observation = try observeAll(testing.allocator, &.{comptime finishEvent(case.usage, default_cost, default_slug)});
        defer observation.deinit(testing.allocator);
        const got = (try requireReceipt(&observation, test_started_at_ms));
        try testing.expectEqual(case.cache_read, got.cache_read_tokens);
        try testing.expectEqual(case.cache_write, got.cache_write_tokens);
        try testing.expectEqual(case.reasoning, got.reasoning_tokens);
    }
}

test "canonicalSlug: same byte rule as fx" {
    const bad_slugs = comptime [_][]const u8{
        \\""
        ,
        \\"provider/model\ninjected"
        ,
        \\"provider model"
        ,
        \\"provider/\u007f"
        ,
        \\"provider/é"
        ,
        \\7
        ,
        \\null
        ,
        "\"" ++ ("a" ** 1025) ++ "\"",
    };
    inline for (bad_slugs) |slug| try expectNoReceipt(&.{comptime finishEvent(default_usage, default_cost, slug)});

    var observation = try observeAll(testing.allocator, &.{comptime finishEvent(default_usage, default_cost, "\"" ++ ("a" ** 1024) ++ "\"")});
    defer observation.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1024), (try requireReceipt(&observation, test_started_at_ms)).model.len);

    try expectNoReceipt(&.{
        \\{"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","gatewayCost":"0.1"}}}
    });
    try expectNoReceipt(&.{
        \\{"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","gatewayCost":"0.1","routing":"a/b"}}}
    });
}

test "lookup status policy, with 401/403 unauthorized" {
    try testing.expectEqual(LookupStatus.found_or_parse, classifyStatus(.ok));
    try testing.expectEqual(LookupStatus.retry, classifyStatus(.not_found));
    try testing.expectEqual(LookupStatus.retry, classifyStatus(.request_timeout));
    try testing.expectEqual(LookupStatus.retry, classifyStatus(.too_early));
    try testing.expectEqual(LookupStatus.retry, classifyStatus(.too_many_requests));
    try testing.expectEqual(LookupStatus.retry, classifyStatus(.internal_server_error));
    try testing.expectEqual(LookupStatus.retry, classifyStatus(.service_unavailable));
    try testing.expectEqual(LookupStatus.retry, classifyStatus(@enumFromInt(599)));
    // fx: preserve_pending.
    try testing.expectEqual(LookupStatus.unauthorized, classifyStatus(.unauthorized));
    try testing.expectEqual(LookupStatus.unauthorized, classifyStatus(.forbidden));
    try testing.expectEqual(LookupStatus.rejected, classifyStatus(.bad_request));
    try testing.expectEqual(LookupStatus.rejected, classifyStatus(.created));
    try testing.expectEqual(LookupStatus.rejected, classifyStatus(.no_content));
    try testing.expectEqual(LookupStatus.rejected, classifyStatus(.gone));
    try testing.expectEqual(LookupStatus.rejected, classifyStatus(@enumFromInt(302)));
}

test "lookup: parser accepts authoritative response fields" {
    const alloc = testing.allocator;
    const body =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","total_cost":0.00123,
        \\"upstream_inference_cost":0,"usage":0.00123,"created_at":"2026-05-22T00:00:00.000Z",
        \\"model":"provider/model","is_byok":false,"provider_name":"provider",
        \\"streamed":true,"finish_reason":"stop","latency":200,"generation_time":1500,
        \\"tokens_prompt":100,"tokens_completion":50,"native_tokens_prompt":100,
        \\"native_tokens_completion":50,"native_tokens_reasoning":0,"native_tokens_cached":20,
        \\"native_tokens_cache_creation":10,"billable_web_search_calls":2}}
    ;
    var record = try parseLookup(alloc, body, test_id);
    defer record.deinit(alloc);
    try testing.expectEqualStrings(test_id, record.id);
    try testing.expectEqualStrings("provider/model", record.model);
    try testing.expectApproxEqAbs(@as(f64, 0.00123), record.total_cost, 1e-12);
    try testing.expectEqual(@as(u64, 130), record.input_tokens);
    try testing.expectEqual(@as(u64, 50), record.output_tokens);
    try testing.expectEqual(@as(u64, 20), record.cache_read_tokens);
    try testing.expectEqual(@as(u64, 10), record.cache_write_tokens);
    try testing.expectEqual(@as(?u64, 0), record.reasoning_tokens);
    try testing.expectEqual(@as(u64, 2), record.billable_web_search_calls);
    try testing.expectEqual(try parseGatewayTimestamp("2026-05-22T00:00:00.000Z"), record.created_at_ms);
}

const minimal_lookup_body =
    \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","total_cost":0.00123,
    \\"created_at":"2026-05-22T00:00:00.000Z","model":"provider/model",
    \\"native_tokens_prompt":100,"native_tokens_completion":50,
    \\"native_tokens_reasoning":0,"native_tokens_cached":20,
    \\"native_tokens_cache_creation":10,"billable_web_search_calls":2}}
;

test "lookup: allocation failure is an error and leaks nothing" {
    // fx maps this error to a terminal rejection.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, parseLookup(failing.allocator(), minimal_lookup_body, test_id));
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn parseLookupForAllocationTest(alloc: Allocator, body: []const u8) !void {
    var record = try parseLookup(alloc, body, test_id);
    record.deinit(alloc);
}

test "parseLookup frees everything at every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, parseLookupForAllocationTest, .{minimal_lookup_body});
}

test "lookup: cached tokens count toward total input" {
    const alloc = testing.allocator;
    const body =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","total_cost":0.00340723,
        \\"created_at":"2026-07-28T05:27:02.000Z","model":"provider/model",
        \\"is_byok":false,"native_tokens_prompt":11,"native_tokens_completion":4,
        \\"native_tokens_reasoning":3,"native_tokens_cached":15513,
        \\"native_tokens_cache_creation":0,"billable_web_search_calls":0}}
    ;
    var record = try parseLookup(alloc, body, test_id);
    defer record.deinit(alloc);
    try testing.expectEqual(@as(u64, 15524), record.input_tokens);
    try testing.expectEqual(@as(u64, 7), record.output_tokens);
    try testing.expectEqual(@as(u64, 15513), record.cache_read_tokens);
}

test "lookup: rejects wrong identity and invalid billing" {
    const alloc = testing.allocator;
    const wrong_id =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAW","total_cost":1,
        \\"created_at":"2026-05-22T00:00:00.000Z","model":"provider/model",
        \\"native_tokens_prompt":1,"native_tokens_completion":1,
        \\"native_tokens_cached":0,"native_tokens_cache_creation":0,
        \\"billable_web_search_calls":0}}
    ;
    try testing.expectError(error.GenerationIdentityMismatch, parseLookup(alloc, wrong_id, test_id));

    const negative_cost =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","total_cost":-1,
        \\"created_at":"2026-05-22T00:00:00.000Z","model":"provider/model",
        \\"native_tokens_prompt":1,"native_tokens_completion":1,
        \\"native_tokens_cached":0,"native_tokens_cache_creation":0,
        \\"billable_web_search_calls":0}}
    ;
    try testing.expectError(error.InvalidGenerationRecord, parseLookup(alloc, negative_cost, test_id));

    const unsafe_model =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","model":"provider/model\ninjected"}}
    ;
    try testing.expectError(error.InvalidModel, parseLookup(alloc, unsafe_model, test_id));
}

test "parseLookup: error identities follow fx's check order" {
    const alloc = testing.allocator;
    const Case = struct { body: []const u8, expected: LookupParseError };
    const cases = [_]Case{
        .{ .body = "", .expected = error.InvalidGenerationRecord },
        .{ .body = "[]", .expected = error.InvalidGenerationRecord },
        .{ .body = "{}", .expected = error.InvalidGenerationRecord },
        .{ .body = "{\"data\":[]}", .expected = error.InvalidGenerationRecord },
        .{ .body = "{\"data\":{\"id\":\"gen_bad\"}}", .expected = error.InvalidGenerationRecord },
        .{ .body = "{\"data\":{\"id\":\"" ++ test_id ++ "\"}}", .expected = error.InvalidGenerationRecord },
        .{ .body = "{\"data\":{\"id\":\"" ++ test_id ++ "\",\"model\":\"\"}}", .expected = error.InvalidModel },
        .{ .body = "{\"data\":{\"id\":\"" ++ test_id ++ "\",\"model\":\"a/b\",\"created_at\":\"2026-05-22\"}}", .expected = error.InvalidGenerationRecord },
        .{ .body = "{\"data\":{\"id\":\"" ++ other_test_id ++ "\",\"model\":\"\"}}", .expected = error.GenerationIdentityMismatch },
    };
    for (cases) |case| try testing.expectError(case.expected, parseLookup(alloc, case.body, test_id));
    try testing.expectError(error.InvalidGenerationId, parseLookup(alloc, minimal_lookup_body, "gen_bad"));
}

test "parseLookup: number forms and token arithmetic match fx" {
    const alloc = testing.allocator;
    const prefix = "{\"data\":{\"id\":\"" ++ test_id ++ "\",\"created_at\":\"2026-05-22T00:00:00Z\",\"model\":\"a/b\",";
    const accepted =
        prefix ++ "\"total_cost\":2,\"native_tokens_prompt\":18446744073709551615,\"native_tokens_completion\":1," ++
        "\"native_tokens_cached\":0,\"native_tokens_cache_creation\":0,\"native_tokens_reasoning\":null,\"billable_web_search_calls\":0}}";
    var record = try parseLookup(alloc, accepted, test_id);
    defer record.deinit(alloc);
    try testing.expectEqual(@as(f64, 2), record.total_cost);
    try testing.expectEqual(std.math.maxInt(u64), record.input_tokens);
    try testing.expectEqual(@as(?u64, null), record.reasoning_tokens);
    try testing.expectEqual(@as(u64, 1), record.output_tokens);

    const rejected = [_][]const u8{
        // Input sum overflows.
        prefix ++ "\"total_cost\":2,\"native_tokens_prompt\":18446744073709551615,\"native_tokens_completion\":1," ++
            "\"native_tokens_cached\":1,\"native_tokens_cache_creation\":0,\"billable_web_search_calls\":0}}",
        // Output sum overflows.
        prefix ++ "\"total_cost\":2,\"native_tokens_prompt\":1,\"native_tokens_completion\":18446744073709551615," ++
            "\"native_tokens_cached\":0,\"native_tokens_cache_creation\":0,\"native_tokens_reasoning\":1,\"billable_web_search_calls\":0}}",
        // Cost as a string is not a number.
        prefix ++ "\"total_cost\":\"2\",\"native_tokens_prompt\":1,\"native_tokens_completion\":1," ++
            "\"native_tokens_cached\":0,\"native_tokens_cache_creation\":0,\"billable_web_search_calls\":0}}",
        // A fractional token count.
        prefix ++ "\"total_cost\":2,\"native_tokens_prompt\":1.5,\"native_tokens_completion\":1," ++
            "\"native_tokens_cached\":0,\"native_tokens_cache_creation\":0,\"billable_web_search_calls\":0}}",
        // Missing billable_web_search_calls.
        prefix ++ "\"total_cost\":2,\"native_tokens_prompt\":1,\"native_tokens_completion\":1," ++
            "\"native_tokens_cached\":0,\"native_tokens_cache_creation\":0}}",
        // Too large for u64.
        prefix ++ "\"total_cost\":2,\"native_tokens_prompt\":18446744073709551616,\"native_tokens_completion\":1," ++
            "\"native_tokens_cached\":0,\"native_tokens_cache_creation\":0,\"billable_web_search_calls\":0}}",
    };
    for (rejected) |body| try testing.expectError(error.InvalidGenerationRecord, parseLookup(alloc, body, test_id));
}

test "lookup: parser handles fuzzed bytes" {
    try testing.fuzz({}, fuzzLookup, .{
        .corpus = &.{
            "",
            "{}",
            "{\"data\":{}}",
            "{\"data\":{\"id\":\"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV\"}}",
            minimal_lookup_body,
        },
    });
}

fn fuzzLookup(_: void, smith: *testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var record = parseLookup(testing.allocator, buffer[0..len], test_id) catch return;
    record.deinit(testing.allocator);
}

test "Gateway timestamps parse UTC fractions strictly" {
    try testing.expectEqual(@as(i64, 1_775_045_467_000), try parseGatewayTimestamp("2026-04-01T12:11:07Z"));
    try testing.expectEqual(@as(i64, 1_775_045_467_123), try parseGatewayTimestamp("2026-04-01T12:11:07.123456Z"));
    try testing.expectEqual(@as(i64, 1_775_045_467_100), try parseGatewayTimestamp("2026-04-01T12:11:07.1Z"));
    try testing.expectEqual(@as(i64, 1_775_045_467_120), try parseGatewayTimestamp("2026-04-01T12:11:07.12Z"));
    try testing.expectEqual(@as(i64, 951_782_400_000), try parseGatewayTimestamp("2000-02-29T00:00:00Z"));
    try testing.expectEqual(@as(i64, 0), try parseGatewayTimestamp("1970-01-01T00:00:00Z"));
    const rejected = [_][]const u8{
        "2026-02-30T12:11:07Z",
        "2026-04-01T12:11:07+00:00",
        "1900-02-29T00:00:00Z",
        "1969-12-31T23:59:59Z",
        "2026-04-01T12:11:07.Z",
        "2026-04-01T12:11:07.1234567890Z",
        "2026-04-01T24:00:00Z",
        "2026-04-01 12:11:07Z",
        "2026-13-01T12:11:07Z",
        "2026-04-01T12:11:07",
        "2026-04-01T12:11:07Zx",
        "+026-04-01T12:11:07Z",
    };
    for (rejected) |text| try testing.expectError(error.InvalidGatewayTimestamp, parseGatewayTimestamp(text));
}

test "Gateway timestamp parser handles fuzzed bytes" {
    try testing.fuzz({}, fuzzGatewayTimestamp, .{
        .corpus = &.{ "", "2026-04-01T12:11:07Z", "2026-04-01T12:11:07.123456789Z" },
    });
}

fn fuzzGatewayTimestamp(_: void, smith: *testing.Smith) !void {
    var buffer: [128]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    _ = parseGatewayTimestamp(buffer[0..len]) catch return;
}

test "generation ids are gen_ plus 26 Crockford base32 characters" {
    try testing.expect(validGatewayGenerationId(test_id));
    try testing.expect(validGatewayGenerationId("gen_0123456789ABCDEFGHJKMNPQRS"[0..30]));
    const rejected = [_][]const u8{
        "",
        "gen_",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FA",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAVV",
        "GEN_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "gen-01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAI",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAL",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAO",
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAU",
        "gen_01arz3ndektsv4rrffq69g5fav",
    };
    for (rejected) |id| try testing.expect(!validGatewayGenerationId(id));
}

test "truncating any fixture event at any byte never yields a receipt or leaks" {
    const alloc = testing.allocator;
    for (streamed_routes) |route| {
        const sse = try readFixture(alloc, route.name, ".sse");
        defer alloc.free(sse);
        var events = try dataEvents(alloc, sse);
        defer events.deinit(alloc);

        for (events.items, 0..) |event, index| {
            var cut: usize = 0;
            while (cut < event.len) : (cut += 1) {
                var observation: Observation = .{};
                defer observation.deinit(alloc);
                for (events.items[0..index]) |before| try observation.observe(alloc, before);
                try observation.observe(alloc, event[0..cut]);
                for (events.items[index + 1 ..]) |after| try observation.observe(alloc, after);
                try testing.expect(observation.receipt(test_started_at_ms) == null);
            }
        }
    }
}

test "garbled fixture bytes never crash, leak, or break receipt invariants" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed_0001);
    const random = prng.random();
    const garbage = "{}[]\":,0123456789-.eE+ntrufalsgen_\\\x00\xff";
    for (streamed_routes) |route| {
        const sse = try readFixture(alloc, route.name, ".sse");
        defer alloc.free(sse);
        var events = try dataEvents(alloc, sse);
        defer events.deinit(alloc);

        var round: usize = 0;
        while (round < 400) : (round += 1) {
            const index = random.uintLessThan(usize, events.items.len);
            const mutated = try alloc.dupe(u8, events.items[index]);
            defer alloc.free(mutated);
            const flips = 1 + random.uintLessThan(usize, 4);
            for (0..flips) |_| {
                mutated[random.uintLessThan(usize, mutated.len)] = garbage[random.uintLessThan(usize, garbage.len)];
            }

            var observation: Observation = .{};
            defer observation.deinit(alloc);
            for (events.items, 0..) |event, i| {
                try observation.observe(alloc, if (i == index) mutated else event);
            }
            if (observation.receipt(test_started_at_ms)) |got| try expectReceiptInvariants(got);
        }
    }
}

test "observe handles fuzzed event streams" {
    try testing.fuzz({}, fuzzObserve, .{
        .corpus = &.{
            "",
            "[DONE]",
            metadata_with_timestamp ++ "\n" ++ id_event ++ "\n" ++ valid_finish,
            exact_billing_prefix[1] ++ "\n" ++ valid_finish,
            "{\"type\":\"tool-input-start\",\"id\":\"b\",\"toolName\":\"exa_search\"}\n{\"type\":\"tool-call\",\"toolCallId\":\"b\"}",
        },
    });
}

fn fuzzObserve(_: void, smith: *testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var observation: Observation = .{ .expected_provider_tool = "exa_search" };
    defer observation.deinit(testing.allocator);
    var events = std.mem.splitScalar(u8, buffer[0..len], '\n');
    while (events.next()) |event| try observation.observe(testing.allocator, event);
    if (observation.receipt(test_started_at_ms)) |got| try expectReceiptInvariants(got);
    _ = observation.identity();
}

fn observeForAllocationTest(alloc: Allocator, events: []const []const u8) !void {
    var observation: Observation = .{};
    defer observation.deinit(alloc);
    for (events) |event| try observation.observe(alloc, event);
    _ = observation.receipt(test_started_at_ms) orelse return error.TestExpectedReceipt;
}

test "observe frees everything at every allocation failure" {
    const events = [_][]const u8{
        metadata_with_timestamp,
        id_event,
        \\{"type":"tool-input-start","id":"b","toolName":"exa_search"}
        ,
        \\{"type":"tool-call","toolCallId":"b","providerExecuted":true}
        ,
        valid_finish,
    };
    try testing.checkAllAllocationFailures(testing.allocator, observeForAllocationTest, .{@as([]const []const u8, &events)});

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var observation: Observation = .{};
    try testing.expectError(error.OutOfMemory, observation.observe(failing.allocator(), valid_finish));
    try testing.expectEqual(Phase.failed, observation.phase);
    try testing.expect(observation.receipt(test_started_at_ms) == null);
    observation.deinit(failing.allocator());
}
