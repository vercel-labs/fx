const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const host_target = @import("../hosts/target.zig");
const input_action = @import("../input/input_action.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const cli_config = @import("../cli/cli_config.zig");
const env_settings = @import("../config/env_settings.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const workspace_trust = @import("../workspace_trust/workspace_trust.zig");
const input_submit_runtime = @import("input_submit_runtime.zig");

const Gate = workspace_trust.gate.Gate;
const Input = workspace_trust.prompt.Input;
const SkillRoot = workspace_trust.gate.SkillRoot;
const SkillSource = skill_contract.SkillSource;

const trace_scope = "workspace_trust";
const not_saved_format = "Could not save your answer to {s}/settings.json: {s}. fx will ask again next time.";
const dropped_reason = "folder_access_screen_open";
const carriage_return: u8 = 13;
const line_feed: u8 = 10;
const ctrl_c: u8 = 3;
const ctrl_d: u8 = 4;
const module = @This();

fn screenDisabled() bool {
    return env_settings.testSwitchOn(io_mod.getenv("FX_TEST_SKIP_WORKSPACE_TRUST"));
}

fn inputFor(event: input_action.TerminalInputEvent) ?Input {
    return switch (event) {
        .raw => |raw| switch (raw.byte) {
            carriage_return, line_feed => .confirm,
            '1' => .choose_allow,
            '2' => .choose_exit,
            ctrl_c, ctrl_d => .cancel,
            else => null,
        },
        .action => |decoded| switch (decoded.action) {
            .cursor_up => .previous,
            .cursor_down => .next,
            .escape => .cancel,
            else => null,
        },
        .paste_byte => null,
    };
}

fn isEntryOfKind(kind: ?std.Io.File.Kind, expected: std.Io.File.Kind) bool {
    const found = kind orelse return false;
    return found == expected or found == .sym_link;
}

fn traceDroppedEvent(event: input_action.TerminalInputEvent) void {
    switch (event) {
        .raw => debug_trace.logf(trace_scope, "event dropped kind=raw reason={s}", .{dropped_reason}),
        .paste_byte => debug_trace.logf(trace_scope, "event dropped kind=paste_byte reason={s}", .{dropped_reason}),
        .action => |decoded| debug_trace.logf(trace_scope, "event dropped kind=action name={s} reason={s}", .{ @tagName(decoded.action), dropped_reason }),
    }
}

fn traceDroppedReplayByte() void {
    debug_trace.logf(trace_scope, "replay byte dropped reason={s}", .{dropped_reason});
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const McpCounts = struct {
            servers: usize = 0,
            pending: usize = 0,
        };

        pub fn begin(app: *App) !void {
            try beginWithHome(app, io_mod.homeDir());
        }

        fn beginWithHome(app: *App, home: ?[]const u8) !void {
            app.trust.deinit(app.alloc);
            // libfx's wasm terminal never shows the screen; the embedding host owns its files.
            app.trust = try Gate.open(
                app.alloc,
                app.workspace_root,
                home,
                module.screenDisabled() or host_target.is_wasm,
            );
            if (!app.trust.asking()) return;
            if (comptime @hasField(App, "mcp")) {
                if (comptime @hasDecl(@TypeOf(app.mcp), "holdForTrust")) {
                    app.mcp.holdForTrust();
                }
            }
            try refreshFacts(app);
            requestFooterRender(app);
        }

        pub fn refreshFacts(app: *App) !void {
            if (!app.trust.asking()) return;
            const root = if (comptime @hasField(App, "workspace_root")) app.workspace_root else "";
            const agents_md = isEntryOfKind(statKindNoFollow(app.alloc, root, "AGENTS.md"), .file);
            const agent_profiles = isEntryOfKind(statKindNoFollow(app.alloc, root, ".fx/agents"), .directory);

            var skill_counts = std.EnumArray(SkillSource, usize).initFill(0);
            if (comptime @hasField(App, "skills")) {
                for (app.skills.items) |skill| {
                    skill_counts.set(skill.source, skill_counts.get(skill.source) + 1);
                }
            }
            var skill_roots_buf: [std.enums.values(SkillSource).len]SkillRoot = undefined;
            var skill_roots_len: usize = 0;
            for (std.enums.values(SkillSource)) |source| {
                const path = builtin_skills.workspaceRootPath(source) orelse continue;
                const count = skill_counts.get(source);
                if (count == 0) continue;
                skill_roots_buf[skill_roots_len] = .{ .path = path, .count = count };
                skill_roots_len += 1;
            }

            const mcp = workspaceMcpCounts(app);

            try app.trust.setFacts(app.alloc, .{
                .agents_md = agents_md,
                .agent_profiles = agent_profiles,
                .skill_roots = skill_roots_buf[0..skill_roots_len],
                .mcp_servers = mcp.servers,
                .mcp_pending = mcp.pending,
            });
            requestFooterRender(app);
        }

        fn workspaceMcpCounts(app: *App) McpCounts {
            var counts: McpCounts = .{};
            if (comptime !@hasField(App, "mcp")) return counts;
            if (comptime !@hasDecl(@TypeOf(app.mcp), "leaseHost")) return counts;
            const lease = app.mcp.leaseHost() orelse return counts;
            defer lease.deinit();
            for (lease.host.runtime.servers()) |server| {
                if (server.source != .workspace) continue;
                counts.servers += 1;
                if (server.held == .waiting_for_approval) counts.pending += 1;
            }
            return counts;
        }

        pub fn routeIngress(app: *App, ingress: input_action.TerminalInputIngress) !bool {
            if (!app.trust.asking()) return false;
            if (ingress.replay_byte_after_routing != null) traceDroppedReplayByte();
            const event = ingress.event orelse return true;
            const input = module.inputFor(event) orelse {
                traceDroppedEvent(event);
                return true;
            };
            switch (app.trust.press(input)) {
                .stay => requestFooterRender(app),
                .allow => try finishAllowed(app),
                .exit => finishDeclined(app),
            }
            return true;
        }

        fn finishAllowed(app: *App) !void {
            try finishAllowedWithHome(app, io_mod.homeDir());
        }

        fn finishAllowedWithHome(app: *App, home: ?[]const u8) !void {
            const allowed = app.trust.allow(app.alloc, home);
            switch (allowed) {
                .saved, .session_only => {},
                .not_saved => |err| {
                    if (comptime @hasDecl(App, "writeDomainNotice")) {
                        try writeNotSavedNotice(app, err);
                    }
                },
            }
            releaseMcpTrustHold(app);
            requestFullRender(app);
        }

        fn writeNotSavedNotice(app: *App, err: anyerror) !void {
            const body = try app.alloc.print(not_saved_format, .{ profile_paths.displayRoot(), cli_config.saveFailureReason(err) });
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = trace_scope,
                .tone = .@"error",
                .body = body,
            }, true);
        }

        fn releaseMcpTrustHold(app: *App) void {
            if (comptime @hasField(App, "mcp")) {
                if (comptime @hasDecl(@TypeOf(app.mcp), "releaseTrustHold")) {
                    app.mcp.releaseTrustHold();
                }
            }
        }

        fn finishDeclined(app: *App) void {
            input_submit_runtime.SubmitRuntime(App).discardLaunchPrompt(app, "folder_access_declined");
            if (comptime @hasField(App, "should_exit")) {
                app.should_exit = true;
            }
        }

        fn requestFooterRender(app: *App) void {
            if (comptime @hasField(App, "shell")) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn requestFullRender(app: *App) void {
            if (comptime @hasField(App, "shell")) {
                app.shell.render_requests.request(.transcript);
                app.shell.render_requests.request(.footer);
            }
        }
    };
}

