//! One server as the client sees it: era detection, the tool catalog,
//! and tool calls, over Streamable HTTP (`io/http.zig`) or a process on
//! stdio (`io/process.zig`). Every request goes through the request table.
//!
//! On stdio each request is one line: the request table ends it,
//! a process exit loses what is in flight, a cancel is notifications/cancelled,
//! each new process detects again, and the host starts the process
//! with `connect`. A 2026 call's rounds run as on HTTP.
//!
//! On a 2026 server every logical request is a `core/http_modern.zig`
//! exchange: a broken stream is re-issued with a new id, and a cancel closes
//! the stream, and a call that comes back `input_required` runs as a
//! `core/mrtr.zig` chain of rounds. On a 2025 server the requests run in the session of
//! `core/http_legacy.zig`: they carry its `Mcp-Session-Id`, a 404 starts a new
//! session, a broken stream is resumed with GET and Last-Event-ID, and a
//! cancel is a notifications/cancelled POST.
//!
//! Every request passes `auth/client.zig`: it carries the token, a
//! request rejected with 401 goes out again once with a newer one, and the
//! host signs in with `signIn` and `finishSignIn` when a refresh can't help.
//!
//! With `listen_tools`, a 2026 server's tool list changes come on a
//! `subscriptions/listen` stream, run by `core/subscription.zig`.
//!
//! A 2025 server's elicitations run in `core/elicitation.zig`: the host
//! hears `elicit` and answers with `answerElicitation`. A 2026 call's come in
//! its rounds; both are read and checked by `protocol/elicitation.zig`.
//!
//! The host drives it with `connect` (or `detect` over HTTP), `needTools`,
//! `call`, `cancel`, `next` or `poll`, and `close`; `engine.zig` does.

const std = @import("std");
const era = @import("core/era.zig");
const catalog = @import("core/catalog.zig");
const request = @import("core/request.zig");
const http_modern = @import("core/http_modern.zig");
const http_legacy = @import("core/http_legacy.zig");
const mrtr_core = @import("core/mrtr.zig");
const mrtr = @import("protocol/mrtr.zig");
const http = @import("io/http.zig");
const process = @import("io/process.zig");
const stdio_conn = @import("core/stdio_conn.zig");
const http_headers = @import("protocol/http_headers.zig");
const tools = @import("protocol/tools.zig");
const trace = @import("io/trace.zig");
const wire = @import("protocol/wire.zig");
const auth_client = @import("auth/client.zig");
const elicitation = @import("protocol/elicitation.zig");
const elicit_core = @import("core/elicitation.zig");
const auth_core = @import("core/auth.zig");
const subscription = @import("core/subscription.zig");
const subscriptions = @import("protocol/subscriptions.zig");

pub const Link = union(enum) {
    http: http.Options,
    /// Its `config` is replaced: the process never backs off or gives up on
    /// its own, since the engine does both for every server.
    stdio: process.Options,
};

pub const Options = struct {
    link: Link,
    client: era.Client,
    era: era.Config = .{},
    catalog: catalog.Config = .{},
    exchange: http_modern.Config = .{},
    session: http_legacy.Config = .{},
    mrtr: mrtr_core.Config = .{},
    auth: auth_client.Options = .{},
    /// Listen for tool list changes once a 2026 server is ready, so the
    /// catalog hears of them. fx turns it on.
    listen_tools: bool = false,
    subscription: subscription.Config = .{},
    timeouts: request.Timeouts = .{},
    /// 2025: how long a new session's requests wait for its listening
    /// GET to open, so what the server sends there isn't lost.
    listen_wait_ms: u32 = 1000,
    trace: ?*trace.Writer = null,
};

pub const Handle = u32;

pub const Failure = union(enum) {
    era: era.Failure,
    /// A 2025 session ended and a new one couldn't be started.
    session,
    /// Detection needs a sign-in first; `detect` again after it.
    needs_auth,
};

/// How a call ended: the exchange's outcomes, and a chain's.
pub const CallOutcome = enum { result, failure, lost, http_failure, cancelled, rounds_exceeded, unsupported_input, malformed, needs_auth };

pub const Event = union(enum) {
    /// Detection finished; requests carry this version.
    ready: []const u8,
    failed: Failure,
    /// A listing ended (or a need was served from the cache). Read the list
    /// with `toolList`.
    tools: struct { ok: bool, fresh: bool, dropped: tools.Added = .{}, needs_auth: bool = false },
    /// A call ended. `answer` is set when the server answered, valid until the next `next`.
    called: struct { handle: Handle, outcome: CallOutcome, maybe_ran: bool, timed_out: bool, answer: ?tools.Call },
    /// A call needs the host's answers to its input requests: `respond` with
    /// one value per request, in order, or `cancel`. The requests stay
    /// valid until then.
    input: struct { handle: Handle, requests: []const mrtr.Request },
    /// Requests need a sign-in: after a 401 a refresh can't fix, or a
    /// 403 asking for more scopes (`step_up`).
    auth_required: struct { step_up: bool },
    /// The host opens this URL in a browser, and passes the URL it comes back
    /// to to `finishSignIn`.
    authorize: []const u8,
    signed_in,
    /// `message` is the authorization server's own, from a checked response
    /// or from its token endpoint.
    sign_in_failed: struct { why: auth_client.Failure, message: ?[]const u8 },
    /// The tool list subscription is acknowledged: the server will send these.
    listening: subscription.Filter,
    /// It ended for good.
    listen_ended: subscription.End,
    /// A 2025 server asks the user something: read `params` with
    /// `elicitation.parse` and answer with `answerElicitation`. `params` stays
    /// valid until the slot is used again. `required`: listed in a call's
    /// -32042 error, so nothing is sent back, accept is the user's consent to
    /// open the URL, and the host calls again when it completes.
    elicit: struct { slot: u8, params: []const u8, required: bool },
    /// The host no longer holds `slot`: the server cancelled it, or the
    /// session ended.
    elicit_withdrawn: u8,
    /// The URL interaction of `slot` completed.
    elicitation_complete: u8,
    /// Stdio: the process didn't start, or it ended; what was in flight on
    /// it was lost.
    down,
    /// The sign-in credential to keep changed; write it with
    /// `saveCredential`.
    credential,
    timeout,
};

pub const Error = http.Error || process.Error || std.mem.Allocator.Error || wire.EncodeError || std.Io.Writer.Error || auth_client.Error ||
    error{ NotReady, TooManyRequests, UnknownCall, InvalidInputResponses, UnknownElicitation, InvalidAnswer };

const What = union(enum) { discover: u8, initialize, list, call, listen };

const Logical = struct {
    used: bool = false,
    handle: Handle = 0,
    what: What = .list,
    /// 2026 only.
    exchange: http_modern.Exchange = undefined,
    /// The attempt in flight; on a 2025 session, the request's one id.
    id: ?request.Id = null,
    arena: std.heap.ArenaAllocator,
    name: []const u8 = "",
    arguments: ?[]const u8 = null,
    timed_out: bool = false,
    instance: []const u8 = "",
    /// 2025: the stream's last event id, sent back to resume it.
    last_event_id: ?[]const u8 = null,
    /// 2026 calls: the chain of input_required rounds, the last round
    /// (its slices in the arena), and the host's answers to it.
    chain: mrtr_core.Chain = .init(.{}),
    round: mrtr.Round = .{},
    answers: []const []const u8 = &.{},
    /// The chain's trace instance; each round's exchange gets its own.
    chain_instance: []const u8 = "",
    /// The gate gave up on it for want of a sign-in.
    needs_auth: bool = false,
    /// A listen: its subscription and filter, its id once sent, and
    /// whether it listens again after an abrupt end.
    sub: u8 = 0,
    filter: subscription.Filter = 0,
    listen_id: request.Id = 0,
    resend: bool = false,
};

/// A request kept until it ends, so the gate can send it again.
const Kept = struct {
    key: u64,
    method: http.Method,
    body: ?[]const u8,
    /// The request's headers and a spare last slot for `Authorization`.
    headers: []std.http.Header,
    arena: std.heap.ArenaAllocator,
};

const Timer = struct {
    kind: union(enum) { request: request.Timer, probe: u32, expiry: catalog.Generation, resume_stream: request.Id, listen, listen_wait, backoff: Handle, relisten: struct { sub: u8, generation: u32 } },
    due_ms: i64,
};

/// What a 2025 elicitation came with, in `gpa`: the request's raw id,
/// its raw elicitationId, and its params.
const Held = struct { id: ?[]u8 = null, eid: ?[]u8 = null, params: []u8 = &.{} };

/// Keys for requests nobody waits on an answer to: notifications, replies to
/// server requests, the listening GET, and the DELETE. Request ids stay far
/// below this.
const aux_base: u64 = 1 << 62;

