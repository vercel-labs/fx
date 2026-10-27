//! Messages between the agents of one tree (D185 to D189), proto's IRC bus
//! in proto-fx form. Each node keeps a mailbox in its own log
//! (`fold_mail.zig`); this file routes a message there and then to the
//! node's model, exactly once:
//!
//! - A worker gets its waiting messages as `send` would give them, from
//!   its parent's host: a steer into its running turn, or a turn of its
//!   own that its parent owns and lists as a job, as proto's wake turns
//!   are. A turn is admitted durably, so its messages leave the mailbox at
//!   once; a steer's messages leave it when the steer is applied, and wait
//!   again when it is not.
//! - The root gets its messages from the supervisor's tick, as job notices
//!   are (`supervisor/wake.zig`): a steer of the running turn or a turn of
//!   its own, settled by the host's answer.
//!
//! After a restart, a waiting message the node's history already holds was
//! received before the crash and leaves the mailbox as delivered
//! (`tests/tla/jobs/Mailbox.tla` ExactlyOnce, NoLossAcrossRestart).
const std = @import("std");
const agent_message = @import("agent_message.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const fleet_host = @import("fleet_host.zig");
const io_mod = @import("../shared/io.zig");
const node_ops = @import("node_ops.zig");
const session_adapter = @import("../session/session_adapter.zig");
const session_store = @import("../session/session_store.zig");
const tool_host = @import("tool_host.zig");
const types = @import("../shared/types.zig");
pub const directory = @import("mail_directory.zig");

const Allocator = std.mem.Allocator;
const Runtime = tool_host.Runtime;
const Mail = session_adapter.Mail;
const Node = directory.Node;

/// After the loop answered a root notice without delivering it, the next
/// waits this long.
const undelivered_retry_ms = 5_000;

pub const Outcome = enum { delivered, queued, rejected, dropped };
pub const Effect = enum { injected, wake_requested };

/// What became of one message, as proto's bus answers a sender.
pub const Receipt = struct {
    to: []const u8,
    label: []const u8 = "",
    id: ?[]const u8 = null,
    outcome: Outcome,
    effect: ?Effect = null,
    /// The recipient's host was closed and opened again for it.
    revived: bool = false,
    /// The oldest waiting message a full mailbox dropped for this one.
    dropped_oldest: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const SendInput = struct {
    to: []const u8,
    body: []const u8,
    reply_to: ?[]const u8 = null,
};

/// One tree's mail state in this process. Durable state is the mailboxes;
/// this holds only what is in flight.
pub const Bus = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    /// Bumped whenever a mailbox changes, for waits.
    generation: std.atomic.Value(u64) = .init(0),
    /// Nodes that may have waiting messages; null until the first pump
    /// reads every mailbox of the tree.
    pending: ?std.array_hash_map.String(void) = null,
    /// Messages steered into a worker's running turn, until the steer is
    /// settled.
    steers: std.ArrayList(Steer) = .empty,
    /// Root messages the supervisor handed to the loop and not answered.
    root_notices: std.ArrayList(InflightNotice) = .empty,
    /// Waits on the root's mailbox; automatic delivery leaves it to them.
    root_waits: usize = 0,
    root_retry_after_ms: i64 = 0,
    /// Nodes whose mailbox one thread is handing to their model now. Only
    /// one delivery or inbox read runs per node, so no message is carried
    /// twice or settled by another's delivery (`tests/tla/jobs/Mailbox.tla` ExactlyOnce, mutation two_carriers).
    delivering: std.array_hash_map.String(void) = .empty,
    /// Whether the root's log may hold messages for workers admitted but
    /// not started, which have no log to keep them (D212): each moves into
    /// its worker's mailbox once the worker's first turn saves its log.
    /// True at start, so the first pump looks after a restart.
    held_maybe: std.atomic.Value(bool) = .init(true),
    /// Rows for the root's transcript of messages between workers, as
    /// proto relays them to its main view: "alpha → beta · first line".
    relays: std.ArrayList([]u8) = .empty,
    /// Whether the root's own turn ran at the supervisor's last tick, so a
    /// receipt can say whether a message joins it or wakes it.
    root_busy: std.atomic.Value(bool) = .init(false),

    const Steer = struct {
        node_id: []u8,
        parent_id: []u8,
        operation_id: []u8,
        fingerprint: [32]u8,
        ids: [][]u8,

        fn free(steer: Steer, alloc: Allocator) void {
            alloc.free(steer.node_id);
            alloc.free(steer.parent_id);
            alloc.free(steer.operation_id);
            freeIds(alloc, steer.ids);
        }
    };

    const InflightNotice = struct {
        request_id: i64,
        ids: [][]u8,
    };

    pub fn init(alloc: Allocator) Bus {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Bus) void {
        if (self.pending) |*pending| {
            for (pending.keys()) |key| self.alloc.free(key);
            pending.deinit(self.alloc);
        }
        for (self.steers.items) |steer| steer.free(self.alloc);
        self.steers.deinit(self.alloc);
        for (self.root_notices.items) |notice| freeIds(self.alloc, notice.ids);
        self.root_notices.deinit(self.alloc);
        for (self.delivering.keys()) |key| self.alloc.free(key);
        self.delivering.deinit(self.alloc);
        for (self.relays.items) |row| self.alloc.free(row);
        self.relays.deinit(self.alloc);
        self.* = undefined;
    }

    fn lock(self: *Bus) void {
        self.mutex.lockUncancelable(io_mod.getIo());
    }

    fn unlock(self: *Bus) void {
        self.mutex.unlock(io_mod.getIo());
    }

    /// Waits on the root's mailbox now.
    pub fn rootWaits(self: *Bus) usize {
        self.lock();
        defer self.unlock();
        return self.root_waits;
    }

    /// Claims node `node_id`'s mailbox for one delivery or read; false
    /// while another holds it.
    fn claim(self: *Bus, node_id: []const u8) bool {
        self.lock();
        defer self.unlock();
        if (self.delivering.contains(node_id)) return false;
        const owned = self.alloc.dupe(u8, node_id) catch return false;
        self.delivering.put(self.alloc, owned, {}) catch {
            self.alloc.free(owned);
            return false;
        };
        return true;
    }

    fn unclaim(self: *Bus, node_id: []const u8) void {
        self.lock();
        defer self.unlock();
        const index = self.delivering.getIndex(node_id) orelse return;
        self.alloc.free(self.delivering.keys()[index]);
        self.delivering.swapRemoveAt(index);
    }

    /// `claim`, waiting a little for another holder to finish.
    fn claimWaiting(self: *Bus, node_id: []const u8) bool {
        var tries: usize = 0;
        while (tries < 2000) : (tries += 1) {
            if (self.claim(node_id)) return true;
            io_mod.sleep(std.time.ns_per_ms);
        }
        return false;
    }

    fn changed(self: *Bus) void {
        _ = self.generation.fetchAdd(1, .seq_cst);
    }

    /// Ids of `node_id`'s messages on their way to its model. Owned by
    /// `arena`. Holds `mutex`.
    fn inflightLocked(self: *Bus, arena: Allocator, node_id: []const u8, root: bool) ![]const []const u8 {
        var ids: std.ArrayList([]const u8) = .empty;
        if (root) {
            for (self.root_notices.items) |notice| for (notice.ids) |id| try ids.append(arena, try arena.dupe(u8, id));
        } else for (self.steers.items) |steer| {
            if (!std.mem.eql(u8, steer.node_id, node_id)) continue;
            for (steer.ids) |id| try ids.append(arena, try arena.dupe(u8, id));
        }
        return ids.items;
    }

    fn markPending(self: *Bus, node_id: []const u8) void {
        self.lock();
        defer self.unlock();
        const pending = if (self.pending) |*pending| pending else return;
        if (pending.contains(node_id)) return;
        const owned = self.alloc.dupe(u8, node_id) catch return;
        pending.put(self.alloc, owned, {}) catch self.alloc.free(owned);
    }

    fn clearPending(self: *Bus, node_id: []const u8) void {
        self.lock();
        defer self.unlock();
        const pending = if (self.pending) |*pending| pending else return;
        const index = pending.getIndex(node_id) orelse return;
        self.alloc.free(pending.keys()[index]);
        pending.swapRemoveAt(index);
    }
};

fn freeIds(alloc: Allocator, ids: []const []u8) void {
    for (ids) |id| alloc.free(id);
    alloc.free(ids);
}

fn dupeIds(alloc: Allocator, mails: []const Mail) ![][]u8 {
    const ids = try alloc.alloc([]u8, mails.len);
    var filled: usize = 0;
    errdefer {
        for (ids[0..filled]) |id| alloc.free(id);
        alloc.free(ids);
    }
    for (mails, ids) |mail, *id| {
        id.* = try alloc.dupe(u8, mail.id);
        filled += 1;
    }
    return ids;
}

fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

/// `mailbox` without the messages in `inflight` and, with `from`, only
/// those from that sender. Owned by `arena`.
fn waiting(arena: Allocator, mailbox: []const Mail, inflight: []const []const u8, from: ?[]const u8) ![]Mail {
    var out: std.ArrayList(Mail) = .empty;
    for (mailbox) |mail| {
        if (contains(inflight, mail.id)) continue;
        if (from) |sender| if (!std.mem.eql(u8, mail.from, sender)) continue;
        try out.append(arena, mail);
    }
    return out.items;
}

fn rootHost(bus_owner: *Runtime) *Runtime {
    return bus_owner.tree.root_host.?;
}

fn bus(host: *Runtime) *Bus {
    return &host.tree.mail;
}

// ---------------------------------------------------------------------------
// Sending

/// Sends `input` from `sender`'s node to one agent of its tree, its parent
/// or root by name, or every other live agent with `all` (D186). Receipts
/// are owned by `arena`.
pub fn send(sender: *Runtime, arena: Allocator, input: SendInput) ![]Receipt {
    const root = rootHost(sender);
    const nodes = try directory.list(arena, root);
    const me = directory.find(nodes, sender.node_id) orelse return error.NodeUnavailable;
    var receipts: std.ArrayList(Receipt) = .empty;
    if (std.mem.eql(u8, input.to, "all")) {
        for (nodes) |node| {
            if (std.mem.eql(u8, node.id, me.id) or node.terminated) continue;
            try receipts.append(arena, try sendOne(root, arena, me, node, input, true));
        }
    } else {
        const target_id: []const u8 = if (std.mem.eql(u8, input.to, "parent"))
            me.parent orelse return receiptsOf(arena, .{ .to = input.to, .outcome = .rejected, .@"error" = "The root agent has no parent." })
        else if (std.mem.eql(u8, input.to, "root"))
            root.node_id
        else
            input.to;
        if (std.mem.eql(u8, target_id, me.id)) return receiptsOf(arena, .{ .to = input.to, .outcome = .rejected, .@"error" = "Cannot send a message to yourself." });
        const target = directory.find(nodes, target_id) orelse {
            const hint = if (directory.findLabel(nodes, target_id)) |named|
                try arena.print("`{s}` is a label, and labels never route. Address agent `{s}` by its id.", .{ target_id, named.id })
            else
                try arena.print("Unknown agent `{s}`. fleet op \"list\" scope \"visible\" names every agent of this tree.", .{target_id});
            return receiptsOf(arena, .{ .to = input.to, .outcome = .rejected, .@"error" = hint });
        };
        if (target.terminated) return receiptsOf(arena, .{
            .to = target.id,
            .label = target.label,
            .outcome = .rejected,
            .@"error" = try arena.print("Agent `{s}` is terminal and takes no more messages. Its transcript stays readable at history://{s}.", .{ target.id, target.id }),
        });
        try receipts.append(arena, try sendOne(root, arena, me, target, input, false));
        if (me.depth > 0 and target.depth > 0) relay(root, arena, me.label, target.label, input.body);
    }
    bus(root).changed();
    return receipts.items;
}

const max_relays = 64;

/// Queues the root transcript's row for a message between workers.
fn relay(root: *Runtime, arena: Allocator, from: []const u8, to: []const u8, body: []const u8) void {
    const b = bus(root);
    const row = agent_message.rowText(arena, .{ .id = "", .from = from, .label = from, .preview = agent_message.preview(body) }, to) catch return;
    const owned = b.alloc.dupe(u8, row) catch return;
    b.lock();
    defer b.unlock();
    if (b.relays.items.len >= max_relays) b.alloc.free(b.relays.orderedRemove(0));
    b.relays.append(b.alloc, owned) catch b.alloc.free(owned);
}

/// The relayed rows since the last call, oldest first. Owned by `arena`.
pub fn takeRelays(root: *Runtime, arena: Allocator) ![]const []const u8 {
    const b = bus(root);
    b.lock();
    defer b.unlock();
    const out = try arena.alloc([]const u8, b.relays.items.len);
    for (b.relays.items, out) |row, *copy| copy.* = try arena.dupe(u8, row);
    for (b.relays.items) |row| b.alloc.free(row);
    b.relays.clearRetainingCapacity();
    return out;
}

fn receiptsOf(arena: Allocator, receipt: Receipt) ![]Receipt {
    const out = try arena.alloc(Receipt, 1);
    out[0] = receipt;
    return out;
}

fn sendOne(root: *Runtime, arena: Allocator, me: Node, target: Node, input: SendInput, broadcast: bool) !Receipt {
    const id = try session_store.generateSessionId(arena);
    const line: session_adapter.MailLine = .{ .mail = .{
        .id = id,
        .from = me.id,
        .label = me.label,
        .body = input.body,
        .reply_to = input.reply_to,
        .broadcast = broadcast,
    } };
    if (target.depth == 0) {
        const dropped = post(root, arena, root.children.parent, root.node_id, line) catch |err| return failed(arena, target, err);
        bus(root).changed();
        const busy = bus(root).root_busy.load(.seq_cst);
        return .{ .to = target.id, .label = target.label, .id = id, .outcome = .delivered, .effect = if (busy) .injected else .wake_requested, .dropped_oldest = dropped };
    }
    const revived = !root.tree.nodes.isOpen(target.id);
    const entry = node_ops.lease(root, target.path) catch |err| switch (err) {
        // Admitted, still waiting for a run slot: no log yet.
        error.NodeUnavailable => return holdEarly(root, arena, target, line) catch |hold_err| failed(arena, target, hold_err),
        else => return failed(arena, target, err),
    };
    defer node_ops.release(root, entry);
    if (!entry.session.saved()) return holdEarly(root, arena, target, line) catch |err| failed(arena, target, err);
    // Messages held for it before it started go first, in order.
    flushHeldFor(root, arena, entry, target.id) catch |err| return failed(arena, target, err);
    const dropped = post(root, arena, entry.session, target.id, line) catch |err| return failed(arena, target, err);
    bus(root).changed();
    const effect: ?Effect = switch (try deliverWorker(root, arena, entry, target)) {
        .steered => .injected,
        .turn => .wake_requested,
        .none, .later => null,
        .terminal => return .{ .to = target.id, .label = target.label, .id = id, .outcome = .rejected, .@"error" = "The agent became terminal before the message reached it." },
    };
    return .{
        .to = target.id,
        .label = target.label,
        .id = id,
        .outcome = if (effect != null) .delivered else .queued,
        .effect = effect,
        .revived = revived,
        .dropped_oldest = dropped,
        .@"error" = if (effect == null) "The agent cannot take it now; it waits in its mailbox and is delivered when the agent can." else null,
    };
}

/// Keeps a message for a worker that has not started in the root's log,
/// held for it, until the worker's log exists (D212, `flushHeld`): a crash
/// cannot lose it. Bounded like a mailbox: the oldest held for that worker
/// goes first.
fn holdEarly(root: *Runtime, arena: Allocator, target: Node, line: session_adapter.MailLine) !Receipt {
    const b = bus(root);
    var mail = line.mail;
    mail.hold_for = target.id;
    var dropped: ?[]const u8 = null;
    {
        b.lock();
        defer b.unlock();
        const session = root.children.parent;
        const held = try session.heldMail(arena);
        var count: usize = 0;
        var oldest: ?[]const u8 = null;
        for (held) |item| if (std.mem.eql(u8, item.hold_for.?, target.id)) {
            count += 1;
            if (oldest == null) oldest = item.id;
        };
        var lines: [2]session_adapter.MailLine = undefined;
        var len: usize = 0;
        if (count >= session_adapter.max_mailbox) {
            dropped = oldest;
            lines[len] = .{ .done = .{ .id = oldest.?, .how = .dropped } };
            len += 1;
        }
        lines[len] = .{ .mail = mail };
        len += 1;
        try session.appendMail(lines[0..len]);
        b.held_maybe.store(true, .seq_cst);
    }
    b.changed();
    return .{
        .to = target.id,
        .label = target.label,
        .id = mail.id,
        .outcome = .queued,
        .dropped_oldest = dropped,
        .@"error" = "The agent has not started yet; the message reaches it once it starts.",
    };
}

/// Moves held messages into the mailboxes of workers whose log now exists,
/// and drops those held for a worker that is gone or terminal.
fn flushHeld(root: *Runtime, arena: Allocator) void {
    const b = bus(root);
    if (!b.held_maybe.load(.seq_cst)) return;
    const held = blk: {
        b.lock();
        defer b.unlock();
        const held = root.children.parent.heldMail(arena) catch return;
        if (held.len == 0) b.held_maybe.store(false, .seq_cst);
        break :blk held;
    };
    if (held.len == 0) return;
    var targets: std.ArrayList([]const u8) = .empty;
    for (held) |mail| {
        if (!contains(targets.items, mail.hold_for.?)) targets.append(arena, mail.hold_for.?) catch return;
    }
    const tree_nodes = directory.list(arena, root) catch return;
    for (targets.items) |node_id| {
        const node = directory.find(tree_nodes, node_id) orelse {
            finishHeld(root, arena, node_id, null, .dropped);
            continue;
        };
        if (node.terminated) {
            finishHeld(root, arena, node_id, null, .dropped);
            continue;
        }
        const entry = node_ops.lease(root, node.path) catch continue;
        defer node_ops.release(root, entry);
        if (!entry.session.saved()) continue;
        flushHeldFor(root, arena, entry, node_id) catch |err| {
            debug_trace.logf("subagent", "held mail not moved node_id={s} err={s}", .{ node_id, @errorName(err) });
        };
    }
}

/// Moves the messages the root's log holds for worker `node_id`, whose log
/// exists, into its mailbox in order, then takes them out of the root's
/// log, claiming the worker's mailbox meanwhile (`moveHeld`).
fn flushHeldFor(root: *Runtime, arena: Allocator, entry: *@import("node_hosts.zig").Entry, node_id: []const u8) !void {
    const b = bus(root);
    if (!b.held_maybe.load(.seq_cst)) return;
    if (!b.claimWaiting(node_id)) return error.MailboxBusy;
    defer b.unclaim(node_id);
    try moveHeld(root, arena, entry.session, node_id);
}

/// `flushHeldFor` for a caller that holds the worker's claim. Every carrier
/// of a worker's mail moves its held mail first, so none takes a message
/// that the root's log still holds: a crash between the move and the root
/// letting go leaves the message in both, and the next move skips one the
/// worker's mailbox or history already has (`tests/tla/jobs/Mailbox.tla`
/// ExactlyOnce, mutations take_unsettled and flush_no_dedupe).
fn moveHeld(root: *Runtime, arena: Allocator, session: *session_adapter.Session, node_id: []const u8) !void {
    const b = bus(root);
    if (!b.held_maybe.load(.seq_cst)) return;
    const held = blk: {
        b.lock();
        defer b.unlock();
        const all = try root.children.parent.heldMail(arena);
        var mine: std.ArrayList(Mail) = .empty;
        for (all) |mail| if (std.mem.eql(u8, mail.hold_for.?, node_id)) try mine.append(arena, mail);
        break :blk mine.items;
    };
    if (held.len == 0) return;
    const present_mail = try session.mailbox(arena);
    const received = try receivedIds(arena, root.tree.store, node_id, held);
    for (held) |mail| {
        if (contains(received, mail.id)) continue;
        var present = false;
        for (present_mail) |other| if (std.mem.eql(u8, other.id, mail.id)) {
            present = true;
        };
        if (present) continue;
        _ = try post(root, arena, session, node_id, .{ .mail = .{
            .id = mail.id,
            .from = mail.from,
            .label = mail.label,
            .body = mail.body,
            .reply_to = mail.reply_to,
            .broadcast = mail.broadcast,
        } });
    }
    finishHeld(root, arena, node_id, held, .delivered);
    b.markPending(node_id);
    b.changed();
}

/// Takes the messages held for `node_id` out of the root's log: `only`
/// those, or every one held for it.
fn finishHeld(root: *Runtime, arena: Allocator, node_id: []const u8, only: ?[]const Mail, how: session_adapter.MailEnd) void {
    const b = bus(root);
    b.lock();
    defer b.unlock();
    const session = root.children.parent;
    const held = session.heldMail(arena) catch return;
    var lines: std.ArrayList(session_adapter.MailLine) = .empty;
    for (held) |mail| {
        if (!std.mem.eql(u8, mail.hold_for.?, node_id)) continue;
        if (only) |subset| {
            var listed = false;
            for (subset) |item| if (std.mem.eql(u8, item.id, mail.id)) {
                listed = true;
            };
            if (!listed) continue;
        }
        lines.append(arena, .{ .done = .{ .id = mail.id, .how = how } }) catch return;
    }
    session.appendMail(lines.items) catch |err| {
        debug_trace.logf("subagent", "held mail settle not saved node_id={s} err={s}", .{ node_id, @errorName(err) });
        return;
    };
    b.changed();
}

fn failed(arena: Allocator, target: Node, err: anyerror) !Receipt {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    debug_trace.logf("subagent", "mail not posted node_id={s} err={s}", .{ target.id, @errorName(err) });
    return .{ .to = target.id, .label = target.label, .outcome = .rejected, .@"error" = try arena.print("The message could not be kept: {s}.", .{@errorName(err)}) };
}

/// Appends `line` to node `node_id`'s mailbox in `session`, dropping its
/// oldest waiting message when it is full (D185). Returns the dropped id.
fn post(root: *Runtime, arena: Allocator, session: *session_adapter.Session, node_id: []const u8, line: session_adapter.MailLine) !?[]const u8 {
    const b = bus(root);
    b.lock();
    defer b.unlock();
    const mailbox = try session.mailbox(arena);
    var dropped: ?[]const u8 = null;
    var lines: [2]session_adapter.MailLine = undefined;
    var count: usize = 0;
    if (mailbox.len >= session_adapter.max_mailbox) {
        const inflight = try b.inflightLocked(arena, node_id, std.mem.eql(u8, node_id, root.node_id));
        // The oldest that is not on its way to the model, or the oldest.
        var victim = mailbox[0];
        for (mailbox) |mail| if (!contains(inflight, mail.id)) {
            victim = mail;
            break;
        };
        dropped = victim.id;
        lines[count] = .{ .done = .{ .id = victim.id, .how = .dropped } };
        count += 1;
    }
    lines[count] = line;
    count += 1;
    try session.appendMail(lines[0..count]);
    if (b.pending) |*pending| if (!pending.contains(node_id)) {
        const owned = try b.alloc.dupe(u8, node_id);
        pending.put(b.alloc, owned, {}) catch |err| {
            b.alloc.free(owned);
            return err;
        };
    };
    return dropped;
}

/// Writes `how` for each of `ids` that still waits in `session`'s mailbox.
fn finishMail(root: *Runtime, arena: Allocator, session: *session_adapter.Session, ids: []const []const u8, how: session_adapter.MailEnd) void {
    const b = bus(root);
    b.lock();
    defer b.unlock();
    const mailbox = session.mailbox(arena) catch return;
    var lines: std.ArrayList(session_adapter.MailLine) = .empty;
    for (ids) |id| {
        for (mailbox) |mail| if (std.mem.eql(u8, mail.id, id)) {
            lines.append(arena, .{ .done = .{ .id = id, .how = how } }) catch return;
            break;
        };
    }
    session.appendMail(lines.items) catch |err| {
        debug_trace.logf("subagent", "mail settle not saved count={d} err={s}", .{ lines.items.len, @errorName(err) });
        return;
    };
    b.changed();
}

// ---------------------------------------------------------------------------
// Delivering to workers

const WorkerDelivery = enum { none, steered, turn, later, terminal };

/// Hands worker `node`'s waiting messages to it through its parent's host.
fn deliverWorker(root: *Runtime, arena: Allocator, entry: *@import("node_hosts.zig").Entry, node: Node) !WorkerDelivery {
    const b = bus(root);
    // Another thread carries this node's messages now; it, or the next
    // pump, takes these too.
    if (!b.claim(node.id)) return .later;
    defer b.unclaim(node.id);
    moveHeld(root, arena, entry.session, node.id) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .later;
    };
    const ready = blk: {
        b.lock();
        defer b.unlock();
        // One batch at a time keeps the mailbox's order: a steer that is
        // not applied puts its messages back in front (`tests/tla/jobs/Mailbox.tla`
        // InOrder).
        if ((try b.inflightLocked(arena, node.id, false)).len > 0) return .later;
        break :blk try waiting(arena, try entry.session.mailbox(arena), &.{}, null);
    };
    if (ready.len == 0) return .none;
    const built = (try agent_message.build(arena, node.label, ready)).?;
    const carried = ready[0..built.used];
    const parent = if (entry.parent) |above| above.runtime else root;
    // Names exactly these messages, so the same delivery again after a
    // restart finds its turn, and a different one never does.
    var hasher = std.hash.Wyhash.init(0);
    for (carried) |mail| {
        hasher.update(mail.id);
        hasher.update("\x00");
    }
    const operation_id = try arena.print("mail-{s}-{x}", .{ carried[0].id, hasher.final() });
    const delivery = fleet_host.deliverMail(parent, node.id, built.text, operation_id) catch |err| {
        debug_trace.logf("subagent", "mail delivery failed node_id={s} err={s}", .{ node.id, @errorName(err) });
        return .later;
    };
    switch (delivery) {
        .steered => |fingerprint| {
            const steer: Bus.Steer = .{
                .node_id = try b.alloc.dupe(u8, node.id),
                .parent_id = try b.alloc.dupe(u8, parent.node_id),
                .operation_id = try b.alloc.dupe(u8, operation_id),
                .fingerprint = fingerprint,
                .ids = try dupeIds(b.alloc, carried),
            };
            b.lock();
            defer b.unlock();
            b.steers.append(b.alloc, steer) catch |err| {
                steer.free(b.alloc);
                return err;
            };
            return .steered;
        },
        .turn => {
            // The turn's admission is durable in the parent's log, so the
            // messages leave the mailbox now (`tests/tla/jobs/Mailbox.tla` AdmitTurn).
            const ids = try arena.alloc([]const u8, carried.len);
            for (carried, ids) |mail, *id| id.* = mail.id;
            finishMail(root, arena, entry.session, ids, .delivered);
            return .turn;
        },
        .later => return .later,
        .terminal => {
            const ids = try arena.alloc([]const u8, ready.len);
            for (ready, ids) |mail, *id| id.* = mail.id;
            finishMail(root, arena, entry.session, ids, .dropped);
            return .terminal;
        },
    }
}

