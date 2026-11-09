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
const http_headers = @import("../protocol/http_headers.zig");
const wire = @import("../protocol/wire.zig");
const Budget = @import("budget.zig").Budget;
const Read = @import("budget.zig").Read;

pub const Options = struct {
    url: []const u8,
    /// Headers the host configured for every request, such as an API key.
    headers: []const std.http.Header = &.{},
    /// The largest JSON body or SSE event.
    max_message: usize = 16 * 1024 * 1024,
    max_in_flight: usize = 32,
    /// Rung after each post, for a host that reads many clients.
    bell: ?*Bell = null,
    /// Once the client has sent nothing for this long, the connections it
    /// kept are closed rather than used again: a network can drop one that
    /// sat idle without either end hearing of it, and a request sent on it
    /// would wait out its timeout.
    max_idle_ms: u32 = 60_000,
};

pub const Method = enum { post, get, delete };

pub const Ending = enum {
    /// The body or stream was read to its end.
    complete,
    /// 202 Accepted with no body.
    accepted,
    /// A status with no JSON-RPC message in the body.
    http_failure,
    /// The connection or stream broke.
    broken,
    /// A message was over `max_message`, so the rest of the stream was left
    /// unread. Asking for it again would bring the same message.
    too_large,
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
    /// The answer to `fetch` request `key`: status 0 when none came. `media`
    /// is its Content-Type, "" for none; `challenge` its `WWW-Authenticate`
    /// values, joined.
    fetched: struct { key: u64, status: u16, body: []const u8, location: ?[]const u8, media: []const u8, challenge: ?[]const u8 },
    timeout,
};

pub const Error = error{ InvalidUrl, TooManyInFlight, ConcurrencyUnavailable } || std.mem.Allocator.Error || Io.Cancelable;

const Posted = union(enum) {
    event: struct { key: u64, status: u16, data: ?[]u8, event_id: ?[]u8, retry_ms: ?u32 },
    session: struct { key: u64, id: []u8 },
    opened: u64,
    ended: struct { key: u64, status: u16, how: Ending, challenge: ?[]u8 = null },
    fetched: struct { key: u64, status: u16 = 0, body: ?[]u8 = null, location: ?[]u8 = null, media: ?[]u8 = null, challenge: ?[]u8 = null },

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
                if (f.media) |m| gpa.free(m);
                if (f.challenge) |c| gpa.free(c);
            },
            .opened => {},
        }
    }
};

/// Requests that may wait for a slot past `max_in_flight`. With 32 in
/// flight that is the server's whole request table.
const waiting_room = 32;

