const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const generation_fact_codec = @import("generation_fact_codec.zig");
const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;
const usage_file = profile_paths.usage_file_name;
const usage_lock_file = "usage.lock";
const lock_deadline_ms: u64 = 2000;
const max_file_bytes: usize = 32 * 1024 * 1024;
const max_record_bytes: usize = 16 * 1024;
const max_records: usize = 200_000;
const compaction_threshold_bytes: u64 = 8 * 1024 * 1024;
const retention_ms: i64 = std.time.ms_per_day * 35;
const private_dir_permissions = (if (builtin.os.tag == .windows) std.Io.Dir.Permissions.default_dir else (if (builtin.os.tag == .windows) std.Io.Dir.Permissions.default_dir else std.Io.Dir.Permissions.fromMode(0o700)));
const private_file_permissions = (if (builtin.os.tag == .windows) std.Io.File.Permissions.default_file else (if (builtin.os.tag == .windows) std.Io.File.Permissions.default_file else std.Io.File.Permissions.fromMode(0o600)));

pub const AppendOutcome = enum {
    appended,
    duplicate,
    conflict,
};

pub const Loaded = struct {
    coverage_started_at_ms: ?i64,
    facts: []usage_report.GenerationFact,
    pending: []usage_report.PendingMarker,
    incidents: []usage_report.Incident,
    record_count: usize,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        for (self.facts) |*fact| fact.deinit(alloc);
        alloc.free(self.facts);
        for (self.pending) |*marker| marker.deinit(alloc);
        alloc.free(self.pending);
        alloc.free(self.incidents);
        self.* = undefined;
    }
};

const ParsedRecord = union(enum) {
    coverage: i64,
    generation: usage_report.GenerationFact,
    pending: usage_report.PendingMarker,
    incident: usage_report.Incident,

    fn deinit(self: *ParsedRecord, alloc: Allocator) void {
        switch (self.*) {
            .generation => |*fact| fact.deinit(alloc),
            .pending => |*marker| marker.deinit(alloc),
            .coverage, .incident => {},
        }
        self.* = undefined;
    }
};

const AppendDecision = struct {
    outcome: AppendOutcome,
    write: bool,
};

const VariantIndexes = struct {
    first: usize,
    second: ?usize = null,
};

const TailBoundary = struct {
    length: u64,
    incomplete: bool,
};

