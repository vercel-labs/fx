//! Finds out whether the team of the AI Gateway credential has Token Pass.
//! When a session starts, fx takes the answer it saved for the team, then
//! asks the credits endpoint in the background, as `/credits` does, and
//! saves the new answer. A team with Token Pass starts a new session on the
//! Token Pass default model when nothing else chose the model. Without a
//! saved answer, the first prompt of a session waits up to
//! `first_prompt_wait_ms` for the check.
const std = @import("std");
const builtin = @import("builtin");
const agents = @import("../agents/agents.zig");
const credentials = @import("../auth/credentials.zig");
const jwt_claims = @import("../auth/jwt_claims.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");
const token_pass = @import("../gateway/token_pass.zig");
const token_pass_memory = @import("../gateway/token_pass_memory.zig");
const token_pass_team = @import("../gateway/token_pass_team.zig");
const credits_lookup = @import("credits_lookup.zig");
const provider_runtime = @import("provider_runtime.zig");
const session_commands = @import("../session/session_commands.zig");

const Allocator = std.mem.Allocator;

/// How long the first prompt of a session waits for a check whose answer fx
/// has not saved before.
pub const first_prompt_wait_ms: i64 = 2_000;

const Identity = [token_pass.identity_len]u8;

/// How the check names a credential's team: `asked` for this run, and
/// `saved_as` for the saved answer, when fx keeps one for the credential.
pub const Named = struct {
    asked: Identity,
    saved_as: ?Identity,
};

/// The name of the credential's team, or null when fx does not check it:
/// a credential that is not for AI Gateway, or one a host manages.
pub fn name(alloc: Allocator, source: credentials.Source, api_key: ?[]const u8, account: ?[]const u8, team: ?[]const u8) ?Named {
    var named: Named = .{ .asked = undefined, .saved_as = null };
    switch (source) {
        .fx_login => if (account) |id| {
            _ = token_pass.identity(&named.asked, .login, id, team);
            named.saved_as = named.asked;
        } else {
            _ = token_pass.identity(&named.asked, .session_token, "", team);
        },
        .ai_gateway_api_key, .stored_key => {
            const key = api_key orelse return null;
            _ = token_pass.identity(&named.asked, .api_key, key, team);
            named.saved_as = named.asked;
        },
        .vercel_oidc_token => {
            const subject = if (api_key) |token| oidcSubject(alloc, token) else null;
            defer if (subject) |value| alloc.free(value);
            if (subject) |value| {
                _ = token_pass.identity(&named.asked, .oidc, value, team);
                named.saved_as = named.asked;
            } else {
                _ = token_pass.identity(&named.asked, .session_token, "", team);
            }
        },
        .chatgpt_subscription, .grok_subscription, .host_managed, .configured => return null,
    }
    return named;
}

/// The longest OIDC token whose claims fx reads to name its team.
const max_oidc_token_bytes: usize = 16 * 1024;

/// The team and project a Vercel OIDC token names in its `owner_id` and
/// `project_id` claims, joined by a zero byte, or null when the token is not
/// a JWT with both. The claims stay the same as the token renews. fx uses
/// them only to name the saved answer, so it does not check the signature.
/// Caller owns the result.
fn oidcSubject(alloc: Allocator, token: []const u8) ?[]u8 {
    if (token.len > max_oidc_token_bytes) return null;
    var parsed = jwt_claims.parse(alloc, token) catch return null;
    defer parsed.deinit();
    const owner = claimString(parsed.value.object, "owner_id") orelse return null;
    const project = claimString(parsed.value.object, "project_id") orelse return null;
    return alloc.print("{s}\x00{s}", .{ owner, project }) catch null;
}

