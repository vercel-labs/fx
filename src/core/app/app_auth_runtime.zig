const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const io_mod = @import("../shared/io.zig");
const credentials = @import("../auth/credentials.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const login_flow = @import("../auth/login_flow.zig");
const types = @import("../shared/types.zig");

fn oauthAuthEnabled(comptime App: type) bool {
    return runtime_profile.allows(App, .native_auth) or
        runtime_profile.allows(App, .js_host_auth);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        fn ensurePromptCredential(app: *App) !bool {
            if (app.auth.credentialSource() != null) return true;

            const auth_view = app.auth.view();
            if (auth_view.onboarding_skipped) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = credentials.missing_interactive_credential_message,
                }, true);
            } else if (!app.auth.pickerView().active) {
                try app.auth.refreshSourceInventory(app.alloc);
                app.auth.openOnboardingPicker(app.alloc);
            }
            app.shell.render_requests.request(.footer);
            return false;
        }

        pub fn runLoginCommand(app: *App) !void {
            if (comptime !oauthAuthEnabled(App)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Set FX_API_KEY through createFxTerminal() to authenticate this WASM session.",
                }, true);
                return;
            }
            try beginSignIn(app, false);
        }

        pub fn runLogoutCommand(app: *App) !void {
            if (comptime !oauthAuthEnabled(App)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Authentication is owned by the embedding SDK for this WASM session.",
                }, true);
                return;
            }
            try app.flushBeforeBlockingExternalWork();
            const result = login_flow.logout(app.alloc, app.auth.oauthTransport()) catch |err| switch (err) {
                error.SessionDeleteFailed => {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Could not complete fx logout. The current source is unchanged.",
                    });
                    return;
                },
            };
            try applyLogoutResult(app, result);
        }

        pub fn openSetupHub(app: *App) !void {
            if (comptime !runtime_profile.allows(App, .native_auth)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "API key setup is unavailable in this WASM session.",
                }, true);
                return;
            }
            try app.auth.refreshSourceInventory(app.alloc);
            app.auth.openPicker(app.alloc);
            app.shell.render_requests.request(.footer);
        }

        fn applyLogoutResult(app: *App, result: login_flow.LogoutResult) !void {
            // Logging out is an explicit rejection of that credential, so a
            // remembered pointer to it would silently reactivate on next login.
            // A remembered source always wins resolution, so an active fx login
            // is the only way one can be remembered; clearing otherwise is a
            // no-op against a store that holds nothing.
            if (app.auth.credentialSource() == .fx_login) forgetCredentialSource(app);
            applyCredentialChange(app, try app.auth.reconcileAfterFxLoginLogout(app.alloc));
            try writeAuthNotice(app, if (result.local_durability_failed)
                .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Could not confirm durable fx logout. The active source was recalculated.",
                }
            else if (result.session_deleted)
                .{
                    .topic = "auth",
                    .tone = .neutral,
                    .body = "Signed out of fx.",
                }
            else
                .{
                    .topic = "auth",
                    .tone = .neutral,
                    .body = "No fx login session found.",
                });
            if (result.remote_revocation_failed) {
                try writeAuthNotice(app, .{
                    .topic = "auth",
                    .tone = .warning,
                    .body = login_flow.remote_revocation_warning,
                });
            }
        }

        pub fn applyPickerChoice(app: *App, choice: auth_runtime.Choice) !void {
            if (comptime !oauthAuthEnabled(App)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Browser authentication is supplied by the embedding SDK.",
                }, true);
                return;
            }
            switch (choice) {
                .source => |source| try applySourceChoice(app, source),
                .action => |action| switch (action) {
                    .login => try beginSignIn(app, true),
                    .setup => {
                        if (comptime !runtime_profile.allows(App, .native_auth)) {
                            try app.writeDomainNotice(.{
                                .topic = "auth",
                                .tone = .warning,
                                .body = "API key setup is unavailable in this WASM session.",
                            }, true);
                            return;
                        }
                        prepareApiKeyInputBoundary(app);
                        app.auth.openApiKeyPickerFromRoot(app.alloc);
                    },
                    .change_team => try beginTeamPicker(app),
                    .switch_credential => app.auth.openSwitchCredentialPicker(app.alloc),
                    .automatic => try applyAutomaticCredential(app),
                },
                .team => |index| try applyTeamChoice(app, index),
            }
        }

        pub fn routeAuthPickerByte(app: *App, byte: u8) !bool {
            if (app.auth.signInEntryActive()) {
                switch (byte) {
                    3, 4 => _ = app.auth.popPickerStage(app.alloc),
                    '\r', '\n' => try openSignInBrowser(app),
                    else => {},
                }
                app.shell.render_requests.request(.footer);
                return true;
            }
            if (app.auth.teamPickerActive()) {
                const consumed = switch (byte) {
                    8, 127 => app.auth.deleteTeamQueryByte(),
                    else => try app.auth.appendTeamQueryByte(app.alloc, byte),
                };
                if (consumed) {
                    app.shell.render_requests.request(.footer);
                    return true;
                }
            }
            if (!app.auth.apiKeyEntryActive()) return false;
            switch (byte) {
                3, 4 => _ = app.auth.popPickerStage(app.alloc),
                '\r', '\n' => try submitApiKeyEntry(app),
                8, 127 => _ = app.auth.deleteApiKeyByte(),
                else => _ = try app.auth.appendApiKeyByte(app.alloc, byte),
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn routeAuthPickerEscapeAction(app: *App, action: anytype) bool {
            if (!app.auth.signInEntryActive() and !app.auth.apiKeyEntryActive()) return false;
            return switch (action) {
                .escape, .remapped_byte => false,
                else => true,
            };
        }

        pub fn collectSignInFacts(app: *App) !void {
            if (comptime !oauthAuthEnabled(App)) return;
            app.auth.pulseSignIn(app.alloc);
            switch (app.auth.pollSignInTransition(app.alloc)) {
                .none => {},
                .cancelled => app.shell.render_requests.request(.footer),
                .failed => |err| {
                    debug_trace.logf("auth", "login failed err={s}", .{@errorName(err)});
                    _ = app.auth.popPickerStage(app.alloc);
                    try writeLoginError(app, err);
                },
                .succeeded => |completed| {
                    var selection = completed;
                    defer selection.deinit(app.alloc);

                    if (!try selectCredentialSource(app, .fx_login)) {
                        _ = app.auth.popPickerStage(app.alloc);
                        try writeAuthNotice(app, .{
                            .topic = "auth",
                            .tone = .@"error",
                            .body = "Signed in, but the fx login credential could not be loaded.",
                        });
                        return;
                    }
                    rememberCredentialSource(app, .fx_login);

                    if (selection.teams.items.len > 0) {
                        app.auth.openTeamPicker(app.alloc, &selection);
                    } else {
                        _ = app.auth.popPickerStage(app.alloc);
                    }
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .neutral,
                        .body = "Signed in to Vercel.",
                    });
                },
            }
        }

        fn prepareApiKeyInputBoundary(app: *App) void {
            if (comptime @hasDecl(App, "prepareApiKeyInputBoundary")) {
                app.prepareApiKeyInputBoundary();
            }
        }

        fn submitApiKeyEntry(app: *App) !void {
            if (app.auth.pickerView().api_key_mask_count == 0) return;
            switch (app.auth.beginApiKeySave(app.alloc)) {
                .started => app.shell.render_requests.request(.footer),
                .empty => {},
                .busy => try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Still saving the previous API key. Nothing was stored for this one; try again in a moment.",
                }, true),
            }
        }

        /// Polled from the event loop so a save that blocks on a locked key store
        /// or a slow gateway never stalls rendering.
        pub fn collectApiKeySaveFacts(app: *App) !void {
            const result = app.auth.takeApiKeySaveResult(app.alloc) orelse return;
            try applyApiKeySaveResult(app, result);
        }

        fn applyApiKeySaveResult(app: *App, result: auth_runtime.ApiKeySaveResult) !void {
            switch (result) {
                .empty => return,
                .saved => |changed| {
                    applyCredentialChange(app, changed);
                    rememberCredentialSource(app, .stored_key);
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Saved the API key to {s} and made it active.",
                        .{credentials.stored_key_backend_label},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .neutral,
                        .body = body,
                    }, true);
                },
                .gateway_refused => try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "The AI Gateway refused that API key. Nothing was stored.",
                }, true),
                .gateway_unavailable => try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Could not verify that API key with AI Gateway. Nothing was stored.",
                }, true),
                .store_failed => {
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Could not save the API key to {s}. Nothing was stored.",
                        .{credentials.stored_key_backend_label},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = body,
                    }, true);
                },
                .reload_failed => {
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Saved the API key to {s}, but could not make it active.",
                        .{credentials.stored_key_backend_label},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .warning,
                        .body = body,
                    }, true);
                },
            }
        }

        /// Clearing the remembered choice must also re-resolve, otherwise the
        /// session would keep running on a source precedence no longer selects.
        fn applyAutomaticCredential(app: *App) !void {
            forgetCredentialSource(app);
            app.auth.closePicker(app.alloc);
            applyCredentialChange(app, try app.auth.reselectByPrecedence(app.alloc));
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .neutral,
                .body = "Using automatic credential precedence again.",
            }, true);
        }

        fn forgetCredentialSource(app: *App) void {
            if (comptime @hasDecl(@TypeOf(app.auth), "rememberSelectedCredentialReference")) {
                app.auth.rememberSelectedCredentialReference("automatic") catch |err| {
                    debug_trace.logf(
                        "auth",
                        "connection credential choice not cleared err={s}",
                        .{@errorName(err)},
                    );
                    return;
                };
            }
            // G11 removes this compatibility projection once status readers
            // consume the selected connection as their authority.
            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .clear_credential_source = true },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .outcome => debug_trace.logf("auth", "credential choice cleared", .{}),
                .failure => |failure| debug_trace.logf(
                    "auth",
                    "credential choice not cleared err={s}",
                    .{@errorName(failure.err)},
                ),
            }
        }

        fn applySourceChoice(app: *App, source: credentials.Source) !void {
            const body = try std.fmt.allocPrint(
                app.alloc,
                "Switched credential to {s}.",
                .{credentials.sourceLabel(source)},
            );
            defer app.alloc.free(body);

            if (!try selectCredentialSource(app, source)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "That credential is no longer available. The current source is unchanged.",
                }, true);
                return;
            }

            rememberCredentialSource(app, source);
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        /// An explicit source choice outlives the session. Failing to persist
        /// leaves the source active for this run rather than refusing a working
        /// credential the user already selected.
        fn rememberCredentialSource(app: *App, source: credentials.Source) void {
            if (comptime @hasDecl(@TypeOf(app.auth), "rememberSelectedCredentialReference")) {
                app.auth.rememberSelectedCredentialReference(@tagName(source)) catch |err| {
                    debug_trace.logf(
                        "auth",
                        "connection credential choice not persisted source={t} err={s}",
                        .{ source, @errorName(err) },
                    );
                    return;
                };
            }
            // G11 removes this compatibility projection once status readers
            // consume the selected connection as their authority.
            if (comptime @hasDecl(App, "persistCredentialSourcePreference")) {
                app.persistCredentialSourcePreference(source);
                return;
            }
            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .credential_source = source },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .outcome => debug_trace.logf("auth", "credential choice persisted source={t}", .{source}),
                .failure => |failure| debug_trace.logf(
                    "auth",
                    "credential choice not persisted source={t} err={s}",
                    .{ source, @errorName(failure.err) },
                ),
            }
        }

        fn beginTeamPicker(app: *App) !void {
            if (!app.auth.pickerView().fx_login_session_available) return;
            try app.flushBeforeBlockingExternalWork();

            var selection = login_flow.loadTeamSelection(app.alloc, app.auth.oauthTransport()) catch |err| {
                debug_trace.logf("auth", "team picker load failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = switch (err) {
                        error.NoSession => "The fx login session is no longer available. Sign in to change teams.",
                        error.NoTeams => "No Vercel teams are available for this account.",
                        else => "Could not load Vercel teams. The current team is unchanged.",
                    },
                }, true);
                return;
            };
            defer selection.deinit(app.alloc);
            app.auth.openTeamPicker(app.alloc, &selection);
            app.shell.render_requests.request(.footer);
        }

        fn applyTeamChoice(app: *App, index: usize) !void {
            const selection = app.auth.teamSelection() orelse return;
            if (index >= selection.teams.items.len) return;
            const team = selection.teams.items[index];
            const body = try std.fmt.allocPrint(
                app.alloc,
                "Changed Vercel team to {s} ({s}).",
                .{ team.name, team.slug },
            );
            defer app.alloc.free(body);

            var selected_team = selection.select(app.alloc, index) catch |err| {
                debug_trace.logf("auth", "team change failed err={s}", .{@errorName(err)});
                app.auth.closePicker(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = switch (err) {
                        error.SessionChanged, error.NoSession => "The fx login session changed before the team could be saved.",
                        else => "Could not change the Vercel team. The current team is unchanged.",
                    },
                }, true);
                return;
            };
            defer selected_team.deinit(app.alloc);

            if (app.auth.credentialSource() == .fx_login) {
                applyCredentialChange(app, app.auth.adoptSelectedTeam(app.alloc, &selected_team));
            } else if (!try selectCredentialSource(app, .fx_login)) {
                app.auth.closePicker(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Changed the Vercel team, but the fx login credential could not be loaded.",
                }, true);
                return;
            }
            rememberCredentialSource(app, .fx_login);
            app.auth.closePicker(app.alloc);
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        fn beginSignIn(app: *App, from_root: bool) !void {
            try app.flushBeforeBlockingExternalWork();

            const started = if (from_root)
                app.auth.openSignInPickerFromRoot(app.alloc)
            else
                app.auth.openSignInPicker(app.alloc);
            if (started catch |err| {
                debug_trace.logf("auth", "login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                // Open the browser as soon as the device code is ready instead of
                // waiting for Enter; Enter stays as a manual re-open, and
                // FX_NO_OPEN_BROWSER opts out for headless/SSH sessions.
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn openSignInBrowser(app: *App) !void {
            const url = (try app.auth.signInBrowserUrlAlloc(app.alloc)) orelse return;
            defer app.alloc.free(url);
            if (!try app.urlOpener().open(app.alloc, url)) {
                debug_trace.logf("auth", "login browser launcher failed", .{});
            }
        }

        pub fn selectCredentialSource(app: *App, source: credentials.Source) !bool {
            const changed = (try app.auth.selectSource(app.alloc, source)) orelse return false;
            applyCredentialChange(app, changed);
            return true;
        }

        fn refreshFxLoginCredentialIfNeeded(app: *App) !void {
            if (!try app.auth.refreshFxLoginIfNeeded(app.alloc)) return;
            reconcileGatewayCredential(app);
            if (app.auth.modelCatalogAccess().authorizationCredential() == null) return;
            app.model_cache.reset();
            if (comptime @hasDecl(App, "startModelCacheWarmup")) {
                app.startModelCacheWarmup();
            }
        }

        pub fn admitPromptCredential(app: *App) !bool {
            if (comptime !oauthAuthEnabled(App)) {
                if (app.auth.apiKey() != null) return true;
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Missing FX_API_KEY. Supply it through createFxTerminal().",
                }, true);
                return false;
            }
            if (!try ensurePromptCredential(app)) return false;
            return preparePromptCredential(app);
        }

        fn preparePromptCredential(app: *App) !bool {
            for (0..2) |_| {
                refreshFxLoginCredentialIfNeeded(app) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return recoverPromptCredentialRefreshFailure(app, err),
                };
                if (app.auth.gatewayCredential() != null) return true;
            }
            return recoverPromptCredentialRefreshFailure(app, error.CredentialRefreshUnavailable);
        }

        fn recoverPromptCredentialRefreshFailure(app: *App, err: anyerror) !bool {
            debug_trace.logf("auth", "prompt credential refresh failed source=fx_login err={s}", .{@errorName(err)});
            app.auth.recordCredentialRefreshFailure(.fx_login);
            try app.auth.refreshSourceInventory(app.alloc);
            app.auth.openPicker(app.alloc);
            const failure = auth_runtime.FailureSnapshot{
                .source = .fx_login,
                .reason = .credential_refresh_failed,
            };
            const failure_text = try failure.renderText(app.alloc);
            defer app.alloc.free(failure_text);
            const recovery = try std.fmt.allocPrint(
                app.alloc,
                "{s}.\nChoose another source below.",
                .{failure_text},
            );
            defer app.alloc.free(recovery);
            try app.writeDomainNotice(.{
                .topic = "auth",
                .tone = .@"error",
                .body = recovery,
            }, true);
            app.shell.render_requests.request(.footer);
            return false;
        }

        fn applyCredentialChange(app: *App, changed: bool) void {
            if (!changed) return;
            reconcileGatewayCredential(app);
            app.model_cache.reset();
            if (comptime @hasDecl(App, "startModelCacheWarmup")) {
                app.startModelCacheWarmup();
            }
        }

        fn reconcileGatewayCredential(app: *App) void {
            if (comptime !runtime_profile.allows(App, .generation_usage)) return;
            if (comptime @hasField(App, "session") and
                @hasField(@TypeOf(app.session), "usage"))
            {
                if (app.auth.gatewayCredential()) |credential| {
                    app.session.usage.replaceReconciliationCredential(
                        app.alloc,
                        credential.api_key,
                    );
                } else {
                    app.session.usage.clearReconciliationCredential();
                }
            }
        }

        fn writeLoginError(app: *App, err: anyerror) !void {
            const notice: types.SemanticNotice = switch (err) {
                error.ClientIdMissing => .{ .topic = "auth", .tone = .@"error", .body = "fx login is not configured yet. The current credential is unchanged." },
                error.AccessDenied => .{ .topic = "auth", .tone = .@"error", .body = "Vercel sign-in was denied. The current credential is unchanged." },
                error.ExpiredToken, error.LoginTimedOut => .{ .topic = "auth", .tone = .warning, .body = "The Vercel sign-in code expired. The current credential is unchanged; run /login to try again." },
                else => .{ .topic = "auth", .tone = .@"error", .body = "Vercel sign-in failed. The current credential is unchanged." },
            };
            try writeAuthNotice(app, notice);
        }

        fn writeAuthNotice(app: *App, notice: types.SemanticNotice) !void {
            try app.writeDomainNotice(notice, true);
            app.shell.render_requests.request(.first_frame);
            try app.flushBeforeBlockingExternalWork();
        }
    };
}

