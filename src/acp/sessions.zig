const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const mem_utils = @import("../core/shared/mem_utils.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const jsonrpc = @import("jsonrpc.zig");
const libfx_hooks = @import("libfx_hooks.zig");
const acp_types = @import("types.zig");
const mcp_servers = @import("mcp_servers.zig");
const client_instructions = @import("client_instructions.zig");
const tool_call_identities = @import("tool_call_identities.zig");
const workspace_binding = @import("workspace_binding.zig");
const server = @import("server.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_display_metadata = @import("../core/session/session_display_metadata.zig");
const session_store = @import("../core/session/session_store.zig");
const session_adapter = @import("../core/session/session_adapter.zig");
const session_store_paths = @import("../core/session/session_store_paths.zig");
const session_child_store = @import("../core/session/session_child_store.zig");
const js_host_session_store = @import("../core/session/js_host_session_store.zig");
const session_runtime = @import("../core/session/session.zig");
const agent_execution_memory = @import("../core/agent/execution_memory.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const tool_call_presentation = @import("tool_call_presentation.zig");
const runtime_tool_presentation = @import("../core/agent/runtime/tool_presentation.zig");
const mcp_host = @import("../core/mcp_host/host.zig");
const mcp_contract = @import("../core/mcp/mcp_contract.zig");
const project_config = @import("../core/mcp/project_config.zig");
const builtin_mcp = @import("../builtins/mcp.zig");
const workspace_config = @import("../core/mcp/workspace_config.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const permissions = @import("../core/permissions/permissions.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const host = @import("../core/hosts/host.zig");
const host_target = @import("../core/hosts/target.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const credentials = @import("../core/auth/credentials.zig");
const model_provider = @import("../core/config/model_provider.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const types = @import("../core/shared/types.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const test_builtin_gateway = if (builtin.is_test)
    @import("../builtins/gateway.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;
const writeJsonStr = jsonrpc.writeJsonStr;

/// The session id a `libfx/new` request names, or null when it names none.
/// The id reaches gateway headers, so it must pass the session layout rules.
/// Caller owns the returned slice.
fn requestedLibfxSessionId(alloc: Allocator, params_raw: ?[]const u8) error{ InvalidSessionId, OutOfMemory }!?[]u8 {
    const raw = params_raw orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionId,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionId;
    const value = parsed.value.object.get("sessionId") orelse return null;
    switch (value) {
        .null => return null,
        .string => |id| {
            session_store_paths.validateSessionId(id) catch return error.InvalidSessionId;
            return try alloc.dupe(u8, id);
        },
        else => return error.InvalidSessionId,
    }
}

test "hook configuration OOM is not converted to an ACP parameter error" {
    const Fixture = struct {
        fail_index: usize = 0,
        alloc_index: usize = 0,
        writes: usize = 0,
        fn allocate(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const index = self.alloc_index;
            self.alloc_index += 1;
            if (index == self.fail_index) return null;
            return std.testing.allocator.rawAlloc(len, alignment, ret);
        }
        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ret);
        }
        fn write(raw: ?*anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.writes += 1;
        }
    };
    const Handler = *const fn (*server.ServerState, Allocator, *jsonrpc.Message) anyerror!void;
    const handlers = if (comptime host_target.is_wasm) [_]Handler{ handleNewLibfxSession, handleNewWasmSession, handleLoadWasmSession } else [_]Handler{ handleNewLibfxSession, handleNewSession, handleLoadSession, handleResumeSession };
    for (handlers) |handler| {
        var fixture: Fixture = .{};
        const alloc: Allocator = .{ .ptr = &fixture, .vtable = &.{ .alloc = Fixture.allocate, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = Fixture.free } };
        if (handler == handleNewLibfxSession) {
            // That handler parses the optional session ID first, even for {}.
            // Fail the first hooks allocation, not an allocation in that parse.
            fixture.fail_index = std.math.maxInt(usize);
            try std.testing.expect(try requestedLibfxSessionId(alloc, "{}") == null);
            fixture.fail_index = fixture.alloc_index;
            fixture.alloc_index = 0;
        }
        var state: server.ServerState = undefined;
        state.writer = jsonrpc.Writer.initCallback(&fixture, Fixture.write);
        var message: jsonrpc.Message = .{ .params_raw = "{}" };
        try std.testing.expectError(error.OutOfMemory, handler(&state, alloc, &message));
        try std.testing.expectEqual(@as(usize, 0), fixture.writes);
    }
}

pub fn handleNewLibfxSession(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    // Checked before the active session is released, so a bad request
    // leaves it in place.
    const requested = requestedLibfxSessionId(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSessionId => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid sessionId",
        }),
    };
    var requested_owned = requested != null;
    defer if (requested_owned) alloc.free(requested.?);
    const observer_hooks = libfx_hooks.parseConfig(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid hooks" }),
    };
    try server.releaseActiveSession(state);
    requested_owned = false;
    const session_id = requested orelse try session_store.generateSessionId(alloc);
    var session_id_owned = true;
    defer if (session_id_owned) alloc.free(session_id);
    const model = try alloc.dupe(u8, state.selected_model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model);
    var session_rt = session_runtime.SessionRuntime.init(state.cfg.max_history_turns);
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);

    const start = server.loadStartingMode(state, alloc);
    state.active_session = .{
        .observer_hooks = observer_hooks,
        .session_id = session_id,
        .model = model,
        .provider = state.provider,
        .mode = start.id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = state.fast_mode,
        .ultrafast_mode = state.ultrafast_mode,
        .effort = state.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = start.permission_mode,
        .permission_rules = state.permission_rules,
        .session_rt = session_rt,
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    session_id_owned = false;
    model_owned = false;
    session_rt_owned = false;
    try writeNewSessionResponse(state, alloc, msg, session_id, observer_hooks);
}

pub fn handleNewWasmSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const observer_hooks = libfx_hooks.parseConfig(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid hooks" }),
    };
    try server.releaseActiveSession(state);

    var durable = try freshAcpState(state, alloc, state.workspace_root);
    var durable_owned = true;
    defer if (durable_owned) durable.deinit(alloc);
    const session_id = try alloc.dupe(u8, durable.id);
    var session_id_owned = true;
    defer if (session_id_owned) alloc.free(session_id);
    const model = try alloc.dupe(u8, durable.preferences.model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model);
    var session_rt = session_runtime.SessionRuntime.init(state.cfg.max_history_turns);
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    const revision = js_host_session_store.commit(alloc, durable, null) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to create session",
        });
    var revision_owned = true;
    defer if (revision_owned) alloc.free(revision);

    const start = server.loadStartingMode(state, alloc);
    state.active_session = .{
        .session_id = session_id,
        .wasm_state = durable,
        .wasm_revision = revision,
        .model = model,
        .provider = durable.preferences.provider,
        .mode = start.id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .credential_refresh_after_ms = state.credential_refresh_after_ms,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = state.fast_mode,
        .ultrafast_mode = state.ultrafast_mode,
        .effort = state.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = start.permission_mode,
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

    try writeNewSessionResponse(state, alloc, msg, session_id, observer_hooks);
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
    next.context_history_start = 0;
    next.conversation_language = session.session_rt.languageSnapshot();
    next.updated_at_ms = io_mod.milliTimestamp();
    const model = try alloc.dupe(u8, session.model);
    alloc.free(next.preferences.model);
    next.preferences.model = model;
    next.preferences.provider = session.provider;
    next.preferences.effort = session.effort;
    next.preferences.fast_mode = session.fast_mode;
    // Ultrafast keeps its durable baseline, not the process-local request.

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

pub fn commitWasmUltrafastPreference(alloc: Allocator, session: *server.ActiveSessionState, ultrafast: bool) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const durable = if (session.wasm_state) |*value| value else return error.SessionPersistenceUnavailable;
    const previous = durable.preferences.ultrafast_mode;
    durable.preferences.ultrafast_mode = ultrafast;
    commitWasmSessionLocked(alloc, session) catch |err| {
        durable.preferences.ultrafast_mode = previous;
        return err;
    };
    session.ultrafast_mode = ultrafast;
}

test "ACP ultrafast WASM saves preserve baselines and failed preference writes roll back" {
    if (comptime host_target.is_wasm) return error.SkipZigTest;
    const Host = struct {
        var status: i32 = 0;
        var stored_ultrafast: bool = false;
        var expected_revision_matched: bool = false;

        fn commit(
            _: [*]const u8,
            _: usize,
            bytes: [*]const u8,
            length: usize,
            expected: [*]const u8,
            expected_len: usize,
            revision: [*]u8,
            capacity: usize,
            revision_len: *usize,
        ) callconv(.c) i32 {
            expected_revision_matched = std.mem.eql(u8, expected[0..expected_len], "next");
            if (status != 0) return status;
            var reader = std.Io.Reader.fixed(bytes[0..length]);
            var saved = session_codec.decodeState(std.testing.allocator, &reader, .{}) catch return -1;
            defer saved.deinit(std.testing.allocator);
            stored_ultrafast = saved.preferences.ultrafast_mode;
            if (capacity < 4) return -1;
            @memcpy(revision[0..4], "next");
            revision_len.* = 4;
            return 0;
        }
    };
    @export(&Host.commit, .{ .name = "fx_session_commit" });
    Host.status = 0;
    Host.stored_ultrafast = false;
    Host.expected_revision_matched = false;
    const alloc = std.testing.allocator;
    var state = server.ServerState{
        .alloc = alloc,
        .cfg = acpSessionTestConfig(),
        .writer = jsonrpc.Writer.init(),
        .configured_model = @constCast("openai/test"),
        .configured_ultrafast_mode = true,
    };
    var active = server.ActiveSessionState{
        .session_id = @constCast("wasm-test"),
        .wasm_state = try freshAcpState(&state, alloc, "/workspace"),
        .model = @constCast("openai/test"),
        .mode = "default",
        .workspace_root = "/workspace",
        .api_key = "",
        .agent_step_limit = 1,
        .max_tool_result_bytes = 1024,
        .fast_mode = false,
        .ultrafast_mode = false,
        .effort = .auto,
        .first_call_tool_choice = .auto,
        .permission_mode = .ask,
        .permission_rules = .{},
        .session_rt = session_runtime.SessionRuntime.init(4),
        .cancel_flag = .init(false),
        .pending_prompt_id = null,
    };
    defer active.session_rt.deinit(alloc);
    defer active.wasm_state.?.deinit(alloc);
    defer if (active.wasm_revision) |revision| alloc.free(revision);
    try commitWasmSession(alloc, &active);
    try std.testing.expect(Host.stored_ultrafast);
    try std.testing.expect(active.wasm_state.?.preferences.ultrafast_mode);
    try std.testing.expect(!active.ultrafast_mode);
    try commitWasmUltrafastPreference(alloc, &active, false);
    try std.testing.expect(!Host.stored_ultrafast);
    try std.testing.expect(!active.wasm_state.?.preferences.ultrafast_mode);
    for ([_]i32{ -2, -1 }) |status| {
        Host.status = status;
        try std.testing.expectError(
            if (status == -2) error.SessionRevisionConflict else error.SessionStoreUnavailable,
            commitWasmUltrafastPreference(alloc, &active, true),
        );
        try std.testing.expect(!active.ultrafast_mode);
        try std.testing.expect(!active.wasm_state.?.preferences.ultrafast_mode);
        try std.testing.expect(!Host.stored_ultrafast);
        try std.testing.expect(Host.expected_revision_matched);
        try std.testing.expectEqualStrings("next", active.wasm_revision.?);
    }
    Host.status = 0;
    try commitWasmUltrafastPreference(alloc, &active, true);
    try std.testing.expect(active.ultrafast_mode);
    try std.testing.expect(active.wasm_state.?.preferences.ultrafast_mode);
    Host.status = -2;
    try std.testing.expectError(error.SessionRevisionConflict, commitWasmUltrafastPreference(alloc, &active, false));
    try std.testing.expect(active.ultrafast_mode);
    try std.testing.expect(active.wasm_state.?.preferences.ultrafast_mode);
    try std.testing.expect(Host.stored_ultrafast);
    Host.status = 0;
    active.ultrafast_mode = false;
    try commitWasmSession(alloc, &active);
    try std.testing.expect(Host.stored_ultrafast);
}

pub fn handleNewSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const observer_hooks = libfx_hooks.parseConfig(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid hooks" }),
    };
    // Validate the client system prompt before any session side effect.
    var client_system_prompt = client_instructions.parse(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = client_instructions.parseErrorMessage(err),
        }),
    };
    defer if (client_system_prompt) |text| alloc.free(text);
    var workspace = workspace_binding.prepare(state, alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = workspace_binding.prepareErrorMessage(err),
        }),
    };
    defer if (workspace) |*binding| binding.deinit(alloc);
    const workspace_root = if (workspace) |binding| binding.root else state.workspace_root;
    var mcp_configs = mcp_servers.parse(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = mcp_servers.parseErrorMessage(err),
        }),
    };
    defer mcp_configs.deinit(alloc);
    if (try mcp_servers.duplicateNameMessage(alloc, &mcp_configs)) |message| {
        defer alloc.free(message);
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = message });
    }
    if (!state.cfg.allow_acp_mcp and mcp_configs.items.items.len > 0) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "MCP servers are unavailable in this runtime",
        });
    }
    if (state.cfg.allow_acp_mcp) {
        try appendProfileMcpConfigsIfRequested(state, alloc, msg.params_raw, &mcp_configs);
        try appendProjectMcpConfigs(state, alloc, workspace_root, &mcp_configs);
    }
    var mcp_preparation = try mcp_servers.prepare(
        alloc,
        &mcp_configs,
        workspace_root,
        state.client_elicitation,
        server.legacyUrlCompletionSink(state),
    );
    defer mcp_preparation.deinit(alloc);
    switch (mcp_preparation) {
        .none, .host => {},
        .failed => |message| return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
        }),
    }
    const session_host = mcp_preparation.takeHost();
    var session_host_owned = true;
    defer if (session_host_owned) if (session_host) |h| h.destroy();
    const v2_store = server.sessionsStore(state) orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.internal_error,
        .message = "Session store not available",
    });
    session_host_owned = false;
    return startV2Session(state, alloc, msg, v2_store, .{
        .observer_hooks = observer_hooks,
        .mcp_host = session_host,
        .workspace = if (workspace) |*binding| binding else null,
        .client_system_prompt = &client_system_prompt,
    });
}

