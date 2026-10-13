//! Codex (ChatGPT plan) usage: the request paths and the parsers for
//! `GET chatgpt.com/backend-api/wham/usage` (limits and credits),
//! `wham/profiles/me` (token activity) and
//! `wham/usage/daily-token-usage-breakdown` (usage by model and surface).
//! Pure; the caller owns all I/O. A ChatGPT plan is rate-limited rather than
//! billed, so its usage is tokens, shares of usage and limit windows.

const std = @import("std");
const report = @import("report.zig");

const Allocator = std.mem.Allocator;

pub const path = "/backend-api/wham/usage";
pub const profile_path = "/backend-api/wham/profiles/me";
pub const breakdown_path = "/backend-api/wham/usage/daily-token-usage-breakdown";

/// Largest response body accepted.
pub const max_body_bytes: usize = 256 * 1024;
const max_limits: usize = 16;
const max_text_bytes: usize = 64;
/// Daily buckets kept: enough for a calendar month and a week.
const max_days: usize = 62;
/// Model and speed pairs, or surfaces, kept per day and tallied per period.
pub const max_shares: usize = 32;

/// One limit window: how much of it is used and when it starts over.
pub const Window = struct {
    used_percent: f64,
    window_seconds: i64,
    resets_at_ms: ?i64 = null,
};

/// A named limit with up to two windows (Codex: about 5 hours and a week).
pub const Limit = struct {
    name: []const u8,
    reached: bool = false,
    primary: ?Window = null,
    secondary: ?Window = null,
};

pub const Credits = struct {
    has_credits: bool,
    unlimited: bool,
    /// The balance as ChatGPT reports it, when it reports one.
    balance: ?[]const u8 = null,
};

/// Tokens on one UTC day.
pub const Day = struct {
    /// Days since the Unix epoch.
    day: i64,
    tokens: u64,
};

/// The account's Codex activity. ChatGPT computes it once a day (`as_of_day`)
/// and may leave out any number.
pub const Profile = struct {
    name: ?[]const u8 = null,
    as_of_day: ?i64 = null,
    lifetime_tokens: ?u64 = null,
    peak_day_tokens: ?u64 = null,
    longest_turn_seconds: ?u64 = null,
    streak_days: ?u64 = null,
    best_streak_days: ?u64 = null,
    chats: ?u64 = null,
    fast_mode_percent: ?f64 = null,
    reasoning: ?[]const u8 = null,
    reasoning_percent: ?f64 = null,
    /// The most recent daily buckets, oldest first.
    days: []const Day = &.{},

    /// Tokens from `first_day` through `last_day`; null without daily data
    /// or when ChatGPT's stats end before `first_day`.
    pub fn tokensBetween(self: Profile, first_day: i64, last_day: i64) ?u64 {
        if (self.days.len == 0) return null;
        if (self.as_of_day) |as_of| if (as_of < first_day) return null;
        var sum: u64 = 0;
        for (self.days) |d| {
            if (d.day >= first_day and d.day <= last_day) sum +|= d.tokens;
        }
        return sum;
    }

    pub fn clone(self: Profile, alloc: Allocator) Allocator.Error!Profile {
        var copy = self;
        copy.name = if (self.name) |n| try alloc.dupe(u8, n) else null;
        copy.reasoning = if (self.reasoning) |r| try alloc.dupe(u8, r) else null;
        copy.days = try alloc.dupe(Day, self.days);
        return copy;
    }

    pub fn valid(self: Profile) bool {
        if (self.days.len > max_days) return false;
        inline for (.{ self.name, self.reasoning }) |t| {
            if (t) |v| if (v.len == 0 or v.len > max_text_bytes) return false;
        }
        inline for (.{ self.fast_mode_percent, self.reasoning_percent }) |pct| {
            if (pct) |v| if (!std.math.isFinite(v) or v < 0 or v > 100) return false;
        }
        return true;
    }
};

/// One model at one speed (`standard`, `fast`) on one day.
pub const ModelValue = struct {
    model: []const u8,
    speed: []const u8,
    value: f64,
};

/// Usage from one surface (the CLI, the desktop app, ...) on one day.
pub const SurfaceValue = struct {
    surface: []const u8,
    value: f64,
};

pub const BreakdownDay = struct {
    /// Days since the Unix epoch.
    day: i64,
    models: []const ModelValue = &.{},
    surfaces: []const SurfaceValue = &.{},
};

/// A model's or surface's share of a period's usage.
pub const Share = struct {
    name: []const u8,
    /// For models: `standard` or `fast`. Empty for surfaces.
    speed: []const u8 = "",
    percent: f64,
};

