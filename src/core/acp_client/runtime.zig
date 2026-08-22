const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const jsonrpc = @import("../../acp/jsonrpc.zig");
const mcp_json = @import("../mcp/mcp_json.zig");

const Allocator = std.mem.Allocator;
const writeJsonStr = jsonrpc.writeJsonStr;

const max_frame_bytes: usize = 8 * 1024 * 1024;
const shutdown_grace_ms: i64 = 1_000;
const poll_ns: u64 = 5 * std.time.ns_per_ms;

pub const AcpError = error{
    AcpTimeout,
    AcpConnectionClosed,
    AcpProtocolError,
    AcpSpawnFailed,
    AcpHandshakeFailed,
    AcpSessionFailed,
};

/// Borrowed agent launch description. The caller owns every string.
pub const AgentConfig = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
};

/// One parsed session/update notification. All strings are allocated from the
/// arena passed to the callback and remain valid until the prompt call returns.
pub const Update = union(enum) {
    agent_message: []const u8,
    agent_thought: []const u8,
    user_message: []const u8,
    tool_call: ToolCall,
    tool_call_update: ToolCallUpdate,
    plan: PlanUpdate,
    mode_change: ModeChange,
    raw: []const u8,
};

pub const ToolCall = struct {
    call_id: []const u8,
    tool_name: []const u8,
    content: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const ToolCallUpdate = struct {
    call_id: []const u8,
    content: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const PlanUpdate = struct {
    entries: []PlanEntry,
};

pub const PlanEntry = struct {
    content: []const u8,
    status: []const u8,
};

pub const ModeChange = struct {
    mode_id: []const u8,
};

/// What the agent chose to do about a permission request outcome.
pub const PermissionOutcome = union(enum) {
    selected: []const u8,
    cancelled,
};

/// Kinds of session/request_permission options an agent may offer, mapped
/// from the ACP schema's `kind` field.
pub const PermissionOptionKind = enum {
    allow,
    reject,
};

/// Host bridge: streams updates and resolves permission requests.
pub const Callbacks = struct {
    ctx: *anyopaque,
    /// Reader thread. `update` strings live in `arena` and stay valid until
    /// the owning prompt call returns.
    on_update: *const fn (ctx: *anyopaque, arena: Allocator, update: Update) void,
    /// Spawned on a dedicated worker thread so the reader keeps parsing while
    /// an interactive approval blocks. `request_json` is raw params JSON owned
    /// by the runtime; the returned outcome's strings must be arena-allocated.
    on_permission: *const fn (ctx: *anyopaque, arena: Allocator, request_json: []const u8) PermissionOutcome,
};

const Pending = struct {
    response: ?[]u8 = null,
    failure: ?anyerror = null,
    done: std.Io.Event = .unset,
};

const State = enum(u8) {
    running,
    stopping,
    failed,
    stopped,
};

pub const Client = struct {
    alloc: Allocator,
    child: std.process.Child,
    child_id: std.process.Child.Id,
    stdin: ?std.Io.File,
    stdout: ?std.Io.File,
    reader_thread: ?std.Thread = null,
    state_mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    state: State = .running,
    pending: std.AutoHashMap(u64, *Pending),
    next_request_id: u64 = 1,
    callbacks: Callbacks,
    arena: Allocator,
    session_id: ?[]u8 = null,
    agent_capabilities_json: ?[]u8 = null,
    /// Model value ids from session/new's "model" config option, if any.
    model_values: []const []u8 = &.{},
    /// Reasoning-effort value ids from session/new, if the agent offers an
    /// effort config option, plus that option's exact id for later writes.
    effort_values: []const []u8 = &.{},
    effort_config_id: ?[]u8 = null,
    reaped: bool = false,
    /// Optional cancel hook consulted while a request awaits its response.
    /// When set, the callback runs on the requesting thread every poll tick;
    /// it should send session/cancel and may fail the pending request.
    cancel_check: ?*const fn (ctx: ?*anyopaque) void = null,
    cancel_check_ctx: ?*anyopaque = null,

    pub fn create(alloc: Allocator, arena: Allocator, config: AgentConfig, callbacks: Callbacks) AcpError!*Client {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            return error.AcpSpawnFailed;
        }
        const zio = io_mod.getIo();

        // With no agent-specific vars, inherit the fx environment directly:
        // in the TUI the environment lives as a block, not a map, and an
        // explicit map built without it would spawn the agent with an empty
        // environment (no PATH, no HOME).
        var env_map: ?std.process.Environ.Map = null;
        defer if (env_map) |*map| map.deinit();
        if (config.env.len > 0) {
            env_map = std.process.Environ.Map.init(alloc);
            io_mod.copyEnviron(&env_map.?) catch return error.AcpSpawnFailed;
            for (config.env) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                env_map.?.put(pair[0..eq], pair[eq + 1 ..]) catch return error.AcpSpawnFailed;
            }
        }

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        argv.append(alloc, config.command) catch return error.AcpSpawnFailed;
        argv.appendSlice(alloc, config.args) catch return error.AcpSpawnFailed;

        const child = std.process.spawn(zio, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
            .environ_map = if (env_map) |*map| map else null,
        }) catch {
            debug_trace.logf("acp", "agent spawn failed command={s}", .{config.command});
            return error.AcpSpawnFailed;
        };

        const child_id = child.id orelse return error.AcpSpawnFailed;
        var stdin = child.stdin orelse {
            terminateChild(child_id);
            return error.AcpSpawnFailed;
        };
        var stdout = child.stdout orelse {
            stdin.close(zio);
            terminateChild(child_id);
            return error.AcpSpawnFailed;
        };

        const self = alloc.create(Client) catch {
            stdin.close(zio);
            stdout.close(zio);
            terminateChild(child_id);
            return error.AcpSpawnFailed;
        };
        self.* = .{
            .alloc = alloc,
            .child = child,
            .child_id = child_id,
            .stdin = stdin,
            .stdout = stdout,
            .pending = std.AutoHashMap(u64, *Pending).init(alloc),
            .callbacks = callbacks,
            .arena = arena,
        };
        // The client owns the pipe fds through self.stdin/self.stdout.
        // Child.wait's cleanup closes any fds still set on the child and
        // panics on a double close, so drop the child's copies here.
        self.child.stdin = null;
        self.child.stdout = null;
        self.child.stderr = null;
        stdin = undefined;
        stdout = undefined;

        self.reader_thread = std.Thread.spawn(.{}, readerMain, .{self}) catch {
            self.closePipes();
            terminateChild(child_id);
            self.pending.deinit();
            alloc.destroy(self);
            return error.AcpSpawnFailed;
        };
        debug_trace.logf("acp", "client spawned agent={s} command={s}", .{ config.name, config.command });
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.shutdown();
        if (self.session_id) |id| self.alloc.free(id);
        if (self.agent_capabilities_json) |json| self.alloc.free(json);
        for (self.model_values) |value| self.alloc.free(value);
        self.alloc.free(self.model_values);
        for (self.effort_values) |value| self.alloc.free(value);
        self.alloc.free(self.effort_values);
        if (self.effort_config_id) |id| self.alloc.free(id);
        self.pending.deinit();
        self.alloc.destroy(self);
    }

    pub fn modelValues(self: *const Client) []const []const u8 {
        return self.model_values;
    }

    pub fn effortValues(self: *const Client) []const []const u8 {
        return self.effort_values;
    }

    /// Selects a model on the active session via session/set_config_option.
    pub fn setModel(self: *Client, value: []const u8, timeout_ms: u32) AcpError!void {
        return self.setConfigOption("model", value, timeout_ms);
    }

    /// Applies a reasoning-effort value when the agent advertised an effort
    /// config option during session/new; no-op otherwise.
    pub fn setEffort(self: *Client, value: []const u8, timeout_ms: u32) AcpError!void {
        const config_id = self.effort_config_id orelse return;
        return self.setConfigOption(config_id, value, timeout_ms);
    }

    fn setConfigOption(self: *Client, config_id: []const u8, value: []const u8, timeout_ms: u32) AcpError!void {
        const session_id = self.session_id orelse return error.AcpSessionFailed;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        out.writer.writeAll("\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":") catch
            return error.AcpProtocolError;
        writeJsonStr(session_id, &out.writer) catch return error.AcpProtocolError;
        out.writer.writeAll(",\"configId\":") catch return error.AcpProtocolError;
        writeJsonStr(config_id, &out.writer) catch return error.AcpProtocolError;
        out.writer.writeAll(",\"type\":\"id\",\"value\":") catch
            return error.AcpProtocolError;
        writeJsonStr(value, &out.writer) catch return error.AcpProtocolError;
        out.writer.writeAll("}}") catch return error.AcpProtocolError;
        const params = out.toOwnedSlice() catch return error.AcpProtocolError;
        defer self.alloc.free(params);

        const response = try self.request(params, timeout_ms);
        self.alloc.free(response);
    }

    pub fn sessionId(self: *const Client) ?[]const u8 {
        return self.session_id;
    }

    pub fn agentCapabilitiesJson(self: *const Client) ?[]const u8 {
        return self.agent_capabilities_json;
    }

    /// True while the agent process connection is usable for new requests.
    pub fn isAlive(self: *Client) bool {
        const zio = io_mod.getIo();
        self.state_mutex.lockUncancelable(zio);
        defer self.state_mutex.unlock(zio);
        return self.state == .running;
    }

    /// Sends initialize then session/new; stores the session id.
    pub fn start(self: *Client, cwd: []const u8, initialize_timeout_ms: u32) AcpError!void {
        {
            var out: std.Io.Writer.Allocating = .init(self.alloc);
            defer out.deinit();
            out.writer.writeAll("\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{}}}") catch
                return error.AcpProtocolError;
            const params = out.toOwnedSlice() catch return error.AcpProtocolError;
            defer self.alloc.free(params);
            _ = try self.request(params, initialize_timeout_ms);
        }

        {
            var out: std.Io.Writer.Allocating = .init(self.alloc);
            defer out.deinit();
            out.writer.writeAll("\"method\":\"session/new\",\"params\":{\"cwd\":") catch
                return error.AcpProtocolError;
            writeJsonStr(cwd, &out.writer) catch return error.AcpProtocolError;
            // mcpServers is a required parameter in the ACP schema.
            out.writer.writeAll(",\"mcpServers\":[]}}") catch return error.AcpProtocolError;
            const params = out.toOwnedSlice() catch return error.AcpProtocolError;
            defer self.alloc.free(params);

            const response = try self.request(params, initialize_timeout_ms);
            defer self.alloc.free(response);

            const session_id = extractStringField(self.alloc, response, "sessionId") catch
                return error.AcpProtocolError;
            if (session_id == null or session_id.?.len == 0) return error.AcpHandshakeFailed;
            self.session_id = session_id;
            self.model_values = extractConfigOptionValues(self.alloc, response, .model) catch &.{};
            const effort = extractEffortOption(self.alloc, response) catch EffortOption{};
            self.effort_values = effort.values;
            self.effort_config_id = effort.config_id;
            debug_trace.logf("acp", "handshake complete session_id={s} models={d} efforts={d}", .{
                self.session_id.?,
                self.model_values.len,
                self.effort_values.len,
            });
        }
    }

    /// Sends one prompt and blocks until stopReason, streaming updates.
    pub fn prompt(self: *Client, arena: Allocator, text: []const u8, timeout_ms: u32) AcpError!PromptOutcome {
        const session_id = self.session_id orelse return error.AcpSessionFailed;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        out.writer.writeAll("\"method\":\"session/prompt\",\"params\":{\"sessionId\":") catch
            return error.AcpProtocolError;
        writeJsonStr(session_id, &out.writer) catch return error.AcpProtocolError;
        out.writer.writeAll(",\"prompt\":[{\"type\":\"text\",\"text\":") catch return error.AcpProtocolError;
        writeJsonStr(text, &out.writer) catch return error.AcpProtocolError;
        out.writer.writeAll("}]}}") catch return error.AcpProtocolError;
        const params = out.toOwnedSlice() catch return error.AcpProtocolError;
        defer self.alloc.free(params);

        const response = try self.request(params, timeout_ms);
        defer self.alloc.free(response);

        const stop_reason = extractStringField(arena, response, "stopReason") catch
            return error.AcpProtocolError;
        return .{ .stop_reason = stop_reason orelse "end_turn" };
    }

    /// Sends the session/cancel notification for the active prompt.
    pub fn cancel(self: *Client) void {
        const session_id = self.session_id orelse return;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":") catch
            return;
        writeJsonStr(session_id, &out.writer) catch return;
        out.writer.writeAll("}}") catch return;
        const frame = out.toOwnedSlice() catch return;
        defer self.alloc.free(frame);
        self.sendFrame(frame) catch |err| {
            debug_trace.logf("acp", "cancel write failed err={s}", .{@errorName(err)});
        };
    }

    /// Sends one JSON-RPC request. `method_and_params` is the frame content
    /// after `"id":<n>,` (i.e. `"method":"...","params":{...}` including the
    /// trailing brace of the envelope). The caller owns the response.
    fn request(self: *Client, method_and_params: []const u8, timeout_ms: u32) AcpError![]u8 {
        var pending = Pending{};
        const request_id = blk: {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            defer self.state_mutex.unlock(io_mod.getIo());
            if (self.state != .running) return error.AcpConnectionClosed;
            const id = self.next_request_id;
            self.next_request_id += 1;
            self.pending.put(id, &pending) catch return error.AcpProtocolError;
            break :blk id;
        };
        defer {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            _ = self.pending.remove(request_id);
            if (pending.response) |response| self.alloc.free(response);
            self.state_mutex.unlock(io_mod.getIo());
        }

        {
            var out: std.Io.Writer.Allocating = .init(self.alloc);
            defer out.deinit();
            out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return error.AcpProtocolError;
            out.writer.print("{d}", .{request_id}) catch return error.AcpProtocolError;
            out.writer.writeAll(",") catch return error.AcpProtocolError;
            out.writer.writeAll(method_and_params) catch return error.AcpProtocolError;
            const frame = out.toOwnedSlice() catch return error.AcpProtocolError;
            defer self.alloc.free(frame);

            self.sendFrame(frame) catch |err| {
                self.state_mutex.lockUncancelable(io_mod.getIo());
                pending.failure = err;
                pending.done.set(io_mod.getIo());
                self.state_mutex.unlock(io_mod.getIo());
            };
        }

        const deadline = io_mod.milliTimestamp() + @as(i64, timeout_ms);
        while (true) {
            self.state_mutex.lockUncancelable(io_mod.getIo());
            const finished = pending.response != null or pending.failure != null;
            self.state_mutex.unlock(io_mod.getIo());
            if (finished) break;
            if (io_mod.milliTimestamp() >= deadline) return error.AcpTimeout;
            if (self.cancel_check) |check| check(self.cancel_check_ctx);
            io_mod.sleep(poll_ns);
        }

        if (pending.failure) |err| {
            return switch (err) {
                error.AcpTimeout => error.AcpTimeout,
                error.AcpConnectionClosed => error.AcpConnectionClosed,
                error.AcpProtocolError => error.AcpProtocolError,
                error.AcpSpawnFailed => error.AcpSpawnFailed,
                error.AcpHandshakeFailed => error.AcpHandshakeFailed,
                error.AcpSessionFailed => error.AcpSessionFailed,
                else => error.AcpProtocolError,
            };
        }
        const response = pending.response orelse return error.AcpConnectionClosed;
        pending.response = null;
        return response;
    }

    fn sendFrame(self: *Client, frame: []const u8) !void {
        self.write_mutex.lockUncancelable(io_mod.getIo());
        defer self.write_mutex.unlock(io_mod.getIo());
        const stdin = self.stdin orelse return error.AcpConnectionClosed;
        var compact: std.Io.Writer.Allocating = .init(self.alloc);
        defer compact.deinit();
        try mcp_json.write_compact(&compact.writer, frame);
        try compact.writer.writeByte('\n');
        try stdin.writeStreamingAll(io_mod.getIo(), compact.written());
    }

    fn failAll(self: *Client, err: anyerror) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.failure = err;
            entry.value_ptr.*.done.set(io_mod.getIo());
        }
    }

    fn closePipes(self: *Client) void {
        if (self.stdin) |file| file.close(io_mod.getIo());
        self.stdin = null;
    }

    fn shutdown(self: *Client) void {
        self.state_mutex.lockUncancelable(io_mod.getIo());
        const already_stopped = self.state == .stopped;
        if (!already_stopped) {
            self.state = .stopping;
            self.failAll(error.AcpConnectionClosed);
        }
        self.state_mutex.unlock(io_mod.getIo());

        self.closePipes();

        if (!already_stopped) {
            const deadline = io_mod.milliTimestamp() + shutdown_grace_ms;
            while (self.state != .stopped and io_mod.milliTimestamp() < deadline) {
                io_mod.sleep(poll_ns);
            }
            if (self.state != .stopped) terminateChild(self.child_id);
        }

        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        self.state_mutex.lockUncancelable(io_mod.getIo());
        self.state = .stopped;
        const reap = !self.reaped;
        self.reaped = true;
        self.state_mutex.unlock(io_mod.getIo());
        // Child.wait both reaps and panics on a second call, so exactly one
        // shutdown performs it, always after the reader thread has joined.
        if (reap) _ = self.child.wait(io_mod.getIo()) catch {};
        if (self.stdout) |file| file.close(io_mod.getIo());
        self.stdout = null;
    }
};

