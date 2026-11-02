const std = @import("std");
const testing_allocator = @import("../core/shared/testing_allocator.zig");
const io_mod = @import("../core/shared/io.zig");
const host_target = @import("../core/hosts/target.zig");

const Allocator = std.mem.Allocator;

pub fn writeJsonStr(s: []const u8, w: *std.Io.Writer) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// Writes JSON a caller built into a frame. Frames are newline-delimited, and
/// valid JSON holds a raw CR or LF only as whitespace between tokens, so each
/// one is written as a space. A host tool call's input, for example, is the
/// model's own text and may be pretty-printed.
fn writeOneLine(w: *std.Io.Writer, json: []const u8) !void {
    if (std.mem.findScalar(u8, json, '\n') == null and std.mem.findScalar(u8, json, '\r') == null) {
        return w.writeAll(json);
    }
    var rest = json;
    while (std.mem.findAny(u8, rest, "\r\n")) |index| {
        try w.writeAll(rest[0..index]);
        try w.writeByte(' ');
        rest = rest[index + 1 ..];
    }
    try w.writeAll(rest);
}

pub const ErrorCode = struct {
    pub const request_frame_too_large: i64 = -32000;
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
};

pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    null,
};

pub const Message = struct {
    id: ?RequestId = null,
    method: []const u8 = "",
    params_raw: ?[]const u8 = null,
    result_raw: ?[]const u8 = null,
    error_raw: ?[]const u8 = null,

    pub fn isResponse(self: Message) bool {
        return self.method.len == 0 and self.id != null and
            (self.result_raw != null or self.error_raw != null);
    }
};

pub const RpcError = struct {
    code: i64,
    message: []const u8,
    data: ?struct {
        code: []const u8,
        model: []const u8,
        capability: []const u8,
    } = null,
};

pub fn parseMessage(alloc: Allocator, line: []const u8) !Message {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch
        return error.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidRequest;

    var msg = Message{};
    errdefer freeMessage(alloc, &msg);

    if (root.object.get("id")) |id_val| {
        switch (id_val) {
            .integer => |n| msg.id = .{ .integer = n },
            .string => |s| msg.id = .{ .string = try alloc.dupe(u8, s) },
            .null => msg.id = .null,
            else => return error.InvalidRequest,
        }
    }

    if (root.object.get("method")) |method_val| {
        switch (method_val) {
            .string => |s| msg.method = try alloc.dupe(u8, s),
            else => return error.InvalidRequest,
        }
    }

    if (root.object.get("params")) |params_val| {
        msg.params_raw = try stringifyValueAlloc(alloc, params_val);
    }

    if (root.object.get("result")) |result_val| {
        msg.result_raw = try stringifyValueAlloc(alloc, result_val);
    }
    if (root.object.get("error")) |error_val| {
        msg.error_raw = try stringifyValueAlloc(alloc, error_val);
    }
    if (msg.result_raw != null and msg.error_raw != null) return error.InvalidRequest;
    if (msg.method.len > 0 and (msg.result_raw != null or msg.error_raw != null)) return error.InvalidRequest;
    if (msg.method.len == 0 and !msg.isResponse()) return error.InvalidRequest;

    return msg;
}

