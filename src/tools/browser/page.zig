//! Page-level CDP work for one tab: evaluating in the page, resolving
//! selectors and observed ids to elements, and trusted mouse and keyboard
//! input (D195).
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const cdp = @import("../../core/browser/cdp.zig");
const browser_mod = @import("../../core/browser/browser.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Browser = browser_mod.Browser;
const Tab = browser_mod.Tab;

pub const helper_source = @embedFile("page_helper.js");
pub const aria_source = @embedFile("aria_snapshot.js");
/// Objects fx holds in the page during a run, released together at its end.
pub const object_group = "proto-fx";

/// A failure the script sees, with its message in `Failure.message`.
pub const Failure = error{OpFailed};

pub const Page = struct {
    alloc: Allocator,
    browser: *Browser,
    tab: *Tab,
    /// The message of the last failure, owned by `alloc`.
    message: ?[]u8 = null,

    pub fn fail(self: *Page, comptime fmt: []const u8, args: anytype) Failure {
        self.message = self.alloc.print(fmt, args) catch null;
        return error.OpFailed;
    }

    /// Fails with the browser's last protocol error.
    pub fn protocolFailure(self: *Page, err: anyerror, what: []const u8) Failure {
        return switch (err) {
            error.CdpError => self.fail("{s}: {s}", .{ what, self.browser.conn.lastError() }),
            error.Timeout => self.fail("{s}: the browser did not answer in time", .{what}),
            error.Cancelled => self.fail("cancelled", .{}),
            error.ConnectionClosed => self.fail("{s}: the browser connection closed", .{what}),
            else => self.fail("{s}: {s}", .{ what, @errorName(err) }),
        };
    }

    fn sid(self: *const Page) []const u8 {
        return self.tab.session_id;
    }

    /// Runs `expression` in the page. With `by_value`, the result's `value`;
    /// otherwise its remote object. Exceptions become failures.
    pub fn evaluate(self: *Page, expression: []const u8, by_value: bool, await_promise: bool) Failure!cdp.Result {
        var result = self.browser.call(self.sid(), "Runtime.evaluate", .{
            .expression = expression,
            .returnByValue = by_value,
            .awaitPromise = await_promise,
            .objectGroup = object_group,
            .userGesture = true,
        }) catch |err| return self.protocolFailure(err, "evaluate");
        if (exceptionText(result.value())) |text| {
            defer result.deinit(self.browser.alloc);
            return self.fail("{s}", .{text});
        }
        return result;
    }

    /// Evaluates and returns the JSON text of the value, owned by `alloc`.
    pub fn evaluateJson(self: *Page, expression: []const u8, await_promise: bool) Failure![]u8 {
        var result = try self.evaluate(expression, true, await_promise);
        defer result.deinit(self.browser.alloc);
        return self.valueJson(result.value());
    }

    pub fn valueJson(self: *Page, result: Value) Failure![]u8 {
        const remote = if (result == .object) result.object.get("result") else null;
        const value = if (remote) |r| if (r == .object) r.object.get("value") else null else null;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        std.json.Stringify.value(value orelse Value.null, .{}, &out.writer) catch return self.fail("out of memory", .{});
        return out.toOwnedSlice() catch self.fail("out of memory", .{});
    }

    /// Calls `function` with `this` bound to `object_id`. `args_json` is a
    /// JSON array of CDP call arguments, or empty.
    pub fn callOn(self: *Page, object_id: []const u8, function: []const u8, args_json: []const u8, by_value: bool) Failure!cdp.Result {
        const id_json = cdp.jsonString(self.alloc, object_id) catch return self.fail("out of memory", .{});
        defer self.alloc.free(id_json);
        const fn_json = cdp.jsonString(self.alloc, function) catch return self.fail("out of memory", .{});
        defer self.alloc.free(fn_json);
        const params = self.alloc.print(
            "{{\"objectId\":{s},\"functionDeclaration\":{s},\"arguments\":{s},\"returnByValue\":{},\"awaitPromise\":true,\"userGesture\":true}}",
            .{ id_json, fn_json, if (args_json.len > 0) args_json else "[]", by_value },
        ) catch return self.fail("out of memory", .{});
        defer self.alloc.free(params);
        var result = self.browser.conn.call(self.sid(), "Runtime.callFunctionOn", params, browser_mod.command_timeout_ms) catch |err|
            return self.protocolFailure(err, "element call");
        if (exceptionText(result.value())) |text| {
            defer result.deinit(self.browser.alloc);
            return self.fail("{s}", .{text});
        }
        return result;
    }

    pub fn callOnJson(self: *Page, object_id: []const u8, function: []const u8, args_json: []const u8) Failure![]u8 {
        var result = try self.callOn(object_id, function, args_json, true);
        defer result.deinit(self.browser.alloc);
        return self.valueJson(result.value());
    }

    /// The object id of the element a target names, waiting up to `wait_ms`
    /// for a selector to match. Owned by `alloc`.
    pub fn resolveTarget(self: *Page, target: Value, wait_ms: i64) Failure![]u8 {
        if (target != .object) return self.fail("missing element target", .{});
        if (target.object.get("id")) |id_value| {
            const id = switch (id_value) {
                .integer => |n| n,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => return self.fail("element id must be a number", .{}),
            };
            if (id < 1 or id > self.tab.elements.items.len)
                return self.fail("element id {d} is unknown or stale; call tab.observe() after the last navigation", .{id});
            const backend_id = self.tab.elements.items[@intCast(id - 1)];
            var result = self.browser.call(self.sid(), "DOM.resolveNode", .{ .backendNodeId = backend_id, .objectGroup = object_group }) catch
                return self.fail("element id {d} is stale; call tab.observe() again", .{id});
            defer result.deinit(self.browser.alloc);
            const object = if (result.value() == .object) result.value().object.get("object") else null;
            const object_id = if (object) |o| cdp.stringField(o, "objectId") else null;
            return self.alloc.dupe(u8, object_id orelse return self.fail("element id {d} is stale", .{id})) catch self.fail("out of memory", .{});
        }
        const selector = cdp.stringField(target, "selector") orelse return self.fail("missing selector", .{});
        const selector_json = cdp.jsonString(self.alloc, selector) catch return self.fail("out of memory", .{});
        defer self.alloc.free(selector_json);
        const expression = self.alloc.print("{s}.resolve({s})", .{ helper_source, selector_json }) catch return self.fail("out of memory", .{});
        defer self.alloc.free(expression);
        const deadline = io_mod.monotonicMilliTimestamp() + wait_ms;
        while (true) {
            var result = try self.evaluate(expression, false, false);
            defer result.deinit(self.browser.alloc);
            const remote = if (result.value() == .object) result.value().object.get("result") else null;
            if (remote) |r| if (cdp.stringField(r, "objectId")) |object_id| {
                return self.alloc.dupe(u8, object_id) catch self.fail("out of memory", .{});
            };
            if (io_mod.monotonicMilliTimestamp() >= deadline)
                return self.fail("no element matches {s}", .{selector_json});
            self.browser.conn.pump(100) catch |err| return self.protocolFailure(err, "wait");
        }
    }

    pub const Box = struct { x: f64, y: f64, width: f64, height: f64 };

    /// Scrolls the element into view and returns its viewport box.
    pub fn box(self: *Page, object_id: []const u8) Failure!Box {
        var result = try self.callOn(object_id,
            \\function() {
            \\  if (this.nodeType !== 1) throw new Error("not an element");
            \\  this.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
            \\  const r = this.getBoundingClientRect();
            \\  return { x: r.x, y: r.y, width: r.width, height: r.height };
            \\}
        , "", true);
        defer result.deinit(self.browser.alloc);
        const remote = if (result.value() == .object) result.value().object.get("result") else null;
        const value = if (remote) |r| if (r == .object) r.object.get("value") else null else null;
        const v = value orelse return self.fail("element has no box", .{});
        return .{
            .x = cdp.floatField(v, "x") orelse 0,
            .y = cdp.floatField(v, "y") orelse 0,
            .width = cdp.floatField(v, "width") orelse 0,
            .height = cdp.floatField(v, "height") orelse 0,
        };
    }

    pub fn mouse(self: *Page, kind: []const u8, x: f64, y: f64, click_count: u32) Failure!void {
        const button: []const u8 = if (std.mem.eql(u8, kind, "mouseMoved")) "none" else "left";
        var result = self.browser.call(self.sid(), "Input.dispatchMouseEvent", .{
            .type = kind,
            .x = x,
            .y = y,
            .button = button,
            .buttons = @as(u32, if (std.mem.eql(u8, kind, "mousePressed")) 1 else 0),
            .clickCount = click_count,
        }) catch |err| return self.protocolFailure(err, "mouse");
        result.deinit(self.browser.alloc);
    }

    pub fn wheel(self: *Page, x: f64, y: f64, dx: f64, dy: f64) Failure!void {
        var result = self.browser.call(self.sid(), "Input.dispatchMouseEvent", .{
            .type = "mouseWheel",
            .x = x,
            .y = y,
            .deltaX = dx,
            .deltaY = dy,
        }) catch |err| return self.protocolFailure(err, "scroll");
        result.deinit(self.browser.alloc);
    }

    /// Clicks the element's center with trusted mouse events.
    pub fn clickObject(self: *Page, object_id: []const u8, count: u32) Failure!void {
        const b = try self.box(object_id);
        if (b.width <= 0 or b.height <= 0) return self.fail("element is not visible (zero size)", .{});
        const x = b.x + b.width / 2;
        const y = b.y + b.height / 2;
        try self.mouse("mouseMoved", x, y, 0);
        var n: u32 = 1;
        while (n <= count) : (n += 1) {
            try self.mouse("mousePressed", x, y, n);
            try self.mouse("mouseReleased", x, y, n);
        }
    }

    pub fn insertText(self: *Page, text: []const u8) Failure!void {
        var result = self.browser.call(self.sid(), "Input.insertText", .{ .text = text }) catch |err| return self.protocolFailure(err, "insert text");
        result.deinit(self.browser.alloc);
    }

    pub fn key(self: *Page, spec: KeySpec, modifiers: u32) Failure!void {
        const text: ?[]const u8 = if (modifiers & (modifier_ctrl | modifier_meta | modifier_alt) != 0) null else spec.text;
        inline for (.{ "keyDown", "keyUp" }) |kind| {
            const is_down = comptime std.mem.eql(u8, kind, "keyDown");
            var result = self.browser.call(self.sid(), "Input.dispatchKeyEvent", .{
                .type = if (is_down and text == null) "rawKeyDown" else kind,
                .key = spec.key,
                .code = spec.code,
                .windowsVirtualKeyCode = spec.key_code,
                .nativeVirtualKeyCode = spec.key_code,
                .modifiers = modifiers,
                .text = if (is_down) text else null,
                .unmodifiedText = if (is_down) text else null,
            }) catch |err| return self.protocolFailure(err, "key");
            result.deinit(self.browser.alloc);
        }
    }

    pub fn releaseObjects(self: *Page) void {
        self.browser.callIgnored(self.sid(), "Runtime.releaseObjectGroup", .{ .objectGroup = object_group }) catch {};
    }
};

/// The text of a thrown exception, borrowed from `value`, or null.
pub fn exceptionText(value: Value) ?[]const u8 {
    if (value != .object) return null;
    const details = value.object.get("exceptionDetails") orelse return null;
    if (details.object.get("exception")) |exception| {
        if (cdp.stringField(exception, "description")) |text| return firstLines(text);
        if (exception == .object) if (exception.object.get("value")) |v| if (v == .string) return v.string;
    }
    return cdp.stringField(details, "text") orelse "script error";
}

/// The message of a stack trace without its frames.
fn firstLines(text: []const u8) []const u8 {
    var end: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "at ")) break;
        end = @intFromPtr(line.ptr) - @intFromPtr(text.ptr) + line.len;
    }
    return std.mem.trimEnd(u8, text[0..end], "\n ");
}