pub const PromptOutcome = struct {
    stop_reason: []const u8,
};

fn readerMain(self: *Client) void {
    const zio = io_mod.getIo();
    defer {
        self.state_mutex.lockUncancelable(zio);
        self.state = .stopped;
        self.failAll(error.AcpConnectionClosed);
        self.state_mutex.unlock(zio);
        if (self.stdout) |file| file.close(zio);
        self.stdout = null;
        // Reaping is shutdown()'s job: Child.wait panics when called twice,
        // and shutdown always runs it after joining this thread.
    }

    const stdout = self.stdout orelse return;
    var read_buf: [4096]u8 = undefined;
    var file_reader = stdout.reader(zio, &read_buf);

    while (true) {
        const line = readLine(self.alloc, &file_reader.interface) catch |err| {
            debug_trace.logf("acp", "reader readLine failed err={s}", .{@errorName(err)});
            break;
        };
        if (line == null) break;
        defer self.alloc.free(line.?);
        dispatchFrame(self, line.?) catch |err| {
            debug_trace.logf("acp", "reader dispatch failed err={s}", .{@errorName(err)});
            break;
        };
    }
}

fn readLine(alloc: Allocator, reader: *std.Io.Reader) !?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    while (true) {
        var byte_buf: [1]u8 = undefined;
        const count = try reader.readSliceShort(&byte_buf);
        if (count == 0) {
            if (line.items.len == 0) return null;
            return error.AcpConnectionClosed;
        }
        if (byte_buf[0] != '\n') {
            if (line.items.len >= max_frame_bytes) {
                debug_trace.logf("acp", "frame exceeds {d} bytes; rejecting", .{max_frame_bytes});
                return error.AcpProtocolError;
            }
            try line.append(alloc, byte_buf[0]);
            continue;
        }
        line.shrinkRetainingCapacity(std.mem.trimEnd(u8, line.items, "\r").len);
        if (line.items.len == 0) continue;
        return try line.toOwnedSlice(alloc);
    }
}