/// Daily usage by model and by surface. ChatGPT reports relative values:
/// the days in one response share a scale on which the busiest is 100,
/// weighted the way credits count (fast mode counts more). Only shares
/// within one response mean anything, so shares are all this offers.
pub const Breakdown = struct {
    /// Oldest first.
    days: []const BreakdownDay = &.{},

    /// Each model and speed's share from `first_day` through `last_day`,
    /// largest first; empty when nothing was used.
    pub fn modelShares(self: Breakdown, first_day: i64, last_day: i64, out: *[max_shares]Share) []Share {
        var n: usize = 0;
        for (self.days) |d| {
            if (d.day < first_day or d.day > last_day) continue;
            for (d.models) |m| n = tally(out, n, m.model, m.speed, m.value);
        }
        return finish(out[0..n]);
    }

    /// Each surface's share under its readable name, largest first.
    pub fn surfaceShares(self: Breakdown, first_day: i64, last_day: i64, out: *[max_shares]Share) []Share {
        var n: usize = 0;
        for (self.days) |d| {
            if (d.day < first_day or d.day > last_day) continue;
            for (d.surfaces) |s| n = tally(out, n, surfaceLabel(s.surface), "", s.value);
        }
        return finish(out[0..n]);
    }

    pub fn clone(self: Breakdown, alloc: Allocator) Allocator.Error!Breakdown {
        const days = try alloc.alloc(BreakdownDay, self.days.len);
        for (days, self.days) |*to, from| {
            const models = try alloc.alloc(ModelValue, from.models.len);
            for (models, from.models) |*m, f| m.* = .{ .model = try alloc.dupe(u8, f.model), .speed = try alloc.dupe(u8, f.speed), .value = f.value };
            const surfaces = try alloc.alloc(SurfaceValue, from.surfaces.len);
            for (surfaces, from.surfaces) |*s, f| s.* = .{ .surface = try alloc.dupe(u8, f.surface), .value = f.value };
            to.* = .{ .day = from.day, .models = models, .surfaces = surfaces };
        }
        return .{ .days = days };
    }

    pub fn valid(self: Breakdown) bool {
        if (self.days.len > max_days) return false;
        for (self.days) |d| {
            if (d.models.len > max_shares or d.surfaces.len > max_shares) return false;
            for (d.models) |m| {
                if (!shortText(m.model) or !shortText(m.speed) or !validValue(m.value)) return false;
            }
            for (d.surfaces) |s| {
                if (!shortText(s.surface) or !validValue(s.value)) return false;
            }
        }
        return true;
    }
};

fn shortText(t: []const u8) bool {
    return t.len > 0 and t.len <= max_text_bytes;
}

fn validValue(v: f64) bool {
    return std.math.isFinite(v) and v >= 0;
}

fn tally(out: *[max_shares]Share, n: usize, name: []const u8, speed: []const u8, value: f64) usize {
    for (out[0..n]) |*s| {
        if (std.mem.eql(u8, s.name, name) and std.mem.eql(u8, s.speed, speed)) {
            s.percent += value;
            return n;
        }
    }
    if (n == out.len) return n;
    out[n] = .{ .name = name, .speed = speed, .percent = value };
    return n + 1;
}

/// Turns tallies into percentages of their total, drops zeros, and sorts
/// largest first, then by name and speed so ties keep their order.
fn finish(shares: []Share) []Share {
    var total: f64 = 0;
    for (shares) |s| total += s.percent;
    if (total <= 0) return shares[0..0];
    var n: usize = 0;
    for (shares) |s| {
        if (s.percent <= 0) continue;
        shares[n] = .{ .name = s.name, .speed = s.speed, .percent = s.percent / total * 100 };
        n += 1;
    }
    std.mem.sort(Share, shares[0..n], {}, struct {
        fn lessThan(_: void, a: Share, b: Share) bool {
            if (a.percent != b.percent) return a.percent > b.percent;
            const by_name = std.mem.order(u8, a.name, b.name);
            if (by_name != .eq) return by_name == .lt;
            return std.mem.order(u8, a.speed, b.speed) == .lt;
        }
    }.lessThan);
    return shares[0..n];
}

/// `33.5%`, or `<0.1%` for a sliver that would round to zero.
pub fn formatShare(buf: *[8]u8, percent: f64) []const u8 {
    if (percent > 0 and percent < 0.05) return "<0.1%";
    return std.mem.print(buf, "{d:.1}%", .{percent}) catch "-";
}