fn claimString(claims: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = claims.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

/// What a credits reply says about the team's Token Pass, or null when it
/// says nothing or the request failed.
pub fn answerOf(snapshot: output_contracts.CreditsSnapshot) ?token_pass.Answer {
    if (snapshot.err_message != null) return null;
    if (snapshot.token_pass != null) return .has_pass;
    if (snapshot.no_token_pass) return .no_pass;
    return null;
}

/// How often a wait looks for the check's answer.
const answer_poll_ms: u64 = 10;

/// For `fx ask` and ACP: the answer saved for the team, refreshed by a
/// credits check that runs while the session works. Without a saved answer,
/// `begin` waits for the check, as the first prompt in the app does.
pub const Check = struct {
    lookup: credits_lookup.Lookup = .{},
    named: Named,
    home: ?[]const u8,
    has_pass: bool = false,

    /// Starts the check with the saved answer, or waits at most `wait_ms`
    /// for one when fx has none. Publishes whether the team has Token Pass
    /// to `token_pass_team`.
    pub fn begin(
        self: *Check,
        alloc: Allocator,
        provider: gateway_provider.CreditsProvider,
        input: gateway_provider.CreditsLookupInput,
        wait_ms: i64,
    ) void {
        const saved: ?token_pass.Answer = if (self.home) |dir| if (self.named.saved_as) |id| token_pass_memory.load(alloc, dir, &id) else null else null;
        self.has_pass = saved == .has_pass;
        defer token_pass_team.publishHasPass(self.has_pass);
        if (comptime builtin.single_threaded) return;
        // A login that is due for renewal has no token yet; the saved answer
        // stands, and the next run asks.
        if (input.credential == null) {
            debug_trace.logf("token_pass", "check skipped reason=no_token saved={s}", .{answerLabel(saved)});
            return;
        }
        _ = self.lookup.start(provider, input, null) catch |err| {
            debug_trace.logf("token_pass", "check start failed err={s}", .{@errorName(err)});
            return;
        };
        debug_trace.logf("token_pass", "check started saved={s}", .{answerLabel(saved)});
        if (saved == null) self.waitForAnswer(alloc, wait_ms);
    }

    /// Takes the answer if it has arrived, without waiting.
    pub fn poll(self: *Check, alloc: Allocator) void {
        self.waitForAnswer(alloc, 0);
    }

    /// Takes an answer that has arrived, then stops the check. `reason`
    /// names why, for the trace, when the check had not answered.
    pub fn finish(self: *Check, alloc: Allocator, reason: []const u8) void {
        self.waitForAnswer(alloc, 0);
        if (self.lookup.task != null) debug_trace.logf("token_pass", "check dropped reason={s}", .{reason});
        self.lookup.deinit();
    }

    fn waitForAnswer(self: *Check, alloc: Allocator, wait_ms: i64) void {
        const deadline = io_mod.awakeMilliTimestamp() + wait_ms;
        while (self.lookup.task != null) {
            if (self.lookup.take()) |taken| {
                var result = taken;
                defer result.deinit();
                const answer = answerOf(result.snapshot);
                if (answer) |fresh| {
                    self.has_pass = fresh == .has_pass;
                    token_pass_team.publishHasPass(self.has_pass);
                    if (self.home) |dir| if (self.named.saved_as) |id| saveAnswer(alloc, dir, &id, fresh);
                }
                // Logged once the answer is saved, so a reader of the trace
                // finds the file current.
                debug_trace.logf("token_pass", "check answered answer={s}", .{answerLabel(answer)});
                return;
            }
            if (io_mod.awakeMilliTimestamp() >= deadline) {
                if (wait_ms > 0) debug_trace.logf("token_pass", "check wait ended without an answer wait_ms={d}", .{wait_ms});
                return;
            }
            io_mod.sleep(answer_poll_ms * std.time.ns_per_ms);
        }
    }
};

fn saveAnswer(alloc: Allocator, home: []const u8, id: []const u8, answer: token_pass.Answer) void {
    token_pass_memory.save(alloc, home, id, answer) catch |err| {
        debug_trace.logf("token_pass", "saved answer not written err={s}", .{@errorName(err)});
    };
}

fn answerLabel(answer: ?token_pass.Answer) []const u8 {
    return if (answer) |value| @tagName(value) else "none";
}

/// The interactive app's check: one at a time, once per credential and team.
pub const State = struct {
    lookup: credits_lookup.Lookup = .{},
    /// The credential and team the last check asked about.
    asked: ?Identity = null,
    /// Where the running check's answer is saved, when fx keeps one.
    saved_as: ?Identity = null,
    /// The latest answer for that team: the saved one, then the check's.
    answer: ?token_pass.Answer = null,
    /// When the running check started, on the awake clock.
    started_ms: ?i64 = null,
    /// Whether fx had a saved answer when the running check started.
    had_saved: bool = false,
    /// Whether this run's start model is decided. Once the first check
    /// answers or the first prompt goes out, fx no longer changes the model.
    start_settled: bool = false,

    pub fn deinit(self: *State) void {
        self.lookup.deinit();
    }

    /// Ends this run's start-model decision: once the user chooses a model,
    /// fx no longer changes it, whatever the check answers later.
    pub fn settle(self: *State, reason: []const u8) void {
        if (self.start_settled) return;
        self.start_settled = true;
        debug_trace.logf("token_pass", "start model settled reason={s}", .{reason});
    }

    /// Whether the session's first prompt waits for the running check: only
    /// while fx knows nothing of the team, from a saved answer or from AI
    /// Gateway, such as a catalog that marks Token Pass models.
    fn holdsFirstPrompt(self: *const State, now_ms: i64) bool {
        if (self.start_settled or self.had_saved or self.answer != null) return false;
        const started = self.started_ms orelse return false;
        return now_ms - started < first_prompt_wait_ms;
    }
};

pub const Readiness = enum { pending, current };

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};

        /// Starts the check for the current credential, unless this run
        /// already asked about its team. Applies the saved answer at once.
        pub fn start(app: *App) void {
            if (comptime builtin.single_threaded or !@hasField(App, "token_pass_check")) return;
            if (provider_runtime.provider(app) != .gateway) return;
            const credential = app.auth.queuedPromptCredential() orelse return;
            // A login due for renewal waits for it, as `/credits` does: its
            // renewal starts the warmup, and so the check, again.
            if (credentials.sourceRefreshable(credential.source) and app.auth.credentialNeedsRefresh()) {
                debug_trace.logf("token_pass", "check deferred reason=credential_refresh_required", .{});
                return;
            }
            const named = name(app.alloc, credential.source, credential.api_key, credential.account orelse app.auth.accountId(), credential.gateway_team) orelse return;
            const state = &app.token_pass_check;
            if (state.asked) |asked| if (std.mem.eql(u8, &asked, &named.asked)) {
                // A new sign-in to the same team resets the status; its
                // answer still holds.
                const has_pass = state.answer == .has_pass;
                if ((app.model_cache.tokenPassStatus() == .active) != has_pass) app.model_cache.adoptSavedTokenPass(state.answer);
                return;
            };

            // A check for an earlier credential answers for another team.
            if (state.lookup.task != null) debug_trace.logf("token_pass", "check dropped reason=credential_changed", .{});
            state.lookup.deinit();
            state.asked = named.asked;
            state.saved_as = named.saved_as;
            state.started_ms = null;
            const saved: ?token_pass.Answer = if (io_mod.homeDir()) |home|
                if (named.saved_as) |id| token_pass_memory.load(app.alloc, home, &id) else null
            else
                null;
            state.had_saved = saved != null;
            state.answer = saved;
            app.model_cache.adoptSavedTokenPass(saved);
            applyStartModel(app) catch |err| {
                debug_trace.logf("token_pass", "start model not applied source=saved err={s}", .{@errorName(err)});
            };

            const input: gateway_provider.CreditsLookupInput = .{
                .credential = credential.api_key,
                .credential_source = credential.source,
                .tenant = credential.gateway_team,
            };
            _ = state.lookup.start(app.creditsProvider(), input, null) catch |err| {
                debug_trace.logf("token_pass", "check start failed err={s}", .{@errorName(err)});
                state.start_settled = true;
                return;
            };
            state.started_ms = io_mod.awakeMilliTimestamp();
            debug_trace.logf("token_pass", "check started saved={s}", .{answerLabel(saved)});
        }

        /// Takes the check's answer once it arrives. Returns true when the
        /// screen shows something new.
        pub fn collect(app: *App) !bool {
            if (comptime !@hasField(App, "token_pass_check")) return false;
            const state = &app.token_pass_check;
            var result = state.lookup.take() orelse return false;
            defer result.deinit();
            state.started_ms = null;
            const answer = answerOf(result.snapshot);
            if (answer) |fresh| record(app, fresh, "credits_check");
            debug_trace.logf("token_pass", "check answered answer={s}", .{answerLabel(answer)});
            try applyStartModel(app);
            // A check that failed leaves the start model open for another
            // answer, such as the catalog's, until the first prompt.
            if (answer != null) state.start_settled = true;
            return true;
        }

        /// Records what AI Gateway said about the team: the check's answer, a
        /// `/credits` reply, a response Token Pass served, or a Token Pass
        /// denial. fx saves each new answer for the team.
        pub fn record(app: *App, answer: token_pass.Answer, source: []const u8) void {
            app.model_cache.observeTokenPassAnswer(answer, source);
            if (comptime !@hasField(App, "token_pass_check")) return;
            const state = &app.token_pass_check;
            if (state.answer == answer) return;
            state.answer = answer;
            if (state.saved_as) |id| if (io_mod.homeDir()) |home| saveAnswer(app.alloc, home, &id, answer);
        }

        /// A catalog that marks Token Pass models, which AI Gateway sends only
        /// to a team with an active pass.
        pub fn observeCatalog(app: *App) void {
            if (comptime !@hasField(App, "model_cache") or !@hasField(App, "token_pass_check")) return;
            if (provider_runtime.provider(app) != .gateway) return;
            if (!app.model_cache.catalogMarksTokenPass()) return;
            record(app, .has_pass, "catalog");
            applyStartModel(app) catch |err| {
                debug_trace.logf("token_pass", "start model not applied source=catalog err={s}", .{@errorName(err)});
            };
        }

        /// A response that names `token-pass` as the provider that served it.
        pub fn observeServedBy(app: *App, served_by: []const u8) void {
            if (token_pass.isTokenPassProvider(served_by)) record(app, .has_pass, "served_by");
        }

        /// An error the user sees: AI Gateway's denial for a team without an
        /// active Token Pass.
        pub fn observeErrorText(app: *App, text: []const u8) void {
            if (token_pass.deniedCause(text) == .no_active_pass) record(app, .no_pass, "denied");
        }

        /// For the first prompt of a session: waits while the check that
        /// decides its model runs, up to `first_prompt_wait_ms`.
        pub fn collectPendingPrompt(app: *App, agent: *AppAgent) Readiness {
            if (comptime !@hasField(App, "token_pass_check")) return .current;
            const state = &app.token_pass_check;
            if (state.start_settled) return .current;
            if (agent != &app.main_agent or agent.session.agent.history.items.len != 0) {
                state.start_settled = true;
                return .current;
            }
            if (state.holdsFirstPrompt(io_mod.awakeMilliTimestamp())) return .pending;
            // The wait ran out with nothing known of the team; an answer from
            // another source, such as the catalog, needs no wait.
            if (state.started_ms != null and state.answer == null) {
                debug_trace.logf("token_pass", "first prompt sent before the check answered wait_ms={d}", .{first_prompt_wait_ms});
            }
            state.start_settled = true;
            return .current;
        }

        /// Puts a new session that nothing chose a model for on the start
        /// model for its team: the Token Pass default with Token Pass, the
        /// built-in default otherwise. Saves nothing.
        fn applyStartModel(app: *App) !void {
            const state = &app.token_pass_check;
            if (state.start_settled) return;
            const seed = &app.instances.seed;
            if (seed.model_source != .compiled_default) return;
            const agent = &app.main_agent;
            if (provider_runtime.providerOf(app, agent) != .gateway) return;
            if (agent.session.agent.history.items.len != 0) return;
            const has_pass = app.model_cache.tokenPassStatus() == .active;
            const current = provider_runtime.modelOf(app, agent);
            const target = token_pass.startModelFor(current, seed.configured_model, has_pass) orelse return;
            if (std.mem.eql(u8, current, target)) return;
            debug_trace.logf("token_pass", "start model={s}", .{target});
            // Token Pass credit pays only for standard speed; the built-in
            // default goes back to the speed the profile chose.
            try session_commands.Commands(App).adoptStartModel(app, agent, target, if (has_pass) false else seed.fast_mode);
        }
    };
}

