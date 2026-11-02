const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
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

pub const ShellKind = enum { bash, zsh };

pub fn shellKind(path: []const u8) ?ShellKind {
    const basename = std.Io.Dir.path.basename(path);
    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    return null;
}

fn fallbackLoginShell() []const u8 {
    return if (builtin.target.os.tag == .macos) "/bin/zsh" else "/bin/bash";
}

fn supportedLoginShell(configured_login_shell: ?[]const u8) ResolveError![]const u8 {
    const path = configured_login_shell orelse return error.MissingLoginShell;
    if (!std.Io.Dir.path.isAbsolute(path)) return error.RelativeShellPath;
    if (shellKind(path) != null) return path;
    return fallbackLoginShell();
}

pub const Invocation = struct {
    path: []const u8,
    values: [8][]const u8 = @splat(""),
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
    if (!std.Io.Dir.path.isAbsolute(selection.path)) {
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
    if (comptime !builtin.link_libc or builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
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

/// zsh's `equals` option expands an unquoted word that starts with `=`, such
/// as a `======` separator or the `==` in `[ a == b ]`, to the path of the
/// command it names, and a word that names no command aborts the rest of the
/// command line. Commands are written for POSIX shells, so every zsh launch
/// turns the option off right before the command, after startup files or a
/// snapshot replay have run.
const zsh_command_prelude = "\\builtin unsetopt equals; ";

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
            invocation.setCommand(if (shellKind(path) == .zsh)
                try std.mem.concat(alloc, u8, &.{ zsh_command_prelude, command })
            else
                command);
            return invocation;
        },
        .user => |path| {
            var invocation = try resolve(path, .user_login);
            if (std.mem.eql(u8, std.Io.Dir.path.basename(path), "bash")) {
                removeInteractiveFlag(&invocation);
                invocation.append("-O");
                invocation.append("expand_aliases");
            }
            const effective_command = if (shellKind(path) == .zsh)
                try std.mem.concat(alloc, u8, &.{ captured_zsh_user_prelude, zsh_command_prelude, command })
            else
                command;
            invocation.setCommand(effective_command);
            return invocation;
        },
    }
}

/// Stderr marker, followed by a nonce, that a snapshot bootstrap writes with
/// exit status 125 when the replay stopped before the command could start.
pub const snapshot_replay_failure_prefix = "fx-shell-snapshot-replay-failed:";

/// Builds the clean-shell argv for a snapshot run. The shell sources the
/// replay and the command from stdin, so no snapshot text or command appears
/// in argv. `failure_marker` reaches stderr, with exit status 125, only when
/// the replay stopped before the command started.
///
/// The replay runs with stderr saved on fd 9 and pointed at /dev/null, so
/// its errors never reach the command's output. The command gets stderr back
/// through its own redirection (`snapshotScript`), and the bootstrap restores
/// it once the replay returns, for exit traps and the failure marker.
pub fn snapshotInvocation(
    alloc: Allocator,
    shell_path: []const u8,
    failure_marker: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    const kind = shellKind(shell_path) orelse return error.UnsupportedShell;
    var invocation = Invocation{ .path = shell_path };
    invocation.append(shell_path);
    switch (kind) {
        .zsh => invocation.append("-f"),
        .bash => {
            invocation.append("--noprofile");
            invocation.append("--norc");
            invocation.append("-O");
            invocation.append("expand_aliases");
        },
    }
    // bash's `builtin exec` drops its redirections when it returns, and bash
    // 3.2 hangs on a `command exec`, so bash uses plain `exec`. Nothing is
    // replayed before the first one, and the second runs after the command, so
    // removing a replayed function named `exec` there changes nothing it uses.
    const park_stderr: []const u8, const restore_stderr: []const u8 = switch (kind) {
        .zsh => .{ "\\builtin exec 9>&2 2>/dev/null; ", "\\builtin exec 2>&9 9>&-; " },
        .bash => .{ "exec 9>&2 2>/dev/null; ", "\\builtin unset -f exec; exec 2>&9 9>&-; " },
    };
    var bootstrap: std.ArrayList(u8) = .empty;
    errdefer bootstrap.deinit(alloc);
    try bootstrap.appendSlice(alloc, park_stderr);
    try bootstrap.appendSlice(alloc, "\\builtin source /dev/fd/0; __fx_snapshot_status=$?; ");
    try bootstrap.appendSlice(alloc, restore_stderr);
    try bootstrap.appendSlice(
        alloc,
        "if [[ -z ${__fx_snapshot_restored-} ]]; then \\builtin printf '%s' ",
    );
    try appendShellWord(&bootstrap, alloc, failure_marker);
    // Re-raise the common termination signals so the supervisor reports a
    // signal, as it does when the shell runs the command directly.
    try bootstrap.appendSlice(
        alloc,
        " >&2; \\builtin exit 125; fi; " ++
            "case $__fx_snapshot_status in 129|130|137|143) " ++
            "\\builtin kill -$((__fx_snapshot_status - 128)) $$;; esac; " ++
            "\\builtin exit $__fx_snapshot_status",
    );
    invocation.setCommand(try bootstrap.toOwnedSlice(alloc));
    return invocation;
}

