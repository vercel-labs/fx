//! Sends requests to a custom model connection
//! (`src/core/config/configured_provider.zig`) for every protocol it can
//! speak: the credential and header rules, the connection's own bounds on how
//! long a request may wait, the masking of secrets in a server's error text,
//! and the request for the server's model list. Each protocol's adapter
//! builds the body and reads the reply.
const std = @import("std");
const build_options = @import("build_options");
const client_mod = @import("client.zig");
const chat_codec = @import("chat_completions_protocol.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const io = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const request_deadlines = @import("request_deadlines.zig");
const sse = @import("sse.zig");
const catalog_fetch_failure = @import("catalog_fetch_failure.zig");
const raw_answer_testing = @import("raw_answer_testing.zig");
const testing_listener = @import("../core/shared/testing_listener.zig");
const command_auth = if (build_options.libfx) struct {} else @import("../core/auth/command_auth.zig");
const ExtraHeader = if (build_options.libfx) struct { name: []const u8, value: []u8 } else @import("../core/auth/command_helper.zig").Header;
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
/// environment (and any helper headers), plus the header its protocol needs.
/// Free with `deinit`, which wipes the values.
pub const Headers = struct {
    list: []std.http.Header = &.{},
    /// How many entries of `list` own a value. Settings headers come first
    /// (`0..settings_owned`), followed by helper headers (`settings_owned..owned`).
    owned: usize = 0,
    settings_owned: usize = 0,
    /// The allocation `list` is a prefix of.
    storage: []std.http.Header = &.{},

    /// Fails with `MissingConfiguredProviderHeader` when a header's variable
    /// is unset or empty, and with `InvalidConfiguredProviderHeader` when its
    /// value could not travel in a header.
    pub fn resolve(alloc: Allocator, definition: *const definitions.Definition, extra: []const ExtraHeader) !Headers {
        const list = try alloc.alloc(std.http.Header, definition.headers.len + extra.len + 1);
        var headers: Headers = .{ .list = list[0..0], .storage = list };
        errdefer headers.deinit(alloc);
        var version_given = false;
        for (definition.headers) |header| {
            // `config_runtime.configuredProviderMessage` names the header and
            // its variable for these errors, by the same rule.
            const value = io.getenv(header.env);
            switch (definitions.header_value(value)) {
                .usable => {},
                .unset, .empty => return error.MissingConfiguredProviderHeader,
                .too_long, .unsendable => return error.InvalidConfiguredProviderHeader,
            }
            list[headers.owned] = .{ .name = header.name, .value = try alloc.dupe(u8, value.?) };
            headers.owned += 1;
            headers.settings_owned += 1;
            headers.list = list[0..headers.owned];
            version_given = version_given or std.ascii.eqlIgnoreCase(header.name, "anthropic-version");
        }
        for (extra) |header| {
            if (headerNamed(list[0..headers.settings_owned], header.name)) {
                debug_trace.logf("gateway", "event=configured_helper_header_skipped connection={s} header={s} reason=settings_precedence", .{ definition.id, header.name });
                continue;
            }
            const owned_name = try alloc.dupe(u8, header.name);
            errdefer alloc.free(owned_name);
            const owned_value = try alloc.dupe(u8, header.value);
            list[headers.owned] = .{ .name = owned_name, .value = owned_value };
            headers.owned += 1;
            headers.list = list[0..headers.owned];
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
        for (self.list[0..self.owned], 0..) |header, index| {
            if (index >= self.settings_owned) alloc.free(@constCast(header.name));
            secret.zeroAndFree(alloc, @constCast(header.value));
        }
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

fn headerNamed(headers: []const std.http.Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
    }
    return false;
}

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

fn commandConnection(definition: *const definitions.Definition) command_auth.Connection {
    return .{
        .identity = definition.binding_identity(),
        .argv = definition.auth.command,
        .cwd = io.homeDir(),
    };
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
        .command => if (token != null) return error.UnexpectedConfiguredProviderCredential,
    }
    return token;
}

/// Sends `payload` to the connection's request URL and reads the reply with
/// `consume`. A wait that runs out ends this attempt
/// (`tests/tla/configured_provider/ConfiguredDeadlines.tla`); request recovery
/// decides whether to send again.
pub fn send(alloc: Allocator, definition: *const definitions.Definition, request: streams.ModelRequest, payload: []const u8, consume: ConsumeFn) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (definition.auth == .command) {
        if (comptime build_options.libfx) return error.ConfiguredCommandAuthUnavailable;
        _ = try tokenOf(definition, request);
        var lease = command_auth.token(alloc, commandConnection(definition), request.cancel_flag, request.deadline) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.Timeout => error.Timeout,
            error.HelperFailed => error.ConfiguredCommandAuthFailed,
            error.TooManyConnections => error.ConfiguredCommandAuthLimit,
        };
        defer lease.deinit(alloc);
        var headers = try Headers.resolve(alloc, definition, lease.headers);
        defer headers.deinit(alloc);
        var result = try postAndClassify(alloc, definition, request, lease.token, &headers, payload, consume);
        if (result == .failed and result.failed.http_status == .unauthorized) {
            command_auth.refused(definition.binding_identity(), lease.gen);
            result.failed.renews_credential_on_replay = true;
        }
        return result;
    }
    const token = try tokenOf(definition, request);
    // Before anything is sent: a header that cannot be filled in fails here.
    var headers = try Headers.resolve(alloc, definition, &.{});
    defer headers.deinit(alloc);
    return postAndClassify(alloc, definition, request, token, &headers, payload, consume);
}

