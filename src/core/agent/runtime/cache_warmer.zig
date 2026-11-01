//! Keeps one conversation's Claude prompt cache entry alive: holds a copy of
//! the last real request, wakes when the planner in `cache_warming.zig` says
//! to, and sends each ping, the same request with a one-token reply, from its
//! own thread. The conversation's `SessionRuntime` owns it; the agent loop
//! arms it after each completed request and disarms it before each send.
//!
//! Pings are best effort. A ping that fails or writes the entry instead of
//! reading it stops warming until the next real request. Their usage is held
//! here until the agent loop records it with the next request, and is traced
//! when the conversation closes first.

const std = @import("std");
const builtin = @import("builtin");
const cache_warming = @import("cache_warming.zig");
const gateway_step = @import("gateway_step.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const types = @import("../../shared/types.zig");
const io_mod = @import("../../shared/io.zig");
const debug_trace = @import("../../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

/// The request to keep warm. Borrowed for the call; `arm` copies it.
pub const ArmInput = struct {
    provider: agent_stream_provider.Provider,
    model: []const u8,
    session_id: ?[]const u8,
    /// The exact body the request sent.
    body: []const u8,
    api_key: []const u8,
    credential_source: ?types.CredentialSource,
    account_id: ?[]const u8,
    gateway_team: ?[]const u8,
    /// When the request started; the provider keeps the entry for its
    /// lifetime from then.
    started_ms: i64,
};

/// One armed request, owned by the warmer.
const Snapshot = struct {
    provider: agent_stream_provider.Provider,
    model: []u8,
    session_id: ?[]u8,
    ping_body: []u8,
    api_key: []u8,
    credential_source: ?types.CredentialSource,
    account_id: ?[]u8,
    gateway_team: ?[]u8,

    fn create(alloc: Allocator, input: ArmInput) !*Snapshot {
        const ping_body = try pingBody(alloc, input.body) orelse return error.NoReplyLimit;
        errdefer alloc.free(ping_body);
        const model = try alloc.dupe(u8, input.model);
        errdefer alloc.free(model);
        const session_id = if (input.session_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (session_id) |value| alloc.free(value);
        const api_key = try alloc.dupe(u8, input.api_key);
        errdefer {
            std.crypto.secureZero(u8, api_key);
            alloc.free(api_key);
        }
        const account_id = if (input.account_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (account_id) |value| alloc.free(value);
        const gateway_team = if (input.gateway_team) |value| try alloc.dupe(u8, value) else null;
        errdefer if (gateway_team) |value| alloc.free(value);
        const snapshot = try alloc.create(Snapshot);
        snapshot.* = .{
            .provider = input.provider,
            .model = model,
            .session_id = session_id,
            .ping_body = ping_body,
            .api_key = api_key,
            .credential_source = input.credential_source,
            .account_id = account_id,
            .gateway_team = gateway_team,
        };
        return snapshot;
    }

    fn destroy(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.model);
        if (self.session_id) |value| alloc.free(value);
        alloc.free(self.ping_body);
        std.crypto.secureZero(u8, self.api_key);
        alloc.free(self.api_key);
        if (self.account_id) |value| alloc.free(value);
        if (self.gateway_team) |value| alloc.free(value);
        alloc.destroy(self);
    }
};

/// Pings run on the warmer's own thread, so a build without threads, such
/// as libfx's WebAssembly core, keeps nothing warm.
const threads = !builtin.single_threaded;

/// The longest a ping may take before it counts as failed. A ping reads a
/// cached prefix and writes one token, so it answers in about a second.
const max_ping_ms: i64 = 15_000;

pub const Warmer = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    closing: bool = false,
    timing: cache_warming.Timing,
    state: cache_warming.State = .{},
    plan: cache_warming.Plan = .idle,
    /// The request the planner holds.
    armed: ?*Snapshot = null,
    /// The request the ping on the wire was built from; it stays alive
    /// until the ping returns even if a newer arm replaced it.
    sending: ?*Snapshot = null,
    /// Ping usage the agent loop has not recorded yet.
    usage: ?types.Usage = null,
    cancel: std.atomic.Value(bool) = .init(false),

    /// Uses c_allocator: the warmer and its thread outlive any caller scope.
    pub fn create() !*Warmer {
        const warmer = try std.heap.c_allocator.create(Warmer);
        warmer.* = .{ .timing = timingFromEnvironment() };
        return warmer;
    }

    /// Cancels the ping on the wire, joins the thread, and frees everything.
    pub fn destroy(self: *Warmer) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.closing = true;
        self.cancel.store(true, .release);
        self.changed.signal(io);
        self.mutex.unlock(io);
        if (comptime threads) {
            if (self.thread) |thread| thread.join();
        }
        const alloc = std.heap.c_allocator;
        if (self.armed) |snapshot| snapshot.destroy(alloc);
        if (self.usage) |usage| {
            debug_trace.logf("cache_warming", "event=usage_dropped reason=closed read={d} write={d} output={d}", .{
                usage.cache_read_tokens orelse 0, usage.cache_write_tokens orelse 0, usage.output_tokens orelse 0,
            });
        }
        alloc.destroy(self);
    }

    /// Keeps the entry `input` touched warm. Copies `input`; a request the
    /// warmer cannot copy or ping exactly is traced and not kept warm.
    pub fn arm(self: *Warmer, input: ArmInput) void {
        if (comptime !threads) return;
        const alloc = std.heap.c_allocator;
        const snapshot = Snapshot.create(alloc, input) catch |err| {
            debug_trace.logf("cache_warming", "event=not_armed model={s} err={s}", .{ input.model, @errorName(err) });
            self.disarm("not_armed");
            return;
        };
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closing) {
            snapshot.destroy(alloc);
            return;
        }
        self.replaceArmed(snapshot);
        const now_ms = io_mod.milliTimestamp();
        self.apply(.{ .armed = .{ .now_ms = now_ms, .started_ms = input.started_ms } });
        debug_trace.logf("cache_warming", "event=armed model={s} generation={d} body_bytes={d} started_ms={d} age_ms={d}", .{
            input.model, self.state.generation, input.body.len, input.started_ms, now_ms - input.started_ms,
        });
        if (self.thread == null and self.state.armed) {
            self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| spawn: {
                debug_trace.logf("cache_warming", "event=thread_unavailable err={s}", .{@errorName(err)});
                self.apply(.{ .disarmed = .{ .now_ms = now_ms } });
                break :spawn null;
            };
        }
        self.changed.signal(io);
    }

    /// The armed request no longer matches the next one: stop warming it.
    /// Never waits for a ping on the wire.
    pub fn disarm(self: *Warmer, why: []const u8) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const was_armed = self.state.armed;
        self.apply(.{ .disarmed = .{ .now_ms = io_mod.milliTimestamp() } });
        if (was_armed) debug_trace.logf("cache_warming", "event=disarmed why={s} pings={d}", .{ why, self.state.pings });
        self.changed.signal(io);
    }

    /// Ping usage not yet recorded, which the caller now owns.
    pub fn takeUsage(self: *Warmer) ?types.Usage {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        defer self.usage = null;
        return self.usage;
    }

    /// Steps the planner; holds the mutex.
    fn apply(self: *Warmer, event: cache_warming.Event) void {
        self.plan = cache_warming.step(&self.state, self.timing, event);
        switch (self.plan) {
            .stopped => |reason| {
                if (reason != .disarmed) debug_trace.logf("cache_warming", "event=stopped reason={s} pings={d}", .{ @tagName(reason), self.state.pings });
            },
            else => {},
        }
        if (!self.state.armed) self.replaceArmed(null);
    }

    /// Holds the mutex. Frees the replaced request unless a ping still uses it.
    fn replaceArmed(self: *Warmer, snapshot: ?*Snapshot) void {
        const old = self.armed;
        self.armed = snapshot;
        if (old) |replaced| if (replaced != self.sending) replaced.destroy(std.heap.c_allocator);
    }

    fn threadMain(self: *Warmer) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.closing) {
            switch (self.plan) {
                .wait_until => |at_ms| {
                    const now_ms = io_mod.milliTimestamp();
                    if (now_ms < at_ms) {
                        self.changed.waitTimeout(io, &self.mutex, .{ .duration = .{
                            .raw = .fromMilliseconds(at_ms - now_ms),
                            .clock = .awake,
                        } }) catch |err| switch (err) {
                            error.Timeout => {},
                            error.Canceled => return,
                        };
                        continue;
                    }
                    self.apply(.{ .woke = .{ .now_ms = now_ms } });
                },
                .ping => |generation| self.ping(generation),
                .idle, .wait_for_answer, .stopped => self.changed.waitUncancelable(io, &self.mutex),
            }
        }
    }

    /// Sends one ping without holding the mutex and steps the planner with
    /// its answer.
    fn ping(self: *Warmer, generation: u64) void {
        const io = io_mod.getIo();
        const snapshot = self.armed orelse {
            self.apply(.{ .answered = .{ .now_ms = io_mod.milliTimestamp(), .generation = generation, .outcome = .failed } });
            return;
        };
        self.sending = snapshot;
        const started_ms = self.state.in_flight_started_ms;
        debug_trace.logf("cache_warming", "event=ping model={s} generation={d} ping={d}", .{ snapshot.model, generation, self.state.pings });
        self.mutex.unlock(io);
        const answer = sendPing(snapshot, &self.cancel);
        self.mutex.lockUncancelable(io);
        self.sending = null;
        if (snapshot != self.armed) snapshot.destroy(std.heap.c_allocator);
        if (answer.usage) |usage| {
            if (self.usage) |*pending| pending.add(usage) else self.usage = usage;
        }
        const now_ms = io_mod.milliTimestamp();
        debug_trace.logf("cache_warming", "event=ping_answered outcome={s} read={d} write={d} output={d} ms={d} err={s}", .{
            @tagName(answer.outcome),
            if (answer.usage) |usage| usage.cache_read_tokens orelse 0 else 0,
            if (answer.usage) |usage| usage.cache_write_tokens orelse 0 else 0,
            if (answer.usage) |usage| usage.output_tokens orelse 0 else 0,
            now_ms - started_ms,
            answer.err,
        });
        if (self.closing) return;
        self.apply(.{ .answered = .{ .now_ms = now_ms, .generation = generation, .outcome = answer.outcome } });
    }
};

