//! `fx thread`: a read-only view of the threads a saved session started.
//!
//! Threads run inside an interactive fx process, so this reads what that
//! process saved: the thread list under `~/.fx/threads/`, each thread's saved
//! child state, and its saved session. It never reports live state.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const child_state = @import("../subagent/child_state.zig");
const resume_admission = @import("../subagent/resume_admission.zig");
const output_contracts = @import("../output/output_contracts.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const thread_registry = @import("../threads/thread_registry.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const not_started_state = "not_started";
/// The registry names a started thread but its child state is gone.
pub const unknown_state = "unknown";

pub const Error = error{
    InvalidThreadArgs,
    /// No such thread in the session's saved list.
    ThreadNotFound,
    /// The saved thread list is unreadable.
    InvalidThreadRegistry,
    /// Threads are recorded only for the default session format.
    ThreadsNeedDefaultSessionFormat,
};

pub const SessionTarget = union(enum) {
    last,
    id: []u8,
};

pub const Action = union(enum) {
    list,
    show: []u8,
};

pub const Options = struct {
    format: output_contracts.OutputFormat = .text,
    action: Action = .list,
    session: SessionTarget = .last,

    pub fn deinit(self: *Options, alloc: Allocator) void {
        switch (self.action) {
            .list => {},
            .show => |name| alloc.free(name),
        }
        switch (self.session) {
            .last => {},
            .id => |id| alloc.free(id),
        }
        self.* = undefined;
    }
};

/// `[list] [SESSION] [--json]` or `show NAME [SESSION] [--json]`. A first
/// word other than `list` and `show` is the session. Caller owns the result.
pub fn parseArgs(alloc: Allocator, args: []const [:0]const u8) !Options {
    var options = Options{};
    errdefer options.deinit(alloc);

    var positionals: [3][]const u8 = undefined;
    var count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidThreadArgs;
        const trimmed = std.mem.trim(u8, arg, " \t\r\n");
        if (trimmed.len == 0 or count == positionals.len) return error.InvalidThreadArgs;
        positionals[count] = trimmed;
        count += 1;
    }

    var rest: []const []const u8 = positionals[0..count];
    var show = false;
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "show")) {
        show = true;
        rest = rest[1..];
        if (rest.len == 0) return error.InvalidThreadArgs;
        options.action = .{ .show = try alloc.dupe(u8, rest[0]) };
        rest = rest[1..];
    } else if (rest.len > 0 and std.mem.eql(u8, rest[0], "list")) {
        rest = rest[1..];
    }
    if (rest.len > 1) return error.InvalidThreadArgs;
    if (rest.len == 1 and !std.mem.eql(u8, rest[0], "last")) {
        options.session = .{ .id = try alloc.dupe(u8, rest[0]) };
    }
    return options;
}

