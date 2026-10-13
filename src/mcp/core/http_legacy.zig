//! Streamable HTTP with 2025 sessions, client side, one endpoint. Each event
//! is one action, or a client action followed by the client actions it makes
//! enabled right away (posting queued requests and opening the listening
//! stream once a session is ready). Every action taken is one trace record.
//!
//! The host keeps the strings: the session id and each stream's last event
//! id. This core only decides what goes out.

const std = @import("std");
const request = @import("request.zig");
const trace = @import("../io/trace.zig");

pub const Id = request.Id;

pub const Phase = enum { start, initializing, ready, failed, closed };
pub const Listen = enum { off, open, waiting, none };
pub const State = enum { idle, posted, broken, resuming, queued, done };
pub const Outcome = enum { none, result, lost, failed, cancelled };

pub const Config = struct {
    /// Resumes per request stream.
    max_resumes: u8 = 2,
    /// The wait before resuming when the server sent no `retry`.
    default_retry_ms: u32 = 1000,
    /// Whether to open the listening GET stream.
    listen: bool = true,
    /// The listening stream reconnects after 1 s doubling to 30 s, at most
    /// this many times in a row, then waits for the host.
    max_listen_attempts: u8 = 8,
};

pub const Request = struct {
    used: bool = false,
    id: Id = 0,
    state: State = .idle,
    /// The session it went out in, 0 for none.
    session: u32 = 0,
    posts: u8 = 0,
    after_404: bool = false,
    has_event: bool = false,
    resumes: u8 = 0,
    /// The stream's `retry`, if the server sent one.
    retry_ms: ?u32 = null,
    outcome: Outcome = .none,
};

pub const Event = union(enum) {
    /// The host connects: initialize goes out.
    start,
    /// The host sends request `id`.
    send: Id,
    /// initialize was answered; `session` says whether it assigned an id.
    initialize_answered: struct { session: bool },
    /// initialize failed, a 404 included: it carried no session id.
    initialize_failed,
    /// An SSE event with an id (or a `retry`) on `id`'s stream.
    event_seen: struct { id: Id, has_id: bool, retry_ms: ?u32 },
    answered: Id,
    /// The stream broke before the answer.
    broke: Id,
    /// A status without a JSON-RPC answer, other than a session 404.
    refused: Id,
    /// A 404 to a POST or resume that carried a session id.
    expired: Id,
    /// The retry wait for `id` is over.
    resume_due: Id,
    cancel: Id,
    /// The listening GET was answered 405.
    listen_refused,
    /// The listening stream broke; the server's `retry`, if it sent one.
    listen_broke: ?u32,
    /// The listening GET was answered 404 with a session id.
    listen_expired,
    /// The listening stream received an event, so reconnects start over.
    listen_event,
    listen_due,
    close,
};

pub const Effect = union(enum) {
    /// POST initialize without a session id.
    post_initialize,
    /// POST notifications/initialized in the new session.
    post_initialized,
    /// POST request `id` in the current session.
    post: Id,
    /// POST notifications/cancelled for `id`.
    post_cancel: Id,
    /// GET `id`'s stream with its Last-Event-ID.
    get_resume: Id,
    arm_resume: struct { id: Id, after_ms: u32 },
    open_listen,
    close_listen,
    arm_listen: u32,
    /// DELETE the session.
    delete,
    deliver: struct { id: Id, outcome: Outcome },
};

/// One model action, for the trace.
pub const Transition = struct {
    action: []const u8,
    id: Id = 0,
    from: Phase,
    to: Phase,
    /// Accepted where the model's action is disabled; nothing changed.
    ignored: bool = false,
};

pub const max_effects = 96;
pub const max_transitions = 72;

pub const Output = struct {
    effect_buffer: [max_effects]Effect = undefined,
    effect_count: usize = 0,
    transition_buffer: [max_transitions]Transition = undefined,
    transition_count: usize = 0,
    /// Each transition's state after it, for the trace.
    after: [max_transitions]Snapshot = undefined,

    pub fn effects(out: *const Output) []const Effect {
        return out.effect_buffer[0..out.effect_count];
    }

    pub fn transitions(out: *const Output) []const Transition {
        return out.transition_buffer[0..out.transition_count];
    }

    fn push(out: *Output, effect: Effect) void {
        out.effect_buffer[out.effect_count] = effect;
        out.effect_count += 1;
    }
};

