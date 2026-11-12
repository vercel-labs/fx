//! `/loop` on the app thread: the command's notices, and the glue between an
//! agent's `loops.Loops` and the worker that runs each loop's prompt. Every
//! function runs on the main loop, the only thread that touches `Loops`.

const std = @import("std");
const loops = @import("../loops/loops.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");

/// Longest prompt excerpt a notice shows, after terminal-safe encoding.
const max_prompt_display_bytes: usize = 200;

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Runs `/loop <payload>` for `agent`, the agent on screen.
        pub fn handleCommand(app: *App, agent: anytype, payload: []const u8) !void {
            const command = loops.parseCommand(payload) catch |err| return writeParseError(app, err, payload);
            switch (command) {
                .list => try writeList(app, agent),
                .arm => |arm| try armLoop(app, agent, arm.interval_ms, arm.prompt),
                .stop => |target| try stopLoops(app, agent, target),
                .resume_loop => |id| try resumeLoop(app, agent, id),
            }
        }

        fn armLoop(app: *App, agent: anytype, interval_ms: u64, prompt: []const u8) !void {
            const id = agent.loops.arm(app.alloc, interval_ms, prompt, app_permission_runtime.monotonicMillis()) catch |err| switch (err) {
                error.TooManyLoops => return writeNotice(app, .warning, "A conversation holds at most {d} loops. Stop one with /loop stop <id>.", .{loops.max_loops}),
                error.OutOfMemory => return err,
            };
            debug_trace.logf("loop", "event=armed id={d} interval_ms={d}", .{ id, interval_ms });
            var shown = try text_utils.encodeTerminalSafe(app.alloc, prompt, max_prompt_display_bytes);
            defer shown.deinit(app.alloc);
            var interval_buf: [32]u8 = undefined;
            try writeNotice(app, .neutral, "Loop {d} runs every {s} until you stop it or fx exits: {s}", .{ id, formatInterval(&interval_buf, interval_ms), shown.bytes });
        }

        fn writeList(app: *App, agent: anytype) !void {
            if (agent.loops.count() == 0) return writeNotice(app, .neutral, "No active loops. Start one with /loop <interval> <prompt>.", .{});
            const now_ms = app_permission_runtime.monotonicMillis();
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(app.alloc);
            for (agent.loops.items.items, 0..) |loop, index| {
                if (index > 0) try body.append(app.alloc, '\n');
                var interval_buf: [32]u8 = undefined;
                var when_buf: [64]u8 = undefined;
                const when = switch (loop.state) {
                    .paused => try std.mem.print(&when_buf, "paused · /loop resume {d}", .{loop.id}),
                    .running => "running now",
                    .waiting => try std.mem.print(&when_buf, "next in {s}", .{formatRemaining(&interval_buf, loop.next_due_ms - now_ms)}),
                };
                var every_buf: [32]u8 = undefined;
                var shown = try text_utils.encodeTerminalSafe(app.alloc, loop.prompt, max_prompt_display_bytes);
                defer shown.deinit(app.alloc);
                const row = try app.alloc.print("{d}  every {s}  {s}  runs {d}  failures {d}/{d}  {s}", .{
                    loop.id,
                    formatInterval(&every_buf, loop.interval_ms),
                    when,
                    loop.runs,
                    loop.consecutive_failures,
                    loops.pause_after_failures,
                    shown.bytes,
                });
                defer app.alloc.free(row);
                try body.appendSlice(app.alloc, row);
            }
            try app.writeDomainNotice(.{ .topic = "loop", .tone = .neutral, .body = body.items }, true);
        }

        fn stopLoops(app: *App, agent: anytype, target: loops.Target) !void {
            switch (target) {
                .id => |id| {
                    _ = agent.loops.stop(app.alloc, target) catch return writeUnknownLoop(app, id);
                    debug_trace.logf("loop", "event=stopped id={d}", .{id});
                    try writeNotice(app, .neutral, "Stopped loop {d}.", .{id});
                },
                .all => {
                    if (agent.loops.count() == 0) return writeNotice(app, .neutral, "No active loops.", .{});
                    const ids = try idList(app, agent);
                    defer app.alloc.free(ids);
                    const stopped = agent.loops.endAll(app.alloc);
                    debug_trace.logf("loop", "event=stopped ids={s}", .{ids});
                    try writeNotice(app, .neutral, "Stopped {s} {s}.", .{ loopWord(stopped), ids });
                },
            }
        }

        fn resumeLoop(app: *App, agent: anytype, id: u32) !void {
            agent.loops.resumeLoop(id, app_permission_runtime.monotonicMillis()) catch |err| switch (err) {
                error.UnknownLoop => return writeUnknownLoop(app, id),
                error.NotPaused => return writeNotice(app, .neutral, "Loop {d} is not paused.", .{id}),
            };
            debug_trace.logf("loop", "event=resumed id={d}", .{id});
            const loop = for (agent.loops.items.items) |item| {
                if (item.id == id) break item;
            } else unreachable;
            var interval_buf: [32]u8 = undefined;
            try writeNotice(app, .neutral, "Resumed loop {d}. Next run in {s}.", .{ id, formatInterval(&interval_buf, loop.interval_ms) });
        }

        fn writeUnknownLoop(app: *App, id: u32) !void {
            try writeNotice(app, .warning, "No loop {d}. /loop lists active loops.", .{id});
        }

        fn writeParseError(app: *App, err: loops.ParseError, payload: []const u8) !void {
            const text = std.mem.trim(u8, payload, " \t");
            const token = text[0 .. std.mem.findAny(u8, text, " \t") orelse text.len];
            var shown = try text_utils.encodeTerminalSafe(app.alloc, token, 64);
            defer shown.deinit(app.alloc);
            switch (err) {
                error.IntervalTooShort => try writeNotice(app, .warning, "{s} is shorter than the 1m minimum.", .{shown.bytes}),
                error.IntervalTooLong => try writeNotice(app, .warning, "{s} is longer than the 365d maximum.", .{shown.bytes}),
                error.InvalidInterval => try writeNotice(app, .warning, "{s} is not an interval. Use one such as 5m, 2h, or 1d.", .{shown.bytes}),
                error.MissingPrompt => try writeNotice(app, .warning, "Usage: /loop <interval> <prompt>", .{}),
                error.PromptTooLong => try writeNotice(app, .warning, "A loop prompt holds at most {d} bytes.", .{loops.max_prompt_bytes}),
                error.InvalidId => try writeNotice(app, .warning, "Usage: /loop stop <id|all> or /loop resume <id>", .{}),
            }
        }

        fn writeNotice(app: *App, tone: anytype, comptime fmt: []const u8, args: anytype) !void {
            const body = try app.alloc.print(fmt, args);
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{ .topic = "loop", .tone = tone, .body = body }, true);
        }

        /// The ids of `agent`'s loops as `1, 2, 3`. Caller frees.
        fn idList(app: *App, agent: anytype) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(app.alloc);
            for (agent.loops.items.items, 0..) |loop, index| {
                if (index > 0) try out.appendSlice(app.alloc, ", ");
                var buf: [16]u8 = undefined;
                try out.appendSlice(app.alloc, try std.mem.print(&buf, "{d}", .{loop.id}));
            }
            return out.toOwnedSlice(app.alloc);
        }
    };
}

