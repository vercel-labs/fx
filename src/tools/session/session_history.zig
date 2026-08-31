const std = @import("std");
const provider_mod = @import("../../core/session/session_history_provider.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const SearchInput = struct {
    query: []u8,
    limit: usize = 8,

    fn deinit(self: *SearchInput, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = .{ .query = &.{} };
    }
};

const ReadInput = struct {
    reference: []u8,
    include_execution: bool = false,

    fn deinit(self: *ReadInput, alloc: Allocator) void {
        alloc.free(self.reference);
        self.* = .{ .reference = &.{} };
    }
};

pub fn searchDecode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_search arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_search arguments must be an object") };
    }
    const query_value = parsed.value.object.get("query") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_search requires string field \"query\"") };
    };
    if (query_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_search field \"query\" must be a string") };
    }
    const query = std.mem.trim(u8, query_value.string, " \t\r\n");
    if (query.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_search field \"query\" must not be empty") };
    }
    if (query.len > provider_mod.max_search_query_bytes) {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_search query is too long") };
    }
    var limit: usize = 8;
    if (parsed.value.object.get("limit")) |limit_value| {
        if (limit_value != .integer or limit_value.integer < 1 or
            limit_value.integer > provider_mod.max_search_results)
        {
            return .{ .failure = try std.fmt.allocPrint(
                ctx.allocator,
                "session_history_search field \"limit\" must be an integer from 1 to {d}",
                .{provider_mod.max_search_results},
            ) };
        }
        limit = @intCast(limit_value.integer);
    }
    const input = try ctx.allocator.create(SearchInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .query = try ctx.allocator.dupe(u8, query),
        .limit = limit,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = destroySearchInput } };
}

pub fn readDecode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_read arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_read arguments must be an object") };
    }
    const reference_value = parsed.value.object.get("reference") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_read requires string field \"reference\"") };
    };
    if (reference_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_read field \"reference\" must be a string") };
    }
    const reference = std.mem.trim(u8, reference_value.string, " \t\r\n");
    if (reference.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_read field \"reference\" must not be empty") };
    }
    if (reference.len > provider_mod.max_read_reference_bytes) {
        return .{ .failure = try ctx.allocator.dupe(u8, "session_history_read reference is too long") };
    }
    var include_execution = false;
    if (parsed.value.object.get("include_execution")) |value| {
        if (value != .bool) {
            return .{ .failure = try ctx.allocator.dupe(u8, "session_history_read field \"include_execution\" must be a boolean") };
        }
        include_execution = value.bool;
    }
    const input = try ctx.allocator.create(ReadInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .reference = try ctx.allocator.dupe(u8, reference),
        .include_execution = include_execution,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = destroyReadInput } };
}

pub fn searchCall(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.session_history_provider orelse return .{
        .failure = try ctx.allocator.dupe(u8, "No canonical session-history store is available for this runtime."),
    };
    const input = erased.as(SearchInput);
    return providerResult(try provider.search(ctx.allocator, .{
        .query = input.query,
        .limit = input.limit,
    }));
}

pub fn readCall(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.session_history_provider orelse return .{
        .failure = try ctx.allocator.dupe(u8, "No canonical session-history store is available for this runtime."),
    };
    const input = erased.as(ReadInput);
    return providerResult(try provider.read(ctx.allocator, .{
        .reference = input.reference,
        .include_execution = input.include_execution,
    }));
}

fn providerResult(result: provider_mod.Result) tool_dispatch.ToolResult {
    return switch (result) {
        .success => |body| .{ .success = body },
        .failure => |body| .{ .failure = body },
    };
}

fn destroySearchInput(raw: *anyopaque, alloc: Allocator) void {
    const input: *SearchInput = @ptrCast(@alignCast(raw));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn destroyReadInput(raw: *anyopaque, alloc: Allocator) void {
    const input: *ReadInput = @ptrCast(@alignCast(raw));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "session history tool inputs decode bounded search and exact read requests" {
    const alloc = std.testing.allocator;
    const search = try searchDecode(.{ .allocator = alloc }, "{\"query\":\"deployment blue\",\"limit\":3}");
    const search_input = switch (search) {
        .input => |input| input,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer search_input.deinit(alloc);
    try std.testing.expectEqualStrings("deployment blue", search_input.as(SearchInput).query);
    try std.testing.expectEqual(@as(usize, 3), search_input.as(SearchInput).limit);

    const read = try readDecode(.{ .allocator = alloc }, "{\"reference\":\"fxhr1:session:0:digest\",\"include_execution\":true}");
    const read_input = switch (read) {
        .input => |input| input,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer read_input.deinit(alloc);
    try std.testing.expect(read_input.as(ReadInput).include_execution);
}

test "session history tools reject invalid requests" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "{\"query\":\"   \"}",
        "{\"query\":\"valid\",\"limit\":21}",
        "{\"query\":\"x" ++ ("x" ** provider_mod.max_search_query_bytes) ++ "\"}",
    };
    for (cases) |arguments| {
        const decoded = try searchDecode(.{ .allocator = alloc }, arguments);
        switch (decoded) {
            .failure => |body| alloc.free(body),
            .input => |input| {
                input.deinit(alloc);
                return error.TestUnexpectedDecodeSuccess;
            },
        }
    }

    const read = try readDecode(
        .{ .allocator = alloc },
        "{\"reference\":\"x" ++ ("x" ** provider_mod.max_read_reference_bytes) ++ "\"}",
    );
    switch (read) {
        .failure => |body| alloc.free(body),
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedDecodeSuccess;
        },
    }
}