fn postAndClassify(
    alloc: Allocator,
    definition: *const definitions.Definition,
    request: streams.ModelRequest,
    token: ?[]const u8,
    headers: *const Headers,
    payload: []const u8,
    consume: ConsumeFn,
) !streams.Result {
    // The wait the request is in, so a bound that runs out can name itself.
    var wait: request_deadlines.Wait = .connecting;
    return post(alloc, definition, request, token, headers, payload, consume, &wait) catch |err| {
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
        const result = client_mod.fetchWholeBodyOnOpenJob(.{
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

/// A cut-off or broken answer is `malformed`; any other failure to get one is `transport`.
fn modelsFailureFor(err: anyerror) ModelsFailure {
    return if (catalog_fetch_failure.classify(err).category == .malformed_response) .malformed else .transport;
}

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
    const bound_ms = definition.timeouts.first_response_ms orelse short_reply_ms;
    const deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(bound_ms) });
    if (definition.auth == .command) {
        if (comptime build_options.libfx) return .{ .failure = .credential };
        var lease = command_auth.token(alloc, commandConnection(definition), cancel, deadline) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => .{ .failure = .cancelled },
            error.Timeout => .{ .failure = .timeout },
            error.HelperFailed, error.TooManyConnections => .{ .failure = .credential },
        };
        defer lease.deinit(alloc);
        var headers = Headers.resolve(alloc, definition, lease.headers) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failure = .credential },
        };
        defer headers.deinit(alloc);
        const authorization = try alloc.print("Bearer {s}", .{lease.token});
        defer secret.zeroAndFree(alloc, authorization);
        var status: ?std.http.Status = null;
        const result = try fetchModelsWithAuth(alloc, definition, cancel, deadline, bound_ms, authorization, headers.list, &status);
        if (result == .failure and result.failure == .http_status and status == .unauthorized) {
            command_auth.refused(definition.binding_identity(), lease.gen);
        }
        return result;
    }
    var headers = Headers.resolve(alloc, definition, &.{}) catch |err| switch (err) {
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
        .command => return .{ .failure = .credential },
    }
    return fetchModelsWithAuth(alloc, definition, cancel, deadline, bound_ms, authorization, headers.list, null);
}

fn fetchModelsWithAuth(
    alloc: Allocator,
    definition: *const definitions.Definition,
    cancel: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    bound_ms: u32,
    authorization: ?[]const u8,
    headers: []const std.http.Header,
    status_out: ?*?std.http.Status,
) Allocator.Error!ModelsResult {
    const url = try definition.models_url(alloc);
    defer alloc.free(url);
    var operation = ModelsOperation{ .alloc = alloc, .url = url, .authorization = authorization, .headers = headers };
    var response = client_mod.runBoundedHttpOperation(ModelsResponse, alloc, cancel, deadline, &operation) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .{ .failure = .cancelled },
        error.Timeout => {
            debug_trace.logf("gateway", "event=configured_models_timeout connection={s} setting=timeouts.first_response_ms bound_ms={d}", .{ definition.id, bound_ms });
            return .{ .failure = .timeout };
        },
        error.ModelListTooLarge => return .{ .failure = .malformed },
        else => |other| return .{ .failure = modelsFailureFor(other) },
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        if (status_out) |out| out.* = response.status;
        return .{ .failure = .http_status };
    }
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

