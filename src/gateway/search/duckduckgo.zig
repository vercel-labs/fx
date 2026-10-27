//! DuckDuckGo's HTML endpoint, the keyless last resort. It throttles
//! automated traffic from shared addresses; a challenge page is reported as
//! blocked so the chain moves on.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

const endpoint = "https://html.duckduckgo.com/html/";
const browser_user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

pub const member = bank.Member{
    .id = "duckduckgo",
    .label = "DuckDuckGo",
    .available_fn = available,
    .search_fn = search,
};

fn available(_: *const bank.Env) bool {
    return true;
}

/// The form body: query with site operators, US English, recency as `df`.
/// The caller owns it.
pub fn buildForm(alloc: Allocator, query: bank.Query) ![]u8 {
    const text = try bank.queryWithSiteOperators(alloc, query);
    defer alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("q=");
    try http.writeQueryComponent(&out.writer, text);
    try out.writer.writeAll("&kl=us-en&b=");
    if (query.recency) |recency| try out.writer.print("&df={c}", .{@tagName(recency)[0]});
    return out.toOwnedSlice();
}

fn search(alloc: Allocator, _: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const form = try buildForm(alloc, query);
    defer alloc.free(form);
    const body = try http.sendOk(alloc, .{
        .method = .post,
        .url = endpoint,
        .body = form,
        .content_type = "application/x-www-form-urlencoded",
        .user_agent = browser_user_agent,
        .headers = &.{
            .{ .name = "accept", .value = "text/html,application/xhtml+xml" },
            .{ .name = "accept-language", .value = "en-US,en;q=0.9" },
            .{ .name = "referer", .value = "https://html.duckduckgo.com/" },
        },
    }, query);
    defer alloc.free(body);
    return parse(alloc, body, query.limit);
}

/// Splits the page on result blocks and reads the title link, the
/// snippet, and a dated extras span. Redirect links are unwrapped.
pub fn parse(alloc: Allocator, html: []const u8, limit: u8) !bank.Answer {
    if (std.mem.find(u8, html, "anomaly-modal") != null or std.mem.find(u8, html, "anomaly.js") != null) {
        return error.SearchBlocked;
    }
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    var rest = html;
    while (findClass(rest, "result__a")) |anchor_start| {
        if (hits.items.items.len >= limit) break;
        const block_end = if (findClass(rest[anchor_start + 1 ..], "result__a")) |next| anchor_start + 1 + next else rest.len;
        const block = rest[anchor_start..block_end];
        rest = rest[block_end..];
        const href = attribute(block, "href") orelse continue;
        const title_html = innerText(block) orelse continue;
        const url = try unwrapUrl(alloc, href) orelse continue;
        defer alloc.free(url);
        const title = try http.htmlText(alloc, title_html);
        defer alloc.free(title);
        if (title.len == 0) continue;
        const snippet = if (findClass(block, "result__snippet")) |at| try http.htmlText(alloc, innerText(block[at..]) orelse "") else try alloc.dupe(u8, "");
        defer alloc.free(snippet);
        try hits.add(title, url, snippet, extrasDate(block));
    }
    return hits.finish("");
}

/// Index of the tag whose class list contains `class`, at its `<`.
fn findClass(html: []const u8, class: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.findPos(u8, html, from, class)) |at| {
        from = at + class.len;
        const after = if (at + class.len < html.len) html[at + class.len] else ' ';
        const before = if (at > 0) html[at - 1] else ' ';
        if (!(before == '"' or before == ' ') or !(after == '"' or after == ' ')) continue;
        const tag = std.mem.findScalarLast(u8, html[0..at], '<') orelse continue;
        if (std.mem.findScalar(u8, html[tag..at], '>') != null) continue;
        return tag;
    }
    return null;
}

fn attribute(tag_html: []const u8, name: []const u8) ?[]const u8 {
    const tag_end = std.mem.findScalar(u8, tag_html, '>') orelse return null;
    const tag = tag_html[0..tag_end];
    var from: usize = 0;
    while (std.mem.findPos(u8, tag, from, name)) |at| {
        from = at + name.len;
        if (at == 0 or tag[at - 1] != ' ') continue;
        var i = at + name.len;
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        if (i >= tag.len or (tag[i] != '"' and tag[i] != '\'')) continue;
        const quote = tag[i];
        const end = std.mem.findScalarPos(u8, tag, i + 1, quote) orelse return null;
        return tag[i + 1 .. end];
    }
    return null;
}

