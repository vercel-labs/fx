//! The tab API's operations (D195). A script's `tab.click(...)` reaches
//! `perform` as one request; the answer is JSON for the script, a deferred
//! wait the run loop settles later, or a failure the script sees as a thrown
//! Error.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const cdp = @import("../../core/browser/cdp.zig");
const browser_mod = @import("../../core/browser/browser.zig");
const html_to_markdown = @import("../web/html_to_markdown.zig");
const page_mod = @import("page.zig");
const observe = @import("observe.zig");
const output_mod = @import("output.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Page = page_mod.Page;
const Failure = page_mod.Failure;

/// How long an action waits for its selector to match by default.
const action_wait_ms: i64 = 5_000;

pub const Answer = union(enum) {
    /// JSON text for the script, owned by the run arena.
    value: []const u8,
    /// Settled later by the run loop.
    deferred: Waiter,
};

pub const Waiter = struct {
    kind: enum { navigation, url },
    tab: *browser_mod.Tab,
    start: u64 = 0,
    /// A URL substring, or a regular expression source when `regex`.
    pattern: []const u8 = "",
    regex: bool = false,
    dom_only: bool = false,
    deadline: i64,
    next_check: i64 = 0,
};

pub const Context = struct {
    arena: Allocator,
    browser: *browser_mod.Browser,
    output: *output_mod.Output,
    /// When the whole run must end.
    deadline: i64,
};

fn remaining(ctx: *const Context) i64 {
    return @max(0, ctx.deadline - io_mod.monotonicMilliTimestamp());
}

fn waitBudget(ctx: *const Context, args: Value, default_ms: i64) i64 {
    const asked = cdp.intField(args, "timeout") orelse default_ms;
    return @max(0, @min(asked, remaining(ctx)));
}

fn json(ctx: *Context, value: anytype) []const u8 {
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    std.json.Stringify.value(value, .{}, &out.writer) catch return "null";
    return out.toOwnedSlice() catch "null";
}

pub fn perform(ctx: *Context, page: *Page, op: []const u8, args: Value) Failure!Answer {
    const Op = enum { url, title, goto, history, reload, observe, aria, extract, text, html, screenshot, click, hover, focus, fill, type, press, select, check, scroll, scrollIntoView, waitFor, waitForNavigation, waitForUrl, evaluate, viewport, checkTarget, value, attribute, box };
    const kind = std.meta.stringToEnum(Op, op) orelse return page.fail("unknown tab operation {s}", .{op});
    const tab = page.tab;
    const browser = ctx.browser;
    switch (kind) {
        .url => return .{ .value = try page.evaluateJson("location.href", false) },
        .title => return .{ .value = try page.evaluateJson("document.title", false) },
        .goto => {
            const url = cdp.stringField(args, "url") orelse return page.fail("tab.goto needs a url", .{});
            const dom_only = if (cdp.stringField(args, "waitUntil")) |w| std.mem.eql(u8, w, "domcontentloaded") else false;
            browser.navigate(tab, url, dom_only, waitBudget(ctx, args, remaining(ctx))) catch |err| switch (err) {
                error.NavigationFailed => return page.fail("tab.goto({s}) failed: {s}", .{ url, browser.conn.lastError() }),
                error.Timeout => return page.fail("tab.goto({s}) timed out waiting for the page to load", .{url}),
                else => return page.protocolFailure(err, "tab.goto"),
            };
            return .{ .value = "null" };
        },
        .history, .reload => {
            const starts = tab.starts;
            if (kind == .reload) {
                var result = browser.call(tab.session_id, "Page.reload", .{}) catch |err| return page.protocolFailure(err, "tab.reload");
                result.deinit(browser.alloc);
            } else {
                const delta = cdp.intField(args, "delta") orelse -1;
                const expression = ctx.arena.print("history.go({d})", .{delta}) catch return page.fail("out of memory", .{});
                var result = try page.evaluate(expression, true, false);
                result.deinit(browser.alloc);
            }
            browser.settleAfterAction(tab, starts, waitBudget(ctx, args, remaining(ctx))) catch |err| return page.protocolFailure(err, "navigation");
            tab.elements.clearRetainingCapacity();
            return .{ .value = "null" };
        },
        .observe => return .{ .value = try observe.collect(ctx.arena, page, .{
            .include_all = boolField(args, "includeAll"),
            .viewport_only = boolField(args, "viewportOnly"),
        }) },
        .aria => {
            const install = ctx.arena.print(
                "(globalThis[Symbol.for(\"proto-fx.aria\")] ??= (() => {{ var module = {{ exports: {{}} }};\n{s}\n; return module.exports; }})(), true)",
                .{page_mod.aria_source},
            ) catch return page.fail("out of memory", .{});
            var installed = try page.evaluate(install, true, false);
            installed.deinit(browser.alloc);
            const selector_json = if (cdp.stringField(args, "selector")) |s| cdp.jsonString(ctx.arena, s) catch return page.fail("out of memory", .{}) else "null";
            const request = json(ctx, .{ .depth = cdp.intField(args, "depth"), .boxes = boolField(args, "boxes") });
            const expression = ctx.arena.print(
                "(() => {{ const sel = {s}; const root = sel ? {s}.resolve(sel) : null; if (sel && !root) throw new Error(\"tab.ariaSnapshot: selector \" + sel + \" matched no element\"); return globalThis[Symbol.for(\"proto-fx.aria\")].ariaSnapshot(root, {s}); }})()",
                .{ selector_json, page_mod.helper_source, request },
            ) catch return page.fail("out of memory", .{});
            return .{ .value = try page.evaluateJson(expression, false) };
        },
        .extract => {
            const format = cdp.stringField(args, "format") orelse "markdown";
            if (std.mem.eql(u8, format, "text")) return .{ .value = try page.evaluateJson("(document.body ? document.body.innerText : document.documentElement.innerText) || ''", false) };
            var result = try page.evaluate("document.documentElement.outerHTML", true, false);
            defer result.deinit(browser.alloc);
            const remote = if (result.value() == .object) result.value().object.get("result") else null;
            const html = if (remote) |r| cdp.stringField(r, "value") orelse "" else "";
            const markdown = html_to_markdown.convert(ctx.arena, html, .{ .max_output_bytes = 2 * 1024 * 1024 }) catch return page.fail("could not convert the page to markdown", .{});
            if (std.mem.trim(u8, markdown, " \n\t").len == 0) return page.fail("tab.extract found no readable content", .{});
            return .{ .value = json(ctx, markdown) };
        },
        .html => {
            if (args.object.get("target")) |target| {
                const object_id = try page.resolveTarget(target, waitBudget(ctx, args, action_wait_ms));
                return .{ .value = try page.callOnJson(object_id, "function() { return this.outerHTML; }", "") };
            }
            return .{ .value = try page.evaluateJson("document.documentElement.outerHTML", false) };
        },
        .text, .value, .attribute, .box, .focus, .scrollIntoView, .checkTarget => {
            const target = args.object.get("target") orelse return page.fail("missing element target", .{});
            const wait_ms: i64 = if (kind == .checkTarget) 0 else waitBudget(ctx, args, action_wait_ms);
            const object_id = try page.resolveTarget(target, wait_ms);
            const function: []const u8 = switch (kind) {
                .text => "function() { return (this.innerText ?? this.textContent ?? '').trim(); }",
                .value => "function() { return this.value ?? null; }",
                .attribute => "function(name) { return this.getAttribute(name); }",
                .box => "function() { const r = this.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; }",
                .focus => "function() { this.focus(); return null; }",
                .scrollIntoView => "function() { this.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); return null; }",
                else => "function() { return null; }",
            };
            const call_args = if (kind == .attribute)
                ctx.arena.print("[{{\"value\":{s}}}]", .{json(ctx, cdp.stringField(args, "name") orelse "")}) catch return page.fail("out of memory", .{})
            else
                "";
            return .{ .value = try page.callOnJson(object_id, function, call_args) };
        },
        .screenshot => return .{ .value = try ctx.output.screenshot(ctx.arena, page, args) },
        .click, .hover => {
            const target = args.object.get("target") orelse return page.fail("missing element target", .{});
            const object_id = try page.resolveTarget(target, waitBudget(ctx, args, action_wait_ms));
            const starts = tab.starts;
            if (kind == .hover) {
                const b = try page.box(object_id);
                try page.mouse("mouseMoved", b.x + b.width / 2, b.y + b.height / 2, 0);
                return .{ .value = "null" };
            }
            const count: u32 = @intCast(std.math.clamp(cdp.intField(args, "count") orelse 1, 1, 3));
            try page.clickObject(object_id, count);
            browser.settleAfterAction(tab, starts, remaining(ctx)) catch |err| return page.protocolFailure(err, "navigation after click");
            return .{ .value = "null" };
        },
        .fill => {
            const target = args.object.get("target") orelse return page.fail("missing element target", .{});
            const value = cdp.stringField(args, "value") orelse "";
            const object_id = try page.resolveTarget(target, waitBudget(ctx, args, action_wait_ms));
            const prepared = try page.callOnJson(object_id, prepare_fill, "");
            if (std.mem.eql(u8, prepared, "\"select\"")) return page.fail("tab.fill does not work on <select>; use tab.select", .{});
            if (std.mem.startsWith(u8, prepared, "\"unfillable")) return page.fail("this element cannot be filled ({s}); click or check it instead", .{prepared});
            if (value.len > 0) try page.insertText(value);
            const changed = try page.callOnJson(object_id, "function() { this.dispatchEvent(new Event('change', { bubbles: true })); return null; }", "");
            _ = changed;
            return .{ .value = "null" };
        },
        .type => {
            const target = args.object.get("target") orelse return page.fail("missing element target", .{});
            const text = cdp.stringField(args, "text") orelse "";
            const object_id = try page.resolveTarget(target, waitBudget(ctx, args, action_wait_ms));
            _ = try page.callOnJson(object_id, "function() { this.focus(); return null; }", "");
            const starts = tab.starts;
            try typeText(page, text);
            browser.settleAfterAction(tab, starts, remaining(ctx)) catch |err| return page.protocolFailure(err, "navigation after typing");
            return .{ .value = "null" };
        },
        .press => {
            const key_text = cdp.stringField(args, "key") orelse return page.fail("tab.press needs a key", .{});
            var parsed: page_mod.ParsedKey = .{ .spec = undefined, .modifiers = 0 };
            if (!page_mod.parseKey(key_text, &parsed)) return page.fail("unknown key {s}; use names like Enter, Tab, Escape, ArrowDown, or chords like Control+A", .{key_text});
            if (args.object.get("target")) |target| {
                const object_id = try page.resolveTarget(target, waitBudget(ctx, args, action_wait_ms));
                _ = try page.callOnJson(object_id, "function() { this.focus(); return null; }", "");
            }
            const starts = tab.starts;
            try page.key(parsed.spec, parsed.modifiers);
            browser.settleAfterAction(tab, starts, remaining(ctx)) catch |err| return page.protocolFailure(err, "navigation after key press");
            return .{ .value = "null" };
        },
        .select => {
            const target = args.object.get("target") orelse return page.fail("missing element target", .{});
            const values = args.object.get("values") orelse return page.fail("tab.select needs option values", .{});
            const object_id = try page.resolveTarget(target, waitBudget(ctx, args, action_wait_ms));
            const call_args = ctx.arena.print("[{{\"value\":{s}}}]", .{json(ctx, values)}) catch return page.fail("out of memory", .{});
            return .{ .value = try page.callOnJson(object_id, select_options, call_args) };
        },
        .check => {
            const target = args.object.get("target") orelse return page.fail("missing element target", .{});
            const want = boolField(args, "checked");
            const object_id = try page.resolveTarget(target, waitBudget(ctx, args, action_wait_ms));
            const state = try page.callOnJson(object_id, "function() { if (!('checked' in this)) throw new Error('element is not a checkbox or radio'); return this.checked; }", "");
            if (std.mem.eql(u8, state, if (want) "true" else "false")) return .{ .value = "null" };
            const starts = tab.starts;
            try page.clickObject(object_id, 1);
            browser.settleAfterAction(tab, starts, remaining(ctx)) catch |err| return page.protocolFailure(err, "navigation after check");
            return .{ .value = "null" };
        },
        .scroll => {
            const dx = cdp.floatField(args, "deltaX") orelse 0;
            const dy = cdp.floatField(args, "deltaY") orelse 0;
            const size = try page.evaluateJson("[innerWidth, innerHeight]", false);
            var x: f64 = 400;
            var y: f64 = 300;
            if (std.json.parseFromSliceLeaky([2]f64, ctx.arena, size, .{})) |dims| {
                x = dims[0] / 2;
                y = dims[1] / 2;
            } else |_| {}
            try page.wheel(x, y, dx, dy);
            // Let the scroll land before the script reads positions.
            _ = try page.evaluateJson("new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r(null))))", true);
            return .{ .value = "null" };
        },
        .waitFor => {
            const target = args.object.get("target") orelse return page.fail("missing element target", .{});
            _ = try page.resolveTarget(target, waitBudget(ctx, args, 30_000));
            return .{ .value = "null" };
        },
        .waitForNavigation => {
            const dom_only = if (cdp.stringField(args, "waitUntil")) |w| std.mem.eql(u8, w, "domcontentloaded") else false;
            return .{ .deferred = .{
                .kind = .navigation,
                .tab = tab,
                .start = if (dom_only) tab.dom_ready else tab.loads,
                .dom_only = dom_only,
                .deadline = io_mod.monotonicMilliTimestamp() + waitBudget(ctx, args, 30_000),
            } };
        },
        .waitForUrl => return .{ .deferred = .{
            .kind = .url,
            .tab = tab,
            .pattern = ctx.arena.dupe(u8, cdp.stringField(args, "pattern") orelse "") catch return page.fail("out of memory", .{}),
            .regex = boolField(args, "regex"),
            .deadline = io_mod.monotonicMilliTimestamp() + waitBudget(ctx, args, 30_000),
        } },
        .evaluate => return .{ .value = try evaluate(ctx, page, args) },
        .viewport => {
            const width = cdp.intField(args, "width") orelse return page.fail("tab.setViewport needs width and height", .{});
            const height = cdp.intField(args, "height") orelse return page.fail("tab.setViewport needs width and height", .{});
            browser.setViewport(tab, .{
                .width = @intCast(std.math.clamp(width, 100, 7680)),
                .height = @intCast(std.math.clamp(height, 100, 7680)),
                .scale = cdp.floatField(args, "scale") orelse 1,
            }) catch |err| return page.protocolFailure(err, "tab.setViewport");
            return .{ .value = "null" };
        },
    }
}

fn boolField(args: Value, name: []const u8) bool {
    if (args != .object) return false;
    const value = args.object.get(name) orelse return false;
    return value == .bool and value.bool;
}

/// Types text with key events, one character at a time; a newline presses Enter.
fn typeText(page: *Page, text: []const u8) Failure!void {
    var view = std.unicode.Utf8View.init(text) catch return page.fail("text is not valid UTF-8", .{});
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        if (std.mem.eql(u8, slice, "\n")) {
            var parsed: page_mod.ParsedKey = .{ .spec = undefined, .modifiers = 0 };
            _ = page_mod.parseKey("Enter", &parsed);
            try page.key(parsed.spec, 0);
            continue;
        }
        var parsed: page_mod.ParsedKey = .{ .spec = undefined, .modifiers = 0 };
        if (slice.len == 1 and page_mod.parseKey(slice, &parsed)) {
            try page.key(parsed.spec, 0);
        } else {
            // Characters without a key of their own arrive as text input.
            try page.insertText(slice);
        }
    }
}

