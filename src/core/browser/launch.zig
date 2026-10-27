//! Finding and launching a local Chromium-family browser for the browser
//! tool (D196, D197).
//!
//! Discovery checks, in order: an explicit executable (setting or
//! `FX_BROWSER_EXECUTABLE`), installed Google Chrome, Chromium, Brave and
//! Edge, then Playwright's and Puppeteer's browser caches. A launch gets a
//! private temporary profile and a DevTools port of the browser's choosing,
//! runs in its own process group, and is recorded in the profile's
//! `browser/` folder so a later launch can reap it if fx died first.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const memory = @import("../kernel/memory.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum { chrome, chrome_for_testing, headless_shell, chromium, brave, edge, custom };

pub const Candidate = struct {
    path: []u8,
    kind: Kind,

    pub fn deinit(self: *Candidate, alloc: Allocator) void {
        alloc.free(self.path);
    }
};

const macos_apps = [_]struct { rel: []const u8, kind: Kind }{
    .{ .rel = "Google Chrome.app/Contents/MacOS/Google Chrome", .kind = .chrome },
    .{ .rel = "Chromium.app/Contents/MacOS/Chromium", .kind = .chromium },
    .{ .rel = "Brave Browser.app/Contents/MacOS/Brave Browser", .kind = .brave },
    .{ .rel = "Microsoft Edge.app/Contents/MacOS/Microsoft Edge", .kind = .edge },
};

const linux_paths = [_]struct { path: []const u8, kind: Kind }{
    .{ .path = "/usr/bin/google-chrome", .kind = .chrome },
    .{ .path = "/usr/bin/google-chrome-stable", .kind = .chrome },
    .{ .path = "/opt/google/chrome/chrome", .kind = .chrome },
    .{ .path = "/usr/bin/chromium", .kind = .chromium },
    .{ .path = "/usr/bin/chromium-browser", .kind = .chromium },
    .{ .path = "/snap/bin/chromium", .kind = .chromium },
    .{ .path = "/usr/bin/brave-browser", .kind = .brave },
    .{ .path = "/usr/bin/microsoft-edge", .kind = .edge },
};

/// Executables inside a Playwright `chromium-N` or `chromium_headless_shell-N`
/// folder, or a Puppeteer `chrome/<platform>-<version>` folder.
const cache_layouts = [_]struct { rel: []const u8, kind: Kind }{
    .{ .rel = "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing", .kind = .chrome_for_testing },
    .{ .rel = "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing", .kind = .chrome_for_testing },
    .{ .rel = "chrome-mac/Chromium.app/Contents/MacOS/Chromium", .kind = .chromium },
    .{ .rel = "chrome-linux64/chrome", .kind = .chrome_for_testing },
    .{ .rel = "chrome-linux/chrome", .kind = .chromium },
    .{ .rel = "chrome-headless-shell-mac-arm64/chrome-headless-shell", .kind = .headless_shell },
    .{ .rel = "chrome-headless-shell-mac-x64/chrome-headless-shell", .kind = .headless_shell },
    .{ .rel = "chrome-headless-shell-linux64/chrome-headless-shell", .kind = .headless_shell },
    .{ .rel = "chrome-mac/headless_shell", .kind = .headless_shell },
    .{ .rel = "chrome-linux/headless_shell", .kind = .headless_shell },
};

pub const DiscoveryInput = struct {
    home: ?[]const u8,
    explicit: ?[]const u8 = null,
    os: std.Target.Os.Tag = builtin.target.os.tag,
    /// Tests replace the file system check.
    exists_fn: *const fn ([]const u8) bool = fileExists,
    /// Lists entry names of a directory; tests replace it.
    list_fn: *const fn (Allocator, []const u8) anyerror![][]u8 = listDir,
};

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn listDir(alloc: Allocator, path: []const u8) anyerror![][]u8 {
    const io = io_mod.getIo();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(alloc);
}

