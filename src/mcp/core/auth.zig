//! OAuth as two state machines, `Gate` and `Flow`.
//!
//! `Gate` puts the token on the requests to one MCP server. A request the
//! server rejects with 401 goes out again, once, with a newer token; one
//! refresh at a time, and requests wait for it.
//!
//! `Flow` signs in: discovery, a registration per issuer, the authorization
//! request and the checks on its response, and redeeming the code.
//!
//! Pure. Tokens, URLs, and strings are the host's: a token is named by its
//! generation, issuers are numbered from 1, and scopes are bits.

const std = @import("std");
const trace = @import("../io/trace.zig");

// ---------------------------------------------------------------------------
// Gate

/// Requests the gate tracks at once: more than the HTTP layer has in flight
/// plus those waiting for a refresh.
pub const max_requests = 64;

pub const Phase = enum { idle, sent, waiting, done, needs_sign_in, failed, cancelled };

pub const Entry = struct { key: u64, phase: Phase = .idle, g: u32 = 0, again: bool = false };

pub const Refreshed = enum { ok, rotated, refused, failed };

pub const GateEvent = union(enum) {
    /// A request is about to go out; `expiring` when the token held expires
    /// within 30 s.
    send: struct { key: u64, expiring: bool },
    /// The server answered it with anything but a rejection.
    accepted: u64,
    /// The server rejected it with 401.
    rejected: u64,
    /// The client gave up on it.
    forget: u64,
    /// The refresh ended: a token (`rotated` with a new refresh token), a
    /// refusal, or no answer.
    refreshed: Refreshed,
    signed_in: struct { refreshable: bool },
    signed_out,
};

pub const GiveUp = enum { needs_sign_in, failed };

pub const GateEffect = union(enum) {
    /// Post request `key`, again if it went out before, with the token of
    /// generation `token` (0: none).
    post: struct { key: u64, token: u32 },
    refresh,
    /// The request ends without a usable token.
    give_up: struct { key: u64, why: GiveUp },
};

pub const GateOutput = struct {
    effect_buffer: [max_requests + 1]GateEffect = undefined,
    effect_count: usize = 0,
    action: []const u8 = "",
    /// The request the event was about, 0 for none, and its entry before and
    /// after.
    key: u64 = 0,
    from: Phase = .idle,
    to: Phase = .idle,
    entry: Entry = .{ .key = 0 },
    ignored: bool = false,
    /// The event's parameters, for the trace.
    expiring: bool = false,
    rotate: bool = false,

    pub fn effects(out: *const GateOutput) []const GateEffect {
        return out.effect_buffer[0..out.effect_count];
    }

    fn push(out: *GateOutput, effect: GateEffect) void {
        out.effect_buffer[out.effect_count] = effect;
        out.effect_count += 1;
    }
};