/// A readable name for one of ChatGPT's surface keys; work and personal
/// variants share one name, so their usage adds up.
pub fn surfaceLabel(key: []const u8) []const u8 {
    const names = [_]struct { []const u8, []const u8 }{
        .{ "desktop_app", "desktop app" },
        .{ "work_desktop", "desktop app" },
        .{ "work_web", "web" },
        .{ "work_mobile", "mobile" },
        .{ "vscode", "vs code" },
        .{ "github_code_review", "code review" },
        .{ "agent_identity", "agents" },
        .{ "unknown", "other" },
    };
    for (names) |n| if (std.mem.eql(u8, key, n[0])) return n[1];
    return key;
}

/// `<breakdown_path>?start_date=YYYY-MM-DD`: `first_day` through today.
pub fn breakdownPath(buf: []u8, first_day: i64) error{NoSpaceLeft}![]const u8 {
    const epoch: std.time.epoch.EpochDay = .{ .day = @intCast(@max(first_day, 0)) };
    const year_day = epoch.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.mem.print(buf, "{s}?start_date={d}-{d:0>2}-{d:0>2}", .{
        breakdown_path,
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
    });
}

pub const Usage = struct {
    plan: []const u8,
    /// The Codex limit first, then code review, then any others.
    limits: []const Limit = &.{},
    credits: ?Credits = null,
    spend_limit_reached: bool = false,
    /// Token activity, when `wham/profiles/me` answered.
    profile: ?Profile = null,
    /// Usage by model and surface, when the breakdown answered.
    breakdown: ?Breakdown = null,

    /// Whether any limit has a window to show.
    pub fn hasWindows(self: Usage) bool {
        for (self.limits) |limit| if (limit.primary != null or limit.secondary != null) return true;
        return false;
    }

    /// A deep copy into `alloc`.
    pub fn clone(self: Usage, alloc: Allocator) Allocator.Error!Usage {
        const limits = try alloc.alloc(Limit, self.limits.len);
        for (limits, self.limits) |*to, from| {
            to.* = from;
            to.name = try alloc.dupe(u8, from.name);
        }
        return .{
            .plan = try alloc.dupe(u8, self.plan),
            .limits = limits,
            .credits = if (self.credits) |c| .{
                .has_credits = c.has_credits,
                .unlimited = c.unlimited,
                .balance = if (c.balance) |b| try alloc.dupe(u8, b) else null,
            } else null,
            .spend_limit_reached = self.spend_limit_reached,
            .profile = if (self.profile) |p| try p.clone(alloc) else null,
            .breakdown = if (self.breakdown) |b| try b.clone(alloc) else null,
        };
    }

    /// Whether every field is in range, for data read back from disk.
    pub fn valid(self: Usage) bool {
        if (self.plan.len == 0 or self.plan.len > max_text_bytes or self.limits.len > max_limits) return false;
        for (self.limits) |limit| {
            if (limit.name.len == 0 or limit.name.len > max_text_bytes) return false;
            inline for (.{ limit.primary, limit.secondary }) |window| {
                if (window) |w| if (!std.math.isFinite(w.used_percent) or w.used_percent < 0 or w.window_seconds < 0) return false;
            }
        }
        if (self.credits) |c| if (c.balance) |b| if (b.len > max_text_bytes) return false;
        if (self.profile) |p| if (!p.valid()) return false;
        if (self.breakdown) |b| if (!b.valid()) return false;
        return true;
    }
};

/// Usage and the arena that owns its strings.
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    usage: Usage,

    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{ InvalidResponse, OutOfMemory };

/// Parses a `wham/usage` body. `now_ms` turns `reset_after_seconds` into a
/// time when `reset_at` is missing. Caller owns the result, which copies
/// every string, so `body` may be freed right after.
pub fn parse(gpa: Allocator, body: []const u8, now_ms: i64) ParseError!Owned {
    if (body.len > max_body_bytes) return error.InvalidResponse;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    if (root != .object) return error.InvalidResponse;
    const plan = try text(root.object.get("plan_type") orelse return error.InvalidResponse);

    var limits: std.ArrayList(Limit) = .empty;
    if (try limitOf(root.object.get("rate_limit"), "codex", now_ms)) |limit| try limits.append(alloc, limit);
    if (try limitOf(root.object.get("code_review_rate_limit"), "code review", now_ms)) |limit| try limits.append(alloc, limit);
    if (root.object.get("additional_rate_limits")) |extra| switch (extra) {
        .null => {},
        .array => |items| for (items.items) |item| {
            if (item != .object) return error.InvalidResponse;
            if (limits.items.len == max_limits) break;
            const name = try text(item.object.get("limit_name") orelse return error.InvalidResponse);
            if (try limitOf(item.object.get("rate_limit"), name, now_ms)) |limit| try limits.append(alloc, limit);
        },
        else => return error.InvalidResponse,
    };

    var credits: ?Credits = null;
    if (root.object.get("credits")) |value| switch (value) {
        .null => {},
        .object => |o| credits = .{
            .has_credits = try flag(o.get("has_credits")),
            .unlimited = try flag(o.get("unlimited")),
            .balance = if (o.get("balance")) |b| switch (b) {
                .null => null,
                .string => try text(b),
                .integer, .float => try alloc.print("{d}", .{try number(b)}),
                else => return error.InvalidResponse,
            } else null,
        },
        else => return error.InvalidResponse,
    };

    var spend_limit_reached = false;
    if (root.object.get("spend_control")) |value| switch (value) {
        .null => {},
        .object => |o| spend_limit_reached = try flag(o.get("reached")),
        else => return error.InvalidResponse,
    };

    const usage: Usage = .{
        .plan = plan,
        .limits = limits.items,
        .credits = credits,
        .spend_limit_reached = spend_limit_reached,
    };
    if (!usage.valid()) return error.InvalidResponse;
    return .{ .arena = arena, .usage = usage };
}

