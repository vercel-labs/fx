//! Streamable HTTP I/O: each request runs as its own task on
//! `std.http.Client`, the client fx already uses, reads a JSON body or an SSE
//! stream, and posts what it finds to one queue the host reads with `next`.
//! Cancelling a request cancels its task, which closes the stream.
//! Redirects aren't followed: a 3xx is an HTTP failure the host reports.
//! 2025 sessions also use GET and DELETE, the `Mcp-Session-Id` response
//! header, and SSE event ids and `retry`; 2026 ignores them. OAuth adds
//! rejected requests, with their challenge, and `fetch` for any other URL.

const std = @import("std");
const Io = std.Io;
const lines = @import("lines.zig");
const Bell = @import("bell.zig").Bell;
const sse = @import("../protocol/sse.zig");
const wire = @import("../protocol/wire.zig");

pub const Options = struct {
    url: []const u8,
    /// Headers the host configured for every request, such as an API key.
    headers: []const std.http.Header = &.{},
    /// The largest JSON body or SSE event.
    max_message: usize = 16 * 1024 * 1024,
    max_in_flight: usize = 32,
    /// Rung after each post, for a host that reads many clients.
    bell: ?*Bell = null,
};

pub const Method = enum { post, get, delete };

pub const Ending = enum {
    /// The body or stream was read to its end.
    complete,
    /// 202 Accepted with no body.
    accepted,
    /// A status with no JSON-RPC message in the body.
    http_failure,
    /// The connection or stream broke, or a message was over the limit.
    broken,
    /// 401, or 403 with a `WWW-Authenticate` challenge: the server
    /// didn't take the request.
    rejected,
};

/// What `next` returns. Slices stay valid until the next `next`.
pub const Incoming = union(enum) {
    /// A JSON-RPC message in the answer to request `key`, with the answer's
    /// status, and the SSE event's id and `retry` when it set them.
    message: struct { key: u64, status: u16, bytes: []const u8, message: wire.Message, event_id: ?[]const u8, retry_ms: ?u32 },
    /// An SSE event on `key`'s stream with an id or `retry` but no JSON-RPC
    /// message, such as a priming event.
    mark: struct { key: u64, event_id: ?[]const u8, retry_ms: ?u32 },
    /// The answer to `key` carried an `Mcp-Session-Id` header.
    session: struct { key: u64, id: []const u8 },
    /// The answer to `key` is an event stream: its head arrived, so the
    /// server holds the stream open.
    opened: u64,
    /// Request `key` ended. Nothing more comes for it. A rejected one carries
    /// its `WWW-Authenticate` values, joined.
    ended: struct { key: u64, status: u16, how: Ending, challenge: ?[]const u8 },
    /// The answer to `fetch` request `key`: status 0 when none came.
    fetched: struct { key: u64, status: u16, body: []const u8, location: ?[]const u8 },
    timeout,
};

pub const Error = error{ InvalidUrl, TooManyInFlight, ConcurrencyUnavailable } || std.mem.Allocator.Error || Io.Cancelable;

const Posted = union(enum) {
    event: struct { key: u64, status: u16, data: ?[]u8, event_id: ?[]u8, retry_ms: ?u32 },
    session: struct { key: u64, id: []u8 },
    opened: u64,
    ended: struct { key: u64, status: u16, how: Ending, challenge: ?[]u8 = null },
    fetched: struct { key: u64, status: u16 = 0, body: ?[]u8 = null, location: ?[]u8 = null },
    wake: u32,

    fn free(p: Posted, gpa: std.mem.Allocator) void {
        switch (p) {
            .event => |e| {
                if (e.data) |d| gpa.free(d);
                if (e.event_id) |i| gpa.free(i);
            },
            .session => |s| gpa.free(s.id),
            .ended => |e| if (e.challenge) |c| gpa.free(c),
            .fetched => |f| {
                if (f.body) |b| gpa.free(b);
                if (f.location) |l| gpa.free(l);
            },
            .opened, .wake => {},
        }
    }
};

const Slot = struct {
    used: bool = false,
    key: u64 = 0,
    arena: std.heap.ArenaAllocator,
    future: Io.Future(void) = undefined,
};