/// What `session/new` hands `startV2Session`.
const V2Start = struct {
    observer_hooks: ?libfx_hooks.Config = null,
    /// Owned; the session takes it over.
    mcp_host: ?*mcp_host.Host = null,
    /// The request's `cwd`, borrowed as in v1.
    workspace: ?*workspace_binding.Binding,
    /// Owned by the caller. The session takes the text over on success, and
    /// this is then set to null.
    client_system_prompt: *?[]u8,
};

/// `session/new` on v2. The session stays in memory until its first prompt,
/// so one that never gets a prompt leaves no session behind (D24). A client
/// prompt goes to the side folder at once, as v1 saves it (D27).
fn startV2Session(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    v2_store: *session_adapter.Store,
    start: V2Start,
) !void {
    const session_host = start.mcp_host;
    var session_host_owned = true;
    defer if (session_host_owned) if (session_host) |h| h.destroy();
    const workspace_root = if (start.workspace) |binding| binding.root else state.workspace_root;
    const v2 = session_adapter.Session.create(alloc, v2_store, workspace_root, .acp, .{
        .preferences = .{
            .provider = state.provider,
            .model = state.configured_model,
            .effort = state.effort,
            .fast_mode = state.fast_mode,
            .ultrafast_mode = state.configured_ultrafast_mode,
        },
        .language = session_runtime.ConversationLanguage.default(),
        .permission_state = .{},
    }) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.internal_error, .message = "Failed to create session" });
    var v2_owned = true;
    defer if (v2_owned) v2.close();
    if (start.client_system_prompt.*) |text| {
        v2.setClientPrompt(text) catch |err| {
            debug_trace.logf("acp", "failed to persist client system prompt err={s}", .{@errorName(err)});
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.internal_error,
                .message = "Failed to save the client system prompt",
            });
        };
    }
    const session_id = try alloc.dupe(u8, v2.id());
    var session_id_owned = true;
    defer if (session_id_owned) alloc.free(session_id);
    const model_copy = try alloc.dupe(u8, state.selected_model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model_copy);
    var session_rt = session_runtime.SessionRuntime.init(state.cfg.max_history_turns);
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    session_rt.configureWebFetchArtifactBlobs(alloc, try v2.childCapability(), v2.id());
    server.cancelAndReapActivePrompt(state);
    activateSession(state, .{
        .session_id = session_id,
        .v2 = v2,
        .model = model_copy,
        .provider = state.provider,
        .fast_mode = state.fast_mode,
        .ultrafast_mode = state.ultrafast_mode,
        .effort = state.effort,
        .session_rt = session_rt,
        .mcp_host = session_host,
        .client_system_prompt = start.client_system_prompt.*,
        .workspace = start.workspace,
    }) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to save active session",
        });
    start.client_system_prompt.* = null;
    v2_owned = false;
    session_id_owned = false;
    model_owned = false;
    session_rt_owned = false;
    session_host_owned = false;
    try writeNewSessionResponse(state, alloc, msg, session_id, start.observer_hooks);
}

fn writeNewSessionResponse(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session_id: []const u8,
    observer_hooks: ?libfx_hooks.Config,
) !void {
    state.active_session.?.observer_hooks = observer_hooks;
    try server.refreshModelCatalogForOptions(state);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"configOptions\":[");
    if (comptime !host_target.is_wasm) {
        try writeProviderConfigOption(&out.writer, state.active_session.?.provider, state.configured_providers.definitions);
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
        state.active_session.?.mode,
    );
    if (effortConfigState(state)) |config| {
        try out.writer.writeAll(",");
        try writeEffortConfigOption(&out.writer, config.efforts, config.current);
    }
    if (fastConfigState(state)) |current| {
        try out.writer.writeAll(",");
        try writeFastConfigOption(&out.writer, current);
    }
    if (ultrafastConfigState(state)) |current| {
        try out.writer.writeAll(",");
        try writeUltrafastConfigOption(&out.writer, current);
    }
    try out.writer.writeAll("],\"modes\":{\"currentModeId\":");
    try writeJsonStr(state.active_session.?.mode, &out.writer);
    try out.writer.writeAll(",\"availableModes\":");
    try writeModesArray(&out.writer, state.cfg.mode_registry);
    try out.writer.writeByte('}');
    if (state.active_session.?.observer_hooks != null) try out.writer.writeAll(",\"_meta\":{\"fx\":{\"hooksVersion\":1}}");
    try out.writer.writeByte('}');

    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());

    try sendAvailableCommands(state, alloc, session_id, "[]");
}

