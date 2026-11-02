//! A fake host transport for tests of the host-backed providers: it serves
//! canned responses in order and records each request.
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const host_stream = @import("host_stream_provider.zig");

/// Serves canned responses in order and records each request.
pub const FakeTransport = struct {
    pub const Response = struct { status: u16, body: []const u8 };
    pub const max_calls = 4;

    responses: []const Response,
    /// The model and prepared body of `request()`.
    model: []const u8 = "test-model",
    prepared_body: []const u8 = "{\"model\":\"test-model\"}",
    calls: usize = 0,
    offset: usize = 0,
    methods: [max_calls][]const u8 = undefined,
    urls: [max_calls][]u8 = undefined,
    headers: [max_calls][]u8 = undefined,
    bodies: [max_calls][]u8 = undefined,
    closed: usize = 0,
    consumed: usize = 0,
    cancel_flag: std.atomic.Value(bool) = .init(false),
    delivery: stream_provider.DeliveryCertainty = .init(),
    attempt: stream_provider.AttemptEvidence = .{},

    pub fn deinit(self: *FakeTransport) void {
        for (0..self.calls) |index| {
            std.testing.allocator.free(self.urls[index]);
            std.testing.allocator.free(self.headers[index]);
            std.testing.allocator.free(self.bodies[index]);
        }
    }

    pub fn transport(self: *FakeTransport) host_stream.Transport {
        return .{ .context = self, .open_fn = open, .status_fn = status, .next_fn = next, .close_fn = close, .consumed_fn = markConsumed };
    }

    pub fn request(self: *FakeTransport, credential: stream_provider.CredentialLease) stream_provider.ModelRequest {
        return .{
            .credential = credential,
            .model = self.model,
            .retry_count = 0,
            .messages = &.{},
            .tool_choice = .auto,
            .provider_options = .{},
            .prepared_request_body = self.prepared_body,
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &self.delivery,
            .attempt_evidence = &self.attempt,
            .events = .{ .context = self, .emit_fn = emit },
            .admission = .{ .context = self, .admit_fn = admit },
            .cancel_flag = &self.cancel_flag,
            .session_id = "session-1",
        };
    }

    fn open(raw: ?*anyopaque, method: []const u8, url: []const u8, headers: []const u8, body: []const u8) anyerror!i32 {
        const self: *FakeTransport = @ptrCast(@alignCast(raw.?));
        if (self.calls == max_calls or self.calls == self.responses.len) return error.UnexpectedRequest;
        const index = self.calls;
        self.methods[index] = method;
        self.urls[index] = try std.testing.allocator.dupe(u8, url);
        errdefer std.testing.allocator.free(self.urls[index]);
        self.headers[index] = try std.testing.allocator.dupe(u8, headers);
        errdefer std.testing.allocator.free(self.headers[index]);
        self.bodies[index] = try std.testing.allocator.dupe(u8, body);
        self.calls += 1;
        self.offset = 0;
        return @intCast(index + 1);
    }

    fn status(raw: ?*anyopaque, handle: i32, status_out: *u16) i32 {
        const self: *FakeTransport = @ptrCast(@alignCast(raw.?));
        status_out.* = self.responses[@intCast(handle - 1)].status;
        return 1;
    }

    fn next(raw: ?*anyopaque, handle: i32, out: []u8) i32 {
        const self: *FakeTransport = @ptrCast(@alignCast(raw.?));
        const body = self.responses[@intCast(handle - 1)].body;
        const len = @min(out.len, body.len - self.offset);
        @memcpy(out[0..len], body[self.offset..][0..len]);
        self.offset += len;
        return @intCast(len);
    }

    fn close(raw: ?*anyopaque, _: i32) void {
        const self: *FakeTransport = @ptrCast(@alignCast(raw.?));
        self.closed += 1;
    }

    fn markConsumed(raw: ?*anyopaque, _: i32) void {
        const self: *FakeTransport = @ptrCast(@alignCast(raw.?));
        self.consumed += 1;
    }

    fn emit(_: *anyopaque, _: stream_provider.Event) void {}

    fn admit(_: *anyopaque) !void {}
};
