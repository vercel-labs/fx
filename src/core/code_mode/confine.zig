//! Locks the calling process down before it runs model-written JavaScript, so
//! a bug in the engine can reach no file, socket, or other process, and can use
//! no more memory or CPU time than the run allows. Confinement is permanent
//! for the process: the code-mode child calls `confine` once, before it reads
//! the program.
//!
//! On Linux the kernel kills the process on any system call outside a short
//! allowlist (seccomp). On macOS a deny-all sandbox profile refuses every
//! file, network, process, and signal operation, while reads and writes on
//! the pipes the child already holds keep working. Both platforms also lower
//! resource limits, and close every inherited descriptor above stderr.

const std = @import("std");
const builtin = @import("builtin");

const native_os = builtin.target.os.tag;

/// Whether this build can confine itself. Code mode is unavailable elsewhere.
pub const supported = switch (native_os) {
    .linux => builtin.target.cpu.arch == .x86_64 or builtin.target.cpu.arch == .aarch64,
    .macos => true,
    else => false,
};

pub const Limits = struct {
    /// Most address space the process may map. Linux only: macOS does not
    /// enforce it, and the engine's own heap cap still applies there.
    address_space_bytes: u64,
    /// CPU seconds after which the kernel kills the process: a backstop
    /// behind the engine's own deadline and the parent's watchdog.
    cpu_seconds: u64,
};

pub const Error = error{
    /// This platform has no confinement; see `supported`.
    Unsupported,
    /// The OS refused a limit or the sandbox. The caller must not run the
    /// program.
    ConfinementFailed,
};

/// Confines the calling process, every thread in it, for the rest of its
/// life.
pub fn confine(limits: Limits) Error!void {
    if (!supported) return error.Unsupported;
    try closeInheritedDescriptors();
    try setLimit(.CORE, 0);
    try setLimit(.FSIZE, 0);
    try setLimit(.CPU, limits.cpu_seconds);
    switch (native_os) {
        .linux => {
            try setLimit(.NPROC, 0);
            try setLimit(.AS, limits.address_space_bytes);
            try setLimit(.NOFILE, 3);
            try linux_filter.install();
        },
        .macos => {
            try setLimit(.NOFILE, 3);
            try installMacosProfile();
        },
        else => unreachable,
    }
}

fn closeInheritedDescriptors() Error!void {
    switch (native_os) {
        .linux => {
            const rc = std.os.linux.close_range(3, std.math.maxInt(std.os.linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false });
            if (std.os.linux.errno(rc) != .SUCCESS) return error.ConfinementFailed;
        },
        else => {
            var current: std.c.rlimit = undefined;
            if (std.c.getrlimit(.NOFILE, &current) != 0) return error.ConfinementFailed;
            // A descriptor at or above the soft limit can exist only if the
            // limit was lowered after it opened; the cap keeps the scan fast.
            const end: std.c.fd_t = @intCast(@min(current.cur, 65536));
            var fd: std.c.fd_t = 3;
            while (fd < end) : (fd += 1) _ = std.c.close(fd);
        },
    }
}

fn setLimit(resource: std.c.rlimit_resource, value: u64) Error!void {
    const limit: std.c.rlimit = .{ .cur = value, .max = value };
    if (std.c.setrlimit(resource, &limit) != 0) return error.ConfinementFailed;
}