fn stringifyValueAlloc(alloc: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

pub fn freeMessage(alloc: Allocator, msg: *Message) void {
    if (msg.method.len > 0) alloc.free(msg.method);
    if (msg.params_raw) |p| alloc.free(p);
    if (msg.result_raw) |p| alloc.free(p);
    if (msg.error_raw) |p| alloc.free(p);
    if (msg.id) |id| {
        switch (id) {
            .string => |s| alloc.free(s),
            else => {},
        }
    }
    msg.* = .{};
}

pub const Writer = struct {
    pub const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;

    const Callback = struct {
        context: ?*anyopaque,
        write_fn: WriteFn,
    };

    mutex: std.Io.Mutex = .init,
    stdout: std.Io.File,
    callback: ?Callback = null,

    const Frame = union(enum) {
        response: struct {
            id: ?RequestId,
            result_json: []const u8,
        },
        error_response: struct {
            id: ?RequestId,
            err: RpcError,
        },
        notification: struct {
            method: []const u8,
            params_json: []const u8,
        },
        request: struct {
            id: RequestId,
            method: []const u8,
            params_json: []const u8,
        },

        fn write(self: Frame, w: *std.Io.Writer) !void {
            switch (self) {
                .response => |response| {
                    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                    try writeId(w, response.id);
                    try w.writeAll(",\"result\":");
                    try writeOneLine(w, response.result_json);
                    try w.writeAll("}\n");
                },
                .error_response => |response| {
                    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                    try writeId(w, response.id);
                    try w.writeAll(",\"error\":{\"code\":");
                    try w.print("{d}", .{response.err.code});
                    try w.writeAll(",\"message\":");
                    try writeJsonStr(response.err.message, w);
                    if (response.err.data) |data| {
                        try w.writeAll(",\"data\":{\"code\":");
                        try writeJsonStr(data.code, w);
                        try w.writeAll(",\"model\":");
                        try writeJsonStr(data.model, w);
                        try w.writeAll(",\"capability\":");
                        try writeJsonStr(data.capability, w);
                        try w.writeByte('}');
                    }
                    try w.writeAll("}}\n");
                },
                .notification => |notification| {
                    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
                    try writeJsonStr(notification.method, w);
                    try w.writeAll(",\"params\":");
                    try writeOneLine(w, notification.params_json);
                    try w.writeAll("}\n");
                },
                .request => |request| {
                    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                    try writeId(w, request.id);
                    try w.writeAll(",\"method\":");
                    try writeJsonStr(request.method, w);
                    try w.writeAll(",\"params\":");
                    try writeOneLine(w, request.params_json);
                    try w.writeAll("}\n");
                },
            }
        }
    };

    pub fn init() Writer {
        return .{ .stdout = std.Io.File.stdout() };
    }

    pub fn initCallback(context: ?*anyopaque, write_fn: WriteFn) Writer {
        return .{
            .stdout = std.Io.File.stdout(),
            .callback = .{
                .context = context,
                .write_fn = write_fn,
            },
        };
    }

    pub fn writeResponse(self: *Writer, alloc: Allocator, id: ?RequestId, result_json: []const u8) !void {
        try self.writeFrame(alloc, .{ .response = .{
            .id = id,
            .result_json = result_json,
        } });
    }

    pub fn writeError(self: *Writer, alloc: Allocator, id: ?RequestId, err: RpcError) !void {
        try self.writeFrame(alloc, .{ .error_response = .{
            .id = id,
            .err = err,
        } });
    }

    pub fn writeNotification(self: *Writer, alloc: Allocator, method: []const u8, params_json: []const u8) !void {
        try self.writeFrame(alloc, .{ .notification = .{
            .method = method,
            .params_json = params_json,
        } });
    }

    pub fn writeRequest(self: *Writer, alloc: Allocator, id: RequestId, method: []const u8, params_json: []const u8) !void {
        try self.writeFrame(alloc, .{ .request = .{
            .id = id,
            .method = method,
            .params_json = params_json,
        } });
    }

    fn writeFrame(self: *Writer, alloc: Allocator, frame: Frame) !void {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try frame.write(&out.writer);

        const slice = try out.toOwnedSlice();
        defer alloc.free(slice);

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.callback) |callback| {
            try callback.write_fn(callback.context, slice);
        } else {
            try self.stdout.writeStreamingAll(io, slice);
        }
    }

    pub fn writeId(w: *std.Io.Writer, id: ?RequestId) !void {
        if (id) |rid| {
            switch (rid) {
                .integer => |n| try w.print("{d}", .{n}),
                .string => |s| try writeJsonStr(s, w),
                .null => try w.writeAll("null"),
            }
        } else {
            try w.writeAll("null");
        }
    }
};