/// One request and its copies, from `send` or `fetch` until it ends.
const Slot = struct {
    state: enum { free, waiting, running } = .free,
    key: u64 = 0,
    /// The order requests came in: the oldest waiting one starts first.
    order: u64 = 0,
    arena: std.heap.ArenaAllocator,
    future: Io.Future(void) = undefined,
    method: Method = .post,
    body: ?[]u8 = null,
    headers: []std.http.Header = &.{},
    /// A fetch's URL and content type; null for a request to the server.
    fetch: ?struct { uri: std.Uri, content_type: []u8 } = null,
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
    running: usize = 0,
    sent: u64 = 0,
    /// Rung after each post, as is the shared `bell` if any. `next` waits on
    /// this one, so a timed wait starts no task and never takes a ring meant
    /// for another server.
    own: Bell = undefined,
    /// What the last `next` returned, freed on the next one.
    held: ?Posted = null,
    /// Bytes of messages posted and not yet taken: at most one largest
    /// message, so a fast server waits instead of growing fx.
    budget: Budget,
    /// When a request last started or ended, in the awake clock's
    /// milliseconds; under `used_lock`.
    last_used_ms: i64 = 0,
    used_lock: Io.Mutex = .init,

    /// `options.url` must outlive the client.
    pub fn init(c: *Client, io: Io, gpa: std.mem.Allocator, options: Options) Error!void {
        const slots = try gpa.alloc(Slot, options.max_in_flight + waiting_room);
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
            .budget = .{ .max = options.max_message },
        };
        c.queue = .init(&c.queue_buffer);
        c.own.init(io);
    }

    pub fn deinit(c: *Client) void {
        for (c.slots) |*s| {
            if (s.state == .running) s.future.cancel(c.io);
            s.arena.deinit();
        }
        c.release();
        // What nobody read.
        var leftover: [1]Posted = undefined;
        while ((c.queue.get(c.io, &leftover, 0) catch 0) == 1) leftover[0].free(c.gpa);
        c.http.deinit();
        c.gpa.free(c.slots);
        c.budget.deinit(c.gpa);
    }

    /// Sends a request with `body` (POST only) and `headers`, both copied.
    /// `key` names it in what `next` returns. Past `max_in_flight` it waits
    /// for one to end, in order.
    pub fn send(c: *Client, key: u64, method: Method, body: ?[]const u8, headers: []const std.http.Header) Error!void {
        const slot = try c.claim(key, method);
        errdefer slot.state = .free;
        const a = slot.arena.allocator();
        const all = try a.alloc(std.http.Header, headers.len + c.options.headers.len);
        for (headers, 0..) |h, i| all[i] = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        @memcpy(all[headers.len..], c.options.headers);
        slot.headers = all;
        slot.body = if (body) |b| try a.dupe(u8, b) else null;
        if (c.running < c.options.max_in_flight) try c.start(slot);
    }

    /// One request to any `url` (OAuth discovery, registration, tokens), with
    /// `body` and `headers` copied and none of the server's configured headers.
    /// The status, the body up to 1 MiB, and `Location` come back as
    /// `fetched`; redirects aren't followed.
    pub fn fetch(c: *Client, key: u64, method: Method, url: []const u8, body: ?[]const u8, content_type: []const u8, headers: []const std.http.Header) Error!void {
        const slot = try c.claim(key, method);
        errdefer slot.state = .free;
        const a = slot.arena.allocator();
        const uri = std.Uri.parse(try a.dupe(u8, url)) catch return error.InvalidUrl;
        const all = try a.alloc(std.http.Header, headers.len);
        for (headers, all) |h, *o| o.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        slot.headers = all;
        slot.body = if (body) |b| try a.dupe(u8, b) else null;
        slot.fetch = .{ .uri = uri, .content_type = try a.dupe(u8, content_type) };
        if (c.running < c.options.max_in_flight) try c.start(slot);
    }

    /// A free slot for request `key`, its arena emptied, waiting to start.
    fn claim(c: *Client, key: u64, method: Method) Error!*Slot {
        const slot = for (c.slots) |*s| {
            if (s.state == .free) break s;
        } else return error.TooManyInFlight;
        _ = slot.arena.reset(.retain_capacity);
        c.sent += 1;
        slot.* = .{ .state = .waiting, .key = key, .order = c.sent, .method = method, .arena = slot.arena };
        return slot;
    }

    fn start(c: *Client, slot: *Slot) error{ConcurrencyUnavailable}!void {
        slot.future = c.io.concurrent(task, .{ c, slot }) catch return error.ConcurrencyUnavailable;
        slot.state = .running;
        c.running += 1;
    }

    fn task(c: *Client, slot: *const Slot) void {
        if (slot.fetch) |f|
            c.fetchTask(slot.key, slot.method, f.uri, slot.body, f.content_type, slot.headers)
        else
            c.exchange(slot.key, slot.method, slot.body, slot.headers);
    }

    /// A request ended: the oldest waiting one takes its place. One that
    /// can't be started waits for the next.
    fn startWaiting(c: *Client) void {
        if (c.running >= c.options.max_in_flight) return;
        var oldest: ?*Slot = null;
        for (c.slots) |*s| {
            if (s.state == .waiting and (oldest == null or s.order < oldest.?.order)) oldest = s;
        }
        if (oldest) |s| c.start(s) catch {};
    }

    /// Closes request `key`'s stream, if it is still open. Nothing more comes for it.
    pub fn cancel(c: *Client, key: u64) void {
        for (c.slots) |*s| if (s.state != .free and s.key == key) {
            // One still waiting never went out.
            if (s.state == .running) {
                s.future.cancel(c.io);
                c.running -= 1;
            }
            s.state = .free;
        };
        c.startWaiting();
    }

    /// The next message, mark, or ending, waiting at most `timeout_ms` (forever when null).
    pub fn next(c: *Client, timeout_ms: ?u32) Error!Incoming {
        const deadline = if (timeout_ms) |ms| now(c.io) + ms else null;
        while (true) {
            if (c.poll()) |incoming| return incoming;
            const left: ?u32 = if (deadline) |d| @intCast(@max(0, d - now(c.io))) else null;
            if (left == 0) return .timeout;
            try c.own.wait(left);
        }
    }

    /// What is already queued, without waiting; null when nothing is.
    pub fn poll(c: *Client) ?Incoming {
        c.release();
        var one: [1]Posted = undefined;
        while ((c.queue.get(c.io, &one, 0) catch 0) == 1) {
            c.giveBack(one[0]);
            if (c.take(one[0])) |incoming| return incoming;
        }
        return null;
    }

    /// What a posted item means to the host; null for one to skip, already freed.
    fn take(c: *Client, posted: Posted) ?Incoming {
        switch (posted) {
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
                return .{ .fetched = .{ .key = f.key, .status = f.status, .body = f.body orelse "", .location = f.location, .media = f.media orelse "", .challenge = f.challenge } };
            },
        }
    }

    /// The task for `key` is done: its slot is free again.
    fn settle(c: *Client, key: u64) void {
        for (c.slots) |*s| if (s.state == .running and s.key == key) {
            s.future.await(c.io);
            s.state = .free;
            c.running -= 1;
        };
        c.startWaiting();
    }

    fn inFlight(c: *const Client, key: u64) bool {
        for (c.slots) |s| if (s.state == .running and s.key == key) return true;
        return false;
    }

    fn release(c: *Client) void {
        if (c.held) |held| {
            var rest = held;
            // An event's data buffer is kept for the next.
            switch (rest) {
                .event => |*e| if (e.data) |d| {
                    c.budget.recycle(c.io, c.gpa, d);
                    e.data = null;
                },
                else => {},
            }
            rest.free(c.gpa);
        }
        c.held = null;
    }

    /// The budget's share of `posted`: its message's bytes.
    fn giveBack(c: *Client, posted: Posted) void {
        switch (posted) {
            .event => |e| if (e.data) |d| c.budget.give(c.io, d.len),
            else => {},
        }
    }

    fn put(c: *Client, posted: Posted) Io.Cancelable!void {
        c.queue.putOne(c.io, posted) catch |err| {
            c.giveBack(posted);
            posted.free(c.gpa);
            return switch (err) {
                error.Canceled => error.Canceled,
                error.Closed => unreachable, // the queue is never closed
            };
        };
        c.own.ring();
        if (c.options.bell) |b| b.ring();
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
        accept[@backingInt(std.http.ContentEncoding.identity)] = true;
        break :blk accept;
    };

    fn run(c: *Client, key: u64, method: Method, body: ?[]u8, headers: []const std.http.Header) Io.Cancelable!Result {
        // One that can't go out as it is never does: nothing takes it.
        if (!http_headers.sendable(headers)) return .{ .how = .http_failure };
        defer _ = c.markUsed();
        var req = (try c.openSent(method, c.uri, .{
            .headers = .{ .content_type = if (body != null) .{ .override = "application/json" } else .default, .accept_encoding = .{ .override = "identity" } },
            .extra_headers = headers,
            .redirect_behavior = .unhandled,
        }, body)) orelse return .{ .how = .broken };
        defer req.deinit();
        var response = req.receiveHead(&.{}) catch return .{ .how = .broken };
        const status: u16 = @backingInt(response.head.status);
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
        // A JSON-RPC answer comes as application/json; any other body is an
        // HTTP failure, whatever it holds.
        if (!isJson(content_type)) return .{ .status = status, .how = .http_failure };
        // The body is counted as it is read and posted as it is.
        var read: Read = .{};
        var answer: std.ArrayList(u8) = .empty;
        defer {
            c.budget.drop(c.io, &read);
            answer.deinit(c.gpa);
        }
        c.readBody(reader, &read, &answer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.TooLong => return .{ .status = status, .how = .too_large },
            error.ReadFailed, error.OutOfMemory => return .{ .status = status, .how = .broken },
        };
        if (wire.decode(answer.items)) |message| {
            // A result says it worked, so one under an error status
            // contradicts itself. An error under one is read: a 400
            // carries a version mismatch (VER-04).
            if (status / 100 != 2 and message == .response and message.response.body == .result)
                return .{ .status = status, .how = .http_failure };
            const len = answer.items.len;
            try c.budget.post(c.io, &read, len);
            const bytes = answer.toOwnedSlice(c.gpa) catch {
                c.budget.give(c.io, len);
                return .{ .status = status, .how = .broken };
            };
            try c.put(.{ .event = .{ .key = key, .status = status, .data = bytes, .event_id = null, .retry_ms = null } });
            return .{ .status = status, .how = .complete };
        } else |_| {
            return .{ .status = status, .how = .http_failure };
        }
    }

    /// Opens `method` on `uri`, on a connection kept for its server or a new
    /// one, and sends `body`. A send that fails never brought the server the
    /// whole request, so it is made once more, on a new connection; and the
    /// connection it failed on is closed, where `std.http` would keep it for
    /// the next request to fail on too. Null when it couldn't go out.
    fn openSent(c: *Client, method: Method, uri: std.Uri, options: std.http.Client.RequestOptions, body: ?[]u8) Io.Cancelable!?std.http.Client.Request {
        var fresh = false;
        while (true) {
            var with = options;
            with.connection = try c.takeKept(uri, fresh);
            var req = c.http.request(switch (method) {
                .post => .POST,
                .get => .GET,
                .delete => .DELETE,
            }, uri, with) catch {
                if (with.connection) |kept| c.http.connection_pool.release(kept, c.io);
                return null;
            };
            req.accept_encoding = identity_only;
            const sending = if (body) |b| send: {
                req.transfer_encoding = .{ .content_length = b.len };
                break :send req.sendBodyComplete(b);
            } else req.sendBodiless();
            sending catch {
                req.connection.?.closing = true;
                req.deinit();
                if (fresh) return null;
                fresh = true;
                continue;
            };
            return req;
        }
    }

    /// A connection kept for `uri`'s server, taken from the pool, or null for
    /// a new one. Those kept that the server closed or reset while they sat
    /// idle are closed here, before anything is sent on them, and so is
    /// every one kept when `fresh` is set or the client sat idle past
    /// `max_idle_ms`.
    fn takeKept(c: *Client, uri: std.Uri, fresh: bool) Io.Cancelable!?*std.http.Client.Connection {
        // Through a proxy, `std.http` finds its own.
        if (c.http.http_proxy != null or c.http.https_proxy != null) return null;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
        var host: [Io.net.HostName.max_len]u8 = undefined;
        const criteria: std.http.Client.ConnectionPool.Criteria = .{
            .host = Io.net.HostName.fromUri(uri, &host) catch return null,
            .port = uri.port orelse switch (protocol) {
                .plain => 80,
                .tls => 443,
            },
            .protocol = protocol,
        };
        const stale = fresh or c.markUsed() > c.options.max_idle_ms;
        const pool = &c.http.connection_pool;
        while (try pool.findConnection(c.io, criteria)) |kept| {
            if (!stale and !closedByServer(kept)) return kept;
            kept.closing = true;
            pool.release(kept, c.io);
        }
        return null;
    }

    /// Notes that a request starts or ends now, and returns how long none
    /// had before.
    fn markUsed(c: *Client) i64 {
        const at = now(c.io);
        c.used_lock.lockUncancelable(c.io);
        defer c.used_lock.unlock(c.io);
        const idle = at - c.last_used_ms;
        c.last_used_ms = at;
        return idle;
    }

    /// Reads a JSON body into `body` a step at a time, counting each step
    /// before it is read. One past `max_message` is `TooLong`.
    fn readBody(c: *Client, reader: *Io.Reader, read: *Read, body: *std.ArrayList(u8)) (Io.Cancelable || error{ TooLong, ReadFailed, OutOfMemory })!void {
        var adopted = false;
        while (true) {
            if (body.items.len == c.options.max_message) {
                _ = reader.peekByte() catch |err| switch (err) {
                    error.EndOfStream => return,
                    error.ReadFailed => return error.ReadFailed,
                };
                return error.TooLong;
            }
            const step = @min(c.budget.allowance, c.options.max_message - body.items.len);
            try c.budget.grow(c.io, read, body.items.len + step);
            if (read.large and !adopted) {
                c.budget.adopt(c.io, c.gpa, body);
                adopted = true;
            }
            try body.ensureUnusedCapacity(c.gpa, step);
            const n = reader.readSliceShort(body.unusedCapacitySlice()[0..step]) catch return error.ReadFailed;
            body.items.len += n;
            if (n < step) return;
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
        if (!http_headers.sendable(headers)) return none;
        defer _ = c.markUsed();
        var req = (try c.openSent(method, uri, .{
            .headers = .{ .content_type = if (body != null) .{ .override = content_type } else .default, .accept_encoding = .{ .override = "identity" } },
            .extra_headers = headers,
            .redirect_behavior = .unhandled,
        }, body)) orelse return none;
        defer req.deinit();
        var response = req.receiveHead(&.{}) catch return none;
        var got: @FieldType(Posted, "fetched") = .{ .key = key, .status = @backingInt(response.head.status) };
        var challenge: std.ArrayList(u8) = .empty;
        defer challenge.deinit(c.gpa);
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (got.location == null and std.ascii.eqlIgnoreCase(h.name, "location")) {
                got.location = c.gpa.dupe(u8, h.value) catch null;
            } else if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
                if (challenge.items.len > 0) challenge.appendSlice(c.gpa, ", ") catch {};
                challenge.appendSlice(c.gpa, h.value) catch {};
            }
        }
        if (challenge.items.len > 0) got.challenge = challenge.toOwnedSlice(c.gpa) catch null;
        // The head's bytes don't outlive reading the body.
        if (response.head.content_type) |media| got.media = c.gpa.dupe(u8, media) catch null;
        var transfer: [64]u8 = undefined;
        got.body = response.reader(&transfer).allocRemaining(c.gpa, .limited(1 << 20)) catch null;
        return got;
    }

    /// Counts an event's buffer as it grows, a step of the allowance at a
    /// time, and gives a large one the spare.
    const Counter = struct {
        c: *Client,
        read: *Read,
        data: *std.ArrayList(u8),
        adopted: bool = false,

        pub fn grow(n: *Counter, held: usize) Io.Cancelable!void {
            if (held <= n.read.held) return;
            const step = n.c.budget.allowance;
            try n.c.budget.grow(n.c.io, n.read, @min(@divCeil(held, step) * step, n.c.options.max_message));
            if (n.read.large and !n.adopted) {
                n.c.budget.adopt(n.c.io, n.c.gpa, n.data);
                n.adopted = true;
            }
        }
    };

    fn readEvents(c: *Client, key: u64, status: u16, reader: *Io.Reader) Io.Cancelable!Result {
        var parser: sse.Parser = .{};
        defer parser.deinit(c.gpa);
        // Each line is read onto the end of the event's buffer, which is
        // counted as it grows and posted as it is.
        var data: std.ArrayList(u8) = .empty;
        var read: Read = .{};
        var counter: Counter = .{ .c = c, .read = &read, .data = &data };
        defer {
            c.budget.drop(c.io, &read);
            data.deinit(c.gpa);
        }
        var stream: lines.SseLines = .{};
        while (true) {
            const mark = data.items.len;
            const got = stream.read(reader, c.gpa, &data, c.options.max_message, &counter) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.ReadFailed, error.OutOfMemory => return .{ .status = status, .how = .broken },
            };
            if (got.too_long) return .{ .status = status, .how = .too_large };
            const event = parser.line(c.gpa, &data, mark) catch return .{ .status = status, .how = .broken };
            if (event) |e| {
                const event_id: ?[]u8 = if (e.id) |i| c.gpa.dupe(u8, i) catch return .{ .status = status, .how = .broken } else null;
                var posted: ?[]u8 = null;
                if (e.data != null and data.items.len > 0) {
                    const len = data.items.len;
                    c.budget.post(c.io, &read, len) catch |err| {
                        if (event_id) |i| c.gpa.free(i);
                        return err;
                    };
                    counter.adopted = false;
                    posted = data.toOwnedSlice(c.gpa) catch {
                        c.budget.give(c.io, len);
                        if (event_id) |i| c.gpa.free(i);
                        return .{ .status = status, .how = .broken };
                    };
                } else data.clearRetainingCapacity();
                if (posted != null or event_id != null or e.retry_ms != null)
                    try c.put(.{ .event = .{ .key = key, .status = status, .data = posted, .event_id = event_id, .retry_ms = e.retry_ms } });
            }
            // A buffer that holds no data doesn't keep the large read, or
            // the memory it counted.
            if (read.large and data.items.len == 0) {
                c.budget.drop(c.io, &read);
                data.clearAndFree(c.gpa);
                counter.adopted = false;
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

fn now(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}

/// Whether the server closed or reset a kept connection while it sat idle.
/// Nothing is due on one between requests, so anything to read, its end
/// included, means it can't carry another.
fn closedByServer(kept: *std.http.Client.Connection) bool {
    if (kept.reader().bufferedLen() > 0 or kept.stream_reader.interface.bufferedLen() > 0) return true;
    var ready = [_]std.posix.pollfd{.{ .fd = kept.stream_reader.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    return (std.posix.poll(&ready, 0) catch return true) > 0;
}

/// A Content-Type naming JSON, with any parameters such as `charset`.
pub fn isJson(media: []const u8) bool {
    const end = std.mem.findScalar(u8, media, ';') orelse media.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, media[0..end], " \t"), "application/json");
}

const testing = std.testing;

test "only application/json, with or without parameters, is JSON" {
    for ([_][]const u8{ "application/json", "Application/JSON", "application/json; charset=utf-8", "application/json;charset=UTF-8" }) |m| try testing.expect(isJson(m));
    for ([_][]const u8{ "", "text/plain", "text/json", "application/json-rpc", "application/jsonx", "text/event-stream" }) |m| try testing.expect(!isJson(m));
}

test "a header that can't go out as it is never does, and the request ends refused" {
    // Nothing listens on port 1, so a request that does go out breaks.
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:1/mcp" });
    defer c.deinit();
    for ([_][]const u8{ "a\r\nb", "a\nInjected: yes" }, 1..) |value, key| {
        try c.send(key, .post, "{}", &.{.{ .name = "X-Team", .value = value }});
        try testing.expectEqual(Ending.http_failure, (try c.next(10_000)).ended.how);
    }
    try c.send(3, .post, "{}", &.{.{ .name = "X-Team", .value = "a b\tc" }});
    try testing.expectEqual(Ending.broken, (try c.next(10_000)).ended.how);
    // A sign-in request is refused too: there, CR LF would abort in `std.http`.
    try c.fetch(4, .post, "http://127.0.0.1:1/token", "x", "text/plain", &.{.{ .name = "X-Team", .value = "a\r\nb" }});
    try testing.expectEqual(@as(u16, 0), (try c.next(10_000)).fetched.status);
}

test "a request past the slots waits for one, oldest first, and one cancelled while it waits never goes out" {
    // Nothing listens on port 1, so each request ends as soon as it goes out.
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:1/mcp", .max_in_flight = 1 });
    defer c.deinit();
    for (1..5) |key| try c.send(key, .post, "{}", &.{});
    c.cancel(3);
    for ([_]u64{ 1, 2, 4 }) |key| try testing.expectEqual(key, (try c.next(10_000)).ended.key);
    try testing.expect((try c.next(200)) == .timeout);
    // Cancelling the one in flight lets the next one in.
    try c.send(5, .post, "{}", &.{});
    try c.send(6, .post, "{}", &.{});
    c.cancel(5);
    try testing.expectEqual(@as(u64, 6), (try c.next(10_000)).ended.key);
}

test "a request's end wakes a timed wait at once, with or without a shared bell" {
    // With one, as when the engine closes a server, the shared bell rings too.
    var shared: Bell = undefined;
    shared.init(testing.io);
    for ([_]?*Bell{ null, &shared }) |bell| {
        var c: Client = undefined;
        try c.init(testing.io, testing.allocator, .{ .url = "http://127.0.0.1:1/mcp", .bell = bell });
        defer c.deinit();
        const started = now(testing.io);
        try c.send(1, .post, "{}", &.{});
        try testing.expectEqual(Ending.broken, (try c.next(10_000)).ended.how);
        try testing.expect(now(testing.io) - started < 3_000);
    }
    try testing.expect(shared.rung);
}

/// Answers one request on `server` with `count` SSE notifications of 45
/// bytes, then the response, and closes.
fn serveEvents(server: *Io.net.Server, count: usize) !void {
    const stream = try server.accept(testing.io);
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    try w.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n");
    for (0..count) |_| try w.interface.writeAll("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/n\"}\n\n");
    try w.interface.writeAll("data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n");
    try w.interface.flush();
}

/// Answers one request on `server` with `body` as `content_type`, and closes.
fn serveBody(server: *Io.net.Server, content_type: []const u8, body: []const u8) !void {
    const stream = try server.accept(testing.io);
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    try w.interface.print("HTTP/1.1 200 OK\r\ncontent-type: {s}\r\nconnection: close\r\n\r\n", .{content_type});
    try w.interface.writeAll(body);
    try w.interface.flush();
}

test "an answer over max_message ends too_large, not broken, in a JSON body and in an SSE event" {
    const pad: [200]u8 = @splat('x');
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"t\":\"" ++ pad ++ "\"}}";
    const Case = struct { content_type: []const u8, body: []const u8 };
    for ([_]Case{
        .{ .content_type = "application/json", .body = json },
        .{ .content_type = "text/event-stream", .body = "id: e1\ndata: " ++ json ++ "\n\n" },
    }) |case| {
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try address.listen(testing.io, .{ .reuse_address = true });
        defer server.deinit(testing.io);
        var serving = try testing.io.concurrent(serveBody, .{ &server, case.content_type, case.body });
        defer serving.cancel(testing.io) catch {};
        var url: [64]u8 = undefined;
        var c: Client = undefined;
        try c.init(testing.io, testing.allocator, .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}), .max_message = 64 });
        defer c.deinit();
        try c.send(1, .post, "{}", &.{});
        while (true) switch (try c.next(5_000)) {
            .ended => |e| {
                try testing.expectEqual(Ending.too_large, e.how);
                break;
            },
            .timeout => return error.TestTimeout,
            else => {},
        };
    }
}

