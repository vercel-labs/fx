const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const elicitation = @import("../mcp/elicitation.zig");
const mcp_model_catalog = @import("../mcp/model_catalog.zig");
const mcp_host = @import("../mcp_host/host.zig");
const mcp_verbs = @import("../mcp_host/verbs.zig");
const mcp_menu = @import("../mcp_host/menu.zig");
const editor_state = @import("../input/editor_state.zig");
const command_lex = @import("../shell_command/command_lex.zig");
const mod_registry = @import("../mods/registry.zig");
const context_limits = @import("../config/context_limits.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

/// The server a typed `/mcp ARGS` signs in to, or null if it isn't a valid
/// `login`. Read by the verb's own parser, since `--no-browser` may come
/// before or after the name. The result points into `args`.
fn typedLoginServer(arena: Allocator, args: []const []const u8) Allocator.Error!?[]const u8 {
    return switch (try mcp_verbs.parse(arena, .shell, args)) {
        .command => |command| switch (command) {
            .login => |login| login.name,
            else => null,
        },
        .usage, .moved => null,
    };
}

/// Owns the native profile MCP runtime. All transport work and retirement happen
/// after releasing this state lock; the lock protects only pointer publication.
pub const State = struct {
    /// The MCP host. Replaced on the UI thread when `/mcp` changes the
    /// config; other threads use it through `leaseHost`.
    host: ?*mcp_host.Host = null,
    /// Guards `host` against other threads, and its leases.
    host_mutex: std.Io.Mutex = .init,
    host_load: ?mcp_host.LoadFn = null,
    host_questions: elicitation.Capabilities = .{},
    /// Where the host's owner thread and `/mcp` threads leave what they have
    /// to say. On the heap, because the app is moved after the host starts
    /// and the host keeps this address.
    host_sink: ?*HostSink = null,
    /// What `/mcp` completes, rebuilt on the UI thread from the host's status.
    host_completion: []const mod_registry.ArgumentCompletion = &.{},
    host_completion_arena: ?std.heap.ArenaAllocator = null,
    host_completion_at_ms: i64 = 0,
    host_reload_requested: std.atomic.Value(bool) = .init(false),
    /// The `/mcp` menu; what it shows of the servers,
    /// rebuilt on the UI thread while it's open; and the open server's tools.
    host_menu: mcp_menu.State = .{},
    host_menu_rows: []const mcp_menu.Row = &.{},
    host_menu_notes: usize = 0,
    host_menu_arena: ?std.heap.ArenaAllocator = null,
    host_menu_at_ms: i64 = 0,
    host_menu_tools: mcp_menu.Tools = .loading,
    /// The UI thread's copy of the sink's waiting sign-in, for the menu.
    host_menu_sign_in: ?[]u8 = null,
    /// The status line's MCP text, which `refreshHostStatus` rebuilds.
    host_status_buf: [120]u8 = undefined,
    host_status_len: usize = 0,
    host_status_at_ms: i64 = 0,
    /// When the host loaded or `startHostServers` last started its servers;
    /// the status line waits for them to finish starting from then.
    host_started_ms: i64 = 0,
    /// Once the user sends a prompt, the servers that needed attention then:
    /// the status line stops repeating them and names only new ones.
    /// Null until the first prompt.
    host_status_seen: ?mcp_menu.Seen = null,
    /// A prompt was sent: record what needs attention once servers finish
    /// starting.
    host_status_dismiss_requested: bool = false,
    host_menu_tools_arena: ?std.heap.ArenaAllocator = null,
    /// Counts tool loads, so one for a server no longer open is dropped.
    host_menu_load: usize = 0,
    /// How the open server stood when its tools last loaded; a change, such
    /// as finishing a login, loads them again.
    host_menu_loaded: ?MenuLoadedAs = null,
    /// `/mcp` commands and menu tool loads still running, and the flag that
    /// ends them on quit.
    host_verbs: std.atomic.Value(usize) = .init(0),
    host_closing: std.atomic.Value(bool) = .init(false),
    /// Set by process-exit teardown before it joins a pending reload, so the
    /// reload discards its candidate runtime without grace or session DELETEs.
    process_exiting: std.atomic.Value(bool) = .init(false),
    model_catalog_baseline_lock: std.Io.Mutex = .init,
    /// Server availability as of the previous model-catalog report, used to
    /// surface mid-session changes (authentication, reload, recovery) to the
    /// model explicitly. Owned by the `baseline_alloc` passed to
    /// `snapshotModelCatalog`.
    model_catalog_baseline: ?[]mcp_model_catalog.BaselineEntry = null,

    /// Loads the host at startup with `load`, which reloads use too. The host's
    /// lifecycle is modeled in `tests/tla/mcp_host/HostLifecycle.tla`.
    pub fn loadHost(
        self: *State,
        load: mcp_host.LoadFn,
        alloc: Allocator,
        workspace_root: []const u8,
        registry: tool_dispatch.Registry,
        questions: elicitation.Capabilities,
    ) !void {
        self.host_load = load;
        self.host_questions = questions;
        if (self.host_sink == null) {
            const sink = try std.heap.c_allocator.create(HostSink);
            sink.* = .{};
            self.host_sink = sink;
        }
        self.replaceHost(try load(alloc, workspace_root, registry, .{ .questions = questions, .notify = self.host_sink.?.notify(), .slash_commands = true }));
    }

    /// Loads the config again after `/mcp` changed it. The host takes it in
    /// place, so only a server whose config changed restarts. A new host
    /// comes only when there was none, or the last server went; calls still
    /// using an old one finish on it.
    pub fn reloadHost(self: *State, alloc: Allocator, workspace_root: []const u8, registry: tool_dispatch.Registry) !void {
        const load = self.host_load orelse return;
        const sink = self.host_sink orelse return;
        const lease = self.leaseHost();
        defer if (lease) |l| l.deinit();
        const current = if (lease) |l| l.host else null;
        const next = try load(alloc, workspace_root, registry, .{ .questions = self.host_questions, .notify = sink.notify(), .slash_commands = true, .reuse = current });
        if (next != current) self.replaceHost(next);
        self.startHostServers();
    }

    pub fn hostStatusText(self: *const State) []const u8 {
        return self.host_status_buf[0..self.host_status_len];
    }

    /// Rebuilds the status line's MCP text, at most every 250 ms since
    /// servers change on their own; true when it changed.
    pub fn refreshHostStatus(self: *State, now_ms: i64) bool {
        if (self.host_status_at_ms != 0 and now_ms - self.host_status_at_ms < 250) return false;
        self.host_status_at_ms = now_ms;
        var next: [120]u8 = undefined;
        const text = self.hostStatusLine(&next, now_ms);
        if (std.mem.eql(u8, text, self.hostStatusText())) return false;
        @memcpy(self.host_status_buf[0..text.len], text);
        self.host_status_len = text.len;
        return true;
    }

    fn hostStatusLine(self: *State, buf: []u8, now_ms: i64) []const u8 {
        const sink = self.host_sink orelse return "";
        const lease = self.leaseHost() orelse return "";
        defer lease.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // The status line never shows sign-in state, so it doesn't wait for it.
        const statuses = lease.host.runtime.statusesNow(a) catch return "";
        sink.mutex.lockUncancelable(io_mod.getIo());
        const news: ?[]const u8 = if (sink.news) |text|
            (if (now_ms - sink.news_at_ms < mcp_menu.news_ms) a.dupe(u8, text) catch null else null)
        else
            null;
        const signing_in: ?[]const u8 = if (sink.sign_in) |waiting|
            a.dupe(u8, waiting[0 .. std.mem.findScalar(u8, waiting, 0) orelse waiting.len]) catch null
        else
            null;
        sink.mutex.unlock(io_mod.getIo());
        // While servers start, what needs the user waits so the count shows
        // once, not climbing; sign-in news still shows at once.
        if (self.host_started_ms != 0 and !mcp_menu.startupSettled(statuses, now_ms - self.host_started_ms))
            return mcp_menu.statusLine(buf, &.{}, signing_in, news, 0);
        if (self.host_status_dismiss_requested) {
            var seen: mcp_menu.Seen = .{};
            seen.record(statuses);
            self.host_status_seen = seen;
            self.host_status_dismiss_requested = false;
        }
        // After a prompt, what the user already saw stays in /mcp.
        if (self.host_status_seen) |*seen| {
            const fresh = a.alloc(std.meta.Elem(@TypeOf(statuses)), statuses.len) catch return "";
            return mcp_menu.statusLine(buf, mcp_menu.unseen(statuses, seen, fresh), signing_in, news, 0);
        }
        return mcp_menu.statusLine(buf, statuses, signing_in, news, lease.host.notes.len);
    }

    /// The user sent a prompt: what needs attention has been seen, so the
    /// status line clears it and speaks up only about new problems. Servers
    /// still starting are recorded once they finish.
    pub fn dismissHostStatus(self: *State) void {
        self.host_status_dismiss_requested = true;
        // The next refresh shows the change instead of waiting its turn.
        self.host_status_at_ms = 0;
    }

    /// Starts every server in the background, so each is ready before it's
    /// needed. Nothing waits: the host's own thread connects them, and quitting
    /// still signals them all at once.
    pub fn startHostServers(self: *State) void {
        const lease = self.leaseHost() orelse return;
        defer lease.deinit();
        self.host_started_ms = io_mod.milliTimestamp();
        for (lease.host.runtime.servers()) |s| lease.host.runtime.prepare(s.name) catch |err| {
            debug_trace.logf("mcp", "MCP servers not started in the background server={s} err={s}", .{ s.name, @errorName(err) });
            return;
        };
    }

    pub const HostLease = struct {
        state: *State,
        host: *mcp_host.Host,

        pub fn deinit(l: HostLease) void {
            l.state.releaseHost(l.host);
        }
    };

    /// The current host, kept alive until the lease ends even if a reload
    /// replaces it.
    pub fn leaseHost(self: *State) ?HostLease {
        self.host_mutex.lockUncancelable(io_mod.getIo());
        defer self.host_mutex.unlock(io_mod.getIo());
        const h = self.host orelse return null;
        h.leases += 1;
        return .{ .state = self, .host = h };
    }

    /// Every configured server's status, copied into `alloc`; null when
    /// there is no host.
    pub fn hostStatuses(self: *State, alloc: Allocator) Allocator.Error!?[]mcp_host.Status {
        const lease = self.leaseHost() orelse return null;
        defer lease.deinit();
        return try lease.host.runtime.statuses(alloc);
    }

    /// `hostStatuses` without waiting for saved logins to be read, for
    /// startup, which must not wait for the Keychain: until they are, every
    /// server reads as signed out.
    pub fn hostStatusesNow(self: *State, alloc: Allocator) Allocator.Error!?[]mcp_host.Status {
        const lease = self.leaseHost() orelse return null;
        defer lease.deinit();
        return try lease.host.runtime.statusesNow(alloc);
    }

    fn releaseHost(self: *State, h: *mcp_host.Host) void {
        self.host_mutex.lockUncancelable(io_mod.getIo());
        h.leases -= 1;
        const last = h.retired and h.leases == 0;
        self.host_mutex.unlock(io_mod.getIo());
        if (last) h.stop();
    }

    /// Swaps in `next` on the UI thread. Calls still using the old host
    /// finish on it; it goes with its last lease, its servers stopping in the
    /// background, and until then `next` starts no server.
    fn replaceHost(self: *State, next: ?*mcp_host.Host) void {
        self.host_mutex.lockUncancelable(io_mod.getIo());
        const old = self.host;
        // Before anyone can lease `next`.
        if (old) |h| h.retire();
        self.host = next;
        const unused = if (old) |h| unused: {
            h.retired = true;
            break :unused h.leases == 0;
        } else false;
        self.host_mutex.unlock(io_mod.getIo());
        // Its servers haven't reported in yet: the status line waits for them.
        if (next != null) self.host_started_ms = io_mod.milliTimestamp();
        if (unused) old.?.stop();
    }

    fn destroyHost(self: *State) void {
        self.host_closing.store(true, .release);
        if (self.process_exiting.load(.acquire)) {
            // Nothing is waited for: the servers get
            // SIGTERM, and the host and `/mcp` threads are left to the
            // exiting process.
            mcp_host.signalServersForExit();
            return;
        }
        // `/mcp` commands still running end first, so none outlives the state.
        self.closeHostMenu();
        var waited: usize = 0;
        while (self.host_verbs.load(.acquire) > 0 and waited < 500) : (waited += 1) io_mod.sleep(10 * std.time.ns_per_ms);
        if (self.host_verbs.load(.acquire) > 0) debug_trace.logf("mcp", "MCP commands still running at exit count={d}", .{self.host_verbs.load(.acquire)});
        self.replaceHost(null);
        // The retired hosts' servers notify the sink until they're gone.
        mcp_host.waitRetired();
        if (self.host_completion_arena) |*arena| arena.deinit();
        self.host_completion_arena = null;
        self.host_completion = &.{};
        // No host is left to notify, and no `/mcp` thread to push.
        if (self.host_sink) |sink| {
            sink.deinit();
            std.heap.c_allocator.destroy(sink);
            self.host_sink = null;
        }
    }

    pub const HostNotice = struct { text: []u8, warning: bool };

    /// What the host and `/mcp` threads have to say, until the UI thread
    /// takes it. Everything in it is from `std.heap.c_allocator`.
    pub const HostSink = struct {
        mutex: std.Io.Mutex = .init,
        notices: std.ArrayList(HostNotice) = .empty,
        /// Servers whose sign-in was typed as `/mcp login NAME`: its outcome
        /// goes in the transcript, like other typed commands' output.
        typed: std.ArrayList([]u8) = .empty,
        /// Any other sign-in's outcome, for the status line, and when it came.
        news: ?[]u8 = null,
        news_at_ms: i64 = 0,
        /// The menu's tool load still running, so leaving the server cancels
        /// it, and the last one finished, until the UI thread takes it.
        menu_job: ?*MenuToolsJob = null,
        menu_tools: ?MenuTools = null,
        /// The sign-in waiting for the browser, as its server, a 0 byte, and
        /// its address, so the menu can say so. Owned; the next one replaces it.
        sign_in: ?[]u8 = null,

        fn deinit(sink: *HostSink) void {
            if (sink.menu_tools) |*done| done.arena.deinit();
            if (sink.sign_in) |waiting| std.heap.c_allocator.free(waiting);
            for (sink.notices.items) |n| std.heap.c_allocator.free(n.text);
            sink.notices.deinit(std.heap.c_allocator);
            for (sink.typed.items) |name| std.heap.c_allocator.free(name);
            sink.typed.deinit(std.heap.c_allocator);
            if (sink.news) |text| std.heap.c_allocator.free(text);
        }

        fn notify(sink: *HostSink) mcp_host.Notify {
            return .{ .context = sink, .notice = onNotice };
        }

        /// On the host's owner thread: what a login or a call needs the user to hear.
        fn onNotice(context: *anyopaque, notice: mcp_host.Notice) void {
            const sink: *HostSink = @ptrCast(@alignCast(context));
            const a = std.heap.c_allocator;
            var arena: std.heap.ArenaAllocator = .init(a);
            defer arena.deinit();
            const aa = arena.allocator();
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            switch (notice) {
                .authorize => |n| {
                    sink.waitForSignIn(n.server, n.url);
                    // The menu shows the address; a typed login prints it.
                    if (!sink.isTyped(n.server)) return;
                    const text = a.print("Sign in to {s} in your browser. If it didn't open, go to:\n  {s}", .{ safeText(aa, n.server, 160), safeText(aa, n.url, 16 * 1024) }) catch return;
                    sink.pushLocked(text, false);
                },
                .signed_in => |server| {
                    sink.endSignIn(server);
                    sink.report(server, a.print("Signed in to {s}.", .{safeText(aa, server, 160)}) catch return, false);
                },
                .sign_in_failed => |n| {
                    sink.endSignIn(n.server);
                    sink.report(n.server, a.print("Couldn't sign in to {s}: {s}.", .{ safeText(aa, n.server, 160), safeText(aa, n.reason, 240) }) catch return, true);
                },
                // The status line says so for as long as it's true.
                .needs_login => {},
                .not_saved => |n| {
                    const server = safeText(aa, n.server, 160);
                    const text = a.print("Couldn't save {s}'s new login: {s}. It keeps working here, but after a restart {s} needs a login again.", .{ server, safeText(aa, n.reason, 240), server }) catch return;
                    sink.pushLocked(text, true);
                },
            }
        }

        /// A sign-in's outcome: the transcript for a typed one, else the
        /// status line's news. Takes `text`; locked by the caller.
        fn report(sink: *HostSink, server: []const u8, text: []u8, warning: bool) void {
            if (sink.untype(server)) return sink.pushLocked(text, warning);
            if (sink.news) |old| std.heap.c_allocator.free(old);
            sink.news = text;
            sink.news_at_ms = io_mod.milliTimestamp();
        }

        /// On the UI thread, for `/mcp login NAME` typed in the shell.
        fn markTyped(sink: *HostSink, server: []const u8) void {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            if (sink.isTyped(server)) return;
            const a = std.heap.c_allocator;
            // Out of memory, its outcome goes to the status line instead.
            const name = a.dupe(u8, server) catch return;
            sink.typed.append(a, name) catch a.free(name);
        }

        fn isTyped(sink: *const HostSink, server: []const u8) bool {
            for (sink.typed.items) |name| if (std.mem.eql(u8, name, server)) return true;
            return false;
        }

        fn untype(sink: *HostSink, server: []const u8) bool {
            for (sink.typed.items, 0..) |name, i| if (std.mem.eql(u8, name, server)) {
                std.heap.c_allocator.free(sink.typed.swapRemove(i));
                return true;
            };
            return false;
        }

        /// Locked by the caller. Out of memory, the menu just doesn't say it waits.
        fn waitForSignIn(sink: *HostSink, server: []const u8, url: []const u8) void {
            const a = std.heap.c_allocator;
            const next = std.mem.concat(a, u8, &.{ server, "\x00", url }) catch null;
            if (sink.sign_in) |old| a.free(old);
            sink.sign_in = next;
        }

        /// Locked by the caller.
        fn endSignIn(sink: *HostSink, server: []const u8) void {
            const waiting = sink.sign_in orelse return;
            const end = std.mem.findScalar(u8, waiting, 0) orelse waiting.len;
            if (!std.mem.eql(u8, waiting[0..end], server)) return;
            std.heap.c_allocator.free(waiting);
            sink.sign_in = null;
        }

        /// Takes ownership of `text`.
        fn push(sink: *HostSink, text: []u8, warning: bool) void {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            sink.pushLocked(text, warning);
        }

        fn pushLocked(sink: *HostSink, text: []u8, warning: bool) void {
            sink.notices.append(std.heap.c_allocator, .{ .text = text, .warning = warning }) catch {
                debug_trace.logf("mcp", "MCP notice dropped: out of memory", .{});
                std.heap.c_allocator.free(text);
            };
        }

        fn safeText(arena: Allocator, raw: []const u8, max: usize) []const u8 {
            return (text_utils.encodeTerminalSafeInline(arena, raw, max) catch return "?").bytes;
        }
    };

    /// The notices waiting for the UI, owned by `std.heap.c_allocator`.
    pub fn takeHostNotices(self: *State) []HostNotice {
        const sink = self.host_sink orelse return &.{};
        sink.mutex.lockUncancelable(io_mod.getIo());
        defer sink.mutex.unlock(io_mod.getIo());
        return sink.notices.toOwnedSlice(std.heap.c_allocator) catch &.{};
    }

    const verb_completions = [_]mod_registry.ArgumentCompletion{
        .{ .full = "/mcp list", .description = "configured servers" },
        .{ .full = "/mcp show", .description = "connect to a server and list its tools" },
        .{ .full = "/mcp add", .description = "add a server" },
        .{ .full = "/mcp remove", .description = "remove a server and its login" },
        .{ .full = "/mcp login", .description = "sign in to an HTTP server" },
        .{ .full = "/mcp logout", .description = "sign out of an HTTP server" },
        .{ .full = "/mcp approve", .description = "approve a project server" },
        .{ .full = "/mcp reject", .description = "reject a project server" },
    };

    /// On the UI thread: what `/mcp` completes, from the host's current
    /// status. Rebuilt at most twice a second.
    pub fn refreshCompletion(self: *State) void {
        if (self.host_sink == null) return;
        const now = io_mod.milliTimestamp();
        if (self.host_completion.len > 0 and now - self.host_completion_at_ms < 500) return;
        self.host_completion_at_ms = now;
        var next: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        const entries = self.buildCompletion(next.allocator()) catch {
            next.deinit();
            return;
        };
        if (self.host_completion_arena) |*old| old.deinit();
        self.host_completion_arena = next;
        self.host_completion = entries;
    }

    fn buildCompletion(self: *State, a: Allocator) ![]const mod_registry.ArgumentCompletion {
        var out: std.ArrayList(mod_registry.ArgumentCompletion) = .empty;
        try out.appendSlice(a, &verb_completions);
        const lease = self.leaseHost() orelse return out.items;
        defer lease.deinit();
        // Rebuilt twice a second on the UI thread, so it doesn't wait for
        // saved credentials: a description says "signed in" from the next
        // rebuild after they are restored.
        const statuses = try lease.host.runtime.statusesNow(a);
        for (statuses, lease.host.runtime.servers()) |status, server| {
            if (!mcp_verbs.isValidServerName(status.name)) continue;
            const description = try mcp_verbs.statusText(a, status);
            const applies = [_]struct { verb: []const u8, ok: bool }{
                .{ .verb = "show", .ok = true },
                .{ .verb = "remove", .ok = true },
                .{ .verb = "login", .ok = server.transport != .stdio },
                .{ .verb = "logout", .ok = server.transport != .stdio },
                .{ .verb = "approve", .ok = server.source == .workspace },
                .{ .verb = "reject", .ok = server.source == .workspace },
            };
            for (applies) |verb| if (verb.ok) try out.append(a, .{
                .full = try a.print("/mcp {s} {s}", .{ verb.verb, status.name }),
                .description = description,
            });
        }
        return out.items;
    }

    /// Whether a `/mcp` command changed the config since the last call.
    pub fn takeHostReload(self: *State) bool {
        return self.host_reload_requested.swap(false, .acq_rel);
    }

    /// Runs `/mcp ARGS` off the UI thread, since `show` may wait for a
    /// server; what it prints and any reload it asks for reach the UI through
    /// `takeHostNotices` and `takeHostReload`.
    pub fn runVerbs(self: *State, home: []const u8, workspace_root: []const u8, rest: []const u8) !void {
        const a = std.heap.c_allocator;
        var argv = command_lex.tokenize_argv(a, rest) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                const sink = self.host_sink orelse return;
                sink.push(try a.dupe(u8, "/mcp: that command line has an unmatched quote or a character fx doesn't take here."), true);
                return;
            },
        };
        defer argv.deinit(a);
        const args = try a.alloc([]const u8, argv.tokens.len);
        defer a.free(args);
        for (argv.tokens, args) |t, *arg| arg.* = t.value;
        if (self.host_sink) |sink| {
            var arena: std.heap.ArenaAllocator = .init(a);
            defer arena.deinit();
            if (try typedLoginServer(arena.allocator(), args)) |server| sink.markTyped(server);
        }
        try self.startVerbs(home, workspace_root, args, .transcript);
    }

    /// Where a `/mcp` command's report goes. A command typed in the
    /// composer prints it; a choice in the menu shows its result there, so
    /// only its warnings and errors print.
    const VerbReport = enum { transcript, warnings_only };

    /// Runs `/mcp` with `args` off the UI thread, like `runVerbs`.
    fn startVerbs(self: *State, home: []const u8, workspace_root: []const u8, args: []const []const u8, report: VerbReport) !void {
        if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
        const a = std.heap.c_allocator;
        const job = try a.create(VerbJob);
        errdefer a.destroy(job);
        job.* = .{ .state = self, .report = report };
        errdefer job.free();
        const owned = try a.alloc([]const u8, args.len);
        @memset(owned, "");
        job.args = owned;
        for (args, owned) |arg, *copy| copy.* = try a.dupe(u8, arg);
        job.home = try a.dupe(u8, home);
        job.workspace_root = try a.dupe(u8, workspace_root);
        _ = self.host_verbs.fetchAdd(1, .acq_rel);
        errdefer _ = self.host_verbs.fetchSub(1, .acq_rel);
        const thread = try std.Thread.spawn(.{}, VerbJob.run, .{job});
        thread.detach();
    }

    const VerbJob = struct {
        state: *State,
        report: VerbReport,
        args: []const []const u8 = &.{},
        home: []const u8 = "",
        workspace_root: []const u8 = "",

        fn free(job: *VerbJob) void {
            const a = std.heap.c_allocator;
            for (job.args) |arg| a.free(arg);
            a.free(job.args);
            a.free(job.home);
            a.free(job.workspace_root);
        }

        fn run(job: *VerbJob) void {
            const a = std.heap.c_allocator;
            const self = job.state;
            const args = job.args;
            defer {
                job.free();
                a.destroy(job);
                _ = self.host_verbs.fetchSub(1, .acq_rel);
            }
            var out: std.Io.Writer.Allocating = .init(a);
            defer out.deinit();
            var err: std.Io.Writer.Allocating = .init(a);
            defer err.deinit();
            _ = mcp_verbs.run(.{
                .gpa = a,
                .out = &out.writer,
                .err = &err.writer,
                .surface = .shell,
                .home = job.home,
                .workspace_root = job.workspace_root,
                .hosts = .{ .context = self, .get = getHost, .release = putHost, .changed = configChanged },
                .cancel = &self.host_closing,
            }, args);
            const sink = self.host_sink orelse return;
            for ([_]*std.Io.Writer.Allocating{ &out, &err }, [_]bool{ false, true }) |w, warning| {
                if (!warning and job.report == .warnings_only) continue;
                const text = std.mem.trimEnd(u8, w.written(), "\n");
                if (text.len == 0) continue;
                sink.push(a.dupe(u8, text) catch continue, warning);
            }
        }

        fn getHost(context: *anyopaque, _: ?mcp_host.Notify) anyerror!?*mcp_host.Host {
            const self: *State = @ptrCast(@alignCast(context));
            return if (self.leaseHost()) |l| l.host else null;
        }

        fn putHost(context: *anyopaque, h: *mcp_host.Host) void {
            const self: *State = @ptrCast(@alignCast(context));
            self.releaseHost(h);
        }

        fn configChanged(context: *anyopaque) void {
            const self: *State = @ptrCast(@alignCast(context));
            self.host_reload_requested.store(true, .release);
        }
    };

    pub fn hostMenuActive(self: *const State) bool {
        return self.host_menu.active;
    }

    pub fn openHostMenu(self: *State) void {
        self.closeHostMenu();
        mcp_menu.open(&self.host_menu);
        _ = self.refreshHostMenu("");
    }

    /// Each screen keeps its own filter in the composer: opening a server
    /// starts its tool filter empty, and going back brings the list's back.
    pub fn swapHostMenuFilter(self: *State, was: mcp_menu.Screen, alloc: Allocator, composer: *editor_state.State) Allocator.Error!void {
        if (!self.host_menu.active) return;
        if (was == .list and self.host_menu.screen == .server) {
            self.host_menu.keepListFilter(composer.input.items);
            composer.clearRetainingCapacity();
        } else if (was != .list and self.host_menu.screen == .list) {
            try composer.setText(alloc, self.host_menu.listFilter());
        }
    }

    /// The composer changed: on a server's screen, that's its tool filter.
    pub fn hostMenuFilterChanged(self: *State, filter: []const u8) void {
        if (!self.host_menu.active or self.host_menu.screen != .server) return;
        const view = mcp_menu.viewOf(&self.host_menu, self.host_menu_rows, filter, self.host_menu_tools, &.{});
        mcp_menu.filterChanged(&self.host_menu, view, filter.len > 0);
    }

    pub fn closeHostMenu(self: *State) void {
        self.stopMenuTools();
        self.host_menu = .{};
        if (self.host_menu_arena) |*arena| arena.deinit();
        self.host_menu_arena = null;
        self.host_menu_rows = &.{};
        self.host_menu_notes = 0;
        self.host_menu_at_ms = 0;
        if (self.host_menu_sign_in) |waiting| std.heap.c_allocator.free(waiting);
        self.host_menu_sign_in = null;
    }

    /// The address the open server's sign-in waits on, if one does.
    pub fn hostMenuSignInUrl(self: *const State) ?[]const u8 {
        if (self.host_menu.screen == .list) return null;
        const waiting = self.host_menu_sign_in orelse return null;
        const end = std.mem.findScalar(u8, waiting, 0) orelse return null;
        if (!std.mem.eql(u8, waiting[0..end], self.host_menu.selectedName())) return null;
        return waiting[end + 1 ..];
    }

    /// Copies the sink's waiting sign-in; true when it changed.
    fn takeSignIn(self: *State) bool {
        const sink = self.host_sink orelse return false;
        sink.mutex.lockUncancelable(io_mod.getIo());
        defer sink.mutex.unlock(io_mod.getIo());
        const now = sink.sign_in;
        const had = self.host_menu_sign_in;
        if (now == null and had == null) return false;
        if (now != null and had != null and std.mem.eql(u8, now.?, had.?)) return false;
        const a = std.heap.c_allocator;
        if (had) |old| a.free(old);
        self.host_menu_sign_in = if (now) |w| a.dupe(u8, w) catch null else null;
        return true;
    }

    /// A key in the menu, with `filter` typed in the composer. A choice runs
    /// the `/mcp` command it shows, which prints in the conversation.
    pub fn hostMenuKey(self: *State, key: mcp_menu.Key, filter: []const u8, home: []const u8, workspace_root: []const u8) !void {
        const buf = try std.heap.c_allocator.alloc(mcp_menu.Row, self.host_menu_rows.len);
        defer std.heap.c_allocator.free(buf);
        const view = mcp_menu.viewOf(&self.host_menu, self.host_menu_rows, filter, self.host_menu_tools, buf);
        switch (mcp_menu.press(&self.host_menu, view, key)) {
            .none => {},
            .close => self.closeHostMenu(),
            .open => |name| try self.startMenuTools(name),
            .back => self.stopMenuTools(),
            .run => |run| {
                // A confirmed Remove went back to the list already.
                if (self.host_menu.screen == .list) self.stopMenuTools();
                try self.startVerbs(home, workspace_root, &.{ run.choice.verb(), run.server }, .warnings_only);
                // The status follows sooner than the next refresh would show it.
                self.host_menu_at_ms = 0;
            },
        }
    }

    /// On the UI thread while the menu is open: the servers' status at most
    /// four times a second, and the open server's tools once they load.
    /// Whether anything it shows changed.
    /// `filter` is what the composer holds: the list's, or the open server's tools'.
    pub fn refreshHostMenu(self: *State, filter: []const u8) bool {
        if (!self.host_menu.active) return false;
        var changed = false;
        const now = io_mod.milliTimestamp();
        if (now - self.host_menu_at_ms >= 250) {
            changed = true;
            self.host_menu_at_ms = now;
            var next: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
            if (self.buildMenuRows(next.allocator())) |rows| {
                if (self.host_menu_arena) |*old| old.deinit();
                self.host_menu_arena = next;
                self.host_menu_rows = rows;
            } else |err| {
                next.deinit();
                debug_trace.logf("mcp", "MCP menu kept its old rows err={s}", .{@errorName(err)});
            }
        }
        if (self.takeMenuTools()) changed = true;
        if (self.takeSignIn()) changed = true;
        const view = mcp_menu.viewOf(&self.host_menu, self.host_menu_rows, filter, self.host_menu_tools, &.{});
        if (mcp_menu.settle(&self.host_menu, view) == .back) {
            self.stopMenuTools();
            return true;
        }
        // A server that became usable since its tools failed to load, by
        // logging in or being approved, loads them again. Only then: a
        // failing server moving between retrying and failed is left alone.
        const open = view.open orelse return changed;
        if (self.host_menu_tools == .ready or self.host_menu_tools == .loading) return changed;
        if (open.status.needs_login or (open.status.state != .ready and open.status.state != .idle)) return changed;
        if (self.host_menu_loaded) |was| if (std.meta.eql(was, MenuLoadedAs.of(open))) return changed;
        self.startMenuTools(open.status.name) catch |err|
            debug_trace.logf("mcp", "MCP menu tools reload failed err={s}", .{@errorName(err)});
        return true;
    }

    fn buildMenuRows(self: *State, a: Allocator) ![]const mcp_menu.Row {
        const lease = self.leaseHost() orelse {
            self.host_menu_notes = 0;
            return &.{};
        };
        defer lease.deinit();
        // Right after launch, waiting for saved logins would freeze the
        // shell; the next refresh shows them once they're in.
        const statuses = try lease.host.runtime.statusesNow(a);
        const rows = try a.alloc(mcp_menu.Row, statuses.len);
        for (statuses, lease.host.runtime.servers(), rows) |status, server, *row| row.* = .{
            .status = status,
            .target = if (server.url orelse server.command) |target| try a.dupe(u8, target) else null,
        };
        self.host_menu_notes = lease.host.notes.len;
        return rows;
    }

    pub const MenuTools = struct { load: usize, arena: std.heap.ArenaAllocator, tools: mcp_menu.Tools };

    const MenuLoadedAs = struct {
        state: @import("../mcp_host/runtime.zig").State,
        needs_login: bool,
        signed_in: bool,

        fn of(row: mcp_menu.Row) MenuLoadedAs {
            return .{ .state = row.status.state, .needs_login = row.status.needs_login, .signed_in = row.status.signed_in };
        }
    };

    /// Connects `name` off the UI thread and lists its tools for the menu.
    fn startMenuTools(self: *State, name: []const u8) !void {
        if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
        self.stopMenuTools();
        self.host_menu_load +%= 1;
        const open = for (self.host_menu_rows) |row| {
            if (std.mem.eql(u8, row.status.name, name)) break row;
        } else null;
        self.host_menu_loaded = if (open) |row| MenuLoadedAs.of(row) else null;
        const sink = self.host_sink orelse return;
        const a = std.heap.c_allocator;
        const job = try a.create(MenuToolsJob);
        errdefer a.destroy(job);
        job.* = .{ .state = self, .load = self.host_menu_load, .name = try a.dupe(u8, name) };
        errdefer a.free(job.name);
        _ = self.host_verbs.fetchAdd(1, .acq_rel);
        errdefer _ = self.host_verbs.fetchSub(1, .acq_rel);
        // Registered before it starts, so it can't finish unseen.
        sink.mutex.lockUncancelable(io_mod.getIo());
        sink.menu_job = job;
        sink.mutex.unlock(io_mod.getIo());
        const thread = std.Thread.spawn(.{}, MenuToolsJob.run, .{job}) catch |err| {
            sink.mutex.lockUncancelable(io_mod.getIo());
            sink.menu_job = null;
            sink.mutex.unlock(io_mod.getIo());
            return err;
        };
        thread.detach();
    }

    /// Cancels the menu's tool load, and drops the tools it had.
    fn stopMenuTools(self: *State) void {
        if (self.host_sink) |sink| {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            if (sink.menu_job) |job| job.cancel.store(true, .release);
            sink.menu_job = null;
            if (sink.menu_tools) |*done| done.arena.deinit();
            sink.menu_tools = null;
        }
        if (self.host_menu_tools_arena) |*arena| arena.deinit();
        self.host_menu_tools_arena = null;
        self.host_menu_tools = .loading;
    }

    fn takeMenuTools(self: *State) bool {
        const sink = self.host_sink orelse return false;
        sink.mutex.lockUncancelable(io_mod.getIo());
        const done = sink.menu_tools orelse {
            sink.mutex.unlock(io_mod.getIo());
            return false;
        };
        sink.menu_tools = null;
        sink.mutex.unlock(io_mod.getIo());
        if (done.load != self.host_menu_load) {
            done.arena.deinit();
            return false;
        }
        if (self.host_menu_tools_arena) |*old| old.deinit();
        self.host_menu_tools_arena = done.arena;
        self.host_menu_tools = done.tools;
        return true;
    }

    const MenuToolsJob = struct {
        state: *State,
        load: usize,
        name: []const u8,
        cancel: std.atomic.Value(bool) = .init(false),

        fn run(job: *MenuToolsJob) void {
            const a = std.heap.c_allocator;
            const self = job.state;
            defer {
                a.free(job.name);
                a.destroy(job);
                _ = self.host_verbs.fetchSub(1, .acq_rel);
            }
            var arena: std.heap.ArenaAllocator = .init(a);
            const tools = job.list(arena.allocator()) catch |err| switch (err) {
                error.OutOfMemory => mcp_menu.Tools{ .failed = "fx ran out of memory" },
                else => mcp_menu.Tools{ .failed = "the server stopped answering" },
            };
            const sink = self.host_sink orelse return arena.deinit();
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            // Left or replaced while it ran: nobody wants these.
            if (sink.menu_job != job) return arena.deinit();
            sink.menu_job = null;
            if (sink.menu_tools) |*old| old.arena.deinit();
            sink.menu_tools = .{ .load = job.load, .arena = arena, .tools = tools };
        }

        fn list(job: *MenuToolsJob, arena: Allocator) !mcp_menu.Tools {
            const lease = job.state.leaseHost() orelse return .{ .failed = "MCP isn't running" };
            defer lease.deinit();
            return switch (try lease.host.runtime.tools(arena, job.name, &job.cancel)) {
                .tools => |found| blk: {
                    const out = try arena.alloc(mcp_menu.Tool, found.len);
                    for (found, out) |t, *o| o.* = .{ .name = t.name, .description = (try mcp_verbs.toolDescription(arena, t.raw)) orelse "" };
                    break :blk .{ .ready = out };
                },
                .needs_login => .needs_login,
                .failed => |reason| .{ .failed = reason },
                .unknown_server => .{ .failed = "it's no longer configured" },
            };
        }
    };

    pub fn hasTool(self: *State, name: []const u8, access: tool_mcp_runtime.Access) bool {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.hasTool(name, access);
        }
        return false;
    }

    pub fn validateTool(
        self: *State,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.ValidationResult {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.validateTool(arena, name, arguments_json, access);
        }
        return .not_available;
    }

    pub fn callTool(
        self: *State,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.callTool(arena, name, arguments_json, max_tool_result_bytes, options);
        }
        return null;
    }

    pub fn searchTools(
        self: *State,
        arena: Allocator,
        request: tool_mcp_runtime.SearchRequest,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !tool_mcp_runtime.SearchResult {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.searchTools(arena, request, permission_rules, limits, access, cancel_flag);
        }
        return .{ .model_output = try arena.dupe(u8, "{\"tools\":[],\"count\":0}") };
    }

    pub fn toolSchema(
        self: *State,
        arena: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !?tool_mcp_runtime.ToolSchemaResult {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.toolSchema(arena, name, permission_rules, limits, access, cancel_flag);
        }
        return null;
    }

    pub fn snapshotToolDefinition(self: *State, alloc: Allocator, name: []const u8, known: tool_mcp_runtime.Binding, permission_rules: types.PermissionRuleSet, limits: context_limits.Values, access: tool_mcp_runtime.Access) !tool_mcp_runtime.DefinitionSnapshot {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.snapshotToolDefinition(alloc, name, known, permission_rules, limits, access);
        }
        return .unavailable;
    }

    pub fn snapshotToolNames(
        self: *State,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
    ) ![][]u8 {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.snapshotToolNames(alloc, permission_rules);
        }
        return alloc.alloc([]u8, 0);
    }

    pub fn snapshotAccessView(
        self: *State,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
        permission_rules: types.PermissionRuleSet,
    ) !?mcp_access.View {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return try l.host.catalog.snapshotAccessView(alloc, owner_id, parent_id, permission_rules);
        }
        return null;
    }

    pub fn snapshotModelCatalog(
        self: *State,
        alloc: Allocator,
        baseline_alloc: Allocator,
    ) !mcp_model_catalog.Report {
        var snapshot = if (self.leaseHost()) |l| leased: {
            defer l.deinit();
            break :leased try l.host.catalog.modelSnapshot(alloc);
        } else return .{ .snapshot = try mcp_model_catalog.Snapshot.empty(alloc) };
        errdefer snapshot.deinit(alloc);
        const notice = try self.updateModelCatalogBaseline(alloc, baseline_alloc, snapshot.servers);
        return .{ .snapshot = snapshot, .change_notice = notice };
    }

    /// Compares the freshly rendered model catalog against the availability
    /// the previous report showed the model, returning an owned note when it
    /// changed. `baseline_alloc` owns the retained baseline and must be the
    /// same long-lived allocator across calls and `deinit`.
    fn updateModelCatalogBaseline(
        self: *State,
        alloc: Allocator,
        baseline_alloc: Allocator,
        current: []const mcp_model_catalog.ServerSummary,
    ) !?[]u8 {
        // A discovery pass that is still settling is not a model-visible
        // change; wait for a stable listing before teaching the model about
        // availability deltas so session startup never renders a notice.
        for (current) |server| {
            if (server.availability == .discovering) return null;
        }
        self.model_catalog_baseline_lock.lockUncancelable(io_mod.getIo());
        defer self.model_catalog_baseline_lock.unlock(io_mod.getIo());
        const notice = if (self.model_catalog_baseline) |baseline|
            try mcp_model_catalog.renderChangeNotice(alloc, baseline, current)
        else
            null;
        errdefer if (notice) |text| alloc.free(text);
        try self.replaceModelCatalogBaselineLocked(baseline_alloc, current);
        return notice;
    }

    fn replaceModelCatalogBaselineLocked(
        self: *State,
        baseline_alloc: Allocator,
        current: []const mcp_model_catalog.ServerSummary,
    ) !void {
        var next = try baseline_alloc.alloc(mcp_model_catalog.BaselineEntry, current.len);
        var initialized: usize = 0;
        errdefer {
            for (next[0..initialized]) |entry| baseline_alloc.free(entry.name);
            baseline_alloc.free(next);
        }
        for (current, 0..) |server, index| {
            next[index] = .{
                .name = try baseline_alloc.dupe(u8, server.name),
                .availability = server.availability,
            };
            initialized += 1;
        }
        self.clearModelCatalogBaselineLocked(baseline_alloc);
        self.model_catalog_baseline = next;
    }

    fn clearModelCatalogBaselineLocked(self: *State, baseline_alloc: Allocator) void {
        const baseline = self.model_catalog_baseline orelse return;
        for (baseline) |entry| baseline_alloc.free(entry.name);
        baseline_alloc.free(baseline);
        self.model_catalog_baseline = null;
    }

    /// At exit: once `process_exiting` is set, `destroyHost` signals the
    /// servers and waits for nothing.
    pub fn deinitForProcessExit(self: *State) void {
        self.process_exiting.store(true, .release);
        self.destroyHost();
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.destroyHost();
        self.model_catalog_baseline_lock.lockUncancelable(io_mod.getIo());
        self.clearModelCatalogBaselineLocked(alloc);
        self.model_catalog_baseline_lock.unlock(io_mod.getIo());
        self.* = .{};
    }
};