pub const Gate = struct {
    /// The newest token's generation, 0 before the first.
    gen: u32 = 0,
    held: bool = false,
    refreshable: bool = false,
    /// The refresh token held, by the generation that brought it.
    rt: u32 = 0,
    refreshing: bool = false,
    entries: [max_requests]Entry = undefined,
    count: usize = 0,

    fn token(g: *const Gate) u32 {
        return if (g.held) g.gen else 0;
    }

    pub fn find(g: *Gate, key: u64) ?*Entry {
        for (g.entries[0..g.count]) |*e| if (e.key == key) return e;
        return null;
    }

    fn remove(g: *Gate, e: *Entry) void {
        e.* = g.entries[g.count - 1];
        g.count -= 1;
    }

    pub fn step(g: *Gate, event: GateEvent, out: *GateOutput) void {
        out.* = .{};
        switch (event) {
            .send => |s| {
                out.action = "send";
                out.expiring = s.expiring;
                g.subject(s.key, out);
                // A key is sent once; remote never has more than
                // max_requests at a time.
                if (g.find(s.key) != null or g.count == max_requests) return g.ignore(out);
                g.entries[g.count] = .{ .key = s.key };
                g.count += 1;
                const e = &g.entries[g.count - 1];
                if (g.refreshing or (s.expiring and g.held and g.refreshable)) {
                    e.phase = .waiting;
                    if (!g.refreshing) g.startRefresh(out);
                } else {
                    e.phase = .sent;
                    e.g = g.token();
                    out.push(.{ .post = .{ .key = s.key, .token = e.g } });
                }
                g.settle(e, out);
            },
            .accepted => |key| {
                out.action = "accept";
                g.subject(key, out);
                const e = g.sentEntry(key) orelse return g.ignore(out);
                e.phase = .done;
                g.settle(e, out);
            },
            .rejected => |key| {
                out.action = "reject";
                g.subject(key, out);
                const e = g.sentEntry(key) orelse return g.ignore(out);
                if (e.again) {
                    g.giveUp(e, .needs_sign_in, out);
                } else if (g.token() > e.g) {
                    // A newer token arrived since it went out.
                    e.g = g.token();
                    e.again = true;
                    out.push(.{ .post = .{ .key = key, .token = e.g } });
                } else if (g.refreshing) {
                    e.phase = .waiting;
                    e.again = true;
                } else if (g.held and g.refreshable) {
                    e.phase = .waiting;
                    e.again = true;
                    g.startRefresh(out);
                } else g.giveUp(e, .needs_sign_in, out);
                g.settle(e, out);
            },
            .forget => |key| {
                out.action = "forget";
                g.subject(key, out);
                const e = g.find(key) orelse return g.ignore(out);
                if (e.phase != .sent and e.phase != .waiting) return g.ignore(out);
                e.phase = .cancelled;
                g.settle(e, out);
            },
            .refreshed => |r| {
                out.action = switch (r) {
                    .ok, .rotated => "refresh_ok",
                    .refused => "refresh_refused",
                    .failed => "refresh_failed",
                };
                out.rotate = r == .rotated;
                // A sign-in or sign-out replaced this refresh.
                if (!g.refreshing) return g.ignore(out);
                g.refreshing = false;
                switch (r) {
                    .ok, .rotated => {
                        g.gen += 1;
                        g.held = true;
                        if (r == .rotated) g.rt = g.gen;
                        g.release(out);
                    },
                    .refused => {
                        g.held = false;
                        g.refreshable = false;
                        g.endWaiting(.needs_sign_in, out);
                    },
                    .failed => g.endWaiting(.failed, out),
                }
            },
            .signed_in => |s| {
                out.action = "signed_in";
                g.gen += 1;
                g.held = true;
                g.refreshable = s.refreshable;
                g.rt = g.gen;
                // The new token replaces the refresh in flight.
                g.refreshing = false;
                g.release(out);
            },
            .signed_out => {
                out.action = "sign_out";
                g.held = false;
                g.refreshable = false;
                g.refreshing = false;
                g.endWaiting(.needs_sign_in, out);
            },
        }
    }

    fn sentEntry(g: *Gate, key: u64) ?*Entry {
        const e = g.find(key) orelse return null;
        return if (e.phase == .sent) e else null;
    }

    fn subject(g: *Gate, key: u64, out: *GateOutput) void {
        out.key = key;
        if (g.find(key)) |e| {
            out.from = e.phase;
            out.entry = e.*;
        } else out.entry = .{ .key = key };
        out.to = out.from;
    }

    /// Records the subject's entry after the step, and forgets it once it ended.
    fn settle(g: *Gate, e: *Entry, out: *GateOutput) void {
        out.to = e.phase;
        out.entry = e.*;
        switch (e.phase) {
            .idle, .sent, .waiting => {},
            else => g.remove(e),
        }
    }

    fn startRefresh(g: *Gate, out: *GateOutput) void {
        g.refreshing = true;
        out.push(.refresh);
    }

    fn giveUp(_: *Gate, e: *Entry, why: GiveUp, out: *GateOutput) void {
        e.phase = if (why == .failed) .failed else .needs_sign_in;
        out.push(.{ .give_up = .{ .key = e.key, .why = why } });
    }

    /// The requests waiting go out with the new token.
    fn release(g: *Gate, out: *GateOutput) void {
        for (g.entries[0..g.count]) |*e| if (e.phase == .waiting) {
            e.phase = .sent;
            e.g = g.gen;
            out.push(.{ .post = .{ .key = e.key, .token = e.g } });
        };
    }

    fn endWaiting(g: *Gate, why: GiveUp, out: *GateOutput) void {
        var i: usize = 0;
        while (i < g.count) {
            const e = &g.entries[i];
            if (e.phase != .waiting) {
                i += 1;
                continue;
            }
            g.giveUp(e, why, out);
            g.remove(e);
        }
    }

    fn ignore(_: *Gate, out: *GateOutput) void {
        out.ignored = true;
    }
};

