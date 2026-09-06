const std = @import("std");
const lexical_relevance = @import("../../core/shared/lexical_relevance.zig");
const result_store = @import("../../core/session/result_store.zig");
const capability_retrieval = @import("../../core/tooling/capability_retrieval.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../../core/tooling/tool_mcp_runtime.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const skill_search = @import("../skills/skill_search.zig");

const Allocator = std.mem.Allocator;
const Input = struct {
    query: []u8,
    prepared: lexical_relevance.PreparedQuery,
    server: ?[]u8,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        if (self.server) |server| alloc.free(server);
        self.* = undefined;
    }

    fn request(self: *const Input) capability_retrieval.Request {
        return .{
            .query = &self.prepared,
            .kind = if (self.server == null) .all else .mcp,
            .server = self.server,
            .limit = capability_retrieval.default_limit,
            .relevance_policy = .intent,
        };
    }
};

const ProjectionCheck = union(enum) {
    valid,
    invalid,
    authentication_identity_changed,
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "capability_search arguments must be valid JSON"),
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return failure(ctx.allocator, "capability_search arguments must be an object");
    }
    const query_value = parsed.value.object.get("query") orelse
        return failure(ctx.allocator, "capability_search field \"query\" is required");
    if (query_value != .string) {
        return failure(ctx.allocator, "capability_search field \"query\" must be a string");
    }
    if (query_value.string.len == 0) {
        return failure(ctx.allocator, "capability_search field \"query\" must not be empty");
    }
    if (query_value.string.len > lexical_relevance.max_query_bytes) {
        return failure(ctx.allocator, "capability_search query must not exceed 4096 bytes");
    }

    const server_value = parsed.value.object.get("server");
    if (server_value) |value| {
        if (value != .string) {
            return failure(ctx.allocator, "capability_search field \"server\" must be a string");
        }
        if (value.string.len == 0) {
            return failure(ctx.allocator, "capability_search field \"server\" must not be empty");
        }
    }
    const query = try ctx.allocator.dupe(u8, query_value.string);
    errdefer ctx.allocator.free(query);
    const prepared = lexical_relevance.prepare(query) catch |err| switch (err) {
        error.QueryTooLong => unreachable,
    };
    const server = if (server_value) |value|
        try ctx.allocator.dupe(u8, value.string)
    else
        null;
    errdefer if (server) |owned| ctx.allocator.free(owned);
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .query = query,
        .prepared = prepared,
        .server = server,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const server = args.get("server") orelse return null;
    if (server != .string or server.string.len == 0) return null;
    return .{
        .activity_kind = .read,
        .action_label = "Searching capabilities",
        .completed_action_label = "Searched capabilities",
        .label_arg_kind = .server,
        .label_arg_default = "MCP server",
    };
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const output_cap = @min(
        ctx.max_tool_result_bytes,
        result_store.large_result_threshold_bytes,
    );
    const request = input.request();
    const searches_skills = request.includes(.skill);
    const searches_mcp = request.includes(.mcp);
    const domain_cap = if (searches_skills and searches_mcp and output_cap > 512)
        (output_cap - 512) / 2
    else
        output_cap;
    const skill_output = if (searches_skills)
        skill_search.searchRequest(ctx, request, domain_cap) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return executionFailure(ctx.allocator, "skill", err),
        }
    else
        try ctx.allocator.dupe(
            u8,
            "{\"skills\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}",
        );
    defer ctx.allocator.free(skill_output);

    var mcp_result: tool_mcp_runtime.SearchResult = if (searches_mcp)
        try searchMcp(ctx, request, domain_cap)
    else
        .{ .model_output = try ctx.allocator.dupe(u8, "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}") };
    defer mcp_result.deinit(ctx.allocator);
    if (mcp_result.notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);

    const combined = combineProjected(
        ctx.allocator,
        skill_output,
        mcp_result.model_output,
        output_cap,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return executionFailure(ctx.allocator, "combined", err),
    };
    errdefer ctx.allocator.free(combined);
    for (mcp_result.selected_tools) |selected| try tool_dispatch.reportSelectedDynamicTool(ctx, selected.name, selected.schema_json, selected.mcp_binding);
    return .{ .success = combined };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}

