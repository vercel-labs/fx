//! The one-time cleanup of an old session's log: the front door. `prune`
//! replaces superseded legacy usage and snapshot lines, keeps every seq, and
//! keeps the original as `pruned/log.jsonl` until the user discards it. A
//! later run keeps that first original rather than replacing it. `restore`
//! puts the original back as the log, with every turn written after it.
//!
//! The protocol, under the session's writer lock:
//!   1. stage: write `log.jsonl.pruning`, fsync it, and run the replay check;
//!   2. link: hard-link `log.jsonl` to `pruned/log.jsonl` (the original survives);
//!   3. commit: rename the staged file over `log.jsonl`.
//! A crash before (3) leaves the original in place; a crash after (3) leaves
//! the finished log. Either way the next run finishes or starts over.

const std = @import("std");
const format = @import("prune_format.zig");
const scan = @import("prune_scan.zig");
const rewrite = @import("prune_rewrite.zig");
const replay = @import("prune_replay.zig");
const log_mod = @import("log.zig");
const fold = @import("fold.zig");
const storage = @import("storage.zig");
const fixture = @import("prune_fixture.zig");

pub const Error = format.Error;

pub const kept_dir_name = format.kept_dir_name;
pub const log_name = format.log_name;

pub const Options = struct {
    /// Count and report; change nothing.
    dry_run: bool = false,
};

pub const Outcome = enum { no_op, dry_run, pruned };

pub const Report = struct {
    outcome: Outcome,
    lines: u64,
    bytes_before: u64,
    /// Exact after `pruned`; the placeholder and removal arithmetic for `dry_run`.
    bytes_after: u64,
    usage_superseded: u64,
    snapshots_superseded: u64,
    bytes_removed: u64,
    placeholder_bytes: u64,
    /// True when a finished cleanup's original was already kept. That original
    /// is the user's true original, so this run keeps it and links nothing.
    original_kept: bool,
};

/// Writes the cleaned log into `dst`. `rewrite.write` is the real one; a test
/// passes a planted one to prove the replay check refuses it.
const WriteFn = *const fn (std.mem.Allocator, storage.Storage, storage.File, *const scan.Plan, storage.File) format.Error!void;

/// A step after staging: linking the original, or committing the staged file.
const StepFn = *const fn (storage.Storage, storage.Dir) Error!void;

/// The steps a cleanup runs. The real ones are the defaults; a test passes a
/// failing or planted one to prove the protocol holds.
const Seams = struct {
    write: WriteFn = rewrite.write,
    link: StepFn = linkOriginal,
    commit: StepFn = commit,
};

pub fn prune(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir, options: Options) Error!Report {
    return pruneWith(gpa, s, dir, options, .{});
}

fn pruneWith(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir, options: Options, seams: Seams) Error!Report {
    const lock = try acquire(s, dir);
    defer release(s, lock);
    const log = try format.openLog(s, dir, format.log_name);
    defer s.closeFile(log.file);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const plan = try scan.run(gpa, arena.allocator(), s, log.file, log.end);

    const kept_before = try finished(gpa, s, dir, log);
    if (!plan.any()) return reportOf(.no_op, &plan, log.len, log.len, kept_before);
    if (options.dry_run) {
        const predicted = log.len - plan.bytes_removed + plan.placeholder_bytes;
        return reportOf(.dry_run, &plan, log.len, predicted, kept_before);
    }
    try removeLeftovers(gpa, s, dir, log);
    const written = try stage(gpa, s, dir, log.file, &plan, seams.write);
    publish(s, dir, kept_before, seams) catch |err| {
        discardStaged(s, dir);
        return err;
    };
    return reportOf(.pruned, &plan, log.len, written, kept_before);
}

fn reportOf(outcome: Outcome, plan: *const scan.Plan, bytes_before: u64, bytes_after: u64, original_kept: bool) Report {
    return .{
        .outcome = outcome,
        .lines = plan.lines.len,
        .bytes_before = bytes_before,
        .bytes_after = bytes_after,
        .usage_superseded = plan.usage_superseded,
        .snapshots_superseded = plan.snapshots_superseded,
        .bytes_removed = plan.bytes_removed,
        .placeholder_bytes = plan.placeholder_bytes,
        .original_kept = original_kept,
    };
}

/// Writes the restored log into `dst`, from the first original and the
/// current log.
const RestoreWriteFn = *const fn (std.mem.Allocator, storage.Storage, storage.File, u64, storage.File, u64, storage.File) format.Error!void;

