//! Pure refresh and token-response rules for Google DPoP-bound plan logins.
//!
//! No I/O, no clock, and no allocation (`RULES.md` R1.5). The caller takes the
//! cross-process lock, reads the saved login inside the lock, asks `decide`,
//! and runs the plan (`tests/tla/gemini_auth/GeminiDpopRefresh.tla`).

const std = @import("std");

/// Refresh when 300 seconds or fewer remain on the access token.
pub const refresh_margin_s: i64 = 300;
/// Cap `use_dpop_nonce` retries at one per refresh (`tests/tla/gemini_auth/GeminiDpopRefresh.tla` NonceRetryAtMostOnce).
pub const max_nonce_retries: u8 = 1;
/// Cap `invalid_dpop_proof` clock-sync retries at one per refresh.
pub const max_clock_retries: u8 = 1;

pub const SavedAccess = struct {
    access_token: []const u8,
    access_token_expires_at_s: i64,
    refresh_token_expires_at_s: i64,
};

pub const Decision = union(enum) {
    adopt,
    refresh,
    sign_in_required,
};

/// Decides inside the refresh lock whether to adopt a live saved access token,
/// refresh it, or ask the person to sign in again.
pub fn decide(saved: ?SavedAccess, rejected_access_token: ?[]const u8, now_s: i64) Decision {
    const current = saved orelse return .sign_in_required;
    // Do not adopt or refresh after the 7-day grant ends (`tests/tla/gemini_auth/GeminiDpopRefresh.tla` NoUseAfterExpiry).
    if (current.refresh_token_expires_at_s <= now_s) return .sign_in_required;

    if (current.access_token.len == 0) return .refresh;
    if (rejected_access_token) |rejected| {
        if (std.mem.eql(u8, current.access_token, rejected)) return .refresh;
    }

    const remaining_s = @as(i128, current.access_token_expires_at_s) - @as(i128, now_s);
    if (remaining_s > refresh_margin_s) return .adopt;
    return .refresh;
}

pub const Attempt = struct {
    nonce_retries: u8 = 0,
    clock_retries: u8 = 0,

    pub fn afterNonceRetry(self: Attempt) Attempt {
        return .{
            .nonce_retries = self.nonce_retries +| 1,
            .clock_retries = self.clock_retries,
        };
    }

    pub fn afterClockRetry(self: Attempt) Attempt {
        return .{
            .nonce_retries = self.nonce_retries,
            .clock_retries = self.clock_retries +| 1,
        };
    }
};

pub const HttpResponse = struct {
    status: u16,
    error_code: ?[]const u8 = null,
    dpop_nonce: ?[]const u8 = null,
    date_header_s: ?i64 = null,
};

pub const TokenResponse = union(enum) {
    offline,
    timeout,
    http: HttpResponse,
};

pub const Step = union(enum) {
    save: SavePlan,
    retry_with_nonce: NonceRetry,
    retry_with_clock: ClockRetry,
    clear_login,
    keep_and_fail,

    pub const SavePlan = struct {
        dpop_nonce: ?[]const u8 = null,
    };

    pub const NonceRetry = struct {
        dpop_nonce: []const u8,
    };

    pub const ClockRetry = struct {
        server_time_s: i64,
    };
};

/// Chooses the next step after one `POST /token` refresh attempt.
pub fn onTokenResponse(attempt: Attempt, response: TokenResponse) Step {
    return switch (response) {
        // Never clear saved tokens on offline or timeout (`tests/tla/gemini_auth/GeminiDpopRefresh.tla` ClearOnlyWithCause).
        .offline, .timeout => .keep_and_fail,
        .http => |http| onHttpResponse(attempt, http),
    };
}

