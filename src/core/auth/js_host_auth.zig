const std = @import("std");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const max_response_bytes: usize = 64 * 1024;
pub const max_session_bytes: usize = 64 * 1024;
pub const max_revision_bytes: usize = 1024;

extern "fx" fn fx_http_request(
    method_ptr: [*]const u8,
    method_len: usize,
    url_ptr: [*]const u8,
    url_len: usize,
    headers_ptr: [*]const u8,
    headers_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
    status_out: *u16,
    response_ptr: [*]u8,
    response_cap: usize,
) i32;

extern "fx" fn fx_oauth_session_load(
    bytes_ptr: [*]u8,
    bytes_cap: usize,
    revision_ptr: [*]u8,
    revision_cap: usize,
    revision_len_out: *usize,
) i32;

extern "fx" fn fx_oauth_session_commit(
    bytes_ptr: [*]const u8,
    bytes_len: usize,
    expected_revision_ptr: [*]const u8,
    expected_revision_len: usize,
    revision_ptr: [*]u8,
    revision_cap: usize,
    revision_len_out: *usize,
) i32;

extern "fx" fn fx_oauth_session_remove(
    expected_revision_ptr: [*]const u8,
    expected_revision_len: usize,
) i32;

pub const oauth_provider: oauth_transport.Provider = if (host_target.is_wasm)
    .{ .execute_fn = executeOAuthRequest }
else
    oauth_transport.unavailable_provider;

fn executeOAuthRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: oauth_transport.Request,
) !oauth_transport.Response {
    try checkRequestBounds(request);
    const Header = struct { name: []const u8, value: []const u8 };
    var header_buf: [8]Header = undefined;
    var header_count: usize = 0;
    switch (request.method) {
        .get => {},
        .post_form => {
            header_buf[header_count] = .{ .name = "content-type", .value = "application/x-www-form-urlencoded" };
            header_count += 1;
        },
        .post_json => {
            header_buf[header_count] = .{ .name = "content-type", .value = "application/json" };
            header_count += 1;
        },
    }
    if (request.authorization) |value| {
        header_buf[header_count] = .{ .name = "authorization", .value = value };
        header_count += 1;
    }
    if (header_count + request.extra_headers.len > header_buf.len) return error.OAuthRequestHeadersTooLarge;
    for (request.extra_headers) |header| {
        header_buf[header_count] = .{ .name = header.name, .value = header.value };
        header_count += 1;
    }
    var response = try executeRequest(
        alloc,
        switch (request.method) {
            .get => "GET",
            .post_form, .post_json => "POST",
        },
        request.url,
        header_buf[0..header_count],
        request.payload orelse "",
    );
    errdefer response.deinit(alloc);
    try checkRequestBounds(request);
    return response;
}

pub fn executeBearerGet(
    alloc: Allocator,
    url: []const u8,
    access_token: []const u8,
) !oauth_transport.Response {
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
    defer secret.zeroAndFree(alloc, authorization);
    return executeRequest(alloc, "GET", url, &.{.{
        .name = "authorization",
        .value = authorization,
    }}, "");
}

fn executeRequest(
    alloc: Allocator,
    method: []const u8,
    url: []const u8,
    headers: anytype,
    body: []const u8,
) !oauth_transport.Response {
    var headers_json: std.Io.Writer.Allocating = .init(alloc);
    defer headers_json.deinit();
    try std.json.Stringify.value(headers, .{}, &headers_json.writer);

    const response_buffer = try alloc.alloc(u8, max_response_bytes);
    defer secret.zeroAndFree(alloc, response_buffer);
    var status: u16 = 0;
    const response_len = fx_http_request(
        method.ptr,
        method.len,
        url.ptr,
        url.len,
        headers_json.written().ptr,
        headers_json.written().len,
        body.ptr,
        body.len,
        &status,
        response_buffer.ptr,
        response_buffer.len,
    );
    if (response_len == -2) return error.OAuthResponseTooLarge;
    if (response_len < 0 or @as(usize, @intCast(response_len)) > response_buffer.len) {
        return error.OAuthRequestFailed;
    }
    return .{
        .disposition = if (status == 200) .accepted else .rejected,
        .body = try alloc.dupe(u8, response_buffer[0..@intCast(response_len)]),
    };
}

fn checkRequestBounds(request: oauth_transport.Request) !void {
    if (request.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }
    if (request.deadline) |deadline| {
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) return error.Timeout;
    }
}

pub const StoredSession = struct {
    bytes: []u8,
    revision: []u8,

    pub fn deinit(self: *StoredSession, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.bytes);
        alloc.free(self.revision);
        self.* = undefined;
    }
};

