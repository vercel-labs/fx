const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const mcp_servers = @import("mcp_servers.zig");
const server = @import("server.zig");
const session_test_controls = @import("session_test_controls.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_store = @import("../core/session/session_store.zig");
const js_host_session_store = @import("../core/session/js_host_session_store.zig");
const session_runtime = @import("../core/session/session.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const host = @import("../core/hosts/host.zig");
const host_target = @import("../core/hosts/target.zig");
const credentials = @import("../core/auth/credentials.zig");
const model_provider = @import("../core/config/model_provider.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const subagent_resume_admission = @import("../core/subagent/resume_admission.zig");
const types = @import("../core/shared/types.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const command_specs = @import("../core/slash_commands/command_specs.zig");
const test_builtin_gateway = if (builtin.is_test)
    @import("../builtins/gateway.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;
const writeJsonStr = jsonrpc.writeJsonStr;

pub fn handleNewWasmSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    try server.releaseActiveSession(state);

    var durable = try freshAcpState(state, alloc);
    var durable_owned = true;
    defer if (durable_owned) durable.deinit(alloc);
    const session_id = try alloc.dupe(u8, durable.id);
    var session_id_owned = true;
    defer if (session_id_owned) alloc.free(session_id);
    const model = try alloc.dupe(u8, durable.preferences.model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model);
    var session_rt = session_runtime.SessionRuntime.init(
        state.cfg.max_history_turns,
        state.cfg.gateway_provider.generation_usage,
    );
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    const revision = js_host_session_store.commit(alloc, durable, null) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to create session",
        });
    var revision_owned = true;
    defer if (revision_owned) alloc.free(revision);

    state.active_session = .{
        .session_id = session_id,
        .wasm_state = durable,
        .wasm_revision = revision,
        .model = model,
        .provider = durable.preferences.provider,
        .mode = state.cfg.mode_registry.default_mode_id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = state.fast_mode,
        .effort = state.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = state.permission_mode,
        .permission_rules = state.permission_rules,
        .session_rt = session_rt,
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    durable_owned = false;
    revision_owned = false;
    session_id_owned = false;
    model_owned = false;
    session_rt_owned = false;

    try writeNewSessionResponse(state, alloc, msg, session_id);
}

pub fn commitWasmSessionLocked(alloc: Allocator, session: *server.ActiveSessionState) !void {
    const base = if (session.wasm_state) |*value| value else return error.SessionPersistenceUnavailable;
    var next = try base.dupe(alloc);
    var next_owned = true;
    defer if (next_owned) next.deinit(alloc);
    const history = try session.session_rt.snapshotHistory(alloc);
    types.freeHistoryTurnSlice(alloc, next.history);
    next.history = history;
    const permission_state = try session.session_rt.snapshotPermissionState(alloc);
    next.permission_state.deinit(alloc);
    next.permission_state = permission_state;
    next.context_history_start = session.session_rt.context_history_start;
    next.conversation_language = session.session_rt.languageSnapshot();
    next.updated_at_ms = io_mod.milliTimestamp();
    alloc.free(next.preferences.model);
    next.preferences.model = try alloc.dupe(u8, session.model);
    next.preferences.provider = session.provider;
    next.preferences.effort = session.effort;
    next.preferences.fast_mode = session.fast_mode;
    const usage = try session.session_rt.usage.snapshot(alloc);
    if (next.usage) |*old| old.deinit(alloc);
    next.usage = usage;

    const revision = try js_host_session_store.commit(alloc, next, session.wasm_revision);
    if (session.wasm_revision) |old| alloc.free(old);
    session.wasm_revision = revision;
    base.deinit(alloc);
    session.wasm_state = next;
    next_owned = false;
}

pub fn commitWasmSession(alloc: Allocator, session: *server.ActiveSessionState) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    try commitWasmSessionLocked(alloc, session);
}

pub fn handleNewSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    var mcp_configs = mcp_servers.parse(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = mcp_servers.parseErrorMessage(err),
        }),
    };
    defer mcp_configs.deinit(alloc);
    if (!state.cfg.allow_acp_mcp and mcp_configs.items.items.len > 0) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "MCP servers are unavailable in this runtime",
        });
    }
    var mcp_preparation = try mcp_servers.prepare(
        alloc,
        &mcp_configs,
        state.client_elicitation,
        server.legacyUrlCompletionSink(state),
    );
    defer mcp_preparation.deinit(alloc);
    switch (mcp_preparation) {
        .ready => {},
        .failed => |message| return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
        }),
    }
    const session_mcp = mcp_preparation.takeRuntime();
    var session_mcp_owned = true;
    defer if (session_mcp_owned) {
        if (session_mcp) |runtime| {
            runtime.deinit();
            alloc.destroy(runtime);
        }
    };

    var store = (if (state.cfg.home_override) |home|
        session_store.Store.initFromHome(alloc, home, state.workspace_root)
    else
        session_store.Store.init(alloc, state.workspace_root)) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Session store not available",
        });
    var store_owned = true;
    defer if (store_owned) store.deinit(alloc);

    var initial = try freshAcpState(state, alloc);
    defer initial.deinit(alloc);
    var writable = store.startWritableSessionWithOptions(
        alloc,
        initial,
        session_test_controls.logOptions(),
    ) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.internal_error, .message = "Failed to create session" });
    var writable_owned = true;
    defer if (writable_owned) writable.deinit(alloc);

    const session_id = try alloc.dupe(u8, writable.active_id);
    var session_id_owned = true;
    defer if (session_id_owned) alloc.free(session_id);
    const model_copy = try alloc.dupe(u8, state.selected_model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model_copy);
    const session_dir = try session_store.sessionDirPath(alloc, store.sessions_dir, writable.active_id);
    defer alloc.free(session_dir);
    var session_rt = session_runtime.SessionRuntime.init(
        state.cfg.max_history_turns,
        state.cfg.gateway_provider.generation_usage,
    );
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    _ = try session_rt.initializeProfileUsage(alloc, io_mod.getenv("HOME"));
    if (writable.state.usage) |usage| {
        try session_rt.usage.restore(
            alloc,
            usage,
            writable.state.created_at_ms,
        );
    } else {
        session_rt.usage.restoreLegacyWallDuration(
            writable.state.created_at_ms,
        );
    }
    session_rt.configureWebFetchArtifacts(alloc, session_dir);
    server.cancelAndReapActivePrompt(state);
    activateSession(state, store, .{
        .session_id = session_id,
        .writable = writable,
        .model = model_copy,
        .provider = state.provider,
        .fast_mode = state.fast_mode,
        .effort = state.effort,
        .session_rt = session_rt,
        .mcp = session_mcp,
    }) catch {
        _ = store.discardPristineStartedSession(alloc, &writable);
        writable_owned = false;
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to save active session",
        });
    };
    writable_owned = false;
    store_owned = false;
    session_id_owned = false;
    model_owned = false;
    session_rt_owned = false;
    session_mcp_owned = false;

    try writeNewSessionResponse(state, alloc, msg, session_id);
}

