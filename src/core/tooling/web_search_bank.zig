//! The web search provider bank: an ordered chain of search providers, each
//! available or not from the credentials at hand. A search tries the
//! available providers in order and falls back to the next one when a
//! provider fails, is rate limited, or finds nothing. Transports live in
//! `src/gateway/search/`; `src/builtins/web_search_bank.zig` lists them.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_search_policy = @import("web_search_policy.zig");
const web_search_provider = @import("web_search_provider.zig");

const Allocator = std.mem.Allocator;

pub const Recency = web_search_contract.Recency;
pub const default_limit: u8 = 10;
pub const max_limit: u8 = 20;
pub const max_members = 16;
const max_settings_entries = 32;
const max_failure_reason_bytes = 240;

/// One normalized result. Every field is owned; `snippet` and `date` are
/// empty when the provider gave none.
pub const Hit = struct {
    title: []u8,
    url: []u8,
    snippet: []u8 = &.{},
    date: []u8 = &.{},

    pub fn deinit(self: Hit, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.url);
        alloc.free(self.snippet);
        alloc.free(self.date);
    }
};

/// What one provider returned: an optional synthesized answer and its hits.
pub const Answer = struct {
    text: []u8 = &.{},
    hits: []Hit = &.{},

    pub fn deinit(self: *Answer, alloc: Allocator) void {
        alloc.free(self.text);
        for (self.hits) |hit| hit.deinit(alloc);
        alloc.free(self.hits);
        self.* = .{};
    }

    pub fn isEmpty(self: Answer) bool {
        return self.hits.len == 0 and std.mem.trim(u8, self.text, " \t\r\n").len == 0;
    }
};

/// Accumulates hits for a transport parser. Strings passed to `add` are
/// borrowed and copied; an empty url is skipped and an empty title falls
/// back to the url.
pub const HitList = struct {
    alloc: Allocator,
    items: std.ArrayList(Hit) = .empty,

    pub fn init(alloc: Allocator) HitList {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *HitList) void {
        for (self.items.items) |hit| hit.deinit(self.alloc);
        self.items.deinit(self.alloc);
    }

    pub fn add(self: *HitList, title: []const u8, url: []const u8, snippet: []const u8, date: []const u8) !void {
        const clean_url = std.mem.trim(u8, url, " \t\r\n");
        if (clean_url.len == 0) return;
        for (self.items.items) |existing| if (std.mem.eql(u8, existing.url, clean_url)) return;
        const clean_title = collapse(title);
        const owned_url = try self.alloc.dupe(u8, clean_url);
        errdefer self.alloc.free(owned_url);
        const owned_title = try self.alloc.dupe(u8, if (clean_title.len > 0) clean_title else clean_url);
        errdefer self.alloc.free(owned_title);
        const owned_snippet = try self.alloc.dupe(u8, std.mem.trim(u8, snippet, " \t\r\n"));
        errdefer self.alloc.free(owned_snippet);
        const owned_date = try self.alloc.dupe(u8, std.mem.trim(u8, date, " \t\r\n"));
        errdefer self.alloc.free(owned_date);
        try self.items.append(self.alloc, .{ .title = owned_title, .url = owned_url, .snippet = owned_snippet, .date = owned_date });
    }

    /// Moves the hits and `text` (borrowed, copied) into an Answer.
    pub fn finish(self: *HitList, text: []const u8) !Answer {
        const owned_text = try self.alloc.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
        errdefer self.alloc.free(owned_text);
        const hits = try self.items.toOwnedSlice(self.alloc);
        return .{ .text = owned_text, .hits = hits };
    }

    fn collapse(text: []const u8) []const u8 {
        return std.mem.trim(u8, text, " \t\r\n");
    }
};

pub const Query = struct {
    text: []const u8,
    recency: ?Recency = null,
    limit: u8 = default_limit,
    allowed_domains: []const []const u8 = &.{},
    blocked_domains: []const []const u8 = &.{},
    timeout_ms: u32 = 30_000,
    max_output_tokens: u32 = 4096,
    cancel_flag: *std.atomic.Value(bool),
};

/// A configured Anthropic-compatible endpoint: Messages API prefix and key.
pub const AnthropicEndpoint = struct {
    base_url: []const u8,
    key: []const u8,
    /// Sends the key as a bearer token instead of `x-api-key`.
    bearer: bool = false,
};

