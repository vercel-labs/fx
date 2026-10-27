//! Bounded HTTP for the web search transports, plus the small text helpers
//! they share: URL encoding, HTML entity decoding, and JSON field access.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const gateway_client = @import("../client.zig");
const bank = @import("../../core/tooling/web_search_bank.zig");

const Allocator = std.mem.Allocator;

pub const max_response_bytes: usize = 4 * 1024 * 1024;

pub const Method = enum { get, post };

/// One request. Every slice is borrowed for the call.
pub const Request = struct {
    method: Method = .get,
    url: []const u8,
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
};

/// A response the caller owns.
pub const Response = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Response, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

/// Sends `request` within the query's timeout and cancellation.
pub fn send(alloc: Allocator, request: Request, query: bank.Query) !Response {
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(@max(query.timeout_ms, 1000)),
    });
    var operation = Operation{ .alloc = alloc, .request = request };
    return gateway_client.runBoundedHttpOperation(Response, alloc, query.cancel_flag, deadline, &operation) catch |err| switch (err) {
        // A single-threaded Io cannot watch the deadline beside the request;
        // run it directly and rely on the connection's own timeouts.
        error.ConcurrencyUnavailable => {
            var direct = Operation{ .alloc = alloc, .request = request };
            return direct.run();
        },
        else => return err,
    };
}

/// Sends `request` and returns the body of a 2xx response, mapping other
/// statuses to the errors the bank describes. The caller owns the body.
pub fn sendOk(alloc: Allocator, request: Request, query: bank.Query) ![]u8 {
    var response = try send(alloc, request, query);
    errdefer response.deinit(alloc);
    try checkStatus(response.status);
    return response.body;
}

pub fn checkStatus(status: std.http.Status) !void {
    const code = @backingInt(status);
    if (code >= 200 and code < 300) return;
    return switch (code) {
        401, 403 => error.SearchUnauthorized,
        404 => error.SearchNotFound,
        429 => error.SearchRateLimited,
        500...599 => error.SearchServerError,
        else => error.SearchHttpError,
    };
}

const Operation = struct {
    alloc: Allocator,
    request: Request,

    pub fn run(self: *@This()) !Response {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const buffer = try self.alloc.alloc(u8, max_response_bytes + 1);
        defer self.alloc.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.request.url },
            .method = switch (self.request.method) {
                .get => .GET,
                .post => .POST,
            },
            .payload = self.request.body,
            .headers = .{
                .content_type = if (self.request.content_type) |value| .{ .override = value } else .default,
                .user_agent = .{ .override = self.request.user_agent orelse gateway_client.user_agent },
                .accept_encoding = .omit,
                .authorization = if (self.request.authorization) |value| .{ .override = value } else .default,
            },
            .extra_headers = self.request.headers,
            .redirect_behavior = if (self.request.method == .get) .init(3) else .unhandled,
            .response_writer = &writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.SearchResponseTooLarge,
            else => return err,
        };
        const body = writer.buffered();
        if (body.len > max_response_bytes) return error.SearchResponseTooLarge;
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, body) };
    }
};

/// Percent-encodes `text` for a query component (spaces as %20).
pub fn writeQueryComponent(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try writer.writeByte(c);
        } else {
            try writer.print("%{X:0>2}", .{c});
        }
    }
}

/// Decodes a percent-encoded component, `+` as space. The caller owns the result.
pub fn percentDecode(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '%' and i + 2 < text.len) {
            const value = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch {
                try out.append(alloc, c);
                continue;
            };
            try out.append(alloc, value);
            i += 2;
        } else if (c == '+') {
            try out.append(alloc, ' ');
        } else {
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Strips tags, decodes common entities, and collapses whitespace. The
/// caller owns the result.
pub fn htmlText(alloc: Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    var pending_space = false;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const end = std.mem.findScalarPos(u8, html, i, '>') orelse html.len;
            if (isBlockTag(html[i + 1 .. end])) pending_space = true;
            i = @min(end + 1, html.len);
            continue;
        }
        var decoded_buf: [4]u8 = undefined;
        var piece: []const u8 = html[i .. i + 1];
        var advance: usize = 1;
        if (c == '&') {
            if (decodeEntity(html[i..], &decoded_buf)) |entity| {
                piece = entity.text;
                advance = entity.consumed;
            }
        }
        i += advance;
        if (piece.len == 1 and std.ascii.isWhitespace(piece[0])) {
            pending_space = true;
            continue;
        }
        if (pending_space and out.items.len > 0) try out.append(alloc, ' ');
        pending_space = false;
        try out.appendSlice(alloc, piece);
    }
    return out.toOwnedSlice(alloc);
}