// ---- keys ---------------------------------------------------------------------

pub const modifier_alt: u32 = 1;
pub const modifier_ctrl: u32 = 2;
pub const modifier_meta: u32 = 4;
pub const modifier_shift: u32 = 8;

pub const KeySpec = struct {
    key: []const u8,
    code: []const u8,
    key_code: u32,
    text: ?[]const u8 = null,
};

const named_keys = [_]KeySpec{
    .{ .key = "Enter", .code = "Enter", .key_code = 13, .text = "\r" },
    .{ .key = "Tab", .code = "Tab", .key_code = 9 },
    .{ .key = "Escape", .code = "Escape", .key_code = 27 },
    .{ .key = "Backspace", .code = "Backspace", .key_code = 8 },
    .{ .key = "Delete", .code = "Delete", .key_code = 46 },
    .{ .key = "ArrowUp", .code = "ArrowUp", .key_code = 38 },
    .{ .key = "ArrowDown", .code = "ArrowDown", .key_code = 40 },
    .{ .key = "ArrowLeft", .code = "ArrowLeft", .key_code = 37 },
    .{ .key = "ArrowRight", .code = "ArrowRight", .key_code = 39 },
    .{ .key = "Home", .code = "Home", .key_code = 36 },
    .{ .key = "End", .code = "End", .key_code = 35 },
    .{ .key = "PageUp", .code = "PageUp", .key_code = 33 },
    .{ .key = "PageDown", .code = "PageDown", .key_code = 34 },
    .{ .key = " ", .code = "Space", .key_code = 32, .text = " " },
    .{ .key = "Insert", .code = "Insert", .key_code = 45 },
};