const TestModelCache = struct {
    reset_count: usize = 0,

    fn reset(self: *TestModelCache) void {
        self.reset_count += 1;
    }
};

const TestTeam = struct {
    name: []const u8,
    slug: []const u8,
};

const test_teams = [_]TestTeam{.{
    .name = "Vercel Labs",
    .slug = "vercel-labs",
}};

const TestSelectedTeam = struct {
    fn deinit(_: *TestSelectedTeam, _: std.mem.Allocator) void {}
};

const TestTeamSelection = struct {
    teams: struct {
        items: []const TestTeam = &test_teams,
    } = .{},
    select_count: usize = 0,

    fn select(
        self: *TestTeamSelection,
        _: std.mem.Allocator,
        index: usize,
    ) error{ InvalidTeamSelection, SessionChanged, NoSession }!TestSelectedTeam {
        if (index >= self.teams.items.len) return error.InvalidTeamSelection;
        self.select_count += 1;
        return .{};
    }
};

const TestAuth = struct {
    select_result: ?bool = false,
    sign_in_transition: login_flow.SignInTransition = .none,
    logout_changed: bool = false,
    refresh_changed: bool = false,
    refresh_error: ?anyerror = null,
    selected_source: ?credentials.Source = null,
    active_source: ?credentials.Source = .ai_gateway_api_key,
    refresh_count: usize = 0,
    logout_reconcile_count: usize = 0,
    source_inventory_refresh_count: usize = 0,
    refresh_failure_source: ?credentials.Source = null,
    picker_opened: bool = false,
    picker_closed: bool = false,
    gateway_ready: bool = true,
    catalog_ready: bool = true,
    gateway_ready_after_refresh_count: ?usize = null,
    team_selection: TestTeamSelection = .{},
    selected_team_adopted: bool = false,
    sign_in_url: ?[]const u8 = null,
    picker_pop_count: usize = 0,

    fn credentialSource(self: *const TestAuth) ?credentials.Source {
        return self.active_source;
    }

    fn selectSource(self: *TestAuth, _: std.mem.Allocator, source: credentials.Source) !?bool {
        self.selected_source = source;
        if (self.select_result != null) self.active_source = source;
        return self.select_result;
    }

    fn pollSignInTransition(self: *TestAuth, _: std.mem.Allocator) login_flow.SignInTransition {
        const transition = self.sign_in_transition;
        self.sign_in_transition = .none;
        return transition;
    }

    fn pulseSignIn(_: *TestAuth, _: std.mem.Allocator) void {}

    fn popPickerStage(self: *TestAuth, _: std.mem.Allocator) bool {
        self.picker_pop_count += 1;
        return true;
    }

    fn openTeamPicker(_: *TestAuth, _: std.mem.Allocator, _: *login_flow.TeamSelection) void {}

    fn refreshFxLoginIfNeeded(self: *TestAuth, _: std.mem.Allocator) !bool {
        self.refresh_count += 1;
        if (self.refresh_error) |err| return err;
        if (self.gateway_ready_after_refresh_count == self.refresh_count) self.gateway_ready = true;
        return self.refresh_changed;
    }

    fn gatewayCredential(self: *const TestAuth) ?TestGatewayCredential {
        return if (self.gateway_ready) .{ .api_key = "refreshed-key" } else null;
    }

    fn modelCatalogAccess(self: *const TestAuth) credentials.CatalogAccess {
        return if (self.catalog_ready)
            credentials.catalogAccessForCredential(.fx_login, "refreshed-key", "team_123")
        else
            .{ .public_only = .fx_login_team_required };
    }

    fn reconcileAfterFxLoginLogout(self: *TestAuth, _: std.mem.Allocator) !bool {
        self.logout_reconcile_count += 1;
        return self.logout_changed;
    }

    fn refreshSourceInventory(self: *TestAuth, _: std.mem.Allocator) !void {
        self.source_inventory_refresh_count += 1;
    }

    fn recordCredentialRefreshFailure(self: *TestAuth, source: credentials.Source) void {
        self.refresh_failure_source = source;
    }

    fn openPicker(self: *TestAuth, _: std.mem.Allocator) void {
        self.picker_opened = true;
    }

    fn teamSelection(self: *TestAuth) ?*TestTeamSelection {
        return &self.team_selection;
    }

    fn adoptSelectedTeam(self: *TestAuth, _: std.mem.Allocator, _: *TestSelectedTeam) bool {
        self.selected_team_adopted = true;
        return true;
    }

    fn closePicker(self: *TestAuth, _: std.mem.Allocator) void {
        self.picker_closed = true;
    }

    fn signInBrowserUrlAlloc(self: *TestAuth, alloc: std.mem.Allocator) !?[]u8 {
        const url = self.sign_in_url orelse return null;
        return try alloc.dupe(u8, url);
    }
};