const Answer = struct {
    outcome: cache_warming.Outcome,
    usage: ?types.Usage = null,
    err: []const u8 = "",
};

fn ignoreEvent(_: *anyopaque, _: agent_stream_provider.Event) void {}

fn sendPing(snapshot: *const Snapshot, cancel: *std.atomic.Value(bool)) Answer {
    const alloc = std.heap.c_allocator;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(max_ping_ms),
    });
    var delivery = agent_stream_provider.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    var result = gateway_step.streamModelCompletion(snapshot.provider, alloc, .{
        .purpose = .auxiliary,
        .credential = .{ .direct = .{
            .secret_bytes = snapshot.api_key,
            .source = snapshot.credential_source,
            .account_id = snapshot.account_id,
            .tenant_context = snapshot.gateway_team,
        } },
        .session_id = snapshot.session_id,
        .model = snapshot.model,
        // One attempt: a ping that fails is not worth a second.
        .retry_count = 1,
        .messages = &.{},
        .tool_choice = .none,
        .provider_options = .{},
        .max_output_tokens = 1,
        .prepared_request_body = snapshot.ping_body,
        .trace_ctx = .{},
        .content_capture_limit = 64,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .events = .{ .context = &callback_context, .emit_fn = ignoreEvent },
        .cancel_flag = cancel,
    }) catch |err| return .{ .outcome = .failed, .err = @errorName(err) };
    defer result.deinit(alloc);
    return switch (result) {
        .failed => |failure| .{ .outcome = .failed, .err = @tagName(failure.kind) },
        .completed => |completed| .{ .outcome = outcomeOf(completed.completion.usage), .usage = completed.completion.usage },
    };
}

