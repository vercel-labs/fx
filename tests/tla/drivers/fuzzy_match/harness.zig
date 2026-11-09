//! A JSON-lines shell around the real fuzzy match engine, for the Bun drivers.
//!
//! Built from `src/core/shared/fuzzy_match.zig` (or a planted-bug copy of it)
//! as the `fuzzy_match` module. It reads one request per line and prints one
//! line per request. Text travels as lowercase hex, so any bytes can.
//!
//!   in:  {"case":{"q":"6370","f":[{"h":"2f6d6f64656c","k":"name"}]}}
//!   out: {"tier":"fuzzy","field":0}         or {"tier":"none","field":null}
//!
//!   in:  {"listing":{"items":[[{"h":"...","k":"name"}],...],"q":"...","mode":"ranked"}}
//!   out: {"shown":[2,0],"at":[2,0],"count":2,"rank_of":[0,1]}
//!
//! A listing request builds the listing with the real `Ranking` or `Filter`:
//! `shown` walks it (the iterator, or `keeps` in base order), `at` reads it
//! back by index up to `count`, and `rank_of` is `Ranking.rankOf` for each
//! shown position (empty when filtered). Positions count from 0.
//!
//!   in:  {"bench":{"items":[[{"h":"...","k":"name"}],...],"queries":["..."],"passes":5,"legacy":false}}
//!   out: {"ns":123456,"min_ns":24000,"passes":5,"matches":42}
//!
//! A bench request times `passes` runs of every query over every item and
//! reports the total and the fastest run, which a busy machine disturbs
//! least. With
//! `legacy` it times today's substring scan instead: every field against the
//! whole trimmed query, with `containsIgnoreCase` as
//! `src/core/shared/text_utils.zig` has it. The harness is a shell and
//! decides nothing itself.
const std = @import("std");
const fuzzy_match = @import("fuzzy_match");

const FieldJson = struct { h: []const u8, k: []const u8 };
const CaseJson = struct { q: []const u8, f: []const FieldJson };
const BenchJson = struct {
    items: []const []const FieldJson,
    queries: []const []const u8,
    passes: u32,
    legacy: bool = false,
};
const ListingJson = struct { items: []const []const FieldJson, q: []const u8, mode: []const u8 };
const Input = struct { case: ?CaseJson = null, bench: ?BenchJson = null, listing: ?ListingJson = null };

const Answer = struct { tier: []const u8, field: ?usize };
const ListingAnswer = struct { shown: []const usize, at: []const usize, count: usize, rank_of: []const usize };

const Items = struct {
    items: []const []const fuzzy_match.Field,
    query: []const u8,

    pub fn matchAt(self: Items, position: usize) ?fuzzy_match.Match {
        return fuzzy_match.match(self.query, self.items[position]);
    }
};

fn listing(alloc: std.mem.Allocator, request: ListingJson) !ListingAnswer {
    const items = try alloc.alloc([]const fuzzy_match.Field, request.items.len);
    for (request.items, items) |item, *slot| slot.* = try fields(alloc, item);
    const context: Items = .{ .items = items, .query = try unhex(alloc, request.q) };
    var shown: std.ArrayList(usize) = .empty;
    var at: std.ArrayList(usize) = .empty;
    var rank_of: std.ArrayList(usize) = .empty;
    if (std.mem.eql(u8, request.mode, "ranked")) {
        const ranking: fuzzy_match.Ranking(Items) = .{ .context = context, .len = items.len };
        var walk = ranking.iterator();
        while (walk.next()) |position| {
            try shown.append(alloc, position);
            try rank_of.append(alloc, ranking.rankOf(position) orelse return error.RankOfMissing);
        }
        const count = ranking.count();
        for (0..count) |rank| try at.append(alloc, ranking.at(rank) orelse return error.AtMissing);
        if (ranking.at(count) != null) return error.AtPastEnd;
        return .{ .shown = shown.items, .at = at.items, .count = count, .rank_of = rank_of.items };
    }
    if (!std.mem.eql(u8, request.mode, "filtered")) return error.InvalidMode;
    const filter: fuzzy_match.Filter(Items) = .init(context, items.len);
    for (0..items.len) |position| {
        if (filter.keeps(position)) try shown.append(alloc, position);
    }
    const count = filter.count();
    for (0..count) |index| try at.append(alloc, filter.at(index) orelse return error.AtMissing);
    if (filter.at(count) != null) return error.AtPastEnd;
    return .{ .shown = shown.items, .at = at.items, .count = count, .rank_of = &.{} };
}