/// A loaded snapshot together with the memory its strings borrow from.
pub fn Loaded(comptime Snapshot: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        snapshot: Snapshot,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// The root session a command names: the latest visible session of the
/// store's workspace for `last`, else the exact id, which must be visible
/// (not missing and not a managed child). Caller owns the result.
pub fn resolveRoot(alloc: Allocator, store: *session_store.Store, target: SessionTarget) ![]u8 {
    switch (target) {
        .last => {
            var summary = try resume_admission.latestVisibleWorkspaceSummary(store.*, alloc);
            defer summary.deinit(alloc);
            return alloc.dupe(u8, summary.id);
        },
        .id => |id| {
            var detail = try resume_admission.loadVisibleReadOnlyDetail(store.*, alloc, id, .{});
            detail.deinit(alloc);
            return alloc.dupe(u8, id);
        },
    }
}

pub fn loadList(
    parent: Allocator,
    store: *session_store.Store,
    home: []const u8,
    root_id: []const u8,
) !Loaded(output_contracts.ThreadListSnapshot) {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var registry = try loadRegistry(parent, home, root_id);
    defer registry.deinit(parent);
    var children = try child_state.Store.load(.{ .backend = .{ .v1 = store }, .parent_id = root_id }, parent);
    defer children.deinit(parent);

    const entries = try alloc.alloc(output_contracts.ThreadListEntry, registry.threads.items.len);
    for (registry.threads.items, entries) |thread, *entry| {
        entry.* = try entryFor(alloc, thread, &children);
    }
    // Allocate before moving the arena: the allocator points at this frame's copy.
    const owned_root = try alloc.dupe(u8, root_id);
    return .{
        .arena = arena,
        .snapshot = .{ .root_session_id = owned_root, .threads = entries },
    };
}

pub fn loadDetail(
    parent: Allocator,
    store: *session_store.Store,
    home: []const u8,
    root_id: []const u8,
    name: []const u8,
) !Loaded(output_contracts.ThreadDetailSnapshot) {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var registry = try loadRegistry(parent, home, root_id);
    defer registry.deinit(parent);
    const thread = switch (registry.resolve(name)) {
        .found => |found| found,
        // An unknown or ambiguous name is the same answer here: nothing to show.
        .none, .ambiguous => return error.ThreadNotFound,
    };
    var children = try child_state.Store.load(.{ .backend = .{ .v1 = store }, .parent_id = root_id }, parent);
    defer children.deinit(parent);

    var snapshot = output_contracts.ThreadDetailSnapshot{
        .root_session_id = try alloc.dupe(u8, root_id),
        .entry = try entryFor(alloc, thread.*, &children),
    };
    if (thread.session_id.len > 0) {
        var detail = store.loadReadOnlyAdmissionDetail(parent, thread.session_id, .{}) catch |err| switch (err) {
            // A thread that never saved a turn has no history to read.
            error.SessionNotFound, error.ConversationHistoryUnavailable => return .{ .arena = arena, .snapshot = snapshot },
            else => return err,
        };
        defer detail.deinit(parent);
        snapshot.turns = turnCount(detail.state.history);
        if (lastReply(detail.state.history)) |reply| {
            var encoded = try output_contracts.threadReplyForDisplay(parent, reply);
            defer encoded.deinit(parent);
            snapshot.last_reply = try alloc.dupe(u8, encoded.bytes);
            snapshot.last_reply_truncated = encoded.truncated;
        }
    }
    return .{ .arena = arena, .snapshot = snapshot };
}

fn loadRegistry(alloc: Allocator, home: []const u8, root_id: []const u8) !thread_registry.Registry {
    return thread_registry.load(alloc, home, root_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRegistry => return error.InvalidThreadRegistry,
        else => return error.InvalidThreadRegistry,
    };
}

fn entryFor(
    alloc: Allocator,
    thread: thread_registry.Thread,
    children: *child_state.Registry,
) !output_contracts.ThreadListEntry {
    var state: []const u8 = not_started_state;
    var outcome: ?[]const u8 = null;
    if (thread.session_id.len > 0) {
        if (children.findPersistent(thread.agent)) |child| {
            state = @tagName(child.phase);
            if (child.last_outcome) |value| outcome = @tagName(value);
        } else {
            state = unknown_state;
        }
    }
    return .{
        .name = try alloc.dupe(u8, thread.name),
        .session_id = try alloc.dupe(u8, thread.session_id),
        .state = state,
        .last_outcome = outcome,
    };
}

fn turnCount(history: []const types.HistoryTurn) usize {
    var count: usize = 0;
    for (history) |turn| {
        switch (turn) {
            .compacted_summary => {},
            .assistant, .interrupted => count += 1,
        }
    }
    return count;
}

/// The newest non-empty assistant text. Borrows from `history`.
fn lastReply(history: []const types.HistoryTurn) ?[]const u8 {
    var i = history.len;
    while (i > 0) {
        i -= 1;
        const text: []const u8 = switch (history[i]) {
            .assistant => |entry| entry.assistant,
            .interrupted => |entry| entry.assistant orelse "",
            .compacted_summary => "",
        };
        if (text.len > 0) return text;
    }
    return null;
}

/// A message for the failures this command adds. Other errors fall to the
/// shared session lookup messages.
pub fn failureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidThreadArgs => "invalid arguments",
        error.ThreadNotFound => "thread not found in that session",
        error.InvalidThreadRegistry => "the saved thread list is unreadable",
        error.ThreadsNeedDefaultSessionFormat => "threads need the default session format; run without --sessions-v2",
        else => null,
    };
}

