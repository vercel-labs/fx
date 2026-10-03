//! The children of one fx: up to ten named fx instances, each a full TUI in
//! its own hidden sub-engine terminal. The subagent tool calls this runtime.
//!
//! Every call is safe from any thread, so tool calls can run in parallel.
//! One lock guards the table and the children's screens. The pool's reader
//! thread takes it to apply each child's output and reports; starting a
//! terminal, typing and the polls of `wait` happen outside it.
//!
//! A message is typed as a paste. fx refuses a paste followed by more input
//! in the same read, so the runtime presses Enter only after the child
//! reports that the paste reached its composer. A child waiting on a prompt
//! never reports that, so a message cannot answer the prompt.
//!
//! Do not move a Runtime once a child was launched: the pool calls back into
//! it.

const std = @import("std");
const sub_engine = @import("sub_engine");
const core = @import("control_core.zig");

pub const max_name_bytes = core.max_name_bytes;
const labels_mod = @import("labels.zig");
const permission_request = @import("../permissions/permission_request.zig");
const types = @import("../shared/types.zig");
const engine = @import("../terminal/engine.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const host_target = @import("../hosts/target.zig");

const Allocator = std.mem.Allocator;

pub const max_children = core.max_children;
pub const validName = core.validName;

/// Whether this fx offers the subagent tool with sub-engine children: the
/// `--subagents-v2` flag, or FX_SUBAGENTS_V2 set to `1` or `true`. Never in
/// a child, so children cannot launch children, and never in wasm, which has
/// no terminals.
pub fn enabled(flag: bool) bool {
    if (comptime host_target.is_wasm) return false;
    if (isChild()) return false;
    if (flag) return true;
    const value = io_mod.getenv("FX_SUBAGENTS_V2") orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

/// The runtime `app` holds in its `child_agents` field, if it has one.
pub inline fn ofApp(app: anytype) ?*Runtime {
    // The wasm builds have no child terminals. A null known at compile
    // time keeps every caller's child-runtime branch, and with it socket
    // calls the wasm hosts do not provide, out of those builds.
    if (comptime host_target.is_wasm) return null;
    const App = @typeInfo(@TypeOf(app)).pointer.child;
    if (comptime !@hasField(App, "child_agents")) return null;
    return if (app.child_agents) |*children| children else null;
}

/// Whether this fx runs in a terminal of another fx's sub-engine. A stale
/// report entry, such as one a child's shell inherits, does not count.
pub fn isChild() bool {
    if (comptime host_target.is_wasm) return false;
    const value = io_mod.getenv(sub_engine.report_env_name) orelse return false;
    return sub_engine.inheritedReportFd(value) != null;
}

const poll_ms: u32 = 25;

pub const Config = struct {
    /// The fx binary children run.
    program: []const u8,
    cols: u16 = 120,
    rows: u16 = 40,
    /// How long a child may take to start its TUI.
    start_timeout_ms: u32 = 30_000,
    /// How long a child may take to take a paste, and then to report the
    /// message.
    delivery_timeout_ms: u32 = 10_000,
    /// A user answers the children's prompts in this fx, so `wait` keeps
    /// waiting through a blocked child. Without one, a blocked child counts
    /// as settled, since nothing would unblock it.
    prompts_reach_user: bool = false,
};

/// What a child runs with. Empty values leave the child's own default.
pub const Settings = struct {
    /// Passed as `--provider`, `--model` and `--effort`, which apply to that
    /// run only.
    provider: []const u8 = "",
    model: []const u8 = "",
    effort: []const u8 = "",
    /// Passed as FX_PERMISSION_MODE.
    permission_mode: []const u8 = "",
    /// The folder the child runs in. Null keeps this process's.
    cwd: ?[]const u8 = null,
    /// This fx's root-user context. The child gets it before each message
    /// and reviews its own actions against it, since its prompts come from
    /// this fx's model.
    root_context: []const u8 = "",
};

/// What one subagent tool call gets from its host.
pub const Host = struct {
    runtime: *Runtime,
    /// The parent's current settings, which a child inherits.
    settings: Settings,
};

pub const Delivery = enum {
    /// The child reported the message.
    delivered,
    /// Enter was pressed but the child has not reported the message yet.
    pending,
    /// The child never took the paste, for example because a prompt is
    /// open. Nothing was submitted.
    not_delivered,
    /// The child exited.
    exited,
};

/// A child as the live view holds it. It goes stale once the child is
/// stopped, even if a new child takes its name.
pub const Handle = struct {
    slot: usize,
    id: sub_engine.Id,
};

/// A copy of a child's screen, and the version it had.
pub const Screen = struct {
    grid: engine.Grid,
    version: u64,
};

pub const Status = struct {
    name: []u8,
    /// Null only for a child stopped while the call ran.
    handle: ?Handle = null,
    state: labels_mod.State,
    blocked_reason: ?labels_mod.BlockedReason,
    exit: ?sub_engine.Exit,
    session_id: ?[]u8,
    turns_ended: u64,
    /// Exited, or reported everything typed into it and idle, or blocked
    /// where no user answers its prompts.
    settled: bool,
    /// Stopped while the call ran.
    stopped: bool = false,

    pub fn deinit(self: Status, gpa: Allocator) void {
        gpa.free(self.name);
        if (self.session_id) |id| gpa.free(id);
    }
};

pub fn freeStatuses(gpa: Allocator, statuses: []Status) void {
    for (statuses) |status| status.deinit(gpa);
    gpa.free(statuses);
}

pub const Launched = struct {
    delivery: Delivery,
    status: Status,
};

pub const Waited = struct {
    timed_out: bool,
    children: []Status,
};

pub const Read = union(enum) {
    final: struct { text: ?[]u8, truncated: bool, turns_ended: u64 },
    messages: [][]u8,
    screen: []u8,

    pub fn deinit(self: Read, gpa: Allocator) void {
        switch (self) {
            .final => |final| if (final.text) |text| gpa.free(text),
            .messages => |items| {
                for (items) |item| gpa.free(item);
                gpa.free(items);
            },
            .screen => |text| gpa.free(text),
        }
    }
};

pub const Stopped = struct {
    session_id: ?[]u8,
    exit: sub_engine.Exit,

    pub fn deinit(self: Stopped, gpa: Allocator) void {
        if (self.session_id) |id| gpa.free(id);
    }
};

/// A child's question batch for main to show. `id` names it for
/// `answerQuestions`.
pub const PendingQuestions = struct {
    id: u64,
    arena: std.heap.ArenaAllocator,
    /// The asking child's name, for main's question screen.
    child_name: []const u8,
    entries: []const types.QuestionBatchEntry,

    pub fn deinit(self: *PendingQuestions) void {
        self.arena.deinit();
    }
};

pub const AnswerError = error{
    /// The prompt closed, was answered, or its child is gone.
    Stale,
    /// The child has not read earlier answers; nothing was sent.
    Busy,
    AnswerTooLong,
    OutOfMemory,
};

/// Ids main gives child prompts. Main's own requests count from 1, so the
/// two never meet.
const first_prompt_id: u64 = 1 << 62;

pub const LaunchError = core.ReserveError || error{
    /// Text with control characters other than tab and newline.
    UnsupportedText,
    StartFailed,
    StartTimedOut,
    Cancelled,
    OutOfMemory,
};

pub const SendError = error{
    NotFound,
    Exited,
    /// The child shows a permission or question prompt, which only the user
    /// answers.
    Blocked,
    UnsupportedText,
    Cancelled,
    OutOfMemory,
};

pub const Runtime = struct {
    gpa: Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    config: Config,
    lock: std.Io.Mutex = .init,
    table: core.Table = .{},
    screens: [max_children]?engine.Grid = [_]?engine.Grid{null} ** max_children,
    /// Bumped whenever a screen changes, so the live view repaints only then.
    versions: [max_children]u64 = [_]u64{0} ** max_children,
    pool: ?*sub_engine.Pool = null,
    /// Each child's open prompt as main knows it.
    prompts: [max_children]PromptSlot = [_]PromptSlot{.{}} ** max_children,
    next_prompt_id: u64 = first_prompt_id,
    /// The child question batch main shows, by its prompt id.
    presented_questions: ?u64 = null,

    const PromptSlot = struct {
        /// The child's number for the prompt; 0 when none is open.
        number: u64 = 0,
        id: u64 = 0,
        answered: bool = false,
    };

    /// Copies `config`. Call `deinit` when done.
    pub fn init(gpa: Allocator, io: std.Io, config: Config) Allocator.Error!Runtime {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var owned = config;
        owned.program = try a.dupe(u8, config.program);
        return .{ .gpa = gpa, .io = io, .arena = arena, .config = owned };
    }

    /// Stops every child. Their sessions stay saved.
    pub fn deinit(self: *Runtime) void {
        if (self.pool) |pool| pool.destroy();
        for (&self.screens) |*slot| {
            if (slot.*) |*grid| grid.deinit();
            slot.* = null;
        }
        self.table.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Starts a child named `name` and types `task` into it once its TUI is
    /// up.
    pub fn launch(
        self: *Runtime,
        gpa: Allocator,
        name: []const u8,
        task: []const u8,
        settings: Settings,
        cancel: ?*std.atomic.Value(bool),
    ) LaunchError!Launched {
        if (!supportedText(task)) return error.UnsupportedText;
        // The terminal starts under the lock: its child may report before
        // `open` returns, and the reports must find its id.
        const slot, const id = blk: {
            self.lockTable();
            defer self.unlockTable();
            if (self.pool == null) {
                self.pool = sub_engine.Pool.create(self.gpa, self.io, .{
                    .ctx = self,
                    .output = onOutput,
                    .report = onReport,
                    .exited = onExited,
                }) catch return error.StartFailed;
            }
            const slot = try self.table.reserve(name);
            self.screens[slot] = engine.Grid.init(self.gpa, self.config.cols, self.config.rows) catch {
                self.table.free(self.gpa, slot);
                return error.OutOfMemory;
            };
            const id = self.open(settings) catch |err| {
                self.freeLocked(slot);
                return err;
            };
            self.table.opened(slot, id);
            break :blk .{ slot, id };
        };

        var waited: u32 = 0;
        while (true) : (waited += poll_ms) {
            {
                self.lockTable();
                defer self.unlockTable();
                if (self.table.get(slot).started()) {
                    self.table.markReady(slot);
                    break;
                }
            }
            if (cancelled(cancel) or waited >= self.config.start_timeout_ms) {
                debug_trace.logf("child_agents", "launch abandoned name={s} cancelled={}", .{ name, cancelled(cancel) });
                _ = self.pool.?.close(id) catch {};
                self.release(slot);
                return if (cancelled(cancel)) error.Cancelled else error.StartTimedOut;
            }
            sleepMs(poll_ms);
        }

        self.sendContext(id, settings.root_context);
        const delivery = self.deliver(slot, id, task, cancel) catch |err| switch (err) {
            error.NotFound => Delivery.exited,
            error.Cancelled => {
                // A cancelled launch leaves no child behind. A parallel stop
                // may have closed it already.
                if (self.stop(gpa, name)) |stopped| stopped.deinit(gpa) else |_| {}
                return error.Cancelled;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        self.lockTable();
        defer self.unlockTable();
        // A parallel stop may have closed the child meanwhile.
        const status = if (self.childAt(slot, id)) |child| try statusOf(self, gpa, child) else try stoppedStatus(gpa, name);
        return .{ .delivery = delivery, .status = status };
    }

    /// Types `message` into the ready child named `name`, after
    /// `root_context` (see `Settings.root_context`).
    pub fn send(
        self: *Runtime,
        name: []const u8,
        message: []const u8,
        root_context: []const u8,
        cancel: ?*std.atomic.Value(bool),
    ) SendError!Delivery {
        if (!supportedText(message)) return error.UnsupportedText;
        const slot, const id = blk: {
            self.lockTable();
            defer self.unlockTable();
            const slot = self.table.find(name) orelse return error.NotFound;
            const child = self.table.get(slot);
            if (child.phase != .ready) return error.NotFound;
            if (child.exit != null) return error.Exited;
            if (child.labels.state == .blocked) return error.Blocked;
            break :blk .{ slot, child.id.? };
        };
        self.sendContext(id, root_context);
        return self.deliver(slot, id, message, cancel) catch |err| switch (err) {
            error.NotFound => error.NotFound,
            error.Cancelled => error.Cancelled,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// Waits until any of `names`, or of every child when `names` is empty,
    /// settles or was stopped. Returns their statuses.
    pub fn wait(
        self: *Runtime,
        gpa: Allocator,
        names: []const []const u8,
        timeout_ms: u32,
        cancel: ?*std.atomic.Value(bool),
    ) error{ NotFound, Cancelled, OutOfMemory }!Waited {
        const Target = struct {
            slot: usize,
            id: ?sub_engine.Id,
            /// A copy: the table may reuse the slot once the child stops.
            name_buf: [core.max_name_bytes]u8 = undefined,
            name_len: usize = 0,

            fn of(slot: usize, child: *const core.Child) @This() {
                var target: @This() = .{ .slot = slot, .id = child.id, .name_len = child.name_len };
                @memcpy(target.name_buf[0..child.name_len], child.name());
                return target;
            }

            fn name(target: *const @This()) []const u8 {
                return target.name_buf[0..target.name_len];
            }
        };
        var targets: std.ArrayList(Target) = .empty;
        defer targets.deinit(gpa);
        {
            self.lockTable();
            defer self.unlockTable();
            if (names.len == 0) {
                for (&self.table.slots, 0..) |*slot, index| {
                    const child = &(slot.* orelse continue);
                    try targets.append(gpa, .of(index, child));
                }
            } else for (names) |name| {
                const slot = self.table.find(name) orelse return error.NotFound;
                try targets.append(gpa, .of(slot, self.table.get(slot)));
            }
        }
        if (targets.items.len == 0) return error.NotFound;

        var waited: u32 = 0;
        while (true) : (waited += poll_ms) {
            {
                self.lockTable();
                defer self.unlockTable();
                var any = false;
                for (targets.items) |*target| {
                    const child = self.childAt(target.slot, target.id) orelse {
                        any = true;
                        continue;
                    };
                    any = any or (child.phase == .ready and child.settled(!self.config.prompts_reach_user));
                }
                const timed_out = waited >= timeout_ms;
                if (any or timed_out) {
                    var statuses: std.ArrayList(Status) = .empty;
                    errdefer {
                        for (statuses.items) |status| status.deinit(gpa);
                        statuses.deinit(gpa);
                    }
                    for (targets.items) |*target| {
                        const status = if (self.childAt(target.slot, target.id)) |child|
                            try statusOf(self, gpa, child)
                        else
                            try stoppedStatus(gpa, target.name());
                        try statuses.append(gpa, status);
                    }
                    return .{ .timed_out = !any, .children = try statuses.toOwnedSlice(gpa) };
                }
            }
            if (cancelled(cancel)) return error.Cancelled;
            sleepMs(poll_ms);
        }
    }

    pub const ReadKind = enum { final, messages, screen };

    pub fn read(self: *Runtime, gpa: Allocator, name: []const u8, kind: ReadKind) error{ NotFound, OutOfMemory }!Read {
        self.lockTable();
        defer self.unlockTable();
        const slot = self.table.find(name) orelse return error.NotFound;
        const child = self.table.get(slot);
        switch (kind) {
            .final => return .{ .final = .{
                .text = if (child.labels.final) |text| try gpa.dupe(u8, text) else null,
                .truncated = child.labels.final_truncated,
                .turns_ended = child.labels.turns_ended,
            } },
            .messages => {
                const items = try gpa.alloc([]u8, child.labels.messages.items.len);
                var filled: usize = 0;
                errdefer {
                    for (items[0..filled]) |item| gpa.free(item);
                    gpa.free(items);
                }
                for (child.labels.messages.items, items) |message, *item| {
                    item.* = try gpa.dupe(u8, message.text);
                    filled += 1;
                }
                return .{ .messages = items };
            },
            .screen => return .{ .screen = try screenText(gpa, &self.screens[slot].?) },
        }
    }

    pub fn list(self: *Runtime, gpa: Allocator) Allocator.Error![]Status {
        self.lockTable();
        defer self.unlockTable();
        var statuses: std.ArrayList(Status) = .empty;
        errdefer {
            for (statuses.items) |status| status.deinit(gpa);
            statuses.deinit(gpa);
        }
        for (&self.table.slots, 0..) |*slot, index| {
            const child = &(slot.* orelse continue);
            var status = try statusOf(self, gpa, child);
            if (child.id) |id| status.handle = .{ .slot = index, .id = id };
            statuses.append(gpa, status) catch |err| {
                status.deinit(gpa);
                return err;
            };
        }
        return statuses.toOwnedSlice(gpa);
    }

    /// A copy of the child's screen if it changed since version `after`,
    /// else null; always a copy when `after` is null. `error.Gone` once the
    /// child exited or was stopped.
    pub fn screen(self: *Runtime, gpa: Allocator, handle: Handle, after: ?u64) error{ Gone, OutOfMemory }!?Screen {
        self.lockTable();
        defer self.unlockTable();
        const child = self.childAt(handle.slot, handle.id) orelse return error.Gone;
        if (child.exit != null) return error.Gone;
        const grid = &(self.screens[handle.slot] orelse return error.Gone);
        const version = self.versions[handle.slot];
        if (after == version) return null;
        var copy = try grid.clone(gpa);
        // `clone` copies the cells only; the view also needs the insertion
        // point.
        copy.cursor_row = grid.cursor_row;
        copy.cursor_col = grid.cursor_col;
        copy.cursor_visible = grid.cursor_visible;
        return .{ .grid = copy, .version = version };
    }

    /// Types the user's raw keys into the child, as a terminal would. The
    /// main agent's messages may arrive in between. `QueueFull` means the
    /// child stopped reading its input; the keys are dropped.
    pub fn keys(self: *Runtime, handle: Handle, bytes: []const u8) error{ Gone, QueueFull, OutOfMemory }!void {
        {
            self.lockTable();
            defer self.unlockTable();
            const child = self.childAt(handle.slot, handle.id) orelse return error.Gone;
            if (child.exit != null) return error.Gone;
        }
        self.pool.?.write(handle.id, bytes) catch |err| return switch (err) {
            error.NotFound, error.Ended, error.WriteFailed => error.Gone,
            error.QueueFull, error.OutOfMemory => |e| e,
        };
    }

    /// How many children other than the one `except` names wait on a
    /// permission or question prompt.
    pub fn blockedOthers(self: *Runtime, except: Handle) usize {
        self.lockTable();
        defer self.unlockTable();
        var count: usize = 0;
        for (&self.table.slots, 0..) |*slot, index| {
            const child = &(slot.* orelse continue);
            if (index == except.slot and std.meta.eql(child.id, except.id)) continue;
            if (child.exit == null and child.labels.state == .blocked) count += 1;
        }
        return count;
    }

    /// Resizes every child's terminal and screen. Children launched later
    /// start at this size.
    pub fn resize(self: *Runtime, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        self.lockTable();
        defer self.unlockTable();
        if (cols == self.config.cols and rows == self.config.rows) return;
        self.config.cols = cols;
        self.config.rows = rows;
        for (&self.screens, &self.versions) |*slot, *version| {
            const grid = &(slot.* orelse continue);
            grid.resize(cols, rows) catch |err| {
                debug_trace.logf("child_agents", "screen resize failed cols={d} rows={d} err={s}", .{ cols, rows, @errorName(err) });
            };
            version.* +%= 1;
        }
        const pool = self.pool orelse return;
        pool.resize(cols, rows) catch |err| {
            debug_trace.logf("child_agents", "terminal resize failed cols={d} rows={d} err={s}", .{ cols, rows, @errorName(err) });
        };
    }

    /// Closes the child named `name` and frees its name. Its session stays
    /// saved and can be resumed.
    pub fn stop(self: *Runtime, gpa: Allocator, name: []const u8) error{ NotFound, OutOfMemory }!Stopped {
        const slot, const id = blk: {
            self.lockTable();
            defer self.unlockTable();
            const slot = try self.table.markStopping(name);
            break :blk .{ slot, self.table.get(slot).id.? };
        };
        const report = self.pool.?.close(id) catch |err| blk: {
            debug_trace.logf("child_agents", "stop name={s} close failed err={s}", .{ name, @errorName(err) });
            break :blk sub_engine.CloseReport{ .exit = .{ .signal = 9 }, .dropped_bytes = 0, .dropped_report_lines = 0 };
        };
        if (report.dropped_report_lines > 0) {
            debug_trace.logf("child_agents", "stop name={s} dropped_report_lines={d}", .{ name, report.dropped_report_lines });
        }
        self.lockTable();
        defer self.unlockTable();
        const child = self.table.get(slot);
        const session_id = if (child.labels.session_id) |session| gpa.dupe(u8, session) catch null else null;
        self.freeLocked(slot);
        return .{ .session_id = session_id, .exit = report.exit };
    }

    /// Types `text` into the child in `slot` that has terminal `id`: claims
    /// it for typing, pastes, waits until the paste reached the composer,
    /// presses Enter and waits until the message is reported.
    fn deliver(
        self: *Runtime,
        slot: usize,
        id: sub_engine.Id,
        text: []const u8,
        cancel: ?*std.atomic.Value(bool),
    ) error{ NotFound, Cancelled, OutOfMemory }!Delivery {
        var pastes: u64 = 0;
        var messages: u64 = 0;
        while (true) {
            {
                self.lockTable();
                defer self.unlockTable();
                const child = self.childAt(slot, id) orelse return error.NotFound;
                if (child.phase == .stopping) return error.NotFound;
                if (child.exit != null) return .exited;
                if (self.table.beginTyping(slot)) {
                    pastes = child.labels.pastes_total;
                    messages = child.labels.messages_total;
                    break;
                }
            }
            if (cancelled(cancel)) return error.Cancelled;
            sleepMs(poll_ms);
        }
        defer {
            self.lockTable();
            if (self.childAt(slot, id) != null) self.table.endTyping(slot);
            self.unlockTable();
        }

        const paste = try std.mem.concat(self.gpa, u8, &.{ "\x1b[200~", text, "\x1b[201~" });
        defer self.gpa.free(paste);
        self.pool.?.write(id, paste) catch return .exited;
        const pasted = self.waitCount(slot, id, .pastes, pastes, cancel) catch |err| {
            self.clearDraft(id);
            return err;
        };
        switch (pasted) {
            .reached => {},
            .exited => return .exited,
            .timed_out => {
                self.clearDraft(id);
                return .not_delivered;
            },
        }

        {
            self.lockTable();
            defer self.unlockTable();
            if (self.childAt(slot, id) == null) return error.NotFound;
            self.table.typedOne(slot);
        }
        self.pool.?.write(id, "\r") catch return .exited;
        return switch (try self.waitCount(slot, id, .messages, messages, cancel)) {
            .reached => .delivered,
            .exited => .exited,
            .timed_out => .pending,
        };
    }

    /// Clears the child's draft with Ctrl+U, after a paste whose delivery
    /// failed. The child reads input in order, so this also clears a paste
    /// that lands late, and the next message does not run into it.
    fn clearDraft(self: *Runtime, id: sub_engine.Id) void {
        self.pool.?.write(id, "\x15") catch {};
    }

    const Counter = enum { pastes, messages };

    /// Polls until the child's `counter` passes `from`.
    fn waitCount(
        self: *Runtime,
        slot: usize,
        id: sub_engine.Id,
        counter: Counter,
        from: u64,
        cancel: ?*std.atomic.Value(bool),
    ) error{ NotFound, Cancelled }!enum { reached, exited, timed_out } {
        var waited: u32 = 0;
        while (waited < self.config.delivery_timeout_ms) : (waited += poll_ms) {
            {
                self.lockTable();
                defer self.unlockTable();
                const child = self.childAt(slot, id) orelse return error.NotFound;
                const value = switch (counter) {
                    .pastes => child.labels.pastes_total,
                    .messages => child.labels.messages_total,
                };
                if (value > from) return .reached;
                if (child.exit != null) return .exited;
            }
            if (cancelled(cancel)) return error.Cancelled;
            sleepMs(poll_ms);
        }
        return .timed_out;
    }

    fn open(self: *Runtime, settings: Settings) error{ StartFailed, OutOfMemory }!sub_engine.Id {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena.allocator(), self.config.program);
        for ([_][2][]const u8{
            .{ "--provider", settings.provider },
            .{ "--model", settings.model },
            .{ "--effort", settings.effort },
        }) |flag| {
            if (flag[1].len > 0) try argv.appendSlice(arena.allocator(), &flag);
        }
        return self.pool.?.open(.{
            .argv = argv.items,
            .env = try childEnv(arena.allocator(), settings.permission_mode),
            .cwd = settings.cwd,
            .cols = self.config.cols,
            .rows = self.config.rows,
        }) catch |err| {
            debug_trace.logf("child_agents", "launch failed program={s} err={s}", .{ self.config.program, @errorName(err) });
            return if (err == error.OutOfMemory) error.OutOfMemory else error.StartFailed;
        };
    }

    /// The child in `slot`, if it still has terminal `id`.
    fn childAt(self: *Runtime, slot: usize, id: ?sub_engine.Id) ?*core.Child {
        const child = &(self.table.slots[slot] orelse return null);
        if (!std.meta.eql(child.id, id)) return null;
        return child;
    }

    fn release(self: *Runtime, slot: usize) void {
        self.lockTable();
        defer self.unlockTable();
        self.freeLocked(slot);
    }

    fn freeLocked(self: *Runtime, slot: usize) void {
        if (self.screens[slot]) |*grid| grid.deinit();
        self.screens[slot] = null;
        self.prompts[slot] = .{};
        self.table.free(self.gpa, slot);
    }

    fn lockTable(self: *Runtime) void {
        self.lock.lockUncancelable(self.io);
    }

    fn unlockTable(self: *Runtime) void {
        self.lock.unlock(self.io);
    }

    fn onOutput(ctx: *anyopaque, id: sub_engine.Id, bytes: []const u8) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        var replies: std.ArrayList(u8) = .empty;
        defer replies.deinit(self.gpa);
        {
            self.lockTable();
            defer self.unlockTable();
            const slot = self.table.findId(id) orelse return;
            const grid = &(self.screens[slot] orelse return);
            var result = grid.feedMode(bytes, .native_live) catch |err| {
                debug_trace.logf("child_agents", "screen dropped output bytes={d} err={s}", .{ bytes.len, @errorName(err) });
                return;
            };
            defer result.deinit(self.gpa);
            self.versions[slot] +%= 1;
            for (result.replies.items) |reply| replies.appendSlice(self.gpa, reply.bytes) catch return;
        }
        // The pool lets the sink write; terminal queries need their answers.
        if (replies.items.len > 0) self.pool.?.write(id, replies.items) catch {};
    }

    fn onReport(ctx: *anyopaque, id: sub_engine.Id, line: []const u8) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.lockTable();
        defer self.unlockTable();
        self.table.report(self.gpa, id, line) catch |err| {
            debug_trace.logf("child_agents", "report ignored bytes={d} err={s}", .{ line.len, @errorName(err) });
        };
        const slot = self.table.findId(id) orelse return;
        const tracked = &self.prompts[slot];
        const prompt = self.table.get(slot).labels.prompt orelse {
            tracked.* = .{};
            return;
        };
        if (tracked.number == prompt.number) return;
        tracked.* = .{ .number = prompt.number, .id = self.next_prompt_id };
        self.next_prompt_id += 1;
    }

    /// The slot of the oldest prompt main has not answered, among children
    /// still running. Called with the lock held.
    fn oldestPromptLocked(self: *Runtime) ?usize {
        var oldest: ?usize = null;
        for (&self.table.slots, 0..) |*entry, slot| {
            const child = &(entry.* orelse continue);
            const tracked = self.prompts[slot];
            if (child.phase != .ready or child.exit != null or child.labels.prompt == null) continue;
            if (tracked.number == 0 or tracked.answered) continue;
            if (oldest == null or tracked.id < self.prompts[oldest.?].id) oldest = slot;
        }
        return oldest;
    }

    /// The oldest child prompt, when it asks for permission: the child's
    /// request with main's id for it and the child as its origin. Main shows
    /// one child prompt at a time.
    pub fn pendingPermission(self: *Runtime, gpa: Allocator) Allocator.Error!?permission_request.OwnedPermissionRequest {
        self.lockTable();
        defer self.unlockTable();
        const slot = self.oldestPromptLocked() orelse return null;
        const child = self.table.get(slot);
        const owned = switch (child.labels.prompt.?.body) {
            .permission => |*request| request,
            .questions => return null,
        };
        var request = owned.view();
        request.id = self.prompts[slot].id;
        request.origin = .{ .subagent = child.name() };
        return permission_request.OwnedPermissionRequest.dupe(gpa, request) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => blk: {
                debug_trace.logf("child_agents", "permission prompt not shown name={s} err={s}", .{ child.name(), @errorName(err) });
                break :blk null;
            },
        };
    }

    /// The oldest child prompt, when it asks questions. Main remembers it as
    /// the batch it shows.
    pub fn presentQuestions(self: *Runtime, gpa: Allocator) Allocator.Error!?PendingQuestions {
        self.lockTable();
        defer self.unlockTable();
        const slot = self.oldestPromptLocked() orelse return null;
        const child = self.table.get(slot);
        const entries = switch (child.labels.prompt.?.body) {
            .questions => |entries| entries,
            .permission => return null,
        };
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const copy = try copyQuestions(arena.allocator(), entries);
        const child_name = try arena.allocator().dupe(u8, child.name());
        self.presented_questions = self.prompts[slot].id;
        return .{ .id = self.prompts[slot].id, .arena = arena, .child_name = child_name, .entries = copy };
    }

    /// The id of the child question batch main shows, if any. It may have
    /// closed since: check with `ownsPrompt`.
    pub fn presentedQuestions(self: *Runtime) ?u64 {
        self.lockTable();
        defer self.unlockTable();
        return self.presented_questions;
    }

    /// Main no longer shows the presented batch; it stays pending.
    pub fn dropPresentedQuestions(self: *Runtime) void {
        self.lockTable();
        defer self.unlockTable();
        self.presented_questions = null;
    }

    /// Whether `id` names a child prompt main still owes an answer.
    pub fn ownsPrompt(self: *Runtime, id: u64) bool {
        self.lockTable();
        defer self.unlockTable();
        return self.promptSlotLocked(id) != null;
    }

    pub fn answerPermission(self: *Runtime, id: u64, decision: labels_mod.Decision, feedback: ?[]const u8) AnswerError!void {
        return self.answer(id, .{ .permission = .{ .decision = decision, .feedback = feedback } });
    }

    /// Answers the batch main shows; null cancels it.
    pub fn answerQuestions(self: *Runtime, answers: ?[]const []const u8) AnswerError!void {
        const id = blk: {
            self.lockTable();
            defer self.unlockTable();
            const id = self.presented_questions orelse return error.Stale;
            self.presented_questions = null;
            break :blk id;
        };
        return self.answer(id, .{ .questions = answers });
    }

    /// Sends the user's answer to child prompt `id` and stops showing it.
    /// Sends `context` to the child with terminal `id` ahead of a message,
    /// so the message is reviewed against it. A child without it treats its
    /// prompts as instructions from this fx's model with no user context.
    fn sendContext(self: *Runtime, id: sub_engine.Id, context: []const u8) void {
        if (context.len == 0) return;
        const line = labels_mod.encodeContext(self.gpa, context, sub_engine.max_reply_line) catch |err| {
            return debug_trace.logf("child_agents", "context not sent err={s}", .{@errorName(err)});
        };
        defer self.gpa.free(line);
        self.pool.?.reply(id, line) catch |err| {
            debug_trace.logf("child_agents", "context not sent err={s}", .{@errorName(err)});
        };
    }

    fn answer(self: *Runtime, id: u64, reply: @FieldType(labels_mod.Answer, "reply")) AnswerError!void {
        self.lockTable();
        defer self.unlockTable();
        const slot = self.promptSlotLocked(id) orelse return error.Stale;
        const child = self.table.get(slot);
        const line = try labels_mod.encodeAnswer(self.gpa, .{ .prompt = self.prompts[slot].number, .reply = reply }, sub_engine.max_reply_line);
        defer self.gpa.free(line);
        // The pool's reader never holds its table lock while it calls back
        // into this runtime, so taking it here cannot deadlock.
        self.pool.?.reply(child.id.?, line) catch |err| {
            debug_trace.logf("child_agents", "answer not sent name={s} err={s}", .{ child.name(), @errorName(err) });
            return if (err == error.Busy) error.Busy else error.Stale;
        };
        self.prompts[slot].answered = true;
        debug_trace.logf("child_agents", "answer sent name={s} prompt={d}", .{ child.name(), self.prompts[slot].number });
    }

    /// The slot whose open, unanswered prompt main calls `id`. Called with
    /// the lock held.
    fn promptSlotLocked(self: *Runtime, id: u64) ?usize {
        for (self.prompts, 0..) |tracked, slot| {
            if (tracked.id != id or tracked.number == 0 or tracked.answered) continue;
            const child = &(self.table.slots[slot] orelse return null);
            if (child.phase != .ready or child.exit != null) return null;
            return slot;
        }
        return null;
    }

    fn onExited(ctx: *anyopaque, id: sub_engine.Id, exit: sub_engine.Exit) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        self.lockTable();
        defer self.unlockTable();
        self.table.exited(id, exit);
    }
};

/// fx's own environment without the variables a child's settings replace,
/// plus its permission mode.
fn childEnv(arena: Allocator, permission_mode: []const u8) Allocator.Error![]const []const u8 {
    const replaced = [_][]const u8{ "FX_PROVIDER", "FX_MODEL", "FX_EFFORT", "FX_PERMISSION_MODE" };
    var env: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    outer: while (std.c.environ[index]) |raw| : (index += 1) {
        const entry = std.mem.span(raw);
        for (replaced) |name| {
            if (entry.len > name.len and entry[name.len] == '=' and std.mem.startsWith(u8, entry, name)) continue :outer;
        }
        try env.append(arena, entry);
    }
    if (permission_mode.len > 0)
        try env.append(arena, try std.fmt.allocPrint(arena, "FX_PERMISSION_MODE={s}", .{permission_mode}));
    return env.items;
}

fn copyQuestions(arena: Allocator, entries: []const types.QuestionBatchEntry) Allocator.Error![]const types.QuestionBatchEntry {
    const copy = try arena.alloc(types.QuestionBatchEntry, entries.len);
    for (entries, copy) |entry, *out| {
        const options = try arena.alloc(types.QuestionOption, entry.options.len);
        for (entry.options, options) |option, *option_out| option_out.* = .{
            .label = try arena.dupe(u8, option.label),
            .description = if (option.description) |text| try arena.dupe(u8, text) else null,
        };
        out.* = .{ .question = try arena.dupe(u8, entry.question), .options = options, .submission = entry.submission };
    }
    return copy;
}

/// Text a child can take as a paste: no control characters but tab, newline
/// and carriage return. An escape could end the paste early.
fn supportedText(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') return false;
        if (byte == 0x7f) return false;
    }
    return true;
}

fn statusOf(self: *const Runtime, gpa: Allocator, child: *const core.Child) Allocator.Error!Status {
    const name = try gpa.dupe(u8, child.name());
    errdefer gpa.free(name);
    return .{
        .name = name,
        .state = child.labels.state,
        .blocked_reason = child.labels.blocked_reason,
        .exit = child.exit,
        .session_id = if (child.labels.session_id) |id| try gpa.dupe(u8, id) else null,
        .turns_ended = child.labels.turns_ended,
        .settled = child.settled(!self.config.prompts_reach_user),
    };
}

fn stoppedStatus(gpa: Allocator, name: []const u8) Allocator.Error!Status {
    return .{
        .name = try gpa.dupe(u8, name),
        .state = .idle,
        .blocked_reason = null,
        .exit = null,
        .session_id = null,
        .turns_ended = 0,
        .settled = true,
        .stopped = true,
    };
}

/// The screen's rows as text, trailing blank rows dropped.
fn screenText(gpa: Allocator, grid: *const engine.Grid) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    var kept: usize = 0;
    var row: u16 = 1;
    while (row <= grid.rows) : (row += 1) {
        line.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &line);
        try out.appendSlice(gpa, line.items);
        if (line.items.len > 0) kept = out.items.len;
        try out.append(gpa, '\n');
    }
    out.shrinkRetainingCapacity(kept);
    return out.toOwnedSlice(gpa);
}

