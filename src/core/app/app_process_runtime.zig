const std = @import("std");
const app_worker_runtime = @import("app_worker_runtime.zig");
const image_attachments = @import("../images/image_attachments.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn startWorkerThread(app: *App) !void {
            app.worker_thread = try std.Thread.spawn(.{}, workerThreadMain, .{app});
        }

        /// Starts one queued prompt on a single-threaded host. Prompt admission
        /// is presented before agent work can suspend on host transport.
        pub fn processNextCooperativePrompt(
            app: *App,
            event_handlers: app_worker_runtime.WorkerEventHandlers,
            flush_frame: *const fn (*App) anyerror!void,
        ) !void {
            const work = (try app.worker.tryTakeNextWork(std.heap.c_allocator)) orelse return;
            defer worker_runtime.freeWorkItem(std.heap.c_allocator, work);

            try app_worker_runtime.Runtime(App).tick(
                app,
                event_handlers,
            );
            try flush_frame(app);

            app.processQueuedWork(work) catch |err| {
                if (err != error.RouteRecoveryStopped) {
                    const body = try formatErrorBody(std.heap.c_allocator, "request failed", err);
                    defer std.heap.c_allocator.free(body);
                    try app.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                        .topic = "system",
                        .tone = .@"error",
                        .body = body,
                    } });
                }
            };
            app.worker.finishProcessing();
        }

        pub fn formatToolExecutionError(alloc: std.mem.Allocator, tool_name: []const u8, err: anyerror) ![]u8 {
            const error_detail = detailedErrorSummary(err);
            const details: []const tool_result_errors.Detail = if (error_detail) |detail|
                &[_]tool_result_errors.Detail{
                    .{ .name = "error", .value = .{ .string = @errorName(err) } },
                    .{ .name = "detail", .value = .{ .string = detail } },
                }
            else
                &[_]tool_result_errors.Detail{
                    .{ .name = "error", .value = .{ .string = @errorName(err) } },
                };

            return tool_result_errors.toolExecutionFailureJson(alloc, .{
                .tool_name = tool_name,
                .message = if (error_detail != null) "Tool execution failed while parsing or preparing data" else "Tool execution failed",
                .details = details,
                .suggestion = suggestionForError(err),
            });
        }

        fn detailedErrorSummary(err: anyerror) ?[]const u8 {
            return switch (err) {
                error.StreamInterrupted => "provider response ended before completion",
                error.UnexpectedEndOfInput => "incomplete JSON or internal response while parsing data",
                error.SyntaxError => "invalid JSON syntax while parsing data",
                error.MissingField => "required field missing while parsing data",
                error.InvalidEnumTag => "invalid enum value while parsing data",
                error.UnknownField => "unexpected field while parsing data",
                error.ImageTooLarge => image_attachments.image_too_large_notice,
                error.McpInputTimedOut => tool_result_errors.executionErrorMessage(err),
                else => null,
            };
        }

        fn suggestionForError(err: anyerror) ?[]const u8 {
            return switch (err) {
                error.UnexpectedEndOfInput, error.SyntaxError => "Check that the tool arguments are valid JSON and retry with corrected input.",
                error.MissingField => "Add the required input field named by the tool schema, then retry.",
                error.InvalidEnumTag, error.UnknownField => "Compare the input fields with the tool schema and retry with supported values.",
                error.ImageTooLarge => "Use a smaller image or reduce the image before retrying.",
                error.McpInputTimedOut => tool_result_errors.executionErrorSuggestion(err),
                else => null,
            };
        }

        fn formatErrorBody(alloc: std.mem.Allocator, context: []const u8, err: anyerror) ![]u8 {
            switch (err) {
                error.ConnectionSetupTimedOut => return alloc.dupe(u8, "Connection setup timed out after 30 seconds."),
                error.TlsInitializationFailed => return alloc.dupe(u8, "Connection setup failed: TLS could not be initialized."),
                error.ModelImageCapabilityUnavailable => return alloc.dupe(u8, image_attachments.model_image_capability_unavailable_notice),
                error.InvalidCompactionHandoff => return alloc.dupe(
                    u8,
                    "The model did not return a usable context summary. Your existing context was kept. Try /compact again or send a follow-up.",
                ),
                error.CompactionResultStorageUnavailable => return alloc.dupe(
                    u8,
                    "Context could not be compacted because older tool results could not be preserved. Save the session or restore writable session storage, then try again.",
                ),
                else => {},
            }
            if (detailedErrorSummary(err)) |detail| {
                return std.fmt.allocPrint(alloc, "{s}: {s} ({s})", .{ context, detail, @errorName(err) });
            }

            return std.fmt.allocPrint(alloc, "{s}: {s}", .{ context, @errorName(err) });
        }

        fn workerThreadMain(app: *App) void {
            workerLoop(app) catch |err| {
                const body = formatErrorBody(std.heap.c_allocator, "worker loop crashed", err) catch return;
                defer std.heap.c_allocator.free(body);
                app.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                    .topic = "system",
                    .tone = .@"error",
                    .body = body,
                } }) catch return;
            };
        }

        fn workerLoop(app: *App) !void {
            while (true) {
                const work = (try app.worker.waitAndTakeNextWork(std.heap.c_allocator)) orelse return;

                defer worker_runtime.freeWorkItem(std.heap.c_allocator, work);
                app.processQueuedWork(work) catch |err| {
                    if (err != error.RouteRecoveryStopped) {
                        const body = try formatErrorBody(std.heap.c_allocator, "request failed", err);
                        defer std.heap.c_allocator.free(body);
                        try app.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                            .topic = "system",
                            .tone = .@"error",
                            .body = body,
                        } });
                    }
                };

                app.worker.finishProcessing();
            }
        }
    };
}

