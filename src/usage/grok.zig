//! A Grok plan's usage as the Grok CLI proxy (`cli-chat-proxy.grok.com/v1`)
//! reports it: how much of the plan's allowance this period has used, in
//! total and by product, and the bought credits and pay-as-you-go spending
//! beside it. Money is in US cents, as magnitudes: Grok stores bought
//! credits as negative cents. `/settings` adds the plan's name.

const std = @import("std");
const report = @import("report.zig");

const Allocator = std.mem.Allocator;

pub const billing_path = "/billing?format=credits";
pub const settings_path = "/settings";

pub const max_body_bytes: usize = 256 * 1024;
const max_products: usize = 16;
const max_text_bytes: usize = 64;
const max_url_bytes: usize = 512;
/// A period can run over its allowance; anything past this is not a usage
/// figure.
const max_percent: f64 = 10_000;
/// A billion dollars.
const max_cents: i64 = 100_000_000_000;

pub const PeriodKind = enum { weekly, monthly };

pub const Product = struct {
    /// Lowercase words, e.g. `grok build` from `PRODUCT_GROK_BUILD`.
    name: []const u8,
    used_percent: f64,
};

/// What `/settings` says about the plan.
pub const Settings = struct {
    /// The plan's display name, e.g. `SuperGrok Heavy`.
    plan: ?[]const u8 = null,
    /// Whether pay-as-you-go is on.
    on_demand_enabled: ?bool = null,
    /// Where a team manages its usage instead of fx showing it.
    usage_url: ?[]const u8 = null,
};

pub const Usage = struct {
    /// Percent of the plan's allowance used this period.
    used_percent: ?f64 = null,
    period: ?PeriodKind = null,
    /// When the period ends and the allowance resets.
    resets_at_ms: ?i64 = null,
    products: []const Product = &.{},
    /// Bought credits left.
    prepaid_cents: ?i64 = null,
    /// Pay-as-you-go spending this month, and its cap.
    on_demand_used_cents: ?i64 = null,
    on_demand_cap_cents: ?i64 = null,
    /// From `/settings`, when it answered.
    settings: ?Settings = null,

    /// Whether billing reported anything to show.
    pub fn hasBilling(self: Usage) bool {
        return self.used_percent != null or self.products.len > 0 or self.prepaid_cents != null or
            self.on_demand_used_cents != null or self.on_demand_cap_cents != null;
    }

    pub fn plan(self: Usage) ?[]const u8 {
        const s = self.settings orelse return null;
        return s.plan;
    }

    /// A deep copy into `alloc`.
    pub fn clone(self: Usage, alloc: Allocator) Allocator.Error!Usage {
        const products = try alloc.alloc(Product, self.products.len);
        for (products, self.products) |*to, from| to.* = .{ .name = try alloc.dupe(u8, from.name), .used_percent = from.used_percent };
        var copy = self;
        copy.products = products;
        if (self.settings) |s| copy.settings = .{
            .plan = if (s.plan) |p| try alloc.dupe(u8, p) else null,
            .on_demand_enabled = s.on_demand_enabled,
            .usage_url = if (s.usage_url) |u| try alloc.dupe(u8, u) else null,
        };
        return copy;
    }

    /// Whether every field is in range, for data read back from disk.
    pub fn valid(self: Usage) bool {
        if (self.used_percent) |v| if (!validPercent(v)) return false;
        if (self.products.len > max_products) return false;
        for (self.products) |p| {
            if (p.name.len == 0 or p.name.len > max_text_bytes or !validPercent(p.used_percent)) return false;
        }
        inline for (.{ self.prepaid_cents, self.on_demand_used_cents, self.on_demand_cap_cents }) |amount| {
            if (amount) |c| if (c < 0 or c > max_cents) return false;
        }
        if (self.settings) |s| {
            if (s.plan) |p| if (p.len == 0 or p.len > max_text_bytes) return false;
            if (s.usage_url) |u| if (!validUrl(u)) return false;
        }
        return true;
    }
};

fn validPercent(v: f64) bool {
    return std.math.isFinite(v) and v >= 0 and v <= max_percent;
}

