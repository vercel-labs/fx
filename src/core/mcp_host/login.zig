//! The loopback redirect for an MCP sign-in (RFC 8252 §7.3): fx listens on
//! 127.0.0.1, the browser comes back to `GET /callback`, and the address it
//! came to goes to MCP-v2's `finishSignIn`. Anything else, such as a request
//! for an icon, gets a 404 and the wait goes on. A bridged sign-in (Slack's,
//! through fx.sh) comes back instead as a form its page posts.

const std = @import("std");
const browser_callback = @import("../auth/browser_callback.zig");

const Allocator = std.mem.Allocator;

/// A request head longer than this is not a browser coming back.
const max_head_bytes = 16 * 1024;
/// A bridge's form longer than this is not a sign-in's answer.
const max_form_bytes = 8 * 1024;

/// A sign-in whose redirect is a page elsewhere: it posts what came back to
/// it as a form to `path` here, from `origin`. Both borrowed.
pub const Bridge = struct {
    origin: []const u8,
    /// The redirect MCP-v2 signs in with; the form's fields become its query.
    redirect: []const u8,
    path: []const u8,
};

pub const Listener = struct {
    server: std.Io.net.Server,
    port: u16,
    bridge: ?Bridge = null,

    /// Listens on 127.0.0.1 at `port`, or at a free port when null.
    pub fn open(io: std.Io, port: ?u16) !Listener {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port orelse 0);
        var server = try address.listen(io, .{ .reuse_address = port != null });
        return .{ .port = server.socket.address.getPort(), .server = server };
    }

    pub fn close(l: *Listener, io: std.Io) void {
        l.server.deinit(io);
    }

    /// The redirect URI to sign in with, in `buffer`.
    pub fn redirectUri(l: *const Listener, buffer: *[64]u8) []const u8 {
        if (l.bridge) |b| return b.redirect;
        const origin = "http://127.0.0.1:";
        const path = "/callback";
        comptime std.debug.assert(origin.len + std.fmt.count("{d}", .{std.math.maxInt(@TypeOf(l.port))}) + path.len <= buffer.len);
        buffer[0..origin.len].* = origin.*;
        const port_end = origin.len + std.fmt.printInt(buffer[origin.len..], l.port, 10, .lower, .{});
        buffer[port_end..][0..path.len].* = path.*;
        return buffer[0 .. port_end + path.len];
    }

    /// Waits for the browser's `GET /callback` and returns the full address it
    /// came to, owned by `alloc`. A cancellation point: cancelling the task
    /// ends the wait with error.Canceled.
    pub fn accept(l: *Listener, io: std.Io, alloc: Allocator) ![]u8 {
        while (true) {
            const stream = try l.server.accept(io);
            defer stream.close(io);
            if (try answer(stream, io, alloc, l.port, l.bridge)) |url| return url;
        }
    }
};

/// Answers one connection: the callback address when it was the browser's
/// return, null otherwise.
fn answer(stream: std.Io.net.Stream, io: std.Io, alloc: Allocator, port: u16, bridge: ?Bridge) !?[]u8 {
    var in: [max_head_bytes]u8 = undefined;
    var reader = stream.reader(io, &in);
    const first = reader.interface.takeDelimiterInclusive('\n') catch return null;
    var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, first, "\r\n"), ' ');
    const method_view = parts.next() orelse return null;
    const target_view = parts.next() orelse return null;
    // Both are copied: the reads below reuse `in`.
    var line: [max_head_bytes]u8 = undefined;
    const method = line[0..method_view.len];
    @memcpy(method, method_view);
    const target = line[method.len..][0..target_view.len];
    @memcpy(target, target_view);
    // The rest of the head is read first, so closing doesn't reset the connection.
    var head: Head = .{};
    while (true) {
        const header = std.mem.trimEnd(u8, reader.interface.takeDelimiterInclusive('\n') catch return null, "\r\n");
        if (header.len == 0) break;
        head.note(header);
    }
    if (bridge) |b| return answerForm(stream, &reader.interface, alloc, port, b, method, target, &head);
    const query_at = std.mem.findScalar(u8, target, '?');
    const path = target[0 .. query_at orelse target.len];
    const query = if (query_at) |q| target[q + 1 ..] else "";
    const ours = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/callback");
    // The same page fx's other sign-ins show. A refusal comes back with an
    // `error` (RFC 6749 §4.1.2.1); MCP-v2 reads the rest from the address.
    const outcome: browser_callback.Response = if (!ours) .unrelated else if (hasParam(query, "error")) .failed else .ok;
    browser_callback.writeResponse(stream, outcome, null) catch {};
    if (!ours) return null;
    return try alloc.print("http://127.0.0.1:{d}{s}", .{ port, target });
}

