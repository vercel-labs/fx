const std = @import("std");

const builtin_tools = @import("tools.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const command_provider_contract = @import("../core/mcp/command_provider.zig");
const mcp_contract = @import("../core/mcp/mcp_contract.zig");
const mcp_health = @import("../core/mcp/health.zig");
const project_config = @import("../core/mcp/project_config.zig");
const workspace_config = @import("../core/mcp/workspace_config.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const elicitation = @import("../core/mcp/elicitation.zig");
const streamable_http = @import("../core/mcp/streamable_http.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const text_utils = @import("../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const CommandRequest = command_provider_contract.Request;
const CommandResult = command_provider_contract.Result;
const McpServerConfig = mcp_contract.McpServerConfig;
const McpTransport = mcp_contract.McpTransport;

const add_usage = "Usage: /mcp add <name> <command> [args...] or /mcp add --transport http <name> <url>";
const profile_lock_deadline_ms: u64 = 2_000;

pub const command_provider = command_provider_contract.Provider{ .handle_fn = handleCommand };

fn handleCommand(alloc: Allocator, rest: []const u8, command_request: CommandRequest) !CommandResult {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) {
        const summarize = command_request.summarize_servers orelse
            command_request.list_servers_and_tools;
        const summary = try summarize(command_request.list_ctx, alloc);
        errdefer alloc.free(summary);
        return .{
            .display = .{
                .block = try appendProfileWarning(
                    alloc,
                    command_request.home,
                    summary,
                ),
            },
        };
    }
    if (std.mem.eql(u8, trimmed, "list")) {
        const listing = try command_request.list_servers_and_tools(
            command_request.list_ctx,
            alloc,
        );
        errdefer alloc.free(listing);
        return .{
            .display = .{
                .block = try appendProfileWarning(
                    alloc,
                    command_request.home,
                    listing,
                ),
            },
        };
    }

    if (std.mem.startsWith(u8, trimmed, "resource ")) {
        return handleResourceCommand(alloc, std.mem.trimStart(u8, trimmed[9..], " \t"), command_request);
    }
    if (std.mem.startsWith(u8, trimmed, "prompt ")) {
        return handlePromptCommand(alloc, std.mem.trimStart(u8, trimmed[7..], " \t"), command_request);
    }

    const home = command_request.home orelse return lineLiteral(alloc, "HOME is not available.", false);
    const config_path = try configPathFromHome(alloc, home);
    defer alloc.free(config_path);

    if (std.mem.eql(u8, trimmed, "path")) {
        return lineParts(alloc, &.{config_path}, false);
    }

    if (std.mem.eql(u8, trimmed, "reload")) {
        var maybe_document: ?project_config.ProfileParseResult =
            loadProfileDocumentFromPath(alloc, config_path) catch null;
        defer if (maybe_document) |*document| document.deinit(alloc);
        if (maybe_document) |document| if (document.diagnostic) |warning| {
            const warning_text = try renderProfileWarning(alloc, warning);
            defer alloc.free(warning_text);
            return .{
                .display = .{ .line = try std.fmt.allocPrint(
                    alloc,
                    "{s}\nEvaluating trusted profile MCP configuration.",
                    .{warning_text},
                ) },
                .reload = true,
                .report_reload = true,
            };
        };
        return .{
            .display = .{
                .line = try alloc.dupe(u8, "Evaluating trusted profile MCP configuration."),
            },
            .reload = true,
            .report_reload = true,
        };
    }

    if (std.mem.startsWith(u8, trimmed, "trust ")) {
        var tokens = std.mem.tokenizeAny(u8, trimmed[6..], " \t");
        const operation = tokens.next() orelse
            return lineLiteral(alloc, "Usage: /mcp trust approve|reject <server> | approve-all | reset", false);
        if (std.mem.eql(u8, operation, "approve-all")) {
            if (tokens.next() != null) return lineLiteral(alloc, "Usage: /mcp trust approve-all", false);
            return .{
                .display = .{ .line = try alloc.dupe(u8, "Approving all project MCP servers for this workspace.") },
                .project_action = .approve_all,
            };
        }
        if (std.mem.eql(u8, operation, "reset")) {
            if (tokens.next() != null) return lineLiteral(alloc, "Usage: /mcp trust reset", false);
            return .{
                .display = .{ .line = try alloc.dupe(u8, "Resetting project MCP choices for this workspace.") },
                .project_action = .reset,
            };
        }
        const name = tokens.next() orelse
            return lineLiteral(alloc, "Usage: /mcp trust approve|reject <server>", false);
        if (tokens.next() != null) return lineLiteral(alloc, "Usage: /mcp trust approve|reject <server>", false);
        if (std.mem.eql(u8, operation, "approve")) {
            return .{
                .display = .{ .line = try std.fmt.allocPrint(alloc, "Approving project MCP server '{s}'.", .{name}) },
                .project_action = .{ .approve = name },
            };
        }
        if (std.mem.eql(u8, operation, "reject")) {
            return .{
                .display = .{ .line = try std.fmt.allocPrint(alloc, "Rejecting project MCP server '{s}'.", .{name}) },
                .project_action = .{ .reject = name },
            };
        }
        return lineLiteral(alloc, "Usage: /mcp trust approve|reject <server> | approve-all | reset", false);
    }

    if (std.mem.eql(u8, trimmed, "auth") or std.mem.startsWith(u8, trimmed, "auth ")) {
        var tokens = std.mem.tokenizeAny(u8, trimmed[4..], " \t");
        const name = tokens.next() orelse
            return lineLiteral(alloc, "Usage: /mcp auth <name> [--open]", false);
        const confirmation = tokens.next();
        if (tokens.next() != null or
            (confirmation != null and !std.mem.eql(u8, confirmation.?, "--open")))
        {
            return lineLiteral(alloc, "Usage: /mcp auth <name> [--open]", false);
        }
        const validate = command_request.validate_authentication_server orelse
            return lineLiteral(
                alloc,
                "Interactive MCP authentication is unavailable here.",
                false,
            );
        validate(command_request.auth_ctx orelse command_request.list_ctx, name) catch |err| {
            return lineParts(
                alloc,
                &.{ "MCP authentication for '", name, "' failed: ", @errorName(err), "." },
                false,
            );
        };
        if (confirmation == null) {
            return lineParts(
                alloc,
                &.{ "Run /mcp auth ", name, " --open to confirm opening your browser." },
                false,
            );
        }
        const authenticate = command_request.authenticate_server orelse
            return lineLiteral(
                alloc,
                "Interactive MCP authentication is unavailable here.",
                false,
            );
        const authentication = authenticate(
            command_request.auth_ctx orelse command_request.list_ctx,
            name,
        ) catch |err| {
            return lineParts(
                alloc,
                &.{ "MCP authentication for '", name, "' failed: ", @errorName(err), "." },
                false,
            );
        };
        return switch (authentication) {
            .started => lineParts(
                alloc,
                &.{ "Waiting for MCP authentication for '", name, "'. You can continue using fx while the browser flow completes." },
                false,
            ),
            .busy => lineParts(
                alloc,
                &.{ "MCP authentication for '", name, "' is already in progress or MCP configuration is reloading." },
                false,
            ),
        };
    }

    if (std.mem.startsWith(u8, trimmed, "logout ")) {
        const name = std.mem.trim(u8, trimmed[7..], " \t");
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t") != null) {
            return lineLiteral(alloc, "Usage: /mcp logout <name>", false);
        }
        const logout = command_request.logout_server orelse
            return lineLiteral(alloc, "MCP logout is unavailable here.", false);
        const result = logout(
            command_request.auth_ctx orelse command_request.list_ctx,
            name,
        ) catch |err| {
            return lineParts(
                alloc,
                &.{ "MCP logout for '", name, "' failed: ", @errorName(err), "." },
                false,
            );
        };
        if (result.busy) {
            return lineParts(
                alloc,
                &.{ "MCP authentication for '", name, "' is still in progress. Wait for it to finish before logging out." },
                false,
            );
        }
        if (!result.removed) {
            return lineParts(
                alloc,
                &.{ "No stored MCP credentials found for '", name, "'." },
                false,
            );
        }
        if (result.repaired_entries > 0) {
            const text = if (result.revocation_failed)
                try std.fmt.allocPrint(
                    alloc,
                    "Logged out of MCP server '{s}' locally; remote revocation failed. Removed {d} unreadable MCP credential {s}.",
                    .{
                        name,
                        result.repaired_entries,
                        if (result.repaired_entries == 1) "entry" else "entries",
                    },
                )
            else
                try std.fmt.allocPrint(
                    alloc,
                    "Logged out of MCP server '{s}'. Removed {d} unreadable MCP credential {s}.",
                    .{
                        name,
                        result.repaired_entries,
                        if (result.repaired_entries == 1) "entry" else "entries",
                    },
                );
            return .{
                .display = .{ .line = text },
                .reload = false,
            };
        }
        if (result.revocation_failed) {
            return lineParts(
                alloc,
                &.{ "Logged out of MCP server '", name, "' locally; remote revocation failed." },
                false,
            );
        }
        return lineParts(
            alloc,
            &.{ "Logged out of MCP server '", name, "'." },
            false,
        );
    }

    if (std.mem.startsWith(u8, trimmed, "remove ")) {
        const name = std.mem.trim(u8, trimmed[7..], " \t");
        if (name.len == 0) {
            return lineLiteral(alloc, "Usage: /mcp remove <name>", false);
        }

        const removed = removeServerFromPath(alloc, config_path, name) catch |err| {
            return lineParts(
                alloc,
                &.{ "Failed to remove MCP server '", name, "': ", @errorName(err), "." },
                false,
            );
        };
        if (!removed) {
            return lineParts(alloc, &.{ "MCP server '", name, "' not found." }, false);
        }
        return lineParts(alloc, &.{ "Removed MCP server '", name, "'." }, true);
    }

    if (std.mem.startsWith(u8, trimmed, "add ")) {
        var tokens: std.ArrayList([]const u8) = .empty;
        defer tokens.deinit(alloc);

        var it = std.mem.tokenizeAny(u8, trimmed[4..], " \t");
        while (it.next()) |token| try tokens.append(alloc, token);

        const intent = command_provider_contract.parseAddIntent(tokens.items) catch |err| switch (err) {
            error.McpAddUsage => return lineLiteral(alloc, add_usage, false),
            else => return lineParts(
                alloc,
                &.{ "Failed to save MCP server config: ", @errorName(err), "." },
                false,
            ),
        };
        const warning = addProfileServerToPath(alloc, config_path, intent) catch |err| {
            return lineParts(
                alloc,
                &.{ "Failed to save MCP server config: ", @errorName(err), "." },
                false,
            );
        };
        const name = switch (intent) {
            .local => |local| local.name,
            .http => |http| http.name,
        };
        if (warning) |value| {
            const warning_text = try renderProfileWarning(alloc, value);
            defer alloc.free(warning_text);
            return lineParts(
                alloc,
                &.{ warning_text, "\nSaved MCP server '", name, "'." },
                true,
            );
        }
        return lineParts(alloc, &.{ "Saved MCP server '", name, "'." }, true);
    }

    return lineLiteral(
        alloc,
        "Usage: /mcp [list|resource|prompt|add|remove|path|reload|auth|logout|trust]",
        false,
    );
}

fn appendProfileWarning(
    alloc: Allocator,
    home: ?[]const u8,
    owned_body: []u8,
) ![]u8 {
    const home_path = home orelse return owned_body;
    const path = try configPathFromHome(alloc, home_path);
    defer alloc.free(path);
    var document = loadProfileDocumentFromPath(alloc, path) catch return owned_body;
    defer document.deinit(alloc);
    const warning = document.diagnostic orelse return owned_body;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(owned_body);
    if (out.written().len > 0 and out.written()[out.written().len - 1] != '\n') {
        try out.writer.writeByte('\n');
    }
    const warning_text = try renderProfileWarning(alloc, warning);
    defer alloc.free(warning_text);
    try out.writer.writeAll(warning_text);
    try out.writer.writeByte('\n');
    const rendered = try out.toOwnedSlice();
    alloc.free(owned_body);
    return rendered;
}

fn renderProfileWarning(
    alloc: Allocator,
    warning: project_config.ProfileDiagnostic,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("MCP config warning: {s}", .{@tagName(warning.cause)});
    if (warning.key()) |key| {
        const encoded = try text_utils.encodeTerminalSafe(alloc, key, 128);
        defer alloc.free(encoded.bytes);
        try out.writer.print(" key={s}", .{encoded.bytes});
    }
    try out.writer.print(
        " additional_matches={d}",
        .{warning.additional_matches},
    );
    return out.toOwnedSlice();
}

fn handleResourceCommand(alloc: Allocator, rest: []const u8, command_request: CommandRequest) !CommandResult {
    var input = rest;
    const action = takeToken(&input) orelse return lineLiteral(
        alloc,
        "Usage: /mcp resource [list|templates|read|complete] ...",
        false,
    );
    const context = command_request.feature_ctx orelse command_request.list_ctx;
    if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "templates")) {
        const server = takeToken(&input) orelse return lineLiteral(
            alloc,
            "Usage: /mcp resource list <server> or /mcp resource templates <server>",
            false,
        );
        if (takeToken(&input) != null) return lineLiteral(
            alloc,
            "Usage: /mcp resource list <server> or /mcp resource templates <server>",
            false,
        );
        const callback = command_request.list_resources orelse return lineLiteral(alloc, "MCP resources are unavailable here.", false);
        const text = callback(context, alloc, server, std.mem.eql(u8, action, "templates")) catch |err| {
            return lineParts(alloc, &.{ "MCP resource listing failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    if (std.mem.eql(u8, action, "read")) {
        const server = takeToken(&input) orelse return lineLiteral(alloc, "Usage: /mcp resource read <server> <uri>", false);
        const uri = std.mem.trim(u8, input, " \t");
        if (uri.len == 0) return lineLiteral(alloc, "Usage: /mcp resource read <server> <uri>", false);
        const callback = command_request.read_resource orelse return lineLiteral(alloc, "MCP resource reads are unavailable here.", false);
        const text = callback(context, alloc, server, uri) catch |err| {
            return lineParts(alloc, &.{ "MCP resource read failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    if (std.mem.eql(u8, action, "complete")) {
        const server = takeToken(&input) orelse return resourceCompletionUsage(alloc);
        const uri_template = takeToken(&input) orelse return resourceCompletionUsage(alloc);
        const variable_name = takeToken(&input) orelse return resourceCompletionUsage(alloc);
        const value = std.mem.trim(u8, input, " \t");
        const callback = command_request.complete_resource orelse return lineLiteral(alloc, "MCP resource completion is unavailable here.", false);
        const text = callback(context, alloc, server, uri_template, variable_name, value) catch |err| {
            return lineParts(alloc, &.{ "MCP resource completion failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    return lineLiteral(alloc, "Usage: /mcp resource [list|templates|read|complete] ...", false);
}

fn handlePromptCommand(alloc: Allocator, rest: []const u8, command_request: CommandRequest) !CommandResult {
    var input = rest;
    const action = takeToken(&input) orelse return lineLiteral(
        alloc,
        "Usage: /mcp prompt [list|get|complete] ...",
        false,
    );
    const context = command_request.feature_ctx orelse command_request.list_ctx;
    if (std.mem.eql(u8, action, "list")) {
        const server = takeToken(&input) orelse return lineLiteral(alloc, "Usage: /mcp prompt list <server>", false);
        if (takeToken(&input) != null) return lineLiteral(alloc, "Usage: /mcp prompt list <server>", false);
        const callback = command_request.list_prompts orelse return lineLiteral(alloc, "MCP prompts are unavailable here.", false);
        const text = callback(context, alloc, server) catch |err| {
            return lineParts(alloc, &.{ "MCP prompt listing failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    if (std.mem.eql(u8, action, "get")) {
        const server = takeToken(&input) orelse return promptGetUsage(alloc);
        const prompt_name = takeToken(&input) orelse return promptGetUsage(alloc);
        const arguments_json = if (std.mem.trim(u8, input, " \t").len > 0)
            std.mem.trim(u8, input, " \t")
        else
            "{}";
        const callback = command_request.get_prompt orelse return lineLiteral(alloc, "MCP prompt invocation is unavailable here.", false);
        const text = callback(context, alloc, server, prompt_name, arguments_json) catch |err| {
            return lineParts(alloc, &.{ "MCP prompt invocation failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    if (std.mem.eql(u8, action, "complete")) {
        const server = takeToken(&input) orelse return promptCompletionUsage(alloc);
        const prompt_name = takeToken(&input) orelse return promptCompletionUsage(alloc);
        const argument_name = takeToken(&input) orelse return promptCompletionUsage(alloc);
        const value = std.mem.trim(u8, input, " \t");
        const callback = command_request.complete_prompt orelse return lineLiteral(alloc, "MCP prompt completion is unavailable here.", false);
        const text = callback(context, alloc, server, prompt_name, argument_name, value) catch |err| {
            return lineParts(alloc, &.{ "MCP prompt completion failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    return lineLiteral(alloc, "Usage: /mcp prompt [list|get|complete] ...", false);
}

fn takeToken(input: *[]const u8) ?[]const u8 {
    input.* = std.mem.trimStart(u8, input.*, " \t");
    if (input.*.len == 0) return null;
    const end = std.mem.indexOfAny(u8, input.*, " \t") orelse input.*.len;
    const token = input.*[0..end];
    input.* = input.*[end..];
    return token;
}

fn resourceCompletionUsage(alloc: Allocator) !CommandResult {
    return lineLiteral(alloc, "Usage: /mcp resource complete <server> <uri-template> <variable> [value]", false);
}

fn promptGetUsage(alloc: Allocator) !CommandResult {
    return lineLiteral(alloc, "Usage: /mcp prompt get <server> <name> [arguments-json]", false);
}

fn promptCompletionUsage(alloc: Allocator) !CommandResult {
    return lineLiteral(alloc, "Usage: /mcp prompt complete <server> <name> <argument> [value]", false);
}

fn lineLiteral(alloc: Allocator, text: []const u8, reload: bool) !CommandResult {
    return .{ .display = .{ .line = try alloc.dupe(u8, text) }, .reload = reload };
}

// Non-generic on purpose: a comptime-format sibling stamps out one
// formatter instantiation per call shape; every message here is a plain
// string splice.
fn lineParts(alloc: Allocator, parts: []const []const u8, reload: bool) !CommandResult {
    return .{ .display = .{ .line = try std.mem.concat(alloc, u8, parts) }, .reload = reload };
}

pub fn configPathFromHome(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.mcpConfigPath(alloc, home);
}

pub fn addProfileServer(
    alloc: Allocator,
    intent: command_provider_contract.AddIntent,
) !command_provider_contract.ProfileAddResult {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const config_path = try configPathFromHome(alloc, home);
    errdefer alloc.free(config_path);
    const warning = try addProfileServerToPath(alloc, config_path, intent);
    return .{ .profile_path = config_path, .warning = warning };
}

pub fn removeProfileServer(
    alloc: Allocator,
    name: []const u8,
) !command_provider_contract.ProfileRemoveResult {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const config_path = try configPathFromHome(alloc, home);
    errdefer alloc.free(config_path);
    const result = try removeProfileServerFromPath(alloc, config_path, name);
    return .{
        .profile_path = config_path,
        .removed = result.removed,
        .warning = result.warning,
    };
}

pub fn loadRuntime(
    alloc: Allocator,
    workspace_root: []const u8,
    elicitation_capabilities: elicitation.Capabilities,
) !?*mcp_runtime.McpRuntime {
    var profile: std.ArrayList(McpServerConfig) = .empty;
    defer freeConfigs(alloc, &profile);
    if (io_mod.getenv("HOME")) |home| {
        const config_path = try configPathFromHome(alloc, home);
        defer alloc.free(config_path);
        profile = try loadConfigFromPath(alloc, config_path);
    }

    var choice_load = config_runtime.loadProjectMcpChoices(alloc, workspace_root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("mcp", "workspace MCP choices unavailable err={s}", .{@errorName(err)});
        return runtimeFromConfigs(alloc, &profile, elicitation_capabilities);
    };
    defer choice_load.deinit(alloc);
    for (choice_load.diagnostics.items) |diagnostic| {
        var name_buf: [256]u8 = undefined;
        debug_trace.logf(
            "mcp",
            "workspace MCP choice diagnostic cause={s} server={s}",
            .{
                @tagName(diagnostic.cause),
                if (diagnostic.server_name) |name|
                    debug_trace.terminalPreview(name_buf[0..], name)
                else
                    "none",
            },
        );
    }

    var workspace = try workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        choice_load.choices,
    );
    defer workspace.deinit(alloc);
    traceWorkspaceDiagnostics(workspace.diagnostics.items);

    var configs = try project_config.mergeNative(alloc, &profile, &workspace.configs);
    defer freeConfigs(alloc, &configs);
    var runtime = try runtimeFromConfigs(alloc, &configs, elicitation_capabilities);
    if (runtime == null and workspace.diagnostics.items.len > 0) {
        runtime = try alloc.create(mcp_runtime.McpRuntime);
        runtime.?.* = mcp_runtime.McpRuntime.initWithElicitation(
            alloc,
            elicitation_capabilities,
        );
    }
    if (runtime) |value| {
        value.takeWorkspaceDiagnostics(&workspace.diagnostics) catch |err| {
            value.deinit();
            alloc.destroy(value);
            return err;
        };
    }
    return runtime;
}

pub fn previewNativeWorkspaceAuthority(
    alloc: Allocator,
    workspace_root: []const u8,
) ![][]u8 {
    var choice_load = config_runtime.loadProjectMcpChoices(alloc, workspace_root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("mcp", "workspace MCP authority unavailable err={s}", .{@errorName(err)});
        return alloc.alloc([]u8, 0);
    };
    defer choice_load.deinit(alloc);
    var workspace = try workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        choice_load.choices,
    );
    defer workspace.deinit(alloc);
    return project_config.authorityNames(alloc, workspace.configs.items, .all);
}

fn traceWorkspaceDiagnostics(diagnostics: []const project_config.WorkspaceDiagnostic) void {
    for (diagnostics) |diagnostic| {
        var name_buf: [256]u8 = undefined;
        var variable_buf: [160]u8 = undefined;
        debug_trace.logf(
            "mcp",
            "workspace MCP config skipped cause={s} server={s} field={s} variable={s}",
            .{
                @tagName(diagnostic.cause),
                if (diagnostic.server_name) |name|
                    debug_trace.terminalPreview(name_buf[0..], name)
                else
                    "none",
                if (diagnostic.environment_field) |field| @tagName(field) else "none",
                if (diagnostic.environment_variable) |name|
                    debug_trace.terminalPreview(variable_buf[0..], name)
                else
                    "none",
            },
        );
    }
}

pub fn inspectProfileConfig(
    alloc: Allocator,
) error{OutOfMemory}!mcp_contract.ProfileConfigDiagnostic {
    const home = io_mod.getenv("HOME") orelse return .clear;
    const config_path = try configPathFromHome(alloc, home);
    defer alloc.free(config_path);

    var document = loadProfileDocumentFromPath(alloc, config_path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failed = err };
    };
    defer document.deinit(alloc);
    return if (document.diagnostic) |warning|
        .{ .warning = warning }
    else
        .clear;
}

pub fn inspectLocalConfig(
    alloc: Allocator,
    workspace_root: []const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    var profile: std.ArrayList(McpServerConfig) = .empty;
    defer freeConfigs(alloc, &profile);
    var profile_diagnostic: mcp_contract.ProfileConfigDiagnostic = .clear;
    if (io_mod.getenv("HOME")) |home| {
        const config_path = try configPathFromHome(alloc, home);
        defer alloc.free(config_path);
        var document = loadProfileDocumentFromPath(alloc, config_path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return emptyLocalInspection(alloc, .{ .failed = err }, @errorName(err));
        };
        defer document.deinit(alloc);
        profile_diagnostic = if (document.diagnostic) |warning|
            .{ .warning = warning }
        else
            .clear;
        profile = document.configs;
        document.configs = .empty;
    }

    var choice_load = config_runtime.loadProjectMcpChoices(alloc, workspace_root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return localInspectionFromConfigs(
            alloc,
            profile.items,
            &.{},
            profile_diagnostic,
            null,
        );
    };
    defer choice_load.deinit(alloc);
    var workspace = workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        choice_load.choices,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return emptyLocalInspection(
            alloc,
            profile_diagnostic,
            @errorName(err),
        );
    };
    defer workspace.deinit(alloc);
    var configs = project_config.mergeNative(
        alloc,
        &profile,
        &workspace.configs,
    ) catch return error.OutOfMemory;
    defer freeConfigs(alloc, &configs);
    return localInspectionFromConfigs(
        alloc,
        configs.items,
        workspace.diagnostics.items,
        profile_diagnostic,
        null,
    );
}

fn emptyLocalInspection(
    alloc: Allocator,
    profile_diagnostic: mcp_contract.ProfileConfigDiagnostic,
    inspection_error: ?[]const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    return localInspectionFromConfigs(
        alloc,
        &.{},
        &.{},
        profile_diagnostic,
        inspection_error,
    );
}

fn localInspectionFromConfigs(
    alloc: Allocator,
    configs: []const McpServerConfig,
    diagnostics: []const project_config.WorkspaceDiagnostic,
    profile_diagnostic: mcp_contract.ProfileConfigDiagnostic,
    inspection_error: ?[]const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    const servers = try alloc.alloc(mcp_health.ConfiguredServerSnapshot, configs.len);
    var servers_initialized: usize = 0;
    errdefer {
        for (servers[0..servers_initialized]) |*server| server.deinit(alloc);
        alloc.free(servers);
    }
    for (configs, 0..) |config, index| {
        var encoded_name = try text_utils.encodeTerminalSafe(alloc, config.name, 256);
        servers[index] = .{
            .configured_name = encoded_name.bytes,
            .source = config.source,
            .scope = config.scope,
            .workspace_admission = config.workspace_admission,
            .required = config.required,
            .transport = config.transport,
        };
        encoded_name = undefined;
        servers_initialized += 1;
    }

    const issues = try alloc.alloc(mcp_health.ConfigurationIssue, diagnostics.len);
    var issues_initialized: usize = 0;
    errdefer {
        for (issues[0..issues_initialized]) |*issue| issue.deinit(alloc);
        alloc.free(issues);
    }
    for (diagnostics, 0..) |diagnostic, index| {
        issues[index] = .{
            .message = try project_config.renderWorkspaceDiagnostic(alloc, diagnostic),
        };
        issues_initialized += 1;
    }
    return .{
        .profile_diagnostic = profile_diagnostic,
        .snapshot = .{
            .servers = servers,
            .configuration_issues = issues,
        },
        .inspection_error = inspection_error,
    };
}

fn runtimeFromConfigs(
    alloc: Allocator,
    configs: *std.ArrayList(McpServerConfig),
    elicitation_capabilities: elicitation.Capabilities,
) !?*mcp_runtime.McpRuntime {
    if (configs.items.len == 0) return null;

    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    errdefer alloc.destroy(runtime);
    runtime.* = mcp_runtime.McpRuntime.initWithElicitation(alloc, elicitation_capabilities);
    errdefer runtime.deinit();
    while (configs.items.len > 0) {
        var config = configs.orderedRemove(0);
        runtime.addServer(config) catch |err| {
            config.deinit(alloc);
            return err;
        };
    }

    return runtime;
}

pub fn loadConfigFromPath(alloc: Allocator, path: []const u8) !std.ArrayList(McpServerConfig) {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| {
        if (err == error.FileNotFound) return .empty;
        logConfigFailure("open", path, err);
        return err;
    };
    defer file.close(io_mod.getIo());

    const json_text = io_mod.readFileToEnd(alloc, &file, 1024 * 1024) catch |err| {
        logConfigFailure("read", path, err);
        return err;
    };
    defer alloc.free(json_text);

    return loadConfigFromJson(alloc, json_text) catch |err| {
        logConfigFailure("load", path, err);
        return err;
    };
}

fn addProfileServerToPath(
    alloc: Allocator,
    path: []const u8,
    intent: command_provider_contract.AddIntent,
) !?project_config.ProfileDiagnostic {
    const next = switch (intent) {
        .local => |local| try configFromCommandParts(alloc, local.name, local.command, local.args),
        .http => |http| blk: {
            const owned_name = try alloc.dupe(u8, http.name);
            errdefer alloc.free(owned_name);
            const owned_url = try alloc.dupe(u8, http.url);
            break :blk McpServerConfig{
                .name = owned_name,
                .transport = .http,
                .url = owned_url,
                .allow_stored_credentials = true,
            };
        },
    };
    return addOrReplaceServer(alloc, path, next);
}

fn addOrReplaceServer(
    alloc: Allocator,
    path: []const u8,
    next_value: McpServerConfig,
) !?project_config.ProfileDiagnostic {
    var next = next_value;
    var moved = false;
    errdefer if (!moved) next.deinit(alloc);

    var lock = try acquireProfileMutationLock(path);
    defer lock.release();
    var document = try loadProfileDocumentFromPath(alloc, path);
    defer document.deinit(alloc);
    if (!document.mutation_allowed) return error.McpConfigAmbiguousServerKey;
    const configs = &document.configs;
    const warning = document.diagnostic;

    for (configs.items) |*existing| {
        if (!std.mem.eql(u8, existing.name, next.name)) continue;
        existing.deinit(alloc);
        existing.* = next;
        moved = true;
        try saveConfigsToPath(alloc, path, configs.items);
        return warning;
    }

    try configs.append(alloc, next);
    moved = true;
    try saveConfigsToPath(alloc, path, configs.items);
    return warning;
}

const ProfileRemoveFromPathResult = struct {
    removed: bool,
    warning: ?project_config.ProfileDiagnostic = null,
};

fn removeProfileServerFromPath(
    alloc: Allocator,
    path: []const u8,
    name: []const u8,
) !ProfileRemoveFromPathResult {
    var lock = try acquireProfileMutationLock(path);
    defer lock.release();
    var document = try loadProfileDocumentFromPath(alloc, path);
    defer document.deinit(alloc);
    if (!document.mutation_allowed) return error.McpConfigAmbiguousServerKey;
    const configs = &document.configs;
    const warning = document.diagnostic;

    for (configs.items, 0..) |config, i| {
        if (!std.mem.eql(u8, config.name, name)) continue;
        var removed = configs.orderedRemove(i);
        removed.deinit(alloc);
        try saveConfigsToPath(alloc, path, configs.items);
        return .{ .removed = true, .warning = warning };
    }

    return .{ .removed = false, .warning = warning };
}

fn removeServerFromPath(alloc: Allocator, path: []const u8, name: []const u8) !bool {
    return (try removeProfileServerFromPath(alloc, path, name)).removed;
}

fn loadConfigFromJson(alloc: Allocator, json_text: []const u8) !std.ArrayList(McpServerConfig) {
    return project_config.parseProfileJson(alloc, json_text);
}

fn loadProfileDocumentFromPath(
    alloc: Allocator,
    path: []const u8,
) !project_config.ProfileParseResult {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer file.close(io_mod.getIo());
    const json_text = try io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
    defer alloc.free(json_text);
    return project_config.parseProfileDocument(alloc, json_text);
}

fn acquireProfileMutationLock(path: []const u8) !io_mod.TimedAdvisoryLock {
    const parent = std.fs.path.dirname(path) orelse return error.McpConfigPathInvalid;
    const grandparent = std.fs.path.dirname(parent) orelse return error.McpConfigPathInvalid;
    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.fs.path.basename(parent));
    defer dir.close();
    return io_mod.acquireTimedAdvisoryLock(&dir, "mcp.lock", profile_lock_deadline_ms);
}

fn saveConfigsToPath(alloc: Allocator, path: []const u8, configs: []const McpServerConfig) !void {
    const json = try renderConfigJson(alloc, configs);
    defer alloc.free(json);

    const parent = std.fs.path.dirname(path) orelse return error.McpConfigPathInvalid;
    const grandparent = std.fs.path.dirname(parent) orelse return error.McpConfigPathInvalid;

    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.fs.path.basename(parent));
    defer dir.close();
    try io_mod.durableReplaceVerified(alloc, &dir, std.fs.path.basename(path), json);
}

fn freeConfigs(alloc: Allocator, configs: *std.ArrayList(McpServerConfig)) void {
    for (configs.items) |config| {
        var mutable = config;
        mutable.deinit(alloc);
    }
    configs.deinit(alloc);
}

fn findConfig(configs: []const McpServerConfig, name: []const u8) ?*const McpServerConfig {
    for (configs) |*config| {
        if (std.mem.eql(u8, config.name, name)) return config;
    }
    return null;
}

noinline fn logConfigFailure(action: []const u8, path: []const u8, err: anyerror) void {
    debug_trace.logf(
        "mcp",
        "failed to {s} config {s}: {s}",
        .{ action, path, @errorName(err) },
    );
}

fn configFromCommandParts(
    alloc: Allocator,
    name: []const u8,
    command: []const u8,
    command_args: []const []const u8,
) !McpServerConfig {
    const args: [][]u8 = if (command_args.len > 0) try alloc.alloc([]u8, command_args.len) else &.{};
    errdefer if (args.len > 0) alloc.free(args);

    var parsed: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed) : (i += 1) alloc.free(args[i]);
    }

    for (command_args, 0..) |arg, i| {
        args[i] = try alloc.dupe(u8, arg);
        parsed += 1;
    }

    const owned_command = try alloc.dupe(u8, command);
    errdefer alloc.free(owned_command);

    return .{
        .name = try alloc.dupe(u8, name),
        .source = .profile,
        .scope = .profile,
        .command = owned_command,
        .args = args,
        .enabled = true,
    };
}

fn renderConfigJson(alloc: Allocator, configs: []const McpServerConfig) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"mcp\":{");
    for (configs, 0..) |config, i| {
        if (i > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(config.name, .{}, &out.writer);
        try out.writer.writeAll(":{");

        switch (config.transport) {
            .stdio => {
                try out.writer.writeAll("\"type\":\"local\",\"command\":[");
                try std.json.Stringify.value(try config.stdioCommand(), .{}, &out.writer);
                for (config.args) |arg| {
                    try out.writer.writeByte(',');
                    try std.json.Stringify.value(arg, .{}, &out.writer);
                }
                try out.writer.writeByte(']');
            },
            .sse => {
                try out.writer.writeAll("\"type\":\"sse\",\"url\":");
                try std.json.Stringify.value(try config.remoteUrl(), .{}, &out.writer);
            },
            .http => {
                try out.writer.writeAll("\"type\":\"http\",\"url\":");
                try std.json.Stringify.value(try config.remoteUrl(), .{}, &out.writer);
            },
        }

        try out.writer.print(",\"enabled\":{s}", .{if (config.enabled) "true" else "false"});
        if (config.required) try out.writer.writeAll(",\"required\":true");
        if (config.transport == .stdio or
            config.transport == .http or
            config.transport == .sse)
        {
            try out.writer.print(
                ",\"startup_timeout_ms\":{d},\"operation_timeout_ms\":{d}",
                .{ config.startup_timeout_ms, config.operation_timeout_ms },
            );
        }
        if (config.transport == .stdio) {
            try out.writer.print(",\"restart_limit\":{d}", .{config.restart_limit});
        }
        if (config.headers.len > 0) {
            try out.writer.writeAll(",\"headers\":{");
            for (config.headers, 0..) |header, header_i| {
                if (header_i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(header.name, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(header.value, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        if (config.header_env.len > 0) {
            try out.writer.writeAll(",\"header_env\":{");
            for (config.header_env, 0..) |ref, ref_i| {
                if (ref_i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(ref.name, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(ref.env, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        if (config.bearer_token_env) |env_name| {
            try out.writer.writeAll(",\"bearer_token_env\":");
            try std.json.Stringify.value(env_name, .{}, &out.writer);
        }
        if (config.auth) |auth| {
            try out.writer.writeAll(",\"oauth\":{");
            var first_auth = true;
            if (auth.resource) |field| try writeOptionalJsonField(&out.writer, &first_auth, "resource", field);
            if (auth.issuer) |field| try writeOptionalJsonField(&out.writer, &first_auth, "issuer", field);
            if (auth.client_id) |field| try writeOptionalJsonField(&out.writer, &first_auth, "client_id", field);
            if (auth.client_secret_env) |field| try writeOptionalJsonField(&out.writer, &first_auth, "client_secret_env", field);
            if (auth.client_metadata_url) |field| try writeOptionalJsonField(&out.writer, &first_auth, "client_metadata_url", field);
            if (auth.scopes.len > 0) {
                if (!first_auth) try out.writer.writeByte(',');
                first_auth = false;
                try out.writer.writeAll("\"scopes\":[");
                for (auth.scopes, 0..) |scope, scope_i| {
                    if (scope_i > 0) try out.writer.writeByte(',');
                    try std.json.Stringify.value(scope, .{}, &out.writer);
                }
                try out.writer.writeByte(']');
            }
            if (auth.callback_port) |port| {
                if (!first_auth) try out.writer.writeByte(',');
                first_auth = false;
                try out.writer.print("\"callback_port\":{d}", .{port});
            }
            try out.writer.writeByte('}');
        }
        if (config.env.len > 0) {
            try out.writer.writeAll(",\"environment\":{");
            for (config.env, 0..) |entry, env_i| {
                if (env_i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(entry.key, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(entry.value, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn writeOptionalJsonField(
    writer: *std.Io.Writer,
    first: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const TestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: ?[]const u8) !*TestHome {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestHome) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const ListFixture = struct {
    text: []const u8,
    calls: usize = 0,
    summary_calls: usize = 0,

    fn list(raw_ctx: *anyopaque, alloc: Allocator) ![]u8 {
        const self: *ListFixture = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        return alloc.dupe(u8, self.text);
    }

    fn summary(raw_ctx: *anyopaque, alloc: Allocator) ![]u8 {
        const self: *ListFixture = @ptrCast(@alignCast(raw_ctx));
        self.summary_calls += 1;
        return alloc.dupe(u8, "MCP: no servers configured. Use /mcp add <name> <command> [args...].");
    }
};

fn request(home: ?[]const u8, fixture: *ListFixture) CommandRequest {
    return .{
        .home = home,
        .list_ctx = @ptrCast(fixture),
        .summarize_servers = ListFixture.summary,
        .list_servers_and_tools = ListFixture.list,
    };
}

fn expectBlock(result: CommandResult, expected: []const u8) !void {
    switch (result.display) {
        .block => |text| try std.testing.expectEqualStrings(expected, text),
        .line => return error.TestExpectedEqual,
    }
}

fn expectLine(result: CommandResult, expected: []const u8, reload: bool) !void {
    switch (result.display) {
        .line => |text| try std.testing.expectEqualStrings(expected, text),
        .block => return error.TestExpectedEqual,
    }
    try std.testing.expectEqual(reload, result.reload);
}

fn tmpRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn tmpPath(alloc: Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ root, name });
}

test "saving MCP config replaces the file durably" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "{\"mcp\":{\"stale\":{\"command\":\"echo\"}}}";
    try writeTempFile(&tmp, "home/.fx/mcp.json", original);
    const path = try tmpDirPath(alloc, tmp.dir, "home/.fx/mcp.json");
    defer alloc.free(path);

    var fx_dir = try tmp.dir.openDir(io_mod.getIo(), "home/.fx", .{ .iterate = true });
    defer fx_dir.close(io_mod.getIo());

    // Seed a group-readable mode so the 0600 assertion below cannot pass just
    // because the developer's umask already produced it.
    {
        var seed = try fx_dir.openFile(io_mod.getIo(), "mcp.json", .{ .mode = .read_write });
        defer seed.close(io_mod.getIo());
        try seed.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o644));
    }

    // Hold the pre-save file open. A rename-over leaves this descriptor on the
    // old, unlinked inode; an in-place truncate would empty it instead, which
    // is the failure this save must not have.
    var held = try fx_dir.openFile(io_mod.getIo(), "mcp.json", .{});
    defer held.close(io_mod.getIo());

    try saveConfigsToPath(alloc, path, &.{});

    const held_stat = try held.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(u64, 0), held_stat.nlink);
    const held_bytes = try io_mod.readFileToEnd(alloc, &held, 4096);
    defer alloc.free(held_bytes);
    try std.testing.expectEqualStrings(original, held_bytes);

    const written = try readFileForTest(alloc, path);
    defer alloc.free(written);
    try std.testing.expect(std.mem.find(u8, written, "stale") == null);

    const stat = try fx_dir.statFile(io_mod.getIo(), "mcp.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);

    var it = fx_dir.iterate();
    var entries: usize = 0;
    while (try it.next(io_mod.getIo())) |entry| {
        entries += 1;
        try std.testing.expectEqualStrings("mcp.json", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
}

fn tmpDirPath(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, dir, sub_path);
}

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readFileForTest(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

test "built-in MCP runtime returns null when HOME is missing" {
    const alloc = std.testing.allocator;
    const home = try TestHome.install(alloc, null);
    defer home.deinit();

    try std.testing.expect(try loadRuntime(alloc, "/", .{}) == null);
}

test "MCP config diagnostic treats nonblocking profile states as clear" {
    const alloc = std.testing.allocator;

    {
        const test_home = try TestHome.install(alloc, null);
        defer test_home.deinit();

        switch (try inspectProfileConfig(alloc)) {
            .clear, .warning => {},
            .failed => return error.TestUnexpectedResult,
        }
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const home_path = try tmpDirPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);

    {
        const test_home = try TestHome.install(alloc, home_path);
        defer test_home.deinit();

        switch (try inspectProfileConfig(alloc)) {
            .clear, .warning => {},
            .failed => return error.TestUnexpectedResult,
        }
    }

    try writeTempFile(&tmp, "home/.fx/mcp.json", "{\"mcp\":{}}");
    {
        const test_home = try TestHome.install(alloc, home_path);
        defer test_home.deinit();

        switch (try inspectProfileConfig(alloc)) {
            .clear, .warning => {},
            .failed => return error.TestUnexpectedResult,
        }
    }
}

test "MCP config diagnostic preserves the startup parser error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "home/.fx/mcp.json", "{invalid json");
    const home_path = try tmpDirPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);

    const test_home = try TestHome.install(alloc, home_path);
    defer test_home.deinit();

    switch (try inspectProfileConfig(alloc)) {
        .clear, .warning => return error.TestUnexpectedResult,
        .failed => |err| try std.testing.expectEqual(error.McpConfigInvalidJson, err),
    }
    try std.testing.expectError(error.McpConfigInvalidJson, loadRuntime(alloc, "/", .{}));
}

test "MCP config diagnostic propagates allocation failure" {
    const alloc = std.testing.allocator;
    const test_home = try TestHome.install(alloc, "/tmp");
    defer test_home.deinit();

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        inspectProfileConfig(failing.allocator()),
    );
}

test "MCP config diagnostic preserves parser allocation failure" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        loadConfigFromJson(failing.allocator(), "{\"mcp\":{}}"),
    );
}

test "workspace MCP loading expands command args environment and HTTP headers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "workspace/.mcp.json",
        \\{"mcpServers":{"local":{"command":"${MCP_COMMAND}","args":["--token=${MCP_TOKEN}","${MCP_OPTIONAL:-fallback}"],"env":{"TOKEN":"${MCP_TOKEN}"}},"remote":{"type":"http","url":"https://example.test/mcp","headers":{"X-MCP-Token":"Bearer ${MCP_TOKEN}"}}}}
    );
    const workspace_root = try tmpDirPath(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace_root);

    const environment = try TestHome.install(alloc, "/tmp");
    defer environment.deinit();
    try environment.map.put("MCP_COMMAND", "node");
    try environment.map.put("MCP_TOKEN", "secret-value");
    var approved_names = [_][]u8{ @constCast("local"), @constCast("remote") };

    var result = try workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        .{ .approved = &approved_names },
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), result.configs.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    const local = result.configs.items[0];
    try std.testing.expectEqualStrings("node", local.command.?);
    try std.testing.expectEqualStrings("--token=secret-value", local.args[0]);
    try std.testing.expectEqualStrings("fallback", local.args[1]);
    try std.testing.expectEqualStrings("secret-value", local.env[0].value);
    const remote = result.configs.items[1];
    try std.testing.expectEqualStrings("Bearer secret-value", remote.headers[0].value);
}

test "workspace MCP missing environment variable is actionable and secret free" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "workspace/.mcp.json",
        \\{"mcpServers":{"secure":{"type":"http","url":"https://example.test/mcp","headers":{"X-MCP-Token":"secret-prefix-${MCP_REQUIRED_TOKEN}"}}}}
    );
    const workspace_root = try tmpDirPath(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace_root);
    const settings = try std.fmt.allocPrint(
        alloc,
        "{{\"workspaces\":{{\"{s}\":{{\"enableAllProjectMcpServers\":true}}}}}}",
        .{workspace_root},
    );
    defer alloc.free(settings);
    try writeTempFile(&tmp, "home/.fx/settings.json", settings);
    const home_path = try tmpDirPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const environment = try TestHome.install(alloc, home_path);
    defer environment.deinit();

    const runtime = try loadRuntime(alloc, workspace_root, .{}) orelse
        return error.TestUnexpectedResult;
    defer {
        runtime.deinit();
        alloc.destroy(runtime);
    }
    const listing = try runtime.listServersAndTools(alloc);
    defer alloc.free(listing);

    try std.testing.expect(std.mem.find(u8, listing, ".mcp.json") != null);
    try std.testing.expect(std.mem.find(u8, listing, "secure") != null);
    try std.testing.expect(std.mem.find(u8, listing, "MCP_REQUIRED_TOKEN") != null);
    try std.testing.expect(std.mem.find(u8, listing, "http_header") != null);
    try std.testing.expect(std.mem.find(u8, listing, "secret-prefix") == null);
}

test "built-in MCP runtime loads disabled configured servers without spawning" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/.fx/mcp.json",
        \\{"mcp":{"noop":{"type":"local","command":["node","server.js"],"enabled":false}}}
    );
    const home_path = try tmpDirPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);

    const home = try TestHome.install(alloc, home_path);
    defer home.deinit();

    const runtime = try loadRuntime(alloc, "/", .{}) orelse return error.TestUnexpectedResult;
    defer {
        runtime.deinit();
        alloc.destroy(runtime);
    }
    runtime.connectAll(builtin_tools.registry);

    try std.testing.expectEqual(@as(usize, 1), runtime.servers.items.len);
    try std.testing.expectEqual(mcp_runtime.ServerState.disabled, runtime.servers.items[0].state.load(.acquire));
    try std.testing.expectEqualStrings("noop", runtime.servers.items[0].config.name);
}

test "built-in MCP runtime loading leaves enabled servers disconnected" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/.fx/mcp.json",
        \\{"mcp":{"pending":{"type":"local","command":["false"],"enabled":true}}}
    );
    const home_path = try tmpDirPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);

    const home = try TestHome.install(alloc, home_path);
    defer home.deinit();

    const runtime = try loadRuntime(alloc, "/", .{}) orelse return error.TestUnexpectedResult;
    defer {
        runtime.deinit();
        alloc.destroy(runtime);
    }

    try std.testing.expectEqual(@as(usize, 1), runtime.servers.items.len);
    try std.testing.expectEqual(mcp_runtime.ServerState.disconnected, runtime.servers.items[0].state.load(.acquire));
}

test "built-in MCP runtime config transfer cleans its unvisited suffix on append failure" {
    const alloc = std.testing.allocator;
    var configs = try loadConfigFromJson(alloc,
        \\{"mcp":{"first":{"type":"local","command":["node"],"enabled":false},"second":{"type":"local","command":["node"],"environment":{"TOKEN":"value"},"enabled":false}}}
    );
    defer freeConfigs(alloc, &configs);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 1 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        runtimeFromConfigs(failing.allocator(), &configs, .{}),
    );
    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("second", configs.items[0].name);
}

test "built-in MCP runtime reserves active registry names" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const shell_server =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"server/discover"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"error":{"code":-32601,"message":"Method not found"}}'
        \\      ;;
        \\    *'"method":"initialize"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"shell","version":"0"}}}'
        \\      ;;
        \\    *'"method":"notifications/initialized"'*)
        \\      ;;
        \\    *'"method":"tools/list"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"tool","description":"Collision fixture","inputSchema":{"type":"object","properties":{}}}]}}'
        \\      ;;
        \\    *)
        \\      exit 3
        \\      ;;
        \\  esac
        \\done
    ;
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home_path = try tmpDirPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const config_path = try configPathFromHome(alloc, home_path);
    defer alloc.free(config_path);

    const args = [_][]const u8{ "-c", shell_server };
    const configs = [_]McpServerConfig{.{
        .name = "select",
        .command = "sh",
        .args = args[0..],
    }};
    try saveConfigsToPath(alloc, config_path, configs[0..]);

    const home = try TestHome.install(alloc, home_path);
    defer home.deinit();

    const runtime = try loadRuntime(alloc, "/", .{}) orelse return error.TestUnexpectedResult;
    defer {
        runtime.deinit();
        alloc.destroy(runtime);
    }
    runtime.connectAll(builtin_tools.registry);

    try std.testing.expectEqual(@as(usize, 1), runtime.servers.items.len);
    try std.testing.expectEqual(mcp_runtime.ServerState.ready, runtime.servers.items[0].state.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), runtime.servers.items[0].tool_catalog.tools.items.len);
    try std.testing.expectEqualStrings("mcp_select_tool_2", runtime.servers.items[0].tool_catalog.tools.items[0].prefixed_name);
}

test "built-in MCP command handles list path and reload requests" {
    const alloc = std.testing.allocator;
    var fixture = ListFixture{ .text = "No MCP servers configured.\n" };

    var list_result = try handleCommand(alloc, "", request(null, &fixture));
    defer list_result.deinit(alloc);
    try expectBlock(
        list_result,
        "MCP: no servers configured. Use /mcp add <name> <command> [args...].",
    );
    try std.testing.expectEqual(@as(usize, 1), fixture.summary_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expect(!list_result.reload);

    var details = try handleCommand(alloc, "list", request(null, &fixture));
    defer details.deinit(alloc);
    try expectBlock(details, "No MCP servers configured.\n");
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const expected_path = try configPathFromHome(alloc, home);
    defer alloc.free(expected_path);

    var path_result = try handleCommand(alloc, "path", request(home, &fixture));
    defer path_result.deinit(alloc);
    try expectLine(path_result, expected_path, false);

    var reload_result = try handleCommand(alloc, "reload", request(home, &fixture));
    defer reload_result.deinit(alloc);
    try expectLine(reload_result, "Evaluating trusted profile MCP configuration.", true);
}

test "built-in MCP feature commands require exact servers and preserve typed values" {
    const alloc = std.testing.allocator;
    const Fixture = struct {
        calls: usize = 0,

        fn list(_: *anyopaque, allocator: Allocator) ![]u8 {
            return allocator.dupe(u8, "servers\n");
        }

        fn read(raw: *anyopaque, allocator: Allocator, server: []const u8, uri: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqualStrings("server-a", server);
            try std.testing.expectEqualStrings("git+ssh://host/repo?ref=main#README", uri);
            return allocator.dupe(u8, "resource\n");
        }

        fn get(raw: *anyopaque, allocator: Allocator, server: []const u8, name: []const u8, arguments: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqualStrings("server-b", server);
            try std.testing.expectEqualStrings("shared", name);
            try std.testing.expectEqualStrings("{\"tone\":\"very brief\"}", arguments);
            return allocator.dupe(u8, "prompt\n");
        }

        fn complete(raw: *anyopaque, allocator: Allocator, server: []const u8, name: []const u8, argument: []const u8, value: []const u8) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqualStrings("server-b", server);
            try std.testing.expectEqualStrings("shared", name);
            try std.testing.expectEqualStrings("tone", argument);
            try std.testing.expectEqualStrings("very brief", value);
            return allocator.dupe(u8, "completion\n");
        }
    };
    var fixture = Fixture{};
    const feature_request = CommandRequest{
        .home = null,
        .list_ctx = @ptrCast(&fixture),
        .list_servers_and_tools = Fixture.list,
        .feature_ctx = @ptrCast(&fixture),
        .read_resource = Fixture.read,
        .get_prompt = Fixture.get,
        .complete_prompt = Fixture.complete,
    };

    var resource = try handleCommand(
        alloc,
        "resource read server-a git+ssh://host/repo?ref=main#README",
        feature_request,
    );
    defer resource.deinit(alloc);
    try expectBlock(resource, "resource\n");

    var prompt = try handleCommand(
        alloc,
        "prompt get server-b shared {\"tone\":\"very brief\"}",
        feature_request,
    );
    defer prompt.deinit(alloc);
    try expectBlock(prompt, "prompt\n");

    var completion = try handleCommand(
        alloc,
        "prompt complete server-b shared tone very brief",
        feature_request,
    );
    defer completion.deinit(alloc);
    try expectBlock(completion, "completion\n");

    var ambiguous = try handleCommand(alloc, "prompt get shared", feature_request);
    defer ambiguous.deinit(alloc);
    try expectLine(
        ambiguous,
        "Usage: /mcp prompt get <server> <name> [arguments-json]",
        false,
    );
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}

test "built-in MCP command mutates profile config and requests reload after save and remove" {
    const alloc = std.testing.allocator;
    var fixture = ListFixture{ .text = "" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const config_path = try configPathFromHome(alloc, home);
    defer alloc.free(config_path);

    var add_result = try handleCommand(alloc, "add fs node server.js", request(home, &fixture));
    defer add_result.deinit(alloc);
    try expectLine(add_result, "Saved MCP server 'fs'.", true);

    var configs = try loadConfigFromPath(alloc, config_path);
    defer freeConfigs(alloc, &configs);
    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("fs", configs.items[0].name);
    try std.testing.expectEqualStrings("node", try configs.items[0].stdioCommand());
    try std.testing.expectEqualStrings("server.js", configs.items[0].args[0]);

    var remove_result = try handleCommand(alloc, "remove fs", request(home, &fixture));
    defer remove_result.deinit(alloc);
    try expectLine(remove_result, "Removed MCP server 'fs'.", true);

    var missing_result = try handleCommand(alloc, "remove fs", request(home, &fixture));
    defer missing_result.deinit(alloc);
    try expectLine(missing_result, "MCP server 'fs' not found.", false);
}

test "built-in MCP command adds a remote HTTP server and preserves local add" {
    const alloc = std.testing.allocator;
    var fixture = ListFixture{ .text = "" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const config_path = try configPathFromHome(alloc, home);
    defer alloc.free(config_path);

    var remote = try handleCommand(
        alloc,
        "add --transport http prisma https://mcp.prisma.io/mcp",
        request(home, &fixture),
    );
    defer remote.deinit(alloc);
    try expectLine(remote, "Saved MCP server 'prisma'.", true);

    var local = try handleCommand(
        alloc,
        "add files node server.js",
        request(home, &fixture),
    );
    defer local.deinit(alloc);
    try expectLine(local, "Saved MCP server 'files'.", true);

    var configs = try loadConfigFromPath(alloc, config_path);
    defer freeConfigs(alloc, &configs);
    try std.testing.expectEqual(@as(usize, 2), configs.items.len);
    try std.testing.expectEqualStrings("prisma", configs.items[0].name);
    try std.testing.expectEqual(McpTransport.http, configs.items[0].transport);
    try std.testing.expectEqualStrings(
        "https://mcp.prisma.io/mcp",
        try configs.items[0].remoteUrl(),
    );
    try std.testing.expectEqualStrings("files", configs.items[1].name);
    try std.testing.expectEqual(McpTransport.stdio, configs.items[1].transport);
    try std.testing.expectEqualStrings("node", try configs.items[1].stdioCommand());
    try std.testing.expectEqualStrings("server.js", configs.items[1].args[0]);
}

test "built-in MCP command rejects invalid remote add forms without mutation" {
    const alloc = std.testing.allocator;
    var fixture = ListFixture{ .text = "" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const config_path = try configPathFromHome(alloc, home);
    defer alloc.free(config_path);

    for ([_][]const u8{
        "add --transport http prisma",
        "add --transport sse prisma https://mcp.prisma.io/mcp",
        "add --transport http prisma https://mcp.prisma.io/mcp extra",
    }) |command| {
        var result = try handleCommand(alloc, command, request(home, &fixture));
        defer result.deinit(alloc);
        try expectLine(
            result,
            "Usage: /mcp add <name> <command> [args...] or /mcp add --transport http <name> <url>",
            false,
        );
    }

    var configs = try loadConfigFromPath(alloc, config_path);
    defer freeConfigs(alloc, &configs);
    try std.testing.expectEqual(@as(usize, 0), configs.items.len);
}

test "saving MCP config refuses a symlinked target" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const external = "{\"mcp\":{\"fs\":{\"command\":\"node\"}}}";
    try writeTempFile(&tmp, "home/external.json", external);
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const external_path = try tmpDirPath(alloc, tmp.dir, "home/external.json");
    defer alloc.free(external_path);
    try tmp.dir.symLink(io_mod.getIo(), external_path, "home/.fx/mcp.json", .{ .is_directory = false });

    const path = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(external_path).?, ".fx", "mcp.json" });
    defer alloc.free(path);

    // The durable helper refuses a target that is not a plain private file, so
    // a symlinked config fails the save rather than writing through the link.
    try std.testing.expectError(error.DurablePathUnsafe, saveConfigsToPath(alloc, path, &.{}));

    const untouched = try readFileForTest(alloc, external_path);
    defer alloc.free(untouched);
    try std.testing.expectEqualStrings(external, untouched);
}

test "built-in MCP command reports a failed save instead of a missing server" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = ListFixture{ .text = "" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/external.json", "{\"mcp\":{\"fs\":{\"command\":\"node\"}}}");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const external_path = try tmpDirPath(alloc, tmp.dir, "home/external.json");
    defer alloc.free(external_path);
    try tmp.dir.symLink(io_mod.getIo(), external_path, "home/.fx/mcp.json", .{ .is_directory = false });

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    // The server loads through the symlink, so this is a real entry whose
    // removal cannot be persisted. It must not be reported as missing.
    var result = try handleCommand(alloc, "remove fs", request(home, &fixture));
    defer result.deinit(alloc);
    try expectLine(result, "Failed to remove MCP server 'fs': DurablePathUnsafe.", false);
}

test "adding an MCP server creates the profile directory privately" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = ListFixture{ .text = "" };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    var result = try handleCommand(alloc, "add fs node server.js", request(home, &fixture));
    defer result.deinit(alloc);
    try expectLine(result, "Saved MCP server 'fs'.", true);

    const dir_stat = try tmp.dir.statFile(io_mod.getIo(), "home/.fx", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o700), dir_stat.permissions.toMode() & 0o777);
    const file_stat = try tmp.dir.statFile(io_mod.getIo(), "home/.fx/mcp.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), file_stat.permissions.toMode() & 0o777);
}

test "built-in MCP command preserves usage and missing-home notices" {
    const alloc = std.testing.allocator;
    var fixture = ListFixture{ .text = "" };

    var no_home = try handleCommand(alloc, "path", request(null, &fixture));
    defer no_home.deinit(alloc);
    try expectLine(no_home, "HOME is not available.", false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    var add_usage_result = try handleCommand(alloc, "add server", request(home, &fixture));
    defer add_usage_result.deinit(alloc);
    try expectLine(add_usage_result, add_usage, false);

    var generic_usage = try handleCommand(alloc, "wat", request(home, &fixture));
    defer generic_usage.deinit(alloc);
    try expectLine(
        generic_usage,
        "Usage: /mcp [list|resource|prompt|add|remove|path|reload|auth|logout|trust]",
        false,
    );
}

test "MCP auth requires explicit browser confirmation and logout stays non-secret" {
    const Fixture = struct {
        validation_calls: usize = 0,
        auth_calls: usize = 0,
        logout_calls: usize = 0,
        logout_busy: bool = false,
        logout_repaired_entries: usize = 0,

        fn list(_: *anyopaque, alloc: Allocator) ![]u8 {
            return alloc.dupe(u8, "");
        }

        fn authenticate(
            raw: *anyopaque,
            name: []const u8,
        ) !command_provider_contract.AuthenticationStart {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.auth_calls += 1;
            if (std.mem.eql(u8, name, "busy")) return .busy;
            try std.testing.expectEqualStrings("remote", name);
            return .started;
        }

        fn validate(raw: *anyopaque, name: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.validation_calls += 1;
            if (std.mem.eql(u8, name, "local")) {
                return error.McpAuthenticationNotRemote;
            }
            if (!std.mem.eql(u8, name, "busy")) {
                try std.testing.expectEqualStrings("remote", name);
            }
        }

        fn logout(
            raw: *anyopaque,
            name: []const u8,
        ) !command_provider_contract.LogoutResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqualStrings("remote", name);
            self.logout_calls += 1;
            if (self.logout_busy) return .{ .busy = true };
            return .{
                .removed = true,
                .repaired_entries = self.logout_repaired_entries,
            };
        }
    };
    const alloc = std.testing.allocator;
    var fixture = Fixture{};
    const command_request = CommandRequest{
        .home = "/tmp",
        .list_ctx = @ptrCast(&fixture),
        .list_servers_and_tools = Fixture.list,
        .auth_ctx = @ptrCast(&fixture),
        .validate_authentication_server = Fixture.validate,
        .authenticate_server = Fixture.authenticate,
        .logout_server = Fixture.logout,
    };

    var prompt = try handleCommand(alloc, "auth remote", command_request);
    defer prompt.deinit(alloc);
    try expectLine(
        prompt,
        "Run /mcp auth remote --open to confirm opening your browser.",
        false,
    );
    try std.testing.expectEqual(@as(usize, 1), fixture.validation_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.auth_calls);

    var started = try handleCommand(
        alloc,
        "auth remote --open",
        command_request,
    );
    defer started.deinit(alloc);
    try expectLine(
        started,
        "Waiting for MCP authentication for 'remote'. You can continue using fx while the browser flow completes.",
        false,
    );
    try std.testing.expectEqual(@as(usize, 2), fixture.validation_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.auth_calls);

    var busy = try handleCommand(
        alloc,
        "auth busy --open",
        command_request,
    );
    defer busy.deinit(alloc);
    try expectLine(
        busy,
        "MCP authentication for 'busy' is already in progress or MCP configuration is reloading.",
        false,
    );
    try std.testing.expectEqual(@as(usize, 3), fixture.validation_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.auth_calls);

    var local = try handleCommand(alloc, "auth local", command_request);
    defer local.deinit(alloc);
    try expectLine(
        local,
        "MCP authentication for 'local' failed: McpAuthenticationNotRemote.",
        false,
    );
    try std.testing.expectEqual(@as(usize, 4), fixture.validation_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.auth_calls);

    fixture.logout_busy = true;
    var logout_busy = try handleCommand(alloc, "logout remote", command_request);
    defer logout_busy.deinit(alloc);
    try expectLine(
        logout_busy,
        "MCP authentication for 'remote' is still in progress. Wait for it to finish before logging out.",
        false,
    );
    fixture.logout_busy = false;

    var logged_out = try handleCommand(alloc, "logout remote", command_request);
    defer logged_out.deinit(alloc);
    try expectLine(logged_out, "Logged out of MCP server 'remote'.", false);
    try std.testing.expectEqual(@as(usize, 2), fixture.logout_calls);

    fixture.logout_repaired_entries = 2;
    var repaired = try handleCommand(alloc, "logout remote", command_request);
    defer repaired.deinit(alloc);
    try expectLine(
        repaired,
        "Logged out of MCP server 'remote'. Removed 2 unreadable MCP credential entries.",
        false,
    );
}

test "loadConfigFromJson parses canonical local config with command array" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"myserver":{"type":"local","command":["node","server.js"]}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqual(McpTransport.stdio, configs.items[0].transport);
    try std.testing.expectEqualStrings("myserver", configs.items[0].name);
    try std.testing.expectEqualStrings("node", try configs.items[0].stdioCommand());
    try std.testing.expectEqual(@as(usize, 1), configs.items[0].args.len);
    try std.testing.expectEqualStrings("server.js", configs.items[0].args[0]);
    try std.testing.expect(configs.items[0].enabled);
}

test "loadConfigFromJson parses local config with environment enabled and args" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"everything":{"type":"local","command":["npx","-y","@modelcontextprotocol/server-everything"],"enabled":false,"environment":{"TOKEN":"abc"}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("everything", configs.items[0].name);
    try std.testing.expectEqualStrings("npx", try configs.items[0].stdioCommand());
    try std.testing.expectEqual(@as(usize, 2), configs.items[0].args.len);
    try std.testing.expectEqualStrings("-y", configs.items[0].args[0]);
    try std.testing.expectEqualStrings("@modelcontextprotocol/server-everything", configs.items[0].args[1]);
    try std.testing.expectEqual(@as(usize, 1), configs.items[0].env.len);
    try std.testing.expectEqualStrings("TOKEN", configs.items[0].env[0].key);
    try std.testing.expectEqualStrings("abc", configs.items[0].env[0].value);
    try std.testing.expect(!configs.items[0].enabled);
}

test "loadConfigFromJson returns empty for empty config" {
    const alloc = std.testing.allocator;
    var configs = try loadConfigFromJson(alloc, "{}");
    defer freeConfigs(alloc, &configs);
    try std.testing.expectEqual(@as(usize, 0), configs.items.len);
}

test "loadConfigFromJson reports invalid json" {
    try std.testing.expectError(
        error.McpConfigInvalidJson,
        loadConfigFromJson(std.testing.allocator, "{not json"),
    );
}

test "loadConfigFromJson parses stdio type as stdio" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"stdio_server":{"type":"stdio","command":["node","server.js"]}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqual(McpTransport.stdio, configs.items[0].transport);
    try std.testing.expectEqualStrings("node", try configs.items[0].stdioCommand());
}