/// Settles steers whose outcome is known: applied messages leave their
/// mailbox, the rest wait again.
fn settleSteers(root: *Runtime, arena: Allocator) void {
    const b = bus(root);
    // Read each steer's outcome without the bus lock: the parent's host
    // has locks of its own.
    const open = blk: {
        b.lock();
        defer b.unlock();
        var copy: std.ArrayList(Bus.Steer) = .empty;
        for (b.steers.items) |steer| copy.append(arena, .{
            .node_id = arena.dupe(u8, steer.node_id) catch return,
            .parent_id = arena.dupe(u8, steer.parent_id) catch return,
            .operation_id = arena.dupe(u8, steer.operation_id) catch return,
            .fingerprint = steer.fingerprint,
            .ids = steer.ids,
        }) catch return;
        break :blk copy.items;
    };
    for (open) |view| {
        const state = steerState(root, view) orelse continue;
        // Hold the node's mailbox while its messages settle, so no delivery
        // reads them between leaving flight and leaving the mailbox.
        if (!b.claimWaiting(view.node_id)) continue;
        defer b.unclaim(view.node_id);
        if (state == .applied) {
            if (directory.pathOf(arena, root, view.node_id) catch null) |hops| {
                if (node_ops.lease(root, hops)) |entry| {
                    defer node_ops.release(root, entry);
                    finishMail(root, arena, entry.session, @ptrCast(view.ids), .delivered);
                } else |_| {}
            }
        }
        const steer = blk: {
            b.lock();
            defer b.unlock();
            for (b.steers.items, 0..) |candidate, index| {
                if (std.mem.eql(u8, candidate.operation_id, view.operation_id)) break :blk b.steers.orderedRemove(index);
            }
            continue;
        };
        steer.free(b.alloc);
        b.markPending(view.node_id);
        debug_trace.logf("subagent", "mail steer settled node_id={s} applied={}", .{ view.node_id, state == .applied });
    }
}

