//! Wire format: MCP's JSON-RPC 2.0 messages.
//!
//! Decoding scans one message once with `std.json.Scanner` and returns slices
//! of the input: no allocation, no copies, no tree. Encoding streams through
//! `std.json.Stringify` into the caller's writer. fx already links both, so
//! this file adds only its own logic to the fx binary.
//!
//! Encoded messages never contain a CR or LF byte, so each is one stdio line.

const std = @import("std");

/// Ids the client allocates: integers from 1, never reused.
pub const RequestId = u64;

/// The largest id the client sends: 2^53 - 1, so servers that read JSON
/// numbers as doubles (JavaScript) see every id exactly.
pub const max_request_id: RequestId = (1 << 53) - 1;

/// Error codes the client handles or sends.
pub const code = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
    pub const header_mismatch: i64 = -32020;
    pub const missing_required_client_capability: i64 = -32021;
    pub const unsupported_protocol_version: i64 = -32022;
    /// Resource not found from 2025-era servers; still accepted.
    pub const legacy_resource_not_found: i64 = -32002;
};

pub const Message = union(enum) {
    response: Response,
    notification: Notification,
    /// 2025 only: a request from the server, such as ping or elicitation/create.
    request: ServerRequest,
};

pub const Response = struct {
    /// The id when it is one the client could have issued: an integer, or a
    /// string of plain decimal digits (some servers echo ids as strings). Null
    /// when the id is null, absent, or anything else, so the response can't
    /// be matched to a request.
    id: ?RequestId,
    body: union(enum) {
        result: Result,
        failure: Failure,
    },
};

pub const ResultKind = enum { complete, input_required, unrecognized };

pub const Result = struct {
    /// The whole result object.
    raw: []const u8,
    /// A missing `resultType` means complete; an unknown one is unrecognized,
    /// which the caller treats as invalid.
    kind: ResultKind,
};

pub const Failure = struct {
    code: i64,
    /// The message as a JSON string literal, with its quotes and escapes.
    message: []const u8,
    /// Raw JSON, when present.
    data: ?[]const u8,
};

pub const Notification = struct {
    method: []const u8,
    params: ?[]const u8,
};

pub const ServerRequest = struct {
    /// The raw id, echoed unchanged in the answer.
    id: []const u8,
    method: []const u8,
    params: ?[]const u8,
};

pub const DecodeError = error{
    InvalidJson,
    TooDeep,
    NotAnObject,
    NotAnArray,
    NotJsonRpc2,
    DuplicateField,
    /// The fields don't describe exactly one kind of message.
    Ambiguous,
    InvalidId,
    /// Not a string, or written with escapes.
    InvalidMethod,
    InvalidParams,
    InvalidResult,
    InvalidErrorObject,
};

/// Scanner nesting stack. 512 bytes allow about 2,000 levels of nesting;
/// deeper input is `TooDeep`.
const scan_stack_bytes = 512;

const envelope_fields = [_][]const u8{ "jsonrpc", "id", "method", "params", "result", "error" };

/// Decodes one complete message. Returned slices point into `input`.
pub fn decode(input: []const u8) DecodeError!Message {
    var found: [envelope_fields.len]?[]const u8 = undefined;
    try objectFields(input, &envelope_fields, &found);
    const version, const id, const method, const params, const result, const failure = found;

    const is_2_0 = if (version) |v| std.mem.eql(u8, v, "\"2.0\"") else false;
    if (!is_2_0) return error.NotJsonRpc2;
    if (params) |p| if (p[0] != '{') return error.InvalidParams;

    if (method) |m| {
        if (result != null or failure != null) return error.Ambiguous;
        const name = plainString(m) orelse return error.InvalidMethod;
        const raw_id = id orelse return .{ .notification = .{ .method = name, .params = params } };
        if (!isRequestId(raw_id)) return error.InvalidId;
        return .{ .request = .{ .id = raw_id, .method = name, .params = params } };
    }

    if (params != null or (result == null) == (failure == null)) return error.Ambiguous;
    const response_id = try ownId(id);
    if (result) |r| {
        if (r[0] != '{') return error.InvalidResult;
        return .{ .response = .{ .id = response_id, .body = .{ .result = .{ .raw = r, .kind = try resultKind(r) } } } };
    }
    return .{ .response = .{ .id = response_id, .body = .{ .failure = try failureOf(failure.?) } } };
}