pub const Store = struct {
    home_path: []u8,
    durable_home: ?io_mod.VerifiedDir = null,
    lock_ops: io_mod.LockOps = .{},

    pub fn initFromHome(alloc: Allocator, home_path: []const u8) !Store {
        const owned_home = try alloc.dupe(u8, home_path);
        errdefer alloc.free(owned_home);
        return .{
            .home_path = owned_home,
            .durable_home = try openExistingDurableHome(home_path),
        };
    }

    pub fn deinit(self: *Store, alloc: Allocator) void {
        if (self.durable_home) |*dir| dir.close();
        alloc.free(self.home_path);
        self.* = undefined;
    }

    fn appendFact(
        self: *Store,
        alloc: Allocator,
        fact: usage_report.GenerationFact,
    ) !AppendOutcome {
        return self.appendEvent(alloc, .{ .generation = fact });
    }

    pub fn appendEvent(
        self: *Store,
        alloc: Allocator,
        event: usage_report.ProfileEvent,
    ) !AppendOutcome {
        try validateEvent(event);
        const event_line = try serializeEvent(alloc, event);
        defer alloc.free(event_line);
        if (event_line.len > max_record_bytes) return error.UsageRecordTooLarge;

        try self.ensureWritable();
        var lock = self.acquireLock() catch |err| switch (err) {
            error.LockBusy => return error.UsageLockBusy,
            error.LockUnsupported => return error.UsageLockUnsupported,
            else => return err,
        };
        defer lock.release();

        var file: ?std.Io.File = (try self.openUsage(true, true)).?;
        defer if (file) |open_file| open_file.close(io_mod.getIo());
        const tail = try inspectTail(file.?);
        const has_incomplete_tail = tail.incomplete;
        var boundary = tail.length;
        var loaded = try self.loadFromFile(alloc, file.?, boundary);
        defer loaded.deinit(alloc);

        const decision = classifyEvent(loaded, event);

        const now_ms = @max(io_mod.milliTimestamp(), 0);
        var append_bytes: std.Io.Writer.Allocating = .init(alloc);
        defer append_bytes.deinit();
        var append_record_count: usize = 0;
        if (loaded.coverage_started_at_ms == null) {
            try writeCoverage(&append_bytes.writer, now_ms);
            append_record_count += 1;
        }
        if (has_incomplete_tail) {
            try writeIncident(&append_bytes.writer, .{
                .occurred_at_ms = now_ms,
                .completeness = .incomplete,
            });
            append_record_count += 1;
        }
        if (decision.write) {
            try append_bytes.writer.writeAll(event_line);
            append_record_count += 1;
        }
        if (append_bytes.written().len == 0) return decision.outcome;

        var next_length = std.math.add(
            u64,
            boundary,
            std.math.cast(u64, append_bytes.written().len) orelse
                return error.UsageCapacityExceeded,
        ) catch return error.UsageCapacityExceeded;
        var compacted_before_append = false;
        var append_committed = false;
        var base_record_count = loaded.record_count;
        if (shouldCompactBeforeAppend(
            next_length,
            base_record_count,
            append_record_count,
            loaded,
            now_ms,
        )) {
            compacted_before_append = true;
            base_record_count = retainedRecordCount(loaded, now_ms);
            if (has_incomplete_tail) {
                var replacement: std.Io.Writer.Allocating = .init(alloc);
                defer replacement.deinit();
                try writeRetainedRecords(&replacement.writer, loaded, now_ms);
                try replacement.writer.writeAll(append_bytes.written());
                next_length = std.math.cast(u64, replacement.written().len) orelse
                    return error.UsageCapacityExceeded;
                if (next_length > max_file_bytes) return error.UsageCapacityExceeded;
                _ = try checkedRecordCount(base_record_count, append_record_count);
                try self.replaceUsageLocked(alloc, replacement.written());
                file.?.close(io_mod.getIo());
                file = null;
                append_committed = true;
            } else {
                file.?.close(io_mod.getIo());
                file = null;
                try self.compactLocked(alloc, now_ms);
                file = (try self.openUsage(true, false)) orelse
                    return error.UsageReadFailed;
                boundary = try file.?.length(io_mod.getIo());
                next_length = std.math.add(
                    u64,
                    boundary,
                    std.math.cast(u64, append_bytes.written().len) orelse
                        return error.UsageCapacityExceeded,
                ) catch return error.UsageCapacityExceeded;
            }
        }
        if (next_length > max_file_bytes) return error.UsageCapacityExceeded;
        _ = try checkedRecordCount(base_record_count, append_record_count);
        if (!append_committed) {
            if (has_incomplete_tail) {
                var replacement: std.Io.Writer.Allocating = .init(alloc);
                defer replacement.deinit();
                try copyFilePrefix(
                    &replacement.writer,
                    file.?,
                    boundary,
                );
                try replacement.writer.writeAll(append_bytes.written());
                try self.replaceUsageLocked(alloc, replacement.written());
                file.?.close(io_mod.getIo());
                file = null;
            } else {
                try file.?.writePositionalAll(io_mod.getIo(), append_bytes.written(), boundary);
                file.?.sync(io_mod.getIo()) catch return error.UsageWriteFailed;
            }
        }

        if (shouldCompactAfterAppend(
            next_length,
            loaded,
            eventTimestamp(event),
            now_ms,
            compacted_before_append,
        )) {
            if (file) |open_file| {
                open_file.close(io_mod.getIo());
                file = null;
            }
            try self.compactLocked(alloc, now_ms);
        }
        return decision.outcome;
    }

    /// Loads one stable read-only boundary without creating profile state.
    pub fn load(self: *Store, alloc: Allocator) !Loaded {
        if (self.durable_home == null) {
            self.durable_home = try openExistingDurableHome(self.home_path);
        }
        try self.validateReadable();
        while (true) {
            const existing_lock = self.acquireExistingLock() catch |err| switch (err) {
                error.LockBusy => return error.UsageLockBusy,
                error.LockUnsupported => return error.UsageLockUnsupported,
                else => return err,
            };
            if (existing_lock) |held| {
                var lock = held;
                defer lock.release();
                return self.loadUnlocked(alloc);
            }

            var loaded = try self.loadUnlocked(alloc);
            if (!try self.lockFileExists()) return loaded;
            loaded.deinit(alloc);
        }
    }

    fn loadUnlocked(self: *Store, alloc: Allocator) !Loaded {
        var file = (try self.openUsage(false, false)) orelse return .{
            .coverage_started_at_ms = null,
            .facts = try alloc.alloc(usage_report.GenerationFact, 0),
            .pending = try alloc.alloc(usage_report.PendingMarker, 0),
            .incidents = try alloc.alloc(usage_report.Incident, 0),
            .record_count = 0,
        };
        defer file.close(io_mod.getIo());
        const boundary = try file.length(io_mod.getIo());
        return self.loadFromFile(alloc, file, boundary);
    }

    fn validateReadable(self: *Store) !void {
        const durable_home = self.durable_home orelse return;
        const stat = try durable_home.dir.stat(io_mod.getIo());
        if (stat.kind != .directory) return error.DurablePathUnsafe;
        if (comptime builtin.os.tag != .windows and (stat.permissions.toMode() & 0o777 != 0o700)) {
            return error.PrivateStatePermissionsUnsupported;
        }
    }

    fn ensureWritable(self: *Store) !void {
        if (self.durable_home == null) {
            const zio = io_mod.getIo();
            var home = io_mod.VerifiedDir{
                .dir = std.Io.Dir.openDirAbsolute(zio, self.home_path, .{
                    .iterate = true,
                }) catch return error.DurableLayoutFailed,
            };
            defer home.close();
            self.durable_home = io_mod.openOrCreateVerifiedPrivateDir(
                &home,
                profile_paths.root_dir_name,
            ) catch |err| switch (err) {
                error.PrivateStatePermissionsUnsupported, error.DurablePathUnsafe => return err,
                else => return error.DurableLayoutFailed,
            };
        }
        io_mod.applyDirPermissions(
            self.durable_home.?.dir,
            private_dir_permissions,
        ) catch return error.PrivateStatePermissionsUnsupported;
        const stat = try self.durable_home.?.dir.stat(io_mod.getIo());
        if (stat.kind != .directory) return error.DurablePathUnsafe;
        if (comptime builtin.os.tag != .windows and (stat.permissions.toMode() & 0o777 != 0o700)) {
            return error.PrivateStatePermissionsUnsupported;
        }
    }

    fn acquireLock(self: *Store) !io_mod.TimedAdvisoryLock {
        return io_mod.acquireTimedAdvisoryLockWithOps(
            &self.durable_home.?,
            usage_lock_file,
            lock_deadline_ms,
            self.lock_ops,
        );
    }

    fn acquireExistingLock(self: *Store) !?io_mod.TimedAdvisoryLock {
        const durable_home = self.durable_home orelse return null;
        const zio = io_mod.getIo();
        const file = io_mod.openFile(durable_home.dir, usage_lock_file, .{
            .mode = .read_write,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
            else => return err,
        };
        errdefer file.close(zio);
        const stat = try file.stat(zio);
        if (stat.kind != .file or stat.nlink != 1) {
            return error.DurablePathUnsafe;
        }
        if (comptime builtin.os.tag != .windows and (stat.permissions.toMode() & 0o777 != 0o600)) {
            return error.PrivateStatePermissionsUnsupported;
        }

        const started = self.lock_ops.now_ms(self.lock_ops.ctx);
        const deadline = started + @as(i64, @intCast(lock_deadline_ms));
        while (true) {
            const locked = self.lock_ops.try_lock(
                self.lock_ops.ctx,
                file,
            ) catch |err| switch (err) {
                error.FileLocksUnsupported => return error.LockUnsupported,
                else => return err,
            };
            if (locked) return .{ .file = file };
            if (self.lock_ops.now_ms(self.lock_ops.ctx) >= deadline) {
                return error.LockBusy;
            }
            self.lock_ops.sleep_ms(
                self.lock_ops.ctx,
                @min(@as(u64, 10), lock_deadline_ms),
            );
        }
    }

    fn lockFileExists(self: *Store) !bool {
        const durable_home = self.durable_home orelse return false;
        const stat = durable_home.dir.statFile(io_mod.getIo(), usage_lock_file, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return false,
            error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
            else => return err,
        };
        if (stat.kind != .file or stat.nlink != 1) {
            return error.DurablePathUnsafe;
        }
        if (comptime builtin.os.tag != .windows and (stat.permissions.toMode() & 0o777 != 0o600)) {
            return error.PrivateStatePermissionsUnsupported;
        }
        return true;
    }

    fn openUsage(
        self: *Store,
        writable: bool,
        create: bool,
    ) !?std.Io.File {
        if (self.durable_home == null) return null;
        const zio = io_mod.getIo();
        var created = false;
        var file = openExistingUsageFile(
            self.durable_home.?.dir,
            if (writable) .read_write else .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => create_file: {
                if (!create) return null;
                const new_file = self.durable_home.?.dir.createFile(zio, usage_file, .{
                    .read = true,
                    .truncate = false,
                    .exclusive = true,
                    .permissions = private_file_permissions,
                    .resolve_beneath = true,
                }) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => return self.openUsage(writable, false),
                    else => return create_err,
                };
                created = true;
                break :create_file new_file;
            },
            error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
            else => return err,
        };
        errdefer file.close(zio);

        const initial = try file.stat(zio);
        try io_mod.verifyOpenedRegularFile(
            initial,
            if (writable) .read_write else .read_only,
        );
        if (writable) {
            file.setPermissions(zio, private_file_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        const verified = if (writable) try file.stat(zio) else initial;
        if (comptime builtin.os.tag != .windows and (verified.permissions.toMode() & 0o777 != 0o600)) {
            return error.PrivateStatePermissionsUnsupported;
        }
        if (created) {
            io_mod.syncVerifiedDir(self.durable_home.?.dir) catch
                return error.DurableLayoutFailed;
        }
        return file;
    }

    fn loadFromFile(
        self: *Store,
        alloc: Allocator,
        file: std.Io.File,
        boundary: u64,
    ) !Loaded {
        _ = self;
        if (boundary > max_file_bytes) return error.UsageCapacityExceeded;
        if (boundary == 0) {
            return .{
                .coverage_started_at_ms = null,
                .facts = try alloc.alloc(usage_report.GenerationFact, 0),
                .pending = try alloc.alloc(usage_report.PendingMarker, 0),
                .incidents = try alloc.alloc(usage_report.Incident, 0),
                .record_count = 0,
            };
        }
        const byte_len = std.math.cast(usize, boundary) orelse
            return error.UsageCapacityExceeded;
        const bytes = try alloc.alloc(u8, byte_len);
        defer alloc.free(bytes);
        const read_count = try file.readPositionalAll(io_mod.getIo(), bytes, 0);
        if (read_count != byte_len) return error.UsageReadFailed;
        if (bytes[bytes.len - 1] != '\n') return error.UsageStoreIncomplete;

        var facts: std.ArrayList(usage_report.GenerationFact) = .empty;
        errdefer {
            for (facts.items) |*fact| fact.deinit(alloc);
            facts.deinit(alloc);
        }
        var pending: std.ArrayList(usage_report.PendingMarker) = .empty;
        errdefer {
            for (pending.items) |*marker| marker.deinit(alloc);
            pending.deinit(alloc);
        }
        var incidents: std.ArrayList(usage_report.Incident) = .empty;
        errdefer incidents.deinit(alloc);
        var fact_indexes: std.StringHashMapUnmanaged(VariantIndexes) = .empty;
        defer fact_indexes.deinit(alloc);
        var pending_indexes: std.StringHashMapUnmanaged(VariantIndexes) = .empty;
        defer pending_indexes.deinit(alloc);
        var coverage_started_at_ms: ?i64 = null;
        var record_count: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            record_count += 1;
            if (record_count > max_records or line.len > max_record_bytes) {
                return error.UsageCapacityExceeded;
            }
            var record = try parseRecord(alloc, line);
            defer record.deinit(alloc);
            switch (record) {
                .coverage => |started_at_ms| {
                    if (coverage_started_at_ms) |existing| {
                        if (existing != started_at_ms) return error.InvalidUsageStore;
                    } else {
                        coverage_started_at_ms = started_at_ms;
                    }
                },
                .generation => |fact| {
                    if (coverage_started_at_ms == null) return error.InvalidUsageStore;
                    if (fact_indexes.getPtr(fact.id)) |indexes| {
                        if (usage_report.GenerationFact.eql(
                            facts.items[indexes.first],
                            fact,
                        ) or (indexes.second != null and
                            usage_report.GenerationFact.eql(
                                facts.items[indexes.second.?],
                                fact,
                            )))
                        {
                            continue;
                        }
                        if (indexes.second == null) {
                            var owned = try fact.dupe(alloc);
                            facts.append(alloc, owned) catch |err| {
                                owned.deinit(alloc);
                                return err;
                            };
                            indexes.second = facts.items.len - 1;
                        }
                    } else {
                        var owned = try fact.dupe(alloc);
                        facts.append(alloc, owned) catch |err| {
                            owned.deinit(alloc);
                            return err;
                        };
                        try fact_indexes.put(
                            alloc,
                            facts.items[facts.items.len - 1].id,
                            .{ .first = facts.items.len - 1 },
                        );
                    }
                },
                .pending => |marker| {
                    if (coverage_started_at_ms == null) return error.InvalidUsageStore;
                    if (pending_indexes.getPtr(marker.id)) |indexes| {
                        if (usage_report.PendingMarker.eql(
                            pending.items[indexes.first],
                            marker,
                        ) or (indexes.second != null and
                            usage_report.PendingMarker.eql(
                                pending.items[indexes.second.?],
                                marker,
                            )))
                        {
                            continue;
                        }
                        if (indexes.second == null) {
                            var owned = try marker.dupe(alloc);
                            pending.append(alloc, owned) catch |err| {
                                owned.deinit(alloc);
                                return err;
                            };
                            indexes.second = pending.items.len - 1;
                            try incidents.append(alloc, .{
                                .occurred_at_ms = marker.observed_at_ms,
                                .completeness = .incomplete,
                            });
                        }
                    } else {
                        var owned = try marker.dupe(alloc);
                        pending.append(alloc, owned) catch |err| {
                            owned.deinit(alloc);
                            return err;
                        };
                        try pending_indexes.put(
                            alloc,
                            pending.items[pending.items.len - 1].id,
                            .{ .first = pending.items.len - 1 },
                        );
                    }
                },
                .incident => |incident| try incidents.append(alloc, incident),
            }
        }

        return .{
            .coverage_started_at_ms = coverage_started_at_ms,
            .facts = try facts.toOwnedSlice(alloc),
            .pending = try pending.toOwnedSlice(alloc),
            .incidents = try incidents.toOwnedSlice(alloc),
            .record_count = record_count,
        };
    }

    fn compactLocked(self: *Store, alloc: Allocator, now_ms: i64) !void {
        var file = (try self.openUsage(false, false)) orelse return;
        defer file.close(io_mod.getIo());
        const boundary = try file.length(io_mod.getIo());
        var loaded = try self.loadFromFile(alloc, file, boundary);
        defer loaded.deinit(alloc);

        var replacement: std.Io.Writer.Allocating = .init(alloc);
        defer replacement.deinit();
        try writeRetainedRecords(&replacement.writer, loaded, now_ms);
        try self.replaceUsageLocked(alloc, replacement.written());
    }

    fn replaceUsageLocked(
        self: *Store,
        alloc: Allocator,
        contents: []const u8,
    ) !void {
        io_mod.durableReplaceVerified(
            alloc,
            &self.durable_home.?,
            usage_file,
            contents,
        ) catch |err| switch (err) {
            error.DurableReplacePostRenameFailed => return error.UsageCommitIndeterminate,
            error.DurableReplacePreRenameFailed => return error.UsageWriteFailed,
            else => return err,
        };
    }
};

fn openExistingUsageFile(
    dir: std.Io.Dir,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    return io_mod.openExistingRegularFile(dir, usage_file, mode) catch |err| {
        if (comptime @import("builtin").os.tag == .windows) return err;
        return switch (err) {
            error.FileControlFailed => error.UsageReadFailed,
            else => err,
        };
    };
}

fn openExistingDurableHome(home_path: []const u8) !?io_mod.VerifiedDir {
    const zio = io_mod.getIo();
    var home = try std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true });
    defer home.close(zio);

    if (home.openDir(zio, profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    })) |dir| {
        errdefer dir.close(zio);
        const stat = try dir.stat(zio);
        if (stat.kind != .directory) return error.DurablePathUnsafe;
        return .{ .dir = dir };
    } else |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
        else => return err,
    }
}