/// Asks a custom connection for its model list through a loopback server that
/// sends `answer`, or a closed port when `answer` is null. The result must be
/// the failure `expected`.
fn expectModelListFailure(answer: ?[]const u8, expected: ModelsFailure) !void {
    const alloc = std.testing.allocator;
    var server: ?raw_answer_testing.AnswerServer = null;
    if (answer) |bytes| server = try raw_answer_testing.AnswerServer.start(alloc, bytes);
    const base_url = if (server) |running|
        try running.url(alloc, "/v1")
    else
        try alloc.dupe(u8, "http://127.0.0.1:1/v1");
    defer alloc.free(base_url);
    const json = try alloc.print(
        "{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"{s}\",\"auth\":{{\"type\":\"none\"}},\"fetch_models\":true}}}}",
        .{base_url},
    );
    defer alloc.free(json);
    var registry = try definitions.Registry.parse_json(alloc, json);
    defer registry.deinit(alloc);
    var result = try fetchModelIds(alloc, registry.get("local").?, null);
    if (server) |running| try running.finish();
    switch (result) {
        .failure => |failure| try std.testing.expectEqual(expected, failure),
        .ids => |*ids| {
            freeIds(alloc, ids);
            return error.TestExpectedModelListFailure;
        },
    }
}

test "configured model list cut inside its Content-Length is malformed, not an empty list" {
    const answer: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n{\"data\":[]}";
    try expectModelListFailure(answer, .malformed);
}

test "configured model list gzip that is not gzip is malformed" {
    const answer: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"data\":[]}";
    try expectModelListFailure(answer, .malformed);
}

test "configured model list refused before it connects is a transport failure" {
    try expectModelListFailure(null, .transport);
}

const CaptureServer = struct {
    alloc: Allocator,
    state: *State,
    thread: std.Thread,

    const max_requests = 4;

    const State = struct {
        alloc: Allocator,
        server: std.Io.net.Server,
        answers: []const []const u8,
        heads: [max_requests]?[]u8 = @splat(null),
        count: usize = 0,
        joined: bool = false,
        stopping: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(self: *State) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }

        fn serve(self: *State) !void {
            const zio = io.getIo();
            for (self.answers, 0..) |answer, index| {
                const stream = (try testing_listener.acceptUnlessStopping(&self.server, zio, &self.stopping)) orelse return;
                defer stream.close(zio);
                var read_buffer: [4096]u8 = undefined;
                var reader = stream.reader(zio, &read_buffer);
                var head_buf: [16 * 1024]u8 = undefined;
                var head_len: usize = 0;
                while (head_len < head_buf.len) {
                    head_buf[head_len] = try reader.interface.takeByte();
                    head_len += 1;
                    if (std.mem.endsWith(u8, head_buf[0..head_len], "\r\n\r\n")) break;
                }
                const head = head_buf[0..head_len];
                const body_len = contentLength(head);
                for (0..body_len) |_| _ = try reader.interface.takeByte();
                self.heads[index] = try self.alloc.dupe(u8, head);
                self.count = index + 1;
                var write_buffer: [4096]u8 = undefined;
                var writer = stream.writer(zio, &write_buffer);
                writer.interface.writeAll(answer) catch {};
                writer.interface.flush() catch {};
            }
        }
    };

    fn contentLength(head: []const u8) usize {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
            return std.fmt.parseUnsigned(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch 0;
        }
        return 0;
    }

    fn start(alloc: Allocator, answers: []const []const u8) !CaptureServer {
        std.debug.assert(answers.len <= max_requests);
        const zio = io.getIo();
        const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        const state = try alloc.create(State);
        errdefer alloc.destroy(state);
        state.* = .{
            .alloc = alloc,
            .server = try std.Io.net.IpAddress.listen(&address, zio, .{ .reuse_address = true }),
            .answers = answers,
        };
        errdefer state.server.deinit(zio);
        const thread = try std.Thread.spawn(.{}, State.run, .{state});
        return .{ .alloc = alloc, .state = state, .thread = thread };
    }

    fn url(self: CaptureServer, alloc: Allocator, path: []const u8) ![]u8 {
        return alloc.print("http://127.0.0.1:{d}{s}", .{ self.state.server.socket.address.getPort(), path });
    }

    fn headAt(self: CaptureServer, index: usize) []const u8 {
        return self.state.heads[index].?;
    }

    fn finish(self: CaptureServer) !void {
        if (!self.state.joined) {
            self.thread.join();
            self.state.joined = true;
        }
        if (self.state.failure) |err| return err;
    }

    fn deinit(self: CaptureServer) void {
        if (!self.state.joined) {
            self.state.stopping.store(true, .seq_cst);
            self.thread.join();
            self.state.joined = true;
        }
        self.state.server.deinit(io.getIo());
        for (self.state.heads) |maybe_head| if (maybe_head) |head| self.alloc.free(head);
        self.alloc.destroy(self.state);
    }
};

