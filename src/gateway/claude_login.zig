//! Whether the installed Claude Code is signed in, for `/login anthropic`
//! (D184). It runs `claude auth status --json` with the same isolation as a
//! model request, a private config directory and the user's own login, so
//! it reports exactly the login a request would use.
const std = @import("std");
const builtin = @import("builtin");
const agent = @import("claude_agent.zig");
const executable = @import("claude_executable.zig");
const io_mod = @import("../core/shared/io.zig");
const Allocator = std.mem.Allocator;

const timeout_ms = 20_000;
const max_output_bytes = 64 * 1024;

pub const SignedIn = struct {
    /// Claude Code's `authMethod`, such as `claude.ai`. Owned.
    method: []u8,
    /// The plan, such as `max`, when Claude Code reports one. Owned.
    subscription: ?[]u8 = null,
    email: ?[]u8 = null,
};

pub const Status = union(enum) {
    not_installed,
    /// `PROTO_FX_CLAUDE_EXECUTABLE` or `PI_CLAUDE_EXECUTABLE` names no
    /// executable file.
    override_invalid,
    signed_out,
    signed_in: SignedIn,
    /// The check ran but said nothing usable. Owned detail.
    unknown: []u8,

    pub fn deinit(self: *Status, alloc: Allocator) void {
        switch (self.*) {
            .signed_in => |value| {
                alloc.free(value.method);
                if (value.subscription) |text| alloc.free(text);
                if (value.email) |text| alloc.free(text);
            },
            .unknown => |detail| alloc.free(detail),
            else => {},
        }
        self.* = undefined;
    }
};

/// Reads `claude auth status --json` output.
pub fn parse(alloc: Allocator, output: []const u8) !Status {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, output, .{}) catch
        return .{ .unknown = try alloc.dupe(u8, "Claude Code's auth status was not JSON.") };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .unknown = try alloc.dupe(u8, "Claude Code's auth status was not an object.") };
    const object = parsed.value.object;
    const logged_in = object.get("loggedIn") orelse return .{ .unknown = try alloc.dupe(u8, "Claude Code's auth status has no loggedIn field.") };
    if (logged_in != .bool) return .{ .unknown = try alloc.dupe(u8, "Claude Code's auth status has no loggedIn field.") };
    if (!logged_in.bool) return .signed_out;
    const method = try alloc.dupe(u8, stringField(object, "authMethod") orelse "claude.ai");
    errdefer alloc.free(method);
    const subscription = if (stringField(object, "subscriptionType")) |text| try alloc.dupe(u8, text) else null;
    errdefer if (subscription) |text| alloc.free(text);
    const email = if (stringField(object, "email")) |text| try alloc.dupe(u8, text) else null;
    return .{ .signed_in = .{ .method = method, .subscription = subscription, .email = email } };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

/// Checks the installed Claude Code in the current environment.
pub fn check(alloc: Allocator) !Status {
    if (comptime builtin.target.os.tag == .windows or builtin.target.cpu.arch.isWasm()) return .not_installed;
    const exe = executable.find(alloc, .current()) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .override_invalid,
    } orelse return .not_installed;
    defer alloc.free(exe);
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    var env = try io_mod.cloneEnvironMap(arena_state.allocator());
    defer env.deinit();
    return checkWith(alloc, exe, &env);
}

/// Runs `exe auth status --json` with `base_env` isolated as a model request
/// would be. The private config directory is removed before returning.
pub fn checkWith(alloc: Allocator, exe: []const u8, base_env: *std.process.Environ.Map) !Status {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch = try agent.Scratch.create(arena);
    defer scratch.remove();
    try agent.isolateEnvironment(arena, base_env, try std.Io.Dir.path.join(arena, &.{ scratch.path, "config" }), null);
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = &.{ exe, "auth", "status", "--json" },
        .cwd = .{ .path = scratch.path },
        .environ_map = base_env,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |err| return .{ .unknown = try alloc.print("Could not run {s} auth status: {s}", .{ exe, @errorName(err) }) };
    return parse(alloc, result.stdout);
}

