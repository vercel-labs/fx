//! The HTTP side of the built-in remote runner (spec 3.10, R2, R4.8): the
//! origin each request goes to, the token it carries, and the one request
//! function that setup and run calls share. Every request has the call's
//! cancel flag and a deadline, and its response body is bounded.

const std = @import("std");
const io_mod = @import("../../shared/io.zig");
const secret = @import("../../auth/secret.zig");
const gateway_client = @import("../../../gateway/client.zig");
const credentials = @import("credentials.zig");

pub const default_origin = "https://api.vercel.com";
/// The variable the caller reads for the override (spec 3.10, registered in R5.1).
pub const override_env = "FX_TEST_VERCEL_API_URL";
/// The token every request carries while the test override is honored (spec 3.10).
pub const test_token = "fx-test-token";
/// The deadline of one request, from its start to the end of its body (R2.3).
pub const request_deadline_ms: i64 = 10_000;
/// The largest response body one request reads (R3.7).
pub const max_response_bytes: usize = 256 * 1024;

pub const Kind = enum { default, loopback_test, ignored_override };

pub const BaseUrl = struct {
    kind: Kind,
    origin: []const u8,
};

/// The origin for a request. `FX_TEST_VERCEL_API_URL` is honored only as a
/// loopback origin with a canonical port and nothing after it. Any other
/// value, an empty one included, is ignored: the origin stays the default,
/// and the caller traces that once.
pub fn resolveBaseUrl(override: ?[]const u8) BaseUrl {
    const value = override orelse return .{ .kind = .default, .origin = default_origin };
    if (isLoopbackOrigin(value)) return .{ .kind = .loopback_test, .origin = value };
    return .{ .kind = .ignored_override, .origin = default_origin };
}

const loopback_v4 = "http://127.0.0.1:";
const loopback_v6 = "http://[::1]:";

fn isLoopbackOrigin(value: []const u8) bool {
    const port_text = if (std.mem.startsWith(u8, value, loopback_v4))
        value[loopback_v4.len..]
    else if (std.mem.startsWith(u8, value, loopback_v6))
        value[loopback_v6.len..]
    else
        return false;
    return validPort(port_text);
}

/// Decimal, one to five digits, no leading zero, value 1 to 65535.
fn validPort(text: []const u8) bool {
    if (text.len == 0 or text.len > 5 or text[0] == '0') return false;
    var port: u32 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return false;
        port = port * 10 + (byte - '0');
    }
    return port >= 1 and port <= 65535;
}

/// The token a request carries. While the override is honored, the real token
/// is never sent, even though fx read it for R2 and R3 (spec 3.10, AC-30).
pub fn bearerToken(base: BaseUrl, real: credentials.Token) []const u8 {
    return switch (base.kind) {
        .loopback_test => test_token,
        .default, .ignored_override => real.bytes(),
    };
}

/// One request. `step` names the caller's step in the trace line; the trace
/// names the step and the HTTP status only (U12, R4.8), never the path, the
/// body, the token or a header.
pub const Call = struct {
    step: []const u8,
    method: std.http.Method,
    path: []const u8,
    body: ?[]const u8 = null,
    /// The most body bytes this call reads. Setup's replies are larger than sandbox replies (U5).
    max_bytes: usize = max_response_bytes,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: Response, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
    }
};

pub const RequestError = std.mem.Allocator.Error || error{
    Cancelled,
    Timeout,
    TransportFailed,
    BodyTooLarge,
    InvalidPath,
};

/// Sends one call. It fails with `error.Cancelled` once `cancel_flag` is set,
/// with `error.Timeout` after `request_deadline_ms`, and with `error.BodyTooLarge`
/// past `call.max_bytes`. A redirect is not followed, so the token never
/// goes to another host. The caller owns the response and frees it with `deinit`.
pub fn request(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    base: BaseUrl,
    real: credentials.Token,
    trace: credentials.Trace,
    call: Call,
) RequestError!Response {
    return requestWithin(alloc, cancel_flag, base, real, trace, call, request_deadline_ms);
}