/// Finds the fields listed in `names` in the JSON object `object` and stores
/// each raw value, a slice of `object`, at the same index in `out`. Other
/// fields, and keys written with escapes, are skipped. A wanted field that
/// appears twice is an error, so a message can't say two things at once.
pub fn objectFields(object: []const u8, names: []const []const u8, out: []?[]const u8) DecodeError!void {
    std.debug.assert(names.len == out.len);
    @memset(out, null);
    var stack: [scan_stack_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), object);
    defer scanner.deinit();

    if ((try nextToken(&scanner)) != .object_begin) return error.NotAnObject;
    while (true) {
        var token = try nextToken(&scanner);
        if (token == .object_end) break;
        // A key with escapes arrives in pieces; the last piece is a string.
        var escaped = false;
        const key = while (true) : (token = try nextToken(&scanner)) switch (token) {
            .string => |piece| break piece,
            else => escaped = true,
        };
        _ = scanner.peekNextTokenType() catch return error.InvalidJson;
        const start = scanner.cursor;
        try skip(&scanner);
        if (escaped) continue;
        for (names, out) |name, *slot| {
            if (!std.mem.eql(u8, key, name)) continue;
            if (slot.* != null) return error.DuplicateField;
            slot.* = object[start..scanner.cursor];
        }
    }
    if ((try nextToken(&scanner)) != .end_of_document) return error.InvalidJson;
}

/// Walks the elements of a JSON array, each as a raw slice of the input.
/// Holds its own scanner stack, so it must stay in place between `init` and
/// the last `next`.
pub const Elements = struct {
    array: []const u8,
    stack: [scan_stack_bytes]u8,
    fba: std.heap.FixedBufferAllocator,
    scanner: std.json.Scanner,

    pub fn init(e: *Elements, array: []const u8) DecodeError!void {
        e.array = array;
        e.fba = .init(&e.stack);
        e.scanner = .initCompleteInput(e.fba.allocator(), array);
        if ((try nextToken(&e.scanner)) != .array_begin) return error.NotAnArray;
    }

    /// The next element, or null after the last one once the whole input
    /// has been checked.
    pub fn next(e: *Elements) DecodeError!?[]const u8 {
        if ((e.scanner.peekNextTokenType() catch return error.InvalidJson) == .array_end) {
            _ = try nextToken(&e.scanner);
            if ((try nextToken(&e.scanner)) != .end_of_document) return error.InvalidJson;
            return null;
        }
        const start = e.scanner.cursor;
        try skip(&e.scanner);
        return e.array[start..e.scanner.cursor];
    }
};

/// Walks the fields of a JSON object: each key as its raw token, quotes and
/// escapes included, and its raw value, both slices of the input. Holds its
/// own scanner stack, so it must stay in place between `init` and the last
/// `next`.
pub const Fields = struct {
    object: []const u8,
    stack: [scan_stack_bytes]u8,
    fba: std.heap.FixedBufferAllocator,
    scanner: std.json.Scanner,

    pub const Field = struct { key: []const u8, value: []const u8 };

    pub fn init(f: *Fields, object: []const u8) DecodeError!void {
        f.object = object;
        f.fba = .init(&f.stack);
        f.scanner = .initCompleteInput(f.fba.allocator(), object);
        if ((try nextToken(&f.scanner)) != .object_begin) return error.NotAnObject;
    }

    /// The next field, or null after the last one once the whole input has
    /// been checked.
    pub fn next(f: *Fields) DecodeError!?Field {
        const before = f.scanner.cursor;
        var token = try nextToken(&f.scanner);
        if (token == .object_end) {
            if ((try nextToken(&f.scanner)) != .end_of_document) return error.InvalidJson;
            return null;
        }
        // A key with escapes arrives in pieces; the last piece is a string.
        while (token != .string) token = try nextToken(&f.scanner);
        const key_end = f.scanner.cursor;
        const quote = std.mem.findScalarPos(u8, f.object, before, '"') orelse return error.InvalidJson;
        _ = f.scanner.peekNextTokenType() catch return error.InvalidJson;
        const start = f.scanner.cursor;
        try skip(&f.scanner);
        return .{ .key = f.object[quote..key_end], .value = f.object[start..f.scanner.cursor] };
    }
};