pub const EnvFn = *const fn (?*anyopaque, []const u8) ?[]const u8;

/// Everything a provider may authenticate with. All fields are borrowed for
/// one search. `env` reads environment variables; tests replace it.
pub const Env = struct {
    chatgpt_token: ?[]const u8 = null,
    chatgpt_account: ?[]const u8 = null,
    grok_token: ?[]const u8 = null,
    gateway_key: ?[]const u8 = null,
    gateway_inputs: ?web_search_provider.Inputs = null,
    anthropic: ?AnthropicEndpoint = null,
    searxng_url: ?[]const u8 = null,
    env_ctx: ?*anyopaque = null,
    env_fn: EnvFn = processEnv,

    /// A nonempty environment value, or null.
    pub fn get(self: *const Env, name: []const u8) ?[]const u8 {
        const value = self.env_fn(self.env_ctx, name) orelse return null;
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        return if (trimmed.len == 0) null else trimmed;
    }

    pub fn anthropicEndpoint(self: *const Env) ?AnthropicEndpoint {
        if (self.anthropic) |endpoint| return endpoint;
        const key = self.get("ANTHROPIC_API_KEY") orelse return null;
        return .{ .base_url = "https://api.anthropic.com/v1", .key = key };
    }

    pub fn searxngUrl(self: *const Env) ?[]const u8 {
        return self.searxng_url orelse self.get("SEARXNG_ENDPOINT");
    }
};

fn processEnv(_: ?*anyopaque, name: []const u8) ?[]const u8 {
    return io_mod.getenv(name);
}

pub const Member = struct {
    /// Stable lowercase id used in settings, `--provider`, and output.
    id: []const u8,
    label: []const u8,
    available_fn: *const fn (*const Env) bool,
    /// Availability when a person names this provider; defaults to `available_fn`.
    explicit_available_fn: ?*const fn (*const Env) bool = null,
    search_fn: *const fn (Allocator, *const Env, Query) anyerror!Answer,

    pub fn available(self: *const Member, env: *const Env, explicit: bool) bool {
        if (explicit) if (self.explicit_available_fn) |explicit_fn| return explicit_fn(env);
        return self.available_fn(env);
    }
};

/// Profile settings under `web_search`. Owned.
pub const Settings = struct {
    /// Providers to try first, in this order; the remaining defaults follow.
    order: [][]u8 = &.{},
    /// Providers never tried.
    exclude: [][]u8 = &.{},
    searxng_url: ?[]u8 = null,

    pub fn deinit(self: *Settings, alloc: Allocator) void {
        freeStrings(alloc, self.order);
        freeStrings(alloc, self.exclude);
        if (self.searxng_url) |value| alloc.free(value);
        self.* = .{};
    }

    fn excludes(self: Settings, id: []const u8) bool {
        return containsString(self.exclude, id);
    }
};

pub const SettingsError = error{ InvalidWebSearchSettings, OutOfMemory };

/// Parses the profile `web_search` object. The caller owns the result.
pub fn parseSettings(alloc: Allocator, value: std.json.Value) SettingsError!Settings {
    if (value != .object) return error.InvalidWebSearchSettings;
    var settings: Settings = .{};
    errdefer settings.deinit(alloc);
    if (value.object.get("order")) |order| settings.order = try parseIdList(alloc, order);
    if (value.object.get("exclude")) |exclude| settings.exclude = try parseIdList(alloc, exclude);
    if (value.object.get("searxng_url")) |url| {
        if (url != .string) return error.InvalidWebSearchSettings;
        const trimmed = std.mem.trim(u8, url.string, " \t\r\n");
        if (trimmed.len > 0) settings.searxng_url = try alloc.dupe(u8, trimmed);
    }
    return settings;
}

fn parseIdList(alloc: Allocator, value: std.json.Value) SettingsError![][]u8 {
    if (value != .array) return error.InvalidWebSearchSettings;
    if (value.array.items.len > max_settings_entries) return error.InvalidWebSearchSettings;
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| alloc.free(item);
        list.deinit(alloc);
    }
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidWebSearchSettings;
        const id = std.mem.trim(u8, item.string, " \t\r\n");
        if (id.len == 0 or containsString(list.items, id)) continue;
        const owned = try std.ascii.allocLowerString(alloc, id);
        errdefer alloc.free(owned);
        try list.append(alloc, owned);
    }
    return list.toOwnedSlice(alloc);
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.ascii.eqlIgnoreCase(value, needle)) return true;
    return false;
}

