//! End-to-end browser checks against a real Chromium. They run only when
//! PROTO_FX_BROWSER_TEST_EXE names a Chrome, Chromium or headless shell.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const browser_mod = @import("../../core/browser/browser.zig");
const launch = @import("../../core/browser/launch.zig");
const slot_mod = @import("../../core/browser/slot.zig");
const output_mod = @import("output.zig");
const run_mod = @import("run.zig");
const navigation_policy = @import("navigation_policy.zig");
const types = @import("../../core/shared/types.zig");

const form_page =
    "data:text/html,<title>Form</title><h1>Sign up</h1><form onsubmit=\"event.preventDefault();document.getElementById('out').textContent='Hello '+this.who.value+' ('+this.plan.value+')'\">" ++
    "<label>Name <input name=who></label><select name=plan><option value=free>Free</option><option value=pro>Pro</option></select>" ++
    "<button>Sign in</button></form><p id=out></p>";

fn testExe(alloc: std.mem.Allocator) !?[]u8 {
    var env = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer env.deinit();
    const exe = env.get("PROTO_FX_BROWSER_TEST_EXE") orelse return null;
    return if (exe.len > 0) try alloc.dupe(u8, exe) else null;
}

fn kindFor(exe: []const u8) launch.Kind {
    return if (std.mem.find(u8, exe, "headless") != null) .headless_shell else .chrome_for_testing;
}

fn runScript(alloc: std.mem.Allocator, browser: *browser_mod.Browser, code: []const u8, images: *usize) !run_mod.Outcome {
    var output: output_mod.Output = .{ .gpa = alloc, .max_text_bytes = 64 * 1024 };
    defer output.deinit();
    const outcome = try run_mod.run(alloc, browser, "main", code, 20_000, &output);
    images.* += output.images.items.len;
    return outcome;
}