test "events past the budget all arrive, each once the one before it is taken" {
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var serving = try testing.io.concurrent(serveEvents, .{ &server, 6 });
    defer serving.cancel(testing.io) catch {};
    var url: [64]u8 = undefined;
    var c: Client = undefined;
    // Six events of 45 bytes against a 64-byte budget: each waits for room.
    try c.init(testing.io, testing.allocator, .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}), .max_message = 64 });
    defer c.deinit();
    try c.send(1, .post, "{}", &.{});
    var notes: usize = 0;
    while (true) switch (try c.next(5_000)) {
        .message => |m| if (m.message == .notification) {
            notes += 1;
        },
        .ended => |e| {
            try testing.expectEqual(Ending.complete, e.how);
            break;
        },
        .timeout => return error.TestTimeout,
        else => {},
    };
    try testing.expectEqual(@as(usize, 6), notes);
    try testing.expect(c.budget.used <= 64);
}

/// Counts the bytes an allocator has live, and the most it had at once.
const Peak = struct {
    child: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(p: *Peak) std.mem.Allocator {
        return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grew(p: *Peak, old: usize, new: usize) void {
        if (new >= old) {
            const total = p.live.fetchAdd(new - old, .monotonic) + new - old;
            _ = p.peak.fetchMax(total, .monotonic);
        } else _ = p.live.fetchSub(old - new, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        const out = p.child.rawAlloc(len, a, ra) orelse return null;
        p.grew(0, len);
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        if (!p.child.rawResize(memory, a, new_len, ra)) return false;
        p.grew(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        const out = p.child.rawRemap(memory, a, new_len, ra) orelse return null;
        p.grew(memory.len, new_len);
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, ra: usize) void {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        p.child.rawFree(memory, a, ra);
        p.grew(memory.len, 0);
    }
};

fn answerOne(stream: Io.net.Stream, size: usize, events: bool) !void {
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [4096]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    const head = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"x\":\"";
    const tail = "\"}}";
    if (events) {
        try w.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n: one large event\ndata: ");
    } else {
        try w.interface.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{size});
    }
    try w.interface.writeAll(head);
    try w.interface.splatByteAll('a', size - head.len - tail.len);
    try w.interface.writeAll(tail);
    if (events) try w.interface.writeAll("\n\n");
    try w.interface.flush();
}

/// Answers `count` requests at once, each with a JSON body of `size` bytes,
/// or one event that carries it.
fn serveAnswers(server: *Io.net.Server, count: usize, size: usize, events: bool) !void {
    var answering: [16]?Io.Future(@typeInfo(@TypeOf(answerOne)).@"fn".return_type.?) = @splat(null);
    defer for (&answering) |*a| if (a.*) |*f| f.cancel(testing.io) catch {};
    for (answering[0..count]) |*a| a.* = try testing.io.concurrent(answerOne, .{ try server.accept(testing.io), size, events });
    for (answering[0..count]) |*a| {
        try a.*.?.await(testing.io);
        a.* = null;
    }
}

fn manyLargeAnswers(events: bool) !void {
    const count = 16;
    const size = 200 * 1024;
    const max = 256 * 1024;
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var serving = try testing.io.concurrent(serveAnswers, .{ &server, count, size, events });
    defer serving.cancel(testing.io) catch {};
    var peak: Peak = .{ .child = testing.allocator };
    var url: [64]u8 = undefined;
    var c: Client = undefined;
    try c.init(testing.io, peak.allocator(), .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}), .max_message = max });
    defer c.deinit();
    c.budget.allowance = 4 * 1024;
    for (1..count + 1) |key| try c.send(key, .post, "{}", &.{});
    // Nothing is taken for a while: every reader reads what it may.
    try Io.sleep(testing.io, .fromMilliseconds(500), .awake);
    var answers: usize = 0;
    var ended: usize = 0;
    while (ended < count) switch (try c.next(10_000)) {
        .message => |m| if (m.message == .response) {
            answers += 1;
        },
        .ended => |e| {
            try testing.expectEqual(Ending.complete, e.how);
            ended += 1;
        },
        .timeout => return error.TestTimeout,
        else => {},
    };
    try testing.expectEqual(@as(usize, count), answers);
    // What the budget counts, the spare, each reader's allowance, growth
    // slack, and the client's own buffers: set by `max`, not by how many
    // answers come at once.
    try testing.expect(peak.peak.load(.monotonic) < count * size / 2);
}

