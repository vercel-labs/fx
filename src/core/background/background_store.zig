const std = @import("std");
const io_mod = @import("../shared/io.zig");
const process_supervisor = @import("process_supervisor.zig");
const session_child_store = @import("../session/session_child_store.zig");

const Allocator = std.mem.Allocator;
const legacy_schema_version: i64 = 1;
const schema_version: i64 = 2;
const max_record_bytes: usize = 256 * 1024;
pub const StableBackgroundRecordId =
    process_supervisor.StableBackgroundRecordId;

pub const LogStorage = union(enum) {
    managed_session: struct {
        managed_log_name: []u8,
    },
    external: struct {
        path: []u8,
    },

    pub fn deinit(self: *LogStorage, alloc: Allocator) void {
        switch (self.*) {
            .managed_session => |value| alloc.free(value.managed_log_name),
            .external => |value| alloc.free(value.path),
        }
        self.* = undefined;
    }
};

pub fn renderLogStorageJson(
    alloc: Allocator,
    storage: LogStorage,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    switch (storage) {
        .managed_session => |value| {
            try session_child_store.SessionChildCapability.validateManagedName(
                value.managed_log_name,
            );
            try out.writer.writeAll(
                "{\"kind\":\"managed_session\",\"managed_log_name\":",
            );
            try std.json.Stringify.value(
                value.managed_log_name,
                .{},
                &out.writer,
            );
        },
        .external => |value| {
            if (!std.fs.path.isAbsolute(value.path)) {
                return error.InvalidBackgroundRecord;
            }
            try out.writer.writeAll("{\"kind\":\"external\",\"path\":");
            try std.json.Stringify.value(value.path, .{}, &out.writer);
        },
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn parseLogStorageJson(
    alloc: Allocator,
    json_text: []const u8,
) !LogStorage {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        json_text,
        .{},
    ) catch return error.InvalidBackgroundRecord;
    defer parsed.deinit();
    const object = try requireObject(parsed.value);
    const kind = try requireString(object, "kind");
    if (std.mem.eql(u8, kind, "managed_session")) {
        const name = try requireString(object, "managed_log_name");
        session_child_store.SessionChildCapability.validateManagedName(name) catch
            return error.InvalidBackgroundRecord;
        return .{ .managed_session = .{
            .managed_log_name = try alloc.dupe(u8, name),
        } };
    }
    if (std.mem.eql(u8, kind, "external")) {
        const path = try requireString(object, "path");
        if (!std.fs.path.isAbsolute(path)) {
            return error.InvalidBackgroundRecord;
        }
        return .{ .external = .{
            .path = try alloc.dupe(u8, path),
        } };
    }
    return error.InvalidBackgroundRecord;
}

pub fn classifyLegacyLogStorage(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    legacy_path: []const u8,
    explicit_external_dir: ?[]const u8,
) !?LogStorage {
    if (!std.fs.path.isAbsolute(legacy_path)) return null;
    const parent = std.fs.path.dirname(legacy_path) orelse return null;
    const basename = std.fs.path.basename(legacy_path);
    session_child_store.SessionChildCapability.validateManagedName(basename) catch
        return null;

    const managed_route = try capability.displayRoutePath(
        alloc,
        .background_logs,
    );
    defer alloc.free(managed_route);
    if (std.mem.eql(u8, parent, managed_route)) {
        return .{ .managed_session = .{
            .managed_log_name = try alloc.dupe(u8, basename),
        } };
    }
    const external_dir = explicit_external_dir orelse return null;
    if (!std.mem.eql(u8, parent, external_dir)) return null;
    return .{ .external = .{
        .path = try alloc.dupe(u8, legacy_path),
    } };
}

test "managed and external background log storage remain distinct" {
    const alloc = std.testing.allocator;
    var managed = LogStorage{
        .managed_session = .{
            .managed_log_name = try alloc.dupe(u8, "managed.log"),
        },
    };
    defer managed.deinit(alloc);
    var external = LogStorage{
        .external = .{
            .path = try alloc.dupe(u8, "/tmp/managed.log"),
        },
    };
    defer external.deinit(alloc);

    switch (managed) {
        .managed_session => |value| try std.testing.expectEqualStrings(
            "managed.log",
            value.managed_log_name,
        ),
        .external => return error.ExpectedManagedSessionStorage,
    }
    switch (external) {
        .external => |value| try std.testing.expectEqualStrings(
            "/tmp/managed.log",
            value.path,
        ),
        .managed_session => return error.ExpectedExternalStorage,
    }
}

test "background log storage codec preserves managed and external identity" {
    const alloc = std.testing.allocator;
    const cases = [_]LogStorage{
        .{ .managed_session = .{
            .managed_log_name = @constCast("managed.log"),
        } },
        .{ .external = .{
            .path = @constCast("/tmp/external.log"),
        } },
    };

    for (cases) |storage| {
        const encoded = try renderLogStorageJson(alloc, storage);
        defer alloc.free(encoded);
        var decoded = try parseLogStorageJson(alloc, encoded);
        defer decoded.deinit(alloc);
        switch (storage) {
            .managed_session => |expected| switch (decoded) {
                .managed_session => |actual| try std.testing.expectEqualStrings(
                    expected.managed_log_name,
                    actual.managed_log_name,
                ),
                .external => return error.ExpectedManagedSessionStorage,
            },
            .external => |expected| switch (decoded) {
                .external => |actual| try std.testing.expectEqualStrings(
                    expected.path,
                    actual.path,
                ),
                .managed_session => return error.ExpectedExternalStorage,
            },
        }
    }
}

test "legacy log path maps to managed only for exact display parent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session-logs",
        io_mod.permissionsFromMode(0o700),
    );
    try tmp.dir.createDir(
        io_mod.getIo(),
        "external-logs",
        io_mod.permissionsFromMode(0o700),
    );
    const managed_dir = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "session-logs",
    );
    defer alloc.free(managed_dir);
    const external_dir = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "external-logs",
    );
    defer alloc.free(external_dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(
        alloc,
        managed_dir,
        .background_logs,
        .read_only,
    );
    defer capability.deinit();

    const managed_path = try std.fs.path.join(
        alloc,
        &.{ managed_dir, "managed.log" },
    );
    defer alloc.free(managed_path);
    var managed = (try classifyLegacyLogStorage(
        alloc,
        &capability,
        managed_path,
        external_dir,
    )).?;
    defer managed.deinit(alloc);
    switch (managed) {
        .managed_session => |value| try std.testing.expectEqualStrings(
            "managed.log",
            value.managed_log_name,
        ),
        .external => return error.ExpectedManagedSessionStorage,
    }

    const external_path = try std.fs.path.join(
        alloc,
        &.{ external_dir, "external.log" },
    );
    defer alloc.free(external_path);
    var external = (try classifyLegacyLogStorage(
        alloc,
        &capability,
        external_path,
        external_dir,
    )).?;
    defer external.deinit(alloc);
    switch (external) {
        .external => |value| try std.testing.expectEqualStrings(
            external_path,
            value.path,
        ),
        .managed_session => return error.ExpectedExternalStorage,
    }

    const unauthorized = try std.fs.path.join(
        alloc,
        &.{ external_dir, "..", "other.log" },
    );
    defer alloc.free(unauthorized);
    try std.testing.expect((try classifyLegacyLogStorage(
        alloc,
        &capability,
        unauthorized,
        external_dir,
    )) == null);
}

