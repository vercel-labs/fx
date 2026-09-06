const std = @import("std");
const versions = @import("../core/gateway/provider_versions.zig");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const lookup_timeout_ms = 3000;
const max_response_bytes = 64 * 1024;

pub fn resolve(
    alloc: Allocator,
    provider: versions.Provider,
    cancel_flag: *std.atomic.Value(bool),
    outer_deadline: ?std.Io.Clock.Timestamp,
) versions.Error!versions.Version {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const override_name = switch (provider) {
        .codex => "FX_E2E_CODEX_CLIENT_VERSION",
        .grok => "FX_E2E_GROK_CLIENT_VERSION",
    };
    if (io_mod.getenv(override_name)) |value| {
        return versions.Version.parse(value) orelse error.ProviderVersionUnavailable;
    }
    var context = LookupContext{ .cancel_flag = cancel_flag, .outer_deadline = outer_deadline };
    return versions.resolve(alloc, provider, .{ .context = &context, .fetch = fetch });
}

const LookupContext = struct {
    cancel_flag: *std.atomic.Value(bool),
    outer_deadline: ?std.Io.Clock.Timestamp,
};

fn fetch(raw: ?*anyopaque, alloc: Allocator, provider: versions.Provider) versions.Error!versions.Version {
    const context: *LookupContext = @ptrCast(@alignCast(raw.?));
    const override_name = switch (provider) {
        .codex => "FX_E2E_CODEX_VERSION_URL",
        .grok => "FX_E2E_GROK_VERSION_URL",
    };
    const url = if (io_mod.getenv(override_name)) |value| blk: {
        if (!gateway_client.isLoopbackHttpUrl(value)) return error.ProviderVersionUnavailable;
        break :blk value;
    } else switch (provider) {
        .codex => "https://registry.npmjs.org/@openai/codex/latest",
        .grok => "https://x.ai/cli/stable",
    };
    var deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(lookup_timeout_ms),
    });
    if (context.outer_deadline) |outer| {
        if (std.Io.Clock.Timestamp.compare(outer, .lt, deadline)) deadline = outer;
    }
    var operation = LookupOperation{ .alloc = alloc, .url = url };
    var response = gateway_client.runBoundedHttpOperation(Response, alloc, context.cancel_flag, deadline, &operation) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return error.Cancelled;
        debug_trace.logf("models", "provider version lookup failed provider={t} err={s}", .{ provider, @errorName(err) });
        return error.ProviderVersionUnavailable;
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        debug_trace.logf("models", "provider version lookup rejected provider={t} status={d}", .{ provider, @intFromEnum(response.status) });
        return error.ProviderVersionUnavailable;
    }
    return parseResponse(alloc, provider, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("models", "provider version metadata invalid provider={t}", .{provider});
        return error.ProviderVersionUnavailable;
    };
}

const Response = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Response, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

const LookupOperation = struct {
    alloc: Allocator,
    url: []const u8,

    pub fn run(self: *LookupOperation) !Response {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const buffer = try self.alloc.alloc(u8, max_response_bytes + 1);
        defer self.alloc.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        const result = try client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .redirect_behavior = .unhandled,
            .response_writer = &writer,
        });
        if (writer.buffered().len > max_response_bytes) return error.ProviderVersionResponseTooLarge;
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, writer.buffered()) };
    }
};

fn parseResponse(alloc: Allocator, provider: versions.Provider, body: []const u8) !versions.Version {
    if (body.len > max_response_bytes) return error.ProviderVersionResponseTooLarge;
    if (provider == .grok) return versions.Version.parse(body) orelse error.InvalidProviderVersion;
    const Release = struct { version: []const u8 };
    const parsed = try std.json.parseFromSlice(Release, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return versions.Version.parse(parsed.value.version) orelse error.InvalidProviderVersion;
}

test "provider version metadata parses the two upstream release formats" {
    const codex = try parseResponse(std.testing.allocator, .codex, "{\"version\":\"0.153.1\",\"name\":\"@openai/codex\"}");
    try std.testing.expectEqualStrings("0.153.1", codex.slice());
    const grok = try parseResponse(std.testing.allocator, .grok, "1.0.13\n");
    try std.testing.expectEqualStrings("1.0.13", grok.slice());
    try std.testing.expectError(error.InvalidProviderVersion, parseResponse(std.testing.allocator, .codex, "{\"version\":\"bad\"}"));
    try std.testing.expectError(error.InvalidProviderVersion, parseResponse(std.testing.allocator, .grok, "1.0.13\nHeader: injected"));
}
