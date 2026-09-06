const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mcp_auth = @import("../mcp/mcp_auth.zig");
const mcp_command_provider = @import("../mcp/command_provider.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const elicitation = @import("../mcp/elicitation.zig");
const mcp_health = @import("../mcp/health.zig");
const mcp_menu_state = @import("../mcp/menu_state.zig");
const mcp_model_catalog = @import("../mcp/model_catalog.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const completion_feature = @import("../mcp/features/completion.zig");
const context_limits = @import("../config/context_limits.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const Lease = struct {
    runtime: *mcp_runtime.McpRuntime,

    pub fn deinit(self: *Lease) void {
        self.runtime.releaseUse();
        self.* = undefined;
    }
};

pub const PublishedReload = struct {
    generation: ?u64,
    health: mcp_health.StartupDecision,
    configured_server_count: usize,
    unavailable_server_names: [][]u8,

    fn init(
        alloc: Allocator,
        generation: ?u64,
        servers: []const mcp_health.ServerSnapshot,
    ) !PublishedReload {
        var unavailable_count: usize = 0;
        for (servers) |server| {
            if (isUnavailableForReload(server)) unavailable_count += 1;
        }

        const names = try alloc.alloc([]u8, unavailable_count);
        errdefer alloc.free(names);
        var initialized: usize = 0;
        errdefer for (names[0..initialized]) |name| alloc.free(name);
        for (servers) |server| {
            if (!isUnavailableForReload(server)) continue;
            names[initialized] = try alloc.dupe(u8, server.configured_name);
            initialized += 1;
        }

        return .{
            .generation = generation,
            .health = mcp_health.startupDecision(servers),
            .configured_server_count = servers.len,
            .unavailable_server_names = names,
        };
    }

    pub fn deinit(self: *PublishedReload, alloc: Allocator) void {
        for (self.unavailable_server_names) |name| alloc.free(name);
        alloc.free(self.unavailable_server_names);
        self.* = undefined;
    }
};

pub const ReloadOutcome = union(enum) {
    published: PublishedReload,
    retained_required_failure: []u8,

    pub fn deinit(self: *ReloadOutcome, alloc: Allocator) void {
        switch (self.*) {
            .published => |*published| published.deinit(alloc),
            .retained_required_failure => |message| alloc.free(message),
        }
        self.* = undefined;
    }
};

fn isUnavailableForReload(server: mcp_health.ServerSnapshot) bool {
    return server.connection != .ready and
        (server.connection != .disabled or server.required);
}

pub const ReloadCompletion = union(enum) {
    outcome: ReloadOutcome,
    failed: anyerror,

    pub fn deinit(self: *ReloadCompletion, alloc: Allocator) void {
        switch (self.*) {
            .outcome => |*outcome| outcome.deinit(alloc),
            .failed => {},
        }
        self.* = undefined;
    }
};

const PendingResult = union(enum) {
    outcome: ReloadOutcome,
    failed: anyerror,
    cancelled,
};

const ReloadPolicy = enum {
    transactional,
    authority_reducing,
};

pub const PresentationOrigin = union(enum) {
    command,
    menu: u64,
};

const PendingReload = struct {
    owner: *State,
    alloc: Allocator,
    workspace_root: []u8,
    elicitation_capabilities: elicitation.Capabilities,
    loader: mcp_runtime.LoadRuntimeFn,
    preview_workspace_authority: ?mcp_runtime.PreviewNativeWorkspaceAuthorityFn = null,
    registry: tool_dispatch.Registry,
    captured_at_ms: u64,
    presentation_origin: PresentationOrigin = .command,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    result: ?PendingResult = null,
    policy: ReloadPolicy = .transactional,
    rebuild: bool = true,
    superseded_reload: ?*PendingReload = null,
    superseded_authentication: ?*PendingAuthentication = null,

    fn run(self: *PendingReload) void {
        if (self.policy == .authority_reducing) self.quiesceSupersededWork();
        const outcome = switch (self.policy) {
            .transactional => self.owner.reloadControlled(
                self.alloc,
                self.workspace_root,
                self.elicitation_capabilities,
                self.loader,
                self.preview_workspace_authority.?,
                self.registry,
                self.captured_at_ms,
                &self.cancel_requested,
                self,
            ),
            .authority_reducing => self.owner.reloadAuthorityReducedControlled(
                self.alloc,
                self.workspace_root,
                self.elicitation_capabilities,
                self.loader,
                self.registry,
                self.captured_at_ms,
                &self.cancel_requested,
                self,
                self.rebuild,
            ),
        } catch |err| {
            self.result = if (err == error.Cancelled)
                .cancelled
            else
                .{ .failed = err };
            self.done.store(true, .release);
            return;
        };
        self.result = .{ .outcome = outcome };
        self.done.store(true, .release);
    }

    fn quiesceSupersededWork(self: *PendingReload) void {
        // Authentication can hold the lease that a retiring reload is waiting for.
        if (self.superseded_authentication) |task| {
            self.superseded_authentication = null;
            cancelAndDeinitAuthentication(task, "authority_reduction");
        }
        if (self.superseded_reload) |task| {
            self.superseded_reload = null;
            task.deinit();
        }
    }

    fn join(self: *PendingReload) void {
        if (comptime builtin.single_threaded) {
            std.debug.assert(self.thread == null);
            return;
        }
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn deinit(self: *PendingReload) void {
        self.join();
        self.quiesceSupersededWork();
        if (self.result) |*result| switch (result.*) {
            .outcome => |*outcome| outcome.deinit(self.alloc),
            .failed, .cancelled => {},
        };
        self.alloc.free(self.workspace_root);
        self.alloc.destroy(self);
    }
};

pub const AuthenticationCompletion = struct {
    server_name: []u8,
    reconnect_error: ?anyerror = null,
    result: anyerror!mcp_auth.AuthenticationResult,

    pub fn deinit(self: *AuthenticationCompletion, alloc: Allocator) void {
        alloc.free(self.server_name);
        deinitAuthenticationResult(self.result);
        self.* = undefined;
    }
};

const PendingAuthentication = struct {
    alloc: Allocator,
    server_name: []u8,
    lease: Lease,
    opener: host.UrlOpener,
    presentation_origin: PresentationOrigin = .command,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    reconnect_error: ?anyerror = null,
    result: ?(anyerror!mcp_auth.AuthenticationResult) = null,

    fn run(self: *PendingAuthentication) void {
        self.result = self.lease.runtime.authenticateServerControlled(
            self.server_name,
            self,
            openUrl,
            &self.cancel_requested,
        );
        if (self.result.?) |outcome| {
            if (outcome == .authenticated) {
                self.lease.runtime.reconnectAuthenticatedServer(self.server_name, &self.cancel_requested) catch |err| {
                    self.reconnect_error = err;
                };
            }
        } else |_| {}
        self.done.store(true, .release);
    }

    fn openUrl(
        raw: ?*anyopaque,
        alloc: Allocator,
        url: []const u8,
    ) anyerror!bool {
        const self: *PendingAuthentication = @ptrCast(@alignCast(raw.?));
        return self.opener.open(alloc, url);
    }

    fn join(self: *PendingAuthentication) void {
        if (comptime builtin.single_threaded) {
            std.debug.assert(self.thread == null);
            return;
        }
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn deinit(self: *PendingAuthentication) void {
        self.join();
        if (self.result) |result| deinitAuthenticationResult(result);
        self.lease.deinit();
        self.alloc.free(self.server_name);
        self.alloc.destroy(self);
    }
};

const max_menu_preview_bytes: usize = 64 * 1024;

pub const MenuResourceCatalog = struct {
    resources: mcp_runtime.ResourceCatalogResult,
    templates: mcp_runtime.ResourceCatalogResult,

    fn deinit(self: *MenuResourceCatalog, alloc: Allocator) void {
        self.resources.deinit(alloc);
        self.templates.deinit(alloc);
        self.* = undefined;
    }

    fn count(self: MenuResourceCatalog) usize {
        return self.resources.items.len + self.templates.items.len;
    }

    fn filteredItem(
        self: MenuResourceCatalog,
        index: usize,
        query: []const u8,
    ) ?*const mcp_runtime.ResourceSummary {
        var matched: usize = 0;
        for (self.resources.items) |*item_value| {
            if (!menuResourceMatches(item_value.*, query)) continue;
            if (matched == index) return item_value;
            matched += 1;
        }
        for (self.templates.items) |*item_value| {
            if (!menuResourceMatches(item_value.*, query)) continue;
            if (matched == index) return item_value;
            matched += 1;
        }
        return null;
    }
};

fn menuResourceMatches(item: mcp_runtime.ResourceSummary, query: []const u8) bool {
    return mcp_menu_state.textMatchesQuery(item.uri, query) or
        mcp_menu_state.textMatchesQuery(item.name, query) or
        (item.title != null and mcp_menu_state.textMatchesQuery(item.title.?, query)) or
        (item.description != null and mcp_menu_state.textMatchesQuery(item.description.?, query));
}

fn menuPromptMatches(item: mcp_runtime.PromptSummary, query: []const u8) bool {
    return mcp_menu_state.textMatchesQuery(item.name, query) or
        (item.title != null and mcp_menu_state.textMatchesQuery(item.title.?, query)) or
        (item.description != null and mcp_menu_state.textMatchesQuery(item.description.?, query));
}

fn appendMenuArgumentField(
    alloc: Allocator,
    fields: *std.ArrayList(MenuArgumentField),
    name: []const u8,
    required: bool,
) !void {
    for (fields.items) |field| {
        if (std.mem.eql(u8, field.name, name)) return;
    }
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try fields.append(alloc, .{ .name = owned_name, .required = required });
}

fn appendTemplateArgumentFields(
    alloc: Allocator,
    fields: *std.ArrayList(MenuArgumentField),
    uri_template: []const u8,
) !void {
    var remaining = uri_template;
    while (std.mem.findScalar(u8, remaining, '{')) |open| {
        const after_open = remaining[open + 1 ..];
        const relative_close = std.mem.findScalar(u8, after_open, '}') orelse
            return error.McpResourceTemplateInvalid;
        const expression = after_open[0..relative_close];
        var variables = std.mem.splitScalar(u8, expression, ',');
        while (variables.next()) |raw_variable| {
            var variable = raw_variable;
            if (variable.len > 0 and std.mem.findScalar(u8, "+#./;?&", variable[0]) != null) {
                variable = variable[1..];
            }
            const modifier = std.mem.indexOfAny(u8, variable, ":*") orelse variable.len;
            const name = variable[0..modifier];
            if (name.len > 0) try appendMenuArgumentField(alloc, fields, name, true);
        }
        remaining = after_open[relative_close + 1 ..];
    }
}

fn expandResourceTemplate(
    alloc: Allocator,
    uri_template: []const u8,
    arguments: []const OwnedMenuArgument,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var remaining = uri_template;
    while (std.mem.findScalar(u8, remaining, '{')) |open| {
        try out.writer.writeAll(remaining[0..open]);
        const after_open = remaining[open + 1 ..];
        const relative_close = std.mem.findScalar(u8, after_open, '}') orelse
            return error.McpResourceTemplateInvalid;
        const expression = after_open[0..relative_close];
        if (expression.len == 0) return error.McpResourceTemplateInvalid;
        const operator = if (std.mem.findScalar(u8, "+#./;?&", expression[0]) != null)
            expression[0]
        else
            @as(u8, 0);
        const variables_text = if (operator == 0) expression else expression[1..];
        const prefix: []const u8 = switch (operator) {
            '#' => "#",
            '.' => ".",
            '/' => "/",
            ';' => ";",
            '?' => "?",
            '&' => "&",
            else => "",
        };
        const separator: []const u8 = switch (operator) {
            '.' => ".",
            '/' => "/",
            ';' => ";",
            '?', '&' => "&",
            else => ",",
        };
        try out.writer.writeAll(prefix);
        var variables = std.mem.splitScalar(u8, variables_text, ',');
        var variable_index: usize = 0;
        while (variables.next()) |raw_variable| : (variable_index += 1) {
            const modifier = std.mem.indexOfAny(u8, raw_variable, ":*") orelse raw_variable.len;
            const name = raw_variable[0..modifier];
            const value = for (arguments) |argument| {
                if (std.mem.eql(u8, argument.name, name)) break argument.value;
            } else return error.McpResourceTemplateArgumentMissing;
            if (variable_index > 0) try out.writer.writeAll(separator);
            if (operator == ';' or operator == '?' or operator == '&') {
                try writeTemplateValue(&out.writer, name, false);
                try out.writer.writeByte('=');
            }
            try writeTemplateValue(&out.writer, value, operator == '+' or operator == '#');
        }
        remaining = after_open[relative_close + 1 ..];
    }
    try out.writer.writeAll(remaining);
    return out.toOwnedSlice();
}

fn writeTemplateValue(writer: *std.Io.Writer, value: []const u8, allow_reserved: bool) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or
            std.mem.findScalar(u8, "-._~", byte) != null or
            (allow_reserved and std.mem.findScalar(u8, ":/?#[]@!$&'()*+,;=", byte) != null))
        {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

const MenuPreview = struct {
    display: []u8,
    insert: []u8,

    fn deinit(self: *MenuPreview, alloc: Allocator) void {
        alloc.free(self.display);
        alloc.free(self.insert);
        self.* = undefined;
    }
};

const MenuOperationResult = union(enum) {
    tools: [][]u8,
    resources: MenuResourceCatalog,
    prompts: mcp_runtime.PromptCatalogResult,
    preview: MenuPreview,
    completion: MenuArgumentCompletion,
    action: MenuActionResult,
    failed: anyerror,
    cancelled,

    fn deinit(self: *MenuOperationResult, alloc: Allocator) void {
        switch (self.*) {
            .tools => |items| {
                for (items) |item| alloc.free(item);
                alloc.free(items);
            },
            .resources => |*catalog| catalog.deinit(alloc),
            .prompts => |*catalog| catalog.deinit(alloc),
            .preview => |*preview| preview.deinit(alloc),
            .completion => |*completion| completion.deinit(alloc),
            .action => |*action| action.deinit(alloc),
            .failed, .cancelled => {},
        }
        self.* = undefined;
    }
};

const MenuArgumentCompletion = struct {
    field_index: usize,
    value: []u8,

    fn deinit(self: *MenuArgumentCompletion, alloc: Allocator) void {
        alloc.free(self.value);
        self.* = undefined;
    }
};

const MenuActionResult = struct {
    feedback: []u8,

    fn deinit(self: *MenuActionResult, alloc: Allocator) void {
        alloc.free(self.feedback);
        self.* = undefined;
    }
};

const MenuOperationKind = enum { catalog, preview, completion, action };
const menu_catalog_loading_grace_ms: i64 = 200;

const MenuOperation = struct {
    kind: MenuOperationKind,
    request: mcp_menu_state.Request,
};

const OwnedMenuArgument = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: *OwnedMenuArgument, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.value);
        self.* = undefined;
    }
};

fn cloneMenuArguments(
    alloc: Allocator,
    fields: []const MenuArgumentField,
) ![]OwnedMenuArgument {
    if (fields.len == 0) return &.{};
    const arguments = try alloc.alloc(OwnedMenuArgument, fields.len);
    var initialized: usize = 0;
    errdefer {
        for (arguments[0..initialized]) |*argument| argument.deinit(alloc);
        alloc.free(arguments);
    }
    for (fields, 0..) |field, index| {
        const name = try alloc.dupe(u8, field.name);
        errdefer alloc.free(name);
        arguments[index] = .{
            .name = name,
            .value = try alloc.dupe(u8, field.value.items),
        };
        initialized += 1;
    }
    return arguments;
}

const PendingMenuOperation = struct {
    alloc: Allocator,
    request: mcp_menu_state.Request,
    kind: MenuOperationKind,
    lease: Lease,
    permission_rules: types.PermissionRuleSet,
    limits: context_limits.Values,
    server_name: ?[]u8 = null,
    identity: ?[]u8 = null,
    arguments: []OwnedMenuArgument = &.{},
    argument_index: usize = 0,
    resource_template: bool = false,
    action: ?mcp_menu_state.Action = null,
    started_at_ms: i64,
    catalog_loading_visible: bool = false,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    result: ?MenuOperationResult = null,

    fn run(self: *PendingMenuOperation) void {
        self.result = self.perform() catch |err| if (err == error.Cancelled)
            .cancelled
        else
            .{ .failed = err };
        self.done.store(true, .release);
    }

    fn perform(self: *PendingMenuOperation) !MenuOperationResult {
        if (self.cancel_requested.load(.acquire)) return error.Cancelled;
        return switch (self.kind) {
            .catalog => switch (self.request.section) {
                .servers => error.McpMenuInvalidOperation,
                .tools => .{ .tools = try self.lease.runtime.snapshotToolNames(
                    self.alloc,
                    self.permission_rules,
                ) },
                .resources => resources: {
                    const server_name = self.server_name orelse return error.McpServerNotFound;
                    var resources = try self.lease.runtime.listResources(
                        self.alloc,
                        server_name,
                        false,
                        &self.cancel_requested,
                        .unrestricted,
                    );
                    errdefer resources.deinit(self.alloc);
                    const templates = try self.lease.runtime.listResources(
                        self.alloc,
                        server_name,
                        true,
                        &self.cancel_requested,
                        .unrestricted,
                    );
                    break :resources .{ .resources = .{
                        .resources = resources,
                        .templates = templates,
                    } };
                },
                .prompts => .{ .prompts = try self.lease.runtime.listPrompts(
                    self.alloc,
                    self.server_name orelse return error.McpServerNotFound,
                    &self.cancel_requested,
                    .unrestricted,
                ) },
            },
            .preview => switch (self.request.section) {
                .servers => error.McpMenuInvalidOperation,
                .tools => .{ .preview = try self.previewTool() },
                .resources => .{ .preview = try self.previewResource() },
                .prompts => .{ .preview = try self.previewPrompt() },
            },
            .completion => .{ .completion = try self.completeArgument() },
            .action => switch (self.action orelse return error.McpMenuInvalidOperation) {
                .logout => .{ .action = try self.logoutServer() },
                else => error.McpMenuInvalidOperation,
            },
        };
    }

    fn completeArgument(self: *PendingMenuOperation) !MenuArgumentCompletion {
        if (self.argument_index >= self.arguments.len) return error.McpMenuInvalidField;
        const current = self.arguments[self.argument_index];
        const context_count = self.arguments.len - 1;
        const context = try self.alloc.alloc(completion_feature.Argument, context_count);
        defer self.alloc.free(context);
        var context_index: usize = 0;
        for (self.arguments, 0..) |argument, index| {
            if (index == self.argument_index) continue;
            context[context_index] = .{ .name = argument.name, .value = argument.value };
            context_index += 1;
        }
        var completion = switch (self.request.section) {
            .resources => try self.lease.runtime.completeResourceTemplateArgument(
                self.alloc,
                self.server_name orelse return error.McpServerNotFound,
                self.identity orelse return error.McpResourceNotFound,
                .{ .name = current.name, .value = current.value },
                context,
                &self.cancel_requested,
                .unrestricted,
            ),
            .prompts => try self.lease.runtime.completePromptArgument(
                self.alloc,
                self.server_name orelse return error.McpServerNotFound,
                self.identity orelse return error.McpPromptNotFound,
                .{ .name = current.name, .value = current.value },
                context,
                &self.cancel_requested,
                .unrestricted,
            ),
            .servers, .tools => return error.McpMenuInvalidOperation,
        };
        defer completion.deinit(self.alloc);
        if (completion.values.len == 0) return error.McpCompletionEmpty;
        return .{
            .field_index = self.argument_index,
            .value = try self.alloc.dupe(u8, completion.values[0]),
        };
    }

    fn logoutServer(self: *PendingMenuOperation) !MenuActionResult {
        const server_name = self.server_name orelse return error.McpServerNotFound;
        const result = try self.lease.runtime.logoutServer(server_name);
        const feedback = if (!result.removed)
            try allocMenuText(
                self.alloc,
                &.{ "No stored MCP credentials found for '", server_name, "'." },
            )
        else if (result.revocation_failed)
            try allocMenuText(
                self.alloc,
                &.{ "Logged out of '", server_name, "' locally; remote revocation failed." },
            )
        else
            try allocMenuText(
                self.alloc,
                &.{ "Logged out of MCP server '", server_name, "'. Run /mcp auth ", server_name, " --open to sign in again." },
            );
        return .{ .feedback = feedback };
    }

    fn previewTool(self: *PendingMenuOperation) !MenuPreview {
        var schema = (try self.lease.runtime.toolSchemaJsonByNameWithAccess(
            self.alloc,
            self.identity orelse return error.McpToolNotFound,
            self.permission_rules,
            self.limits,
            .unrestricted,
            &self.cancel_requested,
        )) orelse return error.McpToolNotFound;
        defer schema.deinit(self.alloc);
        const payload = switch (schema) {
            .selected => |value| value,
            .rejected => return error.McpAccessDenied,
        };
        return makeMenuPreview(self.alloc, "MCP tool schema · untrusted metadata\n\n", payload.model_output);
    }

    fn previewResource(self: *PendingMenuOperation) !MenuPreview {
        const server_name = self.server_name orelse return error.McpServerNotFound;
        const identity = self.identity orelse return error.McpResourceNotFound;
        if (self.resource_template) {
            const resolved = try expandResourceTemplate(
                self.alloc,
                identity,
                self.arguments,
            );
            defer self.alloc.free(resolved);
            return self.readResourcePreview(server_name, resolved);
        }
        return self.readResourcePreview(server_name, identity);
    }

    fn readResourcePreview(
        self: *PendingMenuOperation,
        server_name: []const u8,
        identity: []const u8,
    ) !MenuPreview {
        var result = try self.lease.runtime.readResource(
            self.alloc,
            server_name,
            identity,
            .{ .cancel_flag = &self.cancel_requested, .access = .unrestricted },
        );
        defer result.deinit(self.alloc);
        var raw: std.Io.Writer.Allocating = .init(self.alloc);
        defer raw.deinit();
        for (result.contents, 0..) |content, index| {
            if (index > 0) try raw.writer.writeAll("\n\n");
            switch (content.data) {
                .text => |value| try raw.writer.writeAll(value),
                .blob => try raw.writer.writeAll("[binary MCP resource content omitted]"),
            }
        }
        const insert = try boundedOwnedSlice(self.alloc, raw.written(), max_menu_preview_bytes);
        errdefer self.alloc.free(insert);
        return makeMenuPreviewOwned(
            self.alloc,
            "MCP resource · untrusted content\n\n",
            insert,
        );
    }

    fn previewPrompt(self: *PendingMenuOperation) !MenuPreview {
        var json: std.Io.Writer.Allocating = .init(self.alloc);
        defer json.deinit();
        try json.writer.writeByte('{');
        var written: usize = 0;
        for (self.arguments) |argument| {
            if (argument.value.len == 0) continue;
            if (written > 0) try json.writer.writeByte(',');
            try std.json.Stringify.value(argument.name, .{}, &json.writer);
            try json.writer.writeByte(':');
            try std.json.Stringify.value(argument.value, .{}, &json.writer);
            written += 1;
        }
        try json.writer.writeByte('}');
        var result = try self.lease.runtime.getPrompt(
            self.alloc,
            self.server_name orelse return error.McpServerNotFound,
            self.identity orelse return error.McpPromptNotFound,
            json.written(),
            .{ .cancel_flag = &self.cancel_requested, .access = .unrestricted },
        );
        defer result.deinit(self.alloc);
        var raw: std.Io.Writer.Allocating = .init(self.alloc);
        defer raw.deinit();
        for (result.messages, 0..) |message, index| {
            if (index > 0) try raw.writer.writeAll("\n\n");
            try raw.writer.print("{s}: {s}", .{ @tagName(message.role), message.content_json });
        }
        const insert = try boundedOwnedSlice(self.alloc, raw.written(), max_menu_preview_bytes);
        errdefer self.alloc.free(insert);
        return makeMenuPreviewOwned(
            self.alloc,
            "MCP prompt · untrusted content\n\n",
            insert,
        );
    }

    fn join(self: *PendingMenuOperation) void {
        if (comptime builtin.single_threaded) {
            std.debug.assert(self.thread == null);
            return;
        }
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
    }

    fn deinit(self: *PendingMenuOperation) void {
        self.join();
        if (self.result) |*result| result.deinit(self.alloc);
        if (self.server_name) |value| self.alloc.free(value);
        if (self.identity) |value| self.alloc.free(value);
        for (self.arguments) |*argument| argument.deinit(self.alloc);
        if (self.arguments.len > 0) self.alloc.free(self.arguments);
        types.freePermissionRuleSlice(self.alloc, self.permission_rules.rules);
        self.lease.deinit();
        self.alloc.destroy(self);
    }
};

fn spawnPendingMenuOperation(pending: *PendingMenuOperation) !std.Thread {
    if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
    return std.Thread.spawn(.{}, PendingMenuOperation.run, .{pending});
}

fn boundedOwnedSlice(alloc: Allocator, bytes: []const u8, max_bytes: usize) ![]u8 {
    const bounded = text_utils.utf8PrefixByBytes(bytes, @min(bytes.len, max_bytes));
    return alloc.dupe(u8, bounded);
}

noinline fn allocMenuText(alloc: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    var total_bytes: usize = 0;
    for (parts) |part| {
        total_bytes = std.math.add(usize, total_bytes, part.len) catch
            return error.OutOfMemory;
    }
    const text = try alloc.alloc(u8, total_bytes);
    var offset: usize = 0;
    for (parts) |part| {
        @memcpy(text[offset..][0..part.len], part);
        offset += part.len;
    }
    return text;
}

fn makeMenuPreview(alloc: Allocator, heading: []const u8, raw: []const u8) !MenuPreview {
    return makeMenuPreviewOwned(
        alloc,
        heading,
        try boundedOwnedSlice(alloc, raw, max_menu_preview_bytes),
    );
}

fn makeMenuPreviewOwned(alloc: Allocator, heading: []const u8, insert: []u8) !MenuPreview {
    errdefer alloc.free(insert);
    var encoded = try text_utils.encodeTerminalSafe(alloc, insert, max_menu_preview_bytes);
    defer encoded.deinit(alloc);
    return .{
        .display = try std.mem.concat(alloc, u8, &.{ heading, encoded.bytes }),
        .insert = insert,
    };
}

pub const MenuAddForm = struct {
    name: std.ArrayList(u8) = .empty,
    target: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *MenuAddForm, alloc: Allocator) void {
        self.name.deinit(alloc);
        self.target.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = .{};
    }

    fn value(self: *const MenuAddForm, field_index: usize) []const u8 {
        return switch (field_index) {
            0 => self.name.items,
            1 => self.target.items,
            2 => self.arguments.items,
            else => "",
        };
    }

    fn set(self: *MenuAddForm, alloc: Allocator, field_index: usize, bytes: []const u8) !void {
        const field = switch (field_index) {
            0 => &self.name,
            1 => &self.target,
            2 => &self.arguments,
            else => return error.McpMenuInvalidField,
        };
        try field.ensureTotalCapacity(alloc, bytes.len);
        field.clearRetainingCapacity();
        field.appendSliceAssumeCapacity(bytes);
    }
};