fn cancelled(cancel: ?*std.atomic.Value(bool)) bool {
    const flag = cancel orelse return false;
    return flag.load(.acquire);
}

fn sleepMs(ms: u32) void {
    var none: [0]std.c.pollfd = .{};
    _ = std.c.poll(&none, 0, @intCast(ms));
}

const testing = std.testing;

/// A fake child: a bash script that reads its terminal raw and reports on
/// its report channel the way fx does. bash, because dash takes only
/// single-digit fds in `>&` and `<&`.
const FakeChild = struct {
    dir: std.testing.TmpDir,
    path: []u8,

    const prelude =
        \\#!/bin/bash
        \\r=${SUB_ENGINE_REPORT%%:*}
        \\stty raw -echo
        \\say() { printf '%s\n' "$1" >&"$r"; }
        \\take() { head -c "$1" > /dev/null; }
        \\turn() {
        \\  take $(( $1 + 12 )); say '{"event":"pasted"}'
        \\  take 1; say '{"event":"message","text":"m"}'
        \\  printf 'working\r\n'
        \\  say '{"event":"turn_end","final":"'"$2"'","next":"idle"}'
        \\}
        \\printf 'fake child\r\n'
        \\
    ;

    fn create(body: []const u8) !FakeChild {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        const script = try std.mem.concat(testing.allocator, u8, &.{ prelude, body, "\n" });
        defer testing.allocator.free(script);
        var file = try dir.dir.createFile(testing.io, "child.sh", .{ .permissions = .fromMode(0o755) });
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, script);
        const real = try std.Io.Dir.realPathFileAlloc(dir.dir, testing.io, "child.sh", testing.allocator);
        defer testing.allocator.free(real);
        return .{ .dir = dir, .path = try testing.allocator.dupe(u8, real) };
    }

    fn deinit(self: *FakeChild) void {
        testing.allocator.free(self.path);
        self.dir.cleanup();
    }

    fn runtime(self: *const FakeChild) !Runtime {
        return Runtime.init(testing.allocator, testing.io, .{
            .program = self.path,
            .start_timeout_ms = 2000,
            .delivery_timeout_ms = 1500,
        });
    }
};

