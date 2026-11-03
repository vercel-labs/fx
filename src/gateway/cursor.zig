//! The built-in `cursor` provider (D200-D204): Cursor's agent service, as
//! proto's `providers/cursor.ts` speaks it, with proto-fx running every tool.
//!
//! Wire contract (agent.v1, protobuf over Connect):
//!
//! - Auth: `Authorization: Bearer <access JWT>`, plus `x-ghost-mode: true`,
//!   `x-cursor-client-version`, `x-cursor-client-type: cli` and a fresh
//!   `x-request-id`. The JWT refreshes five minutes before its `exp` with
//!   `POST /auth/exchange_user_api_key`, `Authorization: Bearer <refresh token
//!   or API key>`, body `{}`, reply `{accessToken, refreshToken?}`.
//! - Run: proto opens the bidirectional `AgentService/Run` over HTTP/2.
//!   proto-fx speaks HTTP/1.1 only, so it uses the same service's
//!   `AgentService/RunSSE` (D201): the request body is one Connect envelope
//!   holding `BidiRequestId{request_id}`, and the response streams Connect
//!   envelopes of `AgentServerMessage`. Each client `AgentClientMessage` goes
//!   up as a unary `aiserver.v1.BidiService/BidiAppend` with
//!   `{data: hex(message), request_id: {request_id}, append_seqno}`, in
//!   order from 0. The first is the `run_request`.
//! - Envelope: flag byte, big-endian u32 length, message. Flag 0x02 ends the
//!   stream with a JSON `{"error":{"code","message"}}` or `{}`.
//! - During the run Cursor asks for the request context (rules and MCP tool
//!   definitions), for blobs by SHA-256 id (`kv get_blob`), stores blobs
//!   (`kv set_blob`), and calls tools through exec messages; the client
//!   answers each, and sends a heartbeat every five seconds.
//! - The turn ends with `interaction_update.turn_ended`, which carries the
//!   token counts.
//!
//! External tool handoff (D203): proto-fx's tools are advertised as MCP
//! tools. An MCP exec is answered with proto's handoff text, so the model
//! ends its turn; the call goes back to proto-fx's loop as an ordinary tool
//! call, and its result reaches Cursor in the next request's history, which
//! ends in a `resume_action`. Cursor's own tools are refused.
//!
//! The HTTP/1.1 RunSSE and BidiAppend path has been checked only against a
//! scripted local server, not the real service.
const std = @import("std");
const pb = @import("cursor_protobuf.zig");
const msg = @import("cursor_messages.zig");
const cursor_request = @import("cursor_request.zig");
const reducer_mod = @import("cursor_stream.zig");
const cursor_models = @import("cursor_models.zig");
const cursor_catalog = @import("cursor_catalog.zig");
const chat_completions = @import("chat_completions.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const client_mod = @import("client.zig");
const wire = @import("claude_agent_wire.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const provider_keys = @import("../core/auth/provider_keys.zig");
const credentials = @import("../core/auth/credentials.zig");
const cursor_oauth = @import("../core/auth/cursor_oauth.zig");
const secret = @import("../core/auth/secret.zig");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const Allocator = std.mem.Allocator;

pub const provider_id = cursor_oauth.provider_id;
pub const client_version = "cli-2026.07.23-e383d2b";
const run_path = "/agent.v1.AgentService/RunSSE";
const append_path = "/aiserver.v1.BidiService/BidiAppend";
const refresh_path = "/auth/exchange_user_api_key";
const heartbeat_interval_ms: i64 = 5_000;
const max_frame_bytes = 32 * 1024 * 1024;
const max_reply_bytes = 1024 * 1024;
const conversation_cache_limit = 8;

const ConversationCacheEntry = struct {
    used: bool = false,
    base_hash: [32]u8 = @splat(0),
    conversation_id: [36]u8 = @splat(0),
    successful: bool = false,
    age: u64 = 0,
};

var conversation_mutex: std.Io.Mutex = .init;
var conversation_cache: [conversation_cache_limit]ConversationCacheEntry = @splat(.{});
var conversation_cache_age: u64 = 0;

pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .title_model = definition.reviewer_model orelse cursor_models.small_model,
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build },
        .model_catalog = model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = chat_completions.fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

/// Whether `definition` is the built-in `cursor` provider rather than a
/// user's own definition that shares the id.
pub fn owns(definition: *const definitions.Definition) bool {
    return definition.preset and std.mem.eql(u8, definition.id, provider_id);
}

fn model_catalog_provider(definition: *const definitions.Definition) model_catalog.Provider {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .context = context,
        .fetch_fn = fetch_catalog,
        .refresh_on_seed = true,
        .lookup_capabilities_fn = chat_completions.lookup_capabilities,
        .provider_id = chat_completions.bound_identity(definition),
    };
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    const definition = definition_at(raw);
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    return cursor_catalog.fetch(alloc, definition.base_url, input.access, client_version, input);
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

/// The packed request: run message, request context and blobs.
pub fn build(_: ?*anyopaque, alloc: Allocator, request: streams.RequestData) anyerror![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const built = try cursor_request.build(arena, request, .{
        .model = wireModel(request),
        .conversation_id = &conversationId(request.session_id),
    });
    return cursor_request.pack(alloc, built);
}

fn wireModel(request: streams.RequestData) cursor_request.Model {
    const effort_value = request.provider_options.reasoning;
    const effort: ?[]const u8 = if (effort_value) |*value| value.label() else null;
    const routed = cursor_models.route(request.model, effort);
    const discovered = routed.wire_id;
    var normalized = normalizedModelId(request.model, routed.wire_id);
    var inferred_effort: ?[]const u8 = null;
    if (normalized == null and std.mem.eql(u8, routed.wire_id, request.model)) {
        if (splitDiscoveredEffort(request.model)) |split| {
            normalized = split.base_id;
            inferred_effort = split.effort;
        }
    }
    const selected_effort = if (effort) |value| value else inferred_effort;
    const listed = cursor_models.find(request.model);
    return .{
        .id = request.model,
        .wire_id = routed.wire_id,
        .name = if (listed) |model| model.name else request.model,
        .max_mode = if (normalized != null) routed.max_mode else cursor_models.maxModeTier(request.model),
        .normalized_id = normalized,
        .effort_parameter = if (normalized != null) selected_effort else null,
        .fallback_wire_id = if (normalized != null and selected_effort != null) discovered else null,
        .disable_fast = std.mem.eql(u8, request.model, "composer-2.5"),
    };
}

const DiscoveredEffort = struct { base_id: []const u8, effort: []const u8 };

fn splitDiscoveredEffort(model_id: []const u8) ?DiscoveredEffort {
    if (!std.mem.startsWith(u8, model_id, "gpt-")) return null;
    const suffixes = [_]struct { suffix: []const u8, effort: []const u8 }{
        .{ .suffix = "-extra-high", .effort = "xhigh" },
        .{ .suffix = "-minimal", .effort = "minimal" },
        .{ .suffix = "-medium", .effort = "medium" },
        .{ .suffix = "-high", .effort = "high" },
        .{ .suffix = "-low", .effort = "low" },
        .{ .suffix = "-xhigh", .effort = "xhigh" },
        .{ .suffix = "-max", .effort = "max" },
        .{ .suffix = "-none", .effort = "auto" },
    };
    for (suffixes) |candidate| if (std.mem.endsWith(u8, model_id, candidate.suffix)) {
        return .{ .base_id = model_id[0 .. model_id.len - candidate.suffix.len], .effort = candidate.effort };
    };
    return null;
}

/// A routed Cursor tier can use the normalized base model plus a reasoning
/// parameter. Keep provider-specific `thinking-*` ids on their discovered
/// wire name; only routes whose base is the selected model normalize.
fn normalizedModelId(model_id: []const u8, wire_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, model_id, wire_id)) return null;
    const model_fast = std.mem.endsWith(u8, model_id, "-fast");
    const model_base = if (model_fast) model_id[0 .. model_id.len - 5] else model_id;
    // Cursor's normalized effort fields are an OpenAI model contract. Other
    // families (notably GLM) keep their discovered thinking wire id.
    if (!std.mem.startsWith(u8, model_base, "gpt-")) return null;
    var wire_base = wire_id;
    if (std.mem.endsWith(u8, wire_base, "-fast")) wire_base = wire_base[0 .. wire_base.len - 5];
    for ([_][]const u8{ "-extra-high", "-minimal", "-low", "-medium", "-high", "-xhigh", "-max", "-none" }) |suffix| {
        if (std.mem.endsWith(u8, wire_base, suffix)) {
            wire_base = wire_base[0 .. wire_base.len - suffix.len];
            break;
        }
    }
    if (!std.mem.eql(u8, wire_base, model_base)) return null;
    return model_id;
}

