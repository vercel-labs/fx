const std = @import("std");
const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;

pub fn write(
    writer: *std.Io.Writer,
    fact: usage_report.GenerationFact,
) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(fact.id, .{}, writer);
    try writer.print(",\"created_at_ms\":{d},\"model\":", .{fact.created_at_ms});
    try std.json.Stringify.value(fact.model, .{}, writer);
    try writer.print(
        ",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
        .{
            fact.input_tokens,
            fact.output_tokens,
            fact.cache_read_tokens,
            fact.cache_write_tokens,
        },
    );
    if (fact.reasoning_tokens) |reasoning| {
        try writer.print("{d}", .{reasoning});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"billable_web_search_calls\":{d},\"total_cost\":{d}}}",
        .{ fact.billable_web_search_calls, fact.total_cost },
    );
}

pub fn parse(
    alloc: Allocator,
    value: std.json.Value,
) (Allocator.Error || error{InvalidGenerationFact})!usage_report.GenerationFact {
    if (value != .object or
        (value.object.count() != 9 and value.object.count() != 10))
    {
        return error.InvalidGenerationFact;
    }
    const id_value = value.object.get("id") orelse
        return error.InvalidGenerationFact;
    const model_value = value.object.get("model") orelse
        return error.InvalidGenerationFact;
    const reasoning_value = value.object.get("reasoning_tokens") orelse
        return error.InvalidGenerationFact;
    if (id_value != .string or model_value != .string) {
        return error.InvalidGenerationFact;
    }
    const id = try alloc.dupe(u8, id_value.string);
    errdefer alloc.free(id);
    const model = try alloc.dupe(u8, model_value.string);
    errdefer alloc.free(model);
    const fact = usage_report.GenerationFact{
        .id = id,
        .created_at_ms = try parseI64(value.object.get("created_at_ms")),
        .model = model,
        .input_tokens = try parseU64(value.object.get("input_tokens")),
        .output_tokens = try parseU64(value.object.get("output_tokens")),
        .cache_read_tokens = try parseU64(
            value.object.get("cache_read_tokens"),
        ),
        .cache_write_tokens = try parseU64(
            value.object.get("cache_write_tokens"),
        ),
        .reasoning_tokens = if (reasoning_value == .null)
            null
        else
            try parseU64(reasoning_value),
        .billable_web_search_calls = if (value.object.get(
            "billable_web_search_calls",
        )) |field|
            try parseU64(field)
        else
            0,
        .total_cost = try parseCost(value.object.get("total_cost")),
    };
    try usage_report.validateFact(fact);
    return fact;
}

fn parseU64(
    value: ?std.json.Value,
) error{InvalidGenerationFact}!u64 {
    const actual = value orelse return error.InvalidGenerationFact;
    return switch (actual) {
        .integer => |number| if (number >= 0)
            std.math.cast(u64, number) orelse error.InvalidGenerationFact
        else
            error.InvalidGenerationFact,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch
            error.InvalidGenerationFact,
        else => error.InvalidGenerationFact,
    };
}

fn parseI64(value: ?std.json.Value) error{InvalidGenerationFact}!i64 {
    const number = try parseU64(value);
    return std.math.cast(i64, number) orelse error.InvalidGenerationFact;
}

fn parseCost(value: ?std.json.Value) error{InvalidGenerationFact}!f64 {
    const actual = value orelse return error.InvalidGenerationFact;
    const number: f64 = switch (actual) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch
            return error.InvalidGenerationFact,
        else => return error.InvalidGenerationFact,
    };
    if (!std.math.isFinite(number) or number < 0) {
        return error.InvalidGenerationFact;
    }
    return number;
}

test "codec round trips the shared generation fact shape" {
    const alloc = std.testing.allocator;
    const expected = usage_report.GenerationFact{
        .id = @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"),
        .created_at_ms = 42,
        .model = @constCast("provider/model"),
        .input_tokens = 8,
        .output_tokens = 3,
        .cache_read_tokens = 2,
        .cache_write_tokens = 1,
        .reasoning_tokens = null,
        .billable_web_search_calls = 4,
        .total_cost = 0.25,
    };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try write(&encoded.writer, expected);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded.written(),
        .{},
    );
    defer parsed.deinit();
    var decoded = try parse(alloc, parsed.value);
    defer decoded.deinit(alloc);

    try std.testing.expect(usage_report.GenerationFact.eql(expected, decoded));
    try std.testing.expect(std.mem.find(
        u8,
        encoded.written(),
        "request_count",
    ) == null);
}