pub fn findMember(members: []const Member, id: []const u8) ?*const Member {
    for (members) |*member| if (std.ascii.eqlIgnoreCase(member.id, id)) return member;
    return null;
}

pub const Candidate = struct {
    member: *const Member,
    explicit: bool,
};

/// The providers to consider, in order: `forced` alone when given, otherwise
/// the configured order followed by the remaining defaults, minus exclusions.
pub fn candidates(
    members: []const Member,
    settings: Settings,
    forced: ?*const Member,
    out: *[max_members]Candidate,
) []Candidate {
    var count: usize = 0;
    if (forced) |member| {
        if (settings.excludes(member.id)) return out[0..0];
        out[0] = .{ .member = member, .explicit = true };
        return out[0..1];
    }
    for (settings.order) |id| {
        const member = findMember(members, id) orelse continue;
        if (settings.excludes(member.id) or count == out.len) continue;
        out[count] = .{ .member = member, .explicit = true };
        count += 1;
    }
    for (members) |*member| {
        if (settings.excludes(member.id) or containsString(settings.order, member.id) or count == out.len) continue;
        out[count] = .{ .member = member, .explicit = false };
        count += 1;
    }
    return out[0..count];
}

/// Ids of the providers a search would try now, in order. Borrowed from `members`.
pub fn availableIds(
    members: []const Member,
    settings: Settings,
    env: *const Env,
    out: *[max_members][]const u8,
) [][]const u8 {
    var buf: [max_members]Candidate = undefined;
    var count: usize = 0;
    for (candidates(members, settings, null, &buf)) |candidate| {
        if (!candidate.member.available(env, candidate.explicit)) continue;
        out[count] = candidate.member.id;
        count += 1;
    }
    return out[0..count];
}

pub fn anyAvailable(members: []const Member, settings: Settings, env: *const Env) bool {
    var buf: [max_members][]const u8 = undefined;
    return availableIds(members, settings, env, &buf).len > 0;
}

pub const Failure = struct {
    provider: []const u8,
    reason: []u8,
};

/// A chain run. `provider` and `answer` are set when a provider answered;
/// `failures` lists every provider that was tried and failed, in order.
pub const Outcome = struct {
    provider: ?[]const u8 = null,
    answer: Answer = .{},
    failures: []Failure = &.{},

    pub fn deinit(self: *Outcome, alloc: Allocator) void {
        self.answer.deinit(alloc);
        for (self.failures) |failure| alloc.free(failure.reason);
        alloc.free(self.failures);
        self.* = .{};
    }

    /// "brave: HTTP 429; duckduckgo: no results". The caller owns the text.
    pub fn failureSummary(self: Outcome, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        for (self.failures, 0..) |failure, index| {
            if (index > 0) try out.writer.writeAll("; ");
            try out.writer.print("{s}: {s}", .{ failure.provider, failure.reason });
        }
        return out.toOwnedSlice();
    }
};

pub const RunError = error{
    UnknownWebSearchProvider,
    WebSearchProviderExcluded,
    WebSearchProviderUnavailable,
    NoWebSearchProvider,
    Cancelled,
    OutOfMemory,
};

