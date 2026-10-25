//! Permissions are settled by normal tool admission before kernel execution.
const std = @import("std");
const dispatch = @import("../core/tooling/tool_dispatch.zig");
const kernel = @import("../core/kernel/slot.zig");
const Allocator = std.mem.Allocator;
/// `execute` runs code; every other action is a `kernel.Action` recovery control.
const Action = enum { execute, status, interrupt, stop, restart, prewarm };
const Input = struct { action: Action, code: ?[]u8, timeout_ms: u64, max_output_chars: usize };

pub fn decode(ctx: dispatch.DispatchContext, json: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(struct {
        action: Action = .execute,
        code: ?[]const u8 = null,
        timeout_ms: u64 = 60_000,
        max_output_chars: usize = 65_536,
    }, ctx.allocator, json, .{}) catch return .{ .failure = try ctx.allocator.dupe(u8, "kernel expects action execute/status/interrupt/stop/restart/prewarm, code for execute, optional timeout_ms and max_output_chars") };
    defer parsed.deinit();
    const value = parsed.value;
    if (value.action == .execute) {
        const code = value.code orelse return .{ .failure = try ctx.allocator.dupe(u8, "kernel execute requires code") };
        if (code.len == 0 or code.len > 1024 * 1024) return .{ .failure = try ctx.allocator.dupe(u8, "kernel code must be 1–1048576 bytes") };
    } else if (value.code != null) return .{ .failure = try ctx.allocator.dupe(u8, "code is only accepted for kernel action execute") };
    if (value.max_output_chars > 65_536) return .{ .failure = try ctx.allocator.dupe(u8, "max_output_chars must be at most 65536") };
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .action = value.action,
        .code = if (value.code) |code| try ctx.allocator.dupe(u8, code) else null,
        .timeout_ms = value.timeout_ms,
        .max_output_chars = value.max_output_chars,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = deinitInput } };
}

fn deinitInput(raw: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(raw));
    if (input.code) |code| alloc.free(code);
    alloc.destroy(input);
}

pub fn readsOnly(input: dispatch.ToolInput) bool {
    return input.as(Input).action == .status;
}
pub fn isIrreversible(input: dispatch.ToolInput) bool {
    return switch (input.as(Input).action) {
        .status, .prewarm => false,
        else => true,
    };
}

const Output = struct {
    ctx: dispatch.DispatchContext,
    fn write(raw: ?*anyopaque, stream: kernel.Stream, chunk: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.ctx.on_output_chunk) |callback| {
            if (self.ctx.output_chunk_ctx) |context| callback(context, self.ctx.output_chunk_lifecycle_id, if (stream == .stdout) .stdout else .stderr, chunk) catch {};
        }
    }
};

pub fn call(ctx: dispatch.DispatchContext, erased: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    const slot = ctx.kernel orelse return .{ .failure = try ctx.allocator.dupe(u8, "kernel is unavailable in this host") };
    const input = erased.as(Input);
    const owner: kernel.Owner = .{ .cwd = ctx.workspace_root, .session_id = ctx.terminal_owner_session_id };
    if (input.action != .execute) return control(ctx, slot, owner, std.meta.stringToEnum(kernel.Action, @tagName(input.action)).?);
    const manager = slot.ensure(ctx.lifecycle_allocator, owner) catch |err|
        return .{ .failure = try ctx.allocator.print("Kernel initialization failed: {s}", .{@errorName(err)}) };
    var output = Output{ .ctx = ctx };
    const result = manager.execute(ctx.allocator, input.code.?, .{
        .cancel = ctx.cancel_flag,
        .on_stream = .{ .context = &output, .write = Output.write },
        .timeout_ms = input.timeout_ms,
        .max_output_chars = input.max_output_chars,
    }) catch |err| {
        if (err == error.KernelCapacityExhausted) return .{ .failure = try ctx.allocator.dupe(u8, "This process already runs its maximum number of Python kernels and every one is running a cell, so this kernel could not start within a minute. Retry after a cell finishes, or raise PROTO_FX_MAX_LIVE_KERNELS.") };
        if (err == error.KernelStillBusyAfterInterrupt) return .{ .failure = try ctx.allocator.dupe(u8, "The Python kernel is still running the interrupted cell. Wait and retry, or call kernel with action restart to discard it and recover the last saved globals.") };
        const diagnostic = manager.diagnostics(ctx.allocator) catch return error.OutOfMemory;
        defer ctx.allocator.free(diagnostic);
        return .{ .failure = try ctx.allocator.print("Kernel execution failed: {s}\n{s}", .{ @errorName(err), diagnostic }) };
    };
    defer result.deinit(ctx.allocator);
    const text = result.text(ctx.allocator) catch return error.OutOfMemory;
    return if (result.status == .ok) .{ .success = text } else .{ .failure = text };
}

fn control(ctx: dispatch.DispatchContext, slot: *kernel.Slot, owner: kernel.Owner, action: kernel.Action) dispatch.DispatchError!dispatch.ToolResult {
    const state = slot.control(ctx.lifecycle_allocator, owner, action) catch |err|
        return .{ .failure = try ctx.allocator.print("Kernel {t} failed: {s}", .{ action, @errorName(err) }) };
    if (state == null) return .{ .success = try ctx.allocator.dupe(u8, "Python kernel: idle (starts on first execution)") };
    // The first owner decided persistence when it created the kernel.
    const persist = slot.current().?.persist;
    return .{ .success = try switch (action) {
        .status => ctx.allocator.print("Python kernel: {t}", .{state.?}),
        .interrupt => ctx.allocator.dupe(u8, "Interrupt requested; the current cell remains busy until Python finishes handling it."),
        .stop => ctx.allocator.dupe(u8, if (persist)
            "Python kernel stopped. Saved globals will be restored on the next execution; live tasks and open resources are closed."
        else
            "Python kernel stopped. This unsaved session does not keep snapshots; the next execution has an empty namespace."),
        .restart => ctx.allocator.dupe(u8, if (persist)
            "Python kernel discarded without a final snapshot. The next execution starts fresh and restores the last saved globals; unsaved changes, tasks and open resources are lost."
        else
            "Python kernel discarded. The next execution has an empty namespace; this unsaved session does not keep snapshots."),
        .prewarm => ctx.allocator.dupe(u8, "Python kernel startup requested in the background. Execute joins the same startup; status reports its state."),
    } };
}

test "kernel action decoding distinguishes inspection from execution" {
    const alloc = std.testing.allocator;
    const ctx = dispatch.DispatchContext{ .allocator = alloc };
    const decoded = try decode(ctx, "{\"action\":\"status\"}");
    switch (decoded) {
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(readsOnly(input));
            try std.testing.expect(!isIrreversible(input));
        },
        .failure => |message| {
            alloc.free(message);
            return error.TestUnexpectedResult;
        },
    }
    const missing = try decode(ctx, "{}");
    switch (missing) {
        .failure => |message| {
            defer alloc.free(message);
            try std.testing.expect(std.mem.find(u8, message, "requires code") != null);
        },
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }
}
