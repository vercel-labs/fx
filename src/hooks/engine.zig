//! Runs the hooks that match one event and merges their answers into one outcome.

const std = @import("std");
const event = @import("event.zig");
const answer = @import("answer.zig");
const config = @import("config.zig");
const host = @import("host.zig");
const merge = @import("merge.zig");
const protocol = @import("protocol.zig");
const limits = @import("limits.zig");

/// One of fx's own in-process handlers, such as sound. Builtins run before user hooks.
pub const Builtin = struct {
    /// Shown in traces and notices, such as "fx.sound".
    name: []const u8,
    /// The events it runs for.
    events: std.EnumSet(event.EventName),
    ctx: *anyopaque,
    /// Must not block. Slices in the answer must stay valid until the engine's `run` returns.
    run: *const fn (ctx: *anyopaque, ev: *const event.Event) answer.Answer,
};

pub const Engine = struct {
    host: host.Host,
    builtins: []const Builtin = &.{},

    /// Whether any builtin or any of `hooks` would run for this event, so a caller can skip
    /// building event data when nothing listens.
    pub fn wants(self: *const Engine, hooks: []const *const config.Hook, name: event.EventName, match_value: ?[]const u8) bool {
        for (self.builtins) |builtin| {
            if (builtin.events.contains(name)) return true;
        }
        for (hooks) |hook| {
            if (hookMatches(hook, name, match_value)) return true;
        }
        return false;
    }

    /// How many of `hooks` fit this event and match `match_value`. A caller that ran only the
    /// trusted hooks uses it to count the waiting ones it skipped.
    pub fn countMatching(hooks: []const *const config.Hook, name: event.EventName, match_value: ?[]const u8) usize {
        var count: usize = 0;
        for (hooks) |hook| {
            if (hookMatches(hook, name, match_value)) count += 1;
        }
        return count;
    }

    /// Runs every builtin for `ev.name`, then every hook in `hooks` (in order) that fits the
    /// event, and merges the results. The caller owns the outcome, allocated with `alloc`.
    /// No new hook process starts once `cancel` is true.
    pub fn run(
        self: *const Engine,
        alloc: std.mem.Allocator,
        hooks: []const *const config.Hook,
        ev: event.Event,
        cancel: ?*const std.atomic.Value(bool),
    ) std.mem.Allocator.Error!answer.Outcome {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var results: std.ArrayList(answer.HandlerResult) = .empty;

        for (self.builtins) |builtin| {
            if (!builtin.events.contains(ev.name)) continue;
            const started = self.host.now_ms(self.host.ctx);
            const given = builtin.run(builtin.ctx, &ev);
            const finished = self.host.now_ms(self.host.ctx);
            try results.append(arena, .{
                .hook_id = builtin.name,
                .result = .{ .answer = given },
                .duration_ms = finished -| started,
            });
        }

        var stdin: ?[]u8 = null;
        var env: ?[]const host.EnvVar = null;

        for (hooks) |hook| {
            if (!hookMatches(hook, ev.name, ev.match_value)) continue;
            if (cancel) |flag| {
                if (flag.load(.acquire)) break;
            }
            if (stdin == null) {
                stdin = try protocol.buildInput(arena, ev);
                env = try buildEnv(arena, ev);
            }
            const argv = switch (hook.command) {
                .shell => |text| try shellArgv(arena, text),
                .argv => |items| try argvList(arena, items),
            };

            const started = self.host.now_ms(self.host.ctx);
            const ended = try self.host.run_process(self.host.ctx, arena, .{
                .argv = argv,
                .stdin = stdin.?,
                .cwd = ev.scope.cwd,
                .env = env.?,
                .timeout_ms = hook.timeout_ms,
                .stdout_limit = limits.stdout_bytes,
                .stderr_limit = limits.stderr_bytes,
                .cancel = cancel,
            });
            const finished = self.host.now_ms(self.host.ctx);

            const result: answer.Result = switch (ended) {
                .exited => |exited| if (exited.stdout_overflow)
                    failure(.output_too_large, null, "")
                else
                    try protocol.readOutput(arena, ev.name, hook.on_failure, .{
                        .code = exited.code,
                        .stdout = exited.stdout,
                        .stderr = exited.stderr,
                    }),
                .signaled => |signaled| .{ .failure = .{
                    .kind = .signaled,
                    .signal = signaled.signal,
                    .detail = protocol.firstLine(signaled.stderr),
                } },
                .spawn_failed => |text| failure(.spawn_failed, null, text),
                .timed_out => failure(.timed_out, null, ""),
                .cancelled => failure(.cancelled, null, ""),
            };

            const elapsed = finished -| started;
            try results.append(arena, .{
                .hook_id = hook.id,
                .on_failure = hook.on_failure,
                .result = result,
                .duration_ms = elapsed,
            });

            self.host.trace(self.host.ctx, switch (result) {
                .answer => try arena.print("hook {s} {s} answered in {d} ms", .{
                    hook.id,
                    ev.name.fileName(),
                    elapsed,
                }),
                .failure => |failed| try arena.print("hook {s} {s} failed ({s}) in {d} ms", .{
                    hook.id,
                    ev.name.fileName(),
                    @tagName(failed.kind),
                    elapsed,
                }),
            });
        }

        return merge.merge(alloc, ev.name, results.items);
    }
};

