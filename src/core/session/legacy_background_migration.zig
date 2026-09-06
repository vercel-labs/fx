const std = @import("std");
const process_identity = @import("../execution/process_identity.zig");
const process_provider = @import("../execution/process_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session_child_store = @import("session_child_store.zig");

const Allocator = std.mem.Allocator;
const max_record_bytes: usize = 256 * 1024;
const max_records: usize = 1024;
const migration_lock_name = "managed-execution-migration.lock";

pub const Result = struct {
    records_removed: usize = 0,
    logs_removed: usize = 0,
    processes_signaled: usize = 0,
    identities_unavailable: usize = 0,
};

pub fn migrate(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    provider: process_provider.Provider,
) !Result {
    var record_probe = try capability.iterate(alloc, .background_records);
    defer record_probe.deinit();
    var log_probe = try capability.iterate(alloc, .background_logs);
    defer log_probe.deinit();
    const has_records = for (record_probe.names) |name| {
        if (!std.mem.eql(u8, name, migration_lock_name)) break true;
    } else false;
    if (!has_records and log_probe.names.len == 0) return .{};

    var lock = try capability.acquireTimedAdvisoryLock(
        .background_records,
        migration_lock_name,
        2_000,
    );
    defer lock.release();

    var result: Result = .{};
    var records = try capability.iterate(alloc, .background_records);
    defer records.deinit();
    if (records.names.len > max_records) return error.LegacyBackgroundMigrationTooLarge;
    for (records.names) |name| {
        if (std.mem.eql(u8, name, migration_lock_name)) continue;
        migrateRecord(alloc, capability, provider, name, &result) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf(
                "session",
                "legacy background record migration degraded name={s} err={s}",
                .{ name, @errorName(err) },
            );
        };
        capability.delete(.background_records, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        result.records_removed += 1;
    }

    var logs = try capability.iterate(alloc, .background_logs);
    defer logs.deinit();
    if (logs.names.len > max_records) return error.LegacyBackgroundMigrationTooLarge;
    for (logs.names) |name| {
        capability.delete(.background_logs, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        result.logs_removed += 1;
    }
    return result;
}

fn migrateRecord(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    provider: process_provider.Provider,
    name: []const u8,
    result: *Result,
) !void {
    var file = try capability.openFileReadOnly(
        alloc,
        .background_records,
        name,
    );
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_record_bytes);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.InvalidLegacyBackgroundRecord;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidLegacyBackgroundRecord,
    };
    const state = stringField(object, "state") orelse return;
    if (!std.mem.eql(u8, state, "running")) return;
    const pid = stringField(object, "pid") orelse return;
    const token_text = optionalStringField(object, "process_token") orelse {
        result.identities_unavailable += 1;
        return;
    };
    const token = process_identity.ProcessInstanceToken.parse(token_text) catch {
        result.identities_unavailable += 1;
        return;
    };
    switch (provider.matchToken(alloc, pid, token)) {
        .matched => provider.signalProcess(alloc, pid, token) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                result.identities_unavailable += 1;
                return;
            },
        },
        .missing, .mismatched => return,
        .unavailable => {
            result.identities_unavailable += 1;
            return;
        },
    }
    result.processes_signaled += 1;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalStringField(
    object: std.json.ObjectMap,
    name: []const u8,
) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        .null => null,
        else => null,
    };
}

test "legacy migration revalidates identity before signaling" {
    const alloc = std.testing.allocator;
    const Stub = struct {
        var matched: usize = 0;
        var signaled: usize = 0;

        fn capture(
            _: ?*anyopaque,
            _: Allocator,
            _: []const u8,
        ) process_provider.ProviderError!process_identity.ProcessInstanceToken {
            return error.Unsupported;
        }

        fn match(
            _: ?*anyopaque,
            _: Allocator,
            pid: []const u8,
            _: process_identity.ProcessInstanceToken,
        ) process_identity.TokenMatch {
            matched += 1;
            return if (std.mem.eql(u8, pid, "123")) .matched else .mismatched;
        }

        fn signal(
            _: ?*anyopaque,
            _: Allocator,
            _: []const u8,
            _: process_identity.ProcessInstanceToken,
        ) process_provider.ProviderError!void {
            signaled += 1;
        }
    };
    Stub.matched = 0;
    Stub.signaled = 0;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "background",
        std.Io.File.Permissions.fromMode(0o700),
    );
    const background_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "background",
    );
    defer alloc.free(background_path);
    var capability = try session_child_store.SessionChildCapability.initLegacyBackgroundRoutes(
        alloc,
        background_path,
        .writable,
    );
    defer capability.deinit();
    var record = try capability.createExclusiveFile(
        alloc,
        .background_records,
        "background-1.json",
    );
    try record.writeAll(
        "{\"schema_version\":2,\"pid\":\"123\",\"process_token\":\"linux:00112233445566778899aabbccddeeff:123\",\"state\":\"running\"}",
    );
    try record.sync();
    record.deinit();
    var stale = try capability.createExclusiveFile(
        alloc,
        .background_records,
        "background-2.json",
    );
    try stale.writeAll(
        "{\"schema_version\":2,\"pid\":\"456\",\"process_token\":\"linux:00112233445566778899aabbccddeeff:456\",\"state\":\"running\"}",
    );
    try stale.sync();
    stale.deinit();
    var completed = try capability.createExclusiveFile(
        alloc,
        .background_records,
        "background-3.json",
    );
    try completed.writeAll(
        "{\"schema_version\":2,\"pid\":\"789\",\"process_token\":null,\"state\":\"exited\"}",
    );
    try completed.sync();
    completed.deinit();
    var malformed = try capability.createExclusiveFile(
        alloc,
        .background_records,
        "background-4.json",
    );
    try malformed.writeAll("not-json");
    try malformed.sync();
    malformed.deinit();
    var log = try capability.createExclusiveFile(
        alloc,
        .background_logs,
        "background-1.log",
    );
    try log.writeAll("legacy output");
    try log.sync();
    log.deinit();
    var second_log = try capability.createExclusiveFile(
        alloc,
        .background_logs,
        "background-2.log",
    );
    try second_log.writeAll("stale output");
    try second_log.sync();
    second_log.deinit();

    const result = try migrate(alloc, &capability, .{
        .capture_token_fn = Stub.capture,
        .match_token_fn = Stub.match,
        .signal_process_fn = Stub.signal,
    });
    try std.testing.expectEqual(@as(usize, 2), Stub.matched);
    try std.testing.expectEqual(@as(usize, 1), Stub.signaled);
    try std.testing.expectEqual(@as(usize, 4), result.records_removed);
    try std.testing.expectEqual(@as(usize, 2), result.logs_removed);
    try std.testing.expectEqual(@as(usize, 1), result.processes_signaled);
    var records = try capability.iterate(alloc, .background_records);
    defer records.deinit();
    try std.testing.expectEqual(@as(usize, 1), records.names.len);
    try std.testing.expectEqualStrings(migration_lock_name, records.names[0]);
    const repeated = try migrate(alloc, &capability, .{
        .capture_token_fn = Stub.capture,
        .match_token_fn = Stub.match,
        .signal_process_fn = Stub.signal,
    });
    try std.testing.expectEqual(Result{}, repeated);
}
