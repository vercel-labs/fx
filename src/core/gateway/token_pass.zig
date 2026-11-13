//! Token Pass is Vercel's monthly credit for a small set of featured
//! open-weight models. AI Gateway serves them through the `token-pass`
//! provider and bills them to the team's Token Pass credit while it lasts,
//! whatever credential the request uses. See
//! https://vercel.com/docs/ai-gateway/token-pass.
//!
//! The model catalog does not mark the featured models, so fx keeps their
//! list here. fx learns that a team has Token Pass from the credits endpoint,
//! which it asks when a session starts, and from a response that names
//! `token-pass` as the provider that served it. Until then, and for a team
//! without Token Pass, fx shows nothing about Token Pass. This file imports
//! only the standard library.
const std = @import("std");

/// The featured models Token Pass credit pays for. Vercel can change this
/// set; it matches the Token Pass documentation.
pub const featured_models = [_][]const u8{
    "moonshotai/kimi-k3",
    "moonshotai/kimi-k3.1-pro",
    "zai/glm-5.3",
    "zai/glm-5.3-flash",
    "deepseek/deepseek-v4.1-flash",
};

/// The model an AI Gateway session starts on when the team has Token Pass
/// and nothing else chose the model.
pub const default_model = "deepseek/deepseek-v4.1-flash";

/// What AI Gateway last said about a team's Token Pass.
pub const Answer = enum { has_pass, no_pass };

/// The model a session starts on when nothing chose it: the Token Pass
/// default for a team with Token Pass, and `builtin_default` otherwise.
pub fn startModel(builtin_default: []const u8, has_pass: bool) []const u8 {
    return if (has_pass) default_model else builtin_default;
}

/// The start model for a session still on one of the two start models, or
/// null when it runs another model, which keeps its place. The caller
/// decides that nothing else chose the session's model.
pub fn startModelFor(current: []const u8, builtin_default: []const u8, has_pass: bool) ?[]const u8 {
    if (!std.mem.eql(u8, current, builtin_default) and !std.mem.eql(u8, current, default_model)) return null;
    return startModel(builtin_default, has_pass);
}

/// Whether Token Pass credit pays for `model`, where `has_pass` says whether
/// fx knows the team has Token Pass.
pub fn paysFor(has_pass: bool, model: []const u8) bool {
    return has_pass and isFeaturedModel(model);
}

/// Whether fx offers Fast mode for `model`, which `supports_fast_mode` says
/// the model has. Token Pass credit does not pay for Fast mode, so a Token
/// Pass model of a team with Token Pass offers none.
pub fn offersFastMode(has_pass: bool, model: []const u8, supports_fast_mode: bool) bool {
    return supports_fast_mode and !paysFor(has_pass, model);
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

/// Whether Token Pass credit pays for `model` at standard speed.
pub fn isFeaturedModel(model: []const u8) bool {
    for (featured_models) |featured| {
        if (std.ascii.eqlIgnoreCase(model, featured)) return true;
    }
    return false;
}

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

/// The model for an AI Gateway side call: a Token Pass model when the team
/// has Token Pass and the session runs a Token Pass model, so the whole
/// session stays on Token Pass credit, and `fallback_model` otherwise.
pub fn modelForSideCall(call: SideCall, session_model: []const u8, fallback_model: []const u8, has_pass: bool) []const u8 {
    return if (paysFor(has_pass, session_model)) sideCallModel(call) else fallback_model;
}

/// The Token Pass model of another family that retries a summary a Token
/// Pass model could not write. Null when the team has no Token Pass or
/// `primary` is not a Token Pass model, which leaves the choice to the
/// compactor.
pub fn compactionFallback(primary: []const u8, has_pass: bool) ?[]const u8 {
    if (!paysFor(has_pass, primary)) return null;
    return if (std.ascii.startsWithIgnoreCase(primary, "zai/")) "deepseek/deepseek-v4.1-flash" else "zai/glm-5.3";
}

/// Whether the team of the process's AI Gateway credential has Token Pass,
/// for side calls that run off the main thread, such as permission reviews
/// and the vision tool. A process has one AI Gateway credential at a time, so
/// one value serves all its sessions. Its owner on the main thread publishes
/// every change, and any thread may read it.
var process_has_pass: std.atomic.Value(bool) = .init(false);

pub fn publishHasPass(has_pass: bool) void {
    process_has_pass.store(has_pass, .release);
}

pub fn processHasPass() bool {
    return process_has_pass.load(.acquire);
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
        .scoped_key_model => "This API key works only with Token Pass models at standard speed: " ++
            featured_list ++ ". Choose one, or use a standard API key.",
        .no_active_pass => "Subscribe in the Token Pass tab at " ++ dashboard_url ++
            ", or switch to the team that has Token Pass with fx teams or /login.",
    };
}

