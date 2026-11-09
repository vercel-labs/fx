const std = @import("std");
const selected_schema = @import("selected_schema.zig");
const tool_names = @import("tool_names.zig");
const permissions = @import("../permissions/permissions.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");
const context_limits = @import("../config/context_limits.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const capability_retrieval = @import("../tooling/capability_retrieval.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const Allocator = std.mem.Allocator;
const mcp_server_instruction_search_bytes = context_limits.Name.mcp_server_instructions_bytes.defaultBytes();
const mcp_tool_description_search_bytes: usize = 2 * 1024;
const mcp_tool_schema_search_bytes: usize = 4 * 1024;
const catalog_state = @import("catalog_state.zig");
const McpTool = catalog_state.McpTool;

const server_not_found_output = "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null,\"state\":\"server_not_found\"}";

/// The page a search names no configured server for.
pub fn renderServerNotFound(alloc: Allocator) ![]u8 {
    return alloc.dupe(u8, server_not_found_output);
}

/// `page`, a search's JSON object, with why each server it couldn't look in
/// was skipped, so a model that found nothing hears why. Takes `page`.
pub fn withUnavailable(alloc: Allocator, page: []u8, reasons: []const []const u8) ![]u8 {
    if (page.len == 0 or page[page.len - 1] != '}') return page;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(page[0 .. page.len - 1]);
    try out.writer.writeAll(",\"unavailable\":[");
    for (reasons, 0..) |reason, i| {
        if (i > 0) try out.writer.writeByte(',');
        try writeEncodedJsonScalar(alloc, &out.writer, reason);
    }
    try out.writer.writeAll("]}");
    const result = try out.toOwnedSlice();
    alloc.free(page);
    return result;
}

test "a page that matched nothing names the servers the search couldn't look in" {
    const alloc = std.testing.allocator;
    const page = try alloc.dupe(u8, "{\"tools\":[],\"count\":0}");
    // Text for the model is encoded as everywhere else on the page.
    const out = try withUnavailable(alloc, page, &.{ "MCP server 'linear' needs a login.", "MCP server 'say \"hi\"' is unavailable: it did not start" });
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "{\"tools\":[],\"count\":0,\"unavailable\":[\"MCP server 'linear' needs a login.\",\"MCP server 'say &quot;hi&quot;' is unavailable: it did not start\"]}",
        out,
    );
}

/// One tool a search may return. The strings and the tool are borrowed for
/// the search.
pub const Candidate = struct {
    server_name: []const u8,
    instructions: ?[]const u8,
    tool: *const McpTool,
    binding: tool_mcp_runtime.Binding,
};

/// Whether a tool may appear in a search at all: no rule denies it, and the
/// model's text projection keeps its names intact.
pub fn searchable(scratch: Allocator, permission_rules: types.PermissionRuleSet, server_name: []const u8, tool: *const McpTool) !bool {
    if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) return false;
    return try tool_result_limits.modelProjectionPreservesText(scratch, server_name) and
        try tool_result_limits.modelProjectionPreservesText(scratch, tool.prefixed_name);
}

