//! The Vercel login the built-in remote runner reads (R2) and its expiry
//! check (R3). Parsing and the choice of source are pure: the environment,
//! the files and the trace sink come in as values (module rule 6), so tests
//! pass fakes. Only `disk` touches the disk.

const std = @import("std");
const io_mod = @import("../../shared/io.zig");

/// The largest auth.json read (R3.7). The Vercel CLI writes a few hundred bytes.
pub const max_auth_file_bytes: usize = 64 * 1024;
/// The largest token accepted from any source (R3.7).
pub const max_token_bytes: usize = 4 * 1024;
/// A token that expires within this many seconds counts as expired (R3).
pub const expiry_margin_s: i64 = 60;

const vercel_dir = "com.vercel.cli";
const auth_file = "auth.json";

/// The Vercel token. Its text is reached only through `bytes`. Formatting it
/// prints a fixed label, so a stray print cannot show the value (R4.8).
pub const Token = struct {
    value: []const u8,

    pub fn bytes(self: Token) []const u8 {
        return self.value;
    }

    pub fn format(self: Token, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self;
        try writer.writeAll("Token(redacted)");
    }
};

/// `token` is usable. `missing` is E5 (no login). `expired` is E6 (the saved
/// login is too close to its end to use).
pub const AuthResult = union(enum) {
    token: Token,
    missing,
    expired,
};

/// The environment values the login reads. Null means not set.
pub const Env = struct {
    vercel_token: ?[]const u8 = null,
    home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
};

pub const FileRead = union(enum) {
    absent,
    /// The file exists but cannot be read, or is larger than `max_auth_file_bytes`.
    unreadable,
    bytes: []const u8,
};

/// Reads one file for the login. The caller owns the returned bytes through `arena`.
pub const Files = struct {
    context: ?*anyopaque,
    read: *const fn (context: ?*anyopaque, arena: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!FileRead,
};

/// Where one trace line goes. A line names the step and the outcome only (U12).
pub const Trace = struct {
    context: ?*anyopaque,
    line: *const fn (context: ?*anyopaque, text: []const u8) void,

    pub fn write(self: Trace, text: []const u8) void {
        self.line(self.context, text);
    }
};

pub const discard_trace: Trace = .{ .context = null, .line = ignoreLine };

fn ignoreLine(context: ?*anyopaque, text: []const u8) void {
    _ = context;
    _ = text;
}

/// The reader of the real disk, the only I/O in this file. A path that is not
/// absolute is unreadable, so a relative HOME cannot reach the filesystem.
pub const disk: Files = .{ .context = null, .read = readDisk };

fn readDisk(context: ?*anyopaque, arena: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!FileRead {
    _ = context;
    if (!std.Io.Dir.path.isAbsolute(path)) return .unreadable;
    const io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return .unreadable,
    };
    defer file.close(io);
    const bytes = io_mod.readFileToEnd(arena, &file, max_auth_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unreadable,
    };
    return .{ .bytes = bytes };
}

/// Reads one auth.json. Bytes over `max_auth_file_bytes`, broken JSON, a root
/// that is not an object, a token that is not a JSON string, a token that is
/// empty or not visible ASCII, and an `expiresAt` that is neither absent,
/// null, nor a JSON integer all give `missing`. An absent or null `expiresAt`
/// skips the expiry check. A token expires when `expiresAt` is not later than
/// `now_unix_s + expiry_margin_s`. The token's bytes are owned by `arena`.
pub fn parseAuthJson(arena: std.mem.Allocator, bytes: []const u8, now_unix_s: i64) std.mem.Allocator.Error!AuthResult {
    if (bytes.len > max_auth_file_bytes) return .missing;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .missing,
    };
    const object = switch (root) {
        .object => |map| map,
        else => return .missing,
    };
    const token = switch (object.get("token") orelse return .missing) {
        .string => |text| text,
        else => return .missing,
    };
    if (!usableToken(token)) return .missing;
    const expires_at: ?i64 = switch (object.get("expiresAt") orelse .null) {
        .null => null,
        .integer => |value| value,
        else => return .missing,
    };
    if (expires_at) |value| {
        if (value <= now_unix_s +| expiry_margin_s) return .expired;
    }
    return .{ .token = .{ .value = token } };
}

/// A token that can go into an HTTP header: non-empty, short, and visible
/// ASCII with no spaces, so no header can be split by a stray byte.
fn usableToken(token: []const u8) bool {
    if (token.len == 0 or token.len > max_token_bytes) return false;
    for (token) |byte| {
        if (byte < 0x21 or byte > 0x7e) return false;
    }
    return true;
}