fn requestWithin(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    base: BaseUrl,
    real: credentials.Token,
    trace: credentials.Trace,
    call: Call,
    deadline_ms: i64,
) RequestError!Response {
    const response = perform(alloc, cancel_flag, base, real, call, deadline_ms) catch |err| {
        const mapped = mapError(err);
        traceFailure(trace, call.step, mapped);
        return mapped;
    };
    traceStatus(trace, call.step, response.status);
    return response;
}

fn perform(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    base: BaseUrl,
    real: credentials.Token,
    call: Call,
    deadline_ms: i64,
) anyerror!Response {
    const url = try requestUrl(alloc, base, call.path);
    defer alloc.free(url);
    var operation: Operation = .{
        .alloc = alloc,
        .url = url,
        .bearer = bearerToken(base, real),
        .method = call.method,
        .body = call.body,
        .max_bytes = call.max_bytes,
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(deadline_ms),
    });
    return gateway_client.runBoundedHttpOperation(Response, alloc, cancel_flag, deadline, &operation);
}

/// The URL of a call: the origin, then the path. The path must start with `/`
/// and hold no whitespace or control byte, so the origin's host is the host of
/// every request: the authority ends at the first `/` after the origin.
pub fn requestUrl(alloc: std.mem.Allocator, base: BaseUrl, path: []const u8) RequestError![]u8 {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    for (path) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidPath;
    }
    return alloc.print("{s}{s}", .{ base.origin, path });
}