/// Ranks `candidates` for `request` and renders the page the model sees,
/// within the search and schema budgets. A tool whose schema the search loads
/// is marked `schema_loaded`; its schema carries the whole description, so a
/// shortened one on the page is not reported as truncated. `matched`, when
/// given, receives the index of every ranked candidate.
pub fn rank(
    alloc: Allocator,
    candidates: []const Candidate,
    request: capability_retrieval.Request,
    limits: context_limits.Values,
    matched: ?*std.ArrayList(usize),
) !tool_mcp_runtime.SearchResult {
    const documents = try alloc.alloc(capability_retrieval.Document, candidates.len);
    defer alloc.free(documents);
    for (candidates, documents) |candidate, *document| {
        const tool = candidate.tool;
        const searchable_instructions = if (candidate.instructions) |instructions|
            instructions[0..context_limits.utf8PrefixLength(instructions, mcp_server_instruction_search_bytes)]
        else
            "";
        const searchable_description = tool.description[0..context_limits.utf8PrefixLength(
            tool.description,
            mcp_tool_description_search_bytes,
        )];
        const searchable_schema = tool.input_schema_json[0..context_limits.utf8PrefixLength(
            tool.input_schema_json,
            mcp_tool_schema_search_bytes,
        )];
        document.* = .{
            .identities = .{ tool.original_name, tool.prefixed_name },
            .stable_key = tool.prefixed_name,
            .primary = .{
                candidate.server_name,
                tool.original_name,
                tool.prefixed_name,
                tool.title orelse "",
            },
            .primary_extra = tool.tags,
            .secondary = .{
                searchable_description,
                searchable_schema,
                searchable_instructions,
            },
        };
    }
    var page = try capability_retrieval.retrieve(
        alloc,
        request,
        .mcp,
        documents,
    );
    defer page.deinit(alloc);
    const matches = try alloc.alloc(Candidate, page.matches.len);
    defer alloc.free(matches);
    if (matched) |out| try out.ensureUnusedCapacity(alloc, page.matches.len);
    for (page.matches, matches) |match, *candidate| {
        candidate.* = candidates[match.document_index];
        if (matched) |out| out.appendAssumeCapacity(match.document_index);
    }

    // Schemas are chosen before the page is rendered, so the page can say
    // which tools this search loads in full.
    var loads = try SchemaLoads.init(alloc, matches, limits);
    defer loads.deinit(alloc);

    const full_cursor = try page.cursorAfter(alloc, matches.len);
    defer if (full_cursor) |cursor| alloc.free(cursor);
    const full = try renderSearchResult(
        alloc,
        matches,
        matches.len,
        page.total_matches,
        full_cursor,
        limits.mcp_description_bytes,
        limits.mcp_search_result_bytes,
        &loads,
        0,
        false,
    );
    const observed_bytes = full.len;
    const effective_bytes = limits.mcp_search_result_bytes.effectiveBytes();
    const limit_triggered = full.len > effective_bytes;
    var shown = matches.len;
    var output = full;
    if (limit_triggered) {
        alloc.free(full);
        while (true) {
            const candidate_cursor = try page.cursorAfter(alloc, shown);
            defer if (candidate_cursor) |cursor| alloc.free(cursor);
            const candidate = try renderSearchResult(
                alloc,
                matches,
                shown,
                page.total_matches,
                candidate_cursor,
                limits.mcp_description_bytes,
                limits.mcp_search_result_bytes,
                &loads,
                observed_bytes,
                true,
            );
            if (candidate.len <= effective_bytes or shown == 0) {
                output = candidate;
                break;
            }
            alloc.free(candidate);
            shown -= 1;
        }
    }
    errdefer alloc.free(output);
    var notice = try renderSearchNotice(alloc, matches, shown, limits, observed_bytes, limit_triggered, &loads);
    errdefer if (notice) |value| alloc.free(value);
    try loads.appendNotices(alloc, shown, &notice);
    const selected = try loads.take(alloc, shown);
    return tool_mcp_runtime.SearchResult{ .model_output = output, .notice = notice, .selected_tools = selected };
}

fn appendSearchNotice(alloc: Allocator, notice: *?[]u8, message: []const u8) !void {
    const combined = if (notice.*) |current| try alloc.print("{s}\n{s}", .{ current, message }) else try alloc.dupe(u8, message);
    if (notice.*) |current| alloc.free(current);
    notice.* = combined;
}