/// `tab.evaluate(fn, ...args)` or `tab.evaluate("expression")`, and a
/// handle's `evaluate(fn, ...args)` with the element first.
fn evaluate(ctx: *Context, page: *Page, args: Value) Failure![]const u8 {
    const source = cdp.stringField(args, "source") orelse return page.fail("tab.evaluate needs a function or expression", .{});
    const is_function = boolField(args, "isFunction") or boolField(args, "element");
    if (!is_function) return page.evaluateJson(source, true);
    // Call it on the page's global object, or on the element for a handle.
    const object_id = if (args.object.get("target")) |target|
        try page.resolveTarget(target, waitBudget(ctx, args, action_wait_ms))
    else blk: {
        var global = try page.evaluate("globalThis", false, false);
        defer global.deinit(ctx.browser.alloc);
        const remote = if (global.value() == .object) global.value().object.get("result") else null;
        const id = if (remote) |r| cdp.stringField(r, "objectId") else null;
        break :blk ctx.arena.dupe(u8, id orelse return page.fail("the page has no global object", .{})) catch return page.fail("out of memory", .{});
    };
    var list: std.ArrayList(u8) = .empty;
    list.append(ctx.arena, '[') catch return page.fail("out of memory", .{});
    if (boolField(args, "element")) list.appendSlice(ctx.arena, "{\"objectId\":") catch {};
    if (boolField(args, "element")) {
        list.appendSlice(ctx.arena, json(ctx, object_id)) catch {};
        list.append(ctx.arena, '}') catch {};
    }
    if (args.object.get("args")) |extra| if (extra == .array) for (extra.array.items, 0..) |item, index| {
        if (index > 0 or boolField(args, "element")) list.append(ctx.arena, ',') catch {};
        list.appendSlice(ctx.arena, "{\"value\":") catch {};
        list.appendSlice(ctx.arena, json(ctx, item)) catch {};
        list.append(ctx.arena, '}') catch {};
    };
    list.append(ctx.arena, ']') catch return page.fail("out of memory", .{});
    // An element handle's function is called as fn(element, ...args).
    const wrapped = if (boolField(args, "element"))
        ctx.arena.print("function(el, ...rest) {{ return ({s})(el, ...rest); }}", .{source}) catch return page.fail("out of memory", .{})
    else
        ctx.arena.print("function(...rest) {{ return ({s})(...rest); }}", .{source}) catch return page.fail("out of memory", .{});
    return page.callOnJson(object_id, wrapped, list.items);
}

