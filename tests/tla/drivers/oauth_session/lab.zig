//! One fx process that refreshes the fx login, or an MCP credential, for
//! driver.ts in this folder.
//!
//! driver.ts builds it from a copy of src/ whose src/core/hosts/native_keychain.zig
//! is fake_keychain.zig. The real src/core/auth/oauth_session.zig takes the
//! login's lock and loads the login, and the real credentials.refreshFxSession
//! refreshes it against the driver's local issuer, the way
//! credentials.refreshFxLoginCredentialLocked does. Only the HTTP transport
//! here stands in for fx's, which needs the whole gateway client.
//!
//! With FX_TLA_ITEM=mcp it refreshes an MCP credential instead: the real
//! src/core/mcp_host/credentials.zig Store takes the login's refresh lock,
//! reads the credential under it, and saves the rotated one or removes a
//! refused one, in the order Runtime.tryRefresh (src/core/mcp_host/runtime.zig)
//! does. The MCP engine's own refresh request, which needs the whole engine, is
//! the plain form post here.
//!
//! It prints one JSON line per step on standard output, timed on the awake
//! clock in nanoseconds. "take" is printed once the lock is held and
//! "release" while it still is, so another process's "take" always follows.
//!
//! Environment: HOME and FX_HOME as fx reads them. FX_TLA_LABEL names the
//! process. FX_TLA_FORCE=1 refreshes a login that has not run out, as fx does
//! after a 401. FX_TLA_HOLD_MS keeps the lock that long after the refresh, so
//! the driver can kill the process there. FX_TRACE_LOG and FX_TRACE_SCOPES
//! write fx's own trace lines. FX_TLA_ITEM=mcp, and the Keychain items the
//! fake Keychain reads, FX_TLA_KEYCHAIN_FILE and FX_TLA_MCP_KEYCHAIN_FILE.
const std = @import("std");
const io_mod = @import("src/core/shared/io.zig");
const profile_paths = @import("src/core/shared/profile_paths.zig");
const debug_trace = @import("src/core/shared/debug_trace.zig");
const oauth_session = @import("src/core/auth/oauth_session.zig");
const oauth_transport = @import("src/core/auth/oauth_transport.zig");
const credentials = @import("src/core/auth/credentials.zig");
const mcp_credentials = @import("src/core/mcp_host/credentials.zig");

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

/// The credential blob the MCP lab saves: opaque to the store.
const McpBlob = struct { refresh_token: []const u8, expires_at_ms: i64 };

/// How long a waiter for a refresh lock lets its holder answer, as the runtime's `refresh_answer_ms`.
const mcp_refresh_answer_ms: i64 = 30_000;

const Fetched = struct { status: std.http.Status, body: []u8 };

fn fetch(alloc: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8) !Fetched {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(alloc);
    errdefer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .headers = .{
            .content_type = if (payload != null) .{ .override = "application/x-www-form-urlencoded" } else .default,
            .accept_encoding = .omit,
        },
        .redirect_behavior = .unhandled,
        .response_writer = &body.writer,
    });
    return .{ .status = result.status, .body = try body.toOwnedSlice() };
}

fn runMcp(alloc: std.mem.Allocator) !void {
    event("\"ev\":\"start\"", .{});
    const home = io_mod.homeDir() orelse return error.HomeNotSet;
    const store = mcp_credentials.Store.detect(alloc, home);
    const key: mcp_credentials.Key = .{ .name = "plain", .url = "https://mcp.plain.com/mcp" };

    // Under the login's refresh lock one fx refreshes at a time; one that
    // finds it held waits for it, or goes ahead once its holder stopped.
    const started = io_mod.awakeMilliTimestamp();
    var lock: ?mcp_credentials.Store.Locked = null;
    while (true) {
        lock = try store.tryRefreshLock(key);
        if (lock != null) break;
        if (store.refreshHolderStopped(key, started, mcp_refresh_answer_ms)) break;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    if (lock != null) event("\"ev\":\"take\"", .{});
    defer if (lock) |*held| {
        event("\"ev\":\"release\"", .{});
        held.release();
    };

    const saved = (try store.lookup(alloc, key)) orelse {
        event("\"ev\":\"load\",\"token\":\"\"", .{});
        return;
    };
    defer alloc.free(saved);
    var blob = try std.json.parseFromSlice(McpBlob, alloc, saved, .{ .ignore_unknown_fields = true });
    defer blob.deinit();
    const expired = blob.value.expires_at_ms <= io_mod.milliTimestamp();
    event("\"ev\":\"load\",\"token\":\"{s}\",\"expired\":{}", .{ blob.value.refresh_token, expired });

    if (expired or flag("FX_TLA_FORCE")) {
        event("\"ev\":\"send\",\"token\":\"{s}\"", .{blob.value.refresh_token});
        const issuer_url = io_mod.getenv("FX_TEST_OAUTH_ISSUER_URL") orelse return error.NoIssuerUrl;
        const discovery = try alloc.print("{s}/.well-known/openid-configuration", .{issuer_url});
        defer alloc.free(discovery);
        const found = try fetch(alloc, .GET, discovery, null);
        alloc.free(found.body);
        const token_url = try alloc.print("{s}/oauth/token", .{issuer_url});
        defer alloc.free(token_url);
        const form = try alloc.print("grant_type=refresh_token&refresh_token={s}&client_id=lab-client", .{blob.value.refresh_token});
        defer alloc.free(form);
        const answer = try fetch(alloc, .POST, token_url, form);
        defer alloc.free(answer.body);
        if (answer.status == .ok) {
            const Answer = struct { refresh_token: []const u8 };
            var parsed = try std.json.parseFromSlice(Answer, alloc, answer.body, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const rotated = try alloc.print("{{\"refresh_token\":\"{s}\",\"expires_at_ms\":{d}}}", .{ parsed.value.refresh_token, io_mod.milliTimestamp() + 3_600_000 });
            defer alloc.free(rotated);
            if (store.put(alloc, key, rotated)) {
                event("\"ev\":\"reply\",\"outcome\":\"ok\",\"token\":\"{s}\"", .{parsed.value.refresh_token});
            } else |err| {
                event("\"ev\":\"reply\",\"outcome\":\"{s}\"", .{@errorName(err)});
            }
        } else if (answer.status == .bad_request) {
            // A refused login goes only if it is still the one this fx loaded.
            const removed = try store.removeIfSame(alloc, key, mcp_credentials.digest(saved));
            event("\"ev\":\"reply\",\"outcome\":\"{s}\"", .{if (removed) "InvalidGrant" else "InvalidGrantKept"});
        } else {
            event("\"ev\":\"reply\",\"outcome\":\"Unavailable\"", .{});
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
    const item = io_mod.getenv("FX_TLA_ITEM") orelse "login";
    (if (std.mem.eql(u8, item, "mcp")) runMcp(init.gpa) else run(init.gpa)) catch |err| {
        event("\"ev\":\"error\",\"err\":\"{s}\"", .{@errorName(err)});
        std.process.exit(1);
    };
}