/// A `RateLimitStatusDetails` object, or null when absent.
fn limitOf(value: ?std.json.Value, name: []const u8, now_ms: i64) ParseError!?Limit {
    const v = value orelse return null;
    if (v == .null) return null;
    if (v != .object) return error.InvalidResponse;
    return .{
        .name = name,
        .reached = try flag(v.object.get("limit_reached")),
        .primary = try windowOf(v.object.get("primary_window"), now_ms),
        .secondary = try windowOf(v.object.get("secondary_window"), now_ms),
    };
}

fn windowOf(value: ?std.json.Value, now_ms: i64) ParseError!?Window {
    const v = value orelse return null;
    if (v == .null) return null;
    if (v != .object) return error.InvalidResponse;
    const o = v.object;
    const used = try number(o.get("used_percent") orelse return error.InvalidResponse);
    const seconds = try number(o.get("limit_window_seconds") orelse return error.InvalidResponse);
    const reset_at = if (o.get("reset_at")) |r| (if (r == .null) null else try number(r)) else null;
    const reset_after = if (o.get("reset_after_seconds")) |r| (if (r == .null) null else try number(r)) else null;
    const resets_at_ms: ?i64 = if (reset_at) |at|
        @intFromFloat(at * std.time.ms_per_s)
    else if (reset_after) |after|
        now_ms + @as(i64, @intFromFloat(after * std.time.ms_per_s))
    else
        null;
    return .{ .used_percent = used, .window_seconds = @intFromFloat(seconds), .resets_at_ms = resets_at_ms };
}

/// A profile and the arena that owns its strings.
pub const ProfileOwned = struct {
    arena: std.heap.ArenaAllocator,
    profile: Profile,

    pub fn deinit(self: *ProfileOwned) void {
        self.arena.deinit();
    }
};

/// Parses a `wham/profiles/me` body. Caller owns the result, which copies
/// every string, so `body` may be freed right after.
pub fn parseProfile(gpa: Allocator, body: []const u8) ParseError!ProfileOwned {
    if (body.len > max_profile_bytes) return error.InvalidResponse;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    if (root != .object) return error.InvalidResponse;
    const stats_value = root.object.get("stats") orelse return error.InvalidResponse;
    if (stats_value != .object) return error.InvalidResponse;
    const stats = stats_value.object;

    var profile: Profile = .{
        .lifetime_tokens = try count(stats.get("lifetime_tokens")),
        .peak_day_tokens = try count(stats.get("peak_daily_tokens")),
        .longest_turn_seconds = try count(stats.get("longest_running_turn_sec")),
        .streak_days = try count(stats.get("current_streak_days")),
        .best_streak_days = try count(stats.get("longest_streak_days")),
        .chats = try count(stats.get("total_threads")),
        .fast_mode_percent = try share(stats.get("fast_mode_usage_percentage")),
        .reasoning = try optionalText(stats.get("most_used_reasoning_effort")),
        .reasoning_percent = try share(stats.get("most_used_reasoning_effort_percentage")),
    };
    if (root.object.get("profile")) |who| if (who == .object) {
        profile.name = try optionalText(who.object.get("display_name")) orelse try optionalText(who.object.get("username"));
    };
    if (root.object.get("metadata")) |meta| if (meta == .object) {
        if (meta.object.get("stats_as_of")) |as_of| if (as_of == .string) {
            profile.as_of_day = dayOf(as_of.string);
        };
    };

    if (stats.get("daily_usage_buckets")) |buckets| switch (buckets) {
        .null => {},
        .array => |items| {
            var days: std.ArrayList(Day) = .empty;
            for (items.items) |item| {
                if (item != .object) return error.InvalidResponse;
                const date = item.object.get("start_date") orelse return error.InvalidResponse;
                if (date != .string) return error.InvalidResponse;
                const day = dayOf(date.string) orelse return error.InvalidResponse;
                const tokens = try count(item.object.get("tokens")) orelse 0;
                try days.append(alloc, .{ .day = day, .tokens = tokens });
            }
            std.mem.sort(Day, days.items, {}, struct {
                fn lessThan(_: void, a: Day, b: Day) bool {
                    return a.day < b.day;
                }
            }.lessThan);
            profile.days = days.items[days.items.len -| max_days..];
        },
        else => return error.InvalidResponse,
    };

    if (!profile.valid()) return error.InvalidResponse;
    return .{ .arena = arena, .profile = profile };
}

