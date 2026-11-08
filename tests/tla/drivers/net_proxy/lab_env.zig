//! Drives the proxy variables' parser (`src/core/shared/net_proxy.zig`) for the
//! TLA+ driver in this folder, along `tests/tla/net_proxy/NetProxyEnv.tla`. It
//! reads one JSON operation per line from the file named by its first argument
//! and writes one JSON result per operation to the file named by its second.
//!
//! The environment is a set of buffers the lab owns and overwrites in place,
//! which is what a host program that sets a variable again does to the strings
//! libc handed out earlier: a parser that kept a slice of one reads the new
//! bytes, or freed ones. `env_snap` has the real `parse` read them, and every
//! result says what the snapshot holds now, read live from its memory through
//! the real `route`, so a snapshot that borrowed the environment shows it.
//! `env_parse` reads a proxy URL of one host class and says whether the real
//! parser took it and, when it did not, which reason its message names.
const std = @import("std");
const net_proxy = @import("net_proxy");

const Op = struct {
    op: []const u8,
    rm: ?[]const u8 = null,
    up: ?[]const u8 = null,
    lo: ?[]const u8 = null,
    hs: ?[]const u8 = null,
    ph: ?[]const u8 = null,
    np: ?[]const u8 = null,
    cls: ?[]const u8 = null,
};

const Obs = struct { http: []const u8, host: []const u8, internal: []const u8 };

const Result = struct {
    snapped: bool,
    s_http: []const u8,
    s_https: []const u8,
    s_host: []const u8,
    obs: []const Obs,
    parsed: bool,
    accepted: bool,
    reason: []const u8,
    @"error": ?[]const u8 = null,
};

/// One environment variable's string, overwritten in place by a set.
const Var = struct {
    buf: [96]u8 = @splat(0),
    len: usize = 0,
    present: bool = false,

    fn set(v: *Var, text: []const u8) void {
        // The old bytes past the new text are cleared, as a shorter value in
        // the same storage leaves them.
        @memset(&v.buf, 0);
        @memcpy(v.buf[0..text.len], text);
        v.len = text.len;
        v.present = true;
    }

    fn unset(v: *Var) void {
        v.* = .{};
    }

    fn get(v: *const Var) ?[]const u8 {
        return if (v.present) v.buf[0..v.len] else null;
    }
};

const Lab = struct {
    rm: Var = .{},
    up: Var = .{},
    lo: Var = .{},
    hs: Var = .{},
    np: Var = .{},
    ph: []const u8 = "p1",
    snapshot: net_proxy.Snapshot = undefined,
    parse_snapshot: net_proxy.Snapshot = undefined,
    snapped: bool = false,
    obs: [8]Obs = undefined,
    obs_len: usize = 0,
    parsed: bool = false,
    accepted: bool = false,
    reason: []const u8 = "none",
    cls: []const u8 = "letters",
};

const LabEnv = struct {
    lab: *const Lab,
    pub fn getenv(e: LabEnv, name: []const u8) ?[]const u8 {
        if (is(name, "REQUEST_METHOD")) return e.lab.rm.get();
        if (is(name, "HTTP_PROXY")) return e.lab.up.get();
        if (is(name, "http_proxy")) return e.lab.lo.get();
        if (is(name, "HTTPS_PROXY")) return e.lab.hs.get();
        if (is(name, "NO_PROXY")) return e.lab.np.get();
        return null;
    }
};

const ClassEnv = struct {
    url: []const u8,
    pub fn getenv(e: ClassEnv, name: []const u8) ?[]const u8 {
        return if (is(name, "HTTPS_PROXY")) e.url else null;
    }
};

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn proxyUrl(host: []const u8, buf: []u8) ![]const u8 {
    return std.mem.print(buf, "http://{s}.example:3128", .{host});
}

fn noProxyText(np: []const u8) []const u8 {
    return if (is(np, "lists")) "internal.example,other.example" else "unrelated.example";
}

/// The name a tunnel host stands for in the model: p1, p2, or "?" for bytes
/// that are neither, as a snapshot that read freed memory has.
fn hostName(host: []const u8) []const u8 {
    if (is(host, "p1.example")) return "p1";
    if (is(host, "p2.example")) return "p2";
    return "?";
}

/// Which variable a plain http connection's proxy came from.
fn httpUsed(lab: *const Lab) []const u8 {
    if (!lab.snapped) return "none";
    return switch (net_proxy.route(&lab.snapshot, "api.example.test", 80, .http)) {
        .tunnel => |p| if (is(p.host, "lower.example")) "lower" else if (is(p.host, "upper.example")) "upper" else "?",
        .direct => "none",
        .refuse => "?",
    };
}

