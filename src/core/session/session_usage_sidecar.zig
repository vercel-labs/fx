const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const generation_usage = @import("generation_usage_provider.zig");
const session_usage = @import("session_usage.zig");

const Allocator = std.mem.Allocator;

pub const sidecar_file = "usage-v2.json";
pub const max_sidecar_bytes: usize = session_usage.max_snapshot_bytes + 512;

pub const RestoreOutcome = enum {
    missing,
    restored,
    invalid,
    mismatched,
};

pub const PendingConnectionAuthority = union(enum) {
    historical_vercel,
    current: []const u8,
};

pub const Captured = union(enum) {
    missing,
    invalid: []const u8,
    encoded: []u8,

    pub fn deinit(self: *Captured, alloc: Allocator) void {
        switch (self.*) {
            .encoded => |bytes| alloc.free(bytes),
            .missing, .invalid => {},
        }
        self.* = undefined;
    }
};

const Decoded = struct {
    session_id: []u8,
    snapshot: session_usage.Snapshot,

    fn deinit(self: *Decoded, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

pub fn write(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    snapshot: session_usage.Snapshot,
) !void {
    const encoded = try encode(alloc, session_id, snapshot);
    defer alloc.free(encoded);
    try writeEncoded(alloc, session_dir, encoded);
}

pub fn encode(
    alloc: Allocator,
    session_id: []const u8,
    snapshot: session_usage.Snapshot,
) ![]u8 {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try encoded.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &encoded.writer);
    try encoded.writer.writeAll(",\"snapshot\":");
    try session_usage.writeRichSnapshot(&encoded.writer, snapshot);
    try encoded.writer.writeByte('}');
    if (encoded.written().len > max_sidecar_bytes) {
        return error.UsageSidecarTooLarge;
    }
    return try encoded.toOwnedSlice();
}

pub fn writeEncoded(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    encoded: []const u8,
) !void {
    if (encoded.len == 0 or encoded.len > max_sidecar_bytes) {
        return error.UsageSidecarTooLarge;
    }
    try io_mod.durableReplaceVerified(
        alloc,
        session_dir,
        sidecar_file,
        encoded,
    );
}

pub fn capture(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
) Allocator.Error!Captured {
    const initial = session_dir.dir.statFile(io_mod.getIo(), sidecar_file, .{
        .follow_symlinks = false,
    }) catch |err| {
        if (err == error.FileNotFound) return .missing;
        return .{ .invalid = @errorName(err) };
    };
    if (initial.kind != .file or initial.nlink != 1 or
        initial.permissions.toMode() & 0o777 != 0o600)
    {
        return .{ .invalid = "unsafe_initial_shape" };
    }
    if (initial.size == 0) return .{ .invalid = "empty" };
    if (initial.size > max_sidecar_bytes) return .{ .invalid = "oversized" };

    var file = session_dir.dir.openFile(io_mod.getIo(), sidecar_file, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.FileNotFound) return .missing;
        return .{ .invalid = @errorName(err) };
    };
    defer file.close(io_mod.getIo());
    const verified = file.stat(io_mod.getIo()) catch |err|
        return .{ .invalid = @errorName(err) };
    if (verified.kind != .file or verified.nlink != 1 or
        verified.permissions.toMode() & 0o777 != 0o600)
    {
        return .{ .invalid = "unsafe_verified_shape" };
    }
    if (verified.size != initial.size) return .{ .invalid = "changed_during_open" };
    const bytes = io_mod.readFileToEnd(
        alloc,
        &file,
        max_sidecar_bytes,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .invalid = @errorName(err) };
    };
    return .{ .encoded = bytes };
}

pub fn restoreIfMatching(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    continuity_at_ms: i64,
    pending_authority: PendingConnectionAuthority,
    durable: *session_usage.Snapshot,
) !RestoreOutcome {
    var captured = try capture(alloc, session_dir);
    defer captured.deinit(alloc);
    return restoreCaptured(
        alloc,
        captured,
        session_id,
        continuity_at_ms,
        pending_authority,
        durable,
    );
}

