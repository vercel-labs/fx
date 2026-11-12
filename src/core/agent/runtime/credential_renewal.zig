//! Renews a credential the provider rejected with 401, for one more send.
//! Every fx process shares a sign-in, so the store is read first, and a
//! refresh is forced only while the store still holds the rejected token: each
//! forced refresh rotates the sign-in for all of them.

const std = @import("std");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const secret = @import("../../auth/secret.zig");
const credentials = @import("../../auth/credentials.zig");
const runtime_deps = @import("deps.zig");

const Allocator = std.mem.Allocator;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const CredentialRefreshMode = runtime_deps.CredentialRefreshMode;
const RefreshedGatewayCredential = runtime_deps.RefreshedGatewayCredential;
const TraceContext = debug_trace.TraceContext;

/// The sign-in a request sent. Borrowed.
pub const SignIn = struct {
    source: ?types.CredentialSource,
    account_id: ?[]const u8 = null,
};

/// What the host gave after a 401. Both credentials are owned by the caller;
/// adopt `stored` first and then `forced`, or `free` them.
pub const Renewal = struct {
    /// The stored credential; null when the host holds none this sign-in can
    /// send.
    stored: ?RefreshedGatewayCredential = null,
    /// The forced refresh's credential, asked for only while the store still
    /// held the rejected token; null when there was none.
    forced: ?RefreshedGatewayCredential = null,
    /// Whether the newest credential differs from the rejected token, so one
    /// more send can work.
    resend: bool = false,

    /// The forced credential when there is one, else the stored one.
    pub fn newest(self: Renewal) ?RefreshedGatewayCredential {
        return self.forced orelse self.stored;
    }
};

pub fn free(alloc: Allocator, credential: RefreshedGatewayCredential) void {
    secret.zeroAndFree(alloc, credential.token);
    if (credential.gateway_team) |team| alloc.free(team);
    if (credential.gateway_team_label) |label| alloc.free(label);
}

/// The sign-in's credential from the host in `mode`, owned by the caller.
/// Null when its source is not refreshable, the host holds none, or the host
/// refused it, such as a stored sign-in for another account or team.
pub fn load(
    deps: *const AgentRuntimeDeps,
    alloc: Allocator,
    sign_in: SignIn,
    mode: CredentialRefreshMode,
    trace_ctx: TraceContext,
) Allocator.Error!?RefreshedGatewayCredential {
    const source = sign_in.source orelse return null;
    if (!credentials.sourceRefreshable(source)) return null;
    const refresh = deps.refresh_gateway_credential orelse return null;
    return refresh(deps.ctx, alloc, source, mode, sign_in.account_id) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.eventf(
            "gateway",
            "credential_refresh_failed",
            trace_ctx,
            "source={s} mode={s} err={s}",
            .{ @tagName(source), @tagName(mode), @errorName(err) },
        );
        return null;
    };
}

/// The stored credential when another fx process already replaced
/// `rejected`, and a forced refresh only while the store still holds it
/// (`tests/e2e/auth-refresh.test.ts` "fx ask replays a rejected request with
/// the login another fx already renewed, without refreshing"). When the store
/// holds nothing this sign-in can send, such as another team's sign-in,
/// nothing is refreshed (`tests/e2e/auth-refresh.test.ts` "fx ask does not
/// refresh the login another fx signed in to another team when its request is
/// rejected"). `rejected` must be the caller's own copy: a host can free its
/// key while it loads the stored one.
pub fn renewRejected(
    deps: *const AgentRuntimeDeps,
    alloc: Allocator,
    sign_in: SignIn,
    rejected: []const u8,
    trace_ctx: TraceContext,
) Allocator.Error!Renewal {
    const stored = (try load(deps, alloc, sign_in, .reload, trace_ctx)) orelse {
        debug_trace.eventf("gateway", "credential_renewal_skipped", trace_ctx, "reason=no_usable_stored_credential", .{});
        return .{};
    };
    errdefer free(alloc, stored);
    if (!std.mem.eql(u8, stored.token, rejected)) return .{ .stored = stored, .resend = true };
    const forced = (try load(deps, alloc, sign_in, .force, trace_ctx)) orelse return .{ .stored = stored };
    return .{ .stored = stored, .forced = forced, .resend = true };
}