/// The first browser found, or null. The caller owns the result.
pub fn discover(alloc: Allocator, input: DiscoveryInput) !?Candidate {
    if (input.explicit) |path| {
        if (path.len > 0 and input.exists_fn(path)) return .{ .path = try alloc.dupe(u8, path), .kind = .custom };
        return null;
    }
    switch (input.os) {
        .macos => {
            for (macos_apps) |app| {
                const system = try std.Io.Dir.path.join(alloc, &.{ "/Applications", app.rel });
                if (input.exists_fn(system)) return .{ .path = system, .kind = app.kind };
                alloc.free(system);
                if (input.home) |home| {
                    const user = try std.Io.Dir.path.join(alloc, &.{ home, "Applications", app.rel });
                    if (input.exists_fn(user)) return .{ .path = user, .kind = app.kind };
                    alloc.free(user);
                }
            }
        },
        else => for (linux_paths) |entry| {
            if (input.exists_fn(entry.path)) return .{ .path = try alloc.dupe(u8, entry.path), .kind = entry.kind };
        },
    }
    const home = input.home orelse return null;
    const caches: []const []const u8 = if (input.os == .macos)
        &.{ "Library/Caches/ms-playwright", ".cache/puppeteer/chrome", ".cache/puppeteer/chrome-headless-shell" }
    else
        &.{ ".cache/ms-playwright", ".cache/puppeteer/chrome", ".cache/puppeteer/chrome-headless-shell" };
    // A full browser beats a headless shell; within each, the newest folder wins.
    for ([_]bool{ false, true }) |shell_pass| {
        for (caches) |cache| {
            const root = try std.Io.Dir.path.join(alloc, &.{ home, cache });
            defer alloc.free(root);
            const names = input.list_fn(alloc, root) catch continue;
            defer {
                for (names) |name| alloc.free(name);
                alloc.free(names);
            }
            std.mem.sort([]u8, names, {}, newerFirst);
            for (names) |name| {
                const is_shell = std.mem.find(u8, name, "headless_shell") != null or std.mem.find(u8, cache, "headless-shell") != null;
                if (is_shell != shell_pass) continue;
                for (cache_layouts) |layout| {
                    const path = try std.Io.Dir.path.join(alloc, &.{ root, name, layout.rel });
                    if (input.exists_fn(path)) return .{ .path = path, .kind = layout.kind };
                    alloc.free(path);
                }
            }
        }
    }
    return null;
}

/// Orders cache folders by the number after their last '-' or '_', highest
/// first, then by name.
fn newerFirst(_: void, a: []u8, b: []u8) bool {
    const va = trailingNumber(a);
    const vb = trailingNumber(b);
    if (va != vb) return va > vb;
    return std.mem.order(u8, a, b) == .gt;
}

fn trailingNumber(name: []const u8) u64 {
    var start = name.len;
    while (start > 0 and (std.ascii.isDigit(name[start - 1]) or name[start - 1] == '.')) start -= 1;
    var digits = std.mem.splitScalar(u8, name[start..], '.');
    return std.fmt.parseInt(u64, digits.first(), 10) catch 0;
}

/// Command-line switches for a private, quiet headless browser.
pub fn launchArgs(alloc: Allocator, exe: []const u8, kind: Kind, profile_dir: []const u8, headless: bool) ![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(alloc);
    try args.append(alloc, exe);
    if (headless and kind != .headless_shell) try args.append(alloc, "--headless=new");
    try args.appendSlice(alloc, &.{
        "--remote-debugging-port=0",
        try alloc.print("--user-data-dir={s}", .{profile_dir}),
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-sync",
        "--disable-default-apps",
        "--disable-extensions",
        "--disable-features=Translate,MediaRouter,OptimizationHints",
        "--password-store=basic",
        "--use-mock-keychain",
        "--mute-audio",
        "--hide-scrollbars",
        "--window-size=1280,800",
        "about:blank",
    });
    return args.toOwnedSlice(alloc);
}

