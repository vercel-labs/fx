//! fx's side of the MCP engine. One thread owns the engine, which is
//! single-threaded: other threads send it requests through a queue, wake it,
//! and read copied status snapshots. The owner turns fx's MCP config into the
//! engine's servers (`config.zig`), keeps sign-in credentials
//! (`credentials.zig`), and runs logins on a loopback listener (`login.zig`).
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
/// How long a logout waits for its revocation, as the engine's `close` does.
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
    /// A login is under way: from `/mcp login` until it signs in, fails,
    /// or expires, through the requests before its address comes.
    signing_in: bool = false,
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
    /// The call ended without an answer. `why`: the server's failure, when
    /// the call ended because its start failed.
    ended: struct { outcome: engine.Outcome, maybe_ran: bool, timed_out: bool, why: ?[]const u8 = null },
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
    /// Set while the user waits for a 2025 server to complete the URLs they
    /// opened: the owner completes it, and the question closes.
    url_wait: ?*const tool_mcp_runtime.LegacyUrlCompletionSignal = null,
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
    /// Where sign-in credentials are kept. `.detect` names the home whose
    /// store the owner thread picks with `credentials.Store.detect`, so
    /// `start` never waits for the Keychain; the owner replaces it with
    /// that store before it handles any request.
    credentials: union(enum) { detect: []const u8, store: credentials.Store },
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
    /// Where the call's progress notes go, on the caller's thread.
    progress: ?mcp_contract.ProgressSink = null,
    /// The latest note the owner left for the caller; its message is r.gpa's.
    note: ?mcp_contract.Progress = null,
    /// Guarded by `Runtime.mutex`: a question waiting for the caller to ask.
    question: ?Pending = null,
    /// Owner thread only: fx declined the server's question, so the call's
    /// cancellation is fx's answer, not the user's.
    declined: bool = false,
    /// Owner thread only: the URLs a 2025 server's -32042 answer listed,
    /// held with the call while the user opens them and the server
    /// completes them (`tests/tla/mcp_host/UrlRetry.tla`).
    urls: std.ArrayList(UrlNeed) = .empty,
    url_phase: enum { none, consent, waiting } = .none,
    url_server: usize = 0,
    /// The -32042 answer: the call's result unless it is called again.
    url_failure: ?CallResult = null,
    /// Closes the waiting question: the owner sets it, the caller reads it.
    url_signal: tool_mcp_runtime.LegacyUrlCompletionSignal = .{},

    const Kind = union(enum) {
        tools: []const u8,
        /// Starts a server's tool list without anyone waiting for it. The
        /// name is one of `servers()`, which outlive the runtime.
        need: []const u8,
        call: struct { server: []const u8, tool: []const u8, arguments: ?[]const u8 },
        cancel: *Request,
        login: struct { server: []const u8, open_browser: bool },
        finish_login: struct { server: []const u8, url: []const u8 },
        logout: []const u8,
        /// Servers that need a login take one another fx saved since.
        pick_up,
        /// What the user answered, posted by the caller that asked.
        answer: struct { pending: Pending, json: ?[]u8 },
        /// The config changed: see `reload`.
        reload: struct { configs: []const mcp_contract.McpServerConfig, inherited: *const std.process.Environ.Map },

        /// Whether handling it could start a server.
        fn mayStart(k: Kind) bool {
            return switch (k) {
                .tools, .need, .call, .login, .finish_login, .pick_up => true,
                .cancel, .logout, .answer, .reload => false,
            };
        }

        /// The server it could start, if one.
        fn starts(k: Kind) ?[]const u8 {
            return switch (k) {
                .tools => |name| name,
                .need => |name| name,
                .call => |c| c.server,
                .login => |l| l.server,
                .finish_login => |f| f.server,
                .pick_up, .cancel, .logout, .answer, .reload => null,
            };
        }
    };

    const Outcome = union(enum) {
        none,
        ok,
        failed: Error,
        tools: ToolsResult,
        call: CallResult,
        reloaded: Reloaded,
    };
};

/// A question the owner hands a calling thread, with what it takes to
/// answer it. Owned by the runtime's allocator.
const Pending = struct {
    /// The server's name, which outlives the runtime, so the calling thread
    /// reads it without the owner.
    name: []const u8,
    /// Which run of that server asked (`Runtime.ids`): an answer to a server
    /// a reload replaced reaches no one.
    server: u64,
    json: []u8,
    version: ?[]u8,
    reply: union(enum) {
        /// 2026: the call's input requests, answered in this key order.
        input: struct { call: engine.Handle, keys: [][]u8 },
        /// 2025: the server's elicitation, by slot and number, so an answer
        /// to one it withdrew never reaches the next in that slot.
        elicit: mcp.core.elicitation.Id,
        /// 2025: whether the user opens a held call's URLs.
        url_consent: *Request,
        /// 2025: the user's choice while the server completes them.
        url_wait: *Request,
    },

    fn deinit(p: *Pending, gpa: Allocator) void {
        gpa.free(p.json);
        if (p.version) |v| gpa.free(v);
        switch (p.reply) {
            .input => |input| {
                for (input.keys) |k| gpa.free(k);
                gpa.free(input.keys);
            },
            .elicit, .url_consent, .url_wait => {},
        }
        p.* = undefined;
    }
};

/// A URL a call's -32042 answer listed. `params` is the runtime allocator's.
const UrlNeed = struct {
    id: mcp.core.elicitation.Id,
    params: []u8,
    seen: bool = false,
    /// Its slot went to another question, or the server withdrew it, so no
    /// completion of it can come.
    dropped: bool = false,
};

const url_elicitation_required: i64 = -32042;

const Login = struct {
    runtime: *Runtime,
    /// Its server's index, which a reload moves; owner thread only.
    server: usize,
    /// Its server's name, which outlives the runtime, for the login task.
    name: []const u8,
    listener: loopback.Listener,
    group: std.Io.Group = .init,
    deadline_ms: i64,
    open_browser: bool,
    /// The address the browser came back to, kept until the login ends:
    /// The engine reads the code in it when it redeems it.
    callback: ?[]u8 = null,
    /// The authorization address, once the engine made it, for a login
    /// asked for again: it shows the same one.
    url: ?[]u8 = null,
};

/// What a `reload` did.
pub const Reloaded = struct {
    /// Per server in the new `servers()`: it kept running as it was, so what
    /// it listed still holds.
    kept: []const bool,
    /// A server that ran before was removed, held back, or replaced by one
    /// of the same name.
    dropped: bool,
};

