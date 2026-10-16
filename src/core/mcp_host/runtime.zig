//! fx's side of MCP-v2. One thread owns the engine, which is
//! single-threaded: other threads send it requests through a queue, wake it,
//! and read copied status snapshots. The owner turns fx's MCP config into the
//! engine's servers (`config.zig`), keeps sign-in credentials
//! (`credentials.zig`), and runs logins on a loopback listener (`login.zig`).
//! Chosen with FX_MCP_ENGINE=v2 until v1 is removed.
//!
//! TLA+ models: `tests/tla/mcp_host/HostLifecycle.tla`,
//! `tests/tla/mcp_host/SignIn.tla`, `tests/tla/mcp_host/SharedLogins.tla`, and
//! `tests/tla/mcp_host/ElicitationRouting.tla`.

const std = @import("std");
const observation = @import("../agent/runtime/observation.zig");
const mcp = @import("../../mcp/mcp.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const io_mod = @import("../shared/io.zig");
const host_target = @import("../hosts/target.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const url_opener = @import("../hosts/url_opener.zig");
const secret = @import("../auth/secret.zig");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const loopback = @import("login.zig");
const elicitation = @import("../mcp/elicitation.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");

const Allocator = std.mem.Allocator;
const engine = mcp.engine;

/// A login waits this long for the browser to come back.
const login_timeout_ms: i64 = 5 * 60 * 1000;
/// The longest the owner sleeps; a `wake` ends it sooner.
const idle_wait_ms: u32 = 1000;
/// How long a logout waits for its revocation, as MCP-v2's `close` does.
const revoke_wait_ms: i64 = 2000;
/// How long a refresh waits for another fx refreshing the same login; then
/// it refreshes anyway.
const refresh_lock_wait_ms: i64 = 10_000;
/// How often a refresh waiting for that lock tries it again.
const refresh_retry_ms: u32 = 20;

/// For a program that exits next: every stdio server it
/// runs gets SIGTERM and nothing waits, so quitting takes no longer with
/// servers than without. Hosts, their threads, and their memory are left to
/// the exiting process, and a logout already waited for its revocation.
pub fn signalServersForExit() void {
    if (comptime host_target.is_wasm) return;
    mcp.stdio.signalAllForExit(io_mod.getIo());
}

/// Retired runtimes, in the whole program, from when they were replaced until
/// their servers are gone: still in use by calls that began on them, or
/// stopping on a thread of their own (`Host.stop`). Until then, no other
/// runtime takes a request that could start a server, so one never runs
/// twice.
var retiring: std.atomic.Value(u32) = .init(0);
/// How often a held runtime looks again.
const retiring_wait_ms: u32 = 50;

fn retireStarted() void {
    _ = retiring.fetchAdd(1, .acq_rel);
}

fn retireEnded() void {
    _ = retiring.fetchSub(1, .acq_rel);
}

/// Waits until every retired runtime's servers are gone.
pub fn waitRetired() void {
    while (retiring.load(.acquire) != 0) io_mod.sleep(5 * std.time.ns_per_ms);
}

/// FX_MCP_ENGINE=v2 selects MCP-v2.
pub fn selected() bool {
    const value = io_mod.getenv("FX_MCP_ENGINE") orelse return false;
    return std.mem.eql(u8, value, "v2");
}

pub const State = enum {
    idle,
    connecting,
    ready,
    retrying,
    failed,
    disabled,
    waiting_for_approval,
    rejected,
    unsupported,
    missing_env,
    invalid_env,
};

pub const Status = struct {
    name: []const u8,
    source: mcp_contract.ConfigSource,
    transport: mcp_contract.McpTransport,
    state: State,
    version: ?[]const u8 = null,
    tools: usize = 0,
    last_error: ?[]const u8 = null,
    needs_login: bool = false,
    signed_in: bool = false,
    /// The variable a `missing_env` or `invalid_env` server names.
    missing: ?[]const u8 = null,
    /// What the server told fx to tell the model about it.
    instructions: ?[]const u8 = null,
};

pub const Tool = struct { name: []const u8, raw: []const u8 };

pub const ToolsResult = union(enum) {
    tools: []Tool,
    needs_login,
    /// The server could not list its tools; the reason.
    failed: []const u8,
    unknown_server,
};

pub const CallResult = union(enum) {
    result: struct { content: []const u8, structured: ?[]const u8, is_error: bool },
    /// The server answered with a protocol error; `message` is a JSON string literal.
    failure: struct { code: i64, message: []const u8 },
    /// The call ended without an answer.
    ended: struct { outcome: engine.Outcome, maybe_ran: bool, timed_out: bool },
    unknown_server,
};

/// A question an MCP server asks during a call, for fx's question UI.
pub const Question = struct {
    server: []const u8,
    /// MCP's `inputRequests` object: each key with its `elicitation/create`
    /// request.
    input_requests_json: []const u8,
    /// The version the server speaks, which decides how a form's schema reads.
    version: ?[]const u8,
};

/// Asks a call's questions on the caller's thread. Returns the
/// `inputResponses` object in `alloc`, or null to decline.
pub const Asker = struct {
    context: *anyopaque,
    ask: *const fn (context: *anyopaque, alloc: Allocator, question: Question) anyerror!?[]u8,
};

pub const Notice = union(enum) {
    /// The URL to sign in at; opened in the browser when the login asked for that.
    authorize: struct { server: []const u8, url: []const u8 },
    signed_in: []const u8,
    sign_in_failed: struct { server: []const u8, reason: []const u8 },
    needs_login: []const u8,
    /// A new login couldn't be saved: it works in this process only.
    not_saved: struct { server: []const u8, reason: []const u8 },
};

/// Called on the owner thread; the slices in a notice are valid for the call.
pub const Notify = struct {
    context: *anyopaque,
    notice: *const fn (context: *anyopaque, notice: Notice) void,
};

pub const Options = struct {
    client_version: []const u8,
    credentials: credentials.Store,
    /// The workspace whose `.mcp.json` servers keep their own logins.
    workspace_root: []const u8 = "",
    notify: ?Notify = null,
    /// The questions fx's UI on this surface can ask, declared to servers so
    /// they only ask those.
    questions: elicitation.Capabilities = .{},
    /// Where a 2025 server's URL completions go: ACP sends the editor
    /// `elicitation/complete`.
    url_completions: ?tool_mcp_runtime.LegacyUrlCompletionSink = null,
    /// The surface takes slash commands, as fx's shell does, so the model
    /// tells the user to sign in with `/mcp login NAME`, not in a terminal.
    slash_commands: bool = false,
};

pub const Error = Allocator.Error || error{
    UnknownServer,
    /// Only HTTP servers sign in.
    NotHttp,
    /// The server is held back; its status says why.
    Held,
    /// No login is waiting for the browser.
    NotSigningIn,
    /// The runtime is stopping.
    Stopped,
    /// The caller's cancel flag ended the request.
    Cancelled,
    /// The engine refused the request; the trace says why.
    Failed,
    /// The saved sign-ins can't be read, damaged or saved by a newer fx, so a
    /// sign-in or sign-out changes nothing.
    CredentialStoreUnreadable,
    /// Another program holds the sign-in's fixed callback port.
    CallbackPortInUse,
};

const Request = struct {
    observation: ?observation.McpCall = null,
    kind: Kind,
    /// Results are allocated with it; the caller doesn't use it while waiting.
    alloc: Allocator,
    done: std.Io.Event = .unset,
    result: Outcome = .none,
    /// Freed by the owner once handled; set for requests the owner posts itself.
    owned: bool = false,
    /// The browser's address a login task posted, until a login takes it.
    owned_url: ?[]u8 = null,
    /// A call's way to ask the user, on the caller's thread.
    asker: ?Asker = null,
    /// Guarded by `Runtime.mutex`: a question waiting for the caller to ask.
    question: ?Pending = null,
    /// Owner thread only: fx declined the server's question, so the call's
    /// cancellation is fx's answer, not the user's.
    declined: bool = false,

    const Kind = union(enum) {
        tools: []const u8,
        /// Starts a server's tool list without anyone waiting for it.
        need: usize,
        call: struct { server: []const u8, tool: []const u8, arguments: ?[]const u8 },
        cancel: *Request,
        login: struct { server: []const u8, open_browser: bool },
        finish_login: struct { server: []const u8, url: []const u8 },
        logout: []const u8,
        /// Servers that need a login take one another fx saved since.
        pick_up,
        /// What the user answered, posted by the caller that asked.
        answer: struct { pending: Pending, json: ?[]u8 },

        /// Whether handling it could start a server.
        fn mayStart(k: Kind) bool {
            return switch (k) {
                .tools, .need, .call, .login, .finish_login, .pick_up => true,
                .cancel, .logout, .answer => false,
            };
        }
    };

    const Outcome = union(enum) {
        none,
        ok,
        failed: Error,
        tools: ToolsResult,
        call: CallResult,
    };
};

/// A question the owner hands a calling thread, with what it takes to
/// answer it. Owned by the runtime's allocator.
const Pending = struct {
    server: usize,
    json: []u8,
    version: ?[]u8,
    reply: union(enum) {
        /// 2026: the call's input requests, answered in this key order.
        input: struct { call: engine.Handle, keys: [][]u8 },
        /// 2025: the server's elicitation, by slot and number, so an answer
        /// to one it withdrew never reaches the next in that slot.
        elicit: mcp.core.elicitation.Id,
    },

    fn deinit(p: *Pending, gpa: Allocator) void {
        gpa.free(p.json);
        if (p.version) |v| gpa.free(v);
        switch (p.reply) {
            .input => |input| {
                for (input.keys) |k| gpa.free(k);
                gpa.free(input.keys);
            },
            .elicit => {},
        }
        p.* = undefined;
    }
};

const Login = struct {
    runtime: *Runtime,
    server: usize,
    listener: loopback.Listener,
    group: std.Io.Group = .init,
    deadline_ms: i64,
    open_browser: bool,
    /// The address the browser came back to, kept until the login ends:
    /// MCP-v2 reads the code in it when it redeems it.
    callback: ?[]u8 = null,
};

pub const Runtime = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    arena: std.heap.ArenaAllocator,
    resolved: config.Resolved,
    engine: engine.Engine,
    /// Per server in `resolved.servers`; owner thread only.
    flags: []Flags,
    thread: ?std.Thread = null,
    /// Set by `retire`; read by the owner thread.
    retired: std.atomic.Value(bool) = .init(false),

    mutex: std.Io.Mutex = .init,
    /// Guarded by `mutex`.
    queue: std.ArrayList(*Request) = .empty,
    /// Guarded by `mutex`.
    stopping: bool = false,
    /// Callers inside `submit` or `statuses`; `deinit` waits for none, so a
    /// call that is still waiting when it starts can return safely.
    active: std.atomic.Value(u32) = .init(0),
    /// Guarded by `mutex`: the latest statuses, in `snapshot_arena`.
    snapshot: []Status = &.{},
    snapshot_arena: std.heap.ArenaAllocator,

    /// Owner thread only.
    calls: std.AutoHashMapUnmanaged(engine.Handle, *Request) = .empty,
    tool_waiters: std.ArrayList(struct { server: usize, request: *Request }) = .empty,
    logins: std.ArrayList(*Login) = .empty,
    /// 2025 URL questions the client was shown, by server and slot, with the
    /// server's elicitation id, until the server completes or withdraws them.
    url_questions: std.ArrayList(struct { server: usize, slot: u8, id: []u8 }) = .empty,
    /// Logouts waiting for their revocation's answer.
    logouts: std.ArrayList(struct { server: usize, request: *Request, deadline_ms: i64 }) = .empty,
    refreshes: std.ArrayList(Refresh) = .empty,
    /// Finished requests, woken only once the snapshot that follows them is
    /// published, so a caller never reads a status older than its result.
    finished: std.ArrayList(*Request) = .empty,

    const Flags = struct {
        needs_login: bool = false,
        signed_in: bool = false,
        /// The last saved credential this server had or tried, so a stale
        /// one isn't taken twice.
        tried: ?[32]u8 = null,
        /// A save failed, and the user heard so.
        not_saved: bool = false,
    };

    /// A refresh MCP-v2 said was due: waiting for its login's refresh lock,
    /// or holding it until the refresh ends.
    const Refresh = struct {
        server: usize,
        lock: ?credentials.Store.Locked = null,
        sent: bool = false,
        deadline_ms: i64,
    };

    /// Starts the engine with `configs` (from `loadNativeConfigs`) and its
    /// owner thread. `configs` and `inherited` are read only during the call.
    /// `gpa` must be thread-safe, and `r` must not move until `deinit`: the
    /// engine and login tasks point at it. Nothing connects until a server
    /// is needed.
    pub fn start(
        r: *Runtime,
        gpa: Allocator,
        io: std.Io,
        configs: []const mcp_contract.McpServerConfig,
        inherited: *const std.process.Environ.Map,
        options: Options,
    ) !void {
        r.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .arena = .init(gpa),
            .resolved = undefined,
            .engine = undefined,
            .flags = &.{},
            .snapshot_arena = .init(gpa),
        };
        errdefer r.arena.deinit();
        errdefer r.snapshot_arena.deinit();
        const arena = r.arena.allocator();
        r.resolved = try config.resolve(arena, configs, inherited, .{ .context = r, .get = savedCredential }, r.options.workspace_root);
        r.flags = try arena.alloc(Flags, r.resolved.servers.len);
        for (r.flags) |*f| f.* = .{};
        for (r.resolved.engine, r.resolved.engine_server) |c, i| {
            r.flags[i].signed_in = c.auth.saved != null;
            if (c.auth.saved) |saved| r.flags[i].tried = credentials.digest(saved);
        }
        try r.engine.init(io, gpa, .{ .context = r, .allow = allow, .log = log }, .{
            .client = .{ .info = .{ .name = "fx", .version = options.client_version }, .capabilities = declaredCapabilities(options.questions) },
        }, r.resolved.engine);
        errdefer r.engine.deinit();
        // The engine has its own copies now.
        for (r.resolved.engine) |c| if (c.auth.saved) |s| std.crypto.secureZero(u8, @constCast(s));
        // The rest may point into `configs`, which the caller may free now.
        r.resolved.engine = &.{};
        try r.publish();
        r.thread = try std.Thread.spawn(.{}, run, .{r});
    }

    /// Replaced: from now until `deinit`, no other runtime starts a server.
    /// This one still takes every request, so calls that began here finish.
    pub fn retire(r: *Runtime) void {
        if (!r.retired.swap(true, .acq_rel)) retireStarted();
    }

    /// Whether requests that could start a server wait: a retired runtime
    /// elsewhere still has servers.
    fn waitsForRetired(r: *const Runtime) bool {
        return !r.retired.load(.acquire) and retiring.load(.acquire) != 0;
    }

    /// Ends every waiting request, stops the servers, and joins the owner.
    pub fn deinit(r: *Runtime) void {
        r.mutex.lockUncancelable(r.io);
        r.stopping = true;
        r.mutex.unlock(r.io);
        r.engine.wake();
        if (r.thread) |t| t.join();
        // The owner ended every request; let their callers leave first.
        while (r.active.load(.acquire) != 0) std.Io.sleep(r.io, .fromMilliseconds(1), .awake) catch {};
        r.queue.deinit(r.gpa);
        r.calls.deinit(r.gpa);
        r.tool_waiters.deinit(r.gpa);
        r.logins.deinit(r.gpa);
        r.logouts.deinit(r.gpa);
        r.refreshes.deinit(r.gpa);
        for (r.url_questions.items) |q| r.gpa.free(q.id);
        r.url_questions.deinit(r.gpa);
        r.finished.deinit(r.gpa);
        r.snapshot_arena.deinit();
        r.arena.deinit();
        const was_retired = r.retired.load(.acquire);
        r.* = undefined;
        // Its servers are down: the others may start theirs.
        if (was_retired) retireEnded();
    }

    /// Every configured server's status, copied into `alloc`.
    pub fn statuses(r: *Runtime, alloc: Allocator) Allocator.Error![]Status {
        _ = r.active.fetchAdd(1, .acq_rel);
        defer _ = r.active.fetchSub(1, .acq_rel);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const out = try alloc.alloc(Status, r.snapshot.len);
        for (r.snapshot, out) |s, *o| {
            o.* = s;
            o.name = try alloc.dupe(u8, s.name);
            if (s.version) |v| o.version = try alloc.dupe(u8, v);
            if (s.last_error) |e| o.last_error = try alloc.dupe(u8, e);
            if (s.missing) |m| o.missing = try alloc.dupe(u8, m);
            if (s.instructions) |t| o.instructions = try alloc.dupe(u8, t);
        }
        return out;
    }

    /// Server `index`'s instructions (in `servers()` order), copied into
    /// `alloc`; null when it gave none.
    pub fn instructions(r: *Runtime, alloc: Allocator, index: usize) Allocator.Error!?[]const u8 {
        _ = r.active.fetchAdd(1, .acq_rel);
        defer _ = r.active.fetchSub(1, .acq_rel);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (index >= r.snapshot.len) return null;
        const text = r.snapshot[index].instructions orelse return null;
        return try alloc.dupe(u8, text);
    }

    /// The resolved servers, in config order; they don't change while the
    /// runtime runs.
    pub fn servers(r: *const Runtime) []const config.Server {
        return r.resolved.servers;
    }

    /// The server's tools, starting it if needed; blocks until it has them,
    /// can't get them, or `cancel` is set. Results are owned by `alloc`.
    pub fn tools(r: *Runtime, alloc: Allocator, server: []const u8, cancel: ?*const std.atomic.Value(bool)) Error!ToolsResult {
        var req: Request = .{ .kind = .{ .tools = server }, .alloc = alloc };
        try r.submit(&req, cancel);
        return switch (req.result) {
            .tools => |t| t,
            .failed => |err| err,
            else => unreachable,
        };
    }

    /// Starts getting the tool list of `resolved.servers[index]` without
    /// waiting, so several servers start at once; `tools` then waits less.
    pub fn prepare(r: *Runtime, index: usize) Error!void {
        const req = try r.gpa.create(Request);
        req.* = .{ .kind = .{ .need = index }, .alloc = r.gpa, .owned = true };
        r.post(req) catch |err| {
            r.gpa.destroy(req);
            return err;
        };
    }

    /// Calls `tool` with a JSON object (or null), after fx's permission
    /// allowed it; blocks until it ends. Setting `cancel` cancels it. The
    /// server's questions go to `asker`, and are declined without one.
    pub fn call(
        r: *Runtime,
        alloc: Allocator,
        server: []const u8,
        tool: []const u8,
        arguments: ?[]const u8,
        cancel: ?*const std.atomic.Value(bool),
        asker: ?Asker,
    ) Error!CallResult {
        return r.callObserved(alloc, server, tool, arguments, cancel, asker, null);
    }

    pub fn callObserved(r: *Runtime, alloc: Allocator, server: []const u8, tool: []const u8, arguments: ?[]const u8, cancel: ?*const std.atomic.Value(bool), asker: ?Asker, observed: ?observation.McpCall) Error!CallResult {
        var req: Request = .{ .kind = .{ .call = .{ .server = server, .tool = tool, .arguments = arguments } }, .alloc = alloc, .asker = asker, .observation = observed };
        try r.submit(&req, cancel);
        return switch (req.result) {
            .call => |c| c,
            .failed => |err| err,
            else => unreachable,
        };
    }

    /// Starts signing in to an HTTP server: a `.authorize` notice carries the
    /// URL, and `.signed_in` or `.sign_in_failed` ends it.
    pub fn login(r: *Runtime, server: []const u8, open_browser: bool) Error!void {
        var req: Request = .{ .kind = .{ .login = .{ .server = server, .open_browser = open_browser } }, .alloc = r.gpa };
        try r.submitOk(&req);
    }

    /// Finishes a login with the address the browser came back to, when it
    /// was pasted instead of reaching the listener.
    pub fn finishLogin(r: *Runtime, server: []const u8, url: []const u8) Error!void {
        var req: Request = .{ .kind = .{ .finish_login = .{ .server = server, .url = url } }, .alloc = r.gpa };
        try r.submitOk(&req);
    }

    /// Signs out: the token is revoked where the server can, and forgotten.
    pub fn logout(r: *Runtime, server: []const u8) Error!void {
        var req: Request = .{ .kind = .{ .logout = server }, .alloc = r.gpa };
        try r.submitOk(&req);
    }

    /// Every server that needs a login takes one saved since by another fx,
    /// if there is one, before a status is shown.
    pub fn pickUpLogins(r: *Runtime) Error!void {
        var req: Request = .{ .kind = .pick_up, .alloc = r.gpa };
        try r.submitOk(&req);
    }

    fn submitOk(r: *Runtime, req: *Request) Error!void {
        try r.submit(req, null);
        switch (req.result) {
            .ok => {},
            .failed => |err| return err,
            else => unreachable,
        }
    }

    /// Queues `req` and waits for the owner to finish it. A cancel is sent
    /// once when `cancel` is set, and waited for too, so the owner never
    /// holds a request that has gone.
    fn submit(r: *Runtime, req: *Request, cancel: ?*const std.atomic.Value(bool)) Error!void {
        _ = r.active.fetchAdd(1, .acq_rel);
        defer _ = r.active.fetchSub(1, .acq_rel);
        const io = r.io;
        try r.post(req);
        var cancel_req: Request = .{ .kind = .{ .cancel = req }, .alloc = r.gpa };
        var cancel_tried = false;
        var cancel_sent = false;
        while (!req.done.isSet()) {
            req.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
            if (req.asker) |asker| r.askWaiting(req, asker);
            if (!cancel_tried) if (cancel) |flag| if (flag.load(.acquire)) {
                cancel_tried = true;
                // When stopping, the owner ends the request itself.
                cancel_sent = if (r.post(&cancel_req)) |_| true else |_| false;
            };
        }
        if (cancel_sent) cancel_req.done.waitUncancelable(io);
    }

    /// On the caller's thread: asks the question the owner left, if any, and
    /// posts the answer back. The call may end meanwhile; the answer is then
    /// dropped.
    fn askWaiting(r: *Runtime, req: *Request, asker: Asker) void {
        r.mutex.lockUncancelable(r.io);
        var pending = req.question orelse {
            r.mutex.unlock(r.io);
            return;
        };
        req.question = null;
        r.mutex.unlock(r.io);
        var scratch: std.heap.ArenaAllocator = .init(r.gpa);
        defer scratch.deinit();
        const answer = asker.ask(asker.context, scratch.allocator(), .{
            .server = r.resolved.servers[pending.server].name,
            .input_requests_json = pending.json,
            .version = pending.version,
        }) catch |err| answer: {
            debug_trace.logf("mcp", "MCP question not answered server={s} err={s}", .{ r.resolved.servers[pending.server].name, @errorName(err) });
            break :answer null;
        };
        const reply = r.gpa.create(Request) catch return pending.deinit(r.gpa);
        reply.* = .{ .kind = .{ .answer = .{ .pending = pending, .json = null } }, .alloc = r.gpa, .owned = true };
        if (answer) |text| reply.kind.answer.json = r.gpa.dupe(u8, text) catch null;
        r.post(reply) catch r.finish(reply, .ok);
    }

    fn post(r: *Runtime, req: *Request) Error!void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.stopping) return error.Stopped;
        try r.queue.append(r.gpa, req);
        r.engine.wake();
    }

    // ---- the owner thread ----

    fn run(r: *Runtime) void {
        while (true) {
            const stopping = r.drain();
            r.flush();
            if (stopping) break;
            const event = r.engine.next(r.waitMs()) catch |err| {
                debug_trace.logf("mcp", "MCP engine step failed err={s}", .{@errorName(err)});
                std.Io.sleep(r.io, .fromMilliseconds(50), .awake) catch {};
                continue;
            };
            if (event) |e| r.onEvent(e) catch |err| {
                debug_trace.logf("mcp", "MCP event handling failed server={s} err={s}", .{ e.server, @errorName(err) });
            };
            r.expireLogins();
            r.endLogouts();
            r.retryRefreshes();
            r.flush();
        }
        r.shutdown();
    }

    /// Publishes the snapshot, then wakes the requests finished before it.
    fn flush(r: *Runtime) void {
        r.publish() catch |err| debug_trace.logf("mcp", "MCP status not published err={s}", .{@errorName(err)});
        for (r.finished.items) |req| req.done.set(r.io);
        r.finished.clearRetainingCapacity();
    }

    /// Takes the queued requests and handles them; true once stopping.
    fn drain(r: *Runtime) bool {
        r.mutex.lockUncancelable(r.io);
        const stopping = r.stopping;
        var taken = r.queue;
        r.queue = .empty;
        if (!stopping and r.waitsForRetired()) {
            // A retired runtime's servers are still stopping: what could
            // start a server waits, in order.
            var kept: usize = 0;
            for (taken.items) |req| {
                if (req.kind.mayStart()) held: {
                    r.queue.append(r.gpa, req) catch break :held; // out of memory: handled now
                    continue;
                }
                taken.items[kept] = req;
                kept += 1;
            }
            taken.shrinkRetainingCapacity(kept);
        }
        r.mutex.unlock(r.io);
        defer taken.deinit(r.gpa);
        for (taken.items) |req| {
            if (stopping) {
                r.finish(req, .{ .failed = error.Stopped });
                continue;
            }
            r.handle(req) catch |err| {
                debug_trace.logf("mcp", "MCP request failed kind={s} err={s}", .{ @tagName(req.kind), @errorName(err) });
                r.finish(req, .{ .failed = if (err == error.OutOfMemory) error.OutOfMemory else error.Failed });
            };
        }
        return stopping;
    }

    fn handle(r: *Runtime, req: *Request) !void {
        switch (req.kind) {
            .tools => |name| {
                const i = r.serverIndex(name) orelse return r.finish(req, .{ .tools = .unknown_server });
                if (r.heldReason(req.alloc, i)) |why| return r.finish(req, .{ .tools = .{ .failed = try why } });
                if (r.flags[i].needs_login and r.loginFor(i) == null and !try r.pickUpLogin(i)) return r.finish(req, .{ .tools = .needs_login });
                if (r.enginePhase(i) == .backoff) {
                    try r.engine.needTools(r.resolved.servers[i].name);
                    return r.finish(req, .{ .tools = .{ .failed = try req.alloc.dupe(u8, r.lastError(i) orelse "the server is unavailable") } });
                }
                try r.tool_waiters.ensureUnusedCapacity(r.gpa, 1);
                try r.engine.needTools(r.resolved.servers[i].name);
                r.tool_waiters.appendAssumeCapacity(.{ .server = i, .request = req });
            },
            .pick_up => {
                for (r.flags, 0..) |f, i| if (f.needs_login) {
                    _ = try r.pickUpLogin(i);
                };
                r.finish(req, .ok);
            },
            .need => |i| {
                if (r.resolved.servers[i].held == null) r.engine.needTools(r.resolved.servers[i].name) catch |err| {
                    debug_trace.logf("mcp", "MCP tool list not started server={s} err={s}", .{ r.resolved.servers[i].name, @errorName(err) });
                };
                r.finish(req, .ok);
            },
            .call => |c| {
                const i = r.serverIndex(c.server) orelse return r.finish(req, .{ .call = .unknown_server });
                if (r.resolved.servers[i].held != null) return r.finish(req, .{ .failed = error.Held });
                if (r.flags[i].needs_login) _ = try r.pickUpLogin(i);
                // Room first: a call the engine took must have its waiter.
                try r.calls.ensureUnusedCapacity(r.gpa, 1);
                const handle_ = try r.engine.call(r.resolved.servers[i].name, c.tool, c.arguments);
                if (req.observation) |call_| call_.engineRequest(handle_);
                r.calls.putAssumeCapacity(handle_, req);
            },
            .cancel => |target| {
                var it = r.calls.iterator();
                while (it.next()) |entry| if (entry.value_ptr.* == target) {
                    try r.engine.cancel(entry.key_ptr.*);
                    break;
                };
                // A tools waiter just stops waiting; the list still arrives.
                for (r.tool_waiters.items, 0..) |w, k| if (w.request == target) {
                    _ = r.tool_waiters.swapRemove(k);
                    r.finish(target, .{ .failed = error.Cancelled });
                    break;
                };
                // A logout is done locally; only the wait for the revocation stops.
                for (r.logouts.items, 0..) |l, k| if (l.request == target) {
                    _ = r.logouts.swapRemove(k);
                    r.finish(target, .ok);
                    break;
                };
                r.finish(req, .ok);
            },
            .login => |l| try r.startLogin(req, l.server, l.open_browser),
            .finish_login => |f| {
                const i = r.engineServer(f.server) orelse return r.finish(req, .{ .failed = error.UnknownServer });
                const l = r.loginFor(i) orelse return r.finish(req, .{ .failed = error.NotSigningIn });
                const url = req.owned_url orelse try r.gpa.dupe(u8, f.url);
                req.owned_url = null;
                if (l.callback) |old| r.gpa.free(old);
                l.callback = url;
                try r.engine.finishSignIn(r.resolved.servers[i].name, url);
                r.finish(req, .ok);
            },
            .answer => |a| {
                // `finish` frees the pending question and the answer.
                defer r.finish(req, .ok);
                const name = r.resolved.servers[a.pending.server].name;
                var scratch: std.heap.ArenaAllocator = .init(r.gpa);
                defer scratch.deinit();
                switch (a.pending.reply) {
                    .input => |input| {
                        const values = if (a.json) |json| inputValues(scratch.allocator(), json, input.keys) else null;
                        if (values) |v| r.engine.respond(input.call, v) catch |err| {
                            debug_trace.logf("mcp", "MCP answer not sent server={s} err={s}", .{ name, @errorName(err) });
                        } else {
                            if (r.calls.get(input.call)) |asking| asking.declined = true;
                            r.engine.cancel(input.call) catch {};
                        }
                    },
                    .elicit => |id| {
                        const answer = elicitAnswer(scratch.allocator(), a.json) orelse mcp.elicitation.Answer{ .action = .decline };
                        r.engine.answerElicitation(name, id, answer) catch |err| {
                            debug_trace.logf("mcp", "MCP elicitation answer not sent server={s} err={s}", .{ name, @errorName(err) });
                        };
                    },
                }
            },
            .logout => |name| {
                const i = r.engineServer(name) orelse return r.finish(req, .{ .failed = error.UnknownServer });
                const s = r.resolved.servers[i];
                if (s.transport != .http) return r.finish(req, .{ .failed = error.NotHttp });
                // The saved login goes first: a store that can't be read leaves
                // the session signed in rather than half signed out.
                _ = r.options.credentials.remove(r.gpa, s.credentialKey()) catch |err| switch (err) {
                    error.CredentialStoreUnreadable => return r.finish(req, .{ .failed = error.CredentialStoreUnreadable }),
                    else => debug_trace.logf("mcp", "MCP credential not removed server={s} err={s}", .{ s.name, @errorName(err) }),
                };
                try r.engine.signOut(s.name);
                r.flags[i] = .{};
                // A program that exits next would lose a revocation still on
                // its way, so the logout ends when it's answered.
                if (!r.engine.revoking(s.name)) return r.finish(req, .ok);
                try r.logouts.append(r.gpa, .{ .server = i, .request = req, .deadline_ms = r.nowMs() + revoke_wait_ms });
            },
        }
    }

    fn startLogin(r: *Runtime, req: *Request, name: []const u8, open_browser: bool) !void {
        const i = r.engineServer(name) orelse return r.finish(req, .{ .failed = if (r.serverIndex(name) == null) error.UnknownServer else error.Held });
        const s = r.resolved.servers[i];
        if (s.transport != .http) return r.finish(req, .{ .failed = error.NotHttp });
        // A sign-in that couldn't be saved would last only this session.
        r.options.credentials.check(r.gpa) catch |err| switch (err) {
            error.CredentialStoreUnreadable => return r.finish(req, .{ .failed = error.CredentialStoreUnreadable }),
            else => debug_trace.logf("mcp", "MCP credential store not checked server={s} err={s}", .{ s.name, @errorName(err) }),
        };
        r.endLogin(i);
        var listener = loopback.Listener.open(r.io, s.callback_port) catch |err| switch (err) {
            error.AddressInUse => return r.finish(req, .{ .failed = error.CallbackPortInUse }),
            else => return err,
        };
        const l = r.gpa.create(Login) catch |err| {
            listener.close(r.io);
            return err;
        };
        l.* = .{
            .runtime = r,
            .server = i,
            .listener = listener,
            .deadline_ms = r.nowMs() + login_timeout_ms,
            .open_browser = open_browser,
        };
        l.listener.localhost = s.slack_app;
        r.logins.append(r.gpa, l) catch |err| {
            l.listener.close(r.io);
            r.gpa.destroy(l);
            return err;
        };
        l.group.concurrent(r.io, awaitBrowser, .{l}) catch |err| {
            _ = r.logins.pop();
            l.listener.close(r.io);
            r.gpa.destroy(l);
            return err;
        };
        var buffer: [64]u8 = undefined;
        r.engine.signIn(s.name, l.listener.redirectUri(&buffer)) catch |err| {
            r.endLogin(i);
            return err;
        };
        r.finish(req, .ok);
    }

    /// The login task: waits for the browser, then hands its address to the owner.
    fn awaitBrowser(l: *Login) std.Io.Cancelable!void {
        const r = l.runtime;
        const url = l.listener.accept(r.io, r.gpa) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                debug_trace.logf("mcp", "MCP login listener failed server={s} err={s}", .{ r.resolved.servers[l.server].name, @errorName(err) });
                return;
            },
        };
        const req = r.gpa.create(Request) catch {
            r.gpa.free(url);
            return;
        };
        req.* = .{
            .kind = .{ .finish_login = .{ .server = r.resolved.servers[l.server].name, .url = url } },
            .alloc = r.gpa,
            .owned = true,
            .owned_url = url,
        };
        r.post(req) catch {
            r.gpa.free(url);
            r.gpa.destroy(req);
        };
    }

    fn loginFor(r: *const Runtime, server: usize) ?*Login {
        for (r.logins.items) |l| if (l.server == server) return l;
        return null;
    }

    fn endLogin(r: *Runtime, server: usize) void {
        for (r.logins.items, 0..) |l, k| if (l.server == server) {
            l.group.cancel(r.io);
            l.listener.close(r.io);
            if (l.callback) |url| r.gpa.free(url);
            r.gpa.destroy(l);
            _ = r.logins.swapRemove(k);
            return;
        };
    }

    fn expireLogins(r: *Runtime) void {
        const now = r.nowMs();
        var k: usize = 0;
        while (k < r.logins.items.len) {
            const l = r.logins.items[k];
            if (l.deadline_ms > now) {
                k += 1;
                continue;
            }
            const name = r.resolved.servers[l.server].name;
            r.engine.cancelSignIn(name) catch {};
            r.notify(.{ .sign_in_failed = .{ .server = name, .reason = "the browser didn't come back within 5 minutes" } });
            r.endLogin(l.server);
        }
    }

    /// Logouts whose revocation was answered, or waited for long enough.
    fn endLogouts(r: *Runtime) void {
        const now = r.nowMs();
        var k: usize = 0;
        while (k < r.logouts.items.len) {
            const l = r.logouts.items[k];
            if (l.deadline_ms > now and r.engine.revoking(r.resolved.servers[l.server].name)) {
                k += 1;
                continue;
            }
            _ = r.logouts.swapRemove(k);
            r.finish(l.request, .ok);
        }
    }

    fn onEvent(r: *Runtime, event: engine.Event) !void {
        const i = r.serverIndex(event.server) orelse return;
        switch (event.kind) {
            // A failed attempt ends the waits for tools with its reason; the
            // engine keeps trying, so a later request may still get them.
            .phase => |phase| if (phase == .backoff or phase == .failed) r.endToolWaiters(i, .failed),
            .called => |c| {
                const entry = r.calls.fetchRemove(c.call) orelse return;
                const req = entry.value;
                var result = copyCall(req.alloc, c) catch |err| return r.finish(req, .{ .failed = err });
                if (req.declined and result == .ended and result.ended.outcome == .cancelled) result.ended.outcome = .unsupported_input;
                r.finish(req, .{ .call = result });
            },
            .input => |q| {
                const req = r.calls.get(q.call) orelse return r.engine.cancel(q.call);
                if (req.asker == null) {
                    debug_trace.logf("mcp", "MCP input request declined server={s} reason=no question UI", .{event.server});
                    req.declined = true;
                    return r.engine.cancel(q.call);
                }
                var pending = r.inputQuestion(i, q.call, q.requests) catch |err| {
                    try r.engine.cancel(q.call);
                    return err;
                };
                if (!r.offer(req, pending)) {
                    pending.deinit(r.gpa);
                    req.declined = true;
                    try r.engine.cancel(q.call);
                }
            },
            .server => |s| try r.onServer(i, event.server, s),
        }
    }

    fn onServer(r: *Runtime, i: usize, name: []const u8, event: mcp.server.Event) !void {
        switch (event) {
            .tools => |t| {
                var k: usize = 0;
                while (k < r.tool_waiters.items.len) {
                    const w = r.tool_waiters.items[k];
                    if (w.server != i) {
                        k += 1;
                        continue;
                    }
                    _ = r.tool_waiters.swapRemove(k);
                    const result: Allocator.Error!ToolsResult = if (t.ok)
                        if (r.copyTools(w.request.alloc, name)) |list| .{ .tools = list } else |err| err
                    else if (t.needs_auth)
                        .needs_login
                    else if (w.request.alloc.dupe(u8, r.lastError(i) orelse "the server is unavailable")) |why| .{ .failed = why } else |err| err;
                    r.finish(w.request, if (result) |ok| .{ .tools = ok } else |err| .{ .failed = err });
                }
            },
            .auth_required => {
                r.flags[i].needs_login = true;
                r.notify(.{ .needs_login = name });
                // Nothing comes until someone logs in.
                r.endToolWaiters(i, .needs_login);
            },
            .authorize => |authorize| {
                r.notify(.{ .authorize = .{ .server = name, .url = authorize } });
                for (r.logins.items) |l| if (l.server == i) {
                    // Only a return carrying this sign-in's state ends its wait.
                    l.listener.expect(r.io, authorize);
                    if (!l.open_browser) continue;
                    // The URL went out in the notice either way.
                    const opened = url_opener.native_opener.open(r.gpa, authorize) catch false;
                    if (!opened) debug_trace.logf("mcp", "browser not opened for MCP login server={s}", .{name});
                };
            },
            .signed_in => {
                r.flags[i] = .{ .signed_in = true };
                r.endLogin(i);
                r.notify(.{ .signed_in = name });
            },
            .sign_in_failed => |f| {
                // The message can point into the callback address the login
                // holds, so it is put in words before the login goes.
                var buffer: [512]u8 = undefined;
                const reason = signInFailure(&buffer, f.why, f.message);
                r.endLogin(i);
                r.notify(.{ .sign_in_failed = .{ .server = name, .reason = reason } });
            },
            .credential => try r.saveCredential(i),
            .refresh_due => try r.refreshDue(i),
            .refresh_ended => r.endRefresh(i),
            .elicit => |x| {
                const decline: mcp.elicitation.Answer = .{ .action = .decline };
                const req = r.callAsking(name) orelse {
                    debug_trace.logf("mcp", "MCP elicitation declined server={s} reason=no call can ask", .{name});
                    return r.engine.answerElicitation(name, x.id, decline);
                };
                const json = try r.gpa.print("{{\"elicitation\":{{\"method\":\"elicitation/create\",\"params\":{s}}}}}", .{x.params});
                var pending: Pending = .{ .server = i, .json = json, .version = r.versionCopy(i), .reply = .{ .elicit = x.id } };
                if (!r.offer(req, pending)) {
                    pending.deinit(r.gpa);
                    return r.engine.answerElicitation(name, x.id, decline);
                }
                try r.holdUrl(i, x.id.slot, x.params);
            },
            .elicitation_complete => |slot| r.endUrl(i, slot, true),
            .elicit_withdrawn => |slot| {
                r.dropWithdrawn(i, slot);
                r.endUrl(i, slot, false);
            },
            else => {},
        }
    }

    /// The server withdrew its 2025 question in `slot`: one no call has shown
    /// yet is never shown. One on screen stays, and its answer is refused.
    fn dropWithdrawn(r: *Runtime, i: usize, slot: u8) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        var it = r.calls.valueIterator();
        while (it.next()) |req| if (req.*.question) |*q| {
            if (q.server != i or q.reply != .elicit or q.reply.elicit.slot != slot) continue;
            debug_trace.logf("mcp", "MCP question dropped server={s} reason=withdrawn before it was shown", .{r.resolved.servers[i].name});
            q.deinit(r.gpa);
            req.*.question = null;
            return;
        };
    }

    /// Keeps a 2025 URL question's id, which its completion names.
    fn holdUrl(r: *Runtime, i: usize, slot: u8, params: []const u8) !void {
        if (r.options.url_completions == null) return;
        var form: mcp.elicitation.Form = .{};
        const request = mcp.elicitation.parse(params, &form) catch return;
        const raw = request.elicitation_id orelse return;
        const parsed = std.json.parseFromSlice([]const u8, r.gpa, raw, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer parsed.deinit();
        const id = try r.gpa.dupe(u8, parsed.value);
        errdefer r.gpa.free(id);
        // A slot used again holds a new question.
        r.endUrl(i, slot, false);
        try r.url_questions.append(r.gpa, .{ .server = i, .slot = slot, .id = id });
    }

    /// The server completed or withdrew the URL question in `slot`.
    fn endUrl(r: *Runtime, i: usize, slot: u8, completed: bool) void {
        for (r.url_questions.items, 0..) |q, k| if (q.server == i and q.slot == slot) {
            _ = r.url_questions.swapRemove(k);
            defer r.gpa.free(q.id);
            if (completed) if (r.options.url_completions) |sink| sink.complete(.{
                .server_name = r.resolved.servers[i].name,
                .elicitation_id = q.id,
                .connection_generation = 0,
                .client_generation = 0,
                .auth_generation = 0,
            });
            return;
        };
    }

    fn saveCredential(r: *Runtime, i: usize) !void {
        const s = r.resolved.servers[i];
        if (s.url == null) return;
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer {
            std.crypto.secureZero(u8, out.writer.buffer);
            out.deinit();
        }
        if (try r.engine.saveCredential(s.name, &out.writer)) {
            if (r.options.credentials.put(r.gpa, s.credentialKey(), out.written())) {
                // Only a saved login is this process's own; one that wasn't
                // leaves the store's as it was, for a refusal to remove.
                r.flags[i].tried = credentials.digest(out.written());
                r.flags[i].not_saved = false;
            } else |err| {
                debug_trace.logf("mcp", "MCP credential not saved server={s} err={s}", .{ s.name, @errorName(err) });
                if (r.flags[i].not_saved) return;
                r.flags[i].not_saved = true;
                var buf: [320]u8 = undefined;
                r.notify(.{ .not_saved = .{ .server = s.name, .reason = notSavedReason(&buf, r.options.credentials, err) } });
            }
        } else if (r.flags[i].tried) |own| {
            // Only this process's own login goes: one another fx saved since
            // stays, for the next request to take.
            _ = r.options.credentials.removeIfSame(r.gpa, s.credentialKey(), own) catch |err| {
                debug_trace.logf("mcp", "MCP credential not removed server={s} err={s}", .{ s.name, @errorName(err) });
            };
        }
    }

    fn shutdown(r: *Runtime) void {
        while (r.logins.items.len > 0) {
            // Only a config change ends a host while it signs in: the
            // shell's "Signing in" clears, and it says why.
            const server = r.logins.items[0].server;
            const name = r.resolved.servers[server].name;
            var buf: [320]u8 = undefined;
            const reason = std.mem.print(&buf, "the MCP config changed before the browser came back; run /mcp login {s} again", .{name}) catch
                "the MCP config changed before the browser came back; sign in again";
            r.notify(.{ .sign_in_failed = .{ .server = name, .reason = reason } });
            r.endLogin(server);
        }
        var it = r.calls.valueIterator();
        while (it.next()) |req| r.finish(req.*, .{ .failed = error.Stopped });
        r.calls.clearRetainingCapacity();
        for (r.tool_waiters.items) |w| r.finish(w.request, .{ .failed = error.Stopped });
        r.tool_waiters.clearRetainingCapacity();
        for (r.logouts.items) |l| r.finish(l.request, .ok);
        r.logouts.clearRetainingCapacity();
        for (r.refreshes.items) |*f| if (f.lock) |*l| l.release();
        r.refreshes.clearRetainingCapacity();
        // Requests queued after the last drain.
        _ = r.drain();
        r.flush();
        r.engine.deinit();
    }

    /// Rebuilds the status snapshot from the engine.
    fn publish(r: *Runtime) Allocator.Error!void {
        var next_arena: std.heap.ArenaAllocator = .init(r.gpa);
        errdefer next_arena.deinit();
        const a = next_arena.allocator();
        const out = try a.alloc(Status, r.resolved.servers.len);
        for (r.resolved.servers, out, 0..) |s, *o, i| {
            o.* = .{ .name = s.name, .source = s.source, .transport = s.transport, .state = .idle, .missing = s.missing };
            if (s.held) |h| {
                o.state = switch (h) {
                    .disabled => .disabled,
                    .waiting_for_approval => .waiting_for_approval,
                    .rejected => .rejected,
                    .unsupported => .unsupported,
                    .missing_env => .missing_env,
                    .invalid_env => .invalid_env,
                };
                continue;
            }
            const k = std.mem.findScalar(usize, r.resolved.engine_server, i).?;
            const st = r.engine.status(k);
            o.state = switch (st.phase) {
                .idle => .idle,
                .connecting => .connecting,
                .ready => .ready,
                .backoff => .retrying,
                .failed => .failed,
            };
            o.version = if (st.version) |v| try a.dupe(u8, v) else null;
            o.tools = st.tools;
            // The engine keeps its last failure; it explains a server that is
            // down, not one that is back or stopped to wait for a sign-in.
            o.last_error = switch (o.state) {
                .failed, .retrying => if (st.last_error) |e| try a.dupe(u8, describeFailure(e)) else null,
                else => null,
            };
            o.needs_login = r.flags[i].needs_login;
            o.signed_in = r.flags[i].signed_in;
            if (r.engine.instructions(s.name)) |t| o.instructions = try a.dupe(u8, t);
        }
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.snapshot_arena.deinit();
        r.snapshot_arena = next_arena;
        r.snapshot = out;
    }

    fn waitMs(r: *const Runtime) u32 {
        var wait: i64 = idle_wait_ms;
        const now = r.nowMs();
        for (r.logins.items) |l| wait = @min(wait, @max(0, l.deadline_ms - now));
        for (r.logouts.items) |l| wait = @min(wait, @max(0, l.deadline_ms - now));
        for (r.refreshes.items) |f| if (!f.sent) {
            wait = @min(wait, refresh_retry_ms);
        };
        if (r.waitsForRetired()) wait = @min(wait, retiring_wait_ms);
        return @intCast(wait);
    }

    fn nowMs(r: *const Runtime) i64 {
        return std.Io.Clock.awake.now(r.io).toMilliseconds();
    }

    /// Hands `result` to the waiting caller, or frees a request the owner posted.
    fn finish(r: *Runtime, req: *Request, result: Request.Outcome) void {
        if (req.owned) {
            if (req.owned_url) |url| r.gpa.free(url);
            switch (req.kind) {
                .answer => |*a| {
                    a.pending.deinit(r.gpa);
                    if (a.json) |json| r.gpa.free(json);
                },
                else => {},
            }
            return r.gpa.destroy(req);
        }
        // A question the caller hadn't taken goes with the call.
        r.mutex.lockUncancelable(r.io);
        var question = req.question;
        req.question = null;
        r.mutex.unlock(r.io);
        if (question) |*p| p.deinit(r.gpa);
        req.result = result;
        r.finished.append(r.gpa, req) catch req.done.set(r.io);
    }

    /// Leaves `pending` for the call's thread to ask; false when one waits.
    fn offer(r: *Runtime, req: *Request, pending: Pending) bool {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (req.question != null) return false;
        req.question = pending;
        return true;
    }

    /// A call on server `name` that can ask the user and isn't asking yet.
    fn callAsking(r: *Runtime, name: []const u8) ?*Request {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        var it = r.calls.valueIterator();
        while (it.next()) |req| {
            if (req.*.asker == null or req.*.question != null) continue;
            if (std.mem.eql(u8, req.*.kind.call.server, name)) return req.*;
        }
        return null;
    }

    fn inputQuestion(r: *Runtime, i: usize, call_handle: engine.Handle, requests: []const mcp.mrtr.Request) Allocator.Error!Pending {
        const keys = try r.gpa.alloc([]u8, requests.len);
        var made: usize = 0;
        errdefer {
            for (keys[0..made]) |k| r.gpa.free(k);
            r.gpa.free(keys);
        }
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer out.deinit();
        // An allocating writer fails only when allocation does.
        out.writer.writeByte('{') catch return error.OutOfMemory;
        for (requests, keys, 0..) |request, *key, n| {
            key.* = try r.gpa.dupe(u8, request.key);
            made += 1;
            if (n > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
            out.writer.print("{s}:{s}", .{ request.key, request.raw }) catch return error.OutOfMemory;
        }
        out.writer.writeByte('}') catch return error.OutOfMemory;
        const json = try out.toOwnedSlice();
        return .{ .server = i, .json = json, .version = r.versionCopy(i), .reply = .{ .input = .{ .call = call_handle, .keys = keys } } };
    }

    fn versionCopy(r: *Runtime, i: usize) ?[]u8 {
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        const version = r.engine.status(k).version orelse return null;
        return r.gpa.dupe(u8, version) catch null;
    }

    fn notify(r: *Runtime, notice: Notice) void {
        if (r.options.notify) |n| n.notice(n.context, notice);
    }

    fn serverIndex(r: *const Runtime, name: []const u8) ?usize {
        for (r.resolved.servers, 0..) |s, i| if (std.mem.eql(u8, s.name, name)) return i;
        return null;
    }

    /// A server the engine runs, by name.
    fn engineServer(r: *const Runtime, name: []const u8) ?usize {
        const i = r.serverIndex(name) orelse return null;
        return if (r.resolved.servers[i].held == null) i else null;
    }

    /// Ends the waits for server `i`'s tools: with the reason it failed, or
    /// because it needs a login.
    fn endToolWaiters(r: *Runtime, i: usize, how: enum { failed, needs_login }) void {
        var k: usize = 0;
        while (k < r.tool_waiters.items.len) {
            const w = r.tool_waiters.items[k];
            if (w.server != i) {
                k += 1;
                continue;
            }
            _ = r.tool_waiters.swapRemove(k);
            if (how == .needs_login) {
                r.finish(w.request, .{ .tools = .needs_login });
                continue;
            }
            const why = w.request.alloc.dupe(u8, r.lastError(i) orelse "the server is unavailable");
            r.finish(w.request, if (why) |text| .{ .tools = .{ .failed = text } } else |err| .{ .failed = err });
        }
    }

    fn enginePhase(r: *const Runtime, i: usize) ?engine.Phase {
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        return r.engine.status(k).phase;
    }

    fn lastError(r: *const Runtime, i: usize) ?[]const u8 {
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        return describeFailure(r.engine.status(k).last_error orelse return null);
    }

    /// Why a held-back server has no tools, in `alloc`; null when the engine runs it.
    fn heldReason(r: *const Runtime, alloc: Allocator, i: usize) ?Allocator.Error![]u8 {
        const s = r.resolved.servers[i];
        const held = s.held orelse return null;
        return switch (held) {
            .disabled => alloc.dupe(u8, "the server is disabled"),
            .waiting_for_approval => alloc.dupe(u8, "the project server is waiting for approval"),
            .rejected => alloc.dupe(u8, "the project server was rejected"),
            .unsupported => alloc.dupe(u8, if (s.transport == .sse)
                "HTTP+SSE servers are not supported"
            else
                "servers of \"type\": \"acp\" are not supported: ACP v1 defines stdio, HTTP, and SSE"),
            .missing_env => alloc.print("{s} is not set", .{s.missing orelse "a variable"}),
            .invalid_env => alloc.print("{s} holds a line break or another character a header can't carry", .{s.missing orelse "a variable"}),
        };
    }

    fn copyTools(r: *Runtime, alloc: Allocator, name: []const u8) Allocator.Error![]Tool {
        const list = r.engine.toolList(name) catch return &.{};
        const out = try alloc.alloc(Tool, list.len());
        for (out, 0..) |*t, k| {
            const tool = list.get(k);
            t.* = .{ .name = try alloc.dupe(u8, tool.name), .raw = try alloc.dupe(u8, tool.raw) };
        }
        return out;
    }

    /// A login saved since by another fx, taken in place of asking for one;
    /// true when server `i` took it. One already had or tried is skipped,
    /// and so is a server signing in here.
    fn pickUpLogin(r: *Runtime, i: usize) !bool {
        const s = r.resolved.servers[i];
        if (s.transport != .http or s.held != null or r.loginFor(i) != null) return false;
        if (!try r.takeSaved(i)) return false;
        r.flags[i].needs_login = false;
        r.flags[i].signed_in = true;
        debug_trace.logf("mcp", "MCP login saved by another fx taken server={s}", .{s.name});
        r.notify(.{ .signed_in = s.name });
        return true;
    }

    /// Server `i`'s refresh is due. One left over, whose end was
    /// dropped, goes first: a server refreshes once at a time.
    fn refreshDue(r: *Runtime, i: usize) !void {
        r.endRefresh(i);
        try r.refreshes.append(r.gpa, .{ .server = i, .deadline_ms = r.nowMs() + refresh_lock_wait_ms });
        try r.tryRefresh(&r.refreshes.items[r.refreshes.items.len - 1]);
    }

    /// Under the login's refresh lock, one fx refreshes it at a time: this one
    /// takes the login another fx saved meanwhile, or refreshes its own.
    /// Waiting too long, or without the lock at all, it refreshes anyway.
    fn tryRefresh(r: *Runtime, f: *Refresh) !void {
        const s = r.resolved.servers[f.server];
        if (r.options.credentials.tryRefreshLock(s.credentialKey())) |maybe| {
            if (maybe) |lock| {
                f.lock = lock;
            } else if (r.nowMs() < f.deadline_ms) {
                return;
            } else debug_trace.logf("mcp", "MCP refresh went ahead server={s} reason=another fx held its refresh lock too long", .{s.name});
        } else |err| debug_trace.logf("mcp", "MCP refresh went ahead server={s} reason=no refresh lock err={s}", .{ s.name, @errorName(err) });
        f.sent = true;
        if (try r.takeSaved(f.server)) debug_trace.logf("mcp", "MCP refresh replaced server={s} reason=another fx refreshed", .{s.name});
        // Nothing goes out once a saved login replaced the refresh.
        try r.engine.refresh(s.name);
    }

    fn retryRefreshes(r: *Runtime) void {
        for (r.refreshes.items) |*f| if (!f.sent) r.tryRefresh(f) catch |err| {
            debug_trace.logf("mcp", "MCP refresh not started server={s} err={s}", .{ r.resolved.servers[f.server].name, @errorName(err) });
        };
    }

    /// Server `i`'s refresh ended, or a sign-in or sign-out replaced it.
    fn endRefresh(r: *Runtime, i: usize) void {
        for (r.refreshes.items, 0..) |*f, k| if (f.server == i) {
            if (f.lock) |*l| l.release();
            _ = r.refreshes.swapRemove(k);
            return;
        };
    }

    /// The login another fx saved under server `i`'s key, given to it; false
    /// when there is none, or it's one `i` had or tried already.
    fn takeSaved(r: *Runtime, i: usize) !bool {
        const s = r.resolved.servers[i];
        const saved = r.options.credentials.get(r.gpa, s.credentialKey()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                return false;
            },
        } orelse return false;
        defer secret.zeroAndFree(r.gpa, saved);
        const digest = credentials.digest(saved);
        if (r.flags[i].tried) |tried| if (std.mem.eql(u8, &tried, &digest)) return false;
        r.flags[i].tried = digest;
        try r.engine.useCredential(s.name, saved);
        return true;
    }

    fn savedCredential(context: *anyopaque, alloc: Allocator, key: credentials.Key) Allocator.Error!?[]u8 {
        const r: *Runtime = @ptrCast(@alignCast(context));
        const found = r.options.credentials.get(r.gpa, key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("mcp", "MCP credential not loaded server={s} err={s}", .{ key.name, @errorName(err) });
                return null;
            },
        } orelse return null;
        defer secret.zeroAndFree(r.gpa, found);
        return try alloc.dupe(u8, found);
    }

    /// Permission is fx's tool admission, before the call reaches the
    /// runtime, and only the runtime calls the engine.
    fn allow(_: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) bool {
        return true;
    }

    fn log(_: *anyopaque, server: []const u8, line: []const u8) void {
        debug_trace.logf("mcp", "MCP server stderr server={s} line={s}", .{ server, line[0..@min(line.len, 512)] });
    }
};