pub fn handleLoadWasmSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const observer_hooks = libfx_hooks.parseConfig(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid hooks" }),
    };
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
            var sources: runtime_tool_presentation.ReplayedSavedOutputSources = .{};
            defer sources.deinit(alloc);
            for (active.session_rt.agent.history.items) |turn| try sendHistoryTurnAsUpdates(state, alloc, session_id, &sources, turn);
            try sendActiveSessionInfoUpdate(state, alloc);
            return writeLoadSessionResponse(state, alloc, msg, active.model, observer_hooks);
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
    var session_rt = session_runtime.SessionRuntime.init(state.cfg.max_history_turns);
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    try session_rt.restoreWithPermissionState(
        alloc,
        loaded.state.conversation_language,
        loaded.state.history,
        loaded.state.permission_state,
    );

    try server.releaseActiveSession(state);
    const start = server.loadStartingMode(state, alloc);
    state.active_session = .{
        .session_id = sid_copy,
        .wasm_state = loaded.state,
        .wasm_revision = loaded.revision,
        .model = model_copy,
        .provider = loaded.state.preferences.provider,
        .mode = start.id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .credential_refresh_after_ms = state.credential_refresh_after_ms,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = loaded.state.preferences.fast_mode,
        .ultrafast_mode = restoredUltrafastMode(state, loaded.state.preferences.ultrafast_mode),
        .effort = loaded.state.preferences.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = start.permission_mode,
        .permission_rules = state.permission_rules,
        .session_rt = session_rt,
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    loaded_owned = false;
    sid_owned = false;
    model_owned = false;
    session_rt_owned = false;
    var sources: runtime_tool_presentation.ReplayedSavedOutputSources = .{};
    defer sources.deinit(alloc);
    for (state.active_session.?.session_rt.agent.history.items) |turn| try sendHistoryTurnAsUpdates(state, alloc, session_id, &sources, turn);
    try sendActiveSessionInfoUpdate(state, alloc);
    try writeLoadSessionResponse(state, alloc, msg, state.active_session.?.model, observer_hooks);
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
    const observer_hooks = libfx_hooks.parseConfig(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid hooks" }),
    };
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

    var workspace = workspace_binding.prepare(state, alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = workspace_binding.prepareErrorMessage(err),
        }),
    };
    defer if (workspace) |*binding| binding.deinit(alloc);
    const workspace_root = if (workspace) |binding| binding.root else state.workspace_root;

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
    if (try mcp_servers.duplicateNameMessage(alloc, &mcp_configs)) |message| {
        defer alloc.free(message);
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = message });
    }
    if (!state.cfg.allow_acp_mcp) {
        if (mcp_configs.items.items.len > 0) {
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "MCP servers are unavailable in this runtime",
            });
        }
    } else {
        try appendProfileMcpConfigsIfRequested(state, alloc, msg.params_raw, &mcp_configs);
        try appendProjectMcpConfigs(state, alloc, workspace_root, &mcp_configs);
    }
    var mcp_preparation = try mcp_servers.prepare(
        alloc,
        &mcp_configs,
        workspace_root,
        state.client_elicitation,
        server.legacyUrlCompletionSink(state),
    );
    defer mcp_preparation.deinit(alloc);
    switch (mcp_preparation) {
        .none, .host => {},
        .failed => |message| return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
        }),
    }
    const session_host = mcp_preparation.takeHost();
    var session_host_owned = true;
    defer if (session_host_owned) if (session_host) |h| h.destroy();

    if (state.active_session) |*active| {
        // Loading the active session into another workspace releases it and
        // reopens it through the ordinary rebinding path below.
        if (sameSessionId(active.session_id, session_id) and workspace != null) {
            server.cancelAndReapActivePrompt(state);
            try server.releaseActiveSession(state);
        }
    }
    if (state.active_session) |*active| {
        if (sameSessionId(active.session_id, session_id)) {
            server.cancelAndReapActivePrompt(state);
            server.disableSubagentHost(state);
            state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
            const previous_host = active.mcp_host;
            active.mcp_host = session_host;
            session_host_owned = false;
            const start = server.loadStartingMode(state, alloc);
            active.mode = start.id;
            active.permission_mode = start.permission_mode;
            state.subagent_authority_mutex.unlock(io_mod.getIo());
            if (previous_host) |h| h.stop();
            server.enableSubagentHost(state);
            // One map, so a recovered read can name a call from an earlier turn.
            var sources: runtime_tool_presentation.ReplayedSavedOutputSources = .{};
            defer sources.deinit(alloc);
            if (kind.replaysHistory()) {
                try sendActiveHistoryUpdates(state, alloc, session_id, &sources);
            }
            try sendActiveSessionInfoUpdate(state, alloc);
            return writeLoadSessionResponse(
                state,
                alloc,
                msg,
                active.model,
                observer_hooks,
            );
        }
    }

    var v2: ?*session_adapter.Session = null;
    var v2_owned = true;
    defer if (v2_owned) if (v2) |value| value.close();
    var v2_resumed: ?session_adapter.Resumed = null;
    defer if (v2_resumed) |*value| value.deinit(alloc);
    const v2_store = server.sessionsStore(state) orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.internal_error,
        .message = "Session store not available",
    });
    {
        // Converting a v1 session can be slow; the client is told why (D61).
        var notice: ConversionNotice = .{ .state = state, .alloc = alloc, .session_id = session_id };
        v2_store.notice = .{ .context = &notice, .emit = ConversionNotice.emit };
        defer v2_store.notice = null;
        v2 = session_adapter.Session.resumeSession(alloc, v2_store, .{ .id = session_id }, workspace_root, .acp) catch |err|
            return handleLoadFailure(state, alloc, msg, err);
        v2_resumed = v2.?.durableState(alloc, workspace_root) catch |err|
            return handleLoadFailure(state, alloc, msg, err);
    }
    const durable: *const session_codec.DurableSessionState = &v2_resumed.?.state;

    const sid_copy = try alloc.dupe(u8, durable.id);
    var sid_owned = true;
    defer if (sid_owned) alloc.free(sid_copy);
    const effective_provider = if (state.process_provider_override)
        state.provider
    else
        durable.preferences.provider;
    const effective_model = if (state.process_model_override or state.process_provider_override)
        state.selected_model
    else
        durable.preferences.model;
    var staged_credential = server.prepareCredentialForProvider(state, effective_provider) catch |err| {
        if (err != error.ProviderCredentialUnavailable) return err;
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = if (effective_provider == .codex)
                credentials.missing_chatgpt_credential_message
            else if (effective_provider == .grok)
                credentials.missing_grok_credential_message
            else if (effective_provider == .configured)
                "Configured provider authentication is unavailable"
            else
                credentials.missing_credential_message,
        });
    };
    defer if (staged_credential) |*credential| credential.deinit(alloc);
    const model_copy = try alloc.dupe(u8, effective_model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model_copy);

    var session_rt = session_runtime.SessionRuntime.init(state.cfg.max_history_turns);
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    try session_rt.restoreWithPermissionState(
        alloc,
        durable.conversation_language,
        durable.history,
        durable.permission_state,
    );
    // Read before the active session is released, so an unreadable prompt
    // fails this restore without replacing a different active session. A
    // same-session `cwd` rebind has already released it above.
    var client_system_prompt: ?[]u8 = restoredClientSystemPrompt(state.alloc, v2.?) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ClientSystemPromptUnreadable => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Session client system prompt could not be restored",
        }),
    };
    defer if (client_system_prompt) |text| state.alloc.free(text);
    // The session's downloads are its blobs (D44).
    session_rt.configureWebFetchArtifactBlobs(alloc, try v2.?.childCapability(), v2.?.id());
    server.cancelAndReapActivePrompt(state);
    activateSession(state, .{
        .session_id = sid_copy,
        .v2 = v2.?,
        .model = model_copy,
        .provider = effective_provider,
        .credential = if (staged_credential) |*credential| credential else null,
        .fast_mode = durable.preferences.fast_mode,
        .ultrafast_mode = restoredUltrafastMode(state, durable.preferences.ultrafast_mode),
        .effort = durable.preferences.effort,
        .session_rt = session_rt,
        .mcp_host = session_host,
        .client_system_prompt = client_system_prompt,
        .workspace = if (workspace) |*binding| binding else null,
    }) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to save active session",
        });
    client_system_prompt = null;
    v2_owned = false;
    sid_owned = false;
    model_owned = false;
    session_rt_owned = false;
    session_host_owned = false;
    // One map, so a recovered read can name a call from an earlier turn.
    var sources: runtime_tool_presentation.ReplayedSavedOutputSources = .{};
    defer sources.deinit(alloc);
    if (kind.replaysHistory()) {
        try sendActiveHistoryUpdates(state, alloc, session_id, &sources);
    }
    try sendActiveSessionInfoUpdate(state, alloc);

    try writeLoadSessionResponse(
        state,
        alloc,
        msg,
        state.active_session.?.model,
        observer_hooks,
    );
}

/// Adds the user's profile MCP servers after the request's own servers when
/// the client sets `_meta.fx.profileMcpServers`. ACP sessions otherwise use
/// only client-supplied and approved project servers. Request entries win
/// name collisions, and profile entries win over project entries.
fn appendProfileMcpConfigsIfRequested(
    state: *server.ServerState,
    alloc: Allocator,
    params_raw: ?[]const u8,
    configs: *mcp_servers.OwnedServerConfigs,
) !void {
    if (!profileMcpRequested(alloc, params_raw)) return;
    const home = state.cfg.home_override orelse io_mod.homeDir() orelse {
        debug_trace.logf("mcp", "ACP profile MCP servers skipped reason=no_home", .{});
        return;
    };
    const config_path = try builtin_mcp.configPathFromHome(alloc, home);
    defer alloc.free(config_path);
    var profile = builtin_mcp.loadConfigFromPath(alloc, config_path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("mcp", "ACP profile MCP servers unavailable err={s}", .{@errorName(err)});
        return;
    };
    defer {
        for (profile.items) |*config| config.deinit(alloc);
        profile.deinit(alloc);
    }
    debug_trace.logf("mcp", "ACP profile MCP servers requested count={d}", .{profile.items.len});
    try project_config.appendWorkspaceAfterAcpPrimary(alloc, &configs.items, &profile);
}

fn profileMcpRequested(alloc: Allocator, params_raw: ?[]const u8) bool {
    const raw = params_raw orelse return false;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return acp_types.fxMetaBool(parsed.value.object, "profileMcpServers") orelse false;
}

fn appendProjectMcpConfigs(
    state: *server.ServerState,
    alloc: Allocator,
    workspace_root: []const u8,
    configs: *mcp_servers.OwnedServerConfigs,
) !void {
    var choices = if (state.cfg.home_override) |home|
        config_runtime.loadProjectMcpChoicesFromHome(alloc, home, workspace_root) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("mcp", "ACP workspace MCP choices unavailable err={s}", .{@errorName(err)});
            return;
        }
    else
        config_runtime.loadProjectMcpChoices(alloc, workspace_root) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("mcp", "ACP workspace MCP choices unavailable err={s}", .{@errorName(err)});
            return;
        };
    defer choices.deinit(alloc);

    var workspace = try workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        choices.choices,
    );
    defer workspace.deinit(alloc);
    for (workspace.diagnostics.items) |diagnostic| {
        var name_buf: [256]u8 = undefined;
        var variable_buf: [160]u8 = undefined;
        debug_trace.logf(
            "mcp",
            "ACP workspace MCP config skipped cause={s} server={s} field={s} variable={s}",
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
    // Project servers run in the session's workspace, which a client `cwd`
    // may have moved away from the directory fx was launched in.
    for (workspace.configs.items) |*config| {
        if (config.transport != .stdio or config.cwd != null) continue;
        config.cwd = try alloc.dupe(u8, workspace_root);
    }
    try project_config.appendWorkspaceAfterAcpPrimary(
        alloc,
        &configs.items,
        &workspace.configs,
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
    observer_hooks: ?libfx_hooks.Config,
) !void {
    state.active_session.?.observer_hooks = observer_hooks;
    try server.refreshModelCatalogForOptions(state);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"configOptions\":[");
    if (comptime !host_target.is_wasm) {
        try writeProviderConfigOption(&out.writer, state.active_session.?.provider, state.configured_providers.definitions);
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
        state.active_session.?.mode,
    );
    if (effortConfigState(state)) |config| {
        try out.writer.writeAll(",");
        try writeEffortConfigOption(&out.writer, config.efforts, config.current);
    }
    if (fastConfigState(state)) |current| {
        try out.writer.writeAll(",");
        try writeFastConfigOption(&out.writer, current);
    }
    if (ultrafastConfigState(state)) |current| {
        try out.writer.writeAll(",");
        try writeUltrafastConfigOption(&out.writer, current);
    }
    try out.writer.writeAll("],\"modes\":{\"currentModeId\":");
    try writeJsonStr(state.active_session.?.mode, &out.writer);
    try out.writer.writeAll(",\"availableModes\":");
    try writeModesArray(&out.writer, state.cfg.mode_registry);
    try out.writer.writeByte('}');
    if (observer_hooks != null) try out.writer.writeAll(",\"_meta\":{\"fx\":{\"hooksVersion\":1}}");
    try out.writer.writeByte('}');

    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

fn freshAcpState(
    state: *server.ServerState,
    alloc: Allocator,
    workspace_root: []const u8,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = try session_store.generateSessionId(alloc);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, workspace_root);
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
            .ultrafast_mode = state.configured_ultrafast_mode,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

fn restoredUltrafastMode(state: *const server.ServerState, preference: bool) bool {
    return state.process_ultrafast_override orelse preference;
}

const SessionActivation = struct {
    session_id: []u8,
    v2: *session_adapter.Session,
    model: []u8,
    provider: model_provider.ProviderId,
    credential: ?*credentials.Credential = null,
    fast_mode: bool,
    ultrafast_mode: bool,
    effort: types.ReasoningEffort,
    session_rt: session_runtime.SessionRuntime,
    mcp_host: ?*mcp_host.Host = null,
    /// Owned client prompt. The session takes it over on success; the caller
    /// frees it when activation fails.
    client_system_prompt: ?[]u8 = null,
    /// Workspace named by the request's `cwd`, installed once the previous
    /// session is released. Left empty after a successful activation.
    workspace: ?*workspace_binding.Binding = null,
};

/// Returns the owned persisted client prompt of a restored session, or an
/// empty slice when it has none. A stored prompt that cannot be read fails
/// the restore instead of running the session without the client's
/// instructions.
fn restoredClientSystemPrompt(
    alloc: Allocator,
    session: *session_adapter.Session,
) error{ OutOfMemory, ClientSystemPromptUnreadable }![]u8 {
    const text = session.clientPrompt(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf(
                "acp",
                "client system prompt unreadable session={s} err={s}",
                .{ session.id(), @errorName(err) },
            );
            return error.ClientSystemPromptUnreadable;
        },
    };
    return text orelse &.{};
}

/// Returns the tool identity record of a restored session. A record that
/// cannot be read is reported in the trace and replaced by an empty one.
fn restoredToolIdentities(
    alloc: Allocator,
    session: *session_adapter.Session,
) Allocator.Error!tool_call_identities.Record {
    const record = blk: {
        const stored = session.toolIdentities(alloc) catch |err| break :blk err;
        const bytes = stored orelse return .{};
        defer alloc.free(bytes);
        break :blk tool_call_identities.parse(alloc, bytes);
    };
    return record catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf(
                "acp",
                "dropped unreadable tool identity record session={s} err={s}",
                .{ session.id(), @errorName(err) },
            );
            return .{};
        },
    };
}

