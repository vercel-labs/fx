//! What a kernel process costs and who it is: its private memory, which the
//! pool's budget sums, and its start time, which tells a live kernel apart from
//! a later process that reused its pid. Both read the OS directly through libc
//! or /proc, with no helper process.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const os = builtin.target.os.tag;

pub const budget_env = "PROTO_FX_KERNEL_MEMORY_BUDGET";
const max_default_budget: u64 = 4 << 30;

/// `struct rusage_info_v0` from <sys/resource.h>.
const RusageInfoV0 = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
};
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfoV0) c_int;

fn darwinRusage(pid: std.posix.pid_t) ?RusageInfoV0 {
    if (comptime os != .macos) return null;
    var info: RusageInfoV0 = undefined;
    if (proc_pid_rusage(pid, 0, &info) != 0) return null;
    return info;
}

/// Memory only this process holds, in bytes, or null when the process is gone
/// or unreadable. macOS reports phys_footprint, which leaves out pages a forked
/// kernel still shares with its zygote. Linux reports Pss, which splits each
/// shared page among its sharers, so the sum over a zygote and its kernels is
/// their real total; without smaps_rollup it falls back to resident minus shared.
pub fn privateBytes(pid: std.posix.pid_t) ?u64 {
    if (pid <= 0) return null;
    return switch (os) {
        .macos => if (darwinRusage(pid)) |info| info.phys_footprint else null,
        .linux => linuxPss(pid) orelse linuxStatm(pid),
        else => null,
    };
}

/// An opaque token that changes when the pid names a different process, or
/// null when no process has the pid. A zombie keeps its token until reaped.
pub fn startToken(pid: std.posix.pid_t) ?u64 {
    if (pid <= 0) return null;
    return switch (os) {
        .macos => if (darwinRusage(pid)) |info| info.proc_start_abstime else null,
        .linux => linuxStartTime(pid),
        else => null,
    };
}

fn readProc(buf: []u8, pid: std.posix.pid_t, name: []const u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.mem.print(&path_buf, "/proc/{d}/{s}", .{ pid, name }) catch return null;
    const io = io_mod.getIo();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const len = file.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..len];
}

fn linuxPss(pid: std.posix.pid_t) ?u64 {
    var buf: [4096]u8 = undefined;
    return parsePss(readProc(&buf, pid, "smaps_rollup") orelse return null);
}

fn parsePss(text: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Pss:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["Pss:".len..], " \t");
        const kib = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        return kib * 1024;
    }
    return null;
}

fn linuxStatm(pid: std.posix.pid_t) ?u64 {
    var buf: [256]u8 = undefined;
    var fields = std.mem.tokenizeScalar(u8, readProc(&buf, pid, "statm") orelse return null, ' ');
    _ = fields.next() orelse return null;
    const resident = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    const shared = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    return (resident -| shared) * std.heap.pageSize();
}

fn linuxStartTime(pid: std.posix.pid_t) ?u64 {
    var buf: [1024]u8 = undefined;
    return parseStartTime(readProc(&buf, pid, "stat") orelse return null);
}

/// Field 22 of /proc/<pid>/stat. The command name in field 2 may hold spaces
/// and parentheses, so fields are counted from its last closing parenthesis.
fn parseStartTime(text: []const u8) ?u64 {
    const close = std.mem.findScalarLast(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    var index: usize = 3;
    while (fields.next()) |field| : (index += 1) {
        if (index == 22) return std.fmt.parseInt(u64, field, 10) catch null;
    }
    return null;
}

/// The budget on every kernel's private memory together: the environment
/// override, else a quarter of physical memory capped at 4 GiB.
pub fn configuredBudget() u64 {
    if (io_mod.getenv(budget_env)) |raw| if (parseSize(raw)) |value| return value;
    const total = std.process.totalSystemMemory() catch return 1 << 30;
    return @min(total / 4, max_default_budget);
}

/// Bytes, or a number with a binary suffix: K, M, G or T, optionally followed
/// by B or iB, in any case. Zero and malformed values are rejected.
pub fn parseSize(raw: []const u8) ?u64 {
    const text = std.mem.trim(u8, raw, " \t");
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    const number = std.fmt.parseInt(u64, text[0..end], 10) catch return null;
    var suffix = text[end..];
    for ([_][]const u8{ "ib", "b" }) |unit| {
        if (suffix.len > unit.len and std.ascii.endsWithIgnoreCase(suffix, unit)) {
            suffix = suffix[0 .. suffix.len - unit.len];
            break;
        }
    }
    const shift: u6 = if (suffix.len == 0) 0 else if (suffix.len > 1) return null else switch (std.ascii.toLower(suffix[0])) {
        'k' => 10,
        'm' => 20,
        'g' => 30,
        't' => 40,
        'b' => 0,
        else => return null,
    };
    const value = std.math.shlExact(u64, number, shift) catch return null;
    return if (value == 0) null else value;
}

test "memory budget sizes accept bytes and binary suffixes" {
    try std.testing.expectEqual(@as(?u64, 1048576), parseSize("1048576"));
    try std.testing.expectEqual(@as(?u64, 64 << 20), parseSize("64M"));
    try std.testing.expectEqual(@as(?u64, 2 << 30), parseSize("2G"));
    try std.testing.expectEqual(@as(?u64, 2 << 30), parseSize("2gib"));
    try std.testing.expectEqual(@as(?u64, 512 << 10), parseSize(" 512KB "));
    try std.testing.expectEqual(@as(?u64, 100), parseSize("100B"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("0"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("-1G"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("lots"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("2X"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("99999999999T"));
    try std.testing.expect(configuredBudget() > 0);
    try std.testing.expect(configuredBudget() <= max_default_budget);
}

test "proc parsers read Pss and the start time past a command with spaces" {
    try std.testing.expectEqual(@as(?u64, 4321 * 1024), parsePss("Rss:  9000 kB\nPss:   4321 kB\nShared_Clean: 1 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parsePss("Rss: 1 kB\n"));
    const stat = "42 (py (thon) x) S 1 42 42 0 -1 4194304 1 0 0 0 0 0 0 0 20 0 1 0 987654 1000 10";
    try std.testing.expectEqual(@as(?u64, 987654), parseStartTime(stat));
    try std.testing.expectEqual(@as(?u64, null), parseStartTime("42 (short) S 1"));
}

test "this process has private memory and a stable start token" {
    if (comptime os != .macos and os != .linux) return error.SkipZigTest;
    const pid = std.c.getpid();
    try std.testing.expect((privateBytes(pid) orelse 0) > 0);
    const token = startToken(pid) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(token, startToken(pid).?);
    try std.testing.expectEqual(@as(?u64, null), privateBytes(-1));
}
