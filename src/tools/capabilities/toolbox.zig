//! The `toolbox` tool: opens, runs, and searches what the toolbox menu lists
//! (`src/core/tooling/toolbox.zig`).
//!
//! It never adds anything to the tools fx sends. What it opens comes back as
//! its result, at the end of the conversation, so every later request starts
//! with exactly the bytes of the earlier ones (`tests/tla/toolbox/Toolbox.tla`
//! ToolsFixed and PrefixStable). A run reaches the real MCP tool through the
//! same permission check and call as a shell command's `fx mcp call`
//! (`src/core/tooling/mcp_call_capability.zig`): the configured and saved
//! rules, the prompt, and automatic review all see the real tool
//! (RunNeedsAdmission). A run does not need an earlier open, so compaction
//! strands nothing (RunWorksWhenAllowed).
const std = @import("std");
const tool_presentation = @import("../../core/tooling/tool_presentation.zig");
const core_types = @import("../../core/shared/types.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const mcp_call_capability = @import("../../core/tooling/mcp_call_capability.zig");
const capability_retrieval = @import("../../core/tooling/capability_retrieval.zig");
const lexical_relevance = @import("../../core/shared/lexical_relevance.zig");
const capability_search_impl = @import("capability_search.zig");
const skill_impl = @import("../skills/skill.zig");
const skill_invocation = @import("../../core/skills/skill_invocation.zig");
const skill_search = @import("../skills/skill_search.zig");

const Allocator = std.mem.Allocator;

const Action = enum { open, run, search };

const Input = struct {
    action: Action,
    /// The entry to open, the tool to run, or what to search for.
    target: []u8,
    /// A file inside a skill, for open.
    resource: ?[]u8 = null,
    /// Where to continue reading a skill file, for open.
    offset: ?u64 = null,
    /// The MCP server to search, for search.
    server: ?[]u8 = null,
    /// The run's arguments as a JSON object.
    arguments_json: []u8,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.target);
        if (self.resource) |value| alloc.free(value);
        if (self.server) |value| alloc.free(value);
        alloc.free(self.arguments_json);
        self.* = undefined;
    }
};

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "toolbox arguments must be valid JSON"),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return failure(ctx.allocator, "toolbox arguments must be an object");
    const args = parsed.value.object;

    var action: ?Action = null;
    var target: []const u8 = "";
    for ([_]Action{ .open, .run, .search }) |candidate| {
        const value = args.get(@tagName(candidate)) orelse continue;
        if (value != .string) return failure(ctx.allocator, "toolbox open, run, and search take a string");
        if (std.mem.trim(u8, value.string, " \t\r\n").len == 0) return failure(ctx.allocator, "toolbox open, run, and search must not be empty");
        if (action != null) return failure(ctx.allocator, "toolbox takes exactly one of open, run, or search");
        action = candidate;
        target = value.string;
    }
    const chosen = action orelse return failure(ctx.allocator, "toolbox needs one of open, run, or search");

    const resource_value = args.get("resource");
    if (resource_value) |value| {
        if (chosen != .open) return failure(ctx.allocator, "toolbox resource goes with open");
        if (value != .string or value.string.len == 0) return failure(ctx.allocator, "toolbox resource must be a file name inside the skill");
    }
    const server_value = args.get("server");
    if (server_value) |value| {
        if (chosen != .search) return failure(ctx.allocator, "toolbox server goes with search");
        if (value != .string or value.string.len == 0) return failure(ctx.allocator, "toolbox server must be an MCP server's name");
    }
    const offset_value = args.get("offset");
    if (offset_value) |value| {
        if (chosen != .open) return failure(ctx.allocator, "toolbox offset goes with open");
        if (value != .integer or value.integer < 0) return failure(ctx.allocator, "toolbox offset must be a non-negative integer");
    }
    const arguments_value = args.get("arguments");
    if (arguments_value) |value| {
        if (chosen != .run) return failure(ctx.allocator, "toolbox arguments go with run");
        if (value != .object) return failure(ctx.allocator, "toolbox arguments must be an object");
    }
    if (chosen == .search) {
        _ = lexical_relevance.prepare(target) catch return failure(ctx.allocator, "toolbox search is too long");
    }

    const owned_target = try ctx.allocator.dupe(u8, target);
    errdefer ctx.allocator.free(owned_target);
    const resource = if (resource_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (resource) |value| ctx.allocator.free(value);
    const server = if (server_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (server) |value| ctx.allocator.free(value);
    const arguments_json = if (arguments_value) |value| arguments: {
        var out: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer out.deinit();
        std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
        break :arguments try out.toOwnedSlice();
    } else try ctx.allocator.dupe(u8, "{}");
    errdefer ctx.allocator.free(arguments_json);

    const input = try ctx.allocator.create(Input);
    input.* = .{
        .action = chosen,
        .target = owned_target,
        .resource = resource,
        .offset = if (offset_value) |value| @intCast(value.integer) else null,
        .server = server,
        .arguments_json = arguments_json,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    return switch (input.action) {
        .open => open(ctx, input),
        .run => run(ctx, input),
        .search => search(ctx, input),
    };
}

/// A skill location: as the menu gives a skill whose name another shares,
/// or the path toolbox search reports.
fn isSkillLocation(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "skill:") or std.Io.Dir.path.isAbsolute(target);
}

fn hasSkill(ctx: tool_dispatch.DispatchContext, name: []const u8) bool {
    if (isSkillLocation(name)) return true;
    const locations = ctx.skill_locations orelse return false;
    for (locations.skills) |skill| {
        if (std.mem.eql(u8, skill.name, name)) return true;
    }
    return false;
}

/// A skill's instructions, an MCP server's tools, or one MCP tool's
/// arguments, in that order of lookup.
fn open(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (hasSkill(ctx, input.target)) return openSkillOrNothing(ctx, input);
    if (ctx.toolbox_run) |runner| {
        var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena_state.deinit();
        const described = runner.describe(arena_state.allocator(), input.target) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (described) |description| switch (description) {
            .definition => |definition| {
                if (definition.notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
                return .{ .success = try ctx.allocator.print(
                    "{s}\nRun it with toolbox run: \"{s}\" and arguments matching this schema.",
                    .{ definition.json, input.target },
                ) };
            },
            .unavailable => |why| return .{ .failure = try ctx.allocator.dupe(u8, why) },
        };
    }
    if (ctx.mcp_call_capability) |capability| {
        var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var cancel = std.atomic.Value(bool).init(false);
        const flag = ctx.cancel_flag orelse &cancel;
        const listed = capability.lookup(arena, .{ .list = input.target }, flag) catch |err| return lookupError(ctx, input.target, err);
        if (listed.status == .ok) {
            return .{ .success = try ctx.allocator.print(
                "Tools of MCP server {s}, one per line with what it does:\n{s}\n" ++
                    "Open a tool by its name to see its arguments, then run it with toolbox run and its arguments.",
                .{ input.target, std.mem.trimEnd(u8, listed.bytes, "\n") },
            ) };
        }
    }
    // A skill installed since the turn started isn't in the catalog yet;
    // reading it by name finds it.
    return openSkillOrNothing(ctx, input);
}

/// A skill's instructions. A skill fx found and couldn't read, such as a
/// name two skills share, says why; a name or location no skill has gets the
/// menu's next step, by the name the model gave.
fn openSkillOrNothing(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const result = try openSkill(ctx, input);
    if (result != .failure or !skill_invocation.isNotFound(result.failure)) return result;
    result.deinit(ctx.allocator);
    return .{ .failure = try ctx.allocator.print(
        "Nothing named {s} is in the toolbox menu. Use toolbox search to find it.",
        .{input.target},
    ) };
}

fn openSkill(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const location = try skillLocation(ctx, arena_state.allocator(), input);
    var args: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer args.deinit();
    writeSkillArgs(&args.writer, input, location) catch return error.OutOfMemory;
    const decoded = try skill_impl.decode(ctx, args.written());
    switch (decoded) {
        .failure => |reason| return .{ .failure = reason },
        .input => |skill_input| {
            defer skill_input.deinit(ctx.allocator);
            return skill_impl.call(ctx, skill_input);
        },
    }
}

/// The location to read a skill at, as the skill tool reads a catalog
/// skill: its whole files. Null leaves the skill tool's named form, which
/// reads in chunks when `skill_chunk_bytes` is set, continues an `offset`,
/// finds a skill installed since the turn began, and says which skills a
/// shared name could mean.
fn skillLocation(ctx: tool_dispatch.DispatchContext, arena: Allocator, input: *const Input) Allocator.Error!?[]const u8 {
    if (input.offset != null) return null;
    // A set chunk limit asks for chunks; a whole read past it would load
    // nothing.
    if (ctx.context_limits.skill_chunk_bytes.source != .compiled_default) return null;
    if (isSkillLocation(input.target)) return input.target;
    const locations = ctx.skill_locations orelse return null;
    var found: ?[]const u8 = null;
    for (locations.skills) |skill| {
        if (!std.mem.eql(u8, skill.name, input.target)) continue;
        if (found != null) return null;
        found = skill.path;
    }
    return locations.locationOf(arena, found orelse return null) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn writeSkillArgs(w: *std.Io.Writer, input: *const Input, location: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll(if (location != null) "{\"location\":" else "{\"name\":");
    try std.json.Stringify.value(location orelse input.target, .{}, w);
    if (input.resource) |resource| {
        try w.writeAll(",\"resource\":");
        try std.json.Stringify.value(resource, .{}, w);
    }
    if (input.offset) |offset| try w.print(",\"offset\":{d}", .{offset});
    try w.writeByte('}');
}

/// The agent loop runs what a run carries as its own direct call of it,
/// admitted as that call (`tests/tla/toolbox/Toolbox.tla`
/// RunNeedsAdmission), so a run that gets here didn't run: this says why.
fn run(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runner = ctx.toolbox_run orelse return .{ .failure = try ctx.allocator.print(
        "{s} can't run here: this host runs no tools through toolbox.",
        .{input.target},
    ) };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const why = runner.explain(arena_state.allocator(), input.target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return .{ .failure = try ctx.allocator.print(
            "{s} didn't run ({s}). Open it with toolbox to check its name and arguments, then run it again.",
            .{ input.target, @errorName(err) },
        ) },
    };
    return .{ .failure = try ctx.allocator.dupe(u8, why) };
}

/// Skills and MCP tools that match the query, with no side effect: nothing
/// found becomes callable or joins the tools list.
/// Searches skills and MCP tools as capability_search does, server states
/// and sign-in hints included, but loads no schemas: what it finds is opened
/// and run through toolbox.
fn search(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const prepared = lexical_relevance.prepare(input.target) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "toolbox search is too long") };
    const found = try capability_search_impl.search(ctx, .{
        .query = &prepared,
        // A server's search wakes that server only.
        .kind = if (input.server == null) .all else .mcp,
        .server = input.server,
        .limit = capability_retrieval.default_limit,
        .relevance_policy = .intent,
        .load_schemas = false,
    });
    // The built-in tools behind toolbox are found too, except by a search of
    // one server.
    if (input.server != null) return found;
    const runner = ctx.toolbox_run orelse return found;
    const text = switch (found) {
        .success => |body| body,
        .failure, .rich => return found,
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const matches = runner.searchBuiltins(arena, &prepared) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return found,
    };
    if (matches.len == 0) return found;
    const merged = (try withBuiltins(ctx.allocator, arena, text, matches)) orelse return found;
    ctx.allocator.free(text);
    return .{ .success = merged };
}

/// `result`, a search's JSON, with `matches` as its `tools`, their count in
/// `counts` and `total_matches`, and no `no_match` state. Null when `result`
/// isn't the JSON object a search returns. The caller owns the result.
fn withBuiltins(alloc: Allocator, arena: Allocator, result: []const u8, matches: []const tool_dispatch.ToolboxMatch) Allocator.Error!?[]u8 {
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, result, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .object) return null;
    var tools: std.json.Array = .init(arena);
    for (matches) |match| {
        var entry: std.json.ObjectMap = .empty;
        try entry.put(arena, "name", .{ .string = match.name });
        try entry.put(arena, "description", .{ .string = match.description });
        try tools.append(.{ .object = entry });
    }
    try parsed.object.put(arena, "tools", .{ .array = tools });
    for ([_][]const u8{ "counts", "total_matches" }) |field| {
        if (parsed.object.getPtr(field)) |counts| if (counts.* == .object) {
            try counts.object.put(arena, "tools", .{ .integer = @intCast(matches.len) });
        };
    }
    // A search states no_match only when it found nothing.
    if (parsed.object.get("state")) |state| {
        if (state == .string and std.mem.eql(u8, state.string, "no_match")) _ = parsed.object.orderedRemove("state");
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(parsed, .{}, &out.writer) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

/// A failed MCP lookup of `target`, with its cause and what the model can
/// do next.
fn lookupError(ctx: tool_dispatch.DispatchContext, target: []const u8, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        else => .{ .failure = try ctx.allocator.print(
            "fx couldn't look up {s} ({s}). Its MCP server may be starting, stopped, or signed out. Find it with toolbox search, or ask the user to check it with fx mcp.",
            .{ target, @errorName(err) },
        ) },
    };
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    // Only a skill has files to read, so these read as the skill tool shows them.
    if (args.get("open") != null and (args.get("resource") != null or args.get("offset") != null)) {
        return skill_impl.presentation(args);
    }
    if (args.get("run")) |value| if (value == .string) {
        // An MCP tool's row reads as a direct call of it does.
        const mcp = std.mem.startsWith(u8, value.string, "mcp_");
        return .{
            .activity_kind = if (mcp) .mcp else .write,
            .action_label = if (mcp) tool_presentation.mcp_running_label else "Running",
            .completed_action_label = if (mcp) tool_presentation.mcp_ran_label else "Ran",
            .label_arg_kind = .run,
            .label_arg_default = "tool",
        };
    };
    if (args.get("search")) |value| if (value == .string) return .{
        .activity_kind = .read,
        .action_label = "Searching toolbox",
        .completed_action_label = "Searched toolbox",
        .label_arg_kind = .search,
        .label_arg_default = "toolbox",
    };
    if (args.get("open")) |value| if (value == .string) return .{
        .activity_kind = .read,
        .action_label = "Opening",
        .completed_action_label = "Opened",
        .label_arg_kind = .open,
        .label_arg_default = "toolbox",
    };
    return null;
}

/// Opening and searching read; a run is whatever the real tool does.
pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return erased.as(Input).action != .run;
}

