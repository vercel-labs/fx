//! Token Pass is Vercel's monthly credit for a small set of featured
//! open-weight models. AI Gateway serves them through the `token-pass`
//! provider and bills them to the team's Token Pass credit while it lasts,
//! whatever credential the request uses. See
//! https://vercel.com/docs/ai-gateway/token-pass.
//!
//! AI Gateway marks each model a team's Token Pass pays for with
//! `token_pass: true` in the coding-agent model catalog, and only for a team
//! with an active pass, so fx keeps no list of its own. fx learns that a team
//! has Token Pass from those marks, from the credits endpoint, which it asks
//! when a session starts, and from a response that names `token-pass` as the
//! provider that served it. Until then, and for a team without Token Pass, fx
//! shows nothing about Token Pass. This file imports only the standard
//! library; `token_pass_team.zig` holds what the process knows of its team.
const std = @import("std");

/// The model an AI Gateway session starts on when the team has Token Pass
/// and nothing else chose the model.
pub const default_model = "deepseek/deepseek-v4.1-flash";

/// The most Token Pass models fx keeps for a team, and the longest model ID.
/// A team's pass pays for a handful of models; a mark past either limit is
/// dropped, and the trace says so.
pub const max_team_models = 32;
pub const max_model_id_len = 128;

/// The models AI Gateway marks as paid by a team's Token Pass, in a fixed
/// buffer so any thread can take a copy without allocating.
pub const TeamModels = struct {
    ids: [max_team_models][max_model_id_len]u8 = undefined,
    lens: [max_team_models]u8 = @splat(0),
    count: u8 = 0,

    /// Adds `id`. Returns false when the set is full or `id` is too long.
    pub fn add(self: *TeamModels, id: []const u8) bool {
        if (self.contains(id)) return true;
        if (self.count == max_team_models or id.len == 0 or id.len > max_model_id_len) return false;
        @memcpy(self.ids[self.count][0..id.len], id);
        self.lens[self.count] = @intCast(id.len);
        self.count += 1;
        return true;
    }

    pub fn contains(self: *const TeamModels, id: []const u8) bool {
        for (0..self.count) |index| {
            if (std.ascii.eqlIgnoreCase(self.ids[index][0..self.lens[index]], id)) return true;
        }
        return false;
    }
};

/// What fx knows of a team's Token Pass: whether the team has one, and the
/// models AI Gateway marks as paid by it.
pub const Team = struct {
    has_pass: bool = false,
    models: TeamModels = .{},

    /// Whether Token Pass credit pays for `model` for this team.
    pub fn paysFor(self: *const Team, model: []const u8) bool {
        return self.has_pass and self.models.contains(model);
    }
};

/// What AI Gateway last said about a team's Token Pass.
pub const Answer = enum { has_pass, no_pass };

/// The model a session starts on when nothing chose it: the Token Pass
/// default for a team with Token Pass, and `builtin_default` otherwise.
fn startModel(builtin_default: []const u8, has_pass: bool) []const u8 {
    return if (has_pass) default_model else builtin_default;
}

/// The start model for a session still on one of the two start models, or
/// null when it runs another model, which keeps its place. The caller
/// decides that nothing else chose the session's model.
pub fn startModelFor(current: []const u8, builtin_default: []const u8, has_pass: bool) ?[]const u8 {
    if (!std.mem.eql(u8, current, builtin_default) and !std.mem.eql(u8, current, default_model)) return null;
    return startModel(builtin_default, has_pass);
}

/// Whether fx offers Fast mode for a model that `supports_fast_mode`, where
/// `paid_by_pass` says the team's Token Pass pays for it. Token Pass credit
/// does not pay for Fast mode, so such a model offers none.
pub fn offersFastMode(paid_by_pass: bool, supports_fast_mode: bool) bool {
    return supports_fast_mode and !paid_by_pass;
}

/// How a credential names its team, for the saved answer.
pub const IdentityKind = enum {
    /// fx login: the account and the team it chose. Its token changes as it
    /// renews, so the token is not part of the identity.
    login,
    /// An AI Gateway API key, which belongs to one team.
    api_key,
    /// A Vercel OIDC token: the team and project its claims name. The token
    /// renews often, and its claims stay the same.
    oidc,
    /// A token fx cannot name across renewals, such as an OIDC token without
    /// those claims: named by its team alone, for one run, and fx saves no
    /// answer for it.
    session_token,
};

/// The length of an `identity`: hex of the first 16 bytes of a SHA-256.
pub const identity_len = 32;

