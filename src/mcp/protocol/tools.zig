//! Tool messages: reading `tools/list` pages into a caller-owned `Store`,
//! writing `tools/list` and `tools/call` requests, and reading a `tools/call`
//! answer. Readers return slices of the input, like `wire`; only `Store`
//! copies, into memory it owns. `core/catalog.zig` decides when to list,
//! restart, publish, or fail; this file holds the data.

const std = @import("std");
const http_headers = @import("http_headers.zig");
const wire = @import("wire.zig");
const mrtr = @import("mrtr.zig");

/// The longest a list may stay fresh (24 hours, like `rmcp`).
pub const max_ttl_ms: u32 = 24 * 60 * 60 * 1000;

pub const Page = struct {
    /// The raw `tools` array.
    tools: []const u8,
    /// The raw `nextCursor` string, quotes included, sent back as is. Cursors
    /// are opaque, and an empty string is a cursor.
    next_cursor: ?[]const u8,
    /// How long the page stays fresh: `ttlMs`, or 0 when it is absent,
    /// negative, or not an integer, at most `max_ttl_ms`.
    ttl_ms: u32,
};

/// Reads a complete `tools/list` result.
pub fn parsePage(result: []const u8) wire.DecodeError!Page {
    var found: [3]?[]const u8 = undefined;
    try wire.objectFields(result, &.{ "tools", "nextCursor", "ttlMs" }, &found);
    const cursor = found[1];
    if (cursor) |c| if (c[0] != '"' and !std.mem.eql(u8, c, "null")) return error.InvalidResult;
    const ttl = wire.decimal(found[2] orelse "0") orelse 0;
    return .{
        .tools = found[0] orelse return error.InvalidResult,
        .next_cursor = if (cursor) |c| (if (c[0] == '"') c else null) else null,
        .ttl_ms = @intCast(@min(ttl, max_ttl_ms)),
    };
}

pub const Tool = struct {
    name: []const u8,
    /// The tool's definition as the server sent it.
    raw: []const u8,
};