fn baseConversationId(session_id: ?[]const u8) ?[36]u8 {
    if (session_id) |id| return wire.derivedUuid(id, 0xc0);
    return null;
}

fn conversationHash(base: [36]u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&base, &digest, .{});
    return digest;
}

fn findConversationEntry(hash: [32]u8) ?usize {
    for (conversation_cache, 0..) |entry, index| {
        if (entry.used and std.mem.eql(u8, &entry.base_hash, &hash)) return index;
    }
    return null;
}

fn touchConversationEntry(index: usize) void {
    conversation_cache_age +%= 1;
    conversation_cache[index].age = conversation_cache_age;
}

fn conversationId(session_id: ?[]const u8) [36]u8 {
    if (session_id) |id| {
        const base = wire.derivedUuid(id, 0xc0);
        const hash = conversationHash(base);
        conversation_mutex.lockUncancelable(io_mod.getIo());
        defer conversation_mutex.unlock(io_mod.getIo());
        if (findConversationEntry(hash)) |index| {
            touchConversationEntry(index);
            return conversation_cache[index].conversation_id;
        }
        return base;
    }
    var random: [16]u8 = undefined;
    io_mod.getIo().random(&random);
    return wire.derivedUuid(&random, 0xc1);
}

/// Records a successful turn on a rotated conversation so a later bare
/// resource exhaustion may rotate it once more without hiding account quota.
fn markConversationSuccess(base: [36]u8, conversation_id: []const u8) void {
    const hash = conversationHash(base);
    conversation_mutex.lockUncancelable(io_mod.getIo());
    defer conversation_mutex.unlock(io_mod.getIo());
    const index = findConversationEntry(hash) orelse return;
    if (std.mem.eql(u8, &conversation_cache[index].conversation_id, conversation_id)) {
        conversation_cache[index].successful = true;
        touchConversationEntry(index);
    }
}

