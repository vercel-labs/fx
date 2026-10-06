//! Session-owned native children isolate protocol lifetime from borrowed model requests.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const manifest = @import("manifest.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("../auth/secret.zig");
const types = @import("../shared/types.zig");
const streams = @import("../agent/stream_provider.zig");
const dispatcher_mod = @import("../mcp/stdio_dispatcher.zig");

const Allocator = std.mem.Allocator;
const jsonrpc_version = "2.0";
const lifecycle_timeout_ms = 10_000;
const stream_timeout_ms = 300_000;
const shutdown_timeout_ms = 1_000;
const max_executable_bytes = 64 * 1024 * 1024;
const max_handle_bytes = 256;
const max_tool_calls = 128;
const max_header_value_bytes = 8192;
const terminal_delete_byte = 0x7f;
const initial_generation = 1;
const identity_format = "{s}#sha256={s}";

/// Only a session owner may publish or retire a child; requests serialize on its mutex.
pub const Runtime = struct {
    mutex: std.Io.Mutex = .init,
    dispatcher: ?*dispatcher_mod.StdioDispatcher = null,
    identity: ?[]u8 = null,

    /// The owning registry calls this after all provider workers have stopped.
    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        if (self.dispatcher) |dispatcher| {
            const reply = rpc(std.json.Value, dispatcher, alloc, "shutdown", .{}, .{ .timeout_ms = shutdown_timeout_ms }) catch null;
            if (reply) |value| {
                var owned = value;
                owned.deinit();
            }
            dispatcher.deinitForced();
        }
        if (self.identity) |identity| alloc.free(identity);
        self.dispatcher = null;
        self.identity = null;
    }

    /// Failed or ambiguous streams retire their connection instead of replaying a billed request.
    pub fn stream(self: *Runtime, owner_alloc: Allocator, alloc: Allocator, root: []const u8, entrypoint: []const u8, provider: protocol.Provider, model: protocol.Model, request: streams.ModelRequest, execution_allowed: *const std.atomic.Value(bool)) !streams.Result {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        const executable = try manifest.canonical_child_path(alloc, root, entrypoint);
        defer alloc.free(executable);
        const identity = try executable_identity(alloc, executable);
        defer alloc.free(identity);
        if (self.identity) |previous| if (!std.mem.eql(u8, previous, identity)) self.deinit(owner_alloc);
        errdefer self.deinit(owner_alloc);
        if (self.dispatcher == null) {
            var environment = std.process.Environ.Map.init(alloc);
            defer environment.deinit();
            const child = try std.process.spawn(io_mod.getIo(), .{
                .argv = &.{executable},
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
                .cwd = .{ .path = root },
                .environ_map = &environment,
                .pgid = if (builtin.os.tag == .windows) null else 0,
            });
            self.dispatcher = try dispatcher_mod.StdioDispatcher.create(owner_alloc, std.heap.c_allocator, child, initial_generation, protocol.max_models_bytes);
            self.identity = try owner_alloc.dupe(u8, identity);
            var initialized = try rpc(struct { version: u32 }, self.dispatcher.?, alloc, "initialize", .{ .version = protocol.version }, .{
                .timeout_ms = lifecycle_timeout_ms,
                .deadline = request.deadline,
                .cancel_flag = request.cancel_flag,
            });
            defer initialized.deinit();
            if (initialized.value.result.?.version != protocol.version) return error.ExtensionVersionUnsupported;
        }
        const dispatcher = self.dispatcher.?;
        var prepared = try rpc(struct { handle: []const u8 }, dispatcher, alloc, "provider.prepare", .{
            .provider = .{ .id = provider.id, .base_url = provider.base_url },
            .model = model,
            .request = .{
                .model = request.model,
                .messages = request.messages,
                .functions = request.tools.advertised_functions,
                .additional_functions = request.tools.additional_functions,
                .dynamic_functions = request.tools.selected_dynamic,
                .tool_choice = request.tool_choice,
                .reasoning_effort = if (request.provider_options.reasoning) |*effort| effort.gatewayValue() else null,
                .fast = request.provider_options.fast,
                .parallel_tool_calls = request.provider_options.parallel_tool_calls,
                .max_output_tokens = request.max_output_tokens,
                .response_format = request.response_format,
            },
        }, .{ .timeout_ms = lifecycle_timeout_ms, .deadline = request.deadline, .cancel_flag = request.cancel_flag });
        defer prepared.deinit();
        const handle = prepared.value.result.?.handle;
        if (handle.len == 0 or handle.len > max_handle_bytes) return error.ExtensionPreparedHandleInvalid;
        for (handle) |byte| if (std.ascii.isControl(byte)) return error.ExtensionPreparedHandleInvalid;
        var headers = try resolved_headers(alloc, provider.headers, request.session_id);
        defer headers.deinit();
        const request_id = try dispatcher.reserveRequestId();
        const body = try encode(alloc, request_id, "provider.stream", .{
            .handle = handle,
            .credential = request.credential.secret,
            .headers = headers.value,
            .session_id = request.session_id,
        });
        defer secret.zeroAndFree(alloc, body);
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (!execution_allowed.load(.seq_cst)) return error.ExtensionExecutionPermissionRequired;
        try request.admission.admit();
        request.attempt_evidence.provider_admitted = true;
        request.delivery.markPossiblySent();
        const frame = dispatcher.request(alloc, request_id, body, protocol.max_models_bytes, .{
            .timeout_ms = stream_timeout_ms,
            .deadline = request.deadline,
            .cancel_flag = request.cancel_flag,
            .send_cancellation = false,
        }) catch |err| {
            const cancellation = rpc(std.json.Value, dispatcher, alloc, "provider.cancel", .{ .handle = handle }, .{ .timeout_ms = shutdown_timeout_ms }) catch null;
            if (cancellation) |value| {
                var owned = value;
                owned.deinit();
            }
            return if (err == error.Cancelled) error.Cancelled else error.ExtensionStreamAmbiguous;
        };
        defer alloc.free(frame);
        var completed = try parse_reply(types.ModelCompletion, alloc, request_id, frame);
        defer completed.deinit();
        const source = completed.value.result.?;
        if (source.tool_calls.len > max_tool_calls or source.finish_reason == null) return error.ExtensionCompletionInvalid;
        var result = streams.Result{ .completed = .{ .ownership = .owned, .usage = .{ .unavailable = .possibly_billed } } };
        errdefer result.deinit(alloc);
        result.completed.completion = source;
        result.completed.completion.content = null;
        result.completed.completion.tool_calls = &.{};
        result.completed.completion.generation_id = null;
        result.completed.completion.billing = null;
        result.completed.completion.provider_failure_detail = null;
        result.completed.completion.provider_state_json = null;
        if (source.content) |value| result.completed.completion.content = try alloc.dupe(u8, value[0..@min(value.len, request.content_capture_limit orelse value.len)]);
        result.completed.completion.tool_calls = try types.dupeToolCallSlice(alloc, source.tool_calls);
        if (source.generation_id) |value| result.completed.completion.generation_id = try alloc.dupe(u8, value);
        if (source.provider_state_json) |value| result.completed.completion.provider_state_json = try alloc.dupe(u8, value);
        if (source.provider_failure_detail) |value| result.completed.completion.provider_failure_detail = try alloc.dupe(u8, value);
        if (source.billing) |value| {
            var billing = value;
            billing.model = try alloc.dupe(u8, value.model);
            result.completed.completion.billing = billing;
        }
        // CLI and terminal consumers reduce neutral events rather than completion storage.
        if (source.content) |text| request.events.emit(.{ .content_delta = text });
        return result;
    }
};

