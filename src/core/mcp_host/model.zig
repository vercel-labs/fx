//! What the model sees of MCP-v2: each server's tools under the
//! names fx gives them, and the has, validate, call, search, schema, and
//! snapshot operations fx's tool runtime asks for. The tool lists come from
//! the runtime; parsing, names, bindings, ranking, schemas, and call results
//! are fx's own MCP code, so the model sees an MCP-v2 server as it saw v1's.

const std = @import("std");
const runtime_mod = @import("runtime.zig");
const config = @import("config.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const context_limits = @import("../config/context_limits.zig");
const permissions = @import("../permissions/permissions.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const access_policy = @import("../mcp/access_policy.zig");
const catalog_state = @import("../mcp/catalog_state.zig");
const model_catalog = @import("../mcp/model_catalog.zig");
const selected_schema = @import("../mcp/selected_schema.zig");
const tool_names = @import("../mcp/tool_names.zig");
const tool_result = @import("../mcp/tool_result.zig");
const tool_search = @import("../mcp/tool_search.zig");
const tool_snapshot = @import("../mcp/tool_snapshot.zig");
const tools_feature = @import("../mcp/features/tools.zig");
const elicitation = @import("../mcp/elicitation.zig");

const Allocator = std.mem.Allocator;
const Runtime = runtime_mod.Runtime;
const McpTool = catalog_state.McpTool;
const Access = tool_mcp_runtime.Access;
const Binding = tool_mcp_runtime.Binding;
const Cancel = ?*std.atomic.Value(bool);

pub const Catalog = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: *Runtime,
    builtins: tool_dispatch.Registry,
    /// Every binding carries it, so a binding from another run never matches.
    generation: u64,
    names: tool_names.Registry,
    mutex: std.Io.Mutex = .init,
    /// One per `runtime.servers()`; guarded by `mutex`.
    lists: []List,

    const List = struct {
        arena: ?std.heap.ArenaAllocator = null,
        tools: []McpTool = &.{},
        digest: ?[32]u8 = null,
        /// Bumped when the list changes; bindings carry it.
        generation: u64 = 0,
        state: enum { unknown, loaded, needs_login, failed } = .unknown,
        /// Why the list couldn't be had; owned by the catalog.
        failure: ?[]u8 = null,
    };

    const Found = struct { server: usize, tool: *const McpTool };

    /// `runtime` must outlive the catalog. `builtins` are fx's own tools, so an
    /// MCP tool's name never takes one of theirs.
    pub fn init(c: *Catalog, gpa: Allocator, io: std.Io, runtime: *Runtime, builtins: tool_dispatch.Registry) Allocator.Error!void {
        const lists = try gpa.alloc(List, runtime.servers().len);
        for (lists) |*l| l.* = .{};
        const now: u96 = @bitCast(std.Io.Clock.real.now(io).nanoseconds);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .runtime = runtime,
            .builtins = builtins,
            .generation = @as(u64, @truncate(now)) | 1,
            .names = .init(gpa),
            .lists = lists,
        };
    }

    pub fn deinit(c: *Catalog) void {
        for (c.lists) |*l| {
            if (l.arena) |*arena| arena.deinit();
            if (l.failure) |why| c.gpa.free(why);
        }
        c.gpa.free(c.lists);
        c.names.deinit();
        c.* = undefined;
    }

    /// The has, validate, and call operations, for checks made outside a
    /// tool context.
    pub fn runtimeCapabilities(c: *Catalog) tool_mcp_runtime.RuntimeCapabilities {
        return .{ .context = c, .has_tool = hasToolFn, .validate_tool = validateToolFn, .call_tool = callToolFn };
    }

    /// Points a tool context's MCP operations at this catalog.
    pub fn wire(c: *Catalog, tc: *tool_runtime.Context) void {
        tc.mcp_ctx = c;
        tc.mcp_has_tool = hasToolFn;
        tc.mcp_validate_tool = validateToolFn;
        tc.mcp_call_tool = callToolFn;
        tc.mcp_search_tools = searchToolsFn;
        tc.mcp_tool_schema = toolSchemaFn;
        tc.mcp_snapshot_tool = snapshotToolFn;
    }

    pub fn hasTool(c: *Catalog, name: []const u8, access: Access) bool {
        if (!access.allowsTool(c.generation, name)) return false;
        c.ensure(name, null) catch return false;
        return c.known(name);
    }

    pub fn validateTool(c: *Catalog, arena: Allocator, name: []const u8, arguments_json: []const u8, access: Access) !tool_mcp_runtime.ValidationResult {
        if (!access.allowsTool(c.generation, name)) return .not_available;
        try c.ensure(name, null);
        if (!c.known(name)) return .not_available;
        tools_feature.validateArguments(arena, arguments_json, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .invalid = try std.fmt.allocPrint(arena, "Invalid arguments for MCP tool {s}: {s}", .{ name, @errorName(err) }) };
        };
        return .{ .valid = c.generation };
    }

    /// Null when no server has the tool.
    pub fn callTool(
        c: *Catalog,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        if (!options.access.allowsTool(c.generation, name)) return error.McpAccessDenied;
        if (options.expected_binding) |b| if (b.runtime_generation != c.generation) return error.McpAdvertisedToolChanged;
        if (options.expected_runtime_generation) |g| if (g != c.generation) return error.McpAuthorityChanged;
        try c.ensure(name, options.cancel_flag);
        const server, const tool = found: {
            c.mutex.lockUncancelable(c.io);
            defer c.mutex.unlock(c.io);
            const found = c.findLocked(name) orelse return null;
            if (options.expected_binding) |b| {
                if (!b.sameDefinition(c.bindingLocked(found.server, found.tool.*))) return error.McpAdvertisedToolChanged;
            }
            break :found .{ c.runtime.servers()[found.server].name, try arena.dupe(u8, found.tool.original_name) };
        };
        var asking: Asking = .{ .responder = options.input_responder orelse undefined, .tool = name, .cancel = options.cancel_flag, .io = c.io };
        const asker: ?runtime_mod.Asker = if (options.input_responder != null) .{ .context = &asking, .ask = Asking.ask } else null;
        const answer = c.runtime.call(arena, server, tool, arguments_json, options.cancel_flag, asker) catch |err| {
            asking.finish(arena, .abandoned);
            return err;
        };
        // The questions asked end with the call: an editor hears that a URL it
        // opened was used (ACP `elicitation/complete`).
        asking.finish(arena, if (answer == .result) .completed else .abandoned);
        return try render(arena, server, name, answer, max_tool_result_bytes);
    }

    pub fn searchTools(
        c: *Catalog,
        alloc: Allocator,
        request: tool_mcp_runtime.SearchRequest,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: Access,
        cancel: Cancel,
    ) !tool_mcp_runtime.SearchResult {
        const servers = c.runtime.servers();
        if (request.server) |name| {
            for (servers) |s| {
                if (std.mem.eql(u8, s.name, name)) break;
            } else return .{ .model_output = try tool_search.renderServerNotFound(alloc) };
        }
        // Every server starts at once, then each list is waited for.
        for (servers, 0..) |s, i| if (searched(request, s)) c.runtime.prepare(i) catch {};
        for (servers, 0..) |s, i| if (searched(request, s)) try c.refresh(i, cancel);
        if (try c.renderUnavailable(alloc, request)) |output| return .{ .model_output = output };

        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        var candidates: std.ArrayList(tool_search.Candidate) = .empty;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (servers, c.lists, 0..) |s, l, i| {
            if (!searched(request, s) or l.state != .loaded) continue;
            for (l.tools) |*tool| {
                if (!access.allowsTool(c.generation, tool.prefixed_name)) continue;
                if (!try tool_search.searchable(scratch.allocator(), permission_rules, s.name, tool)) continue;
                try candidates.append(scratch.allocator(), .{ .server_name = s.name, .instructions = try c.runtime.instructions(scratch.allocator(), i), .tool = tool, .binding = c.bindingLocked(i, tool.*) });
            }
        }
        return tool_search.rank(alloc, candidates.items, request, limits, null);
    }

    pub fn toolSchema(
        c: *Catalog,
        alloc: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: Access,
        cancel: Cancel,
    ) !?tool_mcp_runtime.ToolSchemaResult {
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        if (!access.allowsTool(c.generation, name)) return null;
        try c.ensure(name, cancel);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const found = c.findLocked(name) orelse return c.whyUnavailableLocked(alloc, name);
        if (permissions.rulesDenyAllTargetsForPermission(permission_rules, name)) return null;
        const instructions = try c.runtime.instructions(alloc, found.server);
        defer if (instructions) |text| alloc.free(text);
        var projection = try selected_schema.project(alloc, found.tool.*, instructions, limits);
        if (projection == .selected) projection.selected.mcp_binding = c.bindingLocked(found.server, found.tool.*);
        return projection;
    }

    /// Every tool of the always-loaded servers, so an editor's tools are
    /// callable each turn without a search. Their lists
    /// load first, all at once.
    pub fn snapshotAlwaysLoadedTools(
        c: *Catalog,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: Access,
        cancel: Cancel,
    ) !selected_schema.AlwaysLoadedTools {
        const servers = c.runtime.servers();
        for (servers, 0..) |s, i| if (s.always_loaded) c.runtime.prepare(i) catch {};
        for (servers, 0..) |s, i| if (s.always_loaded) try c.refresh(i, cancel);
        var loaded: selected_schema.AlwaysLoaded = .init(limits);
        errdefer loaded.deinit(alloc);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (servers, c.lists, 0..) |s, l, i| {
            if (!s.always_loaded or l.state != .loaded) continue;
            const instructions = try c.runtime.instructions(alloc, i);
            defer if (instructions) |text| alloc.free(text);
            for (l.tools) |*tool| {
                if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) continue;
                if (!access.allowsTool(c.generation, tool.prefixed_name)) continue;
                try loaded.add(alloc, tool.*, instructions, c.bindingLocked(i, tool.*), limits);
            }
        }
        return loaded.finish(alloc);
    }

    /// Whether an advertised tool is still the one the model was shown.
    pub fn snapshotToolDefinition(
        c: *Catalog,
        alloc: Allocator,
        name: []const u8,
        known_binding: Binding,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: Access,
    ) !tool_mcp_runtime.DefinitionSnapshot {
        if (!access.allowsTool(c.generation, name)) return .unavailable;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const found = c.findLocked(name) orelse return .unavailable;
        if (permissions.rulesDenyAllTargetsForPermission(permission_rules, name)) return .unavailable;
        const current = c.bindingLocked(found.server, found.tool.*);
        if (std.meta.eql(known_binding, current)) return .current;
        const instructions = try c.runtime.instructions(alloc, found.server);
        defer if (instructions) |text| alloc.free(text);
        var projection = try selected_schema.project(alloc, found.tool.*, instructions, limits);
        if (projection == .rejected) {
            projection.deinit(alloc);
            return .unavailable;
        }
        if (projection.selected.notice) |notice| alloc.free(notice);
        errdefer alloc.free(projection.selected.model_output);
        return .{ .updated = .{ .name = try alloc.dupe(u8, name), .schema_json = projection.selected.model_output, .mcp_binding = current } };
    }

    /// The names of the tools in the lists the catalog has, owned by `alloc`.
    pub fn snapshotToolNames(c: *Catalog, alloc: Allocator, permission_rules: types.PermissionRuleSet) ![][]u8 {
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.lists) |l| {
            if (l.state != .loaded) continue;
            for (l.tools) |tool| {
                if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) continue;
                const name = try alloc.dupe(u8, tool.prefixed_name);
                names.append(alloc, name) catch |err| {
                    alloc.free(name);
                    return err;
                };
            }
        }
        return names.toOwnedSlice(alloc);
    }

    /// What a subagent may use: the tools in the lists the catalog has.
    pub fn snapshotAccessView(
        c: *Catalog,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
        permission_rules: types.PermissionRuleSet,
        features_visible: bool,
    ) !access_policy.View {
        var servers: std.ArrayList(access_policy.ServerIdentity) = .empty;
        var tools: std.ArrayList(access_policy.ToolIdentity) = .empty;
        errdefer {
            for (servers.items) |*s| s.deinit(alloc);
            servers.deinit(alloc);
            for (tools.items) |*t| t.deinit(alloc);
            tools.deinit(alloc);
        }
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.runtime.servers(), c.lists) |s, l| {
            if (l.state != .loaded) continue;
            try servers.ensureUnusedCapacity(alloc, 1);
            servers.appendAssumeCapacity(.{
                .name = try alloc.dupe(u8, s.name),
                .source = s.source,
                .scope = s.scope,
                .connection_generation = l.generation,
                .catalog_generation = l.generation,
                .auth_generation = 0,
            });
            for (l.tools) |tool| {
                if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) continue;
                try tools.ensureUnusedCapacity(alloc, 1);
                const name = try alloc.dupe(u8, tool.prefixed_name);
                errdefer alloc.free(name);
                tools.appendAssumeCapacity(.{ .name = name, .server_name = try alloc.dupe(u8, s.name) });
            }
        }
        const owner = try alloc.dupe(u8, owner_id);
        errdefer alloc.free(owner);
        const parent = try alloc.dupe(u8, parent_id);
        errdefer alloc.free(parent);
        const server_slice = try servers.toOwnedSlice(alloc);
        errdefer {
            for (server_slice) |*s| s.deinit(alloc);
            alloc.free(server_slice);
        }
        return .{
            .runtime_generation = c.generation,
            .owner_id = owner,
            .parent_id = parent,
            .features_visible = features_visible,
            .servers = server_slice,
            .tools = try tools.toOwnedSlice(alloc),
        };
    }

    /// The servers the model's prompt lists. Project servers that aren't
    /// approved stay out of it.
    pub fn modelSnapshot(c: *Catalog, alloc: Allocator) !model_catalog.Snapshot {
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        const statuses = try c.runtime.statuses(scratch.allocator());
        var out: std.ArrayList(model_catalog.ServerSummary) = .empty;
        errdefer {
            for (out.items) |s| alloc.free(s.name);
            out.deinit(alloc);
        }
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (statuses, c.lists) |s, l| {
            const availability: model_catalog.Availability = switch (s.state) {
                .waiting_for_approval, .rejected => continue,
                .disabled => .disabled,
                .unsupported, .missing_env => .unavailable,
                .idle => if (l.state == .loaded) .ready else .available_on_demand,
                .connecting, .retrying => .discovering,
                .ready => .ready,
                .failed => .failed,
            };
            try out.ensureUnusedCapacity(alloc, 1);
            out.appendAssumeCapacity(.{
                .name = try alloc.dupe(u8, s.name),
                .availability = if (s.needs_login) .authentication_required else availability,
                .tool_count = if (l.state == .loaded) l.tools.len else null,
            });
        }
        return .{ .servers = try out.toOwnedSlice(alloc) };
    }

    // ---- lists ----

    fn searched(request: tool_mcp_runtime.SearchRequest, s: config.Server) bool {
        if (s.held != null) return false;
        const name = request.server orelse return true;
        return std.mem.eql(u8, s.name, name);
    }

    /// Loads the lists that could hold `name`, until one does.
    fn ensure(c: *Catalog, name: []const u8, cancel: Cancel) !void {
        if (c.known(name)) return;
        for (c.runtime.servers(), 0..) |s, i| {
            if (s.held != null or !tool_names.matchesServer(name, s.name)) continue;
            try c.refresh(i, cancel);
            if (c.known(name)) return;
        }
    }

    fn known(c: *Catalog, name: []const u8) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.findLocked(name) != null;
    }

    fn findLocked(c: *const Catalog, name: []const u8) ?Found {
        for (c.lists, 0..) |l, i| {
            if (l.state != .loaded) continue;
            for (l.tools) |*tool| if (std.mem.eql(u8, tool.prefixed_name, name)) return .{ .server = i, .tool = tool };
        }
        return null;
    }

    fn bindingLocked(c: *const Catalog, server: usize, tool: McpTool) Binding {
        const generation = c.lists[server].generation;
        return .{
            .runtime_generation = c.generation,
            .connection_generation = generation,
            .catalog_generation = generation,
            .auth_generation = 0,
            .definition_digest = tool_snapshot.definitionDigest(tool, null),
        };
    }

    /// Gets server `i`'s list from the runtime and replaces the catalog's copy.
    fn refresh(c: *Catalog, i: usize, cancel: Cancel) !void {
        const server = c.runtime.servers()[i];
        if (server.held != null) return;
        var scratch: std.heap.ArenaAllocator = .init(c.gpa);
        defer scratch.deinit();
        const result = try c.runtime.tools(scratch.allocator(), server.name, cancel);
        switch (result) {
            .tools => |listed| {
                var arena: std.heap.ArenaAllocator = .init(c.gpa);
                errdefer arena.deinit();
                const tools = try c.build(arena.allocator(), server.name, listed);
                const digest = catalog_state.digestTools(tools);
                c.mutex.lockUncancelable(c.io);
                defer c.mutex.unlock(c.io);
                const l = &c.lists[i];
                if (l.digest == null or !std.mem.eql(u8, &l.digest.?, &digest)) l.generation += 1;
                if (l.arena) |*old| old.deinit();
                l.arena = arena;
                l.tools = tools;
                l.digest = digest;
                c.setStateLocked(l, .loaded, null);
            },
            .needs_login => {
                c.mutex.lockUncancelable(c.io);
                defer c.mutex.unlock(c.io);
                c.setStateLocked(&c.lists[i], .needs_login, null);
            },
            .failed => |why| {
                c.mutex.lockUncancelable(c.io);
                defer c.mutex.unlock(c.io);
                c.setStateLocked(&c.lists[i], .failed, why);
            },
            .unknown_server => {},
        }
    }

    fn setStateLocked(c: *Catalog, l: *List, state: @FieldType(List, "state"), failure: ?[]const u8) void {
        if (l.failure) |old| c.gpa.free(old);
        l.failure = if (failure) |why| c.gpa.dupe(u8, why) catch null else null;
        l.state = state;
    }

    /// The tools of one listed server as fx names them, in `a`.
    fn build(c: *Catalog, a: Allocator, server_name: []const u8, listed: []const runtime_mod.Tool) Allocator.Error![]McpTool {
        var out: std.ArrayList(McpTool) = .empty;
        for (listed) |item| {
            const parsed = tools_feature.parseToolJson(a, item.raw, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf("mcp", "MCP tool left out server={s} tool={s} err={s}", .{ server_name, item.name, @errorName(err) });
                    continue;
                },
            };
            const prefixed = c.names.name(a, c.builtins, server_name, parsed.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.McpToolNameLimitExceeded => {
                    debug_trace.logf("mcp", "MCP tool left out server={s} tool={s} err={s}", .{ server_name, item.name, @errorName(err) });
                    continue;
                },
            };
            try out.append(a, .{
                .original_name = parsed.name,
                .prefixed_name = prefixed,
                .title = parsed.title,
                .description = if (parsed.description.len > 0) parsed.description else try a.dupe(u8, "MCP tool"),
                .input_schema_json = parsed.input_schema_json,
                .output_schema_json = parsed.output_schema_json,
                .icons_json = parsed.icons_json,
                .annotations_json = parsed.annotations_json,
                .metadata_json = parsed.metadata_json,
                .tags = try tool_names.tagsFor(a, server_name, parsed.name),
            });
        }
        return out.items;
    }

    /// Why `name` can't be selected when its server's list didn't load, so
    /// the model hears more than "not found".
    fn whyUnavailableLocked(c: *Catalog, alloc: Allocator, name: []const u8) !?tool_mcp_runtime.ToolSchemaResult {
        for (c.runtime.servers(), c.lists) |s, l| {
            if (!tool_names.matchesServer(name, s.name)) continue;
            const text = switch (l.state) {
                .needs_login => try needsLoginText(alloc, s.name),
                .failed => try std.fmt.allocPrint(alloc, "MCP server '{s}' is unavailable: {s}", .{ s.name, l.failure orelse "it did not start" }),
                else => if (s.held == .missing_env)
                    try std.fmt.allocPrint(alloc, "MCP server '{s}' needs {s} set before fx starts.", .{ s.name, s.missing orelse "a variable" })
                else
                    continue,
            };
            return .{ .rejected = .{ .model_output = text } };
        }
        return null;
    }

    /// v1's answers for a search that names a server needing a login, or one
    /// that is down.
    fn renderUnavailable(c: *Catalog, alloc: Allocator, request: tool_mcp_runtime.SearchRequest) !?[]u8 {
        const named = request.server orelse request.query.raw;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.runtime.servers(), c.lists) |s, l| {
            if (!tool_search.queryContainsCompleteIdentity(named, s.name)) continue;
            if (l.state == .needs_login) {
                const guidance = try std.fmt.allocPrint(alloc, "Run fx mcp login {s} in a terminal, then search again.", .{s.name});
                defer alloc.free(guidance);
                return try tool_search.writeAuthenticationRequired(alloc, s.name, .{ .oauth = guidance });
            }
            if (s.held == .missing_env) {
                return try tool_search.writeAuthenticationRequired(alloc, s.name, .{ .bearer_environment = s.missing orelse "" });
            }
        }
        const name = request.server orelse return null;
        for (c.runtime.servers(), c.lists) |s, l| {
            if (!std.mem.eql(u8, s.name, name) or l.state != .failed) continue;
            return try tool_search.writeServerFailure(alloc, s.name, l.failure orelse "the server is unavailable");
        }
        return null;
    }
};