fn statKindNoFollow(alloc: std.mem.Allocator, workspace_root: []const u8, sub_path: []const u8) ?std.Io.File.Kind {
    if (workspace_root.len == 0) return null;
    const path = std.Io.Dir.path.join(alloc, &.{ workspace_root, sub_path }) catch return null;
    defer alloc.free(path);
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch return null;
    return stat.kind;
}

test "terminal keys map to folder access inputs" {
    try std.testing.expectEqual(@as(?Input, .confirm), inputFor(.{ .raw = .{ .byte = 13 } }));
    try std.testing.expectEqual(@as(?Input, .confirm), inputFor(.{ .raw = .{ .byte = 10 } }));
    try std.testing.expectEqual(@as(?Input, .choose_allow), inputFor(.{ .raw = .{ .byte = '1' } }));
    try std.testing.expectEqual(@as(?Input, .choose_exit), inputFor(.{ .raw = .{ .byte = '2' } }));
    try std.testing.expectEqual(@as(?Input, .cancel), inputFor(.{ .raw = .{ .byte = 3 } }));
    try std.testing.expectEqual(@as(?Input, .cancel), inputFor(.{ .raw = .{ .byte = 4 } }));
    try std.testing.expectEqual(@as(?Input, .previous), inputFor(.{ .action = .{ .action = .cursor_up } }));
    try std.testing.expectEqual(@as(?Input, .next), inputFor(.{ .action = .{ .action = .cursor_down } }));
    try std.testing.expectEqual(@as(?Input, .cancel), inputFor(.{ .action = .{ .action = .escape } }));

    try std.testing.expectEqual(@as(?Input, null), inputFor(.{ .raw = .{ .byte = 'a' } }));
    try std.testing.expectEqual(@as(?Input, null), inputFor(.{ .raw = .{ .byte = '\t' } }));
    try std.testing.expectEqual(@as(?Input, null), inputFor(.{ .action = .{ .action = .{ .mouse_wheel = .up } } }));
    try std.testing.expectEqual(@as(?Input, null), inputFor(.{ .action = .{ .action = .{ .mouse_pointer = .{ .kind = .press, .column = 1, .row = 1 } } } }));
    try std.testing.expectEqual(@as(?Input, null), inputFor(.{ .paste_byte = '1' }));
}

