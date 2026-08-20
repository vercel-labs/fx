const std = @import("std");
const build_options = @import("build_options");
const acp_server = @import("acp/server.zig");
const jsonrpc = @import("acp/jsonrpc.zig");
const agent_stream_provider = @import("core/agent/stream_provider.zig");
const background_process_provider = @import("core/execution/background_process_provider.zig");
const adapter_auth = @import("core/gateway/adapter_auth.zig");
const connection_registry = @import("core/gateway/connection_registry.zig");
const gateway_provider = @import("core/gateway/gateway_provider.zig");
const generation_usage_provider = @import("core/session/generation_usage_provider.zig");
const host = @import("core/hosts/host.zig");
const debug_trace = @import("core/shared/debug_trace.zig");
const io_mod = @import("core/shared/io.zig");
const fetch_state = @import("napi_fetch_state.zig");
const streamable_http = @import("core/mcp/streamable_http.zig");
const host_stream_provider = @import("gateway/host_stream_provider.zig");
const oauth_transport = @import("gateway/auth/oauth_transport.zig");
const builtin_context = @import("builtins/context.zig");
const builtin_gateway = @import("builtins/gateway.zig");
const builtin_modes = @import("builtins/modes.zig");

const c = @cImport({
    @cInclude("node_api.h");
});

const Allocator = std.mem.Allocator;
const max_drain_bytes = 1024 * 1024;
const max_input_bytes = 8 * 1024 * 1024;
const max_output_bytes = 8 * 1024 * 1024;
const max_fetch_request_bytes = 8 * 1024 * 1024;
const max_fetch_response_bytes = 8 * 1024 * 1024;
const max_api_key_bytes = 64 * 1024;
const max_model_bytes = 1024;
const max_path_bytes = 16 * 1024;
const max_url_bytes = 16 * 1024;
const max_active_runtimes = 64;
const runtime_handle_type_tag = c.napi_type_tag{
    .lower = 0x4c4942465852544d,
    .upper = 0xa71d7c52e9314b08,
};

comptime {
    if (build_options.napi_surface != .core) {
        @compileError("libfx N-API core requires -Dnapi-surface=core");
    }
}

const InputQueue = struct {
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    closed: bool = false,

    fn read(self: *InputQueue, alloc: Allocator, destination: []u8) usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.offset == self.bytes.items.len and !self.closed) {
            self.bytes.clearRetainingCapacity();
            self.offset = 0;
            self.wake.waitUncancelable(io, &self.mutex);
        }
        const available = self.bytes.items.len - self.offset;
        if (available == 0) return 0;
        const len = @min(destination.len, available);
        @memcpy(destination[0..len], self.bytes.items[self.offset..][0..len]);
        self.offset += len;
        if (self.offset == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.offset = 0;
        }
        _ = alloc;
        return len;
    }

    fn write(self: *InputQueue, alloc: Allocator, data: []const u8) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return error.InputClosed;
        const queued = self.bytes.items.len - self.offset;
        if (data.len > max_input_bytes or queued > max_input_bytes - data.len) return error.InputQueueFull;
        if (self.offset > 0) {
            std.mem.copyForwards(u8, self.bytes.items[0..queued], self.bytes.items[self.offset..]);
            self.bytes.items.len = queued;
            self.offset = 0;
        }
        try self.bytes.appendSlice(alloc, data);
        self.wake.signal(io);
    }

    fn close(self: *InputQueue) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.wake.broadcast(io);
        self.mutex.unlock(io);
    }

    fn deinit(self: *InputQueue, alloc: Allocator) void {
        self.bytes.deinit(alloc);
    }
};

const OutputQueue = struct {
    mutex: std.Io.Mutex = .init,
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,

    fn write(self: *OutputQueue, alloc: Allocator, data: []const u8) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const queued = self.bytes.items.len - self.offset;
        if (data.len > max_output_bytes or queued > max_output_bytes - data.len) return error.OutputQueueFull;
        if (self.offset > 0) {
            std.mem.copyForwards(u8, self.bytes.items[0..queued], self.bytes.items[self.offset..]);
            self.bytes.items.len = queued;
            self.offset = 0;
        }
        try self.bytes.appendSlice(alloc, data);
    }

    fn drain(self: *OutputQueue, destination: []u8) usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const available_bytes = self.bytes.items.len - self.offset;
        const len = @min(destination.len, available_bytes);
        if (len == 0) return 0;
        @memcpy(destination[0..len], self.bytes.items[self.offset..][0..len]);
        self.offset += len;
        if (self.offset == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.offset = 0;
        }
        return len;
    }

    fn available(self: *OutputQueue) usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.bytes.items.len - self.offset;
    }

    fn deinit(self: *OutputQueue, alloc: Allocator) void {
        self.bytes.deinit(alloc);
    }
};