test "token pass check: a credential is named without its secret, and saved only when it lasts" {
    const alloc = std.testing.allocator;
    const login = name(alloc, .fx_login, "token-that-renews", "account_example", "example-team").?;
    try std.testing.expect(login.saved_as != null);
    const renewed = name(alloc, .fx_login, "renewed-token", "account_example", "example-team").?;
    try std.testing.expectEqualSlices(u8, &login.asked, &renewed.asked);

    const key = name(alloc, .ai_gateway_api_key, "vck_example", null, null).?;
    try std.testing.expect(key.saved_as != null);
    try std.testing.expectEqualSlices(u8, &key.asked, &name(alloc, .stored_key, "vck_example", null, null).?.asked);
    try std.testing.expect(!std.mem.eql(u8, &key.asked, &name(alloc, .ai_gateway_api_key, "vck_other", null, null).?.asked));

    // An OIDC token without the team and project claims is asked about for
    // this run only.
    const opaque_token = name(alloc, .vercel_oidc_token, "oidc-token", null, "example-team").?;
    try std.testing.expect(opaque_token.saved_as == null);
    try std.testing.expect(name(alloc, .ai_gateway_api_key, null, null, null) == null);
    try std.testing.expect(name(alloc, .host_managed, "host-token", null, null) == null);
    try std.testing.expect(name(alloc, .chatgpt_subscription, "subscription", null, null) == null);
}