/// The schemas a search loads, one entry per match. The budget is spent in
/// match order and stops at the first schema that doesn't fit, so the loads
/// among the first `n` matches are the ones a page showing only those makes.
const SchemaLoads = struct {
    entries: []Entry,
    /// The match the budget ran out on.
    exhausted_at: ?usize = null,

    const Entry = struct {
        /// The schema the search loads, or null when it was rejected or the
        /// budget ran out first.
        tool: ?tool_mcp_runtime.SelectedTool = null,
        /// The notice the schema's projection raised.
        notice: ?[]u8 = null,
    };

    fn init(alloc: Allocator, matches: []const Candidate, limits: context_limits.Values) !SchemaLoads {
        const entries = try alloc.alloc(Entry, matches.len);
        @memset(entries, .{});
        var loads: SchemaLoads = .{ .entries = entries };
        errdefer loads.deinit(alloc);
        var remaining = limits.mcp_selected_schema_bytes.effectiveBytes();
        for (matches, entries, 0..) |match, *entry, index| {
            const projection = try selected_schema.project(alloc, match.tool.*, match.instructions, limits);
            const payload = switch (projection) {
                .selected, .rejected => |value| value,
            };
            entry.notice = payload.notice;
            if (projection == .rejected) {
                alloc.free(payload.model_output);
                continue;
            }
            if (payload.model_output.len > remaining) {
                alloc.free(payload.model_output);
                loads.exhausted_at = index;
                break;
            }
            errdefer alloc.free(payload.model_output);
            const name = try alloc.dupe(u8, match.tool.prefixed_name);
            entry.tool = .{ .name = name, .schema_json = payload.model_output, .mcp_binding = match.binding };
            remaining -= payload.model_output.len;
        }
        return loads;
    }

    fn deinit(loads: *SchemaLoads, alloc: Allocator) void {
        for (loads.entries) |entry| {
            if (entry.tool) |tool| tool.deinit(alloc);
            if (entry.notice) |notice| alloc.free(notice);
        }
        alloc.free(loads.entries);
        loads.* = undefined;
    }

    fn loaded(loads: *const SchemaLoads, index: usize) bool {
        return loads.entries[index].tool != null;
    }

    /// Appends the notices of the first `shown` matches, in match order.
    fn appendNotices(loads: *const SchemaLoads, alloc: Allocator, shown: usize, notice: *?[]u8) !void {
        for (loads.entries[0..shown], 0..) |entry, index| {
            if (entry.notice) |message| try appendSearchNotice(alloc, notice, message);
            if (loads.exhausted_at == index) {
                try appendSearchNotice(alloc, notice, "[context] Additional MCP schemas exceed the search loading budget; narrow the search or select a tool explicitly.");
            }
        }
    }

    /// Hands over the schemas loaded among the first `shown` matches. Caller
    /// owns the slice and its tools.
    fn take(loads: *SchemaLoads, alloc: Allocator, shown: usize) ![]const tool_mcp_runtime.SelectedTool {
        var count: usize = 0;
        for (loads.entries[0..shown]) |entry| count += @intFromBool(entry.tool != null);
        const out = try alloc.alloc(tool_mcp_runtime.SelectedTool, count);
        var next: usize = 0;
        for (loads.entries[0..shown]) |*entry| {
            if (entry.tool) |tool| {
                out[next] = tool;
                next += 1;
                entry.tool = null;
            }
        }
        return out;
    }
};

fn renderSearchResult(
    alloc: Allocator,
    matches: []const Candidate,
    selected_count: usize,
    total_matches: usize,
    next_cursor: ?[]const u8,
    description_limit: context_limits.Resolved,
    result_limit: context_limits.Resolved,
    loads: *const SchemaLoads,
    observed_bytes: usize,
    limit_triggered: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"tools\":[");
    for (matches[0..selected_count], 0..) |match, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeToolMetadataJson(alloc, &out.writer, match, description_limit, loads.loaded(index));
    }
    try out.writer.print(
        "],\"count\":{d},\"total_matches\":{d},\"more_available\":{s},\"next_cursor\":",
        .{ selected_count, total_matches, if (next_cursor != null) "true" else "false" },
    );
    try std.json.Stringify.value(next_cursor, .{}, &out.writer);
    if (limit_triggered) {
        try out.writer.print(
            ",\"context_limit\":{{\"name\":\"mcp_search_result_bytes\",\"action\":\"omitted\",\"omitted_count\":{d},\"observed_bytes\":{d},\"effective_bytes\":{d},\"source\":",
            .{ matches.len - selected_count, observed_bytes, result_limit.effectiveBytes() },
        );
        try std.json.Stringify.value(result_limit.source.label(), .{}, &out.writer);
        try out.writer.writeAll(",\"override\":\"--context-limit mcp_search_result_bytes=BYTES|off\"}");
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn renderSearchNotice(
    alloc: Allocator,
    matches: []const Candidate,
    selected_count: usize,
    limits: context_limits.Values,
    observed_bytes: usize,
    result_limit_triggered: bool,
    loads: *const SchemaLoads,
) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (matches[0..selected_count], 0..) |match, index| {
        // A loaded tool's schema carries its whole description.
        if (loads.loaded(index)) continue;
        const tool = match.tool;
        const encoded_description = try encodeScalarAlloc(alloc, tool.description);
        defer alloc.free(encoded_description);
        if (encoded_description.len <= limits.mcp_description_bytes.effectiveBytes()) continue;
        try out.writer.writeAll("[context] MCP description for \"");
        try model_context_encoding.writeScalar(&out.writer, tool.prefixed_name);
        try out.writer.print(
            "\" truncated: observed={d} bytes effective={d} bytes source={s}; override with --context-limit mcp_description_bytes=BYTES|off\n",
            .{ encoded_description.len, limits.mcp_description_bytes.effectiveBytes(), limits.mcp_description_bytes.source.label() },
        );
    }
    if (result_limit_triggered) {
        try out.writer.print("[context] MCP search omitted {d} tool(s) (", .{matches.len - selected_count});
        for (matches[selected_count..], 0..) |match, index| {
            if (index > 0) try out.writer.writeAll(", ");
            try model_context_encoding.writeScalar(&out.writer, match.tool.prefixed_name);
        }
        try out.writer.print(
            "): observed={d} bytes effective={d} bytes source={s}; override with --context-limit mcp_search_result_bytes=BYTES|off",
            .{ observed_bytes, limits.mcp_search_result_bytes.effectiveBytes(), limits.mcp_search_result_bytes.source.label() },
        );
    }
    return if (out.written().len > 0) try out.toOwnedSlice() else null;
}