/// Whether the JSON array `array` holds the string `needle`. A string written
/// with escapes never matches, and other elements are skipped.
pub fn arrayHasString(array: []const u8, needle: []const u8) DecodeError!bool {
    var elements: Elements = undefined;
    try elements.init(array);
    var found = false;
    while (try elements.next()) |value| {
        if (value.len == needle.len + 2 and value[0] == '"' and std.mem.eql(u8, value[1 .. value.len - 1], needle)) found = true;
    }
    return found;
}

fn nextToken(scanner: *std.json.Scanner) DecodeError!std.json.Token {
    return scanner.next() catch |err| switch (err) {
        error.OutOfMemory => error.TooDeep,
        else => error.InvalidJson,
    };
}

fn skip(scanner: *std.json.Scanner) DecodeError!void {
    scanner.skipValue() catch |err| return switch (err) {
        error.OutOfMemory => error.TooDeep,
        else => error.InvalidJson,
    };
}

/// The contents of a raw JSON string written without escapes, or null for
/// anything else.
pub fn plainString(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    const contents = raw[1 .. raw.len - 1];
    if (std.mem.findScalar(u8, contents, '\\') != null) return null;
    return contents;
}

/// A JSON string token's contents, unescaped: the token's own bytes when it has
/// no escapes, else a copy in `a`. Null when `raw` isn't a string.
pub fn decodeString(a: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (plainString(raw)) |s| return s;
    if (raw.len < 2 or raw[0] != '"') return null;
    var scanner: std.json.Scanner = .initCompleteInput(a, raw);
    defer scanner.deinit();
    const token = scanner.nextAlloc(a, .alloc_always) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return switch (token) {
        .allocated_string => |s| s,
        else => null,
    };
}

/// JSON-RPC ids are strings or integers, never null.
fn isRequestId(raw: []const u8) bool {
    if (raw[0] == '"') return true;
    if (raw[0] != '-' and !std.ascii.isDigit(raw[0])) return false;
    return std.mem.findAny(u8, raw, ".eE") == null;
}

fn ownId(raw: ?[]const u8) DecodeError!?RequestId {
    const value = raw orelse return null;
    return switch (value[0]) {
        '"' => decimal(value[1 .. value.len - 1]),
        '0'...'9' => decimal(value),
        '-', 'n' => null,
        else => error.InvalidId,
    };
}

/// Plain decimal digits without a leading zero, as the client writes its ids.
/// A raw JSON integer that is non-negative and fits in 64 bits, or null.
pub fn decimal(digits: []const u8) ?RequestId {
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return null;
    var value: RequestId = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
        value = std.math.mul(RequestId, value, 10) catch return null;
        value = std.math.add(RequestId, value, c - '0') catch return null;
    }
    return value;
}

fn resultKind(result: []const u8) DecodeError!ResultKind {
    var found: [1]?[]const u8 = undefined;
    try objectFields(result, &.{"resultType"}, &found);
    const value = found[0] orelse return .complete;
    if (std.mem.eql(u8, value, "\"complete\"")) return .complete;
    if (std.mem.eql(u8, value, "\"input_required\"")) return .input_required;
    return .unrecognized;
}

fn failureOf(raw: []const u8) DecodeError!Failure {
    var found: [3]?[]const u8 = undefined;
    objectFields(raw, &.{ "code", "message", "data" }, &found) catch |err| return switch (err) {
        error.NotAnObject => error.InvalidErrorObject,
        else => err,
    };
    const code_raw = found[0] orelse return error.InvalidErrorObject;
    const message = found[1] orelse return error.InvalidErrorObject;
    if (message[0] != '"') return error.InvalidErrorObject;
    // Error codes are integers; the scanner has already checked the syntax.
    const value = std.fmt.parseInt(i64, code_raw, 10) catch return error.InvalidErrorObject;
    return .{ .code = value, .message = message, .data = found[2] };
}

pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
};

