const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_event = @import("session_event.zig");
const session_json = @import("session_json.zig");
const session_log = @import("session_log.zig");
const session_projection = @import("session_projection.zig");
const session_replay = @import("session_replay.zig");
const Allocator = std.mem.Allocator;

const authority_module = @import("session_authority.zig");
const paths = @import("session_store_paths.zig");
const types = @import("session_store_types.zig");

const openSessionFile = authority_module.openSessionFile;
const readExactLegacyFile = authority_module.readExactLegacyFile;
const validateWorkspaceRoot = paths.validateWorkspaceRoot;
const LoadedWritableSession = types.LoadedWritableSession;
const ResumeOptions = types.ResumeOptions;
const automatic_legacy_max_bytes = types.automatic_legacy_max_bytes;
const StoreContext = types.StoreContext;

// Temporary read-only compatibility boundary. Remove this module's v1-v3
// decoders once the supported upgrade window no longer includes schema v3.
// Current sessions never write any of these formats.

pub const LegacyStoredSession = struct {
    id: []u8,
    workspace_root: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    history: []session.HistoryTurn,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,

    /// Frees owned session fields and history turns.
    pub fn deinit(self: *LegacyStoredSession, alloc: Allocator) void {
        if (self.id.len > 0) alloc.free(self.id);
        if (self.workspace_root) |wr| alloc.free(wr);
        session.freeHistoryTurnSlice(alloc, self.history);
        self.* = undefined;
    }
};

pub const MigrationPreferenceSource = enum {
    requesting_workspace,
    preserved_workspace,
};

pub fn migrateLegacyLocked(
    ctx: StoreContext,
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    workspace_root: []const u8,
    preference_source: MigrationPreferenceSource,
    options: ResumeOptions,
) !LoadedWritableSession {
    var loaded: LoadedWritableSession = undefined;
    try migrateLegacyLockedInto(
        &loaded,
        ctx,
        alloc,
        writable,
        workspace_root,
        preference_source,
        options,
    );
    return loaded;
}

// Keep fallible construction behind a noinline out-parameter boundary so
// error returns do not materialize the full LoadedWritableSession payload.
noinline fn migrateLegacyLockedInto(
    out: *LoadedWritableSession,
    ctx: StoreContext,
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    workspace_root: []const u8,
    preference_source: MigrationPreferenceSource,
    options: ResumeOptions,
) !void {
    var primary = try openSessionFile(&writable.dir, "session.json", .read_only);
    defer primary.close(io_mod.getIo());
    const primary_stat = try primary.stat(io_mod.getIo());
    const allowed_size = if (options.allow_large_legacy)
        primary_stat.size
    else
        automatic_legacy_max_bytes;
    if (primary_stat.size > allowed_size) return error.LegacySessionTooLarge;
    const primary_bytes = readExactLegacyFile(
        alloc,
        &primary,
        primary_stat.size,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
        else => return error.LegacySessionMigrationFailed,
    };
    defer alloc.free(primary_bytes);
    const schema = try session_json.parseLegacySchemaVersion(alloc, primary_bytes);

    var legacy = session_json.parseLegacyExact(
        LegacyStoredSession,
        alloc,
        primary_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
        else => return err,
    };
    errdefer legacy.deinit(alloc);
    if (!std.mem.eql(u8, legacy.id, writable.session_id)) {
        return error.InvalidSessionFormat;
    }
    const legacy_had_workspace = legacy.workspace_root != null;
    var state = try legacyToDurableState(
        ctx,
        alloc,
        &legacy,
        workspace_root,
        preference_source,
        options.seed_preferences,
    );
    errdefer state.deinit(alloc);
    if (!legacy_had_workspace and
        !std.mem.eql(u8, state.workspace_root, workspace_root))
    {
        return error.InvalidDurableField;
    }

    try repairLegacyImages(ctx, alloc, writable.session_id, state.history);

    const loaded = try session_log.importLegacySnapshotState(
        alloc,
        writable,
        state,
        @intFromEnum(schema),
        primary_stat.size,
        null,
    );
    state.deinit(alloc);
    out.* = loaded;
}

/// Reads one valid schema-v3 committed prefix and converts it directly to the
/// current conversation format. The v3 log is an import source only; none of
/// its watermark, checkpoint, or replacement writers run.
pub const SchemaV3Import = struct {
    state: session_codec.DurableSessionState,
    source_bytes: u64,
    generation: session_event.Identifier,

    pub fn deinit(self: *SchemaV3Import, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.* = undefined;
    }

    pub fn takeState(self: *SchemaV3Import) session_codec.DurableSessionState {
        const state = self.state;
        self.* = undefined;
        return state;
    }
};