/// Rotates one poisoned conversation. A rotated id can rotate again only
/// after a successful turn, matching Cursor's account-exhaustion safety.
fn rotateConversation(base: [36]u8, conversation_id: []const u8) ?[36]u8 {
    const hash = conversationHash(base);
    conversation_mutex.lockUncancelable(io_mod.getIo());
    defer conversation_mutex.unlock(io_mod.getIo());
    const existing = findConversationEntry(hash);
    if (existing) |index| {
        if (!std.mem.eql(u8, &conversation_cache[index].conversation_id, conversation_id) or !conversation_cache[index].successful) return null;
    }
    var slot: usize = 0;
    if (existing) |index| {
        slot = index;
    } else {
        var oldest: u64 = std.math.maxInt(u64);
        for (conversation_cache, 0..) |entry, index| {
            if (!entry.used) {
                slot = index;
                oldest = 0;
                break;
            }
            if (entry.age < oldest) {
                oldest = entry.age;
                slot = index;
            }
        }
    }
    var random: [16]u8 = undefined;
    io_mod.getIo().random(&random);
    const rotated = wire.derivedUuid(&random, 0xc2);
    conversation_cache[slot] = .{ .used = true, .base_hash = hash, .conversation_id = rotated, .successful = false };
    touchConversationEntry(slot);
    return rotated;
}

pub fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) anyerror!classifier.ParseOutcome {
    return chat_completions.review_with(raw, alloc, input, request, .{ .build_fn = build, .stream_fn = stream });
}

fn failed(alloc: Allocator, kind: streams.FailureKind, detail: []const u8) !streams.Result {
    return .{ .failed = .{ .kind = kind, .detail = try alloc.dupe(u8, detail), .ownership = .owned } };
}

const not_signed_in = "Cursor is not signed in. Run /login cursor, or set " ++ cursor_oauth.api_key_env ++ ".";