pub const Reader = struct {
    pub const ReadFn = *const fn (?*anyopaque, []u8) usize;

    pub const frame_resource_byte_limit: usize = 8 * 1024 * 1024;
    pub const LineRead = union(enum) {
        line: []u8,
        overflow,
    };

    read_context: ?*anyopaque = null,
    read_fn: ReadFn,
    buf: [64 * 1024]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,

    pub fn init() Reader {
        return .{ .read_fn = readStdin };
    }

    pub fn initCallback(context: ?*anyopaque, read_fn: ReadFn) Reader {
        return .{
            .read_context = context,
            .read_fn = read_fn,
        };
    }

    fn initForTesting(context: *anyopaque, read_fn: ReadFn) Reader {
        return initCallback(context, read_fn);
    }

    // Native ACP uses raw read(2) because Linux may pass socket-based stdin to
    // child processes. WASI has no std.posix surface, so use the injected std.Io
    // backend and let the host's fd_read import suspend through JSPI.
    fn readStdin(_: ?*anyopaque, destination: []u8) usize {
        if (comptime host_target.is_wasm) {
            return std.Io.File.stdin().readStreaming(
                io_mod.getIo(),
                &.{destination},
            ) catch return 0;
        }
        return std.posix.read(std.posix.STDIN_FILENO, destination) catch return 0;
    }

    fn readFromSource(self: *Reader) usize {
        return self.read_fn(self.read_context, &self.buf);
    }

    pub fn readLine(self: *Reader, alloc: Allocator) !?LineRead {
        return self.readLineWithLimit(alloc, frame_resource_byte_limit);
    }

    fn readLineWithLimit(
        self: *Reader,
        alloc: Allocator,
        resource_byte_limit: usize,
    ) !?LineRead {
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(alloc);
        var overflow = false;

        while (true) {
            if (self.findNewline()) |nl_pos| {
                if (!overflow and !try appendFrameChunk(
                    alloc,
                    &line_buf,
                    self.buf[self.pos .. self.pos + nl_pos],
                    resource_byte_limit,
                )) {
                    overflow = true;
                    line_buf.clearAndFree(alloc);
                }
                self.pos += nl_pos + 1;
                if (overflow) return .overflow;
                if (line_buf.items.len == 0) continue;
                return .{ .line = try line_buf.toOwnedSlice(alloc) };
            }

            if (!overflow and self.pos < self.len and !try appendFrameChunk(
                alloc,
                &line_buf,
                self.buf[self.pos..self.len],
                resource_byte_limit,
            )) {
                overflow = true;
                line_buf.clearAndFree(alloc);
            }
            self.pos = 0;
            self.len = self.readFromSource();
            if (self.len == 0) return if (overflow) .overflow else null;
        }
    }

    fn appendFrameChunk(
        alloc: Allocator,
        line_buf: *std.ArrayList(u8),
        chunk: []const u8,
        resource_byte_limit: usize,
    ) !bool {
        const next_len = std.math.add(usize, line_buf.items.len, chunk.len) catch
            return false;
        if (next_len > resource_byte_limit) return false;
        try line_buf.appendSlice(alloc, chunk);
        return true;
    }

    fn findNewline(self: *Reader) ?usize {
        for (self.buf[self.pos..self.len], 0..) |c, i| {
            if (c == '\n') return i;
        }
        return null;
    }
};

const ChunkedTestSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    max_chunk: usize,

    fn read(raw: ?*anyopaque, destination: []u8) usize {
        const self: *ChunkedTestSource = @ptrCast(@alignCast(raw.?));
        if (self.offset == self.bytes.len) return 0;
        const remaining = self.bytes.len - self.offset;
        const count = @min(@min(remaining, destination.len), self.max_chunk);
        @memcpy(destination[0..count], self.bytes[self.offset .. self.offset + count]);
        self.offset += count;
        return count;
    }
};

test "Reader accepts an exact fragmented frame" {
    const alloc = std.testing.allocator;
    var source = ChunkedTestSource{
        .bytes = "12345678\n",
        .max_chunk = 2,
    };
    var reader = Reader.initForTesting(&source, ChunkedTestSource.read);
    const result = (try reader.readLineWithLimit(alloc, 8)).?;
    switch (result) {
        .line => |line| {
            defer alloc.free(line);
            try std.testing.expectEqualStrings("12345678", line);
        },
        .overflow => return error.TestUnexpectedResult,
    }
}

test "Reader drains one oversized fragmented frame and resumes at the next frame" {
    const alloc = std.testing.allocator;
    var source = ChunkedTestSource{
        .bytes = "123456789\n{\"id\":2}\n",
        .max_chunk = 3,
    };
    var reader = Reader.initForTesting(&source, ChunkedTestSource.read);

    const overflow = (try reader.readLineWithLimit(alloc, 8)).?;
    try std.testing.expect(overflow == .overflow);

    const next = (try reader.readLineWithLimit(alloc, 8)).?;
    switch (next) {
        .line => |line| {
            defer alloc.free(line);
            try std.testing.expectEqualStrings("{\"id\":2}", line);
        },
        .overflow => return error.TestUnexpectedResult,
    }
}