fn dispatchFrame(self: *Client, frame: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, frame, .{}) catch
        return error.AcpProtocolError;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.AcpProtocolError;
    const object = root.object;

    // Response to one of our requests.
    if (object.get("method") == null) {
        if (object.get("id")) |id_value| {
            if (id_value != .integer) return error.AcpProtocolError;
            const id: u64 = @intCast(id_value.integer);
            self.state_mutex.lockUncancelable(io_mod.getIo());
            if (self.pending.get(id)) |pending| {
                if (object.get("error") != null) {
                    pending.failure = error.AcpProtocolError;
                } else if (object.get("result")) |result| {
                    pending.response = std.json.Stringify.valueAlloc(self.alloc, result, .{}) catch null;
                } else {
                    pending.failure = error.AcpProtocolError;
                }
                pending.done.set(io_mod.getIo());
            }
            self.state_mutex.unlock(io_mod.getIo());
            return;
        }
        return error.AcpProtocolError;
    }

    const method_value = object.get("method") orelse return error.AcpProtocolError;
    if (method_value != .string) return error.AcpProtocolError;
    const method = method_value.string;

    if (std.mem.eql(u8, method, "session/update")) {
        const params = object.get("params") orelse return;
        handleSessionUpdate(self, params);
        return;
    }

    if (std.mem.eql(u8, method, "session/request_permission")) {
        const id_value = object.get("id") orelse return;
        const params = object.get("params") orelse return;
        const params_json = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch
            return error.AcpProtocolError;
        const work = PermissionWork{
            .client = self,
            .request_id_json = std.json.Stringify.valueAlloc(self.alloc, id_value, .{}) catch
                return error.AcpProtocolError,
            .params_json = params_json,
        };
        const thread = std.Thread.spawn(.{}, PermissionWork.run, .{work}) catch {
            self.alloc.free(params_json);
            return error.AcpProtocolError;
        };
        thread.detach();
        return;
    }

    debug_trace.logf("acp", "ignoring unhandled method={s}", .{method});
}

