const std = @import("std");
const app_code_viewer_runtime = @import("app_code_viewer_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const code_viewer_layout = @import("../../ui/code_viewer_layout.zig");
const input_action = @import("../input/input_action.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");

const ctrl_c: u8 = 3;
const ctrl_l: u8 = 12;
const ctrl_n: u8 = 14;
const ctrl_p: u8 = 16;
const ctrl_u: u8 = 21;
const ctrl_d: u8 = 4;
const ctrl_x: u8 = 24;
const backspace: u8 = 127;
const backspace_alt: u8 = 8;

const ViewerKey = union(enum) {
    quit,
    interrupt,
    redraw,
    subagent_manager,
    move: isize,
    page: isize,
    top,
    bottom,
    search,
    goto_line,
    definition,
    next_match,
    previous_match,
    next_hunk,
    previous_hunk,
    toggle_layout,
    confirm,
    cancel,
    prompt_byte: u8,
    prompt_delete,
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn routeByte(app: *App, byte: u8) !bool {
            if (comptime @hasField(App, "code_viewer") and @hasField(App, "terminal")) {
                if (!app.terminal.codeViewerScreenActive() or !app.code_viewer.active()) return false;
                const key = keyForByte(app.code_viewer.mode, byte) orelse return true;
                try dispatchOwned(app, key);
                return true;
            }
            return false;
        }

        pub fn routeAction(app: *App, resolved: input_action.Action) !bool {
            if (comptime @hasField(App, "code_viewer") and @hasField(App, "terminal")) {
                if (!app.terminal.codeViewerScreenActive() or !app.code_viewer.active()) return false;
                const key = keyForAction(app.code_viewer.mode, resolved) orelse return true;
                try dispatchOwned(app, key);
                return true;
            }
            return false;
        }

        fn dispatchOwned(app: *App, key: ViewerKey) !void {
            if (comptime @hasField(App, "code_viewer")) {
                const Owned = struct {
                    fn dispatch(owned_app: *App, owned_key: ViewerKey) !void {
                        const body_rows = code_viewer_layout.regions(owned_app.shell.layout.rows).body_rows;
                        switch (owned_key) {
                            .quit, .interrupt => {
                                try app_code_viewer_runtime.Runtime(App).close(owned_app);
                                return;
                            },
                            .cancel => owned_app.code_viewer.cancelPrompt(),
                            .confirm => owned_app.code_viewer.confirmPrompt(),
                            .prompt_byte => |byte| try owned_app.code_viewer.appendPromptByte(byte),
                            .prompt_delete => try owned_app.code_viewer.deletePromptByte(),
                            .move => |delta| owned_app.code_viewer.moveBy(delta),
                            .page => |delta| owned_app.code_viewer.pageBy(delta, body_rows),
                            .top => owned_app.code_viewer.gotoTop(),
                            .bottom => owned_app.code_viewer.gotoBottom(),
                            .search => try owned_app.code_viewer.beginSearch(),
                            .goto_line => owned_app.code_viewer.beginGoto(),
                            .definition => {
                                try app_code_viewer_runtime.Runtime(App).gotoDefinition(owned_app);
                            },
                            .next_match => owned_app.code_viewer.nextMatch(),
                            .previous_match => owned_app.code_viewer.previousMatch(),
                            .next_hunk => owned_app.code_viewer.nextHunk(),
                            .previous_hunk => owned_app.code_viewer.previousHunk(),
                            .toggle_layout => owned_app.code_viewer.toggleDiffLayout(),
                            .redraw => {},
                            .subagent_manager => {
                                try app_code_viewer_runtime.Runtime(App).close(owned_app);
                                if (comptime runtime_profile.allows(App, .subagents)) {
                                    try app_render_runtime.Runtime(App).toggleSubagentView(owned_app);
                                }
                                return;
                            },
                        }
                        owned_app.code_viewer.syncScroll(body_rows);
                        app_render_runtime.Runtime(App).requestActiveSurfaceFrame(owned_app, .modal);
                    }
                };
                try Owned.dispatch(app, key);
            }
        }
    };
}

fn keyForByte(mode: app_code_viewer_runtime.Mode, byte: u8) ?ViewerKey {
    if (mode != .browse) {
        return switch (byte) {
            ctrl_c => .interrupt,
            0x1b => .cancel,
            '\r', '\n' => .confirm,
            backspace, backspace_alt => .prompt_delete,
            ctrl_u => .cancel,
            else => if (byte >= 32 and byte < 127) .{ .prompt_byte = byte } else .redraw,
        };
    }
    return switch (byte) {
        ctrl_c => .interrupt,
        'q', 'Q' => .quit,
        ctrl_l => .redraw,
        ctrl_x => .subagent_manager,
        'j' => .{ .move = 1 },
        'k' => .{ .move = -1 },
        ctrl_d => .{ .page = 1 },
        ctrl_u => .{ .page = -1 },
        'g' => .top,
        'G' => .bottom,
        '/' => .search,
        ':' => .goto_line,
        'd' => .definition,
        'n' => .next_match,
        'N' => .previous_match,
        ']', ctrl_n => .next_hunk,
        '[', ctrl_p => .previous_hunk,
        't', 'T' => .toggle_layout,
        else => null,
    };
}

fn keyForAction(mode: app_code_viewer_runtime.Mode, resolved: input_action.Action) ?ViewerKey {
    if (mode != .browse) {
        return switch (resolved) {
            .escape => .cancel,
            .insert_newline => .confirm,
            .delete_next => .prompt_delete,
            .composer_shortcut => |shortcut| switch (shortcut) {
                .delete_backward => .prompt_delete,
                .redraw => .redraw,
                else => null,
            },
            .remapped_byte => |byte| keyForByte(mode, byte),
            else => null,
        };
    }
    return switch (resolved) {
        .escape => .quit,
        .cursor_down => .{ .move = 1 },
        .cursor_up => .{ .move = -1 },
        .page_down => .{ .page = 1 },
        .page_up => .{ .page = -1 },
        .home => .top,
        .end => .bottom,
        .mouse_wheel => |direction| switch (direction) {
            .up => .{ .move = -3 },
            .down => .{ .move = 3 },
        },
        .composer_shortcut => |shortcut| switch (shortcut) {
            .redraw => .redraw,
            .move => |intent| switch (intent.kind) {
                .visual_up, .paragraph_up => .{ .move = -1 },
                .visual_down, .paragraph_down => .{ .move = 1 },
                .draft_start, .line_start => .top,
                .draft_end, .line_end => .bottom,
                .page_up => .{ .page = -1 },
                .page_down => .{ .page = 1 },
                else => null,
            },
            else => null,
        },
        .remapped_byte => |byte| keyForByte(mode, byte),
        else => null,
    };
}
