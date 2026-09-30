const std = @import("std");

pub const Request = struct {
    payload: []const u8,
    api_key: []const u8,
    team: ?[]const u8 = null,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp = null,
};

pub const Response = struct {
    body: []u8,
    pub fn deinit(self: *Response, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const EvaluateFn = *const fn (?*anyopaque, std.mem.Allocator, Request) anyerror!Response;