const RunOutcome = struct {
    result: streams.Result,
    saw_progress_or_side_effect: bool = false,
    saw_token_delta: bool = false,
};

fn packedConversationId(client_message: []const u8) !?[]const u8 {
    const run_bytes = (try pb.findBytes(client_message, 1)) orelse return null;
    return pb.findBytes(run_bytes, 5);
}

fn startsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return needle.len <= haystack.len and std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start <= haystack.len - needle.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn modelNotFound(result: streams.Result) bool {
    const detail = switch (result) {
        .failed => |failure| failure.detail orelse return false,
        .completed => return false,
    };
    return startsAsciiIgnoreCase(detail, "Connect error not_found:") or
        startsAsciiIgnoreCase(detail, "gRPC error 5:");
}

fn resourceExhausted(result: streams.Result) bool {
    const detail = switch (result) {
        .failed => |failure| failure.detail orelse return false,
        .completed => return false,
    };
    return containsAsciiIgnoreCase(detail, "resource_exhausted") or
        containsAsciiIgnoreCase(detail, "resource-exhausted") or
        containsAsciiIgnoreCase(detail, "resource exhausted");
}

pub fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) anyerror!streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    var payload_owned: ?[]u8 = null;
    var payload = request.prepared_request_body orelse blk: {
        const fresh = try build(raw, alloc, request.data());
        payload_owned = fresh;
        break :blk fresh;
    };
    defer if (payload_owned) |owned| alloc.free(owned);
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    debug_trace.logf("gateway", "cursor_payload_received len={d} magic={}", .{ payload.len, std.mem.startsWith(u8, payload, "proto-fx-cursor-run/1\n") });
    var built = try cursor_request.unpack(arena, payload);
    debug_trace.logf("gateway", "cursor_payload_unpacked run_len={d}", .{built.run_message.len});

    // A prepared body can outlive a zero-token rotation. Rebuild from the
    // current request context rather than migrating its mid-turn state/blob
    // cache into the fresh conversation id. Normal prepared bodies already
    // carry the deterministic base id and avoid this allocation.
    if (request.session_id != null) {
        const desired = conversationId(request.session_id);
        const current = try packedConversationId(built.run_message);
        if (current == null or !std.mem.eql(u8, current.?, &desired)) {
            debug_trace.logf("gateway", "cursor_payload_rewrite current_present={} current_len={d} desired_len={d} prepared={}", .{ current != null, if (current) |value| value.len else 0, desired.len, request.prepared_request_body != null });
            if (request.prepared_request_body != null) {
                const fresh = try build(raw, alloc, request.data());
                payload_owned = fresh;
                payload = fresh;
                built = try cursor_request.unpack(arena, payload);
            } else {
                built.run_message = try cursor_request.rewriteRun(arena, built.run_message, null, &desired, false);
            }
        }
    }
    const base_conversation = baseConversationId(request.session_id);
    var conversation = try packedConversationId(built.run_message);
    var refreshed = false;
    var fallback_attempted = false;
    while (true) {
        const access = (accessToken(alloc, definition.base_url, refreshed) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.CursorNotSignedIn => return failed(alloc, .unauthorized, not_signed_in),
            else => {
                const detail = try alloc.print("Cursor token refresh failed ({s}). Run /login cursor to sign in again.", .{@errorName(err)});
                return .{ .failed = .{ .kind = .unauthorized, .detail = detail, .ownership = .owned } };
            },
        });
        defer secret.zeroAndFree(alloc, access);
        const outcome = run(alloc, definition, request, &built, access) catch |err| {
            request.attempt_evidence.network_failure = client_mod.networkFailureEvidence(err, request.delivery.load());
            if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
            return err;
        };
        var result = outcome.result;

        // The normalized effort request is deliberately retried with Cursor's
        // discovered wire id only when no output, tool, or context side effect
        // has escaped. This mirrors proto's fallback before any visible event.
        if (!fallback_attempted and !request.cancel_flag.load(.seq_cst) and !outcome.saw_progress_or_side_effect and modelNotFound(result)) {
            if (wireModel(request.data()).fallback_wire_id) |fallback| {
                const current_model = try packedModelId(built.run_message);
                if (current_model == null or !std.mem.eql(u8, fallback, current_model.?)) {
                    result.deinit(alloc);
                    built.run_message = try cursor_request.rewriteRun(arena, built.run_message, fallback, null, true);
                    fallback_attempted = true;
                    conversation = try packedConversationId(built.run_message);
                    continue;
                }
            }
        }

        // A bare zero-token resource exhaustion poisons this conversation id,
        // not the account. Remember one fresh id for the next attempt; a
        // rotated id may rotate again only after completing a turn.
        if (base_conversation) |base| if (!outcome.saw_token_delta and resourceExhausted(result)) {
            if (conversation) |current| _ = rotateConversation(base, current);
        };
        if (result == .completed) if (base_conversation) |base| if (conversation) |current| markConversationSuccess(base, current);

        // An access token the server refuses gets one forced refresh.
        if (result == .failed and result.failed.kind == .unauthorized and !refreshed and !request.cancel_flag.load(.seq_cst)) {
            result.deinit(alloc);
            refreshed = true;
            continue;
        }
        return result;
    }
}