/// Runs the chain. An unavailable provider is skipped; a failing or empty one
/// is recorded and the next is tried. A named provider runs alone. Cancellation
/// stops the chain. The caller owns the outcome.
pub fn run(
    alloc: Allocator,
    members: []const Member,
    settings: Settings,
    env: *const Env,
    query: Query,
    forced_id: ?[]const u8,
) RunError!Outcome {
    const forced = if (forced_id) |id| findMember(members, id) orelse return error.UnknownWebSearchProvider else null;
    var buf: [max_members]Candidate = undefined;
    const list = candidates(members, settings, forced, &buf);
    if (forced != null and list.len == 0) return error.WebSearchProviderExcluded;

    var failures: std.ArrayList(Failure) = .empty;
    errdefer {
        for (failures.items) |failure| alloc.free(failure.reason);
        failures.deinit(alloc);
    }
    var tried: usize = 0;
    for (list) |candidate| {
        if (query.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (!candidate.member.available(env, candidate.explicit)) {
            if (forced != null) return error.WebSearchProviderUnavailable;
            continue;
        }
        tried += 1;
        var answer = candidate.member.search_fn(alloc, env, query) catch |err| {
            if (err == error.Cancelled or query.cancel_flag.load(.seq_cst)) return error.Cancelled;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try appendFailure(alloc, &failures, candidate.member.id, describeError(err));
            continue;
        };
        try refine(alloc, &answer, query);
        if (answer.isEmpty()) {
            answer.deinit(alloc);
            try appendFailure(alloc, &failures, candidate.member.id, "no results");
            continue;
        }
        return .{
            .provider = candidate.member.id,
            .answer = answer,
            .failures = try failures.toOwnedSlice(alloc),
        };
    }
    if (tried == 0) return error.NoWebSearchProvider;
    return .{ .failures = try failures.toOwnedSlice(alloc) };
}

fn appendFailure(alloc: Allocator, failures: *std.ArrayList(Failure), provider: []const u8, reason: []const u8) !void {
    const owned = try alloc.dupe(u8, reason[0..@min(reason.len, max_failure_reason_bytes)]);
    errdefer alloc.free(owned);
    try failures.append(alloc, .{ .provider = provider, .reason = owned });
}

/// Short reason for a failed provider, for the model and the CLI.
pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.SearchRateLimited => "rate limited (HTTP 429)",
        error.SearchUnauthorized => "authorization failed; check the API key",
        error.SearchNotFound => "endpoint or model not found (HTTP 404)",
        error.SearchHttpError => "HTTP error",
        error.SearchServerError => "server error (HTTP 5xx)",
        error.SearchBlocked => "blocked by a bot-detection challenge",
        error.SearchNoWebSearch => "the model answered without searching",
        error.InvalidSearchResponse => "unreadable response",
        error.SearchResponseTooLarge => "response too large",
        error.Timeout => "timed out",
        error.MissingSearchCredential => "no credential",
        else => @errorName(err),
    };
}

/// Drops hits outside the domain filters, keeps the first `limit`, and
/// bounds snippet length.
fn refine(alloc: Allocator, answer: *Answer, query: Query) !void {
    var kept: usize = 0;
    for (answer.hits) |hit| {
        if (kept >= query.limit or !domainAllowed(hit.url, query.allowed_domains, query.blocked_domains)) {
            hit.deinit(alloc);
            continue;
        }
        answer.hits[kept] = hit;
        kept += 1;
    }
    if (kept != answer.hits.len) {
        if (alloc.remap(answer.hits, kept)) |shrunk| {
            answer.hits = shrunk;
        } else {
            const copy = try alloc.dupe(Hit, answer.hits[0..kept]);
            alloc.free(answer.hits);
            answer.hits = copy;
        }
    }
}

/// The host of `url`, lowercase-insensitive comparison left to the caller.
pub fn urlHost(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.find(u8, rest, "://")) |index| rest = rest[index + 3 ..];
    const end = std.mem.findAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.findScalarLast(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.findScalar(u8, host, ':')) |colon| host = host[0..colon];
    return host;
}

/// A filter entry's host: "https://docs.example.com/x" names docs.example.com.
fn filterHost(entry: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, entry, " \t\r\n");
    return urlHost(trimmed);
}

fn hostMatches(host: []const u8, domain: []const u8) bool {
    if (domain.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (host.len <= domain.len) return false;
    const suffix = host[host.len - domain.len ..];
    return host[host.len - domain.len - 1] == '.' and std.ascii.eqlIgnoreCase(suffix, domain);
}

pub fn domainAllowed(url: []const u8, allowed: []const []const u8, blocked: []const []const u8) bool {
    const host = urlHost(url);
    for (blocked) |entry| if (hostMatches(host, filterHost(entry))) return false;
    var any_allowed = false;
    for (allowed) |entry| {
        const domain = filterHost(entry);
        if (domain.len == 0) continue;
        any_allowed = true;
        if (hostMatches(host, domain)) return true;
    }
    return !any_allowed;
}

/// `query` with `site:` and `-site:` operators for providers without native
/// domain filters. The caller owns the result.
pub fn queryWithSiteOperators(alloc: Allocator, query: Query) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(query.text);
    var first_allowed = true;
    for (query.allowed_domains) |entry| {
        const domain = filterHost(entry);
        if (domain.len == 0) continue;
        try out.writer.writeAll(if (first_allowed) " (" else " OR ");
        try out.writer.print("site:{s}", .{domain});
        first_allowed = false;
    }
    if (!first_allowed) try out.writer.writeAll(")");
    for (query.blocked_domains) |entry| {
        const domain = filterHost(entry);
        if (domain.len == 0) continue;
        try out.writer.print(" -site:{s}", .{domain});
    }
    return out.toOwnedSlice();
}