/// A breakdown and the arena that owns its strings.
pub const BreakdownOwned = struct {
    arena: std.heap.ArenaAllocator,
    breakdown: Breakdown,

    pub fn deinit(self: *BreakdownOwned) void {
        self.arena.deinit();
    }
};

/// Parses a `daily-token-usage-breakdown` body, keeping the newest days.
/// Caller owns the result, which copies every string.
pub fn parseBreakdown(gpa: Allocator, body: []const u8) ParseError!BreakdownOwned {
    if (body.len > max_profile_bytes) return error.InvalidResponse;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    if (root != .object) return error.InvalidResponse;
    const data = root.object.get("data") orelse return error.InvalidResponse;
    if (data != .array) return error.InvalidResponse;

    var days: std.ArrayList(BreakdownDay) = .empty;
    for (data.array.items) |item| {
        if (item != .object) return error.InvalidResponse;
        const o = item.object;
        const date = o.get("date") orelse return error.InvalidResponse;
        if (date != .string) return error.InvalidResponse;
        var day: BreakdownDay = .{ .day = dayOf(date.string) orelse return error.InvalidResponse };

        if (o.get("models")) |list| switch (list) {
            .null => {},
            .array => |entries| {
                var models: std.ArrayList(ModelValue) = .empty;
                for (entries.items) |entry| {
                    if (entry != .object) return error.InvalidResponse;
                    const model = try optionalText(entry.object.get("model")) orelse continue;
                    const speed = try optionalText(entry.object.get("speed")) orelse "standard";
                    const value = try number(entry.object.get("credits") orelse continue);
                    if (value == 0 or models.items.len == max_shares) continue;
                    try models.append(alloc, .{ .model = model, .speed = speed, .value = value });
                }
                day.models = models.items;
            },
            else => return error.InvalidResponse,
        };

        if (o.get("product_surface_usage_values")) |values| switch (values) {
            .null => {},
            .object => |map| {
                var surfaces: std.ArrayList(SurfaceValue) = .empty;
                var it = map.iterator();
                while (it.next()) |entry| {
                    const value = try number(entry.value_ptr.*);
                    if (value == 0 or !shortText(entry.key_ptr.*) or surfaces.items.len == max_shares) continue;
                    try surfaces.append(alloc, .{ .surface = entry.key_ptr.*, .value = value });
                }
                day.surfaces = surfaces.items;
            },
            else => return error.InvalidResponse,
        };
        try days.append(alloc, day);
    }
    std.mem.sort(BreakdownDay, days.items, {}, struct {
        fn lessThan(_: void, a: BreakdownDay, b: BreakdownDay) bool {
            return a.day < b.day;
        }
    }.lessThan);
    const breakdown: Breakdown = .{ .days = days.items[days.items.len -| max_days..] };
    if (!breakdown.valid()) return error.InvalidResponse;
    return .{ .arena = arena, .breakdown = breakdown };
}

/// The profile grows with daily buckets; a year is about 20 KB.
const max_profile_bytes: usize = 1024 * 1024;

