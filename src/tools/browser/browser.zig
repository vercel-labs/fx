//! The browser tool: `open`, `close` and `run` against real Chromium tabs
//! over the DevTools protocol (D195 to D199), as proto's browser tool does.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const config_runtime = @import("../../core/config/config_runtime.zig");
const browser_mod = @import("../../core/browser/browser.zig");
const browser_settings = @import("../../core/browser/settings.zig");
const endpoint = @import("../../core/browser/endpoint.zig");
const launch = @import("../../core/browser/launch.zig");
const slot_mod = @import("../../core/browser/slot.zig");
const profile_paths = @import("../../core/shared/profile_paths.zig");
const output_mod = @import("output.zig");
const page_mod = @import("page.zig");
const run_mod = @import("run.zig");

const Allocator = std.mem.Allocator;
const DispatchContext = tool_dispatch.DispatchContext;
const ToolResult = tool_dispatch.ToolResult;

const default_timeout_s: i64 = 30;
const max_timeout_s: i64 = 300;

pub const Action = enum { open, close, run };

pub const Input = struct {
    action: Action,
    name: []u8,
    url: ?[]u8 = null,
    code: ?[]u8 = null,
    timeout_s: i64 = default_timeout_s,
    viewport: ?browser_mod.Viewport = null,
    dom_only: bool = false,
    dialogs: browser_mod.DialogPolicy = .accept,
    all: bool = false,
    kill: bool = false,
    cdp_url: ?[]u8 = null,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.url) |v| alloc.free(v);
        if (self.code) |v| alloc.free(v);
        if (self.cdp_url) |v| alloc.free(v);
    }
};

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn failure(alloc: Allocator, comptime fmt: []const u8, args: anytype) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.print(fmt, args) };
}

