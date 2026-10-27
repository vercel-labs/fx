//! `proto-fx search <query> [--provider X] [--recency R] [--limit N] [--json]`:
//! runs the web search provider bank once and prints one snapshot.
const std = @import("std");
const bank = @import("../tooling/web_search_bank.zig");
const credentials = @import("../auth/credentials.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const host = @import("../hosts/host.zig");
const output_contracts = @import("../output/output_contracts.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    query: []u8,
    provider: ?[]const u8 = null,
    recency: ?bank.Recency = null,
    limit: u8 = bank.default_limit,
    format: output_contracts.OutputFormat = .text,

    pub fn deinit(self: *Options, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = undefined;
    }
};

pub const ParseError = error{ MissingSearchQuery, InvalidSearchOption, OutOfMemory };

/// Query words are joined with spaces; `--` ends option parsing.
pub fn parseArgs(alloc: Allocator, args: []const [:0]const u8) ParseError!Options {
    var words: std.ArrayList(u8) = .empty;
    defer words.deinit(alloc);
    var options: Options = .{ .query = &.{} };
    var index: usize = 0;
    var options_done = false;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (!options_done and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--")) {
                options_done = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                options.format = .json;
            } else if (std.mem.eql(u8, arg, "--provider")) {
                index += 1;
                if (index >= args.len) return error.InvalidSearchOption;
                options.provider = args[index];
            } else if (std.mem.eql(u8, arg, "--recency")) {
                index += 1;
                if (index >= args.len) return error.InvalidSearchOption;
                options.recency = bank.Recency.parse(args[index]) orelse return error.InvalidSearchOption;
            } else if (std.mem.eql(u8, arg, "--limit")) {
                index += 1;
                if (index >= args.len) return error.InvalidSearchOption;
                const limit = std.fmt.parseInt(u8, args[index], 10) catch return error.InvalidSearchOption;
                if (limit < 1 or limit > bank.max_limit) return error.InvalidSearchOption;
                options.limit = limit;
            } else {
                return error.InvalidSearchOption;
            }
            continue;
        }
        if (words.items.len > 0) try words.append(alloc, ' ');
        try words.appendSlice(alloc, arg);
    }
    const query = std.mem.trim(u8, words.items, " \t\r\n");
    if (query.len < 2) return error.MissingSearchQuery;
    options.query = try alloc.dupe(u8, query);
    return options;
}

/// Sources of stored subscription credentials. Reading them can touch the
/// system keychain, so only a search that names codex or xai does.
pub const CredentialAccess = struct {
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
};

pub const Result = struct {
    output: []u8,
    format: output_contracts.OutputFormat,
    succeeded: bool,
};