/// How long fx's question UI waits for the user before giving up.
const question_timeout_ms: i64 = 10 * 60 * 1000;

/// A call's questions, asked through the tool context's input responder:
/// fx's question UI in the shell, the client's elicitation in ACP.
const Asking = struct {
    responder: tool_mcp_runtime.InputResponder,
    tool: []const u8,
    cancel: ?*std.atomic.Value(bool),
    io: std.Io,
    /// The last question's origin, once one was asked.
    origin: ?tool_mcp_runtime.InputOrigin = null,

    fn finish(self: *const Asking, alloc: Allocator, outcome: tool_mcp_runtime.ContinuationTerminal) void {
        if (self.origin) |origin| self.responder.finish(alloc, origin, outcome);
    }

    fn ask(context: *anyopaque, alloc: Allocator, question: runtime_mod.Question) anyerror!?[]u8 {
        const self: *Asking = @ptrCast(@alignCast(context));
        const origin: tool_mcp_runtime.InputOrigin = .{
            .wire = wireFor(question.version),
            .server_name = question.server,
            .operation = .{ .tools_call = self.tool },
            .connection_generation = 0,
            .client_generation = 0,
            .catalog_generation = 0,
            .request_generation = 0,
            .auth_generation = 0,
            .deadline_ms = std.Io.Clock.awake.now(self.io).toMilliseconds() + question_timeout_ms,
            .lifecycle_cancel_flag = self.cancel,
        };
        self.origin = origin;
        const answer = try self.responder.callback(self.responder.context, alloc, origin, .{ .input_requests_json = question.input_requests_json });
        return @constCast(answer);
    }

    /// A 2025 server's form schema reads by its version's rules.
    fn wireFor(version: ?[]const u8) elicitation.Wire {
        const v = version orelse return .modern_mcp;
        if (std.mem.eql(u8, v, "2025-06-18") or std.mem.eql(u8, v, "2025-03-26")) return .legacy_mcp_2025_06;
        if (std.mem.startsWith(u8, v, "2025-")) return .legacy_mcp_2025_11;
        return .modern_mcp;
    }
};

