//! The app side of the model hub (D221): builds the hub's snapshot from the
//! app's providers, catalog, roles and web search settings, routes keys to
//! it while it is open, and carries out what it asks for through typed
//! backend operations plus the settings writes `/role` and `/login` use.

const std = @import("std");
const builtin = @import("builtin");
const hub = @import("../model_hub/hub.zig");
const catalog = hub.catalog;
const edits = hub.edits;
const model_roles = @import("../config/model_roles.zig");
const model_provider = @import("../config/model_provider.zig");
const configured_provider = @import("../config/configured_provider.zig");
const provider_registry = @import("../config/provider_registry.zig");
const config_runtime = @import("../config/config_runtime.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const provider_keys = @import("../auth/provider_keys.zig");
const secret = @import("../auth/secret.zig");
const credentials = @import("../auth/credentials.zig");
const input_action = @import("../input/input_action.zig");
const web_search_bank = @import("../tooling/web_search_bank.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const provider_runtime = @import("provider_runtime.zig");
const model_role_runtime = @import("model_role_runtime.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const model_performance = @import("../model_hub/performance.zig");
const session_backend = @import("session_backend.zig");
const session_commands = @import("../session/session_commands.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");

const Allocator = std.mem.Allocator;
const RoleId = model_roles.RoleId;

pub fn supported(comptime App: type) bool {
    return @hasField(App, "model_hub") and @hasField(App, "model_cache") and
        @hasField(App, "model_roles") and @hasField(App, "auth") and
        provider_runtime.supported(App) and !builtin.target.cpu.arch.isWasm();
}

pub fn Runtime(comptime App: type) type {
    return struct {
        fn performanceSnapshot(app: *App, id: []const u8) model_performance.Metrics {
            if (comptime @hasField(App, "model_performance")) return app.model_performance.snapshot(id);
            return .{};
        }

        /// Opens the hub. `/provider <name>` starts on that provider.
        pub fn open(app: *App, start: hub.Start, args: []const u8) !void {
            if (comptime !supported(App)) return;
            if (comptime @hasDecl(App, "revalidateModelCache")) app.revalidateModelCache();
            app.model_cache.closeMenu();
            app.input_runtime.settings_menu.close();
            app.input_runtime.effort_menu.close(app.alloc);
            var snapshot = try buildSnapshot(app);
            errdefer snapshot.deinit();
            try app.model_hub.open(app.alloc, snapshot, start);
            const wanted = std.mem.trim(u8, args, " \t");
            if (wanted.len > 0) focusProvider(app, wanted);
            debug_trace.logf("model_hub", "open start={t} providers={d} models={d}", .{ start, app.model_hub.snapshot.?.providers.len, app.model_hub.snapshot.?.models.len });
            app.shell.render_requests.request(.footer);
        }

        fn focusProvider(app: *App, wanted: []const u8) void {
            const snapshot = app.model_hub.snapshot orelse return;
            for (snapshot.providers, 0..) |provider, index| {
                if (std.ascii.eqlIgnoreCase(provider.key, wanted) or std.ascii.eqlIgnoreCase(provider.name, wanted)) {
                    app.model_hub.scope = .{ .kind = .provider, .provider = @intCast(index) };
                    app.model_hub.focus = .scope;
                    app.model_hub.rebuild(app.alloc) catch {};
                    return;
                }
            }
        }

        fn close(app: *App) void {
            if (comptime !supported(App)) return;
            if (!app.model_hub.active) return;
            app.model_hub.close(app.alloc);
            app.shell.render_requests.request(.footer);
        }

        /// Rebuilds the snapshot, as after an action or a catalog load.
        pub fn refresh(app: *App) !void {
            if (comptime !supported(App)) return;
            if (!app.model_hub.active) return;
            var snapshot = try buildSnapshot(app);
            errdefer snapshot.deinit();
            try app.model_hub.replaceSnapshot(app.alloc, snapshot);
            app.shell.render_requests.request(.footer);
        }

        /// A prompt or approval that needs the keyboard closes the hub.
        fn yieldsToPrompt(app: *App) bool {
            if (app.question_prompt.isActive() or app.approval_prompt.isActive()) {
                close(app);
                return true;
            }
            return false;
        }

        /// Routes one raw byte. True when the hub took it.
        pub fn routeByte(app: *App, byte: u8) !bool {
            if (comptime !supported(App)) return false;
            if (!app.model_hub.active or yieldsToPrompt(app)) return false;
            const key: ?hub.Key = switch (byte) {
                '\r', '\n' => .enter,
                '\t' => .tab,
                0x7f, 0x08 => .backspace,
                0x03 => .escape,
                // Ctrl+P opens the hub, so it also closes it.
                0x10 => .escape,
                0x12 => .role_strip,
                0x14 => .thinking_strip,
                0x15 => .clear_query,
                0x20...0x7e => .{ .char = byte },
                else => null,
            };
            if (key) |value| try press(app, if (byte == 0x10) .close else .{ .key = value });
            return true;
        }

        /// Routes one decoded key. True when the hub took it.
        pub fn routeAction(app: *App, action: input_action.Action) !bool {
            if (comptime !supported(App)) return false;
            if (!app.model_hub.active or yieldsToPrompt(app)) return false;
            const key: ?hub.Key = switch (action) {
                .remapped_byte, .paste_start, .paste_end => return false,
                .escape => .escape,
                .cursor_up, .history_up => .up,
                .cursor_down, .history_down => .down,
                .cursor_left, .word_left => .left,
                .cursor_right, .word_right => .right,
                .page_up => .page_up,
                .page_down => .page_down,
                .home => .home,
                .end => .end,
                .delete_next => .delete,
                .clear_line, .delete_to_line_start => .clear_query,
                .delete_word_left => .backspace,
                .toggle_permission_mode => .back_tab,
                .open_model_catalog => {
                    close(app);
                    return true;
                },
                .refresh_model_catalog => .force_refresh,
                .mouse_wheel => |wheel| if (wheel == .up) .up else .down,
                .mouse_pointer => |pointer| .{ .mouse = .{
                    .kind = switch (pointer.kind) {
                        .press => .press,
                        .drag => .motion,
                        .release => .release,
                    },
                    .row = pointer.row,
                    .column = pointer.column,
                } },
                else => null,
            };
            if (key) |value| {
                if (value == .mouse) {
                    const effect = try app.model_hub.handleMouse(app.alloc, value.mouse);
                    if (effect != .none) app.shell.render_requests.request(.footer);
                    try apply(app, effect);
                } else try press(app, .{ .key = value });
            }
            return true;
        }

        const Press = union(enum) { key: hub.Key, close };

        fn press(app: *App, input: Press) !void {
            const key = switch (input) {
                .close => {
                    close(app);
                    return;
                },
                .key => |value| value,
            };
            const effect = try app.model_hub.handle(app.alloc, key);
            if (effect != .none) app.shell.render_requests.request(.footer);
            try apply(app, effect);
        }

        fn apply(app: *App, effect: hub.Effect) !void {
            switch (effect) {
                .none, .redraw => {},
                .close => close(app),
                .select_model => |choice| try selectModel(app, choice.model, choice.effort),
                .edit_role => |change| try editRole(app, change.role, change.edit, change.scope),
                .clear_role => |role| {
                    if (!try model_role_runtime.Runtime(App).saveId(app, role, null)) return;
                    var notice_buf: [96]u8 = undefined;
                    const notice = std.mem.print(&notice_buf, "{s} cleared", .{role.label()}) catch "";
                    try app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = notice }, true);
                    app.model_hub.setNotice(notice);
                    try refresh(app);
                },
                .create_role => |create| try createRole(app, create.name),
                .rename_role => |rename| try renameRole(app, rename.role, rename.name),
                .delete_role => |role| try deleteRole(app, role),
                .edit_tag => |change| try editTag(app, change.role, change.edit),
                .edit_bank => |change| try editBank(app, change.role, change.selectors),
                .edit_fallback => |change| try editFallback(app, change.selector, change.chain),
                .refresh_provider => |index| try refreshProvider(app, index),
                .toggle_cycle => |role| {
                    var buf: [64]RoleId = undefined;
                    try saveCycle(app, edits.toggleCycle(app.model_hub.snapshot.?.cycle, role, &buf));
                },
                .move_cycle => |move| {
                    var buf: [64]RoleId = undefined;
                    try saveCycle(app, edits.moveCycle(app.model_hub.snapshot.?.cycle, move.role, move.later, &buf));
                },
                .toggle_web_search => |index| try saveWebSearch(app, .{ .toggle = index }),
                .move_web_search => |move| try saveWebSearch(app, .{ .move = .{ .index = move.index, .later = move.later } }),
                .sign_in => |index| {
                    const key = try app.alloc.dupe(u8, app.model_hub.snapshot.?.providers[index].key);
                    defer app.alloc.free(key);
                    close(app);
                    if (comptime @hasDecl(App, "runLoginWithArgs")) try app.runLoginWithArgs(key);
                },
                .sign_out => |index| {
                    const key = try app.alloc.dupe(u8, app.model_hub.snapshot.?.providers[index].key);
                    defer app.alloc.free(key);
                    try app_auth_runtime.Runtime(App).runLogoutCommand(app, key);
                    var notice_buf: [96]u8 = undefined;
                    app.model_hub.setNotice(std.mem.print(&notice_buf, "Signed out of {s}", .{app.model_hub.snapshot.?.providers[index].name}) catch "");
                    try refresh(app);
                },
                .activate_provider => |index| {
                    const key = try app.alloc.dupe(u8, app.model_hub.snapshot.?.providers[index].key);
                    defer app.alloc.free(key);
                    var notice_buf: [96]u8 = undefined;
                    app.model_hub.setNotice(std.mem.print(&notice_buf, "Switching to {s}; its models load next", .{app.model_hub.snapshot.?.providers[index].name}) catch "");
                    _ = try switchProvider(app, key);
                    try refresh(app);
                },
            }
        }

        fn createRole(app: *App, name: []const u8) !void {
            const role = model_roles.parseRoleId(name) orelse {
                app.model_hub.setNotice("Role names use letters, numbers, _ and -");
                return;
            };
            if (role == .builtin) {
                app.model_hub.setNotice("That name is already a built-in role");
                return;
            }
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .model_role_create = name });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "role", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            try app.model_roles.createRole(app.alloc, role);
            app.model_hub.setNotice("Created role");
            try refresh(app);
        }

        fn renameRole(app: *App, role: RoleId, name: []const u8) !void {
            if (role != .custom) return;
            const next = model_roles.parseRoleId(name) orelse {
                app.model_hub.setNotice("Invalid role name");
                return;
            };
            if (next == .builtin) return;
            const old_name = role.custom;
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .model_role_rename = .{ .old_name = old_name, .new_name = next.custom } });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "role", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            const value = app.model_roles.table.getId(role);
            try app.model_roles.renameRole(app.alloc, role, next);
            if (value) |text| _ = try model_role_runtime.Runtime(App).saveId(app, next, text);
            app.model_hub.setNotice("Renamed role");
            try refresh(app);
        }

        fn deleteRole(app: *App, role: RoleId) !void {
            if (role != .custom) return;
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .model_role_delete = .{ .name = role.custom } });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "role", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            try app.model_roles.deleteRole(app.alloc, role);
            app.model_hub.setNotice("Deleted role");
            try refresh(app);
        }

        fn editTag(app: *App, role: RoleId, edit: hub.TagEdit) !void {
            const name = role.label();
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .model_role_tag = .{ .name = name, .tag = edit.tag, .display_name = edit.display_name, .color = edit.color, .hidden = edit.hidden, .clear = edit.clear } });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "role tag", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            if (edit.clear) {
                try app.model_roles.clearTag(app.alloc, role);
            } else {
                try app.model_roles.setTag(app.alloc, role, .{
                    .tag = edit.tag orelse "",
                    .name = edit.display_name orelse "",
                    .color = edit.color orelse "",
                    .hidden = edit.hidden orelse false,
                });
            }
            app.model_hub.setNotice("Saved role tag");
            try refresh(app);
        }

        fn editBank(app: *App, role: RoleId, selectors: []const []const u8) !void {
            const name = role.label();
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .model_role_bank = .{ .name = name, .selectors = selectors, .clear = selectors.len == 0 } });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "role bank", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            if (selectors.len == 0) try app.model_roles.clearBank(app.alloc, role) else try app.model_roles.setBank(app.alloc, role, selectors);
            app.model_hub.setNotice("Saved role bank");
            try refresh(app);
        }

        fn editFallback(app: *App, selector: []const u8, chain: ?[]const u8) !void {
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .fallback_chain = .{ .selector = selector, .chain = chain } });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "fallback chain", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            if (chain) |value| try app.model_roles.setFallback(app.alloc, selector, value) else try app.model_roles.clearFallback(app.alloc, selector);
            app.model_hub.setNotice("Saved fallback chain");
            try refresh(app);
        }

        fn refreshProvider(app: *App, index: u16) !void {
            const snapshot = app.model_hub.snapshot orelse return;
            if (index >= snapshot.providers.len) return;
            const key = snapshot.providers[index].key;
            if (model_provider.parse(key)) |provider| {
                const queued = if (comptime @hasDecl(App, "forceRefreshModelCatalogProvider"))
                    try app.forceRefreshModelCatalogProvider(provider)
                else
                    app.model_cache.refresh(provider, .force);
                if (!queued) {
                    app.model_hub.setNotice("That provider is not configured");
                    return;
                }
                app.model_hub.setNotice("Refreshing model list and credentials…");
                try refresh(app);
            }
        }

        fn saveRoleId(app: *App, role: RoleId, value: ?[]const u8, scope: hub.RoleScope) !bool {
            if (value) |text| model_roles.validateChain(text) catch {
                try app.writeDomainNotice(.{ .topic = "role", .tone = .@"error", .body = "That is not a model reference." }, true);
                return false;
            };
            const owned = if (value) |text| try app.alloc.dupe(u8, text) else null;
            defer if (owned) |bytes| app.alloc.free(bytes);
            const patch_scope: config_runtime.ModelRoleScope = if (scope == .workspace and @hasField(App, "workspace_root")) .workspace else .global;
            const workspace_root: ?[]const u8 = if (patch_scope == .workspace) app.workspace_root else null;
            var attempt = switch (role) {
                .builtin => |builtin_role| config_runtime.attemptUserPreferences(app.alloc, .{ .model_role = .{ .role = builtin_role, .value = owned }, .model_role_scope = patch_scope, .workspace_root = workspace_root }),
                .custom => |name| config_runtime.attemptUserPreferences(app.alloc, .{ .model_role = .{ .name = name, .value = owned }, .model_role_scope = patch_scope, .workspace_root = workspace_root }),
            };
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| {
                    try session_commands.reportUserSettingsFailure(app, "role", failure.err, failure.cleanup, false);
                    return false;
                },
                .outcome => {},
            }
            try app.model_roles.assignId(app.alloc, role, owned);
            return true;
        }

        /// Saves one role's changed chain (D250) and says what it does now.
        fn editRole(app: *App, role: RoleId, edit: hub.RoleEdit, scope: hub.RoleScope) !void {
            const snapshot = &app.model_hub.snapshot.?;
            const row = snapshot.roleRow(role) orelse return;
            var ref: ?[]u8 = null;
            defer if (ref) |bytes| app.alloc.free(bytes);
            var notice_buf: [160]u8 = undefined;
            const name = roleLabel(app, role);
            var notice: []const u8 = "";
            const chain_edit: edits.ChainEdit = switch (edit) {
                .put => |put| blk: {
                    const model = snapshot.models[put.model];
                    const provider = snapshot.providers[model.provider];
                    ref = try app.alloc.print("{s}/{s}", .{ provider.key, model.id });
                    const fallback = put.entry == null or put.entry.? > 0;
                    notice = std.mem.print(&notice_buf, "{s} {s} {s} on {s}", .{ name, if (fallback) "falls back to" else "now uses", model.name, provider.name }) catch "";
                    break :blk .{ .put = .{ .entry = put.entry, .ref = ref.? } };
                },
                .remove => |at| blk: {
                    notice = std.mem.print(&notice_buf, "Removed a fallback from {s}", .{name}) catch "";
                    break :blk .{ .remove = at };
                },
                .move => |move| blk: {
                    notice = std.mem.print(&notice_buf, "Reordered {s}'s models", .{name}) catch "";
                    break :blk .{ .move = .{ .entry = move.entry, .later = move.later } };
                },
                .thinking => |thinking| blk: {
                    notice = if (thinking.effort) |effort|
                        std.mem.print(&notice_buf, "{s} thinks at {s} with that model", .{ name, effort.label() }) catch ""
                    else
                        std.mem.print(&notice_buf, "{s} keeps the session's thinking with that model", .{name}) catch "";
                    break :blk .{ .thinking = .{ .entry = thinking.entry, .effort = thinking.effort } };
                },
            };
            const value = try edits.editRoleChain(app.alloc, row.entries, chain_edit);
            defer if (value) |bytes| app.alloc.free(bytes);
            debug_trace.logf("model_hub", "role={s} chain={s}", .{ role.label(), value orelse "" });
            if (!try saveRoleId(app, role, value, scope)) return;
            try app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = notice }, true);
            app.model_hub.setNotice(notice);
            try refresh(app);
        }

        /// Runs a slash command through the app's own router, so the hub
        /// does exactly what typing it would.
        fn runCommand(app: *App, command: []const u8) !void {
            debug_trace.logf("model_hub", "command {s}", .{command});
            if (comptime @hasDecl(App, "handleCommand")) try app.handleCommand(command);
        }

        fn selectModel(app: *App, index: usize, effort: ?types.ReasoningEffort) !void {
            const snapshot = &app.model_hub.snapshot.?;
            const model = snapshot.models[index];
            const provider = snapshot.providers[model.provider];
            const id = try app.alloc.dupe(u8, model.id);
            defer app.alloc.free(id);
            const has_levels = model.efforts.len > 0;
            if (!provider.active) {
                const key = try app.alloc.dupe(u8, provider.key);
                defer app.alloc.free(key);
                close(app);
                // The switch picks the provider's saved model, so save this
                // one for it first.
                if (model_provider.parse(key)) |target| {
                    var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .model_preference = .{ .provider = target, .model = id } });
                    attempt.deinit(app.alloc);
                }
                const switched = try switchProvider(app, key);
                if (switched) {
                    if (comptime @hasField(App, "model_performance")) app.model_performance.recordUsage(id);
                    try selectOnActive(app, id, effort, has_levels);
                }
                return;
            }
            close(app);
            if (comptime @hasField(App, "model_performance")) app.model_performance.recordUsage(id);
            try selectOnActive(app, id, effort, has_levels);
        }

        fn selectOnActive(app: *App, id: []const u8, effort: ?types.ReasoningEffort, has_levels: bool) !void {
            // The public `/model` command deliberately rejects arguments. Hub
            // selection uses the typed backend operation so detached sessions
            // enqueue their model config directly instead of routing through
            // that public command.
            try session_backend.Ops(App).selectModel(app, .{
                .model = id,
                .effort = effort orelse .auto,
                .fast_mode = false,
                .ultrafast_mode = false,
            });
            // A model without levels has nothing to set; `auto` is its only chip.
            // In-process selection applies effort as part of the typed operation;
            // detached sessions still expose effort as a separate remote option.
            if (effort) |value| if (has_levels and !session_backend.Ops(App).agentInProcess(app)) {
                const effort_command = try app.alloc.print("/effort {s}", .{value.label()});
                defer app.alloc.free(effort_command);
                try runCommand(app, effort_command);
            };
        }

        /// Makes `key` the session's provider. True when the switch applied
        /// now, so a model can follow; false when it runs in the background.
        fn switchProvider(app: *App, key: []const u8) !bool {
            const target = model_provider.parse(key) orelse return false;
            if (comptime @hasDecl(App, "selectProviderAfterLogin")) {
                if (try app.selectProviderAfterLogin(target)) return true;
            }
            try app_auth_runtime.Runtime(App).selectConfiguredProvider(app, key);
            return false;
        }

        fn saveCycle(app: *App, order: []const RoleId) !void {
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .cycle_order_ids = order });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "role", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            try app.model_roles.setCycleIds(app.alloc, order);
            app.model_hub.setNotice("Saved the Alt+P cycle");
            try refresh(app);
        }

        fn saveWebSearch(app: *App, edit: edits.WebSearchEdit) !void {
            const lists = edits.editWebSearch(app.model_hub.snapshot.?.web_search, edit);
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .web_search = .{ .order = lists.order(), .exclude = lists.exclude() } });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "web search", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            app.model_hub.setNotice("Saved the web search order");
            try refresh(app);
        }

        fn currentModel(app: *App) []const u8 {
            const view_model = if (comptime @hasField(App, "backend")) session_backend.Ops(App).view(app).model else null;
            return view_model orelse provider_runtime.model(app);
        }

        fn cachedProvider(catalogs: []const model_cache_runtime.ProviderHubSnapshot, key: []const u8) ?model_cache_runtime.ProviderHubSnapshot {
            for (catalogs) |catalog_snapshot| {
                if (std.mem.eql(u8, catalog_snapshot.provider.label(), key)) return catalog_snapshot;
            }
            return null;
        }

        fn cachedFailureStatus(catalogs: ?[]const model_cache_runtime.ProviderHubSnapshot, key: []const u8) ?u16 {
            const list = catalogs orelse return null;
            const cached = cachedProvider(list, key) orelse return null;
            const failure = cached.state.failure orelse return null;
            const status = failure.http_status orelse return null;
            return @backingInt(status);
        }

        fn addCachedCatalog(
            app: *App,
            builder: *catalog.Builder,
            index: u16,
            current: []const u8,
            cached: model_cache_runtime.ProviderHubSnapshot,
        ) !void {
            if (cached.models) |models| {
                for (models) |entry| {
                    const observed = performanceSnapshot(app, entry.id);
                    try builder.addModel(.{
                        .provider = index,
                        .id = entry.id,
                        .name = entry.name,
                        .description = entry.description orelse "",
                        .context_window = entry.context_window,
                        .max_tokens = entry.max_tokens,
                        .cost = if (entry.cost) |value| .{ .input = value.input, .output = value.output, .cache_read = value.cache_read, .cache_write = value.cache_write } else null,
                        .intelligence = entry.intelligence,
                        .is_beta = entry.beta,
                        .is_recommended = entry.recommended,
                        .released = entry.released,
                        .has_reasoning = entry.has_reasoning,
                        .has_vision = entry.has_vision,
                        .efforts = entry.efforts,
                        .current = std.mem.eql(u8, entry.id, current),
                        .mru_index = observed.mru_index,
                        .ttft_ms = observed.ttft_ms,
                        .tokens_per_second = observed.tokens_per_second,
                        .roles = try rolesFor(app, builder.arena(), builder.providers.items[index].key, entry.id),
                    });
                }
            } else if (cached.state.status == .loading and builder.providers.items[index].active) {
                builder.snapshot.loading = true;
            }
        }

        fn buildSnapshot(app: *App) !hub.Snapshot {
            if (comptime @hasField(App, "model_performance")) app.model_performance.reload();
            var builder: catalog.Builder = .init(app.alloc);
            errdefer builder.deinit();
            const arena = builder.arena();
            const active_id = provider_runtime.provider(app);
            const active_key = active_id.label();
            const current = currentModel(app);
            const view = app.auth.view();
            const inventory = sourceSet(view);
            const cached_catalogs = app.model_cache.snapshotForHubAll(arena) catch null;

            // Built-in providers sign in outside the hub; they appear once
            // signed in or in use.
            // Vercel AI Gateway is deliberately disabled as a selectable
            // provider in fx. Its credentials/auth remain owned by the
            // auth/runtime paths, but it must not become a hub scope merely
            // because a token happens to be present in the test environment.
            for ([_]model_provider.ProviderId{ .codex, .grok }) |id| {
                const is_active = active_id.eql(id);
                const signed_in = is_active or switch (id) {
                    .codex => inventory.contains(.chatgpt_subscription),
                    .grok => inventory.contains(.grok_subscription),
                    else => inventory.contains(.fx_login) or inventory.contains(.ai_gateway_api_key) or
                        inventory.contains(.vercel_oidc_token) or inventory.contains(.stored_key),
                };
                if (!signed_in) continue;
                const index = try builder.addProvider(.{
                    .key = id.label(),
                    .name = provider_catalog.find(id).name,
                    .detail = if (provider_catalog.find(id).subscription) "Subscription" else "Signed in",
                    .signed_in = true,
                    .active = is_active,
                    .sign_in = .external,
                    .can_sign_out = false,
                    .models_known = is_active,
                    .refreshing = if (cached_catalogs) |catalogs| if (cachedProvider(catalogs, id.label())) |cached| cached.state.status == .loading or cached.state.force_refresh_pending else false else false,
                    .last_attempt_age_ms = if (cached_catalogs) |catalogs| if (cachedProvider(catalogs, id.label())) |cached| cached.state.last_attempt_age_ms else null else null,
                    .last_success_age_ms = if (cached_catalogs) |catalogs| if (cachedProvider(catalogs, id.label())) |cached| cached.state.last_success_age_ms else null else null,
                    .failure_category = if (cached_catalogs) |catalogs| if (cachedProvider(catalogs, id.label())) |cached| if (cached.state.failure) |failure| @tagName(failure.category) else null else null else null,
                    .failure_status = cachedFailureStatus(cached_catalogs, id.label()),
                    .credential_source = if (cached_catalogs) |catalogs| if (cachedProvider(catalogs, id.label())) |cached| if (cached.state.credential_source) |source| @tagName(source) else null else null else null,
                });
                if (cached_catalogs) |catalogs| {
                    if (cachedProvider(catalogs, id.label())) |cached| {
                        try addCachedCatalog(app, &builder, index, current, cached);
                    } else if (is_active) try addActiveCatalog(app, &builder, index, current, null);
                } else if (is_active) try addActiveCatalog(app, &builder, index, current, null);
            }

            const definitions = app.provider_selection.definitions.definitions;
            for (definitions) |*definition| {
                const is_active = active_id == .configured and std.mem.eql(u8, active_key, definition.id);
                const state = try credentialState(arena, definition, is_active);
                const cached = if (cached_catalogs) |catalogs| cachedProvider(catalogs, definition.id) else null;
                const index = try builder.addProvider(.{
                    .key = definition.id,
                    .name = if (provider_registry.presetFor(definition.id)) |preset| preset.name else definition.id,
                    .detail = state.detail,
                    .signed_in = state.signed_in,
                    .active = is_active,
                    .sign_in = if (definition.preset) .login else .settings,
                    .can_sign_out = state.saved_key,
                    .models_known = if (cached) |value| value.models != null else is_active,
                    .refreshing = if (cached) |value| value.state.status == .loading or value.state.force_refresh_pending else false,
                    .last_attempt_age_ms = if (cached) |value| value.state.last_attempt_age_ms else null,
                    .last_success_age_ms = if (cached) |value| value.state.last_success_age_ms else null,
                    .failure_category = if (cached) |value| if (value.state.failure) |failure| @tagName(failure.category) else null else null,
                    .failure_status = if (cached) |value| if (value.state.failure) |failure| if (failure.http_status) |status| @backingInt(status) else null else null else null,
                    .credential_source = if (cached) |value| if (value.state.credential_source) |source| @tagName(source) else null else null,
                });
                if (cached) |value| try addCachedCatalog(app, &builder, index, current, value);
                if (is_active and cached == null) try addActiveCatalog(app, &builder, index, current, definition);
                try addDeclaredModels(app, &builder, index, definition, is_active, current);
            }

            try addRoles(app, &builder, definitions);
            // A detached session keeps its effort in the supervisor, which
            // does not report it; the hub then marks no level as in use.
            builder.snapshot.effort = if (session_backend.Ops(App).agentInProcess(app)) app.effort else null;
            const cycle = app.model_roles.table.cycleOrderIds();
            return builder.finish(cycle);
        }

        fn sourceSet(view: anytype) std.EnumSet(credentials.Source) {
            var set = view.available_inactive_sources;
            if (view.active_source) |source| set.insert(source);
            return set;
        }

        const CredentialState = struct { signed_in: bool, detail: []const u8, saved_key: bool };

        fn credentialState(arena: Allocator, definition: *const configured_provider.Definition, is_active: bool) !CredentialState {
            const saved = savedKey(arena, definition.id);
            switch (definition.auth) {
                .none => {
                    if (provider_registry.presetFor(definition.id)) |preset| {
                        const env_names: []const []const u8 = switch (preset.login) {
                            .claude_or_key => &.{ "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN" },
                            .cursor => &.{"CURSOR_API_KEY"},
                            else => &.{},
                        };
                        if (saved) return .{ .signed_in = true, .detail = "Saved key", .saved_key = true };
                        for (env_names) |name| if (io_mod.getenv(name) != null) return .{ .signed_in = true, .detail = "Key from the environment", .saved_key = false };
                        if (preset.login == .claude_or_key and is_active) return .{ .signed_in = true, .detail = "Claude Code login", .saved_key = false };
                        return .{ .signed_in = false, .detail = "Not signed in", .saved_key = false };
                    }
                    return .{ .signed_in = true, .detail = "No sign-in needed", .saved_key = false };
                },
                .bearer => |env| {
                    if (io_mod.getenv(env) != null) return .{ .signed_in = true, .detail = "Key from the environment", .saved_key = false };
                    return .{ .signed_in = false, .detail = try arena.print("Set {s} to sign in", .{env}), .saved_key = false };
                },
                .command => return .{ .signed_in = true, .detail = "Key from a command", .saved_key = false },
                .login => |env| {
                    if (saved) return .{ .signed_in = true, .detail = "Saved key", .saved_key = true };
                    if (env.len > 0 and io_mod.getenv(env) != null) return .{ .signed_in = true, .detail = "Key from the environment", .saved_key = false };
                    return .{ .signed_in = false, .detail = "Not signed in", .saved_key = false };
                },
            }
        }

        fn savedKey(arena: Allocator, id: []const u8) bool {
            const key = provider_keys.load(arena, id) catch return false;
            const value = key orelse return false;
            secret.zeroAndFree(arena, value);
            return true;
        }

        fn addActiveCatalog(
            app: *App,
            builder: *catalog.Builder,
            index: u16,
            current: []const u8,
            definition: ?*const configured_provider.Definition,
        ) !void {
            const entries = try app.model_cache.snapshotForHub(builder.arena());
            if (entries) |list| {
                for (list) |entry| {
                    const observed = performanceSnapshot(app, entry.id);
                    try builder.addModel(.{
                        .provider = index,
                        .id = entry.id,
                        .name = entry.name,
                        .description = entry.description orelse "",
                        .context_window = entry.context_window,
                        .max_tokens = entry.max_tokens,
                        .cost = if (entry.cost) |value| .{ .input = value.input, .output = value.output, .cache_read = value.cache_read, .cache_write = value.cache_write } else null,
                        .intelligence = entry.intelligence,
                        .is_beta = entry.beta,
                        .is_recommended = entry.recommended,
                        .released = entry.released,
                        .has_reasoning = entry.has_reasoning,
                        .has_vision = entry.has_vision,
                        .efforts = entry.efforts,
                        .current = std.mem.eql(u8, entry.id, current),
                        .mru_index = observed.mru_index,
                        .ttft_ms = observed.ttft_ms,
                        .tokens_per_second = observed.tokens_per_second,
                        .roles = try rolesFor(app, builder.arena(), builder.providers.items[index].key, entry.id),
                    });
                }
            } else builder.snapshot.loading = app.model_cache.isLoading();
            // The definition's own models fill in what the catalog lacks.
            if (definition) |value| try addDeclaredModels(app, builder, index, value, true, current);
            // The session's model stays listed even when no catalog has it.
            if (current.len > 0) try builder.addModel(.{
                .provider = index,
                .id = current,
                .name = "",
                .current = true,
                .roles = try rolesFor(app, builder.arena(), builder.providers.items[index].key, current),
            });
        }

        fn addDeclaredModels(
            app: *App,
            builder: *catalog.Builder,
            index: u16,
            definition: *const configured_provider.Definition,
            is_active: bool,
            current: []const u8,
        ) !void {
            for ([_][]const configured_provider.ModelMetadata{ definition.model_metadata, definition.builtin_models }) |list| {
                for (list) |metadata| {
                    const observed = performanceSnapshot(app, metadata.id);
                    try builder.addModel(.{
                        .provider = index,
                        .id = metadata.id,
                        .name = metadata.name orelse "",
                        .description = metadata.description orelse "",
                        .context_window = metadata.context_window,
                        .max_tokens = metadata.max_output_tokens,
                        .cost = if (metadata.cost) |value| .{ .input = value.input, .output = value.output, .cache_read = value.cache_read, .cache_write = value.cache_write } else null,
                        .intelligence = metadata.intelligence,
                        .is_beta = metadata.beta,
                        .is_recommended = metadata.recommended,
                        .released = metadata.released,
                        .efforts = metadata.reasoning_efforts,
                        .has_reasoning = metadata.reasoning_efforts.len > 0,
                        .has_vision = metadata.supports_vision orelse false,
                        .current = is_active and std.mem.eql(u8, metadata.id, current),
                        .mru_index = observed.mru_index,
                        .ttft_ms = observed.ttft_ms,
                        .tokens_per_second = observed.tokens_per_second,
                        .roles = try rolesFor(app, builder.arena(), definition.id, metadata.id),
                    });
                }
            }
        }

        /// The roles whose assignment names `id` on `provider`, plus the
        /// default role on the model it falls back to, the one Alt+P picks.
        fn rolesFor(app: *App, arena: Allocator, provider: []const u8, id: []const u8) ![]const RoleId {
            const host = model_role_runtime.host(app);
            const active_key = host.provider.label();
            const ids = try app.model_roles.table.roleIds(arena);
            var out = try arena.alloc(RoleId, ids.len);
            var count: usize = 0;
            for (ids) |role| {
                switch (role) {
                    .builtin => |builtin_role| {
                        if (builtin_role != .default and app.model_roles.table.getId(role) == null) continue;
                    },
                    .custom => {},
                }
                const ref = model_roles.resolveId(&app.model_roles.table, role, roleContext(host, active_key)) orelse continue;
                const ref_provider = ref.provider orelse active_key;
                if (!std.mem.eql(u8, ref_provider, provider) or !std.mem.eql(u8, ref.model, id)) continue;
                out[count] = role;
                count += 1;
            }
            return out[0..count];
        }

        fn roleLabel(app: *App, role: RoleId) []const u8 {
            if (app.model_roles.table.tagFor(role)) |tag| {
                if (tag.tag.len > 0) return tag.tag;
                if (tag.name.len > 0) return tag.name;
            }
            return role.label();
        }

        fn addRoles(app: *App, builder: *catalog.Builder, definitions: []const configured_provider.Definition) !void {
            const arena = builder.arena();
            const table = &app.model_roles.table;
            const cycle = table.cycleOrderIds();
            const host = model_role_runtime.host(app);
            const active_id = provider_runtime.provider(app);
            const active_key = active_id.label();
            const ids = try table.roleIds(arena);
            for (ids) |role| {
                const raw = table.getId(role);
                var entries: std.ArrayList(catalog.EntryRow) = .empty;
                if (raw) |text| {
                    const chain = model_roles.Chain.parse(text);
                    for (chain.entries()) |entry| try entries.append(arena, try entryRow(app, builder, entry, definitions, host));
                }
                const resolved = host.pickSelectionId(role);
                const tag = table.tagFor(role);
                const label = if (tag) |value| if (value.tag.len > 0) value.tag else if (value.name.len > 0) value.name else role.label() else role.label();
                const summary = if (tag) |value| if (value.name.len > 0) value.name else role.label() else role.label();
                var cycle_position: ?usize = null;
                for (cycle, 0..) |member, position| {
                    if (member.eql(role)) {
                        cycle_position = position + 1;
                        break;
                    }
                }
                try builder.addRole(.{
                    .role = role,
                    .label = label,
                    .summary = summary,
                    .hidden = if (tag) |value| value.hidden else false,
                    .assigned = if (entries.items.len > 0) entries.items[0].shown else null,
                    .entries = entries.items,
                    .in_use = model_roles.chosenEntryId(table, role, roleContext(host, active_key)),
                    .resolved = if (resolved) |selection| try describeModel(app, arena, selection.provider.label(), selection.model, definitions) else null,
                    .chain = fallbackChain(role),
                    .cycle_position = cycle_position,
                });
            }
        }

        /// `active_key` must be the provider's label from a value that
        /// outlives the context: a configured provider's label points into
        /// the ID it is called on.
        fn roleContext(host: model_role_runtime.Host, active_key: []const u8) model_roles.Context {
            return .{
                .provider = active_key,
                .default_model = host.defaultModel(),
                .configured = host.set.definitions,
                .known = host.known,
                .candidates = host.candidates,
            };
        }

        /// One chain entry as the hub shows it, with whether it can be used
        /// now and the thinking levels its model offers.
        fn entryRow(
            app: *App,
            builder: *catalog.Builder,
            entry: model_roles.Entry,
            definitions: []const configured_provider.Definition,
            host: model_role_runtime.Host,
        ) !catalog.EntryRow {
            const arena = builder.arena();
            var row: catalog.EntryRow = .{ .ref = entry.ref, .shown = try describeRef(app, arena, entry.ref, definitions), .effort = entry.effort };
            if (entry.ref[0] == '@') {
                row.state = .alias;
                return row;
            }
            var provider = host.provider;
            const active_key = provider.label();
            const ref = model_roles.parseRefId(entry.ref, .{ .builtin = .default }, definitions);
            const key = ref.provider orelse active_key;
            for (builder.models.items) |model| {
                if (!std.mem.eql(u8, builder.providers.items[model.provider].key, key)) continue;
                if (std.mem.eql(u8, model.id, ref.model)) row.efforts = model.efforts;
            }
            if (std.mem.eql(u8, key, active_key)) {
                const known = if (host.known) |check| check.known_fn(check.context, ref.model) else true;
                row.state = if (known) .ready else .unknown_model;
                return row;
            }
            row.state = .signed_out;
            for (builder.providers.items) |listed| {
                if (std.mem.eql(u8, listed.key, key) and listed.signed_in) row.state = .other_provider;
            }
            return row;
        }

        /// A role reference as people read it: `@small` follows Small, and
        /// `provider/model` names the provider.
        fn describeRef(app: *App, arena: Allocator, raw: []const u8, definitions: []const configured_provider.Definition) ![]const u8 {
            if (raw[0] == '@') {
                const role = model_roles.parseRoleId(raw[1..]) orelse return arena.dupe(u8, raw);
                return arena.print("follows {s}", .{role.label()});
            }
            if (std.mem.findScalar(u8, raw, '/')) |slash| {
                const prefix = raw[0..slash];
                if (providerName(prefix, definitions)) |_| return describeModel(app, arena, prefix, raw[slash + 1 ..], definitions);
            }
            return describeModel(app, arena, provider_runtime.provider(app).label(), raw, definitions);
        }

        fn describeModel(app: *App, arena: Allocator, provider: []const u8, model: []const u8, definitions: []const configured_provider.Definition) ![]const u8 {
            _ = app;
            const name = providerName(provider, definitions) orelse provider;
            return arena.print("{s} · {s}", .{ name, model });
        }

        fn providerName(key: []const u8, definitions: []const configured_provider.Definition) ?[]const u8 {
            if (provider_registry.presetFor(key)) |preset| return preset.name;
            for (definitions) |definition| if (std.mem.eql(u8, definition.id, key)) return definition.id;
            const id = model_provider.parse(key) orelse return null;
            if (id == .configured) return null;
            return provider_catalog.find(id).name;
        }

        fn fallbackChain(role: RoleId) []const u8 {
            return switch (role) {
                .custom => "the session's model",
                .builtin => |builtin_role| switch (builtin_role) {
                    .default => "the model the profile saved for this provider",
                    .small => "the provider's low-cost model",
                    .title, .tiny => "follows Small",
                    .review => "the reviewer's default model",
                    .worker, .deep, .compact => "the session's model",
                    .designer, .commit, .advisor => "unused by proto-fx",
                },
            };
        }

        fn addWebSearch(app: *App, builder: *catalog.Builder, inventory: std.EnumSet(credentials.Source), active_id: model_provider.ProviderId) !void {
            const bank = app.providerSet().web_search orelse return;
            var settings = bank.loadSettings(app.alloc);
            defer settings.deinit(app.alloc);
            var env: web_search_bank.Env = .{};
            // A subscription searches with the session's own sign-in, so it
            // is ready while the session runs on it (`envFromInputs`); the
            // token itself is not needed to say so.
            if (active_id.eql(.codex) and inventory.contains(.chatgpt_subscription)) env.chatgpt_token = "present";
            if (active_id.eql(.grok) and inventory.contains(.grok_subscription)) env.grok_token = "present";
            if (inventory.contains(.fx_login) or inventory.contains(.ai_gateway_api_key) or inventory.contains(.stored_key)) env.gateway_key = "present";
            env.searxng_url = settings.searxng_url;
            var listed: [edits.max_web_search]bool = @splat(false);
            for (settings.order) |id| {
                for (bank.members, 0..) |*member, index| {
                    if (index >= listed.len or listed[index] or !std.ascii.eqlIgnoreCase(member.id, id)) continue;
                    listed[index] = true;
                    try addSearchMember(builder, member, &settings, &env);
                }
            }
            for (bank.members, 0..) |*member, index| {
                if (index >= listed.len or listed[index]) continue;
                try addSearchMember(builder, member, &settings, &env);
            }
        }

        fn addSearchMember(builder: *catalog.Builder, member: *const web_search_bank.Member, settings: *const web_search_bank.Settings, env: *const web_search_bank.Env) !void {
            var excluded = false;
            for (settings.exclude) |id| excluded = excluded or std.ascii.eqlIgnoreCase(id, member.id);
            try builder.addWebSearch(.{
                .id = member.id,
                .name = member.label,
                .excluded = excluded,
                .ready = member.available(env, true),
                .needs = member.needs.text(),
                .needs_detail = member.needs.detail(),
            });
        }
    };
}
