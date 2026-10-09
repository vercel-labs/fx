//! What fx plugs into the usage module.
//!
//! Each part is a context pointer and a vtable that fx implements. The module
//! calls them from its worker task (src/usage/io/worker.zig) as well as from
//! the thread that reports a call, so implementations must be thread-safe.
//! None of them may call back into the module.
//!
//! - `Lookup` is fx's AI Gateway GET transport for cost lookups and usage
//!   reports (`client.fetchGatewayUsageResult`). It owns trusted origins,
//!   timeouts, the user agent, and the E2E loopback override.
//! - `SessionSink` persists a session checkpoint: a snapshot the host
//!   encodes with the writer for the format it stores. Session files stay
//!   the session store's.
//! - `Credential` is what the host pushes when its credential changes. The
//!   module keeps the secret in memory only, compares credentials by their
//!   SHA-256 digest, and never persists, traces, or logs either.

const std = @import("std");
const core = @import("core/ledger.zig");
const snapshot = @import("codec/snapshot.zig");

/// One AI Gateway GET, `<origin><path>`: a cost lookup or a usage report.
pub const Lookup = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Whether `origin` is one the host trusts with a credential, as
        /// fx's `isTrustedGenerationOrigin`: the production Gateway or a
        /// loopback `http` override. The module asks before every fetch and
        /// rejects the lookup of an origin the host doesn't trust.
        trusted: *const fn (context: *anyopaque, origin: []const u8) bool,
        /// Sends one GET for `request.path` and reads the whole body into
        /// `body`. Blocks
        /// until the answer is read, the transport fails, or `request.cancel`
        /// is set; then returns `error.Canceled` promptly (the module's
        /// shutdown budget is 250 ms). Never logs `request.secret`.
        fetch: *const fn (context: *anyopaque, request: *const Request, body: []u8) FetchError!Response,
    };

    /// Every slice is borrowed for the call only.
    pub const Request = struct {
        /// Already checked with `trusted`.
        origin: []const u8,
        /// The path and query under `origin`, built by the module: a cost
        /// lookup, `/v1/generation?id=` and a generation id, or a usage
        /// report, `/v1/report?` and URL-safe parameters.
        path: []const u8,
        /// Sent as `x-vercel-ai-gateway-team` when present.
        team: ?[]const u8,
        /// The bearer token, or null for host-managed auth (no
        /// `Authorization` header).
        secret: ?[]const u8,
        cancel: *const std.atomic.Value(bool),
    };

    pub const Response = struct {
        status: u16,
        /// Bytes of the body written to the start of `body`.
        body_len: usize,
    };

    pub const FetchError = error{
        /// `request.cancel` was set, or the task was canceled.
        Canceled,
        /// No answer: connection, TLS, timeout, or a broken body.
        Transport,
        /// The body didn't fit in `body`.
        BodyTooLarge,
    };

    pub fn trusted(lookup: Lookup, origin: []const u8) bool {
        return lookup.vtable.trusted(lookup.context, origin);
    }

    /// Checks the host kept its side of the contract: a body length past
    /// the buffer is a transport failure, never a slice past the buffer.
    pub fn fetch(lookup: Lookup, request: *const Request, body: []u8) FetchError!Response {
        const response = try lookup.vtable.fetch(lookup.context, request, body);
        if (response.body_len > body.len) return error.Transport;
        return response;
    }
};

/// Persists session checkpoints: the sidecar, a v2 `set usage`, or a state
/// blob, whichever the session store keeps.
pub const SessionSink = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Durable when it returns. Called with the module's checkpoint lock
        /// held, so checkpoints arrive one at a time, in order. Must not
        /// retain `checkpoint`.
        persist: *const fn (context: *anyopaque, checkpoint: *const Checkpoint) PersistError!void,
    };

    pub const PersistError = error{PersistFailed};

    pub fn persist(sink: SessionSink, checkpoint: *const Checkpoint) PersistError!void {
        return sink.vtable.persist(sink.context, checkpoint);
    }
};