/// Reads `DevToolsActivePort`: the port on the first line and the browser
/// target path on the second. The caller owns the URL.
pub fn parseActivePort(alloc: Allocator, text: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const port_line = std.mem.trim(u8, lines.next() orelse return null, " \r");
    const path_line = std.mem.trim(u8, lines.next() orelse return null, " \r");
    const port = std.fmt.parseInt(u16, port_line, 10) catch return null;
    if (path_line.len == 0 or path_line[0] != '/') return null;
    return try alloc.print("ws://127.0.0.1:{d}{s}", .{ port, path_line });
}

/// A browser fx started. It owns its process and profile folder.
pub const Process = struct {
    child: std.process.Child,
    pid: std.posix.pid_t,
    profile_dir: []u8,
    ws_url: []u8,
    record_path: ?[]u8 = null,
    exe: []u8,
    /// Stops the browser if fx dies without closing it.
    sentinel: ?std.process.Child = null,

    /// Waits up to `timeout_ms` for the browser and every helper in its
    /// group to exit, reaping the browser when it does.
    fn awaitGone(self: *Process, timeout_ms: i64) bool {
        const deadline = io_mod.monotonicMilliTimestamp() + timeout_ms;
        while (true) {
            if (self.child.id) |pid| {
                var status: c_int = 0;
                if (std.c.waitpid(pid, &status, std.c.W.NOHANG) == pid) self.child.id = null;
            }
            if (self.child.id == null and !groupAlive(self.pid)) return true;
            if (io_mod.monotonicMilliTimestamp() >= deadline) return false;
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }

    /// Stops the browser and its helpers, reaps it, and removes its profile
    /// and record. Safe to call once.
    pub fn stop(self: *Process, alloc: Allocator) void {
        const io = io_mod.getIo();
        if (self.sentinel) |*sentinel| sentinel.kill(io);
        // A browser asked to close gets a moment; then the group it leads is
        // signalled, so no renderer or GPU helper outlives it.
        if (!self.awaitGone(1000)) {
            std.posix.kill(-self.pid, .TERM) catch {};
            if (!self.awaitGone(1000)) std.posix.kill(-self.pid, .KILL) catch {};
        }
        if (self.child.id != null) self.child.kill(io);
        debug_trace.logf("browser", "event=stopped pid={d}", .{self.pid});
        removeTree(self.profile_dir);
        if (self.record_path) |path| {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
            alloc.free(path);
        }
        alloc.free(self.profile_dir);
        alloc.free(self.ws_url);
        alloc.free(self.exe);
    }
};

/// True while any process of the group led by `pgid` is alive, the leader's
/// zombie included.
fn groupAlive(pgid: std.posix.pid_t) bool {
    std.posix.kill(-pgid, @fromBackingInt(@intCast(0))) catch return false;
    return true;
}

fn removeTree(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io_mod.getIo(), path) catch {};
}

pub const LaunchOptions = struct {
    exe: []const u8,
    kind: Kind,
    headless: bool = true,
    /// Folder for owned-browser records; null keeps none.
    registry_dir: ?[]const u8 = null,
    timeout_ms: i64 = 20_000,
    cancel: ?*std.atomic.Value(bool) = null,
};

pub const LaunchError = error{ BrowserLaunchFailed, BrowserStartTimeout, Cancelled, OutOfMemory };