/// Tools in server order, copied into memory the list owns.
pub const List = struct {
    bytes: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    /// Finds a tool by name in constant time, so gathering a large list stays
    /// linear: open addressing over `spans`, each slot a tool's index
    /// + 1 (0 is empty), a power of two at least twice the tools.
    slots: std.ArrayList(u32) = .empty,

    const Span = struct { raw_start: u32, raw_len: u32, name_start: u32, name_len: u32 };

    pub fn deinit(list: *List, gpa: std.mem.Allocator) void {
        list.bytes.deinit(gpa);
        list.spans.deinit(gpa);
        list.slots.deinit(gpa);
    }

    pub fn clear(list: *List) void {
        list.bytes.clearRetainingCapacity();
        list.spans.clearRetainingCapacity();
        list.slots.clearRetainingCapacity();
    }

    pub fn len(list: *const List) usize {
        return list.spans.items.len;
    }

    /// A number that changes when the list's tools do, so a reader that worked something out of them knows when to
    /// do it again.
    pub fn fingerprint(list: *const List) u64 {
        return std.hash.Wyhash.hash(list.spans.items.len, list.bytes.items);
    }

    pub fn get(list: *const List, index: usize) Tool {
        const s = list.spans.items[index];
        return .{
            .name = list.bytes.items[s.name_start..][0..s.name_len],
            .raw = list.bytes.items[s.raw_start..][0..s.raw_len],
        };
    }

    pub fn find(list: *const List, name: []const u8) ?Tool {
        const slots = list.slots.items;
        if (slots.len == 0) return null;
        var at = slotFor(name, slots.len);
        while (slots[at] != 0) : (at = (at + 1) & (slots.len - 1)) {
            const tool = list.get(slots[at] - 1);
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }

    /// Makes room in `slots` for one more tool, before it is appended, so
    /// running out of memory never leaves a tool unindexed.
    fn reserve(list: *List, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        const n = list.len() + 1;
        if (n * 2 <= list.slots.items.len) return;
        const size = std.math.ceilPowerOfTwo(usize, @max(16, n * 2)) catch return error.OutOfMemory;
        try list.slots.resize(gpa, size);
        @memset(list.slots.items, 0);
        for (0..list.len()) |i| list.place(i);
    }

    /// Indexes tool `index`, which `reserve` made room for.
    fn place(list: *List, index: usize) void {
        const slots = list.slots.items;
        var at = slotFor(list.get(index).name, slots.len);
        while (slots[at] != 0) at = (at + 1) & (slots.len - 1);
        slots[at] = @intCast(index + 1);
    }

    fn slotFor(name: []const u8, slots: usize) usize {
        return @as(usize, @truncate(std.hash.Wyhash.hash(0, name))) & (slots - 1);
    }
};

pub const Added = struct {
    added: u32 = 0,
    /// Tools without a plain, non-empty `name`, or whose `inputSchema` isn't an object.
    invalid: u32 = 0,
    /// Tools with a field written twice, `name` included: no copy of it is trusted over the other.
    repeated_field: u32 = 0,
    /// Tools that are no JSON object, or that fx could not read for another reason.
    unreadable: u32 = 0,
    /// Tools named like one listed earlier (the first wins).
    duplicate: u32 = 0,
    /// Over HTTP, tools with an invalid `x-mcp-header`; the first
    /// one is named, for the warning the spec asks for.
    bad_headers: u32 = 0,
    /// Of `bad_headers`, the tools whose check gave up for size: a schema nested or branching past what it handles.
    /// They are over a limit, not wrong.
    header_limit: u32 = 0,
    first_bad: ?struct { name: []const u8, reason: http_headers.Invalid } = null,

    /// What this page left out, by reason.
    pub fn dropped(a: Added) Dropped {
        var d: Dropped = .{};
        d.add(.unnamed, a.invalid);
        d.add(.repeated_field, a.repeated_field);
        d.add(.over_limit, a.header_limit);
        d.add(.unusable, a.unreadable);
        d.add(.repeated_name, a.duplicate);
        d.add(.bad_header, a.bad_headers -| a.header_limit);
        return d;
    }
};

pub const AddError = wire.DecodeError || std.mem.Allocator.Error;

/// Why fx leaves one tool out of what a server listed. The set is closed and `words` gives each its fixed words, so
/// nothing the server wrote reaches a screen; the host shows them beside a server's status.
pub const Drop = enum {
    /// No plain, non-empty `name`, or an `inputSchema` that is not an object (`Store.addPage`).
    unnamed,
    /// A field of the tool written twice, `name` included (`Store.addPage`).
    repeated_field,
    /// A name already listed by an earlier tool: the first one wins (`Store.addPage`).
    repeated_name,
    /// An `x-mcp-header` annotation that is not valid (`Store.addPage`).
    bad_header,
    /// A schema or another field past fx's size or nesting limits.
    over_limit,
    /// A definition fx cannot use for another reason: a field of the wrong type, a schema dialect it doesn't read.
    unusable,

    pub fn words(why: Drop) []const u8 {
        return switch (why) {
            .unnamed => "a name or schema is missing",
            .repeated_field => "a field is written twice",
            .repeated_name => "a name is used by two tools",
            .bad_header => "an x-mcp-header is not valid",
            .over_limit => "a limit on size or nesting is passed",
            .unusable => "a definition can't be used",
        };
    }
};

/// How many tools of one list fx left out, by reason. A value with no words in it: it copies like a number.
pub const Dropped = struct {
    counts: [drop_reasons]u32 = @splat(0),

    const drop_reasons = std.enums.values(Drop).len;

    pub fn add(d: *Dropped, why: Drop, n: u32) void {
        d.counts[@backingInt(why)] +|= n;
    }

    pub fn merge(d: *Dropped, other: Dropped) void {
        for (&d.counts, other.counts) |*mine, theirs| mine.* +|= theirs;
    }

    pub fn total(d: Dropped) u32 {
        var sum: u32 = 0;
        for (d.counts) |n| sum +|= n;
        return sum;
    }

    /// The reason every left-out tool has; null when none was left out or the reasons differ.
    pub fn single(d: Dropped) ?Drop {
        var found: ?Drop = null;
        for (d.counts, 0..) |n, k| {
            if (n == 0) continue;
            if (found != null) return null;
            found = @fromBackingInt(@intCast(k));
        }
        return found;
    }
};

/// Why fx refused the server's answer to `tools/list`. The set is closed, and `words` gives each its fixed
/// words, so nothing the server wrote reaches a screen: the host shows them beside a server's status.
pub const Refusal = enum {
    /// A JSON-RPC error reply.
    error_reply,
    /// A result that is not `complete`, such as `input_required`.
    not_complete,
    /// A field of the result is written twice, plain or escaped.
    repeated_field,
    /// `tools` is no array.
    tools_not_a_list,
    /// Anything else that is no tool list.
    unreadable,
    /// An HTTP status that no other flow reads (not a sign-in, nor a session's end) and a body with no
    /// JSON-RPC message. `text` puts the status number in the words.
    http_status,
    /// The same, for a status that says the server can't answer now: `temporaryStatus`. The list is refused
    /// like any other, and the words say it is temporary.
    http_unavailable,
    /// A 2xx answer sent with a content type that is not JSON.
    not_json,

    pub fn words(refusal: Refusal) []const u8 {
        return switch (refusal) {
            .error_reply => "the server answered the list with an error",
            .not_complete => "the server's answer was not a finished list",
            .repeated_field => "a field is written twice",
            .tools_not_a_list => "\"tools\" is not a list",
            .unreadable => "the answer is not a readable tool list",
            .http_status, .http_unavailable => "the server answered the list with an HTTP error",
            .not_json => "the list is not valid JSON",
        };
    }

    /// The words of a refusal, with the status number for the HTTP ones (a number fx read, never server text).
    /// They fit `text_max` bytes.
    pub fn text(refusal: Refusal, status: u16, buf: *[text_max]u8) []const u8 {
        if (status == 0) return refusal.words();
        const temporary: []const u8 = switch (refusal) {
            .http_status => "",
            .http_unavailable => ", which is temporary",
            else => return refusal.words(),
        };
        return std.mem.print(buf, "the server answered the list with HTTP {d}{s}", .{ status, temporary }) catch refusal.words();
    }

    /// The refusal for an HTTP answer to `tools/list` that no other flow reads, by its status.
    pub fn ofStatus(status: u16) Refusal {
        return if (temporaryStatus(status)) .http_unavailable else .http_status;
    }
};

/// The HTTP statuses that say the server can't answer now but may later: 429 (too many requests) and 503
/// (unavailable). `fx mcp show` names each in the words it has for them (`verbs.zig`).
pub const temporary_statuses = [_]u16{ 429, 503 };

pub fn temporaryStatus(status: u16) bool {
    return std.mem.findScalar(u16, &temporary_statuses, status) != null;
}

/// The most bytes `Refusal.text` writes.
pub const text_max = 64;

/// The refusal for a page that `parsePage` or `Store.addPage` could not read.
pub fn refusalOf(err: wire.DecodeError) Refusal {
    return switch (err) {
        error.DuplicateField => .repeated_field,
        error.NotAnArray => .tools_not_a_list,
        else => .unreadable,
    };
}

/// The tool list of one server: the current list, the one being gathered by
/// a running listing, and the cursor for its next page. The effects of
/// `core/catalog.zig` say which method to call.
pub const Store = struct {
    current: List = .{},
    gathering: List = .{},
    cursor: std.ArrayList(u8) = .empty,
    has_cursor: bool = false,
    /// Streamable HTTP: drop tools whose `x-mcp-header` annotations are
    /// invalid. Other transports may ignore them.
    check_headers: bool = false,

    pub fn deinit(store: *Store, gpa: std.mem.Allocator) void {
        store.current.deinit(gpa);
        store.gathering.deinit(gpa);
        store.cursor.deinit(gpa);
    }

    /// Adds a page's tools to the list being gathered and keeps its cursor.
    /// Each malformed tool is skipped and counted, so one bad definition
    /// doesn't hide the others. On error, the caller fails the listing,
    /// which discards the partial list.
    pub fn addPage(store: *Store, gpa: std.mem.Allocator, page: Page) AddError!Added {
        var added: Added = .{};
        var elements: wire.Elements = undefined;
        try elements.init(page.tools);
        while (try elements.next()) |raw| {
            var found: [2]?[]const u8 = undefined;
            wire.objectFields(raw, &.{ "name", "inputSchema" }, &found) catch |err| {
                switch (err) {
                    error.DuplicateField => added.repeated_field += 1,
                    else => added.unreadable += 1,
                }
                continue;
            };
            const name = wire.plainString(found[0] orelse "") orelse "";
            const schema = found[1] orelse "";
            if (name.len == 0 or schema.len == 0 or schema[0] != '{') {
                added.invalid += 1;
                continue;
            }
            if (store.gathering.find(name) != null) {
                added.duplicate += 1;
                continue;
            }
            if (store.check_headers) {
                var annotations: [http_headers.max_annotations]http_headers.Annotation = undefined;
                if (http_headers.annotations(schema, &annotations)) |_| {} else |reason| {
                    added.bad_headers += 1;
                    if (reason == error.TooMany or reason == error.Malformed) added.header_limit += 1;
                    if (added.first_bad == null) added.first_bad = .{ .name = name, .reason = reason };
                    continue;
                }
            }
            const list = &store.gathering;
            const start = list.bytes.items.len;
            if (start + raw.len > std.math.maxInt(u32)) return error.OutOfMemory;
            try list.reserve(gpa);
            try list.spans.ensureUnusedCapacity(gpa, 1);
            try list.bytes.appendSlice(gpa, raw);
            const name_offset = @intFromPtr(name.ptr) - @intFromPtr(raw.ptr);
            list.spans.appendAssumeCapacity(.{
                .raw_start = @intCast(start),
                .raw_len = @intCast(raw.len),
                .name_start = @intCast(start + name_offset),
                .name_len = @intCast(name.len),
            });
            list.place(list.len() - 1);
            added.added += 1;
        }
        store.cursor.clearRetainingCapacity();
        store.has_cursor = page.next_cursor != null;
        if (page.next_cursor) |c| try store.cursor.appendSlice(gpa, c);
        return added;
    }

    /// The cursor for the next page, raw.
    pub fn nextCursor(store: *const Store) ?[]const u8 {
        return if (store.has_cursor) store.cursor.items else null;
    }

    /// Drops the pages gathered so far.
    pub fn discard(store: *Store) void {
        store.gathering.clear();
        store.has_cursor = false;
    }

    /// The gathered list becomes the current one.
    pub fn publish(store: *Store) void {
        std.mem.swap(List, &store.current, &store.gathering);
        store.discard();
    }
};

/// A `tools/list` request; `cursor` is a raw cursor from `Store.nextCursor`.
pub fn writeList(out: *std.Io.Writer, id: wire.RequestId, meta: wire.Meta, cursor: ?[]const u8) wire.EncodeError!void {
    var w: wire.Writer = try .request(out, id, "tools/list", meta);
    if (cursor) |c| {
        try w.field("cursor");
        try w.raw(c);
    }
    try w.end();
}

/// A `tools/call` request. `arguments` is a raw JSON object, `{}` when null.
/// A retry of an input_required round adds its answers and state.
pub fn writeCall(out: *std.Io.Writer, id: wire.RequestId, meta: wire.Meta, name: []const u8, arguments: ?[]const u8, retry: mrtr.Retry) wire.EncodeError!void {
    var w: wire.Writer = try .request(out, id, "tools/call", meta);
    try w.field("name");
    try w.string(name);
    try w.field("arguments");
    try w.raw(arguments orelse "{}");
    try mrtr.writeRetry(&w, retry);
    try w.end();
}

pub const Call = union(enum) {
    /// A tool result. One with `is_error` goes to the model too.
    /// `structured` is passed on unvalidated.
    result: struct { content: []const u8, structured: ?[]const u8, is_error: bool },
    /// More input is needed: the raw result. Never cached.
    input_required: []const u8,
    /// A protocol error.
    failure: wire.Failure,
    /// A result that isn't a tool result.
    invalid,
};

/// Reads the answer to a `tools/call` request.
pub fn classifyCall(body: @FieldType(wire.Response, "body")) Call {
    switch (body) {
        .failure => |failure| return .{ .failure = failure },
        .result => |result| {
            switch (result.kind) {
                .input_required => return .{ .input_required = result.raw },
                .unrecognized => return .invalid,
                .complete => {},
            }
            var found: [3]?[]const u8 = undefined;
            wire.objectFields(result.raw, &.{ "content", "structuredContent", "isError" }, &found) catch return .invalid;
            const content = found[0] orelse return .invalid;
            const is_error = found[2] orelse "false";
            if (content[0] != '[') return .invalid;
            if (!std.mem.eql(u8, is_error, "true") and !std.mem.eql(u8, is_error, "false")) return .invalid;
            return .{ .result = .{ .content = content, .structured = found[1], .is_error = is_error[0] == 't' } };
        },
    }
}

/// An answer saying the tool or its arguments are unknown suggests the list
/// changed, so the list goes stale.
pub fn suggestsChangedList(call: Call) bool {
    return call == .failure and (call.failure.code == wire.code.method_not_found or call.failure.code == wire.code.invalid_params);
}

const testing = std.testing;

fn refusalOfPage(store: *Store, result: []const u8) !?Refusal {
    const page = parsePage(result) catch |err| return refusalOf(err);
    _ = store.addPage(testing.allocator, page) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => |decode| return refusalOf(decode),
    };
    return null;
}

