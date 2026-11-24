const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const elicitation = @import("../mcp/elicitation.zig");
const workspace_config = @import("../mcp/workspace_config.zig");
const mcp_host = @import("../mcp_host/host.zig");
const catalog_state = @import("../mcp/catalog_state.zig");
const mcp_verbs = @import("../mcp_host/verbs.zig");
const mcp_menu = @import("../mcp_host/menu.zig");
const login_words = @import("../mcp_host/login_words.zig");
const config_file = @import("../mcp_host/config_file.zig");
const config_runtime = @import("../config/config_runtime.zig");
const profile_paths = @import("../shared/profile_paths.zig");
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

/// What decides the servers fx runs in `workspace_root`, hashed: the
/// profile's `mcp.json`, the project's `.mcp.json`, and the project servers
/// the user approved or rejected, read the way `loadNativeConfigs` in
/// `src/builtins/mcp.zig` reads them. A file fx can't read hashes as its
/// error, so a lasting problem changes the stamp once, not at every check.
fn configStamp(alloc: Allocator, home: ?[]const u8, workspace_root: []const u8) u64 {
    var h: std.hash.Wyhash = .init(0);
    if (home) |dir| stampFile(alloc, &h, readProfileConfig(alloc, dir));
    stampFile(alloc, &h, workspace_config.readFile(alloc, workspace_root));
    if (home) |dir| {
        if (config_runtime.loadProjectMcpChoicesFromHome(alloc, dir, workspace_root)) |loaded| {
            var load = loaded;
            defer load.deinit(alloc);
            h.update(&.{ 1, @intFromBool(load.choices.enable_all) });
            for ([_][]const []u8{ load.choices.approved, load.choices.rejected }) |names| {
                h.update(std.mem.asBytes(&names.len));
                for (names) |name| stampBytes(&h, name);
            }
        } else |err| stampError(&h, err);
    }
    return h.final();
}

fn readProfileConfig(alloc: Allocator, home: []const u8) anyerror!?[]u8 {
    const path = try profile_paths.mcpConfigPath(alloc, home);
    defer alloc.free(path);
    return config_file.read(alloc, path);
}

/// A config file read into `h`: its bytes, or that it's absent or unreadable.
fn stampFile(alloc: Allocator, h: *std.hash.Wyhash, read: anyerror!?[]u8) void {
    const text = read catch |err| return stampError(h, err);
    const bytes = text orelse return h.update(&.{0});
    defer alloc.free(bytes);
    h.update(&.{1});
    stampBytes(h, bytes);
}

fn stampBytes(h: *std.hash.Wyhash, bytes: []const u8) void {
    h.update(std.mem.asBytes(&bytes.len));
    h.update(bytes);
}