pub const MenuArgumentField = struct {
    name: []u8,
    required: bool,
    value: std.ArrayList(u8) = .empty,

    fn deinit(self: *MenuArgumentField, alloc: Allocator) void {
        alloc.free(self.name);
        self.value.deinit(alloc);
        self.* = undefined;
    }
};

const MenuArgumentForm = struct {
    fields: []MenuArgumentField = &.{},

    fn deinit(self: *MenuArgumentForm, alloc: Allocator) void {
        for (self.fields) |*field| field.deinit(alloc);
        if (self.fields.len > 0) alloc.free(self.fields);
        self.* = .{};
    }

    fn set(self: *MenuArgumentForm, alloc: Allocator, field_index: usize, bytes: []const u8) !void {
        if (field_index >= self.fields.len) return error.McpMenuInvalidField;
        const field = &self.fields[field_index].value;
        try field.ensureTotalCapacity(alloc, bytes.len);
        field.clearRetainingCapacity();
        field.appendSliceAssumeCapacity(bytes);
    }

    fn allRequiredPresent(self: *const MenuArgumentForm) bool {
        for (self.fields) |field| {
            if (field.required and field.value.items.len == 0) return false;
        }
        return true;
    }
};

pub const MenuCompletionEffect = enum { none, repaint };

const SpawnPendingReloadFn = *const fn (*PendingReload) anyerror!std.Thread;

