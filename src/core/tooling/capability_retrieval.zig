const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

pub const default_limit: usize = 5;
pub const max_limit: usize = 20;
pub const max_cursor_bytes: usize = 160;

const primary_weight: f64 = 3.0;
const k1: f64 = 1.2;
const b: f64 = 0.75;
const min_secondary_evidence_token_bytes: usize = 4;
const rare_short_token_catalog_divisor: usize = 32;

pub const Kind = enum {
    all,
    skill,
    mcp,

    pub fn includes(self: Kind, domain: Domain) bool {
        return self == .all or switch (domain) {
            .skill => self == .skill,
            .mcp => self == .mcp,
        };
    }
};

pub const Domain = enum {
    skill,
    mcp,
};

pub const RelevancePolicy = enum {
    compatible,
    intent,
};

pub const Request = struct {
    query: *const lexical_relevance.PreparedQuery,
    kind: Kind = .all,
    server: ?[]const u8 = null,
    limit: usize = default_limit,
    cursor: ?[]const u8 = null,
    relevance_policy: RelevancePolicy = .compatible,

    pub fn validate(self: Request) ValidationError!void {
        if (self.limit == 0 or self.limit > max_limit) return error.InvalidLimit;
        if (self.server) |server| {
            if (server.len == 0) return error.InvalidServer;
            if (self.kind == .skill) return error.ServerRequiresMcp;
        }
        if (self.query.raw.len == 0 and self.server == null) {
            return error.QueryOrServerRequired;
        }
        if (self.cursor) |cursor| {
            if (cursor.len == 0 or cursor.len > max_cursor_bytes) {
                return error.InvalidCursor;
            }
            if (self.kind == .all and self.server == null) {
                return error.CursorRequiresDomain;
            }
        }
    }

    pub fn includes(self: Request, domain: Domain) bool {
        if (self.server != null and domain == .skill) return false;
        return self.kind.includes(domain);
    }
};

pub const ValidationError = error{
    QueryOrServerRequired,
    InvalidLimit,
    InvalidServer,
    ServerRequiresMcp,
    CursorRequiresDomain,
    InvalidCursor,
};

pub const Document = struct {
    identities: [2][]const u8 = .{ "", "" },
    stable_key: []const u8,
    primary: [4][]const u8 = .{ "", "", "", "" },
    primary_extra: []const []const u8 = &.{},
    secondary: [3][]const u8 = .{ "", "", "" },
};

pub const Match = struct {
    document_index: usize,
};

pub const Page = struct {
    matches: []Match,
    total_matches: usize,
    start_offset: usize,
    fingerprint: u64,
    request_hash: u64,
    domain: Domain,

    pub fn deinit(self: *Page, alloc: Allocator) void {
        alloc.free(self.matches);
        self.* = undefined;
    }

    /// Returns an owned continuation cursor after the retained prefix. Null
    /// means the retained prefix reaches the final match.
    pub fn cursorAfter(
        self: Page,
        alloc: Allocator,
        retained_count: usize,
    ) (Allocator.Error || error{InvalidRetainedCount})!?[]u8 {
        if (retained_count > self.matches.len) return error.InvalidRetainedCount;
        const next_offset = std.math.add(usize, self.start_offset, retained_count) catch
            return error.InvalidRetainedCount;
        if (next_offset >= self.total_matches) return null;
        return try renderCursor(
            alloc,
            self.domain,
            self.fingerprint,
            self.request_hash,
            next_offset,
        );
    }
};

pub const RetrieveError = Allocator.Error || error{
    InvalidCursor,
    StaleCursor,
};

const Ranked = struct {
    document_index: usize,
    exact_identity: bool,
    score: f64,
    primary_hits: u8,
};

const CorpusStats = struct {
    primary_average_length: f64,
    secondary_average_length: f64,
};

const Cursor = struct {
    domain: Domain,
    fingerprint: u64,
    request_hash: u64,
    offset: usize,
};

