const std = @import("std");
const protocol_validation = @import("protocol_validation.zig");
const client = @import("client.zig");
const generation_usage_provider = @import("../core/session/generation_usage_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;
const max_model_bytes: usize = 1024;

pub const provider = generation_usage_provider.Provider{
    .lookup_fn = lookup,
};

fn lookup(
    _: ?*anyopaque,
    alloc: Allocator,
    input: generation_usage_provider.LookupInput,
) generation_usage_provider.LookupError!generation_usage_provider.LookupOutcome {
    const origin = input.lookup_scope orelse return .reject;
    if (!client.isTrustedGenerationOrigin(origin)) return .reject;

    var response = client.fetchGatewayGenerationResult(
        alloc,
        input.credential,
        input.tenant,
        origin,
        input.generation_id,
        input.cancel_flag,
    ) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf(
                "gateway",
                "generation usage lookup failed reason={s}",
                .{@errorName(err)},
            );
            return .retry;
        },
    };
    defer response.deinit(alloc);

    if (response.status != .ok) {
        const outcome = classifyStatus(response.status);
        debug_trace.logf(
            "gateway",
            "generation usage lookup status={d} outcome={s}",
            .{ @intFromEnum(response.status), @tagName(outcome) },
        );
        return outcome;
    }
    return parseLookupOutcome(
        alloc,
        response.body,
        input.generation_id,
    );
}

fn classifyStatus(status: std.http.Status) generation_usage_provider.LookupOutcome {
    const code = @intFromEnum(status);
    if (code == 404 or code == 408 or code == 425 or code == 429 or code >= 500) {
        return .retry;
    }
    if (status == .unauthorized or status == .forbidden) {
        return .preserve_pending;
    }
    return .reject;
}

fn parseLookupOutcome(
    alloc: Allocator,
    body: []const u8,
    expected_id: []const u8,
) generation_usage_provider.LookupOutcome {
    const record = parseGenerationRecord(
        alloc,
        body,
        expected_id,
    ) catch |err| {
        debug_trace.logf(
            "gateway",
            "generation usage response rejected reason={s}",
            .{@errorName(err)},
        );
        return .reject;
    };
    return .{ .found = record };
}

/// Parses one authoritative `GET /v1/generation` response. A successful
/// record transfers its strings to `LookupOutcome.found`; direct test callers
/// release them with `freeGenerationRecord`.
fn parseGenerationRecord(
    alloc: Allocator,
    body: []const u8,
    expected_id: []const u8,
) !generation_usage_provider.Record {
    if (!protocol_validation.validGenerationId(expected_id)) {
        return error.InvalidGenerationId;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGenerationRecord,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGenerationRecord;
    const data = parsed.value.object.get("data") orelse
        return error.InvalidGenerationRecord;
    if (data != .object) return error.InvalidGenerationRecord;

    const id_value = data.object.get("id") orelse
        return error.InvalidGenerationRecord;
    if (id_value != .string or
        !protocol_validation.validGenerationId(id_value.string))
    {
        return error.InvalidGenerationRecord;
    }
    if (!std.mem.eql(u8, id_value.string, expected_id)) {
        return error.GenerationIdentityMismatch;
    }

    const model_value = data.object.get("model") orelse
        return error.InvalidGenerationRecord;
    if (model_value != .string) return error.InvalidGenerationRecord;
    try validateModel(model_value.string);

    const created_at_value = data.object.get("created_at") orelse
        return error.InvalidGenerationRecord;
    if (created_at_value != .string) return error.InvalidGenerationRecord;
    const created_at_ms = protocol_validation.parseTimestamp(created_at_value.string) catch
        return error.InvalidGenerationRecord;
    const total_cost = try parseNonNegativeNumber(data.object.get("total_cost"));
    const prompt_tokens = try parseNonNegativeInteger(
        data.object.get("native_tokens_prompt"),
    );
    const completion_tokens = try parseNonNegativeInteger(
        data.object.get("native_tokens_completion"),
    );
    const cache_read_tokens = try parseNonNegativeInteger(
        data.object.get("native_tokens_cached"),
    );
    const cache_write_tokens = try parseNonNegativeInteger(
        data.object.get("native_tokens_cache_creation"),
    );
    var input_tokens = std.math.add(
        u64,
        prompt_tokens,
        cache_read_tokens,
    ) catch return error.InvalidGenerationRecord;
    input_tokens = std.math.add(
        u64,
        input_tokens,
        cache_write_tokens,
    ) catch return error.InvalidGenerationRecord;
    const reasoning_tokens = try parseOptionalNonNegativeInteger(
        data.object.get("native_tokens_reasoning"),
    );
    const output_tokens = std.math.add(
        u64,
        completion_tokens,
        reasoning_tokens orelse 0,
    ) catch return error.InvalidGenerationRecord;
    const billable_web_search_calls = try parseNonNegativeInteger(
        data.object.get("billable_web_search_calls"),
    );

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

fn freeGenerationRecord(
    alloc: Allocator,
    record: *generation_usage_provider.Record,
) void {
    alloc.free(@constCast(record.id));
    alloc.free(@constCast(record.model));
    record.* = undefined;
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > max_model_bytes) {
        return error.InvalidModel;
    }
    for (model) |char| {
        if (char < 0x21 or char > 0x7e) return error.InvalidModel;
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
    if (!std.math.isFinite(number) or number < 0) {
        return error.InvalidGenerationRecord;
    }
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

test "generation lookup status policy preserves retry and auth outcomes" {
    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.retry,
        classifyStatus(.not_found),
    );
    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.retry,
        classifyStatus(.request_timeout),
    );
    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.retry,
        classifyStatus(.too_early),
    );
    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.retry,
        classifyStatus(.too_many_requests),
    );
    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.retry,
        classifyStatus(.internal_server_error),
    );
    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.preserve_pending,
        classifyStatus(.unauthorized),
    );
    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.preserve_pending,
        classifyStatus(.forbidden),
    );
    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.reject,
        classifyStatus(.bad_request),
    );
}

