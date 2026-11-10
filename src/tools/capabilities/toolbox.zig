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
const toolbox_core = @import("../../core/tooling/toolbox.zig");
const model_context_encoding = @import("../../core/shared/model_context_encoding.zig");

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
    /// Which menu heading the name to open is under, for a name under more
    /// than one.
    kind: ?toolbox_core.Kind = null,
    /// How many matches a search returns.
    limit: usize = capability_retrieval.default_limit,
    /// An earlier search's next_cursor, for its next page.
    cursor: ?[]u8 = null,
    /// The run's arguments as a JSON object.
    arguments_json: []u8,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.target);
        if (self.resource) |value| alloc.free(value);
        if (self.server) |value| alloc.free(value);
        if (self.cursor) |value| alloc.free(value);
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
        // An empty search of one server lists its tools; that is checked
        // once server is read.
        if (candidate != .search and std.mem.trim(u8, value.string, " \t\r\n").len == 0) return failure(ctx.allocator, "toolbox open and run must not be empty");
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
    var kind: ?toolbox_core.Kind = null;
    if (args.get("kind")) |value| {
        if (chosen != .open) return failure(ctx.allocator, "toolbox kind goes with open");
        if (value != .string) return failure(ctx.allocator, "toolbox kind must be skill, mcp_server, or tool");
        kind = std.meta.stringToEnum(toolbox_core.Kind, value.string) orelse
            return failure(ctx.allocator, "toolbox kind must be skill, mcp_server, or tool");
    }
    var limit: usize = capability_retrieval.default_limit;
    if (args.get("limit")) |value| {
        if (chosen != .search) return failure(ctx.allocator, "toolbox limit goes with search");
        if (value != .integer or value.integer < 1 or value.integer > capability_retrieval.max_limit) {
            return failure(ctx.allocator, std.fmt.comptimePrint("toolbox limit must be a whole number from 1 to {d}", .{capability_retrieval.max_limit}));
        }
        limit = @intCast(value.integer);
    }
    const cursor_value = args.get("cursor");
    if (cursor_value) |value| {
        if (chosen != .search) return failure(ctx.allocator, "toolbox cursor goes with search");
        if (value != .string or value.string.len == 0) return failure(ctx.allocator, "toolbox cursor must be an earlier search's next_cursor");
        // Skills and MCP tools page apart, so a cursor pages one server's.
        if (server_value == null) return failure(ctx.allocator, "toolbox cursor goes with a search of one server: pass the same server again");
    }
    if (chosen == .search) {
        if (std.mem.trim(u8, target, " \t\r\n").len == 0) {
            if (server_value == null) return failure(ctx.allocator, "toolbox search needs what you are looking for. To list one MCP server's tools, give its name as server and leave search empty.");
            target = "";
        }
        _ = lexical_relevance.prepare(target) catch return failure(ctx.allocator, "toolbox search is too long");
    }

    const owned_target = try ctx.allocator.dupe(u8, target);
    errdefer ctx.allocator.free(owned_target);
    const resource = if (resource_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (resource) |value| ctx.allocator.free(value);
    const server = if (server_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (server) |value| ctx.allocator.free(value);
    const cursor = if (cursor_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (cursor) |value| ctx.allocator.free(value);
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
        .kind = kind,
        .limit = limit,
        .cursor = cursor,
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

/// A server with at most this many tools opens with all of them and their
/// arguments; a bigger one opens with its list, to search for what is needed.
const small_server_tools: usize = 10;
/// The most the tools of a server that opens whole may take, arguments and all.
const small_server_bytes: usize = 8 * 1024;

/// A skill's instructions, a tool's arguments, or an MCP server's tools.
/// `kind` picks one. Without it, a name is opened as what the menu lists it
/// under, looked up as a skill, a tool, then a server; a skill's name the
/// menu also lists as a server or tool opens nothing and names both, since
/// either could be meant (`toolbox.lookupOf` decides it in the same order).
fn open(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (input.kind) |kind| return switch (kind) {
        .skill => openSkillOrNothing(ctx, input),
        .tool => (try openTool(ctx, input)) orelse nothingNamed(ctx, "tool", input.target),
        .mcp_server => (try openServer(ctx, input)) orelse nothingNamed(ctx, "MCP server", input.target),
    };
    if (hasSkill(ctx, input.target)) {
        if (alsoListedAs(ctx, input.target)) |other| return .{ .failure = try ctx.allocator.print(
            "{f} is in the toolbox menu as a skill and as {s}. Open it again with kind \"skill\" or kind \"{s}\".",
            .{ model_context_encoding.scalar(input.target), if (other == .mcp_server) "an MCP server" else "a tool", @tagName(other) },
        ) };
        return openSkillOrNothing(ctx, input);
    }
    if (try openTool(ctx, input)) |result| return result;
    if (try openServer(ctx, input)) |result| return result;
    // A skill installed since the turn started isn't in the catalog yet;
    // reading it by name finds it.
    return openSkillOrNothing(ctx, input);
}

/// The other heading the menu lists skill `name` under, if any. A location
/// names one skill only.
fn alsoListedAs(ctx: tool_dispatch.DispatchContext, name: []const u8) ?toolbox_core.Kind {
    if (isSkillLocation(name)) return null;
    for (ctx.toolbox_mcp_servers) |server| if (std.mem.eql(u8, server, name)) return .mcp_server;
    for (ctx.toolbox_behind) |tool| if (std.mem.eql(u8, tool, name)) return .tool;
    return null;
}

fn nothingNamed(ctx: tool_dispatch.DispatchContext, noun: []const u8, name: []const u8) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.print(
        "No {s} named {f} is in the toolbox menu. Use toolbox search to find it.",
        .{ noun, model_context_encoding.scalar(name) },
    ) };
}

/// A built-in or MCP tool's definition, or null when no tool has `name`.
fn openTool(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!?tool_dispatch.ToolResult {
    const runner = ctx.toolbox_run orelse return null;
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const described = runner.describe(arena_state.allocator(), input.target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    const description = described orelse return null;
    switch (description) {
        .definition => |definition| {
            if (definition.notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
            return .{ .success = try ctx.allocator.print(
                "{s}\nRun it with toolbox run: \"{s}\" and arguments matching this schema.",
                .{ definition.json, input.target },
            ) };
        },
        .unavailable => |why| return .{ .failure = try ctx.allocator.dupe(u8, why) },
    }
}

/// An MCP server's tools, or null when no server has `name`. A small server
/// gives every tool with its arguments, so the model can run one next; a
/// bigger one gives its list, and the model searches it for the tools it
/// needs rather than loading every schema.
fn openServer(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!?tool_dispatch.ToolResult {
    const capability = ctx.mcp_call_capability orelse return null;
    if (try smallServerTools(ctx, input.target)) |page| {
        defer ctx.allocator.free(page);
        return .{ .success = try ctx.allocator.print(
            "Tools of MCP server {s}, each with its arguments:\n{s}\n" ++
                "Run one with toolbox run: its name and arguments matching its schema.",
            .{ input.target, page },
        ) };
    }
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const flag = ctx.cancel_flag orelse &cancel;
    const listed = capability.lookup(arena, .{ .list = input.target }, flag) catch |err| return try lookupError(ctx, input.target, err);
    if (listed.status != .ok) return null;
    return .{ .success = try ctx.allocator.print(
        "Tools of MCP server {s}, one per line with what it does:\n{s}\n" ++
            "Search this server for the tools you need, with toolbox search and server \"{s}\", which gives their arguments. " ++
            "Then run one with toolbox run. Or open one tool by its name.",
        .{ input.target, std.mem.trimEnd(u8, listed.bytes, "\n"), input.target },
    ) };
}

/// The search page of every tool of menu server `server`, each with its
/// arguments, or null when the server isn't in the menu, has more than
/// `small_server_tools` tools, or they and their arguments don't fit in
/// `small_server_bytes`. The caller owns the page.
fn smallServerTools(ctx: tool_dispatch.DispatchContext, server: []const u8) tool_dispatch.DispatchError!?[]u8 {
    const listed = for (ctx.toolbox_mcp_servers) |name| {
        if (std.mem.eql(u8, name, server)) break true;
    } else false;
    if (!listed) return null;
    const runtime_context = ctx.mcp_ctx orelse return null;
    const search_tools = ctx.mcp_search_tools orelse return null;
    const everything = lexical_relevance.prepare("") catch return null;
    var limits = ctx.context_limits;
    limits.mcp_search_result_bytes.value = .{ .bytes = @min(small_server_bytes, limits.mcp_search_result_bytes.effectiveBytes()) };
    var result = search_tools(runtime_context, ctx.allocator, .{
        .query = &everything,
        .kind = .mcp,
        .server = server,
        // One past the most, to tell a small server from a bigger one.
        .limit = small_server_tools + 1,
        .load_schemas = false,
        .schemas_in_result = true,
    }, ctx.mcp_permission_rules, limits, ctx.mcp_access, ctx.cancel_flag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return null,
    };
    defer result.deinit(ctx.allocator);
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    if (!try wholeWithArguments(arena_state.allocator(), result.model_output)) return null;
    if (result.notice) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
    return try ctx.allocator.dupe(u8, result.model_output);
}

/// Whether search page `page` holds every tool it found, no more than
/// `small_server_tools`, each with its arguments.
fn wholeWithArguments(arena: Allocator, page: []const u8) Allocator.Error!bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, page, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (parsed != .object) return false;
    if (parsed.object.get("state") != null or parsed.object.get("context_limit") != null) return false;
    const tools = parsed.object.get("tools") orelse return false;
    const total = parsed.object.get("total_matches") orelse return false;
    if (tools != .array or total != .integer) return false;
    if (tools.array.items.len == 0 or tools.array.items.len > small_server_tools) return false;
    if (total.integer != @as(i64, @intCast(tools.array.items.len))) return false;
    for (tools.array.items) |tool| {
        if (tool != .object or tool.object.get("arguments") == null) return false;
    }
    return true;
}

/// A skill's instructions. A skill fx found and couldn't read, such as a
/// name two skills share, says why; a name or location no skill has gets the
/// menu's next step, by the name the model gave.
fn openSkillOrNothing(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const result = try openSkill(ctx, input);
    if (result != .failure or !skill_invocation.isNotFound(result.failure)) return result;
    result.deinit(ctx.allocator);
    return .{ .failure = try ctx.allocator.print(
        "Nothing named {f} is in the toolbox menu. Use toolbox search to find it.",
        .{model_context_encoding.scalar(input.target)},
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
        "{f} can't run here: this host runs no tools through toolbox.",
        .{model_context_encoding.scalar(input.target)},
    ) };
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const why = runner.explain(arena_state.allocator(), input.target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return .{ .failure = try ctx.allocator.print(
            "{f} didn't run ({s}). Open it with toolbox to check its name and arguments, then run it again.",
            .{ model_context_encoding.scalar(input.target), @errorName(err) },
        ) },
    };
    return .{ .failure = try ctx.allocator.dupe(u8, why) };
}

/// Skills and MCP tools that match the query, with no side effect: nothing
/// found becomes callable or joins the tools list. Each tool found carries
/// its arguments, so the model can run it next; a row with no room for them
/// says to open it. Server states and sign-in hints are included.
fn search(ctx: tool_dispatch.DispatchContext, input: *const Input) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const prepared = lexical_relevance.prepare(input.target) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "toolbox search is too long") };
    const found = try capability_search_impl.search(ctx, .{
        .query = &prepared,
        // A server's search wakes that server only.
        .kind = if (input.server == null) .all else .mcp,
        .server = input.server,
        .limit = input.limit,
        .cursor = input.cursor,
        .relevance_policy = .intent,
        .load_schemas = false,
        .schemas_in_result = true,
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
    const merged = (try withBuiltins(ctx.allocator, arena, text, matches, runner)) orelse return found;
    ctx.allocator.free(text);
    return .{ .success = merged };
}

/// `result`, a search's JSON, with `matches` as its `tools`, each with its
/// arguments as `runner` describes them, their count in `counts` and
/// `total_matches`, and no `no_match` state. Null when `result` isn't the
/// JSON object a search returns. The caller owns the result.
fn withBuiltins(alloc: Allocator, arena: Allocator, result: []const u8, matches: []const tool_dispatch.ToolboxMatch, runner: tool_dispatch.ToolboxRun) Allocator.Error!?[]u8 {
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
        if (try builtinArguments(arena, runner, match.name)) |arguments| try entry.put(arena, "arguments", arguments);
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

/// The input schema of built-in `name`, or null when `runner` gives none.
fn builtinArguments(arena: Allocator, runner: tool_dispatch.ToolboxRun, name: []const u8) Allocator.Error!?std.json.Value {
    const described = runner.describe(arena, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const definition = switch (described orelse return null) {
        .definition => |value| value,
        .unavailable => return null,
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, definition.json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .object) return null;
    return parsed.object.get("inputSchema");
}

/// A failed MCP lookup of `target`, with its cause and what the model can
/// do next.
fn lookupError(ctx: tool_dispatch.DispatchContext, target: []const u8, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        else => .{ .failure = try ctx.allocator.print(
            "fx couldn't look up {f} ({s}). Its MCP server may be starting, stopped, or signed out. Find it with toolbox search, or ask the user to check it with fx mcp.",
            .{ model_context_encoding.scalar(target), @errorName(err) },
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
        const mcp = core_types.isMcpToolName(value.string);
        return .{
            .activity_kind = if (mcp) .mcp else .write,
            .action_label = if (mcp) tool_presentation.mcp_running_label else "Running",
            .completed_action_label = if (mcp) tool_presentation.mcp_ran_label else "Ran",
            .label_arg_kind = .run,
            .label_arg_default = "tool",
        };
    };
    if (args.get("search")) |value| if (value == .string) {
        // An empty search of one server lists that server's tools, so its
        // row names the server.
        const lists = std.mem.trim(u8, value.string, " \t\r\n").len == 0 and args.get("server") != null;
        return .{
            .activity_kind = .read,
            .action_label = "Searching toolbox",
            .completed_action_label = "Searched toolbox",
            .label_arg_kind = if (lists) .server else .search,
            .label_arg_default = "toolbox",
        };
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
        .{ .args = "{\"open\":\"  \"}", .reason = "toolbox open and run must not be empty" },
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

const fuzz_keys = [_][]const u8{ "open", "run", "search", "resource", "server", "offset", "kind", "limit", "cursor", "arguments", "note" };
const fuzz_values = [_][]const u8{ "\"mcp_fixture_echo\"", "\"\"", "\"  \"", "3", "-1", "{}", "{\"text\":\"hi\"}", "[1]", "null", "true", "\"tool\"", "\"a\\u0000b\"" };

/// Byte pairs pick an arguments object's keys and values; a first byte of
/// 0xff takes the rest as the arguments' text.
fn fuzzRunShape(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [64]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var json: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer json.deinit();
    if (bytes.len > 0 and bytes[0] == 0xff) try json.writer.writeAll(bytes[1..]) else {
        try json.writer.writeByte('{');
        var index: usize = 0;
        while (index + 1 < bytes.len) : (index += 2) {
            if (index > 0) try json.writer.writeByte(',');
            try json.writer.print("\"{s}\":{s}", .{ fuzz_keys[bytes[index] % fuzz_keys.len], fuzz_values[bytes[index + 1] % fuzz_values.len] });
        }
        try json.writer.writeByte('}');
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const carried = try toolbox_core.carriedCall(arena_state.allocator(), toolbox_core.tool_name, json.written());
    switch (try decodeForTest(json.written())) {
        .failure => |reason| {
            std.testing.allocator.free(reason);
            try std.testing.expect(carried == null);
        },
        .input => |input| {
            defer input.deinit(std.testing.allocator);
            const typed = input.as(Input);
            if (typed.action != .run) return std.testing.expect(carried == null);
            // The agent loop runs what carriedCall gives as that tool, so it
            // must be decode's run, target and arguments alike.
            const run_call = carried orelse return error.TestExpectedEqual;
            try std.testing.expectEqualStrings(typed.target, run_call.name);
            try std.testing.expectEqualStrings(typed.arguments_json, run_call.arguments_json);
        },
    }
}

test "a toolbox call is carried as a run exactly when its decode reads a run" {
    try std.testing.fuzz({}, fuzzRunShape, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "\x00\x00\x01\x00",
            "\x01\x00\x09\x06\x0a\x03",
            "\xff{\"run\":\"mcp_fixture_echo\",\"arguments\":\"text\"}",
        }) ++ @import("fuzz_corpus").toolbox_run_shape.*),
    });
}

/// A runner that describes `glob_files` only, for the search tests.
const DescribingRunner = struct {
    fn explainNothing(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
        return "";
    }
    fn describeGlob(_: *anyopaque, _: Allocator, tool: []const u8) anyerror!?tool_dispatch.ToolboxDescription {
        if (!std.mem.eql(u8, tool, "glob_files")) return null;
        return .{ .definition = .{ .json = "{\"type\":\"function\",\"name\":\"glob_files\",\"description\":\"Find files.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"}}}}" } };
    }
    fn searchNothing(_: *anyopaque, _: Allocator, _: *const lexical_relevance.PreparedQuery) anyerror![]const tool_dispatch.ToolboxMatch {
        return &.{};
    }
    var unused: u8 = 0;
    const runner: tool_dispatch.ToolboxRun = .{ .context = &unused, .explain_fn = explainNothing, .describe_fn = describeGlob, .search_fn = searchNothing };
};

test "a search's result gains the built-in tools behind toolbox it found, with their arguments" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const result = "{\"skills\":[],\"mcp_tools\":[],\"counts\":{\"skills\":0,\"mcp_tools\":0},\"total_matches\":{\"skills\":0,\"mcp_tools\":0},\"state\":\"no_match\"}";
    const merged = (try withBuiltins(alloc, arena_state.allocator(), result, &.{
        .{ .name = "glob_files", .description = "Find files." },
        .{ .name = "missing", .description = "Not described." },
    }, DescribingRunner.runner)).?;
    defer alloc.free(merged);
    // The arguments are the definition's input schema, so the model can run
    // the tool next; a tool the runner can't describe keeps its row.
    try std.testing.expect(std.mem.find(u8, merged, "\"tools\":[{\"name\":\"glob_files\",\"description\":\"Find files.\",\"arguments\":{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"}}}},{\"name\":\"missing\",\"description\":\"Not described.\"}]") != null);
    try std.testing.expect(std.mem.find(u8, merged, "\"counts\":{\"skills\":0,\"mcp_tools\":0,\"tools\":2}") != null);
    try std.testing.expect(std.mem.find(u8, merged, "\"total_matches\":{\"skills\":0,\"mcp_tools\":0,\"tools\":2}") != null);
    try std.testing.expect(std.mem.find(u8, merged, "no_match") == null);
    try std.testing.expectEqual(@as(?[]u8, null), try withBuiltins(alloc, arena_state.allocator(), "not json", &.{}, DescribingRunner.runner));
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
        // A name with control characters stays visible text, so the result
        // is still text the model can read.
        .{ .ctx = .{ .allocator = std.testing.allocator }, .args = "{\"open\":\"bad\\u0000name\\u001b[2J\",\"kind\":\"tool\"}", .says = &.{"No tool named bad&#x00;name&#x1b;[2J"} },
        .{ .ctx = with_mcp, .args = "{\"open\":\"lin\\u0007ear\"}", .says = &.{"fx couldn't look up lin&#x07;ear"} },
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
        for (text) |byte| if (byte < 0x20) {
            std.debug.print("a control byte in: {s}\n", .{text});
            return error.TestExpectedEqual;
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

test "toolbox checks kind, limit, and cursor where each goes" {
    const Bad = struct { args: []const u8, says: []const u8 };
    const bad = [_]Bad{
        .{ .args = "{\"open\":\"x\",\"kind\":\"server\"}", .says = "kind must be skill, mcp_server, or tool" },
        .{ .args = "{\"search\":\"x\",\"kind\":\"skill\"}", .says = "kind goes with open" },
        .{ .args = "{\"search\":\"x\",\"limit\":0}", .says = "limit must be a whole number from 1 to 20" },
        .{ .args = "{\"search\":\"x\",\"limit\":21}", .says = "limit must be a whole number from 1 to 20" },
        .{ .args = "{\"search\":\"x\",\"limit\":\"5\"}", .says = "limit must be a whole number from 1 to 20" },
        .{ .args = "{\"open\":\"x\",\"limit\":5}", .says = "limit goes with search" },
        // Skills and MCP tools page apart, so a cursor pages one server's.
        .{ .args = "{\"search\":\"x\",\"cursor\":\"c1\"}", .says = "cursor goes with a search of one server" },
        .{ .args = "{\"open\":\"x\",\"cursor\":\"c1\"}", .says = "cursor goes with search" },
        // An empty search lists one server's tools, and says so when it has none.
        .{ .args = "{\"search\":\"\"}", .says = "To list one MCP server's tools, give its name as server" },
        .{ .args = "{\"search\":\" \",\"limit\":20}", .says = "To list one MCP server's tools, give its name as server" },
        .{ .args = "{\"open\":\" \"}", .says = "toolbox open and run must not be empty" },
    };
    for (bad) |case| switch (try decodeForTest(case.args)) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedFailure;
        },
        .failure => |reason| {
            defer std.testing.allocator.free(reason);
            try std.testing.expect(std.mem.find(u8, reason, case.says) != null);
        },
    };
    const paged = (try decodeForTest("{\"search\":\"issues\",\"server\":\"linear\",\"limit\":20,\"cursor\":\"c1\"}")).input;
    defer paged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 20), paged.as(Input).limit);
    try std.testing.expectEqualStrings("c1", paged.as(Input).cursor.?);
    const plain = (try decodeForTest("{\"search\":\"issues\"}")).input;
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqual(capability_retrieval.default_limit, plain.as(Input).limit);
    const listing = (try decodeForTest("{\"search\":\"  \",\"server\":\"linear\",\"limit\":20}")).input;
    defer listing.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", listing.as(Input).target);
    try std.testing.expectEqualStrings("linear", listing.as(Input).server.?);
    const kinded = (try decodeForTest("{\"open\":\"linear\",\"kind\":\"mcp_server\"}")).input;
    defer kinded.deinit(std.testing.allocator);
    try std.testing.expectEqual(toolbox_core.Kind.mcp_server, kinded.as(Input).kind.?);
}

