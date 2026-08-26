const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const command_environment = @import("../execution/command_environment.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const ResolveError = error{
    MissingLoginShell,
    RelativeShellPath,
    UnsupportedShell,
};

pub const Profile = command_environment.Profile;
pub const Environment = command_environment.Environment;

const ShellKind = enum { bash, zsh };

fn shellKind(path: []const u8) ?ShellKind {
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    return null;
}

fn shellIsExecutable(path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io_mod.getIo(), path, .{}) catch return false;
    if (stat.kind != .file) return false;
    cwd.access(io_mod.getIo(), path, .{ .execute = true }) catch return false;
    return true;
}

fn firstExecutableShell(candidates: []const []const u8) ?[]const u8 {
    for (candidates) |candidate| {
        if (shellIsExecutable(candidate)) return candidate;
    }
    return null;
}

/// Platform-ordered fallback shells, filtered to executable regular files so a
/// missing interpreter surfaces as MissingLoginShell instead of a later
/// spawn failure.
fn fallbackLoginShell() ?[]const u8 {
    const candidates: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "/bin/zsh", "/bin/bash" }
    else
        &.{ "/bin/bash", "/bin/zsh" };
    return firstExecutableShell(candidates);
}

fn supportedLoginShell(configured_login_shell: ?[]const u8) ResolveError![]const u8 {
    const path = configured_login_shell orelse
        return fallbackLoginShell() orelse error.MissingLoginShell;
    if (!std.fs.path.isAbsolute(path)) return error.RelativeShellPath;
    if (shellKind(path) != null and shellIsExecutable(path)) return path;
    return fallbackLoginShell() orelse error.MissingLoginShell;
}

pub const Invocation = struct {
    path: []const u8,
    values: [6][]const u8 = @splat(""),
    len: usize = 0,

    pub fn argv(self: *const Invocation) []const []const u8 {
        return self.values[0..self.len];
    }

    fn append(self: *Invocation, value: []const u8) void {
        self.values[self.len] = value;
        self.len += 1;
    }

    pub fn setCommand(self: *Invocation, command: []const u8) void {
        self.append("-c");
        self.append(command);
    }
};

pub fn resolve(
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) ResolveError!Invocation {
    const Selection = struct {
        path: []const u8,
        clean_start: bool,
    };
    const selection: Selection = switch (shell) {
        .user_login => .{
            .path = try supportedLoginShell(configured_login_shell),
            .clean_start = false,
        },
        .executable => |value| .{
            .path = value.path,
            .clean_start = value.clean_start,
        },
    };
    if (!std.fs.path.isAbsolute(selection.path)) {
        return error.RelativeShellPath;
    }

    const kind = shellKind(selection.path) orelse return error.UnsupportedShell;

    var result = Invocation{ .path = selection.path };
    result.append(selection.path);
    switch (kind) {
        .bash => {
            if (selection.clean_start) {
                result.append("--noprofile");
                result.append("--norc");
            } else {
                result.append("--login");
            }
            result.append("-i");
        },
        .zsh => {
            if (selection.clean_start) {
                result.append("-f");
            } else {
                result.append("-l");
            }
            result.append("-i");
        },
    }
    return result;
}

const PasswdLoginShell = union(enum) {
    missing_entry,
    unavailable,
    shell: []const u8,
};

/// Login shell for the current uid. A passwd entry is authoritative; SHELL is
/// consulted only when the uid has no passwd entry, as is common in hardened
/// containers started with an arbitrary --user value.
pub fn configuredLoginShellInto(buffer: []u8) ?[]const u8 {
    return configuredLoginShellFromSources(
        passwdLoginShellInto(buffer),
        io_mod.getenv("SHELL"),
        buffer,
    );
}

fn configuredLoginShellFromSources(
    passwd: PasswdLoginShell,
    shell_env: ?[]const u8,
    buffer: []u8,
) ?[]const u8 {
    return switch (passwd) {
        .shell => |shell| shell,
        .unavailable => null,
        .missing_entry => validatedShellValue(shell_env, buffer),
    };
}

