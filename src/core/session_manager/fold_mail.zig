//! A node's mailbox in the fold (D185): the messages other agents of its
//! tree sent it that have not left it yet, oldest first. A `mail` line adds
//! one and a `mail_done` line with its id takes it out, so the mailbox
//! survives a restart and a resume exactly as the log has it
//! (`tests/tla/jobs/Mailbox.tla` NoLossAcrossRestart).
const std = @import("std");
const fold = @import("fold.zig");
const schema = @import("schema.zig");

const State = fold.State;
const Event = fold.Event;

/// The most messages one mailbox holds, as proto's bus keeps (D185). A
/// sender that finds it full drops the oldest in the same batch.
pub const max_mailbox: usize = 100;
/// The longest message body a line carries.
pub const max_body_bytes: usize = 16 * 1024;

/// One waiting message. Owns its slices.
pub const Mail = struct {
    id: []u8,
    /// The `mail` line's seq: the mailbox's order.
    seq: u64,
    from: []u8,
    label: []u8,
    body: []u8,
    reply_to: ?[]u8 = null,
    broadcast: bool = false,
    /// Held here for this worker, which has no log yet (D212); null for
    /// this node's own mail.
    hold_for: ?[]u8 = null,

    pub fn deinit(mail: Mail, gpa: std.mem.Allocator) void {
        gpa.free(mail.id);
        gpa.free(mail.from);
        gpa.free(mail.label);
        gpa.free(mail.body);
        if (mail.reply_to) |value| gpa.free(value);
        if (mail.hold_for) |value| gpa.free(value);
    }

    /// Whether this is the node's own mail, not mail held for a worker.
    pub fn own(mail: Mail) bool {
        return mail.hold_for == null;
    }

    pub fn clone(mail: Mail, gpa: std.mem.Allocator) error{OutOfMemory}!Mail {
        return fromBody(gpa, mail.seq, .{
            .id = mail.id,
            .from = mail.from,
            .label = mail.label,
            .body = mail.body,
            .reply_to = mail.reply_to,
            .broadcast = mail.broadcast,
            .hold_for = mail.hold_for,
        });
    }

    fn eql(a: Mail, b: Mail) bool {
        const reply_same = optionalEql(a.reply_to, b.reply_to);
        return a.seq == b.seq and a.broadcast == b.broadcast and reply_same and optionalEql(a.hold_for, b.hold_for) and
            std.mem.eql(u8, a.id, b.id) and std.mem.eql(u8, a.from, b.from) and
            std.mem.eql(u8, a.label, b.label) and std.mem.eql(u8, a.body, b.body);
    }
};

