const std = @import("std");
const lexical_relevance = @import("../../core/shared/lexical_relevance.zig");
const result_store = @import("../../core/session/result_store.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const skill_search = @import("../skills/skill_search.zig");

const Allocator = std.mem.Allocator;
const mcp_result_limit: usize = 8;

const Input = struct {
    query: []u8,
    prepared: lexical_relevance.PreparedQuery,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = undefined;
    }
};

const ProjectionCheck = union(enum) {
    valid,
    invalid,
    skill_identity_changed: usize,
    mcp_identity_changed: usize,
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
    const query_value = parsed.value.object.get("query") orelse {
        return failure(ctx.allocator, "capability_search field \"query\" is required");
    };
    if (query_value != .string) {
        return failure(ctx.allocator, "capability_search field \"query\" must be a string");
    }
    if (query_value.string.len > lexical_relevance.max_query_bytes) {
        return failure(ctx.allocator, "capability_search query must not exceed 4096 bytes");
    }

    const query = try ctx.allocator.dupe(u8, query_value.string);
    errdefer ctx.allocator.free(query);
    const prepared = lexical_relevance.prepare(query) catch |err| switch (err) {
        error.QueryTooLong => unreachable,
        error.TooManyTokens => {
            const result = try failure(
                ctx.allocator,
                "capability_search query must not exceed 64 tokens",
            );
            ctx.allocator.free(query);
            return result;
        },
    };
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .query = query, .prepared = prepared };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
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
    const skill_output = skill_search.search(
        ctx,
        &input.prepared,
        output_cap,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return executionFailure(ctx.allocator, "skill", err),
    };
    defer ctx.allocator.free(skill_output);

    var mcp_notice: ?[]u8 = null;
    defer if (mcp_notice) |notice| ctx.allocator.free(notice);
    const mcp_output = try searchMcp(ctx, &input.prepared, &mcp_notice);
    defer ctx.allocator.free(mcp_output);
    if (mcp_notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);

    const combined = combineProjected(
        ctx.allocator,
        skill_output,
        mcp_output,
        output_cap,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return executionFailure(ctx.allocator, "combined", err),
    };
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
    query: *const lexical_relevance.PreparedQuery,
    notice_out: *?[]u8,
) tool_dispatch.DispatchError![]u8 {
    const runtime_context = ctx.mcp_ctx orelse
        return ctx.allocator.dupe(u8, "{\"tools\":[],\"count\":0,\"state\":\"unavailable\"}");
    const search_tools = ctx.mcp_search_tools orelse
        return ctx.allocator.dupe(u8, "{\"tools\":[],\"count\":0,\"state\":\"unavailable\"}");
    var result = search_tools(
        runtime_context,
        ctx.allocator,
        query,
        mcp_result_limit,
        ctx.mcp_permission_rules,
        ctx.context_limits,
        ctx.mcp_access,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return std.fmt.allocPrint(
            ctx.allocator,
            "{{\"tools\":[],\"count\":0,\"error\":\"{s}\"}}",
            .{@errorName(err)},
        ),
    };
    notice_out.* = result.notice;
    result.notice = null;
    return result.model_output;
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
    var skill_count = skill_items.len;
    var mcp_count = mcp_items.len;
    var include_authentication = mcp_parsed.value.object.get("authentication_required") != null;

    while (true) {
        const raw = renderCombined(
            alloc,
            skill_items[0..skill_count],
            mcp_items[0..mcp_count],
            skillMoreAvailable(skills_parsed.value) or skill_count < skill_items.len,
            mcpMoreAvailable(mcp_parsed.value) or mcp_count < mcp_items.len,
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
            },
            .skill_identity_changed => |index| skill_count = index,
            .mcp_identity_changed => |index| mcp_count = index,
            .authentication_identity_changed => include_authentication = false,
            .invalid => {
                if (mcp_count > skill_count and mcp_count > 0) {
                    mcp_count -= 1;
                } else if (skill_count > 0) {
                    skill_count -= 1;
                } else if (mcp_count > 0) {
                    mcp_count -= 1;
                } else if (include_authentication) {
                    include_authentication = false;
                } else {
                    alloc.free(projected);
                    return error.CapabilitySearchResultLimitTooSmall;
                }
            },
        }
        alloc.free(projected);
    }
}

fn renderCombined(
    alloc: Allocator,
    skills: []const std.json.Value,
    mcp_tools: []const std.json.Value,
    skills_more_available: bool,
    mcp_more_available: bool,
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
        "],\"counts\":{{\"skills\":{d},\"mcp_tools\":{d}}},\"more_available\":{{\"skills\":{s},\"mcp_tools\":{s}}}",
        .{
            skills.len,
            mcp_tools.len,
            if (skills_more_available) "true" else "false",
            if (mcp_more_available) "true" else "false",
        },
    );
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

    for (projected_skills.array.items, skills, 0..) |projected_skill, skill, index| {
        if (!objectStringFieldsEqual(projected_skill, skill, "name", "location")) {
            return .{ .skill_identity_changed = index };
        }
    }
    for (projected_mcp.array.items, mcp_tools, 0..) |projected_tool, tool, index| {
        if (!objectStringFieldsEqual(projected_tool, tool, "name", "server")) {
            return .{ .mcp_identity_changed = index };
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

fn skillMoreAvailable(value: std.json.Value) bool {
    const candidate = value.object.get("more_available") orelse return false;
    return candidate == .bool and candidate.bool;
}

fn mcpMoreAvailable(value: std.json.Value) bool {
    const candidate = value.object.get("more_available") orelse return false;
    return candidate == .bool and candidate.bool;
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

test "capability search combines domains and omits projected identities" {
    const alloc = std.testing.allocator;
    const skills =
        "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"},{\"name\":\"unsafe\",\"description\":\"Unsafe\",\"location\":\"/skills/TOKEN=runtime-secret\"}],\"count\":2,\"more_available\":false}";
    const mcp =
        "{\"tools\":[{\"name\":\"mcp_mail_send\",\"server\":\"mail\",\"description\":\"Send email\"},{\"name\":\"mcp_unsafe_send\",\"server\":\"TOKEN=runtime-secret\",\"description\":\"Unsafe\"}],\"count\":2,\"authentication_required\":{\"server\":\"TOKEN=runtime-auth-secret\",\"message\":\"authenticate\"}}";
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
    try std.testing.expect(parsed.value.object.get("more_available").?.object.get("skills").?.bool);
    try std.testing.expect(parsed.value.object.get("more_available").?.object.get("mcp_tools").?.bool);
    try std.testing.expect(parsed.value.object.get("authentication_required") == null);
}

test "capability search combined projection releases every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const skills =
                "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"}],\"count\":1,\"more_available\":false}";
            const mcp =
                "{\"tools\":[{\"name\":\"mcp_mail_send\",\"server\":\"mail\",\"description\":\"Send email\"}],\"count\":1}";
            const output = try combineProjected(alloc, skills, mcp, 1024);
            alloc.free(output);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