/// The state a trace record shows: the session, and the stepped request.
pub const Snapshot = struct {
    sid: u32,
    listen: Listen,
    deleted: bool,
    request: ?Request,
};

pub const StepError = error{ TooManyRequests, UnknownRequest, AlreadySent };

pub const Session = struct {
    config: Config,
    requests: []Request,
    phase: Phase = .start,
    sid: u32 = 0,
    next_sid: u32 = 1,
    listen: Listen = .off,
    deleted: bool = false,
    listen_attempts: u8 = 0,

    pub fn init(requests: []Request, config: Config) Session {
        for (requests) |*r| r.* = .{};
        return .{ .config = config, .requests = requests };
    }

    pub fn find(s: *Session, id: Id) ?*Request {
        for (s.requests) |*r| if (r.used and r.id == id) return r;
        return null;
    }

    pub fn step(s: *Session, event: Event, out: *Output) StepError!void {
        out.* = .{};
        switch (event) {
            .start => {
                if (s.phase != .start) return s.ignore("start", 0, out);
                const from = s.phase;
                s.phase = .initializing;
                out.push(.post_initialize);
                s.record("start", 0, from, out);
            },
            .send => |id| {
                if (s.find(id) != null) return error.AlreadySent;
                if (s.phase == .failed or s.phase == .closed) {
                    out.push(.{ .deliver = .{ .id = id, .outcome = .failed } });
                    return s.ignore("post", id, out);
                }
                const r = for (s.requests) |*r| {
                    if (!r.used) break r;
                } else return error.TooManyRequests;
                r.* = .{ .used = true, .id = id };
                if (s.phase == .ready) s.post(r, out) else {
                    r.state = .queued;
                    s.record("hold", id, s.phase, out);
                }
            },
            .initialize_answered => |a| {
                if (s.phase != .initializing) return s.ignore("init_answered", 0, out);
                const from = s.phase;
                s.phase = .ready;
                if (a.session) {
                    s.sid = s.next_sid;
                    s.next_sid += 1;
                } else s.sid = 0;
                if (s.listen == .open or s.listen == .waiting) out.push(.close_listen);
                if (s.listen != .none) s.listen = .off;
                out.push(.post_initialized);
                s.record(if (a.session) "init_answered_with_id" else "init_answered_without_id", 0, from, out);
                // The client actions this enables, taken at once.
                for (s.requests) |*r| if (r.used and r.state == .queued) s.post(r, out);
                s.openListen(out);
            },
            .initialize_failed => {
                if (s.phase != .initializing) return s.ignore("init_failed", 0, out);
                const from = s.phase;
                s.phase = .failed;
                s.endAll(.failed, out);
                if (s.listen == .open or s.listen == .waiting) out.push(.close_listen);
                if (s.listen != .none) s.listen = .off;
                s.record("init_failed", 0, from, out);
            },
            .event_seen => |e| {
                const r = s.find(e.id) orelse return error.UnknownRequest;
                if (r.state != .posted and r.state != .resuming) return s.ignore("event", e.id, out);
                if (e.retry_ms) |ms| r.retry_ms = ms;
                // A `retry` alone is no event id: nothing the model sees changes.
                if (!e.has_id) return;
                r.has_event = true;
                s.record("event", e.id, s.phase, out);
            },
            .answered => |id| {
                const r = s.find(id) orelse return error.UnknownRequest;
                if (r.state != .posted and r.state != .resuming) return s.ignore("answer", id, out);
                s.end(r, .result, out);
                s.record("answer", id, s.phase, out);
            },
            .broke => |id| {
                const r = s.find(id) orelse return error.UnknownRequest;
                if (r.state != .posted and r.state != .resuming) return s.ignore("break", id, out);
                if (r.has_event and r.resumes < s.config.max_resumes) {
                    r.state = .broken;
                    out.push(.{ .arm_resume = .{ .id = id, .after_ms = r.retry_ms orelse s.config.default_retry_ms } });
                } else s.end(r, .lost, out);
                s.record("break", id, s.phase, out);
            },
            .refused => |id| {
                const r = s.find(id) orelse return error.UnknownRequest;
                if (r.state != .posted and r.state != .resuming) return s.ignore("refused", id, out);
                s.end(r, if (r.state == .posted) .failed else .lost, out);
                s.record("refused", id, s.phase, out);
            },
            .expired => |id| {
                const r = s.find(id) orelse return error.UnknownRequest;
                if (r.state != .posted and r.state != .resuming) return s.ignore("expired", id, out);
                // A 404 without a session id is a plain failure.
                if (r.session == 0) {
                    s.end(r, if (r.state == .posted) .failed else .lost, out);
                    return s.record("refused", id, s.phase, out);
                }
                s.inferEnd(r.session, out);
                const from = s.phase;
                if (r.state == .resuming or r.after_404) {
                    s.end(r, if (r.state == .resuming) .lost else .failed, out);
                } else {
                    r.state = .queued;
                    r.after_404 = true;
                }
                s.sawEnd(r.session, out);
                s.record("expired", id, from, out);
                // A 404 for an older session starts no new one, so the request
                // goes out again in the current session right away.
                if (r.state == .queued and s.phase == .ready) s.post(r, out);
            },
            .resume_due => |id| {
                const r = s.find(id) orelse return s.ignore("resume_due", id, out);
                if (r.state != .broken) return s.ignore("resume_due", id, out);
                if (s.phase == .ready and r.session == s.sid) {
                    r.state = .resuming;
                    r.resumes += 1;
                    out.push(.{ .get_resume = id });
                } else s.end(r, .lost, out);
                s.record("resume_due", id, s.phase, out);
            },
            .cancel => |id| {
                const r = s.find(id) orelse return s.ignore("cancel", id, out);
                if (r.state == .idle or r.state == .done) return s.ignore("cancel", id, out);
                if (r.state != .queued and s.phase == .ready and r.session == s.sid) out.push(.{ .post_cancel = id });
                s.end(r, .cancelled, out);
                s.record("cancel", id, s.phase, out);
            },
            .listen_refused => {
                if (s.listen != .open) return s.ignore("listen_refused", 0, out);
                s.listen = .none;
                s.record("listen_refused", 0, s.phase, out);
            },
            .listen_broke => |retry| {
                if (s.listen != .open) return s.ignore("listen_broke", 0, out);
                s.listen = .waiting;
                s.record("listen_broke", 0, s.phase, out);
                // Give up after too many reconnects in a row; the model
                // never forces ListenDue.
                if (s.listen_attempts < s.config.max_listen_attempts) {
                    const backoff = request.reconnectDelay(s.listen_attempts);
                    out.push(.{ .arm_listen = retry orelse backoff });
                    s.listen_attempts += 1;
                }
            },
            .listen_expired => {
                if (s.listen != .open or s.sid == 0) return s.ignore("listen_expired", 0, out);
                s.inferEnd(s.sid, out);
                const from = s.phase;
                s.listen = .off;
                s.sawEnd(s.sid, out);
                s.record("listen_expired", 0, from, out);
            },
            .listen_event => s.listen_attempts = 0,
            .listen_due => {
                if (s.listen != .waiting) return s.ignore("listen_due", 0, out);
                s.listen = .off;
                s.record("listen_due", 0, s.phase, out);
                s.openListen(out);
            },
            .close => {
                if (s.phase != .start and s.phase != .initializing and s.phase != .ready) return s.ignore("close", 0, out);
                const from = s.phase;
                // A 404 for the current session always starts a new one, so a
                // ready session's id is live.
                s.deleted = s.phase == .ready and s.sid != 0;
                if (s.deleted) out.push(.delete);
                s.phase = .closed;
                s.endAll(.cancelled, out);
                if (s.listen == .open or s.listen == .waiting) out.push(.close_listen);
                if (s.listen != .none) s.listen = .off;
                s.record("close", 0, from, out);
            },
        }
    }

    fn post(s: *Session, r: *Request, out: *Output) void {
        const from = s.phase;
        r.state = .posted;
        r.session = s.sid;
        r.posts += 1;
        r.has_event = false;
        r.resumes = 0;
        r.retry_ms = null;
        out.push(.{ .post = r.id });
        s.record("post", r.id, from, out);
    }

    fn openListen(s: *Session, out: *Output) void {
        if (!s.config.listen or s.phase != .ready or s.listen != .off) return;
        s.listen = .open;
        out.push(.open_listen);
        s.record("listen_open", 0, s.phase, out);
    }

    /// For the trace: the server ended `session` before the 404 that shows it,
    /// which is the model's EndSession. A 404 for the ready session is the
    /// first sign; an older session's end was seen before, and while a new
    /// session starts, so was the current one's.
    fn inferEnd(s: *Session, session: u32, out: *Output) void {
        if (session == s.sid and s.phase == .ready) s.record("end_session", 0, s.phase, out);
    }

    /// A 404 carrying session `session`: re-initialize when it is the current
    /// one and no re-initialize is under way.
    fn sawEnd(s: *Session, session: u32, out: *Output) void {
        if (session != s.sid or s.phase != .ready) return;
        s.phase = .initializing;
        out.push(.post_initialize);
    }

    fn end(_: *Session, r: *Request, outcome: Outcome, out: *Output) void {
        r.state = .done;
        r.outcome = outcome;
        out.push(.{ .deliver = .{ .id = r.id, .outcome = outcome } });
    }

    fn endAll(s: *Session, outcome: Outcome, out: *Output) void {
        for (s.requests) |*r| switch (r.state) {
            .posted, .broken, .resuming, .queued => s.end(r, outcome, out),
            else => {},
        };
    }

    /// Frees the slots of requests that ended, after the host read their outcomes.
    pub fn sweep(s: *Session) void {
        for (s.requests) |*r| if (r.used and r.state == .done) {
            r.* = .{};
        };
    }

    fn record(s: *Session, action: []const u8, id: Id, from: Phase, out: *Output) void {
        out.transition_buffer[out.transition_count] = .{ .action = action, .id = id, .from = from, .to = s.phase };
        out.after[out.transition_count] = .{ .sid = s.sid, .listen = s.listen, .deleted = s.deleted, .request = if (id == 0) null else if (s.find(id)) |r| r.* else null };
        out.transition_count += 1;
    }

    fn ignore(s: *Session, action: []const u8, id: Id, out: *Output) void {
        s.record(action, id, s.phase, out);
        out.transition_buffer[out.transition_count - 1].ignored = true;
    }
};