pub fn restoreCaptured(
    alloc: Allocator,
    captured: Captured,
    session_id: []const u8,
    continuity_at_ms: i64,
    pending_authority: PendingConnectionAuthority,
    durable: *session_usage.Snapshot,
) !RestoreOutcome {
    const bytes = switch (captured) {
        .missing => {
            try recoverCanonicalFallback(
                alloc,
                durable,
                continuity_at_ms,
                pending_authority,
            );
            return .missing;
        },
        .invalid => |reason| {
            debug_trace.logf(
                "session",
                "event=usage_sidecar_invalid reason={s}",
                .{reason},
            );
            try recoverCanonicalFallback(
                alloc,
                durable,
                continuity_at_ms,
                pending_authority,
            );
            return .invalid;
        },
        .encoded => |value| value,
    };
    var decoded = decode(alloc, bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        traceInvalid(err);
        try recoverCanonicalFallback(
            alloc,
            durable,
            continuity_at_ms,
            pending_authority,
        );
        return .invalid;
    };
    var decoded_owned = true;
    defer if (decoded_owned) decoded.deinit(alloc);
    if (!std.mem.eql(u8, decoded.session_id, session_id)) {
        traceInvalid(error.UsageSidecarSessionMismatch);
        try recoverCanonicalFallback(
            alloc,
            durable,
            continuity_at_ms,
            pending_authority,
        );
        return .invalid;
    }

    if (!pendingConnectionsMatchAuthority(decoded.snapshot, pending_authority)) {
        try recoverCanonicalFallback(
            alloc,
            durable,
            continuity_at_ms,
            pending_authority,
        );
        debug_trace.logf(
            "session",
            "event=usage_sidecar_mismatched reason=pending_connection_changed",
            .{},
        );
        return .mismatched;
    }

    if (!session_usage.billingProjectionEql(
        durable.*,
        decoded.snapshot,
    )) {
        carryRecoveryState(durable, &decoded.snapshot);
        try recoverCanonicalFallback(
            alloc,
            durable,
            continuity_at_ms,
            pending_authority,
        );
        debug_trace.logf(
            "session",
            "event=usage_sidecar_mismatched reason=billing_projection_changed",
            .{},
        );
        return .mismatched;
    }

    if (!session_usage.rollbackProjectionEql(
        durable.*,
        decoded.snapshot,
    )) {
        mergeRichExtensions(durable, &decoded.snapshot);
        return .restored;
    }

    durable.deinit(alloc);
    durable.* = decoded.snapshot;
    alloc.free(decoded.session_id);
    decoded_owned = false;
    return .restored;
}

fn pendingConnectionsMatchAuthority(
    snapshot: session_usage.Snapshot,
    authority: PendingConnectionAuthority,
) bool {
    const connection_id = switch (authority) {
        .historical_vercel => "vercel",
        .current => |value| value,
    };
    for (snapshot.pending) |pending| {
        if (!std.mem.eql(u8, pending.connection_id, connection_id)) return false;
    }
    return true;
}

fn mergeRichExtensions(
    durable: *session_usage.Snapshot,
    rich: *session_usage.Snapshot,
) void {
    durable.reasoning_tokens = rich.reasoning_tokens;
    durable.request_count = rich.request_count;
    for (durable.models, rich.models) |*target, source| {
        target.reasoning_tokens = source.reasoning_tokens;
        target.request_count = source.request_count;
    }
    for (durable.pending, rich.pending) |*target, *source| {
        std.mem.swap([]u8, &target.connection_id, &source.connection_id);
        target.observed_at_ms = source.observed_at_ms;
    }
    carryRecoveryState(durable, rich);
}

fn recoverCanonicalFallback(
    alloc: Allocator,
    durable: *session_usage.Snapshot,
    continuity_at_ms: i64,
    pending_authority: PendingConnectionAuthority,
) !void {
    switch (pending_authority) {
        .historical_vercel => {},
        .current => |connection_id| try session_usage.rebindPendingConnection(
            alloc,
            durable,
            connection_id,
        ),
    }
    try markContinuityGapIfNeeded(alloc, durable, continuity_at_ms);
}

fn markContinuityGapIfNeeded(
    alloc: Allocator,
    durable: *session_usage.Snapshot,
    continuity_at_ms: i64,
) !void {
    if (durable.next_sequence <= 1) return;
    // Missing or unreadable rich state is indistinguishable from a rollback
    // binary advancing billable usage without updating the sidecar. Preserve
    // canonical totals, but qualifies rolling reports that include this gap.
    try session_usage.appendIncidentOwned(alloc, durable, .{
        .occurred_at_ms = @max(continuity_at_ms, 0),
        .completeness = .incomplete,
    });
}