/// Whether `hook` runs for an event with this name and match value.
fn hookMatches(hook: *const config.Hook, name: event.EventName, match_value: ?[]const u8) bool {
    if (hook.event != name) return false;
    const value = match_value orelse "";
    return switch (name.capabilities().match) {
        .none => true,
        .tool_name => hook.matcher.matchesTool(value),
        else => hook.matcher.matches(value),
    };
}

fn failure(kind: answer.FailureKind, exit_code: ?u8, detail: []const u8) answer.Result {
    return .{ .failure = .{ .kind = kind, .exit_code = exit_code, .detail = detail } };
}

/// The environment fx adds for every hook process of this event.
fn buildEnv(arena: std.mem.Allocator, ev: event.Event) std.mem.Allocator.Error![]const host.EnvVar {
    var list: std.ArrayList(host.EnvVar) = .empty;
    try list.append(arena, .{ .name = "FX_PROJECT_DIR", .value = ev.scope.project_dir });
    if (ev.scope.session_id) |id| {
        try list.append(arena, .{ .name = "FX_SESSION_ID", .value = id });
    }
    try list.append(arena, .{ .name = "FX_HOOK_EVENT", .value = ev.name.fileName() });
    try list.append(arena, .{ .name = "CLAUDE_PROJECT_DIR", .value = ev.scope.project_dir });
    return try list.toOwnedSlice(arena);
}

/// The program that runs a hook's shell command. A command is shell text, so it runs through the
/// POSIX shell at this path, which macOS and Linux both have.
const shell_program = "/bin/sh";

fn shellArgv(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const []const u8 {
    const argv = try arena.alloc([]const u8, 3);
    argv[0] = shell_program;
    argv[1] = "-c";
    argv[2] = text;
    return argv;
}

fn argvList(arena: std.mem.Allocator, items: [][]u8) std.mem.Allocator.Error![]const []const u8 {
    const argv = try arena.alloc([]const u8, items.len);
    for (items, 0..) |item, index| argv[index] = item;
    return argv;
}

test "nothing listens" {
    const alloc = std.testing.allocator;
    var fake = Fake{ .scripts = &.{} };
    defer fake.deinit();
    const runner = Engine{ .host = fake.asHost() };
    const hooks: []const *const config.Hook = &.{};

    try std.testing.expect(!runner.wants(hooks, .pre_tool_use, null));

    var outcome = try runner.run(alloc, hooks, .{ .name = .pre_tool_use, .scope = testScope() }, null);
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(answer.Decision.proceed, outcome.decision);
    try std.testing.expectEqual(@as(usize, 0), outcome.ran);
    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "only matching hooks run" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":[\"a\"]}]},{\"matcher\":\"Read\",\"hooks\":[{\"type\":\"command\",\"command\":[\"b\"]}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"c\"]}]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "a", .result = .{ .exit = .{ .code = 0 } } },
        .{ .last_arg = "b", .result = .{ .exit = .{ .code = 0 } } },
        .{ .last_arg = "c", .result = .{ .exit = .{ .code = 0 } } },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();
    const runner = Engine{ .host = fake.asHost() };

    try std.testing.expect(runner.wants(hooks, .pre_tool_use, "shell"));
    try std.testing.expect(!runner.wants(hooks, .pre_tool_use, "grep_files"));

    var outcome = try runner.run(alloc, hooks, .{ .name = .pre_tool_use, .scope = testScope(), .match_value = "shell" }, null);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try std.testing.expectEqualStrings("a", fake.calls.items[0].argv[0]);
}

test "hooks run in order and their answers merge" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"one\"],\"id\":\"first\"},{\"type\":\"command\",\"command\":[\"two\"],\"id\":\"second\"}]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "one", .result = .{ .exit = .{ .code = 0, .stdout = "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}" } } },
        .{ .last_arg = "two", .result = .{ .exit = .{ .code = 2, .stderr = "no" } } },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();
    const runner = Engine{ .host = fake.asHost() };

    var outcome = try runner.run(alloc, hooks, .{ .name = .pre_tool_use, .scope = testScope(), .match_value = "shell" }, null);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.deny, outcome.decision);
    try std.testing.expectEqualStrings("second", outcome.decided_by.?);
    try std.testing.expectEqualStrings("no", outcome.reason.?);
    try std.testing.expectEqual(@as(usize, 2), outcome.ran);
    try std.testing.expectEqualStrings("one", fake.calls.items[0].argv[0]);
    try std.testing.expectEqualStrings("two", fake.calls.items[1].argv[0]);
}