test "profile required policy defaults optional and roundtrips canonically" {
    const alloc = std.testing.allocator;
    var configs = try loadConfigFromJson(
        alloc,
        "{\"mcp\":{\"optional\":{\"type\":\"stdio\",\"command\":[\"node\"]},\"required\":{\"type\":\"stdio\",\"command\":[\"node\"],\"required\":true}}}",
    );
    defer freeConfigs(alloc, &configs);
    const optional_config = findConfig(configs.items, "optional").?;
    const required_config = findConfig(configs.items, "required").?;
    try std.testing.expect(!optional_config.required);
    try std.testing.expect(required_config.required);
    try std.testing.expectEqual(mcp_contract.ConfigSource.profile, optional_config.source);
    try std.testing.expectEqual(mcp_contract.ConfigScope.profile, optional_config.scope);

    const rendered = try renderConfigJson(alloc, configs.items);
    defer alloc.free(rendered);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "\"required\":true"));

    var reparsed = try loadConfigFromJson(alloc, rendered);
    defer freeConfigs(alloc, &reparsed);
    try std.testing.expect(!findConfig(reparsed.items, "optional").?.required);
    try std.testing.expect(findConfig(reparsed.items, "required").?.required);
}

test "profile config reports invalid required policy" {
    try std.testing.expectError(
        error.McpConfigInvalidRequired,
        loadConfigFromJson(
            std.testing.allocator,
            "{\"mcp\":{\"server\":{\"command\":[\"node\"],\"required\":\"yes\"}}}",
        ),
    );
}