fn retentionCutoff(now_ms: i64) i64 {
    return std.math.sub(i64, now_ms, retention_ms) catch 0;
}

fn hasExpiredRecords(loaded: Loaded, now_ms: i64) bool {
    const cutoff_ms = retentionCutoff(now_ms);
    for (loaded.facts) |fact| {
        if (fact.created_at_ms < cutoff_ms) return true;
    }
    for (loaded.pending) |marker| {
        if (marker.observed_at_ms < cutoff_ms or pendingResolved(loaded, marker.id)) {
            return true;
        }
    }
    for (loaded.incidents) |incident| {
        if (incident.occurred_at_ms < cutoff_ms) return true;
    }
    return false;
}

fn pendingResolved(loaded: Loaded, id: []const u8) bool {
    for (loaded.facts) |fact| {
        if (std.mem.eql(u8, fact.id, id)) return true;
    }
    return false;
}

fn checkedRecordCount(current: usize, additional: usize) !usize {
    const next = std.math.add(usize, current, additional) catch
        return error.UsageCapacityExceeded;
    if (next > max_records) return error.UsageCapacityExceeded;
    return next;
}

fn exceedsRecordCapacity(current: usize, additional: usize) bool {
    _ = checkedRecordCount(current, additional) catch return true;
    return false;
}