fn spawnPendingReload(pending: *PendingReload) !std.Thread {
    if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
    return std.Thread.spawn(.{}, PendingReload.run, .{pending});
}

fn deinitAuthenticationResult(result: anyerror!mcp_auth.AuthenticationResult) void {
    var owned = result catch return;
    owned.deinit();
}

/// Owns the native profile MCP runtime. All transport work and retirement happen
/// after releasing this state lock; the lock protects only pointer publication.
pub const State = struct {
    lock: std.Io.RwLock = .init,
    runtime: ?*mcp_runtime.McpRuntime = null,
    pending_reload: ?*PendingReload = null,
    pending_authentication: ?*PendingAuthentication = null,
    pending_menu_operation: ?*PendingMenuOperation = null,
    last_reload_completion_origin: PresentationOrigin = .command,
    last_authentication_completion_origin: PresentationOrigin = .command,
    project_prompts_suppressed: bool = false,
    menu: mcp_menu_state.State = .{},
    menu_health: ?mcp_health.Snapshot = null,
    menu_tools: ?[][]u8 = null,
    menu_resources: ?MenuResourceCatalog = null,
    menu_prompts: ?mcp_runtime.PromptCatalogResult = null,
    menu_preview: ?MenuPreview = null,
    menu_feedback: ?[]u8 = null,
    menu_add_form: MenuAddForm = .{},
    menu_argument_form: MenuArgumentForm = .{},

    pub const MenuView = struct {
        state: mcp_menu_state.State,
        health: ?*const mcp_health.Snapshot,
        tools: []const []const u8,
        resources: ?*const MenuResourceCatalog,
        prompts: ?*const mcp_runtime.PromptCatalogResult,
        preview: ?[]const u8,
        insert: ?[]const u8,
        feedback: ?[]const u8,
        add_form: *const MenuAddForm,
        argument_fields: []const MenuArgumentField,
    };

    pub fn menuView(self: *const State) MenuView {
        return .{
            .state = self.menu,
            .health = if (self.menu_health) |*snapshot| snapshot else null,
            .tools = self.menu_tools orelse &.{},
            .resources = if (self.menu_resources) |*catalog| catalog else null,
            .prompts = if (self.menu_prompts) |*catalog| catalog else null,
            .preview = if (self.menu_preview) |preview| preview.display else null,
            .insert = if (self.menu_preview) |preview| preview.insert else null,
            .feedback = self.menu_feedback,
            .add_form = &self.menu_add_form,
            .argument_fields = self.menu_argument_form.fields,
        };
    }

    pub fn openMenu(self: *State, alloc: Allocator, captured_at_ms: u64) !void {
        debug_trace.logf("mcp", "opening MCP menu", .{});
        self.clearMenuOwned(alloc);
        var snapshot = if (self.acquire()) |lease_value| snapshot: {
            var lease = lease_value;
            defer lease.deinit();
            break :snapshot try lease.runtime.snapshotHealth(alloc, captured_at_ms);
        } else try emptyHealthSnapshot(alloc, captured_at_ms);
        errdefer snapshot.deinit(alloc);
        self.menu_health = snapshot;
        self.menu = .{};
        _ = mcp_menu_state.apply(&self.menu, .{ .open = snapshot.servers.len });
    }

    pub fn refreshMenuHealth(self: *State, alloc: Allocator, captured_at_ms: u64) !bool {
        if (!self.menu.active) return false;
        if (self.menu_health) |current| {
            if (captured_at_ms >= current.captured_at_ms and captured_at_ms - current.captured_at_ms < 100) return false;
        }
        const snapshot = if (self.acquire()) |lease_value| snapshot: {
            var lease = lease_value;
            defer lease.deinit();
            break :snapshot try lease.runtime.snapshotHealth(alloc, captured_at_ms);
        } else try emptyHealthSnapshot(alloc, captured_at_ms);
        return self.replaceMenuHealth(alloc, snapshot);
    }

    fn replaceMenuHealth(self: *State, alloc: Allocator, next: mcp_health.Snapshot) bool {
        if (self.menu_health) |*current| {
            if (mcp_health.sameState(current.*, next)) {
                current.captured_at_ms = next.captured_at_ms;
                var unchanged = next;
                unchanged.deinit(alloc);
                return false;
            }
            if (self.menu.selected_server_index < current.servers.len) {
                const previous = &current.servers[self.menu.selected_server_index];
                const selected = for (next.servers, 0..) |server, index| {
                    if (server.source == previous.source and server.scope == previous.scope and
                        std.mem.eql(u8, server.identity(), previous.identity())) break index;
                } else null;
                self.menu.selected_server_index = selected orelse 0;
                if (self.menu.section == .servers) self.menu.selected_index = self.menu.selected_server_index;
                if (selected == null) {
                    self.cancelPendingMenuOperation("selected_server_removed");
                    debug_trace.logf("mcp", "closing server-bound menu state because its selected server was removed", .{});
                    self.menu.pending_generation = null;
                    if (self.menu.screen != .add) {
                        self.menu.screen = .browse;
                        self.menu.section = .servers;
                        self.menu.selected_index = self.menu.selected_server_index;
                        self.menu.load_state = .ready;
                    }
                }
            }
            current.deinit(alloc);
        }
        self.menu_health = next;
        return true;
    }

    fn emptyHealthSnapshot(alloc: Allocator, captured_at_ms: u64) !mcp_health.Snapshot {
        const servers = try alloc.alloc(mcp_health.ServerSnapshot, 0);
        errdefer alloc.free(servers);
        const configuration_issues = try alloc.alloc(mcp_health.ConfigurationIssue, 0);
        return .{
            .captured_at_ms = captured_at_ms,
            .servers = servers,
            .configuration_issues = configuration_issues,
        };
    }

    pub fn closeMenu(self: *State, alloc: Allocator) void {
        debug_trace.logf("mcp", "closing MCP menu screen={s}", .{@tagName(self.menu.screen)});
        if (mcp_menu_state.apply(&self.menu, .close)) |effect| switch (effect) {
            .cancel => self.cancelPendingMenuOperation("menu_closed"),
            .load_catalog, .load_preview, .complete_argument, .action => {},
        };
        self.clearMenuOwned(alloc);
        self.menu = .{};
    }

    fn clearMenuOwned(self: *State, alloc: Allocator) void {
        if (self.menu_health) |*snapshot| snapshot.deinit(alloc);
        self.menu_health = null;
        if (self.menu_tools) |items| {
            for (items) |item| alloc.free(item);
            alloc.free(items);
        }
        self.menu_tools = null;
        if (self.menu_resources) |*catalog| catalog.deinit(alloc);
        self.menu_resources = null;
        if (self.menu_prompts) |*catalog| catalog.deinit(alloc);
        self.menu_prompts = null;
        if (self.menu_preview) |*preview| preview.deinit(alloc);
        self.menu_preview = null;
        if (self.menu_feedback) |feedback| alloc.free(feedback);
        self.menu_feedback = null;
        self.menu_add_form.deinit(alloc);
        self.menu_argument_form.deinit(alloc);
    }

    pub fn setMenuAddField(
        self: *State,
        alloc: Allocator,
        field_index: usize,
        value: []const u8,
    ) !void {
        try self.menu_add_form.set(alloc, field_index, value);
    }

    pub fn menuAddFieldValue(self: *const State, field_index: usize) []const u8 {
        return self.menu_add_form.value(field_index);
    }

    pub fn setMenuFeedback(self: *State, alloc: Allocator, text: []const u8) !void {
        const owned = try alloc.dupe(u8, text);
        if (self.menu_feedback) |previous| alloc.free(previous);
        self.menu_feedback = owned;
    }

    pub fn prepareMenuArguments(self: *State, alloc: Allocator) !bool {
        var fields: std.ArrayList(MenuArgumentField) = .empty;
        defer fields.deinit(alloc);
        errdefer for (fields.items) |*field| field.deinit(alloc);
        switch (self.menu.section) {
            .servers, .tools => return false,
            .resources => {
                const catalog = self.menu_resources orelse return false;
                const item = catalog.filteredItem(
                    self.menu.selected_index,
                    self.menu.queryText(),
                ) orelse return false;
                if (!item.is_template) return false;
                try appendTemplateArgumentFields(alloc, &fields, item.uri);
            },
            .prompts => {
                const prompt = self.selectedMenuPrompt() orelse return false;
                for (prompt.arguments) |argument| {
                    try appendMenuArgumentField(
                        alloc,
                        &fields,
                        argument.name,
                        argument.required,
                    );
                }
            },
        }
        if (fields.items.len == 0) return false;
        const owned = try fields.toOwnedSlice(alloc);
        self.menu_argument_form.deinit(alloc);
        self.menu_argument_form.fields = owned;
        _ = mcp_menu_state.apply(&self.menu, .{ .show_arguments = owned.len });
        return true;
    }

    pub fn setMenuArgumentField(
        self: *State,
        alloc: Allocator,
        field_index: usize,
        value: []const u8,
    ) !void {
        try self.menu_argument_form.set(alloc, field_index, value);
    }

    pub fn menuArgumentsValid(self: *const State) bool {
        return self.menu_argument_form.allRequiredPresent();
    }

    fn selectedMenuPrompt(self: *const State) ?*const mcp_runtime.PromptSummary {
        const catalog = self.menu_prompts orelse return null;
        var matched: usize = 0;
        const query = self.menu.queryText();
        for (catalog.items) |*item| {
            if (!menuPromptMatches(item.*, query)) continue;
            if (matched == self.menu.selected_index) return item;
            matched += 1;
        }
        return null;
    }

    pub fn returnMenuToServers(self: *State) void {
        self.menu.section = .servers;
        self.menu.screen = .browse;
        self.menu.selected_index = self.menu.selected_server_index;
        self.menu.window_start = 0;
        self.menu.confirmation_action = null;
        self.menu.filter_active = false;
        self.menu.query_len = 0;
    }

    pub fn beginMenuEffect(
        self: *State,
        alloc: Allocator,
        effect: mcp_menu_state.Effect,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
    ) !void {
        var action: ?mcp_menu_state.Action = null;
        const operation: MenuOperation = switch (effect) {
            .load_catalog => |request| .{ .kind = MenuOperationKind.catalog, .request = request },
            .load_preview => |request| .{ .kind = MenuOperationKind.preview, .request = request },
            .complete_argument => |request| .{
                .kind = MenuOperationKind.completion,
                .request = request,
            },
            .action => |request| action_operation: {
                if (request.action != .logout) return error.McpMenuInvalidOperation;
                action = request.action;
                break :action_operation .{
                    .kind = .action,
                    .request = .{
                        .generation = request.generation,
                        .section = self.menu.section,
                        .server_index = self.menu.selected_server_index,
                        .selected_index = request.selected_index,
                    },
                };
            },
            .cancel => return error.McpMenuInvalidOperation,
        };
        self.cancelPendingMenuOperation("superseded");
        if (self.menu_feedback) |feedback| alloc.free(feedback);
        self.menu_feedback = null;

        if (operation.kind == .catalog and
            (operation.request.section == .resources or operation.request.section == .prompts))
        {
            const health = self.menu_health orelse {
                self.completeEmptyMenuCatalog(alloc, operation.request);
                return;
            };
            if (operation.request.server_index >= health.servers.len) {
                self.completeEmptyMenuCatalog(alloc, operation.request);
                return;
            }
        }
        var lease = self.acquire() orelse {
            if (operation.kind == .catalog) {
                self.completeEmptyMenuCatalog(alloc, operation.request);
                return;
            }
            return error.McpRuntimeUnavailable;
        };
        var lease_owned = true;
        errdefer if (lease_owned) lease.deinit();
        const owned_rules = try types.dupePermissionRuleSet(alloc, permission_rules);
        var rules_owned = true;
        errdefer if (rules_owned) types.freePermissionRuleSlice(alloc, owned_rules.rules);

        var server_name: ?[]u8 = null;
        var identity: ?[]u8 = null;
        var arguments: []OwnedMenuArgument = &.{};
        var resource_template = false;
        errdefer {
            if (server_name) |value| alloc.free(value);
            if (identity) |value| alloc.free(value);
            for (arguments) |*argument| argument.deinit(alloc);
            if (arguments.len > 0) alloc.free(arguments);
        }
        if (operation.kind == .action or
            operation.request.section == .resources or
            operation.request.section == .prompts)
        {
            const health = self.menu_health orelse return error.McpRuntimeUnavailable;
            if (operation.request.server_index >= health.servers.len) return error.McpServerNotFound;
            if (health.servers[operation.request.server_index].runtime_generation != lease.runtime.generation) {
                return error.McpMenuSelectionChanged;
            }
            server_name = try alloc.dupe(
                u8,
                health.servers[operation.request.server_index].identity(),
            );
        }
        if (operation.kind == .preview or operation.kind == .completion) switch (operation.request.section) {
            .servers => return error.McpMenuInvalidOperation,
            .tools => {
                const tools = self.menu_tools orelse return error.McpToolNotFound;
                const query = self.menu.queryText();
                var matched: usize = 0;
                const selected = for (tools) |tool| {
                    if (!mcp_menu_state.textMatchesQuery(tool, query)) continue;
                    if (matched == operation.request.selected_index) break tool;
                    matched += 1;
                } else return error.McpToolNotFound;
                identity = try alloc.dupe(u8, selected);
            },
            .resources => {
                const catalog = self.menu_resources orelse return error.McpResourceNotFound;
                const item = catalog.filteredItem(
                    operation.request.selected_index,
                    self.menu.queryText(),
                ) orelse
                    return error.McpResourceNotFound;
                identity = try alloc.dupe(u8, item.uri);
                resource_template = item.is_template;
            },
            .prompts => {
                const catalog = self.menu_prompts orelse return error.McpPromptNotFound;
                const query = self.menu.queryText();
                var matched: usize = 0;
                const prompt = for (catalog.items) |item| {
                    if (!menuPromptMatches(item, query)) continue;
                    if (matched == operation.request.selected_index) break item;
                    matched += 1;
                } else return error.McpPromptNotFound;
                identity = try alloc.dupe(u8, prompt.name);
            },
        };
        if (operation.kind == .preview or operation.kind == .completion) {
            arguments = try cloneMenuArguments(alloc, self.menu_argument_form.fields);
        }

        const pending = try alloc.create(PendingMenuOperation);
        pending.* = .{
            .alloc = alloc,
            .request = operation.request,
            .kind = operation.kind,
            .lease = lease,
            .permission_rules = owned_rules,
            .limits = limits,
            .server_name = server_name,
            .identity = identity,
            .arguments = arguments,
            .argument_index = self.menu.argument_index,
            .resource_template = resource_template,
            .action = action,
            .started_at_ms = io_mod.milliTimestamp(),
        };
        lease_owned = false;
        rules_owned = false;
        server_name = null;
        identity = null;
        arguments = &.{};

        self.lock.lockUncancelable(io_mod.getIo());
        std.debug.assert(self.pending_menu_operation == null);
        self.pending_menu_operation = pending;
        self.lock.unlock(io_mod.getIo());
        if (comptime builtin.single_threaded) {
            pending.run();
        } else {
            pending.thread = spawnPendingMenuOperation(pending) catch |err| {
                self.lock.lockUncancelable(io_mod.getIo());
                if (self.pending_menu_operation == pending) self.pending_menu_operation = null;
                self.lock.unlock(io_mod.getIo());
                pending.deinit();
                return err;
            };
        }
    }

    fn completeEmptyMenuCatalog(
        self: *State,
        alloc: Allocator,
        request: mcp_menu_state.Request,
    ) void {
        switch (request.section) {
            .servers => {},
            .tools => {
                if (self.menu_tools) |items| {
                    for (items) |item| alloc.free(item);
                    alloc.free(items);
                }
                self.menu_tools = null;
            },
            .resources => {
                if (self.menu_resources) |*catalog| catalog.deinit(alloc);
                self.menu_resources = null;
            },
            .prompts => {
                if (self.menu_prompts) |*catalog| catalog.deinit(alloc);
                self.menu_prompts = null;
            },
        }
        if (self.menu_feedback) |feedback| alloc.free(feedback);
        self.menu_feedback = null;
        _ = mcp_menu_state.apply(&self.menu, .{ .catalog_loaded = .{
            .generation = request.generation,
            .item_count = 0,
        } });
    }

    pub noinline fn collectMenuCompletion(self: *State, alloc: Allocator) !MenuCompletionEffect {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_menu_operation orelse {
            self.lock.unlock(io_mod.getIo());
            return .none;
        };
        if (!pending.done.load(.acquire)) {
            const now_ms = io_mod.milliTimestamp();
            const reveal_loading = pending.kind == .catalog and
                !pending.catalog_loading_visible and
                now_ms >= pending.started_at_ms and
                now_ms - pending.started_at_ms >= menu_catalog_loading_grace_ms;
            if (reveal_loading) pending.catalog_loading_visible = true;
            self.lock.unlock(io_mod.getIo());
            return if (reveal_loading) .repaint else .none;
        }
        self.pending_menu_operation = null;
        self.lock.unlock(io_mod.getIo());

        pending.join();
        const request = pending.request;
        const kind = pending.kind;
        var result = pending.result.?;
        pending.result = null;
        pending.deinit();
        defer result.deinit(alloc);
        if (!self.menu.active or self.menu.pending_generation != request.generation) {
            debug_trace.logf(
                "mcp",
                "discarding menu completion generation={d} active={s} pending_generation={any}",
                .{ request.generation, if (self.menu.active) "true" else "false", self.menu.pending_generation },
            );
            return .none;
        }

        if (self.menu_feedback) |feedback| alloc.free(feedback);
        self.menu_feedback = null;
        switch (result) {
            .tools => |items| {
                if (self.menu_tools) |previous| {
                    for (previous) |item| alloc.free(item);
                    alloc.free(previous);
                }
                self.menu_tools = items;
                result = .cancelled;
                _ = mcp_menu_state.apply(&self.menu, .{ .catalog_loaded = .{
                    .generation = request.generation,
                    .item_count = items.len,
                } });
            },
            .resources => |catalog| {
                if (self.menu_resources) |*previous| previous.deinit(alloc);
                const count = catalog.count();
                self.menu_resources = catalog;
                result = .cancelled;
                _ = mcp_menu_state.apply(&self.menu, .{ .catalog_loaded = .{
                    .generation = request.generation,
                    .item_count = count,
                } });
            },
            .prompts => |catalog| {
                if (self.menu_prompts) |*previous| previous.deinit(alloc);
                const count = catalog.items.len;
                self.menu_prompts = catalog;
                result = .cancelled;
                _ = mcp_menu_state.apply(&self.menu, .{ .catalog_loaded = .{
                    .generation = request.generation,
                    .item_count = count,
                } });
            },
            .preview => |preview| {
                if (self.menu_preview) |*previous| previous.deinit(alloc);
                self.menu_preview = preview;
                result = .cancelled;
                _ = mcp_menu_state.apply(
                    &self.menu,
                    .{ .preview_loaded = request.generation },
                );
            },
            .completion => |completion| {
                try self.menu_argument_form.set(
                    alloc,
                    completion.field_index,
                    completion.value,
                );
                _ = mcp_menu_state.apply(
                    &self.menu,
                    .{ .completion_loaded = request.generation },
                );
            },
            .action => |action_result| {
                self.menu_feedback = action_result.feedback;
                result = .cancelled;
                self.returnMenuToServers();
                _ = mcp_menu_state.apply(
                    &self.menu,
                    .{ .action_succeeded = request.generation },
                );
            },
            .failed => |err| {
                if (kind == .catalog and (err == error.McpResourcesUnsupported or err == error.McpPromptsUnsupported)) {
                    self.completeEmptyMenuCatalog(alloc, request);
                    return .repaint;
                }
                self.menu_feedback = try allocMenuText(
                    alloc,
                    &.{
                        "MCP ",
                        switch (kind) {
                            .catalog => "catalog",
                            .preview => "preview",
                            .completion => "completion",
                            .action => "action",
                        },
                        " failed: ",
                        @errorName(err),
                    },
                );
                _ = mcp_menu_state.apply(
                    &self.menu,
                    .{ .effect_failed = request.generation },
                );
            },
            .cancelled => {
                _ = mcp_menu_state.apply(
                    &self.menu,
                    .{ .effect_cancelled = request.generation },
                );
            },
        }
        return .repaint;
    }

    pub fn recordMenuEffectFailure(
        self: *State,
        alloc: Allocator,
        generation: u64,
        err: anyerror,
    ) !void {
        if (!self.menu.active or self.menu.pending_generation != generation) return;
        if (self.menu_feedback) |feedback| alloc.free(feedback);
        self.menu_feedback = try allocMenuText(
            alloc,
            &.{ "MCP operation failed: ", @errorName(err) },
        );
        _ = mcp_menu_state.apply(&self.menu, .{ .effect_failed = generation });
    }

    pub fn applyMenuReloadCompletion(
        self: *State,
        alloc: Allocator,
        generation: u64,
        completion: *const ReloadCompletion,
        captured_at_ms: u64,
    ) !void {
        if (!self.menu.active or self.menu.pending_generation != generation) return;
        if (self.menu_feedback) |feedback| alloc.free(feedback);
        self.menu_feedback = switch (completion.*) {
            .outcome => |outcome| switch (outcome) {
                .published => |published| if (published.health == .ready)
                    try alloc.dupe(u8, "MCP configuration reloaded.")
                else
                    try std.fmt.allocPrint(
                        alloc,
                        "MCP reloaded with {d} unavailable server{s}.",
                        .{
                            published.unavailable_server_names.len,
                            if (published.unavailable_server_names.len == 1) "" else "s",
                        },
                    ),
                .retained_required_failure => try alloc.dupe(
                    u8,
                    "MCP reload failed; the previous runtime remains active.",
                ),
            },
            .failed => |err| try allocMenuText(
                alloc,
                &.{ "MCP reload failed: ", @errorName(err) },
            ),
        };
        const completion_event: mcp_menu_state.Event = switch (completion.*) {
            .outcome => |outcome| switch (outcome) {
                .published => .{ .action_succeeded = generation },
                .retained_required_failure => .{ .effect_failed = generation },
            },
            .failed => .{ .effect_failed = generation },
        };
        _ = mcp_menu_state.apply(&self.menu, completion_event);

        var snapshot = if (self.acquire()) |lease_value| snapshot: {
            var lease = lease_value;
            defer lease.deinit();
            break :snapshot try lease.runtime.snapshotHealth(alloc, captured_at_ms);
        } else try emptyHealthSnapshot(alloc, captured_at_ms);
        errdefer snapshot.deinit(alloc);
        _ = self.replaceMenuHealth(alloc, snapshot);
    }

    pub fn selectedMenuServerName(self: *const State) ?[]const u8 {
        const health = self.menu_health orelse return null;
        if (self.menu.selected_server_index >= health.servers.len) return null;
        return health.servers[self.menu.selected_server_index].identity();
    }

    pub fn applyMenuAuthenticationCompletion(
        self: *State,
        alloc: Allocator,
        generation: u64,
        completion: *const AuthenticationCompletion,
    ) !bool {
        if (!self.menu.active or self.menu.pending_generation != generation) return false;
        if (self.menu_feedback) |feedback| alloc.free(feedback);
        self.menu_feedback = null;
        if (completion.result) |authentication| {
            switch (authentication) {
                .authenticated => |authenticated| {
                    self.menu_feedback = if (authenticated.repaired_entries == 0)
                        try allocMenuText(
                            alloc,
                            &.{
                                "Authenticated MCP server '",
                                completion.server_name,
                                "'.",
                            },
                        )
                    else
                        try std.fmt.allocPrint(
                            alloc,
                            "Authenticated '{s}'; repaired {d} credential entries.",
                            .{ completion.server_name, authenticated.repaired_entries },
                        );
                    if (completion.reconnect_error) |err| {
                        const feedback = try std.fmt.allocPrint(alloc, "{s} Connection failed: {s}. Check /mcp list.", .{ self.menu_feedback.?, @errorName(err) });
                        alloc.free(self.menu_feedback.?);
                        self.menu_feedback = feedback;
                        _ = mcp_menu_state.apply(&self.menu, .{ .effect_failed = generation });
                    } else {
                        _ = mcp_menu_state.apply(&self.menu, .{ .action_succeeded = generation });
                    }
                    if (self.acquire()) |lease_value| {
                        var lease = lease_value;
                        defer lease.deinit();
                        const snapshot = try lease.runtime.snapshotHealth(alloc, @intCast(@max(io_mod.milliTimestamp(), 0)));
                        _ = self.replaceMenuHealth(alloc, snapshot);
                    }
                    return true;
                },
                .issuer_mismatch => {
                    self.menu_feedback = try allocMenuText(
                        alloc,
                        &.{
                            "MCP authentication for '",
                            completion.server_name,
                            "' rejected an issuer mismatch.",
                        },
                    );
                },
            }
        } else |err| {
            self.menu_feedback = try allocMenuText(
                alloc,
                &.{
                    "MCP authentication for '",
                    completion.server_name,
                    "' failed: ",
                    @errorName(err),
                },
            );
        }
        _ = mcp_menu_state.apply(&self.menu, .{ .effect_failed = generation });
        return false;
    }

    fn cancelPendingMenuOperation(self: *State, reason: []const u8) void {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_menu_operation;
        self.pending_menu_operation = null;
        if (pending) |task| task.cancel_requested.store(true, .release);
        self.lock.unlock(io_mod.getIo());
        if (pending) |task| {
            debug_trace.logf(
                "mcp",
                "discarding pending menu operation generation={d} reason={s}",
                .{ task.request.generation, reason },
            );
            task.deinit();
        }
    }

    pub fn cancelMenuOperation(self: *State) void {
        self.cancelPendingMenuOperation("menu_back");
    }

    pub fn installInitial(self: *State, runtime: ?*mcp_runtime.McpRuntime) void {
        std.debug.assert(self.runtime == null);
        self.runtime = runtime;
    }

    pub fn projectPromptActive(self: *State) bool {
        var lease = self.acquireProjectPromptRuntime() orelse return false;
        defer lease.deinit();
        return lease.runtime.hasPendingWorkspace();
    }

    pub fn projectPromptName(self: *State, alloc: Allocator) !?[]u8 {
        var lease = self.acquireProjectPromptRuntime() orelse return null;
        defer lease.deinit();
        return lease.runtime.firstPendingWorkspaceName(alloc);
    }

    pub fn projectPromptDisplayName(self: *State, alloc: Allocator) !?[]u8 {
        const name = (try self.projectPromptName(alloc)) orelse return null;
        defer alloc.free(name);
        const encoded = try text_utils.encodeTerminalSafe(alloc, name, 256);
        return @as(?[]u8, encoded.bytes);
    }

    pub fn suppressProjectPrompts(self: *State) void {
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        self.project_prompts_suppressed = true;
        debug_trace.logf("mcp", "project MCP approval prompts suppressed for process", .{});
    }

    fn acquireProjectPromptRuntime(self: *State) ?Lease {
        self.lock.lockSharedUncancelable(io_mod.getIo());
        defer self.lock.unlockShared(io_mod.getIo());
        if (self.project_prompts_suppressed or self.pending_reload != null) {
            return null;
        }
        const runtime = self.runtime orelse return null;
        if (!runtime.acquireUse()) return null;
        return .{ .runtime = runtime };
    }

    pub fn startDiscovery(self: *State, registry: tool_dispatch.Registry) void {
        var lease = self.acquire() orelse return;
        defer lease.deinit();
        lease.runtime.startDiscovery(registry);
    }

    pub fn acquire(self: *State) ?Lease {
        self.lock.lockSharedUncancelable(io_mod.getIo());
        const runtime = self.runtime orelse {
            self.lock.unlockShared(io_mod.getIo());
            return null;
        };
        if (!runtime.acquireUse()) {
            self.lock.unlockShared(io_mod.getIo());
            return null;
        }
        self.lock.unlockShared(io_mod.getIo());
        return .{ .runtime = runtime };
    }

    pub fn hasTool(self: *State, name: []const u8, access: tool_mcp_runtime.Access) bool {
        var lease = self.acquire() orelse return false;
        defer lease.deinit();
        return lease.runtime.hasToolWithAccess(name, access);
    }

    pub fn validateTool(
        self: *State,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.ValidationResult {
        var lease = self.acquire() orelse return .not_available;
        defer lease.deinit();
        return lease.runtime.validateToolArgumentsByNameWithAccess(
            arena,
            name,
            arguments_json,
            access,
        );
    }

    pub fn callTool(
        self: *State,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        var lease = self.acquire() orelse return null;
        defer lease.deinit();
        return lease.runtime.callToolByNameWithOptions(
            arena,
            name,
            arguments_json,
            max_tool_result_bytes,
            options,
        );
    }

    pub fn searchTools(
        self: *State,
        arena: Allocator,
        request: tool_mcp_runtime.SearchRequest,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !tool_mcp_runtime.SearchResult {
        var lease = self.acquire() orelse
            return .{ .model_output = try arena.dupe(u8, "{\"tools\":[],\"count\":0}") };
        defer lease.deinit();
        return lease.runtime.searchToolsPrepared(arena, request, permission_rules, limits, access, cancel_flag);
    }

    pub fn toolSchema(
        self: *State,
        arena: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !?tool_mcp_runtime.ToolSchemaResult {
        var lease = self.acquire() orelse return null;
        defer lease.deinit();
        return lease.runtime.toolSchemaJsonByNameWithAccess(
            arena,
            name,
            permission_rules,
            limits,
            access,
            cancel_flag,
        );
    }

    pub fn renderHealth(self: *State, alloc: Allocator) ![]u8 {
        var lease = self.acquire() orelse return alloc.dupe(u8, "No MCP servers configured.\n");
        defer lease.deinit();
        return lease.runtime.listServersAndTools(alloc);
    }

    pub fn renderHealthSummary(self: *State, alloc: Allocator) ![]u8 {
        var lease = self.acquire() orelse return mcp_health.renderSummary(
            alloc,
            .{ .captured_at_ms = 0, .servers = &.{} },
        );
        defer lease.deinit();
        var snapshot = try lease.runtime.snapshotHealth(
            alloc,
            @intCast(@max(io_mod.milliTimestamp(), 0)),
        );
        defer snapshot.deinit(alloc);
        return mcp_health.renderSummary(alloc, snapshot);
    }

    pub fn snapshotToolDefinition(self: *State, alloc: Allocator, name: []const u8, known: tool_mcp_runtime.Binding, permission_rules: types.PermissionRuleSet, limits: context_limits.Values, access: tool_mcp_runtime.Access) !tool_mcp_runtime.DefinitionSnapshot {
        var lease = self.acquire() orelse return .unavailable;
        defer lease.deinit();
        return lease.runtime.snapshotToolDefinition(alloc, name, known, permission_rules, limits, access);
    }

    pub fn snapshotToolNames(
        self: *State,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
    ) ![][]u8 {
        var lease = self.acquire() orelse return alloc.alloc([]u8, 0);
        defer lease.deinit();
        return lease.runtime.snapshotToolNames(alloc, permission_rules);
    }

    pub fn snapshotAccessView(
        self: *State,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
        permission_rules: types.PermissionRuleSet,
        features_visible: bool,
    ) !?mcp_access.View {
        var lease = self.acquire() orelse return null;
        defer lease.deinit();
        const view = try lease.runtime.snapshotAccessView(
            alloc,
            owner_id,
            parent_id,
            permission_rules,
            features_visible,
        );
        return view;
    }

    pub fn snapshotModelCatalog(
        self: *State,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
        include_ask_deferred: bool,
    ) !mcp_model_catalog.Snapshot {
        var lease = self.acquire() orelse return mcp_model_catalog.Snapshot.empty(alloc);
        defer lease.deinit();
        return lease.runtime.snapshotModelCatalog(
            alloc,
            permission_rules,
            include_ask_deferred,
        );
    }

    pub fn waitForRequired(
        self: *State,
        alloc: Allocator,
        cancel_flag: ?*std.atomic.Value(bool),
        captured_at_ms: u64,
    ) !?[]u8 {
        var lease = self.acquire() orelse return null;
        defer lease.deinit();
        try lease.runtime.waitForRequiredDiscovery(cancel_flag);
        return lease.runtime.requiredStartupFailure(alloc, captured_at_ms);
    }

    pub fn startAuthentication(
        self: *State,
        alloc: Allocator,
        server_name: []const u8,
        opener: host.UrlOpener,
    ) !mcp_command_provider.AuthenticationStart {
        return self.startAuthenticationWithOrigin(
            alloc,
            server_name,
            opener,
            .command,
        );
    }

    pub fn startMenuAuthentication(
        self: *State,
        alloc: Allocator,
        server_name: []const u8,
        opener: host.UrlOpener,
        generation: u64,
    ) !mcp_command_provider.AuthenticationStart {
        return self.startAuthenticationWithOrigin(
            alloc,
            server_name,
            opener,
            .{ .menu = generation },
        );
    }

    fn startAuthenticationWithOrigin(
        self: *State,
        alloc: Allocator,
        server_name: []const u8,
        opener: host.UrlOpener,
        presentation_origin: PresentationOrigin,
    ) !mcp_command_provider.AuthenticationStart {
        const pending = try alloc.create(PendingAuthentication);
        var pending_owned = true;
        errdefer if (pending_owned) alloc.destroy(pending);
        const owned_name = try alloc.dupe(u8, server_name);
        var name_owned = true;
        errdefer if (name_owned) alloc.free(owned_name);

        self.lock.lockUncancelable(io_mod.getIo());
        if (self.pending_authentication != null or self.pending_reload != null) {
            self.lock.unlock(io_mod.getIo());
            alloc.free(owned_name);
            alloc.destroy(pending);
            return .busy;
        }
        const runtime = self.runtime orelse {
            self.lock.unlock(io_mod.getIo());
            return error.McpServerNotFound;
        };
        if (!runtime.acquireUse()) {
            self.lock.unlock(io_mod.getIo());
            return error.McpServerNotFound;
        }
        runtime.validateAuthenticationServer(server_name) catch |err| {
            runtime.releaseUse();
            self.lock.unlock(io_mod.getIo());
            return err;
        };
        pending.* = .{
            .alloc = alloc,
            .server_name = owned_name,
            .lease = .{ .runtime = runtime },
            .opener = opener,
            .presentation_origin = presentation_origin,
        };
        pending_owned = false;
        name_owned = false;
        self.pending_authentication = pending;
        self.lock.unlock(io_mod.getIo());

        if (comptime builtin.single_threaded) {
            pending.run();
        } else {
            pending.thread = std.Thread.spawn(.{}, PendingAuthentication.run, .{pending}) catch |err| {
                self.lock.lockUncancelable(io_mod.getIo());
                if (self.pending_authentication == pending) self.pending_authentication = null;
                self.lock.unlock(io_mod.getIo());
                pending.deinit();
                return err;
            };
        }
        return .started;
    }

    pub fn takeAuthenticationCompletion(self: *State) ?AuthenticationCompletion {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_authentication orelse {
            self.lock.unlock(io_mod.getIo());
            return null;
        };
        if (!pending.done.load(.acquire)) {
            self.lock.unlock(io_mod.getIo());
            return null;
        }
        self.pending_authentication = null;
        self.lock.unlock(io_mod.getIo());

        pending.join();
        self.last_authentication_completion_origin = pending.presentation_origin;
        const result = pending.result.?;
        pending.result = null;
        const server_name = pending.server_name;
        const reconnect_error = pending.reconnect_error;
        pending.lease.deinit();
        pending.alloc.destroy(pending);
        return .{
            .reconnect_error = reconnect_error,
            .server_name = server_name,
            .result = result,
        };
    }

    pub fn authenticationCompletionOrigin(self: *const State) PresentationOrigin {
        return self.last_authentication_completion_origin;
    }

    pub fn authenticationPending(self: *State, server_name: []const u8) bool {
        self.lock.lockSharedUncancelable(io_mod.getIo());
        defer self.lock.unlockShared(io_mod.getIo());
        const pending = self.pending_authentication orelse return false;
        return std.mem.eql(u8, pending.server_name, server_name);
    }

    pub fn reload(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        preview_workspace_authority: mcp_runtime.PreviewNativeWorkspaceAuthorityFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
    ) !ReloadOutcome {
        var cancel_requested = std.atomic.Value(bool).init(false);
        return self.reloadControlled(
            alloc,
            workspace_root,
            elicitation_capabilities,
            loader,
            preview_workspace_authority,
            registry,
            captured_at_ms,
            &cancel_requested,
            null,
        );
    }

    pub fn beginReload(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        preview_workspace_authority: mcp_runtime.PreviewNativeWorkspaceAuthorityFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
    ) !void {
        return self.beginReloadWithOriginAndSpawner(
            alloc,
            workspace_root,
            elicitation_capabilities,
            loader,
            preview_workspace_authority,
            registry,
            captured_at_ms,
            .command,
            spawnPendingReload,
        );
    }

    pub fn beginMenuReload(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        preview_workspace_authority: mcp_runtime.PreviewNativeWorkspaceAuthorityFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        generation: u64,
    ) !void {
        return self.beginReloadWithOriginAndSpawner(
            alloc,
            workspace_root,
            elicitation_capabilities,
            loader,
            preview_workspace_authority,
            registry,
            captured_at_ms,
            .{ .menu = generation },
            spawnPendingReload,
        );
    }

    fn beginReloadWithSpawner(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        preview_workspace_authority: mcp_runtime.PreviewNativeWorkspaceAuthorityFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        spawn_reload: SpawnPendingReloadFn,
    ) !void {
        return self.beginReloadWithOriginAndSpawner(
            alloc,
            workspace_root,
            elicitation_capabilities,
            loader,
            preview_workspace_authority,
            registry,
            captured_at_ms,
            .command,
            spawn_reload,
        );
    }

    fn beginReloadWithOriginAndSpawner(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        preview_workspace_authority: mcp_runtime.PreviewNativeWorkspaceAuthorityFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        presentation_origin: PresentationOrigin,
        spawn_reload: SpawnPendingReloadFn,
    ) !void {
        self.cancelPendingAuthentication("reload");
        self.cancelPendingReload();

        const pending = try alloc.create(PendingReload);
        const owned_workspace_root = alloc.dupe(u8, workspace_root) catch |err| {
            alloc.destroy(pending);
            return err;
        };
        pending.* = .{
            .owner = self,
            .alloc = alloc,
            .workspace_root = owned_workspace_root,
            .elicitation_capabilities = elicitation_capabilities,
            .loader = loader,
            .preview_workspace_authority = preview_workspace_authority,
            .registry = registry,
            .captured_at_ms = captured_at_ms,
            .presentation_origin = presentation_origin,
        };
        self.lock.lockUncancelable(io_mod.getIo());
        std.debug.assert(self.pending_reload == null);
        const authentication = self.pending_authentication;
        self.pending_authentication = null;
        self.pending_reload = pending;
        self.lock.unlock(io_mod.getIo());
        if (authentication) |task| cancelAndDeinitAuthentication(task, "reload");

        if (comptime builtin.single_threaded) {
            pending.run();
        } else {
            pending.thread = spawn_reload(pending) catch |err| {
                self.lock.lockUncancelable(io_mod.getIo());
                if (self.pending_reload == pending) self.pending_reload = null;
                self.lock.unlock(io_mod.getIo());
                pending.deinit();
                return err;
            };
        }
    }

    pub fn beginAuthorityReduction(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        rebuild: bool,
    ) !void {
        return self.beginAuthorityReductionWithOriginAndSpawner(
            alloc,
            workspace_root,
            elicitation_capabilities,
            loader,
            registry,
            captured_at_ms,
            rebuild,
            .command,
            spawnPendingReload,
        );
    }

    pub fn beginMenuAuthorityReduction(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        rebuild: bool,
        generation: u64,
    ) !void {
        return self.beginAuthorityReductionWithOriginAndSpawner(
            alloc,
            workspace_root,
            elicitation_capabilities,
            loader,
            registry,
            captured_at_ms,
            rebuild,
            .{ .menu = generation },
            spawnPendingReload,
        );
    }

    fn beginAuthorityReductionWithSpawner(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        rebuild: bool,
        spawn_reload: SpawnPendingReloadFn,
    ) !void {
        return self.beginAuthorityReductionWithOriginAndSpawner(
            alloc,
            workspace_root,
            elicitation_capabilities,
            loader,
            registry,
            captured_at_ms,
            rebuild,
            .command,
            spawn_reload,
        );
    }

    fn beginAuthorityReductionWithOriginAndSpawner(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        rebuild: bool,
        presentation_origin: PresentationOrigin,
        spawn_reload: SpawnPendingReloadFn,
    ) !void {
        const pending = try alloc.create(PendingReload);
        const owned_workspace_root = alloc.dupe(u8, workspace_root) catch |err| {
            alloc.destroy(pending);
            return err;
        };
        pending.* = .{
            .owner = self,
            .alloc = alloc,
            .workspace_root = owned_workspace_root,
            .elicitation_capabilities = elicitation_capabilities,
            .loader = loader,
            .registry = registry,
            .captured_at_ms = captured_at_ms,
            .presentation_origin = presentation_origin,
            .policy = .authority_reducing,
            .rebuild = rebuild,
        };

        self.lock.lockUncancelable(io_mod.getIo());
        const superseded_reload = self.pending_reload;
        if (superseded_reload) |task| task.cancel_requested.store(true, .release);
        const superseded_authentication = self.pending_authentication;
        if (superseded_authentication) |task| task.cancel_requested.store(true, .release);
        pending.superseded_reload = superseded_reload;
        pending.superseded_authentication = superseded_authentication;
        if (self.runtime) |runtime| _ = runtime.revokeWorkspaceExceptNames(&.{});
        self.pending_reload = pending;
        self.pending_authentication = null;
        self.lock.unlock(io_mod.getIo());

        if (comptime builtin.single_threaded) {
            pending.run();
        } else {
            pending.thread = spawn_reload(pending) catch {
                pending.run();
                return;
            };
        }
    }

    pub fn retireAuthoritySynchronously(self: *State, _: Allocator) void {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending_reload = self.pending_reload;
        if (pending_reload) |task| task.cancel_requested.store(true, .release);
        const pending_authentication = self.pending_authentication;
        if (pending_authentication) |task| task.cancel_requested.store(true, .release);
        const runtime = self.runtime;
        self.pending_reload = null;
        self.pending_authentication = null;
        self.lock.unlock(io_mod.getIo());

        if (pending_authentication) |task| {
            cancelAndDeinitAuthentication(task, "authority_reduction_sync");
        }
        if (pending_reload) |task| task.deinit();
        if (runtime) |value| _ = value.revokeWorkspaceExceptNames(&.{});
    }

    pub fn takeReloadCompletion(self: *State) ?ReloadCompletion {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_reload orelse {
            self.lock.unlock(io_mod.getIo());
            return null;
        };
        if (!pending.done.load(.acquire)) {
            self.lock.unlock(io_mod.getIo());
            return null;
        }
        self.pending_reload = null;
        self.lock.unlock(io_mod.getIo());

        pending.join();
        self.last_reload_completion_origin = pending.presentation_origin;
        const result = pending.result.?;
        pending.result = null;
        pending.alloc.free(pending.workspace_root);
        pending.alloc.destroy(pending);
        return switch (result) {
            .outcome => |outcome| .{ .outcome = outcome },
            .failed => |err| .{ .failed = err },
            .cancelled => null,
        };
    }

    pub fn reloadCompletionOrigin(self: *const State) PresentationOrigin {
        return self.last_reload_completion_origin;
    }

    fn cancelPendingReload(self: *State) void {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_reload;
        if (pending) |task| task.cancel_requested.store(true, .release);
        self.pending_reload = null;
        self.lock.unlock(io_mod.getIo());
        if (pending) |task| task.deinit();
    }

    fn cancelPendingAuthentication(self: *State, reason: []const u8) void {
        self.lock.lockUncancelable(io_mod.getIo());
        const pending = self.pending_authentication;
        self.pending_authentication = null;
        self.lock.unlock(io_mod.getIo());
        if (pending) |task| cancelAndDeinitAuthentication(task, reason);
    }

    fn reloadControlled(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        preview_workspace_authority: mcp_runtime.PreviewNativeWorkspaceAuthorityFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        cancel_requested: *std.atomic.Value(bool),
        pending: ?*PendingReload,
    ) !ReloadOutcome {
        if (cancel_requested.load(.acquire)) return error.Cancelled;
        var lease = self.acquire();
        defer if (lease) |*current| current.deinit();
        const next_authority = preview_workspace_authority(alloc, workspace_root) catch |err| {
            if (lease) |current| {
                if (current.runtime.revokeWorkspaceExceptNames(&.{})) return error.McpAuthorityReducedReloadFailed;
            }
            return err;
        };
        defer mcp_contract.freeOwnedStrings(alloc, next_authority);
        const authority_reduced = if (lease) |current| current.runtime.revokeWorkspaceExceptNames(next_authority) else false;
        const candidate = loader(alloc, workspace_root, elicitation_capabilities) catch |err| {
            if (authority_reduced) return error.McpAuthorityReducedReloadFailed;
            return err;
        };
        return self.applyReloadCandidate(alloc, candidate, registry, captured_at_ms, cancel_requested, pending, !authority_reduced, true);
    }

    fn reloadAuthorityReducedControlled(
        self: *State,
        alloc: Allocator,
        workspace_root: []const u8,
        elicitation_capabilities: elicitation.Capabilities,
        loader: mcp_runtime.LoadRuntimeFn,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        cancel_requested: *std.atomic.Value(bool),
        pending: *PendingReload,
        rebuild: bool,
    ) !ReloadOutcome {
        if (cancel_requested.load(.acquire)) return error.Cancelled;
        if (!rebuild) {
            if (self.acquire()) |owned| {
                var lease = owned;
                defer lease.deinit();
                try lease.runtime.drainRetiredServers();
                var snapshot = try lease.runtime.snapshotHealth(alloc, captured_at_ms);
                defer snapshot.deinit(alloc);
                return .{ .published = try PublishedReload.init(alloc, if (snapshot.servers.len == 0) null else lease.runtime.generation, snapshot.servers) };
            }
            return .{ .published = try PublishedReload.init(alloc, null, &.{}) };
        }
        const candidate = try loader(alloc, workspace_root, elicitation_capabilities);
        return self.applyReloadCandidate(alloc, candidate, registry, captured_at_ms, cancel_requested, pending, false, false);
    }

    /// Takes ownership of the unloaded candidate, including all error paths.
    fn applyReloadCandidate(
        self: *State,
        alloc: Allocator,
        candidate: ?*mcp_runtime.McpRuntime,
        registry: tool_dispatch.Registry,
        captured_at_ms: u64,
        cancel_requested: *std.atomic.Value(bool),
        pending: ?*PendingReload,
        retain_on_required_failure: bool,
        refresh_catalogs: bool,
    ) !ReloadOutcome {
        var candidate_owned = candidate != null;
        defer if (candidate_owned) destroyRuntime(alloc, candidate.?);
        self.lock.lockSharedUncancelable(io_mod.getIo());
        const stale = cancel_requested.load(.acquire) or (pending != null and self.pending_reload != pending.?);
        self.lock.unlockShared(io_mod.getIo());
        if (stale) return error.Cancelled;
        if (self.acquire()) |owned| {
            var lease = owned;
            defer lease.deinit();
            if (try lease.runtime.reconcile(candidate, cancel_requested, retain_on_required_failure)) |failure| {
                return .{ .retained_required_failure = failure };
            }
            if (refresh_catalogs) try lease.runtime.reloadCatalogs(cancel_requested);
            var snapshot = try lease.runtime.snapshotHealth(alloc, captured_at_ms);
            defer snapshot.deinit(alloc);
            return .{ .published = try PublishedReload.init(
                alloc,
                if (snapshot.servers.len == 0) null else lease.runtime.generation,
                snapshot.servers,
            ) };
        }
        var published = if (candidate) |runtime| result: {
            runtime.connectAllCancellable(registry, cancel_requested);
            if (cancel_requested.load(.acquire)) return error.Cancelled;
            var snapshot = try runtime.snapshotHealth(alloc, captured_at_ms);
            defer snapshot.deinit(alloc);
            if (retain_on_required_failure and !mcp_health.publishCandidateForDecision(mcp_health.startupDecision(snapshot.servers))) {
                return .{ .retained_required_failure = (try runtime.requiredStartupFailure(alloc, captured_at_ms)) orelse try alloc.dupe(u8, "A required MCP server is unavailable.") };
            }
            break :result try PublishedReload.init(alloc, runtime.generation, snapshot.servers);
        } else try PublishedReload.init(alloc, null, &.{});
        errdefer published.deinit(alloc);
        self.lock.lockUncancelable(io_mod.getIo());
        defer self.lock.unlock(io_mod.getIo());
        if (cancel_requested.load(.acquire) or (pending != null and self.pending_reload != pending.?) or self.runtime != null) return error.Cancelled;
        self.runtime = candidate;
        candidate_owned = false;
        return .{ .published = published };
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.cancelPendingAuthentication("shutdown");
        self.cancelPendingReload();
        self.cancelPendingMenuOperation("shutdown");
        self.lock.lockUncancelable(io_mod.getIo());
        const previous = self.runtime;
        self.runtime = null;
        self.lock.unlock(io_mod.getIo());
        if (previous) |runtime| destroyRuntime(alloc, runtime);
        self.clearMenuOwned(alloc);
        self.* = .{};
    }
};

fn cancelAndDeinitAuthentication(
    pending: *PendingAuthentication,
    reason: []const u8,
) void {
    debug_trace.logf(
        "mcp",
        "discarding pending authentication server={s} reason={s}",
        .{ pending.server_name, reason },
    );
    pending.cancel_requested.store(true, .release);
    pending.deinit();
}

fn destroyRuntime(alloc: Allocator, runtime: *mcp_runtime.McpRuntime) void {
    runtime.retireAndWait();
    runtime.deinit();
    alloc.destroy(runtime);
}

test "MCP menu expands every resource template argument" {
    const alloc = std.testing.allocator;
    var fields: std.ArrayList(MenuArgumentField) = .empty;
    defer {
        for (fields.items) |*field| field.deinit(alloc);
        fields.deinit(alloc);
    }
    try appendTemplateArgumentFields(
        alloc,
        &fields,
        "custom://project/{project}/{path}{?lang,mode}",
    );
    try std.testing.expectEqual(@as(usize, 4), fields.items.len);
    try std.testing.expectEqualStrings("project", fields.items[0].name);
    try std.testing.expectEqualStrings("path", fields.items[1].name);
    try std.testing.expectEqualStrings("lang", fields.items[2].name);
    try std.testing.expectEqualStrings("mode", fields.items[3].name);

    const arguments = [_]OwnedMenuArgument{
        .{ .name = @constCast("project"), .value = @constCast("alpha team") },
        .{ .name = @constCast("path"), .value = @constCast("src/lib") },
        .{ .name = @constCast("lang"), .value = @constCast("en") },
        .{ .name = @constCast("mode"), .value = @constCast("fast") },
    };
    const expanded = try expandResourceTemplate(
        alloc,
        "custom://project/{project}/{path}{?lang,mode}",
        &arguments,
    );
    defer alloc.free(expanded);
    try std.testing.expectEqualStrings(
        "custom://project/alpha%20team/src%2Flib?lang=en&mode=fast",
        expanded,
    );
}

test "MCP menu failures preserve exact menu-owned feedback" {
    const alloc = std.testing.allocator;

    var effect_state = State{
        .menu = .{
            .active = true,
            .load_state = .loading,
            .pending_generation = 7,
        },
    };
    defer effect_state.deinit(alloc);
    try effect_state.recordMenuEffectFailure(
        alloc,
        7,
        error.McpServerNotFound,
    );
    try std.testing.expectEqualStrings(
        "MCP operation failed: McpServerNotFound",
        effect_state.menu_feedback.?,
    );
    try std.testing.expectEqual(mcp_menu_state.LoadState.failed, effect_state.menu.load_state);

    var reload_state = State{
        .menu = .{
            .active = true,
            .load_state = .loading,
            .pending_generation = 11,
        },
    };
    defer reload_state.deinit(alloc);
    const reload_completion = ReloadCompletion{ .failed = error.TestReloadFailed };
    try reload_state.applyMenuReloadCompletion(
        alloc,
        11,
        &reload_completion,
        0,
    );
    try std.testing.expectEqualStrings(
        "MCP reload failed: TestReloadFailed",
        reload_state.menu_feedback.?,
    );
    try std.testing.expectEqual(mcp_menu_state.LoadState.failed, reload_state.menu.load_state);

    var unavailable_names = [_][]u8{
        @constCast("alpha"),
        @constCast("beta"),
    };
    var degraded_state = State{
        .menu = .{
            .active = true,
            .load_state = .loading,
            .pending_generation = 12,
        },
    };
    defer degraded_state.deinit(alloc);
    const degraded_completion = ReloadCompletion{ .outcome = .{ .published = .{
        .generation = 4,
        .health = .degraded,
        .configured_server_count = 3,
        .unavailable_server_names = &unavailable_names,
    } } };
    try degraded_state.applyMenuReloadCompletion(
        alloc,
        12,
        &degraded_completion,
        0,
    );
    try std.testing.expectEqualStrings(
        "MCP reloaded with 2 unavailable servers.",
        degraded_state.menu_feedback.?,
    );

    var authentication_state = State{
        .menu = .{
            .active = true,
            .load_state = .loading,
            .pending_generation = 13,
        },
    };
    defer authentication_state.deinit(alloc);
    const authentication_completion = AuthenticationCompletion{
        .server_name = @constCast("fixture"),
        .result = error.TestAuthenticationFailed,
    };
    try std.testing.expect(!try authentication_state.applyMenuAuthenticationCompletion(
        alloc,
        13,
        &authentication_completion,
    ));
    try std.testing.expectEqualStrings(
        "MCP authentication for 'fixture' failed: TestAuthenticationFailed",
        authentication_state.menu_feedback.?,
    );
    try std.testing.expectEqual(
        mcp_menu_state.LoadState.failed,
        authentication_state.menu.load_state,
    );

    var repaired_state = State{
        .menu = .{
            .active = true,
            .load_state = .loading,
            .pending_generation = 17,
        },
    };
    defer repaired_state.deinit(alloc);
    const repaired_completion = AuthenticationCompletion{
        .server_name = @constCast("fixture"),
        .result = .{ .authenticated = .{ .repaired_entries = 2 } },
    };
    try std.testing.expect(try repaired_state.applyMenuAuthenticationCompletion(
        alloc,
        17,
        &repaired_completion,
    ));
    try std.testing.expectEqualStrings(
        "Authenticated 'fixture'; repaired 2 credential entries.",
        repaired_state.menu_feedback.?,
    );
}

test "MCP menu repeated lifecycle releases drafts and feedback" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    for (0..1000) |cycle| {
        try state.openMenu(alloc, cycle);
        try state.setMenuAddField(alloc, 0, "fixture");
        try state.setMenuAddField(alloc, 1, "/usr/bin/env");
        try state.setMenuAddField(alloc, 2, "node fixture.mjs");
        try state.setMenuFeedback(alloc, "Saved MCP server; reconnecting…");
        state.closeMenu(alloc);

        const view = state.menuView();
        try std.testing.expect(!view.state.active);
        try std.testing.expectEqual(@as(usize, 0), view.add_form.name.items.len);
        try std.testing.expectEqual(@as(usize, 0), view.add_form.target.items.len);
        try std.testing.expectEqual(@as(usize, 0), view.add_form.arguments.items.len);
        try std.testing.expect(view.feedback == null);
    }
}

const TestReloadMode = enum {
    parse_failure,
    required_disabled,
    optional_failed,
    empty,
    delayed_empty,
    stalled_candidate,
};

var test_reload_mode: TestReloadMode = .empty;

test "menu selection follows server identity when snapshots reorder" {
    const alloc = std.testing.allocator;
    var runtime = mcp_runtime.McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{ .name = try alloc.dupe(u8, "first"), .command = try alloc.dupe(u8, "cmd") });
    try runtime.addServer(.{ .name = try alloc.dupe(u8, "second"), .command = try alloc.dupe(u8, "cmd") });
    var state: State = .{};
    defer state.deinit(alloc);
    state.menu_health = try runtime.snapshotHealth(alloc, 1);
    state.menu = .{ .active = true, .section = .servers, .screen = .details, .selected_index = 1, .selected_server_index = 1 };
    var reordered = try runtime.snapshotHealth(alloc, 200);
    std.mem.swap(mcp_health.ServerSnapshot, &reordered.servers[0], &reordered.servers[1]);
    try std.testing.expect(state.replaceMenuHealth(alloc, reordered));
    try std.testing.expectEqual(@as(usize, 0), state.menu.selected_index);
    try std.testing.expectEqualStrings("second", state.selectedMenuServerName().?);
}

fn loadTestReloadRuntime(
    alloc: Allocator,
    _: []const u8,
    _: elicitation.Capabilities,
) !?*mcp_runtime.McpRuntime {
    switch (test_reload_mode) {
        .parse_failure => return error.McpConfigInvalidJson,
        .empty => return null,
        .delayed_empty => {
            io_mod.sleep(100 * std.time.ns_per_ms);
            return null;
        },
        .required_disabled, .optional_failed, .stalled_candidate => {},
    }
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    errdefer alloc.destroy(runtime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    errdefer runtime.deinit();
    const name = try alloc.dupe(u8, "candidate");
    errdefer alloc.free(name);
    const command = try alloc.dupe(
        u8,
        switch (test_reload_mode) {
            .optional_failed => "__fx_missing_mcp_executable__",
            .stalled_candidate => "awk",
            else => "disabled",
        },
    );
    errdefer alloc.free(command);
    const args = if (test_reload_mode == .stalled_candidate) args: {
        const values = try alloc.alloc([]const u8, 1);
        errdefer alloc.free(values);
        values[0] = try alloc.dupe(u8, "{}");
        break :args values;
    } else &.{};
    errdefer if (args.len > 0) {
        for (args) |arg| alloc.free(arg);
        alloc.free(args);
    };
    const config = mcp_contract.McpServerConfig{
        .name = name,
        .command = command,
        .args = args,
        .enabled = test_reload_mode == .optional_failed or
            test_reload_mode == .stalled_candidate,
        .required = test_reload_mode == .required_disabled,
        .startup_timeout_ms = if (test_reload_mode == .stalled_candidate)
            60_000
        else
            10_000,
    };
    try runtime.addServer(config);
    return runtime;
}

fn previewTestWorkspaceAuthority(alloc: Allocator, _: []const u8) ![][]u8 {
    return alloc.alloc([]u8, 0);
}

fn failPendingReloadSpawn(_: *PendingReload) !std.Thread {
    return error.TestSpawnFailed;
}

fn expectNoActiveMcpServers(state: *State) !void {
    var lease = state.acquire() orelse return;
    defer lease.deinit();
    var snapshot = try lease.runtime.snapshotHealth(std.testing.allocator, 0);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.servers.len);
}

test "transactional reload retains old runtime and publishes only accepted candidates" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const original = try alloc.create(mcp_runtime.McpRuntime);
    original.* = mcp_runtime.McpRuntime.init(alloc);
    const original_generation = original.generation;
    state.installInitial(original);

    test_reload_mode = .parse_failure;
    try std.testing.expectError(
        error.McpConfigInvalidJson,
        state.reload(alloc, "/workspace", .{}, loadTestReloadRuntime, previewTestWorkspaceAuthority, .{}, 10),
    );
    {
        var lease = state.acquire() orelse return error.TestUnexpectedResult;
        defer lease.deinit();
        try std.testing.expectEqual(original_generation, lease.runtime.generation);
    }

    test_reload_mode = .required_disabled;
    var rejected = try state.reload(alloc, "/workspace", .{}, loadTestReloadRuntime, previewTestWorkspaceAuthority, .{}, 20);
    defer rejected.deinit(alloc);
    switch (rejected) {
        .retained_required_failure => |failure| {
            try std.testing.expect(std.mem.find(u8, failure, "candidate") != null);
            try std.testing.expect(std.mem.find(u8, failure, "Required MCP server") != null);
        },
        .published => return error.TestUnexpectedResult,
    }
    {
        var lease = state.acquire() orelse return error.TestUnexpectedResult;
        defer lease.deinit();
        try std.testing.expectEqual(original_generation, lease.runtime.generation);
    }

    test_reload_mode = .optional_failed;
    var degraded = try state.reload(alloc, "/workspace", .{}, loadTestReloadRuntime, previewTestWorkspaceAuthority, .{}, 30);
    defer degraded.deinit(alloc);
    switch (degraded) {
        .published => |published| {
            try std.testing.expectEqual(mcp_health.StartupDecision.degraded, published.health);
            try std.testing.expectEqual(original_generation, published.generation.?);
            try std.testing.expectEqual(@as(usize, 1), published.configured_server_count);
            try std.testing.expectEqual(@as(usize, 1), published.unavailable_server_names.len);
            try std.testing.expectEqualStrings("candidate", published.unavailable_server_names[0]);
        },
        .retained_required_failure => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(?tool_mcp_runtime.CallResult, null), try state.callTool(
        alloc,
        "mcp_candidate_echo",
        "{}",
        1024,
        .{ .expected_runtime_generation = original_generation },
    ));

    test_reload_mode = .empty;
    var empty = try state.reload(alloc, "/workspace", .{}, loadTestReloadRuntime, previewTestWorkspaceAuthority, .{}, 40);
    defer empty.deinit(alloc);
    switch (empty) {
        .published => |published| {
            try std.testing.expectEqual(mcp_health.StartupDecision.ready, published.health);
            try std.testing.expect(published.generation == null);
            try std.testing.expectEqual(@as(usize, 0), published.configured_server_count);
            try std.testing.expectEqual(@as(usize, 0), published.unavailable_server_names.len);
        },
        .retained_required_failure => return error.TestUnexpectedResult,
    }
    try expectNoActiveMcpServers(&state);
}

