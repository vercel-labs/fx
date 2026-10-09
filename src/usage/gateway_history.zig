//! Usage history from AI Gateway reports: the query for each period, the
//! mapping of a report's rows into fx's token counts, the snapshot that
//! keeps the last answer on disk, and when to ask again.
//!
//! AI Gateway counts input without cache reads and writes, and output
//! without reasoning. fx counts both inside, so the mapping adds them back.
//! Pure: no I/O.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A history period: whole UTC days ending today.
pub const Period = enum {
    today,
    days_7,
    days_30,

    pub const all = [_]Period{ .today, .days_7, .days_30 };

    pub fn days(period: Period) u8 {
        return switch (period) {
            .today => 1,
            .days_7 => 7,
            .days_30 => 30,
        };
    }

    fn key(period: Period) []const u8 {
        return switch (period) {
            .today => "today",
            .days_7 => "7d",
            .days_30 => "30d",
        };
    }
};

/// The UTC day number of `ms`, counted from 1970-01-01.
pub fn utcDay(ms: i64) i64 {
    return @divFloor(ms, std.time.ms_per_day);
}

/// The first UTC day `period` covers when `today` is the current one.
pub fn firstDay(period: Period, today: i64) i64 {
    return today - (period.days() - 1);
}

/// `YYYY-MM-DD` for a UTC day number on or after 1970-01-01.
fn writeDate(buf: *[10]u8, day: i64) []const u8 {
    const epoch_day: std.time.epoch.EpochDay = .{ .day = @intCast(day) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch unreachable;
}

/// Longest `queryPath` result, for a `gatewayUser` tag.
pub const max_query_bytes = 128;
const max_user_bytes = 40;

/// The `/v1/report` path for `period`'s per-model usage of `user`, a
/// `gatewayUser` tag, when `today` is the current UTC day.
pub fn queryPath(buf: *[max_query_bytes]u8, period: Period, today: i64, user: []const u8) []const u8 {
    std.debug.assert(user.len <= max_user_bytes);
    var start: [10]u8 = undefined;
    var end: [10]u8 = undefined;
    return std.fmt.bufPrint(buf, "/v1/report?start_date={s}&end_date={s}&group_by=model&user_id={s}", .{
        writeDate(&start, firstDay(period, today)),
        writeDate(&end, today),
        user,
    }) catch unreachable;
}

/// One model's usage in a period, in fx's terms.
pub const Row = struct {
    model: []const u8,
    /// Including cache reads and writes.
    input_tokens: u64,
    /// Including reasoning.
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: u64,
    request_count: u64,
    /// What AI Gateway charged.
    total_cost: f64,

    fn valid(row: Row) bool {
        if (row.model.len == 0 or row.model.len > max_model_bytes) return false;
        for (row.model) |byte| if (byte < 0x21 or byte > 0x7e) return false;
        return std.math.isFinite(row.total_cost) and row.total_cost >= 0 and
            row.cache_read_tokens <= row.input_tokens and
            row.cache_write_tokens <= row.input_tokens and
            row.reasoning_tokens <= row.output_tokens;
    }
};

/// The longest model name a row may carry, as the session ledger.
pub const max_model_bytes = 256;
/// The most rows one period may hold.
pub const max_rows = 4096;

pub const ParseError = error{ InvalidReport, OutOfMemory };

/// The rows of one `group_by=model` report body, mapped to fx's token
/// counts. A missing token count reads as zero; a malformed row rejects
/// the whole report. Every slice lives in `arena`.
pub fn parseRows(arena: Allocator, body: []const u8) ParseError![]Row {
    const WireRow = struct {
        model: []const u8,
        total_cost: f64,
        request_count: u64,
        input_tokens: ?u64 = null,
        output_tokens: ?u64 = null,
        cached_input_tokens: ?u64 = null,
        cache_creation_input_tokens: ?u64 = null,
        reasoning_tokens: ?u64 = null,
    };
    const Wire = struct { results: []const WireRow };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidReport,
    };
    if (wire.results.len > max_rows) return error.InvalidReport;
    const rows = try arena.alloc(Row, wire.results.len);
    for (wire.results, rows) |in, *out| {
        const cache_read = in.cached_input_tokens orelse 0;
        const cache_write = in.cache_creation_input_tokens orelse 0;
        const reasoning = in.reasoning_tokens orelse 0;
        out.* = .{
            .model = in.model,
            .input_tokens = sum(&.{ in.input_tokens orelse 0, cache_read, cache_write }) orelse return error.InvalidReport,
            .output_tokens = sum(&.{ in.output_tokens orelse 0, reasoning }) orelse return error.InvalidReport,
            .cache_read_tokens = cache_read,
            .cache_write_tokens = cache_write,
            .reasoning_tokens = reasoning,
            .request_count = in.request_count,
            .total_cost = in.total_cost,
        };
        if (!out.valid()) return error.InvalidReport;
    }
    return rows;
}