pub fn decode(ctx: DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const alloc = ctx.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch return failure(alloc, "browser arguments must be valid JSON", .{});
    defer parsed.deinit();
    if (parsed.value != .object) return failure(alloc, "browser arguments must be an object", .{});
    const object = parsed.value.object;
    const allowed = [_][]const u8{ "action", "name", "url", "code", "timeout", "viewport", "wait_until", "dialogs", "all", "kill", "app" };
    var it = object.iterator();
    while (it.next()) |entry| {
        for (allowed) |name| {
            if (std.mem.eql(u8, name, entry.key_ptr.*)) break;
        } else return failure(alloc, "browser field \"{s}\" is not allowed", .{entry.key_ptr.*});
    }
    const action_text = tool_args.optionalStringArg(object, "action") orelse return failure(alloc, "browser field \"action\" is required: open, close, or run", .{});
    const action = std.meta.stringToEnum(Action, action_text) orelse return failure(alloc, "browser action must be open, close, or run; screenshots, clicks and fills happen inside run", .{});
    const input = try alloc.create(Input);
    input.* = .{ .action = action, .name = alloc.dupe(u8, tool_args.optionalStringArg(object, "name") orelse browser_mod.default_tab_name) catch |err| {
        alloc.destroy(input);
        return err;
    } };
    var decoded = false;
    defer if (!decoded) inputDeinit(input, alloc);
    if (tool_args.optionalStringArg(object, "url")) |url| input.url = try alloc.dupe(u8, std.mem.trim(u8, url, " \t\r\n"));
    if (tool_args.optionalStringArg(object, "code")) |code| input.code = try alloc.dupe(u8, code);
    if (object.get("timeout")) |value| {
        const seconds: i64 = switch (value) {
            .integer => |n| n,
            .float => |f| @intFromFloat(@ceil(f)),
            else => return failure(alloc, "browser timeout must be a number of seconds", .{}),
        };
        input.timeout_s = std.math.clamp(seconds, 1, max_timeout_s);
    }
    if (object.get("viewport")) |value| {
        if (value != .object) return failure(alloc, "browser viewport must be an object with width and height", .{});
        const width = intOf(value.object.get("width")) orelse return failure(alloc, "browser viewport needs width and height", .{});
        const height = intOf(value.object.get("height")) orelse return failure(alloc, "browser viewport needs width and height", .{});
        input.viewport = .{
            .width = @intCast(std.math.clamp(width, 100, 7680)),
            .height = @intCast(std.math.clamp(height, 100, 7680)),
            .scale = if (value.object.get("scale")) |s| floatOf(s) orelse 1 else 1,
        };
    }
    if (tool_args.optionalStringArg(object, "wait_until")) |wait| input.dom_only = std.mem.eql(u8, wait, "domcontentloaded");
    if (tool_args.optionalStringArg(object, "dialogs")) |dialogs| input.dialogs = if (std.mem.eql(u8, dialogs, "dismiss")) .dismiss else .accept;
    if (object.get("all")) |value| input.all = value == .bool and value.bool;
    if (object.get("kill")) |value| input.kill = value == .bool and value.bool;
    if (object.get("app")) |app| {
        if (app != .object) return failure(alloc, "browser app must be an object", .{});
        if (tool_args.optionalStringArg(app.object, "cdp_url")) |url| input.cdp_url = try alloc.dupe(u8, url);
        var app_it = app.object.iterator();
        while (app_it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "cdp_url"))
                return failure(alloc, "browser app.{s} is not supported in proto-fx; use app.cdp_url for an existing DevTools endpoint", .{entry.key_ptr.*});
        }
    }
    decoded = true;
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn intOf(value: ?std.json.Value) ?i64 {
    return switch (value orelse return null) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn floatOf(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

pub fn validate(ctx: DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const alloc = ctx.allocator;
    switch (input.action) {
        .run => if (input.code == null or std.mem.trim(u8, input.code.?, " \t\r\n").len == 0)
            return try alloc.dupe(u8, "browser run needs code: JavaScript that uses tab, for example `return await tab.observe()`"),
        .open => if (input.url) |url| {
            if (!isOpenableUrl(url)) return try alloc.dupe(u8, "browser open takes an http(s) URL or about:blank; read local files with read_file, or serve them over http");
        },
        .close => {},
    }
    if (input.name.len == 0 or input.name.len > 64) return try alloc.dupe(u8, "browser tab name must be 1 to 64 characters");
    return null;
}

pub fn isOpenableUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://") or std.mem.eql(u8, url, "about:blank");
}

/// Opening and closing tabs only read; a run executes the model's code in
/// a page and needs approval (D198).
pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return erased.as(Input).action != .run;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const action = std.meta.stringToEnum(Action, tool_args.optionalStringArg(args, "action") orelse return null) orelse return null;
    const name = tool_args.optionalStringArg(args, "name") orelse browser_mod.default_tab_name;
    return switch (action) {
        .open => .{
            .activity_kind = .open,
            .action_label = "Opening",
            .completed_action_label = "Opened",
            .label_arg_kind = .url,
            .label_arg_default = "a browser tab",
        },
        .close => .{
            .activity_kind = .open,
            .action_label = "Closing",
            .completed_action_label = "Closed",
            .label_arg_kind = .none,
            .label_arg_default = if (args.get("all") != null) "all browser tabs" else name,
        },
        .run => .{
            .activity_kind = .command,
            .action_label = "Running browser script on",
            .completed_action_label = "Ran browser script on",
            .label_arg_kind = .none,
            .label_arg_default = name,
        },
    };
}