/// The client capabilities that declare `questions`.
fn declaredCapabilities(questions: elicitation.Capabilities) []const u8 {
    if (questions.form and questions.url) return "{\"elicitation\":{\"form\":{},\"url\":{}}}";
    if (questions.form) return "{\"elicitation\":{\"form\":{}}}";
    if (questions.url) return "{\"elicitation\":{\"url\":{}}}";
    return "{}";
}

/// MCP-v2 names why a server is down; fx says it in words. Anything else,
/// such as an HTTP failure's own text, is shown as it is.
/// Why a new login wasn't saved, in words.
fn notSavedReason(buffer: []u8, store: credentials.Store, err: anyerror) []const u8 {
    const why: []const u8 = switch (err) {
        error.CredentialStoreUnreadable => "a newer fx saved it, or it's damaged",
        error.LockBusy => "another fx kept it busy",
        else => @errorName(err),
    };
    return std.mem.print(buffer, "{s} couldn't be written: {s}", .{ store.place(), why }) catch "the saved MCP sign-ins couldn't be written";
}

/// Why a sign-in failed, in words, with the authorization server's own when
/// it gave some.
fn signInFailure(buffer: []u8, why: mcp.auth.client.Failure, message: ?[]const u8) []const u8 {
    const what = switch (why) {
        .discovery => "fx couldn't find how to sign in to it",
        .registration => "it didn't register fx as a client; set oauth.client_id for it in mcp.json",
        .response => "the sign-in page returned an error",
        .mismatch => "the answer that came back wasn't for this sign-in",
        .redemption => "it didn't accept the sign-in",
        .cancelled => "the sign-in was cancelled",
        .refused => "fx has tried to sign in to it too many times; restart fx to try again",
        .insecure_endpoint => "its sign-in server uses plain HTTP, not HTTPS",
        .internal_endpoint => "its sign-in server points at an internal address fx won't contact",
    };
    var said = std.mem.trimEnd(u8, message orelse return what, ". \t\r\n");
    if (said.len == 0) return what;
    // At most 300 bytes of it, never inside a character.
    if (said.len > 300) {
        var end: usize = 300;
        while (end > 0 and said[end] & 0xC0 == 0x80) end -= 1;
        said = said[0..end];
    }
    return std.mem.print(buffer, "{s} ({s})", .{ what, said }) catch what;
}

