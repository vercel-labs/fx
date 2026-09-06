const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const command_environment = @import("../execution/command_environment.zig");

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

fn fallbackLoginShell() []const u8 {
    return if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash";
}

fn supportedLoginShell(configured_login_shell: ?[]const u8) ResolveError![]const u8 {
    const path = configured_login_shell orelse return error.MissingLoginShell;
    if (!std.fs.path.isAbsolute(path)) return error.RelativeShellPath;
    if (shellKind(path) != null) return path;
    return fallbackLoginShell();
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

pub fn configuredLoginShellInto(buffer: []u8) ?[]const u8 {
    if (comptime !builtin.link_libc or builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return null;
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
    ) != 0) return null;
    const record = found orelse return null;
    const shell_ptr = record.shell orelse return null;
    const shell = std.mem.span(shell_ptr);
    if (shell.len == 0 or shell.len > buffer.len) return null;
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

pub fn environmentForShellSpec(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) (ResolveError || Allocator.Error)!Environment {
    const invocation = try resolve(configured_login_shell, shell);
    return switch (shell) {
        .user_login => .{ .user = try alloc.dupe(u8, invocation.path) },
        .executable => |value| if (value.clean_start)
            .{ .clean = try alloc.dupe(u8, invocation.path) }
        else
            .{ .user = try alloc.dupe(u8, invocation.path) },
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

const captured_zsh_user_prelude = "\\builtin trap - TERM; ";

pub fn capturedInvocation(
    alloc: Allocator,
    environment_value: Environment,
    command: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
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
            if (std.mem.eql(u8, std.fs.path.basename(path), "bash")) {
                removeInteractiveFlag(&invocation);
                invocation.append("-O");
                invocation.append("expand_aliases");
            }
            const effective_command = if (shellKind(path) == .zsh)
                try std.mem.concat(alloc, u8, &.{ captured_zsh_user_prelude, command })
            else
                command;
            invocation.setCommand(effective_command);
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

test "shell environments bind executable path and startup mode" {
    const alloc = std.testing.allocator;
    const clean = try environmentForShellSpec(
        alloc,
        null,
        .{ .executable = .{ .path = "/bin/bash", .clean_start = true } },
    );
    defer switch (clean) {
        .clean => |path| alloc.free(@constCast(path)),
        else => {},
    };
    try std.testing.expectEqualStrings("/bin/bash", clean.clean);

    const user = try environmentForShellSpec(
        alloc,
        null,
        .{ .executable = .{ .path = "/bin/bash" } },
    );
    defer switch (user) {
        .user => |path| alloc.free(@constCast(path)),
        else => {},
    };
    try std.testing.expectEqualStrings("/bin/bash", user.user);
    try std.testing.expect(!clean.eql(user));
}

test "resolver rejects missing relative and unsupported shells" {
    try std.testing.expectError(
        error.MissingLoginShell,
        resolve(null, .user_login),
    );
    try std.testing.expectError(
        error.RelativeShellPath,
        resolve(null, .{ .executable = .{ .path = "zsh" } }),
    );
    try std.testing.expectError(
        error.UnsupportedShell,
        resolve(null, .{ .executable = .{ .path = "/bin/fish" } }),
    );
}

test "login shell resolution falls back without accepting explicit unsupported shells" {
    const fallback = try resolve("/opt/homebrew/bin/fish", .user_login);
    try std.testing.expectEqualStrings(fallbackLoginShell(), fallback.path);
    if (builtin.os.tag == .macos) {
        try std.testing.expectEqualSlices(
            []const u8,
            &.{ "/bin/zsh", "-l", "-i" },
            fallback.argv(),
        );
    } else {
        try std.testing.expectEqualSlices(
            []const u8,
            &.{ "/bin/bash", "--login", "-i" },
            fallback.argv(),
        );
    }

    try std.testing.expectError(
        error.UnsupportedShell,
        resolve(null, .{ .executable = .{ .path = "/opt/homebrew/bin/fish" } }),
    );
}

test "captured profiles use exact non-PTY argv" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bash_clean = try capturedInvocation(arena, .{ .clean = "/bin/bash" }, "printf clean");
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/bin/bash", "--noprofile", "--norc", "-c", "printf clean" },
        bash_clean.argv(),
    );
    const bash_user = try capturedInvocation(arena, .{ .user = "/bin/bash" }, "printf user");
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/bin/bash", "--login", "-O", "expand_aliases", "-c", "printf user" },
        bash_user.argv(),
    );
    const zsh_clean = try capturedInvocation(arena, .{ .clean = "/bin/zsh" }, "printf clean");
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "/bin/zsh", "-f", "-c", "printf clean" },
        zsh_clean.argv(),
    );
    const zsh_user = try capturedInvocation(arena, .{ .user = "/bin/zsh" }, "printf user");
    const expected_zsh_user = [_][]const u8{
        "/bin/zsh",
        "-l",
        "-i",
        "-c",
        "\\builtin trap - TERM; printf user",
    };
    try std.testing.expectEqual(expected_zsh_user.len, zsh_user.argv().len);
    for (&expected_zsh_user, zsh_user.argv()) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "captured invocation provider projection shell-quotes every argv word" {
    const invocation = try capturedInvocation(std.testing.allocator, .{ .clean = "/bin/zsh" }, "printf '%s' ok");
    const command = try formatInvocationCommand(std.testing.allocator, &invocation);
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings(
        "'/bin/zsh' '-f' '-c' 'printf '\"'\"'%s'\"'\"' ok'",
        command,
    );
}

test "profile normalization defaults captured and persistent execution to user" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect((try environment(arena, "/bin/bash", null)).eql(.{ .user = "/bin/bash" }));
    try std.testing.expect((try environment(arena, "/bin/zsh", null)).eql(.{ .user = "/bin/zsh" }));
    try std.testing.expect((try environment(arena, "/bin/zsh", .clean)).eql(.{ .clean = "/bin/zsh" }));
    try std.testing.expect((try environment(arena, "/bin/zsh", .user)).eql(.{ .user = "/bin/zsh" }));
    try std.testing.expectEqual(contracts.ShellSpec.user_login, try profileShell(arena, "/bin/zsh", .user));
    try std.testing.expectEqualStrings(
        "/bin/zsh",
        (try profileShell(arena, "/bin/zsh", .clean)).executable.path,
    );
}

test "unsupported login shell profiles fall back for captured and persistent execution" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fallback = fallbackLoginShell();
    const user_environment = try environment(arena, "/opt/homebrew/bin/fish", .user);
    const clean_environment = try environment(arena, "/opt/homebrew/bin/fish", .clean);
    try std.testing.expect(user_environment.eql(.{ .user = fallback }));
    try std.testing.expect(clean_environment.eql(.{ .clean = fallback }));

    const user_invocation = try capturedInvocation(arena, user_environment, "printf user");
    const clean_invocation = try capturedInvocation(arena, clean_environment, "printf clean");
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