test "loadConfigFromJson parses string command with args" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"string_command":{"type":"local","command":"node","args":["server.js","--flag"]}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("node", try configs.items[0].stdioCommand());
    try std.testing.expectEqual(@as(usize, 2), configs.items[0].args.len);
    try std.testing.expectEqualStrings("server.js", configs.items[0].args[0]);
    try std.testing.expectEqualStrings("--flag", configs.items[0].args[1]);
}

test "loadConfigFromJson parses sse config with url" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"remote":{"type":"sse","url":"https://mcp.example.com/rpc","enabled":true,"startup_timeout_ms":2500,"operation_timeout_ms":5000}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("remote", configs.items[0].name);
    try std.testing.expectEqual(McpTransport.sse, configs.items[0].transport);
    try std.testing.expectEqualStrings("https://mcp.example.com/rpc", try configs.items[0].remoteUrl());
    try std.testing.expect(configs.items[0].enabled);
    try std.testing.expectEqual(
        @as(u32, 2500),
        configs.items[0].startup_timeout_ms,
    );
    try std.testing.expectEqual(
        @as(u32, 5000),
        configs.items[0].operation_timeout_ms,
    );
}

test "loadConfigFromJson preserves HTTP identity headers and timeouts" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","headers":{"X-Workspace":"one"},"startup_timeout_ms":2500,"operation_timeout_ms":5000}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("api", configs.items[0].name);
    try std.testing.expectEqual(McpTransport.http, configs.items[0].transport);
    try std.testing.expectEqualStrings("https://api.example.com/mcp", try configs.items[0].remoteUrl());
    try std.testing.expectEqualStrings("X-Workspace", configs.items[0].headers[0].name);
    try std.testing.expectEqualStrings("one", configs.items[0].headers[0].value);
    try std.testing.expectEqual(@as(u32, 2500), configs.items[0].startup_timeout_ms);
    try std.testing.expectEqual(@as(u32, 5000), configs.items[0].operation_timeout_ms);
}