/// Writes each action in `out` as a trace line for machine "http_legacy".
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, out: *const Output) std.Io.Writer.Error!void {
    for (out.transitions(), 0..) |t, i| {
        const a = out.after[i];
        var fields: [11]trace.Field = undefined;
        var n: usize = 0;
        fields[n] = .{ .name = "id", .value = .{ .int = @intCast(t.id) } };
        n += 1;
        fields[n] = .{ .name = "ignored", .value = .{ .boolean = t.ignored } };
        n += 1;
        fields[n] = .{ .name = "sid", .value = .{ .int = a.sid } };
        n += 1;
        fields[n] = .{ .name = "listen", .value = .{ .string = @tagName(a.listen) } };
        n += 1;
        fields[n] = .{ .name = "deleted", .value = .{ .boolean = a.deleted } };
        n += 1;
        if (a.request) |r| {
            fields[n] = .{ .name = "st", .value = .{ .string = @tagName(r.state) } };
            fields[n + 1] = .{ .name = "req_sid", .value = .{ .int = r.session } };
            fields[n + 2] = .{ .name = "posts", .value = .{ .int = r.posts } };
            fields[n + 3] = .{ .name = "after404", .value = .{ .boolean = r.after_404 } };
            fields[n + 4] = .{ .name = "ev", .value = .{ .boolean = r.has_event } };
            fields[n + 5] = .{ .name = "resumes", .value = .{ .int = r.resumes } };
            n += 6;
        }
        try writer.write(.{
            .machine = "http_legacy",
            .instance = instance,
            .event = t.action,
            .from = @tagName(t.from),
            .to = @tagName(t.to),
            .data = fields[0..n],
        });
    }
}