pub fn call(ctx: DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!ToolResult {
    const input = erased.as(Input);
    const alloc = ctx.allocator;
    const slot = ctx.browser orelse return .{ .failure = try alloc.dupe(u8, "the browser is unavailable in this host") };
    slot.acquire();
    defer slot.release();
    if (slot.browser) |b| if (!b.alive()) slot.closeLocked();
    var settings = config_runtime.loadBrowserSettings(alloc) catch browser_settings.Settings{};
    defer settings.deinit(alloc);
    if (slot.browser) |b| b.conn.cancel = ctx.cancel_flag;
    defer if (slot.browser) |b| {
        b.conn.cancel = null;
    };
    const result = switch (input.action) {
        .open => open(ctx, slot, input, &settings),
        .close => close(alloc, slot, input),
        .run => runAction(ctx, slot, input, &settings),
    };
    // A browser whose connection died is gone; the next open starts over.
    if (slot.browser) |b| if (!b.alive()) slot.closeLocked();
    return result;
}

fn open(ctx: DispatchContext, slot: *slot_mod.Slot, input: *Input, settings: *browser_settings.Settings) tool_dispatch.DispatchError!ToolResult {
    const alloc = ctx.allocator;
    const requested_cdp = input.cdp_url orelse settings.cdp_url;
    if (slot.browser) |b| {
        if (input.cdp_url) |wanted| {
            const same = b.backend == .connected and std.mem.eql(u8, b.backend.connected, std.mem.trimEnd(u8, wanted, "/"));
            if (!same) return .{ .failure = try alloc.print("this session's browser is {s}; close it with {{\"action\":\"close\",\"all\":true}} before connecting to {s}", .{ b.label, wanted }) };
        }
    } else {
        slot.browser = startBrowser(alloc, requested_cdp, settings, ctx.cancel_flag) catch |err| return .{ .failure = try startFailure(alloc, err, requested_cdp) };
        slot.browser.?.conn.cancel = ctx.cancel_flag;
    }
    const browser = slot.browser.?;
    const timeout_ms = input.timeout_s * 1000;
    var created = false;
    const tab = browser.findTab(input.name) orelse blk: {
        created = true;
        break :blk browser.openTab(input.name, input.viewport, input.dialogs) catch |err| {
            const message = try protocolMessage(alloc, browser, err, "could not open a tab");
            if (browser.tabs.items.len == 0) slot.closeLocked();
            return .{ .failure = message };
        };
    };
    tab.dialogs = input.dialogs;
    if (!created) if (input.viewport) |viewport| browser.setViewport(tab, viewport) catch {};
    if (input.url) |url| {
        browser.navigate(tab, url, input.dom_only, timeout_ms) catch |err| {
            const message = switch (err) {
                error.NavigationFailed => try alloc.print("could not load {s}: {s}", .{ url, browser.conn.lastError() }),
                error.Timeout => try alloc.print("{s} did not finish loading within {d}s; the tab stays open on what loaded", .{ url, input.timeout_s }),
                else => try protocolMessage(alloc, browser, err, "navigation failed"),
            };
            return .{ .failure = message };
        };
    }
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var page: page_mod.Page = .{ .alloc = arena_state.allocator(), .browser = browser, .tab = tab };
    const info = page.evaluateJson("[location.href, document.title]", false) catch "[\"\",\"\"]";
    const pair = std.json.parseFromSliceLeaky([2][]const u8, arena_state.allocator(), info, .{}) catch [2][]const u8{ "", "" };
    const verb = if (created) "Opened" else "Reused";
    if (pair[1].len > 0) return .{ .success = try alloc.print("{s} tab \"{s}\" in {s}\nURL: {s}\nTitle: {s}", .{ verb, tab.name, browser.label, pair[0], pair[1] }) };
    return .{ .success = try alloc.print("{s} tab \"{s}\" in {s}\nURL: {s}", .{ verb, tab.name, browser.label, pair[0] }) };
}

fn close(alloc: Allocator, slot: *slot_mod.Slot, input: *Input) tool_dispatch.DispatchError!ToolResult {
    const browser = slot.browser orelse {
        if (input.all) return .{ .success = try alloc.dupe(u8, "No browser tabs are open") };
        return .{ .success = try alloc.print("No tab named \"{s}\"", .{input.name}) };
    };
    if (input.all) {
        const count = browser.tabs.items.len;
        slot.closeLocked();
        return .{ .success = try alloc.print("Closed {d} browser tab{s} and the browser", .{ count, if (count == 1) "" else "s" }) };
    }
    const tab = browser.findTab(input.name) orelse return .{ .success = try alloc.print("No tab named \"{s}\"", .{input.name}) };
    browser.releaseTab(tab);
    // The browser fx launched has no other use; a borrowed one is only detached.
    if (browser.tabs.items.len == 0 or input.kill) {
        slot.closeLocked();
        return .{ .success = try alloc.print("Closed tab \"{s}\" and the browser", .{input.name}) };
    }
    return .{ .success = try alloc.print("Closed tab \"{s}\"", .{input.name}) };
}

fn runAction(ctx: DispatchContext, slot: *slot_mod.Slot, input: *Input, settings: *browser_settings.Settings) tool_dispatch.DispatchError!ToolResult {
    const alloc = ctx.allocator;
    const browser = slot.browser orelse return .{ .failure = try alloc.print("No tab named \"{s}\"; open it first with {{\"action\":\"open\",\"name\":\"{s}\",\"url\":\"...\"}}", .{ input.name, input.name }) };
    if (browser.findTab(input.name) == null) return .{ .failure = try alloc.print("No tab named \"{s}\"; open it first with {{\"action\":\"open\",\"name\":\"{s}\",\"url\":\"...\"}}", .{ input.name, input.name }) };
    var output: output_mod.Output = .{
        .gpa = alloc,
        .max_text_bytes = @max(4096, ctx.max_tool_result_bytes -| 1024),
        .screenshot_dir = settings.screenshot_dir,
    };
    defer output.deinit();
    const outcome = run_mod.run(alloc, browser, input.name, input.code.?, input.timeout_s * 1000, &output) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSuchTab => return .{ .failure = try alloc.print("No tab named \"{s}\"", .{input.name}) },
        error.ControllerUnavailable => return .{ .failure = try protocolMessage(alloc, browser, err, "could not start the script runner") },
    };
    const text = if (outcome.text.len == 0 and !outcome.failed) blk: {
        alloc.free(outcome.text);
        break :blk try alloc.print("Ran code on tab \"{s}\"", .{input.name});
    } else outcome.text;
    if (output.images.items.len > 0) {
        const images = try output.takeImages();
        return .{ .rich = .{ .text = text, .images = images, .is_error = outcome.failed } };
    }
    return if (outcome.failed) .{ .failure = text } else .{ .success = text };
}

