//! Test-only fault injection for L0, compiled only with `-Dhooks=true`.
//!
//! It models what the kernel and the disk may do when things go wrong:
//! - an injected short or failed write, and a failed sync;
//! - a process crash (`kill`): every byte already written stays in the
//!   kernel, and the dead process does nothing more;
//! - a machine crash (`powerLoss`): each written file keeps at least its
//!   synced length plus any prefix of the rest, sometimes followed by zero
//!   bytes, and each name created or renamed since its folder's last sync may
//!   be undone.
//!
//! This is the guarantee a plain `fsync` gives on an OS crash, or a power cut
//! on Linux (D3). `restart` revives the process after a `kill`; `reboot`
//! brings the machine back after a `powerLoss`.

const std = @import("std");
const Io = std.Io;
const storage = @import("storage.zig");

pub const Fault = struct {
    gpa: std.mem.Allocator,
    io: Io,
    prng: std.Random.DefaultPrng,
    /// The simulated process is dead: every storage call fails untouched.
    dead: bool = false,
    /// One-shot plan for the next write.
    next_write: ?WritePlan = null,
    /// One-shot: the next sync fails, so durability is unknown.
    fail_next_sync: bool = false,
    /// What a planned write failure or a failed sync reports: `Io` unless
    /// a test names an OS cause (D29).
    fail_error: storage.Error = error.Io,
    /// Written files, keyed by inode, each with a private duplicate handle so
    /// a power loss can cut it after its owner has closed or renamed it.
    files: std.ArrayList(Tracked) = .empty,
    /// Names created or renamed and not yet covered by a folder sync.
    ops: std.ArrayList(NameOp) = .empty,
    /// Descriptors that wrote since they were opened.
    writers: std.ArrayList(std.posix.fd_t) = .empty,
    /// Mutating storage calls made so far (writes, syncs, creates, renames,
    /// links, cuts, deletes).
    steps: u64 = 0,
    /// A real `kill -9`: the process sends itself SIGKILL just before this
    /// mutating call (counting from 1). The driver's crash matrix sets it.
    kill_at_step: ?u64 = null,
    /// A machine crash just before this mutating call: unsynced bytes and
    /// names are dropped, and this call and every later one fail.
    power_at_step: ?u64 = null,
    /// Written files closed by their writer while holding unsynced bytes.
    /// The design closes every written file only after a sync, so tests
    /// that do not crash on purpose expect zero.
    closed_unsynced: usize = 0,

    pub const WritePlan = struct {
        /// Writes that complete normally before the plan applies.
        after_calls: usize = 0,
        /// Bytes of the planned write that reach the file before the failure.
        keep: usize,
        then: enum { fail, die },
    };

    const Tracked = struct {
        inode: Io.File.INode,
        dup: Io.File,
        synced: u64,
    };

    const NameOp = struct {
        kind: enum { create, rename },
        /// Folder whose sync makes the op durable (the new parent).
        parent: []u8,
        /// The created name, or the new name of a rename.
        path: []u8,
        /// The old name of a rename; empty for a create.
        from: []u8,
    };

    pub fn init(gpa: std.mem.Allocator, io: Io, seed: u64) Fault {
        return .{ .gpa = gpa, .io = io, .prng = .init(seed) };
    }

    pub fn deinit(f: *Fault) void {
        f.forget();
        f.files.deinit(f.gpa);
        f.ops.deinit(f.gpa);
        f.writers.deinit(f.gpa);
    }

    // -- test controls ------------------------------------------------------

    /// Process crash: the kernel keeps every written byte; nothing else runs.
    pub fn kill(f: *Fault) void {
        f.dead = true;
    }

    /// A new process starts on the same, still running machine.
    pub fn restart(f: *Fault) void {
        f.dead = false;
    }

    /// Machine crash. Returns the number of files that lost bytes.
    pub fn powerLoss(f: *Fault) usize {
        const random = f.prng.random();
        var damaged: usize = 0;
        for (f.files.items) |tracked| {
            if (cutUnsynced(f.io, random, tracked)) damaged += 1;
        }
        var i = f.ops.items.len;
        while (i > 0) {
            i -= 1;
            if (random.boolean()) undo(f.io, f.ops.items[i]);
        }
        f.dead = true;
        return damaged;
    }

    /// The machine comes back: everything on disk now counts as durable.
    pub fn reboot(f: *Fault) void {
        f.forget();
        f.dead = false;
    }

    /// Whether the first `len` bytes of `name` would survive a power loss
    /// now. A file never written since the last reboot is fully durable.
    pub fn isDurable(f: *Fault, dir: storage.Dir, name: []const u8, len: u64) bool {
        const st = dir.handle.statFile(f.io, name, .{ .follow_symlinks = false }) catch return false;
        const tracked = f.find(st.inode) orelse return st.size >= len;
        return tracked.synced >= len;
    }

    /// Whether a name inside the folder `dir` is still waiting for a folder
    /// sync (a power loss may undo it).
    pub fn isNamePending(f: *Fault, dir: storage.Dir, name: []const u8) bool {
        const parent = realPath(f.gpa, f.io, dir) catch return false;
        defer f.gpa.free(parent);
        const path = join(f.gpa, parent, name) catch return false;
        defer f.gpa.free(path);
        for (f.ops.items) |op| {
            if (std.mem.eql(u8, op.path, path)) return true;
        }
        return false;
    }

    // -- called by storage.zig ----------------------------------------------

    /// Counts one mutating call. Dies for real at `kill_at_step`; at
    /// `power_at_step` loses power and returns true: the call must fail.
    pub fn mutate(f: *Fault) bool {
        f.steps += 1;
        if (f.kill_at_step) |n| if (f.steps == n) {
            std.posix.kill(std.c.getpid(), .KILL) catch {};
        };
        if (f.power_at_step) |n| if (f.steps == n) {
            _ = f.powerLoss();
            return true;
        };
        return false;
    }

    pub fn planWrite(f: *Fault, len: usize) struct { allowed: usize, outcome: storage.WriteOutcome } {
        const plan = f.next_write orelse return .{ .allowed = len, .outcome = .complete };
        if (plan.after_calls > 0) {
            f.next_write.?.after_calls -= 1;
            return .{ .allowed = len, .outcome = .complete };
        }
        f.next_write = null;
        return .{
            .allowed = @min(plan.keep, len),
            .outcome = switch (plan.then) {
                .fail => .fail,
                .die => .die,
            },
        };
    }

    pub fn takeSyncFailure(f: *Fault) bool {
        defer f.fail_next_sync = false;
        return f.fail_next_sync;
    }

    /// Before the first write to an inode, everything already in it is
    /// durable (it survived the last reboot or was synced).
    pub fn noteBeforeWrite(f: *Fault, s: storage.Storage, file: storage.File) storage.Error!void {
        if (std.mem.findScalar(std.posix.fd_t, f.writers.items, file.handle.handle) == null) {
            f.writers.append(f.gpa, file.handle.handle) catch return error.Io;
        }
        const st = file.handle.stat(s.io) catch return error.Io;
        if (f.find(st.inode) != null) return;
        const fd = std.c.dup(file.handle.handle);
        if (fd < 0) return error.Io;
        const dup: Io.File = .{ .handle = fd, .flags = file.handle.flags };
        f.files.append(f.gpa, .{ .inode = st.inode, .dup = dup, .synced = st.size }) catch {
            dup.close(f.io);
            return error.Io;
        };
    }

    pub fn noteSync(f: *Fault, s: storage.Storage, file: storage.File) storage.Error!void {
        const st = file.handle.stat(s.io) catch return error.Io;
        if (f.find(st.inode)) |tracked| tracked.synced = st.size;
    }

    pub fn noteSetLength(f: *Fault, file: storage.File, new_length: u64) void {
        const st = file.handle.stat(f.io) catch return;
        if (f.find(st.inode)) |tracked| tracked.synced = @min(tracked.synced, new_length);
    }

    pub fn forgetWriter(f: *Fault, file: storage.File) void {
        const index = std.mem.findScalar(std.posix.fd_t, f.writers.items, file.handle.handle) orelse return;
        _ = f.writers.swapRemove(index);
    }

    pub fn noteClose(f: *Fault, s: storage.Storage, file: storage.File) void {
        const index = std.mem.findScalar(std.posix.fd_t, f.writers.items, file.handle.handle) orelse return;
        _ = f.writers.swapRemove(index);
        const st = file.handle.stat(s.io) catch return;
        if (f.find(st.inode)) |tracked| {
            if (st.size > tracked.synced) f.closed_unsynced += 1;
        }
    }

    pub fn noteCreate(f: *Fault, s: storage.Storage, dir: storage.Dir, name: []const u8) storage.Error!void {
        const parent = try realPath(f.gpa, s.io, dir);
        errdefer f.gpa.free(parent);
        const path = try join(f.gpa, parent, name);
        errdefer f.gpa.free(path);
        f.ops.append(f.gpa, .{ .kind = .create, .parent = parent, .path = path, .from = &.{} }) catch
            return error.Io;
    }

    /// Called after a successful rename.
    pub fn noteRename(
        f: *Fault,
        s: storage.Storage,
        old_dir: storage.Dir,
        old_name: []const u8,
        new_dir: storage.Dir,
        new_name: []const u8,
    ) storage.Error!void {
        const old_parent = try realPath(f.gpa, s.io, old_dir);
        defer f.gpa.free(old_parent);
        const from = try join(f.gpa, old_parent, old_name);
        errdefer f.gpa.free(from);
        const parent = try realPath(f.gpa, s.io, new_dir);
        errdefer f.gpa.free(parent);
        const path = try join(f.gpa, parent, new_name);
        errdefer f.gpa.free(path);
        f.ops.append(f.gpa, .{ .kind = .rename, .parent = parent, .path = path, .from = from }) catch
            return error.Io;
    }

    pub fn noteDirSync(f: *Fault, s: storage.Storage, dir: storage.Dir) storage.Error!void {
        const synced = try realPath(f.gpa, s.io, dir);
        defer f.gpa.free(synced);
        var i: usize = 0;
        while (i < f.ops.items.len) {
            if (std.mem.eql(u8, f.ops.items[i].parent, synced)) {
                freeOp(f.gpa, f.ops.orderedRemove(i));
            } else i += 1;
        }
    }

    // -- helpers ----------------------------------------------------------------

    fn find(f: *Fault, inode: Io.File.INode) ?*Tracked {
        for (f.files.items) |*tracked| {
            if (tracked.inode == inode) return tracked;
        }
        return null;
    }

    fn forget(f: *Fault) void {
        for (f.files.items) |tracked| tracked.dup.close(f.io);
        f.files.clearRetainingCapacity();
        for (f.ops.items) |op| freeOp(f.gpa, op);
        f.ops.clearRetainingCapacity();
    }
};

