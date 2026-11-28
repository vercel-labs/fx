//! Runs `src/core/mods/store.zig` under step-by-step stdin/stdout control
//! for `tests/tla/drivers/mods/driver.ts`.
//!
//! Commands:
//! - `lab_store change <root> <add|update|disable|enable|remove> <name> [<source_dir>]`
//! - `lab_store load <root> <name>`
//!
//! Uses `std.Io.File.tryLock` / `unlock` for advisory locking with a 50 ms
//! deadline so a SIGKILLed process drops its lock in the OS kernel, matching
//! `tests/tla/mods/ModStore.tla`.

const std = @import("std");
const store = @import("store");

const lab_lock_deadline_ms: u64 = 50;
const lock_poll_interval_ms: u64 = 5;
const locks_dir_name = ".locks";

const LabCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    in_reader: *std.Io.File.Reader,
    out_writer: *std.Io.File.Writer,
};

fn labStepHook(ctx_ptr: ?*anyopaque, step: store.Step) void {
    const ctx: *LabCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const out = &ctx.out_writer.interface;
    out.print("step {s}\n", .{@tagName(step)}) catch std.process.exit(1);
    out.flush() catch std.process.exit(1);

    _ = ctx.in_reader.interface.discardDelimiterInclusive('\n') catch std.process.exit(1);
}

fn acquireLabLock(
    ctx_ptr: ?*anyopaque,
    io: std.Io,
    root_path: []const u8,
    name: []const u8,
    deadline_ms: u64,
) anyerror!store.LockAttempt {
    const ctx: *LabCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const locks_path = try std.Io.Dir.path.join(ctx.alloc, &.{ root_path, locks_dir_name });
    defer ctx.alloc.free(locks_path);

    var locks_dir = try std.Io.Dir.cwd().createDirPathOpen(io, locks_path, .{});
    defer locks_dir.close(io);

    const file = try locks_dir.createFile(io, name, .{ .read = true, .truncate = false });
    errdefer file.close(io);

    const started = std.Io.Timestamp.now(io, .awake);
    const deadline_ns = started.nanoseconds + @as(i96, @intCast(deadline_ms)) * std.time.ns_per_ms;

    while (true) {
        if (try file.tryLock(io, .exclusive)) {
            return .{ .acquired = .{
                .file = file,
                .release_fn = releaseLabLock,
            } };
        }
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline_ns) {
            file.close(io);
            return .busy;
        }
        io.sleep(.fromMilliseconds(lock_poll_interval_ms), .awake) catch {};
    }
}

fn releaseLabLock(self: *store.Lock, io: std.Io) void {
    self.file.unlock(io);
    self.file.close(io);
}

fn formatOutcome(buf: *[64]u8, outcome: store.Outcome) []const u8 {
    return switch (outcome) {
        .ok => "ok",
        .exists => "exists",
        .missing => "missing",
        .busy => "busy",
        .invalid => |inv| std.mem.print(buf, "invalid:{s}", .{@tagName(inv)}) catch "invalid",
    };
}

fn runChange(ctx: *LabCtx, args: []const []const u8) !void {
    if (args.len < 5) return error.ExpectedChangeArgs;
    const root_path = args[2];
    const op_name = args[3];
    const mod_name = args[4];

    const s: store.Store = .{
        .root_path = root_path,
        .ops = .{
            .io = ctx.io,
            .ctx = ctx,
            .lock_deadline_ms = lab_lock_deadline_ms,
            .acquire_lock = acquireLabLock,
            .step = labStepHook,
        },
    };

    const outcome = if (std.mem.eql(u8, op_name, "add")) blk: {
        if (args.len != 6) return error.ExpectedSourceDir;
        break :blk try store.add(ctx.alloc, s, mod_name, args[5], null);
    } else if (std.mem.eql(u8, op_name, "update")) blk: {
        if (args.len != 6) return error.ExpectedSourceDir;
        break :blk try store.update(ctx.alloc, s, mod_name, args[5], null);
    } else if (std.mem.eql(u8, op_name, "disable")) blk: {
        if (args.len != 5) return error.UnexpectedExtraArgs;
        break :blk try store.setOn(ctx.alloc, s, mod_name, false);
    } else if (std.mem.eql(u8, op_name, "enable")) blk: {
        if (args.len != 5) return error.UnexpectedExtraArgs;
        break :blk try store.setOn(ctx.alloc, s, mod_name, true);
    } else if (std.mem.eql(u8, op_name, "remove")) blk: {
        if (args.len != 5) return error.UnexpectedExtraArgs;
        break :blk try store.remove(ctx.alloc, s, mod_name);
    } else return error.UnknownOperation;

    var outcome_buf: [64]u8 = undefined;
    const out = &ctx.out_writer.interface;
    try out.print("result {s}\n", .{formatOutcome(&outcome_buf, outcome)});
    try out.flush();
}

fn runLoad(ctx: *LabCtx, args: []const []const u8) !void {
    if (args.len != 4) return error.ExpectedLoadArgs;
    const root_path = args[2];
    const mod_name = args[3];

    const s: store.Store = .{
        .root_path = root_path,
        .ops = .{
            .io = ctx.io,
            .ctx = ctx,
            .lock_deadline_ms = lab_lock_deadline_ms,
            .acquire_lock = acquireLabLock,
        },
    };

    var loaded = try store.load(ctx.alloc, s, mod_name);
    defer loaded.deinit(ctx.alloc);

    const out = &ctx.out_writer.interface;
    switch (loaded) {
        .none => try out.writeAll("{\"state\":\"none\"}\n"),
        .bad => try out.writeAll("{\"state\":\"bad\"}\n"),
        .mod => |m| {
            const ver = std.fmt.parseInt(u32, m.version, 10) catch {
                try out.writeAll("{\"state\":\"bad\"}\n");
                try out.flush();
                return;
            };
            try out.print("{{\"state\":\"mod\",\"v\":{d},\"off\":{s}}}\n", .{
                ver,
                if (m.on) "false" else "true",
            });
        },
    }
    try out.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.MissingSubcommand;

    var in_buf: [256]u8 = undefined;
    var in_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);

    var ctx: LabCtx = .{
        .alloc = alloc,
        .io = io,
        .in_reader = &in_reader,
        .out_writer = &out_writer,
    };

    if (std.mem.eql(u8, args[1], "change")) {
        try runChange(&ctx, args);
    } else if (std.mem.eql(u8, args[1], "load")) {
        try runLoad(&ctx, args);
    } else {
        return error.UnknownSubcommand;
    }
}