fn expectStatus(status: Status, state: labels_mod.State, turns: u64) !void {
    try testing.expectEqual(state, status.state);
    try testing.expectEqual(turns, status.turns_ended);
}

test "a child gets the root-user context before its task and each message" {
    // The child reads one report-channel line before each turn and says in
    // its final reply whether it was the context.
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\for turn_name in task message; do
        \\  read -r line <&"$r"
        \\  if [[ $line == *'"kind":"context"'*'run the tests'* ]]; then got="$turn_name with context"; else got=missing; fi
        \\  turn 4 "$got"
        \\done
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();
    const context = "current_request: run the tests\n";

    const launched = try runtime.launch(testing.allocator, "a1", "task", .{ .root_context = context }, null);
    defer launched.status.deinit(testing.allocator);
    const first = try runtime.wait(testing.allocator, &.{"a1"}, 5000, null);
    defer freeStatuses(testing.allocator, first.children);
    const final = try runtime.read(testing.allocator, "a1", .final);
    defer final.deinit(testing.allocator);
    try testing.expectEqualStrings("task with context", final.final.text.?);

    try testing.expectEqual(Delivery.delivered, try runtime.send("a1", "more", context, null));
    const second = try runtime.wait(testing.allocator, &.{"a1"}, 5000, null);
    defer freeStatuses(testing.allocator, second.children);
    const final2 = try runtime.read(testing.allocator, "a1", .final);
    defer final2.deinit(testing.allocator);
    try testing.expectEqualStrings("message with context", final2.final.text.?);
}