/// The work one bounded request does on its own thread. The connection opens on
/// an open job (`openRequestOnJob`), which owns its client, so no connection
/// outlives this call, and nothing of this call is read after it returns.
const Operation = struct {
    alloc: std.mem.Allocator,
    url: []const u8,
    bearer: []const u8,
    method: std.http.Method,
    body: ?[]const u8,
    max_bytes: usize,

    pub fn run(self: *@This()) anyerror!Response {
        const uri = try std.Uri.parse(self.url);
        const authorization = try self.alloc.print("Bearer {s}", .{self.bearer});
        defer secret.zeroAndFree(self.alloc, authorization);
        const accept = [_]std.http.Header{.{ .name = "Accept", .value = "application/json" }};
        var opened = try gateway_client.openRequestOnJob(self.method, uri, .{
            .headers = .{
                .accept_encoding = .omit,
                .authorization = .{ .override = authorization },
                .content_type = if (self.body != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = &accept,
            .redirect_behavior = .unhandled,
        });
        defer opened.deinit();
        const req = &opened.request;

        if (self.body) |body| {
            const copy = try self.alloc.dupe(u8, body);
            defer self.alloc.free(copy);
            try req.sendBodyComplete(copy);
        } else if (self.method.requestHasBody()) {
            // std asserts that a body-less send is for a method without a body, so a POST sends an empty body.
            var empty: [0]u8 = .{};
            try req.sendBodyComplete(&empty);
        } else {
            try req.sendBodiless();
        }

        var response = try req.receiveHead(&.{});
        const status: u16 = @backingInt(response.head.status);
        var transfer_buffer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const body = reader.allocRemaining(self.alloc, .limited(self.max_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooLarge,
            else => return err,
        };
        return .{ .status = status, .body = body };
    }
};

fn mapError(err: anyerror) RequestError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.Timeout => error.Timeout,
        error.BodyTooLarge => error.BodyTooLarge,
        error.InvalidPath => error.InvalidPath,
        else => error.TransportFailed,
    };
}

pub fn traceStatus(trace: credentials.Trace, step: []const u8, status: u16) void {
    var buffer: [256]u8 = undefined;
    const text = std.mem.print(&buffer, "vercel request: step {s}, status {d}", .{ step, status }) catch return;
    trace.write(text);
}

pub fn traceFailure(trace: credentials.Trace, step: []const u8, err: anyerror) void {
    var buffer: [256]u8 = undefined;
    const text = std.mem.print(&buffer, "vercel request: step {s}, failed {s}", .{ step, @errorName(err) }) catch return;
    trace.write(text);
}

// --- Tests ---------------------------------------------------------------

const test_server = @import("test_server.zig");

const probe_token = "fx-leak-probe-7Q2";
const real_token_text = "vca_real_fake";
const test_now: i64 = 1_800_000_000;

fn loopbackOrigin(buffer: []u8, port_number: u16) ![]const u8 {
    return std.mem.print(buffer, "http://127.0.0.1:{d}", .{port_number});
}

test "FX_TEST_VERCEL_API_URL is honored only for the loopback forms (spec 3.10)" {
    const cases = [_]struct { input: ?[]const u8, kind: Kind }{
        .{ .input = null, .kind = .default },
        .{ .input = "http://127.0.0.1:9", .kind = .loopback_test },
        .{ .input = "http://127.0.0.1:65535", .kind = .loopback_test },
        .{ .input = "http://[::1]:1", .kind = .loopback_test },
        .{ .input = "http://[::1]:9", .kind = .loopback_test },
        .{ .input = "http://127.0.0.1:9/x", .kind = .ignored_override },
        .{ .input = "http://127.0.0.1:9@evil.com", .kind = .ignored_override },
        .{ .input = "http://127.0.0.1.evil.com:9", .kind = .ignored_override },
        .{ .input = "https://127.0.0.1:9", .kind = .ignored_override },
        .{ .input = "http://localhost:9", .kind = .ignored_override },
        .{ .input = "http://127.0.0.1:0", .kind = .ignored_override },
        .{ .input = "http://127.0.0.1:70000", .kind = .ignored_override },
        .{ .input = "", .kind = .ignored_override },
        .{ .input = "http://127.0.0.1:09", .kind = .ignored_override },
        .{ .input = "http://127.0.0.1:", .kind = .ignored_override },
        .{ .input = "http://127.0.0.1:9/", .kind = .ignored_override },
        .{ .input = "http://127.0.0.1:9 ", .kind = .ignored_override },
    };
    for (cases) |case| {
        const base = resolveBaseUrl(case.input);
        try std.testing.expectEqual(case.kind, base.kind);
        if (case.kind == .ignored_override) {
            try std.testing.expectEqualStrings(default_origin, base.origin);
        }
    }
}

test "every request carries the test token while the override is honored, never the real one (AC-30)" {
    const real: credentials.Token = .{ .value = real_token_text };
    const honored = resolveBaseUrl("http://127.0.0.1:9");
    try std.testing.expectEqualStrings(test_token, bearerToken(honored, real));
    const ignored = resolveBaseUrl("http://127.0.0.1:9/x");
    try std.testing.expectEqualStrings(real_token_text, bearerToken(ignored, real));
    try std.testing.expectEqualStrings(real_token_text, bearerToken(resolveBaseUrl(null), real));
}

test "an ignored override never changes the host a request goes to" {
    const alloc = std.testing.allocator;
    const base = resolveBaseUrl("http://127.0.0.1:9/x");

    const plain = try requestUrl(alloc, base, "/v2/user");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("https://api.vercel.com/v2/user", plain);

    const pinned = try requestUrl(alloc, base, "//evil.com/x@evil.com");
    defer alloc.free(pinned);
    try std.testing.expect(std.mem.startsWith(u8, pinned, "https://api.vercel.com/"));

    try std.testing.expectError(error.InvalidPath, requestUrl(alloc, base, "v2/user"));
    try std.testing.expectError(error.InvalidPath, requestUrl(alloc, base, "/v2/user name"));
    try std.testing.expectError(error.InvalidPath, requestUrl(alloc, base, "/v2/user\r\nHost: evil.com"));
}

test "a request to the honored override sends the test token and the query, and returns the status and body" {
    var server: test_server.Server = .{ .replies = &.{.{ .body = "{\"ok\":true}" }} };
    try server.listen();
    defer server.close();
    try server.start();

    var origin_buffer: [64]u8 = undefined;
    const base = resolveBaseUrl(try loopbackOrigin(&origin_buffer, server.port()));
    var capture: credentials.CaptureTrace = .{};
    var cancel = std.atomic.Value(bool).init(false);
    const response = try request(std.testing.allocator, &cancel, base, .{ .value = real_token_text }, capture.trace(), .{
        .step = "user",
        .method = .GET,
        .path = "/v2/teams?limit=100",
    });
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", response.body);

    server.close();
    const wire = server.head(0);
    try std.testing.expect(std.mem.find(u8, wire, "GET /v2/teams?limit=100 HTTP/1.1") != null);
    try std.testing.expect(std.mem.find(u8, wire, "Bearer fx-test-token") != null);
    try std.testing.expect(std.mem.find(u8, wire, real_token_text) == null);
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel request: step user, status 200") != null);
    try std.testing.expect(std.mem.find(u8, capture.captured(), real_token_text) == null);
}

test "a POST sends its JSON body, and a 404 comes back as a status, not an error" {
    var server: test_server.Server = .{ .replies = &.{.{ .mode = .echo }} };
    const payload = "{\"name\":\"fx-sandbox\"}";
    try server.listen();
    defer server.close();
    try server.start();

    var origin_buffer: [64]u8 = undefined;
    const base = resolveBaseUrl(try loopbackOrigin(&origin_buffer, server.port()));
    var capture: credentials.CaptureTrace = .{};
    var cancel = std.atomic.Value(bool).init(false);
    const echoed = try request(std.testing.allocator, &cancel, base, .{ .value = real_token_text }, capture.trace(), .{
        .step = "create",
        .method = .POST,
        .path = "/v11/projects?teamId=team_fake",
        .body = payload,
    });
    defer echoed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(payload, echoed.body);

    server.close();
    try std.testing.expect(std.mem.find(u8, server.head(0), "POST /v11/projects?teamId=team_fake HTTP/1.1") != null);
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel request: step create, status 200") != null);
}

test "a body-less POST is sent with Content-Length 0 and gets its reply, not a std assert" {
    var server: test_server.Server = .{ .replies = &.{.{ .body = "{}" }}, .sink_bodies = true };
    try server.listen();
    try server.start();
    defer server.close();

    var origin_buffer: [64]u8 = undefined;
    const base = resolveBaseUrl(try loopbackOrigin(&origin_buffer, server.port()));
    var capture: credentials.CaptureTrace = .{};
    var cancel = std.atomic.Value(bool).init(false);
    const reply = try request(std.testing.allocator, &cancel, base, .{ .value = real_token_text }, capture.trace(), .{
        .step = "stop",
        .method = .POST,
        .path = "/v2/sandboxes/sessions/s/stop?teamId=team_fake",
    });
    defer reply.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{}", reply.body);

    server.close();
    try std.testing.expect(std.mem.find(u8, server.head(0), "POST /v2/sandboxes/sessions/s/stop?teamId=team_fake HTTP/1.1") != null);
    try std.testing.expect(std.ascii.findIgnoreCase(server.head(0), "content-length: 0") != null);
}

test "a 404 is returned as its status" {
    var server: test_server.Server = .{ .replies = &.{.{ .status = "404 Not Found", .body = "{\"error\":\"not_found\"}" }} };
    try server.listen();
    defer server.close();
    try server.start();

    var origin_buffer: [64]u8 = undefined;
    const base = resolveBaseUrl(try loopbackOrigin(&origin_buffer, server.port()));
    var capture: credentials.CaptureTrace = .{};
    var cancel = std.atomic.Value(bool).init(false);
    const response = try request(std.testing.allocator, &cancel, base, .{ .value = real_token_text }, capture.trace(), .{
        .step = "project",
        .method = .GET,
        .path = "/v9/projects/fake-web",
    });
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 404), response.status);
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel request: step project, status 404") != null);
}