test "remote config keeps credential references and OAuth policy without secrets" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","header_env":{"X-Workspace":"MCP_WORKSPACE"},"bearer_token_env":"MCP_TOKEN","oauth":{"resource":"https://api.example.com/mcp","issuer":"https://login.example.com","client_id":"fx-client","client_secret_env":"MCP_CLIENT_SECRET","client_metadata_url":"https://client.example/fx.json","scopes":["tools.read","tools.call"]}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    const config = configs.items[0];
    try std.testing.expectEqual(@as(usize, 1), config.header_env.len);
    try std.testing.expectEqualStrings("X-Workspace", config.header_env[0].name);
    try std.testing.expectEqualStrings("MCP_WORKSPACE", config.header_env[0].env);
    try std.testing.expectEqualStrings("MCP_TOKEN", config.bearer_token_env.?);
    const auth = config.auth.?;
    try std.testing.expectEqualStrings(
        "https://api.example.com/mcp",
        auth.resource.?,
    );
    try std.testing.expectEqualStrings("https://login.example.com", auth.issuer.?);
    try std.testing.expectEqualStrings("fx-client", auth.client_id.?);
    try std.testing.expectEqualStrings("MCP_CLIENT_SECRET", auth.client_secret_env.?);
    try std.testing.expectEqual(@as(usize, 2), auth.scopes.len);
    try std.testing.expectEqual(@as(?u16, null), auth.callback_port);
}

