//! Attached terminal client. Socket requests run off the paint thread; closing this
//! state releases only client resources, never the supervisor's sessions.
const std = @import("std");
const client_mod = @import("../supervisor/client.zig");
const client_protocol = @import("../supervisor/protocol.zig");
const io_mod = @import("../shared/io.zig");
const browser_mod = @import("../input/session_browser.zig");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");
const presentation = @import("../agent/assistant_presentation.zig");
const callbacks = @import("app_callbacks.zig");
const sessions = @import("app_session_runtime.zig");
const session_catalog = @import("../session/session_catalog.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const diff = @import("../output/diff.zig");
const metrics_line = @import("../output/metrics_line.zig");
const Allocator = std.mem.Allocator;
const SnapshotView = client_protocol.Snapshot([]const types.HistoryTurn, std.json.Value);
const Kind = enum { startup, startup_last, startup_remembered, attach, poll, list, children, history, submit, cancel, rpc, heartbeat, kernel, rename, config, command };
const Request = struct {
    alloc: Allocator,
    kind: Kind,
    json: []u8,
    generation: u64,
    executable: ?[]u8 = null,
    fn deinit(self: *Request) void {
        self.alloc.free(self.json);
        if (self.executable) |value| self.alloc.free(value);
    }
};
const Task = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    alloc: Allocator,
    client: *const client_mod.Client,
    request: Request,
    response: ?client_mod.Response = null,
    failure: ?anyerror = null,
    fn run(self: *Task) void {
        defer self.done.store(true, .release);
        if (self.request.executable) |executable| self.client.ensureRunning(executable) catch |err| {
            self.failure = err;
            return;
        };
        self.response = self.client.requestJson(self.alloc, self.request.json) catch |err| {
            self.failure = err;
            return;
        };
    }
    fn deinit(self: *Task) void {
        if (self.thread) |thread| thread.join();
        if (self.response) |*response| response.deinit();
        self.request.deinit();
        self.alloc.destroy(self);
    }
};
pub const State = struct {
    allocator: ?Allocator = null,
    active: bool = false,
    client: ?*client_mod.Client = null,
    task: ?*Task = null,
    queue: std.ArrayList(Request) = .empty,
    current_id: []u8 = &.{},
    child_id: []u8 = &.{},
    generation: u64 = 1,
    sequence: u64 = 0,
    next_poll_ms: i64 = 0,
    next_list_ms: i64 = 0,
    next_child_poll_ms: i64 = 0,
    child_history_count: ?usize = null,
    child_work_id: []u8 = &.{},
    child_sequence: u64 = 0,
    child_live_active: bool = false,
    child_prompt: []u8 = &.{},
    child_status: [64]u8 = undefined,
    child_status_len: usize = 0,
    markdown: presentation.MarkdownProcessor = .{},
    turn_id: u64 = 1,
    native_presentation: bool = false,
    native_turn_offset: u64 = 1,
    native_source_turn_id: ?u64 = null,
    model: []u8 = &.{},
    cwd: []u8 = &.{},
    workspace_label: []u8 = &.{},
    incarnation: []u8 = &.{},
    reconnect_notice: bool = false,
    permission_mode: types.PermissionMode = .ask,
    message_id: [128]u8 = undefined,
    message_id_len: usize = 0,
    pending_permission_id: ?i64 = null,
    permission_response_queued: bool = false,
    submitted_text: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.task) |task| task.deinit();
        for (self.queue.items) |*request| request.deinit();
        self.queue.deinit(alloc);
        if (self.client) |client| {
            client.deinit();
            alloc.destroy(client);
        }
        if (self.current_id.len > 0) alloc.free(self.current_id);
        if (self.child_id.len > 0) alloc.free(self.child_id);
        if (self.child_prompt.len > 0) alloc.free(self.child_prompt);
        if (self.child_work_id.len > 0) alloc.free(self.child_work_id);
        if (self.model.len > 0) alloc.free(self.model);
        if (self.cwd.len > 0) alloc.free(self.cwd);
        if (self.workspace_label.len > 0) alloc.free(self.workspace_label);
        if (self.incarnation.len > 0) alloc.free(self.incarnation);
        for (self.submitted_text.items) |text| alloc.free(text);
        self.submitted_text.deinit(alloc);
        self.markdown.deinit(alloc);
        self.* = .{};
    }

    fn clearChildTracking(self: *State, alloc: Allocator) void {
        if (self.child_work_id.len > 0) alloc.free(self.child_work_id);
        self.child_work_id = &.{};
        if (self.child_prompt.len > 0) alloc.free(self.child_prompt);
        self.child_prompt = &.{};
        self.child_history_count = null;
        self.child_sequence = 0;
        self.child_live_active = false;
        self.child_status_len = 0;
    }

    fn enqueue(self: *State, kind: Kind, request: client_protocol.Request) !void {
        const alloc = self.allocator orelse return error.RemoteNotInitialized;
        if (self.queue.items.len >= 32) return error.RemoteQueueFull;
        const json = try client_protocol.encode(alloc, request);
        errdefer alloc.free(json);
        try self.queue.append(alloc, .{ .alloc = alloc, .kind = kind, .json = json, .generation = self.generation });
    }
    fn startNext(self: *State) !void {
        if (self.task != null or self.queue.items.len == 0) return;
        const alloc = self.allocator orelse return error.RemoteNotInitialized;
        const task = try alloc.create(Task);
        errdefer alloc.destroy(task);
        task.* = .{ .alloc = alloc, .client = self.client.?, .request = self.queue.orderedRemove(0) };
        errdefer task.request.deinit();
        task.thread = try std.Thread.spawn(.{}, Task.run, .{task});
        self.task = task;
    }
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn init(app: *App, executable: []const u8, resume_id: ?[]const u8) !void {
            const remote = &app.remote;
            if (remote.client != null) return;
            const client = try app.alloc.create(client_mod.Client);
            client.* = client_mod.Client.init(app.alloc) catch |err| {
                app.alloc.destroy(client);
                return err;
            };
            remote.allocator = app.alloc;
            remote.client = client;
            remote.active = true;
            errdefer remote.deinit(app.alloc);
            if (app.requested_resume) |requested| {
                var target = requested;
                app.requested_resume = null;
                defer target.deinit(app.alloc);
                switch (target) {
                    .pick => {
                        app.input_runtime.session_browser.open(.sessions);
                        try remote.enqueue(.list, .list);
                    },
                    .last => try remote.enqueue(.startup_last, .list),
                    .remembered => try remote.enqueue(.startup_remembered, .list),
                    .id => |id| try remote.enqueue(.startup, .{ .create = .{ .cwd = app.workspace_root, .@"resume" = id } }),
                }
            } else {
                try remote.enqueue(.startup, .{ .create = .{ .cwd = app.workspace_root, .@"resume" = resume_id } });
            }
            remote.queue.items[0].executable = try app.alloc.dupe(u8, executable);
            try remote.startNext();
        }

        /// Returns true only for commands owned by the detached session frontend.
        pub fn handleCommand(app: *App, command: []const u8) !bool {
            if (!app.remote.active) return false;
            const trimmed = std.mem.trim(u8, command, " \t\r\n");
            const boundary = std.mem.findAny(u8, trimmed, " \t\r\n") orelse trimmed.len;
            const name = trimmed[0..boundary];
            const rest = std.mem.trim(u8, trimmed[boundary..], " \t\r\n");
            if (app.remote.child_id.len > 0) {
                for ([_][]const u8{ "/kernel", "/heartbeat", "/model", "/permissions", "/rename" }) |scoped| {
                    if (!std.mem.eql(u8, name, scoped)) continue;
                    const status_command = std.mem.eql(u8, name, "/kernel") or std.mem.eql(u8, name, "/heartbeat");
                    const read_only = rest.len == 0 or (status_command and std.mem.eql(u8, rest, "status"));
                    if (!read_only) {
                        try notice(app, "subagent", "This child transcript is read-only. Press Left to return to the parent before changing its runtime or settings.");
                        return true;
                    }
                    if (!std.mem.eql(u8, name, "/rename")) try notice(app, "subagent", "Showing parent session status; this child transcript is read-only.");
                    break;
                }
            }
            if (std.mem.eql(u8, name, "/help")) {
                try notice(app, "proto-fx", "← sessions · → subagents (empty composer)\n/session  /compact · /clear · /context · /model <id> · /effort <level> · /fast on|off · /ultrafast on|off · /permissions ask|auto|full-access · /undo\n/app  /copy · /stats · /settings · /shell reload\n/allowlist · /mcp · /workspace [add PATH|remove PATH|clear] · /resume [id|last] · /subagents · /rename <title>\n/heartbeat status|start <seconds> <prompt>|pause|resume|stop\n/kernel status|prewarm|interrupt|stop|restart");
                return false;
            }
            if (std.mem.eql(u8, name, "/resume")) {
                if (rest.len == 0) try openSessionBrowser(app, .sessions) else if (std.mem.eql(u8, rest, "last")) {
                    try app.remote.enqueue(.startup_last, .list);
                } else try switchSession(app, rest);
                return true;
            }
            if (std.mem.eql(u8, name, "/rename")) {
                if (rest.len == 0) {
                    try notice(app, "", "usage: /rename <title>");
                } else if (app.remote.current_id.len == 0) {
                    try notice(app, "session", "Open a session before renaming it.");
                } else try app.remote.enqueue(.rename, .{ .rename = .{ .session_id = app.remote.current_id, .name = rest } });
                return true;
            }
            if (std.mem.eql(u8, name, "/subagents")) {
                try openSessionBrowser(app, .subagents);
                return true;
            }
            if (std.mem.eql(u8, name, "/status")) {
                const body = try app.alloc.print("session: {s}\nworkspace: {s}\nmodel: {s}\nmode: {s}\nview: {s}", .{ app.remote.current_id, app.remote.cwd, app.remote.model, @tagName(app.remote.permission_mode), if (app.remote.child_id.len > 0) app.remote.child_id else "root" });
                defer app.alloc.free(body);
                try notice(app, "session", body);
                return true;
            }
            if (std.mem.eql(u8, name, "/copy")) {
                if (app.remote.current_id.len == 0) {
                    try notice(app, "session", "Open a session before copying a reply.");
                    return true;
                }
                try app.remote.enqueue(.command, .{ .command = .{
                    .session_id = app.remote.current_id,
                    .name = "last_reply",
                } });
                return true;
            }
            if (std.mem.eql(u8, name, "/stats")) {
                var buf: [256]u8 = undefined;
                const body = try metrics_line.write(&buf, app.metrics);
                try notice(app, "stats", body);
                return true;
            }
            if (std.mem.eql(u8, name, "/workspace")) {
                if (app.remote.child_id.len > 0) {
                    try notice(app, "subagent", "This child transcript is read-only. Press Left to return to the parent before changing its workspace.");
                    return true;
                }
                if (app.remote.current_id.len == 0) {
                    try notice(app, "session", "Open a session before changing its workspace.");
                    return true;
                }
                const usage = "usage: /workspace [add PATH|remove PATH|clear]";
                if (rest.len == 0 or std.mem.eql(u8, rest, "list")) {
                    try app.remote.enqueue(.command, .{ .command = .{
                        .session_id = app.remote.current_id,
                        .name = "workspace",
                    } });
                    return true;
                }
                if (std.mem.eql(u8, rest, "clear")) {
                    try app.remote.enqueue(.command, .{ .command = .{
                        .session_id = app.remote.current_id,
                        .name = "workspace",
                        .action = "clear",
                    } });
                    return true;
                }
                const verb_end = std.mem.findAny(u8, rest, " \t") orelse {
                    try notice(app, "", usage);
                    return true;
                };
                const verb = rest[0..verb_end];
                const path = std.mem.trim(u8, rest[verb_end..], " \t");
                if (path.len == 0 or
                    (!std.mem.eql(u8, verb, "add") and !std.mem.eql(u8, verb, "remove")))
                {
                    try notice(app, "", usage);
                    return true;
                }
                try app.remote.enqueue(.command, .{ .command = .{
                    .session_id = app.remote.current_id,
                    .name = "workspace",
                    .action = verb,
                    .path = path,
                } });
                return true;
            }
            if (std.mem.eql(u8, name, "/shell")) {
                if (app.remote.child_id.len > 0) {
                    try notice(app, "subagent", "This child transcript is read-only. Press Left to return to the parent before reloading its shell.");
                    return true;
                }
                if (!std.mem.eql(u8, rest, "reload")) {
                    try notice(app, "", "usage: /shell reload");
                    return true;
                }
                if (app.remote.current_id.len == 0) {
                    try notice(app, "session", "Open a session before reloading its shell.");
                    return true;
                }
                try app.remote.enqueue(.command, .{ .command = .{
                    .session_id = app.remote.current_id,
                    .name = "shell_reload",
                } });
                return true;
            }
            if (std.mem.eql(u8, name, "/context")) {
                if (app.remote.child_id.len > 0) {
                    try notice(app, "subagent", "This child transcript is read-only. Press Left to return to the parent before checking its context.");
                    return true;
                }
                if (app.remote.current_id.len == 0) {
                    try notice(app, "session", "Open a session before checking its context.");
                    return true;
                }
                try app.remote.enqueue(.command, .{ .command = .{
                    .session_id = app.remote.current_id,
                    .name = "context",
                } });
                return true;
            }
            if (std.mem.eql(u8, name, "/compact")) {
                if (app.remote.child_id.len > 0) {
                    try notice(app, "subagent", "This child transcript is read-only. Press Left to return to the parent before compacting it.");
                    return true;
                }
                if (app.remote.current_id.len == 0) {
                    try notice(app, "session", "Open a session before compacting it.");
                    return true;
                }
                try app.remote.enqueue(.command, .{ .command = .{
                    .session_id = app.remote.current_id,
                    .name = "compact",
                } });
                try notice(app, "session", "Compacting context...");
                return true;
            }
            if (std.mem.eql(u8, name, "/clear")) {
                if (app.remote.child_id.len > 0) {
                    try notice(app, "subagent", "This child transcript is read-only. Press Left to return to the parent before clearing.");
                    return true;
                }
                // `/clear` carries the current session to the background and
                // starts a fresh conversation, exactly like `/new` in this
                // host; the daemon keeps the old session and its processes.
                try newSession(app);
                return true;
            }
            if (std.mem.eql(u8, name, "/undo")) {
                if (app.remote.child_id.len > 0) {
                    try notice(app, "subagent", "This child transcript is read-only. Press Left to return to the parent before undoing.");
                    return true;
                }
                if (app.remote.current_id.len == 0) {
                    try notice(app, "session", "Open a session before undoing a file operation.");
                    return true;
                }
                try app.remote.enqueue(.command, .{ .command = .{
                    .session_id = app.remote.current_id,
                    .name = "undo",
                } });
                return true;
            }
            if (optionIdForCommand(name)) |option| {
                try forwardSessionOption(app, option, rest);
                return true;
            }
            if (std.mem.eql(u8, name, "/mcp")) {
                if (app.remote.child_id.len > 0) {
                    try notice(app, "subagent", "This child transcript is read-only. Press Left to return to the parent before managing MCP servers.");
                    return true;
                }
                if (app.remote.current_id.len == 0) {
                    try notice(app, "session", "Open a session before managing MCP servers.");
                    return true;
                }
                if (rest.len == 0) {
                    try app.remote.enqueue(.command, .{ .command = .{
                        .session_id = app.remote.current_id,
                        .name = "mcp_status",
                    } });
                    return true;
                }
                try app.remote.enqueue(.command, .{ .command = .{
                    .session_id = app.remote.current_id,
                    .name = "mcp_verb",
                    .line = rest,
                } });
                return true;
            }
            if (std.mem.eql(u8, name, "/fork")) {
                try notice(app, "session", "Detached session fork is not available yet. Use /new to create a session, or /resume to switch.");
                return true;
            }
            for ([_][]const u8{ "/setup", "/teams", "/credits", "/login", "/logout", "/provider", "/upgrade", "/usage", "/feedback", "/balance" }) |legacy| {
                if (!std.mem.eql(u8, name, legacy)) continue;
                try notice(app, "setup", "proto-fx uses your OpenAI-compatible endpoint configuration. Gateway account login, billing, teams, and self-upgrade are disabled. Run proto-fx --help for setup.");
                return true;
            }
            if (std.mem.eql(u8, name, "/model") or std.mem.eql(u8, name, "/permissions")) {
                const is_model = std.mem.eql(u8, name, "/model");
                if (rest.len == 0) {
                    try notice(app, if (is_model) "model" else "permissions", if (is_model) app.remote.model else switch (app.remote.permission_mode) {
                        .ask => "ask",
                        .auto => "auto",
                        .yolo => "full-access",
                    });
                } else if (app.remote.current_id.len == 0) {
                    try notice(app, "session", "Open a session before changing its configuration.");
                } else if (is_model) {
                    try app.remote.enqueue(.config, .{ .model = .{ .session_id = app.remote.current_id, .model = rest } });
                } else if (types.PermissionMode.parse(rest)) |mode| {
                    try app.remote.enqueue(.config, .{ .mode = .{ .session_id = app.remote.current_id, .mode = switch (mode) {
                        .ask => "ask",
                        .auto => "auto",
                        .yolo => "full-access",
                    } } });
                } else try notice(app, "", "usage: /permissions ask|auto|full-access");
                return true;
            }
            const heartbeat = std.mem.eql(u8, name, "/heartbeat");
            const kernel = std.mem.eql(u8, name, "/kernel");
            if (!heartbeat and !kernel) return false;
            if (app.remote.current_id.len == 0) {
                try notice(app, "session", "Open a session before managing its background runtime.");
                return true;
            }
            const action_end = std.mem.findAny(u8, rest, " \t") orelse rest.len;
            const action = if (action_end == 0) "status" else rest[0..action_end];
            const args = std.mem.trim(u8, rest[action_end..], " \t");
            if (kernel) {
                if (args.len == 0) for ([_][]const u8{ "status", "restart", "stop", "prewarm", "interrupt" }) |allowed| {
                    if (!std.mem.eql(u8, action, allowed)) continue;
                    try app.remote.enqueue(.kernel, .{ .kernel = .{ .session_id = app.remote.current_id, .action = action } });
                    return true;
                };
                try notice(app, "", "usage: /kernel status|restart|stop|prewarm|interrupt");
                return true;
            }
            if (std.mem.eql(u8, action, "start")) {
                const seconds_end = std.mem.findAny(u8, args, " \t") orelse args.len;
                const seconds = std.fmt.parseInt(u64, args[0..seconds_end], 10) catch 0;
                const prompt = std.mem.trim(u8, args[seconds_end..], " \t");
                if (seconds > 0 and seconds <= 365 * 24 * 60 * 60 and prompt.len > 0) {
                    try app.remote.enqueue(.heartbeat, .{ .heartbeat = .{ .session_id = app.remote.current_id, .action = .set, .interval_ms = seconds * 1000, .prompt = prompt } });
                    return true;
                }
            } else if (args.len == 0) for ([_][]const u8{ "status", "pause", "resume", "stop" }) |allowed| {
                if (!std.mem.eql(u8, action, allowed)) continue;
                try app.remote.enqueue(.heartbeat, .{ .heartbeat = .{ .session_id = app.remote.current_id, .action = if (std.mem.eql(u8, action, "stop")) .clear else std.meta.stringToEnum(client_protocol.HeartbeatAction, action).? } });
                return true;
            };
            try notice(app, "", "usage: /heartbeat status|start <seconds> <prompt>|pause|resume|stop");
            return true;
        }

        fn notice(app: *App, topic: []const u8, body: []const u8) !void {
            try app.writeDomainNotice(.{ .topic = topic, .tone = .neutral, .body = body }, true);
        }

        /// `/effort`, `/fast`, and `/ultrafast` each name one host config
        /// option. The host owns the accepted values and the rejection text,
        /// so this only normalizes a boolean toggle; every other value passes
        /// through untouched.
        fn forwardSessionOption(app: *App, option: []const u8, rest: []const u8) !void {
            if (app.remote.child_id.len > 0) {
                try notice(app, "subagent", "This child transcript is read-only. Press Left to return to the parent before changing its configuration.");
                return;
            }
            if (app.remote.current_id.len == 0) {
                try notice(app, "session", "Open a session before changing its configuration.");
                return;
            }

            var value = rest;
            if (!std.mem.eql(u8, option, "effort")) {
                const enabled = parseToggle(rest) orelse {
                    try notice(app, "", if (std.mem.eql(u8, option, "fast")) "usage: /fast on|off" else "usage: /ultrafast on|off");
                    return;
                };
                value = if (enabled) "true" else "false";
            } else if (value.len == 0) {
                try notice(app, "", "usage: /effort auto|minimal|low|medium|high");
                return;
            }

            try app.remote.enqueue(.config, .{ .option = .{
                .session_id = app.remote.current_id,
                .config_id = option,
                .value = value,
            } });
        }

        /// Renders the result of a forwarded `fx/command`. The host owns the
        /// effect and its data; the frontend owns how it reads on screen.
        fn applyCommandResult(app: *App, value: std.json.Value) !void {
            const result = field(value, "result") orelse return;
            const command = string(result, "command") orelse return;
            if (std.mem.eql(u8, command, "last_reply")) {
                return applyLastReply(app, string(result, "text") orelse "");
            }
            if (std.mem.eql(u8, command, "compact")) {
                return applyCompaction(app, string(result, "compaction") orelse "");
            }
            if (std.mem.eql(u8, command, "undo")) {
                return applyUndo(app, result);
            }
            if (std.mem.eql(u8, command, "context")) {
                return applyContext(app, result);
            }
            if (std.mem.eql(u8, command, "mcp_verb")) {
                try notice(app, "mcp", string(result, "text") orelse "");
                return;
            }
            if (std.mem.eql(u8, command, "mcp_status")) {
                try notice(app, "mcp", string(result, "text") orelse "");
                return;
            }
            if (std.mem.eql(u8, command, "permissions_reload")) {
                try notice(app, "permissions", "Session permissions reloaded.");
                return;
            }
            if (std.mem.eql(u8, command, "workspace")) {
                try notice(app, "workspace", string(result, "text") orelse "");
                return;
            }
            if (std.mem.eql(u8, command, "shell_reload")) {
                try notice(app, "shell", "The next command reloads your shell startup files. Remembered command approvals were reset.");
                return;
            }
        }

        fn applyLastReply(app: *App, text: []const u8) !void {
            if (text.len == 0) {
                try notice(app, "clipboard", "No assistant reply to copy.");
                return;
            }
            if (!copyToClipboard(app, text)) {
                try notice(app, "clipboard", "Failed to copy to clipboard.");
                return;
            }
            try notice(app, "clipboard", "Copied to clipboard.");
        }

        fn applyCompaction(app: *App, outcome: []const u8) !void {
            if (std.mem.eql(u8, outcome, "compacted")) {
                try notice(app, "session", "Context compacted.");
            } else if (std.mem.eql(u8, outcome, "nothing_to_compact")) {
                try notice(app, "session", "No context to compact.");
            }
        }

        fn applyContext(app: *App, result: std.json.Value) !void {
            const used = integer(result, "used") orelse 0;
            const percent = integer(result, "auto_compact_percent") orelse 0;
            var buf: [192]u8 = undefined;
            const body = if (integer(result, "total")) |total|
                try std.mem.print(&buf, "context: {d} / {d} tokens ({d}%) · auto-compact at {d}%", .{
                    used,
                    total,
                    if (total > 0) @divTrunc(used * 100, total) else 0,
                    percent,
                })
            else
                try std.mem.print(&buf, "context: {d} tokens · auto-compact at {d}%", .{ used, percent });
            try notice(app, "context", body);
        }

        /// The host reports what happened to the file; the frontend renders the
        /// path safely, because a repository can name a file with control bytes.
        fn applyUndo(app: *App, result: std.json.Value) !void {
            const outcome = string(result, "outcome") orelse return;
            if (std.mem.eql(u8, outcome, "nothing_to_undo")) {
                try notice(app, "undo", "Nothing to undo.");
                return;
            }
            var arena_state = std.heap.ArenaAllocator.init(app.alloc);
            defer arena_state.deinit();
            const alloc = arena_state.allocator();
            const path = string(result, "path") orelse "";
            var safe = try text_utils.encodeTerminalSafe(alloc, path, std.Io.Dir.max_path_bytes);
            defer safe.deinit(alloc);
            const body = if (std.mem.eql(u8, outcome, "restored"))
                try alloc.print("Restored {s}", .{safe.bytes})
            else if (std.mem.eql(u8, outcome, "deleted"))
                try alloc.print("Deleted {s} (was newly created)", .{safe.bytes})
            else
                try alloc.print("Could not undo {s}", .{safe.bytes});
            try notice(app, "undo", body);
        }

        /// Replaces the host's live permission rules with what this process
        /// just wrote to the profile or project settings.
        pub fn reloadPermissions(app: *App) !void {
            if (app.remote.current_id.len == 0) return;
            try app.remote.enqueue(.command, .{ .command = .{
                .session_id = app.remote.current_id,
                .name = "permissions_reload",
            } });
        }

        pub fn newSession(app: *App) !void {
            app.clearPendingSubmissionForSessionTransition();
            if (app.remote.current_id.len > 0) app.alloc.free(app.remote.current_id);
            app.remote.current_id = &.{};
            if (app.remote.child_id.len > 0) app.alloc.free(app.remote.child_id);
            app.remote.child_id = &.{};
            app.remote.clearChildTracking(app.alloc);
            app.remote.generation +%= 1;
            app.remote.sequence = 0;
            app.remote.native_presentation = false;
            app.input_runtime.session_browser.close();
            resetTranscript(app);
            try app.remote.enqueue(.startup, .{ .create = .{ .cwd = app.workspace_root } });
        }

        pub fn submit(app: *App, prompt: []const u8, images: []const types.ImageAttachment) !bool {
            if (images.len > 0) {
                try notice(app, "images", "Image forwarding is not supported by the detached frontend yet. Remove the image attachments before sending; no prompt was submitted.");
                return false;
            }
            if (!app.remote.active or app.remote.current_id.len == 0) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .warning, .body = "The session is still connecting. Please send again when it is ready." }, true);
                return false;
            }
            if (app.remote.child_id.len > 0) {
                try app.writeDomainNotice(.{ .topic = "subagent", .tone = .neutral, .body = "This is a child transcript. Return to its parent to send a message." }, true);
                return false;
            }
            const text = try app.alloc.dupe(u8, prompt);
            errdefer app.alloc.free(text);
            if (app.remote.submitted_text.items.len >= 32) app.alloc.free(app.remote.submitted_text.orderedRemove(0));
            try app.remote.submitted_text.append(app.alloc, text);
            errdefer _ = app.remote.submitted_text.pop();
            try app.remote.enqueue(.submit, .{ .prompt = .{ .session_id = app.remote.current_id, .text = prompt } });
            app.stream.active = true;
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn cancel(app: *App) !void {
            if (app.remote.current_id.len == 0) return;
            try app.remote.enqueue(.cancel, .{ .cancel = .{ .session_id = app.remote.current_id } });
        }

        pub fn openSessionBrowser(app: *App, scope: browser_mod.Scope) !void {
            app.input_runtime.session_browser.open(scope);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            try refreshBrowser(app);
            app.shell.render_requests.request(.footer);
        }

        fn refreshBrowser(app: *App) !void {
            if (app.input_runtime.session_browser.scope == .sessions) {
                try app.remote.enqueue(.list, .list);
            } else if (app.remote.current_id.len > 0) {
                try app.remote.enqueue(.children, .{ .children = .{ .session_id = app.remote.current_id } });
            } else {
                try app.input_runtime.session_browser.replaceRows(app.alloc, &.{});
            }
            app.remote.next_list_ms = io_mod.milliTimestamp() + 750;
        }

        pub fn activateBrowserSelection(app: *App) !void {
            const browser = &app.input_runtime.session_browser;
            const row = browser.selectedRow() orelse return;
            const id = try app.alloc.dupe(u8, row.id);
            defer app.alloc.free(id);
            const scope = browser.scope;
            browser.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            if (scope == .subagents) {
                if (app.remote.child_id.len > 0) app.alloc.free(app.remote.child_id);
                app.remote.child_id = try app.alloc.dupe(u8, id);
                app.remote.generation +%= 1;
                app.remote.clearChildTracking(app.alloc);
                resetTranscriptContents(app);
                try refreshChild(app);
            } else {
                try switchSession(app, id);
            }
            app.shell.render_requests.request(.footer);
        }

        fn switchSession(app: *App, id: []const u8) !void {
            const owned = try app.alloc.dupe(u8, id);
            app.clearPendingSubmissionForSessionTransition();
            if (app.remote.current_id.len > 0) app.alloc.free(app.remote.current_id);
            app.remote.current_id = owned;
            if (app.remote.child_id.len > 0) app.alloc.free(app.remote.child_id);
            app.remote.child_id = &.{};
            app.remote.clearChildTracking(app.alloc);
            app.remote.generation +%= 1;
            app.remote.sequence = 0;
            app.remote.native_presentation = false;
            resetTranscript(app);
            try app.remote.enqueue(.attach, .{ .attach = .{ .session_id = app.remote.current_id, .after_sequence = 0 } });
        }

        pub fn browserBack(app: *App) !void {
            app.input_runtime.session_browser.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            if (app.remote.child_id.len > 0) {
                app.alloc.free(app.remote.child_id);
                app.remote.child_id = &.{};
                try switchSession(app, app.remote.current_id);
            }
            app.shell.render_requests.request(.footer);
        }

        fn resetTranscriptContents(app: *App) void {
            app.remote.markdown.reset(app.alloc);
            app.remote.message_id_len = 0;
            app.remote.native_source_turn_id = null;
            for (app.remote.submitted_text.items) |text| app.alloc.free(text);
            app.remote.submitted_text.clearRetainingCapacity();
            app.shell.clearTranscriptPreservingWelcome(app.alloc);
            app.stream = .{};
            _ = app.shell.worker_status_state().clear();
            app.remote.turn_id +%= 1;
            app.shell.render_requests.request(.transcript);
        }

        fn resetTranscript(app: *App) void {
            resetTranscriptContents(app);
            app.approval_prompt.clear(app.alloc);
            app.remote.pending_permission_id = null;
            app.remote.permission_response_queued = false;
            app.shell.render_requests.request(.transcript);
        }

        pub fn poll(app: *App) !void {
            const remote = &app.remote;
            if (!remote.active) return;
            if (remote.task) |task| {
                if (task.done.load(.acquire)) {
                    remote.task = null;
                    defer task.deinit();
                    if (task.request.generation == remote.generation) {
                        if (task.request.kind == .rpc) remote.permission_response_queued = false;
                        if (task.failure) |failure| {
                            remote.next_poll_ms = io_mod.milliTimestamp() + 2_000;
                            if (task.request.kind == .list or task.request.kind == .children) app.input_runtime.session_browser.fail(@errorName(failure));
                            try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = @errorName(failure) }, true);
                        } else if (task.response) |*response| {
                            try applyResponse(app, task.request.kind, response.value);
                        }
                    }
                }
            }
            const now = io_mod.milliTimestamp();
            if (remote.task == null and remote.queue.items.len == 0 and remote.current_id.len > 0 and now >= remote.next_poll_ms) {
                try remote.enqueue(.poll, .{ .attach = .{ .session_id = remote.current_id, .after_sequence = remote.sequence, .include_history = false } });
                remote.next_poll_ms = now + 100;
            }
            if (app.input_runtime.session_browser.active and now >= remote.next_list_ms and remote.queue.items.len < 2) try refreshBrowser(app);
            if (remote.child_id.len > 0 and now >= remote.next_child_poll_ms and remote.queue.items.len < 2) {
                try refreshChild(app);
            }
            try remote.startNext();
        }

        fn refreshChild(app: *App) !void {
            const remote = &app.remote;
            if (remote.task) |task| if (task.request.kind == .history and task.request.generation == remote.generation) return;
            for (remote.queue.items) |request| if (request.kind == .history and request.generation == remote.generation) return;
            try remote.enqueue(.history, .{ .history = .{
                .session_id = remote.current_id,
                .child_id = remote.child_id,
                .work_id = if (remote.child_work_id.len > 0) remote.child_work_id else null,
                .after_live_sequence = remote.child_sequence,
                .live_active = remote.child_live_active,
                .include_history = remote.child_history_count == null,
            } });
            remote.next_child_poll_ms = io_mod.milliTimestamp() + 150;
        }

        fn decode(comptime T: type, app: *App, value: std.json.Value) !std.json.Parsed(T) {
            return std.json.parseFromValue(T, app.alloc, value, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        }

        fn applyResponse(app: *App, kind: Kind, value: std.json.Value) !void {
            var outcome = try decode(client_protocol.Outcome, app, value);
            defer outcome.deinit();
            if (!outcome.value.ok) {
                const message = outcome.value.@"error" orelse "The local session request failed";
                if (kind == .list or kind == .children) app.input_runtime.session_browser.fail(message);
                try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = message }, true);
                return;
            }
            switch (kind) {
                .startup, .attach, .poll => {
                    var snapshot = try decode(SnapshotView, app, value);
                    defer snapshot.deinit();
                    try applySnapshot(app, snapshot.value);
                },
                .list => {
                    var listed = try decode(client_protocol.SessionList, app, value);
                    defer listed.deinit();
                    try applySessionRows(app, listed.value.sessions);
                },
                .children => {
                    var listed = try decode(client_protocol.Children, app, value);
                    defer listed.deinit();
                    try applyChildRows(app, listed.value.children);
                },
                .startup_last, .startup_remembered => {
                    var listed = try decode(client_protocol.SessionList, app, value);
                    defer listed.deinit();
                    var selected: ?[]const u8 = null;
                    if (kind == .startup_remembered) selected = listed.value.last_attached_id;
                    if (selected == null or selected.?.len == 0) {
                        var updated: i64 = -1;
                        for (listed.value.sessions) |row| {
                            if (!std.mem.eql(u8, row.cwd, app.workspace_root)) continue;
                            if (row.updated_at_ms >= updated) {
                                selected = row.id;
                                updated = row.updated_at_ms;
                            }
                        }
                    }
                    if (selected) |id| try switchSession(app, id) else try newSession(app);
                },
                .heartbeat => {
                    var state = try decode(client_protocol.HeartbeatState, app, value);
                    defer state.deinit();
                    const heartbeat = state.value.heartbeat;
                    const body = if (heartbeat.interval_ms == 0) try app.alloc.dupe(u8, "No heartbeat configured.") else try app.alloc.print("{s} · every {d}s · {s}", .{ if (heartbeat.paused) "Paused" else "Running", @divTrunc(heartbeat.interval_ms, 1000), heartbeat.prompt });
                    defer app.alloc.free(body);
                    try notice(app, "heartbeat", body);
                },
                .kernel => {
                    var state = try decode(client_protocol.KernelState, app, value);
                    defer state.deinit();
                    const body = try std.json.Stringify.valueAlloc(app.alloc, state.value.kernel, .{});
                    defer app.alloc.free(body);
                    try notice(app, "kernel", body);
                },
                .history => {
                    var child = try decode(client_protocol.ChildHistory(std.json.Value), app, value);
                    defer child.deinit();
                    try applyChildSnapshot(app, child.value);
                },
                .config => {
                    try notice(app, "session", "Session configuration updated.");
                    app.remote.next_poll_ms = 0;
                },
                .rename => {
                    try notice(app, "session", "Session renamed.");
                    app.remote.next_poll_ms = 0;
                },
                .rpc => app.remote.permission_response_queued = false,
                // The daemon accepts a session command and reports its result
                // through the event stream, so poll for it right away.
                .command => app.remote.next_poll_ms = 0,
                .submit, .cancel => app.remote.next_poll_ms = 0,
            }
            app.shell.render_requests.request(.footer);
        }

        fn applySessionRows(app: *App, sessions_listed: []const client_protocol.SessionSummary) !void {
            const browser = &app.input_runtime.session_browser;
            if (!browser.active or browser.scope != .sessions) return;
            var arena: std.heap.ArenaAllocator = .init(app.alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const rows = try a.alloc(browser_mod.Row, sessions_listed.len);
            const now_ms = io_mod.milliTimestamp();
            for (sessions_listed, rows) |item, *row| {
                var age_buf: [32]u8 = undefined;
                const age = session_catalog.relativeActivityAgeCompact(&age_buf, item.updated_at_ms, now_ms);
                const named = item.name.len > 0 and !std.mem.eql(u8, item.name, "session");
                const short_id = if (item.id.len > 8) item.id[0..8] else item.id;
                const active = item.status == .running or item.status == .awaiting_approval;
                row.* = .{
                    .id = item.id,
                    .parent_id = "",
                    .title = if (named) item.name else try a.print("session {s}", .{short_id}),
                    .status = @tagName(item.status),
                    .detail = "",
                    .meta = try a.dupe(u8, if (active) @tagName(item.status) else age),
                    .depth = 0,
                    .current = std.mem.eql(u8, item.id, app.remote.current_id),
                };
            }
            try browser.replaceRows(app.alloc, rows);
        }

        fn applyChildRows(app: *App, children: []const client_protocol.Child) !void {
            const browser = &app.input_runtime.session_browser;
            if (!browser.active or browser.scope != .subagents) return;
            var arena: std.heap.ArenaAllocator = .init(app.alloc);
            defer arena.deinit();
            const rows = try arena.allocator().alloc(browser_mod.Row, children.len);
            for (children, rows) |item, *row| {
                row.* = .{
                    .id = item.id,
                    .parent_id = item.parent_id,
                    .title = if (item.name.len > 0) item.name else item.id,
                    .status = item.status,
                    .detail = item.detail,
                    .meta = item.status,
                    .depth = item.depth,
                    .current = std.mem.eql(u8, item.id, app.remote.current_id),
                };
            }
            try browser.replaceRows(app.alloc, rows);
        }

        fn applyChildSnapshot(app: *App, value: client_protocol.ChildHistory(std.json.Value)) !void {
            const remote = &app.remote;
            if (remote.child_id.len == 0 or !std.mem.eql(u8, remote.child_id, value.child_id)) return;
            const live_active = value.live_active;
            const reset = value.live_reset or remote.child_history_count == null or
                !std.mem.eql(u8, value.work_id, remote.child_work_id) or value.live_sequence < remote.child_sequence or
                live_active != remote.child_live_active;
            if (reset) {
                const history = value.history orelse {
                    // Ask for a complete baseline rather than joining unrelated tails.
                    remote.child_history_count = null;
                    remote.next_child_poll_ms = 0;
                    return;
                };
                const owned_work = try app.alloc.dupe(u8, value.work_id);
                errdefer app.alloc.free(owned_work);
                const active_prompt = value.active_prompt orelse "";
                const owned_prompt = try app.alloc.dupe(u8, active_prompt);
                errdefer app.alloc.free(owned_prompt);
                resetTranscriptContents(app);
                try sessions.Runtime(App).replayRemoteHistory(app, history);
                remote.turn_id = app.shell.finalizedToolTurnWatermark() + 1;
                remote.native_turn_offset = remote.turn_id;
                const outcome = if (live_active) value.status else value.last_outcome orelse value.status;
                const body = try app.alloc.print("{s} · {s} · read-only child transcript · left returns to parent", .{ value.name, outcome });
                defer app.alloc.free(body);
                try notice(app, "subagent", body);
                if (!live_active) if (value.last_failure) |failure| try notice(app, "subagent", failure);
                if (live_active and active_prompt.len > 0) try app.writeUserPromptCard(.{ .text = @constCast(active_prompt) });
                if (value.oldest_live_sequence > 1) {
                    try notice(app, "subagent", "Earlier live output exceeded the preview buffer. The complete transcript will load when this work finishes.");
                }
                if (remote.child_work_id.len > 0) app.alloc.free(remote.child_work_id);
                remote.child_work_id = owned_work;
                if (remote.child_prompt.len > 0) app.alloc.free(remote.child_prompt);
                remote.child_prompt = owned_prompt;
                remote.child_history_count = history.len;
                remote.child_sequence = 0;
                if (live_active) app.stream.turn_started_ms = io_mod.milliTimestamp();
            }
            const status = value.status;
            remote.child_status_len = @min(status.len, remote.child_status.len);
            @memcpy(remote.child_status[0..remote.child_status_len], status[0..remote.child_status_len]);
            remote.child_live_active = live_active;
            app.stream.active = childIsRunning(app);
            if (std.mem.eql(u8, status, "awaiting_approval")) {
                if (app.stream.waiting_since_ms == 0) app.stream.waiting_since_ms = io_mod.milliTimestamp();
            } else if (app.stream.waiting_since_ms != 0) {
                app.stream.turn_started_ms += io_mod.milliTimestamp() - app.stream.waiting_since_ms;
                app.stream.waiting_since_ms = 0;
            }
            const live_events = itemsOf(value.live_events);
            for (live_events) |entry| {
                const event_sequence: u64 = @intCast(@max(0, integer(entry, "sequence") orelse 0));
                if (event_sequence <= remote.child_sequence) continue;
                if (string(entry, "text")) |text| {
                    _ = try app.shell.streamAssistantChunk(app.alloc, &app.metrics, text);
                    app.stream.phase = .generating;
                } else if (field(entry, "event")) |event| {
                    try applyNativeEvent(app, event);
                }
                remote.child_sequence = event_sequence;
            }
            remote.child_sequence = @max(remote.child_sequence, value.live_sequence);
            try callbacks.Bindings(App).worker_tool_lifecycle_presenter(app).finish_batch(app.alloc);
            if (reset or live_events.len > 0) app.shell.render_requests.request(.transcript);
        }

        fn nativeLifecycleId(app: *App, id: types.ToolLifecycleId) !types.ToolLifecycleId {
            return .{ .turn_id = std.math.add(u64, app.remote.native_turn_offset, id.turn_id) catch return error.InvalidNativeTurnId, .call_id = id.call_id };
        }

        fn beginNativeTurn(app: *App, source_turn_id: u64) void {
            if (app.remote.native_source_turn_id == source_turn_id) return;
            app.remote.native_source_turn_id = source_turn_id;
            app.stream = .{ .active = true, .turn_started_ms = io_mod.milliTimestamp() };
            _ = app.shell.worker_status_state().clear();
            app.shell.render_requests.requestAnimationReset();
            app.shell.render_requests.request(.footer);
        }

        /// Native root and child frames share fx's owned presentation reducer.
        /// The offset is fixed for the displayed history baseline: user echoes
        /// (including steering) must not change an in-flight tool's identity.
        /// A host sends a tool's status as plain text; the transcript marks
        /// its status rows, as the local terminal's own tool labels are.
        /// Text that already carries the marker came from an older host.
        fn withStatusMarker(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
            const marker = "● ";
            if (text.len == 0 or std.mem.startsWith(u8, text, marker)) return text;
            return std.mem.concat(arena, u8, &.{ marker, text });
        }

        fn applyNativeEvent(app: *App, event: std.json.Value) !void {
            if (field(event, "tool_lifecycle")) |value| {
                var parsed = try std.json.parseFromValue(types.ToolLifecycleEvent, app.alloc, value, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                var lifecycle = parsed.value;
                switch (lifecycle) {
                    .provisional => |*started| {
                        beginNativeTurn(app, started.id.turn_id);
                        started.id = try nativeLifecycleId(app, started.id);
                        if (started.presentation_group_id) |*group| group.turn_id = started.id.turn_id;
                    },
                    .authoritative_started => |*started| {
                        beginNativeTurn(app, started.id.turn_id);
                        started.id = try nativeLifecycleId(app, started.id);
                        if (started.presentation_group_id) |*group| group.turn_id = started.id.turn_id;
                    },
                    .progress => |*progress| {
                        progress.id = try nativeLifecycleId(app, progress.id);
                        if (app.shell.toolActivityRecord(progress.id) == null) return;
                        progress.text = try withStatusMarker(parsed.arena.allocator(), progress.text);
                    },
                    .terminal => |*terminal| {
                        terminal.id = try nativeLifecycleId(app, terminal.id);
                        if (app.shell.toolActivityRecord(terminal.id) == null) return;
                        terminal.outcome.summary = try withStatusMarker(parsed.arena.allocator(), terminal.outcome.summary);
                    },
                    .turn_finished => |*finished| finished.turn_id = (try nativeLifecycleId(app, .{ .turn_id = finished.turn_id, .call_id = "" })).turn_id,
                }
                const transition = try callbacks.Bindings(App).worker_tool_lifecycle_presenter(app).apply(app.alloc, lifecycle);
                if (transition.applied_activity_kind) |kind| {
                    app.stream.chunks += 1;
                    switch (kind) {
                        .read => app.stream.read_count += 1,
                        .write => app.stream.write_count += 1,
                        .edit => app.stream.edit_count += 1,
                        .open => app.stream.open_count += 1,
                        .command => app.stream.command_count += 1,
                        .subagent => app.stream.subagent_count += 1,
                        .ask => {},
                    }
                }
                switch (lifecycle) {
                    .provisional, .authoritative_started, .progress => app.stream.phase = .running,
                    .terminal => {},
                    .turn_finished => app.stream.active = false,
                }
                app.stream.last_activity_kind = transition.snapshot.focused_activity_kind;
                if (transition.focus_changed()) app.shell.render_requests.requestAnimationReset();
            } else if (field(event, "command_output")) |value| {
                var parsed = try std.json.parseFromValue(worker_runtime.CommandOutputChunk, app.alloc, value, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                const id = if (parsed.value.lifecycle_id) |source| try nativeLifecycleId(app, source) else null;
                if (id) |identity| if (app.shell.toolActivityRecord(identity) == null) return;
                try app.writeCommandOutputChunkForLifecycle(id, parsed.value.stream, parsed.value.text, true);
            } else if (field(event, "command_output_complete")) |value| {
                var parsed = try std.json.parseFromValue(?types.ToolLifecycleId, app.alloc, value, .{});
                defer parsed.deinit();
                const id = if (parsed.value) |source| try nativeLifecycleId(app, source) else null;
                if (id) |identity| if (app.shell.toolActivityRecord(identity) == null) return;
                try app.flushCommandOutputSummaryForLifecycle(id, true);
            } else if (field(event, "turn_phase_update")) |value| {
                var parsed = try std.json.parseFromValue(types.TurnPhaseUpdate, app.alloc, value, .{});
                defer parsed.deinit();
                beginNativeTurn(app, parsed.value.turn_id);
                if (parsed.value.step_id >= app.stream.phase_step_id) {
                    app.stream.phase = parsed.value.phase;
                    app.stream.phase_step_id = parsed.value.step_id;
                }
            } else if (field(event, "turn_token_update")) |value| {
                var parsed = try std.json.parseFromValue(types.TurnTokenProgress, app.alloc, value, .{});
                defer parsed.deinit();
                app.stream.token_progress = parsed.value;
            } else if (field(event, "assistant_presentation")) |value| {
                var parsed = try std.json.parseFromValue(presentation.Event, app.alloc, value, .{});
                defer parsed.deinit();
                switch (parsed.value) {
                    .text => |text| _ = try app.shell.streamAssistantChunk(app.alloc, &app.metrics, text),
                    .table => |table| {
                        var owned = try table.clone(app.alloc);
                        errdefer owned.deinit(app.alloc);
                        try app.appendAssistantTable(owned);
                    },
                    .code_block => |block| {
                        var owned = try block.clone(app.alloc);
                        errdefer owned.deinit(app.alloc);
                        try app.appendAssistantCodeBlock(owned);
                    },
                    .thematic_rule => try app.appendAssistantThematicRule(),
                }
            } else if (field(event, "diff_block")) |value| {
                var parsed = try std.json.parseFromValue(diff.DiffEntryPayload, app.alloc, value, .{});
                defer parsed.deinit();
                const owned = try worker_runtime.dupeWorkerEvent(std.heap.c_allocator, .{ .diff_block = parsed.value });
                try app.registerAndEmitDiffBlock(owned.diff_block);
            } else if (field(event, "append_user_feedback")) |value| {
                if (value == .string) try app.writeUserPromptCard(.{ .text = @constCast(value.string) });
            } else if (field(event, "semantic_notice") orelse field(event, "error_text")) |value| {
                var parsed = try std.json.parseFromValue(types.SemanticNotice, app.alloc, value, .{});
                defer parsed.deinit();
                try app.writeDomainNotice(parsed.value, true);
            } else if (field(event, "route_recovery_status")) |value| {
                var parsed = try std.json.parseFromValue(types.RouteRecoveryStatus, app.alloc, value, .{});
                defer parsed.deinit();
                app.shell.worker_status_state().set_route_recovery(parsed.value, io_mod.milliTimestamp());
            } else if (field(event, "clear_route_recovery_status") != null) {
                _ = app.shell.worker_status_state().clear_route_recovery();
            }
        }

        fn applySnapshot(app: *App, value: SnapshotView) !void {
            const remote = &app.remote;
            const changed = if (remote.incarnation.len > 0) !std.mem.eql(u8, remote.incarnation, value.incarnation) else remote.sequence > 0;
            if (remote.incarnation.len == 0 or changed) {
                const owned = try app.alloc.dupe(u8, value.incarnation);
                if (remote.incarnation.len > 0) app.alloc.free(remote.incarnation);
                remote.incarnation = owned;
            }
            if (changed) {
                // Never replay a command after a connection's execution owner changes.
                for (remote.queue.items) |*request| request.deinit();
                remote.queue.clearRetainingCapacity();
                try switchSession(app, value.session_id);
                remote.reconnect_notice = true;
                return;
            }
            if (remote.current_id.len == 0) remote.current_id = try app.alloc.dupe(u8, value.session_id);
            if (value.history) |history| {
                resetTranscript(app);
                try sessions.Runtime(App).replayRemoteHistory(app, history);
                remote.turn_id = app.shell.finalizedToolTurnWatermark() + 1;
                remote.native_turn_offset = remote.turn_id;
                remote.sequence = value.history_sequence orelse 0;
            }
            // Select the presentation lane before applying any frames, including
            // the initial attachment tail.
            remote.native_presentation = value.native_presentation;
            const summary = value.session;
            if (!std.mem.eql(u8, summary.cwd, remote.cwd)) {
                const owned = try app.alloc.dupe(u8, summary.cwd);
                errdefer app.alloc.free(owned);
                const label = try text_utils.encodeTerminalSafeInline(app.alloc, std.Io.Dir.path.basename(summary.cwd), 128);
                if (remote.cwd.len > 0) app.alloc.free(remote.cwd);
                if (remote.workspace_label.len > 0) app.alloc.free(remote.workspace_label);
                remote.cwd = owned;
                remote.workspace_label = label.bytes;
            }
            if (!std.mem.eql(u8, summary.name, app.session_title.items)) {
                try sessions.Runtime(App).setCachedSessionTitle(app, summary.name);
            }
            if (!std.mem.eql(u8, summary.model, remote.model)) {
                const owned = try app.alloc.dupe(u8, summary.model);
                if (remote.model.len > 0) app.alloc.free(remote.model);
                remote.model = owned;
            }
            remote.permission_mode = types.PermissionMode.parse(summary.mode) orelse remote.permission_mode;
            // The inactive local engine mirrors the attached projection for settings panels.
            app.permission_engine.mode = remote.permission_mode;
            const running = summary.status == .running or summary.status == .awaiting_approval;
            for (value.events) |event| {
                if (event.sequence <= remote.sequence) continue;
                if (remote.child_id.len == 0) try applyFrame(app, event.frame);
                remote.sequence = event.sequence;
            }
            if (remote.child_id.len == 0) {
                try callbacks.Bindings(App).worker_tool_lifecycle_presenter(app).finish_batch(app.alloc);
                if (!running and !remote.native_presentation) try flushMarkdown(app);
                if (summary.status == .awaiting_approval) {
                    if (app.stream.waiting_since_ms == 0) app.stream.waiting_since_ms = io_mod.milliTimestamp();
                } else if (app.stream.waiting_since_ms != 0) {
                    app.stream.turn_started_ms += io_mod.milliTimestamp() - app.stream.waiting_since_ms;
                    app.stream.waiting_since_ms = 0;
                }
            }
            var submission_queued = false;
            for (remote.queue.items) |request| if (request.kind == .submit and request.generation == remote.generation) {
                submission_queued = true;
                break;
            };
            app.stream.active = if (remote.child_id.len > 0) childIsRunning(app) else running or submission_queued;
            if (remote.reconnect_notice) {
                remote.reconnect_notice = false;
                try notice(app, "session", "Supervisor restarted; restored this session. Unsent requests were not replayed.");
            }
            if (!remote.permission_response_queued) {
                if (value.pending.len == 0) {
                    remote.pending_permission_id = null;
                    app.approval_prompt.clear(app.alloc);
                } else for (value.pending) |frame| {
                    if (std.mem.eql(u8, string(frame, "method") orelse "", "session/request_permission")) {
                        try showPermission(app, frame);
                        break;
                    }
                }
            }
        }

        fn childIsRunning(app: *App) bool {
            const status = app.remote.child_status[0..app.remote.child_status_len];
            return app.remote.child_live_active or std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "awaiting_approval");
        }

        fn applyFrame(app: *App, frame: std.json.Value) !void {
            const method = string(frame, "method") orelse return;
            if (std.mem.eql(u8, method, client_protocol.replay_gap_method)) {
                try notice(app, "session", "Some live output exceeded the replay buffer. Reopen this session after its turn finishes to load the complete saved transcript.");
                return;
            }
            if (std.mem.eql(u8, method, "fx/mcp_notice")) {
                const params = field(frame, "params") orelse return;
                if (string(params, "session_id")) |id| if (!std.mem.eql(u8, id, app.remote.current_id)) return;
                const text = string(params, "text") orelse return;
                try app.writeDomainNotice(.{
                    .topic = "mcp",
                    .tone = if (boolean(params, "warning")) .warning else .neutral,
                    .body = text,
                }, true);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (std.mem.eql(u8, method, client_protocol.command_result_method)) {
                const params = field(frame, "params") orelse return;
                var result = try decode(client_protocol.CommandResult(std.json.Value), app, params);
                defer result.deinit();
                if (!result.value.ok) {
                    const message = result.value.@"error" orelse "The session command failed";
                    try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = message }, true);
                    app.shell.render_requests.request(.footer);
                    return;
                }
                try applyCommandResult(app, params);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (std.mem.eql(u8, method, "proto/native_presentation")) {
                if (!app.remote.native_presentation) return;
                const params = field(frame, "params") orelse return;
                if (string(params, "session_id")) |id| if (!std.mem.eql(u8, id, app.remote.current_id)) return;
                if (string(params, "text")) |text| {
                    _ = try app.shell.streamAssistantChunk(app.alloc, &app.metrics, text);
                    app.stream.phase = .generating;
                } else if (field(params, "event")) |event| {
                    try applyNativeEvent(app, event);
                }
                app.shell.render_requests.request(.transcript);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (!std.mem.eql(u8, method, "session/update")) return;
            const params = field(frame, "params") orelse return;
            const update = field(params, "update") orelse return;
            const kind = string(update, "sessionUpdate") orelse return;
            if (app.remote.native_presentation and
                (std.mem.eql(u8, kind, "agent_message_chunk") or
                    std.mem.eql(u8, kind, "tool_call") or
                    std.mem.eql(u8, kind, "tool_call_update"))) return;
            if (std.mem.eql(u8, kind, "agent_message_chunk")) {
                if (string(update, "messageId")) |message_id| {
                    const bounded = message_id[0..@min(message_id.len, app.remote.message_id.len)];
                    if (app.remote.message_id_len > 0 and !std.mem.eql(u8, bounded, app.remote.message_id[0..app.remote.message_id_len])) {
                        try flushMarkdown(app);
                        app.remote.markdown.reset(app.alloc);
                        _ = try app.shell.streamAssistantChunk(app.alloc, &app.metrics, "\n\n");
                    }
                    @memcpy(app.remote.message_id[0..bounded.len], bounded);
                    app.remote.message_id_len = bounded.len;
                }
                const content = field(update, "content") orelse return;
                const text = string(content, "text") orelse return;
                var rendered: std.ArrayList(u8) = .empty;
                defer rendered.deinit(app.alloc);
                try app.remote.markdown.push(app.alloc, text, &rendered);
                if (rendered.items.len > 0) _ = try app.shell.streamAssistantChunk(app.alloc, &app.metrics, rendered.items);
                app.shell.render_requests.request(.transcript);
            } else if (std.mem.eql(u8, kind, "user_message_chunk")) {
                try flushMarkdown(app);
                app.remote.markdown.reset(app.alloc);
                app.remote.message_id_len = 0;
                const content = field(update, "content") orelse return;
                const text = string(content, "text") orelse return;
                var submitted: ?usize = null;
                for (app.remote.submitted_text.items, 0..) |own, i| if (std.mem.eql(u8, own, text)) {
                    submitted = i;
                    break;
                };
                if (submitted) |i| app.alloc.free(app.remote.submitted_text.orderedRemove(i)) else try app.writeUserPromptCard(.{ .text = @constCast(text) });
                app.remote.turn_id +%= 1;
            } else if (std.mem.eql(u8, kind, "tool_call")) {
                try flushMarkdown(app);
                app.remote.message_id_len = 0;
                const id = string(update, "toolCallId") orelse return;
                const name = string(update, "name") orelse "tool";
                const title = string(update, "title") orelse name;
                var writer: std.Io.Writer.Allocating = .init(app.alloc);
                defer writer.deinit();
                try std.json.Stringify.value(field(update, "rawInput") orelse .null, .{}, &writer.writer);
                const presenter = callbacks.Bindings(App).worker_tool_lifecycle_presenter(app);
                _ = try presenter.apply(app.alloc, .{ .authoritative_started = .{
                    .id = .{ .turn_id = app.remote.turn_id, .call_id = id },
                    .reconciles_provisional_call_id = null,
                    .tool_name = name,
                    .activity_kind = toolKind(string(update, "kind") orelse "other"),
                    .arguments_json = writer.written(),
                } });
                _ = try presenter.apply(app.alloc, .{ .progress = .{ .id = .{ .turn_id = app.remote.turn_id, .call_id = id }, .text = title } });
            } else if (std.mem.eql(u8, kind, "tool_call_update")) {
                const id = string(update, "toolCallId") orelse return;
                const status = string(update, "status") orelse return;
                if (!std.mem.eql(u8, status, "completed") and !std.mem.eql(u8, status, "failed")) return;
                var result: std.Io.Writer.Allocating = .init(app.alloc);
                defer result.deinit();
                for (array(update, "content")) |part| {
                    const content = field(part, "content") orelse continue;
                    if (string(content, "text")) |text| try result.writer.writeAll(text);
                }
                const failed = std.mem.eql(u8, status, "failed");
                const presenter = callbacks.Bindings(App).worker_tool_lifecycle_presenter(app);
                _ = try presenter.apply(app.alloc, .{ .terminal = .{
                    .id = .{ .turn_id = app.remote.turn_id, .call_id = id },
                    .outcome = .{ .kind = if (failed) .failed else .completed, .summary = if (failed) "Tool failed" else "Tool completed" },
                    .result = result.written(),
                } });
            } else if (std.mem.eql(u8, kind, "notice")) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .neutral, .body = string(update, "title") orelse "" }, true);
            }
        }

        fn flushMarkdown(app: *App) !void {
            var rendered: std.ArrayList(u8) = .empty;
            defer rendered.deinit(app.alloc);
            try app.remote.markdown.flush(app.alloc, &rendered);
            if (rendered.items.len > 0) _ = try app.shell.streamAssistantChunk(app.alloc, &app.metrics, rendered.items);
            app.shell.render_requests.request(.transcript);
        }

        fn showPermission(app: *App, frame: std.json.Value) !void {
            const id: u64 = @intCast(integer(frame, "id") orelse return);
            if (app.approval_prompt.request) |request| if (request.id == id) return;
            app.remote.pending_permission_id = @intCast(id);
            const params = field(frame, "params") orelse return;
            const tool = field(params, "toolCall") orelse return;
            var label: std.Io.Writer.Allocating = .init(app.alloc);
            defer label.deinit();
            try label.writer.writeAll(string(tool, "title") orelse "Tool needs permission");
            if (field(tool, "rawInput")) |arguments| {
                try label.writer.writeAll(" · ");
                try std.json.Stringify.value(arguments, .{}, &label.writer);
            }
            _ = try app.approval_prompt.syncRequest(app.alloc, .{ .id = id, .label = label.written(), .amendment_allowed = false });
            app.shell.render_requests.request(.modal);
        }

        pub fn resolvePermission(app: *App, decision: types.ToolPermissionDecision) !bool {
            const id = app.remote.pending_permission_id orelse return false;
            const option: client_protocol.PermissionOption = switch (decision) {
                .once => .allow_once,
                .always => .allow_always,
                .deny, .policy_denied, .permission_required => .reject_once,
            };
            try app.remote.enqueue(.rpc, .{ .permission = .{ .session_id = app.remote.current_id, .request_id = id, .option = option } });
            app.remote.permission_response_queued = true;
            app.approval_prompt.clear(app.alloc);
            app.shell.render_requests.request(.modal);
            return true;
        }
    };
}
fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}

