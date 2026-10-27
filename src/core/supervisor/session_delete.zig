//! Deletes a supervised session on its own executor (D100 in
//! `tests/tla/session_manager/system-design.md`). The executor is the only
//! thread that starts work on the session, so the check that nothing is
//! running and the stop that follows it see the same state. The record is
//! saved as stopped before any file goes, so a restart after a crash never
//! reopens a half-deleted session; the accept loop drops the retired row and
//! saves the registry last.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const session_adapter = @import("../session/session_adapter.zig");
const kernel_slot = @import("../kernel/slot.zig");
const protocol = @import("protocol.zig");
const child_views = @import("child_views.zig");
const Session = @import("session.zig").Session;
const Allocator = std.mem.Allocator;

/// Why a delete was refused. Each has the text the client shows.
pub const Refusal = enum {
    in_use,
    busy,
    heartbeat,
    legacy,
    held_elsewhere,

    pub fn text(self: Refusal) []const u8 {
        return switch (self) {
            .in_use => "The session is open in another view and was not deleted.",
            .busy => "The session is still working and was not deleted.",
            .heartbeat => "The session has an active heartbeat. Pause it with /heartbeat pause, then delete.",
            .legacy => "This session was saved by an older version and cannot be deleted here.",
            .held_elsewhere => "Another fx process has the session open, so it was not deleted.",
        };
    }
};

/// Runs on `session`'s executor. Answers an Ack, or a failure naming the
/// refusal. On success the session is retired and the accept loop drops it.
pub fn run(session: *Session, arena: Allocator) ![]const u8 {
    if (session.id.len == 0) return error.SessionNotFound;
    if (try refusal(session, arena)) |why| return refuse(arena, why);
    const alloc = session.daemon.alloc;
    var store = try session_adapter.Store.open(alloc, session.daemon.home);
    defer store.deinit(alloc);
    const family = session_adapter.sessionFamily(&store, alloc, session.id) catch |err| switch (err) {
        error.SessionLegacy => return refuse(arena, .legacy),
        // Never saved: only the row and the folders beside it remain.
        error.SessionNotFound => try only(alloc, session.id),
        else => return err,
    };
    defer {
        for (family) |member| alloc.free(member);
        alloc.free(family);
    }
    // Saved as stopped, and the host closed, before anything is removed.
    _ = try session.stop(arena);
    session_adapter.deleteSession(&store, family) catch |err| switch (err) {
        error.SessionBusy => return refuse(arena, .held_elsewhere),
        else => return err,
    };
    for (family) |member| if (!kernel_slot.removeSaved(alloc, session.daemon.home, member)) {
        debug_trace.logf("supervisor", "event=kernel_files_kept session={s}", .{member});
    };
    session.retired.store(true, .release);
    return protocol.encode(arena, protocol.Ack{});
}

fn refuse(arena: Allocator, why: Refusal) ![]const u8 {
    return protocol.encode(arena, protocol.Failure{ .@"error" = why.text() });
}

fn only(alloc: Allocator, id: []const u8) ![][]u8 {
    const list = try alloc.alloc([]u8, 1);
    errdefer alloc.free(list);
    list[0] = try alloc.dupe(u8, id);
    return list;
}

/// What keeps `session` from being deleted now. Executor-only: it reads the
/// host and the record the executor owns.
fn refusal(session: *Session, arena: Allocator) !?Refusal {
    {
        session.watchers.mutex.lockUncancelable(io_mod.getIo());
        defer session.watchers.mutex.unlock(io_mod.getIo());
        if (session.watchers.items.items.len > 0) return .in_use;
    }
    {
        session.jobs_mutex.lockUncancelable(io_mod.getIo());
        defer session.jobs_mutex.unlock(io_mod.getIo());
        if (session.jobs.items.len > 0) return .busy;
    }
    if (session.pendingCount() > 0 or session.record.running) return .busy;
    if (session.record.heartbeatArmed()) return .heartbeat;
    const host = session.host orelse return null;
    if (host.busy()) return .busy;
    // An unreadable registry refuses rather than cut a child's work short.
    if (child_views.anyRunning(arena, host, session.id) catch true) return .busy;
    return null;
}