test "Reader reports one overflow when an oversized frame ends at EOF" {
    const alloc = std.testing.allocator;
    var source = ChunkedTestSource{
        .bytes = "123456789",
        .max_chunk = 2,
    };
    var reader = Reader.initForTesting(&source, ChunkedTestSource.read);
    try std.testing.expect((try reader.readLineWithLimit(alloc, 8)).? == .overflow);
    try std.testing.expect((try reader.readLineWithLimit(alloc, 8)) == null);
}

test "Reader propagates allocation failure without publishing a partial frame" {
    var source = ChunkedTestSource{
        .bytes = "12345678\n",
        .max_chunk = 2,
    };
    var reader = Reader.initForTesting(&source, ChunkedTestSource.read);
    var failing = std.testing.FailingAllocator.init(
        testing_allocator.no_resize,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        reader.readLineWithLimit(failing.allocator(), 8),
    );
}

test "parseMessage parses request with integer id" {
    const alloc = std.testing.allocator;
    var msg = try parseMessage(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}");
    defer freeMessage(alloc, &msg);

    try std.testing.expectEqualStrings("initialize", msg.method);
    try std.testing.expect(msg.id != null);
    switch (msg.id.?) {
        .integer => |n| try std.testing.expectEqual(@as(i64, 1), n),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(msg.params_raw != null);
}

test "parseMessage parses notification without id" {
    const alloc = std.testing.allocator;
    var msg = try parseMessage(alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"abc\"}}");
    defer freeMessage(alloc, &msg);

    try std.testing.expectEqualStrings("session/cancel", msg.method);
    try std.testing.expect(msg.id == null);
}

test "parseMessage rejects messages without a method or response payload" {
    const alloc = std.testing.allocator;
    const result = parseMessage(alloc, "{\"jsonrpc\":\"2.0\",\"id\":1}");
    try std.testing.expectError(error.InvalidRequest, result);
}

test "parseMessage accepts correlated client responses" {
    const alloc = std.testing.allocator;
    var msg = try parseMessage(alloc, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_once\"}}}");
    defer freeMessage(alloc, &msg);
    try std.testing.expect(msg.isResponse());
    try std.testing.expect(msg.result_raw != null);
    try std.testing.expectEqual(@as(i64, 7), msg.id.?.integer);
}

test "parseMessage accepts client error responses" {
    const alloc = std.testing.allocator;
    var msg = try parseMessage(alloc, "{\"jsonrpc\":\"2.0\",\"id\":8,\"error\":{\"code\":-32601,\"message\":\"nope\"}}");
    defer freeMessage(alloc, &msg);
    try std.testing.expect(msg.isResponse());
    try std.testing.expect(msg.result_raw == null);
    try std.testing.expect(msg.error_raw != null);
}

test "parseMessage rejects responses with both result and error" {
    const alloc = std.testing.allocator;
    const result = parseMessage(alloc, "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{},\"error\":{\"code\":-32603,\"message\":\"nope\"}}");
    try std.testing.expectError(error.InvalidRequest, result);
}

test "parseMessage rejects invalid json" {
    const alloc = std.testing.allocator;
    const result = parseMessage(alloc, "not json");
    try std.testing.expectError(error.ParseError, result);
}

test "parseMessage parses string id" {
    const alloc = std.testing.allocator;
    var msg = try parseMessage(alloc, "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"test\"}");
    defer freeMessage(alloc, &msg);

    switch (msg.id.?) {
        .string => |s| try std.testing.expectEqualStrings("req-1", s),
        else => return error.TestUnexpectedResult,
    }
}

test "Writer Frame formats protocol lines" {
    const alloc = std.testing.allocator;

    {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try (Writer.Frame{ .response = .{
            .id = .{ .integer = 42 },
            .result_json = "{\"ok\":true}",
        } }).write(&out.writer);
        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{\"ok\":true}}\n", out.writer.buffered());
    }

    {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try (Writer.Frame{ .error_response = .{
            .id = .{ .string = "req-1" },
            .err = .{ .code = ErrorCode.invalid_params, .message = "bad \"params\"" },
        } }).write(&out.writer);
        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"error\":{\"code\":-32602,\"message\":\"bad \\\"params\\\"\"}}\n", out.writer.buffered());
    }

    {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try (Writer.Frame{ .error_response = .{
            .id = .{ .integer = 7 },
            .err = .{
                .code = ErrorCode.invalid_params,
                .message = "Unsupported fast mode",
                .data = .{
                    .code = "LIBFX_MODEL_UNSUPPORTED_FAST",
                    .model = "provider/quoted\"model",
                    .capability = "fast",
                },
            },
        } }).write(&out.writer);
        try std.testing.expectEqualStrings(
            "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"Unsupported fast mode\",\"data\":{\"code\":\"LIBFX_MODEL_UNSUPPORTED_FAST\",\"model\":\"provider/quoted\\\"model\",\"capability\":\"fast\"}}}\n",
            out.writer.buffered(),
        );
    }

    {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try (Writer.Frame{ .notification = .{
            .method = "session/update",
            .params_json = "{\"ok\":true}",
        } }).write(&out.writer);
        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"ok\":true}}\n", out.writer.buffered());
    }

    {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try (Writer.Frame{ .request = .{
            .id = .{ .integer = 3 },
            .method = "session/request_permission",
            .params_json = "{\"ok\":true}",
        } }).write(&out.writer);
        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/request_permission\",\"params\":{\"ok\":true}}\n", out.writer.buffered());
    }
}

