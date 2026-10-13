//! AI Gateway usage requests and responses. Pure: builds request paths and
//! parses response bodies; the caller owns all I/O.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Largest response body accepted from either endpoint.
pub const max_body_bytes: usize = 1024 * 1024;
/// Most model rows kept from one response.
pub const max_models: usize = 256;
const max_model_name_bytes: usize = 256;

/// Whose spend a report covers, chosen by how fx is signed in.
pub const Scope = enum {
    /// fx login: the signed-in member, fx login and user-attributed keys both
    /// (`metered_scope=user` with the team header).
    member,
    /// AI Gateway API key: that key only (`api_key_id=self`).
    api_key,
    /// A ChatGPT plan through Codex: its limits, not AI Gateway reports.
    codex,
    /// A Grok plan: its allowance and credits, not AI Gateway reports.
    grok,

    /// Whether usage comes from AI Gateway reports rather than a provider's
    /// plan.
    pub fn readsReports(self: Scope) bool {
        return self == .member or self == .api_key;
    }
};

pub const Totals = struct {
    request_count: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    total_cost: f64 = 0,
    /// Requests that hit the prompt cache (`cache_hit_pct` times requests).
    /// Counts add exactly across reports, unlike percentages.
    cache_hit_requests: f64 = 0,
    /// Requests that failed: `http_failure_pct + malformed_response_pct`
    /// times requests.
    failed_requests: f64 = 0,
    /// `p90_ttft_ms` and `p90_tps` times the requests they describe. A p90
    /// cannot be combined exactly, so a merged value is the request-weighted
    /// mean of its parts (exact for a single report).
    ttft_weighted: f64 = 0,
    ttft_requests: u64 = 0,
    tps_weighted: f64 = 0,
    tps_requests: u64 = 0,

    pub fn totalTokens(self: Totals) u64 {
        return self.input_tokens +| self.output_tokens +| self.cache_read_tokens +| self.cache_write_tokens;
    }

    pub fn add(self: *Totals, other: Totals) void {
        self.request_count +|= other.request_count;
        self.input_tokens +|= other.input_tokens;
        self.output_tokens +|= other.output_tokens;
        self.cache_read_tokens +|= other.cache_read_tokens;
        self.cache_write_tokens +|= other.cache_write_tokens;
        self.reasoning_tokens +|= other.reasoning_tokens;
        self.total_cost += other.total_cost;
        self.cache_hit_requests += other.cache_hit_requests;
        self.failed_requests += other.failed_requests;
        self.ttft_weighted += other.ttft_weighted;
        self.ttft_requests +|= other.ttft_requests;
        self.tps_weighted += other.tps_weighted;
        self.tps_requests +|= other.tps_requests;
    }

    /// Percent of requests that hit the cache, or null without requests.
    pub fn cacheHitPct(self: Totals) ?f64 {
        return percentOf(self.cache_hit_requests, self.request_count);
    }

    /// Percent of requests that failed, or null without requests.
    pub fn errorPct(self: Totals) ?f64 {
        return percentOf(self.failed_requests, self.request_count);
    }

    pub fn p90TtftMs(self: Totals) ?f64 {
        if (self.ttft_requests == 0) return null;
        return self.ttft_weighted / @as(f64, @floatFromInt(self.ttft_requests));
    }

    pub fn p90Tps(self: Totals) ?f64 {
        if (self.tps_requests == 0) return null;
        return self.tps_weighted / @as(f64, @floatFromInt(self.tps_requests));
    }

    /// Whether every number is finite and not negative.
    pub fn valid(self: Totals) bool {
        inline for (.{ self.total_cost, self.cache_hit_requests, self.failed_requests, self.ttft_weighted, self.tps_weighted }) |v| {
            if (!std.math.isFinite(v) or v < 0) return false;
        }
        return true;
    }
};

fn percentOf(part: f64, whole: u64) ?f64 {
    if (whole == 0) return null;
    return @min(part / @as(f64, @floatFromInt(whole)) * 100, 100);
}

