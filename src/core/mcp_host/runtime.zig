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
const kept_sign_outs = @import("kept_sign_outs.zig");
const login_words = @import("login_words.zig");
const loopback = @import("login.zig");
const elicitation = @import("../mcp/elicitation.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const json_decode = @import("../shared/json_decode.zig");
const json_depth = @import("../shared/json_depth.zig");
const shared_servers = @import("shared_servers.zig");
const dropped_tools = @import("dropped_tools.zig");
const owner_core = @import("owner_core.zig");
const share_key = @import("share_key.zig");

const Allocator = std.mem.Allocator;
const engine = mcp.engine;

/// A login waits this long for the browser to come back.
const login_timeout_ms: i64 = 5 * 60 * 1000;
/// A new login waits this long for the server to answer a request with it,
/// past the engine's own start timeout: the owner ends the sign-in then.
const confirm_wait_ms: i64 = 45 * 1000;
/// How long after a refused new login the saved login that the host takes back is the one from
/// before it. The next request, status or verb takes it back within moments; a login saved by
/// another fx after this long is a new login, and fx says so.
const refusal_pickup_ms: i64 = 30 * 1000;
/// The longest the owner sleeps; a `wake` ends it sooner.
const idle_wait_ms: u32 = 1000;
/// How long a logout waits for its revocation, as the engine's `close` does.
const revoke_wait_ms: i64 = 2000;
/// How long a sent refresh waits for its answer, the engine's own timeout,
/// which `config.zig` keeps for every server: the longest step a refresh
/// lock's holder takes between its stamps (`credentials.Store.refreshHolderStopped`).
const refresh_answer_ms: i64 = (@FieldType(mcp.engine.Options, "timeouts"){}).refresh_ms;
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
    /// Why fx refused the last tool list the server answered, in the words of `mcp.tools.Refusal`, which may name
    /// the HTTP status fx read: set only for a server that is `ready`. It is no failure of the server, so
    /// `last_error` stays empty. An older accepted list is still served: `tools` counts it. The engine only lends
    /// the words, so `publish` copies them into the snapshot and `statusesNow` copies them into each caller's
    /// allocator, like the other strings.
    tools_error: ?[]const u8 = null,
    /// The HTTP status behind `tools_error` when its words say the server is temporarily unavailable (429, 503), else
    /// 0: `fx mcp show` and the `/mcp` screen say "unavailable (HTTP n)" for it. A number, so every copy carries it.
    tools_unavailable: u16 = 0,
    /// How many tools of the list fx left out of what the model gets, by reason, for a server that is `ready`: the ones
    /// the engine skipped (`mcp.tools.Store.addPage`) and the ones the host's reading refuses (`dropped_tools`). Plain
    /// counts, so every copy of a `Status` carries them as it is.
    dropped: mcp.tools.Dropped = .{},
    needs_login: bool = false,
    signed_in: bool = false,
    /// A login is under way: from `/mcp login` until it signs in, fails,
    /// or expires, through the requests before its address comes, and the
    /// request that checks the new login.
    signing_in: bool = false,
    /// Why the server needs a login, once it does. Its words come from
    /// `login_words`; `last_error` holds them for a refused login.
    reason: login_words.Reason = .{},
    /// The variable a `missing_env` or `invalid_env` server names.
    missing: ?[]const u8 = null,
    /// What the server told fx to tell the model about it.
    instructions: ?[]const u8 = null,
};

pub const Tool = struct { name: []const u8, raw: []const u8 };

/// How a logout ended.
pub const Logout = struct {
    /// Why the saved login couldn't be removed, if it couldn't: this fx is
    /// signed out, but every other fx, and the next one, still has it.
    kept: ?anyerror = null,
    revocation: Revocation = .none,
    /// An `.unconfirmed` revocation is kept, and fx sends it again later
    /// (`kept_sign_outs.zig`).
    retry_later: bool = false,

    /// What the server did with the login's tokens.
    pub const Revocation = enum {
        /// No revocation went out, as when its authorization server takes
        /// none: the tokens stay valid there until they expire.
        none,
        /// The server answered the revocation with a 2xx, so the tokens no
        /// longer work there (RFC 7009 section 2.2).
        confirmed,
        /// It answered otherwise, not within `revoke_wait_ms`, or the
        /// request couldn't be sent: the tokens may still work there.
        unconfirmed,
    };
};

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
    /// `data` is what the server gave to explain it, as JSON text bounded by
    /// `data_cap`; null when it gave none, gave null, or the error is a -32042.
    failure: struct { code: i64, message: []const u8, data: ?[]const u8 = null },
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
    /// The login is new and kept, but the request that checks it didn't show
    /// whether the server takes the token (no answer, a 5xx, a 403 that isn't a
    /// step-up): a failure that isn't a refusal.
    signed_in_unchecked: []const u8,
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
    /// store the owner thread picks lazily with `credentials.Store.detect`
    /// when an HTTP server needs it, so `start` never waits for the Keychain
    /// and stdio-only configs never touch it.
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
    /// How long a server may hold nothing before it stops; 0 never.
    idle_ms: u32 = 0,
    /// Sharing MCP servers with other fx sessions through one owner process.
    /// Null runs every server here, as before.
    share: ?Share = null,
};

/// Where this session's shared servers come from.
pub const Share = struct {
    /// The profile's folder: `~/.fx`, or `$FX_HOME`.
    fx_home: []const u8,
    /// Whether this session may start an owner; a test serves one instead.
    spawn_owner: bool = true,
};

/// The gate's limits for an idle limit: a server quiet for that long has
/// stayed up, so a limit below `stable_ms` lowers it too, and an idle stop
/// never waits on it (`tests/tla/mcp/Engine.tla` IdleFire).
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

/// A logout waiting for its revocation's answer.
const PendingLogout = struct {
    server: usize,
    request: *Request,
    deadline_ms: i64,
    /// The kept sign-out whose revocation this waits for, owned by the
    /// runtime's allocator: forgotten once the server confirms it, else it
    /// stays kept for a later retry (`kept_sign_outs.zig`).
    kept_token: ?[]u8 = null,
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
    /// Set by the owner before a logout ends: why the saved login stayed.
    logout_kept: ?anyerror = null,
    /// Set by the owner before a logout ends: what the server did with the
    /// revocation.
    logout_revocation: Logout.Revocation = .none,
    /// Set by the owner before a logout ends: its `Logout.retry_later`.
    logout_retry_later: bool = false,
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
    /// The token exchange is done and the engine holds the new tokens, unsaved.
    /// The login waits for the server's answer to a request with them
    /// (`concludeSignIn`), and `deadline_ms` is that wait's end.
    confirming: bool = false,
};

