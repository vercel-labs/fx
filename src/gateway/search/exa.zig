//! Exa search. With EXA_API_KEY it calls the search API; without one, a
//! search that names exa uses Exa's keyless MCP endpoint, which is rate
//! limited, so the automatic chain only includes exa when a key exists.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

const api_endpoint = "https://api.exa.ai/search";
const mcp_endpoint = "https://mcp.exa.ai/mcp";
const max_answer_summaries = 3;

pub const member = bank.Member{
    .id = "exa",
    .label = "Exa",
    .available_fn = available,
    .explicit_available_fn = explicitAvailable,
    .search_fn = search,
};

fn available(env: *const bank.Env) bool {
    return env.get("EXA_API_KEY") != null;
}

fn explicitAvailable(_: *const bank.Env) bool {
    return true;
}

/// The search API body. The caller owns it.
pub fn buildApiBody(alloc: Allocator, query: bank.Query, start_date: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"query\":");
    try http.writeJsonString(w, query.text);
    try w.print(",\"numResults\":{d},\"type\":\"auto\",\"contents\":{{\"summary\":{{\"query\":", .{query.limit});
    try http.writeJsonString(w, query.text);
    try w.writeAll("}}");
    try writeDomains(w, "includeDomains", query.allowed_domains);
    try writeDomains(w, "excludeDomains", query.blocked_domains);
    if (start_date) |date| try w.print(",\"startPublishedDate\":\"{s}\"", .{date});
    try w.writeAll("}");
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

/// The MCP `tools/call` body; filters become query operators. The caller owns it.
pub fn buildMcpBody(alloc: Allocator, query: bank.Query, start_date: ?[]const u8) ![]u8 {
    const base = try bank.queryWithSiteOperators(alloc, query);
    defer alloc.free(base);
    const text = if (start_date) |date| try alloc.print("{s} after:{s}", .{ base, date }) else try alloc.dupe(u8, base);
    defer alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"web_search_exa\",\"arguments\":{\"query\":");
    try http.writeJsonString(&out.writer, text);
    try out.writer.print(",\"numResults\":{d}}}}}}}", .{query.limit});
    return out.toOwnedSlice();
}

fn search(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    var date_buf: [10]u8 = undefined;
    const start_date = if (query.recency) |recency| http.recencyStartDate(&date_buf, recency) else null;
    if (env.get("EXA_API_KEY")) |key| {
        const payload = try buildApiBody(alloc, query, start_date);
        defer alloc.free(payload);
        const body = try http.sendOk(alloc, .{
            .method = .post,
            .url = api_endpoint,
            .body = payload,
            .content_type = "application/json",
            .headers = &.{.{ .name = "x-api-key", .value = key }},
        }, query);
        defer alloc.free(body);
        return parseApi(alloc, body);
    }
    const payload = try buildMcpBody(alloc, query, start_date);
    defer alloc.free(payload);
    const body = try http.sendOk(alloc, .{
        .method = .post,
        .url = mcp_endpoint ++ "?tools=web_search_exa",
        .body = payload,
        .content_type = "application/json",
        .headers = &.{
            .{ .name = "accept", .value = "application/json, text/event-stream" },
            .{ .name = "x-exa-source", .value = "proto" },
        },
    }, query);
    defer alloc.free(body);
    return parseMcp(alloc, body);
}

/// Results with their summaries; the first summaries form the answer.
pub fn parseApi(alloc: Allocator, body: []const u8) !bank.Answer {
    var parsed = try http.parseJson(alloc, body);
    defer parsed.deinit();
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    var answer: std.Io.Writer.Allocating = .init(alloc);
    defer answer.deinit();
    var summaries: usize = 0;
    for (http.arr(parsed.value, "results")) |result| {
        const summary = http.str(result, "summary");
        var highlights: std.Io.Writer.Allocating = .init(alloc);
        defer highlights.deinit();
        for (http.arr(result, "highlights")) |highlight| if (highlight == .string) {
            if (highlights.written().len > 0) try highlights.writer.writeAll(" ");
            try highlights.writer.writeAll(highlight.string);
        };
        const snippet_full = if (summary.len > 0) summary else if (http.str(result, "text").len > 0) http.str(result, "text") else highlights.written();
        const snippet = snippet_full[0..@min(snippet_full.len, 1000)];
        try hits.add(http.str(result, "title"), http.str(result, "url"), snippet, http.str(result, "publishedDate"));
        if (summary.len > 0 and summaries < max_answer_summaries) {
            if (summaries > 0) try answer.writer.writeAll("\n\n");
            const title = http.firstStr(result, &.{ "title", "url" });
            try answer.writer.print("**{s}**: {s}", .{ title, std.mem.trim(u8, summary, " \n") });
            summaries += 1;
        }
    }
    return hits.finish(answer.written());
}