test "many large answers at once are read within the budget, one large read at a time" {
    // About 0.9 MiB here, and 3.5 MiB before D178.
    try manyLargeAnswers(false);
}

test "many large events at once are read into one buffer each, within the budget" {
    try manyLargeAnswers(true);
}

fn hangAfterComment(stream: Io.net.Stream) !void {
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    while ((try r.interface.takeDelimiterInclusive('\n')).len > 2) {}
    var out: [4096]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    try w.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n: ");
    try w.interface.splatByteAll('c', 20 * 1024);
    try w.interface.writeAll("\n");
    try w.interface.flush();
    try Io.sleep(testing.io, .fromSeconds(30), .awake);
}

/// One stream sends a large comment and stays open; the next, one large event.
fn serveCommentThenEvent(server: *Io.net.Server) !void {
    var hanging = try testing.io.concurrent(hangAfterComment, .{try server.accept(testing.io)});
    defer hanging.cancel(testing.io) catch {};
    try answerOne(try server.accept(testing.io), 200 * 1024, true);
    // The comment's stream stays open until the test ends.
    try Io.sleep(testing.io, .fromSeconds(30), .awake);
}

test "a large comment doesn't keep the large read from the next large event" {
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var serving = try testing.io.concurrent(serveCommentThenEvent, .{&server});
    defer serving.cancel(testing.io) catch {};
    var url: [64]u8 = undefined;
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = try std.mem.print(&url, "http://127.0.0.1:{d}/mcp", .{server.socket.address.getPort()}), .max_message = 256 * 1024 });
    defer c.deinit();
    c.budget.allowance = 4 * 1024;
    try c.send(1, .post, "{}", &.{});
    // The comment is read, past the allowance, and cut.
    try Io.sleep(testing.io, .fromMilliseconds(200), .awake);
    try c.send(2, .post, "{}", &.{});
    while (true) switch (try c.next(5_000)) {
        .message => |m| if (m.message == .response) break,
        .timeout => return error.TestTimeout,
        else => {},
    };
}