const RestoreSeams = struct {
    write: RestoreWriteFn = rewrite.restoreWrite,
    commit: StepFn = commit,
};

/// The sizes of the log a restore replaced and the one it wrote.
pub const RestoreReport = struct {
    bytes_before: u64,
    bytes_after: u64,
};

/// Puts the kept original back as the log, with every turn written since the
/// cleanup. Refused unless a finished cleanup is there.
pub fn restore(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir) Error!RestoreReport {
    return restoreWith(gpa, s, dir, .{});
}

/// Puts the first original back as the log, with every turn written after the
/// cleanup. The restored log is staged, proved by the replay check against the
/// current log, and renamed over it. The kept folder goes last. A crash before
/// the rename leaves the current log; after it, the restored one.
fn restoreWith(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir, seams: RestoreSeams) Error!RestoreReport {
    const lock = try acquire(s, dir);
    defer release(s, lock);
    const log = try format.openLog(s, dir, format.log_name);
    defer s.closeFile(log.file);
    if (!try finished(gpa, s, dir, log)) return error.NotPruned;

    const kept = try s.openDir(dir, format.kept_dir_name);
    defer s.closeDir(kept);
    const original = try format.openLog(s, kept, format.log_name);
    defer s.closeFile(original.file);

    try removeStaged(s, dir);
    const staged = try s.createFile(dir, format.pruning_name);
    defer s.closeFile(staged);
    errdefer discardStaged(s, dir);
    try seams.write(gpa, s, original.file, original.end, log.file, log.end, staged);
    try s.sync(staged);
    const written = try s.length(staged);
    try replay.checkRestore(gpa, s, log.file, log.end, staged, written);
    try seams.commit(s, dir);
    try s.deleteTree(dir, format.kept_dir_name);
    try s.syncDir(dir);
    return .{ .bytes_before = log.len, .bytes_after = written };
}

/// Deletes the kept original and nothing else. Refused unless a finished
/// cleanup is there.
/// Returns the bytes the deleted original held.
pub fn discard(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir) Error!u64 {
    const lock = try acquire(s, dir);
    defer release(s, lock);
    const log = try format.openLog(s, dir, format.log_name);
    defer s.closeFile(log.file);
    if (!try finished(gpa, s, dir, log)) return error.NotPruned;

    const kept = try s.openDir(dir, format.kept_dir_name);
    defer s.closeDir(kept);
    const original = try format.openLog(s, kept, format.log_name);
    defer s.closeFile(original.file);
    const freed = original.len;
    try s.deleteTree(dir, format.kept_dir_name);
    try s.syncDir(dir);
    return freed;
}

/// What a cleanup left in a session's folder, read without the writer lock.
pub const Status = struct {
    /// A cleanup finished: the kept original exists and the log holds its placeholders.
    finished: bool,
    /// The kept original's size; 0 unless `finished`.
    kept_bytes: u64,
};

pub fn status(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir) Error!Status {
    const log = try format.openLog(s, dir, format.log_name);
    defer s.closeFile(log.file);
    if (!try finished(gpa, s, dir, log)) return .{ .finished = false, .kept_bytes = 0 };

    const kept = try s.openDir(dir, format.kept_dir_name);
    defer s.closeDir(kept);
    const original = try format.openLog(s, kept, format.log_name);
    defer s.closeFile(original.file);
    return .{ .finished = true, .kept_bytes = original.len };
}

/// The writer lock: a second writer, or a session open elsewhere, refuses.
fn acquire(s: storage.Storage, dir: storage.Dir) Error!storage.File {
    const lock = try s.openFile(dir, format.lock_name, .read_write);
    errdefer s.closeFile(lock);
    if (!try s.tryLock(lock)) return error.Busy;
    return lock;
}

fn release(s: storage.Storage, lock: storage.File) void {
    s.unlock(lock);
    s.closeFile(lock);
}

/// A cleanup is finished when the kept original exists and the log holds the
/// placeholders the rename put there.
fn finished(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir, log: format.OpenedLog) Error!bool {
    if (!keptExists(s, dir)) return false;
    return scan.hasPlaceholder(gpa, s, log.file, log.end);
}

/// The kept original is `pruned/log.jsonl` itself. A folder without it, left by
/// a crash inside a delete or by a person, holds no original.
fn keptExists(s: storage.Storage, dir: storage.Dir) bool {
    const kept = s.openDir(dir, format.kept_dir_name) catch return false;
    defer s.closeDir(kept);
    _ = s.stat(kept, format.log_name) catch return false;
    return true;
}

