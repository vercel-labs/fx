const std = @import("std");
const web_search_contract = @import("web_search_contract.zig");

/// Product-facing Gateway search backends advertised as `web_search`.
pub const SearchBackend = enum {
    exa,
    browserbase,
    parallel,
    perplexity,
    tako,

    pub const default: SearchBackend = .exa;

    pub fn slug(self: SearchBackend) []const u8 {
        return switch (self) {
            .exa => "exa",
            .browserbase => "browserbase",
            .parallel => "parallel",
            .perplexity => "perplexity",
            .tako => "tako",
        };
    }

    pub fn envId(self: SearchBackend) []const u8 {
        return switch (self) {
            .exa => "ai_gateway_exa_search",
            .browserbase => "ai_gateway_browserbase_search",
            .parallel => "ai_gateway_parallel_search",
            .perplexity => "ai_gateway_perplexity_search",
            .tako => "ai_gateway_tako_search",
        };
    }

    pub fn providerToolName(self: SearchBackend) []const u8 {
        return switch (self) {
            .exa => "exa_search",
            .browserbase => "browserbase_search",
            .parallel => "parallel_search",
            .perplexity => "perplexity_search",
            .tako => "tako_search",
        };
    }

    pub fn providerToolId(self: SearchBackend) []const u8 {
        return switch (self) {
            .exa => "gateway.exa_search",
            .browserbase => "gateway.browserbase_search",
            .parallel => "gateway.parallel_search",
            .perplexity => "gateway.perplexity_search",
            .tako => "gateway.tako_search",
        };
    }

    pub fn id(self: SearchBackend) web_search_contract.SearchBackendId {
        return .{ .value = self.envId() };
    }

    pub fn label(self: SearchBackend) []const u8 {
        return switch (self) {
            .exa => "Exa",
            .browserbase => "Browserbase",
            .parallel => "Parallel",
            .perplexity => "Perplexity",
            .tako => "Tako",
        };
    }
};

/// Product-facing fetch backends advertised as `web_fetch`.
pub const FetchBackend = enum {
    local,
    browserbase,

    pub const default: FetchBackend = .local;

    pub fn slug(self: FetchBackend) []const u8 {
        return switch (self) {
            .local => "local",
            .browserbase => "browserbase",
        };
    }

    pub fn envId(self: FetchBackend) []const u8 {
        return switch (self) {
            .local => "local",
            .browserbase => "ai_gateway_browserbase_fetch",
        };
    }

    pub fn providerToolName(self: FetchBackend) ?[]const u8 {
        return switch (self) {
            .local => null,
            .browserbase => "browserbase_fetch",
        };
    }

    pub fn providerToolId(self: FetchBackend) ?[]const u8 {
        return switch (self) {
            .local => null,
            .browserbase => "gateway.browserbase_fetch",
        };
    }

    pub fn label(self: FetchBackend) []const u8 {
        return switch (self) {
            .local => "local",
            .browserbase => "Browserbase",
        };
    }

    pub fn isProviderExecuted(self: FetchBackend) bool {
        return self == .browserbase;
    }
};

pub const search_slugs = [_][]const u8{
    SearchBackend.exa.slug(),
    SearchBackend.browserbase.slug(),
    SearchBackend.parallel.slug(),
    SearchBackend.perplexity.slug(),
    SearchBackend.tako.slug(),
};

pub const fetch_slugs = [_][]const u8{
    FetchBackend.local.slug(),
    FetchBackend.browserbase.slug(),
};

pub fn parseSearch(raw: []const u8) ?SearchBackend {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    inline for (std.meta.tags(SearchBackend)) |backend| {
        if (std.ascii.eqlIgnoreCase(trimmed, backend.slug()) or
            std.ascii.eqlIgnoreCase(trimmed, backend.envId()) or
            std.ascii.eqlIgnoreCase(trimmed, backend.providerToolName()))
        {
            return backend;
        }
    }
    return null;
}

