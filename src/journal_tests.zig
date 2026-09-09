// Focused recovery witnesses, run by the native Full CI matrix.
test {
    _ = @import("core/agent/runtime/tests/journal_crash_flow.zig");
    _ = @import("acp/server.zig");
    _ = @import("acp/prompt.zig");
    _ = @import("core/session/execution_journal_store.zig");
    _ = @import("core/session/execution_journal_genesis.zig");
    _ = @import("core/subagent/managed_owner.zig");
    _ = @import("core/session/restart_handoff.zig");
}