fn sum(values: []const u64) ?u64 {
    var total: u64 = 0;
    for (values) |value| total = std.math.add(u64, total, value) catch return null;
    return total;
}

/// Whose usage a snapshot holds: SHA-256 of the user tag and the team, in
/// hex. A credential switch reads another identity, so it never shows
/// another key's numbers.
pub const Identity = [64]u8;

pub fn identityOf(user: []const u8, team: ?[]const u8) Identity {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx-gateway-history-v1\x00");
    hash.update(user);
    hash.update("\x00");
    hash.update(team orelse "");
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

/// The last answer AI Gateway gave for one identity.
pub const Snapshot = struct {
    identity: Identity,
    /// When the answer arrived, or when AI Gateway refused the credential.
    fetched_at_ms: i64,
    /// The UTC day the periods end on.
    today: i64,
    /// AI Gateway refused usage reports for this credential: the periods
    /// are empty.
    refused: bool = false,
    /// In `Period.all` order.
    periods: [Period.all.len][]const Row = .{ &.{}, &.{}, &.{} },
};

/// The snapshot file's size limit.
pub const max_snapshot_bytes = 1024 * 1024;

/// Writes `snapshot` as one JSON document.
pub fn encode(writer: *std.Io.Writer, snapshot: Snapshot) std.Io.Writer.Error!void {
    try writer.writeAll("{\"schema_version\":1,\"identity\":\"");
    try writer.writeAll(&snapshot.identity);
    try writer.print("\",\"fetched_at_ms\":{d},\"today\":{d},\"refused\":{},\"periods\":{{", .{
        snapshot.fetched_at_ms,
        snapshot.today,
        snapshot.refused,
    });
    for (Period.all, snapshot.periods, 0..) |period, rows, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("\"{s}\":", .{period.key()});
        try std.json.Stringify.value(rows, .{}, writer);
    }
    try writer.writeAll("}}\n");
}

pub const DecodeError = error{ InvalidSnapshot, OutOfMemory };

/// Reads a snapshot `encode` wrote, rejecting anything else. Every slice
/// lives in `arena`.
pub fn decode(arena: Allocator, bytes: []const u8) DecodeError!Snapshot {
    const Wire = struct {
        schema_version: u32,
        identity: []const u8,
        fetched_at_ms: i64,
        today: i64,
        refused: bool,
        periods: struct {
            today: []const Row,
            @"7d": []const Row,
            @"30d": []const Row,
        },
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSnapshot,
    };
    if (wire.schema_version != 1 or wire.identity.len != 64 or wire.fetched_at_ms < 0 or wire.today < 0) {
        return error.InvalidSnapshot;
    }
    for (wire.identity) |char| switch (char) {
        '0'...'9', 'a'...'f' => {},
        else => return error.InvalidSnapshot,
    };
    const periods = [Period.all.len][]const Row{ wire.periods.today, wire.periods.@"7d", wire.periods.@"30d" };
    for (periods) |rows| {
        if (rows.len > max_rows or (wire.refused and rows.len > 0)) return error.InvalidSnapshot;
        for (rows) |row| if (!row.valid()) return error.InvalidSnapshot;
    }
    return .{
        .identity = wire.identity[0..64].*,
        .fetched_at_ms = wire.fetched_at_ms,
        .today = wire.today,
        .refused = wire.refused,
        .periods = periods,
    };
}