fn keptFolderExists(s: storage.Storage, dir: storage.Dir) bool {
    _ = s.stat(dir, format.kept_dir_name) catch return false;
    return true;
}

/// Removes a staged file that a run left behind when it stopped. A missing
/// one is fine.
fn removeStaged(s: storage.Storage, dir: storage.Dir) Error!void {
    s.deleteFile(dir, format.pruning_name) catch |err| switch (err) {
        error.NotFound => {},
        else => |io_err| return io_err,
    };
}

/// Removes what a stopped run left behind: a staged file, a kept link to a log
/// that was never replaced, and a kept folder without its log. A finished
/// cleanup's kept original is left alone.
fn removeLeftovers(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir, log: format.OpenedLog) Error!void {
    try removeStaged(s, dir);
    if (keptExists(s, dir)) {
        if (try scan.hasPlaceholder(gpa, s, log.file, log.end)) return;
    } else if (!keptFolderExists(s, dir)) return;
    try s.deleteTree(dir, format.kept_dir_name);
}

/// Writes the cleaned log to the staged file, makes it durable, and checks it
/// against the original. Returns its size. A failed stage removes the staged
/// file, and the original is untouched.
fn stage(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir, original: storage.File, plan: *const scan.Plan, write: WriteFn) Error!u64 {
    const staged = try s.createFile(dir, format.pruning_name);
    defer s.closeFile(staged);
    errdefer discardStaged(s, dir);
    try write(gpa, s, original, plan, staged);
    try s.sync(staged);
    const written = try s.length(staged);
    try replay.check(gpa, s, original, plan.end, staged, written);
    return written;
}

fn discardStaged(s: storage.Storage, dir: storage.Dir) void {
    // The original is intact. A staged file that stays is removed by the next
    // run, so a failed delete here loses nothing.
    s.deleteFile(dir, format.pruning_name) catch {};
}

/// Hard-links the original to `pruned/log.jsonl`. The original's inode now
/// has two names, so the rename below cannot lose it.
fn linkOriginal(s: storage.Storage, dir: storage.Dir) Error!void {
    const kept = try s.ensureDir(dir, format.kept_dir_name);
    defer s.closeDir(kept);
    try s.link(dir, format.log_name, kept, format.log_name);
    try s.syncDir(kept);
    try s.syncDir(dir);
}

fn commit(s: storage.Storage, dir: storage.Dir) Error!void {
    try s.rename(dir, format.pruning_name, dir, format.log_name);
    try s.syncDir(dir);
}

/// Keeps the original and swaps the staged log in. A finished cleanup already
/// kept the user's true original, so a second cleanup links nothing.
fn publish(s: storage.Storage, dir: storage.Dir, original_kept: bool, seams: Seams) Error!void {
    if (!original_kept) try seams.link(s, dir);
    try seams.commit(s, dir);
}