/// 2025: a call can't go on until the URL elicitations it lists complete.
const url_elicitation_required: i64 = -32042;

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    /// Over HTTP.
    client: http.Client,
    /// Over stdio.
    proc: process.Process,
    stdio: bool,
    /// Stdio: the process the era was last detected for, and a start asked
    /// for while the last process was still stopping.
    era_generation: stdio_conn.Generation = 0,
    catalog_generation: stdio_conn.Generation = 0,
    start_pending: bool = false,
    table: request.Table,
    table_slots: [64]request.Slot = undefined,
    detector: era.Detector,
    catalog: catalog.Catalog,
    store: tools.Store = .{ .check_headers = true },
    logicals: [32]Logical = undefined,
    next_handle: Handle = 1,
    timers: std.ArrayList(Timer) = .empty,
    /// Room for a session's end to withdraw every elicitation.
    events: [16 + 2 * elicit_core.max_pending]Event = undefined,
    event_count: usize = 0,
    /// The answer an event points into, kept until the next `next`.
    held_answer: ?tools.Call = null,
    /// What the last page added, for the warning about dropped tools.
    last_added: tools.Added = .{},

    // A 2025 session.
    legacy: ?http_legacy.Session = null,
    legacy_slots: [32]http_legacy.Request = undefined,
    /// The session id in use, and the one an initialize answer brought.
    session_id: ?[]u8 = null,
    incoming_session: ?[]u8 = null,
    /// initialize's answer carried a session id the client can't echo.
    bad_session: bool = false,
    /// The agreed version, an index into `Config.legacy`.
    legacy_version: u8 = 0,
    /// What the last discover or initialize result told the client to
    /// tell the model about the server; in `gpa`.
    instructions: ?[]const u8 = null,
    listen_key: ?u64 = null,
    listen_last_event_id: ?[]u8 = null,
    delete_key: ?u64 = null,
    next_aux: u64 = aux_base,
    /// The notifications/initialized POST in flight. Each request is its own
    /// HTTP request, so until it ends the session's other sends wait, in
    /// order: requests must not reach the server before it.
    initialized_key: ?u64 = null,
    held_sends: std.ArrayList(http_legacy.Effect) = .empty,
    /// The session's first listening GET went out and hasn't opened,
    /// been refused, or ended yet, so the session's requests wait for it.
    first_listen: bool = true,
    listen_pending: bool = false,

    // OAuth.
    auth: auth_client.Auth = undefined,
    outbox: std.ArrayList(Kept) = .empty,
    /// The failing page's request gave up for want of a sign-in.
    page_needs_auth: bool = false,
    /// Each detection run is its own era and session trace instance.
    era_instance: []const u8 = "remote",
    era_run: u32 = 1,
    era_instance_buf: [24]u8 = undefined,

    // Subscriptions.
    subs: subscription.Table = undefined,

    // Elicitations of a 2025 session, by slot.
    elicit: elicit_core.Table = undefined,
    elicit_held: [elicit_core.max_pending]Held = @splat(.{}),

    pub fn init(r: *Server, io: std.Io, gpa: std.mem.Allocator, options: Options) Error!void {
        r.* = .{
            .io = io,
            .gpa = gpa,
            .options = options,
            .client = undefined,
            .proc = undefined,
            .stdio = options.link == .stdio,
            .table = undefined,
            .detector = .init(options.era),
            .catalog = .init(options.catalog),
            .subs = undefined,
            .elicit = .init(elicitation.declared(options.client.capabilities)),
        };
        var subs = options.subscription;
        subs.stdio = r.stdio;
        r.subs = .init(subs);
        r.table = .init(&r.table_slots, options.timeouts);
        for (&r.logicals) |*l| l.* = .{ .arena = .init(gpa) };
        switch (options.link) {
            .http => |h| {
                try r.client.init(io, gpa, h);
                r.auth = .init(io, gpa, &r.client, h.url, options.auth, trace.on(options.trace));
                if (options.auth.saved) |saved| try r.auth.restore(saved);
            },
            .stdio => |o| {
                var po = o;
                po.config.max_attempts = std.math.maxInt(u8);
                po.config.backoff_ms = 0;
                r.proc.init(io, gpa, po);
            },
        }
    }

    pub fn deinit(r: *Server) void {
        if (r.instructions) |text| r.gpa.free(text);
        if (r.stdio) r.proc.deinit() else {
            r.client.deinit();
            r.auth.deinit();
        }
        for (r.outbox.items) |*k| k.arena.deinit();
        r.outbox.deinit(r.gpa);
        for (&r.logicals) |*l| l.arena.deinit();
        r.timers.deinit(r.gpa);
        r.held_sends.deinit(r.gpa);
        r.store.deinit(r.gpa);
        for ([_]?[]u8{ r.session_id, r.incoming_session, r.listen_last_event_id }) |s| if (s) |v| r.gpa.free(v);
        for (&r.elicit_held) |*h| {
            r.forget(h);
            r.gpa.free(h.params);
        }
    }

    pub fn toolList(r: *const Server) *const tools.List {
        return &r.store.current;
    }

    /// Starts era detection. Over HTTP the endpoint is the "process".
    pub fn detect(r: *Server) Error!void {
        try r.stepEra(.process_started);
        try r.stepEra(.detect_requested);
    }

    /// Starts the server: over HTTP, detection again from the start;
    /// over stdio, the process, which detects once it runs. A start asked
    /// for while the last process is still stopping runs when it is down.
    pub fn connect(r: *Server) Error!void {
        if (!r.stdio) {
            if (r.detector.state != .unknown) try r.reset();
            return r.detect();
        }
        switch (r.proc.conn.state) {
            .idle, .stopped => try r.proc.start(),
            .failed => {
                try r.proc.reconnect();
                try r.proc.start();
            },
            else => {
                r.start_pending = true;
                return r.processUp();
            },
        }
        try r.started();
    }

    /// Why the last start of the process failed, if it did. The engine shows
    /// it in the server's status.
    pub fn spawnError(r: *const Server) ?anyerror {
        return if (r.stdio) r.proc.spawn_error else null;
    }

    /// Drops the link and everything on it: the process stops, or the
    /// session ends with a DELETE nobody waits for and detection starts over.
    /// The tool list stays until the next one; a sign-in stays too.
    pub fn reset(r: *Server) Error!void {
        r.start_pending = false;
        if (r.stdio) return r.proc.stop();
        // The tool list listen ends; the next ready opens it again.
        try r.stepSubs(.{ .cancel = 0 });
        if (r.legacy != null) try r.stepLegacy(.close);
        for (&r.logicals) |*l| if (l.used) {
            if (l.id) |id| {
                try r.stepRequest(.{ .transport_lost = id });
                try r.closeKey(id);
            }
            l.used = false;
        };
        if (r.listen_key) |key| try r.closeKey(key);
        r.listen_key = null;
        r.timers.clearRetainingCapacity();
        r.held_sends.clearRetainingCapacity();
        r.initialized_key = null;
        r.listen_pending = false;
        r.legacy = null;
        try r.endElicitations();
        r.newEraRun();
    }

    /// The version requests carry, once detection is done.
    pub fn protocolVersion(r: *const Server) ?[]const u8 {
        if (!r.detector.ready()) return null;
        return era.versionName(r.detector.config, r.detector.version);
    }

    /// A sign-out's revocation is still on its way.
    pub fn revoking(r: *const Server) bool {
        return !r.stdio and r.auth.revoking() != null;
    }

    /// Writes the sign-in credential for the host to keep securely,
    /// and pass back as `auth.saved`; false when there is none to keep.
    pub fn saveCredential(r: *const Server, w: *std.Io.Writer) std.Io.Writer.Error!bool {
        if (r.stdio) return false;
        return r.auth.save(w);
    }

    /// Stdio: the process is still on its way down after `close` or `reset`.
    pub fn stopping(r: *const Server) bool {
        if (!r.stdio) return false;
        return switch (r.proc.conn.state) {
            .closing, .terminating, .killing => true,
            else => false,
        };
    }

    /// A subscription waits to listen again: demand for a stopped process.
    pub fn waiting(r: *const Server) bool {
        return r.subs.waiting();
    }

    /// When the next timer is due, if any. The engine sleeps until then.
    pub fn dueMs(r: *const Server) ?i64 {
        var due: ?i64 = null;
        for (r.timers.items) |t| due = @min(due orelse t.due_ms, t.due_ms);
        return due;
    }

    /// The host needs the tool list.
    pub fn needTools(r: *Server) Error!void {
        try r.stepCatalog(.need);
    }

    /// Calls a tool from the current list. `arguments` is a JSON object, or
    /// null for none. Both are copied.
    pub fn call(r: *Server, name: []const u8, arguments: ?[]const u8) Error!Handle {
        if (!r.detector.ready()) return error.NotReady;
        const l = try r.newLogical(.call, .call);
        const a = l.arena.allocator();
        l.name = try a.dupe(u8, name);
        l.arguments = if (arguments) |args| try a.dupe(u8, args) else null;
        try r.start(l);
        return l.handle;
    }

    /// Cancels a call: on 2026 its stream is closed, on 2025 a
    /// notifications/cancelled goes out.
    pub fn cancel(r: *Server, handle: Handle) Error!void {
        const l = r.logicalByHandle(handle) orelse return;
        // Between rounds no request is out: the chain ends here.
        if (l.chain.phase == .asking or l.chain.phase == .backoff) return r.stepChain(l, .cancel);
        if (l.id) |id| try r.stepRequest(.{ .cancel_requested = id });
        if (!r.stdio and r.legacy == null and l.used) try r.stepExchange(l, .cancel);
    }

    /// Stops listening for tool list changes: the listen's stream closes.
    pub fn stopListening(r: *Server) Error!void {
        try r.stepSubs(.{ .cancel = 0 });
    }

    /// Answers a call's input requests: one raw JSON value per request,
    /// in the order of the `input` event, all at once. They go out
    /// under the server's own keys.
    pub fn respond(r: *Server, handle: Handle, values: []const []const u8) Error!void {
        const l = r.logicalByHandle(handle) orelse return error.UnknownCall;
        if (l.chain.phase != .asking or values.len != l.round.count) return error.InvalidInputResponses;
        // An elicitation's answer is checked before anything goes out.
        for (l.round.slice(), values) |q, v| if (q.kind == .elicitation) {
            var form: elicitation.Form = .{};
            const read = elicitation.parse(q.params.?, &form) catch unreachable; // read with the round
            _ = elicitation.readAnswer(read.mode, &form, v) catch return error.InvalidInputResponses;
        };
        const a = l.arena.allocator();
        const copies = try a.alloc([]const u8, values.len);
        for (values, copies) |v, *c| c.* = try a.dupe(u8, v);
        l.answers = copies;
        try r.stepChain(l, .provided);
    }

    /// Answers the 2025 elicitation in `slot`: accept with content for a
    /// form, accept for a URL, decline, or cancel. Content that fails the
    /// schema is refused, and the host still holds the elicitation.
    pub fn answerElicitation(r: *Server, slot: u8, answer: elicitation.Answer) Error!void {
        const s = r.elicit.held(slot) orelse return error.UnknownElicitation;
        var form: elicitation.Form = .{};
        _ = elicitation.parse(r.elicit_held[slot].params, &form) catch unreachable; // read when asked
        const valid = if (elicitation.check(s.mode, &form, answer)) true else |err| switch (err) {
            error.InvalidAnswer => return error.InvalidAnswer,
            error.InvalidContent => false,
        };
        try r.stepElicit(.{ .answered = .{ .slot = slot, .action = answer.action, .valid = valid } }, .{ .content = answer.content });
        if (!valid) return error.InvalidAnswer;
    }

    /// Starts signing in. The host hears `authorize` with the URL to
    /// open, which comes back to `redirect_uri`, a loopback or HTTPS URL; it
    /// passes that URL to `finishSignIn`, and hears `signed_in` or
    /// `sign_in_failed`. Then it retries what needed the sign-in.
    pub fn signIn(r: *Server, redirect_uri: []const u8) Error!void {
        if (r.stdio) return error.NotReady;
        try r.auth.signIn(redirect_uri);
        try r.runAuth(null);
    }

    /// `callback_url` must stay valid until the sign-in ends: the code in it
    /// is read when it is redeemed.
    pub fn finishSignIn(r: *Server, callback_url: []const u8) Error!void {
        if (r.stdio) return error.NotReady;
        try r.auth.finishSignIn(callback_url);
        try r.runAuth(null);
    }

    pub fn cancelSignIn(r: *Server) Error!void {
        if (r.stdio) return error.NotReady;
        try r.auth.cancelSignIn();
        try r.runAuth(null);
    }

    /// The tokens are forgotten; requests then go without one.
    pub fn signOut(r: *Server) Error!void {
        if (r.stdio) return error.NotReady;
        try r.auth.signOut();
        try r.runAuth(null);
    }

    /// Ends a 2025 session with a DELETE, waiting at most 2 s for
    /// it. Nothing goes out afterwards.
    pub fn close(r: *Server) Error!void {
        // Stdio: the process stops; `deinit` kills what is left.
        if (r.stdio) return r.proc.stop();
        var delete: ?u64 = null;
        if (r.legacy != null) {
            try r.stepLegacy(.close);
            delete = r.delete_key;
        }
        // A sign-out's revocation still on its way is waited for too,
        // within the same 2 s, or it would never leave a process that exits.
        var revoke = r.auth.revoking();
        const deadline = r.now() + 2000;
        while ((delete != null or revoke != null) and r.now() < deadline) switch (try r.client.next(@intCast(@max(0, deadline - r.now())))) {
            .ended => |e| if (delete) |k| if (k == e.key) {
                delete = null;
            },
            .fetched => |f| if (revoke) |k| if (k == f.key) {
                revoke = null;
            },
            .timeout => return,
            else => {},
        };
    }

    /// The next thing that happened, waiting at most `timeout_ms`.
    pub fn next(r: *Server, timeout_ms: u32) Error!Event {
        r.held_answer = null;
        const deadline = r.now() + timeout_ms;
        while (true) {
            if (r.take()) |event| return event;
            const wait: u32 = @intCast(@max(0, @min(deadline, r.dueMs() orelse deadline) - r.now()));
            const timed_out = if (r.stdio) blk: {
                const incoming = try r.proc.next(wait);
                if (incoming == .timeout) break :blk true;
                try r.onProcess(incoming);
                break :blk false;
            } else blk: {
                const incoming = try r.client.next(wait);
                if (incoming == .timeout) break :blk true;
                try r.onHttp(incoming);
                break :blk false;
            };
            if (timed_out) {
                try r.fireTimers();
                if (r.event_count == 0 and r.now() >= deadline) return .timeout;
            }
        }
    }

    /// The next thing that happened, without waiting; null for nothing. The
    /// engine reads each server when its bell rings, or a timer is due.
    pub fn poll(r: *Server) Error!?Event {
        r.held_answer = null;
        while (true) {
            if (r.take()) |event| return event;
            if (r.stdio) {
                if (try r.proc.poll()) |incoming| {
                    try r.onProcess(incoming);
                    continue;
                }
            } else if (r.client.poll()) |incoming| {
                try r.onHttp(incoming);
                continue;
            }
            const due = r.dueMs() orelse return null;
            if (due > r.now()) return null;
            try r.fireTimers();
        }
    }

    /// An event already queued, without reading anything. The engine
    /// takes what one read queued together, such as a process exit's lost
    /// calls and its `down`.
    pub fn pending(r: *Server) ?Event {
        return r.take();
    }

    fn take(r: *Server) ?Event {
        if (r.event_count == 0) return null;
        const event = r.events[0];
        std.mem.copyForwards(Event, r.events[0 .. r.event_count - 1], r.events[1..r.event_count]);
        r.event_count -= 1;
        return event;
    }

    fn onHttp(r: *Server, incoming: http.Incoming) Error!void {
        switch (incoming) {
            .message => |m| {
                try r.onEventId(m.key, m.event_id, m.retry_ms);
                try r.onMessage(m.key, m.status, m.message);
            },
            .mark => |m| try r.onEventId(m.key, m.event_id, m.retry_ms),
            .session => |s| try r.onSession(s.key, s.id),
            .opened => |key| if (r.legacy != null and key == r.listen_key) try r.listenSettled(),
            .ended => |e| try r.onEnded(e.key, e.status, e.how, e.challenge),
            .fetched => |f| {
                _ = try r.auth.fetched(f.key, f.status, f.body);
                try r.runAuth(null);
            },
            .timeout => unreachable,
        }
    }

    // ---- stdio ----

    fn onProcess(r: *Server, incoming: process.Incoming) Error!void {
        switch (incoming) {
            // On stdio a response names its request only by its id.
            .message => |m| try r.onMessage(if (m.message == .response) m.message.response.id orelse 0 else 0, 200, m.message),
            // With no sink for stderr, and a line that isn't MCP.
            .stderr, .dropped => {},
            .changed => |c| try r.onProcessChanged(c.state, c.lost),
            .timeout => unreachable,
        }
    }

    fn onProcessChanged(r: *Server, state: stdio_conn.State, lost: bool) Error!void {
        if (lost) {
            // What was in flight on the process is lost. The exit ends every
            // listen, and its elicitations are over.
            for (r.table_slots) |slot| if (slot.used) try r.stepRequest(.{ .transport_lost = slot.id });
            if (r.subs.up) try r.stepSubs(.transport_down);
            try r.endElicitations();
            var i: usize = 0;
            while (i < r.timers.items.len) {
                if (r.timers.items[i].kind == .probe) _ = r.timers.swapRemove(i) else i += 1;
            }
        }
        // A start that failed or a process that ended on its own; a stop the
        // host asked for ends as `stopped` instead.
        if (state == .backoff or state == .failed) r.emit(.down);
        if (r.start_pending and (state == .idle or state == .stopped)) {
            r.start_pending = false;
            try r.proc.start();
            return r.started();
        }
        try r.processUp();
    }

    /// After a start: a spawn that worked runs at once, and one that failed
    /// is in backoff at once, with no change for `next` to see either way.
    fn started(r: *Server) Error!void {
        if (r.proc.conn.state == .backoff or r.proc.conn.state == .failed) return r.emit(.down);
        try r.processUp();
    }

    /// Each new process detects before anything else.
    fn processUp(r: *Server) Error!void {
        const generation = r.proc.conn.generation;
        if (r.proc.conn.state != .running or generation == r.era_generation) return;
        r.era_generation = generation;
        try r.stepEra(.process_started);
        try r.stepEra(.detect_requested);
    }

    /// A stdio answer: what it answers is read, then the request table ends
    /// the request, and `stdioDelivered` the logical one.
    fn onStdioAnswer(r: *Server, l: *Logical, id: request.Id, body: @FieldType(wire.Response, "body")) Error!void {
        switch (l.what) {
            .discover => {
                try r.keepInstructions(body);
                try r.stepEra(era.classifyDiscover(r.detector.config, body));
            },
            .initialize => {
                try r.keepInstructions(body);
                try r.stepEra(era.classifyInitialize(r.detector.config, body));
            },
            .list => try r.stepCatalog(try r.pageEvent(body)),
            .call => _ = try r.callAnswer(body),
            // A result ends a listen gracefully, an error refuses it.
            .listen => try r.stepSubs(.{ .final = .{ .id = id, .end = if (body == .result) .result else .refused } }),
        }
        try r.stepRequest(.{ .response_received = .{ .id = id, .response = if (body == .result) .result else .peer_error } });
    }

    /// A stdio request ended in the request table: its logical request ends.
    fn stdioDelivered(r: *Server, id: request.Id, outcome: request.Outcome) Error!void {
        const l = r.logicalFor(id) orelse return;
        const answered = outcome == .result or outcome == .peer_error;
        if (r.legacyEra() and (l.what == .call or l.what == .list)) return r.legacyDelivered(id, switch (outcome) {
            .result, .peer_error => .result,
            .none, .lost, .ended => .lost,
            .timed_out, .cancelled => .cancelled,
        });
        l.id = null;
        switch (l.what) {
            // Answers were read on arrival; the probe timer covers silence.
            .discover => {},
            .initialize => if (outcome == .timed_out) try r.stepEra(.initialize_timed_out),
            .list => if (!answered) try r.stepCatalog(.page_failed),
            // The server's notifications/cancelled. A lost one waits
            // for the process, and a listen never times out.
            .listen => if (outcome == .ended) try r.stepSubs(.{ .final = .{ .id = id, .end = .server_cancelled } }),
            .call => return r.roundEnded(l, switch (outcome) {
                .result => .result,
                .peer_error => .failure,
                .none, .lost, .ended => .lost,
                .timed_out, .cancelled => .cancelled,
            }),
        }
        l.used = false;
    }

    /// A 2025 session over either transport.
    fn legacyEra(r: *const Server) bool {
        if (!r.stdio) return r.legacy != null;
        return r.detector.state == .legacy or r.detector.state == .initializing;
    }

    /// Answers a server's request: a POST, or a line on stdio.
    fn reply(r: *Server, body: []const u8) Error!void {
        if (r.stdio) return r.proc.send(.response, body) catch {};
        try r.sendAux(.post, body, null);
    }

    inline fn tracer(r: *const Server) ?*trace.Writer {
        return trace.on(r.options.trace);
    }

    fn now(r: *const Server) i64 {
        return std.Io.Clock.awake.now(r.io).toMilliseconds();
    }

    fn emit(r: *Server, event: Event) void {
        if (r.event_count == r.events.len) return; // the host stopped reading; the newest are dropped
        r.events[r.event_count] = event;
        r.event_count += 1;
    }

    fn auxKey(r: *Server) u64 {
        r.next_aux += 1;
        return r.next_aux;
    }

    fn newLogical(r: *Server, what: What, kind: http_modern.Kind) Error!*Logical {
        const l = for (&r.logicals) |*l| {
            if (!l.used) break l;
        } else return error.TooManyRequests;
        _ = l.arena.reset(.retain_capacity);
        l.* = .{ .used = true, .handle = r.next_handle, .what = what, .exchange = .init(r.options.exchange, kind), .arena = l.arena, .chain = .init(r.options.mrtr) };
        r.next_handle +%= 1;
        l.instance = try std.fmt.allocPrint(l.arena.allocator(), "x{d}", .{l.handle});
        l.chain_instance = l.instance;
        return l;
    }

    fn logicalByHandle(r: *Server, handle: Handle) ?*Logical {
        for (&r.logicals) |*l| if (l.used and l.handle == handle) return l;
        return null;
    }

    fn logicalFor(r: *Server, id: request.Id) ?*Logical {
        for (&r.logicals) |*l| if (l.used and l.id == id) return l;
        return null;
    }

    /// Sends a list or call: as a 2026 exchange, or in the 2025 session.
    fn start(r: *Server, l: *Logical) Error!void {
        if (r.stdio) return if (l.what == .call and !r.legacyEra()) r.stepChain(l, .start) else r.sendAttempt(l);
        if (r.legacy == null) return if (l.what == .call) r.stepChain(l, .start) else r.stepExchange(l, .send);
        var out: era.Output = .{};
        r.detector.step(.operation_sent, &out) catch return error.NotReady;
        if (r.tracer()) |t| try era.writeTrace(t, r.era_instance, &out);
        l.id = try r.newRequest(.normal);
        try r.stepLegacy(.{ .send = l.id.? });
    }

    /// A new id from the request table.
    fn newRequest(r: *Server, kind: request.Kind) Error!request.Id {
        var out: request.Output = .{};
        r.table.step(.{ .send = kind }, &out) catch return error.TooManyRequests;
        if (r.tracer()) |t| try request.writeTrace(t, "remote", &out);
        var id: request.Id = 0;
        for (out.effects()) |effect| switch (effect) {
            .write_request => |w| id = w.id,
            .arm_timer => |a| try r.timers.append(r.gpa, .{ .kind = .{ .request = a.timer }, .due_ms = r.now() + a.after_ms }),
            else => {},
        };
        if (r.questionsHeld() > 0) try r.stepRequest(.{ .idle_paused = id });
        return id;
    }

    /// 2025 questions the host holds and hasn't answered.
    fn questionsHeld(r: *const Server) usize {
        var n: usize = 0;
        for (r.elicit.slots) |slot| n += @intFromBool(slot.used);
        return n;
    }

    /// A 2025 server asks outside the request it needs the answer for,
    /// so while the host holds any question, no request's idle timer runs.
    fn idleWhileAsking(r: *Server, held_before: usize) Error!void {
        const held = r.questionsHeld();
        if ((held_before == 0) == (held == 0)) return;
        for (r.table.slots) |slot| if (slot.used) {
            try r.stepRequest(if (held > 0) .{ .idle_paused = slot.id } else .{ .idle_resumed = slot.id });
        };
    }

    fn stepExchange(r: *Server, l: *Logical, event: http_modern.Event) Error!void {
        var out: http_modern.Output = .{};
        l.exchange.step(event, &out);
        if (r.tracer()) |t| try http_modern.writeTrace(t, l.instance, &out);
        for (out.effects()) |effect| switch (effect) {
            .post => try r.sendAttempt(l),
            .relist => {
                // Refresh the list, then retry with the new schema's headers.
                try r.stepCatalog(.invalidated);
                try r.stepCatalog(.need);
            },
            .close => if (l.id) |id| try r.closeKey(id),
            .deliver => |d| {
                // A call's round ended: its chain decides what comes next.
                if (l.what == .call) return r.roundEnded(l, d.outcome);
                // A listen's answer was taken where it arrived. A stream that
                // broke is abrupt; a status without an answer refuses it.
                if (l.what == .listen) {
                    l.used = false;
                    return r.stepSubs(switch (d.outcome) {
                        .lost => .{ .lost = l.listen_id },
                        .http_failure => .{ .final = .{ .id = l.listen_id, .end = .refused } },
                        else => return,
                    });
                }
                // An answer was routed where it arrived; here only an exchange
                // that ended without one.
                if (d.outcome != .result and d.outcome != .failure and l.what == .list) {
                    r.page_needs_auth = l.needs_auth;
                    try r.stepCatalog(.page_failed);
                }
                l.used = false;
            },
        };
    }

    /// Sends one attempt of `l` as a new request (a new id): a 2026 POST,
    /// or a line on stdio in either era.
    fn sendAttempt(r: *Server, l: *Logical) Error!void {
        var version: era.Version = .none;
        if (l.what == .discover) {
            version = .{ .preferred = l.what.discover };
        } else if (l.what != .initialize) {
            var out: era.Output = .{};
            r.detector.step(.operation_sent, &out) catch return error.NotReady;
            if (r.tracer()) |t| try era.writeTrace(t, r.era_instance, &out);
            version = out.meta.?;
        }
        const id = try r.newRequest(switch (l.what) {
            .listen => .listen,
            .initialize => .initialize,
            else => .normal,
        });
        l.id = id;
        if (l.what == .listen) {
            l.listen_id = id;
            try r.stepSubs(if (l.resend) .{ .resent = .{ .sub = l.sub, .id = id } } else .{ .opened = .{ .sub = l.sub, .id = id, .filter = l.filter } });
        }
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var body: std.Io.Writer.Allocating = .init(a);
        const config = r.detector.config;
        const meta = era.meta(config, r.options.client, version, id);
        switch (l.what) {
            .discover => |i| try era.writeDiscover(&body.writer, config, r.options.client, i, id),
            .initialize => try era.writeInitialize(&body.writer, config, r.options.client, id),
            .list, .call => try r.writeOperation(&body.writer, l, meta),
            .listen => try subscriptions.writeListen(&body.writer, id, meta, l.filter),
        }
        // Not written: the process isn't running, so the request is lost.
        if (r.stdio) return r.proc.send(.request, body.written()) catch r.stepRequest(.{ .transport_lost = id });
        var headers: std.ArrayList(http_headers.Header) = .empty;
        const version_name = era.versionName(config, version) orelse config.legacy[0];
        try http_headers.requestHeaders(a, version_name, switch (l.what) {
            .discover => "server/discover",
            .list => "tools/list",
            .call => "tools/call",
            .listen => "subscriptions/listen",
            .initialize => unreachable, // only in a 2025 session
        }, if (l.what == .call) l.name else null, &.{}, &headers);
        if (l.what == .call) if (r.store.current.find(l.name)) |tool| try r.paramHeaders(a, tool.raw, l.arguments orelse "{}", &headers);
        r.send(id, .post, body.written(), headers.items) catch |err| switch (err) {
            error.TooManyInFlight, error.ConcurrencyUnavailable => try r.endAttempt(l, id, .broken, 0),
            else => return err,
        };
    }

    /// The body of a tools/list or tools/call.
    fn writeOperation(r: *Server, out: *std.Io.Writer, l: *const Logical, meta: wire.Meta) Error!void {
        const id = l.id.?;
        switch (l.what) {
            .list => try tools.writeList(out, id, meta, if (r.catalog.pending == .next) r.store.nextCursor() else null),
            .call => try tools.writeCall(out, id, meta, l.name, l.arguments, if (!r.legacyEra()) retryOf(l) else .{}),
            else => unreachable,
        }
    }

    /// The `Mcp-Param-*` headers from the tool's `x-mcp-header`
    /// annotations. The store already dropped tools with invalid ones.
    fn paramHeaders(_: *Server, a: std.mem.Allocator, tool_raw: []const u8, arguments: []const u8, headers: *std.ArrayList(http_headers.Header)) Error!void {
        var found: [1]?[]const u8 = undefined;
        wire.objectFields(tool_raw, &.{"inputSchema"}, &found) catch return;
        var annotations: [http_headers.max_annotations]http_headers.Annotation = undefined;
        const n = http_headers.annotations(found[0] orelse return, &annotations) catch return;
        http_headers.paramHeaders(a, annotations[0..n], arguments, headers) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }

    fn onMessage(r: *Server, key: u64, status: u16, message: wire.Message) Error!void {
        switch (message) {
            .notification => |n| {
                // A server ends a listen with notifications/cancelled.
                if (std.mem.eql(u8, n.method, "notifications/cancelled")) {
                    // A 2025 server may cancel its own elicitation.
                    if (r.legacyEra()) if (r.heldSlot(n.params, "requestId", .id)) |slot| {
                        return r.stepElicit(.{ .server_cancelled = slot }, .{});
                    };
                    const id = subscriptions.cancelledId(n.params) orelse return;
                    return r.stepRequest(.{ .server_cancel_received = id });
                }
                // What names a listen is the subscription's.
                if (subscriptions.subscriptionId(n.params)) |sid| return switch (subscriptions.notice(n.method, n.params)) {
                    .acknowledged => |f| r.stepSubs(.{ .acknowledged = .{ .id = sid, .filter = f } }),
                    .changed => |kind| r.stepSubs(.{ .notified = .{ .id = sid, .kind = kind } }),
                    .other => {},
                };
                // Only a 2025 session has completion notifications.
                if (r.legacyEra() and std.mem.eql(u8, n.method, "notifications/elicitation/complete")) {
                    return r.stepElicit(.{ .completed = r.heldSlot(n.params, "elicitationId", .eid) }, .{});
                }
                // One without a subscriptionId still refreshes the list.
                if (std.mem.eql(u8, n.method, "notifications/tools/list_changed")) return r.stepCatalog(.invalidated);
                if (std.mem.eql(u8, n.method, "notifications/progress")) {
                    var found: [2]?[]const u8 = undefined;
                    wire.objectFields(n.params orelse "{}", &.{ "progressToken", "progress" }, &found) catch return;
                    const token = wire.decimal(found[0] orelse return) orelse return;
                    const value = std.fmt.parseFloat(f64, found[1] orelse return) catch return;
                    return r.stepRequest(.{ .progress_received = .{ .token = token, .value = value } });
                }
            },
            // A 2026 server sends no requests; they are dropped. A 2025
            // one gets an answer.
            .request => |q| if (r.legacyEra()) try r.answerServerRequest(q),
            .response => |resp| {
                // A JSON-RPC answer in a POST's body answers that POST,
                // even an error without an id.
                if (resp.id) |id| if (id != key) return;
                // On stdio an error without an id during the probe
                // means a legacy server.
                if (r.stdio and resp.id == null) return if (resp.body == .failure and r.detector.pending == .discover) r.stepEra(.legacy_answer);
                const l = r.logicalFor(key) orelse return;
                if (r.stdio) return r.onStdioAnswer(l, key, resp.body);
                if (l.what == .initialize) return r.onInitializeAnswer(l, resp.body);
                if (r.legacy != null and l.what != .discover) return r.onLegacyAnswer(l, key, status, resp.body);
                if (l.exchange.phase != .posted) return;
                try r.stepRequest(.{ .response_received = .{ .id = key, .response = if (resp.body == .result) .result else .peer_error } });
                const answer: http_modern.Answer = switch (l.what) {
                    .discover => blk: {
                        try r.keepInstructions(resp.body);
                        try r.stepEra(era.classifyDiscoverHttp(r.detector.config, status, resp.body));
                        break :blk if (resp.body == .result) .result else .failure;
                    },
                    .list => blk: {
                        try r.stepCatalog(try r.pageEvent(resp.body));
                        break :blk if (resp.body == .result) .result else .failure;
                    },
                    .call => blk: {
                        const c = try r.callAnswer(resp.body) orelse break :blk .mismatch;
                        // input_required is a result; the chain reads it.
                        break :blk switch (c) {
                            .result, .input_required => .result,
                            .failure, .invalid => .failure,
                        };
                    },
                    // A result ends it gracefully, an error refuses it.
                    .listen => blk: {
                        try r.stepSubs(.{ .final = .{ .id = key, .end = if (resp.body == .result) .result else .refused } });
                        break :blk if (resp.body == .result) .result else .failure;
                    },
                    .initialize => unreachable,
                };
                l.id = null;
                try r.stepExchange(l, .{ .answer = answer });
            },
        }
    }

    /// Reads a tools/call answer: null for a -32020 header mismatch.
    fn callAnswer(r: *Server, body: @FieldType(wire.Response, "body")) Error!?tools.Call {
        const c = tools.classifyCall(body);
        r.held_answer = c;
        if (c == .failure) {
            if (!r.stdio and r.legacy == null and c.failure.code == wire.code.header_mismatch) return null;
            if (era.classifyOperationRejection(r.detector.config, c.failure)) |e| try r.stepEra(e);
        }
        if (tools.suggestsChangedList(c)) try r.stepCatalog(.invalidated);
        return c;
    }

    /// A request ended: the gate hears first, then the machines that
    /// wait on it.
    fn onEnded(r: *Server, key: u64, status: u16, how: http.Ending, challenge: ?[]const u8) Error!void {
        if (r.kept(key) != null) {
            if (how == .rejected) {
                if (try r.auth.ended(key, .{ .rejected = .{ .status = status, .challenge = challenge orelse "" } })) return r.runAuth(null);
                r.unkeep(key);
                try r.runAuth(null);
            } else {
                r.unkeep(key);
                // A broken stream says nothing about the token; any reply
                // means it got past the server's check.
                _ = try r.auth.ended(key, if (how == .broken) .forgotten else .answered);
                try r.runAuth(null);
            }
        }
        try r.onEndedDomain(key, status, if (how == .rejected) .http_failure else how);
    }

    fn onEndedDomain(r: *Server, key: u64, status: u16, how: http.Ending) Error!void {
        if (r.legacy != null) {
            if (key == r.initialized_key) return r.releaseHeldSends();
            if (key == r.listen_key) return r.onListenEnded(status, how);
            const l = r.logicalFor(key) orelse return;
            if (l.what == .initialize) return r.onInitializeEnded(l, key);
            if (l.what != .discover) return r.onLegacyEnded(l, key, status, how);
        }
        const l = r.logicalFor(key) orelse return;
        if (l.exchange.phase != .posted) return;
        try r.endAttempt(l, key, how, status);
    }

    /// A 2026 attempt ended without an answer: the table forgets it, and the
    /// exchange decides.
    fn endAttempt(r: *Server, l: *Logical, id: request.Id, how: http.Ending, status: u16) Error!void {
        l.id = null;
        try r.stepRequest(.{ .transport_lost = id });
        if (how == .http_failure) {
            if (l.what == .discover) try r.stepEra(era.classifyDiscoverHttp(r.detector.config, status, null));
            return r.stepExchange(l, .http_failure);
        }
        try r.stepExchange(l, .stream_broken);
    }

    fn pageEvent(r: *Server, body: @FieldType(wire.Response, "body")) Error!catalog.Event {
        switch (body) {
            .failure => |f| return if (f.code == wire.code.invalid_params and r.catalog.pending == .next) .invalid_cursor else .page_failed,
            .result => |res| {
                if (res.kind != .complete) return .page_failed;
                const page = tools.parsePage(res.raw) catch return .page_failed;
                const added = r.store.addPage(r.gpa, page) catch return .page_failed;
                r.last_added = added;
                return .{ .page_received = .{ .more = page.next_cursor != null, .ttl_ms = page.ttl_ms } };
            },
        }
    }

    // ---- input_required rounds ----

    /// The fields a call's next request adds: answers when the chain sends
    /// them, and the last round's requestState when it echoes one.
    fn retryOf(l: *const Logical) mrtr.Retry {
        const answering = l.chain.responded > 0;
        return .{
            .requests = if (answering) l.round.slice() else &.{},
            .values = if (answering) l.answers else &.{},
            .state = if (l.chain.sent_state != 0) l.round.state else null,
        };
    }

    /// A round's exchange ended: an input_required answer is read into the
    /// call's own memory and given to the chain; anything else ends it.
    fn roundEnded(r: *Server, l: *Logical, outcome: http_modern.Outcome) Error!void {
        const answer: mrtr_core.Answer = switch (outcome) {
            .result => if (r.held_answer) |a| switch (a) {
                .input_required => |raw| try r.readRound(l, raw),
                else => .{ .ended = .result },
            } else .{ .ended = .result },
            .failure => .{ .ended = .failure },
            .lost => .{ .ended = .lost },
            .http_failure => .{ .ended = .http_failure },
            .cancelled => return r.stepChain(l, .cancel),
        };
        try r.stepChain(l, .{ .answered = answer });
    }

    fn readRound(r: *Server, l: *Logical, raw: []const u8) Error!mrtr_core.Answer {
        const bytes = try l.arena.allocator().dupe(u8, raw);
        mrtr.parse(bytes, &l.round) catch return .malformed;
        // An elicitation the client declared but can't show.
        for (l.round.slice()) |q| if (q.kind == .elicitation and mrtr.supported(r.options.client.capabilities, q)) {
            var form: elicitation.Form = .{};
            _ = elicitation.parse(q.params orelse return .malformed, &form) catch return .malformed;
        };
        return .{ .input_required = .{
            .requests = l.round.count,
            .state = l.round.state != null,
            .supported = mrtr.allSupported(r.options.client.capabilities, &l.round),
        } };
    }

    fn stepChain(r: *Server, l: *Logical, event: mrtr_core.Event) Error!void {
        var out: mrtr_core.Output = .{};
        l.chain.step(event, &out);
        if (r.tracer()) |t| try mrtr_core.writeTrace(t, l.chain_instance, &l.chain, &out);
        for (out.effects()) |effect| switch (effect) {
            .send => |s| {
                // Each round is a new request with a new id, and its own
                // exchange, traced under its own instance.
                l.exchange = .init(r.options.exchange, .call);
                l.id = null;
                if (s.round > 1) l.instance = try std.fmt.allocPrint(l.arena.allocator(), "x{d}.{d}", .{ l.handle, s.round });
                if (r.stdio) try r.sendAttempt(l) else try r.stepExchange(l, .send);
            },
            .ask_host => r.emit(.{ .input = .{ .handle = l.handle, .requests = l.round.slice() } }),
            .arm_backoff => |ms| try r.timers.append(r.gpa, .{ .kind = .{ .backoff = l.handle }, .due_ms = r.now() + ms }),
            .deliver => |o| {
                r.emit(.{
                    .called = .{
                        .handle = l.handle,
                        .outcome = if (l.needs_auth and o == .http_failure) .needs_auth else switch (o) {
                            .none => .failure,
                            inline else => |tag| @field(CallOutcome, @tagName(tag)),
                        },
                        // Only a lost stream leaves the call maybe run.
                        .maybe_ran = o == .lost,
                        .timed_out = l.timed_out,
                        .answer = if (o == .result or o == .failure) r.held_answer else null,
                    },
                });
                l.used = false;
            },
        };
    }

    // ---- 2025 sessions ----

    /// The era core asked for initialize: over HTTP that starts a session.
    fn startSession(r: *Server) Error!void {
        if (r.legacy == null) r.legacy = .init(&r.legacy_slots, r.options.session);
        try r.stepLegacy(.start);
    }

    fn stepLegacy(r: *Server, event: http_legacy.Event) Error!void {
        const s = &(r.legacy orelse return);
        var out: http_legacy.Output = .{};
        s.step(event, &out) catch return;
        if (r.tracer()) |t| try http_legacy.writeTrace(t, r.era_instance, &out);
        for (out.effects()) |effect| try r.legacyEffect(effect);
        s.sweep();
    }

    fn legacyEffect(r: *Server, effect: http_legacy.Effect) Error!void {
        switch (effect) {
            .post, .get_resume => if (r.initialized_key != null or r.listen_pending) return r.held_sends.append(r.gpa, effect),
            .open_listen => if (r.initialized_key != null) return r.held_sends.append(r.gpa, effect),
            else => {},
        }
        switch (effect) {
            .post_initialize => {
                // A new session; the old one's elicitations are over.
                try r.endElicitations();
                r.first_listen = true;
                r.listen_pending = false;
                try r.sendInitialize();
            },
            .post_initialized => {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                try era.writeInitialized(&body.writer);
                const key = r.auxKey();
                r.initialized_key = key;
                try r.sendLegacy(key, .post, body.written(), null);
            },
            .post => |id| {
                // A held post for a request that was cancelled meanwhile.
                const req = r.legacy.?.find(id) orelse return;
                if (req.state == .posted) try r.postLegacy(id);
            },
            .post_cancel => |id| {
                // The request id, as the cancellation names it.
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                var w: wire.Writer = try .notification(&body.writer, "notifications/cancelled", .{});
                try w.field("requestId");
                try w.int(@intCast(id));
                try w.end();
                try r.sendAux(.post, body.written(), null);
            },
            .get_resume => |id| {
                const req = r.legacy.?.find(id) orelse return;
                const l = r.logicalFor(id) orelse return;
                if (req.state == .resuming) try r.sendLegacy(id, .get, null, l.last_event_id);
            },
            .arm_resume => |a| try r.timers.append(r.gpa, .{ .kind = .{ .resume_stream = a.id }, .due_ms = r.now() + a.after_ms }),
            .open_listen => {
                // Held sends run later: the session may have closed meanwhile.
                if (r.legacy.?.listen != .open or r.legacy.?.phase != .ready) return;
                const key = r.auxKey();
                r.listen_key = key;
                if (r.first_listen) {
                    r.first_listen = false;
                    r.listen_pending = true;
                    try r.timers.append(r.gpa, .{ .kind = .listen_wait, .due_ms = r.now() + r.options.listen_wait_ms });
                }
                try r.sendLegacy(key, .get, null, r.listen_last_event_id);
            },
            .close_listen => if (r.listen_key) |key| {
                try r.closeKey(key);
                r.listen_key = null;
            },
            .arm_listen => |ms| try r.timers.append(r.gpa, .{ .kind = .listen, .due_ms = r.now() + ms }),
            .delete => {
                try r.endElicitations();
                const key = r.auxKey();
                r.delete_key = key;
                try r.sendLegacy(key, .delete, null, null);
            },
            .deliver => |d| {
                if (d.outcome != .result) {
                    try r.stepRequest(.{ .transport_lost = d.id });
                    // Nothing reads its answer now, so a stream still open is
                    // closed. A disconnect cancels nothing in 2025;
                    // notifications/cancelled did.
                    try r.closeKey(d.id);
                }
                try r.legacyDelivered(d.id, d.outcome);
            },
        }
    }

    /// The first listening GET opened, was refused, or ended, or the
    /// wait for it is over: the session's held requests go out.
    fn listenSettled(r: *Server) Error!void {
        if (!r.listen_pending) return;
        r.listen_pending = false;
        try r.releaseHeldSends();
    }

    /// The initialized POST ended: the sends held for it go out, in order.
    fn releaseHeldSends(r: *Server) Error!void {
        r.initialized_key = null;
        var held = r.held_sends;
        r.held_sends = .empty;
        defer held.deinit(r.gpa);
        for (held.items) |effect| try r.legacyEffect(effect);
    }

    /// POSTs initialize, without a session id, as a new request.
    fn sendInitialize(r: *Server) Error!void {
        const l = try r.newLogical(.initialize, .idempotent);
        const id = try r.newRequest(.initialize);
        l.id = id;
        var body: std.Io.Writer.Allocating = .init(r.gpa);
        defer body.deinit();
        try era.writeInitialize(&body.writer, r.detector.config, r.options.client, id);
        if (r.incoming_session) |v| r.gpa.free(v);
        r.incoming_session = null;
        r.bad_session = false;
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        var headers: std.ArrayList(http_headers.Header) = .empty;
        try http_headers.sessionHeaders(arena.allocator(), false, null, null, null, &headers);
        try r.send(id, .post, body.written(), headers.items);
    }

    /// POSTs a list or call in the current session.
    fn postLegacy(r: *Server, id: request.Id) Error!void {
        const l = r.logicalFor(id) orelse return;
        l.last_event_id = null;
        var body: std.Io.Writer.Allocating = .init(r.gpa);
        defer body.deinit();
        try r.writeOperation(&body.writer, l, era.meta(r.detector.config, r.options.client, .none, id));
        try r.sendLegacy(id, .post, body.written(), null);
    }

    /// Sends with the session's headers: the agreed version, the session id,
    /// and Last-Event-ID to resume.
    fn sendLegacy(r: *Server, key: u64, method: http.Method, body: ?[]const u8, last_event_id: ?[]const u8) Error!void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        var headers: std.ArrayList(http_headers.Header) = .empty;
        const version = r.detector.config.legacy[r.legacy_version];
        try http_headers.sessionHeaders(arena.allocator(), method == .get, version, r.session_id, last_event_id, &headers);
        r.send(key, method, body, headers.items) catch |err| switch (err) {
            // Nothing could go out: the same as a stream that broke at once.
            error.TooManyInFlight, error.ConcurrencyUnavailable => if (key < aux_base) try r.stepLegacy(.{ .broke = key }),
            else => return err,
        };
    }

    fn sendAux(r: *Server, method: http.Method, body: ?[]const u8, last_event_id: ?[]const u8) Error!void {
        try r.sendLegacy(r.auxKey(), method, body, last_event_id);
    }

    /// A 2025 server's ping gets an empty result, and an elicitation goes
    /// to the elicitation table; other requests get -32601, since the
    /// client declares no capabilities that take them.
    fn answerServerRequest(r: *Server, q: wire.ServerRequest) Error!void {
        if (std.mem.eql(u8, q.method, "elicitation/create")) return r.askElicitation(.request, q.id, q.params orelse "{}");
        var body: std.Io.Writer.Allocating = .init(r.gpa);
        defer body.deinit();
        if (std.mem.eql(u8, q.method, "ping")) {
            var w: wire.Writer = try .result(&body.writer, q.id);
            try w.end();
        } else try wire.writeFailure(&body.writer, q.id, wire.code.method_not_found, "Method not found");
        try r.reply(body.written());
    }

    fn onSession(r: *Server, key: u64, id: []const u8) Error!void {
        const l = r.logicalFor(key) orelse return;
        if (l.what != .initialize) return;
        // An id the client couldn't echo safely fails the initialize.
        if (!http_headers.validSessionId(id)) {
            r.bad_session = true;
            return;
        }
        if (r.incoming_session) |v| r.gpa.free(v);
        r.incoming_session = try r.gpa.dupe(u8, id);
    }

    fn onEventId(r: *Server, key: u64, event_id: ?[]const u8, retry_ms: ?u32) Error!void {
        if (r.legacy == null) return;
        // Only ids that are safe to send back make a stream resumable.
        const id = if (event_id) |e| if (http_headers.validEventId(e)) e else null else null;
        if (key == r.listen_key) {
            if (id) |e| {
                if (r.listen_last_event_id) |v| r.gpa.free(v);
                r.listen_last_event_id = try r.gpa.dupe(u8, e);
            }
            return r.stepLegacy(.listen_event);
        }
        const l = r.logicalFor(key) orelse return;
        if (l.what == .initialize or l.what == .discover) return;
        if (id) |e| l.last_event_id = try l.arena.allocator().dupe(u8, e);
        if (id != null or retry_ms != null) try r.stepLegacy(.{ .event_seen = .{ .id = key, .has_id = id != null, .retry_ms = retry_ms } });
    }

    /// A result replaces the instructions, with none when it has none.
    fn keepInstructions(r: *Server, body: @FieldType(wire.Response, "body")) Error!void {
        if (body != .result) return;
        var found: [1]?[]const u8 = .{null};
        wire.objectFields(body.result.raw, &.{"instructions"}, &found) catch {};
        if (r.instructions) |old| r.gpa.free(old);
        r.instructions = null;
        const raw = found[0] orelse return;
        const text = (try wire.decodeString(r.gpa, raw)) orelse return;
        // Without escapes it is the result's own bytes, which don't last.
        r.instructions = if (wire.plainString(raw) != null) try r.gpa.dupe(u8, text) else text;
    }

    fn onInitializeAnswer(r: *Server, l: *Logical, body: @FieldType(wire.Response, "body")) Error!void {
        const id = l.id.?;
        try r.stepRequest(.{ .response_received = .{ .id = id, .response = if (body == .result) .result else .peer_error } });
        l.used = false;
        try r.keepInstructions(body);
        const event = era.classifyInitialize(r.detector.config, body);
        const first = r.detector.state == .initializing;
        if (event == .initialize_result and event.initialize_result == .legacy and !r.bad_session) {
            r.legacy_version = event.initialize_result.legacy;
            if (r.session_id) |v| r.gpa.free(v);
            r.session_id = r.incoming_session;
            r.incoming_session = null;
            if (r.listen_last_event_id) |v| r.gpa.free(v);
            r.listen_last_event_id = null;
            try r.stepLegacy(.{ .initialize_answered = .{ .session = r.session_id != null } });
            // A new session may hold different tools.
            if (!first) try r.stepCatalog(.{ .process_started = .legacy });
        } else {
            try r.stepLegacy(.initialize_failed);
            if (!first) r.emit(.{ .failed = if (l.needs_auth) .needs_auth else .session });
        }
        if (first) try r.stepEra(if (r.bad_session) .{ .initialize_error = false } else event);
    }

    fn onInitializeEnded(r: *Server, l: *Logical, key: u64) Error!void {
        // An answer would have freed it: initialize ended without one.
        l.used = false;
        try r.stepRequest(.{ .transport_lost = key });
        const first = r.detector.state == .initializing;
        try r.stepLegacy(.initialize_failed);
        if (first) try r.stepEra(.{ .initialize_error = false }) else r.emit(.{ .failed = if (l.needs_auth) .needs_auth else .session });
    }

    fn onLegacyAnswer(r: *Server, l: *Logical, key: u64, status: u16, body: @FieldType(wire.Response, "body")) Error!void {
        const s = &r.legacy.?;
        const req = s.find(key) orelse return;
        if (req.state != .posted and req.state != .resuming) return;
        // A 404 is the session's end even with a JSON-RPC error in its body,
        // as the TypeScript SDK sends; a failed resume answers nothing. The
        // end of the request decides (in a 2025 session).
        if (status == 404 or (req.state == .resuming and status >= 300)) return;
        try r.stepRequest(.{ .response_received = .{ .id = key, .response = if (body == .result) .result else .peer_error } });
        switch (l.what) {
            .list => try r.stepCatalog(try r.pageEvent(body)),
            .call => _ = try r.callAnswer(body),
            else => {},
        }
        try r.stepLegacy(.{ .answered = key });
    }

    fn onLegacyEnded(r: *Server, l: *Logical, key: u64, status: u16, how: http.Ending) Error!void {
        _ = l;
        const s = &r.legacy.?;
        const req = s.find(key) orelse return;
        if (req.state != .posted and req.state != .resuming) return;
        try r.stepLegacy(if (status == 404)
            // `expired` takes a request without a session id for a refusal.
            .{ .expired = key }
        else if (status >= 300)
            .{ .refused = key }
        else switch (how) {
            // A stream that ended or broke before the answer, which the
            // server may have closed to be polled.
            .complete, .accepted, .broken => .{ .broke = key },
            .http_failure, .rejected => .{ .refused = key },
        });
    }

    /// Any refusal of the listening GET but a session 404 means the
    /// server offers no stream.
    fn onListenEnded(r: *Server, status: u16, how: http.Ending) Error!void {
        r.listen_key = null;
        try r.stepLegacy(if (status == 404 and r.session_id != null)
            .listen_expired
        else if (status >= 300 or how == .http_failure)
            .listen_refused
        else
            .{ .listen_broke = null });
        try r.listenSettled();
    }

    /// A list or call in a 2025 session ended, over either transport: the
    /// host hears.
    fn legacyDelivered(r: *Server, id: request.Id, outcome: http_legacy.Outcome) Error!void {
        const l = r.logicalFor(id) orelse return;
        // A call's -32042 error lists URL elicitations the host gets first.
        if (l.what == .call and outcome == .result) if (r.held_answer) |a| if (a == .failure and a.failure.code == url_elicitation_required) {
            try r.requiredElicitations(a.failure.data);
        };
        if (l.what == .call) r.emit(.{
            .called = .{
                .handle = l.handle,
                .outcome = switch (outcome) {
                    // Input_required has no place in a 2025 session.
                    .result => if (r.held_answer) |a| switch (a) {
                        .failure => .failure,
                        .input_required => .malformed,
                        else => .result,
                    } else .result,
                    .lost => .lost,
                    .failed, .none => if (l.needs_auth) .needs_auth else .http_failure,
                    .cancelled => .cancelled,
                },
                // Only a lost stream leaves the call maybe run.
                .maybe_ran = outcome == .lost,
                .timed_out = l.timed_out,
                .answer = if (outcome == .result) r.held_answer else null,
            },
        });
        if (l.what == .list and outcome != .result) {
            r.page_needs_auth = l.needs_auth;
            try r.stepCatalog(.page_failed);
        }
        l.used = false;
    }

    // ---- Elicitation, 2025 sessions ----

    /// A server request (`id`) or an entry of a -32042 error (no id).
    fn askElicitation(r: *Server, origin: elicit_core.Origin, id: ?[]const u8, params: []const u8) Error!void {
        var form: elicitation.Form = .{};
        const read: ?elicitation.Request = elicitation.parse(params, &form) catch null;
        const mode: elicit_core.Mode = if (read) |q| q.mode else .form;
        const eid = if (read) |q| if (mode == .url) q.elicitation_id else null else null;
        // A -32042 error lists URL elicitations with an id; any other
        // entry is skipped.
        if (origin == .required and eid == null) return;
        try r.stepElicit(.{ .asked = .{ .origin = origin, .mode = mode, .eid = eid != null, .readable = read != null } }, .{ .id = id, .eid = eid, .params = params });
    }

    fn requiredElicitations(r: *Server, data: ?[]const u8) Error!void {
        var found: [1]?[]const u8 = undefined;
        wire.objectFields(data orelse return, &.{"elicitations"}, &found) catch return;
        var list: wire.Elements = undefined;
        list.init(found[0] orelse return) catch return;
        while (list.next() catch return) |entry| try r.askElicitation(.required, null, entry);
    }

    fn endElicitations(r: *Server) Error!void {
        try r.stepElicit(.session_ended, .{});
    }

    /// The slot whose held id (or elicitationId) is the token `field` of `params` names.
    fn heldSlot(r: *const Server, params: ?[]const u8, field: []const u8, comptime which: enum { id, eid }) ?u8 {
        var found: [1]?[]const u8 = undefined;
        wire.objectFields(params orelse return null, &.{field}, &found) catch return null;
        const token = found[0] orelse return null;
        for (r.elicit_held, 0..) |h, i| {
            const held = (if (which == .id) h.id else h.eid) orelse continue;
            if (r.elicit.slots[i].used and std.mem.eql(u8, held, token)) return @intCast(i);
        }
        return null;
    }

    fn forget(r: *Server, h: *Held) void {
        if (h.id) |v| r.gpa.free(v);
        if (h.eid) |v| r.gpa.free(v);
        h.id = null;
        h.eid = null;
    }

    fn stepElicit(r: *Server, event: elicit_core.Event, with: struct { id: ?[]const u8 = null, eid: ?[]const u8 = null, params: []const u8 = "", content: ?[]const u8 = null }) Error!void {
        var out: elicit_core.Output = .{};
        const held_before = r.questionsHeld();
        r.elicit.step(event, &out);
        try r.idleWhileAsking(held_before);
        if (r.tracer()) |t| try elicit_core.writeTrace(t, "remote", &r.elicit, event, &out);
        for (out.effects()) |effect| switch (effect) {
            .show => |slot| {
                // The params stay until the slot is used again, so an
                // `elicit` the host hasn't read yet stays valid.
                const h = &r.elicit_held[slot];
                const params = try r.gpa.dupe(u8, with.params);
                r.gpa.free(h.params);
                h.* = .{ .params = params };
                if (with.id) |id| h.id = try r.gpa.dupe(u8, id);
                if (with.eid) |eid| h.eid = try r.gpa.dupe(u8, eid);
                r.emit(.{ .elicit = .{ .slot = slot, .params = h.params, .required = event.asked.origin == .required } });
            },
            .reject => |why| {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                try switch (why) {
                    .invalid_params => wire.writeFailure(&body.writer, with.id.?, wire.code.invalid_params, "Unsupported elicitation"),
                    .too_many => wire.writeFailure(&body.writer, with.id.?, wire.code.internal_error, "Too many elicitations"),
                };
                try r.reply(body.written());
            },
            .send => |s| {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                var w: wire.Writer = try .result(&body.writer, r.elicit_held[s.slot].id.?);
                try w.field("action");
                try w.string(@tagName(s.action));
                if (s.content) {
                    try w.field("content");
                    try w.raw(with.content.?);
                }
                try w.end();
                try r.reply(body.written());
            },
            .withdraw => |slot| r.emit(.{ .elicit_withdrawn = slot }),
            .complete => |slot| r.emit(.{ .elicitation_complete = slot }),
            .release => |slot| r.forget(&r.elicit_held[slot]),
        };
    }

    // ---- OAuth ----

    /// Every request goes out through here: it is kept until it ends, and the
    /// gate puts the token on it, or holds it for a refresh. The gate's answer
    /// for this request is posted at once, so a send that can't go out is the
    /// caller's to handle, as before.
    fn send(r: *Server, key: u64, method: http.Method, body: ?[]const u8, headers: []const std.http.Header) Error!void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const copies = try a.alloc(std.http.Header, headers.len + 1);
        for (headers, copies[0..headers.len]) |h, *c| c.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        try r.outbox.append(r.gpa, .{ .key = key, .method = method, .body = if (body) |b| try a.dupe(u8, b) else null, .headers = copies, .arena = arena });
        try r.auth.beforeSend(key);
        r.runAuth(key) catch |err| {
            // It never went out: the gate forgets it too.
            if (r.kept(key) != null) {
                r.unkeep(key);
                _ = r.auth.ended(key, .forgotten) catch {};
            }
            return err;
        };
    }

    fn kept(r: *Server, key: u64) ?*Kept {
        for (r.outbox.items) |*k| if (k.key == key) return k;
        return null;
    }

    fn unkeep(r: *Server, key: u64) void {
        for (r.outbox.items, 0..) |*k, i| if (k.key == key) {
            k.arena.deinit();
            _ = r.outbox.swapRemove(i);
            return;
        };
    }

    /// Closes request `key`'s stream; the gate forgets it.
    fn closeKey(r: *Server, key: u64) Error!void {
        r.client.cancel(key);
        if (r.kept(key) == null) return;
        r.unkeep(key);
        _ = try r.auth.ended(key, .forgotten);
        try r.runAuth(null);
    }

    /// Carries out what the OAuth side asked for. A post of `now_key` fails
    /// to the caller; any other that can't go out ends as a broken stream.
    fn runAuth(r: *Server, now_key: ?u64) Error!void {
        while (r.auth.actions.items.len > 0) {
            const action = r.auth.actions.orderedRemove(0);
            switch (action) {
                .post => |p| if (now_key != null and p.key == now_key.?) {
                    try r.dispatch(p.key, p.token);
                } else r.dispatch(p.key, p.token) catch |err| switch (err) {
                    error.TooManyInFlight, error.ConcurrencyUnavailable => try r.onEnded(p.key, 0, .broken, null),
                    else => return err,
                },
                .give_up => |g| try r.authGaveUp(g.key, g.why),
                .needs_sign_in => |n| r.emit(.{ .auth_required = .{ .step_up = n.step_up } }),
                .authorize => |url| r.emit(.{ .authorize = url }),
                .signed_in => r.emit(.signed_in),
                .sign_in_failed => |f| r.emit(.{ .sign_in_failed = .{ .why = f.why, .message = f.message } }),
                .save => r.emit(.credential),
            }
        }
    }

    /// Posts a kept request with the token's `Authorization`, in
    /// the kept headers' spare slot; `send` copies them all.
    fn dispatch(r: *Server, key: u64, token: u32) Error!void {
        const k = r.kept(key) orelse return;
        var count = k.headers.len - 1;
        if (r.auth.authorization(token)) |value| {
            k.headers[count] = .{ .name = "authorization", .value = value };
            count += 1;
        }
        try r.client.send(key, k.method, k.body, k.headers[0..count]);
    }

    /// The gate gave up on `key`. Before the era is known that stops detection;
    /// otherwise the request ends as it would have: a 401 for want of a
    /// sign-in, a broken stream when the refresh got no answer.
    fn authGaveUp(r: *Server, key: u64, why: auth_core.GiveUp) Error!void {
        r.unkeep(key);
        if (key < aux_base) if (r.logicalFor(key)) |l| {
            l.needs_auth = why == .needs_sign_in;
            if ((l.what == .discover or l.what == .initialize) and !r.detector.ready()) return r.abortDetection();
        };
        try r.onEndedDomain(key, if (why == .needs_sign_in) 401 else 0, if (why == .needs_sign_in) .http_failure else .broken);
    }

    /// A rejection says nothing about the era. Detection stops, and the
    /// host signs in and detects again, as a new run with its own traces.
    fn abortDetection(r: *Server) Error!void {
        for (&r.logicals) |*l| if (l.used and (l.what == .discover or l.what == .initialize)) {
            if (l.id) |id| {
                try r.stepRequest(.{ .transport_lost = id });
                try r.closeKey(id);
            }
            l.used = false;
        };
        var i: usize = 0;
        while (i < r.timers.items.len) {
            if (r.timers.items[i].kind == .probe) _ = r.timers.swapRemove(i) else i += 1;
        }
        r.legacy = null;
        try r.endElicitations();
        r.newEraRun();
        r.emit(.{ .failed = .needs_auth });
    }

    /// Detection starts over as a new run, with its own era and session
    /// trace instance.
    fn newEraRun(r: *Server) void {
        r.detector = .init(r.options.era);
        r.era_run += 1;
        r.era_instance = std.fmt.bufPrint(&r.era_instance_buf, "remote.{d}", .{r.era_run}) catch "remote.n";
    }

    // ---- shared machines ----

    fn stepRequest(r: *Server, event: request.Event) Error!void {
        var out: request.Output = .{};
        r.table.step(event, &out) catch return;
        if (r.tracer()) |t| try request.writeTrace(t, "remote", &out);
        // A timeout comes with its cancel first: mark it before either runs.
        for (out.effects()) |effect| if (effect == .deliver and effect.deliver.outcome == .timed_out) {
            if (r.logicalFor(effect.deliver.id)) |l| l.timed_out = true;
        };
        for (out.effects()) |effect| switch (effect) {
            .write_request => {},
            // 2026: no cancel message, the exchange's close effect
            // closes the stream. 2025: the session posts one.
            // Stdio: notifications/cancelled, as the request names it.
            .send_cancel => |id| if (r.stdio) {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                var w: wire.Writer = try .notification(&body.writer, "notifications/cancelled", .{});
                try w.field("requestId");
                try w.int(@intCast(id));
                try w.end();
                r.proc.send(.notification, body.written()) catch {};
            } else try r.stepLegacy(.{ .cancel = id }),
            .deliver => |d| if (r.stdio) try r.stdioDelivered(d.id, d.outcome) else switch (d.outcome) {
                .timed_out => if (r.legacy == null) if (r.logicalFor(d.id)) |l| try r.stepExchange(l, .cancel),
                // The server ended the listen; its stream closes.
                .ended => if (r.logicalFor(d.id)) |l| {
                    try r.stepSubs(.{ .final = .{ .id = d.id, .end = .server_cancelled } });
                    try r.stepExchange(l, .cancel);
                },
                else => {},
            },
            .arm_timer => |a| try r.timers.append(r.gpa, .{ .kind = .{ .request = a.timer }, .due_ms = r.now() + a.after_ms }),
            .disarm_timers => |id| {
                var i: usize = 0;
                while (i < r.timers.items.len) {
                    const t = r.timers.items[i];
                    if (t.kind == .request and t.kind.request.id == id) _ = r.timers.swapRemove(i) else i += 1;
                }
            },
        };
    }

    fn stepEra(r: *Server, event: era.Event) Error!void {
        var out: era.Output = .{};
        r.detector.step(event, &out) catch return;
        if (r.tracer()) |t| try era.writeTrace(t, r.era_instance, &out);
        for (out.effects()) |effect| switch (effect) {
            .send_discover => |i| {
                // Detection went back to probing; a session started for
                // the fallback is dropped.
                r.legacy = null;
                try r.endElicitations();
                const l = try r.newLogical(.{ .discover = i }, .idempotent);
                if (r.stdio) try r.sendAttempt(l) else try r.stepExchange(l, .send);
            },
            .send_initialize => if (r.stdio) try r.sendAttempt(try r.newLogical(.initialize, .idempotent)) else try r.startSession(),
            // Over HTTP the session posts it once initialize is answered.
            .send_initialized => if (r.stdio) {
                var body: std.Io.Writer.Allocating = .init(r.gpa);
                defer body.deinit();
                try era.writeInitialized(&body.writer);
                r.proc.send(.notification, body.written()) catch {};
            },
            .arm_probe_timer => |a| try r.timers.append(r.gpa, .{ .kind = .{ .probe = a.probe }, .due_ms = r.now() + a.after_ms }),
            .ready => |v| {
                // The catalog starts over for each new process or detection
                // run; a new 2025 session in a run does that too.
                const run = if (r.stdio) r.era_generation else r.era_run;
                const first = r.catalog_generation != run;
                r.catalog_generation = run;
                if (r.stdio) r.proc.setEra(if (v == .legacy) .legacy else .modern) catch {};
                r.emit(.{ .ready = era.versionName(r.detector.config, v).? });
                if (first) try r.stepCatalog(.{ .process_started = if (v == .legacy) .legacy else .modern });
                // The listens a process exit ended go out again.
                if (r.stdio and v != .legacy and !r.subs.up) try r.stepSubs(.transport_up);
                if (first and v != .legacy and r.options.listen_tools) try r.listen(0, subscription.bit(.tools), false);
            },
            .failed => |f| {
                // Stdio: a process that can't be detected is stopped, and the
                // next start is a new one.
                if (r.stdio) r.proc.stop() catch {};
                r.emit(.{ .failed = .{ .era = f } });
            },
        };
    }

    fn stepCatalog(r: *Server, event: catalog.Event) Error!void {
        var out: catalog.Output = .{};
        r.catalog.step(event, &out) catch return;
        if (r.tracer()) |t| try catalog.writeTrace(t, "remote", &out);
        for (out.effects()) |effect| switch (effect) {
            .send_page => {
                const l = try r.newLogical(.list, .idempotent);
                try r.start(l);
            },
            .discard_pages => r.store.discard(),
            .publish => |fresh| {
                r.store.publish();
                r.emit(.{ .tools = .{ .ok = true, .fresh = fresh, .dropped = r.last_added } });
                try r.relisted(true);
            },
            .fail => {
                r.store.discard();
                r.emit(.{ .tools = .{ .ok = false, .fresh = false, .needs_auth = r.page_needs_auth } });
                r.page_needs_auth = false;
                try r.relisted(false);
            },
            .serve => r.emit(.{ .tools = .{ .ok = true, .fresh = true } }),
            .arm_expiry => |a| try r.timers.append(r.gpa, .{ .kind = .{ .expiry = a.generation }, .due_ms = r.now() + a.after_ms }),
        };
    }

    /// Calls waiting for a re-list after -32020 go on.
    fn relisted(r: *Server, ok: bool) Error!void {
        if (r.stdio or r.legacy != null) return;
        for (&r.logicals) |*l| if (l.used and l.exchange.phase == .relisting) try r.stepExchange(l, .{ .relisted = ok });
    }

    // ---- Subscriptions ----

    /// Sends a listen for `sub` as a new 2026 exchange; its id comes with
    /// the attempt.
    fn listen(r: *Server, sub: u8, filter: subscription.Filter, resend: bool) Error!void {
        if (!resend and !r.subs.canOpen(sub)) return;
        const l = try r.newLogical(.listen, .call);
        l.sub = sub;
        l.filter = filter;
        l.resend = resend;
        if (r.stdio) try r.sendAttempt(l) else try r.stepExchange(l, .send);
    }

    fn stepSubs(r: *Server, event: subscription.Event) Error!void {
        var out: subscription.Output = .{};
        r.subs.step(event, &out);
        if (r.tracer()) |t| try subscription.writeTrace(t, "remote", &r.subs, event, &out);
        for (out.effects()) |effect| switch (effect) {
            // The tool list is refreshed when the host next needs it.
            .deliver => |d| if (d.kind == .tools) try r.stepCatalog(.invalidated),
            .acknowledged => |a| r.emit(.{ .listening = a.filter }),
            .ended => |e| r.emit(.{ .listen_ended = e.end }),
            // On 2026 HTTP the stream closes; on stdio
            // notifications/cancelled goes out.
            .cancel_listen => |id| if (r.logicalFor(id)) |l| {
                try r.stepRequest(.{ .cancel_requested = id });
                if (!r.stdio) try r.stepExchange(l, .cancel);
            },
            // On stdio the listens go out again when the process is back.
            .arm_retry => |a| if (!r.stdio) try r.timers.append(r.gpa, .{ .kind = .{ .relisten = .{ .sub = a.sub, .generation = a.generation } }, .due_ms = r.now() + a.after_ms }),
            .relisten => |sub| try r.listen(sub, r.subs.subs[sub].asked, true),
        };
    }

    fn fireTimers(r: *Server) Error!void {
        var i: usize = 0;
        while (i < r.timers.items.len) {
            const t = r.timers.items[i];
            if (t.due_ms > r.now()) {
                i += 1;
                continue;
            }
            _ = r.timers.swapRemove(i);
            switch (t.kind) {
                .request => |timer| try r.stepRequest(.{ .timer_fired = timer }),
                .probe => |probe| try r.stepEra(.{ .probe_timer_fired = probe }),
                .expiry => |generation| try r.stepCatalog(.{ .expired = generation }),
                .resume_stream => |id| try r.stepLegacy(.{ .resume_due = id }),
                .listen => try r.stepLegacy(.listen_due),
                .listen_wait => try r.listenSettled(),
                .backoff => |handle| if (r.logicalByHandle(handle)) |l| try r.stepChain(l, .backoff_elapsed),
                .relisten => |x| try r.stepSubs(.{ .retry_due = .{ .sub = x.sub, .generation = x.generation } }),
            }
            i = 0;
        }
    }
};

test {
    // Behavior is tested by the conformance suite and the Bun driver, which
    // run cli/conformance.zig on this; this makes sure everything compiles.
    std.testing.refAllDecls(Server);
}
