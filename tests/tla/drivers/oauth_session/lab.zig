//! One fx process that refreshes the fx login, for driver.ts in this folder.
//!
//! driver.ts builds it from a copy of src/ whose src/core/hosts/native_keychain.zig
//! is fake_keychain.zig. The real src/core/auth/oauth_session.zig takes the
//! login's lock and loads the login, and the real credentials.refreshFxSession
//! refreshes it against the driver's local issuer, the way
//! credentials.refreshFxLoginCredentialLocked does. Only the HTTP transport
//! here stands in for fx's, which needs the whole gateway client.
//!
//! It prints one JSON line per step on standard output, timed on the awake
//! clock in nanoseconds. "take" is printed once the lock is held and
//! "release" while it still is, so another process's "take" always follows.
//!
//! Environment: HOME and FX_HOME as fx reads them. FX_TLA_LABEL names the
//! process. FX_TLA_FORCE=1 refreshes a login that has not run out, as fx does
//! after a 401. FX_TLA_HOLD_MS keeps the lock that long after the refresh, so
//! the driver can kill the process there. FX_TRACE_LOG and FX_TRACE_SCOPES
//! write fx's own trace lines.
const std = @import("std");
const io_mod = @import("src/core/shared/io.zig");
const profile_paths = @import("src/core/shared/profile_paths.zig");
const debug_trace = @import("src/core/shared/debug_trace.zig");
const oauth_session = @import("src/core/auth/oauth_session.zig");
const oauth_transport = @import("src/core/auth/oauth_transport.zig");
const credentials = @import("src/core/auth/credentials.zig");

var label: []const u8 = "lab";

fn event(comptime fields: []const u8, args: anytype) void {
    const io = io_mod.getIo();
    var buf: [2048]u8 = undefined;
    const at = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const line = std.mem.print(&buf, "{{\"p\":\"{s}\",\"at\":{d}," ++ fields ++ "}}\n", .{ label, at } ++ args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
}

fn flag(name: []const u8) bool {
    const value = io_mod.getenv(name) orelse return false;
    return std.mem.eql(u8, value, "1");
}

const http_transport = oauth_transport.Provider{ .execute_fn = execute };

fn execute(_: ?*anyopaque, alloc: std.mem.Allocator, request: oauth_transport.Request) !oauth_transport.Response {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = if (request.method == .get) .GET else .POST,
        .payload = request.payload,
        .headers = .{
            .content_type = if (request.method == .post_form) .{ .override = "application/x-www-form-urlencoded" } else .default,
            .accept_encoding = .omit,
        },
        .redirect_behavior = .unhandled,
        .response_writer = &body.writer,
    });
    return .{
        .disposition = if (result.status == .ok) .accepted else .rejected,
        .body = try body.toOwnedSlice(),
    };
}

fn hold() void {
    const text = io_mod.getenv("FX_TLA_HOLD_MS") orelse return;
    const ms = std.fmt.parseInt(u64, text, 10) catch return;
    io_mod.sleep(ms * std.time.ns_per_ms);
}

fn run(alloc: std.mem.Allocator) !void {
    event("\"ev\":\"start\"", .{});
    var mutation = (try oauth_session.beginExistingMutation()) orelse {
        event("\"ev\":\"nologin\"", .{});
        return;
    };
    event("\"ev\":\"take\"", .{});
    defer {
        event("\"ev\":\"release\"", .{});
        mutation.deinit();
    }

    var session = (try mutation.load(alloc)) orelse {
        event("\"ev\":\"load\",\"token\":\"\"", .{});
        return;
    };
    defer session.deinit(alloc);
    const expired = session.expired(io_mod.milliTimestamp());
    event("\"ev\":\"load\",\"token\":\"{s}\",\"expired\":{}", .{ session.refresh_token, expired });

    if (expired or flag("FX_TLA_FORCE")) {
        event("\"ev\":\"send\",\"token\":\"{s}\"", .{session.refresh_token});
        if (credentials.refreshFxSession(alloc, http_transport, &mutation, &session)) {
            event("\"ev\":\"reply\",\"outcome\":\"ok\",\"token\":\"{s}\"", .{session.refresh_token});
        } else |err| {
            event("\"ev\":\"reply\",\"outcome\":\"{s}\"", .{@errorName(err)});
        }
    }
    hold();
}

pub fn main(init: std.process.Init) !void {
    io_mod.setIo(init.io);
    io_mod.setEnvironMap(init.environ_map);
    label = io_mod.getenv("FX_TLA_LABEL") orelse "lab";
    if (io_mod.getenv("FX_HOME")) |value| try profile_paths.useFxHome(value, io_mod.getenv("HOME"));
    debug_trace.configureFromEnv(init.gpa, "/");
    defer debug_trace.shutdown();
    run(init.gpa) catch |err| {
        event("\"ev\":\"error\",\"err\":\"{s}\"", .{@errorName(err)});
        std.process.exit(1);
    };
}