/// A bridge's form, posted by its page in the browser: `POST` to its path,
/// from its origin, to this host, as one urlencoded body. Its fields become
/// the query of the redirect MCP-v2 signed in with; anything else gets a 404.
fn answerForm(stream: std.Io.net.Stream, reader: *std.Io.Reader, alloc: Allocator, port: u16, b: Bridge, method: []const u8, target: []const u8, head: *const Head) !?[]u8 {
    var host_buf: [32]u8 = undefined;
    const host = try std.mem.print(&host_buf, "127.0.0.1:{d}", .{port});
    const kind = if (head.content_type.get()) |t| std.mem.trim(u8, t[0 .. std.mem.findScalar(u8, t, ';') orelse t.len], " ") else "";
    const length = if (head.length.get()) |v| std.fmt.parseInt(usize, v, 10) catch 0 else 0;
    const ours = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, b.path) and
        eqlField(head.origin.get(), b.origin) and eqlField(head.host.get(), host) and
        std.ascii.eqlIgnoreCase(kind, "application/x-www-form-urlencoded") and !head.chunked and
        length > 0 and length <= max_form_bytes;
    if (!ours) {
        browser_callback.writeResponse(stream, .unrelated, null) catch {};
        return null;
    }
    var body: [max_form_bytes]u8 = undefined;
    reader.readSliceAll(body[0..length]) catch return null;
    const form = body[0..length];
    browser_callback.writeResponse(stream, if (hasParam(form, "error")) .failed else .ok, null) catch {};
    return try alloc.print("{s}?{s}", .{ b.redirect, form });
}

fn eqlField(value: ?[]const u8, want: []const u8) bool {
    return std.mem.eql(u8, value orelse return false, want);
}

/// The headers a bridge's form is checked by; each counts only if sent once.
const Head = struct {
    origin: Field = .{},
    host: Field = .{},
    content_type: Field = .{},
    length: Field = .{},
    chunked: bool = false,

    const Field = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,
        seen: u8 = 0,

        fn set(f: *Field, value: []const u8) void {
            f.seen +|= 1;
            f.len = @min(value.len, f.buf.len);
            @memcpy(f.buf[0..f.len], value[0..f.len]);
            if (value.len > f.buf.len) f.seen = 2;
        }

        fn get(f: *const Field) ?[]const u8 {
            return if (f.seen == 1) f.buf[0..f.len] else null;
        }
    };

    fn note(h: *Head, line: []const u8) void {
        const colon = std.mem.findScalar(u8, line, ':') orelse return;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "origin")) h.origin.set(value) else if (std.ascii.eqlIgnoreCase(name, "host")) h.host.set(value) else if (std.ascii.eqlIgnoreCase(name, "content-type")) h.content_type.set(value) else if (std.ascii.eqlIgnoreCase(name, "content-length")) h.length.set(value) else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) h.chunked = true;
    }
};