/// Cuts one file to a random length between its synced length and its
/// current length. Sometimes the cut snaps to a line end, and sometimes zero
/// bytes follow it, as on file systems that zero-fill unwritten blocks.
fn cutUnsynced(io: Io, random: std.Random, tracked: Fault.Tracked) bool {
    const len = tracked.dup.length(io) catch return false;
    if (len <= tracked.synced) return false;
    var keep = random.intRangeAtMost(u64, tracked.synced, len);
    if (random.uintLessThan(u8, 3) == 0) keep = lastLineEnd(io, tracked, keep);
    tracked.dup.setLength(io, keep) catch return false;
    if (keep < len and random.uintLessThan(u8, 4) == 0) {
        const zeros_len = random.intRangeAtMost(u64, 1, @min(len - keep, 64));
        const zeros: [64]u8 = @splat(0);
        tracked.dup.writePositionalAll(io, zeros[0..@intCast(zeros_len)], keep) catch {};
    }
    return true;
}

/// The offset just after the last newline at or before `limit`, but never
/// below the synced length.
fn lastLineEnd(io: Io, tracked: Fault.Tracked, limit: u64) u64 {
    var buffer: [4096]u8 = undefined;
    var end = limit;
    while (end > tracked.synced) {
        const start = @max(tracked.synced, end -| buffer.len);
        const len: usize = @intCast(end - start);
        const n = tracked.dup.readPositional(io, &.{buffer[0..len]}, start) catch return limit;
        if (std.mem.findScalarLast(u8, buffer[0..n], '\n')) |at| return start + at + 1;
        end = start;
    }
    return tracked.synced;
}

