const std = @import("std");

pub const Handle = i32;

pub const TerminalKind = enum {
    success,
    failure,
    aborted,
};

pub const Terminal = struct {
    handle: Handle,
    kind: TerminalKind,
};

pub const Phase = union(enum) {
    idle,
    request_pending: Handle,
    awaiting_response: Handle,
    streaming: Handle,
    terminal: Terminal,
    shutdown,
};

pub const Event = union(enum) {
    open: Handle,
    take_request,
    start: Handle,
    push: Handle,
    finish: Handle,
    consumed: Handle,
    fail: Handle,
    close: Handle,
    cancel,
    shutdown,
};

pub const Action = enum {
    applied,
    stale,
    no_request,
    unavailable,
    shutting_down,
};

pub const StaleReason = enum {
    no_active_fetch,
    handle_mismatch,
    phase_mismatch,
    terminal,
    shutdown,
};

pub const Decision = struct {
    phase: Phase,
    action: Action,
    stale_reason: ?StaleReason = null,
};

pub fn decide(phase: Phase, event: Event) Decision {
    return switch (event) {
        .open => |handle| switch (phase) {
            .idle => .{
                .phase = .{ .request_pending = handle },
                .action = .applied,
            },
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
            else => .{ .phase = phase, .action = .unavailable },
        },
        .take_request => switch (phase) {
            .request_pending => |handle| .{
                .phase = .{ .awaiting_response = handle },
                .action = .applied,
            },
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
            else => .{ .phase = phase, .action = .no_request },
        },
        .start => |handle| switch (phase) {
            .awaiting_response => |active| if (active == handle)
                .{ .phase = .{ .streaming = handle }, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .push => |handle| switch (phase) {
            .streaming => |active| if (active == handle)
                .{ .phase = phase, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .finish => |handle| switch (phase) {
            .streaming => |active| if (active == handle)
                .{
                    .phase = .{ .terminal = .{ .handle = handle, .kind = .success } },
                    .action = .applied,
                }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .consumed => |handle| switch (phase) {
            .streaming => |active| if (active == handle)
                .{ .phase = phase, .action = .applied }
            else
                stale(phase, handle),
            .terminal => |terminal| if (terminal.handle == handle and terminal.kind == .success)
                .{ .phase = phase, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .fail => |handle| switch (phase) {
            .awaiting_response, .streaming => |active| if (active == handle)
                .{
                    .phase = .{ .terminal = .{ .handle = handle, .kind = .failure } },
                    .action = .applied,
                }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .close => |handle| switch (phase) {
            .request_pending, .awaiting_response, .streaming => |active| if (active == handle)
                .{ .phase = .idle, .action = .applied }
            else
                stale(phase, handle),
            .terminal => |terminal| if (terminal.handle == handle)
                .{ .phase = .idle, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .cancel => switch (phase) {
            .idle => .{ .phase = .idle, .action = .no_request },
            .request_pending, .awaiting_response, .streaming => |handle| .{
                .phase = .{ .terminal = .{ .handle = handle, .kind = .aborted } },
                .action = .applied,
            },
            .terminal => |terminal| if (terminal.kind == .success)
                .{
                    .phase = .{ .terminal = .{ .handle = terminal.handle, .kind = .aborted } },
                    .action = .applied,
                }
            else
                .{ .phase = phase, .action = .no_request },
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
        },
        .shutdown => switch (phase) {
            .shutdown => .{ .phase = .shutdown, .action = .no_request },
            else => .{ .phase = .shutdown, .action = .applied },
        },
    };
}

/// Keeps one exact logical-consumption identity independently of the HTTP phase.
/// Explicit cancellation revokes it even after close or shutdown; EOF does not grant it.
pub fn consumed_after(phase: Phase, last_consumed_handle: ?Handle, event: Event) ?Handle {
    return switch (event) {
        .consumed => |handle| if (decide(phase, event).action == .applied) handle else last_consumed_handle,
        .cancel => null,
        else => last_consumed_handle,
    };
}

pub const Disposition = enum(i32) {
    retired = 0,
    active = 1,
    consumed = 2,
};

/// Call with phase and consumption identity from the same synchronized observation.
pub fn disposition(phase: Phase, last_consumed_handle: ?Handle, handle: Handle) Disposition {
    if (last_consumed_handle == handle) return .consumed;
    return if (is_active(phase, handle)) .active else .retired;
}

pub fn is_active(phase: Phase, handle: Handle) bool {
    return switch (phase) {
        .request_pending, .awaiting_response, .streaming => |active| active == handle,
        else => false,
    };
}

fn stale(phase: Phase, handle: Handle) Decision {
    return .{
        .phase = phase,
        .action = .stale,
        .stale_reason = switch (phase) {
            .idle => .no_active_fetch,
            .shutdown => .shutdown,
            .terminal => |terminal| if (terminal.handle == handle) .terminal else .handle_mismatch,
            .request_pending, .awaiting_response, .streaming => |active| if (active == handle)
                .phase_mismatch
            else
                .handle_mismatch,
        },
    };
}

fn expectDecision(expected: Decision, actual: Decision) !void {
    try std.testing.expectEqualDeep(expected, actual);
}

test "N-API fetch state applies matching lifecycle transitions" {
    const handle: Handle = 7;
    const opened = decide(.idle, .{ .open = handle });
    try expectDecision(.{
        .phase = .{ .request_pending = handle },
        .action = .applied,
    }, opened);

    const taken = decide(opened.phase, .take_request);
    try expectDecision(.{
        .phase = .{ .awaiting_response = handle },
        .action = .applied,
    }, taken);

    const started = decide(taken.phase, .{ .start = handle });
    try expectDecision(.{
        .phase = .{ .streaming = handle },
        .action = .applied,
    }, started);
    try std.testing.expect(is_active(started.phase, handle));

    const pushed = decide(started.phase, .{ .push = handle });
    try expectDecision(.{
        .phase = .{ .streaming = handle },
        .action = .applied,
    }, pushed);

    const finished = decide(pushed.phase, .{ .finish = handle });
    try expectDecision(.{
        .phase = .{ .terminal = .{ .handle = handle, .kind = .success } },
        .action = .applied,
    }, finished);
    try std.testing.expect(!is_active(finished.phase, handle));

    const closed = decide(finished.phase, .{ .close = handle });
    try expectDecision(.{ .phase = .idle, .action = .applied }, closed);
}

test "N-API fetch state keeps stale operations inert" {
    const active: Phase = .{ .streaming = 11 };
    inline for (.{
        Event{ .push = 12 },
        Event{ .finish = 12 },
        Event{ .fail = 12 },
        Event{ .close = 12 },
    }) |event| {
        try expectDecision(.{
            .phase = active,
            .action = .stale,
            .stale_reason = .handle_mismatch,
        }, decide(active, event));
    }

    const terminal: Phase = .{ .terminal = .{ .handle = 11, .kind = .success } };
    inline for (.{
        Event{ .push = 11 },
        Event{ .finish = 11 },
        Event{ .fail = 11 },
    }) |event| {
        try expectDecision(.{
            .phase = terminal,
            .action = .stale,
            .stale_reason = .terminal,
        }, decide(terminal, event));
    }

    try expectDecision(.{
        .phase = .idle,
        .action = .stale,
        .stale_reason = .no_active_fetch,
    }, decide(.idle, .{ .close = 11 }));
}

test "N-API fetch state handles failure cancellation and shutdown" {
    const handle: Handle = 19;
    const awaiting: Phase = .{ .awaiting_response = handle };
    try expectDecision(.{
        .phase = .{ .terminal = .{ .handle = handle, .kind = .failure } },
        .action = .applied,
    }, decide(awaiting, .{ .fail = handle }));

    const cancelled = decide(awaiting, .cancel);
    try expectDecision(.{
        .phase = .{ .terminal = .{ .handle = handle, .kind = .aborted } },
        .action = .applied,
    }, cancelled);
    try std.testing.expect(!is_active(cancelled.phase, handle));

    const idle_cancel = decide(.idle, .cancel);
    try expectDecision(.{ .phase = .idle, .action = .no_request }, idle_cancel);
    try expectDecision(.{ .phase = .{ .request_pending = 20 }, .action = .applied }, decide(idle_cancel.phase, .{ .open = 20 }));

    const stopped = decide(.{ .request_pending = handle }, .shutdown);
    try expectDecision(.{ .phase = .shutdown, .action = .applied }, stopped);
    inline for (.{ Event{ .open = 20 }, Event.take_request, Event.cancel }) |event| {
        try expectDecision(.{
            .phase = .shutdown,
            .action = .shutting_down,
        }, decide(.shutdown, event));
    }
    inline for (.{
        Event{ .start = handle },
        Event{ .push = handle },
        Event{ .finish = handle },
        Event{ .fail = handle },
        Event{ .close = handle },
    }) |event| {
        try expectDecision(.{
            .phase = .shutdown,
            .action = .stale,
            .stale_reason = .shutdown,
        }, decide(.shutdown, event));
    }
    try expectDecision(.{
        .phase = .shutdown,
        .action = .no_request,
    }, decide(.shutdown, .shutdown));
}

const ConsumptionTrace = struct {
    phase: Phase = .idle,
    last_consumed_handle: ?Handle = null,

    fn apply(self: *@This(), event: Event) Decision {
        const decision = decide(self.phase, event);
        self.last_consumed_handle = consumed_after(self.phase, self.last_consumed_handle, event);
        self.phase = decision.phase;
        return decision;
    }
};

test "N-API fetch consumption exhaustively checks phase and exact handle" {
    const phases = [_]Phase{
        .idle,
        .{ .request_pending = 41 },
        .{ .awaiting_response = 41 },
        .{ .streaming = 41 },
        .{ .terminal = .{ .handle = 41, .kind = .success } },
        .{ .terminal = .{ .handle = 41, .kind = .failure } },
        .{ .terminal = .{ .handle = 41, .kind = .aborted } },
        .shutdown,
    };
    for (phases, 0..) |phase, index| {
        for ([_]?Handle{ null, 41, 42 }) |previous| {
            for ([_]Handle{ 41, 42, 43 }) |handle| {
                const eligible = handle == 41 and (index == 3 or index == 4);
                const event: Event = .{ .consumed = handle };
                const decision = decide(phase, event);
                try std.testing.expectEqualDeep(phase, decision.phase);
                try std.testing.expectEqual(if (eligible) Action.applied else Action.stale, decision.action);
                try std.testing.expectEqual(if (eligible) handle else previous, consumed_after(phase, previous, event));
            }
        }
    }
}

test "N-API fetch consumption only model completion grants and cancellation revokes" {
    const phases = [_]Phase{
        .idle,
        .{ .request_pending = 1 },
        .{ .awaiting_response = 1 },
        .{ .streaming = 1 },
        .{ .terminal = .{ .handle = 1, .kind = .success } },
        .{ .terminal = .{ .handle = 1, .kind = .failure } },
        .{ .terminal = .{ .handle = 1, .kind = .aborted } },
        .shutdown,
    };
    const events = [_]Event{
        .{ .open = 2 },
        .take_request,
        .{ .start = 1 },
        .{ .start = 2 },
        .{ .push = 1 },
        .{ .push = 2 },
        .{ .finish = 1 },
        .{ .finish = 2 },
        .{ .fail = 1 },
        .{ .fail = 2 },
        .{ .close = 1 },
        .{ .close = 2 },
        .shutdown,
        .cancel,
    };
    for (phases) |phase| {
        for ([_]?Handle{ null, 1, 2 }) |previous| {
            for (events) |event| {
                try std.testing.expectEqual(if (event == .cancel) null else previous, consumed_after(phase, previous, event));
            }
            var trace: ConsumptionTrace = .{ .phase = phase, .last_consumed_handle = previous };
            _ = trace.apply(.cancel);
            try std.testing.expect(trace.last_consumed_handle == null);
            _ = trace.apply(.{ .consumed = 1 });
            _ = trace.apply(.{ .consumed = 2 });
            try std.testing.expect(trace.last_consumed_handle == null);
        }
    }
}

test "N-API fetch disposition uses one exact phase and consumption observation" {
    const phases = [_]Phase{
        .idle,
        .{ .request_pending = 41 },
        .{ .awaiting_response = 41 },
        .{ .streaming = 41 },
        .{ .terminal = .{ .handle = 41, .kind = .success } },
        .{ .terminal = .{ .handle = 41, .kind = .failure } },
        .{ .terminal = .{ .handle = 41, .kind = .aborted } },
        .shutdown,
    };
    for (phases) |phase| {
        for ([_]?Handle{ null, 41, 42 }) |consumed| {
            for ([_]Handle{ 41, 42, 43 }) |handle| {
                const expected: Disposition = if (consumed == handle)
                    .consumed
                else if (is_active(phase, handle))
                    .active
                else
                    .retired;
                try std.testing.expectEqual(expected, disposition(phase, consumed, handle));
            }
        }
    }
}

test "N-API fetch disposition replays completion between legacy boolean reads" {
    var trace: ConsumptionTrace = .{ .phase = .{ .streaming = 1 } };
    const legacy_consumed = trace.last_consumed_handle == 1;
    try std.testing.expectEqual(Disposition.active, disposition(trace.phase, trace.last_consumed_handle, 1));
    _ = trace.apply(.{ .consumed = 1 });
    try std.testing.expectEqual(Disposition.consumed, disposition(trace.phase, trace.last_consumed_handle, 1));
    _ = trace.apply(.{ .close = 1 });
    // The old two-query observation loses completion while the single query preserves it.
    try std.testing.expect(!legacy_consumed and !is_active(trace.phase, 1));
    try std.testing.expectEqual(Disposition.consumed, disposition(trace.phase, trace.last_consumed_handle, 1));
    try std.testing.expectEqual(Disposition.retired, disposition(trace.phase, trace.last_consumed_handle, 2));
    _ = trace.apply(.shutdown);
    try std.testing.expectEqual(Disposition.consumed, disposition(trace.phase, trace.last_consumed_handle, 1));
    _ = trace.apply(.cancel);
    try std.testing.expectEqual(Disposition.retired, disposition(trace.phase, trace.last_consumed_handle, 1));
}

test "N-API fetch consumption replays model complete before HTTP EOF and normal close" {
    var trace: ConsumptionTrace = .{};
    for ([_]Event{ .{ .open = 1 }, .take_request, .{ .start = 1 }, .{ .push = 1 } }) |event| {
        try std.testing.expectEqual(Action.applied, trace.apply(event).action);
        try std.testing.expect(trace.last_consumed_handle == null);
    }
    try std.testing.expectEqual(Action.applied, trace.apply(.{ .consumed = 1 }).action);
    try std.testing.expectEqual(@as(?Handle, 1), trace.last_consumed_handle);
    // The consumer's close precedes HTTP EOF in the legacy counterexample.
    _ = trace.apply(.{ .close = 1 });
    try std.testing.expectEqualDeep(Phase.idle, trace.phase);
    try std.testing.expect(!is_active(trace.phase, 1));
    try std.testing.expectEqual(@as(?Handle, 1), trace.last_consumed_handle);
    try std.testing.expectEqual(Action.stale, trace.apply(.{ .finish = 1 }).action);
    _ = trace.apply(.shutdown);
    try std.testing.expectEqualDeep(Phase.shutdown, trace.phase);
    try std.testing.expectEqual(@as(?Handle, 1), trace.last_consumed_handle);
    try std.testing.expectEqual(Action.stale, trace.apply(.{ .consumed = 2 }).action);
    try std.testing.expectEqual(@as(?Handle, 1), trace.last_consumed_handle);
    _ = trace.apply(.cancel);
    try std.testing.expect(trace.last_consumed_handle == null);
}

test "N-API fetch consumption replays HTTP EOF before consumer completion" {
    var trace: ConsumptionTrace = .{ .phase = .{ .streaming = 1 } };
    _ = trace.apply(.{ .finish = 1 });
    try std.testing.expectEqualDeep(Phase{ .terminal = .{ .handle = 1, .kind = .success } }, trace.phase);
    try std.testing.expect(!is_active(trace.phase, 1));
    try std.testing.expect(trace.last_consumed_handle == null);
    _ = trace.apply(.{ .consumed = 1 });
    try std.testing.expectEqual(@as(?Handle, 1), trace.last_consumed_handle);
    _ = trace.apply(.{ .close = 1 });
    _ = trace.apply(.shutdown);
    try std.testing.expectEqual(@as(?Handle, 1), trace.last_consumed_handle);
}

test "N-API fetch consumption cancellation wins after HTTP EOF before completion" {
    var trace: ConsumptionTrace = .{ .phase = .{ .streaming = 1 } };
    _ = trace.apply(.{ .finish = 1 });
    try std.testing.expectEqual(Action.applied, trace.apply(.cancel).action);
    try std.testing.expectEqualDeep(Phase{ .terminal = .{ .handle = 1, .kind = .aborted } }, trace.phase);
    try std.testing.expectEqual(Action.stale, trace.apply(.{ .consumed = 1 }).action);
    try std.testing.expect(trace.last_consumed_handle == null);
}

test "N-API fetch consumption replays failure and old new handle transitions" {
    var trace: ConsumptionTrace = .{ .phase = .{ .streaming = 1 } };
    _ = trace.apply(.{ .consumed = 1 });
    _ = trace.apply(.{ .close = 1 });
    for ([_]Event{ .{ .open = 2 }, .take_request, .{ .start = 2 } }) |event| _ = trace.apply(event);
    try std.testing.expectEqual(Action.stale, trace.apply(.{ .consumed = 1 }).action);
    try std.testing.expectEqualDeep(Phase{ .streaming = 2 }, trace.phase);
    try std.testing.expectEqual(@as(?Handle, 1), trace.last_consumed_handle);
    _ = trace.apply(.{ .fail = 2 });
    try std.testing.expectEqual(Action.stale, trace.apply(.{ .consumed = 2 }).action);
    try std.testing.expectEqual(@as(?Handle, 1), trace.last_consumed_handle);
    _ = trace.apply(.{ .close = 2 });
    for ([_]Event{ .{ .open = 3 }, .take_request, .{ .start = 3 }, .{ .consumed = 3 } }) |event| _ = trace.apply(event);
    try std.testing.expectEqual(@as(?Handle, 3), trace.last_consumed_handle);
    const active = trace.phase;
    for ([_]Event{ .{ .consumed = 1 }, .{ .consumed = 2 }, .{ .close = 1 }, .{ .fail = 2 }, .{ .finish = 1 } }) |event| {
        try std.testing.expectEqual(Action.stale, trace.apply(event).action);
        try std.testing.expectEqualDeep(active, trace.phase);
        try std.testing.expectEqual(@as(?Handle, 3), trace.last_consumed_handle);
    }
    _ = trace.apply(.cancel);
    _ = trace.apply(.{ .consumed = 3 });
    try std.testing.expect(trace.last_consumed_handle == null);
}