fn carryRecoveryState(
    durable: *session_usage.Snapshot,
    rich: *session_usage.Snapshot,
) void {
    if (durable.publication_backlog.len == 0 and
        rich.publication_backlog.len > 0)
    {
        durable.publication_backlog = rich.publication_backlog;
        rich.publication_backlog = &.{};
    }
    if (durable.incidents.len == 0 and rich.incidents.len > 0) {
        durable.incidents = rich.incidents;
        rich.incidents = &.{};
    }
}

fn decode(alloc: Allocator, bytes: []const u8) !Decoded {
    if (bytes.len == 0 or bytes.len > max_sidecar_bytes) {
        return error.InvalidUsageSidecar;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUsageSidecar,
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 3) {
        return error.InvalidUsageSidecar;
    }
    const schema = parsed.value.object.get("schema_version") orelse
        return error.InvalidUsageSidecar;
    if (schema != .integer or schema.integer != 1) {
        return error.InvalidUsageSidecar;
    }
    const session_id_value = parsed.value.object.get("session_id") orelse
        return error.InvalidUsageSidecar;
    if (session_id_value != .string or session_id_value.string.len == 0) {
        return error.InvalidUsageSidecar;
    }
    const snapshot_value = parsed.value.object.get("snapshot") orelse
        return error.InvalidUsageSidecar;
    if (snapshot_value != .object or
        snapshot_value.object.get("schema_version") == null)
    {
        return error.InvalidUsageSidecar;
    }

    const session_id = try alloc.dupe(u8, session_id_value.string);
    errdefer alloc.free(session_id);
    var snapshot = try session_usage.parseSnapshotValue(alloc, snapshot_value);
    errdefer snapshot.deinit(alloc);
    return .{
        .session_id = session_id,
        .snapshot = snapshot,
    };
}

fn traceInvalid(err: anyerror) void {
    debug_trace.logf(
        "session",
        "event=usage_sidecar_invalid err={s}",
        .{@errorName(err)},
    );
}

fn openTestVerifiedDir(dir: std.Io.Dir) !io_mod.VerifiedDir {
    return .{
        .dir = try dir.openDir(
            io_mod.getIo(),
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ),
    };
}

test "usage sidecar restores rich fields only for its bound session and projection" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = try openTestVerifiedDir(temp.dir);
    defer verified.close();

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        5,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "vercel",
        "https://ai-gateway.vercel.sh",
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "provider/model",
        .total_cost = 0.01,
        .input_tokens = 10,
        .output_tokens = 4,
        .cache_read_tokens = 2,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 0,
    });
    var rich = try usage.snapshot(alloc);
    defer rich.deinit(alloc);
    try write(alloc, &verified, "session-one", rich);

    var legacy_bytes: std.Io.Writer.Allocating = .init(alloc);
    defer legacy_bytes.deinit();
    try session_usage.writeSnapshot(&legacy_bytes.writer, rich);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        legacy_bytes.written(),
        .{},
    );
    defer parsed.deinit();
    var durable = try session_usage.parseSnapshotValue(alloc, parsed.value);
    defer durable.deinit(alloc);

    try std.testing.expectEqual(
        RestoreOutcome.restored,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            20,
            .historical_vercel,
            &durable,
        ),
    );
    try std.testing.expectEqual(@as(?u64, 1), durable.request_count);
    try std.testing.expectEqual(@as(?u64, 3), durable.reasoning_tokens);
    try std.testing.expectEqual(@as(?u64, 1), durable.models[0].request_count);

    try std.testing.expectEqual(
        RestoreOutcome.invalid,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-two",
            21,
            .historical_vercel,
            &durable,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), durable.incidents.len);
    try std.testing.expectEqual(@as(i64, 21), durable.incidents[0].occurred_at_ms);

    var stale = try legacyCopyForTest(alloc, rich);
    defer stale.deinit(alloc);
    stale.next_sequence += 1;
    stale.settled_through_sequence += 1;
    try std.testing.expectEqual(
        RestoreOutcome.mismatched,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            22,
            .historical_vercel,
            &stale,
        ),
    );
    try std.testing.expect(stale.request_count == null);
    try std.testing.expectEqual(@as(usize, 1), stale.incidents.len);
    try std.testing.expectEqual(@as(i64, 22), stale.incidents[0].occurred_at_ms);

    var changed = try legacyCopyForTest(alloc, rich);
    defer changed.deinit(alloc);
    changed.total_cost += 0.01;
    changed.models[0].total_cost += 0.01;
    try std.testing.expectEqual(
        RestoreOutcome.mismatched,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            23,
            .historical_vercel,
            &changed,
        ),
    );
    try std.testing.expect(changed.request_count == null);
    try std.testing.expectEqual(@as(usize, 1), changed.incidents.len);
    try std.testing.expectEqual(@as(i64, 23), changed.incidents[0].occurred_at_ms);
}