fn httpsHost(lab: *const Lab) []const u8 {
    if (!lab.snapped) return "none";
    return switch (net_proxy.route(&lab.snapshot, "api.example.test", 443, .https)) {
        .tunnel => |p| hostName(p.host),
        .direct => "none",
        .refuse => "?",
    };
}

fn internalRoute(lab: *const Lab) []const u8 {
    return switch (net_proxy.route(&lab.snapshot, "internal.example", 443, .https)) {
        .tunnel => "tunnel",
        .direct => "direct",
        .refuse => "refuse",
    };
}

/// The reason a refusal's message names, in the model's words.
fn reasonOf(text: []const u8) []const u8 {
    if (std.mem.find(u8, text, " has no host name") != null) return "no_host";
    if (std.mem.find(u8, text, " has a host name fx cannot use") != null) return "bad_host";
    if (std.mem.find(u8, text, " has a port fx cannot use") != null) return "bad_port";
    if (std.mem.find(u8, text, " is not a proxy URL fx can read") != null) return "unreadable";
    return "unknown";
}

fn run(lab: *Lab, op: Op) !void {
    if (is(op.op, "env_reset")) {
        lab.* = .{};
        lab.ph = op.ph orelse return error.ResetWithoutHost;
        if (is(op.rm orelse "unset", "set")) lab.rm.set("GET");
        if (is(op.up orelse "unset", "set")) lab.up.set("http://upper.example:80");
        if (is(op.lo orelse "unset", "set")) lab.lo.set("http://lower.example:80");
        var url: [64]u8 = undefined;
        if (is(op.hs orelse "unset", "set")) lab.hs.set(try proxyUrl(lab.ph, &url));
        lab.np.set(noProxyText(op.np orelse "lists"));
        lab.cls = op.cls orelse return error.ResetWithoutClass;
    } else if (is(op.op, "env_snap")) {
        if (lab.snapped) return error.SnapTwice;
        net_proxy.parse(&lab.snapshot, LabEnv{ .lab = lab });
        lab.snapped = true;
    } else if (is(op.op, "env_set_host")) {
        // The host program sets HTTPS_PROXY again, to the other proxy.
        lab.ph = op.ph orelse return error.SetWithoutHost;
        var url: [64]u8 = undefined;
        if (lab.hs.present) lab.hs.set(try proxyUrl(lab.ph, &url));
    } else if (is(op.op, "env_set_no_proxy")) {
        lab.np.set(noProxyText(op.np orelse return error.SetWithoutNoProxy));
    } else if (is(op.op, "env_route")) {
        if (!lab.snapped) return error.RouteBeforeSnapshot;
        const o: Obs = .{ .http = httpUsed(lab), .host = httpsHost(lab), .internal = internalRoute(lab) };
        for (lab.obs[0..lab.obs_len]) |have| {
            if (is(have.http, o.http) and is(have.host, o.host) and is(have.internal, o.internal)) return;
        }
        lab.obs[lab.obs_len] = o;
        lab.obs_len += 1;
    } else if (is(op.op, "env_parse")) {
        if (lab.parsed) return error.ParseTwice;
        const url = if (is(lab.cls, "letters")) "http://squid-proxy:3128" else if (is(lab.cls, "underscore")) "http://squid_proxy:3128" else if (is(lab.cls, "bang")) "http://bad_host!:3128" else if (is(lab.cls, "no_host")) "http:///path" else "http://proxy:99999";
        net_proxy.parse(&lab.parse_snapshot, ClassEnv{ .url = url });
        lab.parsed = true;
        switch (net_proxy.route(&lab.parse_snapshot, "x.example", 443, .https)) {
            .tunnel => {
                lab.accepted = true;
                lab.reason = "none";
            },
            .refuse => |refusal| {
                var buf: [256]u8 = undefined;
                lab.accepted = false;
                lab.reason = reasonOf(net_proxy.Failure.refusal(refusal, "x.example", 443).text(&buf));
            },
            .direct => return error.ParsedUrlWentDirect,
        }
    } else return error.UnknownOperation;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // driver.ts always passes the operations file and the results file.
    if (args.len != 3) return error.ExpectedOpsAndResultsPaths;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 30));
    var file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const out = &file_writer.interface;

    const lab = try arena.create(Lab);
    lab.* = .{};
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const op = try std.json.parseFromSliceLeaky(Op, scratch.allocator(), line, .{ .ignore_unknown_fields = true });
        const failure: ?[]const u8 = if (run(lab, op)) |_| null else |err| @errorName(err);
        const result: Result = .{
            .snapped = lab.snapped,
            .s_http = httpUsed(lab),
            .s_https = if (lab.snapped and lab.snapshot.https == .proxy) "set" else "none",
            .s_host = httpsHost(lab),
            .obs = lab.obs[0..lab.obs_len],
            .parsed = lab.parsed,
            .accepted = lab.accepted,
            .reason = lab.reason,
            .@"error" = failure,
        };
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