const FetchBridge = struct {
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    request: std.ArrayList(u8) = .empty,
    response: std.ArrayList(u8) = .empty,
    response_offset: usize = 0,
    phase: fetch_state.Phase = .idle,
    next_handle: fetch_state.Handle = 1,
    status: u16 = 0,

    fn clearPendingRequest(self: *FetchBridge, reason: []const u8) void {
        if (self.request.items.len == 0) return;
        debug_trace.logf("napi", "dropping pending host fetch reason={s} bytes={d}", .{ reason, self.request.items.len });
        self.request.clearRetainingCapacity();
    }

    fn trace_stale(operation: []const u8, handle: fetch_state.Handle, reason: fetch_state.StaleReason) void {
        debug_trace.logf(
            "napi",
            "dropping stale host fetch operation={s} handle={d} reason={s}",
            .{ operation, handle, @tagName(reason) },
        );
    }

    fn advance_handle(self: *FetchBridge) void {
        self.next_handle = if (self.next_handle == std.math.maxInt(fetch_state.Handle))
            0
        else
            self.next_handle + 1;
    }

    fn open(raw: ?*anyopaque, method: []const u8, url: []const u8, headers: []const u8, body: []const u8) !i32 {
        const self: *FetchBridge = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.next_handle == 0) return error.HostStreamUnavailable;
        const handle = self.next_handle;
        const decision = fetch_state.decide(self.phase, .{ .open = handle });
        switch (decision.action) {
            .cancelled => {
                self.phase = decision.phase;
                return error.Cancelled;
            },
            .unavailable, .shutting_down => return error.HostStreamUnavailable,
            .applied => {},
            else => unreachable,
        }
        self.response_offset = 0;
        self.response.clearRetainingCapacity();
        var writer: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer writer.deinit();
        const encoded_body = std.base64.standard.Encoder.calcSize(body.len);
        const body_base64 = try std.heap.c_allocator.alloc(u8, encoded_body);
        defer std.heap.c_allocator.free(body_base64);
        _ = std.base64.standard.Encoder.encode(body_base64, body);
        try std.json.Stringify.value(.{
            .handle = handle,
            .method = method,
            .url = url,
            .headers = headers,
            .body = body_base64,
        }, .{}, &writer.writer);
        const bytes = writer.writer.buffered();
        if (bytes.len > max_fetch_request_bytes) return error.HostStreamBackpressure;
        self.request.clearRetainingCapacity();
        try self.request.appendSlice(std.heap.c_allocator, bytes);
        self.phase = decision.phase;
        self.advance_handle();
        self.wake.broadcast(io);
        return handle;
    }

    fn statusFn(raw: ?*anyopaque, handle: i32, status_out: *u16) i32 {
        const self: *FetchBridge = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) switch (self.phase) {
            .request_pending, .awaiting_response => |active| {
                if (active != handle) return -2;
                self.wake.waitUncancelable(io, &self.mutex);
            },
            .streaming => |active| {
                if (active != handle) return -2;
                status_out.* = self.status;
                return 1;
            },
            .terminal => |terminal| {
                if (terminal.handle != handle) return -2;
                return switch (terminal.kind) {
                    .success => result: {
                        status_out.* = self.status;
                        break :result 1;
                    },
                    .failure => -1,
                    .aborted => -2,
                };
            },
            else => return -2,
        };
    }

    fn next(raw: ?*anyopaque, handle: i32, out: []u8) i32 {
        const self: *FetchBridge = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            const terminal_kind: ?fetch_state.TerminalKind = switch (self.phase) {
                .streaming => |active| if (active == handle) null else return -2,
                .terminal => |terminal| if (terminal.handle == handle) terminal.kind else return -2,
                else => return -2,
            };
            if (terminal_kind) |kind| switch (kind) {
                .failure => return -1,
                .aborted => return -2,
                .success => {},
            };
            const available = self.response.items.len - self.response_offset;
            if (available > 0) {
                const len = @min(out.len, available);
                @memcpy(out[0..len], self.response.items[self.response_offset..][0..len]);
                self.response_offset += len;
                self.wake.broadcast(io);
                return @intCast(len);
            }
            self.response.clearRetainingCapacity();
            self.response_offset = 0;
            if (terminal_kind != null) return 0;
            self.wake.waitUncancelable(io, &self.mutex);
        }
    }

    fn close(raw: ?*anyopaque, handle: i32) void {
        const self: *FetchBridge = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .close = handle });
        if (decision.action == .stale) {
            trace_stale("close", handle, decision.stale_reason.?);
            return;
        }
        self.clearPendingRequest("stream_close");
        self.phase = decision.phase;
        self.status = 0;
        self.response.clearRetainingCapacity();
        self.response_offset = 0;
        self.wake.broadcast(io);
    }

    fn startResponse(self: *FetchBridge, handle: fetch_state.Handle, status: u16) FetchOperationResult {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .start = handle });
        if (decision.action == .stale) {
            trace_stale("start", handle, decision.stale_reason.?);
            return .stale;
        }
        self.status = status;
        self.phase = decision.phase;
        self.wake.broadcast(io);
        return .applied;
    }

    fn pushResponse(self: *FetchBridge, handle: fetch_state.Handle, data: []const u8) !FetchOperationResult {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .push = handle });
        if (decision.action == .stale) {
            trace_stale("push", handle, decision.stale_reason.?);
            return .stale;
        }
        const queued = self.response.items.len - self.response_offset;
        if (data.len > max_fetch_response_bytes or queued > max_fetch_response_bytes - data.len) return .backpressure;
        if (self.response_offset > 0) {
            std.mem.copyForwards(u8, self.response.items[0..queued], self.response.items[self.response_offset..]);
            self.response.items.len = queued;
            self.response_offset = 0;
        }
        try self.response.appendSlice(std.heap.c_allocator, data);
        self.wake.broadcast(io);
        return .applied;
    }

    fn finishResponse(self: *FetchBridge, handle: fetch_state.Handle) FetchOperationResult {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .finish = handle });
        if (decision.action == .stale) {
            trace_stale("finish", handle, decision.stale_reason.?);
            return .stale;
        }
        self.phase = decision.phase;
        self.wake.broadcast(io);
        return .applied;
    }

    fn failResponse(self: *FetchBridge, handle: fetch_state.Handle) FetchOperationResult {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .{ .fail = handle });
        if (decision.action == .stale) {
            trace_stale("fail", handle, decision.stale_reason.?);
            return .stale;
        }
        self.phase = decision.phase;
        self.wake.broadcast(io);
        return .applied;
    }

    fn is_active(self: *FetchBridge, handle: fetch_state.Handle) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return fetch_state.is_active(self.phase, handle);
    }

    fn abort(self: *FetchBridge) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .cancel);
        self.clearPendingRequest("abort");
        self.phase = decision.phase;
        self.wake.broadcast(io);
    }

    fn shutdown(self: *FetchBridge) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const decision = fetch_state.decide(self.phase, .shutdown);
        self.clearPendingRequest("shutdown");
        self.phase = decision.phase;
        self.wake.broadcast(io);
    }

    fn deinit(self: *FetchBridge) void {
        self.request.deinit(std.heap.c_allocator);
        self.response.deinit(std.heap.c_allocator);
    }
};