pub fn parseFetch(raw: []const u8) ?FetchBackend {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    inline for (std.meta.tags(FetchBackend)) |backend| {
        if (std.ascii.eqlIgnoreCase(trimmed, backend.slug()) or
            std.ascii.eqlIgnoreCase(trimmed, backend.envId()))
        {
            return backend;
        }
        if (backend.providerToolName()) |name| {
            if (std.ascii.eqlIgnoreCase(trimmed, name)) return backend;
        }
    }
    return null;
}

pub fn resolveSearch(env_raw: ?[]const u8, settings: ?SearchBackend) error{InvalidWebSearchBackend}!SearchBackend {
    if (env_raw) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return parseSearch(trimmed) orelse error.InvalidWebSearchBackend;
    }
    return settings orelse .default;
}

pub fn resolveFetch(env_raw: ?[]const u8, settings: ?FetchBackend) error{InvalidWebFetchBackend}!FetchBackend {
    if (env_raw) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return parseFetch(trimmed) orelse error.InvalidWebFetchBackend;
    }
    return settings orelse .default;
}

pub fn isProviderSearchAlias(name: []const u8) bool {
    inline for (std.meta.tags(SearchBackend)) |backend| {
        if (std.mem.eql(u8, name, backend.providerToolName())) return true;
    }
    return false;
}

pub fn isProviderFetchAlias(name: []const u8) bool {
    inline for (std.meta.tags(FetchBackend)) |backend| {
        if (backend.providerToolName()) |alias| {
            if (std.mem.eql(u8, name, alias)) return true;
        }
    }
    return false;
}

pub const Selection = struct {
    search: SearchBackend = .default,
    fetch: FetchBackend = .default,

    pub fn summary(self: Selection, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            alloc,
            "{s} search, {s} fetch",
            .{ self.search.slug(), self.fetch.slug() },
        );
    }
};

pub const CommandPatch = struct {
    search: ?SearchBackend = null,
    fetch: ?FetchBackend = null,

    pub fn isEmpty(self: CommandPatch) bool {
        return self.search == null and self.fetch == null;
    }
};

pub const command_usage = "usage: /web [<search> [<fetch>]]";

/// Empty rest means show status. Invalid tokens fail instead of defaulting.
/// Accepts labeled `search <backend> [fetch <backend>]` and unlabeled
/// `/web <search> [fetch]` column tokens.
pub fn parseCommand(rest: []const u8) error{InvalidWebCommand}!?CommandPatch {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) return null;
    var patch = CommandPatch{};
    var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = tokens.next() orelse return error.InvalidWebCommand;
    if (std.ascii.eqlIgnoreCase(first, "search") or std.ascii.eqlIgnoreCase(first, "fetch")) {
        var word = first;
        while (true) {
            if (std.ascii.eqlIgnoreCase(word, "search")) {
                const value = tokens.next() orelse return error.InvalidWebCommand;
                patch.search = parseSearch(value) orelse return error.InvalidWebCommand;
            } else if (std.ascii.eqlIgnoreCase(word, "fetch")) {
                const value = tokens.next() orelse return error.InvalidWebCommand;
                patch.fetch = parseFetch(value) orelse return error.InvalidWebCommand;
            } else return error.InvalidWebCommand;
            word = tokens.next() orelse break;
        }
        if (patch.isEmpty()) return error.InvalidWebCommand;
        return patch;
    }

    patch.search = parseSearch(first) orelse return error.InvalidWebCommand;
    if (tokens.next()) |second| {
        patch.fetch = parseFetch(second) orelse return error.InvalidWebCommand;
        if (tokens.next() != null) return error.InvalidWebCommand;
    }
    return patch;
}

