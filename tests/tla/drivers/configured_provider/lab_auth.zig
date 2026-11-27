//! Runs the pure command-auth planner (`src/core/auth/command_token.zig`) for
//! the TLA+ driver in this folder. It reads one JSON operation per line from
//! the file named by its first argument and writes one JSON result per
//! operation to the file named by its second.
//!
//! The lab plays fx's I/O side: it applies each plan to the requests and
//! connections. The planner mutates a copy of a connection, and the lab keeps
//! that copy only when the plan is one it accepts, so a refused operation
//! changes nothing.
//!
//! `runs` counts the helper runs fx would have started and not yet ended, so
//! a planner that starts a second run shows.
const std = @import("std");
const command_token = @import("command_token");

const conn_names = [_][]const u8{ "c1", "c2" };
const request_names = [_][]const u8{ "r1", "r2", "r3" };
const c1 = 0;
const c2 = 1;
const r1 = 0;
const r2 = 1;
const r3 = 2;
// r1 and r2 belong to c1, r3 belongs to c2.
const request_conns = [_]usize{ c1, c1, c2 };

const unknown_op = "unknown op";
const unknown_connection = "unknown connection";
const unknown_request = "unknown request";
const unexpected_plan = "unexpected plan";
const request_not_idle = "request is not idle";
const request_not_sending = "request is not sending";
const request_not_replay = "request is not replay";
const request_not_cancellable = "request cannot be cancelled from this phase";
const printed_not_delivered = "printed did not deliver";
const run_end_not_failed = "run end did not fail waiters";

const Phase = enum { idle, waiting, sending, replay, done, failed, cancelled };
const Reason = enum { none, helper, rejected, cancelled };

const Request = struct {
    phase: Phase = .idle,
    reason: Reason = .none,
    gen: u32 = 0,
    refreshes: u8 = 0,
};

const Conn = struct {
    state: command_token.State = .{},
    valid_from: u32 = 1,
    helper_runs: u8 = 0,
};

const Lab = struct {
    conns: [conn_names.len]Conn = .{ .{}, .{} },
    requests: [request_names.len]Request = .{ .{}, .{}, .{} },
};

const Op = struct {
    op: []const u8,
    r: ?[]const u8 = null,
    c: ?[]const u8 = null,
};

const RequestView = struct {
    phase: []const u8,
    reason: []const u8,
    gen: u32,
    refreshes: u8,
};

const ConnView = struct {
    cache: u32,
    cache_expired: bool,
    runs: u8,
    waiters: u16,
    issued: u32,
    valid_from: u32,
};

const Result = struct {
    requests: struct {
        r1: RequestView,
        r2: RequestView,
        r3: RequestView,
    },
    conns: struct {
        c1: ConnView,
        c2: ConnView,
    },
    @"error": ?[]const u8 = null,
};

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn indexOf(names: []const []const u8, name: ?[]const u8) ?usize {
    const wanted = name orelse return null;
    for (names, 0..) |candidate, index| {
        if (is(candidate, wanted)) return index;
    }
    return null;
}

fn failReason(reason: command_token.Reason) Reason {
    return switch (reason) {
        .helper => .helper,
    };
}

fn helperStarted(conn: *Conn) void {
    conn.helper_runs +|= 1;
}

fn helperEnded(conn: *Conn) void {
    conn.helper_runs -|= 1;
}

fn acquire(lab: *Lab, index: usize) ?[]const u8 {
    const request = &lab.requests[index];
    const conn = &lab.conns[request_conns[index]];
    var next = conn.*;
    switch (command_token.need(&next.state)) {
        .send => |gen| {
            request.phase = .sending;
            request.gen = gen;
        },
        .wait => request.phase = .waiting,
        .start_and_wait => {
            helperStarted(&next);
            request.phase = .waiting;
        },
        .fail => |reason| {
            request.phase = .failed;
            request.reason = failReason(reason);
        },
        else => return unexpected_plan,
    }
    conn.* = next;
    return null;
}

fn need(lab: *Lab, index: usize) ?[]const u8 {
    if (lab.requests[index].phase != .idle) return request_not_idle;
    return acquire(lab, index);
}

fn replay(lab: *Lab, index: usize) ?[]const u8 {
    if (lab.requests[index].phase != .replay) return request_not_replay;
    return acquire(lab, index);
}

fn printed(lab: *Lab, conn_index: usize) ?[]const u8 {
    const conn = &lab.conns[conn_index];
    var next = conn.*;
    const delivered = switch (command_token.printed(&next.state)) {
        .deliver => |gen| gen,
        else => return printed_not_delivered,
    };
    for (&lab.requests, 0..) |*request, index| {
        if (request_conns[index] != conn_index or request.phase != .waiting) continue;
        request.phase = .sending;
        request.gen = delivered;
    }
    helperEnded(&next);
    conn.* = next;
    return null;
}

