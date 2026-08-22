const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const credentials = @import("../auth/credentials.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const login_flow = @import("../auth/login_flow.zig");
const chatgpt_oauth = @import("../auth/chatgpt_oauth.zig");
const claude_oauth = @import("../auth/claude_oauth.zig");
const grok_oauth = @import("../auth/grok_oauth.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const model_provider = @import("../config/model_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_runtime = @import("provider_runtime.zig");
const types = @import("../shared/types.zig");

fn oauthAuthEnabled(comptime App: type) bool {
    return runtime_profile.allows(App, .native_auth) or
        runtime_profile.allows(App, .js_host_auth);
}

const ProviderSwitchDecision = enum {
    no_change,
    busy,
    prepare,
};

const ProviderSwitchIntent = enum {
    manual,
    post_oauth,
};

const ProviderSwitchFacts = struct {
    current: model_provider.ProviderId,
    target: model_provider.ProviderId,
    target_credential_ready: bool,
    intent: ProviderSwitchIntent,
    stream_active: bool,
    queued_prompts: usize,
};

fn decideProviderSwitch(facts: ProviderSwitchFacts) ProviderSwitchDecision {
    if (facts.intent == .manual and facts.current == facts.target and facts.target_credential_ready) return .no_change;
    if (facts.stream_active or facts.queued_prompts > 0) return .busy;
    return .prepare;
}

fn providerFailureMessage(
    intent: ProviderSwitchIntent,
    ordinary: []const u8,
    after_oauth: []const u8,
) []const u8 {
    return if (intent == .post_oauth) after_oauth else ordinary;
}

fn selectCatalogModel(
    entries: []const model_catalog.ModelCatalogEntry,
    primary: ?[]const u8,
    secondary: ?[]const u8,
) ?[]const u8 {
    for ([_]?[]const u8{ primary, secondary }) |maybe_candidate| {
        const candidate = maybe_candidate orelse continue;
        for (entries) |entry| {
            if (std.mem.eql(u8, candidate, entry.id)) return entry.id;
        }
    }
    return if (entries.len > 0) entries[0].id else null;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        fn ensurePromptCredential(app: *App) !bool {
            if (comptime provider_runtime.supported(App) and
                @hasDecl(@TypeOf(app.auth), "selectForProvider"))
            {
                const provider = provider_runtime.provider(app);
                const required_source: credentials.Source = switch (provider) {
                    .codex => .chatgpt_subscription,
                    .grok => .grok_subscription,
                    .claude => .claude_subscription,
                    .gateway => app.auth.credentialSource() orelse .fx_login,
                };
                const route_change = app.auth.selectForProvider(app.alloc, provider) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return recoverCredentialFailure(app, required_source, err),
                };
                if (route_change) |changed| {
                    applyCredentialChange(app, changed);
                } else if (!model_provider.authorizesCredential(provider, app.auth.credentialSource())) {
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .warning,
                        .body = if (provider == .grok)
                            credentials.missing_grok_interactive_credential_message
                        else if (provider == .codex)
                            credentials.missing_chatgpt_interactive_credential_message
                        else
                            credentials.missing_interactive_credential_message,
                    }, true);
                    app.shell.render_requests.request(.footer);
                    return false;
                }
            }
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
            if (comptime host_target.is_wasm) {
                try beginSignIn(app, false);
                return;
            }
            try app.auth.refreshSourceInventory(app.alloc);
            app.auth.openPicker(app.alloc);
            app.shell.render_requests.request(.footer);
        }

        pub fn runLogoutCommand(app: *App, target: []const u8) !void {
            if (comptime !oauthAuthEnabled(App)) {
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .warning,
                    .body = "Authentication is owned by the embedding SDK for this WASM session.",
                }, true);
                return;
            }
            const requested_provider = if (std.mem.trim(u8, target, " \t\r\n").len == 0)
                null
            else
                provider_catalog.parse(std.mem.trim(u8, target, " \t\r\n")) orelse {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .warning,
                        .body = "Usage: /logout [vercel|codex|grok]",
                    });
                    return;
                };
            try app.flushBeforeBlockingExternalWork();
            const selected_model_uses_chatgpt = if (comptime provider_runtime.supported(App))
                provider_runtime.provider(app) == .codex
            else
                false;
            const selected_model_uses_grok = if (comptime provider_runtime.supported(App))
                provider_runtime.provider(app) == .grok
            else
                false;
            const provider_inventory = if (comptime @hasDecl(@TypeOf(app.auth), "pickerView")) inventory: {
                try app.auth.refreshSourceInventory(app.alloc);
                break :inventory app.auth.pickerView().available_sources;
            } else @as(auth_runtime.SourceSet, .empty);
            const chatgpt_is_only_logout_session = provider_inventory.contains(.chatgpt_subscription) and
                !provider_inventory.contains(.fx_login) and
                !provider_inventory.contains(.grok_subscription);
            const grok_is_only_logout_session = provider_inventory.contains(.grok_subscription) and
                !provider_inventory.contains(.fx_login) and
                !provider_inventory.contains(.chatgpt_subscription);
            const claude_is_only_logout_session = provider_inventory.contains(.claude_subscription) and
                !provider_inventory.contains(.fx_login) and
                !provider_inventory.contains(.chatgpt_subscription) and
                !provider_inventory.contains(.grok_subscription);
            const selected_model_uses_claude = if (comptime provider_runtime.supported(App))
                provider_runtime.provider(app) == .claude
            else
                false;
            const logout_claude = if (requested_provider) |provider|
                provider == .claude
            else
                selected_model_uses_claude or
                    app.auth.credentialSource() == .claude_subscription or
                    claude_is_only_logout_session;
            if (logout_claude) {
                const outcome = claude_oauth.logout(app.alloc, app.auth.oauthTransport()) catch {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Could not durably sign out of Claude. The current source is unchanged.",
                    });
                    return;
                };
                const changed = if (comptime @hasDecl(@TypeOf(app.auth), "reconcileAfterClaudeLogout"))
                    try app.auth.reconcileAfterClaudeLogout(app.alloc)
                else
                    false;
                applyCredentialChange(app, changed);
                try writeAuthNotice(app, switch (outcome.deletion) {
                    .deleted => .{ .topic = "auth", .tone = .neutral, .body = "Signed out of Claude." },
                    .missing => .{ .topic = "auth", .tone = .neutral, .body = "No Claude login session found." },
                    .deleted_not_durable => .{ .topic = "auth", .tone = .warning, .body = "Signed out of Claude, but could not confirm the profile directory update." },
                });
                if (outcome.revocation_failed) {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .warning,
                        .body = "The local Claude session was removed, but remote revocation could not be confirmed.",
                    });
                }
                return;
            }
            const logout_grok = if (requested_provider) |provider|
                provider == .grok
            else
                selected_model_uses_grok or
                    app.auth.credentialSource() == .grok_subscription or
                    grok_is_only_logout_session;
            if (logout_grok) {
                const outcome = grok_oauth.logout(app.alloc, app.auth.oauthTransport()) catch {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Could not durably sign out of Grok. The current source is unchanged.",
                    });
                    return;
                };
                const changed = if (comptime @hasDecl(@TypeOf(app.auth), "reconcileAfterGrokLogout"))
                    try app.auth.reconcileAfterGrokLogout(app.alloc)
                else
                    false;
                applyCredentialChange(app, changed);
                try writeAuthNotice(app, switch (outcome.deletion) {
                    .deleted => .{ .topic = "auth", .tone = .neutral, .body = "Signed out of Grok." },
                    .missing => .{ .topic = "auth", .tone = .neutral, .body = "No Grok login session found." },
                    .deleted_not_durable => .{ .topic = "auth", .tone = .warning, .body = "Signed out of Grok, but could not confirm the profile directory update." },
                });
                if (outcome.revocation_failed) {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .warning,
                        .body = "The local Grok session was removed, but remote revocation could not be confirmed.",
                    });
                }
                return;
            }
            const logout_chatgpt = if (requested_provider) |provider|
                provider == .codex
            else
                selected_model_uses_chatgpt or
                    app.auth.credentialSource() == .chatgpt_subscription or
                    chatgpt_is_only_logout_session;
            if (logout_chatgpt) {
                const outcome = chatgpt_oauth.logout() catch {
                    try writeAuthNotice(app, .{
                        .topic = "auth",
                        .tone = .@"error",
                        .body = "Could not durably sign out of Codex. The current source is unchanged.",
                    });
                    return;
                };
                const changed = if (comptime @hasDecl(@TypeOf(app.auth), "reconcileAfterChatGptLogout"))
                    try app.auth.reconcileAfterChatGptLogout(app.alloc)
                else
                    false;
                applyCredentialChange(app, changed);
                try writeAuthNotice(app, switch (outcome) {
                    .deleted => .{ .topic = "auth", .tone = .neutral, .body = "Signed out of Codex." },
                    .missing => .{ .topic = "auth", .tone = .neutral, .body = "No Codex login session found." },
                    .deleted_not_durable => .{ .topic = "auth", .tone = .warning, .body = "Signed out of Codex, but could not confirm the profile directory update." },
                });
                return;
            }
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
                .provider => |provider| try switchProvider(app, provider, true, .manual),
                .source => |source| try applySourceChoice(app, source),
                .action => |action| switch (action) {
                    .login => try beginSignIn(app, true),
                    .chatgpt_login => try beginChatGptSignIn(app),
                    .grok_login => try beginGrokSignIn(app),
                    .claude_login => try beginClaudeSignIn(app),
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
                    .switch_provider => app.auth.openProviderPicker(app.alloc, provider_runtime.provider(app)),
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
            const sign_in_source: credentials.Source = if (comptime @hasDecl(@TypeOf(app.auth), "pickerView"))
                app.auth.pickerView().sign_in_source
            else
                .fx_login;
            app.auth.pulseSignIn(app.alloc);
            switch (app.auth.pollSignInTransition(app.alloc)) {
                .none => {},
                .cancelled => app.shell.render_requests.request(.footer),
                .failed => |err| {
                    debug_trace.logf("auth", "login failed source={t} err={s}", .{ sign_in_source, @errorName(err) });
                    _ = app.auth.popPickerStage(app.alloc);
                    try writeLoginError(app, sign_in_source, err);
                },
                .succeeded => |completed| {
                    var owned = completed;
                    defer owned.deinit(app.alloc);
                    switch (owned) {
                        .vercel => |*selection| {
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
                                app.auth.openTeamPicker(app.alloc, selection);
                            } else {
                                app.auth.closePicker(app.alloc);
                            }
                            try writeAuthNotice(app, .{
                                .topic = "auth",
                                .tone = .neutral,
                                .body = "Signed in to Vercel.",
                            });
                        },
                        .chatgpt => {
                            try app.auth.refreshSourceInventory(app.alloc);
                            if (comptime provider_runtime.supported(App)) {
                                app.auth.closePicker(app.alloc);
                                try switchProvider(app, .codex, false, .post_oauth);
                                return;
                            }
                            if (!try selectCredentialSource(app, .chatgpt_subscription)) {
                                _ = app.auth.popPickerStage(app.alloc);
                                try writeAuthNotice(app, .{
                                    .topic = "auth",
                                    .tone = .@"error",
                                    .body = "Signed in, but the Codex subscription credential could not be loaded.",
                                });
                                return;
                            }
                            app.auth.closePicker(app.alloc);
                            try writeAuthNotice(app, .{
                                .topic = "auth",
                                .tone = .neutral,
                                .body = "Signed in with Codex.",
                            });
                        },
                        .grok => {
                            try app.auth.refreshSourceInventory(app.alloc);
                            if (comptime provider_runtime.supported(App)) {
                                app.auth.closePicker(app.alloc);
                                try switchProvider(app, .grok, false, .post_oauth);
                                return;
                            }
                            const selected_model_uses_grok = if (comptime provider_runtime.supported(App))
                                provider_runtime.provider(app) == .grok
                            else
                                false;
                            if (selected_model_uses_grok and
                                !try selectCredentialSource(app, .grok_subscription))
                            {
                                _ = app.auth.popPickerStage(app.alloc);
                                try writeAuthNotice(app, .{
                                    .topic = "auth",
                                    .tone = .@"error",
                                    .body = "Signed in, but the Grok subscription credential could not be loaded.",
                                });
                                return;
                            }
                            if (!selected_model_uses_grok) {
                                app.model_cache.reset();
                                if (comptime @hasDecl(App, "startModelCacheWarmup")) app.startModelCacheWarmup();
                            }
                            app.auth.closePicker(app.alloc);
                            try writeAuthNotice(app, .{
                                .topic = "auth",
                                .tone = .neutral,
                                .body = "Signed in with Grok.",
                            });
                        },
                        .claude => {
                            try app.auth.refreshSourceInventory(app.alloc);
                            if (comptime provider_runtime.supported(App)) {
                                app.auth.closePicker(app.alloc);
                                try switchProvider(app, .claude, false, .post_oauth);
                                return;
                            }
                            const selected_model_uses_claude = if (comptime provider_runtime.supported(App))
                                provider_runtime.provider(app) == .claude
                            else
                                false;
                            if (selected_model_uses_claude and
                                !try selectCredentialSource(app, .claude_subscription))
                            {
                                _ = app.auth.popPickerStage(app.alloc);
                                try writeAuthNotice(app, .{
                                    .topic = "auth",
                                    .tone = .@"error",
                                    .body = "Signed in, but the Claude subscription credential could not be loaded.",
                                });
                                return;
                            }
                            if (!selected_model_uses_claude) {
                                app.model_cache.reset();
                                if (comptime @hasDecl(App, "startModelCacheWarmup")) app.startModelCacheWarmup();
                            }
                            app.auth.closePicker(app.alloc);
                            try writeAuthNotice(app, .{
                                .topic = "auth",
                                .tone = .neutral,
                                .body = "Signed in with Claude.",
                            });
                        },
                    }
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
            // ChatGPT is selected by model route, not as a global Gateway
            // credential preference. Its saved session coexists independently.
            if (source == .chatgpt_subscription or source == .grok_subscription) return;
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

        fn beginChatGptSignIn(app: *App) !void {
            if (comptime provider_runtime.supported(App)) {
                const decision = decideProviderSwitch(.{
                    .current = provider_runtime.provider(app),
                    .target = .codex,
                    .target_credential_ready = false,
                    .intent = .post_oauth,
                    .stream_active = app.stream.active,
                    .queued_prompts = app.worker.queuedPromptCount(),
                });
                if (decision == .busy) {
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .warning,
                        .body = "Codex sign-in is unavailable until active and queued work finishes.",
                    }, true);
                    return;
                }
            }
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openChatGptSignInPickerFromRoot(app.alloc);
            if (started catch |err| {
                debug_trace.logf("auth", "ChatGPT login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .chatgpt_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn beginGrokSignIn(app: *App) !void {
            if (comptime provider_runtime.supported(App)) {
                const decision = decideProviderSwitch(.{
                    .current = provider_runtime.provider(app),
                    .target = .grok,
                    .target_credential_ready = false,
                    .intent = .post_oauth,
                    .stream_active = app.stream.active,
                    .queued_prompts = app.worker.queuedPromptCount(),
                });
                if (decision == .busy) {
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .warning,
                        .body = "Grok sign-in is unavailable until active and queued work finishes.",
                    }, true);
                    return;
                }
            }
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openGrokSignInPickerFromRoot(app.alloc);
            if (started catch |err| {
                debug_trace.logf("auth", "Grok login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .grok_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn beginCodexSignInForProviderSwitch(app: *App) !void {
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openChatGptSignInPickerForProviderSwitch(app.alloc);
            if (started catch |err| {
                debug_trace.logf("auth", "Codex login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .chatgpt_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn beginGrokSignInForProviderSwitch(app: *App) !void {
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openGrokSignInPickerForProviderSwitch(app.alloc);
            if (started catch |err| {
                debug_trace.logf("auth", "Grok login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .grok_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn beginClaudeSignIn(app: *App) !void {
            if (try credentials.sourceExists(app.alloc, app.auth.secretStore(), .claude_subscription)) {
                try switchProvider(app, .claude, false, .manual);
                return;
            }
            if (comptime provider_runtime.supported(App)) {
                const decision = decideProviderSwitch(.{
                    .current = provider_runtime.provider(app),
                    .target = .claude,
                    .target_credential_ready = false,
                    .intent = .post_oauth,
                    .stream_active = app.stream.active,
                    .queued_prompts = app.worker.queuedPromptCount(),
                });
                if (decision == .busy) {
                    try app.writeDomainNotice(.{
                        .topic = "auth",
                        .tone = .warning,
                        .body = "Claude sign-in is unavailable until active and queued work finishes.",
                    }, true);
                    return;
                }
            }
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openClaudeSignInPickerFromRoot(app.alloc);
            if (started catch |err| {
                debug_trace.logf("auth", "Claude login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .claude_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn beginClaudeSignInForProviderSwitch(app: *App) !void {
            try app.flushBeforeBlockingExternalWork();
            const started = app.auth.openClaudeSignInPickerForProviderSwitch(app.alloc);
            if (started catch |err| {
                debug_trace.logf("auth", "Claude login failed err={s}", .{@errorName(err)});
                try writeLoginError(app, .claude_subscription, err);
                return;
            }) {
                app.shell.render_requests.request(.footer);
                if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) try openSignInBrowser(app);
            }
        }

        fn switchProvider(
            app: *App,
            target: model_provider.ProviderId,
            allow_login: bool,
            intent: ProviderSwitchIntent,
        ) !void {
            if (comptime !provider_runtime.supported(App) or
                !@hasDecl(App, "fetchProviderCatalog") or
                !@hasDecl(@TypeOf(app.model_cache), "adoptOwnedCatalog"))
            {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .warning,
                    .body = "Provider switching is unavailable in this host.",
                }, true);
                return;
            }
            if (comptime host_target.is_wasm) {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .warning,
                    .body = "Subscription provider switching is unavailable in this WASM session.",
                }, true);
                return;
            }

            const current = provider_runtime.provider(app);
            const active_source = app.auth.credentialSource();
            const target_credential_ready = if (active_source) |source|
                model_provider.authorizesCredential(target, source)
            else
                false;
            switch (decideProviderSwitch(.{
                .current = current,
                .target = target,
                .target_credential_ready = target_credential_ready,
                .intent = intent,
                .stream_active = app.stream.active,
                .queued_prompts = app.worker.queuedPromptCount(),
            })) {
                .prepare => {},
                .no_change => {
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Already using {s}.",
                        .{model_provider.label(target)},
                    );
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{ .topic = "provider", .tone = .neutral, .body = body }, true);
                    return;
                },
                .busy => {
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .warning,
                        .body = providerFailureMessage(
                            intent,
                            "Provider switching is unavailable until active and queued work finishes.",
                            "Subscription sign-in completed, but provider activation is unavailable until active and queued work finishes. The current provider is unchanged.",
                        ),
                    }, true);
                    return;
                },
            }
            try app.flushBeforeBlockingExternalWork();

            const resolution = credentials.resolveForProvider(
                app.alloc,
                app.auth.oauthTransport(),
                app.auth.secretStore(),
                .refresh_if_needed,
                target,
                null,
            ) catch |err| {
                debug_trace.logf("provider", "credential preparation failed provider={t} err={s}", .{ target, @errorName(err) });
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = providerFailureMessage(
                        intent,
                        "Could not prepare the target provider credential. The current provider is unchanged.",
                        "Subscription sign-in completed, but its credential could not be prepared. The current provider is unchanged.",
                    ),
                }, true);
                return;
            };
            var credential = resolution.credential orelse {
                if (target == .codex and allow_login) {
                    try beginCodexSignInForProviderSwitch(app);
                    return;
                }
                if (target == .grok and allow_login) {
                    try beginGrokSignInForProviderSwitch(app);
                    return;
                }
                if (target == .claude and allow_login) {
                    try beginClaudeSignInForProviderSwitch(app);
                    return;
                }
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .warning,
                    .body = if (intent == .post_oauth)
                        "Subscription sign-in completed, but its saved credential is unavailable. The current provider is unchanged."
                    else if (target == .codex)
                        "Run fx login codex, then try switching again."
                    else if (target == .grok)
                        "Run fx login grok, then try switching again."
                    else if (target == .claude)
                        "Run claude auth login, then try switching again."
                    else
                        credentials.missing_interactive_credential_message,
                }, true);
                return;
            };
            defer credential.deinit(app.alloc);
            if (!model_provider.authorizesCredential(target, credential.source)) {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = providerFailureMessage(
                        intent,
                        "The target credential cannot authorize that provider. The current provider is unchanged.",
                        "Subscription sign-in completed, but its credential cannot authorize the provider. The current provider is unchanged.",
                    ),
                }, true);
                return;
            }

            const access = credentials.catalogAccessForCredentialAndAccount(
                credential.source,
                credential.token,
                credential.gatewayTeam(),
                credential.accountId(),
            );
            const fetched = app.fetchProviderCatalog(target, access) catch |err| {
                debug_trace.logf("provider", "catalog preparation failed provider={t} err={s}", .{ target, @errorName(err) });
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = providerFailureMessage(
                        intent,
                        "Could not load the target provider catalog. The current provider is unchanged.",
                        "Subscription sign-in completed, but its model catalog could not be loaded. The current provider is unchanged.",
                    ),
                }, true);
                return;
            };
            var catalog = switch (fetched) {
                .catalog => |catalog| catalog,
                .failure => |failure| {
                    debug_trace.logf("provider", "catalog rejected provider={t} category={t}", .{ target, failure.category });
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .@"error",
                        .body = providerFailureMessage(
                            intent,
                            "The target provider catalog could not be validated. The current provider is unchanged.",
                            "Subscription sign-in completed, but its model catalog could not be validated. The current provider is unchanged.",
                        ),
                    }, true);
                    return;
                },
            };
            defer model_catalog.freeModelCatalog(app.alloc, &catalog);
            if (catalog.items.len == 0) {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = providerFailureMessage(
                        intent,
                        "The target provider returned no supported models. The current provider is unchanged.",
                        "Subscription sign-in completed, but its model catalog returned no supported models. The current provider is unchanged.",
                    ),
                }, true);
                return;
            }

            var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch |err| {
                debug_trace.logf("provider", "settings load failed err={s}", .{@errorName(err)});
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .@"error",
                    .body = providerFailureMessage(
                        intent,
                        "Could not load the saved provider model. The current provider is unchanged.",
                        "Subscription sign-in completed, but its saved provider model could not be loaded. The current provider is unchanged.",
                    ),
                }, true);
                return;
            };
            defer settings.deinit(app.alloc);
            const saved_model = switch (target) {
                .gateway => settings.model,
                .codex => settings.codex_model,
                .grok => settings.grok_model,
                .claude => settings.claude_model,
            };
            const current_model = if (intent == .post_oauth and current == target)
                provider_runtime.model(app)
            else
                null;
            const preferred_model = if (intent == .post_oauth)
                saved_model
            else
                io_mod.getenv("FX_MODEL") orelse saved_model;
            const selected_model = selectCatalogModel(catalog.items, current_model, preferred_model) orelse unreachable;
            var owned_model = try app.alloc.dupe(u8, selected_model);
            errdefer app.alloc.free(owned_model);

            if (app.stream.active or app.worker.queuedPromptCount() > 0) {
                try app.writeDomainNotice(.{
                    .topic = "provider",
                    .tone = .warning,
                    .body = providerFailureMessage(
                        intent,
                        "Provider switching is unavailable until active and queued work finishes.",
                        "Subscription sign-in completed, but provider activation is unavailable until active and queued work finishes. The current provider is unchanged.",
                    ),
                }, true);
                return;
            }

            app.model_cache.adoptOwnedCatalog(access, &catalog);
            app.provider_selection.adoptOwned(target, &owned_model);
            _ = app.auth.adoptCredential(app.alloc, &credential);
            reconcileGatewayCredential(app);

            const body = try std.fmt.allocPrint(
                app.alloc,
                "Switched to {s} with {s}.",
                .{ model_provider.label(target), provider_runtime.model(app) },
            );
            defer app.alloc.free(body);
            if (comptime @hasDecl(App, "persistRuntimePreferences")) {
                var persistence = app.persistRuntimePreferences(.{
                    .provider = target,
                    .model = provider_runtime.model(app),
                });
                defer persistence.deinit(app.alloc);
                if (persistence.settings_error != null or persistence.session_error != null) {
                    debug_trace.logf(
                        "provider",
                        "runtime switch persistence failed settings={s} session={s}",
                        .{
                            if (persistence.settings_error) |err| @errorName(err) else "none",
                            if (persistence.session_error) |err| @errorName(err) else "none",
                        },
                    );
                    try app.writeDomainNotice(.{
                        .topic = "provider",
                        .tone = .warning,
                        .body = "Provider switched for this run, but the selection could not be saved.",
                    }, true);
                } else {
                    try app.writeDomainNotice(.{ .topic = "provider", .tone = .neutral, .body = body }, true);
                }
            } else {
                var persistence = config_runtime.attemptUserPreferences(app.alloc, switch (target) {
                    .gateway => .{ .provider = .gateway, .model = provider_runtime.model(app) },
                    .codex => .{ .provider = .codex, .codex_model = provider_runtime.model(app) },
                    .grok => .{ .provider = .grok, .grok_model = provider_runtime.model(app) },
                });
                defer persistence.deinit(app.alloc);
                switch (persistence) {
                    .outcome => try app.writeDomainNotice(.{ .topic = "provider", .tone = .neutral, .body = body }, true),
                    .failure => |failure| {
                        debug_trace.logf("provider", "runtime switch persistence failed err={s}", .{@errorName(failure.err)});
                        try app.writeDomainNotice(.{
                            .topic = "provider",
                            .tone = .warning,
                            .body = "Provider switched for this run, but the selection could not be saved.",
                        }, true);
                    },
                }
            }
            app.shell.render_requests.request(.footer);
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
                try writeLoginError(app, .fx_login, err);
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
            const active_source = app.auth.credentialSource();
            const source = if (active_source) |active|
                if (credentials.sourceRefreshable(active)) active else .fx_login
            else
                .fx_login;
            return recoverCredentialFailure(app, source, err);
        }

        fn recoverCredentialFailure(app: *App, source: credentials.Source, err: anyerror) !bool {
            debug_trace.logf("auth", "prompt credential refresh failed source={t} err={s}", .{ source, @errorName(err) });
            if (app.auth.credentialSource() == source) app.auth.recordCredentialRefreshFailure(source);
            try app.auth.refreshSourceInventory(app.alloc);
            app.auth.openPicker(app.alloc);
            const failure = auth_runtime.FailureSnapshot{
                .source = source,
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
                    const subscription = if (comptime @hasField(@TypeOf(credential), "source"))
                        credential.source == .chatgpt_subscription or credential.source == .grok_subscription
                    else
                        false;
                    if (subscription) {
                        app.session.usage.clearReconciliationCredential();
                    } else {
                        app.session.usage.replaceReconciliationCredential(
                            app.alloc,
                            credential.api_key,
                        );
                    }
                } else {
                    app.session.usage.clearReconciliationCredential();
                }
            }
        }

        fn writeLoginError(app: *App, source: credentials.Source, err: anyerror) !void {
            const notice: types.SemanticNotice = if (source == .chatgpt_subscription)
                switch (err) {
                    error.ChatGptAuthorizationFailed => .{ .topic = "auth", .tone = .@"error", .body = "Codex sign-in was denied. The current credential is unchanged." },
                    error.ChatGptLoginTimedOut, error.LoginTimedOut => .{ .topic = "auth", .tone = .warning, .body = "Codex sign-in expired. The current credential is unchanged; run /login to try again." },
                    else => .{ .topic = "auth", .tone = .@"error", .body = "Codex sign-in failed. The current credential is unchanged." },
                }
            else if (source == .grok_subscription)
                switch (err) {
                    error.GrokAuthorizationFailed => .{ .topic = "auth", .tone = .@"error", .body = "Grok sign-in was denied. The current credential is unchanged." },
                    error.GrokLoginTimedOut, error.LoginTimedOut => .{ .topic = "auth", .tone = .warning, .body = "Grok sign-in expired. The current credential is unchanged; run /login to try again." },
                    else => .{ .topic = "auth", .tone = .@"error", .body = "Grok sign-in failed. The current credential is unchanged." },
                }
            else if (source == .claude_subscription)
                switch (err) {
                    error.ClaudeOAuthRequestFailed => .{ .topic = "auth", .tone = .@"error", .body = "Claude rejected the authorization code. The current credential is unchanged; run /login to try again." },
                    error.ClaudeOAuthStateMismatch => .{ .topic = "auth", .tone = .@"error", .body = "Claude authorization state did not match. The current credential is unchanged; run /login to try again." },
                    error.ClaudeUserInfoRequestFailed => .{ .topic = "auth", .tone = .@"error", .body = "Claude accepted the token but rejected the profile request. The current credential is unchanged." },
                    error.InvalidClaudeUserInfoResponse => .{ .topic = "auth", .tone = .@"error", .body = "Claude accepted the token but returned an unexpected profile. The current credential is unchanged." },
                    error.InvalidClaudeOAuthResponse => .{ .topic = "auth", .tone = .@"error", .body = "Claude returned an unexpected token response. The current credential is unchanged." },
                    error.ClaudeRefreshTokenMissing => .{ .topic = "auth", .tone = .@"error", .body = "Claude did not return a refresh token. The current credential is unchanged." },
                    error.LoginTimedOut => .{ .topic = "auth", .tone = .warning, .body = "Claude sign-in expired. The current credential is unchanged; run /login to try again." },
                    else => .{ .topic = "auth", .tone = .@"error", .body = "Claude sign-in failed. The current credential is unchanged." },
                }
            else switch (err) {
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

test "provider switch state machine no-ops rejects busy work and prepares only idle changes" {
    try std.testing.expectEqual(
        ProviderSwitchDecision.no_change,
        decideProviderSwitch(.{
            .current = .gateway,
            .target = .gateway,
            .target_credential_ready = true,
            .intent = .manual,
            .stream_active = true,
            .queued_prompts = 2,
        }),
    );
    try std.testing.expectEqual(
        ProviderSwitchDecision.prepare,
        decideProviderSwitch(.{
            .current = .codex,
            .target = .codex,
            .target_credential_ready = false,
            .intent = .manual,
            .stream_active = false,
            .queued_prompts = 0,
        }),
    );
    try std.testing.expectEqual(
        ProviderSwitchDecision.busy,
        decideProviderSwitch(.{
            .current = .codex,
            .target = .codex,
            .target_credential_ready = false,
            .intent = .manual,
            .stream_active = true,
            .queued_prompts = 0,
        }),
    );
    try std.testing.expectEqual(
        ProviderSwitchDecision.busy,
        decideProviderSwitch(.{
            .current = .gateway,
            .target = .codex,
            .target_credential_ready = false,
            .intent = .manual,
            .stream_active = false,
            .queued_prompts = 1,
        }),
    );
    try std.testing.expectEqual(
        ProviderSwitchDecision.prepare,
        decideProviderSwitch(.{
            .current = .codex,
            .target = .codex,
            .target_credential_ready = true,
            .intent = .post_oauth,
            .stream_active = false,
            .queued_prompts = 0,
        }),
    );
    try std.testing.expectEqual(
        ProviderSwitchDecision.busy,
        decideProviderSwitch(.{
            .current = .codex,
            .target = .codex,
            .target_credential_ready = true,
            .intent = .post_oauth,
            .stream_active = false,
            .queued_prompts = 1,
        }),
    );
    try std.testing.expectEqual(
        ProviderSwitchDecision.prepare,
        decideProviderSwitch(.{
            .current = .gateway,
            .target = .codex,
            .target_credential_ready = false,
            .intent = .manual,
            .stream_active = false,
            .queued_prompts = 0,
        }),
    );
}

test "post OAuth catalog selection keeps valid current then saved then first" {
    const entries = [_]model_catalog.ModelCatalogEntry{
        .{ .id = @constCast("first"), .model_type = @constCast("language") },
        .{ .id = @constCast("current"), .model_type = @constCast("language") },
        .{ .id = @constCast("saved"), .model_type = @constCast("language") },
    };

    try std.testing.expectEqualStrings("current", selectCatalogModel(&entries, "current", "saved").?);
    try std.testing.expectEqualStrings("saved", selectCatalogModel(&entries, "missing", "saved").?);
    try std.testing.expectEqualStrings("first", selectCatalogModel(&entries, "missing", "also-missing").?);
    try std.testing.expect(selectCatalogModel(&.{}, "current", "saved") == null);
}

const TestModelCache = struct {
    reset_count: usize = 0,

    fn reset(self: *TestModelCache) void {
        self.reset_count += 1;
    }
};

const BusySignInAuth = struct {
    start_count: usize = 0,

    fn openChatGptSignInPickerFromRoot(self: *BusySignInAuth, _: std.mem.Allocator) !bool {
        self.start_count += 1;
        return true;
    }

    fn openGrokSignInPickerFromRoot(self: *BusySignInAuth, _: std.mem.Allocator) !bool {
        self.start_count += 1;
        return true;
    }

    fn signInBrowserUrlAlloc(_: *BusySignInAuth, _: std.mem.Allocator) !?[]u8 {
        return null;
    }
};

const BusySignInApp = struct {
    pub const host_profile = runtime_profile.native;

    alloc: std.mem.Allocator = std.testing.allocator,
    selected_provider: model_provider.ProviderId = .gateway,
    selected_model: std.ArrayList(u8) = .empty,
    auth: BusySignInAuth = .{},
    stream: struct { active: bool = false } = .{},
    worker: struct {
        queued_prompts: usize = 0,

        fn queuedPromptCount(self: @This()) usize {
            return self.queued_prompts;
        }
    } = .{},
    shell: struct { render_requests: TestRenderRequests = .{} } = .{},
    notice_count: usize = 0,
    flush_count: usize = 0,

    fn deinit(self: *BusySignInApp) void {
        self.selected_model.deinit(self.alloc);
    }

    fn writeDomainNotice(self: *BusySignInApp, _: types.SemanticNotice, _: bool) !void {
        self.notice_count += 1;
    }

    fn flushBeforeBlockingExternalWork(self: *BusySignInApp) !void {
        self.flush_count += 1;
    }

    fn urlOpener(_: *BusySignInApp) host.UrlOpener {
        return host.unavailable_url_opener;
    }
};

test "interactive subscription sign-in rejects active and queued work before OAuth" {
    const cases = [_]struct {
        stream_active: bool,
        queued_prompts: usize,
    }{
        .{ .stream_active = true, .queued_prompts = 0 },
        .{ .stream_active = false, .queued_prompts = 1 },
    };

    for (cases) |case| {
        inline for ([_]model_provider.ProviderId{ .codex, .grok }) |provider| {
            var app: BusySignInApp = .{};
            defer app.deinit();
            app.stream.active = case.stream_active;
            app.worker.queued_prompts = case.queued_prompts;

            switch (provider) {
                .codex => try Runtime(BusySignInApp).beginChatGptSignIn(&app),
                .grok => try Runtime(BusySignInApp).beginGrokSignIn(&app),
                .claude => unreachable,
                .gateway => unreachable,
            }

            try std.testing.expectEqual(@as(usize, 0), app.auth.start_count);
            try std.testing.expectEqual(@as(usize, 0), app.flush_count);
            try std.testing.expectEqual(@as(usize, 1), app.notice_count);
        }
    }
}

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
    app.auth.sign_in_transition = .{ .succeeded = .{ .vercel = .{} } };

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
    app.auth.sign_in_transition = .{ .succeeded = .{ .vercel = .{} } };

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
    app.auth.sign_in_transition = .{ .succeeded = .{ .vercel = .{} } };
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
    try std.testing.expect(app.auth.refresh_failure_source == null);
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
