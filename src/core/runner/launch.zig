//! The launch of one placed shell command. It is the one POSIX shell string that starts the
//! runner as a local command (spec L3): `exec` of the quoted argv, run by `/bin/sh -c`. A
//! built-in run takes the L1 values, and a third-party provider takes the L2 values. This
//! module is pure: no I/O and no clock.
const std = @import("std");
const command_environment = @import("../execution/command_environment.zig");
const command_lex = @import("../shell_command/command_lex.zig");
const runner_main = @import("runner_main.zig");

/// Extra provider arguments for isolated runs with one profile name.
pub const Profile = struct {
    name: []const u8,
    args: []const []const u8,
};

/// The L1 values of the built-in runner. The host passes the values it loaded, so the
/// runner never reads the config file. The login token itself never goes in the launch:
/// only its SHA-256 hex does.
pub const Builtin = struct {
    team_id: []const u8,
    team_slug: []const u8,
    project_id: []const u8,
    project_name: []const u8,
    user_id: []const u8,
    token_sha256: []const u8,
    include: []const []const u8 = &.{},
    bring_back: []const []const u8 = &.{},
    vcpus: ?u8 = null,
};

/// What the provider needs to start one placed run. The strings are borrowed
/// for the calls that use them.
pub const Launch = struct {
    /// The provider program and its first arguments. The built-in runner's argv
    /// is `fx __fx_runner__`.
    provider: []const []const u8,
    /// Passed to the provider before its subcommand. A third-party provider only.
    provider_args: []const []const u8 = &.{},
    /// The state folder. A built-in run gets its keyed folder (spec L5).
    state_dir: []const u8,
    /// The workspace root that remote runs mirror.
    workspace_root: []const u8,
    /// Variables passed to remote runs.
    env: []const []const u8 = &.{},
    /// Extra provider arguments for isolated runs, by profile name.
    profiles: []const Profile = &.{},
    /// How long the provider waits after SIGTERM before SIGKILL.
    grace_ms: u32,
    /// Set for the built-in runner (L1). Null for a third-party provider (L2).
    builtin: ?Builtin = null,
};

pub const InvocationError = error{ LocalPlacement, UnknownProfile } || std.mem.Allocator.Error;

const default_profile_name = "default";

/// The one POSIX shell string that runs `command` through the runner in `cwd`. `exec` is the
/// only word left bare. Every other word is quoted by `command_lex.quoteWord`, which leaves a
/// word bare only when it is safe as it is. The caller owns the result, which is allocated with
/// `alloc` and freed with it. The quoted words are built in a scratch arena, which is freed
/// before this returns, so only the result outlives the call.
///
/// `timeout_ms` is the call's own timeout. It is passed to the built-in runner only (L1).
/// A remote run passes `--env` for each name in `launch.env`. An isolated run passes `--profile`
/// with the profile's arguments, and `default` when `profile` is null. A profile other than
/// `default` must be in `launch.profiles`. A local command has no runner, so it is an error.
pub fn invocation(
    alloc: std.mem.Allocator,
    launch: *const Launch,
    command: []const u8,
    cwd: []const u8,
    placement: command_environment.Placement,
    profile: ?[]const u8,
    timeout_ms: ?usize,
) InvocationError![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const text = try buildInvocation(scratch.allocator(), launch, command, cwd, placement, profile, timeout_ms);
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
    timeout_ms: ?usize,
) InvocationError![]const u8 {
    const mode: []const u8 = switch (placement) {
        .local => return error.LocalPlacement,
        .remote => "remote",
        .isolated => "isolated",
    };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "exec");
    for (launch.provider) |word| try appendWord(arena, &out, word);
    if (launch.builtin) |builtin| {
        try appendWords(arena, &out, &.{ "run", "--contract", runner_main.contract_version });
        try appendWords(arena, &out, &.{ "--mode", mode, "--root", launch.workspace_root, "--cwd", cwd, "--state", launch.state_dir });
        try appendPair(arena, &out, "--team", builtin.team_id);
        try appendPair(arena, &out, "--project", builtin.project_id);
        try appendPair(arena, &out, "--token-sha256", builtin.token_sha256);
        try appendPair(arena, &out, "--team-slug", builtin.team_slug);
        try appendPair(arena, &out, "--project-name", builtin.project_name);
        try appendPair(arena, &out, "--user-id", builtin.user_id);
        try appendPair(arena, &out, "--grace-ms", try arena.print("{d}", .{launch.grace_ms}));
        if (timeout_ms) |value| try appendPair(arena, &out, "--timeout-ms", try arena.print("{d}", .{value}));
        for (builtin.include) |path| try appendPair(arena, &out, "--include", path);
        for (builtin.bring_back) |path| try appendPair(arena, &out, "--bring-back", path);
        if (builtin.vcpus) |count| try appendPair(arena, &out, "--vcpus", try arena.print("{d}", .{count}));
    } else {
        for (launch.provider_args) |word| try appendWord(arena, &out, word);
        try appendWords(arena, &out, &.{ "run", "--mode", mode, "--root", launch.workspace_root, "--cwd", cwd, "--state", launch.state_dir });
    }
    if (placement == .remote) {
        for (launch.env) |name| try appendPair(arena, &out, "--env", name);
    } else {
        const name = profile orelse default_profile_name;
        try appendPair(arena, &out, "--profile", name);
        for (try profileArgs(launch, name)) |word| try appendWord(arena, &out, word);
    }
    try appendWord(arena, &out, "--");
    try appendWord(arena, &out, command);
    return out.toOwnedSlice(arena);
}