pub fn retrieve(
    alloc: Allocator,
    request: Request,
    domain: Domain,
    documents: []const Document,
) RetrieveError!Page {
    const fingerprint = catalogFingerprint(documents);
    const request_hash = requestHash(request, domain);
    const start_offset = if (request.cursor) |raw_cursor| cursor: {
        const parsed = parseCursor(raw_cursor) catch return error.InvalidCursor;
        if (parsed.domain != domain or parsed.request_hash != request_hash) {
            return error.InvalidCursor;
        }
        if (parsed.fingerprint != fingerprint) return error.StaleCursor;
        break :cursor parsed.offset;
    } else 0;

    const ranked = try alloc.alloc(Ranked, documents.len);
    defer alloc.free(ranked);
    var ranked_count: usize = 0;
    const stats = corpusStats(documents);
    var document_frequencies: [lexical_relevance.max_query_tokens]usize = undefined;
    for (0..request.query.token_count) |index| {
        const token = request.query.tokenAt(index);
        document_frequencies[index] = corpusDocumentFrequency(documents, token);
    }

    for (documents, 0..) |document, document_index| {
        const exact_identity = lexical_relevance.containsCompleteIdentity(
            request.query.raw,
            &document.identities,
        ) or lexical_relevance.containsCompleteIdentity(
            request.query.raw,
            document.primary[0..1],
        );
        var primary_hits: u8 = 0;
        var secondary_hits: u8 = 0;
        var score: f64 = 0;
        const primary_length = primaryLength(document);
        const secondary_length = secondaryLength(document);
        for (0..request.query.token_count) |token_index| {
            const token = request.query.tokenAt(token_index);
            const primary_tf = primaryTermFrequency(document, token);
            const secondary_tf = secondaryTermFrequency(document, token);
            if (primary_tf > 0) primary_hits += 1;
            if (secondary_tf > 0 and secondaryTokenProvidesEvidence(
                token,
                document_frequencies[token_index],
                documents.len,
                request.relevance_policy,
                request.server != null,
            )) {
                secondary_hits += 1;
            }
            if (primary_tf == 0 and secondary_tf == 0) continue;

            const idf = inverseDocumentFrequency(
                documents.len,
                document_frequencies[token_index],
            );
            score += idf * (primary_weight * bm25Term(
                primary_tf,
                primary_length,
                stats.primary_average_length,
            ) +
                bm25Term(
                    secondary_tf,
                    secondary_length,
                    stats.secondary_average_length,
                ));
        }

        const inventory = request.query.raw.len == 0;
        const clear_match = clearMatch(
            request.query.token_count,
            exact_identity,
            primary_hits,
            secondary_hits,
        );
        if (!inventory and !clear_match) continue;
        ranked[ranked_count] = .{
            .document_index = document_index,
            .exact_identity = exact_identity,
            .score = score,
            .primary_hits = primary_hits,
        };
        ranked_count += 1;
    }

    if (request.query.raw.len == 0) {
        sort_utils.sort(Ranked, ranked[0..ranked_count], documents, lessInventory);
    } else {
        sort_utils.sort(Ranked, ranked[0..ranked_count], documents, lessRelevance);
    }
    if (start_offset > ranked_count) return error.InvalidCursor;
    const end = @min(
        std.math.add(usize, start_offset, request.limit) catch ranked_count,
        ranked_count,
    );
    const page_matches = try alloc.alloc(Match, end - start_offset);
    errdefer alloc.free(page_matches);
    for (ranked[start_offset..end], 0..) |match, index| {
        page_matches[index] = .{
            .document_index = match.document_index,
        };
    }
    return .{
        .matches = page_matches,
        .total_matches = ranked_count,
        .start_offset = start_offset,
        .fingerprint = fingerprint,
        .request_hash = request_hash,
        .domain = domain,
    };
}