/// Content identity prevents a retained process from silently surviving executable replacement.
fn executable_identity(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_executable_bytes);
    defer alloc.free(bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(alloc, identity_format, .{ path, std.fmt.bytesToHex(digest, .lower) });
}

/// Owned RPC envelopes prevent parser arenas from escaping their request lifetime.
fn Reply(comptime T: type) type {
    return struct { jsonrpc: []const u8, id: u64, result: ?T = null, @"error": ?std.json.Value = null };
}

/// The caller owns bytes, including zeroing credential-bearing envelopes.
fn encode(alloc: Allocator, id: u64, method: []const u8, params: anytype) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(alloc);
    defer writer.deinit();
    try std.json.Stringify.value(.{ .jsonrpc = jsonrpc_version, .id = id, .method = method, .params = params }, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

/// Untrusted errors remain opaque so an extension cannot echo credentials into host diagnostics.
fn parse_reply(comptime T: type, alloc: Allocator, id: u64, frame: []const u8) !std.json.Parsed(Reply(T)) {
    var parsed = try std.json.parseFromSlice(Reply(T), alloc, frame, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.jsonrpc, jsonrpc_version) or parsed.value.id != id) return error.ExtensionRpcInvalid;
    if (parsed.value.@"error" != null) return error.ExtensionRpcFailed;
    if (parsed.value.result == null) return error.ExtensionRpcInvalid;
    return parsed;
}

/// Dispatcher IDs and cancellation semantics stay identical to existing native subprocess transports.
fn rpc(comptime T: type, dispatcher: *dispatcher_mod.StdioDispatcher, alloc: Allocator, method: []const u8, params: anytype, options: dispatcher_mod.RequestOptions) !std.json.Parsed(Reply(T)) {
    const id = try dispatcher.reserveRequestId();
    const body = try encode(alloc, id, method, params);
    defer alloc.free(body);
    const frame = try dispatcher.request(alloc, id, body, protocol.max_models_bytes, options);
    defer alloc.free(frame);
    return parse_reply(T, alloc, id, frame);
}

/// Bindings materialize only for the admitted stream, never in catalog discovery or prepare.
fn resolved_headers(alloc: Allocator, configured: ?std.json.Value, session_id: ?[]const u8) !std.json.Parsed(std.json.Value) {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const owned = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(owned);
    var values: std.json.ObjectMap = .empty;
    if (configured) |headers| {
        var fields = headers.object.iterator();
        while (fields.next()) |field| {
            const value = field.value_ptr.*;
            const text = if (value == .string) value.string else blk: {
                const source = value.object.get("source").?.string;
                if (std.mem.eql(u8, source, "session_id")) break :blk session_id orelse return error.ExtensionHeaderUnavailable;
                break :blk io_mod.getenv(value.object.get("name").?.string) orelse return error.ExtensionHeaderUnavailable;
            };
            if (text.len > max_header_value_bytes) return error.ExtensionHeaderInvalid;
            for (text) |byte| if (std.ascii.isControl(byte) or byte == terminal_delete_byte) return error.ExtensionHeaderInvalid;
            try values.put(arena.allocator(), field.key_ptr.*, .{ .string = text });
        }
    }
    owned.* = arena;
    return .{ .arena = owned, .value = .{ .object = values } };
}