test "a timed wait starts no task, so it works where none can run" {
    var threaded: Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var c: Client = undefined;
    try c.init(threaded.io(), testing.allocator, .{ .url = "http://127.0.0.1:1/mcp" });
    defer c.deinit();
    try testing.expect((try c.next(20)) == .timeout);
}

/// What a test server does to each connection once it has answered on it.
const Drop = enum { keep, reset, close };

/// Reads one request on `r`, head and body, so none is left unread when the
/// connection closes: a close with unread bytes is a reset.
fn readRequest(r: *Io.Reader) !void {
    const name = "content-length:";
    var length: usize = 0;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        if (line.len <= 2) break;
        if (std.ascii.startsWithIgnoreCase(line, name)) length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[name.len..], " \r\n"), 10);
    }
    try r.discardAll(length);
}

/// Answers each request on `stream` with a result, keeping the connection
/// for the next, until `drop` ends it after the first answer. One the client
/// ends is held open, unanswered, until the test does.
fn answerKept(stream: Io.net.Stream, drop: Drop, requests: *std.atomic.Value(u32)) !void {
    defer stream.close(testing.io);
    var in: [4096]u8 = undefined;
    var r = stream.reader(testing.io, &in);
    var out: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &out);
    const answer = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    while (true) {
        readRequest(&r.interface) catch return Io.sleep(testing.io, .fromSeconds(30), .awake);
        _ = requests.fetchAdd(1, .monotonic);
        try w.interface.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n", .{answer.len});
        try w.interface.writeAll(answer);
        try w.interface.flush();
        switch (drop) {
            .keep => {},
            .close => return,
            .reset => {
                // Once the client has read the answer: a reset, not an end.
                try Io.sleep(testing.io, .fromMilliseconds(50), .awake);
                try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&std.posix.linger{ .onoff = 1, .linger = 0 }));
                return;
            },
        }
    }
}