fn onHttpResponse(attempt: Attempt, http: HttpResponse) Step {
    if (http.status == 200) {
        return .{ .save = .{ .dpop_nonce = nonEmpty(http.dpop_nonce) } };
    }
    if (http.status != 400) {
        // Keep stored tokens on 429, 5xx, and unexpected HTTP statuses (`tests/tla/gemini_auth/GeminiDpopRefresh.tla` ClearOnlyWithCause).
        return .keep_and_fail;
    }

    const code = http.error_code orelse return .keep_and_fail;
    if (std.mem.eql(u8, code, "use_dpop_nonce")) {
        // Retry at most once per refresh (`tests/tla/gemini_auth/GeminiDpopRefresh.tla` NonceRetryAtMostOnce).
        if (attempt.nonce_retries >= max_nonce_retries) return .keep_and_fail;
        const nonce = nonEmpty(http.dpop_nonce) orelse return .keep_and_fail;
        return .{ .retry_with_nonce = .{ .dpop_nonce = nonce } };
    }
    if (std.mem.eql(u8, code, "invalid_dpop_proof")) {
        if (attempt.clock_retries >= max_clock_retries) return .keep_and_fail;
        const server_time_s = http.date_header_s orelse return .keep_and_fail;
        return .{ .retry_with_clock = .{ .server_time_s = server_time_s } };
    }
    // Clear the saved login only on explicit grant or client revocation (`tests/tla/gemini_auth/GeminiDpopRefresh.tla` ClearOnlyWithCause).
    if (std.mem.eql(u8, code, "invalid_grant") or std.mem.eql(u8, code, "unauthorized_client")) {
        return .clear_login;
    }
    return .keep_and_fail;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const slice = value orelse return null;
    return if (slice.len == 0) null else slice;
}

const testing = std.testing;

test "decide requires sign-in when no login is saved" {
    try testing.expectEqual(Decision.sign_in_required, decide(null, null, 1_000));
}

test "decide requires sign-in when the 7-day grant has expired" {
    const expired_at_now: SavedAccess = .{
        .access_token = "ya29.fresh",
        .access_token_expires_at_s = 5_000,
        .refresh_token_expires_at_s = 1_000,
    };
    try testing.expectEqual(Decision.sign_in_required, decide(expired_at_now, null, 1_000));

    const expired_before: SavedAccess = .{
        .access_token = "ya29.fresh",
        .access_token_expires_at_s = 5_000,
        .refresh_token_expires_at_s = 999,
    };
    try testing.expectEqual(Decision.sign_in_required, decide(expired_before, null, 1_000));

    const last_second: SavedAccess = .{
        .access_token = "ya29.fresh",
        .access_token_expires_at_s = 5_000,
        .refresh_token_expires_at_s = 1_001,
    };
    try testing.expectEqual(Decision.adopt, decide(last_second, null, 1_000));
}

test "decide adopts a live saved token written by another process" {
    const saved: SavedAccess = .{
        .access_token = "ya29.peer-saved",
        .access_token_expires_at_s = 1_000 + refresh_margin_s + 1,
        .refresh_token_expires_at_s = 100_000,
    };
    try testing.expectEqual(Decision.adopt, decide(saved, "ya29.old-rejected", 1_000));
    try testing.expectEqual(Decision.adopt, decide(saved, null, 1_000));
}

test "decide refreshes when the saved token equals the rejected one" {
    const saved: SavedAccess = .{
        .access_token = "ya29.rejected",
        .access_token_expires_at_s = 10_000,
        .refresh_token_expires_at_s = 100_000,
    };
    try testing.expectEqual(Decision.refresh, decide(saved, "ya29.rejected", 1_000));
}

test "decide refreshes when 300 seconds or fewer remain on the access token" {
    const at_margin: SavedAccess = .{
        .access_token = "ya29.near-expiry",
        .access_token_expires_at_s = 1_000 + refresh_margin_s,
        .refresh_token_expires_at_s = 100_000,
    };
    try testing.expectEqual(Decision.refresh, decide(at_margin, null, 1_000));

    const under_margin: SavedAccess = .{
        .access_token = "ya29.near-expiry",
        .access_token_expires_at_s = 1_000 + refresh_margin_s - 1,
        .refresh_token_expires_at_s = 100_000,
    };
    try testing.expectEqual(Decision.refresh, decide(under_margin, null, 1_000));
}