test "a page fx refuses has one of the fixed reasons, whatever the server wrote" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    // `tools` that is no list, a field written twice (plain and escaped), a list with a missing `tools`, and text that is no JSON.
    const cases = [_]struct { []const u8, Refusal }{
        .{ "{\"tools\":7}", .tools_not_a_list },
        .{ "{\"tools\":[],\"tools\":[]}", .repeated_field },
        .{ "{\"tools\":[],\"t\\u006fols\":[]}", .repeated_field },
        .{ "{\"nextCursor\":null}", .unreadable },
        .{ "not json", .unreadable },
        .{ "[]", .unreadable },
    };
    for (cases) |case| {
        const refusal = try refusalOfPage(&store, case[0]);
        try testing.expectEqual(case[1], refusal.?);
    }
    // Every reason has words, and none carries a byte a screen could misread.
    for (std.enums.values(Refusal)) |refusal| {
        const words = refusal.words();
        try testing.expect(words.len > 0 and words.len < 64);
        for (words) |byte| try testing.expect(byte >= ' ' and byte < 0x7f);
    }
    // A decode error with no words of its own gets the general ones: a list nested too deeply never gets this far,
    // because the line that carries it fails to decode first.
    try testing.expectEqual(Refusal.unreadable, refusalOf(error.TooDeep));
}