/// How a sign-in ends once its tokens are held: the server took them, it
/// couldn't be asked (a failure that isn't a refusal), or it refused them.
const SignInEnd = union(enum) { accepted, unchecked, refused: login_words.Reason };

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
    /// Owner thread only: this session's shared servers and their owner
    /// connection (`shared_servers.zig`); null runs every server here.
    shared: ?shared_servers.Shared = null,
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
    /// Owner thread only: why the store of saved logins couldn't be read,
    /// from a read that gave servers no login (at the start, or for one a
    /// reload added) until one works. Those servers start without a login,
    /// and one asked for a login reads the store again first.
    store_unread: ?anyerror = null,

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
    logouts: std.ArrayList(PendingLogout) = .empty,
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
        /// Its tools were asked for again with a login read after a 401, so
        /// the listing that 401 ended answers no waits; the next one does.
        relisting: bool = false,
        /// Why the server needs a login, while `needs_login`.
        login: login_words.Held = .{},
        /// When a new login of this server was refused, so the saved login the host takes back
        /// next is the one it had before, not a sign-in. Only the moments after the refusal count:
        /// see `refusalRecent`.
        refused_new_ms: ?i64 = null,
        /// What `dropped_tools` counted in the list whose `fingerprint` is `dropped_key`, so a list is read once and
        /// not at every status snapshot.
        dropped_here: mcp.tools.Dropped = .{},
        dropped_key: ?u64 = null,
    };

    /// A refresh the engine said was due: waiting for its login's refresh lock,
    /// or holding it until the refresh ends.
    const Refresh = struct {
        server: usize,
        lock: ?credentials.Store.Locked = null,
        sent: bool = false,
        /// When it began waiting for the refresh lock, on the awake clock.
        started_ms: i64,
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
        r.options.workspace_root = try arena.dupe(u8, options.workspace_root);
        r.options.credentials = switch (options.credentials) {
            .detect => |home| .{ .detect = try arena.dupe(u8, home) },
            .store => |store| .{ .store = .{
                .home = try arena.dupe(u8, store.home),
                .backend = store.backend,
            } },
        };
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const resolved = try config.resolve(scratch.allocator(), configs, inherited, r.options.workspace_root, io_mod.homeDir());
        const n = resolved.servers.len;
        const routing = r.options.share != null;
        // With sharing, the runtime keeps every engine config: a shared
        // server registers it with the owner, and one that cannot share runs
        // from it here.
        const kept_engine: []mcp.engine.Config = if (routing) try config.keepEngineConfigs(arena, resolved.engine) else try arena.alloc(mcp.engine.Config, 0);
        r.resolved = .{ .servers = try config.keepServers(arena, resolved.servers, &.{}), .shared = try arena.dupe(bool, resolved.shared), .engine = &.{}, .engine_server = &.{} };
        r.flags = try gpa.alloc(Flags, n);
        errdefer gpa.free(r.flags);
        for (r.flags) |*f| f.* = .{};
        r.ids = try gpa.alloc(u64, n);
        errdefer gpa.free(r.ids);
        for (r.ids) |*id| id.* = r.newId();
        r.tools_epochs = try gpa.alloc(std.atomic.Value(u64), n);
        errdefer gpa.free(r.tools_epochs);
        for (r.tools_epochs) |*e| e.* = .init(0);
        // A shared server registers its config with the owner, which runs it.
        // No owner at all leaves every server running here, as before.
        if (r.options.share) |share| {
            // The runtime keeps its copy of the folder: the caller's string
            // is only read while this returns.
            r.options.share = .{ .fx_home = try arena.dupe(u8, share.fx_home), .spawn_owner = share.spawn_owner };
            r.shared = shared_servers.Shared.init(.{
                .io = io,
                .gpa = gpa,
                .fx_home = r.options.share.?.fx_home,
                .spawn_owner = share.spawn_owner,
                .ask_form = options.questions.form,
                .ask_url = options.questions.url,
                .wake = .{ .context = r, .wake = wakeEngine },
            }) catch |err| blk: {
                debug_trace.logf("mcp", "MCP servers run in this session reason={s}", .{@errorName(err)});
                break :blk null;
            };
        }
        errdefer if (r.shared) |*s| s.deinit();
        if (r.shared) |*s| for (kept_engine, resolved.engine_server) |c, i| {
            if (!resolved.shared[i]) continue;
            try s.add(r.resolved.servers[i].name, c);
        };
        // The engine copies what it keeps, so the rest of the config goes. A
        // shared server stays out of it, and its config is kept until a
        // reload moves it in.
        var local_engine: std.ArrayList(mcp.engine.Config) = .empty;
        defer local_engine.deinit(scratch.allocator());
        var local_servers: std.ArrayList(usize) = .empty;
        defer local_servers.deinit(scratch.allocator());
        if (routing) {
            const on_owner = r.shared != null;
            for (kept_engine, resolved.engine_server) |c, i| {
                if (on_owner and resolved.shared[i]) continue;
                try local_engine.append(scratch.allocator(), c);
                try local_servers.append(scratch.allocator(), i);
            }
            r.resolved.engine = try arena.dupe(mcp.engine.Config, local_engine.items);
            r.resolved.engine_server = try arena.dupe(usize, local_servers.items);
        } else {
            try local_engine.appendSlice(scratch.allocator(), resolved.engine);
            r.resolved.engine_server = try arena.dupe(usize, resolved.engine_server);
        }
        try r.engine.init(io, gpa, .{ .context = r, .allow = allow, .log = log }, .{
            .client = .{ .info = .{ .name = "fx", .version = options.client_version }, .capabilities = declaredCapabilities(options.questions) },
            .gate = mcp.core.engine.limitsFor(options.idle_ms),
        }, local_engine.items);
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
        for (r.logouts.items) |l| if (l.kept_token) |token| secret.zeroAndFree(r.gpa, token);
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
            if (s.tools_error) |t| o.tools_error = try alloc.dupe(u8, t);
            if (s.missing) |m| o.missing = try alloc.dupe(u8, m);
            if (s.instructions) |t| o.instructions = try alloc.dupe(u8, t);
            o.reason = try login_words.copy(alloc, s.reason);
        }
        return out;
    }

    /// What server `name` says about a login it refused, copied into `alloc`
    /// (`login_words.errorText`): null when it isn't waiting for a login, or
    /// waits for one for another reason.
    pub fn refusedLogin(r: *Runtime, alloc: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        _ = r.active.fetchAdd(1, .acq_rel);
        defer _ = r.active.fetchSub(1, .acq_rel);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.snapshot) |s| if (std.mem.eql(u8, s.name, name)) {
            if (!s.needs_login or s.reason.kind != .login_refused) return null;
            return try alloc.dupe(u8, s.last_error orelse return null);
        };
        return null;
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
    pub fn logout(r: *Runtime, server: []const u8) Error!Logout {
        var req: Request = .{ .kind = .{ .logout = server }, .alloc = r.gpa };
        try r.submitOk(&req);
        return .{ .kept = req.logout_kept, .revocation = req.logout_revocation, .retry_later = req.logout_retry_later };
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
            // The shared servers' events come from the owner, in the shape
            // the engine's do, so `onEvent` handles both.
            if (r.shared) |*s| {
                while (s.take()) |e| {
                    r.onEvent(e) catch |err| debug_trace.logf("mcp", "MCP shared event handling failed server={s} err={s}", .{ e.server, @errorName(err) });
                }
                // A key the owner refused runs in this session from now on,
                // while every other shared key keeps its owner.
                while (s.nextRefused()) |refused| {
                    defer r.gpa.free(refused);
                    r.runHere(refused) catch |err| {
                        debug_trace.logf("mcp", "MCP server not run in this session server={s} reason=owner refused it err={s}", .{ refused, @errorName(err) });
                        continue;
                    };
                    r.engine.needTools(refused) catch |err| {
                        debug_trace.logf("mcp", "MCP tool list not started server={s} err={s}", .{ refused, @errorName(err) });
                    };
                }
            }
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
                if (r.flags[i].needs_login and r.loginFor(i) == null and !try r.pickUpLogin(i)) {
                    if (try r.unreadText(req.alloc, i)) |why| return r.finish(req, .{ .tools = .{ .failed = why } });
                    return r.finish(req, .{ .tools = .needs_login });
                }
                // Between tries too, it waits for the next start, and a
                // failed start ends it with the reason, as a call waits.
                try r.tool_waiters.ensureUnusedCapacity(r.gpa, 1);
                try r.needToolsOf(r.resolved.servers[i].name);
                r.tool_waiters.appendAssumeCapacity(.{ .server = i, .request = req });
            },
            .pick_up => {
                for (r.flags, 0..) |f, i| if (f.needs_login) {
                    _ = try r.pickUpLogin(i);
                };
                r.finish(req, .ok);
            },
            .need => |name| {
                if (r.engineServer(name) != null) r.needToolsOf(name) catch |err| {
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
                    try r.cancelCall(entry.key_ptr.*);
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
                // A logout is done locally; only the wait for the revocation
                // stops, and its sign-out stays kept.
                for (r.logouts.items, 0..) |l, k| if (l.request == target) {
                    _ = r.logouts.swapRemove(k);
                    r.endLogout(l, false);
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
                        if (values) |v| r.respondCall(input.call, v) catch |err| {
                            debug_trace.logf("mcp", "MCP answer not sent server={s} err={s}", .{ name, @errorName(err) });
                        } else {
                            if (r.calls.get(input.call)) |asking| asking.declined = true;
                            // The input request was declined, and this call
                            // should end now; say when the engine didn't take
                            // the cancel, since the call then waits its deadline.
                            r.cancelCall(input.call) catch |err| {
                                debug_trace.logf("mcp", "MCP declined input cancel not sent server={s} err={s}", .{ name, @errorName(err) });
                            };
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
                        r.answerOn(name, id, answer) catch |err| {
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
                        for (held.urls.items) |need| if (!need.dropped) r.answerOn(name, need.id, .{ .action = action }) catch |err| {
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
                const saved = r.ensureCredentialStore().lookup(r.gpa, s.credentialKey()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.CredentialStoreUnreadable => return r.finish(req, .{ .failed = error.CredentialStoreUnreadable }),
                    else => blk: {
                        debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                        break :blk null;
                    },
                };
                defer if (saved) |c| secret.zeroAndFree(r.gpa, c);
                // Each revocation is kept before the saved login goes, so one
                // the server never confirms is sent again later
                // (`kept_sign_outs.zig`).
                var held_token = try r.keepHeldSignOut(i);
                defer if (held_token) |t| secret.zeroAndFree(r.gpa, t);
                const revokes_saved = if (saved) |c| !r.holds(i, c) else false;
                var saved_token = if (revokes_saved) r.keepSignOut(saved.?, s.url.?) else null;
                defer if (saved_token) |t| secret.zeroAndFree(r.gpa, t);
                // The saved login goes first: a store that can't be read leaves
                // the session signed in rather than half signed out.
                if (r.ensureCredentialStore().remove(r.gpa, s.credentialKey())) |_| {} else |err| switch (err) {
                    error.CredentialStoreUnreadable => {
                        // Nothing is revoked, so nothing stays kept.
                        if (held_token) |t| kept_sign_outs.forget(r.gpa, r.ensureCredentialStore(), t);
                        if (saved_token) |t| kept_sign_outs.forget(r.gpa, r.ensureCredentialStore(), t);
                        return r.finish(req, .{ .failed = error.CredentialStoreUnreadable });
                    },
                    else => {
                        debug_trace.logf("mcp", "MCP credential not removed server={s} err={s}", .{ s.name, @errorName(err) });
                        req.logout_kept = err;
                    },
                }
                try r.engine.signOut(s.name);
                // The engine waits for its latest revocation only.
                var last = &held_token;
                if (saved) |c| if (revokes_saved and try r.engine.adoptCredential(s.name, c)) {
                    debug_trace.logf("mcp", "MCP logout also revokes server={s} reason=another fx saved a newer login", .{s.name});
                    try r.engine.signOut(s.name);
                    last = &saved_token;
                };
                // A new login that waits for its check request goes with the logout: its tokens
                // are gone, so the answer would have nothing to save, and "Signed in" would follow
                // a logout (`tests/tla/mcp_host/SignIn.tla` Logout, LoggedOutNeverSaved).
                if (r.confirmingLogin(i)) {
                    debug_trace.logf("mcp", "MCP login dropped server={s} reason=signed out while it waited for the server", .{s.name});
                    r.endLogin(i);
                    r.notify(.{ .sign_in_failed = .{ .server = s.name, .reason = "signed out before the server answered" } });
                }
                r.flags[i] = .{};
                // A program that exits next would lose a revocation still on
                // its way, so the logout ends when it's answered. Until then,
                // whether it worked isn't known.
                if (!r.engine.revoking(s.name)) {
                    // A kept revocation that isn't on its way couldn't be sent.
                    if (last.* != null) {
                        req.logout_revocation = .unconfirmed;
                        req.logout_retry_later = true;
                    }
                    return r.finish(req, .ok);
                }
                req.logout_revocation = .unconfirmed;
                try r.logouts.append(r.gpa, .{ .server = i, .request = req, .deadline_ms = r.nowMs() + revoke_wait_ms, .kept_token = last.* });
                last.* = null;
            },
        }
    }

    fn startLogin(r: *Runtime, req: *Request, name: []const u8, open_browser: bool) !void {
        const i = r.engineServer(name) orelse return r.finish(req, .{ .failed = if (r.serverIndex(name) == null) error.UnknownServer else error.Held });
        const s = r.resolved.servers[i];
        // Only HTTP servers sign in, and a shared server is stdio: the
        // transport decides first, so this is an answer, never an assert.
        if (s.transport != .http) return r.finish(req, .{ .failed = error.NotHttp });
        // The sign-in already under way is the one asked for. Ending it would
        // close the port its browser comes back to while the engine keeps its
        // flow, so no sign-in could finish
        // (`tests/tla/mcp_host/SignIn.tla` FlowHasListener).
        if (r.loginFor(i)) |l| {
            // Its browser is done: the server is being asked about the new login.
            if (l.confirming) return r.finish(req, .ok);
            l.open_browser = l.open_browser or open_browser;
            if (l.url) |url| {
                r.notify(.{ .authorize = .{ .server = s.name, .url = url } });
                if (open_browser) r.openBrowser(s.name, url);
            }
            return r.finish(req, .ok);
        }
        // A sign-in that couldn't be saved would last only this session.
        r.ensureCredentialStore().check(r.gpa) catch |err| switch (err) {
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

    fn confirmingLogin(r: *const Runtime, server: usize) bool {
        const l = r.loginFor(server) orelse return false;
        return l.confirming;
    }

    /// The reason an `auth_required` event gives.
    fn reasonOf(required: anytype) login_words.Reason {
        if (required.step_up) return .{ .kind = .more_scopes };
        if (required.refused) |refused| return .{ .kind = .refresh_refused, .code = refused.code };
        if (required.rejected) |rejected| return .{ .kind = .login_refused, .code = rejected.code, .description = rejected.description };
        return .{};
    }

    /// An error the server named, for a log line: only a plain token, never its prose.
    fn logCode(code: ?[]const u8) []const u8 {
        const text = code orelse return "unnamed";
        return if (login_words.isLogSafeCode(text)) text else "unnamed";
    }

    /// The server answered the request that checks server `i`'s new login, or
    /// couldn't (`SignInEnd`). An accepted login, and one that couldn't be
    /// checked, is saved, then reported. A refused one is forgotten with
    /// nothing saved, and the sign-in fails with the server's words, so no
    /// other fx can take it (`tests/tla/mcp_host/SignIn.tla`
    /// `SignedInOnlyAfterCheck`, `RefusedNeverSaved`, `NeverTakeRefused`).
    /// A 401 refuses the login whatever the refresh it started does after
    /// (`checkFailed`, the answer `refuse_unrenewed`).
    fn concludeSignIn(r: *Runtime, i: usize, how: SignInEnd) !void {
        if (!r.confirmingLogin(i)) return;
        const name = r.resolved.servers[i].name;
        switch (how) {
            .accepted, .unchecked => {
                if (how == .unchecked) debug_trace.logf("mcp", "MCP login kept server={s} reason=the check request didn't show whether the server takes the token", .{name});
                try r.saveCredential(i);
                r.flags[i] = .{ .signed_in = true };
                r.endLogin(i);
                r.notify(if (how == .accepted) .{ .signed_in = name } else .{ .signed_in_unchecked = name });
            },
            .refused => |reason| {
                debug_trace.logf("mcp", "MCP new login dropped server={s} reason=server refused the new login status=401 error={s}", .{ name, logCode(reason.code) });
                // The words first: the reason can borrow the engine's, and forgetting the login ends that.
                var arena: std.heap.ArenaAllocator = .init(r.gpa);
                defer arena.deinit();
                const words = (login_words.refusal(arena.allocator(), name, reason, .new) catch null) orelse "the server refused the new login";
                var buffer: [login_words.max_failure_bytes]u8 = undefined;
                const text = std.mem.print(&buffer, "{s}", .{words}) catch words[0..@min(words.len, buffer.len)];
                r.engine.discardLogin(name) catch |err| debug_trace.logf("mcp", "MCP new login not forgotten server={s} err={s}", .{ name, @errorName(err) });
                // Nothing was saved, so there is nothing to say beyond the sign-in's failure.
                r.flags[i] = .{ .needs_login = true, .refused_new_ms = r.nowMs() };
                r.endLogin(i);
                r.notify(.{ .sign_in_failed = .{ .server = name, .reason = text } });
                r.endToolWaiters(i, .needs_login);
            },
        }
    }

    /// The request that checks server `i`'s new login failed, and the server didn't say it needs
    /// a login. A 401 to the new token still refused it when the refresh that 401 started then got
    /// no usable answer (a 5xx, a 429, none): the engine holds that 401, so the sign-in ends
    /// refused with the server's words and nothing saved, as if the refresh had never run
    /// (`tests/tla/mcp_host/SignIn.tla` `RefusedNeverSaved`, answer `refuse_unrenewed`). With no 401
    /// held, the server was never heard on the token: a 5xx, a drop, a timeout, or a refresh that
    /// failed before anything was sent. The login is kept, with a note.
    fn checkFailed(r: *Runtime, i: usize) !void {
        const name = r.resolved.servers[i].name;
        const rejected = r.engine.loginRejected(name) orelse return r.concludeSignIn(i, .unchecked);
        debug_trace.logf("mcp", "MCP login check ended without an answer but the server had refused the token server={s} status={d} error={s}", .{ name, rejected.status, logCode(rejected.code) });
        try r.concludeSignIn(i, .{ .refused = .{ .kind = .login_refused, .code = rejected.code, .description = rejected.description } });
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
            if (l.confirming) {
                // The engine's own timeouts should have ended it; the sign-in doesn't wait longer. It
                // ends as any failed check does: refused when the engine holds a 401 for the token (a
                // refresh or a retry that 401 started is still pending), else kept with a note. So a
                // retry the server would accept, still waiting at this deadline, is refused too: the
                // engine keeps the first 401 until a request carrying the token is answered, and fx
                // saves no login the server refused and has not accepted since. The person can sign
                // in again.
                debug_trace.logf("mcp", "MCP login check ended server={s} reason=no answer in time", .{name});
                r.checkFailed(l.server) catch |err| {
                    debug_trace.logf("mcp", "MCP login not concluded server={s} err={s}", .{ name, @errorName(err) });
                    r.endLogin(l.server);
                };
                continue;
            }
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
            const confirmed = if (r.engine.revocationAnswer(r.resolved.servers[l.server].name)) |status| status >= 200 and status < 300 else false;
            r.endLogout(l, confirmed);
        }
    }

    /// Ends a logout that waited for its revocation. A confirmed one forgets
    /// its kept sign-out; any other leaves it kept to send again later.
    fn endLogout(r: *Runtime, l: PendingLogout, confirmed: bool) void {
        if (confirmed) l.request.logout_revocation = .confirmed;
        if (l.kept_token) |token| {
            if (confirmed) kept_sign_outs.forget(r.gpa, r.ensureCredentialStore(), token);
            l.request.logout_retry_later = !confirmed;
            secret.zeroAndFree(r.gpa, token);
        }
        r.finish(l.request, .ok);
    }

    fn onEvent(r: *Runtime, event: engine.Event) !void {
        const found = r.serverIndex(event.server);
        const i = found orelse {
            // A call's end still ends the call when the server it named is
            // already gone: a reload that dropped the server ran first, and
            // the shared adapter made this end as it dropped the slot
            // (`shared_servers.zig` `remove`). Nothing else reaches here.
            if (event.kind == .called) return r.onCalled(event.kind.called, null);
            return;
        };
        switch (event.kind) {
            // A failed attempt ends the waits for tools with its reason; the
            // engine keeps trying, so a later request may still get them.
            .phase => |phase| if (phase == .backoff or phase == .failed) {
                r.endToolWaiters(i, .failed);
                // The request that checks a new login failed to get an answer. Not a refusal,
                // unless the server's 401 stands (`checkFailed`).
                try r.checkFailed(i);
            },
            .called => |c| try r.onCalled(c, i),
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
                const req = r.calls.get(q.call) orelse return r.cancelCall(q.call);
                if (req.asker == null) {
                    // Nobody can answer, so the call ends as one fx could not
                    // give input to: a cancel answer would let the server go on
                    // with nothing the user chose. A shared server runs in an
                    // owner that declares every question UI its sessions can
                    // show, so this is also how a session without a UI answers
                    // a request it could not have made itself.
                    debug_trace.logf("mcp", "MCP input request declined server={s} reason=no question UI", .{event.server});
                    req.declined = true;
                    return r.cancelCall(q.call);
                }
                var pending = r.inputQuestion(i, q.call, q.requests) catch |err| {
                    try r.cancelCall(q.call);
                    return err;
                };
                if (!r.offer(req, pending)) {
                    pending.deinit(r.gpa);
                    req.declined = true;
                    try r.cancelCall(q.call);
                }
            },
            .server => |s| try r.onServer(i, event.server, s),
            .stopped_idle => debug_trace.logf("mcp", "MCP server stopped while idle server={s} idle_ms={d}", .{ event.server, r.options.idle_ms }),
        }
    }

    /// Ends one call. `i` is its server's index, or null when a reload removed
    /// the server before this end arrived: the call still ends, without the
    /// words the server's own state would have added.
    fn onCalled(r: *Runtime, c: anytype, i: ?usize) !void {
        const entry = r.calls.fetchRemove(c.call) orelse {
            if (i) |index| r.releaseRequired(index);
            return;
        };
        const req = entry.value;
        var result = copyCall(r.gpa, req.alloc, c) catch |err| {
            if (i) |index| r.releaseRequired(index);
            return r.finish(req, .{ .failed = err });
        };
        if (req.declined and result == .ended and result.ended.outcome == .cancelled) result.ended.outcome = .unsupported_input;
        if (i) |index| {
            // fx dropped the reply, and a stdio server with it: the
            // server didn't go away by itself.
            if (c.oversized and result == .ended) {
                const s = r.resolved.servers[index];
                debug_trace.logf("mcp", "MCP call reply dropped server={s} transport={s} reason=too_large", .{ s.name, @tagName(s.transport) });
                result.ended.why = if (s.transport == .stdio)
                    "its reply was larger than fx reads in one message, so fx restarted the server"
                else
                    "its reply was larger than fx reads in one message, so fx dropped it";
            }
            if (result == .ended and result.ended.outcome == .transport_failed) {
                const down = if (r.enginePhase(index)) |p| p == .backoff or p == .failed else false;
                if (down) result.ended.why = r.failureText(req.alloc, index) catch null;
            }
            // The server sent something fx could not read: a 2xx body that is no JSON-RPC message,
            // or a line that no request named, whose grace ran out. Nothing of it is logged,
            // only its length.
            if (result == .ended and result.ended.outcome == .malformed and (c.refused_body or c.refused_bytes > 0)) {
                const s = r.resolved.servers[index];
                debug_trace.logf("mcp", "MCP call ended server={s} transport={s} code=malformed reason={s} bytes={d}", .{ s.name, @tagName(s.transport), if (c.refused_body) "unreadable_body" else "unreadable_line", c.refused_bytes });
            }
            // A lost call logs its reason and whether the link restarted; an oversized one logged above.
            if (c.outcome == .lost and !c.oversized) {
                const s = r.resolved.servers[index];
                var line_buf: [lost_call_line_max_bytes]u8 = undefined;
                // Every lost call carries its reason; `unknown` would mean a path forgot to set it.
                const why = if (c.lost_why) |w| @tagName(w) else "unknown";
                debug_trace.logf("mcp", "{s}", .{lostCallLine(&line_buf, s.name, @tagName(s.transport), why, c.protocol, c.status, c.restarted)});
            }
            if (r.holdForUrls(index, req, result)) return;
        }
        r.finish(req, .{ .call = result });
    }

    fn onServer(r: *Runtime, i: usize, name: []const u8, event: mcp.server.Event) !void {
        switch (event) {
            .tools => |t| {
                // The sign-in is announced before the listing gives up for it
                // (`src/mcp/auth/client.zig`), so this is the listing that
                // 401 ended.
                if (r.flags[i].relisting) {
                    r.flags[i].relisting = false;
                    if (!t.ok and t.needs_auth) return;
                }
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
                // The request that checks a new login: what the server says to
                // the new tokens ends the sign-in. A refusal comes as `auth_required`.
                if (r.confirmingLogin(i)) {
                    if (t.ok) try r.concludeSignIn(i, .accepted) else if (!t.needs_auth) try r.checkFailed(i);
                }
            },
            .failed => |why| if (r.confirmingLogin(i)) switch (why) {
                // The refusal arrives as `auth_required`.
                .needs_auth => {},
                else => try r.checkFailed(i),
            },
            .auth_required => |required| {
                // A new login waits for the answer to its check request: that answer ends the
                // sign-in, before the branch for an unreadable store below can take it.
                if (r.confirmingLogin(i)) {
                    // The server wants more scopes than the new login has: it knew the token.
                    if (required.step_up) try r.concludeSignIn(i, .accepted) else return r.concludeSignIn(i, .{ .refused = reasonOf(required) });
                }
                // The store this fx couldn't read at the start may hold the
                // login: it's read again first. While it still can't be read,
                // a sign-in couldn't be saved either, so the server is down
                // for that reason, not waiting for a sign-in.
                if (!required.step_up and r.store_unread != null) {
                    if (try r.pickUpLogin(i)) {
                        debug_trace.logf("mcp", "MCP saved login read again server={s} reason=the store wasn't read at the start", .{name});
                        r.flags[i].relisting = true;
                        return r.needToolsOf(name);
                    }
                    if (r.store_unread) |err| {
                        r.flags[i].needs_login = true;
                        r.flags[i].signed_in = false;
                        // Why the server refused is kept for when the store reads: the status
                        // says the store can't be read until then.
                        r.flags[i].login.set(reasonOf(required));
                        debug_trace.logf("mcp", "MCP login not asked for server={s} reason=saved logins not read err={s}", .{ name, @errorName(err) });
                        return r.endToolWaiters(i, .failed);
                    }
                }
                r.flags[i].needs_login = true;
                // Only a step-up keeps the login working for what it had;
                // otherwise the saved one, if any, doesn't sign anything in.
                if (!required.step_up) r.flags[i].signed_in = false;
                const reason = reasonOf(required);
                r.flags[i].login.set(reason);
                if (required.refused) |refused| {
                    debug_trace.logf("mcp", "MCP login dropped server={s} reason=refresh refused status={d} error={s}", .{ name, refused.status, refused.code });
                } else if (required.rejected) |rejected| {
                    debug_trace.logf("mcp", "MCP login refused server={s} reason=server refused the saved login status={d} error={s}", .{ name, rejected.status, logCode(rejected.code) });
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
                // The engine holds the new tokens, unsaved. The server hasn't
                // taken them yet: it is asked, and its answer ends the sign-in.
                const l = r.loginFor(i) orelse {
                    try r.saveCredential(i);
                    r.flags[i] = .{ .signed_in = true };
                    return r.notify(.{ .signed_in = name });
                };
                l.confirming = true;
                l.deadline_ms = r.nowMs() + confirm_wait_ms;
                // A list kept from an earlier login would answer without asking.
                r.reconnectOf(name) catch |err| {
                    debug_trace.logf("mcp", "MCP login check not sent server={s} err={s}", .{ name, @errorName(err) });
                    try r.concludeSignIn(i, .unchecked);
                };
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
            // A new login's tokens are saved once the server has taken them
            // (`concludeSignIn`); a refresh meanwhile is saved with them.
            .credential => if (!r.confirmingLogin(i)) try r.saveCredential(i),
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
                        return r.answerOn(name, x.id, cancel);
                    };
                    const json = try r.gpa.print("{{\"elicitation\":{{\"method\":\"elicitation/create\",\"params\":{s}}}}}", .{x.params});
                    var pending: Pending = .{ .name = r.resolved.servers[i].name, .server = r.ids[i], .json = json, .version = r.versionCopy(i), .reply = .{ .elicit = x.id } };
                    if (!r.offer(req, pending)) {
                        pending.deinit(r.gpa);
                        return r.answerOn(name, x.id, cancel);
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
        const parsed = json_decode.parseFromSlice([]const u8, r.gpa, raw, .{}) catch |err| switch (err) {
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
            if (!need.dropped and !need.seen) r.answerOn(name, need.id, .{ .action = .cancel }) catch {};
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
        const handle_ = try r.callOnServer(r.resolved.servers[i].name, c.tool, c.arguments);
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
            // A question this session can no longer show is answered with a
            // cancel; say when that answer didn't go, since the server keeps
            // the slot until it is.
            r.answerOn(r.resolved.servers[i].name, q.need.id, .{ .action = .cancel }) catch |err| {
                debug_trace.logf("mcp", "MCP required question cancel not sent server={s} err={s}", .{ r.resolved.servers[i].name, @errorName(err) });
            };
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
            // A refresh's save is its last step under the refresh lock.
            for (r.refreshes.items) |*f| if (f.server == i) if (f.lock) |*l| l.restamp();
            if (r.ensureCredentialStore().put(r.gpa, s.credentialKey(), out.written())) {
                // Only a saved login is this process's own; one that wasn't
                // leaves the store's as it was, for a refusal to remove.
                r.flags[i].tried = credentials.digest(out.written());
                r.flags[i].not_saved = false;
            } else |err| {
                debug_trace.logf("mcp", "MCP credential not saved server={s} err={s}", .{ s.name, @errorName(err) });
                if (r.flags[i].not_saved) return;
                r.flags[i].not_saved = true;
                var buf: [320]u8 = undefined;
                r.notify(.{ .not_saved = .{ .server = s.name, .reason = r.ensureCredentialStore().writeFailure(&buf, err) } });
            }
        } else {
            // The tokens are gone, so this process is signed out whatever
            // the store holds.
            r.flags[i].signed_in = false;
            const own = r.flags[i].tried orelse return debug_trace.logf("mcp", "MCP login dropped server={s} saved=none", .{s.name});
            // Only this process's own login goes: one another fx saved since
            // stays, for the next request to take.
            const removed = r.ensureCredentialStore().removeIfSame(r.gpa, s.credentialKey(), own) catch |err| {
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
        const next = try config.resolve(s, configs, inherited, r.options.workspace_root, io_mod.homeDir());
        const n = next.servers.len;
        const routing = r.options.share != null and r.shared != null;
        // What a caller reads after the reload: the servers, and which kept running.
        const arena = r.arena.allocator();
        const kept_servers = try config.keepServers(arena, next.servers, r.resolved.servers);
        const shared = try arena.dupe(bool, next.shared);
        // With sharing, the runtime keeps the configs the local engine runs,
        // and each shared server's own config goes to the owner.
        const kept_next_engine: []mcp.engine.Config = if (routing) try config.keepEngineConfigs(arena, next.engine) else &.{};
        const kept = try arena.alloc(bool, n);
        @memset(kept, false);
        const kept_shared = try s.alloc(bool, n);
        @memset(kept_shared, false);
        var dropped = false;
        // The configs the local engine takes after the reload, and the server
        // each of its slots runs.
        var local_configs: std.ArrayList(mcp.engine.Config) = .empty;
        defer local_configs.deinit(s);
        var local_servers: std.ArrayList(usize) = .empty;
        defer local_servers.deinit(s);
        if (routing) {
            const sh = &r.shared.?;
            // A shared server keeps its slot while its name and launch config
            // are the same.
            for (next.servers, 0..) |server, j| {
                if (!next.shared[j]) continue;
                const key = sh.keyOf(server.name) orelse continue;
                const c = kept_next_engine[std.mem.findScalar(usize, next.engine_server, j) orelse continue];
                if (std.mem.eql(u8, &key, &share_key.of(c))) kept_shared[j] = true;
            }
            // Any other slot goes: its key changed, it was removed, or it is
            // no longer shared. Its calls end as cancelled through the
            // adapter, a tool list asked of it is asked again, and the owner
            // drops this session from the key, so a server no other session
            // holds stops now.
            var k: usize = sh.slots.items.len;
            while (k > 0) {
                k -= 1;
                const slot = sh.slots.items[k];
                var keep = false;
                for (next.servers, kept_shared) |server, keep_now| {
                    if (keep_now and std.mem.eql(u8, server.name, slot.name)) keep = true;
                }
                if (keep) continue;
                if (r.serverIndex(slot.name)) |old| {
                    r.requeueToolWaiters(old);
                    r.endServerQuestions(old);
                }
                dropped = true;
                sh.remove(slot.name);
            }
            for (kept_next_engine, next.engine_server) |c, j| {
                if (next.shared[j]) continue;
                try local_configs.append(s, c);
                try local_servers.append(s, j);
            }
            for (kept_next_engine, next.engine_server) |c, j| kept[j] = if (next.shared[j]) kept_shared[j] else r.engine.keeps(c);
            // A shared server that had no slot, or lost it, registers again
            // here; registering with the owner waits for its first use.
            for (kept_next_engine, next.engine_server) |c, j| {
                if (!next.shared[j] or kept_shared[j]) continue;
                try sh.add(kept_servers[j].name, c);
            }
        } else {
            try local_configs.appendSlice(s, next.engine);
            try local_servers.appendSlice(s, next.engine_server);
            for (next.engine, next.engine_server) |c, j| kept[j] = r.engine.keeps(c);
        }
        const engine_server = try arena.dupe(usize, local_servers.items);
        const engine_configs: []mcp.engine.Config = if (routing) try arena.dupe(mcp.engine.Config, local_configs.items) else &.{};
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

        for (r.resolved.engine_server) |i| if (to[i] == null) {
            dropped = true;
            r.dropServer(i, next.servers);
        };
        // The engine copies what it keeps; the rest goes with `scratch`.
        try r.engine.reload(local_configs.items);
        r.moveServers(to);
        r.mutex.lockUncancelable(r.io);
        const old_flags = r.flags;
        const old_ids = r.ids;
        const old_epochs = r.tools_epochs;
        r.resolved = .{ .servers = kept_servers, .shared = shared, .engine = engine_configs, .engine_server = engine_server };
        r.flags = flags;
        r.ids = ids;
        r.tools_epochs = epochs;
        r.mutex.unlock(r.io);
        // Other threads read the epochs only under `mutex`.
        r.gpa.free(old_flags);
        r.gpa.free(old_ids);
        r.gpa.free(old_epochs);
        var added: usize = 0;
        if (routing) {
            for (from, next.servers) |f, server| {
                if (f == null and server.held == null) added += 1;
            }
        } else {
            for (next.engine_server) |j| {
                if (from[j] == null) added += 1;
            }
        }
        for (engine_server) |j| if (from[j] == null) r.adoptSaved(j);
        var same: usize = 0;
        for (kept) |k| same += @intFromBool(k);
        debug_trace.logf("mcp", "MCP config reloaded servers={d} kept={d} fresh={d} dropped={s}", .{ n, same, added, if (dropped) "yes" else "no" });
        return .{ .kept = kept, .dropped = dropped };
    }

    /// A tool list asked of server `i` is asked again: whatever has its name
    /// after the reload answers, in the engine or in the owner.
    fn requeueToolWaiters(r: *Runtime, i: usize) void {
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
                .maybe_ran = r.callSentOf(waiting.handle),
                .timed_out = false,
                .why = "the MCP config changed, and fx stopped the server",
            } } });
        }
        r.requeueToolWaiters(i);
        if (r.loginFor(i) != null) {
            var buf: [320]u8 = undefined;
            const reason = if (successor != null and successor.?.held == null)
                std.mem.print(&buf, "the MCP config changed before the browser came back; run /mcp login {s} again", .{name}) catch "the MCP config changed before the browser came back"
            else
                "the MCP config changed before the browser came back";
            r.notify(.{ .sign_in_failed = .{ .server = name, .reason = reason } });
            r.endLogin(i);
        }
        var k: usize = 0;
        while (k < r.logouts.items.len) {
            const l = r.logouts.items[k];
            if (l.server != i) {
                k += 1;
                continue;
            }
            _ = r.logouts.swapRemove(k);
            r.endLogout(l, false);
        }
        r.endRefresh(i);
        r.endServerQuestions(i);
    }

    /// Server `i` is gone: a call it held for its 2025 URLs ends, and the URL
    /// questions it left end with it.
    fn endServerQuestions(r: *Runtime, i: usize) void {
        var k: usize = 0;
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
    /// `restoreCredentials` does at the start, and a store that can't be
    /// read is noted in `store_unread` the same way.
    fn adoptSaved(r: *Runtime, i: usize) void {
        const s = r.resolved.servers[i];
        if (s.url == null) return;
        const found = r.ensureCredentialStore().lookup(r.gpa, s.credentialKey()) catch |err| {
            if (err != error.OutOfMemory) r.store_unread = err;
            return debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
        };
        r.store_unread = null;
        const saved = found orelse return;
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
        // A shared call still waiting ends as cancelled: the owner is told,
        // and its request ends as a stopped one, like a local call's.
        if (r.shared) |*s| {
            var waiting = r.calls.iterator();
            while (waiting.next()) |entry| if (s.owns(entry.key_ptr.*)) s.cancel(entry.key_ptr.*);
        }
        var it = r.calls.valueIterator();
        while (it.next()) |req| r.finish(req.*, .{ .failed = error.Stopped });
        r.calls.clearRetainingCapacity();
        while (r.held.items.len > 0) r.endHeld(r.held.items[0], .{ .failed = error.Stopped });
        for (r.required.items) |q| r.gpa.free(q.need.params);
        r.required.clearRetainingCapacity();
        for (r.tool_waiters.items) |w| r.finish(w.request, .{ .failed = error.Stopped });
        r.tool_waiters.clearRetainingCapacity();
        for (r.logouts.items) |l| r.endLogout(l, false);
        r.logouts.clearRetainingCapacity();
        for (r.refreshes.items) |*f| if (f.lock) |*l| l.release();
        r.refreshes.clearRetainingCapacity();
        // Requests queued after the last drain.
        _ = r.drain();
        r.flush();
        // Before the engine: the adapter's reader thread wakes it.
        if (r.shared) |*s| s.deinit();
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
            const st = r.statusOf(i) orelse continue;
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
            // A shared server runs in the owner, which keeps no sign-in state
            // for this session: a login there belongs to no session.
            const on_owner = if (r.shared) |*sh| sh.has(s.name) else false;
            if (!on_owner) {
                o.needs_login = r.flags[i].needs_login;
                o.signed_in = r.flags[i].signed_in;
                o.signing_in = r.loginFor(i) != null;
                if (try r.unreadText(a, i)) |why| {
                    o.state = .failed;
                    o.needs_login = false;
                    o.last_error = why;
                }
                if (o.needs_login) {
                    o.reason = try login_words.copy(a, r.flags[i].login.view());
                    // A refused login is what `last_error` says, for every surface that shows it.
                    if (try login_words.errorText(a, s.name, o.reason)) |text| o.last_error = text;
                }
            }
            // The engine lends the words until its next refusal.
            if (o.state == .ready and !o.needs_login) {
                o.tools_error = if (st.list_refusal) |words| try a.dupe(u8, words) else null;
                o.tools_unavailable = if (o.tools_error != null) st.list_unavailable else 0;
            }
            if (o.state == .ready) {
                o.dropped = st.dropped;
                o.dropped.merge(r.hostDropped(i, s.name));
            }
            if (r.instructionsOf(s.name)) |t| o.instructions = try a.dupe(u8, t);
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
        const version = (r.statusOf(i) orelse return null).version orelse return null;
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

    // ---- which side runs a server ----
    //
    // A shared server runs in the owner (`shared_servers.zig`), not in this
    // runtime's engine, so every engine call it can reach goes through one of
    // these and is sent there instead.

    fn needToolsOf(r: *Runtime, name: []const u8) (engine.Error || shared_servers.Error)!void {
        if (r.shared) |*s| if (s.has(name)) {
            s.needTools(name) catch |err| {
                if (err != error.SharingUnavailable) return err;
                try r.runHere(name);
                return r.engine.needTools(name);
            };
            return;
        };
        return r.engine.needTools(name);
    }

    /// What the host's reading refuses in server `name`'s list now, counted again only when the list changed. A count
    /// that ran out of memory is left for the next snapshot to try again.
    fn hostDropped(r: *Runtime, i: usize, name: []const u8) mcp.tools.Dropped {
        const list = r.toolListOf(name) catch return .{};
        const key = list.fingerprint();
        const flags = &r.flags[i];
        if (flags.dropped_key == key) return flags.dropped_here;
        flags.dropped_here = dropped_tools.count(r.gpa, list) catch |err| {
            debug_trace.logf("mcp", "MCP left-out tools not counted server={s} err={s}", .{ name, @errorName(err) });
            flags.dropped_key = null;
            return .{};
        };
        flags.dropped_key = key;
        return flags.dropped_here;
    }

    fn toolListOf(r: *Runtime, name: []const u8) engine.Error!*const mcp.tools.List {
        if (r.shared) |*s| if (s.has(name)) return s.toolList(name);
        return r.engine.toolList(name);
    }

    fn callOnServer(r: *Runtime, name: []const u8, tool: []const u8, arguments: ?[]const u8) (engine.Error || shared_servers.Error)!engine.Handle {
        if (r.shared) |*s| if (s.has(name)) {
            const handle_ = s.call(name, tool, arguments) catch |err| {
                if (err != error.SharingUnavailable) return err;
                try r.runHere(name);
                return r.engine.call(name, tool, arguments);
            };
            return handle_;
        };
        return r.engine.call(name, tool, arguments);
    }

    fn callSentOf(r: *Runtime, handle_: engine.Handle) bool {
        if (r.shared) |*s| if (s.owns(handle_)) return s.callSent(handle_);
        return r.engine.callSent(handle_);
    }

    fn cancelCall(r: *Runtime, handle_: engine.Handle) engine.Error!void {
        if (r.shared) |*s| if (s.owns(handle_)) return s.cancel(handle_);
        return r.engine.cancel(handle_);
    }

    fn respondCall(r: *Runtime, handle_: engine.Handle, values: []const []const u8) (engine.Error || shared_servers.Error)!void {
        if (r.shared) |*s| if (s.owns(handle_)) return s.respond(r.gpa, handle_, values);
        return r.engine.respond(handle_, values);
    }

    fn answerOn(r: *Runtime, name: []const u8, id: mcp.core.elicitation.Id, answer: mcp.elicitation.Answer) engine.Error!void {
        if (r.shared) |*s| if (s.has(name)) return s.answerElicitation(name, id, answer);
        return r.engine.answerElicitation(name, id, answer);
    }

    /// A server's status, from whichever side runs it; null when this runtime
    /// runs neither (a server held back before it starts).
    fn statusOf(r: *Runtime, i: usize) ?engine.Status {
        const name = r.resolved.servers[i].name;
        if (r.shared) |*s| if (s.has(name)) return s.status(name);
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        return r.engine.status(k);
    }

    fn stderrTailOf(r: *Runtime, i: usize, out: *[mcp.stdio.tail_max]u8) ?[]const u8 {
        const name = r.resolved.servers[i].name;
        if (r.shared) |*s| if (s.has(name)) return s.stderrTail(name, out);
        const k = std.mem.findScalar(usize, r.resolved.engine_server, i) orelse return null;
        return r.engine.stderrTail(k, out);
    }

    fn instructionsOf(r: *Runtime, name: []const u8) ?[]const u8 {
        if (r.shared) |*s| if (s.has(name)) return s.instructions(name);
        return r.engine.instructions(name);
    }

    fn reconnectOf(r: *Runtime, name: []const u8) (engine.Error || shared_servers.Error)!void {
        if (r.shared) |*s| if (s.has(name)) return s.reconnect(name);
        return r.engine.reconnect(name);
    }

    /// The owner cannot run server `name` after all: it moves into this
    /// session's engine with the config it registered, and stays there until
    /// the next reload. The request that met the failure then runs here, so
    /// its caller never sees the owner's.
    fn runHere(r: *Runtime, name: []const u8) !void {
        const s = if (r.shared) |*sh| sh else return error.SharingUnavailable;
        const config_ = s.configOf(name) orelse return error.SharingUnavailable;
        const i = r.serverIndex(name) orelse return error.SharingUnavailable;
        var configs: std.ArrayList(mcp.engine.Config) = .empty;
        defer configs.deinit(r.gpa);
        try configs.appendSlice(r.gpa, r.resolved.engine);
        try configs.append(r.gpa, config_);
        var server_indexes: std.ArrayList(usize) = .empty;
        defer server_indexes.deinit(r.gpa);
        try server_indexes.appendSlice(r.gpa, r.resolved.engine_server);
        try server_indexes.append(r.gpa, i);
        // The engine copies what it keeps, so a reload that fails changes
        // nothing here and the slot stays for the next try.
        try r.engine.reload(configs.items);
        _ = s.remove(name);
        const arena = r.arena.allocator();
        const engine_configs = try arena.dupe(mcp.engine.Config, configs.items);
        const engine_servers = try arena.dupe(usize, server_indexes.items);
        r.mutex.lockUncancelable(r.io);
        r.resolved.engine = engine_configs;
        r.resolved.engine_server = engine_servers;
        r.mutex.unlock(r.io);
        debug_trace.logf("mcp", "MCP server runs in this session server={s} reason=owner unavailable", .{name});
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

    fn enginePhase(r: *Runtime, i: usize) ?engine.Phase {
        return if (r.statusOf(i)) |st| st.phase else null;
    }

    fn lastError(r: *Runtime, alloc: Allocator, i: usize) Allocator.Error![]u8 {
        if (try r.unreadText(alloc, i)) |why| return why;
        if (try r.failureText(alloc, i)) |why| return why;
        return (try r.refusalText(alloc, i)) orelse try alloc.dupe(u8, "the server is unavailable");
    }

    /// Why fx refused server `i`'s last tool list, in `alloc`: the words `Status.tools_error` has, so a screen, a
    /// status and what the model is told all give one reason. Null when it refused none. A failure of the server
    /// (`failureText`) is said first: it is down, whatever its list was.
    fn refusalText(r: *Runtime, alloc: Allocator, i: usize) Allocator.Error!?[]u8 {
        const st = r.statusOf(i) orelse return null;
        // The engine lends the words until its next refusal.
        return if (st.list_refusal) |words| try alloc.dupe(u8, words) else null;
    }

    /// Why server `i` has no login, in `alloc`, when that's because the
    /// store of saved logins couldn't be read; null otherwise. Such a server
    /// isn't asked to sign in: it's down until the store reads.
    fn unreadText(r: *const Runtime, alloc: Allocator, i: usize) Allocator.Error!?[]u8 {
        const err = r.store_unread orelse return null;
        if (!r.flags[i].needs_login) return null;
        const store = switch (r.options.credentials) {
            .store => |s| s,
            .detect => return null,
        };
        var buffer: [256]u8 = undefined;
        return try alloc.dupe(u8, store.readFailure(&buffer, err));
    }

    /// Why server `i` is down, in `alloc`, with what its process said when
    /// it ran over stdio: how it ended, the stdout line it wrote instead of
    /// MCP, and its last stderr lines. Null with no failure.
    fn failureText(r: *Runtime, alloc: Allocator, i: usize) Allocator.Error!?[]u8 {
        const st = r.statusOf(i) orelse return null;
        const why = st.last_error orelse return null;
        var tail_buf: [mcp.stdio.tail_max]u8 = undefined;
        const tail = r.stderrTailOf(i, &tail_buf);
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
        const list = r.toolListOf(name) catch return &.{};
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
        // Only HTTP servers sign in, and a shared server is stdio: the
        // transport decides first, so this is never an assert.
        if (s.transport != .http or s.held != null or r.loginFor(i) != null) return false;
        if (!try r.takeSaved(i)) return false;
        // A new login was just refused: the saved login back in use is the one from before it.
        // That is no sign-in, and "Signed in to NAME." after "Couldn't sign in to NAME" would be
        // false. A login another fx saved within `refusal_pickup_ms` of it is taken the same way,
        // without the notice; one saved later is a new login, and is announced.
        const after_refusal = refusalRecent(r.flags[i].refused_new_ms, r.nowMs());
        r.flags[i].needs_login = false;
        r.flags[i].login.clear();
        r.flags[i].signed_in = true;
        r.flags[i].refused_new_ms = null;
        if (after_refusal) {
            debug_trace.logf("mcp", "MCP saved login taken again after a refused new login server={s}", .{s.name});
            return true;
        }
        debug_trace.logf("mcp", "MCP login saved by another fx taken server={s}", .{s.name});
        r.notify(.{ .signed_in = s.name });
        return true;
    }

    /// Server `i`'s refresh is due. One left over, whose end was
    /// dropped, goes first: a server refreshes once at a time.
    fn refreshDue(r: *Runtime, i: usize) !void {
        r.endRefresh(i);
        try r.refreshes.append(r.gpa, .{ .server = i, .started_ms = r.nowMs() });
        try r.tryRefresh(&r.refreshes.items[r.refreshes.items.len - 1]);
    }

    /// Under the login's refresh lock, one fx refreshes it at a time: this one
    /// takes the login another fx saved meanwhile, or refreshes its own. It
    /// waits for as long as the fx holding the lock is still refreshing;
    /// behind one that stopped (ctrl+z), or without the lock at all, it
    /// refreshes anyway.
    fn tryRefresh(r: *Runtime, f: *Refresh) !void {
        const s = r.resolved.servers[f.server];
        const store = r.ensureCredentialStore();
        if (store.tryRefreshLock(s.credentialKey())) |maybe| {
            if (maybe) |lock| {
                f.lock = lock;
            } else if (!store.refreshHolderStopped(s.credentialKey(), f.started_ms, refresh_answer_ms)) {
                return;
            } else debug_trace.logf("mcp", "MCP refresh went ahead server={s} reason=another fx stopped refreshing started={d} at={d}", .{ s.name, f.started_ms, r.nowMs() });
        } else |err| debug_trace.logf("mcp", "MCP refresh went ahead server={s} reason=no refresh lock err={s}", .{ s.name, @errorName(err) });
        f.sent = true;
        const saved = store.lookup(r.gpa, s.credentialKey()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Whether it's still saved can't be told, so it's refreshed as before.
            else => {
                debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                return r.sendRefresh(f);
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
        try r.sendRefresh(f);
    }

    /// Sends `f`'s refresh, stamping its refresh lock first: the answer comes
    /// within `refresh_answer_ms` of the stamp.
    fn sendRefresh(r: *Runtime, f: *Refresh) !void {
        if (f.lock) |*l| l.restamp();
        try r.engine.refresh(r.resolved.servers[f.server].name);
    }

    /// Keeps the sign-out of the login server `i` holds now, which its next
    /// `signOut` revokes. Returns the kept token, owned, or null when nothing
    /// was kept.
    fn keepHeldSignOut(r: *Runtime, i: usize) !?[]u8 {
        const s = r.resolved.servers[i];
        var out: std.Io.Writer.Allocating = .init(r.gpa);
        defer {
            std.crypto.secureZero(u8, out.writer.buffer);
            out.deinit();
        }
        if (!try r.engine.writeSignOutCredential(s.name, &out.writer)) return null;
        return r.keepSignOut(out.written(), s.url.?);
    }

    /// Keeps the sign-out of `saved`, a login of the server at `url`, before
    /// its revocation is sent. Returns the kept token, owned, or null when
    /// it revokes nothing or wasn't kept; the debug trace says why.
    fn keepSignOut(r: *Runtime, saved: []const u8, url: []const u8) ?[]u8 {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        const found = kept_sign_outs.tokensOf(arena.allocator(), saved, url) catch |err| {
            debug_trace.logf("mcp", "MCP sign-out not kept err={s}", .{@errorName(err)});
            return null;
        };
        const tokens = found orelse {
            debug_trace.logf("mcp", "MCP sign-out not kept reason=its login has no revocation endpoint fx may use", .{});
            return null;
        };
        if (!kept_sign_outs.keep(r.gpa, r.ensureCredentialStore(), tokens)) return null;
        return r.gpa.dupe(u8, tokens.refresh_token) catch {
            // It stays kept, and a later retry revokes it.
            debug_trace.logf("mcp", "MCP kept sign-out not tracked reason=out of memory", .{});
            return null;
        };
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
        const saved = r.ensureCredentialStore().lookup(r.gpa, s.credentialKey()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("mcp", "MCP saved login not read server={s} err={s}", .{ s.name, @errorName(err) });
                if (r.store_unread != null) r.store_unread = err;
                return false;
            },
        };
        r.store_unread = null;
        const c = saved orelse return false;
        defer secret.zeroAndFree(r.gpa, c);
        return r.take(i, c);
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

    fn hasHttpServer(r: *const Runtime) bool {
        for (r.resolved.engine_server) |i| {
            if (r.resolved.servers[i].url != null) return true;
        }
        return false;
    }

    fn ensureCredentialStore(r: *Runtime) credentials.Store {
        switch (r.options.credentials) {
            .store => |s| return s,
            .detect => |home| {
                const store = credentials.Store.detect(r.gpa, home);
                r.options.credentials = .{ .store = store };
                return store;
            },
        }
    }

    /// Before any request: picks the store when `start` left that to the
    /// owner, reads it once, and gives each HTTP server the login saved
    /// under its key, so no server starts without it. Stdio-only configs
    /// skip detection and snapshotting completely until an HTTP server is
    /// added via reload (`ensureCredentialStore`). A store that can't be
    /// read leaves every server signed out, and `store_unread` says why.
    fn restoreCredentials(r: *Runtime) void {
        defer r.credentials_restored.set(r.io);
        if (!r.hasHttpServer()) return;
        const store = r.ensureCredentialStore();
        var saved = store.snapshot(r.gpa) catch |err| {
            debug_trace.logf("mcp", "MCP credentials not loaded err={s}", .{@errorName(err)});
            r.store_unread = err;
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

/// Wakes the runtime's owner thread when the owner client has a frame.
fn wakeEngine(context: *anyopaque) void {
    const r: *Runtime = @ptrCast(@alignCast(context));
    r.engine.wake();
}

/// The client capabilities that declare `questions`.
fn declaredCapabilities(questions: elicitation.Capabilities) []const u8 {
    if (questions.form and questions.url) return "{\"elicitation\":{\"form\":{},\"url\":{}}}";
    if (questions.form) return "{\"elicitation\":{\"form\":{}}}";
    if (questions.url) return "{\"elicitation\":{\"url\":{}}}";
    return "{}";
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

test "a saved login taken back counts as the one from before a refusal only for a moment after it" {
    try std.testing.expect(!refusalRecent(null, 1_000_000));
    try std.testing.expect(refusalRecent(5_000, 5_000));
    try std.testing.expect(refusalRecent(5_000, 5_000 + refusal_pickup_ms));
    try std.testing.expect(!refusalRecent(5_000, 5_000 + refusal_pickup_ms + 1));
    // Hours later, a login another fx saved is a new login.
    try std.testing.expect(!refusalRecent(5_000, 5_000 + 3 * 60 * 60 * 1000));
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

/// Whether a new login that was refused at `refused_ms` was refused a moment ago, so that the saved
/// login taken back now is the one from before it (`refusal_pickup_ms`). Never, for no refusal.
fn refusalRecent(refused_ms: ?i64, now_ms: i64) bool {
    const at = refused_ms orelse return false;
    return now_ms - at <= refusal_pickup_ms;
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

/// The answers to a call's input requests, in the order of `keys` (JSON
/// string tokens); null when one is missing or the answers aren't an object.
fn inputValues(a: Allocator, json: []const u8, keys: []const []const u8) ?[]const []const u8 {
    const answers = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .parse_numbers = false }) catch return null;
    if (answers != .object) return null;
    const values = a.alloc([]const u8, keys.len) catch return null;
    for (keys, values) |token, *value| {
        const key = json_decode.parseFromSliceLeaky([]const u8, a, token, .{}) catch return null;
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

/// The most bytes of a server's error data the model sees. When the data's
/// compact JSON text fits, the model sees that text. Otherwise it sees one JSON
/// string literal: a prefix of the data, then a marker. The literal's quotes
/// and the prefix as it is written, with escapes, take at most `data_cap`
/// bytes, so the whole literal is at most `data_cap` plus the marker, and the
/// marker is at most `data_marker_max` bytes. The cut falls where a character
/// ends, and keeps as much as fits: one more character would not. Nothing later
/// in the path changes these lengths: `sanitizeModelText` leaves text with no NUL
/// byte and valid UTF-8 as it is, and core's JSON round trip leaves both forms as
/// they are, because the host writes the compact text and the escapes with
/// `std.json` itself (a round trip of the raw text would grow `1e-300` from 6
/// bytes to 302). Data the host cannot read safely is left out.
/// (`tests/tla/mcp_host/ErrorData.tla` `Bounded`, `KeepsMost` and `CutOnBoundary`)
const data_cap = 8 * 1024;
const data_marker_max = 64;
/// Data longer than this is cut without being read; its marker names its length.
const data_parse_max = 2 * data_cap;
/// The most bytes of the compact text the host holds at once: the cut needs the first
/// `data_cap` bytes of it, and this leaves the same again for a character that ends past them.
const data_hold_max = 2 * data_cap;
/// Data nested deeper than this is left out: `std.json` keeps the nesting of what it
/// writes in a stack of 256 levels and core writes the data again, so the 2,000
/// levels the engine reads would crash fx.
const data_depth_max = 128;

/// The host's copy of a server's error data, bounded as `data_cap` says and
/// allocated in `alloc`; null when there is none to keep, or the data is left out:
/// it is null, nested past `data_depth_max`, or not text. `scratch` holds the parse
/// of data short enough to read, and is empty again on return. Of the compact text
/// it never holds more than `data_hold_max` bytes: the rest is counted, not kept.
fn boundErrorData(scratch: Allocator, alloc: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, raw, "null")) return null;
    if (raw.len > data_parse_max) return try cutErrorData(alloc, raw, raw.len);
    var arena: std.heap.ArenaAllocator = .init(scratch);
    defer arena.deinit();
    var held: [data_hold_max]u8 = undefined;
    const compact = (try compactText(arena.allocator(), raw, &held)) orelse {
        debug_trace.logf("mcp", "MCP error data left out reason=unreadable bytes={d}", .{raw.len});
        return null;
    };
    if (compact.len <= data_cap) return try alloc.dupe(u8, compact.head);
    return try cutErrorData(alloc, compact.head, compact.len);
}

/// The data written as `std.json` writes it with no spaces: its first bytes, as many as fit
/// `buffer`, and the length of the whole text.
const CompactText = struct { head: []const u8, len: usize };

/// The compact text of `raw`, or null when it is nested past `data_depth_max` or is not JSON.
/// The parse is in `a`. The text is written twice into writers that keep nothing of it
/// beyond `buffer`: once to count its length, once to fill `buffer` until it is full. A compact
/// text can be 47 times as long as the data (`5e-324` is 6 bytes and writes 47), so it is never held whole.
fn compactText(a: Allocator, raw: []const u8, buffer: []u8) Allocator.Error!?CompactText {
    if (json_depth.exceedsDepth(raw, data_depth_max)) return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var counted: std.Io.Writer.Discarding = .init(&.{});
    std.json.Stringify.value(value, .{}, &counted.writer) catch return error.OutOfMemory;
    var held: std.Io.Writer = .fixed(buffer);
    std.json.Stringify.value(value, .{}, &held) catch |err| switch (err) {
        error.WriteFailed => {}, // `buffer` is full: the rest is only counted
    };
    return .{ .head = held.buffered(), .len = @intCast(counted.fullCount()) };
}

/// The bytes `std.json` writes for one character of a string.
fn escapedCost(char: []const u8) usize {
    if (char.len > 1) return char.len;
    return switch (char[0]) {
        '"', '\\', 0x08, 0x09, 0x0a, 0x0c, 0x0d => 2,
        0x00...0x07, 0x0b, 0x0e...0x1f => 6,
        else => 1,
    };
}

/// A JSON string literal: the longest prefix of `text` that fits `data_cap`
/// with its quotes and escapes and ends where a character ends, then the marker,
/// which names `total` bytes, how long the whole text is. `text` is the whole text,
/// or its first bytes, at least `data_cap` of them, and the whole text is longer than `data_cap`.
fn cutErrorData(alloc: Allocator, text: []const u8, total: usize) Allocator.Error!?[]const u8 {
    const budget = data_cap - 2;
    var end: usize = 0;
    var used: usize = 0;
    while (end < text.len) {
        const width = @min(std.unicode.utf8ByteSequenceLength(text[end]) catch 1, text.len - end);
        const cost = escapedCost(text[end..][0..width]);
        if (used + cost > budget) break;
        used += cost;
        end += width;
    }
    const prefix = text[0..end];
    if (!std.unicode.utf8ValidateSlice(prefix)) {
        debug_trace.logf("mcp", "MCP error data left out reason=not_utf8 bytes={d}", .{text.len});
        return null;
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeByte('"') catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonStringChars(prefix, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.print(" ... [data truncated: {d} bytes, cap is {d}]\"", .{ total, data_cap }) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

/// Room for one `MCP call lost` line; a longer one is cut.
const lost_call_line_max_bytes: usize = 512;

/// The `MCP call lost` line: names, enum tags, numbers, and a flag, never content.
fn lostCallLine(buf: []u8, server: []const u8, transport: []const u8, why: []const u8, protocol: ?[]const u8, status: u16, restarted: bool) []const u8 {
    var out = std.Io.Writer.fixed(buf);
    // A name too long for `buf` cuts the line; what fits is still written.
    out.print("MCP call lost server={s} transport={s} why={s} protocol={s} status={d} restarted={}", .{ server, transport, why, protocol orelse "none", status, restarted }) catch {};
    return out.buffered();
}

fn copyCall(scratch: Allocator, alloc: Allocator, c: anytype) Allocator.Error!CallResult {
    const answer = c.answer orelse return .{ .ended = .{ .outcome = c.outcome, .maybe_ran = c.maybe_ran, .timed_out = c.timed_out } };
    return switch (answer) {
        .result => |res| .{ .result = .{
            .content = try alloc.dupe(u8, res.content),
            .structured = if (res.structured) |s| try alloc.dupe(u8, s) else null,
            .is_error = res.is_error,
        } },
        .failure => |f| .{
            .failure = .{
                .code = f.code,
                .message = try alloc.dupe(u8, f.message),
                // A -32042 lists URLs for the user to answer, through the questions the engine hands
                // the host while it holds the call (`tests/tla/mcp_host/UrlRetry.tla`): the model
                // gets that answer's words as before. A null data says nothing.
                .data = if (f.code == url_elicitation_required) null else if (f.data) |data| try boundErrorData(scratch, alloc, data) else null,
            },
        },
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
const owner = @import("owner.zig");

/// A short fx home for a shared server test: the owner's socket path must fit
/// a Unix address.
fn sharedHome(tag: []const u8) ![]u8 {
    const path = try testing.allocator.print("/tmp/fx-rt-shared-{s}-{d}", .{ tag, std.c.getpid() });
    removeTestDir(path);
    try std.Io.Dir.cwd().createDir(testing.io, path, .fromMode(0o700));
    return path;
}

/// Removes a test's folder. Cleanup only: a folder that won't go leaves
/// nothing the test asserts on, and the system clears /tmp.
fn removeTestDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(testing.io, path) catch {}; // Cleanup only: nothing the test asserts on depends on the folder.
}

fn freeSharedHome(home: []u8) void {
    removeTestDir(home);
    testing.allocator.free(home);
}

fn serveOwner(io: std.Io, gpa: Allocator, home: []const u8, stop: *std.atomic.Value(bool)) void {
    // An owner that ends with an error is what a test's stop asks for; the
    // test fails on the state it checks, not on this thread.
    owner.serve(io, gpa, home, stop, owner.test_client_version) catch {};
}

/// Waits until an owner answers on `home`'s socket.
fn waitForOwner(home: []const u8) !void {
    const path = try std.Io.Dir.path.join(testing.allocator, &.{ home, owner.run_dir_name, owner.socket_name });
    defer testing.allocator.free(path);
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        const address = std.Io.net.UnixAddress.init(path) catch return error.OwnerSocketNeverAppeared;
        if (address.connect(testing.io)) |stream| {
            stream.close(testing.io);
            return;
        } else |_| {
            // Polls for the socket the test's owner thread is opening.
            try testing.io.sleep(.fromMilliseconds(20), .awake);
        }
    }
    return error.OwnerSocketNeverAppeared;
}

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

/// A 2025 server in sh whose first tool list is good and followed by `list_changed`. Every later list is no list
/// (`tools` is a number), until the file `<server>.fixed` exists, and then it is good again.
const refusing_server_script =
    \\#!/bin/sh
    \\n=0
    \\while IFS= read -r line; do
    \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"method":"server/discover"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
    \\    *'"method":"tools/list"'*)
    \\      n=$((n + 1))
    \\      if [ "$n" -gt 1 ] && [ ! -e "$0.fixed" ]; then
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":7}}\n' "$id"
    \\      else
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echoes","inputSchema":{"type":"object"}}]}}\n' "$id"
    \\        if [ "$n" = 1 ]; then printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n'; fi
    \\      fi ;;
    \\  esac
    \\done
    \\
;

/// A 2025 server in sh whose every tool list is no list (`tools` is a number).
const always_refusing_server_script =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"method":"server/discover"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
    \\    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":7}}\n' "$id" ;;
    \\  esac
    \\done
    \\
;

/// Asks for server `fake`'s tools until its status says `want`, for up to thirty seconds: the snapshot follows the engine a moment later,
/// and a loaded machine can take longer. It stops as soon as the status is right.
fn statusAfterListing(r: *Runtime, arena: Allocator, want_refused: bool) !Status {
    var status: Status = undefined;
    for (0..600) |_| {
        _ = try r.tools(arena, "fake", null);
        status = (try r.statuses(arena))[0];
        if ((status.tools_error != null) == want_refused) break;
        // A sleep that ends early only polls sooner, and the loop is bounded.
        std.Io.sleep(testing.io, .fromMilliseconds(50), .awake) catch {};
    }
    return status;
}

/// A 2025 server in sh whose first tool list keeps one tool and has two the host leaves out: a second tool named
/// `echo`, which the engine skips, and one whose `description` is not text, which the host's reading refuses. It then
/// says its tools changed, and every later list keeps all its tools.
const leaving_out_server_script =
    \\#!/bin/sh
    \\n=0
    \\while IFS= read -r line; do
    \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"method":"server/discover"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
    \\    *'"method":"tools/list"'*)
    \\      n=$((n + 1))
    \\      if [ "$n" = 1 ]; then
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echoes","inputSchema":{"type":"object"}},{"name":"echo","inputSchema":{"type":"object"}},{"name":"odd","description":7,"inputSchema":{"type":"object"}}]}}\n' "$id"
    \\        printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n'
    \\      else
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echoes","inputSchema":{"type":"object"}}]}}\n' "$id"
    \\      fi ;;
    \\  esac
    \\done
    \\
;

test "tools fx leaves out of a list show in the status by reason, and a later list that keeps them all clears it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "server", .data = leaving_out_server_script, .flags = .{ .permissions = .executable_file } });
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The engine skipped the second `echo`, and the host's reading refuses `odd`: two tools are left out, for two reasons.
    try testing.expectEqual(@as(usize, 2), (try r.tools(a, "fake", null)).tools.len);
    var status = (try r.statuses(a))[0];
    try testing.expectEqual(State.ready, status.state);
    try testing.expectEqual(@as(usize, 2), status.tools);
    try testing.expectEqual(@as(u32, 2), status.dropped.total());
    try testing.expectEqual(@as(u32, 1), status.dropped.counts[@backingInt(mcp.tools.Drop.repeated_name)]);
    try testing.expectEqual(@as(u32, 1), status.dropped.counts[@backingInt(mcp.tools.Drop.unusable)]);

    // The server says its tools changed: the next list keeps every tool, and the status says nothing is left out.
    for (0..600) |_| {
        _ = try r.tools(a, "fake", null);
        status = (try r.statuses(a))[0];
        if (status.dropped.total() == 0) break;
        // A sleep that ends early only polls sooner, and the loop is bounded.
        std.Io.sleep(testing.io, .fromMilliseconds(50), .awake) catch {};
    }
    try testing.expectEqual(@as(u32, 0), status.dropped.total());
    try testing.expectEqual(@as(usize, 1), status.tools);
}

test "a refused tool list shows in the status beside the older list still served, and a good list clears it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "server", .data = refusing_server_script, .flags = .{ .permissions = .executable_file } });
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The first list is good.
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "fake", null)).tools.len);
    var status = (try r.statuses(a))[0];
    try testing.expectEqual(State.ready, status.state);
    try testing.expect(status.tools_error == null);

    // The server says its tools changed, and its next list is refused: the older one is still served, and the status says both.
    status = try statusAfterListing(&r, a, true);
    try testing.expectEqualStrings("\"tools\" is not a list", status.tools_error orelse return error.TestExpectedRefusal);
    try testing.expectEqual(State.ready, status.state);
    try testing.expectEqual(@as(usize, 1), status.tools);
    // The server is not down, so nothing says so.
    try testing.expect(status.last_error == null);
    // The words are the caller's own copy. The snapshot's words go with its arena at the next publish, so a copy that
    // pointed into them would read freed memory. Overwriting them here stands in for that, every time.
    {
        const own = try r.statusesNow(a);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const held = r.snapshot[0].tools_error orelse return error.TestExpectedRefusal;
        @memset(@constCast(held), 'U');
        try testing.expectEqualStrings("\"tools\" is not a list", own[0].tools_error orelse return error.TestExpectedRefusal);
    }
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "fake", null)).tools.len);

    // The server lists well again: the refused list left the older one stale, so the next need lists again, and the refusal is gone.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "server.fixed", .data = "" });
    status = try statusAfterListing(&r, a, false);
    try testing.expect(status.tools_error == null);
    try testing.expectEqual(@as(usize, 1), status.tools);
}

test "a server whose tool list is refused fails the request for its tools with the refusal's words, as its status says them" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "server", .data = always_refusing_server_script, .flags = .{ .permissions = .executable_file } });
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, f.options());
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The `/mcp` screen, the catalog and `toolbox` all read the words of this failure, so they say what the status says
    // and not that the server is unavailable.
    const why = switch (try r.tools(a, "fake", null)) {
        .failed => |text| text,
        else => return error.TestExpectedFailure,
    };
    try testing.expectEqualStrings("\"tools\" is not a list", why);
    const status = try statusAfterListing(&r, a, true);
    try testing.expectEqualStrings(why, status.tools_error orelse return error.TestExpectedRefusal);
    try testing.expectEqual(@as(usize, 0), status.tools);
    try testing.expectEqual(@as(u16, 0), status.tools_unavailable);
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

/// Whether process `pid` still runs; the engine reaps its servers, so an
/// exited one is gone.
fn running(pid: std.posix.pid_t) !bool {
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return err,
    };
    return true;
}

