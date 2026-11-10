//! Runs web_fetch's own fetch (`src/tools/web/http_fetch.zig`) for the TLA+ driver
//! in this folder, along `tests/tla/net_proxy/NetProxyCallers.tla`, against the
//! proxy that HTTPS_PROXY names. The driver starts the proxy, so a proxy can
//! refuse one address and open a tunnel for another, which a run of the built fx
//! cannot do: it needs a host name with two admitted addresses, and so a resolver.
//!
//! The lab calls the real `http_fetch.fetch` the way `src/tools/web/fetch.zig`
//! does (clear the held proxy failure, fetch, take the sentence for the error the
//! fetch ended with), with one difference: the resolver answers with the two
//! public addresses 93.184.216.34 and 93.184.216.35, so the public-address rule
//! admits both and the dial tries them in order. The proxy is the only thing it
//! reaches: CONNECT names those addresses and the proxy never forwards them.
//!
//! driver.ts builds it inside a copy of `src/`, as `src/_lab_fetch.zig`, because
//! http_fetch.zig imports its neighbours by relative path.
//!
//! Usage: lab_fetch <rounds> <deadline_ms> <open_files>
//! Each round is one fetch with a deadline of `deadline_ms` from its start, with
//! at most `open_files` open files allowed to the process, so a dial that leaks a
//! socket ends in a descriptor-limit error within a few rounds. It prints one JSON
//! line per round: the error name the fetch ended with (null for a success), the
//! sentence web_fetch would show for that error (null when none), and the time.
const std = @import("std");
const io_mod = @import("core/shared/io.zig");
const net_proxy_io = @import("core/shared/net_proxy_io.zig");
const http_fetch = @import("tools/web/http_fetch.zig");
const url_policy = @import("tools/web/url_policy.zig");

const IpAddress = std.Io.net.IpAddress;

var resolver_ctx: u8 = 0;

fn resolveTwoPublicAddresses(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, port: u16, _: http_fetch.FetchOptions) anyerror![]IpAddress {
    const out = try alloc.alloc(IpAddress, 2);
    out[0] = .{ .ip4 = .{ .bytes = .{ 93, 184, 216, 34 }, .port = port } };
    out[1] = .{ .ip4 = .{ .bytes = .{ 93, 184, 216, 35 }, .port = port } };
    return out;
}

const Round = struct {
    round: usize,
    @"error": ?[]const u8,
    shown: ?[]const u8,
    ms: i64,
};

fn nowMillis() i64 {
    const ts = std.Io.Clock.awake.now(io_mod.getIo());
    return @intCast(@divFloor(ts.nanoseconds, 1_000_000));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;
    const arena = init.arena.allocator();
    io_mod.setIo(io);
    io_mod.setEnvironMap(init.environ_map);

    const args = try init.minimal.args.toSlice(arena);
    // driver.ts always passes the rounds, the deadline, and the open-file limit.
    if (args.len != 4) return error.ExpectedRoundsDeadlineAndOpenFiles;
    const rounds = try std.fmt.parseInt(usize, args[1], 10);
    const deadline_ms = try std.fmt.parseInt(i64, args[2], 10);
    const open_files = try std.fmt.parseInt(u64, args[3], 10);
    const old_limit = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = @min(old_limit.cur, open_files), .max = old_limit.max });

    const transport: http_fetch.Transport = .{
        .resolver = .{ .ctx = @ptrCast(&resolver_ctx), .resolve = resolveTwoPublicAddresses },
        .connector = http_fetch.defaultTransport().connector,
    };
    for (0..rounds) |round| {
        var target = try url_policy.normalize(alloc, "https://public.example/docs");
        defer target.deinit(alloc);
        // fetch.zig clears what an earlier call left before it fetches.
        net_proxy_io.clearRequestFailure();
        const started = nowMillis();
        var shown_buf: [512]u8 = undefined;
        var line: Round = .{ .round = round, .@"error" = null, .shown = null, .ms = 0 };
        if (http_fetch.fetch(alloc, target, .{ .deadline = .{ .deadline_ms = started + deadline_ms } }, transport)) |result| {
            var owned = result;
            owned.deinit(alloc);
        } else |err| {
            line.@"error" = @errorName(err);
            line.shown = net_proxy_io.takeRequestFailure(err, &shown_buf);
        }
        line.ms = nowMillis() - started;

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.json.Stringify.value(line, .{}, &out.writer);
        try out.writer.writeByte('\n');
        try std.Io.File.stdout().writeStreamingAll(io, out.written());
    }
}