test "every hook gets the same input and environment" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"one\"]},{\"type\":\"command\",\"command\":[\"two\"]}]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "one", .result = .{ .exit = .{ .code = 0 } } },
        .{ .last_arg = "two", .result = .{ .exit = .{ .code = 0 } } },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();
    const runner = Engine{ .host = fake.asHost() };

    const ev = event.Event{ .name = .pre_tool_use, .scope = testScope(), .match_value = "shell" };
    var outcome = try runner.run(alloc, hooks, ev, null);
    defer outcome.deinit(alloc);

    const expected = try protocol.buildInput(alloc, ev);
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, fake.calls.items[0].stdin);
    try std.testing.expectEqualStrings(expected, fake.calls.items[1].stdin);

    const env = fake.calls.items[0].env;
    try std.testing.expectEqual(@as(usize, 4), env.len);
    try std.testing.expectEqualStrings("FX_PROJECT_DIR", env[0].name);
    try std.testing.expectEqualStrings("/Users/example/p", env[0].value);
    try std.testing.expectEqualStrings("FX_SESSION_ID", env[1].name);
    try std.testing.expectEqualStrings("s1", env[1].value);
    try std.testing.expectEqualStrings("FX_HOOK_EVENT", env[2].name);
    try std.testing.expectEqualStrings("PreToolUse", env[2].value);
    try std.testing.expectEqualStrings("CLAUDE_PROJECT_DIR", env[3].name);
    try std.testing.expectEqualStrings("/Users/example/p", env[3].value);

    var no_session = testScope();
    no_session.session_id = null;
    var next = try runner.run(alloc, hooks, .{ .name = .pre_tool_use, .scope = no_session, .match_value = "shell" }, null);
    defer next.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), fake.calls.items[2].env.len);
    try std.testing.expectEqualStrings("FX_HOOK_EVENT", fake.calls.items[2].env[1].name);
}

test "a hook request carries the command, cwd, timeout, and limits" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo hi\",\"timeout\":2}]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "echo hi", .result = .{ .exit = .{ .code = 0 } } },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();
    const runner = Engine{ .host = fake.asHost() };

    var outcome = try runner.run(alloc, hooks, .{ .name = .pre_tool_use, .scope = testScope(), .match_value = "shell" }, null);
    defer outcome.deinit(alloc);

    const call = fake.calls.items[0];
    try std.testing.expectEqual(@as(usize, 3), call.argv.len);
    try std.testing.expectEqualStrings("/bin/sh", call.argv[0]);
    try std.testing.expectEqualStrings("-c", call.argv[1]);
    try std.testing.expectEqualStrings("echo hi", call.argv[2]);
    try std.testing.expectEqualStrings("/Users/example/p", call.cwd);
    try std.testing.expectEqual(@as(u32, 2000), call.timeout_ms);
    try std.testing.expectEqual(limits.stdout_bytes, call.stdout_limit);
    try std.testing.expectEqual(limits.stderr_bytes, call.stderr_limit);
}

