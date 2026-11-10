//! Sends requests to a custom model connection
//! (`src/core/config/configured_provider.zig`) for every protocol it can
//! speak: the credential and header rules, the connection's own bounds on how
//! long a request may wait, the masking of secrets in a server's error text,
//! and the request for the server's model list. Each protocol's adapter
//! builds the body and reads the reply.
const std = @import("std");
const client_mod = @import("client.zig");
const chat_codec = @import("chat_completions_protocol.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const io = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const request_deadlines = @import("request_deadlines.zig");
const sse = @import("sse.zig");
const Allocator = std.mem.Allocator;

/// fx's own bounds, for a connection whose settings name none.
pub const default_connect_ms: u32 = 30_000;
pub const default_first_response_ms: u32 = 120_000;
/// How long an error body or a model list may take to arrive.
const short_reply_ms: u32 = 30_000;
const max_error_bytes = 64 * 1024;
const max_secret_bytes = 16 * 1024;
/// The largest model list fx reads. A router lists thousands of models.
pub const max_models_bytes = 4 * 1024 * 1024;

/// Reads a successful streamed reply. `progress` is told about each event.
pub const ConsumeFn = *const fn (alloc: Allocator, reader: *std.Io.Reader, request: streams.ModelRequest, progress: ?sse.Progress) anyerror!streams.Result;

/// The connection's extra headers with their values read from the
/// environment, and the header its protocol needs. Free with `deinit`, which
/// wipes the values.
pub const Headers = struct {
    list: []std.http.Header = &.{},
    /// How many entries of `list` own a value from the environment. They
    /// come first.
    owned: usize = 0,
    /// The allocation `list` is a prefix of.
    storage: []std.http.Header = &.{},

    /// Fails with `MissingConfiguredProviderHeader` when a header's variable
    /// is unset or empty, and with `InvalidConfiguredProviderHeader` when its
    /// value could not travel in a header.
    pub fn resolve(alloc: Allocator, definition: *const definitions.Definition) !Headers {
        const list = try alloc.alloc(std.http.Header, definition.headers.len + 1);
        var headers: Headers = .{ .list = list[0..0], .storage = list };
        errdefer {
            for (list[0..headers.owned]) |header| secret.zeroAndFree(alloc, @constCast(header.value));
            alloc.free(list);
        }
        var version_given = false;
        for (definition.headers) |header| {
            const value = io.getenv(header.env) orelse return error.MissingConfiguredProviderHeader;
            if (value.len == 0) return error.MissingConfiguredProviderHeader;
            if (value.len > max_secret_bytes) return error.InvalidConfiguredProviderHeader;
            for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidConfiguredProviderHeader;
            list[headers.owned] = .{ .name = header.name, .value = try alloc.dupe(u8, value) };
            headers.owned += 1;
            version_given = version_given or std.ascii.eqlIgnoreCase(header.name, "anthropic-version");
        }
        var count = headers.owned;
        if (definition.protocol == .@"anthropic-messages" and !version_given) {
            list[count] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            count += 1;
        }
        headers.list = list[0..count];
        return headers;
    }

    pub fn deinit(self: *Headers, alloc: Allocator) void {
        for (self.list[0..self.owned]) |header| secret.zeroAndFree(alloc, @constCast(header.value));
        alloc.free(self.storage);
        self.* = .{};
    }

    /// `detail` with the bearer token and every header value replaced by
    /// asterisks, in the forms a server may quote them. Takes `detail` and
    /// returns owned text.
    fn mask(self: *const Headers, alloc: Allocator, detail: []u8, token: ?[]const u8) Allocator.Error![]u8 {
        var masked = detail;
        if (token) |value| masked = try maskOne(alloc, masked, value);
        for (self.list[0..self.owned]) |header| masked = try maskOne(alloc, masked, header.value);
        return masked;
    }
};

fn maskOne(alloc: Allocator, detail: []u8, value: []const u8) Allocator.Error![]u8 {
    defer alloc.free(detail);
    return chat_codec.redact_error_detail(alloc, detail, value);
}

fn expired(deadline: std.Io.Clock.Timestamp) bool {
    return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, deadline);
}

fn phaseDeadline(milliseconds: i64, caller: ?std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const phase = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    if (caller) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, phase)) return deadline;
    return phase;
}

