//! The MCP owner's routing: clients share servers, and this decides what goes
//! where (D: `tests/tla/mcp_host/SharedServers.tla`). One `step` takes the
//! route table and one event and returns the effects to run: it performs no
//! I/O, reads no clock, and allocates nothing. `owner.zig` owns the socket,
//! the clients' writer queues, and the engine, and feeds every result back as
//! an event.
//!
//! Rules, from the model:
//! - A session registers for a share key; the first registration adds that
//!   key's server to the owner's engine.
//! - `phase`, `tools`, `status`, and `stopped_idle` go to every client
//!   registered for the key (`broadcast`).
//! - A 2026 input request names its call, so it goes to that call's client.
//! - A 2025 question names no call: it goes to the only client with calls in
//!   flight on the key. When two or more clients have calls there, or that one
//!   client cannot show that kind of question, the owner declines it.
//! - A call's outcome and progress go only to its caller.
//! - A client that leaves has each of its calls cancelled in the engine, and
//!   nothing of another client's is touched. Later events for its calls are
//!   dropped and logged.
//!
//! Engine handles exist only after the shell calls `Engine.call`, so a call is
//! pending between the `call` effect and its `issued` event: a cancel or
//! respond that arrives sooner waits for the handle, and `issue_failed` ends
//! the call as a transport failure.
const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");
const share_key = @import("share_key.zig");
const wire = @import("owner_wire.zig");

const engine = mcp.engine;

/// One socket, numbered by the shell and never reused.
pub const ClientId = enum(u32) { _ };

/// One call, numbered once and never reused, so a late answer can never reach
/// a later call.
pub const CallId = enum(u32) { _ };

pub const max_clients = 256;
pub const max_keys = 256;
pub const max_calls = 1024;
/// Calls one client may hold at once; the engine itself holds 24 per server.
pub const max_calls_per_client = 24;
/// Keys one client may register for.
pub const max_keys_per_client = 32;
/// 2025 questions the owner holds at once. Each names no call, so the owner
/// remembers which client it showed it to.
pub const max_questions = 64;
/// The effects one step can produce: a leaving client cancels at most its own
/// calls, answers the questions it holds, and disconnects the keys it alone
/// was registered for.
pub const max_effects = max_calls_per_client + max_questions + max_keys_per_client + 8;

pub const Key = share_key.Key;

pub const Client = struct {
    id: ClientId,
    ask_form: bool,
    ask_url: bool,
};

pub const Slot = struct {
    key: Key,
    clients: std.bit_set.Static(max_clients) = .empty,
};

pub const Call = struct {
    id: CallId,
    /// Null once its client left; its handle is still cancelled.
    client: ?ClientId,
    client_call: u32,
    key: Key,
    handle: ?engine.Handle = null,
    /// A cancel arrived before the handle did.
    cancel_held: bool = false,
};

/// A 2025 question, which names no call: the owner remembers which client it
/// showed it to, so only that client's answer reaches the server.
pub const Question = struct {
    key: Key,
    slot: u8,
    n: u32,
    client: ClientId,
};

pub const State = struct {
    clients: [max_clients]?Client = @splat(null),
    slots: [max_keys]?Slot = @splat(null),
    calls: [max_calls]?Call = @splat(null),
    questions: [max_questions]?Question = @splat(null),
    next_call: u32 = 1,

    pub fn clientOf(state: *const State, id: ClientId) ?*const Client {
        const index = @backingInt(id);
        if (index == 0 or index > max_clients) return null;
        if (state.clients[index - 1]) |*client| return client;
        return null;
    }
};

pub const QuestionKind = enum { form, url };

pub const Registered = struct { client: ClientId, key: Key, ask_form: bool, ask_url: bool };
pub const CallRequest = struct { client: ClientId, id: u32, key: Key, tool: []const u8 = "", arguments: ?[]const u8 = null };
pub const AnswerRequest = struct { client: ClientId, key: Key, slot: u8, n: u32, action: mcp.elicitation.Action, content: ?[]const u8 = null };
pub const Issued = struct { call: CallId, handle: engine.Handle };
pub const IssueFailed = struct { call: CallId };
pub const EngineCalled = struct { handle: engine.Handle, outcome: engine.Outcome, maybe_ran: bool, timed_out: bool, oversized: bool, answer: ?[]const u8 = null, refused_bytes: u32 = 0, refused_body: bool = false, lost_why: ?mcp.server.LostWhy = null };
pub const EngineProgress = struct { handle: engine.Handle, progress: f64, total: ?f64, message: ?[]const u8 };
pub const EngineInput = struct { handle: engine.Handle, requests: []const u8 };
pub const EngineQuestion = struct { key: Key, slot: u8, n: u32, kind: QuestionKind, params: []const u8, version: ?[]const u8, required: bool = false };

pub const Event = union(enum) {
    /// The shell numbered a new connection.
    hello: ClientId,
    /// That client needs this key's server; the flags say which questions it
    /// can show.
    registered: Registered,
    /// The client stops using this key's server.
    unregister: struct { client: ClientId, key: Key },
    /// The connection closed.
    gone: ClientId,
    /// The session said goodbye, then closes. Its keys disconnect at once.
    bye: ClientId,
    need: struct { client: ClientId, key: Key },
    call: CallRequest,
    cancel: struct { client: ClientId, id: u32 },
    respond: struct { client: ClientId, id: u32, values: []const u8 = "" },
    /// A 2025 question's answer, by its slot and number.
    answer: AnswerRequest,
    /// The shell called `Engine.call` and got the handle.
    issued: Issued,
    /// `Engine.call` failed.
    issue_failed: IssueFailed,
    engine_phase: struct { key: Key, phase: engine.Phase },
    engine_tools: struct { key: Key, ok: bool, fresh: bool, needs_auth: bool },
    engine_called: EngineCalled,
    engine_progress: EngineProgress,
    /// The call's 2026 input requests, as JSON text that lives until the
    /// effects run.
    engine_input: EngineInput,
    /// A 2025 question, whose params live until the effects run.
    engine_question: EngineQuestion,
    engine_stopped_idle: struct { key: Key },
    engine_status: struct { key: Key },
    /// The server completed, or withdrew, the 2025 question in `slot`.
    engine_elicitation_complete: struct { key: Key, slot: u8 },
    engine_elicitation_withdrawn: struct { key: Key, slot: u8 },
};

/// What every client registered for a key hears.
pub const Broadcast = union(enum) {
    phase: engine.Phase,
    tools: struct { ok: bool, fresh: bool, needs_auth: bool },
    status,
    stopped_idle,
    elicitation_complete: u8,
    elicit_withdrawn: u8,
};

/// Why a client's request was refused, so its session can fall back. The wire
/// message carries the same names, so the owner sends one without a mapping
/// table to keep in step.
pub const Refuse = wire.Refused;

/// User state the core drops.
pub const Drop = enum {
    /// A cancel arrived before the engine had the call; it is held until then.
    cancel_held,
    /// A cancel or respond for a call that already ended.
    late,
    /// An engine event for a call whose client is gone.
    orphaned_call,
    /// An answer from a client that is not registered for the key.
    answer_unregistered,
    /// A 2025 question with no single caller that can show it.
    question_declined,
    /// A second hello for a client id that is in use.
    client_twice,
    /// An answer from a client the question was not shown to.
    answer_other,
    /// An answer for a question the owner does not hold.
    answer_unknown,
    /// A connection that was never numbered.
    unknown_client,
    /// An unregister for a key the client is not registered for.
    unregister_unregistered,
};