test "an idle server stops, a tool list comes from the kept list, and the next call starts it again" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.idle_ms = 300;
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "fake", null)).tools.len);
    const first = try std.fmt.parseInt(std.posix.pid_t, try pidOf(&r, a, "fake"), 10);
    // Idle for 300 ms, then the stop: stdin closes and the fake exits.
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (try running(first)) {
        if (std.Io.Clock.awake.now(testing.io).toMilliseconds() > deadline) return error.IdleServerStillRunning;
        // Polls the server process's exit, bounded by the deadline above.
        try testing.io.sleep(.fromMilliseconds(20), .awake);
    }
    try testing.expectEqual(State.idle, (try r.statuses(a))[0].state);

    // A toolbox search asks for every server's tools: the kept list answers,
    // and nothing starts.
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "fake", null)).tools.len);
    try testing.expectEqual(State.idle, (try r.statuses(a))[0].state);

    // The next call starts a new process and gets its answer.
    const second = try std.fmt.parseInt(std.posix.pid_t, try pidOf(&r, a, "fake"), 10);
    try testing.expect(second != first);
    try testing.expectEqual(State.ready, (try r.statuses(a))[0].state);
}

test "a call in flight keeps an idle server up" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.idle_ms = 300;
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pid = try std.fmt.parseInt(std.posix.pid_t, try pidOf(&r, a, "fake"), 10);

    // The fake never answers a call that mentions "slow".
    const Caller = struct {
        fn run(runtime: *Runtime, cancel: *std.atomic.Value(bool), out: *?engine.Outcome) void {
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            const result = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"slow\"}", cancel, null) catch return;
            if (result == .ended) out.* = result.ended.outcome;
        }
    };
    var cancel: std.atomic.Value(bool) = .init(false);
    var outcome: ?engine.Outcome = null;
    const caller = try std.Thread.spawn(.{}, Caller.run, .{ &r, &cancel, &outcome });
    // Well past the idle limit, with the call in flight the whole time. A
    // fixed window is the point: the test proves the server did NOT stop in
    // it, which no event announces.
    try testing.io.sleep(.fromMilliseconds(1500), .awake);
    try testing.expect(try running(pid));
    try testing.expectEqual(State.ready, (try r.statuses(a))[0].state);

    cancel.store(true, .release);
    caller.join();
    try testing.expectEqual(@as(?engine.Outcome, .cancelled), outcome);
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