/// A snapshot older than this is refreshed while history is on screen.
pub const stale_after_ms = 15 * std.time.ms_per_min;
/// The least time between two refreshes the user asks for.
pub const manual_interval_ms = 30 * std.time.ms_per_s;
/// How long a refused credential waits before fx asks again on its own.
pub const refused_retry_ms = std.time.ms_per_day;
/// How long a failed refresh waits before fx tries again on its own.
pub const failed_retry_ms = std.time.ms_per_min;

/// What fx knows about this identity's history right now.
pub const State = struct {
    /// The stored snapshot for this identity, if any.
    snapshot: ?*const Snapshot,
    /// When this process last tried a refresh that failed, if it did.
    failed_at_ms: ?i64 = null,
};

/// Whether to fetch new reports at `now_ms`. `asked` is a refresh the
/// user asked for. A snapshot from another UTC day is always due.
pub fn refreshDue(state: State, now_ms: i64, asked: bool) bool {
    const since_failure = if (state.failed_at_ms) |at| now_ms - at else std.math.maxInt(i64);
    const snapshot = state.snapshot orelse return asked or since_failure >= failed_retry_ms;
    const age = now_ms - snapshot.fetched_at_ms;
    if (asked) return age >= manual_interval_ms and since_failure >= manual_interval_ms;
    if (since_failure < failed_retry_ms) return false;
    if (snapshot.refused) return age >= refused_retry_ms;
    return age >= stale_after_ms or snapshot.today != utcDay(now_ms);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// A `group_by=model` body AI Gateway returned on 2026-10-09 for one fx
/// turn and its title.
const captured_report =
    \\{"results":[{"model":"openai/gpt-4.1-nano","total_cost":0.0007864,"market_cost":0.0006114,"input_tokens":6098,"output_tokens":4,"cached_input_tokens":0,"cache_creation_input_tokens":0,"reasoning_tokens":0,"request_count":1,"p90_ttft_ms":520,"p90_tps":null,"http_failure_pct":0,"malformed_response_pct":0,"rate_limit_pct":0,"cache_hit_pct":0},{"model":"openai/gpt-5.6-luna","total_cost":0.000266,"market_cost":0.000091,"input_tokens":71,"output_tokens":9,"cached_input_tokens":0,"cache_creation_input_tokens":0,"reasoning_tokens":55,"request_count":1,"p90_ttft_ms":1447,"p90_tps":null,"http_failure_pct":0,"malformed_response_pct":0,"rate_limit_pct":0,"cache_hit_pct":0}]}
;

test "report queries cover whole UTC days ending today" {
    var buf: [max_query_bytes]u8 = undefined;
    const today = utcDay(1_791_504_000_000 + 5 * std.time.ms_per_hour); // 2026-10-09 05:00 UTC
    const user = "fx_9258b1e31293f24fa6d43e84fc60ca53";
    try testing.expectEqualStrings(
        "/v1/report?start_date=2026-10-09&end_date=2026-10-09&group_by=model&user_id=fx_9258b1e31293f24fa6d43e84fc60ca53",
        queryPath(&buf, .today, today, user),
    );
    try testing.expectEqualStrings(
        "/v1/report?start_date=2026-10-03&end_date=2026-10-09&group_by=model&user_id=fx_9258b1e31293f24fa6d43e84fc60ca53",
        queryPath(&buf, .days_7, today, user),
    );
    try testing.expectEqualStrings(
        "/v1/report?start_date=2026-09-10&end_date=2026-10-09&group_by=model&user_id=fx_9258b1e31293f24fa6d43e84fc60ca53",
        queryPath(&buf, .days_30, today, user),
    );
    // Midnight UTC starts the next day; the last millisecond does not.
    try testing.expectEqual(today + 1, utcDay(1_791_504_000_000 + std.time.ms_per_day));
    try testing.expectEqual(today, utcDay(1_791_504_000_000 + std.time.ms_per_day - 1));
}

test "a captured report maps cache into input and reasoning into output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rows = try parseRows(arena_state.allocator(), captured_report);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("openai/gpt-4.1-nano", rows[0].model);
    try testing.expectEqual(@as(u64, 6098), rows[0].input_tokens);
    try testing.expectEqual(@as(u64, 4), rows[0].output_tokens);
    try testing.expectEqual(@as(f64, 0.0007864), rows[0].total_cost);
    try testing.expectEqualStrings("openai/gpt-5.6-luna", rows[1].model);
    try testing.expectEqual(@as(u64, 64), rows[1].output_tokens);
    try testing.expectEqual(@as(u64, 55), rows[1].reasoning_tokens);
    try testing.expectEqual(@as(u64, 1), rows[1].request_count);

    const cached = try parseRows(arena_state.allocator(),
        \\{"results":[{"model":"anthropic/claude-haiku-4.5","total_cost":1.5,"input_tokens":100,"output_tokens":20,"cached_input_tokens":900,"cache_creation_input_tokens":50,"reasoning_tokens":5,"request_count":3}]}
    );
    try testing.expectEqual(@as(u64, 1050), cached[0].input_tokens);
    try testing.expectEqual(@as(u64, 900), cached[0].cache_read_tokens);
    try testing.expectEqual(@as(u64, 50), cached[0].cache_write_tokens);
    try testing.expectEqual(@as(u64, 25), cached[0].output_tokens);

    const sparse = try parseRows(arena_state.allocator(),
        \\{"results":[{"model":"m","total_cost":0,"request_count":2,"input_tokens":null}]}
    );
    try testing.expectEqual(@as(u64, 0), sparse[0].input_tokens);
    try testing.expectEqual(@as(usize, 0), (try parseRows(arena_state.allocator(), "{\"results\":[]}")).len);
}