// ---------------------------------------------------------------------------
// Tests. Each property of the model is checked after every step of every
// event sequence to a small depth, against a test server that only does what
// the model's server may do.

const testing = std.testing;

/// What the model's ghosts and server know, kept beside the core.
const World = struct {
    server_ended: [8]bool = @splat(false),
    seen_end: [8]bool = @splat(false),
    inits: u32 = 0,
    sent_closed: bool = false,
    refused_405: bool = false,
    listen_after_405: bool = false,
    events: u8 = 0,

    fn sends(out: *const Output) bool {
        for (out.effects()) |e| switch (e) {
            .post_initialize, .post_initialized, .post, .post_cancel, .get_resume, .open_listen, .delete => return true,
            else => {},
        };
        return false;
    }

    /// Records what the step did, and checks the model's invariants.
    fn check(w: *World, s: *const Session, before_phase: Phase, out: *const Output) !void {
        if (before_phase == .closed and sends(out)) w.sent_closed = true;
        for (out.effects()) |e| switch (e) {
            .post_initialize => w.inits += 1,
            .open_listen => if (w.refused_405) {
                w.listen_after_405 = true;
            },
            else => {},
        };
        var seen: u32 = 0;
        for (w.seen_end, 0..) |b, i| if (b) {
            seen += 1;
            try testing.expect(w.server_ended[i]); // SeenOnlyEnded
        };
        try testing.expect(w.inits <= 1 + seen); // OneInitPerEnd
        try testing.expect(!w.sent_closed); // NothingAfterClose
        try testing.expect(!w.listen_after_405); // ListenRespects405
        if (s.deleted) try testing.expect(s.phase == .closed and s.sid != 0 and !w.seen_end[s.sid]); // DeleteOnlyLive
        for (s.requests) |r| if (r.used) {
            try testing.expect(r.posts <= 2 and (r.posts < 2 or r.after_404)); // NoReplayOfLostPost
            if (r.state == .broken or r.state == .resuming) try testing.expect(r.has_event and r.resumes <= s.config.max_resumes); // ResumeAfterEventId
        };
        // ResumeSameSession: a resume goes out only for the current session.
        for (out.effects()) |e| if (e == .get_resume) try testing.expectEqual(s.sid, s.requests[0..][indexOf(s, e.get_resume)].session);
    }
};

