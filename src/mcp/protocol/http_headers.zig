//! Request headers for Streamable HTTP (2026): the headers that mirror the
//! body, `x-mcp-header` checks and
//! mirroring, and value encoding. Pure: the caller passes
//! an allocator for the header values, normally a per-request arena.

const std = @import("std");
const wire = @import("wire.zig");

pub const Header = std.http.Header;

/// Most `x-mcp-header` annotations in one tool, and the deepest property path.
pub const max_annotations = 32;
pub const max_depth = 8;

/// Whether a header value must be sent base64-wrapped: any byte
/// outside 0x20..0x7E, tab included, a leading or trailing space, or a
/// value that already looks wrapped.
pub fn needsEncoding(value: []const u8) bool {
    for (value) |c| if (c < 0x20 or c > 0x7e) return true;
    if (value.len > 0 and (value[0] == ' ' or value[value.len - 1] == ' ')) return true;
    return std.mem.startsWith(u8, value, "=?base64?") and std.mem.endsWith(u8, value, "?=");
}

/// `value`, or its `=?base64?...?=` form when it can't be sent as is.
pub fn encodeValue(gpa: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!needsEncoding(value)) return value;
    const encoder = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, "=?base64?".len + encoder.calcSize(value.len) + "?=".len);
    @memcpy(out[0..9], "=?base64?");
    _ = encoder.encode(out[9 .. out.len - 2], value);
    @memcpy(out[out.len - 2 ..], "?=");
    return out;
}

pub const Kind = enum { string, integer, boolean };

/// One `x-mcp-header` annotation: the header name part, and the chain of
/// `properties` keys leading to the annotated property. Slices of the schema.
pub const Annotation = struct {
    name: []const u8,
    path: [max_depth][]const u8 = undefined,
    depth: u8 = 0,
    kind: Kind,
};

pub const Invalid = error{
    /// Empty, not an HTTP token, or written with escapes.
    NotToken,
    /// Two annotations differ only in case.
    Duplicate,
    /// On a property that isn't a string, integer, or boolean.
    NotPrimitive,
    /// Anywhere but on a property reached through `properties` keys alone.
    NotReachable,
    /// More annotations or deeper paths than this client handles.
    TooMany,
    /// The schema isn't valid JSON.
    Malformed,
};

/// RFC 9110 tchar.
fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

const Frame = struct {
    /// An object that is a schema reached through `properties` keys alone
    /// (or the root schema itself).
    reachable: bool,
    /// An object that is the value of a reachable schema's `properties`.
    properties: bool,
    /// A reachable property schema, not the root.
    property: bool,
    is_array: bool,
    key: ?[]const u8 = null,
    header: ?[]const u8 = null,
    type: ?[]const u8 = null,
    depth: u8,
};

/// Finds every `x-mcp-header` annotation in a tool's `inputSchema` and checks
/// it. Returns how many it stored in `out`; any invalid annotation
/// makes the whole tool invalid.
pub fn annotations(schema: []const u8, out: *[max_annotations]Annotation) Invalid!usize {
    var stack_bytes: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack_bytes);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), schema);
    var frames: [64]Frame = undefined;
    var top: usize = 0;
    var path: [max_depth][]const u8 = undefined;
    var count: usize = 0;
    while (true) {
        const token = scanner.next() catch return error.Malformed;
        switch (token) {
            .object_begin, .array_begin => {
                if (top == frames.len) return error.Malformed;
                var frame: Frame = .{ .reachable = false, .properties = false, .property = false, .is_array = token == .array_begin, .depth = 0 };
                if (top == 0) {
                    frame.reachable = !frame.is_array;
                } else {
                    const parent = &frames[top - 1];
                    frame.depth = parent.depth;
                    if (!frame.is_array and !parent.is_array) {
                        const key = parent.key orelse "";
                        if (parent.properties) {
                            if (parent.depth == max_depth) return error.TooMany;
                            path[parent.depth] = key;
                            frame.depth = parent.depth + 1;
                            frame.reachable = true;
                            frame.property = true;
                        } else if (parent.reachable and std.mem.eql(u8, key, "properties")) {
                            frame.properties = true;
                        }
                    }
                    parent.key = null;
                }
                frames[top] = frame;
                top += 1;
            },
            .object_end, .array_end => {
                top -= 1;
                const frame = frames[top];
                if (frame.header) |name| {
                    if (!frame.property) return error.NotReachable;
                    const kind: Kind = if (std.mem.eql(u8, frame.type orelse "", "string"))
                        .string
                    else if (std.mem.eql(u8, frame.type orelse "", "integer"))
                        .integer
                    else if (std.mem.eql(u8, frame.type orelse "", "boolean"))
                        .boolean
                    else
                        return error.NotPrimitive;
                    for (out[0..count]) |other| if (std.ascii.eqlIgnoreCase(other.name, name)) return error.Duplicate;
                    if (count == max_annotations) return error.TooMany;
                    out[count] = .{ .name = name, .depth = frame.depth, .kind = kind };
                    @memcpy(out[count].path[0..frame.depth], path[0..frame.depth]);
                    count += 1;
                }
                if (top == 0) {
                    if ((scanner.next() catch return error.Malformed) != .end_of_document) return error.Malformed;
                    return count;
                }
            },
            .string, .number, .true, .false, .null, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4, .partial_number => {
                if (top == 0) return error.Malformed;
                const frame = &frames[top - 1];
                // A key written with escapes arrives in pieces; it matches nothing.
                const whole = token == .string or token == .number or token == .true or token == .false or token == .null;
                if (!frame.is_array and frame.key == null) {
                    frame.key = if (token == .string) token.string else "";
                    if (!whole) try skipRest(&scanner);
                    continue;
                }
                const key = frame.key orelse "";
                frame.key = null;
                if (std.mem.eql(u8, key, "x-mcp-header")) {
                    if (token != .string) return error.NotToken;
                    const name = token.string;
                    if (name.len == 0) return error.NotToken;
                    for (name) |c| if (!isTokenChar(c)) return error.NotToken;
                    frame.header = name;
                } else if (std.mem.eql(u8, key, "type") and token == .string) {
                    frame.type = token.string;
                }
                if (!whole) {
                    // An escaped x-mcp-header value is never a valid token.
                    if (std.mem.eql(u8, key, "x-mcp-header")) return error.NotToken;
                    try skipRest(&scanner);
                }
            },
            .end_of_document => return error.Malformed,
            else => return error.Malformed,
        }
    }
}