fn passwdLoginShellInto(buffer: []u8) PasswdLoginShell {
    if (comptime !builtin.link_libc or builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .unavailable;
    }
    var entry: std.c.passwd = undefined;
    var scratch: [4096]u8 = undefined;
    var found: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(
        std.c.getuid(),
        &entry,
        &scratch,
        scratch.len,
        &found,
    ) != 0) return .unavailable;
    const record = found orelse return .missing_entry;
    const shell_ptr = record.shell orelse return .unavailable;
    const shell = std.mem.span(shell_ptr);
    if (shell.len == 0 or shell.len > buffer.len) return .unavailable;
    @memcpy(buffer[0..shell.len], shell);
    return .{ .shell = buffer[0..shell.len] };
}

fn validatedShellValue(value: ?[]const u8, buffer: []u8) ?[]const u8 {
    const shell = value orelse return null;
    if (shell.len == 0 or shell.len > buffer.len) return null;
    if (!std.fs.path.isAbsolute(shell) or !shellIsExecutable(shell)) return null;
    @memcpy(buffer[0..shell.len], shell);
    return buffer[0..shell.len];
}

pub fn environment(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: ?Profile,
) (ResolveError || Allocator.Error)!Environment {
    const selected = profile orelse .user;
    const path = try supportedLoginShell(configured_login_shell);
    _ = try resolve(null, switch (selected) {
        .clean => .{ .executable = .{ .path = path, .clean_start = true } },
        .user => .{ .executable = .{ .path = path } },
    });
    return switch (selected) {
        .clean => .{ .clean = try alloc.dupe(u8, path) },
        .user => .{ .user = try alloc.dupe(u8, path) },
    };
}

pub fn profileShell(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: Profile,
) (ResolveError || Allocator.Error)!contracts.ShellSpec {
    return switch (profile) {
        .clean => blk: {
            const path = try supportedLoginShell(configured_login_shell);
            _ = try resolve(null, .{ .executable = .{ .path = path, .clean_start = true } });
            break :blk .{ .executable = .{
                .path = try alloc.dupe(u8, path),
                .clean_start = true,
            } };
        },
        .user => blk: {
            const configured = configured_login_shell orelse
                break :blk .user_login;
            const path = try supportedLoginShell(configured);
            if (std.mem.eql(u8, path, configured)) break :blk .user_login;
            break :blk .{ .executable = .{
                .path = try alloc.dupe(u8, path),
            } };
        },
    };
}

pub fn capturedInvocation(environment_value: Environment, command: []const u8) ResolveError!Invocation {
    switch (environment_value) {
        .legacy, .workspace_clean => return error.UnsupportedShell,
        .clean => |path| {
            var invocation = try resolve(null, .{ .executable = .{
                .path = path,
                .clean_start = true,
            } });
            removeInteractiveFlag(&invocation);
            invocation.setCommand(command);
            return invocation;
        },
        .user => |path| {
            var invocation = try resolve(path, .user_login);
            if (std.mem.eql(u8, std.fs.path.basename(invocation.path), "bash")) {
                removeInteractiveFlag(&invocation);
                invocation.append("-O");
                invocation.append("expand_aliases");
            }
            invocation.setCommand(command);
            return invocation;
        },
    }
}

pub fn formatInvocationCommand(
    alloc: Allocator,
    invocation: *const Invocation,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    for (invocation.argv(), 0..) |word, index| {
        if (index != 0) try output.append(alloc, ' ');
        try appendShellWord(&output, alloc, word);
    }
    return output.toOwnedSlice(alloc);
}

fn removeInteractiveFlag(invocation: *Invocation) void {
    std.debug.assert(invocation.len > 0);
    std.debug.assert(std.mem.eql(u8, invocation.values[invocation.len - 1], "-i"));
    invocation.len -= 1;
}

pub fn buildBootstrap(
    alloc: Allocator,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    command_path: ?[]const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);

    try output.appendSlice(alloc, "set +x; ");
    if (command_path) |path| {
        try output.appendSlice(alloc, "fx_terminal_command=$(< ");
        try appendShellWord(&output, alloc, path);
        try output.appendSlice(alloc, ") || exit 125; ");
    }
    try appendMarker(&output, alloc, executable, control_path, nonce, "shell-ready");
    if (command_path) |_| {
        try output.appendSlice(alloc, " || exit 125; ");
        try appendMarker(
            &output,
            alloc,
            executable,
            control_path,
            nonce,
            "command-started",
        );
        try output.appendSlice(
            alloc,
            " || exit 125; builtin eval -- \"$fx_terminal_command\"; " ++
                "fx_terminal_status=$?; exit \"$fx_terminal_status\"\n",
        );
    } else {
        try output.appendSlice(alloc, " || exit 125\n");
    }
    return output.toOwnedSlice(alloc);
}