const DummyApp = struct {
    worker: ?void = null,
    worker_thread: ?std.Thread = null,
};

test "formatToolExecutionError includes tool name" {
    const alloc = std.testing.allocator;
    const Rt = Runtime(DummyApp);
    const msg = try Rt.formatToolExecutionError(alloc, "write_file", error.FileNotFound);
    defer alloc.free(msg);
    try std.testing.expect(std.mem.find(u8, msg, "write_file") != null);
    try std.testing.expect(std.mem.find(u8, msg, "FileNotFound") != null);
    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(msg));
}

test "formatToolExecutionError includes detail for SyntaxError" {
    const alloc = std.testing.allocator;
    const Rt = Runtime(DummyApp);
    const msg = try Rt.formatToolExecutionError(alloc, "edit_file", error.SyntaxError);
    defer alloc.free(msg);
    try std.testing.expect(std.mem.find(u8, msg, "invalid JSON syntax") != null);
    try std.testing.expect(std.mem.find(u8, msg, "edit_file") != null);
}

test "formatErrorBody describes an interrupted provider response without presentation bytes" {
    const alloc = std.testing.allocator;
    const Rt = Runtime(DummyApp);
    const body = try Rt.formatErrorBody(alloc, "request failed", error.StreamInterrupted);
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "provider response ended before completion") != null);
    try std.testing.expect(std.mem.find(u8, body, "StreamInterrupted") != null);
    try std.testing.expect(std.mem.find(u8, body, "\x1b[") == null);
    try std.testing.expect(!std.mem.endsWith(u8, body, "\n"));
}

test "formatErrorBody explains unresolved image capability" {
    const alloc = std.testing.allocator;
    const Rt = Runtime(DummyApp);
    const body = try Rt.formatErrorBody(
        alloc,
        "request failed",
        error.ModelImageCapabilityUnavailable,
    );
    defer alloc.free(body);

    try std.testing.expectEqualStrings(
        "Unable to verify image support for this model, so the image was not sent. Try again later, choose another model, or remove the image.",
        body,
    );
    try std.testing.expect(std.mem.find(u8, body, "ModelImageCapabilityUnavailable") == null);
}