pub const Runtime = struct {
    gpa: Allocator,
    io: std.Io,
    options: Options,
    /// Lives until `deinit`: every server list a reload makes stays, since
    /// other threads may still read the one they had. Only the list and its
    /// changed strings are kept; the rest of a config goes once the engine
    /// copied it.
    arena: std.heap.ArenaAllocator,
    /// Replaced by `reload` on the owner thread under `mutex`; other threads
    /// read it under `mutex` (`servers`).
    resolved: config.Resolved,
    engine: engine.Engine,
    /// Per server in `resolved.servers`; owner thread only. `gpa`'s, as are
    /// `ids` and `tools_epochs`, each replaced by a reload.
    flags: []Flags,
    /// Per server in `resolved.servers`: which run of it this is, new for
    /// each server a reload adds or replaces. Owner thread only.
    ids: []u64,
    next_id: u64 = 1,
    /// Each server's count of `tools_stale` events, so the catalog can tell
    /// a list it holds from one the server may have changed since. Apart
    /// from `flags`, which a sign-in or sign-out resets, so a count never
    /// comes back to a value the catalog already saw. Replaced with
    /// `resolved`.
    tools_epochs: []std.atomic.Value(u64),
    /// Owner thread only: the last `drain` held a request while a server a
    /// reload dropped stops, so the owner looks again soon.
    holding: bool = false,
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
    /// Set once the owner gave the servers their saved credentials and
    /// published that, so `statuses` never reports a premature signed_in.
    credentials_restored: std.Io.Event = .unset,

    /// Owner thread only.
    calls: std.AutoHashMapUnmanaged(engine.Handle, *Request) = .empty,
    tool_waiters: std.ArrayList(struct { server: usize, request: *Request }) = .empty,
    logins: std.ArrayList(*Login) = .empty,
    /// 2025 URL questions the client was shown, by server and slot, with the
    /// server's elicitation id, until the server completes or withdraws them.
    url_questions: std.ArrayList(struct { server: usize, slot: u8, id: []u8 }) = .empty,
    /// URLs a -32042 answer listed, until that call's `.called` takes them.
    required: std.ArrayList(struct { server: usize, need: UrlNeed }) = .empty,
    /// Calls held for their URLs after a -32042 answer.
    held: std.ArrayList(*Request) = .empty,
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

    /// A refresh the engine said was due: waiting for its login's refresh lock,
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
    /// is needed, and saved credentials are read on the owner thread, so
    /// this never waits for the Keychain.
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
            .ids = &.{},
            .tools_epochs = &.{},
            .snapshot_arena = .init(gpa),
        };
        errdefer r.arena.deinit();
        errdefer r.snapshot_arena.deinit();
        const arena = r.arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const resolved = try config.resolve(scratch.allocator(), configs, inherited, r.options.workspace_root);
        const n = resolved.servers.len;
        r.resolved = .{ .servers = try config.keepServers(arena, resolved.servers, &.{}), .engine = &.{}, .engine_server = try arena.dupe(usize, resolved.engine_server) };
        r.flags = try gpa.alloc(Flags, n);
        errdefer gpa.free(r.flags);
        for (r.flags) |*f| f.* = .{};
        r.ids = try gpa.alloc(u64, n);
        errdefer gpa.free(r.ids);
        for (r.ids) |*id| id.* = r.newId();
        r.tools_epochs = try gpa.alloc(std.atomic.Value(u64), n);
        errdefer gpa.free(r.tools_epochs);
        for (r.tools_epochs) |*e| e.* = .init(0);
        // The engine copies what it keeps, so the rest of the config goes.
        try r.engine.init(io, gpa, .{ .context = r, .allow = allow, .log = log }, .{
            .client = .{ .info = .{ .name = "fx", .version = options.client_version }, .capabilities = declaredCapabilities(options.questions) },
        }, resolved.engine);
        errdefer r.engine.deinit();
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
        for (r.required.items) |q| r.gpa.free(q.need.params);
        r.required.deinit(r.gpa);
        r.held.deinit(r.gpa);
        r.finished.deinit(r.gpa);
        r.gpa.free(r.flags);
        r.gpa.free(r.ids);
        r.gpa.free(r.tools_epochs);
        r.snapshot_arena.deinit();
        r.arena.deinit();
        const was_retired = r.retired.load(.acquire);
        r.* = undefined;
        // Its servers are down: the others may start theirs.
        if (was_retired) retireEnded();
    }

    /// Every configured server's status, copied into `alloc`. Waits for the
    /// owner to restore saved credentials, so `signed_in` is settled.
    pub fn statuses(r: *Runtime, alloc: Allocator) Allocator.Error![]Status {
        _ = r.active.fetchAdd(1, .acq_rel);
        defer _ = r.active.fetchSub(1, .acq_rel);
        r.credentials_restored.waitUncancelable(r.io);
        return r.statusesNow(alloc);
    }

    /// `statuses` without the wait, for the UI thread's periodic refreshes,
    /// which must not hold up a frame: until the owner restored saved
    /// credentials, every server reads as not signed in.
    pub fn statusesNow(r: *Runtime, alloc: Allocator) Allocator.Error![]Status {
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

    /// Server `name`'s instructions, copied into `alloc`; null when it gave
    /// none or there is no such server.
    pub fn instructions(r: *Runtime, alloc: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        _ = r.active.fetchAdd(1, .acq_rel);
        defer _ = r.active.fetchSub(1, .acq_rel);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.snapshot) |s| if (std.mem.eql(u8, s.name, name)) {
            const text = s.instructions orelse return null;
            return try alloc.dupe(u8, text);
        };
        return null;
    }

    /// Server `name`'s count of the times its tools may have changed; 0 for
    /// none by that name. Read before asking for a list: a list asked for
    /// under an older count is out of date.
    pub fn toolsEpoch(r: *Runtime, name: []const u8) u64 {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const i = r.serverIndex(name) orelse return 0;
        return r.tools_epochs[i].load(.acquire);
    }

    /// The resolved servers, in config order. A reload replaces the list,
    /// but the one returned, and its names, stay valid until `deinit`.
    pub fn servers(r: *Runtime) []const config.Server {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
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

    /// Starts getting server `name`'s tool list without waiting, so several
    /// servers start at once; `tools` then waits less. `name` is one of
    /// `servers()`' names, which outlive the runtime.
    pub fn prepare(r: *Runtime, name: []const u8) Error!void {
        const req = try r.gpa.create(Request);
        req.* = .{ .kind = .{ .need = name }, .alloc = r.gpa, .owned = true };
        r.post(req) catch |err| {
            r.gpa.destroy(req);
            return err;
        };
    }

    /// Takes the changed config in place: a server whose config is the same
    /// keeps running, with its connection, calls, sign-in, and tools. The
    /// rest go: a removed one stops, its calls ending cancelled, and one
    /// added or changed starts fresh, once that name's old process is gone.
    /// `configs` and `inherited` are read only during the call. The host's
    /// lifecycle is modeled in `tests/tla/mcp_host/HostLifecycle.tla`.
    pub fn reload(r: *Runtime, configs: []const mcp_contract.McpServerConfig, inherited: *const std.process.Environ.Map) Error!Reloaded {
        var req: Request = .{ .kind = .{ .reload = .{ .configs = configs, .inherited = inherited } }, .alloc = r.gpa };
        try r.submit(&req, null);
        return switch (req.result) {
            .reloaded => |done| done,
            .failed => |err| err,
            else => unreachable,
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
        return r.callObserved(alloc, server, tool, arguments, cancel, asker, null, null);
    }

    pub fn callObserved(r: *Runtime, alloc: Allocator, server: []const u8, tool: []const u8, arguments: ?[]const u8, cancel: ?*const std.atomic.Value(bool), asker: ?Asker, progress: ?mcp_contract.ProgressSink, observed: ?observation.McpCall) Error!CallResult {
        var req: Request = .{ .kind = .{ .call = .{ .server = server, .tool = tool, .arguments = arguments } }, .alloc = alloc, .asker = asker, .progress = progress, .observation = observed };
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
            if (req.progress) |sink| r.reportProgress(req, sink);
            if (!cancel_tried) if (cancel) |flag| if (flag.load(.acquire)) {
                cancel_tried = true;
                // When stopping, the owner ends the request itself.
                cancel_sent = if (r.post(&cancel_req)) |_| true else |_| false;
            };
        }
        if (cancel_sent) cancel_req.done.waitUncancelable(io);
        // A note that came with the end is shown too, and freed.
        if (req.progress) |sink| r.reportProgress(req, sink);
    }

    /// On the caller's thread: passes the latest note the owner left, if
    /// any, to the call's progress sink.
    fn reportProgress(r: *Runtime, req: *Request, sink: mcp_contract.ProgressSink) void {
        r.mutex.lockUncancelable(r.io);
        const note = req.note orelse {
            r.mutex.unlock(r.io);
            return;
        };
        req.note = null;
        r.mutex.unlock(r.io);
        defer if (note.message) |m| r.gpa.free(m);
        sink.callback(sink.context, note);
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
            .server = pending.name,
            .input_requests_json = pending.json,
            .version = pending.version,
            .url_wait = if (pending.reply == .url_wait) &req.url_signal else null,
        }) catch |err| answer: {
            debug_trace.logf("mcp", "MCP question not answered server={s} err={s}", .{ pending.name, @errorName(err) });
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
        r.restoreCredentials();
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
        r.holding = false;
        while (true) {
            r.mutex.lockUncancelable(r.io);
            const stopping = r.stopping;
            var taken = r.queue;
            r.queue = .empty;
            var after_reload = false;
            if (!stopping) {
                // A reload ends its batch: what came after it waits for the
                // next one, so it is held against the servers it dropped.
                var batch = taken.items.len;
                for (taken.items, 0..) |req, k| if (req.kind == .reload) {
                    batch = k + 1;
                    break;
                };
                const retiring_now = r.waitsForRetired();
                var kept: usize = 0;
                for (taken.items[0..batch]) |req| {
                    // What could start a server waits, in order, while a
                    // retired runtime's servers stop, or while the process a
                    // reload dropped under that server's name does, so a
                    // server never runs twice.
                    const dropped_stopping = if (req.kind.starts()) |name| r.engine.stopping(name) else false;
                    if ((retiring_now and req.kind.mayStart()) or dropped_stopping) held: {
                        r.queue.append(r.gpa, req) catch break :held; // out of memory: handled now
                        if (dropped_stopping) r.holding = true;
                        continue;
                    }
                    taken.items[kept] = req;
                    kept += 1;
                }
                const rest = taken.items[batch..];
                if (rest.len > 0) {
                    if (r.queue.appendSlice(r.gpa, rest)) |_| {
                        after_reload = true;
                    } else |_| {
                        // Out of memory: handled now, after the reload.
                        @memmove(taken.items[kept..][0..rest.len], rest);
                        kept += rest.len;
                    }
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
            if (stopping or !after_reload) return stopping;
        }
    }

    /// Takes `req` out of the queue; false when it isn't there.
    fn unqueue(r: *Runtime, req: *Request) bool {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.queue.items, 0..) |queued, k| if (queued == req) {
            _ = r.queue.orderedRemove(k);
            return true;
        };
        return false;
    }

    fn handle(r: *Runtime, req: *Request) !void {
        switch (req.kind) {
            .tools => |name| {
                const i = r.serverIndex(name) orelse return r.finish(req, .{ .tools = .unknown_server });
                if (r.heldReason(req.alloc, i)) |why| return r.finish(req, .{ .tools = .{ .failed = try why } });
                if (r.flags[i].needs_login and r.loginFor(i) == null and !try r.pickUpLogin(i)) return r.finish(req, .{ .tools = .needs_login });
                // Between tries too, it waits for the next start, and a
                // failed start ends it with the reason, as a call waits.
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
            .need => |name| {
                if (r.engineServer(name) != null) r.engine.needTools(name) catch |err| {
                    debug_trace.logf("mcp", "MCP tool list not started server={s} err={s}", .{ name, @errorName(err) });
                };
                r.finish(req, .ok);
            },
            .reload => |c| r.finish(req, .{ .reloaded = try r.applyReload(c.configs, c.inherited) }),
            .call => |c| {
                const i = r.serverIndex(c.server) orelse return r.finish(req, .{ .call = .unknown_server });
                if (r.resolved.servers[i].held != null) return r.finish(req, .{ .failed = error.Held });
                if (r.flags[i].needs_login) _ = try r.pickUpLogin(i);
                try r.send(req, i);
            },
            .cancel => |target| {
                // One still waiting in the queue, held while a retired host's
                // servers stop, ends here without reaching its server.
                if (r.unqueue(target)) {
                    r.finish(target, switch (target.kind) {
                        .call => .{ .call = .{ .ended = .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false } } },
                        else => .{ .failed = error.Cancelled },
                    });
                    return r.finish(req, .ok);
                }
                var it = r.calls.iterator();
                while (it.next()) |entry| if (entry.value_ptr.* == target) {
                    try r.engine.cancel(entry.key_ptr.*);
                    break;
                };
                // A call held for its URLs ends here.
                if (r.isHeld(target)) r.endHeld(target, .{ .call = .{ .ended = .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false } } });
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
                const name = a.pending.name;
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
                        // Elicitation ids are per run of a server: the one a
                        // reload replaced never hears it, and nor does its
                        // successor.
                        if (r.serverById(a.pending.server) == null) {
                            debug_trace.logf("mcp", "MCP elicitation answer dropped server={s} reason=the server was reloaded", .{name});
                            return;
                        }
                        const answer = elicitAnswer(scratch.allocator(), a.json) orelse mcp.elicitation.Answer{ .action = .decline };
                        r.engine.answerElicitation(name, id, answer) catch |err| {
                            debug_trace.logf("mcp", "MCP elicitation answer not sent server={s} err={s}", .{ name, @errorName(err) });
                        };
                    },
                    // The call may have ended meanwhile; it is used only while held.
                    .url_consent => |held| if (r.isHeld(held) and held.url_phase == .consent) {
                        const choice = urlChoice(scratch.allocator(), a.json, held.urls.items.len);
                        const action: @FieldType(mcp.elicitation.Answer, "action") = switch (choice) {
                            .accepted => .accept,
                            .declined => .decline,
                            .cancelled => .cancel,
                        };
                        // Nothing goes back to the server: accept is consent, and
                        // the engine waits for each completion.
                        for (held.urls.items) |need| if (!need.dropped) r.engine.answerElicitation(name, need.id, .{ .action = action }) catch |err| {
                            debug_trace.logf("mcp", "MCP elicitation answer not sent server={s} err={s}", .{ name, @errorName(err) });
                        };
                        held.url_phase = .none;
                        if (choice != .accepted) return r.endHeld(held, null);
                        held.url_signal.status.store(.pending, .release);
                        held.url_signal.wake.store(false, .release);
                        r.askUrls(held, .waiting) catch |err| {
                            logUrlCallEnded(name, "wait", err);
                            r.endHeld(held, null);
                        };
                    },
                    // Every completion came, or the user chose Retry. The
                    // signal wins over a choice made as it came, as on screen.
                    .url_wait => |held| if (r.isHeld(held) and held.url_phase == .waiting) {
                        const completed = held.url_signal.status.load(.acquire) == .completed;
                        if (!completed and urlChoice(scratch.allocator(), a.json, held.urls.items.len) != .accepted) return r.endHeld(held, null);
                        r.callAgain(held);
                    },
                }
            },
            .logout => |name| {
                const i = r.engineServer(name) orelse return r.finish(req, .{ .failed = error.UnknownServer });
                const s = r.resolved.servers[i];
                if (s.transport != .http) return r.finish(req, .{ .failed = error.NotHttp });
                // The saved login is the one every other fx uses, and another fx
                // may have saved it after this one took its own: it's revoked
                // too, or it would stay valid at the server
                // (`tests/tla/mcp_host/SharedLogins.tla` LogoutRevokesSaved).
                const saved = r.options.credentials.store.lookup(r.gpa, s.credentialKey()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.CredentialStoreUnreadable => return r.finish(req, .{ .failed = error.CredentialStoreUnreadable }),
                    else => blk: {
                        debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                        break :blk null;
                    },
                };
                defer if (saved) |c| secret.zeroAndFree(r.gpa, c);
                // The saved login goes first: a store that can't be read leaves
                // the session signed in rather than half signed out.
                _ = r.options.credentials.store.remove(r.gpa, s.credentialKey()) catch |err| switch (err) {
                    error.CredentialStoreUnreadable => return r.finish(req, .{ .failed = error.CredentialStoreUnreadable }),
                    else => debug_trace.logf("mcp", "MCP credential not removed server={s} err={s}", .{ s.name, @errorName(err) }),
                };
                try r.engine.signOut(s.name);
                if (saved) |c| if (!r.holds(i, c) and try r.engine.adoptCredential(s.name, c)) {
                    debug_trace.logf("mcp", "MCP logout also revokes server={s} reason=another fx saved a newer login", .{s.name});
                    try r.engine.signOut(s.name);
                };
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
        // The sign-in already under way is the one asked for. Ending it would
        // close the port its browser comes back to while the engine keeps its
        // flow, so no sign-in could finish
        // (`tests/tla/mcp_host/SignIn.tla` FlowHasListener).
        if (r.loginFor(i)) |l| {
            l.open_browser = l.open_browser or open_browser;
            if (l.url) |url| {
                r.notify(.{ .authorize = .{ .server = s.name, .url = url } });
                if (open_browser) r.openBrowser(s.name, url);
            }
            return r.finish(req, .ok);
        }
        // A sign-in that couldn't be saved would last only this session.
        r.options.credentials.store.check(r.gpa) catch |err| switch (err) {
            error.CredentialStoreUnreadable => return r.finish(req, .{ .failed = error.CredentialStoreUnreadable }),
            else => debug_trace.logf("mcp", "MCP credential store not checked server={s} err={s}", .{ s.name, @errorName(err) }),
        };
        var listener = loopback.Listener.open(r.io, s.callback_port) catch |err| switch (err) {
            // Only a fixed port can be another app's, and the message names it.
            error.AddressInUse => if (s.callback_port != null) return r.finish(req, .{ .failed = error.CallbackPortInUse }) else return err,
            else => return err,
        };
        const l = r.gpa.create(Login) catch |err| {
            listener.close(r.io);
            return err;
        };
        l.* = .{
            .runtime = r,
            .server = i,
            .name = s.name,
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
                debug_trace.logf("mcp", "MCP login listener failed server={s} err={s}", .{ l.name, @errorName(err) });
                return;
            },
        };
        const req = r.gpa.create(Request) catch {
            r.gpa.free(url);
            return;
        };
        req.* = .{
            .kind = .{ .finish_login = .{ .server = l.name, .url = url } },
            .alloc = r.gpa,
            .owned = true,
            .owned_url = url,
        };
        r.post(req) catch {
            r.gpa.free(url);
            r.gpa.destroy(req);
        };
    }

    /// The URL went out in a notice either way.
    fn openBrowser(r: *Runtime, name: []const u8, url: []const u8) void {
        const opened = url_opener.native_opener.open(r.gpa, url) catch false;
        if (!opened) debug_trace.logf("mcp", "browser not opened for MCP login server={s}", .{name});
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
            if (l.url) |url| r.gpa.free(url);
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
                const entry = r.calls.fetchRemove(c.call) orelse return r.releaseRequired(i);
                const req = entry.value;
                var result = copyCall(req.alloc, c) catch |err| {
                    r.releaseRequired(i);
                    return r.finish(req, .{ .failed = err });
                };
                if (req.declined and result == .ended and result.ended.outcome == .cancelled) result.ended.outcome = .unsupported_input;
                // fx dropped the reply, and a stdio server with it: the
                // server didn't go away by itself.
                if (c.oversized and result == .ended) {
                    const s = r.resolved.servers[i];
                    debug_trace.logf("mcp", "MCP call reply dropped server={s} transport={s} reason=too_large", .{ s.name, @tagName(s.transport) });
                    result.ended.why = if (s.transport == .stdio)
                        "its reply was larger than fx reads in one message, so fx restarted the server"
                    else
                        "its reply was larger than fx reads in one message, so fx dropped it";
                }
                if (result == .ended and result.ended.outcome == .transport_failed) {
                    const down = if (r.enginePhase(i)) |p| p == .backoff or p == .failed else false;
                    if (down) result.ended.why = r.failureText(req.alloc, i) catch null;
                }
                if (r.holdForUrls(i, req, result)) return;
                r.finish(req, .{ .call = result });
            },
            .progress => |p| {
                const req = r.calls.get(p.call) orelse return;
                if (req.progress == null) return;
                const message = if (p.message) |m| try r.gpa.dupe(u8, m) else null;
                r.mutex.lockUncancelable(r.io);
                defer r.mutex.unlock(r.io);
                // Only the latest waits for the caller.
                if (req.note) |old| if (old.message) |m| r.gpa.free(m);
                req.note = .{ .progress = p.progress, .total = p.total, .message = message };
            },
            .input => |q| {
                const req = r.calls.get(q.call) orelse return r.engine.cancel(q.call);
                if (req.asker == null) {
                    // Nobody can answer: each question is answered cancel,
                    // dismissed without a choice, and the server goes on.
                    const elicitations = for (q.requests) |request| {
                        if (request.kind != .elicitation) break false;
                    } else true;
                    if (elicitations) {
                        debug_trace.logf("mcp", "MCP input request answered cancel server={s} reason=no question UI", .{event.server});
                        const values = try r.gpa.alloc([]const u8, q.requests.len);
                        defer r.gpa.free(values);
                        @memset(values, cancel_answer);
                        return r.engine.respond(q.call, values);
                    }
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
                    else if (r.lastError(w.request.alloc, i)) |why| .{ .failed = why } else |err| err;
                    r.finish(w.request, if (result) |ok| .{ .tools = ok } else |err| .{ .failed = err });
                }
            },
            .auth_required => |required| {
                r.flags[i].needs_login = true;
                // Only a step-up keeps the login working for what it had;
                // otherwise the saved one, if any, doesn't sign anything in.
                if (!required.step_up) r.flags[i].signed_in = false;
                if (required.refused) |refused| {
                    debug_trace.logf("mcp", "MCP login dropped server={s} reason=refresh refused status={d} error={s}", .{ name, refused.status, refused.code });
                } else {
                    debug_trace.logf("mcp", "MCP login needed server={s} reason={s}", .{ name, if (required.step_up) "more scopes" else "sign-in required" });
                }
                r.notify(.{ .needs_login = name });
                // Nothing comes until someone logs in.
                r.endToolWaiters(i, .needs_login);
            },
            .authorize => |authorize| {
                r.notify(.{ .authorize = .{ .server = name, .url = authorize } });
                for (r.logins.items) |l| if (l.server == i) {
                    // Only a return carrying this sign-in's state ends its wait.
                    l.listener.expect(r.io, authorize);
                    // Out of memory, a login asked for again just doesn't show it.
                    if (r.gpa.dupe(u8, authorize)) |url| {
                        if (l.url) |old| r.gpa.free(old);
                        l.url = url;
                    } else |_| {}
                    if (l.open_browser) r.openBrowser(name, authorize);
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
            .tools_stale => _ = r.tools_epochs[i].fetchAdd(1, .release),
            .credential => try r.saveCredential(i),
            .refresh_due => try r.refreshDue(i),
            .refresh_ended => r.endRefresh(i),
            .elicit => |x| {
                // A question in a slot means a URL that slot held is gone.
                r.dropUrlSlot(i, x.id.slot);
                if (x.required) {
                    // Listed in a call's -32042 answer: that call's `.called`
                    // comes next and takes it.
                    const params = try r.gpa.dupe(u8, x.params);
                    r.required.append(r.gpa, .{ .server = i, .need = .{ .id = x.id, .params = params } }) catch |err| {
                        r.gpa.free(params);
                        return err;
                    };
                } else {
                    // Nobody can answer: dismissed without a choice.
                    const cancel: mcp.elicitation.Answer = .{ .action = .cancel };
                    const req = r.callAsking(name) orelse {
                        debug_trace.logf("mcp", "MCP elicitation answered cancel server={s} reason=no call can ask", .{name});
                        return r.engine.answerElicitation(name, x.id, cancel);
                    };
                    const json = try r.gpa.print("{{\"elicitation\":{{\"method\":\"elicitation/create\",\"params\":{s}}}}}", .{x.params});
                    var pending: Pending = .{ .name = r.resolved.servers[i].name, .server = r.ids[i], .json = json, .version = r.versionCopy(i), .reply = .{ .elicit = x.id } };
                    if (!r.offer(req, pending)) {
                        pending.deinit(r.gpa);
                        return r.engine.answerElicitation(name, x.id, cancel);
                    }
                }
                try r.holdUrl(i, x.id.slot, x.params);
            },
            .elicitation_complete => |slot| {
                r.urlCompleted(i, slot);
                r.endUrl(i, slot, true);
            },
            .elicit_withdrawn => |slot| {
                r.dropWithdrawn(i, slot);
                r.dropUrlSlot(i, slot);
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
            if (q.server != r.ids[i] or q.reply != .elicit or q.reply.elicit.slot != slot) continue;
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

    /// A 2025 server's -32042 answer listed URLs the user must open first: a
    /// call that can ask is held for them, and asked. False when it ends now.
    fn holdForUrls(r: *Runtime, i: usize, req: *Request, result: CallResult) bool {
        const listed = for (r.required.items) |q| {
            if (q.server == i) break true;
        } else false;
        if (!listed) return false;
        const name = r.resolved.servers[i].name;
        if (req.asker == null or result != .failure or result.failure.code != url_elicitation_required) {
            debug_trace.logf("mcp", "MCP elicitation answered cancel server={s} reason=no call can ask", .{name});
            r.releaseRequired(i);
            return false;
        }
        r.holdUrls(i, req, result) catch |err| {
            logUrlCallEnded(name, "hold", err);
            r.unhold(req);
            r.releaseRequired(i);
            return false;
        };
        return true;
    }

    fn holdUrls(r: *Runtime, i: usize, req: *Request, result: CallResult) Allocator.Error!void {
        try r.held.ensureUnusedCapacity(r.gpa, 1);
        req.url_server = i;
        r.held.appendAssumeCapacity(req);
        var k: usize = 0;
        while (k < r.required.items.len) {
            if (r.required.items[k].server != i) {
                k += 1;
                continue;
            }
            try req.urls.append(r.gpa, r.required.items[k].need);
            _ = r.required.orderedRemove(k);
        }
        req.url_failure = result;
        try r.askUrls(req, .consent);
    }

    /// Offers a held call's URLs to its caller: for consent, or with the
    /// call's signal while the server completes them.
    fn askUrls(r: *Runtime, req: *Request, phase: @FieldType(Request, "url_phase")) Allocator.Error!void {
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer out.deinit();
        // An allocating writer fails only when allocation does.
        out.writer.writeByte('{') catch return error.OutOfMemory;
        // A key per URL, "a" on: a call holds at most one per engine slot.
        for (req.urls.items, 0..) |need, n| {
            if (n > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
            const key = [_]u8{ '"', 'a' + @as(u8, @intCast(n)), '"' };
            out.writer.writeAll(&key) catch return error.OutOfMemory;
            out.writer.writeAll(":{\"method\":\"elicitation/create\",\"params\":") catch return error.OutOfMemory;
            out.writer.writeAll(need.params) catch return error.OutOfMemory;
            out.writer.writeByte('}') catch return error.OutOfMemory;
        }
        out.writer.writeByte('}') catch return error.OutOfMemory;
        const pending: Pending = .{
            .name = r.resolved.servers[req.url_server].name,
            .server = r.ids[req.url_server],
            .json = try out.toOwnedSlice(),
            .version = r.versionCopy(req.url_server),
            .reply = if (phase == .consent) .{ .url_consent = req } else .{ .url_wait = req },
        };
        r.mutex.lockUncancelable(r.io);
        // A question the call left unasked ended with that call.
        var stale = req.question;
        req.question = pending;
        r.mutex.unlock(r.io);
        if (stale) |*p| p.deinit(r.gpa);
        req.url_phase = phase;
    }

    fn isHeld(r: *const Runtime, req: *Request) bool {
        return std.mem.findScalar(*Request, r.held.items, req) != null;
    }

    /// Ends a held call with its -32042 answer, or with `result`.
    fn endHeld(r: *Runtime, req: *Request, result: ?Request.Outcome) void {
        const failure: Request.Outcome = if (req.url_failure) |f| .{ .call = f } else .{ .failed = error.Cancelled };
        r.unhold(req);
        r.finish(req, result orelse failure);
    }

    /// Takes a call off the held list and lets go of its URLs. A waiting
    /// question still on screen closes as Cancel.
    fn unhold(r: *Runtime, req: *Request) void {
        if (std.mem.findScalar(*Request, r.held.items, req)) |k| _ = r.held.orderedRemove(k);
        const name = r.resolved.servers[req.url_server].name;
        for (req.urls.items) |need| {
            // One still shown is dismissed; the engine refuses the rest.
            if (!need.dropped and !need.seen) r.engine.answerElicitation(name, need.id, .{ .action = .cancel }) catch {};
            r.gpa.free(need.params);
        }
        req.urls.clearAndFree(r.gpa);
        if (req.url_phase == .waiting) {
            req.url_signal.status.store(.cancelled, .release);
            req.url_signal.wake.store(true, .release);
        }
        req.url_phase = .none;
    }

    /// The user opened every URL, and the server completed them or the user
    /// chose Retry: the call goes again, as a new request.
    fn callAgain(r: *Runtime, req: *Request) void {
        const failure = req.url_failure orelse CallResult{ .ended = .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false } };
        req.url_failure = null;
        r.unhold(req);
        r.send(req, req.url_server) catch |err| {
            logUrlCallEnded(r.resolved.servers[req.url_server].name, "again", err);
            r.finish(req, .{ .call = failure });
        };
    }

    /// Sends a call to server `i`'s engine and waits for its `.called`.
    fn send(r: *Runtime, req: *Request, i: usize) !void {
        const c = req.kind.call;
        // Room first: a call the engine took must have its waiter.
        try r.calls.ensureUnusedCapacity(r.gpa, 1);
        const handle_ = try r.engine.call(r.resolved.servers[i].name, c.tool, c.arguments);
        if (req.observation) |call_| call_.engineRequest(handle_);
        r.calls.putAssumeCapacity(handle_, req);
    }

    /// URLs a -32042 answer listed that no call holds: dismissed.
    fn releaseRequired(r: *Runtime, i: usize) void {
        var k: usize = 0;
        while (k < r.required.items.len) {
            const q = r.required.items[k];
            if (q.server != i) {
                k += 1;
                continue;
            }
            _ = r.required.orderedRemove(k);
            r.engine.answerElicitation(r.resolved.servers[i].name, q.need.id, .{ .action = .cancel }) catch {};
            r.gpa.free(q.need.params);
        }
    }

    /// The URL a held call has in `slot` can't complete any more: another
    /// question took the slot, or the server withdrew it.
    fn dropUrlSlot(r: *Runtime, i: usize, slot: u8) void {
        for (r.held.items) |req| if (req.url_server == i) {
            for (req.urls.items) |*need| if (need.id.slot == slot and !need.seen) {
                need.dropped = true;
            };
        };
    }

    /// The server completed the URL in `slot`: a held call counts it, and
    /// once every URL it waits for has come, its waiting question closes.
    fn urlCompleted(r: *Runtime, i: usize, slot: u8) void {
        for (r.held.items) |req| if (req.url_server == i) {
            var all = true;
            for (req.urls.items) |*need| {
                if (need.id.slot == slot and !need.dropped) need.seen = true;
                all = all and need.seen;
            }
            if (all and req.url_phase == .waiting) {
                req.url_signal.status.store(.completed, .release);
                req.url_signal.wake.store(true, .release);
            }
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
            if (r.options.credentials.store.put(r.gpa, s.credentialKey(), out.written())) {
                // Only a saved login is this process's own; one that wasn't
                // leaves the store's as it was, for a refusal to remove.
                r.flags[i].tried = credentials.digest(out.written());
                r.flags[i].not_saved = false;
            } else |err| {
                debug_trace.logf("mcp", "MCP credential not saved server={s} err={s}", .{ s.name, @errorName(err) });
                if (r.flags[i].not_saved) return;
                r.flags[i].not_saved = true;
                var buf: [320]u8 = undefined;
                r.notify(.{ .not_saved = .{ .server = s.name, .reason = notSavedReason(&buf, r.options.credentials.store, err) } });
            }
        } else {
            // The tokens are gone, so this process is signed out whatever
            // the store holds.
            r.flags[i].signed_in = false;
            const own = r.flags[i].tried orelse return debug_trace.logf("mcp", "MCP login dropped server={s} saved=none", .{s.name});
            // Only this process's own login goes: one another fx saved since
            // stays, for the next request to take.
            const removed = r.options.credentials.store.removeIfSame(r.gpa, s.credentialKey(), own) catch |err| {
                return debug_trace.logf("mcp", "MCP credential not removed server={s} err={s}", .{ s.name, @errorName(err) });
            };
            debug_trace.logf("mcp", "MCP login dropped server={s} saved={s}", .{ s.name, if (removed) "removed" else "kept, another fx saved a newer one" });
        }
    }

    // ---- reload ----

    /// The owner's side of `reload`. What can fail before a server is touched
    /// comes first; only the engine's own reload can fail after that.
    fn applyReload(r: *Runtime, configs: []const mcp_contract.McpServerConfig, inherited: *const std.process.Environ.Map) !Reloaded {
        var scratch: std.heap.ArenaAllocator = .init(r.gpa);
        defer scratch.deinit();
        const s = scratch.allocator();
        const next = try config.resolve(s, configs, inherited, r.options.workspace_root);
        const n = next.servers.len;
        // What a caller reads after the reload: the servers, and which kept running.
        const arena = r.arena.allocator();
        const kept_servers = try config.keepServers(arena, next.servers, r.resolved.servers);
        const engine_server = try arena.dupe(usize, next.engine_server);
        const kept = try arena.alloc(bool, n);
        @memset(kept, false);
        for (next.engine, next.engine_server) |c, j| kept[j] = r.engine.keeps(c);
        // Each new server's old index, and each old one's new index, for the
        // servers that keep running as they were.
        const from = try s.alloc(?usize, n);
        for (next.servers, kept, from) |server, k, *f| f.* = if (k) r.serverIndex(server.name) else null;
        const to = try s.alloc(?usize, r.resolved.servers.len);
        @memset(to, null);
        for (from, 0..) |f, j| if (f) |i| {
            to[i] = j;
        };
        const flags = try r.gpa.alloc(Flags, n);
        errdefer r.gpa.free(flags);
        const ids = try r.gpa.alloc(u64, n);
        errdefer r.gpa.free(ids);
        const epochs = try r.gpa.alloc(std.atomic.Value(u64), n);
        errdefer r.gpa.free(epochs);
        for (from, flags, ids, epochs) |f, *flag, *id, *epoch| {
            flag.* = if (f) |i| r.flags[i] else .{};
            id.* = if (f) |i| r.ids[i] else r.newId();
            epoch.* = .init(if (f) |i| r.tools_epochs[i].load(.acquire) else 0);
        }

        var dropped = false;
        for (r.resolved.engine_server) |i| if (to[i] == null) {
            dropped = true;
            r.dropServer(i, next.servers);
        };
        // The engine copies what it keeps; the rest goes with `scratch`.
        try r.engine.reload(next.engine);
        r.moveServers(to);
        r.mutex.lockUncancelable(r.io);
        const old_flags = r.flags;
        const old_ids = r.ids;
        const old_epochs = r.tools_epochs;
        r.resolved = .{ .servers = kept_servers, .engine = &.{}, .engine_server = engine_server };
        r.flags = flags;
        r.ids = ids;
        r.tools_epochs = epochs;
        r.mutex.unlock(r.io);
        // Other threads read the epochs only under `mutex`.
        r.gpa.free(old_flags);
        r.gpa.free(old_ids);
        r.gpa.free(old_epochs);
        var added: usize = 0;
        for (engine_server) |j| if (from[j] == null) {
            added += 1;
            r.adoptSaved(j);
        };
        var same: usize = 0;
        for (kept) |k| same += @intFromBool(k);
        debug_trace.logf("mcp", "MCP config reloaded servers={d} kept={d} fresh={d} dropped={s}", .{ n, same, added, if (dropped) "yes" else "no" });
        return .{ .kept = kept, .dropped = dropped };
    }

    /// Old server `i` doesn't run on as it was: removed, held back, or
    /// replaced. Its calls end, as they may have run; a tool list asked of it
    /// is asked again of whatever has its name now; its sign-in, logout,
    /// refresh, and URL questions end. `next` is the servers after the reload.
    fn dropServer(r: *Runtime, i: usize, next: []const config.Server) void {
        const name = r.resolved.servers[i].name;
        const successor: ?config.Server = for (next) |s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else null;
        const why = if (successor == null) "removed" else if (successor.?.held != null) "held back" else "changed";
        debug_trace.logf("mcp", "MCP server stops for a reload server={s} reason={s}", .{ name, why });
        while (r.callOn(name)) |waiting| {
            _ = r.calls.remove(waiting.handle);
            r.finish(waiting.request, .{ .call = .{ .ended = .{
                .outcome = .cancelled,
                .maybe_ran = r.engine.callSent(waiting.handle),
                .timed_out = false,
                .why = "the MCP config changed, and fx stopped the server",
            } } });
        }
        var k: usize = 0;
        while (k < r.tool_waiters.items.len) {
            const w = r.tool_waiters.items[k];
            if (w.server != i) {
                k += 1;
                continue;
            }
            _ = r.tool_waiters.swapRemove(k);
            r.mutex.lockUncancelable(r.io);
            const queued = if (r.queue.append(r.gpa, w.request)) |_| true else |_| false;
            r.mutex.unlock(r.io);
            if (queued) r.engine.wake() else r.finish(w.request, .{ .failed = error.OutOfMemory });
        }
        if (r.loginFor(i) != null) {
            var buf: [320]u8 = undefined;
            const reason = if (successor != null and successor.?.held == null)
                std.mem.print(&buf, "the MCP config changed before the browser came back; run /mcp login {s} again", .{name}) catch "the MCP config changed before the browser came back"
            else
                "the MCP config changed before the browser came back";
            r.notify(.{ .sign_in_failed = .{ .server = name, .reason = reason } });
            r.endLogin(i);
        }
        k = 0;
        while (k < r.logouts.items.len) {
            const l = r.logouts.items[k];
            if (l.server != i) {
                k += 1;
                continue;
            }
            _ = r.logouts.swapRemove(k);
            r.finish(l.request, .ok);
        }
        r.endRefresh(i);
        k = 0;
        while (k < r.held.items.len) {
            const req = r.held.items[k];
            if (req.url_server != i) {
                k += 1;
                continue;
            }
            r.endHeld(req, .{ .call = .{ .ended = .{ .outcome = .cancelled, .maybe_ran = false, .timed_out = false, .why = "the MCP config changed, and fx stopped the server" } } });
        }
        k = 0;
        while (k < r.required.items.len) {
            if (r.required.items[k].server != i) {
                k += 1;
                continue;
            }
            r.gpa.free(r.required.orderedRemove(k).need.params);
        }
        k = 0;
        while (k < r.url_questions.items.len) {
            if (r.url_questions.items[k].server != i) {
                k += 1;
                continue;
            }
            r.gpa.free(r.url_questions.swapRemove(k).id);
        }
    }

    /// Points what waits on a server that kept running at its new index;
    /// `dropServer` ended the rest.
    fn moveServers(r: *Runtime, to: []const ?usize) void {
        for (r.tool_waiters.items) |*w| w.server = to[w.server].?;
        for (r.logins.items) |l| l.server = to[l.server].?;
        for (r.logouts.items) |*l| l.server = to[l.server].?;
        for (r.refreshes.items) |*f| f.server = to[f.server].?;
        for (r.held.items) |req| req.url_server = to[req.url_server].?;
        for (r.required.items) |*q| q.server = to[q.server].?;
        for (r.url_questions.items) |*q| q.server = to[q.server].?;
    }

    /// A server a reload added signs in with the login saved for it, as
    /// `restoreCredentials` does at the start.
    fn adoptSaved(r: *Runtime, i: usize) void {
        const s = r.resolved.servers[i];
        if (s.url == null) return;
        const saved = r.options.credentials.store.get(r.gpa, s.credentialKey()) catch |err| {
            return debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
        } orelse return;
        defer secret.zeroAndFree(r.gpa, saved);
        r.engine.restoreCredential(s.name, saved) catch |err| {
            return debug_trace.logf("mcp", "MCP credential not loaded server={s} err={s}", .{ s.name, @errorName(err) });
        };
        r.flags[i].signed_in = true;
        r.flags[i].tried = credentials.digest(saved);
    }

    /// A call still waiting on server `name`.
    fn callOn(r: *Runtime, name: []const u8) ?struct { handle: engine.Handle, request: *Request } {
        var it = r.calls.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.kind.call.server, name)) return .{ .handle = entry.key_ptr.*, .request = entry.value_ptr.* };
        }
        return null;
    }

    fn serverById(r: *const Runtime, id: u64) ?usize {
        return std.mem.findScalar(u64, r.ids, id);
    }

    fn newId(r: *Runtime) u64 {
        defer r.next_id += 1;
        return r.next_id;
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
        while (r.held.items.len > 0) r.endHeld(r.held.items[0], .{ .failed = error.Stopped });
        for (r.required.items) |q| r.gpa.free(q.need.params);
        r.required.clearRetainingCapacity();
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
                .failed, .retrying => try r.failureText(a, i),
                else => null,
            };
            o.needs_login = r.flags[i].needs_login;
            o.signed_in = r.flags[i].signed_in;
            o.signing_in = r.loginFor(i) != null;
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
        if (r.waitsForRetired() or r.holding) wait = @min(wait, retiring_wait_ms);
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
        return .{ .name = r.resolved.servers[i].name, .server = r.ids[i], .json = json, .version = r.versionCopy(i), .reply = .{ .input = .{ .call = call_handle, .keys = keys } } };
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
            const why = r.lastError(w.request.alloc, i);
            r.finish(w.request, if (why) |text| .{ .tools = .{ .failed = text } } else |err| .{ .failed = err });
        }
    }

    fn enginePhase(r: *const Runtime, i: usize) ?engine.Phase {
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        return r.engine.status(k).phase;
    }

    fn lastError(r: *const Runtime, alloc: Allocator, i: usize) Allocator.Error![]u8 {
        return (try r.failureText(alloc, i)) orelse try alloc.dupe(u8, "the server is unavailable");
    }

    /// Why server `i` is down, in `alloc`, with what its process said when
    /// it ran over stdio: how it ended, the stdout line it wrote instead of
    /// MCP, and its last stderr lines. Null with no failure.
    fn failureText(r: *const Runtime, alloc: Allocator, i: usize) Allocator.Error!?[]u8 {
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        const st = r.engine.status(k);
        const why = st.last_error orelse return null;
        var tail_buf: [mcp.stdio.tail_max]u8 = undefined;
        const tail = r.engine.stderrTail(k, &tail_buf);
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        writeFailure(&out.writer, why, st.exit, st.stray_line, tail) catch return error.OutOfMemory;
        return try out.toOwnedSlice();
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
        if (r.options.credentials.store.tryRefreshLock(s.credentialKey())) |maybe| {
            if (maybe) |lock| {
                f.lock = lock;
            } else if (r.nowMs() < f.deadline_ms) {
                return;
            } else debug_trace.logf("mcp", "MCP refresh went ahead server={s} reason=another fx held its refresh lock too long", .{s.name});
        } else |err| debug_trace.logf("mcp", "MCP refresh went ahead server={s} reason=no refresh lock err={s}", .{ s.name, @errorName(err) });
        f.sent = true;
        const saved = r.options.credentials.store.lookup(r.gpa, s.credentialKey()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Whether it's still saved can't be told, so it's refreshed as before.
            else => {
                debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                return r.engine.refresh(s.name);
            },
        };
        if (saved) |c| {
            defer secret.zeroAndFree(r.gpa, c);
            if (try r.take(f.server, c)) debug_trace.logf("mcp", "MCP refresh replaced server={s} reason=another fx refreshed", .{s.name});
        } else if (r.flags[f.server].tried != null) {
            // This fx's login was saved and is gone: another fx logged out of
            // it, or removed the server. Refreshing would save it back and
            // undo that, so this fx signs out too
            // (`tests/tla/mcp_host/SharedLogins.tla` LogoutStays).
            debug_trace.logf("mcp", "MCP login ended server={s} reason=signed out in another fx", .{s.name});
            if (f.lock) |*l| l.release();
            f.lock = null;
            try r.engine.signOut(s.name);
            r.flags[f.server] = .{};
            return;
        }
        // Nothing goes out once a saved login replaced the refresh.
        try r.engine.refresh(s.name);
    }

    /// Whether `saved` is the login server `i` last saved or took.
    fn holds(r: *const Runtime, i: usize, saved: []const u8) bool {
        const tried = r.flags[i].tried orelse return false;
        return std.mem.eql(u8, &tried, &credentials.digest(saved));
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
    /// when there is none, it's one `i` had or tried already, or the server
    /// can't use it.
    fn takeSaved(r: *Runtime, i: usize) !bool {
        const s = r.resolved.servers[i];
        const saved = r.options.credentials.store.get(r.gpa, s.credentialKey()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                return false;
            },
        } orelse return false;
        defer secret.zeroAndFree(r.gpa, saved);
        return r.take(i, saved);
    }

    /// `saved` given to server `i`, as `takeSaved` does.
    fn take(r: *Runtime, i: usize, saved: []const u8) !bool {
        const s = r.resolved.servers[i];
        if (r.holds(i, saved)) return false;
        r.flags[i].tried = credentials.digest(saved);
        // One the server can't use isn't a login: the server still needs one.
        if (!try r.engine.useCredential(s.name, saved)) {
            debug_trace.logf("mcp", "MCP saved login not usable, ignored server={s}", .{s.name});
            return false;
        }
        return true;
    }

    /// Before any request: picks the store when `start` left that to the
    /// owner, reads it once, and gives each HTTP server the login saved
    /// under its key, so no server starts without it. A store that can't be
    /// read leaves every server signed out, as one without credentials.
    fn restoreCredentials(r: *Runtime) void {
        defer r.credentials_restored.set(r.io);
        const store: credentials.Store = switch (r.options.credentials) {
            .store => |s| s,
            .detect => |home| .detect(r.gpa, home),
        };
        r.options.credentials = .{ .store = store };
        var saved = store.snapshot(r.gpa) catch |err| {
            debug_trace.logf("mcp", "MCP credentials not loaded err={s}", .{@errorName(err)});
            return;
        };
        defer saved.deinit(r.gpa);
        for (r.resolved.engine_server) |i| {
            const s = r.resolved.servers[i];
            if (s.url == null) continue;
            const credential = saved.get(s.credentialKey()) orelse continue;
            r.engine.restoreCredential(s.name, credential) catch |err| {
                debug_trace.logf("mcp", "MCP credential not loaded server={s} err={s}", .{ s.name, @errorName(err) });
                continue;
            };
            r.flags[i].signed_in = true;
            // The login this process starts with, so a refusal removes only
            // its own and a login another fx saves since is taken.
            r.flags[i].tried = credentials.digest(credential);
        }
        r.publish() catch |err| debug_trace.logf("mcp", "MCP status not published err={s}", .{@errorName(err)});
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
        .metadata_not_json => "its sign-in metadata isn't JSON",
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

fn writeFailure(w: *std.Io.Writer, why: []const u8, exit: ?mcp.stdio.Exit, stray: ?[]const u8, tail: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll(describeFailure(why));
    // "its process exited" says how; another failure adds it.
    const own = std.mem.eql(u8, why, "process");
    if (exit) |e| switch (e) {
        .code => |c| try w.print("{s} with code {d}", .{ if (own) "" else "; its process exited", c }),
        .signal => |n| try w.print("{s} on signal {d}", .{ if (own) "" else "; its process exited", n }),
    };
    if (stray) |line| try w.print("; it wrote \"{s}\" instead of MCP", .{line});
    if (tail) |t| try w.print("; its last stderr lines: \"{s}\"", .{t});
}

/// The engine names why a server is down; fx says it in words. Anything else,
/// such as an HTTP failure's own text, is shown as it is.
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

/// An elicitation's answer when nobody can give one: dismissed without a
/// choice.
const cancel_answer = "{\"action\":\"cancel\"}";

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

/// A held call that ended with its -32042 answer because fx failed at `step`.
fn logUrlCallEnded(server: []const u8, step: []const u8, err: anyerror) void {
    debug_trace.logf("mcp", "MCP URL call ended server={s} step={s} err={s}", .{ server, step, @errorName(err) });
}

/// The user's choice for a held call's `n` URLs, from fx's `inputResponses`
/// object: accepted only when every URL was.
fn urlChoice(a: Allocator, json: ?[]const u8, n: usize) enum { accepted, declined, cancelled } {
    const answers = std.json.parseFromSliceLeaky(std.json.Value, a, json orelse return .cancelled, .{ .parse_numbers = false }) catch return .cancelled;
    if (answers != .object or answers.object.count() != n) return .cancelled;
    var declined = false;
    for (answers.object.values()) |reply| {
        if (reply != .object) return .cancelled;
        const action = reply.object.get("action") orelse return .cancelled;
        if (action != .string) return .cancelled;
        if (std.mem.eql(u8, action.string, "decline")) {
            declined = true;
        } else if (!std.mem.eql(u8, action.string, "accept")) return .cancelled;
    }
    return if (declined) .declined else .accepted;
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

test "a call held while a retired host's servers stop ends when cancelled, and its server never starts" {
    waitRetired();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const Caller = struct {
        fn call(runtime: *Runtime, cancel: *std.atomic.Value(bool), out: *?engine.Outcome, done: *std.atomic.Value(bool)) void {
            defer done.store(true, .release);
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            const result = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"late\"}", cancel, null) catch return;
            if (result == .ended) out.* = result.ended.outcome;
        }
    };
    retireStarted();
    var holding = true;
    defer if (holding) retireEnded();
    var cancel: std.atomic.Value(bool) = .init(false);
    var outcome: ?engine.Outcome = null;
    var done: std.atomic.Value(bool) = .init(false);
    const caller = try std.Thread.spawn(.{}, Caller.call, .{ &r, &cancel, &outcome, &done });
    // Nothing may start a server yet, so the call waits in the queue.
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    const waited = !done.load(.acquire);
    cancel.store(true, .release);
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 2_000;
    while (!done.load(.acquire) and std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    // Ended by the cancel, while the retired host's servers still stop.
    const ended_while_held = done.load(.acquire);
    retireEnded();
    holding = false;
    caller.join();
    try testing.expect(waited);
    try testing.expect(ended_while_held);
    try testing.expectEqual(@as(?engine.Outcome, .cancelled), outcome);
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    try testing.expectEqual(State.idle, (try r.statuses(arena.allocator()))[0].state);
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

/// Server `name`'s process id, as the fake server says it.
fn pidOf(r: *Runtime, a: Allocator, name: []const u8) ![]const u8 {
    const result = try r.call(a, name, "echo", "{\"text\":\"pid\"}", null, null);
    if (result != .result) return error.TestUnexpectedResult;
    const at = std.mem.find(u8, result.result.content, "pid=") orelse return error.TestUnexpectedResult;
    const digits = result.result.content[at + 4 ..];
    return digits[0 .. std.mem.findNone(u8, digits, "0123456789") orelse digits.len];
}

test "a reload keeps a server whose config is the same on its process, and restarts the changed ones" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var one = [_]mcp_contract.McpEnvVar{.{ .key = @constCast("MODE"), .value = @constCast("one") }};
    var two = [_]mcp_contract.McpEnvVar{.{ .key = @constCast("MODE"), .value = @constCast("two") }};
    const before = [_]mcp_contract.McpServerConfig{
        .{ .name = "same", .command = f.server, .env = &one },
        .{ .name = "args", .command = f.server },
        .{ .name = "env", .command = f.server, .env = &one },
        .{ .name = "gone", .command = f.server },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &before, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "same", null)).tools.len);
    const same = try pidOf(&r, a, "same");
    const args = try pidOf(&r, a, "args");
    const env = try pidOf(&r, a, "env");
    _ = try pidOf(&r, a, "gone");

    // The config is read afresh, so each environment is a new map; the same
    // variables still count as the same server.
    const after = [_]mcp_contract.McpServerConfig{
        .{ .name = "added", .command = f.server },
        .{ .name = "same", .command = f.server, .env = &one },
        .{ .name = "args", .command = f.server, .args = &.{"--new"} },
        .{ .name = "env", .command = f.server, .env = &two },
    };
    const done = try r.reload(&after, &f.inherited);
    try testing.expectEqualSlices(bool, &.{ false, true, false, false }, done.kept);
    try testing.expect(done.dropped);
    const statuses = try r.statuses(a);
    try testing.expectEqualStrings("added", statuses[0].name);
    try testing.expectEqual(State.idle, statuses[0].state);
    // Still up and listed, before anything asks it again.
    try testing.expectEqualStrings("same", statuses[1].name);
    try testing.expectEqual(State.ready, statuses[1].state);
    try testing.expectEqual(@as(usize, 1), statuses[1].tools);
    try testing.expectEqualStrings(same, try pidOf(&r, a, "same"));
    try testing.expect(!std.mem.eql(u8, args, try pidOf(&r, a, "args")));
    try testing.expect(!std.mem.eql(u8, env, try pidOf(&r, a, "env")));
    _ = try pidOf(&r, a, "added");
    try testing.expectEqual(CallResult.unknown_server, try r.call(a, "gone", "echo", "{}", null, null));

    // Taking only an added server drops nothing.
    var more: [5]mcp_contract.McpServerConfig = undefined;
    @memcpy(more[0..4], &after);
    more[4] = .{ .name = "late", .command = f.server };
    try testing.expect(!(try r.reload(&more, &f.inherited)).dropped);
    try testing.expectEqualStrings(same, try pidOf(&r, a, "same"));
}