/// Skips the remaining pieces of a string or number the scanner splits.
fn skipRest(scanner: *std.json.Scanner) Invalid!void {
    while (true) switch (scanner.next() catch return error.Malformed) {
        .string, .number => return,
        .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4, .partial_number => {},
        else => return error.Malformed,
    };
}

/// The `Mcp-Param-*` headers for a tool call: each annotated
/// argument's value at its exact path, encoded. Absent and null
/// values are omitted, and so are objects and arrays, which no annotation
/// may name. Appends to `out`; values are allocated with `gpa`.
pub fn paramHeaders(
    gpa: std.mem.Allocator,
    found: []const Annotation,
    arguments: []const u8,
    out: *std.ArrayList(Header),
) (std.mem.Allocator.Error || wire.DecodeError)!void {
    for (found) |a| {
        var level = arguments;
        var value: ?[]const u8 = level;
        for (a.path[0..a.depth]) |key| {
            var field: [1]?[]const u8 = undefined;
            wire.objectFields(level, &.{key}, &field) catch {
                value = null;
                break;
            };
            value = field[0];
            level = value orelse break;
        }
        const raw = value orelse continue;
        const text: []const u8 = switch (raw[0]) {
            '"' => try decodeString(gpa, raw),
            't', 'f', '-', '0'...'9' => raw,
            else => continue,
        };
        try out.append(gpa, .{
            .name = try std.mem.concat(gpa, u8, &.{ "Mcp-Param-", a.name }),
            .value = try encodeValue(gpa, text),
        });
    }
}

/// The text of a raw JSON string, with escapes decoded.
fn decodeString(gpa: std.mem.Allocator, raw: []const u8) (std.mem.Allocator.Error || wire.DecodeError)![]const u8 {
    if (wire.plainString(raw)) |plain| return plain;
    var scanner: std.json.Scanner = .initCompleteInput(gpa, raw);
    defer scanner.deinit();
    const token = scanner.nextAlloc(gpa, .alloc_always) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
    return switch (token) {
        .allocated_string => |s| s,
        else => error.InvalidJson,
    };
}

const post_accept = "application/json, text/event-stream";

/// What a 2025 request carries: `Accept` with both types for a POST and only
/// SSE for a GET, the agreed `MCP-Protocol-Version` once
/// initialize was answered, the session id, and, to
/// resume a stream, `Last-Event-ID`. Appends to `out`.
pub fn sessionHeaders(
    gpa: std.mem.Allocator,
    get: bool,
    version: ?[]const u8,
    session: ?[]const u8,
    last_event_id: ?[]const u8,
    out: *std.ArrayList(Header),
) std.mem.Allocator.Error!void {
    try out.append(gpa, .{ .name = "Accept", .value = if (get) "text/event-stream" else post_accept });
    if (version) |v| try out.append(gpa, .{ .name = "MCP-Protocol-Version", .value = v });
    if (session) |id| try out.append(gpa, .{ .name = "Mcp-Session-Id", .value = id });
    if (last_event_id) |id| try out.append(gpa, .{ .name = "Last-Event-ID", .value = id });
}