const FetchOperationResult = enum(u8) {
    stale = 0,
    applied = 1,
    backpressure = 2,
};

const Runtime = struct {
    alloc: Allocator,
    fetch: FetchBridge = .{},
    stream_context: host_stream_provider.ProviderContext = undefined,
    input: InputQueue = .{},
    output: OutputQueue = .{},
    credential: []u8,
    model: ?[]u8,
    home: []u8,
    workspace_root: []u8,
    gateway_chat_url: []u8,
    thread: std.Thread,
    exited: std.atomic.Value(bool) = .init(false),
    exit_code: std.atomic.Value(u8) = .init(0),

    fn readInput(context: ?*anyopaque, destination: []u8) usize {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        return self.input.read(self.alloc, destination);
    }

    fn writeOutput(context: ?*anyopaque, bytes: []const u8) !void {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        self.output.write(self.alloc, bytes) catch |err| {
            debug_trace.logf("napi", "native output failed err={s}", .{@errorName(err)});
            self.exit_code.store(1, .seq_cst);
            return err;
        };
    }

    fn run(self: *Runtime) void {
        const agent_stream = host_stream_provider.provider(&self.stream_context);
        var provider_adapter = builtin_gateway.provider_adapter;
        provider_adapter.auth = self.authProvider();
        provider_adapter.legacy_provider = agent_stream;
        provider_adapter.generation_usage = generation_usage_provider.unavailable_provider;
        const adapters = [_]agent_stream_provider.ProviderAdapter{provider_adapter};
        const provider = gateway_provider.Provider{
            .connection_seed = builtin_gateway.connection_seed,
            .agent_stream = agent_stream,
            .provider_adapter = provider_adapter,
            .adapter_registry = .{ .adapters = &adapters },
            .oauth_transport = oauth_transport.unavailable_provider,
            .chat_url = builtin_gateway.provider.chat_url,
        };
        acp_server.runWithTransport(
            self.alloc,
            .{
                .default_model = builtin_gateway.default_model,
                .default_agent_step_limit = 64,
                .gateway_retry_count = 0,
                .gateway_chat_url = self.gateway_chat_url,
                .gateway_models_path = builtin_gateway.models_path,
                .gateway_provider = provider,
                .background_process_provider = background_process_provider.unavailable_provider,
                .secret_store = host.unavailable_secret_store,
                .prompt_policy = builtin_context.prompt_policy,
                .ignored_list_entries = &.{},
                .max_list_entries = 0,
                .max_read_file_bytes = 0,
                .max_read_file_lines = 0,
                .max_read_file_line_len = 0,
                .max_command_output_bytes = 0,
                .max_tool_result_bytes = 64 * 1024,
                .max_history_turns = 100,
                .context_registry = .{ .default_provider = builtin_context.provider },
                .mode_registry = builtin_modes.registry,
                .credential_override = self.credential,
                .model_override = self.model,
                .home_override = self.home,
                .workspace_root_override = self.workspace_root,
                .allow_acp_mcp = false,
                .allow_native_tools = false,
            },
            jsonrpc.Reader.initCallback(self, Runtime.readInput),
            jsonrpc.Writer.initCallback(self, Runtime.writeOutput),
        ) catch |err| {
            debug_trace.logf("napi", "native runtime failed err={s}", .{@errorName(err)});
            self.exit_code.store(1, .seq_cst);
        };
        self.exited.store(true, .seq_cst);
    }

    fn authProvider(self: *Runtime) adapter_auth.Provider {
        return .{
            .kind = builtin_gateway.connection_seed.adapter_id,
            .auth_service_label = "Vercel",
            .context = self,
            .acquire_fn = acquireCredential,
            .status_fn = credentialStatus,
        };
    }

    fn acquireCredential(
        raw: *const anyopaque,
        alloc: Allocator,
        request: adapter_auth.Request,
    ) Allocator.Error!adapter_auth.Acquisition {
        const self: *const Runtime = @ptrCast(@alignCast(raw));
        if (self.credential.len == 0) return .{ .missing = .not_found };
        const source = builtin_gateway.credentialOverrideSource(request.profile.credential_ref) catch
            return .{ .failed = .{ .category = .configuration } };
        const credential = try alloc.dupe(u8, self.credential);
        return .{ .acquired = .{
            .secret_bytes = credential,
            .source = source,
            .catalog_access = .{ .authenticated = .{
                .source = source,
                .credential = credential,
                .team_context = null,
            } },
        } };
    }

    fn credentialStatus(
        raw: *const anyopaque,
        _: Allocator,
        profile: connection_registry.Profile,
        _: adapter_auth.AuthHost,
    ) Allocator.Error!adapter_auth.StatusOutcome {
        const self: *const Runtime = @ptrCast(@alignCast(raw));
        return .{ .loaded = .{
            .source = if (self.credential.len > 0)
                builtin_gateway.credentialOverrideSource(profile.credential_ref) catch null
            else
                null,
            .store_status = if (self.credential.len > 0) .not_attempted else .not_found,
        } };
    }

    fn closeInput(self: *Runtime) void {
        self.input.close();
    }

    fn abortHostEffects(self: *Runtime) void {
        self.fetch.abort();
    }

    fn deinit(self: *Runtime) void {
        self.closeInput();
        self.fetch.shutdown();
        self.thread.join();
        self.fetch.deinit();
        self.input.deinit(self.alloc);
        self.output.deinit(self.alloc);
        self.alloc.free(self.credential);
        if (self.model) |model| self.alloc.free(model);
        self.alloc.free(self.home);
        self.alloc.free(self.workspace_root);
        self.alloc.free(self.gateway_chat_url);
        self.alloc.destroy(self);
        releaseRuntimeSlot();
    }
};