/// The bearer token `request` carries, checked against the connection's auth.
/// An adapter calls this before it builds a body, so a request with the wrong
/// credential fails on that and not on what the body would have held.
pub fn tokenOf(definition: *const definitions.Definition, request: streams.ModelRequest) !?[]const u8 {
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    if (token) |value| {
        if (value.len > max_secret_bytes) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (definition.auth) {
        .none => if (token != null) return error.UnexpectedConfiguredProviderCredential,
        .bearer => if (token == null) return error.MissingConfiguredProviderCredential,
    }
    return token;
}

/// Sends `payload` to the connection's request URL and reads the reply with
/// `consume`. A wait that runs out ends this attempt
/// (`tests/tla/configured_provider/ConfiguredDeadlines.tla`); request recovery
/// decides whether to send again.
pub fn send(alloc: Allocator, definition: *const definitions.Definition, request: streams.ModelRequest, payload: []const u8, consume: ConsumeFn) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const token = try tokenOf(definition, request);
    // Before anything is sent: a header that cannot be filled in fails here.
    var headers = try Headers.resolve(alloc, definition);
    defer headers.deinit(alloc);
    // The wait the request is in, so a bound that runs out can name itself.
    var wait: request_deadlines.Wait = .connecting;
    return post(alloc, definition, request, token, &headers, payload, consume, &wait) catch |err| {
        request.attempt_evidence.network_failure = client_mod.networkFailureEvidence(err, request.delivery.load());
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (request.deadline) |deadline| if (expired(deadline)) return error.Timeout;
        if (err == error.Timeout or err == error.StreamStalled) {
            debug_trace.logf("gateway", "event=configured_wait_ran_out connection={s} setting={s} err={s}", .{ definition.id, wait.setting(), @errorName(err) });
        }
        return err;
    };
}

fn post(
    alloc: Allocator,
    definition: *const definitions.Definition,
    request: streams.ModelRequest,
    token: ?[]const u8,
    headers: *const Headers,
    payload: []const u8,
    consume: ConsumeFn,
    wait: *request_deadlines.Wait,
) !streams.Result {
    const url = try definition.request_url(alloc);
    defer alloc.free(url);
    const authorization = if (token) |value| try alloc.print("Bearer {s}", .{value}) else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    const extra = try std.mem.concat(alloc, std.http.Header, &.{ &.{.{ .name = "accept", .value = "text/event-stream" }}, headers.list });
    defer alloc.free(extra);
    try request.admission.admit();
    const timeouts = definition.timeouts;
    var opened = try client_mod.openBoundedPost(request.cancel_flag, phaseDeadline(timeouts.connect_ms orelse default_connect_ms, request.deadline), .{
        .uri = uri,
        .authorization = authorization,
        .extra_headers = extra,
    });
    defer opened.deinit();
    wait.* = .awaiting_head;
    const http = &opened.request;
    var watch: client_mod.ConnectionWatch = .init(.{
        .timeout_ms = timeouts.first_response_ms orelse default_first_response_ms,
        // The connection's own bound holds for every request on it. Without
        // one, a request with a deadline of its own needs no stall window.
        .stall_timeout_ms = if (timeouts.stall_ms) |stall_ms| stall_ms else client_mod.ConnectionWatch.bodyStallTimeoutMs(request.deadline),
    });
    defer watch.stop();
    if (http.connection) |connection| try watch.start(request.cancel_flag, request.deadline, connection.stream_writer.stream);
    // The wait for the first response also bounds sending the request.
    if (watch.armHead()) |err| return err;
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = http.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    wait.* = .streaming;
    if (response.head.status != .ok) {
        // An error body is read under its own bound.
        watch.stop();
        watch = .init(.{ .patient = true, .stall_timeout_ms = std.math.maxInt(i64) });
        if (http.connection) |connection| try watch.start(request.cancel_flag, phaseDeadline(short_reply_ms, request.deadline), connection.stream_writer.stream);
    }
    var retry_after: ?u64 = null;
    var response_headers = response.head.iterateHeaders();
    while (response_headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
        retry_after = std.fmt.parseUnsigned(u64, std.mem.trim(u8, header.value, " \t"), 10) catch null;
        break;
    };
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        var detail = reader.allocRemaining(alloc, .limited(max_error_bytes)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Provider error response exceeded the local limit"),
            else => return err,
        };
        detail = try headers.mask(alloc, detail, token);
        return .{ .failed = .{ .kind = client_mod.httpFailureKind(alloc, .fromHttpStatus(response.head.status), detail), .http_status = response.head.status, .detail = detail, .retry_after_seconds = retry_after, .ownership = .owned } };
    }
    var result = consume(alloc, reader, request, watch.progress()) catch |err| return watch.failure(err);
    if (watch.finish()) |err| {
        result.deinit(alloc);
        return err;
    }
    // A reply that reports its own failure may quote a secret, as an error
    // body may.
    if (result == .failed and result.failed.ownership == .owned) {
        if (result.failed.detail) |detail| {
            result.failed.detail = null;
            result.failed.detail = headers.mask(alloc, @constCast(detail), token) catch |err| {
                result.deinit(alloc);
                return err;
            };
        }
    }
    return result;
}