/// `YYYY-MM-DD` as days since the Unix epoch.
fn dayOf(date: []const u8) ?i64 {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return null;
    const y = std.fmt.parseInt(i64, date[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, date[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, date[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    return report.civilDay(y, m, d);
}

/// A whole non-negative count, or null when absent.
fn count(value: ?std.json.Value) ParseError!?u64 {
    const v = value orelse return null;
    const f: f64 = switch (v) {
        .null => return null,
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return error.InvalidResponse,
    };
    if (!std.math.isFinite(f) or f < 0 or f > 1e17) return error.InvalidResponse;
    return @intFromFloat(f);
}

/// A percentage from 0 to 100, or null when absent.
fn share(value: ?std.json.Value) ParseError!?f64 {
    const v = value orelse return null;
    if (v == .null) return null;
    const f = try number(v);
    if (f > 100) return error.InvalidResponse;
    return f;
}

/// Short text, or null when absent, empty or too long to show.
fn optionalText(value: ?std.json.Value) ParseError!?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| if (s.len == 0 or s.len > max_text_bytes) null else s,
        else => error.InvalidResponse,
    };
}

fn text(value: std.json.Value) ParseError![]const u8 {
    if (value != .string or value.string.len == 0 or value.string.len > max_text_bytes) return error.InvalidResponse;
    return value.string;
}

fn flag(value: ?std.json.Value) ParseError!bool {
    const v = value orelse return false;
    return switch (v) {
        .null => false,
        .bool => |b| b,
        else => error.InvalidResponse,
    };
}

/// A finite, non-negative number below a trillion.
fn number(value: std.json.Value) ParseError!f64 {
    const f: f64 = switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return error.InvalidResponse,
    };
    if (!std.math.isFinite(f) or f < 0 or f > 1e12) return error.InvalidResponse;
    return f;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const now: i64 = 1_791_752_000_000;

test "a business plan without limit windows and with unlimited credits" {
    // The live response for a ChatGPT business plan, trimmed of account ids.
    const body =
        \\{"plan_type":"business","rate_limit":null,"code_review_rate_limit":null,
        \\ "additional_rate_limits":null,
        \\ "model_usage":{"gpt-6-astra":{"available":true,"available_at":null,"credits_would_enable":false}},
        \\ "credits":{"has_credits":true,"unlimited":true,"overage_limit_reached":false,"balance":null,
        \\  "approx_local_messages":null,"approx_cloud_messages":null},
        \\ "spend_control":{"reached":false,"individual_limit":null},
        \\ "rate_limit_reached_type":null,"promo":null,
        \\ "rate_limit_reset_credits":{"available_count":0,"applicable_available_count":0}}
    ;
    var owned = try parse(testing.allocator, body, now);
    defer owned.deinit();
    const u = owned.usage;
    try testing.expectEqualStrings("business", u.plan);
    try testing.expectEqual(@as(usize, 0), u.limits.len);
    try testing.expect(!u.hasWindows());
    try testing.expect(u.credits.?.unlimited and u.credits.?.has_credits);
    try testing.expect(u.credits.?.balance == null);
    try testing.expect(!u.spend_limit_reached);
}

test "a plan with 5-hour and weekly windows, code review and an extra limit" {
    const body =
        \\{"plan_type":"pro",
        \\ "rate_limit":{"allowed":true,"limit_reached":false,
        \\  "primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":7980,"reset_at":1791759980},
        \\  "secondary_window":{"used_percent":18.5,"limit_window_seconds":604800,"reset_after_seconds":300000,"reset_at":null}},
        \\ "code_review_rate_limit":{"allowed":true,"limit_reached":true,
        \\  "primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":60,"reset_at":1791752060},
        \\  "secondary_window":null},
        \\ "additional_rate_limits":[{"limit_name":"cloud tasks","metered_feature":"cloud","rate_limit":{"allowed":true,"limit_reached":false,
        \\  "primary_window":{"used_percent":3,"limit_window_seconds":86400,"reset_after_seconds":100,"reset_at":1791752100}}}],
        \\ "credits":{"has_credits":true,"unlimited":false,"balance":"12.40"},
        \\ "spend_control":{"reached":true,"individual_limit":null}}
    ;
    var owned = try parse(testing.allocator, body, now);
    defer owned.deinit();
    const u = owned.usage;
    try testing.expectEqual(@as(usize, 3), u.limits.len);
    try testing.expectEqualStrings("codex", u.limits[0].name);
    try testing.expectEqual(@as(f64, 42), u.limits[0].primary.?.used_percent);
    try testing.expectEqual(@as(i64, 18000), u.limits[0].primary.?.window_seconds);
    try testing.expectEqual(@as(?i64, 1_791_759_980_000), u.limits[0].primary.?.resets_at_ms);
    // No reset_at: computed from reset_after_seconds.
    try testing.expectEqual(@as(?i64, now + 300_000_000), u.limits[0].secondary.?.resets_at_ms);
    try testing.expectEqualStrings("code review", u.limits[1].name);
    try testing.expect(u.limits[1].reached);
    try testing.expectEqualStrings("cloud tasks", u.limits[2].name);
    try testing.expectEqualStrings("12.40", u.credits.?.balance.?);
    try testing.expect(u.spend_limit_reached and u.hasWindows());

    // A deep copy survives the original.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const copy = try u.clone(arena.allocator());
    try testing.expectEqualStrings("cloud tasks", copy.limits[2].name);
}