fn fromBody(gpa: std.mem.Allocator, seq: u64, body: schema.Body.Mail) error{OutOfMemory}!Mail {
    const id = try gpa.dupe(u8, body.id);
    errdefer gpa.free(id);
    const from = try gpa.dupe(u8, body.from);
    errdefer gpa.free(from);
    const label = try gpa.dupe(u8, body.label);
    errdefer gpa.free(label);
    const text = try gpa.dupe(u8, body.body);
    errdefer gpa.free(text);
    const reply_to = if (body.reply_to) |value| try gpa.dupe(u8, value) else null;
    errdefer if (reply_to) |value| gpa.free(value);
    const hold_for = if (body.hold_for) |value| try gpa.dupe(u8, value) else null;
    return .{ .id = id, .seq = seq, .from = from, .label = label, .body = text, .reply_to = reply_to, .broadcast = body.broadcast, .hold_for = hold_for };
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn find(mailbox: []const Mail, id: []const u8) ?usize {
    for (mailbox, 0..) |mail, index| if (std.mem.eql(u8, mail.id, id)) return index;
    return null;
}

/// Folds a `mail` line.
pub fn receive(gpa: std.mem.Allocator, state: *State, seq: u64, body: schema.Body.Mail) error{OutOfMemory}!void {
    if (find(state.mailbox.items, body.id) != null) return;
    const mail = try fromBody(gpa, seq, body);
    errdefer mail.deinit(gpa);
    try state.mailbox.append(gpa, mail);
}

/// Folds a `mail_done` line.
pub fn finish(gpa: std.mem.Allocator, state: *State, id: []const u8) void {
    const index = find(state.mailbox.items, id) orelse return;
    state.mailbox.orderedRemove(index).deinit(gpa);
}

/// Whether message `id` waits after `earlier` events of a batch.
fn pendingAt(state: *const State, earlier: []const Event, id: []const u8) bool {
    var pending = find(state.mailbox.items, id) != null;
    for (earlier) |event| switch (event) {
        .mail => |m| if (std.mem.eql(u8, m.id, id)) {
            pending = true;
        },
        .mail_done => |d| if (std.mem.eql(u8, d.id, id)) {
            pending = false;
        },
        else => {},
    };
    return pending;
}

/// The waiting messages of one box after `earlier` events of a batch: the
/// node's own (`box` null) or those held for worker `box` (D212).
fn countAt(state: *const State, earlier: []const Event, box: ?[]const u8) usize {
    var count: usize = 0;
    for (state.mailbox.items) |mail| {
        if (optionalEql(mail.hold_for, box)) count += 1;
    }
    for (earlier, 0..) |event, index| switch (event) {
        .mail => |m| if (optionalEql(m.hold_for, box)) {
            count += 1;
        },
        .mail_done => |d| if (boxOfAt(state, earlier[0..index], d.id)) |found| {
            if (optionalEql(found, box)) count -|= 1;
        },
        else => {},
    };
    return count;
}

/// The box of message `id` waiting after `earlier` events, or null when it
/// does not wait. The inner optional is the box itself.
fn boxOfAt(state: *const State, earlier: []const Event, id: []const u8) ??[]const u8 {
    var box: ??[]const u8 = if (find(state.mailbox.items, id)) |index| state.mailbox.items[index].hold_for else null;
    for (earlier) |event| switch (event) {
        .mail => |m| if (std.mem.eql(u8, m.id, id)) {
            box = m.hold_for;
        },
        .mail_done => |d| if (std.mem.eql(u8, d.id, id)) {
            box = null;
        },
        else => {},
    };
    return box;
}

/// A `mail` line names a message not waiting already, and a full box takes
/// one only after a drop earlier in the batch (`tests/tla/jobs/Mailbox.tla`
/// Bounded). Mail held for a worker counts against that worker's box, not
/// this node's. Any time, inside a turn or between turns.
pub fn planMail(state: *const State, earlier: []const Event, body: schema.Body.Mail) fold.TransitionError!void {
    if (pendingAt(state, earlier, body.id)) return error.InvalidTransition;
    if (countAt(state, earlier, body.hold_for) >= max_mailbox) return error.InvalidTransition;
}

/// A `mail_done` line names a message that waits.
pub fn planDone(state: *const State, earlier: []const Event, done: schema.Body.MailDone) fold.TransitionError!void {
    if (!pendingAt(state, earlier, done.id)) return error.InvalidTransition;
}

pub fn eql(a: []const Mail, b: []const Mail) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

/// `,"mailbox":[...]`, written only when a message waits, so older
/// snapshots read the same.
pub fn encode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), mailbox: []const Mail) error{OutOfMemory}!void {
    if (mailbox.len == 0) return;
    try out.appendSlice(gpa, ",\"mailbox\":[");
    for (mailbox, 0..) |mail, index| {
        if (index > 0) try out.append(gpa, ',');
        try out.print(gpa, "{{\"seq\":{d}", .{mail.seq});
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(gpa);
        try schema.appendBody(gpa, &body, .{ .mail = .{
            .id = mail.id,
            .from = mail.from,
            .label = mail.label,
            .body = mail.body,
            .reply_to = mail.reply_to,
            .broadcast = mail.broadcast,
            .hold_for = mail.hold_for,
        } });
        try out.appendSlice(gpa, body.items);
        try out.append(gpa, '}');
    }
    try out.append(gpa, ']');
}

pub fn decode(gpa: std.mem.Allocator, arena: std.mem.Allocator, state: *State, raw: []const u8) schema.BodyError!void {
    for (try schema.rawElements(arena, raw)) |raw_mail| {
        const f = try schema.Fields.parseObject(arena, raw_mail);
        const seq = try f.req(u64, "seq");
        const body = (try schema.parseLineBody(arena, .mail, try std.mem.concat(arena, u8, &.{ raw_mail, "\n" }))).mail;
        const mail = try fromBody(gpa, seq, body);
        errdefer mail.deinit(gpa);
        try state.mailbox.append(gpa, mail);
    }
}

const testing = std.testing;