/// A deep copy that owns its strings, so it outlives the arena that built the
/// source. Every field is copied here, so a new field cannot be dropped by a copy.
pub fn duplicate(source: *const Launch, alloc: std.mem.Allocator) std.mem.Allocator.Error!Launch {
    return .{
        .provider = try dupeStrings(alloc, source.provider),
        .provider_args = try dupeStrings(alloc, source.provider_args),
        .state_dir = try alloc.dupe(u8, source.state_dir),
        .workspace_root = try alloc.dupe(u8, source.workspace_root),
        .env = try dupeStrings(alloc, source.env),
        .profiles = try dupeProfiles(alloc, source.profiles),
        .grace_ms = source.grace_ms,
        .builtin = if (source.builtin) |value| try dupeBuiltin(alloc, value) else null,
    };
}

fn dupeStrings(alloc: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const out = try alloc.alloc([]const u8, items.len);
    for (items, out) |item, *slot| slot.* = try alloc.dupe(u8, item);
    return out;
}

fn dupeProfiles(alloc: std.mem.Allocator, items: []const Profile) std.mem.Allocator.Error![]const Profile {
    const out = try alloc.alloc(Profile, items.len);
    for (items, out) |item, *slot| {
        slot.* = .{ .name = try alloc.dupe(u8, item.name), .args = try dupeStrings(alloc, item.args) };
    }
    return out;
}

fn dupeBuiltin(alloc: std.mem.Allocator, value: Builtin) std.mem.Allocator.Error!Builtin {
    return .{
        .team_id = try alloc.dupe(u8, value.team_id),
        .team_slug = try alloc.dupe(u8, value.team_slug),
        .project_id = try alloc.dupe(u8, value.project_id),
        .project_name = try alloc.dupe(u8, value.project_name),
        .user_id = try alloc.dupe(u8, value.user_id),
        .token_sha256 = try alloc.dupe(u8, value.token_sha256),
        .include = try dupeStrings(alloc, value.include),
        .bring_back = try dupeStrings(alloc, value.bring_back),
        .vcpus = value.vcpus,
    };
}

/// Appends `word` after a space, as one shell word.
fn appendWord(arena: std.mem.Allocator, out: *std.ArrayList(u8), word: []const u8) !void {
    try out.append(arena, ' ');
    try out.appendSlice(arena, try command_lex.quoteWord(arena, word));
}

fn appendWords(arena: std.mem.Allocator, out: *std.ArrayList(u8), words: []const []const u8) !void {
    for (words) |word| try appendWord(arena, out, word);
}

fn appendPair(arena: std.mem.Allocator, out: *std.ArrayList(u8), flag: []const u8, value: []const u8) !void {
    try appendWord(arena, out, flag);
    try appendWord(arena, out, value);
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

const test_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const test_include = [_][]const u8{"vendor"};
const test_bring_back = [_][]const u8{"zig-out/bin"};
const builtin_launch: Launch = .{
    .provider = &.{ "/usr/local/bin/fx", "__fx_runner__" },
    .state_dir = "/Users/example/.fx/sandbox/state/0123456789abcdef",
    .workspace_root = "/Users/example/repo",
    .env = &test_env,
    .profiles = &test_profiles,
    .grace_ms = 5000,
    .builtin = .{
        .team_id = "team_1",
        .team_slug = "acme",
        .project_id = "prj_1",
        .project_name = "repo",
        .user_id = "usr_1",
        .token_sha256 = test_digest,
        .include = &test_include,
        .bring_back = &test_bring_back,
        .vcpus = 4,
    },
};

test "remote invocation names the provider, folders, and env" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try invocation(
        arena_state.allocator(),
        &test_launch,
        "zig build test",
        "/Users/example/repo/app",
        .remote,
        null,
        null,
    );
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode remote --root /Users/example/repo " ++
            "--cwd /Users/example/repo/app --state /Users/example/.fx/sandbox/state " ++
            "--env CI_TOKEN_1 --env PATH -- 'zig build test'",
        text,
    );
}