const Helpers = struct {
    const session = @import("session.zig");

    fn exists(s: storage.Storage, dir: storage.Dir, name: []const u8) bool {
        _ = s.stat(dir, name) catch return false;
        return true;
    }

    fn keptExists(s: storage.Storage, dir: storage.Dir) bool {
        return exists(s, dir, format.kept_dir_name);
    }

    fn lineCount(gpa: std.mem.Allocator, bytes: []const u8) !usize {
        const lines = try fixture.splitLines(gpa, bytes);
        defer gpa.free(lines);
        return lines.len;
    }

    fn foldLog(gpa: std.mem.Allocator, s: storage.Storage, dir: storage.Dir) !fold.State {
        const log = try format.openLog(s, dir, format.log_name);
        defer s.closeFile(log.file);
        return replay.foldOf(gpa, s, log.file, log.end);
    }

    fn expectVerifies(gpa: std.mem.Allocator, scratch: *fixture.Scratch) !void {
        const env: session.Env = .{ .gpa = gpa, .s = scratch.s, .root = scratch.root };
        const verified = try session.verifySession(&env, "s", .{});
        try std.testing.expectEqual(@as(?u64, null), verified.damaged_at);
        try std.testing.expectEqual(@as(u64, 0), verified.bad_snapshots);
    }

    /// Every line of `before` from index `from` that is not a snapshot is still
    /// there, byte for byte, at the same index of `after`.
    fn expectTurnsKept(gpa: std.mem.Allocator, before: []const u8, after: []const u8, from: usize) !void {
        const before_lines = try fixture.splitLines(gpa, before);
        defer gpa.free(before_lines);
        const after_lines = try fixture.splitLines(gpa, after);
        defer gpa.free(after_lines);
        try std.testing.expectEqual(before_lines.len, after_lines.len);
        for (before_lines[from..], from..) |line, i| {
            if ((try log_mod.checkLine(line)).kind == .snapshot) continue;
            try std.testing.expectEqualSlices(u8, line, after_lines[i]);
        }
    }

    /// A log with two superseded legacy usage lines and two snapshots: the
    /// first snapshot is superseded, the second stays.
    fn sampleLog(b: *fixture.Builder) !void {
        try b.created("s");
        try b.turn(1);
        try b.legacyUsage();
        try b.snapshot();
        try b.turn(2);
        try b.legacyUsage();
        try b.snapshot();
        try b.turn(3);
        try b.usage(3);
    }

    /// Writes a placeholder for every line: the planted rewrite.
    fn plantedAllPlaceholders(gpa: std.mem.Allocator, s: storage.Storage, src: storage.File, plan: *const scan.Plan, dst: storage.File) Error!void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var reader = log_mod.ForwardReader.init(gpa, s, src, 0, plan.end, 1);
        defer reader.deinit();
        while (true) {
            const line = (reader.next() catch return error.Damaged) orelse break;
            try format.appendPlaceholder(gpa, &out, line.header.seq, line.header.ts_ms);
        }
        try s.writeAt(dst, out.items, 0);
        try s.sync(dst);
    }

    /// A step that fails before it changes anything: a link or a commit that
    /// the OS refuses.
    fn failingStep(s: storage.Storage, dir: storage.Dir) Error!void {
        _ = s;
        _ = dir;
        return error.Io;
    }

    /// A restore that writes the first original and drops every turn after it.
    fn plantedDropTail(gpa: std.mem.Allocator, s: storage.Storage, original: storage.File, original_end: u64, current: storage.File, current_end: u64, dst: storage.File) Error!void {
        _ = current;
        _ = current_end;
        const bytes = try gpa.alloc(u8, original_end);
        defer gpa.free(bytes);
        var got: usize = 0;
        while (got < bytes.len) {
            const n = try s.readAt(original, bytes[got..], got);
            if (n == 0) break;
            got += n;
        }
        try s.writeAt(dst, bytes[0..got], 0);
        try s.sync(dst);
    }

    fn logBytes(gpa: std.mem.Allocator, dir: storage.Dir) ![]u8 {
        return fixture.readBytes(gpa, dir, format.log_name);
    }
};

test "the cleanup replaces superseded lines, keeps every seq, and the session verifies" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);

    const report = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.pruned, report.outcome);
    try std.testing.expectEqual(@as(u64, 2), report.usage_superseded);
    try std.testing.expectEqual(@as(u64, 1), report.snapshots_superseded);
    try std.testing.expectEqual(@as(u64, 15), report.lines);

    const before = try fixture.splitLines(gpa, b.bytes.items);
    defer gpa.free(before);
    const after_bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(after_bytes);
    const after = try fixture.splitLines(gpa, after_bytes);
    defer gpa.free(after);
    try std.testing.expectEqual(before.len, after.len);
    try std.testing.expectEqualSlices(u8, before[14], after[14]);

    const env: Helpers.session.Env = .{ .gpa = gpa, .s = scratch.s, .root = scratch.root };
    const verified = try Helpers.session.verifySession(&env, "s", .{});
    try std.testing.expectEqual(@as(?u64, null), verified.damaged_at);
    try std.testing.expectEqual(@as(u64, 0), verified.bad_snapshots);
    try std.testing.expectEqual(@as(u64, 15), verified.lines);
}

test "a second cleanup keeps the first original, commits the new log, and leaves no staged file" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.legacyUsage();
    try b.legacyUsage();
    try b.turn(1);
    try b.snapshot();
    try b.turn(2);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    const first_original = try gpa.dupe(u8, b.bytes.items);
    defer gpa.free(first_original);

    const first = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.pruned, first.outcome);
    try std.testing.expect(!first.original_kept);

    // fx keeps writing after a cleanup: a turn and a newer snapshot, so the
    // second run has a superseded snapshot of its own to remove.
    const tail_start = b.bytes.items.len;
    try b.turn(3);
    try b.snapshot();
    try fixture.appendRaw(scratch.s, dir, format.log_name, b.bytes.items[tail_start..]);

    const second = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.pruned, second.outcome);
    try std.testing.expectEqual(@as(u64, 1), second.snapshots_superseded);
    try std.testing.expect(second.original_kept);

    const kept = try scratch.s.openDir(dir, format.kept_dir_name);
    defer scratch.s.closeDir(kept);
    const kept_bytes = try Helpers.logBytes(gpa, kept);
    defer gpa.free(kept_bytes);
    try std.testing.expectEqualSlices(u8, first_original, kept_bytes);
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));

    const env: Helpers.session.Env = .{ .gpa = gpa, .s = scratch.s, .root = scratch.root };
    const verified = try Helpers.session.verifySession(&env, "s", .{});
    try std.testing.expectEqual(@as(?u64, null), verified.damaged_at);
    try std.testing.expectEqual(@as(u64, 0), verified.bad_snapshots);
}

