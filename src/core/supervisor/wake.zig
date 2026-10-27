//! Turns the supervisor starts on its own, without a frontend asking: a
//! session's heartbeat and the notices for background jobs that settled with
//! nobody waiting (D111). Each runs on the session's executor from `tick`.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const Session = @import("session.zig").Session;

/// Fires a due heartbeat, then hands settled jobs to the agent loop.
pub fn tick(self: *Session, now: i64) void {
    if (self.record.heartbeatArmed() and now >= self.record.heartbeat.next_run_ms) {
        // Coalesce to one admitted fire. Steering interrupts only a
        // streaming reply; tools, compaction and approvals wait safely.
        self.events_mutex.lockUncancelable(io_mod.getIo());
        const waiting = self.heartbeat_request != null;
        self.events_mutex.unlock(io_mod.getIo());
        if (!waiting) fireHeartbeat(self, now);
    }
    if (!self.record.stopped) deliverJobNotice(self);
}

fn fireHeartbeat(self: *Session, now: i64) void {
    const alloc = self.daemon.alloc;
    const admitted = if (self.prompt(self.record.heartbeat.prompt, .heartbeat)) |_| true else |err| blk: {
        std.debug.print("proto-fx: heartbeat admission failed: {s}\n", .{@errorName(err)});
        break :blk false;
    };
    var next_record = self.record.clone(alloc) catch return;
    next_record.heartbeat.next_run_ms = now + @as(i64, @intCast(next_record.heartbeat.interval_ms));
    if (admitted) next_record.heartbeat.run_count += 1;
    self.daemon.commit(self, &next_record, false) catch |err| std.debug.print("proto-fx: heartbeat save failed: {s}\n", .{@errorName(err)});
}

/// Hands jobs that settled with nobody waiting to the agent loop: it
/// steers a running turn or starts one (D111). A refused notice keeps
/// its jobs for the next tick.
fn deliverJobNotice(self: *Session) void {
    const host = self.host orelse return;
    settleJobNotices(self, host);
    var arena_state = std.heap.ArenaAllocator.init(self.daemon.alloc);
    defer arena_state.deinit();
    const notice = (host.takeJobNotice(arena_state.allocator()) catch |err| {
        std.debug.print("proto-fx: job delivery failed: {s}\n", .{@errorName(err)});
        return;
    }) orelse return;
    const request_id = self.prompt(notice.text, .job_notice) catch |err| {
        notice.release();
        if (err != error.SessionBusy) std.debug.print("proto-fx: job notice admission failed: {s}\n", .{@errorName(err)});
        return;
    };
    host.jobNoticeAdmitted(notice, request_id);
}

/// Commits each answered notice the model got, and releases the rest so
/// their jobs are delivered again. Runs after `jobNoticeAdmitted` for the
/// same request, since both run on the executor.
fn settleJobNotices(self: *Session, host: anytype) void {
    self.events_mutex.lockUncancelable(io_mod.getIo());
    const answers = self.notice_answers.toOwnedSlice(self.daemon.alloc) catch &.{};
    self.events_mutex.unlock(io_mod.getIo());
    defer self.daemon.alloc.free(answers);
    for (answers) |answer| host.jobNoticeAnswered(answer.id, answer.delivered);
}
