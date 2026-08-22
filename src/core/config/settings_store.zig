const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const types = @import("../shared/types.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const context_limits = @import("context_limits.zig");
const model_provider = @import("model_provider.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const update_target = @import("../upgrade/update_target.zig");

const Allocator = std.mem.Allocator;
const max_settings_bytes: usize = 64 * 1024;
pub const max_model_bytes: usize = 1024;
const lock_deadline_ms: u64 = 2000;
const backup_keep_count: usize = 5;
const corrupt_keep_count: usize = 3;

pub const OpenMode = enum {
    read_only,
    writable,
};

pub const Availability = union(enum) {
    read_only_absent,
    writable,
    unavailable,
};

pub const StatuslineItem = enum {
    context,
    session,
    workspace,
};

pub const StatuslineItemPatch = struct {
    item: StatuslineItem,
    enabled: bool,
};

pub const AllowlistResetScope = enum {
    all,
    commands,
    tools,
    urls,
    web_fetch_domains,
};

pub const PermissionPatch = union(enum) {
    add: struct {
        category: []const u8,
        pattern: []const u8,
        action: types.PermissionAction,
    },
    remove: struct {
        category: []const u8,
        pattern: []const u8,
    },
    reset: AllowlistResetScope,
};

pub const PermissionScope = enum {
    user,
    local,
};

pub const PermissionMutation = struct {
    scope: PermissionScope,
    workspace_root: ?[]const u8,
    patch: PermissionPatch,
};

pub const WorkspaceDirectoryPatch = union(enum) {
    add: []const u8,
    remove: []const u8,
    clear,
};

pub const WorkspaceDirectoryMutation = struct {
    workspace_root: []const u8,
    patch: WorkspaceDirectoryPatch,
    observed_sources: []const workspace_access.SavedSource = &.{},
    command_line_directories: []const []const u8 = &.{},
};

pub const UserSettingsPatch = struct {
    model: ?[]const u8 = null,
    provider: ?model_provider.ProviderId = null,
    codex_model: ?[]const u8 = null,
    grok_model: ?[]const u8 = null,
    claude_model: ?[]const u8 = null,
    permission_mode: ?types.PermissionMode = null,
    credential_source: ?types.CredentialSource = null,
    /// Removes the key entirely so resolution returns to plain precedence.
    /// Distinct from a null `credential_source`, which means "leave unchanged".
    clear_credential_source: bool = false,
    yolo_acknowledged: ?bool = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,
    slash_menu_categories: ?bool = null,
    update_channel: ?update_target.Channel = null,
    startup_scrollback: ?bool = null,
    prompt_history_enabled: ?bool = null,
    statusline_item: ?StatuslineItemPatch = null,
    notification_turn_end: ?bool = null,
    notification_attention_required: ?bool = null,
    notification_max: ?bool = null,

    fn isEmpty(self: UserSettingsPatch) bool {
        return self.model == null and
            self.provider == null and
            self.codex_model == null and
            self.grok_model == null and
            self.claude_model == null and
            self.permission_mode == null and
            self.credential_source == null and
            !self.clear_credential_source and
            self.yolo_acknowledged == null and
            self.effort == null and
            self.fast_mode == null and
            self.slash_menu_categories == null and
            self.update_channel == null and
            self.startup_scrollback == null and
            self.prompt_history_enabled == null and
            self.statusline_item == null and
            self.notification_turn_end == null and
            self.notification_attention_required == null and
            self.notification_max == null;
    }
};

pub const SettingsScope = enum {
    user,
    local,
};

pub const LegacyCleanup = struct {
    fields_removed: usize = 0,
    workspaces_changed: usize = 0,
    recovery_paths: []const []const u8 = &.{},

    pub fn deinit(self: *LegacyCleanup, alloc: Allocator) void {
        if (self.recovery_paths.len > 0) {
            for (self.recovery_paths) |path| alloc.free(path);
            alloc.free(self.recovery_paths);
        }
        self.* = undefined;
    }
};

pub const CommittedSettings = struct {
    scope: SettingsScope,
    cleanup: LegacyCleanup = .{},
    permission_rules_removed: usize = 0,
};

pub const CommitOutcome = union(enum) {
    unchanged,
    committed: CommittedSettings,

    pub fn deinit(self: *CommitOutcome, alloc: Allocator) void {
        switch (self.*) {
            .unchanged => {},
            .committed => |*committed| committed.cleanup.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const PrimaryLoad = union(enum) {
    absent,
    valid: []u8,
    invalid,
    oversized,

    pub fn deinit(self: *PrimaryLoad, alloc: Allocator) void {
        if (self.* == .valid) alloc.free(self.valid);
        self.* = undefined;
    }
};

const RawPrimary = union(enum) {
    absent,
    bytes: []u8,
    oversized,

    fn deinit(self: *RawPrimary, alloc: Allocator) void {
        if (self.* == .bytes) alloc.free(self.bytes);
        self.* = undefined;
    }
};

const PatchApplication = struct {
    changed: bool = false,
    permission_rules_removed: usize = 0,
    legacy_fields_removed: usize = 0,
    legacy_workspaces_changed: usize = 0,
    migration_fields: u16 = 0,
};

const UserPreferenceField = enum(u4) {
    model,
    permission_mode,
    effort,
    fast_mode,
    slash_menu_categories,
    update_channel,
    startup_scrollback,
    prompt_history_enabled,
    statusline_context,
    statusline_session,

    fn mask(self: UserPreferenceField) u16 {
        return @as(u16, 1) << @intFromEnum(self);
    }

    fn snapshotName(self: UserPreferenceField) []const u8 {
        return switch (self) {
            .model => "settings.json.preference-migration.model.json",
            .permission_mode => "settings.json.preference-migration.permission_mode.json",
            .effort => "settings.json.preference-migration.effort.json",
            .fast_mode => "settings.json.preference-migration.fast_mode.json",
            .slash_menu_categories => "settings.json.preference-migration.slash_menu_categories.json",
            .update_channel => "settings.json.preference-migration.update_channel.json",
            .startup_scrollback => "settings.json.preference-migration.startup_scrollback.json",
            .prompt_history_enabled => "settings.json.preference-migration.prompt_history_enabled.json",
            .statusline_context => "settings.json.preference-migration.statusline_context.json",
            .statusline_session => "settings.json.preference-migration.statusline_session.json",
        };
    }
};

const user_preference_fields = [_]UserPreferenceField{
    .model,
    .permission_mode,
    .effort,
    .fast_mode,
    .slash_menu_categories,
    .update_channel,
    .startup_scrollback,
    .prompt_history_enabled,
    .statusline_context,
    .statusline_session,
};

const SettingsMutation = union(enum) {
    user: UserSettingsPatch,
    workspace_directory: WorkspaceDirectoryMutation,
    permission: PermissionMutation,

    fn operation(self: SettingsMutation) []const u8 {
        return switch (self) {
            .user => "user_patch",
            .workspace_directory => "workspace_directory_patch",
            .permission => "permission_patch",
        };
    }

    fn scope(self: SettingsMutation) SettingsScope {
        return switch (self) {
            .user => .user,
            .workspace_directory => .local,
            .permission => |mutation| switch (mutation.scope) {
                .user => .user,
                .local => .local,
            },
        };
    }

    fn mutationMode(self: SettingsMutation) []const u8 {
        return switch (self) {
            .user => |patch| if (patch.prompt_history_enabled != null)
                "commit_first"
            else
                "runtime_first",
            .workspace_directory => "commit_first",
            .permission => "commit_first",
        };
    }

    fn isEmpty(self: SettingsMutation) bool {
        return switch (self) {
            .user => |patch| patch.isEmpty(),
            .workspace_directory => false,
            .permission => false,
        };
    }
};

pub const Store = struct {
    durable_home: ?io_mod.VerifiedDir,
    display_root: []u8,
    availability: Availability,
    mode: OpenMode,
    commit_count: usize = 0,
    forced_fingerprint_conflicts: usize = 0,
    fail_parent_sync_after_rename: bool = false,
    fail_migration_snapshot: bool = false,
    last_failure_cleanup: LegacyCleanup = .{},

    fn initReadOnlyAbsent(alloc: Allocator, home_path: []const u8) !Store {
        return .{
            .durable_home = null,
            .display_root = try profile_paths.rootDir(alloc, home_path),
            .availability = .read_only_absent,
            .mode = .read_only,
        };
    }

    pub fn initFromHome(alloc: Allocator, home_path: []const u8, mode: OpenMode) !Store {
        const zio = io_mod.getIo();
        var home = std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                if (mode == .read_only) return initReadOnlyAbsent(alloc, home_path);
                return err;
            },
            else => return err,
        };
        defer home.close(zio);

        var durable_home = home.openDir(zio, profile_paths.root_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) return initReadOnlyAbsent(alloc, home_path);

                var verified_home = io_mod.VerifiedDir{
                    .dir = try std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true }),
                };
                defer verified_home.close();
                const created = try io_mod.openOrCreateVerifiedPrivateDir(&verified_home, profile_paths.root_dir_name);
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
            else => return err,
        };
        errdefer durable_home.close(zio);

        if (mode == .writable) {
            durable_home.setPermissions(zio, std.Io.File.Permissions.fromMode(0o700)) catch {
                return error.PrivateStatePermissionsUnsupported;
            };
        }
        const stat = try durable_home.stat(zio);
        if (stat.kind != .directory) return error.DurablePathUnsafe;
        const durable_mode = stat.permissions.toMode() & 0o777;
        if (mode == .writable and durable_mode != 0o700) {
            return error.PrivateStatePermissionsUnsupported;
        }
        if (mode == .read_only and durableModeWritableByGroupOrOther(durable_mode)) {
            return error.PrivateStatePermissionsUnsupported;
        }

        return .{
            .durable_home = .{ .dir = durable_home },
            .display_root = try io_mod.dirRealpathAlloc(alloc, durable_home, "."),
            .availability = .writable,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.last_failure_cleanup.deinit(alloc);
        if (self.durable_home) |*dir| dir.close();
        alloc.free(self.display_root);
        self.* = undefined;
    }

    pub fn loadPrimary(self: *Store, alloc: Allocator) !PrimaryLoad {
        var raw = try self.loadRawPrimary(alloc);
        switch (raw) {
            .absent => return .absent,
            .oversized => return .oversized,
            .bytes => |bytes| {
                raw = .absent;
                errdefer alloc.free(bytes);
                var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch {
                    alloc.free(bytes);
                    return .invalid;
                };
                defer parsed.deinit();
                if (parsed.value != .object) {
                    alloc.free(bytes);
                    return .invalid;
                }
                return .{ .valid = bytes };
            },
        }
    }

    pub fn applyUserPatch(
        self: *Store,
        alloc: Allocator,
        patch: UserSettingsPatch,
    ) !CommitOutcome {
        return self.applyMutation(alloc, .{ .user = patch });
    }

    pub fn applyPermissionPatch(
        self: *Store,
        alloc: Allocator,
        mutation: PermissionMutation,
    ) !CommitOutcome {
        return self.applyMutation(alloc, .{ .permission = mutation });
    }

    pub fn applyWorkspaceDirectoryPatch(
        self: *Store,
        alloc: Allocator,
        mutation: WorkspaceDirectoryMutation,
    ) !CommitOutcome {
        return self.applyMutation(alloc, .{ .workspace_directory = mutation });
    }

    fn applyMutation(
        self: *Store,
        alloc: Allocator,
        mutation: SettingsMutation,
    ) !CommitOutcome {
        self.last_failure_cleanup.deinit(alloc);
        self.last_failure_cleanup = .{};
        const operation = mutation.operation();
        const mutation_mode = mutation.mutationMode();
        return self.applyMutationImpl(alloc, mutation, operation, mutation_mode) catch |err| {
            debug_trace.logf(
                "config",
                "settings operation={s} path_category=user_settings scope={s} mutation_mode={s} outcome=failed error={s}",
                .{ operation, @tagName(mutation.scope()), mutation_mode, @errorName(err) },
            );
            return err;
        };
    }

    fn applyMutationImpl(
        self: *Store,
        alloc: Allocator,
        mutation: SettingsMutation,
        operation: []const u8,
        mutation_mode: []const u8,
    ) !CommitOutcome {
        if (self.mode != .writable or self.durable_home == null) return error.SettingsStoreUnavailable;
        try validateMutation(mutation);
        if (mutation.isEmpty()) {
            debug_trace.logf(
                "config",
                "settings operation={s} path_category=user_settings scope={s} mutation_mode={s} outcome=unchanged error=none",
                .{ operation, @tagName(mutation.scope()), mutation_mode },
            );
            return .unchanged;
        }

        var lock = io_mod.acquireTimedAdvisoryLock(&self.durable_home.?, "settings.lock", lock_deadline_ms) catch |err| switch (err) {
            error.LockBusy => return error.SettingsLockBusy,
            error.LockUnsupported => return error.SettingsLockUnsupported,
            else => return err,
        };
        defer lock.release();

        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            var primary = try self.loadRawPrimary(alloc);
            defer primary.deinit(alloc);

            const existing = switch (primary) {
                .absent => null,
                .oversized => return error.SettingsPrimaryTooLarge,
                .bytes => |bytes| bytes,
            };

            const original_fingerprint = fingerprintOptional(existing);
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var root = if (existing) |bytes|
                (std.json.parseFromSlice(std.json.Value, arena, bytes, .{}) catch {
                    self.copyCorruptBestEffort(alloc, bytes);
                    return error.InvalidSettingsFormat;
                }).value
            else
                std.json.Value{ .object = .empty };
            if (root != .object) {
                if (existing) |bytes| self.copyCorruptBestEffort(alloc, bytes);
                return error.InvalidSettingsFormat;
            }

            const application = try applyMutationToRoot(arena, &root, mutation);
            if (!application.changed) {
                debug_trace.logf(
                    "config",
                    "settings operation={s} path_category=user_settings scope={s} mutation_mode={s} outcome=unchanged error=none",
                    .{ operation, @tagName(mutation.scope()), mutation_mode },
                );
                return .unchanged;
            }

            const candidate = try serializeJson(alloc, root);
            defer alloc.free(candidate);
            if (candidate.len > max_settings_bytes) return error.SettingsTooLarge;
            try validateCandidate(alloc, candidate, mutation);

            const recovery_paths = self.writeMigrationSnapshots(
                alloc,
                application.migration_fields,
                existing,
            ) catch return error.SettingsMigrationSnapshotFailed;
            var recovery_paths_owned = recovery_paths.len > 0;
            defer if (recovery_paths_owned) freeRecoveryPaths(alloc, recovery_paths);

            if (self.forced_fingerprint_conflicts > 0) {
                self.forced_fingerprint_conflicts -= 1;
                continue;
            }

            var latest = try self.loadRawPrimary(alloc);
            defer latest.deinit(alloc);
            const latest_bytes = switch (latest) {
                .absent => null,
                .oversized => return error.SettingsPrimaryTooLarge,
                .bytes => |bytes| bytes,
            };
            const latest_fingerprint = fingerprintOptional(latest_bytes);
            if (!std.mem.eql(u8, &original_fingerprint, &latest_fingerprint)) continue;

            if (existing) |bytes| self.createBackupBestEffort(alloc, bytes);

            var precommit = try self.loadRawPrimary(alloc);
            defer precommit.deinit(alloc);
            const precommit_bytes = switch (precommit) {
                .absent => null,
                .oversized => return error.SettingsPrimaryTooLarge,
                .bytes => |bytes| bytes,
            };
            const precommit_fingerprint = fingerprintOptional(precommit_bytes);
            if (!std.mem.eql(u8, &original_fingerprint, &precommit_fingerprint)) continue;

            const durable_ops = if (self.fail_parent_sync_after_rename)
                io_mod.DurableOps{ .ctx = self, .sync_dir = failStoreParentSync }
            else
                io_mod.DurableOps{};
            io_mod.durableReplaceVerifiedWithOps(
                alloc,
                &self.durable_home.?,
                "settings.json",
                candidate,
                durable_ops,
            ) catch |err| switch (err) {
                error.DurableReplacePostRenameFailed => {
                    self.last_failure_cleanup = .{
                        .fields_removed = application.legacy_fields_removed,
                        .workspaces_changed = application.legacy_workspaces_changed,
                        .recovery_paths = recovery_paths,
                    };
                    recovery_paths_owned = false;
                    return error.SettingsCommitIndeterminate;
                },
                error.DurableReplacePreRenameFailed => return error.SettingsCommitFailed,
                else => return err,
            };
            self.commit_count += 1;
            debug_trace.logf(
                "config",
                "settings operation={s} path_category=user_settings scope={s} mutation_mode={s} outcome=committed legacy_fields_removed={d} legacy_workspaces_changed={d} migration_snapshots_written={d} permission_rules_removed={d} error=none",
                .{
                    operation,
                    @tagName(mutation.scope()),
                    mutation_mode,
                    application.legacy_fields_removed,
                    application.legacy_workspaces_changed,
                    recovery_paths.len,
                    application.permission_rules_removed,
                },
            );
            recovery_paths_owned = false;
            return .{ .committed = .{
                .scope = mutation.scope(),
                .cleanup = .{
                    .fields_removed = application.legacy_fields_removed,
                    .workspaces_changed = application.legacy_workspaces_changed,
                    .recovery_paths = recovery_paths,
                },
                .permission_rules_removed = application.permission_rules_removed,
            } };
        }
        return error.SettingsConcurrentModification;
    }

    pub fn takeFailureCleanup(self: *Store) LegacyCleanup {
        const cleanup = self.last_failure_cleanup;
        self.last_failure_cleanup = .{};
        return cleanup;
    }

    pub fn readPrimaryForTest(self: *Store, alloc: Allocator) ![]u8 {
        var raw = try self.loadRawPrimary(alloc);
        defer raw.deinit(alloc);
        return switch (raw) {
            .bytes => |bytes| blk: {
                raw = .absent;
                break :blk bytes;
            },
            .absent => error.FileNotFound,
            .oversized => error.SettingsPrimaryTooLarge,
        };
    }

    pub fn primaryStatForTest(self: *Store) !std.Io.File.Stat {
        const dir = self.durable_home orelse return error.FileNotFound;
        return dir.dir.statFile(io_mod.getIo(), "settings.json", .{ .follow_symlinks = false });
    }

    pub fn commitCountForTest(self: *const Store) usize {
        return self.commit_count;
    }

    pub fn forceFingerprintConflictsForTest(self: *Store, count: usize) void {
        self.forced_fingerprint_conflicts = count;
    }

    pub fn failParentSyncAfterRenameForTest(self: *Store) void {
        self.fail_parent_sync_after_rename = true;
    }

    pub fn failMigrationSnapshotForTest(self: *Store) void {
        self.fail_migration_snapshot = true;
    }

    pub fn newestValidBackupPath(self: *Store, alloc: Allocator) !?[]u8 {
        if (self.durable_home == null) return null;
        var backups = self.durable_home.?.dir.openDir(io_mod.getIo(), profile_paths.backups_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
            else => return err,
        };
        defer backups.close(io_mod.getIo());

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| alloc.free(name);
            names.deinit(alloc);
        }
        var iterator = backups.iterate();
        while (try iterator.next(io_mod.getIo())) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "settings.json.backup.")) continue;
            if (parseBackupTimestamp(entry.name) == null) continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
        sort_utils.sort([]u8, names.items, {}, struct {
            fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
                return backupNameNewerThan(lhs, rhs);
            }
        }.lessThan);

        for (names.items) |name| {
            const stat = backups.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch continue;
            if (stat.kind != .file or stat.nlink != 1 or stat.size > max_settings_bytes) continue;
            var file = backups.openFile(io_mod.getIo(), name, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch continue;
            defer file.close(io_mod.getIo());
            const bytes = io_mod.readFileToEnd(alloc, &file, max_settings_bytes + 1) catch continue;
            defer alloc.free(bytes);
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            return try std.fs.path.join(alloc, &.{ self.display_root, profile_paths.backups_dir_name, name });
        }
        return null;
    }

    fn loadRawPrimary(self: *Store, alloc: Allocator) !RawPrimary {
        if (self.durable_home == null) return .absent;
        const zio = io_mod.getIo();
        const open_mode: std.Io.Dir.OpenFileOptions.Mode =
            if (self.mode == .writable) .read_write else .read_only;
        var file = io_mod.openExistingRegularFile(
            self.durable_home.?.dir,
            "settings.json",
            open_mode,
        ) catch |err| switch (err) {
            error.FileNotFound => return .absent,
            error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
            else => return err,
        };
        defer file.close(zio);

        const stat = try file.stat(zio);
        try io_mod.verifyOpenedRegularFile(stat, open_mode);
        if (self.mode == .writable) {
            file.setPermissions(zio, std.Io.File.Permissions.fromMode(0o600)) catch {
                return error.PrivateStatePermissionsUnsupported;
            };
        }
        const verified_stat = if (self.mode == .writable) try file.stat(zio) else stat;
        const primary_mode = verified_stat.permissions.toMode() & 0o777;
        if (self.mode == .writable and primary_mode != 0o600) {
            return error.PrivateStatePermissionsUnsupported;
        }
        if (self.mode == .read_only and durableModeWritableByGroupOrOther(primary_mode)) {
            return error.PrivateStatePermissionsUnsupported;
        }
        if (verified_stat.size > max_settings_bytes) return .oversized;
        return .{ .bytes = try io_mod.readFileToEnd(alloc, &file, max_settings_bytes + 1) };
    }

    fn createBackupBestEffort(self: *Store, alloc: Allocator, bytes: []const u8) void {
        self.createSequencedCopy(alloc, "backup", bytes, backup_keep_count) catch |err| {
            debug_trace.logf("config", "settings backup skipped err={s}", .{@errorName(err)});
        };
    }

    fn copyCorruptBestEffort(self: *Store, alloc: Allocator, bytes: []const u8) void {
        self.createSequencedCopy(alloc, "corrupt", bytes, corrupt_keep_count) catch |err| {
            debug_trace.logf("config", "settings corrupt copy skipped err={s}", .{@errorName(err)});
        };
    }

    fn durableModeWritableByGroupOrOther(mode: std.posix.mode_t) bool {
        return mode & 0o022 != 0;
    }

    fn createSequencedCopy(
        self: *Store,
        alloc: Allocator,
        kind: []const u8,
        bytes: []const u8,
        keep_count: usize,
    ) !void {
        var backups = try io_mod.openOrCreateVerifiedPrivateDir(&self.durable_home.?, profile_paths.backups_dir_name);
        defer backups.close();
        if (std.mem.eql(u8, kind, "corrupt") and try containsCopyWithFingerprint(alloc, backups.dir, kind, bytes)) return;

        const sequence = try nextBackupSequence(backups.dir);
        var random_bytes: [16]u8 = undefined;
        io_mod.getIo().random(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
        const name = try std.fmt.allocPrint(
            alloc,
            "settings.json.{s}.{d}-{x:0>16}-{s}",
            .{ kind, io_mod.milliTimestamp(), sequence, random_hex },
        );
        defer alloc.free(name);
        try io_mod.durableReplaceVerified(alloc, &backups, name, bytes);
        try pruneSequencedCopies(alloc, backups.dir, kind, keep_count);
    }

    fn writeMigrationSnapshots(
        self: *Store,
        alloc: Allocator,
        migration_fields: u16,
        existing: ?[]const u8,
    ) ![]const []const u8 {
        if (migration_fields == 0) return &.{};
        const bytes = existing orelse return error.InvalidSettingsFormat;
        if (self.fail_migration_snapshot) return error.InjectedMigrationSnapshotFailure;
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (paths.items) |path| alloc.free(path);
            paths.deinit(alloc);
        }

        var backups = try io_mod.openOrCreateVerifiedPrivateDir(&self.durable_home.?, profile_paths.backups_dir_name);
        defer backups.close();
        for (user_preference_fields) |field| {
            if (migration_fields & field.mask() == 0) continue;
            const name = field.snapshotName();
            try io_mod.durableReplaceVerified(alloc, &backups, name, bytes);
            try paths.append(
                alloc,
                try std.fs.path.join(alloc, &.{ self.display_root, profile_paths.backups_dir_name, name }),
            );
        }
        return paths.toOwnedSlice(alloc);
    }
};