fn serveKept(server: *Io.net.Server, drop: Drop, connections: *std.atomic.Value(u32), requests: *std.atomic.Value(u32)) !void {
    var answering: [4]?Io.Future(@typeInfo(@TypeOf(answerKept)).@"fn".return_type.?) = @splat(null);
    defer for (&answering) |*a| if (a.*) |*f| f.cancel(testing.io) catch {};
    for (&answering) |*a| {
        const stream = try server.accept(testing.io);
        _ = connections.fetchAdd(1, .monotonic);
        a.* = try testing.io.concurrent(answerKept, .{ stream, drop, requests });
    }
    try Io.sleep(testing.io, .fromSeconds(30), .awake);
}

/// A server that keeps connections alive, counting them and the requests on
/// them. It must not move once started.
const Kept = struct {
    server: Io.net.Server,
    connections: std.atomic.Value(u32) = .init(0),
    requests: std.atomic.Value(u32) = .init(0),
    serving: ?Io.Future(@typeInfo(@TypeOf(serveKept)).@"fn".return_type.?) = null,
    url_buffer: [64]u8 = undefined,
    url: []const u8 = "",

    fn start(k: *Kept, drop: Drop) !void {
        var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        k.* = .{ .server = try address.listen(testing.io, .{ .reuse_address = true }) };
        k.url = try std.mem.print(&k.url_buffer, "http://127.0.0.1:{d}/mcp", .{k.server.socket.address.getPort()});
        k.serving = try testing.io.concurrent(serveKept, .{ &k.server, drop, &k.connections, &k.requests });
    }

    fn stop(k: *Kept) void {
        if (k.serving) |*f| f.cancel(testing.io) catch {};
        k.server.deinit(testing.io);
    }
};

