//! Drives `src/core/mods/pins.zig` and `src/core/mods/store.zig` under
//! stdin/stdout control for `tests/tla/drivers/mods/driver.ts` (`use-walk`),
//! stepping through `tests/tla/mods/ModUse.tla` design "pin".
//!
//! Subcommands:
//! - `lab_use reader <root> <name>`
//! - `lab_use install <root> <name> <source_dir> <token_hex>`
//! - `lab_use remove <root> <name>`
//! - `lab_use cleanup-version <root> <name> <token_hex>`
//! - `lab_use collect <root> <name>`

const std = @import("std");
const store = @import("store");
const pins = store.pins;

const lab_lock_deadline_ms: u64 = 50;
const lock_poll_interval_ms: u64 = 5;
const locks_dir_name = ".locks";
const marker_file_name = "marker.txt";

const ReaderCtx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    in_reader: *std.Io.File.Reader,
    out_writer: *std.Io.File.Writer,
};

fn readCommandLine(in_reader: *std.Io.File.Reader, buf: []u8) !?[]const u8 {
    var line_writer: std.Io.Writer = .fixed(buf);
    const n = try in_reader.interface.streamDelimiterLimit(&line_writer, '\n', .limited(buf.len));
    _ = in_reader.interface.takeByte() catch |err| switch (err) {
        error.EndOfStream => if (n == 0) return null,
        else => return err,
    };
    return std.mem.trimEnd(u8, buf[0..n], "\r");
}

fn expectCommand(ctx: *ReaderCtx, expected: []const u8) void {
    var buf: [64]u8 = undefined;
    const cmd = readCommandLine(ctx.in_reader, &buf) catch std.process.exit(1) orelse std.process.exit(0);
    if (!std.mem.eql(u8, cmd, expected)) {
        std.process.exit(1);
    }
}

fn readerStepHook(ctx_ptr: ?*anyopaque, step: pins.Step) void {
    const ctx: *ReaderCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const out = &ctx.out_writer.interface;
    switch (step) {
        .resolved => {
            out.writeAll("step resolved\n") catch std.process.exit(1);
            out.flush() catch std.process.exit(1);
            expectCommand(ctx, "lock");
        },
        .locked => {
            out.writeAll("step locked\n") catch std.process.exit(1);
            out.flush() catch std.process.exit(1);
            expectCommand(ctx, "check");
        },
        .retry => {
            out.writeAll("step retry\n") catch std.process.exit(1);
            out.flush() catch std.process.exit(1);
            expectCommand(ctx, "resolve");
        },
        .checked => {},
    }
}

fn readMarker(io: std.Io, folder_path: []const u8, buf: *[64]u8) ![]const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, folder_path, .{ .follow_symlinks = false });
    defer dir.close(io);
    var file = try dir.openFile(io, marker_file_name, .{ .mode = .read_only, .follow_symlinks = false });
    defer file.close(io);
    var read_buf: [128]u8 = undefined;
    var r = file.reader(io, &read_buf);
    var w: std.Io.Writer = .fixed(buf);
    const n = try r.interface.streamRemaining(&w);
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn runReader(alloc: std.mem.Allocator, io: std.Io, root_path: []const u8, mod_name: []const u8) !void {
    var in_buf: [256]u8 = undefined;
    var in_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    var ctx: ReaderCtx = .{
        .alloc = alloc,
        .io = io,
        .in_reader = &in_reader,
        .out_writer = &out_writer,
    };

    var current_pin: ?pins.Pin = null;
    defer if (current_pin) |*p| p.release(alloc, io);

    try out.writeAll("ready\n");
    try out.flush();

    const pin_ops: pins.Ops = .{
        .io = io,
        .ctx = &ctx,
        .lock_deadline_ms = lab_lock_deadline_ms,
        .max_resolve_attempts = 64,
        .step = readerStepHook,
    };

    var cmd_buf: [128]u8 = undefined;
    while (try readCommandLine(&in_reader, &cmd_buf)) |cmd| {
        if (std.mem.eql(u8, cmd, "resolve")) {
            const res = try pins.reload(alloc, root_path, mod_name, &current_pin, pin_ops);
            switch (res) {
                .pinned => |p| {
                    current_pin = p;
                    try out.print("result pinned {s}\n", .{&p.token});
                },
                .not_installed => try out.writeAll("result none\n"),
                .bad_link => try out.writeAll("result bad_link\n"),
                .busy => try out.writeAll("result busy\n"),
            }
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "reload")) {
            try out.writeAll("step reload\n");
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "use") or std.mem.eql(u8, cmd, "end_use")) {
            const prefix = if (std.mem.eql(u8, cmd, "use")) "used" else "ended";
            const p = current_pin orelse {
                try out.writeAll("use_error NoPin\n");
                try out.flush();
                continue;
            };
            var marker_buf: [64]u8 = undefined;
            if (readMarker(io, p.path, &marker_buf)) |marker| {
                try out.print("{s} {s}\n", .{ prefix, marker });
            } else |err| {
                try out.print("use_error {s}\n", .{@errorName(err)});
            }
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "release")) {
            if (current_pin) |*p| {
                p.release(alloc, io);
                current_pin = null;
            }
            try out.writeAll("released\n");
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "quit")) {
            break;
        } else {
            return error.UnknownReaderCommand;
        }
    }
}

const ChangerCtx = struct {
    alloc: std.mem.Allocator,
    token: [pins.token_hex_bytes]u8 = undefined,
};

