const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../shared/io.zig");
const protocol = @import("../code_mode_protocol.zig");

pub const NestedRequest = struct {
    id: u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const NestedResponse = union(enum) {
    success: []const u8,
    failure: []const u8,
    approval_required: []const u8,
    indeterminate: []const u8,
};

pub const DispatchError = error{
    OutOfMemory,
    Cancelled,
    DispatchFailed,
};

pub const Dispatcher = struct {
    context: *anyopaque,
    dispatch: *const fn (
        context: *anyopaque,
        requests: []const NestedRequest,
        responses: []NestedResponse,
    ) DispatchError!void,
};

pub const Request = struct {
    helper_path: []const u8,
    source: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    dispatcher: Dispatcher,
};

pub const Failure = struct {
    kind: protocol.FailureKind,
    message: []u8,
};

pub const Result = union(enum) {
    completed: []u8,
    failed: Failure,

    pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
        switch (self) {
            .completed => |value| alloc.free(value),
            .failed => |failure| alloc.free(failure.message),
        }
    }
};

pub fn resolveHelperPath(alloc: std.mem.Allocator) ![]u8 {
    const current_z = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(current_z);
    const current = std.mem.sliceTo(current_z, 0);
    const directory = std.fs.path.dirname(current) orelse
        return error.CodeHostPathUnavailable;
    return std.fs.path.join(alloc, &.{
        directory,
        if (builtin.os.tag == .windows) "fx-code-host.exe" else "fx-code-host",
    });
}

pub fn run(alloc: std.mem.Allocator, request: Request) !Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const io = io_mod.getIo();
    var child = try std.process.spawn(io, .{
        .argv = &.{request.helper_path},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var child_needs_cleanup = true;
    defer if (child_needs_cleanup) child.kill(io);

    var input_buffer: [64 * 1024]u8 = undefined;
    var output_buffer: [64 * 1024]u8 = undefined;
    var child_input = child.stdin.?.writer(io, &input_buffer);
    var child_output = child.stdout.?.reader(io, &output_buffer);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const ready = try readHostMessage(
        arena_state.allocator(),
        &child_output.interface,
    );
    if (ready != .ready) return error.CodeHostProtocolViolation;
    try writeParentMessage(
        arena_state.allocator(),
        &child_input.interface,
        .{ .execute = request.source },
    );

    while (true) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const message = try readHostMessageCancellable(
            arena,
            &child_output.interface,
            request.cancel_flag,
        );
        switch (message) {
            .ready => return error.CodeHostProtocolViolation,
            .failed => |failure| {
                return .{ .failed = .{
                    .kind = failure.kind,
                    .message = try alloc.dupe(u8, failure.message),
                } };
            },
            .completed => |result| {
                const owned = try alloc.dupe(u8, result);
                child.stdin.?.close(io);
                child.stdin = null;
                const term = try child.wait(io);
                child_needs_cleanup = false;
                switch (term) {
                    .exited => |code| if (code != 0) {
                        alloc.free(owned);
                        return error.CodeHostFailed;
                    },
                    .signal, .stopped, .unknown => {
                        alloc.free(owned);
                        return error.CodeHostFailed;
                    },
                }
                return .{ .completed = owned };
            },
            .tool_call => |first| {
                if (try dispatchBatch(
                    arena,
                    request.dispatcher,
                    first,
                    &child_output.interface,
                    &child_input.interface,
                )) |failure| {
                    return .{ .failed = .{
                        .kind = failure.kind,
                        .message = try alloc.dupe(u8, failure.message),
                    } };
                }
            },
        }
    }
}

