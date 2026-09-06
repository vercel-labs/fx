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
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
            else => .{ .phase = phase, .action = .no_request },
        },
        .shutdown => switch (phase) {
            .shutdown => .{ .phase = .shutdown, .action = .no_request },
            else => .{ .phase = .shutdown, .action = .applied },
        },
    };
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
