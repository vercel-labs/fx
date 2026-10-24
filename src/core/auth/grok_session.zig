const std = @import("std");
const profile_paths = @import("../shared/profile_paths.zig");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");
const subscription_session = @import("subscription_session.zig");

const store = subscription_session.Store(.{
    .auth_file_name = profile_paths.grok_auth_file_name,
    .mutation_lock_file_name = "grok-auth.lock",
    .trace_label = "Grok",
}, error.InvalidGrokAuthSession, error.GrokOAuthUnavailable);

pub const Session = store.Session;
pub const Mutation = store.Mutation;
pub const DeleteOutcome = subscription_session.DeleteOutcome;
pub const presence = store.presence;
pub const requireSignInStorage = store.requireSignInStorage;
pub const refreshDeadlineMs = subscription_session.refreshDeadlineMs;
pub const load = store.load;
pub const saveNewSession = store.saveNewSession;
pub const beginExistingMutation = store.beginExistingMutation;

pub fn validAccountId(account_id: []const u8) bool {
    return types.validCredentialAccountId(account_id);
}

test "Grok account identity is bounded and safe for HTTP headers" {
    try std.testing.expect(validAccountId("acct_123"));
    try std.testing.expect(!validAccountId(""));
    try std.testing.expect(!validAccountId("acct\r\ninjected"));
    try std.testing.expect(!validAccountId(text_utils.repeat("a", 1025)));

    const invalid =
        \\{"version":1,"access_token":"access","refresh_token":"refresh","expires_at_ms":1234,"account_id":"acct\ninjected"}
    ;
    try std.testing.expectError(error.InvalidGrokAuthSession, store.parse(std.testing.allocator, invalid));
}