fn protocolMessage(alloc: Allocator, browser: *browser_mod.Browser, err: anyerror, what: []const u8) ![]u8 {
    return switch (err) {
        error.CdpError => alloc.print("{s}: {s}", .{ what, browser.conn.lastError() }),
        error.Timeout => alloc.print("{s}: the browser did not answer in time", .{what}),
        error.ConnectionClosed => alloc.print("{s}: the browser connection closed", .{what}),
        error.Cancelled => alloc.dupe(u8, "cancelled"),
        else => alloc.print("{s}: {s}", .{ what, @errorName(err) }),
    };
}

fn startFailure(alloc: Allocator, err: anyerror, cdp_url: ?[]const u8) ![]u8 {
    return switch (err) {
        error.NoBrowserFound => alloc.dupe(u8, "No Chromium-family browser was found. Install Google Chrome or Chromium, run `npx playwright install chromium`, set browser.executable or FX_BROWSER_EXECUTABLE, or point browser.cdp_url at a running browser's DevTools endpoint."),
        error.InvalidEndpoint => alloc.print("browser cdp_url {s} must be http://host:port or a ws:// DevTools URL", .{cdp_url orelse ""}),
        error.EndpointUnreachable => alloc.print("no DevTools endpoint answered at {s}; start the browser with --remote-debugging-port", .{cdp_url orelse ""}),
        error.BrowserStartTimeout => alloc.dupe(u8, "the browser started but never opened its DevTools port within 20s"),
        error.BrowserLaunchFailed => alloc.dupe(u8, "the browser could not be started; check browser.executable"),
        error.Cancelled => alloc.dupe(u8, "cancelled"),
        else => alloc.print("could not start the browser: {s}", .{@errorName(err)}),
    };
}

/// Launches or connects the session's browser.
fn startBrowser(alloc: Allocator, cdp_url: ?[]const u8, settings: *const browser_settings.Settings, cancel: ?*std.atomic.Value(bool)) !*browser_mod.Browser {
    if (cdp_url) |url| {
        const ws_url = try endpoint.resolve(alloc, url);
        defer alloc.free(ws_url);
        const owned = try alloc.dupe(u8, std.mem.trimEnd(u8, url, "/"));
        errdefer alloc.free(owned);
        const label = try std.mem.concat(alloc, u8, &.{ "connected ", owned });
        defer alloc.free(label);
        return browser_mod.Browser.connect(alloc, ws_url, .{ .connected = owned }, label);
    }
    var candidate = (try launch.discover(alloc, .{ .home = io_mod.homeDir(), .explicit = settings.executable })) orelse return error.NoBrowserFound;
    defer candidate.deinit(alloc);
    const registry = try registryDir(alloc);
    defer if (registry) |dir| alloc.free(dir);
    var process = try launch.launch(alloc, .{ .exe = candidate.path, .kind = candidate.kind, .headless = settings.headless, .registry_dir = registry, .cancel = cancel });
    errdefer process.stop(alloc);
    const label = try alloc.print("{s} {s}", .{ if (settings.headless) "headless" else "visible", kindLabel(candidate.kind) });
    defer alloc.free(label);
    return browser_mod.Browser.connect(alloc, process.ws_url, .{ .launched = process }, label);
}

fn kindLabel(kind: launch.Kind) []const u8 {
    return switch (kind) {
        .chrome => "Google Chrome",
        .chrome_for_testing => "Chrome for Testing",
        .headless_shell => "Chrome headless shell",
        .chromium => "Chromium",
        .brave => "Brave",
        .edge => "Microsoft Edge",
        .custom => "browser",
    };
}