test "a failed sign-in says why in words, with the server's own" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("it didn't accept the sign-in (invalid_grant: The code expired)", signInFailure(&buffer, .redemption, "invalid_grant: The code expired."));
    try std.testing.expectEqualStrings("the sign-in was cancelled", signInFailure(&buffer, .cancelled, null));
    try std.testing.expectEqualStrings("it didn't register fx as a client; set oauth.client_id for it in mcp.json", signInFailure(&buffer, .registration, null));
    try std.testing.expectEqualStrings("the sign-in page returned an error", signInFailure(&buffer, .response, " . "));
    try std.testing.expectEqualStrings("the answer that came back wasn't for this sign-in", signInFailure(&buffer, .mismatch, null));
    const long = text_utils.repeat("\xc3\xa9", 200);
    const said = signInFailure(&buffer, .redemption, long);
    try std.testing.expect(std.unicode.utf8ValidateSlice(said));
    try std.testing.expect(said.len < 340);
}

fn describeFailure(why: []const u8) []const u8 {
    const known = [_]struct { []const u8, []const u8 }{
        .{ "no_shared_version", "it supports no MCP version fx speaks" },
        .{ "rejected", "it refused fx's MCP version" },
        .{ "went_quiet", "it stopped answering while starting" },
        .{ "unsupported_version", "it answered with an MCP version fx doesn't support (fx speaks 2025-03-26 and newer)" },
        .{ "initialize_failed", "it refused or never answered fx's initialize request" },
        .{ "session", "its session ended" },
        .{ "initialized_timed_out", "it never answered fx's initialized notification" },
        .{ "needs_auth", "it needs a login" },
        .{ "auth_unavailable", "its login couldn't be renewed: the sign-in server didn't answer; fx tries again" },
        .{ "process", "its process exited" },
        .{ "FileNotFound", "its command was not found" },
        .{ "AccessDenied", "its command could not be run (permission denied)" },
    };
    for (known) |entry| if (std.mem.eql(u8, entry[0], why)) return entry[1];
    return why;
}