/// TLC's integers are 32-bit: keys from 2^30 up, such as the host's
/// auxiliary keys, fold into 2^30 to 2^31.
fn traceKey(key: u64) i64 {
    const fold: u64 = 1 << 30;
    return @intCast(if (key < fold) key else fold + key % fold);
}

/// Writes the gate's step as one trace line for machine "auth_gate".
pub fn writeGateTrace(writer: *trace.Writer, instance: []const u8, g: *const Gate, out: *const GateOutput) std.Io.Writer.Error!void {
    try writer.write(.{
        .machine = "auth_gate",
        .instance = instance,
        .event = out.action,
        .from = @tagName(out.from),
        .to = @tagName(out.to),
        .data = &.{
            .{ .name = "ignored", .value = .{ .boolean = out.ignored } },
            .{ .name = "key", .value = .{ .int = traceKey(out.key) } },
            .{ .name = "g", .value = .{ .int = out.entry.g } },
            .{ .name = "again", .value = .{ .boolean = out.entry.again } },
            .{ .name = "expiring", .value = .{ .boolean = out.expiring } },
            .{ .name = "rotate", .value = .{ .boolean = out.rotate } },
            .{ .name = "gen", .value = .{ .int = g.gen } },
            .{ .name = "held", .value = .{ .boolean = g.held } },
            .{ .name = "refreshable", .value = .{ .boolean = g.refreshable } },
            .{ .name = "rt", .value = .{ .int = g.rt } },
            .{ .name = "refreshing", .value = .{ .boolean = g.refreshing } },
        },
    });
}

// ---------------------------------------------------------------------------
// Flow

pub const FlowConfig = struct {
    /// Authorization requests since the server last accepted a request.
    max_authorizations: u8 = 3,
};

pub const FlowPhase = enum { idle, discovering, registering, authorizing, redeeming };

/// How the response's iss compared with the issuer recorded: absent, the
/// same string, or another.
pub const Iss = enum { none, match, wrong };

/// Issuers are numbered from 1 up to this; the flow keeps them as bits, at
/// most bit 30 so every mask fits TLC's integers in the traces.
pub const max_issuers = 31;

pub const FlowEvent = union(enum) {
    sign_in,
    /// Discovery ended: the issuer of usable metadata, or 0 when there is
    /// none, and the resource metadata's scopes_supported,
    /// asked for when nothing else names scopes.
    discovered: struct { issuer: u8, scopes: u32 },
    registered: bool,
    /// The authorization response: whether its state is the flow's, its iss,
    /// whether the metadata advertised iss, and whether it carries an error
    /// rather than a code.
    responded: struct { state_ok: bool, iss: Iss, advertised: bool, err: bool },
    redeemed: bool,
    cancel,
    signed_out,
    /// A request was rejected with a challenge naming these scopes.
    challenged: u32,
    /// The server accepted a request.
    accepted,
};

pub const Stage = enum { discovery, registration, response, redemption, cancelled };

pub const FlowEffect = union(enum) {
    discover,
    /// Register with the flow's issuer.
    register,
    /// The authorization request goes out with the registration for the
    /// flow's issuer, asking for `scopes`.
    authorize: u32,
    redeem,
    /// The token held is from another issuer than the metadata names now.
    drop_token,
    /// Signed in with a token asked with `scopes`.
    signed_in: u32,
    /// No token. `show_error`: the response's error may be shown.
    failed: struct { stage: Stage, show_error: bool },
    /// Too many authorization requests since the server last accepted
    /// a request.
    refused,
};

pub const FlowOutput = struct {
    effect_buffer: [3]FlowEffect = undefined,
    effect_count: usize = 0,
    action: []const u8 = "",
    from: FlowPhase = .idle,
    ignored: bool = false,
    /// The event's parameters, for the trace.
    event: ?FlowEvent = null,

    pub fn effects(out: *const FlowOutput) []const FlowEffect {
        return out.effect_buffer[0..out.effect_count];
    }

    fn push(out: *FlowOutput, effect: FlowEffect) void {
        out.effect_buffer[out.effect_count] = effect;
        out.effect_count += 1;
    }
};