pub const Effect = union(enum) {
    send: struct { to: ClientId, message: wire.OwnerMessage },
    broadcast: struct { key: Key, what: Broadcast },
    /// One request refused, so its session falls back for that server or call
    /// alone. `key` names the server it was about when it named one, and
    /// `call` the session's call id when it was a call.
    refuse: struct { to: ClientId, reason: Refuse, key: ?Key = null, call: ?u32 = null },
    /// The shell adds this key's server to the engine.
    register_slot: struct { key: Key },
    /// The last client registered for the key left: the shell disconnects it,
    /// so its server stops now instead of outliving its last session.
    disconnect: struct { key: Key },
    need: struct { key: Key },
    /// The shell calls `Engine.call` and reports `issued` or `issue_failed`.
    call: struct { call: CallId, key: Key, tool: []const u8 = "", arguments: ?[]const u8 = null },
    cancel: struct { handle: engine.Handle },
    respond: struct { handle: engine.Handle, values: []const u8 = "" },
    answer: struct { key: Key, slot: u8, n: u32, action: mcp.elicitation.Action, content: ?[]const u8 = null },
    log: struct { what: Drop, client: ?ClientId = null, key: ?Key = null },
};

pub const Output = struct {
    buffer: [max_effects]Effect = undefined,
    len: usize = 0,

    pub fn effects(out: *const Output) []const Effect {
        return out.buffer[0..out.len];
    }

    fn push(out: *Output, effect: Effect) void {
        std.debug.assert(out.len < out.buffer.len);
        out.buffer[out.len] = effect;
        out.len += 1;
    }
};

pub fn step(state: *State, event: Event, out: *Output) void {
    switch (event) {
        .hello => |client| onHello(state, client, out),
        .registered => |added| onRegistered(state, added, out),
        .unregister => |left| onUnregister(state, left.client, left.key, out),
        .gone => |client| onGone(state, client, out),
        .bye => |client| onGone(state, client, out),
        .need => |need| onNeed(state, need.client, need.key, out),
        .call => |call| onCall(state, call, out),
        .cancel => |cancel| onCancel(state, cancel.client, cancel.id, out),
        .respond => |respond| onRespond(state, respond.client, respond.id, respond.values, out),
        .answer => |answer| onAnswer(state, answer, out),
        .issued => |issued| onIssued(state, issued.call, issued.handle, out),
        .issue_failed => |failed| onIssueFailed(state, failed.call, out),
        .engine_phase => |phase| out.push(.{ .broadcast = .{ .key = phase.key, .what = .{ .phase = phase.phase } } }),
        .engine_tools => |tools| out.push(.{ .broadcast = .{ .key = tools.key, .what = .{ .tools = .{ .ok = tools.ok, .fresh = tools.fresh, .needs_auth = tools.needs_auth } } } }),
        .engine_status => |status| out.push(.{ .broadcast = .{ .key = status.key, .what = .status } }),
        .engine_stopped_idle => |stopped| out.push(.{ .broadcast = .{ .key = stopped.key, .what = .stopped_idle } }),
        .engine_called => |called| onEngineCalled(state, called, out),
        .engine_progress => |progress| onEngineProgress(state, progress, out),
        .engine_input => |input| onEngineInput(state, input, out),
        .engine_question => |question| onEngineQuestion(state, question, out),
        .engine_elicitation_complete => |done| {
            clearQuestion(state, done.key, done.slot);
            out.push(.{ .broadcast = .{ .key = done.key, .what = .{ .elicitation_complete = done.slot } } });
        },
        .engine_elicitation_withdrawn => |gone| {
            clearQuestion(state, gone.key, gone.slot);
            out.push(.{ .broadcast = .{ .key = gone.key, .what = .{ .elicit_withdrawn = gone.slot } } });
        },
    }
}

fn onHello(state: *State, id: ClientId, out: *Output) void {
    const index = @backingInt(id);
    if (index == 0 or index > max_clients) return out.push(.{ .log = .{ .what = .unknown_client } });
    if (state.clients[index - 1] != null) return out.push(.{ .log = .{ .what = .client_twice, .client = id } });
    state.clients[index - 1] = .{ .id = id, .ask_form = false, .ask_url = false };
}

fn onRegistered(state: *State, added: Registered, out: *Output) void {
    _ = clientOrRefuse(state, added.client, out) orelse return;
    if (registered(state, added.client, added.key)) return;
    const fresh = slotFor(state, added.key) == null;
    if (keysOf(state, added.client) >= max_keys_per_client) {
        return out.push(.{ .refuse = .{ .to = added.client, .reason = .too_many_keys, .key = added.key } });
    }
    if (fresh and freeSlots(state) == 0) return out.push(.{ .refuse = .{ .to = added.client, .reason = .too_many_keys, .key = added.key } });
    const slot = ensureSlot(state, added.key).?;
    slot.clients.set(@backingInt(added.client) - 1);
    const stored = &state.clients[@backingInt(added.client) - 1].?;
    stored.ask_form = stored.ask_form or added.ask_form;
    stored.ask_url = stored.ask_url or added.ask_url;
    if (fresh) {
        out.push(.{ .register_slot = .{ .key = added.key } });
    } else {
        // The owner already runs this server: the joining session hears where
        // it is, since no phase or status change may come for a while.
        out.push(.{ .broadcast = .{ .key = added.key, .what = .status } });
    }
}

fn onGone(state: *State, id: ClientId, out: *Output) void {
    const index = @backingInt(id);
    if (index == 0 or index > max_clients) return out.push(.{ .log = .{ .what = .unknown_client } });
    if (state.clients[index - 1] == null) return; // already gone: bye, then the socket closed
    state.clients[index - 1] = null;
    // A question it holds can never be answered now: decline it, so the
    // server does not wait.
    for (&state.questions) |*maybe| {
        const question = if (maybe.*) |*value| value else continue;
        if (question.client != id) continue;
        out.push(.{ .answer = .{ .key = question.key, .slot = question.slot, .n = question.n, .action = .cancel } });
        maybe.* = null;
    }
    // Its calls end; another client's calls are untouched.
    var cancelled: usize = 0;
    for (&state.calls) |*maybe| {
        const call = if (maybe.*) |*value| value else continue;
        const owner = call.client orelse continue;
        if (owner != id) continue;
        call.client = null;
        if (call.handle) |handle| {
            out.push(.{ .cancel = .{ .handle = handle } });
            cancelled += 1;
        } else {
            // The shell will report the handle; the cancel goes then.
            call.cancel_held = true;
        }
    }
    // A key it alone was registered for stops its server now, so no server
    // outlives its last session, and its slot is freed so a long-lived owner
    // keeps serving new keys: the key's next registration is a fresh one.
    for (&state.slots) |*maybe| {
        const slot = if (maybe.*) |*value| value else continue;
        if (!slot.clients.isSet(index - 1)) continue;
        const key = slot.key;
        slot.clients.unset(index - 1);
        if (slot.clients.count() == 0) {
            maybe.* = null;
            out.push(.{ .disconnect = .{ .key = key } });
        }
    }
    if (cancelled > 0) out.push(.{ .log = .{ .what = .orphaned_call, .client = id } });
}