/// The answers to a call's input requests, in the order of `keys` (JSON
/// string tokens); null when one is missing or the answers aren't an object.
fn inputValues(a: Allocator, json: []const u8, keys: []const []const u8) ?[]const []const u8 {
    const answers = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .parse_numbers = false }) catch return null;
    if (answers != .object) return null;
    const values = a.alloc([]const u8, keys.len) catch return null;
    for (keys, values) |token, *value| {
        const key = std.json.parseFromSliceLeaky([]const u8, a, token, .{}) catch return null;
        const answer = answers.object.get(key) orelse return null;
        value.* = std.json.Stringify.valueAlloc(a, answer, .{}) catch return null;
    }
    return values;
}

/// A 2025 elicitation's answer from fx's `inputResponses` object.
fn elicitAnswer(a: Allocator, json: ?[]const u8) ?mcp.elicitation.Answer {
    const answers = std.json.parseFromSliceLeaky(std.json.Value, a, json orelse return null, .{ .parse_numbers = false }) catch return null;
    if (answers != .object) return null;
    const reply = answers.object.get("elicitation") orelse return null;
    if (reply != .object) return null;
    const action_value = reply.object.get("action") orelse return null;
    if (action_value != .string) return null;
    const action = std.meta.stringToEnum(@FieldType(mcp.elicitation.Answer, "action"), action_value.string) orelse return null;
    const content = if (reply.object.get("content")) |c| std.json.Stringify.valueAlloc(a, c, .{}) catch return null else null;
    return .{ .action = action, .content = content };
}