test "onTokenResponse saves on 200 with or without a rotated nonce" {
    const without_nonce = onTokenResponse(.{}, .{ .http = .{ .status = 200 } });
    try testing.expectEqual(Step{ .save = .{ .dpop_nonce = null } }, without_nonce);

    const empty_nonce = onTokenResponse(.{}, .{ .http = .{ .status = 200, .dpop_nonce = "" } });
    try testing.expectEqual(Step{ .save = .{ .dpop_nonce = null } }, empty_nonce);

    const with_nonce = onTokenResponse(.{}, .{ .http = .{ .status = 200, .dpop_nonce = "nonce-2" } });
    try testing.expectEqualDeep(Step{ .save = .{ .dpop_nonce = "nonce-2" } }, with_nonce);
}

test "onTokenResponse retries once on 400 use_dpop_nonce with a DPoP-Nonce header" {
    const step = onTokenResponse(.{}, .{ .http = .{
        .status = 400,
        .error_code = "use_dpop_nonce",
        .dpop_nonce = "fresh-nonce",
    } });
    try testing.expectEqualDeep(Step{ .retry_with_nonce = .{ .dpop_nonce = "fresh-nonce" } }, step);

    const missing_nonce = onTokenResponse(.{}, .{ .http = .{
        .status = 400,
        .error_code = "use_dpop_nonce",
        .dpop_nonce = null,
    } });
    try testing.expectEqual(Step.keep_and_fail, missing_nonce);
}

test "onTokenResponse returns keep_and_fail on a second use_dpop_nonce after a retry" {
    const first = Attempt{};
    const second = first.afterNonceRetry();
    const step = onTokenResponse(second, .{ .http = .{
        .status = 400,
        .error_code = "use_dpop_nonce",
        .dpop_nonce = "newer-nonce",
    } });
    try testing.expectEqual(Step.keep_and_fail, step);
}

test "onTokenResponse retries once on invalid_dpop_proof with server time from Date" {
    const step = onTokenResponse(.{}, .{ .http = .{
        .status = 400,
        .error_code = "invalid_dpop_proof",
        .date_header_s = 1_700_000_123,
    } });
    try testing.expectEqual(Step{ .retry_with_clock = .{ .server_time_s = 1_700_000_123 } }, step);

    const missing_date = onTokenResponse(.{}, .{ .http = .{
        .status = 400,
        .error_code = "invalid_dpop_proof",
        .date_header_s = null,
    } });
    try testing.expectEqual(Step.keep_and_fail, missing_date);

    const second = (Attempt{}).afterClockRetry();
    const repeat = onTokenResponse(second, .{ .http = .{
        .status = 400,
        .error_code = "invalid_dpop_proof",
        .date_header_s = 1_700_000_124,
    } });
    try testing.expectEqual(Step.keep_and_fail, repeat);
}

test "onTokenResponse clears login only on invalid_grant or unauthorized_client" {
    try testing.expectEqual(Step.clear_login, onTokenResponse(.{}, .{ .http = .{
        .status = 400,
        .error_code = "invalid_grant",
    } }));
    try testing.expectEqual(Step.clear_login, onTokenResponse(.{}, .{ .http = .{
        .status = 400,
        .error_code = "unauthorized_client",
    } }));
    try testing.expectEqual(Step.keep_and_fail, onTokenResponse(.{}, .{ .http = .{
        .status = 400,
        .error_code = "invalid_request",
    } }));
}

test "onTokenResponse keeps login on offline, timeout, 429, and 5xx" {
    try testing.expectEqual(Step.keep_and_fail, onTokenResponse(.{}, .offline));
    try testing.expectEqual(Step.keep_and_fail, onTokenResponse(.{}, .timeout));
    try testing.expectEqual(Step.keep_and_fail, onTokenResponse(.{}, .{ .http = .{ .status = 429 } }));
    try testing.expectEqual(Step.keep_and_fail, onTokenResponse(.{}, .{ .http = .{ .status = 500 } }));
    try testing.expectEqual(Step.keep_and_fail, onTokenResponse(.{}, .{ .http = .{ .status = 502 } }));
    try testing.expectEqual(Step.keep_and_fail, onTokenResponse(.{}, .{ .http = .{ .status = 503 } }));
}