fn retainedRecordCount(loaded: Loaded, now_ms: i64) usize {
    const cutoff_ms = retentionCutoff(now_ms);
    var count: usize = @intFromBool(loaded.coverage_started_at_ms != null);
    for (loaded.facts) |fact| {
        if (fact.created_at_ms >= cutoff_ms) count += 1;
    }
    for (loaded.pending) |marker| {
        if (marker.observed_at_ms >= cutoff_ms and
            !pendingResolved(loaded, marker.id))
        {
            count += 1;
        }
    }
    for (loaded.incidents) |incident| {
        if (incident.occurred_at_ms >= cutoff_ms) count += 1;
    }
    return count;
}

fn shouldCompactBeforeAppend(
    next_length: u64,
    record_count: usize,
    append_record_count: usize,
    loaded: Loaded,
    now_ms: i64,
) bool {
    return (next_length > max_file_bytes or
        exceedsRecordCapacity(record_count, append_record_count)) and
        hasExpiredRecords(loaded, now_ms);
}

fn shouldCompactAfterAppend(
    next_length: u64,
    loaded: Loaded,
    appended_at_ms: i64,
    now_ms: i64,
    compacted_before_append: bool,
) bool {
    return !compacted_before_append and
        next_length > compaction_threshold_bytes and
        (hasExpiredRecords(loaded, now_ms) or
            appended_at_ms < retentionCutoff(now_ms));
}

fn inspectTail(file: std.Io.File) !TailBoundary {
    const length = try file.length(io_mod.getIo());
    if (length == 0) return .{ .length = 0, .incomplete = false };
    var last: [1]u8 = undefined;
    const count = try file.readPositionalAll(io_mod.getIo(), &last, length - 1);
    if (count == 1 and last[0] == '\n') {
        return .{ .length = length, .incomplete = false };
    }

    var cursor = length;
    var buffer: [8192]u8 = undefined;
    while (cursor > 0) {
        const start = cursor - @min(cursor, buffer.len);
        const read_len: usize = @intCast(cursor - start);
        const read_count = try file.readPositionalAll(
            io_mod.getIo(),
            buffer[0..read_len],
            start,
        );
        if (read_count != read_len) return error.UsageWriteFailed;
        if (std.mem.lastIndexOfScalar(u8, buffer[0..read_count], '\n')) |newline| {
            return .{
                .length = start + newline + 1,
                .incomplete = true,
            };
        }
        cursor = start;
    }
    return .{ .length = 0, .incomplete = true };
}

fn copyFilePrefix(
    writer: *std.Io.Writer,
    file: std.Io.File,
    boundary: u64,
) !void {
    var offset: u64 = 0;
    var buffer: [8192]u8 = undefined;
    while (offset < boundary) {
        const remaining = boundary - offset;
        const read_len: usize = @intCast(@min(remaining, buffer.len));
        const read_count = try file.readPositionalAll(
            io_mod.getIo(),
            buffer[0..read_len],
            offset,
        );
        if (read_count != read_len) return error.UsageReadFailed;
        try writer.writeAll(buffer[0..read_count]);
        offset += read_count;
    }
}