/// `~/.proto-fx/browser`, where launched browsers are recorded for reaping.
fn registryDir(alloc: Allocator) !?[]u8 {
    const home = io_mod.homeDir() orelse return null;
    const root = try profile_paths.rootDir(alloc, home);
    defer alloc.free(root);
    return try std.Io.Dir.path.join(alloc, &.{ root, "browser" });
}

var availability: std.atomic.Value(u8) = .init(0);

/// Whether a browser can be had: an endpoint is configured or a local
/// browser exists. Checked once per process (D196).
pub fn backendAvailable() bool {
    switch (availability.load(.acquire)) {
        1 => return true,
        2 => return false,
        else => {},
    }
    const alloc = std.heap.c_allocator;
    const found = blk: {
        var settings = config_runtime.loadBrowserSettings(alloc) catch browser_settings.Settings{};
        defer settings.deinit(alloc);
        if (settings.cdp_url != null) break :blk true;
        var candidate = (launch.discover(alloc, .{ .home = io_mod.homeDir(), .explicit = settings.executable }) catch null) orelse break :blk false;
        candidate.deinit(alloc);
        break :blk true;
    };
    availability.store(if (found) 1 else 2, .release);
    return found;
}

test "browser decode accepts proto's actions and rejects unknown fields and actions" {
    const alloc = std.testing.allocator;
    const ctx: DispatchContext = .{ .allocator = alloc };
    const decoded = try decode(ctx, "{\"action\":\"open\",\"url\":\" https://example.com \",\"viewport\":{\"width\":800,\"height\":600},\"timeout\":12.5,\"app\":{\"cdp_url\":\"http://127.0.0.1:9222\"}}");
    const input = decoded.input.as(Input);
    defer decoded.input.deinit(alloc);
    try std.testing.expectEqual(Action.open, input.action);
    try std.testing.expectEqualStrings("main", input.name);
    try std.testing.expectEqualStrings("https://example.com", input.url.?);
    try std.testing.expectEqual(@as(u32, 800), input.viewport.?.width);
    try std.testing.expectEqual(@as(i64, 13), input.timeout_s);
    try std.testing.expectEqualStrings("http://127.0.0.1:9222", input.cdp_url.?);
    try std.testing.expect(readsOnly(decoded.input));

    const screenshot = try decode(ctx, "{\"action\":\"screenshot\"}");
    defer alloc.free(screenshot.failure);
    try std.testing.expect(std.mem.find(u8, screenshot.failure, "inside run") != null);
    const extra = try decode(ctx, "{\"action\":\"run\",\"selector\":\"#x\"}");
    defer alloc.free(extra.failure);
    try std.testing.expectEqualStrings("browser field \"selector\" is not allowed", extra.failure);
    const path = try decode(ctx, "{\"action\":\"open\",\"app\":{\"path\":\"/Applications/Cursor.app\"}}");
    defer alloc.free(path.failure);
    try std.testing.expect(std.mem.find(u8, path.failure, "app.path is not supported") != null);
}

test "browser run needs code and approval while open and close only read" {
    const alloc = std.testing.allocator;
    const ctx: DispatchContext = .{ .allocator = alloc };
    const empty = try decode(ctx, "{\"action\":\"run\",\"code\":\"  \"}");
    defer empty.input.deinit(alloc);
    const reason = (try validate(ctx, empty.input)).?;
    defer alloc.free(reason);
    try std.testing.expect(std.mem.startsWith(u8, reason, "browser run needs code"));
    try std.testing.expect(!readsOnly(empty.input));

    const local = try decode(ctx, "{\"action\":\"open\",\"url\":\"file:///etc/passwd\"}");
    defer local.input.deinit(alloc);
    const refused = (try validate(ctx, local.input)).?;
    defer alloc.free(refused);
    try std.testing.expect(std.mem.find(u8, refused, "http(s) URL") != null);
}

test "browser calls present as opens, closes and script runs" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"action\":\"run\",\"name\":\"docs\",\"code\":\"x\"}", .{});
    defer parsed.deinit();
    const run_view = presentation(parsed.value.object).?;
    try std.testing.expectEqual(.command, run_view.activity_kind);
    try std.testing.expectEqualStrings("docs", run_view.label_arg_default);
    var opened = try std.json.parseFromSlice(std.json.Value, alloc, "{\"action\":\"open\",\"url\":\"https://example.com\"}", .{});
    defer opened.deinit();
    try std.testing.expectEqualStrings("Opened", presentation(opened.value.object).?.completed_action_label);
}