const TestGatewayCredential = struct {
    api_key: []const u8,
};

const TestUsage = struct {
    refresh_count: usize = 0,
    clear_count: usize = 0,
    last_key: ?[]const u8 = null,

    fn replaceReconciliationCredential(
        self: *TestUsage,
        _: std.mem.Allocator,
        api_key: []const u8,
    ) void {
        self.refresh_count += 1;
        self.last_key = api_key;
    }

    fn clearReconciliationCredential(self: *TestUsage) void {
        self.clear_count += 1;
        self.last_key = null;
    }
};

const TestRenderRequests = struct {
    footer_requested: bool = false,

    fn request(self: *TestRenderRequests, _: anytype) void {
        self.footer_requested = true;
    }
};

const TestUrlOpener = struct {
    calls: usize = 0,
    succeeds: bool = true,
    error_on_open: bool = false,
    opened_url: [256]u8 = undefined,
    opened_url_len: usize = 0,

    fn opener(self: *TestUrlOpener) host.UrlOpener {
        return .{
            .context = self,
            .open_fn = open,
        };
    }

    fn open(
        raw_context: ?*anyopaque,
        _: std.mem.Allocator,
        url: []const u8,
    ) host.UrlOpenError!bool {
        const self: *TestUrlOpener = @ptrCast(@alignCast(raw_context.?));
        self.calls += 1;
        if (url.len > self.opened_url.len) return error.OutOfMemory;
        @memcpy(self.opened_url[0..url.len], url);
        self.opened_url_len = url.len;
        if (self.error_on_open) return error.OutOfMemory;
        return self.succeeds;
    }

    fn openedUrl(self: *const TestUrlOpener) []const u8 {
        return self.opened_url[0..self.opened_url_len];
    }
};

