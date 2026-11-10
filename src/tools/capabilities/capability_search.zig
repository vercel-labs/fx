const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const result_store = @import("../../core/session/result_store.zig");
const capability_retrieval = @import("../../core/tooling/capability_retrieval.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../../core/tooling/tool_mcp_runtime.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const skill_search = @import("../skills/skill_search.zig");

const Allocator = std.mem.Allocator;
/// Searches skills and MCP tools for `request`, as toolbox search answers.
/// A request that loads schemas reports the MCP tools it loaded as selected
/// for the next step.
pub fn search(
    ctx: tool_dispatch.DispatchContext,
    request: capability_retrieval.Request,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const output_cap = @min(
        ctx.max_tool_result_bytes,
        result_store.large_result_threshold_bytes,
    );
    const searches_skills = request.includes(.skill);
    const searches_mcp = request.includes(.mcp);
    const domain_cap = if (searches_skills and searches_mcp and output_cap > 512)
        (output_cap - 512) / 2
    else
        output_cap;
    var skill_result: ?skill_search.SearchResult = null;
    if (searches_skills) {
        skill_result = skill_search.searchRequest(ctx, request, domain_cap) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return executionFailure(ctx.allocator, "skill", err),
        };
    }
    defer if (skill_result) |*result| result.deinit(ctx.allocator);

    var mcp_result: tool_mcp_runtime.SearchResult = if (searches_mcp)
        try searchMcp(ctx, request, domain_cap)
    else
        .{ .model_output = try ctx.allocator.dupe(u8, "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}") };
    defer mcp_result.deinit(ctx.allocator);
    if (mcp_result.notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);

    const combined = combineProjected(
        ctx.allocator,
        if (skill_result) |*result| result else null,
        mcp_result.model_output,
        output_cap,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return executionFailure(ctx.allocator, "combined", err),
    };
    return .{ .success = combined };
}

fn executionFailure(
    alloc: Allocator,
    domain: []const u8,
    err: anyerror,
) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try alloc.print(
        "The {s} search failed ({s}). Try it again, or open a skill or MCP server by name with toolbox.",
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
        else => return .{ .model_output = try ctx.allocator.print("{{\"tools\":[],\"count\":0,\"error\":\"{s}\"}}", .{@errorName(err)}) },
    };
}