/// A ping read the entry when the provider served most of it from the
/// cache; a ping that wrote more than it read rebuilt the entry, which only
/// happens when the provider lost it or the ping no longer matches.
fn outcomeOf(usage: types.Usage) cache_warming.Outcome {
    const read = usage.cache_read_tokens orelse 0;
    const write = usage.cache_write_tokens orelse 0;
    return if (read > 0 and write <= read) .read else .missed;
}

/// `body` with its top-level `maxOutputTokens` set to 1, or added when the
/// body has none, and every other byte unchanged: the reply limit is not
/// part of the provider's cache key, so the ping matches the cached prefix
/// exactly. Null when the body is not one JSON object with at most one
/// numeric top-level `maxOutputTokens`. Caller owns the result.
pub fn pingBody(alloc: Allocator, body: []const u8) !?[]u8 {
    var scanner = std.json.Scanner.initCompleteInput(alloc, body);
    defer scanner.deinit();
    const limit = findReplyLimit(alloc, &scanner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    } orelse return null;
    switch (limit) {
        .value => |value| {
            const start = @intFromPtr(value.ptr) - @intFromPtr(body.ptr);
            return try std.mem.concat(alloc, u8, &.{ body[0..start], "1", body[start + value.len ..] });
        },
        .absent => |absent| {
            const field = if (absent.members) ",\"maxOutputTokens\":1" else "\"maxOutputTokens\":1";
            return try std.mem.concat(alloc, u8, &.{ body[0..absent.close], field, body[absent.close..] });
        },
    }
}

