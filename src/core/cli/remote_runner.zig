const std = @import("std");
const acp_runner = @import("acp_runner.zig");

const Allocator = std.mem.Allocator;

pub const ServeOptions = struct {
    listen: []const u8,
    tailscale_capability: []const u8,
};

pub const AttachOptions = struct {
    endpoint: []const u8,
    session_id: []const u8,
    observe: bool = false,
};

pub const ServeFn = *const fn (?*anyopaque, Allocator, acp_runner.Config, ServeOptions) anyerror!void;
pub const AttachFn = *const fn (?*anyopaque, Allocator, AttachOptions) anyerror!void;

pub const Runner = struct {
    context: ?*anyopaque = null,
    serve_fn: ServeFn = unavailableServe,
    attach_fn: AttachFn = unavailableAttach,

    pub fn serve(self: Runner, alloc: Allocator, cfg: acp_runner.Config, options: ServeOptions) !void {
        return self.serve_fn(self.context, alloc, cfg, options);
    }

    pub fn attach(self: Runner, alloc: Allocator, options: AttachOptions) !void {
        return self.attach_fn(self.context, alloc, options);
    }
};

fn unavailableServe(_: ?*anyopaque, _: Allocator, _: acp_runner.Config, _: ServeOptions) anyerror!void {
    return error.RemoteServeUnavailable;
}

fn unavailableAttach(_: ?*anyopaque, _: Allocator, _: AttachOptions) anyerror!void {
    return error.RemoteAttachUnavailable;
}
