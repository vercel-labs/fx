//! The harness over a real socket: authentication, the op registry, and the
//! lease lifetime, with fake turn services.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const harness = @import("harness.zig");
const services_mod = @import("services.zig");
const lease_mod = @import("lease.zig");
const Allocator = std.mem.Allocator;

const Fake = struct {
    calls: std.atomic.Value(u32) = .init(0),
    last_name: [32]u8 = undefined,
    last_len: usize = 0,

    fn callTool(context: *anyopaque, arena: Allocator, request: services_mod.ToolRequest) anyerror!services_mod.ToolOutcome {
        const self: *Fake = @ptrCast(@alignCast(context));
        _ = self.calls.fetchAdd(1, .monotonic);
        if (std.mem.eql(u8, request.name, "write_file")) return .{ .status = .denied, .output = "denied" };
        if (std.mem.eql(u8, request.name, "fleet")) return .{ .status = .success, .output = "{\"ok\":true,\"result\":\"child says hi\",\"error_code\":null}" };
        return .{ .status = .success, .output = try arena.print("{s} {s} {s}", .{ request.call_id, request.name, request.arguments_json }) };
    }

    fn toolNames(_: *anyopaque, _: Allocator) anyerror![]const []const u8 {
        return &.{ "read_file", "fleet" };
    }

    fn complete(_: *anyopaque, arena: Allocator, request: services_mod.CompletionRequest) anyerror!services_mod.CompletionOutcome {
        return .{ .text = try arena.dupe(u8, request.prompt) };
    }

    fn services(self: *Fake) services_mod.Services {
        return .{ .context = self, .call_tool_fn = callTool, .tool_names_fn = toolNames, .complete_fn = complete };
    }
};

/// Sends one line and returns every line the host wrote back.
fn send(alloc: Allocator, socket_path: []const u8, line: []const u8) ![]u8 {
    const io = io_mod.getIo();
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        var buffers = [_][]u8{&chunk};
        const read = stream.readWithControl(io, &buffers, &.{}) catch break;
        if (read.data_len == 0) break;
        try out.appendSlice(alloc, chunk[0..read.data_len]);
    }
    return out.toOwnedSlice(alloc);
}

fn ask(alloc: Allocator, lease: *lease_mod.Lease, token: []const u8, op: []const u8, args: []const u8) ![]u8 {
    const line = try std.mem.concat(alloc, u8, &.{ "{\"v\":1,\"token\":\"", token, "\",\"id\":9,\"op\":\"", op, "\",\"args\":", args, "}\n" });
    defer alloc.free(line);
    return send(alloc, lease.socketPath(), line);
}

test "harness requests authenticate per connection and reach the node's services" {
    if (comptime @import("builtin").target.os.tag != .macos and @import("builtin").target.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var fake: Fake = .{};
    const lease = harness.open(.{ .node_id = "node-a", .home = home, .cwd = home, .services = fake.services(), .parent_call_id = "call-1" }) catch |err| {
        // A temporary directory too deep for a socket path is not this test's subject.
        if (err == error.HarnessSocketPathTooLong or err == error.HarnessSocketDirectoryUnsafe) return error.SkipZigTest;
        return err;
    };
    var closed = false;
    defer if (!closed) harness.close(lease);
    const token: []const u8 = &lease.token;

    const hello = try ask(alloc, lease, token, "hello", "{}");
    defer alloc.free(hello);
    try std.testing.expect(std.mem.find(u8, hello, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, hello, "\"node\":\"node-a\"") != null);

    const tool = try ask(alloc, lease, token, "tool", "{\"name\":\"read_file\",\"args\":{\"path\":\"a\"}}");
    defer alloc.free(tool);
    try std.testing.expect(std.mem.find(u8, tool, "harness:call-1:1 read_file {\\\"path\\\":\\\"a\\\"}") != null);

    const denied = try ask(alloc, lease, token, "tool", "{\"name\":\"write_file\"}");
    defer alloc.free(denied);
    try std.testing.expect(std.mem.find(u8, denied, "\"kind\":\"permission_denied\"") != null);

    const child = try ask(alloc, lease, token, "agent", "{\"prompt\":\"hi\"}");
    defer alloc.free(child);
    try std.testing.expect(std.mem.find(u8, child, "\"text\":\"child says hi\"") != null);

    const smuggled = try ask(alloc, lease, token, "tool", "{\"name\":\"read_file\",\"node\":\"other\"}");
    defer alloc.free(smuggled);
    try std.testing.expect(std.mem.find(u8, smuggled, "\"kind\":\"bad_request\"") != null);

    const unknown = try ask(alloc, lease, token, "nope", "{}");
    defer alloc.free(unknown);
    try std.testing.expect(std.mem.find(u8, unknown, "\"kind\":\"unknown_op\"") != null);

    var wrong = lease.token;
    wrong[0] = if (wrong[0] == '0') '1' else '0';
    const stranger = try ask(alloc, lease, &wrong, "tool", "{\"name\":\"read_file\"}");
    defer alloc.free(stranger);
    try std.testing.expect(std.mem.find(u8, stranger, "\"kind\":\"unauthorized\"") != null);

    const noted = try ask(alloc, lease, token, "process", "{\"pid\":42,\"argv\":[\"python\",\"-c\",\"pass\"]}");
    defer alloc.free(noted);
    try std.testing.expectEqual(@as(usize, 0), noted.len);
    try std.testing.expectEqual(@as(u32, 1), lease.processes.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 3), fake.calls.load(.monotonic));

    const kernels = try ask(alloc, lease, token, "kernel.status", "{}");
    defer alloc.free(kernels);
    try std.testing.expect(std.mem.find(u8, kernels, "\"kind\":\"unavailable\"") != null);

    // The socket is 0600 inside a 0700 folder.
    var info: std.c.Stat = undefined;
    const path_z = try alloc.dupeSentinel(u8, lease.socketPath(), 0);
    defer alloc.free(path_z);
    const io = io_mod.getIo();
    const socket_file = try std.Io.Dir.openFileAbsolute(io, std.Io.Dir.path.dirname(lease.socketPath()).?, .{});
    defer socket_file.close(io);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fstat(socket_file.handle, &info));
    try std.testing.expectEqual(@as(@TypeOf(info.mode), 0), info.mode & 0o077);

    const socket_path = try alloc.dupe(u8, lease.socketPath());
    defer alloc.free(socket_path);
    harness.close(lease);
    closed = true;
    // The node's socket is gone with its last lease.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, socket_path, .{}));
}