pub const ModelsFailure = enum {
    cancelled,
    /// The connection's bearer variable, or a header's, is unset.
    credential,
    transport,
    timeout,
    http_status,
    malformed,

    pub fn text(self: ModelsFailure) []const u8 {
        return switch (self) {
            .cancelled => "the request was cancelled",
            .credential => "its key or a header is not set in the environment",
            .transport => "the server could not be reached",
            .timeout => "the server did not answer in time",
            .http_status => "the server refused the request",
            .malformed => "the reply was not a model list",
        };
    }
};

pub const ModelsResult = union(enum) {
    /// Owned ids, in the server's order, without duplicates. Free with `freeIds`.
    ids: std.ArrayList([]u8),
    failure: ModelsFailure,
};

pub fn freeIds(alloc: Allocator, ids: *std.ArrayList([]u8)) void {
    for (ids.items) |id| alloc.free(id);
    ids.deinit(alloc);
}

const ModelsResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *ModelsResponse, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

const ModelsOperation = struct {
    alloc: Allocator,
    url: []const u8,
    authorization: ?[]const u8,
    headers: []const std.http.Header,

    pub fn run(self: *@This()) !ModelsResponse {
        var request_headers: std.http.Client.Request.Headers = .{
            .user_agent = .{ .override = client_mod.user_agent },
            .accept_encoding = .omit,
        };
        if (self.authorization) |value| request_headers.authorization = .{ .override = value };
        const body_buffer = try self.alloc.alloc(u8, max_models_bytes + 1);
        defer self.alloc.free(body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const extra = try std.mem.concat(self.alloc, std.http.Header, &.{ &.{.{ .name = "accept", .value = "application/json" }}, self.headers });
        defer self.alloc.free(extra);
        const result = client_mod.fetchOnOpenJob(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = request_headers,
            .extra_headers = extra,
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.ModelListTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_models_bytes) return error.ModelListTooLarge;
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, body) };
    }
};

/// Asks the connection's server for its model list (`GET {base_url}/models`)
/// with the connection's own key and headers, read from the environment here
/// because a model list request carries no credential of its own. One
/// request, bounded by the connection's wait for a first response; a reply
/// that arrives at the bound loses (`tests/tla/configured_provider/ConfiguredCatalog.tla`
/// RequestSettles, TokenStaysWithItsConnection).
pub fn fetchModelIds(alloc: Allocator, definition: *const definitions.Definition, cancel_flag: ?*std.atomic.Value(bool)) Allocator.Error!ModelsResult {
    var never_cancelled = std.atomic.Value(bool).init(false);
    const cancel = cancel_flag orelse &never_cancelled;
    if (cancel.load(.seq_cst)) return .{ .failure = .cancelled };
    var headers = Headers.resolve(alloc, definition) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .credential },
    };
    defer headers.deinit(alloc);
    var authorization: ?[]u8 = null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    switch (definition.auth) {
        .none => {},
        .bearer => |env| {
            const token = io.getenv(env) orelse return .{ .failure = .credential };
            if (token.len == 0 or token.len > max_secret_bytes) return .{ .failure = .credential };
            for (token) |byte| if (byte <= 0x20 or byte >= 0x7f) return .{ .failure = .credential };
            authorization = try alloc.print("Bearer {s}", .{token});
        },
    }
    const url = try definition.models_url(alloc);
    defer alloc.free(url);
    const bound_ms = definition.timeouts.first_response_ms orelse short_reply_ms;
    const deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(bound_ms) });
    var operation = ModelsOperation{ .alloc = alloc, .url = url, .authorization = authorization, .headers = headers.list };
    var response = client_mod.runBoundedHttpOperation(ModelsResponse, alloc, cancel, deadline, &operation) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .{ .failure = .cancelled },
        error.Timeout => {
            debug_trace.logf("gateway", "event=configured_models_timeout connection={s} setting=timeouts.first_response_ms bound_ms={d}", .{ definition.id, bound_ms });
            return .{ .failure = .timeout };
        },
        error.ModelListTooLarge => return .{ .failure = .malformed },
        else => return .{ .failure = .transport },
    };
    defer response.deinit(alloc);
    if (response.status != .ok) return .{ .failure = .http_status };
    return parseModelIds(alloc, response.body);
}

