//! A session host's jobs: the registry with its shell and fleet sources,
//! and the async-result notice the host hands to the agent loop when jobs
//! settle with nobody waiting.
//!
//! Delivery follows proto: a notice steers a running turn at its next safe
//! boundary without cutting a streaming reply short, and wakes an idle
//! session with a turn of its own (D111).
const std = @import("std");
const jobs = @import("jobs.zig");
const io_mod = @import("../shared/io.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const result_commit = @import("../tooling/result_commit.zig");
const turn_jobs = @import("../subagent/turn_jobs.zig");
const Allocator = std.mem.Allocator;

pub const Host = struct {
    registry: jobs.Registry,
    shell: jobs.shell_source.Source,
    turns: jobs.turn_source.Source,

    /// `self` must not move afterwards: the registry points at its sources.
    pub fn init(
        self: *Host,
        alloc: Allocator,
        executions: *managed_execution.Runtime,
        turn_runtime: ?*const ?*turn_jobs.Runtime,
    ) void {
        self.* = .{
            .registry = jobs.Registry.init(alloc),
            .shell = .{ .runtime = executions },
            .turns = jobs.turn_source.Source.init(alloc, turn_runtime),
        };
        self.registry.addSource(self.shell.source());
        self.registry.addSource(self.turns.source());
    }

    pub fn deinit(self: *Host) void {
        self.registry.deinit();
        self.turns.deinit();
        self.* = undefined;
    }

    pub fn runningCount(self: *Host) usize {
        var arena_state = std.heap.ArenaAllocator.init(self.registry.alloc);
        defer arena_state.deinit();
        return self.registry.runningCount(arena_state.allocator());
    }

    /// The notice for jobs that settled with nobody waiting, or null. The
    /// caller hands `text` to the agent loop, then commits the notice, or
    /// releases it when the loop refused it so a later tick tries again.
    pub fn takeNotice(self: *Host, arena: Allocator) !?Notice {
        const settled = try self.registry.takeDeliveries(arena);
        if (settled.len == 0) return null;
        errdefer for (settled) |item| item.token.cancel();
        const built = (try jobs.notice.build(arena, settled, io_mod.milliTimestamp())).?;
        const tokens = try arena.alloc(result_commit.Token, built.used);
        for (settled[0..built.used], tokens) |item, *token| token.* = item.token;
        for (settled[built.used..]) |item| item.token.cancel();
        return .{ .text = built.text, .tokens = tokens };
    }
};

pub const Notice = struct {
    text: []const u8,
    tokens: []const result_commit.Token,

    pub fn commit(self: Notice) void {
        for (self.tokens) |token| token.commit() catch {};
    }

    pub fn release(self: Notice) void {
        for (self.tokens) |token| token.cancel();
    }
};
