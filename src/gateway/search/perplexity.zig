//! Perplexity Sonar chat completions with search. Key: PERPLEXITY_API_KEY.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

const endpoint = "https://api.perplexity.ai/chat/completions";
const model = "sonar-pro";

pub const member = bank.Member{
    .id = "perplexity",
    .label = "Perplexity",
    .available_fn = available,
    .search_fn = search,
};

fn available(env: *const bank.Env) bool {
    return env.get("PERPLEXITY_API_KEY") != null;
}

/// The JSON body. Domain filters use `search_domain_filter`, with a leading
/// "-" for a blocked domain. The caller owns it.
pub fn buildBody(alloc: Allocator, query: bank.Query) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"model\":\"" ++ model ++ "\",\"messages\":[{\"role\":\"user\",\"content\":");
    try http.writeJsonString(w, query.text);
    try w.print("}}],\"max_tokens\":{d},\"search_mode\":\"web\",\"return_related_questions\":false", .{@min(query.max_output_tokens, 8192)});
    if (query.recency) |recency| try w.print(",\"search_recency_filter\":\"{s}\"", .{@tagName(recency)});
    if (query.allowed_domains.len + query.blocked_domains.len > 0) {
        try w.writeAll(",\"search_domain_filter\":[");
        var first = true;
        for (query.allowed_domains) |domain| {
            if (!first) try w.writeAll(",");
            first = false;
            try http.writeJsonString(w, bank.urlHost(domain));
        }
        for (query.blocked_domains) |domain| {
            if (!first) try w.writeAll(",");
            first = false;
            const negated = try alloc.print("-{s}", .{bank.urlHost(domain)});
            defer alloc.free(negated);
            try http.writeJsonString(w, negated);
        }
        try w.writeAll("]");
    }
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn search(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const key = env.get("PERPLEXITY_API_KEY") orelse return error.MissingSearchCredential;
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

/// The answer from the first choice. Sources follow the citation order with
/// details from `search_results`; without citations, the search results.
pub fn parse(alloc: Allocator, body: []const u8) !bank.Answer {
    var parsed = try http.parseJson(alloc, body);
    defer parsed.deinit();
    const choices = http.arr(parsed.value, "choices");
    const text = if (choices.len > 0) http.str(http.get(choices[0], "message"), "content") else "";
    const results = http.arr(parsed.value, "search_results");
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    const citations = http.arr(parsed.value, "citations");
    if (citations.len > 0) {
        for (citations) |citation| {
            if (citation != .string) continue;
            const detail = findResult(results, citation.string);
            try hits.add(http.str(detail, "title"), citation.string, http.str(detail, "snippet"), http.str(detail, "date"));
        }
    } else {
        for (results) |result| try hits.add(http.str(result, "title"), http.str(result, "url"), http.str(result, "snippet"), http.str(result, "date"));
    }
    return hits.finish(text);
}

fn findResult(results: []const std.json.Value, url: []const u8) ?std.json.Value {
    for (results) |result| if (std.mem.eql(u8, http.str(result, "url"), url)) return result;
    return null;
}

test "perplexity body maps recency and domain filters" {
    var cancel = std.atomic.Value(bool).init(false);
    const body = try buildBody(std.testing.allocator, .{ .text = "zig", .recency = .day, .blocked_domains = &.{"x.com"}, .cancel_flag = &cancel });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"search_recency_filter\":\"day\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"search_domain_filter\":[\"-x.com\"]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"sonar-pro\"") != null);
}

test "perplexity response orders sources by citation" {
    const fixture =
        \\{"id":"r","model":"sonar-pro","choices":[{"message":{"role":"assistant","content":"Zig 0.17 is out [1]."}}],
        \\ "citations":["https://ziglang.org/news","https://example.com/a"],
        \\ "search_results":[{"title":"Example","url":"https://example.com/a","date":"2026-09-01","snippet":"s"},{"title":"Zig news","url":"https://ziglang.org/news"}]}
    ;
    var answer = try parse(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Zig 0.17 is out [1].", answer.text);
    try std.testing.expectEqualStrings("Zig news", answer.hits[0].title);
    try std.testing.expectEqualStrings("2026-09-01", answer.hits[1].date);
}
