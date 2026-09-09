const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const process_tree = @import("process_tree.zig");

// Darwin's ancillary alignment is 4 even on 64-bit hosts; Linux uses size_t.
const ControlLength = if (builtin.os.tag == .macos) u32 else usize;
const ControlHeader = extern struct {
    len: ControlLength,
    level: c_int,
    kind: c_int,
};
const control_alignment = @sizeOf(ControlLength);
const control_data_offset = std.mem.alignForward(usize, @sizeOf(ControlHeader), control_alignment);
const rights_type = 1; // SCM_RIGHTS on Linux and Darwin.
const capability_byte: u8 = 0x73;
// XNU's UIPC_MAX_CMSG_FD bounds one control mbuf to 512 fds (sockargs
// additionally bounds it by MCLBYTES). Linux caps SCM_RIGHTS at 253.
// Darwin can install undisclosed fds on CTRUNC, so reserve the kernel bound,
// not just the descriptors our protocol accepts.
const max_received_descriptors = 512;
const capability_descriptor_count = if (builtin.os.tag == .macos) 2 else 1;

fn controlSpace(bytes: usize) usize {
    return control_data_offset + std.mem.alignForward(usize, bytes, control_alignment);
}

/// Owns one mapping and descriptor in this process, never a request arena.
/// Moving this value transfers ownership; copying it does not duplicate it.
/// The peer receives its own descriptor and virtual mapping of the same store.
/// This same-binary private protocol assumes peers never resize the backing file.
pub const Mapping = struct {
    state: *process_tree.SharedMembership,
    file: std.Io.File,
    memory: []align(std.heap.page_size_min) u8,
    /// The creator retains both pipe ends until deinit. A receiver may call
    /// closeChildCopy after spawning the target; its duplicate still pins the
    /// write endpoint until that receiver's own scope cleanup finishes.
    witness: ?process_tree.DarwinProcessWitness,

    pub fn create() !Mapping {
        if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.ScopeMappingUnsupported;
        const io = io_mod.getIo();
        var random: [16]u8 = undefined;
        io.random(&random);
        var path_buffer: [96]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "/tmp/fx-scope-{x}", .{random});
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0o600);
        const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        errdefer file.close(io);
        // No persistent name or path is used for handoff, including on macOS.
        var linked = true;
        errdefer if (linked) std.Io.Dir.cwd().deleteFile(io, path) catch {};
        try std.Io.Dir.cwd().deleteFile(io, path);
        linked = false;
        try setCloexec(fd);
        try file.setLength(io, @sizeOf(process_tree.SharedMembership));
        const memory = try mapFile(file);
        errdefer std.posix.munmap(memory);
        const state: *process_tree.SharedMembership = @ptrCast(@alignCast(memory.ptr));
        state.* = .{};
        const witness = if (builtin.os.tag == .macos) try process_tree.DarwinProcessWitness.init() else null;
        return .{ .state = state, .file = file, .memory = memory, .witness = witness };
    }

    /// Sends one capability byte with the mapping fd and, on macOS, its witness
    /// child fd in the same SCM_RIGHTS transaction. Linux sends only the mapping.
    /// Borrows control and retains this mapping; suppresses SIGPIPE per call/socket.
    /// Nonblocking per call; the bootstrap owner retries WouldBlock within its deadline.
    pub fn send(self: *const Mapping, control: std.Io.File) !void {
        if (comptime builtin.os.tag == .macos) {
            const witness = self.witness orelse return error.ScopeWitnessUnavailable;
            const child_fd = witness.child_fd orelse return error.ScopeWitnessUnavailable;
            try self.state.validateWitness(&witness);
            try sendDescriptors(control, &.{ self.file.handle, child_fd }, capability_byte);
        } else {
            try self.state.validate();
            try sendDescriptors(control, &.{self.file.handle}, capability_byte);
        }
    }

    /// Consumes only the capability byte, not the subsequent bootstrap frame.
    /// Owns and closes every received descriptor on malformed/partial transfer.
    /// Nonblocking per call; retry only WouldBlock, within the bootstrap deadline.
    pub fn receive(control: std.Io.File) !Mapping {
        var ancillary: [controlSpace(max_received_descriptors * @sizeOf(std.posix.fd_t))]u8 align(@alignOf(ControlHeader)) = @splat(0);
        var byte: [1]u8 = undefined;
        var iov = [1]std.posix.iovec{.{ .base = &byte, .len = 1 }};
        var message: std.posix.msghdr = std.mem.zeroes(std.posix.msghdr);
        message.iov = &iov;
        message.iovlen = 1;
        message.control = &ancillary;
        message.controllen = ancillary.len;
        const received = while (true) {
            const result = std.c.recvmsg(control.handle, &message, std.posix.MSG.DONTWAIT | (if (builtin.os.tag == .linux) std.posix.MSG.CMSG_CLOEXEC else @as(u32, 0)));
            switch (std.posix.errno(result)) {
                .SUCCESS => break result,
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                else => return error.ScopeTransferFailed,
            }
        };
        var descriptors: [max_received_descriptors]std.posix.fd_t = undefined;
        var descriptor_count: usize = 0;
        defer for (descriptors[0..descriptor_count]) |fd| closeFd(fd);
        const length: usize = @intCast(message.controllen);
        if (length > ancillary.len) return error.InvalidScopeTransfer;
        var malformed = false;
        var offset: usize = 0;
        var headers: usize = 0;
        while (offset + @sizeOf(ControlHeader) <= length) {
            const header: *align(1) const ControlHeader = @ptrCast(ancillary[offset..].ptr);
            const header_len: usize = @intCast(header.len);
            if (header_len < control_data_offset) {
                malformed = true;
                break;
            }
            const visible_len = @min(header_len, length - offset);
            if (visible_len != header_len) malformed = true;
            headers += 1;
            const payload = ancillary[offset + control_data_offset .. offset + visible_len];
            if (header.level == std.posix.SOL.SOCKET and header.kind == rights_type) {
                if (payload.len % @sizeOf(std.posix.fd_t) != 0) malformed = true;
                var index: usize = 0;
                while (index + @sizeOf(std.posix.fd_t) <= payload.len) : (index += @sizeOf(std.posix.fd_t)) {
                    const fd = std.mem.bytesToValue(std.posix.fd_t, payload[index..][0..@sizeOf(std.posix.fd_t)]);
                    if (descriptor_count < descriptors.len) {
                        descriptors[descriptor_count] = fd;
                        descriptor_count += 1;
                    } else {
                        closeFd(fd);
                        malformed = true;
                    }
                }
            } else malformed = true;
            if (visible_len != header_len) break;
            const advance = std.mem.alignForward(usize, header_len, control_alignment);
            if (advance > length - offset) {
                offset += header_len;
                break;
            }
            offset += advance;
        }
        if (received != 1 or byte[0] != capability_byte or malformed or headers != 1 or
            descriptor_count != capability_descriptor_count or offset != length or
            message.flags & (std.posix.MSG.CTRUNC | std.posix.MSG.TRUNC) != 0)
            return error.InvalidScopeTransfer;
        const file: std.Io.File = .{ .handle = descriptors[0], .flags = .{ .nonblocking = false } };
        try setCloexec(file.handle);
        const memory = try mapFile(file);
        errdefer std.posix.munmap(memory);
        const state: *process_tree.SharedMembership = @ptrCast(@alignCast(memory.ptr));
        try state.validate();
        var witness: ?process_tree.DarwinProcessWitness = null;
        if (comptime builtin.os.tag == .macos) {
            var adopted = try process_tree.DarwinProcessWitness.fromOwnedChildFd(descriptors[1]);
            // The constructor owns the child fd now; the pool still owns the file.
            descriptor_count = 1;
            errdefer adopted.deinit();
            try state.validateWitness(&adopted);
            witness = adopted;
        }
        descriptor_count = 0;
        return .{ .state = state, .file = file, .memory = memory, .witness = witness };
    }

    pub fn deinit(self: *Mapping) void {
        if (self.witness) |*witness| witness.deinit();
        std.posix.munmap(self.memory);
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }
};