pub const ParsedKey = struct { spec: KeySpec, modifiers: u32, buf: [16]u8 = undefined };

/// Parses "Enter", "a", "Control+A", "Shift+Tab" or "Meta+Enter".
pub fn parseKey(text: []const u8, out: *ParsedKey) bool {
    var modifiers: u32 = 0;
    var rest = text;
    while (std.mem.findScalar(u8, rest, '+')) |plus| {
        if (plus + 1 >= rest.len) break; // "+" itself or "Shift++"
        const name = rest[0..plus];
        modifiers |= if (std.ascii.eqlIgnoreCase(name, "Shift"))
            modifier_shift
        else if (std.ascii.eqlIgnoreCase(name, "Control") or std.ascii.eqlIgnoreCase(name, "Ctrl"))
            modifier_ctrl
        else if (std.ascii.eqlIgnoreCase(name, "Alt") or std.ascii.eqlIgnoreCase(name, "Option"))
            modifier_alt
        else if (std.ascii.eqlIgnoreCase(name, "Meta") or std.ascii.eqlIgnoreCase(name, "Command") or std.ascii.eqlIgnoreCase(name, "Cmd") or std.ascii.eqlIgnoreCase(name, "ControlOrMeta"))
            modifier_meta
        else
            return false;
        rest = rest[plus + 1 ..];
    }
    out.modifiers = modifiers;
    for (named_keys) |spec| {
        if (std.ascii.eqlIgnoreCase(spec.key, rest) or (std.mem.eql(u8, spec.key, " ") and std.ascii.eqlIgnoreCase(rest, "Space"))) {
            out.spec = spec;
            return true;
        }
    }
    if (rest.len == 2 and (rest[0] == 'F' or rest[0] == 'f') and rest[1] >= '1' and rest[1] <= '9') {
        out.spec = .{ .key = rest, .code = rest, .key_code = 111 + @as(u32, rest[1] - '0') };
        return true;
    }
    if (rest.len != 1 or rest[0] < 0x20 or rest[0] > 0x7e) return false;
    const c = rest[0];
    out.buf[0] = c;
    const upper = std.ascii.toUpper(c);
    const code = if (std.ascii.isAlphabetic(c))
        std.mem.print(out.buf[1..], "Key{c}", .{upper}) catch return false
    else if (std.ascii.isDigit(c))
        std.mem.print(out.buf[1..], "Digit{c}", .{c}) catch return false
    else
        out.buf[0..1];
    out.spec = .{ .key = out.buf[0..1], .code = code, .key_code = if (std.ascii.isAlphanumeric(c)) upper else c, .text = out.buf[0..1] };
    return true;
}