fn packedModelId(client_message: []const u8) !?[]const u8 {
    const run_bytes = (try pb.findBytes(client_message, 1)) orelse return null;
    const details = (try pb.findBytes(run_bytes, 3)) orelse return null;
    return pb.findBytes(details, 1);
}

/// A usable access token, refreshing and saving the credential when it is
/// missing, expiring, or `force` is set. Caller owns and zeroes it.
pub fn accessToken(alloc: Allocator, base_url: []const u8, force: bool) ![]u8 {
    const saved = try provider_keys.load(alloc, provider_id);
    defer if (saved) |value| secret.zeroAndFree(alloc, value);
    const stored: []const u8 = saved orelse io_mod.getenv(cursor_oauth.api_key_env) orelse return error.CursorNotSignedIn;
    if (stored.len == 0) return error.CursorNotSignedIn;
    const credential = cursor_oauth.parse(stored);
    const now_seconds = @divFloor(io_mod.milliTimestamp(), 1000);
    if (!force and !cursor_oauth.needsRefresh(credential.access, now_seconds)) return alloc.dupe(u8, credential.access);
    if (credential.refresh.len == 0) return error.CursorNotSignedIn;
    const renewed = try exchange(alloc, base_url, credential.refresh);
    defer secret.zeroAndFree(alloc, renewed);
    // An environment key is exchanged per request; a saved one is replaced.
    if (saved != null) provider_keys.save(alloc, provider_id, renewed) catch |err| {
        debug_trace.logf("gateway", "cursor_credential_save_failed err={s}", .{@errorName(err)});
    };
    return alloc.dupe(u8, cursor_oauth.parse(renewed).access);
}

/// Exchanges a refresh token or API key for a new saved-form credential.
fn exchange(alloc: Allocator, base_url: []const u8, refresh: []const u8) ![]u8 {
    const url = try std.mem.concat(alloc, u8, &.{ std.mem.trimEnd(u8, base_url, "/"), refresh_path });
    defer alloc.free(url);
    const authorization = try alloc.print("Bearer {s}", .{refresh});
    defer secret.zeroAndFree(alloc, authorization);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(body.writer.buffer, 0);
        body.deinit();
    }
    const status = (try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = "{}",
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" }, .authorization = .{ .override = authorization } },
        .response_writer = &body.writer,
    })).status;
    if (status != .ok) return error.CursorTokenRefreshRejected;
    return cursor_oauth.credentialFromReply(alloc, body.written(), refresh);
}