test "reducing preflight retires workspace authority before strict loader failure" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "workspace"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "unused"),
        .workspace_admission = .approved,
    });
    state.installInitial(runtime);

    test_reload_mode = .parse_failure;
    defer test_reload_mode = .empty;
    try std.testing.expectError(
        error.McpAuthorityReducedReloadFailed,
        state.reload(
            alloc,
            "/workspace",
            .{},
            loadTestReloadRuntime,
            previewTestWorkspaceAuthority,
            .{},
            10,
        ),
    );
    try expectNoActiveMcpServers(&state);
}

test "project prompt display escapes repository control bytes" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "bad\n\x1b]0;owned\x07"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "unused"),
        .workspace_admission = .pending,
    });
    state.installInitial(runtime);
    const display = (try state.projectPromptDisplayName(alloc)).?;
    defer alloc.free(display);
    try std.testing.expect(text_utils.isTerminalSafe(display));
    try std.testing.expect(std.mem.findScalar(u8, display, '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, display, 0x1b) == null);
}

test "project prompt allocation failure releases the runtime lease" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "pending"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "unused"),
        .workspace_admission = .pending,
    });
    state.installInitial(runtime);
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        state.projectPromptName(failing.allocator()),
    );
    state.deinit(alloc);
}

test "pending reload returns immediately and publishes one completion" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const original = try alloc.create(mcp_runtime.McpRuntime);
    original.* = mcp_runtime.McpRuntime.init(alloc);
    const original_generation = original.generation;
    state.installInitial(original);

    test_reload_mode = .delayed_empty;
    const started_ms = io_mod.milliTimestamp();
    try state.beginReload(alloc, "/workspace", .{}, loadTestReloadRuntime, previewTestWorkspaceAuthority, .{}, 50);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 50);
    {
        var lease = state.acquire() orelse return error.TestUnexpectedResult;
        defer lease.deinit();
        try std.testing.expectEqual(original_generation, lease.runtime.generation);
    }
    try std.testing.expect(state.takeReloadCompletion() == null);

    var completion: ?ReloadCompletion = null;
    const deadline = io_mod.milliTimestamp() + 2_000;
    while (completion == null and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
        completion = state.takeReloadCompletion();
    }
    var loaded = completion orelse return error.TestUnexpectedResult;
    defer loaded.deinit(alloc);
    switch (loaded) {
        .outcome => |outcome| switch (outcome) {
            .published => |published| {
                try std.testing.expectEqual(mcp_health.StartupDecision.ready, published.health);
                try std.testing.expect(published.generation == null);
                try std.testing.expectEqual(@as(usize, 0), published.configured_server_count);
                try std.testing.expectEqual(@as(usize, 0), published.unavailable_server_names.len);
            },
            .retained_required_failure => return error.TestUnexpectedResult,
        },
        .failed => return error.TestUnexpectedResult,
    }
    try std.testing.expect(state.takeReloadCompletion() == null);
    try expectNoActiveMcpServers(&state);
}

