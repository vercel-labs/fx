//! `kernel.*`: the calling node's persistent Python namespaces, a handle on
//! the process-wide kernel pool through the node's kernel slot. `default`
//! is the node's own kernel, the one `/kernel` controls; other names are
//! extra kernels of the same node. Parking, the memory budget, snapshots and
//! the zygote all apply as they do to any pool kernel.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const kernel_slot = @import("../kernel/slot.zig");
const protocol = @import("protocol.zig");
const Allocator = std.mem.Allocator;

const max_output_chars: usize = 65_536;

pub const run = struct {
    pub const name = "kernel.run";
    pub const Args = struct {
        name: []const u8 = kernel_slot.default_name,
        code: []const u8,
        timeout_ms: u64 = 60_000,
    };

    pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
        const slot = call.lease.kernel orelse return noKernels(call);
        if (args.code.len == 0) return call.fail(.bad_request, "kernel.run needs code", .{});
        const manager = slot.ensureNamed(call.lease.kernel_allocator, owner(call), args.name) catch |err| return startFailure(call, args.name, err);
        try bind(call, manager);
        var stream = Stream{ .call = call };
        const result = manager.execute(call.arena, args.code, .{
            .cancel = call.lease.cancel,
            .on_stream = .{ .context = &stream, .write = Stream.write },
            .timeout_ms = args.timeout_ms,
            .max_output_chars = max_output_chars,
        }) catch |err| return executeFailure(call, manager, err);
        const text = try result.text(call.arena);
        return call.ok(.{
            .status = @tagName(result.status),
            .stdout = result.stdout,
            .stderr = result.stderr,
            .result = result.result,
            .output = text,
        });
    }
};

fn control(comptime op_name: []const u8, comptime action: kernel_slot.Action) type {
    return struct {
        pub const name = op_name;
        pub const Args = struct { name: []const u8 = kernel_slot.default_name };

        pub fn handle(call: *protocol.Call, args: Args) !protocol.Reply {
            const slot = call.lease.kernel orelse return noKernels(call);
            if (!std.mem.eql(u8, args.name, kernel_slot.default_name) and !kernel_slot.validName(args.name))
                return call.fail(.bad_request, "a kernel name is 1 to 32 lowercase letters, digits, _ or -", .{});
            const state = slot.controlNamed(call.lease.kernel_allocator, owner(call), args.name, action) catch |err|
                return call.fail(.kernel_failed, "kernel {s} {t} failed: {s}", .{ args.name, action, @errorName(err) });
            return call.ok(.{ .name = args.name, .state = if (state) |value| @tagName(value) else "uninitialized" });
        }
    };
}

pub const status = control("kernel.status", .status);
pub const stop = control("kernel.stop", .stop);
pub const restart = control("kernel.restart", .restart);

pub const list = struct {
    pub const name = "kernel.list";
    pub const Args = struct {};

    pub fn handle(call: *protocol.Call, _: Args) !protocol.Reply {
        const slot = call.lease.kernel orelse return noKernels(call);
        return call.ok(.{ .report = try slot.report(call.arena, owner(call)) });
    }
};

fn owner(call: *protocol.Call) kernel_slot.Owner {
    return .{ .cwd = call.lease.cwd, .session_id = call.lease.kernel_session_id };
}

fn noKernels(call: *protocol.Call) !protocol.Reply {
    return call.fail(.unavailable, "this host offers no Python kernels to this command", .{});
}

fn startFailure(call: *protocol.Call, name: []const u8, err: anyerror) !protocol.Reply {
    return switch (err) {
        error.OutOfMemory => err,
        error.InvalidKernelName => call.fail(.bad_request, "a kernel name is 1 to 32 lowercase letters, digits, _ or -", .{}),
        error.TooManyKernels => call.fail(.refused, "this agent already holds {d} named kernels; stop using one or reuse a name", .{kernel_slot.max_named}),
        else => call.fail(.kernel_failed, "kernel {s} could not start: {s}", .{ name, @errorName(err) }),
    };
}

fn executeFailure(call: *protocol.Call, manager: *kernel_slot.Manager, err: anyerror) !protocol.Reply {
    switch (err) {
        error.OutOfMemory, error.Cancelled => return err,
        error.KernelCapacityExhausted => return call.fail(.kernel_failed, "every Python kernel this process may run is busy with a cell; retry after one finishes", .{}),
        error.KernelStillBusyAfterInterrupt => return call.fail(.kernel_failed, "the kernel is still running an interrupted cell; wait, or restart it", .{}),
        else => {},
    }
    const diagnostic = try manager.diagnostics(call.arena);
    return .{ .failure = .{ .kind = .kernel_failed, .message = try call.arena.print("kernel execution failed: {s}", .{@errorName(err)}), .output = diagnostic } };
}

/// Hands this lease's socket and token to the kernel process, once per
/// kernel start, so a cell that imports `proto_fx` reaches this node and its
/// own Python children stay quiet. The token dies with the lease, so a later
/// command rebinds.
fn bind(call: *protocol.Call, manager: *kernel_slot.Manager) !void {
    if (call.lease.isBound(manager, generation(manager))) return;
    const code = try bindingCode(call.arena, call.lease.socketPath(), &call.lease.token, call.lease.python_dir);
    const result = manager.execute(call.arena, code, .{ .cancel = call.lease.cancel, .timeout_ms = 10_000, .max_output_chars = 4096 }) catch |err| switch (err) {
        error.OutOfMemory, error.Cancelled => return err,
        // The cell itself reports why the kernel cannot run.
        else => return,
    };
    if (result.status == .ok) call.lease.setBound(manager, generation(manager));
}

fn generation(manager: *kernel_slot.Manager) u64 {
    const io = io_mod.getIo();
    manager.mutex.lockUncancelable(io);
    defer manager.mutex.unlock(io);
    return manager.generation;
}

fn bindingCode(arena: Allocator, socket: []const u8, token: []const u8, python_dir: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("import os as _pfx_os, sys as _pfx_sys\n_pfx_os.environ.update({\"PROTO_FX_HARNESS_SOCKET\": ");
    try std.json.Stringify.value(socket, .{}, w);
    try w.writeAll(", \"PROTO_FX_HARNESS_TOKEN\": ");
    try std.json.Stringify.value(token, .{}, w);
    try w.writeAll(", \"PROTO_FX_HARNESS_DEPTH\": \"1\"})\n_pfx_dir = ");
    try std.json.Stringify.value(python_dir, .{}, w);
    try w.writeAll("\nif _pfx_dir not in _pfx_sys.path: _pfx_sys.path.insert(0, _pfx_dir)\ndel _pfx_os, _pfx_sys, _pfx_dir\n");
    return out.written();
}

const Stream = struct {
    call: *protocol.Call,

    fn write(raw: ?*anyopaque, which: kernel_slot.Stream, chunk: []const u8) void {
        const self: *Stream = @ptrCast(@alignCast(raw.?));
        self.call.event(@tagName(which), chunk);
    }
};

test "the binding cell names the socket, token and package and leaves no globals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const code = try bindingCode(arena_state.allocator(), "/tmp/h/1.sock", "abc", "/Users/example/py");
    try std.testing.expect(std.mem.find(u8, code, "\"PROTO_FX_HARNESS_SOCKET\": \"/tmp/h/1.sock\"") != null);
    try std.testing.expect(std.mem.find(u8, code, "\"PROTO_FX_HARNESS_TOKEN\": \"abc\"") != null);
    try std.testing.expect(std.mem.find(u8, code, "del _pfx_os, _pfx_sys, _pfx_dir") != null);
}