const Session = struct {
    alloc: Allocator,
    base_url: []const u8,
    request_id: [36]u8,
    authorization: []const u8,
    appends: std.http.Client,
    seqno: u64 = 0,
    last_send_ms: i64 = 0,

    fn headers(self: *const Session, buffer: *[4]std.http.Header) []const std.http.Header {
        buffer.* = .{
            .{ .name = "x-ghost-mode", .value = "true" },
            .{ .name = "x-cursor-client-version", .value = client_version },
            .{ .name = "x-cursor-client-type", .value = "cli" },
            .{ .name = "x-request-id", .value = &self.request_id },
        };
        return buffer;
    }

    /// Sends one AgentClientMessage as the next BidiAppend.
    fn append(self: *Session, message: []const u8) !void {
        const alloc = self.alloc;
        var inner = pb.Writer.init(alloc);
        defer inner.deinit();
        try inner.stringField(1, &self.request_id);
        var body = pb.Writer.init(alloc);
        defer body.deinit();
        const hex = try alloc.alloc(u8, message.len * 2);
        defer alloc.free(hex);
        const digits = "0123456789abcdef";
        for (message, 0..) |byte, index| {
            hex[index * 2] = digits[byte >> 4];
            hex[index * 2 + 1] = digits[byte & 0x0f];
        }
        try body.stringField(1, hex);
        try body.bytesField(2, inner.bytes.items);
        if (self.seqno != 0) try body.uintField(3, self.seqno);
        const url = try std.mem.concat(alloc, u8, &.{ self.base_url, append_path });
        defer alloc.free(url);
        var header_buffer: [4]std.http.Header = undefined;
        var extra: [5]std.http.Header = undefined;
        @memcpy(extra[0..4], self.headers(&header_buffer));
        extra[4] = .{ .name = "connect-protocol-version", .value = "1" };
        var reply: std.Io.Writer.Allocating = .init(alloc);
        defer reply.deinit();
        const status = (try self.appends.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body.bytes.items,
            .headers = .{ .content_type = .{ .override = "application/proto" }, .authorization = .{ .override = self.authorization }, .accept_encoding = .omit },
            .extra_headers = &extra,
            .response_writer = &reply.writer,
        })).status;
        if (status != .ok) {
            debug_trace.logf("gateway", "cursor_append_rejected status={d} seqno={d}", .{ @backingInt(status), self.seqno });
            return if (status == .unauthorized) error.CursorUnauthorized else error.CursorAppendRejected;
        }
        self.seqno += 1;
        self.last_send_ms = io_mod.milliTimestamp();
    }
};

fn emitEvent(context: *anyopaque, event: streams.Event) void {
    const sink: *const streams.EventSink = @ptrCast(@alignCast(context));
    sink.emit(event);
}