pub fn buildSourceCommand(
    alloc: Allocator,
    bootstrap_path: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, ". ");
    try appendShellWord(&output, alloc, bootstrap_path);
    try output.append(alloc, '\n');
    return output.toOwnedSlice(alloc);
}

fn appendMarker(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    event: []const u8,
) Allocator.Error!void {
    try appendShellWord(output, alloc, executable);
    inline for (.{
        "--fx-internal-terminal-control",
        control_path,
        nonce,
        event,
    }) |word| {
        try output.append(alloc, ' ');
        try appendShellWord(output, alloc, word);
    }
}

fn appendShellWord(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    word: []const u8,
) Allocator.Error!void {
    try output.append(alloc, '\'');
    for (word) |byte| {
        if (byte == '\'') {
            try output.appendSlice(alloc, "'\"'\"'");
        } else {
            try output.append(alloc, byte);
        }
    }
    try output.append(alloc, '\'');
}

/// Creates an executable shell fixture. The caller owns the returned path.
fn createExecutableTestShell(
    alloc: Allocator,
    dir: std.Io.Dir,
    name: []const u8,
) ![]u8 {
    var file = try dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.setPermissions(
        std.testing.io,
        std.Io.File.Permissions.fromMode(0o700),
    );
    return io_mod.dirRealpathAlloc(alloc, dir, name);
}

test "resolver builds Bash and zsh interactive argv" {
    const bash = try resolve("/bin/bash", .user_login);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/bin/bash", "--login", "-i" },
        bash.argv(),
    );

    const zsh = try resolve(
        null,
        .{ .executable = .{ .path = "/bin/zsh" } },
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/bin/zsh", "-l", "-i" },
        zsh.argv(),
    );
}

test "resolver makes clean startup explicit" {
    const bash = try resolve(
        null,
        .{ .executable = .{ .path = "/usr/local/bin/bash", .clean_start = true } },
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/usr/local/bin/bash", "--noprofile", "--norc", "-i" },
        bash.argv(),
    );

    const zsh = try resolve(
        null,
        .{ .executable = .{ .path = "/bin/zsh", .clean_start = true } },
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/bin/zsh", "-f", "-i" },
        zsh.argv(),
    );
}

test "resolver falls back to an existing platform shell without a passwd shell" {
    const expected_fallback = fallbackLoginShell() orelse return error.SkipZigTest;
    const resolved = try resolve(null, .user_login);
    try std.testing.expectEqualStrings(expected_fallback, resolved.path);
    switch (shellKind(expected_fallback) orelse return error.TestUnexpectedResult) {
        .bash => try std.testing.expectEqualSlices(
            []const u8,
            &.{ expected_fallback, "--login", "-i" },
            resolved.argv(),
        ),
        .zsh => try std.testing.expectEqualSlices(
            []const u8,
            &.{ expected_fallback, "-l", "-i" },
            resolved.argv(),
        ),
    }
    try std.testing.expectError(
        error.RelativeShellPath,
        resolve(null, .{ .executable = .{ .path = "zsh" } }),
    );
    try std.testing.expectError(
        error.UnsupportedShell,
        resolve(null, .{ .executable = .{ .path = "/bin/fish" } }),
    );
}

test "SHELL fallback is limited to a missing passwd entry" {
    const executable_shell = fallbackLoginShell() orelse return error.SkipZigTest;
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        executable_shell,
        configuredLoginShellFromSources(.missing_entry, executable_shell, &buffer).?,
    );
    try std.testing.expect(
        configuredLoginShellFromSources(.unavailable, executable_shell, &buffer) == null,
    );
    try std.testing.expectEqualStrings(
        "/configured/login/bash",
        configuredLoginShellFromSources(
            .{ .shell = "/configured/login/bash" },
            executable_shell,
            &buffer,
        ).?,
    );
}