fn mapFile(file: std.Io.File) ![]align(std.heap.page_size_min) u8 {
    const raw_flags = std.c.fcntl(file.handle, std.posix.F.GETFL);
    if (raw_flags < 0) return error.InvalidScopeDescriptor;
    const flags: std.posix.O = @bitCast(@as(u32, @intCast(raw_flags)));
    if (flags.ACCMODE != .RDWR) return error.InvalidScopeDescriptor;
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.size != @sizeOf(process_tree.SharedMembership) or stat.nlink != 0)
        return error.InvalidScopeDescriptor;
    return std.posix.mmap(null, @sizeOf(process_tree.SharedMembership), .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, file.handle, 0);
}

fn setCloexec(fd: std.posix.fd_t) !void {
    while (true) switch (std.posix.errno(std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.ScopeDescriptorControlFailed,
    };
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn sendDescriptors(control: std.Io.File, descriptors: []const std.posix.fd_t, byte: u8) !void {
    if (descriptors.len > max_received_descriptors) return error.InvalidScopeTransfer;
    if (comptime builtin.os.tag == .macos) {
        const enabled: c_int = 1;
        if (std.c.setsockopt(control.handle, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0)
            return error.ScopeTransferFailed;
    }
    var ancillary: [controlSpace(max_received_descriptors * @sizeOf(std.posix.fd_t))]u8 align(@alignOf(ControlHeader)) = @splat(0);
    const header: *ControlHeader = @ptrCast(&ancillary);
    const bytes = std.mem.sliceAsBytes(descriptors);
    header.* = .{ .len = @intCast(control_data_offset + bytes.len), .level = std.posix.SOL.SOCKET, .kind = rights_type };
    @memcpy(ancillary[control_data_offset..][0..bytes.len], bytes);
    var iov = [1]std.posix.iovec_const{.{ .base = @ptrCast(&byte), .len = 1 }};
    var message: std.posix.msghdr_const = std.mem.zeroes(std.posix.msghdr_const);
    message.iov = &iov;
    message.iovlen = 1;
    message.control = &ancillary;
    message.controllen = @intCast(controlSpace(bytes.len));
    while (true) {
        const result = std.c.sendmsg(control.handle, &message, std.posix.MSG.DONTWAIT | (if (builtin.os.tag == .linux) std.posix.MSG.NOSIGNAL else @as(u32, 0)));
        switch (std.posix.errno(result)) {
            .SUCCESS => if (result == 1) return else return error.InvalidScopeTransfer,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.ScopeTransferFailed,
        }
    }
}

fn socketPair() ![2]std.Io.File {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    errdefer for (fds) |fd| closeFd(fd);
    for (fds) |fd| try setCloexec(fd);
    return .{
        .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

test "scope memory transfer shares storage and independent mapping ownership" {
    var original = try Mapping.create();
    defer original.deinit();
    const pair = try socketPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    try original.send(pair[0]);
    var received = try Mapping.receive(pair[1]);
    defer received.deinit();
    try std.testing.expect(original.state != received.state);
    try std.testing.expect(original.file.handle != received.file.handle);
    var tracker = try process_tree.Tracker.initShared(std.testing.allocator, received.state);
    defer tracker.deinit();
    if (received.witness) |*witness| {
        try std.testing.expectEqualDeep(original.witness.?.identity, witness.identity);
        try std.testing.expect(original.witness.?.childFd() != witness.childFd());
        try std.testing.expect(witness.supervisor_fd.? != witness.childFd());
        for ([_]std.posix.fd_t{
            original.witness.?.childFd(), original.witness.?.supervisor_fd.?,
            witness.childFd(),            witness.supervisor_fd.?,
        }) |fd| try std.testing.expect(std.c.fcntl(fd, std.posix.F.GETFD) & std.posix.FD_CLOEXEC != 0);
        tracker.bindProcessWitness(witness);
    } else {
        try std.testing.expect(builtin.os.tag == .linux);
        try std.testing.expect(original.witness == null);
    }
    try tracker.refresh(std.c.getpid());
    try std.testing.expectEqual(std.c.getpid(), original.state.rootPid().?);
    try std.testing.expect(original.state.isComplete());
    try std.testing.expectEqual(process_tree.Liveness.alive, tracker.scanLiveness());
    for ([_]std.Io.File{ original.file, received.file }) |file| {
        const flags = std.c.fcntl(file.handle, std.posix.F.GETFD);
        try std.testing.expect(flags & std.posix.FD_CLOEXEC != 0);
        try std.testing.expectEqual(@as(std.Io.File.NLink, 0), (try file.stat(io_mod.getIo())).nlink);
    }
}

test "scope memory rejects oversized rights and invalid capability without descriptor leaks" {
    var mapping = try Mapping.create();
    defer mapping.deinit();
    const pair = try socketPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    const available_fd = try probeAvailableFd(mapping.file.handle);
    for (0..8) |_| {
        const extra = [_]std.posix.fd_t{mapping.file.handle} ** (capability_descriptor_count + 1);
        try sendDescriptors(pair[0], &extra, capability_byte);
        try std.testing.expectError(error.InvalidScopeTransfer, Mapping.receive(pair[1]));
        try std.testing.expectEqual(available_fd, try probeAvailableFd(mapping.file.handle));
        const many = [_]std.posix.fd_t{mapping.file.handle} ** 253;
        // The short control buffer regression used 17 rights; also exercise
        // the largest rights message supported by both native kernels.
        for ([_]usize{ 17, 253 }) |count| {
            try sendDescriptors(pair[0], many[0..count], capability_byte);
            try std.testing.expectError(error.InvalidScopeTransfer, Mapping.receive(pair[1]));
        }
        try sendTestCapability(pair[0], mapping.file.handle, mapping.witness, 0);
        try std.testing.expectError(error.InvalidScopeTransfer, Mapping.receive(pair[1]));
        try std.testing.expectEqual(available_fd, try probeAvailableFd(mapping.file.handle));
    }
}

fn sendTestCapability(control: std.Io.File, fd: std.posix.fd_t, witness: ?process_tree.DarwinProcessWitness, byte: u8) !void {
    if (comptime builtin.os.tag == .macos) {
        try sendDescriptors(control, &.{ fd, witness.?.childFd() }, byte);
    } else {
        try sendDescriptors(control, &.{fd}, byte);
    }
}

fn probeAvailableFd(fd: std.posix.fd_t) !std.posix.fd_t {
    const probe = std.c.fcntl(fd, std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (probe < 0) return error.DescriptorProbeFailed;
    closeFd(probe);
    return probe;
}

test "Darwin scope capability rejects missing or invalid witness without descriptor leaks" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var mapping = try Mapping.create();
    defer mapping.deinit();
    const pair = try socketPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const regular_write = try tmp.dir.createFile(io_mod.getIo(), "not-a-pipe", .{});
    defer regular_write.close(io_mod.getIo());
    const available_fd = try probeAvailableFd(mapping.file.handle);
    for (0..8) |_| {
        try sendDescriptors(pair[0], &.{mapping.file.handle}, capability_byte);
        try std.testing.expectError(error.InvalidScopeTransfer, Mapping.receive(pair[1]));
        for ([_]std.posix.fd_t{
            mapping.file.handle, pair[0].handle, mapping.witness.?.supervisor_fd.?, regular_write.handle,
        }) |invalid| {
            try sendDescriptors(pair[0], &.{ mapping.file.handle, invalid }, capability_byte);
            try std.testing.expectError(error.InvalidProcessWitness, Mapping.receive(pair[1]));
            try std.testing.expectEqual(available_fd, try probeAvailableFd(mapping.file.handle));
        }
    }
}

test "Darwin scope capability rejects a different pipe than its published witness" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var mapping = try Mapping.create();
    defer mapping.deinit();
    var other = try process_tree.DarwinProcessWitness.init();
    defer other.deinit();
    var tracker = try process_tree.Tracker.initShared(std.testing.allocator, mapping.state);
    defer tracker.deinit();
    tracker.bindProcessWitness(&mapping.witness.?);
    try tracker.refresh(std.c.getpid());
    const pair = try socketPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    const available_fd = try probeAvailableFd(mapping.file.handle);
    for (0..8) |_| {
        try sendDescriptors(pair[0], &.{ mapping.file.handle, other.childFd() }, capability_byte);
        try std.testing.expectError(error.SharedWitnessMismatch, Mapping.receive(pair[1]));
        try std.testing.expectEqual(available_fd, try probeAvailableFd(mapping.file.handle));
    }
    try mapping.send(pair[0]);
    var received = try Mapping.receive(pair[1]);
    defer received.deinit();
    try std.testing.expectEqualDeep(mapping.witness.?.identity, received.witness.?.identity);
    try std.testing.expect(mapping.state.isComplete());
}

test "Darwin creator and receiver independently retain their scope witness" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pair = try socketPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    const available_fd = try probeAvailableFd(pair[0].handle);
    {
        var survivor = blk: {
            var original = try Mapping.create();
            defer original.deinit();
            // Closing one receiver must leave the creator's witness intact.
            {
                const before = try probeAvailableFd(original.file.handle);
                try original.send(pair[0]);
                var receiver = try Mapping.receive(pair[1]);
                receiver.witness.?.closeChildCopy();
                receiver.deinit();
                try std.testing.expectEqual(before, try probeAvailableFd(original.file.handle));
            }
            try original.send(pair[0]);
            var receiver = try Mapping.receive(pair[1]);
            errdefer receiver.deinit();
            try std.testing.expectEqualDeep(original.witness.?.identity, receiver.witness.?.identity);
            var tracker = try process_tree.Tracker.initShared(std.testing.allocator, receiver.state);
            defer tracker.deinit();
            tracker.bindProcessWitness(&receiver.witness.?);
            try tracker.refresh(std.c.getpid());
            receiver.witness.?.closeChildCopy();
            break :blk receiver;
        };
        defer survivor.deinit();
        // The creator's read end is now gone. Only the receiver's write-end
        // anchor survives; recapture its real identity through another transfer.
        try std.testing.expect(survivor.witness.?.child_fd == null);
        try std.testing.expectError(error.ScopeWitnessUnavailable, survivor.send(pair[0]));
        try sendDescriptors(pair[0], &.{ survivor.file.handle, survivor.witness.?.supervisor_fd.? }, capability_byte);
        var probe = try Mapping.receive(pair[1]);
        defer probe.deinit();
        try std.testing.expectEqual(survivor.witness.?.identity.handle, probe.witness.?.identity.handle);
        try std.testing.expectEqual(@as(u64, 0), probe.witness.?.identity.peer_handle);
        try std.testing.expect(probe.state.isComplete());
    }
    try std.testing.expectEqual(available_fd, try probeAvailableFd(pair[0].handle));
}

test "scope memory rejects a read-only capability before writable mmap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = io_mod.getIo();
    const backing = try tmp.dir.createFile(io, "read-only", .{ .read = true });
    defer backing.close(io);
    try backing.setLength(io, @sizeOf(process_tree.SharedMembership));
    const read_only = try tmp.dir.openFile(io, "read-only", .{ .mode = .read_only });
    defer read_only.close(io);
    try tmp.dir.deleteFile(io, "read-only");
    const pair = try socketPair();
    defer for (pair) |file| file.close(io);
    var witness: ?process_tree.DarwinProcessWitness = if (builtin.os.tag == .macos) try process_tree.DarwinProcessWitness.init() else null;
    defer if (witness) |*value| value.deinit();
    try sendTestCapability(pair[0], read_only.handle, witness, capability_byte);
    try std.testing.expectError(error.InvalidScopeDescriptor, Mapping.receive(pair[1]));
}

test "scope memory rejects wrong descriptor kind size and header" {
    var mapping = try Mapping.create();
    defer mapping.deinit();
    const pair = try socketPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    const available_fd = try probeAvailableFd(mapping.file.handle);
    try sendTestCapability(pair[0], pair[0].handle, mapping.witness, capability_byte);
    try std.testing.expectError(error.InvalidScopeDescriptor, Mapping.receive(pair[1]));
    mapping.state.version = 0;
    try sendTestCapability(pair[0], mapping.file.handle, mapping.witness, capability_byte);
    try std.testing.expectError(error.InvalidSharedMembership, Mapping.receive(pair[1]));
    try std.testing.expectEqual(available_fd, try probeAvailableFd(mapping.file.handle));
    // Only this test mutates the backing size; neither mapping is read afterwards.
    try mapping.file.setLength(io_mod.getIo(), 1);
    try sendTestCapability(pair[0], mapping.file.handle, mapping.witness, capability_byte);
    try std.testing.expectError(error.InvalidScopeDescriptor, Mapping.receive(pair[1]));
}

test "scope memory peer mapping outlives creator mapping and preserves control framing" {
    const pair = try socketPair();
    defer for (pair) |file| file.close(io_mod.getIo());
    var received = blk: {
        var original = try Mapping.create();
        defer original.deinit();
        try std.testing.expectError(error.WouldBlock, Mapping.receive(pair[1]));
        try original.send(pair[0]);
        try pair[0].writeStreamingAll(io_mod.getIo(), "next");
        break :blk try Mapping.receive(pair[1]);
    };
    defer received.deinit();
    var buffer: [4]u8 = undefined;
    const length = std.c.read(pair[1].handle, &buffer, buffer.len);
    try std.testing.expectEqual(@as(isize, 4), length);
    try std.testing.expectEqualStrings("next", &buffer);
    var tracker = try process_tree.Tracker.initShared(std.testing.allocator, received.state);
    defer tracker.deinit();
    try tracker.refresh(std.c.getpid());
    try std.testing.expect(received.state.isComplete());
}

test "scope memory survives writer death during unpublished record without false empty" {
    var mapping = try Mapping.create();
    defer mapping.deinit();
    var tracker = try process_tree.Tracker.initShared(std.testing.allocator, mapping.state);
    defer tracker.deinit();
    try tracker.refresh(std.c.getpid());
    const committed = @atomicLoad(u32, &mapping.state.committed, .acquire);
    const root = mapping.state.records[0];
    const child = std.c.fork();
    if (child == -1) return error.ForkFailed;
    if (child == 0) {
        // No allocators or inherited I/O runtime are used in the fork child.
        @atomicStore(u32, &mapping.state.scanning, 1, .release);
        mapping.state.records[committed].pid = -1;
        mapping.state.records[committed].kind = 999;
        std.posix.kill(std.c.getpid(), std.posix.SIG.KILL) catch {};
        std.c._exit(2);
    }
    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(child, &status, 0);
        if (waited == child) break;
        if (waited == -1 and std.posix.errno(waited) == .INTR) continue;
        return error.WaitFailed;
    }
    try std.testing.expect(std.c.W.IFSIGNALED(@intCast(status)));
    try std.testing.expectEqual(std.posix.SIG.KILL, std.c.W.TERMSIG(@intCast(status)));
    try mapping.state.validate();
    try std.testing.expect(!mapping.state.isComplete());
    try std.testing.expectEqualDeep(root, mapping.state.records[0]);
    try std.testing.expectEqual(committed, @atomicLoad(u32, &mapping.state.committed, .acquire));
    try std.testing.expectEqual(process_tree.Liveness.incomplete, tracker.scanLiveness());
    // Only after waitpid proved death may the parent take over writing.
    try tracker.refresh(std.c.getpid());
    try std.testing.expect(!mapping.state.isComplete());
    try std.testing.expectEqual(process_tree.Liveness.incomplete, tracker.scanLiveness());
}

test "scope memory transfer rejects EOF missing rights and closed peer without SIGPIPE" {
    var mapping = try Mapping.create();
    defer mapping.deinit();
    const pair = try socketPair();
    defer pair[0].close(io_mod.getIo());
    try pair[0].writeStreamingAll(io_mod.getIo(), &.{capability_byte});
    try std.testing.expectError(error.InvalidScopeTransfer, Mapping.receive(pair[1]));
    pair[1].close(io_mod.getIo());
    try std.testing.expectError(error.InvalidScopeTransfer, Mapping.receive(pair[0]));
    try std.testing.expectError(error.ScopeTransferFailed, mapping.send(pair[0]));
}