/// How the request `c` sent last ended, past its messages.
fn endingOf(c: *Client) !Ending {
    while (true) switch (try c.next(5_000)) {
        .ended => |e| return e.how,
        .timeout => return error.TestTimeout,
        else => {},
    };
}

fn fetchedStatus(c: *Client) !u16 {
    while (true) switch (try c.next(5_000)) {
        .fetched => |f| return f.status,
        .timeout => return error.TestTimeout,
        else => {},
    };
}

test "a kept connection the server reset or closed while idle isn't sent on again: each request goes out once, on a new one" {
    for ([_]Drop{ .reset, .close }) |drop| {
        var kept: Kept = undefined;
        try kept.start(drop);
        defer kept.stop();
        var c: Client = undefined;
        try c.init(testing.io, testing.allocator, .{ .url = kept.url });
        defer c.deinit();
        try c.send(1, .post, "{}", &.{});
        try testing.expectEqual(Ending.complete, try endingOf(&c));
        // The server drops each connection after one answer, so the next
        // request and the sign-in request after it find theirs gone.
        try Io.sleep(testing.io, .fromMilliseconds(300), .awake);
        try c.send(2, .post, "{}", &.{});
        try testing.expectEqual(Ending.complete, try endingOf(&c));
        try Io.sleep(testing.io, .fromMilliseconds(300), .awake);
        try c.fetch(3, .post, kept.url, "{}", "application/json", &.{});
        try testing.expectEqual(@as(u16, 200), try fetchedStatus(&c));
        try testing.expectEqual(@as(u32, 3), kept.connections.load(.monotonic));
        try testing.expectEqual(@as(u32, 3), kept.requests.load(.monotonic));
    }
}