/// Reads the schema-v3 watermark's committed prefix. The manifest is only a
/// derived projection and may lag an acknowledged commit or be absent.
pub fn loadSchemaV3ReadOnly(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !SchemaV3Import {
    var events = try openSessionFile(session_dir, "events.jsonl", .read_only);
    defer events.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, events);
    const watermark_name = try std.fmt.allocPrint(alloc, "commit.{s}.json", .{
        std.fmt.bytesToHex(generation, .lower),
    });
    defer alloc.free(watermark_name);
    const watermark_bytes = try authority_module.readOptionalSessionFile(
        alloc,
        session_dir,
        watermark_name,
        16 * 1024,
    ) orelse return error.InvalidSessionFormat;
    defer alloc.free(watermark_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, watermark_bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try authority_module.exactJsonObject(parsed.value, &.{
        "schema_version",   "session_id",              "log_generation", "through_seq",
        "through_event_id", "through_event_log_bytes",
    });
    const recorded_generation = try authority_module.parseIdentifier(
        try authority_module.objectString(object, "log_generation"),
    );
    if (try authority_module.jsonU64(object, "schema_version") != 1 or
        !std.mem.eql(u8, try authority_module.objectString(object, "session_id"), session_id) or
        !std.mem.eql(u8, &recorded_generation, &generation))
    {
        return error.InvalidSessionFormat;
    }
    const event_id = try authority_module.parseIdentifier(
        try authority_module.objectString(object, "through_event_id"),
    );
    const committed_bytes = try authority_module.jsonU64(object, "through_event_log_bytes");
    var replayed = try session_replay.replayCommittedPrefix(
        alloc,
        events,
        generation,
        try authority_module.jsonU64(object, "through_seq"),
        committed_bytes,
    );
    errdefer replayed.deinit(alloc);
    if (!std.mem.eql(u8, replayed.state.id, session_id) or
        !std.mem.eql(u8, &replayed.position.through_event_id, &event_id))
    {
        return error.InvalidSessionFormat;
    }
    if (try replayed.state.archive_legacy_recovery(alloc)) {
        @import("../shared/debug_trace.zig").logf("session", "legacy recovery archived session_id={s} reason=unverifiable_route_authority", .{session_id});
    }
    const state = replayed.takeState();
    return .{
        .state = state,
        .source_bytes = committed_bytes,
        .generation = generation,
    };
}

/// Reads one valid schema-v3 committed prefix and converts it directly to the
/// current conversation format. The v3 log is an import source only; none of
/// its watermark, checkpoint, or replacement writers run.
pub fn migrateSchemaV3Locked(
    ctx: StoreContext,
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
) !LoadedWritableSession {
    var source = try loadSchemaV3ReadOnly(
        alloc,
        &writable.dir,
        writable.session_id,
    );
    defer source.deinit(alloc);
    try repairLegacyImages(
        ctx,
        alloc,
        writable.session_id,
        source.state.history,
    );
    return session_log.importLegacySnapshotState(
        alloc,
        writable,
        source.state,
        3,
        source.source_bytes,
        source.generation,
    );
}

fn repairLegacyImages(
    ctx: StoreContext,
    alloc: Allocator,
    session_id: []const u8,
    history: []session.HistoryTurn,
) !void {
    const session_dir = try paths.sessionDirPath(alloc, ctx.sessions_dir, session_id);
    defer alloc.free(session_dir);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ session_dir, "images" });
    defer alloc.free(snapshot_dir);
    _ = try session.repair_legacy_images_transactionally(
        alloc,
        history,
        snapshot_dir,
    );
}

/// Converts a parsed legacy session into a validated `DurableSessionState`,
/// resolving the origin/current workspace roots and merging preferences from
/// the requested or preserved workspace. Consumes `legacy` (transfers its
/// owned id/history into the returned state).
pub fn legacyToDurableState(
    ctx: StoreContext,
    alloc: Allocator,
    legacy: *LegacyStoredSession,
    requesting_workspace: []const u8,
    preference_source: MigrationPreferenceSource,
    seed_preferences: ?session_codec.DurableSessionPreferences,
) !session_codec.DurableSessionState {
    const root = legacy.workspace_root orelse ctx.workspace_root;
    try validateWorkspaceRoot(root);
    const origin = if (legacy.workspace_root != null)
        legacy.workspace_root.?
    else
        try alloc.dupe(u8, root);
    errdefer if (legacy.workspace_root == null) alloc.free(origin);
    const current = try alloc.dupe(u8, root);
    errdefer alloc.free(current);
    const preferences = try loadMigrationPreferences(
        ctx,
        alloc,
        switch (preference_source) {
            .requesting_workspace => requesting_workspace,
            .preserved_workspace => root,
        },
        seed_preferences,
    );
    errdefer {
        var owned = preferences;
        owned.deinit(alloc);
    }
    const state = session_codec.DurableSessionState{
        .id = legacy.id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = legacy.created_at_ms,
        .updated_at_ms = legacy.updated_at_ms,
        .conversation_language = legacy.conversation_language,
        .preferences = preferences,
        .history = legacy.history,
        .total_input_tokens = legacy.total_input_tokens,
        .total_output_tokens = legacy.total_output_tokens,
    };
    legacy.id = &.{};
    legacy.workspace_root = null;
    legacy.history = &.{};
    try session_codec.validateState(state);
    return state;
}

