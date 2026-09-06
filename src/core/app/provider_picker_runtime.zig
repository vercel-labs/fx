//! Behavior for the columnar `/provider` picker.
//!
//! The picker walks left to right: provider, then the sign-in method for the
//! gateway (`oauth`/`api-key`), then either the Vercel team (oauth with a live
//! session), the which-key column (`env`/`saved`/`new`), or the masked key
//! entry field. Each list column writes its choice into the composer, so the
//! next column anchors under its own argument the way `/model` does.
//!
//! Terminal actions are not reimplemented here. Every commit is expressed as an
//! `auth_runtime.Choice` and handed to the auth runtime, which already owns
//! provider switching, OAuth, API key entry, and team selection.

const std = @import("std");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const provider_picker_catalog = @import("../auth/provider_picker_catalog.zig");
const model_provider = @import("../config/model_provider.zig");
const picker_state = @import("../input/picker_state.zig");
const list_window = @import("../shared/list_window.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");

const ProviderPickerStage = picker_state.ProviderPickerStage;
const max_options = provider_picker_catalog.max_column_options;

/// Scratch for one column: stack-local in key handlers, container-retained in
/// the render path. Team labels borrow from the auth runtime's team list, so
/// no slice may be kept past the frame or key press that filled the buffer.
pub const ColumnBuffer = struct {
    labels: [max_options][]const u8 = undefined,
    annotations: [max_options][]const u8 = undefined,
    count: usize = 0,
    /// Backing bytes for the API key column, whose single row is composed per
    /// frame rather than picked from a list.
    field: [provider_picker_catalog.max_key_field_bytes]u8 = undefined,
};

