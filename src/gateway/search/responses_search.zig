//! Side Responses requests that force the native `web_search` tool: Codex
//! through the ChatGPT subscription, and Grok through the Grok subscription
//! or XAI_API_KEY. Both stream the same event shapes, so one reader
//! collects the answer, the search call's sources, and the url citations.
const std = @import("std");
const bank = @import("../../core/tooling/web_search_bank.zig");
const io_mod = @import("../../core/shared/io.zig");
const chatgpt_oauth = @import("../../core/auth/chatgpt_oauth.zig");
const openai_codex = @import("../openai_codex.zig");
const openai_codex_models = @import("../openai_codex_models.zig");
const xai_grok = @import("../xai_grok.zig");
const xai_grok_models = @import("../xai_grok_models.zig");
const version_lookup = @import("../provider_versions.zig");
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

const instructions = "You are a web research assistant. Search the web to answer the user's query accurately, then answer briefly and cite your sources.";
const xai_api_endpoint = "https://api.x.ai/v1/responses";

pub const codex_member = bank.Member{
    .id = "codex",
    .label = "Codex",
    .available_fn = codexAvailable,
    .search_fn = codexSearch,
};

pub const xai_member = bank.Member{
    .id = "xai",
    .label = "Grok",
    .available_fn = xaiAvailable,
    .search_fn = xaiSearch,
};

fn codexAvailable(env: *const bank.Env) bool {
    return env.chatgpt_token != null;
}

fn xaiAvailable(env: *const bank.Env) bool {
    return env.grok_token != null or env.get("XAI_API_KEY") != null;
}

pub const Flavor = enum { codex, xai };

/// The request body. Codex takes instructions and the include list; Grok
/// takes a system message and native domain filters. The caller owns it.
pub fn buildBody(alloc: Allocator, flavor: Flavor, model: []const u8, query: bank.Query) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const text = switch (flavor) {
        // Codex's tool has no domain filters; operators carry them.
        .codex => try bank.queryWithSiteOperators(alloc, query),
        .xai => try alloc.dupe(u8, query.text),
    };
    defer alloc.free(text);
    const prompt = if (query.recency) |recency|
        try alloc.print("{s}\n\nOnly use sources published in the past {s}.", .{ text, @tagName(recency) })
    else
        try alloc.dupe(u8, text);
    defer alloc.free(prompt);
    try w.writeAll("{\"model\":");
    try http.writeJsonString(w, model);
    try w.writeAll(",\"stream\":true,\"store\":false");
    switch (flavor) {
        .codex => {
            try w.writeAll(",\"instructions\":");
            try http.writeJsonString(w, instructions);
            try w.writeAll(",\"include\":[\"web_search_call.action.sources\"],\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try http.writeJsonString(w, prompt);
            try w.writeAll("}]}],\"tools\":[{\"type\":\"web_search\",\"search_context_size\":\"high\"}],\"tool_choice\":{\"type\":\"web_search\"}");
        },
        .xai => {
            try w.writeAll(",\"input\":[{\"role\":\"system\",\"content\":");
            try http.writeJsonString(w, instructions);
            try w.writeAll("},{\"role\":\"user\",\"content\":");
            try http.writeJsonString(w, prompt);
            try w.writeAll("}],\"tools\":[{\"type\":\"web_search\"");
            const filter_field: ?[]const u8 = if (query.allowed_domains.len > 0) "allowed_domains" else if (query.blocked_domains.len > 0) "excluded_domains" else null;
            if (filter_field) |name| {
                const domains = if (query.allowed_domains.len > 0) query.allowed_domains else query.blocked_domains;
                try w.print(",\"filters\":{{\"{s}\":[", .{name});
                for (domains[0..@min(domains.len, 5)], 0..) |domain, index| {
                    if (index > 0) try w.writeAll(",");
                    try http.writeJsonString(w, bank.urlHost(domain));
                }
                try w.writeAll("]}");
            }
            try w.writeAll("}]");
        },
    }
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn codexSearch(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const token = env.chatgpt_token orelse return error.MissingSearchCredential;
    const account_id = if (env.chatgpt_account) |account| try alloc.dupe(u8, account) else try chatgpt_oauth.extractAccountId(alloc, token);
    defer alloc.free(account_id);
    const authorization = try alloc.print("Bearer {s}", .{token});
    defer alloc.free(authorization);
    const payload = try buildBody(alloc, .codex, openai_codex_models.reviewer_model, query);
    defer alloc.free(payload);
    var headers_buf: [openai_codex.max_extra_headers]std.http.Header = undefined;
    const headers = openai_codex.extraHeaders(&headers_buf, account_id, null);
    const body = try http.sendOk(alloc, .{
        .method = .post,
        .url = try openai_codex.responsesEndpoint(),
        .body = payload,
        .content_type = "application/json",
        .authorization = authorization,
        .headers = headers,
    }, query);
    defer alloc.free(body);
    return parse(alloc, body);
}

fn xaiSearch(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const model = xai_grok_models.title_model;
    const payload = try buildBody(alloc, .xai, model, query);
    defer alloc.free(payload);
    var headers_buf: [xai_grok.max_extra_headers]std.http.Header = undefined;
    var authorization: []u8 = undefined;
    var url: []const u8 = undefined;
    var headers: []std.http.Header = undefined;
    var version: ?@import("../../core/gateway/provider_versions.zig").Version = null;
    if (env.grok_token) |token| {
        authorization = try alloc.print("Bearer {s}", .{token});
        url = try xai_grok.responsesEndpoint();
        version = version_lookup.resolve(alloc, .grok, query.cancel_flag, null) catch null;
        headers = xai_grok.extraHeaders(&headers_buf, .{
            .subscription = true,
            .client_version = if (version) |*value| value.slice() else null,
            .model = model,
        });
    } else {
        const key = env.get("XAI_API_KEY") orelse return error.MissingSearchCredential;
        authorization = try alloc.print("Bearer {s}", .{key});
        url = xai_api_endpoint;
        headers_buf[0] = .{ .name = "accept", .value = "text/event-stream" };
        headers = headers_buf[0..1];
    }
    defer alloc.free(authorization);
    const body = try http.sendOk(alloc, .{
        .method = .post,
        .url = url,
        .body = payload,
        .content_type = "application/json",
        .authorization = authorization,
        .headers = headers,
    }, query);
    defer alloc.free(body);
    return parse(alloc, body);
}

/// Reads an event stream, or one JSON response, into an answer. A response
/// that never searched is an error so the chain moves on.
pub fn parse(alloc: Allocator, body: []const u8) !bank.Answer {
    var reader = Reader{ .alloc = alloc, .hits = bank.HitList.init(alloc) };
    defer reader.deinit();
    const trimmed = std.mem.trimStart(u8, body, " \r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') {
        var parsed = try http.parseJson(alloc, trimmed);
        defer parsed.deinit();
        try reader.response(parsed.value);
    } else {
        var events = std.mem.splitSequence(u8, body, "\n\n");
        while (events.next()) |event| {
            var data: std.ArrayList(u8) = .empty;
            defer data.deinit(alloc);
            var lines = std.mem.splitScalar(u8, event, '\n');
            while (lines.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                if (!std.mem.startsWith(u8, line, "data:")) continue;
                if (data.items.len > 0) try data.append(alloc, '\n');
                try data.appendSlice(alloc, std.mem.trimStart(u8, line["data:".len..], " "));
            }
            if (data.items.len == 0 or std.mem.eql(u8, data.items, "[DONE]")) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, data.items, .{}) catch continue;
            defer parsed.deinit();
            try reader.event(parsed.value);
        }
    }
    if (!reader.searched) return error.SearchNoWebSearch;
    const text = if (reader.answer.items.len > 0) reader.answer.items else reader.streamed.items;
    return reader.hits.finish(text);
}