test "remote config keeps a pinned OAuth callback port" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"slack":{"type":"http","url":"https://mcp.slack.com/mcp","oauth":{"client_id":"fx-client","callback_port":3118}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    const auth = configs.items[0].auth.?;
    try std.testing.expectEqualStrings("fx-client", auth.client_id.?);
    try std.testing.expectEqual(@as(?u16, 3118), auth.callback_port);
}

test "profile config rejects out-of-range OAuth callback ports" {
    const cases = [_][]const u8{
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","oauth":{"callback_port":null}}}}
        ,
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","oauth":{"callback_port":0}}}}
        ,
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","oauth":{"callback_port":65536}}}}
        ,
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","oauth":{"callback_port":"3118"}}}}
        ,
    };
    for (cases) |json| {
        try std.testing.expectError(
            error.McpConfigInvalidOAuth,
            loadConfigFromJson(std.testing.allocator, json),
        );
    }
}

test "profile config rejects a mixed set containing invalid client metadata URLs" {
    const json =
        \\{"mcp":{"loopback":{"type":"http","url":"https://api.example.com/mcp","oauth":{"client_metadata_url":"http://127.0.0.1:4321/client.json"}},"pathless":{"type":"http","url":"https://api.example.com/mcp","oauth":{"client_metadata_url":"https://client.example"}},"root":{"type":"http","url":"https://api.example.com/mcp","oauth":{"client_metadata_url":"https://client.example/"}},"valid":{"type":"http","url":"https://api.example.com/mcp","oauth":{"client_metadata_url":"https://client.example/fx.json"}}}}
    ;
    try std.testing.expectError(
        error.McpConfigInvalidOAuth,
        loadConfigFromJson(std.testing.allocator, json),
    );
}