fn writeNewSessionResponse(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session_id: []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"configOptions\":[");
    if (comptime !host_target.is_wasm) {
        try writeProviderConfigOption(&out.writer, state.active_session.?.provider);
        try out.writer.writeAll(",");
    }
    try writeModelConfigOption(
        &out.writer,
        state.active_session.?.model,
        state.capability_resolver.catalogEntries(),
    );
    try out.writer.writeAll(",");
    try writeModeConfigOption(
        &out.writer,
        state.cfg.mode_registry,
        state.cfg.mode_registry.default_mode_id,
    );
    try out.writer.writeAll("],\"modes\":{\"currentModeId\":");
    try writeJsonStr(state.cfg.mode_registry.default_mode_id, &out.writer);
    try out.writer.writeAll(",\"availableModes\":");
    try writeModesArray(&out.writer, state.cfg.mode_registry);
    try out.writer.writeAll("}}");

    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());

    const commands_json = try buildSlashCommandsJson(alloc);
    defer alloc.free(commands_json);
    try sendAvailableCommands(state, alloc, session_id, commands_json);
}

pub fn handleLoadWasmSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();
    const session_id = if (parsed.value == .object)
        if (parsed.value.object.get("sessionId")) |value|
            if (value == .string) value.string else return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" })
        else
            return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" })
    else
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" });

    if (state.active_session) |*active| {
        if (sameSessionId(active.session_id, session_id)) {
            for (active.session_rt.history.items) |turn| try sendHistoryTurnAsUpdates(state, alloc, session_id, turn);
            return writeLoadSessionResponse(state, alloc, msg, active.model);
        }
    }

    var loaded = (js_host_session_store.load(alloc, session_id) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.internal_error, .message = "Session could not be loaded" })) orelse
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Session not found" });
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(alloc);
    const sid_copy = try alloc.dupe(u8, loaded.state.id);
    var sid_owned = true;
    defer if (sid_owned) alloc.free(sid_copy);
    if (loaded.state.preferences.provider != .gateway) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Subscription models are unavailable in this WASM runtime",
        });
    }
    const model_copy = try alloc.dupe(u8, loaded.state.preferences.model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model_copy);
    var session_rt = session_runtime.SessionRuntime.init(state.cfg.max_history_turns, state.cfg.gateway_provider.generation_usage);
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    try session_rt.restoreWithPermissionState(
        alloc,
        loaded.state.conversation_language,
        loaded.state.history,
        loaded.state.context_history_start,
        loaded.state.permission_state,
    );
    if (loaded.state.usage) |usage| try session_rt.usage.restore(alloc, usage, loaded.state.created_at_ms);

    try server.releaseActiveSession(state);
    state.active_session = .{
        .session_id = sid_copy,
        .wasm_state = loaded.state,
        .wasm_revision = loaded.revision,
        .model = model_copy,
        .provider = loaded.state.preferences.provider,
        .mode = state.cfg.mode_registry.default_mode_id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = loaded.state.preferences.fast_mode,
        .effort = loaded.state.preferences.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = state.permission_mode,
        .permission_rules = state.permission_rules,
        .session_rt = session_rt,
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    loaded_owned = false;
    sid_owned = false;
    model_owned = false;
    session_rt_owned = false;
    for (state.active_session.?.session_rt.history.items) |turn| try sendHistoryTurnAsUpdates(state, alloc, session_id, turn);
    try writeLoadSessionResponse(state, alloc, msg, state.active_session.?.model);
}

pub fn handleListWasmSessions(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const entries = js_host_session_store.list(alloc) catch
        return state.writer.writeResponse(alloc, msg.id, "{\"sessions\":[]}");
    defer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessions\":[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"sessionId\":");
        try writeJsonStr(entry.id, &out.writer);
        try out.writer.writeAll(",\"cwd\":");
        try writeJsonStr(state.workspace_root, &out.writer);
        try out.writer.writeAll(",\"updatedAt\":");
        const iso = try formatIso8601(alloc, entry.updated_at_ms);
        defer alloc.free(iso);
        try writeJsonStr(iso, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

pub fn handleRemoveWasmSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing params" });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();
    const value = if (parsed.value == .object) parsed.value.object.get("sessionId") else null;
    const session_id = if (value) |id| if (id == .string) id.string else return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" }) else return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" });
    js_host_session_store.remove(session_id) catch return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.internal_error, .message = "Failed to remove session" });
    if (state.active_session) |*active| {
        if (sameSessionId(active.session_id, session_id)) try server.releaseActiveSession(state);
    }
    try state.writer.writeResponse(alloc, msg.id, "null");
}

const RestoreKind = enum {
    load,
    reconnect,

    fn replaysHistory(self: RestoreKind) bool {
        return self == .load;
    }
};

pub fn handleLoadSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    return handleRestoreSession(state, alloc, msg, .load);
}