test "stdio-only MCP startup skips credential store detection and snapshot" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    var options = f.options();
    options.credentials = .{ .detect = f.home };
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try r.statuses(arena.allocator());
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(State.idle, got[0].state);
    try testing.expect(r.options.credentials == .detect);

    const fx_dir = try std.Io.Dir.path.join(arena.allocator(), &.{ f.home, ".fx" });
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, fx_dir, .{}));
}

test "stdio-only MCP startup resolves credential store lazily on HTTP reload without dangling home" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const home_arg = try testing.allocator.dupe(u8, f.home);
    var home_freed = false;
    defer if (!home_freed) testing.allocator.free(home_arg);
    const ws_arg = try testing.allocator.dupe(u8, f.home);
    var ws_freed = false;
    defer if (!ws_freed) testing.allocator.free(ws_arg);

    const before = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var r: Runtime = undefined;
    var options = f.options();
    options.credentials = .{ .detect = home_arg };
    options.workspace_root = ws_arg;
    try r.start(testing.allocator, testing.io, &before, &f.inherited, options);
    defer r.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const initial = try r.statuses(a);
    try testing.expectEqual(@as(usize, 1), initial.len);
    try testing.expect(r.options.credentials == .detect);

    testing.allocator.free(home_arg);
    home_freed = true;
    testing.allocator.free(ws_arg);
    ws_freed = true;

    const after = [_]mcp_contract.McpServerConfig{
        .{ .name = "fake", .command = f.server },
        .{ .name = "web", .transport = .http, .url = "https://web.example.invalid/mcp" },
    };
    _ = try r.reload(&after, &f.inherited);
    const reloaded = try r.statuses(a);
    try testing.expectEqual(@as(usize, 2), reloaded.len);
    try testing.expect(r.options.credentials == .store);
    try testing.expectEqualStrings(f.home, r.options.credentials.store.home);
    try testing.expectEqualStrings("web", reloaded[1].name);
    try testing.expectEqual(State.idle, reloaded[1].state);
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