pub const Flow = struct {
    config: FlowConfig = .{},
    phase: FlowPhase = .idle,
    /// Sign-ins started; each has its own verifier and state.
    flows: u32 = 0,
    /// The issuer recorded with the flow's verifier and state.
    flow_issuer: u8 = 0,
    flow_scopes: u32 = 0,
    /// Issuers the client holds a registration with, as bits.
    regs: u32 = 0,
    token_issuer: u8 = 0,
    granted: u32 = 0,
    challenge: u32 = 0,
    auths: u8 = 0,

    pub fn step(f: *Flow, event: FlowEvent, out: *FlowOutput) void {
        out.* = .{ .from = f.phase, .event = event };
        out.action = @tagName(event);
        switch (event) {
            .sign_in => {
                if (f.phase != .idle) return f.ignore(out);
                if (f.auths >= f.config.max_authorizations) {
                    f.ignore(out);
                    return out.push(.refused);
                }
                f.phase = .discovering;
                f.flows += 1;
                // The scopes held and those challenged.
                f.flow_scopes = f.granted | f.challenge;
                out.push(.discover);
            },
            .discovered => |d| {
                if (f.phase != .discovering) return f.ignore(out);
                if (d.issuer == 0 or d.issuer > max_issuers) {
                    f.phase = .idle;
                    return out.push(.{ .failed = .{ .stage = .discovery, .show_error = false } });
                }
                f.flow_issuer = d.issuer;
                if (f.flow_scopes == 0) f.flow_scopes = d.scopes;
                if (f.token_issuer != 0 and f.token_issuer != d.issuer) {
                    f.token_issuer = 0;
                    f.granted = 0;
                    out.push(.drop_token);
                }
                if (f.regs & bit(d.issuer) != 0) return f.authorize(out);
                f.phase = .registering;
                out.push(.register);
            },
            .registered => |ok| {
                if (f.phase != .registering) return f.ignore(out);
                if (!ok) {
                    f.phase = .idle;
                    return out.push(.{ .failed = .{ .stage = .registration, .show_error = false } });
                }
                f.regs |= bit(f.flow_issuer);
                f.authorize(out);
            },
            .responded => |r| {
                if (f.phase != .authorizing) return f.ignore(out);
                // State, then iss by RFC 9207 §2.4, before
                // anything in the response is used.
                const accept = r.state_ok and switch (r.iss) {
                    .match => true,
                    .wrong => false,
                    .none => !r.advertised,
                };
                if (accept and !r.err) {
                    f.phase = .redeeming;
                    return out.push(.redeem);
                }
                f.phase = .idle;
                out.push(.{ .failed = .{ .stage = .response, .show_error = r.err and accept } });
            },
            .redeemed => |ok| {
                if (f.phase != .redeeming) return f.ignore(out);
                f.phase = .idle;
                if (!ok) return out.push(.{ .failed = .{ .stage = .redemption, .show_error = false } });
                f.token_issuer = f.flow_issuer;
                f.granted = f.flow_scopes;
                out.push(.{ .signed_in = f.flow_scopes });
            },
            .cancel => {
                if (f.phase == .idle) return f.ignore(out);
                f.phase = .idle;
                out.push(.{ .failed = .{ .stage = .cancelled, .show_error = false } });
            },
            .signed_out => {
                f.token_issuer = 0;
                f.granted = 0;
            },
            .challenged => |scopes| f.challenge = scopes,
            .accepted => {
                if (f.token_issuer == 0) return f.ignore(out);
                f.auths = 0;
            },
        }
    }

    fn authorize(f: *Flow, out: *FlowOutput) void {
        f.phase = .authorizing;
        f.auths += 1;
        out.push(.{ .authorize = f.flow_scopes });
    }

    fn ignore(_: *Flow, out: *FlowOutput) void {
        out.ignored = true;
    }
};

fn bit(issuer: u8) u32 {
    return @as(u32, 1) << @intCast(issuer - 1);
}

