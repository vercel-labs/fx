//! Runs web_fetch hops through the real `fetch` in
//! `src/tools/web/http_fetch.zig` for the TLA+ driver in this folder. It
//! reads one JSON case per line from the file named by its first argument and
//! writes one JSON result per case to the file named by its second.
//!
//! A case is the answers a DNS lookup of fx.sh returns:
//!
//!     {"answers": ["64.239.123.65", "64:ff9b::40ef:7b41"]}
//!
//! The lab stands in only for the network edge: its resolver returns the
//! case's answers, and its connector records the addresses fetch pins and
//! answers 200 without dialing. fetch and isPublicAddress decide the rest.
//! A result names the outcome, the error fetch returned, if any, and the
//! index of each answer fetch handed to the connector:
//!
//!     {"outcome":"admitted","error":null,"pinned":[0,1],"resolver_calls":1,"connector_calls":1}
//!
//! driver.ts builds it against a copy of src/, through the module `fx_web`,
//! whose root file it writes into that copy.
const std = @import("std");
const fx_web = @import("fx_web");

const http_fetch = fx_web.http_fetch;
const url_policy = fx_web.url_policy;
const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;

const Case = struct {
    answers: []const []const u8,
};

const Result = struct {
    outcome: []const u8,
    @"error": ?[]const u8 = null,
    pinned: []const usize = &.{},
    resolver_calls: usize = 0,
    connector_calls: usize = 0,
};

const Edge = struct {
    answers: []const IpAddress,
    pinned: std.ArrayList(usize) = .empty,
    resolver_calls: usize = 0,
    connector_calls: usize = 0,
    arena: Allocator,

    fn transport(edge: *Edge) http_fetch.Transport {
        return .{
            .resolver = .{ .ctx = @ptrCast(edge), .resolve = resolve },
            .connector = .{ .ctx = @ptrCast(edge), .get = get },
        };
    }

    fn resolve(raw: *anyopaque, alloc: Allocator, _: []const u8, _: u16, _: http_fetch.FetchOptions) anyerror![]IpAddress {
        const edge: *Edge = @ptrCast(@alignCast(raw));
        edge.resolver_calls += 1;
        return alloc.dupe(IpAddress, edge.answers);
    }

    fn get(raw: *anyopaque, alloc: Allocator, target: http_fetch.PinnedTarget, _: http_fetch.FetchOptions) anyerror!http_fetch.ConnectorResponse {
        const edge: *Edge = @ptrCast(@alignCast(raw));
        edge.connector_calls += 1;
        for (target.admitted_addresses) |*pinned| {
            for (edge.answers, 0..) |*answer, index| {
                if (pinned.eql(answer)) {
                    try edge.pinned.append(edge.arena, index);
                    break;
                }
            }
        }
        return .{ .status = .ok, .body = try alloc.dupe(u8, "ok") };
    }
};

fn runCase(arena: Allocator, case: Case) !Result {
    const answers = try arena.alloc(IpAddress, case.answers.len);
    for (case.answers, answers) |text, *address| {
        address.* = IpAddress.parse(text, 443) catch return .{ .outcome = "bad_case", .@"error" = "UnparsableAnswer" };
    }

    var target = try url_policy.normalize(arena, "https://fx.sh/");
    defer target.deinit(arena);

    var edge: Edge = .{ .answers = answers, .arena = arena };
    var result = http_fetch.fetch(arena, target, .{}, edge.transport()) catch |err| {
        const outcome = switch (err) {
            error.NonPublicDnsAnswer => "refused",
            else => "error",
        };
        return .{
            .outcome = outcome,
            .@"error" = @errorName(err),
            .resolver_calls = edge.resolver_calls,
            .connector_calls = edge.connector_calls,
        };
    };
    defer result.deinit(arena);
    return .{
        .outcome = if (result == .success) "admitted" else "error",
        .pinned = edge.pinned.items,
        .resolver_calls = edge.resolver_calls,
        .connector_calls = edge.connector_calls,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    fx_web.io_mod.setIo(io);
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // driver.ts always passes the cases file and the results file.
    if (args.len != 3) return error.ExpectedCasesAndResultsPaths;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 30));
    var file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const out = &file_writer.interface;

    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const case = try std.json.parseFromSliceLeaky(Case, scratch.allocator(), line, .{ .ignore_unknown_fields = true });
        const result = try runCase(scratch.allocator(), case);
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
