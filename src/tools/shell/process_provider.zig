const std = @import("std");
const builtin = @import("builtin");
const host = @import("../../core/hosts/host.zig");
const io_mod = @import("../../core/shared/io.zig");
const process_identity = @import("../../core/execution/process_identity.zig");
const process_provider = @import("../../core/execution/process_provider.zig");
const process_tree = @import("../../core/execution/process_tree.zig");

const Allocator = std.mem.Allocator;

pub const provider = process_provider.Provider{
    .capture_token_fn = captureToken,
    .match_token_fn = matchToken,
    .signal_process_fn = signalProcess,
};

fn captureToken(
    _: ?*anyopaque,
    alloc: Allocator,
    pid_text: []const u8,
) process_provider.ProviderError!process_identity.ProcessInstanceToken {
    const pid = std.fmt.parseInt(std.posix.pid_t, pid_text, 10) catch
        return error.InvalidPid;
    return switch (builtin.os.tag) {
        .linux => captureLinuxToken(alloc, pid) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ProcessNotFound => error.ProcessNotFound,
            else => error.ProcessIdentityUnavailable,
        },
        .macos => captureMacOSToken(pid) catch |err| switch (err) {
            error.ProcessNotFound => error.ProcessNotFound,
            else => error.ProcessIdentityUnavailable,
        },
        else => error.ProcessIdentityUnsupported,
    };
}

fn matchToken(
    context: ?*anyopaque,
    alloc: Allocator,
    pid: []const u8,
    expected: process_identity.ProcessInstanceToken,
) process_identity.TokenMatch {
    const actual = captureToken(context, alloc, pid) catch |err| {
        return if (err == error.ProcessNotFound) .missing else .unavailable;
    };
    return if (actual.eql(expected)) .matched else .mismatched;
}

fn readLinuxProcStat(file: std.Io.File, buffer: []u8) !usize {
    if (builtin.os.tag != .linux) return error.ProcessIdentityUnsupported;
    while (true) {
        const rc = std.posix.system.read(file.handle, buffer.ptr, buffer.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const read_len: usize = @intCast(rc);
                if (read_len == 0) return error.ProcessNotFound;
                return read_len;
            },
            .INTR => continue,
            .SRCH => return error.ProcessNotFound,
            else => return error.ProcessIdentityUnavailable,
        }
    }
}

fn captureLinuxToken(
    alloc: Allocator,
    pid: std.posix.pid_t,
) !process_identity.ProcessInstanceToken {
    const zio = io_mod.getIo();
    var boot_id_file = std.Io.Dir.openFileAbsolute(
        zio,
        "/proc/sys/kernel/random/boot_id",
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ProcessIdentityUnavailable,
        else => return err,
    };
    defer boot_id_file.close(zio);
    var boot_id_text: [128]u8 = undefined;
    var boot_id_reader = boot_id_file.readerStreaming(zio, &.{});
    const boot_id_text_len = boot_id_reader.interface.readSliceShort(
        &boot_id_text,
    ) catch return boot_id_reader.err.?;

    var boot_id: [32]u8 = undefined;
    var boot_len: usize = 0;
    for (std.mem.trim(u8, boot_id_text[0..boot_id_text_len], " \r\n\t")) |byte| {
        if (byte == '-') continue;
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte) or
            boot_len == boot_id.len)
        {
            return error.ProcessIdentityUnavailable;
        }
        boot_id[boot_len] = byte;
        boot_len += 1;
    }
    if (boot_len != boot_id.len) return error.ProcessIdentityUnavailable;

    const stat_path = try std.fmt.allocPrint(alloc, "/proc/{d}/stat", .{pid});
    defer alloc.free(stat_path);
    var stat_file = std.Io.Dir.openFileAbsolute(
        zio,
        stat_path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ProcessNotFound,
        else => return err,
    };
    defer stat_file.close(zio);
    var stat_text: [4096]u8 = undefined;
    const stat_text_len = try readLinuxProcStat(stat_file, &stat_text);
    const stat = stat_text[0..stat_text_len];
    const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse
        return error.ProcessIdentityUnavailable;
    var fields = std.mem.tokenizeScalar(u8, stat[close_paren + 1 ..], ' ');
    var field_number: usize = 3;
    var start_ticks: ?[]const u8 = null;
    while (fields.next()) |field| : (field_number += 1) {
        if (field_number == 22) {
            start_ticks = field;
            break;
        }
    }
    const ticks = start_ticks orelse return error.ProcessIdentityUnavailable;
    _ = std.fmt.parseUnsigned(u64, ticks, 10) catch
        return error.ProcessIdentityUnavailable;
    var token_buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &token_buf,
        "linux:{s}:{s}",
        .{ boot_id[0..], ticks },
    );
    return process_identity.ProcessInstanceToken.parse(text);
}