/// Turns the runtime's answer into the result the model sees, through fx's
/// result projection: content, images, size limits, and errors.
fn render(arena: Allocator, server: []const u8, name: []const u8, answer: runtime_mod.CallResult, max_bytes: usize) !?tool_mcp_runtime.CallResult {
    const response = switch (answer) {
        .result => |r| if (r.structured) |structured|
            try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{{\"content\":{s},\"structuredContent\":{s},\"isError\":{s}}}}}", .{ r.content, structured, if (r.is_error) "true" else "false" })
        else
            try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{{\"content\":{s},\"isError\":{s}}}}}", .{ r.content, if (r.is_error) "true" else "false" }),
        .failure => |f| try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{{\"code\":{d},\"message\":{s}}}}}", .{ f.code, f.message }),
        .ended => |e| return try ended(arena, server, name, e, max_bytes),
        .unknown_server => return null,
    };
    return try tool_result.extract(arena, .{
        .server_name = server,
        .tool_name = name,
        .response = response,
        .max_tool_result_bytes = max_bytes,
        .protocol = .modern,
    });
}

/// A call that ended without an answer.
fn ended(arena: Allocator, server: []const u8, name: []const u8, e: @FieldType(runtime_mod.CallResult, "ended"), max_bytes: usize) !tool_mcp_runtime.CallResult {
    if (e.outcome == .cancelled) return error.Cancelled;
    const why = switch (e.outcome) {
        .needs_auth => return .{
            .model_output = try tool_result_limits.prepareModelOutput(arena, name, try needsLoginText(arena, server), max_bytes),
            .status = .tool_failure,
        },
        .lost => "the server went away",
        .transport_failed, .http_failure => "the connection failed",
        .malformed => "the server's answer was malformed",
        .rounds_exceeded => "the server asked for input too many times",
        .unsupported_input => "the server asked for input fx can't give",
        .denied => "fx's permission refused it",
        else => @tagName(e.outcome),
    };
    const text = try std.fmt.allocPrint(arena, "MCP server '{s}' ended the call: {s}{s}{s}", .{
        server,
        if (e.timed_out) "it did not answer in time" else why,
        if (e.maybe_ran) ". The tool may have run" else "",
        ".",
    });
    return .{ .model_output = try tool_result_limits.prepareModelOutput(arena, name, text, max_bytes), .status = .protocol_failure };
}

fn needsLoginText(alloc: Allocator, server: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "MCP server '{s}' needs a login. Ask the user to run fx mcp login {s}, then try again.", .{ server, server });
}

fn catalog(raw: *anyopaque) *Catalog {
    return @ptrCast(@alignCast(raw));
}

fn hasToolFn(raw: *anyopaque, name: []const u8, access: Access) bool {
    return catalog(raw).hasTool(name, access);
}

fn validateToolFn(raw: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, access: Access) anyerror!tool_mcp_runtime.ValidationResult {
    return catalog(raw).validateTool(arena, name, arguments_json, access);
}

fn callToolFn(raw: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, max_bytes: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
    return catalog(raw).callTool(arena, name, arguments_json, max_bytes, options);
}

fn searchToolsFn(raw: *anyopaque, alloc: Allocator, request: tool_mcp_runtime.SearchRequest, rules: types.PermissionRuleSet, limits: context_limits.Values, access: Access, cancel: Cancel) anyerror!tool_mcp_runtime.SearchResult {
    return catalog(raw).searchTools(alloc, request, rules, limits, access, cancel);
}

fn toolSchemaFn(raw: *anyopaque, alloc: Allocator, name: []const u8, rules: types.PermissionRuleSet, limits: context_limits.Values, access: Access, cancel: Cancel) anyerror!?tool_mcp_runtime.ToolSchemaResult {
    return catalog(raw).toolSchema(alloc, name, rules, limits, access, cancel);
}

fn snapshotToolFn(raw: *anyopaque, alloc: Allocator, name: []const u8, known_binding: Binding, rules: types.PermissionRuleSet, limits: context_limits.Values, access: Access) anyerror!tool_mcp_runtime.DefinitionSnapshot {
    return catalog(raw).snapshotToolDefinition(alloc, name, known_binding, rules, limits, access);
}

const testing = std.testing;
const Fixture = @import("fake_server.zig").Fixture;
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");

test "an MCP-v2 server's tools reach the model under fx's names" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Asking for a tool by its fx name starts its server and loads the list.
    try testing.expect(c.hasTool("mcp_fake_echo", .unrestricted));
    try testing.expect(!c.hasTool("mcp_fake_nope", .unrestricted));
    try testing.expect(!c.hasTool("mcp_fake_echo", .disabled));

    const query = try lexical_relevance.prepare("echo");
    const found = try c.searchTools(a, .{ .query = &query, .kind = .mcp }, .{}, .{}, .unrestricted, null);
    try testing.expect(std.mem.indexOf(u8, found.model_output, "\"name\":\"mcp_fake_echo\",\"server\":\"fake\"") != null);
    try testing.expectEqual(@as(usize, 1), found.selected_tools.len);
    const binding = found.selected_tools[0].mcp_binding.?;
    try testing.expectEqual(c.generation, binding.runtime_generation);

    const schema = (try c.toolSchema(a, "mcp_fake_echo", .{}, .{}, .unrestricted, null)).?;
    try testing.expect(std.meta.eql(binding, schema.selected.mcp_binding.?));
    try testing.expect(std.mem.indexOf(u8, schema.selected.model_output, "mcp_fake_echo") != null);
    try testing.expect((try c.snapshotToolDefinition(a, "mcp_fake_echo", binding, .{}, .{}, .unrestricted)) == .current);

    try testing.expectEqual(c.generation, (try c.validateTool(a, "mcp_fake_echo", "{}", .unrestricted)).valid);
    try testing.expect((try c.validateTool(a, "mcp_fake_echo", "[", .unrestricted)) == .invalid);

    const result = (try c.callTool(a, "mcp_fake_echo", "{}", 4096, .{ .expected_binding = binding })).?;
    try testing.expectEqual(tool_mcp_runtime.CallStatus.success, result.status);
    try testing.expect(std.mem.indexOf(u8, result.model_output, "hi") != null);
    var stale = binding;
    stale.runtime_generation +%= 1;
    try testing.expectError(error.McpAdvertisedToolChanged, c.callTool(a, "mcp_fake_echo", "{}", 4096, .{ .expected_binding = stale }));
    try testing.expect((try c.callTool(a, "mcp_fake_nope", "{}", 4096, .{})) == null);

    try testing.expectEqual(@as(usize, 1), (try c.snapshotToolNames(a, .{})).len);
    var view = try c.snapshotAccessView(testing.allocator, "child", "parent", .{}, false);
    defer view.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), view.tools.len);
    try testing.expect(Access.allowsTool(.{ .scoped = .{ .captured = &view, .admission_authority_generation = 0, .live = undefined } }, c.generation, "mcp_fake_echo"));
    var snapshot = try c.modelSnapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqual(model_catalog.Availability.ready, snapshot.servers[0].availability);
    try testing.expectEqual(@as(?usize, 1), snapshot.servers[0].tool_count);
}