/// The steer's outcome once it is known; null while it is queued.
fn steerState(root: *Runtime, steer: Bus.Steer) ?types.SteeringDelivery {
    const Visit = struct {
        steer: Bus.Steer,
        fn visit(self: @This(), host: *Runtime) ?types.SteeringDelivery {
            // The delivery pinned its steer, so the outcome stays readable.
            const replay = host.managed.feedbackReplay(self.steer.operation_id, self.steer.fingerprint) orelse return .not_applied;
            const delivery = switch (replay) {
                .receipt => |delivery| delivery,
                else => return .not_applied,
            };
            if (delivery == .queued) return null;
            host.managed.acknowledgeFeedback(self.steer.node_id, self.steer.operation_id, delivery);
            host.managed.pinFeedback(self.steer.operation_id, false);
            return delivery;
        }
    };
    // A parent whose host closed took the steer with it.
    return root.tree.withHost(steer.parent_id, ?types.SteeringDelivery, Visit{ .steer = steer }, Visit.visit) orelse .not_applied;
}

/// Delivers every waiting worker message it can: the supervisor's tick
/// calls it, and so does every send. The first call reads every mailbox of
/// the tree and settles what a crash left (D188).
pub fn pump(root: *Runtime) void {
    var arena_state = std.heap.ArenaAllocator.init(root.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const b = bus(root);
    if (b.pending == null) recover(root, arena) catch |err| {
        debug_trace.logf("subagent", "mail recovery failed err={s}", .{@errorName(err)});
        return;
    };
    flushHeld(root, arena);
    settleSteers(root, arena);
    const ids = blk: {
        b.lock();
        defer b.unlock();
        const pending = b.pending orelse return;
        var copy: std.ArrayList([]const u8) = .empty;
        for (pending.keys()) |id| {
            if (std.mem.eql(u8, id, root.node_id)) continue;
            copy.append(arena, arena.dupe(u8, id) catch return) catch return;
        }
        break :blk copy.items;
    };
    if (ids.len == 0) return;
    const nodes = directory.list(arena, root) catch return;
    for (ids) |id| {
        const node = directory.find(nodes, id) orelse {
            b.clearPending(id);
            continue;
        };
        const entry = node_ops.lease(root, node.path) catch continue;
        defer node_ops.release(root, entry);
        const outcome = deliverWorker(root, arena, entry, node) catch continue;
        if (outcome == .none) b.clearPending(id);
    }
}

/// Reads every mailbox of the tree once: a waiting message the node's
/// history already holds reached its model before a restart and leaves as
/// delivered (`tests/tla/jobs/Mailbox.tla` Recover, ExactlyOnce); the rest wait.
fn recover(root: *Runtime, arena: Allocator) !void {
    const b = bus(root);
    const nodes = try directory.list(arena, root);
    var pending: std.array_hash_map.String(void) = .empty;
    errdefer {
        for (pending.keys()) |key| b.alloc.free(key);
        pending.deinit(b.alloc);
    }
    for (nodes) |node| {
        if (node.waiting == 0) continue;
        const store = root.tree.store;
        // A worker with no log yet counts only mail held for it (D212).
        const mailbox = store.peekMailbox(arena, node.id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const received = try receivedIds(arena, store, node.id, mailbox);
        if (received.len > 0) {
            if (node.depth == 0) {
                finishMail(root, arena, root.children.parent, received, .delivered);
            } else if (node_ops.lease(root, node.path)) |entry| {
                defer node_ops.release(root, entry);
                finishMail(root, arena, entry.session, received, .delivered);
            } else |_| {}
        }
        if (received.len < mailbox.len) {
            const owned = try b.alloc.dupe(u8, node.id);
            try pending.put(b.alloc, owned, {});
        }
    }
    b.lock();
    defer b.unlock();
    if (b.pending == null) b.pending = pending else {
        for (pending.keys()) |key| b.alloc.free(key);
        pending.deinit(b.alloc);
    }
}

/// The ids of `mailbox` that node `id`'s saved turns carry, as a prompt or
/// a steer. Owned by `arena`.
fn receivedIds(arena: Allocator, store: *session_adapter.Store, id: []const u8, mailbox: []const Mail) ![]const []const u8 {
    if (mailbox.len == 0) return &.{};
    const Visitor = struct {
        arena: Allocator,
        mailbox: []const Mail,
        found: std.ArrayList([]const u8) = .empty,

        fn note(self: *@This(), text: []const u8) !void {
            const at = std.mem.find(u8, text, agent_message.open_tag) orelse return;
            for (self.mailbox) |mail| {
                if (contains(self.found.items, mail.id)) continue;
                if (agent_message.carries(text[at..], mail.id)) try self.found.append(self.arena, mail.id);
            }
        }

        pub fn turn(self: *@This(), value: types.HistoryTurn, _: u64) !void {
            const user, const execution = switch (value) {
                .assistant => |entry| .{ entry.user, entry.execution },
                .interrupted => |entry| .{ entry.user, entry.execution },
                .compacted_summary => return,
            };
            try self.note(user.text);
            for (execution.steering) |steering| try self.note(steering.text);
        }
    };
    var visitor: Visitor = .{ .arena = arena, .mailbox = mailbox };
    store.visitTurns(arena, id, &visitor) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return visitor.found.items,
    };
    return visitor.found.items;
}

// ---------------------------------------------------------------------------
// The root's mail, delivered by the supervisor

pub const RootNotice = struct {
    text: []const u8,
    ids: []const []const u8,
};

/// The notice of the root's waiting messages, or null. The caller hands
/// `text` to the agent loop, then calls `rootAdmitted` with its request id.
pub fn takeRootNotice(root: *Runtime, arena: Allocator) !?RootNotice {
    const b = bus(root);
    if (io_mod.milliTimestamp() < b.root_retry_after_ms) return null;
    // An inbox read of the root's mailbox finishes first.
    if (!b.claim(root.node_id)) return null;
    defer b.unclaim(root.node_id);
    const ready = blk: {
        b.lock();
        defer b.unlock();
        if (b.root_waits > 0) return null;
        if (b.pending) |pending| if (!pending.contains(root.node_id)) return null;
        // One notice at a time keeps the mailbox's order (`tests/tla/jobs/Mailbox.tla` InOrder).
        if (b.root_notices.items.len > 0) return null;
        break :blk try waiting(arena, try root.children.parent.mailbox(arena), &.{}, null);
    };
    if (ready.len == 0) {
        b.clearPending(root.node_id);
        return null;
    }
    const built = (try agent_message.build(arena, "root", ready)).?;
    const carried = ready[0..built.used];
    const ids = try arena.alloc([]const u8, carried.len);
    for (carried, ids) |mail, *id| id.* = mail.id;
    // In flight from now, under request 0 until the loop admits it.
    const owned = try dupeIds(b.alloc, carried);
    b.lock();
    defer b.unlock();
    b.root_notices.append(b.alloc, .{ .request_id = 0, .ids = owned }) catch |err| {
        freeIds(b.alloc, owned);
        return err;
    };
    return .{ .text = built.text, .ids = ids };
}

/// The loop admitted the taken notice as request `request_id`: its
/// messages stay on their way until `rootAnswered`.
pub fn rootAdmitted(root: *Runtime, notice: RootNotice, request_id: i64) void {
    _ = notice;
    const b = bus(root);
    b.lock();
    defer b.unlock();
    for (b.root_notices.items) |*inflight| {
        if (inflight.request_id == 0) inflight.request_id = request_id;
    }
}

/// The loop refused the taken notice: its messages wait again.
pub fn rootRefused(root: *Runtime) void {
    const b = bus(root);
    b.lock();
    defer b.unlock();
    var index: usize = 0;
    while (index < b.root_notices.items.len) {
        if (b.root_notices.items[index].request_id == 0) {
            freeIds(b.alloc, b.root_notices.orderedRemove(index).ids);
        } else index += 1;
    }
}

/// The loop answered root notice `request_id`: `delivered` when the model
/// got it, as a steer the turn took or the prompt of a turn it ran.
pub fn rootAnswered(root: *Runtime, request_id: i64, delivered: bool) void {
    const b = bus(root);
    const ids = blk: {
        b.lock();
        defer b.unlock();
        for (b.root_notices.items, 0..) |notice, index| {
            if (notice.request_id == request_id) break :blk b.root_notices.orderedRemove(index).ids;
        }
        return;
    };
    defer freeIds(b.alloc, ids);
    var arena_state = std.heap.ArenaAllocator.init(root.alloc);
    defer arena_state.deinit();
    if (delivered) {
        const borrowed: []const []const u8 = @ptrCast(ids);
        finishMail(root, arena_state.allocator(), root.children.parent, borrowed, .delivered);
    } else {
        b.root_retry_after_ms = io_mod.milliTimestamp() + undelivered_retry_ms;
        b.markPending(root.node_id);
    }
}

/// Whether the root has waiting messages no notice carries yet.
pub fn rootHasMail(root: *Runtime) bool {
    const b = bus(root);
    b.lock();
    defer b.unlock();
    const pending = b.pending orelse return false;
    return pending.contains(root.node_id);
}

/// Posts a message to the root's mailbox from something that is not an
/// agent: a watch reporting a match (D190). `from` is the watch's job id.
pub fn postToRoot(root: *Runtime, from: []const u8, label: []const u8, body: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(root.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const clipped = body[0..@min(body.len, session_adapter.max_mail_body_bytes)];
    const id = try session_store.generateSessionId(arena);
    _ = try post(root, arena, root.children.parent, root.node_id, .{ .mail = .{ .id = id, .from = from, .label = label, .body = clipped } });
    bus(root).changed();
}

// ---------------------------------------------------------------------------
// Reading a mailbox

/// `node`'s waiting messages, oldest first, without those on their way to
/// its model. Unless `peek`, they leave the mailbox as read. With `from`,
/// only that sender's. Owned by `arena`.
pub fn inbox(node: *Runtime, arena: Allocator, peek: bool, from: ?[]const u8) ![]Mail {
    const root = rootHost(node);
    const b = bus(root);
    const is_root = node == root;
    if (!b.claimWaiting(node.node_id)) return &.{};
    defer b.unclaim(node.node_id);
    if (!is_root) try moveHeld(root, arena, node.children.parent, node.node_id);
    const ready = blk: {
        b.lock();
        defer b.unlock();
        // Messages on their way to the model now reach it first; the rest
        // wait behind them, in order.
        if ((try b.inflightLocked(arena, node.node_id, is_root)).len > 0) return &.{};
        break :blk try waiting(arena, try node.children.parent.mailbox(arena), &.{}, from);
    };
    if (!peek and ready.len > 0) {
        const ids = try arena.alloc([]const u8, ready.len);
        for (ready, ids) |mail, *id| id.* = mail.id;
        finishMail(root, arena, node.children.parent, ids, .read);
    }
    return ready;
}

/// Waits up to `timeout_ms` for a message in the root's mailbox, from
/// `from` when given, and takes what waits as read. Automatic delivery
/// leaves the root's mail to the wait while it waits (`tests/tla/jobs/Mailbox.tla`
/// NoDeliveryUnderWait). Empty when the window passed.
pub fn waitRoot(root: *Runtime, arena: Allocator, from: ?[]const u8, timeout_ms: u64, cancel: ?*const std.atomic.Value(bool)) ![]Mail {
    const b = bus(root);
    {
        b.lock();
        defer b.unlock();
        b.root_waits += 1;
    }
    defer {
        b.lock();
        b.root_waits -= 1;
        b.unlock();
    }
    const deadline = io_mod.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (true) {
        const seen = b.generation.load(.seq_cst);
        const taken = try inbox(root, arena, false, from);
        if (taken.len > 0) return taken;
        if (cancel) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        if (io_mod.milliTimestamp() >= deadline) return &.{};
        while (b.generation.load(.seq_cst) == seen and io_mod.milliTimestamp() < deadline) {
            if (cancel) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
            io_mod.sleep(25 * std.time.ns_per_ms);
        }
    }
}

test {
    _ = agent_message;
    _ = directory;
    _ = @import("mailbox_tests.zig");
}