test "writeJsonStr escapes special characters" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeJsonStr("hello \"world\"\nnewline\\backslash", &out.writer);
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nnewline\\\\backslash\"", out.writer.buffered());
}

test "writeJsonStr handles empty string" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeJsonStr("", &out.writer);
    try std.testing.expectEqualStrings("\"\"", out.writer.buffered());
}

test "writeJsonStr handles tab and carriage return" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeJsonStr("a\tb\rc", &out.writer);
    try std.testing.expectEqualStrings("\"a\\tb\\rc\"", out.writer.buffered());
}

test "parseMessage extracts params as raw json" {
    const alloc = std.testing.allocator;
    var msg = try parseMessage(alloc, "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"init\",\"params\":{\"version\":1,\"caps\":{}}}");
    defer freeMessage(alloc, &msg);
    try std.testing.expect(msg.params_raw != null);
    try std.testing.expect(std.mem.find(u8, msg.params_raw.?, "version") != null);
}

test "parseMessage handles null id" {
    const alloc = std.testing.allocator;
    var msg = try parseMessage(alloc, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"test\"}");
    defer freeMessage(alloc, &msg);
    try std.testing.expect(msg.id != null);
    switch (msg.id.?) {
        .null => {},
        else => return error.TestUnexpectedResult,
    }
}

test "Writer writeId handles all id types" {
    const alloc = std.testing.allocator;

    {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try Writer.writeId(&out.writer, .{ .integer = 99 });
        try std.testing.expectEqualStrings("99", out.writer.buffered());
    }
    {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try Writer.writeId(&out.writer, .null);
        try std.testing.expectEqualStrings("null", out.writer.buffered());
    }
    {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try Writer.writeId(&out.writer, null);
        try std.testing.expectEqualStrings("null", out.writer.buffered());
    }
}

test "Writer keeps each frame on one line when caller JSON has line breaks" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        bytes: std.ArrayList(u8) = .empty,

        fn write(raw: ?*anyopaque, frame: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.bytes.appendSlice(std.testing.allocator, frame);
        }
    };
    // A model's tool input as some models send it: pretty-printed with LF and
    // CRLF line breaks, holding an escaped newline that must survive.
    const input = "{\n  \"items\": [\r\n\t{\"text\": \"a\\nb\"}\n  ]\n}";
    var capture: Capture = .{};
    defer capture.bytes.deinit(alloc);
    var writer = Writer.initCallback(&capture, Capture.write);
    try writer.writeRequest(alloc, .{ .integer = 1 }, "libfx/tool_call", "{\"name\":\"todo\",\"input\":" ++ input ++ "}");
    try writer.writeNotification(alloc, "session/update", input);
    try writer.writeResponse(alloc, .{ .integer = 2 }, input);

    const frames = capture.bytes.items;
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, frames, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, frames, "\n"));
    try std.testing.expect(std.mem.findScalar(u8, frames, '\r') == null);

    const expected = try std.json.parseFromSlice(std.json.Value, alloc, input, .{});
    defer expected.deinit();
    const expected_json = try std.json.Stringify.valueAlloc(alloc, expected.value, .{});
    defer alloc.free(expected_json);
    var lines = std.mem.splitScalar(u8, frames[0 .. frames.len - 1], '\n');
    for ([_][]const u8{ "params", "params", "result" }, 0..) |field, index| {
        const frame = try std.json.parseFromSlice(std.json.Value, alloc, lines.next().?, .{});
        defer frame.deinit();
        var value = frame.value.object.get(field).?;
        if (index == 0) value = value.object.get("input").?;
        const actual_json = try std.json.Stringify.valueAlloc(alloc, value, .{});
        defer alloc.free(actual_json);
        try std.testing.expectEqualStrings(expected_json, actual_json);
    }
}