fn writeToolMetadataJson(
    alloc: Allocator,
    writer: *std.Io.Writer,
    match: Candidate,
    description_limit: context_limits.Resolved,
    /// The search loads this tool's schema, which carries its whole
    /// description, so a shortened one here is only a preview.
    schema_loaded: bool,
) !void {
    const tool = match.tool;
    const bounded = try boundedEncodedScalar(
        alloc,
        tool.description,
        description_limit.effectiveBytes(),
    );
    defer alloc.free(bounded.text);
    try writer.writeAll("{\"name\":");
    try writeEncodedJsonScalar(alloc, writer, tool.prefixed_name);
    try writer.writeAll(",\"server\":");
    try writeEncodedJsonScalar(alloc, writer, match.server_name);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(bounded.text, .{}, writer);
    try writer.writeAll(",\"usage\":[");
    for (tool.tags, 0..) |tag, index| {
        if (index > 0) try writer.writeByte(',');
        try writeEncodedJsonScalar(alloc, writer, tag);
    }
    try writer.writeByte(']');
    if (schema_loaded) {
        try writer.writeAll(",\"schema_loaded\":true");
    } else if (bounded.observed_bytes > description_limit.effectiveBytes()) {
        try writer.print(
            ",\"context_limit\":{{\"name\":\"mcp_description_bytes\",\"action\":\"truncated\",\"observed_bytes\":{d},\"effective_bytes\":{d},\"source\":",
            .{ bounded.observed_bytes, description_limit.effectiveBytes() },
        );
        try std.json.Stringify.value(description_limit.source.label(), .{}, writer);
        try writer.writeAll(",\"override\":\"--context-limit mcp_description_bytes=BYTES|off\"}");
    }
    try writer.writeByte('}');
}

const BoundedEncodedScalar = struct {
    text: []u8,
    observed_bytes: usize,
};

fn boundedEncodedScalar(alloc: Allocator, value: []const u8, max_bytes: usize) !BoundedEncodedScalar {
    const encoded = try encodeScalarAlloc(alloc, value);
    errdefer alloc.free(encoded);
    const observed = encoded.len;
    if (observed <= max_bytes) return .{ .text = encoded, .observed_bytes = observed };

    var prefix_len = context_limits.utf8PrefixLength(encoded, max_bytes);
    if (std.mem.findScalarLast(u8, encoded[0..prefix_len], '&')) |amp_index| {
        if (std.mem.findScalar(u8, encoded[amp_index..prefix_len], ';') == null) prefix_len = amp_index;
    }
    return .{ .text = try alloc.realloc(encoded, prefix_len), .observed_bytes = observed };
}

