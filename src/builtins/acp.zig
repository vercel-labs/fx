const std = @import("std");

const agent_catalog = @import("../core/acp_client/agent_catalog.zig");
const acp_config = @import("../core/acp_client/config.zig");
const acp_runtime = @import("../core/acp_client/runtime.zig");
const command_provider_contract = @import("../core/acp_client/command_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");

const Allocator = std.mem.Allocator;
const CommandRequest = command_provider_contract.Request;
const CommandResult = command_provider_contract.Result;

pub const command_provider = command_provider_contract.Provider{ .handle_fn = handleCommand };

fn handleCommand(alloc: Allocator, rest: []const u8, command_request: CommandRequest) !CommandResult {
    const trimmed = std.mem.trim(u8, rest, " \t");

    const home = command_request.home orelse return lineLiteral(alloc, "HOME is not available.", false);
    const config_path = try profile_paths.acpConfigPath(alloc, home);
    defer alloc.free(config_path);

    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) {
        return handleList(alloc, config_path);
    }
    if (std.mem.eql(u8, trimmed, "path")) {
        return lineParts(alloc, &.{config_path}, false);
    }
    if (std.mem.startsWith(u8, trimmed, "add")) {
        return handleAdd(alloc, std.mem.trimStart(u8, trimmed[3..], " \t"), config_path, command_request);
    }
    if (std.mem.startsWith(u8, trimmed, "remove ")) {
        const name = std.mem.trim(u8, trimmed[7..], " \t");
        if (name.len == 0) return usageLine(alloc);
        return handleRemove(alloc, name, config_path);
    }
    if (std.mem.startsWith(u8, trimmed, "run ")) {
        const remainder = std.mem.trimStart(u8, trimmed[4..], " \t");
        const space = std.mem.indexOfAny(u8, remainder, " \t") orelse
            return lineLiteral(alloc, "Usage: /acp run <agent>[/model] <prompt>", false);
        const name = remainder[0..space];
        const prompt = std.mem.trimStart(u8, remainder[space..], " \t");
        if (name.len == 0 or prompt.len == 0) {
            return lineLiteral(alloc, "Usage: /acp run <agent>[/model] <prompt>", false);
        }
        return handleRun(alloc, name, prompt, config_path, command_request);
    }
    return usageLine(alloc);
}

/// Names of enabled configured agents, for surfacing in the model picker.
/// Caller frees with freeAgentNames. Load failures yield an empty list.
pub fn enabledAgentNames(alloc: Allocator, home: ?[]const u8) ![][]u8 {
    const home_dir = home orelse return try alloc.alloc([]u8, 0);
    const config_path = try profile_paths.acpConfigPath(alloc, home_dir);
    defer alloc.free(config_path);
    var configs = acp_config.loadConfigFromPath(alloc, config_path) catch
        return try alloc.alloc([]u8, 0);
    defer acp_config.freeConfigs(alloc, &configs);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    for (configs.items) |config| {
        if (!config.enabled) continue;
        try names.append(alloc, try alloc.dupe(u8, config.name));
        // Cached model ids expand to one picker entry per model.
        for (config.models) |model_id| {
            try names.append(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ config.name, model_id }));
        }
    }
    return names.toOwnedSlice(alloc);
}

pub fn freeAgentNames(alloc: Allocator, names: [][]u8) void {
    for (names) |name| alloc.free(name);
    alloc.free(names);
}

/// Cached reasoning-effort value ids for one configured agent, for the
/// /model picker's effort stage. Caller frees with freeAgentNames.
pub fn agentEffortLabels(alloc: Allocator, home: ?[]const u8, agent: []const u8) ![][]u8 {
    const home_dir = home orelse return try alloc.alloc([]u8, 0);
    const config_path = try profile_paths.acpConfigPath(alloc, home_dir);
    defer alloc.free(config_path);
    var configs = acp_config.loadConfigFromPath(alloc, config_path) catch
        return try alloc.alloc([]u8, 0);
    defer acp_config.freeConfigs(alloc, &configs);
    for (configs.items) |config| {
        if (!std.ascii.eqlIgnoreCase(config.name, agent)) continue;
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |value| alloc.free(value);
            out.deinit(alloc);
        }
        for (config.efforts) |effort| try out.append(alloc, try alloc.dupe(u8, effort));
        return out.toOwnedSlice(alloc);
    }
    return try alloc.alloc([]u8, 0);
}