fn validUrl(url: []const u8) bool {
    return url.len <= max_url_bytes and std.mem.startsWith(u8, url, "https://");
}

pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    usage: Usage,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

pub const SettingsOwned = struct {
    arena: std.heap.ArenaAllocator,
    settings: Settings,

    pub fn deinit(self: *SettingsOwned) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{ InvalidResponse, OutOfMemory };

/// Parses a `/billing?format=credits` body: the credits shape, or the older
/// monthly shape it replaced. `config: null` is a plan without billing data.
/// Caller owns the result; it copies every string.
pub fn parseBilling(gpa: Allocator, body: []const u8) ParseError!Owned {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const root = try parseObject(alloc, body);
    var usage: Usage = .{};
    const config = switch (root.get("config") orelse .null) {
        .null => return .{ .arena = arena, .usage = usage },
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    usage.used_percent = try percent(config.get("creditUsagePercent"));
    if (config.get("currentPeriod")) |value| switch (value) {
        .null => {},
        .object => |period| {
            if (period.get("type")) |t| if (t == .string) {
                if (std.mem.endsWith(u8, t.string, "_WEEKLY")) usage.period = .weekly;
                if (std.mem.endsWith(u8, t.string, "_MONTHLY")) usage.period = .monthly;
            };
            if (period.get("end")) |end| if (end == .string) {
                usage.resets_at_ms = timeOf(end.string);
            };
        },
        else => return error.InvalidResponse,
    };

    // The older shape: a monthly allowance and what was used of it.
    if (usage.used_percent == null) {
        const limit = try cents(config.get("monthlyLimit"));
        const used = try cents(config.get("used"));
        if (limit) |l| if (l > 0) {
            const share = @as(f64, @floatFromInt(@max(used orelse 0, 0))) * 100 / @as(f64, @floatFromInt(l));
            usage.used_percent = @min(share, max_percent);
            if (usage.period == null) usage.period = .monthly;
        };
    }
    if (usage.resets_at_ms == null) if (config.get("billingPeriodEnd")) |end| if (end == .string) {
        usage.resets_at_ms = timeOf(end.string);
    };
    // proto3 leaves out a zero, so a period without a percentage is unused.
    if (usage.used_percent == null and usage.period != null) usage.used_percent = 0;

    if (config.get("productUsage")) |value| switch (value) {
        .null => {},
        .array => |items| {
            var products: std.ArrayList(Product) = .empty;
            for (items.items) |item| {
                if (item != .object) return error.InvalidResponse;
                if (products.items.len == max_products) break;
                const product = item.object.get("product") orelse continue;
                if (product != .string) return error.InvalidResponse;
                const name = try productName(alloc, product.string) orelse continue;
                // proto3 leaves out a zero.
                const used = try percent(item.object.get("usagePercent")) orelse 0;
                try products.append(alloc, .{ .name = name, .used_percent = used });
            }
            usage.products = products.items;
        },
        else => return error.InvalidResponse,
    };

    usage.prepaid_cents = try cents(config.get("prepaidBalance"));
    usage.on_demand_used_cents = try cents(config.get("onDemandUsed"));
    usage.on_demand_cap_cents = try cents(config.get("onDemandCap"));
    if (!usage.valid()) return error.InvalidResponse;
    return .{ .arena = arena, .usage = usage };
}

/// Parses `/settings`, keeping only the plan's name, pay-as-you-go and a
/// team's usage page. Caller owns the result.
pub fn parseSettings(gpa: Allocator, body: []const u8) ParseError!SettingsOwned {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const root = try parseObject(arena.allocator(), body);
    const settings: Settings = .{
        .plan = try shortText(root.get("subscription_tier_display")) orelse try shortText(root.get("subscription_tier")),
        .on_demand_enabled = switch (root.get("on_demand_enabled") orelse .null) {
            .null => null,
            .bool => |b| b,
            else => return error.InvalidResponse,
        },
        .usage_url = switch (root.get("usage_billing_redirect_url") orelse .null) {
            .string => |u| if (validUrl(u)) u else null,
            else => null,
        },
    };
    return .{ .arena = arena, .settings = settings };
}

fn parseObject(alloc: Allocator, body: []const u8) ParseError!std.json.ObjectMap {
    if (body.len > max_body_bytes) return error.InvalidResponse;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    if (root != .object) return error.InvalidResponse;
    return root.object;
}

/// `PRODUCT_GROK_BUILD` as `grok build`; null for an unnamed product.
fn productName(alloc: Allocator, raw: []const u8) ParseError!?[]const u8 {
    const bare = if (std.mem.startsWith(u8, raw, "PRODUCT_")) raw["PRODUCT_".len..] else raw;
    if (bare.len == 0 or bare.len > max_text_bytes or std.mem.eql(u8, bare, "UNSPECIFIED")) return null;
    const name = try alloc.alloc(u8, bare.len);
    for (bare, name) |from, *to| to.* = if (from == '_') ' ' else std.ascii.toLower(from);
    return name;
}

/// A percentage, or null when absent.
fn percent(value: ?std.json.Value) ParseError!?f64 {
    const v = value orelse return null;
    const f: f64 = switch (v) {
        .null => return null,
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return error.InvalidResponse,
    };
    if (!validPercent(f)) return error.InvalidResponse;
    return f;
}

/// A `Cent` (`{"val": n}`) as a magnitude in US cents, or null when absent.
/// proto3 sends a zero as `{}` and may send an int64 as a string.
fn cents(value: ?std.json.Value) ParseError!?i64 {
    const v = value orelse return null;
    const object = switch (v) {
        .null => return null,
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const n: i64 = switch (object.get("val") orelse .null) {
        .null => 0,
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) <= max_cents) @intFromFloat(f) else return error.InvalidResponse,
        .string, .number_string => |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidResponse,
        else => return error.InvalidResponse,
    };
    if (n < -max_cents or n > max_cents) return error.InvalidResponse;
    return @intCast(@abs(n));
}

fn shortText(value: ?std.json.Value) ParseError!?[]const u8 {
    return switch (value orelse .null) {
        .null => null,
        .string => |s| if (s.len == 0 or s.len > max_text_bytes) null else s,
        else => error.InvalidResponse,
    };
}

/// An RFC 3339 time (`2026-06-08T00:00:00Z`, with an optional fraction and
/// offset) in milliseconds since the Unix epoch, or null when malformed.
fn timeOf(t: []const u8) ?i64 {
    if (t.len < 20 or t[4] != '-' or t[7] != '-' or (t[10] != 'T' and t[10] != 't') or t[13] != ':' or t[16] != ':') return null;
    const y = digits(t[0..4]) orelse return null;
    const m = digits(t[5..7]) orelse return null;
    const d = digits(t[8..10]) orelse return null;
    const hh = digits(t[11..13]) orelse return null;
    const mm = digits(t[14..16]) orelse return null;
    const ss = digits(t[17..19]) orelse return null;
    if (m < 1 or m > 12 or d < 1 or d > 31 or hh > 23 or mm > 59 or ss > 60) return null;
    var i: usize = 19;
    var ms: i64 = 0;
    if (t[i] == '.') {
        i += 1;
        var places: usize = 0;
        while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) {
            if (places < 3) {
                ms = ms * 10 + (t[i] - '0');
                places += 1;
            }
        }
        if (places == 0) return null;
        while (places < 3) : (places += 1) ms *= 10;
    }
    if (i >= t.len) return null;
    var offset_minutes: i64 = 0;
    switch (t[i]) {
        'Z', 'z' => if (i + 1 != t.len) return null,
        '+', '-' => {
            if (t.len != i + 6 or t[i + 3] != ':') return null;
            const oh = digits(t[i + 1 .. i + 3]) orelse return null;
            const om = digits(t[i + 4 .. i + 6]) orelse return null;
            offset_minutes = oh * 60 + om;
            if (t[i] == '-') offset_minutes = -offset_minutes;
        },
        else => return null,
    }
    const seconds = report.civilDay(y, m, d) * std.time.s_per_day + hh * 3600 + mm * 60 + ss - offset_minutes * 60;
    return seconds * std.time.ms_per_s + ms;
}