const TestApp = struct {
    alloc: std.mem.Allocator = std.testing.allocator,
    auth: TestAuth = .{},
    model_cache: TestModelCache = .{},
    session: struct {
        usage: TestUsage = .{},
    } = .{},
    model_cache_warmup_count: usize = 0,
    notice_write_count: usize = 0,
    transcript: std.ArrayList(u8) = .empty,
    test_url_opener: TestUrlOpener = .{},
    preference_write_count: usize = 0,
    last_preference_source: ?credentials.Source = null,
    preference_write_succeeds: bool = true,
    shell: struct {
        render_requests: TestRenderRequests = .{},
    } = .{},

    fn deinit(self: *TestApp) void {
        self.transcript.deinit(self.alloc);
    }

    fn startModelCacheWarmup(self: *TestApp) void {
        self.model_cache_warmup_count += 1;
    }

    fn writeTranscriptClassified(self: *TestApp, text: []const u8, _: bool, _: anytype) !void {
        try self.transcript.appendSlice(self.alloc, text);
    }

    fn writeDomainNotice(self: *TestApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_write_count += 1;
        try self.transcript.appendSlice(self.alloc, notice.body);
        try self.transcript.append(self.alloc, '\n');
    }

    fn flushBeforeBlockingExternalWork(_: *TestApp) !void {}

    fn urlOpener(self: *TestApp) host.UrlOpener {
        return self.test_url_opener.opener();
    }

    fn persistCredentialSourcePreference(self: *TestApp, source: credentials.Source) void {
        self.preference_write_count += 1;
        if (self.preference_write_succeeds) self.last_preference_source = source;
    }
};

