const std = @import("std");
const host = @import("../hosts/host.zig");
const task_helpers = @import("../tasks/task_helpers.zig");
const types = @import("../shared/types.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const OpenUrlOutcome = struct {
    text: []const u8,
    succeeded: bool,
};

fn openUrlOutcome(
    alloc: std.mem.Allocator,
    opener: host.UrlOpener,
    url: []const u8,
    supported: bool,
) !OpenUrlOutcome {
    if (!supported) {
        return .{
            .text = try alloc.dupe(u8, "open_url not supported on this OS"),
            .succeeded = false,
        };
    }
    const succeeded = try opener.open(alloc, url);
    return .{
        .text = if (succeeded)
            try std.fmt.allocPrint(alloc, "opened {s}", .{url})
        else
            try std.fmt.allocPrint(alloc, "failed to open {s}", .{url}),
        .succeeded = succeeded,
    };
}

fn writeOpenResultNotice(app: anytype, result: OpenUrlOutcome) !void {
    try app.writeDomainNotice(.{
        .topic = "background",
        .tone = if (result.succeeded) .neutral else .@"error",
        .body = result.text,
    }, true);
}

fn parseSelectionOrUsage(app: anytype, target: []const u8, comptime usage: []const u8) !?task_helpers.StopSelection {
    return task_helpers.parseTaskSelection(target) catch {
        try app.writeDomainNotice(.{ .topic = "background", .tone = .@"error", .body = usage }, true);
        return null;
    };
}

