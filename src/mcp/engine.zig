//! The engine: every configured server, each started only when something
//! needs it (LazyConnect), the host's permission before every tool call,
//! and one stream of events for the host. Each server is a
//! `server.zig` Server behind its `core/engine.zig` gate. It is created on
//! first use and kept until the host reloads without it, so its process
//! outlives any one task or conversation. The host calls
//! everything from one thread; only `wake` may come from another.

const std = @import("std");
const core = @import("core/engine.zig");
const era = @import("core/era.zig");
const request = @import("core/request.zig");
const server_mod = @import("server.zig");
const tools = @import("protocol/tools.zig");
const mrtr = @import("protocol/mrtr.zig");
const wire = @import("protocol/wire.zig");
const elicitation = @import("protocol/elicitation.zig");
const auth_client = @import("auth/client.zig");
const trace = @import("io/trace.zig");
const Bell = @import("io/bell.zig").Bell;
const Host = @import("host.zig").Host;

pub const Phase = core.Phase;
pub const Handle = core.Handle;

pub const Transport = union(enum) {
    /// `environ_map` is the host's and must outlive the engine.
    stdio: struct { argv: []const []const u8, environ_map: ?*const std.process.Environ.Map = null },
    http: struct { url: []const u8, headers: []const std.http.Header = &.{} },
};

/// One server as the host resolved it; the engine reads no config files.
pub const Config = struct {
    name: []const u8,
    transport: Transport,
    auth: auth_client.Options = .{},
};

pub const Options = struct {
    client: era.Client,
    era: era.Config = .{},
    gate: core.Config = .{},
    timeouts: request.Timeouts = .{},
    /// Listen for tool list changes on 2026 servers.
    listen_tools: bool = true,
    trace: ?*trace.Writer = null,
};

/// How a call ended: the server's outcomes, and the engine's own.
pub const Outcome = enum { result, failure, lost, http_failure, cancelled, rounds_exceeded, unsupported_input, malformed, needs_auth, denied, transport_failed };

pub const Event = struct {
    /// The server's name, valid until the next `reload`.
    server: []const u8,
    kind: union(enum) {
        phase: Phase,
        /// A call ended. `answer` is set when the server answered, valid
        /// until the next `next`.
        called: struct { call: Handle, outcome: Outcome, maybe_ran: bool, timed_out: bool, answer: ?tools.Call },
        /// A call needs the host's answers to its input requests:
        /// `respond`, or `cancel`. Valid until then.
        input: struct { call: Handle, requests: []const mrtr.Request },
        /// The rest as the server says it: tool lists, sign-in,
        /// subscriptions, detection failures, and 2025 elicitations.
        server: server_mod.Event,
    },
};

pub const Status = struct {
    name: []const u8,
    transport: std.meta.Tag(Transport),
    phase: Phase,
    version: ?[]const u8,
    tools: usize,
    last_error: ?[]const u8,
};

pub const Error = server_mod.Error || error{ UnknownServer, UnknownCall, TooManyCalls };

const Call = struct {
    handle: Handle,
    /// The server's handle, once it was handed over.
    sent: ?server_mod.Handle = null,
    name: []u8,
    arguments: ?[]u8,
    /// Sent once more after -32022 switched the version.
    resent: bool = false,
};

const Slot = struct {
    engine: *Engine,
    arena: std.heap.ArenaAllocator,
    config: Config,
    gate: core.Gate,
    server: ?*server_mod.Server = null,
    tracer: trace.Writer = undefined,
    calls: std.ArrayList(Call) = .empty,
    backoff_due: ?i64 = null,
    last_error: ?[]const u8 = null,
    /// Dropped by `reload`: freed once it is down and the host read its events.
    retired_at: i64 = 0,
};

const empty_list: tools.List = .{};