/// The MCP reply is JSON or one SSE `data:` event whose text blocks hold
/// "Title:", "URL:", "Published Date:", and "Text:" sections.
pub fn parseMcp(alloc: Allocator, body: []const u8) !bank.Answer {
    const json_text = sseData(body) orelse body;
    var parsed = try http.parseJson(alloc, json_text);
    defer parsed.deinit();
    if (http.get(parsed.value, "error")) |err_value| {
        _ = err_value;
        return error.InvalidSearchResponse;
    }
    const result = http.get(parsed.value, "result");
    if (http.get(result, "isError")) |flag| if (flag == .bool and flag.bool) return error.SearchHttpError;
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    for (http.arr(result, "content")) |part| {
        const text = http.str(part, "text");
        var sections = std.mem.splitSequence(u8, text, "\nTitle: ");
        var first = true;
        while (sections.next()) |raw| {
            const was_first = first;
            first = false;
            const section = if (!was_first) raw else if (std.mem.startsWith(u8, raw, "Title: ")) raw["Title: ".len..] else continue;
            // A title may wrap onto several lines before the URL line.
            const title_end = std.mem.find(u8, section, "\nURL: ") orelse std.mem.findScalar(u8, section, '\n') orelse section.len;
            const title = try http.htmlText(alloc, section[0..title_end]);
            defer alloc.free(title);
            const published = labeledLine(section, "Published Date: ");
            const date = if (published.len > 0) published else labeledLine(section, "Published: ");
            try hits.add(
                title,
                labeledLine(section, "URL: "),
                textField(section),
                if (std.mem.eql(u8, date, "N/A")) "" else date,
            );
        }
    }
    return hits.finish("");
}

fn sseData(body: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "data:")) return std.mem.trim(u8, trimmed["data:".len..], " ");
    }
    return null;
}

fn labeledLine(section: []const u8, label: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, label)) return std.mem.trim(u8, line[label.len..], " \r");
    }
    return "";
}

/// The body after "Text:" or "Highlights:", bounded.
fn textField(section: []const u8) []const u8 {
    const markers = [_][]const u8{ "\nText: ", "\nHighlights:\n", "\nHighlights: " };
    for (markers) |marker| {
        const at = std.mem.find(u8, section, marker) orelse continue;
        const text = std.mem.trim(u8, section[at + marker.len ..], " \r\n");
        return text[0..@min(text.len, 1000)];
    }
    return "";
}

test "exa api body uses native filters and summaries" {
    var cancel = std.atomic.Value(bool).init(false);
    const body = try buildApiBody(std.testing.allocator, .{ .text = "zig", .limit = 4, .allowed_domains = &.{"ziglang.org"}, .cancel_flag = &cancel }, "2026-10-01");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"query\":\"zig\",\"numResults\":4,\"type\":\"auto\",\"contents\":{\"summary\":{\"query\":\"zig\"}},\"includeDomains\":[\"ziglang.org\"],\"startPublishedDate\":\"2026-10-01\"}",
        body,
    );
}

test "exa mcp body is a tools call with operators" {
    var cancel = std.atomic.Value(bool).init(false);
    const body = try buildMcpBody(std.testing.allocator, .{ .text = "zig", .limit = 3, .blocked_domains = &.{"x.com"}, .cancel_flag = &cancel }, null);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"web_search_exa\",\"arguments\":{\"query\":\"zig -site:x.com\",\"numResults\":3}}}",
        body,
    );
}

test "exa api response synthesizes an answer from summaries" {
    const fixture =
        \\{"requestId":"r","results":[{"title":"Zig","url":"https://ziglang.org","publishedDate":"2026-10-01T00:00:00.000Z","summary":"A language."},
        \\ {"title":"Blog","url":"https://blog.example/z","highlights":["one","two"]}]}
    ;
    var answer = try parseApi(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("**Zig**: A language.", answer.text);
    try std.testing.expectEqualStrings("one two", answer.hits[1].snippet);
    try std.testing.expectEqualStrings("2026-10-01T00:00:00.000Z", answer.hits[0].date);
}

test "exa mcp response parses text sections from an SSE event" {
    const fixture = "event: message\ndata: {\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Title: Zig 0.17\\nURL: https://ziglang.org/news\\nPublished Date: 2026-10-01\\nAuthor: Zig\\nText: Release notes here.\\n\\nTitle: Second\\nURL: https://example.com/2\\nText: More.\"}]},\"jsonrpc\":\"2.0\",\"id\":1}\n\n";
    var answer = try parseMcp(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), answer.hits.len);
    try std.testing.expectEqualStrings("Zig 0.17", answer.hits[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org/news", answer.hits[0].url);
    try std.testing.expectEqualStrings("2026-10-01", answer.hits[0].date);
    try std.testing.expectEqualStrings("Release notes here.", answer.hits[0].snippet);
    try std.testing.expectEqualStrings("More.", answer.hits[1].snippet);
}

test "exa mcp response handles wrapped titles and highlights" {
    const fixture = "data: {\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Title: Home\\n      Zig Programming Language\\nURL: https://ziglang.org/\\nPublished: N/A\\nAuthor: N/A\\nHighlights:\\nZig is a general-purpose language.\"}]}}\n\n";
    var answer = try parseMcp(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Home Zig Programming Language", answer.hits[0].title);
    try std.testing.expectEqualStrings("", answer.hits[0].date);
    try std.testing.expectEqualStrings("Zig is a general-purpose language.", answer.hits[0].snippet);
}