/// Hosts without a composer, an auth runtime, a provider selection, or native
/// auth have no `/provider` picker; every entry point below is inert for them.
/// The native-auth gate matters because the picker triggers on typed text: the
/// command handlers refuse politely on WASM, but the composer would otherwise
/// still open columns whose leaves (key entry, OAuth) cannot run there.
pub fn supported(comptime App: type) bool {
    return runtime_profile.allows(App, .native_auth) and
        @hasField(App, "input_runtime") and
        @hasField(App, "auth") and
        provider_runtime.supported(App);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Fills one column with its options and their `current` annotations,
        /// then narrows both to what the typed query matches.
        pub fn columnOptions(
            app: *App,
            query: picker_state.ProviderPickerQuery,
            column: *ColumnBuffer,
        ) usize {
            // Emptied up front so early returns leave no stale slice count in
            // a caller-retained buffer.
            column.count = 0;
            if (comptime !supported(App)) return 0;
            if (app.auth.sourceInventoryRefreshActive()) {
                column.labels[0] = "checking credentials...";
                column.annotations[0] = "";
                column.count = 1;
                return column.count;
            }
            const active_provider = provider_runtime.provider(app);
            var count: usize = 0;
            switch (query.stage) {
                .provider => {
                    var slugs: [provider_picker_catalog.max_provider_options][]const u8 = undefined;
                    count = provider_picker_catalog.providerOptions(&slugs);
                    for (slugs[0..count], 0..) |slug, i| {
                        column.labels[i] = slug;
                        const id = provider_catalog.parse(slug) orelse .gateway;
                        column.annotations[i] = if (id == active_provider and
                            model_provider.authorizesCredential(id, app.auth.credentialSource())) "current" else "";
                    }
                },
                .method => {
                    const pending = app.input_runtime.picker.provider_picker_pending_provider.items;
                    const provider = provider_catalog.parse(pending) orelse return 0;
                    const active_source = app.auth.credentialSource();
                    const methods = provider_picker_catalog.providerMethods(provider);
                    for (methods, 0..) |method, i| {
                        column.labels[i] = provider_picker_catalog.methodSlug(method);
                        const in_use = provider == active_provider and
                            if (active_source) |source| provider_picker_catalog.methodMatchesSource(method, source) else false;
                        column.annotations[i] = if (in_use) "current" else "";
                    }
                    count = methods.len;
                },
                .key_source => {
                    const view = app.auth.pickerView();
                    // `current` always means "used for inference right now",
                    // so a key is only current while the gateway is active.
                    const active = if (active_provider == .gateway) app.auth.credentialSource() else null;
                    inline for (@typeInfo(provider_picker_catalog.KeySource).@"enum".fields) |field| {
                        const key_source = @field(provider_picker_catalog.KeySource, field.name);
                        const credential = provider_picker_catalog.keySourceCredential(key_source);
                        const detected = if (credential) |value| view.available_sources.contains(value) else true;
                        if (detected) {
                            column.labels[count] = provider_picker_catalog.keySourceSlug(key_source);
                            column.annotations[count] = provider_picker_catalog.keySourceAnnotation(
                                key_source,
                                credential != null and credential == active,
                            );
                            count += 1;
                        }
                    }
                },
                .api_key => {
                    // The column outlives the entry while the save thread
                    // works; an empty ready-looking field there would invite
                    // pasting the key again, into the composer this time.
                    column.labels[0] = if (app.auth.apiKeySaveInFlight())
                        "saving the key..."
                    else
                        provider_picker_catalog.writeKeyField(&column.field, app.auth.apiKeyMaskCount());
                    column.annotations[0] = "";
                    column.count = 1;
                    return 1;
                },
                .team => {
                    const selection = app.auth.loadedTeamSelection() orelse return 0;
                    // `current` always means "used for inference right now".
                    // The login session remembers a team even while a
                    // subscription provider or an API key is doing the actual
                    // inference; that remembered team earns no marker then.
                    const oauth_inference_active = active_provider == .gateway and
                        app.auth.credentialSource() == .fx_login;
                    const current = if (oauth_inference_active) selection.currentTeam() else null;
                    for (selection.teams.items) |team| {
                        if (count >= provider_picker_catalog.max_team_options) break;
                        column.labels[count] = team.slug;
                        const is_current = if (current) |slug|
                            std.mem.eql(u8, slug, team.slug) or std.mem.eql(u8, slug, team.id)
                        else
                            false;
                        column.annotations[count] = if (is_current) "current" else "";
                        count += 1;
                    }
                },
            }
            column.count = picker_state.filterAnnotatedLabels(
                query.query,
                &column.labels,
                &column.annotations,
                count,
            );
            return column.count;
        }

        pub fn hasQuery(app: *App) bool {
            if (comptime !supported(App)) return false;
            return app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) != null;
        }

        pub fn navigate(app: *App, delta: i32) void {
            if (comptime !supported(App)) return;
            if (app.auth.sourceInventoryRefreshActive()) return;
            if (!hasQuery(app)) return;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return;
            var column: ColumnBuffer = .{};
            const count = columnOptions(app, query, &column);
            const picker = &app.input_runtime.picker;
            switch (query.stage) {
                .provider => list_window.advanceSelection(&picker.provider_column_index, &picker.provider_column_window_start, count, delta),
                .method => list_window.advanceSelection(&picker.method_column_index, &picker.method_column_window_start, count, delta),
                .team => list_window.advanceSelection(&picker.team_column_index, &picker.team_column_window_start, count, delta),
                .key_source => list_window.advanceSelection(&picker.key_source_column_index, &picker.key_source_column_window_start, count, delta),
                .api_key => {},
            }
        }

        /// Tab: write the highlighted option into the composer without moving
        /// to the next column. The rewrite clears the picker flow (every full
        /// composer replacement does), so the stage is re-established after.
        pub fn autocomplete(app: *App) !void {
            if (comptime !supported(App)) return;
            if (app.auth.sourceInventoryRefreshActive()) return;
            if (!hasQuery(app)) return;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return;
            const stage = query.stage;
            if (stage == .api_key) return;
            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            const selected = selectedLabel(app, query, &column) orelse return;

            const picker = &app.input_runtime.picker;
            const prefix = try app.alloc.dupe(u8, query.prefix);
            defer app.alloc.free(prefix);
            const provider_slug = try app.alloc.dupe(u8, picker.provider_picker_pending_provider.items);
            defer app.alloc.free(provider_slug);
            const method_slug = try app.alloc.dupe(u8, picker.provider_picker_pending_method.items);
            defer app.alloc.free(method_slug);

            switch (stage) {
                .provider => try setComposerText(app, "{s}{s}", .{ prefix, selected }),
                .method => {
                    try setComposerText(app, "{s}{s} {s}", .{ prefix, provider_slug, selected });
                    try picker.beginProviderPickerFlow(app.alloc, provider_slug, "", .method);
                },
                .team, .key_source => {
                    try setComposerText(app, "{s}{s} {s} {s}", .{ prefix, provider_slug, method_slug, selected });
                    try picker.beginProviderPickerFlow(app.alloc, provider_slug, method_slug, stage);
                },
                .api_key => unreachable,
            }
            app.shell.render_requests.request(.footer);
        }

        /// Space advances only when the exact typed token opens another column
        /// with no side effects: a provider that has a method column, or the
        /// `api-key` method (its next column is local). Everything that acts
        /// (switching, OAuth, saving) stays on Enter, so a reflexive space
        /// never commits and never touches the network.
        pub fn advanceOnSpace(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (app.auth.sourceInventoryRefreshActive()) return false;
            if (!hasQuery(app)) return false;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return false;
            if (app.input_runtime.edit_state.cursor != app.input_runtime.edit_state.input.items.len) return false;
            if (std.mem.trim(u8, query.query, " \t").len == 0) return false;

            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            const selected = exactLabel(query.query, &column) orelse return false;
            switch (query.stage) {
                .provider => {
                    const provider = provider_catalog.parse(selected) orelse return false;
                    if (provider_picker_catalog.providerMethods(provider).len == 0) return false;
                },
                .method => {
                    if (provider_picker_catalog.parseMethod(selected) != .api_key) return false;
                },
                .team, .key_source, .api_key => return false,
            }
            return try submit(app);
        }

        /// Enter: open the next column, or hand the completed choice to the
        /// auth runtime.
        pub fn submit(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (!hasQuery(app)) return false;
            if (app.auth.sourceInventoryRefreshActive()) return true;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return false;
            var column: ColumnBuffer = .{};
            _ = columnOptions(app, query, &column);
            // No matching option: let Enter fall through so the router reports
            // the unknown text instead of silently eating the key.
            const selected = selectedLabel(app, query, &column) orelse return false;

            switch (query.stage) {
                .provider => {
                    const provider = provider_catalog.parse(selected) orelse return false;
                    if (provider_picker_catalog.providerMethods(provider).len == 0) {
                        try commit(app, .{ .provider = provider });
                        return true;
                    }
                    // Nothing is applied yet: the provider is only a heading
                    // until the method, and then the team, are chosen too.
                    const slug = provider_catalog.find(provider).slug;
                    try setComposerText(app, "{s}{s} ", .{ query.prefix, slug });
                    try app.input_runtime.picker.beginProviderPickerFlow(app.alloc, slug, "", .method);
                    app.shell.render_requests.request(.footer);
                    return true;
                },
                .method => {
                    const method = provider_picker_catalog.parseMethod(selected) orelse return false;
                    // The inventory is what says whether this method already
                    // has a credential to switch to; it goes stale the moment
                    // a key lands in the environment or the keychain.
                    try app.auth.refreshSourceInventory(app.alloc);
                    const provider = provider_catalog.parse(
                        app.input_runtime.picker.provider_picker_pending_provider.items,
                    ) orelse .gateway;
                    if (method == .api_key) {
                        // With detected keys the next column asks which to use
                        // (or `new` to paste one); with none there is nothing
                        // to ask, so the paste field opens directly.
                        const view = app.auth.pickerView();
                        if (view.available_sources.contains(.ai_gateway_api_key) or
                            view.available_sources.contains(.stored_key))
                        {
                            try openKeyStage(app, query.prefix, .key_source);
                            return true;
                        }
                        try openKeyStage(app, query.prefix, .api_key);
                        return true;
                    }
                    // A first sign-in picks the team as part of the OAuth flow,
                    // so the team column only earns a place once a session
                    // exists to list teams for.
                    const prefix = try app.alloc.dupe(u8, query.prefix);
                    defer app.alloc.free(prefix);
                    const provider_slug = try app.alloc.dupe(u8, app.input_runtime.picker.provider_picker_pending_provider.items);
                    defer app.alloc.free(provider_slug);

                    const teams = try app_auth_runtime.Runtime(App).loadTeamsForProviderPicker(app);
                    switch (teams) {
                        .ready => {},
                        .needs_sign_in, .blocked => {
                            // An ambient OIDC token satisfies oauth without a
                            // browser round trip; switch to it instead of
                            // forcing a sign-in it does not need.
                            if (ambientOauthSource(app)) |source| {
                                try commitSource(app, source, provider);
                                return true;
                            }
                            if (teams == .blocked) return true;
                            app.input_runtime.picker.clearProviderPickerFlow();
                            app.input_runtime.inputResetState().clearCurrent(app.alloc);
                            try app_auth_runtime.Runtime(App).beginSignInForProviderPicker(app);
                            app.shell.render_requests.request(.footer);
                            return true;
                        },
                        // Teams refine the account rather than gate it, so this
                        // is the last column the choice has: the login is still
                        // the credential the user asked for, teams or not.
                        .unavailable => {
                            try commitSource(app, .fx_login, provider);
                            return true;
                        },
                    }
                    const method_slug = provider_picker_catalog.methodSlug(method);
                    try setComposerText(app, "{s}{s} {s} ", .{ prefix, provider_slug, method_slug });
                    try app.input_runtime.picker.beginProviderPickerFlow(app.alloc, provider_slug, method_slug, .team);
                    selectCurrentTeam(app);
                    app.shell.render_requests.request(.footer);
                    return true;
                },
                .key_source => {
                    const key_source = provider_picker_catalog.parseKeySource(selected) orelse return false;
                    const pending_provider = provider_catalog.parse(
                        app.input_runtime.picker.provider_picker_pending_provider.items,
                    ) orelse .gateway;
                    if (provider_picker_catalog.keySourceCredential(key_source)) |credential| {
                        try commitSource(app, credential, pending_provider);
                    } else {
                        try openKeyStage(app, query.prefix, .api_key);
                    }
                    return true;
                },
                // Enter is consumed by the key field itself, which the auth
                // runtime routes before the composer ever sees the byte.
                .api_key => return false,
                .team => {
                    const index = teamIndex(app, selected) orelse return false;
                    const provider = provider_catalog.parse(
                        app.input_runtime.picker.provider_picker_pending_provider.items,
                    ) orelse .gateway;
                    try commitTeam(app, index, provider);
                    return true;
                },
            }
        }

        /// Opens one of the api-key stages under the `api-key` argument: the
        /// which-key list, or the masked entry field (whose bytes the auth
        /// runtime owns; the composer only carries the breadcrumb).
        fn openKeyStage(app: *App, prefix: []const u8, stage: ProviderPickerStage) !void {
            const provider_slug = try app.alloc.dupe(u8, app.input_runtime.picker.provider_picker_pending_provider.items);
            defer app.alloc.free(provider_slug);
            const method_slug = provider_picker_catalog.methodSlug(.api_key);
            const stable_prefix = try app.alloc.dupe(u8, prefix);
            defer app.alloc.free(stable_prefix);

            try setComposerText(app, "{s}{s} {s} ", .{ stable_prefix, provider_slug, method_slug });
            try app.input_runtime.picker.beginProviderPickerFlow(app.alloc, provider_slug, method_slug, stage);
            if (stage == .api_key) app.auth.openApiKeyPickerInline(app.alloc);
            app.shell.render_requests.request(.footer);
        }

        /// Left arrow at the start of a column: reopen the column to its left.
        pub fn stepBack(app: *App) !bool {
            if (comptime !supported(App)) return false;
            if (!hasQuery(app)) return false;
            const query = app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) orelse return false;
            if (query.stage == .provider) return false;

            const picker = &app.input_runtime.picker;
            const prefix = try app.alloc.dupe(u8, query.prefix);
            defer app.alloc.free(prefix);
            const provider_slug = try app.alloc.dupe(u8, picker.provider_picker_pending_provider.items);
            defer app.alloc.free(provider_slug);

            switch (query.stage) {
                .provider => return false,
                // Arrow keys never reach here while the key field is active;
                // its entry routing consumes them. Esc is the way out.
                .api_key => return false,
                .method => {
                    // Back to the full provider column, not to the committed
                    // token as a filter: the point of stepping back is seeing
                    // the alternatives again, with the old choice preselected.
                    try setComposerText(app, "{s}", .{prefix});
                    picker.clearProviderPickerFlow();
                    syncProviderSelection(app, provider_slug);
                },
                .team, .key_source => {
                    const method_slug = try app.alloc.dupe(u8, picker.provider_picker_pending_method.items);
                    defer app.alloc.free(method_slug);
                    try setComposerText(app, "{s}{s} ", .{ prefix, provider_slug });
                    try picker.beginProviderPickerFlow(app.alloc, provider_slug, "", .method);
                    syncMethodSelection(app, provider_slug, method_slug);
                },
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn abandon(app: *App) void {
            if (comptime !supported(App)) return;
            app.auth.releaseLoadedTeamSelection(app.alloc);
            if (app.input_runtime.picker.provider_picker_stage == .provider) return;
            app.auth.cancelInlineApiKeyEntry(app.alloc);
            app.input_runtime.picker.clearProviderPickerFlow();
        }

        /// Retires the key column once the entry it was showing has ended, so a
        /// saved or cancelled key does not leave the breadcrumb behind.
        pub fn closeKeyColumn(app: *App) void {
            if (comptime !supported(App)) return;
            if (app.input_runtime.picker.provider_picker_stage != .api_key) return;
            if (app.auth.apiKeyInlineActive()) return;
            // Enter pops the entry stage before the save thread finishes; the
            // column must outlive the save so the switch-to-gateway gate can
            // still see where the key came from when the result lands.
            if (app.auth.apiKeySaveInFlight()) return;
            app.input_runtime.picker.clearProviderPickerFlow();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            app.shell.render_requests.request(.footer);
        }

        fn commit(app: *App, choice: auth_runtime.Choice) !void {
            // Clear first: the choice may open the device-code or API key
            // screen, and a leftover `/provider ...` line under it reads as if the
            // picker were still waiting for input.
            app.input_runtime.picker.clearProviderPickerFlow();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            try app_auth_runtime.Runtime(App).applyPickerChoice(app, choice);
            app.shell.render_requests.request(.footer);
        }

        /// An ambient OIDC token satisfies the oauth method without a browser
        /// round trip. It is the only source worth switching to here: a stored
        /// fx login session that reached this point was already judged dead by
        /// the team load, so offering it back would switch to a corpse.
        fn ambientOauthSource(app: *App) ?credentials.Source {
            const view = app.auth.pickerView();
            if (!view.available_sources.contains(.vercel_oidc_token)) return null;
            if (app.auth.credentialSource() == .vercel_oidc_token) return null;
            return .vercel_oidc_token;
        }

        /// Switching to a detected credential is a complete leaf: apply the
        /// source, then the provider it authenticates.
        fn commitSource(app: *App, source: credentials.Source, provider: model_provider.ProviderId) !void {
            app.input_runtime.picker.clearProviderPickerFlow();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            const auth_rt = app_auth_runtime.Runtime(App);
            // The provider only follows a credential that actually applied;
            // switching after a failed selection would strand the provider
            // without the credential the user just asked it to use.
            if (try auth_rt.applySourceChoice(app, source)) {
                if (provider_runtime.provider(app) != provider) {
                    try auth_rt.applyPickerChoice(app, .{ .provider = provider });
                }
            }
            app.shell.render_requests.request(.footer);
        }

        /// The team is the last column, so this is where the whole path
        /// (provider, method, team) finally takes effect.
        fn commitTeam(app: *App, index: usize, provider: model_provider.ProviderId) !void {
            app.input_runtime.picker.clearProviderPickerFlow();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            const auth_rt = app_auth_runtime.Runtime(App);
            if (try auth_rt.applyTeamChoice(app, index)) {
                if (provider_runtime.provider(app) != provider) {
                    try auth_rt.applyPickerChoice(app, .{ .provider = provider });
                }
            }
            app.shell.render_requests.request(.footer);
        }

        fn selectedLabel(
            app: *App,
            query: picker_state.ProviderPickerQuery,
            column: *const ColumnBuffer,
        ) ?[]const u8 {
            if (column.count == 0) return null;
            if (exactLabel(query.query, column)) |label| return label;
            const index = currentIndex(app, query.stage) % column.count;
            return column.labels[index];
        }

        fn currentIndex(app: *App, stage: ProviderPickerStage) usize {
            const picker = &app.input_runtime.picker;
            return switch (stage) {
                .provider => picker.provider_column_index,
                .method => picker.method_column_index,
                .team => picker.team_column_index,
                .key_source => picker.key_source_column_index,
                .api_key => 0,
            };
        }

        fn teamIndex(app: *App, slug: []const u8) ?usize {
            const selection = app.auth.loadedTeamSelection() orelse return null;
            for (selection.teams.items, 0..) |team, index| {
                if (std.mem.eql(u8, team.slug, slug)) return index;
            }
            return null;
        }

        fn selectCurrentTeam(app: *App) void {
            const picker = &app.input_runtime.picker;
            picker.team_column_index = 0;
            picker.team_column_window_start = 0;

            const selection = app.auth.loadedTeamSelection() orelse return;
            const current = selection.currentTeam() orelse return;
            for (selection.teams.items, 0..) |team, index| {
                if (!std.mem.eql(u8, current, team.slug) and !std.mem.eql(u8, current, team.id)) continue;
                picker.team_column_index = index;
                picker.team_column_window_start = list_window.updateEdgeStart(
                    0,
                    selection.teams.items.len,
                    index,
                    list_window.default_max_picker_rows,
                );
                return;
            }
        }

        fn syncMethodSelection(app: *App, provider_slug: []const u8, method_slug: []const u8) void {
            const provider = provider_catalog.parse(provider_slug) orelse return;
            for (provider_picker_catalog.providerMethods(provider), 0..) |method, index| {
                if (!std.mem.eql(u8, provider_picker_catalog.methodSlug(method), method_slug)) continue;
                app.input_runtime.picker.method_column_index = index;
                return;
            }
        }

        fn syncProviderSelection(app: *App, slug: []const u8) void {
            var slugs: [provider_picker_catalog.max_provider_options][]const u8 = undefined;
            const count = provider_picker_catalog.providerOptions(&slugs);
            for (slugs[0..count], 0..) |candidate, index| {
                if (!std.mem.eql(u8, candidate, slug)) continue;
                app.input_runtime.picker.provider_column_index = index;
                app.input_runtime.picker.provider_column_window_start = list_window.updateEdgeStart(
                    0,
                    count,
                    index,
                    list_window.default_max_picker_rows,
                );
                return;
            }
        }

        fn setComposerText(app: *App, comptime fmt: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(app.alloc, fmt, args);
            defer app.alloc.free(text);
            try app.input_runtime.textReplacementState().replace(app.alloc, text);
        }
    };
}