fn copyCall(alloc: Allocator, c: anytype) Allocator.Error!CallResult {
    const answer = c.answer orelse return .{ .ended = .{ .outcome = c.outcome, .maybe_ran = c.maybe_ran, .timed_out = c.timed_out } };
    return switch (answer) {
        .result => |res| .{ .result = .{
            .content = try alloc.dupe(u8, res.content),
            .structured = if (res.structured) |s| try alloc.dupe(u8, s) else null,
            .is_error = res.is_error,
        } },
        .failure => |f| .{ .failure = .{ .code = f.code, .message = try alloc.dupe(u8, f.message) } },
        // An answer that isn't a result ended the call: say how the engine ended it.
        .input_required, .invalid => .{ .ended = .{
            .outcome = if (c.outcome == .result) .malformed else c.outcome,
            .maybe_ran = true,
            .timed_out = false,
        } },
    };
}

test {
    _ = config;
    _ = credentials;
    _ = loopback;
}

const testing = std.testing;

const Fixture = @import("fake_server.zig").Fixture;

test "tools and calls go through the owner thread, from several threads at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const listed = try r.tools(arena.allocator(), "fake", null);
    try testing.expectEqual(@as(usize, 1), listed.tools.len);
    try testing.expectEqualStrings("echo", listed.tools[0].name);
    const status = (try r.statuses(arena.allocator()))[0];
    try testing.expectEqual(State.ready, status.state);
    try testing.expectEqualStrings("2025-11-25", status.version.?);
    try testing.expectEqual(@as(usize, 1), status.tools);

    const Caller = struct {
        fn run(runtime: *Runtime, ok: *std.atomic.Value(u32)) void {
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            const result = runtime.call(a.allocator(), "fake", "echo", "{}", null, null) catch return;
            if (result == .result and std.mem.find(u8, result.result.content, "hi") != null) _ = ok.fetchAdd(1, .acq_rel);
        }
    };
    var ok: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Caller.run, .{ &r, &ok });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 4), ok.load(.acquire));
}

