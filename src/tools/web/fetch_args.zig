const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const url_policy = @import("url_policy.zig");

const Allocator = std.mem.Allocator;

const whitespace = " \t\r\n";

pub const Input = struct {
    url: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.url);
        self.* = .{ .url = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_fetch arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_fetch arguments must be an object") };
    }

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "url")) continue;
        return .{ .failure = try ctx.allocator.print("web_fetch field \"{s}\" is not allowed", .{entry.key_ptr.*}) };
    }

    const url_value = parsed.value.object.get("url") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_fetch field \"url\" is required") };
    };
    if (url_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_fetch field \"url\" must be a string") };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    const url = try ctx.allocator.dupe(u8, url_value.string);
    errdefer ctx.allocator.free(url);
    input.* = .{
        .url = url,
    };
    errdefer input.deinit(ctx.allocator);

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const trimmed = std.mem.trim(u8, input.url, whitespace);
    if (!std.mem.eql(u8, input.url, trimmed)) {
        const owned = try ctx.allocator.dupe(u8, trimmed);
        ctx.allocator.free(input.url);
        input.url = owned;
    }

    var normalized = url_policy.normalize(ctx.allocator, input.url) catch |err| {
        return try ctx.allocator.dupe(u8, urlValidationMessage(err));
    };
    defer normalized.deinit(ctx.allocator);
    if (!std.mem.eql(u8, input.url, normalized.retrieval_url)) {
        const owned = try ctx.allocator.dupe(u8, normalized.retrieval_url);
        ctx.allocator.free(input.url);
        input.url = owned;
    }

    return null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn urlValidationMessage(err: url_policy.Error) []const u8 {
    return switch (err) {
        error.EmptyUrl => "web_fetch field \"url\" must not be empty",
        error.UrlTooLong => "web_fetch field \"url\" must be at most 2000 bytes",
        error.UnsupportedScheme => "web_fetch url must start with http:// or https://",
        error.MissingHost => "web_fetch url must include a host",
        error.CredentialedUrl => "web_fetch refuses credential-bearing URLs",
        error.NonPublicAddress,
        error.SingleLabelHost,
        => "web_fetch only fetches known public HTTP(S) URLs",
        error.MalformedPercentEncoding,
        error.PercentEncodedHost,
        error.UnicodeHost,
        error.ControlByte,
        error.InvalidPort,
        error.InvalidIpv4,
        error.ScopeIdRejected,
        error.MalformedHost,
        error.MalformedLocation,
        error.PortChanged,
        error.ProtocolChanged,
        error.RequestTargetWhitespace,
        error.OutOfMemory,
        error.WriteFailed,
        => "web_fetch url is malformed",
    };
}