const ReplyLimit = union(enum) {
    /// The value's bytes, borrowed from the body.
    value: []const u8,
    /// The body has no reply limit: where its top-level object closes.
    absent: struct { close: usize, members: bool },
};

fn findReplyLimit(alloc: Allocator, scanner: *std.json.Scanner) !?ReplyLimit {
    if (try scanner.next() != .object_begin) return null;
    var found: ?[]const u8 = null;
    var members = false;
    const close = while (true) {
        const key_token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        const key = switch (key_token) {
            .object_end => break scanner.cursor - 1,
            .string => |key| key,
            .allocated_string => |key| key,
            else => return null,
        };
        defer if (key_token == .allocated_string) alloc.free(key_token.allocated_string);
        members = true;
        if (!std.mem.eql(u8, key, "maxOutputTokens")) {
            try scanner.skipValue();
            continue;
        }
        switch (try scanner.next()) {
            .number => |number| {
                if (found != null) return null;
                found = number;
            },
            else => return null,
        }
    };
    if (try scanner.next() != .end_of_document) return null;
    if (found) |value| return .{ .value = value };
    if (scanner.input[close] != '}') return null;
    return .{ .absent = .{ .close = close, .members = members } };
}

/// Claude's timing, or a shorter one the end-to-end tests set with
/// `FX_TEST_CACHE_WARMING_TTL_MS`: the cap stays six lifetimes.
fn timingFromEnvironment() cache_warming.Timing {
    const value = io_mod.getenv("FX_TEST_CACHE_WARMING_TTL_MS") orelse return .claude;
    const ttl_ms = std.fmt.parseInt(i64, value, 10) catch return .claude;
    if (ttl_ms < 500 or ttl_ms > cache_warming.Timing.claude.ttl_ms) return .claude;
    return .{ .ttl_ms = ttl_ms, .cap_ms = ttl_ms * @divTrunc(cache_warming.Timing.claude.cap_ms, cache_warming.Timing.claude.ttl_ms) };
}

const testing = std.testing;