const RuntimeHandle = struct {
    mutex: std.Io.Mutex = .init,
    runtime: ?*Runtime,

    fn destroy(self: *RuntimeHandle) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const runtime = self.runtime;
        self.runtime = null;
        self.mutex.unlock(io);
        if (runtime) |value| value.deinit();
    }
};

var threaded_io: ?std.Io.Threaded = null;
var threaded_io_state: std.atomic.Value(u8) = .init(0);
var active_runtime_count: std.atomic.Value(usize) = .init(0);

fn claimRuntimeSlot() bool {
    var current = active_runtime_count.load(.acquire);
    while (current < max_active_runtimes) {
        if (active_runtime_count.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
            current = observed;
        } else return true;
    }
    return false;
}

fn releaseRuntimeSlot() void {
    _ = active_runtime_count.fetchSub(1, .acq_rel);
}

fn ensureThreadedIo() void {
    if (threaded_io_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        threaded_io = std.Io.Threaded.init(std.heap.c_allocator, .{});
        io_mod.setIo(threaded_io.?.io());
        const raw_environ: io_mod.RawEnviron = @ptrCast(std.c.environ);
        io_mod.setRawEnviron(raw_environ);
        const workspace_root = io_mod.realpathAlloc(std.heap.c_allocator, ".") catch null;
        defer if (workspace_root) |path| std.heap.c_allocator.free(path);
        debug_trace.configureFromEnv(std.heap.c_allocator, workspace_root orelse ".");
        threaded_io_state.store(2, .release);
        return;
    }
    while (threaded_io_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

fn throw(env: c.napi_env, code: [*:0]const u8, message: [*:0]const u8) c.napi_value {
    _ = c.napi_throw_error(env, code, message);
    return null;
}

fn statusOk(env: c.napi_env, status: c.napi_status, message: [*:0]const u8) bool {
    if (status == c.napi_ok) return true;
    _ = c.napi_throw_error(env, "LIBFX_NAPI", message);
    return false;
}

fn callbackArgs(env: c.napi_env, info: c.napi_callback_info, argv: []c.napi_value) bool {
    var argc = argv.len;
    if (!statusOk(env, c.napi_get_cb_info(env, info, &argc, argv.ptr, null, null), "could not read arguments")) return false;
    if (argc == argv.len) return true;
    _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "missing required argument");
    return false;
}

fn stringArg(env: c.napi_env, value: c.napi_value, alloc: Allocator, max_len: usize) ![]u8 {
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, null, 0, &len) != c.napi_ok) return error.InvalidArgument;
    if (len > max_len) return error.ArgumentTooLong;
    const bytes = try alloc.alloc(u8, len + 1);
    errdefer alloc.free(bytes);
    var written: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, bytes.ptr, bytes.len, &written) != c.napi_ok) return error.InvalidArgument;
    return bytes[0..written];
}