test "an HTTP status goes into the words as a number, and nothing else does" {
    var buf: [text_max]u8 = undefined;
    try testing.expectEqualStrings("the server answered the list with HTTP 500", Refusal.http_status.text(500, &buf));
    try testing.expectEqualStrings("the server answered the list with HTTP 65535", Refusal.http_status.text(65535, &buf));
    // No status, no number; every other reason keeps its fixed words whatever the status.
    try testing.expectEqualStrings(Refusal.http_status.words(), Refusal.http_status.text(0, &buf));
    for (std.enums.values(Refusal)) |refusal| {
        if (refusal == .http_status or refusal == .http_unavailable) continue;
        try testing.expectEqualStrings(refusal.words(), refusal.text(500, &buf));
    }
    // The longest words fit the buffer, and are plain ASCII.
    const longest = Refusal.http_status.text(65535, &buf);
    try testing.expect(longest.len <= text_max);
    for (longest) |byte| try testing.expect(byte >= ' ' and byte < 0x7f);
}

test "429 and 503 are refused as temporary, with their number and no other words from the server" {
    var buf: [text_max]u8 = undefined;
    try testing.expectEqual(Refusal.http_unavailable, Refusal.ofStatus(429));
    try testing.expectEqual(Refusal.http_unavailable, Refusal.ofStatus(503));
    for ([_]u16{ 400, 401, 403, 404, 500, 502, 504, 301 }) |status| try testing.expectEqual(Refusal.http_status, Refusal.ofStatus(status));
    try testing.expectEqualStrings("the server answered the list with HTTP 503, which is temporary", Refusal.http_unavailable.text(503, &buf));
    try testing.expectEqualStrings(Refusal.http_unavailable.words(), Refusal.http_unavailable.text(0, &buf));
    const longest = Refusal.http_unavailable.text(65535, &buf);
    try testing.expect(longest.len <= text_max);
    for (longest) |byte| try testing.expect(byte >= ' ' and byte < 0x7f);
}