fn loadMigrationPreferences(
    ctx: StoreContext,
    alloc: Allocator,
    workspace_root: []const u8,
    seed_preferences: ?session_codec.DurableSessionPreferences,
) !session_codec.DurableSessionPreferences {
    if (seed_preferences) |preferences| return preferences.dupe(alloc);
    var detailed = try config_runtime.loadMergedSettingsDetailedFromHome(
        alloc,
        ctx.home_dir,
        workspace_root,
    );
    defer detailed.deinit(alloc);
    return .{
        .model = try alloc.dupe(
            u8,
            detailed.settings.models.get(.gateway) orelse "anthropic/claude-opus-4.7",
        ),
        .effort = detailed.settings.effort orelse .auto,
        .fast_mode = detailed.settings.fast_mode orelse false,
    };
}

test "schema v3 import archives legacy recovery with allocation failure cleanup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{}) };
    defer dir.close();
    const generation = [_]u8{1} ** 16;
    const started = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = [_]u8{1} ** 16,
        .timestamp_ms = 10,
        .event = .{ .session_started = .{
            .id = @constCast("legacy-recovery"),
            .created_at_ms = 10,
            .origin_workspace_root = @constCast("/workspace"),
            .workspace_root = @constCast("/workspace"),
            .conversation_language = .literal("en"),
            .preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false },
        } },
    });
    defer alloc.free(started);
    const recovery = "{\"schema_version\":1,\"log_generation\":\"01010101010101010101010101010101\",\"seq\":2,\"event_id\":\"02020202020202020202020202020202\",\"timestamp_ms\":20,\"kind\":\"recovery_checkpoint_set\",\"payload\":{\"checkpoint\":{\"version\":2,\"route_identity\":{\"connection_id\":\"vercel\",\"adapter_kind\":\"vercel_ai_gateway\",\"permission_review_model_id\":\"review\"},\"delivery\":\"possibly_sent\",\"turn_id\":1,\"user\":{\"text\":\"saved request\",\"images\":[]},\"assistant_source\":\"saved partial\",\"execution\":{\"schema_version\":3,\"tool_steps\":[],\"files\":[]},\"cause\":\"response_interrupted\",\"action\":\"continuing_response\",\"tool_state\":\"uncertain\",\"route_model\":\"test/model\",\"requested_fast_mode\":false,\"fast_mode\":false,\"max_provider_attempts\":3,\"consumed_provider_attempts\":0,\"outstanding_reservation\":false}}}\n";
    const events = try std.mem.concat(alloc, u8, &.{ started, recovery });
    defer alloc.free(events);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "events.jsonl", .data = events });
    const watermark = try std.fmt.allocPrint(alloc, "{{\"schema_version\":1,\"session_id\":\"legacy-recovery\",\"log_generation\":\"01010101010101010101010101010101\",\"through_seq\":2,\"through_event_id\":\"02020202020202020202020202020202\",\"through_event_log_bytes\":{d}}}", .{events.len});
    defer alloc.free(watermark);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "commit.01010101010101010101010101010101.json", .data = watermark });
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn check(a: Allocator, source: *io_mod.VerifiedDir) !void {
            var imported = try loadSchemaV3ReadOnly(a, source, "legacy-recovery");
            defer imported.deinit(a);
            try std.testing.expect(imported.state.recovery_checkpoint == null);
            try std.testing.expectEqual(@as(usize, 1), imported.state.history.len);
            try std.testing.expectEqualStrings("saved partial", imported.state.history[0].interrupted.assistant.?);
        }
    }.check, .{&dir});
}