fn stampError(h: *std.hash.Wyhash, err: anyerror) void {
    h.update(&.{2});
    stampBytes(h, @errorName(err));
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
    /// The config files as of the last load (`configStamp`), so a change made
    /// outside this session is noticed the next time it uses MCP.
    host_config_stamp: ?u64 = null,
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

    /// Loads the host at startup with `load`, which reloads use too. The host's
    /// lifecycle is modeled in `tests/tla/mcp_host/HostLifecycle.tla`.
    pub fn loadHost(
        self: *State,
        load: mcp_host.LoadFn,
        alloc: Allocator,
        home: ?[]const u8,
        workspace_root: []const u8,
        registry: tool_dispatch.Registry,
        questions: elicitation.Capabilities,
    ) !void {
        self.host_load = load;
        self.host_questions = questions;
        if (self.host_sink == null) {
            const sink = try std.heap.c_allocator.create(HostSink);
            sink.* = .{ .offer_paste = !mcp_verbs.canOpenBrowser() };
            self.host_sink = sink;
        }
        // Read before the load, so a change between the two loads again at
        // the next check instead of going unnoticed.
        self.host_config_stamp = configStamp(alloc, home, workspace_root);
        self.replaceHost(try load(alloc, workspace_root, registry, .{ .questions = questions, .notify = self.host_sink.?.notify(), .slash_commands = true }));
    }

    pub const RefreshCheck = enum {
        /// Only a change a `/mcp` command made.
        requested,
        /// Also the config files, for a change made outside this session:
        /// `fx mcp add` in a shell, an edit, or another fx.
        files,
    };

    /// On the UI thread: loads the config again when a `/mcp` command changed
    /// it, or, with `.files`, when the config files changed since the last
    /// load. True when it loaded. A load that fails keeps the current servers
    /// and says so once per change, since the stamp it read is kept.
    pub fn refreshHost(
        self: *State,
        alloc: Allocator,
        home: ?[]const u8,
        workspace_root: []const u8,
        registry: tool_dispatch.Registry,
        check: RefreshCheck,
    ) bool {
        if (self.host_load == null) return false;
        const requested = self.takeHostReload();
        if (!requested and check == .requested) return false;
        // Read before the load, as in `loadHost`.
        const stamp = configStamp(alloc, home, workspace_root);
        if (!requested) if (self.host_config_stamp) |last| if (last == stamp) return false;
        self.host_config_stamp = stamp;
        debug_trace.logf("mcp", "MCP config loaded again reason={s}", .{if (requested) "mcp_command" else "config_files_changed"});
        self.reloadHost(alloc, workspace_root, registry) catch |err| {
            debug_trace.logf("mcp", "MCP reload failed err={s}", .{@errorName(err)});
            const sink = self.host_sink orelse return true;
            sink.push(std.heap.c_allocator.print("The MCP config changed, but fx couldn't load it: {s}. Your current servers are still active.", .{mcp_verbs.describe(err)}) catch return true, true);
        };
        return true;
    }

    /// Loads the config again after it changed. The host takes it in place,
    /// so only a server whose config changed restarts. A new host comes only
    /// when there was none, or the last server went; calls still using an old
    /// one finish on it.
    fn reloadHost(self: *State, alloc: Allocator, workspace_root: []const u8, registry: tool_dispatch.Registry) !void {
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

    /// Who serves the MCP tool `name` (`Catalog.toolIdentity`), copied into
    /// `alloc`; null when there is no host or no loaded list has it.
    pub fn toolIdentity(self: *State, alloc: Allocator, name: []const u8) Allocator.Error!?catalog_state.ToolIdentity {
        const lease = self.leaseHost() orelse return null;
        defer lease.deinit();
        return lease.host.catalog.toolIdentity(alloc, name);
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
        /// The last sign-in that ended, as `sign_in` is, so its return pasted late is held back, not sent. Owned.
        ended_sign_in: ?[]u8 = null,
        /// The server `/mcp add` just added, to sign in to once the host has
        /// loaded it and it asks for a login (`State.signInAfterAdd`). Owned.
        sign_in_when_loaded: ?[]u8 = null,
        /// The waiting sign-in's return was pasted, so the menu stops offering the link.
        sign_in_pasted: bool = false,
        /// fx can't open a browser here, so a sign-in offers to take its pasted return.
        offer_paste: bool = false,

        fn deinit(sink: *HostSink) void {
            if (sink.menu_tools) |*done| done.arena.deinit();
            if (sink.sign_in) |waiting| std.heap.c_allocator.free(waiting);
            if (sink.ended_sign_in) |ended| std.heap.c_allocator.free(ended);
            if (sink.sign_in_when_loaded) |name| std.heap.c_allocator.free(name);
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
                    // The menu shows the address; a typed login links it.
                    if (!sink.isTyped(n.server)) return;
                    sink.pushLocked(signInText(a, aa, n.server, n.url, sink.offer_paste) catch return, false);
                },
                .signed_in => |server| {
                    sink.endSignIn(server);
                    sink.report(server, a.print("Signed in to {s}.", .{safeText(aa, server, 160)}) catch return, false);
                },
                // The login is kept, but the request that checks it got no answer about the token.
                .signed_in_unchecked => |server| {
                    sink.endSignIn(server);
                    sink.report(server, a.print("Signed in to {s}, but fx couldn't check the login with it.", .{safeText(aa, server, 160)}) catch return, false);
                },
                // A refusal carries the server's own error, which can run past 240.
                .sign_in_failed => |n| {
                    sink.endSignIn(n.server);
                    sink.report(n.server, a.print("Couldn't sign in to {s}: {s}.", .{ safeText(aa, n.server, 160), safeText(aa, n.reason, login_words.max_failure_bytes) }) catch return, true);
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
            sink.sign_in_pasted = false;
        }

        const SignInParts = struct { server: []const u8, url: []const u8 };

        /// Null when there is no 0 byte: `waitForSignIn` always writes one.
        fn splitWaiting(waiting: []const u8) ?SignInParts {
            const end = std.mem.findScalar(u8, waiting, 0) orelse return null;
            return .{ .server = waiting[0..end], .url = waiting[end + 1 ..] };
        }

        const PasteDecision = union(enum) {
            not_a_return,
            other_sign_in: []const u8,
            already_pasted: []const u8,
            ended: []const u8,
            start: struct { server: []const u8, address: []const u8 },
        };

        /// Locked by the caller. The strings it returns are owned by `arena`.
        fn decidePaste(sink: *HostSink, arena: Allocator, text: []const u8) !PasteDecision {
            if (try decideWaitingPaste(sink, arena, text)) |decision| return decision;
            return decideEndedPaste(sink, arena, text);
        }

        /// Null when `text` is not a return to the sign-in that waits.
        fn decideWaitingPaste(sink: *HostSink, arena: Allocator, text: []const u8) !?PasteDecision {
            const waiting = splitWaiting(sink.sign_in orelse return null) orelse return null;
            switch (try mcp_host.classifyPasted(arena, waiting.url, text)) {
                .unrelated => return null,
                .other_sign_in => return PasteDecision{ .other_sign_in = try arena.dupe(u8, waiting.server) },
                .this_sign_in => |address| return try startDecision(sink, arena, waiting.server, address),
            }
        }

        fn startDecision(sink: *HostSink, arena: Allocator, server: []const u8, address: []const u8) !PasteDecision {
            const owned_server = try arena.dupe(u8, server);
            if (sink.sign_in_pasted) return .{ .already_pasted = owned_server };
            sink.sign_in_pasted = true;
            return .{ .start = .{ .server = owned_server, .address = address } };
        }

        /// A return to the sign-in that ended, of its state or another's, is held back.
        fn decideEndedPaste(sink: *HostSink, arena: Allocator, text: []const u8) !PasteDecision {
            const ended = splitWaiting(sink.ended_sign_in orelse return .not_a_return) orelse return .not_a_return;
            switch (try mcp_host.classifyPasted(arena, ended.url, text)) {
                .unrelated => return .not_a_return,
                .this_sign_in, .other_sign_in => return .{ .ended = try arena.dupe(u8, ended.server) },
            }
        }

        /// Why a paste didn't finish its sign-in, in words for the notice.
        fn pasteFailureReason(err: anyerror) []const u8 {
            return switch (err) {
                error.NotSigningIn => "the sign-in has ended",
                error.NoMcpHost => "fx's MCP servers aren't running",
                else => "fx couldn't start it",
            };
        }

        /// A paste that didn't finish its sign-in says why, on the UI thread
        /// or off it, and the next paste or `/mcp login` can try again. The
        /// address never appears.
        fn pasteFailed(sink: *HostSink, server: []const u8, err: anyerror) void {
            debug_trace.logf("mcp", "MCP pasted sign-in return failed server={s} err={s}", .{ server, @errorName(err) });
            var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
            defer arena.deinit();
            const name = safeText(arena.allocator(), server, 160);
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            if (sink.sign_in) |waiting| {
                if (splitWaiting(waiting)) |parts| {
                    if (std.mem.eql(u8, parts.server, server)) sink.sign_in_pasted = false;
                }
            }
            const text = std.heap.c_allocator.print("Couldn't finish signing in to {s}: {s}. Try /mcp login {s} again.", .{ name, pasteFailureReason(err), name }) catch return;
            sink.pushLocked(text, true);
        }

        /// Locked by the caller. The sign-in that ends is kept, so a return pasted late is held back.
        fn endSignIn(sink: *HostSink, server: []const u8) void {
            const waiting = sink.sign_in orelse return;
            const parts = splitWaiting(waiting) orelse return;
            if (!std.mem.eql(u8, parts.server, server)) return;
            if (sink.ended_sign_in) |old| std.heap.c_allocator.free(old);
            sink.ended_sign_in = waiting;
            sink.sign_in = null;
            sink.sign_in_pasted = false;
        }

        /// Puts back the sign-in `State.signInAfterAdd` still waits on,
        /// unless `/mcp add` named another server meanwhile. Takes `name`.
        fn keepSignInWhenLoaded(sink: *HostSink, name: []u8) void {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            if (sink.sign_in_when_loaded == null) {
                sink.sign_in_when_loaded = name;
                return;
            }
            debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=another server was added", .{name});
            std.heap.c_allocator.free(name);
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

        /// What a typed login says once its address comes, owned by `alloc`:
        /// a link to it, or, when it can't be a link target, the address
        /// itself made safe, to copy. `offer_paste` adds the paste hint.
        fn signInText(alloc: Allocator, arena: Allocator, server: []const u8, url: []const u8, offer_paste: bool) ![]u8 {
            const name = safeText(arena, server, 160);
            if (text_utils.isLinkTarget(url))
                return alloc.print("Sign in to {s} in your browser. Didn't open? \x1b]8;id=fx-mcp-sign-in;{s}\x1b\\" ++ mcp_menu.sign_in_link_label ++ "\x1b]8;;\x1b\\.{s}", .{ name, url, if (offer_paste) " " ++ mcp_menu.paste_hint else "" });
            return alloc.print("Sign in to {s} in your browser. If it didn't open, go to:\n  {s}{s}", .{ name, safeText(arena, url, 16 * 1024), if (offer_paste) "\n  " ++ mcp_menu.paste_hint else "" });
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
                .hosts = .{ .context = self, .get = getHost, .release = putHost, .changed = configChanged, .sign_in_when_loaded = signInWhenLoaded },
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

        fn signInWhenLoaded(context: *anyopaque, name: []const u8) void {
            const self: *State = @ptrCast(@alignCast(context));
            const sink = self.host_sink orelse return;
            const copy = std.heap.c_allocator.dupe(u8, name) catch {
                debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=out of memory", .{name});
                return;
            };
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            if (sink.sign_in_when_loaded) |old| {
                debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=another server was added", .{old});
                std.heap.c_allocator.free(old);
            }
            sink.sign_in_when_loaded = copy;
        }
    };

    /// On the UI thread, after each reload check: once the host has loaded
    /// the server `/mcp add` added and it asks for a login, signs in the way
    /// a typed `/mcp login` does, so the address and the outcome reach the
    /// transcript. A server that loads without asking, is held, or is gone
    /// ends the wait; one still connecting keeps it.
    pub fn signInAfterAdd(self: *State) void {
        const sink = self.host_sink orelse return;
        const name = take: {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            const name = sink.sign_in_when_loaded orelse return;
            sink.sign_in_when_loaded = null;
            break :take name;
        };
        var keep = false;
        defer if (keep) sink.keepSignInWhenLoaded(name) else std.heap.c_allocator.free(name);
        // The tick that loads the change hasn't come yet.
        if (self.host_reload_requested.load(.acquire)) {
            keep = true;
            return;
        }
        const lease = self.leaseHost() orelse return debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=no MCP host", .{name});
        defer lease.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        const statuses = lease.host.runtime.statusesNow(arena.allocator()) catch return debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=out of memory", .{name});
        const status = for (statuses) |s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else return debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=not in the loaded config", .{name});
        if (!status.needs_login) {
            keep = status.state == .idle or status.state == .connecting or status.state == .retrying;
            if (!keep) debug_trace.logf("mcp", "MCP sign-in after add not needed server={s} state={s}", .{ name, @tagName(status.state) });
            return;
        }
        // Its address and outcome go to the transcript, as a typed login's do.
        sink.markTyped(name);
        lease.host.runtime.login(name, mcp_verbs.canOpenBrowser()) catch |err| {
            debug_trace.logf("mcp", "MCP sign-in after add failed server={s} err={s}", .{ name, @errorName(err) });
            sink.mutex.lockUncancelable(io_mod.getIo());
            _ = sink.untype(name);
            sink.mutex.unlock(io_mod.getIo());
            sink.push(std.heap.c_allocator.print("Couldn't start signing in to {s}. Try /mcp login {s}.", .{ name, name }) catch return, true);
        };
    }

    /// What fx did with a line submitted while a sign-in may wait for the browser.
    pub const PastedSignIn = enum {
        /// Not that sign-in's return: the line goes on as usual.
        not_a_return,
        /// The sign-in's return, taken: the composer is cleared.
        taken,
        /// Kept in the composer; a notice says why.
        kept,
    };

    /// On the UI thread, for a line submitted while a sign-in waits for the
    /// browser. A return to that sign-in finishes it off this thread.
    pub fn takePastedSignIn(self: *State, text: []const u8) !PastedSignIn {
        const sink = self.host_sink orelse return .not_a_return;
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const decision = blk: {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            break :blk try sink.decidePaste(aa, text);
        };
        switch (decision) {
            .not_a_return => return .not_a_return,
            .other_sign_in => |server| {
                const notice = std.heap.c_allocator.print("That isn't the address of the sign-in to {s}. Paste the one the browser ends on after you approve.", .{HostSink.safeText(aa, server, 160)}) catch return .kept;
                sink.push(notice, true);
                return .kept;
            },
            .already_pasted => |server| {
                debug_trace.logf("mcp", "MCP pasted sign-in return ignored server={s} reason=already pasted", .{server});
                const notice = std.heap.c_allocator.print("fx is already finishing the sign-in to {s} with that address.", .{HostSink.safeText(aa, server, 160)}) catch return .kept;
                sink.push(notice, false);
                return .taken;
            },
            .ended => |server| {
                debug_trace.logf("mcp", "MCP pasted sign-in return held server={s} reason=sign-in ended", .{server});
                const name = HostSink.safeText(aa, server, 160);
                const notice = std.heap.c_allocator.print("That address is for a sign-in to {s} that has ended. Run /mcp login {s} to sign in again.", .{ name, name }) catch return .kept;
                sink.push(notice, true);
                return .taken;
            },
            .start => |start| {
                self.startPasteJob(start.server, start.address) catch |err| {
                    sink.pasteFailed(start.server, err);
                    return .kept;
                };
                return .taken;
            },
        }
    }

    fn startPasteJob(self: *State, server: []const u8, address: []const u8) !void {
        if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
        const a = std.heap.c_allocator;
        const server_copy = try a.dupe(u8, server);
        errdefer a.free(server_copy);
        const address_copy = try a.dupe(u8, address);
        errdefer a.free(address_copy);
        const job = try a.create(PasteJob);
        errdefer a.destroy(job);
        job.* = .{ .state = self, .server = server_copy, .address = address_copy };
        _ = self.host_verbs.fetchAdd(1, .acq_rel);
        errdefer _ = self.host_verbs.fetchSub(1, .acq_rel);
        const thread = try std.Thread.spawn(.{}, PasteJob.run, .{job});
        thread.detach();
    }

    const PasteJob = struct {
        state: *State,
        server: []u8,
        address: []u8,

        fn free(job: *PasteJob) void {
            const a = std.heap.c_allocator;
            a.free(job.server);
            a.free(job.address);
            a.destroy(job);
        }

        fn run(job: *PasteJob) void {
            const self = job.state;
            defer {
                job.free();
                _ = self.host_verbs.fetchSub(1, .acq_rel);
            }
            const sink = self.host_sink orelse return;
            const lease = self.leaseHost() orelse return sink.pasteFailed(job.server, error.NoMcpHost);
            defer lease.deinit();
            lease.host.runtime.finishLogin(job.server, job.address) catch |err| return sink.pasteFailed(job.server, err);
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
        const parts = HostSink.splitWaiting(waiting) orelse return null;
        if (!std.mem.eql(u8, parts.server, self.host_menu.selectedName())) return null;
        return parts.url;
    }

    /// Whether a waiting sign-in offers to take its pasted return: fx can't open a browser here.
    pub fn hostMenuOffersPaste(self: *const State) bool {
        const sink = self.host_sink orelse return false;
        return sink.offer_paste;
    }

    /// Copies the sink's waiting sign-in; true when it changed.
    fn takeSignIn(self: *State) bool {
        const sink = self.host_sink orelse return false;
        sink.mutex.lockUncancelable(io_mod.getIo());
        defer sink.mutex.unlock(io_mod.getIo());
        const now = if (sink.sign_in_pasted) null else sink.sign_in;
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
    ) ![][]u8 {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.snapshotToolNames(alloc);
        }
        return alloc.alloc([]u8, 0);
    }

    pub fn snapshotAccessView(
        self: *State,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
    ) !?mcp_access.View {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return try l.host.catalog.snapshotAccessView(alloc, owner_id, parent_id);
        }
        return null;
    }

    /// The names of the MCP servers the model may reach, for the toolbox
    /// menu. `alloc` owns the slice and each name.
    pub fn serverNames(self: *State, alloc: Allocator) ![]const []const u8 {
        const l = self.leaseHost() orelse return &.{};
        defer l.deinit();
        return l.host.catalog.serverNames(alloc);
    }

    /// At exit: once `process_exiting` is set, `destroyHost` signals the
    /// servers and waits for nothing.
    pub fn deinitForProcessExit(self: *State) void {
        self.process_exiting.store(true, .release);
        self.destroyHost();
    }

    pub fn deinit(self: *State) void {
        self.destroyHost();
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

test "a typed sign-in prints an address that can't be a link, to copy" {
    var sink: State.HostSink = .{};
    defer sink.deinit();
    const notify = sink.notify();
    sink.markTyped("docs");
    notify.notice(notify.context, .{ .authorize = .{ .server = "docs", .url = "https://a.example/a b\x1b[2J" } });
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    const text = sink.notices.items[0].text;
    try std.testing.expect(std.mem.startsWith(u8, text, "Sign in to docs in your browser. If it didn't open, go to:\n  https://a.example/a b"));
    try std.testing.expect(std.mem.findScalar(u8, text, 0x1b) == null);
}

test "a typed sign-in reports in the transcript, any other on the status line" {
    var sink: State.HostSink = .{};
    defer sink.deinit();
    const notify = sink.notify();
    sink.markTyped("docs");
    notify.notice(notify.context, .{ .authorize = .{ .server = "docs", .url = "https://a.example/authorize" } });
    notify.notice(notify.context, .{ .signed_in = "docs" });
    try std.testing.expectEqual(@as(usize, 2), sink.notices.items.len);
    // The address is a link under a few words, not printed out.
    try std.testing.expectEqualStrings(
        "Sign in to docs in your browser. Didn't open? \x1b]8;id=fx-mcp-sign-in;https://a.example/authorize\x1b\\Open the sign-in page\x1b]8;;\x1b\\.",
        sink.notices.items[0].text,
    );
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

fn writeTestFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try tmp.dir.createDirPath(io_mod.getIo(), parent);
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

test "the config stamp follows the MCP config files and project choices, and nothing else" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    const none = configStamp(alloc, home, root);
    try std.testing.expectEqual(none, configStamp(alloc, home, root));
    // An empty file isn't a missing one.
    try writeTestFile(&tmp, "home/.fx/mcp.json", "");
    const blank = configStamp(alloc, home, root);
    try std.testing.expect(blank != none);
    try writeTestFile(&tmp, "home/.fx/mcp.json",
        \\{"mcp":{"linear":{"url":"https://mcp.linear.app/mcp"}}}
    );
    const profile = configStamp(alloc, home, root);
    try std.testing.expect(profile != blank);
    try writeTestFile(&tmp, "workspace/.mcp.json",
        \\{"mcpServers":{"p":{"command":"p-server"}}}
    );
    const project = configStamp(alloc, home, root);
    try std.testing.expect(project != profile);

    // Settings other than the project's MCP choices, such as a model switch,
    // leave it as it was.
    const unrelated = try alloc.print("{{\"permission_mode\":\"auto\",\"workspaces\":{{\"{s}\":{{\"max_agent_steps\":10}}}}}}", .{root});
    defer alloc.free(unrelated);
    try writeTestFile(&tmp, "home/.fx/settings.json", unrelated);
    try std.testing.expectEqual(project, configStamp(alloc, home, root));

    const approved = try alloc.print("{{\"workspaces\":{{\"{s}\":{{\"" ++ @import("../mcp/project_config.zig").enabled_servers_key ++ "\":[\"p\"]}}}}}}", .{root});
    defer alloc.free(approved);
    try writeTestFile(&tmp, "home/.fx/settings.json", approved);
    // The approval is read, so the change below is the approval's.
    var load = try config_runtime.loadProjectMcpChoicesFromHome(alloc, home, root);
    defer load.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), load.choices.approved.len);
    try std.testing.expect(configStamp(alloc, home, root) != project);
}

const TestLoader = struct {
    var loads: usize = 0;
    var fail = false;

    fn load(_: Allocator, _: []const u8, _: tool_dispatch.Registry, _: mcp_host.Extras) anyerror!?*mcp_host.Host {
        loads += 1;
        if (fail) return error.McpConfigInvalidJson;
        return null;
    }
};

test "the host loads again when its config files change outside the session, once per change" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    TestLoader.loads = 0;
    TestLoader.fail = false;
    const registry: tool_dispatch.Registry = .{ .tools = &.{} };
    var state: State = .{};
    defer state.deinit();

    try state.loadHost(TestLoader.load, alloc, home, root, registry, .{});
    try std.testing.expectEqual(@as(usize, 1), TestLoader.loads);
    try std.testing.expect(!state.refreshHost(alloc, home, root, registry, .files));

    // `fx mcp add` in a shell writes the profile; only a check that reads the
    // files notices.
    try writeTestFile(&tmp, "home/.fx/mcp.json",
        \\{"mcp":{"linear":{"url":"https://mcp.linear.app/mcp"}}}
    );
    try std.testing.expect(!state.refreshHost(alloc, home, root, registry, .requested));
    try std.testing.expect(state.refreshHost(alloc, home, root, registry, .files));
    try std.testing.expectEqual(@as(usize, 2), TestLoader.loads);
    try std.testing.expect(!state.refreshHost(alloc, home, root, registry, .files));

    // A `/mcp` command's own change loads even when the files read the same.
    state.host_reload_requested.store(true, .release);
    try std.testing.expect(state.refreshHost(alloc, home, root, registry, .requested));
    try std.testing.expectEqual(@as(usize, 3), TestLoader.loads);

    // A load that fails warns once for the change, not at every check.
    TestLoader.fail = true;
    try writeTestFile(&tmp, "workspace/.mcp.json",
        \\{"mcpServers":{"p":{"command":"p-server"}}}
    );
    try std.testing.expect(state.refreshHost(alloc, home, root, registry, .files));
    try std.testing.expect(!state.refreshHost(alloc, home, root, registry, .files));
    try std.testing.expectEqual(@as(usize, 4), TestLoader.loads);
    const notices = state.takeHostNotices();
    defer {
        for (notices) |n| std.heap.c_allocator.free(n.text);
        std.heap.c_allocator.free(notices);
    }
    try std.testing.expectEqual(@as(usize, 1), notices.len);
    try std.testing.expect(notices[0].warning);
    try std.testing.expectEqualStrings("The MCP config changed, but fx couldn't load it: ~/.fx/mcp.json isn't valid JSON. Your current servers are still active.", notices[0].text);
}

const pasted_authorize = "https://as.example/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A41723%2Fcallback&state=s1";
const pasted_return = "http://127.0.0.1:41723/callback?code=c1&state=s1";

fn lockedWaitForSignIn(sink: *State.HostSink, server: []const u8, url: []const u8) void {
    sink.mutex.lockUncancelable(io_mod.getIo());
    defer sink.mutex.unlock(io_mod.getIo());
    sink.waitForSignIn(server, url);
}

fn waitForPasteJobs(state: *State) !void {
    var waited: usize = 0;
    while (state.host_verbs.load(.acquire) > 0) : (waited += 1) {
        if (waited == 2000) return error.PasteJobStillRunning;
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
}

test "a pasted line with no sign-in waiting is not a return" {
    var state: State = .{};
    var sink: State.HostSink = .{};
    defer sink.deinit();
    try std.testing.expectEqual(State.PastedSignIn.not_a_return, try state.takePastedSignIn("fix the build"));
    try std.testing.expectEqual(State.PastedSignIn.not_a_return, try state.takePastedSignIn(pasted_return));
    state.host_sink = &sink;
    try std.testing.expectEqual(State.PastedSignIn.not_a_return, try state.takePastedSignIn("fix the build"));
    try std.testing.expectEqual(State.PastedSignIn.not_a_return, try state.takePastedSignIn(pasted_return));
    try std.testing.expectEqual(@as(usize, 0), sink.notices.items.len);
}

test "a pasted prompt during a waiting sign-in is not a return, and says nothing" {
    var state: State = .{};
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    try std.testing.expectEqual(State.PastedSignIn.not_a_return, try state.takePastedSignIn("fix the build"));
    try std.testing.expectEqual(@as(usize, 0), sink.notices.items.len);
    try std.testing.expect(!sink.sign_in_pasted);
}

test "a pasted return of another state is kept, with one warning that shows no state or code" {
    var state: State = .{};
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    try std.testing.expectEqual(State.PastedSignIn.kept, try state.takePastedSignIn("http://127.0.0.1:41723/callback?code=c1&state=s2"));
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    try std.testing.expect(sink.notices.items[0].warning);
    const text = sink.notices.items[0].text;
    try std.testing.expect(std.mem.find(u8, text, "s2") == null);
    try std.testing.expect(std.mem.find(u8, text, "code=") == null);
    try std.testing.expect(!sink.sign_in_pasted);
}

test "a pasted return while one is already being finished is taken, with one notice that is not a warning" {
    var state: State = .{};
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    sink.sign_in_pasted = true;
    try std.testing.expectEqual(State.PastedSignIn.taken, try state.takePastedSignIn(pasted_return));
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    try std.testing.expect(!sink.notices.items[0].warning);
    try std.testing.expectEqualStrings("fx is already finishing the sign-in to fixture with that address.", sink.notices.items[0].text);
    try std.testing.expectEqual(@as(usize, 0), state.host_verbs.load(.acquire));
}

test "a pasted return with no MCP host is taken, then fails with one warning that names the server and shows no code" {
    var state: State = .{};
    try std.testing.expect(state.leaseHost() == null);
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    try std.testing.expectEqual(State.PastedSignIn.taken, try state.takePastedSignIn(pasted_return));
    try waitForPasteJobs(&state);
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    try std.testing.expect(sink.notices.items[0].warning);
    try std.testing.expectEqualStrings("Couldn't finish signing in to fixture: fx's MCP servers aren't running. Try /mcp login fixture again.", sink.notices.items[0].text);
    try std.testing.expect(!sink.sign_in_pasted);
}

test "takeSignIn gives the menu no address while a pasted return is being finished, and the address again for a new sign-in" {
    var state: State = .{};
    defer if (state.host_menu_sign_in) |waiting| std.heap.c_allocator.free(waiting);
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    sink.sign_in_pasted = true;
    _ = state.takeSignIn();
    try std.testing.expect(state.host_menu_sign_in == null);
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    try std.testing.expect(state.takeSignIn());
    try std.testing.expect(state.host_menu_sign_in != null);
}

test "a sign-in text offers the pasted address step only when asked, for linkable and unlinkable addresses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "https://a.example/authorize", "https://a.example/a b" }) |url| {
        const with = try State.HostSink.signInText(std.testing.allocator, arena.allocator(), "docs", url, true);
        defer std.testing.allocator.free(with);
        try std.testing.expect(std.mem.find(u8, with, "Paste the address it ends on.") != null);
        const without = try State.HostSink.signInText(std.testing.allocator, arena.allocator(), "docs", url, false);
        defer std.testing.allocator.free(without);
        try std.testing.expect(std.mem.find(u8, without, "Paste the address it ends on.") == null);
    }
}