fn undo(io: Io, op: Fault.NameOp) void {
    const cwd = Io.Dir.cwd();
    switch (op.kind) {
        .create => cwd.deleteTree(io, op.path) catch {},
        .rename => Io.Dir.rename(cwd, op.path, cwd, op.from, io) catch {},
    }
}

fn freeOp(gpa: std.mem.Allocator, op: Fault.NameOp) void {
    gpa.free(op.parent);
    gpa.free(op.path);
    gpa.free(op.from);
}

fn realPath(gpa: std.mem.Allocator, io: Io, dir: storage.Dir) storage.Error![]u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = dir.handle.realPath(io, &buffer) catch return error.Io;
    return gpa.dupe(u8, buffer[0..n]) catch error.Io;
}

fn join(gpa: std.mem.Allocator, parent: []const u8, name: []const u8) storage.Error![]u8 {
    return std.Io.Dir.path.join(gpa, &.{ parent, name }) catch error.Io;
}

/// Silent damage: flips one bit of a file without the fault layer noticing.
/// A read-only blob (D49) is made writable for the flip and then restored.
pub fn flipBit(io: Io, dir: storage.Dir, name: []const u8, offset: u64, bit: u3) !void {
    const before = try dir.handle.statFile(io, name, .{ .follow_symlinks = false });
    const read_only = before.permissions.toMode() & 0o200 == 0;
    if (read_only) try dir.handle.setFilePermissions(io, name, .fromMode(storage.file_mode), .{ .follow_symlinks = false });
    defer if (read_only) dir.handle.setFilePermissions(io, name, before.permissions, .{ .follow_symlinks = false }) catch {};
    var file = try dir.handle.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false });
    defer file.close(io);
    var byte: [1]u8 = undefined;
    if (try file.readPositional(io, &.{&byte}, offset) != 1) return error.EndOfFile;
    byte[0] ^= @as(u8, 1) << bit;
    try file.writePositionalAll(io, &byte, offset);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "a power loss never loses a synced byte" {
    const io = testing.io;
    var seed: u64 = 0;
    while (seed < 200) : (seed += 1) {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault = Fault.init(testing.allocator, io, seed);
        defer fault.deinit();
        const s: storage.Storage = .{ .io = io, .fault = &fault };
        const root: storage.Dir = .{ .handle = tmp.dir };

        var written: std.ArrayList(u8) = .empty;
        defer written.deinit(testing.allocator);
        var synced: usize = 0;
        const file = try s.createFile(root, "log");
        // Make the name durable so only the file's bytes are at risk.
        try s.syncDir(root);
        var random = std.Random.DefaultPrng.init(seed ^ 0x5eed);
        const steps = random.random().intRangeAtMost(u8, 1, 12);
        for (0..steps) |_| {
            if (random.random().uintLessThan(u8, 3) == 0) {
                try s.sync(file);
                synced = written.items.len;
            } else {
                var line: [24]u8 = undefined;
                const text = try std.mem.print(&line, "line {d}\n", .{written.items.len});
                try s.writeAt(file, text, written.items.len);
                try written.appendSlice(testing.allocator, text);
            }
        }
        _ = fault.powerLoss();
        s.closeFile(file);
        fault.reboot();

        const after = try tmp.dir.readFileAlloc(io, "log", testing.allocator, .limited(1 << 16));
        defer testing.allocator.free(after);
        try testing.expect(after.len >= synced);
        // The kept bytes are a prefix of what was written, then maybe zeros.
        var i: usize = 0;
        while (i < after.len and i < written.items.len and after[i] == written.items[i]) i += 1;
        try testing.expect(i >= synced);
        for (after[i..]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "an injected short write keeps only the planned bytes, then fails" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fault = Fault.init(testing.allocator, testing.io, 1);
    defer fault.deinit();
    const s: storage.Storage = .{ .io = testing.io, .fault = &fault };
    const root: storage.Dir = .{ .handle = tmp.dir };
    const file = try s.createFile(root, "log");
    defer s.closeFile(file);
    fault.next_write = .{ .keep = 3, .then = .fail };
    try testing.expectError(error.Io, s.writeAt(file, "abcdef", 0));
    try testing.expectEqual(@as(u64, 3), try s.length(file));
    try s.writeAt(file, "def", 3);
    try testing.expectEqual(@as(u64, 6), try s.length(file));
}

test "a killed process does no more I/O until restart" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fault = Fault.init(testing.allocator, testing.io, 2);
    defer fault.deinit();
    const s: storage.Storage = .{ .io = testing.io, .fault = &fault };
    const root: storage.Dir = .{ .handle = tmp.dir };
    const file = try s.createFile(root, "log");
    defer s.closeFile(file);
    fault.next_write = .{ .keep = 2, .then = .die };
    try testing.expectError(error.Io, s.writeAt(file, "abcd", 0));
    try testing.expectError(error.Io, s.writeAt(file, "cd", 2));
    try testing.expectError(error.Io, s.sync(file));
    fault.restart();
    try testing.expectEqual(@as(u64, 2), try s.length(file));
}

test "a failed sync is reported and changes nothing on disk" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fault = Fault.init(testing.allocator, testing.io, 3);
    defer fault.deinit();
    const s: storage.Storage = .{ .io = testing.io, .fault = &fault };
    const root: storage.Dir = .{ .handle = tmp.dir };
    const file = try s.createFile(root, "log");
    defer s.closeFile(file);
    try s.writeAt(file, "abc\n", 0);
    fault.fail_next_sync = true;
    try testing.expectError(error.Io, s.sync(file));
    try s.sync(file);
    try testing.expectEqual(@as(u64, 4), fault.files.items[0].synced);
}