/// What the engine gives the host when a call ends with a protocol error.
fn failedCall(code: i64, message: []const u8, data: ?[]const u8) struct { answer: ?mcp.tools.Call, outcome: engine.Outcome, maybe_ran: bool, timed_out: bool } {
    return .{
        .answer = .{ .failure = .{ .code = code, .message = message, .data = data } },
        .outcome = .failure,
        .maybe_ran = false,
        .timed_out = false,
    };
}

/// The host's copy of a failure; `testing.allocator` is the scratch, so a leak in it fails the test.
fn keptFailure(a: Allocator, code: i64, data: ?[]const u8) !CallResult {
    return copyCall(testing.allocator, a, failedCall(code, "\"m\"", data));
}

/// What the host reads of `raw`, as the spec says: the data as `std.json` writes it with no spaces,
/// or null when the data is nested past the limit or is not JSON. The text is in `a`.
fn compactOf(a: Allocator, raw: []const u8) ?[]const u8 {
    if (json_depth.exceedsDepth(raw, data_depth_max)) return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return null;
    return std.json.Stringify.valueAlloc(a, value, .{}) catch null;
}

const cut_marker = " ... [data truncated";

/// The bound the model sees, checked on a cut: `held` is one JSON string literal
/// whose quotes and escaped prefix take at most `data_cap` bytes, then a marker of at most
/// `data_marker_max` bytes that names the length of the text it was cut from; the prefix is a
/// prefix of that text that ends where a character ends and is the longest that fits; and that
/// text did not fit whole. The text is `raw` when it is longer than `data_parse_max`, and
/// otherwise the data as the host reads it, `std.json`'s compact writing of it.
fn expectBoundedCut(a: Allocator, raw: []const u8, held: []const u8) !void {
    const source: []const u8 = if (raw.len > data_parse_max) raw else compactOf(a, raw) orelse return error.TestUnexpectedResult;
    try expectCutOf(a, source, held);
}