/// The bank as the web_search runtime's provider. `load_settings_fn` reads
/// the profile settings for each search.
pub const Bank = struct {
    members: []const Member,
    load_settings_fn: *const fn (Allocator) anyerror!Settings = emptySettings,

    pub fn provider(self: *const Bank) web_search_provider.Provider {
        return .{
            .context = @ptrCast(@constCast(self)),
            .policy = policy,
            .preferred_backends_fn = preferredBackends,
            .execute_fn = execute,
            .available_fn = availableForProvider,
        };
    }

    /// The profile settings, or empty settings when they cannot be read.
    pub fn loadSettings(self: *const Bank, alloc: Allocator) Settings {
        return self.load_settings_fn(alloc) catch .{};
    }

    /// True when a search would find at least one available provider.
    pub fn availableFor(self: *const Bank, alloc: Allocator, inputs: ?web_search_provider.Inputs) bool {
        var settings = self.loadSettings(alloc);
        defer settings.deinit(alloc);
        const env = envFromInputs(inputs, settings);
        return anyAvailable(self.members, settings, &env);
    }
};

fn availableForProvider(raw_ctx: ?*anyopaque, alloc: Allocator, inputs: web_search_provider.Inputs) bool {
    const self: *const Bank = @ptrCast(@alignCast(raw_ctx orelse return false));
    return self.availableFor(alloc, inputs);
}

fn emptySettings(_: Allocator) anyerror!Settings {
    return .{};
}

/// The single backend the bank presents to the web_search policy. The chain
/// filters domains itself, by native filters, site operators, and a final
/// host check, so strict filters pass through.
pub const backend_id = web_search_contract.SearchBackendId{ .value = "bank" };
const backend_order = [_]web_search_contract.SearchBackendId{backend_id};
const backend_policies = [_]web_search_policy.BackendPolicy{.{
    .id = backend_id,
    .features = .{
        .max_uses = .best_effort,
        .allowed_domains = .pass_through,
        .blocked_domains = .pass_through,
        .ordered_sources = true,
        .usage = true,
        .terminal_incomplete = true,
        .timeout = true,
        .cancellation = true,
        .result_bounds = .post_filter,
    },
}};

pub const policy = web_search_policy.WebSearchPolicy{
    .max_results = default_limit,
    .timeout_ms = 60_000,
    .preferred_backends = &backend_order,
    .backend_policies = &backend_policies,
};

fn preferredBackends(_: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
    return null;
}

/// Maps the active session's credential onto the providers that can use it.
pub fn envFromInputs(inputs: ?web_search_provider.Inputs, settings: Settings) Env {
    var env: Env = .{ .searxng_url = settings.searxng_url };
    const value = inputs orelse return env;
    const key = if (value.api_key.len > 0) value.api_key else return env;
    const source = value.credential_source orelse return env;
    switch (source) {
        .chatgpt_subscription => {
            env.chatgpt_token = key;
            env.chatgpt_account = value.account_id;
        },
        .grok_subscription => env.grok_token = key,
        .vercel_oidc_token, .ai_gateway_api_key, .fx_login, .stored_key => {
            env.gateway_key = key;
            env.gateway_inputs = value;
        },
        .configured => if (value.anthropic_base_url) |base_url| {
            env.anthropic = .{ .base_url = base_url, .key = key, .bearer = value.anthropic_bearer };
        },
        .host_managed => {},
    }
    return env;
}

fn execute(
    raw_ctx: ?*anyopaque,
    alloc: Allocator,
    inputs: web_search_provider.Inputs,
    request: web_search_contract.ProviderRequest,
    _: ?web_search_contract.ProgressFn,
    _: ?*anyopaque,
) anyerror!web_search_contract.ProviderResponse {
    const self: *const Bank = @ptrCast(@alignCast(raw_ctx orelse return error.MissingWebSearchProvider));
    var settings = self.loadSettings(alloc);
    defer settings.deinit(alloc);
    const env = envFromInputs(inputs, settings);
    var outcome = try run(alloc, self.members, settings, &env, .{
        .text = request.query,
        .recency = request.recency,
        .limit = request.max_results,
        .allowed_domains = request.allowed_domains orelse &.{},
        .blocked_domains = request.blocked_domains orelse &.{},
        .timeout_ms = request.timeout_ms,
        .max_output_tokens = request.max_output_tokens,
        .cancel_flag = @constCast(request.cancel_flag),
    }, null);
    defer outcome.deinit(alloc);
    return toProviderResponse(alloc, &outcome);
}