test "managed background read only absence does not create route" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        io_mod.permissionsFromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "session",
    );
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .read_only,
        .{},
    );
    defer capability.deinit();
    const store = Store.initManaged(&capability);

    try std.testing.expectError(
        error.BackgroundRecordNotFound,
        store.load(alloc, 1),
    );
    var records = try store.list(alloc);
    defer records.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), records.items.len);
    try std.testing.expectError(
        error.FileNotFound,
        session_dir.statFile(io_mod.getIo(), "background", .{}),
    );
}

pub const TaskState = process_supervisor.TaskState;

pub const Record = struct {
    id: u64,
    background_record_id: ?StableBackgroundRecordId = null,
    process_token: ?[]u8 = null,
    pid: []u8,
    command: []u8,
    cwd: []u8,
    log_path: []u8,
    log_storage: ?LogStorage = null,
    expect_url: bool,
    server_url: ?[]u8 = null,
    started_at_ms: i64,
    updated_at_ms: i64,
    exit_code: ?i32 = null,
    state: TaskState,
    diagnostic: ?[]u8 = null,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        alloc.free(self.pid);
        if (self.process_token) |process_token| alloc.free(process_token);
        alloc.free(self.command);
        alloc.free(self.cwd);
        alloc.free(self.log_path);
        if (self.log_storage) |*storage| storage.deinit(alloc);
        if (self.server_url) |url| alloc.free(url);
        if (self.diagnostic) |diagnostic| alloc.free(diagnostic);
        self.* = undefined;
    }

    pub fn fromTaskSnapshot(alloc: Allocator, snapshot: process_supervisor.TaskSnapshot, updated_at_ms: i64) !Record {
        const pid = try alloc.dupe(u8, snapshot.pid);
        errdefer alloc.free(pid);
        const command = try alloc.dupe(u8, snapshot.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, snapshot.cwd);
        errdefer alloc.free(cwd);
        const log_path = try alloc.dupe(u8, snapshot.log_path);
        errdefer alloc.free(log_path);

        var server_url: ?[]u8 = null;
        errdefer if (server_url) |url| alloc.free(url);
        if (snapshot.server_url) |url| {
            server_url = try alloc.dupe(u8, url);
        }

        return .{
            .id = snapshot.durable_record_id orelse snapshot.id,
            .background_record_id = snapshot.background_record_id,
            .process_token = if (snapshot.process_token) |token|
                try alloc.dupe(u8, token.view())
            else
                null,
            .pid = pid,
            .command = command,
            .cwd = cwd,
            .log_path = log_path,
            .log_storage = if (snapshot.managed_log_name) |name|
                .{ .managed_session = .{
                    .managed_log_name = try alloc.dupe(u8, name),
                } }
            else
                .{ .external = .{
                    .path = try alloc.dupe(u8, snapshot.log_path),
                } },
            .expect_url = snapshot.expect_url,
            .server_url = server_url,
            .started_at_ms = snapshot.started_at_ms,
            .updated_at_ms = updated_at_ms,
            .exit_code = snapshot.exit_code,
            .state = snapshot.state,
        };
    }
};