fn exactLabel(raw_query: []const u8, column: *const ColumnBuffer) ?[]const u8 {
    const query = std.mem.trim(u8, raw_query, " \t");
    if (query.len == 0) return null;
    for (column.labels[0..column.count]) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, query)) return candidate;
    }
    return null;
}

test "exact label matching ignores case and surrounding spaces" {
    var column: ColumnBuffer = .{};
    column.labels[0] = "vercel";
    column.labels[1] = "codex";
    column.count = 2;

    try std.testing.expectEqualStrings("codex", exactLabel(" CODEX ", &column).?);
    try std.testing.expect(exactLabel("cod", &column) == null);
    try std.testing.expect(exactLabel("", &column) == null);
}

test "model provider identity stays aligned with the catalog slugs" {
    var slugs: [provider_picker_catalog.max_provider_options][]const u8 = undefined;
    const count = provider_picker_catalog.providerOptions(&slugs);
    for (slugs[0..count]) |slug| {
        const id: model_provider.ProviderId = provider_catalog.parse(slug).?;
        try std.testing.expectEqualStrings(slug, provider_catalog.find(id).slug);
    }
}

const core_input_runtime = @import("../input/runtime.zig");
const ColumnTestApp = struct {
    alloc: std.mem.Allocator,
    input_runtime: core_input_runtime.Runtime = .{},
    provider_selection: provider_runtime.Runtime,
    auth: TestAuth = .{},
    shell: struct {
        render_requests: struct {
            fn request(_: *@This(), _: enum { footer }) void {}
        } = .{},
    } = .{},

    const TestAuth = struct {
        source: ?credentials.Source = null,
        mask_count: usize = 0,
        save_in_flight: bool = false,
        inventory_refresh_active: bool = false,
        available: auth_runtime.SourceSet = .empty,

        fn sourceInventoryRefreshActive(self: *const TestAuth) bool {
            return self.inventory_refresh_active;
        }

        fn credentialSource(self: *const TestAuth) ?credentials.Source {
            return self.source;
        }

        fn pickerView(self: *const TestAuth) auth_runtime.PickerView {
            return .{
                .active = false,
                .available_sources = self.available,
                .selected_choice = null,
                .active_source = self.source,
                .include_skip = false,
            };
        }

        fn apiKeyMaskCount(self: *const TestAuth) usize {
            return self.mask_count;
        }

        fn apiKeyInlineActive(_: *const TestAuth) bool {
            return true;
        }

        fn apiKeySaveInFlight(self: *const TestAuth) bool {
            return self.save_in_flight;
        }

        fn loadedTeamSelection(_: *TestAuth) ?*@import("../auth/login_flow.zig").TeamSelection {
            return null;
        }
    };

    fn init(alloc: std.mem.Allocator) ColumnTestApp {
        return .{ .alloc = alloc, .provider_selection = .{ .alloc = alloc } };
    }

    fn deinit(self: *ColumnTestApp) void {
        self.input_runtime.deinit(self.alloc);
        self.provider_selection.deinit();
    }
};