test "a delivery that times out clears the child's draft" {
    // The child never reports the paste, and says when Ctrl+U arrives.
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\while IFS= read -r -n1 -d '' c; do
        \\  if [[ $c == $'\x15' ]]; then printf 'cleared\r\n'; break; fi
        \\done
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();

    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    defer launched.status.deinit(testing.allocator);
    try testing.expectEqual(Delivery.not_delivered, launched.delivery);
    var waited: u32 = 0;
    while (true) : (waited += 20) {
        const shown = try runtime.read(testing.allocator, "a1", .screen);
        defer shown.deinit(testing.allocator);
        if (std.mem.find(u8, shown.screen, "cleared") != null) break;
        if (waited >= 3000) return error.TestExpectedClearedDraft;
        sleepMs(20);
    }
}

test "a launch cancelled during its delivery leaves no child" {
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    const Canceller = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            sleepMs(300);
            flag.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&cancel});
    defer thread.join();
    try testing.expectError(error.Cancelled, runtime.launch(testing.allocator, "a1", "task", .{}, &cancel));
    const statuses = try runtime.list(testing.allocator);
    defer freeStatuses(testing.allocator, statuses);
    try testing.expectEqual(@as(usize, 0), statuses.len);
}

test "blockedOthers counts the other children waiting on a prompt" {
    const prompt = try labels_mod.encode(testing.allocator, .{ .prompt = .{ .number = 1, .reason = .permission, .body = .{
        .permission = .{ .id = 1, .label = "shell" },
    } } });
    defer testing.allocator.free(prompt);
    const body = try std.mem.concat(testing.allocator, u8, &.{
        "say '{\"event\":\"state\",\"state\":\"idle\"}'\nturn 4 'done'\nsay '",
        std.mem.trimEnd(u8, prompt, "\n"),
        "'\nsleep 30",
    });
    defer testing.allocator.free(body);
    var fake = try FakeChild.create(body);
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();

    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    defer launched.status.deinit(testing.allocator);
    const statuses = try runtime.list(testing.allocator);
    defer freeStatuses(testing.allocator, statuses);
    const handle = statuses[0].handle.?;
    var waited: u32 = 0;
    while (runtime.blockedOthers(.{ .slot = handle.slot + 1, .id = handle.id }) == 0) : (waited += 20) {
        if (waited >= 3000) return error.TestExpectedBlockedChild;
        sleepMs(20);
    }
    try testing.expectEqual(@as(usize, 0), runtime.blockedOthers(handle));
}

