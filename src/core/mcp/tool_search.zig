const server_views = @import("server_views.zig");
const std = @import("std");
const server_connection = @import("server_connection.zig");
const io_mod = @import("../shared/io.zig");
const selected_schema = @import("selected_schema.zig");
const tool_names = @import("tool_names.zig");
const tool_catalog = @import("tool_catalog.zig");
const tool_snapshot = @import("tool_snapshot.zig");
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
const operation_authority = @import("operation_authority.zig");
const catalog_state = @import("catalog_state.zig");
const McpTool = catalog_state.McpTool;
const OperationAccessGuard = operation_authority.Guard;
const bindingForSnapshot = tool_snapshot.binding;
const serverAuthenticationState = server_views.serverAuthenticationState;
const McpServer = server_connection.Server;
const CatalogAuthWitness = tool_catalog.CatalogAuthWitness;
const catalogAuthWitness = tool_catalog.catalogAuthWitness;
const validateCatalogAuthWitnesses = tool_catalog.validateCatalogAuthWitnesses;

pub fn search(
    alloc: Allocator,
    runtime_generation: u64,
    server_handles: []const *McpServer,
    request: capability_retrieval.Request,
    permission_rules: types.PermissionRuleSet,
    limits: context_limits.Values,
    operation_access: *const OperationAccessGuard,
) !tool_mcp_runtime.SearchResult {
    var auth_witnesses: std.ArrayList(CatalogAuthWitness) = .empty;
    defer auth_witnesses.deinit(alloc);
    if (try renderAuthenticationRequired(
        alloc,
        server_handles,
        operation_access,
        request.server orelse request.query.raw,
    )) |output| {
        return tool_mcp_runtime.SearchResult{ .model_output = output, .notice = null };
    }
    var candidate_capacity: usize = 0;
    var server_configured = request.server == null;
    for (server_handles) |server| {
        if (request.server) |name| {
            if (!std.mem.eql(u8, server.config.name, name)) continue;
            server_configured = true;
        }
        if (!server.isPublished()) continue;
        candidate_capacity = try std.math.add(
            usize,
            candidate_capacity,
            server.tool_catalog.tools.items.len,
        );
    }
    if (!server_configured) {
        return tool_mcp_runtime.SearchResult{
            .model_output = try alloc.dupe(
                u8,
                "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null,\"state\":\"server_not_found\"}",
            ),
        };
    }
    const candidate_storage = try alloc.alloc(ToolSearchMatch, candidate_capacity);
    defer alloc.free(candidate_storage);
    const documents = try alloc.alloc(capability_retrieval.Document, candidate_capacity);
    defer alloc.free(documents);
    var identity_scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer identity_scratch_state.deinit();
    const identity_scratch = identity_scratch_state.allocator();
    var candidate_count: usize = 0;
    for (server_handles) |server| {
        if (request.server) |name| {
            if (!std.mem.eql(u8, server.config.name, name)) continue;
        }
        if (!server.isPublished() or server.state.load(.acquire) != .ready) continue;
        if (!tool_catalog.serverCatalogAvailable(server)) continue;
        if (!operation_access.allows(.{ .tool_server = server.config.name })) continue;
        const searchable_instructions = if (server.instructions) |instructions|
            instructions[0..context_limits.utf8PrefixLength(instructions, mcp_server_instruction_search_bytes)]
        else
            "";
        if (!server.isPublished()) continue;
        for (server.tool_catalog.tools.items) |*tool| {
            if (!operation_access.allows(.{ .tool = tool.prefixed_name })) continue;
            if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) continue;
            if (!try tool_result_limits.modelProjectionPreservesText(identity_scratch, server.config.name) or
                !try tool_result_limits.modelProjectionPreservesText(identity_scratch, tool.prefixed_name))
            {
                continue;
            }
            const searchable_description = tool.description[0..context_limits.utf8PrefixLength(
                tool.description,
                mcp_tool_description_search_bytes,
            )];
            const searchable_schema = tool.input_schema_json[0..context_limits.utf8PrefixLength(
                tool.input_schema_json,
                mcp_tool_schema_search_bytes,
            )];
            candidate_storage[candidate_count] = .{
                .server = server,
                .tool = tool,
            };
            documents[candidate_count] = .{
                .identities = .{ tool.original_name, tool.prefixed_name },
                .stable_key = tool.prefixed_name,
                .primary = .{
                    server.config.name,
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
            candidate_count += 1;
        }
    }
    var page = try capability_retrieval.retrieve(
        alloc,
        request,
        .mcp,
        documents[0..candidate_count],
    );
    defer page.deinit(alloc);
    const matches = try alloc.alloc(ToolSearchMatch, page.matches.len);
    defer alloc.free(matches);
    for (page.matches, 0..) |match, index| {
        matches[index] = candidate_storage[match.document_index];
    }
    for (matches) |match| {
        const generation = catalogAuthWitness(match.server) orelse continue;
        var witnessed = false;
        for (auth_witnesses.items) |witness| {
            if (witness.server == match.server) {
                witnessed = true;
                break;
            }
        }
        if (!witnessed) try auth_witnesses.append(alloc, .{
            .server = match.server,
            .generation = generation,
        });
    }

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
        0,
        false,
    );
    const observed_bytes = full.len;
    const effective_bytes = limits.mcp_search_result_bytes.effectiveBytes();
    if (full.len <= effective_bytes) {
        errdefer alloc.free(full);
        var notice = try renderSearchNotice(alloc, matches, matches.len, limits, observed_bytes, false);
        errdefer if (notice) |value| alloc.free(value);
        const selected = try selectSearchSchemas(alloc, runtime_generation, matches[0..matches.len], limits, &notice);
        errdefer tool_mcp_runtime.freeSelectedTools(alloc, selected);
        try validateCatalogAuthWitnesses(auth_witnesses.items);
        return tool_mcp_runtime.SearchResult{ .model_output = full, .notice = notice, .selected_tools = selected };
    }
    alloc.free(full);

    var selected_count = matches.len;
    var model_output: ?[]u8 = null;
    while (true) {
        const candidate_cursor = try page.cursorAfter(alloc, selected_count);
        defer if (candidate_cursor) |cursor| alloc.free(cursor);
        const candidate = try renderSearchResult(
            alloc,
            matches,
            selected_count,
            page.total_matches,
            candidate_cursor,
            limits.mcp_description_bytes,
            limits.mcp_search_result_bytes,
            observed_bytes,
            true,
        );
        if (candidate.len <= effective_bytes) {
            model_output = candidate;
            break;
        }
        if (selected_count == 0) {
            model_output = candidate;
            break;
        }
        alloc.free(candidate);
        selected_count -= 1;
    }
    const output = model_output.?;
    errdefer alloc.free(output);
    var notice = try renderSearchNotice(alloc, matches, selected_count, limits, observed_bytes, true);
    errdefer if (notice) |value| alloc.free(value);
    const selected = try selectSearchSchemas(alloc, runtime_generation, matches[0..selected_count], limits, &notice);
    errdefer tool_mcp_runtime.freeSelectedTools(alloc, selected);
    try validateCatalogAuthWitnesses(auth_witnesses.items);
    return tool_mcp_runtime.SearchResult{ .model_output = output, .notice = notice, .selected_tools = selected };
}

