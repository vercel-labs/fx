//! Public catalog token rates in USD per token. Estimates exclude tool fees,
//! regional surcharges, and provider-specific discounts.
const std = @import("std");
const types = @import("../shared/types.zig");

const max_tiers = 4;
const Tier = struct { min: u64, max: ?u64, cost: f64 };
const Rate = struct {
    base: ?f64 = null,
    tiers: [max_tiers]Tier = .{Tier{ .min = 0, .max = null, .cost = 0 }} ** max_tiers,
    len: usize = 0,

    fn at(self: Rate, context: u64) ?f64 {
        if (self.len == 0) return self.base;
        for (self.tiers[0..self.len]) |tier| {
            if (context >= tier.min and (tier.max == null or context < tier.max.?)) return tier.cost;
        }
        return null;
    }
};

const Rates = struct {
    input: Rate,
    output: Rate,
    cache_read: Rate,
    cache_write: Rate,
};

pub const Pricing = struct {
    standard: Rates,
    fast: ?Rates = null,

    pub fn estimate(self: Pricing, usage: types.Usage, fast: bool) ?f64 {
        const rates = if (fast) self.fast orelse return null else self.standard;
        const input = usage.input_tokens orelse return null;
        const output = usage.output_tokens orelse return null;
        if (usage.reasoning_tokens) |reasoning| if (reasoning > output) return null;
        var buckets = [_]?u64{ usage.uncached_input_tokens, usage.cache_read_tokens, usage.cache_write_tokens };
        var known: u64 = 0;
        var missing: usize = 0;
        for (buckets) |bucket| {
            if (bucket) |count| {
                known = std.math.add(u64, known, count) catch return null;
            } else missing += 1;
        }
        if (known > input) return null;
        // A zero remainder proves absent buckets are zero. Otherwise exactly
        // one missing bucket can be derived from the inclusive input total.
        if (missing > 1 and known != input) return null;
        if (missing == 0 and known != input) return null;
        for (&buckets) |*bucket| if (bucket.* == null) {
            bucket.* = input - known;
        };
        const counts = [_]u64{ buckets[0].?, buckets[1].?, buckets[2].?, output };
        const prices = [_]?f64{ rates.input.at(input), rates.cache_read.at(input), rates.cache_write.at(input), rates.output.at(input) };
        var total: f64 = 0;
        for (counts, prices) |count, price| {
            if (count == 0) continue;
            const rate = price orelse return null;
            total += @as(f64, @floatFromInt(count)) * rate;
        }
        return if (std.math.isFinite(total) and total >= 0) total else null;
    }
};

/// Invalid or unsupported pricing leaves estimation unavailable, without
/// preventing the model from being used.
pub fn parse(value: ?std.json.Value) ?Pricing {
    const object = value orelse return null;
    if (object != .object) return null;
    return .{
        .standard = parse_rates(object) catch return null,
        .fast = if (object.object.get("fast")) |fast| parse_rates(fast) catch null else null,
    };
}

fn parse_rates(value: std.json.Value) !Rates {
    if (value != .object) return error.InvalidPricing;
    return .{
        .input = try parse_rate(value, "input", "input_tiers"),
        .output = try parse_rate(value, "output", "output_tiers"),
        .cache_read = try parse_rate(value, "input_cache_read", "input_cache_read_tiers"),
        .cache_write = try parse_rate(value, "input_cache_write", "input_cache_write_tiers"),
    };
}

fn parse_rate(value: std.json.Value, key: []const u8, tiers_key: []const u8) !Rate {
    var rate: Rate = .{ .base = if (value.object.get(key)) |price| try parse_price(price) else null };
    const tiers = value.object.get(tiers_key) orelse return rate;
    if (tiers != .array or tiers.array.items.len == 0 or tiers.array.items.len > max_tiers) return error.InvalidPricing;
    for (tiers.array.items, 0..) |tier, i| {
        if (tier != .object) return error.InvalidPricing;
        const min = try unsigned(tier.object.get("min") orelse return error.InvalidPricing);
        const max = if (tier.object.get("max")) |limit| try unsigned(limit) else null;
        if (max != null and max.? <= min) return error.InvalidPricing;
        if (i > 0 and (rate.tiers[i - 1].max == null or rate.tiers[i - 1].max.? > min)) return error.InvalidPricing;
        rate.tiers[i] = .{ .min = min, .max = max, .cost = try parse_price(tier.object.get("cost") orelse return error.InvalidPricing) };
        rate.len += 1;
    }
    return rate;
}

fn unsigned(value: std.json.Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidPricing;
    return @intCast(value.integer);
}

fn parse_price(value: std.json.Value) !f64 {
    if (value != .string) return error.InvalidPricing;
    const price = std.fmt.parseFloat(f64, value.string) catch return error.InvalidPricing;
    if (!std.math.isFinite(price) or price < 0) return error.InvalidPricing;
    return price;
}

test "catalog pricing accounts for cache tokens and inclusive reasoning once" {
    const alloc = std.testing.allocator;
    var value = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"input":"0.000003","output":"0.000015","input_cache_read":"0.0000003","input_cache_write":"0.00000375"}
    , .{});
    defer value.deinit();
    const pricing = parse(value.value).?;
    const usage: types.Usage = .{ .input_tokens = 130, .output_tokens = 25, .cache_read_tokens = 20, .cache_write_tokens = 10, .reasoning_tokens = 5 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0007185), pricing.estimate(usage, false).?, 1e-12);
    try std.testing.expect(pricing.estimate(usage, true) == null);
    try std.testing.expect(pricing.estimate(.{ .input_tokens = 130, .output_tokens = 25 }, false) == null);
    try std.testing.expect(pricing.estimate(.{ .input_tokens = 10, .output_tokens = 2, .cache_read_tokens = 9, .cache_write_tokens = 2 }, false) == null);
    try std.testing.expect(pricing.estimate(.{ .input_tokens = 0 }, false) == null);
    try std.testing.expectEqual(@as(?f64, 0), pricing.estimate(.{ .input_tokens = 0, .output_tokens = 0 }, false));
    try std.testing.expectApproxEqAbs(@as(f64, 0.000036), pricing.estimate(.{ .input_tokens = 20, .output_tokens = 2, .cache_read_tokens = 20 }, false).?, 1e-12);
}

test "catalog pricing selects context and fast tiers at their boundaries" {
    var value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"input":"0.000001","input_tiers":[{"min":0,"max":200001,"cost":"0.000001"},{"min":200001,"cost":"0.000002"}],"output":"0.000003","fast":{"input":"0.000004","output":"0.000006"}}
    , .{});
    defer value.deinit();
    const pricing = parse(value.value).?;
    var usage: types.Usage = .{ .input_tokens = 200000, .uncached_input_tokens = 200000, .output_tokens = 1000 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.203), pricing.estimate(usage, false).?, 1e-12);
    usage.input_tokens = 200001;
    usage.uncached_input_tokens = 200001;
    try std.testing.expectApproxEqAbs(@as(f64, 0.403002), pricing.estimate(usage, false).?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.806004), pricing.estimate(usage, true).?, 1e-12);
}

test "catalog pricing rejects malformed rates and preserves unknown rates" {
    for ([_][]const u8{ "{\"input\":\"NaN\"}", "{\"output\":\"-1\"}", "{\"input_tiers\":[]}" }) |json| {
        var value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer value.deinit();
        try std.testing.expect(parse(value.value) == null);
    }
    var value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer value.deinit();
    try std.testing.expect(parse(value.value).?.estimate(.{ .input_tokens = 1, .uncached_input_tokens = 1, .output_tokens = 0 }, false) == null);
}