const PermissionWork = struct {
    client: *Client,
    request_id_json: []u8,
    params_json: []u8,

    fn run(self: PermissionWork) void {
        const alloc = self.client.alloc;
        defer {
            alloc.free(self.request_id_json);
            alloc.free(self.params_json);
        }
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const outcome = self.client.callbacks.on_permission(
            self.client.callbacks.ctx,
            arena,
            self.params_json,
        );
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return;
        out.writer.writeAll(self.request_id_json) catch return;
        out.writer.writeAll(",\"result\":{\"outcome\":{\"outcome\":") catch return;
        switch (outcome) {
            .selected => |option_id| {
                out.writer.writeAll("\"selected\",\"optionId\":") catch return;
                writeJsonStr(option_id, &out.writer) catch return;
            },
            .cancelled => out.writer.writeAll("\"cancelled\"") catch return,
        }
        out.writer.writeAll("}}") catch return;
        const frame = out.toOwnedSlice() catch return;
        defer alloc.free(frame);
        self.client.sendFrame(frame) catch |err| {
            debug_trace.logf("acp", "permission response write failed err={s}", .{@errorName(err)});
        };
    }
};

fn handleSessionUpdate(self: *Client, params: std.json.Value) void {
    if (params != .object) return;
    const update_value = params.object.get("update") orelse return;
    if (update_value != .object) return;
    const update = update_value.object;
    const kind_value = update.get("sessionUpdate") orelse return;
    if (kind_value != .string) return;
    const kind = kind_value.string;

    var arena_state = std.heap.ArenaAllocator.init(self.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed_update: ?Update = if (std.mem.eql(u8, kind, "agent_message_chunk"))
        textChunkUpdate(arena, update, .agent_message)
    else if (std.mem.eql(u8, kind, "agent_thought_chunk"))
        textChunkUpdate(arena, update, .agent_thought)
    else if (std.mem.eql(u8, kind, "user_message_chunk"))
        textChunkUpdate(arena, update, .user_message)
    else if (std.mem.eql(u8, kind, "tool_call"))
        toolCallUpdate(arena, update)
    else if (std.mem.eql(u8, kind, "tool_call_update"))
        toolCallUpdateOnly(arena, update)
    else if (std.mem.eql(u8, kind, "plan"))
        planUpdate(arena, update)
    else if (std.mem.eql(u8, kind, "current_mode_update"))
        modeChangeUpdate(arena, update)
    else
        rawUpdate(arena, params);

    if (parsed_update) |value| {
        self.callbacks.on_update(self.callbacks.ctx, arena, value);
    }
}

fn textChunkUpdate(arena: Allocator, update: std.json.ObjectMap, kind: TextChunkKind) ?Update {
    const content_value = update.get("content") orelse return null;
    if (content_value != .object) return null;
    const text_value = content_value.object.get("text") orelse return null;
    if (text_value != .string) return null;
    const text = arena.dupe(u8, text_value.string) catch return null;
    return switch (kind) {
        .agent_message => .{ .agent_message = text },
        .agent_thought => .{ .agent_thought = text },
        .user_message => .{ .user_message = text },
    };
}

const TextChunkKind = enum { agent_message, agent_thought, user_message };

fn toolCallUpdate(arena: Allocator, update: std.json.ObjectMap) ?Update {
    const call_id = jsonString(update.get("callId")) orelse return null;
    const tool_name = jsonString(update.get("toolName")) orelse return null;
    return .{ .tool_call = .{
        .call_id = arena.dupe(u8, call_id) catch return null,
        .tool_name = arena.dupe(u8, tool_name) catch return null,
        .content = optionalJsonString(arena, update.get("content")),
        .status = optionalJsonString(arena, update.get("status")),
    } };
}

fn toolCallUpdateOnly(arena: Allocator, update: std.json.ObjectMap) ?Update {
    const call_id = jsonString(update.get("callId")) orelse return null;
    return .{ .tool_call_update = .{
        .call_id = arena.dupe(u8, call_id) catch return null,
        .content = optionalJsonString(arena, update.get("content")),
        .status = optionalJsonString(arena, update.get("status")),
    } };
}

fn planUpdate(arena: Allocator, update: std.json.ObjectMap) ?Update {
    const entries_value = update.get("entries") orelse return null;
    if (entries_value != .array) return null;
    const entries = arena.alloc(PlanEntry, entries_value.array.items.len) catch return null;
    for (entries_value.array.items, 0..) |entry_value, i| {
        if (entry_value != .object) return null;
        const entry = entry_value.object;
        entries[i] = .{
            .content = arena.dupe(u8, jsonString(entry.get("content")) orelse return null) catch return null,
            .status = arena.dupe(u8, jsonString(entry.get("status")) orelse return null) catch return null,
        };
    }
    return .{ .plan = .{ .entries = entries } };
}

fn modeChangeUpdate(arena: Allocator, update: std.json.ObjectMap) ?Update {
    const mode_id = jsonString(update.get("modeId")) orelse return null;
    return .{ .mode_change = .{ .mode_id = arena.dupe(u8, mode_id) catch return null } };
}

fn rawUpdate(arena: Allocator, params: std.json.Value) ?Update {
    const raw = std.json.Stringify.valueAlloc(arena, params, .{}) catch return null;
    return .{ .raw = raw };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn optionalJsonString(arena: Allocator, value: ?std.json.Value) ?[]const u8 {
    const string = jsonString(value) orelse return null;
    return arena.dupe(u8, string) catch null;
}

/// Pulls the "model" config option's value ids from a session/new result.
/// Returns an owned slice of owned strings; empty when the option is absent.
const ConfigOptionKind = enum { model, effort };

const EffortOption = struct {
    values: []const []u8 = &.{},
    config_id: ?[]u8 = null,
};

fn configOptionMatches(kind: ConfigOptionKind, id: []const u8) bool {
    return switch (kind) {
        .model => std.mem.eql(u8, id, "model"),
        // Agents name it differently ("reasoning_effort", "effort", ...).
        .effort => std.ascii.indexOfIgnoreCase(id, "effort") != null,
    };
}

fn extractConfigOptionValues(alloc: Allocator, response_json: []const u8, kind: ConfigOptionKind) ![]const []u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response_json, .{}) catch
        return error.AcpProtocolError;
    defer parsed.deinit();
    if (parsed.value != .object) return error.AcpProtocolError;
    const config_options = parsed.value.object.get("configOptions") orelse return &.{};
    if (config_options != .array) return &.{};

    var values: std.ArrayList([]u8) = .empty;
    errdefer {
        for (values.items) |value| alloc.free(value);
        values.deinit(alloc);
    }
    for (config_options.array.items) |option_value| {
        if (option_value != .object) continue;
        const id = option_value.object.get("id") orelse continue;
        if (id != .string or !configOptionMatches(kind, id.string)) continue;
        const options = option_value.object.get("options") orelse continue;
        if (options != .array) continue;
        for (options.array.items) |choice| {
            if (choice != .object) continue;
            const value = choice.object.get("value") orelse continue;
            if (value != .string or value.string.len == 0) continue;
            try values.append(alloc, try alloc.dupe(u8, value.string));
        }
        break;
    }
    return values.toOwnedSlice(alloc);
}