pub fn handleResumeSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    return handleRestoreSession(state, alloc, msg, .reconnect);
}

fn handleRestoreSession(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    kind: RestoreKind,
) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    const session_id = blk: {
        if (parsed.value == .object) {
            if (parsed.value.object.get("sessionId")) |v| {
                if (v == .string) break :blk v.string;
            }
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" });
    };

    var mcp_configs = switch (kind) {
        .load => mcp_servers.parse(alloc, msg.params_raw),
        .reconnect => mcp_servers.parseResume(alloc, msg.params_raw),
    } catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = mcp_servers.parseErrorMessage(err),
        }),
    };
    defer mcp_configs.deinit(alloc);
    var mcp_preparation = try mcp_servers.prepare(
        alloc,
        &mcp_configs,
        state.client_elicitation,
        server.legacyUrlCompletionSink(state),
    );
    defer mcp_preparation.deinit(alloc);
    switch (mcp_preparation) {
        .ready => {},
        .failed => |message| return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
        }),
    }
    const session_mcp = mcp_preparation.takeRuntime();
    var session_mcp_owned = true;
    defer if (session_mcp_owned) {
        if (session_mcp) |runtime| {
            runtime.deinit();
            alloc.destroy(runtime);
        }
    };

    if (state.active_session) |*active| {
        if (sameSessionId(active.session_id, session_id)) {
            server.cancelAndReapActivePrompt(state);
            server.disableSubagentHost(state);
            state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
            const previous_mcp = active.mcp;
            active.mcp = session_mcp;
            session_mcp_owned = false;
            server.applySessionMode(
                state.cfg.mode_registry,
                active,
                state.cfg.mode_registry.default_mode_id,
            );
            state.subagent_authority_mutex.unlock(io_mod.getIo());
            if (previous_mcp) |runtime| {
                runtime.retireAndWait();
                runtime.deinit();
                alloc.destroy(runtime);
            }
            server.enableSubagentHost(state);
            if (kind.replaysHistory()) {
                for (active.session_rt.history.items) |turn| {
                    try sendHistoryTurnAsUpdates(state, alloc, session_id, turn);
                }
            }
            try sendPendingRecoveryUpdate(
                state,
                alloc,
                session_id,
                if (active.writable) |*writable| writable.state.recovery_checkpoint else null,
            );
            return writeLoadSessionResponse(
                state,
                alloc,
                msg,
                active.model,
            );
        }
    }

    var store = (if (state.cfg.home_override) |home|
        session_store.Store.initFromHome(alloc, home, state.workspace_root)
    else
        session_store.Store.init(alloc, state.workspace_root)) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Session store not available",
        });
    var store_owned = true;
    defer if (store_owned) store.deinit(alloc);

    const seed_preferences = session_codec.DurableSessionPreferences{
        .provider = state.provider,
        .model = state.configured_model,
        .effort = state.effort,
        .fast_mode = state.fast_mode,
    };
    var writable = subagent_resume_admission.resumeForExternalPrompt(
        store,
        alloc,
        .{ .id = session_id },
        state.workspace_root,
        .{
            .seed_preferences = seed_preferences,
            .log = session_test_controls.logOptions(),
        },
    ) catch |err| return handleLoadFailure(state, alloc, msg, err);
    var writable_owned = true;
    defer if (writable_owned) writable.deinit(alloc);

    const sid_copy = try alloc.dupe(u8, writable.state.id);
    var sid_owned = true;
    defer if (sid_owned) alloc.free(sid_copy);
    const effective_provider = if (state.process_model_override)
        state.provider
    else
        writable.state.preferences.provider;
    const effective_model = if (state.process_model_override)
        state.selected_model
    else
        writable.state.preferences.model;
    if (!try server.selectCredentialForProvider(state, effective_provider)) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = if (effective_provider == .codex)
                credentials.missing_chatgpt_credential_message
            else if (effective_provider == .grok)
                credentials.missing_grok_credential_message
            else
                credentials.missing_credential_message,
        });
    }
    const model_copy = try alloc.dupe(u8, effective_model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model_copy);

    var session_rt = session_runtime.SessionRuntime.init(
        state.cfg.max_history_turns,
        state.cfg.gateway_provider.generation_usage,
    );
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    _ = try session_rt.initializeProfileUsage(alloc, io_mod.getenv("HOME"));
    try session_rt.restoreWithPermissionState(
        alloc,
        writable.state.conversation_language,
        writable.state.history,
        writable.state.context_history_start,
        writable.state.permission_state,
    );
    if (writable.state.usage) |usage| {
        try session_rt.usage.restore(
            alloc,
            usage,
            writable.state.created_at_ms,
        );
    } else {
        session_rt.usage.restoreLegacyWallDuration(
            writable.state.created_at_ms,
        );
    }
    const session_dir = try session_store.sessionDirPath(alloc, store.sessions_dir, session_id);
    defer alloc.free(session_dir);

    session_rt.configureWebFetchArtifacts(alloc, session_dir);
    server.cancelAndReapActivePrompt(state);
    activateSession(state, store, .{
        .session_id = sid_copy,
        .writable = writable,
        .model = model_copy,
        .provider = effective_provider,
        .fast_mode = writable.state.preferences.fast_mode,
        .effort = writable.state.preferences.effort,
        .session_rt = session_rt,
        .mcp = session_mcp,
    }) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to save active session",
        });
    writable_owned = false;
    store_owned = false;
    sid_owned = false;
    model_owned = false;
    session_rt_owned = false;
    session_mcp_owned = false;
    if (kind.replaysHistory()) {
        for (state.active_session.?.writable.?.state.history) |turn| {
            try sendHistoryTurnAsUpdates(state, alloc, session_id, turn);
        }
    }
    try sendPendingRecoveryUpdate(
        state,
        alloc,
        session_id,
        state.active_session.?.writable.?.state.recovery_checkpoint,
    );

    try writeLoadSessionResponse(
        state,
        alloc,
        msg,
        state.active_session.?.model,
    );
}