test "a cancelled call ends, and stopping ends a call that never answers" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    var stopped = false;
    defer if (!stopped) r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Canceller = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
            flag.store(true, .release);
        }
    };
    var cancel: std.atomic.Value(bool) = .init(false);
    const canceller = try std.Thread.spawn(.{}, Canceller.run, .{&cancel});
    const cancelled = try r.call(arena.allocator(), "fake", "echo", "{\"text\":\"slow\"}", &cancel, null);
    canceller.join();
    try testing.expectEqual(engine.Outcome.cancelled, cancelled.ended.outcome);

    const Waiter = struct {
        fn run(runtime: *Runtime, got: *?Error) void {
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            _ = runtime.call(a.allocator(), "fake", "echo", "{\"text\":\"slow\"}", null, null) catch |err| {
                got.* = err;
            };
        }
    };
    var got: ?Error = null;
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ &r, &got });
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
    r.deinit();
    stopped = true;
    waiter.join();
    try testing.expectEqual(@as(?Error, error.Stopped), got);
}

test "while a retired host's servers stop, nothing starts a server, and a cancel still gets through" {
    waitRetired();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{
        .{ .name = "fake", .command = f.server },
        .{ .name = "late", .command = f.server },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try r.tools(a, "fake", null);

    const Caller = struct {
        fn call(runtime: *Runtime, cancel: *std.atomic.Value(bool), out: *?engine.Outcome) void {
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            const result = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"slow\"}", cancel, null) catch return;
            if (result == .ended) out.* = result.ended.outcome;
        }
        fn list(runtime: *Runtime, done: *std.atomic.Value(bool)) void {
            var la: std.heap.ArenaAllocator = .init(testing.allocator);
            defer la.deinit();
            const listed = runtime.tools(la.allocator(), "late", null) catch return;
            if (listed == .tools and listed.tools.len == 1) done.store(true, .release);
        }
    };
    var cancel: std.atomic.Value(bool) = .init(false);
    var outcome: ?engine.Outcome = null;
    const caller = try std.Thread.spawn(.{}, Caller.call, .{ &r, &cancel, &outcome });
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};

    retireStarted();
    var holding = true;
    defer if (holding) retireEnded();
    var listed: std.atomic.Value(bool) = .init(false);
    const lister = try std.Thread.spawn(.{}, Caller.list, .{ &r, &listed });
    // A cancel can't start a server, so it isn't held.
    cancel.store(true, .release);
    caller.join();
    try testing.expectEqual(@as(?engine.Outcome, .cancelled), outcome);
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
    try testing.expect(!listed.load(.acquire));
    try testing.expectEqual(State.idle, (try r.statuses(a))[1].state);

    retireEnded();
    holding = false;
    const ended_ms = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    while ((try r.statuses(a))[1].state == .idle) std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
    // Looked at again within 50 ms, not at the next idle wake a second later.
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - ended_ms < 500);
    lister.join();
    try testing.expect(listed.load(.acquire));
}