fn writeRetainedRecords(
    writer: *std.Io.Writer,
    loaded: Loaded,
    now_ms: i64,
) !void {
    const cutoff_ms = retentionCutoff(now_ms);
    if (loaded.coverage_started_at_ms) |started_at_ms| {
        try writeCoverage(writer, started_at_ms);
    }
    for (loaded.facts) |fact| {
        if (fact.created_at_ms < cutoff_ms) continue;
        try writeGeneration(writer, fact);
    }
    for (loaded.pending) |marker| {
        if (marker.observed_at_ms < cutoff_ms or
            pendingResolved(loaded, marker.id))
        {
            continue;
        }
        try writePending(writer, marker);
    }
    for (loaded.incidents) |incident| {
        if (incident.occurred_at_ms < cutoff_ms) continue;
        try writeIncident(writer, incident);
    }
}

fn validateEvent(event: usage_report.ProfileEvent) !void {
    switch (event) {
        .generation => |fact| try usage_report.validateFact(fact),
        .pending => |marker| try usage_report.validatePendingMarker(marker),
        .incident => |incident| try usage_report.validateIncident(incident),
    }
}

fn classifyEvent(
    loaded: Loaded,
    event: usage_report.ProfileEvent,
) AppendDecision {
    return switch (event) {
        .generation => |fact| classifyGeneration(loaded.facts, fact),
        .pending => |marker| classifyPending(loaded.pending, marker),
        .incident => |incident| for (loaded.incidents) |existing| {
            if (existing.occurred_at_ms == incident.occurred_at_ms and
                existing.completeness == incident.completeness)
            {
                break .{ .outcome = .duplicate, .write = false };
            }
        } else .{ .outcome = .appended, .write = true },
    };
}

fn classifyGeneration(
    facts: []const usage_report.GenerationFact,
    fact: usage_report.GenerationFact,
) AppendDecision {
    var variants: usize = 0;
    for (facts) |existing| {
        if (!std.mem.eql(u8, existing.id, fact.id)) continue;
        if (usage_report.GenerationFact.eql(existing, fact)) {
            return .{ .outcome = .duplicate, .write = false };
        }
        variants += 1;
    }
    return if (variants == 0)
        .{ .outcome = .appended, .write = true }
    else
        .{ .outcome = .conflict, .write = variants < 2 };
}

fn classifyPending(
    pending: []const usage_report.PendingMarker,
    marker: usage_report.PendingMarker,
) AppendDecision {
    var variants: usize = 0;
    for (pending) |existing| {
        if (!std.mem.eql(u8, existing.id, marker.id)) continue;
        if (usage_report.PendingMarker.eql(existing, marker)) {
            return .{ .outcome = .duplicate, .write = false };
        }
        variants += 1;
    }
    return if (variants == 0)
        .{ .outcome = .appended, .write = true }
    else
        .{ .outcome = .conflict, .write = variants < 2 };
}

fn eventTimestamp(event: usage_report.ProfileEvent) i64 {
    return switch (event) {
        .generation => |fact| fact.created_at_ms,
        .pending => |marker| marker.observed_at_ms,
        .incident => |incident| incident.occurred_at_ms,
    };
}

fn serializeEvent(
    alloc: Allocator,
    event: usage_report.ProfileEvent,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();
    switch (event) {
        .generation => |fact| try writeGeneration(&writer.writer, fact),
        .pending => |marker| try writePending(&writer.writer, marker),
        .incident => |incident| try writeIncident(&writer.writer, incident),
    }
    return writer.toOwnedSlice();
}

fn writeCoverage(writer: *std.Io.Writer, started_at_ms: i64) !void {
    try writer.print(
        "{{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":{d}}}\n",
        .{started_at_ms},
    );
}

fn writeGeneration(
    writer: *std.Io.Writer,
    fact: usage_report.GenerationFact,
) !void {
    try writer.writeAll(
        "{\"schema_version\":1,\"kind\":\"generation\",\"fact\":",
    );
    try generation_fact_codec.write(writer, fact);
    try writer.writeAll("}\n");
}

fn writePending(
    writer: *std.Io.Writer,
    marker: usage_report.PendingMarker,
) !void {
    try writer.writeAll("{\"schema_version\":1,\"kind\":\"pending\",\"id\":");
    try std.json.Stringify.value(marker.id, .{}, writer);
    try writer.print(",\"observed_at_ms\":{d}}}\n", .{marker.observed_at_ms});
}

fn writeIncident(
    writer: *std.Io.Writer,
    incident: usage_report.Incident,
) !void {
    try writer.print(
        "{{\"schema_version\":1,\"kind\":\"incident\",\"occurred_at_ms\":{d},\"completeness\":",
        .{incident.occurred_at_ms},
    );
    try std.json.Stringify.value(@tagName(incident.completeness), .{}, writer);
    try writer.writeAll("}\n");
}