/// Converts a chain outcome into result items: the answer as commentary, the
/// hits as one search block named for the provider, and a single error item
/// when every provider failed. Takes ownership of the answer.
pub fn toProviderResponse(alloc: Allocator, outcome: *Outcome) !web_search_contract.ProviderResponse {
    var items: std.ArrayList(web_search_contract.ResultItem) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(alloc);
        items.deinit(alloc);
    }
    const provider_id = outcome.provider orelse {
        const summary = try outcome.failureSummary(alloc);
        errdefer alloc.free(summary);
        const text = try alloc.print("every web search provider failed: {s}", .{summary});
        alloc.free(summary);
        errdefer alloc.free(text);
        try items.append(alloc, .{ .error_text = text });
        return .{ .content = try items.toOwnedSlice(alloc) };
    };
    if (outcome.answer.text.len > 0) {
        try items.append(alloc, .{ .commentary = outcome.answer.text });
        outcome.answer.text = &.{};
    }
    if (outcome.answer.hits.len > 0) {
        const sources = try alloc.alloc(web_search_contract.Source, outcome.answer.hits.len);
        for (outcome.answer.hits, sources) |hit, *source| source.* = .{
            .title = hit.title,
            .url = hit.url,
            .snippet = hit.snippet,
            .date = hit.date,
        };
        alloc.free(outcome.answer.hits);
        outcome.answer.hits = &.{};
        const name = alloc.dupe(u8, provider_id) catch |err| {
            for (sources) |source| source.deinit(alloc);
            alloc.free(sources);
            return err;
        };
        try items.append(alloc, .{ .search = .{ .tool_use_id = name, .content = sources } });
    }
    return .{
        .content = try items.toOwnedSlice(alloc),
        .usage = .{ .web_search_requests = 1 },
        .answered_by = provider_id,
    };
}

// Tests ---------------------------------------------------------------------

const FakeState = struct {
    var calls: [4]usize = .{ 0, 0, 0, 0 };
    var env_key: ?[]const u8 = null;

    fn reset() void {
        calls = .{ 0, 0, 0, 0 };
        env_key = null;
    }
};

fn fakeEnv(_: ?*anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "FAKE_KEY")) return FakeState.env_key;
    return null;
}

fn alwaysAvailable(_: *const Env) bool {
    return true;
}

fn neverAvailable(_: *const Env) bool {
    return false;
}

fn keyedAvailable(env: *const Env) bool {
    return env.get("FAKE_KEY") != null;
}

fn failingSearch(_: Allocator, _: *const Env, _: Query) anyerror!Answer {
    FakeState.calls[0] += 1;
    return error.SearchRateLimited;
}

fn emptySearch(alloc: Allocator, _: *const Env, _: Query) anyerror!Answer {
    FakeState.calls[1] += 1;
    var list = HitList.init(alloc);
    defer list.deinit();
    return list.finish("");
}

fn goodSearch(alloc: Allocator, _: *const Env, _: Query) anyerror!Answer {
    FakeState.calls[2] += 1;
    var list = HitList.init(alloc);
    defer list.deinit();
    try list.add("Zig", "https://ziglang.org/", "A language", "2026-01-02");
    try list.add("Dup", "https://ziglang.org/", "", "");
    try list.add("Other", "https://example.com/a", "", "");
    try list.add("Docs", "https://docs.example.com/b", "", "");
    return list.finish("answer");
}

fn keyedSearch(alloc: Allocator, env: *const Env, query: Query) anyerror!Answer {
    FakeState.calls[3] += 1;
    _ = env;
    return goodSearch(alloc, undefined, query);
}

const test_members = [_]Member{
    .{ .id = "alpha", .label = "Alpha", .available_fn = alwaysAvailable, .search_fn = failingSearch },
    .{ .id = "beta", .label = "Beta", .available_fn = alwaysAvailable, .search_fn = emptySearch },
    .{ .id = "gamma", .label = "Gamma", .available_fn = alwaysAvailable, .search_fn = goodSearch },
    .{ .id = "keyed", .label = "Keyed", .available_fn = keyedAvailable, .explicit_available_fn = alwaysAvailable, .search_fn = keyedSearch },
};