test "a child takes its task and later messages, and wait returns once each turn ends" {
    var fake = try FakeChild.create(
        \\say '{"event":"session","id":"sess-1"}'
        \\say '{"event":"state","state":"idle"}'
        \\turn 4 'first done'
        \\turn 4 'second done'
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();

    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    defer launched.status.deinit(testing.allocator);
    try testing.expectEqual(Delivery.delivered, launched.delivery);
    try testing.expectEqualStrings("sess-1", launched.status.session_id.?);

    const first = try runtime.wait(testing.allocator, &.{"a1"}, 5000, null);
    defer freeStatuses(testing.allocator, first.children);
    try testing.expect(!first.timed_out);
    try expectStatus(first.children[0], .idle, 1);
    const final = try runtime.read(testing.allocator, "a1", .final);
    defer final.deinit(testing.allocator);
    try testing.expectEqualStrings("first done", final.final.text.?);

    try testing.expectEqual(Delivery.delivered, try runtime.send("a1", "more", "", null));
    const second = try runtime.wait(testing.allocator, &.{}, 5000, null);
    defer freeStatuses(testing.allocator, second.children);
    try expectStatus(second.children[0], .idle, 2);
    const final2 = try runtime.read(testing.allocator, "a1", .final);
    defer final2.deinit(testing.allocator);
    try testing.expectEqualStrings("second done", final2.final.text.?);
    const shown = try runtime.read(testing.allocator, "a1", .screen);
    defer shown.deinit(testing.allocator);
    try testing.expect(std.mem.find(u8, shown.screen, "fake child") != null);
    const messages = try runtime.read(testing.allocator, "a1", .messages);
    defer messages.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), messages.messages.len);

    const stopped = try runtime.stop(testing.allocator, "a1");
    defer stopped.deinit(testing.allocator);
    try testing.expectEqualStrings("sess-1", stopped.session_id.?);
    const statuses = try runtime.list(testing.allocator);
    defer freeStatuses(testing.allocator, statuses);
    try testing.expectEqual(@as(usize, 0), statuses.len);
    try testing.expectError(error.NotFound, runtime.send("a1", "gone", "", null));
}