pub const Engine = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    host: Host,
    options: Options,
    slots: std.ArrayList(*Slot) = .empty,
    retired: std.ArrayList(*Slot) = .empty,
    bell: Bell,
    /// Set by `wake`, so a `next` that wakes up empty returns.
    woken: std.atomic.Value(bool) = .init(false),
    next_handle: Handle = 1,
    /// Where the next read starts, so one busy server can't starve the rest.
    cursor: usize = 0,
    /// Room for a step that ends every call of a server, and its phase.
    events: [2 * core.max_calls + 8]Event = undefined,
    event_count: usize = 0,

    pub fn init(e: *Engine, io: std.Io, gpa: std.mem.Allocator, host: Host, options: Options, servers: []const Config) Error!void {
        e.* = .{ .io = io, .gpa = gpa, .host = host, .options = options, .bell = undefined };
        e.bell.init(io);
        errdefer e.deinit();
        for (servers) |c| try e.slots.append(gpa, try e.newSlot(c));
    }

    /// Stdio servers stop together; whatever is still up after 3.5 s is killed.
    pub fn deinit(e: *Engine) void {
        for (e.slots.items) |slot| {
            if (slot.server) |s| s.close() catch {};
            slot.retired_at = e.now();
        }
        e.retired.appendSlice(e.gpa, e.slots.items) catch for (e.slots.items) |slot| e.destroySlot(slot);
        e.slots.clearRetainingCapacity();
        const deadline = e.now() + 3500;
        while (e.retired.items.len > 0 and e.now() < deadline) {
            e.event_count = 0;
            e.sweep() catch break;
            if (e.retired.items.len > 0) e.bell.wait(50) catch break;
        }
        for (e.retired.items) |slot| e.destroySlot(slot);
        e.retired.deinit(e.gpa);
        e.slots.deinit(e.gpa);
        e.bell.deinit();
    }

    /// Takes a new list of servers. One whose config is unchanged keeps
    /// running; the rest are dropped, their calls ending cancelled, and new
    /// ones are added, in the new order.
    pub fn reload(e: *Engine, servers: []const Config) Error!void {
        var kept: std.ArrayList(*Slot) = .empty;
        errdefer kept.deinit(e.gpa);
        try kept.ensureTotalCapacity(e.gpa, servers.len);
        for (servers) |c| {
            const old = for (e.slots.items, 0..) |slot, i| {
                if (same(slot.config, c)) break i;
            } else null;
            if (old) |i| kept.appendAssumeCapacity(e.slots.swapRemove(i)) else kept.appendAssumeCapacity(try e.newSlot(c));
        }
        try e.retired.ensureUnusedCapacity(e.gpa, e.slots.items.len);
        for (e.slots.items) |slot| {
            try e.step(slot, .{ .drop = .{ .keep = false } });
            if (slot.server) |s| s.close() catch {};
            slot.retired_at = e.now();
            e.retired.appendAssumeCapacity(slot);
        }
        e.slots.deinit(e.gpa);
        e.slots = kept;
    }

    pub fn len(e: *const Engine) usize {
        return e.slots.items.len;
    }

    pub fn status(e: *const Engine, index: usize) Status {
        const slot = e.slots.items[index];
        return .{
            .name = slot.config.name,
            .transport = std.meta.activeTag(slot.config.transport),
            .phase = slot.gate.phase,
            .version = if (slot.server) |s| s.protocolVersion() else null,
            .tools = if (slot.server) |s| s.toolList().len() else 0,
            .last_error = slot.last_error,
        };
    }

    /// The server's tools as it advertised them, valid until the next `next`.
    pub fn toolList(e: *Engine, name: []const u8) Error!*const tools.List {
        const slot = try e.find(name);
        return if (slot.server) |s| s.toolList() else &empty_list;
    }

    /// The host needs the tool list: the server starts if it must, and a
    /// `tools` event follows.
    pub fn needTools(e: *Engine, name: []const u8) Error!void {
        try e.step(try e.find(name), .need);
    }

    pub fn disconnect(e: *Engine, name: []const u8) Error!void {
        try e.step(try e.find(name), .{ .drop = .{ .keep = false } });
    }

    /// Drops the link and starts the server again, with its tries in a row
    /// back to none.
    pub fn reconnect(e: *Engine, name: []const u8) Error!void {
        const slot = try e.find(name);
        try e.step(slot, .{ .drop = .{ .keep = true } });
        try e.step(slot, .need);
    }

    /// Calls `tool` on server `name` with a JSON object, or null for none;
    /// both are copied. The host's `allow` answers first. Every
    /// call ends with one `called` event, a refused one too.
    pub fn call(e: *Engine, name: []const u8, tool: []const u8, arguments: ?[]const u8) Error!Handle {
        const slot = try e.find(name);
        const allowed = e.host.allow(e.host.context, slot.config.name, tool, arguments);
        const handle = e.next_handle;
        e.next_handle = if (e.next_handle == std.math.maxInt(Handle)) 1 else e.next_handle + 1;
        if (allowed) {
            const copy: Call = .{ .handle = handle, .name = try e.gpa.dupe(u8, tool), .arguments = if (arguments) |a| try e.gpa.dupe(u8, a) else null };
            slot.calls.append(e.gpa, copy) catch |err| {
                free(e.gpa, copy);
                return err;
            };
        }
        e.step(slot, .{ .asked = .{ .call = handle, .allowed = allowed } }) catch |err| {
            if (allowed) free(e.gpa, slot.calls.pop().?);
            return err;
        };
        return handle;
    }

    /// Cancels a call: one waiting ends here, one in flight goes to its server.
    pub fn cancel(e: *Engine, handle: Handle) Error!void {
        const slot, const i = e.findCall(handle) orelse return;
        if (slot.calls.items[i].sent) |h| return slot.server.?.cancel(h);
        try e.step(slot, .{ .cancel = handle });
    }

    /// Answers a call's input requests, as `server.zig` `respond`.
    pub fn respond(e: *Engine, handle: Handle, values: []const []const u8) Error!void {
        const slot, const i = e.findCall(handle) orelse return error.UnknownCall;
        const h = slot.calls.items[i].sent orelse return error.UnknownCall;
        try slot.server.?.respond(h, values);
    }

    /// Answers a 2025 server's elicitation, as `server.zig` does.
    pub fn answerElicitation(e: *Engine, name: []const u8, elicit: u8, answer: elicitation.Answer) Error!void {
        const s = (try e.find(name)).server orelse return error.UnknownElicitation;
        try s.answerElicitation(elicit, answer);
    }

    /// Sign-in, as `server.zig` does; a server that never started
    /// is created for it.
    pub fn signIn(e: *Engine, name: []const u8, redirect_uri: []const u8) Error!void {
        try (try e.ensureServer(try e.find(name))).signIn(redirect_uri);
    }

    /// `callback_url` must stay valid until the sign-in ends: the code in it
    /// is read when it is redeemed.
    pub fn finishSignIn(e: *Engine, name: []const u8, callback_url: []const u8) Error!void {
        try (try e.ensureServer(try e.find(name))).finishSignIn(callback_url);
    }

    pub fn cancelSignIn(e: *Engine, name: []const u8) Error!void {
        try (try e.ensureServer(try e.find(name))).cancelSignIn();
    }

    pub fn signOut(e: *Engine, name: []const u8) Error!void {
        try (try e.ensureServer(try e.find(name))).signOut();
    }

    /// What server `name` said to tell the model about it, from its
    /// last discover or initialize result; null when it said nothing. Valid
    /// until the next call into the engine.
    pub fn instructions(e: *Engine, name: []const u8) ?[]const u8 {
        const s = (e.find(name) catch return null).server orelse return null;
        return s.instructions;
    }

    /// Server `name`'s sign-out is still revoking its token, so a host
    /// whose program exits next can wait for the answer first.
    pub fn revoking(e: *Engine, name: []const u8) bool {
        const s = (e.find(name) catch return false).server orelse return false;
        return s.revoking();
    }

    /// Writes server `name`'s sign-in credential for the host to keep
    /// securely, and pass back in `Config.auth.saved`; false when there is
    /// none to keep. A `credential` event says when it changed.
    pub fn saveCredential(e: *Engine, name: []const u8, w: *std.Io.Writer) Error!bool {
        const s = (try e.find(name)).server orelse return false;
        return s.saveCredential(w);
    }

    /// Wakes a `next` that waits, from any thread: it returns null early, so
    /// the host can act on what it was woken for.
    pub fn wake(e: *Engine) void {
        e.woken.store(true, .release);
        e.bell.ring();
    }

    /// The next event, waiting at most `timeout_ms`; null when none came, or
    /// when `wake` was called. Events already waiting come first.
    pub fn next(e: *Engine, timeout_ms: u32) Error!?Event {
        const deadline = e.now() + timeout_ms;
        while (true) {
            if (e.take()) |event| return event;
            try e.sweep();
            const count = e.slots.items.len;
            for (0..count) |k| {
                const slot = e.slots.items[(e.cursor + k) % count];
                if (slot.backoff_due) |due| if (due <= e.now()) {
                    slot.backoff_due = null;
                    try e.step(slot, .backoff_over);
                    // A subscription waiting to listen again is demand.
                    if (slot.server) |s| if (s.waiting()) try e.step(slot, .need);
                };
                // What the host should see goes out before that server is
                // read again, so the slices in it stay valid. What the same
                // read queued is taken with it, so the gate is current when
                // the host acts: a process exit's lost calls and its `down`
                // are one step, as in the model.
                if (slot.server) |s| while (e.event_count == 0) {
                    try e.onServer(slot, try s.poll() orelse break);
                    while (s.pending()) |more| try e.onServer(slot, more);
                };
                if (e.event_count > 0) {
                    e.cursor = (e.cursor + k + 1) % count;
                    break;
                }
            }
            if (e.event_count > 0) continue;
            const at = e.now();
            if (at >= deadline) return null;
            var wait = deadline;
            for (e.slots.items) |slot| {
                if (slot.backoff_due) |due| wait = @min(wait, due);
                if (slot.server) |s| {
                    if (s.dueMs()) |due| wait = @min(wait, due);
                }
            }
            try e.bell.wait(@intCast(@max(0, wait - at)));
            if (e.woken.swap(false, .acq_rel)) return null;
        }
    }

    fn onServer(e: *Engine, slot: *Slot, event: server_mod.Event) Error!void {
        switch (event) {
            .ready => try e.step(slot, .up),
            .failed => |f| {
                slot.last_error = switch (f) {
                    .era => |why| @tagName(why),
                    .session => "session",
                    .needs_auth => "needs_auth",
                };
                // One that needs a sign-in is dropped, as the host would,
                // and what waits ends needs_auth; once signed in, the next
                // need starts it again.
                if (f == .needs_auth) return e.stepFor(slot, .{ .drop = .{ .keep = false } }, .needs_auth);
                try e.step(slot, .down);
            },
            .down => {
                slot.last_error = if (slot.server.?.spawnError()) |err| @errorName(err) else "process";
                try e.step(slot, .down);
            },
            .called => |c| {
                const i = for (slot.calls.items, 0..) |x, i| {
                    if (x.sent != null and x.sent.? == c.handle) break i;
                } else return;
                const s = slot.server.?;
                const x = &slot.calls.items[i];
                // -32022 after detection switched versions; the call
                // goes out once more, with the new one.
                if (c.answer) |a| if (a == .failure and a.failure.code == wire.code.unsupported_protocol_version and !x.resent and s.protocolVersion() != null) {
                    x.resent = true;
                    x.sent = try s.call(x.name, x.arguments);
                    return;
                };
                const done = slot.calls.orderedRemove(i);
                free(e.gpa, done);
                try e.step(slot, .{ .answered = done.handle });
                e.emit(slot, .{ .called = .{
                    .call = done.handle,
                    .outcome = switch (c.outcome) {
                        inline else => |tag| @field(Outcome, @tagName(tag)),
                    },
                    .maybe_ran = c.maybe_ran,
                    .timed_out = c.timed_out,
                    .answer = c.answer,
                } });
            },
            .input => |q| for (slot.calls.items) |x| if (x.sent != null and x.sent.? == q.handle) {
                return e.emit(slot, .{ .input = .{ .call = x.handle, .requests = q.requests } });
            },
            .timeout => unreachable, // `poll` never says it
            else => e.emit(slot, .{ .server = event }),
        }
    }

    fn step(e: *Engine, slot: *Slot, event: core.Event) Error!void {
        return e.stepFor(slot, event, null);
    }

    /// Steps the gate and carries out its effects; `why` replaces the
    /// outcome of the calls it cancels.
    fn stepFor(e: *Engine, slot: *Slot, event: core.Event, why: ?Outcome) Error!void {
        const before = slot.gate.phase;
        var out: core.Output = .{};
        try slot.gate.step(event, &out);
        if (trace.on(e.options.trace)) |t| try core.writeTrace(t, slot.config.name, &slot.gate, event, &out);
        for (out.effects()) |effect| switch (effect) {
            .connect => try (try e.ensureServer(slot)).connect(),
            .send => |handle| for (slot.calls.items) |*x| if (x.handle == handle) {
                x.sent = try slot.server.?.call(x.name, x.arguments);
            },
            .end => |end| {
                for (slot.calls.items, 0..) |x, i| if (x.handle == end.call) {
                    free(e.gpa, slot.calls.orderedRemove(i));
                    break;
                };
                e.emit(slot, .{ .called = .{
                    .call = end.call,
                    .outcome = if (why != null and end.end == .cancelled) why.? else switch (end.end) {
                        .denied => .denied,
                        .failed => .transport_failed,
                        .cancelled => .cancelled,
                        .lost => .lost,
                    },
                    .maybe_ran = end.end == .lost,
                    .timed_out = false,
                    .answer = null,
                } });
            },
            .list => try slot.server.?.needTools(),
            .refuse_need => e.emit(slot, .{ .server = .{ .tools = .{ .ok = false, .fresh = false, .needs_auth = why == .needs_auth } } }),
            .arm_backoff => |ms| slot.backoff_due = e.now() + ms,
            .teardown => {
                slot.backoff_due = null;
                if (slot.server) |s| try s.reset();
            },
        };
        if (slot.gate.phase != before) e.emit(slot, .{ .phase = slot.gate.phase });
    }

    fn ensureServer(e: *Engine, slot: *Slot) Error!*server_mod.Server {
        if (slot.server) |s| return s;
        const tracer: ?*trace.Writer = if (trace.on(e.options.trace)) |t| blk: {
            slot.tracer = t.child(slot.config.name);
            break :blk &slot.tracer;
        } else null;
        const s = try e.gpa.create(server_mod.Server);
        errdefer e.gpa.destroy(s);
        try s.init(e.io, e.gpa, .{
            .link = switch (slot.config.transport) {
                .http => |h| .{ .http = .{ .url = h.url, .headers = h.headers, .bell = &e.bell } },
                .stdio => |p| .{ .stdio = .{
                    .argv = p.argv,
                    .environ_map = p.environ_map,
                    .trace = tracer,
                    .bell = &e.bell,
                    .stderr = .{ .context = slot, .line = logLine },
                } },
            },
            .client = e.options.client,
            .era = e.options.era,
            .auth = slot.config.auth,
            .listen_tools = e.options.listen_tools,
            .timeouts = e.options.timeouts,
            .trace = tracer,
        });
        slot.server = s;
        return s;
    }

    fn logLine(context: *anyopaque, line: []const u8) void {
        const slot: *Slot = @ptrCast(@alignCast(context));
        const host = slot.engine.host;
        host.log(host.context, slot.config.name, line);
    }

    /// Frees retired servers once they are down and nothing the host hasn't
    /// read names them; after 3.5 s whatever still runs is killed.
    fn sweep(e: *Engine) Error!void {
        var i: usize = 0;
        while (i < e.retired.items.len) {
            const slot = e.retired.items[i];
            if (slot.server) |s| while (try s.poll()) |_| {};
            const late = e.now() - slot.retired_at > 3500;
            const busy = if (slot.server) |s| s.stopping() else false;
            if (e.event_count == 0 and (!busy or late)) {
                e.destroySlot(slot);
                _ = e.retired.swapRemove(i);
            } else i += 1;
        }
    }

    fn newSlot(e: *Engine, c: Config) Error!*Slot {
        const slot = try e.gpa.create(Slot);
        errdefer e.gpa.destroy(slot);
        slot.* = .{ .engine = e, .arena = .init(e.gpa), .config = undefined, .gate = .init(e.options.gate) };
        errdefer slot.arena.deinit();
        const a = slot.arena.allocator();
        slot.config = .{
            .name = try a.dupe(u8, c.name),
            .transport = switch (c.transport) {
                .stdio => |p| .{ .stdio = .{ .argv = try dupeAll(a, p.argv), .environ_map = p.environ_map } },
                .http => |h| blk: {
                    const headers = try a.alloc(std.http.Header, h.headers.len);
                    for (h.headers, headers) |from, *to| to.* = .{ .name = try a.dupe(u8, from.name), .value = try a.dupe(u8, from.value) };
                    break :blk .{ .http = .{ .url = try a.dupe(u8, h.url), .headers = headers } };
                },
            },
            .auth = c.auth,
        };
        const auth = &slot.config.auth;
        auth.client_name = try a.dupe(u8, c.auth.client_name);
        inline for (.{ "client_id", "client_secret", "client_metadata_url", "saved" }) |field| {
            if (@field(c.auth, field)) |v| @field(auth, field) = try a.dupe(u8, v);
        }
        return slot;
    }

    fn destroySlot(e: *Engine, slot: *Slot) void {
        if (slot.server) |s| {
            s.deinit();
            e.gpa.destroy(s);
        }
        for (slot.calls.items) |x| free(e.gpa, x);
        slot.calls.deinit(e.gpa);
        slot.arena.deinit();
        e.gpa.destroy(slot);
    }

    fn find(e: *Engine, name: []const u8) Error!*Slot {
        for (e.slots.items) |slot| if (std.mem.eql(u8, slot.config.name, name)) return slot;
        return error.UnknownServer;
    }

    fn findCall(e: *Engine, handle: Handle) ?struct { *Slot, usize } {
        for (e.slots.items) |slot| for (slot.calls.items, 0..) |x, i| if (x.handle == handle) return .{ slot, i };
        return null;
    }

    fn emit(e: *Engine, slot: *Slot, kind: @FieldType(Event, "kind")) void {
        if (e.event_count == e.events.len) return; // the host stopped reading; the newest are dropped
        e.events[e.event_count] = .{ .server = slot.config.name, .kind = kind };
        e.event_count += 1;
    }

    fn take(e: *Engine) ?Event {
        if (e.event_count == 0) return null;
        const event = e.events[0];
        std.mem.copyForwards(Event, e.events[0 .. e.event_count - 1], e.events[1..e.event_count]);
        e.event_count -= 1;
        return event;
    }

    fn now(e: *const Engine) i64 {
        return std.Io.Clock.awake.now(e.io).toMilliseconds();
    }
};