pub const Store = struct {
    capability: *session_child_store.SessionChildCapability,
    owned_capability: ?*session_child_store.SessionChildCapability = null,
    display_route_path: ?[]u8 = null,

    pub fn initManaged(
        capability: *session_child_store.SessionChildCapability,
    ) Store {
        return .{ .capability = capability };
    }

    /// Transitional legacy-only constructor retained until adapter conversion.
    pub fn initWithDir(alloc: Allocator, dir_path: []const u8) !Store {
        const owned = try alloc.create(session_child_store.SessionChildCapability);
        errdefer alloc.destroy(owned);
        owned.* = try session_child_store.SessionChildCapability.initLegacyRoute(
            alloc,
            dir_path,
            .background_records,
            .writable,
        );
        const display_route_path = try alloc.dupe(u8, dir_path);
        errdefer alloc.free(display_route_path);
        return .{
            .capability = owned,
            .owned_capability = owned,
            .display_route_path = display_route_path,
        };
    }

    pub fn initReadOnlyWithDir(
        alloc: Allocator,
        dir_path: []const u8,
    ) !Store {
        const owned = try alloc.create(
            session_child_store.SessionChildCapability,
        );
        errdefer alloc.destroy(owned);
        owned.* = try session_child_store.SessionChildCapability.initLegacyRoute(
            alloc,
            dir_path,
            .background_records,
            .read_only,
        );
        const display_route_path = try alloc.dupe(u8, dir_path);
        errdefer alloc.free(display_route_path);
        return .{
            .capability = owned,
            .owned_capability = owned,
            .display_route_path = display_route_path,
        };
    }

    pub fn deinit(self: *Store, alloc: Allocator) void {
        if (self.owned_capability) |owned| {
            owned.deinit();
            alloc.destroy(owned);
        }
        if (self.display_route_path) |path| alloc.free(path);
        self.* = undefined;
    }

    pub fn sameBacking(self: Store, other: Store) bool {
        if (self.display_route_path) |left| {
            const right = other.display_route_path orelse return false;
            return std.mem.eql(u8, left, right);
        }
        return other.display_route_path == null and
            self.capability == other.capability;
    }

    pub fn nextId(self: Store) !u64 {
        var max_id: u64 = 0;
        var entries = try self.capability.iterate(
            std.heap.c_allocator,
            .background_records,
        );
        defer entries.deinit();
        for (entries.names) |name| {
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            const basename = name[0 .. name.len - ".json".len];
            const id = std.fmt.parseUnsigned(u64, basename, 10) catch continue;
            max_id = @max(max_id, id);
        }

        return max_id + 1;
    }

    pub fn saveTaskSnapshot(self: Store, alloc: Allocator, snapshot: process_supervisor.TaskSnapshot) !void {
        var record = try Record.fromTaskSnapshot(alloc, snapshot, io_mod.milliTimestamp());
        defer record.deinit(alloc);
        try self.saveRecord(alloc, record);
    }

    pub fn saveRecord(self: Store, alloc: Allocator, record: Record) !void {
        const name = try recordName(alloc, record.id);
        defer alloc.free(name);
        try self.validateIndeterminateCurrent(alloc);

        const text = try renderRecordJson(alloc, record);
        defer alloc.free(text);

        var entry = try self.capability.atomicReplace(
            alloc,
            .background_records,
            name,
            text,
        );
        entry.deinit(alloc);
    }

    fn validateIndeterminateCurrent(
        self: Store,
        alloc: Allocator,
    ) !void {
        const pending_name = self.capability.indeterminateEntryName(
            .background_records,
        ) orelse return;
        const expected_id = try recordIdFromName(pending_name);
        var current = try loadRecordFromFile(
            alloc,
            self.capability,
            pending_name,
        );
        defer current.deinit(alloc);
        if (current.id != expected_id) {
            return error.InvalidBackgroundRecord;
        }
    }

    pub fn delete(self: Store, alloc: Allocator, id: u64) !void {
        try self.validateIndeterminateCurrent(alloc);
        const name = try recordName(alloc, id);
        defer alloc.free(name);
        self.capability.delete(.background_records, name) catch |err| switch (err) {
            error.FileNotFound => return error.BackgroundRecordNotFound,
            else => return err,
        };
    }

    pub fn load(self: Store, alloc: Allocator, id: u64) !Record {
        const name = try recordName(alloc, id);
        defer alloc.free(name);
        return loadRecordFromFile(alloc, self.capability, name);
    }

    pub fn loadByStableId(
        self: Store,
        alloc: Allocator,
        stable_id: StableBackgroundRecordId,
    ) !Record {
        var found: ?Record = null;
        errdefer if (found) |*record| record.deinit(alloc);

        var entries = try self.capability.iterate(
            alloc,
            .background_records,
        );
        defer entries.deinit();
        for (entries.names) |name| {
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            var record = loadRecordFromFile(
                alloc,
                self.capability,
                name,
            ) catch |err| switch (err) {
                error.BackgroundRecordNotFound,
                error.InvalidBackgroundRecord,
                error.UnsupportedBackgroundSchema,
                => continue,
                else => return err,
            };
            const record_id = record.background_record_id orelse {
                record.deinit(alloc);
                continue;
            };
            if (!std.mem.eql(u8, &record_id, &stable_id)) {
                record.deinit(alloc);
                continue;
            }
            if (found != null) {
                record.deinit(alloc);
                return error.DuplicateBackgroundRecordIdentity;
            }
            found = record;
        }
        return found orelse error.BackgroundRecordNotFound;
    }

    pub fn loadLatest(self: Store, alloc: Allocator) !Record {
        var records = try self.list(alloc);
        defer {
            for (records.items) |*entry| {
                entry.deinit(alloc);
            }
            records.deinit(alloc);
        }

        if (records.items.len == 0) return error.NoBackgroundRecords;
        return records.orderedRemove(0);
    }

    pub fn list(self: Store, alloc: Allocator) !std.ArrayList(Record) {
        var results: std.ArrayList(Record) = .empty;
        errdefer {
            for (results.items) |*entry| entry.deinit(alloc);
            results.deinit(alloc);
        }

        var entries = try self.capability.iterate(
            alloc,
            .background_records,
        );
        defer entries.deinit();
        for (entries.names) |name| {
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            var record = loadRecordFromFile(
                alloc,
                self.capability,
                name,
            ) catch |err| switch (err) {
                error.BackgroundRecordNotFound,
                error.InvalidBackgroundRecord,
                error.UnsupportedBackgroundSchema,
                => continue,
                else => return err,
            };
            errdefer record.deinit(alloc);
            try results.append(alloc, record);
        }

        sortRecordsNewestFirst(results.items);
        return results;
    }
};