const BenchAnswer = struct { ns: i96, min_ns: i96, passes: u32, matches: u64 };

fn unhex(alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try alloc.alloc(u8, hex.len / 2);
    _ = std.fmt.hexToBytes(out, hex) catch return error.InvalidHex;
    return out;
}

fn kind(text: []const u8) !fuzzy_match.Field.Kind {
    if (std.mem.eql(u8, text, "name")) return .name;
    if (std.mem.eql(u8, text, "text")) return .text;
    return error.InvalidKind;
}

fn fields(alloc: std.mem.Allocator, json: []const FieldJson) ![]fuzzy_match.Field {
    const out = try alloc.alloc(fuzzy_match.Field, json.len);
    for (json, out) |field, *slot| slot.* = .{ .text = try unhex(alloc, field.h), .kind = try kind(field.k) };
    return out;
}

/// `containsIgnoreCase` from `src/core/shared/text_utils.zig`, the scan most
/// menus run today. Copied rather than imported because that file pulls in
/// fx's I/O layer; it is the benchmark's baseline, not a reference answer.
fn legacyContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const last_start = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= last_start) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn bench(io: std.Io, alloc: std.mem.Allocator, request: BenchJson) !BenchAnswer {
    const items = try alloc.alloc([]fuzzy_match.Field, request.items.len);
    for (request.items, items) |item, *slot| slot.* = try fields(alloc, item);
    const queries = try alloc.alloc([]u8, request.queries.len);
    for (request.queries, queries) |query, *slot| slot.* = try unhex(alloc, query);

    var matches: u64 = 0;
    var total: i96 = 0;
    var fastest: i96 = std.math.maxInt(i96);
    for (0..request.passes) |_| {
        const start = std.Io.Timestamp.now(io, .awake);
        for (queries) |query| {
            const trimmed = std.mem.trim(u8, query, " \t\r\n");
            for (items) |item| {
                if (request.legacy) {
                    for (item) |field| {
                        if (legacyContains(field.text, trimmed)) {
                            matches += 1;
                            break;
                        }
                    }
                } else if (fuzzy_match.match(query, item) != null) {
                    matches += 1;
                }
            }
        }
        const elapsed = start.untilNow(io, .awake).toNanoseconds();
        total += elapsed;
        fastest = @min(fastest, elapsed);
    }
    std.mem.doNotOptimizeAway(matches);
    return .{ .ns = total, .min_ns = fastest, .passes = request.passes, .matches = matches };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // A bench request carries every item, up to about 10 MiB of JSON.
    const in_buffer = try init.gpa.alloc(u8, 32 << 20);
    defer init.gpa.free(in_buffer);
    var stdin = std.Io.File.stdin().reader(io, in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const writer = &stdout.interface;

    while (true) {
        const raw = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.RequestTooLong,
            else => return err,
        } orelse break;
        const text = std.mem.trim(u8, raw, " \r\t");
        if (text.len == 0) continue;

        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        const parsed = try std.json.parseFromSliceLeaky(Input, alloc, text, .{});

        if (parsed.case) |request| {
            const answer: Answer = if (fuzzy_match.match(try unhex(alloc, request.q), try fields(alloc, request.f))) |found|
                .{ .tier = @tagName(found.tier), .field = found.field }
            else
                .{ .tier = "none", .field = null };
            try std.json.Stringify.value(answer, .{}, writer);
        } else if (parsed.listing) |request| {
            try std.json.Stringify.value(try listing(alloc, request), .{}, writer);
        } else if (parsed.bench) |request| {
            try std.json.Stringify.value(try bench(io, alloc, request), .{}, writer);
        } else return error.InvalidRequest;
        try writer.writeByte('\n');
        try writer.flush();
    }
}