/// Test hosts and embedders need not offer a clipboard; production hosts do.
fn copyToClipboard(app: anytype, text: []const u8) bool {
    const Host = @TypeOf(app.*);
    return if (comptime @hasDecl(Host, "clipboard"))
        app.clipboard().copy(text) catch false
    else
        false;
}

/// The host config option each speed or effort command names, or null when
/// the command belongs to something else.
fn optionIdForCommand(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "/effort")) return "effort";
    if (std.mem.eql(u8, name, "/fast")) return "fast";
    if (std.mem.eql(u8, name, "/ultrafast")) return "ultrafast";
    return null;
}

/// The words a person types for a boolean config option. The host speaks
/// `true` and `false`; the frontend accepts both and the on/off shorthand.
fn parseToggle(raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "on") or std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "off") or std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
    return null;
}

fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
    const v = field(value, key) orelse return null;
    return if (v == .string) v.string else null;
}
fn integer(value: std.json.Value, key: []const u8) ?i64 {
    const v = field(value, key) orelse return null;
    return if (v == .integer) v.integer else null;
}
fn boolean(value: std.json.Value, key: []const u8) bool {
    const v = field(value, key) orelse return false;
    return v == .bool and v.bool;
}
fn array(value: std.json.Value, key: []const u8) []const std.json.Value {
    return itemsOf(field(value, key) orelse return &.{});
}
fn itemsOf(value: std.json.Value) []const std.json.Value {
    return if (value == .array) value.array.items else &.{};
}
fn toolKind(kind: []const u8) types.ToolActivityKind {
    if (std.mem.eql(u8, kind, "read")) return .read;
    if (std.mem.eql(u8, kind, "edit")) return .edit;
    if (std.mem.eql(u8, kind, "search")) return .read;
    if (std.mem.eql(u8, kind, "think")) return .ask;
    return .command;
}

