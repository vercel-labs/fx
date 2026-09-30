const std = @import("std");
const configured_provider = @import("../core/config/configured_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const configured = @import("chat_completions_configured.zig");
const codec = @import("chat_completions_protocol.zig");
const host_stream = @import("host_stream_provider.zig");
const secret = @import("../core/auth/secret.zig");

const Allocator = std.mem.Allocator;

/// The owner keeps both the definition and transport alive until the ACP core exits.
pub const Context = struct {
    definition: *const configured_provider.Definition,
    transport: host_stream.Transport,
};

pub fn bundle(raw: ?*anyopaque, definition: *const configured_provider.Definition) provider_set.Bundle {
    const context: *Context = @ptrCast(@alignCast(raw orelse return .{}));
    const expected = context.definition.binding_identity();
    const actual = definition.binding_identity();
    if (!std.mem.eql(u8, &expected, &actual)) return .{};
    return .{
        .agent_stream = .{
            .context = context,
            .stream_fn = stream,
            .build_request_fn = build,
            .project_replay_fn = configured.project_replay,
        },
        .model_catalog = configured.model_catalog(definition),
        .cli_model_catalog = configured.cli_model_catalog(definition),
    };
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.RequestData) ![]u8 {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    return configured.build(@ptrCast(@constCast(context.definition)), alloc, request);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *Context = @ptrCast(@alignCast(raw.?));
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (context.definition.auth) {
        .none => if (token != null) return error.UnexpectedConfiguredProviderCredential,
        .bearer => if (token == null) return error.MissingConfiguredProviderCredential,
    }
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const url = try context.definition.chat_url(alloc);
    defer alloc.free(url);
    const authorization = if (token) |value| try std.fmt.allocPrint(alloc, "Bearer {s}", .{value}) else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    const Header = struct { name: []const u8, value: []const u8 };
    const headers = [_]Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "authorization", .value = authorization orelse "" },
    };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try std.json.Stringify.value(headers[0..if (authorization != null) 3 else 2], .{}, &encoded.writer);

    try request.admission.admit();
    request.delivery.markPossiblySent();
    const transport = context.transport;
    const handle = try transport.open("POST", url, encoded.writer.buffered(), payload);
    if (handle < 0) return error.HostStreamFailed;
    defer transport.close(handle);
    var status_code: u16 = 0;
    while (true) {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (host_stream.deadlineExpired(request.deadline)) return error.Timeout;
        const status = transport.status(handle, &status_code);
        if (status == 1) break;
        if (status == -2) return error.Cancelled;
        if (status < 0) return error.HostStreamFailed;
        if (request.cooperative_pulse) |pulse| try pulse.pulse();
    }
    const response_status: std.http.Status = @enumFromInt(status_code);
    if (response_status != .ok) {
        var detail = try host_stream.readBody(alloc, transport, handle, request.cancel_flag, request.deadline, request.cooperative_pulse);
        errdefer alloc.free(detail);
        if (token) |value| {
            const redacted = try codec.redact_error_detail(alloc, detail, value);
            alloc.free(detail);
            detail = redacted;
        }
        return .{ .failed = .{
            .kind = host_stream.failureKind(response_status),
            .detail = detail,
            .ownership = .owned,
        } };
    }
    var reader: host_stream.HostStreamReader = undefined;
    reader.init(transport, handle, request.cancel_flag, request.deadline, request.cooperative_pulse);
    var limits: codec.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return codec.consume_stream(alloc, &reader.interface, request.data(), limits, request.events, request.cancel_flag) catch |err| switch (err) {
        error.ReadFailed => if (reader.timed_out)
            error.Timeout
        else if (request.cancel_flag.load(.seq_cst) or reader.aborted)
            error.Cancelled
        else
            error.HostStreamFailed,
        else => err,
    };
}
