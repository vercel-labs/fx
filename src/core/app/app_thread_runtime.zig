//! `/thread`: named threads of work that run beside the current session.
//!
//! A thread is a persistent subagent child of the root session with its own
//! saved session and context. This file parses the slash command and drives
//! the subagent host; `core/threads` holds the pure parts.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const thread_registry = @import("../threads/thread_registry.zig");
const thread_menu = @import("../threads/thread_menu.zig");
const thread_feed = @import("../threads/thread_feed.zig");
const thread_tools = @import("../threads/thread_tools.zig");

const Allocator = std.mem.Allocator;

pub const usage = "usage: /thread (menu) | /thread INSTRUCTIONS | new NAME TASK | list | status | switch NAME | watch NAME [LINES] | send NAME MESSAGE | stop NAME | rename OLD NEW | delete NAME";
const menu_refresh_ms: i64 = 700;

/// Lines a live view keeps on screen; older ones scroll out of it.
const follow_lines: usize = 12;
const follow_interval_ms: i64 = 120;

/// The one live view `/thread watch NAME` keeps up to date. It owns no
/// allocations: the text is rebuilt from the thread's feed on each refresh.
pub const WatchState = struct {
    active: bool = false,
    entry_id: u32 = 0,
    /// The subagent host the view was started on. A different host means the
    /// session changed and the view ends.
    host: usize = 0,
    child_id_buf: [64]u8 = undefined,
    child_id_len: usize = 0,
    name_buf: [thread_registry.max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    started_ms: i64 = 0,
    last_refresh_ms: i64 = 0,
    last_hash: u64 = 0,

    fn childId(self: *const WatchState) []const u8 {
        return self.child_id_buf[0..self.child_id_len];
    }

    fn name(self: *const WatchState) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Action = union(enum) {
    list,
    /// Which threads are still working, and what each last did.
    status,
    /// Free-form instructions: start a thread named from them.
    start: []const u8,
    new: struct { name: []const u8, task: []const u8 },
    /// `lines` null follows the thread live; a count prints that many once.
    watch: struct { name: []const u8, lines: ?usize },
    send: struct { name: []const u8, message: []const u8 },
    stop: []const u8,
    @"switch": []const u8,
    rename: struct { old: []const u8, new: []const u8 },
    delete: []const u8,
};

pub const ParseError = error{InvalidThreadCommand};

/// `secs` as `42s`, `1m 12s`, or `1h 05m`, written into `buf`.
fn formatDuration(buf: []u8, secs: u64) []const u8 {
    const text = if (secs < 60)
        std.mem.print(buf, "{d}s", .{secs})
    else if (secs < 3600)
        std.mem.print(buf, "{d}m {d:0>2}s", .{ secs / 60, secs % 60 })
    else
        std.mem.print(buf, "{d}h {d:0>2}m", .{ secs / 3600, (secs % 3600) / 60 });
    return text catch "";
}

/// Borrows from `rest`.
pub fn parse(rest: []const u8) ParseError!Action {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) return .list;
    const verb, const tail = splitWord(trimmed);
    if (std.mem.eql(u8, verb, "list")) {
        if (tail.len != 0) return error.InvalidThreadCommand;
        return .list;
    }
    if (std.mem.eql(u8, verb, "status")) {
        if (tail.len != 0) return error.InvalidThreadCommand;
        return .status;
    }
    if (std.mem.eql(u8, verb, "new")) {
        const name, const task = splitWord(tail);
        if (name.len == 0 or task.len == 0) return error.InvalidThreadCommand;
        return .{ .new = .{ .name = name, .task = task } };
    }
    // A thread is found by what you type, which may be several words. Where
    // nothing follows the name, the whole phrase is the name; where more text
    // follows, quote a name of several words.
    if (std.mem.eql(u8, verb, "send")) {
        const name, const message = splitName(tail);
        if (name.len == 0 or message.len == 0) return error.InvalidThreadCommand;
        return .{ .send = .{ .name = name, .message = message } };
    }
    if (std.mem.eql(u8, verb, "watch")) {
        // A trailing number is how many lines to print once; the rest is the name.
        var name = unquote(tail);
        var lines: ?usize = null;
        if (std.mem.findScalarLast(u8, tail, ' ')) |space| {
            const last = tail[space + 1 ..];
            if (last.len > 0 and allDigits(last) and std.mem.trim(u8, tail[0..space], " \t").len > 0) {
                const count = std.fmt.parseInt(usize, last, 10) catch return error.InvalidThreadCommand;
                if (count == 0 or count > thread_feed.default_max_lines) return error.InvalidThreadCommand;
                lines = count;
                name = unquote(std.mem.trim(u8, tail[0..space], " \t"));
            }
        }
        if (name.len == 0) return error.InvalidThreadCommand;
        return .{ .watch = .{ .name = name, .lines = lines } };
    }
    if (std.mem.eql(u8, verb, "stop") or std.mem.eql(u8, verb, "delete") or std.mem.eql(u8, verb, "switch")) {
        const name = unquote(tail);
        if (name.len == 0) return error.InvalidThreadCommand;
        if (std.mem.eql(u8, verb, "stop")) return .{ .stop = name };
        if (std.mem.eql(u8, verb, "delete")) return .{ .delete = name };
        return .{ .@"switch" = name };
    }
    if (std.mem.eql(u8, verb, "rename")) {
        const old, const new_tail = splitName(tail);
        const new, const extra = splitWord(new_tail);
        if (old.len == 0 or new.len == 0 or extra.len != 0) return error.InvalidThreadCommand;
        return .{ .rename = .{ .old = old, .new = new } };
    }
    // Anything that is not a command word is instructions for a new thread.
    // Command words always parse as commands, so a typo such as `/thread stop`
    // reports its usage instead of starting a model run.
    return .{ .start = trimmed };
}

fn allDigits(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return text.len > 0;
}

/// `text` without one pair of surrounding double quotes.
fn unquote(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    }
    return trimmed;
}

