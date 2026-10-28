//! A SearXNG instance's JSON API. Endpoint: `web_search.searxng_url` in the
//! profile settings or SEARXNG_ENDPOINT; optional SEARXNG_TOKEN.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

pub const member = bank.Member{
    .id = "searxng",
    .label = "SearXNG",
    .needs = .url,
    .available_fn = available,
    .search_fn = search,
};

fn available(env: *const bank.Env) bool {
    return env.searxngUrl() != null;
}

/// `<base>/search?q=...&format=json`. SearXNG has no week range, so a week
/// widens to a month. The caller owns the URL.
pub fn buildUrl(alloc: Allocator, base: []const u8, query: bank.Query) ![]u8 {
    const text = try bank.queryWithSiteOperators(alloc, query);
    defer alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(std.mem.trimEnd(u8, base, "/"));
    try out.writer.writeAll("/search?q=");
    try http.writeQueryComponent(&out.writer, text);
    try out.writer.writeAll("&format=json");
    if (query.recency) |recency| try out.writer.print("&time_range={s}", .{switch (recency) {
        .day => "day",
        .week, .month => "month",
        .year => "year",
    }});
    return out.toOwnedSlice();
}

fn search(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const base = env.searxngUrl() orelse return error.MissingSearchCredential;
    const url = try buildUrl(alloc, base, query);
    defer alloc.free(url);
    const authorization = if (env.get("SEARXNG_TOKEN")) |token| try alloc.print("Bearer {s}", .{token}) else null;
    defer if (authorization) |value| alloc.free(value);
    const body = try http.sendOk(alloc, .{
        .url = url,
        .authorization = authorization,
        .headers = &.{.{ .name = "accept", .value = "application/json" }},
    }, query);
    defer alloc.free(body);
    return parse(alloc, body);
}

pub fn parse(alloc: Allocator, body: []const u8) !bank.Answer {
    var parsed = try http.parseJson(alloc, body);
    defer parsed.deinit();
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    for (http.arr(parsed.value, "results")) |result| {
        try hits.add(http.str(result, "title"), http.str(result, "url"), http.str(result, "content"), http.firstStr(result, &.{ "publishedDate", "pubdate" }));
    }
    var answer: std.Io.Writer.Allocating = .init(alloc);
    defer answer.deinit();
    for (http.arr(parsed.value, "answers")) |item| {
        const text = if (item == .string) item.string else http.firstStr(item, &.{ "answer", "content" });
        if (text.len == 0) continue;
        if (answer.written().len > 0) try answer.writer.writeAll("\n");
        try answer.writer.writeAll(text);
    }
    return hits.finish(answer.written());
}

test "searxng url maps week to month" {
    var cancel = std.atomic.Value(bool).init(false);
    const url = try buildUrl(std.testing.allocator, "http://127.0.0.1:8888/", .{ .text = "zig", .recency = .week, .cancel_flag = &cancel });
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:8888/search?q=zig&format=json&time_range=month", url);
}

test "searxng response keeps answers and results" {
    const fixture =
        \\{"query":"zig","results":[{"url":"https://ziglang.org","title":"Zig","content":"Home","publishedDate":"2026-10-01T00:00:00"}],
        \\ "answers":[{"answer":"Zig is a language."}],"unresponsive_engines":[]}
    ;
    var answer = try parse(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Zig is a language.", answer.text);
    try std.testing.expectEqualStrings("Home", answer.hits[0].snippet);
}