/// `expectBoundedCut` for a `source` the caller worked out.
fn expectCutOf(a: Allocator, source: []const u8, held: []const u8) !void {
    try testing.expect(source.len > data_cap);
    try testing.expect(std.unicode.utf8ValidateSlice(held));
    const decoded = try json_decode.parseFromSliceLeaky([]const u8, a, held, .{});
    try testing.expect(std.unicode.utf8ValidateSlice(decoded));
    const at = std.mem.find(u8, decoded, cut_marker) orelse return error.TestUnexpectedResult;
    const marker = try a.print("{s}", .{decoded[at..]});
    try testing.expect(marker.len <= data_marker_max);
    try testing.expectEqualStrings(try a.print(" ... [data truncated: {d} bytes, cap is {d}]", .{ source.len, data_cap }), marker);
    // The marker has no escapes, so it is the end of `held` before its closing quote.
    const before = held.len - marker.len;
    try testing.expect(before <= data_cap);
    const prefix = decoded[0..at];
    try testing.expectEqualStrings(source[0..prefix.len], prefix);
    // The longest prefix that fits: the next character would not.
    if (prefix.len < source.len) {
        const width = @min(std.unicode.utf8ByteSequenceLength(source[prefix.len]) catch 1, source.len - prefix.len);
        try testing.expect(before + escapedCost(source[prefix.len..][0..width]) > data_cap);
    }
}

test "copyCall keeps a protocol error's data as compact JSON, whatever its code" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = "{\"errors\":[{\"path\":[\"limit\"]}]}";
    try testing.expectEqualStrings(data, (try keptFailure(a, -32602, data)).failure.data orelse "(dropped)");
    try testing.expectEqualStrings("\"why\"", (try keptFailure(a, -32603, "\"why\"")).failure.data orelse "(dropped)");
    try testing.expectEqualStrings("42", (try keptFailure(a, -32000, "42")).failure.data orelse "(dropped)");
    // The host writes the text the model sees, so what core reads back is the same text.
    try testing.expectEqualStrings("{\"a\":[1,2]}", (try keptFailure(a, -32602, "{ \"a\" : [ 1 , 2 ] }")).failure.data orelse "(dropped)");
    try testing.expectEqualStrings("{\"errors\":[{\"path\":[\"limit\"]}]}", (try keptFailure(a, -32602, "{  \"errors\" : [   { \"path\" : [ \"limit\" ] }   ]  }")).failure.data orelse "(dropped)");
    try testing.expectEqualStrings("\"\u{e9}/\"", (try keptFailure(a, -32602, "\"\\u00e9\\/\"")).failure.data orelse "(dropped)");
}

test "copyCall keeps nothing for an error without data or with null data, and its code and message as they were" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?[]const u8, null), (try keptFailure(a, -32602, null)).failure.data);
    try testing.expectEqual(@as(?[]const u8, null), (try keptFailure(a, -32602, "null")).failure.data);
    const kept = try keptFailure(a, -32602, "{\"errors\":[]}");
    try testing.expectEqual(@as(i64, -32602), kept.failure.code);
    try testing.expectEqualStrings("\"m\"", kept.failure.message);
}

test "copyCall holds data whose compact text is exactly the cap whole, and cuts one byte more" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fit = try a.alloc(u8, data_cap);
    @memset(fit, 'x');
    fit[0] = '"';
    fit[data_cap - 1] = '"';
    try testing.expectEqualStrings(fit, (try keptFailure(a, -32602, fit)).failure.data orelse "(dropped)");
    const over = try a.alloc(u8, data_cap + 1);
    @memset(over, 'x');
    over[0] = '"';
    over[data_cap] = '"';
    try expectBoundedCut(a, over, (try keptFailure(a, -32602, over)).failure.data orelse return error.TestUnexpectedResult);
}

test "copyCall counts escapes against the cap: quotes and backslashes cost two bytes, control bytes six" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A JSON string full of escaped quotes: 10,002 bytes, so it is cut from its own text.
    const quotes = try a.alloc(u8, 2 + 2 * 5000);
    quotes[0] = '"';
    quotes[quotes.len - 1] = '"';
    for (0..5000) |i| {
        quotes[1 + 2 * i] = '\\';
        quotes[2 + 2 * i] = '"';
    }
    const cut = (try keptFailure(a, -32602, quotes)).failure.data orelse return error.TestUnexpectedResult;
    try expectBoundedCut(a, quotes, cut);
    // Every byte of that prefix costs two: it ends exactly at the cap after escaping.
    const decoded = try json_decode.parseFromSliceLeaky([]const u8, a, cut, .{});
    const at = std.mem.find(u8, decoded, cut_marker).?;
    try testing.expectEqual(@as(usize, data_cap - 2), 2 * at);
    // A JSON string of control characters is written with `\u0007`: a backslash costs two, the rest one.
    const bell_text = try a.alloc(u8, 2000);
    @memset(bell_text, 0x07);
    const bells = try std.json.Stringify.valueAlloc(a, bell_text, .{});
    try expectBoundedCut(a, bells, (try keptFailure(a, -32602, bells)).failure.data orelse return error.TestUnexpectedResult);
    // Bytes that no JSON holds are cut without being read when they are long, at the cost of each.
    const raw_bells = try a.alloc(u8, 20000);
    @memset(raw_bells, 0x07);
    try expectBoundedCut(a, raw_bells, (try keptFailure(a, -32602, raw_bells)).failure.data orelse return error.TestUnexpectedResult);
    const mixed = try a.alloc(u8, 20000);
    for (mixed, 0..) |*byte, i| byte.* = "\"\\\x07\n\ta"[i % 6];
    try expectBoundedCut(a, mixed, (try keptFailure(a, -32602, mixed)).failure.data orelse return error.TestUnexpectedResult);
    // The cost of each ASCII byte is what `std.json` writes for it.
    var written: std.Io.Writer.Allocating = .init(a);
    for (0..0x80) |byte| {
        written.clearRetainingCapacity();
        try std.json.Stringify.encodeJsonStringChars(&.{@as(u8, @intCast(byte))}, .{}, &written.writer);
        try testing.expectEqual(written.writer.buffered().len, escapedCost(&.{@as(u8, @intCast(byte))}));
    }
}

test "copyCall cuts data that compacts to more than the cap even when its own text is shorter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `1e-300` is 6 bytes and `std.json` writes it as 302: core's round trip would grow this past
    // its own metadata limit, so the host cuts what the model would see, the compact text.
    const floats = try a.alloc(u8, 7 * 1000);
    for (0..1000) |i| @memcpy(floats[7 * i ..][0..7], "1e-300,");
    floats[floats.len - 1] = ']';
    const raw = try a.print("[{s}", .{floats});
    try testing.expect(raw.len < data_cap);
    try expectBoundedCut(a, raw, (try keptFailure(a, -32602, raw)).failure.data orelse return error.TestUnexpectedResult);
}