test "process endings become failures" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[" ++
        "{\"type\":\"command\",\"command\":[\"slow\"],\"id\":\"slow\"}," ++
        "{\"type\":\"command\",\"command\":[\"sig\"],\"id\":\"sig\"}," ++
        "{\"type\":\"command\",\"command\":[\"big\"],\"id\":\"big\"}," ++
        "{\"type\":\"command\",\"command\":[\"blocker\"],\"id\":\"blocker\",\"on_failure\":\"block\"}" ++
        "]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "slow", .result = .timed_out },
        .{ .last_arg = "sig", .result = .{ .signal = .{ .number = 9 } } },
        .{ .last_arg = "big", .result = .{ .exit = .{ .code = 0, .overflow = true } } },
        .{ .last_arg = "blocker", .result = .timed_out },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();
    const runner = Engine{ .host = fake.asHost() };

    var outcome = try runner.run(alloc, hooks, .{ .name = .pre_tool_use, .scope = testScope(), .match_value = "shell" }, null);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(answer.Decision.deny, outcome.decision);
    try std.testing.expectEqualStrings("blocker", outcome.decided_by.?);
    try std.testing.expectEqual(@as(usize, 4), outcome.notices.len);
    try std.testing.expectEqualStrings("slow failed: timed out", outcome.notices[0].text);
    try std.testing.expectEqualStrings("sig failed: was stopped by signal 9", outcome.notices[1].text);
    try std.testing.expectEqualStrings("big failed: wrote more output than fx reads", outcome.notices[2].text);
    try std.testing.expectEqualStrings("blocker failed: timed out", outcome.notices[3].text);
}

test "a signaled hook names the first line of its stderr" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[" ++
        "{\"type\":\"command\",\"command\":[\"term\"],\"id\":\"term\"}" ++
        "]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "term", .result = .{ .signal = .{ .number = 15, .stderr = "terminated\nlater line" } } },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();
    const runner = Engine{ .host = fake.asHost() };

    var outcome = try runner.run(alloc, hooks, .{ .name = .pre_tool_use, .scope = testScope(), .match_value = "shell" }, null);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), outcome.notices.len);
    try std.testing.expectEqualStrings("term failed: was stopped by signal 15: terminated", outcome.notices[0].text);
}

test "builtins run before user hooks" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"Notification\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"user\"],\"id\":\"user-hook\"}]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "user", .result = .{ .exit = .{ .code = 0, .stdout = "{\"systemMessage\":\"user\"}" } } },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();

    var counter = Counter{};
    const builtins = [_]Builtin{
        .{
            .name = "fx.test",
            .events = std.EnumSet(event.EventName).initOne(.notification),
            .ctx = &counter,
            .run = dingRun,
        },
        .{
            .name = "fx.idle",
            .events = std.EnumSet(event.EventName).initOne(.stop),
            .ctx = &counter,
            .run = countRun,
        },
    };
    const runner = Engine{ .host = fake.asHost(), .builtins = &builtins };

    var outcome = try runner.run(alloc, hooks, .{ .name = .notification, .scope = testScope() }, null);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), outcome.notices.len);
    try std.testing.expectEqual(answer.NoticeKind.message, outcome.notices[0].kind);
    try std.testing.expectEqualStrings("fx.test", outcome.notices[0].hook_id);
    try std.testing.expectEqualStrings("ding", outcome.notices[0].text);
    try std.testing.expectEqualStrings("user-hook", outcome.notices[1].hook_id);
    try std.testing.expectEqualStrings("user", outcome.notices[1].text);
    try std.testing.expectEqual(@as(usize, 0), counter.runs);
}

test "a cancelled run starts no hook" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"a\"]}]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "a", .result = .{ .exit = .{ .code = 0 } } },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();

    var counter = Counter{};
    const builtins = [_]Builtin{
        .{
            .name = "fx.count",
            .events = std.EnumSet(event.EventName).initOne(.pre_tool_use),
            .ctx = &counter,
            .run = countRun,
        },
    };
    const runner = Engine{ .host = fake.asHost(), .builtins = &builtins };

    var flag = std.atomic.Value(bool).init(true);
    var outcome = try runner.run(alloc, hooks, .{ .name = .pre_tool_use, .scope = testScope(), .match_value = "shell" }, &flag);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), counter.runs);
}

