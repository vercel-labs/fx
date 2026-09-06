const std = @import("std");
const client = @import("client.zig");
const contracts = @import("contracts.zig");
const operation = @import("operation.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    alloc: Allocator,
    lifecycle_allocator: Allocator,
    runtime: *client.Runtime,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub fn execute(
    ctx: Context,
    request: contracts.ActionRequest,
) !contracts.OwnedResult {
    operation.validate(request) catch {
        return contracts.OwnedResult.init(ctx.alloc, .{ .failure = .{
            .action = request.action(),
            .code = .invalid_request,
            .session_id = operation.authoritySessionId(request),
        } });
    };
    const correlation_id = ctx.runtime.nextCorrelationId();
    ctx.runtime.admit(
        ctx.lifecycle_allocator,
        correlation_id,
        request,
    ) catch |err| {
        return contracts.OwnedResult.init(ctx.alloc, .{ .failure = .{
            .action = request.action(),
            .code = mapAdmissionError(err),
            .session_id = operation.authoritySessionId(request),
            .retryable = err == error.QueueFull,
        } });
    };
    var cancellation_sent = false;
    while (true) {
        if (ctx.runtime.takeCompletionFor(correlation_id)) |completion_value| {
            var completion = completion_value;
            defer completion.deinit();
            if (completion.frame) |*frame| {
                return switch (frame.message().payload) {
                    .response => |response| contracts.OwnedResult.init(
                        ctx.alloc,
                        response,
                    ),
                    else => failure(ctx, request, .protocol_incompatible, false),
                };
            }
            return failure(
                ctx,
                request,
                switch (completion.kind) {
                    .cancelled => .cancelled,
                    .unavailable => if (completion.is_missing_capability(
                        contracts.protocol_capability_complete_process_tree_signals,
                    ))
                        .unsupported_host
                    else
                        .protocol_incompatible,
                    .disconnected => .session_lost,
                    .response => .protocol_incompatible,
                },
                completion.kind == .disconnected and
                    disconnectedActionIsRetryable(request.action()),
            );
        }
        if (!cancellation_sent) {
            if (ctx.cancel_flag) |cancel_flag| {
                if (cancel_flag.load(.acquire)) {
                    _ = ctx.runtime.cancel(correlation_id);
                    cancellation_sent = true;
                }
            }
        }
        io_mod.sleep(2 * std.time.ns_per_ms);
    }
}

fn disconnectedActionIsRetryable(action: contracts.Action) bool {
    return switch (action) {
        .read, .screen, .wait, .inspect, .list => true,
        .start, .write, .resize, .signal, .close => false,
    };
}

fn failure(
    ctx: Context,
    request: contracts.ActionRequest,
    code: contracts.StructuredErrorCode,
    retryable: bool,
) !contracts.OwnedResult {
    return contracts.OwnedResult.init(ctx.alloc, .{ .failure = .{
        .action = request.action(),
        .code = code,
        .session_id = operation.authoritySessionId(request),
        .retryable = retryable,
    } });
}

fn mapAdmissionError(err: anyerror) contracts.StructuredErrorCode {
    return switch (err) {
        error.QueueFull => .capacity_exceeded,
        error.TerminalUnavailable, error.Unsupported => .unsupported_host,
        error.Cancelled => .cancelled,
        else => .protocol_incompatible,
    };
}

test "disconnect retryability excludes actions that may already have effects" {
    try std.testing.expect(!disconnectedActionIsRetryable(.start));
    try std.testing.expect(!disconnectedActionIsRetryable(.write));
    try std.testing.expect(!disconnectedActionIsRetryable(.signal));
    try std.testing.expect(!disconnectedActionIsRetryable(.close));
    try std.testing.expect(disconnectedActionIsRetryable(.list));
    try std.testing.expect(disconnectedActionIsRetryable(.wait));
}