test "a typed /mcp login names its server wherever --no-browser goes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { args: []const []const u8, server: ?[]const u8 }{
        .{ .args = &.{ "login", "web" }, .server = "web" },
        .{ .args = &.{ "login", "--no-browser", "web" }, .server = "web" },
        .{ .args = &.{ "login", "web", "--no-browser" }, .server = "web" },
        .{ .args = &.{ "login", "--no-browser" }, .server = null },
        .{ .args = &.{ "login", "web", "docs" }, .server = null },
        .{ .args = &.{ "login", "web", "--json" }, .server = null },
        .{ .args = &.{ "login", "web", "--help" }, .server = null },
        .{ .args = &.{"login"}, .server = null },
        .{ .args = &.{}, .server = null },
        .{ .args = &.{ "logout", "web" }, .server = null },
        .{ .args = &.{ "show", "web" }, .server = null },
    };
    for (cases) |case| {
        const server = try typedLoginServer(arena.allocator(), case.args);
        if (case.server) |want| {
            try std.testing.expectEqualStrings(want, server orelse return error.TestExpectedEqual);
        } else try std.testing.expectEqual(@as(?[]const u8, null), server);
    }
}

test "model catalog baseline surfaces availability changes once" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const before = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .authentication_required },
    };
    const first = try state.updateModelCatalogBaseline(alloc, alloc, &before);
    try std.testing.expectEqual(@as(?[]u8, null), first);

    const after = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .ready, .tool_count = 74 },
    };
    const changed = try state.updateModelCatalogBaseline(alloc, alloc, &after);
    defer if (changed) |notice| alloc.free(notice);
    try std.testing.expect(changed != null);
    try std.testing.expect(std.mem.find(u8, changed.?, "linear: authentication_required -> ready (74 tools)") != null);

    const settled = try state.updateModelCatalogBaseline(alloc, alloc, &after);
    try std.testing.expectEqual(@as(?[]u8, null), settled);
}