const encodeScalarAlloc = model_context_encoding.scalarAlloc;
const writeEncodedJsonScalar = model_context_encoding.writeJsonScalar;

/// Whether `query` names `identity` as a whole word, ignoring case.
pub fn queryContainsCompleteIdentity(query: []const u8, identity: []const u8) bool {
    if (identity.len == 0 or identity.len > query.len) return false;

    var start: usize = 0;
    while (start <= query.len - identity.len) : (start += 1) {
        const end = start + identity.len;
        if (!std.ascii.eqlIgnoreCase(query[start..end], identity)) continue;
        if (start > 0 and tool_names.isIdentifierByte(query[start - 1])) continue;
        if (end < query.len and tool_names.isIdentifierByte(query[end])) continue;
        return true;
    }
    return false;
}

pub const AuthenticationRequired = union(enum) {
    /// What the user runs to sign in.
    oauth: []const u8,
    /// The variable to set before starting fx.
    bearer_environment: []const u8,
};

/// The page a search returns when the server it names needs a sign-in.
pub fn writeAuthenticationRequired(alloc: Allocator, server_name: []const u8, required: AuthenticationRequired) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(
        "{\"tools\":[],\"count\":0,\"authentication_required\":{\"server\":",
    );
    try writeEncodedJsonScalar(alloc, &out.writer, server_name);
    switch (required) {
        .oauth => |guidance| {
            try out.writer.writeAll(",\"interactive\":true,\"message\":");
            try writeEncodedJsonScalar(alloc, &out.writer, guidance);
        },
        .bearer_environment => |variable| {
            try out.writer.writeAll(",\"interactive\":false,\"environment\":");
            try writeEncodedJsonScalar(alloc, &out.writer, variable);
            try out.writer.writeAll(",\"message\":\"Set this environment variable before starting fx.\"");
        },
    }
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

/// The page a search returns when the server it names is down.
pub fn writeServerFailure(alloc: Allocator, server_name: []const u8, failure: []const u8) ![]u8 {
    const message = try alloc.print("MCP server '{s}' is unavailable: {s}", .{ server_name, failure });
    defer alloc.free(message);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(
        "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null,\"state\":\"server_failed\",\"error\":",
    );
    try writeEncodedJsonScalar(alloc, &out.writer, message);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

test "MCP search names why the server it names is down" {
    const alloc = std.testing.allocator;
    const output = try writeServerFailure(alloc, "devtools", "MCP server exited with code 1 before completing startup: npm error code E401");
    defer alloc.free(output);
    try std.testing.expectEqualStrings(
        "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null,\"state\":\"server_failed\"," ++
            "\"error\":\"MCP server 'devtools' is unavailable: MCP server exited with code 1 before completing startup: npm error code E401\"}",
        output,
    );
}

const lexical_relevance = @import("../shared/lexical_relevance.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");

/// Three tools on one server, searched by its inventory.
const SearchFixture = struct {
    names: [3][9]u8 = .{ "mcp_srv_a".*, "mcp_srv_b".*, "mcp_srv_c".* },
    descriptions: [3][3000]u8 = undefined,
    schema: [17]u8 = "{\"type\":\"object\"}".*,
    tools: [3]McpTool = undefined,
    candidates: [3]Candidate = undefined,

    /// Points the tools at the fixture's own storage, so it stays in place
    /// after.
    fn init(f: *SearchFixture, description_bytes: [3]usize) void {
        for (&f.tools, &f.candidates, &f.names, &f.descriptions, description_bytes) |*tool, *candidate, *name, *description, len| {
            @memset(description, 'd');
            tool.* = .{ .original_name = name[8..], .prefixed_name = name, .description = description[0..len], .input_schema_json = &f.schema, .tags = &.{} };
            candidate.* = .{
                .server_name = "srv",
                .instructions = null,
                .tool = tool,
                .binding = .{ .runtime_generation = 1, .connection_generation = 1, .catalog_generation = 1, .auth_generation = 1 },
            };
        }
    }

    fn search(f: *const SearchFixture, alloc: Allocator, limits: context_limits.Values) !tool_mcp_runtime.SearchResult {
        const query = try lexical_relevance.prepare("");
        return rank(alloc, &f.candidates, .{ .query = &query, .kind = .mcp, .server = "srv" }, limits, null);
    }

    fn fullDescription(f: *const SearchFixture, name: []const u8) []const u8 {
        for (f.tools) |tool| if (std.mem.eql(u8, tool.prefixed_name, name)) return tool.description;
        unreachable;
    }
};

fn selectedNamed(result: tool_mcp_runtime.SearchResult, name: []const u8) ?tool_mcp_runtime.SelectedTool {
    for (result.selected_tools) |tool| if (std.mem.eql(u8, tool.name, name)) return tool;
    return null;
}

test "MCP search marks the tools it loads and doesn't call their descriptions truncated" {
    const alloc = std.testing.allocator;
    var f: SearchFixture = .{};
    f.init(.{ 3000, 12, 12 });
    var result = try f.search(alloc, .{});
    defer result.deinit(alloc);

    try std.testing.expect(result.notice == null);
    try std.testing.expectEqual(@as(usize, 3), result.selected_tools.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.model_output, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), tools.len);
    for (tools) |tool| {
        const name = tool.object.get("name").?.string;
        try std.testing.expect(tool.object.get("schema_loaded").?.bool);
        try std.testing.expect(tool.object.get("context_limit") == null);
        try std.testing.expect(tool.object.get("purpose") == null);
        // The page shows a preview; the loaded schema carries all of it.
        const full = f.fullDescription(name);
        try std.testing.expect(tool.object.get("description").?.string.len <= context_limits.Name.mcp_description_bytes.defaultBytes());
        try std.testing.expect(std.mem.find(u8, selectedNamed(result, name).?.schema_json, full) != null);
    }
}