/// The ids in a model list body: `{"data":[{"id":...}]}`, as OpenAI-style
/// servers send it, or a bare array of the same entries. An entry with no
/// usable id is skipped; a body of another shape is malformed.
pub fn parseModelIds(alloc: Allocator, body: []const u8) Allocator.Error!ModelsResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = .malformed },
    };
    defer parsed.deinit();
    const list = switch (parsed.value) {
        .array => |array| array,
        .object => |object| switch (object.get("data") orelse return .{ .failure = .malformed }) {
            .array => |array| array,
            else => return .{ .failure = .malformed },
        },
        else => return .{ .failure = .malformed },
    };
    var ids: std.ArrayList([]u8) = .empty;
    errdefer freeIds(alloc, &ids);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    for (list.items) |entry| {
        if (entry != .object) continue;
        const id = switch (entry.object.get("id") orelse continue) {
            .string => |string| string,
            else => continue,
        };
        definitions.validate_model_id(id) catch continue;
        const slot = try seen.getOrPut(alloc, id);
        if (slot.found_existing) continue;
        const owned = try alloc.dupe(u8, id);
        errdefer alloc.free(owned);
        try ids.append(alloc, owned);
        // The map must not point into `parsed`, which a longer-lived caller frees.
        slot.key_ptr.* = owned;
    }
    return .{ .ids = ids };
}

test "model list ids keep the server's order, drop repeats, and skip entries with no usable id" {
    const alloc = std.testing.allocator;
    // The reply a real local server sent, as recorded in
    // tests/e2e/fixtures/custom-endpoint-captures/models.json.
    const captured = "{\"object\":\"list\",\"data\":[{\"id\":\"qwen2.5:0.5b\",\"object\":\"model\",\"created\":1790619955,\"owned_by\":\"library\"},{\"id\":\"qwen2.5:1.5b\",\"object\":\"model\",\"created\":1789143667,\"owned_by\":\"library\"}]}";
    var result = try parseModelIds(alloc, captured);
    defer freeIds(alloc, &result.ids);
    try std.testing.expectEqual(@as(usize, 2), result.ids.items.len);
    try std.testing.expectEqualStrings("qwen2.5:0.5b", result.ids.items[0]);
    try std.testing.expectEqualStrings("qwen2.5:1.5b", result.ids.items[1]);

    var mixed = try parseModelIds(alloc,
        \\[{"id":"b"},{"id":""},{"id":7},{"name":"no id"},7,null,{"id":"a"},{"id":"b"},{"id":" padded "},{"id":"bad\nid"}]
    );
    defer freeIds(alloc, &mixed.ids);
    try std.testing.expectEqual(@as(usize, 2), mixed.ids.items.len);
    try std.testing.expectEqualStrings("b", mixed.ids.items[0]);
    try std.testing.expectEqualStrings("a", mixed.ids.items[1]);

    var empty = try parseModelIds(alloc, "{\"object\":\"list\",\"data\":[]}");
    defer freeIds(alloc, &empty.ids);
    try std.testing.expectEqual(@as(usize, 0), empty.ids.items.len);

    for ([_][]const u8{ "", "{", "{\"object\":\"list\",\"data\":", "null", "\"models\"", "7", "{}", "{\"data\":{}}", "{\"data\":\"a\"}", "{\"models\":[{\"id\":\"a\"}]}" }) |body| {
        try std.testing.expectEqual(ModelsFailure.malformed, (try parseModelIds(alloc, body)).failure);
    }
}

fn testParseAllocations(alloc: Allocator) !void {
    var result = try parseModelIds(alloc, "{\"data\":[{\"id\":\"one\"},{\"id\":\"two\"},{\"id\":\"one\"},{\"id\":\"three\"}]}");
    switch (result) {
        .ids => |*ids| {
            defer freeIds(alloc, ids);
            try std.testing.expectEqual(@as(usize, 3), ids.items.len);
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "model list parsing releases its ids on any allocation failure" {
    try std.testing.checkAllAllocationFailures(@import("../core/shared/testing_allocator.zig").no_resize, testParseAllocations, .{});
}