fn freeRecoveryPaths(alloc: Allocator, paths: []const []const u8) void {
    for (paths) |path| alloc.free(path);
    alloc.free(paths);
}

fn failStoreParentSync(_: ?*anyopaque, _: std.Io.Dir) anyerror!void {
    return error.InjectedParentSyncFailure;
}

fn validateWorkspaceRoot(workspace_root: []const u8) !void {
    if (workspace_root.len == 0 or workspace_root.len > std.fs.max_path_bytes) return error.InvalidDurableField;
    if (!std.fs.path.isAbsolute(workspace_root) or !std.unicode.utf8ValidateSlice(workspace_root)) {
        return error.InvalidDurableField;
    }
}

fn validateMutation(mutation: SettingsMutation) !void {
    switch (mutation) {
        .user => |patch| try validateUserPatch(patch),
        .workspace_directory => |workspace| {
            try validateWorkspaceRoot(workspace.workspace_root);
            if (workspace.observed_sources.len > workspace_access.max_additional_directories) {
                return error.InvalidDurableField;
            }
            for (workspace.observed_sources, 0..) |source, index| {
                if (!validAdditionalDirectoryPath(source.source) or
                    !validAdditionalDirectoryPath(source.identity))
                {
                    return error.InvalidDurableField;
                }
                for (workspace.observed_sources[0..index]) |previous| {
                    if (std.mem.eql(u8, source.source, previous.source)) {
                        return error.InvalidDurableField;
                    }
                }
            }
            if (workspace.command_line_directories.len > workspace_access.max_additional_directories) {
                return error.InvalidDurableField;
            }
            for (workspace.command_line_directories) |path| {
                if (!validAdditionalDirectoryPath(path)) return error.InvalidDurableField;
            }
            switch (workspace.patch) {
                .add, .remove => |path| if (!validAdditionalDirectoryPath(path)) {
                    return error.InvalidDurableField;
                },
                .clear => {},
            }
        },
        .permission => |permission| switch (permission.scope) {
            .user => if (permission.workspace_root != null) return error.InvalidDurableField,
            .local => {
                const workspace_root = permission.workspace_root orelse return error.InvalidDurableField;
                try validateWorkspaceRoot(workspace_root);
            },
        },
    }
}

pub fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > max_model_bytes or !std.unicode.utf8ValidateSlice(model)) {
        return error.InvalidDurableField;
    }
    if (!std.mem.eql(u8, model, std.mem.trim(u8, model, " \t\r\n"))) return error.InvalidDurableField;
    for (model) |byte| {
        if (std.ascii.isControl(byte)) return error.InvalidDurableField;
    }
}

fn validateUserPatch(patch: UserSettingsPatch) !void {
    if (patch.model) |model| try validateModel(model);
}