/// One checkpoint: the session snapshot and its time. Holds no credential,
/// no digest, and no blocked state, which are runtime-only. Borrowed for
/// the `persist` call only.
pub const Checkpoint = struct {
    /// 1 for the session's first checkpoint in this run, then one more each time.
    number: u64,
    /// Wall-clock time, strictly after the previous checkpoint's.
    at_ms: i64,
    snapshot: *const snapshot.Snapshot,

    pub const WriteError = snapshot.WriteError;
    pub const EncodeError = std.mem.Allocator.Error || snapshot.ValidateError || error{InvalidGenerationFact};

    /// The rich shape (schema 3), as v3 rich events and sidecars hold it.
    pub fn writeRich(checkpoint: *const Checkpoint, writer: *std.Io.Writer) WriteError!void {
        return snapshot.writeRich(writer, checkpoint.snapshot.*);
    }

    /// The 18-key shape older binaries read in v3 events and state blobs.
    pub fn writeLegacy18(checkpoint: *const Checkpoint, writer: *std.Io.Writer) WriteError!void {
        return snapshot.writeLegacy18(writer, checkpoint.snapshot.*);
    }

    /// The v1 sidecar `sessions/<id>/usage-v2.json`. The caller owns the bytes.
    pub fn encodeSidecar(checkpoint: *const Checkpoint, gpa: std.mem.Allocator, session_id: []const u8) (EncodeError || error{UsageSidecarTooLarge})![]u8 {
        return snapshot.encodeSidecar(gpa, session_id, checkpoint.snapshot.*);
    }

    /// The sessions-v2 `set usage` value. The caller owns the bytes.
    pub fn encodeV2Value(checkpoint: *const Checkpoint, gpa: std.mem.Allocator) EncodeError![]u8 {
        return snapshot.encodeV2Value(gpa, checkpoint.snapshot.*, checkpoint.at_ms);
    }
};

/// The credential lookups run with.
pub const Credential = union(enum) {
    /// No credential: lookups wait until one arrives.
    signed_out,
    /// An AI Gateway API key, a Vercel OIDC token, or an `fx login` token,
    /// sent as `Authorization: Bearer`. Borrowed for the call; the module
    /// copies it. At most `max_secret_bytes`, and not empty.
    bearer: []const u8,
    /// The host authenticates lookups itself, so no `Authorization` header
    /// is sent. It is one fixed credential, as in today's fx.
    host_managed,

    pub const max_secret_bytes = 8 * 1024;

    /// Today's fx digest for host-managed auth (`session_usage.zig:3318`).
    pub const host_managed_input = "fx-host-managed-auth-v1";

    pub const Error = error{InvalidCredential};

    /// The digest the ledger compares credentials by, or null when signed out.
    pub fn digest(credential: Credential) Error!?core.Digest {
        return switch (credential) {
            .signed_out => null,
            .bearer => |secret| if (secret.len == 0 or secret.len > max_secret_bytes)
                error.InvalidCredential
            else
                core.credentialDigest(secret),
            .host_managed => core.credentialDigest(host_managed_input),
        };
    }
};

test "a credential is compared by the SHA-256 of its secret" {
    const a = (try Credential.digest(.{ .bearer = "vck_one" })).?;
    const b = (try Credential.digest(.{ .bearer = "vck_two" })).?;
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    var expected: core.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash("vck_one", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &a);
    try std.testing.expectEqual(@as(?core.Digest, null), try Credential.digest(.signed_out));
    const managed = (try Credential.digest(.host_managed)).?;
    try std.testing.expectEqualSlices(u8, &core.credentialDigest("fx-host-managed-auth-v1"), &managed);
}

test "an empty or oversized secret is refused" {
    try std.testing.expectError(error.InvalidCredential, Credential.digest(.{ .bearer = "" }));
    const long = [_]u8{'k'} ** (Credential.max_secret_bytes + 1);
    try std.testing.expectError(error.InvalidCredential, Credential.digest(.{ .bearer = &long }));
}

test "a fetch that reports more body than the buffer holds is a transport failure" {
    const Liar = struct {
        fn trusted(_: *anyopaque, _: []const u8) bool {
            return true;
        }
        fn fetch(_: *anyopaque, _: *const Lookup.Request, body: []u8) Lookup.FetchError!Lookup.Response {
            return .{ .status = 200, .body_len = body.len + 1 };
        }
    };
    var dummy: u8 = 0;
    const lookup: Lookup = .{ .context = &dummy, .vtable = &.{ .trusted = Liar.trusted, .fetch = Liar.fetch } };
    var cancel: std.atomic.Value(bool) = .init(false);
    var body: [4]u8 = undefined;
    const request: Lookup.Request = .{ .origin = "http://127.0.0.1:1", .path = "/v1/generation?id=gen_x", .team = null, .secret = null, .cancel = &cancel };
    try std.testing.expectError(error.Transport, lookup.fetch(&request, &body));
}