fn testOidcToken(buf: []u8, claims: []const u8) []const u8 {
    const header = "eyJhbGciOiJSUzI1NiJ9";
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const payload_len = encoder.calcSize(claims.len);
    @memcpy(buf[0..header.len], header);
    buf[header.len] = '.';
    _ = encoder.encode(buf[header.len + 1 ..][0..payload_len], claims);
    const signature = ".c2lnbmF0dXJl";
    @memcpy(buf[header.len + 1 + payload_len ..][0..signature.len], signature);
    return buf[0 .. header.len + 1 + payload_len + signature.len];
}

test "token pass check: an OIDC token is saved under the team and project it names" {
    const alloc = std.testing.allocator;
    var first_buf: [512]u8 = undefined;
    var renewed_buf: [512]u8 = undefined;
    var other_buf: [512]u8 = undefined;
    var partial_buf: [512]u8 = undefined;
    const first = testOidcToken(&first_buf, "{\"owner_id\":\"team_example\",\"project_id\":\"prj_example\",\"exp\":1}");
    const renewed = testOidcToken(&renewed_buf, "{\"owner_id\":\"team_example\",\"project_id\":\"prj_example\",\"exp\":2}");
    const other = testOidcToken(&other_buf, "{\"owner_id\":\"team_other\",\"project_id\":\"prj_example\",\"exp\":1}");
    const partial = testOidcToken(&partial_buf, "{\"owner_id\":\"team_example\",\"exp\":1}");

    const named = name(alloc, .vercel_oidc_token, first, null, null).?;
    try std.testing.expect(named.saved_as != null);
    // A renewed token keeps its team's saved answer; another team has its own.
    try std.testing.expectEqualSlices(u8, &named.saved_as.?, &name(alloc, .vercel_oidc_token, renewed, null, null).?.saved_as.?);
    try std.testing.expect(!std.mem.eql(u8, &named.saved_as.?, &name(alloc, .vercel_oidc_token, other, null, null).?.saved_as.?));
    try std.testing.expect(name(alloc, .vercel_oidc_token, partial, null, null).?.saved_as == null);
    try std.testing.expect(name(alloc, .vercel_oidc_token, "header.%%%.sig", null, null).?.saved_as == null);
}