test "reload thread start failure frees the task and copied workspace root once" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    try std.testing.expectError(
        error.TestSpawnFailed,
        state.beginReloadWithSpawner(
            alloc,
            "/workspace",
            .{},
            loadTestReloadRuntime,
            previewTestWorkspaceAuthority,
            .{},
            50,
            failPendingReloadSpawn,
        ),
    );
    try std.testing.expect(state.pending_reload == null);
}

test "authority reduction drains revoked servers without waiting for unrelated runtime leases" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "workspace"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "unused"),
        .workspace_admission = .approved,
    });
    state.installInitial(runtime);

    var active_lease = state.acquire() orelse return error.TestUnexpectedResult;
    var active_lease_owned = true;
    defer if (active_lease_owned) active_lease.deinit();
    var authentication_lease = state.acquire() orelse return error.TestUnexpectedResult;
    var authentication_lease_owned = true;
    defer if (authentication_lease_owned) authentication_lease.deinit();

    test_reload_mode = .delayed_empty;
    defer test_reload_mode = .empty;
    try state.beginReload(
        alloc,
        "/workspace",
        .{},
        loadTestReloadRuntime,
        previewTestWorkspaceAuthority,
        .{},
        50,
    );

    const retirement_deadline = io_mod.milliTimestamp() + 2_000;
    while (true) {
        var snapshot = try runtime.snapshotHealth(alloc, 0);
        const revoked = snapshot.servers.len == 0;
        snapshot.deinit(alloc);
        if (revoked) break;
        if (io_mod.milliTimestamp() >= retirement_deadline) return error.TestWorkspaceAuthorityNotRetired;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(!runtime.retiring.load(.acquire));

    const authentication_name = try alloc.dupe(u8, "workspace");
    const authentication = alloc.create(PendingAuthentication) catch |err| {
        alloc.free(authentication_name);
        return err;
    };
    authentication.* = .{
        .alloc = alloc,
        .server_name = authentication_name,
        .lease = authentication_lease,
        .opener = host.unavailable_url_opener,
        .done = .init(true),
        .result = error.Cancelled,
    };
    state.lock.lockUncancelable(io_mod.getIo());
    state.pending_authentication = authentication;
    state.lock.unlock(io_mod.getIo());
    authentication_lease_owned = false;

    try state.beginAuthorityReduction(
        alloc,
        "/workspace",
        .{},
        loadTestReloadRuntime,
        .{},
        60,
        false,
    );
    try expectNoActiveMcpServers(&state);

    try std.testing.expect(!runtime.retiring.load(.acquire));
    var completion: ?ReloadCompletion = null;
    const completion_deadline = io_mod.milliTimestamp() + 2_000;
    while (completion == null and io_mod.milliTimestamp() < completion_deadline) {
        io_mod.sleep(std.time.ns_per_ms);
        completion = state.takeReloadCompletion();
    }
    var loaded = completion orelse return error.TestUnexpectedResult;
    active_lease.deinit();
    active_lease_owned = false;
    defer loaded.deinit(alloc);
    switch (loaded) {
        .outcome => |outcome| switch (outcome) {
            .published => |published| try std.testing.expect(
                published.generation == null,
            ),
            .retained_required_failure => return error.TestUnexpectedResult,
        },
        .failed => return error.TestUnexpectedResult,
    }
    try expectNoActiveMcpServers(&state);
}