/// One client stops using one key: it leaves that key's slot, its calls on
/// that key end as cancelled, and the key's server stops once no client is
/// left. Its calls and questions on other keys are untouched.
fn onUnregister(state: *State, id: ClientId, key: Key, out: *Output) void {
    const index = @backingInt(id);
    if (index == 0 or index > max_clients or state.clients[index - 1] == null) return out.push(.{ .log = .{ .what = .unknown_client } });
    const slot = slotForMut(state, key) orelse return out.push(.{ .log = .{ .what = .unregister_unregistered, .client = id, .key = key } });
    if (!slot.clients.isSet(index - 1)) return out.push(.{ .log = .{ .what = .unregister_unregistered, .client = id, .key = key } });
    // A question routed to it on this key can never be answered now.
    for (&state.questions) |*maybe| {
        const question = if (maybe.*) |*value| value else continue;
        if (question.client != id or !std.mem.eql(u8, &question.key, &key)) continue;
        out.push(.{ .answer = .{ .key = question.key, .slot = question.slot, .n = question.n, .action = .cancel } });
        maybe.* = null;
    }
    // Its calls on this key end; another client's calls, and its own on other
    // keys, are untouched.
    var cancelled: usize = 0;
    for (&state.calls) |*maybe| {
        const call = if (maybe.*) |*value| value else continue;
        const owner = call.client orelse continue;
        if (owner != id or !std.mem.eql(u8, &call.key, &key)) continue;
        call.client = null;
        if (call.handle) |handle| {
            out.push(.{ .cancel = .{ .handle = handle } });
            cancelled += 1;
        } else {
            // The shell will report the handle; the cancel goes then.
            call.cancel_held = true;
        }
    }
    slot.clients.unset(index - 1);
    // No session left on the key: its server stops now, and its slot is freed
    // so the key's next registration is a fresh one.
    if (slot.clients.count() == 0) {
        _ = freeSlotIfEmpty(state, key);
        out.push(.{ .disconnect = .{ .key = key } });
    }
    if (cancelled > 0) out.push(.{ .log = .{ .what = .orphaned_call, .client = id } });
}

fn onNeed(state: *State, client: ClientId, key: Key, out: *Output) void {
    if (!registered(state, client, key)) return out.push(.{ .refuse = .{ .to = client, .reason = .not_registered, .key = key } });
    out.push(.{ .need = .{ .key = key } });
}

fn onCall(state: *State, request: CallRequest, out: *Output) void {
    _ = clientOrRefuse(state, request.client, out) orelse return;
    if (!registered(state, request.client, request.key)) return out.push(.{ .refuse = .{ .to = request.client, .reason = .not_registered, .key = request.key, .call = request.id } });
    if (heldBy(state, request.client) >= max_calls_per_client) {
        return out.push(.{ .refuse = .{ .to = request.client, .reason = .too_many_calls, .key = request.key, .call = request.id } });
    }
    const index = freeCall(state) orelse return out.push(.{ .refuse = .{ .to = request.client, .reason = .too_many_calls, .key = request.key, .call = request.id } });
    const id: CallId = @fromBackingInt(state.next_call);
    state.next_call += 1;
    state.calls[index] = .{ .id = id, .client = request.client, .client_call = request.id, .key = request.key };
    out.push(.{ .call = .{ .call = id, .key = request.key, .tool = request.tool, .arguments = request.arguments } });
}

fn onCancel(state: *State, client: ClientId, id: u32, out: *Output) void {
    const call = callFor(state, client, id) orelse return out.push(.{ .log = .{ .what = .late, .client = client } });
    if (call.handle) |handle| return out.push(.{ .cancel = .{ .handle = handle } });
    call.cancel_held = true;
    out.push(.{ .log = .{ .what = .cancel_held, .client = client } });
}

fn onRespond(state: *State, client: ClientId, id: u32, values: []const u8, out: *Output) void {
    const call = callFor(state, client, id) orelse return out.push(.{ .log = .{ .what = .late, .client = client } });
    const handle = call.handle orelse return out.push(.{ .log = .{ .what = .cancel_held, .client = client } });
    out.push(.{ .respond = .{ .handle = handle, .values = values } });
}

fn onAnswer(state: *State, answer: AnswerRequest, out: *Output) void {
    if (!registered(state, answer.client, answer.key)) {
        return out.push(.{ .log = .{ .what = .answer_unregistered, .client = answer.client, .key = answer.key } });
    }
    const index = questionIndex(state, answer.key, answer.slot, answer.n) orelse {
        return out.push(.{ .log = .{ .what = .answer_unknown, .client = answer.client, .key = answer.key } });
    };
    if (state.questions[index].?.client != answer.client) {
        return out.push(.{ .log = .{ .what = .answer_other, .client = answer.client, .key = answer.key } });
    }
    state.questions[index] = null;
    out.push(.{ .answer = .{ .key = answer.key, .slot = answer.slot, .n = answer.n, .action = answer.action, .content = answer.content } });
}

fn onIssued(state: *State, id: CallId, handle: engine.Handle, out: *Output) void {
    const call = callById(state, id) orelse return out.push(.{ .log = .{ .what = .late } });
    if (call.handle != null) return out.push(.{ .log = .{ .what = .late, .client = call.client } });
    call.handle = handle;
    if (call.cancel_held) out.push(.{ .cancel = .{ .handle = handle } });
}

fn onIssueFailed(state: *State, id: CallId, out: *Output) void {
    const call = callById(state, id) orelse return out.push(.{ .log = .{ .what = .late } });
    if (call.client) |client| out.push(.{ .send = .{ .to = client, .message = .{ .called = .{
        .id = call.client_call,
        .outcome = .transport_failed,
        .maybe_ran = false,
        .timed_out = false,
    } } } });
    endCall(state, call);
}

fn onEngineCalled(state: *State, called: EngineCalled, out: *Output) void {
    const call = callByHandle(state, called.handle) orelse return out.push(.{ .log = .{ .what = .orphaned_call } });
    if (call.client) |client| out.push(.{
        .send = .{
            .to = client,
            .message = .{
                .called = .{
                    .id = call.client_call,
                    .outcome = called.outcome,
                    .maybe_ran = called.maybe_ran,
                    .timed_out = called.timed_out,
                    .oversized = called.oversized,
                    .answer = called.answer,
                    .refused_bytes = called.refused_bytes,
                    .refused_body = called.refused_body,
                    // Why the engine lost it, when it did: the session logs the same
                    // reason for a shared call as for one it ran itself.
                    .lost_why = called.lost_why,
                },
            },
        },
    }) else out.push(.{ .log = .{ .what = .orphaned_call } });
    endCall(state, call);
}

fn onEngineProgress(state: *State, progress: EngineProgress, out: *Output) void {
    const call = callByHandle(state, progress.handle) orelse return out.push(.{ .log = .{ .what = .orphaned_call } });
    const client = call.client orelse return out.push(.{ .log = .{ .what = .orphaned_call } });
    out.push(.{ .send = .{ .to = client, .message = .{ .progress = .{
        .id = call.client_call,
        .progress = progress.progress,
        .total = progress.total,
        .message = progress.message,
    } } } });
}

fn onEngineInput(state: *State, input: EngineInput, out: *Output) void {
    const call = callByHandle(state, input.handle) orelse return out.push(.{ .log = .{ .what = .orphaned_call } });
    const client = call.client orelse return out.push(.{ .log = .{ .what = .orphaned_call } });
    out.push(.{ .send = .{ .to = client, .message = .{ .input = .{ .id = call.client_call, .requests = input.requests } } } });
}