test "model catalog baseline waits out discovery before recording state" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const discovering = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .discovering },
    };
    const during_discovery = try state.updateModelCatalogBaseline(alloc, alloc, &discovering);
    try std.testing.expectEqual(@as(?[]u8, null), during_discovery);
    try std.testing.expect(state.model_catalog_baseline == null);

    const ready = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .ready, .tool_count = 74 },
    };
    const settled = try state.updateModelCatalogBaseline(alloc, alloc, &ready);
    try std.testing.expectEqual(@as(?[]u8, null), settled);
    try std.testing.expect(state.model_catalog_baseline != null);

    const failed = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .failed },
    };
    const outage = try state.updateModelCatalogBaseline(alloc, alloc, &failed);
    defer if (outage) |notice| alloc.free(notice);
    try std.testing.expect(outage != null);
    try std.testing.expect(std.mem.find(u8, outage.?, "linear: ready -> failed") != null);
}

test "model catalog baseline reports removals" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const before = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("slack"), .availability = .ready, .tool_count = 3 },
    };
    _ = try state.updateModelCatalogBaseline(alloc, alloc, &before);

    const removed = try state.updateModelCatalogBaseline(alloc, alloc, &.{});
    defer if (removed) |notice| alloc.free(notice);
    try std.testing.expect(removed != null);
    try std.testing.expect(std.mem.find(u8, removed.?, "slack: removed") != null);
}