/// What `/login anthropic` tells the user about `status`. Caller owns it.
pub fn describe(alloc: Allocator, status: Status) ![]u8 {
    return switch (status) {
        .signed_in => |value| alloc.print("Using your Claude Code login ({s}{s}{s}{s}{s}). proto-fx runs Claude through it with your settings, hooks, plugins and CLAUDE.md left out.", .{
            value.email orelse value.method,
            if (value.subscription != null) " \u{00b7} " else "",
            value.subscription orelse "",
            if (value.email != null) " \u{00b7} " else "",
            if (value.email != null) value.method else "",
        }),
        .signed_out => alloc.dupe(u8, "Claude Code is installed but not signed in. Run `claude auth login`, then /login anthropic again. Or choose claude-token to paste a `claude setup-token` token, or api-key for an Anthropic API key."),
        .not_installed => alloc.dupe(u8, "Claude Code is not installed. Install it from https://claude.com/claude-code (or set " ++ executable.override_env ++ " to its path), sign in with `claude auth login`, then /login anthropic again. Or choose api-key for an Anthropic API key."),
        .override_invalid => alloc.dupe(u8, executable.override_env ++ " or " ++ executable.proto_override_env ++ " does not name an executable file. Fix it, then /login anthropic again."),
        .unknown => |detail| alloc.print("Could not tell whether Claude Code is signed in: {s} Run `claude auth status` to check, or choose claude-token or api-key.", .{detail}),
    };
}

test "auth status output parses into signed in, signed out or unknown" {
    const alloc = std.testing.allocator;
    var in = try parse(alloc, "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"email\":null,\"subscriptionType\":\"max\"}");
    defer in.deinit(alloc);
    try std.testing.expectEqualStrings("claude.ai", in.signed_in.method);
    try std.testing.expectEqualStrings("max", in.signed_in.subscription.?);
    try std.testing.expect(in.signed_in.email == null);
    const text = try describe(alloc, in);
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "Using your Claude Code login (claude.ai \u{00b7} max)."));
    var out = try parse(alloc, "{\"loggedIn\":false,\"authMethod\":\"none\"}");
    defer out.deinit(alloc);
    try std.testing.expect(out == .signed_out);
    var junk = try parse(alloc, "Not logged in.");
    defer junk.deinit(alloc);
    try std.testing.expect(junk == .unknown);
}

test "the status check runs the executable with the user's login and a private config directory" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const record = try std.Io.Dir.path.join(alloc, &.{ root, "record.txt" });
    defer alloc.free(record);
    const script = try alloc.print(
        \\#!/bin/sh
        \\{{ echo "argv=$*"; echo "config=$CLAUDE_CONFIG_DIR"; echo "secure=${{CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}}"; echo "key=${{ANTHROPIC_API_KEY-unset}}"; echo "nested=${{CLAUDECODE-unset}}"; }} > "{s}"
        \\echo '{{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro"}}'
        \\
    , .{record});
    defer alloc.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "claude", .data = script, .flags = .{ .permissions = .fromMode(0o755) } });
    const exe = try std.Io.Dir.path.join(alloc, &.{ root, "claude" });
    defer alloc.free(exe);

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("ANTHROPIC_API_KEY", "");
    try env.put("CLAUDECODE", "1");
    var status = try checkWith(alloc, exe, &env);
    defer status.deinit(alloc);
    try std.testing.expectEqualStrings("pro", status.signed_in.subscription.?);

    var file = try tmp.dir.openFile(io, "record.txt", .{});
    defer file.close(io);
    const recorded = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(recorded);
    try std.testing.expect(std.mem.find(u8, recorded, "argv=auth status --json\n") != null);
    // The login of the default ~/.claude, everything written somewhere private.
    try std.testing.expect(std.mem.find(u8, recorded, "secure=\n") != null);
    try std.testing.expect(std.mem.find(u8, recorded, "/proto-fx-claude-") != null);
    try std.testing.expect(std.mem.find(u8, recorded, "key=unset\n") != null);
    try std.testing.expect(std.mem.find(u8, recorded, "nested=unset\n") != null);
}