fn parseRecord(alloc: Allocator, line: []const u8) !ParsedRecord {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        line,
        .{ .allocate = .alloc_always, .parse_numbers = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUsageStore,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidUsageStore;
    const schema = try parseU64(parsed.value.object.get("schema_version"));
    const kind_value = parsed.value.object.get("kind") orelse
        return error.InvalidUsageStore;
    if (schema != 1 or kind_value != .string) return error.InvalidUsageStore;

    if (std.mem.eql(u8, kind_value.string, "coverage")) {
        if (parsed.value.object.count() != 3) return error.InvalidUsageStore;
        return .{ .coverage = try parseI64(parsed.value.object.get("started_at_ms")) };
    }
    if (std.mem.eql(u8, kind_value.string, "pending")) {
        if (parsed.value.object.count() != 4) return error.InvalidUsageStore;
        const id_value = parsed.value.object.get("id") orelse
            return error.InvalidUsageStore;
        if (id_value != .string) return error.InvalidUsageStore;
        const id = try alloc.dupe(u8, id_value.string);
        errdefer alloc.free(id);
        const marker = usage_report.PendingMarker{
            .id = id,
            .observed_at_ms = try parseI64(
                parsed.value.object.get("observed_at_ms"),
            ),
        };
        usage_report.validatePendingMarker(marker) catch
            return error.InvalidUsageStore;
        return .{ .pending = marker };
    }
    if (std.mem.eql(u8, kind_value.string, "incident")) {
        if (parsed.value.object.count() != 4) return error.InvalidUsageStore;
        const completeness_value = parsed.value.object.get("completeness") orelse
            return error.InvalidUsageStore;
        if (completeness_value != .string) return error.InvalidUsageStore;
        const completeness = std.meta.stringToEnum(
            usage_report.Completeness,
            completeness_value.string,
        ) orelse return error.InvalidUsageStore;
        if (completeness != .pending and completeness != .incomplete) {
            return error.InvalidUsageStore;
        }
        return .{ .incident = .{
            .occurred_at_ms = try parseI64(parsed.value.object.get("occurred_at_ms")),
            .completeness = completeness,
        } };
    }
    if (!std.mem.eql(u8, kind_value.string, "generation") or
        parsed.value.object.count() != 3)
    {
        return error.InvalidUsageStore;
    }
    const fact_value = parsed.value.object.get("fact") orelse
        return error.InvalidUsageStore;
    return .{ .generation = generation_fact_codec.parse(
        alloc,
        fact_value,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidGenerationFact => return error.InvalidUsageStore,
    } };
}

fn parseU64(value: ?std.json.Value) !u64 {
    const actual = value orelse return error.InvalidUsageStore;
    return switch (actual) {
        .integer => |number| if (number >= 0)
            std.math.cast(u64, number) orelse error.InvalidUsageStore
        else
            error.InvalidUsageStore,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch
            error.InvalidUsageStore,
        else => error.InvalidUsageStore,
    };
}

fn parseI64(value: ?std.json.Value) !i64 {
    const number = try parseU64(value);
    return std.math.cast(i64, number) orelse error.InvalidUsageStore;
}

fn makeTestFact(
    alloc: Allocator,
    id: []const u8,
    created_at_ms: i64,
    input_tokens: u64,
) !usage_report.GenerationFact {
    const id_copy = try alloc.dupe(u8, id);
    errdefer alloc.free(id_copy);
    return .{
        .id = id_copy,
        .created_at_ms = created_at_ms,
        .model = try alloc.dupe(u8, "provider/model"),
        .input_tokens = input_tokens,
        .output_tokens = 2,
        .cache_read_tokens = 1,
        .cache_write_tokens = 0,
        .reasoning_tokens = 1,
        .total_cost = 0.25,
    };
}

test "profile usage store is read-only until first fact and dedupes exact replay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home);
    defer store.deinit(alloc);

    var empty = try store.load(alloc);
    defer empty.deinit(alloc);
    try std.testing.expect(empty.coverage_started_at_ms == null);

    var fact = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        1000,
        10,
    );
    defer fact.deinit(alloc);
    try std.testing.expectEqual(AppendOutcome.appended, try store.appendFact(alloc, fact));
    try std.testing.expectEqual(AppendOutcome.duplicate, try store.appendFact(alloc, fact));

    var loaded = try store.load(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.coverage_started_at_ms.? > 0);
    try std.testing.expectEqual(@as(usize, 1), loaded.facts.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.incidents.len);
}

test "profile usage store discovers profile state created after initialization" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var observer = try Store.initFromHome(alloc, home);
    defer observer.deinit(alloc);
    var writer = try Store.initFromHome(alloc, home);
    defer writer.deinit(alloc);

    var fact = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        1000,
        10,
    );
    defer fact.deinit(alloc);
    try std.testing.expectEqual(
        AppendOutcome.appended,
        try writer.appendFact(alloc, fact),
    );

    var loaded = try observer.load(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.coverage_started_at_ms != null);
    try std.testing.expectEqual(@as(usize, 1), loaded.facts.len);
    try std.testing.expect(usage_report.GenerationFact.eql(
        fact,
        loaded.facts[0],
    ));
}

test "profile usage readers wait for the cross-process writer boundary" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var writer = try Store.initFromHome(alloc, home);
    defer writer.deinit(alloc);
    var reader = try Store.initFromHome(alloc, home);
    defer reader.deinit(alloc);
    var fact = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        1000,
        10,
    );
    defer fact.deinit(alloc);
    try std.testing.expectEqual(
        AppendOutcome.appended,
        try writer.appendFact(alloc, fact),
    );

    const Worker = struct {
        store: *Store,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        fact_count: usize = 0,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .seq_cst);
            var loaded = self.store.load(std.heap.c_allocator) catch |err| {
                self.failure = err;
                self.done.store(true, .seq_cst);
                return;
            };
            defer loaded.deinit(std.heap.c_allocator);
            self.fact_count = loaded.facts.len;
            self.done.store(true, .seq_cst);
        }
    };
    var worker = Worker{ .store = &reader };
    var lock = try writer.acquireLock();
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    while (!worker.started.load(.seq_cst)) std.Thread.yield() catch {};
    for (0..100) |_| std.Thread.yield() catch {};
    const blocked_at_boundary = !worker.done.load(.seq_cst);
    lock.release();
    thread.join();

    try std.testing.expect(blocked_at_boundary);
    try std.testing.expect(worker.failure == null);
    try std.testing.expectEqual(@as(usize, 1), worker.fact_count);
}

test "profile usage store preserves conflicting duplicates as incomplete evidence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home);
    defer store.deinit(alloc);

    var first = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        1000,
        10,
    );
    defer first.deinit(alloc);
    var conflict = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        1000,
        11,
    );
    defer conflict.deinit(alloc);
    try std.testing.expectEqual(AppendOutcome.appended, try store.appendFact(alloc, first));
    try std.testing.expectEqual(AppendOutcome.conflict, try store.appendFact(alloc, conflict));
    var file = (try store.openUsage(false, false)).?;
    const conflicted_length = try file.length(io_mod.getIo());
    file.close(io_mod.getIo());
    try std.testing.expectEqual(AppendOutcome.duplicate, try store.appendFact(alloc, conflict));
    file = (try store.openUsage(false, false)).?;
    defer file.close(io_mod.getIo());
    try std.testing.expectEqual(conflicted_length, try file.length(io_mod.getIo()));

    var loaded = try store.load(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.facts.len);
    try std.testing.expectEqual(@as(usize, 0), loaded.incidents.len);

    var report = try usage_report.buildRollingSnapshot(
        alloc,
        .hours_24,
        2000,
        0,
        loaded.facts,
        loaded.incidents,
    );
    defer report.deinit(alloc);
    try std.testing.expectEqual(
        usage_report.Completeness.incomplete,
        report.completeness,
    );
}