test "a replaced runtime still in use serves its calls, and holds the others until it's gone" {
    waitRetired();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var old: Runtime = undefined;
    try old.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    var old_up = true;
    defer if (old_up) old.deinit();
    var next: Runtime = undefined;
    try next.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer next.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    old.retire();
    // What began on the old one finishes there, so its last user can let go.
    try testing.expectEqual(@as(usize, 1), (try old.tools(a, "fake", null)).tools.len);

    const Lister = struct {
        fn run(runtime: *Runtime, done: *std.atomic.Value(bool)) void {
            var la: std.heap.ArenaAllocator = .init(testing.allocator);
            defer la.deinit();
            const listed = runtime.tools(la.allocator(), "fake", null) catch return;
            if (listed == .tools and listed.tools.len == 1) done.store(true, .release);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const lister = try std.Thread.spawn(.{}, Lister.run, .{ &next, &done });
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};
    try testing.expect(!done.load(.acquire));
    try testing.expectEqual(State.idle, (try next.statuses(a))[0].state);

    old.deinit();
    old_up = false;
    lister.join();
    try testing.expect(done.load(.acquire));
}

test "an answer to a withdrawn 2025 question reaches no one, and the next question gets its own" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.questions = .{ .form = true };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();

    // The user answers whichever question is on screen, naming it. Q1 is
    // withdrawn, so its answer is refused if it was shown in time, and it
    // is never shown if the withdrawal came first.
    const User = struct {
        fn ask(_: *anyopaque, alloc: Allocator, question: Question) anyerror!?[]u8 {
            const which = if (std.mem.find(u8, question.input_requests_json, "\"Q2\"") != null) "Q2" else "Q1";
            return try alloc.print("{{\"elicitation\":{{\"action\":\"accept\",\"content\":{{\"name\":\"for-{s}\"}}}}}}", .{which});
        }
    };
    var user: u8 = 0;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try r.call(arena.allocator(), "fake", "echo", "{\"text\":\"withdraw\"}", null, .{ .context = &user, .ask = User.ask });
    try testing.expect(result == .result);
    try testing.expect(std.mem.find(u8, result.result.content, "e2=for-Q2") != null);
    try testing.expect(std.mem.find(u8, result.result.content, "e1 ") == null);
}