test "ACP frames stay one parseable line and read the same however they are split" {
    try std.testing.fuzz({}, fuzzAcpFrames, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").acp_jsonrpc.*),
    });
}

const fuzz_text_pieces = [_][]const u8{
    "a",      "Z",        " ",         "\"",       "\\", "\n", "\r", "\t", "\x00", "\x08", "\x1f", "\x7f", "/", "{", "]",
    "\u{e9}", "\u{754c}", "\u{1f600}", "\u{2028}",
};

const FuzzFrameSink = struct {
    alloc: Allocator,
    out: std.ArrayList(u8) = .empty,

    fn write(raw: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *FuzzFrameSink = @ptrCast(@alignCast(raw.?));
        try self.out.appendSlice(self.alloc, bytes);
    }
};

fn appendFuzzText(smith: *std.testing.Smith, w: *std.Io.Writer) !void {
    for (0..smith.valueRangeAtMost(u8, 0, 12)) |_| try w.writeAll(fuzz_text_pieces[smith.index(fuzz_text_pieces.len)]);
}

/// Writes a JSON value, sometimes pretty-printed across lines as a model's
/// tool input can be.
fn appendFuzzJson(alloc: Allocator, smith: *std.testing.Smith, w: *std.Io.Writer, depth: u8) !void {
    const spaces = [_][]const u8{ "", " ", "\n", "\r\n", "\t" };
    try w.writeAll(spaces[smith.index(spaces.len)]);
    switch (smith.valueRangeAtMost(u8, 0, if (depth >= 3) 4 else 6)) {
        0 => try w.writeAll("null"),
        1 => try w.writeAll(if (smith.value(bool)) "true" else "false"),
        2 => try w.print("{d}", .{smith.value(i32)}),
        3, 4 => {
            var text: std.Io.Writer.Allocating = .init(alloc);
            defer text.deinit();
            try appendFuzzText(smith, &text.writer);
            try writeJsonStr(text.written(), w);
        },
        5 => {
            try w.writeByte('[');
            for (0..smith.valueRangeAtMost(u8, 0, 3)) |index| {
                if (index > 0) try w.writeByte(',');
                try appendFuzzJson(alloc, smith, w, depth + 1);
            }
            try w.writeByte(']');
        },
        else => {
            try w.writeByte('{');
            for (0..smith.valueRangeAtMost(u8, 0, 3)) |index| {
                if (index > 0) try w.writeByte(',');
                try w.print("\"k{d}\":", .{index});
                try appendFuzzJson(alloc, smith, w, depth + 1);
            }
            try w.writeByte('}');
        },
    }
    try w.writeAll(spaces[smith.index(spaces.len)]);
}

fn fuzzAcpFrames(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    try expectFuzzFrame(alloc, smith);
    try expectFuzzLines(alloc, smith);
}