test "schema v3 import follows the committed watermark beyond a stale manifest" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const id = "legacy-committed-prefix";
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try @import("session_store.zig").Store.initFromHome(alloc, home, "/workspace");
    defer store.deinit(alloc);
    try store.canonical_root.sessions.?.dir.createDir(std.testing.io, id, .fromMode(0o700));
    var dir = io_mod.VerifiedDir{ .dir = try store.canonical_root.sessions.?.dir.openDir(std.testing.io, id, .{}) };
    defer dir.close();
    const generation = [_]u8{1} ** 16;
    const event_id = [_]u8{2} ** 16;
    const language = try session.ConversationLanguage.fromSlice("en");
    var usage = @import("session_usage.zig").Usage.initFresh();
    defer usage.deinit(alloc);
    var usage_snapshot = try usage.snapshot(alloc);
    defer usage_snapshot.deinit(alloc);
    const started = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = [_]u8{1} ** 16,
        .timestamp_ms = 10,
        .event = .{ .session_started = .{
            .id = @constCast(id),
            .created_at_ms = 10,
            .origin_workspace_root = @constCast("/workspace"),
            .workspace_root = @constCast("/workspace"),
            .conversation_language = language,
            .preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false },
            .usage = usage_snapshot,
        } },
    });
    defer alloc.free(started);
    const committed = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = generation,
        .seq = 2,
        .event_id = event_id,
        .timestamp_ms = 20,
        .event = .{ .history_turn_committed = .{
            .conversation_language = language,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .turn = .{ .assistant = .{
                .user = .{ .text = @constCast("acknowledged request") },
                .assistant = @constCast("acknowledged answer"),
            } },
        } },
    });
    defer alloc.free(committed);
    const events = try std.mem.concat(alloc, u8, &.{ started, committed, "uncommitted tail" });
    defer alloc.free(events);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "events.jsonl", .data = events });
    const manifest = try session_projection.encodeManifest(alloc, .{
        .id = @constCast(id),
        .authority_id = [_]u8{3} ** 16,
        .log_generation = generation,
        .created_at_ms = 10,
        .updated_at_ms = 10,
        .origin_workspace_root = @constCast("/workspace"),
        .workspace_root = @constCast("/workspace"),
        .conversation_language = language,
        .history_len = 0,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .last_event_seq = 1,
        .event_log_bytes = started.len,
        .event_log_stat_fingerprint = [_]u8{0} ** 32,
        .generation_base_seq = 1,
        .generation_base_bytes = started.len,
        .checkpoint_seq = null,
        .checkpoint_sha256 = null,
        .preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false },
    });
    defer alloc.free(manifest);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "session.json", .data = manifest });
    const watermark_name = "commit.01010101010101010101010101010101.json";
    const watermark = try std.fmt.allocPrint(
        alloc,
        "{{\"schema_version\":1,\"session_id\":\"{s}\",\"log_generation\":\"{s}\",\"through_seq\":2,\"through_event_id\":\"{s}\",\"through_event_log_bytes\":{d}}}\n",
        .{ id, std.fmt.bytesToHex(generation, .lower), std.fmt.bytesToHex(event_id, .lower), started.len + committed.len },
    );
    defer alloc.free(watermark);
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = watermark_name, .data = watermark });
    {
        var imported = try loadSchemaV3ReadOnly(alloc, &dir, id);
        defer imported.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), imported.state.history.len);
        try std.testing.expectEqualStrings("acknowledged answer", imported.state.history[0].assistant.assistant);
        try std.testing.expectEqual(started.len + committed.len, imported.source_bytes);
    }
    try dir.dir.deleteFile(std.testing.io, "session.json");
    {
        var imported = try loadSchemaV3ReadOnly(alloc, &dir, id);
        defer imported.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), imported.state.history.len);
    }
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = watermark_name, .data = "{}" });
    try std.testing.expectError(error.InvalidSessionFormat, loadSchemaV3ReadOnly(alloc, &dir, id));
    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "session.json", .data = manifest });
    try dir.dir.writeFile(std.testing.io, .{
        .sub_path = "authority.json",
        .data = "{\"schema_version\":1,\"storage_format\":\"event_log_v1\",\"session_id\":\"legacy-committed-prefix\",\"authority_id\":\"03030303030303030303030303030303\",\"source\":\"native_create\"}",
    });
    var recovered = try store.recoverSessionCopy(alloc, id, .{});
    defer recovered.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), recovered.history_len);
    var restored = try store.canonical_root.loadReadOnly(alloc, recovered.recovered_session_id, .{});
    defer restored.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), restored.history.len);
    const source_after = try authority_module.readOptionalSessionFile(alloc, &dir, "events.jsonl", events.len + 1);
    defer if (source_after) |bytes| alloc.free(bytes);
    try std.testing.expectEqualStrings(events, source_after.?);
}