test "a request whose send fails goes out once more, on a new connection, and reaches the server once" {
    var kept: Kept = undefined;
    try kept.start(.keep);
    defer kept.stop();
    var c: Client = undefined;
    try c.init(testing.io, testing.allocator, .{ .url = kept.url });
    defer c.deinit();
    try c.send(1, .post, "{}", &.{});
    try testing.expectEqual(Ending.complete, try endingOf(&c));
    // The connection kept for the next request can't send any more, and
    // nothing says so until a send on it fails.
    const node = c.http.connection_pool.free.last orelse return error.TestUnexpectedResult;
    const connection: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
    try connection.stream_reader.stream.shutdown(testing.io, .send);
    try c.send(2, .post, "{}", &.{});
    try testing.expectEqual(Ending.complete, try endingOf(&c));
    try testing.expectEqual(@as(u32, 2), kept.connections.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), kept.requests.load(.monotonic));
}

test "a kept connection is used again, unless the client sat idle past max_idle_ms" {
    for ([_]u32{ 60_000, 0 }, [_]u32{ 1, 2 }) |max_idle_ms, connections| {
        var kept: Kept = undefined;
        try kept.start(.keep);
        defer kept.stop();
        var c: Client = undefined;
        try c.init(testing.io, testing.allocator, .{ .url = kept.url, .max_idle_ms = max_idle_ms });
        defer c.deinit();
        for (1..3) |key| {
            try c.send(key, .post, "{}", &.{});
            try testing.expectEqual(Ending.complete, try endingOf(&c));
            try Io.sleep(testing.io, .fromMilliseconds(20), .awake);
        }
        try testing.expectEqual(connections, kept.connections.load(.monotonic));
        try testing.expectEqual(@as(u32, 2), kept.requests.load(.monotonic));
    }
}