test "OAuth app gating accepts native auth or JS-host auth and rejects neither" {
    const NativeApp = struct {
        pub const host_profile = runtime_profile.native;
    };
    const JsHostApp = struct {
        pub const host_profile = runtime_profile.wasm;
    };
    const NeitherApp = struct {
        pub const host_profile = blk: {
            var profile = runtime_profile.wasm;
            profile.js_host_auth = false;
            break :blk profile;
        };
    };

    try std.testing.expect(oauthAuthEnabled(NativeApp));
    try std.testing.expect(oauthAuthEnabled(JsHostApp));
    try std.testing.expect(!oauthAuthEnabled(NeitherApp));
}

test "interactive sign-in opens the owned browser URL through the host" {
    var app: TestApp = .{};
    app.auth.sign_in_url = "https://vercel.test/verify?code=TEST-CODE";

    try Runtime(TestApp).openSignInBrowser(&app);

    try std.testing.expectEqual(@as(usize, 1), app.test_url_opener.calls);
    try std.testing.expectEqualStrings(
        "https://vercel.test/verify?code=TEST-CODE",
        app.test_url_opener.openedUrl(),
    );
}

test "interactive sign-in preserves manual fallback when the host launcher fails" {
    var app: TestApp = .{};
    app.auth.sign_in_url = "https://vercel.test/verify";
    app.test_url_opener.succeeds = false;

    try Runtime(TestApp).openSignInBrowser(&app);

    try std.testing.expectEqual(@as(usize, 1), app.test_url_opener.calls);
    try std.testing.expectEqualStrings(
        "https://vercel.test/verify",
        app.test_url_opener.openedUrl(),
    );
    try std.testing.expectEqualStrings("https://vercel.test/verify", app.auth.sign_in_url.?);
}

