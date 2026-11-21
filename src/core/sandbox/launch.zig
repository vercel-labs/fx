//! The provider launch for one placed shell command. The provider runs the
//! command in a sandbox and returns its output and exit status. This module
//! builds the one POSIX shell string that starts it. It is pure: no I/O and no
//! clock.
const std = @import("std");
const command_environment = @import("../execution/command_environment.zig");
const command_lex = @import("../shell_command/command_lex.zig");

/// Extra provider arguments for isolated runs with one profile name.
pub const Profile = struct {
    name: []const u8,
    args: []const []const u8,
};

/// What the provider needs to start one placed run. The strings are borrowed
/// for the calls that use them.
pub const Launch = struct {
    /// The provider program and its first arguments.
    provider: []const []const u8,
    /// Passed to the provider before its subcommand.
    provider_args: []const []const u8 = &.{},
    /// The provider's state folder.
    state_dir: []const u8,
    /// The workspace root that workspace runs mirror.
    workspace_root: []const u8,
    /// Variables passed to workspace runs.
    env: []const []const u8 = &.{},
    /// Extra provider arguments for isolated runs, by profile name.
    profiles: []const Profile = &.{},
    /// How long the provider waits after SIGTERM before SIGKILL.
    grace_ms: u32,
};

pub const InvocationError = error{ LocalPlacement, UnknownProfile } || std.mem.Allocator.Error;

const default_profile_name = "default";

/// The one POSIX shell string that runs `command` through the provider in
/// `cwd`. `exec` is the only word left bare. Every other word is quoted by
/// `command_lex.quoteWord`, which leaves a word bare only when it is safe as
/// it is. The caller owns the result, which is allocated with `alloc` and freed
/// with it. The quoted words are built in a scratch arena, which is freed before
/// this returns, so only the result outlives the call.
///
/// A workspace run passes `--env` for each name in `launch.env`. An isolated
/// run passes `--profile` with the profile's arguments, and `default` when
/// `profile` is null. A profile other than `default` must be in
/// `launch.profiles`. A local command has no provider, so it is an error.
pub fn invocation(
    alloc: std.mem.Allocator,
    launch: *const Launch,
    command: []const u8,
    cwd: []const u8,
    placement: command_environment.Placement,
    profile: ?[]const u8,
) InvocationError![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const text = try buildInvocation(scratch.allocator(), launch, command, cwd, placement, profile);
    return alloc.dupe(u8, text);
}

/// Builds the invocation text in `arena`, which the caller frees.
fn buildInvocation(
    arena: std.mem.Allocator,
    launch: *const Launch,
    command: []const u8,
    cwd: []const u8,
    placement: command_environment.Placement,
    profile: ?[]const u8,
) InvocationError![]const u8 {
    const mode: []const u8 = switch (placement) {
        .local => return error.LocalPlacement,
        .workspace => "workspace",
        .isolated => "isolated",
    };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "exec");
    for (launch.provider) |word| try appendWord(arena, &out, word);
    for (launch.provider_args) |word| try appendWord(arena, &out, word);
    const run_words = [_][]const u8{
        "run",
        "--mode",
        mode,
        "--root",
        launch.workspace_root,
        "--cwd",
        cwd,
        "--state",
        launch.state_dir,
    };
    for (run_words) |word| try appendWord(arena, &out, word);
    if (placement == .workspace) {
        for (launch.env) |name| {
            try appendWord(arena, &out, "--env");
            try appendWord(arena, &out, name);
        }
    } else {
        const name = profile orelse default_profile_name;
        try appendWord(arena, &out, "--profile");
        try appendWord(arena, &out, name);
        for (try profileArgs(launch, name)) |word| try appendWord(arena, &out, word);
    }
    try appendWord(arena, &out, "--");
    try appendWord(arena, &out, command);
    return out.toOwnedSlice(arena);
}

/// Appends `word` after a space, as one shell word.
fn appendWord(arena: std.mem.Allocator, out: *std.ArrayList(u8), word: []const u8) !void {
    try out.append(arena, ' ');
    try out.appendSlice(arena, try command_lex.quoteWord(arena, word));
}

/// The extra arguments for `name`. `default` needs no entry in `profiles`. Any
/// other name must have one.
fn profileArgs(launch: *const Launch, name: []const u8) error{UnknownProfile}![]const []const u8 {
    for (launch.profiles) |profile| {
        if (std.mem.eql(u8, profile.name, name)) return profile.args;
    }
    if (std.mem.eql(u8, name, default_profile_name)) return &.{};
    return error.UnknownProfile;
}

const testing = std.testing;