fn digits(s: []const u8) ?i64 {
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "the credits shape gives the period's use, its reset, products and money" {
    // The Grok CLI's own fixture for `GetGrokCreditsConfig`.
    const body =
        \\{"config":{"creditUsagePercent":42.5,
        \\"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"},
        \\"onDemandCap":{"val":5000},"onDemandUsed":{"val":300},"prepaidBalance":{"val":1250},
        \\"isUnifiedBillingUser":true,
        \\"productUsage":[{"product":"PRODUCT_GROK_BUILD","usagePercent":61.2},{"product":"PRODUCT_CHAT"},{"product":"PRODUCT_UNSPECIFIED","usagePercent":1}],
        \\"history":[{"period":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-05-25T00:00:00Z","end":"2026-06-01T00:00:00Z"},"onDemandUsed":{"val":120}}]}}
    ;
    var owned = try parseBilling(testing.allocator, body);
    defer owned.deinit();
    const u = owned.usage;
    try testing.expectEqual(@as(?f64, 42.5), u.used_percent);
    try testing.expectEqual(@as(?PeriodKind, .weekly), u.period);
    // 2026-06-08 is day 20612.
    try testing.expectEqual(@as(?i64, 20612 * std.time.ms_per_day), u.resets_at_ms);
    try testing.expectEqual(@as(usize, 2), u.products.len);
    try testing.expectEqualStrings("grok build", u.products[0].name);
    try testing.expectEqual(@as(f64, 61.2), u.products[0].used_percent);
    // A product without a percentage used none of the period.
    try testing.expectEqualStrings("chat", u.products[1].name);
    try testing.expectEqual(@as(f64, 0), u.products[1].used_percent);
    try testing.expectEqual(@as(?i64, 1250), u.prepaid_cents);
    try testing.expectEqual(@as(?i64, 300), u.on_demand_used_cents);
    try testing.expectEqual(@as(?i64, 5000), u.on_demand_cap_cents);
    try testing.expect(u.hasBilling() and u.settings == null);
}

test "the older monthly shape becomes a share of the allowance" {
    const body =
        \\{"config":{"monthlyLimit":{"val":2000},"used":{"val":1234},"onDemandCap":{"val":500},
        \\"billingPeriodStart":"2025-04-01T00:00:00Z","billingPeriodEnd":"2025-05-01T00:00:00Z",
        \\"history":[{"billingCycle":{"year":2025,"month":3},"includedUsed":{"val":1800}}]}}
    ;
    var owned = try parseBilling(testing.allocator, body);
    defer owned.deinit();
    try testing.expectApproxEqAbs(@as(f64, 61.7), owned.usage.used_percent.?, 1e-9);
    try testing.expectEqual(@as(?PeriodKind, .monthly), owned.usage.period);
    try testing.expectEqual(@as(?i64, report.civilDay(2025, 5, 1) * std.time.ms_per_day), owned.usage.resets_at_ms);
    try testing.expectEqual(@as(?i64, 500), owned.usage.on_demand_cap_cents);
    try testing.expectEqual(@as(?i64, null), owned.usage.prepaid_cents);
}

test "no billing data, proto3 zeros and string amounts parse" {
    var empty = try parseBilling(testing.allocator, "{\"config\":null}");
    defer empty.deinit();
    try testing.expect(!empty.usage.hasBilling());
    var bare = try parseBilling(testing.allocator, "{}");
    defer bare.deinit();
    try testing.expect(!bare.usage.hasBilling());

    var zeros = try parseBilling(testing.allocator, "{\"config\":{\"prepaidBalance\":{},\"onDemandCap\":{\"val\":\"4299\"}}}");
    defer zeros.deinit();
    try testing.expectEqual(@as(?i64, 0), zeros.usage.prepaid_cents);
    try testing.expectEqual(@as(?i64, 4299), zeros.usage.on_demand_cap_cents);
    try testing.expectEqual(@as(?f64, null), zeros.usage.used_percent);

    // Bought credits arrive negative; an unused period leaves out its 0%.
    var unused = try parseBilling(testing.allocator, "{\"config\":{\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_WEEKLY\",\"end\":\"2026-10-14T05:50:16.561Z\"},\"prepaidBalance\":{\"val\":-500},\"onDemandUsed\":{},\"onDemandCap\":{}}}");
    defer unused.deinit();
    try testing.expectEqual(@as(?f64, 0), unused.usage.used_percent);
    try testing.expectEqual(@as(?i64, 500), unused.usage.prepaid_cents);
    try testing.expectEqual(@as(?i64, (report.civilDay(2026, 10, 14) * std.time.s_per_day + 5 * 3600 + 50 * 60 + 16) * 1000 + 561), unused.usage.resets_at_ms);
}

test "malformed billing is rejected" {
    const bad = [_][]const u8{
        "[]",
        "not json",
        "{\"config\":[]}",
        "{\"config\":{\"creditUsagePercent\":-1}}",
        "{\"config\":{\"creditUsagePercent\":\"42\"}}",
        "{\"config\":{\"prepaidBalance\":5}}",
        "{\"config\":{\"prepaidBalance\":{\"val\":\"lots\"}}}",
        "{\"config\":{\"productUsage\":{}}}",
        "{\"config\":{\"productUsage\":[{\"product\":7}]}}",
    };
    for (bad) |body| try testing.expectError(error.InvalidResponse, parseBilling(testing.allocator, body));
}

test "settings give the plan's name, pay-as-you-go and a team's usage page" {
    var owned = try parseSettings(testing.allocator,
        \\{"subscription_tier":"supergrok_heavy","subscription_tier_display":"SuperGrok Heavy","on_demand_enabled":true,
        \\"usage_billing_redirect_url":"https://console.x.ai/team/usage","leader_mode":false}
    );
    defer owned.deinit();
    try testing.expectEqualStrings("SuperGrok Heavy", owned.settings.plan.?);
    try testing.expectEqual(@as(?bool, true), owned.settings.on_demand_enabled);
    try testing.expectEqualStrings("https://console.x.ai/team/usage", owned.settings.usage_url.?);

    var fallback = try parseSettings(testing.allocator, "{\"subscription_tier\":\"supergrok\",\"usage_billing_redirect_url\":\"javascript:alert(1)\"}");
    defer fallback.deinit();
    try testing.expectEqualStrings("supergrok", fallback.settings.plan.?);
    try testing.expectEqual(@as(?[]const u8, null), fallback.settings.usage_url);
    try testing.expectEqual(@as(?bool, null), fallback.settings.on_demand_enabled);
}

test "a clone survives the original and stays valid" {
    var owned = try parseBilling(testing.allocator, "{\"config\":{\"creditUsagePercent\":5,\"productUsage\":[{\"product\":\"PRODUCT_GROK_BUILD\",\"usagePercent\":5}]}}");
    var usage = owned.usage;
    usage.settings = .{ .plan = "SuperGrok", .usage_url = "https://grok.com/usage" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const copy = try usage.clone(arena.allocator());
    owned.deinit();
    try testing.expect(copy.valid());
    try testing.expectEqualStrings("grok build", copy.products[0].name);
    try testing.expectEqualStrings("SuperGrok", copy.plan().?);
}

test "RFC 3339 times with fractions and offsets" {
    const base = report.civilDay(2026, 6, 8) * std.time.ms_per_day;
    try testing.expectEqual(@as(?i64, base), timeOf("2026-06-08T00:00:00Z"));
    try testing.expectEqual(@as(?i64, base + 1500), timeOf("2026-06-08T00:00:01.5Z"));
    try testing.expectEqual(@as(?i64, base - 2 * std.time.ms_per_hour), timeOf("2026-06-08T00:00:00+02:00"));
    try testing.expectEqual(@as(?i64, base + 90 * std.time.ms_per_min), timeOf("2026-06-08T00:00:00-01:30"));
    for ([_][]const u8{ "2026-06-08", "2026-06-08T00:00:00", "2026-13-08T00:00:00Z", "2026-06-08T00:00:00.Z", "2026-06-08T00:00:00Zx" }) |bad| {
        try testing.expectEqual(@as(?i64, null), timeOf(bad));
    }
}