fn onEngineQuestion(state: *State, question: EngineQuestion, out: *Output) void {
    const caller = singleCaller(state, question.key, question.kind) orelse {
        out.push(.{ .log = .{ .what = .question_declined, .key = question.key } });
        return out.push(.{ .answer = .{ .key = question.key, .slot = question.slot, .n = question.n, .action = .cancel } });
    };
    const held = freeQuestion(state) orelse {
        // Nobody's answer could be told apart with more questions than this
        // holds, so the server is told to cancel rather than wait.
        out.push(.{ .log = .{ .what = .question_declined, .key = question.key } });
        return out.push(.{ .answer = .{ .key = question.key, .slot = question.slot, .n = question.n, .action = .cancel } });
    };
    state.questions[held] = .{ .key = question.key, .slot = question.slot, .n = question.n, .client = caller };
    out.push(.{
        .send = .{
            .to = caller,
            .message = .{
                .question = .{
                    .key = question.key,
                    .slot = question.slot,
                    .n = question.n,
                    .params = question.params,
                    .version = question.version,
                    // A required question is one its call's -32042 answer listed: the
                    // session shows it with that call and answers it when the user
                    // chooses, as the session's own engine does.
                    .required = question.required,
                },
            },
        },
    });
}

/// The server completed or withdrew the question in `slot`: nothing is left
/// to answer, so its record goes, whoever held it.
fn clearQuestion(state: *State, key: Key, slot: u8) void {
    for (&state.questions) |*maybe| {
        const question = if (maybe.*) |*value| value else continue;
        if (question.slot != slot or !std.mem.eql(u8, &question.key, &key)) continue;
        maybe.* = null;
    }
}

fn questionIndex(state: *const State, key: Key, slot: u8, n: u32) ?usize {
    for (state.questions, 0..) |maybe, index| {
        const question = maybe orelse continue;
        if (question.slot != slot or question.n != n) continue;
        if (!std.mem.eql(u8, &question.key, &key)) continue;
        return index;
    }
    return null;
}

fn freeQuestion(state: *const State) ?usize {
    for (state.questions, 0..) |maybe, index| if (maybe == null) return index;
    return null;
}

fn keysOf(state: *const State, client: ClientId) usize {
    var count: usize = 0;
    for (state.slots) |maybe| {
        const slot = maybe orelse continue;
        if (slot.clients.isSet(@backingInt(client) - 1)) count += 1;
    }
    return count;
}

/// The one client with a call in flight on the key that can show this kind of
/// question, or null when there is none or more than one.
fn singleCaller(state: *const State, key: Key, kind: QuestionKind) ?ClientId {
    var found: ?ClientId = null;
    for (state.calls) |maybe| {
        const call = maybe orelse continue;
        if (!std.mem.eql(u8, &call.key, &key)) continue;
        if (call.handle == null) continue;
        const client = call.client orelse continue;
        if (found != null and found.? != client) return null;
        found = client;
    }
    const client = found orelse return null;
    const stored = state.clientOf(client) orelse return null;
    const can_ask = switch (kind) {
        .form => stored.ask_form,
        .url => stored.ask_url,
    };
    return if (can_ask) client else null;
}

fn endCall(state: *State, call: *Call) void {
    for (state.calls, 0..) |maybe, index| {
        const stored = maybe orelse continue;
        if (stored.id == call.id) {
            state.calls[index] = null;
            return;
        }
    }
}

fn clientOrRefuse(state: *State, id: ClientId, out: *Output) ?ClientId {
    const index = @backingInt(id);
    if (index == 0 or index > max_clients or state.clients[index - 1] == null) {
        out.push(.{ .refuse = .{ .to = id, .reason = .unknown_client } });
        return null;
    }
    return id;
}

fn registered(state: *const State, client: ClientId, key: Key) bool {
    const slot = slotFor(state, key) orelse return false;
    return slot.clients.isSet(@backingInt(client) - 1);
}

fn slotFor(state: *const State, key: Key) ?*const Slot {
    for (&state.slots) |*maybe| {
        const slot = if (maybe.*) |*value| value else continue;
        if (std.mem.eql(u8, &slot.key, &key)) return slot;
    }
    return null;
}

fn slotForMut(state: *State, key: Key) ?*Slot {
    for (&state.slots) |*maybe| {
        const slot = if (maybe.*) |*value| value else continue;
        if (std.mem.eql(u8, &slot.key, &key)) return slot;
    }
    return null;
}

/// Frees the key's slot once no client is left on it, so a long-lived owner
/// keeps serving new keys. True when it freed one.
fn freeSlotIfEmpty(state: *State, key: Key) bool {
    for (&state.slots) |*maybe| {
        const slot = if (maybe.*) |*value| value else continue;
        if (!std.mem.eql(u8, &slot.key, &key)) continue;
        if (slot.clients.count() != 0) return false;
        maybe.* = null;
        return true;
    }
    return false;
}

fn ensureSlot(state: *State, key: Key) ?*Slot {
    if (slotForMut(state, key)) |slot| return slot;
    for (&state.slots) |*maybe| {
        if (maybe.* != null) continue;
        maybe.* = .{ .key = key };
        return if (maybe.*) |*slot| slot else unreachable;
    }
    return null;
}

fn freeSlots(state: *const State) usize {
    var count: usize = 0;
    for (state.slots) |maybe| if (maybe == null) {
        count += 1;
    };
    return count;
}

fn callFor(state: *State, client: ClientId, client_call: u32) ?*Call {
    for (&state.calls) |*maybe| {
        const call = if (maybe.*) |*value| value else continue;
        if (call.client != null and call.client.? == client and call.client_call == client_call) return call;
    }
    return null;
}

fn callById(state: *State, id: CallId) ?*Call {
    for (&state.calls) |*maybe| {
        const call = if (maybe.*) |*value| value else continue;
        if (call.id == id) return call;
    }
    return null;
}

fn callByHandle(state: *State, search: engine.Handle) ?*Call {
    for (&state.calls) |*maybe| {
        const call = if (maybe.*) |*value| value else continue;
        if (call.handle) |handle| if (handle == search) return call;
    }
    return null;
}

fn heldBy(state: *const State, client: ClientId) usize {
    var count: usize = 0;
    for (state.calls) |maybe| {
        const call = maybe orelse continue;
        if (call.client != null and call.client.? == client) count += 1;
    }
    return count;
}

fn freeCall(state: *const State) ?usize {
    for (state.calls, 0..) |maybe, index| if (maybe == null) return index;
    return null;
}

const testing = std.testing;

const key_a: Key = "00112233445566778899aabbccddeeff".*;
const key_b: Key = "ffeeddccbbaa99887766554433221100".*;

fn hello(state: *State, id: u32) void {
    var output: Output = .{};
    step(state, .{ .hello = @fromBackingInt(id) }, &output);
}

fn register(state: *State, client: u32, key: Key, ask_form: bool, ask_url: bool, output: *Output) void {
    output.* = .{};
    step(state, .{ .registered = .{ .client = @fromBackingInt(client), .key = key, .ask_form = ask_form, .ask_url = ask_url } }, output);
}

fn startCall(state: *State, client: u32, id: u32, key: Key, output: *Output) CallId {
    output.* = .{};
    step(state, .{ .call = .{ .client = @fromBackingInt(client), .id = id, .key = key } }, output);
    for (output.effects()) |effect| if (effect == .call) return effect.call.call;
    unreachable;
}

fn issue(state: *State, id: CallId, handle: engine.Handle, output: *Output) void {
    output.* = .{};
    step(state, .{ .issued = .{ .call = id, .handle = handle } }, output);
}