fn loopWord(count: usize) []const u8 {
    return if (count == 1) "loop" else "loops";
}

/// `interval_ms` in the largest unit that divides it: `1h`, `90s`, `2d`.
fn formatInterval(buf: []u8, interval_ms: u64) []const u8 {
    const units = [_]struct { ms: u64, suffix: u8 }{
        .{ .ms = 24 * 60 * 60_000, .suffix = 'd' },
        .{ .ms = 60 * 60_000, .suffix = 'h' },
        .{ .ms = 60_000, .suffix = 'm' },
    };
    for (units) |unit| {
        if (interval_ms % unit.ms == 0) return std.mem.print(buf, "{d}{c}", .{ interval_ms / unit.ms, unit.suffix }) catch "?";
    }
    return std.mem.print(buf, "{d}s", .{interval_ms / 1_000}) catch "?";
}

/// Time left until a run, rounded down: `30s`, `42m`, `2h 5m`, `3d 4h`.
fn formatRemaining(buf: []u8, remaining_ms: i64) []const u8 {
    const secs: u64 = @intCast(@max(remaining_ms, 0) / 1_000);
    if (secs < 60) return std.mem.print(buf, "{d}s", .{secs}) catch "?";
    if (secs < 60 * 60) return std.mem.print(buf, "{d}m", .{secs / 60}) catch "?";
    if (secs < 24 * 60 * 60) return std.mem.print(buf, "{d}h {d}m", .{ secs / 3600, secs % 3600 / 60 }) catch "?";
    return std.mem.print(buf, "{d}d {d}h", .{ secs / 86_400, secs % 86_400 / 3600 }) catch "?";
}

test "formatInterval picks the largest exact unit" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1h", formatInterval(&buf, 60 * 60_000));
    try std.testing.expectEqualStrings("90m", formatInterval(&buf, 90 * 60_000));
    try std.testing.expectEqualStrings("2d", formatInterval(&buf, 2 * 24 * 60 * 60_000));
    try std.testing.expectEqualStrings("90s", formatInterval(&buf, 90_000));
}

test "formatRemaining rounds down to the largest units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0s", formatRemaining(&buf, -5));
    try std.testing.expectEqualStrings("59m", formatRemaining(&buf, 60 * 60_000 - 1));
    try std.testing.expectEqualStrings("2h 5m", formatRemaining(&buf, (2 * 60 + 5) * 60_000));
    try std.testing.expectEqualStrings("3d 4h", formatRemaining(&buf, (3 * 24 + 4) * 60 * 60_000));
}