test "reads a page: tools, an opaque cursor, and the TTL" {
    const page = try parsePage("{\"tools\":[],\"nextCursor\":\"\",\"ttlMs\":300000}");
    try testing.expectEqualStrings("\"\"", page.next_cursor.?);
    try testing.expectEqual(@as(u32, 300000), page.ttl_ms);
    for ([_][]const u8{ "-5", "1.5", "3e5", "\"60\"", "99999999999999999999999" }) |ttl| {
        var buffer: [96]u8 = undefined;
        const result = try std.mem.print(&buffer, "{{\"tools\":[],\"ttlMs\":{s}}}", .{ttl});
        try testing.expectEqual(@as(u32, 0), (try parsePage(result)).ttl_ms);
    }
    try testing.expectEqual(max_ttl_ms, (try parsePage("{\"tools\":[],\"ttlMs\":999999999999}")).ttl_ms);
    try testing.expectEqual(@as(?[]const u8, null), (try parsePage("{\"tools\":[],\"nextCursor\":null}")).next_cursor);
    try testing.expectError(error.InvalidResult, parsePage("{\"nextCursor\":\"a\"}"));
    try testing.expectError(error.InvalidResult, parsePage("{\"tools\":[],\"nextCursor\":7}"));
}

test "a tool result's isError written with an escape is still the server's isError" {
    const failed = classifyCall((try wire.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[],\"i\\u0073Error\":true}}")).response.body);
    try testing.expect(failed.result.is_error);
    const fine = classifyCall((try wire.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[],\"i\\u0073Error\":false}}")).response.body);
    try testing.expect(!fine.result.is_error);
    // A result with no isError is not an error.
    const absent = classifyCall((try wire.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[]}}")).response.body);
    try testing.expect(!absent.result.is_error);
    // The same result with the key written plainly.
    const plain = classifyCall((try wire.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[],\"isError\":true}}")).response.body);
    try testing.expect(plain.result.is_error);
}

