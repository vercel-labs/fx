//! One-use exec authority bound to an acknowledged native journal position.
//! Callers hold the session writer lock and stop work admission throughout.
const std = @import("std");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const session_log = @import("session_log.zig");
const journal = @import("execution_journal.zig");
const journal_runtime = @import("../agent/runtime/journal_runtime.zig");

const Allocator = std.mem.Allocator;
pub const Reason = enum { upgrade, restart };
const file_name = "upgrade-handoff.json";
const schema_version = 3;

pub const Boundary = struct {
    session_hash: [32]u8,
    workspace_hash: [32]u8,
    seq: u64,
    hash: [64]u8,
    turn_id: u64,
};

pub const Consumption = struct {
    reason: Reason,
    continuation: ?Boundary,
};

const Record = struct {
    version: u32 = schema_version,
    reason: Reason,
    boundary: Boundary,
    continue_turn: bool,
    process_id: i32,
    capability_fd: i32,
    capability_sha256: [32]u8,
};

fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn boundary(loaded: *session_log.LoadedWritableSession) !Boundary {
    try loaded.requireWritable();
    const records = loaded.journalState() orelse return error.JournalWriterRequired;
    return boundaryFor(records, loaded.active_id, loaded.state.workspace_root);
}

fn boundaryFor(records: *const journal.State, session_id: []const u8, workspace: []const u8) !Boundary {
    try records.ensureAvailable();
    const turn_id: u64 = switch (records.pending()) {
        .idle => 0,
        .tool => return error.UpgradeNeedsToolIntervention,
        .model, .ending => |index| pending: {
            // A graceful suspension never leaves a provider request in flight.
            // Ordinary recovery can retry it explicitly; exec cannot grant that.
            if (records.requestForCurrentStep(index) != null) return error.UpgradeRequestUnsettled;
            const start = records.start(index);
            break :pending try journal_runtime.decodeRuntimeTurnId(start);
        },
    };
    return .{
        .session_hash = digest(session_id),
        .workspace_hash = digest(workspace),
        .seq = records.last_seq,
        .hash = records.last_hash,
        .turn_id = turn_id,
    };
}

fn validate(record: Record, current: Boundary) !void {
    if (record.version != schema_version or !std.meta.eql(record.boundary, current) or
        (record.continue_turn and current.turn_id == 0)) return error.InvalidUpgradeHandoff;
}

fn replaceMarker(alloc: Allocator, loaded: *session_log.LoadedWritableSession, bytes: []const u8, ops: io_mod.DurableOps) !void {
    io_mod.durableReplaceVerifiedWithOps(alloc, &loaded.log.dir, file_name, bytes, ops) catch |err| {
        if (err == error.DurableReplacePostRenameFailed) {
            loaded.markCommitFailed();
            return error.SessionPersistenceUncertain;
        }
        return err;
    };
}

/// Returns an owned, unlinked file kept open across exec. Close on exec failure.
pub fn publish(alloc: Allocator, loaded: *session_log.LoadedWritableSession, continue_turn: bool, reason: Reason) !std.Io.File {
    if (comptime host_target.is_wasm) return error.UpgradeHandoffUnavailable;
    const current = try boundary(loaded);
    if (continue_turn != (current.turn_id != 0)) return error.InvalidUpgradeHandoff;
    var nonce: [32]u8 = undefined;
    try io_mod.getIo().randomSecure(&nonce);
    const hex = std.fmt.bytesToHex(nonce, .lower);
    const name = try std.fmt.allocPrint(alloc, ".upgrade-capability-{s}", .{hex});
    defer alloc.free(name);
    const file = try loaded.log.dir.dir.createFile(io_mod.getIo(), name, .{
        .read = true,
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    errdefer file.close(io_mod.getIo());
    try loaded.log.dir.dir.deleteFile(io_mod.getIo(), name);
    try file.writeStreamingAll(io_mod.getIo(), &nonce);
    const record: Record = .{
        .reason = reason,
        .boundary = current,
        .continue_turn = continue_turn,
        .process_id = std.c.getpid(),
        .capability_fd = file.handle,
        .capability_sha256 = digest(&nonce),
    };
    const bytes = try std.json.Stringify.valueAlloc(alloc, record, .{});
    defer alloc.free(bytes);
    try replaceMarker(alloc, loaded, bytes, .{});
    if (std.c.fcntl(file.handle, std.c.F.SETFD, @as(c_int, 0)) != 0)
        return error.UpgradeHandoffUnavailable;
    return file;
}

fn inheritedCapability(record: Record) !std.Io.File {
    if (comptime host_target.is_wasm) return error.UpgradeHandoffUnavailable;
    if (record.process_id != std.c.getpid() or record.capability_fd < 3 or
        std.c.fcntl(record.capability_fd, std.c.F.GETFD) < 0) return error.UpgradeHandoffUnavailable;
    const file: std.Io.File = .{ .handle = record.capability_fd, .flags = .{ .nonblocking = false } };
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 0 or stat.size != 32) return error.UpgradeHandoffUnavailable;
    var bytes: [33]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &bytes);
    const nonce = try reader.interface.take(32);
    if (!std.crypto.timing_safe.eql([32]u8, digest(nonce), record.capability_sha256)) return error.UpgradeHandoffUnavailable;
    return file;
}