fn validAdditionalDirectoryPath(path: []const u8) bool {
    return path.len > 0 and path.len <= std.fs.max_path_bytes and
        std.fs.path.isAbsolute(path) and std.unicode.utf8ValidateSlice(path) and
        std.mem.findScalar(u8, path, 0) == null;
}

test "clearing the credential choice removes the key rather than blanking it" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"model\":\"m\",\"credential_source\":\"fx_login\"}",
        .{},
    );
    var application = try applyUserPatchToRoot(arena.allocator(), &root, .{ .clear_credential_source = true });
    try std.testing.expect(application.changed);
    try std.testing.expect(!root.object.contains("credential_source"));
    try std.testing.expect(root.object.contains("model"));

    application = try applyUserPatchToRoot(arena.allocator(), &root, .{ .clear_credential_source = true });
    try std.testing.expect(!application.changed);
}

test "provider patch keeps independent provider models" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"model\":\"gateway/model\"}",
        .{},
    );
    const application = try applyUserPatchToRoot(arena.allocator(), &root, .{
        .provider = .codex,
        .codex_model = "gpt-5.4-mini",
        .grok_model = "grok-4.20-0309-non-reasoning",
    });
    try std.testing.expect(application.changed);
    try std.testing.expectEqualStrings("gateway/model", root.object.get("model").?.string);
    try std.testing.expectEqualStrings("codex", root.object.get("provider").?.string);
    try std.testing.expectEqualStrings("gpt-5.4-mini", root.object.get("codex_model").?.string);
    try std.testing.expectEqualStrings("grok-4.20-0309-non-reasoning", root.object.get("grok_model").?.string);
    try std.testing.expectEqual(model_provider.ProviderId.codex, model_provider.parse(root.object.get("provider").?.string).?);
}

fn applyMutationToRoot(
    arena: Allocator,
    root: *std.json.Value,
    mutation: SettingsMutation,
) !PatchApplication {
    const retired_settings_removed = removeRetiredPresentationSettings(&root.object);
    var application = try switch (mutation) {
        .user => |patch| applyUserPatchToRoot(arena, root, patch),
        .workspace_directory => |workspace| applyWorkspaceDirectoryMutationToRoot(
            arena,
            root,
            workspace,
        ),
        .permission => |permission| applyPermissionMutationToRoot(arena, root, permission),
    };
    application.changed = application.changed or retired_settings_removed;
    return application;
}

fn applyUserPatchToRoot(
    arena: Allocator,
    root: *std.json.Value,
    patch: UserSettingsPatch,
) !PatchApplication {
    var application = PatchApplication{};
    if (patch.model) |value| application.changed = try putString(arena, &root.object, "model", value) or application.changed;
    if (patch.provider) |value| application.changed = try putString(arena, &root.object, "provider", @tagName(value)) or application.changed;
    if (patch.codex_model) |value| application.changed = try putString(arena, &root.object, "codex_model", value) or application.changed;
    if (patch.grok_model) |value| application.changed = try putString(arena, &root.object, "grok_model", value) or application.changed;
    if (patch.claude_model) |value| application.changed = try putString(arena, &root.object, "claude_model", value) or application.changed;
    if (patch.permission_mode) |value| application.changed = try putString(arena, &root.object, "permission_mode", @tagName(value)) or application.changed;
    if (patch.credential_source) |value| application.changed = try putString(arena, &root.object, "credential_source", @tagName(value)) or application.changed;
    if (patch.clear_credential_source and root.object.contains("credential_source")) {
        _ = root.object.orderedRemove("credential_source");
        application.changed = true;
    }
    if (patch.yolo_acknowledged) |value| application.changed = try putBool(arena, &root.object, "yolo_acknowledged", value) or application.changed;
    if (patch.effort) |value| application.changed = try putString(arena, &root.object, "effort", value.label()) or application.changed;
    if (patch.fast_mode) |value| application.changed = try putBool(arena, &root.object, "fast_mode", value) or application.changed;
    if (patch.slash_menu_categories) |value| application.changed = try putBool(arena, &root.object, "slash_menu_categories", value) or application.changed;
    if (patch.update_channel) |value| application.changed = try putString(arena, &root.object, "update_channel", value.label()) or application.changed;
    if (patch.startup_scrollback) |value| application.changed = try putBool(arena, &root.object, "startup_scrollback", value) or application.changed;

    if (patch.prompt_history_enabled) |enabled| {
        var prompt_history = if (root.object.getPtr("prompt_history")) |value| blk: {
            if (value.* != .object) return error.InvalidSettingsFormat;
            break :blk value;
        } else blk: {
            try root.object.put(arena, "prompt_history", .{ .object = .empty });
            break :blk root.object.getPtr("prompt_history").?;
        };
        application.changed = try putBool(arena, &prompt_history.object, "enabled", enabled) or application.changed;
    }

    if (patch.statusline_item) |item_patch| {
        var statusline = if (root.object.getPtr("statusLine")) |value| blk: {
            if (value.* != .object) return error.InvalidSettingsFormat;
            break :blk value;
        } else blk: {
            try root.object.put(arena, "statusLine", .{ .object = .empty });
            break :blk root.object.getPtr("statusLine").?;
        };
        application.changed = try putBool(arena, &statusline.object, @tagName(item_patch.item), item_patch.enabled) or application.changed;
    }

    if (patch.notification_turn_end != null or
        patch.notification_attention_required != null or
        patch.notification_max != null)
    {
        var notifications = if (root.object.getPtr("notifications")) |value| blk: {
            if (value.* != .object) return error.InvalidSettingsFormat;
            break :blk value;
        } else blk: {
            try root.object.put(arena, "notifications", .{ .object = .empty });
            break :blk root.object.getPtr("notifications").?;
        };
        if (patch.notification_turn_end) |enabled| {
            application.changed = try putBool(arena, &notifications.object, "turn_end", enabled) or application.changed;
        }
        if (patch.notification_attention_required) |enabled| {
            application.changed = try putBool(arena, &notifications.object, "attention_required", enabled) or application.changed;
        }
        if (patch.notification_max) |enabled| {
            application.changed = try putBool(arena, &notifications.object, "max", enabled) or application.changed;
        }
    }
    try cleanupLegacyWorkspacePreferences(arena, root, patch, &application);
    return application;
}

fn removeRetiredPresentationSettings(root: *std.json.ObjectMap) bool {
    var changed = false;
    inline for (&.{ "input_appearance", "maxxing_mode" }) |key| {
        if (root.contains(key)) {
            _ = root.orderedRemove(key);
            changed = true;
        }
    }

    const workspaces = root.getPtr("workspaces") orelse return changed;
    if (workspaces.* != .object) return changed;
    var iterator = workspaces.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        inline for (&.{ "input_appearance", "maxxing_mode" }) |key| {
            if (entry.value_ptr.object.contains(key)) {
                _ = entry.value_ptr.object.orderedRemove(key);
                changed = true;
            }
        }
    }
    return changed;
}

fn cleanupLegacyWorkspacePreferences(
    arena: Allocator,
    root: *std.json.Value,
    patch: UserSettingsPatch,
    application: *PatchApplication,
) !void {
    const workspaces = root.object.getPtr("workspaces") orelse return;
    if (workspaces.* != .object) return error.InvalidSettingsFormat;

    var empty_workspaces: std.ArrayList([]const u8) = .empty;
    defer empty_workspaces.deinit(arena);
    var iterator = workspaces.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const removed_before = application.legacy_fields_removed;

        removeLegacyLeaf(
            &entry.value_ptr.object,
            "model",
            .model,
            patch.model != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "permission_mode",
            .permission_mode,
            patch.permission_mode != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "effort",
            .effort,
            patch.effort != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "fast_mode",
            .fast_mode,
            patch.fast_mode != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "slash_menu_categories",
            .slash_menu_categories,
            patch.slash_menu_categories != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "update_channel",
            .update_channel,
            patch.update_channel != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "startup_scrollback",
            .startup_scrollback,
            patch.startup_scrollback != null,
            application,
        );
        removeLegacyNestedLeaf(
            &entry.value_ptr.object,
            "prompt_history",
            "enabled",
            .prompt_history_enabled,
            patch.prompt_history_enabled != null,
            application,
        );
        if (patch.statusline_item) |item_patch| {
            const legacy_field: ?UserPreferenceField = switch (item_patch.item) {
                .context => .statusline_context,
                .session => .statusline_session,
                .workspace => null,
            };
            if (legacy_field) |field| {
                removeLegacyNestedLeaf(
                    &entry.value_ptr.object,
                    "statusLine",
                    @tagName(item_patch.item),
                    field,
                    true,
                    application,
                );
            }
        }
        if (application.legacy_fields_removed != removed_before) {
            application.legacy_workspaces_changed += 1;
            if (entry.value_ptr.object.count() == 0) {
                try empty_workspaces.append(arena, entry.key_ptr.*);
            }
        }
    }
    for (empty_workspaces.items) |workspace_root| {
        _ = workspaces.object.orderedRemove(workspace_root);
    }
}

fn removeLegacyLeaf(
    object: *std.json.ObjectMap,
    key: []const u8,
    field: UserPreferenceField,
    enabled: bool,
    application: *PatchApplication,
) void {
    if (!enabled or !object.contains(key)) return;
    _ = object.orderedRemove(key);
    application.changed = true;
    application.legacy_fields_removed += 1;
    application.migration_fields |= field.mask();
}

fn removeLegacyNestedLeaf(
    object: *std.json.ObjectMap,
    container_key: []const u8,
    leaf_key: []const u8,
    field: UserPreferenceField,
    enabled: bool,
    application: *PatchApplication,
) void {
    if (!enabled) return;
    const container = object.getPtr(container_key) orelse return;
    if (container.* != .object or !container.object.contains(leaf_key)) return;
    _ = container.object.orderedRemove(leaf_key);
    if (container.object.count() == 0) _ = object.orderedRemove(container_key);
    application.changed = true;
    application.legacy_fields_removed += 1;
    application.migration_fields |= field.mask();
}

fn applyWorkspaceDirectoryMutationToRoot(
    arena: Allocator,
    root: *std.json.Value,
    mutation: WorkspaceDirectoryMutation,
) !PatchApplication {
    const workspace = try workspaceObject(arena, root, mutation.workspace_root);
    const existing = workspace.getPtr("additional_directories");
    var changed = false;
    var unseen_sources = switch (mutation.patch) {
        .add, .remove => try unseenWorkspaceSourceStrings(
            arena,
            existing,
            mutation.observed_sources,
        ),
        .clear => std.ArrayList([]const u8).empty,
    };
    defer unseen_sources.deinit(arena);

    switch (mutation.patch) {
        .add => |path| {
            var identities: std.ArrayList([]const u8) = .empty;
            defer identities.deinit(arena);
            var saved_contains_path = containsWorkspaceIdentity(unseen_sources.items, path);

            if (existing) |directories| {
                var index: usize = 0;
                while (index < directories.array.items.len) {
                    const entry = directories.array.items[index];
                    const observed = observedWorkspaceSource(mutation.observed_sources, entry.string) orelse {
                        index += 1;
                        continue;
                    };
                    saved_contains_path = saved_contains_path or std.mem.eql(u8, observed.identity, path);
                    if (containsWorkspaceIdentity(unseen_sources.items, observed.identity)) {
                        _ = directories.array.orderedRemove(index);
                        changed = true;
                        continue;
                    }
                    if (!try appendUniqueWorkspaceIdentity(arena, &identities, observed.identity)) {
                        _ = directories.array.orderedRemove(index);
                        changed = true;
                        continue;
                    }
                    if (!std.mem.eql(u8, entry.string, observed.identity)) {
                        directories.array.items[index] = .{
                            .string = try arena.dupe(u8, observed.identity),
                        };
                        changed = true;
                    }
                    index += 1;
                }
            }
            for (mutation.command_line_directories) |command_line_path| {
                if (containsWorkspaceIdentity(unseen_sources.items, command_line_path)) continue;
                _ = try appendUniqueWorkspaceIdentity(arena, &identities, command_line_path);
            }
            if (!saved_contains_path) {
                _ = try appendUniqueWorkspaceIdentity(arena, &identities, path);
            }
            const effective_count = std.math.add(usize, identities.items.len, unseen_sources.items.len) catch {
                return error.TooManyDirectories;
            };
            if (effective_count > workspace_access.max_additional_directories) {
                return error.TooManyDirectories;
            }

            if (saved_contains_path) {
                removeWorkspaceIfEmpty(root, mutation.workspace_root);
                return .{ .changed = changed };
            }
            if (existing) |directories| {
                try directories.array.append(.{ .string = try arena.dupe(u8, path) });
            } else {
                var directories = std.json.Array.init(arena);
                try directories.append(.{ .string = try arena.dupe(u8, path) });
                try workspace.put(arena, "additional_directories", .{ .array = directories });
            }
            changed = true;
        },
        .remove => |path| {
            var target_was_saved = false;
            for (mutation.observed_sources) |source| {
                if (std.mem.eql(u8, source.identity, path)) {
                    target_was_saved = true;
                    break;
                }
            }
            if (!target_was_saved) {
                removeWorkspaceIfEmpty(root, mutation.workspace_root);
                return .{};
            }
            const directories = existing orelse {
                removeWorkspaceIfEmpty(root, mutation.workspace_root);
                return .{};
            };
            if (directories.* != .array) return error.InvalidSettingsFormat;
            var survivor_identities: std.ArrayList([]const u8) = .empty;
            defer survivor_identities.deinit(arena);
            var index: usize = 0;
            while (index < directories.array.items.len) {
                const entry = directories.array.items[index];
                if (entry != .string) return error.InvalidSettingsFormat;
                const observed = observedWorkspaceSource(mutation.observed_sources, entry.string) orelse {
                    if (std.mem.eql(u8, entry.string, path)) {
                        _ = directories.array.orderedRemove(index);
                        changed = true;
                        continue;
                    }
                    index += 1;
                    continue;
                };
                if (std.mem.eql(u8, observed.identity, path)) {
                    _ = directories.array.orderedRemove(index);
                    changed = true;
                    continue;
                }
                if (containsWorkspaceIdentity(unseen_sources.items, observed.identity)) {
                    _ = directories.array.orderedRemove(index);
                    changed = true;
                    continue;
                }
                if (!try appendUniqueWorkspaceIdentity(arena, &survivor_identities, observed.identity)) {
                    _ = directories.array.orderedRemove(index);
                    changed = true;
                    continue;
                }
                if (!std.mem.eql(u8, entry.string, observed.identity)) {
                    directories.array.items[index] = .{
                        .string = try arena.dupe(u8, observed.identity),
                    };
                    changed = true;
                }
                index += 1;
            }
            if (directories.array.items.len == 0) _ = workspace.orderedRemove("additional_directories");
        },
        .clear => {
            changed = workspace.orderedRemove("additional_directories");
        },
    }

    removeWorkspaceIfEmpty(root, mutation.workspace_root);
    return .{ .changed = changed };
}