fn expectFuzzFrame(alloc: Allocator, smith: *std.testing.Smith) !void {
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    try appendFuzzText(smith, &text.writer);
    var json: std.Io.Writer.Allocating = .init(alloc);
    defer json.deinit();
    try appendFuzzJson(alloc, smith, &json.writer, 0);
    var id_text: std.Io.Writer.Allocating = .init(alloc);
    defer id_text.deinit();
    try appendFuzzText(smith, &id_text.writer);
    const id: RequestId = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => .{ .integer = smith.value(i64) },
        1 => .{ .string = id_text.written() },
        else => .null,
    };

    var sink: FuzzFrameSink = .{ .alloc = alloc };
    defer sink.out.deinit(alloc);
    var writer = Writer.initCallback(&sink, FuzzFrameSink.write);
    const kind = smith.valueRangeAtMost(u8, 0, 3);
    switch (kind) {
        0 => try writer.writeRequest(alloc, id, text.written(), json.written()),
        1 => try writer.writeNotification(alloc, text.written(), json.written()),
        2 => try writer.writeResponse(alloc, id, json.written()),
        else => try writer.writeError(alloc, id, .{ .code = ErrorCode.invalid_params, .message = text.written() }),
    }

    // One frame is one line of JSON.
    const frame = sink.out.items;
    try std.testing.expect(frame.len > 0 and frame[frame.len - 1] == '\n');
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame, "\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame[0 .. frame.len - 1], .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", object.get("jsonrpc").?.string);

    // It carries what the caller wrote.
    if (kind != 1) try expectFuzzId(id, object.get("id").?);
    if (kind <= 1) try std.testing.expectEqualStrings(text.written(), object.get("method").?.string);
    if (kind == 3) try std.testing.expectEqualStrings(text.written(), object.get("error").?.object.get("message").?.string);
    if (kind <= 2) {
        const field = if (kind == 2) "result" else "params";
        const expected = try std.json.parseFromSlice(std.json.Value, alloc, json.written(), .{});
        defer expected.deinit();
        const expected_text = try stringifyValueAlloc(alloc, expected.value);
        defer alloc.free(expected_text);
        const actual_text = try stringifyValueAlloc(alloc, object.get(field).?);
        defer alloc.free(actual_text);
        try std.testing.expectEqualStrings(expected_text, actual_text);
    }

    // The server's own parser reads it back.
    if (kind >= 2 or text.written().len > 0) {
        var message = try parseMessage(alloc, frame[0 .. frame.len - 1]);
        defer freeMessage(alloc, &message);
        if (kind <= 1) try std.testing.expectEqualStrings(text.written(), message.method);
        if (kind >= 2) try std.testing.expect(message.isResponse());
    }
}

fn expectFuzzId(expected: RequestId, actual: std.json.Value) !void {
    switch (expected) {
        .integer => |n| try std.testing.expectEqual(n, actual.integer),
        .string => |s| try std.testing.expectEqualStrings(s, actual.string),
        .null => try std.testing.expect(actual == .null),
    }
}

fn expectFuzzLines(alloc: Allocator, smith: *std.testing.Smith) !void {
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(alloc);
    for (0..smith.valueRangeAtMost(u8, 0, 16)) |_| {
        if (smith.valueRangeAtMost(u8, 0, 3) == 0) {
            try stream.append(alloc, '\n');
        } else {
            for (0..smith.valueRangeAtMost(u8, 0, 40)) |_| try stream.append(alloc, 'a' + smith.valueRangeAtMost(u8, 0, 25));
        }
    }
    const limit: usize = smith.valueRangeAtMost(u16, 1, 48);

    // A line ends at a newline. An empty line is skipped, a line over the
    // limit is reported once as an overflow, and a final line without a
    // newline is dropped unless it is over the limit.
    var expected: std.ArrayList(?[]const u8) = .empty;
    defer expected.deinit(alloc);
    var rest: []const u8 = stream.items;
    while (std.mem.findScalar(u8, rest, '\n')) |end| {
        const line = rest[0..end];
        if (line.len > limit) try expected.append(alloc, null) else if (line.len > 0) try expected.append(alloc, line);
        rest = rest[end + 1 ..];
    }
    if (rest.len > limit) try expected.append(alloc, null);

    for ([_]usize{ stream.items.len + 1, smith.valueRangeAtMost(u16, 1, 64) }) |max_chunk| {
        var source = ChunkedTestSource{ .bytes = stream.items, .max_chunk = max_chunk };
        var reader = Reader.initForTesting(&source, ChunkedTestSource.read);
        for (expected.items) |want| {
            const got = (try reader.readLineWithLimit(alloc, limit)) orelse return error.TestExpectedLine;
            switch (got) {
                .line => |line| {
                    defer alloc.free(line);
                    try std.testing.expectEqualStrings(want orelse return error.TestExpectedOverflow, line);
                },
                .overflow => try std.testing.expect(want == null),
            }
        }
        try std.testing.expect((try reader.readLineWithLimit(alloc, limit)) == null);
    }
}