fn testQuery(cancel: *std.atomic.Value(bool)) Query {
    return .{ .text = "zig", .cancel_flag = cancel };
}

test "chain falls back past errors and empty results and reports the answering provider" {
    FakeState.reset();
    const alloc = std.testing.allocator;
    var cancel = std.atomic.Value(bool).init(false);
    const env = Env{ .env_fn = fakeEnv };
    var outcome = try run(alloc, &test_members, .{}, &env, testQuery(&cancel), null);
    defer outcome.deinit(alloc);

    try std.testing.expectEqualStrings("gamma", outcome.provider.?);
    try std.testing.expectEqual(@as(usize, 3), outcome.answer.hits.len);
    try std.testing.expectEqual(@as(usize, 2), outcome.failures.len);
    try std.testing.expectEqualStrings("alpha", outcome.failures[0].provider);
    try std.testing.expectEqualStrings("rate limited (HTTP 429)", outcome.failures[0].reason);
    try std.testing.expectEqualStrings("no results", outcome.failures[1].reason);
    try std.testing.expectEqual(@as(usize, 0), FakeState.calls[3]);
}

test "order setting puts providers first and exclude removes them" {
    FakeState.reset();
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"order\":[\"Gamma\",\"nope\"],\"exclude\":[\"alpha\"]}", .{});
    defer parsed.deinit();
    var settings = try parseSettings(alloc, parsed.value);
    defer settings.deinit(alloc);
    var cancel = std.atomic.Value(bool).init(false);
    const env = Env{ .env_fn = fakeEnv };

    var ids_buf: [max_members][]const u8 = undefined;
    const ids = availableIds(&test_members, settings, &env, &ids_buf);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("gamma", ids[0]);
    try std.testing.expectEqualStrings("beta", ids[1]);

    var outcome = try run(alloc, &test_members, settings, &env, testQuery(&cancel), null);
    defer outcome.deinit(alloc);
    try std.testing.expectEqualStrings("gamma", outcome.provider.?);
    try std.testing.expectEqual(@as(usize, 0), FakeState.calls[0]);
    try std.testing.expectEqual(@as(usize, 0), outcome.failures.len);
}

test "availability gating counts only providers whose credentials exist" {
    FakeState.reset();
    const only_keyed = [_]Member{test_members[3]};
    const env = Env{ .env_fn = fakeEnv };
    try std.testing.expect(!anyAvailable(&only_keyed, .{}, &env));
    FakeState.env_key = "secret";
    try std.testing.expect(anyAvailable(&only_keyed, .{}, &env));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"exclude\":[\"keyed\"]}", .{});
    defer parsed.deinit();
    var settings = try parseSettings(std.testing.allocator, parsed.value);
    defer settings.deinit(std.testing.allocator);
    try std.testing.expect(!anyAvailable(&only_keyed, settings, &env));
}

test "a named provider runs alone with its explicit availability" {
    FakeState.reset();
    const alloc = std.testing.allocator;
    var cancel = std.atomic.Value(bool).init(false);
    const env = Env{ .env_fn = fakeEnv };
    var outcome = try run(alloc, &test_members, .{}, &env, testQuery(&cancel), "keyed");
    defer outcome.deinit(alloc);
    try std.testing.expectEqualStrings("keyed", outcome.provider.?);
    try std.testing.expectEqual(@as(usize, 1), FakeState.calls[3]);
    try std.testing.expectEqual(@as(usize, 0), FakeState.calls[0] + FakeState.calls[1]);

    var failed = try run(alloc, &test_members, .{}, &env, testQuery(&cancel), "alpha");
    defer failed.deinit(alloc);
    try std.testing.expect(failed.provider == null);
    try std.testing.expectEqual(@as(usize, 1), failed.failures.len);
    try std.testing.expectError(error.UnknownWebSearchProvider, run(alloc, &test_members, .{}, &env, testQuery(&cancel), "missing"));
    const none = [_]Member{.{ .id = "off", .label = "Off", .available_fn = neverAvailable, .search_fn = goodSearch }};
    try std.testing.expectError(error.WebSearchProviderUnavailable, run(alloc, &none, .{}, &env, testQuery(&cancel), "off"));
    try std.testing.expectError(error.NoWebSearchProvider, run(alloc, &none, .{}, &env, testQuery(&cancel), null));
}