test "the profile gives lifetime stats and daily tokens" {
    // The live shape for a business account, trimmed.
    const body =
        \\{"profile":{"username":"samdoe12345","display_name":"samdoe","profile_picture_url":"https://x"},
        \\ "stats":{"lifetime_tokens":315686778511,"peak_daily_tokens":11594630891,"current_streak_days":132,
        \\  "longest_streak_days":132,"total_threads":11374,"longest_running_turn_sec":110473,
        \\  "fast_mode_usage_percentage":66.54220886817048,"total_skills_used":81157,"unique_skills_used":178,
        \\  "most_used_reasoning_effort":"xhigh","most_used_reasoning_effort_percentage":85.06233504754985,
        \\  "daily_usage_buckets":[{"start_date":"2026-10-11","tokens":39877412},{"start_date":"2026-10-10","tokens":52293426},
        \\   {"start_date":"2026-10-01","tokens":1000},{"start_date":"2026-09-30","tokens":7}],
        \\  "cumulative_daily_usage_buckets":[],"weekly_usage_buckets":[],
        \\  "top_invocations":[{"type":"plugin","plugin_id":"superpowers@x","plugin_name":"superpowers","skill_id":null,"skill_name":null,"usage_count":11670},
        \\   {"type":"skill","plugin_id":null,"plugin_name":null,"skill_id":"bd04","skill_name":"fx-conventions","usage_count":11395},
        \\   {"type":"agent","usage_count":5}],
        \\  "workspace_rank":null,"workspace_total_user_count":null},
        \\ "metadata":{"stats_as_of":"2026-10-11","generated_at":"2026-10-11T21:37:36Z","stats_error":null}}
    ;
    var owned = try parseProfile(testing.allocator, body);
    defer owned.deinit();
    const p = owned.profile;
    try testing.expectEqualStrings("samdoe", p.name.?);
    try testing.expectEqual(@as(?u64, 315686778511), p.lifetime_tokens);
    try testing.expectEqual(@as(?u64, 110473), p.longest_turn_seconds);
    try testing.expectEqual(@as(?u64, 11374), p.chats);
    try testing.expectEqualStrings("xhigh", p.reasoning.?);
    try testing.expectEqual(@as(?i64, 20737), p.as_of_day);
    // Sorted oldest first, whatever order ChatGPT sends.
    try testing.expectEqual(@as(i64, 20726), p.days[0].day);
    const today: i64 = 20737;
    try testing.expectEqual(@as(?u64, 39877412), p.tokensBetween(today, today));
    try testing.expectEqual(@as(?u64, 39877412 + 52293426), p.tokensBetween(today - 6, today));
    try testing.expectEqual(@as(?u64, 39877412 + 52293426 + 1000), p.tokensBetween(20727, today));
    // A day past ChatGPT's stats is unknown, not zero.
    try testing.expectEqual(@as(?u64, null), p.tokensBetween(today + 1, today + 1));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const copy = try p.clone(arena.allocator());
    try testing.expectEqualStrings("samdoe", copy.name.?);
    try testing.expectEqual(@as(i64, 11016), dayOf("2000-02-29").?);
}

test "a profile keeps only the most recent daily buckets" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"stats\":{\"daily_usage_buckets\":[");
    for (0..200) |i| {
        if (i > 0) try body.append(testing.allocator, ',');
        const day: i64 = 20560 + @as(i64, @intCast(i));
        const epoch: std.time.epoch.EpochDay = .{ .day = @intCast(day) };
        const year_day = epoch.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        try body.print(testing.allocator, "{{\"start_date\":\"{d}-{d:0>2}-{d:0>2}\",\"tokens\":1}}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 });
    }
    try body.appendSlice(testing.allocator, "]}}");
    var owned = try parseProfile(testing.allocator, body.items);
    defer owned.deinit();
    try testing.expectEqual(max_days, owned.profile.days.len);
    try testing.expectEqual(@as(i64, 20560 + 199), owned.profile.days[max_days - 1].day);
    try testing.expectEqual(@as(i64, 20560 + 199 - max_days + 1), owned.profile.days[0].day);
}

test "a malformed profile is rejected" {
    const bad = [_][]const u8{
        "not json",
        "{}",
        "{\"stats\":[]}",
        "{\"stats\":{\"lifetime_tokens\":-1}}",
        "{\"stats\":{\"lifetime_tokens\":\"many\"}}",
        "{\"stats\":{\"fast_mode_usage_percentage\":140}}",
        "{\"stats\":{\"daily_usage_buckets\":[{\"start_date\":\"Oct 11\",\"tokens\":1}]}}",
    };
    for (bad) |body| try testing.expectError(error.InvalidResponse, parseProfile(testing.allocator, body));
}