/// Per-request `_meta`.
pub const Meta = struct {
    /// 2026-07-28 fields, required together on every request. Null on 2025 requests.
    modern: ?Modern = null,
    /// Opts the request into progress notifications. The client uses the request id.
    progress_token: ?RequestId = null,

    pub const Modern = struct {
        protocol_version: []const u8,
        /// A JSON object; `{}` declares no capabilities.
        client_capabilities: []const u8,
        client_info: ?Implementation = null,
    };
};

pub const EncodeError = std.Io.Writer.Error || error{InvalidRawJson};

/// Streams one message. Start it with `request`, `notification`, or
/// `result`, add fields with `field` followed by `string`, `int`, or `raw`,
/// and close it with `end`. Does not write the newline or flush.
pub const Writer = struct {
    json: std.json.Stringify,

    /// `id` is at most `max_request_id`.
    pub fn request(out: *std.Io.Writer, id: RequestId, method: []const u8, meta: Meta) EncodeError!Writer {
        var w = try envelope(out);
        try w.json.objectField("id");
        try w.int(@intCast(id));
        try w.openParams(method, meta);
        return w;
    }

    /// A notification has no id.
    pub fn notification(out: *std.Io.Writer, method: []const u8, meta: Meta) EncodeError!Writer {
        var w = try envelope(out);
        try w.openParams(method, meta);
        return w;
    }

    /// 2025 only: answers a server request, echoing its raw id.
    pub fn result(out: *std.Io.Writer, server_id: []const u8) EncodeError!Writer {
        return reply(out, server_id, "result");
    }

    pub fn field(w: *Writer, name: []const u8) EncodeError!void {
        try w.json.objectField(name);
    }

    pub fn string(w: *Writer, value: []const u8) EncodeError!void {
        try w.json.write(value);
    }

    pub fn int(w: *Writer, value: i64) EncodeError!void {
        try w.json.write(value);
    }

    /// Writes one already-encoded JSON value after checking it is exactly one
    /// valid value. CR and LF can only be whitespace in valid JSON, so they
    /// become spaces.
    pub fn raw(w: *Writer, value: []const u8) EncodeError!void {
        try validate(value);
        try w.json.beginWriteRaw();
        defer w.json.endWriteRaw();
        var rest = value;
        while (std.mem.findAny(u8, rest, "\r\n")) |index| {
            try w.json.writer.writeAll(rest[0..index]);
            try w.json.writer.writeByte(' ');
            rest = rest[index + 1 ..];
        }
        try w.json.writer.writeAll(rest);
    }

    /// Closes `params` (or `result`) and the message.
    pub fn end(w: *Writer) EncodeError!void {
        try w.json.endObject();
        try w.json.endObject();
    }

    /// Opens an answer to a server request: the envelope, its id, and `member`.
    fn reply(out: *std.Io.Writer, server_id: []const u8, member: []const u8) EncodeError!Writer {
        var w = try envelope(out);
        try w.json.objectField("id");
        try w.raw(server_id);
        try w.json.objectField(member);
        try w.json.beginObject();
        return w;
    }

    fn envelope(out: *std.Io.Writer) EncodeError!Writer {
        var w: Writer = .{ .json = .{ .writer = out } };
        try w.json.beginObject();
        try w.json.objectField("jsonrpc");
        try w.json.write("2.0");
        return w;
    }

    fn openParams(w: *Writer, method: []const u8, meta: Meta) EncodeError!void {
        try w.json.objectField("method");
        try w.json.write(method);
        try w.json.objectField("params");
        try w.json.beginObject();
        if (meta.modern == null and meta.progress_token == null) return;
        try w.json.objectField("_meta");
        try w.json.beginObject();
        if (meta.progress_token) |token| {
            try w.json.objectField("progressToken");
            try w.int(@intCast(token));
        }
        if (meta.modern) |modern| {
            try w.json.objectField("io.modelcontextprotocol/protocolVersion");
            try w.json.write(modern.protocol_version);
            try w.json.objectField("io.modelcontextprotocol/clientCapabilities");
            try w.raw(modern.client_capabilities);
            if (modern.client_info) |info| {
                try w.json.objectField("io.modelcontextprotocol/clientInfo");
                try w.json.write(info);
            }
        }
        try w.json.endObject();
    }
};