pub fn Commands(comptime App: type) type {
    return struct {
        pub fn show(app: *App) !void {
            const tasks = try app.background.snapshotTasks(app.alloc);
            defer tasks.deinit(app.alloc);

            if (tasks.items.len == 0) {
                try app.writeDomainNotice(.{
                    .topic = "background",
                    .tone = .neutral,
                    .body = "no background processes for this workspace",
                }, true);
                return;
            }

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();

            try out.writer.print("{d} tracked\n", .{tasks.items.len});
            for (tasks.items) |task| {
                var state_buf: [32]u8 = undefined;
                const state_text = switch (task.state) {
                    .failed, .exited => if (task.exit_code) |code|
                        std.fmt.bufPrint(&state_buf, "{s}({d})", .{ task_helpers.taskStateLabel(task.state), code }) catch task_helpers.taskStateLabel(task.state)
                    else
                        task_helpers.taskStateLabel(task.state),
                    else => task_helpers.taskStateLabel(task.state),
                };

                try out.writer.print(" - #{d} [{s}] {s}\n", .{ task.id, state_text, task.command });
                try out.writer.print("   cwd: {s}\n", .{task.cwd});
                try out.writer.print("   log: {s}\n", .{task.log_path});
                if (task.server_url) |url| {
                    try out.writer.print("   url: {s}\n", .{url});
                }
            }

            const text = try out.toOwnedSlice();
            defer app.alloc.free(text);
            try app.writeDomainNotice(.{
                .topic = "background",
                .tone = .neutral,
                .body = std.mem.trimEnd(u8, text, "\n"),
            }, true);
        }

        pub fn stop(app: *App, target: []const u8) !void {
            const selection = (try parseSelectionOrUsage(app, target, "usage: /background stop <id|last>")) orelse return;

            const stopped = app.background.stopTask(std.heap.c_allocator, selection) catch |err| {
                const body = try std.fmt.allocPrint(app.alloc, "failed to stop task: {s}", .{@errorName(err)});
                defer app.alloc.free(body);
                try app.writeDomainNotice(.{ .topic = "background", .tone = .@"error", .body = body }, true);
                return;
            };
            if (stopped) |task_id| {
                const body = try std.fmt.allocPrint(app.alloc, "stopped background #{d}", .{task_id});
                defer app.alloc.free(body);
                try app.writeDomainNotice(.{ .topic = "background", .tone = .cancelled, .body = body }, true);
                return;
            }

            try app.writeDomainNotice(.{ .topic = "background", .tone = .neutral, .body = "no matching running background process" }, true);
        }

        pub fn open(app: *App, target: []const u8) !void {
            const selection = (try parseSelectionOrUsage(app, target, "usage: /background open <id|last>")) orelse return;

            const task = try app.background.snapshotTask(app.alloc, selection);
            if (task == null) {
                try app.writeDomainNotice(.{ .topic = "background", .tone = .neutral, .body = "no matching background process" }, true);
                return;
            }
            defer task.?.deinit(app.alloc);

            const snapshot = task.?;
            const url = snapshot.server_url orelse {
                try app.writeDomainNotice(.{ .topic = "background", .tone = .neutral, .body = "background process has no known URL yet" }, true);
                return;
            };
            if (snapshot.state != .running) {
                try app.writeDomainNotice(.{ .topic = "background", .tone = .neutral, .body = "background process is no longer running; saved URL is stale" }, true);
                return;
            }

            const result = try openUrlOutcome(
                app.alloc,
                app.urlOpener(),
                url,
                host.current().url_open,
            );
            defer app.alloc.free(result.text);
            try writeOpenResultNotice(app, result);
        }

        pub fn logs(app: *App, target: []const u8) !void {
            const selection = (try parseSelectionOrUsage(app, target, "usage: /background logs <id|last>")) orelse return;

            const task = try app.background.snapshotTask(app.alloc, selection);
            if (task == null) {
                try app.writeDomainNotice(.{ .topic = "background", .tone = .neutral, .body = "no matching background process" }, true);
                return;
            }
            defer task.?.deinit(app.alloc);

            const log_text = if (@hasDecl(
                @TypeOf(app.background),
                "readTaskLogSummaryBody",
            ))
                app.background.readTaskLogSummaryBody(
                    app.alloc,
                    selection,
                    16 * 1024,
                    16 * 1024,
                    40,
                )
            else
                task_helpers.readExternalTaskLogSummaryBody(
                    app.alloc,
                    task.?.log_path,
                    16 * 1024,
                    16 * 1024,
                    40,
                );
            const resolved_log_text = log_text catch |err| {
                const body = try std.fmt.allocPrint(app.alloc, "failed to read task log: {s}", .{@errorName(err)});
                defer app.alloc.free(body);
                try app.writeDomainNotice(.{ .topic = "logs", .tone = .@"error", .body = body }, true);
                return;
            };
            defer app.alloc.free(resolved_log_text);
            try app.writeDomainNotice(.{
                .topic = "logs",
                .tone = .neutral,
                .body = std.mem.trimEnd(u8, resolved_log_text, "\n"),
            }, true);
        }
    };
}