/// A session id the client will echo: visible ASCII only, as the spec
/// requires of servers, and at most 1 KiB.
pub fn validSessionId(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024) return false;
    for (value) |c| if (c < 0x21 or c > 0x7e) return false;
    return true;
}

/// An event id the client can send back as `Last-Event-ID`: printable ASCII
/// and at most 1 KiB. A stream with any other id isn't resumable.
pub fn validEventId(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024) return false;
    for (value) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}

/// The headers every POST carries: `Accept`,
/// `MCP-Protocol-Version`, `Mcp-Method`, and, for a tool call, `Mcp-Name`.
/// Then the `extra` headers the host configured. Appends to `out`.
pub fn requestHeaders(
    gpa: std.mem.Allocator,
    version: []const u8,
    method: []const u8,
    name: ?[]const u8,
    extra: []const Header,
    out: *std.ArrayList(Header),
) std.mem.Allocator.Error!void {
    try out.appendSlice(gpa, &.{
        .{ .name = "Accept", .value = post_accept },
        .{ .name = "MCP-Protocol-Version", .value = version },
        .{ .name = "Mcp-Method", .value = method },
    });
    if (name) |n| try out.append(gpa, .{ .name = "Mcp-Name", .value = try encodeValue(gpa, n) });
    try out.appendSlice(gpa, extra);
}

const testing = std.testing;

test "2025 requests carry the session, the agreed version, and Last-Event-ID to resume" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var headers: std.ArrayList(Header) = .empty;
    try sessionHeaders(a, true, "2025-06-18", "abc", "ev-3", &headers);
    try testing.expectEqual(@as(usize, 4), headers.items.len);
    try testing.expectEqualStrings("text/event-stream", headers.items[0].value);
    try testing.expectEqualStrings("Mcp-Session-Id", headers.items[2].name);
    try testing.expectEqualStrings("ev-3", headers.items[3].value);
    headers.clearRetainingCapacity();
    try sessionHeaders(a, false, null, null, null, &headers);
    try testing.expectEqual(@as(usize, 1), headers.items.len);
    try testing.expectEqualStrings(post_accept, headers.items[0].value);
}

test "session and event ids are echoed only when they are safe header values" {
    try testing.expect(validSessionId("1868a90c-9f"));
    try testing.expect(!validSessionId(""));
    try testing.expect(!validSessionId("has space"));
    try testing.expect(!validSessionId("cr\rlf"));
    try testing.expect(!validSessionId("\xc3\xa9"));
    try testing.expect(validEventId("stream 1:7"));
    try testing.expect(!validEventId("tab\t"));
    try testing.expect(!validEventId("x" ** 1025));
}

test "encodes values that can't be sent as is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "us-west1", "us-west1" },
        .{ "us west 1", "us west 1" },
        .{ "", "" },
        .{ "Hello, \u{4e16}\u{754c}", "=?base64?SGVsbG8sIOS4lueVjA==?=" },
        .{ " padded ", "=?base64?IHBhZGRlZCA=?=" },
        .{ "line1\nline2", "=?base64?bGluZTEKbGluZTI=?=" },
        .{ "=?base64?literal?=", "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=" },
        .{ "\tindented", "=?base64?CWluZGVudGVk?=" },
    };
    for (cases) |case| try testing.expectEqualStrings(case[1], try encodeValue(a, case[0]));
}

fn checked(schema: []const u8) Invalid!usize {
    var out: [max_annotations]Annotation = undefined;
    return annotations(schema, &out);
}

test "accepts x-mcp-header only on primitive properties reached through properties" {
    var out: [max_annotations]Annotation = undefined;
    const n = try annotations(
        \\{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"},
        \\"opts":{"type":"object","properties":{"debug":{"x-mcp-header":"Debug","type":"boolean"}}},
        \\"query":{"type":"string"},"n":{"type":"integer","x-mcp-header":"N"}}}
    , &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("Region", out[0].name);
    try testing.expectEqual(Kind.boolean, out[1].kind);
    try testing.expectEqual(@as(u8, 2), out[1].depth);
    try testing.expectEqualStrings("opts", out[1].path[0]);
    try testing.expectEqualStrings("debug", out[1].path[1]);
    try testing.expectEqual(@as(usize, 0), try checked("{\"type\":\"object\"}"));
}