fn columnFor(app: *ColumnTestApp, stage: ProviderPickerStage, query: []const u8) ColumnBuffer {
    var column: ColumnBuffer = .{};
    _ = Runtime(ColumnTestApp).columnOptions(app, .{
        .stage = stage,
        .prefix = "/provider ",
        .query = query,
        .token_start = 0,
    }, &column);
    return column;
}

test "provider column lists every provider and marks the active one" {
    const alloc = std.testing.allocator;
    var app = ColumnTestApp.init(alloc);
    defer app.deinit();
    app.auth.source = .ai_gateway_api_key;

    const column = columnFor(&app, .provider, "");
    try std.testing.expect(column.count >= 2);
    try std.testing.expectEqualStrings("vercel", column.labels[0]);
    try std.testing.expectEqualStrings("current", column.annotations[0]);
    for (column.annotations[1..column.count]) |annotation| {
        try std.testing.expectEqualStrings("", annotation);
    }
}

test "provider column requires matching authentication for a current annotation" {
    var app = ColumnTestApp.init(std.testing.allocator);
    defer app.deinit();
    for ([_]?credentials.Source{ null, .chatgpt_subscription }) |source| {
        app.auth.source = source;
        const column = columnFor(&app, .provider, "");
        for (column.annotations[0..column.count]) |annotation| {
            try std.testing.expectEqualStrings("", annotation);
        }
    }
    app.auth.source = .host_managed;
    try std.testing.expectEqualStrings("current", columnFor(&app, .provider, "").annotations[0]);
}