/// Settles a deferred wait: null while pending, else the JSON answer or a failure.
pub fn checkWaiter(ctx: *Context, page: *Page, waiter: *Waiter) Failure!?[]const u8 {
    const now = io_mod.monotonicMilliTimestamp();
    switch (waiter.kind) {
        .navigation => {
            const counter = if (waiter.dom_only) waiter.tab.dom_ready else waiter.tab.loads;
            if (counter != waiter.start) return "null";
            if (now >= waiter.deadline) return page.fail("tab.waitForNavigation timed out", .{});
            return null;
        },
        .url => {
            if (now < waiter.next_check) return null;
            waiter.next_check = now + 150;
            const pattern = json(ctx, waiter.pattern);
            const expression = if (waiter.regex)
                ctx.arena.print("new RegExp({s}).test(location.href)", .{pattern}) catch return page.fail("out of memory", .{})
            else
                ctx.arena.print("location.href.includes({s})", .{pattern}) catch return page.fail("out of memory", .{});
            const matched = page.evaluateJson(expression, false) catch "false";
            if (std.mem.eql(u8, matched, "true")) return try page.evaluateJson("location.href", false);
            if (now >= waiter.deadline) return page.fail("tab.waitForUrl({s}) timed out", .{waiter.pattern});
            return null;
        },
    }
}