test "non-billing rollback changes keep canonical values and rich metrics" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = try openTestVerifiedDir(temp.dir);
    defer verified.close();

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        5,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "vercel",
        "https://ai-gateway.vercel.sh",
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "provider/model",
        .total_cost = 0.01,
        .input_tokens = 10,
        .output_tokens = 4,
        .cache_read_tokens = 2,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 0,
    });
    var rich = try usage.snapshot(alloc);
    defer rich.deinit(alloc);
    try write(alloc, &verified, "session-one", rich);

    var durable = try legacyCopyForTest(alloc, rich);
    defer durable.deinit(alloc);
    durable.wall_duration_ms += 50;
    durable.lines_added = 7;
    durable.lines_removed = 2;

    try std.testing.expectEqual(
        RestoreOutcome.restored,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            20,
            .historical_vercel,
            &durable,
        ),
    );
    try std.testing.expectEqual(@as(u64, rich.wall_duration_ms + 50), durable.wall_duration_ms);
    try std.testing.expectEqual(@as(u64, 7), durable.lines_added);
    try std.testing.expectEqual(@as(u64, 2), durable.lines_removed);
    try std.testing.expectEqual(@as(?u64, 1), durable.request_count);
    try std.testing.expectEqual(@as(?u64, 3), durable.reasoning_tokens);
    try std.testing.expectEqual(@as(usize, 0), durable.incidents.len);
}