fn corpusStats(documents: []const Document) CorpusStats {
    if (documents.len == 0) {
        return .{
            .primary_average_length = 1,
            .secondary_average_length = 1,
        };
    }
    var primary_total: usize = 0;
    var secondary_total: usize = 0;
    for (documents) |document| {
        primary_total +|= primaryLength(document);
        secondary_total +|= secondaryLength(document);
    }
    const count: f64 = @floatFromInt(documents.len);
    return .{
        .primary_average_length = @max(1, @as(f64, @floatFromInt(primary_total)) / count),
        .secondary_average_length = @max(1, @as(f64, @floatFromInt(secondary_total)) / count),
    };
}

fn inverseDocumentFrequency(document_count: usize, document_frequency: usize) f64 {
    const count: f64 = @floatFromInt(document_count);
    const frequency: f64 = @floatFromInt(document_frequency);
    return @log(1.0 + (count - frequency + 0.5) / (frequency + 0.5));
}

fn bm25Term(term_frequency: usize, document_length: usize, average_length: f64) f64 {
    if (term_frequency == 0) return 0;
    const tf: f64 = @floatFromInt(term_frequency);
    const length: f64 = @floatFromInt(document_length);
    const normalization = 1.0 - b + b * length / average_length;
    return tf * (k1 + 1.0) / (tf + k1 * normalization);
}

fn corpusDocumentFrequency(documents: []const Document, token: []const u8) usize {
    var count: usize = 0;
    for (documents) |document| {
        if (primaryTermFrequency(document, token) > 0 or
            secondaryTermFrequency(document, token) > 0)
        {
            count += 1;
        }
    }
    return count;
}

fn primaryTermFrequency(document: Document, token: []const u8) usize {
    var count: usize = 0;
    for (document.primary) |field| count +|= termFrequency(field, token);
    for (document.primary_extra) |field| count +|= termFrequency(field, token);
    return count;
}

fn secondaryTermFrequency(document: Document, token: []const u8) usize {
    var count: usize = 0;
    for (document.secondary) |field| count +|= termFrequency(field, token);
    return count;
}

fn secondaryTokenProvidesEvidence(
    token: []const u8,
    document_frequency: usize,
    document_count: usize,
    relevance_policy: RelevancePolicy,
    server_scoped: bool,
) bool {
    if (token.len < min_secondary_evidence_token_bytes) {
        return document_frequency <= document_count / rare_short_token_catalog_divisor;
    }
    return relevance_policy == .compatible or
        server_scoped or
        document_frequency < document_count;
}

fn clearMatch(
    query_token_count: usize,
    exact_identity: bool,
    primary_hits: u8,
    secondary_hits: u8,
) bool {
    return exact_identity or
        (query_token_count == 1 and primary_hits > 0) or
        primary_hits + secondary_hits >= 2;
}

fn primaryLength(document: Document) usize {
    var count: usize = 0;
    for (document.primary) |field| count +|= tokenCount(field);
    for (document.primary_extra) |field| count +|= tokenCount(field);
    return count;
}

fn secondaryLength(document: Document) usize {
    var count: usize = 0;
    for (document.secondary) |field| count +|= tokenCount(field);
    return count;
}

fn tokenCount(text: []const u8) usize {
    var count: usize = 0;
    var in_token = false;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (!in_token) count += 1;
            in_token = true;
        } else {
            in_token = false;
        }
    }
    return count;
}

fn termFrequency(text: []const u8, token: []const u8) usize {
    if (token.len == 0 or token.len > text.len) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (start <= text.len - token.len) : (start += 1) {
        const end = start + token.len;
        if (!std.ascii.eqlIgnoreCase(text[start..end], token)) continue;
        if (start > 0 and std.ascii.isAlphanumeric(text[start - 1])) continue;
        if (end < text.len and std.ascii.isAlphanumeric(text[end])) continue;
        count += 1;
        start = end - 1;
    }
    return count;
}

fn lessInventory(
    documents: []const Document,
    lhs: Ranked,
    rhs: Ranked,
) bool {
    return lessStableKey(documents, lhs.document_index, rhs.document_index);
}