const NativePresentationTestApp = struct {
    alloc: Allocator = std.testing.allocator,
    remote: State = .{ .native_turn_offset = 100 },
    stream: types.StreamState = .{ .active = true },
    user_prompt_count: usize = 0,
    reject_semantic: bool = false,
    metrics: types.Metrics = .{},
    shell: @import("../../ui/transcript/runtime.zig").TranscriptRuntime = .{},

    pub fn writeCommandOutputChunkForLifecycle(self: *@This(), id: ?types.ToolLifecycleId, stream: @import("../tooling/command_output_content.zig").Stream, text: []const u8, record: bool) !void {
        try self.shell.writeCommandOutputChunkForLifecycle(self.alloc, &self.metrics, .{}, id, stream, text, record);
    }
    pub fn flushCommandOutputSummaryForLifecycle(self: *@This(), id: ?types.ToolLifecycleId, record: bool) !void {
        try self.shell.flushCommandOutputSummaryForLifecycle(self.alloc, &self.metrics, .{}, id, record);
    }
    pub fn appendAssistantTable(self: *@This(), table: presentation.TablePayload) !void {
        if (self.reject_semantic) return error.TestAppendRejected;
        _ = try self.shell.appendAssistantTableOwned(self.alloc, table);
    }
    pub fn appendAssistantCodeBlock(self: *@This(), block: presentation.CodeBlockPayload) !void {
        if (self.reject_semantic) return error.TestAppendRejected;
        _ = try self.shell.appendAssistantCodeBlockOwned(self.alloc, block);
    }
    pub fn appendAssistantThematicRule(self: *@This()) !void {
        _ = try self.shell.appendAssistantThematicRule(self.alloc);
    }
    pub fn registerAndEmitDiffBlock(_: *@This(), payload: diff.DiffEntryPayload) !void {
        diff.freeDiffEntryPayload(std.heap.c_allocator, payload);
    }
    pub fn writeUserPromptCard(self: *@This(), _: types.UserTurn) !void {
        self.user_prompt_count += 1;
    }
    pub fn writeDomainNotice(self: *@This(), value: types.SemanticNotice, record: bool) !void {
        try self.shell.writeNotice(self.alloc, &self.metrics, value, record);
    }
    fn apply(self: *@This(), json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, json, .{});
        defer parsed.deinit();
        try Runtime(@This()).applyNativeEvent(self, parsed.value);
    }
    fn statusText(self: *@This(), id: types.ToolLifecycleId) ![]const u8 {
        const record = self.shell.toolActivityRecord(id) orelse return error.TestExpectedTool;
        for (self.shell.entries.items) |entry| {
            if (entry == .raw_bytes and entry.raw_bytes.id == record.entry_id) return entry.raw_bytes.bytes;
        }
        return error.TestExpectedStatus;
    }

    fn frame(self: *@This(), json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, json, .{});
        defer parsed.deinit();
        try Runtime(@This()).applyFrame(self, parsed.value);
    }
};