test "a paste the child never takes submits nothing" {
    // Like a child whose open prompt takes the paste.
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\take 16
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();

    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    defer launched.status.deinit(testing.allocator);
    try testing.expectEqual(Delivery.not_delivered, launched.delivery);
    // Nothing was submitted, so the child still counts as settled.
    const waited = try runtime.wait(testing.allocator, &.{"a1"}, 1000, null);
    defer freeStatuses(testing.allocator, waited.children);
    try testing.expect(!waited.timed_out);
    try expectStatus(waited.children[0], .idle, 0);
}

test "a child that exits is settled and refuses messages" {
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\exit 3
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();

    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    defer launched.status.deinit(testing.allocator);
    try testing.expectEqual(Delivery.exited, launched.delivery);
    // An idle child with nothing pending is settled even before its exit is
    // noticed, so wait for the exit itself.
    var exit: ?sub_engine.Exit = null;
    var waited: u32 = 0;
    while (exit == null and waited < 5000) : (waited += 20) {
        const statuses = try runtime.list(testing.allocator);
        defer freeStatuses(testing.allocator, statuses);
        exit = statuses[0].exit;
        if (exit == null) sleepMs(20);
    }
    try testing.expectEqual(sub_engine.Exit{ .code = 3 }, exit.?);
    try testing.expectError(error.Exited, runtime.send("a1", "hello", "", null));
    const stopped = try runtime.stop(testing.allocator, "a1");
    stopped.deinit(testing.allocator);
}