pub const ModelRow = struct {
    model: []const u8,
    totals: Totals,
};

/// Rows owned by one allocation arena.
pub const Rows = struct {
    arena: std.heap.ArenaAllocator,
    models: []const ModelRow,

    pub fn deinit(self: *Rows) void {
        self.arena.deinit();
    }
};

pub const RefreshPeriod = enum { daily, weekly, monthly, none };

pub const Budget = struct {
    limit: f64,
    spent: f64,
    period: RefreshPeriod,
};

/// Days since the Unix epoch, in UTC.
/// Days since the Unix epoch for a civil date, from Howard Hinnant's
/// days-from-civil algorithm with March as the first month.
pub fn civilDay(y: i64, m: i64, d: i64) i64 {
    const year = if (m <= 2) y - 1 else y;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const day_of_year = @divFloor(153 * @mod(m + 9, 12) + 2, 5) + d - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

pub fn utcDay(ms: i64) i64 {
    return @divFloor(ms, std.time.ms_per_day);
}

pub const MonthDay = struct {
    year: u16,
    /// 1 through 12.
    month: u4,
    /// 1 through 31.
    day: u5,
};

pub fn monthDay(day: i64) MonthDay {
    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(@max(day, 0)) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{ .year = year_day.year, .month = month_day.month.numeric(), .day = @as(u5, month_day.day_index) + 1 };
}

/// The first UTC day of the calendar month that holds `day`.
pub fn monthStart(day: i64) i64 {
    return day - (monthDay(day).day - 1);
}

/// The first UTC day of the next calendar month.
pub fn nextMonthStart(day: i64) i64 {
    var d = monthStart(day) + 27;
    while (monthDay(d).day != 1) d += 1;
    return d;
}

/// The UTC day a budget next resets, when the budget says.
pub fn budgetResetDay(period: RefreshPeriod, today: i64) ?i64 {
    return switch (period) {
        .daily => today + 1,
        .monthly => nextMonthStart(today),
        .weekly, .none => null,
    };
}

/// `YYYY-MM-DD` for a UTC day number.
pub fn formatDay(buf: *[10]u8, day: i64) []const u8 {
    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(@max(day, 0)) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.mem.print(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    }) catch unreachable;
}

/// The `/v1/report` path for per-model usage over the UTC days `first..last`.
pub fn reportPath(buf: []u8, scope: Scope, first: i64, last: i64) ![]const u8 {
    var a: [10]u8 = undefined;
    var b: [10]u8 = undefined;
    const filter = switch (scope) {
        .member => "metered_scope=user",
        .api_key => "api_key_id=self",
        .codex, .grok => return error.NotAiGateway,
    };
    return std.mem.print(buf, "/v1/report?start_date={s}&end_date={s}&group_by=model&{s}", .{
        formatDay(&a, first),
        formatDay(&b, last),
        filter,
    });
}

/// The `usage-report` path that carries the member's budget. One day keeps
/// the query small; the budget does not depend on the range.
pub fn budgetPath(buf: []u8, team_id: []const u8, day: i64) ![]const u8 {
    var d: [10]u8 = undefined;
    const date = formatDay(&d, day);
    return std.mem.print(buf, "/ai-gateway/usage-report?teamId={s}&scope=user&start={s}&end={s}", .{ team_id, date, date });
}

pub const ParseError = error{ InvalidResponse, OutOfMemory };