// Tests

fn testArgs(comptime items: []const []const u8) [items.len][:0]const u8 {
    var out: [items.len][:0]const u8 = undefined;
    inline for (items, 0..) |item, i| out[i] = item[0..item.len :0];
    return out;
}

test "parseArgs reads list, show, session, and json in any order" {
    const alloc = std.testing.allocator;

    var bare = try parseArgs(alloc, &.{});
    defer bare.deinit(alloc);
    try std.testing.expect(bare.action == .list);
    try std.testing.expect(bare.session == .last);
    try std.testing.expectEqual(output_contracts.OutputFormat.text, bare.format);

    const list_args = testArgs(&.{ "list", "sess-1", "--json" });
    var list = try parseArgs(alloc, &list_args);
    defer list.deinit(alloc);
    try std.testing.expect(list.action == .list);
    try std.testing.expectEqualStrings("sess-1", list.session.id);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, list.format);

    const session_only = testArgs(&.{"sess-2"});
    var only = try parseArgs(alloc, &session_only);
    defer only.deinit(alloc);
    try std.testing.expect(only.action == .list);
    try std.testing.expectEqualStrings("sess-2", only.session.id);

    const last_args = testArgs(&.{ "--json", "last" });
    var last = try parseArgs(alloc, &last_args);
    defer last.deinit(alloc);
    try std.testing.expect(last.session == .last);

    const show_args = testArgs(&.{ "show", "alpha", "--json" });
    var show = try parseArgs(alloc, &show_args);
    defer show.deinit(alloc);
    try std.testing.expectEqualStrings("alpha", show.action.show);
    try std.testing.expect(show.session == .last);

    const show_session = testArgs(&.{ "show", "alpha", "sess-3" });
    var with_session = try parseArgs(alloc, &show_session);
    defer with_session.deinit(alloc);
    try std.testing.expectEqualStrings("sess-3", with_session.session.id);
}

test "parseArgs rejects malformed commands" {
    const alloc = std.testing.allocator;
    const cases = [_][]const []const u8{
        &.{"show"},
        &.{ "show", "--json" },
        &.{ "list", "a", "b" },
        &.{ "show", "a", "b", "c" },
        &.{"--bogus"},
        &.{""},
        &.{ "a", "b" },
    };
    inline for (cases) |case| {
        const args = comptime testArgs(case);
        try std.testing.expectError(error.InvalidThreadArgs, parseArgs(alloc, &args));
    }
}

fn testState(alloc: Allocator, id: []const u8, workspace: []const u8, reply: ?[]const u8) !session_codec.DurableSessionState {
    const history = try alloc.alloc(session.HistoryTurn, if (reply == null) 0 else 1);
    errdefer alloc.free(history);
    if (reply) |text| {
        history[0] = .{ .assistant = .{
            .user = try session.dupeUserTurn(alloc, .{ .text = @constCast("do the thing") }),
            .assistant = try alloc.dupe(u8, text),
        } };
    }
    return .{
        .id = try alloc.dupe(u8, id),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{
            .model = try alloc.dupe(u8, "test"),
            .effort = .auto,
            .fast_mode = false,
        },
    };
}