/// A name for the credential's team that holds no secret: a hash of `kind`,
/// `subject` (the account ID for a login, the key for an API key, the team
/// and project for an OIDC token), and the team fx sends with requests.
/// Writes into `buf` and returns it.
pub fn identity(buf: *[identity_len]u8, kind: IdentityKind, subject: []const u8, team: ?[]const u8) []const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(@tagName(kind));
    hash.update(&.{0});
    hash.update(subject);
    hash.update(&.{0});
    hash.update(team orelse "");
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    buf.* = std.fmt.bytesToHex(digest[0 .. identity_len / 2].*, .lower);
    return buf;
}

/// The provider AI Gateway reports for a request Token Pass served.
const provider_slug = "token-pass";

/// The dashboard's Token Pass tab, which shows the remaining credit and the
/// reset date. Vercel fills in the signed-in team for `[team]`.
pub const dashboard_url = "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai-gateway%2Ftoken-pass";

/// Whether `provider` is the one AI Gateway names for a request Token Pass
/// served.
pub fn isTokenPassProvider(provider: []const u8) bool {
    return std.ascii.eqlIgnoreCase(provider, provider_slug);
}

/// A call fx makes on its own during a session, beside the session's turns.
pub const SideCall = enum {
    /// The automatic permission review. It needs reliable structured tool
    /// calls within the reviewer's output budget.
    review,
    /// The session title, within a 128-token reply.
    title,
    /// The vision tool, which reads images for a model that cannot.
    vision,
};

/// The Token Pass model for each side call. The reviewer must return one
/// structured decision within its output budget and its 30-second deadline:
/// DeepSeek V4.1 Flash does, while GLM 5.3 Flash can spend the budget on
/// reasoning and GLM 5.3 can miss the deadline. GLM 5.3 Flash writes a title
/// well within 128 tokens and reads images, so it takes both of those calls.
fn sideCallModel(call: SideCall) []const u8 {
    return switch (call) {
        .review => "deepseek/deepseek-v4.1-flash",
        .title, .vision => "zai/glm-5.3-flash",
    };
}

/// The model for an AI Gateway side call: fx's Token Pass model for the call
/// when the team's Token Pass pays for both it and the session's model, so
/// the whole session stays on Token Pass credit, and `fallback_model`
/// otherwise.
pub fn modelForSideCall(call: SideCall, session_model: []const u8, fallback_model: []const u8, team: *const Team) []const u8 {
    const chosen = sideCallModel(call);
    return if (team.paysFor(session_model) and team.paysFor(chosen)) chosen else fallback_model;
}

/// The Token Pass model of another family that retries a summary a Token
/// Pass model could not write. Null when the team's Token Pass does not pay
/// for `primary` or for that model, which leaves the choice to the
/// compactor.
pub fn compactionFallback(primary: []const u8, team: *const Team) ?[]const u8 {
    if (!team.paysFor(primary)) return null;
    const fallback = if (std.ascii.startsWithIgnoreCase(primary, "zai/")) "deepseek/deepseek-v4.1-flash" else "zai/glm-5.3";
    return if (team.paysFor(fallback)) fallback else null;
}

/// What fx knows of the current team's Token Pass. `unknown` covers a team
/// without one and a team fx has not heard about yet.
pub const Status = enum { unknown, active };

/// The current credential's Token Pass status. It starts from the answer fx
/// saved for the team, turns active when AI Gateway says the team has Token
/// Pass, and back to unknown when it says the team has no active Token Pass.
/// Its owner resets it when the credential or the team changes. It is read
/// and written on the main thread only.
pub const Tracker = struct {
    status: Status = .unknown,

    /// A tracker that starts from the answer fx saved for the team.
    pub fn fromSaved(saved: ?Answer) Tracker {
        return .{ .status = if (saved == .has_pass) .active else .unknown };
    }

    pub fn hasPass(self: Tracker) bool {
        return self.status == .active;
    }

    /// Records that AI Gateway said the team has Token Pass: a credits reply
    /// with Token Pass credit, or a response Token Pass served. Returns true
    /// when the status changed.
    pub fn observeCredit(self: *Tracker) bool {
        return self.markActive();
    }

    /// Records that AI Gateway said the team has no active Token Pass: a
    /// credits reply with `token_pass: null`, or a request it denied for that
    /// reason. Returns true when the status changed.
    pub fn observeNoPass(self: *Tracker) bool {
        if (self.status == .unknown) return false;
        self.status = .unknown;
        return true;
    }

    fn markActive(self: *Tracker) bool {
        if (self.status == .active) return false;
        self.status = .active;
        return true;
    }
};

/// The Token Pass reasons AI Gateway gives for a `403`
/// `no_providers_available` error.
pub const DeniedCause = enum {
    /// A Token Pass key's credit is used up for this billing period.
    credit_used_up,
    /// A Token Pass key called a model that is not featured, or Fast mode.
    scoped_key_model,
    /// The credential's team has no active Token Pass.
    no_active_pass,
};

const DeniedMarker = struct { text: []const u8, cause: DeniedCause };