test "a child that never starts is closed and its name freed" {
    var fake = try FakeChild.create("sleep 30");
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();
    runtime.config.start_timeout_ms = 300;
    try testing.expectError(error.StartTimedOut, runtime.launch(testing.allocator, "a1", "task", .{}, null));
    const statuses = try runtime.list(testing.allocator);
    defer freeStatuses(testing.allocator, statuses);
    try testing.expectEqual(@as(usize, 0), statuses.len);
}

test "names stay unique and limited when launches run in parallel" {
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\turn 4 'done'
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();

    const Attempt = struct {
        result: ?LaunchError = null,

        fn run(self: *@This(), target: *Runtime) void {
            const launched = target.launch(testing.allocator, "dup", "task", .{}, null) catch |err| {
                self.result = err;
                return;
            };
            launched.status.deinit(testing.allocator);
        }
    };
    var attempts = [_]Attempt{ .{}, .{} };
    var threads: [2]std.Thread = undefined;
    for (&threads, &attempts) |*thread, *attempt| thread.* = try std.Thread.spawn(.{}, Attempt.run, .{ attempt, &runtime });
    for (threads) |thread| thread.join();
    var succeeded: usize = 0;
    var taken: usize = 0;
    for (attempts) |attempt| {
        const err = attempt.result orelse {
            succeeded += 1;
            continue;
        };
        if (err == error.NameTaken) taken += 1;
    }
    try testing.expectEqual(@as(usize, 1), succeeded);
    try testing.expectEqual(@as(usize, 1), taken);

    try testing.expectError(error.InvalidName, runtime.launch(testing.allocator, "Bad Name", "task", .{}, null));
    try testing.expectError(error.UnsupportedText, runtime.launch(testing.allocator, "esc", "a\x1b[201~b", .{}, null));
    var name: [8]u8 = undefined;
    for (1..max_children) |i| {
        const launched = try runtime.launch(testing.allocator, try std.fmt.bufPrint(&name, "c{d}", .{i}), "task", .{}, null);
        launched.status.deinit(testing.allocator);
    }
    try testing.expectError(error.LimitReached, runtime.launch(testing.allocator, "eleven", "task", .{}, null));
}

test "wait times out, and stops when cancelled" {
    // The child takes the message but never finishes the turn.
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\take 16; say '{"event":"pasted"}'
        \\take 1; say '{"event":"message","text":"m"}'
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();
    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    defer launched.status.deinit(testing.allocator);
    try testing.expectEqual(Delivery.delivered, launched.delivery);

    const waited = try runtime.wait(testing.allocator, &.{"a1"}, 200, null);
    defer freeStatuses(testing.allocator, waited.children);
    try testing.expect(waited.timed_out);
    try expectStatus(waited.children[0], .working, 0);

    var cancel = std.atomic.Value(bool).init(true);
    try testing.expectError(error.Cancelled, runtime.wait(testing.allocator, &.{"a1"}, 60_000, &cancel));
    try testing.expectError(error.NotFound, runtime.wait(testing.allocator, &.{"nobody"}, 100, null));
}

/// Polls until `ready` says so, or fails after five seconds.
fn pollUntil(runtime: *Runtime, comptime ready: fn (*Runtime) anyerror!bool) !void {
    var waited: u32 = 0;
    while (!try ready(runtime)) : (waited += 20) {
        if (waited >= 5000) return error.TestTimedOut;
        sleepMs(20);
    }
}

fn screenHas(runtime: *Runtime, text: []const u8) !bool {
    const shown = try runtime.read(testing.allocator, "a1", .screen);
    defer shown.deinit(testing.allocator);
    return std.mem.find(u8, shown.screen, text) != null;
}