fn lessRelevance(
    documents: []const Document,
    lhs: Ranked,
    rhs: Ranked,
) bool {
    if (lhs.exact_identity != rhs.exact_identity) return lhs.exact_identity;
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if (lhs.primary_hits != rhs.primary_hits) return lhs.primary_hits > rhs.primary_hits;
    return lessStableKey(documents, lhs.document_index, rhs.document_index);
}

fn lessStableKey(
    documents: []const Document,
    lhs_index: usize,
    rhs_index: usize,
) bool {
    const lhs = documents[lhs_index].stable_key;
    const rhs = documents[rhs_index].stable_key;
    const shared = @min(lhs.len, rhs.len);
    for (lhs[0..shared], rhs[0..shared]) |lhs_byte, rhs_byte| {
        const lhs_lower = std.ascii.toLower(lhs_byte);
        const rhs_lower = std.ascii.toLower(rhs_byte);
        if (lhs_lower != rhs_lower) return lhs_lower < rhs_lower;
    }
    if (lhs.len != rhs.len) return lhs.len < rhs.len;
    return lhs_index < rhs_index;
}

fn catalogFingerprint(documents: []const Document) u64 {
    var xor_digest: u64 = 0;
    var sum_digest: u64 = 0;
    for (documents) |document| {
        var hash = std.hash.Wyhash.init(0x6361706162696c69);
        updateHashField(&hash, document.stable_key);
        for (document.identities) |field| updateHashField(&hash, field);
        for (document.primary) |field| updateHashField(&hash, field);
        for (document.primary_extra) |field| updateHashField(&hash, field);
        for (document.secondary) |field| updateHashField(&hash, field);
        const digest = hash.final();
        xor_digest ^= digest;
        sum_digest +%= digest *% 0x9e3779b97f4a7c15;
    }
    return xor_digest ^ std.math.rotl(u64, sum_digest, 17) ^ @as(u64, @intCast(documents.len));
}

fn requestHash(request: Request, domain: Domain) u64 {
    var hash = std.hash.Wyhash.init(0x7265717565737421);
    updateHashField(&hash, request.query.raw);
    hash.update(&.{@backingInt(domain)});
    hash.update(&.{@backingInt(request.relevance_policy)});
    if (request.server) |server| updateHashField(&hash, server);
    return hash.final();
}

fn updateHashField(hash: *std.hash.Wyhash, field: []const u8) void {
    const length: u64 = @intCast(field.len);
    hash.update(std.mem.asBytes(&length));
    hash.update(field);
}

fn renderCursor(
    alloc: Allocator,
    domain: Domain,
    fingerprint: u64,
    request_hash: u64,
    offset: usize,
) Allocator.Error![]u8 {
    return alloc.print(
        "c1:{c}:{x}:{x}:{d}",
        .{
            if (domain == .skill) @as(u8, 's') else @as(u8, 'm'),
            fingerprint,
            request_hash,
            offset,
        },
    );
}

fn parseCursor(raw: []const u8) error{InvalidCursor}!Cursor {
    if (raw.len == 0 or raw.len > max_cursor_bytes) return error.InvalidCursor;
    var parts = std.mem.splitScalar(u8, raw, ':');
    const version = parts.next() orelse return error.InvalidCursor;
    const domain_raw = parts.next() orelse return error.InvalidCursor;
    const fingerprint_raw = parts.next() orelse return error.InvalidCursor;
    const request_hash_raw = parts.next() orelse return error.InvalidCursor;
    const offset_raw = parts.next() orelse return error.InvalidCursor;
    if (parts.next() != null or !std.mem.eql(u8, version, "c1") or domain_raw.len != 1) {
        return error.InvalidCursor;
    }
    const domain: Domain = switch (domain_raw[0]) {
        's' => .skill,
        'm' => .mcp,
        else => return error.InvalidCursor,
    };
    return .{
        .domain = domain,
        .fingerprint = std.fmt.parseInt(u64, fingerprint_raw, 16) catch
            return error.InvalidCursor,
        .request_hash = std.fmt.parseInt(u64, request_hash_raw, 16) catch
            return error.InvalidCursor,
        .offset = std.fmt.parseInt(usize, offset_raw, 10) catch
            return error.InvalidCursor,
    };
}