/// The login order of R2. A set, non-empty `VERCEL_TOKEN` wins with no expiry
/// check. Otherwise the first auth.json that exists decides, and a file that
/// exists but is broken does not fall through to the next path. The macOS path
/// is tried only on macOS.
pub fn load(
    arena: std.mem.Allocator,
    env: Env,
    os: std.Target.Os.Tag,
    files: Files,
    trace: Trace,
    now_unix_s: i64,
) std.mem.Allocator.Error!AuthResult {
    if (env.vercel_token) |value| {
        if (value.len != 0) {
            const result: AuthResult = if (usableToken(value)) .{ .token = .{ .value = value } } else .missing;
            traceOutcome(trace, "env", result);
            return result;
        }
    }

    var paths: std.ArrayList([]const u8) = .empty;
    if (os == .macos) {
        if (env.home) |home| {
            try paths.append(arena, try std.Io.Dir.path.join(arena, &.{ home, "Library", "Application Support", vercel_dir, auth_file }));
        }
    }
    if (env.xdg_data_home) |xdg| {
        if (xdg.len != 0) {
            try paths.append(arena, try std.Io.Dir.path.join(arena, &.{ xdg, vercel_dir, auth_file }));
        }
    }
    if (env.home) |home| {
        try paths.append(arena, try std.Io.Dir.path.join(arena, &.{ home, ".local", "share", vercel_dir, auth_file }));
    }

    for (paths.items) |path| {
        switch (try files.read(files.context, arena, path)) {
            .absent => continue,
            .unreadable => {
                traceOutcome(trace, "auth file", .missing);
                return .missing;
            },
            .bytes => |bytes| {
                const result = try parseAuthJson(arena, bytes, now_unix_s);
                traceOutcome(trace, "auth file", result);
                return result;
            },
        }
    }
    traceOutcome(trace, "none", .missing);
    return .missing;
}

/// One trace line: the source and the outcome. Never the token or a path.
fn traceOutcome(trace: Trace, source: []const u8, result: AuthResult) void {
    var buffer: [128]u8 = undefined;
    const text = std.mem.print(&buffer, "vercel login: source {s}, result {s}", .{ source, @tagName(result) }) catch return;
    trace.write(text);
}

const FakeFiles = struct {
    entries: []const Entry,
    requested: [4][]const u8 = undefined,
    requested_count: usize = 0,

    const Entry = struct { path: []const u8, read: FileRead };

    fn read(context: ?*anyopaque, arena: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!FileRead {
        _ = arena;
        const self: *FakeFiles = @ptrCast(@alignCast(context.?));
        self.requested[self.requested_count] = path;
        self.requested_count += 1;
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.read;
        }
        return .absent;
    }

    fn files(self: *FakeFiles) Files {
        return .{ .context = self, .read = read };
    }
};

/// A trace sink that keeps every line, for tests that check what was written.
pub const CaptureTrace = struct {
    buffer: [2048]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,

    fn record(context: ?*anyopaque, text: []const u8) void {
        const self: *CaptureTrace = @ptrCast(@alignCast(context.?));
        if (self.len + text.len + 1 > self.buffer.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buffer[self.len..][0..text.len], text);
        self.len += text.len;
        self.buffer[self.len] = '\n';
        self.len += 1;
    }

    pub fn trace(self: *CaptureTrace) Trace {
        return .{ .context = self, .line = record };
    }

    pub fn captured(self: *const CaptureTrace) []const u8 {
        return self.buffer[0..self.len];
    }
};

const probe_token = "fx-leak-probe-7Q2";
const test_home = "/Users/example";
const test_now: i64 = 1_800_000_000;

test "parseAuthJson returns a token with a future expiry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try parseAuthJson(arena, "{\"token\":\"vca_fake_token\",\"expiresAt\":1800003600}", test_now);
    try std.testing.expectEqualStrings("vca_fake_token", result.token.bytes());
}

test "parseAuthJson with no expiresAt skips the expiry check" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try parseAuthJson(arena_state.allocator(), "{\"token\":\"vca_fake_token\"}", test_now);
    try std.testing.expectEqualStrings("vca_fake_token", result.token.bytes());
}

test "parseAuthJson expires a token at now plus the margin, and not one second later" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const at_margin = try parseAuthJson(arena, "{\"token\":\"vca_fake_token\",\"expiresAt\":1800000060}", test_now);
    try std.testing.expect(at_margin == .expired);
    const past_margin = try parseAuthJson(arena, "{\"token\":\"vca_fake_token\",\"expiresAt\":1800000061}", test_now);
    try std.testing.expect(past_margin == .token);
}