fn dispatchBatch(
    arena: std.mem.Allocator,
    dispatcher: Dispatcher,
    first: protocol.ToolCall,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !?protocol.Failure {
    if (first.batch_index != 0) return error.CodeHostProtocolViolation;
    const requests = try arena.alloc(NestedRequest, first.batch_size);
    const responses = try arena.alloc(NestedResponse, first.batch_size);
    requests[0] = nestedRequest(first);
    for (1..first.batch_size) |index| {
        const message = try readHostMessage(arena, reader);
        const call = switch (message) {
            .tool_call => |value| value,
            else => return error.CodeHostProtocolViolation,
        };
        if (call.batch_size != first.batch_size or
            call.batch_index != index)
        {
            return error.CodeHostProtocolViolation;
        }
        requests[index] = nestedRequest(call);
    }
    try dispatcher.dispatch(dispatcher.context, requests, responses);
    for (responses) |response| switch (response) {
        .approval_required => |message| return .{
            .kind = .approval_required,
            .message = message,
        },
        .indeterminate => |message| return .{
            .kind = .indeterminate,
            .message = message,
        },
        .success, .failure => {},
    };
    for (requests, responses) |nested, response| {
        const result = switch (response) {
            .success => |value| protocol.ToolResult{
                .id = nested.id,
                .status = .success,
                .value_json = value,
            },
            .failure => |value| protocol.ToolResult{
                .id = nested.id,
                .status = .failure,
                .value_json = value,
            },
            .approval_required, .indeterminate => unreachable,
        };
        try writeParentMessage(arena, writer, .{ .tool_result = result });
    }
    return null;
}

fn nestedRequest(call: protocol.ToolCall) NestedRequest {
    return .{
        .id = call.id,
        .name = call.name,
        .arguments_json = call.arguments_json,
    };
}

fn readHostMessage(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
) !protocol.HostMessage {
    const payload = try protocol.readPayload(alloc, reader);
    return protocol.parseHostMessage(alloc, payload);
}

fn readHostMessageCancellable(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    cancel_flag: *std.atomic.Value(bool),
) !protocol.HostMessage {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const Event = union(enum) {
        message: anyerror!protocol.HostMessage,
        cancelled: anyerror!void,
    };
    const Reader = struct {
        fn run(
            message_alloc: std.mem.Allocator,
            source: *std.Io.Reader,
        ) anyerror!protocol.HostMessage {
            return readHostMessage(message_alloc, source);
        }
    };
    const Cleanup = struct {
        fn drain(select: *std.Io.Select(Event)) void {
            while (select.cancel()) |_| {}
        }
    };

    var select_buffer: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    try select.concurrent(.message, Reader.run, .{ alloc, reader });
    select.concurrent(.cancelled, waitForCancellation, .{cancel_flag}) catch |err| {
        Cleanup.drain(&select);
        return err;
    };
    const event = select.await() catch |err| {
        Cleanup.drain(&select);
        return err;
    };
    return switch (event) {
        .message => |result| result: {
            const message = result catch |err| {
                Cleanup.drain(&select);
                return err;
            };
            Cleanup.drain(&select);
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            break :result message;
        },
        .cancelled => |result| result: {
            result catch |err| {
                Cleanup.drain(&select);
                return err;
            };
            Cleanup.drain(&select);
            break :result error.Cancelled;
        },
    };
}

fn waitForCancellation(cancel_flag: *std.atomic.Value(bool)) anyerror!void {
    while (!cancel_flag.load(.seq_cst)) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn writeParentMessage(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: protocol.ParentMessage,
) !void {
    const encoded = try protocol.encodeParentMessage(alloc, message);
    defer alloc.free(encoded);
    try protocol.writePayload(writer, encoded);
}

test "controller delegates one Promise batch through the real companion" {
    const helper_path_z = std.c.getenv("FX_TEST_CODE_HOST_EXE") orelse
        return error.SkipZigTest;
    const helper_path = std.mem.span(helper_path_z);
    const Capture = struct {
        batch_size: usize = 0,

        fn dispatch(
            raw: *anyopaque,
            requests: []const NestedRequest,
            responses: []NestedResponse,
        ) DispatchError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.batch_size = requests.len;
            for (requests, responses) |request, *response| {
                response.* = if (std.mem.find(
                    u8,
                    request.arguments_json,
                    "alpha",
                ) != null)
                    .{ .success = "{\"path\":\"alpha\"}" }
                else
                    .{ .success = "{\"path\":\"beta\"}" };
            }
        }
    };

    var capture: Capture = .{};
    var cancel = std.atomic.Value(bool).init(false);
    const result = try run(std.testing.allocator, .{
        .helper_path = helper_path,
        .source =
        \\const [alpha, beta] = await Promise.all([
        \\  tools.read_file({ path: "alpha" }),
        \\  tools.read_file({ path: "beta" }),
        \\]);
        \\return [alpha.path, beta.path];
        ,
        .cancel_flag = &cancel,
        .dispatcher = .{
            .context = &capture,
            .dispatch = Capture.dispatch,
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), capture.batch_size);
    try std.testing.expect(result == .completed);
    try std.testing.expectEqualStrings(
        "[\"alpha\",\"beta\"]",
        result.completed,
    );
}

test "controller cancellation interrupts a busy companion" {
    const helper_path_z = std.c.getenv("FX_TEST_CODE_HOST_EXE") orelse
        return error.SkipZigTest;
    const helper_path = std.mem.span(helper_path_z);
    const Unused = struct {
        fn dispatch(
            _: *anyopaque,
            _: []const NestedRequest,
            _: []NestedResponse,
        ) DispatchError!void {
            return error.DispatchFailed;
        }
    };
    const Trigger = struct {
        fn run(cancel_flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(25 * std.time.ns_per_ms);
            cancel_flag.store(true, .seq_cst);
        }
    };

    var unused: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    const trigger = try std.Thread.spawn(.{}, Trigger.run, .{&cancel});
    defer trigger.join();
    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.Cancelled,
        run(std.testing.allocator, .{
            .helper_path = helper_path,
            .source = "while (true) {}",
            .cancel_flag = &cancel,
            .dispatcher = .{
                .context = &unused,
                .dispatch = Unused.dispatch,
            },
        }),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
}

test "controller stops approval-required programs even when source catches rejection" {
    const helper_path_z = std.c.getenv("FX_TEST_CODE_HOST_EXE") orelse
        return error.SkipZigTest;
    const helper_path = std.mem.span(helper_path_z);
    const Approval = struct {
        fn dispatch(
            _: *anyopaque,
            requests: []const NestedRequest,
            responses: []NestedResponse,
        ) DispatchError!void {
            std.debug.assert(requests.len == 1);
            responses[0] = .{
                .approval_required = "approval_required: direct call needed",
            };
        }
    };

    var context: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    const result = try run(std.testing.allocator, .{
        .helper_path = helper_path,
        .source =
        \\try {
        \\  await tools.terminal({ action: "exec", command: "true" });
        \\} catch (_) {}
        \\return "must not complete";
        ,
        .cancel_flag = &cancel,
        .dispatcher = .{
            .context = &context,
            .dispatch = Approval.dispatch,
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result == .failed);
    try std.testing.expectEqual(
        protocol.FailureKind.approval_required,
        result.failed.kind,
    );
    try std.testing.expectEqualStrings(
        "approval_required: direct call needed",
        result.failed.message,
    );
}

test "controller fails closed when the companion path is missing" {
    const Unused = struct {
        fn dispatch(
            _: *anyopaque,
            _: []const NestedRequest,
            _: []NestedResponse,
        ) DispatchError!void {
            return error.DispatchFailed;
        }
    };
    var context: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.FileNotFound,
        run(std.testing.allocator, .{
            .helper_path = "/definitely/missing/fx-code-host",
            .source = "return null;",
            .cancel_flag = &cancel,
            .dispatcher = .{
                .context = &context,
                .dispatch = Unused.dispatch,
            },
        }),
    );
}