test "a reload ends a call on a server it drops, and a call on a server it keeps goes on" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = [_]mcp_contract.McpServerConfig{
        .{ .name = "kept", .command = f.server },
        .{ .name = "gone", .command = f.server },
    };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &before, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try r.tools(a, "kept", null);
    _ = try r.tools(a, "gone", null);

    const Caller = struct {
        server: []const u8,
        cancel: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        ended: ?@FieldType(CallResult, "ended") = null,
        why: [128]u8 = undefined,
        why_len: usize = 0,

        fn run(c: *@This(), runtime: *Runtime) void {
            defer c.done.store(true, .release);
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            const result = runtime.call(ca.allocator(), c.server, "echo", "{\"text\":\"slow\"}", &c.cancel, null) catch return;
            if (result != .ended) return;
            c.ended = result.ended;
            if (result.ended.why) |why| {
                c.why_len = @min(why.len, c.why.len);
                @memcpy(c.why[0..c.why_len], why[0..c.why_len]);
            }
        }
    };
    var kept: Caller = .{ .server = "kept" };
    var gone: Caller = .{ .server = "gone" };
    const kept_thread = try std.Thread.spawn(.{}, Caller.run, .{ &kept, &r });
    const gone_thread = try std.Thread.spawn(.{}, Caller.run, .{ &gone, &r });
    std.Io.sleep(testing.io, .fromMilliseconds(300), .awake) catch {};

    const after = [_]mcp_contract.McpServerConfig{.{ .name = "kept", .command = f.server }};
    _ = try r.reload(&after, &f.inherited);
    gone_thread.join();
    try testing.expectEqual(engine.Outcome.cancelled, gone.ended.?.outcome);
    // It reached the server, so it may have run there.
    try testing.expect(gone.ended.?.maybe_ran);
    try testing.expectEqualStrings("the MCP config changed, and fx stopped the server", gone.why[0..gone.why_len]);
    // The kept server's call is still out; only its cancel ends it.
    std.Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    try testing.expect(!kept.done.load(.acquire));
    kept.cancel.store(true, .release);
    kept_thread.join();
    try testing.expectEqual(engine.Outcome.cancelled, kept.ended.?.outcome);
    try testing.expectEqual(@as(usize, 0), kept.why_len);
}