test "authority reduction thread start failure falls back synchronously" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "workspace"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "unused"),
        .workspace_admission = .approved,
    });
    state.installInitial(runtime);

    test_reload_mode = .empty;
    try state.beginAuthorityReductionWithSpawner(
        alloc,
        "/workspace",
        .{},
        loadTestReloadRuntime,
        .{},
        70,
        false,
        failPendingReloadSpawn,
    );
    try expectNoActiveMcpServers(&state);
    var completion = state.takeReloadCompletion() orelse
        return error.TestUnexpectedResult;
    defer completion.deinit(alloc);
    switch (completion) {
        .outcome => |outcome| switch (outcome) {
            .published => |published| try std.testing.expect(
                published.generation == null,
            ),
            .retained_required_failure => return error.TestUnexpectedResult,
        },
        .failed => return error.TestUnexpectedResult,
    }
}

test "authentication admission is busy while reload is pending" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    test_reload_mode = .delayed_empty;
    try state.beginReload(alloc, "/workspace", .{}, loadTestReloadRuntime, previewTestWorkspaceAuthority, .{}, 55);
    try std.testing.expectEqual(
        mcp_command_provider.AuthenticationStart.busy,
        try state.startAuthentication(
            alloc,
            "fixture",
            host.unavailable_url_opener,
        ),
    );

    var completion: ?ReloadCompletion = null;
    const deadline = io_mod.milliTimestamp() + 2_000;
    while (completion == null and io_mod.milliTimestamp() < deadline) {
        io_mod.sleep(std.time.ns_per_ms);
        completion = state.takeReloadCompletion();
    }
    var loaded = completion orelse return error.TestUnexpectedResult;
    loaded.deinit(alloc);
}