test "a malformed report is rejected whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = [_][]const u8{
        "",
        "{}",
        "{\"results\":{}}",
        "{\"results\":[{\"model\":\"m\",\"request_count\":1}]}",
        "{\"results\":[{\"model\":\"\",\"total_cost\":0,\"request_count\":1}]}",
        "{\"results\":[{\"model\":\"a b\",\"total_cost\":0,\"request_count\":1}]}",
        "{\"results\":[{\"model\":\"m\",\"total_cost\":-1,\"request_count\":1}]}",
        "{\"results\":[{\"model\":\"m\",\"total_cost\":0,\"request_count\":-1}]}",
        "{\"results\":[{\"model\":\"m\",\"total_cost\":0,\"request_count\":1,\"input_tokens\":1.5}]}",
        "{\"results\":[{\"model\":\"m\",\"total_cost\":0,\"request_count\":1,\"input_tokens\":18446744073709551615,\"cached_input_tokens\":1}]}",
    };
    for (bad) |body| try testing.expectError(error.InvalidReport, parseRows(arena, body));
}

test "a snapshot reads back exactly and rejects anything else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rows = try parseRows(arena, captured_report);
    const identity = identityOf("fx_9258b1e31293f24fa6d43e84fc60ca53", null);
    const want: Snapshot = .{
        .identity = identity,
        .fetched_at_ms = 1_791_609_600_123,
        .today = 20_735,
        .periods = .{ rows[1..], rows, rows },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try encode(&out.writer, want);
    const got = try decode(arena, out.written());
    try testing.expectEqualSlices(u8, &want.identity, &got.identity);
    try testing.expectEqual(want.fetched_at_ms, got.fetched_at_ms);
    try testing.expectEqual(want.today, got.today);
    try testing.expectEqual(false, got.refused);
    for (want.periods, got.periods) |a, b| {
        try testing.expectEqual(a.len, b.len);
        for (a, b) |x, y| {
            try testing.expectEqualStrings(x.model, y.model);
            try testing.expectEqual(x.total_cost, y.total_cost);
            try testing.expectEqual(x.output_tokens, y.output_tokens);
        }
    }

    const written = out.written();
    // A torn write, another schema, or a bad row is no snapshot.
    try testing.expectError(error.InvalidSnapshot, decode(arena, written[0 .. written.len / 2]));
    const other_schema = try std.mem.replaceOwned(u8, arena, written, "\"schema_version\":1", "\"schema_version\":2");
    try testing.expectError(error.InvalidSnapshot, decode(arena, other_schema));
    const bad_row = try std.mem.replaceOwned(u8, arena, written, "\"reasoning_tokens\":55", "\"reasoning_tokens\":65");
    try testing.expectError(error.InvalidSnapshot, decode(arena, bad_row));

    // A refused credential keeps no rows.
    out.clearRetainingCapacity();
    try encode(&out.writer, .{ .identity = identity, .fetched_at_ms = 5, .today = 0, .refused = true });
    try testing.expect((try decode(arena, out.written())).refused);
}

