//! Kagi search API. Key: KAGI_API_KEY.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

const endpoint = "https://kagi.com/api/v1/search";

pub const member = bank.Member{
    .id = "kagi",
    .label = "Kagi",
    .available_fn = available,
    .search_fn = search,
};

fn available(env: *const bank.Env) bool {
    return env.get("KAGI_API_KEY") != null;
}

/// The JSON body; recency becomes an `after` date filter. The caller owns it.
pub fn buildBody(alloc: Allocator, query: bank.Query, after: ?[]const u8) ![]u8 {
    const text = try bank.queryWithSiteOperators(alloc, query);
    defer alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"query\":");
    try http.writeJsonString(&out.writer, text);
    try out.writer.print(",\"workflow\":\"search\",\"limit\":{d}", .{query.limit});
    if (after) |date| try out.writer.print(",\"filters\":{{\"after\":\"{s}\"}}", .{date});
    try out.writer.writeAll("}");
    return out.toOwnedSlice();
}

fn search(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const key = env.get("KAGI_API_KEY") orelse return error.MissingSearchCredential;
    const authorization = try alloc.print("Bearer {s}", .{key});
    defer alloc.free(authorization);
    var date_buf: [10]u8 = undefined;
    const after = if (query.recency) |recency| http.recencyStartDate(&date_buf, recency) else null;
    const payload = try buildBody(alloc, query, after);
    defer alloc.free(payload);
    const body = try http.sendOk(alloc, .{
        .method = .post,
        .url = endpoint,
        .body = payload,
        .content_type = "application/json",
        .authorization = authorization,
        .headers = &.{.{ .name = "accept", .value = "application/json" }},
    }, query);
    defer alloc.free(body);
    return parse(alloc, body);
}

/// Web results first, then news, video, and infobox entries with a tag.
pub fn parse(alloc: Allocator, body: []const u8) !bank.Answer {
    var parsed = try http.parseJson(alloc, body);
    defer parsed.deinit();
    const data = http.get(parsed.value, "data");
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    const groups = [_]struct { []const u8, []const u8 }{
        .{ "search", "" }, .{ "news", "[News] " }, .{ "video", "[Video] " }, .{ "infobox", "[Info] " },
    };
    for (groups) |group| {
        for (http.arr(data, group[0])) |item| {
            const url = http.firstStr(item, &.{ "url", "href", "link" });
            const raw_title = http.firstStr(item, &.{ "title", "name" });
            const title = try alloc.print("{s}{s}", .{ group[1], if (raw_title.len > 0) raw_title else url });
            defer alloc.free(title);
            try hits.add(title, url, http.firstStr(item, &.{ "snippet", "description", "summary" }), http.str(item, "time"));
        }
    }
    return hits.finish("");
}

test "kagi body carries limit and after filter" {
    var cancel = std.atomic.Value(bool).init(false);
    const body = try buildBody(std.testing.allocator, .{ .text = "zig", .limit = 7, .cancel_flag = &cancel }, "2026-10-21");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"query\":\"zig\",\"workflow\":\"search\",\"limit\":7,\"filters\":{\"after\":\"2026-10-21\"}}", body);
}

test "kagi response tags non-web groups" {
    const fixture =
        \\{"meta":{},"data":{"search":[{"url":"https://ziglang.org","title":"Zig","snippet":"Home","time":"2026-10-01"}],
        \\ "news":[{"url":"https://news.example/zig","title":"Zig ships"}]}}
    ;
    var answer = try parse(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), answer.hits.len);
    try std.testing.expectEqualStrings("2026-10-01", answer.hits[0].date);
    try std.testing.expectEqualStrings("[News] Zig ships", answer.hits[1].title);
}
