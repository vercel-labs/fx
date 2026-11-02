const std = @import("std");
const vision_contracts = @import("../../core/agent/runtime/vision_contracts.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = vision_contracts.VisionRequest;

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const request = vision_contracts.parse_vision_request(ctx.allocator, args_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |invalid| return .{ .failure = try ctx.allocator.print(
            "vision arguments are invalid: {s}. {s}",
            .{ @errorName(invalid), requestFix(invalid) },
        ) },
    };
    errdefer request.deinit(ctx.allocator);

    const input = try ctx.allocator.create(Input);
    input.* = request;
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

/// What to change, so a model that repeats a rejected call learns why.
fn requestFix(err: vision_contracts.VisionRequestError) []const u8 {
    return switch (err) {
        error.InvalidVisionJson, error.InvalidVisionRequest => "Send focus and exactly one of paths or image_ids, each a list.",
        error.EmptyImageIds, error.EmptyPaths => "List at least one image.",
        error.InvalidImageId => "Image ids are positive integers.",
        error.DuplicateImageId, error.DuplicateImagePath => "List each image once.",
        error.InvalidImagePath => "Each path must be a non-empty file path.",
        error.EmptyFocus => "Say what to look for in focus.",
        error.FocusTooLong => "Shorten focus.",
    };
}

fn inputDeinit(raw: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(raw));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.vision_provider orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "Vision is unavailable in this runtime.") };
    };
    return provider.execute(ctx, input);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "vision decode failure says how to fix the call" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"image_ids\":[1],\"paths\":[\"a.png\"],\"focus\":\"read it\"}");
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
            try std.testing.expectEqualStrings(
                "vision arguments are invalid: InvalidVisionRequest. Send focus and exactly one of paths or image_ids, each a list.",
                failure,
            );
        },
    }
}