/// Writes the flow's step as one trace line for machine "auth_flow".
pub fn writeFlowTrace(writer: *trace.Writer, instance: []const u8, f: *const Flow, out: *const FlowOutput) std.Io.Writer.Error!void {
    var p: struct { issuer: u8 = 0, scopes: u32 = 0, ok: bool = false, state_ok: bool = false, iss: Iss = .none, advertised: bool = false, err: bool = false } = .{};
    if (out.event) |e| switch (e) {
        .discovered => |d| {
            p.issuer = d.issuer;
            p.scopes = d.scopes;
        },
        .registered, .redeemed => |ok| p.ok = ok,
        .responded => |r| {
            p.state_ok = r.state_ok;
            p.iss = r.iss;
            p.advertised = r.advertised;
            p.err = r.err;
        },
        .challenged => |s| p.scopes = s,
        else => {},
    };
    try writer.write(.{
        .machine = "auth_flow",
        .instance = instance,
        .event = out.action,
        .from = @tagName(out.from),
        .to = @tagName(f.phase),
        .data = &.{
            .{ .name = "ignored", .value = .{ .boolean = out.ignored } },
            .{ .name = "issuer", .value = .{ .int = p.issuer } },
            .{ .name = "scopes", .value = .{ .int = p.scopes } },
            .{ .name = "ok", .value = .{ .boolean = p.ok } },
            .{ .name = "state_ok", .value = .{ .boolean = p.state_ok } },
            .{ .name = "iss", .value = .{ .string = @tagName(p.iss) } },
            .{ .name = "advertised", .value = .{ .boolean = p.advertised } },
            .{ .name = "err", .value = .{ .boolean = p.err } },
            .{ .name = "flows", .value = .{ .int = f.flows } },
            .{ .name = "flow_issuer", .value = .{ .int = f.flow_issuer } },
            .{ .name = "flow_scopes", .value = .{ .int = f.flow_scopes } },
            .{ .name = "regs", .value = .{ .int = f.regs } },
            .{ .name = "token_issuer", .value = .{ .int = f.token_issuer } },
            .{ .name = "granted", .value = .{ .int = f.granted } },
            .{ .name = "challenge", .value = .{ .int = f.challenge } },
            .{ .name = "auths", .value = .{ .int = f.auths } },
        },
    });
}

// ---------------------------------------------------------------------------
// Tests. Each machine's model invariants are checked after every step of
// every event sequence to a small depth, with the models' ghosts kept beside.

const testing = std.testing;

const GateWorld = struct {
    /// The refresh token the authorization server accepts.
    server_rt: u32 = 0,
    /// The refresh token the refresh in flight presented.
    used_rt: u32 = 0,
    refreshes: u32 = 0,
    sends: [3]u8 = .{ 0, 0, 0 },
    rejected_g: [3]u32 = .{ 0, 0, 0 },

    fn check(w: *GateWorld, g: *const Gate, before_rt: u32, event: GateEvent, out: *const GateOutput) !void {
        // A key sent anew is a new request.
        if (event == .send and !out.ignored) {
            w.sends[@intCast(event.send.key)] = 0;
            w.rejected_g[@intCast(event.send.key)] = 0;
        }
        for (out.effects()) |e| switch (e) {
            .refresh => {
                w.refreshes += 1;
                w.used_rt = before_rt;
            },
            .post => |p| w.sends[@intCast(p.key)] += 1,
            .give_up => {},
        };
        switch (event) {
            .refreshed => |r| if (!out.ignored) {
                w.refreshes -= 1;
                if (r == .rotated) w.server_rt = g.gen;
            },
            .signed_in => {
                w.refreshes = 0;
                w.server_rt = g.gen;
            },
            .signed_out => w.refreshes = 0,
            else => {},
        }
        try testing.expect(w.refreshes <= 1); // SingleFlightRefresh
        try testing.expect(w.refreshes == @intFromBool(g.refreshing));
        if (g.refreshing) try testing.expectEqual(w.server_rt, w.used_rt); // RefreshUsesLatest
        for (w.sends) |n| try testing.expect(n <= 2); // SendsBound
        var waiting = false;
        for (g.entries[0..g.count]) |e| {
            waiting = waiting or e.phase == .waiting;
            if (e.phase == .sent and e.again) try testing.expect(e.g > w.rejected_g[@intCast(e.key)]); // NewerOnResend
        }
        if (waiting) try testing.expect(g.refreshing); // WaitingHasRefresh
    }
};