test "a child's permission prompt is shown on main and the answer reaches the child" {
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\turn 4 'done'
        \\say '{"event":"prompt","number":1,"reason":"permission","permission":{"id":9,"label":"shell: ls","command":"ls"}}'
        \\read -r answer <&"$r"
        \\printf 'answer=%s\r\n' "$answer"
        \\say '{"event":"prompt_closed","number":1,"next":"idle"}'
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();
    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    launched.status.deinit(testing.allocator);

    try pollUntil(&runtime, struct {
        fn ready(r: *Runtime) !bool {
            var pending = try r.pendingPermission(testing.allocator) orelse return false;
            pending.deinit(testing.allocator);
            return true;
        }
    }.ready);
    var pending = (try runtime.pendingPermission(testing.allocator)).?;
    defer pending.deinit(testing.allocator);
    try testing.expectEqualStrings("shell: ls", pending.label);
    try testing.expectEqualStrings("a1", pending.origin.subagent);
    try testing.expect(pending.id >= first_prompt_id);
    try testing.expect((try runtime.presentQuestions(testing.allocator)) == null);
    try testing.expect(runtime.ownsPrompt(pending.id));

    try runtime.answerPermission(pending.id, .always, "keep it short");
    // Answered: main stops showing it, and a second answer is stale.
    try testing.expect((try runtime.pendingPermission(testing.allocator)) == null);
    try testing.expectError(error.Stale, runtime.answerPermission(pending.id, .deny, null));
    try pollUntil(&runtime, struct {
        fn ready(r: *Runtime) !bool {
            return screenHas(r, "\"decision\":\"always\"");
        }
    }.ready);
    try testing.expect(try screenHas(&runtime, "\"prompt\":1"));
    try testing.expect(try screenHas(&runtime, "keep it short"));
    const waited = try runtime.wait(testing.allocator, &.{"a1"}, 5000, null);
    defer freeStatuses(testing.allocator, waited.children);
    try expectStatus(waited.children[0], .idle, 1);
    try testing.expect(!runtime.ownsPrompt(pending.id));
}

test "a child's questions are shown on main, answered or cancelled" {
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\turn 4 'done'
        \\say '{"event":"prompt","number":1,"reason":"question","questions":[{"question":"Which?","options":[{"label":"a"},{"label":"b"}]}]}'
        \\read -r answer <&"$r"
        \\printf 'first=%s\r\n' "$answer"
        \\say '{"event":"prompt_closed","number":1,"next":"working"}'
        \\say '{"event":"prompt","number":2,"reason":"question","questions":[{"question":"Again?","options":[{"label":"y"}]}]}'
        \\read -r answer <&"$r"
        \\printf 'second=%s\r\n' "$answer"
        \\say '{"event":"prompt_closed","number":2,"next":"working"}'
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();
    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    launched.status.deinit(testing.allocator);

    const Present = struct {
        fn ready(r: *Runtime) !bool {
            var pending = try r.presentQuestions(testing.allocator) orelse return false;
            pending.deinit();
            return true;
        }
    };
    try pollUntil(&runtime, Present.ready);
    var first = (try runtime.presentQuestions(testing.allocator)).?;
    defer first.deinit();
    try testing.expectEqualStrings("a1", first.child_name);
    try testing.expectEqualStrings("Which?", first.entries[0].question);
    try testing.expectEqualStrings("b", first.entries[0].options[1].label);
    try testing.expectEqual(@as(?u64, first.id), runtime.presentedQuestions());
    try runtime.answerQuestions(&.{"b"});
    try testing.expect(runtime.presentedQuestions() == null);
    try pollUntil(&runtime, struct {
        fn ready(r: *Runtime) !bool {
            return screenHas(r, "first={\"kind\":\"questions\",\"prompt\":1,\"answers\":[\"b\"]}");
        }
    }.ready);

    try pollUntil(&runtime, Present.ready);
    try runtime.answerQuestions(null);
    try pollUntil(&runtime, struct {
        fn ready(r: *Runtime) !bool {
            return screenHas(r, "second={\"kind\":\"questions\",\"prompt\":2}");
        }
    }.ready);
    try testing.expectError(error.Stale, runtime.answerQuestions(null));
}

test "a message to a child waiting on a prompt is refused, not typed" {
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\turn 4 'done'
        \\say '{"event":"prompt","number":1,"reason":"question","questions":[{"question":"Which?","options":[{"label":"a"}]}]}'
        \\sleep 30
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();
    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    launched.status.deinit(testing.allocator);
    const waited = try runtime.wait(testing.allocator, &.{"a1"}, 5000, null);
    defer freeStatuses(testing.allocator, waited.children);
    try testing.expectEqual(labels_mod.State.blocked, waited.children[0].state);
    try testing.expectError(error.Blocked, runtime.send("a1", "answer it for me", "", null));
}

fn echoedKey(runtime: *Runtime) !bool {
    return screenHas(runtime, "got x");
}

fn reportedSize(runtime: *Runtime) !bool {
    return screenHas(runtime, "size 20 60");
}

// The fake child polls its size: bash 5 runs no WINCH trap while `read`
// waits, and the bash 3.2 macOS ships takes no fractional timeouts.
test "the live view copies a child's screen, types into it and resizes it" {
    var fake = try FakeChild.create(
        \\say '{"event":"state","state":"idle"}'
        \\turn 4 'done'
        \\last=$(stty size)
        \\while true; do
        \\  IFS= read -r -n1 -t 1 c && printf 'got %s\r\n' "$c"
        \\  size=$(stty size)
        \\  [ "$size" = "$last" ] || { last=$size; printf 'size %s\r\n' "$size"; }
        \\done
    );
    defer fake.deinit();
    var runtime = try fake.runtime();
    defer runtime.deinit();
    const launched = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    launched.status.deinit(testing.allocator);
    const waited = try runtime.wait(testing.allocator, &.{"a1"}, 5000, null);
    freeStatuses(testing.allocator, waited.children);
    const statuses = try runtime.list(testing.allocator);
    const handle = statuses[0].handle.?;
    freeStatuses(testing.allocator, statuses);

    var first = (try runtime.screen(testing.allocator, handle, null)).?;
    defer first.grid.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try first.grid.rowTextTrimmed(1, &text);
    try testing.expectEqualStrings("fake child", text.items);
    // Nothing changed, so there is nothing to copy.
    try testing.expect(try runtime.screen(testing.allocator, handle, first.version) == null);

    try runtime.keys(handle, "x");
    try pollUntil(&runtime, echoedKey);
    // "fake child", "working" and "got x" each end a line.
    var typed = (try runtime.screen(testing.allocator, handle, first.version)).?;
    defer typed.grid.deinit();
    try testing.expectEqual(@as(u16, 4), typed.grid.cursor_row);
    try testing.expectEqual(@as(u16, 1), typed.grid.cursor_col);

    runtime.resize(60, 20);
    try pollUntil(&runtime, reportedSize);
    var resized = (try runtime.screen(testing.allocator, handle, first.version)).?;
    defer resized.grid.deinit();
    try testing.expectEqual(@as(u16, 60), resized.grid.cols);
    try testing.expectEqual(@as(u16, 20), resized.grid.rows);

    const stopped = try runtime.stop(testing.allocator, "a1");
    stopped.deinit(testing.allocator);
    try testing.expectError(error.Gone, runtime.screen(testing.allocator, handle, null));
    try testing.expectError(error.Gone, runtime.keys(handle, "y"));
    // A new child with the old name is another child.
    const again = try runtime.launch(testing.allocator, "a1", "task", .{}, null);
    again.status.deinit(testing.allocator);
    try testing.expectError(error.Gone, runtime.screen(testing.allocator, handle, null));
}
