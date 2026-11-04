//! Who owns a connection open that a request may walk away from.
//!
//! A request's connection open runs on a job of its own, because a DNS
//! lookup cannot be cancelled: a request that waited for one sat out the
//! whole lookup after Esc. When Esc or the setup deadline comes first, the
//! request walks away at once, and the job, whenever its lookup and connect
//! return, closes what it opened. One atomic state word decides which side
//! owns the result, so both never do: the job publishes with a swap from
//! `running` to `handed`, and the request walks away with a swap from
//! `running` to `abandoned`. Whichever swap fails learns that the other side
//! went first. `tests/tla/gateway_open/OpenCancel.tla` models it, and
//! `tests/tla/drivers/gateway_open/` walks this file along that model.
const std = @import("std");

pub const State = enum(u8) { running, handed, abandoned };

/// What the job does once its open returned.
pub const JobAfterOpen = enum {
    /// The request takes the result; the job must not touch it again.
    hand_over,
    /// The request walked away; the job closes what it opened.
    close_late,
};

/// What the waiting request does on each check.
pub const WorkerMove = enum {
    /// The open is still running and the request still wants it.
    wait,
    /// The open was handed over and the request still wants it.
    take,
    /// The request stopped first: it returns at once and never touches the
    /// job again, which then closes its own late connection.
    walk_away,
    /// The request stopped after the open was handed over, so it closes the
    /// connection itself.
    close_handed,
};

pub const Handoff = struct {
    state: std.atomic.Value(State) = .init(.running),

    /// The job's side, once its open returned (OpenCancel.tla
    /// JobPublishAtomic). After `.hand_over` the request may free the job at
    /// any moment, so the job must not touch it again.
    pub fn publish(self: *Handoff) JobAfterOpen {
        return if (self.state.cmpxchgStrong(.running, .handed, .acq_rel, .acquire) == null)
            .hand_over
        else
            .close_late;
    }

    /// The request's side, checked while it waits (OpenCancel.tla WorkerTake
    /// and WorkerAbandonAtomic). `stop` is Esc or the setup deadline.
    pub fn poll(self: *Handoff, stop: bool) WorkerMove {
        if (!stop) return if (self.state.load(.acquire) == .handed) .take else .wait;
        return if (self.state.cmpxchgStrong(.running, .abandoned, .acq_rel, .acquire) == null)
            .walk_away
        else
            .close_handed;
    }
};

test "an open that returns first is handed over, and a stop after it closes it" {
    var handoff: Handoff = .{};
    try std.testing.expectEqual(WorkerMove.wait, handoff.poll(false));
    try std.testing.expectEqual(JobAfterOpen.hand_over, handoff.publish());
    try std.testing.expectEqual(WorkerMove.take, handoff.poll(false));
    var stopped: Handoff = .{};
    try std.testing.expectEqual(JobAfterOpen.hand_over, stopped.publish());
    try std.testing.expectEqual(WorkerMove.close_handed, stopped.poll(true));
}

test "a request that stops first walks away, and the late open is closed by its job" {
    var handoff: Handoff = .{};
    try std.testing.expectEqual(WorkerMove.walk_away, handoff.poll(true));
    try std.testing.expectEqual(JobAfterOpen.close_late, handoff.publish());
}

test "racing threads leave exactly one owner of every open" {
    const Race = struct {
        handoff: Handoff = .{},
        job: JobAfterOpen = undefined,
        worker: WorkerMove = undefined,

        fn runJob(self: *@This()) void {
            self.job = self.handoff.publish();
        }

        fn runWorker(self: *@This()) void {
            self.worker = self.handoff.poll(true);
        }
    };
    var hand_overs: usize = 0;
    var walk_aways: usize = 0;
    for (0..2_000) |_| {
        var race: Race = .{};
        const job = try std.Thread.spawn(.{}, Race.runJob, .{&race});
        const worker = try std.Thread.spawn(.{}, Race.runWorker, .{&race});
        job.join();
        worker.join();
        // Exactly one side closes the connection: the request when it was
        // handed over, the job when the request walked away first.
        switch (race.job) {
            .hand_over => {
                try std.testing.expectEqual(WorkerMove.close_handed, race.worker);
                hand_overs += 1;
            },
            .close_late => {
                try std.testing.expectEqual(WorkerMove.walk_away, race.worker);
                walk_aways += 1;
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 2_000), hand_overs + walk_aways);
}