test "the mailbox folds mail lines, takes out finished ones and refuses a full or repeated id" {
    const gpa = testing.allocator;
    var state: State = .{};
    defer state.deinit(gpa);
    try receive(gpa, &state, 4, .{ .id = "m1", .from = "a", .label = "alpha", .body = "hi", .reply_to = "m0" });
    try receive(gpa, &state, 5, .{ .id = "m2", .from = "b", .body = "yo", .broadcast = true });
    try testing.expectEqual(@as(usize, 2), state.mailbox.items.len);
    try testing.expectError(error.InvalidTransition, planMail(&state, &.{}, .{ .id = "m1", .from = "a", .body = "again" }));
    try planDone(&state, &.{}, .{ .id = "m1", .how = .delivered });
    try testing.expectError(error.InvalidTransition, planDone(&state, &.{.{ .mail_done = .{ .id = "m1", .how = .read } }}, .{ .id = "m1", .how = .read }));

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    try encoded.appendSlice(gpa, "{\"x\":1");
    try encode(gpa, &encoded, state.mailbox.items);
    try encoded.append(gpa, '}');
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var decoded: State = .{};
    defer decoded.deinit(gpa);
    const f = try schema.Fields.parseObject(arena.allocator(), encoded.items);
    try decode(gpa, arena.allocator(), &decoded, f.raw("mailbox").?);
    try testing.expect(eql(state.mailbox.items, decoded.mailbox.items));
    try testing.expectEqualStrings("m0", decoded.mailbox.items[0].reply_to.?);
    try testing.expect(decoded.mailbox.items[1].broadcast);

    finish(gpa, &state, "m1");
    try testing.expectEqualStrings("m2", state.mailbox.items[0].id);
    var index: usize = 0;
    while (state.mailbox.items.len < max_mailbox) : (index += 1) {
        var buf: [16]u8 = undefined;
        try receive(gpa, &state, 10 + index, .{ .id = try std.mem.print(&buf, "f{d}", .{index}), .from = "a", .body = "x" });
    }
    try testing.expectError(error.InvalidTransition, planMail(&state, &.{}, .{ .id = "new", .from = "a", .body = "x" }));
    // Dropping the oldest in the same batch makes room.
    try planMail(&state, &.{.{ .mail_done = .{ .id = "m2", .how = .dropped } }}, .{ .id = "new", .from = "a", .body = "x" });
}

test "mail held for a worker keeps its own box and survives a snapshot" {
    const gpa = testing.allocator;
    var state: State = .{};
    defer state.deinit(gpa);
    var index: usize = 0;
    while (index < max_mailbox) : (index += 1) {
        var buf: [16]u8 = undefined;
        try receive(gpa, &state, 1 + index, .{ .id = try std.mem.print(&buf, "own{d}", .{index}), .from = "a", .body = "x" });
    }
    // A full own mailbox still takes mail held for a worker.
    try planMail(&state, &.{}, .{ .id = "h1", .from = "a", .body = "for w", .hold_for = "w1" });
    try receive(gpa, &state, 500, .{ .id = "h1", .from = "a", .label = "alpha", .body = "for w", .hold_for = "w1" });
    try testing.expectError(error.InvalidTransition, planMail(&state, &.{}, .{ .id = "own-new", .from = "a", .body = "x" }));
    try testing.expect(!state.mailbox.items[state.mailbox.items.len - 1].own());

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    try encoded.appendSlice(gpa, "{\"x\":1");
    try encode(gpa, &encoded, state.mailbox.items);
    try encoded.append(gpa, '}');
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var decoded: State = .{};
    defer decoded.deinit(gpa);
    const f = try schema.Fields.parseObject(arena.allocator(), encoded.items);
    try decode(gpa, arena.allocator(), &decoded, f.raw("mailbox").?);
    try testing.expect(eql(state.mailbox.items, decoded.mailbox.items));
    try testing.expectEqualStrings("w1", decoded.mailbox.items[decoded.mailbox.items.len - 1].hold_for.?);

    // A held box is bounded on its own, and a drop in the batch makes room.
    var held: State = .{};
    defer held.deinit(gpa);
    index = 0;
    while (index < max_mailbox) : (index += 1) {
        var buf: [16]u8 = undefined;
        try receive(gpa, &held, 1 + index, .{ .id = try std.mem.print(&buf, "h{d}", .{index}), .from = "a", .body = "x", .hold_for = "w1" });
    }
    try testing.expectError(error.InvalidTransition, planMail(&held, &.{}, .{ .id = "h-new", .from = "a", .body = "x", .hold_for = "w1" }));
    try planMail(&held, &.{}, .{ .id = "h-other", .from = "a", .body = "x", .hold_for = "w2" });
    try planMail(&held, &.{.{ .mail_done = .{ .id = "h0", .how = .dropped } }}, .{ .id = "h-new", .from = "a", .body = "x", .hold_for = "w1" });
}