test "a matcher on another event kind tests the value" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"SessionStart\":[{\"matcher\":\"resume\",\"hooks\":[{\"type\":\"command\",\"command\":[\"resume-script\"],\"id\":\"resume-hook\"}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"stop-script\"],\"id\":\"stop-hook\"}]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "resume-script", .result = .{ .exit = .{ .code = 0 } } },
        .{ .last_arg = "stop-script", .result = .{ .exit = .{ .code = 0 } } },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();
    const runner = Engine{ .host = fake.asHost() };

    try std.testing.expect(hookMatches(hooks[0], .session_start, "resume"));
    try std.testing.expect(!hookMatches(hooks[0], .session_start, "startup"));
    try std.testing.expect(hookMatches(hooks[1], .stop, "anything"));

    var resumed = try runner.run(alloc, hooks, .{ .name = .session_start, .scope = testScope(), .match_value = "resume" }, null);
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try std.testing.expectEqualStrings("resume-script", fake.calls.items[0].argv[0]);

    var started = try runner.run(alloc, hooks, .{ .name = .session_start, .scope = testScope(), .match_value = "startup" }, null);
    defer started.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "each hook leaves one trace line" {
    const alloc = std.testing.allocator;
    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"one\"],\"id\":\"first\"},{\"type\":\"command\",\"command\":[\"two\"],\"id\":\"second\"}]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "one", .result = .{ .exit = .{ .code = 0, .stdout = "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}" } } },
        .{ .last_arg = "two", .result = .{ .exit = .{ .code = 2, .stderr = "no" } } },
    };

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    var fake = Fake{ .scripts = &scripts };
    defer fake.deinit();
    const runner = Engine{ .host = fake.asHost() };

    var outcome = try runner.run(alloc, hooks, .{ .name = .pre_tool_use, .scope = testScope(), .match_value = "shell" }, null);
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), fake.traces.items.len);
    try std.testing.expectEqualStrings("hook first PreToolUse answered in 5 ms", fake.traces.items[0]);
    try std.testing.expectEqualStrings("hook second PreToolUse answered in 5 ms", fake.traces.items[1]);
}

test "an allocation failure leaves nothing behind" {
    var no_resize = NoResize{ .child = std.testing.allocator };
    const text = "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":[\"one\"],\"id\":\"first\"},{\"type\":\"command\",\"command\":[\"two\"],\"id\":\"second\"}]}]}}";
    const scripts = [_]Script{
        .{ .last_arg = "one", .result = .{ .exit = .{ .code = 0, .stdout = "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}" } } },
        .{ .last_arg = "two", .result = .{ .exit = .{ .code = 2, .stderr = "no" } } },
    };

    try std.testing.checkAllAllocationFailures(no_resize.allocator(), runUnderFailures, .{ text, &scripts });
}

/// One planned process ending the fake host hands back.
const Planned = union(enum) {
    exit: struct { code: u8, stdout: []const u8 = "", stderr: []const u8 = "", overflow: bool = false },
    signal: struct { number: u32, stderr: []const u8 = "" },
    spawn_failed: []const u8,
    timed_out,
    cancelled,
};

/// One script the fake host answers, keyed by the last argument.
const Script = struct { last_arg: []const u8, result: Planned };

/// One process request the fake host recorded. Owned memory, freed by Fake.deinit.
const Call = struct {
    argv: [][]u8,
    stdin: []u8,
    cwd: []u8,
    env: []host.EnvVar,
    timeout_ms: u32,
    stdout_limit: usize,
    stderr_limit: usize,
};

/// A host that answers from a script table, counts its calls, and moves a clock.
const Fake = struct {
    scripts: []const Script,
    calls: std.ArrayList(Call) = .empty,
    clock: u64 = 0,
    traces: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Fake) void {
        const alloc = std.testing.allocator;
        for (self.calls.items) |*call| {
            freeStrings(alloc, call.argv);
            alloc.free(call.stdin);
            alloc.free(call.cwd);
            for (call.env) |entry| {
                alloc.free(entry.name);
                alloc.free(entry.value);
            }
            if (call.env.len > 0) alloc.free(call.env);
        }
        self.calls.deinit(alloc);
        for (self.traces.items) |line| alloc.free(line);
        self.traces.deinit(alloc);
    }

    fn asHost(self: *Fake) host.Host {
        return .{
            .ctx = self,
            .run_process = runProcess,
            .now_ms = nowMs,
            .trace = trace,
        };
    }

    fn runProcess(ctx: *anyopaque, alloc: std.mem.Allocator, request: host.ProcessRequest) std.mem.Allocator.Error!host.ProcessResult {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try self.record(request);

        const command = if (request.argv.len > 0) request.argv[request.argv.len - 1] else "";
        for (self.scripts) |script| {
            if (!std.mem.eql(u8, script.last_arg, command)) continue;
            return switch (script.result) {
                .exit => |planned| .{ .exited = .{
                    .code = planned.code,
                    .stdout = try alloc.dupe(u8, planned.stdout),
                    .stderr = try alloc.dupe(u8, planned.stderr),
                    .stdout_overflow = planned.overflow,
                } },
                .signal => |planned| .{ .signaled = .{
                    .signal = planned.number,
                    .stderr = try alloc.dupe(u8, planned.stderr),
                } },
                .spawn_failed => |text| .{ .spawn_failed = try alloc.dupe(u8, text) },
                .timed_out => .timed_out,
                .cancelled => .cancelled,
            };
        }
        return .{ .spawn_failed = try alloc.dupe(u8, "no script") };
    }

    fn nowMs(ctx: *anyopaque) u64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.clock += 5;
        return self.clock;
    }

    fn trace(ctx: *anyopaque, line: []const u8) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        // Out of memory drops this trace line. Tests that check traces run with memory available.
        const copy = std.testing.allocator.dupe(u8, line) catch return;
        // Out of memory after the copy: free it, so the fake does not leak.
        self.traces.append(std.testing.allocator, copy) catch {
            std.testing.allocator.free(copy);
        };
    }

    fn record(self: *Fake, request: host.ProcessRequest) std.mem.Allocator.Error!void {
        const alloc = std.testing.allocator;

        const argv = try alloc.alloc([]u8, request.argv.len);
        var argv_filled: usize = 0;
        errdefer {
            for (argv[0..argv_filled]) |item| alloc.free(item);
            alloc.free(argv);
        }
        for (request.argv, 0..) |item, index| {
            argv[index] = try alloc.dupe(u8, item);
            argv_filled += 1;
        }

        const stdin = try alloc.dupe(u8, request.stdin);
        errdefer alloc.free(stdin);
        const cwd = try alloc.dupe(u8, request.cwd);
        errdefer alloc.free(cwd);

        const env = try alloc.alloc(host.EnvVar, request.env.len);
        var env_filled: usize = 0;
        errdefer {
            for (env[0..env_filled]) |entry| {
                alloc.free(entry.name);
                alloc.free(entry.value);
            }
            alloc.free(env);
        }
        for (request.env, 0..) |entry, index| {
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);
            const value = try alloc.dupe(u8, entry.value);
            env[index] = .{ .name = name, .value = value };
            env_filled += 1;
        }

        try self.calls.append(alloc, .{
            .argv = argv,
            .stdin = stdin,
            .cwd = cwd,
            .env = env,
            .timeout_ms = request.timeout_ms,
            .stdout_limit = request.stdout_limit,
            .stderr_limit = request.stderr_limit,
        });
    }
};