test "missing and corrupt sidecars retain current pending connection with one fixed gap" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = try openTestVerifiedDir(temp.dir);
    defer verified.close();
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        1,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "connection-a",
        null,
    );
    var rich = try usage.snapshot(alloc);
    defer rich.deinit(alloc);

    try write(alloc, &verified, "session-one", rich);
    var intact = try legacyCopyForTest(alloc, rich);
    defer intact.deinit(alloc);
    try std.testing.expectEqual(
        RestoreOutcome.restored,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            29,
            .{ .current = "connection-a" },
            &intact,
        ),
    );
    try std.testing.expect(intact.pending[0].lookup_scope == null);
    try std.testing.expectEqual(@as(usize, 0), intact.incidents.len);
    try verified.dir.deleteFile(io_mod.getIo(), sidecar_file);

    var missing = try legacyCopyForTest(alloc, rich);
    defer missing.deinit(alloc);
    try std.testing.expectEqualStrings("vercel", missing.pending[0].connection_id);
    try std.testing.expectEqual(
        RestoreOutcome.missing,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            30,
            .{ .current = "connection-a" },
            &missing,
        ),
    );
    try std.testing.expectEqualStrings("connection-a", missing.pending[0].connection_id);
    try std.testing.expect(missing.pending[0].lookup_scope == null);
    try std.testing.expectEqual(@as(usize, 1), missing.incidents.len);
    try std.testing.expectEqual(@as(i64, 30), missing.incidents[0].occurred_at_ms);

    const Probe = struct {
        resolved_a: usize = 0,
        resolved_vercel: usize = 0,
        calls_a: usize = 0,
        calls_vercel: usize = 0,
        saw_a_credential: bool = false,
        saw_null_scope: bool = false,
        saw_legacy_scope: bool = false,

        fn resolve(
            raw: ?*anyopaque,
            allocator: Allocator,
            reference: generation_usage.CredentialReference,
        ) generation_usage.ResolveCredentialError!generation_usage.ResolvedCredential {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, reference.credential_ref, "credential-a") and
                std.mem.eql(u8, reference.adapter_kind, "adapter-a"))
            {
                self.resolved_a += 1;
            } else if (std.mem.eql(u8, reference.credential_ref, "credential-vercel") and
                std.mem.eql(u8, reference.adapter_kind, "vercel_ai_gateway"))
            {
                self.resolved_vercel += 1;
            } else {
                return error.Unavailable;
            }
            return .{ .token = try allocator.dupe(u8, reference.credential_ref) };
        }

        fn lookupA(
            raw: ?*anyopaque,
            _: Allocator,
            input: generation_usage.LookupInput,
        ) generation_usage.LookupError!generation_usage.LookupOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls_a += 1;
            self.saw_a_credential = std.mem.eql(u8, "credential-a", input.credential);
            self.saw_null_scope = input.lookup_scope == null;
            self.saw_legacy_scope = if (input.lookup_scope) |scope|
                std.mem.eql(u8, scope, "legacy")
            else
                false;
            return .preserve_pending;
        }

        fn lookupVercel(
            raw: ?*anyopaque,
            _: Allocator,
            _: generation_usage.LookupInput,
        ) generation_usage.LookupError!generation_usage.LookupOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls_vercel += 1;
            return .preserve_pending;
        }
    };
    var probe: Probe = .{};
    var dispatch = try generation_usage.Dispatch.init(alloc, &.{
        .{
            .id = "connection-a",
            .adapter_kind = "adapter-a",
            .credential_ref = "credential-a",
            .provider = .{ .context = &probe, .lookup_fn = Probe.lookupA },
        },
        .{
            .id = "vercel",
            .adapter_kind = "vercel_ai_gateway",
            .credential_ref = "credential-vercel",
            .provider = .{ .context = &probe, .lookup_fn = Probe.lookupVercel },
        },
    }, .{ .context = &probe, .resolve_fn = Probe.resolve });
    defer dispatch.deinit(alloc);
    var cancel = std.atomic.Value(bool).init(false);
    var outcome = try dispatch.lookup(
        alloc,
        missing.pending[0].connection_id,
        missing.pending[0].id,
        missing.pending[0].lookup_scope,
        &cancel,
    );
    defer outcome.deinit(alloc);
    switch (outcome) {
        .preserve_pending => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), probe.resolved_a);
    try std.testing.expectEqual(@as(usize, 0), probe.resolved_vercel);
    try std.testing.expectEqual(@as(usize, 1), probe.calls_a);
    try std.testing.expectEqual(@as(usize, 0), probe.calls_vercel);
    try std.testing.expect(probe.saw_a_credential);
    try std.testing.expect(probe.saw_null_scope);

    try std.testing.expectEqual(
        RestoreOutcome.missing,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            30,
            .{ .current = "connection-a" },
            &missing,
        ),
    );
    try std.testing.expectEqualStrings("connection-a", missing.pending[0].connection_id);
    try std.testing.expectEqual(@as(usize, 1), missing.incidents.len);

    try io_mod.durableReplaceVerified(
        alloc,
        &verified,
        sidecar_file,
        "{bad",
    );
    var corrupt = try legacyCopyForTest(alloc, rich);
    defer corrupt.deinit(alloc);
    try std.testing.expectEqual(
        RestoreOutcome.invalid,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            31,
            .{ .current = "connection-a" },
            &corrupt,
        ),
    );
    try std.testing.expectEqualStrings("connection-a", corrupt.pending[0].connection_id);
    try std.testing.expect(corrupt.pending[0].lookup_scope == null);
    try std.testing.expectEqual(@as(usize, 1), corrupt.incidents.len);
    try std.testing.expectEqual(@as(i64, 31), corrupt.incidents[0].occurred_at_ms);

    const valid_sidecar = try encode(alloc, "session-one", rich);
    defer alloc.free(valid_sidecar);
    const wrong_connection = try std.mem.replaceOwned(
        u8,
        alloc,
        valid_sidecar,
        "\"connection_id\":\"connection-a\"",
        "\"connection_id\":\"vercel\"",
    );
    defer alloc.free(wrong_connection);
    try writeEncoded(alloc, &verified, wrong_connection);
    var mismatched = try legacyCopyForTest(alloc, rich);
    defer mismatched.deinit(alloc);
    try std.testing.expectEqualStrings("vercel", mismatched.pending[0].connection_id);
    try std.testing.expectEqual(
        RestoreOutcome.mismatched,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            32,
            .{ .current = "connection-a" },
            &mismatched,
        ),
    );
    try std.testing.expectEqualStrings("connection-a", mismatched.pending[0].connection_id);
    try std.testing.expect(mismatched.pending[0].lookup_scope == null);
    probe = .{};
    var mismatched_outcome = try dispatch.lookup(
        alloc,
        mismatched.pending[0].connection_id,
        mismatched.pending[0].id,
        mismatched.pending[0].lookup_scope,
        &cancel,
    );
    defer mismatched_outcome.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), probe.resolved_a);
    try std.testing.expectEqual(@as(usize, 0), probe.resolved_vercel);
    try std.testing.expectEqual(@as(usize, 1), probe.calls_a);
    try std.testing.expectEqual(@as(usize, 0), probe.calls_vercel);

    try writeEncoded(alloc, &verified, valid_sidecar);
    var historical = try legacyCopyForTest(alloc, rich);
    defer historical.deinit(alloc);
    try std.testing.expectEqual(
        RestoreOutcome.mismatched,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-one",
            33,
            .historical_vercel,
            &historical,
        ),
    );
    try std.testing.expectEqualStrings("vercel", historical.pending[0].connection_id);

    var scoped_usage = session_usage.Usage.initFresh();
    defer scoped_usage.deinit(alloc);
    const scoped_sequence = try scoped_usage.reserveInvocation();
    try scoped_usage.finishObservedInvocation(
        alloc,
        scoped_sequence,
        1,
        .observed_generation,
        "request-legacy",
        "connection-a",
        "legacy",
    );
    var scoped_rich = try scoped_usage.snapshot(alloc);
    defer scoped_rich.deinit(alloc);
    try verified.dir.deleteFile(io_mod.getIo(), sidecar_file);
    var scoped_missing = try legacyCopyForTest(alloc, scoped_rich);
    defer scoped_missing.deinit(alloc);
    probe = .{};
    try std.testing.expectEqual(
        RestoreOutcome.missing,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-two",
            34,
            .{ .current = "connection-a" },
            &scoped_missing,
        ),
    );
    try std.testing.expectEqualStrings("connection-a", scoped_missing.pending[0].connection_id);
    try std.testing.expectEqualStrings("legacy", scoped_missing.pending[0].lookup_scope.?);
    try std.testing.expectEqual(@as(usize, 0), probe.resolved_a);
    try std.testing.expectEqual(@as(usize, 0), probe.resolved_vercel);
    try std.testing.expectEqual(@as(usize, 0), probe.calls_a);
    try std.testing.expectEqual(@as(usize, 0), probe.calls_vercel);

    try io_mod.durableReplaceVerified(alloc, &verified, sidecar_file, "{bad");
    var scoped_corrupt = try legacyCopyForTest(alloc, scoped_rich);
    defer scoped_corrupt.deinit(alloc);
    try std.testing.expectEqual(
        RestoreOutcome.invalid,
        try restoreIfMatching(
            alloc,
            &verified,
            "session-two",
            35,
            .{ .current = "connection-a" },
            &scoped_corrupt,
        ),
    );
    try std.testing.expectEqualStrings("connection-a", scoped_corrupt.pending[0].connection_id);
    try std.testing.expectEqualStrings("legacy", scoped_corrupt.pending[0].lookup_scope.?);
    try std.testing.expectEqual(@as(usize, 0), probe.resolved_a);
    try std.testing.expectEqual(@as(usize, 0), probe.resolved_vercel);
    try std.testing.expectEqual(@as(usize, 0), probe.calls_a);
    try std.testing.expectEqual(@as(usize, 0), probe.calls_vercel);
    probe = .{};
    var scoped_outcome = try dispatch.lookup(
        alloc,
        scoped_corrupt.pending[0].connection_id,
        scoped_corrupt.pending[0].id,
        scoped_corrupt.pending[0].lookup_scope,
        &cancel,
    );
    defer scoped_outcome.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), probe.resolved_a);
    try std.testing.expectEqual(@as(usize, 0), probe.resolved_vercel);
    try std.testing.expectEqual(@as(usize, 1), probe.calls_a);
    try std.testing.expectEqual(@as(usize, 0), probe.calls_vercel);
    try std.testing.expect(probe.saw_a_credential);
    try std.testing.expect(probe.saw_legacy_scope);
}

fn legacyCopyForTest(
    alloc: Allocator,
    snapshot: session_usage.Snapshot,
) !session_usage.Snapshot {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try session_usage.writeSnapshot(&encoded.writer, snapshot);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded.written(),
        .{},
    );
    defer parsed.deinit();
    return session_usage.parseSnapshotValue(alloc, parsed.value);
}