test "a log with nothing superseded is left unchanged and nothing is staged" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.turn(1);
    try b.usage(3);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);

    const report = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.no_op, report.outcome);
    const bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, b.bytes.items, bytes);
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));
}

test "a dry run counts what the cleanup would do and changes nothing" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);

    const report = try prune(gpa, scratch.s, dir, .{ .dry_run = true });
    try std.testing.expectEqual(Outcome.dry_run, report.outcome);
    try std.testing.expectEqual(@as(u64, 2), report.usage_superseded);
    try std.testing.expectEqual(@as(u64, 1), report.snapshots_superseded);
    try std.testing.expect(report.bytes_after < report.bytes_before);
    const bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, b.bytes.items, bytes);
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));
}

test "a busy session is refused and its log is not touched" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);

    const writer = try scratch.s.openFile(dir, format.lock_name, .read_write);
    defer scratch.s.closeFile(writer);
    try std.testing.expect(try scratch.s.tryLock(writer));
    defer scratch.s.unlock(writer);

    try std.testing.expectError(error.Busy, prune(gpa, scratch.s, dir, .{}));
    const bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, b.bytes.items, bytes);
}

test "a rewrite the replay check rejects leaves the log and the folder as they were" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);

    try std.testing.expectError(error.ReplayMismatch, pruneWith(gpa, scratch.s, dir, .{}, .{ .write = Helpers.plantedAllPlaceholders }));
    const bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, b.bytes.items, bytes);
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));
}

test "a crash after staging leaves the original, and the next run finishes the cleanup" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try scan.run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);

    _ = try stage(gpa, scratch.s, dir, log.file, &plan, rewrite.write);
    try std.testing.expect(Helpers.exists(scratch.s, dir, format.pruning_name));
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));

    const report = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.pruned, report.outcome);
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));
    const completed = try fixture.openLog(scratch.s, dir, format.log_name);
    defer scratch.s.closeFile(completed.file);
    try std.testing.expect(try scan.hasPlaceholder(gpa, scratch.s, completed.file, completed.end));
}

test "a crash after the link keeps the original as the log, and restore refuses until the cleanup finishes" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try scan.run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);

    _ = try stage(gpa, scratch.s, dir, log.file, &plan, rewrite.write);
    try linkOriginal(scratch.s, dir);
    try std.testing.expect(Helpers.keptExists(scratch.s, dir));
    const bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, b.bytes.items, bytes);
    try std.testing.expectError(error.NotPruned, restore(gpa, scratch.s, dir));

    const report = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.pruned, report.outcome);
    const kept = try fixture.readBytes(gpa, dir, format.kept_dir_name ++ "/" ++ format.log_name);
    defer gpa.free(kept);
    try std.testing.expectEqualSlices(u8, b.bytes.items, kept);
}

test "a crash after the commit leaves the finished log, and a rerun changes nothing" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try scan.run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);

    _ = try stage(gpa, scratch.s, dir, log.file, &plan, rewrite.write);
    try linkOriginal(scratch.s, dir);
    try commit(scratch.s, dir);
    const completed_bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(completed_bytes);

    const report = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.no_op, report.outcome);
    const again = try Helpers.logBytes(gpa, dir);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, completed_bytes, again);
}

test "a failure at link removes the staged file and leaves the log as it was" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);

    try std.testing.expectError(error.Io, pruneWith(gpa, scratch.s, dir, .{}, .{ .link = Helpers.failingStep }));
    const bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, b.bytes.items, bytes);
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));
}