pub fn validateAllManagedRecords(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !void {
    var entries = try capability.iterate(alloc, .background_records);
    defer entries.deinit();
    for (entries.names) |name| {
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        _ = recordIdFromName(name) catch return error.InvalidBackgroundRecord;
        var record = try loadRecordFromFile(alloc, capability, name);
        record.deinit(alloc);
    }
}

pub fn recordBelongsToWorkspace(record: Record, workspace_root: []const u8) bool {
    return process_supervisor.pathBelongsToWorkspace(record.cwd, workspace_root);
}

fn recordName(alloc: Allocator, id: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{d}.json", .{id});
}

fn recordIdFromName(name: []const u8) !u64 {
    if (!std.mem.endsWith(u8, name, ".json")) {
        return error.InvalidBackgroundRecord;
    }
    return std.fmt.parseUnsigned(
        u64,
        name[0 .. name.len - ".json".len],
        10,
    ) catch error.InvalidBackgroundRecord;
}

fn readRecordFile(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
) ![]u8 {
    var file = capability.openFileReadOnly(
        alloc,
        .background_records,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.BackgroundRecordNotFound,
        else => return err,
    };
    defer file.deinit();

    return file.readToEnd(alloc, max_record_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidBackgroundRecord,
        else => return err,
    };
}

/// Returns an owned record; caller must deinit it with Record.deinit.
fn loadRecordFromFile(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
) !Record {
    const bytes = try readRecordFile(alloc, capability, name);
    defer alloc.free(bytes);
    return parseRecord(alloc, bytes);
}

fn renderRecordJson(alloc: Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const stable_id = record.background_record_id;
    try out.writer.print(
        "{{\"schema_version\":{d},\"id\":{d},\"started_at_ms\":{d},\"updated_at_ms\":{d}",
        .{
            if (stable_id != null) schema_version else legacy_schema_version,
            record.id,
            record.started_at_ms,
            record.updated_at_ms,
        },
    );
    if (stable_id) |value| {
        var encoded: [32]u8 = undefined;
        encodeStableId(&encoded, value);
        try out.writer.writeAll(",\"background_record_id\":");
        try std.json.Stringify.value(encoded[0..], .{}, &out.writer);
        try out.writer.writeAll(",\"process_token\":");
        if (record.process_token) |token| {
            _ = try process_supervisor.ProcessInstanceToken.parse(token);
            try std.json.Stringify.value(token, .{}, &out.writer);
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeAll(",\"log_storage\":");
        const storage = record.log_storage orelse
            return error.InvalidBackgroundRecord;
        const storage_json = try renderLogStorageJson(alloc, storage);
        defer alloc.free(storage_json);
        try out.writer.writeAll(storage_json);
    }
    try out.writer.writeAll(",\"pid\":");
    try std.json.Stringify.value(record.pid, .{}, &out.writer);
    try out.writer.writeAll(",\"command\":");
    try std.json.Stringify.value(record.command, .{}, &out.writer);
    try out.writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(record.cwd, .{}, &out.writer);
    try out.writer.writeAll(",\"log_path\":");
    try std.json.Stringify.value(record.log_path, .{}, &out.writer);
    try out.writer.print(",\"expect_url\":{s}", .{if (record.expect_url) "true" else "false"});
    try out.writer.writeAll(",\"server_url\":");
    if (record.server_url) |url| {
        try std.json.Stringify.value(url, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"exit_code\":");
    if (record.exit_code) |code| {
        try out.writer.print("{d}", .{code});
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"state\":");
    try std.json.Stringify.value(@tagName(record.state), .{}, &out.writer);
    try out.writer.writeAll(",\"diagnostic\":");
    if (record.diagnostic) |diagnostic| {
        try std.json.Stringify.value(diagnostic, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn parseRecord(alloc: Allocator, json_text: []const u8) !Record {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidBackgroundRecord;
    defer parsed.deinit();

    const root = try requireObject(parsed.value);
    const record_schema_version = try requireSchemaVersion(root);

    const id = try requireU64(root, "id");
    var background_record_id: ?StableBackgroundRecordId = null;
    var process_token_raw: ?[]const u8 = null;
    var log_storage: ?LogStorage = null;
    errdefer if (log_storage) |*storage| storage.deinit(alloc);
    if (record_schema_version == schema_version) {
        background_record_id = try parseStableId(
            try requireString(root, "background_record_id"),
        );
        process_token_raw = try optionalString(root.get("process_token"));
        if (process_token_raw) |token| {
            _ = process_supervisor.ProcessInstanceToken.parse(token) catch
                return error.InvalidBackgroundRecord;
        }
        const storage_value = root.get("log_storage") orelse
            return error.InvalidBackgroundRecord;
        log_storage = try parseLogStorageValue(alloc, storage_value);
    }
    const pid_raw = try requireString(root, "pid");
    const command_raw = try requireString(root, "command");
    const cwd_raw = try requireString(root, "cwd");
    const log_path_raw = try requireString(root, "log_path");
    const expect_url = try requireBool(root, "expect_url");
    const server_url_raw = try optionalString(root.get("server_url"));
    const started_at_ms = try requireI64(root, "started_at_ms");
    const updated_at_ms = try requireI64(root, "updated_at_ms");
    const exit_code = try optionalI32(root.get("exit_code"));
    const state = try parseState(try requireString(root, "state"));
    const diagnostic_raw = try optionalString(root.get("diagnostic"));

    const pid = try alloc.dupe(u8, pid_raw);
    errdefer alloc.free(pid);
    const command = try alloc.dupe(u8, command_raw);
    errdefer alloc.free(command);
    const cwd = try alloc.dupe(u8, cwd_raw);
    errdefer alloc.free(cwd);
    const log_path = try alloc.dupe(u8, log_path_raw);
    errdefer alloc.free(log_path);

    var process_token: ?[]u8 = null;
    errdefer if (process_token) |value| alloc.free(value);
    if (process_token_raw) |value| {
        process_token = try alloc.dupe(u8, value);
    }

    var server_url: ?[]u8 = null;
    errdefer if (server_url) |url| alloc.free(url);
    if (server_url_raw) |url| {
        server_url = try alloc.dupe(u8, url);
    }

    var diagnostic: ?[]u8 = null;
    errdefer if (diagnostic) |value| alloc.free(value);
    if (diagnostic_raw) |value| {
        diagnostic = try alloc.dupe(u8, value);
    }

    return .{
        .id = id,
        .background_record_id = background_record_id,
        .process_token = process_token,
        .pid = pid,
        .command = command,
        .cwd = cwd,
        .log_path = log_path,
        .log_storage = log_storage,
        .expect_url = expect_url,
        .server_url = server_url,
        .started_at_ms = started_at_ms,
        .updated_at_ms = updated_at_ms,
        .exit_code = exit_code,
        .state = state,
        .diagnostic = diagnostic,
    };
}

fn parseState(raw: []const u8) !TaskState {
    return std.meta.stringToEnum(TaskState, raw) orelse error.InvalidBackgroundRecord;
}

fn requireSchemaVersion(object: std.json.ObjectMap) !i64 {
    const version = try requireI64(object, "schema_version");
    if (version != legacy_schema_version and version != schema_version) {
        return error.UnsupportedBackgroundSchema;
    }
    return version;
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidBackgroundRecord;
    return value.object;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    if (value != .string) return error.InvalidBackgroundRecord;
    return value.string;
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    if (value != .bool) return error.InvalidBackgroundRecord;
    return value.bool;
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    return switch (value) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return error.InvalidBackgroundRecord,
        else => error.InvalidBackgroundRecord,
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    return switch (value) {
        .integer => |number| blk: {
            if (number < 0) return error.InvalidBackgroundRecord;
            break :blk @intCast(number);
        },
        .number_string => |text| std.fmt.parseUnsigned(u64, text, 10) catch return error.InvalidBackgroundRecord,
        else => error.InvalidBackgroundRecord,
    };
}

fn optionalString(maybe_value: ?std.json.Value) !?[]const u8 {
    const value = maybe_value orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidBackgroundRecord,
    };
}

fn optionalI32(maybe_value: ?std.json.Value) !?i32 {
    const value = maybe_value orelse return null;
    return switch (value) {
        .null => null,
        .integer => |number| blk: {
            if (number < std.math.minInt(i32) or number > std.math.maxInt(i32)) {
                return error.InvalidBackgroundRecord;
            }
            break :blk @intCast(number);
        },
        .number_string => |text| std.fmt.parseInt(i32, text, 10) catch return error.InvalidBackgroundRecord,
        else => error.InvalidBackgroundRecord,
    };
}

pub fn sortRecordsNewestFirst(items: []Record) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and items[j - 1].updated_at_ms < items[j].updated_at_ms) : (j -= 1) {
            std.mem.swap(Record, &items[j - 1], &items[j]);
        }
    }
}

pub const DurableRecordRank = struct {
    updated_at_ms: i64,
    source_session_id: []const u8,
    background_record_id: StableBackgroundRecordId,
};

pub fn durableRecordRanksBefore(
    left: DurableRecordRank,
    right: DurableRecordRank,
) bool {
    if (left.updated_at_ms != right.updated_at_ms) {
        return left.updated_at_ms > right.updated_at_ms;
    }
    const source_order = std.mem.order(
        u8,
        left.source_session_id,
        right.source_session_id,
    );
    if (source_order != .eq) return source_order == .gt;
    return std.mem.order(
        u8,
        &left.background_record_id,
        &right.background_record_id,
    ) == .gt;
}

fn parseLogStorageValue(
    alloc: Allocator,
    value: std.json.Value,
) !LogStorage {
    if (value != .object) return error.InvalidBackgroundRecord;
    const kind = try requireString(value.object, "kind");
    if (std.mem.eql(u8, kind, "managed_session")) {
        const name = try requireString(value.object, "managed_log_name");
        session_child_store.SessionChildCapability.validateManagedName(name) catch
            return error.InvalidBackgroundRecord;
        return .{ .managed_session = .{
            .managed_log_name = try alloc.dupe(u8, name),
        } };
    }
    if (std.mem.eql(u8, kind, "external")) {
        const path = try requireString(value.object, "path");
        if (!std.fs.path.isAbsolute(path)) {
            return error.InvalidBackgroundRecord;
        }
        return .{ .external = .{ .path = try alloc.dupe(u8, path) } };
    }
    return error.InvalidBackgroundRecord;
}

fn encodeStableId(
    out: *[32]u8,
    stable_id: StableBackgroundRecordId,
) void {
    const alphabet = "0123456789abcdef";
    for (stable_id, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn parseStableId(text: []const u8) !StableBackgroundRecordId {
    if (text.len != 32) return error.InvalidBackgroundRecord;
    var stable_id: StableBackgroundRecordId = undefined;
    for (&stable_id, 0..) |*byte, index| {
        const high = std.fmt.charToDigit(text[index * 2], 16) catch
            return error.InvalidBackgroundRecord;
        const low = std.fmt.charToDigit(text[index * 2 + 1], 16) catch
            return error.InvalidBackgroundRecord;
        if (std.ascii.isUpper(text[index * 2]) or
            std.ascii.isUpper(text[index * 2 + 1]))
        {
            return error.InvalidBackgroundRecord;
        }
        byte.* = @intCast(high * 16 + low);
    }
    return stable_id;
}

fn initTestStore(alloc: Allocator, root_dir: std.Io.Dir) !Store {
    try root_dir.createDirPath(io_mod.getIo(), "background");
    const bg_dir = try io_mod.dirRealpathAlloc(alloc, root_dir, "background");
    defer alloc.free(bg_dir);
    return Store.initWithDir(alloc, bg_dir);
}

fn writeStoreFile(alloc: Allocator, store: Store, name: []const u8, text: []const u8) !void {
    var entry = try store.capability.atomicReplace(
        alloc,
        .background_records,
        name,
        text,
    );
    entry.deinit(alloc);
}

fn writeRecordText(alloc: Allocator, store: Store, id: u64, text: []const u8) !void {
    const name = try recordName(alloc, id);
    defer alloc.free(name);
    try writeStoreFile(alloc, store, name, text);
}

fn validRecordJson(alloc: Allocator, id: u64, updated_at_ms: i64) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"schema_version\":1,\"id\":{d},\"started_at_ms\":1,\"updated_at_ms\":{d},\"pid\":\"{d}\",\"command\":\"npm run dev\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/{d}.log\",\"expect_url\":true,\"server_url\":\"http://localhost:{d}\",\"exit_code\":null,\"state\":\"running\"}}",
        .{ id, updated_at_ms, 1000 + id, id, 3000 + id },
    );
}

fn validRecordV2Json(
    alloc: Allocator,
    id: u64,
    stable_id: StableBackgroundRecordId,
    updated_at_ms: i64,
) ![]u8 {
    var encoded: [32]u8 = undefined;
    encodeStableId(&encoded, stable_id);
    return std.fmt.allocPrint(
        alloc,
        "{{\"schema_version\":2,\"id\":{d},\"background_record_id\":\"{s}\",\"process_token\":\"linux:00112233445566778899aabbccddeeff:12345\",\"log_storage\":{{\"kind\":\"external\",\"path\":\"/tmp/{d}.log\"}},\"started_at_ms\":1,\"updated_at_ms\":{d},\"pid\":\"{d}\",\"command\":\"npm run dev\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/{d}.log\",\"expect_url\":true,\"server_url\":null,\"exit_code\":null,\"state\":\"running\",\"diagnostic\":null}}",
        .{ id, encoded[0..], id, updated_at_ms, 1000 + id, id },
    );
}

fn recordJsonWithNumericFields(
    alloc: Allocator,
    id: []const u8,
    started_at_ms: []const u8,
    updated_at_ms: []const u8,
    exit_code: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"schema_version\":1,\"id\":{s},\"started_at_ms\":{s},\"updated_at_ms\":{s},\"pid\":\"100\",\"command\":\"vite\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/a.log\",\"expect_url\":false,\"server_url\":null,\"exit_code\":{s},\"state\":\"running\"}}",
        .{ id, started_at_ms, updated_at_ms, exit_code },
    );
}

fn expectParseError(expected: anyerror, json_text: []const u8) !void {
    const alloc = std.testing.allocator;
    if (parseRecord(alloc, json_text)) |parsed| {
        var record = parsed;
        defer record.deinit(alloc);
        return error.ExpectedParseFailure;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

test "saved record roundtrip preserves every field" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try initTestStore(alloc, tmp.dir);
    defer store.deinit(alloc);

    var record = Record{
        .id = 7,
        .pid = try alloc.dupe(u8, "1234"),
        .command = try alloc.dupe(u8, "npm run dev"),
        .cwd = try alloc.dupe(u8, "/tmp/fx"),
        .log_path = try alloc.dupe(u8, "/tmp/fx.log"),
        .expect_url = true,
        .server_url = try alloc.dupe(u8, "http://localhost:3000"),
        .started_at_ms = 100,
        .updated_at_ms = 200,
        .exit_code = -2,
        .state = .failed,
    };
    defer record.deinit(alloc);

    try store.saveRecord(alloc, record);

    var loaded = try store.load(alloc, 7);
    defer loaded.deinit(alloc);

    try std.testing.expectEqual(@as(u64, 7), loaded.id);
    try std.testing.expectEqualStrings("1234", loaded.pid);
    try std.testing.expectEqualStrings("npm run dev", loaded.command);
    try std.testing.expectEqualStrings("/tmp/fx", loaded.cwd);
    try std.testing.expectEqualStrings("/tmp/fx.log", loaded.log_path);
    try std.testing.expect(loaded.expect_url);
    try std.testing.expectEqualStrings("http://localhost:3000", loaded.server_url.?);
    try std.testing.expectEqual(@as(i64, 100), loaded.started_at_ms);
    try std.testing.expectEqual(@as(i64, 200), loaded.updated_at_ms);
    try std.testing.expectEqual(@as(?i32, -2), loaded.exit_code);
    try std.testing.expectEqual(TaskState.failed, loaded.state);
}

test "schema v2 roundtrip preserves stable identity token and managed log authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try initTestStore(alloc, tmp.dir);
    defer store.deinit(alloc);

    var record = Record{
        .id = 7,
        .background_record_id = .{
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        },
        .process_token = try alloc.dupe(
            u8,
            "linux:00112233445566778899aabbccddeeff:12345",
        ),
        .pid = try alloc.dupe(u8, "1234"),
        .command = try alloc.dupe(u8, "npm run dev"),
        .cwd = try alloc.dupe(u8, "/tmp/fx"),
        .log_path = try alloc.dupe(u8, "/tmp/fx.log"),
        .log_storage = .{ .managed_session = .{
            .managed_log_name = try alloc.dupe(u8, "fx-cmd-test.log"),
        } },
        .expect_url = true,
        .started_at_ms = 100,
        .updated_at_ms = 200,
        .state = .running,
    };
    defer record.deinit(alloc);

    try store.saveRecord(alloc, record);

    var loaded = try store.loadByStableId(alloc, record.background_record_id.?);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(record.background_record_id.?, loaded.background_record_id.?);
    try std.testing.expectEqualStrings(record.process_token.?, loaded.process_token.?);
    switch (loaded.log_storage.?) {
        .managed_session => |managed| try std.testing.expectEqualStrings(
            "fx-cmd-test.log",
            managed.managed_log_name,
        ),
        .external => return error.ExpectedManagedSessionStorage,
    }
}

test "duplicate stable ids authorize no exact lookup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try initTestStore(alloc, tmp.dir);
    defer store.deinit(alloc);

    const stable_id = [_]u8{0x42} ** 16;
    const first = try validRecordV2Json(alloc, 1, stable_id, 10);
    defer alloc.free(first);
    const second = try validRecordV2Json(alloc, 2, stable_id, 20);
    defer alloc.free(second);
    try writeRecordText(alloc, store, 1, first);
    try writeRecordText(alloc, store, 2, second);

    try std.testing.expectError(
        error.DuplicateBackgroundRecordIdentity,
        store.loadByStableId(alloc, stable_id),
    );
}

