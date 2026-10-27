//! The app side of the model hub (D221): builds the hub's snapshot from the
//! app's providers, catalog, roles and web search settings, routes keys to
//! it while it is open, and carries out what it asks for through the same
//! commands and settings writes `/model`, `/role` and `/login` use.

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
const session_backend = @import("session_backend.zig");
const session_commands = @import("../session/session_commands.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");

const Allocator = std.mem.Allocator;
const Role = model_roles.Role;

pub fn supported(comptime App: type) bool {
    return @hasField(App, "model_hub") and @hasField(App, "model_cache") and
        @hasField(App, "model_roles") and @hasField(App, "auth") and
        provider_runtime.supported(App) and !builtin.target.cpu.arch.isWasm();
}

pub fn Runtime(comptime App: type) type {
    return struct {
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
                .mouse_wheel => |wheel| if (wheel == .up) .up else .down,
                else => null,
            };
            if (key) |value| try press(app, .{ .key = value });
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
                .assign_role => |assign| {
                    const snapshot = &app.model_hub.snapshot.?;
                    const model = snapshot.models[assign.model];
                    const provider = snapshot.providers[model.provider];
                    const ref = try app.alloc.print("{s}/{s}", .{ provider.key, model.id });
                    defer app.alloc.free(ref);
                    const notice = try app.alloc.print("{s} now uses {s} on {s}", .{ catalog.roleName(assign.role), model.name, provider.name });
                    defer app.alloc.free(notice);
                    if (!try model_role_runtime.Runtime(App).save(app, assign.role, ref)) return;
                    try app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = notice }, true);
                    app.model_hub.setNotice(notice);
                    try refresh(app);
                },
                .clear_role => |role| {
                    if (!try model_role_runtime.Runtime(App).save(app, role, null)) return;
                    var notice_buf: [96]u8 = undefined;
                    const notice = std.mem.print(&notice_buf, "{s} cleared", .{catalog.roleName(role)}) catch "";
                    try app.writeDomainNotice(.{ .topic = "role", .tone = .neutral, .body = notice }, true);
                    app.model_hub.setNotice(notice);
                    try refresh(app);
                },
                .toggle_cycle => |role| {
                    var buf: [model_roles.role_count]Role = undefined;
                    try saveCycle(app, edits.toggleCycle(app.model_hub.snapshot.?.cycle, role, &buf));
                },
                .move_cycle => |move| {
                    var buf: [model_roles.role_count]Role = undefined;
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
                if (switched) try selectOnActive(app, id, effort, has_levels);
                return;
            }
            close(app);
            try selectOnActive(app, id, effort, has_levels);
        }

        fn selectOnActive(app: *App, id: []const u8, effort: ?types.ReasoningEffort, has_levels: bool) !void {
            const command = try app.alloc.print("/model {s}", .{id});
            defer app.alloc.free(command);
            try runCommand(app, command);
            // A model without levels has nothing to set; `auto` is its only chip.
            if (effort) |value| if (has_levels) {
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

        fn saveCycle(app: *App, order: []const Role) !void {
            var attempt = config_runtime.attemptUserPreferences(app.alloc, .{ .cycle_order = order });
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return session_commands.reportUserSettingsFailure(app, "role", failure.err, failure.cleanup, false),
                .outcome => {},
            }
            try app.model_roles.setCycle(app.alloc, order);
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

        fn buildSnapshot(app: *App) !hub.Snapshot {
            var builder: catalog.Builder = .init(app.alloc);
            errdefer builder.deinit();
            const arena = builder.arena();
            const active_id = provider_runtime.provider(app);
            const active_key = active_id.label();
            const current = currentModel(app);
            const view = app.auth.view();
            const inventory = sourceSet(view);

            // Built-in providers sign in outside the hub; they appear once
            // signed in or in use.
            for ([_]model_provider.ProviderId{ .gateway, .codex, .grok }) |id| {
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
                });
                if (is_active) try addActiveCatalog(app, &builder, index, current, null);
            }

            const definitions = app.provider_selection.definitions.definitions;
            for (definitions) |*definition| {
                const is_active = active_id == .configured and std.mem.eql(u8, active_key, definition.id);
                const state = try credentialState(arena, definition, is_active);
                const index = try builder.addProvider(.{
                    .key = definition.id,
                    .name = if (provider_registry.presetFor(definition.id)) |preset| preset.name else definition.id,
                    .detail = state.detail,
                    .signed_in = state.signed_in,
                    .active = is_active,
                    .sign_in = if (definition.preset) .login else .settings,
                    .can_sign_out = state.saved_key,
                });
                if (is_active) {
                    try addActiveCatalog(app, &builder, index, current, definition);
                } else {
                    try addDeclaredModels(app, &builder, index, definition, false, current);
                }
            }

            try addRoles(app, &builder, definitions);
            try addWebSearch(app, &builder, inventory);
            // A detached session keeps its effort in the supervisor, which
            // does not report it; the hub then marks no level as in use.
            builder.snapshot.effort = if (session_backend.Ops(App).agentInProcess(app)) app.effort else null;
            var cycle_buf: [model_roles.role_count]Role = undefined;
            const cycle = app.model_roles.table.cycleOrder();
            @memcpy(cycle_buf[0..cycle.len], cycle);
            return builder.finish(cycle_buf[0..cycle.len]);
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
                for (list) |entry| try builder.addModel(.{
                    .provider = index,
                    .id = entry.id,
                    .name = entry.name,
                    .context_window = entry.context_window,
                    .efforts = entry.efforts,
                    .current = std.mem.eql(u8, entry.id, current),
                    .roles = try rolesFor(app, builder.arena(), builder.providers.items[index].key, entry.id),
                });
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
                for (list) |metadata| try builder.addModel(.{
                    .provider = index,
                    .id = metadata.id,
                    .name = "",
                    .context_window = metadata.context_window,
                    .efforts = metadata.reasoning_efforts,
                    .current = is_active and std.mem.eql(u8, metadata.id, current),
                    .roles = try rolesFor(app, builder.arena(), definition.id, metadata.id),
                });
            }
        }

        /// The roles whose assignment names `id` on `provider`, plus the
        /// default role when it falls back to the session's model.
        fn rolesFor(app: *App, arena: Allocator, provider: []const u8, id: []const u8) ![]const Role {
            const host = model_role_runtime.host(app);
            const active_key = host.provider.label();
            var out: [model_roles.role_count]Role = undefined;
            var count: usize = 0;
            for (catalog.role_order) |role| {
                const ref = model_roles.resolve(&app.model_roles.table, role, .{
                    .provider = active_key,
                    .default_model = host.current_model,
                    .configured = host.set.definitions,
                }) orelse continue;
                if (role != .default and app.model_roles.table.get(role) == null) continue;
                const ref_provider = ref.provider orelse active_key;
                if (!std.mem.eql(u8, ref_provider, provider) or !std.mem.eql(u8, ref.model, id)) continue;
                out[count] = role;
                count += 1;
            }
            return arena.dupe(Role, out[0..count]);
        }

        fn addRoles(app: *App, builder: *catalog.Builder, definitions: []const configured_provider.Definition) !void {
            const arena = builder.arena();
            const table = &app.model_roles.table;
            const cycle = table.cycleOrder();
            for (catalog.role_order) |role| {
                const raw = table.get(role);
                const resolved = model_role_runtime.resolveModel(app, role);
                try builder.addRole(.{
                    .role = role,
                    .assigned = if (raw) |text| try describeRef(app, arena, text, definitions) else null,
                    .resolved = if (resolved) |model| try describeModel(app, arena, provider_runtime.provider(app).label(), model, definitions) else null,
                    .chain = fallbackChain(role),
                    .cycle_position = if (std.mem.findScalar(Role, cycle, role)) |position| position + 1 else null,
                });
            }
        }

        /// A role reference as people read it: `@small` follows Small, and
        /// `provider/model` names the provider.
        fn describeRef(app: *App, arena: Allocator, raw: []const u8, definitions: []const configured_provider.Definition) ![]const u8 {
            if (raw[0] == '@') {
                const role = Role.parse(raw[1..]) orelse return arena.dupe(u8, raw);
                return arena.print("follows {s}", .{catalog.roleName(role)});
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

        fn fallbackChain(role: Role) []const u8 {
            return switch (role) {
                .default => "the model the profile saved for this provider",
                .small => "the provider's low-cost model",
                .title, .tiny => "follows Small",
                .review => "the reviewer's default model",
                .worker, .deep, .compact => "the session's model",
                .designer, .commit, .advisor => "unused by proto-fx",
            };
        }

        fn addWebSearch(app: *App, builder: *catalog.Builder, inventory: std.EnumSet(credentials.Source)) !void {
            const bank = app.providerSet().web_search orelse return;
            var settings = bank.loadSettings(app.alloc);
            defer settings.deinit(app.alloc);
            var env: web_search_bank.Env = .{};
            // Signed-in subscriptions and gateway keys make their searches
            // ready; the token itself is not needed to say so.
            if (inventory.contains(.chatgpt_subscription)) env.chatgpt_token = "present";
            if (inventory.contains(.grok_subscription)) env.grok_token = "present";
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
            });
        }
    };
}