test "a response over the body cap fails with BodyTooLarge" {
    var server: test_server.Server = .{ .replies = &.{.{ .mode = .too_large, .size = max_response_bytes + 1024 }} };
    try server.listen();
    defer server.close();
    try server.start();

    var origin_buffer: [64]u8 = undefined;
    const base = resolveBaseUrl(try loopbackOrigin(&origin_buffer, server.port()));
    var capture: credentials.CaptureTrace = .{};
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.BodyTooLarge, request(std.testing.allocator, &cancel, base, .{ .value = real_token_text }, capture.trace(), .{
        .step = "teams",
        .method = .GET,
        .path = "/v2/teams",
    }));
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel request: step teams, failed BodyTooLarge") != null);
}

test "a held response times out at its deadline" {
    var server: test_server.Server = .{ .replies = &.{.{ .mode = .hold }} };
    try server.listen();
    defer server.close();
    try server.start();

    var origin_buffer: [64]u8 = undefined;
    const base = resolveBaseUrl(try loopbackOrigin(&origin_buffer, server.port()));
    var capture: credentials.CaptureTrace = .{};
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.Timeout, requestWithin(std.testing.allocator, &cancel, base, .{ .value = real_token_text }, capture.trace(), .{
        .step = "user",
        .method = .GET,
        .path = "/v2/user",
    }, 200));
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel request: step user, failed Timeout") != null);
}

