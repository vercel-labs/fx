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

/// The id of a line `decode` refused that is shaped like a response: an
/// object with no `method` and an id the client could have issued. The
/// request it names fails with it.
pub fn responseId(input: []const u8) ?RequestId {
    var found: [envelope_fields.len]?[]const u8 = undefined;
    objectFields(input, &envelope_fields, &found) catch return null;
    if (found[2] != null) return null;
    return ownId(found[1]) catch null;
}

/// Finds the fields listed in `names` in the JSON object `object` and stores
/// each raw value, a slice of `object`, at the same index in `out`. A key is
/// the name it spells once decoded, as `std.json` reads it: `"is\u0045rror"`
/// is `isError`. Other fields are skipped. A wanted field that appears twice,
/// however each is spelled, is an error, so a message can't say two things at
/// once.
pub fn objectFields(object: []const u8, names: []const []const u8, out: []?[]const u8) DecodeError!void {
    std.debug.assert(names.len == out.len);
    @memset(out, null);
    var stack: [scan_stack_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), object);
    defer scanner.deinit();

    if ((try nextToken(&scanner)) != .object_begin) return error.NotAnObject;
    while (true) {
        const before = scanner.cursor;
        var token = try nextToken(&scanner);
        if (token == .object_end) break;
        // A key with escapes arrives in pieces; the last piece is a string.
        var escaped = false;
        const key = while (true) : (token = try nextToken(&scanner)) switch (token) {
            .string => |piece| break piece,
            else => escaped = true,
        };
        // The key as written, quotes included: the first quote after the last value and the comma.
        const key_token = if (escaped) object[std.mem.findScalarPos(u8, object, before, '"') orelse return error.InvalidJson .. scanner.cursor] else key;
        _ = scanner.peekNextTokenType() catch return error.InvalidJson;
        const start = scanner.cursor;
        try skip(&scanner);
        for (names, out) |name, *slot| {
            if (if (escaped) !spells(key_token, name) else !std.mem.eql(u8, key, name)) continue;
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

/// Whether two JSON string tokens, quotes included, spell the same string
/// once decoded: `"caf\u00e9"` and `"café"`, `"a\/b"` and `"a/b"`, and a
/// surrogate pair and the character in UTF-8 are one string each. This is
/// JSON's equality, which is `std.json`'s. It decodes both tokens as it goes
/// and allocates nothing. A token that is not a string, or holds an escape or
/// UTF-8 that is not valid, matches only a token with the same bytes. Tokens
/// that reach here have been through the scanner, which refuses invalid ones.
pub fn sameString(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (!isStringToken(a) or !isStringToken(b)) return false;
    var x: Decoder = .{ .raw = a[1 .. a.len - 1] };
    var y: Decoder = .{ .raw = b[1 .. b.len - 1] };
    return sameDecoded(&x, &y);
}

/// Whether the string token `token`, quotes included, spells `name`, which is
/// already decoded.
fn spells(token: []const u8, name: []const u8) bool {
    if (!isStringToken(token)) return false;
    var x: Decoder = .{ .raw = token[1 .. token.len - 1] };
    var y: Decoder = .{ .raw = name, .literal = true };
    return sameDecoded(&x, &y);
}

fn isStringToken(raw: []const u8) bool {
    return raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"';
}

fn sameDecoded(x: *Decoder, y: *Decoder) bool {
    while (true) {
        const p = x.next() catch return false;
        const q = y.next() catch return false;
        if (p == null or q == null) return p == null and q == null;
        if (p.? != q.?) return false;
    }
}

/// The code points of the inside of a JSON string token, one at a time. With
/// `literal` set the bytes are a decoded string, and no byte is an escape.
const Decoder = struct {
    raw: []const u8,
    at: usize = 0,
    literal: bool = false,

    const Invalid = error{Invalid};

    /// The next code point, or null at the end. A surrogate pair written as
    /// two escapes is one code point, and a lone surrogate is invalid.
    fn next(d: *Decoder) Invalid!?u21 {
        if (d.at >= d.raw.len) return null;
        const c = d.raw[d.at];
        if (c != '\\' or d.literal) {
            const n = std.unicode.utf8ByteSequenceLength(c) catch return error.Invalid;
            if (d.at + n > d.raw.len) return error.Invalid;
            const bytes = d.raw[d.at..][0..n];
            // Each decoder refuses an overlong form; the three-byte one also refuses an encoded surrogate half.
            const code_point: u21 = switch (n) {
                1 => c,
                2 => std.unicode.utf8Decode2(bytes[0..2].*) catch return error.Invalid,
                3 => std.unicode.utf8Decode3(bytes[0..3].*) catch return error.Invalid,
                4 => std.unicode.utf8Decode4(bytes[0..4].*) catch return error.Invalid,
                else => return error.Invalid,
            };
            d.at += n;
            return code_point;
        }
        if (d.at + 1 >= d.raw.len) return error.Invalid;
        const escape = d.raw[d.at + 1];
        d.at += 2;
        switch (escape) {
            '"' => return '"',
            '\\' => return '\\',
            '/' => return '/',
            'b' => return 0x08,
            'f' => return 0x0c,
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'u' => {},
            else => return error.Invalid,
        }
        const unit = try d.hex4();
        if (unit >= 0xdc00 and unit <= 0xdfff) return error.Invalid;
        if (unit < 0xd800 or unit > 0xdbff) return unit;
        // A high surrogate needs a low one, written as the next escape.
        if (d.at + 1 >= d.raw.len or d.raw[d.at] != '\\' or d.raw[d.at + 1] != 'u') return error.Invalid;
        d.at += 2;
        const low = try d.hex4();
        if (low < 0xdc00 or low > 0xdfff) return error.Invalid;
        return 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (low - 0xdc00);
    }

    /// Four hex digits, in either case, and nothing else: no sign.
    fn hex4(d: *Decoder) Invalid!u16 {
        if (d.at + 4 > d.raw.len) return error.Invalid;
        var unit: u16 = 0;
        for (d.raw[d.at..][0..4]) |digit| unit = unit * 16 + (std.fmt.charToDigit(digit, 16) catch return error.Invalid);
        d.at += 4;
        return unit;
    }
};

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

/// The raw value found for a name, or a failure that says nothing was found, instead of a crash on `.?`.
fn expectRaw(want: []const u8, got: ?[]const u8) !void {
    try testing.expectEqualStrings(want, got orelse "(the name was not found)");
}

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
        const input = try std.mem.print(&buffer, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{foreign});
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

test "a refused line shaped like a response still names its request" {
    for ([_][]const u8{
        "{\"id\":3,\"result\":{}}",
        "{\"jsonrpc\":\"1.0\",\"id\":3,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"3\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{},\"error\":{\"code\":1,\"message\":\"x\"}}",
    }) |line| {
        if (decode(line)) |_| return error.TestUnexpectedResult else |_| {}
        try testing.expectEqual(@as(?RequestId, 3), responseId(line));
    }
    // A request, a null or foreign id, and a line that isn't an object name none.
    for ([_][]const u8{ "{\"id\":3,\"method\":\"ping\",\"jsonrpc\":\"1.0\"}", "{\"id\":null}", "{\"id\":-1}", "[3]", "not json" }) |line|
        try testing.expectEqual(@as(?RequestId, null), responseId(line));
}

test "a key written with escapes never matches a field" {
    // The scanner splits this key into pieces, and the last one is "id".
    const message = try decode("{\"jsonrpc\":\"2.0\",\"x\\u0000id\":5,\"id\":1,\"result\":{}}");
    try testing.expectEqual(@as(?RequestId, 1), message.response.id);
}

test "a name written with escapes is read as the name it spells" {
    var mode: [1]?[]const u8 = undefined;
    try objectFields("{\"m\\u006fde\":\"url\"}", &.{"mode"}, &mode);
    try expectRaw("\"url\"", mode[0]);
    // Every letter escaped, and capital hex digits.
    try objectFields("{\"\\u006D\\u006F\\u0064\\u0065\":\"form\"}", &.{"mode"}, &mode);
    try expectRaw("\"form\"", mode[0]);
    // Next to a plain name, and in the order the names were asked for.
    var two: [2]?[]const u8 = undefined;
    try objectFields("{\"url\":1,\"m\\u006fde\":2}", &.{ "mode", "url" }, &two);
    try expectRaw("2", two[0]);
    try expectRaw("1", two[1]);
    // A message the engine reads as an envelope.
    const message = try decode("{\"jsonrpc\":\"2.0\",\"i\\u0064\":7,\"result\":{}}");
    try testing.expectEqual(@as(?RequestId, 7), message.response.id);
}

test "an asked name that holds a backslash or a quote is matched by the key that spells it" {
    // The asked name is already decoded: its backslash is a backslash, not the start of an escape.
    var found: [3]?[]const u8 = undefined;
    const names = [_][]const u8{ "a\\b", "q\"x", "a\\n" };
    try objectFields("{\"a\\\\b\":1,\"q\\\"x\":2,\"a\\\\n\":3}", &names, &found);
    try expectRaw("1", found[0]);
    try expectRaw("2", found[1]);
    try expectRaw("3", found[2]);
    // The same names spelled with escapes of every letter.
    try objectFields("{\"\\u0061\\u005c\\u0062\":4,\"q\\u0022x\":5,\"a\\u005cn\":6}", &names, &found);
    try expectRaw("4", found[0]);
    try expectRaw("5", found[1]);
    try expectRaw("6", found[2]);
}

test "a name seen twice is a duplicate, however either one is written" {
    var mode: [1]?[]const u8 = undefined;
    try testing.expectError(error.DuplicateField, objectFields("{\"mode\":\"form\",\"mode\":\"url\"}", &.{"mode"}, &mode));
    try testing.expectError(error.DuplicateField, objectFields("{\"mode\":\"form\",\"m\\u006fde\":\"url\"}", &.{"mode"}, &mode));
    try testing.expectError(error.DuplicateField, objectFields("{\"m\\u006fde\":\"form\",\"mode\":\"url\"}", &.{"mode"}, &mode));
    try testing.expectError(error.DuplicateField, objectFields("{\"m\\u006fde\":\"form\",\"mo\\u0064e\":\"url\"}", &.{"mode"}, &mode));
    // A name that is not asked for may repeat, plain or written with escapes.
    try objectFields("{\"x\":1,\"x\":2,\"\\u0078\":3,\"mode\":\"form\"}", &.{"mode"}, &mode);
    try expectRaw("\"form\"", mode[0]);
}

test "keys that spell no asked name are skipped, nested ones too" {
    var mode: [1]?[]const u8 = undefined;
    // An escaped key that is longer than any name, one with NUL in it, a surrogate pair, one whose last piece is a
    // name, and an object that holds escaped keys, which is skipped whole.
    const message = "{\"mode\\u0000x\":1,\"\\u0000\":2,\"\\ud83d\\ude00\":3,\"x\\u0000mode\":4," ++
        "\"nested\":{\"m\\u006fde\":\"url\",\"deeper\":{\"mo\\u0064e\":\"url\"}},\"mode\":\"form\"}";
    try objectFields(message, &.{"mode"}, &mode);
    try expectRaw("\"form\"", mode[0]);
    // Nothing asked for is found.
    try objectFields("{\"mode\\u0000\":1}", &.{"mode"}, &mode);
    try testing.expectEqual(@as(?[]const u8, null), mode[0]);
}

test "an object cut at any byte, with names written with escapes, is refused cleanly" {
    const whole = "{\"m\\u006fde\":\"url\",\"x\\ud83d\\ude00\":{\"\\u0061\":[1,2]},\"url\":\"https:\\/\\/e.example\"}";
    var found: [2]?[]const u8 = undefined;
    try objectFields(whole, &.{ "mode", "url" }, &found);
    for (0..whole.len) |cut| {
        if (objectFields(whole[0..cut], &.{ "mode", "url" }, &found)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "an input_required result written with an escaped resultType is still input_required" {
    const message = try decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"result\\u0054ype\":\"input_required\",\"inputRequests\":{}}}");
    try testing.expectEqual(ResultKind.input_required, message.response.body.result.kind);
}

test "a server request with an escaped id is a request, not a notification" {
    const message = try decode("{\"jsonrpc\":\"2.0\",\"i\\u0064\":5,\"method\":\"ping\"}");
    try testing.expectEqual(std.meta.Tag(Message).request, std.meta.activeTag(message));
    // The same request with the key written plainly, and a notification, which has no id.
    const plain = try decode("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}");
    try testing.expectEqual(std.meta.Tag(Message).request, std.meta.activeTag(plain));
    const note = try decode("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}");
    try testing.expectEqual(std.meta.Tag(Message).notification, std.meta.activeTag(note));
}

test "a lone surrogate or an invalid escape in a name is refused as invalid JSON" {
    var found: [1]?[]const u8 = undefined;
    const bad = [_][]const u8{
        "{\"\\ud83d\":1}", // a high surrogate alone
        "{\"\\ude00\":1}", // a low surrogate alone
        "{\"\\ud83dx\":1}", // a high surrogate then a plain letter
        "{\"\\ud83d\\u0041\":1}", // a high surrogate then a letter that is not a low surrogate
        "{\"\\ude00\\ud83d\":1}", // a pair in the wrong order
        "{\"m\\qde\":1}", // an escape that does not exist
        "{\"m\\u12\":1}", // cut hex digits
        "{\"m\\u12zz\":1}", // hex digits that are not
    };
    for (bad) |text| try testing.expectError(error.InvalidJson, objectFields(text, &.{"mode"}, &found));
}

test "thousands of members written with escapes are read in one pass" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const w = &out.writer;
    try w.writeAll("{");
    // 20,000 members whose names are all written with escapes, some holding nested objects.
    for (0..20_000) |i| {
        try w.print("\"k\\u0030\\u{x:0>4}\":{{\"\\u0061\":[{d}]}},", .{ i % 0xffff, i });
    }
    // A name of 100,000 escapes, then the one the reader asks for, written with an escape.
    try w.writeAll("\"");
    for (0..100_000) |_| try w.writeAll("\\u0061");
    try w.writeAll("\":1,\"i\\u0073Error\":true}");
    var found: [1]?[]const u8 = undefined;
    try objectFields(out.written(), &.{"isError"}, &found);
    try expectRaw("true", found[0]);
    // Nested objects with escaped names near the scanner's depth limit are skipped whole.
    var deep: std.Io.Writer.Allocating = .init(arena.allocator());
    try deep.writer.writeAll("{\"x\":");
    for (0..1500) |_| try deep.writer.writeAll("{\"\\u0061\":");
    try deep.writer.writeAll("1");
    for (0..1500) |_| try deep.writer.writeAll("}");
    try deep.writer.writeAll(",\"m\\u006fde\":\"form\"}");
    var mode: [1]?[]const u8 = undefined;
    try objectFields(deep.written(), &.{"mode"}, &mode);
    try expectRaw("\"form\"", mode[0]);
}

test "sameString is JSON's equality of two string tokens" {
    const same = [_][2][]const u8{
        .{ "\"\"", "\"\"" },
        .{ "\"\\u0041\"", "\"A\"" },
        .{ "\"A\"", "\"\\u0041\"" },
        .{ "\"\\u00e9\"", "\"é\"" },
        .{ "\"\\u00E9\"", "\"\\u00e9\"" },
        .{ "\"\\uD83D\\uDE00\"", "\"😀\"" },
        .{ "\"\\ud83d\\ude00\"", "\"\\uD83D\\uDE00\"" },
        .{ "\"\\ud800\\udc00\"", "\"\u{10000}\"" }, // the first astral code point
        .{ "\"\\udbff\\udfff\"", "\"\u{10ffff}\"" }, // the last
        .{ "\"\\ud7ff\"", "\"\u{d7ff}\"" }, // just below the surrogates
        .{ "\"\\ue000\"", "\"\u{e000}\"" }, // just above
        .{ "\"\\uffff\"", "\"\u{ffff}\"" },
        .{ "\"\\u0080\"", "\"\u{80}\"" }, // the first two-byte code point
        .{ "\"\\u07ff\"", "\"\u{7ff}\"" }, // the last
        .{ "\"\\u0800\"", "\"\u{800}\"" }, // the first three-byte one
        .{ "\"\\u20ac\"", "\"€\"" },
        .{ "\"a\\/b\"", "\"a/b\"" },
        .{ "\"\\n\"", "\"\\u000a\"" },
        .{ "\"\\b\\f\\r\\t\"", "\"\\u0008\\u000C\\u000d\\u0009\"" },
        .{ "\"\\\"\\\\\"", "\"\\u0022\\u005c\"" },
        .{ "\"\\u0000\"", "\"\\u0000\"" },
        .{ "\"x\\u00e9y\\ud83d\\ude00z\"", "\"xéy😀z\"" },
    };
    for (same) |pair| {
        testing.expect(sameString(pair[0], pair[1]) and sameString(pair[1], pair[0])) catch |err| {
            std.debug.print("expected the same string: {s} and {s}\n", .{ pair[0], pair[1] });
            return err;
        };
    }
    const different = [_][2][]const u8{
        .{ "\"A\"", "\"a\"" },
        .{ "\"\\u0041\"", "\"B\"" },
        .{ "\"\\u00e9\"", "\"e\"" },
        .{ "\"\\u00e9\"", "\"\\u00e8\"" },
        .{ "\"ab\"", "\"a\"" },
        .{ "\"a\"", "\"ab\"" },
        .{ "\"\\u0041\"", "\"AA\"" },
        .{ "\"\\ud83d\\ude00\"", "\"\\ud83d\\ude01\"" },
        .{ "\"\\ud83d\\ude00\"", "\"😁\"" },
        .{ "\"\\u0041\"", "\"\\u0041\\u0000\"" },
        // An escape or a surrogate that is not valid matches only the same bytes.
        .{ "\"\\u+041\"", "\"A\"" },
        .{ "\"\\u 041\"", "\"A\"" },
        .{ "\"\\u004\"", "\"A\"" },
        .{ "\"\\u00\"", "\"\\u00\"x" },
        .{ "\"\\q\"", "\"q\"" },
        .{ "\"\\ud83d\"", "\"\\uD83D\"" }, // a lone high surrogate, spelled two ways
        .{ "\"\\ude00\"", "\"\\uDE00\"" }, // a lone low one
        .{ "\"\\ud83d\\u0041\"", "\"\\uD83D\\u0041\"" }, // a high surrogate then another escape
        .{ "\"\\ud83dx\"", "\"\\uD83Dx\"" },
        .{ "\"\\ude00\\ud83d\"", "\"\\uDE00\\uD83D\"" }, // the pair the wrong way round
        // UTF-8 that is not valid matches only the same bytes: an overlong form, an encoded surrogate half, a code
        // point past U+10FFFF, a cut sequence, a stray continuation byte.
        .{ "\"\xc0\xaf\"", "\"/\"" },
        .{ "\"\xe0\x80\xaf\"", "\"/\"" },
        .{ "\"\xf0\x80\x80\xaf\"", "\"/\"" },
        .{ "\"\xed\xa0\x80\"", "\"\\ud800\"" },
        .{ "\"\xed\xb0\x80\"", "\"\\udc00\"" },
        // The same encoded half on both sides, then the same text spelled two ways: still not valid.
        .{ "\"\xed\xa0\x80\\u0041\"", "\"\xed\xa0\x80A\"" },
        .{ "\"\xed\xb0\x80\\u0041\"", "\"\xed\xb0\x80A\"" },
        .{ "\"\xf4\x90\x80\x80\"", "\"x\"" },
        .{ "\"\xe2\x82\"", "\"\\u20ac\"" },
        .{ "\"\xc3\"", "\"\\u00c3\"" },
        .{ "\"\x80\"", "\"\\u0080\"" },
        // Not strings.
        .{ "1", "\"1\"" },
        .{ "\"\\u0031\"", "1" },
        .{ "true", "\"true\"" },
        .{ "\"", "\"a\"" },
        // A token whose inside is empty is not the empty string.
        .{ "12", "\"\"" },
        .{ "{}", "\"\"" },
        .{ "[]", "\"\"" },
        .{ "true", "\"ru\"" },
    };
    for (different) |pair| {
        testing.expect(!sameString(pair[0], pair[1]) and !sameString(pair[1], pair[0])) catch |err| {
            std.debug.print("expected different strings: {s} and {s}\n", .{ pair[0], pair[1] });
            return err;
        };
    }
    // The same bytes are the same string, whatever they hold.
    try testing.expect(sameString("1", "1"));
    try testing.expect(sameString("\"\\ud83d\"", "\"\\ud83d\""));
    try testing.expect(sameString("\"\xed\xa0\x80\"", "\"\xed\xa0\x80\""));
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
    const deep = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"a\":" ++ &@as([5000]u8, @splat('[')) ++ &@as([5000]u8, @splat(']')) ++ "}}";
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
                @memmove(buffer[at + 1 .. len + 1], buffer[at..len]);
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