fn indexOf(s: *const Session, id: Id) usize {
    for (s.requests, 0..) |r, i| if (r.used and r.id == id) return i;
    unreachable;
}

/// The events the test server and client may take next.
fn candidates(s: *Session, w: *const World, ids: []const Id, buf: []Event) []Event {
    var n: usize = 0;
    const add = struct {
        fn f(b: []Event, count: *usize, e: Event) void {
            if (count.* < b.len) {
                b[count.*] = e;
                count.* += 1;
            }
        }
    }.f;
    if (s.phase == .start) add(buf, &n, .start);
    add(buf, &n, .close);
    if (s.phase == .initializing) {
        if (s.next_sid < w.server_ended.len) add(buf, &n, .{ .initialize_answered = .{ .session = true } });
        add(buf, &n, .{ .initialize_answered = .{ .session = false } });
        add(buf, &n, .initialize_failed);
    }
    if (s.listen == .open) {
        add(buf, &n, .listen_refused);
        add(buf, &n, .{ .listen_broke = null });
        if (s.sid != 0 and w.server_ended[s.sid]) add(buf, &n, .listen_expired);
    }
    if (s.listen == .waiting) add(buf, &n, .listen_due);
    for (ids) |id| {
        const r = s.find(id) orelse {
            add(buf, &n, .{ .send = id });
            continue;
        };
        switch (r.state) {
            .posted, .resuming => {
                if (w.events < 3) add(buf, &n, .{ .event_seen = .{ .id = id, .has_id = true, .retry_ms = 5 } });
                add(buf, &n, .{ .answered = id });
                add(buf, &n, .{ .broke = id });
                add(buf, &n, .{ .refused = id });
                if (r.session != 0 and w.server_ended[r.session]) add(buf, &n, .{ .expired = id });
            },
            .broken => add(buf, &n, .{ .resume_due = id }),
            else => {},
        }
        add(buf, &n, .{ .cancel = id });
    }
    return buf[0..n];
}