/// The event scope every test shares.
fn testScope() event.Scope {
    return .{
        .surface = .interactive,
        .session_id = "s1",
        .cwd = "/Users/example/p",
        .project_dir = "/Users/example/p",
        .permission_mode = "auto",
    };
}

fn loadHooks(alloc: std.mem.Allocator, file: *config.File) std.mem.Allocator.Error![]const *const config.Hook {
    const pointers = try alloc.alloc(*const config.Hook, file.hooks.len);
    for (file.hooks, 0..) |*hook, index| pointers[index] = hook;
    return pointers;
}

fn freeStrings(alloc: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| alloc.free(item);
    if (items.len > 0) alloc.free(items);
}

/// Counts how often a builtin ran.
const Counter = struct { runs: usize = 0 };

fn dingRun(ctx: *anyopaque, ev: *const event.Event) answer.Answer {
    _ = ctx;
    _ = ev;
    return .{ .system_message = "ding" };
}

fn countRun(ctx: *anyopaque, ev: *const event.Event) answer.Answer {
    _ = ev;
    const counter: *Counter = @ptrCast(@alignCast(ctx));
    counter.runs += 1;
    return .{};
}

/// One run of the engine under an allocator that may fail, for the failure sweep.
fn runUnderFailures(alloc: std.mem.Allocator, text: []const u8, scripts: []const Script) !void {
    var fake = Fake{ .scripts = scripts };
    defer fake.deinit();

    var file = try config.parse(alloc, text, .{ .layer = .profile });
    defer file.deinit(alloc);
    const hooks = try loadHooks(alloc, &file);
    defer alloc.free(hooks);

    const runner = Engine{ .host = fake.asHost() };
    var outcome = try runner.run(alloc, hooks, .{
        .name = .pre_tool_use,
        .scope = testScope(),
        .match_value = "shell",
    }, null);
    defer outcome.deinit(alloc);
}

/// An allocator that forwards to a child and never grows memory in place, so every
/// allocation sequence is the same on every run of the failure sweep.
const NoResize = struct {
    child: std.mem.Allocator,

    fn allocator(self: *NoResize) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *NoResize = @ptrCast(@alignCast(ctx));
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *NoResize = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};
