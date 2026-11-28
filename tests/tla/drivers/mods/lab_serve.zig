//! Drives `src/core/mcp_host/runtime.zig`, `src/mcp/engine.zig`, `src/core/mods/pins.zig`,
//! and `src/core/mods/store.zig` under stdin/stdout line control for
//! `tests/tla/drivers/mods/driver.ts` (`serve-walk`), stepping through
//! `tests/tla/mods/ModServe.tla`.
//!
//! Subcommands:
//! - `lab_serve reader <root> <name> <--cleanup|--no-cleanup>`
//! - `lab_serve changer <root> <name>`
//!
//! Imports relative to `src/` because `driver.ts` builds it from a staged
//! copy of `src/` so `runtime.zig` mutants compile in one module graph.

const std = @import("std");
const io_mod = @import("core/shared/io.zig");
const mods = @import("core/mods/mods.zig");
const mcp_host = @import("core/mcp_host/host.zig");
const mcp_runtime = @import("core/mcp_host/runtime.zig");

const store = mods.store;
const pins = mods.pins;

const lab_lock_deadline_ms: u64 = 50;

fn readCommandLine(in_reader: *std.Io.File.Reader, buf: []u8) !?[]const u8 {
    var line_writer: std.Io.Writer = .fixed(buf);
    const n = try in_reader.interface.streamDelimiterLimit(&line_writer, '\n', .limited(buf.len));
    _ = in_reader.interface.takeByte() catch |err| switch (err) {
        error.EndOfStream => if (n == 0) return null,
        else => return err,
    };
    return std.mem.trimEnd(u8, buf[0..n], "\r");
}

const ChangerCtx = struct {
    alloc: std.mem.Allocator,
    token: [pins.token_hex_bytes]u8 = undefined,
};

