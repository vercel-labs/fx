const std = @import("std");
const protocol = @import("code_mode_protocol");
const runtime = @import("runtime.zig");

pub fn main(init: std.process.Init) !void {
    var input_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try serve(
        std.heap.c_allocator,
        init.io,
        &input.interface,
        &output.interface,
    );
}

fn serve(
    alloc: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    try writeMessage(alloc, writer, .ready);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const payload = try protocol.readPayload(arena_state.allocator(), reader);
    const parent = try protocol.parseParentMessage(
        arena_state.allocator(),
        payload,
    );
    const source = switch (parent) {
        .execute => |value| value,
        else => return error.ExpectedExecute,
    };

    var program = try runtime.Runtime.init(alloc, .{
        .io = io,
        .memory_limit_bytes = 16 * 1024 * 1024,
        .stack_limit_bytes = 512 * 1024,
    });
    defer program.deinit();
    var dispatcher = ServiceDispatcher.init(alloc, reader, writer);
    defer dispatcher.deinit();
    const result = program.runProgram(
        alloc,
        source,
        .{
            .context = &dispatcher,
            .dispatch = ServiceDispatcher.dispatch,
        },
    ) catch |err| {
        try writeMessage(alloc, writer, .{ .failed = .{
            .kind = failureKind(&program, err),
            .message = program.failureMessage(@errorName(err)),
        } });
        return;
    };
    defer alloc.free(result);
    try writeMessage(alloc, writer, .{ .completed = result });
}

const ServiceDispatcher = struct {
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    response_arena: std.heap.ArenaAllocator,

    fn init(
        alloc: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) ServiceDispatcher {
        return .{
            .alloc = alloc,
            .reader = reader,
            .writer = writer,
            .response_arena = .init(alloc),
        };
    }

    fn deinit(self: *ServiceDispatcher) void {
        self.response_arena.deinit();
        self.* = undefined;
    }

    fn dispatch(
        raw: *anyopaque,
        requests: []const runtime.ToolRequest,
        responses: []runtime.ToolResponse,
    ) runtime.DispatchError!void {
        const self: *ServiceDispatcher = @ptrCast(@alignCast(raw));
        _ = self.response_arena.reset(.retain_capacity);
        const response_alloc = self.response_arena.allocator();
        for (requests, 0..) |request, index| {
            writeMessage(self.alloc, self.writer, .{ .tool_call = .{
                .id = request.id,
                .batch_index = @intCast(index),
                .batch_size = @intCast(requests.len),
                .name = request.name,
                .arguments_json = request.arguments_json,
            } }) catch return error.DispatchFailed;
        }

        var seen: u32 = 0;
        for (requests) |_| {
            const payload = protocol.readPayload(
                response_alloc,
                self.reader,
            ) catch return error.DispatchFailed;
            const parent = protocol.parseParentMessage(
                response_alloc,
                payload,
            ) catch return error.DispatchFailed;
            switch (parent) {
                .execute => return error.DispatchFailed,
                .tool_result => |result| {
                    var request_index: ?usize = null;
                    for (requests, 0..) |request, index| {
                        if (request.id == result.id) {
                            request_index = index;
                            break;
                        }
                    }
                    const index = request_index orelse
                        return error.DispatchFailed;
                    const bit = @as(u32, 1) << @intCast(index);
                    if (seen & bit != 0) return error.DispatchFailed;
                    seen |= bit;
                    responses[index] = switch (result.status) {
                        .success => .{ .success = result.value_json },
                        .failure => .{ .failure = result.value_json },
                    };
                },
            }
        }
    }
};

fn writeMessage(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: protocol.HostMessage,
) !void {
    const encoded = try protocol.encodeHostMessage(alloc, message);
    defer alloc.free(encoded);
    try protocol.writePayload(writer, encoded);
}

fn failureKind(
    program: *const runtime.Runtime,
    err: runtime.RuntimeError,
) protocol.FailureKind {
    return switch (err) {
        error.ExecutionLimitExceeded,
        error.SourceTooLarge,
        error.TooManyToolCalls,
        error.TooManyActiveToolCalls,
        => .limit,
        error.JavaScriptException => if (program.failureIsSyntax())
            .syntax
        else
            .runtime,
        error.InvalidProgramResult,
        error.ProgramStalled,
        => .runtime,
        error.InvalidToolResponse,
        error.PendingJobFailed,
        error.DispatchFailed,
        error.WriteFailed,
        => .protocol,
        error.OutOfMemory => .limit,
    };
}

test "service exchanges execute tool result and completion frames" {
    var input_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer input_bytes.deinit();
    try protocol.writePayload(
        &input_bytes.writer,
        "{\"version\":1,\"type\":\"execute\",\"source\":\"const result = await tools.read_file({ path: 'README.md' }); return result;\"}",
    );
    try protocol.writePayload(
        &input_bytes.writer,
        "{\"version\":1,\"type\":\"tool_result\",\"id\":0,\"status\":\"success\",\"value_json\":\"{\\\"path\\\":\\\"README.md\\\"}\"}",
    );

    var input = std.Io.Reader.fixed(input_bytes.written());
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try serve(std.testing.allocator, std.testing.io, &input, &output.writer);

    var output_reader = std.Io.Reader.fixed(output.written());
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var payload = try protocol.readPayload(arena, &output_reader);
    var message = try protocol.parseHostMessage(arena, payload);
    try std.testing.expect(message == .ready);

    payload = try protocol.readPayload(arena, &output_reader);
    message = try protocol.parseHostMessage(arena, payload);
    try std.testing.expect(message == .tool_call);
    try std.testing.expectEqualStrings("read_file", message.tool_call.name);

    payload = try protocol.readPayload(arena, &output_reader);
    message = try protocol.parseHostMessage(arena, payload);
    try std.testing.expect(message == .completed);
    try std.testing.expectEqualStrings(
        "{\"path\":\"README.md\"}",
        message.completed,
    );
}