fn getNamedString(
    env: c.napi_env,
    object: c.napi_value,
    name: [*:0]const u8,
    alloc: Allocator,
    max_len: usize,
) !?[]u8 {
    var present = false;
    if (c.napi_has_named_property(env, object, name, &present) != c.napi_ok or !present) return null;
    var value: c.napi_value = undefined;
    if (c.napi_get_named_property(env, object, name, &value) != c.napi_ok) return error.InvalidArgument;
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok or value_type != c.napi_string) return error.InvalidArgument;
    return try stringArg(env, value, alloc, max_len);
}

const CreateError = error{
    TooManyRuntimes,
    InvalidApiKey,
    InvalidModel,
    InvalidHome,
    InvalidWorkspaceRoot,
    InvalidGatewayUrl,
    OutOfMemory,
    ThreadFailed,
};

fn createRuntime(env: c.napi_env, options: c.napi_value) CreateError!*Runtime {
    if (!claimRuntimeSlot()) return error.TooManyRuntimes;
    errdefer releaseRuntimeSlot();
    const alloc = std.heap.c_allocator;
    const credential = getNamedString(env, options, "apiKey", alloc, max_api_key_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidApiKey,
    };
    const api_key = credential orelse return error.InvalidApiKey;
    errdefer alloc.free(api_key);
    const model = getNamedString(env, options, "model", alloc, max_model_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModel,
    };
    errdefer if (model) |value| alloc.free(value);
    const home = (getNamedString(env, options, "home", alloc, max_path_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidHome,
    }) orelse return error.InvalidHome;
    errdefer alloc.free(home);
    const workspace_root = (getNamedString(env, options, "workspaceRoot", alloc, max_path_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidWorkspaceRoot,
    }) orelse return error.InvalidWorkspaceRoot;
    errdefer alloc.free(workspace_root);
    const gateway_chat_url = (getNamedString(env, options, "gatewayChatUrl", alloc, max_url_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGatewayUrl,
    }) orelse (alloc.dupe(u8, builtin_gateway.default_chat_url) catch return error.OutOfMemory);
    errdefer alloc.free(gateway_chat_url);
    streamable_http.validateEndpoint(gateway_chat_url) catch return error.InvalidGatewayUrl;
    if (!std.mem.eql(u8, gateway_chat_url, builtin_gateway.default_chat_url)) {
        const uri = std.Uri.parse(gateway_chat_url) catch return error.InvalidGatewayUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidGatewayUrl;
    }

    const runtime = alloc.create(Runtime) catch return error.OutOfMemory;
    errdefer alloc.destroy(runtime);
    runtime.* = .{
        .alloc = alloc,
        .credential = api_key,
        .model = model,
        .home = home,
        .workspace_root = workspace_root,
        .gateway_chat_url = gateway_chat_url,
        .thread = undefined,
    };
    runtime.stream_context = host_stream_provider.initContext(builtin_gateway.buildAgentRequest, .{
        .context = &runtime.fetch,
        .open_fn = FetchBridge.open,
        .status_fn = FetchBridge.statusFn,
        .next_fn = FetchBridge.next,
        .close_fn = FetchBridge.close,
    });
    runtime.thread = std.Thread.spawn(.{}, Runtime.run, .{runtime}) catch return error.ThreadFailed;
    return runtime;
}