/// A name and what follows it. A name that starts with a quote runs to the
/// closing quote, so it can hold several words.
fn splitName(text: []const u8) struct { []const u8, []const u8 } {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len > 0 and trimmed[0] == '"') {
        if (std.mem.findScalarPos(u8, trimmed, 1, '"')) |close| {
            return .{ std.mem.trim(u8, trimmed[1..close], " \t"), std.mem.trim(u8, trimmed[close + 1 ..], " \t") };
        }
    }
    return splitWord(trimmed);
}

fn splitWord(text: []const u8) struct { []const u8, []const u8 } {
    const trimmed = std.mem.trim(u8, text, " \t");
    const end = std.mem.findAny(u8, trimmed, " \t") orelse return .{ trimmed, "" };
    return .{ trimmed[0..end], std.mem.trim(u8, trimmed[end..], " \t") };
}

pub fn Runtime(comptime App: type) type {
    const SessionRuntime = app_session_runtime.Runtime(App);

    return struct {
        /// True, after telling the user, when a thread of the current session is
        /// running. Changing the session ends its host and with it every thread
        /// turn, so `what` names the action being refused.
        pub fn blocksSessionChange(app: *App, what: []const u8) !bool {
            const host = SessionRuntime.subagentHost(app) orelse return false;
            const root_id = SessionRuntime.activeSessionId(app) orelse return false;
            const home = io_mod.homeDir() orelse return false;
            var registry = thread_registry.load(app.alloc, home, root_id) catch return false;
            defer registry.deinit(app.alloc);
            const running = runningThread(host, &registry) orelse return false;
            try noticeFmt(app, .@"error", "thread", "Thread {s} is still running. Stop it with /thread stop {s} before you {s}.", .{ running, running, what });
            return true;
        }

        fn runningThread(host: *subagent_tool_host.Runtime, registry: *const thread_registry.Registry) ?[]const u8 {
            for (registry.threads.items) |t| {
                if (t.session_id.len != 0 and host.managed.hasRunningChild(t.session_id)) return t.name;
            }
            return null;
        }

        /// Opens the menu of threads. Returns false, after saying why, when the
        /// session cannot have threads.
        pub fn openMenu(app: *App) !bool {
            const rows = (try buildMenuRows(app, true)) orelse return false;
            app.input_runtime.thread_menu.open(app.alloc, rows, io_mod.milliTimestamp());
            return true;
        }

        /// Keeps an open menu current: threads start, finish, and go idle.
        pub fn tickMenu(app: *App) void {
            // Only the real app carries thread state; test doubles do not.
            if (comptime !@hasField(App, "thread_watch")) return;
            const menu = &app.input_runtime.thread_menu;
            if (!menu.active) return;
            const now = io_mod.milliTimestamp();
            if (now - menu.refreshed_ms < menu_refresh_ms) return;
            menu.refreshed_ms = now;
            const rows = (buildMenuRows(app, false) catch return) orelse return;
            if (rowsEqual(menu.rows, rows)) {
                for (rows) |row| {
                    app.alloc.free(row.label);
                    app.alloc.free(row.info);
                }
                app.alloc.free(rows);
                return;
            }
            menu.refresh(app.alloc, rows, now);
            app.shell.render_requests.request(.footer);
        }

        fn rowsEqual(a: []const thread_menu.Row, b: []const thread_menu.Row) bool {
            if (a.len != b.len) return false;
            for (a, b) |x, y| {
                if (x.current != y.current or !std.mem.eql(u8, x.label, y.label) or !std.mem.eql(u8, x.info, y.info)) return false;
            }
            return true;
        }

        /// Enter on a row: switch to that thread, or back to main.
        pub fn selectMenuRow(app: *App) !void {
            if (comptime !@hasField(App, "thread_watch")) return;
            const menu = &app.input_runtime.thread_menu;
            const row = menu.selected() orelse return;
            const label = try app.alloc.dupe(u8, row.label);
            defer app.alloc.free(label);
            const current = row.current;
            menu.close(app.alloc);
            app.shell.render_requests.request(.footer);
            if (current) {
                try noticeFmt(app, .neutral, "thread", "You are already in {s}.", .{label});
                return;
            }
            const command = try app.alloc.print("switch {s}", .{label});
            defer app.alloc.free(command);
            try handle(app, command);
        }

        /// The menu's rows: `main`, then each thread with its state and what it
        /// was asked. Null, after telling the user when `announce` is set, if
        /// this session cannot have threads. Caller owns the rows.
        fn buildMenuRows(app: *App, announce: bool) !?[]thread_menu.Row {
            const host = SessionRuntime.subagentHost(app) orelse {
                if (announce) try notice(app, .@"error", "thread", "Threads need a saved session in the default session format.");
                return null;
            };
            const root_id = SessionRuntime.activeSessionId(app) orelse {
                if (announce) try notice(app, .@"error", "thread", "No active session.");
                return null;
            };
            const home = io_mod.homeDir() orelse {
                if (announce) try notice(app, .@"error", "thread", "No home directory for thread state.");
                return null;
            };
            var registry = (thread_registry.loadForThreadSession(app.alloc, home, root_id) catch null) orelse
                thread_registry.load(app.alloc, home, root_id) catch |err| {
                if (announce) try noticeFmt(app, .@"error", "thread", "Thread list unreadable: {s}", .{@errorName(err)});
                return null;
            };
            defer registry.deinit(app.alloc);
            const current_thread: ?[]const u8 = if (registry.findBySession(root_id)) |t| t.name else null;

            var specs: std.ArrayList(thread_menu.RowSpec) = .empty;
            defer {
                for (specs.items) |spec| app.alloc.free(spec.info);
                specs.deinit(app.alloc);
            }
            try specs.append(app.alloc, .{
                .label = thread_registry.root_thread_name,
                .info = try app.alloc.dupe(u8, if (current_thread == null) "this session · you are here" else "the session the threads stem from · leave this thread"),
                .current = current_thread == null,
            });
            const now = io_mod.milliTimestamp();
            for (registry.threads.items) |t| {
                var info: std.Io.Writer.Allocating = .init(app.alloc);
                errdefer info.deinit();
                const here = if (current_thread) |c| std.mem.eql(u8, c, t.name) else false;
                if (here) {
                    try info.writer.writeAll("you are here");
                } else if (current_thread != null) {
                    // Only the session that owns the threads can see them run.
                    try info.writer.writeAll("saved");
                } else if (try host.threadStatus(app.alloc, t.agent)) |st| {
                    defer st.deinit(app.alloc);
                    var duration_buf: [24]u8 = undefined;
                    switch (st.phase) {
                        .running => try info.writer.print("running {s}", .{formatDuration(&duration_buf, if (st.active_since_ms) |since| @intCast(@divTrunc(@max(now - since, 0), 1000)) else 0)}),
                        .awaiting_approval => try info.writer.writeAll("waiting for approval"),
                        else => try info.writer.writeAll(thread_tools.phaseLabel(st.phase)),
                    }
                } else {
                    try info.writer.writeAll("not started");
                }
                if (t.title.len > 0) try info.writer.print(" · {s}", .{shortTitle(t.title)});
                try specs.append(app.alloc, .{ .label = t.name, .info = try info.toOwnedSlice(), .current = here });
            }
            return try thread_menu.makeRows(app.alloc, specs.items);
        }

        pub fn handle(app: *App, rest: []const u8) !void {
            const action = parse(rest) catch {
                try notice(app, .@"error", "", usage);
                return;
            };
            const host = SessionRuntime.subagentHost(app) orelse {
                try notice(app, .@"error", "thread", "Threads need a saved session in the default session format.");
                return;
            };
            const root_id = SessionRuntime.activeSessionId(app) orelse {
                try notice(app, .@"error", "thread", "No active session.");
                return;
            };
            const home = io_mod.homeDir() orelse {
                try notice(app, .@"error", "thread", "No home directory for thread state.");
                return;
            };
            // Inside a thread, the registry is the one of the session it stems from.
            var registry = (thread_registry.loadForThreadSession(app.alloc, home, root_id) catch null) orelse
                thread_registry.load(app.alloc, home, root_id) catch |err| {
                try noticeFmt(app, .@"error", "thread", "Thread list unreadable: {s}", .{@errorName(err)});
                return;
            };
            defer registry.deinit(app.alloc);
            const current_thread: ?[]const u8 = if (registry.findBySession(root_id)) |t| t.name else null;

            switch (action) {
                .list => try list(app, host, &registry, current_thread),
                .status => try showStatus(app, host, &registry, current_thread),
                .@"switch" => |name| try switchTo(app, host, &registry, current_thread, name),
                .rename => |a| try rename(app, &registry, home, a.old, a.new),
                else => {},
            }
            switch (action) {
                .list, .status, .@"switch", .rename => return,
                else => {},
            }
            if (current_thread) |name| {
                try noticeFmt(app, .@"error", "thread", "You are in thread {s}. Run /thread switch main first.", .{name});
                return;
            }
            switch (action) {
                .new => |a| try create(app, host, &registry, root_id, home, a.name, a.task),
                .start => |instructions| {
                    const name = try thread_registry.suggestName(app.alloc, &registry, instructions);
                    defer app.alloc.free(name);
                    try create(app, host, &registry, root_id, home, name, instructions);
                },
                .send => |a| try send(app, host, &registry, root_id, a.name, a.message),
                .watch => |a| try watch(app, host, &registry, a.name, a.lines),
                .stop => |name| try stop(app, host, &registry, name),
                .delete => |name| try remove(app, host, &registry, home, name),
                .list, .status, .@"switch", .rename => unreachable,
            }
        }

        /// A quick look at whether threads are still working: how many, for how
        /// long, and the last thing each did.
        fn showStatus(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            current_thread: ?[]const u8,
        ) !void {
            if (registry.threads.items.len == 0) {
                try notice(app, .neutral, "thread", "No threads yet. Start one with /thread INSTRUCTIONS.");
                return;
            }
            if (current_thread != null) {
                try notice(app, .neutral, "thread", "Live status is shown from main, where the threads run. Run /thread switch main.");
                return;
            }
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            var running: usize = 0;
            var waiting: usize = 0;
            var idle: usize = 0;
            const now = io_mod.milliTimestamp();
            for (registry.threads.items) |t| {
                const st = try host.threadStatus(app.alloc, t.agent);
                defer if (st) |s| s.deinit(app.alloc);
                try out.writer.print("\n{s}  ", .{t.name});
                const s = st orelse {
                    try out.writer.writeAll("not started");
                    continue;
                };
                const last = lastLine(app.alloc, host.feedFor(s.child_id)) catch null;
                defer if (last) |text| app.alloc.free(text);
                var duration_buf: [24]u8 = undefined;
                const elapsed = if (s.active_since_ms) |since| formatDuration(&duration_buf, @intCast(@divTrunc(@max(now - since, 0), 1000))) else "";
                switch (s.phase) {
                    .running => {
                        running += 1;
                        try out.writer.print("running {s}", .{elapsed});
                    },
                    .awaiting_approval => {
                        waiting += 1;
                        try out.writer.print("waiting for approval {s} (answer it in the prompt)", .{elapsed});
                    },
                    .idle, .finished => {
                        idle += 1;
                        try out.writer.writeAll("idle");
                        if (host.feedFor(s.child_id)) |feed| {
                            const at = feed.lastActivityMs();
                            if (at > 0) {
                                var ago_buf: [24]u8 = undefined;
                                try out.writer.print(" · last active {s} ago", .{formatDuration(&ago_buf, @intCast(@divTrunc(@max(now - at, 0), 1000)))});
                            }
                        }
                    },
                    .interrupted => {
                        idle += 1;
                        try out.writer.writeAll("interrupted · send it a message to continue");
                    },
                }
                if (last) |text| {
                    if (s.phase == .running or s.phase == .awaiting_approval) try out.writer.print("\n    last: {s}", .{text});
                }
            }
            var header: std.Io.Writer.Allocating = .init(app.alloc);
            defer header.deinit();
            if (running == 0 and waiting == 0) {
                try header.writer.writeAll("No thread is working. All idle.");
            } else {
                try header.writer.print("{d} working", .{running + waiting});
                if (waiting > 0) try header.writer.print(", {d} waiting for approval", .{waiting});
                if (idle > 0) try header.writer.print(", {d} idle", .{idle});
            }
            try out.writer.writeAll("\n\nFollow one live with /thread watch NAME.");
            const body = try std.mem.concat(app.alloc, u8, &.{ header.written(), out.written() });
            defer app.alloc.free(body);
            try notice(app, .neutral, "threads", body);
        }

        /// The newest line a thread has produced, shortened. Caller owns it.
        fn lastLine(alloc: Allocator, feed: ?*thread_feed.Feed) !?[]u8 {
            const f = feed orelse return null;
            const tail = try f.tail(alloc, 1);
            defer tail.deinit(alloc);
            if (tail.lines.len == 0) return null;
            const line = std.mem.trim(u8, tail.lines[0], " \t");
            if (line.len == 0) return null;
            return try alloc.dupe(u8, shortTitle(line));
        }

        fn switchTo(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            current_thread: ?[]const u8,
            name: []const u8,
        ) !void {
            if (current_thread) |current| {
                if (std.mem.eql(u8, current, name)) {
                    try noticeFmt(app, .neutral, "thread", "You are already in {s}.", .{name});
                    return;
                }
            } else if (std.mem.eql(u8, name, thread_registry.root_thread_name)) {
                try notice(app, .neutral, "thread", "You are already in main.");
                return;
            }
            const target: []const u8 = if (std.mem.eql(u8, name, thread_registry.root_thread_name))
                registry.root_id
            else blk: {
                const t = (try resolveThread(app, registry, name)) orelse return;
                if (t.session_id.len == 0) {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} has not started yet.", .{name});
                    return;
                }
                break :blk t.session_id;
            };
            if (current_thread == null) {
                if (runningThread(host, registry)) |running| {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} is still running and would stop. Stop it with /thread stop {s} or wait, then switch.", .{ running, running });
                    return;
                }
            }
            if (app.stream.active or !app.worker.tryHoldTurnStart()) {
                try notice(app, .@"error", "thread", "A turn is running in this session. Wait for it to finish, then switch.");
                return;
            }
            app.worker.releaseTurnStartHold();
            SessionRuntime.switchForegroundSession(app, target) catch |err| {
                const body: []const u8 = switch (err) {
                    error.UnsupportedSessionFormat => "Switching needs the default session format.",
                    error.SessionBusy => "That session is open elsewhere or still running.",
                    else => "Could not open that session.",
                };
                try noticeFmt(app, .@"error", "thread", "{s} ({s})", .{ body, @errorName(err) });
                return;
            };
            try noticeFmt(app, .success, "thread", "Switched to {s}.", .{name});
        }

        fn list(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            current_thread: ?[]const u8,
        ) !void {
            if (registry.threads.items.len == 0 and current_thread == null) {
                try notice(app, .neutral, "thread", "No threads yet. Start one with /thread new NAME TASK.");
                return;
            }
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            const now = io_mod.milliTimestamp();
            try out.writer.print("{s} main\n", .{if (current_thread == null) ">" else " "});
            for (registry.threads.items) |t| {
                const here = if (current_thread) |c| std.mem.eql(u8, c, t.name) else false;
                try out.writer.print("{s} {s}", .{ if (here) ">" else " ", t.name });
                // Only the root's host runs threads, so state is live there alone.
                if (current_thread == null) {
                    const status = try host.threadStatus(app.alloc, t.agent);
                    defer if (status) |s| s.deinit(app.alloc);
                    try out.writer.print("  {s}", .{if (status) |s| thread_tools.phaseLabel(s.phase) else "not started"});
                    if (status) |s| if (host.feedFor(s.child_id)) |feed| {
                        const last = feed.lastActivityMs();
                        if (last > 0) try out.writer.print("  active {d}s ago", .{@divTrunc(@max(now - last, 0), 1000)});
                    };
                }
                if (t.title.len > 0) try out.writer.print("  \"{s}\"", .{shortTitle(t.title)});
                try out.writer.writeByte('\n');
            }
            try out.writer.writeAll("\nMention one in a prompt with @thread:NAME. Follow one with /thread watch NAME.");
            try notice(app, .neutral, "threads", out.written());
        }

        fn create(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *thread_registry.Registry,
            root_id: []const u8,
            home: []const u8,
            name: []const u8,
            task: []const u8,
        ) !void {
            var id_buf: [96]u8 = undefined;
            const outcome = try thread_tools.createThread(
                app.alloc,
                host,
                registry,
                home,
                name,
                task,
                executeOptions(app, root_id, invocationId(&id_buf, "new")),
            );
            switch (outcome) {
                .started => |s| if (s.saved)
                    try noticeFmt(app, .success, "thread", "Started thread {s}. Follow it with /thread watch {s}.", .{ name, name })
                else
                    try noticeFmt(app, .warning, "thread", "Started {s}, but the thread list was not saved.", .{name}),
                .invalid_name => |err| try notice(app, .@"error", "thread", nameProblem(err)),
                .duplicate => try noticeFmt(app, .@"error", "thread", "A thread named {s} already exists.", .{name}),
                .rejected => |code| try noticeFmt(app, .@"error", "thread", "Could not start {s}: {s}", .{ name, code }),
            }
        }

        fn send(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            root_id: []const u8,
            name: []const u8,
            message: []const u8,
        ) !void {
            const t = (try resolveThread(app, registry, name)) orelse return;
            var id_buf: [96]u8 = undefined;
            const outcome = try host.sendThread(app.alloc, t.agent, message, executeOptions(app, root_id, invocationId(&id_buf, "send")));
            defer outcome.deinit(app.alloc);
            switch (outcome) {
                .started => try noticeFmt(app, .success, "thread", "Sent to {s}; it is working on it.", .{name}),
                .steered => try noticeFmt(app, .success, "thread", "Sent to {s}; it was mid-turn, so the text joins that turn.", .{name}),
                .rejected => |code| try noticeFmt(app, .@"error", "thread", "Could not send to {s}: {s}", .{ name, code }),
            }
        }

        fn watch(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            typed_name: []const u8,
            lines: ?usize,
        ) !void {
            const t = (try resolveThread(app, registry, typed_name)) orelse return;
            const name = t.name;
            const status = (try host.threadStatus(app.alloc, t.agent)) orelse {
                try noticeFmt(app, .@"error", "thread", "Thread {s} has not started.", .{name});
                return;
            };
            defer status.deinit(app.alloc);
            const feed = host.feedFor(status.child_id) orelse {
                try noticeFmt(app, .neutral, name, "{s}. Nothing recorded in this process yet.", .{thread_tools.phaseLabel(status.phase)});
                return;
            };
            if (lines) |count| {
                const body = try renderBody(app.alloc, feed, count, status.phase == .running or status.phase == .awaiting_approval, 0);
                defer app.alloc.free(body);
                try notice(app, .neutral, name, body);
                return;
            }
            // Following: one entry in the transcript that the tick redraws.
            // A view already running ends first, so only one entry is pinned.
            endWatch(app, "Stopped following: another thread is being watched.");
            const running = host.managed.hasRunningChild(status.child_id);
            const now = io_mod.milliTimestamp();
            const body = try renderBody(app.alloc, feed, follow_lines, running, 0);
            defer app.alloc.free(body);
            if (!running) {
                // Nothing is changing, so there is nothing to follow.
                try notice(app, .neutral, name, body);
                return;
            }
            const entry_id = try app.appendReplaceableDomainNotice(.{ .topic = name, .tone = .neutral, .body = body });
            if (status.child_id.len > app.thread_watch.child_id_buf.len) return;
            app.thread_watch = .{ .active = true, .entry_id = entry_id, .host = @intFromPtr(host), .started_ms = now, .last_refresh_ms = now };
            @memcpy(app.thread_watch.child_id_buf[0..status.child_id.len], status.child_id);
            app.thread_watch.child_id_len = status.child_id.len;
            @memcpy(app.thread_watch.name_buf[0..name.len], name);
            app.thread_watch.name_len = name.len;
            app.thread_watch.last_hash = std.hash.Wyhash.hash(0, body);
        }

        /// Redraws the live view from the thread's feed. Called every tick; it
        /// does nothing unless a view is active and the interval has passed.
        pub fn tickWatch(app: *App) void {
            const state = &app.thread_watch;
            if (!state.active) return;
            const now = io_mod.milliTimestamp();
            if (now - state.last_refresh_ms < follow_interval_ms) return;
            state.last_refresh_ms = now;
            const host = SessionRuntime.subagentHost(app);
            const feed = if (host) |h|
                if (@intFromPtr(h) == state.host) h.feedFor(state.childId()) else null
            else
                null;
            const live_feed = feed orelse {
                // The session changed under the view. Release it as history.
                endWatch(app, "Stopped following: the session changed.");
                return;
            };
            const running = host.?.managed.hasRunningChild(state.childId());
            const elapsed_s: u64 = @intCast(@divTrunc(@max(now - state.started_ms, 0), 1000));
            const body = renderBody(app.alloc, live_feed, follow_lines, running, elapsed_s) catch return;
            defer app.alloc.free(body);
            if (!running) {
                // The last view says what the thread ended with and stays in the transcript.
                endWatch(app, body);
                return;
            }
            const hash = std.hash.Wyhash.hash(0, body);
            if (hash == state.last_hash) return;
            state.last_hash = hash;
            const replaced = app.replaceDomainNoticeKeepingPin(state.entry_id, .{ .topic = state.name(), .tone = .neutral, .body = body }) catch false;
            // The entry left the transcript, so there is nothing to redraw.
            if (!replaced) state.active = false;
            app.shell.render_requests.request(.transcript);
        }

        /// Ends the live view with `body` as its last text, which releases the
        /// entry into the transcript as ordinary history.
        fn endWatch(app: *App, body: []const u8) void {
            const state = &app.thread_watch;
            if (!state.active) return;
            state.active = false;
            _ = app.replaceDomainNotice(state.entry_id, .{ .topic = state.name(), .tone = .neutral, .body = body }) catch {};
            app.shell.render_requests.request(.transcript);
        }

        /// Header plus the newest `max` lines of the feed. Caller owns the result.
        fn renderBody(alloc: Allocator, feed: *thread_feed.Feed, max: usize, running: bool, elapsed_s: u64) ![]u8 {
            const tail = try feed.tail(alloc, max);
            defer tail.deinit(alloc);
            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            try out.writer.writeAll(if (running) "running" else "idle");
            if (running and elapsed_s > 0) try out.writer.print(" · {d}s", .{elapsed_s});
            const hidden = tail.total_lines -| @as(u64, @intCast(tail.lines.len));
            if (tail.lines.len == 0) {
                try out.writer.writeAll("\n(no output yet)");
            } else {
                if (hidden > 0) try out.writer.print("\n… {d} earlier {s}", .{ hidden, if (hidden == 1) "line" else "lines" });
                for (tail.lines) |line| try out.writer.print("\n{s}", .{line});
            }
            return out.toOwnedSlice();
        }

        fn stop(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            name: []const u8,
        ) !void {
            const t = (try resolveThread(app, registry, name)) orelse return;
            const status = (try host.threadStatus(app.alloc, t.agent)) orelse {
                try noticeFmt(app, .neutral, "thread", "Thread {s} is not running.", .{name});
                return;
            };
            defer status.deinit(app.alloc);
            if (status.phase != .running and status.phase != .awaiting_approval) {
                try noticeFmt(app, .neutral, "thread", "Thread {s} is not running.", .{name});
                return;
            }
            host.cancelThread(status.child_id) catch |err| {
                try noticeFmt(app, .@"error", "thread", "Could not stop {s}: {s}", .{ name, @errorName(err) });
                return;
            };
            try noticeFmt(app, .success, "thread", "Stopping {s}.", .{name});
        }

        fn rename(app: *App, registry: *thread_registry.Registry, home: []const u8, old_typed: []const u8, new: []const u8) !void {
            const found = (try resolveThread(app, registry, old_typed)) orelse return;
            const old = try app.alloc.dupe(u8, found.name);
            defer app.alloc.free(old);
            registry.rename(app.alloc, old, new) catch |err| switch (err) {
                error.ThreadNotFound => return missing(app, old),
                error.DuplicateThreadName => {
                    try noticeFmt(app, .@"error", "thread", "A thread named {s} already exists.", .{new});
                    return;
                },
                error.InvalidThreadName, error.ReservedThreadName => {
                    try notice(app, .@"error", "thread", nameProblem(err));
                    return;
                },
                else => return err,
            };
            try thread_registry.save(app.alloc, home, registry);
            try noticeFmt(app, .success, "thread", "Renamed {s} to {s}.", .{ old, new });
        }

        fn remove(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *thread_registry.Registry,
            home: []const u8,
            name: []const u8,
        ) !void {
            const t = (try resolveThread(app, registry, name)) orelse return;
            if (try host.threadStatus(app.alloc, t.agent)) |status| {
                defer status.deinit(app.alloc);
                if (status.phase == .running or status.phase == .awaiting_approval) {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} is running. Stop it first with /thread stop {s}.", .{ name, name });
                    return;
                }
            }
            // The session and child entry go first and the name last, so a
            // crash between them leaves a name that delete can finish.
            const outcome = host.deleteThread(app.alloc, t.agent, t.session_id) catch |err| {
                try noticeFmt(app, .@"error", "thread", "Could not delete {s}: {s}", .{ name, @errorName(err) });
                return;
            };
            switch (outcome) {
                .deleted => {},
                .running => {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} is running. Stop it first with /thread stop {s}.", .{ name, name });
                    return;
                },
                .in_use => {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} is open in another process. Close it there, then delete.", .{name});
                    return;
                },
                .failed => {
                    try noticeFmt(app, .@"error", "thread", "Could not delete the saved session of {s}. Run /thread delete {s} again.", .{ name, name });
                    return;
                },
            }
            try registry.remove(app.alloc, name);
            try thread_registry.save(app.alloc, home, registry);
            try noticeFmt(app, .success, "thread", "Deleted thread {s} and its saved session.", .{name});
        }

        /// The thread `name` points at, or null after telling the user why not.
        fn resolveThread(app: *App, registry: *const thread_registry.Registry, name: []const u8) !?*const thread_registry.Thread {
            switch (registry.resolve(name)) {
                .found => |t| return t,
                .none => {
                    try missing(app, name);
                    return null;
                },
                .ambiguous => |a| {
                    var out: std.Io.Writer.Allocating = .init(app.alloc);
                    defer out.deinit();
                    for (a.names[0..@min(a.count, a.names.len)], 0..) |candidate, index| {
                        try out.writer.print("{s}{s}", .{ if (index == 0) "" else ", ", candidate });
                    }
                    if (a.count > a.names.len) try out.writer.print(", and {d} more", .{a.count - a.names.len});
                    try noticeFmt(app, .@"error", "thread", "{s} matches several threads: {s}. Use more of the name.", .{ name, out.written() });
                    return null;
                },
            }
        }

        /// The first part of a thread's instructions, enough to tell threads apart.
        fn shortTitle(title: []const u8) []const u8 {
            const limit: usize = 48;
            if (title.len <= limit) return title;
            var end: usize = limit;
            while (end > 0 and (title[end] & 0xC0) == 0x80) end -= 1;
            return title[0..end];
        }

        fn missing(app: *App, name: []const u8) !void {
            try noticeFmt(app, .@"error", "thread", "No thread named {s}. List them with /thread list.", .{name});
        }

        fn executeOptions(app: *App, root_id: []const u8, invocation_id: []const u8) subagent_tool_host.ExecuteOptions {
            const settings = app.worker.effectiveAgentTurnSettings();
            return .{
                .caller_id = root_id,
                .invocation_id = invocation_id,
                .parent_permission_mode = app_permission_runtime.Runtime(App).livePermissionSnapshot(app).mode,
                .defaults = .{
                    .provider = provider_runtime.provider(app),
                    .model = provider_runtime.model(app),
                    .effort = settings.effort,
                    .fast_mode = settings.fast_mode,
                    .ultrafast_mode = settings.ultrafast_mode,
                    .conversation_language = app.session.languageSnapshot(),
                },
                .max_result_bytes = settings.max_tool_result_bytes,
                .timestamp_ms = io_mod.milliTimestamp(),
            };
        }

        /// A fresh id per command, so each send is its own operation.
        fn invocationId(buf: []u8, verb: []const u8) []const u8 {
            return std.mem.print(buf, "thread-{s}-{d}", .{ verb, io_mod.nanoTimestamp() }) catch "thread-op";
        }

        fn notice(app: *App, tone: anytype, topic: []const u8, body: []const u8) !void {
            try app.writeDomainNotice(.{ .topic = topic, .tone = tone, .body = body }, true);
        }

        fn noticeFmt(app: *App, tone: anytype, topic: []const u8, comptime fmt: []const u8, args: anytype) !void {
            const body = try app.alloc.print(fmt, args);
            defer app.alloc.free(body);
            try notice(app, tone, topic, body);
        }
    };
}

