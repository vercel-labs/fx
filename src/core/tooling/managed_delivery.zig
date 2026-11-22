//! Hands a managed command's prepared result to the tool runtime, which commits
//! the delivery once the result is stored or cancels it. Shell and bash share it.
const debug_trace = @import("../shared/debug_trace.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const result_commit = @import("result_commit.zig");
const tool_dispatch = @import("tool_dispatch.zig");

/// Hands the delivery of `reservation_id` to the tool runtime. Without a
/// result-commit sink, the reservation is committed now.
pub fn handoff(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    reservation_id: u64,
) !void {
    if (ctx.result_commit_sink == null) {
        return runtime.commitReservation(reservation_id);
    }
    tool_dispatch.reportResultCommit(ctx, result_commit.Token{
        .context = runtime,
        .identity = reservation_id,
        .commit_fn = commitManagedDelivery,
        .cancel_fn = cancelManagedDelivery,
    });
}

fn commitManagedDelivery(raw: *anyopaque, reservation_id: u64) !void {
    const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
    return runtime.commitReservation(reservation_id);
}

fn cancelManagedDelivery(raw: *anyopaque, reservation_id: u64) void {
    const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
    runtime.cancelReservation(reservation_id) catch |err| {
        debug_trace.logf(
            "managed-delivery",
            "managed delivery cancellation failed reservation={d} err={s}",
            .{ reservation_id, @errorName(err) },
        );
    };
}