/// The content between the element starting at `html[0]` and its closing tag.
fn innerText(html: []const u8) ?[]const u8 {
    const open_end = std.mem.findScalar(u8, html, '>') orelse return null;
    const name_end = std.mem.findAny(u8, html[1..], " >") orelse return null;
    const name = html[1 .. 1 + name_end];
    var close_buf: [16]u8 = undefined;
    const close = std.mem.print(&close_buf, "</{s}>", .{name}) catch return null;
    const end = std.mem.findPos(u8, html, open_end + 1, close) orelse return null;
    return html[open_end + 1 .. end];
}

/// `//duckduckgo.com/l/?uddg=<encoded>&rut=...` becomes the target URL.
fn unwrapUrl(alloc: Allocator, href_raw: []const u8) !?[]u8 {
    const href = try http.htmlText(alloc, href_raw);
    defer alloc.free(href);
    if (std.mem.find(u8, href, "uddg=")) |at| {
        const start = at + "uddg=".len;
        const end = std.mem.findScalarPos(u8, href, start, '&') orelse href.len;
        return try http.percentDecode(alloc, href[start..end]);
    }
    if (std.mem.startsWith(u8, href, "//")) return try alloc.print("https:{s}", .{href});
    if (std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://")) return try alloc.dupe(u8, href);
    return null;
}

/// A "YYYY-MM-DD" date in the result's extras line, if any.
fn extrasDate(block: []const u8) []const u8 {
    const at = findClass(block, "result__extras__url") orelse return "";
    const extras = block[at..@min(block.len, at + 600)];
    var i: usize = 0;
    while (i + 10 <= extras.len) : (i += 1) {
        const candidate = extras[i .. i + 10];
        if (std.ascii.isDigit(candidate[0]) and std.ascii.isDigit(candidate[3]) and candidate[4] == '-' and candidate[7] == '-' and
            std.ascii.isDigit(candidate[5]) and std.ascii.isDigit(candidate[9]))
            return candidate;
    }
    return "";
}

test "duckduckgo form carries the query, locale, and recency" {
    var cancel = std.atomic.Value(bool).init(false);
    const form = try buildForm(std.testing.allocator, .{ .text = "zig lang", .recency = .week, .cancel_flag = &cancel });
    defer std.testing.allocator.free(form);
    try std.testing.expectEqualStrings("q=zig%20lang&kl=us-en&b=&df=w", form);
}

test "duckduckgo html results unwrap redirect links and read snippets" {
    const fixture =
        \\<div class="results">
        \\<div class="result results_links results_links_deep web-result ">
        \\  <div class="links_main links_deep result__body">
        \\    <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2Fdownload%2F&amp;rut=abc">Download &amp; <b>Zig</b></a></h2>
        \\    <div class="result__extras"><div class="result__extras__url"><a class="result__url" href="x">ziglang.org</a><span>2026-10-01T00:00:00</span></div></div>
        \\    <a class="result__snippet" href="x">Get <b>Zig</b> 0.17 here.</a>
        \\  </div>
        \\</div>
        \\<div class="result results_links web-result ">
        \\    <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://example.com/b">Second</a></h2>
        \\    <div class="result__snippet">Plain snippet</div>
        \\</div>
        \\</div>
    ;
    var answer = try parse(std.testing.allocator, fixture, 10);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), answer.hits.len);
    try std.testing.expectEqualStrings("Download & Zig", answer.hits[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org/download/", answer.hits[0].url);
    try std.testing.expectEqualStrings("Get Zig 0.17 here.", answer.hits[0].snippet);
    try std.testing.expectEqualStrings("2026-10-01", answer.hits[0].date);
    try std.testing.expectEqualStrings("Plain snippet", answer.hits[1].snippet);
}

test "duckduckgo challenge page is reported as blocked" {
    try std.testing.expectError(error.SearchBlocked, parse(std.testing.allocator, "<div class=\"anomaly-modal__title\">", 10));
}