// The message text each cause includes, from the Token Pass errors table.
const denied_markers = [_]DeniedMarker{
    .{ .text = "Token Pass credits are used up", .cause = .credit_used_up },
    .{ .text = "scoped to Vercel Token Pass", .cause = .scoped_key_model },
    .{ .text = "requires an active Vercel Token Pass", .cause = .no_active_pass },
};

/// The Token Pass cause a Gateway error message names, if any.
pub fn deniedCause(message: []const u8) ?DeniedCause {
    for (denied_markers) |marker| {
        if (std.ascii.findIgnoreCase(message, marker.text) != null) return marker.cause;
    }
    return null;
}

/// What the user can do about `cause`, as one line.
pub fn deniedHint(cause: DeniedCause) []const u8 {
    return switch (cause) {
        .credit_used_up => "This API key spends only Token Pass credit, so it does not fall back to AI Gateway credits. " ++
            "Wait for the next billing period, or use a standard API key or fx login.",
        .scoped_key_model => "This API key works only with Token Pass models at standard speed. " ++
            "Choose one under Token Pass in /models, or use a standard API key.",
        .no_active_pass => "Subscribe in the Token Pass tab at " ++ dashboard_url ++
            ", or switch to the team that has Token Pass with fx teams or /login.",
    };
}

/// A team with Token Pass whose catalog marks `ids`, for tests.
fn testTeam(ids: []const []const u8) Team {
    var team: Team = .{ .has_pass = true };
    for (ids) |id| std.debug.assert(team.models.add(id));
    return team;
}

const test_pass_models = [_][]const u8{ "moonshotai/kimi-k3", "zai/glm-5.3", "zai/glm-5.3-flash", "deepseek/deepseek-v4.1-flash" };

test "token pass: a team's models match exactly, ignore case, and need the pass" {
    var team = testTeam(&test_pass_models);
    try std.testing.expect(team.paysFor("ZAI/GLM-5.3"));
    try std.testing.expect(!team.paysFor("zai/glm-5.3-fast"));
    try std.testing.expect(!team.paysFor("glm-5.3"));
    try std.testing.expect(!team.paysFor("openai/gpt-5.6-luna"));
    try std.testing.expect(!team.paysFor(""));
    team.has_pass = false;
    try std.testing.expect(!team.paysFor("zai/glm-5.3"));

    // The set refuses what it cannot hold and keeps each ID once.
    var models: TeamModels = .{};
    try std.testing.expect(models.add("zai/glm-5.3"));
    try std.testing.expect(models.add("ZAI/GLM-5.3"));
    try std.testing.expectEqual(@as(u8, 1), models.count);
    try std.testing.expect(!models.add(""));
    const too_long: [max_model_id_len + 1]u8 = @splat('x');
    try std.testing.expect(!models.add(&too_long));
    var index: usize = 1;
    while (index < max_team_models) : (index += 1) {
        var buf: [16]u8 = undefined;
        try std.testing.expect(models.add(try std.mem.print(&buf, "acme/m{d}", .{index})));
    }
    try std.testing.expect(!models.add("acme/one-too-many"));
}

test "token pass: side calls stay on Token Pass models in a Token Pass session" {
    const fallback_model = "openai/gpt-5.6-luna";
    const team = testTeam(&test_pass_models);
    const no_pass: Team = .{ .models = team.models };
    for (test_pass_models) |session_model| {
        inline for (.{ SideCall.review, SideCall.title, SideCall.vision }) |call| {
            const chosen = modelForSideCall(call, session_model, fallback_model, &team);
            try std.testing.expect(team.paysFor(chosen));
            // A team without Token Pass keeps the usual side-call model.
            try std.testing.expectEqualStrings(fallback_model, modelForSideCall(call, session_model, fallback_model, &no_pass));
        }
    }
    try std.testing.expectEqualStrings(fallback_model, modelForSideCall(.review, "anthropic/claude-opus-4.8", fallback_model, &team));
    try std.testing.expectEqualStrings(fallback_model, modelForSideCall(.title, "zai/glm-5.3-fast", fallback_model, &team));

    // A side-call model the team's pass does not pay for is not used.
    const without_reviewer = testTeam(&.{ "zai/glm-5.3", "zai/glm-5.3-flash" });
    try std.testing.expectEqualStrings(fallback_model, modelForSideCall(.review, "zai/glm-5.3", fallback_model, &without_reviewer));
    try std.testing.expectEqualStrings("zai/glm-5.3-flash", modelForSideCall(.title, "zai/glm-5.3", fallback_model, &without_reviewer));
}