const prepare_fill =
    \\function() {
    \\  this.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    \\  this.focus();
    \\  if (this.tagName === "SELECT") return "select";
    \\  if (this.tagName === "INPUT" || this.tagName === "TEXTAREA") {
    \\    const type = (this.type || "").toLowerCase();
    \\    if (["checkbox", "radio", "file", "submit", "button", "reset", "image", "range", "color"].includes(type)) return "unfillable " + type;
    \\    if (this.readOnly || this.disabled) return "unfillable read-only";
    \\    const proto = this.tagName === "INPUT" ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
    \\    Object.getOwnPropertyDescriptor(proto, "value").set.call(this, "");
    \\    this.dispatchEvent(new Event("input", { bubbles: true }));
    \\    return "input";
    \\  }
    \\  if (this.isContentEditable) {
    \\    const range = document.createRange();
    \\    range.selectNodeContents(this);
    \\    const selection = getSelection();
    \\    selection.removeAllRanges();
    \\    selection.addRange(range);
    \\    return "editable";
    \\  }
    \\  return "unfillable " + this.tagName.toLowerCase();
    \\}
;

const select_options =
    \\function(values) {
    \\  if (this.tagName !== "SELECT") throw new Error("tab.select needs a <select> element");
    \\  const options = Array.from(this.options);
    \\  const wanted = (o) => values.includes(o.value) || values.includes(o.label) || values.includes(o.textContent.trim());
    \\  if (!options.some(wanted)) throw new Error("no option matches " + JSON.stringify(values));
    \\  for (const o of options) o.selected = wanted(o) && (this.multiple || !options.slice(0, options.indexOf(o)).some((p) => p.selected && wanted(p)));
    \\  this.dispatchEvent(new Event("input", { bubbles: true }));
    \\  this.dispatchEvent(new Event("change", { bubbles: true }));
    \\  return options.filter((o) => o.selected).map((o) => o.value);
    \\}
;