/// Parses a `/v1/report?group_by=model` body. Rows for the same model are
/// summed; rows are sorted by cost, highest first. Caller owns the result,
/// which copies every string, so `body` may be freed right after.
pub fn parseModelRows(gpa: Allocator, body: []const u8) ParseError!Rows {
    if (body.len > max_body_bytes) return error.InvalidResponse;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    if (root != .object) return error.InvalidResponse;
    const results = root.object.get("results") orelse return error.InvalidResponse;
    if (results != .array) return error.InvalidResponse;

    var rows: std.ArrayList(ModelRow) = .empty;
    for (results.array.items) |item| {
        if (item != .object) return error.InvalidResponse;
        const model_value = item.object.get("model") orelse return error.InvalidResponse;
        if (model_value != .string) return error.InvalidResponse;
        const model = model_value.string;
        if (model.len == 0 or model.len > max_model_name_bytes) return error.InvalidResponse;
        const requests = try count(item.object.get("request_count"));
        const requests_f: f64 = @floatFromInt(requests);
        const hit_pct = try optionalNumber(item.object.get("cache_hit_pct"));
        const failure_pct = (try optionalNumber(item.object.get("http_failure_pct")) orelse 0) +
            (try optionalNumber(item.object.get("malformed_response_pct")) orelse 0);
        const ttft = try optionalNumber(item.object.get("p90_ttft_ms"));
        const tps = try optionalNumber(item.object.get("p90_tps"));
        const totals: Totals = .{
            .request_count = requests,
            .input_tokens = try count(item.object.get("input_tokens")),
            .output_tokens = try count(item.object.get("output_tokens")),
            .cache_read_tokens = try count(item.object.get("cached_input_tokens")),
            .cache_write_tokens = try count(item.object.get("cache_creation_input_tokens")),
            .reasoning_tokens = try count(item.object.get("reasoning_tokens")),
            .total_cost = try money(item.object.get("total_cost") orelse return error.InvalidResponse),
            .cache_hit_requests = (hit_pct orelse 0) / 100 * requests_f,
            .failed_requests = failure_pct / 100 * requests_f,
            .ttft_weighted = if (ttft) |v| v * requests_f else 0,
            .ttft_requests = if (ttft != null) requests else 0,
            .tps_weighted = if (tps) |v| v * requests_f else 0,
            .tps_requests = if (tps != null) requests else 0,
        };
        // Each number was finite, but a product or a sum can still overflow.
        if (!totals.valid()) return error.InvalidResponse;
        if (findRow(rows.items, model)) |row| {
            row.totals.add(totals);
            if (!row.totals.valid()) return error.InvalidResponse;
            continue;
        }
        if (rows.items.len == max_models) return error.InvalidResponse;
        try rows.append(alloc, .{ .model = model, .totals = totals });
    }
    std.mem.sort(ModelRow, rows.items, {}, costDescending);
    return .{ .arena = arena, .models = rows.items };
}

/// Parses the budget out of a `usage-report` body: `users[0].budget`, or null
/// when the member has no budget.
pub fn parseBudget(gpa: Allocator, body: []const u8) ParseError!?Budget {
    if (body.len > max_body_bytes) return error.InvalidResponse;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    if (root != .object) return error.InvalidResponse;
    const users = root.object.get("users") orelse return null;
    if (users != .array) return error.InvalidResponse;
    if (users.array.items.len == 0) return null;
    const user = users.array.items[0];
    if (user != .object) return error.InvalidResponse;
    const budget = user.object.get("budget") orelse return null;
    if (budget == .null) return null;
    if (budget != .object) return error.InvalidResponse;
    const period_value = budget.object.get("refreshPeriod") orelse return error.InvalidResponse;
    if (period_value != .string) return error.InvalidResponse;
    return .{
        .limit = try money(budget.object.get("limitAmount") orelse return error.InvalidResponse),
        .spent = try money(budget.object.get("currentSpend") orelse return error.InvalidResponse),
        .period = std.meta.stringToEnum(RefreshPeriod, period_value.string) orelse return error.InvalidResponse,
    };
}

fn findRow(rows: []ModelRow, model: []const u8) ?*ModelRow {
    for (rows) |*row| if (std.mem.eql(u8, row.model, model)) return row;
    return null;
}

fn costDescending(_: void, a: ModelRow, b: ModelRow) bool {
    if (a.totals.total_cost != b.totals.total_cost) return a.totals.total_cost > b.totals.total_cost;
    return std.mem.lessThan(u8, a.model, b.model);
}