pub fn isIrreversible(erased: tool_dispatch.ToolInput) bool {
    return erased.as(Input).action == .run;
}

fn decodeForTest(args_json: []const u8) !tool_dispatch.DecodeResult {
    return decode(.{ .allocator = std.testing.allocator }, args_json);
}

test "toolbox takes exactly one of open, run, or search" {
    const cases = [_]struct { args: []const u8, reason: []const u8 }{
        .{ .args = "{}", .reason = "toolbox needs one of open, run, or search" },
        .{ .args = "{\"open\":\"a\",\"run\":\"b\"}", .reason = "toolbox takes exactly one of open, run, or search" },
        .{ .args = "{\"open\":\"  \"}", .reason = "toolbox open, run, and search must not be empty" },
        .{ .args = "{\"run\":3}", .reason = "toolbox open, run, and search take a string" },
        .{ .args = "{\"open\":\"a\",\"arguments\":{}}", .reason = "toolbox arguments go with run" },
        .{ .args = "{\"run\":\"a\",\"arguments\":[]}", .reason = "toolbox arguments must be an object" },
        .{ .args = "{\"run\":\"a\",\"resource\":\"x.md\"}", .reason = "toolbox resource goes with open" },
        .{ .args = "[1]", .reason = "toolbox arguments must be an object" },
        .{ .args = "{", .reason = "toolbox arguments must be valid JSON" },
    };
    for (cases) |case| {
        const decoded = try decodeForTest(case.args);
        switch (decoded) {
            .input => |input| {
                input.deinit(std.testing.allocator);
                return error.TestExpectedFailure;
            },
            .failure => |reason| {
                defer std.testing.allocator.free(reason);
                try std.testing.expectEqualStrings(case.reason, reason);
            },
        }
    }
}