fn free(gpa: std.mem.Allocator, x: Call) void {
    gpa.free(x.name);
    if (x.arguments) |a| gpa.free(a);
}

fn dupeAll(a: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const copies = try a.alloc([]const u8, items.len);
    for (items, copies) |item, *copy| copy.* = try a.dupe(u8, item);
    return copies;
}

fn same(a: Config, b: Config) bool {
    if (!std.mem.eql(u8, a.name, b.name) or std.meta.activeTag(a.transport) != std.meta.activeTag(b.transport)) return false;
    switch (a.transport) {
        .stdio => |p| {
            const q = b.transport.stdio;
            if (p.environ_map != q.environ_map or p.argv.len != q.argv.len) return false;
            for (p.argv, q.argv) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        },
        .http => |h| {
            const g = b.transport.http;
            if (!std.mem.eql(u8, h.url, g.url) or h.headers.len != g.headers.len) return false;
            for (h.headers, g.headers) |x, y| if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.value, y.value)) return false;
        },
    }
    inline for (.{ "client_id", "client_secret", "client_metadata_url" }) |field| {
        const x = @field(a.auth, field);
        const y = @field(b.auth, field);
        if ((x == null) != (y == null)) return false;
        if (x != null and !std.mem.eql(u8, x.?, y.?)) return false;
    }
    return std.mem.eql(u8, a.auth.client_name, b.auth.client_name) and std.meta.eql(a.auth.flow, b.auth.flow);
}

