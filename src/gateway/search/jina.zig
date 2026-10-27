//! Jina search (s.jina.ai). Key: JINA_API_KEY.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

const endpoint = "https://s.jina.ai/";

pub const member = bank.Member{
    .id = "jina",
    .label = "Jina",
    .available_fn = available,
    .search_fn = search,
};

fn available(env: *const bank.Env) bool {
    return env.get("JINA_API_KEY") != null;
}

/// The request URL; a single allowed domain goes in the X-Site header
/// instead, others become site operators. The caller owns it.
pub fn buildUrl(alloc: Allocator, query: bank.Query) ![]u8 {
    var site_query = query;
    if (query.allowed_domains.len == 1) site_query.allowed_domains = &.{};
    const text = try bank.queryWithSiteOperators(alloc, site_query);
    defer alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(endpoint);
    try http.writeQueryComponent(&out.writer, text);
    try out.writer.print("?count={d}", .{query.limit});
    return out.toOwnedSlice();
}

fn search(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const key = env.get("JINA_API_KEY") orelse return error.MissingSearchCredential;
    const authorization = try alloc.print("Bearer {s}", .{key});
    defer alloc.free(authorization);
    const url = try buildUrl(alloc, query);
    defer alloc.free(url);
    var headers_buf: [4]std.http.Header = .{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "x-respond-with", .value = "no-content" },
        .{ .name = "x-retain-images", .value = "none" },
        undefined,
    };
    var header_count: usize = 3;
    if (query.allowed_domains.len == 1) {
        headers_buf[3] = .{ .name = "x-site", .value = bank.urlHost(query.allowed_domains[0]) };
        header_count = 4;
    }
    const body = try http.sendOk(alloc, .{ .url = url, .authorization = authorization, .headers = headers_buf[0..header_count] }, query);
    defer alloc.free(body);
    return parse(alloc, body, query.limit);
}

/// Accepts the `{code, data:[...]}` envelope or a bare array.
pub fn parse(alloc: Allocator, body: []const u8, limit: u8) !bank.Answer {
    var parsed = try http.parseJson(alloc, body);
    defer parsed.deinit();
    const results: []const std.json.Value = if (parsed.value == .array)
        parsed.value.array.items
    else
        http.arr(parsed.value, "data");
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    for (results) |result| {
        if (hits.items.items.len >= limit) break;
        try hits.add(http.str(result, "title"), http.str(result, "url"), http.firstStr(result, &.{ "description", "content" }), http.firstStr(result, &.{ "date", "publishedTime" }));
    }
    return hits.finish("");
}

test "jina moves one allowed domain to the site header" {
    var cancel = std.atomic.Value(bool).init(false);
    const url = try buildUrl(std.testing.allocator, .{ .text = "zig io", .limit = 4, .allowed_domains = &.{"ziglang.org"}, .cancel_flag = &cancel });
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(endpoint ++ "zig%20io?count=4", url);
}

test "jina response accepts the data envelope" {
    const fixture =
        \\{"code":200,"status":20000,"data":[{"title":"Zig","url":"https://ziglang.org","description":"Home","content":""},{"title":"Docs","url":"https://ziglang.org/documentation","content":"Body"}]}
    ;
    var answer = try parse(std.testing.allocator, fixture, 10);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), answer.hits.len);
    try std.testing.expectEqualStrings("Home", answer.hits[0].snippet);
    try std.testing.expectEqualStrings("Body", answer.hits[1].snippet);
}
