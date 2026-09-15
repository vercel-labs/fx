// Guest-only experiment. Executable file pages are immutable. Mutable state
// and explicitly relocated constants occupy a separate anonymous segment.
const std = @import("std");
const contract = @import("contract.zig");
const page_size = contract.page_size;
var workspace: [page_size + 131072]u8 align(16) = undefined;
var page_states: [contract.max_pages]u8 = @splat(0);
var pager_owner: u64 = 0;
const SigAction = extern struct { handler: u64, mask: u32, flags: u32 };
const SigInfo = extern struct {
    signo: i32,
    errno: i32,
    code: i32,
    pid: i32,
    uid: u32,
    status: i32,
    addr: u64,
};
const ExceptionState = extern struct { far: u64, esr: u32, exception: u32 };
const UContext = extern struct {
    onstack: i32,
    sigmask: u32,
    stack: [3]u64,
    link: u64,
    mcsize: u64,
    mcontext: ?*const ExceptionState,
};
fn config() *const contract.Config {
    return @ptrFromInt(asm volatile (
        \\adrp x9, pager_config
        \\add x9, x9, #:lo12:pager_config
        : [result] "={x9}" (-> u64),
    ));
}
fn slide() u64 {
    return @intFromPtr(config()) - config().self_addr;
}
// BSD syscall errors use carry and positive errno, not Linux negative errno.
noinline fn syscall(n: u64, a: [6]u64) u64 {
    // A call boundary keeps kernel-clobbered argument registers out of callers.
    var auxiliary: u64 = undefined;
    return asm volatile (
        \\svc 0x80
        \\b.cc 1f
        \\neg x0, x0
        \\1:
        : [result] "={x0}" (-> u64),
          [auxiliary] "={x1}" (auxiliary),
        : [n] "{x16}" (n),
          [a0] "{x0}" (a[0]),
          [a1] "{x1}" (a[1]),
          [a2] "{x2}" (a[2]),
          [a3] "{x3}" (a[3]),
          [a4] "{x4}" (a[4]),
          [a5] "{x5}" (a[5]),
        : .{ .memory = true });
}
fn exit(code: u64) noreturn {
    _ = syscall(1, .{ code, 0, 0, 0, 0, 0 });
    unreachable;
}
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    exit(90);
}
fn fail(message: []const u8, code: u64) noreturn {
    _ = syscall(4, .{ 2, @intFromPtr(message.ptr), message.len, 0, 0, 0 });
    exit(code);
}
fn protect(addr: u64, len: u64, prot: u64) void {
    const result = syscall(74, .{ addr, len, prot, 0, 0, 0 });
    if (result != 0) {
        debug_hex(addr);
        debug_hex(prot);
        debug_hex(result);
        fail("[pager] protection transition failed (address, protection, result above)\n", 73);
    }
}
fn debug_hex(value: u64) void {
    var buf: [17]u8 = undefined;
    for (0..16) |i| {
        const digit: u8 = @truncate((value >> @intCast((15 - i) * 4)) & 15);
        buf[i] = if (digit < 10) '0' + digit else 'a' + digit - 10;
    }
    buf[16] = '\n';
    _ = syscall(4, .{ 2, @intFromPtr(&buf), buf.len, 0, 0, 0 });
}
fn require_guest() void {
    // CTL_HW/HW_MODEL, before reading any uninitialized relocated data.
    var mib = [2]i32{ 6, 2 };
    var model: [64]u8 = @splat(0);
    var len: usize = model.len;
    if (syscall(202, .{ @intFromPtr(&mib), 2, @intFromPtr(&model), @intFromPtr(&len), 0, 0 }) != 0) exit(85);
    // Individual bytes keep this bootstrap independent of .rodata.
    if (model[0] != 'V' or model[1] != 'i' or model[2] != 'r' or model[3] != 't' or
        model[4] != 'u' or model[5] != 'a' or model[6] != 'l' or model[7] != 'M' or
        model[8] != 'a' or model[9] != 'c') exit(85);
}
fn initialize_state() void {
    const c = config();
    const s = slide();
    if (c.magic != contract.magic or c.page_count == 0 or c.page_count > contract.max_pages) exit(83);
    if (c.state_len < 8 or c.readonly_len > c.state_len or c.readonly_len % page_size != 0) exit(83);
    const dst: [*]volatile u8 = @ptrFromInt(c.state_addr + s);
    const src: [*]const volatile u8 = @ptrFromInt(c.template_addr + s);
    // Volatile prevents lowering to memcpy before installing the template.
    for (0..c.state_len) |i| dst[i] = src[i];
    const relocs: [*]const u64 = @ptrFromInt(c.reloc_addr + s);
    for (0..c.reloc_count) |i| {
        const off = relocs[i];
        if (off % 8 != 0 or off > c.state_len - 8) exit(84);
        const slot: *u64 = @ptrFromInt(c.state_addr + s + off);
        slot.* += s;
    }
    // Relocated constants become read-only before any decompression or signal.
    if (c.readonly_len != 0) protect(c.state_addr + s, c.readonly_len, 1);
}
fn flush_icache(page: [*]u8) void {
    var addr = @intFromPtr(page);
    const end = addr + page_size;
    while (addr < end) : (addr += 64) asm volatile ("dc cvau, %[p]"
        :
        : [p] "r" (addr),
        : .{ .memory = true });
    asm volatile ("dsb ish" ::: .{ .memory = true });
    addr = @intFromPtr(page);
    while (addr < end) : (addr += 64) asm volatile ("ic ivau, %[p]"
        :
        : [p] "r" (addr),
        : .{ .memory = true });
    asm volatile ("dsb ish\n\tisb" ::: .{ .memory = true });
}
fn load_page(idx: usize) void {
    const c = config();
    const s = slide();
    const frames: [*]const contract.Frame = @ptrFromInt(c.table_addr + s);
    const frame = frames[idx];
    if (frame.off > c.blob_len or frame.len > c.blob_len - frame.off)
        fail("[pager] invalid frame bounds\n", 74);
    const bytes: [*]const u8 = @ptrFromInt(c.blob_addr + s + frame.off);
    const page: [*]u8 = @ptrFromInt(c.text_addr + s + idx * page_size);
    protect(@intFromPtr(page), page_size, 3);
    var input: std.Io.Reader = .fixed(bytes[0..frame.len]);
    var decoder = std.compress.zstd.Decompress.init(&input, &workspace, .{ .window_len = page_size });
    decoder.reader.readSliceAll(page[0..page_size]) catch fail("[pager] invalid compressed frame\n", 74);
    var extra: [1]u8 = undefined;
    const count = decoder.reader.readSliceShort(&extra) catch fail("[pager] invalid frame ending\n", 74);
    if (count != 0 or contract.page_hash(page[0..page_size]) != frame.checksum)
        fail("[pager] decoded page integrity failure\n", 74);
    flush_icache(page);
    protect(@intFromPtr(page), page_size, 5);
    page_states[idx] = 1;
}
export fn on_fault(_: i32, info: *const SigInfo, context: ?*anyopaque) callconv(.c) void {
    const c = config();
    // A write into restored code is a program error, not a page-in request.
    // Returning to it would create an endless stream of already-loaded faults.
    if (context) |ptr| {
        const ctx: *const UContext = @ptrCast(@alignCast(ptr));
        if (ctx.mcontext) |mc| {
            const ec = mc.esr >> 26;
            if ((ec == 0x24 or ec == 0x25) and mc.esr & 0x40 != 0)
                fail("[pager] write fault in executable text\n", 88);
        }
    }
    const base = c.text_addr + slide();
    if (info.addr < base or info.addr >= base + c.page_count * page_size) {
        debug_hex(info.addr);
        debug_hex(slide());
        fail("[pager] fault outside paged text (address, slide above)\n", 70);
    }
    const tid = syscall(372, .{ 0, 0, 0, 0, 0, 0 });
    if (tid == 0 or tid > 0x7fff_ffff_ffff_ffff) exit(86);
    // No allocation, libc locks, or calls into paged fx code. Fail recursive
    // entry on the owner thread instead of deadlocking on ourselves.
    while (@cmpxchgStrong(u64, &pager_owner, 0, tid, .acquire, .monotonic)) |owner| {
        if (owner == tid) fail("[pager] recursive fault\n", 87);
        asm volatile ("yield");
    }
    defer @atomicStore(u64, &pager_owner, 0, .release);
    const idx = (info.addr - base) / page_size;
    // A queued fault can arrive after another thread has loaded this page.
    if (page_states[idx] == 0) load_page(idx);
}
export fn _start(argc: usize, argv: usize, envp: usize, apple: usize) callconv(.c) i32 {
    require_guest();
    initialize_state();
    const c = config();
    const s = slide();
    if (c.eager != 0) {
        for (0..c.page_count) |i| load_page(i);
    } else {
        const sigaction: *const fn (i32, *const SigAction, ?*SigAction) callconv(.c) i32 = @ptrFromInt(c.sigaction_addr + s);
        const act = SigAction{ .handler = @intFromPtr(&on_fault), .mask = 0, .flags = 0x0050 };
        if (sigaction(10, &act, null) != 0 or sigaction(11, &act, null) != 0) exit(76);
        protect(c.text_addr + s, c.page_count * page_size, 0);
    }
    const entry: *const fn (usize, usize, usize, usize) callconv(.c) i32 = @ptrFromInt(c.entry_addr + s);
    return entry(argc, argv, envp, apple);
}