test "a ping changes only the top-level reply limit" {
    const body =
        \\{"prompt":[{"role":"user","content":[{"type":"text","text":"say \"maxOutputTokens\":9"}]}],"tools":[{"name":"t","inputSchema":{"properties":{"maxOutputTokens":{"type":"number"}}}}],"maxOutputTokens":128000,"providerOptions":{"gateway":{"caching":"auto"}}}
    ;
    const ping_body = (try pingBody(testing.allocator, body)).?;
    defer testing.allocator.free(ping_body);
    try testing.expectEqualStrings(
        \\{"prompt":[{"role":"user","content":[{"type":"text","text":"say \"maxOutputTokens\":9"}]}],"tools":[{"name":"t","inputSchema":{"properties":{"maxOutputTokens":{"type":"number"}}}}],"maxOutputTokens":1,"providerOptions":{"gateway":{"caching":"auto"}}}
    , ping_body);
}

test "a body without a reply limit gets one, and nothing else changes" {
    const cases = [_][2][]const u8{
        .{ "{\"prompt\":[],\"tools\":[]}", "{\"prompt\":[],\"tools\":[],\"maxOutputTokens\":1}" },
        .{ "{}", "{\"maxOutputTokens\":1}" },
        .{ "{\"a\":{\"maxOutputTokens\":3}} \n", "{\"a\":{\"maxOutputTokens\":3},\"maxOutputTokens\":1} \n" },
    };
    for (cases) |case| {
        const ping_body = (try pingBody(testing.allocator, case[0])).?;
        defer testing.allocator.free(ping_body);
        try testing.expectEqualStrings(case[1], ping_body);
    }
}