fn usageLine(alloc: Allocator) !CommandResult {
    return lineLiteral(alloc, "Usage: /acp [list|add|remove <name>|run <name>[/model] <prompt>|path]", false);
}

fn handleList(alloc: Allocator, config_path: []const u8) !CommandResult {
    var configs = acp_config.loadConfigFromPath(alloc, config_path) catch |err|
        return configLoadFailure(alloc, err);
    defer acp_config.freeConfigs(alloc, &configs);

    if (configs.items.len == 0) {
        return lineLiteral(
            alloc,
            "No ACP agents configured. Run /acp add to detect and add one.",
            false,
        );
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("ACP agents ({d}):\n", .{configs.items.len});
    for (configs.items) |config| {
        try out.writer.print("  {s} :: {s}", .{ config.name, config.command });
        for (config.args) |arg| try out.writer.print(" {s}", .{arg});
        if (!config.enabled) try out.writer.writeAll(" (disabled)");
        try out.writer.writeByte('\n');
    }
    return .{ .display = .{ .block = try out.toOwnedSlice() } };
}

fn handleAdd(
    alloc: Allocator,
    rest: []const u8,
    config_path: []const u8,
    command_request: CommandRequest,
) !CommandResult {
    // /acp add            -> scan the curated catalog against PATH
    // /acp add <id>       -> add one catalog entry by id or name
    // /acp add <n> <cmd> [args...] -> manual entry (name command args...)
    if (rest.len == 0) {
        return handleAddScan(alloc, config_path);
    }

    var tokens = std.mem.tokenizeAny(u8, rest, " \t");
    const first = tokens.next() orelse return usageLine(alloc);
    const second = tokens.next();

    if (second == null) {
        return handleAddCatalogEntry(alloc, first, config_path, command_request);
    }

    const name = first;
    const command = second.?;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    while (tokens.next()) |token| try args.append(alloc, token);
    acp_config.addOrReplaceAgent(alloc, config_path, name, command, args.items, &.{}) catch |err| {
        return lineParts(alloc, &.{ "Adding agent failed: ", @errorName(err), "." }, true);
    };
    startWarmup(alloc, command_request, config_path, .{
        .name = name,
        .command = command,
        .args = args.items,
        .env = &.{},
    });
    return lineParts(
        alloc,
        &.{ "Agent '", name, "' saved; connecting in the background to fetch its models." },
        false,
    );
}

/// Kicks off a background connect for a just-saved agent so its models land
/// in acp.json and the session is warm before the first prompt. Best effort:
/// silently skipped when the host cannot run interactive turns.
fn startWarmup(
    alloc: Allocator,
    command_request: CommandRequest,
    config_path: []const u8,
    agent_config: acp_runtime.AgentConfig,
) void {
    const store_ptr = command_request.acp_session_store orelse return;
    const run_ctx = command_request.acp_run_ctx orelse return;
    const request_permission = command_request.request_permission orelse return;
    const report_update = command_request.report_agent_update orelse return;
    const turn_runner = @import("../core/acp_client/turn_runner.zig");
    const store: *turn_runner.SessionStore = @ptrCast(@alignCast(store_ptr));
    turn_runner.startWarmup(alloc, store, agent_config, .{
        .ctx = run_ctx,
        .report_update = report_update,
        .request_permission = request_permission,
        .cwd = command_request.cwd orelse ".",
    }, config_path) catch |err| {
        debug_trace.logf("acp", "warmup spawn failed agent={s} err={s}", .{ agent_config.name, @errorName(err) });
    };
}

fn handleAddScan(alloc: Allocator, config_path: []const u8) !CommandResult {
    _ = config_path;
    const detections = agent_catalog.detectAll(alloc) catch |err|
        return lineParts(alloc, &.{ "Scanning for ACP agents failed: ", @errorName(err), "." }, true);
    defer {
        for (detections) |*detection| detection.deinit(alloc);
        alloc.free(detections);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var installed: usize = 0;
    var installable: usize = 0;
    for (detections) |*detection| {
        switch (detection.status) {
            .installed_local => installed += 1,
            .installable_via_npx => installable += 1,
            .unavailable => {},
        }
    }
    try out.writer.print("Detected ACP agents ({d} installed, {d} via npx):\n", .{ installed, installable });
    for (detections) |*detection| {
        switch (detection.status) {
            .installed_local => try out.writer.print("  {s} — {s}\n", .{
                detection.entry.display_name,
                detection.resolved_command orelse detection.entry.path_candidates[0],
            }),
            .installable_via_npx => try out.writer.print("  {s} — npx {s}\n", .{
                detection.entry.display_name,
                detection.entry.npx_package orelse "",
            }),
            .unavailable => {},
        }
    }
    try out.writer.writeAll("\nAdd one with /acp add <name>, for example /acp add claude-acp.");
    return .{ .display = .{ .block = try out.toOwnedSlice() } };
}

fn handleAddCatalogEntry(
    alloc: Allocator,
    id_or_name: []const u8,
    config_path: []const u8,
    command_request: CommandRequest,
) !CommandResult {
    const detections = agent_catalog.detectAll(alloc) catch |err|
        return lineParts(alloc, &.{ "Scanning for ACP agents failed: ", @errorName(err), "." }, true);
    defer {
        for (detections) |*detection| detection.deinit(alloc);
        alloc.free(detections);
    }

    var chosen: ?*agent_catalog.Detection = null;
    for (detections) |*detection| {
        // Case-insensitive, and forgiving about the -acp suffix: "codex",
        // "Codex", and "codex-acp" all match the codex-acp entry.
        if (std.ascii.eqlIgnoreCase(detection.entry.id, id_or_name) or
            std.ascii.eqlIgnoreCase(detection.entry.display_name, id_or_name) or
            (std.mem.endsWith(u8, detection.entry.id, "-acp") and
                std.ascii.eqlIgnoreCase(detection.entry.id[0 .. detection.entry.id.len - "-acp".len], id_or_name)))
        {
            chosen = detection;
            break;
        }
    }
    const detection = chosen orelse
        return lineParts(alloc, &.{ "Unknown agent '", id_or_name, "'. Run /acp add to scan." }, false);

    switch (detection.status) {
        .unavailable => return lineParts(
            alloc,
            &.{ "Agent '", detection.entry.display_name, "' is not installed and has no npx fallback." },
            true,
        ),
        .installed_local => {
            acp_config.addOrReplaceAgent(
                alloc,
                config_path,
                detection.entry.id,
                detection.resolved_command.?,
                detection.entry.launch_args,
                detection.entry.env,
            ) catch |err| {
                return lineParts(alloc, &.{ "Saving agent failed: ", @errorName(err), "." }, true);
            };
            startWarmup(alloc, command_request, config_path, .{
                .name = detection.entry.id,
                .command = detection.resolved_command.?,
                .args = detection.entry.launch_args,
                .env = detection.entry.env,
            });
            return lineParts(
                alloc,
                &.{ "Agent '", detection.entry.display_name, "' saved from local install; connecting in the background to fetch its models." },
                false,
            );
        },
        .installable_via_npx => {
            const launch_args = agent_catalog.npxLaunchArgs(alloc, detection.entry) catch |err|
                return lineParts(alloc, &.{ "Preparing npx launch failed: ", @errorName(err), "." }, true);
            acp_config.addOrReplaceAgent(
                alloc,
                config_path,
                detection.entry.id,
                "npx",
                launch_args,
                detection.entry.env,
            ) catch |err| {
                return lineParts(alloc, &.{ "Saving agent failed: ", @errorName(err), "." }, true);
            };
            startWarmup(alloc, command_request, config_path, .{
                .name = detection.entry.id,
                .command = "npx",
                .args = launch_args,
                .env = detection.entry.env,
            });
            return lineParts(
                alloc,
                &.{ "Agent '", detection.entry.display_name, "' saved via npx; downloading and connecting in the background to fetch its models." },
                false,
            );
        },
    }
}

fn handleRemove(alloc: Allocator, name: []const u8, config_path: []const u8) !CommandResult {
    const removed = acp_config.removeAgentFromPath(alloc, config_path, name) catch |err|
        return lineParts(alloc, &.{ "Removing agent failed: ", @errorName(err), "." }, true);
    if (!removed) {
        return lineParts(alloc, &.{ "No agent named '", name, "' is configured." }, false);
    }
    return lineParts(alloc, &.{ "Removed agent '", name, "'." }, false);
}

fn handleRun(
    alloc: Allocator,
    name_and_model: []const u8,
    prompt_text: []const u8,
    config_path: []const u8,
    command_request: CommandRequest,
) !CommandResult {
    // "agent" or "agent/model" — model ids come from the agent's own list.
    const slash = std.mem.indexOfScalar(u8, name_and_model, '/');
    const name = if (slash) |i| name_and_model[0..i] else name_and_model;
    const model: ?[]const u8 = if (slash) |i|
        (if (name_and_model.len > i + 1) name_and_model[i + 1 ..] else null)
    else
        null;

    var configs = acp_config.loadConfigFromPath(alloc, config_path) catch |err|
        return configLoadFailure(alloc, err);
    defer acp_config.freeConfigs(alloc, &configs);

    var chosen: ?*acp_config.AcpAgentConfig = null;
    for (configs.items) |*config| {
        if (std.ascii.eqlIgnoreCase(config.name, name)) {
            chosen = config;
            break;
        }
    }
    const config = chosen orelse
        return lineParts(alloc, &.{ "No agent named '", name, "' is configured. Run /acp add." }, false);
    if (!config.enabled) {
        return lineParts(alloc, &.{ "Agent '", name, "' is disabled." }, false);
    }

    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(alloc);
    for (config.env) |pair| try env_list.append(alloc, pair);

    const run_ctx = command_request.acp_run_ctx orelse
        return lineLiteral(alloc, "ACP agent turns are unavailable in this context.", true);
    const request_permission = command_request.request_permission orelse
        return lineLiteral(alloc, "Interactive permission approval is unavailable here.", true);
    const report_update = command_request.report_agent_update orelse
        return lineLiteral(alloc, "Agent update streaming is unavailable here.", true);
    const session_store_ptr = command_request.acp_session_store orelse
        return lineLiteral(alloc, "ACP agent turns are unavailable in this context.", true);

    const agent_config = acp_runtime.AgentConfig{
        .name = config.name,
        .command = config.command,
        .args = config.args,
        .env = env_list.items,
    };

    const turn_runner = @import("../core/acp_client/turn_runner.zig");
    const session_store: *turn_runner.SessionStore = @ptrCast(@alignCast(session_store_ptr));

    const turn = turn_runner.startAgentTurn(
        alloc,
        session_store,
        agent_config,
        prompt_text,
        model,
        command_request.effort_label,
        .{
            .ctx = run_ctx,
            .report_update = report_update,
            .request_permission = request_permission,
            .cwd = command_request.cwd orelse ".",
        },
    ) catch |err| {
        debug_trace.logf("acp", "start agent turn failed agent={s} err={s}", .{ name, @errorName(err) });
        return lineParts(alloc, &.{ "Starting agent turn failed: ", @errorName(err), "." }, true);
    };

    if (command_request.on_turn_started) |on_turn_started| {
        on_turn_started(command_request.turn_started_ctx orelse run_ctx, @ptrCast(turn));
    }

    // No banner on success: the turn streams like a normal provider reply
    // (empty notice bodies are dropped by the transcript writer).
    return .{ .display = .{ .line = try alloc.dupe(u8, "") } };
}

fn configLoadFailure(alloc: Allocator, err: anyerror) !CommandResult {
    return lineParts(
        alloc,
        &.{ "Loading ~/.fx/acp.json failed: ", @errorName(err), ". Fix the file or remove it." },
        true,
    );
}

fn lineLiteral(alloc: Allocator, text: []const u8, warning: bool) !CommandResult {
    return .{
        .display = .{ .line = try alloc.dupe(u8, text) },
        .warning = warning,
    };
}

fn lineParts(alloc: Allocator, parts: []const []const u8, warning: bool) !CommandResult {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (parts) |part| try out.writer.writeAll(part);
    return .{
        .display = .{ .line = try out.toOwnedSlice() },
        .warning = warning,
    };
}