fn explore(s: Session, slots: [2]Request, w: World, depth: u8, end_session: bool) !void {
    if (depth == 0) return;
    var buf: [32]Event = undefined;
    var copy = s;
    var copy_slots = slots;
    copy.requests = &copy_slots;
    const ids = [_]Id{ 1, 2 };
    for (candidates(&copy, &w, &ids, &buf)) |event| {
        var next = s;
        var next_slots = slots;
        next.requests = &next_slots;
        var nw = w;
        if (end_session and next.sid != 0) nw.server_ended[next.sid] = true;
        if (event == .event_seen) nw.events += 1;
        if (event == .expired) {
            if (next.find(event.expired)) |r| nw.seen_end[r.session] = true;
        }
        if (event == .listen_expired) nw.seen_end[next.sid] = true;
        if (event == .listen_refused) nw.refused_405 = true;
        const before = next.phase;
        var out: Output = .{};
        try next.step(event, &out);
        try nw.check(&next, before, &out);
        try explore(next, next_slots, nw, depth - 1, end_session);
    }
}

test "every event sequence to depth 5 keeps the model's invariants" {
    var slots: [2]Request = undefined;
    const s: Session = .init(&slots, .{ .max_resumes = 1 });
    try explore(s, slots, .{}, 5, false);
    // Again, with the server ending each session as soon as it exists.
    try explore(s, slots, .{}, 5, true);
}

fn steps(s: *Session, events: []const Event) !Output {
    var out: Output = .{};
    for (events) |e| try s.step(e, &out);
    return out;
}

test "requests wait for the session, then go out with its id" {
    var slots: [2]Request = undefined;
    var s: Session = .init(&slots, .{ .listen = false });
    _ = try steps(&s, &.{ .start, .{ .send = 7 } });
    try testing.expectEqual(State.queued, s.find(7).?.state);
    const out = try steps(&s, &.{.{ .initialize_answered = .{ .session = true } }});
    try testing.expectEqualSlices(Effect, &.{ .post_initialized, .{ .post = 7 } }, out.effects());
    try testing.expectEqual(@as(u32, 1), s.find(7).?.session);
}

test "a 404 re-initializes once and re-sends only the requests that got it" {
    var slots: [2]Request = undefined;
    var s: Session = .init(&slots, .{ .listen = false });
    _ = try steps(&s, &.{ .start, .{ .initialize_answered = .{ .session = true } }, .{ .send = 1 }, .{ .send = 2 } });
    var out = try steps(&s, &.{.{ .expired = 1 }});
    try testing.expectEqualSlices(Effect, &.{.post_initialize}, out.effects());
    // The second 404 of the same session starts nothing more.
    out = try steps(&s, &.{.{ .expired = 2 }});
    try testing.expectEqual(@as(usize, 0), out.effects().len);
    out = try steps(&s, &.{.{ .initialize_answered = .{ .session = true } }});
    try testing.expectEqualSlices(Effect, &.{ .post_initialized, .{ .post = 1 }, .{ .post = 2 } }, out.effects());
    // A second 404 for a re-sent request fails it: no loop.
    out = try steps(&s, &.{.{ .expired = 1 }});
    try testing.expectEqual(Effect{ .deliver = .{ .id = 1, .outcome = .failed } }, out.effects()[0]);
}

test "a 404 for an older session re-sends at once in the current one, without a new session" {
    var slots: [2]Request = undefined;
    var s: Session = .init(&slots, .{ .listen = false });
    _ = try steps(&s, &.{ .start, .{ .initialize_answered = .{ .session = true } }, .{ .send = 1 }, .{ .send = 2 }, .{ .expired = 1 }, .{ .initialize_answered = .{ .session = true } } });
    // Request 2 went out in session 1, which ended.
    const out = try steps(&s, &.{.{ .expired = 2 }});
    try testing.expectEqualSlices(Effect, &.{.{ .post = 2 }}, out.effects());
    try testing.expectEqual(@as(u32, 2), s.find(2).?.session);
    try testing.expectEqual(Phase.ready, s.phase);
}

test "a broken stream resumes after its event id and retry, and is lost without one" {
    var slots: [2]Request = undefined;
    var s: Session = .init(&slots, .{ .listen = false });
    _ = try steps(&s, &.{ .start, .{ .initialize_answered = .{ .session = true } }, .{ .send = 1 }, .{ .send = 2 } });
    var out = try steps(&s, &.{ .{ .event_seen = .{ .id = 1, .has_id = true, .retry_ms = 500 } }, .{ .broke = 1 } });
    try testing.expectEqualSlices(Effect, &.{.{ .arm_resume = .{ .id = 1, .after_ms = 500 } }}, out.effects());
    out = try steps(&s, &.{.{ .resume_due = 1 }});
    try testing.expectEqualSlices(Effect, &.{.{ .get_resume = 1 }}, out.effects());
    // A `retry` without an id is no event id: the stream is lost, not re-POSTed.
    out = try steps(&s, &.{ .{ .event_seen = .{ .id = 2, .has_id = false, .retry_ms = 10 } }, .{ .broke = 2 } });
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .{ .id = 2, .outcome = .lost } }}, out.effects());
}