const Reader = struct {
    alloc: Allocator,
    hits: bank.HitList,
    answer: std.ArrayList(u8) = .empty,
    streamed: std.ArrayList(u8) = .empty,
    searched: bool = false,

    fn deinit(self: *Reader) void {
        self.hits.deinit();
        self.answer.deinit(self.alloc);
        self.streamed.deinit(self.alloc);
    }

    fn event(self: *Reader, value: std.json.Value) !void {
        const kind = http.str(value, "type");
        if (std.mem.startsWith(u8, kind, "response.web_search_call")) self.searched = true;
        if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            try self.streamed.appendSlice(self.alloc, http.str(value, "delta"));
        } else if (std.mem.eql(u8, kind, "response.output_item.done")) {
            try self.item(http.get(value, "item"));
        } else if (std.mem.eql(u8, kind, "response.completed") or std.mem.eql(u8, kind, "response.done")) {
            if (self.answer.items.len == 0) try self.response(http.get(value, "response") orelse return);
        } else if (std.mem.eql(u8, kind, "error") or std.mem.eql(u8, kind, "response.failed")) {
            return classify(value);
        }
    }

    fn response(self: *Reader, value: std.json.Value) !void {
        if (http.get(value, "error")) |err| if (err == .object) return classify(value);
        for (http.arr(value, "output")) |output| try self.item(output);
        for (http.arr(value, "citations")) |citation| if (citation == .string) try self.hits.add("", citation.string, "", "");
    }

    fn item(self: *Reader, value: ?std.json.Value) !void {
        const kind = http.str(value, "type");
        if (std.mem.eql(u8, kind, "web_search_call")) {
            self.searched = true;
            const groups = [_][]const std.json.Value{ http.arr(http.get(value, "action"), "sources"), http.arr(value, "sources"), http.arr(value, "results") };
            for (groups) |group| for (group) |source| {
                try self.hits.add(http.firstStr(source, &.{ "title", "caption" }), http.firstStr(source, &.{ "url", "source_website_url" }), "", "");
            };
        } else if (std.mem.eql(u8, kind, "message")) {
            for (http.arr(value, "content")) |part| {
                const text = http.firstStr(part, &.{ "text", "output_text" });
                if (text.len == 0) continue;
                if (self.answer.items.len > 0) try self.answer.appendSlice(self.alloc, "\n\n");
                try self.answer.appendSlice(self.alloc, text);
                for (http.arr(part, "annotations")) |annotation| {
                    if (!std.mem.eql(u8, http.str(annotation, "type"), "url_citation")) continue;
                    const url = http.str(annotation, "url");
                    // A citation proves a search ran even when the call item is elided.
                    if (url.len > 0) self.searched = true;
                    try self.hits.add(http.str(annotation, "title"), url, citedText(text, annotation), "");
                }
            }
        }
    }
};