test "token pass: a compaction retry uses another Token Pass family" {
    const team = testTeam(&test_pass_models);
    const no_pass: Team = .{ .models = team.models };
    for (test_pass_models) |primary| {
        const fallback = compactionFallback(primary, &team).?;
        try std.testing.expect(team.paysFor(fallback));
        const family = primary[0 .. std.mem.findScalar(u8, primary, '/').? + 1];
        try std.testing.expect(!std.mem.startsWith(u8, fallback, family));
        try std.testing.expect(compactionFallback(primary, &no_pass) == null);
    }
    try std.testing.expect(compactionFallback("anthropic/claude-opus-4.8", &team) == null);
    // Without a Token Pass model of another family, the compactor chooses.
    try std.testing.expect(compactionFallback("zai/glm-5.3", &testTeam(&.{ "zai/glm-5.3", "zai/glm-5.3-flash" })) == null);
}

test "token pass: a team with Token Pass starts on the Token Pass default" {
    const builtin_default = "spacexai/grok-4.7";
    try std.testing.expectEqualStrings(default_model, startModel(builtin_default, true));
    try std.testing.expectEqualStrings(builtin_default, startModel(builtin_default, false));

    // A session on either start model takes the one for its team.
    for ([_][]const u8{ builtin_default, default_model }) |current| {
        try std.testing.expectEqualStrings(default_model, startModelFor(current, builtin_default, true).?);
        try std.testing.expectEqualStrings(builtin_default, startModelFor(current, builtin_default, false).?);
    }
    // Any other model keeps its place.
    try std.testing.expect(startModelFor("zai/glm-5.3", builtin_default, false) == null);
    try std.testing.expect(startModelFor("openai/gpt-5.6-luna", builtin_default, true) == null);
}

test "token pass: a model the pass pays for offers no Fast mode" {
    try std.testing.expect(!offersFastMode(true, true));
    try std.testing.expect(offersFastMode(false, true));
    try std.testing.expect(!offersFastMode(false, false));
}

test "token pass: an identity names the team without the secret" {
    var first: [identity_len]u8 = undefined;
    var again: [identity_len]u8 = undefined;
    const key = "vck_example_secret_key";
    const named = identity(&first, .api_key, key, null);
    try std.testing.expectEqual(identity_len, named.len);
    try std.testing.expect(std.mem.find(u8, named, key) == null);
    for (named) |c| try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    try std.testing.expectEqualStrings(named, identity(&again, .api_key, key, null));

    // Another team, another kind, or another subject is another identity.
    var other: [identity_len]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, named, identity(&other, .api_key, key, "example-team")));
    try std.testing.expect(!std.mem.eql(u8, named, identity(&other, .login, key, null)));
    try std.testing.expect(!std.mem.eql(u8, named, identity(&other, .oidc, key, null)));
    try std.testing.expect(!std.mem.eql(u8, named, identity(&other, .api_key, "vck_other_key", null)));
}

test "token pass: a tracker starts from the saved answer" {
    try std.testing.expect(Tracker.fromSaved(.has_pass).hasPass());
    try std.testing.expect(!Tracker.fromSaved(.no_pass).hasPass());
    try std.testing.expect(!Tracker.fromSaved(null).hasPass());
}

test "token pass: the tracker follows what AI Gateway says about the team" {
    try std.testing.expect(isTokenPassProvider("token-pass"));
    try std.testing.expect(isTokenPassProvider("Token-Pass"));
    try std.testing.expect(!isTokenPassProvider("baseten"));

    var from_credits: Tracker = .{};
    try std.testing.expect(from_credits.observeCredit());
    try std.testing.expect(!from_credits.observeCredit());
    try std.testing.expectEqual(Status.active, from_credits.status);

    // AI Gateway saying the team has no active Token Pass ends the status,
    // and a later Token Pass response starts it again.
    try std.testing.expect(from_credits.observeNoPass());
    try std.testing.expectEqual(Status.unknown, from_credits.status);
    try std.testing.expect(!from_credits.observeNoPass());
    try std.testing.expect(from_credits.observeCredit());
}

test "token pass: denied causes come from the documented messages" {
    try std.testing.expectEqual(
        DeniedCause.credit_used_up,
        deniedCause("Your Vercel Token Pass credits are used up until your next billing cycle.").?,
    );
    try std.testing.expectEqual(
        DeniedCause.scoped_key_model,
        deniedCause("This API key is scoped to Vercel Token Pass and can only be used with Token Pass models.").?,
    );
    try std.testing.expectEqual(
        DeniedCause.no_active_pass,
        deniedCause("This request requires an active Vercel Token Pass.").?,
    );
    try std.testing.expect(deniedCause("Your team has restricted access to this provider.") == null);
    try std.testing.expect(deniedCause("") == null);
}

test "token pass: the hints point at the picker and the dashboard" {
    try std.testing.expect(std.mem.find(u8, deniedHint(.scoped_key_model), "Token Pass in /models") != null);
    try std.testing.expect(std.mem.find(u8, deniedHint(.no_active_pass), dashboard_url) != null);
}