test "a body that is not one object with a single numeric reply limit is not pinged" {
    const cases = [_][]const u8{
        \\{"maxOutputTokens":10,"maxOutputTokens":20}
        ,
        \\{"maxOutputTokens":"10"}
        ,
        \\{"maxOutputTokens":10
        ,
        \\[{"maxOutputTokens":10}]
        ,
        \\{"maxOutputTokens":10} trailing
        ,
    };
    for (cases) |body| try testing.expectEqual(@as(?[]u8, null), try pingBody(testing.allocator, body));
}

test "a reply limit after an escaped key is still found" {
    const body =
        \\{"k\u0065y":{"maxOutputTokens":5},"maxOutputTokens":64}
    ;
    const ping_body = (try pingBody(testing.allocator, body)).?;
    defer testing.allocator.free(ping_body);
    try testing.expectEqualStrings(
        \\{"k\u0065y":{"maxOutputTokens":5},"maxOutputTokens":1}
    , ping_body);
}

test "pingBody frees everything on allocation failure" {
    const body =
        \\{"k\u0065y":1,"maxOutputTokens":64}
    ;
    try testing.checkAllAllocationFailures(@import("../../shared/testing_allocator.zig").no_resize, struct {
        fn run(alloc: Allocator, input: []const u8) !void {
            const out = (try pingBody(alloc, input)).?;
            alloc.free(out);
        }
    }.run, .{body});
}

test "a ping that wrote more than it read missed the entry" {
    try testing.expectEqual(cache_warming.Outcome.read, outcomeOf(.{ .cache_read_tokens = 9_530, .cache_write_tokens = 0 }));
    try testing.expectEqual(cache_warming.Outcome.read, outcomeOf(.{ .cache_read_tokens = 9_530, .cache_write_tokens = 12 }));
    try testing.expectEqual(cache_warming.Outcome.missed, outcomeOf(.{ .cache_read_tokens = 0, .cache_write_tokens = 9_530 }));
    try testing.expectEqual(cache_warming.Outcome.missed, outcomeOf(.{}));
}

/// A provider that records each ping and answers as told. `block` holds a
/// ping on the wire until the warmer cancels it.
const FakeProvider = struct {
    mutex: std.Io.Mutex = .init,
    bodies: std.ArrayList([]u8) = .empty,
    models: std.ArrayList([]u8) = .empty,
    session_ids: std.ArrayList(?[]u8) = .empty,
    max_output_tokens: ?u32 = null,
    retry_count: usize = 0,
    usage: types.Usage = .{ .cache_read_tokens = 9_530, .cache_write_tokens = 0, .output_tokens = 1 },
    fail: bool = false,
    block: bool = false,

    fn provider(self: *FakeProvider) agent_stream_provider.Provider {
        return .{ .context = self, .stream_fn = stream };
    }

    fn stream(context: ?*anyopaque, _: Allocator, request: agent_stream_provider.ModelRequest) anyerror!agent_stream_provider.Result {
        const self: *FakeProvider = @ptrCast(@alignCast(context.?));
        const io = io_mod.getIo();
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try self.bodies.append(testing.allocator, try testing.allocator.dupe(u8, request.prepared_request_body.?));
            try self.models.append(testing.allocator, try testing.allocator.dupe(u8, request.model));
            try self.session_ids.append(testing.allocator, if (request.session_id) |id| try testing.allocator.dupe(u8, id) else null);
            self.max_output_tokens = request.max_output_tokens;
            self.retry_count = request.retry_count;
        }
        try request.admission.admit();
        request.delivery.markPossiblySent();
        if (self.block) {
            while (!request.cancel_flag.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            return error.Cancelled;
        }
        if (self.fail) return agent_stream_provider.failResult(error.TestPingFailed);
        return .{ .completed = .{ .completion = .{ .usage = self.usage } } };
    }

    fn pings(self: *FakeProvider) usize {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.bodies.items.len;
    }

    fn deinit(self: *FakeProvider) void {
        for (self.bodies.items) |body| testing.allocator.free(body);
        self.bodies.deinit(testing.allocator);
        for (self.models.items) |model| testing.allocator.free(model);
        self.models.deinit(testing.allocator);
        for (self.session_ids.items) |id| if (id) |value| testing.allocator.free(value);
        self.session_ids.deinit(testing.allocator);
    }
};

const test_body =
    \\{"prompt":[{"role":"user","content":[{"type":"text","text":"hi"}]}],"maxOutputTokens":128000,"providerOptions":{"gateway":{"caching":"auto"}}}
;

/// A warmer with a two-second lifetime whose first ping is due at once.
fn armedForTest(fake: *FakeProvider) !*Warmer {
    const warmer = try Warmer.create();
    warmer.timing = .{ .ttl_ms = 2_000, .cap_ms = 12_000 };
    warmer.arm(.{
        .provider = fake.provider(),
        .model = "anthropic/claude-opus-5.5",
        .session_id = "s1",
        .body = test_body,
        .api_key = "key",
        .credential_source = .ai_gateway_api_key,
        .account_id = null,
        .gateway_team = null,
        .started_ms = io_mod.milliTimestamp() - warmer.timing.interval(),
    });
    return warmer;
}

fn waitFor(comptime condition: fn (*FakeProvider) bool, fake: *FakeProvider) !void {
    for (0..2_000) |_| {
        if (condition(fake)) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestTimedOut;
}

fn pinged(fake: *FakeProvider) bool {
    return fake.pings() >= 1;
}

fn warmerSettled(warmer: *Warmer) bool {
    const io = io_mod.getIo();
    warmer.mutex.lockUncancelable(io);
    defer warmer.mutex.unlock(io);
    return warmer.state.in_flight == null and warmer.sending == null;
}

test "a due ping resends the exact request with a one-token reply and keeps its usage" {
    var fake: FakeProvider = .{};
    defer fake.deinit();
    const warmer = try armedForTest(&fake);
    defer warmer.destroy();
    try waitFor(pinged, &fake);
    for (0..2_000) |_| {
        if (warmerSettled(warmer)) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try testing.expectEqualStrings(
        \\{"prompt":[{"role":"user","content":[{"type":"text","text":"hi"}]}],"maxOutputTokens":1,"providerOptions":{"gateway":{"caching":"auto"}}}
    , fake.bodies.items[0]);
    try testing.expectEqualStrings("anthropic/claude-opus-5.5", fake.models.items[0]);
    try testing.expectEqualStrings("s1", fake.session_ids.items[0].?);
    try testing.expectEqual(@as(?u32, 1), fake.max_output_tokens);
    try testing.expectEqual(@as(usize, 1), fake.retry_count);
    // The ping read the entry, so the next one waits a full interval.
    try testing.expect(warmer.state.armed);
    try testing.expectEqual(@as(usize, 1), fake.pings());
    const usage = warmer.takeUsage().?;
    try testing.expectEqual(@as(?u64, 9_530), usage.cache_read_tokens);
    try testing.expectEqual(@as(?types.Usage, null), warmer.takeUsage());
    // A real request disarms it; no ping follows.
    warmer.disarm("request");
    try testing.expect(!warmer.state.armed);
    try testing.expectEqual(@as(?*Snapshot, null), warmer.armed);
}

test "a failed ping stops warming until the next arm" {
    var fake: FakeProvider = .{ .fail = true };
    defer fake.deinit();
    const warmer = try armedForTest(&fake);
    defer warmer.destroy();
    try waitFor(pinged, &fake);
    for (0..2_000) |_| {
        if (warmerSettled(warmer)) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try testing.expect(!warmer.state.armed);
    try testing.expectEqual(@as(?cache_warming.Stop, .failed), warmer.state.stopped);
    try testing.expectEqual(@as(?*Snapshot, null), warmer.armed);
}

test "a ping that wrote the entry stops warming" {
    var fake: FakeProvider = .{ .usage = .{ .cache_read_tokens = 0, .cache_write_tokens = 9_530 } };
    defer fake.deinit();
    const warmer = try armedForTest(&fake);
    defer warmer.destroy();
    try waitFor(pinged, &fake);
    for (0..2_000) |_| {
        if (warmerSettled(warmer)) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(?cache_warming.Stop, .missed), warmer.state.stopped);
    // The write is still paid for, so it is still recorded.
    try testing.expectEqual(@as(?u64, 9_530), warmer.takeUsage().?.cache_write_tokens);
}

test "closing cancels a ping on the wire and joins at once" {
    var fake: FakeProvider = .{ .block = true };
    defer fake.deinit();
    const warmer = try armedForTest(&fake);
    try waitFor(pinged, &fake);
    const started = io_mod.milliTimestamp();
    warmer.destroy();
    try testing.expect(io_mod.milliTimestamp() - started < 1_000);
}

test "closing while waiting for the next ping does not wait for it" {
    var fake: FakeProvider = .{};
    defer fake.deinit();
    const warmer = try Warmer.create();
    warmer.arm(.{
        .provider = fake.provider(),
        .model = "anthropic/claude-opus-5.5",
        .session_id = null,
        .body = test_body,
        .api_key = "key",
        .credential_source = .ai_gateway_api_key,
        .account_id = null,
        .gateway_team = null,
        .started_ms = io_mod.milliTimestamp(),
    });
    try testing.expect(warmer.state.armed);
    io_mod.sleep(20 * std.time.ns_per_ms);
    const started = io_mod.milliTimestamp();
    warmer.destroy();
    try testing.expect(io_mod.milliTimestamp() - started < 1_000);
    try testing.expectEqual(@as(usize, 0), fake.pings());
}

test "a request whose body is not a JSON object is not armed" {
    var fake: FakeProvider = .{};
    defer fake.deinit();
    const warmer = try Warmer.create();
    defer warmer.destroy();
    warmer.arm(.{
        .provider = fake.provider(),
        .model = "anthropic/claude-opus-5.5",
        .session_id = null,
        .body = "[{\"maxOutputTokens\":10}]",
        .api_key = "key",
        .credential_source = .ai_gateway_api_key,
        .account_id = null,
        .gateway_team = null,
        .started_ms = io_mod.milliTimestamp(),
    });
    try testing.expect(!warmer.state.armed);
    try testing.expectEqual(@as(?std.Thread, null), warmer.thread);
}