test "interactive sign-in frees its browser URL when the host opener errors" {
    var app: TestApp = .{};
    app.auth.sign_in_url = "https://vercel.test/verify";
    app.test_url_opener.error_on_open = true;

    try std.testing.expectError(
        error.OutOfMemory,
        Runtime(TestApp).openSignInBrowser(&app),
    );
    try std.testing.expectEqual(@as(usize, 1), app.test_url_opener.calls);
}

test "auth source changes invalidate the catalog and failed selection preserves it" {
    var app: TestApp = .{};
    const runtime = Runtime(TestApp);

    app.auth.select_result = true;
    try std.testing.expect(try runtime.selectCredentialSource(&app, .fx_login));
    try std.testing.expectEqual(credentials.Source.fx_login, app.auth.selected_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache.reset_count);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache_warmup_count);

    try std.testing.expect(try runtime.selectCredentialSource(&app, .stored_key));
    try std.testing.expectEqual(credentials.Source.stored_key, app.auth.selected_source.?);
    try std.testing.expectEqual(@as(usize, 2), app.model_cache.reset_count);
    try std.testing.expectEqual(@as(usize, 2), app.model_cache_warmup_count);
    try std.testing.expectEqual(@as(usize, 2), app.session.usage.refresh_count);
    try std.testing.expectEqualStrings(
        "refreshed-key",
        app.session.usage.last_key.?,
    );

    app.auth.select_result = null;
    try std.testing.expect(!try runtime.selectCredentialSource(&app, .ai_gateway_api_key));
    try std.testing.expectEqual(credentials.Source.stored_key, app.auth.active_source.?);
    try std.testing.expectEqual(@as(usize, 2), app.model_cache.reset_count);
    try std.testing.expectEqual(@as(usize, 2), app.model_cache_warmup_count);
}