/// Builds the stdin script for a snapshot run: the replay, the restored flag
/// the bootstrap checks, and the command. The command is single-quoted so it
/// is parsed only when `eval` runs, after the replayed aliases exist, and it
/// runs with stdin from /dev/null so it cannot read the rest of the script.
/// Its stderr is the one `snapshotInvocation` saved on fd 9, which it does
/// not inherit. A redirection, unlike an `exec`, cannot be replaced by a
/// replayed function or alias.
pub fn snapshotScript(
    alloc: Allocator,
    kind: ShellKind,
    replay: []const u8,
    command: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, replay);
    if (replay.len != 0 and replay[replay.len - 1] != '\n') try output.append(alloc, '\n');
    try output.appendSlice(alloc, "__fx_snapshot_restored=1\n");
    if (kind == .zsh) try output.appendSlice(alloc, zsh_command_prelude);
    try output.appendSlice(alloc, "\\builtin eval -- ");
    try appendShellWord(&output, alloc, command);
    try output.appendSlice(alloc, " </dev/null 2>&9 9>&-\n");
    return output.toOwnedSlice(alloc);
}

/// Payload section markers written by `snapshotCaptureScript`. Each marker is
/// followed by `:` and the capture nonce.
pub const snapshot_marker_prefix = "FXSNAP:";

// The replay starts by removing every alias. zsh starts with default aliases
// such as `run-help`, and a startup file that replaces one with a function,
// as Debian's and Ubuntu's global zshrc does, would otherwise make the
// replayed `run-help () {` a parse error that stops the whole replay. The
// captured `alias -L` lines then restore exactly the user's aliases.
const zsh_capture_script =
    \\{
    \\\builtin zmodload zsh/parameter 2>/dev/null
    \\\builtin printf 'FXSNAP:@NONCE@:ENV\0'
    \\/usr/bin/env -0
    \\\builtin printf 'FXSNAP:@NONCE@:NAMES\0'
    \\\builtin printf '%s\0' ${(k)aliases} ${(k)galiases} ${(k)saliases} ${(k)functions}
    \\\builtin printf 'FXSNAP:@NONCE@:REPLAY\0'
    \\\builtin print -r -- '\builtin unalias -a; \builtin unalias -as'
    \\\builtin typeset -p fpath
    \\for __fx_snapshot_name in ${(ko)functions}; do
    \\  case $__fx_snapshot_name in (_*|prompt_*|__fx_snapshot_*) continue;; esac
    \\  \builtin functions -- $__fx_snapshot_name
    \\done
    \\\builtin alias -L
    \\\builtin alias -sL
    \\for __fx_snapshot_name in extendedglob globdots nullglob nomatch kshglob shglob globstarshort bareglobqual caseglob numericglobsort rcexpandparam shwordsplit ksharrays magicequalsubst braceccl rcquotes shortloops cshnullglob globsubst; do
    \\  if [[ -o $__fx_snapshot_name ]]; then
    \\    \builtin print -r -- "\\builtin setopt $__fx_snapshot_name"
    \\  else
    \\    \builtin print -r -- "\\builtin unsetopt $__fx_snapshot_name"
    \\  fi
    \\done
    \\\builtin printf '\0FXSNAP:@NONCE@:END\0'
    \\} 2>/dev/null
;

const bash_capture_script =
    \\{
    \\\builtin printf 'FXSNAP:@NONCE@:ENV\0'
    \\/usr/bin/env -0
    \\\builtin printf 'FXSNAP:@NONCE@:NAMES\0'
    \\\builtin printf '%s\0' $(\builtin compgen -a) $(\builtin compgen -A function)
    \\\builtin printf 'FXSNAP:@NONCE@:REPLAY\0'
    \\for __fx_snapshot_name in $(\builtin compgen -A function); do
    \\  case $__fx_snapshot_name in _*|__fx_snapshot_*) continue;; esac
    \\  \builtin declare -f -- "$__fx_snapshot_name"
    \\done
    \\\builtin alias -p
    \\for __fx_snapshot_name in extglob nullglob dotglob globstar nocaseglob failglob nocasematch globasciiranges; do
    \\  \builtin shopt -p "$__fx_snapshot_name" 2>/dev/null
    \\done
    \\\builtin printf '\0FXSNAP:@NONCE@:END\0'
    \\} 2>/dev/null
;