fn throwCreateError(env: c.napi_env, err: CreateError) c.napi_value {
    return switch (err) {
        error.TooManyRuntimes => throw(env, "LIBFX_NATIVE_LIMIT", "too many active native runtimes"),
        error.InvalidApiKey => throw(env, "LIBFX_INVALID_ARGUMENT", "apiKey is required and must be a bounded string"),
        error.InvalidModel => throw(env, "LIBFX_INVALID_ARGUMENT", "model must be a bounded string"),
        error.InvalidHome => throw(env, "LIBFX_INVALID_ARGUMENT", "home is required and must be a bounded string"),
        error.InvalidWorkspaceRoot => throw(env, "LIBFX_INVALID_ARGUMENT", "workspaceRoot is required and must be a bounded string"),
        error.InvalidGatewayUrl => throw(env, "LIBFX_INVALID_ARGUMENT", "gatewayChatUrl must be a bounded string"),
        error.OutOfMemory => throw(env, "LIBFX_NATIVE_OOM", "could not allocate native runtime"),
        error.ThreadFailed => throw(env, "LIBFX_NATIVE_THREAD", "could not start native runtime thread"),
    };
}

fn finalizeRuntimeHandle(_: c.napi_env, data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const handle: *RuntimeHandle = @ptrCast(@alignCast(data orelse return));
    handle.destroy();
    std.heap.c_allocator.destroy(handle);
}

fn createCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    if (!callbackArgs(env, info, &argv)) return null;

    const runtime = createRuntime(env, argv[0]) catch |err| return throwCreateError(env, err);
    var runtime_owned = true;
    defer if (runtime_owned) runtime.deinit();
    const handle = std.heap.c_allocator.create(RuntimeHandle) catch
        return throw(env, "LIBFX_NATIVE_OOM", "could not allocate runtime handle");
    var handle_owned = true;
    defer if (handle_owned) std.heap.c_allocator.destroy(handle);
    handle.* = .{ .runtime = runtime };

    var result: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_object(env, &result), "could not create runtime handle")) return null;
    if (!statusOk(
        env,
        c.napi_type_tag_object(env, result, &runtime_handle_type_tag),
        "could not brand runtime handle",
    )) return null;
    if (!statusOk(
        env,
        c.napi_wrap(env, result, handle, finalizeRuntimeHandle, null, null),
        "could not attach native runtime",
    )) return null;
    runtime_owned = false;
    handle_owned = false;
    return result;
}

