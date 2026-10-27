//! Anthropic Messages with the `web_search` server tool, through the active
//! Anthropic-compatible connection or ANTHROPIC_API_KEY. Shares the Messages
//! API version and key styles with `src/gateway/anthropic_messages.zig`.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const anthropic_messages = @import("../anthropic_messages.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

const default_model = "claude-haiku-4-5";
const tool_type = "web_search_20250305";

pub const member = bank.Member{
    .id = "anthropic",
    .label = "Anthropic",
    .available_fn = available,
    .search_fn = search,
};

fn available(env: *const bank.Env) bool {
    return env.anthropicEndpoint() != null;
}

/// The Messages body. Domain filters are native; recency is asked for in the
/// prompt. The caller owns it.
pub fn buildBody(alloc: Allocator, model: []const u8, query: bank.Query) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const prompt = if (query.recency) |recency|
        try alloc.print("Search the web and answer briefly with sources, using only results from the past {s}: {s}", .{ @tagName(recency), query.text })
    else
        try alloc.print("Search the web and answer briefly with sources: {s}", .{query.text});
    defer alloc.free(prompt);
    try w.writeAll("{\"model\":");
    try http.writeJsonString(w, model);
    try w.print(",\"max_tokens\":{d},\"messages\":[{{\"role\":\"user\",\"content\":", .{@min(query.max_output_tokens, 4096)});
    try http.writeJsonString(w, prompt);
    try w.writeAll("}],\"tools\":[{\"type\":\"" ++ tool_type ++ "\",\"name\":\"web_search\",\"max_uses\":3");
    try writeDomains(w, "allowed_domains", query.allowed_domains);
    if (query.allowed_domains.len == 0) try writeDomains(w, "blocked_domains", query.blocked_domains);
    try w.writeAll("}]}");
    return out.toOwnedSlice();
}

fn writeDomains(w: *std.Io.Writer, field: []const u8, domains: []const []const u8) !void {
    if (domains.len == 0) return;
    try w.print(",\"{s}\":[", .{field});
    for (domains, 0..) |domain, index| {
        if (index > 0) try w.writeAll(",");
        try http.writeJsonString(w, bank.urlHost(domain));
    }
    try w.writeAll("]");
}

fn search(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const endpoint = env.anthropicEndpoint() orelse return error.MissingSearchCredential;
    const model = env.get("ANTHROPIC_SEARCH_MODEL") orelse default_model;
    const payload = try buildBody(alloc, model, query);
    defer alloc.free(payload);
    const url = try alloc.print("{s}/messages", .{std.mem.trimEnd(u8, endpoint.base_url, "/")});
    defer alloc.free(url);
    const authorization = if (endpoint.bearer) try alloc.print("Bearer {s}", .{endpoint.key}) else null;
    defer if (authorization) |value| alloc.free(value);
    var headers_buf: [2]std.http.Header = .{
        .{ .name = "anthropic-version", .value = anthropic_messages.api_version },
        .{ .name = "x-api-key", .value = endpoint.key },
    };
    const body = try http.sendOk(alloc, .{
        .method = .post,
        .url = url,
        .body = payload,
        .content_type = "application/json",
        .authorization = authorization,
        .headers = headers_buf[0..if (endpoint.bearer) 1 else 2],
    }, query);
    defer alloc.free(body);
    return parse(alloc, body);
}

/// Text blocks form the answer; `web_search_tool_result` blocks give the
/// sources with their page age; citations add the cited text as snippets.
pub fn parse(alloc: Allocator, body: []const u8) !bank.Answer {
    var parsed = try http.parseJson(alloc, body);
    defer parsed.deinit();
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(alloc);
    var searched = false;
    var search_error: []const u8 = "";
    for (http.arr(parsed.value, "content")) |block| {
        const kind = http.str(block, "type");
        if (std.mem.eql(u8, kind, "web_search_tool_result")) {
            searched = true;
            const content = http.get(block, "content") orelse continue;
            if (content == .object) {
                search_error = http.str(content, "error_code");
                continue;
            }
            if (content != .array) continue;
            for (content.array.items) |result| {
                try hits.add(http.str(result, "title"), http.str(result, "url"), "", http.str(result, "page_age"));
            }
        } else if (std.mem.eql(u8, kind, "text")) {
            try answer.appendSlice(alloc, http.str(block, "text"));
            for (http.arr(block, "citations")) |citation| {
                const url = http.str(citation, "url");
                try attachSnippet(&hits, http.str(citation, "title"), url, http.str(citation, "cited_text"));
            }
        }
    }
    if (!searched) return error.SearchNoWebSearch;
    if (hits.items.items.len == 0 and search_error.len > 0) {
        return if (std.mem.eql(u8, search_error, "too_many_requests")) error.SearchRateLimited else error.SearchServerError;
    }
    return hits.finish(answer.items);
}

fn attachSnippet(hits: *bank.HitList, title: []const u8, url: []const u8, cited: []const u8) !void {
    for (hits.items.items) |*hit| {
        if (!std.mem.eql(u8, hit.url, url)) continue;
        if (hit.snippet.len == 0 and cited.len > 0) {
            const owned = try hits.alloc.dupe(u8, cited[0..@min(cited.len, 400)]);
            hits.alloc.free(hit.snippet);
            hit.snippet = owned;
        }
        return;
    }
    try hits.add(title, url, cited[0..@min(cited.len, 400)], "");
}

test "anthropic body declares the web_search server tool" {
    var cancel = std.atomic.Value(bool).init(false);
    const body = try buildBody(std.testing.allocator, "claude-haiku-4-5", .{ .text = "zig", .blocked_domains = &.{"x.com"}, .cancel_flag = &cancel });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\":[{\"type\":\"web_search_20250305\",\"name\":\"web_search\",\"max_uses\":3,\"blocked_domains\":[\"x.com\"]}]") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    parsed.deinit();
}

test "anthropic response reads results, page age, and citations" {
    const fixture =
        \\{"id":"m","type":"message","model":"claude-haiku-4-5","content":[
        \\ {"type":"server_tool_use","id":"s1","name":"web_search","input":{"query":"zig"}},
        \\ {"type":"web_search_tool_result","tool_use_id":"s1","content":[
        \\   {"type":"web_search_result","url":"https://ziglang.org/news","title":"Zig news","page_age":"October 1, 2026","encrypted_content":"x"}]},
        \\ {"type":"text","text":"Zig 0.17 shipped.","citations":[{"type":"web_search_result_location","url":"https://ziglang.org/news","title":"Zig news","cited_text":"0.17 is out"}]}
        \\]}
    ;
    var answer = try parse(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Zig 0.17 shipped.", answer.text);
    try std.testing.expectEqualStrings("October 1, 2026", answer.hits[0].date);
    try std.testing.expectEqualStrings("0.17 is out", answer.hits[0].snippet);
}

test "anthropic search error maps to a fallback reason" {
    const fixture =
        \\{"content":[{"type":"web_search_tool_result","tool_use_id":"s1","content":{"type":"web_search_tool_result_error","error_code":"too_many_requests"}}]}
    ;
    try std.testing.expectError(error.SearchRateLimited, parse(std.testing.allocator, fixture));
    try std.testing.expectError(error.SearchNoWebSearch, parse(std.testing.allocator, "{\"content\":[{\"type\":\"text\",\"text\":\"no\"}]}"));
}