test "a search says why a server it names has no tools, and calls that end say how" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{
        .name = "keyed",
        .transport = .http,
        .url = "https://example.invalid/mcp",
        .bearer_token_env = @constCast("FX_MCP_HOST_TEST_UNSET"),
    }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var c: Catalog = undefined;
    try c.init(testing.allocator, testing.io, &r, .{});
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const query = try lexical_relevance.prepare("issues");
    const keyed = try c.searchTools(a, .{ .query = &query, .kind = .mcp, .server = "keyed" }, .{}, .{}, .unrestricted, null);
    try testing.expectEqualStrings(
        "{\"tools\":[],\"count\":0,\"authentication_required\":{\"server\":\"keyed\",\"interactive\":false,\"environment\":\"FX_MCP_HOST_TEST_UNSET\",\"message\":\"Set this environment variable before starting fx.\"}}",
        keyed.model_output,
    );
    const missing = try c.searchTools(a, .{ .query = &query, .kind = .mcp, .server = "nope" }, .{}, .{}, .unrestricted, null);
    try testing.expect(std.mem.indexOf(u8, missing.model_output, "\"state\":\"server_not_found\"") != null);

    const login = try ended(a, "linear", "mcp_linear_list", .{ .outcome = .needs_auth, .maybe_ran = false, .timed_out = false }, 4096);
    try testing.expectEqual(tool_mcp_runtime.CallStatus.tool_failure, login.status);
    try testing.expect(std.mem.indexOf(u8, login.model_output, "fx mcp login linear") != null);
    const lost = try ended(a, "linear", "mcp_linear_list", .{ .outcome = .lost, .maybe_ran = true, .timed_out = false }, 4096);
    try testing.expectEqual(tool_mcp_runtime.CallStatus.protocol_failure, lost.status);
    try testing.expect(std.mem.indexOf(u8, lost.model_output, "the server went away. The tool may have run.") != null);
    try testing.expectError(error.Cancelled, ended(a, "linear", "mcp_linear_list", .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false }, 4096));
}