fn activateSession(state: *server.ServerState, activation: SessionActivation) !void {
    try server.releaseActiveSession(state);
    const client_system_prompt: []u8 = activation.client_system_prompt orelse &.{};
    if (activation.workspace) |binding| try workspace_binding.commit(state, binding);
    if (activation.credential) |credential| server.adoptServerCredential(state, credential);
    const start = server.loadStartingMode(state, state.alloc);
    // Nothing after this load can fail before the session takes ownership.
    const tool_identities = try restoredToolIdentities(state.alloc, activation.v2);
    state.active_session = .{
        .session_id = activation.session_id,
        .v2 = activation.v2,
        .client_system_prompt = client_system_prompt,
        .tool_identities = tool_identities,
        .model = activation.model,
        .provider = activation.provider,
        .mode = start.id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .credential_refresh_after_ms = state.credential_refresh_after_ms,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = activation.fast_mode,
        .ultrafast_mode = activation.ultrafast_mode,
        .effort = activation.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = start.permission_mode,
        .permission_rules = state.permission_rules,
        .session_rt = activation.session_rt,
        .mcp_host = activation.mcp_host,
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    server.enableSubagentHost(state);
}

/// A v2 storage fault as one sentence after `what`, such as "Session could
/// not be loaded: the disk is full"; null for any other error.
pub fn v2StorageFaultMessage(comptime what: []const u8, err: anyerror) ?[]const u8 {
    return switch (err) {
        error.AccessDenied => what ++ ": permission denied",
        error.ReadOnlyFileSystem => what ++ ": the disk is read-only",
        error.NoSpaceLeft => what ++ ": the disk is full",
        error.FileTooBig => what ++ ": a file-size limit was reached",
        else => null,
    };
}

test "a v2 storage fault reads as its cause, and other errors have no such message" {
    try std.testing.expectEqualStrings("Session could not be loaded: permission denied", v2StorageFaultMessage("Session could not be loaded", error.AccessDenied).?);
    try std.testing.expectEqualStrings("Session could not be saved: the disk is read-only", v2StorageFaultMessage("Session could not be saved", error.ReadOnlyFileSystem).?);
    try std.testing.expectEqualStrings("Session could not be saved: the disk is full", v2StorageFaultMessage("Session could not be saved", error.NoSpaceLeft).?);
    try std.testing.expectEqualStrings("Session could not be saved: a file-size limit was reached", v2StorageFaultMessage("Session could not be saved", error.FileTooBig).?);
    try std.testing.expect(v2StorageFaultMessage("Session could not be loaded", error.SessionBusy) == null);
}

/// A v2 store's notice that converting a v1 session is slow, sent to the
/// client as the session's agent text, as fx's other notices are.
const ConversionNotice = struct {
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,

    fn emit(context: ?*anyopaque, text: []const u8) void {
        const notice: *ConversionNotice = @ptrCast(@alignCast(context.?));
        sendAgentHistoryChunk(notice.state, notice.alloc, notice.session_id, text) catch |err|
            debug_trace.logf("acp", "event=conversion_notice_dropped err={s}", .{@errorName(err)});
    }
};

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
    // v2 names a storage fault (D29); v1 keeps its messages below.
    if (state.sessions_v2 != null) {
        if (v2StorageFaultMessage("Session could not be loaded", err)) |message| {
            return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.internal_error, .message = message });
        }
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
            .message = "Subagent child sessions cannot be resumed directly",
        });
    }
    if (err == error.InvalidSessionFormat or
        err == error.UnsupportedSessionSchema or
        err == error.UnsupportedSessionFormat or
        err == error.LegacySessionTooLarge or
        err == error.LegacySessionReadResourceExhausted or
        err == error.SessionAuthorityBoundaryUnavailable or
        err == error.SessionAuthorityIntentCleanupPending or
        err == error.SessionPathUnsafe or
        err == error.DurablePathUnsafe)
    {
        // A v1 session that can't be converted says why (D61).
        if (state.sessions_v2) |*store| if (err == error.InvalidSessionFormat) if (store.conversionProblem()) |problem| {
            const message = try alloc.print("Session could not be loaded (InvalidSessionFormat): {s}", .{problem});
            defer alloc.free(message);
            return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.internal_error, .message = message });
        };
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
    var params_arena = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(params_arena);
    const params = parseListSessionsParams(params_arena.allocator(), msg) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    // No store lists as no sessions.
    const v2_store = server.sessionsStore(state) orelse return state.writer.writeResponse(alloc, msg.id, "{\"sessions\":[]}");
    return listV2Sessions(state, alloc, msg, v2_store, params);
}

/// `session/list` on v2, paged as v1 pages it: newest first, one
/// workspace when `cwd` is given, and only what follows the cursor.
fn listV2Sessions(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    v2_store: *session_adapter.Store,
    params: ListSessionsParams,
) !void {
    // Matched as v1 matches it: exactly, after trailing slashes.
    const cwd = if (params.cwd) |value| session_store_paths.normalizeWorkspaceRoot(value) else null;
    var page = session_adapter.listPage(v2_store, alloc, cwd, params.continuation, session_store.session_list_default_limit) catch |err| {
        debug_trace.logf("acp", "session operation=list outcome=failed backend=v2 error={s}", .{@errorName(err)});
        try state.writer.writeResponse(alloc, msg.id, "{\"sessions\":[]}");
        return;
    };
    defer page.deinit(alloc);
    try writeSessionPage(state, alloc, msg, page.summaries.items, page.has_more);
}

fn writeSessionPage(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    summaries: []const session_store.SessionSummary,
    has_more: bool,
) !void {
    var next_cursor_buf: [320]u8 = undefined;
    const next_cursor = if (has_more and summaries.len > 0)
        try std.mem.print(&next_cursor_buf, "v1:{d}:{s}", .{
            summaries[summaries.len - 1].updated_at_ms,
            summaries[summaries.len - 1].id,
        })
    else
        null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"sessions\":[");
    var wrote_session = false;
    for (summaries) |summary| {
        const workspace_root = summary.workspace_root orelse {
            debug_trace.logf(
                "acp",
                "session operation=list outcome=omitted id={s} reason=workspace_unknown",
                .{summary.id},
            );
            continue;
        };
        if (!std.Io.Dir.path.isAbsolute(workspace_root)) {
            debug_trace.logf(
                "acp",
                "session operation=list outcome=omitted id={s} reason=workspace_not_absolute",
                .{summary.id},
            );
            continue;
        }
        if (wrote_session) try out.writer.writeAll(",");
        wrote_session = true;
        try out.writer.writeAll("{\"sessionId\":");
        try writeJsonStr(summary.id, &out.writer);
        try out.writer.writeAll(",\"cwd\":");
        try writeJsonStr(workspace_root, &out.writer);
        if (summary.title) |title| {
            try out.writer.writeAll(",\"title\":");
            try writeJsonStr(title, &out.writer);
        }
        try out.writer.writeAll(",\"updatedAt\":");
        const iso = try formatIso8601(alloc, summary.updated_at_ms);
        defer alloc.free(iso);
        try writeJsonStr(iso, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]");
    if (next_cursor) |cursor| {
        try out.writer.writeAll(",\"nextCursor\":");
        try writeJsonStr(cursor, &out.writer);
    }
    try out.writer.writeAll("}");

    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

const ListSessionsParams = struct {
    cwd: ?[]const u8 = null,
    continuation: ?session_store.ResumableSessionContinuation = null,
};

fn parseListSessionsParams(
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !ListSessionsParams {
    const raw = msg.params_raw orelse return .{};
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch
        return error.InvalidParams;
    if (parsed.value != .object) return error.InvalidParams;
    var result = ListSessionsParams{};
    if (parsed.value.object.get("cwd")) |cwd| {
        if (cwd != .null) {
            if (cwd != .string or !std.Io.Dir.path.isAbsolute(cwd.string)) {
                return error.InvalidParams;
            }
            result.cwd = cwd.string;
        }
    }
    if (parsed.value.object.get("cursor")) |cursor| {
        if (cursor != .null) {
            if (cursor != .string) return error.InvalidParams;
            result.continuation = parseListCursor(cursor.string) catch
                return error.InvalidParams;
        }
    }
    return result;
}

fn parseListCursor(raw: []const u8) !session_store.ResumableSessionContinuation {
    if (raw.len == 0 or raw.len > 320) return error.InvalidParams;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidParams, "v1")) {
        return error.InvalidParams;
    }
    const updated_at_ms = std.fmt.parseInt(
        i64,
        fields.next() orelse return error.InvalidParams,
        10,
    ) catch return error.InvalidParams;
    const id = fields.next() orelse return error.InvalidParams;
    if (updated_at_ms < 0 or fields.next() != null) return error.InvalidParams;
    session_store.validateSessionId(id) catch return error.InvalidParams;
    return .{ .updated_at_ms = updated_at_ms, .id = id };
}

fn sendActiveHistoryUpdates(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    sources: *runtime_tool_presentation.ReplayedSavedOutputSources,
) !void {
    const active = &state.active_session.?;
    // Every saved turn, not only those in memory.
    if (active.v2) |v2| {
        const Visitor = struct {
            state: *server.ServerState,
            alloc: Allocator,
            session_id: []const u8,
            sources: *runtime_tool_presentation.ReplayedSavedOutputSources,

            pub fn append(self: *@This(), turn: types.HistoryTurn) !void {
                try sendHistoryTurnAsUpdates(self.state, self.alloc, self.session_id, self.sources, turn);
            }
        };
        var visitor = Visitor{ .state = state, .alloc = alloc, .session_id = session_id, .sources = sources };
        return v2.visitHistory(alloc, &visitor);
    }
    for (active.session_rt.agent.history.items) |turn| {
        try sendHistoryTurnAsUpdates(state, alloc, session_id, sources, turn);
    }
}