extern "c" fn sandbox_init(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int;
extern "c" fn sandbox_free_error(errorbuf: [*:0]u8) void;

fn installMacosProfile() Error!void {
    var message: ?[*:0]u8 = null;
    if (sandbox_init("(version 1) (deny default)", 0, &message) != 0) {
        if (message) |text| sandbox_free_error(text);
        return error.ConfinementFailed;
    }
}

/// The seccomp program. It checks the architecture first, so a call made
/// through another system call convention can't slip past the numbers below,
/// and it kills the whole process on any call outside the allowlist.
const linux_filter = struct {
    const linux = std.os.linux;
    const SYS = linux.SYS;

    /// What the engine, the allocator, and the frame I/O on stdin and stdout
    /// need. Opening, networking, process, and signal calls are all absent.
    /// The static musl build's `malloc` is Zig's `SmpAllocator`, which counts
    /// CPUs with `sched_getaffinity` the first time each size class is used,
    /// so that call reads a CPU mask and nothing else.
    const allowed = [_]SYS{
        .read,            .write,             .readv,           .writev,
        .close,           .exit,              .exit_group,      .rt_sigreturn,
        .rt_sigprocmask,  .sigaltstack,       .mmap,            .munmap,
        .mremap,          .brk,               .madvise,         .mprotect,
        .futex,           .clock_gettime,     .clock_nanosleep, .nanosleep,
        .getrandom,       .sched_yield,       .getpid,          .gettid,
        .restart_syscall, .sched_getaffinity,
    };

    /// A classic BPF instruction, `struct sock_filter`.
    const Instruction = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
    /// `struct sock_fprog`.
    const Program = extern struct { len: c_ushort, filter: [*]const Instruction };

    const load_word = 0x20; // BPF_LD | BPF_W | BPF_ABS
    const jump_equal = 0x15; // BPF_JMP | BPF_JEQ | BPF_K
    const jump_at_least = 0x35; // BPF_JMP | BPF_JGE | BPF_K
    const return_value = 0x06; // BPF_RET | BPF_K

    /// x86_64 also accepts x32 calls, whose numbers carry this bit.
    const x32_bit = 0x40000000;

    /// `AUDIT_ARCH_*`: the ELF machine with the 64-bit and little-endian
    /// flags. Written out because Zig 0.17's `std.os.linux.AUDIT.ARCH` fails
    /// to compile when referenced.
    const audit_arch: u32 = switch (builtin.target.cpu.arch) {
        .x86_64 => 0xC000003E,
        .aarch64 => 0xC00000B7,
        else => @compileError("seccomp filter for an unsupported architecture"),
    };

    const kill: Instruction = .{ .code = return_value, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.KILL_PROCESS };
    const allow: Instruction = .{ .code = return_value, .jt = 0, .jf = 0, .k = linux.SECCOMP.RET.ALLOW };

    const instructions = build: {
        var list: []const Instruction = &.{
            .{ .code = load_word, .jt = 0, .jf = 0, .k = @offsetOf(linux.SECCOMP.data, "arch") },
            .{ .code = jump_equal, .jt = 1, .jf = 0, .k = audit_arch },
            kill,
            .{ .code = load_word, .jt = 0, .jf = 0, .k = @offsetOf(linux.SECCOMP.data, "nr") },
        };
        if (builtin.target.cpu.arch == .x86_64) {
            list = list ++ &[_]Instruction{ .{ .code = jump_at_least, .jt = 0, .jf = 1, .k = x32_bit }, kill };
        }
        for (allowed, 0..) |call, i| {
            // On a match, skip the remaining checks and the kill after them.
            list = list ++ &[_]Instruction{.{ .code = jump_equal, .jt = allowed.len - i, .jf = 0, .k = @intCast(@backingInt(call)) }};
        }
        list = list ++ &[_]Instruction{ kill, allow };
        break :build list[0..list.len].*;
    };

    fn install() Error!void {
        const no_new_privs = linux.prctl(@backingInt(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
        if (linux.errno(no_new_privs) != .SUCCESS) return error.ConfinementFailed;
        const program: Program = .{ .len = instructions.len, .filter = &instructions };
        // TSYNC applies the filter to every thread, or fails if one can't take it.
        const rc = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, linux.SECCOMP.FILTER_FLAG.TSYNC, &program);
        if (linux.errno(rc) != .SUCCESS) return error.ConfinementFailed;
    }
};

// Each test forks a child, confines it, and has it try one thing. A confined
// child can't print, so it reports through its exit code: 0 when the attempt
// was refused, 1 when it succeeded, 2 when confinement itself failed. A
// seccomp kill (SIGSYS) also counts as refused.

const Verdict = enum { refused, allowed, confine_failed, other };

fn runConfined(comptime attempt: fn () bool) !Verdict {
    if (!supported) return error.SkipZigTest;
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        confine(.{ .address_space_bytes = 1 << 30, .cpu_seconds = 5 }) catch std.c._exit(2);
        std.c._exit(if (attempt()) 1 else 0);
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return error.WaitFailed;
    const s: u32 = @bitCast(status);
    if (std.c.W.IFEXITED(s)) return switch (std.c.W.EXITSTATUS(s)) {
        0 => .refused,
        1 => .allowed,
        2 => .confine_failed,
        else => .other,
    };
    if (std.c.W.IFSIGNALED(s) and std.c.W.TERMSIG(s) == .SYS) return .refused;
    return .other;
}

fn expectRefused(comptime attempt: fn () bool) !void {
    try std.testing.expectEqual(Verdict.refused, try runConfined(attempt));
}

test "a confined process can still compute and use its pipes" {
    try std.testing.expectEqual(Verdict.allowed, try runConfined(struct {
        fn attempt() bool {
            const bytes = std.heap.c_allocator.alloc(u8, 8 << 20) catch return false;
            defer std.heap.c_allocator.free(bytes);
            @memset(bytes, 7);
            // A write to stderr stands in for the frame pipe.
            return bytes[bytes.len - 1] == 7 and std.c.write(2, "", 0) == 0;
        }
    }.attempt));
}

test "a confined process can count its CPUs" {
    // The static musl build's `malloc` counts CPUs the first time it hands out
    // each size of block. macOS uses the system's `malloc`, which doesn't.
    if (native_os != .linux) return error.SkipZigTest;
    try std.testing.expectEqual(Verdict.allowed, try runConfined(struct {
        fn attempt() bool {
            const count = std.Thread.getCpuCount() catch return false;
            return count > 0;
        }
    }.attempt));
}

test "a confined process cannot read a file" {
    try expectRefused(struct {
        fn attempt() bool {
            return std.c.open("/etc/passwd", .{ .ACCMODE = .RDONLY }) >= 0;
        }
    }.attempt);
}

test "a confined process cannot create a file" {
    try expectRefused(struct {
        fn attempt() bool {
            return std.c.open("/tmp/fx-confine-test-must-not-exist", .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o600)) >= 0;
        }
    }.attempt);
}

/// The port of a listener the network test opens before it forks, so a
/// refused connection means the sandbox refused it, not that nothing listened.
var listening_port: u16 = 0;

fn connectToListener() bool {
    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return false;
    defer _ = std.c.close(sock);
    var address: std.c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, listening_port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    return std.c.connect(sock, @ptrCast(&address), @sizeOf(std.c.sockaddr.in)) == 0;
}

test "a confined process cannot connect to the network" {
    if (!supported) return error.SkipZigTest;
    const listener = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(listener >= 0);
    defer _ = std.c.close(listener);
    var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    var length: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    try std.testing.expectEqual(0, std.c.bind(listener, @ptrCast(&address), length));
    try std.testing.expectEqual(0, std.c.listen(listener, 4));
    try std.testing.expectEqual(0, std.c.getsockname(listener, @ptrCast(&address), &length));
    listening_port = std.mem.bigToNative(u16, address.port);
    // Unconfined, the same connection succeeds.
    try std.testing.expect(connectToListener());
    try expectRefused(connectToListener);
}

test "a confined process cannot start another process" {
    try expectRefused(struct {
        fn attempt() bool {
            const pid = std.c.fork();
            if (pid == 0) std.c._exit(0);
            return pid > 0;
        }
    }.attempt);
    try expectRefused(struct {
        fn attempt() bool {
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "exit 0" };
            const envp = [_:null]?[*:0]const u8{};
            _ = std.c.execve("/bin/sh", &argv, &envp);
            return false;
        }
    }.attempt);
}

test "a confined process cannot signal its parent" {
    try expectRefused(struct {
        fn attempt() bool {
            return std.c.kill(std.c.getppid(), @fromBackingInt(0)) == 0;
        }
    }.attempt);
}