fn exploreGate(g: Gate, w: GateWorld, depth: u8) !void {
    if (depth == 0) return;
    const events = [_]GateEvent{
        .{ .send = .{ .key = 1, .expiring = false } }, .{ .send = .{ .key = 2, .expiring = true } },
        .{ .accepted = 1 },                            .{ .rejected = 1 },
        .{ .rejected = 2 },                            .{ .forget = 2 },
        .{ .refreshed = .ok },                         .{ .refreshed = .rotated },
        .{ .refreshed = .refused },                    .{ .refreshed = .failed },
        .{ .signed_in = .{ .refreshable = true } },    .signed_out,
    };
    for (events) |event| {
        var next = g;
        var nw = w;
        const before_rt = next.rt;
        // The rejected send's token, for NewerOnResend.
        const prior: ?u32 = switch (event) {
            .rejected => |k| if (next.find(k)) |e| e.g else null,
            else => null,
        };
        var out: GateOutput = .{};
        next.step(event, &out);
        try nw.check(&next, before_rt, event, &out);
        if (prior) |p| nw.rejected_g[@intCast(event.rejected)] = p;
        try exploreGate(next, nw, depth - 1);
    }
}

test "every gate event sequence to depth 6 keeps the model's invariants" {
    try exploreGate(.{}, .{}, 6);
}

fn gateSteps(g: *Gate, events: []const GateEvent) GateOutput {
    var out: GateOutput = .{};
    for (events) |e| g.step(e, &out);
    return out;
}

test "a rejected request waits for one refresh and goes out again with its token" {
    var g: Gate = .{};
    _ = gateSteps(&g, &.{.{ .signed_in = .{ .refreshable = true } }});
    var out = gateSteps(&g, &.{ .{ .send = .{ .key = 1, .expiring = false } }, .{ .send = .{ .key = 2, .expiring = false } } });
    try testing.expectEqualSlices(GateEffect, &.{.{ .post = .{ .key = 2, .token = 1 } }}, out.effects());
    out = gateSteps(&g, &.{.{ .rejected = 1 }});
    try testing.expectEqualSlices(GateEffect, &.{.refresh}, out.effects());
    // A second rejection during the refresh waits for the same one.
    out = gateSteps(&g, &.{.{ .rejected = 2 }});
    try testing.expectEqual(@as(usize, 0), out.effects().len);
    out = gateSteps(&g, &.{.{ .refreshed = .rotated }});
    try testing.expectEqualSlices(GateEffect, &.{ .{ .post = .{ .key = 1, .token = 2 } }, .{ .post = .{ .key = 2, .token = 2 } } }, out.effects());
    try testing.expectEqual(@as(u32, 2), g.rt);
    // Rejected again: it ends.
    out = gateSteps(&g, &.{.{ .rejected = 1 }});
    try testing.expectEqualSlices(GateEffect, &.{.{ .give_up = .{ .key = 1, .why = .needs_sign_in } }}, out.effects());
}

test "a token close to expiry is refreshed first, and a token without refresh ends the request" {
    var g: Gate = .{};
    _ = gateSteps(&g, &.{.{ .signed_in = .{ .refreshable = true } }});
    var out = gateSteps(&g, &.{.{ .send = .{ .key = 1, .expiring = true } }});
    try testing.expectEqualSlices(GateEffect, &.{.refresh}, out.effects());
    out = gateSteps(&g, &.{.{ .refreshed = .refused }});
    try testing.expectEqualSlices(GateEffect, &.{.{ .give_up = .{ .key = 1, .why = .needs_sign_in } }}, out.effects());
    try testing.expect(!g.held and !g.refreshable);
    out = gateSteps(&g, &.{ .{ .send = .{ .key = 2, .expiring = false } }, .{ .rejected = 2 } });
    try testing.expectEqualSlices(GateEffect, &.{.{ .give_up = .{ .key = 2, .why = .needs_sign_in } }}, out.effects());
}