test "held servers say why, and unknown names and stdio logins are refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{
        .{ .name = "fake", .command = f.server },
        .{ .name = "off", .command = f.server, .enabled = false },
        .{ .name = "pending", .command = f.server, .source = .workspace, .workspace_admission = .pending },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const statuses_ = try r.statuses(a);
    try testing.expectEqual(State.idle, statuses_[0].state);
    try testing.expectEqual(State.disabled, statuses_[1].state);
    try testing.expectEqual(State.waiting_for_approval, statuses_[2].state);
    try testing.expectEqualStrings("the project server is waiting for approval", (try r.tools(a, "pending", null)).failed);
    try testing.expect((try r.tools(a, "nope", null)) == .unknown_server);
    try testing.expectError(error.Held, r.call(a, "off", "echo", null, null, null));
    try testing.expectError(error.NotHttp, r.login("fake", false));
    try testing.expectError(error.UnknownServer, r.logout("nope"));
}

test "answers go back under the server's keys, and an answer that can't be read declines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const keys = [_][]const u8{ "\"confirm\"", "\"pick\"" };
    const values = inputValues(a, "{\"pick\":{\"action\":\"decline\"},\"confirm\":{\"action\":\"accept\",\"content\":{\"ok\":true}}}", &keys).?;
    try testing.expectEqualStrings("{\"action\":\"accept\",\"content\":{\"ok\":true}}", values[0]);
    try testing.expectEqualStrings("{\"action\":\"decline\"}", values[1]);
    try testing.expect(inputValues(a, "{\"confirm\":{\"action\":\"accept\"}}", &keys) == null);
    try testing.expect(inputValues(a, "[]", &keys) == null);

    const accepted = elicitAnswer(a, "{\"elicitation\":{\"action\":\"accept\",\"content\":{\"choice\":\"x\"}}}").?;
    try testing.expectEqual(.accept, accepted.action);
    try testing.expectEqualStrings("{\"choice\":\"x\"}", accepted.content.?);
    const declined = elicitAnswer(a, "{\"elicitation\":{\"action\":\"decline\"}}").?;
    try testing.expectEqual(.decline, declined.action);
    try testing.expect(declined.content == null);
    try testing.expect(elicitAnswer(a, "{\"elicitation\":{\"action\":\"maybe\"}}") == null);
    try testing.expect(elicitAnswer(a, "{}") == null);
    try testing.expect(elicitAnswer(a, null) == null);

    try testing.expectEqualStrings("{}", declaredCapabilities(.{}));
    try testing.expectEqualStrings("{\"elicitation\":{\"form\":{}}}", declaredCapabilities(.{ .form = true }));
    try testing.expectEqualStrings("{\"elicitation\":{\"form\":{},\"url\":{}}}", declaredCapabilities(.{ .form = true, .url = true }));
}