fn runEnded(lab: *Lab, conn_index: usize) ?[]const u8 {
    const conn = &lab.conns[conn_index];
    var next = conn.*;
    const failure = switch (command_token.runEnded(&next.state)) {
        .fail_waiters => |reason| failReason(reason),
        else => return run_end_not_failed,
    };
    for (&lab.requests, 0..) |*request, index| {
        if (request_conns[index] != conn_index or request.phase != .waiting) continue;
        request.phase = .failed;
        request.reason = failure;
    }
    helperEnded(&next);
    conn.* = next;
    return null;
}

fn accept(lab: *Lab, index: usize) ?[]const u8 {
    const request = &lab.requests[index];
    if (request.phase != .sending) return request_not_sending;
    request.phase = .done;
    return null;
}

fn reject(lab: *Lab, index: usize) ?[]const u8 {
    const request = &lab.requests[index];
    if (request.phase != .sending) return request_not_sending;
    const conn = &lab.conns[request_conns[index]];
    var next = conn.*;
    command_token.refused(&next.state, request.gen);
    if (request.refreshes == 0) {
        request.refreshes = 1;
        request.phase = .replay;
    } else {
        request.phase = .failed;
        request.reason = .rejected;
    }
    conn.* = next;
    return null;
}

fn revoke(lab: *Lab, conn_index: usize) void {
    const conn = &lab.conns[conn_index];
    conn.valid_from = conn.state.newest + 1;
}

fn expire(lab: *Lab, conn_index: usize) void {
    const conn = &lab.conns[conn_index];
    var next = conn.*;
    command_token.expired(&next.state, next.state.cached);
    conn.* = next;
}

fn cancel(lab: *Lab, index: usize) ?[]const u8 {
    const request = &lab.requests[index];
    if (request.phase != .waiting and request.phase != .sending and request.phase != .replay) {
        return request_not_cancellable;
    }
    const conn = &lab.conns[request_conns[index]];
    var next = conn.*;
    switch (command_token.cancelled(&next.state, request.phase == .waiting)) {
        .stop_run => helperEnded(&next),
        .none => {},
        else => return unexpected_plan,
    }
    request.phase = .cancelled;
    request.reason = .cancelled;
    conn.* = next;
    return null;
}

fn requestOp(lab: *Lab, name: []const u8, index: usize) ?[]const u8 {
    if (is(name, "need")) return need(lab, index);
    if (is(name, "replay")) return replay(lab, index);
    if (is(name, "accept")) return accept(lab, index);
    if (is(name, "reject")) return reject(lab, index);
    return cancel(lab, index);
}

fn connOp(lab: *Lab, name: []const u8, index: usize) ?[]const u8 {
    if (is(name, "printed")) return printed(lab, index);
    if (is(name, "run_ended")) return runEnded(lab, index);
    if (is(name, "revoke")) {
        revoke(lab, index);
        return null;
    }
    expire(lab, index);
    return null;
}

fn run(lab: *Lab, op: Op) ?[]const u8 {
    if (is(op.op, "walk")) {
        lab.* = .{};
        return null;
    }
    if (is(op.op, "need") or is(op.op, "replay") or is(op.op, "accept") or is(op.op, "reject") or is(op.op, "cancel")) {
        const index = indexOf(&request_names, op.r) orelse return unknown_request;
        return requestOp(lab, op.op, index);
    }
    if (is(op.op, "printed") or is(op.op, "run_ended") or is(op.op, "revoke") or is(op.op, "expire")) {
        const index = indexOf(&conn_names, op.c) orelse return unknown_connection;
        return connOp(lab, op.op, index);
    }
    return unknown_op;
}

fn requestView(request: Request) RequestView {
    return .{
        .phase = @tagName(request.phase),
        .reason = @tagName(request.reason),
        .gen = request.gen,
        .refreshes = request.refreshes,
    };
}

fn connView(conn: Conn) ConnView {
    const state = conn.state;
    return .{
        .cache = state.cached,
        .cache_expired = state.cached != 0 and state.cached_expired,
        .runs = conn.helper_runs,
        .waiters = state.waiters,
        .issued = state.newest,
        .valid_from = conn.valid_from,
    };
}

fn report(lab: *const Lab, failure: ?[]const u8) Result {
    return .{
        .requests = .{
            .r1 = requestView(lab.requests[r1]),
            .r2 = requestView(lab.requests[r2]),
            .r3 = requestView(lab.requests[r3]),
        },
        .conns = .{
            .c1 = connView(lab.conns[c1]),
            .c2 = connView(lab.conns[c2]),
        },
        .@"error" = failure,
    };
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

    var lab: Lab = .{};
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const op = try std.json.parseFromSliceLeaky(Op, scratch.allocator(), line, .{ .ignore_unknown_fields = true });
        const failure = run(&lab, op);
        try std.json.Stringify.value(report(&lab, failure), .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