fn fixedFillToken(ctx_ptr: ?*anyopaque, _: std.Io, out_hex: *[pins.token_hex_bytes]u8) void {
    const ctx: *ChangerCtx = @ptrCast(@alignCast(ctx_ptr.?));
    out_hex.* = ctx.token;
}

fn acquireLabLock(
    ctx_ptr: ?*anyopaque,
    io: std.Io,
    root_path: []const u8,
    name: []const u8,
    deadline_ms: u64,
) anyerror!store.LockAttempt {
    const ctx: *ChangerCtx = @ptrCast(@alignCast(ctx_ptr.?));
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

fn makeStore(ctx: *ChangerCtx, io: std.Io, root_path: []const u8, collect_after_switch: bool) store.Store {
    return .{
        .root_path = root_path,
        .ops = .{
            .io = io,
            .ctx = ctx,
            .lock_deadline_ms = lab_lock_deadline_ms,
            .acquire_lock = acquireLabLock,
            .fill_token = fixedFillToken,
            .collect_after_switch = collect_after_switch,
        },
    };
}

fn parseTokenHex(raw: []const u8) ![pins.token_hex_bytes]u8 {
    if (raw.len != pins.token_hex_bytes or !pins.isLowerHex(raw)) return error.InvalidToken;
    var out: [pins.token_hex_bytes]u8 = undefined;
    @memcpy(&out, raw);
    return out;
}

fn runChanger(alloc: std.mem.Allocator, io: std.Io, root_path: []const u8, mod_name: []const u8) !void {
    var in_buf: [1024]u8 = undefined;
    var in_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [512]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    try out.writeAll("ready\n");
    try out.flush();

    var ctx: ChangerCtx = .{ .alloc = alloc };
    var cmd_buf: [1024]u8 = undefined;
    while (try readCommandLine(&in_reader, &cmd_buf)) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse continue;
        var outcome: store.Outcome = undefined;

        if (std.mem.eql(u8, cmd, "install")) {
            const src = it.next() orelse return error.ExpectedInstallArgs;
            const tok = it.next() orelse return error.ExpectedInstallArgs;
            ctx.token = try parseTokenHex(tok);
            const s = makeStore(&ctx, io, root_path, false);
            var loaded = try store.load(alloc, s, mod_name);
            const has_link = loaded != .none;
            loaded.deinit(alloc);
            outcome = if (has_link)
                try store.update(alloc, s, mod_name, src, null)
            else
                try store.add(alloc, s, mod_name, src, null);
        } else if (std.mem.eql(u8, cmd, "remove")) {
            const s = makeStore(&ctx, io, root_path, false);
            outcome = try store.remove(alloc, s, mod_name);
        } else if (std.mem.eql(u8, cmd, "cleanup-version")) {
            const tok = it.next() orelse return error.ExpectedCleanupVersionArgs;
            const token = try parseTokenHex(tok);
            const s = makeStore(&ctx, io, root_path, true);
            outcome = try store.collectVersion(s, mod_name, &token);
        } else if (std.mem.eql(u8, cmd, "collect")) {
            const s = makeStore(&ctx, io, root_path, true);
            outcome = try store.collect(s, mod_name);
        } else if (std.mem.eql(u8, cmd, "quit")) {
            break;
        } else {
            return error.UnknownChangerCommand;
        }

        var outcome_buf: [64]u8 = undefined;
        try out.print("result {s}\n", .{formatOutcome(&outcome_buf, outcome)});
        try out.flush();
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) return error.MissingArgs;

    const cmd = args[1];
    const root_path = args[2];
    const mod_name = args[3];

    if (std.mem.eql(u8, cmd, "reader")) {
        try runReader(alloc, io, root_path, mod_name);
        return;
    }
    if (std.mem.eql(u8, cmd, "changer")) {
        try runChanger(alloc, io, root_path, mod_name);
        return;
    }

    var out_buf: [512]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    var ctx: ChangerCtx = .{ .alloc = alloc };
    var outcome: store.Outcome = undefined;

    if (std.mem.eql(u8, cmd, "install")) {
        if (args.len != 6) return error.ExpectedInstallArgs;
        ctx.token = try parseTokenHex(args[5]);
        const s = makeStore(&ctx, io, root_path, false);
        var loaded = try store.load(alloc, s, mod_name);
        const has_link = loaded != .none;
        loaded.deinit(alloc);
        outcome = if (has_link)
            try store.update(alloc, s, mod_name, args[4], null)
        else
            try store.add(alloc, s, mod_name, args[4], null);
    } else if (std.mem.eql(u8, cmd, "remove")) {
        if (args.len != 4) return error.ExpectedRemoveArgs;
        const s = makeStore(&ctx, io, root_path, false);
        outcome = try store.remove(alloc, s, mod_name);
    } else if (std.mem.eql(u8, cmd, "cleanup-version")) {
        if (args.len != 5) return error.ExpectedCleanupVersionArgs;
        const token = try parseTokenHex(args[4]);
        const s = makeStore(&ctx, io, root_path, true);
        outcome = try store.collectVersion(s, mod_name, &token);
    } else if (std.mem.eql(u8, cmd, "collect")) {
        if (args.len != 4) return error.ExpectedCollectArgs;
        const s = makeStore(&ctx, io, root_path, true);
        outcome = try store.collect(s, mod_name);
    } else {
        return error.UnknownSubcommand;
    }

    var outcome_buf: [64]u8 = undefined;
    try out.print("result {s}\n", .{formatOutcome(&outcome_buf, outcome)});
    try out.flush();
}