test "profile usage store repairs an incomplete tail and records the gap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home);
    defer store.deinit(alloc);

    var first = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        1000,
        10,
    );
    defer first.deinit(alloc);
    try std.testing.expectEqual(
        AppendOutcome.appended,
        try store.appendFact(alloc, first),
    );

    var file = (try store.openUsage(true, false)).?;
    const length = try file.length(io_mod.getIo());
    try file.writePositionalAll(io_mod.getIo(), "{\"schema_version\":1", length);
    try file.sync(io_mod.getIo());
    file.close(io_mod.getIo());
    try std.testing.expectError(error.UsageStoreIncomplete, store.load(alloc));

    var second = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAW",
        2000,
        20,
    );
    defer second.deinit(alloc);
    try std.testing.expectEqual(
        AppendOutcome.appended,
        try store.appendFact(alloc, second),
    );
    var loaded = try store.load(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.facts.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.incidents.len);
    try std.testing.expectEqual(
        usage_report.Completeness.incomplete,
        loaded.incidents[0].completeness,
    );
}

test "profile usage store records a repaired tail when the replayed fact is duplicate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home);
    defer store.deinit(alloc);

    var fact = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        1000,
        10,
    );
    defer fact.deinit(alloc);
    try std.testing.expectEqual(
        AppendOutcome.appended,
        try store.appendFact(alloc, fact),
    );

    var file = (try store.openUsage(true, false)).?;
    const length = try file.length(io_mod.getIo());
    try file.writePositionalAll(io_mod.getIo(), "{\"schema_version\":1", length);
    try file.sync(io_mod.getIo());
    file.close(io_mod.getIo());

    try std.testing.expectEqual(
        AppendOutcome.duplicate,
        try store.appendFact(alloc, fact),
    );
    var loaded = try store.load(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), loaded.facts.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.incidents.len);
    try std.testing.expectEqual(
        usage_report.Completeness.incomplete,
        loaded.incidents[0].completeness,
    );
}

test "profile usage store leaves an incomplete tail intact when repair exceeds record capacity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        ".fx",
        (if (builtin.os.tag == .windows) std.Io.Dir.Permissions.default_dir else (if (builtin.os.tag == .windows) std.Io.Dir.Permissions.default_dir else std.Io.Dir.Permissions.fromMode(0o700))),
    );
    var profile = try tmp.dir.openDir(io_mod.getIo(), ".fx", .{ .iterate = true });
    defer profile.close(io_mod.getIo());
    profile.setPermissions(io_mod.getIo(), .fromMode(0o700)) catch
        return error.SkipZigTest;

    var contents: std.Io.Writer.Allocating = .init(alloc);
    defer contents.deinit();
    for (0..max_records) |_| try writeCoverage(&contents.writer, 1);
    try contents.writer.writeAll("{\"schema_version\":1");
    var file = try profile.createFile(io_mod.getIo(), usage_file, .{
        .permissions = private_file_permissions,
    });
    try file.writeStreamingAll(io_mod.getIo(), contents.written());
    const original_length = try file.length(io_mod.getIo());
    file.close(io_mod.getIo());
    var lock = try profile.createFile(io_mod.getIo(), usage_lock_file, .{
        .permissions = private_file_permissions,
    });
    lock.close(io_mod.getIo());

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home);
    defer store.deinit(alloc);
    var fact = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        2,
        1,
    );
    defer fact.deinit(alloc);
    try std.testing.expectError(
        error.UsageCapacityExceeded,
        store.appendFact(alloc, fact),
    );

    var unchanged = (try store.openUsage(false, false)).?;
    defer unchanged.close(io_mod.getIo());
    try std.testing.expectEqual(
        original_length,
        try unchanged.length(io_mod.getIo()),
    );
    try std.testing.expectError(error.UsageStoreIncomplete, store.load(alloc));
}

test "profile usage store repairs an existing profile directory to private mode" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        ".fx",
        (if (builtin.os.tag == .windows) std.Io.File.Permissions.default_file else (if (builtin.os.tag == .windows) std.Io.File.Permissions.default_file else std.Io.File.Permissions.fromMode(0o755))),
    );
    var profile = try tmp.dir.openDir(io_mod.getIo(), ".fx", .{ .iterate = true });
    defer profile.close(io_mod.getIo());
    profile.setPermissions(io_mod.getIo(), .fromMode(0o755)) catch
        return error.SkipZigTest;

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home);
    defer store.deinit(alloc);
    var fact = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        1000,
        10,
    );
    defer fact.deinit(alloc);
    try std.testing.expectEqual(
        AppendOutcome.appended,
        try store.appendFact(alloc, fact),
    );

    const stat = try profile.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(u32, 0o700), (if (builtin.os.tag == .windows) @as(std.posix.mode_t, 0) else stat.permissions.toMode()) & 0o777);
}

test "profile usage reads reject an unsafe profile directory without repairing it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        ".fx",
        (if (builtin.os.tag == .windows) std.Io.File.Permissions.default_file else (if (builtin.os.tag == .windows) std.Io.File.Permissions.default_file else std.Io.File.Permissions.fromMode(0o755))),
    );
    var profile = try tmp.dir.openDir(io_mod.getIo(), ".fx", .{ .iterate = true });
    defer profile.close(io_mod.getIo());
    profile.setPermissions(io_mod.getIo(), .fromMode(0o755)) catch
        return error.SkipZigTest;

    var contents: std.Io.Writer.Allocating = .init(alloc);
    defer contents.deinit();
    try writeCoverage(&contents.writer, 1);
    try writeGeneration(&contents.writer, .{
        .id = @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"),
        .created_at_ms = 1,
        .model = @constCast("provider/model"),
        .input_tokens = 1,
        .output_tokens = 1,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = null,
        .total_cost = 0.001,
    });
    var file = try profile.createFile(io_mod.getIo(), usage_file, .{
        .permissions = private_file_permissions,
    });
    try file.writeStreamingAll(io_mod.getIo(), contents.written());
    file.close(io_mod.getIo());

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home);
    defer store.deinit(alloc);
    try std.testing.expectError(
        error.PrivateStatePermissionsUnsupported,
        store.load(alloc),
    );

    const stat = try profile.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(u32, 0o755), (if (builtin.os.tag == .windows) @as(std.posix.mode_t, 0) else stat.permissions.toMode()) & 0o777);
}