test "VT-4 unavailable picker source preserves active source and reports unavailability" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.select_result = null;

    try Runtime(TestApp).applySourceChoice(&app, .stored_key);

    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, app.auth.active_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    try std.testing.expectEqualStrings(
        "That credential is no longer available. The current source is unchanged.\n",
        app.transcript.items,
    );
}

test "completed credential switch emits exactly one transcript line" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.select_result = true;

    try Runtime(TestApp).applySourceChoice(&app, .stored_key);

    try std.testing.expectEqual(credentials.Source.stored_key, app.auth.active_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.preference_write_count);
    try std.testing.expectEqual(credentials.Source.stored_key, app.last_preference_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    const expected = try std.fmt.allocPrint(
        app.alloc,
        "Switched credential to {s}.\n",
        .{credentials.sourceLabel(.stored_key)},
    );
    defer app.alloc.free(expected);
    try std.testing.expectEqualStrings(expected, app.transcript.items);
}

test "team change from an environment source activates and remembers fx login" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.select_result = true;

    try Runtime(TestApp).applyTeamChoice(&app, 0);

    try std.testing.expectEqual(@as(usize, 1), app.auth.team_selection.select_count);
    try std.testing.expect(!app.auth.selected_team_adopted);
    try std.testing.expectEqual(credentials.Source.fx_login, app.auth.active_source.?);
    try std.testing.expectEqual(credentials.Source.fx_login, app.auth.selected_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.preference_write_count);
    try std.testing.expectEqual(credentials.Source.fx_login, app.last_preference_source.?);
    try std.testing.expect(app.auth.picker_closed);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache.reset_count);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache_warmup_count);
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
    try std.testing.expectEqualStrings(
        "Changed Vercel team to Vercel Labs (vercel-labs).\n",
        app.transcript.items,
    );
}

test "team change on an active fx login updates and remembers the selected team" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.active_source = .fx_login;

    try Runtime(TestApp).applyTeamChoice(&app, 0);

    try std.testing.expect(app.auth.selected_team_adopted);
    try std.testing.expectEqual(@as(usize, 1), app.preference_write_count);
    try std.testing.expectEqual(credentials.Source.fx_login, app.last_preference_source.?);
}

test "successful direct login remembers fx login after activation" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.select_result = true;
    app.auth.sign_in_transition = .{ .succeeded = .{} };

    try Runtime(TestApp).collectSignInFacts(&app);

    try std.testing.expectEqual(credentials.Source.fx_login, app.auth.active_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.preference_write_count);
    try std.testing.expectEqual(credentials.Source.fx_login, app.last_preference_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.notice_write_count);
}

test "direct login source load failure leaves the environment preference unchanged" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.select_result = null;
    app.auth.sign_in_transition = .{ .succeeded = .{} };

    try Runtime(TestApp).collectSignInFacts(&app);

    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, app.auth.active_source.?);
    try std.testing.expectEqual(@as(usize, 0), app.preference_write_count);
    try std.testing.expectEqual(@as(usize, 1), app.auth.picker_pop_count);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "could not be loaded") != null);
}

test "failed preference persistence keeps a successful direct login active" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.select_result = true;
    app.auth.sign_in_transition = .{ .succeeded = .{} };
    app.preference_write_succeeds = false;

    try Runtime(TestApp).collectSignInFacts(&app);

    try std.testing.expectEqual(credentials.Source.fx_login, app.auth.active_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.preference_write_count);
    try std.testing.expectEqual(@as(?credentials.Source, null), app.last_preference_source);
}

test "successful API key save persists even when the live credential is unchanged" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.active_source = .stored_key;

    try Runtime(TestApp).applyApiKeySaveResult(&app, .{ .saved = false });

    try std.testing.expectEqual(credentials.Source.stored_key, app.auth.active_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.preference_write_count);
    try std.testing.expectEqual(credentials.Source.stored_key, app.last_preference_source.?);
}

test "successful API key save remembers the newly active stored key" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.active_source = .stored_key;

    try Runtime(TestApp).applyApiKeySaveResult(&app, .{ .saved = true });

    try std.testing.expectEqual(credentials.Source.stored_key, app.auth.active_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.preference_write_count);
    try std.testing.expectEqual(credentials.Source.stored_key, app.last_preference_source.?);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache.reset_count);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache_warmup_count);
}

test "cancelled login and rejected API key do not persist a source" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.sign_in_transition = .cancelled;

    try Runtime(TestApp).collectSignInFacts(&app);
    try Runtime(TestApp).applyApiKeySaveResult(&app, .gateway_refused);

    try std.testing.expectEqual(@as(usize, 0), app.preference_write_count);
    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, app.auth.active_source.?);
}

