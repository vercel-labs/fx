//! Brave Search API. Key: BRAVE_API_KEY.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

const endpoint = "https://api.search.brave.com/res/v1/web/search";

pub const member = bank.Member{
    .id = "brave",
    .label = "Brave",
    .available_fn = available,
    .search_fn = search,
};

fn available(env: *const bank.Env) bool {
    return env.get("BRAVE_API_KEY") != null;
}

/// The request URL. The caller owns it.
pub fn buildUrl(alloc: Allocator, query: bank.Query) ![]u8 {
    const text = try bank.queryWithSiteOperators(alloc, query);
    defer alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(endpoint ++ "?q=");
    try http.writeQueryComponent(&out.writer, text[0..@min(text.len, 400)]);
    try out.writer.print("&count={d}&extra_snippets=true", .{query.limit});
    if (query.recency) |recency| try out.writer.print("&freshness={s}", .{switch (recency) {
        .day => "pd",
        .week => "pw",
        .month => "pm",
        .year => "py",
    }});
    return out.toOwnedSlice();
}

fn search(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const key = env.get("BRAVE_API_KEY") orelse return error.MissingSearchCredential;
    const url = try buildUrl(alloc, query);
    defer alloc.free(url);
    const body = try http.sendOk(alloc, .{
        .url = url,
        .headers = &.{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "x-subscription-token", .value = key },
        },
    }, query);
    defer alloc.free(body);
    return parse(alloc, body);
}

/// Normalizes `web.results`: description plus extra snippets, and the age.
pub fn parse(alloc: Allocator, body: []const u8) !bank.Answer {
    var parsed = try http.parseJson(alloc, body);
    defer parsed.deinit();
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    for (http.arr(http.get(parsed.value, "web"), "results")) |result| {
        var snippet: std.Io.Writer.Allocating = .init(alloc);
        defer snippet.deinit();
        const description = try http.htmlText(alloc, http.str(result, "description"));
        defer alloc.free(description);
        try snippet.writer.writeAll(description);
        for (http.arr(result, "extra_snippets")) |extra| {
            if (extra != .string) continue;
            const text = try http.htmlText(alloc, extra.string);
            defer alloc.free(text);
            if (text.len == 0 or std.mem.find(u8, snippet.written(), text) != null) continue;
            try snippet.writer.writeAll("\n");
            try snippet.writer.writeAll(text);
        }
        const title = try http.htmlText(alloc, http.str(result, "title"));
        defer alloc.free(title);
        try hits.add(title, http.str(result, "url"), snippet.written(), http.firstStr(result, &.{ "age", "page_age" }));
    }
    return hits.finish("");
}

test "brave request carries count, freshness, and site operators" {
    var cancel = std.atomic.Value(bool).init(false);
    const url = try buildUrl(std.testing.allocator, .{
        .text = "zig release",
        .recency = .week,
        .limit = 5,
        .allowed_domains = &.{"ziglang.org"},
        .cancel_flag = &cancel,
    });
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        endpoint ++ "?q=zig%20release%20%28site%3Aziglang.org%29&count=5&extra_snippets=true&freshness=pw",
        url,
    );
}

test "brave response normalizes title, url, snippet, and age" {
    const fixture =
        \\{"type":"search","web":{"results":[
        \\ {"title":"<strong>Zig</strong> 0.17","url":"https://ziglang.org/download/0.17.0/release-notes.html","description":"Release &amp; notes","extra_snippets":["More detail","Release &amp; notes"],"age":"2 days ago"},
        \\ {"title":"","url":"https://example.com/x","description":""},
        \\ {"title":"No url"}
        \\]}}
    ;
    var answer = try parse(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), answer.hits.len);
    try std.testing.expectEqualStrings("Zig 0.17", answer.hits[0].title);
    try std.testing.expectEqualStrings("Release & notes\nMore detail", answer.hits[0].snippet);
    try std.testing.expectEqualStrings("2 days ago", answer.hits[0].date);
    try std.testing.expectEqualStrings("https://example.com/x", answer.hits[1].title);
}