/// Counts the bytes an allocator holds at once, to see what a call keeps in its scratch.
const PeakAllocator = struct {
    backing: Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *PeakAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const out = self.backing.rawAlloc(len, alignment, return_address) orelse return null;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        return out;
    }

    // Never grows or shrinks in place, so the peak does not depend on what the backing allocator can do.
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        self.live -= memory.len;
        self.backing.rawFree(memory, alignment, return_address);
    }
};

/// `[5e-324,` and so on to 16,383 bytes: each number is 6 bytes that `std.json` writes as 327.
fn tinyNumbers(a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '[');
    for (0..2340) |_| try out.appendSlice(a, "5e-324,");
    try out.appendSlice(a, "0]");
    return out.items;
}

fn nestedArrays(a: Allocator, depth: usize) ![]const u8 {
    const text = try a.alloc(u8, depth * 2);
    @memset(text[0..depth], '[');
    @memset(text[depth..], ']');
    return text;
}

test "copyCall gives the model what it gave for the hostile data a review sent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 16 KiB of `5e-324` writes as 765,183 bytes: the model gets the cap and a marker that names that length.
    const tiny = try tinyNumbers(a);
    try testing.expectEqual(@as(usize, 16383), tiny.len);
    const tiny_kept = (try keptFailure(a, -32602, tiny)).failure.data orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 8240), tiny_kept.len);
    try testing.expect(std.mem.find(u8, tiny_kept, " ... [data truncated: 765183 bytes, cap is 8192]\"") != null);
    try expectBoundedCut(a, tiny, tiny_kept);
    // 10,000 levels in 20 KB: too long to read, so it is cut as a string of its own text.
    const deep = try nestedArrays(a, 10_000);
    const deep_kept = (try keptFailure(a, -32602, deep)).failure.data orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 8239), deep_kept.len);
    try expectBoundedCut(a, deep, deep_kept);
    // 128 levels are kept as they are, and 129 are left out.
    const at_limit = try nestedArrays(a, 128);
    try testing.expectEqualStrings(at_limit, (try keptFailure(a, -32602, at_limit)).failure.data orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(?[]const u8, null), (try keptFailure(a, -32602, try nestedArrays(a, 129))).failure.data);
}

test "copyCall never holds more than the cap of the compact text, even for the moment of the cut" {
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();
    const tiny = try tinyNumbers(out.allocator());
    // What the parse alone takes of scratch.
    var tree: PeakAllocator = .{ .backing = testing.allocator };
    {
        var arena: std.heap.ArenaAllocator = .init(tree.allocator());
        defer arena.deinit();
        _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), tiny, .{});
    }
    var scratch: PeakAllocator = .{ .backing = testing.allocator };
    const kept = (try boundErrorData(scratch.allocator(), out.allocator(), tiny)).?;
    try expectBoundedCut(out.allocator(), tiny, kept);
    // Empty again on return, and at its fullest the parse tree and at most two caps of text: the compact
    // text is 765,183 bytes, which nothing holds.
    try testing.expectEqual(@as(usize, 0), scratch.live);
    try testing.expect(scratch.peak <= tree.peak + 2 * data_cap);
}

test "copyCall never holds a huge error data whole, and cuts it where a character ends" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const huge = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    huge[0] = '"';
    huge[huge.len - 1] = '"';
    const before = arena.queryCapacity();
    const cut = (try keptFailure(a, -32602, huge)).failure.data orelse return error.TestUnexpectedResult;
    try expectBoundedCut(a, huge, cut);
    try testing.expect(arena.queryCapacity() - before < 64 * 1024);
    // Characters of two, three and four bytes across the cap, at every shift.
    const letters = [_][]const u8{ "\u{e9}", "\u{20ac}", "\u{1f600}" };
    for (letters) |letter| {
        for (0..letter.len) |shift| {
            const wide = try a.alloc(u8, 3 * data_cap);
            wide[0] = '"';
            var at: usize = 1;
            for (0..shift) |_| {
                wide[at] = 'a';
                at += 1;
            }
            while (at + letter.len < wide.len) : (at += letter.len) @memcpy(wide[at..][0..letter.len], letter);
            while (at < wide.len - 1) : (at += 1) wide[at] = 'a';
            wide[wide.len - 1] = '"';
            try expectBoundedCut(a, wide, (try keptFailure(a, -32602, wide)).failure.data orelse return error.TestUnexpectedResult);
        }
    }
}

test "copyCall leaves out data it cannot read safely: not UTF-8, not JSON, or nested past the limit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try a.alloc(u8, 20000);
    @memset(bytes, 0xff);
    try testing.expectEqual(@as(?[]const u8, null), (try keptFailure(a, -32602, bytes)).failure.data);
    try testing.expectEqual(@as(?[]const u8, null), (try keptFailure(a, -32602, bytes[0..100])).failure.data);
    try testing.expectEqual(@as(?[]const u8, null), (try keptFailure(a, -32602, "{\"a\":")).failure.data);
    // At the limit the data is kept whole. One level past it, and at the 1,900 the engine reads, it is left
    // out, since core writing it again would run out of `std.json`'s 256 levels of nesting.
    for ([_]usize{ data_depth_max, data_depth_max + 1, 300, 1900 }) |depth| {
        const nested = try a.alloc(u8, depth * 2);
        @memset(nested[0..depth], '[');
        @memset(nested[depth..], ']');
        const kept = (try keptFailure(a, -32602, nested)).failure.data;
        if (depth <= data_depth_max) {
            try testing.expectEqualStrings(nested, kept orelse "(dropped)");
        } else {
            try testing.expectEqual(@as(?[]const u8, null), kept);
        }
    }
    // Brackets inside a string are not nesting.
    const brackets = try a.alloc(u8, 2 + 400);
    @memset(brackets, '[');
    brackets[0] = '"';
    brackets[brackets.len - 1] = '"';
    try testing.expectEqualStrings(brackets, (try keptFailure(a, -32602, brackets)).failure.data orelse "(dropped)");
}

test "copyCall writes numbers as std.json does, as core's own round trip would, and leaves out a repeated key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("0.1", (try keptFailure(a, -32602, "0.1000000000000000055511151231257827")).failure.data orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("12345678901234567000", (try keptFailure(a, -32602, "12345678901234567890.5")).failure.data orelse return error.TestUnexpectedResult);
    // Valid JSON, but `std.json` refuses a key it already has, so the data cannot be read.
    try testing.expectEqual(@as(?[]const u8, null), (try keptFailure(a, -32602, "{\"a\":1,\"a\":2}")).failure.data);
}

test "copyCall leaves out the data of a -32042 answer: the URLs it lists are the host's to ask about" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const urls = "{\"elicitations\":[{\"mode\":\"url\",\"elicitationId\":\"e1\",\"url\":\"https://example.test/authorize\",\"message\":\"Sign in\"}]}";
    const kept = try keptFailure(a, -32042, urls);
    try testing.expectEqual(@as(i64, -32042), kept.failure.code);
    try testing.expectEqual(@as(?[]const u8, null), kept.failure.data);
}

test "copyCall keeps a successful result and an ended call as they were" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try copyCall(testing.allocator, a, .{
        .answer = @as(?mcp.tools.Call, .{ .result = .{ .content = "[]", .structured = null, .is_error = true } }),
        .outcome = engine.Outcome.result,
        .maybe_ran = false,
        .timed_out = false,
    });
    try testing.expectEqualStrings("[]", ok.result.content);
    try testing.expect(ok.result.is_error);
    const lost = try copyCall(testing.allocator, a, .{
        .answer = @as(?mcp.tools.Call, null),
        .outcome = engine.Outcome.lost,
        .maybe_ran = true,
        .timed_out = false,
    });
    try testing.expectEqual(engine.Outcome.lost, lost.ended.outcome);
}

test "a lost call's trace line names the server, transport, reason, protocol, status, and restart, and nothing else" {
    var buf: [lost_call_line_max_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "MCP call lost server=web transport=http why=stream_broken protocol=2026-07-28 status=0 restarted=false",
        lostCallLine(&buf, "web", "http", "stream_broken", "2026-07-28", 0, false),
    );
    try testing.expectEqualStrings(
        "MCP call lost server=web transport=http why=resume_refused protocol=2025-11-25 status=503 restarted=false",
        lostCallLine(&buf, "web", "http", "resume_refused", "2025-11-25", 503, false),
    );
    try testing.expectEqualStrings(
        "MCP call lost server=local transport=stdio why=link_down protocol=none status=0 restarted=true",
        lostCallLine(&buf, "local", "stdio", "link_down", null, 0, true),
    );
}

test "many failing calls with a huge error data each stay bounded" {
    // A server that answers every call with 300 KB of data must cost the host the
    // cap for each call and no more, and every call still gets its data.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const huge = try testing.allocator.alloc(u8, 300 * 1024);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    huge[0] = '"';
    huge[huge.len - 1] = '"';
    const calls = 200;
    const before = arena.queryCapacity();
    for (0..calls) |_| {
        const cut = (try keptFailure(a, -32602, huge)).failure.data orelse return error.TestUnexpectedResult;
        try testing.expect(cut.len <= data_cap + data_marker_max);
    }
    // Each call holds its cut and the allocator's slack, and nothing of the parse.
    try testing.expect(arena.queryCapacity() - before < calls * (2 * data_cap));
}

/// Reads the fuzzer's bytes one choice at a time; past the end it reads zeros.
const ErrorDataScript = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(s: *ErrorDataScript) u8 {
        if (s.at >= s.bytes.len) return 0;
        defer s.at += 1;
        return s.bytes[s.at];
    }
};

/// The whitespace JSON allows between tokens, as one byte of the script picks it. The first is none.
const json_gaps = [_][]const u8{ "", " ", "\t", "\n", "\r", " \r\n\t" };

/// One gap of whitespace, picked by the next byte of the script.
fn appendGap(a: Allocator, out: *std.ArrayList(u8), script: *ErrorDataScript) !void {
    try out.appendSlice(a, json_gaps[script.next() % json_gaps.len]);
}

/// What `second` adds after the first value: a gap, `,`, a gap, then, for an object, the member's name `"a"`, a gap,
/// `:` and a gap, and then the value `0`. The script picks the gaps in that order.
fn appendSecondValue(a: Allocator, out: *std.ArrayList(u8), script: *ErrorDataScript, object: bool) !void {
    try appendGap(a, out, script);
    try out.append(a, ',');
    try appendGap(a, out, script);
    if (object) {
        try out.appendSlice(a, "\"a\"");
        try appendGap(a, out, script);
        try out.append(a, ':');
        try appendGap(a, out, script);
    }
    try out.append(a, '0');
}

/// `string`, a JSON string literal, as the one value of a JSON text of shape 2 (the string alone), 3 (an object) or
/// 4 (an array), with insignificant whitespace in every place JSON allows it: around the text, after the brackets,
/// around `:` and `,`. With `second` the object and the array hold one more value, so a `,` is written. The strings keep
/// their own spaces. The script picks each gap in the order the text is written.
fn spacedErrorData(a: Allocator, script: *ErrorDataScript, shape: u8, string: []const u8, second: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendGap(a, &out, script);
    switch (shape) {
        2 => try out.appendSlice(a, string),
        3 => {
            try out.append(a, '{');
            try appendGap(a, &out, script);
            try out.appendSlice(a, "\"detail\"");
            try appendGap(a, &out, script);
            try out.append(a, ':');
            try appendGap(a, &out, script);
            try out.appendSlice(a, string);
            if (second) try appendSecondValue(a, &out, script, true);
            try appendGap(a, &out, script);
            try out.append(a, '}');
        },
        else => {
            try out.append(a, '[');
            try appendGap(a, &out, script);
            try out.appendSlice(a, string);
            if (second) try appendSecondValue(a, &out, script, false);
            try appendGap(a, &out, script);
            try out.append(a, ']');
        },
    }
    try appendGap(a, &out, script);
    return out.items;
}

fn fuzzErrorData(_: void, smith: *testing.Smith) !void {
    var buffer: [64]u8 = undefined;
    const len = smith.slice(&buffer);
    var script: ErrorDataScript = .{ .bytes = buffer[0..len] };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const code: i64 = switch (script.next() % 3) {
        0 => -32602,
        1 => -32603,
        else => -32042,
    };
    const shape = script.next() % 6;
    const mode = script.next() % 4;
    // Shapes 2 to 4 are valid JSON around one string, with whitespace between its tokens (see `spacedErrorData`);
    // shape 5 is bytes of one class, which no JSON holds.
    // A valid string is made of letters, or of one class of bytes that it must write with escapes.
    const near_cap: usize = if (shape == 5) data_cap / 2 else data_cap;
    var target: usize = switch (mode) {
        0 => script.next() % 64 + 1,
        1 => near_cap - 24 + @as(usize, script.next() % 48),
        2 => 3 * data_cap,
        else => 100 * 1024,
    };
    const letters = [_][]const u8{ "a", "\u{e9}", "\u{20ac}", "\u{1f600}" };
    const classes = [_][]const u8{ "\"", "\\", "\x07", "\n", "\"\\\x07", "\\\"" };
    const letter = letters[script.next() % letters.len];
    const class = classes[script.next() % classes.len];
    const quoted = script.next() % 2 == 0;
    const heavy = script.next() % 2 == 1;
    const unit = if (shape == 5 or heavy) class else letter;
    if (heavy and shape != 5 and mode == 1) target = data_cap / 2 - 24 + target % 48;
    // The text of the data's one string, as many whole units as fit the target.
    var text: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    while (text.items.len + unit.len <= target) : (count += 1) {
        if (shape != 5 and !heavy and quoted and count % 7 == 6) {
            try text.append(a, '"');
        } else try text.appendSlice(a, unit);
    }
    const string = try std.json.Stringify.valueAlloc(a, text.items, .{});
    // The script's bytes after these are the whitespace; past its end they read as none, so a saved input without them
    // is the compact JSON it was.
    const second = script.next() % 2 == 1;
    const data: ?[]const u8 = switch (shape) {
        0 => null,
        1 => "null",
        2, 3, 4 => try spacedErrorData(a, &script, shape, string, second),
        else => text.items,
    };

    const kept = (try keptFailure(a, code, data)).failure.data;

    // The law: a -32042's data and an absent or null data are left out. Longer than the cap, data
    // that the host reads is cut as one JSON string literal of the longest prefix of its compact
    // text whose quotes and escapes fit the cap and that ends where a character ends, then a
    // marker; data that is too long to read is cut the same way from its own text; and data the
    // host cannot read safely (not UTF-8, not JSON, nested too deep) is left out. What fits the cap is
    // held as its compact text. So what the model sees is bounded and is valid JSON.
    if (code == -32042 or shape < 2) {
        try testing.expectEqual(@as(?[]const u8, null), kept);
        return;
    }
    const raw = data.?;
    // What the host should read, worked out without `compactText`: the data must be JSON, and the model
    // sees it with no spaces outside its strings, though the server wrote spaces, tabs and line breaks between
    // the tokens. The only number is 0, which `std.json` writes as it is.
    var source: []const u8 = raw;
    if (raw.len <= data_parse_max) {
        if (!try std.json.validate(a, raw)) {
            try testing.expectEqual(@as(?[]const u8, null), kept);
            return;
        }
        source = try withoutSpaces(a, raw);
        if (source.len <= data_cap) {
            const held = kept orelse return error.TestUnexpectedResult;
            try expectNoSpaceOutsideStrings(held);
            const want = try json_decode.parseFromSliceLeaky(std.json.Value, a, raw, .{});
            const got = try json_decode.parseFromSliceLeaky(std.json.Value, a, held, .{});
            try testing.expect(jsonEqual(want, got));
            return;
        }
    }
    const held = kept orelse {
        // Only data that no text holds is left out of a cut.
        try testing.expect(!std.unicode.utf8ValidateSlice(raw));
        return;
    };
    try expectCutOf(a, source, held);
}