pub fn launch(alloc: Allocator, options: LaunchOptions) LaunchError!Process {
    const io = io_mod.getIo();
    if (options.registry_dir) |dir| reapOrphans(alloc, dir);
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const tmp = io_mod.getenv("TMPDIR") orelse "/tmp";
    const hex = std.fmt.bytesToHex(nonce, .lower);
    const profile = alloc.print("{s}/proto-fx-browser-{s}", .{ std.mem.trimEnd(u8, tmp, "/"), &hex }) catch return error.OutOfMemory;
    errdefer alloc.free(profile);
    std.Io.Dir.cwd().createDirPath(io, profile) catch return error.BrowserLaunchFailed;
    errdefer removeTree(profile);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const argv = launchArgs(arena_state.allocator(), options.exe, options.kind, profile, options.headless) catch return error.OutOfMemory;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch return error.BrowserLaunchFailed;
    const pid = child.id.?;
    var stopped = false;
    errdefer if (!stopped) {
        std.posix.kill(-pid, .KILL) catch {};
        child.kill(io);
    };

    const port_path = std.Io.Dir.path.join(alloc, &.{ profile, "DevToolsActivePort" }) catch return error.OutOfMemory;
    defer alloc.free(port_path);
    const deadline = io_mod.monotonicMilliTimestamp() + options.timeout_ms;
    const ws_url = while (true) {
        if (options.cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        if (std.Io.Dir.cwd().readFileAlloc(io, port_path, alloc, .limited(4096))) |text| {
            defer alloc.free(text);
            if (parseActivePort(alloc, text) catch return error.OutOfMemory) |url| break url;
        } else |_| {}
        if (!groupAlive(pid)) return error.BrowserLaunchFailed;
        if (io_mod.monotonicMilliTimestamp() > deadline) return error.BrowserStartTimeout;
        io_mod.sleep(25 * std.time.ns_per_ms);
    };
    errdefer alloc.free(ws_url);
    const exe = alloc.dupe(u8, options.exe) catch return error.OutOfMemory;
    var process: Process = .{ .child = child, .pid = pid, .profile_dir = profile, .ws_url = ws_url, .exe = exe };
    stopped = true;
    process.sentinel = spawnSentinel(@intCast(std.c.getpid()), pid, profile);
    if (options.registry_dir) |dir| process.record_path = writeRecord(alloc, dir, pid, profile) catch null;
    return process;
}

/// The sentinel's script: while the owner lives it waits; then it stops the
/// browser's process group and deletes its profile. Arguments: owner pid,
/// browser process group, profile folder.
const sentinel_script =
    \\while kill -0 "$1" 2>/dev/null; do sleep 1; done
    \\kill -TERM -"$2" 2>/dev/null; sleep 2; kill -KILL -"$2" 2>/dev/null
    \\case "$3" in *proto-fx-browser-*) rm -rf "$3";; esac
;