test "a failure at commit removes the staged file, and the next run finishes the cleanup" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    const original = try gpa.dupe(u8, b.bytes.items);
    defer gpa.free(original);

    try std.testing.expectError(error.Io, pruneWith(gpa, scratch.s, dir, .{}, .{ .commit = Helpers.failingStep }));
    const bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, original, bytes);
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));

    const report = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.pruned, report.outcome);
    try std.testing.expect(!report.original_kept);
    const kept = try scratch.s.openDir(dir, format.kept_dir_name);
    defer scratch.s.closeDir(kept);
    const kept_bytes = try Helpers.logBytes(gpa, kept);
    defer gpa.free(kept_bytes);
    try std.testing.expectEqualSlices(u8, original, kept_bytes);
}

test "restore puts the original back and removes the kept folder" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    _ = try prune(gpa, scratch.s, dir, .{});

    _ = try restore(gpa, scratch.s, dir);
    const bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, b.bytes.items, bytes);
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));
}

test "restore after new turns keeps every turn and their snapshot, verifies, and folds equal to the log before" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    const first_original = try gpa.dupe(u8, b.bytes.items);
    defer gpa.free(first_original);
    _ = try prune(gpa, scratch.s, dir, .{});

    const tail_start = b.bytes.items.len;
    try b.turn(4);
    try b.snapshot();
    try b.turn(5);
    try fixture.appendRaw(scratch.s, dir, format.log_name, b.bytes.items[tail_start..]);

    const before = try Helpers.logBytes(gpa, dir);
    defer gpa.free(before);
    var before_fold = try Helpers.foldLog(gpa, scratch.s, dir);
    defer before_fold.deinit(gpa);

    _ = try restore(gpa, scratch.s, dir);

    const after = try Helpers.logBytes(gpa, dir);
    defer gpa.free(after);
    try std.testing.expect(std.mem.startsWith(u8, after, first_original));
    try Helpers.expectTurnsKept(gpa, before, after, try Helpers.lineCount(gpa, first_original));
    try Helpers.expectVerifies(gpa, &scratch);
    var after_fold = try Helpers.foldLog(gpa, scratch.s, dir);
    defer after_fold.deinit(gpa);
    try std.testing.expect(try replay.sameState(gpa, &before_fold, &after_fold));
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));
}

test "restore after a repeat cleanup keeps the first original and every turn after it" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    const first_original = try gpa.dupe(u8, b.bytes.items);
    defer gpa.free(first_original);
    _ = try prune(gpa, scratch.s, dir, .{});

    const tail_start = b.bytes.items.len;
    try b.turn(4);
    try b.snapshot();
    try b.turn(5);
    try fixture.appendRaw(scratch.s, dir, format.log_name, b.bytes.items[tail_start..]);
    const repeat = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expect(repeat.original_kept);

    const before = try Helpers.logBytes(gpa, dir);
    defer gpa.free(before);
    var before_fold = try Helpers.foldLog(gpa, scratch.s, dir);
    defer before_fold.deinit(gpa);

    _ = try restore(gpa, scratch.s, dir);

    const after = try Helpers.logBytes(gpa, dir);
    defer gpa.free(after);
    try std.testing.expect(std.mem.startsWith(u8, after, first_original));
    try Helpers.expectTurnsKept(gpa, before, after, try Helpers.lineCount(gpa, first_original));
    try Helpers.expectVerifies(gpa, &scratch);
    var after_fold = try Helpers.foldLog(gpa, scratch.s, dir);
    defer after_fold.deinit(gpa);
    try std.testing.expect(try replay.sameState(gpa, &before_fold, &after_fold));
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));
}

test "a tail snapshot that a repeat cleanup superseded is written again from the fold" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    const first_original = try gpa.dupe(u8, b.bytes.items);
    defer gpa.free(first_original);
    _ = try prune(gpa, scratch.s, dir, .{});

    const tail_start = b.bytes.items.len;
    try b.turn(4);
    try b.snapshot();
    try b.turn(5);
    try b.snapshot();
    try b.turn(6);
    try fixture.appendRaw(scratch.s, dir, format.log_name, b.bytes.items[tail_start..]);
    _ = try prune(gpa, scratch.s, dir, .{});

    const before = try Helpers.logBytes(gpa, dir);
    defer gpa.free(before);
    const before_lines = try fixture.splitLines(gpa, before);
    defer gpa.free(before_lines);
    const prefix = try Helpers.lineCount(gpa, first_original);
    var superseded: ?usize = null;
    for (before_lines, 0..) |line, i| {
        if (i >= prefix and format.isPlaceholder(try log_mod.checkLine(line))) superseded = i;
    }
    const at = superseded orelse return error.TestExpectedPlaceholder;
    var before_fold = try Helpers.foldLog(gpa, scratch.s, dir);
    defer before_fold.deinit(gpa);

    _ = try restore(gpa, scratch.s, dir);

    const after = try Helpers.logBytes(gpa, dir);
    defer gpa.free(after);
    const after_lines = try fixture.splitLines(gpa, after);
    defer gpa.free(after_lines);
    try std.testing.expectEqual(before_lines.len, after_lines.len);
    const again = try log_mod.checkLine(after_lines[at]);
    try std.testing.expectEqual(schema.Kind.snapshot, again.kind.?);
    try std.testing.expectEqual((try log_mod.checkLine(before_lines[at])).seq, again.seq);
    try Helpers.expectVerifies(gpa, &scratch);
    var after_fold = try Helpers.foldLog(gpa, scratch.s, dir);
    defer after_fold.deinit(gpa);
    try std.testing.expect(try replay.sameState(gpa, &before_fold, &after_fold));
}