fn count(value: ?std.json.Value) ParseError!u64 {
    const v = value orelse return 0;
    return switch (v) {
        .null => 0,
        .integer => |i| if (i < 0) error.InvalidResponse else @intCast(i),
        .float => |f| if (!std.math.isFinite(f) or f < 0 or f > 1e18) error.InvalidResponse else @intFromFloat(f),
        else => error.InvalidResponse,
    };
}

/// A non-negative finite number, or null when absent or `null`.
fn optionalNumber(value: ?std.json.Value) ParseError!?f64 {
    const v = value orelse return null;
    if (v == .null) return null;
    return try money(v);
}

fn money(value: std.json.Value) ParseError!f64 {
    const f: f64 = switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return error.InvalidResponse,
    };
    if (!std.math.isFinite(f) or f < 0) return error.InvalidResponse;
    return f;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "paths pick the filter for how fx is signed in" {
    var buf: [256]u8 = undefined;
    const day = utcDay(1_791_676_800_000); // 2026-10-11
    try testing.expectEqualStrings(
        "/v1/report?start_date=2026-10-05&end_date=2026-10-10&group_by=model&metered_scope=user",
        try reportPath(&buf, .member, day - 6, day - 1),
    );
    try testing.expectEqualStrings(
        "/v1/report?start_date=2026-10-11&end_date=2026-10-11&group_by=model&api_key_id=self",
        try reportPath(&buf, .api_key, day, day),
    );
    try testing.expectEqualStrings(
        "/ai-gateway/usage-report?teamId=team_1&scope=user&start=2026-10-11&end=2026-10-11",
        try budgetPath(&buf, "team_1", day),
    );
    try testing.expectError(error.NotAiGateway, reportPath(&buf, .codex, day, day));
}

test "model rows parse, merge duplicates and sort by cost" {
    const body =
        \\{"results":[
        \\ {"model":"openai/gpt-5.6-luna","request_count":1484,"input_tokens":10,"output_tokens":20,
        \\  "cached_input_tokens":3,"cache_creation_input_tokens":4,"reasoning_tokens":5,"total_cost":1.65,
        \\  "market_cost":1.65,"cache_hit_pct":12.5,"p90_ttft_ms":null},
        \\ {"model":"anthropic/claude-opus-5.5","request_count":2168,"total_cost":397.44},
        \\ {"model":"openai/gpt-5.6-luna","request_count":1,"total_cost":0.35}
        \\]}
    ;
    var rows = try parseModelRows(testing.allocator, body);
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 2), rows.models.len);
    try testing.expectEqualStrings("anthropic/claude-opus-5.5", rows.models[0].model);
    const luna = rows.models[1].totals;
    try testing.expectEqual(@as(u64, 1485), luna.request_count);
    try testing.expectApproxEqAbs(@as(f64, 2.0), luna.total_cost, 1e-9);
    try testing.expectEqual(@as(u64, 37), luna.totalTokens());
    try testing.expectEqual(@as(u64, 5), luna.reasoning_tokens);
    // 12.5% of 1484 requests hit the cache; the 1-request row reported none.
    try testing.expectApproxEqAbs(@as(f64, 12.5 * 1484.0 / 1485.0), luna.cacheHitPct().?, 1e-9);
    try testing.expect(luna.p90TtftMs() == null);
}

test "perf percentages merge by request count; p90s by request weight" {
    const body =
        \\{"results":[
        \\ {"model":"m","request_count":300,"total_cost":3,"cache_hit_pct":90,"http_failure_pct":1,
        \\  "malformed_response_pct":1,"p90_ttft_ms":2000,"p90_tps":50,"rate_limit_pct":7},
        \\ {"model":"m","request_count":100,"total_cost":1,"cache_hit_pct":50,"http_failure_pct":0,
        \\  "malformed_response_pct":null,"p90_ttft_ms":1000,"p90_tps":70}
        \\]}
    ;
    var rows = try parseModelRows(testing.allocator, body);
    defer rows.deinit();
    const t = rows.models[0].totals;
    try testing.expectApproxEqAbs(@as(f64, 80), t.cacheHitPct().?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5), t.errorPct().?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1750), t.p90TtftMs().?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 55), t.p90Tps().?, 1e-9);
    try testing.expect((Totals{}).cacheHitPct() == null);
    try testing.expectError(error.InvalidResponse, parseModelRows(testing.allocator, "{\"results\":[{\"model\":\"m\",\"total_cost\":1,\"cache_hit_pct\":-1}]}"));
}