test "parseAuthJson refuses bad files as missing (E5)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const u8{
        "",
        "{",
        "[]",
        "null",
        "{\"token\":1}",
        "{\"token\":[\"vca\"]}",
        "{\"expiresAt\":1800003600}",
        "{\"token\":null}",
        "{\"token\":\"\"}",
        "{\"token\":\"vca fake\"}",
        "{\"token\":\"vca\\u000afake\"}",
        "{\"token\":\"vca_fake\",\"expiresAt\":\"1800003600\"}",
        "{\"token\":\"vca_fake\",\"expiresAt\":1.5}",
        "{\"token\":\"vca_fake\",\"expiresAt\":true}",
    };
    for (cases) |bytes| {
        const result = try parseAuthJson(arena, bytes, test_now);
        try std.testing.expect(result == .missing);
    }
}

test "parseAuthJson refuses a token longer than the cap and a file over the byte cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long_token = try arena.alloc(u8, max_token_bytes + 1);
    @memset(long_token, 'a');
    const long_file = try arena.print("{{\"token\":\"{s}\"}}", .{long_token});
    try std.testing.expect((try parseAuthJson(arena, long_file, test_now)) == .missing);

    const huge = try arena.alloc(u8, max_auth_file_bytes + 1);
    @memset(huge, ' ');
    try std.testing.expect((try parseAuthJson(arena, huge, test_now)) == .missing);
}

test "load: a set VERCEL_TOKEN wins and is never checked for expiry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake: FakeFiles = .{ .entries = &.{.{ .path = "/Users/example/.local/share/com.vercel.cli/auth.json", .read = .{ .bytes = "{\"token\":\"vca_file\",\"expiresAt\":1}" } }} };
    var capture: CaptureTrace = .{};
    const result = try load(arena_state.allocator(), .{ .vercel_token = "vca_env", .home = test_home }, .linux, fake.files(), capture.trace(), test_now);
    try std.testing.expectEqualStrings("vca_env", result.token.bytes());
    try std.testing.expectEqual(@as(usize, 0), fake.requested_count);
}

test "load: an empty VERCEL_TOKEN falls through to the files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake: FakeFiles = .{ .entries = &.{.{ .path = "/Users/example/.local/share/com.vercel.cli/auth.json", .read = .{ .bytes = "{\"token\":\"vca_file\"}" } }} };
    const result = try load(arena_state.allocator(), .{ .vercel_token = "", .home = test_home }, .linux, fake.files(), discard_trace, test_now);
    try std.testing.expectEqualStrings("vca_file", result.token.bytes());
}

test "load: the macOS path is tried first on macOS only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var mac: FakeFiles = .{ .entries = &.{.{ .path = "/Users/example/Library/Application Support/com.vercel.cli/auth.json", .read = .{ .bytes = "{\"token\":\"vca_mac\"}" } }} };
    const on_mac = try load(arena_state.allocator(), .{ .home = test_home }, .macos, mac.files(), discard_trace, test_now);
    try std.testing.expectEqualStrings("vca_mac", on_mac.token.bytes());

    var linux: FakeFiles = .{ .entries = &.{.{ .path = "/Users/example/Library/Application Support/com.vercel.cli/auth.json", .read = .{ .bytes = "{\"token\":\"vca_mac\"}" } }} };
    const off_mac = try load(arena_state.allocator(), .{ .home = test_home }, .linux, linux.files(), discard_trace, test_now);
    try std.testing.expect(off_mac == .missing);
    try std.testing.expectEqual(@as(usize, 1), linux.requested_count);
    try std.testing.expectEqualStrings("/Users/example/.local/share/com.vercel.cli/auth.json", linux.requested[0]);
}

test "load: the XDG path comes before ~/.local/share, and the first file that exists decides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake: FakeFiles = .{ .entries = &.{
        .{ .path = "/xdg/com.vercel.cli/auth.json", .read = .{ .bytes = "{\"token\":\"vca_xdg\",\"expiresAt\":1}" } },
        .{ .path = "/Users/example/.local/share/com.vercel.cli/auth.json", .read = .{ .bytes = "{\"token\":\"vca_share\"}" } },
    } };
    const result = try load(arena_state.allocator(), .{ .home = test_home, .xdg_data_home = "/xdg" }, .linux, fake.files(), discard_trace, test_now);
    try std.testing.expect(result == .expired);
    try std.testing.expectEqual(@as(usize, 1), fake.requested_count);
}