/// 2025 only: answers a server request with an error. From -32000 to -32099,
/// only the spec's defined codes (-32020 to -32022) are sent: the legacy
/// range is not used at all, and the rest is reserved for the spec.
pub fn writeFailure(out: *std.Io.Writer, server_id: []const u8, failure_code: i64, message: []const u8) EncodeError!void {
    std.debug.assert(failure_code > -32000 or failure_code < -32099 or
        (failure_code >= code.unsupported_protocol_version and failure_code <= code.header_mismatch));
    var w = try Writer.reply(out, server_id, "error");
    try w.field("code");
    try w.int(failure_code);
    try w.field("message");
    try w.string(message);
    try w.end();
}

fn validate(value: []const u8) error{InvalidRawJson}!void {
    var stack: [scan_stack_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), value);
    defer scanner.deinit();
    scanner.skipValue() catch return error.InvalidRawJson;
    const last = scanner.next() catch return error.InvalidRawJson;
    if (last != .end_of_document) return error.InvalidRawJson;
}

const testing = std.testing;

fn within(input: []const u8, part: []const u8) bool {
    const start = @intFromPtr(input.ptr);
    const at = @intFromPtr(part.ptr);
    return at >= start and at + part.len <= start + input.len;
}

test "decodes results with numeric, string, and foreign ids" {
    const numeric = try decode(
        \\{"jsonrpc":"2.0","id":7,"result":{"tools":[],"resultType":"complete"}}
    );
    try testing.expectEqual(@as(?RequestId, 7), numeric.response.id);
    try testing.expectEqual(ResultKind.complete, numeric.response.body.result.kind);
    try testing.expectEqualStrings("{\"tools\":[],\"resultType\":\"complete\"}", numeric.response.body.result.raw);

    const stringly = try decode(" {\"result\":{},\"id\":\"12\",\"jsonrpc\":\"2.0\"} ");
    try testing.expectEqual(@as(?RequestId, 12), stringly.response.id);

    for ([_][]const u8{ "\"abc\"", "\"012\"", "\"1_0\"", "-3", "null", "1.5", "99999999999999999999" }) |foreign| {
        var buffer: [96]u8 = undefined;
        const input = try std.fmt.bufPrint(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{foreign});
        try testing.expectEqual(@as(?RequestId, null), (try decode(input)).response.id);
    }
    try testing.expectEqual(@as(?RequestId, null), (try decode("{\"jsonrpc\":\"2.0\",\"result\":{}}")).response.id);
}

test "an absent resultType is complete and an unknown one is unrecognized" {
    const cases = [_]struct { []const u8, ResultKind }{
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", .complete },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"requestState\":\"x\"}}", .input_required },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"task\"}}", .unrecognized },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":7}}", .unrecognized },
    };
    for (cases) |case| try testing.expectEqual(case[1], (try decode(case[0])).response.body.result.kind);
}

test "decodes errors, including the spec's unsupported-version example" {
    const message = try decode(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version",
        \\ "data":{"supported":["2026-07-28","2025-11-25"],"requested":"1900-01-01"}}}
    );
    const failure = message.response.body.failure;
    try testing.expectEqual(code.unsupported_protocol_version, failure.code);
    try testing.expectEqualStrings("\"Unsupported protocol version\"", failure.message);
    try testing.expect(std.mem.startsWith(u8, failure.data.?, "{\"supported\":["));

    const no_id = try decode("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
    try testing.expectEqual(@as(?RequestId, null), no_id.response.id);
}

test "a key written with escapes never matches a field" {
    // The scanner splits this key into pieces, and the last one is "id".
    const message = try decode("{\"jsonrpc\":\"2.0\",\"x\\u0000id\":5,\"id\":1,\"result\":{}}");
    try testing.expectEqual(@as(?RequestId, 1), message.response.id);
}