test "the breakdown gives each model's and surface's share of a period" {
    // The live shape, trimmed: ChatGPT sends every surface, most of them 0.
    const body =
        \\{"data":[
        \\ {"date":"2026-10-11","product_surface_usage_values":{"cli":7.0,"desktop_app":10.0,"vscode":0.0,"work_web":1.0,"web":2.0},
        \\  "models":[{"model":"gpt-6.1-sol","speed":"fast","credits":10.0},{"model":"gpt-6.1-sol","speed":"standard","credits":7.0},
        \\   {"model":"gpt-6-astra","speed":"fast","credits":0.0},{"model":"gpt-6-luna","speed":"standard","credits":3.0}]},
        \\ {"date":"2026-10-10","product_surface_usage_values":{"cli":20.0},
        \\  "models":[{"model":"gpt-6-astra","speed":"fast","credits":20.0}]}],
        \\ "units":"percent","group_by":"day"}
    ;
    var owned = try parseBreakdown(testing.allocator, body);
    defer owned.deinit();
    const b = owned.breakdown;
    // Oldest first; zero entries are dropped.
    try testing.expectEqual(@as(i64, 20736), b.days[0].day);
    try testing.expectEqual(@as(usize, 3), b.days[1].models.len);
    try testing.expectEqual(@as(usize, 4), b.days[1].surfaces.len);

    var buf: [max_shares]Share = undefined;
    const today = b.modelShares(20737, 20737, &buf);
    try testing.expectEqual(@as(usize, 3), today.len);
    try testing.expectEqualStrings("gpt-6.1-sol", today[0].name);
    try testing.expectEqualStrings("fast", today[0].speed);
    try testing.expectApproxEqAbs(@as(f64, 50), today[0].percent, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 35), today[1].percent, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 15), today[2].percent, 1e-9);

    const both = b.modelShares(20736, 20737, &buf);
    try testing.expectEqualStrings("gpt-6-astra", both[0].name);
    try testing.expectApproxEqAbs(@as(f64, 50), both[0].percent, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 7.5), both[3].percent, 1e-9);
    try testing.expectEqual(@as(usize, 0), b.modelShares(20738, 20740, &buf).len);

    // Surfaces get readable names, and work and personal web add up.
    const surfaces = b.surfaceShares(20737, 20737, &buf);
    try testing.expectEqual(@as(usize, 3), surfaces.len);
    try testing.expectEqualStrings("desktop app", surfaces[0].name);
    try testing.expectEqualStrings("cli", surfaces[1].name);
    try testing.expectEqualStrings("web", surfaces[2].name);
    try testing.expectApproxEqAbs(@as(f64, 15), surfaces[2].percent, 1e-9);

    var path_buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "/backend-api/wham/usage/daily-token-usage-breakdown?start_date=2026-10-01",
        try breakdownPath(&path_buf, 20727),
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const copy = try b.clone(arena.allocator());
    try testing.expectEqualStrings("gpt-6-luna", copy.days[1].models[2].model);
}

test "a malformed breakdown is rejected" {
    const bad = [_][]const u8{
        "not json",
        "{}",
        "{\"data\":{}}",
        "{\"data\":[{\"date\":\"Oct 11\"}]}",
        "{\"data\":[{\"date\":\"2026-10-11\",\"models\":{}}]}",
        "{\"data\":[{\"date\":\"2026-10-11\",\"models\":[{\"model\":\"m\",\"credits\":-1}]}]}",
        "{\"data\":[{\"date\":\"2026-10-11\",\"product_surface_usage_values\":[]}]}",
    };
    for (bad) |body| try testing.expectError(error.InvalidResponse, parseBreakdown(testing.allocator, body));
}

test "malformed usage is rejected instead of shown" {
    const bad = [_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"plan_type\":\"\"}",
        "{\"plan_type\":7}",
        "{\"plan_type\":\"plus\",\"rate_limit\":[]}",
        "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"used_percent\":-1,\"limit_window_seconds\":1}}}",
        "{\"plan_type\":\"plus\",\"rate_limit\":{\"primary_window\":{\"limit_window_seconds\":1}}}",
        "{\"plan_type\":\"plus\",\"credits\":{\"has_credits\":\"yes\"}}",
    };
    for (bad) |body| try testing.expectError(error.InvalidResponse, parse(testing.allocator, body, now));
}