fn appendSearchNotice(alloc: Allocator, notice: *?[]u8, message: []const u8) !void {
    const combined = if (notice.*) |current| try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ current, message }) else try alloc.dupe(u8, message);
    if (notice.*) |current| alloc.free(current);
    notice.* = combined;
}

fn selectSearchSchemas(alloc: Allocator, runtime_generation: u64, matches: []const ToolSearchMatch, limits: context_limits.Values, notice: *?[]u8) ![]const tool_mcp_runtime.SelectedTool {
    var selected: std.ArrayList(tool_mcp_runtime.SelectedTool) = .empty;
    errdefer {
        for (selected.items) |tool| tool.deinit(alloc);
        selected.deinit(alloc);
    }
    var remaining = limits.mcp_selected_schema_bytes.effectiveBytes();
    for (matches) |match| {
        var projection = try selected_schema.project(alloc, match.tool.*, match.server.instructions, limits);
        var owned = true;
        defer if (owned) projection.deinit(alloc);
        const payload = switch (projection) {
            .selected, .rejected => |value| value,
        };
        if (payload.notice) |message| try appendSearchNotice(alloc, notice, message);
        if (projection == .rejected) continue;
        if (payload.model_output.len > remaining) {
            try appendSearchNotice(alloc, notice, "[context] Additional MCP schemas exceed the search loading budget; narrow the search or select a tool explicitly.");
            break;
        }
        const name = try alloc.dupe(u8, match.tool.prefixed_name);
        errdefer alloc.free(name);
        try selected.append(alloc, .{ .name = name, .schema_json = payload.model_output, .mcp_binding = bindingForSnapshot(runtime_generation, match.server, match.tool.*) });
        remaining -= payload.model_output.len;
        if (payload.notice) |message| alloc.free(message);
        owned = false;
    }
    return selected.toOwnedSlice(alloc);
}