test "a pasted return hint is offered on a sign-in notice when the sink says fx can't open a browser" {
    var sink: State.HostSink = .{ .offer_paste = true };
    defer sink.deinit();
    const notify = sink.notify();
    sink.markTyped("docs");
    notify.notice(notify.context, .{ .authorize = .{ .server = "docs", .url = "https://a.example/authorize" } });
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    try std.testing.expect(std.mem.endsWith(u8, sink.notices.items[0].text, "Open the sign-in page\x1b]8;;\x1b\\. Browser on another computer? Paste the address it ends on."));
}

test "a pasted return longer than the paste fold limit is still taken, with one warning and no code" {
    var state: State = .{};
    try std.testing.expect(state.leaseHost() == null);
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    const prefix = "http://127.0.0.1:41723/callback?code=";
    const padding_len = 1200;
    const suffix = "&state=s1";
    var long: [prefix.len + padding_len + suffix.len]u8 = undefined;
    @memcpy(long[0..prefix.len], prefix);
    @memset(long[prefix.len..][0..padding_len], 'a');
    @memcpy(long[prefix.len + padding_len ..], suffix);
    try std.testing.expectEqual(State.PastedSignIn.taken, try state.takePastedSignIn(&long));
    try waitForPasteJobs(&state);
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    try std.testing.expect(sink.notices.items[0].warning);
    try std.testing.expect(std.mem.find(u8, sink.notices.items[0].text, "code=") == null);
}