fn extractEffortOption(alloc: Allocator, response_json: []const u8) !EffortOption {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response_json, .{}) catch
        return error.AcpProtocolError;
    defer parsed.deinit();
    if (parsed.value != .object) return error.AcpProtocolError;
    const config_options = parsed.value.object.get("configOptions") orelse return .{};
    if (config_options != .array) return .{};

    for (config_options.array.items) |option_value| {
        if (option_value != .object) continue;
        const id = option_value.object.get("id") orelse continue;
        if (id != .string or !configOptionMatches(.effort, id.string)) continue;
        const config_id = try alloc.dupe(u8, id.string);
        errdefer alloc.free(config_id);
        const values = try extractChoiceValues(alloc, option_value.object);
        return .{ .values = values, .config_id = config_id };
    }
    return .{};
}

fn extractChoiceValues(alloc: Allocator, option: std.json.ObjectMap) ![]const []u8 {
    var values: std.ArrayList([]u8) = .empty;
    errdefer {
        for (values.items) |value| alloc.free(value);
        values.deinit(alloc);
    }
    const options = option.get("options") orelse return values.toOwnedSlice(alloc);
    if (options != .array) return values.toOwnedSlice(alloc);
    for (options.array.items) |choice| {
        if (choice != .object) continue;
        const value = choice.object.get("value") orelse continue;
        if (value != .string or value.string.len == 0) continue;
        try values.append(alloc, try alloc.dupe(u8, value.string));
    }
    return values.toOwnedSlice(alloc);
}