test "toolbox keeps a run's arguments as JSON and defaults them to an empty object" {
    const decoded = try decodeForTest("{\"run\":\"mcp_fixture_echo\",\"arguments\":{\"text\":\"hello\"}}");
    const input = switch (decoded) {
        .input => |value| value,
        .failure => |reason| {
            std.testing.allocator.free(reason);
            return error.TestUnexpectedFailure;
        },
    };
    defer input.deinit(std.testing.allocator);
    const typed = input.as(Input);
    try std.testing.expectEqual(Action.run, typed.action);
    try std.testing.expectEqualStrings("mcp_fixture_echo", typed.target);
    try std.testing.expectEqualStrings("{\"text\":\"hello\"}", typed.arguments_json);

    const bare = try decodeForTest("{\"open\":\"fixture\"}");
    const open_input = switch (bare) {
        .input => |value| value,
        .failure => |reason| {
            std.testing.allocator.free(reason);
            return error.TestUnexpectedFailure;
        },
    };
    defer open_input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{}", open_input.as(Input).arguments_json);
}

test "a search's result gains the built-in tools behind toolbox it found" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = "{\"skills\":[],\"mcp_tools\":[],\"counts\":{\"skills\":0,\"mcp_tools\":0},\"total_matches\":{\"skills\":0,\"mcp_tools\":0},\"state\":\"no_match\"}";
    const merged = (try withBuiltins(alloc, arena_state.allocator(), result, &.{.{ .name = "glob_files", .description = "Find files." }})).?;
    defer alloc.free(merged);
    try std.testing.expect(std.mem.find(u8, merged, "\"tools\":[{\"name\":\"glob_files\",\"description\":\"Find files.\"}]") != null);
    try std.testing.expect(std.mem.find(u8, merged, "\"counts\":{\"skills\":0,\"mcp_tools\":0,\"tools\":1}") != null);
    try std.testing.expect(std.mem.find(u8, merged, "\"total_matches\":{\"skills\":0,\"mcp_tools\":0,\"tools\":1}") != null);
    try std.testing.expect(std.mem.find(u8, merged, "no_match") == null);
    try std.testing.expectEqual(@as(?[]u8, null), try withBuiltins(alloc, arena_state.allocator(), "not json", &.{}));
}