test "a page's nextCursor and ttlMs written with escapes are read" {
    const page = try parsePage("{\"tools\":[],\"ne\\u0078tCursor\":\"c2\",\"tt\\u006cMs\":300000}");
    try testing.expectEqualStrings("\"c2\"", page.next_cursor orelse "(no cursor)");
    try testing.expectEqual(@as(u32, 300000), page.ttl_ms);
    // A page whose `tools` name is written with an escape is a page.
    try testing.expectEqualStrings("[]", (try parsePage("{\"too\\u006cs\":[]}")).tools);
}

test "gathers valid tools, skipping malformed ones and later duplicates" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const first = try store.addPage(testing.allocator, try parsePage(
        \\{"tools":[{"name":"a","inputSchema":{"type":"object"}},{"name":"","inputSchema":{}},
        \\{"name":"b"},{"name":"c","inputSchema":null},7,{"name":"\u0064","inputSchema":{}},
        \\{"name":"a","inputSchema":{}},{"name":"d","name":"e","inputSchema":{}}],"nextCursor":"p2"}
    ));
    try testing.expectEqual(Added{ .added = 1, .invalid = 4, .unreadable = 1, .repeated_field = 1, .duplicate = 1 }, first);
    try testing.expectEqualStrings("\"p2\"", store.nextCursor().?);
    const second = try store.addPage(testing.allocator, try parsePage("{\"tools\":[{\"description\":\"x\",\"name\":\"b\",\"inputSchema\":{}},{\"name\":\"a\",\"inputSchema\":{}}]}"));
    try testing.expectEqual(Added{ .added = 1, .duplicate = 1 }, second);
    try testing.expectEqual(@as(?[]const u8, null), store.nextCursor());
    try testing.expectEqual(@as(usize, 0), store.current.len());
    store.publish();
    try testing.expectEqual(@as(usize, 2), store.current.len());
    try testing.expectEqual(@as(usize, 0), store.gathering.len());
    try testing.expectEqualStrings("b", store.current.get(1).name);
    try testing.expectEqualStrings("{\"description\":\"x\",\"name\":\"b\",\"inputSchema\":{}}", store.current.find("b").?.raw);
    try testing.expectEqual(@as(?Tool, null), store.current.find("c"));
    // A restart drops what was gathered; the current list stays.
    _ = try store.addPage(testing.allocator, try parsePage("{\"tools\":[{\"name\":\"z\",\"inputSchema\":{}}],\"nextCursor\":\"q\"}"));
    store.discard();
    try testing.expectEqual(@as(usize, 0), store.gathering.len());
    try testing.expectEqual(@as(?[]const u8, null), store.nextCursor());
    try testing.expectEqual(@as(usize, 2), store.current.len());
    try testing.expectError(error.NotAnArray, store.addPage(testing.allocator, .{ .tools = "{}", .next_cursor = null, .ttl_ms = 0 }));
}