test "a changed server's new process starts only once the old one is gone" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = [_]mcp_contract.McpServerConfig{.{ .name = "slow-exit", .command = f.server, .args = &.{"linger"} }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &before, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try std.fmt.parseInt(std.posix.pid_t, try pidOf(&r, a, "slow-exit"), 10);

    const after = [_]mcp_contract.McpServerConfig{.{ .name = "slow-exit", .command = f.server, .args = &.{ "linger", "again" } }};
    const reloaded_ms = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    _ = try r.reload(&after, &f.inherited);
    const new = try std.fmt.parseInt(std.posix.pid_t, try pidOf(&r, a, "slow-exit"), 10);
    try testing.expect(new != old);
    // The old one lingers a second after its stdin ends; the new one waited.
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - reloaded_ms >= 900);
    try testing.expectError(error.ProcessNotFound, std.posix.kill(old, @fromBackingInt(@intCast(0))));
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

test "a failure says how the process ended, what it wrote instead of MCP, and its last stderr lines" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeFailure(&w, "process", .{ .code = 7 }, null, "npm error code E401 / npm error Incorrect or missing password.");
    try testing.expectEqualStrings("its process exited with code 7; its last stderr lines: \"npm error code E401 / npm error Incorrect or missing password.\"", w.buffered());
    w = .fixed(&buf);
    try writeFailure(&w, "initialize_failed", .{ .signal = 15 }, "not json", null);
    try testing.expectEqualStrings("it refused or never answered fx's initialize request; its process exited on signal 15; it wrote \"not json\" instead of MCP", w.buffered());
    w = .fixed(&buf);
    try writeFailure(&w, "FileNotFound", null, null, null);
    try testing.expectEqualStrings("its command was not found", w.buffered());
}