test "a failed toolbox open says why and what to do next, by the name it was given" {
    const Failing = struct {
        fn authorize(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!mcp_call_capability.Authorization {
            return error.TestUnexpectedCall;
        }
        fn call(_: *anyopaque, _: Allocator, _: []const u8, _: []const u8, _: []const u8, _: @FieldType(mcp_call_capability.Authorization, "allow"), _: *std.atomic.Value(bool)) anyerror!mcp_call_capability.CallOutcome {
            return error.TestUnexpectedCall;
        }
        fn lookup(_: *anyopaque, _: Allocator, _: mcp_call_capability.Lookup, _: *std.atomic.Value(bool)) anyerror!mcp_call_capability.CallOutcome {
            return error.ServerUnavailable;
        }
    };
    var context: u8 = 0;
    const with_mcp: tool_dispatch.DispatchContext = .{
        .allocator = std.testing.allocator,
        .mcp_call_capability = .{ .context = &context, .authorize_fn = Failing.authorize, .call_fn = Failing.call, .lookup_fn = Failing.lookup },
    };
    const Case = struct { ctx: tool_dispatch.DispatchContext, args: []const u8, says: []const []const u8 };
    const cases = [_]Case{
        // The server's lookup fails: its cause, and where to go next.
        .{ .ctx = with_mcp, .args = "{\"open\":\"linear\"}", .says = &.{ "linear", "ServerUnavailable", "toolbox search", "fx mcp" } },
        // A path no skill has is named as given, not as an empty skill.
        .{ .ctx = .{ .allocator = std.testing.allocator }, .args = "{\"open\":\"/nowhere/skill\"}", .says = &.{ "Nothing named /nowhere/skill", "toolbox search" } },
    };
    for (cases) |case| {
        const decoded = try decodeForTest(case.args);
        const input = switch (decoded) {
            .input => |value| value,
            .failure => |reason| {
                std.testing.allocator.free(reason);
                return error.TestUnexpectedFailure;
            },
        };
        defer input.deinit(std.testing.allocator);
        const result = try open(case.ctx, input.as(Input));
        defer result.deinit(std.testing.allocator);
        const text = switch (result) {
            .failure => |reason| reason,
            else => return error.TestExpectedFailure,
        };
        if (std.mem.find(u8, text, "Skill \"\"") != null) {
            std.debug.print("an empty skill name in: {s}\n", .{text});
            return error.TestExpectedEqual;
        }
        for (case.says) |part| {
            if (std.mem.find(u8, text, part) == null) {
                std.debug.print("missing {s} in: {s}\n", .{ part, text });
                return error.TestExpectedEqual;
            }
        }
    }
}