fn nameProblem(err: anyerror) []const u8 {
    return switch (err) {
        error.ReservedThreadName => "main is the current session and cannot be a thread name.",
        else => "Thread names use lowercase letters, digits, - and _, start with a letter or digit, and stay within 32 characters.",
    };
}

test "durations read as short human text" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0s", formatDuration(&buf, 0));
    try std.testing.expectEqualStrings("42s", formatDuration(&buf, 42));
    try std.testing.expectEqualStrings("1m 12s", formatDuration(&buf, 72));
    try std.testing.expectEqualStrings("10m 00s", formatDuration(&buf, 600));
    try std.testing.expectEqualStrings("1h 05m", formatDuration(&buf, 3900));
}

test "status takes no arguments and is a command word" {
    try std.testing.expect((try parse("status")) == .status);
    try std.testing.expectError(error.InvalidThreadCommand, parse("status of everything"));
}

test "thread command treats text that is not a command as instructions" {
    const start = (try parse("fix the login bug after a token refresh")).start;
    try std.testing.expectEqualStrings("fix the login bug after a token refresh", start);
    try std.testing.expectEqualStrings("review @thread:boon", (try parse("  review @thread:boon ")).start);
    // A command word keeps its meaning, and misusing it is an error, not a thread.
    try std.testing.expectError(error.InvalidThreadCommand, parse("stop"));
    try std.testing.expectError(error.InvalidThreadCommand, parse("list all the TODOs"));
    // `new NAME TASK` is the way to start from words that begin like a command.
    try std.testing.expectEqualStrings("todos", (try parse("new todos list all the TODOs")).new.name);
}