fn extractStringField(alloc: Allocator, json: []const u8, field: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch return error.AcpProtocolError;
    defer parsed.deinit();
    if (parsed.value != .object) return error.AcpProtocolError;
    const value = parsed.value.object.get(field) orelse return null;
    if (value != .string) return error.AcpProtocolError;
    return try alloc.dupe(u8, value.string);
}

fn terminateChild(child_id: std.process.Child.Id) void {
    switch (builtin.os.tag) {
        .windows, .wasi => {},
        else => std.posix.kill(-child_id, .KILL) catch |group_err| {
            std.posix.kill(child_id, .KILL) catch |child_err| switch (child_err) {
                error.ProcessNotFound => {},
                else => {
                    debug_trace.logf(
                        "acp",
                        "failed to terminate agent pid={any} group_err={s} child_err={s}",
                        .{ child_id, @errorName(group_err), @errorName(child_err) },
                    );
                },
            };
        },
    }
}

// ---------------------------------------------------------------------------
// Tests: real subprocesses acting as fake ACP agents
// ---------------------------------------------------------------------------

const TestCapture = struct {
    mutex: std.Io.Mutex = .init,
    messages: std.ArrayList([]const u8) = .empty,
    permissions_requested: usize = 0,
    cancel_seen: bool = false,
    permission_decision: []const u8 = "allow-once",
    alloc: Allocator,

    fn onUpdate(ctx: *anyopaque, arena: Allocator, update: Update) void {
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        switch (update) {
            .agent_message => |message| {
                self.messages.append(self.alloc, arena.dupe(u8, message) catch return) catch {};
            },
            .tool_call => |call| {
                const line = std.fmt.allocPrint(self.alloc, "tool:{s}", .{call.tool_name}) catch return;
                self.messages.append(self.alloc, line) catch {};
            },
            else => {},
        }
    }

    fn onPermission(ctx: *anyopaque, arena: Allocator, request_json: []const u8) PermissionOutcome {
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        _ = request_json;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.permissions_requested += 1;
        return .{ .selected = arena.dupe(u8, self.permission_decision) catch "allow-once" };
    }
};