/// Starts a small `/bin/sh` that stops the browser when `owner` exits, so a
/// killed fx leaves no browser behind (D197). Null when it cannot start;
/// the record still lets the next launch reap the browser.
pub fn spawnSentinel(owner: std.posix.pid_t, pgid: std.posix.pid_t, profile: []const u8) ?std.process.Child {
    var owner_buf: [16]u8 = undefined;
    var group_buf: [16]u8 = undefined;
    const owner_text = std.mem.print(&owner_buf, "{d}", .{owner}) catch return null;
    const group_text = std.mem.print(&group_buf, "{d}", .{pgid}) catch return null;
    return std.process.spawn(io_mod.getIo(), .{
        .argv = &.{ "/bin/sh", "-c", sentinel_script, "proto-fx-browser-sentinel", owner_text, group_text, profile },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch null;
}

/// What a record says: the browser, its owner, and its profile.
const Record = struct {
    pid: i64,
    start: u64,
    owner_pid: i64,
    owner_start: u64,
    profile: []const u8,
};

fn writeRecord(alloc: Allocator, dir: []const u8, pid: std.posix.pid_t, profile: []const u8) ![]u8 {
    const io = io_mod.getIo();
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const owner: std.posix.pid_t = @intCast(std.c.getpid());
    const record: Record = .{
        .pid = pid,
        .start = memory.startToken(pid) orelse 0,
        .owner_pid = owner,
        .owner_start = memory.startToken(owner) orelse 0,
        .profile = profile,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(record, .{}, &out.writer);
    var name_buf: [32]u8 = undefined;
    const name = try std.mem.print(&name_buf, "{d}.json", .{pid});
    const path = try std.Io.Dir.path.join(alloc, &.{ dir, name });
    errdefer alloc.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
    return path;
}

/// Stops browsers recorded by an fx process that is gone, and removes
/// their profiles and records. A record whose browser pid now names another
/// process only loses its record.
pub fn reapOrphans(alloc: Allocator, dir: []const u8) void {
    const io = io_mod.getIo();
    var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer handle.close(io);
    var it = handle.iterate();
    var stale: std.ArrayList([]u8) = .empty;
    defer {
        for (stale.items) |name| alloc.free(name);
        stale.deinit(alloc);
    }
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const bytes = handle.readFileAlloc(io, entry.name, alloc, .limited(16 * 1024)) catch continue;
        defer alloc.free(bytes);
        var parsed = std.json.parseFromSlice(Record, alloc, bytes, .{ .ignore_unknown_fields = true }) catch {
            stale.append(alloc, alloc.dupe(u8, entry.name) catch continue) catch {};
            continue;
        };
        defer parsed.deinit();
        const record = parsed.value;
        const owner_alive = (memory.startToken(@intCast(record.owner_pid)) orelse 0) == record.owner_start and record.owner_start != 0;
        if (owner_alive) continue;
        const pid: std.posix.pid_t = @intCast(record.pid);
        if (record.start != 0 and (memory.startToken(pid) orelse 0) == record.start) {
            std.posix.kill(-pid, .KILL) catch {};
        }
        if (std.mem.find(u8, record.profile, "proto-fx-browser-") != null) removeTree(record.profile);
        stale.append(alloc, alloc.dupe(u8, entry.name) catch continue) catch {};
    }
    for (stale.items) |name| handle.deleteFile(io, name) catch {};
}

// ---- tests -------------------------------------------------------------------

const FakeFs = struct {
    var files: []const []const u8 = &.{};
    var dirs: []const []const u8 = &.{};

    fn exists(path: []const u8) bool {
        for (files) |file| if (std.mem.eql(u8, file, path)) return true;
        return false;
    }

    fn list(alloc: Allocator, path: []const u8) anyerror![][]u8 {
        var names: std.ArrayList([]u8) = .empty;
        for (dirs) |dir| {
            if (!std.mem.startsWith(u8, dir, path) or dir.len <= path.len + 1 or dir[path.len] != '/') continue;
            const rest = dir[path.len + 1 ..];
            if (std.mem.findScalar(u8, rest, '/') != null) continue;
            try names.append(alloc, try alloc.dupe(u8, rest));
        }
        if (names.items.len == 0) {
            names.deinit(alloc);
            return error.FileNotFound;
        }
        return names.toOwnedSlice(alloc);
    }
};

fn discoverFake(alloc: Allocator, os: std.Target.Os.Tag) !?Candidate {
    return discover(alloc, .{ .home = "/Users/example", .os = os, .exists_fn = FakeFs.exists, .list_fn = FakeFs.list });
}

test "browser discovery prefers installed browsers, then the newest cached full browser, then a headless shell" {
    const alloc = std.testing.allocator;
    FakeFs.dirs = &.{
        "/Users/example/Library/Caches/ms-playwright/chromium-1100",
        "/Users/example/Library/Caches/ms-playwright/chromium-1234",
        "/Users/example/Library/Caches/ms-playwright/chromium_headless_shell-1234",
    };
    FakeFs.files = &.{
        "/Users/example/Library/Caches/ms-playwright/chromium-1100/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        "/Users/example/Library/Caches/ms-playwright/chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        "/Users/example/Library/Caches/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell",
    };
    var cached = (try discoverFake(alloc, .macos)).?;
    defer cached.deinit(alloc);
    try std.testing.expectEqual(Kind.chrome_for_testing, cached.kind);
    try std.testing.expect(std.mem.find(u8, cached.path, "chromium-1234/") != null);

    FakeFs.files = &.{"/Users/example/Library/Caches/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell"};
    var shell = (try discoverFake(alloc, .macos)).?;
    defer shell.deinit(alloc);
    try std.testing.expectEqual(Kind.headless_shell, shell.kind);

    FakeFs.files = &.{ "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", "/Users/example/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" };
    var installed = (try discoverFake(alloc, .macos)).?;
    defer installed.deinit(alloc);
    try std.testing.expectEqual(Kind.chrome, installed.kind);

    FakeFs.dirs = &.{};
    FakeFs.files = &.{"/usr/bin/chromium"};
    var linux = (try discoverFake(alloc, .linux)).?;
    defer linux.deinit(alloc);
    try std.testing.expectEqual(Kind.chromium, linux.kind);

    FakeFs.files = &.{};
    try std.testing.expect((try discoverFake(alloc, .linux)) == null);
    try std.testing.expect((try discover(alloc, .{ .home = null, .explicit = "/nope", .exists_fn = FakeFs.exists, .list_fn = FakeFs.list })) == null);
}

test "browser launch switches keep the profile private and skip --headless for a headless shell" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const full = try launchArgs(arena.allocator(), "/x/chrome", .chrome, "/tmp/p", true);
    try std.testing.expectEqualStrings("--headless=new", full[1]);
    try std.testing.expectEqualStrings("--user-data-dir=/tmp/p", full[3]);
    const shell = try launchArgs(arena.allocator(), "/x/shell", .headless_shell, "/tmp/p", true);
    for (shell) |arg| try std.testing.expect(!std.mem.startsWith(u8, arg, "--headless"));
    const visible = try launchArgs(arena.allocator(), "/x/chrome", .chrome, "/tmp/p", false);
    try std.testing.expectEqualStrings("--remote-debugging-port=0", visible[1]);
}

test "browser DevToolsActivePort names the browser websocket" {
    const alloc = std.testing.allocator;
    const url = (try parseActivePort(alloc, "53211\n/devtools/browser/0b1c\n")).?;
    defer alloc.free(url);
    try std.testing.expectEqualStrings("ws://127.0.0.1:53211/devtools/browser/0b1c", url);
    try std.testing.expect((try parseActivePort(alloc, "53211\n")) == null);
    try std.testing.expect((try parseActivePort(alloc, "x\n/devtools\n")) == null);
}

test "a browser sentinel stops the browser's group once its owner exits" {
    const io = std.testing.io;
    var owner = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "1" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    var group = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 });
    var sentinel = spawnSentinel(owner.id.?, group.id.?, "/nonexistent/proto-fx-browser-test").?;
    _ = try owner.wait(io);
    // The group's leader exits on TERM within the sentinel's poll interval.
    const term = try group.wait(io);
    try std.testing.expect(term == .signal);
    _ = try sentinel.wait(io);
}