test "load: an unreadable file is missing, and no source at all is missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var broken: FakeFiles = .{ .entries = &.{.{ .path = "/Users/example/.local/share/com.vercel.cli/auth.json", .read = .unreadable }} };
    try std.testing.expect((try load(arena_state.allocator(), .{ .home = test_home }, .linux, broken.files(), discard_trace, test_now)) == .missing);

    var none: FakeFiles = .{ .entries = &.{} };
    try std.testing.expect((try load(arena_state.allocator(), .{}, .linux, none.files(), discard_trace, test_now)) == .missing);
    try std.testing.expectEqual(@as(usize, 0), none.requested_count);
}

test "a known token never reaches a trace line or a formatted print" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeFiles = .{ .entries = &.{} };
    var capture: CaptureTrace = .{};
    const result = try load(arena, .{ .vercel_token = probe_token, .home = test_home }, .linux, fake.files(), capture.trace(), test_now);
    try std.testing.expectEqualStrings(probe_token, result.token.bytes());
    try std.testing.expect(!capture.overflow);
    try std.testing.expect(std.mem.find(u8, capture.captured(), probe_token) == null);
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vercel login") != null);

    const as_any = try arena.print("{any}", .{result.token});
    const as_text = try arena.print("{f}", .{result.token});
    try std.testing.expectEqualStrings("Token(redacted)", as_text);
    try std.testing.expect(std.mem.find(u8, as_any, probe_token) == null);
}

test "disk reads an absolute auth file and refuses a relative path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "auth.json", .data = "{\"token\":\"vca_disk\"}" });
    const dir_path = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const path = try std.Io.Dir.path.join(arena, &.{ dir_path, "auth.json" });
    const read = try disk.read(null, arena, path);
    try std.testing.expectEqualStrings("{\"token\":\"vca_disk\"}", read.bytes);
    try std.testing.expect((try disk.read(null, arena, "relative/auth.json")) == .unreadable);
}

/// The fuzz oracle: the same rules, written again from the standard parser.
const Oracle = struct {
    token: []const u8,
    expires_at: ?i64,
};

fn oracleOf(arena: std.mem.Allocator, bytes: []const u8) ?Oracle {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    if (root != .object) return null;
    const token_value = root.object.get("token") orelse return null;
    const token = switch (token_value) {
        .string => |text| text,
        else => return null,
    };
    const expires_value = root.object.get("expiresAt") orelse .null;
    const expires_at: ?i64 = switch (expires_value) {
        .null => null,
        .integer => |value| value,
        else => return null,
    };
    return .{ .token = token, .expires_at = expires_at };
}

fn fuzzAuthJson(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, max_auth_file_bytes);
    const len = smith.slice(raw);
    const bytes = raw[0..len];
    const now = smith.value(i64);

    const result = try parseAuthJson(arena, bytes, now);
    const oracle = oracleOf(arena, bytes);
    switch (result) {
        .token => |token| {
            const file = oracle orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(file.token, token.bytes());
            if (file.expires_at) |expires_at| try std.testing.expect(expires_at > now +| expiry_margin_s);
        },
        .expired => {
            const file = oracle orelse return error.TestUnexpectedResult;
            const expires_at = file.expires_at orelse return error.TestUnexpectedResult;
            try std.testing.expect(expires_at <= now +| expiry_margin_s);
        },
        .missing => {
            const file = oracle orelse return;
            if (file.token.len == 0 or file.token.len > max_token_bytes) return;
            for (file.token) |byte| {
                if (byte < 0x21 or byte > 0x7e) return;
            }
            if (file.expires_at) |expires_at| {
                if (expires_at <= now +| expiry_margin_s) return;
            }
            return error.TestUnexpectedResult;
        },
    }
}

test "auth.json parses to one of three results, and a token equals its JSON string, on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzAuthJson, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"token\":\"vca_fake_example_token\",\"expiresAt\":1900000000}",
            "{\"token\":\"vca_fake_example_token\"}",
            "{\"token\":\"\"}",
            "{\"token\":1}",
            "{\"token\":\"vca_fake\",\"expiresAt\":\"1900000000\"}",
            "{\"token\":\"\\u0061bc\",\"expiresAt\":1900000000}",
            "[]",
            "",
        }) ++ @import("fuzz_corpus").vercel_auth_json.*),
    });
}