fn expectDeclinedQuestion(effects: []const Effect) !void {
    var declined = false;
    for (effects) |effect| switch (effect) {
        .answer => |answer| {
            declined = true;
            try testing.expectEqual(mcp.elicitation.Action.cancel, answer.action);
        },
        else => {},
    };
    try testing.expect(declined);
}

fn hasEffect(effects: []const Effect, comptime tag: std.meta.Tag(Effect)) bool {
    for (effects) |effect| if (effect == tag) return true;
    return false;
}

test "a 2026 input request goes only to its call's client" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    hello(&s, 2);
    register(&s, 1, key_a, true, true, &output);
    register(&s, 2, key_a, true, true, &output);
    const first = startCall(&s, 1, 1, key_a, &output);
    const second = startCall(&s, 2, 1, key_a, &output);
    issue(&s, first, 10, &output);
    issue(&s, second, 11, &output);

    output = .{};
    step(&s, .{ .engine_input = .{ .handle = 10, .requests = "[]" } }, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expectEqual(@as(u32, 1), @backingInt(output.effects()[0].send.to));
    try testing.expectEqual(@as(u32, 1), output.effects()[0].send.message.input.id);
}

test "a 2025 question with one caller goes to it, and with two it is declined" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    hello(&s, 2);
    register(&s, 1, key_a, true, true, &output);
    register(&s, 2, key_a, true, true, &output);
    const first = startCall(&s, 1, 1, key_a, &output);
    issue(&s, first, 10, &output);

    output = .{};
    step(&s, .{ .engine_question = .{ .key = key_a, .slot = 1, .n = 1, .kind = .form, .params = "{}", .version = "2025-11-25" } }, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expectEqual(@as(u32, 1), @backingInt(output.effects()[0].send.to));

    // A second client's call in flight: the question names no call, so the
    // owner declines it rather than show it in the wrong session.
    const second = startCall(&s, 2, 1, key_a, &output);
    issue(&s, second, 11, &output);
    output = .{};
    step(&s, .{ .engine_question = .{ .key = key_a, .slot = 1, .n = 2, .kind = .form, .params = "{}", .version = "2025-11-25" } }, &output);
    try testing.expect(!hasEffect(output.effects(), .send));
    try testing.expect(hasEffect(output.effects(), .answer));
    try testing.expect(hasEffect(output.effects(), .log));
    try testing.expectEqual(mcp.elicitation.Action.cancel, output.effects()[output.len - 1].answer.action);
}

test "a question the only caller cannot show is declined" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    register(&s, 1, key_a, true, false, &output);
    const only = startCall(&s, 1, 1, key_a, &output);
    issue(&s, only, 10, &output);
    output = .{};
    step(&s, .{ .engine_question = .{ .key = key_a, .slot = 1, .n = 1, .kind = .url, .params = "{}", .version = "2025-11-25" } }, &output);
    try testing.expect(!hasEffect(output.effects(), .send));
    try testing.expect(hasEffect(output.effects(), .answer));
}

test "a client that leaves ends only its own calls" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    hello(&s, 2);
    register(&s, 1, key_a, true, true, &output);
    register(&s, 2, key_a, true, true, &output);
    const mine = startCall(&s, 1, 1, key_a, &output);
    const other = startCall(&s, 2, 1, key_a, &output);
    issue(&s, mine, 10, &output);
    issue(&s, other, 11, &output);

    output = .{};
    step(&s, .{ .gone = @fromBackingInt(1) }, &output);
    var cancels: usize = 0;
    for (output.effects()) |effect| switch (effect) {
        .cancel => |cancel| {
            cancels += 1;
            try testing.expectEqual(@as(engine.Handle, 10), cancel.handle);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), cancels);
    // The other client's call still ends with it.
    output = .{};
    step(&s, .{ .engine_called = .{ .handle = 11, .outcome = .result, .maybe_ran = false, .timed_out = false, .oversized = false } }, &output);
    try testing.expectEqual(@as(u32, 2), @backingInt(output.effects()[0].send.to));
}

test "an unregister ends one session's calls on that key, and the server stops only when no session is left" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    hello(&s, 2);
    register(&s, 1, key_a, true, true, &output);
    register(&s, 2, key_a, true, true, &output);
    register(&s, 1, key_b, true, true, &output);
    const mine = startCall(&s, 1, 1, key_a, &output);
    const other = startCall(&s, 2, 1, key_a, &output);
    const elsewhere = startCall(&s, 1, 2, key_b, &output);
    issue(&s, mine, 10, &output);
    issue(&s, other, 11, &output);
    issue(&s, elsewhere, 12, &output);

    // One session leaves the key: only its call there ends, and the server
    // stays for the session still on it.
    output = .{};
    step(&s, .{ .unregister = .{ .client = @fromBackingInt(1), .key = key_a } }, &output);
    var cancels: usize = 0;
    for (output.effects()) |effect| switch (effect) {
        .cancel => |cancel| {
            cancels += 1;
            try testing.expectEqual(@as(engine.Handle, 10), cancel.handle);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), cancels);
    try testing.expect(!hasEffect(output.effects(), .disconnect));

    // The last session leaves it: its own call there ends too, and the key's
    // server stops now.
    output = .{};
    step(&s, .{ .unregister = .{ .client = @fromBackingInt(2), .key = key_a } }, &output);
    var last: usize = 0;
    for (output.effects()) |effect| switch (effect) {
        .cancel => |cancel| {
            last += 1;
            try testing.expectEqual(@as(engine.Handle, 11), cancel.handle);
        },
        .disconnect => |gone| try testing.expectEqualSlices(u8, &key_a, &gone.key),
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), last);
    try testing.expect(hasEffect(output.effects(), .disconnect));

    // The call the first session still runs on another key is untouched.
    output = .{};
    step(&s, .{ .engine_called = .{ .handle = 12, .outcome = .result, .maybe_ran = false, .timed_out = false, .oversized = false } }, &output);
    try testing.expectEqual(@as(u32, 1), @backingInt(output.effects()[0].send.to));
}

test "an unregister answers cancel the questions it held on that key" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    register(&s, 1, key_a, true, true, &output);
    const only = startCall(&s, 1, 1, key_a, &output);
    issue(&s, only, 10, &output);
    step(&s, .{ .engine_question = .{ .key = key_a, .slot = 1, .n = 1, .kind = .form, .params = "{}", .version = "2025-11-25" } }, &output);
    try testing.expect(hasEffect(output.effects(), .send));

    output = .{};
    step(&s, .{ .unregister = .{ .client = @fromBackingInt(1), .key = key_a } }, &output);
    var answers: usize = 0;
    for (output.effects()) |effect| switch (effect) {
        .answer => |answer| {
            answers += 1;
            try testing.expectEqual(mcp.elicitation.Action.cancel, answer.action);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), answers);
    // Nothing is left to answer.
    output = .{};
    step(&s, .{ .answer = .{ .client = @fromBackingInt(1), .key = key_a, .slot = 1, .n = 1, .action = .cancel } }, &output);
    try testing.expect(!hasEffect(output.effects(), .answer));
    try testing.expect(hasEffect(output.effects(), .log));
}