const ToolSearchMatch = struct {
    server: *McpServer,
    tool: *const McpTool,
};

fn renderSearchResult(
    alloc: Allocator,
    matches: []const ToolSearchMatch,
    selected_count: usize,
    total_matches: usize,
    next_cursor: ?[]const u8,
    description_limit: context_limits.Resolved,
    result_limit: context_limits.Resolved,
    observed_bytes: usize,
    limit_triggered: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"tools\":[");
    for (matches[0..selected_count], 0..) |match, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeToolMetadataJson(alloc, &out.writer, match, description_limit);
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
    matches: []const ToolSearchMatch,
    selected_count: usize,
    limits: context_limits.Values,
    observed_bytes: usize,
    result_limit_triggered: bool,
) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (matches[0..selected_count]) |match| {
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
    match: ToolSearchMatch,
    description_limit: context_limits.Resolved,
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
    try writeEncodedJsonScalar(alloc, writer, match.server.config.name);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(bounded.text, .{}, writer);
    try writer.writeAll(",\"purpose\":");
    try std.json.Stringify.value(bounded.text, .{}, writer);
    try writer.writeAll(",\"usage\":[");
    for (tool.tags, 0..) |tag, index| {
        if (index > 0) try writer.writeByte(',');
        try writeEncodedJsonScalar(alloc, writer, tag);
    }
    try writer.writeByte(']');
    if (bounded.observed_bytes > description_limit.effectiveBytes()) {
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

pub fn boundedEncodedScalar(alloc: Allocator, value: []const u8, max_bytes: usize) !BoundedEncodedScalar {
    const encoded = try encodeScalarAlloc(alloc, value);
    errdefer alloc.free(encoded);
    const observed = encoded.len;
    if (observed <= max_bytes) return .{ .text = encoded, .observed_bytes = observed };

    var prefix_len = context_limits.utf8PrefixLength(encoded, max_bytes);
    if (std.mem.lastIndexOfScalar(u8, encoded[0..prefix_len], '&')) |amp_index| {
        if (std.mem.indexOfScalar(u8, encoded[amp_index..prefix_len], ';') == null) prefix_len = amp_index;
    }
    return .{ .text = try alloc.realloc(encoded, prefix_len), .observed_bytes = observed };
}

const encodeScalarAlloc = model_context_encoding.scalarAlloc;
const writeEncodedJsonScalar = model_context_encoding.writeJsonScalar;

fn queryContainsCompleteIdentity(query: []const u8, identity: []const u8) bool {
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

pub fn renderAuthenticationRequired(
    alloc: Allocator,
    servers: []const *McpServer,
    access: *const OperationAccessGuard,
    query: []const u8,
) !?[]u8 {
    for (servers) |server| {
        if (!server.isPublished()) continue;
        if (!access.allows(.{ .tool_server = server.config.name })) continue;
        if (!queryContainsCompleteIdentity(query, server.config.name)) continue;
        server.status_lock.lockUncancelable(io_mod.getIo());
        const failed = server.state.load(.acquire) == .failed;
        server.status_lock.unlock(io_mod.getIo());
        if (!failed) continue;
        const mode: enum { oauth, bearer_environment } = if (serverAuthenticationState(server) == .required)
            .oauth
        else if (server.config.bearer_token_env != null and
            io_mod.getenv(server.config.bearer_token_env.?) == null)
            .bearer_environment
        else
            continue;

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(
            "{\"tools\":[],\"count\":0,\"authentication_required\":{\"server\":",
        );
        try writeEncodedJsonScalar(alloc, &out.writer, server.config.name);
        switch (mode) {
            .oauth => {
                try out.writer.writeAll(",\"interactive\":true,\"message\":");
                const guidance = try std.fmt.allocPrint(alloc, "Run /mcp auth {s} --open in an interactive fx session.", .{server.config.name});
                defer alloc.free(guidance);
                try writeEncodedJsonScalar(alloc, &out.writer, guidance);
            },
            .bearer_environment => {
                try out.writer.writeAll(
                    ",\"interactive\":false,\"environment\":",
                );
                try writeEncodedJsonScalar(
                    alloc,
                    &out.writer,
                    server.config.bearer_token_env.?,
                );
                try out.writer.writeAll(
                    ",\"message\":\"Set this environment variable before starting fx.\"",
                );
            },
        }
        try out.writer.writeAll("}}");
        return try out.toOwnedSlice();
    }
    return null;
}