test "request validation rejects invalid source and cursor states" {
    const query = try lexical_relevance.prepare("monitor incidents");
    const empty = try lexical_relevance.prepare("");

    try (Request{ .query = &query }).validate();
    try (Request{ .query = &empty, .kind = .mcp, .server = "datadog" }).validate();
    try std.testing.expectError(
        error.QueryOrServerRequired,
        (Request{ .query = &empty }).validate(),
    );
    try std.testing.expectError(
        error.ServerRequiresMcp,
        (Request{ .query = &query, .kind = .skill, .server = "datadog" }).validate(),
    );
    try std.testing.expectError(
        error.InvalidLimit,
        (Request{ .query = &query, .limit = max_limit + 1 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidCursor,
        (Request{ .query = &query, .cursor = "" }).validate(),
    );
    try std.testing.expectError(
        error.CursorRequiresDomain,
        (Request{ .query = &query, .cursor = "c1:s:1:1:1" }).validate(),
    );
}

test "corpus relevance prefers identities and rejects one weak generic hit" {
    const query = try lexical_relevance.prepare("datadog monitor incidents");
    const documents = [_]Document{
        .{
            .identities = .{ "prompt-master", "" },
            .stable_key = "skill:prompt-master",
            .primary = .{ "prompt-master", "", "", "" },
            .secondary = .{ "Write prompts for tools", "", "" },
        },
        .{
            .identities = .{ "mcp_datadog_list_monitors", "list_monitors" },
            .stable_key = "mcp:datadog:list_monitors",
            .primary = .{ "datadog", "list_monitors", "mcp_datadog_list_monitors", "" },
            .secondary = .{ "List Datadog monitors and incidents", "", "" },
        },
        .{
            .identities = .{ "mcp_other_list_tools", "list_tools" },
            .stable_key = "mcp:other:list_tools",
            .primary = .{ "other", "list_tools", "mcp_other_list_tools", "" },
            .secondary = .{ "Return tools from a server", "", "" },
        },
    };
    var page = try retrieve(
        std.testing.allocator,
        .{ .query = &query },
        .mcp,
        &documents,
    );
    defer page.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), page.total_matches);
    try std.testing.expectEqual(@as(usize, 1), page.matches.len);
    try std.testing.expectEqual(@as(usize, 1), page.matches[0].document_index);
}

test "relevance rejects isolated generic primary and short secondary evidence" {
    const documents = [_]Document{
        .{
            .identities = .{ "strategy-website", "" },
            .stable_key = "skill:strategy-website",
            .primary = .{ "strategy-website", "", "", "" },
            .secondary = .{
                "Website content, conversion optimization, and call-to-action guidance. Triggers on landing-page requests.",
                "",
                "",
            },
        },
        .{
            .identities = .{ "mcp_context7_query-docs", "" },
            .stable_key = "mcp:context7:query-docs",
            .primary = .{ "context7", "query-docs", "", "" },
            .secondary = .{ "Call this tool on every documentation request.", "", "" },
        },
    };
    const queries = [_][]const u8{
        "query production monitoring alerts and open incidents datadog pagerduty grafana sentry status page",
        "incident management on-call alerts",
    };
    for (queries) |raw_query| {
        const query = try lexical_relevance.prepare(raw_query);
        var page = try retrieve(
            std.testing.allocator,
            .{ .query = &query },
            .skill,
            &documents,
        );
        defer page.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 0), page.total_matches);
        try std.testing.expectEqual(@as(usize, 0), page.matches.len);
    }
}