test "thread command parses each verb" {
    try std.testing.expect((try parse("")) == .list);
    try std.testing.expect((try parse("list")) == .list);
    const new = (try parse("new fix-auth fix the login bug")).new;
    try std.testing.expectEqualStrings("fix-auth", new.name);
    try std.testing.expectEqualStrings("fix the login bug", new.task);
    const send = (try parse("send fix-auth  also check logout")).send;
    try std.testing.expectEqualStrings("also check logout", send.message);
    try std.testing.expect((try parse("watch a")).watch.lines == null);
    try std.testing.expectEqual(@as(usize, 5), (try parse("watch a 5")).watch.lines.?);
    try std.testing.expectEqualStrings("a", (try parse("stop a")).stop);
    // Several words are one name where nothing else follows.
    try std.testing.expectEqualStrings("web research", (try parse("stop web research")).stop);
    try std.testing.expectEqualStrings("web research", (try parse("switch \"web research\"")).@"switch");
    const multi = (try parse("watch web research 5")).watch;
    try std.testing.expectEqualStrings("web research", multi.name);
    try std.testing.expectEqual(@as(usize, 5), multi.lines.?);
    try std.testing.expectEqualStrings("web research", (try parse("watch web research")).watch.name);
    try std.testing.expect((try parse("watch web research")).watch.lines == null);
    // A number alone is a name, not a line count.
    try std.testing.expectEqualStrings("42", (try parse("watch 42")).watch.name);
    const quoted = (try parse("send \"web research\" also check pricing")).send;
    try std.testing.expectEqualStrings("web research", quoted.name);
    try std.testing.expectEqualStrings("also check pricing", quoted.message);
    try std.testing.expectEqualStrings("web research", (try parse("rename \"web research\" docs")).rename.old);
    try std.testing.expectEqualStrings("b", (try parse("rename a b")).rename.new);
    try std.testing.expectEqualStrings("a", (try parse("delete a")).delete);
    try std.testing.expectEqualStrings("a", (try parse("switch a")).@"switch");
}

test "thread command rejects malformed input" {
    for ([_][]const u8{ "new", "new a", "send a", "watch", "watch a 0", "stop", "rename a", "list x" }) |bad| {
        try std.testing.expectError(error.InvalidThreadCommand, parse(bad));
    }
}