fn sendPendingRecoveryUpdate(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    checkpoint: ?session_codec.RecoveryCheckpoint,
) !void {
    const recovery = checkpoint orelse return;
    try sendUserHistoryChunk(state, alloc, session_id, recovery.user.text);
    try sendExecutionHistory(state, alloc, session_id, recovery.execution);
    if (recovery.assistant_source.len > 0) {
        try sendAgentHistoryChunk(state, alloc, session_id, recovery.assistant_source);
    }
    const attempt = recovery.consumed_provider_attempts +| @intFromBool(recovery.outstanding_reservation);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeModelRecoveryInfoUpdate(&out.writer, .{
        .kind = .terminal_provider_error,
        .failed_attempt = attempt,
        .attempt_limit = recovery.max_provider_attempts,
        .cause = recovery.cause,
        .action = .paused,
        .required_action = if (recovery.tool_state == .uncertain)
            .inspect_uncertain_tool
        else
            .continue_later,
        .diagnostic = types.ModelFailureDiagnostic.forCause(recovery.cause),
    }, true);
    try out.writer.writeByte('}');
    try state.writer.writeNotification(
        alloc,
        "session/update",
        out.writer.buffered(),
    );
}

fn sameSessionId(active_session_id: []const u8, requested_session_id: []const u8) bool {
    return std.mem.eql(u8, active_session_id, requested_session_id);
}

fn writeLoadSessionResponse(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    model: []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"configOptions\":[");
    if (comptime !host_target.is_wasm) {
        try writeProviderConfigOption(&out.writer, state.active_session.?.provider);
        try out.writer.writeAll(",");
    }
    try writeModelConfigOption(
        &out.writer,
        model,
        state.capability_resolver.catalogEntries(),
    );
    try out.writer.writeAll(",");
    try writeModeConfigOption(
        &out.writer,
        state.cfg.mode_registry,
        state.cfg.mode_registry.default_mode_id,
    );
    try out.writer.writeAll("],\"modes\":{\"currentModeId\":");
    try writeJsonStr(state.cfg.mode_registry.default_mode_id, &out.writer);
    try out.writer.writeAll(",\"availableModes\":");
    try writeModesArray(&out.writer, state.cfg.mode_registry);
    try out.writer.writeAll("}}");

    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

fn freshAcpState(
    state: *server.ServerState,
    alloc: Allocator,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = try session_store.generateSessionId(alloc);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, state.workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, state.workspace_root);
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, state.configured_model);
    errdefer alloc.free(model);
    const history = try alloc.alloc(types.HistoryTurn, 0);
    errdefer alloc.free(history);
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = now,
        .updated_at_ms = now,
        .conversation_language = session_runtime.ConversationLanguage.default(),
        .preferences = .{
            .provider = state.provider,
            .model = model,
            .effort = state.effort,
            .fast_mode = state.fast_mode,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

const SessionActivation = struct {
    session_id: []u8,
    writable: session_store.LoadedWritableSession,
    model: []u8,
    provider: model_provider.ProviderId,
    fast_mode: bool,
    effort: types.ReasoningEffort,
    session_rt: session_runtime.SessionRuntime,
    mcp: ?*mcp_runtime.McpRuntime,
};

fn activateSession(
    state: *server.ServerState,
    store: session_store.Store,
    activation: SessionActivation,
) !void {
    try server.releaseActiveSession(state);
    state.active_session = .{
        .session_id = activation.session_id,
        .store = store,
        .writable = activation.writable,
        .model = activation.model,
        .provider = activation.provider,
        .mode = state.cfg.mode_registry.default_mode_id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = activation.fast_mode,
        .effort = activation.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = state.permission_mode,
        .permission_rules = state.permission_rules,
        .session_rt = activation.session_rt,
        .mcp = activation.mcp,
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    server.enableSubagentHost(state);
    state.active_session.?.session_rt.attachProfileUsagePublisher(state.alloc);
    if (state.credential_source == .chatgpt_subscription or state.credential_source == .grok_subscription) {
        state.active_session.?.session_rt.usage.clearReconciliationCredential();
    } else {
        state.active_session.?.session_rt.usage.startReconciliation(
            state.alloc,
            state.api_key,
        );
    }
    activateManagedBackground(state, store);
}

fn activateManagedBackground(
    state: *server.ServerState,
    store: session_store.Store,
) void {
    const active = if (state.active_session) |*session| session else return;
    const writable = if (active.writable) |*value| value else return;
    state.background.restoreWorkspaceFromStore(
        std.heap.c_allocator,
        store,
        state.workspace_root,
        writable.active_id,
    ) catch {};
    state.background.restoreFromManagedPersistence(
        std.heap.c_allocator,
        writable.childCapability() catch return,
        writable.active_id,
        state.workspace_root,
    ) catch {};
}

fn handleLoadFailure(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    err: anyerror,
) !void {
    debug_trace.logf(
        "acp",
        "session operation=load outcome=failed error={s}",
        .{@errorName(err)},
    );
    if (err == error.SessionCommitIndeterminate) {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to commit session workspace rebind",
        });
        state.terminate_connection = true;
        return;
    }
    if (err == error.SessionWorkspaceRebindFailed) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to persist session workspace rebind",
        });
    }
    if (err == error.SessionBusy) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Session is busy",
        });
    }
    if (err == error.InvalidSessionId) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid session ID",
        });
    }
    if (err == error.OneOffSessionNotResumable) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "One-off child sessions cannot accept additional prompts",
        });
    }
    if (err == error.InvalidSessionFormat or
        err == error.UnsupportedSessionSchema or
        err == error.LegacySessionTooLarge or
        err == error.LegacySessionReadResourceExhausted or
        err == error.SessionAuthorityBoundaryUnavailable or
        err == error.SessionAuthorityIntentCleanupPending or
        err == error.SessionPathUnsafe or
        err == error.DurablePathUnsafe)
    {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Session could not be loaded",
        });
    }
    return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Session not found",
    });
}

