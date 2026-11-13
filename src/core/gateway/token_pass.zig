//! Token Pass is Vercel's monthly credit for a small set of featured
//! open-weight models. AI Gateway serves them through the `token-pass`
//! provider and bills them to the team's Token Pass credit while it lasts,
//! whatever credential the request uses. See
//! https://vercel.com/docs/ai-gateway/token-pass.
//!
//! The model catalog does not mark the featured models, so fx keeps their
//! list here. fx learns that a team has Token Pass when a response names
//! `token-pass` as the provider that served it, or when the credits endpoint
//! reports the team's Token Pass credit. This file imports only the standard
//! library.
const std = @import("std");

/// The featured models Token Pass credit pays for. Vercel can change this
/// set; it matches the Token Pass documentation.
pub const featured_models = [_][]const u8{
    "moonshotai/kimi-k3",
    "zai/glm-5.3",
    "zai/glm-5.3-flash",
    "deepseek/deepseek-v4.1-flash",
};

/// The model fx uses for a team with an active Token Pass when the user has
/// not chosen one.
pub const pass_default_model = "deepseek/deepseek-v4.1-flash";

/// What fx says when it moves to `pass_default_model`.
pub const default_model_notice = "Token Pass is active, so fx uses " ++ pass_default_model ++ ". Change it with /model.";

/// The provider AI Gateway reports for a request Token Pass served.
const provider_slug = "token-pass";

pub const docs_url = "https://vercel.com/docs/ai-gateway/token-pass";

/// Where a team buys Token Pass.
pub const purchase_url = "https://vercel.com/get/token-pass";

/// The dim line under the Vercel team notice for a team that fx does not know
/// has an active Token Pass.
/// "Vercel Token Pass" is an OSC 8 link to `purchase_url`, so the terminal
/// shows the name and not the address.
pub const offer_line = "Get $150 of tokens for $30 with \x1b]8;;" ++ purchase_url ++ "\x1b\\Vercel Token Pass\x1b]8;;\x1b\\.";

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

test "the Token Pass default model is one Token Pass pays for" {
    try std.testing.expect(isFeaturedModel(pass_default_model));
}

fn isTokenPassProvider(provider: []const u8) bool {
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

/// The model for an AI Gateway side call: a Token Pass model when the
/// session runs a Token Pass model, so the whole session stays on Token Pass
/// credit, and `default_model` otherwise.
pub fn modelForSideCall(call: SideCall, session_model: []const u8, default_model: []const u8) []const u8 {
    return if (isFeaturedModel(session_model)) sideCallModel(call) else default_model;
}

/// The Token Pass model of another family that retries a summary a Token
/// Pass model could not write. Null when `primary` is not a Token Pass
/// model, which leaves the choice to the compactor.
pub fn compactionFallback(primary: []const u8) ?[]const u8 {
    if (!isFeaturedModel(primary)) return null;
    return if (std.ascii.startsWithIgnoreCase(primary, "zai/")) "deepseek/deepseek-v4.1-flash" else "zai/glm-5.3";
}

/// What fx has seen of the current team's Token Pass. `unknown` covers a
/// team without one and a team that has not yet sent a featured request.
pub const Status = enum { unknown, active };

/// The current credential's Token Pass status. It turns active when a
/// response names `token-pass` as the provider that served it or the credits
/// endpoint reports Token Pass credit, and back to unknown when AI Gateway
/// says the team has no active Token Pass. Its owner resets it when the
/// credential or the team changes. It is read and written on the main thread
/// only.
pub const Tracker = struct {
    status: Status = .unknown,

    /// Records the provider that served a request. Returns true when the
    /// status changed.
    pub fn observeServedBy(self: *Tracker, served_by: []const u8) bool {
        if (!isTokenPassProvider(served_by)) return false;
        return self.markActive();
    }

    /// Records that the credits endpoint reported the team's Token Pass
    /// credit. Returns true when the status changed.
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
    try std.testing.expect(!isFeaturedModel("glm-5.3"));
    try std.testing.expect(!isFeaturedModel("openai/gpt-5.6-luna"));
    try std.testing.expect(!isFeaturedModel(""));
}

test "token pass: side calls stay on Token Pass models in a Token Pass session" {
    const default_model = "openai/gpt-5.6-luna";
    for (featured_models) |session_model| {
        inline for (.{ SideCall.review, SideCall.title, SideCall.vision }) |call| {
            const chosen = modelForSideCall(call, session_model, default_model);
            try std.testing.expect(isFeaturedModel(chosen));
        }
    }
    try std.testing.expectEqualStrings(default_model, modelForSideCall(.review, "anthropic/claude-opus-4.8", default_model));
    try std.testing.expectEqualStrings(default_model, modelForSideCall(.title, "zai/glm-5.3-fast", default_model));
}

test "token pass: a compaction retry uses another Token Pass family" {
    for (featured_models) |primary| {
        const fallback = compactionFallback(primary).?;
        try std.testing.expect(isFeaturedModel(fallback));
        const family = primary[0 .. std.mem.findScalar(u8, primary, '/').? + 1];
        try std.testing.expect(!std.mem.startsWith(u8, fallback, family));
    }
    try std.testing.expect(compactionFallback("anthropic/claude-opus-4.8") == null);
}

test "token pass: the tracker turns active once on a token-pass response" {
    var tracker: Tracker = .{};
    try std.testing.expect(!tracker.observeServedBy("baseten"));
    try std.testing.expectEqual(Status.unknown, tracker.status);
    try std.testing.expect(tracker.observeServedBy("token-pass"));
    try std.testing.expectEqual(Status.active, tracker.status);
    try std.testing.expect(!tracker.observeServedBy("Token-Pass"));
    // A later fallback to another provider does not end the subscription.
    try std.testing.expect(!tracker.observeServedBy("baseten"));
    try std.testing.expectEqual(Status.active, tracker.status);

    var from_credits: Tracker = .{};
    try std.testing.expect(from_credits.observeCredit());
    try std.testing.expect(!from_credits.observeCredit());
    try std.testing.expectEqual(Status.active, from_credits.status);

    // AI Gateway saying the team has no active Token Pass ends the status,
    // and a later Token Pass response starts it again.
    try std.testing.expect(from_credits.observeNoPass());
    try std.testing.expectEqual(Status.unknown, from_credits.status);
    try std.testing.expect(!from_credits.observeNoPass());
    try std.testing.expect(from_credits.observeServedBy("token-pass"));
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