test "MCP search still reports a description truncated when the schema budget leaves the tool out" {
    const alloc = std.testing.allocator;
    var f: SearchFixture = .{};
    f.init(.{ 3000, 3000, 3000 });
    var limits: context_limits.Values = .{};
    // Room for one of the schemas, not two.
    limits.mcp_selected_schema_bytes = .{ .value = .{ .bytes = 4096 }, .source = .command_line };
    var result = try f.search(alloc, limits);
    defer result.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.model_output, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), tools.len);
    try std.testing.expectEqual(@as(usize, 1), result.selected_tools.len);
    const loaded_name = tools[0].object.get("name").?.string;
    try std.testing.expectEqualStrings(loaded_name, result.selected_tools[0].name);
    try std.testing.expect(tools[0].object.get("schema_loaded").?.bool);
    try std.testing.expect(tools[0].object.get("context_limit") == null);

    const notice = result.notice.?;
    var buffer: [64]u8 = undefined;
    try std.testing.expect(std.mem.find(u8, notice, try std.mem.print(&buffer, "MCP description for \"{s}\"", .{loaded_name})) == null);
    for (tools[1..]) |tool| {
        try std.testing.expect(tool.object.get("schema_loaded") == null);
        const limit = tool.object.get("context_limit").?.object;
        try std.testing.expectEqualStrings("mcp_description_bytes", limit.get("name").?.string);
        try std.testing.expectEqualStrings("truncated", limit.get("action").?.string);
        const named = try std.mem.print(&buffer, "MCP description for \"{s}\"", .{tool.object.get("name").?.string});
        try std.testing.expect(std.mem.find(u8, notice, named) != null);
    }
    try std.testing.expect(std.mem.find(u8, notice, "Additional MCP schemas exceed the search loading budget") != null);
}

test "MCP search loads only the schemas of the tools its page has room for" {
    const alloc = std.testing.allocator;
    var f: SearchFixture = .{};
    f.init(.{ 12, 12, 12 });
    var whole = try f.search(alloc, .{});
    const whole_bytes = whole.model_output.len;
    whole.deinit(alloc);

    var limits: context_limits.Values = .{};
    limits.mcp_search_result_bytes = .{ .value = .{ .bytes = whole_bytes - 1 }, .source = .command_line };
    var result = try f.search(alloc, limits);
    defer result.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.model_output, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expect(tools.len < 3);
    try std.testing.expectEqualStrings("omitted", parsed.value.object.get("context_limit").?.object.get("action").?.string);
    try std.testing.expectEqual(tools.len, result.selected_tools.len);
    for (tools, result.selected_tools) |tool, selected| {
        try std.testing.expectEqualStrings(tool.object.get("name").?.string, selected.name);
        try std.testing.expect(tool.object.get("schema_loaded").?.bool);
    }
    try std.testing.expect(std.mem.find(u8, result.notice.?, "MCP search omitted") != null);
}

