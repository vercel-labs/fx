//! `browser run`: the model's JavaScript runs in the controller page with a
//! `tab` bound to one named tab (D195). Each tab call arrives as a binding
//! event; this loop answers it, settles deferred waits, and stops the
//! script by closing the controller when the run's time is up or the user
//! cancels.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const cdp = @import("../../core/browser/cdp.zig");
const browser_mod = @import("../../core/browser/browser.zig");
const page_mod = @import("page.zig");
const ops = @import("ops.zig");
const output_mod = @import("output.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const prelude = @embedFile("prelude.js");

pub const Outcome = struct {
    /// Owned by the caller's allocator.
    text: []u8,
    failed: bool,
};

pub const Error = error{ OutOfMemory, NoSuchTab, ControllerUnavailable };

/// Wraps the model's code so `tab`, `display`, `assert`, `wait` and `sleep`
/// are in scope and the result comes back as text. The caller owns it.
pub fn wrapCode(alloc: Allocator, tab_name: []const u8, code: []const u8, budget_ms: i64) ![]u8 {
    const name_json = try cdp.jsonString(alloc, tab_name);
    defer alloc.free(name_json);
    return alloc.print(
        "(async () => {{ const {{ tab, display, assert, wait, sleep }} = __fxScope({s}, {d});\nconst __fxValue = await (async () => {{\n{s}\n}})();\nreturn __fxSerialize(__fxValue); }})()",
        .{ name_json, budget_ms, code },
    );
}

const Pending = struct { id: i64, waiter: ops.Waiter };

pub fn run(
    gpa: Allocator,
    browser: *browser_mod.Browser,
    tab_name: []const u8,
    code: []const u8,
    timeout_ms: i64,
    output: *output_mod.Output,
) Error!Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tab = browser.findTab(tab_name) orelse return error.NoSuchTab;
    const controller = browser.ensureController(prelude) catch return error.ControllerUnavailable;
    browser.clearNotes();
    browser.clearBindings();
    browser.collecting = true;
    defer browser.collecting = false;

    const started = io_mod.monotonicMilliTimestamp();
    const deadline = started + timeout_ms;
    const expression = try wrapCode(arena, tab_name, code, timeout_ms);
    const params = browser_mod.paramsJson(arena, .{ .expression = expression, .awaitPromise = true, .returnByValue = true }) catch return error.OutOfMemory;
    const run_id = browser.conn.send(controller.session_id, "Runtime.evaluate", params) catch {
        return finishFailure(gpa, output, "the browser connection closed");
    };

    var ctx: ops.Context = .{ .arena = arena, .browser = browser, .output = output, .deadline = deadline };
    var page: page_mod.Page = .{ .alloc = arena, .browser = browser, .tab = tab };
    defer page.releaseObjects();
    var pending: std.ArrayList(Pending) = .empty;

    while (true) {
        flushNotes(browser, output);
        if (browser.conn.early.fetchRemove(run_id)) |entry| {
            var result = entry.value;
            defer result.deinit(browser.alloc);
            flushNotes(browser, output);
            return finishResult(gpa, output, result.parsed.value);
        }
        if (browser.bindings.items.len > 0) {
            const payload = browser.bindings.orderedRemove(0);
            defer browser.alloc.free(payload);
            try handleBinding(&ctx, &page, controller.session_id, payload, &pending);
            continue;
        }
        var index: usize = 0;
        while (index < pending.items.len) {
            const item = &pending.items[index];
            page.message = null;
            const settled = ops.checkWaiter(&ctx, &page, &item.waiter) catch {
                reply(browser, controller.session_id, item.id, false, page.message orelse "wait failed");
                _ = pending.orderedRemove(index);
                continue;
            };
            if (settled) |value| {
                reply(browser, controller.session_id, item.id, true, value);
                _ = pending.orderedRemove(index);
                continue;
            }
            index += 1;
        }
        const left = deadline - io_mod.monotonicMilliTimestamp();
        if (left <= 0) {
            browser.dropController();
            const message = arena.print("browser run timed out after {d}s; the script was stopped. Raise timeout or split the work into smaller runs.", .{@divTrunc(timeout_ms, 1000)}) catch "browser run timed out";
            return finishFailure(gpa, output, message);
        }
        browser.conn.pump(@min(left, @as(i64, if (pending.items.len > 0) 50 else 200))) catch |err| switch (err) {
            error.Cancelled => {
                browser.dropController();
                return finishFailure(gpa, output, "cancelled");
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return finishFailure(gpa, output, "the browser connection closed during the run"),
        };
    }
}

fn handleBinding(ctx: *ops.Context, page: *page_mod.Page, controller_session: []const u8, payload: []const u8, pending: *std.ArrayList(Pending)) Error!void {
    const browser = ctx.browser;
    const request = std.json.parseFromSliceLeaky(Value, ctx.arena, payload, .{}) catch return;
    const id = cdp.intField(request, "id") orelse return;
    const op = cdp.stringField(request, "op") orelse return reply(browser, controller_session, id, false, "malformed request");
    const args = if (request.object.get("args")) |a| a else Value.null;
    if (args != .object) return reply(browser, controller_session, id, false, "malformed request");
    if (std.mem.eql(u8, op, "display")) {
        ctx.output.line(cdp.stringField(args, "text") orelse "");
        return reply(browser, controller_session, id, true, "null");
    }
    page.message = null;
    const answer = ops.perform(ctx, page, op, args) catch {
        return reply(browser, controller_session, id, false, page.message orelse "operation failed");
    };
    switch (answer) {
        .value => |value| reply(browser, controller_session, id, true, value),
        .deferred => |waiter| try pending.append(ctx.arena, .{ .id = id, .waiter = waiter }),
    }
}

/// Answers a script's request: `value` is JSON when `ok`, else an error message.
fn reply(browser: *browser_mod.Browser, controller_session: []const u8, id: i64, ok: bool, value: []const u8) void {
    const alloc = browser.alloc;
    const payload = if (ok) alloc.dupe(u8, value) catch return else cdp.jsonString(alloc, value) catch return;
    defer alloc.free(payload);
    const expression = alloc.print("__fxResolve({d}, {}, {s})", .{ id, ok, payload }) catch return;
    defer alloc.free(expression);
    browser.callIgnored(controller_session, "Runtime.evaluate", .{ .expression = expression }) catch {};
}

fn flushNotes(browser: *browser_mod.Browser, output: *output_mod.Output) void {
    for (browser.notes.items) |note| output.line(note);
    browser.clearNotes();
}

fn finishFailure(gpa: Allocator, output: *output_mod.Output, message: []const u8) Error!Outcome {
    const body = try output.finish(gpa);
    defer gpa.free(body);
    const prefix: []const u8 = if (namesError(message)) "" else "Error: ";
    const text = if (body.len > 0)
        try gpa.print("{s}\n{s}{s}", .{ body, prefix, message })
    else
        try gpa.print("{s}{s}", .{ prefix, message });
    return .{ .text = text, .failed = true };
}

/// Whether a message already starts with its error's name, as in
/// "TypeError: x is not a function".
fn namesError(message: []const u8) bool {
    const colon = std.mem.findScalar(u8, message, ':') orelse return false;
    const name = message[0..colon];
    if (name.len == 0 or name.len > 32 or std.mem.findScalar(u8, name, ' ') != null) return false;
    return std.mem.endsWith(u8, name, "Error") or std.mem.endsWith(u8, name, "Exception");
}

fn finishResult(gpa: Allocator, output: *output_mod.Output, response: Value) Error!Outcome {
    if (response == .object) {
        if (response.object.get("error")) |err_value| {
            return finishFailure(gpa, output, cdp.stringField(err_value, "message") orelse "the browser refused the script");
        }
    }
    const result = if (response == .object) response.object.get("result") orelse Value.null else Value.null;
    if (page_mod.exceptionText(result)) |message| return finishFailure(gpa, output, message);
    const remote = if (result == .object) result.object.get("result") else null;
    const value = if (remote) |r| if (r == .object) r.object.get("value") else null else null;
    if (value) |v| if (v == .string) output.line(v.string);
    return .{ .text = try output.finish(gpa), .failed = false };
}

test "browser run code is wrapped with the tab scope and a serialized result" {
    const alloc = std.testing.allocator;
    const wrapped = try wrapCode(alloc, "main", "return 1 // trailing comment", 30_000);
    defer alloc.free(wrapped);
    try std.testing.expect(std.mem.startsWith(u8, wrapped, "(async () => { const { tab, display, assert, wait, sleep } = __fxScope(\"main\", 30000);"));
    // A trailing line comment cannot swallow the closing braces.
    try std.testing.expect(std.mem.find(u8, wrapped, "return 1 // trailing comment\n})();") != null);
}

test "browser run results map return values and exceptions" {
    const alloc = std.testing.allocator;
    var output: output_mod.Output = .{ .gpa = alloc, .max_text_bytes = 1024 };
    defer output.deinit();
    output.line("shown first");
    var ok = try std.json.parseFromSlice(Value, alloc, "{\"id\":3,\"result\":{\"result\":{\"type\":\"string\",\"value\":\"42\"}}}", .{});
    defer ok.deinit();
    const done = try finishResult(alloc, &output, ok.value);
    defer alloc.free(done.text);
    try std.testing.expect(!done.failed);
    try std.testing.expectEqualStrings("shown first\n42", done.text);

    var output2: output_mod.Output = .{ .gpa = alloc, .max_text_bytes = 1024 };
    defer output2.deinit();
    var thrown = try std.json.parseFromSlice(Value, alloc, "{\"id\":4,\"result\":{\"result\":{},\"exceptionDetails\":{\"text\":\"Uncaught\",\"exception\":{\"description\":\"Error: no element matches \\\"#go\\\"\\n    at x\"}}}}", .{});
    defer thrown.deinit();
    const failed = try finishResult(alloc, &output2, thrown.value);
    defer alloc.free(failed.text);
    try std.testing.expect(failed.failed);
    try std.testing.expectEqualStrings("Error: no element matches \"#go\"", failed.text);
}