fn unseenWorkspaceSourceStrings(
    arena: Allocator,
    existing: ?*std.json.Value,
    observed_sources: []const workspace_access.SavedSource,
) !std.ArrayList([]const u8) {
    var unseen_sources: std.ArrayList([]const u8) = .empty;
    errdefer unseen_sources.deinit(arena);
    const directories = existing orelse return unseen_sources;
    if (directories.* != .array) return error.InvalidSettingsFormat;
    for (directories.array.items) |entry| {
        if (entry != .string) return error.InvalidSettingsFormat;
        if (observedWorkspaceSource(observed_sources, entry.string) == null) {
            try unseen_sources.append(arena, entry.string);
        }
    }
    return unseen_sources;
}

fn observedWorkspaceSource(
    observed_sources: []const workspace_access.SavedSource,
    source_path: []const u8,
) ?workspace_access.SavedSource {
    for (observed_sources) |source| {
        if (std.mem.eql(u8, source.source, source_path)) return source;
    }
    return null;
}

fn containsWorkspaceIdentity(identities: []const []const u8, identity: []const u8) bool {
    for (identities) |existing| {
        if (std.mem.eql(u8, existing, identity)) return true;
    }
    return false;
}

fn appendUniqueWorkspaceIdentity(
    arena: Allocator,
    identities: *std.ArrayList([]const u8),
    identity: []const u8,
) !bool {
    if (containsWorkspaceIdentity(identities.items, identity)) return false;
    try identities.append(arena, identity);
    return true;
}

fn removeWorkspaceIfEmpty(root: *std.json.Value, workspace_root: []const u8) void {
    const workspaces = root.object.getPtr("workspaces") orelse return;
    if (workspaces.* != .object) return;
    const workspace = workspaces.object.get(workspace_root) orelse return;
    if (workspace != .object or workspace.object.count() != 0) return;
    _ = workspaces.object.orderedRemove(workspace_root);
    if (workspaces.object.count() == 0) _ = root.object.orderedRemove("workspaces");
}

fn applyPermissionMutationToRoot(
    arena: Allocator,
    root: *std.json.Value,
    mutation: PermissionMutation,
) !PatchApplication {
    const target = switch (mutation.scope) {
        .user => &root.object,
        .local => try workspaceObject(arena, root, mutation.workspace_root.?),
    };
    return applyPermissionPatch(arena, target, mutation.patch);
}

fn workspaceObject(
    arena: Allocator,
    root: *std.json.Value,
    workspace_root: []const u8,
) !*std.json.ObjectMap {
    var workspaces = if (root.object.getPtr("workspaces")) |value| blk: {
        if (value.* != .object) return error.InvalidSettingsFormat;
        break :blk value;
    } else blk: {
        try root.object.put(arena, "workspaces", .{ .object = .empty });
        break :blk root.object.getPtr("workspaces").?;
    };
    const workspace = if (workspaces.object.getPtr(workspace_root)) |value| blk: {
        if (value.* != .object) return error.InvalidSettingsFormat;
        break :blk value;
    } else blk: {
        const owned_root = try arena.dupe(u8, workspace_root);
        try workspaces.object.put(arena, owned_root, .{ .object = .empty });
        break :blk workspaces.object.getPtr(owned_root).?;
    };
    return &workspace.object;
}

fn putString(arena: Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !bool {
    if (object.get(key)) |existing| {
        if (existing == .string and std.mem.eql(u8, existing.string, value)) return false;
    }
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
    return true;
}

fn putBool(arena: Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !bool {
    if (object.get(key)) |existing| {
        if (existing == .bool and existing.bool == value) return false;
    }
    try object.put(arena, key, .{ .bool = value });
    return true;
}

fn applyPermissionPatch(
    arena: Allocator,
    workspace: *std.json.ObjectMap,
    patch: PermissionPatch,
) !PatchApplication {
    return switch (patch) {
        .add => |add| blk: {
            var permission = try permissionObject(arena, workspace, true) orelse {
                return error.InvalidSettingsFormat;
            };
            var category = if (permission.object.getPtr(add.category)) |value| category_blk: {
                if (value.* == .object) break :category_blk value;
                var replacement = std.json.Value{ .object = .empty };
                try replacement.object.put(arena, "*", value.*);
                try permission.object.put(arena, try arena.dupe(u8, add.category), replacement);
                break :category_blk permission.object.getPtr(add.category).?;
            } else category_blk: {
                try permission.object.put(arena, try arena.dupe(u8, add.category), .{ .object = .empty });
                break :category_blk permission.object.getPtr(add.category).?;
            };
            const action = @tagName(add.action);
            if (category.object.get(add.pattern)) |existing| {
                if (existing == .string and std.mem.eql(u8, existing.string, action)) break :blk .{};
            }
            try category.object.put(arena, try arena.dupe(u8, add.pattern), .{ .string = action });
            break :blk .{ .changed = true };
        },
        .remove => |remove| blk: {
            const permission = try permissionObject(arena, workspace, false) orelse break :blk .{};
            const category_key = canonicalPermissionKey(&permission.object, remove.category) orelse break :blk .{};
            const category = permission.object.getPtr(category_key) orelse break :blk .{};
            if (category.* != .object) break :blk .{};
            const pattern_key = canonicalPermissionKey(&category.object, remove.pattern) orelse break :blk .{};
            _ = category.object.orderedRemove(pattern_key);
            if (category.object.count() == 0) _ = permission.object.orderedRemove(category_key);
            break :blk .{ .changed = true, .permission_rules_removed = 1 };
        },
        .reset => |scope| blk: {
            const permission = try permissionObject(arena, workspace, false) orelse break :blk .{};
            var removed: usize = 0;
            while (removeOneAllowlistRule(&permission.object, scope)) removed += 1;
            if (permission.object.count() == 0) _ = workspace.orderedRemove("permission");
            break :blk .{
                .changed = removed > 0,
                .permission_rules_removed = removed,
            };
        },
    };
}

fn permissionObject(
    arena: Allocator,
    workspace: *std.json.ObjectMap,
    create: bool,
) !?*std.json.Value {
    if (workspace.getPtr("permission")) |value| {
        if (value.* != .object) return error.InvalidSettingsFormat;
        return value;
    }
    if (!create) return null;
    try workspace.put(arena, "permission", .{ .object = .empty });
    return workspace.getPtr("permission").?;
}

fn removeOneAllowlistRule(permission: *std.json.ObjectMap, scope: AllowlistResetScope) bool {
    var it = permission.iterator();
    while (it.next()) |entry| {
        if (!scopeMatchesCategory(scope, entry.key_ptr.*)) continue;
        switch (entry.value_ptr.*) {
            .string => |action| {
                if (!std.ascii.eqlIgnoreCase(action, "allow")) continue;
                _ = permission.orderedRemove(entry.key_ptr.*);
                return true;
            },
            .object => |*category| {
                var category_it = category.iterator();
                while (category_it.next()) |rule| {
                    if (rule.value_ptr.* != .string or
                        !std.ascii.eqlIgnoreCase(rule.value_ptr.string, "allow"))
                    {
                        continue;
                    }
                    _ = category.orderedRemove(rule.key_ptr.*);
                    if (category.count() == 0) _ = permission.orderedRemove(entry.key_ptr.*);
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn scopeMatchesCategory(scope: AllowlistResetScope, category: []const u8) bool {
    const canonical = std.mem.trim(u8, category, " \t\r\n");
    const is_url = std.mem.eql(u8, canonical, "url") or
        std.mem.eql(u8, canonical, "open_url") or
        std.mem.eql(u8, canonical, "browser_navigate");
    const is_fetch = std.mem.eql(u8, canonical, "web_fetch");
    return switch (scope) {
        .all => true,
        .commands => std.mem.eql(u8, canonical, "bash"),
        .urls => is_url,
        .web_fetch_domains => is_fetch,
        .tools => !std.mem.eql(u8, canonical, "bash") and !is_url and !is_fetch and
            !std.mem.eql(u8, canonical, "*"),
    };
}

fn canonicalPermissionKey(object: *const std.json.ObjectMap, expected: []const u8) ?[]const u8 {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(
            u8,
            std.mem.trim(u8, entry.key_ptr.*, " \t\r\n"),
            expected,
        )) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

fn serializeJson(alloc: Allocator, root: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeJsonValue(&out.writer, root);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writer.print("{d}", .{float}),
        .string => |string| try std.json.Stringify.value(string, .{}, writer),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            try writer.writeByte('{');
            var first = true;
            var it = object.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .number_string => |number| try writer.writeAll(number),
    }
}

fn validateCandidate(
    alloc: Allocator,
    bytes: []const u8,
    mutation: SettingsMutation,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch {
        return error.InvalidSettingsFormat;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettingsFormat;
    try validateKnownSettingsObject(parsed.value.object, false);
    const workspace_root = switch (mutation) {
        .user => return,
        .workspace_directory => |workspace| workspace.workspace_root,
        .permission => |permission| switch (permission.scope) {
            .user => return,
            .local => permission.workspace_root.?,
        },
    };
    const workspace_may_be_absent = switch (mutation) {
        .workspace_directory => |workspace| workspace.patch != .add,
        else => false,
    };
    const workspaces = parsed.value.object.get("workspaces") orelse {
        if (workspace_may_be_absent) return;
        return error.InvalidSettingsFormat;
    };
    if (workspaces != .object) return error.InvalidSettingsFormat;
    const workspace = workspaces.object.get(workspace_root) orelse {
        if (workspace_may_be_absent) return;
        return error.InvalidSettingsFormat;
    };
    if (workspace != .object) return error.InvalidSettingsFormat;
    try validateKnownSettingsObject(workspace.object, true);
}

fn validateKnownSettingsObject(
    object: std.json.ObjectMap,
    tolerate_non_object_user_containers: bool,
) !void {
    if (object.get("model")) |value| {
        if (value != .string) return error.InvalidSettingsFormat;
        try validateModel(value.string);
    }
    if (object.get("provider")) |value| {
        if (value != .string or model_provider.parse(value.string) == null) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("codex_model")) |value| {
        if (value != .string) return error.InvalidSettingsFormat;
        try validateModel(value.string);
    }
    if (object.get("grok_model")) |value| {
        if (value != .string) return error.InvalidSettingsFormat;
        try validateModel(value.string);
    }
    if (object.get("claude_model")) |value| {
        if (value != .string) return error.InvalidSettingsFormat;
        try validateModel(value.string);
    }
    if (object.get("permission_mode")) |value| {
        if (value != .string or
            (!std.ascii.eqlIgnoreCase(value.string, "ask") and
                !std.ascii.eqlIgnoreCase(value.string, "auto") and
                !std.ascii.eqlIgnoreCase(value.string, "yolo")))
        {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("credential_source")) |value| {
        if (value != .string or types.parseCredentialSource(value.string) == null) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("max_agent_steps")) |value| {
        if (value != .integer or value.integer < 0) return error.InvalidSettingsFormat;
    }
    if (object.get("max_tool_result_bytes")) |value| {
        if (value != .integer or value.integer < tool_result_limits.min_configured_tool_result_bytes) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("skill_match_fuzzy")) |value| {
        if (value != .bool) return error.InvalidSettingsFormat;
    }
    if (object.get("context_limits")) |value| {
        _ = context_limits.parseJsonObject(value) catch return error.InvalidSettingsFormat;
    }
    inline for (&.{ "context", "fast_mode", "auto_upgrade", "slash_menu_categories", "startup_scrollback", "yolo_acknowledged" }) |key| {
        if (object.get(key)) |value| {
            if (value != .bool) return error.InvalidSettingsFormat;
        }
    }
    if (object.get("update_channel")) |value| {
        if (value != .string or update_target.Channel.parse(value.string) == null) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("effort")) |value| {
        switch (value) {
            .null => {},
            .string => |raw| if (types.ReasoningEffort.parse(raw) == null) return error.InvalidSettingsFormat,
            else => return error.InvalidSettingsFormat,
        }
    }
    if (object.get("additional_directories")) |value| {
        if (value != .array or value.array.items.len > workspace_access.max_additional_directories) {
            return error.InvalidSettingsFormat;
        }
        for (value.array.items, 0..) |item, index| {
            if (item != .string) return error.InvalidSettingsFormat;
            const path = item.string;
            if (!validAdditionalDirectoryPath(path)) return error.InvalidSettingsFormat;
            for (value.array.items[0..index]) |previous| {
                if (previous == .string and std.mem.eql(u8, path, previous.string)) {
                    return error.InvalidSettingsFormat;
                }
            }
        }
    }
    if (object.get("prompt_history")) |value| {
        if (value == .object) {
            if (value.object.get("enabled")) |enabled| {
                if (enabled != .bool) return error.InvalidSettingsFormat;
            }
        } else if (!tolerate_non_object_user_containers) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("statusLine")) |value| {
        if (value == .object) {
            inline for (&.{"context"}) |key| {
                if (value.object.get(key)) |enabled| {
                    if (enabled != .bool) return error.InvalidSettingsFormat;
                }
            }
            if (!tolerate_non_object_user_containers) {
                if (value.object.get("workspace")) |enabled| {
                    if (enabled != .bool) return error.InvalidSettingsFormat;
                }
            }
        } else if (!tolerate_non_object_user_containers) {
            return error.InvalidSettingsFormat;
        }
    }
}

fn fingerprintOptional(bytes: ?[]const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (bytes) |value| {
        std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    } else {
        std.crypto.hash.sha2.Sha256.hash("absent settings primary", &digest, .{});
    }
    return digest;
}

fn parseSequence(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "settings.json.backup.") and
        !std.mem.startsWith(u8, name, "settings.json.corrupt."))
    {
        return null;
    }
    const first_dash = std.mem.indexOfScalar(u8, name, '-') orelse return null;
    const sequence_start = first_dash + 1;
    if (sequence_start + 16 >= name.len or name[sequence_start + 16] != '-') return null;
    return std.fmt.parseInt(u64, name[sequence_start .. sequence_start + 16], 16) catch null;
}

fn parseBackupTimestamp(name: []const u8) ?i64 {
    const prefixes = [_][]const u8{
        "settings.json.backup.",
        "settings.json.corrupt.",
    };
    var suffix: ?[]const u8 = null;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            suffix = name[prefix.len..];
            break;
        }
    }
    const text = suffix orelse return null;
    const end = std.mem.indexOfScalar(u8, text, '-') orelse text.len;
    if (end == 0) return null;
    return std.fmt.parseInt(i64, text[0..end], 10) catch null;
}

pub fn backupNameNewerThan(lhs: []const u8, rhs: []const u8) bool {
    const lhs_sequence = parseSequence(lhs);
    const rhs_sequence = parseSequence(rhs);
    if (lhs_sequence != null and rhs_sequence != null and lhs_sequence.? != rhs_sequence.?) {
        return lhs_sequence.? > rhs_sequence.?;
    }
    if (lhs_sequence != null and rhs_sequence == null) return true;
    if (lhs_sequence == null and rhs_sequence != null) return false;
    const lhs_timestamp = parseBackupTimestamp(lhs);
    const rhs_timestamp = parseBackupTimestamp(rhs);
    if (lhs_timestamp != null and rhs_timestamp != null and lhs_timestamp.? != rhs_timestamp.?) {
        return lhs_timestamp.? > rhs_timestamp.?;
    }
    return std.mem.order(u8, lhs, rhs) == .gt;
}

fn nextBackupSequence(dir: std.Io.Dir) !u64 {
    var iterator = dir.iterate();
    var maximum: u64 = 0;
    while (try iterator.next(io_mod.getIo())) |entry| {
        const sequence = parseSequence(entry.name) orelse continue;
        maximum = @max(maximum, sequence);
    }
    return std.math.add(u64, maximum, 1) catch error.BackupSequenceExhausted;
}

fn containsCopyWithFingerprint(
    alloc: Allocator,
    dir: std.Io.Dir,
    kind: []const u8,
    bytes: []const u8,
) !bool {
    const expected = fingerprintOptional(bytes);
    const prefix = try std.fmt.allocPrint(alloc, "settings.json.{s}.", .{kind});
    defer alloc.free(prefix);
    var iterator = dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const stat = dir.statFile(io_mod.getIo(), entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file or stat.nlink != 1 or stat.size > max_settings_bytes) continue;
        var file = dir.openFile(io_mod.getIo(), entry.name, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch continue;
        defer file.close(io_mod.getIo());
        const copy = io_mod.readFileToEnd(alloc, &file, max_settings_bytes + 1) catch continue;
        defer alloc.free(copy);
        const copy_fingerprint = fingerprintOptional(copy);
        if (std.mem.eql(u8, &expected, &copy_fingerprint)) return true;
    }
    return false;
}

fn pruneSequencedCopies(
    alloc: Allocator,
    dir: std.Io.Dir,
    kind: []const u8,
    keep_count: usize,
) !void {
    const prefix = try std.fmt.allocPrint(alloc, "settings.json.{s}.", .{kind});
    defer alloc.free(prefix);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or parseBackupTimestamp(entry.name) == null) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    sort_utils.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return backupNameNewerThan(lhs, rhs);
        }
    }.lessThan);
    if (names.items.len <= keep_count) return;
    var deleted = false;
    for (names.items[keep_count..]) |name| {
        const stat = dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file or stat.nlink != 1) continue;
        dir.deleteFile(io_mod.getIo(), name) catch |err| {
            debug_trace.logf("config", "settings backup prune skipped err={s}", .{@errorName(err)});
            continue;
        };
        deleted = true;
    }
    if (deleted) try io_mod.syncVerifiedDir(dir);
}