fn searchUnderPressure(alloc: Allocator) !void {
    var f: SearchFixture = .{};
    f.init(.{ 3000, 3000, 12 });
    var limits: context_limits.Values = .{};
    limits.mcp_selected_schema_bytes = .{ .value = .{ .bytes = 4096 }, .source = .command_line };
    limits.mcp_search_result_bytes = .{ .value = .{ .bytes = 1800 }, .source = .command_line };
    // The page's writer reports a failed allocation as WriteFailed.
    var result = f.search(alloc, limits) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
    defer result.deinit(alloc);
    try std.testing.expect(result.selected_tools.len > 0);
}

test "MCP search frees every loaded schema and notice when memory runs out partway" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, searchUnderPressure, .{});
}

/// Text a server may send in a description: plain words, the characters the
/// model encoding escapes, and multibyte UTF-8, so a cut can land inside a
/// sequence or an entity.
const fuzz_text_pieces = [_][]const u8{ "a", "word ", "&", "<", ">", "\"", "\\", "\n", "\x01", "\u{e9}", "\u{20ac}", "\u{6f22}", "\u{1f600}", "&amp;", "</tool>" };

fn fuzzText(smith: *std.testing.Smith, buffer: []u8) []u8 {
    const target: usize = smith.valueRangeAtMost(u16, 0, @intCast(buffer.len));
    var len: usize = 0;
    while (len < target) {
        const piece = fuzz_text_pieces[smith.index(fuzz_text_pieces.len)];
        var repeats: usize = smith.valueRangeAtMost(u16, 1, 256);
        while (repeats > 0 and len + piece.len <= buffer.len) : (repeats -= 1) {
            @memcpy(buffer[len..][0..piece.len], piece);
            len += piece.len;
        }
        if (len + piece.len > buffer.len) break;
    }
    return buffer[0..len];
}

fn fuzzLimit(smith: *std.testing.Smith, name: context_limits.Name, max_bytes: u16) context_limits.Resolved {
    return switch (smith.valueRangeAtMost(u8, 0, 8)) {
        0 => .{ .value = .off, .source = .command_line },
        1, 2 => .{ .value = .{ .bytes = name.defaultBytes() }, .source = .compiled_default },
        else => .{ .value = .{ .bytes = smith.valueRangeAtMost(u16, 0, max_bytes) }, .source = .command_line },
    };
}