test "profile config reports literal authorization secrets" {
    try std.testing.expectError(
        error.McpConfigInvalidHeaders,
        loadConfigFromJson(std.testing.allocator,
            \\{"mcp":{"unsafe":{"type":"http","url":"https://api.example.com/mcp","headers":{"Authorization":"Bearer secret-value"}}}}
        ),
    );
}

test "loadConfigFromJson rejects a mixed set containing insecure HTTP endpoints" {
    const json =
        \\{"mcp":{"insecure":{"type":"http","url":"http://example.com/mcp"},"reserved":{"type":"http","url":"https://api.example.com/mcp","headers":{"Mcp-Method":"override"}},"valid":{"type":"http","url":"http://localhost:4321/mcp"}}}
    ;
    try std.testing.expectError(
        error.McpConfigInvalidUrl,
        loadConfigFromJson(std.testing.allocator, json),
    );
}

test "loadConfigFromJson reports sse config without url" {
    const json =
        \\{"mcp":{"broken":{"type":"sse"}}}
    ;
    try std.testing.expectError(
        error.McpConfigMissingUrl,
        loadConfigFromJson(std.testing.allocator, json),
    );
}

test "loadConfigFromJson parses mixed stdio and sse configs" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"local":{"type":"local","command":["node","server.js"]},"remote":{"type":"sse","url":"https://mcp.example.com"}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 2), configs.items.len);
    try std.testing.expectEqual(McpTransport.stdio, configs.items[0].transport);
    try std.testing.expectEqualStrings("local", configs.items[0].name);
    try std.testing.expectEqual(McpTransport.sse, configs.items[1].transport);
    try std.testing.expectEqualStrings("remote", configs.items[1].name);
}