test "validated SHELL fallback accepts only executable regular absolute values" {
    const alloc = std.testing.allocator;
    const executable_shell = fallbackLoginShell() orelse return error.SkipZigTest;
    var buffer: [4096]u8 = undefined;
    try std.testing.expect(validatedShellValue(null, &buffer) == null);
    try std.testing.expect(validatedShellValue("", &buffer) == null);
    try std.testing.expect(validatedShellValue("zsh", &buffer) == null);
    try std.testing.expect(validatedShellValue("/fx-no-such-shell/bash", &buffer) == null);
    var tiny: [2]u8 = undefined;
    try std.testing.expect(validatedShellValue(executable_shell, &tiny) == null);
    const accepted = validatedShellValue(executable_shell, &buffer) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(executable_shell, accepted);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "zsh", .default_dir);
    const directory_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "zsh");
    defer alloc.free(directory_path);
    try std.testing.expect(validatedShellValue(directory_path, &buffer) == null);

    var file = try tmp.dir.createFile(std.testing.io, "bash", .{});
    defer file.close(std.testing.io);
    const file_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "bash");
    defer alloc.free(file_path);
    try std.testing.expect(validatedShellValue(file_path, &buffer) == null);

    try file.setPermissions(
        std.testing.io,
        std.Io.File.Permissions.fromMode(0o700),
    );
    try std.testing.expectEqualStrings(
        file_path,
        validatedShellValue(file_path, &buffer).?,
    );
}

test "fallback shell selection skips missing earlier candidates" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const missing_bash = try std.fs.path.join(alloc, &.{ root, "bash" });
    defer alloc.free(missing_bash);
    const zsh_path = try createExecutableTestShell(alloc, tmp.dir, "zsh");
    defer alloc.free(zsh_path);

    try std.testing.expectEqualStrings(
        zsh_path,
        firstExecutableShell(&.{ missing_bash, zsh_path }).?,
    );
    try std.testing.expect(firstExecutableShell(&.{missing_bash}) == null);
}

test "login shell resolution falls back without accepting explicit unsupported shells" {
    const fallback = try resolve("/opt/homebrew/bin/fish", .user_login);
    const expected_fallback = fallbackLoginShell() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected_fallback, fallback.path);
    try std.testing.expectEqualStrings(
        expected_fallback,
        (try resolve("/fx-no-such-shell/bash", .user_login)).path,
    );
    try std.testing.expectError(
        error.UnsupportedShell,
        resolve(null, .{ .executable = .{ .path = "/opt/homebrew/bin/fish" } }),
    );
}

test "captured profiles use exact non-PTY argv" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bash_path = try createExecutableTestShell(alloc, tmp.dir, "bash");
    defer alloc.free(bash_path);
    const zsh_path = try createExecutableTestShell(alloc, tmp.dir, "zsh");
    defer alloc.free(zsh_path);

    const bash_clean = try capturedInvocation(.{ .clean = bash_path }, "printf clean");
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ bash_path, "--noprofile", "--norc", "-c", "printf clean" },
        bash_clean.argv(),
    );
    const bash_user = try capturedInvocation(.{ .user = bash_path }, "printf user");
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ bash_path, "--login", "-O", "expand_aliases", "-c", "printf user" },
        bash_user.argv(),
    );
    const zsh_clean = try capturedInvocation(.{ .clean = zsh_path }, "printf clean");
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ zsh_path, "-f", "-c", "printf clean" },
        zsh_clean.argv(),
    );
    const zsh_user = try capturedInvocation(.{ .user = zsh_path }, "printf user");
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ zsh_path, "-l", "-i", "-c", "printf user" },
        zsh_user.argv(),
    );
}

test "captured fallback flags follow the resolved shell" {
    const fallback = fallbackLoginShell() orelse return error.SkipZigTest;
    const invocation = try capturedInvocation(
        .{ .user = "/fx-no-such-shell/bash" },
        "printf fallback",
    );
    switch (shellKind(fallback) orelse return error.TestUnexpectedResult) {
        .bash => try std.testing.expectEqualSlices(
            []const u8,
            &.{ fallback, "--login", "-O", "expand_aliases", "-c", "printf fallback" },
            invocation.argv(),
        ),
        .zsh => try std.testing.expectEqualSlices(
            []const u8,
            &.{ fallback, "-l", "-i", "-c", "printf fallback" },
            invocation.argv(),
        ),
    }
}