test "browser keys parse names, characters and modifier chords" {
    var parsed: ParsedKey = .{ .spec = undefined, .modifiers = 0 };
    try std.testing.expect(parseKey("Enter", &parsed));
    try std.testing.expectEqual(@as(u32, 13), parsed.spec.key_code);
    try std.testing.expectEqualStrings("\r", parsed.spec.text.?);
    try std.testing.expect(parseKey("Control+a", &parsed));
    try std.testing.expectEqual(modifier_ctrl, parsed.modifiers);
    try std.testing.expectEqualStrings("KeyA", parsed.spec.code);
    try std.testing.expectEqual(@as(u32, 'A'), parsed.spec.key_code);
    try std.testing.expect(parseKey("Shift+Tab", &parsed));
    try std.testing.expectEqual(modifier_shift, parsed.modifiers);
    try std.testing.expect(parseKey("7", &parsed));
    try std.testing.expectEqualStrings("Digit7", parsed.spec.code);
    try std.testing.expect(parseKey("F5", &parsed));
    try std.testing.expectEqual(@as(u32, 116), parsed.spec.key_code);
    try std.testing.expect(parseKey("+", &parsed));
    try std.testing.expect(!parseKey("Hyper+x", &parsed));
    try std.testing.expect(!parseKey("Enterprise", &parsed));
}

test "browser exception text keeps the message and drops stack frames" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Value, alloc,
        \\{"result":{},"exceptionDetails":{"text":"Uncaught","exception":{"description":"Error: no element matches \"#x\"\n    at <anonymous>:3:9"}}}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Error: no element matches \"#x\"", exceptionText(parsed.value).?);
}