fn isBlockTag(tag: []const u8) bool {
    const name_start: usize = if (tag.len > 0 and tag[0] == '/') 1 else 0;
    var name_end = name_start;
    while (name_end < tag.len and std.ascii.isAlphanumeric(tag[name_end])) name_end += 1;
    const name = tag[name_start..name_end];
    const blocks = [_][]const u8{ "br", "p", "div", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "ul", "ol", "table" };
    for (blocks) |block| if (std.ascii.eqlIgnoreCase(name, block)) return true;
    return false;
}

const Entity = struct { text: []const u8, consumed: usize };

fn decodeEntity(text: []const u8, buf: *[4]u8) ?Entity {
    const end = std.mem.findScalar(u8, text[0..@min(text.len, 12)], ';') orelse return null;
    const name = text[1..end];
    const named = [_]struct { []const u8, []const u8 }{
        .{ "amp", "&" },   .{ "lt", "<" },   .{ "gt", ">" },
        .{ "quot", "\"" }, .{ "apos", "'" }, .{ "nbsp", " " },
        .{ "#39", "'" },   .{ "#x27", "'" },
    };
    for (named) |entry| if (std.ascii.eqlIgnoreCase(name, entry[0])) return .{ .text = entry[1], .consumed = end + 1 };
    if (name.len < 2 or name[0] != '#') return null;
    const code = if (name[1] == 'x' or name[1] == 'X')
        std.fmt.parseInt(u21, name[2..], 16) catch return null
    else
        std.fmt.parseInt(u21, name[1..], 10) catch return null;
    const len = std.unicode.utf8Encode(code, buf) catch return null;
    return .{ .text = buf[0..len], .consumed = end + 1 };
}

/// A string field, or "" when absent or not a string.
pub fn str(value: ?std.json.Value, field: []const u8) []const u8 {
    const object = obj(value) orelse return "";
    const found = object.get(field) orelse return "";
    return if (found == .string) found.string else "";
}

pub fn obj(value: ?std.json.Value) ?std.json.ObjectMap {
    const v = value orelse return null;
    return if (v == .object) v.object else null;
}

pub fn arr(value: ?std.json.Value, field: []const u8) []const std.json.Value {
    const object = obj(value) orelse return &.{};
    const found = object.get(field) orelse return &.{};
    return if (found == .array) found.array.items else &.{};
}

pub fn get(value: ?std.json.Value, field: []const u8) ?std.json.Value {
    const object = obj(value) orelse return null;
    return object.get(field);
}

/// First nonempty string among `fields` of `value`.
pub fn firstStr(value: ?std.json.Value, fields: []const []const u8) []const u8 {
    for (fields) |field| {
        const text = std.mem.trim(u8, str(value, field), " \t\r\n");
        if (text.len > 0) return text;
    }
    return "";
}

/// Writes `text` as a JSON string literal.
pub fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

test "html text strips tags and decodes entities" {
    const text = try htmlText(std.testing.allocator, "<b>Zig</b> &amp; <i>C</i>&#39;s &#x2192; fast&nbsp;now");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Zig & C's \u{2192} fast now", text);
}

test "percent decoding and query encoding round trip" {
    const decoded = try percentDecode(std.testing.allocator, "https%3A%2F%2Fziglang.org%2Fa%20b+c");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("https://ziglang.org/a b c", decoded);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeQueryComponent(&out.writer, "zig 0.17 & c++");
    try std.testing.expectEqualStrings("zig%200.17%20%26%20c%2B%2B", out.written());
}

test "status mapping drives chain fallback reasons" {
    try std.testing.expectError(error.SearchRateLimited, checkStatus(.too_many_requests));
    try std.testing.expectError(error.SearchUnauthorized, checkStatus(.forbidden));
    try std.testing.expectError(error.SearchServerError, checkStatus(.bad_gateway));
    try checkStatus(.ok);
}

/// "YYYY-MM-DD" for the start of the `recency` window, written into `buf`.
pub fn recencyStartDate(buf: *[10]u8, recency: bank.Recency) []const u8 {
    const days_back: u64 = switch (recency) {
        .day => 1,
        .week => 7,
        .month => 31,
        .year => 365,
    };
    const now_s: u64 = @intCast(@max(@divFloor(io_mod.milliTimestamp(), 1000), 0));
    return isoDate(buf, now_s -| days_back * std.time.s_per_day);
}

pub fn isoDate(buf: *[10]u8, epoch_seconds: u64) []const u8 {
    const day = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const year_day = day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.mem.print(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1,
    }) catch unreachable;
}

/// Parses a JSON body; the caller deinits the result.
pub fn parseJson(alloc: Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.InvalidSearchResponse;
}

test "iso date formats epoch days" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-28", isoDate(&buf, 1_793_145_600));
}