const FakeTask = struct {
    id: u64,
    command: []const u8,
    cwd: []const u8,
    log_path: []const u8,
    server_url: ?[]const u8 = null,
    exit_code: ?i32 = null,
    state: task_helpers.TaskState = .running,

    fn deinit(self: FakeTask, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

const FakeTaskList = struct {
    items: []FakeTask,

    fn deinit(self: FakeTaskList, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

const FakeBackground = struct {
    tasks: []FakeTask = &.{},
    stop_result: ?u64 = null,
    stop_error: ?anyerror = null,
    last_stop_selection: ?task_helpers.StopSelection = null,

    fn snapshotTasks(self: *FakeBackground, alloc: std.mem.Allocator) !FakeTaskList {
        _ = alloc;
        return .{ .items = self.tasks };
    }

    fn stopTask(self: *FakeBackground, alloc: std.mem.Allocator, selection: task_helpers.StopSelection) !?u64 {
        _ = alloc;
        self.last_stop_selection = selection;
        if (self.stop_error) |err| return err;
        return self.stop_result;
    }

    fn snapshotTask(self: *FakeBackground, alloc: std.mem.Allocator, selection: task_helpers.StopSelection) !?FakeTask {
        _ = alloc;
        const target_id = switch (selection) {
            .last => if (self.tasks.len == 0) return null else self.tasks[self.tasks.len - 1].id,
            .id => |id| id,
        };
        for (self.tasks) |task| {
            if (task.id == target_id) return task;
        }
        return null;
    }
};

const FakeApp = struct {
    alloc: std.mem.Allocator,
    background: FakeBackground = .{},
    transcript: std.ArrayList(u8) = .empty,
    last_tone: ?types.NoticeTone = null,
    url_open_calls: usize = 0,

    fn deinit(self: *FakeApp) void {
        self.transcript.deinit(self.alloc);
    }

    fn urlOpener(self: *FakeApp) host.UrlOpener {
        return .{
            .context = self,
            .open_fn = openUrl,
        };
    }

    fn openUrl(raw: ?*anyopaque, _: std.mem.Allocator, _: []const u8) host.UrlOpenError!bool {
        const self: *FakeApp = @ptrCast(@alignCast(raw.?));
        self.url_open_calls += 1;
        return true;
    }

    fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.last_tone = notice.tone;
        try self.transcript.appendSlice(self.alloc, notice.body);
        try self.transcript.append(self.alloc, '\n');
    }

    fn text(self: *const FakeApp) []const u8 {
        return self.transcript.items;
    }
};

const EntryReplayApp = struct {
    alloc: std.mem.Allocator,
    shell: transcript_runtime.TranscriptRuntime = .{},
    write_count: usize = 0,
    last_tone: ?types.NoticeTone = null,

    fn deinit(self: *EntryReplayApp) void {
        self.shell.deinit(self.alloc);
    }

    fn writeDomainNotice(self: *EntryReplayApp, notice: types.SemanticNotice, _: bool) !void {
        self.write_count += 1;
        self.last_tone = notice.tone;
        _ = try self.shell.appendSemanticNotice(self.alloc, notice);
    }
};

fn expectTranscript(app: *const FakeApp, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, app.text());
}

fn noticeText(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\n", .{text});
}

fn writeAbsoluteFile(path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(@import("../shared/io.zig").getIo(), path, .{ .truncate = true });
    defer file.close(@import("../shared/io.zig").getIo());
    try file.writeStreamingAll(@import("../shared/io.zig").getIo(), text);
}

fn tmpPath(alloc: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    const io_mod = @import("../shared/io.zig");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

test "show reports empty task list" {
    const alloc = std.testing.allocator;
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();

    try Commands(FakeApp).show(&app);

    const expected = try noticeText(alloc, "no background processes for this workspace");
    defer alloc.free(expected);
    try expectTranscript(&app, expected);
}

test "show reports tracked tasks" {
    const alloc = std.testing.allocator;
    var tasks = [_]FakeTask{
        .{
            .id = 1,
            .command = "npm run dev",
            .cwd = "/tmp/app",
            .log_path = "/tmp/fx-one.log",
            .server_url = "http://localhost:3000",
            .state = .running,
        },
        .{
            .id = 2,
            .command = "zig build test",
            .cwd = "/tmp/fx",
            .log_path = "/tmp/fx-two.log",
            .exit_code = 2,
            .state = .failed,
        },
    };
    var app = FakeApp{ .alloc = alloc, .background = .{ .tasks = tasks[0..] } };
    defer app.deinit();

    try Commands(FakeApp).show(&app);

    try expectTranscript(&app,
        \\2 tracked
        \\ - #1 [running] npm run dev
        \\   cwd: /tmp/app
        \\   log: /tmp/fx-one.log
        \\   url: http://localhost:3000
        \\ - #2 [failed(2)] zig build test
        \\   cwd: /tmp/fx
        \\   log: /tmp/fx-two.log
        \\
    );
}

test "stop reports parse errors no match success and stop errors" {
    const alloc = std.testing.allocator;

    {
        var app = FakeApp{ .alloc = alloc };
        defer app.deinit();
        try Commands(FakeApp).stop(&app, "abc");
        const expected = try noticeText(alloc, "usage: /background stop <id|last>");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
    }

    {
        var app = FakeApp{ .alloc = alloc };
        defer app.deinit();
        try Commands(FakeApp).stop(&app, "last");
        const expected = try noticeText(alloc, "no matching running background process");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
        try std.testing.expectEqual(task_helpers.StopSelection.last, app.background.last_stop_selection.?);
    }

    {
        var app = FakeApp{ .alloc = alloc, .background = .{ .stop_result = 7 } };
        defer app.deinit();
        try Commands(FakeApp).stop(&app, "7");
        const expected = try noticeText(alloc, "stopped background #7");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
        try std.testing.expectEqual(task_helpers.StopSelection{ .id = 7 }, app.background.last_stop_selection.?);
    }

    {
        var app = FakeApp{ .alloc = alloc, .background = .{ .stop_error = error.AccessDenied } };
        defer app.deinit();
        try Commands(FakeApp).stop(&app, "7");
        const expected = try noticeText(alloc, "failed to stop task: AccessDenied");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
    }
}

test "open reports parse errors no match and missing URL without launching opener" {
    const alloc = std.testing.allocator;

    {
        var app = FakeApp{ .alloc = alloc };
        defer app.deinit();
        try Commands(FakeApp).open(&app, "abc");
        const expected = try noticeText(alloc, "usage: /background open <id|last>");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
    }

    {
        var app = FakeApp{ .alloc = alloc };
        defer app.deinit();
        try Commands(FakeApp).open(&app, "last");
        const expected = try noticeText(alloc, "no matching background process");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
    }

    {
        var tasks = [_]FakeTask{.{
            .id = 7,
            .command = "npm run dev",
            .cwd = "/tmp/app",
            .log_path = "/tmp/fx.log",
            .state = .stopped,
        }};
        var app = FakeApp{ .alloc = alloc, .background = .{ .tasks = tasks[0..] } };
        defer app.deinit();
        try Commands(FakeApp).open(&app, "7");
        const expected = try noticeText(alloc, "background process has no known URL yet");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
        try std.testing.expectEqual(@as(usize, 0), app.url_open_calls);
    }
}

test "open rejects saved URLs for non-running tasks without launching opener" {
    const alloc = std.testing.allocator;
    const states = [_]task_helpers.TaskState{ .exited, .failed, .stopped, .dead, .stale };

    for (states) |state| {
        var tasks = [_]FakeTask{.{
            .id = 7,
            .command = "npm run dev",
            .cwd = "/tmp/app",
            .log_path = "/tmp/fx.log",
            .server_url = "http://localhost:3000",
            .state = state,
        }};
        var app = FakeApp{ .alloc = alloc, .background = .{ .tasks = tasks[0..] } };
        defer app.deinit();

        try Commands(FakeApp).open(&app, "7");

        const expected = try noticeText(alloc, "background process is no longer running; saved URL is stale");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
        try std.testing.expectEqual(@as(usize, 0), app.url_open_calls);
    }
}

test "open launches a saved URL for a running task" {
    const alloc = std.testing.allocator;
    var tasks = [_]FakeTask{.{
        .id = 7,
        .command = "npm run dev",
        .cwd = "/tmp/app",
        .log_path = "/tmp/fx.log",
        .server_url = "http://localhost:3000",
    }};
    var app = FakeApp{ .alloc = alloc, .background = .{ .tasks = tasks[0..] } };
    defer app.deinit();

    try Commands(FakeApp).open(&app, "7");

    const expected = try noticeText(alloc, "opened http://localhost:3000");
    defer alloc.free(expected);
    try expectTranscript(&app, expected);
    try std.testing.expectEqual(@as(usize, 1), app.url_open_calls);
}

test "background open result replays as one notice without outer newline" {
    const alloc = std.testing.allocator;
    var app = EntryReplayApp{ .alloc = alloc };
    defer app.deinit();

    try writeOpenResultNotice(&app, .{
        .text = "opened http://localhost:3000",
        .succeeded = true,
    });

    try std.testing.expectEqual(@as(usize, 1), app.shell.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.write_count);
    try std.testing.expectEqual(types.NoticeTone.neutral, app.last_tone.?);

    const rendered = try transcript_runtime.renderEntriesToBytes(alloc, app.shell.entries.items, 80, .{});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("● Background: opened http://localhost:3000", rendered);
}

test "background open preserves opened failed and unsupported output" {
    const Capture = struct {
        calls: usize = 0,
        succeeds: bool,

        fn open(
            raw: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
        ) host.UrlOpenError!bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return self.succeeds;
        }
    };
    const alloc = std.testing.allocator;
    const url = "http://localhost:3000";
    var capture = Capture{ .succeeds = false };
    const opener = host.UrlOpener{
        .context = &capture,
        .open_fn = Capture.open,
    };

    const failed = try openUrlOutcome(
        alloc,
        opener,
        url,
        host.nativeForOs(.linux).url_open,
    );
    defer alloc.free(failed.text);
    try std.testing.expect(!failed.succeeded);
    try std.testing.expectEqualStrings(
        "failed to open http://localhost:3000",
        failed.text,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);

    capture.succeeds = true;
    const opened = try openUrlOutcome(
        alloc,
        opener,
        url,
        host.nativeForOs(.macos).url_open,
    );
    defer alloc.free(opened.text);
    try std.testing.expect(opened.succeeded);
    try std.testing.expectEqualStrings(
        "opened http://localhost:3000",
        opened.text,
    );
    try std.testing.expectEqual(@as(usize, 2), capture.calls);

    const unsupported = try openUrlOutcome(
        alloc,
        opener,
        url,
        host.nativeForOs(.freebsd).url_open,
    );
    defer alloc.free(unsupported.text);
    try std.testing.expect(!unsupported.succeeded);
    try std.testing.expectEqualStrings(
        "open_url not supported on this OS",
        unsupported.text,
    );
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
}

test "logs reports parse errors no match and log read failures" {
    const alloc = std.testing.allocator;

    {
        var app = FakeApp{ .alloc = alloc };
        defer app.deinit();
        try Commands(FakeApp).logs(&app, "abc");
        const expected = try noticeText(alloc, "usage: /background logs <id|last>");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
    }

    {
        var app = FakeApp{ .alloc = alloc };
        defer app.deinit();
        try Commands(FakeApp).logs(&app, "last");
        const expected = try noticeText(alloc, "no matching background process");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const missing = try tmpPath(alloc, tmp, "missing.log");
        defer alloc.free(missing);
        var tasks = [_]FakeTask{.{
            .id = 7,
            .command = "npm run dev",
            .cwd = "/tmp/app",
            .log_path = missing,
        }};
        var app = FakeApp{ .alloc = alloc, .background = .{ .tasks = tasks[0..] } };
        defer app.deinit();

        try Commands(FakeApp).logs(&app, "7");
        const expected = try noticeText(alloc, "failed to read task log: FileNotFound");
        defer alloc.free(expected);
        try expectTranscript(&app, expected);
    }
}

test "logs writes successful log tail" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(alloc, tmp, "task.log");
    defer alloc.free(path);
    try writeAbsoluteFile(path, "one\ntwo\nthree\n");

    var tasks = [_]FakeTask{.{
        .id = 7,
        .command = "npm run dev",
        .cwd = "/tmp/app",
        .log_path = path,
    }};
    var app = FakeApp{ .alloc = alloc, .background = .{ .tasks = tasks[0..] } };
    defer app.deinit();

    try Commands(FakeApp).logs(&app, "last");

    const expected = try std.fmt.allocPrint(alloc, "{s}\nbytes=14\n<head>\none\ntwo\nthree\n</head>\n<tail>\none\ntwo\nthree\n</tail>\n", .{path});
    defer alloc.free(expected);
    try expectTranscript(&app, expected);
}
