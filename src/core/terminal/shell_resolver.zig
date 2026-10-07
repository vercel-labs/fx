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

/// Shells fx can use as the login shell and restore from a snapshot.
pub const ShellKind = enum { bash, zsh };

pub fn shellKind(path: []const u8) ?ShellKind {
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    return null;
}

/// How fx starts a shell. POSIX shells run only when chosen explicitly: they
/// are never the login shell and have no snapshot.
const Family = enum { bash, zsh, posix };

const posix_shell_names = [_][]const u8{ "sh", "dash", "ksh" };

fn family(path: []const u8) ?Family {
    if (shellKind(path)) |kind| return switch (kind) {
        .bash => .bash,
        .zsh => .zsh,
    };
    const basename = std.fs.path.basename(path);
    for (posix_shell_names) |name| {
        if (std.mem.eql(u8, basename, name)) return .posix;
    }
    return null;
}

/// Reports whether fx can run commands in the shell named or located by
/// `path`: bash, zsh, sh, dash, or ksh.
pub fn isSupportedShell(path: []const u8) bool {
    return family(path) != null;
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
    if (!std.fs.path.isAbsolute(selection.path)) {
        return error.RelativeShellPath;
    }

    const kind = family(selection.path) orelse return error.UnsupportedShell;

    var result = Invocation{ .path = selection.path };
    result.append(selection.path);
    switch (kind) {
        // A non-interactive POSIX shell reads no startup files; an interactive
        // one reads only $ENV.
        .posix => result.append("-i"),
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

/// Environment for a captured (non-TTY) run in an explicitly chosen shell.
/// The process keeps one startup-file snapshot, of the default shell, and a
/// `user` environment for any other shell would replace it and reset the
/// approvals bound to it. So only the default shell runs with the user's
/// startup files; another shell runs without them and inherits fx's
/// environment, which already carries the user's PATH and variables.
pub fn capturedEnvironmentForShellSpec(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) (ResolveError || Allocator.Error)!Environment {
    const explicit = switch (shell) {
        .user_login => return environmentForShellSpec(alloc, configured_login_shell, shell),
        .executable => |value| value,
    };
    const default_path = supportedLoginShell(configured_login_shell) catch |err| switch (err) {
        error.MissingLoginShell => null,
        else => return err,
    };
    if (default_path) |path| {
        if (std.mem.eql(u8, path, explicit.path)) return environmentForShellSpec(alloc, configured_login_shell, shell);
    }
    _ = try resolve(null, shell);
    return .{ .clean = try alloc.dupe(u8, explicit.path) };
}

/// Environment for a captured (non-TTY) run: the explicitly chosen shell when
/// there is one, otherwise the login shell with `profile`. Permission admission
/// and the shell tool both call this, so the approved environment is the one
/// that runs.
pub fn capturedRunEnvironment(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: ?Profile,
    shell: ?contracts.ShellSpec,
) (ResolveError || Allocator.Error)!Environment {
    if (shell) |spec| return capturedEnvironmentForShellSpec(alloc, configured_login_shell, spec);
    return environment(alloc, configured_login_shell, profile);
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

/// zsh options for model commands, which are written as bash text. A word
/// that starts with `=` stays a word instead of a command path lookup that
/// aborts the rest of the command, an unmatched glob stays a literal word,
/// `${arr[0]}` is the first element, and unquoted variables split into words.
/// They run after the startup files and the snapshot replay, so the user's own
/// settings cannot undo them.
const zsh_model_command_options = "\\builtin unsetopt equals nomatch; \\builtin setopt kshzerosubscript shwordsplit; ";

/// The model command runs inside an anonymous function whose `path` and
/// `status` are ordinary local variables. In zsh both are special: `path` is
/// tied to PATH and `status` is read-only, so bash text that assigns either
/// would empty PATH or abort the command. PATH itself is untouched. zsh counts
/// function lines from the opening brace, so the command starting on the next
/// line keeps its own line numbers in error messages. The closing brace sits
/// on its own line after a blank one, so a trailing comment or line
/// continuation cannot absorb it.
const zsh_model_command_open = "() { \\builtin local -h path status\n";
const zsh_model_command_close = "\n\n}";

/// Returns the text the shell at `shell_path` runs for the model command
/// `command`: wrapped as described above for zsh, unchanged for other shells.
/// The result is either `command` itself or allocated in `alloc`.
pub fn modelCommandText(
    alloc: Allocator,
    shell_path: []const u8,
    command: []const u8,
) Allocator.Error![]const u8 {
    if (shellKind(shell_path) != .zsh) return command;
    return std.mem.concat(alloc, u8, &.{ zsh_model_command_options, zsh_model_command_open, command, zsh_model_command_close });
}

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
            if (family(path) == .posix) {
                var invocation = try resolve(null, .{ .executable = .{ .path = path } });
                removeInteractiveFlag(&invocation);
                invocation.setCommand(command);
                return invocation;
            }
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

/// Stderr marker, followed by a nonce, that a snapshot bootstrap writes with
/// exit status 125 when the replay stopped before the command could start.
pub const snapshot_replay_failure_prefix = "fx-shell-snapshot-replay-failed:";

/// Builds the clean-shell argv for a snapshot run. The shell sources the
/// replay and the command from stdin, so no snapshot text or command appears
/// in argv. `failure_marker` reaches stderr, with exit status 125, only when
/// the replay stopped before the command started.
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
    var bootstrap: std.ArrayList(u8) = .empty;
    errdefer bootstrap.deinit(alloc);
    try bootstrap.appendSlice(
        alloc,
        "\\builtin source /dev/fd/0; __fx_snapshot_status=$?; " ++
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
pub fn snapshotScript(
    alloc: Allocator,
    replay: []const u8,
    command: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, replay);
    if (replay.len != 0 and replay[replay.len - 1] != '\n') try output.append(alloc, '\n');
    try output.appendSlice(alloc, "__fx_snapshot_restored=1\n\\builtin eval -- ");
    try appendShellWord(&output, alloc, command);
    try output.appendSlice(alloc, " </dev/null\n");
    return output.toOwnedSlice(alloc);
}

/// Payload section markers written by `snapshotCaptureScript`. Each marker is
/// followed by `:` and the capture nonce.
pub const snapshot_marker_prefix = "FXSNAP:";

const zsh_capture_script =
    \\{
    \\\builtin zmodload zsh/parameter 2>/dev/null
    \\\builtin printf 'FXSNAP:@NONCE@:ENV\0'
    \\/usr/bin/env -0
    \\\builtin printf 'FXSNAP:@NONCE@:NAMES\0'
    \\\builtin printf '%s\0' ${(k)aliases} ${(k)galiases} ${(k)saliases} ${(k)functions}
    \\\builtin printf 'FXSNAP:@NONCE@:REPLAY\0'
    \\\builtin typeset -p fpath
    \\for __fx_snapshot_name in ${(ko)functions}; do
    \\  case $__fx_snapshot_name in (_*|prompt_*|__fx_snapshot_*) continue;; esac
    \\  \builtin functions -- $__fx_snapshot_name
    \\done
    \\\builtin alias -L
    \\\builtin alias -sL
    \\for __fx_snapshot_name in extendedglob globdots nullglob nomatch kshglob shglob globstarshort bareglobqual caseglob numericglobsort rcexpandparam shwordsplit ksharrays magicequalsubst equals braceccl rcquotes shortloops cshnullglob globsubst; do
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

/// Builds the script the TTY shell at `shell_path` sources. Bash and zsh read
/// the command file with `$(< file)` and run it with `builtin eval`; POSIX
/// shells have neither, so they use `cat` and `eval`.
pub fn buildBootstrap(
    alloc: Allocator,
    shell_path: []const u8,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    command_path: ?[]const u8,
) Allocator.Error![]u8 {
    const posix = family(shell_path) == .posix;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);

    try output.appendSlice(alloc, "set +x; ");
    if (command_path) |path| {
        try output.appendSlice(alloc, if (posix) "fx_terminal_command=$(cat " else "fx_terminal_command=$(< ");
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
            if (posix)
                " || exit 125; eval \"$fx_terminal_command\"; " ++
                    "fx_terminal_status=$?; exit \"$fx_terminal_status\"\n"
            else
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

test "explicit POSIX shells run directly and never become the login shell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "/bin/sh", "/bin/dash", "/usr/bin/ksh" }) |path| {
        try std.testing.expect(isSupportedShell(path));
        const tty = try resolve(null, .{ .executable = .{ .path = path } });
        try std.testing.expectEqualSlices([]const u8, &.{ path, "-i" }, tty.argv());
        const user = try capturedInvocation(arena, .{ .user = path }, "printf ok");
        try std.testing.expectEqualSlices([]const u8, &.{ path, "-c", "printf ok" }, user.argv());
        const clean = try capturedInvocation(arena, .{ .clean = path }, "printf ok");
        try std.testing.expectEqualSlices([]const u8, &.{ path, "-c", "printf ok" }, clean.argv());
    }
    try std.testing.expect(!isSupportedShell("/opt/homebrew/bin/fish"));
    try std.testing.expect(!isSupportedShell("/usr/bin/python3"));
    // A POSIX login shell still falls back, as an unsupported one always has.
    try std.testing.expectEqualStrings(fallbackLoginShell(), (try resolve("/bin/ksh", .user_login)).path);
}

test "captured runs keep startup files only for the default shell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bash: contracts.ShellSpec = .{ .executable = .{ .path = "/bin/bash" } };

    // Choosing the default shell explicitly is the same as not choosing one.
    const same = try capturedEnvironmentForShellSpec(arena, "/bin/bash", bash);
    try std.testing.expectEqualStrings("/bin/bash", same.user);
    const same_clean = try capturedEnvironmentForShellSpec(arena, "/bin/bash", .{ .executable = .{ .path = "/bin/bash", .clean_start = true } });
    try std.testing.expectEqualStrings("/bin/bash", same_clean.clean);
    // Any other shell runs without startup files, so the default shell's snapshot stays.
    const other = try capturedEnvironmentForShellSpec(arena, "/bin/zsh", bash);
    try std.testing.expectEqualStrings("/bin/bash", other.clean);
    const posix = try capturedEnvironmentForShellSpec(arena, "/bin/zsh", .{ .executable = .{ .path = "/bin/sh" } });
    try std.testing.expectEqualStrings("/bin/sh", posix.clean);
    const no_login = try capturedEnvironmentForShellSpec(arena, null, bash);
    try std.testing.expectEqualStrings("/bin/bash", no_login.clean);
    try std.testing.expectError(error.UnsupportedShell, capturedEnvironmentForShellSpec(arena, "/bin/zsh", .{ .executable = .{ .path = "/usr/bin/python3" } }));
    try std.testing.expectError(error.RelativeShellPath, capturedEnvironmentForShellSpec(arena, "/bin/zsh", .{ .executable = .{ .path = "bash" } }));
}

test "POSIX TTY bootstrap avoids bash and zsh syntax" {
    const bootstrap = try buildBootstrap(
        std.testing.allocator,
        "/bin/dash",
        "/tmp/fx",
        "/tmp/control",
        "abcd",
        "/tmp/command",
    );
    defer std.testing.allocator.free(bootstrap);
    try std.testing.expect(std.mem.find(u8, bootstrap, "fx_terminal_command=$(cat '/tmp/command')") != null);
    try std.testing.expect(std.mem.find(u8, bootstrap, "eval \"$fx_terminal_command\"") != null);
    try std.testing.expect(std.mem.find(u8, bootstrap, "builtin") == null);
    try std.testing.expect(std.mem.find(u8, bootstrap, "$(<") == null);
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

test "model command text sets bash-compatible options only for zsh" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = "echo =====";
    const wrapped = "\\builtin unsetopt equals nomatch; \\builtin setopt kshzerosubscript shwordsplit; " ++
        "() { \\builtin local -h path status\necho =====\n\n}";
    try std.testing.expectEqualStrings(wrapped, try modelCommandText(arena, "/bin/zsh", command));
    try std.testing.expectEqualStrings(wrapped, try modelCommandText(arena, "/opt/homebrew/bin/zsh", command));
    // Other shells already treat these words as bash does; nothing is added
    // and nothing is allocated.
    try std.testing.expect((try modelCommandText(arena, "/bin/bash", command)).ptr == command.ptr);
    try std.testing.expect((try modelCommandText(arena, "/bin/sh", command)).ptr == command.ptr);
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
        "/bin/zsh",
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
        "/bin/zsh",
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
        "/bin/zsh",
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