test "names are undone by a power loss only until their folder is synced" {
    const io = testing.io;
    var undone_unsynced = false;
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var fault = Fault.init(testing.allocator, io, seed);
        defer fault.deinit();
        const s: storage.Storage = .{ .io = io, .fault = &fault };
        const root: storage.Dir = .{ .handle = tmp.dir };
        const durable = try s.createFile(root, "durable");
        s.closeFile(durable);
        try s.syncDir(root);
        const fresh = try s.createFile(root, "fresh");
        s.closeFile(fresh);
        try s.rename(root, "durable", root, "moved");
        _ = fault.powerLoss();
        fault.reboot();
        // The synced create survives under one of its names; nothing else appears.
        const moved = s.stat(root, "moved") catch null;
        const original = s.stat(root, "durable") catch null;
        try testing.expect((moved == null) != (original == null));
        if ((s.stat(root, "fresh") catch null) == null) undone_unsynced = true;
    }
    try testing.expect(undone_unsynced);
}

test "a written file closed without a sync is counted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fault = Fault.init(testing.allocator, testing.io, 4);
    defer fault.deinit();
    const s: storage.Storage = .{ .io = testing.io, .fault = &fault };
    const root: storage.Dir = .{ .handle = tmp.dir };
    const synced = try s.createFile(root, "a");
    try s.writeAt(synced, "x", 0);
    try s.sync(synced);
    s.closeFile(synced);
    const unsynced = try s.createFile(root, "b");
    try s.writeAt(unsynced, "y", 0);
    s.closeFile(unsynced);
    try testing.expectEqual(@as(usize, 1), fault.closed_unsynced);
}

test "flipBit changes exactly one bit" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "AB" });
    try flipBit(io, .{ .handle = tmp.dir }, "f", 1, 0);
    const after = try tmp.dir.readFileAlloc(io, "f", testing.allocator, .limited(8));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("AC", after);
}