fn fuzzSearchPage(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    const max_tools = 6;
    var names: [max_tools][9]u8 = undefined;
    var descriptions: [max_tools][3000]u8 = undefined;
    var schemas: [max_tools][1200]u8 = undefined;
    var instruction_buffer: [3000]u8 = undefined;
    var tools: [max_tools]McpTool = undefined;
    var candidates: [max_tools]Candidate = undefined;

    const count: usize = smith.valueRangeAtMost(u8, 0, max_tools);
    const instructions: ?[]const u8 = if (smith.boolWeighted(1, 1)) fuzzText(smith, &instruction_buffer) else null;
    for (0..count) |index| {
        const name = try std.mem.print(&names[index], "mcp_srv_{d}", .{index});
        const schema_open = "{\"type\":\"object\",\"description\":\"";
        const padding: usize = smith.valueRangeAtMost(u16, 0, schemas[index].len - schema_open.len - 2);
        const schema = schemas[index][0 .. schema_open.len + padding + 2];
        @memcpy(schema[0..schema_open.len], schema_open);
        @memset(schema[schema_open.len..][0..padding], 'x');
        @memcpy(schema[schema_open.len + padding ..], "\"}");
        tools[index] = .{
            .original_name = name[8..],
            .prefixed_name = name,
            .description = fuzzText(smith, &descriptions[index]),
            .input_schema_json = schema,
            .tags = &.{},
        };
        candidates[index] = .{
            .server_name = "srv",
            .instructions = instructions,
            .tool = &tools[index],
            .binding = .{ .runtime_generation = 1, .connection_generation = 1, .catalog_generation = 1, .auth_generation = 1 },
        };
    }
    var limits: context_limits.Values = .{};
    limits.mcp_description_bytes = fuzzLimit(smith, .mcp_description_bytes, 2048);
    limits.mcp_search_result_bytes = fuzzLimit(smith, .mcp_search_result_bytes, 24 * 1024);
    limits.mcp_selected_schema_bytes = fuzzLimit(smith, .mcp_selected_schema_bytes, 16 * 1024);
    limits.mcp_server_instructions_bytes = fuzzLimit(smith, .mcp_server_instructions_bytes, 4096);
    const query = try lexical_relevance.prepare("");
    const request: capability_retrieval.Request = .{
        .query = &query,
        .kind = .mcp,
        .server = "srv",
        .limit = smith.valueRangeAtMost(u8, 1, capability_retrieval.max_limit),
    };
    var result = rank(alloc, candidates[0..count], request, limits, null) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.TestUnexpectedError,
    };
    defer result.deinit(alloc);
    try expectConsistentSearchPage(alloc, result, tools[0..count], limits);
}

/// The page, its notice, and its loaded schemas agree: each tool the page
/// marks loaded is the next loaded schema, which carries the tool's whole
/// description, and only a tool left unloaded is called truncated.
fn expectConsistentSearchPage(alloc: Allocator, result: tool_mcp_runtime.SearchResult, tools: []const McpTool, limits: context_limits.Values) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.model_output, .{});
    defer parsed.deinit();
    const shown = parsed.value.object.get("tools").?.array.items;
    if (result.model_output.len > limits.mcp_search_result_bytes.effectiveBytes()) {
        try std.testing.expectEqual(@as(usize, 0), shown.len);
    }
    var loaded: usize = 0;
    var schema_bytes: usize = 0;
    for (shown) |entry| {
        const object = entry.object;
        const name = object.get("name").?.string;
        const tool = for (tools) |candidate| {
            if (std.mem.eql(u8, candidate.prefixed_name, name)) break candidate;
        } else return error.TestUnexpectedResult;
        try std.testing.expect(object.get("purpose") == null);
        var line_buffer: [64]u8 = undefined;
        const line = try std.mem.print(&line_buffer, "MCP description for \"{s}\"", .{name});
        const in_notice = if (result.notice) |notice| std.mem.find(u8, notice, line) != null else false;
        const encoded = try encodeScalarAlloc(alloc, tool.description);
        defer alloc.free(encoded);
        if (object.get("schema_loaded")) |flag| {
            try std.testing.expect(flag.bool);
            try std.testing.expect(object.get("context_limit") == null);
            try std.testing.expect(!in_notice);
            try std.testing.expect(loaded < result.selected_tools.len);
            const selected = result.selected_tools[loaded];
            try std.testing.expectEqualStrings(name, selected.name);
            var schema = try std.json.parseFromSlice(std.json.Value, alloc, selected.schema_json, .{});
            defer schema.deinit();
            try std.testing.expect(std.mem.startsWith(u8, schema.value.object.get("description").?.string, encoded));
            schema_bytes += selected.schema_json.len;
            loaded += 1;
        } else {
            const truncated = encoded.len > limits.mcp_description_bytes.effectiveBytes();
            try std.testing.expectEqual(truncated, object.get("context_limit") != null);
            try std.testing.expectEqual(truncated, in_notice);
        }
    }
    try std.testing.expectEqual(loaded, result.selected_tools.len);
    try std.testing.expect(schema_bytes <= limits.mcp_selected_schema_bytes.effectiveBytes());
}

test "MCP search pages agree with the schemas they load under fuzzed tools and limits" {
    try std.testing.fuzz({}, fuzzSearchPage, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "\x03\x01\x08\x00\x00\x08\x00\x00\x08\x00\x00",
            "\x06\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
        }) ++ @import("fuzz_corpus").mcp_search_page.*),
    });
}