test "cross session duplicate numeric ranking is deterministic and read only" {
    const stable_a = [_]u8{0x11} ** 16;
    const stable_b = [_]u8{0x22} ** 16;
    const left = DurableRecordRank{
        .updated_at_ms = 10,
        .source_session_id = "session-a",
        .background_record_id = stable_a,
    };
    const newer = DurableRecordRank{
        .updated_at_ms = 11,
        .source_session_id = "session-a",
        .background_record_id = stable_a,
    };
    const same_time_later_session = DurableRecordRank{
        .updated_at_ms = 10,
        .source_session_id = "session-b",
        .background_record_id = stable_a,
    };
    const same_session_later_stable = DurableRecordRank{
        .updated_at_ms = 10,
        .source_session_id = "session-a",
        .background_record_id = stable_b,
    };

    try std.testing.expect(durableRecordRanksBefore(newer, left));
    try std.testing.expect(durableRecordRanksBefore(same_time_later_session, left));
    try std.testing.expect(durableRecordRanksBefore(same_session_later_stable, left));
}

test "Record.fromTaskSnapshot deep-copies fields and optional server URL" {
    const alloc = std.testing.allocator;
    var snapshot = process_supervisor.TaskSnapshot{
        .id = 5,
        .pid = try alloc.dupe(u8, "1234"),
        .command = try alloc.dupe(u8, "vite"),
        .cwd = try alloc.dupe(u8, "/workspace"),
        .log_path = try alloc.dupe(u8, "/tmp/fx.log"),
        .expect_url = true,
        .server_url = try alloc.dupe(u8, "http://localhost:5173"),
        .started_at_ms = 10,
        .exit_code = null,
        .state = .running,
    };
    defer snapshot.deinit(alloc);

    var record = try Record.fromTaskSnapshot(alloc, snapshot, 99);
    defer record.deinit(alloc);

    snapshot.pid[0] = '9';
    snapshot.command[0] = 'x';
    snapshot.cwd[1] = 'x';
    snapshot.log_path[5] = 'y';
    snapshot.server_url.?[7] = 'x';

    try std.testing.expectEqual(@as(u64, 5), record.id);
    try std.testing.expectEqualStrings("1234", record.pid);
    try std.testing.expectEqualStrings("vite", record.command);
    try std.testing.expectEqualStrings("/workspace", record.cwd);
    try std.testing.expectEqualStrings("/tmp/fx.log", record.log_path);
    try std.testing.expect(record.expect_url);
    try std.testing.expectEqualStrings("http://localhost:5173", record.server_url.?);
    try std.testing.expectEqual(@as(i64, 10), record.started_at_ms);
    try std.testing.expectEqual(@as(i64, 99), record.updated_at_ms);
    try std.testing.expectEqual(TaskState.running, record.state);

    var no_url_snapshot = process_supervisor.TaskSnapshot{
        .id = 6,
        .pid = try alloc.dupe(u8, "1235"),
        .command = try alloc.dupe(u8, "worker"),
        .cwd = try alloc.dupe(u8, "/workspace"),
        .log_path = try alloc.dupe(u8, "/tmp/worker.log"),
        .expect_url = false,
        .server_url = null,
        .started_at_ms = 11,
        .exit_code = 0,
        .state = .exited,
    };
    defer no_url_snapshot.deinit(alloc);

    var no_url_record = try Record.fromTaskSnapshot(alloc, no_url_snapshot, 100);
    defer no_url_record.deinit(alloc);
    try std.testing.expect(no_url_record.server_url == null);
    try std.testing.expectEqual(@as(?i32, 0), no_url_record.exit_code);
}