test "exact server identity bypasses the two-hit relevance floor" {
    const query = try lexical_relevance.prepare("datadog");
    const documents = [_]Document{
        .{
            .identities = .{ "mcp_context7_query-docs", "" },
            .stable_key = "mcp:context7:query-docs",
            .primary = .{ "context7", "query-docs", "", "" },
        },
        .{
            .identities = .{ "mcp_datadog_list-monitors", "" },
            .stable_key = "mcp:datadog:list-monitors",
            .primary = .{ "datadog", "list-monitors", "", "" },
        },
    };
    var page = try retrieve(
        std.testing.allocator,
        .{ .query = &query, .kind = .mcp },
        .mcp,
        &documents,
    );
    defer page.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), page.total_matches);
    try std.testing.expectEqual(@as(usize, 1), page.matches.len);
    try std.testing.expectEqual(@as(usize, 1), page.matches[0].document_index);
}

test "rare short technical terms remain secondary evidence" {
    const query = try lexical_relevance.prepare("aws deployment");
    var documents: [rare_short_token_catalog_divisor]Document = undefined;
    for (&documents, 0..) |*document, index| {
        document.* = .{
            .identities = .{ "generic-helper", "" },
            .stable_key = if (index == 0) "skill:cloud-helper" else "skill:generic-helper",
            .primary = .{ if (index == 0) "cloud-helper" else "generic-helper", "", "", "" },
            .secondary = .{
                if (index == 0) "AWS deployment guidance" else "General workflow guidance",
                "",
                "",
            },
        };
    }
    var page = try retrieve(
        std.testing.allocator,
        .{ .query = &query, .kind = .skill },
        .skill,
        &documents,
    );
    defer page.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), page.total_matches);
    try std.testing.expectEqual(@as(usize, 1), page.matches.len);
    try std.testing.expectEqual(@as(usize, 0), page.matches[0].document_index);
}

test "intent relevance rejects corpus-wide procedural description terms" {
    const query = try lexical_relevance.prepare("query list production monitors");
    const documents = [_]Document{
        .{
            .identities = .{ "mcp_context7_query-docs", "" },
            .stable_key = "mcp:context7:query-docs",
            .primary = .{ "context7", "query-docs", "", "" },
            .secondary = .{ "Query and list documentation", "", "" },
        },
        .{
            .identities = .{ "mcp_context7_resolve-library-id", "" },
            .stable_key = "mcp:context7:resolve-library-id",
            .primary = .{ "context7", "resolve-library-id", "", "" },
            .secondary = .{ "Query and list documentation", "", "" },
        },
    };
    var page = try retrieve(
        std.testing.allocator,
        .{ .query = &query, .kind = .mcp, .relevance_policy = .intent },
        .mcp,
        &documents,
    );
    defer page.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), page.total_matches);
    try std.testing.expectEqual(@as(usize, 0), page.matches.len);
}

test "inventory cursor partitions twenty eight tools without gaps" {
    const alloc = std.testing.allocator;
    const query = try lexical_relevance.prepare("");
    var name_storage: [28][24]u8 = undefined;
    var documents: [28]Document = undefined;
    for (&documents, 0..) |*document, index| {
        const name = try std.mem.print(&name_storage[index], "mcp_datadog_tool_{d:0>2}", .{index});
        document.* = .{
            .identities = .{ name, "" },
            .stable_key = name,
            .primary = .{ "datadog", name, "", "" },
        };
    }

    var seen: [28]bool = @splat(false);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    var total_seen: usize = 0;
    while (true) {
        var page = try retrieve(
            alloc,
            .{
                .query = &query,
                .kind = .mcp,
                .server = "datadog",
                .limit = 5,
                .cursor = cursor,
            },
            .mcp,
            &documents,
        );
        defer page.deinit(alloc);
        for (page.matches) |match| {
            try std.testing.expect(!seen[match.document_index]);
            seen[match.document_index] = true;
            total_seen += 1;
        }
        const next = try page.cursorAfter(alloc, page.matches.len);
        if (cursor) |value| alloc.free(value);
        cursor = next;
        if (cursor == null) break;
    }
    try std.testing.expectEqual(@as(usize, 28), total_seen);
    for (seen) |value| try std.testing.expect(value);
}