test "a launched browser fills and submits a form, observes, screenshots, and leaves no process behind" {
    const alloc = std.testing.allocator;
    const exe = (try testExe(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(exe);
    var process = launch.launch(alloc, .{ .exe = exe, .kind = kindFor(exe) }) catch |e| {
        std.debug.print("launch: {s}\n", .{@errorName(e)});
        return e;
    };
    const pid = process.pid;
    var slot: slot_mod.Slot = .{};
    slot.browser = browser_mod.Browser.connect(alloc, process.ws_url, .{ .launched = process }, "headless test") catch |err| {
        std.debug.print("connect: {s}\n", .{@errorName(err)});
        process.stop(alloc);
        return err;
    };
    defer slot.deinit();
    const browser = slot.browser.?;
    const tab = browser.openTab("main", null, .accept) catch |e| {
        std.debug.print("openTab: {s} {s}\n", .{ @errorName(e), browser.conn.lastError() });
        return e;
    };
    browser.navigate(tab, form_page, false, 10_000) catch |e| {
        std.debug.print("navigate: {s} {s}\n", .{ @errorName(e), browser.conn.lastError() });
        return e;
    };

    var images: usize = 0;
    const observed = try runScript(alloc, browser, "const o = await tab.observe(); return o.elements.map(e => e.role + ':' + (e.name || '')).join(',');", &images);
    defer alloc.free(observed.text);
    try std.testing.expect(!observed.failed);
    try std.testing.expectEqualStrings("textbox:Name,combobox:,option:Free,option:Pro,button:Sign in", observed.text);

    const filled = try runScript(alloc, browser,
        \\await tab.fill('input[name=who]', 'Ada');
        \\await tab.select('select', 'pro');
        \\const o = await tab.observe();
        \\const btn = await tab.id(o.elements.find((e) => e.name === 'Sign in').id);
        \\await btn.click();
        \\await wait(async () => (await tab.text('#out')).length > 0);
        \\display('title ' + await tab.title());
        \\console.log('logged', 1);
        \\return await tab.text('#out');
    , &images);
    defer alloc.free(filled.text);
    try std.testing.expect(!filled.failed);
    try std.testing.expectEqualStrings("title Form\nlogged 1\nHello Ada (pro)", filled.text);

    const shot = try runScript(alloc, browser, "const p = await tab.screenshot(); return p.endsWith('.jpg') ? 'saved' : p;", &images);
    defer alloc.free(shot.text);
    try std.testing.expect(!shot.failed);
    try std.testing.expectEqual(@as(usize, 1), images);
    try std.testing.expect(std.mem.endsWith(u8, shot.text, "saved"));

    const missing = try runScript(alloc, browser, "await tab.click('#nope', { timeout: 200 });", &images);
    defer alloc.free(missing.text);
    try std.testing.expect(missing.failed);
    try std.testing.expect(std.mem.find(u8, missing.text, "no element matches \"#nope\"") != null);

    const aria = try runScript(alloc, browser, "const y = await tab.ariaSnapshot(); const ref = /button \"Sign in\"[^\\n]*\\[ref=(e\\d+)\\]/.exec(y)[1]; await tab.click(ref); return 'clicked ' + ref;", &images);
    defer alloc.free(aria.text);
    try std.testing.expect(!aria.failed);
    try std.testing.expect(std.mem.startsWith(u8, aria.text, "clicked e"));

    // A script that never ends is stopped at its deadline.
    var output: output_mod.Output = .{ .gpa = alloc, .max_text_bytes = 4096 };
    defer output.deinit();
    const stuck = try run_mod.run(alloc, browser, "main", "await new Promise(() => {});", 500, &output);
    defer alloc.free(stuck.text);
    try std.testing.expect(stuck.failed);
    try std.testing.expect(std.mem.find(u8, stuck.text, "timed out") != null);
    const after = try runScript(alloc, browser, "return 1 + 1", &images);
    defer alloc.free(after.text);
    try std.testing.expectEqualStrings("2", after.text);

    slot.deinit();
    // The browser's whole process group is gone.
    std.posix.kill(-pid, @fromBackingInt(@intCast(0))) catch |err| {
        try std.testing.expectEqual(error.ProcessNotFound, err);
        return;
    };
    return error.BrowserStillRunning;
}

test "a script's goto and a clicked link to a denied domain never load (D235)" {
    const alloc = std.testing.allocator;
    const exe = (try testExe(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(exe);
    var process = try launch.launch(alloc, .{ .exe = exe, .kind = kindFor(exe) });
    var slot: slot_mod.Slot = .{};
    slot.browser = browser_mod.Browser.connect(alloc, process.ws_url, .{ .launched = process }, "headless test") catch |err| {
        process.stop(alloc);
        return err;
    };
    defer slot.deinit();
    const browser = slot.browser.?;
    const tab = try browser.openTab("main", null, .accept);
    try browser.navigate(tab, "data:text/html,<title>Links</title><a id=go href=\"https://blocked.example/secret\">go</a>", false, 10_000);

    var rules = [_]types.PermissionRule{.{ .permission = @constCast("web_fetch"), .pattern = @constCast("domain:blocked.example"), .action = .deny }};
    const policy: navigation_policy.Policy = .{ .rules = .{ .rules = rules[0..] } };
    browser.guard = policy.guard();
    defer browser.guard = null;

    var images: usize = 0;
    const went = try runScript(alloc, browser, "await tab.goto('https://blocked.example/login'); return 'loaded';", &images);
    defer alloc.free(went.text);
    try std.testing.expect(went.failed);
    try std.testing.expect(std.mem.find(u8, went.text, "tab.goto(https://blocked.example/login) refused: https://blocked.example/login is denied by the web_fetch rule for domain:blocked.example") != null);

    const clicked = try runScript(alloc, browser, "await tab.click('#go'); await sleep(300); return await tab.url();", &images);
    defer alloc.free(clicked.text);
    try std.testing.expect(std.mem.find(u8, clicked.text, "navigation blocked: https://blocked.example/secret is denied") != null);
    try std.testing.expect(std.mem.find(u8, clicked.text, "https://blocked.example/secret\n") == null);
}