fn writeStoreFixture(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

test "user patch writes user preferences at top level" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", "{\"future\":{\"nested\":7}}\n");

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{
        .model = "openai/gpt-5.4",
        .permission_mode = .yolo,
        .yolo_acknowledged = true,
        .effort = types.ReasoningEffort.literal("high"),
        .fast_mode = true,
        .slash_menu_categories = false,
        .update_channel = .dev,
        .startup_scrollback = false,
        .prompt_history_enabled = false,
        .statusline_item = .{ .item = .context, .enabled = true },
        .notification_turn_end = true,
        .notification_attention_required = false,
    });
    defer outcome.deinit(alloc);

    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(SettingsScope.user, outcome.committed.scope);
    try std.testing.expectEqual(@as(usize, 0), outcome.committed.cleanup.fields_removed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"model\":\"openai/gpt-5.4\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"permission_mode\":\"yolo\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"yolo_acknowledged\":true") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"fast_mode\":true") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"slash_menu_categories\":false") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"update_channel\":\"dev\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"startup_scrollback\":false") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"prompt_history\":{\"enabled\":false}") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"statusLine\":{\"context\":true}") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"notifications\":{\"turn_end\":true,\"attention_required\":false}") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"future\":{\"nested\":7}") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"workspaces\"") == null);
}

test "user patch retires presentation settings without rejecting their values" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"input_appearance\":false,\"maxxing_mode\":7,\"future\":{\"profile\":1},\"workspaces\":{\"/workspace\":{\"input_appearance\":[],\"maxxing_mode\":{},\"future\":{\"workspace\":2}}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{ .model = "openai/gpt-5.4" });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "input_appearance") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "maxxing_mode") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"future\":{\"profile\":1}") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"future\":{\"workspace\":2}") != null);
}

test "workspace statusline patch writes globally and preserves nested leaf" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"statusLine\":{\"future\":7},\"workspaces\":{\"/workspace\":{\"statusLine\":{\"workspace\":false,\"future\":8}}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{
        .statusline_item = .{ .item = .workspace, .enabled = true },
    });
    defer outcome.deinit(alloc);

    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(@as(usize, 0), outcome.committed.cleanup.fields_removed);
    try std.testing.expectEqual(@as(usize, 0), outcome.committed.cleanup.recovery_paths.len);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();

    const root_statusline = parsed.value.object.get("statusLine").?.object;
    try std.testing.expectEqual(true, root_statusline.get("workspace").?.bool);
    try std.testing.expectEqual(@as(i64, 7), root_statusline.get("future").?.integer);

    const nested_statusline = parsed.value.object.get("workspaces").?.object
        .get("/workspace").?.object.get("statusLine").?.object;
    try std.testing.expectEqual(false, nested_statusline.get("workspace").?.bool);
    try std.testing.expectEqual(@as(i64, 8), nested_statusline.get("future").?.integer);
}

test "durable validation rejects malformed workspace statusline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"statusLine\":{\"workspace\":\"yes\"}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    try std.testing.expectError(
        error.InvalidSettingsFormat,
        store.applyUserPatch(alloc, .{ .startup_scrollback = false }),
    );
}

test "notification user patch preserves sibling fields and valid workspace overrides" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"notifications\":{\"attention_required\":true,\"future\":7}," ++
            "\"workspaces\":{\"/workspace\":{\"notifications\":{\"turn_end\":false," ++
            "\"attention_required\":false,\"future\":8}}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{ .notification_turn_end = true, .notification_max = true });
    defer outcome.deinit(alloc);

    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(@as(usize, 0), outcome.committed.cleanup.fields_removed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const notifications = parsed.value.object.get("notifications").?.object;
    try std.testing.expectEqual(true, notifications.get("turn_end").?.bool);
    try std.testing.expectEqual(true, notifications.get("attention_required").?.bool);
    try std.testing.expectEqual(true, notifications.get("max").?.bool);
    try std.testing.expectEqual(@as(i64, 7), notifications.get("future").?.integer);

    const workspace_notifications = parsed.value.object
        .get("workspaces").?.object
        .get("/workspace").?.object
        .get("notifications").?.object;
    try std.testing.expectEqual(false, workspace_notifications.get("turn_end").?.bool);
    try std.testing.expectEqual(false, workspace_notifications.get("attention_required").?.bool);
    try std.testing.expectEqual(@as(i64, 8), workspace_notifications.get("future").?.integer);
}

test "user patch snapshots and removes legacy workspace copies" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const original =
        "{\"model\":\"old/global\",\"future\":7,\"workspaces\":{" ++
        "\"/workspace/a\":{\"model\":\"workspace/a\",\"permission_mode\":\"ask\",\"input_appearance\":\"lines\",\"sandbox\":\"none\"}," ++
        "\"/workspace/b\":{\"model\":\"workspace/b\",\"permission_mode\":\"auto\",\"input_appearance\":\"lines\",\"effort\":\"low\"}," ++
        "\"legacy-string\":\"preserve-me\"}}\n";
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", original);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{
        .model = "openai/gpt-5.4",
        .permission_mode = .auto,
    });
    defer outcome.deinit(alloc);

    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(@as(usize, 4), outcome.committed.cleanup.fields_removed);
    try std.testing.expectEqual(@as(usize, 2), outcome.committed.cleanup.workspaces_changed);
    try std.testing.expectEqual(@as(usize, 2), outcome.committed.cleanup.recovery_paths.len);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"model\":\"openai/gpt-5.4\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"permission_mode\":\"auto\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "input_appearance") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"model\":\"workspace/a\"") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"model\":\"workspace/b\"") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"permission_mode\":\"ask\"") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"input_appearance\":\"lines\"") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"sandbox\":\"none\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"effort\":\"low\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"legacy-string\":\"preserve-me\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"future\":7") != null);

    var recovery = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        outcome.committed.cleanup.recovery_paths[0],
        .{},
    );
    defer recovery.close(io_mod.getIo());
    const recovery_stat = try recovery.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), recovery_stat.permissions.toMode() & 0o777);
    const recovered = try io_mod.readFileToEnd(alloc, &recovery, max_settings_bytes + 1);
    defer alloc.free(recovered);
    try std.testing.expectEqualStrings(original, recovered);
}

test "update channel patch removes legacy workspace copies" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"update_channel\":\"stable\",\"workspaces\":{\"/workspace\":{\"update_channel\":\"dev\",\"sandbox\":\"none\"}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{ .update_channel = .dev });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(@as(usize, 1), outcome.committed.cleanup.fields_removed);
    try std.testing.expectEqual(@as(usize, 1), outcome.committed.cleanup.workspaces_changed);
    try std.testing.expectEqual(@as(usize, 1), outcome.committed.cleanup.recovery_paths.len);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"update_channel\":\"dev\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"sandbox\":\"none\"") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const workspace = parsed.value.object.get("workspaces").?.object.get("/workspace").?.object;
    try std.testing.expect(workspace.get("update_channel") == null);
}

test "slash menu category patch removes legacy workspace copies" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"workspaces\":{\"/workspace\":{\"slash_menu_categories\":false,\"sandbox\":\"none\"}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{ .slash_menu_categories = true });
    defer outcome.deinit(alloc);

    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(@as(usize, 1), outcome.committed.cleanup.fields_removed);
    try std.testing.expectEqual(@as(usize, 1), outcome.committed.cleanup.workspaces_changed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"slash_menu_categories\":true") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"slash_menu_categories\":false") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"sandbox\":\"none\"") != null);
}

