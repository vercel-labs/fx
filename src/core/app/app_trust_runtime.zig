const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const host_target = @import("../hosts/target.zig");
const input_action = @import("../input/input_action.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const workspace_trust = @import("../workspace_trust/workspace_trust.zig");
const input_submit_runtime = @import("input_submit_runtime.zig");

const Gate = workspace_trust.gate.Gate;
const Input = workspace_trust.prompt.Input;
const SkillRoot = workspace_trust.gate.SkillRoot;
const SkillSource = skill_contract.SkillSource;

const trace_scope = "workspace_trust";
const not_saved_notice = "Could not save your answer, so fx will ask again next time.";
const module = @This();

pub fn screenDisabled() bool {
    const value = io_mod.getenv("FX_TEST_SKIP_WORKSPACE_TRUST") orelse return false;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return false;
    return !std.mem.eql(u8, trimmed, "0") and !std.ascii.eqlIgnoreCase(trimmed, "false");
}

pub fn inputFor(event: input_action.TerminalInputEvent) ?Input {
    return switch (event) {
        .raw => |raw| switch (raw.byte) {
            13, 10 => .confirm,
            '1' => .choose_allow,
            '2' => .choose_exit,
            3, 4 => .cancel,
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

pub fn Runtime(comptime App: type) type {
    return struct {
        pub const screenDisabled = module.screenDisabled;
        pub const inputFor = module.inputFor;

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
            const agents_md = statKindNoFollow(app.alloc, root, "AGENTS.md") == .file;
            const agent_profiles = statKindNoFollow(app.alloc, root, ".fx/agents") == .directory;

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

            var mcp_servers: usize = 0;
            var mcp_pending: usize = 0;
            if (comptime @hasField(App, "mcp")) {
                if (comptime @hasDecl(@TypeOf(app.mcp), "leaseHost")) {
                    if (app.mcp.leaseHost()) |lease| {
                        defer lease.deinit();
                        for (lease.host.runtime.servers()) |server| {
                            if (server.source != .workspace) continue;
                            mcp_servers += 1;
                            if (server.held == .waiting_for_approval) mcp_pending += 1;
                        }
                    }
                }
            }

            try app.trust.setFacts(app.alloc, .{
                .agents_md = agents_md,
                .agent_profiles = agent_profiles,
                .skill_roots = skill_roots_buf[0..skill_roots_len],
                .mcp_servers = mcp_servers,
                .mcp_pending = mcp_pending,
            });
            requestFooterRender(app);
        }

        pub fn routeIngress(app: *App, ingress: input_action.TerminalInputIngress) !bool {
            if (!app.trust.asking()) return false;
            const event = ingress.event orelse return true;
            const input = module.inputFor(event) orelse {
                switch (event) {
                    .action => |decoded| if (decoded.action == .paste_start) {
                        debug_trace.logf(trace_scope, "paste dropped reason=folder_access_screen_open", .{});
                    },
                    .raw, .paste_byte => {},
                }
                return true;
            };
            switch (app.trust.press(input)) {
                .stay => requestFooterRender(app),
                .allow => try finishAllowed(app),
                .exit => finishDeclined(app),
            }
            return true;
        }

        pub fn finishAllowed(app: *App) !void {
            try finishAllowedWithHome(app, io_mod.homeDir());
        }

        fn finishAllowedWithHome(app: *App, home: ?[]const u8) !void {
            const allowed = app.trust.allow(app.alloc, home);
            switch (allowed) {
                .saved, .session_only => {},
                .not_saved => {
                    if (comptime @hasDecl(App, "writeDomainNotice")) {
                        try app.writeDomainNotice(.{
                            .topic = trace_scope,
                            .tone = .@"error",
                            .body = not_saved_notice,
                        }, true);
                    }
                },
            }
            if (comptime @hasField(App, "mcp")) {
                if (comptime @hasDecl(@TypeOf(app.mcp), "releaseTrustHold")) {
                    app.mcp.releaseTrustHold();
                }
            }
            requestFullRender(app);
        }

        pub fn finishDeclined(app: *App) void {
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
            try self.notices.append(self.alloc, notice);
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
    try std.testing.expectEqualStrings(not_saved_notice, app.notices.items[0].body);
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