test "browser orphan records of a dead owner are reaped and live owners are kept" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try tmp.dir.createDirPath(io, "proto-fx-browser-dead");
    const dead_profile = try std.Io.Dir.path.join(alloc, &.{ root, "proto-fx-browser-dead" });
    defer alloc.free(dead_profile);
    const me: std.posix.pid_t = @intCast(std.c.getpid());
    // A dead owner: pid 1 with a start token that cannot match.
    const dead = try std.mem.concat(alloc, u8, &.{ "{\"pid\":999999,\"start\":7,\"owner_pid\":1,\"owner_start\":7,\"profile\":\"", dead_profile, "\"}" });
    defer alloc.free(dead);
    try tmp.dir.writeFile(io, .{ .sub_path = "1.json", .data = dead });
    const live = try alloc.print("{{\"pid\":999998,\"start\":7,\"owner_pid\":{d},\"owner_start\":{d},\"profile\":\"/tmp/none\"}}", .{ me, memory.startToken(me) orelse 1 });
    defer alloc.free(live);
    try tmp.dir.writeFile(io, .{ .sub_path = "2.json", .data = live });
    reapOrphans(alloc, root);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "1.json", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "proto-fx-browser-dead", .{}));
    try tmp.dir.access(io, "2.json", .{});
}