test "save and reload preserves mixed stdio and sse configs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(alloc, tmp);
    defer alloc.free(root);
    const path = try tmpPath(alloc, root, "mcp.json");
    defer alloc.free(path);

    var configs = try loadConfigFromJson(alloc,
        \\{"mcp":{"local":{"type":"local","command":["node","server.js"],"enabled":false},"remote":{"type":"sse","url":"https://mcp.example.com","enabled":true}}}
    );
    defer freeConfigs(alloc, &configs);

    try saveConfigsToPath(alloc, path, configs.items);

    var reloaded = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &reloaded);

    try std.testing.expectEqual(@as(usize, 2), reloaded.items.len);
    try std.testing.expectEqual(McpTransport.stdio, reloaded.items[0].transport);
    try std.testing.expectEqualStrings("node", try reloaded.items[0].stdioCommand());
    try std.testing.expect(!reloaded.items[0].enabled);
    try std.testing.expectEqual(McpTransport.sse, reloaded.items[1].transport);
    try std.testing.expectEqualStrings("https://mcp.example.com", try reloaded.items[1].remoteUrl());
}

test "save and reload preserves HTTP identity and headers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(alloc, tmp);
    defer alloc.free(root);
    const path = try tmpPath(alloc, root, "mcp.json");
    defer alloc.free(path);

    var configs = try loadConfigFromJson(alloc,
        \\{"mcp":{"local":{"type":"local","command":["node"]},"remote":{"type":"http","url":"https://api.example.com/mcp","headers":{"X-Workspace":"one"}}}}
    );
    defer freeConfigs(alloc, &configs);

    try saveConfigsToPath(alloc, path, configs.items);

    const rendered = try readFileForTest(alloc, path);
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "\"type\":\"http\"") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "\"type\":\"sse\"") == null);
    try std.testing.expect(std.mem.find(u8, rendered, "\"X-Workspace\":\"one\"") != null);

    var reloaded = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &reloaded);
    try std.testing.expectEqual(@as(usize, 2), reloaded.items.len);
    try std.testing.expectEqual(McpTransport.http, reloaded.items[1].transport);
    try std.testing.expectEqualStrings("https://api.example.com/mcp", try reloaded.items[1].remoteUrl());
    try std.testing.expectEqualStrings("X-Workspace", reloaded.items[1].headers[0].name);
    try std.testing.expectEqualStrings("one", reloaded.items[1].headers[0].value);
}

