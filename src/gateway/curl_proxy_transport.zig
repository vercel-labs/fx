const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    url: []const u8,
    method: enum { get, post } = .get,
    headers: []const Header = &.{},
    payload: ?[]const u8 = null,
    max_response_bytes: usize,
    timeout_seconds: u32,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const Response = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Response, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

/// Zig 0.16 sends plaintext HTTP after an HTTPS proxy CONNECT. macOS ships
/// curl, so use it only for affected HTTPS requests when a proxy is configured.
pub fn shouldUse(url: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    if (!std.mem.startsWith(u8, url, "https://")) return false;
    for ([_][]const u8{ "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" }) |name| {
        if (io_mod.getenv(name)) |value| {
            if (std.mem.trim(u8, value, " \t\r\n").len > 0) return true;
        }
    }
    return false;
}

pub fn execute(alloc: Allocator, request: Request) !Response {
    var config_writer: std.Io.Writer.Allocating = .init(alloc);
    defer config_writer.deinit();
    const writer = &config_writer.writer;
    try writeOption(writer, "url", request.url);
    try writer.print("request = \"{s}\"\n", .{switch (request.method) {
        .get => "GET",
        .post => "POST",
    }});
    try writer.print("max-time = {d}\n", .{request.timeout_seconds});
    for (request.headers) |header| try writeHeader(writer, header);
    if (request.payload) |payload| try writeOption(writer, "data-binary", payload);
    try writer.writeAll("write-out = \"\\n%{http_code}\"\n");
    const config = try config_writer.toOwnedSlice();
    defer secret.zeroAndFree(alloc, config);

    const io = io_mod.getIo();
    var child = try std.process.spawn(io, .{
        .argv = &.{
            "/usr/bin/curl",
            "--silent",
            "--show-error",
            "--no-buffer",
            "--config",
            "-",
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer if (child.id != null) child.kill(io);

    var stdin = child.stdin orelse return error.CurlProxyStdinUnavailable;
    child.stdin = null;
    try stdin.writeStreamingAll(io, config);
    stdin.close(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(64, .none)) |_| {
        if (request.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        if (stdout_reader.buffered().len > request.max_response_bytes + 16 or
            stderr_reader.buffered().len > 16 * 1024)
        {
            return error.CurlProxyResponseTooLarge;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |fill_err| return fill_err,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.CurlProxyRequestFailed;
    const stdout = try multi_reader.toOwnedSlice(0);
    defer secret.zeroAndFree(alloc, stdout);
    return parseResponse(alloc, stdout, request.max_response_bytes);
}

fn parseResponse(alloc: Allocator, stdout: []const u8, max_response_bytes: usize) !Response {
    const separator = std.mem.findScalarLast(u8, stdout, '\n') orelse
        return error.InvalidCurlProxyResponse;
    const status_bytes = std.mem.trim(u8, stdout[separator + 1 ..], " \t\r\n");
    const status_code = std.fmt.parseUnsigned(u10, status_bytes, 10) catch
        return error.InvalidCurlProxyResponse;
    if (status_code < 100 or status_code > 599) return error.InvalidCurlProxyResponse;
    const body = stdout[0..separator];
    if (body.len > max_response_bytes) return error.CurlProxyResponseTooLarge;
    return .{
        .status = @enumFromInt(status_code),
        .body = try alloc.dupe(u8, body),
    };
}

fn writeHeader(writer: *std.Io.Writer, header: Header) !void {
    try writer.writeAll("header = \"");
    try writeEscaped(writer, header.name);
    try writer.writeAll(": ");
    try writeEscaped(writer, header.value);
    try writer.writeAll("\"\n");
}

fn writeOption(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.print("{s} = \"", .{name});
    try writeEscaped(writer, value);
    try writer.writeAll("\"\n");
}

fn writeEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\r' => try writer.writeAll("\\r"),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...12, 14...0x1f, 0x7f => return error.InvalidCurlProxyConfigValue,
        else => try writer.writeByte(byte),
    };
}

test "curl proxy config escapes secrets and JSON without changing bytes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeHeader(&out.writer, .{ .name = "Authorization", .value = "Bearer a\\b\"c" });
    try writeOption(&out.writer, "data-binary", "{\"line\":\"one\\ntwo\"}");
    try std.testing.expectEqualStrings(
        "header = \"Authorization: Bearer a\\\\b\\\"c\"\n" ++
            "data-binary = \"{\\\"line\\\":\\\"one\\\\ntwo\\\"}\"\n",
        out.written(),
    );
}

test "curl proxy response separates body from status trailer" {
    var response = try parseResponse(std.testing.allocator, "data: value\n\n200", 64);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("data: value\n", response.body);
}