test "a skill's name the menu also lists as a server or tool opens nothing and names both" {
    const skill_contract = @import("../../core/skills/skill_contract.zig");
    const skills = [_]skill_contract.Skill{
        .{ .name = "linear", .description = "", .path = "/skills/linear", .source = .global_fx },
        .{ .name = "install_skill", .description = "", .path = "/skills/install_skill", .source = .global_fx },
    };
    const locations: skill_contract.Locations = .{ .namespace = 7, .roots = &.{"/skills"}, .skills = &skills };
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = std.testing.allocator,
        .skill_locations = &locations,
        .toolbox_mcp_servers = &.{"linear"},
        .toolbox_behind = &.{"install_skill"},
    };
    const Case = struct { args: []const u8, says: []const []const u8 };
    const cases = [_]Case{
        .{ .args = "{\"open\":\"linear\"}", .says = &.{ "linear is in the toolbox menu as a skill and as an MCP server", "kind \"skill\"", "kind \"mcp_server\"" } },
        .{ .args = "{\"open\":\"install_skill\"}", .says = &.{ "as a skill and as a tool", "kind \"tool\"" } },
        // A kind with nothing of that kind says which kind is missing.
        .{ .args = "{\"open\":\"linear\",\"kind\":\"mcp_server\"}", .says = &.{"No MCP server named linear"} },
        .{ .args = "{\"open\":\"linear\",\"kind\":\"tool\"}", .says = &.{"No tool named linear"} },
    };
    for (cases) |case| {
        const input = (try decodeForTest(case.args)).input;
        defer input.deinit(std.testing.allocator);
        const result = try open(ctx, input.as(Input));
        defer result.deinit(std.testing.allocator);
        const text = switch (result) {
            .failure => |reason| reason,
            else => return error.TestExpectedFailure,
        };
        for (case.says) |part| {
            if (std.mem.find(u8, text, part) == null) {
                std.debug.print("missing \"{s}\" in: {s}\n", .{ part, text });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "a server opens whole only when every tool it has came back with its arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const with = "{\"name\":\"mcp_s_a\",\"arguments\":{\"type\":\"object\"}}";
    const without = "{\"name\":\"mcp_s_b\",\"open_for_arguments\":true}";
    try std.testing.expect(try wholeWithArguments(arena, "{\"tools\":[" ++ with ++ "," ++ with ++ "],\"count\":2,\"total_matches\":2}"));
    // A row with no room for its arguments, a server with tools past the
    // page, one with more than the small limit, a page a limit cut, a state,
    // or no tools all open as a list instead.
    try std.testing.expect(!try wholeWithArguments(arena, "{\"tools\":[" ++ with ++ "," ++ without ++ "],\"count\":2,\"total_matches\":2}"));
    try std.testing.expect(!try wholeWithArguments(arena, "{\"tools\":[" ++ with ++ "],\"count\":1,\"total_matches\":11}"));
    const eleven = "{\"tools\":[" ++ @import("../../core/shared/text_utils.zig").repeat(with ++ ",", 10) ++ with ++ "],\"count\":11,\"total_matches\":11}";
    try std.testing.expect(!try wholeWithArguments(arena, eleven));
    try std.testing.expect(!try wholeWithArguments(arena, "{\"tools\":[" ++ with ++ "],\"count\":1,\"total_matches\":1,\"context_limit\":{}}"));
    try std.testing.expect(!try wholeWithArguments(arena, "{\"tools\":[],\"count\":0,\"total_matches\":0,\"state\":\"server_not_found\"}"));
    try std.testing.expect(!try wholeWithArguments(arena, "{\"tools\":[],\"count\":0,\"total_matches\":0}"));
    try std.testing.expect(!try wholeWithArguments(arena, "not json"));
}
