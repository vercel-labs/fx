//! The kernel's output reader: the one thread that drains the Python process's
//! stdout and stderr between and during calls. It turns protocol frames into
//! request progress on the `Manager` and keeps the bounded stderr log.
//! Snapshots happen only at a turn's end, at a park and at a stop (D99), so
//! the reader takes none of its own. Lifecycle (start, stop, repair) and the
//! callers' side of each request stay in `kernel.zig`.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const protocol = @import("protocol.zig");
const kernel = @import("kernel.zig");
const Manager = kernel.Manager;
const Stream = kernel.Stream;
const now = io_mod.monotonicMilliTimestamp;
const diagnostic_cap = kernel.diagnostic_cap;
const background_cap = kernel.background_cap;
const max_log_bytes = 5 * 1024 * 1024;

/// Runs until `reader_stop` is set or the process's stdout closes.
pub fn run(self: *Manager, stdout: std.Io.File, stderr: std.Io.File) void {
    var repair_after_exit = false;
    defer if (repair_after_exit) self.scheduleRepair();
    defer {
        // Reap on EOF or corruption, not only on the next tool call. The writer lock
        // makes closing pipes and signaling the unreaped PID safe against interrupts.
        self.writer.lockUncancelable(io_mod.getIo());
        if (self.child) |*child| child.kill();
        self.writer.unlock(io_mod.getIo());
    }
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(self.alloc);
    var buffer: [64 * 1024]u8 = undefined;
    var stderr_open = true;
    while (!self.reader_stop.load(.acquire)) {
        const poll_timeout: i32 = 1000;
        var fds = [_]std.posix.pollfd{
            .{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (stderr_open) stderr.handle else -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, poll_timeout) catch {
            self.fail("Kernel pipe polling failed.");
            return;
        };
        // Drain diagnostics first: an early interpreter exit can make stdout EOF and
        // its explanatory stderr readable in the same poll.
        for ([_]usize{ 1, 0 }) |index| {
            const fd = &fds[index];
            if (fd.revents == 0) continue;
            const rc = std.c.read(fd.fd, &buffer, buffer.len);
            if (rc == 0) {
                if (index == 1) {
                    stderr_open = false;
                    continue;
                }
                if (!self.reader_stop.load(.acquire)) self.fail("Python kernel exited; the next call will start a replacement.");
                return;
            }
            if (rc < 0) continue;
            const bytes = buffer[0..@intCast(rc)];
            if (index == 1) {
                log(self, bytes);
                continue;
            }
            pending.appendSlice(self.alloc, bytes) catch {
                self.fail("Kernel output allocation failed.");
                return;
            };
            var consumed: usize = 0;
            while (std.mem.findScalarPos(u8, pending.items, consumed, '\n')) |newline| {
                if (newline - consumed > protocol.max_frame_bytes) {
                    repair_after_exit = self.status() == .running;
                    self.fail("Kernel protocol frame exceeded 32 MiB.");
                    return;
                }
                handleEvent(self, pending.items[consumed..newline]) catch {
                    repair_after_exit = self.status() == .running;
                    self.fail("Invalid kernel protocol frame; restoring a replacement in the background.");
                    return;
                };
                consumed = newline + 1;
            }
            if (consumed > 0) {
                @memmove(pending.items[0 .. pending.items.len - consumed], pending.items[consumed..]);
                pending.items.len -= consumed;
            }
            if (pending.items.len > protocol.max_frame_bytes) {
                repair_after_exit = self.status() == .running;
                self.fail("Kernel protocol frame exceeded 32 MiB.");
                return;
            }
            if (pending.items.len == 0 and pending.capacity > 256 * 1024) {
                pending.deinit(self.alloc);
                pending = .empty;
            }
        }
    }
}

fn handleEvent(self: *Manager, line: []const u8) !void {
    if (std.mem.trim(u8, line, " \r\t").len == 0) return;
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const event = try std.json.parseFromSliceLeaky(protocol.Event, arena.allocator(), line, .{ .ignore_unknown_fields = true });
    self.mutex.lockUncancelable(io_mod.getIo());
    defer self.mutex.unlock(io_mod.getIo());
    defer self.notify();
    const id = event.requestId();
    const matches = id != 0 and id == self.active_id and self.active != .none;
    switch (event.event) {
        .ready => {
            if (event.protocol != protocol.version) return error.KernelProtocolVersionMismatch;
            if (self.state != .starting) return error.DuplicateKernelReady;
            self.state = .running;
        },
        .stdout, .stderr => {
            if (matches and self.active == .execute) {
                const stream: Stream = if (event.event == .stdout) .stdout else .stderr;
                const destination = if (stream == .stdout) &self.out else &self.err;
                try destination.append(self.alloc, event.text, self.cap);
                if (self.sink) |sink| sink.write(sink.context, stream, event.text);
            } else try self.background.append(self.alloc, event.text, background_cap);
        },
        .result => {
            if (id == 0) return error.InvalidKernelFrame;
            if (matches and self.active == .execute) try self.value.append(self.alloc, event.text, self.cap);
        },
        .@"error" => {
            if (!matches) return self.diagnostic.append(self.alloc, event.evalue, diagnostic_cap);
            self.request_status = .failed;
            for (event.traceback) |entry| try self.err.append(self.alloc, entry, self.cap);
            if (event.traceback.len == 0) {
                try self.err.append(self.alloc, event.ename, self.cap);
                try self.err.append(self.alloc, ": ", self.cap);
                try self.err.append(self.alloc, event.evalue, self.cap);
            }
        },
        .done => {
            if (id == 0) return error.InvalidKernelFrame;
            if (!matches) return;
            if ((event.status orelse .@"error") != .ok) self.request_status = .failed;
            const ok = self.request_status == .ok;
            switch (self.active) {
                .restore => {
                    if (!ok) try self.restore_report.append(self.alloc, event.reason orelse "the restore failed", diagnostic_cap);
                    for (event.failed, 0..) |entry, index| {
                        if (index > 0 or !ok) try self.restore_report.append(self.alloc, ", ", diagnostic_cap);
                        try self.restore_report.append(self.alloc, entry.name, diagnostic_cap);
                        try self.restore_report.append(self.alloc, " (", diagnostic_cap);
                        try self.restore_report.append(self.alloc, entry.reason, diagnostic_cap);
                        try self.restore_report.append(self.alloc, ")", diagnostic_cap);
                    }
                },
                .execute => {},
                .snapshot => if (ok) {
                    const manifest = try protocol.Manifest.create(self.alloc, event.records, event.failed);
                    manifest.written = event.written;
                    manifest.bytes = event.bytes;
                    if (self.snapshot_result) |old| old.destroy();
                    self.snapshot_result = manifest;
                } else try self.diagnostic.append(self.alloc, event.reason orelse "Snapshot failed", diagnostic_cap),
                .shutdown, .none => {},
            }
            self.completed_id = id;
            self.active = .none;
        },
    }
}

pub fn openLog(self: *Manager) void {
    openLogChecked(self) catch {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.diagnostic.append(self.alloc, "Cannot open or rotate kernel stderr log.\n", diagnostic_cap) catch {};
        self.mutex.unlock(io_mod.getIo());
    };
}

fn openLogChecked(self: *Manager) !void {
    const io = io_mod.getIo();
    var dir = try std.Io.Dir.openDirAbsolute(io, self.artifact_dir, .{});
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));
    var file = try dir.createFile(io, "kernel-stderr.log", .{ .truncate = false, .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    try file.setPermissions(io, .fromMode(0o600));
    var size = (try file.stat(io)).size;
    if (size >= max_log_bytes) {
        // Rename atomically over the previous generation; never truncate a log on boot.
        try dir.rename("kernel-stderr.log", dir, "kernel-stderr.log.old", io);
        const replacement = try dir.createFile(io, "kernel-stderr.log", .{ .permissions = .fromMode(0o600) });
        file.close(io);
        file = replacement;
        size = 0;
    }
    self.stderr_log = file;
    self.stderr_log_bytes = @intCast(size);
}

fn log(self: *Manager, bytes: []const u8) void {
    self.mutex.lockUncancelable(io_mod.getIo());
    self.diagnostic.append(self.alloc, bytes, diagnostic_cap) catch {};
    self.mutex.unlock(io_mod.getIo());
    if (self.stderr_log) |file| {
        const keep = @min(bytes.len, max_log_bytes -| self.stderr_log_bytes);
        file.writePositionalAll(io_mod.getIo(), bytes[0..keep], self.stderr_log_bytes) catch {};
        self.stderr_log_bytes += keep;
        if (keep > 0 and keep < bytes.len) {
            const marker = "\n[kernel stderr log reached its 5 MiB budget; further output is omitted]\n";
            file.writePositionalAll(io_mod.getIo(), marker, self.stderr_log_bytes) catch {};
            self.stderr_log_bytes += marker.len;
        }
    }
}