test "generation lookup rejects untrusted origins before transport" {
    var cancel = std.atomic.Value(bool).init(false);
    const outcome = try provider.lookup(std.testing.allocator, .{
        .credential = "unused",
        .tenant = null,
        .lookup_scope = "https://example.com",
        .generation_id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .cancel_flag = &cancel,
    });
    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.reject,
        outcome,
    );
}

test "generation record parser accepts authoritative response fields" {
    const alloc = std.testing.allocator;
    const body =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","total_cost":0.00123,
        \\"upstream_inference_cost":0,"usage":0.00123,"created_at":"2026-05-22T00:00:00.000Z",
        \\"model":"provider/model","is_byok":false,"provider_name":"provider",
        \\"streamed":true,"finish_reason":"stop","latency":200,"generation_time":1500,
        \\"tokens_prompt":100,"tokens_completion":50,"native_tokens_prompt":100,
        \\"native_tokens_completion":50,"native_tokens_reasoning":0,"native_tokens_cached":20,
        \\"native_tokens_cache_creation":10,"billable_web_search_calls":2}}
    ;

    var record = try parseGenerationRecord(
        alloc,
        body,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
    );
    defer freeGenerationRecord(alloc, &record);
    try std.testing.expectEqualStrings("provider/model", record.model);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00123), record.total_cost, 1e-12);
    try std.testing.expectEqual(@as(u64, 130), record.input_tokens);
    try std.testing.expectEqual(@as(u64, 50), record.output_tokens);
    try std.testing.expectEqual(@as(u64, 20), record.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 10), record.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 2), record.billable_web_search_calls);
}

test "generation response allocation failure remains a terminal rejection" {
    const body =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","total_cost":0.00123,
        \\"created_at":"2026-05-22T00:00:00.000Z","model":"provider/model",
        \\"native_tokens_prompt":100,"native_tokens_completion":50,
        \\"native_tokens_reasoning":0,"native_tokens_cached":20,
        \\"native_tokens_cache_creation":10,"billable_web_search_calls":2}}
    ;
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    var outcome = parseLookupOutcome(
        failing.allocator(),
        body,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
    );
    defer outcome.deinit(failing.allocator());

    try std.testing.expectEqual(
        generation_usage_provider.LookupOutcome.reject,
        outcome,
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "generation record parser includes cached tokens in total input" {
    const alloc = std.testing.allocator;
    const body =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","total_cost":0.00340723,
        \\"created_at":"2026-07-28T05:27:02.000Z","model":"provider/model",
        \\"is_byok":false,"native_tokens_prompt":11,"native_tokens_completion":4,
        \\"native_tokens_reasoning":3,"native_tokens_cached":15513,
        \\"native_tokens_cache_creation":0,"billable_web_search_calls":0}}
    ;

    var record = try parseGenerationRecord(
        alloc,
        body,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
    );
    defer freeGenerationRecord(alloc, &record);
    try std.testing.expectEqual(@as(u64, 15524), record.input_tokens);
    try std.testing.expectEqual(@as(u64, 7), record.output_tokens);
    try std.testing.expectEqual(@as(u64, 15513), record.cache_read_tokens);
}

test "generation record parser rejects wrong identity and invalid billing" {
    const alloc = std.testing.allocator;
    const wrong_id =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAW","total_cost":1,
        \\"created_at":"2026-05-22T00:00:00.000Z","model":"provider/model",
        \\"native_tokens_prompt":1,"native_tokens_completion":1,
        \\"native_tokens_cached":0,"native_tokens_cache_creation":0,
        \\"billable_web_search_calls":0}}
    ;
    try std.testing.expectError(
        error.GenerationIdentityMismatch,
        parseGenerationRecord(
            alloc,
            wrong_id,
            "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        ),
    );

    const negative_cost =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","total_cost":-1,
        \\"created_at":"2026-05-22T00:00:00.000Z","model":"provider/model",
        \\"native_tokens_prompt":1,"native_tokens_completion":1,
        \\"native_tokens_cached":0,"native_tokens_cache_creation":0,
        \\"billable_web_search_calls":0}}
    ;
    try std.testing.expectError(
        error.InvalidGenerationRecord,
        parseGenerationRecord(
            alloc,
            negative_cost,
            "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        ),
    );

    const unsafe_model =
        \\{"data":{"id":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV","model":"provider/model\ninjected"}}
    ;
    try std.testing.expectError(
        error.InvalidModel,
        parseGenerationRecord(
            alloc,
            unsafe_model,
            "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        ),
    );
}

test "generation record parser handles fuzzed bytes" {
    try std.testing.fuzz({}, fuzzGenerationRecord, .{
        .corpus = &.{
            "",
            "{}",
            "{\"data\":{}}",
            "{\"data\":{\"id\":\"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV\"}}",
        },
    });
}

fn fuzzGenerationRecord(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var record = parseGenerationRecord(
        std.testing.allocator,
        buffer[0..len],
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
    ) catch return;
    defer freeGenerationRecord(std.testing.allocator, &record);
}