test "a refresh that gets no answer fails the requests waiting and keeps the tokens" {
    var g: Gate = .{};
    _ = gateSteps(&g, &.{ .{ .signed_in = .{ .refreshable = true } }, .{ .send = .{ .key = 1, .expiring = true } } });
    const out = gateSteps(&g, &.{.{ .refreshed = .failed }});
    try testing.expectEqualSlices(GateEffect, &.{.{ .give_up = .{ .key = 1, .why = .failed } }}, out.effects());
    try testing.expect(g.held and g.refreshable);
}

const FlowWorld = struct {
    known: u8 = 0,
    asked: u32 = 0,
    /// The response check the flow's state rests on, by RFC 9207.
    checked: bool = false,
    validated: bool = false,
    redemptions: [8]u8 = @splat(0),
    shown: bool = false,
    cross: bool = false,

    fn check(w: *FlowWorld, f: *const Flow, event: FlowEvent, out: *const FlowOutput) !void {
        if (!out.ignored) switch (event) {
            .sign_in => {
                w.asked = f.granted | f.challenge;
                w.checked = false;
                w.validated = false;
            },
            .discovered => |d| if (d.issuer != 0) {
                w.known = d.issuer;
                w.validated = true;
            },
            .responded => |r| {
                w.checked = r.state_ok and (r.iss == .match or (r.iss == .none and !r.advertised));
                for (out.effects()) |e| if (e == .failed and e.failed.show_error and !w.checked) {
                    w.shown = true;
                };
            },
            .redeemed => w.redemptions[f.flows] += 1,
            else => {},
        };
        for (out.effects()) |e| if (e == .authorize and f.regs & bit(f.flow_issuer) == 0) {
            w.cross = true;
        };
        switch (f.phase) {
            .registering, .authorizing, .redeeming => try testing.expect(w.validated), // MetaValidated
            else => {},
        }
        if (f.phase == .redeeming) try testing.expect(w.checked); // RedeemGuard
        for (w.redemptions) |n| try testing.expect(n <= 1); // VerifierOnce
        try testing.expect(!w.shown); // ErrSuppress
        try testing.expect(!w.cross); // CredIsolation
        try testing.expect(f.token_issuer == 0 or f.token_issuer == w.known); // TokenAudience
        if (f.phase != .idle) try testing.expect(w.asked & ~f.flow_scopes == 0); // ScopeUnion
        try testing.expect(f.auths <= f.config.max_authorizations); // StepUpBound
    }
};

fn exploreFlow(f: Flow, w: FlowWorld, depth: u8) !void {
    if (depth == 0) return;
    const events = [_]FlowEvent{
        .sign_in,
        .{ .discovered = .{ .issuer = 1, .scopes = 4 } },
        .{ .discovered = .{ .issuer = 2, .scopes = 0 } },
        .{ .discovered = .{ .issuer = 0, .scopes = 0 } },
        .{ .registered = true },
        .{ .responded = .{ .state_ok = true, .iss = .match, .advertised = true, .err = false } },
        .{ .responded = .{ .state_ok = true, .iss = .none, .advertised = true, .err = true } },
        .{ .responded = .{ .state_ok = false, .iss = .match, .advertised = false, .err = false } },
        .{ .responded = .{ .state_ok = true, .iss = .wrong, .advertised = false, .err = true } },
        .{ .redeemed = true },
        .{ .redeemed = false },
        .{ .challenged = 2 },
        .accepted,
        .signed_out,
    };
    for (events) |event| {
        var next = f;
        var nw = w;
        var out: FlowOutput = .{};
        next.step(event, &out);
        try nw.check(&next, event, &out);
        try exploreFlow(next, nw, depth - 1);
    }
}

test "every flow event sequence to depth 7 keeps the model's invariants" {
    try exploreFlow(.{}, .{}, 7);
}

fn flowSteps(f: *Flow, events: []const FlowEvent) FlowOutput {
    var out: FlowOutput = .{};
    for (events) |e| f.step(e, &out);
    return out;
}