test "a question no call can show is answered cancel, and the server goes on" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.questions = .{ .form = true };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // fx can take questions, but this call has no one to ask.
    const result = try r.call(arena.allocator(), "fake", "echo", "{\"text\":\"confirm\"}", null, null);
    try testing.expect(result == .result);
    try testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"c1=cancel\"}]", result.result.content);
}

test "saved credentials load on the owner thread, and statuses wait for them" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const store: credentials.Store = .{ .home = f.home, .backend = .file };
    try store.put(testing.allocator, .{ .name = "web", .url = "https://web.example.invalid/mcp" }, "{\"access\":\"w1\"}");
    try store.put(testing.allocator, .{ .name = "moved", .url = "https://old.example.invalid/mcp" }, "{\"access\":\"m1\"}");
    // A project server takes only the login saved under its workspace.
    try store.put(testing.allocator, .{ .name = "team", .url = "https://team.example.invalid/mcp" }, "{\"access\":\"profile\"}");
    try store.put(testing.allocator, .{ .name = "repo", .url = "https://repo.example.invalid/mcp", .workspace = "/Users/example/repo" }, "{\"access\":\"r1\"}");
    const configs = [_]mcp_contract.McpServerConfig{
        .{ .name = "web", .transport = .http, .url = "https://web.example.invalid/mcp" },
        // A credential saved for another URL is not this server's.
        .{ .name = "moved", .transport = .http, .url = "https://new.example.invalid/mcp" },
        .{ .name = "none", .transport = .http, .url = "https://none.example.invalid/mcp" },
        .{ .name = "fake", .command = f.server },
        .{ .name = "team", .transport = .http, .url = "https://team.example.invalid/mcp", .source = .workspace, .scope = .workspace, .workspace_admission = .approved },
        .{ .name = "repo", .transport = .http, .url = "https://repo.example.invalid/mcp", .source = .workspace, .scope = .workspace, .workspace_admission = .approved },
    };
    var options = f.options();
    options.workspace_root = "/Users/example/repo";
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try r.statuses(arena.allocator());
    try testing.expect(got[0].signed_in);
    try testing.expect(!got[1].signed_in);
    try testing.expect(!got[2].signed_in);
    try testing.expect(!got[3].signed_in);
    try testing.expect(!got[4].signed_in);
    try testing.expect(got[5].signed_in);
    try testing.expectEqual(State.idle, got[0].state);
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

test "a held call's URLs are opened only when the user accepted every one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(urlChoice(a, "{\"a\":{\"action\":\"accept\"},\"b\":{\"action\":\"accept\"}}", 2) == .accepted);
    try testing.expect(urlChoice(a, "{\"a\":{\"action\":\"accept\"},\"b\":{\"action\":\"decline\"}}", 2) == .declined);
    try testing.expect(urlChoice(a, "{\"a\":{\"action\":\"cancel\"},\"b\":{\"action\":\"accept\"}}", 2) == .cancelled);
    // A URL with no answer, or no answer at all, is not consent.
    try testing.expect(urlChoice(a, "{\"a\":{\"action\":\"accept\"}}", 2) == .cancelled);
    try testing.expect(urlChoice(a, null, 1) == .cancelled);
    try testing.expect(urlChoice(a, "not json", 1) == .cancelled);
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