test "walks an object's fields with their keys exactly as written" {
    var fields: Fields = undefined;
    try fields.init("{ \"a\": 1, \"b\\u00e9\\\"\" : {\"x\":[2]} ,\"\":null}");
    const want = [_][2][]const u8{ .{ "\"a\"", "1" }, .{ "\"b\\u00e9\\\"\"", "{\"x\":[2]}" }, .{ "\"\"", "null" } };
    for (want) |w| {
        const f = (try fields.next()).?;
        try testing.expectEqualStrings(w[0], f.key);
        try testing.expectEqualStrings(w[1], f.value);
    }
    try testing.expectEqual(@as(?Fields.Field, null), try fields.next());
    var bad: Fields = undefined;
    try testing.expectError(error.NotAnObject, bad.init("[1]"));
    try bad.init("{\"a\":1} x");
    _ = try bad.next();
    try testing.expectError(error.InvalidJson, bad.next());
}

test "decodes string tokens with or without escapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https://x/y", (try decodeString(a, "\"https://x/y\"")).?);
    try testing.expectEqualStrings("https://x/y\u{e9}", (try decodeString(a, "\"https:\\/\\/x\\/y\\u00e9\"")).?);
    try testing.expectEqual(@as(?[]const u8, null), try decodeString(a, "42"));
    try testing.expectEqual(@as(?[]const u8, null), try decodeString(a, "\"a\\x\""));
}

test "finds a plain string in an array" {
    const list = " [ \"2025-11-25\" , {\"x\":[1]}, 7, \"2026-07-28\" ] ";
    try testing.expect(try arrayHasString(list, "2026-07-28"));
    try testing.expect(try arrayHasString(list, "2025-11-25"));
    try testing.expect(!try arrayHasString(list, "2026-07"));
    try testing.expect(!try arrayHasString("[\"2026\\u002d07-28\"]", "2026-07-28"));
    try testing.expect(!try arrayHasString("[]", "x"));
    try testing.expectError(error.NotAnArray, arrayHasString("{}", "x"));
    try testing.expectError(error.InvalidJson, arrayHasString("[\"x\"", "x"));
}

test "decodes notifications and 2025 server requests" {
    const progress = try decode(
        \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":3,"progress":0.5}}
    );
    try testing.expectEqualStrings("notifications/progress", progress.notification.method);
    try testing.expectEqualStrings("{\"progressToken\":3,\"progress\":0.5}", progress.notification.params.?);

    const ping = try decode("{\"jsonrpc\":\"2.0\",\"id\":\"srv-1\",\"method\":\"ping\"}");
    try testing.expectEqualStrings("\"srv-1\"", ping.request.id);
    try testing.expectEqual(@as(?[]const u8, null), ping.request.params);
}

test "rejects malformed and ambiguous messages" {
    const deep = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"a\":" ++ "[" ** 5000 ++ "]" ** 5000 ++ "}}";
    const cases = [_]struct { []const u8, DecodeError }{
        .{ "", error.InvalidJson },
        .{ "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}]", error.NotAnObject },
        .{ "{\"id\":1,\"result\":{}}", error.NotJsonRpc2 },
        .{ "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}", error.NotJsonRpc2 },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1}", error.Ambiguous },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{\"code\":1,\"message\":\"x\"}}", error.Ambiguous },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"result\":{}}", error.Ambiguous },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"id\":2,\"result\":{}}", error.DuplicateField },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"to\\u006fls/list\"}", error.InvalidMethod },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":7}", error.InvalidMethod },
        .{ "{\"jsonrpc\":\"2.0\",\"method\":\"m\",\"params\":[1]}", error.InvalidParams },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"m\"}", error.InvalidId },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{}}", error.InvalidId },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}", error.InvalidResult },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1.5,\"message\":\"x\"}}", error.InvalidErrorObject },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"message\":\"x\"}}", error.InvalidErrorObject },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":\"boom\"}", error.InvalidErrorObject },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}} x", error.InvalidJson },
        .{ deep, error.TooDeep },
    };
    for (cases) |case| try testing.expectError(case[1], decode(case[0]));
}