fn combineProjected(
    alloc: Allocator,
    skill_result: ?*const skill_search.SearchResult,
    mcp_output: []const u8,
    max_bytes: usize,
) ![]u8 {
    var mcp_parsed = try std.json.parseFromSlice(std.json.Value, alloc, mcp_output, .{});
    defer mcp_parsed.deinit();
    if (mcp_parsed.value != .object) return error.InvalidCapabilitySearchResult;
    const mcp_tools_value = mcp_parsed.value.object.get("tools") orelse
        return error.InvalidCapabilitySearchResult;
    if (mcp_tools_value != .array) return error.InvalidCapabilitySearchResult;
    const mcp_items = mcp_tools_value.array.items;

    const combined = renderCombined(
        alloc,
        if (skill_result) |result| result.itemsJson() else "",
        if (skill_result) |result| result.count else 0,
        mcp_items,
        if (skill_result) |result| result.total_matches else 0,
        objectNonNegativeCount(mcp_parsed.value, "total_matches"),
        mcp_parsed.value.object.get("authentication_required"),
        mcp_parsed.value.object.get("state"),
        mcp_parsed.value.object.get("error"),
        mcp_parsed.value.object.get("context_limit"),
        mcp_parsed.value.object.get("unavailable"),
        // Skills and MCP tools page apart, so only a search of MCP alone
        // offers its next page.
        if (skill_result == null) mcp_parsed.value.object.get("next_cursor") else null,
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    if (combined.len <= max_bytes) return combined;
    alloc.free(combined);
    return error.CapabilitySearchResultLimitTooSmall;
}

fn renderCombined(
    alloc: Allocator,
    skills_json: []const u8,
    skill_count: usize,
    mcp_tools: []const std.json.Value,
    skill_total_matches: usize,
    mcp_total_matches: usize,
    authentication_required: ?std.json.Value,
    mcp_state: ?std.json.Value,
    mcp_error: ?std.json.Value,
    mcp_context_limit: ?std.json.Value,
    /// Servers a search that matched no tool couldn't look in, and why.
    mcp_unavailable: ?std.json.Value,
    /// The MCP page's next_cursor, for a search of MCP alone.
    mcp_next_cursor: ?std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"skills\":[");
    try out.writer.writeAll(skills_json);
    try out.writer.writeAll("],\"mcp_tools\":[");
    for (mcp_tools, 0..) |value, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.print(
        "],\"counts\":{{\"skills\":{d},\"mcp_tools\":{d}}},\"total_matches\":{{\"skills\":{d},\"mcp_tools\":{d}}}",
        .{
            skill_count,
            mcp_tools.len,
            skill_total_matches,
            mcp_total_matches,
        },
    );
    if (skill_total_matches == 0 and
        mcp_total_matches == 0 and
        authentication_required == null and
        mcp_state == null and
        mcp_error == null)
    {
        try out.writer.writeAll(",\"state\":\"no_match\"");
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
    if (mcp_unavailable) |value| {
        try out.writer.writeAll(",\"mcp_unavailable\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    if (mcp_next_cursor) |value| if (value == .string) {
        try out.writer.writeAll(",\"next_cursor\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    };
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn objectNonNegativeCount(value: std.json.Value, field: []const u8) usize {
    const candidate = value.object.get(field) orelse return 0;
    if (candidate != .integer or candidate.integer < 0) return 0;
    return std.math.cast(usize, candidate.integer) orelse 0;
}

test "capability search combines bounded skill and MCP results" {
    const alloc = std.testing.allocator;
    const skills =
        "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"}],\"count\":1,\"total_matches\":2,\"more_available\":true,\"next_cursor\":\"c1:s:1:1:1\"}";
    const mcp =
        "{\"tools\":[{\"name\":\"mcp_mail_send\",\"server\":\"mail\",\"description\":\"Send email\"}],\"count\":1,\"total_matches\":3,\"more_available\":true,\"next_cursor\":\"c1:m:1:1:1\",\"authentication_required\":{\"server\":\"TOKEN=runtime-auth-secret\",\"message\":\"authenticate\"}}";
    const skill_result = testSkillResult(skills, 1, 2);
    const output = try combineProjected(alloc, &skill_result, mcp, 4096);
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
    try std.testing.expect(parsed.value.object.get("authentication_required") != null);

    const projected_again = try tool_result_limits.prepareModelOutput(
        alloc,
        "capability_search",
        output,
        output.len,
    );
    defer alloc.free(@constCast(projected_again));
    try std.testing.expectEqualStrings(output, projected_again);

    try std.testing.expectError(
        error.CapabilitySearchResultLimitTooSmall,
        combineProjected(alloc, &skill_result, mcp, output.len - 1),
    );
}

test "a search that matched nothing keeps the MCP servers it couldn't look in" {
    const alloc = std.testing.allocator;
    const mcp =
        \\{"tools":[],"count":0,"total_matches":0,"more_available":false,"next_cursor":null,"unavailable":["MCP server 'linear' needs a login."]}
    ;
    const output = try combineProjected(alloc, null, mcp, 4096);
    defer alloc.free(output);
    try std.testing.expectEqualStrings(
        \\{"skills":[],"mcp_tools":[],"counts":{"skills":0,"mcp_tools":0},"total_matches":{"skills":0,"mcp_tools":0},"state":"no_match","mcp_unavailable":["MCP server 'linear' needs a login."]}
    ,
        output,
    );
}

test "capability search combined projection releases every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const skills =
                "{\"skills\":[{\"name\":\"mail-helper\",\"description\":\"Send email\",\"location\":\"/skills/mail-helper\"}],\"count\":1,\"total_matches\":1,\"more_available\":false,\"next_cursor\":null}";
            const mcp =
                "{\"tools\":[{\"name\":\"mcp_mail_send\",\"server\":\"mail\",\"description\":\"Send email\"}],\"count\":1,\"total_matches\":1,\"more_available\":false,\"next_cursor\":null}";
            const skill_result = testSkillResult(skills, 1, 1);
            const output = try combineProjected(alloc, &skill_result, mcp, 1024);
            alloc.free(output);
        }
    };
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Case.run, .{});
}

test "capability search marks an empty search as terminal" {
    const alloc = std.testing.allocator;
    const skills =
        "{\"skills\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}";
    const mcp =
        "{\"tools\":[],\"count\":0,\"total_matches\":0,\"more_available\":false,\"next_cursor\":null}";
    const skill_result = testSkillResult(skills, 0, 0);
    const output = try combineProjected(alloc, &skill_result, mcp, 4096);
    defer alloc.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "no_match",
        parsed.value.object.get("state").?.string,
    );
    try std.testing.expectEqual(@as(usize, 5), parsed.value.object.count());
}

fn testSkillResult(output: []const u8, count: usize, total_matches: usize) skill_search.SearchResult {
    const items_start = "{\"skills\":[".len;
    const items_end = std.mem.find(u8, output, "],\"count\":") orelse unreachable;
    return .{
        .model_output = @constCast(output),
        .items_start = items_start,
        .items_end = items_end,
        .count = count,
        .total_matches = total_matches,
    };
}