test "search parse accepts slugs, env ids, and provider names" {
    try std.testing.expectEqual(SearchBackend.exa, parseSearch("exa").?);
    try std.testing.expectEqual(SearchBackend.exa, parseSearch("ai_gateway_exa_search").?);
    try std.testing.expectEqual(SearchBackend.exa, parseSearch("exa_search").?);
    try std.testing.expectEqual(SearchBackend.browserbase, parseSearch("Browserbase").?);
    try std.testing.expectEqual(SearchBackend.tako, parseSearch("ai_gateway_tako_search").?);
    try std.testing.expect(parseSearch("") == null);
    try std.testing.expect(parseSearch("unknown") == null);
}

test "fetch parse accepts local and browserbase aliases" {
    try std.testing.expectEqual(FetchBackend.local, parseFetch("local").?);
    try std.testing.expectEqual(FetchBackend.browserbase, parseFetch("browserbase").?);
    try std.testing.expectEqual(FetchBackend.browserbase, parseFetch("ai_gateway_browserbase_fetch").?);
    try std.testing.expectEqual(FetchBackend.browserbase, parseFetch("browserbase_fetch").?);
    try std.testing.expect(parseFetch("exa") == null);
}

test "resolve prefers env over settings and defaults" {
    try std.testing.expectEqual(SearchBackend.exa, try resolveSearch(null, null));
    try std.testing.expectEqual(SearchBackend.parallel, try resolveSearch(null, .parallel));
    try std.testing.expectEqual(SearchBackend.tako, try resolveSearch("tako", .exa));
    try std.testing.expectEqual(SearchBackend.exa, try resolveSearch("  ", .exa));
    try std.testing.expectError(error.InvalidWebSearchBackend, resolveSearch("nope", .exa));

    try std.testing.expectEqual(FetchBackend.local, try resolveFetch(null, null));
    try std.testing.expectEqual(FetchBackend.browserbase, try resolveFetch(null, .browserbase));
    try std.testing.expectEqual(FetchBackend.browserbase, try resolveFetch("browserbase", .local));
    try std.testing.expectError(error.InvalidWebFetchBackend, resolveFetch("exa", .local));
}

test "provider aliases cover every advertised search and fetch name" {
    try std.testing.expect(isProviderSearchAlias("exa_search"));
    try std.testing.expect(isProviderSearchAlias("browserbase_search"));
    try std.testing.expect(isProviderSearchAlias("tako_search"));
    try std.testing.expect(!isProviderSearchAlias("web_search"));
    try std.testing.expect(isProviderFetchAlias("browserbase_fetch"));
    try std.testing.expect(!isProviderFetchAlias("web_fetch"));
}

test "web command parse accepts search and fetch pairs" {
    try std.testing.expect((try parseCommand("")) == null);
    try std.testing.expect((try parseCommand("   ")) == null);

    const search_only = (try parseCommand("search tako")).?;
    try std.testing.expectEqual(SearchBackend.tako, search_only.search.?);
    try std.testing.expect(search_only.fetch == null);

    const fetch_only = (try parseCommand("fetch browserbase")).?;
    try std.testing.expect(fetch_only.search == null);
    try std.testing.expectEqual(FetchBackend.browserbase, fetch_only.fetch.?);

    const both = (try parseCommand("search parallel fetch local")).?;
    try std.testing.expectEqual(SearchBackend.parallel, both.search.?);
    try std.testing.expectEqual(FetchBackend.local, both.fetch.?);

    try std.testing.expectError(error.InvalidWebCommand, parseCommand("search"));
    try std.testing.expectError(error.InvalidWebCommand, parseCommand("search nope"));

    const unlabeled_search = (try parseCommand("tako")).?;
    try std.testing.expectEqual(SearchBackend.tako, unlabeled_search.search.?);
    try std.testing.expect(unlabeled_search.fetch == null);

    const unlabeled_both = (try parseCommand("parallel browserbase")).?;
    try std.testing.expectEqual(SearchBackend.parallel, unlabeled_both.search.?);
    try std.testing.expectEqual(FetchBackend.browserbase, unlabeled_both.fetch.?);
}