/// Ordinary reopen invalidates an unused marker without acquiring continuation.
/// A planned exec consumes its marker before any model or tool can be admitted.
pub fn consume(alloc: Allocator, loaded: *session_log.LoadedWritableSession, planned: bool, workspace: []const u8) !?Consumption {
    try loaded.requireWritable();
    var file = io_mod.openExistingRegularFile(loaded.log.dir.dir, file_name, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, 16 * 1024);
    defer alloc.free(bytes);
    if (std.mem.eql(u8, bytes, "{}\n")) return null;
    if (!planned) {
        try replaceMarker(alloc, loaded, "{}\n", .{});
        return null;
    }
    const parsed = try std.json.parseFromSlice(Record, alloc, bytes, .{});
    defer parsed.deinit();
    const record = parsed.value;
    if (record.version != schema_version) return error.InvalidUpgradeHandoff;
    const capability = try inheritedCapability(record);
    defer capability.close(io_mod.getIo());
    try replaceMarker(alloc, loaded, "{}\n", .{});
    if (!std.meta.eql(digest(workspace), record.boundary.workspace_hash)) return error.InvalidUpgradeHandoff;
    try validate(record, try boundary(loaded));
    return .{ .reason = record.reason, .continuation = if (record.continue_turn) record.boundary else null };
}

test "journal witness handoff binds the exact session workspace position and continuation" {
    var records: journal.State = .{};
    defer records.deinit(std.testing.allocator);
    const current = try boundaryFor(&records, "session", "/workspace");
    var record: Record = .{ .reason = .restart, .boundary = current, .continue_turn = false, .process_id = 1, .capability_fd = 3, .capability_sha256 = @splat(0) };
    try validate(record, current);
    try std.testing.expectError(error.InvalidUpgradeHandoff, validate(record, try boundaryFor(&records, "other", "/workspace")));
    try std.testing.expectError(error.InvalidUpgradeHandoff, validate(record, try boundaryFor(&records, "session", "/other")));
    record.boundary.seq += 1;
    try std.testing.expectError(error.InvalidUpgradeHandoff, validate(record, current));
    record.boundary = current;
    record.boundary.hash[0] ^= 1;
    try std.testing.expectError(error.InvalidUpgradeHandoff, validate(record, current));
    record.boundary = current;
    record.version -= 1;
    try std.testing.expectError(error.InvalidUpgradeHandoff, validate(record, current));
    record.version = schema_version;
    record.continue_turn = true;
    try std.testing.expectError(error.InvalidUpgradeHandoff, validate(record, current));
    records.block();
    try std.testing.expectError(error.PersistenceUncertain, boundaryFor(&records, "session", "/workspace"));
}