fn testConsume(alloc: Allocator, reader: *std.Io.Reader, _: streams.ModelRequest, _: ?sse.Progress) anyerror!streams.Result {
    const body = try reader.allocRemaining(alloc, .limited(1024));
    defer alloc.free(body);
    return .{ .completed = .{
        .completion = .{ .content = try alloc.dupe(u8, body), .finish_reason = .stop },
        .ownership = .owned,
    } };
}

fn ignoreTestEvent(_: *anyopaque, _: streams.Event) void {}

const TestAdmission = struct {
    calls: usize = 0,

    fn admit(raw: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.calls > 1) return error.ProviderAdmissionRepeated;
    }
};

fn sendTestCommandRequest(
    alloc: Allocator,
    definition: *const definitions.Definition,
    cancel: *std.atomic.Value(bool),
) !streams.Result {
    var delivery = streams.DeliveryCertainty.init();
    var evidence = streams.AttemptEvidence{};
    var admission = TestAdmission{};
    var ctx: u8 = 0;
    const request: streams.ModelRequest = .{
        .credential = .{ .direct = .{ .secret_bytes = "", .source = .configured } },
        .model = "m",
        .retry_count = 1,
        .messages = &.{},
        .tool_choice = .none,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = 1024,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .admission = .{ .context = &admission, .admit_fn = TestAdmission.admit },
        .events = .{ .context = &ctx, .emit_fn = ignoreTestEvent },
        .cancel_flag = cancel,
    };
    const res = try send(alloc, definition, request, "{}", testConsume);
    try std.testing.expectEqual(@as(usize, 1), admission.calls);
    return res;
}

fn readTmpCounter(dir: std.Io.Dir) ![]u8 {
    const file = try dir.openFile(io.getIo(), "count", .{});
    defer file.close(io.getIo());
    const raw = try io.readFileToEnd(std.testing.allocator, @constCast(&file), 64);
    errdefer std.testing.allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    const out = try std.testing.allocator.dupe(u8, trimmed);
    std.testing.allocator.free(raw);
    return out;
}