test "Store.nextId scans existing JSON filenames and ignores non-record files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try initTestStore(alloc, tmp.dir);
    defer store.deinit(alloc);

    try writeStoreFile(alloc, store, "9.json", "");
    try writeStoreFile(alloc, store, "not-a-record.json", "");
    try writeStoreFile(alloc, store, "10.txt", "");

    try std.testing.expectEqual(@as(u64, 10), try store.nextId());
}

test "Store.list sorts records newest first" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try initTestStore(alloc, tmp.dir);
    defer store.deinit(alloc);

    var older = Record{
        .id = 1,
        .pid = try alloc.dupe(u8, "100"),
        .command = try alloc.dupe(u8, "vite"),
        .cwd = try alloc.dupe(u8, "/tmp"),
        .log_path = try alloc.dupe(u8, "/tmp/older.log"),
        .expect_url = false,
        .server_url = null,
        .started_at_ms = 1,
        .updated_at_ms = 2,
        .exit_code = null,
        .state = .running,
    };
    defer older.deinit(alloc);
    var newer = Record{
        .id = 2,
        .pid = try alloc.dupe(u8, "101"),
        .command = try alloc.dupe(u8, "npm run dev"),
        .cwd = try alloc.dupe(u8, "/tmp"),
        .log_path = try alloc.dupe(u8, "/tmp/newer.log"),
        .expect_url = true,
        .server_url = try alloc.dupe(u8, "http://localhost:3000"),
        .started_at_ms = 1,
        .updated_at_ms = 5,
        .exit_code = null,
        .state = .running,
    };
    defer newer.deinit(alloc);

    try store.saveRecord(alloc, older);
    try store.saveRecord(alloc, newer);

    var records = try store.list(alloc);
    defer {
        for (records.items) |*entry| entry.deinit(alloc);
        records.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 2), records.items.len);
    try std.testing.expectEqual(@as(u64, 2), records.items[0].id);
    try std.testing.expectEqual(@as(u64, 1), records.items[1].id);
}