test "loadConfigFromJson parses env alias when environment is absent" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"server":{"type":"local","command":["node"],"env":{"TOKEN":"alias"}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqual(@as(usize, 1), configs.items[0].env.len);
    try std.testing.expectEqualStrings("TOKEN", configs.items[0].env[0].key);
    try std.testing.expectEqualStrings("alias", configs.items[0].env[0].value);
}

test "loadConfigFromJson prefers environment over env alias" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"server":{"type":"local","command":["node"],"environment":{"TOKEN":"primary"},"env":{"TOKEN":"alias"}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqual(@as(usize, 1), configs.items[0].env.len);
    try std.testing.expectEqualStrings("primary", configs.items[0].env[0].value);
}

test "loadConfigFromJson reports non-string environment values" {
    const json =
        \\{"mcp":{"server":{"type":"local","command":["node"],"environment":{"TOKEN":123}}}}
    ;
    try std.testing.expectError(
        error.McpConfigInvalidEnvironment,
        loadConfigFromJson(std.testing.allocator, json),
    );
}

test "stdio lifecycle policy parses defaults and roundtrips explicit values" {
    const alloc = std.testing.allocator;
    var defaults = try loadConfigFromJson(
        alloc,
        "{\"mcp\":{\"default\":{\"type\":\"local\",\"command\":[\"node\"]}}}",
    );
    defer freeConfigs(alloc, &defaults);
    try std.testing.expectEqual(
        mcp_contract.default_startup_timeout_ms,
        defaults.items[0].startup_timeout_ms,
    );
    try std.testing.expectEqual(
        mcp_contract.default_operation_timeout_ms,
        defaults.items[0].operation_timeout_ms,
    );
    try std.testing.expectEqual(
        mcp_contract.default_restart_limit,
        defaults.items[0].restart_limit,
    );

    var explicit = try loadConfigFromJson(
        alloc,
        "{\"mcp\":{\"bounded\":{\"type\":\"stdio\",\"command\":[\"node\"],\"startup_timeout_ms\":125,\"operation_timeout_ms\":250,\"restart_limit\":2}}}",
    );
    defer freeConfigs(alloc, &explicit);
    try std.testing.expectEqual(@as(u32, 125), explicit.items[0].startup_timeout_ms);
    try std.testing.expectEqual(@as(u32, 250), explicit.items[0].operation_timeout_ms);
    try std.testing.expectEqual(@as(u8, 2), explicit.items[0].restart_limit);

    const rendered = try renderConfigJson(alloc, explicit.items);
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "\"startup_timeout_ms\":125") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "\"operation_timeout_ms\":250") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "\"restart_limit\":2") != null);
}

test "invalid stdio lifecycle policy reports its field" {
    for ([_]struct { json: []const u8, expected: anyerror }{
        .{ .json = "{\"mcp\":{\"bad\":{\"type\":\"local\",\"command\":[\"node\"],\"startup_timeout_ms\":0}}}", .expected = error.McpConfigInvalidStartupTimeout },
        .{ .json = "{\"mcp\":{\"bad\":{\"type\":\"local\",\"command\":[\"node\"],\"operation_timeout_ms\":\"slow\"}}}", .expected = error.McpConfigInvalidOperationTimeout },
        .{ .json = "{\"mcp\":{\"bad\":{\"type\":\"local\",\"command\":[\"node\"],\"restart_limit\":256}}}", .expected = error.McpConfigInvalidRestartLimit },
    }) |case| {
        try std.testing.expectError(
            case.expected,
            loadConfigFromJson(std.testing.allocator, case.json),
        );
    }
}

test "addProfileServerToPath roundtrips local replacement and remove" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const path = try configPathFromHome(alloc, home);
    defer alloc.free(path);

    _ = try addProfileServerToPath(
        alloc,
        path,
        try command_provider_contract.parseAddIntent(&.{ "everything", "npx", "-y", "@modelcontextprotocol/server-everything" }),
    );

    var configs = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &configs);
    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("everything", configs.items[0].name);
    try std.testing.expectEqualStrings("npx", try configs.items[0].stdioCommand());

    _ = try addProfileServerToPath(
        alloc,
        path,
        try command_provider_contract.parseAddIntent(&.{ "everything", "node", "server.js" }),
    );

    var replaced = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &replaced);
    try std.testing.expectEqual(@as(usize, 1), replaced.items.len);
    try std.testing.expectEqualStrings("node", try replaced.items[0].stdioCommand());
    try std.testing.expectEqualStrings("server.js", replaced.items[0].args[0]);

    try std.testing.expect(try removeServerFromPath(alloc, path, "everything"));

    var after = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &after);
    try std.testing.expectEqual(@as(usize, 0), after.items.len);
}

test "profile mutation preserves canonical files with suspicious sibling maps" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const path = try configPathFromHome(alloc, home);
    defer alloc.free(path);
    const original =
        "{\"mcp\":{\"canonical\":{\"command\":\"one\"}},\"MCP-Servers\":{\"shadow\":{\"command\":\"two\"}},\"metadata\":{\"owner\":\"team\"}}";
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "home/.fx/mcp.json",
        .data = original,
    });

    try std.testing.expectError(
        error.McpConfigAmbiguousServerKey,
        addProfileServerToPath(
            alloc,
            path,
            try command_provider_contract.parseAddIntent(&.{ "new", "node" }),
        ),
    );

    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const after = try io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(original, after);
}

test "MCP add intent rejects invalid server names" {
    for ([_][]const u8{ "", "bad/name", "bad name", "bad.name" }) |name| {
        try std.testing.expectError(
            error.McpInvalidServerName,
            command_provider_contract.parseAddIntent(&.{ name, "node" }),
        );
    }
}

test "removeServerFromPath remains permissive for odd legacy names" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(alloc, tmp);
    defer alloc.free(root);
    const path = try tmpPath(alloc, root, "mcp.json");
    defer alloc.free(path);

    var configs = try loadConfigFromJson(alloc,
        \\{"mcp":{"legacy/name":{"type":"local","command":["node"]}}}
    );
    defer freeConfigs(alloc, &configs);
    try saveConfigsToPath(alloc, path, configs.items);

    try std.testing.expect(try removeServerFromPath(alloc, path, "legacy/name"));

    var after = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &after);
    try std.testing.expectEqual(@as(usize, 0), after.items.len);
}

test "freeConfigs accepts an empty ArrayList" {
    const alloc = std.testing.allocator;
    var configs: std.ArrayList(McpServerConfig) = .empty;
    freeConfigs(alloc, &configs);
}