test "token pass check: a credits reply answers only when it names Token Pass" {
    try std.testing.expectEqual(token_pass.Answer.has_pass, answerOf(.{ .token_pass = .{ .remaining = "12.00" } }).?);
    // A balance the Gateway could not read still means an active Token Pass.
    try std.testing.expectEqual(token_pass.Answer.has_pass, answerOf(.{ .token_pass = .{} }).?);
    try std.testing.expectEqual(token_pass.Answer.no_pass, answerOf(.{ .no_token_pass = true }).?);
    try std.testing.expect(answerOf(.{ .balance = "4.00" }) == null);
    try std.testing.expect(answerOf(.{ .err_message = "failed", .token_pass = .{ .remaining = "1" } }) == null);
}

test "token pass check: the first prompt waits only for an answer fx has not saved" {
    var state: State = .{ .started_ms = 1_000 };
    try std.testing.expect(state.holdsFirstPrompt(1_000));
    try std.testing.expect(state.holdsFirstPrompt(1_000 + first_prompt_wait_ms - 1));
    try std.testing.expect(!state.holdsFirstPrompt(1_000 + first_prompt_wait_ms));
    state.had_saved = true;
    try std.testing.expect(!state.holdsFirstPrompt(1_000));
    // An answer from AI Gateway, such as a catalog's Token Pass marks, ends
    // the wait too.
    state = .{ .started_ms = 1_000, .answer = .has_pass };
    try std.testing.expect(!state.holdsFirstPrompt(1_000));
    state = .{ .started_ms = 1_000, .start_settled = true };
    try std.testing.expect(!state.holdsFirstPrompt(1_000));
    state = .{};
    try std.testing.expect(!state.holdsFirstPrompt(1_000));
}