test "an unregister for a key a client does not hold changes nothing" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    register(&s, 1, key_a, true, true, &output);
    output = .{};
    step(&s, .{ .unregister = .{ .client = @fromBackingInt(1), .key = key_b } }, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expect(output.effects()[0].log.what == .unregister_unregistered);
    // The key it holds still serves it.
    output = .{};
    step(&s, .{ .need = .{ .client = @fromBackingInt(1), .key = key_a } }, &output);
    try testing.expect(!hasEffect(output.effects(), .refuse));
}

test "phase, tools, status, and stopped_idle go to every registered client" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    hello(&s, 2);
    register(&s, 1, key_a, true, true, &output);
    register(&s, 2, key_a, true, true, &output);
    for ([_]Event{
        .{ .engine_phase = .{ .key = key_a, .phase = .ready } },
        .{ .engine_tools = .{ .key = key_a, .ok = true, .fresh = false, .needs_auth = false } },
        .{ .engine_status = .{ .key = key_a } },
        .{ .engine_stopped_idle = .{ .key = key_a } },
    }) |event| {
        output = .{};
        step(&s, event, &output);
        try testing.expectEqual(@as(usize, 1), output.len);
        try testing.expectEqual(key_a[0], output.effects()[0].broadcast.key[0]);
    }
}

test "a cancel that comes before its call's handle is applied when it arrives" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    register(&s, 1, key_a, true, true, &output);
    const id = startCall(&s, 1, 1, key_a, &output);
    output = .{};
    step(&s, .{ .cancel = .{ .client = @fromBackingInt(1), .id = 1 } }, &output);
    try testing.expect(!hasEffect(output.effects(), .cancel));
    try testing.expect(hasEffect(output.effects(), .log));
    output = .{};
    step(&s, .{ .issued = .{ .call = id, .handle = 10 } }, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expectEqual(@as(engine.Handle, 10), output.effects()[0].cancel.handle);
}

test "a call the engine refused ends transport_failed" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    register(&s, 1, key_a, true, true, &output);
    const id = startCall(&s, 1, 1, key_a, &output);
    output = .{};
    step(&s, .{ .issue_failed = .{ .call = id } }, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    const called = output.effects()[0].send.message.called;
    try testing.expectEqual(engine.Outcome.transport_failed, called.outcome);
    try testing.expect(!called.maybe_ran);
    try testing.expectEqual(@as(u32, 1), called.id);
}