pub fn handleListSessions(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    var store = session_store.Store.initReadOnly(
        alloc,
        state.workspace_root,
    ) catch {
        try state.writer.writeResponse(alloc, msg.id, "{\"sessions\":[]}");
        return;
    };
    defer store.deinit(alloc);

    var session_list = store.listForWorkspace(alloc) catch {
        try state.writer.writeResponse(alloc, msg.id, "{\"sessions\":[]}");
        return;
    };
    defer {
        for (session_list.items) |*s| s.deinit(alloc);
        session_list.deinit(alloc);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"sessions\":[");
    for (session_list.items, 0..) |summary, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"sessionId\":");
        try writeJsonStr(summary.id, &out.writer);
        try out.writer.writeAll(",\"cwd\":");
        try writeJsonStr(state.workspace_root, &out.writer);
        try out.writer.writeAll(",\"updatedAt\":");
        const iso = try formatIso8601(alloc, summary.updated_at_ms);
        defer alloc.free(iso);
        try writeJsonStr(iso, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}");

    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

fn sendHistoryTurnAsUpdates(state: *server.ServerState, alloc: Allocator, session_id: []const u8, turn: types.HistoryTurn) !void {
    const user_text: []const u8 = switch (turn) {
        .assistant => |a| a.user.text,
        .background_command => |b| b.user.text,
        .interrupted => |i| i.user.text,
        .compacted_summary => |c| c.summary,
    };

    try sendUserHistoryChunk(state, alloc, session_id, user_text);

    switch (turn) {
        .assistant => |assistant| {
            try sendExecutionHistory(state, alloc, session_id, assistant.execution);
            try sendAgentHistoryChunk(state, alloc, session_id, assistant.assistant);
        },
        .background_command => |background| {
            try sendExecutionHistory(state, alloc, session_id, background.execution);
            if (background.assistant) |assistant| {
                if (assistant.len > 0) {
                    try sendAgentHistoryChunk(state, alloc, session_id, assistant);
                }
            }
            try sendAgentHistoryChunk(state, alloc, session_id, "[background command]");
        },
        .interrupted => |i| {
            try sendExecutionHistory(state, alloc, session_id, i.execution);
            if (i.assistant) |assistant| {
                if (assistant.len > 0) try sendAgentHistoryChunk(state, alloc, session_id, assistant);
            }
            try sendAgentHistoryChunk(
                state,
                alloc,
                session_id,
                session_runtime.interruptedTurnNotice(i).body,
            );
        },
        .compacted_summary => {},
    }
}