test "team source load failure preserves the environment source and preference" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.select_result = null;

    try Runtime(TestApp).applyTeamChoice(&app, 0);

    try std.testing.expectEqual(credentials.Source.ai_gateway_api_key, app.auth.active_source.?);
    try std.testing.expectEqual(@as(usize, 0), app.preference_write_count);
    try std.testing.expect(app.auth.picker_closed);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "could not be loaded") != null);
}

test "prompt credential refresh reloads the catalog after the credential changes" {
    var app: TestApp = .{};
    defer app.deinit();
    const runtime = Runtime(TestApp);

    try runtime.refreshFxLoginCredentialIfNeeded(&app);
    try std.testing.expectEqual(@as(usize, 1), app.auth.refresh_count);
    try std.testing.expectEqual(@as(usize, 0), app.model_cache.reset_count);

    app.auth.refresh_changed = true;
    try runtime.refreshFxLoginCredentialIfNeeded(&app);
    try std.testing.expectEqual(@as(usize, 2), app.auth.refresh_count);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache.reset_count);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache_warmup_count);
    try std.testing.expectEqual(@as(usize, 1), app.session.usage.refresh_count);
}

test "credential removal clears the reconciliation credential" {
    var app: TestApp = .{};
    app.auth.gateway_ready = false;

    Runtime(TestApp).applyCredentialChange(&app, true);

    try std.testing.expectEqual(@as(usize, 1), app.session.usage.clear_count);
    try std.testing.expectEqual(@as(usize, 0), app.session.usage.refresh_count);
}

test "logout result reconciles live auth and renders only sanitized notices" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.logout_changed = true;

    try Runtime(TestApp).applyLogoutResult(&app, .{
        .session_deleted = true,
        .remote_revocation_failed = true,
    });

    try std.testing.expectEqual(@as(usize, 1), app.auth.logout_reconcile_count);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache.reset_count);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache_warmup_count);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Signed out of fx.") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, login_flow.remote_revocation_warning) != null);
    for ([_][]const u8{ "access-secret", "refresh-secret", "RemoteRevokeFailed", "https://issuer.example" }) |detail| {
        try std.testing.expect(std.mem.find(u8, app.transcript.items, detail) == null);
    }
}

test "logout durability failure still reconciles live auth" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.logout_changed = true;

    try Runtime(TestApp).applyLogoutResult(&app, .{
        .session_deleted = true,
        .local_durability_failed = true,
        .remote_revocation_failed = true,
    });

    try std.testing.expectEqual(@as(usize, 1), app.auth.logout_reconcile_count);
    try std.testing.expectEqual(@as(usize, 1), app.model_cache.reset_count);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Could not confirm durable fx logout.") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, login_flow.remote_revocation_warning) != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "current source is unchanged") == null);
}

test "prompt credential refresh failure is recoverable and detail-free" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.refresh_error = error.OAuthRequestFailed;

    try std.testing.expect(!try Runtime(TestApp).preparePromptCredential(&app));
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "fx login credential refresh failed.") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "Choose another source below.") != null);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "OAuthRequestFailed") == null);
    try std.testing.expect(app.shell.render_requests.footer_requested);
    try std.testing.expectEqual(@as(usize, 1), app.auth.source_inventory_refresh_count);
    try std.testing.expectEqual(credentials.Source.fx_login, app.auth.refresh_failure_source.?);
    try std.testing.expect(app.auth.picker_opened);
    try std.testing.expectEqual(@as(usize, 0), app.model_cache.reset_count);
}

test "prompt credential admission retries a crossed readiness deadline" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.gateway_ready = false;
    app.auth.gateway_ready_after_refresh_count = 2;

    try std.testing.expect(try Runtime(TestApp).preparePromptCredential(&app));
    try std.testing.expectEqual(@as(usize, 2), app.auth.refresh_count);
    try std.testing.expectEqual(@as(usize, 0), app.transcript.items.len);
    try std.testing.expect(!app.auth.picker_opened);
}

test "prompt credential admission rejects a credential that remains unavailable" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.gateway_ready = false;

    try std.testing.expect(!try Runtime(TestApp).preparePromptCredential(&app));
    try std.testing.expectEqual(@as(usize, 2), app.auth.refresh_count);
    try std.testing.expect(std.mem.find(u8, app.transcript.items, "fx login credential refresh failed.") != null);
    try std.testing.expect(app.auth.picker_opened);
}

test "prompt credential refresh allows only OutOfMemory to escape" {
    var app: TestApp = .{};
    defer app.deinit();
    app.auth.refresh_error = error.OutOfMemory;

    try std.testing.expectError(error.OutOfMemory, Runtime(TestApp).preparePromptCredential(&app));
    try std.testing.expectEqual(@as(usize, 0), app.transcript.items.len);
    try std.testing.expect(!app.shell.render_requests.footer_requested);
    try std.testing.expectEqual(@as(usize, 0), app.auth.source_inventory_refresh_count);
    try std.testing.expect(!app.auth.picker_opened);
}