/// Runs the search. The caller owns `output`.
pub fn run(
    alloc: Allocator,
    the_bank: *const bank.Bank,
    options: Options,
    access: ?CredentialAccess,
) !Result {
    var settings = the_bank.loadSettings(alloc);
    defer settings.deinit(alloc);
    var env = bank.envFromInputs(null, settings);

    var stored: ?credentials.Credential = null;
    defer if (stored) |*credential| credential.deinit(alloc);
    if (options.provider) |forced| if (access) |source| {
        const target: ?@import("../config/model_provider.zig").ProviderId = if (std.ascii.eqlIgnoreCase(forced, "codex"))
            .codex
        else if (std.ascii.eqlIgnoreCase(forced, "xai"))
            .grok
        else
            null;
        if (target) |provider| {
            const resolution = credentials.resolveForProvider(alloc, source.transport, source.secret_store, .refresh_if_needed, provider, null) catch null;
            if (resolution) |value| stored = value.credential;
            if (stored) |credential| switch (provider) {
                .codex => {
                    env.chatgpt_token = credential.token;
                    env.chatgpt_account = credential.accountId();
                },
                else => env.grok_token = credential.token,
            };
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    const query = bank.Query{
        .text = options.query,
        .recency = options.recency,
        .limit = options.limit,
        .timeout_ms = 60_000,
        .cancel_flag = &cancel,
    };
    var outcome = bank.run(alloc, the_bank.members, settings, &env, query, options.provider) catch |err| {
        const message = try failureMessage(alloc, err, options.provider);
        defer alloc.free(message);
        const snapshot = output_contracts.WebSearchSnapshot{ .query = options.query, .recency = options.recency, .limit = options.limit, .error_message = message };
        return .{ .output = try snapshot.render(alloc, options.format), .format = options.format, .succeeded = false };
    };
    defer outcome.deinit(alloc);
    const snapshot = output_contracts.WebSearchSnapshot.fromOutcome(options.query, options.recency, options.limit, &outcome);
    return .{ .output = try snapshot.render(alloc, options.format), .format = options.format, .succeeded = snapshot.succeeded() };
}

fn failureMessage(alloc: Allocator, err: anyerror, provider: ?[]const u8) ![]u8 {
    const name = provider orelse "";
    return switch (err) {
        error.UnknownWebSearchProvider => alloc.print("unknown provider: {s}", .{name}),
        error.WebSearchProviderExcluded => alloc.print("{s} is excluded by web_search.exclude", .{name}),
        error.WebSearchProviderUnavailable => alloc.print("{s} is not configured; set its API key or sign in", .{name}),
        error.NoWebSearchProvider => alloc.dupe(u8, "no web search provider is available"),
        else => alloc.dupe(u8, @errorName(err)),
    };
}

test "search arguments join query words and read options" {
    const alloc = std.testing.allocator;
    var options = try parseArgs(alloc, &.{ "zig", "--provider", "brave", "release", "--recency", "week", "--limit", "5", "--json", "--", "--notes" });
    defer options.deinit(alloc);
    try std.testing.expectEqualStrings("zig release --notes", options.query);
    try std.testing.expectEqualStrings("brave", options.provider.?);
    try std.testing.expectEqual(bank.Recency.week, options.recency.?);
    try std.testing.expectEqual(@as(u8, 5), options.limit);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, options.format);
}

test "search arguments reject bad options and missing queries" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MissingSearchQuery, parseArgs(alloc, &.{"--json"}));
    try std.testing.expectError(error.InvalidSearchOption, parseArgs(alloc, &.{ "zig", "--limit", "50" }));
    try std.testing.expectError(error.InvalidSearchOption, parseArgs(alloc, &.{ "zig", "--recency", "hour" }));
    try std.testing.expectError(error.InvalidSearchOption, parseArgs(alloc, &.{ "zig", "--provider" }));
    try std.testing.expectError(error.InvalidSearchOption, parseArgs(alloc, &.{ "zig", "--fast" }));
}

fn failingSearch(_: Allocator, _: *const bank.Env, _: bank.Query) anyerror!bank.Answer {
    return error.SearchRateLimited;
}

fn goodSearch(alloc: Allocator, _: *const bank.Env, _: bank.Query) anyerror!bank.Answer {
    var hits = bank.HitList.init(alloc);
    defer hits.deinit();
    try hits.add("Zig", "https://ziglang.org", "", "");
    return hits.finish("");
}

fn always(_: *const bank.Env) bool {
    return true;
}

test "search run falls back and reports the answering provider in JSON" {
    const alloc = std.testing.allocator;
    const members = [_]bank.Member{
        .{ .id = "first", .label = "First", .available_fn = always, .search_fn = failingSearch },
        .{ .id = "second", .label = "Second", .available_fn = always, .search_fn = goodSearch },
    };
    const test_bank = bank.Bank{ .members = &members };
    var query = "zig lang".*;
    const result = try run(alloc, &test_bank, .{ .query = &query, .format = .json }, null);
    defer alloc.free(result.output);
    try std.testing.expect(result.succeeded);
    try std.testing.expect(std.mem.find(u8, result.output, "\"provider\":\"second\"") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "\"failures\":[{\"provider\":\"first\",\"reason\":\"rate limited (HTTP 429)\"}]") != null);

    const unknown = try run(alloc, &test_bank, .{ .query = &query, .provider = "nope" }, null);
    defer alloc.free(unknown.output);
    try std.testing.expect(!unknown.succeeded);
    try std.testing.expectEqualStrings("search failed: unknown provider: nope\n", unknown.output);
}