test "an answer for a question goes only from the client it was shown to" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    hello(&s, 2);
    register(&s, 1, key_a, true, true, &output);
    register(&s, 2, key_a, true, true, &output);
    const first = startCall(&s, 1, 1, key_a, &output);
    issue(&s, first, 10, &output);
    output = .{};
    step(&s, .{ .engine_question = .{ .key = key_a, .slot = 1, .n = 7, .kind = .form, .params = "{}", .version = "2025-11-25" } }, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expectEqual(@as(u32, 1), @backingInt(output.effects()[0].send.to));

    // Another client's answer is dropped: the question showed in session 1.
    output = .{};
    step(&s, .{ .answer = .{ .client = @fromBackingInt(2), .key = key_a, .slot = 1, .n = 7, .action = .accept } }, &output);
    try testing.expect(!hasEffect(output.effects(), .answer));
    try testing.expect(hasEffect(output.effects(), .log));
    // The caller's own answer reaches the server.
    output = .{};
    step(&s, .{ .answer = .{ .client = @fromBackingInt(1), .key = key_a, .slot = 1, .n = 7, .action = .accept } }, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expectEqual(@as(u8, 1), output.effects()[0].answer.slot);
}

test "a client that leaves answers the questions it holds and disconnects the keys it alone held" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    hello(&s, 2);
    register(&s, 1, key_a, true, true, &output);
    register(&s, 2, key_a, true, true, &output);
    const first = startCall(&s, 1, 1, key_a, &output);
    issue(&s, first, 10, &output);
    output = .{};
    step(&s, .{ .engine_question = .{ .key = key_a, .slot = 1, .n = 3, .kind = .form, .params = "{}", .version = "2025-11-25" } }, &output);

    // Session 2 still uses the key, so it stays; the held question is declined.
    output = .{};
    step(&s, .{ .gone = @fromBackingInt(1) }, &output);
    try expectDeclinedQuestion(output.effects());
    try testing.expect(!hasEffect(output.effects(), .disconnect));

    // The last session leaves: the shell disconnects the key, so the server stops.
    output = .{};
    step(&s, .{ .bye = @fromBackingInt(2) }, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expectEqualSlices(u8, &key_a, &output.effects()[0].disconnect.key);

    // A server held by one session alone goes as soon as it leaves.
    var solo: State = .{};
    hello(&solo, 1);
    register(&solo, 1, key_b, true, true, &output);
    output = .{};
    step(&solo, .{ .gone = @fromBackingInt(1) }, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expectEqualSlices(u8, &key_b, &output.effects()[0].disconnect.key);
}

test "a 33rd key is refused for that key alone, and the keys before it stay" {
    var s: State = .{};
    hello(&s, 1);
    var keys: [max_keys_per_client]Key = undefined;
    var output: Output = .{};
    const hex = "0123456789abcdef";
    for (&keys, 0..) |*key, i| {
        // One distinct key per slot, spelled as its launch config's hash is.
        key.* = "00000000000000000000000000000000".*;
        key.*[30] = hex[i / 16];
        key.*[31] = hex[i % 16];
        register(&s, 1, key.*, false, false, &output);
        try testing.expect(!hasEffect(output.effects(), .refuse));
    }
    // The client holds its 32: one more is refused, and the reason names it.
    const extra: Key = "ffffffffffffffffffffffffffffffff".*;
    register(&s, 1, extra, false, false, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expectEqual(Refuse.too_many_keys, output.effects()[0].refuse.reason);
    try testing.expectEqual(extra, output.effects()[0].refuse.key.?);
    // The connection keeps its keys: a need on the first still goes out.
    output = .{};
    step(&s, .{ .need = .{ .client = @fromBackingInt(1), .key = keys[0] } }, &output);
    try testing.expect(!hasEffect(output.effects(), .refuse));
}

test "a second registration for the same key adds no second slot, and an unregistered need is refused" {
    var s: State = .{};
    var output: Output = .{};
    hello(&s, 1);
    register(&s, 1, key_a, true, true, &output);
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expect(std.meta.activeTag(output.effects()[0]) == .register_slot);
    // A registration before hello is refused.
    output = .{};
    step(&s, .{ .registered = .{ .client = @fromBackingInt(2), .key = key_a, .ask_form = true, .ask_url = true } }, &output);
    try testing.expectEqual(Refuse.unknown_client, output.effects()[0].refuse.reason);
    hello(&s, 2);
    register(&s, 2, key_a, true, true, &output);
    // The session that joins a server the owner already runs hears where it
    // is; no second slot appears.
    try testing.expectEqual(@as(usize, 1), output.len);
    try testing.expect(std.meta.activeTag(output.effects()[0]) == .broadcast);
    try testing.expect(output.effects()[0].broadcast.what == .status);
    var slots: usize = 0;
    for (s.slots) |slot| slots += @intFromBool(slot != null);
    try testing.expectEqual(@as(usize, 1), slots);
    output = .{};
    step(&s, .{ .need = .{ .client = @fromBackingInt(1), .key = key_b } }, &output);
    try testing.expectEqual(Refuse.not_registered, output.effects()[0].refuse.reason);
}

// ---- the model's invariants over random sequences ----

const Live = struct { call: CallId, client: u32, key: Key };
const Pending = struct { client: u32, key: Key };

const Model = struct {
    state: State = .{},
    client_of: std.array_hash_map.Auto(CallId, u32) = .empty,
    key_of: std.array_hash_map.Auto(CallId, Key) = .empty,
    pending: std.array_hash_map.Auto(CallId, Pending) = .empty,
    live: std.array_hash_map.Auto(engine.Handle, Live) = .empty,
    handle_of: std.array_hash_map.Auto(CallId, engine.Handle) = .empty,
    seen_call: std.array_hash_map.Auto(CallId, void) = .empty,
    ended: std.array_hash_map.Auto(CallId, void) = .empty,
    questions: std.array_hash_map.Auto(u64, u32) = .empty,
    gone: [4]bool = @splat(false),

    fn deinit(m: *Model, gpa: std.mem.Allocator) void {
        m.client_of.deinit(gpa);
        m.key_of.deinit(gpa);
        m.pending.deinit(gpa);
        m.live.deinit(gpa);
        m.handle_of.deinit(gpa);
        m.seen_call.deinit(gpa);
        m.ended.deinit(gpa);
        m.questions.deinit(gpa);
    }

    /// Every check that follows from the model, run after one step.
    fn check(m: *Model, event: Event, output: *Output) !void {
        for (output.effects()) |effect| switch (effect) {
            .call => |made| {
                // LostNotRetried: a call id is issued once, and never after it ended.
                try testing.expect(!m.seen_call.contains(made.call));
                try testing.expect(!m.ended.contains(made.call));
                try m.seen_call.put(testing.allocator, made.call, {});
                const client = event.call.client;
                try m.client_of.put(testing.allocator, made.call, @backingInt(client));
                try m.key_of.put(testing.allocator, made.call, made.key);
                try m.pending.put(testing.allocator, made.call, .{ .client = @backingInt(client), .key = made.key });
            },
            .send => |sent| {
                // Nothing goes to a client that left.
                try testing.expect(!m.gone[@backingInt(sent.to)]);
                switch (sent.message) {
                    .called, .progress, .input => {},
                    .question => |question| {
                        // QuestionToCaller: only the single client with calls in
                        // flight on the key hears it.
                        var callers: [4]bool = @splat(false);
                        var count: usize = 0;
                        for (m.live.values()) |live| {
                            if (!std.mem.eql(u8, &live.key, &question.key)) continue;
                            // A call whose client left is no caller.
                            if (m.gone[live.client]) continue;
                            if (!callers[live.client]) {
                                callers[live.client] = true;
                                count += 1;
                            }
                        }
                        try testing.expectEqual(@as(usize, 1), count);
                        try testing.expect(callers[@backingInt(sent.to)]);
                    },
                    else => {},
                }
            },
            else => {},
        };
        switch (event) {
            .issued => |issued| {
                const waiting = m.pending.fetchSwapRemove(issued.call) orelse return error.NoSuchCall;
                try testing.expect(!m.live.contains(issued.handle));
                try testing.expect(!m.handle_of.contains(issued.call));
                try m.live.put(testing.allocator, issued.handle, .{ .call = issued.call, .client = waiting.value.client, .key = waiting.value.key });
                try m.handle_of.put(testing.allocator, issued.call, issued.handle);
            },
            .issue_failed => |failed| {
                _ = m.pending.fetchSwapRemove(failed.call) orelse return error.NoSuchCall;
                try m.ended.put(testing.allocator, failed.call, {});
            },
            .engine_called => |called| {
                const live = m.live.fetchSwapRemove(called.handle) orelse return error.NoSuchCall;
                try m.ended.put(testing.allocator, live.value.call, {});
                // NothingToNonCaller: whatever the event sends goes to the caller.
                try expectSendsTo(output.effects(), live.value.client);
            },
            .engine_progress => |progress| {
                const live = m.live.get(progress.handle) orelse return error.NoSuchCall;
                try expectSendsTo(output.effects(), live.client);
            },
            .engine_input => |input| {
                const live = m.live.get(input.handle) orelse return error.NoSuchCall;
                try expectSendsTo(output.effects(), live.client);
            },
            .engine_question => |question| {
                defer for (output.effects()) |effect| switch (effect) {
                    // Records the session a question went to. A put that fails
                    // only by out of memory records none, and the step that
                    // reads it fails with NoSuchCall.
                    .send => |sent| if (sent.message == .question) m.questions.put(testing.allocator, questionId(question.key, question.n), @backingInt(sent.to)) catch {},
                    else => {},
                };
                var callers: [4]bool = @splat(false);
                var count: usize = 0;
                for (m.live.values()) |live| {
                    if (!std.mem.eql(u8, &live.key, &question.key)) continue;
                    if (m.gone[live.client]) continue;
                    if (!callers[live.client]) {
                        callers[live.client] = true;
                        count += 1;
                    }
                }
                var sends: usize = 0;
                for (output.effects()) |effect| switch (effect) {
                    .send => |sent| {
                        sends += 1;
                        try testing.expectEqual(@as(usize, 1), count);
                        for (m.live.values()) |live| {
                            if (!std.mem.eql(u8, &live.key, &question.key) or m.gone[live.client]) continue;
                            try testing.expectEqual(@backingInt(sent.to), live.client);
                        }
                    },
                    .answer => |answer| try testing.expectEqual(mcp.elicitation.Action.cancel, answer.action),
                    else => {},
                };
                if (count != 1) try testing.expectEqual(@as(usize, 0), sends);
            },
            .answer => |answer| {
                // Only the client the question was shown to may answer it.
                const holder = m.questions.get(questionId(answer.key, answer.n));
                var answered = false;
                for (output.effects()) |effect| if (effect == .answer) {
                    answered = true;
                };
                if (answered) {
                    try testing.expectEqual(@backingInt(answer.client), holder orelse return error.NoSuchQuestion);
                    _ = m.questions.fetchSwapRemove(questionId(answer.key, answer.n));
                }
            },
            .unregister => |left| {
                const client = @backingInt(left.client);
                // ExitEndsOwnOnly: a client that leaves one key cancels its
                // own calls there, and nobody else's.
                for (output.effects()) |effect| switch (effect) {
                    .cancel => |cancel| {
                        const live = m.live.get(cancel.handle) orelse continue;
                        try testing.expectEqual(client, live.client);
                        try testing.expect(std.mem.eql(u8, &live.key, &left.key));
                    },
                    .answer => |answer| try testing.expectEqual(mcp.elicitation.Action.cancel, answer.action),
                    .disconnect => |gone| {
                        try testing.expect(std.mem.eql(u8, &gone.key, &left.key));
                        // The server goes only with its last session, and the
                        // key's slot goes with it, so its next registration is
                        // a fresh one: no client is left on the key either way.
                        const left_on = clientsOf(&m.state, gone.key);
                        try testing.expect(left_on == null or left_on.?.count() == 0);
                        try testing.expect(slotFor(&m.state, gone.key) == null);
                    },
                    else => {},
                };
                // Its questions on that key are gone; the ones on other keys
                // are still its own to answer.
                var held: usize = 0;
                var it0 = m.questions.iterator();
                while (it0.next()) |entry| {
                    if (entry.value_ptr.* != client) continue;
                    const which: Key = if (entry.key_ptr.* >= 1000) key_b else key_a;
                    if (!std.mem.eql(u8, &which, &left.key)) continue;
                    held += 1;
                }
                var answers: usize = 0;
                for (output.effects()) |effect| if (effect == .answer) {
                    answers += 1;
                };
                try testing.expectEqual(held, answers);
                var doomed: [64]u64 = undefined;
                var doomed_len: usize = 0;
                var it = m.questions.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != client) continue;
                    const which: Key = if (entry.key_ptr.* >= 1000) key_b else key_a;
                    if (!std.mem.eql(u8, &which, &left.key)) continue;
                    if (doomed_len == doomed.len) break;
                    doomed[doomed_len] = entry.key_ptr.*;
                    doomed_len += 1;
                }
                // Removed after the walk: one swap-remove inside it can move
                // the entry the walk has not reached yet.
                for (doomed[0..doomed_len]) |id| _ = m.questions.fetchSwapRemove(id);
            },
            .gone, .bye => |client| {
                // QuestionToCaller: a client that leaves answers the questions
                // it was holding, so the server does not wait.
                var answers: usize = 0;
                for (output.effects()) |effect| if (effect == .answer) {
                    answers += 1;
                };
                var held: usize = 0;
                var it = m.questions.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == @backingInt(client)) held += 1;
                }
                try testing.expectEqual(held, answers);
                var doomed: [64]u64 = undefined;
                var doomed_len: usize = 0;
                var it2 = m.questions.iterator();
                while (it2.next()) |entry| {
                    if (entry.value_ptr.* != @backingInt(client)) continue;
                    if (doomed_len == doomed.len) break;
                    doomed[doomed_len] = entry.key_ptr.*;
                    doomed_len += 1;
                }
                // Removed after the walk: one swap-remove inside it can move
                // the entry the walk has not reached yet.
                for (doomed[0..doomed_len]) |id| _ = m.questions.fetchSwapRemove(id);
                // ExitEndsOwnOnly: a leaving client cancels its own calls only.
                for (output.effects()) |effect| switch (effect) {
                    .cancel => |cancel| {
                        const live = m.live.get(cancel.handle) orelse continue;
                        try testing.expectEqual(@backingInt(client), live.client);
                    },
                    else => {},
                };
                m.gone[@backingInt(client)] = true;
            },
            else => {},
        }
    }
};