test "loadList and loadDetail report saved thread state, reply, and turns" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);

    var root = try testState(alloc, "root", workspace, null);
    defer root.deinit(alloc);
    var root_session = try store.startWritableSession(alloc, root);
    root_session.deinit(alloc);
    var child = try testState(alloc, "child", workspace, "all done AI_GATEWAY_API_KEY=abcdefghijklmnop \x1b[31m");
    defer child.deinit(alloc);
    child.subagent_child = true;
    var child_session = try store.startWritableSession(alloc, child);
    child_session.deinit(alloc);

    // alpha ran and finished a turn; beta was registered but never started.
    var registry = try thread_registry.Registry.init(alloc, "root");
    defer registry.deinit(alloc);
    try registry.add(alloc, "alpha", "th-1-alpha", 1);
    try registry.setSession(alloc, "alpha", "child");
    try registry.add(alloc, "beta", "th-2-beta", 2);
    try thread_registry.save(alloc, home, &registry);

    var state = try child_state.Registry.init(alloc, "root");
    defer state.deinit(alloc);
    state.children = try alloc.alloc(child_state.Child, 1);
    state.children[0] = .{
        .id = try alloc.dupe(u8, "child"),
        .kind = .{ .persistent = .{ .agent = try alloc.dupe(u8, "th-1-alpha"), .instructions = &.{} } },
        .phase = .interrupted,
        .last_outcome = .interrupted,
    };
    try (child_state.Store{ .backend = .{ .v1 = &store }, .parent_id = "root" }).save(alloc, state);
    try (child_state.Store{ .backend = .{ .v1 = &store }, .parent_id = "root" }).markChildSession(alloc, "child");

    var list = try loadList(alloc, &store, home, "root");
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.snapshot.threads.len);
    try std.testing.expectEqualStrings("alpha", list.snapshot.threads[0].name);
    try std.testing.expectEqualStrings("interrupted", list.snapshot.threads[0].state);
    try std.testing.expectEqualStrings("interrupted", list.snapshot.threads[0].last_outcome.?);
    try std.testing.expectEqualStrings(not_started_state, list.snapshot.threads[1].state);
    try std.testing.expect(list.snapshot.threads[1].last_outcome == null);

    var detail = try loadDetail(alloc, &store, home, "root", "alpha");
    defer detail.deinit();
    try std.testing.expectEqual(@as(usize, 1), detail.snapshot.turns);
    try std.testing.expectEqualStrings("child", detail.snapshot.entry.session_id);
    const reply = detail.snapshot.last_reply.?;
    try std.testing.expect(std.mem.find(u8, reply, "all done") != null);
    try std.testing.expect(std.mem.find(u8, reply, "abcdefghijklmnop") == null);
    try std.testing.expect(std.mem.findScalar(u8, reply, 0x1b) == null);

    var unstarted = try loadDetail(alloc, &store, home, "root", "beta");
    defer unstarted.deinit();
    try std.testing.expectEqualStrings(not_started_state, unstarted.snapshot.entry.state);
    try std.testing.expect(unstarted.snapshot.last_reply == null);
    try std.testing.expectEqual(@as(usize, 0), unstarted.snapshot.turns);

    try std.testing.expectError(error.ThreadNotFound, loadDetail(alloc, &store, home, "root", "nope"));

    const resolved = try resolveRoot(alloc, &store, .{ .id = @constCast("root") });
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("root", resolved);
    try std.testing.expectError(error.SessionNotFound, resolveRoot(alloc, &store, .{ .id = @constCast("child") }));
    try std.testing.expectError(error.SessionNotFound, resolveRoot(alloc, &store, .{ .id = @constCast("absent") }));

    // A session that never started a thread has no list and no child state.
    var bare = try testState(alloc, "bare", workspace, null);
    defer bare.deinit(alloc);
    var bare_session = try store.startWritableSession(alloc, bare);
    bare_session.deinit(alloc);
    var none = try loadList(alloc, &store, home, "bare");
    defer none.deinit();
    try std.testing.expectEqual(@as(usize, 0), none.snapshot.threads.len);
}

test "an unreadable thread list is its own error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx/threads");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.fx/threads/root.json", .data = "not json" });
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    try std.testing.expectError(error.InvalidThreadRegistry, loadList(alloc, &store, home, "root"));
}