fn captureMacOSToken(
    pid: std.posix.pid_t,
) !process_identity.ProcessInstanceToken {
    if (builtin.os.tag != .macos) return error.ProcessIdentityUnsupported;
    const ProcBsdInfo = extern struct {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        pbi_uid: u32,
        pbi_gid: u32,
        pbi_ruid: u32,
        pbi_rgid: u32,
        pbi_svuid: u32,
        pbi_svgid: u32,
        rfu_1: u32,
        pbi_comm: [16]u8,
        pbi_name: [32]u8,
        pbi_nfiles: u32,
        pbi_pgid: u32,
        pbi_pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        pbi_nice: i32,
        pbi_start_tvsec: u64,
        pbi_start_tvusec: u64,
    };
    const Darwin = struct {
        extern "c" fn proc_pidinfo(
            pid_value: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *anyopaque,
            buffersize: c_int,
        ) c_int;
        extern "c" fn sysctlbyname(
            name: [*:0]const u8,
            oldp: ?*anyopaque,
            oldlenp: *usize,
            newp: ?*const anyopaque,
            newlen: usize,
        ) c_int;
    };

    var info: ProcBsdInfo = undefined;
    const read_len = Darwin.proc_pidinfo(pid, 3, 0, &info, @sizeOf(ProcBsdInfo));
    if (read_len == 0) return error.ProcessNotFound;
    if (read_len != @sizeOf(ProcBsdInfo)) return error.ProcessIdentityUnavailable;

    var uuid_buf: [64]u8 = undefined;
    var uuid_len: usize = uuid_buf.len;
    if (Darwin.sysctlbyname(
        "kern.bootsessionuuid",
        &uuid_buf,
        &uuid_len,
        null,
        0,
    ) != 0) return error.ProcessIdentityUnavailable;
    var uuid: [32]u8 = undefined;
    var normalized_len: usize = 0;
    for (uuid_buf[0..uuid_len]) |byte| {
        if (byte == 0) break;
        if (byte == '-') continue;
        const lower = std.ascii.toLower(byte);
        if (!std.ascii.isHex(lower) or normalized_len == uuid.len) {
            return error.ProcessIdentityUnavailable;
        }
        uuid[normalized_len] = lower;
        normalized_len += 1;
    }
    if (normalized_len != uuid.len) return error.ProcessIdentityUnavailable;
    var token_buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &token_buf,
        "macos:{s}:{d}:{d}",
        .{ uuid[0..], info.pbi_start_tvsec, info.pbi_start_tvusec },
    );
    return process_identity.ProcessInstanceToken.parse(text);
}

fn signalProcess(
    context: ?*anyopaque,
    alloc: Allocator,
    pid_text: []const u8,
    expected: process_identity.ProcessInstanceToken,
) process_provider.ProviderError!void {
    switch (matchToken(context, alloc, pid_text, expected)) {
        .matched => {},
        .missing, .mismatched => return error.ProcessIdentityMismatch,
        .unavailable => return error.ProcessIdentityIndeterminate,
    }
    if (!host.current().process_control) return error.Unsupported;
    const pid = std.fmt.parseInt(std.posix.pid_t, pid_text, 10) catch
        return error.InvalidPid;
    var tracker = try process_tree.Tracker.init(alloc);
    defer tracker.deinit();
    tracker.refresh(pid) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ProcessNotFound => return error.ProcessNotFound,
        else => return error.ProcessIdentityUnavailable,
    };
    if (tracker.signalAll(std.posix.SIG.TERM) == 0) {
        return error.ProcessNotFound;
    }
    const started_ms = io_mod.milliTimestamp();
    while (tracker.anyAlive() and io_mod.milliTimestamp() - started_ms < 250) {
        io_mod.sleep(25 * std.time.ns_per_ms);
    }
    if (tracker.anyAlive()) _ = tracker.signalAll(std.posix.SIG.KILL);
}

test "native process provider delegates tree signaling to the neutral tracker" {
    try std.testing.expect(provider.context == null);
    try std.testing.expect(provider.capture_token_fn == captureToken);
    try std.testing.expect(provider.match_token_fn == matchToken);
    try std.testing.expect(provider.signal_process_fn == signalProcess);
}