fn fixedFillToken(ctx_ptr: ?*anyopaque, _: std.Io, out_hex: *[pins.token_hex_bytes]u8) void {
    const ctx: *ChangerCtx = @ptrCast(@alignCast(ctx_ptr.?));
    out_hex.* = ctx.token;
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

fn parseTokenHex(raw: []const u8) ![pins.token_hex_bytes]u8 {
    if (raw.len != pins.token_hex_bytes or !pins.isLowerHex(raw)) return error.InvalidToken;
    var out: [pins.token_hex_bytes]u8 = undefined;
    @memcpy(&out, raw);
    return out;
}

fn makeStore(ctx: *ChangerCtx, _: std.Io, root_path: []const u8) store.Store {
    var ops = mods.realOps();
    ops.ctx = ctx;
    ops.lock_deadline_ms = lab_lock_deadline_ms;
    ops.fill_token = fixedFillToken;
    ops.collect_after_switch = false;
    return .{
        .root_path = root_path,
        .ops = ops,
    };
}

fn probePin(io: std.Io, root_path: []const u8, mod_name: []const u8, token: [pins.token_hex_bytes]u8) !bool {
    var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{
        .iterate = false,
        .follow_symlinks = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer root_dir.close(io);

    var pins_dir = (try pins.openPrivatePinsDirIfPresent(root_dir, io)) orelse return false;
    defer pins_dir.close(io);

    var folder_buf: [mods.manifest.max_name_bytes + 1 + pins.token_hex_bytes]u8 = undefined;
    const folder_name = pins.formatVersionFolder(&folder_buf, mod_name, &token);
    switch (try pins.tryAcquireExclusive(io, pins_dir, folder_name)) {
        .busy => return true,
        .acquired => |lf| {
            var file = lf;
            file.unlock(io);
            file.close(io);
            return false;
        },
    }
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

        if (std.mem.eql(u8, cmd, "probe-pin")) {
            const tok_raw = it.next() orelse return error.ExpectedProbePinArgs;
            const token = try parseTokenHex(tok_raw);
            const busy = try probePin(io, root_path, mod_name, token);
            try out.writeAll(if (busy) "pin busy\n" else "pin free\n");
            try out.flush();
            continue;
        }

        var outcome: store.Outcome = undefined;
        if (std.mem.eql(u8, cmd, "install")) {
            const src = it.next() orelse return error.ExpectedInstallArgs;
            const tok = it.next() orelse return error.ExpectedInstallArgs;
            ctx.token = try parseTokenHex(tok);
            const s = makeStore(&ctx, io, root_path);
            var loaded = try store.load(alloc, s, mod_name);
            const has_link = loaded != .none;
            loaded.deinit(alloc);
            outcome = if (has_link)
                try store.update(alloc, s, mod_name, src, null)
            else
                try store.add(alloc, s, mod_name, src, null);
        } else if (std.mem.eql(u8, cmd, "remove")) {
            const s = makeStore(&ctx, io, root_path);
            outcome = try store.remove(alloc, s, mod_name);
        } else if (std.mem.eql(u8, cmd, "cleanup-version")) {
            const tok = it.next() orelse return error.ExpectedCleanupVersionArgs;
            const token = try parseTokenHex(tok);
            const s = makeStore(&ctx, io, root_path);
            outcome = try store.collectVersion(s, mod_name, &token);
        } else if (std.mem.eql(u8, cmd, "collect")) {
            const s = makeStore(&ctx, io, root_path);
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

const CallJob = struct {
    alloc: std.mem.Allocator,
    runtime: *mcp_runtime.Runtime,
    server: []u8,
    tool: []u8,
    outcome_buf: [128]u8 = undefined,
    outcome_len: usize = 0,

    fn run(self: *CallJob) void {
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const res = self.runtime.call(a, self.server, self.tool, "{}", null, null) catch |err| {
            const slice = std.mem.print(&self.outcome_buf, "err:{s}", .{@errorName(err)}) catch "err";
            self.outcome_len = slice.len;
            return;
        };
        const slice = switch (res) {
            .result => |r| std.mem.print(&self.outcome_buf, "ok:{s}", .{if (r.is_error) "err" else "true"}) catch "ok",
            .failure => |f| std.mem.print(&self.outcome_buf, "failure:{d}", .{f.code}) catch "failure",
            .ended => |e| std.mem.print(&self.outcome_buf, "ended:{s}", .{@tagName(e.outcome)}) catch "ended",
            .unknown_server => "unknown_server",
        };
        self.outcome_len = slice.len;
    }

    fn deinit(self: *CallJob) void {
        self.alloc.free(self.server);
        self.alloc.free(self.tool);
        self.alloc.destroy(self);
    }
};

fn pinExactToken(
    alloc: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    mod_name: []const u8,
    token: [pins.token_hex_bytes]u8,
) !mods.ModPins {
    switch (try pins.pinVersion(alloc, root_path, mod_name, token, mods.realPinOps())) {
        .pinned => |p| {
            var mutable_p = p;
            errdefer mutable_p.release(alloc, io);
            const slice = try alloc.alloc(pins.Pin, 1);
            slice[0] = mutable_p;
            return .{
                .io = io,
                .pins = slice,
            };
        },
        else => return .{ .io = io },
    }
}

fn ensureServersRestored(
    alloc: std.mem.Allocator,
    io: std.Io,
    rt: *mcp_runtime.Runtime,
    inherited: *const std.process.Environ.Map,
    root_path: []const u8,
    mod_name: []const u8,
    use_cleanup: bool,
    current_token: ?[pins.token_hex_bytes]u8,
) !void {
    const tok = current_token orelse return;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const statuses = try rt.statuses(arena_state.allocator());
    if (statuses.len > 0) return;

    var mod_pins = try pinExactToken(alloc, io, root_path, mod_name, tok);
    defer mod_pins.deinit(alloc);
    if (mod_pins.pins.len == 0) return;

    var loaded_mods = try mods.loadModMcpServersFromPins(alloc, &mod_pins, &.{});
    defer loaded_mods.deinit(alloc);
    _ = try rt.reloadWithPins(
        loaded_mods.configs.items,
        inherited,
        &mod_pins,
        if (use_cleanup) root_path else null,
    );
}

fn runReader(
    alloc: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    mod_name: []const u8,
    use_cleanup: bool,
) !void {
    var in_buf: [512]u8 = undefined;
    var in_reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    var inherited = try io_mod.cloneEnvironMap(alloc);
    defer inherited.deinit();

    var rt: mcp_runtime.Runtime = undefined;
    try rt.start(alloc, io, &.{}, &inherited, .{
        .client_version = "0.0.0-lab",
        .credentials = .{ .detect = root_path },
        .workspace_root = root_path,
        .idle_ms = 0,
        .mod_pins = null,
        .mods_root = if (use_cleanup) root_path else null,
    });
    defer rt.deinit();

    var current_token: ?[pins.token_hex_bytes]u8 = null;

    var call_thread: ?std.Thread = null;
    var call_job: ?*CallJob = null;
    defer {
        if (call_thread) |t| t.join();
        if (call_job) |j| j.deinit();
    }

    try out.writeAll("ready\n");
    try out.flush();

    var cmd_buf: [512]u8 = undefined;
    while (try readCommandLine(&in_reader, &cmd_buf)) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse continue;

        if (std.mem.eql(u8, cmd, "reload")) {
            var mod_pins = try mods.loadModPins(alloc, root_path);
            defer mod_pins.deinit(alloc);

            var next_token: ?[pins.token_hex_bytes]u8 = null;
            for (mod_pins.pins) |p| {
                if (std.mem.eql(u8, p.name, mod_name)) {
                    next_token = p.token;
                    break;
                }
            }

            var loaded_mods = try mods.loadModMcpServersFromPins(alloc, &mod_pins, &.{});
            defer loaded_mods.deinit(alloc);

            _ = try rt.reloadWithPins(
                loaded_mods.configs.items,
                &inherited,
                &mod_pins,
                if (use_cleanup) root_path else null,
            );

            current_token = next_token;

            if (next_token) |tok| {
                try out.print("reloaded {s}\n", .{&tok});
            } else {
                try out.writeAll("reloaded none\n");
            }
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "stop_server")) {
            var mod_pins: mods.ModPins = if (current_token) |tok|
                try pinExactToken(alloc, io, root_path, mod_name, tok)
            else
                .{ .io = io };
            defer mod_pins.deinit(alloc);

            _ = try rt.reloadWithPins(
                &.{},
                &inherited,
                &mod_pins,
                if (use_cleanup) root_path else null,
            );
            try out.writeAll("stopped\n");
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "start_server")) {
            const srv_name = it.next() orelse "srv";
            try ensureServersRestored(alloc, io, &rt, &inherited, root_path, mod_name, use_cleanup, current_token);

            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const res = try rt.tools(arena_state.allocator(), srv_name, null);
            switch (res) {
                .tools => |tools_list| try out.print("started {d}\n", .{tools_list.len}),
                .needs_login => try out.writeAll("start_err needs_login\n"),
                .failed => try out.writeAll("start_err failed\n"),
                .unknown_server => try out.writeAll("start_err unknown_server\n"),
            }
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "start_call")) {
            const srv_name = it.next() orelse "srv";
            const tool_name = it.next() orelse "slow";
            if (call_thread) |t| {
                t.join();
                call_thread = null;
            }
            if (call_job) |j| {
                j.deinit();
                call_job = null;
            }
            try ensureServersRestored(alloc, io, &rt, &inherited, root_path, mod_name, use_cleanup, current_token);

            const job = try alloc.create(CallJob);
            errdefer alloc.destroy(job);
            const srv_dupe = try alloc.dupe(u8, srv_name);
            errdefer alloc.free(srv_dupe);
            const tool_dupe = try alloc.dupe(u8, tool_name);
            errdefer alloc.free(tool_dupe);
            job.* = .{
                .alloc = alloc,
                .runtime = &rt,
                .server = srv_dupe,
                .tool = tool_dupe,
            };
            call_job = job;
            call_thread = try std.Thread.spawn(.{}, CallJob.run, .{job});
            try out.print("calling {s}\n", .{srv_name});
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "wait_call")) {
            if (call_thread) |t| {
                t.join();
                call_thread = null;
            }
            if (call_job) |j| {
                try out.print("call_done {s}\n", .{j.outcome_buf[0..j.outcome_len]});
                j.deinit();
                call_job = null;
            } else {
                try out.writeAll("call_done none\n");
            }
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "sweep")) {
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            _ = try rt.statuses(arena_state.allocator());
            try out.writeAll("swept\n");
            try out.flush();
        } else if (std.mem.eql(u8, cmd, "quit")) {
            break;
        } else {
            return error.UnknownReaderCommand;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    io_mod.setIo(init.io);
    io_mod.setEnvironMap(init.environ_map);
    const alloc = std.heap.c_allocator;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) return error.MissingArgs;

    const cmd = args[1];
    const root_path = args[2];
    const mod_name = args[3];

    if (std.mem.eql(u8, cmd, "reader")) {
        const use_cleanup = args.len >= 5 and std.mem.eql(u8, args[4], "--cleanup");
        try runReader(alloc, init.io, root_path, mod_name, use_cleanup);
    } else if (std.mem.eql(u8, cmd, "changer")) {
        try runChanger(alloc, init.io, root_path, mod_name);
    } else {
        return error.UnknownSubcommand;
    }
}