test "later migration refreshes the bounded field recovery snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const first_original =
        "{\"workspaces\":{\"/workspace/a\":{\"model\":\"legacy/one\"}}}\n";
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", first_original);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var first = try store.applyUserPatch(alloc, .{ .model = "user/one" });
    defer first.deinit(alloc);
    const first_path = try alloc.dupe(
        u8,
        first.committed.cleanup.recovery_paths[0],
    );
    defer alloc.free(first_path);

    const second_original =
        "{\"model\":\"user/one\",\"workspaces\":{\"/workspace/b\":{\"model\":\"legacy/two\"}}}\n";
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", second_original);
    var second = try store.applyUserPatch(alloc, .{ .model = "user/two" });
    defer second.deinit(alloc);

    try std.testing.expect(std.mem.eql(
        u8,
        first_path,
        second.committed.cleanup.recovery_paths[0],
    ));
    var recovery = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        second.committed.cleanup.recovery_paths[0],
        .{},
    );
    defer recovery.close(io_mod.getIo());
    const recovered = try io_mod.readFileToEnd(
        alloc,
        &recovery,
        max_settings_bytes + 1,
    );
    defer alloc.free(recovered);
    try std.testing.expectEqualStrings(second_original, recovered);

    var backups = try store.durable_home.?.dir.openDir(io_mod.getIo(), "backups", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer backups.close(io_mod.getIo());
    var iterator = backups.iterate();
    var migration_count: usize = 0;
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (std.mem.startsWith(u8, entry.name, "settings.json.preference-migration.model")) {
            migration_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), migration_count);
}

test "user patch preserves unknown fields in unrelated workspaces" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const original =
        "{\"workspaces\":{" ++
        "\"/workspace/current\":{\"output_level\":\"quiet\"}," ++
        "\"/workspace/unrelated\":{\"model\":123,\"future\":true}}}\n";
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", original);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(
        alloc,
        .{ .startup_scrollback = false },
    );
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(
        std.mem.find(u8, bytes, "\"model\":123") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, bytes, "\"future\":true") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, bytes, "\"output_level\":\"quiet\"") != null,
    );
}

test "migration snapshot failure leaves primary byte identical" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const original =
        "{\"model\":\"old/global\",\"workspaces\":{" ++
        "\"/workspace/a\":{\"model\":\"workspace/a\",\"sandbox\":\"none\"}}}\n";
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", original);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    store.failMigrationSnapshotForTest();

    try std.testing.expectError(
        error.SettingsMigrationSnapshotFailed,
        store.applyUserPatch(alloc, .{ .model = "openai/gpt-5.4" }),
    );

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings(original, bytes);
    try std.testing.expectEqual(@as(usize, 0), store.commitCountForTest());
}

test "nested user cleanup preserves siblings and skips non-object containers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const original =
        "{\"prompt_history\":{\"future\":1},\"statusLine\":{\"context\":true,\"future\":2}," ++
        "\"workspaces\":{" ++
        "\"/workspace/a\":{\"prompt_history\":{\"enabled\":true,\"future\":3}," ++
        "\"statusLine\":{\"sandbox\":false,\"context\":false,\"future\":4}}," ++
        "\"/workspace/b\":{\"prompt_history\":\"preserve\",\"statusLine\":7}," ++
        "\"/workspace/c\":{\"prompt_history\":{\"enabled\":false}}}}\n";
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", original);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{
        .prompt_history_enabled = false,
        .statusline_item = .{ .item = .context, .enabled = true },
    });
    defer outcome.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), outcome.committed.cleanup.fields_removed);
    try std.testing.expectEqual(@as(usize, 2), outcome.committed.cleanup.workspaces_changed);
    try std.testing.expectEqual(@as(usize, 2), outcome.committed.cleanup.recovery_paths.len);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const root_prompt_history = parsed.value.object.get("prompt_history") orelse
        return error.TestMissingRootPromptHistory;
    try std.testing.expectEqual(false, (root_prompt_history.object.get("enabled") orelse
        return error.TestMissingRootPromptHistoryEnabled).bool);
    try std.testing.expectEqual(@as(i64, 1), (root_prompt_history.object.get("future") orelse
        return error.TestMissingRootPromptHistoryFuture).integer);
    const root_statusline = parsed.value.object.get("statusLine") orelse
        return error.TestMissingRootStatusline;
    try std.testing.expectEqual(true, (root_statusline.object.get("context") orelse
        return error.TestMissingRootStatuslineContext).bool);
    try std.testing.expectEqual(@as(i64, 2), (root_statusline.object.get("future") orelse
        return error.TestMissingRootStatuslineFuture).integer);

    const workspaces = (parsed.value.object.get("workspaces") orelse
        return error.TestMissingWorkspaces).object;
    const workspace_a = (workspaces.get("/workspace/a") orelse
        return error.TestMissingWorkspaceA).object;
    const workspace_prompt_history = workspace_a.get("prompt_history") orelse
        return error.TestMissingWorkspacePromptHistory;
    try std.testing.expect(workspace_prompt_history.object.get("enabled") == null);
    try std.testing.expectEqual(@as(i64, 3), (workspace_prompt_history.object.get("future") orelse
        return error.TestMissingWorkspacePromptHistoryFuture).integer);
    const workspace_statusline = workspace_a.get("statusLine") orelse
        return error.TestMissingWorkspaceStatusline;
    try std.testing.expectEqual(false, (workspace_statusline.object.get("sandbox") orelse
        return error.TestMissingLegacySandbox).bool);
    try std.testing.expect(workspace_statusline.object.get("context") == null);
    try std.testing.expectEqual(@as(i64, 4), (workspace_statusline.object.get("future") orelse
        return error.TestMissingWorkspaceStatuslineFuture).integer);
    try std.testing.expectEqualStrings("preserve", workspaces.get("/workspace/b").?.object.get("prompt_history").?.string);
    try std.testing.expectEqual(@as(i64, 7), workspaces.get("/workspace/b").?.object.get("statusLine").?.integer);
    try std.testing.expect(workspaces.get("/workspace/c") == null);
}

test "oversized migration candidate fails before creating recovery snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");

    const original_len = max_settings_bytes - 100;
    const prefix = "{\"workspaces\":{\"/workspace/a\":{\"model\":\"x\",\"future\":true}},\"pad\":\"";
    const suffix = "\"}\n";
    const original = try alloc.alloc(u8, original_len);
    defer alloc.free(original);
    @memcpy(original[0..prefix.len], prefix);
    @memset(original[prefix.len .. original.len - suffix.len], 'p');
    @memcpy(original[original.len - suffix.len ..], suffix);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", original);

    const model = try alloc.alloc(u8, max_model_bytes);
    defer alloc.free(model);
    @memset(model, 'm');

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    try std.testing.expectError(
        error.SettingsTooLarge,
        store.applyUserPatch(alloc, .{ .model = model }),
    );
    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings(original, bytes);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io_mod.getIo(), "home/.fx/backups", .{}),
    );
}

test "user permission mutation preserves local rules" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const fixture = try std.fmt.allocPrint(
        alloc,
        "{{\"permission\":{{\"bash\":{{\"global *\":\"allow\"}}}},\"workspaces\":{{\"{s}\":{{\"permission\":{{\"bash\":{{\"local *\":\"allow\"}}}}}}}}}}\n",
        .{workspace},
    );
    defer alloc.free(fixture);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyPermissionPatch(alloc, .{
        .scope = .user,
        .workspace_root = null,
        .patch = .{ .add = .{
            .category = "bash",
            .pattern = "user *",
            .action = .allow,
        } },
    });
    defer outcome.deinit(alloc);

    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(SettingsScope.user, outcome.committed.scope);
    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"global *\":\"allow\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"user *\":\"allow\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"local *\":\"allow\"") != null);
}

test "permission mutation validates scope paths and isolates remove and reset" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const fixture = try std.fmt.allocPrint(
        alloc,
        "{{\"permission\":{{\"bash\":{{\"user *\":\"allow\"}}}},\"workspaces\":{{\"{s}\":{{\"permission\":{{\"bash\":{{\"local *\":\"allow\",\"deny *\":\"deny\"}},\"read\":{{\"*\":\"allow\"}}}}}}}}}}\n",
        .{workspace},
    );
    defer alloc.free(fixture);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    try std.testing.expectError(error.InvalidDurableField, store.applyPermissionPatch(alloc, .{
        .scope = .user,
        .workspace_root = workspace,
        .patch = .{ .reset = .all },
    }));
    try std.testing.expectError(error.InvalidDurableField, store.applyPermissionPatch(alloc, .{
        .scope = .local,
        .workspace_root = null,
        .patch = .{ .reset = .all },
    }));
    try std.testing.expectError(error.InvalidDurableField, store.applyPermissionPatch(alloc, .{
        .scope = .local,
        .workspace_root = "relative",
        .patch = .{ .reset = .all },
    }));

    var remove_outcome = try store.applyPermissionPatch(alloc, .{
        .scope = .local,
        .workspace_root = workspace,
        .patch = .{ .remove = .{
            .category = "bash",
            .pattern = "local *",
        } },
    });
    defer remove_outcome.deinit(alloc);
    try std.testing.expect(remove_outcome == .committed);

    var reset_outcome = try store.applyPermissionPatch(alloc, .{
        .scope = .local,
        .workspace_root = workspace,
        .patch = .{ .reset = .all },
    });
    defer reset_outcome.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), reset_outcome.committed.permission_rules_removed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"user *\":\"allow\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"local *\":\"allow\"") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"deny *\":\"deny\"") != null);
}

test "permission mutation removes canonical rules stored with padded keys" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"permission\":{\" bash \":{\" git status * \":\"allow\",\"keep *\":\"deny\"}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var remove_outcome = try store.applyPermissionPatch(alloc, .{
        .scope = .user,
        .workspace_root = null,
        .patch = .{ .remove = .{
            .category = "bash",
            .pattern = "git status *",
        } },
    });
    defer remove_outcome.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 1),
        remove_outcome.committed.permission_rules_removed,
    );

    var reset_outcome = try store.applyPermissionPatch(alloc, .{
        .scope = .user,
        .workspace_root = null,
        .patch = .{ .reset = .commands },
    });
    defer reset_outcome.deinit(alloc);
    try std.testing.expect(reset_outcome == .unchanged);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(
        std.mem.find(u8, bytes, "git status") == null,
    );
    try std.testing.expect(
        std.mem.find(u8, bytes, "\"keep *\":\"deny\"") != null,
    );
}

test "permission reset matches padded category keys" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"permission\":{\" bash \":{\" one * \":\"allow\",\"two *\":\"allow\"}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyPermissionPatch(alloc, .{
        .scope = .user,
        .workspace_root = null,
        .patch = .{ .reset = .commands },
    });
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 2),
        outcome.committed.permission_rules_removed,
    );

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "one *") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "two *") == null);
}

test "user patch traces metadata without settings content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"sentinel_secret\":\"FX_SETTINGS_SECRET\",\"workspaces\":{}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const trace_path = try std.fs.path.join(alloc, &.{ home, "settings-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "config");

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyUserPatch(alloc, .{
        .model = "FX_MODEL_SECRET",
        .fast_mode = true,
    });
    defer outcome.deinit(alloc);
    debug_trace.shutdown();

    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);

    try std.testing.expect(std.mem.find(u8, trace, "operation=user_patch") != null);
    try std.testing.expect(std.mem.find(u8, trace, "path_category=user_settings") != null);
    try std.testing.expect(std.mem.find(u8, trace, "mutation_mode=runtime_first") != null);
    try std.testing.expect(std.mem.find(u8, trace, "outcome=committed") != null);
    try std.testing.expect(std.mem.find(u8, trace, "FX_SETTINGS_SECRET") == null);
    try std.testing.expect(std.mem.find(u8, trace, "FX_MODEL_SECRET") == null);
    try std.testing.expect(std.mem.find(u8, trace, workspace) == null);
}

test "settings primary accepts exactly 64 KiB and rejects one byte more" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    const exact = try alloc.alloc(u8, max_settings_bytes);
    defer alloc.free(exact);
    const prefix = "{\"pad\":\"";
    const suffix = "\"}\n";
    @memcpy(exact[0..prefix.len], prefix);
    @memset(exact[prefix.len .. exact.len - suffix.len], 'x');
    @memcpy(exact[exact.len - suffix.len ..], suffix);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", exact);

    var store = try Store.initFromHome(alloc, home, .read_only);
    defer store.deinit(alloc);
    var loaded = try store.loadPrimary(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded == .valid);
    try std.testing.expectEqual(max_settings_bytes, loaded.valid.len);

    var oversized = try alloc.alloc(u8, max_settings_bytes + 1);
    defer alloc.free(oversized);
    @memcpy(oversized[0..exact.len], exact);
    oversized[oversized.len - 1] = ' ';
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", oversized);
    var too_large = try store.loadPrimary(alloc);
    defer too_large.deinit(alloc);
    try std.testing.expect(too_large == .oversized);
}

test "multi-value user patch commits model effort and fast mode once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{
        .model = "openai/gpt-5.4",
        .effort = types.ReasoningEffort.literal("high"),
        .fast_mode = false,
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(@as(usize, 1), store.commitCountForTest());
}

test "missing user settings is created through private durable commit" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{ .startup_scrollback = false });
    defer outcome.deinit(alloc);
    const stat = try store.primaryStatForTest();
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "invalid primary is not replaced by backup or mutation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/backups");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", "{broken");
    try writeStoreFixture(tmp.dir, "home/.fx/backups/settings.json.backup.1-0000000000000001-00000000000000000000000000000000", "{}\n");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    try std.testing.expectError(
        error.InvalidSettingsFormat,
        store.applyUserPatch(alloc, .{ .fast_mode = true }),
    );
    const primary = try store.readPrimaryForTest(alloc);
    defer alloc.free(primary);
    try std.testing.expectEqualStrings("{broken", primary);

    var backups = try tmp.dir.openDir(io_mod.getIo(), "home/.fx/backups", .{ .iterate = true });
    defer backups.close(io_mod.getIo());
    var iterator = backups.iterate();
    var corrupt_count: usize = 0;
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (std.mem.startsWith(u8, entry.name, "settings.json.corrupt.")) {
            corrupt_count += 1;
            try std.testing.expect(parseSequence(entry.name) != null);
            const stat = try backups.statFile(io_mod.getIo(), entry.name, .{ .follow_symlinks = false });
            try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), corrupt_count);
}