fn lockedEndSignIn(sink: *State.HostSink, server: []const u8) void {
    sink.mutex.lockUncancelable(io_mod.getIo());
    defer sink.mutex.unlock(io_mod.getIo());
    sink.endSignIn(server);
}

const ended_notice = "That address is for a sign-in to fixture that has ended. Run /mcp login fixture to sign in again.";

test "a pasted return after its sign-in ended is taken, with one warning that names the server and shows no code" {
    var state: State = .{};
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    lockedEndSignIn(&sink, "fixture");
    try std.testing.expectEqual(State.PastedSignIn.taken, try state.takePastedSignIn(pasted_return));
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    try std.testing.expect(sink.notices.items[0].warning);
    try std.testing.expectEqualStrings(ended_notice, sink.notices.items[0].text);
}

test "a pasted prompt after its sign-in ended is not a return, and says nothing" {
    var state: State = .{};
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    lockedEndSignIn(&sink, "fixture");
    try std.testing.expectEqual(State.PastedSignIn.not_a_return, try state.takePastedSignIn("fix the build"));
    try std.testing.expectEqual(@as(usize, 0), sink.notices.items.len);
}

test "a pasted return of another state after its sign-in ended is held too, with the same warning" {
    var state: State = .{};
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    lockedEndSignIn(&sink, "fixture");
    try std.testing.expectEqual(State.PastedSignIn.taken, try state.takePastedSignIn("http://127.0.0.1:41723/callback?code=c1&state=s2"));
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    try std.testing.expect(sink.notices.items[0].warning);
    try std.testing.expectEqualStrings(ended_notice, sink.notices.items[0].text);
}

test "a pasted return works as before once the same server waits for a new sign-in" {
    var state: State = .{};
    try std.testing.expect(state.leaseHost() == null);
    var sink: State.HostSink = .{};
    defer sink.deinit();
    state.host_sink = &sink;
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    lockedEndSignIn(&sink, "fixture");
    lockedWaitForSignIn(&sink, "fixture", pasted_authorize);
    try std.testing.expectEqual(State.PastedSignIn.taken, try state.takePastedSignIn(pasted_return));
    try waitForPasteJobs(&state);
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    try std.testing.expectEqualStrings("Couldn't finish signing in to fixture: fx's MCP servers aren't running. Try /mcp login fixture again.", sink.notices.items[0].text);
}

test "a pasted return whose sign-in is gone by the time it finishes says the sign-in ended, and shows no code" {
    var sink: State.HostSink = .{};
    defer sink.deinit();
    sink.pasteFailed("fixture", error.NotSigningIn);
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    try std.testing.expect(sink.notices.items[0].warning);
    try std.testing.expectEqualStrings("Couldn't finish signing in to fixture: the sign-in has ended. Try /mcp login fixture again.", sink.notices.items[0].text);
}