fn runtimeHandleArg(env: c.napi_env, info: c.napi_callback_info, argv: []c.napi_value) ?*RuntimeHandle {
    if (!callbackArgs(env, info, argv)) return null;
    var branded = false;
    if (!statusOk(
        env,
        c.napi_check_object_type_tag(env, argv[0], &runtime_handle_type_tag, &branded),
        "could not validate runtime handle",
    )) return null;
    if (!branded) {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "invalid runtime handle");
        return null;
    }
    var context: ?*anyopaque = null;
    if (!statusOk(env, c.napi_unwrap(env, argv[0], &context), "invalid runtime handle")) return null;
    return @ptrCast(@alignCast(context orelse return null));
}

fn lockRuntime(env: c.napi_env, handle: *RuntimeHandle) ?*Runtime {
    handle.mutex.lockUncancelable(io_mod.getIo());
    const runtime = handle.runtime orelse {
        handle.mutex.unlock(io_mod.getIo());
        _ = c.napi_throw_error(env, "LIBFX_NATIVE_CLOSED", "native runtime is closed");
        return null;
    };
    return runtime;
}

fn unlockRuntime(handle: *RuntimeHandle) void {
    handle.mutex.unlock(io_mod.getIo());
}

fn fetch_handle_arg(env: c.napi_env, value: c.napi_value) ?fetch_state.Handle {
    var number: f64 = 0;
    if (c.napi_get_value_double(env, value, &number) != c.napi_ok or
        !std.math.isFinite(number) or
        number < 1 or
        number > @as(f64, @floatFromInt(std.math.maxInt(fetch_state.Handle))) or
        @floor(number) != number)
    {
        _ = c.napi_throw_type_error(env, "LIBFX_INVALID_ARGUMENT", "fetch handle must be a positive int32");
        return null;
    }
    return @intFromFloat(number);
}

fn fetch_operation_value(env: c.napi_env, result: FetchOperationResult) c.napi_value {
    var value: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_uint32(env, @intFromEnum(result), &value), "could not create fetch operation result")) return null;
    return value;
}

fn writeCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var data: ?*anyopaque = null;
    var len: usize = 0;
    if (!statusOk(env, c.napi_get_buffer_info(env, argv[1], &data, &len), "write() requires a Buffer")) return null;
    const bytes = if (len == 0) &.{} else @as([*]const u8, @ptrCast(data orelse return throw(env, "LIBFX_NATIVE_IO", "Buffer data is unavailable")))[0..len];
    runtime.input.write(runtime.alloc, bytes) catch |err| return switch (err) {
        error.InputClosed => throw(env, "LIBFX_NATIVE_CLOSED", "native runtime input is closed"),
        error.InputQueueFull => throw(env, "LIBFX_NATIVE_BACKPRESSURE", "native runtime input queue is full"),
        error.OutOfMemory => throw(env, "LIBFX_NATIVE_OOM", "could not queue native input"),
    };
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn closeCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    runtime.closeInput();
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn drainCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const len = @min(runtime.output.available(), max_drain_bytes);
    var value: c.napi_value = undefined;
    var data: ?*anyopaque = null;
    if (!statusOk(env, c.napi_create_buffer(env, len, &data, &value), "could not allocate output Buffer")) return null;
    if (len == 0) return value;
    const written = runtime.output.drain(@as([*]u8, @ptrCast(data.?))[0..len]);
    if (written != len) return throw(env, "LIBFX_NATIVE_IO", "native output changed while draining");
    return value;
}

fn takeCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    const io = io_mod.getIo();
    runtime.fetch.mutex.lockUncancelable(io);
    defer runtime.fetch.mutex.unlock(io);
    const decision = fetch_state.decide(runtime.fetch.phase, .take_request);
    if (decision.action != .applied) {
        var value: c.napi_value = undefined;
        _ = c.napi_get_null(env, &value);
        return value;
    }
    const len = runtime.fetch.request.items.len;
    var value: c.napi_value = undefined;
    var data: ?*anyopaque = null;
    if (!statusOk(env, c.napi_create_buffer(env, len, &data, &value), "could not allocate fetch request Buffer")) return null;
    if (len > 0) @memcpy(@as([*]u8, @ptrCast(data.?))[0..len], runtime.fetch.request.items);
    runtime.fetch.request.clearRetainingCapacity();
    runtime.fetch.phase = decision.phase;
    return value;
}