const test_provider = [_][]const u8{"/opt/fx/vercel.sh"};
const test_provider_args = [_][]const u8{ "--scope", "team" };
const test_env = [_][]const u8{ "CI_TOKEN_1", "PATH" };
const media_args = [_][]const u8{"--gpu"};
const test_profiles = [_]Profile{.{ .name = "media", .args = &media_args }};
const test_launch: Launch = .{
    .provider = &test_provider,
    .provider_args = &test_provider_args,
    .state_dir = "/Users/example/.fx/sandbox/state",
    .workspace_root = "/Users/example/repo",
    .env = &test_env,
    .profiles = &test_profiles,
    .grace_ms = 5000,
};

test "workspace invocation names the provider, folders, and env" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try invocation(
        arena_state.allocator(),
        &test_launch,
        "zig build test",
        "/Users/example/repo/app",
        .workspace,
        null,
    );
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode workspace --root /Users/example/repo " ++
            "--cwd /Users/example/repo/app --state /Users/example/.fx/sandbox/state " ++
            "--env CI_TOKEN_1 --env PATH -- 'zig build test'",
        text,
    );
}

test "isolated invocation names the profile arguments and passes no env" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const media = try invocation(arena, &test_launch, "convert a b", "/Users/example/repo", .isolated, "media");
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode isolated --root /Users/example/repo " ++
            "--cwd /Users/example/repo --state /Users/example/.fx/sandbox/state " ++
            "--profile media --gpu -- 'convert a b'",
        media,
    );
    try testing.expect(std.mem.find(u8, media, "--env") == null);

    const default = try invocation(arena, &test_launch, "ls", "/Users/example/repo", .isolated, null);
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode isolated --root /Users/example/repo " ++
            "--cwd /Users/example/repo --state /Users/example/.fx/sandbox/state " ++
            "--profile default -- ls",
        default,
    );
}

test "invocation refuses a local placement and an undefined profile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(
        error.LocalPlacement,
        invocation(arena, &test_launch, "ls", "/Users/example/repo", .local, null),
    );
    try testing.expectError(
        error.UnknownProfile,
        invocation(arena, &test_launch, "ls", "/Users/example/repo", .isolated, "open"),
    );
}

test "invocation quotes a command with quotes, dollars, spaces, and newlines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try invocation(
        arena_state.allocator(),
        &test_launch,
        "printf '%s' $HOME\nls it's",
        "/Users/example/repo",
        .isolated,
        null,
    );
    // Each `'` becomes `'\''`, and the newline stays inside the quotes.
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode isolated --root /Users/example/repo " ++
            "--cwd /Users/example/repo --state /Users/example/.fx/sandbox/state " ++
            "--profile default -- 'printf '\\''%s'\\'' $HOME\nls it'\\''s'",
        text,
    );
}

test "the provider receives each word and the quoted command unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The provider is a shell that prints each argument in brackets, so the
    // output shows every word exactly as the provider received it.
    const provider = [_][]const u8{
        "/bin/sh",
        "-c",
        "for a; do printf '[%s]\\n' \"$a\"; done",
        "fx-provider",
    };
    const launch: Launch = .{
        .provider = &provider,
        .state_dir = "/w/state",
        .workspace_root = "/w/repo",
        .grace_ms = 1000,
    };
    const text = try invocation(
        arena,
        &launch,
        "printf '%s' $HOME\nls it's",
        "/w/repo",
        .workspace,
        null,
    );
    const result = try std.process.run(arena, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", text },
    });
    try testing.expectEqualStrings(
        "[run]\n[--mode]\n[workspace]\n[--root]\n[/w/repo]\n[--cwd]\n[/w/repo]\n" ++
            "[--state]\n[/w/state]\n[--]\n[printf '%s' $HOME\nls it's]\n",
        result.stdout,
    );
}

test "invocation under the caller's allocator frees its quoted words" {
    // std.testing.allocator fails this test if a quoted word outlives the call.
    const text = try invocation(
        testing.allocator,
        &test_launch,
        "printf '%s' $HOME",
        "/Users/example/repo",
        .workspace,
        null,
    );
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode workspace --root /Users/example/repo " ++
            "--cwd /Users/example/repo --state /Users/example/.fx/sandbox/state " ++
            "--env CI_TOKEN_1 --env PATH -- 'printf '\\''%s'\\'' $HOME'",
        text,
    );
}

test "invocation under the caller's allocator frees the isolated profile words" {
    const text = try invocation(
        testing.allocator,
        &test_launch,
        "convert a b",
        "/Users/example/repo",
        .isolated,
        "media",
    );
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode isolated --root /Users/example/repo " ++
            "--cwd /Users/example/repo --state /Users/example/.fx/sandbox/state " ++
            "--profile media --gpu -- 'convert a b'",
        text,
    );
}