test "a crash before the commit leaves the current log, and the next restore finishes" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    const first_original = try gpa.dupe(u8, b.bytes.items);
    defer gpa.free(first_original);
    _ = try prune(gpa, scratch.s, dir, .{});

    const tail_start = b.bytes.items.len;
    try b.turn(4);
    try fixture.appendRaw(scratch.s, dir, format.log_name, b.bytes.items[tail_start..]);
    const current = try Helpers.logBytes(gpa, dir);
    defer gpa.free(current);
    try fixture.writeRaw(scratch.s, dir, format.pruning_name, "partly written restore");

    _ = try restore(gpa, scratch.s, dir);

    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));
    const after = try Helpers.logBytes(gpa, dir);
    defer gpa.free(after);
    try std.testing.expect(std.mem.startsWith(u8, after, first_original));
    try Helpers.expectTurnsKept(gpa, current, after, try Helpers.lineCount(gpa, first_original));
}

test "a crash after the commit leaves the restored log, and the next run finishes the cleanup" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    const first_original = try gpa.dupe(u8, b.bytes.items);
    defer gpa.free(first_original);
    _ = try prune(gpa, scratch.s, dir, .{});

    const tail_start = b.bytes.items.len;
    try b.turn(4);
    var restored: std.ArrayList(u8) = .empty;
    defer restored.deinit(gpa);
    try restored.appendSlice(gpa, first_original);
    try restored.appendSlice(gpa, b.bytes.items[tail_start..]);
    try scratch.s.deleteFile(dir, format.log_name);
    try fixture.writeRaw(scratch.s, dir, format.log_name, restored.items);

    try std.testing.expectError(error.NotPruned, restore(gpa, scratch.s, dir));
    const report = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.pruned, report.outcome);
    try std.testing.expect(!report.original_kept);
    const kept = try fixture.readBytes(gpa, dir, format.kept_dir_name ++ "/" ++ format.log_name);
    defer gpa.free(kept);
    try std.testing.expectEqualSlices(u8, restored.items, kept);
}

test "a tail snapshot's compaction offset names the compacted line where it sits after the restore" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    const first_original = try gpa.dupe(u8, b.bytes.items);
    defer gpa.free(first_original);
    _ = try prune(gpa, scratch.s, dir, .{});

    const tail_start = b.bytes.items.len;
    try b.turn(4);
    try b.compacted(4);
    try b.turn(5);
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(gpa);
    try tail.appendSlice(gpa, b.bytes.items[tail_start..]);
    const stale = try fixture.snapshotLine(gpa, b.next_seq, b.next_ts, b.next_seq - 1, "{}", 1);
    defer gpa.free(stale);
    try tail.appendSlice(gpa, stale);
    try fixture.appendRaw(scratch.s, dir, format.log_name, tail.items);
    const current = try Helpers.logBytes(gpa, dir);
    defer gpa.free(current);
    var current_fold = try Helpers.foldLog(gpa, scratch.s, dir);
    defer current_fold.deinit(gpa);

    _ = try restore(gpa, scratch.s, dir);

    const after = try Helpers.logBytes(gpa, dir);
    defer gpa.free(after);
    try std.testing.expect(std.mem.startsWith(u8, after, first_original));
    try Helpers.expectTurnsKept(gpa, current, after, try Helpers.lineCount(gpa, first_original));
    try Helpers.expectVerifies(gpa, &scratch);
    var after_fold = try Helpers.foldLog(gpa, scratch.s, dir);
    defer after_fold.deinit(gpa);
    try std.testing.expect(try replay.sameState(gpa, &current_fold, &after_fold));
    try std.testing.expectEqual(current_fold.compaction_offset == null, after_fold.compaction_offset == null);
    try std.testing.expect(after_fold.compaction_offset != null);
    try std.testing.expect(after_fold.compaction_offset.? != 1);
}