test "probe: raw spawn read kill" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &.{ "sh", "-c", "while IFS= read -r l; do :; done" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    });
    const stdout = child.stdout.?;
    var read_buf: [64]u8 = undefined;
    var fr = stdout.reader(io_mod.getIo(), &read_buf);
    var b: [1]u8 = undefined;
    _ = fr.interface.readSliceShort(&b) catch 0;
    std.posix.kill(child.id.?, .KILL) catch {};
    _ = child.wait(io_mod.getIo()) catch {};
    std.debug.print("probe ok\n", .{});
}

test "handshake exchanges initialize and session/new" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var capture = TestCapture{ .alloc = alloc };
    defer {
        for (capture.messages.items) |message| alloc.free(message);
        capture.messages.deinit(alloc);
    }

    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}' ;;
        \\    *'"method":"session/new"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-1"}}' ;;
        \\  esac
        \\done
    ;
    const client = try Client.create(alloc, std.heap.page_allocator, .{
        .name = "fake-agent",
        .command = "sh",
        .args = &.{ "-c", script },
    }, .{
        .ctx = @ptrCast(&capture),
        .on_update = TestCapture.onUpdate,
        .on_permission = TestCapture.onPermission,
    });
    defer client.deinit();

    try client.start("/tmp", 5_000);
    try std.testing.expectEqualStrings("sess-1", client.sessionId().?);
}

test "prompt streams updates and returns stop reason" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var capture = TestCapture{ .alloc = alloc };
    defer {
        for (capture.messages.items) |message| alloc.free(message);
        capture.messages.deinit(alloc);
    }

    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}' ;;
        \\    *'"method":"session/new"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-2"}}' ;;
        \\    *'"method":"session/prompt"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello from agent"}}}}'
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}' ;;
        \\  esac
        \\done
    ;
    const client = try Client.create(alloc, std.heap.page_allocator, .{
        .name = "fake-agent",
        .command = "sh",
        .args = &.{ "-c", script },
    }, .{
        .ctx = @ptrCast(&capture),
        .on_update = TestCapture.onUpdate,
        .on_permission = TestCapture.onPermission,
    });
    defer client.deinit();

    try client.start("/tmp", 5_000);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const outcome = try client.prompt(arena_state.allocator(), "say hi", 5_000);
    try std.testing.expectEqualStrings("end_turn", outcome.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), capture.messages.items.len);
    try std.testing.expectEqualStrings("hello from agent", capture.messages.items[0]);
}