/// One RunSSE stream for the packed request.
fn run(alloc: Allocator, definition: *const definitions.Definition, request: streams.ModelRequest, built: *cursor_request.Built, access: []const u8) !RunOutcome {
    const base_url = std.mem.trimEnd(u8, definition.base_url, "/");
    const authorization = try alloc.print("Bearer {s}", .{access});
    defer secret.zeroAndFree(alloc, authorization);
    var request_seed: [16]u8 = undefined;
    io_mod.getIo().random(&request_seed);
    var session: Session = .{
        .alloc = alloc,
        .base_url = base_url,
        .request_id = wire.derivedUuid(&request_seed, 0),
        .authorization = authorization,
        .appends = .{ .allocator = alloc, .io = io_mod.getIo() },
    };
    defer session.appends.deinit();

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const url = try std.mem.concat(alloc, u8, &.{ base_url, run_path });
    defer alloc.free(url);
    const uri = try std.Uri.parse(url);
    var header_buffer: [4]std.http.Header = undefined;
    var extra: [6]std.http.Header = undefined;
    @memcpy(extra[0..4], session.headers(&header_buffer));
    extra[4] = .{ .name = "connect-protocol-version", .value = "1" };
    extra[5] = .{ .name = "accept", .value = "application/connect+proto" };
    var opened = SseOpen{ .client = &client, .uri = uri, .authorization = authorization, .extra_headers = &extra };
    try request.admission.admit();
    var connection = try client_mod.runBoundedHttpOperation(client_mod.OpenedPost, alloc, request.cancel_flag, phaseDeadline(30_000, request.deadline), &opened);
    defer connection.deinit(alloc);
    const http = &connection.request.?;
    var watch: client_mod.ConnectionWatch = .init(.{ .timeout_ms = 120_000, .stall_timeout_ms = client_mod.ConnectionWatch.bodyStallTimeoutMs(request.deadline) });
    defer watch.stop();
    if (http.connection) |stream_connection| try watch.start(request.cancel_flag, request.deadline, stream_connection.stream_writer.stream);
    if (watch.armHead()) |err| return err;

    var id_message = pb.Writer.init(alloc);
    defer id_message.deinit();
    try id_message.stringField(1, &session.request_id);
    const body = try pb.envelope(alloc, 0, id_message.bytes.items);
    defer alloc.free(body);
    http.transfer_encoding = .{ .content_length = body.len };
    var send_buffer: [1024]u8 = undefined;
    request.delivery.markPossiblySent();
    var writer = try http.sendBodyUnflushed(&send_buffer);
    try writer.writer.writeAll(body);
    try writer.end();
    if (http.connection) |stream_connection| try stream_connection.flush();
    // The run request goes up once the stream is open.
    session.append(built.run_message) catch |err| return .{ .result = try appendFailure(alloc, err) };

    var response = http.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        const detail = reader.allocRemaining(alloc, .limited(max_reply_bytes)) catch try alloc.dupe(u8, "Cursor refused the request");
        return .{ .result = .{ .failed = .{ .kind = chat_completions.failure_kind(response.head.status), .detail = detail, .ownership = .owned } } };
    }

    var frames: pb.FrameReader = .{ .alloc = alloc, .source = reader, .max_message_bytes = max_frame_bytes };
    defer frames.deinit();
    var state = reducer_mod.Reducer.init(alloc, request.data(), &built.blobs, built.request_context, limits(request));
    defer state.deinit();
    var frame_arena: std.heap.ArenaAllocator = .init(alloc);
    defer frame_arena.deinit();
    const progress = watch.progress();
    while (!state.turn_ended) {
        const frame = (frames.next() catch |err| return watch.failure(err)) orelse break;
        progress.mark_fn(progress.context);
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (frame.endStream()) {
            const failure = try pb.parseEndStream(frame_arena.allocator(), frame.message);
            if (failure) |value| return .{
                .result = try endStreamFailure(alloc, value),
                .saw_progress_or_side_effect = state.saw_progress_or_side_effect,
                .saw_token_delta = state.saw_token_delta,
            };
            break;
        }
        _ = frame_arena.reset(.retain_capacity);
        const scratch = frame_arena.allocator();
        const message = try msg.decodeServerMessage(scratch, frame.message);
        try state.accept(scratch, message, request.events);
        for (state.pendingReplies()) |reply_message| session.append(reply_message) catch |err| return .{
            .result = try appendFailure(alloc, err),
            .saw_progress_or_side_effect = state.saw_progress_or_side_effect,
            .saw_token_delta = state.saw_token_delta,
        };
        state.freeReplies();
        if (io_mod.milliTimestamp() - session.last_send_ms >= heartbeat_interval_ms) {
            const beat = try msg.heartbeatMessage(alloc);
            defer alloc.free(beat);
            session.append(beat) catch |err| return .{
                .result = try appendFailure(alloc, err),
                .saw_progress_or_side_effect = state.saw_progress_or_side_effect,
                .saw_token_delta = state.saw_token_delta,
            };
        }
    }
    if (!state.turn_ended) return .{
        .result = try failed(alloc, .provider_error, "Cursor stream ended before turnEnded"),
        .saw_progress_or_side_effect = state.saw_progress_or_side_effect,
        .saw_token_delta = state.saw_token_delta,
    };
    if (watch.finish()) |err| if (err != error.EndOfStream) {
        // The turn is complete; a watch that fired after it changes nothing.
        debug_trace.logf("gateway", "cursor_watch_after_turn err={s}", .{@errorName(err)});
    };
    const saw_progress_or_side_effect = state.saw_progress_or_side_effect;
    const saw_token_delta = state.saw_token_delta;
    return .{
        .result = try state.finish(),
        .saw_progress_or_side_effect = saw_progress_or_side_effect,
        .saw_token_delta = saw_token_delta,
    };
}

fn limits(request: streams.ModelRequest) reducer_mod.Limits {
    var value: reducer_mod.Limits = .{};
    if (request.content_capture_limit) |limit| value.content_bytes = @min(limit, value.content_bytes);
    return value;
}

