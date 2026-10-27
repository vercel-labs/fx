//! `proto-fx search` output: one snapshot rendered as text or JSON.
const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
const bank = @import("../tooling/web_search_bank.zig");

const Allocator = std.mem.Allocator;

const OutputFormat = @import("output_contracts.zig").OutputFormat;

const max_text_snippet_bytes = 240;

/// Every field is borrowed from the search outcome and arguments.
pub const Snapshot = struct {
    query: []const u8,
    recency: ?bank.Recency = null,
    limit: u8,
    /// The provider that answered, or null when none did.
    provider: ?[]const u8 = null,
    answer: []const u8 = "",
    results: []const bank.Hit = &.{},
    failures: []const bank.Failure = &.{},
    /// A failure before any provider ran, such as an unknown provider.
    error_message: ?[]const u8 = null,

    pub fn fromOutcome(query: []const u8, recency: ?bank.Recency, limit: u8, outcome: *const bank.Outcome) Snapshot {
        return .{
            .query = query,
            .recency = recency,
            .limit = limit,
            .provider = outcome.provider,
            .answer = outcome.answer.text,
            .results = outcome.answer.hits,
            .failures = outcome.failures,
        };
    }

    pub fn succeeded(self: Snapshot) bool {
        return self.provider != null and self.error_message == null;
    }

    pub fn render(self: Snapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: Snapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const w = &out.writer;
        if (self.error_message) |message| {
            try w.print("search failed: {s}\n", .{message});
            return out.toOwnedSlice();
        }
        const provider = self.provider orelse {
            try w.writeAll("search failed: every provider failed\n");
            try self.writeFailures(w);
            return out.toOwnedSlice();
        };
        try w.print("{s} \u{b7} {d} result{s}\n", .{ provider, self.results.len, if (self.results.len == 1) "" else "s" });
        const answer = std.mem.trim(u8, self.answer, " \r\n");
        if (answer.len > 0) try w.print("\n{s}\n", .{answer});
        for (self.results, 1..) |hit, index| {
            try w.print("\n{d}. {s}", .{ index, hit.title });
            if (hit.date.len > 0) try w.print(" ({s})", .{hit.date});
            try w.print("\n   {s}\n", .{hit.url});
            if (hit.snippet.len > 0) {
                const snippet = text_utils.utf8PrefixByBytes(hit.snippet, max_text_snippet_bytes);
                try w.writeAll("   ");
                for (snippet) |c| try w.writeByte(if (c == '\n' or c == '\r' or c == '\t') ' ' else c);
                if (snippet.len < hit.snippet.len) try w.writeAll("...");
                try w.writeByte('\n');
            }
        }
        if (self.failures.len > 0) {
            try w.writeAll("\nfell back past:\n");
            try self.writeFailures(w);
        }
        return out.toOwnedSlice();
    }

    fn writeFailures(self: Snapshot, w: *std.Io.Writer) !void {
        for (self.failures) |failure| try w.print("  {s}: {s}\n", .{ failure.provider, failure.reason });
    }

    pub fn renderJson(self: Snapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        var json: std.json.Stringify = .{ .writer = &out.writer };
        try json.beginObject();
        try json.objectField("kind");
        try json.write("web_search");
        try json.objectField("query");
        try json.write(self.query);
        try json.objectField("recency");
        try json.write(if (self.recency) |recency| @tagName(recency) else null);
        try json.objectField("limit");
        try json.write(self.limit);
        try json.objectField("provider");
        try json.write(self.provider);
        if (self.error_message) |message| {
            try json.objectField("error");
            try json.write(message);
        }
        try json.objectField("answer");
        try json.write(if (self.answer.len > 0) self.answer else null);
        try json.objectField("results");
        try json.beginArray();
        for (self.results) |hit| {
            try json.beginObject();
            try json.objectField("title");
            try json.write(hit.title);
            try json.objectField("url");
            try json.write(hit.url);
            try json.objectField("snippet");
            try json.write(if (hit.snippet.len > 0) hit.snippet else null);
            try json.objectField("date");
            try json.write(if (hit.date.len > 0) hit.date else null);
            try json.endObject();
        }
        try json.endArray();
        try json.objectField("failures");
        try json.beginArray();
        for (self.failures) |failure| {
            try json.beginObject();
            try json.objectField("provider");
            try json.write(failure.provider);
            try json.objectField("reason");
            try json.write(failure.reason);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
        return out.toOwnedSlice();
    }
};

test "search snapshot renders text and JSON from the same results" {
    const alloc = std.testing.allocator;
    var hits = [_]bank.Hit{.{ .title = @constCast("Zig"), .url = @constCast("https://ziglang.org"), .snippet = @constCast("A language\nfor robust software"), .date = @constCast("2026-10-01") }};
    var reason = "rate limited (HTTP 429)".*;
    const failures = [_]bank.Failure{.{ .provider = "brave", .reason = &reason }};
    const snapshot = Snapshot{ .query = "zig", .limit = 5, .provider = "duckduckgo", .results = &hits, .failures = &failures };

    const text = try snapshot.render(alloc, .text);
    defer alloc.free(text);
    try std.testing.expectEqualStrings(
        "duckduckgo \u{b7} 1 result\n\n1. Zig (2026-10-01)\n   https://ziglang.org\n   A language for robust software\n\nfell back past:\n  brave: rate limited (HTTP 429)\n",
        text,
    );

    const json = try snapshot.render(alloc, .json);
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"web_search\",\"query\":\"zig\",\"recency\":null,\"limit\":5,\"provider\":\"duckduckgo\",\"answer\":null,\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\",\"snippet\":\"A language\\nfor robust software\",\"date\":\"2026-10-01\"}],\"failures\":[{\"provider\":\"brave\",\"reason\":\"rate limited (HTTP 429)\"}]}",
        json,
    );
}

test "search snapshot reports an outright failure" {
    const alloc = std.testing.allocator;
    const snapshot = Snapshot{ .query = "zig", .limit = 10, .error_message = "unknown provider: nope" };
    const text = try snapshot.render(alloc, .text);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("search failed: unknown provider: nope\n", text);
    try std.testing.expect(!snapshot.succeeded());
}