test "oversized candidate leaves prior primary unchanged" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", "{}\n");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    const oversized_model = try alloc.alloc(u8, max_model_bytes + 1);
    defer alloc.free(oversized_model);
    @memset(oversized_model, 'm');
    try std.testing.expectError(
        error.InvalidDurableField,
        store.applyUserPatch(alloc, .{ .model = oversized_model }),
    );
    const primary = try store.readPrimaryForTest(alloc);
    defer alloc.free(primary);
    try std.testing.expectEqualStrings("{}\n", primary);
}

test "startup scrollback false is a present user patch" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", "{\"startup_scrollback\":false}\n");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{ .startup_scrollback = false });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .unchanged);
}

test "startup scrollback user patch removes matching legacy workspace value" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const fixture = try std.fmt.allocPrint(alloc, "{{\"startup_scrollback\":true,\"workspaces\":{{\"{s}\":{{\"startup_scrollback\":false}}}}}}\n", .{workspace});
    defer alloc.free(fixture);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{ .startup_scrollback = false });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(@as(usize, 1), outcome.committed.cleanup.fields_removed);
    try std.testing.expectEqual(@as(usize, 1), outcome.committed.cleanup.workspaces_changed);
}

test "unrelated user patch preserves inert output level values" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const fixture = try std.fmt.allocPrint(
        alloc,
        "{{\"output_level\":{{\"legacy\":true}},\"workspaces\":{{\"{s}\":{{\"output_level\":[\"quiet\",7],\"future\":true}}}}}}\n",
        .{workspace},
    );
    defer alloc.free(fixture);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyUserPatch(alloc, .{ .startup_scrollback = false });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(@as(usize, 0), outcome.committed.cleanup.fields_removed);
    try std.testing.expectEqual(@as(usize, 0), outcome.committed.cleanup.workspaces_changed);
    try std.testing.expectEqual(@as(usize, 0), outcome.committed.cleanup.recovery_paths.len);

    const primary = try store.readPrimaryForTest(alloc);
    defer alloc.free(primary);
    try std.testing.expect(std.mem.find(u8, primary, "\"output_level\":{\"legacy\":true}") != null);
    try std.testing.expect(std.mem.find(u8, primary, "\"output_level\":[\"quiet\",7]") != null);
    try std.testing.expect(std.mem.find(u8, primary, "\"future\":true") != null);
    try std.testing.expect(std.mem.find(u8, primary, "\"startup_scrollback\":false") != null);
}

test "second settings commit creates a sequenced private backup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var first_outcome = try store.applyUserPatch(alloc, .{ .fast_mode = true });
    defer first_outcome.deinit(alloc);
    var second_outcome = try store.applyUserPatch(alloc, .{ .effort = types.ReasoningEffort.literal("high") });
    defer second_outcome.deinit(alloc);

    var backups = try store.durable_home.?.dir.openDir(io_mod.getIo(), "backups", .{ .iterate = true, .follow_symlinks = false });
    defer backups.close(io_mod.getIo());
    var iterator = backups.iterate();
    var backup_count: usize = 0;
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "settings.json.backup.")) continue;
        backup_count += 1;
        try std.testing.expect(parseSequence(entry.name) != null);
        const stat = try backups.statFile(io_mod.getIo(), entry.name, .{ .follow_symlinks = false });
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
    try std.testing.expectEqual(@as(usize, 1), backup_count);
}

test "symlinked settings primary is rejected without touching its target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeStoreFixture(tmp.dir, "outside.json", "{\"outside\":true}\n");
    tmp.dir.symLink(io_mod.getIo(), "../../outside.json", "home/.fx/settings.json", .{ .is_directory = false }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    try std.testing.expectError(
        error.DurablePathUnsafe,
        store.applyUserPatch(alloc, .{ .fast_mode = true }),
    );
    var outside = try tmp.dir.openFile(io_mod.getIo(), "outside.json", .{});
    defer outside.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &outside, 128);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("{\"outside\":true}\n", bytes);
}

test "symlinked durable home is rejected before reading settings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "outside");
    try writeStoreFixture(tmp.dir, "outside/settings.json", "{\"model\":\"outside/model\"}\n");
    tmp.dir.symLink(io_mod.getIo(), "../outside", "home/.fx", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);

    try std.testing.expectError(
        error.DurablePathUnsafe,
        Store.initFromHome(alloc, home, .read_only),
    );
}

test "read only settings rejects group or world writable policy files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"permission_mode\":\"auto\",\"permission\":{\"bash\":\"allow\"}}\n",
    );

    var root_dir = try tmp.dir.openDir(io_mod.getIo(), "home/.fx", .{ .iterate = true });
    defer root_dir.close(io_mod.getIo());
    root_dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o777)) catch return error.SkipZigTest;

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    try std.testing.expectError(
        error.PrivateStatePermissionsUnsupported,
        Store.initFromHome(alloc, home, .read_only),
    );

    root_dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o755)) catch return error.SkipZigTest;
    var file = try root_dir.openFile(io_mod.getIo(), "settings.json", .{ .mode = .read_write });
    file.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o666)) catch {
        file.close(io_mod.getIo());
        return error.SkipZigTest;
    };
    file.close(io_mod.getIo());

    var store = try Store.initFromHome(alloc, home, .read_only);
    defer store.deinit(alloc);
    try std.testing.expectError(
        error.PrivateStatePermissionsUnsupported,
        store.loadPrimary(alloc),
    );
}

test "three fingerprint conflicts return SettingsConcurrentModification" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", "{}\n");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    store.forceFingerprintConflictsForTest(3);

    try std.testing.expectError(
        error.SettingsConcurrentModification,
        store.applyUserPatch(alloc, .{ .effort = types.ReasoningEffort.literal("high") }),
    );
}

test "equal timestamp backups order by monotonic sequence" {
    const older = "settings.json.backup.100-0000000000000001-ffffffffffffffffffffffffffffffff";
    const newer = "settings.json.backup.100-0000000000000002-00000000000000000000000000000000";
    try std.testing.expect(backupNameNewerThan(newer, older));
    try std.testing.expect(!backupNameNewerThan(older, newer));
}

test "sequenced backups sort ahead of legacy names and legacy names use timestamp" {
    const sequenced = "settings.json.backup.1-0000000000000001-00000000000000000000000000000000";
    const legacy_newer = "settings.json.backup.200";
    const legacy_older = "settings.json.backup.100";
    try std.testing.expect(backupNameNewerThan(sequenced, legacy_newer));
    try std.testing.expect(backupNameNewerThan(legacy_newer, legacy_older));
}

test "post-rename failure returns SettingsCommitIndeterminate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    store.failParentSyncAfterRenameForTest();

    try std.testing.expectError(
        error.SettingsCommitIndeterminate,
        store.applyUserPatch(alloc, .{ .startup_scrollback = false }),
    );
}

test "indeterminate migration retains recovery metadata for the caller" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const original =
        "{\"workspaces\":{\"/workspace/a\":{\"model\":\"legacy/model\",\"future\":true}}}\n";
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", original);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    store.failParentSyncAfterRenameForTest();

    try std.testing.expectError(
        error.SettingsCommitIndeterminate,
        store.applyUserPatch(alloc, .{ .model = "user/model" }),
    );
    var cleanup = store.takeFailureCleanup();
    defer cleanup.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), cleanup.fields_removed);
    try std.testing.expectEqual(@as(usize, 1), cleanup.workspaces_changed);
    try std.testing.expectEqual(@as(usize, 1), cleanup.recovery_paths.len);

    var recovery = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), cleanup.recovery_paths[0], .{});
    defer recovery.close(io_mod.getIo());
    const recovered = try io_mod.readFileToEnd(alloc, &recovery, max_settings_bytes + 1);
    defer alloc.free(recovered);
    try std.testing.expectEqualStrings(original, recovered);
}

test "read-only settings load under empty home creates no filesystem state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .read_only);
    defer store.deinit(alloc);

    var loaded = try store.loadPrimary(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded == .absent);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), "home/.fx", .{}));
}

test "read-only settings load under missing home is absent without creating state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const home = try std.fs.path.join(alloc, &.{ root, "missing-home" });
    defer alloc.free(home);

    var store = try Store.initFromHome(alloc, home, .read_only);
    defer store.deinit(alloc);
    try std.testing.expect(store.availability == .read_only_absent);

    var loaded = try store.loadPrimary(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded == .absent);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), "missing-home", .{}));
}

test "workspace directory mutations compose against the latest settings state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"future\":true,\"workspaces\":{\"/workspace\":{\"additional_directories\":[\"/removed\"],\"future_workspace\":true},\"/empty\":{\"additional_directories\":[\"/orphan\"]},\"/other\":{\"sandbox\":\"none\"}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var first = try Store.initFromHome(alloc, home, .writable);
    defer first.deinit(alloc);
    var stale_second = try Store.initFromHome(alloc, home, .writable);
    defer stale_second.deinit(alloc);
    const observed_sources = [_]workspace_access.SavedSource{.{
        .source = "/removed",
        .identity = "/removed",
    }};
    try std.testing.expectError(
        error.InvalidDurableField,
        first.applyWorkspaceDirectoryPatch(alloc, .{
            .workspace_root = "/workspace",
            .patch = .{ .add = "relative" },
        }),
    );

    var remove_outcome = try first.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = "/workspace",
        .patch = .{ .remove = "/removed" },
        .observed_sources = &observed_sources,
    });
    defer remove_outcome.deinit(alloc);
    var add_outcome = try stale_second.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = "/workspace",
        .patch = .{ .add = "/added" },
        .observed_sources = &observed_sources,
    });
    defer add_outcome.deinit(alloc);

    const composed = try first.readPrimaryForTest(alloc);
    defer alloc.free(composed);
    try std.testing.expect(std.mem.find(u8, composed, "\"additional_directories\":[\"/added\"]") != null);
    try std.testing.expect(std.mem.find(u8, composed, "/removed") == null);
    try std.testing.expect(std.mem.find(u8, composed, "\"future_workspace\":true") != null);
    try std.testing.expect(std.mem.find(u8, composed, "\"/other\":{\"sandbox\":\"none\"}") != null);

    var clear_outcome = try first.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = "/workspace",
        .patch = .clear,
    });
    defer clear_outcome.deinit(alloc);
    const cleared = try first.readPrimaryForTest(alloc);
    defer alloc.free(cleared);
    try std.testing.expect(std.mem.find(u8, cleared, "\"/workspace\":{\"future_workspace\":true}") != null);
    try std.testing.expect(std.mem.find(u8, cleared, "\"future\":true") != null);
    try std.testing.expect(std.mem.find(u8, cleared, "\"/other\":{\"sandbox\":\"none\"}") != null);

    var empty_clear_outcome = try first.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = "/empty",
        .patch = .clear,
    });
    defer empty_clear_outcome.deinit(alloc);
    const empty_cleared = try first.readPrimaryForTest(alloc);
    defer alloc.free(empty_cleared);
    try std.testing.expect(std.mem.find(u8, empty_cleared, "\"/empty\":") == null);
    try std.testing.expect(std.mem.find(u8, empty_cleared, "\"/other\":{\"sandbox\":\"none\"}") != null);
}

test "workspace directory clear removes the final empty workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"workspaces\":{\"/workspace\":{\"additional_directories\":[\"/shared\"]}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);

    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = "/workspace",
        .patch = .clear,
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("{}\n", bytes);
}

test "workspace directory mutations use workspace access path identity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "shared", .default_dir);
    tmp.dir.symLink(std.testing.io, "shared", "shared-link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);
    const shared_dot = try std.fmt.allocPrint(alloc, "{s}{c}.", .{ shared, std.fs.path.sep });
    defer alloc.free(shared_dot);
    const shared_link = try std.fs.path.resolve(alloc, &.{ primary, "../shared-link" });
    defer alloc.free(shared_link);
    const available_fixture = try std.fmt.allocPrint(
        alloc,
        "{{\"workspaces\":{{\"{s}\":{{\"additional_directories\":[\"{s}\",\"{s}\"]}}}}}}\n",
        .{ primary, shared_dot, shared_link },
    );
    defer alloc.free(available_fixture);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", available_fixture);

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    const available_sources = [_]workspace_access.SavedSource{
        .{ .source = shared_dot, .identity = shared },
        .{ .source = shared_link, .identity = shared },
    };
    var add_outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = primary,
        .patch = .{ .add = shared },
        .observed_sources = &available_sources,
    });
    defer add_outcome.deinit(alloc);
    try std.testing.expect(add_outcome == .committed);
    const stabilized_sources = [_]workspace_access.SavedSource{.{
        .source = shared,
        .identity = shared,
    }};

    var remove_available = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = primary,
        .patch = .{ .remove = shared },
        .observed_sources = &stabilized_sources,
    });
    defer remove_available.deinit(alloc);
    try std.testing.expect(remove_available == .committed);
    const available_removed = try store.readPrimaryForTest(alloc);
    defer alloc.free(available_removed);
    try std.testing.expect(std.mem.find(u8, available_removed, "additional_directories") == null);

    const missing = try std.fs.path.resolve(alloc, &.{ primary, "../missing" });
    defer alloc.free(missing);
    const missing_dot = try std.fmt.allocPrint(alloc, "{s}{c}.", .{ missing, std.fs.path.sep });
    defer alloc.free(missing_dot);
    const missing_parent = try std.fmt.allocPrint(
        alloc,
        "{s}{c}child{c}..",
        .{ missing, std.fs.path.sep, std.fs.path.sep },
    );
    defer alloc.free(missing_parent);
    const unavailable_fixture = try std.fmt.allocPrint(
        alloc,
        "{{\"workspaces\":{{\"{s}\":{{\"additional_directories\":[\"{s}\",\"{s}\"]}}}}}}\n",
        .{ primary, missing_dot, missing_parent },
    );
    defer alloc.free(unavailable_fixture);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", unavailable_fixture);
    const unavailable_sources = [_]workspace_access.SavedSource{
        .{ .source = missing_dot, .identity = missing },
        .{ .source = missing_parent, .identity = missing },
    };

    var remove_unavailable = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = primary,
        .patch = .{ .remove = missing },
        .observed_sources = &unavailable_sources,
    });
    defer remove_unavailable.deinit(alloc);
    try std.testing.expect(remove_unavailable == .committed);
    const unavailable_removed = try store.readPrimaryForTest(alloc);
    defer alloc.free(unavailable_removed);
    try std.testing.expect(std.mem.find(u8, unavailable_removed, "additional_directories") == null);
}

