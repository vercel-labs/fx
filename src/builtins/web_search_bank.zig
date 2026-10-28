//! The web search provider bank in default priority order. Profile
//! settings `web_search.order` and `web_search.exclude` reorder and remove
//! providers; see `src/core/tooling/web_search_bank.zig`.
const std = @import("std");
const bank = @import("../core/tooling/web_search_bank.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const builtin_gateway = @import("gateway.zig");
const anthropic = @import("../gateway/search/anthropic.zig");
const brave = @import("../gateway/search/brave.zig");
const duckduckgo = @import("../gateway/search/duckduckgo.zig");
const exa = @import("../gateway/search/exa.zig");
const jina = @import("../gateway/search/jina.zig");
const kagi = @import("../gateway/search/kagi.zig");
const perplexity = @import("../gateway/search/perplexity.zig");
const responses_search = @import("../gateway/search/responses_search.zig");
const searxng = @import("../gateway/search/searxng.zig");
const tavily = @import("../gateway/search/tavily.zig");

const Allocator = std.mem.Allocator;

/// Priority order. Model-backed searches that synthesize an answer come
/// first, then search APIs, then the keyless scrapers.
pub const members = [_]bank.Member{
    vercel_member,
    responses_search.codex_member,
    responses_search.xai_member,
    anthropic.member,
    perplexity.member,
    exa.member,
    brave.member,
    tavily.member,
    jina.member,
    kagi.member,
    searxng.member,
    duckduckgo.member,
};

pub const default_bank = bank.Bank{
    .members = &members,
    .load_settings_fn = loadSettings,
};

fn loadSettings(alloc: Allocator) anyerror!bank.Settings {
    return config_runtime.loadWebSearchSettings(alloc);
}

/// The Vercel AI Gateway search worker, through the session's gateway
/// credential or AI_GATEWAY_API_KEY.
const vercel_member = bank.Member{
    .id = "vercel",
    .label = "Vercel AI Gateway",
    .needs = .sign_in_or_key,
    .available_fn = vercelAvailable,
    .search_fn = vercelSearch,
};

fn vercelAvailable(env: *const bank.Env) bool {
    return env.gateway_key != null or env.get("AI_GATEWAY_API_KEY") != null;
}

fn vercelSearch(alloc: Allocator, env: *const bank.Env, query: bank.Query) anyerror!bank.Answer {
    const inputs: web_search_provider.Inputs = env.gateway_inputs orelse .{
        .api_key = env.get("AI_GATEWAY_API_KEY") orelse return error.MissingSearchCredential,
        .credential_source = .ai_gateway_api_key,
        .worker_model = builtin_gateway.title_model,
        .gateway_retry_count = builtin_gateway.retry_count,
        .gateway_chat_url = builtin_gateway.defaultChatUrl(),
    };
    var response = try builtin_gateway.default_web_search_provider.execute(alloc, inputs, .{
        .backend = try builtin_gateway.selectedWebSearchBackend(),
        .query = query.text,
        .allowed_domains = if (query.allowed_domains.len > 0) query.allowed_domains else null,
        .blocked_domains = if (query.blocked_domains.len > 0) query.blocked_domains else null,
        .max_results = query.limit,
        .max_output_tokens = query.max_output_tokens,
        .timeout_ms = query.timeout_ms,
        .recency = query.recency,
        .cancel_flag = query.cancel_flag,
    }, null, null);
    defer response.deinit(alloc);
    return answerFromResponse(alloc, response.content);
}

/// Commentary becomes the answer and search blocks the hits; an error item
/// with nothing else fails the provider.
fn answerFromResponse(alloc: Allocator, items: []const web_search_contract.ResultItem) !bank.Answer {
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    var failed = false;
    for (items) |item| switch (item) {
        .commentary => |value| {
            if (text.items.len > 0) try text.appendSlice(alloc, "\n\n");
            try text.appendSlice(alloc, value);
        },
        .search => |block| for (block.content) |source| try hits.add(source.title, source.url, source.snippet, source.date),
        .error_text => failed = true,
        .terminal_incomplete => {},
    };
    if (failed and hits.items.items.len == 0 and text.items.len == 0) return error.SearchServerError;
    return hits.finish(text.items);
}

test "bank lists every provider once with the keyless scraper last" {
    for (members, 0..) |member, index| {
        for (members[0..index]) |previous| try std.testing.expect(!std.mem.eql(u8, previous.id, member.id));
    }
    try std.testing.expectEqualStrings("duckduckgo", members[members.len - 1].id);
    try std.testing.expect(members.len <= bank.max_members);
}

fn emptyEnv(_: ?*anyopaque, _: []const u8) ?[]const u8 {
    return null;
}

fn keyedEnv(_: ?*anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "BRAVE_API_KEY")) return "k";
    return null;
}

test "availability follows credentials and keeps duckduckgo as the keyless fallback" {
    var ids_buf: [bank.max_members][]const u8 = undefined;
    const keyless = bank.Env{ .env_fn = emptyEnv };
    const keyless_ids = bank.availableIds(&members, .{}, &keyless, &ids_buf);
    try std.testing.expectEqual(@as(usize, 1), keyless_ids.len);
    try std.testing.expectEqualStrings("duckduckgo", keyless_ids[0]);

    const codex = bank.Env{ .env_fn = keyedEnv, .chatgpt_token = "t" };
    const codex_ids = bank.availableIds(&members, .{}, &codex, &ids_buf);
    try std.testing.expectEqualStrings("codex", codex_ids[0]);
    try std.testing.expectEqualStrings("brave", codex_ids[1]);
    try std.testing.expectEqualStrings("duckduckgo", codex_ids[2]);

    var exclude = [_][]u8{@constCast("duckduckgo")};
    try std.testing.expect(!bank.anyAvailable(&members, .{ .exclude = &exclude }, &keyless));
}

test "gateway worker results convert to an answer" {
    const alloc = std.testing.allocator;
    const sources = [_]web_search_contract.Source{.{ .title = "Zig", .url = "https://ziglang.org" }};
    const items = [_]web_search_contract.ResultItem{
        .{ .commentary = "Found it." },
        .{ .search = .{ .tool_use_id = "s", .content = &sources } },
    };
    var answer = try answerFromResponse(alloc, &items);
    defer answer.deinit(alloc);
    try std.testing.expectEqualStrings("Found it.", answer.text);
    try std.testing.expectEqualStrings("https://ziglang.org", answer.hits[0].url);
    try std.testing.expectError(error.SearchServerError, answerFromResponse(alloc, &.{.{ .error_text = "boom" }}));
}

test {
    _ = @import("../gateway/search/http.zig");
    _ = anthropic;
    _ = brave;
    _ = duckduckgo;
    _ = exa;
    _ = jina;
    _ = kagi;
    _ = perplexity;
    _ = responses_search;
    _ = searxng;
    _ = tavily;
}
