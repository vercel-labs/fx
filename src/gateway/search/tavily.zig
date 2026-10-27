//! Tavily search API with its synthesized answer. Key: TAVILY_API_KEY.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

const endpoint = "https://api.tavily.com/search";

pub const member = bank.Member{
    .id = "tavily",
    .label = "Tavily",
    .available_fn = available,
    .search_fn = search,
};

fn available(env: *const bank.Env) bool {
    return env.get("TAVILY_API_KEY") != null;
}

/// The JSON body. Domain filters and recency are native. The caller owns it.
pub fn buildBody(alloc: Allocator, query: bank.Query) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"query\":");
    try http.writeJsonString(w, query.text);
    try w.print(",\"search_depth\":\"basic\",\"max_results\":{d},\"include_answer\":\"advanced\",\"include_raw_content\":false", .{query.limit});
    try writeDomains(w, "include_domains", query.allowed_domains);
    try writeDomains(w, "exclude_domains", query.blocked_domains);
    if (query.recency) |recency| try w.print(",\"time_range\":\"{s}\"", .{@tagName(recency)});
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn writeDomains(w: *std.Io.Writer, field: []const u8, domains: []const []const u8) !void {
    if (domains.len == 0) return;
    try w.print(",\"{s}\":[", .{field});
    for (domains, 0..) |domain, index| {
        if (index > 0) try w.writeAll(",");
        try http.writeJsonString(w, bank.urlHost(std.mem.trim(u8, domain, " ")));
    }
    try w.writeAll("]");
}

fn search(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const key = env.get("TAVILY_API_KEY") orelse return error.MissingSearchCredential;
    const authorization = try alloc.print("Bearer {s}", .{key});
    defer alloc.free(authorization);
    const payload = try buildBody(alloc, query);
    defer alloc.free(payload);
    const body = try http.sendOk(alloc, .{
        .method = .post,
        .url = endpoint,
        .body = payload,
        .content_type = "application/json",
        .authorization = authorization,
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
        try hits.add(http.str(result, "title"), http.str(result, "url"), http.str(result, "content"), http.str(result, "published_date"));
    }
    return hits.finish(http.str(parsed.value, "answer"));
}

test "tavily body uses native filters and time range" {
    var cancel = std.atomic.Value(bool).init(false);
    const body = try buildBody(std.testing.allocator, .{
        .text = "zig \"0.17\"",
        .recency = .month,
        .limit = 3,
        .blocked_domains = &.{"https://spam.example/"},
        .cancel_flag = &cancel,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"query\":\"zig \\\"0.17\\\"\",\"search_depth\":\"basic\",\"max_results\":3,\"include_answer\":\"advanced\",\"include_raw_content\":false,\"exclude_domains\":[\"spam.example\"],\"time_range\":\"month\"}",
        body,
    );
}

test "tavily response keeps the answer and normalizes results" {
    const fixture =
        \\{"query":"zig","answer":"Zig 0.17 shipped.","results":[
        \\ {"title":"Release notes","url":"https://ziglang.org/r","content":"Notes body","published_date":"2026-10-01"},
        \\ {"url":"https://example.com"}]}
    ;
    var answer = try parse(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Zig 0.17 shipped.", answer.text);
    try std.testing.expectEqual(@as(usize, 2), answer.hits.len);
    try std.testing.expectEqualStrings("2026-10-01", answer.hits[0].date);
    try std.testing.expectEqualStrings("https://example.com", answer.hits[1].title);
}