test "cursor is bound to request and catalog fingerprint" {
    const alloc = std.testing.allocator;
    const query = try lexical_relevance.prepare("monitor incidents");
    const changed_query = try lexical_relevance.prepare("security signals");
    const documents = [_]Document{
        .{
            .identities = .{ "mcp_datadog_monitors", "" },
            .stable_key = "mcp:datadog:monitors",
            .primary = .{ "datadog", "monitors", "", "" },
            .secondary = .{ "Monitor incidents", "", "" },
        },
        .{
            .identities = .{ "mcp_datadog_incidents", "" },
            .stable_key = "mcp:datadog:incidents",
            .primary = .{ "datadog", "incidents", "", "" },
            .secondary = .{ "Monitor incidents", "", "" },
        },
    };
    var first = try retrieve(
        alloc,
        .{ .query = &query, .kind = .mcp, .server = "datadog", .limit = 1 },
        .mcp,
        &documents,
    );
    defer first.deinit(alloc);
    const cursor = (try first.cursorAfter(alloc, first.matches.len)).?;
    defer alloc.free(cursor);

    try std.testing.expectError(
        error.InvalidCursor,
        retrieve(
            alloc,
            .{
                .query = &changed_query,
                .kind = .mcp,
                .server = "datadog",
                .limit = 1,
                .cursor = cursor,
            },
            .mcp,
            &documents,
        ),
    );

    var changed_documents = documents;
    changed_documents[1].secondary[0] = "Changed catalog";
    try std.testing.expectError(
        error.StaleCursor,
        retrieve(
            alloc,
            .{
                .query = &query,
                .kind = .mcp,
                .server = "datadog",
                .limit = 1,
                .cursor = cursor,
            },
            .mcp,
            &changed_documents,
        ),
    );
}

test "large catalog retrieval remains bounded to the requested page" {
    const alloc = std.testing.allocator;
    const query = try lexical_relevance.prepare("monitor incidents");
    const documents = try alloc.alloc(Document, 10_000);
    defer alloc.free(documents);
    for (documents, 0..) |*document, index| {
        document.* = .{
            .identities = .{ "monitor", "" },
            .stable_key = if (index % 2 == 0) "monitor-even" else "monitor-odd",
            .primary = .{ "datadog", "monitor", "", "" },
            .secondary = .{ "Read monitor incidents", "", "" },
        };
    }
    var page = try retrieve(
        alloc,
        .{ .query = &query, .kind = .mcp, .server = "datadog", .limit = max_limit },
        .mcp,
        documents,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 10_000), page.total_matches);
    try std.testing.expectEqual(max_limit, page.matches.len);
    const cursor = (try page.cursorAfter(alloc, page.matches.len)).?;
    defer alloc.free(cursor);
    try std.testing.expect(cursor.len <= max_cursor_bytes);
}

test "retrieval releases every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const query = try lexical_relevance.prepare("monitor incidents");
            const documents = [_]Document{
                .{
                    .identities = .{ "monitor", "" },
                    .stable_key = "mcp:datadog:monitor",
                    .primary = .{ "datadog", "monitor", "", "" },
                    .secondary = .{ "Read monitor incidents", "", "" },
                },
                .{
                    .identities = .{ "incident", "" },
                    .stable_key = "mcp:datadog:incident",
                    .primary = .{ "datadog", "incident", "", "" },
                    .secondary = .{ "Read monitor incidents", "", "" },
                },
            };
            var page = try retrieve(
                alloc,
                .{ .query = &query, .kind = .mcp, .server = "datadog", .limit = 1 },
                .mcp,
                &documents,
            );
            defer page.deinit(alloc);
            const cursor = (try page.cursorAfter(alloc, page.matches.len)).?;
            alloc.free(cursor);
        }
    };
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Case.run, .{});
}