test "routeIngress consumes all input while asking, finishes allow and decline cleanly" {
    const render_request = @import("../../ui/render_request.zig");
    const types = @import("../shared/types.zig");
    const FakeApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "/",
        trust: Gate = .{},
        should_exit: bool = false,
        mcp: struct {
            held_for_trust: bool = false,
            pub fn holdForTrust(self: *@This()) void {
                self.held_for_trust = true;
            }
            pub fn releaseTrustHold(self: *@This()) void {
                self.held_for_trust = false;
            }
        } = .{},
        shell: struct {
            render_requests: render_request.RenderRequestState = .{},
        } = .{},
        main_agent: struct {
            submission: input_submit_runtime.State = .{},
        } = .{},
        notices: std.ArrayList(types.SemanticNotice) = .empty,

        pub fn writeDomainNotice(self: *@This(), notice: types.SemanticNotice, _: bool) !void {
            try self.notices.append(self.alloc, notice);
        }
    };

    const alloc = std.testing.allocator;
    const Rt = Runtime(FakeApp);

    var allowed_app: FakeApp = .{ .alloc = alloc };
    defer allowed_app.trust.deinit(alloc);
    defer allowed_app.notices.deinit(alloc);
    try std.testing.expect(!(try Rt.routeIngress(&allowed_app, .{ .event = .{ .raw = .{ .byte = 'a' } } })));

    allowed_app.trust = try Gate.open(alloc, "/", null, false);
    allowed_app.mcp.holdForTrust();
    try std.testing.expect(allowed_app.trust.asking());
    try std.testing.expect(try Rt.routeIngress(&allowed_app, .{ .event = .{ .action = .{ .action = .paste_start } } }));
    try std.testing.expect(allowed_app.trust.asking());
    try std.testing.expect(try Rt.routeIngress(&allowed_app, .{ .event = .{ .action = .{ .action = .cursor_down } } }));
    try std.testing.expect(allowed_app.shell.render_requests.hasReason(.footer));
    allowed_app.shell.render_requests.clearReason(.footer);
    try std.testing.expect(try Rt.routeIngress(&allowed_app, .{ .event = .{ .raw = .{ .byte = '1' } } }));
    try std.testing.expect(!allowed_app.trust.asking());
    try std.testing.expect(!allowed_app.mcp.held_for_trust);
    try std.testing.expect(allowed_app.shell.render_requests.hasReason(.transcript));
    try std.testing.expect(allowed_app.shell.render_requests.hasReason(.footer));
    try std.testing.expect(!allowed_app.should_exit);

    var declined_app: FakeApp = .{ .alloc = alloc };
    defer declined_app.trust.deinit(alloc);
    defer declined_app.notices.deinit(alloc);
    declined_app.trust = try Gate.open(alloc, "/", null, false);
    declined_app.mcp.holdForTrust();
    declined_app.main_agent.submission.launch_prompt = try alloc.dupe(u8, "run later");
    try std.testing.expect(try Rt.routeIngress(&declined_app, .{ .event = .{ .action = .{ .action = .escape } } }));
    try std.testing.expect(declined_app.should_exit);
    try std.testing.expect(declined_app.main_agent.submission.launch_prompt == null);
    try std.testing.expect(declined_app.mcp.held_for_trust);
}