test "a typed sign-in reports in the transcript, any other on the status line" {
    var sink: State.HostSink = .{};
    defer sink.deinit();
    const notify = sink.notify();
    sink.markTyped("docs");
    notify.notice(notify.context, .{ .authorize = .{ .server = "docs", .url = "https://a.example/authorize" } });
    notify.notice(notify.context, .{ .signed_in = "docs" });
    try std.testing.expectEqual(@as(usize, 2), sink.notices.items.len);
    try std.testing.expectEqualStrings("Signed in to docs.", sink.notices.items[1].text);
    try std.testing.expect(sink.news == null);
    // Once reported, the next sign-in to it isn't typed.
    notify.notice(notify.context, .{ .authorize = .{ .server = "docs", .url = "https://a.example/authorize" } });
    try std.testing.expect(sink.sign_in != null);
    notify.notice(notify.context, .{ .sign_in_failed = .{ .server = "docs", .reason = "it said no" } });
    try std.testing.expectEqual(@as(usize, 2), sink.notices.items.len);
    try std.testing.expectEqualStrings("Couldn't sign in to docs: it said no.", sink.news.?);
    try std.testing.expect(sink.sign_in == null);
    // Needing a login is the status line's to say.
    notify.notice(notify.context, .{ .needs_login = "docs" });
    try std.testing.expectEqual(@as(usize, 2), sink.notices.items.len);
}