test "months start on the 1st and budgets reset on the next 1st" {
    const oct_11 = utcDay(1_791_676_800_000); // 2026-10-11
    const oct_1 = monthStart(oct_11);
    try testing.expectEqual(MonthDay{ .year = 2026, .month = 10, .day = 1 }, monthDay(oct_1));
    try testing.expectEqual(oct_1, monthStart(oct_1));
    try testing.expectEqual(MonthDay{ .year = 2026, .month = 11, .day = 1 }, monthDay(nextMonthStart(oct_11)));
    try testing.expectEqual(MonthDay{ .year = 2027, .month = 1, .day = 1 }, monthDay(nextMonthStart(oct_11 + 60)));
    try testing.expectEqual(MonthDay{ .year = 2028, .month = 3, .day = 1 }, monthDay(nextMonthStart(utcDay(1_833_062_400_000))));
    try testing.expectEqual(nextMonthStart(oct_11), budgetResetDay(.monthly, oct_11).?);
    try testing.expectEqual(oct_11 + 1, budgetResetDay(.daily, oct_11).?);
    try testing.expect(budgetResetDay(.weekly, oct_11) == null);
}

test "malformed reports are rejected instead of shown" {
    const bad = [_][]const u8{
        "not json",
        "{}",
        "{\"results\":{}}",
        "{\"results\":[{\"request_count\":1,\"total_cost\":1}]}",
        "{\"results\":[{\"model\":\"m\",\"request_count\":1}]}",
        "{\"results\":[{\"model\":\"m\",\"total_cost\":-1}]}",
        "{\"results\":[{\"model\":\"m\",\"total_cost\":1,\"input_tokens\":-3}]}",
        "{\"results\":[{\"model\":\"\",\"total_cost\":1}]}",
        // Finite numbers whose product or sum is not: the cache would refuse them.
        "{\"results\":[{\"model\":\"m\",\"request_count\":100000000000000000,\"total_cost\":1,\"p90_ttft_ms\":1e300}]}",
        "{\"results\":[{\"model\":\"m\",\"total_cost\":1.7e308},{\"model\":\"m\",\"total_cost\":1.7e308}]}",
    };
    for (bad) |body| try testing.expectError(error.InvalidResponse, parseModelRows(testing.allocator, body));
    var empty = try parseModelRows(testing.allocator, "{\"results\":[]}");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.models.len);
}

test "the budget comes from the member's usage-report entry" {
    const body =
        \\{"scope":"user","users":[{"userId":"usr_1","attribution":"user","keyCount":3,
        \\ "budget":{"limitAmount":31600,"currentSpend":6596.55,"refreshPeriod":"monthly"}}]}
    ;
    const budget = (try parseBudget(testing.allocator, body)).?;
    try testing.expectApproxEqAbs(@as(f64, 31600), budget.limit, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 6596.55), budget.spent, 1e-9);
    try testing.expectEqual(RefreshPeriod.monthly, budget.period);
    try testing.expect((try parseBudget(testing.allocator, "{\"users\":[{\"budget\":null}]}")) == null);
    try testing.expect((try parseBudget(testing.allocator, "{\"users\":[]}")) == null);
    try testing.expectError(
        error.InvalidResponse,
        parseBudget(testing.allocator, "{\"users\":[{\"budget\":{\"limitAmount\":1,\"currentSpend\":1,\"refreshPeriod\":\"hourly\"}}]}"),
    );
}