test "results honor limit and domain filters" {
    FakeState.reset();
    const alloc = std.testing.allocator;
    var cancel = std.atomic.Value(bool).init(false);
    const env = Env{ .env_fn = fakeEnv };
    const only_good = [_]Member{test_members[2]};
    var query = testQuery(&cancel);
    query.allowed_domains = &.{"https://example.com/"};
    var outcome = try run(alloc, &only_good, .{}, &env, query, null);
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), outcome.answer.hits.len);
    try std.testing.expectEqualStrings("https://example.com/a", outcome.answer.hits[0].url);

    query = testQuery(&cancel);
    query.blocked_domains = &.{"example.com"};
    query.limit = 1;
    var blocked = try run(alloc, &only_good, .{}, &env, query, null);
    defer blocked.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), blocked.answer.hits.len);
    try std.testing.expectEqualStrings("https://ziglang.org/", blocked.answer.hits[0].url);
}

test "site operators carry domain filters into the query text" {
    var cancel = std.atomic.Value(bool).init(false);
    var query = testQuery(&cancel);
    query.allowed_domains = &.{ "a.com", "https://b.org/x" };
    query.blocked_domains = &.{"c.net"};
    const text = try queryWithSiteOperators(std.testing.allocator, query);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("zig (site:a.com OR site:b.org) -site:c.net", text);
}

test "outcome converts to provider response with the provider named" {
    FakeState.reset();
    const alloc = std.testing.allocator;
    var cancel = std.atomic.Value(bool).init(false);
    const env = Env{ .env_fn = fakeEnv };
    const only_good = [_]Member{test_members[2]};
    var outcome = try run(alloc, &only_good, .{}, &env, testQuery(&cancel), null);
    defer outcome.deinit(alloc);
    var response = try toProviderResponse(alloc, &outcome);
    defer response.deinit(alloc);
    try std.testing.expectEqualStrings("gamma", response.answered_by);
    try std.testing.expectEqualStrings("answer", response.content[0].commentary);
    try std.testing.expectEqualStrings("gamma", response.content[1].search.tool_use_id);
    try std.testing.expectEqualStrings("A language", response.content[1].search.content[0].snippet);
    try std.testing.expectEqual(@as(usize, 3), web_search_contract.sourceCount(response.content));

    const only_bad = [_]Member{test_members[0]};
    var failed = try run(alloc, &only_bad, .{}, &env, testQuery(&cancel), null);
    defer failed.deinit(alloc);
    var failed_response = try toProviderResponse(alloc, &failed);
    defer failed_response.deinit(alloc);
    try std.testing.expectEqualStrings("every web search provider failed: alpha: rate limited (HTTP 429)", failed_response.content[0].error_text);
}

test "active credentials map to the providers that can use them" {
    const base = web_search_provider.Inputs{ .api_key = "tok", .worker_model = "", .gateway_retry_count = 0, .gateway_chat_url = "" };
    var inputs = base;
    inputs.credential_source = .chatgpt_subscription;
    inputs.account_id = "acct";
    const codex_env = envFromInputs(inputs, .{});
    try std.testing.expectEqualStrings("tok", codex_env.chatgpt_token.?);
    try std.testing.expectEqualStrings("acct", codex_env.chatgpt_account.?);
    inputs = base;
    inputs.credential_source = .configured;
    try std.testing.expect(envFromInputs(inputs, .{}).anthropic == null);
    inputs.anthropic_base_url = "http://127.0.0.1:1/v1";
    try std.testing.expectEqualStrings("http://127.0.0.1:1/v1", envFromInputs(inputs, .{}).anthropic.?.base_url);
    inputs = base;
    inputs.credential_source = .grok_subscription;
    try std.testing.expectEqualStrings("tok", envFromInputs(inputs, .{}).grok_token.?);
}

test "domain matching accepts subdomains only on a label boundary" {
    try std.testing.expect(domainAllowed("https://docs.example.com/x", &.{"example.com"}, &.{}));
    try std.testing.expect(!domainAllowed("https://badexample.com/x", &.{"example.com"}, &.{}));
    try std.testing.expect(!domainAllowed("https://user@example.com:8080/x", &.{}, &.{"example.com"}));
    try std.testing.expectEqualStrings("example.com", urlHost("https://user@example.com:8080/x?y"));
}