test "a cancel during a held response ends the request as Cancelled" {
    var cancel = std.atomic.Value(bool).init(false);
    const replies = [_]test_server.Reply{.{ .mode = .cancel_then_hold, .cancel = &cancel }};
    var server: test_server.Server = .{ .replies = &replies };
    try server.listen();
    defer server.close();
    try server.start();

    var origin_buffer: [64]u8 = undefined;
    const base = resolveBaseUrl(try loopbackOrigin(&origin_buffer, server.port()));
    var capture: credentials.CaptureTrace = .{};
    try std.testing.expectError(error.Cancelled, request(std.testing.allocator, &cancel, base, .{ .value = real_token_text }, capture.trace(), .{
        .step = "user",
        .method = .GET,
        .path = "/v2/user",
    }));
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel request: step user, failed Cancelled") != null);
}

test "a call whose cancel is already set sends nothing" {
    var cancel = std.atomic.Value(bool).init(true);
    var server: test_server.Server = .{ .replies = &.{.{ .body = "{\"ok\":true}" }} };
    try server.listen();
    defer server.close();
    try server.start();

    var origin_buffer: [64]u8 = undefined;
    const base = resolveBaseUrl(try loopbackOrigin(&origin_buffer, server.port()));
    var capture: credentials.CaptureTrace = .{};
    try std.testing.expectError(error.Cancelled, request(std.testing.allocator, &cancel, base, .{ .value = real_token_text }, capture.trace(), .{
        .step = "user",
        .method = .GET,
        .path = "/v2/user",
    }));
    server.close();
    try std.testing.expectEqual(@as(usize, 0), server.served);
}

test "a known token goes through load and one request without reaching a trace line or the wire" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{.{ .body = "{\"ok\":true}" }} };
    try server.listen();
    defer server.close();
    try server.start();

    var capture: credentials.CaptureTrace = .{};
    const login = try credentials.load(arena_state.allocator(), .{ .vercel_token = probe_token, .home = "/Users/example" }, .linux, credentials.disk, capture.trace(), test_now);
    const real = switch (login) {
        .token => |token| token,
        else => return error.TestUnexpectedResult,
    };

    var origin_buffer: [64]u8 = undefined;
    const base = resolveBaseUrl(try loopbackOrigin(&origin_buffer, server.port()));
    var cancel = std.atomic.Value(bool).init(false);
    const response = try request(std.testing.allocator, &cancel, base, real, capture.trace(), .{
        .step = "user",
        .method = .GET,
        .path = "/v2/user",
    });
    defer response.deinit(std.testing.allocator);

    server.close();
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel login: source env, result token") != null);
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel request: step user, status 200") != null);
    try std.testing.expect(std.mem.find(u8, capture.captured(), probe_token) == null);
    try std.testing.expect(std.mem.find(u8, server.head(0), probe_token) == null);
    try std.testing.expect(std.mem.find(u8, server.head(0), "Bearer fx-test-token") != null);
}
