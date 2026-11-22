//! The table of the sessions one `fx acp` process has open. Every connection of
//! the process registers, finds and follows sessions here. It is the one list of
//! the process's open sessions (R1.8); a session leaves it when its close starts.
//!
//! Lock order: `mutex`, then a session's `session_write_mutex`, then its
//! `audience_mutex`, then a writer's lock. `startClose` takes `mutex` for each
//! of its steps, and never holds it while it takes a session's `audience_mutex`.

const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const prompt_test_controls = @import("../prompt_test_controls.zig");

const Allocator = std.mem.Allocator;

/// `Session` is the server's open session type. It has `session_id`, `uses`,
/// and `uses_done`, which this table reads under `mutex`.
pub fn SessionTable(comptime Session: type) type {
    return struct {
        const Self = @This();

        mutex: std.Io.Mutex = .init,
        sessions: std.ArrayList(*Session) = .empty,

        /// Adds `session`. `unregister` removes it when the session starts to close.
        pub fn register(self: *Self, alloc: Allocator, session: *Session) Allocator.Error!void {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            try self.sessions.append(alloc, session);
        }

        /// Removes `session` if it is listed. `startClose` calls this before the close
        /// waits for the session's uses, so no connection can take a new use.
        pub fn unregister(self: *Self, session: *Session) void {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            for (self.sessions.items, 0..) |listed, index| {
                if (listed != session) continue;
                _ = self.sessions.orderedRemove(index);
                return;
            }
        }

        /// The open session that `session_id` names, or null. The caller holds `mutex`.
        pub fn findLocked(self: *Self, session_id: []const u8) ?*Session {
            for (self.sessions.items) |session| {
                if (std.mem.eql(u8, session.session_id, session_id)) return session;
            }
            return null;
        }

        /// Takes a use of the session that `session_id` names, when the table lists it.
        /// The use keeps the session from being freed until `release`. A close takes the
        /// session out of the table first, so no use starts after it, and then waits for
        /// the uses that are held (AcpSessionReaders Retains). Null when no listed session
        /// has that id.
        pub fn retain(self: *Self, session_id: []const u8) ?*Session {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            const session = self.findLocked(session_id) orelse return null;
            session.uses += 1;
            return session;
        }

        /// Ends a use that `retain` took. The release that ends the last use wakes the
        /// close that waits for it (AcpSessionReaders Release).
        pub fn release(self: *Self, session: *Session) void {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            std.debug.assert(session.uses > 0);
            session.uses -= 1;
            if (session.uses == 0) session.uses_done.broadcast(io_mod.getIo());
        }

        /// Waits until no use of `session` is held (AcpSessionReaders CloseWait). The
        /// caller has taken the session out of the table, so no new use can start.
        pub fn waitNoUses(self: *Self, session: *Session) void {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            while (session.uses > 0) {
                prompt_test_controls.noteUsesWaiting();
                session.uses_done.waitUncancelable(io_mod.getIo(), &self.mutex);
            }
        }

        /// Frees the table. The process closes its sessions before it calls this, so a
        /// session still listed here is traced, not silently dropped.
        pub fn deinit(self: *Self, alloc: Allocator) void {
            if (self.sessions.items.len > 0) {
                debug_trace.logf("acp", "event=shared_sessions_left_open count={d}", .{self.sessions.items.len});
            }
            self.sessions.deinit(alloc);
        }
    };
}