pub const Client = struct {
    io: Io,
    gpa: std.mem.Allocator,
    options: Options,
    uri: std.Uri,
    http: std.http.Client,
    queue: Io.Queue(Posted),
    queue_buffer: [64]Posted = undefined,
    slots: []Slot,
    wakes: Io.Group = .init,
    wake_id: u32 = 0,
    /// What the last `next` returned, freed on the next one.
    held: ?Posted = null,

    /// `options.url` must outlive the client.
    pub fn init(c: *Client, io: Io, gpa: std.mem.Allocator, options: Options) Error!void {
        const slots = try gpa.alloc(Slot, options.max_in_flight);
        for (slots) |*s| s.* = .{ .arena = .init(gpa) };
        c.* = .{
            .io = io,
            .gpa = gpa,
            .options = options,
            .uri = std.Uri.parse(options.url) catch {
                gpa.free(slots);
                return error.InvalidUrl;
            },
            .http = .{ .allocator = gpa, .io = io },
            .queue = undefined,
            .slots = slots,
        };
        c.queue = .init(&c.queue_buffer);
    }

    pub fn deinit(c: *Client) void {
        for (c.slots) |*s| {
            if (s.used) s.future.cancel(c.io);
            s.arena.deinit();
        }
        c.wakes.cancel(c.io);
        c.release();
        // What nobody read.
        var leftover: [1]Posted = undefined;
        while ((c.queue.get(c.io, &leftover, 0) catch 0) == 1) leftover[0].free(c.gpa);
        c.http.deinit();
        c.gpa.free(c.slots);
    }

    /// Sends a request with `body` (POST only) and `headers`, both copied.
    /// `key` names it in what `next` returns.
    pub fn send(c: *Client, key: u64, method: Method, body: ?[]const u8, headers: []const std.http.Header) Error!void {
        const slot = for (c.slots) |*s| {
            if (!s.used) break s;
        } else return error.TooManyInFlight;
        _ = slot.arena.reset(.retain_capacity);
        const a = slot.arena.allocator();
        const all = try a.alloc(std.http.Header, headers.len + c.options.headers.len);
        for (headers, 0..) |h, i| all[i] = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        @memcpy(all[headers.len..], c.options.headers);
        const owned: ?[]u8 = if (body) |b| try a.dupe(u8, b) else null;
        slot.future = c.io.concurrent(exchange, .{ c, key, method, owned, all }) catch return error.ConcurrencyUnavailable;
        slot.used = true;
        slot.key = key;
    }

    /// One request to any `url` (OAuth discovery, registration, tokens), with
    /// `body` and `headers` copied and none of the server's configured headers.
    /// The status, the body up to 1 MiB, and `Location` come back as
    /// `fetched`; redirects aren't followed.
    pub fn fetch(c: *Client, key: u64, method: Method, url: []const u8, body: ?[]const u8, content_type: []const u8, headers: []const std.http.Header) Error!void {
        const slot = for (c.slots) |*s| {
            if (!s.used) break s;
        } else return error.TooManyInFlight;
        _ = slot.arena.reset(.retain_capacity);
        const a = slot.arena.allocator();
        const uri = std.Uri.parse(try a.dupe(u8, url)) catch return error.InvalidUrl;
        const all = try a.alloc(std.http.Header, headers.len);
        for (headers, all) |h, *o| o.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        const owned: ?[]u8 = if (body) |b| try a.dupe(u8, b) else null;
        slot.future = c.io.concurrent(fetchTask, .{ c, key, method, uri, owned, try a.dupe(u8, content_type), all }) catch return error.ConcurrencyUnavailable;
        slot.used = true;
        slot.key = key;
    }

    /// Closes request `key`'s stream, if it is still open. Nothing more comes for it.
    pub fn cancel(c: *Client, key: u64) void {
        for (c.slots) |*s| if (s.used and s.key == key) {
            s.future.cancel(c.io);
            s.used = false;
        };
    }

    /// The next message, mark, or ending, waiting at most `timeout_ms` (forever when null).
    pub fn next(c: *Client, timeout_ms: ?u32) Error!Incoming {
        c.release();
        if (timeout_ms) |ms| {
            c.wake_id +%= 1;
            c.wakes.concurrent(c.io, wakeAfter, .{ c, c.wake_id, ms }) catch return error.ConcurrencyUnavailable;
        }
        while (true) {
            const posted = c.queue.getOne(c.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => unreachable, // the queue is never closed
            };
            if (posted == .wake) {
                if (posted.wake == c.wake_id and timeout_ms != null) return .timeout;
            } else if (c.take(posted)) |incoming| return incoming;
        }
    }

    /// What is already queued, without waiting; null when nothing is.
    pub fn poll(c: *Client) ?Incoming {
        c.release();
        var one: [1]Posted = undefined;
        while ((c.queue.get(c.io, &one, 0) catch 0) == 1) {
            if (one[0] != .wake) if (c.take(one[0])) |incoming| return incoming;
        }
        return null;
    }

    /// What a posted item means to the host; null for one to skip, already freed.
    fn take(c: *Client, posted: Posted) ?Incoming {
        switch (posted) {
            .wake => unreachable,
            .event => |e| {
                if (!c.inFlight(e.key)) {
                    posted.free(c.gpa);
                    return null;
                }
                c.held = posted;
                if (e.data) |data| if (wire.decode(data)) |message| return .{ .message = .{
                    .key = e.key,
                    .status = e.status,
                    .bytes = data,
                    .message = message,
                    .event_id = e.event_id,
                    .retry_ms = e.retry_ms,
                } } else |_| {};
                if (e.event_id == null and e.retry_ms == null) {
                    c.release();
                    return null;
                }
                return .{ .mark = .{ .key = e.key, .event_id = e.event_id, .retry_ms = e.retry_ms } };
            },
            .session => |s| {
                if (!c.inFlight(s.key)) {
                    posted.free(c.gpa);
                    return null;
                }
                c.held = posted;
                return .{ .session = .{ .key = s.key, .id = s.id } };
            },
            .opened => |key| {
                if (!c.inFlight(key)) return null;
                c.held = posted;
                return .{ .opened = key };
            },
            .ended => |e| {
                // A request that was cancelled may still have said it ended.
                if (!c.inFlight(e.key)) {
                    posted.free(c.gpa);
                    return null;
                }
                c.settle(e.key);
                c.held = posted;
                return .{ .ended = .{ .key = e.key, .status = e.status, .how = e.how, .challenge = e.challenge } };
            },
            .fetched => |f| {
                if (!c.inFlight(f.key)) {
                    posted.free(c.gpa);
                    return null;
                }
                c.settle(f.key);
                c.held = posted;
                return .{ .fetched = .{ .key = f.key, .status = f.status, .body = f.body orelse "", .location = f.location } };
            },
        }
    }

    /// The task for `key` is done: its slot is free again.
    fn settle(c: *Client, key: u64) void {
        for (c.slots) |*s| if (s.used and s.key == key) {
            s.future.await(c.io);
            s.used = false;
        };
    }

    fn inFlight(c: *const Client, key: u64) bool {
        for (c.slots) |s| if (s.used and s.key == key) return true;
        return false;
    }

    fn release(c: *Client) void {
        if (c.held) |p| p.free(c.gpa);
        c.held = null;
    }

    fn wakeAfter(c: *Client, id: u32, ms: u32) Io.Cancelable!void {
        try c.io.sleep(.fromMilliseconds(ms), .awake);
        try c.put(.{ .wake = id });
    }

    fn put(c: *Client, posted: Posted) Io.Cancelable!void {
        c.queue.putOne(c.io, posted) catch |err| {
            posted.free(c.gpa);
            return switch (err) {
                error.Canceled => error.Canceled,
                error.Closed => unreachable, // the queue is never closed
            };
        };
        if (posted != .wake) if (c.options.bell) |b| b.ring();
    }

    /// One request, start to end. Every way out says how it ended, except a cancel.
    fn exchange(c: *Client, key: u64, method: Method, body: ?[]u8, headers: []const std.http.Header) void {
        const ending = c.run(key, method, body, headers) catch |err| switch (err) {
            error.Canceled => return,
        };
        c.put(.{ .ended = .{ .key = key, .status = ending.status, .how = ending.how, .challenge = ending.challenge } }) catch {};
    }

    const Result = struct { status: u16 = 0, how: Ending, challenge: ?[]u8 = null };

    /// Bodies are read as sent, so only uncompressed ones are asked for
    /// (`std.http` asks for gzip and deflate by default) and accepted: a
    /// compressed answer fails as unsupported instead of being parsed as
    /// JSON. Asking for identity keeps decompression out of the binary.
    const identity_only = blk: {
        var accept: @FieldType(std.http.Client.Request, "accept_encoding") = @splat(false);
        accept[@intFromEnum(std.http.ContentEncoding.identity)] = true;
        break :blk accept;
    };

    fn run(c: *Client, key: u64, method: Method, body: ?[]u8, headers: []const std.http.Header) Io.Cancelable!Result {
        var req = c.http.request(switch (method) {
            .post => .POST,
            .get => .GET,
            .delete => .DELETE,
        }, c.uri, .{
            .headers = .{ .content_type = if (body != null) .{ .override = "application/json" } else .default, .accept_encoding = .{ .override = "identity" } },
            .extra_headers = headers,
            .redirect_behavior = .unhandled,
        }) catch return .{ .how = .broken };
        defer req.deinit();
        req.accept_encoding = identity_only;
        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            req.sendBodyComplete(b) catch return .{ .how = .broken };
        } else req.sendBodiless() catch return .{ .how = .broken };
        var response = req.receiveHead(&.{}) catch return .{ .how = .broken };
        const status: u16 = @intFromEnum(response.head.status);
        // The head's bytes don't outlive reading the body.
        var challenge: std.ArrayList(u8) = .empty;
        defer challenge.deinit(c.gpa);
        var it = response.head.iterateHeaders();
        var session_seen = false;
        while (it.next()) |h| {
            if (!session_seen and std.ascii.eqlIgnoreCase(h.name, "mcp-session-id")) {
                session_seen = true;
                const id = c.gpa.dupe(u8, h.value) catch return .{ .status = status, .how = .broken };
                try c.put(.{ .session = .{ .key = key, .id = id } });
            } else if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
                if (challenge.items.len > 0) challenge.appendSlice(c.gpa, ", ") catch return .{ .status = status, .how = .broken };
                challenge.appendSlice(c.gpa, h.value) catch return .{ .status = status, .how = .broken };
            }
        }
        if (status == 401 or (status == 403 and challenge.items.len > 0))
            return .{ .status = status, .how = .rejected, .challenge = challenge.toOwnedSlice(c.gpa) catch return .{ .status = status, .how = .broken } };
        if (status == 202) return .{ .status = status, .how = .accepted };
        const content_type = response.head.content_type orelse "";
        var transfer: [64]u8 = undefined;
        const reader = response.reader(&transfer);
        if (std.ascii.startsWithIgnoreCase(content_type, "text/event-stream")) {
            if (status / 100 == 2) try c.put(.{ .opened = key });
            return c.readEvents(key, status, reader);
        }
        // A JSON body: a JSON-RPC answer, or, with no such body, an HTTP failure.
        const bytes = reader.allocRemaining(c.gpa, .limited(c.options.max_message)) catch return .{ .status = status, .how = .broken };
        if (wire.decode(bytes)) |_| {
            try c.put(.{ .event = .{ .key = key, .status = status, .data = bytes, .event_id = null, .retry_ms = null } });
            return .{ .status = status, .how = .complete };
        } else |_| {
            c.gpa.free(bytes);
            return .{ .status = status, .how = .http_failure };
        }
    }

    fn fetchTask(c: *Client, key: u64, method: Method, uri: std.Uri, body: ?[]u8, content_type: []const u8, headers: []const std.http.Header) void {
        const got = c.fetchRun(key, method, uri, body, content_type, headers) catch |err| switch (err) {
            error.Canceled => return,
        };
        c.put(.{ .fetched = got }) catch {};
    }

    fn fetchRun(c: *Client, key: u64, method: Method, uri: std.Uri, body: ?[]u8, content_type: []const u8, headers: []const std.http.Header) Io.Cancelable!@FieldType(Posted, "fetched") {
        const none: @FieldType(Posted, "fetched") = .{ .key = key };
        var req = c.http.request(switch (method) {
            .post => .POST,
            .get => .GET,
            .delete => .DELETE,
        }, uri, .{
            .headers = .{ .content_type = if (body != null) .{ .override = content_type } else .default, .accept_encoding = .{ .override = "identity" } },
            .extra_headers = headers,
            .redirect_behavior = .unhandled,
        }) catch return none;
        defer req.deinit();
        req.accept_encoding = identity_only;
        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
            req.sendBodyComplete(b) catch return none;
        } else req.sendBodiless() catch return none;
        var response = req.receiveHead(&.{}) catch return none;
        var got: @FieldType(Posted, "fetched") = .{ .key = key, .status = @intFromEnum(response.head.status) };
        var it = response.head.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "location")) {
            got.location = c.gpa.dupe(u8, h.value) catch null;
            break;
        };
        var transfer: [64]u8 = undefined;
        got.body = response.reader(&transfer).allocRemaining(c.gpa, .limited(1 << 20)) catch null;
        return got;
    }

    fn readEvents(c: *Client, key: u64, status: u16, reader: *Io.Reader) Io.Cancelable!Result {
        var line: Io.Writer.Allocating = .init(c.gpa);
        defer line.deinit();
        var parser: sse.Parser = .init(c.options.max_message);
        defer parser.deinit(c.gpa);
        while (true) {
            const got = lines.read(reader, &line, c.options.max_message) catch return .{ .status = status, .how = .broken };
            if (got.too_long) return .{ .status = status, .how = .broken };
            const event = parser.line(c.gpa, got.bytes) catch return .{ .status = status, .how = .broken };
            if (event) |e| {
                const data: ?[]u8 = if (e.data) |d| if (d.len > 0) c.gpa.dupe(u8, d) catch return .{ .status = status, .how = .broken } else null else null;
                const event_id: ?[]u8 = if (e.id) |i| c.gpa.dupe(u8, i) catch {
                    if (data) |d| c.gpa.free(d);
                    return .{ .status = status, .how = .broken };
                } else null;
                if (data != null or event_id != null or e.retry_ms != null)
                    try c.put(.{ .event = .{ .key = key, .status = status, .data = data, .event_id = event_id, .retry_ms = e.retry_ms } });
            }
            if (got.at_end) return .{ .status = status, .how = .complete };
        }
    }
};

test {
    // Behavior is tested against real servers by the Bun driver and the
    // conformance suite; this makes sure every declaration compiles.
    std.testing.refAllDecls(Client);
}