test "a large list over pages: each tool is found as first listed, and a later one of the same name is skipped" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);
    var page: std.Io.Writer.Allocating = .init(gpa);
    defer page.deinit();
    // Three pages of 3,000; the second repeats every even name of the first,
    // and the index grows and is rebuilt several times.
    for (0..2) |round| {
        for (0..3) |p| {
            page.clearRetainingCapacity();
            try page.writer.writeAll("{\"tools\":[");
            for (0..3000) |i| {
                const n = if (p == 1 and i % 2 == 0) i else p * 3000 + i;
                if (i > 0) try page.writer.writeByte(',');
                try page.writer.print("{{\"name\":\"t{d}\",\"inputSchema\":{{}},\"page\":{d}}}", .{ n, p });
            }
            try page.writer.writeAll("]}");
            const added = try store.addPage(gpa, try parsePage(page.written()));
            try testing.expectEqual(Added{ .added = if (p == 1) 1500 else 3000, .duplicate = if (p == 1) 1500 else 0 }, added);
        }
        // The second round gathers again into the memory the first left.
        if (round == 0) store.discard() else store.publish();
    }
    try testing.expectEqual(@as(usize, 7500), store.current.len());
    var name: [16]u8 = undefined;
    for (0..9000) |n| {
        const tool = store.current.find(try std.mem.print(&name, "t{d}", .{n}));
        if (n >= 3000 and n < 6000 and n % 2 == 0) {
            try testing.expectEqual(@as(?Tool, null), tool);
            continue;
        }
        const first: u8 = if (n < 3000) '0' else if (n < 6000) '1' else '2';
        try testing.expectEqualStrings(&.{ '"', 'p', 'a', 'g', 'e', '"', ':', first, '}' }, tool.?.raw[tool.?.raw.len - 9 ..]);
    }
    try testing.expectEqual(@as(?Tool, null), store.current.find("t9000"));
    try testing.expectEqual(@as(?Tool, null), store.gathering.find("t0"));
}

test "over HTTP, tools with an invalid x-mcp-header are dropped; the others stay" {
    var store: Store = .{ .check_headers = true };
    defer store.deinit(testing.allocator);
    const page = try parsePage(
        \\{"tools":[{"name":"valid_tool","inputSchema":{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"}}}},
        \\{"name":"invalid_space","inputSchema":{"properties":{"v":{"type":"string","x-mcp-header":"My Region"}}}},
        \\{"name":"invalid_object","inputSchema":{"properties":{"d":{"type":"object","x-mcp-header":"Data"}}}}]}
    );
    const added = try store.addPage(testing.allocator, page);
    try testing.expectEqual(@as(u32, 1), added.added);
    try testing.expectEqual(@as(u32, 2), added.bad_headers);
    try testing.expectEqualStrings("invalid_space", added.first_bad.?.name);
    try testing.expectEqual(error.NotToken, added.first_bad.?.reason);
    // Over stdio the same page keeps every tool.
    var stdio: Store = .{};
    defer stdio.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), (try stdio.addPage(testing.allocator, page)).added);
}

test "a page whose memory runs out leaves the store usable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var store: Store = .{};
    defer store.deinit(failing.allocator());
    try testing.expectError(error.OutOfMemory, store.addPage(failing.allocator(), try parsePage("{\"tools\":[{\"name\":\"a\",\"inputSchema\":{}},{\"name\":\"b\",\"inputSchema\":{}}]}")));
    store.discard();
    try testing.expectEqual(@as(usize, 0), store.gathering.len());
}

test "writes tools/list and tools/call, cursor sent back unchanged" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeList(&out.writer, 4, .{}, "\"a\\\"b\"");
    try out.writer.writeByte('\n');
    try writeCall(&out.writer, 5, .{}, "get_weather", "{\"location\":\"New York\"}", .{});
    try out.writer.writeByte('\n');
    try writeCall(&out.writer, 6, .{}, "noargs", null, .{});
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{\"cursor\":\"a\\\"b\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"get_weather\",\"arguments\":{\"location\":\"New York\"}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"noargs\",\"arguments\":{}}}",
        out.written(),
    );
}