/// `raw` without the whitespace outside its strings.
fn withoutSpaces(a: Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_string = false;
    var escaped = false;
    for (raw) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') in_string = false;
        } else if (byte == '"') {
            in_string = true;
        } else if (std.ascii.isWhitespace(byte)) continue;
        try out.append(a, byte);
    }
    return out.items;
}

fn expectNoSpaceOutsideStrings(text: []const u8) !void {
    var in_string = false;
    var escaped = false;
    for (text) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') in_string = false;
        } else if (byte == '"') {
            in_string = true;
        } else try testing.expect(!std.ascii.isWhitespace(byte));
    }
}

fn jsonEqual(x: std.json.Value, y: std.json.Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null => true,
        .bool => |v| v == y.bool,
        .integer => |v| v == y.integer,
        .float => |v| v == y.float,
        .number_string => |v| std.mem.eql(u8, v, y.number_string),
        .string => |v| std.mem.eql(u8, v, y.string),
        .array => |v| {
            if (v.items.len != y.array.items.len) return false;
            for (v.items, y.array.items) |item, other| if (!jsonEqual(item, other)) return false;
            return true;
        },
        .object => |v| {
            if (v.count() != y.object.count()) return false;
            var it = v.iterator();
            while (it.next()) |entry| {
                const other = y.object.get(entry.key_ptr.*) orelse return false;
                if (!jsonEqual(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
    };
}

test "a failed call's error data is kept whole or cut at a character, within the cap, on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzErrorData, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").mcp_error_data.*),
    });
}

test "a session past the owner's key limit runs the extra server itself" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const home = try sharedHome("keys");
    defer freeSharedHome(home);
    var stop = std.atomic.Value(bool).init(false);
    const served = try std.Thread.spawn(.{}, serveOwner, .{ testing.io, testing.allocator, home, &stop });
    defer {
        stop.store(true, .release);
        served.join();
    }
    try waitForOwner(home);

    // One more server than the owner gives one session, each with its own name
    // and so its own key.
    const count = owner_core.max_keys_per_client + 1;
    var names: [count][16]u8 = undefined;
    var configs: [count]mcp_contract.McpServerConfig = undefined;
    for (&configs, &names, 0..) |*server, *name, i| {
        name.* = "srv-000000000000".*;
        name.*[14] = "0123456789abcdef"[i / 16];
        name.*[15] = "0123456789abcdef"[i % 16];
        server.* = .{ .name = name, .command = f.server };
    }
    var options = f.options();
    options.share = .{ .fx_home = home, .spawn_owner = false };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The owner takes the first 32 and runs them.
    for (configs[0..owner_core.max_keys_per_client]) |server| {
        const listed = try r.tools(a, server.name, null);
        try testing.expectEqual(@as(usize, 1), listed.tools.len);
    }
    // The 33rd is refused a key, so this session runs it itself and still
    // lists its tools.
    const extra = try r.tools(a, configs[owner_core.max_keys_per_client].name, null);
    try testing.expectEqual(@as(usize, 1), extra.tools.len);
    // The refusal cost the connection nothing: a key the owner runs answers
    // again.
    const again = try r.tools(a, configs[0].name, null);
    try testing.expectEqual(@as(usize, 1), again.tools.len);
}

test "a login on a shared stdio server is NotHttp, and a saved login passes it by" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const home = try sharedHome("login");
    defer freeSharedHome(home);
    var stop = std.atomic.Value(bool).init(false);
    const served = try std.Thread.spawn(.{}, serveOwner, .{ testing.io, testing.allocator, home, &stop });
    defer {
        stop.store(true, .release);
        served.join();
    }
    try waitForOwner(home);

    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.share = .{ .fx_home = home, .spawn_owner = false };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The owner runs it, so this session only routes to it: a shared server is
    // stdio, so a login is an answer (NotHttp), never a failed assert.
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "fake", null)).tools.len);
    try testing.expectError(error.NotHttp, r.login("fake", false));
    // The saved-login path passes a shared stdio server by the same way.
    try r.pickUpLogins();
}

test "a shared server's status comes from the owner" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const home = try sharedHome("status");
    defer freeSharedHome(home);
    var stop = std.atomic.Value(bool).init(false);
    const served = try std.Thread.spawn(.{}, serveOwner, .{ testing.io, testing.allocator, home, &stop });
    defer {
        stop.store(true, .release);
        served.join();
    }
    try waitForOwner(home);

    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.share = .{ .fx_home = home, .spawn_owner = false };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const listed = try r.tools(a, "fake", null);
    try testing.expectEqual(@as(usize, 1), listed.tools.len);
    const listed_status = (try r.statuses(a))[0];
    try testing.expectEqual(State.ready, listed_status.state);
    try testing.expectEqual(@as(usize, 1), listed_status.tools);
    try testing.expectEqualStrings("2025-11-25", listed_status.version.?);
    try testing.expect(!listed_status.needs_login and !listed_status.signed_in and !listed_status.signing_in);
}

test "a reload that changes a shared server's env ends this session's call on it, and the next call works" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const home = try sharedHome("reload");
    defer freeSharedHome(home);
    var stop = std.atomic.Value(bool).init(false);
    const served = try std.Thread.spawn(.{}, serveOwner, .{ testing.io, testing.allocator, home, &stop });
    defer {
        stop.store(true, .release);
        served.join();
    }
    try waitForOwner(home);

    var one = [_]mcp_contract.McpEnvVar{.{ .key = @constCast("MODE"), .value = @constCast("one") }};
    var two = [_]mcp_contract.McpEnvVar{.{ .key = @constCast("MODE"), .value = @constCast("two") }};
    const before = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server, .env = &one }};
    var options = f.options();
    options.share = .{ .fx_home = home, .spawn_owner = false };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &before, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "fake", null)).tools.len);

    const Caller = struct {
        fn run(runtime: *Runtime, out: *?CallResult) void {
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            out.* = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"slow\"}", null, null) catch null;
        }
    };
    var first: ?CallResult = null;
    const caller = try std.Thread.spawn(.{}, Caller.run, .{ &r, &first });
    // The owner has the call: it went out after the listing. A fixed window is
    // needed because nothing tells the session its call reached the owner.
    try testing.io.sleep(.fromMilliseconds(300), .awake);

    const after = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server, .env = &two }};
    const done = try r.reload(&after, &f.inherited);
    caller.join();
    const ended = first orelse return error.NoCallResult;
    try testing.expect(ended == .ended and ended.ended.outcome == .cancelled);
    try testing.expect(!done.kept[0]);

    // The new key starts its own server, and answers.
    const pid = try pidOf(&r, a, "fake");
    try testing.expect(pid.len > 0);
    try testing.expectEqual(State.ready, (try r.statuses(a))[0].state);
}

test "a reload that removes a shared server ends this session's call on it, and says a server was dropped" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const home = try sharedHome("removed");
    defer freeSharedHome(home);
    var stop = std.atomic.Value(bool).init(false);
    const served = try std.Thread.spawn(.{}, serveOwner, .{ testing.io, testing.allocator, home, &stop });
    defer {
        stop.store(true, .release);
        served.join();
    }
    try waitForOwner(home);

    const before = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.share = .{ .fx_home = home, .spawn_owner = false };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &before, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "fake", null)).tools.len);

    const Caller = struct {
        fn run(runtime: *Runtime, out: *?CallResult) void {
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            out.* = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"slow\"}", null, null) catch null;
        }
    };
    var first: ?CallResult = null;
    const caller = try std.Thread.spawn(.{}, Caller.run, .{ &r, &first });
    // The owner has the call: it went out after the listing. A fixed window is
    // needed because nothing tells the session its call reached the owner.
    try testing.io.sleep(.fromMilliseconds(300), .awake);

    const done = try r.reload(&.{}, &f.inherited);
    caller.join();
    const ended = first orelse return error.NoCallResult;
    try testing.expect(ended == .ended and ended.ended.outcome == .cancelled);
    // A subagent's view from before must stop matching, so the catalog bumps.
    try testing.expect(done.dropped);
    try testing.expectEqual(@as(usize, 0), r.resolved.servers.len);
}

test "a shared server runs in this session when no owner can start" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // The owner's socket path must fit a Unix address; this home cannot.
    const home = "/tmp/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/home";
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.share = .{ .fx_home = home };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The adapter refused this home at start, so every server runs here.
    try testing.expect(r.shared == null);
    try testing.expectEqual(@as(usize, 1), (try r.tools(a, "fake", null)).tools.len);
    const pid = try pidOf(&r, a, "fake");
    try testing.expect(pid.len > 0);
    const status = (try r.statuses(a))[0];
    try testing.expectEqual(State.ready, status.state);
    try testing.expectEqual(@as(usize, 1), status.tools);
}

test "a shared server runs in this session when no owner answers" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const home = try sharedHome("nobody");
    defer freeSharedHome(home);
    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.share = .{ .fx_home = home, .spawn_owner = false };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The first call waits for an owner that never comes, then answers here.
    const pid = try pidOf(&r, a, "fake");
    try testing.expect(pid.len > 0);
    try testing.expectEqual(State.ready, (try r.statuses(a))[0].state);
    // The adapter is still there; the server's slot moved into this session.
    try testing.expect(r.shared != null and !r.shared.?.has("fake"));
}

/// Waits until a runtime's only server reads ready, or fails.
fn waitReady(r: *Runtime, a: Allocator) !void {
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 2_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        if ((try r.statuses(a))[0].state == .ready) return;
        // Polls the status the other session publishes, bounded above.
        try testing.io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.ServerNeverReady;
}

test "two runtimes share one server through one owner, and one leaving keeps the other's call working" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const home = try sharedHome("pair");
    defer freeSharedHome(home);
    var stop = std.atomic.Value(bool).init(false);
    const served = try std.Thread.spawn(.{}, serveOwner, .{ testing.io, testing.allocator, home, &stop });
    defer {
        stop.store(true, .release);
        served.join();
    }
    try waitForOwner(home);

    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.share = .{ .fx_home = home, .spawn_owner = false };
    var first: Runtime = undefined;
    try first.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    var first_up = true;
    defer if (first_up) first.deinit();
    var second: Runtime = undefined;
    try second.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer second.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first_pid = try pidOf(&first, a, "fake");
    const second_pid = try pidOf(&second, a, "fake");
    try testing.expectEqualStrings(first_pid, second_pid);
    const pid = try std.fmt.parseInt(std.posix.pid_t, first_pid, 10);

    const Caller = struct {
        fn run(runtime: *Runtime, cancel: *std.atomic.Value(bool), out: *?engine.Outcome) void {
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            const result = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"slow\"}", cancel, null) catch return;
            if (result == .ended) out.* = result.ended.outcome;
        }
    };
    var cancel = std.atomic.Value(bool).init(false);
    var outcome: ?engine.Outcome = null;
    const caller = try std.Thread.spawn(.{}, Caller.run, .{ &second, &cancel, &outcome });
    // The second session's call must be in flight before the first leaves; a
    // fixed window is needed because nothing tells the session that it is.
    try testing.io.sleep(.fromMilliseconds(300), .awake);

    // The second session hears where the server already is when it joins.
    try waitReady(&second, a);
    // The first session leaves; the second still holds the server.
    first.deinit();
    first_up = false;
    try testing.expect(try running(pid));
    try waitReady(&second, a);

    cancel.store(true, .release);
    caller.join();
    try testing.expectEqual(@as(?engine.Outcome, .cancelled), outcome);
    try testing.expect(try running(pid));
}

test "an owner that dies ends a call in flight as lost, and the next call starts a new owner" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const home = try sharedHome("orphan");
    defer freeSharedHome(home);
    var stop = std.atomic.Value(bool).init(false);
    var served: ?std.Thread = try std.Thread.spawn(.{}, serveOwner, .{ testing.io, testing.allocator, home, &stop });
    defer {
        stop.store(true, .release);
        if (served) |thread| thread.join();
    }
    try waitForOwner(home);

    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.share = .{ .fx_home = home, .spawn_owner = false };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first_pid = try pidOf(&r, a, "fake");

    const Caller = struct {
        fn run(runtime: *Runtime, out: *?CallResult) void {
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            out.* = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"slow\"}", null, null) catch null;
        }
    };
    var in_flight: ?CallResult = null;
    const caller = try std.Thread.spawn(.{}, Caller.run, .{ &r, &in_flight });
    // The call must be in flight when the owner dies; a fixed window is needed
    // because nothing tells the session that the owner took it.
    try testing.io.sleep(.fromMilliseconds(300), .awake);

    // The owner dies under the call: what it was running may have run.
    stop.store(true, .release);
    served.?.join();
    served = null;
    caller.join();
    const ended = in_flight orelse return error.NoCallResult;
    try testing.expect(ended == .ended and ended.ended.maybe_ran);

    // The next call starts a new owner, with a new server.
    stop.store(false, .release);
    served = try std.Thread.spawn(.{}, serveOwner, .{ testing.io, testing.allocator, home, &stop });
    try waitForOwner(home);
    const second_pid = try pidOf(&r, a, "fake");
    try testing.expect(!std.mem.eql(u8, first_pid, second_pid));
}

test "deinit while a shared call waits ends it and returns" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const home = try sharedHome("leaving");
    defer freeSharedHome(home);
    var stop = std.atomic.Value(bool).init(false);
    const served = try std.Thread.spawn(.{}, serveOwner, .{ testing.io, testing.allocator, home, &stop });
    defer {
        stop.store(true, .release);
        served.join();
    }
    try waitForOwner(home);

    const configs = [_]mcp_contract.McpServerConfig{.{ .name = "fake", .command = f.server }};
    var options = f.options();
    options.share = .{ .fx_home = home, .spawn_owner = false };
    var r: Runtime = undefined;
    try r.start(testing.allocator, testing.io, &configs, &f.inherited, options);
    var up = true;
    defer if (up) r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = try pidOf(&r, arena.allocator(), "fake");

    const Waiter = struct {
        fn run(runtime: *Runtime, err_out: *?Error, outcome: *?engine.Outcome) void {
            var ca: std.heap.ArenaAllocator = .init(testing.allocator);
            defer ca.deinit();
            const result = runtime.call(ca.allocator(), "fake", "echo", "{\"text\":\"slow\"}", null, null) catch |err| {
                err_out.* = err;
                return;
            };
            if (result == .ended) outcome.* = result.ended.outcome;
        }
    };
    var err_out: ?Error = null;
    var outcome: ?engine.Outcome = null;
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ &r, &err_out, &outcome });
    // The call must be waiting when the runtime is torn down; a fixed window
    // is needed because nothing tells the session that the owner took it.
    try testing.io.sleep(.fromMilliseconds(300), .awake);

    const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    r.deinit();
    up = false;
    const took = std.Io.Clock.awake.now(testing.io).toMilliseconds() - started;
    waiter.join();
    try testing.expect(took < 5_000);
    if (outcome) |how| {
        try testing.expectEqual(engine.Outcome.cancelled, how);
    } else if (err_out) |err| {
        try testing.expect(err == error.Stopped or err == error.Cancelled);
    } else return error.TheCallNeverEnded;
}