fn executionFailure(
    alloc: Allocator,
    domain: []const u8,
    err: anyerror,
) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try std.fmt.allocPrint(
        alloc,
        "capability_search {s} search failed: {s}",
        .{ domain, @errorName(err) },
    ) };
}

fn searchMcp(
    ctx: tool_dispatch.DispatchContext,
    request: capability_retrieval.Request,
    max_bytes: usize,
) tool_dispatch.DispatchError!tool_mcp_runtime.SearchResult {
    const runtime_context = ctx.mcp_ctx orelse
        return .{ .model_output = try ctx.allocator.dupe(u8, "{\"tools\":[],\"count\":0,\"state\":\"unavailable\"}") };
    const search_tools = ctx.mcp_search_tools orelse
        return .{ .model_output = try ctx.allocator.dupe(u8, "{\"tools\":[],\"count\":0,\"state\":\"unavailable\"}") };
    var limits = ctx.context_limits;
    if (max_bytes < limits.mcp_search_result_bytes.effectiveBytes()) {
        limits.mcp_search_result_bytes.value = .{ .bytes = max_bytes };
    }
    return search_tools(
        runtime_context,
        ctx.allocator,
        request,
        ctx.mcp_permission_rules,
        limits,
        ctx.mcp_access,
        ctx.cancel_flag,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return .{ .model_output = try std.fmt.allocPrint(ctx.allocator, "{{\"tools\":[],\"count\":0,\"error\":\"{s}\"}}", .{@errorName(err)}) },
    };
}