test "workspace directory removal uses observed sources and preserves unseen concurrent sources" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "first", .default_dir);
    try tmp.dir.createDir(std.testing.io, "second", .default_dir);
    tmp.dir.symLink(std.testing.io, "first", "observed-link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const first = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "first");
    defer alloc.free(first);
    const observed_source = try std.fs.path.resolve(alloc, &.{ primary, "../observed-link" });
    defer alloc.free(observed_source);
    const unseen_source = try std.fs.path.resolve(alloc, &.{ primary, "../unseen-link" });
    defer alloc.free(unseen_source);
    const observed_sources = [_]workspace_access.SavedSource{.{
        .source = observed_source,
        .identity = first,
    }};

    try tmp.dir.deleteFile(std.testing.io, "observed-link");
    try tmp.dir.symLink(std.testing.io, "second", "observed-link", .{ .is_directory = true });
    try tmp.dir.symLink(std.testing.io, "first", "unseen-link", .{ .is_directory = true });

    const fixture = try std.fmt.allocPrint(
        alloc,
        "{{\"workspaces\":{{\"{s}\":{{\"additional_directories\":[\"{s}\",\"{s}\"]}}}}}}\n",
        .{ primary, observed_source, unseen_source },
    );
    defer alloc.free(fixture);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture);

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = primary,
        .patch = .{ .remove = first },
        .observed_sources = &observed_sources,
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const directories = parsed.value.object
        .get("workspaces").?.object
        .get(primary).?.object
        .get("additional_directories").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), directories.len);
    try std.testing.expectEqualStrings(unseen_source, directories[0].string);
}

test "workspace directory removal stabilizes observed survivor identity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "removed", .default_dir);
    try tmp.dir.createDir(std.testing.io, "survivor", .default_dir);
    try tmp.dir.createDir(std.testing.io, "retarget", .default_dir);
    tmp.dir.symLink(std.testing.io, "removed", "removed-link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try tmp.dir.symLink(std.testing.io, "survivor", "survivor-link", .{ .is_directory = true });

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const removed = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "removed");
    defer alloc.free(removed);
    const survivor = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "survivor");
    defer alloc.free(survivor);
    const removed_source = try std.fs.path.resolve(alloc, &.{ primary, "../removed-link" });
    defer alloc.free(removed_source);
    const survivor_source = try std.fs.path.resolve(alloc, &.{ primary, "../survivor-link" });
    defer alloc.free(survivor_source);
    const observed_sources = [_]workspace_access.SavedSource{
        .{ .source = removed_source, .identity = removed },
        .{ .source = survivor_source, .identity = survivor },
    };
    const fixture = try std.fmt.allocPrint(
        alloc,
        "{{\"workspaces\":{{\"{s}\":{{\"additional_directories\":[\"{s}\",\"{s}\"]}}}}}}\n",
        .{ primary, removed_source, survivor_source },
    );
    defer alloc.free(fixture);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture);

    try tmp.dir.deleteFile(std.testing.io, "survivor-link");
    try tmp.dir.symLink(std.testing.io, "retarget", "survivor-link", .{ .is_directory = true });

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = primary,
        .patch = .{ .remove = removed },
        .observed_sources = &observed_sources,
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const directories = parsed.value.object
        .get("workspaces").?.object
        .get(primary).?.object
        .get("additional_directories").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), directories.len);
    try std.testing.expectEqualStrings(survivor, directories[0].string);
}

test "workspace directory removal prefers an unseen canonical survivor" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"workspaces\":{\"/workspace\":{\"additional_directories\":[\"/unseen-before\",\"/target-alias\",\"/survivor-alias-a\",\"/survivor\",\"/survivor-alias-b\",\"/unseen-after\"]}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const observed_sources = [_]workspace_access.SavedSource{
        .{ .source = "/target-alias", .identity = "/target" },
        .{ .source = "/survivor-alias-a", .identity = "/survivor" },
        .{ .source = "/survivor-alias-b", .identity = "/survivor" },
    };

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = "/workspace",
        .patch = .{ .remove = "/target" },
        .observed_sources = &observed_sources,
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"workspaces\":{\"/workspace\":{\"additional_directories\":[\"/unseen-before\",\"/survivor\",\"/unseen-after\"]}}}\n",
        bytes,
    );
}

test "workspace directory removal removes an unseen exact target replacement" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"workspaces\":{\"/workspace\":{\"additional_directories\":[\"/unseen-before\",\"/target\",\"/unseen-after\"]}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const observed_sources = [_]workspace_access.SavedSource{.{
        .source = "/target-alias",
        .identity = "/target",
    }};

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = "/workspace",
        .patch = .{ .remove = "/target" },
        .observed_sources = &observed_sources,
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"workspaces\":{\"/workspace\":{\"additional_directories\":[\"/unseen-before\",\"/unseen-after\"]}}}\n",
        bytes,
    );
}

test "workspace directory add prefers an unseen canonical survivor" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try writeStoreFixture(
        tmp.dir,
        "home/.fx/settings.json",
        "{\"workspaces\":{\"/workspace\":{\"additional_directories\":[\"/survivor-alias\",\"/survivor\"]}}}\n",
    );

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const observed_sources = [_]workspace_access.SavedSource{.{
        .source = "/survivor-alias",
        .identity = "/survivor",
    }};

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = "/workspace",
        .patch = .{ .add = "/added" },
        .observed_sources = &observed_sources,
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"workspaces\":{\"/workspace\":{\"additional_directories\":[\"/survivor\",\"/added\"]}}}\n",
        bytes,
    );
}

test "workspace directory add counts an unseen command line root once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");

    var fixture: std.Io.Writer.Allocating = .init(alloc);
    defer fixture.deinit();
    try fixture.writer.writeAll("{\"workspaces\":{\"/workspace\":{\"additional_directories\":[");
    for (0..workspace_access.max_additional_directories - 1) |index| {
        if (index > 0) try fixture.writer.writeByte(',');
        try fixture.writer.print("\"/unseen-{d}\"", .{index});
    }
    try fixture.writer.writeAll("]}}}\n");
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture.written());

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = "/workspace",
        .patch = .{ .add = "/added" },
        .command_line_directories = &.{"/unseen-0"},
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const directories = parsed.value.object
        .get("workspaces").?.object
        .get("/workspace").?.object
        .get("additional_directories").?.array.items;
    try std.testing.expectEqual(workspace_access.max_additional_directories, directories.len);
    for (directories[0 .. directories.len - 1], 0..) |directory, index| {
        const expected = try std.fmt.allocPrint(alloc, "/unseen-{d}", .{index});
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, directory.string);
    }
    try std.testing.expectEqualStrings("/added", directories[directories.len - 1].string);
}

test "workspace directory existing add stabilizes a retargeted observed source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "first", .default_dir);
    try tmp.dir.createDir(std.testing.io, "second", .default_dir);
    tmp.dir.symLink(std.testing.io, "first", "saved-link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const first = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "first");
    defer alloc.free(first);
    const source = try std.fs.path.resolve(alloc, &.{ primary, "../saved-link" });
    defer alloc.free(source);
    const observed_sources = [_]workspace_access.SavedSource{.{
        .source = source,
        .identity = first,
    }};
    const fixture = try std.fmt.allocPrint(
        alloc,
        "{{\"workspaces\":{{\"{s}\":{{\"additional_directories\":[\"{s}\"]}}}}}}\n",
        .{ primary, source },
    );
    defer alloc.free(fixture);
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture);

    try tmp.dir.deleteFile(std.testing.io, "saved-link");
    try tmp.dir.symLink(std.testing.io, "second", "saved-link", .{ .is_directory = true });

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = primary,
        .patch = .{ .add = first },
        .observed_sources = &observed_sources,
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const directories = parsed.value.object
        .get("workspaces").?.object
        .get(primary).?.object
        .get("additional_directories").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), directories.len);
    try std.testing.expectEqualStrings(first, directories[0].string);
}

test "workspace directory capacity compaction uses observed source identities" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "shared", .default_dir);
    try tmp.dir.createDir(std.testing.io, "retarget", .default_dir);
    try tmp.dir.createDir(std.testing.io, "added", .default_dir);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);
    const added = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "added");
    defer alloc.free(added);

    var aliases: [workspace_access.max_additional_directories][]u8 = undefined;
    var observed: [workspace_access.max_additional_directories]workspace_access.SavedSource = undefined;
    var initialized: usize = 0;
    defer for (aliases[0..initialized]) |path| alloc.free(path);
    for (&aliases, &observed, 0..) |*alias, *source, index| {
        const name = try std.fmt.allocPrint(alloc, "stable-link-{d}", .{index});
        defer alloc.free(name);
        tmp.dir.symLink(std.testing.io, "shared", name, .{ .is_directory = true }) catch |err| switch (err) {
            error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        alias.* = try std.fs.path.resolve(alloc, &.{ primary, "..", name });
        source.* = .{ .source = alias.*, .identity = shared };
        initialized += 1;
    }

    var fixture: std.Io.Writer.Allocating = .init(alloc);
    defer fixture.deinit();
    try fixture.writer.writeAll("{\"workspaces\":{");
    try std.json.Stringify.value(primary, .{}, &fixture.writer);
    try fixture.writer.writeAll(":{\"additional_directories\":[");
    for (aliases, 0..) |alias, index| {
        if (index > 0) try fixture.writer.writeByte(',');
        try std.json.Stringify.value(alias, .{}, &fixture.writer);
    }
    try fixture.writer.writeAll("]}}}\n");
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture.written());

    try tmp.dir.deleteFile(std.testing.io, "stable-link-15");
    try tmp.dir.symLink(std.testing.io, "retarget", "stable-link-15", .{ .is_directory = true });

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = primary,
        .patch = .{ .add = added },
        .observed_sources = &observed,
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const directories = parsed.value.object
        .get("workspaces").?.object
        .get(primary).?.object
        .get("additional_directories").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), directories.len);
    try std.testing.expectEqualStrings(shared, directories[0].string);
    try std.testing.expectEqualStrings(added, directories[1].string);
}

test "workspace directory add compacts saved aliases before applying effective capacity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "shared", .default_dir);
    try tmp.dir.createDir(std.testing.io, "added", .default_dir);

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);
    const added = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "added");
    defer alloc.free(added);

    var aliases: [workspace_access.max_additional_directories][]u8 = undefined;
    var observed: [workspace_access.max_additional_directories]workspace_access.SavedSource = undefined;
    var initialized: usize = 0;
    defer for (aliases[0..initialized]) |path| alloc.free(path);
    for (&aliases, &observed, 0..) |*alias, *source, index| {
        const name = try std.fmt.allocPrint(alloc, "shared-link-{d}", .{index});
        defer alloc.free(name);
        tmp.dir.symLink(std.testing.io, "shared", name, .{ .is_directory = true }) catch |err| switch (err) {
            error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        alias.* = try std.fs.path.resolve(alloc, &.{ primary, "..", name });
        source.* = .{ .source = alias.*, .identity = shared };
        initialized += 1;
    }

    var fixture: std.Io.Writer.Allocating = .init(alloc);
    defer fixture.deinit();
    try fixture.writer.writeAll("{\"workspaces\":{");
    try std.json.Stringify.value(primary, .{}, &fixture.writer);
    try fixture.writer.writeAll(":{\"additional_directories\":[");
    for (aliases, 0..) |alias, index| {
        if (index > 0) try fixture.writer.writeByte(',');
        try std.json.Stringify.value(alias, .{}, &fixture.writer);
    }
    try fixture.writer.writeAll("]}}}\n");
    try writeStoreFixture(tmp.dir, "home/.fx/settings.json", fixture.written());

    var store = try Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyWorkspaceDirectoryPatch(alloc, .{
        .workspace_root = primary,
        .patch = .{ .add = added },
        .observed_sources = &observed,
        .command_line_directories = &.{aliases[1]},
    });
    defer outcome.deinit(alloc);
    try std.testing.expect(outcome == .committed);

    const bytes = try store.readPrimaryForTest(alloc);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const directories = parsed.value.object
        .get("workspaces").?.object
        .get(primary).?.object
        .get("additional_directories").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), directories.len);
    const retained_identity = try workspace_access.storedDirectoryIdentityAlloc(
        alloc,
        primary,
        directories[0].string,
    );
    defer alloc.free(retained_identity);
    try std.testing.expectEqualStrings(shared, retained_identity);
    try std.testing.expectEqualStrings(added, directories[1].string);
}