test "profile usage store decodes a large ledger with stable id indexing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        ".fx",
        (if (builtin.os.tag == .windows) std.Io.File.Permissions.default_dir else (if (builtin.os.tag == .windows) std.Io.File.Permissions.default_dir else std.Io.File.Permissions.fromMode(0o700))),
    );
    var profile = try tmp.dir.openDir(io_mod.getIo(), ".fx", .{ .iterate = true });
    defer profile.close(io_mod.getIo());
    profile.setPermissions(io_mod.getIo(), .fromMode(0o700)) catch
        return error.SkipZigTest;

    const record_count: usize = 4096;
    const now_ms = @max(io_mod.milliTimestamp(), 1);
    var contents: std.Io.Writer.Allocating = .init(alloc);
    defer contents.deinit();
    try writeCoverage(&contents.writer, now_ms - 1);
    const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    for (0..record_count) |index| {
        var id = "gen_00000000000000000000000000".*;
        var value = index;
        for (0..3) |digit| {
            id[id.len - 1 - digit] = alphabet[value & 31];
            value >>= 5;
        }
        try writeGeneration(&contents.writer, .{
            .id = &id,
            .created_at_ms = now_ms - 1,
            .model = @constCast("provider/model"),
            .input_tokens = 1,
            .output_tokens = 1,
            .cache_read_tokens = 0,
            .cache_write_tokens = 0,
            .reasoning_tokens = null,
            .total_cost = 0.001,
        });
    }
    var file = try profile.createFile(io_mod.getIo(), usage_file, .{
        .permissions = private_file_permissions,
    });
    try file.writeStreamingAll(io_mod.getIo(), contents.written());
    file.close(io_mod.getIo());
    var lock = try profile.createFile(io_mod.getIo(), usage_lock_file, .{
        .permissions = private_file_permissions,
    });
    lock.close(io_mod.getIo());

    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home);
    defer store.deinit(alloc);
    var loaded = try store.load(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(record_count, loaded.facts.len);
}

test "profile usage compaction eligibility requires expired records" {
    const now_ms = std.time.ms_per_day * 100;
    var recent_fact = usage_report.GenerationFact{
        .id = @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"),
        .created_at_ms = now_ms - std.time.ms_per_day,
        .model = @constCast("provider/model"),
        .input_tokens = 1,
        .output_tokens = 1,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = null,
        .total_cost = 0.001,
    };
    var loaded = Loaded{
        .coverage_started_at_ms = 0,
        .facts = (&recent_fact)[0..1],
        .pending = &.{},
        .incidents = &.{},
        .record_count = 2,
    };
    try std.testing.expect(!hasExpiredRecords(loaded, now_ms));
    try std.testing.expect(!shouldCompactAfterAppend(
        compaction_threshold_bytes + 1,
        loaded,
        recent_fact.created_at_ms,
        now_ms,
        false,
    ));
    try std.testing.expect(!shouldCompactBeforeAppend(
        max_file_bytes + 1,
        loaded.record_count,
        1,
        loaded,
        now_ms,
    ));
    loaded.facts[0].created_at_ms = now_ms - std.time.ms_per_day * 36;
    try std.testing.expect(hasExpiredRecords(loaded, now_ms));
    try std.testing.expect(shouldCompactAfterAppend(
        compaction_threshold_bytes + 1,
        loaded,
        now_ms - 1,
        now_ms,
        false,
    ));
    try std.testing.expect(shouldCompactBeforeAppend(
        max_file_bytes + 1,
        loaded.record_count,
        1,
        loaded,
        now_ms,
    ));
    try std.testing.expect(shouldCompactBeforeAppend(
        0,
        max_records,
        1,
        loaded,
        now_ms,
    ));
}

test "profile usage record capacity is checked before append" {
    try std.testing.expectEqual(
        max_records,
        try checkedRecordCount(max_records - 2, 2),
    );
    try std.testing.expectError(
        error.UsageCapacityExceeded,
        checkedRecordCount(max_records, 1),
    );
    try std.testing.expectError(
        error.UsageCapacityExceeded,
        checkedRecordCount(max_records - 1, 2),
    );
}

test "concurrent profile usage writers serialize without losing facts" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var first_store = try Store.initFromHome(alloc, home);
    defer first_store.deinit(alloc);
    var second_store = try Store.initFromHome(alloc, home);
    defer second_store.deinit(alloc);

    const Worker = struct {
        store: *Store,
        fact: usage_report.GenerationFact,
        outcome: ?AppendOutcome = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.outcome = self.store.appendFact(
                std.heap.c_allocator,
                self.fact,
            ) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var first = Worker{
        .store = &first_store,
        .fact = .{
            .id = @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            .created_at_ms = 1000,
            .model = @constCast("provider/a"),
            .input_tokens = 10,
            .output_tokens = 2,
            .cache_read_tokens = 0,
            .cache_write_tokens = 0,
            .reasoning_tokens = null,
            .total_cost = 0.1,
        },
    };
    var second = Worker{
        .store = &second_store,
        .fact = .{
            .id = @constCast("gen_01ARZ3NDEKTSV4RRFFQ69G5FAW"),
            .created_at_ms = 1001,
            .model = @constCast("provider/b"),
            .input_tokens = 20,
            .output_tokens = 4,
            .cache_read_tokens = 1,
            .cache_write_tokens = 0,
            .reasoning_tokens = 1,
            .total_cost = 0.2,
        },
    };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    first_thread.join();
    second_thread.join();

    try std.testing.expect(first.failure == null);
    try std.testing.expect(second.failure == null);
    try std.testing.expectEqual(AppendOutcome.appended, first.outcome.?);
    try std.testing.expectEqual(AppendOutcome.appended, second.outcome.?);
    var loaded = try first_store.load(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.facts.len);
}

test "profile usage store refuses a symlinked ledger leaf" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try Store.initFromHome(alloc, home);
    defer store.deinit(alloc);

    var first = try makeTestFact(
        alloc,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        1000,
        10,
    );
    defer first.deinit(alloc);
    try std.testing.expectEqual(
        AppendOutcome.appended,
        try store.appendFact(alloc, first),
    );
    try tmp.dir.deleteFile(io_mod.getIo(), ".fx/usage.jsonl");
    var outside = try tmp.dir.createFile(io_mod.getIo(), "outside-usage", .{});
    try outside.writeStreamingAll(io_mod.getIo(), "outside");
    outside.close(io_mod.getIo());
    tmp.dir.symLink(
        io_mod.getIo(),
        "../outside-usage",
        ".fx/usage.jsonl",
        .{ .is_directory = false },
    ) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    try std.testing.expectError(error.DurablePathUnsafe, store.load(alloc));
    try std.testing.expectError(
        error.DurablePathUnsafe,
        store.appendFact(alloc, first),
    );
    const outside_bytes = try tmp.dir.readFileAlloc(
        io_mod.getIo(),
        "outside-usage",
        alloc,
        .limited(32),
    );
    defer alloc.free(outside_bytes);
    try std.testing.expectEqualStrings("outside", outside_bytes);
}