test "rejects every invalid x-mcp-header the conformance suite lists" {
    const cases = [_]struct { []const u8, Invalid }{
        .{ "{\"properties\":{\"v\":{\"type\":\"string\",\"x-mcp-header\":\"\"}}}", error.NotToken },
        .{ "{\"properties\":{\"d\":{\"type\":\"object\",\"x-mcp-header\":\"Data\"}}}", error.NotPrimitive },
        .{ "{\"properties\":{\"i\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"x-mcp-header\":\"Items\"}}}", error.NotPrimitive },
        .{ "{\"properties\":{\"n\":{\"type\":\"null\",\"x-mcp-header\":\"Nil\"}}}", error.NotPrimitive },
        .{ "{\"properties\":{\"f\":{\"type\":\"number\",\"x-mcp-header\":\"F\"}}}", error.NotPrimitive },
        .{ "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"Region\"},\"b\":{\"type\":\"string\",\"x-mcp-header\":\"Region\"}}}", error.Duplicate },
        .{ "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"MyField\"},\"b\":{\"type\":\"string\",\"x-mcp-header\":\"myfield\"}}}", error.Duplicate },
        .{ "{\"properties\":{\"v\":{\"type\":\"string\",\"x-mcp-header\":\"My Region\"}}}", error.NotToken },
        .{ "{\"properties\":{\"v\":{\"type\":\"string\",\"x-mcp-header\":\"Region:Primary\"}}}", error.NotToken },
        .{ "{\"properties\":{\"v\":{\"type\":\"string\",\"x-mcp-header\":\"R\u{e9}gion\"}}}", error.NotToken },
        .{ "{\"properties\":{\"v\":{\"type\":\"string\",\"x-mcp-header\":\"Region\\t1\"}}}", error.NotToken },
        .{ "{\"properties\":{\"v\":{\"type\":\"string\",\"x-mcp-header\":7}}}", error.NotToken },
        .{ "{\"properties\":{\"l\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"x-mcp-header\":\"L\"}}}}", error.NotReachable },
        .{ "{\"oneOf\":[{\"properties\":{\"v\":{\"type\":\"string\",\"x-mcp-header\":\"V\"}}}]}", error.NotReachable },
        .{ "{\"$defs\":{\"v\":{\"type\":\"string\",\"x-mcp-header\":\"V\"}}}", error.NotReachable },
        .{ "{\"type\":\"object\",\"x-mcp-header\":\"Root\"}", error.NotReachable },
        .{ "{\"properties\":{\"v\":{\"type\":\"string\",\"x-mcp-header\":\"V\"}}", error.Malformed },
    };
    for (cases) |case| try testing.expectError(case[1], checked(case[0]));
}

test "mirrors annotated arguments at their exact paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var found: [max_annotations]Annotation = undefined;
    const n = try annotations(
        \\{"properties":{"region":{"type":"string","x-mcp-header":"Region"},"priority":{"type":"integer","x-mcp-header":"Priority"},
        \\"verbose":{"type":"boolean","x-mcp-header":"Verbose"},"text":{"type":"string","x-mcp-header":"Text"},
        \\"gone":{"type":"string","x-mcp-header":"Gone"},"opts":{"properties":{"tier":{"type":"string","x-mcp-header":"Tier"}}}}}
    , &found);
    var headers: std.ArrayList(Header) = .empty;
    try paramHeaders(a, found[0..n], "{\"region\":\"us-west1\",\"priority\":42,\"verbose\":false,\"text\":\"line1\\nline2\",\"gone\":null,\"opts\":{\"tier\":\"gold\"}}", &headers);
    const want = [_]Header{
        .{ .name = "Mcp-Param-Region", .value = "us-west1" },
        .{ .name = "Mcp-Param-Priority", .value = "42" },
        .{ .name = "Mcp-Param-Verbose", .value = "false" },
        .{ .name = "Mcp-Param-Text", .value = "=?base64?bGluZTEKbGluZTI=?=" },
        .{ .name = "Mcp-Param-Tier", .value = "gold" },
    };
    try testing.expectEqual(want.len, headers.items.len);
    for (want, headers.items) |w, got| {
        try testing.expectEqualStrings(w.name, got.name);
        try testing.expectEqualStrings(w.value, got.value);
    }
}

test "writes the standard headers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var headers: std.ArrayList(Header) = .empty;
    try requestHeaders(a, "2026-07-28", "tools/call", "caf\u{e9}", &.{.{ .name = "Authorization", .value = "Bearer x" }}, &headers);
    const names = [_][]const u8{ "Accept", "MCP-Protocol-Version", "Mcp-Method", "Mcp-Name", "Authorization" };
    for (names, headers.items) |name, h| try testing.expectEqualStrings(name, h.name);
    try testing.expectEqualStrings("=?base64?Y2Fmw6k=?=", headers.items[3].value);
    headers.clearRetainingCapacity();
    try requestHeaders(a, "2026-07-28", "tools/list", null, &.{}, &headers);
    try testing.expectEqual(@as(usize, 3), headers.items.len);
}