test "finishAllowedWithHome writes an error notice when saving fails" {
    const render_request = @import("../../ui/render_request.zig");
    const types = @import("../shared/types.zig");
    const FakeApp = struct {
        alloc: std.mem.Allocator,
        trust: Gate = .{},
        mcp: struct {
            held_for_trust: bool = true,
            pub fn releaseTrustHold(self: *@This()) void {
                self.held_for_trust = false;
            }
        } = .{},
        shell: struct {
            render_requests: render_request.RenderRequestState = .{},
        } = .{},
        notices: std.ArrayList(types.SemanticNotice) = .empty,

        pub fn writeDomainNotice(self: *@This(), notice: types.SemanticNotice, _: bool) !void {
            var copied = notice;
            copied.body = try self.alloc.dupe(u8, notice.body);
            try self.notices.append(self.alloc, copied);
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    const repo = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(repo);

    var app: FakeApp = .{ .alloc = alloc };
    defer app.trust.deinit(alloc);
    defer app.notices.deinit(alloc);
    defer for (app.notices.items) |notice| alloc.free(notice.body);
    app.trust = try Gate.open(alloc, repo, null, false);
    try std.testing.expect(app.trust.asking());

    try Runtime(FakeApp).finishAllowedWithHome(&app, null);
    try std.testing.expect(!app.trust.asking());
    try std.testing.expect(!app.mcp.held_for_trust);
    try std.testing.expect(app.shell.render_requests.hasReason(.transcript));
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    try std.testing.expectEqual(@as(usize, 1), app.notices.items.len);
    try std.testing.expectEqualStrings(trace_scope, app.notices.items[0].topic);
    try std.testing.expectEqual(types.NoticeTone.@"error", app.notices.items[0].tone);
    const expected = try alloc.print(not_saved_format, .{ profile_paths.displayRoot(), cli_config.saveFailureReason(error.HomeNotSet) });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, app.notices.items[0].body);
}

test "refreshFacts shows a symlinked AGENTS.md and agent profiles folder" {
    const render_request = @import("../../ui/render_request.zig");
    const FakeApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "",
        trust: Gate = .{},
        shell: struct {
            render_requests: render_request.RenderRequestState = .{},
        } = .{},
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "ws/.fx");
    try tmp.dir.createDirPath(std.testing.io, "ws/profiles");
    var file = try tmp.dir.createFile(std.testing.io, "ws/instructions.md", .{ .truncate = true });
    file.close(std.testing.io);
    try tmp.dir.symLink(std.testing.io, "instructions.md", "ws/AGENTS.md", .{ .is_directory = false });
    try tmp.dir.symLink(std.testing.io, "../profiles", "ws/.fx/agents", .{ .is_directory = true });
    const ws = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "ws");
    defer alloc.free(ws);

    var app: FakeApp = .{ .alloc = alloc, .workspace_root = ws };
    defer app.trust.deinit(alloc);
    app.trust = try Gate.open(alloc, "/", null, false);

    try Runtime(FakeApp).refreshFacts(&app);
    const shown = app.trust.prompt.?;
    try std.testing.expectEqual(@as(usize, 2), shown.rows.len);
    try std.testing.expectEqualStrings("AGENTS.md", shown.rows[0].name);
    try std.testing.expectEqualStrings(".fx/agents", shown.rows[1].name);
}