const ok_http_answer = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
const unauthorized_http_answer = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: 22\r\nConnection: close\r\n\r\n{\"error\":\"bad token!\"}";

test "configured command auth sends helper token as Bearer with helper headers" {
    command_auth.shutdown();
    defer command_auth.shutdown();

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const env = try raw_answer_testing.Env.install(alloc, &.{.{ "HOME", home }});
    defer env.deinit();

    var server = try CaptureServer.start(alloc, &.{ok_http_answer});
    defer server.deinit();
    const base_url = try server.url(alloc, "/v1");
    defer alloc.free(base_url);

    const json = try alloc.print(
        "{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"{s}\",\"auth\":{{\"type\":\"command\",\"command\":[\"/bin/sh\",\"-c\",\"printf '{{\\\"token\\\":\\\"tok-1\\\",\\\"headers\\\":{{\\\"X-Helper\\\":\\\"hv-1\\\"}}}}'\"]}}}}}}",
        .{base_url},
    );
    defer alloc.free(json);
    var registry = try definitions.Registry.parse_json(alloc, json);
    defer registry.deinit(alloc);

    var cancel = std.atomic.Value(bool).init(false);
    var result = try sendTestCommandRequest(alloc, registry.get("local").?, &cancel);
    defer result.deinit(alloc);
    try server.finish();

    try std.testing.expectEqualStrings("ok", result.completed.completion.content.?);
    const head = server.headAt(0);
    try std.testing.expect(std.mem.find(u8, head, "authorization: Bearer tok-1\r\n") != null or
        std.mem.find(u8, head, "Authorization: Bearer tok-1\r\n") != null);
    try std.testing.expect(std.mem.find(u8, head, "X-Helper: hv-1\r\n") != null);
}

test "configured command auth marks 401 for replay and next send reruns helper" {
    command_auth.shutdown();
    defer command_auth.shutdown();

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const env = try raw_answer_testing.Env.install(alloc, &.{.{ "HOME", home }});
    defer env.deinit();

    var server = try CaptureServer.start(alloc, &.{ unauthorized_http_answer, ok_http_answer });
    defer server.deinit();
    const base_url = try server.url(alloc, "/v1");
    defer alloc.free(base_url);

    const script = "n=$(cat count 2>/dev/null || echo 0); n=$((n+1)); echo $n > count; printf '{\\\"token\\\":\\\"tok-%s\\\"}' $n";
    const json = try alloc.print(
        "{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"{s}\",\"auth\":{{\"type\":\"command\",\"command\":[\"/bin/sh\",\"-c\",\"{s}\"]}}}}}}",
        .{ base_url, script },
    );
    defer alloc.free(json);
    var registry = try definitions.Registry.parse_json(alloc, json);
    defer registry.deinit(alloc);
    const def = registry.get("local").?;

    var cancel = std.atomic.Value(bool).init(false);
    var first = try sendTestCommandRequest(alloc, def, &cancel);
    defer first.deinit(alloc);
    try std.testing.expect(first == .failed);
    try std.testing.expectEqual(streams.FailureKind.unauthorized, first.failed.kind);
    try std.testing.expect(first.failed.renews_credential_on_replay);

    var second = try sendTestCommandRequest(alloc, def, &cancel);
    defer second.deinit(alloc);
    try server.finish();

    try std.testing.expectEqualStrings("ok", second.completed.completion.content.?);
    const count = try readTmpCounter(tmp.dir);
    defer alloc.free(count);
    try std.testing.expectEqualStrings("2", count);
    try std.testing.expect(std.mem.find(u8, server.headAt(0), "Bearer tok-1\r\n") != null);
    try std.testing.expect(std.mem.find(u8, server.headAt(1), "Bearer tok-2\r\n") != null);
}

test "configured command auth keeps settings headers ahead of matching helper headers" {
    command_auth.shutdown();
    defer command_auth.shutdown();

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const env = try raw_answer_testing.Env.install(alloc, &.{
        .{ "HOME", home },
        .{ "FX_TEST_SETTINGS_TEAM", "from-settings" },
    });
    defer env.deinit();

    var server = try CaptureServer.start(alloc, &.{ok_http_answer});
    defer server.deinit();
    const base_url = try server.url(alloc, "/v1");
    defer alloc.free(base_url);

    const json = try alloc.print(
        "{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"{s}\",\"auth\":{{\"type\":\"command\",\"command\":[\"/bin/sh\",\"-c\",\"printf '{{\\\"token\\\":\\\"tok-1\\\",\\\"headers\\\":{{\\\"x-team\\\":\\\"from-helper\\\",\\\"X-Other\\\":\\\"from-helper-2\\\"}}}}'\"]}},\"headers\":{{\"X-Team\":{{\"env\":\"FX_TEST_SETTINGS_TEAM\"}}}}}}}}",
        .{base_url},
    );
    defer alloc.free(json);
    var registry = try definitions.Registry.parse_json(alloc, json);
    defer registry.deinit(alloc);

    var cancel = std.atomic.Value(bool).init(false);
    var result = try sendTestCommandRequest(alloc, registry.get("local").?, &cancel);
    defer result.deinit(alloc);
    try server.finish();

    const head = server.headAt(0);
    try std.testing.expect(std.mem.find(u8, head, "X-Team: from-settings\r\n") != null);
    try std.testing.expect(std.mem.find(u8, head, "from-helper\r\n") == null);
    try std.testing.expect(std.mem.find(u8, head, "X-Other: from-helper-2\r\n") != null);
}

test "configured command auth failing helper returns ConfiguredCommandAuthFailed" {
    command_auth.shutdown();
    defer command_auth.shutdown();

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const env = try raw_answer_testing.Env.install(alloc, &.{.{ "HOME", home }});
    defer env.deinit();

    const json =
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://127.0.0.1:1/v1","auth":{"type":"command","command":["/bin/sh","-c","printf 'no session\n' >&2; exit 3"]}}}
    ;
    var registry = try definitions.Registry.parse_json(alloc, json);
    defer registry.deinit(alloc);

    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.ConfiguredCommandAuthFailed,
        sendTestCommandRequest(alloc, registry.get("local").?, &cancel),
    );
}