test "authentication completion releases its lease and is taken once" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);
    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    state.installInitial(runtime);

    const pending = try alloc.create(PendingAuthentication);
    pending.* = .{
        .alloc = alloc,
        .server_name = try alloc.dupe(u8, "fixture"),
        .lease = state.acquire() orelse return error.TestUnexpectedResult,
        .opener = host.unavailable_url_opener,
        .done = .init(true),
        .result = error.Cancelled,
    };
    state.pending_authentication = pending;
    try std.testing.expect(state.authenticationPending("fixture"));
    try std.testing.expect(!state.authenticationPending("other"));

    var completion = state.takeAuthenticationCompletion() orelse
        return error.TestUnexpectedResult;
    defer completion.deinit(alloc);
    try std.testing.expectEqualStrings("fixture", completion.server_name);
    try std.testing.expectError(error.Cancelled, completion.result);
    try std.testing.expect(!state.authenticationPending("fixture"));
    try std.testing.expect(state.takeAuthenticationCompletion() == null);
}

test "superseding and deinitializing a stalled pending reload cancel before join" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    const original = try alloc.create(mcp_runtime.McpRuntime);
    original.* = mcp_runtime.McpRuntime.init(alloc);
    state.installInitial(original);

    test_reload_mode = .stalled_candidate;
    try state.beginReload(alloc, "/workspace", .{}, loadTestReloadRuntime, previewTestWorkspaceAuthority, .{}, 60);
    io_mod.sleep(25 * std.time.ns_per_ms);
    test_reload_mode = .empty;
    const supersede_started_ms = io_mod.milliTimestamp();
    try state.beginReload(alloc, "/workspace", .{}, loadTestReloadRuntime, previewTestWorkspaceAuthority, .{}, 70);
    try std.testing.expect(io_mod.milliTimestamp() - supersede_started_ms < 1_000);

    var completion: ?ReloadCompletion = null;
    const completion_deadline = io_mod.milliTimestamp() + 2_000;
    while (completion == null and io_mod.milliTimestamp() < completion_deadline) {
        io_mod.sleep(std.time.ns_per_ms);
        completion = state.takeReloadCompletion();
    }
    var loaded = completion orelse return error.TestUnexpectedResult;
    loaded.deinit(alloc);

    test_reload_mode = .stalled_candidate;
    try state.beginReload(alloc, "/workspace", .{}, loadTestReloadRuntime, previewTestWorkspaceAuthority, .{}, 80);
    io_mod.sleep(25 * std.time.ns_per_ms);
    const deinit_started_ms = io_mod.milliTimestamp();
    state.deinit(alloc);
    try std.testing.expect(io_mod.milliTimestamp() - deinit_started_ms < 1_000);
}