pub const RemoveOutcome = enum { deleted, missing };

pub const SessionStore = struct {
    context: ?*anyopaque = null,
    load_fn: *const fn (?*anyopaque, Allocator) anyerror!?StoredSession,
    commit_fn: *const fn (?*anyopaque, Allocator, []const u8, ?[]const u8) anyerror![]u8,
    remove_fn: *const fn (?*anyopaque, ?[]const u8) anyerror!RemoveOutcome,

    pub fn load(self: SessionStore, alloc: Allocator) !?StoredSession {
        return self.load_fn(self.context, alloc);
    }

    pub fn commit(
        self: SessionStore,
        alloc: Allocator,
        bytes: []const u8,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        return self.commit_fn(self.context, alloc, bytes, expected_revision);
    }

    pub fn remove(self: SessionStore, expected_revision: ?[]const u8) !RemoveOutcome {
        return self.remove_fn(self.context, expected_revision);
    }
};

pub const oauth_session_store: SessionStore = if (host_target.is_wasm)
    .{
        .load_fn = loadSession,
        .commit_fn = commitSession,
        .remove_fn = removeSession,
    }
else
    .{
        .load_fn = unavailableSessionLoad,
        .commit_fn = unavailableSessionCommit,
        .remove_fn = unavailableSessionRemove,
    };

fn unavailableSessionLoad(_: ?*anyopaque, _: Allocator) !?StoredSession {
    return error.OAuthSessionStoreUnavailable;
}

fn unavailableSessionCommit(_: ?*anyopaque, _: Allocator, _: []const u8, _: ?[]const u8) ![]u8 {
    return error.OAuthSessionStoreUnavailable;
}

fn unavailableSessionRemove(_: ?*anyopaque, _: ?[]const u8) !RemoveOutcome {
    return error.OAuthSessionStoreUnavailable;
}

fn loadSession(_: ?*anyopaque, alloc: Allocator) !?StoredSession {
    const session_buffer = try alloc.alloc(u8, max_session_bytes);
    defer secret.zeroAndFree(alloc, session_buffer);
    const revision_buffer = try alloc.alloc(u8, max_revision_bytes);
    defer alloc.free(revision_buffer);
    var revision_len: usize = 0;
    const session_len = fx_oauth_session_load(
        session_buffer.ptr,
        session_buffer.len,
        revision_buffer.ptr,
        revision_buffer.len,
        &revision_len,
    );
    if (session_len == -2) return null;
    if (session_len == -3) return error.OAuthSessionTooLarge;
    if (session_len < 0 or
        @as(usize, @intCast(session_len)) > session_buffer.len or
        revision_len > revision_buffer.len)
    {
        return error.OAuthSessionStoreUnavailable;
    }
    const session_bytes = try alloc.dupe(u8, session_buffer[0..@intCast(session_len)]);
    errdefer secret.zeroAndFree(alloc, session_bytes);
    return .{
        .bytes = session_bytes,
        .revision = try alloc.dupe(u8, revision_buffer[0..revision_len]),
    };
}

fn commitSession(
    _: ?*anyopaque,
    alloc: Allocator,
    bytes: []const u8,
    expected_revision: ?[]const u8,
) ![]u8 {
    if (bytes.len > max_session_bytes) return error.OAuthSessionTooLarge;
    const revision_buffer = try alloc.alloc(u8, max_revision_bytes);
    defer alloc.free(revision_buffer);
    var revision_len: usize = 0;
    const expected = expected_revision orelse "";
    const status = fx_oauth_session_commit(
        bytes.ptr,
        bytes.len,
        expected.ptr,
        expected.len,
        revision_buffer.ptr,
        revision_buffer.len,
        &revision_len,
    );
    if (status == -2) return error.OAuthSessionRevisionConflict;
    if (status < 0 or revision_len > revision_buffer.len) {
        return error.OAuthSessionStoreUnavailable;
    }
    return alloc.dupe(u8, revision_buffer[0..revision_len]);
}

fn removeSession(_: ?*anyopaque, expected_revision: ?[]const u8) !RemoveOutcome {
    const expected = expected_revision orelse "";
    return switch (fx_oauth_session_remove(expected.ptr, expected.len)) {
        0 => .deleted,
        1 => .missing,
        -2 => error.OAuthSessionRevisionConflict,
        else => error.OAuthSessionStoreUnavailable,
    };
}

test "request bounds reject cancellation before touching the JS host" {
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, checkRequestBounds(.{
        .method = .get,
        .url = "https://vercel.test",
        .cancel_flag = &cancelled,
    }));
}