test "a sign-in registers once per issuer, and a new issuer drops the token and registers again" {
    var f: Flow = .{};
    var out = flowSteps(&f, &.{ .sign_in, .{ .discovered = .{ .issuer = 1, .scopes = 1 } } });
    try testing.expectEqualSlices(FlowEffect, &.{.register}, out.effects());
    out = flowSteps(&f, &.{.{ .registered = true }});
    try testing.expectEqualSlices(FlowEffect, &.{.{ .authorize = 1 }}, out.effects());
    out = flowSteps(&f, &.{ .{ .responded = .{ .state_ok = true, .iss = .match, .advertised = true, .err = false } }, .{ .redeemed = true } });
    try testing.expectEqualSlices(FlowEffect, &.{.{ .signed_in = 1 }}, out.effects());
    // The same issuer again: no registration.
    out = flowSteps(&f, &.{ .sign_in, .{ .discovered = .{ .issuer = 1, .scopes = 1 } } });
    try testing.expectEqualSlices(FlowEffect, &.{.{ .authorize = 1 }}, out.effects());
    _ = flowSteps(&f, &.{.cancel});
    // Another issuer: the token goes, and a new registration.
    out = flowSteps(&f, &.{ .sign_in, .{ .discovered = .{ .issuer = 2, .scopes = 1 } } });
    try testing.expectEqualSlices(FlowEffect, &.{ .drop_token, .register }, out.effects());
}

test "a response is checked before its error is shown or its code redeemed" {
    const Case = struct { FlowEvent, FlowEffect };
    const fail = struct {
        fn of(show: bool) FlowEffect {
            return .{ .failed = .{ .stage = .response, .show_error = show } };
        }
    }.of;
    for ([_]Case{
        .{ .{ .responded = .{ .state_ok = true, .iss = .match, .advertised = true, .err = false } }, .redeem },
        .{ .{ .responded = .{ .state_ok = true, .iss = .none, .advertised = false, .err = false } }, .redeem },
        .{ .{ .responded = .{ .state_ok = true, .iss = .none, .advertised = true, .err = false } }, fail(false) },
        .{ .{ .responded = .{ .state_ok = true, .iss = .wrong, .advertised = false, .err = true } }, fail(false) },
        .{ .{ .responded = .{ .state_ok = false, .iss = .match, .advertised = true, .err = true } }, fail(false) },
        .{ .{ .responded = .{ .state_ok = true, .iss = .match, .advertised = true, .err = true } }, fail(true) },
    }) |case| {
        var f: Flow = .{};
        _ = flowSteps(&f, &.{ .sign_in, .{ .discovered = .{ .issuer = 1, .scopes = 0 } }, .{ .registered = true } });
        const out = flowSteps(&f, &.{case[0]});
        try testing.expectEqualSlices(FlowEffect, &.{case[1]}, out.effects());
    }
}

test "a step-up asks for the scopes held and challenged, and stops after three authorizations" {
    var f: Flow = .{};
    _ = flowSteps(&f, &.{ .{ .challenged = 1 }, .sign_in, .{ .discovered = .{ .issuer = 1, .scopes = 8 } }, .{ .registered = true } });
    _ = flowSteps(&f, &.{ .{ .responded = .{ .state_ok = true, .iss = .match, .advertised = true, .err = false } }, .{ .redeemed = true } });
    try testing.expectEqual(@as(u32, 1), f.granted);
    var out = flowSteps(&f, &.{ .{ .challenged = 2 }, .sign_in, .{ .discovered = .{ .issuer = 1, .scopes = 8 } } });
    try testing.expectEqualSlices(FlowEffect, &.{.{ .authorize = 3 }}, out.effects());
    _ = flowSteps(&f, &.{ .cancel, .sign_in, .{ .discovered = .{ .issuer = 1, .scopes = 8 } }, .cancel });
    try testing.expectEqual(@as(u8, 3), f.auths);
    out = flowSteps(&f, &.{.sign_in});
    try testing.expectEqualSlices(FlowEffect, &.{.refused}, out.effects());
    // An accepted request starts the count over.
    _ = flowSteps(&f, &.{.accepted});
    out = flowSteps(&f, &.{.sign_in});
    try testing.expectEqualSlices(FlowEffect, &.{.discover}, out.effects());
}

test "with no challenge scopes, the resource metadata's are asked for" {
    var f: Flow = .{};
    const out = flowSteps(&f, &.{ .sign_in, .{ .discovered = .{ .issuer = 1, .scopes = 6 } }, .{ .registered = true } });
    try testing.expectEqualSlices(FlowEffect, &.{.{ .authorize = 6 }}, out.effects());
}