test "child live native events retain tool output and isolate view turn identities" {
    var app: NativePresentationTestApp = .{};
    defer app.shell.deinit(app.alloc);
    defer app.remote.deinit(app.alloc);
    try app.apply("{\"assistant_presentation\":{\"text\":\"child prose\\n\"}}");
    try app.apply("{\"tool_lifecycle\":{\"authoritative_started\":{\"id\":{\"turn_id\":1,\"call_id\":\"call\"},\"reconciles_provisional_call_id\":null,\"tool_name\":\"shell\",\"activity_kind\":\"command\",\"arguments_json\":\"{\\\"action\\\":\\\"run\\\",\\\"command\\\":\\\"printf child\\\"}\"}}}");
    const id: types.ToolLifecycleId = .{ .turn_id = 101, .call_id = "call" };
    try std.testing.expect(app.shell.toolActivityRecord(id) != null);
    try std.testing.expectEqual(types.TurnPhase.running, app.stream.phase);
    try app.apply("{\"command_output\":{\"lifecycle_id\":{\"turn_id\":1,\"call_id\":\"call\"},\"stream\":\"stdout\",\"text\":\"child stdout\\n\"}}");
    try app.apply("{\"command_output_complete\":{\"turn_id\":1,\"call_id\":\"call\"}}");
    try app.apply("{\"tool_lifecycle\":{\"terminal\":{\"id\":{\"turn_id\":1,\"call_id\":\"call\"},\"outcome\":{\"kind\":\"completed\",\"summary\":\"Ran printf child\"},\"result\":\"child stdout\\n\"}}}");
    try std.testing.expect(std.mem.find(u8, try app.statusText(id), "Ran printf child") != null);
    const record = app.shell.toolActivityRecord(id).?;
    const detail = app.shell.toolDetailForEntry(record.entry_id).?;
    try std.testing.expectEqualStrings("child stdout\n", detail.result.?);
    try std.testing.expect(detail.command_output_entry_id != null);
    try app.apply("{\"turn_phase_update\":{\"turn_id\":1,\"step_id\":2,\"phase\":\"generating\"}}");
    try std.testing.expectEqual(types.TurnPhase.generating, app.stream.phase);
    app.shell.clearTranscript(app.alloc);
    app.remote.native_turn_offset = 200;
    // A retained tail with no start must not recreate a tool from another view.
    try app.apply("{\"tool_lifecycle\":{\"terminal\":{\"id\":{\"turn_id\":1,\"call_id\":\"call\"},\"outcome\":{\"kind\":\"completed\",\"summary\":\"stale\"}}}}");
    try std.testing.expect(app.shell.toolActivityRecord(id) == null);
    try std.testing.expect(app.shell.toolActivityRecord(.{ .turn_id = 201, .call_id = "call" }) == null);
}