test "Store.loadLatest returns newest valid record and NoBackgroundRecords when empty" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try initTestStore(alloc, tmp.dir);
    defer store.deinit(alloc);

    try std.testing.expectError(error.NoBackgroundRecords, store.loadLatest(alloc));

    const older = try validRecordJson(alloc, 1, 2);
    defer alloc.free(older);
    const newer = try validRecordJson(alloc, 2, 9);
    defer alloc.free(newer);
    try writeRecordText(alloc, store, 1, older);
    try writeRecordText(alloc, store, 2, newer);

    var latest = try store.loadLatest(alloc);
    defer latest.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 2), latest.id);
    try std.testing.expectEqual(@as(i64, 9), latest.updated_at_ms);
}

test "corrupt invalid and unsupported records are skipped by list and loadLatest" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try initTestStore(alloc, tmp.dir);
    defer store.deinit(alloc);

    try writeRecordText(alloc, store, 1, "{\"schema_version\":1,");
    try writeRecordText(alloc, store, 2, "{\"schema_version\":1,\"id\":2}");
    try writeRecordText(alloc, store, 3, "{\"schema_version\":2,\"id\":3}");
    const valid = try validRecordJson(alloc, 4, 10);
    defer alloc.free(valid);
    try writeRecordText(alloc, store, 4, valid);

    var records = try store.list(alloc);
    defer {
        for (records.items) |*entry| entry.deinit(alloc);
        records.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 1), records.items.len);
    try std.testing.expectEqual(@as(u64, 4), records.items[0].id);

    var latest = try store.loadLatest(alloc);
    defer latest.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 4), latest.id);

    var bad_tmp = std.testing.tmpDir(.{});
    defer bad_tmp.cleanup();
    var bad_store = try initTestStore(alloc, bad_tmp.dir);
    defer bad_store.deinit(alloc);

    try writeRecordText(alloc, bad_store, 1, "{\"schema_version\":1,");
    try writeRecordText(alloc, bad_store, 2, "{\"schema_version\":1,\"id\":2}");
    try writeRecordText(alloc, bad_store, 3, "{\"schema_version\":2,\"id\":3}");
    try std.testing.expectError(error.NoBackgroundRecords, bad_store.loadLatest(alloc));
}