test "a dropped key, paste, and replay byte leave a trace line with their kind and no text" {
    const render_request = @import("../../ui/render_request.zig");
    const FakeApp = struct {
        alloc: std.mem.Allocator,
        trust: Gate = .{},
        should_exit: bool = false,
        mcp: struct {
            held_for_trust: bool = false,
        } = .{},
        shell: struct {
            render_requests: render_request.RenderRequestState = .{},
        } = .{},
        main_agent: struct {
            submission: input_submit_runtime.State = .{},
        } = .{},
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(base);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ base, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);

    var app: FakeApp = .{ .alloc = alloc };
    defer app.trust.deinit(alloc);
    app.trust = try Gate.open(alloc, "/", null, false);
    const Rt = Runtime(FakeApp);
    try std.testing.expect(try Rt.routeIngress(&app, .{ .event = .{ .raw = .{ .byte = 'q' } } }));
    try std.testing.expect(try Rt.routeIngress(&app, .{ .event = .{ .action = .{ .action = .paste_start } } }));
    try std.testing.expect(try Rt.routeIngress(&app, .{ .replay_byte_after_routing = 'z' }));
    try std.testing.expect(app.trust.asking());

    const trace = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, trace_path, alloc, .limited(64 * 1024));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "event dropped kind=raw reason=folder_access_screen_open") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event dropped kind=action name=paste_start reason=folder_access_screen_open") != null);
    try std.testing.expect(std.mem.find(u8, trace, "replay byte dropped reason=folder_access_screen_open") != null);
    try std.testing.expect(std.mem.find(u8, trace, "q") == null);
    try std.testing.expect(std.mem.find(u8, trace, "z") == null);
}

test "refreshFacts stats workspace entries without following symlinks and counts workspace skills" {
    const render_request = @import("../../ui/render_request.zig");
    const skill_runtime = @import("../skills/skill_runtime.zig");
    const FakeApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8 = "",
        trust: Gate = .{},
        skills: skill_runtime.Runtime = .{},
        shell: struct {
            render_requests: render_request.RenderRequestState = .{},
        } = .{},
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "ws/.fx/agents");
    try tmp.dir.createDirPath(std.testing.io, "outside_dir");
    var file = try tmp.dir.createFile(std.testing.io, "ws/AGENTS.md", .{ .truncate = true });
    file.close(std.testing.io);
    const ws = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "ws");
    defer alloc.free(ws);

    var app: FakeApp = .{ .alloc = alloc, .workspace_root = ws };
    defer app.trust.deinit(alloc);
    app.trust = try Gate.open(alloc, "/", null, false);
    var items = [_]skill_runtime.Skill{
        .{
            .name = @constCast("a"),
            .description = @constCast(""),
            .path = @constCast("p1"),
            .source = .workspace_fx,
        },
        .{
            .name = @constCast("b"),
            .description = @constCast(""),
            .path = @constCast("p2"),
            .source = .workspace_fx,
        },
        .{
            .name = @constCast("c"),
            .description = @constCast(""),
            .path = @constCast("p3"),
            .source = .global_fx,
        },
    };
    app.skills.items = &items;

    try Runtime(FakeApp).refreshFacts(&app);
    try std.testing.expect(app.shell.render_requests.hasReason(.footer));
    const shown = app.trust.prompt.?;
    try std.testing.expectEqual(@as(usize, 3), shown.rows.len);
    try std.testing.expectEqualStrings("AGENTS.md", shown.rows[0].name);
    try std.testing.expectEqualStrings(".fx/agents", shown.rows[1].name);
    try std.testing.expectEqualStrings(".fx/skills", shown.rows[2].name);
    try std.testing.expectEqualStrings("2 skills", shown.rows[2].detail);
}