test "the identity separates keys and teams" {
    const a = identityOf("fx_a", null);
    try testing.expect(!std.mem.eql(u8, &a, &identityOf("fx_b", null)));
    try testing.expect(!std.mem.eql(u8, &a, &identityOf("fx_a", "team_1")));
    try testing.expectEqualSlices(u8, &a, &identityOf("fx_a", null));
}

test "history refreshes when stale, on a new UTC day, or when asked" {
    const day = std.time.ms_per_day;
    const now: i64 = 100 * day + 12 * std.time.ms_per_hour;
    var snapshot: Snapshot = .{ .identity = @splat('0'), .fetched_at_ms = now - std.time.ms_per_min, .today = utcDay(now) };
    const fresh: State = .{ .snapshot = &snapshot };
    try testing.expect(!refreshDue(fresh, now, false));
    try testing.expect(refreshDue(fresh, now, true));
    try testing.expect(!refreshDue(fresh, snapshot.fetched_at_ms + 10 * std.time.ms_per_s, true));
    try testing.expect(refreshDue(fresh, snapshot.fetched_at_ms + stale_after_ms, false));

    snapshot.today -= 1;
    try testing.expect(refreshDue(fresh, now, false));
    snapshot.today += 1;

    // No snapshot: load now, but after a failure wait a minute unless asked.
    try testing.expect(refreshDue(.{ .snapshot = null }, now, false));
    try testing.expect(!refreshDue(.{ .snapshot = null, .failed_at_ms = now - 1000 }, now, false));
    try testing.expect(refreshDue(.{ .snapshot = null, .failed_at_ms = now - 1000 }, now, true));
    try testing.expect(refreshDue(.{ .snapshot = null, .failed_at_ms = now - failed_retry_ms }, now, false));
    const stale: State = .{ .snapshot = &snapshot, .failed_at_ms = now - 1000 };
    snapshot.fetched_at_ms = now - stale_after_ms;
    try testing.expect(!refreshDue(stale, now, false));
    try testing.expect(!refreshDue(stale, now, true));

    // A refusal waits a day unless asked.
    snapshot.refused = true;
    snapshot.fetched_at_ms = now - std.time.ms_per_hour;
    try testing.expect(!refreshDue(fresh, now, false));
    try testing.expect(refreshDue(fresh, now, true));
    snapshot.fetched_at_ms = now - refused_retry_ms;
    try testing.expect(refreshDue(fresh, now, false));
}