test {
    // Behavior is tested by the Bun driver through tools/labs/engine_lab.zig;
    // this makes sure everything compiles.
    std.testing.refAllDecls(Engine);
}

test "wake from another thread ends a waiting next early" {
    const Fake = struct {
        fn allow(_: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) bool {
            return true;
        }
        fn log(_: *anyopaque, _: []const u8, _: []const u8) void {}
        fn wakeLater(e: *Engine) void {
            std.Io.sleep(e.io, .fromMilliseconds(30), .awake) catch {};
            e.wake();
        }
    };
    var context: u8 = 0;
    var e: Engine = undefined;
    try e.init(std.testing.io, std.testing.allocator, .{ .context = &context, .allow = Fake.allow, .log = Fake.log }, .{
        .client = .{ .info = .{ .name = "test", .version = "0" } },
    }, &.{});
    defer e.deinit();

    const started = e.now();
    const thread = try std.Thread.spawn(.{}, Fake.wakeLater, .{&e});
    defer thread.join();
    try std.testing.expectEqual(@as(?Event, null), try e.next(10_000));
    try std.testing.expect(e.now() - started < 5_000);

    // A wake before `next` is not lost: the next wait returns at once.
    e.wake();
    try std.testing.expectEqual(@as(?Event, null), try e.next(10_000));
    try std.testing.expect(e.now() - started < 5_000);
}