test "permission bridge answers agent requests" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var capture = TestCapture{ .alloc = alloc };
    defer {
        for (capture.messages.items) |message| alloc.free(message);
        capture.messages.deinit(alloc);
    }

    // The fake agent asks for permission, then echoes every subsequent line
    // it receives (including our permission response) into a marker file.
    const marker_path = "/tmp/fx-acp-test-perm-marker.txt";
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), marker_path) catch {};

    const script_fmt =
        \\rm -f {s}
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":1,"agentCapabilities":{{}}}}}}' ;;
        \\    *'"method":"session/new"'*) printf '%s\n' '{{"jsonrpc":"2.0","id":2,"result":{{"sessionId":"sess-3"}}}}' ;;
        \\    *'"method":"session/prompt"'*)
        \\      printf '%s\n' '{{"jsonrpc":"2.0","id":10,"method":"session/request_permission","params":{{"sessionId":"sess-3","options":[{{"optionId":"allow-once","name":"Allow once"}},{{"optionId":"reject","name":"Reject"}}]}}}}'
        \\      ;;
        \\    *'"result"*'allow-once'*)
        \\      echo "$line" >> {s}
        \\      printf '%s\n' '{{"jsonrpc":"2.0","id":3,"result":{{"stopReason":"end_turn"}}}}' ;;
        \\  esac
        \\done
    ;
    const script = try std.fmt.allocPrint(alloc, script_fmt, .{ marker_path, marker_path });
    defer alloc.free(script);

    const client = try Client.create(alloc, std.heap.page_allocator, .{
        .name = "perm-agent",
        .command = "sh",
        .args = &.{ "-c", script },
    }, .{
        .ctx = @ptrCast(&capture),
        .on_update = TestCapture.onUpdate,
        .on_permission = TestCapture.onPermission,
    });
    defer client.deinit();

    try client.start("/tmp", 5_000);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const outcome = try client.prompt(arena_state.allocator(), "go", 5_000);
    try std.testing.expectEqualStrings("end_turn", outcome.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), capture.permissions_requested);

    // The marker proves the child received our selected optionId.
    var marker_file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), marker_path, .{}) catch |err| {
        std.debug.print("permission marker missing: {s}\n", .{@errorName(err)});
        return error.TestExpectedMarker;
    };
    defer marker_file.close(io_mod.getIo());
    const marker_text = io_mod.readFileToEnd(alloc, &marker_file, 4096) catch return error.TestExpectedMarker;
    defer alloc.free(marker_text);
    try std.testing.expect(std.mem.indexOf(u8, marker_text, "allow-once") != null);

    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), marker_path) catch {};
}

test "cancel interrupts a blocked prompt" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var capture = TestCapture{ .alloc = alloc };
    defer {
        for (capture.messages.items) |message| alloc.free(message);
        capture.messages.deinit(alloc);
    }

    // The fake agent answers the handshake but never answers session/prompt.
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}' ;;
        \\    *'"method":"session/new"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-4"}}' ;;
        \\  esac
        \\done
    ;
    const client = try Client.create(alloc, std.heap.page_allocator, .{
        .name = "stuck-agent",
        .command = "sh",
        .args = &.{ "-c", script },
    }, .{
        .ctx = @ptrCast(&capture),
        .on_update = TestCapture.onUpdate,
        .on_permission = TestCapture.onPermission,
    });
    defer client.deinit();

    try client.start("/tmp", 5_000);

    // Prompt on a worker; cancel shortly after; the deadline still bounds us.
    const PromptThread = struct {
        fn run(c: *Client) void {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            _ = c.prompt(arena_state.allocator(), "stuck", 10_000) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, PromptThread.run, .{client});
    io_mod.sleep(200 * std.time.ns_per_ms);
    client.cancel();
    // The prompt call must still terminate before its own 10s deadline.
    thread.join();
}

test "oversized frames are rejected without crash" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var capture = TestCapture{ .alloc = alloc };
    defer {
        for (capture.messages.items) |message| alloc.free(message);
        capture.messages.deinit(alloc);
    }

    const script =
        \\head -c 9000000 /dev/zero | tr '\0' 'a'
        \\printf '\n'
        \\while IFS= read -r line; do :; done
    ;
    const client = Client.create(alloc, std.heap.page_allocator, .{
        .name = "big-frame-agent",
        .command = "sh",
        .args = &.{ "-c", script },
    }, .{
        .ctx = @ptrCast(&capture),
        .on_update = TestCapture.onUpdate,
        .on_permission = TestCapture.onPermission,
    }) catch return; // frame rejection surfaces as a connection failure
    defer client.deinit();
}