fn coreFetchActive(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    var value: c.napi_value = undefined;
    _ = c.napi_get_boolean(env, runtime.fetch.is_active(fetch_handle), &value);
    return value;
}

fn startCoreFetchResponse(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [3]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    var status: u32 = 0;
    if (c.napi_get_value_uint32(env, argv[2], &status) != c.napi_ok or status > std.math.maxInt(u16))
        return throw(env, "LIBFX_INVALID_ARGUMENT", "fetch response status must be a uint16");
    return fetch_operation_value(env, runtime.fetch.startResponse(fetch_handle, @intCast(status)));
}

fn pushCoreFetchResponse(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [3]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    var data: ?*anyopaque = null;
    var len: usize = 0;
    if (!statusOk(env, c.napi_get_buffer_info(env, argv[2], &data, &len), "fetch response chunk requires a Buffer")) return null;
    const bytes = if (len == 0) &.{} else @as([*]const u8, @ptrCast(data.?))[0..len];
    const result = runtime.fetch.pushResponse(fetch_handle, bytes) catch
        return throw(env, "LIBFX_NATIVE_OOM", "could not queue fetch response");
    return fetch_operation_value(env, result);
}

fn finishCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    return fetch_operation_value(env, runtime.fetch.finishResponse(fetch_handle));
}

fn failCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [2]c.napi_value = undefined;
    const runtime_handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const fetch_handle = fetch_handle_arg(env, argv[1]) orelse return null;
    const runtime = lockRuntime(env, runtime_handle) orelse return null;
    defer unlockRuntime(runtime_handle);
    return fetch_operation_value(env, runtime.fetch.failResponse(fetch_handle));
}

fn abortCoreFetch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    runtime.abortHostEffects();
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn coreExited(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var value: c.napi_value = undefined;
    _ = c.napi_get_boolean(env, runtime.exited.load(.seq_cst), &value);
    return value;
}

fn coreExitCode(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    const runtime = lockRuntime(env, handle) orelse return null;
    defer unlockRuntime(handle);
    var value: c.napi_value = undefined;
    _ = c.napi_create_uint32(env, runtime.exit_code.load(.seq_cst), &value);
    return value;
}

fn destroyCore(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    const handle = runtimeHandleArg(env, info, &argv) orelse return null;
    handle.destroy();
    var value: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &value);
    return value;
}

fn exportFunction(env: c.napi_env, exports: c.napi_value, name: [*:0]const u8, callback: c.napi_callback) bool {
    var function: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_function(env, name, c.NAPI_AUTO_LENGTH, callback, null, &function), "could not create addon function")) return false;
    return statusOk(env, c.napi_set_named_property(env, exports, name, function), "could not export addon function");
}

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) callconv(.c) c.napi_value {
    ensureThreadedIo();
    var api_version: c.napi_value = undefined;
    if (!statusOk(env, c.napi_create_uint32(env, 2, &api_version), "could not create API version")) return null;
    if (!statusOk(env, c.napi_set_named_property(env, exports, "libfxApiVersion", api_version), "could not export API version")) return null;
    if (!exportFunction(env, exports, "createCore", createCore)) return null;
    if (!exportFunction(env, exports, "writeCore", writeCore)) return null;
    if (!exportFunction(env, exports, "closeCore", closeCore)) return null;
    if (!exportFunction(env, exports, "drainCore", drainCore)) return null;
    if (!exportFunction(env, exports, "takeCoreFetch", takeCoreFetch)) return null;
    if (!exportFunction(env, exports, "coreFetchActive", coreFetchActive)) return null;
    if (!exportFunction(env, exports, "startCoreFetchResponse", startCoreFetchResponse)) return null;
    if (!exportFunction(env, exports, "pushCoreFetchResponse", pushCoreFetchResponse)) return null;
    if (!exportFunction(env, exports, "finishCoreFetch", finishCoreFetch)) return null;
    if (!exportFunction(env, exports, "failCoreFetch", failCoreFetch)) return null;
    if (!exportFunction(env, exports, "abortCoreFetch", abortCoreFetch)) return null;
    if (!exportFunction(env, exports, "coreExited", coreExited)) return null;
    if (!exportFunction(env, exports, "coreExitCode", coreExitCode)) return null;
    if (!exportFunction(env, exports, "destroyCore", destroyCore)) return null;
    return exports;
}