test "provider column narrows to what was typed" {
    const alloc = std.testing.allocator;
    var app = ColumnTestApp.init(alloc);
    defer app.deinit();

    const column = columnFor(&app, .provider, "gro");
    try std.testing.expectEqual(@as(usize, 1), column.count);
    try std.testing.expectEqualStrings("grok", column.labels[0]);
}

test "provider picker loading preserves query and selection instead of exposing cached options" {
    const alloc = std.testing.allocator;
    var app = ColumnTestApp.init(alloc);
    defer app.deinit();
    app.auth.inventory_refresh_active = true;
    try app.input_runtime.textReplacementState().replace(alloc, "/provider co");
    app.input_runtime.picker.provider_column_index = 2;

    const pending = columnFor(&app, .provider, "co");
    try std.testing.expectEqual(@as(usize, 1), pending.count);
    try std.testing.expectEqualStrings("checking credentials...", pending.labels[0]);
    try Runtime(ColumnTestApp).autocomplete(&app);
    Runtime(ColumnTestApp).navigate(&app, 1);
    try std.testing.expectEqualStrings("/provider co", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 2), app.input_runtime.picker.provider_column_index);

    app.auth.inventory_refresh_active = false;
    const ready = columnFor(&app, .provider, "co");
    try std.testing.expectEqual(@as(usize, 1), ready.count);
    try std.testing.expectEqualStrings("codex", ready.labels[0]);
    try Runtime(ColumnTestApp).autocomplete(&app);
    try std.testing.expectEqualStrings("/provider codex", app.input_runtime.edit_state.input.items);
}