test "journal witness handoff refuses outstanding providers and unsettled tools" {
    const alloc = std.testing.allocator;
    var records: journal.State = .{};
    defer records.deinit(alloc);
    var runtime: journal_runtime.Runtime = .{
        .alloc = alloc,
        .state = &records,
        .namespace = "session",
        .creation_id = "created",
        .request_id = "request",
        .sink = .{ .context = &records, .append_fn = struct {
            fn append(_: *anyopaque, _: journal.Entry) !void {}
        }.append },
    };
    const input = @import("../shared/types.zig").UserTurn{ .text = @constCast("task") };
    _ = try runtime.begin(input, "model", 7, false);
    try std.testing.expectEqual(@as(u64, 7), (try boundaryFor(&records, "session", "/workspace")).turn_id);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    var context: std.Io.Writer.Allocating = .init(alloc);
    defer context.deinit();
    try context.writer.writeAll("{\"recovery\":");
    try @import("session_codec.zig").writeRecoveryCheckpoint(&context.writer, .{
        .turn_id = 7,
        .user = input,
        .assistant_source = @constCast(""),
        .cause = .suspended,
        .action = .paused,
        .authority = .{ .provider = .gateway, .model = @constCast("model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = 0,
        .outstanding_reservation = true,
    });
    try context.writer.writeAll(",\"preparations\":[]}");
    try runtime.reserveRequest(key, context.written());
    try std.testing.expectError(error.UpgradeRequestUnsettled, boundaryFor(&records, "session", "/workspace"));
    const step = try runtime.recordDecision(.{}, &.{.{ .id = "read", .name = "read", .arguments_json = "{}" }}, &.{.blocked}, key, false, null, null);
    try std.testing.expectError(error.UpgradeNeedsToolIntervention, boundaryFor(&records, "session", "/workspace"));
    try runtime.recordResult(step, 0, .{
        .tool_call_id = @constCast("read"),
        .tool_name = @constCast("read"),
        .status = .success,
        .output = @constCast("saved"),
        .output_bytes = 5,
        .stored_output_bytes = 5,
    });
    try std.testing.expectEqual(@as(u64, 7), (try boundaryFor(&records, "session", "/workspace")).turn_id);
    if (try runtime.abandon()) |history| @import("../shared/types.zig").freeHistoryTurn(alloc, history);
    const settled = try boundaryFor(&records, "session", "/workspace");
    var checkpoint = try records.checkpoint(alloc, runtime.sink);
    defer checkpoint.deinit(alloc);
    const after = try boundaryFor(&records, "session", "/workspace");
    try std.testing.expectEqual(settled.turn_id, after.turn_id);
    try std.testing.expect(after.seq > settled.seq);
    try std.testing.expect(!std.meta.eql(settled, after));
}

test "journal witness uncertain handoff consumption fences further session writes" {
    const alloc = std.testing.allocator;
    const Fault = struct {
        fn file(_: ?*anyopaque, _: std.Io.File) !void {
            return error.InjectedSyncFailure;
        }
        fn dir(_: ?*anyopaque, _: std.Io.Dir) !void {
            return error.InjectedSyncFailure;
        }
    };
    for ([_]bool{ false, true }) |after_rename| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(path);
        var store = try @import("session_store.zig").Store.initFromHome(alloc, path, path);
        defer store.deinit(alloc);
        var loaded = try store.startJournalSession(alloc, .{
            .id = @constCast("handoff-test"),
            .origin_workspace_root = path,
            .workspace_root = path,
            .created_at_ms = 1,
            .updated_at_ms = 1,
            .conversation_language = .literal("und"),
            .preferences = .{ .model = @constCast("model"), .effort = .auto, .fast_mode = false },
            .history = &.{},
            .total_input_tokens = 0,
            .total_output_tokens = 0,
        }, .{});
        defer loaded.deinit(alloc);
        try replaceMarker(alloc, &loaded, "original", .{});
        const position = loaded.position;
        try std.testing.expectError(
            if (after_rename) error.SessionPersistenceUncertain else error.DurableReplacePreRenameFailed,
            replaceMarker(alloc, &loaded, "{}\n", if (after_rename) .{ .sync_dir = Fault.dir } else .{ .sync_file = Fault.file }),
        );
        try std.testing.expectEqual(position, loaded.position);
        if (after_rename) {
            try std.testing.expectError(error.SessionCommitFailed, loaded.requireWritable());
            try std.testing.expectError(error.SessionCommitFailed, boundary(&loaded));
        } else try loaded.requireWritable();
        var file = try io_mod.openExistingRegularFile(loaded.log.dir.dir, file_name, .read_only);
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(alloc, &file, 64);
        defer alloc.free(bytes);
        try std.testing.expectEqualStrings(if (after_rename) "{}\n" else "original", bytes);
    }
}