test "oversize files map to InvalidBackgroundRecord" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try initTestStore(alloc, tmp.dir);
    defer store.deinit(alloc);

    const text = try alloc.alloc(u8, max_record_bytes + 1);
    defer alloc.free(text);
    @memset(text, 'x');
    try writeRecordText(alloc, store, 1, text);

    try std.testing.expectError(error.InvalidBackgroundRecord, store.load(alloc, 1));
}

test "numeric overflow in persisted fields is rejected" {
    const alloc = std.testing.allocator;

    const id_overflow = try recordJsonWithNumericFields(alloc, "18446744073709551616", "1", "2", "null");
    defer alloc.free(id_overflow);
    try expectParseError(error.InvalidBackgroundRecord, id_overflow);

    const started_overflow = try recordJsonWithNumericFields(alloc, "1", "9223372036854775808", "2", "null");
    defer alloc.free(started_overflow);
    try expectParseError(error.InvalidBackgroundRecord, started_overflow);

    const updated_overflow = try recordJsonWithNumericFields(alloc, "1", "1", "-9223372036854775809", "null");
    defer alloc.free(updated_overflow);
    try expectParseError(error.InvalidBackgroundRecord, updated_overflow);

    const exit_overflow = try recordJsonWithNumericFields(alloc, "1", "1", "2", "2147483648");
    defer alloc.free(exit_overflow);
    try expectParseError(error.InvalidBackgroundRecord, exit_overflow);
}

test "unknown task-state label and wrong JSON field types are rejected" {
    try expectParseError(
        error.InvalidBackgroundRecord,
        "{\"schema_version\":1,\"id\":1,\"started_at_ms\":1,\"updated_at_ms\":2,\"pid\":\"100\",\"command\":\"vite\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/a.log\",\"expect_url\":false,\"server_url\":null,\"exit_code\":null,\"state\":\"missing\"}",
    );

    const wrong_type_cases = [_][]const u8{
        "{\"schema_version\":1,\"id\":\"1\",\"started_at_ms\":1,\"updated_at_ms\":2,\"pid\":\"100\",\"command\":\"vite\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/a.log\",\"expect_url\":false,\"server_url\":null,\"exit_code\":null,\"state\":\"running\"}",
        "{\"schema_version\":1,\"id\":1,\"started_at_ms\":1,\"updated_at_ms\":2,\"pid\":100,\"command\":\"vite\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/a.log\",\"expect_url\":false,\"server_url\":null,\"exit_code\":null,\"state\":\"running\"}",
        "{\"schema_version\":1,\"id\":1,\"started_at_ms\":1,\"updated_at_ms\":2,\"pid\":\"100\",\"command\":\"vite\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/a.log\",\"expect_url\":\"false\",\"server_url\":null,\"exit_code\":null,\"state\":\"running\"}",
        "{\"schema_version\":1,\"id\":1,\"started_at_ms\":1,\"updated_at_ms\":2,\"pid\":\"100\",\"command\":\"vite\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/a.log\",\"expect_url\":false,\"server_url\":123,\"exit_code\":null,\"state\":\"running\"}",
        "{\"schema_version\":1,\"id\":1,\"started_at_ms\":1,\"updated_at_ms\":2,\"pid\":\"100\",\"command\":\"vite\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/a.log\",\"expect_url\":false,\"server_url\":null,\"exit_code\":\"0\",\"state\":\"running\"}",
    };

    for (wrong_type_cases) |json_text| {
        try expectParseError(error.InvalidBackgroundRecord, json_text);
    }
}

test "Record.deinit and Store.deinit free owned fields" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try initTestStore(alloc, tmp.dir);
    store.deinit(alloc);

    var record = Record{
        .id = 1,
        .pid = try alloc.dupe(u8, "100"),
        .command = try alloc.dupe(u8, "vite"),
        .cwd = try alloc.dupe(u8, "/tmp"),
        .log_path = try alloc.dupe(u8, "/tmp/a.log"),
        .expect_url = false,
        .server_url = try alloc.dupe(u8, "http://localhost:3000"),
        .started_at_ms = 1,
        .updated_at_ms = 2,
        .exit_code = 0,
        .state = .exited,
    };
    record.deinit(alloc);
}