fn combineProjected(
    alloc: Allocator,
    skill_output: []const u8,
    mcp_output: []const u8,
    max_bytes: usize,
) ![]u8 {
    var skills_parsed = try std.json.parseFromSlice(std.json.Value, alloc, skill_output, .{});
    defer skills_parsed.deinit();
    var mcp_parsed = try std.json.parseFromSlice(std.json.Value, alloc, mcp_output, .{});
    defer mcp_parsed.deinit();
    if (skills_parsed.value != .object or mcp_parsed.value != .object) {
        return error.InvalidCapabilitySearchResult;
    }
    const skills_value = skills_parsed.value.object.get("skills") orelse
        return error.InvalidCapabilitySearchResult;
    const mcp_tools_value = mcp_parsed.value.object.get("tools") orelse
        return error.InvalidCapabilitySearchResult;
    if (skills_value != .array or mcp_tools_value != .array) {
        return error.InvalidCapabilitySearchResult;
    }

    const skill_items = skills_value.array.items;
    const mcp_items = mcp_tools_value.array.items;
    const skill_count = skill_items.len;
    const mcp_count = mcp_items.len;
    var include_authentication = mcp_parsed.value.object.get("authentication_required") != null;

    while (true) {
        const raw = renderCombined(
            alloc,
            skill_items[0..skill_count],
            mcp_items[0..mcp_count],
            objectNonNegativeCount(skills_parsed.value, "total_matches"),
            objectNonNegativeCount(mcp_parsed.value, "total_matches"),
            skills_parsed.value.object.get("state"),
            if (include_authentication)
                mcp_parsed.value.object.get("authentication_required")
            else
                null,
            mcp_parsed.value.object.get("state"),
            mcp_parsed.value.object.get("error"),
            mcp_parsed.value.object.get("context_limit"),
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        defer alloc.free(raw);

        const projected = @constCast(try tool_result_limits.prepareModelOutput(
            alloc,
            "capability_search",
            raw,
            max_bytes,
        ));
        errdefer alloc.free(projected);
        const check = try checkProjection(
            alloc,
            projected,
            skill_items[0..skill_count],
            mcp_items[0..mcp_count],
            if (include_authentication)
                mcp_parsed.value.object.get("authentication_required")
            else
                null,
        );
        switch (check) {
            .valid => {
                const second = try tool_result_limits.prepareModelOutput(
                    alloc,
                    "capability_search",
                    projected,
                    max_bytes,
                );
                defer alloc.free(@constCast(second));
                if (std.mem.eql(u8, projected, second)) return projected;
                alloc.free(projected);
                return error.CapabilitySearchResultLimitTooSmall;
            },
            .authentication_identity_changed => include_authentication = false,
            .invalid,
            => {
                alloc.free(projected);
                return error.CapabilitySearchResultLimitTooSmall;
            },
        }
        alloc.free(projected);
    }
}

fn renderCombined(
    alloc: Allocator,
    skills: []const std.json.Value,
    mcp_tools: []const std.json.Value,
    skill_total_matches: usize,
    mcp_total_matches: usize,
    skill_state: ?std.json.Value,
    authentication_required: ?std.json.Value,
    mcp_state: ?std.json.Value,
    mcp_error: ?std.json.Value,
    mcp_context_limit: ?std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"skills\":[");
    for (skills, 0..) |value, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeAll("],\"mcp_tools\":[");
    for (mcp_tools, 0..) |value, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.print(
        "],\"counts\":{{\"skills\":{d},\"mcp_tools\":{d}}},\"total_matches\":{{\"skills\":{d},\"mcp_tools\":{d}}}",
        .{
            skills.len,
            mcp_tools.len,
            skill_total_matches,
            mcp_total_matches,
        },
    );
    if (skill_total_matches == 0 and
        mcp_total_matches == 0 and
        skill_state == null and
        authentication_required == null and
        mcp_state == null and
        mcp_error == null)
    {
        try out.writer.writeAll(",\"state\":\"no_match\"");
    }
    if (skill_state) |value| {
        try out.writer.writeAll(",\"skill_state\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (authentication_required) |value| {
        try out.writer.writeAll(",\"authentication_required\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (mcp_state) |value| {
        try out.writer.writeAll(",\"mcp_state\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (mcp_error) |value| {
        try out.writer.writeAll(",\"mcp_error\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (mcp_context_limit) |value| {
        try out.writer.writeAll(",\"mcp_context_limit\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn checkProjection(
    alloc: Allocator,
    projected: []const u8,
    skills: []const std.json.Value,
    mcp_tools: []const std.json.Value,
    authentication_required: ?std.json.Value,
) !ProjectionCheck {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, projected, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .invalid,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .invalid;
    const projected_skills = parsed.value.object.get("skills") orelse return .invalid;
    const projected_mcp = parsed.value.object.get("mcp_tools") orelse return .invalid;
    if (projected_skills != .array or projected_mcp != .array or
        projected_skills.array.items.len != skills.len or
        projected_mcp.array.items.len != mcp_tools.len)
    {
        return .invalid;
    }

    for (projected_skills.array.items, skills) |projected_skill, skill| {
        if (!objectStringFieldsEqual(projected_skill, skill, "name", "location")) {
            return .invalid;
        }
    }
    for (projected_mcp.array.items, mcp_tools) |projected_tool, tool| {
        if (!objectStringFieldsEqual(projected_tool, tool, "name", "server")) {
            return .invalid;
        }
    }
    if (authentication_required) |expected| {
        const projected_auth = parsed.value.object.get("authentication_required") orelse
            return .authentication_identity_changed;
        if (!objectStringFieldEqual(projected_auth, expected, "server")) {
            return .authentication_identity_changed;
        }
    }
    return .valid;
}

fn objectStringFieldsEqual(
    actual: std.json.Value,
    expected: std.json.Value,
    first: []const u8,
    second: []const u8,
) bool {
    return objectStringFieldEqual(actual, expected, first) and
        objectStringFieldEqual(actual, expected, second);
}

fn objectStringFieldEqual(
    actual: std.json.Value,
    expected: std.json.Value,
    field: []const u8,
) bool {
    if (actual != .object or expected != .object) return false;
    const actual_value = actual.object.get(field) orelse return false;
    const expected_value = expected.object.get(field) orelse return false;
    return actual_value == .string and expected_value == .string and
        std.mem.eql(u8, actual_value.string, expected_value.string);
}

fn objectNonNegativeCount(value: std.json.Value, field: []const u8) usize {
    const candidate = value.object.get(field) orelse return 0;
    if (candidate != .integer or candidate.integer < 0) return 0;
    return std.math.cast(usize, candidate.integer) orelse 0;
}

test "capability search decoder owns one bounded prepared query" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"query\":\"send an email\"}");
    switch (decoded) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const value = input.as(Input);
            try std.testing.expectEqualStrings("send an email", value.prepared.raw);
            try std.testing.expectEqual(@as(usize, 3), value.prepared.token_count);
        },
    }
}

test "capability search decoder accepts optional exact server scope" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"query\":\"list production monitors\",\"server\":\"datadog\"}",
    );
    switch (decoded) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const value = input.as(Input);
            try std.testing.expectEqualStrings("list production monitors", value.query);
            try std.testing.expectEqualStrings("datadog", value.server.?);
            try std.testing.expectEqual(capability_retrieval.Kind.mcp, value.request().kind);
        },
    }
}