test "root native presentation preserves tool detail through steering and resets turn metrics" {
    var app: NativePresentationTestApp = .{};
    defer app.shell.deinit(app.alloc);
    defer app.remote.deinit(app.alloc);
    app.remote.native_presentation = true;
    app.remote.current_id = try app.alloc.dupe(u8, "root");
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","text":"NATIVE_ONLY\n"}}
    );
    const native_text_bytes = app.shell.transcript.items.len;
    try app.frame(
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"NATIVE_ONLY\n"}}}}
    );
    try std.testing.expectEqual(native_text_bytes, app.shell.transcript.items.len);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"turn_phase_update":{"turn_id":7,"step_id":8,"phase":"thinking"}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"turn_token_update":{"input_tokens":5,"output_tokens":13}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"authoritative_started":{"id":{"turn_id":7,"call_id":"shell-1"},"reconciles_provisional_call_id":null,"tool_name":"shell","activity_kind":"command","arguments_json":"{\"action\":\"run\",\"command\":\"printf root\"}"}}}}}
    );
    const id: types.ToolLifecycleId = .{ .turn_id = 107, .call_id = "shell-1" };
    try std.testing.expect(app.shell.toolActivityRecord(id) != null);
    try std.testing.expectEqual(@as(usize, 1), app.stream.command_count);
    try std.testing.expectEqual(@as(u64, 13), app.stream.token_progress.output_tokens);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"progress":{"id":{"turn_id":7,"call_id":"shell-1"},"text":"Running printf root"}}}}}
    );
    try std.testing.expect(std.mem.find(u8, try app.statusText(id), "Running printf root") != null);
    // The host sent plain text; the frontend marks the status row.
    try std.testing.expect(std.mem.startsWith(u8, try app.statusText(id), "●"));
    // The ACP compatibility copy must not create another tool or replace labels.
    try app.frame(
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"duplicate","name":"shell","title":"generic shell","kind":"execute"}}}
    );
    try std.testing.expectEqual(@as(usize, 1), app.shell.toolActivityRecordCount());
    try app.frame(
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"shell-1","status":"completed","content":[]}}}
    );
    try std.testing.expectEqual(@import("../output/activity_runtime.zig").ToolLifecyclePhase.authoritative, app.shell.toolActivityRecord(id).?.phase);
    // Steering keeps the ACP user echo, without changing native lifecycle keys.
    try app.frame(
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"text":"steer"}}}}
    );
    try std.testing.expectEqual(@as(usize, 1), app.user_prompt_count);
    try std.testing.expectEqual(@as(u64, 100), app.remote.native_turn_offset);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"command_output":{"lifecycle_id":{"turn_id":7,"call_id":"shell-1"},"stream":"stdout","text":"root stdout\n"}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"command_output_complete":{"turn_id":7,"call_id":"shell-1"}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"terminal":{"id":{"turn_id":7,"call_id":"shell-1"},"outcome":{"kind":"failed","summary":"Failed printf root"},"result":"root stdout\n"}}}}}
    );
    const detail = app.shell.toolDetailForEntry(app.shell.toolActivityRecord(id).?.entry_id).?;
    try std.testing.expect(std.mem.find(u8, try app.statusText(id), "Failed printf root") != null);
    try std.testing.expectEqual(types.ToolOutcomeKind.failed, detail.outcome.?);
    try std.testing.expectEqualStrings("root stdout\n", detail.result.?);
    try std.testing.expect(detail.command_output_entry_id != null);
    // Permission feedback owns a separate native user card (not a steering echo).
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"append_user_feedback":"Use another command"}}}
    );
    try std.testing.expectEqual(@as(usize, 2), app.user_prompt_count);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"turn_phase_update":{"turn_id":8,"step_id":1,"phase":"generating"}}}}
    );
    try std.testing.expectEqual(types.TurnPhase.generating, app.stream.phase);
    try std.testing.expectEqual(@as(u64, 1), app.stream.phase_step_id);
    try std.testing.expectEqual(@as(usize, 0), app.stream.command_count);
    try std.testing.expectEqual(@as(u64, 0), app.stream.token_progress.output_tokens);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"authoritative_started":{"id":{"turn_id":8,"call_id":"read-1"},"reconciles_provisional_call_id":null,"tool_name":"read_file","activity_kind":"read","arguments_json":"{\"path\":\"main.zig\"}"}}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"authoritative_started":{"id":{"turn_id":8,"call_id":"write-1"},"reconciles_provisional_call_id":null,"tool_name":"write_file","activity_kind":"write","arguments_json":"{}"}}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"authoritative_started":{"id":{"turn_id":8,"call_id":"child-1"},"reconciles_provisional_call_id":null,"tool_name":"subagent","activity_kind":"subagent","arguments_json":"{}"}}}}}
    );
    try std.testing.expectEqual(@as(usize, 1), app.stream.read_count);
    try std.testing.expectEqual(@as(usize, 1), app.stream.write_count);
    try std.testing.expectEqual(@as(usize, 1), app.stream.subagent_count);
    try std.testing.expectEqual(types.ToolActivityKind.subagent, app.shell.toolActivityRecord(.{ .turn_id = 108, .call_id = "child-1" }).?.activity_kind);
    // An old daemon has no capability and continues through the ACP fallback.
    app.remote.native_presentation = false;
    try app.frame(
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"legacy","name":"read_file","title":"Reading legacy","kind":"read","rawInput":{}}}}
    );
    try std.testing.expectEqual(types.ToolActivityKind.read, app.shell.toolActivityRecord(.{ .turn_id = app.remote.turn_id, .call_id = "legacy" }).?.activity_kind);
    // Structured append transfers ownership only on success; rejection must not
    // leak the bridge's cloned payload (checked by std.testing.allocator).
    app.reject_semantic = true;
    try std.testing.expectError(error.TestAppendRejected, app.apply(
        \\{"assistant_presentation":{"table":{"rows":[{"cells":["heading"]}],"alignments":["left"],"column_count":1}}}
    ));
    try std.testing.expectError(error.TestAppendRejected, app.apply(
        \\{"assistant_presentation":{"code_block":{"language":"zig","code":"const x = 1;"}}}
    ));
}

test "parseToggle accepts the words a person types for a boolean option" {
    try std.testing.expect(parseToggle("on").?);
    try std.testing.expect(parseToggle("ON").?);
    try std.testing.expect(parseToggle("true").?);
    try std.testing.expect(parseToggle("1").?);
    try std.testing.expect(!parseToggle("off").?);
    try std.testing.expect(!parseToggle("False").?);
    try std.testing.expect(!parseToggle("0").?);
    try std.testing.expect(parseToggle("maybe") == null);
    try std.testing.expect(parseToggle("") == null);
}

test "optionIdForCommand maps only the option commands" {
    try std.testing.expectEqualStrings("effort", optionIdForCommand("/effort").?);
    try std.testing.expectEqualStrings("fast", optionIdForCommand("/fast").?);
    try std.testing.expectEqualStrings("ultrafast", optionIdForCommand("/ultrafast").?);
    try std.testing.expect(optionIdForCommand("/copy") == null);
    try std.testing.expect(optionIdForCommand("/effortx") == null);
}