fn expectSendsTo(effects: []const Effect, client: u32) !void {
    for (effects) |effect| switch (effect) {
        .send => |sent| try testing.expectEqual(client, @backingInt(sent.to)),
        else => {},
    };
}

fn pickPending(model: *Model, random: std.Random) ?CallId {
    const count = model.pending.count();
    if (count == 0) return null;
    var want = random.uintLessThan(usize, count);
    for (model.pending.keys()) |id| {
        if (want == 0) return id;
        want -= 1;
    }
    return null;
}

fn pickLive(model: *Model, random: std.Random) ?engine.Handle {
    const count = model.live.count();
    if (count == 0) return null;
    var want = random.uintLessThan(usize, count);
    for (model.live.keys()) |handle| {
        if (want == 0) return handle;
        want -= 1;
    }
    return null;
}

test "random sequences with three clients keep the model's invariants" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for (0..20) |_| try randomRun(random, 1500);
}

fn randomRun(random: std.Random, steps: usize) !void {
    var model: Model = .{};
    defer model.deinit(testing.allocator);
    for (1..4) |id| hello(&model.state, @intCast(id));
    var output: Output = .{};
    for (1..4) |id| {
        const key: Key = if (id == 3) key_b else key_a;
        register(&model.state, @intCast(id), key, random.boolean(), random.boolean(), &output);
    }
    var next_handle: engine.Handle = 1;
    var next_client_call: u32 = 1;
    for (0..steps) |_| {
        const client: u32 = 1 + random.uintLessThan(u32, 3);
        const key: Key = if (random.boolean()) key_a else key_b;
        const event: Event = switch (random.uintLessThan(u8, 21)) {
            0, 1 => .{ .need = .{ .client = @fromBackingInt(client), .key = key } },
            2, 3, 4 => blk: {
                if (model.gone[client]) break :blk .{ .need = .{ .client = @fromBackingInt(client), .key = key } };
                const id = next_client_call;
                next_client_call += 1;
                break :blk .{ .call = .{ .client = @fromBackingInt(client), .id = id, .key = key } };
            },
            5, 6 => .{ .cancel = .{ .client = @fromBackingInt(client), .id = random.uintAtMost(u32, next_client_call) } },
            7 => .{ .respond = .{ .client = @fromBackingInt(client), .id = random.uintAtMost(u32, next_client_call) } },
            8 => blk: {
                const id = pickPending(&model, random) orelse break :blk .{ .engine_phase = .{ .key = key, .phase = .idle } };
                const handle = next_handle;
                next_handle += 1;
                break :blk .{ .issued = .{ .call = id, .handle = handle } };
            },
            9 => blk: {
                const id = pickPending(&model, random) orelse break :blk .{ .engine_phase = .{ .key = key, .phase = .idle } };
                break :blk .{ .issue_failed = .{ .call = id } };
            },
            10 => .{ .engine_phase = .{ .key = key, .phase = if (random.boolean()) .ready else .idle } },
            11 => .{ .engine_tools = .{ .key = key, .ok = random.boolean(), .fresh = false, .needs_auth = false } },
            12 => .{ .engine_status = .{ .key = key } },
            13 => .{ .engine_stopped_idle = .{ .key = key } },
            14 => blk: {
                const handle = pickLive(&model, random) orelse break :blk .{ .engine_phase = .{ .key = key, .phase = .idle } };
                break :blk .{ .engine_called = .{ .handle = handle, .outcome = if (random.boolean()) .result else .lost, .maybe_ran = true, .timed_out = false, .oversized = false } };
            },
            15 => blk: {
                const handle = pickLive(&model, random) orelse break :blk .{ .engine_phase = .{ .key = key, .phase = .idle } };
                break :blk .{ .engine_progress = .{ .handle = handle, .progress = 0.5, .total = null, .message = null } };
            },
            16 => blk: {
                const handle = pickLive(&model, random) orelse break :blk .{ .engine_phase = .{ .key = key, .phase = .idle } };
                break :blk .{ .engine_input = .{ .handle = handle, .requests = "[]" } };
            },
            17 => .{ .engine_question = .{ .key = key, .slot = 1, .n = 1 + random.uintLessThan(u32, 3), .kind = if (random.boolean()) .form else .url, .params = "{}", .version = "2025-11-25" } },
            18 => .{ .answer = .{ .client = @fromBackingInt(client), .key = key, .slot = 1, .n = 1 + random.uintLessThan(u32, 3), .action = .cancel } },
            19 => blk: {
                if (model.gone[client]) break :blk .{ .engine_status = .{ .key = key } };
                break :blk .{ .unregister = .{ .client = @fromBackingInt(client), .key = key } };
            },
            else => blk: {
                if (model.gone[client]) break :blk .{ .engine_status = .{ .key = key } };
                break :blk if (random.boolean()) .{ .gone = @fromBackingInt(client) } else .{ .bye = @fromBackingInt(client) };
            },
        };
        output = .{};
        step(&model.state, event, &output);
        try model.check(event, &output);
    }
}

/// The test's name for a question: its key and number (the generator uses one slot).
fn questionId(key: Key, n: u32) u64 {
    const which: u64 = if (std.mem.eql(u8, &key, &key_a)) 0 else 1000;
    return which + n;
}

/// The clients registered for a key, so the shell can send a broadcast to each.
pub fn clientsOf(state: *const State, key: Key) ?std.bit_set.Static(max_clients) {
    const slot = slotFor(state, key) orelse return null;
    return slot.clients;
}