test "mutated messages never crash and slices stay inside the input" {
    const seeds = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"a\\\"b\"}],\"resultType\":\"complete\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"9\",\"error\":{\"code\":-32602,\"message\":\"bad\",\"data\":[1,2]}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":1,\"progress\":2}}",
    };
    var prng: std.Random.DefaultPrng = .init(0xdec0de);
    const random = prng.random();
    var buffer: [256]u8 = undefined;
    var decoded: usize = 0;
    for (0..20_000) |_| {
        const seed = seeds[random.uintLessThan(usize, seeds.len)];
        @memcpy(buffer[0..seed.len], seed);
        var len = seed.len;
        for (0..random.intRangeAtMost(usize, 1, 3)) |_| switch (random.uintLessThan(u8, 3)) {
            0 => if (len > 0) {
                buffer[random.uintLessThan(usize, len)] = random.int(u8);
            },
            1 => len = random.intRangeAtMost(usize, 0, len),
            else => if (len < buffer.len) {
                const at = random.uintLessThan(usize, len + 1);
                std.mem.copyBackwards(u8, buffer[at + 1 .. len + 1], buffer[at..len]);
                buffer[at] = "{}[]\",:0\\"[random.uintLessThan(usize, 10)];
                len += 1;
            },
        };
        const input = buffer[0..len];
        const message = decode(input) catch continue;
        decoded += 1;
        switch (message) {
            .response => |r| switch (r.body) {
                .result => |res| try testing.expect(within(input, res.raw)),
                .failure => |f| {
                    try testing.expect(within(input, f.message));
                    if (f.data) |d| try testing.expect(within(input, d));
                },
            },
            .notification => |n| {
                try testing.expect(within(input, n.method));
                if (n.params) |p| try testing.expect(within(input, p));
            },
            .request => |q| try testing.expect(within(input, q.id) and within(input, q.method)),
        }
    }
    try testing.expect(decoded > 0);
}

test "encodes a 2026 request with _meta first in params" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: Writer = try .request(&out.writer, 7, "tools/call", .{
        .progress_token = 7,
        .modern = .{
            .protocol_version = "2026-07-28",
            .client_capabilities = "{}",
            .client_info = .{ .name = "fx", .version = "0.0.0" },
        },
    });
    try w.field("name");
    try w.string("search");
    try w.field("arguments");
    try w.raw("{\n  \"q\": \"a\\nb\"\r\n}");
    try w.end();
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"_meta\":{\"progressToken\":7," ++
            "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}," ++
            "\"io.modelcontextprotocol/clientInfo\":{\"name\":\"fx\",\"version\":\"0.0.0\"}}," ++
            "\"name\":\"search\",\"arguments\":{   \"q\": \"a\\nb\"  }}}",
        out.written(),
    );

    const back = try decode(out.written());
    try testing.expectEqualStrings("tools/call", back.request.method);
    try testing.expectEqualStrings("7", back.request.id);
}

test "encodes 2025 requests, notifications, and answers to server requests" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var initialized: Writer = try .notification(&out.writer, "notifications/initialized", .{});
    try initialized.end();
    try out.writer.writeByte('\n');
    var list: Writer = try .request(&out.writer, 2, "tools/list", .{});
    try list.end();
    try out.writer.writeByte('\n');
    var pong: Writer = try .result(&out.writer, "\"srv-1\"");
    try pong.end();
    try out.writer.writeByte('\n');
    try writeFailure(&out.writer, "4", code.invalid_params, "unsupported elicitation mode");

    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":\"srv-1\",\"result\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32602,\"message\":\"unsupported elicitation mode\"}}",
        out.written(),
    );
}

test "raw values must be exactly one valid JSON value" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for ([_][]const u8{ "", "{", "{} {}", "{'a':1}", "nul" }) |bad| {
        var w: Writer = try .request(&out.writer, 1, "tools/call", .{});
        try w.field("arguments");
        try testing.expectError(error.InvalidRawJson, w.raw(bad));
    }
}

test "encoded messages never contain CR or LF" {
    var prng: std.Random.DefaultPrng = .init(0x11fe);
    const random = prng.random();
    var text: [32]u8 = undefined;
    for (0..2_000) |_| {
        for (&text) |*c| c.* = random.int(u8);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var w: Writer = try .notification(&out.writer, &text, .{});
        try w.field(&text);
        try w.string(&text);
        try w.end();
        try testing.expect(std.mem.findAny(u8, out.written(), "\r\n") == null);
    }
}
