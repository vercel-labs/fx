//! Pure admission policy for selecting which configured MCP servers connect in
//! each product startup phase.

const mcp_contract = @import("mcp_contract.zig");

pub const Phase = enum {
    all,
    ask_startup,
    ask_deferred,
    acp_startup,
    /// Servers the ACP client serves over its own connection, connected from
    /// the prompt worker after session setup.
    acp_host_channel,
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
                .all, .ask_startup, .acp_startup, .acp_host_channel => .connect,
                .ask_deferred => .deferred,
            },
        };
    }
    return switch (phase) {
        .all => .connect,
        .ask_startup => if (required) .connect else .deferred,
        .ask_deferred => if (required) .deferred else .connect,
        .acp_startup, .acp_host_channel => .connect,
    };
}

/// Applies `decide` to one configured server. ACP session setup runs on the
/// thread that reads the ACP connection, so servers served over that same
/// connection wait for the `acp_host_channel` phase.
pub fn decideServer(config: *const mcp_contract.McpServerConfig, phase: Phase) Decision {
    const host_channel = config.acp_server_id != null;
    switch (phase) {
        .acp_startup => if (host_channel) return if (config.enabled) .deferred else .disabled,
        .acp_host_channel => if (!host_channel) return .deferred,
        else => {},
    }
    return decide(config.enabled, config.required, config.workspace_admission, phase);
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

test "ACP host-channel servers wait for the host-channel phase" {
    const testing = @import("std").testing;
    const host: mcp_contract.McpServerConfig = .{ .name = "browser", .transport = .http, .acp_server_id = "browser:1" };
    const remote: mcp_contract.McpServerConfig = .{ .name = "remote", .transport = .http };
    try testing.expectEqual(Decision.deferred, decideServer(&host, .acp_startup));
    try testing.expectEqual(Decision.connect, decideServer(&host, .acp_host_channel));
    try testing.expectEqual(Decision.connect, decideServer(&remote, .acp_startup));
    try testing.expectEqual(Decision.deferred, decideServer(&remote, .acp_host_channel));
    var disabled = host;
    disabled.enabled = false;
    try testing.expectEqual(Decision.disabled, decideServer(&disabled, .acp_startup));
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