const featured_list = blk: {
    var text: []const u8 = "";
    for (featured_models, 0..) |model, index| {
        text = text ++ (if (index == 0) "" else ", ") ++ model;
    }
    break :blk text;
};

test "token pass: featured models match exactly and ignore case" {
    for (featured_models) |model| try std.testing.expect(isFeaturedModel(model));
    try std.testing.expect(isFeaturedModel("ZAI/GLM-5.3"));
    try std.testing.expect(!isFeaturedModel("zai/glm-5.3-fast"));
    try std.testing.expect(!isFeaturedModel("moonshotai/kimi-k3.1-pro-highspeed"));
    try std.testing.expect(!isFeaturedModel("glm-5.3"));
    try std.testing.expect(!isFeaturedModel("openai/gpt-5.6-luna"));
    try std.testing.expect(!isFeaturedModel(""));
}

test "token pass: side calls stay on Token Pass models in a Token Pass session" {
    const fallback_model = "openai/gpt-5.6-luna";
    for (featured_models) |session_model| {
        inline for (.{ SideCall.review, SideCall.title, SideCall.vision }) |call| {
            const chosen = modelForSideCall(call, session_model, fallback_model, true);
            try std.testing.expect(isFeaturedModel(chosen));
            // A team without Token Pass keeps the usual side-call model.
            try std.testing.expectEqualStrings(fallback_model, modelForSideCall(call, session_model, fallback_model, false));
        }
    }
    try std.testing.expectEqualStrings(fallback_model, modelForSideCall(.review, "anthropic/claude-opus-4.8", fallback_model, true));
    try std.testing.expectEqualStrings(fallback_model, modelForSideCall(.title, "zai/glm-5.3-fast", fallback_model, true));
}

test "token pass: a compaction retry uses another Token Pass family" {
    for (featured_models) |primary| {
        const fallback = compactionFallback(primary, true).?;
        try std.testing.expect(isFeaturedModel(fallback));
        const family = primary[0 .. std.mem.findScalar(u8, primary, '/').? + 1];
        try std.testing.expect(!std.mem.startsWith(u8, fallback, family));
        try std.testing.expect(compactionFallback(primary, false) == null);
    }
    try std.testing.expect(compactionFallback("anthropic/claude-opus-4.8", true) == null);
}

test "token pass: a team with Token Pass starts on the Token Pass default" {
    const builtin_default = "spacexai/grok-4.7";
    try std.testing.expect(isFeaturedModel(default_model));
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

test "token pass: only a team with Token Pass loses Fast mode on Token Pass models" {
    try std.testing.expect(paysFor(true, "zai/glm-5.3"));
    try std.testing.expect(!paysFor(false, "zai/glm-5.3"));
    try std.testing.expect(!paysFor(true, "openai/gpt-5.6-luna"));

    try std.testing.expect(!offersFastMode(true, "moonshotai/kimi-k3", true));
    try std.testing.expect(offersFastMode(false, "moonshotai/kimi-k3", true));
    try std.testing.expect(offersFastMode(true, "openai/gpt-5.6-luna", true));
    try std.testing.expect(!offersFastMode(false, "openai/gpt-5.6-luna", false));
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

test "token pass: the scoped-key hint names every featured model" {
    const hint = deniedHint(.scoped_key_model);
    for (featured_models) |model| try std.testing.expect(std.mem.find(u8, hint, model) != null);
    try std.testing.expect(std.mem.find(u8, deniedHint(.no_active_pass), dashboard_url) != null);
}