test "isolated invocation names the profile arguments and passes no env" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const media = try invocation(arena, &test_launch, "convert a b", "/Users/example/repo", .isolated, "media", null);
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode isolated --root /Users/example/repo " ++
            "--cwd /Users/example/repo --state /Users/example/.fx/sandbox/state " ++
            "--profile media --gpu -- 'convert a b'",
        media,
    );
    try testing.expect(std.mem.find(u8, media, "--env") == null);

    const default = try invocation(arena, &test_launch, "ls", "/Users/example/repo", .isolated, null, null);
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode isolated --root /Users/example/repo " ++
            "--cwd /Users/example/repo --state /Users/example/.fx/sandbox/state " ++
            "--profile default -- ls",
        default,
    );
}

test "built-in invocation runs fx __fx_runner__ with the L1 values, and the token only as its hash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try invocation(
        arena_state.allocator(),
        &builtin_launch,
        "zig build test",
        "/Users/example/repo/app",
        .remote,
        null,
        600_000,
    );
    try testing.expectEqualStrings(
        "exec /usr/local/bin/fx __fx_runner__ run --contract 1 --mode remote --root /Users/example/repo " ++
            "--cwd /Users/example/repo/app --state /Users/example/.fx/sandbox/state/0123456789abcdef " ++
            "--team team_1 --project prj_1 --token-sha256 " ++ test_digest ++ " --team-slug acme " ++
            "--project-name repo --user-id usr_1 --grace-ms 5000 --timeout-ms 600000 --include vendor " ++
            "--bring-back zig-out/bin --vcpus 4 --env CI_TOKEN_1 --env PATH -- 'zig build test'",
        text,
    );
}

test "built-in isolated invocation adds the profile after the L1 values and passes no env" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try invocation(
        arena_state.allocator(),
        &builtin_launch,
        "convert a b",
        "/Users/example/repo",
        .isolated,
        "media",
        null,
    );
    try testing.expect(std.mem.find(u8, text, "--timeout-ms") == null);
    try testing.expect(std.mem.endsWith(u8, text, "--vcpus 4 --profile media --gpu -- 'convert a b'"));
    try testing.expect(std.mem.find(u8, text, "--env") == null);
}

test "a third-party provider keeps the L2 argv: no contract, team, project or token" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = try invocation(arena_state.allocator(), &test_launch, "ls", "/Users/example/repo", .remote, null, 600_000);
    try testing.expect(std.mem.find(u8, text, "--contract") == null);
    try testing.expect(std.mem.find(u8, text, "--team") == null);
    try testing.expect(std.mem.find(u8, text, "--token-sha256") == null);
    try testing.expect(std.mem.find(u8, text, "--timeout-ms") == null);
}

test "invocation refuses a local placement and an undefined profile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(
        error.LocalPlacement,
        invocation(arena, &test_launch, "ls", "/Users/example/repo", .local, null, null),
    );
    try testing.expectError(
        error.UnknownProfile,
        invocation(arena, &test_launch, "ls", "/Users/example/repo", .isolated, "open", null),
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
        .remote,
        null,
        null,
    );
    const result = try std.process.run(arena, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", text },
    });
    try testing.expectEqualStrings(
        "[run]\n[--mode]\n[remote]\n[--root]\n[/w/repo]\n[--cwd]\n[/w/repo]\n" ++
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
        .remote,
        null,
        null,
    );
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode remote --root /Users/example/repo " ++
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
        null,
    );
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        "exec /opt/fx/vercel.sh --scope team run --mode isolated --root /Users/example/repo " ++
            "--cwd /Users/example/repo --state /Users/example/.fx/sandbox/state " ++
            "--profile media --gpu -- 'convert a b'",
        text,
    );
}

test "a duplicate keeps every built-in value and invokes the same way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const copy = try duplicate(&builtin_launch, arena);
    const built = copy.builtin orelse return error.TestExpectedBuiltin;
    try testing.expectEqualStrings("team_1", built.team_id);
    try testing.expectEqualStrings(test_digest, built.token_sha256);
    try testing.expectEqualStrings("vendor", built.include[0]);
    try testing.expectEqual(@as(?u8, 4), built.vcpus);
    try testing.expectEqualStrings(
        try invocation(arena, &builtin_launch, "ls", "/Users/example/repo", .remote, null, null),
        try invocation(arena, &copy, "ls", "/Users/example/repo", .remote, null, null),
    );
}