test "configured command auth fetchModelIds sends token and drops cached token on 401" {
    command_auth.shutdown();
    defer command_auth.shutdown();

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const env = try raw_answer_testing.Env.install(alloc, &.{.{ "HOME", home }});
    defer env.deinit();

    const ok_models = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 22\r\nConnection: close\r\n\r\n{\"data\":[{\"id\":\"m1\"}]}";
    var server = try CaptureServer.start(alloc, &.{ unauthorized_http_answer, ok_models });
    defer server.deinit();
    const base_url = try server.url(alloc, "/v1");
    defer alloc.free(base_url);

    const script = "n=$(cat count 2>/dev/null || echo 0); n=$((n+1)); echo $n > count; printf '{\\\"token\\\":\\\"tok-%s\\\",\\\"headers\\\":{\\\"X-H\\\":\\\"hv\\\"}}' $n";
    const json = try alloc.print(
        "{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"{s}\",\"auth\":{{\"type\":\"command\",\"command\":[\"/bin/sh\",\"-c\",\"{s}\"]}},\"fetch_models\":true}}}}",
        .{ base_url, script },
    );
    defer alloc.free(json);
    var registry = try definitions.Registry.parse_json(alloc, json);
    defer registry.deinit(alloc);
    const def = registry.get("local").?;

    const first = try fetchModelIds(alloc, def, null);
    switch (first) {
        .ids => |ids| {
            var owned = ids;
            freeIds(alloc, &owned);
            return error.TestExpectedModelListFailure;
        },
        .failure => |failure| try std.testing.expectEqual(ModelsFailure.http_status, failure),
    }

    var second = try fetchModelIds(alloc, def, null);
    defer switch (second) {
        .ids => |*ids| freeIds(alloc, ids),
        .failure => {},
    };
    try server.finish();

    try std.testing.expect(second == .ids);
    try std.testing.expectEqual(@as(usize, 1), second.ids.items.len);
    const count = try readTmpCounter(tmp.dir);
    defer alloc.free(count);
    try std.testing.expectEqualStrings("2", count);
    try std.testing.expect(std.mem.find(u8, server.headAt(0), "Bearer tok-1\r\n") != null);
    try std.testing.expect(std.mem.find(u8, server.headAt(0), "X-H: hv\r\n") != null);
    try std.testing.expect(std.mem.find(u8, server.headAt(1), "Bearer tok-2\r\n") != null);
}

test "configured command auth masks token and helper header values in error detail" {
    command_auth.shutdown();
    defer command_auth.shutdown();

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const env = try raw_answer_testing.Env.install(alloc, &.{.{ "HOME", home }});
    defer env.deinit();

    const body = "{\"error\":\"echo tok-secret-123 and hdr-secret-456\"}";
    const answer = try alloc.print(
        "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    defer alloc.free(answer);
    var server = try CaptureServer.start(alloc, &.{answer});
    defer server.deinit();
    const base_url = try server.url(alloc, "/v1");
    defer alloc.free(base_url);

    const json = try alloc.print(
        "{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"{s}\",\"auth\":{{\"type\":\"command\",\"command\":[\"/bin/sh\",\"-c\",\"printf '{{\\\"token\\\":\\\"tok-secret-123\\\",\\\"headers\\\":{{\\\"X-Secret\\\":\\\"hdr-secret-456\\\"}}}}'\"]}}}}}}",
        .{base_url},
    );
    defer alloc.free(json);
    var registry = try definitions.Registry.parse_json(alloc, json);
    defer registry.deinit(alloc);

    var cancel = std.atomic.Value(bool).init(false);
    var result = try sendTestCommandRequest(alloc, registry.get("local").?, &cancel);
    defer result.deinit(alloc);
    try server.finish();

    try std.testing.expect(result == .failed);
    const detail = result.failed.detail.?;
    try std.testing.expect(std.mem.find(u8, detail, "tok-secret-123") == null);
    try std.testing.expect(std.mem.find(u8, detail, "hdr-secret-456") == null);
}