/// Builds the script a login shell runs once to capture its state as a
/// NUL-delimited payload: exported environment, alias and function names, and
/// a replay of functions, aliases, and selected options. Every section marker
/// carries `nonce`, so output printed by the user's startup files cannot be
/// mistaken for the payload. `nonce` must be ASCII hex.
pub fn snapshotCaptureScript(
    alloc: Allocator,
    kind: ShellKind,
    nonce: []const u8,
) Allocator.Error![]u8 {
    for (nonce) |byte| std.debug.assert(std.ascii.isHex(byte));
    const template = switch (kind) {
        .zsh => zsh_capture_script,
        .bash => bash_capture_script,
    };
    return std.mem.replaceOwned(u8, alloc, template, "@NONCE@", nonce);
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
    kind: ShellKind,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    command_path: ?[]const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);

    try output.appendSlice(alloc, "set +x; export AI_AGENT=fx; ");
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
        try output.appendSlice(alloc, " || exit 125; ");
        if (kind == .zsh) try output.appendSlice(alloc, zsh_command_prelude);
        try output.appendSlice(
            alloc,
            "builtin eval -- \"$fx_terminal_command\"; " ++
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
    if (builtin.target.os.tag == .macos) {
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
    const expected_zsh_clean = [_][]const u8{
        "/bin/zsh",
        "-f",
        "-c",
        "\\builtin unsetopt equals; printf clean",
    };
    try std.testing.expectEqual(expected_zsh_clean.len, zsh_clean.argv().len);
    for (&expected_zsh_clean, zsh_clean.argv()) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    const zsh_user = try capturedInvocation(arena, .{ .user = "/bin/zsh" }, "printf user");
    const expected_zsh_user = [_][]const u8{
        "/bin/zsh",
        "-l",
        "-i",
        "-c",
        "\\builtin trap - TERM; \\builtin unsetopt equals; printf user",
    };
    try std.testing.expectEqual(expected_zsh_user.len, zsh_user.argv().len);
    for (&expected_zsh_user, zsh_user.argv()) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "captured invocation provider projection shell-quotes every argv word" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const invocation = try capturedInvocation(arena, .{ .clean = "/bin/zsh" }, "printf '%s' ok");
    const command = try formatInvocationCommand(arena, &invocation);
    try std.testing.expectEqualStrings(
        "'/bin/zsh' '-f' '-c' '\\builtin unsetopt equals; printf '\"'\"'%s'\"'\"' ok'",
        command,
    );
}

test "snapshot script turns off zsh equals expansion after the replay" {
    const zsh = try snapshotScript(std.testing.allocator, .zsh, "builtin setopt equals", "echo ======");
    defer std.testing.allocator.free(zsh);
    try std.testing.expectEqualStrings(
        "builtin setopt equals\n__fx_snapshot_restored=1\n" ++
            "\\builtin unsetopt equals; \\builtin eval -- 'echo ======' </dev/null 2>&9 9>&-\n",
        zsh,
    );

    const bash = try snapshotScript(std.testing.allocator, .bash, "", "echo ======");
    defer std.testing.allocator.free(bash);
    try std.testing.expectEqualStrings(
        "__fx_snapshot_restored=1\n\\builtin eval -- 'echo ======' </dev/null 2>&9 9>&-\n",
        bash,
    );
}

test "snapshot bootstrap hides replay errors and restores stderr afterwards" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tail = "if [[ -z ${__fx_snapshot_restored-} ]]; then \\builtin printf '%s' 'marker' >&2; " ++
        "\\builtin exit 125; fi; case $__fx_snapshot_status in 129|130|137|143) " ++
        "\\builtin kill -$((__fx_snapshot_status - 128)) $$;; esac; \\builtin exit $__fx_snapshot_status";

    const zsh = try snapshotInvocation(arena, "/bin/zsh", "marker");
    try std.testing.expectEqualStrings(
        "\\builtin exec 9>&2 2>/dev/null; \\builtin source /dev/fd/0; __fx_snapshot_status=$?; " ++
            "\\builtin exec 2>&9 9>&-; " ++ tail,
        zsh.argv()[zsh.argv().len - 1],
    );

    const bash = try snapshotInvocation(arena, "/bin/bash", "marker");
    try std.testing.expectEqualStrings(
        "exec 9>&2 2>/dev/null; \\builtin source /dev/fd/0; __fx_snapshot_status=$?; " ++
            "\\builtin unset -f exec; exec 2>&9 9>&-; " ++ tail,
        bash.argv()[bash.argv().len - 1],
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
        .zsh,
        "/tmp/fx'bin",
        "/tmp/control",
        "nonce",
        null,
    );
    defer std.testing.allocator.free(commandless);
    try std.testing.expectEqualStrings(
        "set +x; export AI_AGENT=fx; '/tmp/fx'\"'\"'bin' '--fx-internal-terminal-control' " ++
            "'/tmp/control' 'nonce' 'shell-ready' || exit 125\n",
        commandless,
    );

    const command = try buildBootstrap(
        std.testing.allocator,
        .zsh,
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
        std.mem.find(u8, command, "|| exit 125; \\builtin unsetopt equals; builtin eval --") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, command, "exit \"$fx_terminal_status\"") != null,
    );

    const bash_command = try buildBootstrap(
        std.testing.allocator,
        .bash,
        "/tmp/fx",
        "/tmp/control",
        "nonce",
        "/tmp/command",
    );
    defer std.testing.allocator.free(bash_command);
    try std.testing.expect(
        std.mem.find(u8, bash_command, "|| exit 125; builtin eval --") != null,
    );
    try std.testing.expect(std.mem.find(u8, bash_command, "unsetopt") == null);

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
        .zsh,
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
        testing_allocator.no_resize,
        checkBootstrapAllocationFailures,
        .{},
    );
}