test "capability search decoder rejects a missing or empty task" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "{}", "{\"query\":\"\"}" }) |args| {
        const decoded = try decode(.{ .allocator = alloc }, args);
        switch (decoded) {
            .failure => |message| {
                defer alloc.free(message);
                try std.testing.expect(std.mem.find(u8, message, "query") != null);
            },
            .input => |input| {
                input.deinit(alloc);
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "capability search presents exact server scope" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"server\":\"clerk\",\"query\":\"list sdk snippets\"}",
        .{},
    );
    defer parsed.deinit();
    const resolved = presentation(parsed.value.object).?;
    try std.testing.expectEqual(tool_dispatch.LabelArgKind.server, resolved.label_arg_kind);
    try std.testing.expectEqualStrings("clerk", tool_dispatch.presentationLabelValue(resolved, parsed.value.object).?);
}

test "capability search combines bounded skill and MCP results" {
    const alloc = std.testing.allocator;
    const skills =
        "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"}],\"count\":1,\"total_matches\":2,\"more_available\":true,\"next_cursor\":\"c1:s:1:1:1\"}";
    const mcp =
        "{\"tools\":[{\"name\":\"mcp_mail_send\",\"server\":\"mail\",\"description\":\"Send email\"}],\"count\":1,\"total_matches\":3,\"more_available\":true,\"next_cursor\":\"c1:m:1:1:1\",\"authentication_required\":{\"server\":\"TOKEN=runtime-auth-secret\",\"message\":\"authenticate\"}}";
    const output = try combineProjected(alloc, skills, mcp, 4096);
    defer alloc.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    const skill_items = parsed.value.object.get("skills").?.array.items;
    const mcp_items = parsed.value.object.get("mcp_tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), skill_items.len);
    try std.testing.expectEqualStrings("mail-helper", skill_items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 1), mcp_items.len);
    try std.testing.expectEqualStrings("mcp_mail_send", mcp_items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("total_matches").?.object.get("skills").?.integer);
    try std.testing.expect(parsed.value.object.get("more_available") == null);
    try std.testing.expect(parsed.value.object.get("next_cursors") == null);
    try std.testing.expect(parsed.value.object.get("authentication_required") == null);
}

test "capability search combined projection releases every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const skills =
                "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"}],\"count\":1,\"total_matches\":1,\"more_available\":false,\"next_cursor\":null}";
            const mcp =
                "{\"tools\":[{\"name\":\"mcp_mail_send\",\"server\":\"mail\",\"description\":\"Send email\"}],\"count\":1,\"total_matches\":1,\"more_available\":false,\"next_cursor\":null}";
            const output = try combineProjected(alloc, skills, mcp, 1024);
            alloc.free(output);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "capability search marks an empty search as terminal" {
    const alloc = std.testing.allocator;
    const skills =
        "{\"skills\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}";
    const mcp =
        "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}";
    const output = try combineProjected(alloc, skills, mcp, 4096);
    defer alloc.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "no_match",
        parsed.value.object.get("state").?.string,
    );
    try std.testing.expectEqual(@as(usize, 5), parsed.value.object.count());
}