test "captured invocation provider projection shell-quotes every argv word" {
    const invocation = try capturedInvocation(.{ .clean = "/bin/zsh" }, "printf '%s' ok");
    const command = try formatInvocationCommand(std.testing.allocator, &invocation);
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings(
        "'/bin/zsh' '-f' '-c' 'printf '\"'\"'%s'\"'\"' ok'",
        command,
    );
}

test "profile normalization defaults captured and persistent execution to user" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bash_path = try createExecutableTestShell(alloc, tmp.dir, "bash");
    defer alloc.free(bash_path);
    const zsh_path = try createExecutableTestShell(alloc, tmp.dir, "zsh");
    defer alloc.free(zsh_path);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect((try environment(arena, bash_path, null)).eql(.{ .user = bash_path }));
    try std.testing.expect((try environment(arena, zsh_path, null)).eql(.{ .user = zsh_path }));
    try std.testing.expect((try environment(arena, zsh_path, .clean)).eql(.{ .clean = zsh_path }));
    try std.testing.expect((try environment(arena, zsh_path, .user)).eql(.{ .user = zsh_path }));
    try std.testing.expectEqual(contracts.ShellSpec.user_login, try profileShell(arena, zsh_path, .user));
    try std.testing.expectEqualStrings(
        zsh_path,
        (try profileShell(arena, zsh_path, .clean)).executable.path,
    );
}

test "unsupported login shell profiles fall back for captured and persistent execution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fallback = fallbackLoginShell() orelse return error.SkipZigTest;
    const user_environment = try environment(arena, "/opt/homebrew/bin/fish", .user);
    const clean_environment = try environment(arena, "/opt/homebrew/bin/fish", .clean);
    try std.testing.expect(user_environment.eql(.{ .user = fallback }));
    try std.testing.expect(clean_environment.eql(.{ .clean = fallback }));

    const user_invocation = try capturedInvocation(user_environment, "printf user");
    const clean_invocation = try capturedInvocation(clean_environment, "printf clean");
    try std.testing.expectEqualStrings(fallback, user_invocation.path);
    try std.testing.expectEqualStrings(fallback, clean_invocation.path);

    try std.testing.expectEqualStrings(
        fallback,
        (try profileShell(arena, "/opt/homebrew/bin/fish", .user)).executable.path,
    );
    try std.testing.expectEqualStrings(
        fallback,
        (try profileShell(arena, "/opt/homebrew/bin/fish", .clean)).executable.path,
    );
}

test "bootstrap quotes private paths and separates command completion" {
    const commandless = try buildBootstrap(
        std.testing.allocator,
        "/tmp/fx'bin",
        "/tmp/control",
        "nonce",
        null,
    );
    defer std.testing.allocator.free(commandless);
    try std.testing.expectEqualStrings(
        "set +x; '/tmp/fx'\"'\"'bin' '--fx-internal-terminal-control' " ++
            "'/tmp/control' 'nonce' 'shell-ready' || exit 125\n",
        commandless,
    );

    const command = try buildBootstrap(
        std.testing.allocator,
        "/tmp/fx",
        "/tmp/control",
        "nonce",
        "/tmp/command",
    );
    defer std.testing.allocator.free(command);
    try std.testing.expect(
        std.mem.find(u8, command, "'command-started'") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, command, "builtin eval --") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, command, "exit \"$fx_terminal_status\"") != null,
    );

    const source = try buildSourceCommand(
        std.testing.allocator,
        "/tmp/bootstrap'file",
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings(
        ". '/tmp/bootstrap'\"'\"'file'\n",
        source,
    );
}

fn checkBootstrapAllocationFailures(alloc: Allocator) !void {
    const bootstrap = try buildBootstrap(
        alloc,
        "/tmp/fx",
        "/tmp/control",
        "nonce",
        "/tmp/command",
    );
    defer alloc.free(bootstrap);
    const source = try buildSourceCommand(alloc, "/tmp/bootstrap");
    defer alloc.free(source);
}

test "bootstrap construction cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkBootstrapAllocationFailures,
        .{},
    );
}