test "a planted bad tail rewrite is refused by the replay check and leaves everything untouched" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    _ = try prune(gpa, scratch.s, dir, .{});
    const tail_start = b.bytes.items.len;
    try b.turn(4);
    try b.snapshot();
    try b.turn(5);
    try fixture.appendRaw(scratch.s, dir, format.log_name, b.bytes.items[tail_start..]);
    const current = try Helpers.logBytes(gpa, dir);
    defer gpa.free(current);

    try std.testing.expectError(error.ReplayMismatch, restoreWith(gpa, scratch.s, dir, .{ .write = Helpers.plantedDropTail }));
    const after = try Helpers.logBytes(gpa, dir);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, current, after);
    try std.testing.expect(Helpers.keptExists(scratch.s, dir));
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));
}

test "a failure at the rename removes the staged restore and leaves the current log" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    _ = try prune(gpa, scratch.s, dir, .{});
    const tail_start = b.bytes.items.len;
    try b.turn(4);
    try b.snapshot();
    try b.turn(5);
    try fixture.appendRaw(scratch.s, dir, format.log_name, b.bytes.items[tail_start..]);
    const current = try Helpers.logBytes(gpa, dir);
    defer gpa.free(current);

    try std.testing.expectError(error.Io, restoreWith(gpa, scratch.s, dir, .{ .commit = Helpers.failingStep }));
    const after = try Helpers.logBytes(gpa, dir);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, current, after);
    try std.testing.expect(Helpers.keptExists(scratch.s, dir));
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));
}

test "discard deletes only the kept original, and refuses before a cleanup" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);

    try std.testing.expectError(error.NotPruned, discard(gpa, scratch.s, dir));
    _ = try prune(gpa, scratch.s, dir, .{});
    const completed_bytes = try Helpers.logBytes(gpa, dir);
    defer gpa.free(completed_bytes);

    _ = try discard(gpa, scratch.s, dir);
    try std.testing.expect(!Helpers.keptExists(scratch.s, dir));
    const after = try Helpers.logBytes(gpa, dir);
    defer gpa.free(after);
    try std.testing.expectEqualSlices(u8, completed_bytes, after);
}

test "a kept folder without its log is no finished cleanup, and the next cleanup replaces it" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try Helpers.sampleLog(&b);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    try b.writeTo(scratch.s, dir, format.log_name);
    _ = try prune(gpa, scratch.s, dir, .{});

    // A crash inside the discard's delete, or a person who deletes the kept
    // original by hand, leaves the folder without its log.
    {
        const kept = try scratch.s.openDir(dir, format.kept_dir_name);
        defer scratch.s.closeDir(kept);
        try scratch.s.deleteFile(kept, format.log_name);
    }

    const left = try status(gpa, scratch.s, dir);
    try std.testing.expect(!left.finished);
    try std.testing.expectEqual(@as(u64, 0), left.kept_bytes);
    try std.testing.expectError(error.NotPruned, discard(gpa, scratch.s, dir));
    try std.testing.expectError(error.NotPruned, restore(gpa, scratch.s, dir));

    const tail_start = b.bytes.items.len;
    try b.turn(4);
    try b.snapshot();
    try fixture.appendRaw(scratch.s, dir, format.log_name, b.bytes.items[tail_start..]);
    const before = try Helpers.logBytes(gpa, dir);
    defer gpa.free(before);

    const again = try prune(gpa, scratch.s, dir, .{});
    try std.testing.expectEqual(Outcome.pruned, again.outcome);
    try std.testing.expect(!again.original_kept);
    const kept = try scratch.s.openDir(dir, format.kept_dir_name);
    defer scratch.s.closeDir(kept);
    const kept_bytes = try Helpers.logBytes(gpa, kept);
    defer gpa.free(kept_bytes);
    try std.testing.expectEqualSlices(u8, before, kept_bytes);
    try std.testing.expect((try status(gpa, scratch.s, dir)).finished);
    try std.testing.expect(!Helpers.exists(scratch.s, dir, format.pruning_name));
}

const schema = @import("schema.zig");

test {
    _ = format;
    _ = scan;
    _ = rewrite;
    _ = replay;
}