/// Whether the query string has a parameter called `name`.
fn hasParam(query: []const u8, name: []const u8) bool {
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        const key = param[0 .. std.mem.findScalar(u8, param, '=') orelse param.len];
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

const testing = std.testing;

/// Sends one GET and returns the reply, as much of it as fits in `out`.
fn get(port: u16, target: []const u8, out: []u8) ![]const u8 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    var request: [512]u8 = undefined;
    var writer = stream.writer(testing.io, &request);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", .{target});
    try writer.interface.flush();
    var in: [512]u8 = undefined;
    var reader = stream.reader(testing.io, &in);
    var n: usize = 0;
    while (n < out.len) {
        const got = reader.interface.readSliceShort(out[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    return out[0..n];
}

test "the browser's return is the callback address; other requests get a 404 and the wait goes on" {
    var listener = try Listener.open(testing.io, null);
    defer listener.close(testing.io);
    try testing.expect(listener.port != 0);
    var buffer: [64]u8 = undefined;
    const uri = listener.redirectUri(&buffer);
    try testing.expect(std.mem.startsWith(u8, uri, "http://127.0.0.1:"));
    try testing.expect(std.mem.endsWith(u8, uri, "/callback"));

    const Browser = struct {
        icon: [4096]u8 = undefined,
        icon_reply: []const u8 = "",
        page: [4096]u8 = undefined,
        page_reply: []const u8 = "",
        fn run(b: *@This(), port: u16) void {
            b.icon_reply = get(port, "/favicon.ico", &b.icon) catch "";
            b.page_reply = get(port, "/callback?code=c1&state=s1", &b.page) catch "";
        }
    };
    var browser: Browser = .{};
    const thread = try std.Thread.spawn(.{}, Browser.run, .{ &browser, listener.port });
    const url = listener.accept(testing.io, testing.allocator) catch |err| {
        thread.join();
        return err;
    };
    thread.join();
    defer testing.allocator.free(url);
    const want = try testing.allocator.print("http://127.0.0.1:{d}/callback?code=c1&state=s1", .{listener.port});
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, url);
    try testing.expect(std.mem.startsWith(u8, browser.icon_reply, "HTTP/1.1 404"));
    try testing.expect(std.mem.startsWith(u8, browser.page_reply, "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.find(u8, browser.page_reply, "Authorization complete") != null);
}

/// Sends one form POST from `origin` and returns the reply, as much as fits in `out`.
fn post(port: u16, origin: []const u8, body: []const u8, out: []u8) ![]const u8 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    var request: [1024]u8 = undefined;
    var writer = stream.writer(testing.io, &request);
    try writer.interface.print("POST /slack/oauth/callback HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nOrigin: {s}\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ port, origin, body.len, body });
    try writer.interface.flush();
    var in: [512]u8 = undefined;
    var reader = stream.reader(testing.io, &in);
    var n: usize = 0;
    while (n < out.len) {
        const got = reader.interface.readSliceShort(out[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    return out[0..n];
}

test "a bridge's form from its origin is the callback; from anywhere else it's a 404" {
    var listener = try Listener.open(testing.io, null);
    defer listener.close(testing.io);
    listener.bridge = .{ .origin = "https://fx.sh", .redirect = "https://fx.sh/api/slack/oauth/callback", .path = "/slack/oauth/callback" };
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("https://fx.sh/api/slack/oauth/callback", listener.redirectUri(&buffer));
    const Page = struct {
        bad: [4096]u8 = undefined,
        bad_reply: []const u8 = "",
        good: [4096]u8 = undefined,
        good_reply: []const u8 = "",
        fn run(b: *@This(), port: u16) void {
            b.bad_reply = post(port, "https://evil.example", "state=s1&code=c1", &b.bad) catch "";
            b.good_reply = post(port, "https://fx.sh", "state=s1&code=c1", &b.good) catch "";
        }
    };
    var page: Page = .{};
    const thread = try std.Thread.spawn(.{}, Page.run, .{ &page, listener.port });
    const url = listener.accept(testing.io, testing.allocator) catch |err| {
        thread.join();
        return err;
    };
    thread.join();
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://fx.sh/api/slack/oauth/callback?state=s1&code=c1", url);
    try testing.expect(std.mem.startsWith(u8, page.bad_reply, "HTTP/1.1 404"));
    try testing.expect(std.mem.startsWith(u8, page.good_reply, "HTTP/1.1 200 OK"));
}

test "a refused sign-in comes back to the failure page" {
    var listener = try Listener.open(testing.io, null);
    defer listener.close(testing.io);
    const Browser = struct {
        page: [4096]u8 = undefined,
        reply: []const u8 = "",
        fn run(b: *@This(), port: u16) void {
            b.reply = get(port, "/callback?error=access_denied&state=s1", &b.page) catch "";
        }
    };
    var browser: Browser = .{};
    const thread = try std.Thread.spawn(.{}, Browser.run, .{ &browser, listener.port });
    const url = listener.accept(testing.io, testing.allocator) catch |err| {
        thread.join();
        return err;
    };
    thread.join();
    testing.allocator.free(url);
    try testing.expect(std.mem.startsWith(u8, browser.reply, "HTTP/1.1 400"));
    try testing.expect(std.mem.find(u8, browser.reply, "Authorization failed") != null);
}

test "the redirect URI spells out every port in full" {
    var buffer: [64]u8 = undefined;
    for ([_]struct { u16, []const u8 }{
        .{ 1, "http://127.0.0.1:1/callback" },
        .{ 8080, "http://127.0.0.1:8080/callback" },
        .{ 65535, "http://127.0.0.1:65535/callback" },
    }) |case| {
        const listener: Listener = .{ .server = undefined, .port = case[0] };
        try testing.expectEqualStrings(case[1], listener.redirectUri(&buffer));
    }
}