test "formatErrorBody describes terminal connection setup failures plainly" {
    const alloc = std.testing.allocator;
    const Rt = Runtime(DummyApp);

    const timeout = try Rt.formatErrorBody(alloc, "request failed", error.ConnectionSetupTimedOut);
    defer alloc.free(timeout);
    try std.testing.expectEqualStrings("Connection setup timed out after 30 seconds.", timeout);

    const tls = try Rt.formatErrorBody(alloc, "request failed", error.TlsInitializationFailed);
    defer alloc.free(tls);
    try std.testing.expectEqualStrings("Connection setup failed: TLS could not be initialized.", tls);

    for ([_][]const u8{ timeout, tls }) |body| {
        try std.testing.expect(std.mem.find(u8, body, "\x1b[") == null);
        try std.testing.expect(!std.mem.endsWith(u8, body, "\n"));
        try std.testing.expect(std.mem.find(u8, body, "ConnectionSetupTimedOut") == null);
        try std.testing.expect(std.mem.find(u8, body, "TlsInitializationFailed") == null);
    }

    const unrelated_timeout = try Rt.formatErrorBody(alloc, "request failed", error.ConnectionTimedOut);
    defer alloc.free(unrelated_timeout);
    try std.testing.expectEqualStrings("request failed: ConnectionTimedOut", unrelated_timeout);
}

test "formatErrorBody explains how to retry an unusable compaction summary" {
    const alloc = std.testing.allocator;
    const body = try Runtime(DummyApp).formatErrorBody(alloc, "request failed", error.InvalidCompactionHandoff);
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "context was kept") != null);
    try std.testing.expect(std.mem.find(u8, body, "/compact") != null);
    try std.testing.expect(std.mem.find(u8, body, "follow-up") != null);
}

test "formatErrorBody explains compaction result storage failure" {
    const alloc = std.testing.allocator;
    const Rt = Runtime(DummyApp);
    const body = try Rt.formatErrorBody(
        alloc,
        "request failed",
        error.CompactionResultStorageUnavailable,
    );
    defer alloc.free(body);

    try std.testing.expectEqualStrings(
        "Context could not be compacted because older tool results could not be preserved. Save the session or restore writable session storage, then try again.",
        body,
    );
}

test "formatToolExecutionError includes detail for MissingField" {
    const alloc = std.testing.allocator;
    const Rt = Runtime(DummyApp);
    const msg = try Rt.formatToolExecutionError(alloc, "read_file", error.MissingField);
    defer alloc.free(msg);
    try std.testing.expect(std.mem.find(u8, msg, "required field missing") != null);
}

test "formatToolExecutionError includes detail for ImageTooLarge" {
    const alloc = std.testing.allocator;
    const Rt = Runtime(DummyApp);
    const msg = try Rt.formatToolExecutionError(alloc, "image_tool", error.ImageTooLarge);
    defer alloc.free(msg);
    try std.testing.expect(std.mem.find(u8, msg, "image exceeds") != null);
}

test "formatToolExecutionError generic error has no detail" {
    const alloc = std.testing.allocator;
    const Rt = Runtime(DummyApp);
    const msg = try Rt.formatToolExecutionError(alloc, "run_command", error.OutOfMemory);
    defer alloc.free(msg);
    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(msg));
    try std.testing.expect(std.mem.find(u8, msg, "run_command") != null);
    try std.testing.expect(std.mem.find(u8, msg, "OutOfMemory") != null);
}

const TestWorkerApp = struct {
    worker: worker_runtime.WorkerRuntime = .{},
    worker_thread: ?std.Thread = null,
    first_process_error: ?anyerror = null,
    shutdown_after_count: usize = 1,
    processed_count: usize = 0,
    successful_count: usize = 0,
    saw_recovery_prompt: bool = false,

    fn deinit(self: *TestWorkerApp) void {
        if (self.worker_thread) |thread| {
            self.worker.requestShutdown();
            thread.join();
            self.worker_thread = null;
        }
        self.worker.deinit(std.heap.c_allocator);
    }

    fn processQueuedWork(self: *TestWorkerApp, work: worker_runtime.WorkItem) !void {
        self.processed_count += 1;
        if (self.processed_count >= self.shutdown_after_count) self.worker.requestShutdown();
        if (self.processed_count == 1) {
            if (self.first_process_error) |err| return err;
        }
        self.successful_count += 1;
        self.saw_recovery_prompt = switch (work) {
            .prompt => |job| std.mem.eql(u8, job.prompt, "recovery"),
            .compact_context => false,
        };
    }
};