test "a stream isn't resumed in a newer session" {
    var slots: [2]Request = undefined;
    var s: Session = .init(&slots, .{ .listen = false });
    _ = try steps(&s, &.{ .start, .{ .initialize_answered = .{ .session = true } }, .{ .send = 1 }, .{ .send = 2 } });
    _ = try steps(&s, &.{ .{ .event_seen = .{ .id = 1, .has_id = true, .retry_ms = null } }, .{ .broke = 1 }, .{ .expired = 2 }, .{ .initialize_answered = .{ .session = true } } });
    const out = try steps(&s, &.{.{ .resume_due = 1 }});
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .{ .id = 1, .outcome = .lost } }}, out.effects());
}

test "cancelling posts notifications/cancelled only for a request out in this session" {
    var slots: [2]Request = undefined;
    var s: Session = .init(&slots, .{ .listen = false });
    _ = try steps(&s, &.{ .start, .{ .send = 1 } });
    var out = try steps(&s, &.{.{ .cancel = 1 }});
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .{ .id = 1, .outcome = .cancelled } }}, out.effects());
    _ = try steps(&s, &.{ .{ .initialize_answered = .{ .session = true } }, .{ .send = 2 } });
    out = try steps(&s, &.{.{ .cancel = 2 }});
    try testing.expectEqualSlices(Effect, &.{ .{ .post_cancel = 2 }, .{ .deliver = .{ .id = 2, .outcome = .cancelled } } }, out.effects());
}

test "the listening stream backs off, gives up, and never reopens after a 405" {
    var slots: [2]Request = undefined;
    var s: Session = .init(&slots, .{ .max_listen_attempts = 2 });
    var out = try steps(&s, &.{ .start, .{ .initialize_answered = .{ .session = false } } });
    try testing.expectEqualSlices(Effect, &.{ .post_initialized, .open_listen }, out.effects());
    out = try steps(&s, &.{.{ .listen_broke = null }});
    try testing.expectEqualSlices(Effect, &.{.{ .arm_listen = 1000 }}, out.effects());
    out = try steps(&s, &.{ .listen_due, .{ .listen_broke = null } });
    try testing.expectEqualSlices(Effect, &.{.{ .arm_listen = 2000 }}, out.effects());
    out = try steps(&s, &.{ .listen_due, .{ .listen_broke = null } });
    try testing.expectEqual(@as(usize, 0), out.effects().len);
    var other: Session = .init(&slots, .{});
    _ = try steps(&other, &.{ .start, .{ .initialize_answered = .{ .session = true } }, .listen_refused });
    out = try steps(&other, &.{.listen_due});
    try testing.expect(out.transitions()[0].ignored);
    try testing.expectEqual(Listen.none, other.listen);
}

test "close deletes a live session once and sends nothing after" {
    var slots: [2]Request = undefined;
    var s: Session = .init(&slots, .{ .listen = false });
    _ = try steps(&s, &.{ .start, .{ .initialize_answered = .{ .session = true } }, .{ .send = 1 } });
    var out = try steps(&s, &.{.close});
    try testing.expectEqualSlices(Effect, &.{ .delete, .{ .deliver = .{ .id = 1, .outcome = .cancelled } } }, out.effects());
    out = try steps(&s, &.{.{ .send = 2 }});
    try testing.expectEqualSlices(Effect, &.{.{ .deliver = .{ .id = 2, .outcome = .failed } }}, out.effects());
    // No session id, or one that ended: no DELETE.
    var t: Session = .init(&slots, .{ .listen = false });
    _ = try steps(&t, &.{ .start, .{ .initialize_answered = .{ .session = true } }, .{ .send = 1 }, .{ .expired = 1 } });
    out = try steps(&t, &.{.close});
    for (out.effects()) |e| try testing.expect(e != .delete);
}