test "reads tool call answers" {
    const Case = struct { []const u8, std.meta.Tag(Call), bool };
    const cases = [_]Case{
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}", .result, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{}}}", .input_required, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"task\"}}", .invalid, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"structuredContent\":{}}}", .invalid, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[],\"isError\":\"yes\"}}", .invalid, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Unknown tool: x\"}}", .failure, true },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", .failure, true },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}", .failure, false },
    };
    for (cases) |case| {
        const call = classifyCall((try wire.decode(case[0])).response.body);
        try testing.expectEqual(case[1], std.meta.activeTag(call));
        try testing.expectEqual(case[2], suggestsChangedList(call));
    }
    const failed = classifyCall((try wire.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[],\"structuredContent\":[1,2],\"isError\":true}}")).response.body);
    try testing.expect(failed.result.is_error);
    try testing.expectEqualStrings("[1,2]", failed.result.structured.?);
}

test "what a list leaves out is counted by reason, and every reason has words fx wrote" {
    var d: Dropped = .{};
    try testing.expectEqual(@as(u32, 0), d.total());
    try testing.expectEqual(@as(?Drop, null), d.single());
    d.add(.repeated_name, 2);
    try testing.expectEqual(@as(?Drop, .repeated_name), d.single());
    var more: Dropped = .{};
    more.add(.unnamed, 1);
    d.merge(more);
    try testing.expectEqual(@as(u32, 3), d.total());
    try testing.expectEqual(@as(?Drop, null), d.single());

    // A page's skips map to their reasons, one each.
    const page = (Added{ .invalid = 1, .repeated_field = 8, .duplicate = 2, .bad_headers = 5, .header_limit = 1, .unreadable = 32 }).dropped();
    try testing.expectEqual(@as(u32, 1), page.counts[@backingInt(Drop.unnamed)]);
    try testing.expectEqual(@as(u32, 8), page.counts[@backingInt(Drop.repeated_field)]);
    try testing.expectEqual(@as(u32, 2), page.counts[@backingInt(Drop.repeated_name)]);
    // Of five tools the header check refused, one gave up for size: it is over a limit, and no tool counts twice.
    try testing.expectEqual(@as(u32, 4), page.counts[@backingInt(Drop.bad_header)]);
    try testing.expectEqual(@as(u32, 1), page.counts[@backingInt(Drop.over_limit)]);
    try testing.expectEqual(@as(u32, 32), page.counts[@backingInt(Drop.unusable)]);
    try testing.expectEqual(@as(u32, 48), page.total());

    try testing.expectEqualStrings("a field is written twice", Drop.repeated_field.words());
    try testing.expectEqualStrings("a name is used by two tools", Drop.repeated_name.words());
    for (std.enums.values(Drop)) |why| try testing.expect(why.words().len > 0);
}

test "a tool nested past what the header check handles is over a limit, not wrong" {
    const gpa = testing.allocator;
    // Over HTTP and in the 2026 era the header check reads each schema, and gives up on one nested past its frames.
    var schema: std.ArrayList(u8) = .empty;
    defer schema.deinit(gpa);
    try schema.appendSlice(gpa, "{\"tools\":[{\"name\":\"headers\",\"inputSchema\":");
    for (0..70) |_| try schema.appendSlice(gpa, "{\"properties\":{\"a\":");
    try schema.appendSlice(gpa, "{\"type\":\"string\"}");
    for (0..70) |_| try schema.appendSlice(gpa, "}}");
    try schema.appendSlice(gpa, "}]}");
    var store: Store = .{ .check_headers = true };
    defer store.deinit(gpa);
    const added = try store.addPage(gpa, try parsePage(schema.items));
    try testing.expectEqual(@as(u32, 1), added.bad_headers);
    try testing.expectEqual(@as(u32, 1), added.header_limit);
    try testing.expectEqual(@as(u32, 1), added.dropped().counts[@backingInt(Drop.over_limit)]);
    try testing.expectEqual(@as(u32, 0), added.dropped().counts[@backingInt(Drop.bad_header)]);
}