fn makeQueuedPrompt(alloc: std.mem.Allocator, text: []const u8) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, text),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "test-key"),
        .permission_mode = .ask,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    };
}

fn queuePrompt(app: *TestWorkerApp, text: []const u8) !void {
    const prompt = try makeQueuedPrompt(std.heap.c_allocator, text);
    errdefer worker_runtime.freeQueuedPrompt(std.heap.c_allocator, prompt);
    try app.worker.enqueuePrompt(std.heap.c_allocator, prompt);
}

test "startWorkerThread processes queued prompt and exits on shutdown" {
    var app = TestWorkerApp{};
    defer app.deinit();

    try Runtime(TestWorkerApp).startWorkerThread(&app);
    try queuePrompt(&app, "hello");

    const thread = app.worker_thread.?;
    thread.join();
    app.worker_thread = null;

    try std.testing.expectEqual(@as(usize, 1), app.processed_count);
    const snapshot = try app.worker.snapshotState(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(!snapshot.processing);
    try std.testing.expectEqual(@as(usize, 0), snapshot.queued_count);
}

test "worker thread reports queued prompt failures as worker events" {
    var app = TestWorkerApp{ .first_process_error = error.SyntaxError };
    defer app.deinit();

    try Runtime(TestWorkerApp).startWorkerThread(&app);
    try queuePrompt(&app, "bad json");

    const thread = app.worker_thread.?;
    thread.join();
    app.worker_thread = null;

    var events = app.worker.takeEvents();
    defer events.deinit(std.heap.c_allocator);
    defer for (events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);

    var saw_error = false;
    for (events.items) |event| {
        switch (event) {
            .error_text => |notice| {
                saw_error = true;
                try std.testing.expectEqualStrings("system", notice.topic);
                try std.testing.expectEqual(types.NoticeTone.@"error", notice.tone);
                try std.testing.expect(std.mem.find(u8, notice.body, "request failed") != null);
                try std.testing.expect(std.mem.find(u8, notice.body, "invalid JSON syntax") != null);
                try std.testing.expect(std.mem.find(u8, notice.body, "SyntaxError") != null);
            },
            else => {},
        }
    }

    try std.testing.expect(saw_error);
}

test "worker continues after project context selector failures" {
    const errors = [_]anyerror{
        error.OutOfMemory,
        error.NoSpaceLeft,
        error.WriteFailed,
    };

    for (errors) |expected_error| {
        var app = TestWorkerApp{
            .first_process_error = expected_error,
            .shutdown_after_count = 2,
        };
        defer app.deinit();

        try queuePrompt(&app, "selector failure");
        try queuePrompt(&app, "recovery");
        try Runtime(TestWorkerApp).startWorkerThread(&app);

        const thread = app.worker_thread.?;
        thread.join();
        app.worker_thread = null;

        try std.testing.expectEqual(@as(usize, 2), app.processed_count);
        try std.testing.expectEqual(@as(usize, 1), app.successful_count);
        try std.testing.expect(app.saw_recovery_prompt);

        const snapshot = try app.worker.snapshotState(std.testing.allocator);
        defer snapshot.deinit(std.testing.allocator);
        try std.testing.expect(!snapshot.processing);
        try std.testing.expectEqual(@as(usize, 0), snapshot.queued_count);

        var events = app.worker.takeEvents();
        defer events.deinit(std.heap.c_allocator);
        defer for (events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);

        var error_count: usize = 0;
        for (events.items) |event| switch (event) {
            .error_text => |notice| {
                error_count += 1;
                try std.testing.expect(std.mem.find(u8, notice.body, "request failed") != null);
                try std.testing.expect(std.mem.find(u8, notice.body, @errorName(expected_error)) != null);
            },
            else => {},
        };
        try std.testing.expectEqual(@as(usize, 1), error_count);
    }
}