test "method column marks the credential the active provider is using" {
    const alloc = std.testing.allocator;
    var app = ColumnTestApp.init(alloc);
    defer app.deinit();
    app.auth.source = .ai_gateway_api_key;
    try app.input_runtime.picker.beginProviderPickerFlow(alloc, "vercel", "", .method);

    const column = columnFor(&app, .method, "");
    try std.testing.expectEqual(@as(usize, 2), column.count);
    try std.testing.expectEqualStrings("oauth", column.labels[0]);
    try std.testing.expectEqualStrings("", column.annotations[0]);
    try std.testing.expectEqualStrings("api-key", column.labels[1]);
    try std.testing.expectEqualStrings("current", column.annotations[1]);
}

test "a subscription provider has no method column to open" {
    const alloc = std.testing.allocator;
    var app = ColumnTestApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.picker.beginProviderPickerFlow(alloc, "codex", "", .method);

    try std.testing.expectEqual(@as(usize, 0), columnFor(&app, .method, "").count);
}

test "key column is a masked field, not a list of options" {
    const alloc = std.testing.allocator;
    var app = ColumnTestApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.picker.beginProviderPickerFlow(alloc, "vercel", "api-key", .api_key);

    const empty = columnFor(&app, .api_key, "");
    try std.testing.expectEqual(@as(usize, 1), empty.count);
    try std.testing.expect(std.mem.endsWith(u8, empty.labels[0], provider_picker_catalog.key_field_placeholder));

    app.auth.mask_count = 4;
    const typed = columnFor(&app, .api_key, "");
    try std.testing.expectEqual(@as(usize, 1), typed.count);
    try std.testing.expect(std.mem.indexOf(u8, typed.labels[0], provider_picker_catalog.key_field_placeholder) == null);

    // While the save thread works the row says so instead of rendering an
    // empty ready-looking field.
    app.auth.save_in_flight = true;
    const saving = columnFor(&app, .api_key, "");
    try std.testing.expectEqual(@as(usize, 1), saving.count);
    try std.testing.expectEqualStrings("saving the key...", saving.labels[0]);
}

test "key source column offers only detected keys plus new" {
    const alloc = std.testing.allocator;
    var app = ColumnTestApp.init(alloc);
    defer app.deinit();
    try app.input_runtime.picker.beginProviderPickerFlow(alloc, "vercel", "api-key", .key_source);

    // Nothing detected: only `new` remains.
    const bare = columnFor(&app, .key_source, "");
    try std.testing.expectEqual(@as(usize, 1), bare.count);
    try std.testing.expectEqualStrings("new", bare.labels[0]);

    app.auth.available = auth_runtime.SourceSet.initMany(&.{ .ai_gateway_api_key, .stored_key });
    app.auth.source = .ai_gateway_api_key;
    const full = columnFor(&app, .key_source, "");
    try std.testing.expectEqual(@as(usize, 3), full.count);
    try std.testing.expectEqualStrings("env", full.labels[0]);
    try std.testing.expect(std.mem.find(u8, full.annotations[0], "current") != null);
    try std.testing.expectEqualStrings("saved", full.labels[1]);
    try std.testing.expect(std.mem.find(u8, full.annotations[1], "current") == null);
}