fn sendHistoryTurnAsUpdates(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    sources: *runtime_tool_presentation.ReplayedSavedOutputSources,
    turn: types.HistoryTurn,
) !void {
    switch (turn) {
        .assistant => |assistant| try sendUserHistoryTurn(state, alloc, session_id, assistant.user),
        .interrupted => |interrupted| try sendUserHistoryTurn(state, alloc, session_id, interrupted.user),
        .compacted_summary => return,
    }

    switch (turn) {
        .assistant => |assistant| {
            try sendExecutionHistory(state, alloc, session_id, sources, assistant.execution);
            try sendAgentHistoryChunk(state, alloc, session_id, assistant.assistant);
        },
        .interrupted => |i| {
            try sendExecutionHistory(state, alloc, session_id, sources, i.execution);
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

fn sendUserHistoryTurn(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    user: types.UserTurn,
) !void {
    // A turn the terminal app sent to resume an interrupted request replays
    // as the line it showed, not as fx's note to the model.
    if (std.mem.eql(u8, user.text, session_runtime.resumed_request_prompt)) {
        return sendAgentHistoryChunk(state, alloc, session_id, session_runtime.resumed_request_notice.body);
    }
    // A turn a subagent's report or message started is not the user's
    // words, so it never replays as theirs; the agent's reply still does.
    if (user.author != .user) {
        debug_trace.logf("acp", "history replay skipped non-user prompt author={s} bytes={d}", .{ @tagName(user.author), user.text.len });
        return;
    }
    var message_id: acp_types.MessageIdBuffer = undefined;
    const stable_message_id = acp_types.generateMessageId(&message_id);
    if (user.text.len > 0) {
        try sendUserHistoryChunk(state, alloc, session_id, stable_message_id, user.text);
    }
    for (user.images) |attachment| {
        var snapshot = image_attachments.loadVerifiedSnapshot(alloc, attachment, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            debug_trace.logf(
                "acp",
                "image history replay omitted id={d} err={s}",
                .{ attachment.id, @errorName(err) },
            );
            var unavailable: [96]u8 = undefined;
            const notice = try std.mem.print(
                &unavailable,
                "Image #{d} unavailable",
                .{attachment.id},
            );
            try sendUserHistoryChunk(state, alloc, session_id, stable_message_id, notice);
            continue;
        };
        defer snapshot.deinit(alloc);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll("{\"sessionId\":");
        try writeJsonStr(session_id, &out.writer);
        try out.writer.writeAll(",\"update\":");
        try acp_types.writeUserImageChunk(
            &out.writer,
            stable_message_id,
            snapshot.media_type,
            snapshot.bytes,
        );
        try out.writer.writeAll("}");
        try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
    }
}

fn sendUserHistoryChunk(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    message_id: []const u8,
    text: []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeUserMessageChunk(
        &out.writer,
        message_id,
        text,
    );
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

fn sendExecutionHistory(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    sources: *runtime_tool_presentation.ReplayedSavedOutputSources,
    execution: types.ExecutionMemory,
) !void {
    if (execution.isEmpty()) return;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(arena_state);
    const frames = try planExecutionReplay(
        arena_state.allocator(),
        tool_call_presentation.activeToolRegistry(state),
        activeSessionHost(state),
        if (state.active_session) |*active| &active.tool_identities else null,
        .{
            .alloc = alloc,
            .workspace_root = if (state.active_session) |*active| active.workspace_root else state.workspace_root,
            .sources = sources,
        },
        execution,
    );
    for (frames) |frame| {
        switch (frame) {
            .assistant_text => |text| try sendAgentHistoryChunk(state, alloc, session_id, text),
            .steering_text => |text| try sendSteeringHistoryChunk(state, alloc, session_id, text),
            .tool_call => |call| try sendHistoryToolCall(state, alloc, session_id, call),
        }
    }
}

const ReplayToolCall = struct {
    id: []const u8,
    name: []const u8,
    title: []const u8,
    meta: acp_types.ToolCallMeta,
    kind: acp_types.ToolCallKind,
    status: acp_types.ToolCallStatus,
    raw_input: ?std.json.Value,
    content_text: ?[]const u8,
};

const ReplayFrame = union(enum) {
    assistant_text: []const u8,
    /// A steering message the turn absorbed, replayed where it was inserted.
    steering_text: []const u8,
    tool_call: ReplayToolCall,
};

fn replayStatus(result: ?types.PersistedToolResult) acp_types.ToolCallStatus {
    const r = result orelse return .pending;
    return switch (r.status) {
        .success => .completed,
        .failure => .failed,
    };
}

fn findToolResultIndex(results: []const types.PersistedToolResult, call_id: []const u8) ?usize {
    for (results, 0..) |result, i| {
        if (std.mem.eql(u8, result.tool_call_id, call_id)) return i;
    }
    return null;
}

/// Calls whose saved output later replayed reads name, kept across the turns
/// of one replay.
const ReplaySources = struct {
    alloc: Allocator,
    workspace_root: []const u8,
    sources: *runtime_tool_presentation.ReplayedSavedOutputSources,
};

fn planToolCallFrame(
    arena: Allocator,
    registry: tool_dispatch.Registry,
    session_host: ?*mcp_host.Host,
    identities: ?*tool_call_identities.Record,
    replay_sources: ReplaySources,
    replayed_call: types.ToolCall,
    result: ?types.PersistedToolResult,
) !ReplayToolCall {
    var call = replayed_call;
    call.resolved_display_target = try runtime_tool_presentation.readToolResultDisplayTarget(
        arena,
        registry,
        call,
        replay_sources.sources,
    );
    if (result) |saved| try replay_sources.sources.record(
        replay_sources.alloc,
        registry,
        replay_sources.workspace_root,
        call,
        saved,
    );
    const name = tool_call_presentation.acpToolName(call.name);
    // MCP identity comes from the live catalog, or from the identity recorded
    // when the session made the call; it is never guessed from the exposed
    // name.
    const mcp_identity = if (registry.lookup(call.name) == null)
        (if (session_host) |h| h.catalog.toolIdentity(arena, call.name) catch null else null) orelse
            if (identities) |record| try record.lookup(arena, call.name) else null
    else
        null;
    const presentation = tool_call_presentation.describeToolCall(registry, arena, call, mcp_identity);
    const masked_arguments = try agent_execution_memory.redactToolArgumentsJson(arena, call.name, call.arguments_json);
    // Parsed with the arena and returned in the frame; no deinit, the caller's
    // arena frees it in bulk.
    const parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(
        std.json.Value,
        arena,
        masked_arguments,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    return .{
        .id = call.id,
        .name = name,
        .title = presentation.title,
        .meta = presentation.meta,
        .kind = tool_call_presentation.mapToolKind(name),
        .status = replayStatus(result),
        .raw_input = if (parsed) |p| p.value else null,
        // Result content follows the same unmasked tool-update content
        // contract as the live path; only arguments are masked for display
        // (redactToolArgumentsJson).
        .content_text = if (result) |r| if (r.output.len > 0)
            try tool_call_presentation.shellUpdateContentText(arena, call.name, r.output) orelse
                tool_call_presentation.toolUpdateContentText(r.status == .failure, r.output)
        else
            null else null,
    };
}

fn activeSessionHost(state: *server.ServerState) ?*mcp_host.Host {
    if (comptime host_target.is_wasm) return null;
    const session = if (state.active_session) |*active| active else return null;
    return session.mcp_host;
}

/// Maps a persisted execution memory onto the same session/update frame
/// sequence the live prompt path emits: interleaved assistant text plus one
/// tool_call announcement (and final tool_call_update) per tool call, with
/// absorbed steering replayed where the turn took it in.
/// The returned frames borrow from `execution` and `arena`; the caller owns
/// the slice and must free it with the arena.
fn planExecutionReplay(
    arena: Allocator,
    registry: tool_dispatch.Registry,
    session_host: ?*mcp_host.Host,
    identities: ?*tool_call_identities.Record,
    replay_sources: ReplaySources,
    execution: types.ExecutionMemory,
) ![]ReplayFrame {
    var frames: std.ArrayList(ReplayFrame) = .empty;
    var steering_index = try appendSteeringReplay(arena, &frames, execution.steering, 0, 0);
    for (execution.tool_steps, 0..) |step, step_index| {
        if (step.assistant) |assistant| {
            if (assistant.len > 0) try frames.append(arena, .{ .assistant_text = assistant });
        }
        const matched = try arena.alloc(bool, step.tool_results.len);
        @memset(matched, false);
        for (step.tool_calls) |call| {
            const result: ?types.PersistedToolResult = if (findToolResultIndex(step.tool_results, call.id)) |i| blk: {
                matched[i] = true;
                break :blk step.tool_results[i];
            } else null;
            try frames.append(arena, .{ .tool_call = try planToolCallFrame(arena, registry, session_host, identities, replay_sources, call, result) });
        }
        // Results without a surviving call record (e.g. trimmed history) still
        // replay as completed frames so the transcript stays faithful.
        for (step.tool_results, 0..) |result, i| {
            if (matched[i]) continue;
            const call: types.ToolCall = .{
                .id = result.tool_call_id,
                .name = result.tool_name,
                .arguments_json = "{}",
            };
            try frames.append(arena, .{ .tool_call = try planToolCallFrame(arena, registry, session_host, identities, replay_sources, call, result) });
        }
        steering_index = try appendSteeringReplay(arena, &frames, execution.steering, steering_index, step_index + 1);
    }
    // Entries past the last step still replay, in order, rather than vanish.
    _ = try appendSteeringReplay(arena, &frames, execution.steering, steering_index, null);
    // `execution.context_notes` and `execution.runtime_context` never replay:
    // they are fx's context for the model, not messages of the conversation
    // (D93, D94).
    return frames.toOwnedSlice(arena);
}

/// Appends the steering entries recorded after `completed_steps` tool steps
/// (every remaining entry when null), each preceded by the assistant text the
/// turn had streamed before absorbing it. Returns the next unreplayed index.
fn appendSteeringReplay(
    arena: Allocator,
    frames: *std.ArrayList(ReplayFrame),
    steering: []const types.PersistedSteering,
    start: usize,
    completed_steps: ?usize,
) !usize {
    var index = start;
    while (index < steering.len) : (index += 1) {
        const entry = steering[index];
        if (completed_steps) |count| if (entry.after_tool_step_count != count) break;
        if (entry.assistant_prefix) |prefix| {
            if (prefix.len > 0) try frames.append(arena, .{ .assistant_text = prefix });
        }
        if (entry.text.len > 0) try frames.append(arena, .{ .steering_text = entry.text });
    }
    return index;
}

fn sendHistoryToolCall(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    call: ReplayToolCall,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeToolCall(&out.writer, call.id, call.name, call.title, call.kind, .pending, call.raw_input, call.meta);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
    if (call.status == .pending) return;
    out.clearRetainingCapacity();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeToolCallUpdate(&out.writer, call.id, call.status, call.content_text);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

/// Replays absorbed steering. The original request ID is not persisted, so the
/// frame carries a null `requestId`.
fn sendSteeringHistoryChunk(state: *server.ServerState, alloc: Allocator, session_id: []const u8, text: []const u8) !void {
    var message_id: acp_types.MessageIdBuffer = undefined;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeSteeringUserMessageChunk(
        &out.writer,
        acp_types.generateMessageId(&message_id),
        text,
        null,
        null,
    );
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

fn sendAgentHistoryChunk(state: *server.ServerState, alloc: Allocator, session_id: []const u8, text: []const u8) !void {
    var message_id: acp_types.MessageIdBuffer = undefined;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeAgentMessageChunk(
        &out.writer,
        acp_types.generateMessageId(&message_id),
        text,
    );
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

pub fn sendActiveSessionInfoUpdate(state: *server.ServerState, alloc: Allocator) !void {
    const active = if (state.active_session) |*session| session else return;
    var metadata = try session_display_metadata.deriveFromHistory(
        alloc,
        active.session_rt.agent.history.items,
    );
    defer metadata.deinit(alloc);
    const v2_info: ?session_adapter.Session.Info = if (active.v2) |v2| try v2.info(alloc) else null;
    if (v2_info) |info| if (info.title) |title| {
        metadata.deinit(alloc);
        metadata = .{ .present = true, .title = title };
    };
    const updated_at_ms = if (active.wasm_state) |durable|
        durable.updated_at_ms
    else if (v2_info) |info|
        // Not saved yet: a new session has no line before its first prompt.
        if (info.updated_ms > 0) info.updated_ms else io_mod.milliTimestamp()
    else
        io_mod.milliTimestamp();
    const updated_at = try formatIso8601(alloc, @max(updated_at_ms, 0));
    defer alloc.free(updated_at);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(active.session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeSessionInfoUpdate(&out.writer, metadata.title, updated_at);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

pub fn sendActiveSessionUsageUpdate(state: *server.ServerState, alloc: Allocator) !void {
    const active = if (state.active_session) |*session| session else return;
    const used = active.context_used.load(.acquire);
    if (used == 0) return;
    const provider_bundle = state.cfg.provider_set.select(active.provider);
    const capabilities = state.capability_resolver.available(
        active.model,
        provider_bundle.fallbackModelCapabilities(active.model),
    );
    const context_window = capabilities.context_window orelse return;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(active.session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeUsageUpdate(&out.writer, used, context_window);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

fn formatIso8601(alloc: Allocator, timestamp_ms: i64) ![]u8 {
    const epoch_secs: u64 = @intCast(@divTrunc(timestamp_ms, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return alloc.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @backingInt(month_day.month),
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
    definitions: []const @import("../core/config/configured_provider.zig").Definition,
) !void {
    try w.writeAll("{\"id\":\"provider\",\"name\":\"Provider\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(current.label(), w);
    try w.writeAll(",\"options\":[{\"value\":\"gateway\",\"name\":\"Vercel AI Gateway\"},{\"value\":\"codex\",\"name\":\"Codex subscription\"}");
    if (comptime !host_target.is_wasm) {
        try w.writeAll(",{\"value\":\"grok\",\"name\":\"Grok subscription\"}");
        for (definitions) |definition| {
            try w.writeAll(",{\"value\":");
            try writeJsonStr(definition.id, w);
            try w.writeAll(",\"name\":");
            try writeJsonStr(definition.id, w);
            try w.writeAll("}");
        }
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
        // ACP leaves extra value fields to `_meta`.
        try w.writeAll(",\"_meta\":{\"fx\":{\"permissionMode\":");
        try writeJsonStr(permissions.permissionModeLabel(mode.permission_mode), w);
        try w.writeAll("}}}");
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

pub const EffortConfigState = struct {
    efforts: model_capabilities.ReasoningEffortOptions,
    current: types.ReasoningEffort,
};

/// Reasoning-effort selector state for the active session, or null when the
/// active model advertises no effort options (matching the TUI, which hides
/// the effort picker for those models).
pub fn effortConfigState(state: *server.ServerState) ?EffortConfigState {
    const active = if (state.active_session) |*session| session else return null;
    const bundle = state.cfg.provider_set.select(active.provider);
    const capabilities = state.capability_resolver.available(
        active.model,
        bundle.fallbackModelCapabilities(active.model),
    );
    if (capabilities.reasoning_efforts.len == 0) return null;
    return .{ .efforts = capabilities.reasoning_efforts, .current = active.effort };
}

/// Active-session Fast selector state. Like the CLI's speed picker, the option
/// is exposed only when the active model offers a Fast lane.
pub fn fastConfigState(state: *server.ServerState) ?bool {
    const active = if (state.active_session) |*session| session else return null;
    const bundle = state.cfg.provider_set.select(active.provider);
    const capabilities = state.capability_resolver.available(
        active.model,
        bundle.fallbackModelCapabilities(active.model),
    );
    if (!capabilities.supports_fast_mode) return null;
    return active.fast_mode;
}

pub fn writeFastConfigOption(w: *std.Io.Writer, current: bool) !void {
    try w.writeAll("{\"id\":\"fast\",\"name\":\"Fast Mode\",\"description\":\"Uses the model's fast lane\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(if (current) "true" else "false", w);
    try w.writeAll(",\"options\":[{\"value\":\"false\",\"name\":\"off\"},{\"value\":\"true\",\"name\":\"on\"}]}");
}

test "writeFastConfigOption produces an off/on select with the current value" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFastConfigOption(&out.writer, true);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    const option = parsed.value.object;
    try std.testing.expectEqualStrings("fast", option.get("id").?.string);
    try std.testing.expectEqualStrings("true", option.get("currentValue").?.string);
    const choices = option.get("options").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), choices.len);
    try std.testing.expectEqualStrings("false", choices[0].object.get("value").?.string);
    try std.testing.expectEqualStrings("true", choices[1].object.get("value").?.string);
}

/// Active-session ultrafast selector state. The option is exposed only for a
/// verified Gateway catalog model with the explicit capability.
pub fn ultrafastConfigState(state: *server.ServerState) ?bool {
    const active = if (state.active_session) |*session| session else return null;
    if (active.provider != .gateway) return null;
    const bundle = state.cfg.provider_set.select(active.provider);
    const capabilities = state.capability_resolver.available(
        active.model,
        bundle.fallbackModelCapabilities(active.model),
    );
    if (!capabilities.supports_ultrafast_mode) return null;
    return active.ultrafast_mode;
}

pub fn writeUltrafastConfigOption(w: *std.Io.Writer, current: bool) !void {
    try w.writeAll("{\"id\":\"ultrafast\",\"name\":\"Ultrafast Mode\",\"description\":\"Uses the model's ultrafast Gateway lane\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(if (current) "true" else "false", w);
    try w.writeAll(",\"options\":[{\"value\":\"false\",\"name\":\"off\"},{\"value\":\"true\",\"name\":\"on\"}]}");
}

pub fn effortSupportedBy(efforts: model_capabilities.ReasoningEffortOptions, effort: types.ReasoningEffort) bool {
    if (effort == .auto) return true;
    for (efforts.slice()) |option| {
        if (option.eql(effort)) return true;
    }
    return false;
}

pub fn writeEffortConfigOption(
    w: *std.Io.Writer,
    efforts: model_capabilities.ReasoningEffortOptions,
    current: types.ReasoningEffort,
) !void {
    try w.writeAll("{\"id\":\"effort\",\"name\":\"Reasoning Effort\",\"description\":\"Controls how much the model thinks before responding\",\"category\":\"thought_level\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(current.label(), w);
    try w.writeAll(",\"options\":[{\"value\":\"auto\",\"name\":\"default\"}");
    var current_listed = current == .auto;
    for (efforts.slice()) |effort| {
        if (effort.eql(current)) current_listed = true;
        try w.writeAll(",{\"value\":");
        try writeJsonStr(effort.label(), w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(effort.displayLabel(), w);
        try w.writeAll("}");
    }
    // A persisted effort the active model does not advertise still renders, so
    // the select never shows a value outside its own option list.
    if (!current_listed) {
        try w.writeAll(",{\"value\":");
        try writeJsonStr(current.label(), w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(current.displayLabel(), w);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

test "writeEffortConfigOption produces thought_level select with auto first" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const efforts = model_capabilities.ReasoningEffortOptions.fromSlice(&.{
        types.ReasoningEffort.literal("low"),
        types.ReasoningEffort.literal("high"),
    });
    try writeEffortConfigOption(&out.writer, efforts, .literal("high"));
    const items = out.writer.buffered();
    try std.testing.expect(std.mem.find(u8, items, "\"id\":\"effort\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "\"category\":\"thought_level\"") != null);
    try std.testing.expect(std.mem.find(u8, items, "\"currentValue\":\"high\"") != null);
    const auto_index = std.mem.find(u8, items, "\"value\":\"auto\"").?;
    const low_index = std.mem.find(u8, items, "\"value\":\"low\"").?;
    try std.testing.expect(auto_index < low_index);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("select", parsed.value.object.get("type").?.string);
}

test "effortSupportedBy accepts auto and advertised names only" {
    const efforts = model_capabilities.ReasoningEffortOptions.fromSlice(&.{
        types.ReasoningEffort.literal("low"),
        types.ReasoningEffort.literal("high"),
    });
    try std.testing.expect(effortSupportedBy(efforts, .auto));
    try std.testing.expect(effortSupportedBy(efforts, .literal("high")));
    try std.testing.expect(!effortSupportedBy(efforts, .literal("max")));
}

test "writeEffortConfigOption appends an unadvertised current effort" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const efforts = model_capabilities.ReasoningEffortOptions.fromSlice(&.{
        types.ReasoningEffort.literal("low"),
    });
    try writeEffortConfigOption(&out.writer, efforts, .literal("max"));
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    const options = parsed.value.object.get("options").?.array;
    try std.testing.expectEqual(@as(usize, 3), options.items.len);
    try std.testing.expectEqualStrings("max", options.items[2].object.get("value").?.string);
}

test "formatIso8601 produces valid format" {
    const alloc = std.testing.allocator;
    const result = try formatIso8601(alloc, 1700000000000);
    defer alloc.free(result);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, result, "Z"));
    try std.testing.expect(std.mem.find(u8, result, "T") != null);
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

test "ACP history excludes typed summaries without filtering original user text" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var capture = try tmp.dir.createFile(io_mod.getIo(), "history.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());
    var state = try initAcpSessionTestState(arena, workspace, capture);
    defer state.deinit();

    try sendTestHistoryTurn(&state, arena, "session-1", .{ .compacted_summary = .{
        .summary = @constCast("internal summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } });
    try std.testing.expectEqual(@as(u64, 0), try capture.length(io_mod.getIo()));

    const original = "Explain <context_handoff> without hiding my question.";
    try sendTestHistoryTurn(&state, arena, "session-1", .{ .assistant = .{
        .user = .{ .text = @constCast(original) },
        .assistant = @constCast("original reply"),
    } });
    var file = try tmp.dir.openFile(io_mod.getIo(), "history.jsonl", .{});
    defer file.close(io_mod.getIo());
    const captured = try io_mod.readFileToEnd(alloc, &file, 16 * 1024);
    defer alloc.free(captured);
    try std.testing.expect(std.mem.find(u8, captured, original) != null);
    try std.testing.expect(std.mem.find(u8, captured, "original reply") != null);
    try std.testing.expect(std.mem.find(u8, captured, "internal summary") == null);
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
        try sendTestHistoryTurn(&state, arena, "session-1", .{ .interrupted = .{
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

test "ACP history replays a resumed request as its line, not fx's note" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var capture = try tmp.dir.createFile(io_mod.getIo(), "acp-resumed-history.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());

    {
        var state = try initAcpSessionTestState(arena, workspace, capture);
        defer state.deinit();
        try sendTestHistoryTurn(&state, arena, "session-1", .{ .assistant = .{
            .user = .{ .text = try arena.dupe(u8, session_runtime.resumed_request_prompt) },
            .assistant = try arena.dupe(u8, "RESUMED_ANSWER"),
        } });
    }

    const captured = try readCaptured(&capture, alloc);
    defer alloc.free(captured);
    try std.testing.expect(std.mem.find(u8, captured, "user_message_chunk") == null);
    try std.testing.expect(std.mem.find(u8, captured, "session_resumed") == null);
    const line = std.mem.find(u8, captured, session_runtime.resumed_request_notice.body).?;
    try std.testing.expect(std.mem.find(u8, captured[line..], "RESUMED_ANSWER") != null);
}

fn readCaptured(capture_file: *std.Io.File, alloc: Allocator) ![]u8 {
    try capture_file.sync(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, capture_file, 1024 * 1024);
}

test "ACP history replay emits structured tool call frames" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var capture = try tmp.dir.createFile(io_mod.getIo(), "history.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());
    var state = try initAcpSessionTestState(arena, workspace, capture);
    defer state.deinit();

    var calls = [_]types.ToolCall{
        .{ .id = "call_read_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" },
        .{ .id = "call_write_1", .name = "write_file", .arguments_json = "{\"path\":\"out.txt\",\"content\":\"done\"}" },
    };
    var results = [_]types.PersistedToolResult{
        .{
            .tool_call_id = @constCast("call_read_1"),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = @constCast("<content>readme text</content>"),
            .output_bytes = 27,
            .stored_output_bytes = 27,
        },
        .{
            .tool_call_id = @constCast("call_write_1"),
            .tool_name = @constCast("write_file"),
            .status = .failure,
            .output = @constCast("permission denied"),
            .output_bytes = 17,
            .stored_output_bytes = 17,
        },
    };
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("Let me inspect those files."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    try sendTestHistoryTurn(&state, arena, "session-1", .{ .assistant = .{
        .user = .{ .text = @constCast("read and write") },
        .assistant = @constCast("All done."),
        .execution = .{ .tool_steps = steps[0..] },
    } });

    const captured = try readCaptured(&capture, alloc);
    defer alloc.free(captured);

    try std.testing.expect(std.mem.find(u8, captured, "Previous tool execution") == null);
    try std.testing.expect(std.mem.find(u8, captured, "Let me inspect those files.") != null);
    try std.testing.expect(std.mem.find(u8, captured, "All done.") != null);

    const announce_read = std.mem.find(u8, captured, "\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"call_read_1\"").?;
    const announce_write = std.mem.find(u8, captured, "\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"call_write_1\"").?;
    const finish_read = std.mem.find(u8, captured, "\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"call_read_1\"").?;
    const finish_write = std.mem.find(u8, captured, "\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"call_write_1\"").?;
    try std.testing.expect(announce_read < finish_read);
    try std.testing.expect(announce_write < finish_write);
    try std.testing.expect(announce_read < announce_write);

    try std.testing.expect(std.mem.find(u8, captured, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, captured, "\"kind\":\"read\"") != null);
    try std.testing.expect(std.mem.find(u8, captured, "\"rawInput\":{\"path\":\"README.md\"}") != null);
    try std.testing.expect(std.mem.find(u8, captured, "\"status\":\"completed\"") != null);
    try std.testing.expect(std.mem.find(u8, captured, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.find(u8, captured, "readme text") != null);
    try std.testing.expect(std.mem.find(u8, captured, "permission denied") != null);
}

test "ACP history replay leaves resultless tool calls pending" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var capture = try tmp.dir.createFile(io_mod.getIo(), "history.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());
    var state = try initAcpSessionTestState(arena, workspace, capture);
    defer state.deinit();

    var calls = [_]types.ToolCall{
        .{ .id = "call_orphan", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" },
    };
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = calls[0..] }};
    try sendTestHistoryTurn(&state, arena, "session-1", .{ .interrupted = .{
        .user = .{ .text = @constCast("inspect") },
        .execution = .{ .tool_steps = steps[0..] },
    } });

    const captured = try readCaptured(&capture, alloc);
    defer alloc.free(captured);
    try std.testing.expect(std.mem.find(u8, captured, "\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"call_orphan\"") != null);
    try std.testing.expect(std.mem.find(u8, captured, "\"sessionUpdate\":\"tool_call_update\"") == null);
    try std.testing.expect(std.mem.find(u8, captured, "Previous tool execution") == null);
}

test "ACP history replay redacts sensitive tool arguments" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var capture = try tmp.dir.createFile(io_mod.getIo(), "history.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());
    var state = try initAcpSessionTestState(arena, workspace, capture);
    defer state.deinit();

    var calls = [_]types.ToolCall{
        .{ .id = "call_secret", .name = "run_command", .arguments_json = "{\"command\":\"echo ok\",\"api_key\":\"sk-live-secret\"}" },
    };
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call_secret"),
        .tool_name = @constCast("run_command"),
        .status = .success,
        .output = @constCast("ok"),
        .output_bytes = 2,
        .stored_output_bytes = 2,
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = calls[0..], .tool_results = results[0..] }};
    try sendTestHistoryTurn(&state, arena, "session-1", .{ .assistant = .{
        .user = .{ .text = @constCast("run it") },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = steps[0..] },
    } });

    const captured = try readCaptured(&capture, alloc);
    defer alloc.free(captured);
    try std.testing.expect(std.mem.find(u8, captured, "sk-live-secret") == null);
    try std.testing.expect(std.mem.find(u8, captured, "[REDACTED]") != null);
}

test "execution replay plan interleaves assistant text and orphan results" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var calls = [_]types.ToolCall{
        .{ .id = "call_a", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" },
    };
    var results = [_]types.PersistedToolResult{
        .{
            .tool_call_id = @constCast("call_a"),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = @constCast("alpha"),
            .output_bytes = 5,
            .stored_output_bytes = 5,
        },
        .{
            .tool_call_id = @constCast("call_orphaned"),
            .tool_name = @constCast("write_file"),
            .status = .failure,
            .output = @constCast("denied"),
            .output_bytes = 6,
            .stored_output_bytes = 6,
        },
    };
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("working"),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};

    var sources: runtime_tool_presentation.ReplayedSavedOutputSources = .{};
    defer sources.deinit(arena);
    const frames = try planExecutionReplay(
        arena,
        @import("../builtins/tools.zig").registry,
        null,
        null,
        .{ .alloc = arena, .workspace_root = "/workspace", .sources = &sources },
        .{ .tool_steps = steps[0..] },
    );
    try std.testing.expectEqual(@as(usize, 3), frames.len);
    try std.testing.expectEqualStrings("working", frames[0].assistant_text);
    try std.testing.expectEqualStrings("call_a", frames[1].tool_call.id);
    try std.testing.expectEqual(acp_types.ToolCallStatus.completed, frames[1].tool_call.status);
    try std.testing.expectEqual(acp_types.ToolCallKind.read, frames[1].tool_call.kind);
    try std.testing.expectEqualStrings("alpha", frames[1].tool_call.content_text.?);
    try std.testing.expectEqualStrings("call_orphaned", frames[2].tool_call.id);
    try std.testing.expectEqual(acp_types.ToolCallStatus.failed, frames[2].tool_call.status);
    try std.testing.expect(frames[2].tool_call.raw_input != null);
}

fn sendTestHistoryTurn(state: *server.ServerState, alloc: Allocator, session_id: []const u8, turn: types.HistoryTurn) !void {
    var sources: runtime_tool_presentation.ReplayedSavedOutputSources = .{};
    defer sources.deinit(alloc);
    return sendHistoryTurnAsUpdates(state, alloc, session_id, &sources, turn);
}

test "execution replay titles reads with the call whose saved output they read" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const replay = "fx-command-replay-0123.bin";
    var run_calls = [_]types.ToolCall{
        .{ .id = "run", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"zig build test\"}" },
    };
    var run_results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("run"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("{\"exit_code\":0}"),
        .output_bytes = 15,
        .stored_output_bytes = 15,
        .command_output_replay = .{ .available = .{ .handle = replay, .framed_bytes = 64 } },
    }};
    var read_calls = [_]types.ToolCall{
        .{ .id = "read", .name = "read_tool_result", .arguments_json = "{\"request\":{\"handle\":\"" ++ replay ++ "\",\"query\":\"error:\"}}" },
    };
    var read_results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("read"),
        .tool_name = @constCast("read_tool_result"),
        .status = .success,
        .output = @constCast("error: x"),
        .output_bytes = 8,
        .stored_output_bytes = 8,
    }};
    var steps = [_]types.ToolExecutionStep{
        .{ .tool_calls = run_calls[0..], .tool_results = run_results[0..] },
        .{ .tool_calls = read_calls[0..], .tool_results = read_results[0..] },
    };

    var sources: runtime_tool_presentation.ReplayedSavedOutputSources = .{};
    defer sources.deinit(alloc);
    const registry = @import("../builtins/tools.zig").registry;
    const replay_sources: ReplaySources = .{ .alloc = alloc, .workspace_root = "/workspace", .sources = &sources };
    const frames = try planExecutionReplay(arena, registry, null, null, replay_sources, .{ .tool_steps = steps[0..] });
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqualStrings("Searching zig build test output for \"error:\"", frames[1].tool_call.title);

    // A later turn replayed with the same sources still names the command.
    var later_calls = [_]types.ToolCall{
        .{ .id = "later", .name = "read_tool_result", .arguments_json = "{\"request\":{\"handle\":\"" ++ replay ++ "\"}}" },
    };
    var later_steps = [_]types.ToolExecutionStep{.{ .tool_calls = later_calls[0..] }};
    const later = try planExecutionReplay(arena, registry, null, null, replay_sources, .{ .tool_steps = later_steps[0..] });
    try std.testing.expectEqualStrings("Reading more output from zig build test", later[0].tool_call.title);
}

test "ACP load titles a read with the call from an earlier turn" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var capture = try tmp.dir.createFile(io_mod.getIo(), "history.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());
    var state = try initAcpSessionTestState(arena, workspace, capture);
    defer state.deinit();

    const replay = "fx-command-replay-0123.bin";
    var run_calls = [_]types.ToolCall{
        .{ .id = "run", .name = "shell", .arguments_json = "{\"action\":\"run\",\"command\":\"zig build test\"}" },
    };
    var run_results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("run"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = @constCast("{\"exit_code\":0}"),
        .output_bytes = 15,
        .stored_output_bytes = 15,
        .command_output_replay = .{ .available = .{ .handle = replay, .framed_bytes = 64 } },
    }};
    var run_steps = [_]types.ToolExecutionStep{.{ .tool_calls = run_calls[0..], .tool_results = run_results[0..] }};
    var read_calls = [_]types.ToolCall{
        .{ .id = "read", .name = "read_tool_result", .arguments_json = "{\"request\":{\"handle\":\"" ++ replay ++ "\",\"query\":\"error:\"}}" },
    };
    var read_steps = [_]types.ToolExecutionStep{.{ .tool_calls = read_calls[0..] }};

    var sources: runtime_tool_presentation.ReplayedSavedOutputSources = .{};
    defer sources.deinit(arena);
    try sendHistoryTurnAsUpdates(&state, arena, "session-1", &sources, .{ .assistant = .{
        .user = .{ .text = @constCast("run the tests") },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = run_steps[0..] },
    } });
    try sendHistoryTurnAsUpdates(&state, arena, "session-1", &sources, .{ .assistant = .{
        .user = .{ .text = @constCast("find the failure") },
        .assistant = @constCast("found it"),
        .execution = .{ .tool_steps = read_steps[0..] },
    } });

    const captured = try readCaptured(&capture, alloc);
    defer alloc.free(captured);
    try std.testing.expect(std.mem.find(u8, captured, "Searching zig build test output for \\\"error:\\\"") != null);
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
        "Subagent child sessions cannot be resumed directly",
    ) != null);
}

const AcpSessionTestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: []const u8) !*AcpSessionTestHome {
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
        io_mod.resetEnvironForTest();
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
        .provider_set = provider_set.gateway_only(test_builtin_gateway.provider_bundle),
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

test "ACP project MCP loading expands workspace environment templates" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "workspace/.mcp.json",
        .data =
        \\{"mcpServers":{"expanded":{"command":"${ACP_MCP_COMMAND}","args":["${ACP_MCP_ARG:-fallback}"],"env":{"TOKEN":"${ACP_MCP_TOKEN}"}}}}
        ,
    });
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
    try test_home.map.put("ACP_MCP_COMMAND", "node");
    try test_home.map.put("ACP_MCP_TOKEN", "secret-value");
    var approved_names = [_][]u8{@constCast("expanded")};

    var result = try workspace_config.load(
        alloc,
        workspace_path,
        .workspace,
        .{ .approved = &approved_names },
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    const config = result.configs.items[0];
    try std.testing.expectEqualStrings("node", config.command.?);
    try std.testing.expectEqualStrings("fallback", config.args[0]);
    try std.testing.expectEqualStrings("secret-value", config.env[0].value);
}

test "ACP ultrafast new load and resume preserve configured baselines" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_path);
    const workspace_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace_path);
    const env = try AcpSessionTestHome.install(alloc, home_path);
    defer env.deinit();
    var capture = try tmp.dir.createFile(io_mod.getIo(), "ultrafast.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());
    for ([_]bool{ false, true }) |baseline| {
        for ([_]?bool{ null, false, true }) |process| {
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var state = try initAcpSessionTestState(arena, workspace_path, capture);
            defer state.deinit();
            state.cfg.auth_mode = .host_managed;
            state.credential_source = .host_managed;
            state.cfg.minimal_kernel = true;
            state.cfg.allow_acp_mcp = false;
            state.cfg.home_override = home_path;
            state.configured_ultrafast_mode = baseline;
            state.process_ultrafast_override = process;
            state.ultrafast_mode = process orelse baseline;
            state.sessions_v2 = try session_adapter.Store.open(arena, home_path);
            var msg = jsonrpc.Message{
                .id = .{ .integer = 1 },
                .method = "session/new",
                .params_raw = "{\"mcpServers\":[]}",
            };
            try handleNewSession(&state, arena, &msg);
            const active = &state.active_session.?;
            try std.testing.expectEqual(process orelse baseline, active.ultrafast_mode);
            const v2 = active.v2.?;
            const preferences = try v2.currentPreferences(arena);
            try std.testing.expectEqual(baseline, preferences.ultrafast_mode);
            try v2.commitTurn(.{ .assistant = .{
                .user = .{ .text = @constCast("saved request") },
                .assistant = @constCast("saved answer"),
            } }, types.ConversationLanguage.default());
            const id = try arena.dupe(u8, active.session_id);
            inline for (.{ handleLoadSession, handleResumeSession }) |restore| {
                try server.releaseActiveSession(&state);
                msg.params_raw = try arena.print("{{\"sessionId\":\"{s}\",\"mcpServers\":[]}}", .{id});
                try restore(&state, arena, &msg);
                const resumed = &state.active_session.?;
                try std.testing.expectEqual(process orelse baseline, resumed.ultrafast_mode);
                const saved = (try resumed.v2.?.currentPreferences(arena)).ultrafast_mode;
                try std.testing.expectEqual(baseline, saved);
            }
        }
    }
}

test "ACP host-disabled new load and resume skip project MCP effects" {
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
    const marker_path = try std.Io.Dir.path.join(
        alloc,
        &.{ workspace_path, "project-mcp-launched" },
    );
    defer alloc.free(marker_path);
    const project_json = try alloc.print(
        "{{\"mcpServers\":{{\"fixture\":{{\"command\":\"/bin/sh\",\"args\":[\"-c\",\"printf launched > {s}\"]}},\"remote\":{{\"type\":\"http\",\"url\":\"http://127.0.0.1:1/mcp\",\"startup_timeout_ms\":5000}}}}}}",
        .{marker_path},
    );
    defer alloc.free(project_json);
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "workspace/.mcp.json",
        .data = project_json,
    });
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "home/.fx/settings.json",
        .data = "{}",
    });
    const test_home = try AcpSessionTestHome.install(alloc, home_path);
    defer test_home.deinit();

    var capture = try tmp.dir.createFile(
        io_mod.getIo(),
        "acp-host-disabled.jsonl",
        .{ .read = true },
    );
    defer capture.close(io_mod.getIo());
    var state = try initAcpSessionTestState(arena, workspace_path, capture);
    defer state.deinit();
    state.sessions_v2 = try session_adapter.Store.open(arena, home_path);
    state.cfg.allow_acp_mcp = false;

    var new_msg = jsonrpc.Message{
        .id = .{ .integer = 1 },
        .method = "session/new",
        .params_raw = "{\"mcpServers\":[]}",
    };
    try handleNewSession(&state, arena, &new_msg);
    try std.testing.expect(state.active_session.?.mcp_host == null);
    const session_id = try alloc.dupe(u8, state.active_session.?.session_id);
    defer alloc.free(session_id);

    inline for (.{
        .{ .method = "session/load", .handler = handleLoadSession },
        .{ .method = "session/resume", .handler = handleResumeSession },
    }, 0..) |restore, index| {
        const params = try arena.print(
            "{{\"sessionId\":\"{s}\",\"mcpServers\":[]}}",
            .{session_id},
        );
        var msg = jsonrpc.Message{
            .id = .{ .integer = @intCast(index + 2) },
            .method = restore.method,
            .params_raw = params,
        };
        try restore.handler(&state, arena, &msg);
        try std.testing.expect(state.active_session.?.mcp_host == null);
    }

    const local_request = try arena.print(
        "{{\"name\":\"request-local\",\"command\":\"/bin/sh\",\"args\":[\"-c\",\"printf launched > {s}\"],\"env\":[]}}",
        .{marker_path},
    );
    const remote_request =
        "{\"type\":\"http\",\"name\":\"request-remote\",\"url\":\"http://127.0.0.1:1/mcp\",\"headers\":[]}";
    inline for (.{
        .{ .method = "session/new", .handler = handleNewSession, .server = local_request },
        .{ .method = "session/load", .handler = handleLoadSession, .server = remote_request },
        .{ .method = "session/resume", .handler = handleResumeSession, .server = local_request },
    }, 0..) |request, index| {
        const params = if (std.mem.eql(u8, request.method, "session/new"))
            try arena.print(
                "{{\"mcpServers\":[{s}]}}",
                .{request.server},
            )
        else
            try arena.print(
                "{{\"sessionId\":\"{s}\",\"mcpServers\":[{s}]}}",
                .{ session_id, request.server },
            );
        var msg = jsonrpc.Message{
            .id = .{ .integer = @intCast(index + 10) },
            .method = request.method,
            .params_raw = params,
        };
        try request.handler(&state, arena, &msg);
        try std.testing.expect(state.active_session.?.mcp_host == null);
        try std.testing.expectEqualStrings(
            session_id,
            state.active_session.?.session_id,
        );
    }

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(io_mod.getIo(), "workspace/project-mcp-launched", .{}),
    );
    try capture.sync(io_mod.getIo());
    var captured_file = try tmp.dir.openFile(
        io_mod.getIo(),
        "acp-host-disabled.jsonl",
        .{},
    );
    defer captured_file.close(io_mod.getIo());
    // Each session response lists the model catalog, which grows with the
    // Gateway's, so the whole capture is read rather than a fixed slice.
    const captured = try io_mod.readFileToEnd(alloc, &captured_file, 1024 * 1024);
    defer alloc.free(captured);
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, captured, "MCP servers are unavailable in this runtime"),
    );
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
        state.sessions_v2 = try session_adapter.Store.open(arena, home_path);

        var new_msg = jsonrpc.Message{
            .id = .{ .integer = 1 },
            .method = "session/new",
            .params_raw = "{\"mcpServers\":[]}",
        };
        try handleNewSession(&state, arena, &new_msg);

        const new_active = &state.active_session.?;
        const new_v2 = new_active.v2.?;
        try std.testing.expectEqualStrings(
            test_session_mode_registry.default_mode_id,
            new_active.mode,
        );
        _ = server.applySessionMode(
            state.cfg.mode_registry,
            new_active,
            "review",
        );
        try std.testing.expectEqualStrings("review", new_active.mode);
        try std.testing.expect(state.subagent_host != null);

        try new_v2.commitTurn(.{ .assistant = .{
            .user = .{ .text = @constCast("remember this") },
            .assistant = @constCast("retained answer"),
        } }, .literal("en"));
        const session_id = try alloc.dupe(u8, new_active.session_id);
        defer alloc.free(session_id);
        try server.releaseActiveSession(&state);
        try std.testing.expect(state.active_session == null);
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
        try std.testing.expect(loaded_active.v2 != null);
        try std.testing.expectEqual(@as(usize, 1), loaded_active.session_rt.historyLen());
        try std.testing.expectEqualStrings(
            test_session_mode_registry.default_mode_id,
            loaded_active.mode,
        );
        try std.testing.expect(state.subagent_host != null);

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

test "libfx/new uses a valid host session id and generates one when none is named" {
    const alloc = std.testing.allocator;
    const id = (try requestedLibfxSessionId(alloc, "{\"sessionId\":\"wrun_01M3X0485FF9GX5ZA6FWMGR503\"}")).?;
    defer alloc.free(id);
    try std.testing.expectEqualStrings("wrun_01M3X0485FF9GX5ZA6FWMGR503", id);
    try std.testing.expect((try requestedLibfxSessionId(alloc, null)) == null);
    try std.testing.expect((try requestedLibfxSessionId(alloc, "{}")) == null);
    try std.testing.expect((try requestedLibfxSessionId(alloc, "{\"sessionId\":null}")) == null);
}

test "libfx/new rejects a session id that is not header and path safe" {
    const alloc = std.testing.allocator;
    const bad = [_][]const u8{
        "{\"sessionId\":\"\"}",
        "{\"sessionId\":\"..\"}",
        "{\"sessionId\":\"a/b\"}",
        "{\"sessionId\":\"a b\"}",
        "{\"sessionId\":\"a\\r\\nx-injected: 1\"}",
        "{\"sessionId\":42}",
        "[]",
        "{",
    };
    for (bad) |params| {
        try std.testing.expectError(error.InvalidSessionId, requestedLibfxSessionId(alloc, params));
    }
    const long = "{\"sessionId\":\"" ++ text_utils.repeat("a", 256) ++ "\"}";
    try std.testing.expectError(error.InvalidSessionId, requestedLibfxSessionId(alloc, long));
}
