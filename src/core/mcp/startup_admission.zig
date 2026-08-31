//! Pure admission policy for selecting which configured MCP servers connect in
//! each product startup phase.

const mcp_contract = @import("mcp_contract.zig");

pub const Phase = enum {
    all,
    ask_startup,
    ask_deferred,
    acp_startup,
};

pub const Decision = enum {
    connect,
    deferred,
    disabled,
};

pub fn decide(
    enabled: bool,
    required: bool,
    workspace_admission: ?mcp_contract.WorkspaceAdmission,
    phase: Phase,
) Decision {
    if (!enabled) return .disabled;
    if (workspace_admission) |admission| {
        return switch (admission) {
            .rejected => .disabled,
            .pending => .disabled,
            .approved => switch (phase) {
                .all, .ask_startup, .acp_startup => .connect,
                .ask_deferred => .deferred,
            },
        };
    }
    return switch (phase) {
        .all => .connect,
        .ask_startup => if (required) .connect else .deferred,
        .ask_deferred => if (required) .deferred else .connect,
        .acp_startup => .connect,
    };
}

test "startup admission keeps Ask required servers eager and optional servers deferred" {
    const testing = @import("std").testing;

    try testing.expectEqual(Decision.connect, decide(true, true, null, .all));
    try testing.expectEqual(Decision.connect, decide(true, false, null, .all));
    try testing.expectEqual(Decision.connect, decide(true, true, null, .ask_startup));
    try testing.expectEqual(Decision.deferred, decide(true, false, null, .ask_startup));
    try testing.expectEqual(Decision.deferred, decide(true, true, null, .ask_deferred));
    try testing.expectEqual(Decision.connect, decide(true, false, null, .ask_deferred));
    try testing.expectEqual(Decision.connect, decide(true, true, null, .acp_startup));
    try testing.expectEqual(Decision.connect, decide(true, false, null, .acp_startup));
}

test "disabled servers never enter a connection phase" {
    const testing = @import("std").testing;

    try testing.expectEqual(Decision.disabled, decide(false, true, null, .all));
    try testing.expectEqual(Decision.disabled, decide(false, true, .pending, .ask_startup));
    try testing.expectEqual(Decision.disabled, decide(false, false, .approved, .ask_deferred));
    try testing.expectEqual(Decision.disabled, decide(false, false, .rejected, .acp_startup));
}

test "workspace admission is phase derived and reject is absorbing" {
    const testing = @import("std").testing;
    const cases = [_]struct {
        admission: mcp_contract.WorkspaceAdmission,
        all: Decision,
        ask_startup: Decision,
        ask_deferred: Decision,
        acp_startup: Decision,
    }{
        .{ .admission = .approved, .all = .connect, .ask_startup = .connect, .ask_deferred = .deferred, .acp_startup = .connect },
        .{ .admission = .pending, .all = .disabled, .ask_startup = .disabled, .ask_deferred = .disabled, .acp_startup = .disabled },
        .{ .admission = .rejected, .all = .disabled, .ask_startup = .disabled, .ask_deferred = .disabled, .acp_startup = .disabled },
    };
    for (cases) |case| {
        try testing.expectEqual(case.all, decide(true, false, case.admission, .all));
        try testing.expectEqual(case.ask_startup, decide(true, false, case.admission, .ask_startup));
        try testing.expectEqual(case.ask_deferred, decide(true, false, case.admission, .ask_deferred));
        try testing.expectEqual(case.acp_startup, decide(true, false, case.admission, .acp_startup));
    }
}