fn appendFailure(alloc: Allocator, err: anyerror) !streams.Result {
    return switch (err) {
        error.OutOfMemory => err,
        error.CursorUnauthorized => failed(alloc, .unauthorized, "Cursor refused the access token."),
        error.CursorAppendRejected => failed(alloc, .provider_error, "Cursor refused a message on the run stream."),
        else => err,
    };
}

/// Maps a Connect error code to a failure kind, keeping proto's message.
fn endStreamFailure(alloc: Allocator, failure: pb.EndStreamError) !streams.Result {
    const table = [_]struct { []const u8, streams.FailureKind }{
        .{ "unauthenticated", .unauthorized },      .{ "permission_denied", .forbidden },
        .{ "resource_exhausted", .rate_limited },   .{ "invalid_argument", .invalid_request },
        .{ "not_found", .invalid_request },         .{ "unavailable", .unavailable },
        .{ "deadline_exceeded", .gateway_timeout }, .{ "internal", .server_error },
    };
    var kind: streams.FailureKind = .provider_error;
    for (table) |entry| if (std.mem.eql(u8, entry[0], failure.code)) {
        kind = entry[1];
    };
    const detail = try alloc.print("Connect error {s}: {s}", .{ failure.code, failure.message });
    return .{ .failed = .{ .kind = kind, .detail = detail, .ownership = .owned } };
}

fn phaseDeadline(milliseconds: i64, caller: ?std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const phase = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    if (caller) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, phase)) return deadline;
    return phase;
}

/// Opens the RunSSE request; the body is sent by the caller.
const SseOpen = struct {
    client: *std.http.Client,
    uri: std.Uri,
    authorization: []const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *SseOpen) !client_mod.OpenedPost {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/connect+proto" },
                .accept_encoding = .omit,
                .authorization = .{ .override = self.authorization },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

test "Cursor normalizes discovered GPT effort routes" {
    const request: streams.RequestData = .{
        .model = "gpt-5.7-high",
        .messages = &.{},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const routed = wireModel(request);
    try std.testing.expectEqualStrings("gpt-5.7-high", routed.wire_id);
    try std.testing.expectEqualStrings("gpt-5.7", routed.normalized_id.?);
    try std.testing.expectEqualStrings("high", routed.effort_parameter.?);
    try std.testing.expectEqualStrings("gpt-5.7-high", routed.fallback_wire_id.?);
}

test "Cursor recovery classifiers gate model fallback and conversation rotation" {
    var not_found = streams.Result{ .failed = .{
        .kind = .invalid_request,
        .detail = try std.testing.allocator.dupe(u8, "Connect error not_found: model"),
        .ownership = .owned,
    } };
    defer not_found.deinit(std.testing.allocator);
    try std.testing.expect(modelNotFound(not_found));
    var exhausted = streams.Result{ .failed = .{
        .kind = .rate_limited,
        .detail = try std.testing.allocator.dupe(u8, "Connect error resource exhausted: conversation"),
        .ownership = .owned,
    } };
    defer exhausted.deinit(std.testing.allocator);
    try std.testing.expect(resourceExhausted(exhausted));

    const base = baseConversationId("cursor-rotation-proof-2026").?;
    const first = rotateConversation(base, &base).?;
    try std.testing.expect(rotateConversation(base, &first) == null);
    markConversationSuccess(base, &first);
    const second = rotateConversation(base, &first).?;
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "Cursor catalog uses provider-keyed access credential" {
    const access = credentials.catalogAccessForCredential(.stored_key, "access-token|refresh-token", null);
    const token = (try cursor_catalog.catalogAccessToken(std.testing.allocator, access)).?;
    defer secret.zeroAndFree(std.testing.allocator, token);
    try std.testing.expectEqualStrings("access-token", token);

    const api_key_access = credentials.catalogAccessForCredential(.stored_key, "api-key", null);
    const api_key = (try cursor_catalog.catalogAccessToken(std.testing.allocator, api_key_access)).?;
    defer secret.zeroAndFree(std.testing.allocator, api_key);
    try std.testing.expectEqualStrings("api-key", api_key);
}

test {
    _ = @import("cursor_protobuf.zig");
    _ = @import("cursor_messages.zig");
    _ = @import("cursor_models.zig");
    _ = @import("cursor_tests.zig");
    _ = @import("../core/auth/cursor_oauth.zig");
}
