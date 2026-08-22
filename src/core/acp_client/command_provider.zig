const std = @import("std");
const worker_runtime = @import("../agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;

/// Callback surface the ACP command provider needs from the host app.
/// `report_agent_update` streams session/update notifications (message chunks,
/// tool calls) as they arrive. `request_permission` bridges the child agent's
/// session/request_permission JSON-RPC request into fx's interactive approval
/// UI and returns the outcome the agent should receive.
pub const ReportAgentUpdateFn = *const fn (
    ctx: *anyopaque,
    agent_name: []const u8,
    update_text: []const u8,
) void;

pub const RequestPermissionFn = *const fn (
    ctx: *anyopaque,
    agent_name: []const u8,
    request_json: []const u8,
) []const u8;

pub const Request = struct {
    home: ?[]const u8,
    /// Context passed to the callbacks below. Null disables interactive runs.
    acp_run_ctx: ?*anyopaque = null,
    report_agent_update: ?ReportAgentUpdateFn = null,
    request_permission: ?RequestPermissionFn = null,
    /// Worker runtime used to surface permission prompts while a turn runs.
    worker: ?*worker_runtime.WorkerRuntime = null,
    /// Working directory for the agent session.
    cwd: ?[]const u8 = null,
    /// Receives the started turn handle so the host can drain and cancel it.
    /// Null when the host cannot host interactive turns.
    on_turn_started: ?TurnStartedFn = null,
    turn_started_ctx: ?*anyopaque = null,
    /// Host-owned turn_runner.SessionStore keeping the agent connection warm
    /// across turns. Null disables interactive runs and warmups.
    acp_session_store: ?*anyopaque = null,
    /// Reasoning-effort value to apply to the agent session, when the host
    /// has one selected ("high", "max", ...). Null keeps the agent default.
    effort_label: ?[]const u8 = null,
};

/// Called once when a turn begins running in the background. `turn` is owned
/// by the host after this call.
pub const TurnStartedFn = *const fn (ctx: *anyopaque, turn: *anyopaque) void;

pub const Display = union(enum) {
    block: []u8,
    line: []u8,
};

/// Owns the selected display text. `deinit` releases it with the allocator
/// supplied to the provider.
pub const Result = struct {
    display: Display,
    warning: bool = false,

    pub fn deinit(self: Result, alloc: Allocator) void {
        switch (self.display) {
            .block => |text| alloc.free(text),
            .line => |text| alloc.free(text),
        }
    }
};

pub const HandleFn = *const fn (alloc: Allocator, rest: []const u8, request: Request) anyerror!Result;

pub const Provider = struct {
    handle_fn: HandleFn,

    pub fn handle(self: Provider, alloc: Allocator, rest: []const u8, request: Request) !Result {
        return self.handle_fn(alloc, rest, request);
    }
};

test "ACP command provider contract round-trips owned display text" {
    const Fixture = struct {
        fn handle(alloc: Allocator, rest: []const u8, _: Request) !Result {
            try std.testing.expectEqualStrings("list", rest);
            return .{
                .display = .{ .block = try alloc.dupe(u8, "agents\n") },
            };
        }
    };

    const provider = Provider{ .handle_fn = Fixture.handle };
    const result = try provider.handle(std.testing.allocator, "list", .{ .home = null });
    defer result.deinit(std.testing.allocator);

    switch (result.display) {
        .block => |text| try std.testing.expectEqualStrings("agents\n", text),
        .line => return error.TestExpectedEqual,
    }
    try std.testing.expect(!result.warning);
}
