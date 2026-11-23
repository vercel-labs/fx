//! Signs out of a subscription login (Codex, Grok): deletes the saved login,
//! keeps its refresh token for a retry, then revokes it. Also retries kept sign-outs.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const pending_revocation = @import("pending_revocation.zig");
const secret = @import("secret.zig");
const subscription_session = @import("subscription_session.zig");

const Allocator = std.mem.Allocator;

pub const LogoutResult = struct {
    deletion: subscription_session.DeleteOutcome,
    revocation_failed: bool,
    /// The unconfirmed revocation's token is kept, and fx revokes it later
    /// (`pending_revocation`).
    retry_kept: bool = false,
};

/// A deleted subscription login, with its refresh token kept for the revocation.
pub const LocalLogout = struct {
    result: LogoutResult,
    /// Owned by the caller; release it with `secret.zeroAndFree`.
    refresh_token: ?[]u8 = null,
    /// Whether `refresh_token` is kept to revoke later (`pending_revocation`).
    /// Forget it once its revocation is confirmed.
    kept: bool = false,
};

/// `store` is the provider's session module, `revoke` its `revokeToken`, and
/// `trace_label` the provider's name in debug trace lines.
pub fn Provider(
    comptime store: type,
    comptime source: pending_revocation.Source,
    comptime revoke: anytype,
    comptime trace_label: []const u8,
) type {
    return struct {
        pub fn logout(
            alloc: Allocator,
            transport: oauth_transport.Provider,
            before_revocation: ?oauth.BeforeRevocation,
        ) !LogoutResult {
            return logoutIn(alloc, pending_revocation.Place.of(source), transport, before_revocation);
        }

        /// Deletes the saved login without contacting the provider; the caller revokes the returned token, then releases it.
        pub fn logoutLocally(alloc: Allocator) !LocalLogout {
            return logoutLocallyIn(alloc, pending_revocation.Place.of(source));
        }

        /// Revokes the sign-outs that earlier logouts kept because the provider did not confirm them (`pending_revocation.retry`).
        pub fn retryKeptSignOuts(
            alloc: Allocator,
            transport: oauth_transport.Provider,
            before_revocation: ?oauth.BeforeRevocation,
        ) pending_revocation.RetryOutcome {
            return pending_revocation.retry(alloc, source, .{ .context = &transport, .run = revokeKept }, before_revocation);
        }

        fn revokeKept(context: *const anyopaque, alloc: Allocator, tokens: pending_revocation.Tokens) anyerror!void {
            const transport: *const oauth_transport.Provider = @ptrCast(@alignCast(context));
            return revoke(alloc, transport.*, tokens.refresh_token);
        }

        fn logoutIn(
            alloc: Allocator,
            place: pending_revocation.Place,
            transport: oauth_transport.Provider,
            before_revocation: ?oauth.BeforeRevocation,
        ) !LogoutResult {
            const local = try logoutLocallyIn(alloc, place);
            defer if (local.refresh_token) |token| secret.zeroAndFree(alloc, token);
            var result = local.result;
            if (local.refresh_token) |token| {
                if (before_revocation) |notice| notice.run(notice.context);
                revoke(alloc, transport, token) catch |err| {
                    debug_trace.logf("auth", "{s} logout revocation failed err={s}", .{ trace_label, @errorName(err) });
                    result.revocation_failed = true;
                    result.retry_kept = local.kept and pending_revocation.retryable(err);
                    if (local.kept and !result.retry_kept) pending_revocation.forgetIn(alloc, place, token);
                    return result;
                };
                if (local.kept) pending_revocation.forgetIn(alloc, place, token);
            }
            return result;
        }

        /// Deletes the saved login first, so a failed deletion never leaves a revoked token on disk.
        fn logoutLocallyIn(alloc: Allocator, place: pending_revocation.Place) !LocalLogout {
            var mutation = (try store.beginExistingMutation()) orelse return .{ .result = .{
                .deletion = .missing,
                .revocation_failed = false,
            } };
            defer mutation.deinit();
            var revocation_failed = false;
            var refresh_token: ?[]u8 = null;
            errdefer if (refresh_token) |token| secret.zeroAndFree(alloc, token);
            var kept = false;
            const loaded_session = mutation.load(alloc) catch |err| blk: {
                debug_trace.logf("auth", "{s} logout could not load the saved credential err={s}", .{ trace_label, @errorName(err) });
                revocation_failed = true;
                break :blk null;
            };
            if (loaded_session) |loaded| {
                var session = loaded;
                defer session.deinit(alloc);
                refresh_token = try alloc.dupe(u8, session.refresh_token);
                // Kept before the login is deleted, so a revocation that never
                // completes still leaves the token for a later retry.
                kept = pending_revocation.keepIn(alloc, place, .{ .refresh_token = session.refresh_token });
            }
            const deletion = mutation.delete() catch |err| {
                // The login is still saved, so its token must not be revoked later.
                if (kept) pending_revocation.forgetIn(alloc, place, refresh_token.?);
                return err;
            };
            return .{
                .result = .{
                    .deletion = deletion,
                    .revocation_failed = revocation_failed,
                },
                .refresh_token = refresh_token,
                .kept = kept,
            };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const saved_token = "refresh-1";
const max_token_bytes = 64;

/// Set only by test g, which reads the kept state while the fake delete runs.
/// Zig runs the tests of this file one at a time on one thread, and test g
/// clears it before it returns.
var delete_probe: ?DeleteProbe = null;

const DeleteProbe = struct {
    place: pending_revocation.Place,
    ran: bool = false,
};

const FakeLogin = struct {
    saved: bool = true,
    load_error: ?anyerror = null,
    delete_error: ?anyerror = null,
};

fn FakeStore(comptime login: FakeLogin) type {
    return struct {
        pub const Session = struct {
            refresh_token: []u8,

            pub fn deinit(self: *Session, alloc: Allocator) void {
                alloc.free(self.refresh_token);
                self.* = undefined;
            }
        };

        pub const Mutation = struct {
            pub fn load(self: *Mutation, alloc: Allocator) !?Session {
                _ = self;
                if (login.load_error) |err| return err;
                return .{ .refresh_token = try alloc.dupe(u8, saved_token) };
            }

            pub fn delete(self: *Mutation) !subscription_session.DeleteOutcome {
                _ = self;
                if (login.delete_error) |err| return err;
                if (delete_probe) |*probe| {
                    try pending_revocation.expectKept(probe.place, &.{saved_token});
                    probe.ran = true;
                }
                return .deleted;
            }

            pub fn deinit(self: *Mutation) void {
                self.* = undefined;
            }
        };

        pub fn beginExistingMutation() !?Mutation {
            if (!login.saved) return null;
            return .{};
        }
    };
}

fn FakeProvider(comptime login: FakeLogin) type {
    return Provider(FakeStore(login), .codex, fakeRevoke, "Fake");
}

/// What the fake revoke and the notice saw, and the answer the fake revoke gives.
const Recorder = struct {
    answer: anyerror!void = {},
    revoke_calls: usize = 0,
    notice_runs: usize = 0,
    token_buf: [max_token_bytes]u8 = undefined,
    token_len: usize = 0,

    fn tokenSeen(self: *const Recorder) []const u8 {
        return self.token_buf[0..self.token_len];
    }
};

fn fakeRevoke(alloc: Allocator, transport: oauth_transport.Provider, token: []const u8) !void {
    _ = alloc;
    const recorder: *Recorder = @ptrCast(@alignCast(transport.context.?));
    if (token.len > max_token_bytes) return error.TestTokenTooLong;
    recorder.revoke_calls += 1;
    @memcpy(recorder.token_buf[0..token.len], token);
    recorder.token_len = token.len;
    return recorder.answer;
}

fn countNotice(context: *const anyopaque) void {
    const recorder: *Recorder = @ptrCast(@alignCast(@constCast(context)));
    recorder.notice_runs += 1;
}

fn unusedExecute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) anyerror!oauth_transport.Response {
    _ = raw;
    _ = alloc;
    _ = request;
    return error.TestUnexpectedTransportCall;
}

fn transportFor(recorder: *Recorder) oauth_transport.Provider {
    return .{ .context = recorder, .execute_fn = unusedExecute };
}

fn noticeFor(recorder: *Recorder) oauth.BeforeRevocation {
    return .{ .context = recorder, .run = countNotice };
}

fn tempPlace(tmp: *testing.TmpDir) pending_revocation.Place {
    return .{ .source = .codex, .parent = tmp.dir };
}

test "a logout with no saved login deletes nothing and revokes nothing" {
    const Sign = FakeProvider(.{ .saved = false });
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var recorder: Recorder = .{};
    const result = try Sign.logoutIn(testing.allocator, tempPlace(&tmp), transportFor(&recorder), noticeFor(&recorder));
    try testing.expectEqual(subscription_session.DeleteOutcome.missing, result.deletion);
    try testing.expect(!result.revocation_failed);
    try testing.expectEqual(@as(usize, 0), recorder.revoke_calls);
    try testing.expectEqual(@as(usize, 0), recorder.notice_runs);
}

test "a sign-out the provider confirms leaves nothing kept, sends the saved token once, and runs the notice once" {
    const Sign = FakeProvider(.{});
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var recorder: Recorder = .{};
    const result = try Sign.logoutIn(testing.allocator, tempPlace(&tmp), transportFor(&recorder), noticeFor(&recorder));
    try testing.expectEqual(subscription_session.DeleteOutcome.deleted, result.deletion);
    try testing.expect(!result.revocation_failed);
    try testing.expect(!result.retry_kept);
    try testing.expectEqual(@as(usize, 1), recorder.revoke_calls);
    try testing.expectEqualStrings(saved_token, recorder.tokenSeen());
    try testing.expectEqual(@as(usize, 1), recorder.notice_runs);
    try pending_revocation.expectKept(tempPlace(&tmp), &.{});
}

test "a sign-out the provider refuses for now stays kept for a retry" {
    const Sign = FakeProvider(.{});
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var recorder: Recorder = .{ .answer = error.OAuthRequestFailed };
    const result = try Sign.logoutIn(testing.allocator, tempPlace(&tmp), transportFor(&recorder), noticeFor(&recorder));
    try testing.expectEqual(subscription_session.DeleteOutcome.deleted, result.deletion);
    try testing.expect(result.revocation_failed);
    try testing.expect(result.retry_kept);
    try testing.expectEqual(@as(usize, 1), recorder.revoke_calls);
    try pending_revocation.expectKept(tempPlace(&tmp), &.{saved_token});
}

test "a sign-out the provider can never accept is not kept" {
    const Sign = FakeProvider(.{});
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var recorder: Recorder = .{ .answer = error.RevocationEndpointMissing };
    const result = try Sign.logoutIn(testing.allocator, tempPlace(&tmp), transportFor(&recorder), noticeFor(&recorder));
    try testing.expectEqual(subscription_session.DeleteOutcome.deleted, result.deletion);
    try testing.expect(result.revocation_failed);
    try testing.expect(!result.retry_kept);
    try testing.expectEqual(@as(usize, 1), recorder.revoke_calls);
    try pending_revocation.expectKept(tempPlace(&tmp), &.{});
}

test "a saved login that cannot be read is deleted and revokes nothing" {
    const Sign = FakeProvider(.{ .load_error = error.FakeLoadFailed });
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var recorder: Recorder = .{};
    const result = try Sign.logoutIn(testing.allocator, tempPlace(&tmp), transportFor(&recorder), noticeFor(&recorder));
    try testing.expectEqual(subscription_session.DeleteOutcome.deleted, result.deletion);
    try testing.expect(result.revocation_failed);
    try testing.expectEqual(@as(usize, 0), recorder.revoke_calls);
    try testing.expectEqual(@as(usize, 0), recorder.notice_runs);
}

test "a logout whose deletion fails returns the error, keeps nothing, and frees the token it read" {
    const Sign = FakeProvider(.{ .delete_error = error.FakeDeleteFailed });
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expectError(error.FakeDeleteFailed, Sign.logoutLocallyIn(testing.allocator, tempPlace(&tmp)));
    try pending_revocation.expectKept(tempPlace(&tmp), &.{});
}

test "a saved login is kept for a retry before it is deleted" {
    const Sign = FakeProvider(.{});
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    delete_probe = .{ .place = tempPlace(&tmp) };
    defer delete_probe = null;
    var recorder: Recorder = .{};
    const result = try Sign.logoutIn(testing.allocator, tempPlace(&tmp), transportFor(&recorder), noticeFor(&recorder));
    try testing.expect(delete_probe.?.ran);
    try testing.expectEqual(subscription_session.DeleteOutcome.deleted, result.deletion);
}