fn sendUserHistoryChunk(state: *server.ServerState, alloc: Allocator, session_id: []const u8, text: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeUserMessageChunk(&out.writer, text);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

fn sendExecutionHistory(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    execution: types.ExecutionMemory,
) !void {
    const text = try session_runtime.formatExecutionReplayContext(alloc, execution) orelse return;
    defer alloc.free(text);
    try sendAgentHistoryChunk(state, alloc, session_id, text);
}

fn sendAgentHistoryChunk(state: *server.ServerState, alloc: Allocator, session_id: []const u8, text: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeAgentMessageChunk(&out.writer, text);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

fn sendAvailableCommands(state: *server.ServerState, alloc: Allocator, session_id: []const u8, commands_json: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeAvailableCommandsUpdate(&out.writer, commands_json);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

fn buildSlashCommandsJson(alloc: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const commands = [_]struct { name: []const u8, description: []const u8, hint: ?[]const u8 }{
        .{ .name = "compact", .description = "Compact conversation history", .hint = null },
        .{ .name = "undo", .description = "Undo last file change", .hint = null },
        .{ .name = "changes", .description = "Show file changes in this session", .hint = null },
        .{ .name = "review", .description = "Toggle post-edit review", .hint = null },
        .{ .name = "clear", .description = "Clear the screen", .hint = null },
        .{ .name = "reset", .description = "Reset session", .hint = null },
        .{ .name = "help", .description = "Show available commands", .hint = null },
        .{ .name = "status", .description = "Show current status", .hint = null },
        .{ .name = "model", .description = "Switch model", .hint = "model name" },
        .{ .name = "permissions", .description = "Show permission settings", .hint = null },
        .{ .name = "allowlist", .description = "Manage persistent allow rules", .hint = "add command \"git *\"" },
        .{ .name = "rules", .description = "Show active rules", .hint = null },
        .{ .name = "settings", .description = "Show settings", .hint = null },
        .{ .name = "credits", .description = "Show credit balance", .hint = null },
        .{ .name = "mcp", .description = "Show MCP server status", .hint = null },
        .{ .name = "skills", .description = "Show installed skills", .hint = null },
        .{ .name = "fast", .description = "Toggle fast mode for supported models", .hint = null },
    };

    try out.writer.writeAll("[");
    for (commands, 0..) |cmd, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"name\":");
        try writeJsonStr(cmd.name, &out.writer);
        try out.writer.writeAll(",\"description\":");
        try writeJsonStr(cmd.description, &out.writer);
        if (cmd.hint) |hint| {
            try out.writer.writeAll(",\"input\":{\"hint\":");
            try writeJsonStr(hint, &out.writer);
            try out.writer.writeAll("}");
        }
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]");

    return try alloc.dupe(u8, out.writer.buffered());
}

fn formatIso8601(alloc: Allocator, timestamp_ms: i64) ![]u8 {
    const epoch_secs: u64 = @intCast(@divTrunc(timestamp_ms, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

pub fn writeModelConfigOption(
    w: *std.Io.Writer,
    current: []const u8,
    catalog: ?[]const model_catalog.ModelCatalogEntry,
) !void {
    try w.writeAll("{\"id\":\"model\",\"name\":\"Model\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(current, w);
    try w.writeAll(",\"options\":[");
    const entries = catalog orelse &.{};
    var wrote_current = false;
    for (entries, 0..) |entry, i| {
        const id = entry.id;
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"value\":");
        try writeJsonStr(id, w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(id, w);
        try w.writeAll("}");
        if (std.mem.eql(u8, id, current)) wrote_current = true;
    }
    if (!wrote_current) {
        if (entries.len > 0) try w.writeAll(",");
        try w.writeAll("{\"value\":");
        try writeJsonStr(current, w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(current, w);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

pub fn writeProviderConfigOption(
    w: *std.Io.Writer,
    current: model_provider.ProviderId,
) !void {
    try w.writeAll("{\"id\":\"provider\",\"name\":\"Provider\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(@tagName(current), w);
    try w.writeAll(",\"options\":[{\"value\":\"gateway\",\"name\":\"Vercel AI Gateway\"},{\"value\":\"codex\",\"name\":\"Codex subscription\"}");
    if (comptime !host_target.is_wasm) {
        try w.writeAll(",{\"value\":\"grok\",\"name\":\"Grok subscription\"}");
    }
    try w.writeAll("]}");
}

pub fn writeModeConfigOption(
    w: *std.Io.Writer,
    registry: mode_registry.Registry,
    current: []const u8,
) !void {
    try w.writeAll("{\"id\":\"mode\",\"name\":\"Session Mode\",\"description\":\"Controls how the agent requests permission\",\"category\":\"mode\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(current, w);
    try w.writeAll(",\"options\":[");
    for (registry.modes, 0..) |mode, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"value\":");
        try writeJsonStr(mode.id, w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(mode.name, w);
        try w.writeAll(",\"description\":");
        try writeJsonStr(mode.description, w);
        try w.writeAll(",\"permissionMode\":");
        try writeJsonStr(@tagName(mode.permission_mode), w);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeModesArray(w: *std.Io.Writer, registry: mode_registry.Registry) !void {
    try w.writeAll("[");
    for (registry.modes, 0..) |mode, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try writeJsonStr(mode.id, w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(mode.name, w);
        try w.writeAll(",\"description\":");
        try writeJsonStr(mode.description, w);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

test "formatIso8601 produces valid format" {
    const alloc = std.testing.allocator;
    const result = try formatIso8601(alloc, 1700000000000);
    defer alloc.free(result);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, result, "Z"));
    try std.testing.expect(std.mem.find(u8, result, "T") != null);
}

test "buildSlashCommandsJson produces valid array" {
    const alloc = std.testing.allocator;
    const json = try buildSlashCommandsJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(json.len > 0);
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[json.len - 1] == ']');
    try std.testing.expect(std.mem.find(u8, json, "compact") != null);
}

test "buildSlashCommandsJson includes all expected commands" {
    const alloc = std.testing.allocator;
    const json = try buildSlashCommandsJson(alloc);
    defer alloc.free(json);

    const expected_commands = [_][]const u8{
        "compact",   "undo",  "changes",  "review",  "clear",
        "reset",     "help",  "status",   "model",   "permissions",
        "allowlist", "rules", "settings", "credits", "mcp",
        "skills",    "fast",
    };
    for (expected_commands) |cmd| {
        try std.testing.expect(std.mem.find(u8, json, cmd) != null);
    }
    try std.testing.expect(std.mem.find(u8, json, "\"name\":\"summary\"") == null);
}

test "buildSlashCommandsJson includes input hint for model" {
    const alloc = std.testing.allocator;
    const json = try buildSlashCommandsJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"input\":{\"hint\":\"model name\"}") != null);
}

test "formatIso8601 produces known timestamp" {
    const alloc = std.testing.allocator;
    const result = try formatIso8601(alloc, 0);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", result);
}

test "writeModelConfigOption produces valid json with single model fallback" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModelConfigOption(&out.writer, "gpt-4", null);
    const items = out.writer.buffered();
    try std.testing.expect(std.mem.find(u8, items, "\"id\":\"model\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "\"currentValue\":\"gpt-4\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "\"value\":\"gpt-4\"") != null);
}

test "writeModelConfigOption includes all cached model ids" {
    const alloc = std.testing.allocator;
    const entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("anthropic/claude-opus-4.6"), .model_type = @constCast("language") },
        .{ .id = @constCast("openai/gpt-4o"), .model_type = @constCast("language") },
        .{ .id = @constCast("xai/grok-3"), .model_type = @constCast("language") },
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModelConfigOption(&out.writer, "openai/gpt-4o", &entries);
    const items = out.writer.buffered();
    try std.testing.expect(std.mem.find(u8, items, "\"currentValue\":\"openai/gpt-4o\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "anthropic/claude-opus-4.6") != null);
    try std.testing.expect(std.mem.find(u8, items, "openai/gpt-4o") != null);
    try std.testing.expect(std.mem.find(u8, items, "xai/grok-3") != null);
}

test "writeModelConfigOption appends current model when not in cached list" {
    const alloc = std.testing.allocator;
    const entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("anthropic/claude-opus-4.6"), .model_type = @constCast("language") },
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModelConfigOption(&out.writer, "custom/my-model", &entries);
    const items = out.writer.buffered();
    try std.testing.expect(std.mem.find(u8, items, "\"currentValue\":\"custom/my-model\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "anthropic/claude-opus-4.6") != null);
    try std.testing.expect(std.mem.find(u8, items, "custom/my-model") != null);
}

test "writeModeConfigOption produces valid json with all modes" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModeConfigOption(&out.writer, test_session_mode_registry, "inspect");
    const items = out.writer.buffered();
    try std.testing.expect(std.mem.find(u8, items, "\"id\":\"mode\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "\"currentValue\":\"inspect\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "\"review\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "\"inspect\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "\"permissionMode\":\"ask\"") != null);
}

test "writeModesArray preserves supplied registry order" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModesArray(&out.writer, test_session_mode_registry);
    const items = out.writer.buffered();
    try std.testing.expect(items[0] == '[');
    try std.testing.expect(items[items.len - 1] == ']');
    const review_index = std.mem.find(u8, items, "\"review\"") orelse return error.TestExpectedEqual;
    const inspect_index = std.mem.find(u8, items, "\"inspect\"") orelse return error.TestExpectedEqual;
    try std.testing.expect(review_index < inspect_index);
}

test "ACP load recognizes the retained active session exactly" {
    try std.testing.expect(sameSessionId(
        "release.2026.06",
        "release.2026.06",
    ));
    try std.testing.expect(!sameSessionId(
        "release.2026.06",
        "release.2026",
    ));
}

test "ACP interrupted history replay hides model-only abort context" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var capture = try tmp.dir.createFile(
        io_mod.getIo(),
        "acp-interrupted-history.jsonl",
        .{ .read = true },
    );
    defer capture.close(io_mod.getIo());

    {
        var state = try initAcpSessionTestState(arena, workspace, capture);
        defer state.deinit();
        var completed_tool_names = [_][]u8{@constCast("read_file")};
        try sendHistoryTurnAsUpdates(&state, arena, "session-1", .{ .interrupted = .{
            .user = .{ .text = @constCast("inspect the project") },
            .completed_tool_names = completed_tool_names[0..],
        } });
        try capture.sync(io_mod.getIo());
    }

    var captured_file = try tmp.dir.openFile(
        io_mod.getIo(),
        "acp-interrupted-history.jsonl",
        .{},
    );
    defer captured_file.close(io_mod.getIo());
    const captured = try io_mod.readFileToEnd(alloc, &captured_file, 16 * 1024);
    defer alloc.free(captured);
    try std.testing.expect(std.mem.find(u8, captured, "cancelled") != null);
    try std.testing.expect(std.mem.find(u8, captured, "Interrupted by user after completing") == null);
    try std.testing.expect(std.mem.find(u8, captured, "<turn_aborted>") == null);
}

test "ACP load maps one-off child denial to invalid params" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var capture = try tmp.dir.createFile(
        io_mod.getIo(),
        "acp-one-off-error.jsonl",
        .{ .read = true },
    );
    defer capture.close(io_mod.getIo());
    {
        var state = try initAcpSessionTestState(arena, workspace, capture);
        defer state.deinit();
        var msg = jsonrpc.Message{
            .id = .{ .integer = 1 },
            .method = "session/load",
        };
        try handleLoadFailure(
            &state,
            arena,
            &msg,
            error.OneOffSessionNotResumable,
        );
        try std.testing.expect(state.active_session == null);
        try capture.sync(io_mod.getIo());
    }
    var captured_file = try tmp.dir.openFile(
        io_mod.getIo(),
        "acp-one-off-error.jsonl",
        .{},
    );
    defer captured_file.close(io_mod.getIo());
    const captured = try io_mod.readFileToEnd(alloc, &captured_file, 4096);
    defer alloc.free(captured);
    try std.testing.expect(std.mem.find(u8, captured, "\"code\":-32602") != null);
    try std.testing.expect(std.mem.find(
        u8,
        captured,
        "One-off child sessions cannot accept additional prompts",
    ) != null);
}

var acp_session_stable_test_environ: ?*std.process.Environ.Map = null;

fn stableAcpSessionTestEnviron() !*const std.process.Environ.Map {
    if (acp_session_stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    acp_session_stable_test_environ = map;
    return map;
}

const AcpSessionTestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: []const u8) !*AcpSessionTestHome {
        _ = try stableAcpSessionTestEnviron();

        const self = try alloc.create(AcpSessionTestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        try self.map.put("HOME", home);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *AcpSessionTestHome) void {
        if (acp_session_stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn gatherNoopContextForTest(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopStaticContextForTest(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContextForTest(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

const test_session_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.acp_session_context",
    .gather_project_context_fn = gatherNoopContextForTest,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContextForTest,
    .append_transient_fn = appendNoopTransientContextForTest,
} };

const test_session_modes = [_]mode_registry.ModeSpec{
    .{ .id = "review", .name = "Review", .description = "Review changes" },
    .{ .id = "inspect", .name = "Inspect", .description = "Inspect a workspace" },
};

const test_session_mode_registry = mode_registry.Registry{
    .default_mode_id = "inspect",
    .modes = test_session_modes[0..],
};

fn acpSessionTestConfig() server.Config {
    return .{
        .default_model = "test/model",
        .default_agent_step_limit = 8,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1/unused",
        .gateway_models_path = "/v1/models",
        .gateway_provider = test_builtin_gateway.provider,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "test" },
        .ignored_list_entries = &.{},
        .max_list_entries = 100,
        .max_read_file_bytes = 64 * 1024,
        .max_read_file_lines = 1000,
        .max_read_file_line_len = 4096,
        .max_command_output_bytes = 64 * 1024,
        .max_tool_result_bytes = 64 * 1024,
        .max_history_turns = 100,
        .context_registry = test_session_context_registry,
        .mode_registry = test_session_mode_registry,
    };
}

fn initAcpSessionTestState(
    alloc: Allocator,
    workspace_root: []const u8,
    capture: std.Io.File,
) !server.ServerState {
    const workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(workspace);
    const api_key = try alloc.dupe(u8, "test-key");
    errdefer alloc.free(api_key);
    const selected_model = try alloc.dupe(u8, "test/model");
    errdefer alloc.free(selected_model);
    const configured_model = try alloc.dupe(u8, "test/model");
    errdefer alloc.free(configured_model);

    return .{
        .alloc = alloc,
        .cfg = acpSessionTestConfig(),
        .writer = .{ .stdout = capture },
        .workspace_root = workspace,
        .api_key = api_key,
        .credential_source = .ai_gateway_api_key,
        .selected_model = selected_model,
        .configured_model = configured_model,
        .agent_step_limit = 8,
        .max_tool_result_bytes = 64 * 1024,
    };
}

test "ACP new and loaded sessions provide a writable subagent host" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const workspace_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace_path);
    const test_home = try AcpSessionTestHome.install(alloc, home_path);
    defer test_home.deinit();

    var capture = try tmp.dir.createFile(
        io_mod.getIo(),
        "acp-output.jsonl",
        .{ .read = true },
    );
    defer capture.close(io_mod.getIo());
    {
        var state = try initAcpSessionTestState(arena, workspace_path, capture);
        defer state.deinit();

        var new_msg = jsonrpc.Message{
            .id = .{ .integer = 1 },
            .method = "session/new",
            .params_raw = "{\"mcpServers\":[]}",
        };
        try handleNewSession(&state, arena, &new_msg);

        const new_active = &state.active_session.?;
        const new_writable = &new_active.writable.?;
        try std.testing.expectEqualStrings(
            test_session_mode_registry.default_mode_id,
            new_active.mode,
        );
        server.applySessionMode(
            state.cfg.mode_registry,
            new_active,
            "review",
        );
        try std.testing.expectEqualStrings("review", new_active.mode);
        try std.testing.expect(new_writable.state.usage != null);
        try std.testing.expect(
            new_active.session_rt.usage.generation_usage_provider.lookup_fn ==
                state.cfg.gateway_provider.generation_usage.lookup_fn,
        );
        io_mod.sleep(10 * std.time.ns_per_ms);
        var live_usage = try new_active.session_rt.usage.snapshot(alloc);
        defer live_usage.deinit(alloc);
        try std.testing.expect(live_usage.wall_duration_ms > 0);
        try std.testing.expect(state.subagent_store != null);
        try std.testing.expect(state.subagent_host != null);

        const session_id = try alloc.dupe(u8, new_active.session_id);
        defer alloc.free(session_id);
        try server.releaseActiveSession(&state);
        try std.testing.expect(state.active_session == null);
        try std.testing.expect(state.subagent_store == null);
        try std.testing.expect(state.subagent_host == null);

        var load_params: std.Io.Writer.Allocating = .init(arena);
        defer load_params.deinit();
        try load_params.writer.writeAll("{\"sessionId\":");
        try writeJsonStr(session_id, &load_params.writer);
        try load_params.writer.writeAll(",\"mcpServers\":[]}");
        var load_msg = jsonrpc.Message{
            .id = .{ .integer = 2 },
            .method = "session/load",
            .params_raw = load_params.writer.buffered(),
        };
        try handleLoadSession(&state, arena, &load_msg);

        const loaded_active = &state.active_session.?;
        const loaded_writable = &loaded_active.writable.?;
        try std.testing.expectEqualStrings(
            test_session_mode_registry.default_mode_id,
            loaded_active.mode,
        );
        try std.testing.expect(loaded_writable.state.usage != null);
        try std.testing.expect(state.subagent_store != null);
        try std.testing.expect(state.subagent_host != null);
        try std.testing.expect(
            loaded_active.session_rt.usage.generation_usage_provider.lookup_fn ==
                state.cfg.gateway_provider.generation_usage.lookup_fn,
        );

        try capture.sync(io_mod.getIo());
    }
    var captured_file = try tmp.dir.openFile(
        io_mod.getIo(),
        "acp-output.jsonl",
        .{},
    );
    defer captured_file.close(io_mod.getIo());
    const captured = try io_mod.readFileToEnd(
        alloc,
        &captured_file,
        64 * 1024,
    );
    defer alloc.free(captured);
    try std.testing.expect(std.mem.find(u8, captured, "\"id\":1") != null);
    try std.testing.expect(std.mem.find(u8, captured, "\"id\":2") != null);
}

test "ACP same-session restore retires the replaced MCP runtime after active users drain" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    const home_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const workspace_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace_path);
    const test_home = try AcpSessionTestHome.install(alloc, home_path);
    defer test_home.deinit();

    var capture = try tmp.dir.createFile(
        io_mod.getIo(),
        "acp-replace-output.jsonl",
        .{ .read = true },
    );
    defer capture.close(io_mod.getIo());
    var state = try initAcpSessionTestState(arena, workspace_path, capture);
    defer state.deinit();

    var new_msg = jsonrpc.Message{
        .id = .{ .integer = 1 },
        .method = "session/new",
        .params_raw = "{\"mcpServers\":[]}",
    };
    try handleNewSession(&state, arena, &new_msg);

    const runtime = try arena.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(arena);
    state.active_session.?.mcp = runtime;
    try std.testing.expect(runtime.acquireUse());

    var load_params: std.Io.Writer.Allocating = .init(arena);
    defer load_params.deinit();
    try load_params.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(state.active_session.?.session_id, &load_params.writer);
    try load_params.writer.writeAll(",\"mcpServers\":[]}");
    var load_msg = jsonrpc.Message{
        .id = .{ .integer = 2 },
        .method = "session/load",
        .params_raw = load_params.writer.buffered(),
    };

    const Restore = struct {
        state: *server.ServerState,
        alloc: Allocator,
        msg: *jsonrpc.Message,
        done: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            handleLoadSession(self.state, self.alloc, self.msg) catch |err| {
                self.err = err;
            };
            self.done.store(true, .release);
        }
    };
    var restore = Restore{
        .state = &state,
        .alloc = arena,
        .msg = &load_msg,
    };
    const restore_thread = try std.Thread.spawn(.{}, Restore.run, .{&restore});
    var joined = false;
    defer if (!joined) restore_thread.join();

    const observation_deadline = io_mod.milliTimestamp() + 5_000;
    while (!restore.done.load(.acquire) and
        !runtime.retiring.load(.acquire) and
        io_mod.milliTimestamp() < observation_deadline)
    {
        io_mod.sleep(std.time.ns_per_ms);
    }
    const retired_before_destroy = runtime.retiring.load(.acquire);
    const completed_while_leased = restore.done.load(.acquire);

    runtime.releaseUse();
    restore_thread.join();
    joined = true;

    if (restore.err) |err| return err;
    try std.testing.expect(retired_before_destroy);
    try std.testing.expect(!completed_while_leased);
}