/// The sentence a citation annotates, bounded.
fn citedText(text: []const u8, annotation: std.json.Value) []const u8 {
    const start_value = http.get(annotation, "start_index") orelse return "";
    if (start_value != .integer) return "";
    const start: usize = @intCast(@max(0, @min(start_value.integer, @as(i64, @intCast(text.len)))));
    const before = std.mem.trimEnd(u8, text[0..start], " .\n");
    const sentence_start = if (std.mem.findLastAny(u8, before, ".\n")) |at| at + 1 else 0;
    const raw = std.mem.trim(u8, text[sentence_start..start], " \n([");
    return raw[raw.len -| 240..];
}

fn classify(value: std.json.Value) anyerror {
    const err = http.get(value, "error") orelse http.get(http.get(value, "response"), "error");
    const code = http.str(err, "code");
    const message = http.str(err, "message");
    var buf: [256]u8 = undefined;
    const detail = std.ascii.lowerString(&buf, (if (code.len > 0) code else message)[0..@min(@max(code.len, message.len), 256)]);
    if (std.mem.find(u8, detail, "rate") != null or std.mem.find(u8, detail, "quota") != null or std.mem.find(u8, detail, "429") != null) return error.SearchRateLimited;
    if (std.mem.find(u8, detail, "auth") != null or std.mem.find(u8, detail, "401") != null or std.mem.find(u8, detail, "403") != null) return error.SearchUnauthorized;
    return error.SearchServerError;
}

test "codex body forces the native web_search tool" {
    var cancel = std.atomic.Value(bool).init(false);
    const body = try buildBody(std.testing.allocator, .codex, "gpt-5.6-luna", .{ .text = "zig", .recency = .week, .cancel_flag = &cancel });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\":[{\"type\":\"web_search\",\"search_context_size\":\"high\"}]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"include\":[\"web_search_call.action.sources\"]") != null);
    try std.testing.expect(std.mem.find(u8, body, "past week") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    parsed.deinit();
}

test "grok body passes native domain filters" {
    var cancel = std.atomic.Value(bool).init(false);
    const body = try buildBody(std.testing.allocator, .xai, "grok-4.5", .{ .text = "zig", .allowed_domains = &.{"https://ziglang.org/"}, .cancel_flag = &cancel });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\":[{\"type\":\"web_search\",\"filters\":{\"allowed_domains\":[\"ziglang.org\"]}}]") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    parsed.deinit();
}

test "responses event stream yields sources, citations, and the answer" {
    const fixture =
        "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"r1\"}}\n\n" ++
        "data: {\"type\":\"response.web_search_call.searching\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"web_search_call\",\"action\":{\"type\":\"search\",\"sources\":[{\"type\":\"url\",\"url\":\"https://ziglang.org/news\"}]}}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Zig \"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Zig 0.17 shipped in October.\",\"annotations\":[{\"type\":\"url_citation\",\"url\":\"https://example.com/zig\",\"title\":\"Example\",\"start_index\":28,\"end_index\":40}]}]}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\"}}\n\n";
    var answer = try parse(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Zig 0.17 shipped in October.", answer.text);
    try std.testing.expectEqual(@as(usize, 2), answer.hits.len);
    try std.testing.expectEqualStrings("https://ziglang.org/news", answer.hits[0].title);
    try std.testing.expectEqualStrings("Example", answer.hits[1].title);
}

test "grok JSON response reads output items and top-level citations" {
    const fixture =
        \\{"id":"r","output":[{"type":"web_search_call","status":"completed"},
        \\ {"type":"message","content":[{"type":"output_text","text":"Answer.","annotations":[]}]}],
        \\ "citations":["https://x.ai/news"]}
    ;
    var answer = try parse(std.testing.allocator, fixture);
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Answer.", answer.text);
    try std.testing.expectEqualStrings("https://x.ai/news", answer.hits[0].url);
}

test "a response that never searched or failed moves the chain on" {
    try std.testing.expectError(error.SearchNoWebSearch, parse(std.testing.allocator, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n"));
    try std.testing.expectError(error.SearchRateLimited, parse(std.testing.allocator, "data: {\"type\":\"error\",\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"slow down\"}}\n\n"));
}
