//! One agent's saved bash state for the one bash tool. Each bash tool program
//! is one captured bash command. Its BASH_ENV script loads the state the last
//! program saved and saves it again when the program ends, so a program killed
//! by a signal saves nothing (`tests/tla/bash_tool/ResultStore.tla` `Finish`,
//! `StateNeverTorn`, `EndedSaves`). The state never holds the MCP token. This
//! module imports only `std`, so `zig test` runs its tests alone.
const std = @import("std");

/// The whole code a program sends to wait for the program that is running.
pub const wait_word = "wait_more";

/// The variable bash reads its startup script from; its value is `Session.bashEnv`.
pub const env_var = "BASH_ENV";

/// The largest bash state one program saves (R3.7). A larger state is not
/// saved: the last complete state stays, and the program's output says so
/// (`tests/tla/bash_tool/ResultStore.tla` `RefusalNoticed`).
pub const max_state_bytes: usize = 1 << 20;

/// Whether `code` is the wait request: `wait_word` alone, with spaces, tabs,
/// and line ends around it.
pub fn isWaitMore(code: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, code, " \t\r\n"), wait_word);
}

const default_bash = "/bin/bash";

/// The bash to run: `login_shell` when it is an absolute path to a program
/// named `bash`, else `/bin/bash`.
pub fn bashPath(login_shell: ?[]const u8) []const u8 {
    const shell = login_shell orelse return default_bash;
    if (!std.Io.Dir.path.isAbsolute(shell)) return default_bash;
    if (!std.mem.eql(u8, std.Io.Dir.path.basename(shell), "bash")) return default_bash;
    return shell;
}

const env_header =
    "# fx bash tool: load the bash state the last program saved, and save it again\n" ++
    "# when this program ends (tests/tla/bash_tool/ResultStore.tla Finish).\n";

/// The file, next to the state, that holds the folder the last saved program
/// ended in. The state never holds a folder: fx starts each program there.
const folder_file = "folder";

/// Appends `name='<path>'` and a newline. A `'` in `path` becomes `'\''`, so the
/// path stays one shell word.
fn appendQuotedAssignment(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, path: []const u8) !void {
    try out.appendSlice(alloc, name);
    try out.appendSlice(alloc, "='");
    for (path) |byte| {
        if (byte == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, byte);
        }
    }
    try out.appendSlice(alloc, "'\n");
}

/// Whether `name` is a plain variable name: letters, digits, and `_`, not empty.
/// Only such a name can go into the script's case pattern unchanged.
fn isVariableName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

/// The BASH_ENV script for a session whose state file is `state_path`. The
/// caller owns the result. A `'` in the path becomes `'\''`, so the path stays
/// one shell word. `fx_variables` are the names fx adds to every program; the
/// script skips them when it saves, so they never reach the saved state.
fn envScript(alloc: std.mem.Allocator, state_path: []const u8, folder_path: []const u8, fx_variables: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, env_header);
    try appendQuotedAssignment(alloc, &out, "__fx_state", state_path);
    try appendQuotedAssignment(alloc, &out, "__fx_folder", folder_path);
    try out.appendSlice(alloc, std.fmt.comptimePrint("__fx_max={d}\n", .{max_state_bytes}));
    try out.appendSlice(alloc, body_before_skip);
    for (fx_variables) |name| {
        try out.append(alloc, '|');
        try out.appendSlice(alloc, name);
    }
    try out.appendSlice(alloc, body_after_skip);
    return out.toOwnedSlice(alloc);
}

/// One agent's bash session: its private folder and its BASH_ENV script. The
/// folder is made by `prepare` and deleted by `deinit`.
pub const Session = struct {
    /// Makes and frees this session's paths; it lives as long as the session.
    alloc: std.mem.Allocator,
    /// The private folder, `<tmp_root>/fx-bash-<pid>-<16 hex digits>`, where
    /// `<pid>` is this process's id. Owned.
    dir: ?[]u8 = null,
    /// `<dir>/env.sh`, the BASH_ENV script. Owned.
    env_path: ?[]u8 = null,
    /// The id of this session's last program, so a new program waits its
    /// turn and wait_more finds it. Owned.
    program_id: ?[]u8 = null,
    /// The folder the next program starts in, as the last saved state left it.
    /// Null means the workspace root. Owned.
    start_folder: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator) Session {
        return .{ .alloc = alloc };
    }

    /// Makes the folder and writes its script, once. `tmp_root` must be an
    /// absolute path, because the script names the state file by its full
    /// path. It must not hold `$`, a backquote, or a backslash: bash expands
    /// `BASH_ENV`, so one of them would run code or change the path, and such a
    /// root is refused with `error.UnsafeTmpRoot`. `fx_variables` are the names fx adds to every program, which the
    /// script never saves; a name that is not a plain variable name is refused
    /// with `error.InvalidVariableName` before anything is made. Before it makes
    /// the folder, it removes the folders that dead processes left in `tmp_root`
    /// (`sweepDeadFolders`). On failure nothing is left behind and the session
    /// stays unprepared. Returns how many dead folders the sweep removed, or 0
    /// when the session was already prepared.
    pub fn prepare(self: *Session, io: std.Io, tmp_root: []const u8, fx_variables: []const []const u8) !usize {
        if (self.dir != null) return 0;
        const alloc = self.alloc;
        if (!std.Io.Dir.path.isAbsolute(tmp_root)) return error.RelativeTmpRoot;
        if (std.mem.findAny(u8, tmp_root, "$`\\") != null) return error.UnsafeTmpRoot;
        for (fx_variables) |name| {
            if (!isVariableName(name)) return error.InvalidVariableName;
        }
        const swept = sweepDeadFolders(io, tmp_root);
        var suffix: [8]u8 = undefined;
        io.random(&suffix);
        const hex = std.fmt.bytesToHex(suffix, .lower);
        const dir = try alloc.print("{s}/{s}{d}-{s}", .{ tmp_root, folder_prefix, processId(), &hex });
        errdefer alloc.free(dir);
        const env_path = try alloc.print("{s}/env.sh", .{dir});
        errdefer alloc.free(env_path);
        const state_path = try alloc.print("{s}/state.sh", .{dir});
        defer alloc.free(state_path);
        const folder_path = try alloc.print("{s}/{s}", .{ dir, folder_file });
        defer alloc.free(folder_path);
        const script = try envScript(alloc, state_path, folder_path, fx_variables);
        defer alloc.free(script);

        try std.Io.Dir.cwd().createDir(io, dir, .fromMode(0o700));
        errdefer removeTree(io, dir);
        try writeScript(io, dir, script);

        self.dir = dir;
        self.env_path = env_path;
        return swept;
    }

    /// The BASH_ENV value for this session's programs, or null before `prepare`.
    pub fn bashEnv(self: *const Session) ?[]const u8 {
        const path = self.env_path orelse return null;
        return path;
    }

    /// Stores `id` as the id of this session's last program, freeing the one
    /// before it. If the copy fails, the old id stays.
    pub fn setProgram(self: *Session, id: []const u8) !void {
        const owned = try self.alloc.dupe(u8, id);
        if (self.program_id) |old| self.alloc.free(old);
        self.program_id = owned;
    }

    /// The id of this session's last program, or null before one is set.
    pub fn program(self: *const Session) ?[]const u8 {
        return self.program_id;
    }

    /// Deletes the session folder and frees both paths. The session is then
    /// unprepared, so `prepare` can make a new folder.
    /// The folder the next program starts in, or null for the workspace root.
    /// The slice is valid until the next `refreshStartFolder` or `deinit`.
    pub fn startFolder(self: *const Session) ?[]const u8 {
        return self.start_folder;
    }

    /// Reads the folder the last saved program ended in and keeps it when it is
    /// an absolute path, with no NUL byte, that opens as a directory. Anything
    /// else sets null, which means the workspace root.
    pub fn refreshStartFolder(self: *Session, io: std.Io) void {
        // A missing or bad folder file is not an error: the workspace root is
        // the folder a session starts in until a program saves one.
        const next = self.readStartFolder(io) catch null;
        if (self.start_folder) |old| self.alloc.free(old);
        self.start_folder = next;
    }

    fn readStartFolder(self: *Session, io: std.Io) !?[]u8 {
        const dir_path = self.dir orelse return null;
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        const folder = try dir.readFileAlloc(io, folder_file, self.alloc, .limited(std.Io.Dir.max_path_bytes));
        errdefer self.alloc.free(folder);
        if (!std.Io.Dir.path.isAbsolute(folder) or std.mem.findScalar(u8, folder, 0) != null) return error.BadStartFolder;
        var target = try std.Io.Dir.cwd().openDir(io, folder, .{});
        target.close(io);
        return folder;
    }

    pub fn deinit(self: *Session, io: std.Io) void {
        const alloc = self.alloc;
        if (self.dir) |dir| {
            removeTree(io, dir);
            alloc.free(dir);
        }
        if (self.env_path) |path| alloc.free(path);
        if (self.program_id) |id| alloc.free(id);
        if (self.start_folder) |folder| alloc.free(folder);
        self.* = .{ .alloc = alloc };
    }
};

/// The prefix of every bash session folder's name, which the sweep looks for.
const folder_prefix = "fx-bash-";

/// This process's id, which names its bash session folders.
fn processId() std.posix.pid_t {
    return std.posix.system.getpid();
}

/// The process id in a session folder's name, `fx-bash-<pid>-<anything>`, or
/// null for any other name, or for a pid that is not a positive number.
fn folderOwner(name: []const u8) ?std.posix.pid_t {
    if (!std.mem.startsWith(u8, name, folder_prefix)) return null;
    const rest = name[folder_prefix.len..];
    const end = std.mem.findScalar(u8, rest, '-') orelse return null;
    const digits = rest[0..end];
    if (digits.len == 0) return null;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const pid = std.fmt.parseInt(std.posix.pid_t, digits, 10) catch return null;
    return if (pid > 0) pid else null;
}

/// Whether `pid` names no process. Only "no such process" counts as gone. A
/// permission error or any other result may be a live process, so it is alive.
fn processGone(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| return err == error.ProcessNotFound;
    return false;
}

/// Removes the bash session folders that dead processes left in `tmp_root`. A
/// process killed by a signal cannot run `deinit`, so the folder it made stays
/// until a later session in the same temp folder clears it. Only a real
/// directory named `fx-bash-<pid>-...`, whose pid names no process, is removed.
/// A link or a file is never followed or removed, and this process's own
/// folders and those of a live process stay. Best effort: whatever cannot be
/// opened or deleted stays, and a later session tries again.
/// Deletes the folders in `tmp_root` that dead processes left, and returns how
/// many it deleted. Best effort: a folder it cannot delete stays for a later
/// session, and a failure to read the root ends the sweep without an error.
fn sweepDeadFolders(io: std.Io, tmp_root: []const u8) usize {
    var removed: usize = 0;
    var root = std.Io.Dir.cwd().openDir(io, tmp_root, .{ .iterate = true }) catch return removed; // Best effort: a later session sweeps again.
    defer root.close(io);
    const own = processId();
    var entries = root.iterate();
    while (true) {
        const entry = (entries.next(io) catch return removed) orelse break; // Best effort: stop here, a later session sweeps again.
        if (entry.kind != .directory) continue;
        const pid = folderOwner(entry.name) orelse continue;
        if (pid == own or !processGone(pid)) continue;
        root.deleteTree(io, entry.name) catch continue; // Best effort: this folder stays until a later session deletes it.
        removed += 1;
    }
    return removed;
}

/// Writes `script` as `<dir>/env.sh` through a temporary name and an atomic
/// rename, so a reader sees either the old file or the whole new one (R3.4).
fn writeScript(io: std.Io, dir: []const u8, script: []const u8) !void {
    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.writeFile(io, .{ .sub_path = "env.sh.tmp", .data = script });
    try folder.rename("env.sh.tmp", folder, "env.sh", io);
}

/// Deletes `dir` and everything in it. A failed delete is ignored because the
/// caller is already failing or ending, and nothing here can report it.
fn removeTree(io: std.Io, dir: []const u8) void {
    // Safe to ignore: the folder is 0o700 and no program reads it after the session ends.
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
}

/// The state script, in two parts. `envScript` writes the names fx adds to
/// every program between them. The test "the bash script keeps the reviewed
/// bytes" pins the whole script by hash, so a change to either part must update
/// that test on purpose. A multiline string has no newline after its last line,
/// so the empty last line of `body_after_skip` supplies the final one.
const body_before_skip =
    \\__fx_env_n=0
    \\for __fx_name in $(compgen -e); do
    \\  __fx_env_names[__fx_env_n]=$__fx_name
    \\  __fx_env_values[__fx_env_n]="${!__fx_name}"
    \\  __fx_env_n=$((__fx_env_n + 1))
    \\done
    \\if [ -r "$__fx_state" ]; then . "$__fx_state" >/dev/null 2>&1; fi
    \\shopt -s expand_aliases
    \\__fx_inherited() {
    \\  local __fx_i=0
    \\  while [ "$__fx_i" -lt "$__fx_env_n" ]; do
    \\    if [ "${__fx_env_names[__fx_i]}" = "$1" ]; then
    \\      [ "${__fx_env_values[__fx_i]}" = "${!1-}" ]
    \\      return
    \\    fi
    \\    __fx_i=$((__fx_i + 1))
    \\  done
    \\  return 1
    \\}
    \\__fx_save() {
    \\  local __fx_rc=$? __fx_name __fx_decl __fx_size __fx_tmp="$__fx_state.$$.tmp" __fx_keep_n=0 __fx_keep=()
    \\  [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return $__fx_rc
    \\  for __fx_name in $(compgen -v); do
    \\    case $__fx_name in
    \\        BASH|BASH_*|BASHOPTS|BASHPID|COLUMNS|COMP_*|DIRSTACK|EPOCHREALTIME|EPOCHSECONDS|EUID|FUNCNAME|GROUPS|HISTCMD|HOSTNAME|HOSTTYPE|IFS|LINENO|LINES|MACHTYPE|OLDPWD|OPTERR|OPTIND|OSTYPE|PIPESTATUS|PPID|PS4|PWD|RANDOM|SECONDS|SHELLOPTS|SHLVL|SRANDOM|UID|_|__fx_*
;

/// The rest of the script, after the names fx adds to every program.
const body_after_skip =
    \\) continue ;;
    \\    esac
    \\    __fx_inherited "$__fx_name" && continue
    \\    __fx_keep[__fx_keep_n]=$__fx_name
    \\    __fx_keep_n=$((__fx_keep_n + 1))
    \\  done
    \\  (
    \\    umask 077
    \\    {
    \\      if [ "$__fx_keep_n" -gt 0 ]; then declare -p "${__fx_keep[@]}" || exit 1; fi
    \\    for __fx_name in $(compgen -A function); do
    \\      case $__fx_name in
    \\        __fx_*|alias|builtin|cd|command|declare|eval|exec|exit|printf|set|shopt|source|trap|unalias|unset|.) continue ;;
    \\      esac
    \\      declare -f "$__fx_name"
    \\    done
    \\    alias -p
    \\    shopt -p
    \\    set +o | while read -r __fx_decl; do case $__fx_decl in *' errexit'|*' posix') ;; *) printf '%s\n' "$__fx_decl" ;; esac; done
    \\    } 2>/dev/null >"$__fx_tmp"
    \\  ) || { rm -f "$__fx_tmp" 2>/dev/null; return $__fx_rc; }
    \\  __fx_size=$(( $(wc -c <"$__fx_tmp") ))
    \\  if [ "$__fx_size" -gt "$__fx_max" ]; then
    \\    rm -f "$__fx_tmp" 2>/dev/null
    \\    printf "fx: this program's bash state is %s bytes, over the %s-byte limit, so it was not saved; the next program starts from the last saved state.\n" "$__fx_size" "$__fx_max" >&2
    \\  else
    \\    if ( umask 077; printf '%s' "$PWD" >"$__fx_folder.$$.tmp" ) 2>/dev/null; then
    \\      mv -f "$__fx_tmp" "$__fx_state" && mv -f "$__fx_folder.$$.tmp" "$__fx_folder" || rm -f "$__fx_folder.$$.tmp" 2>/dev/null
    \\    else
    \\      rm -f "$__fx_tmp" "$__fx_folder.$$.tmp" 2>/dev/null
    \\    fi
    \\  fi
    \\  return $__fx_rc
    \\}
    \\trap __fx_save EXIT
    \\trap() {
    \\  builtin trap "$@" || return $?
    \\  local __fx_line
    \\  __fx_line=$(builtin trap -p EXIT)
    \\  if [ -z "$__fx_line" ]; then
    \\    builtin trap __fx_save EXIT
    \\    return 0
    \\  fi
    \\  eval "set -- $__fx_line"
    \\  case $3 in
    \\    __fx_save|__fx_save$'\n'*) return 0 ;;
    \\  esac
    \\  builtin trap "__fx_save
    \\$3" EXIT
    \\}
    \\
;

test "wait_more is the whole code, ignoring spaces and line ends" {
    try std.testing.expect(isWaitMore("wait_more"));
    try std.testing.expect(isWaitMore(" wait_more\n"));
    try std.testing.expect(!isWaitMore("wait_more; ls"));
    try std.testing.expect(!isWaitMore("echo wait_more"));
    try std.testing.expect(!isWaitMore(""));
}

test "bashPath keeps an absolute bash and falls back to /bin/bash" {
    try std.testing.expectEqualStrings("/usr/local/bin/bash", bashPath("/usr/local/bin/bash"));
    try std.testing.expectEqualStrings("/bin/bash", bashPath("/bin/zsh"));
    try std.testing.expectEqualStrings("/bin/bash", bashPath(null));
    try std.testing.expectEqualStrings("/bin/bash", bashPath("bash"));
}

test "envScript quotes the state path, keeps the header, and installs the save trap" {
    const alloc = std.testing.allocator;
    const script = try envScript(alloc, "/tmp/a'b/state.sh", "/tmp/a'b/folder", &test_fx_variables);
    defer alloc.free(script);
    var lines = std.mem.splitScalar(u8, script, '\n');
    try std.testing.expectEqualStrings("# fx bash tool: load the bash state the last program saved, and save it again", lines.next().?);
    try std.testing.expectEqualStrings("# when this program ends (tests/tla/bash_tool/ResultStore.tla Finish).", lines.next().?);
    try std.testing.expectEqualStrings("__fx_state='/tmp/a'\\''b/state.sh'", lines.next().?);
    try std.testing.expectEqualStrings("__fx_folder='/tmp/a'\\''b/folder'", lines.next().?);
    try std.testing.expect(std.mem.find(u8, script, "trap __fx_save EXIT\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, script, "}\n"));
}

test "the bash script keeps the reviewed bytes" {
    const script = try envScript(std.testing.allocator, "/tmp/fx-pinned/state.sh", "/tmp/fx-pinned/folder", &test_fx_variables);
    defer std.testing.allocator.free(script);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("80cec24b9ca8c26bde289d5156d430f203d59e676c085c683497e643c12c9f6a", &hex);
}

test "prepare refuses a relative temp root and leaves no session" {
    var session = Session.init(std.testing.allocator);
    try std.testing.expectError(error.RelativeTmpRoot, session.prepare(std.testing.io, "relative/root", &.{}));
    try std.testing.expect(session.dir == null);
}

test "deinit deletes the session folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    _ = try session.prepare(io, root, &.{});
    const dir = try alloc.dupe(u8, session.dir.?);
    defer alloc.free(dir);
    session.deinit(io);
    try std.testing.expect(session.dir == null and session.env_path == null);
    if (std.Io.Dir.cwd().openDir(io, dir, .{})) |opened| {
        var folder = opened;
        folder.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
}

const program_one =
    \\x="two words"; export Y=exported; arr=(a "b c"); f() { echo "f says $1"; }; alias ll="echo alias-ok"; shopt -s nullglob; set -u; set -e; cd "sub dir"; exit 3
;
const program_two =
    \\echo "x=$x Y=$Y arr1=${arr[1]} pwd=$(basename "$PWD")"; f hi; ll; shopt -q nullglob && echo nullglob-on; [[ $- == *u* ]] && echo nounset-on; [[ $- == *e* ]] && echo errexit-on || echo errexit-off; echo token=$FX_MCP_CALL_TOKEN
;
const program_three =
    \\x=changed; kill -9 $$
;
const program_four =
    \\echo "x=$x"
;
const expected_two = "x=two words Y=exported arr1=b c pwd=sub dir\nf says hi\nalias-ok\nnullglob-on\nnounset-on\nerrexit-off\ntoken=t2\n";

/// Runs `program` as one bash tool program of `session`, in `cwd`, with the
/// environment a program gets: PATH, BASH_ENV, and the call token. The caller
/// frees the result with `freeRun`.
fn runProgram(alloc: std.mem.Allocator, io: std.Io, session: *const Session, cwd: []const u8, token: []const u8, program: []const u8) !std.process.RunResult {
    return runProgramWithEnv(alloc, io, session, cwd, token, &.{}, program);
}

/// Runs `program` like `runProgram`, with `extra` added to the environment the
/// program inherits, as fx's own environment would pass it.
fn runProgramWithEnv(alloc: std.mem.Allocator, io: std.Io, session: *const Session, cwd: []const u8, token: []const u8, extra: []const [2][]const u8, program: []const u8) !std.process.RunResult {
    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");
    try environ.put(env_var, session.bashEnv().?);
    try environ.put("FX_MCP_CALL_TOKEN", token);
    for (extra) |pair| try environ.put(pair[0], pair[1]);
    return std.process.run(alloc, io, .{
        .argv = &.{ "/bin/bash", "--noprofile", "--norc", "-c", program },
        .cwd = .{ .path = cwd },
        .environ_map = &environ,
    });
}

fn freeRun(alloc: std.mem.Allocator, result: std.process.RunResult) void {
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

/// Fails unless the program exited with `code`. On a mismatch it prints the
/// program's stderr, so the cause shows in the test output.
fn expectExit(result: std.process.RunResult, code: u8) !void {
    switch (result.term) {
        .exited => |actual| if (actual != code) {
            std.debug.print("exit {d}, want {d}; stderr: {s}\n", .{ actual, code, result.stderr });
            return error.TestUnexpectedExit;
        },
        else => {
            std.debug.print("not an exit; stderr: {s}\n", .{result.stderr});
            return error.TestUnexpectedExit;
        },
    }
}

test "a bash tool program saves its state for the next, and a killed one saves nothing" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.createDir(io, "sub dir", .default_dir);

    const first = try runProgram(alloc, io, &session, dir, "t1", program_one);
    defer freeRun(alloc, first);
    try expectExit(first, 3);

    // fx starts each program in the folder the last saved program ended in.
    session.refreshStartFolder(io);
    const start = session.startFolder() orelse dir;

    const second = try runProgram(alloc, io, &session, start, "t2", program_two);
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings(expected_two, second.stdout);

    const third = try runProgram(alloc, io, &session, start, "t3", program_three);
    defer freeRun(alloc, third);
    switch (third.term) {
        .signal => {},
        else => return error.TestUnexpectedExit,
    }

    const fourth = try runProgram(alloc, io, &session, start, "t4", program_four);
    defer freeRun(alloc, fourth);
    try expectExit(fourth, 0);
    try std.testing.expectEqualStrings("x=two words\n", fourth.stdout);

    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "FX_MCP_CALL_TOKEN") == null);
    try std.testing.expect(std.mem.find(u8, state, "declare -r") == null);
}

test "a program's own EXIT trap keeps fx's save, and its handler sees the exit status" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const bye = try runProgram(alloc, io, &session, dir, "trap1", "trap 'echo \"bye rc=$?\"' EXIT; a=1");
    defer freeRun(alloc, bye);
    try expectExit(bye, 0);
    try std.testing.expectEqualStrings("bye rc=0\n", bye.stdout);

    const sees_a = try runProgram(alloc, io, &session, dir, "trap2", "echo \"a=$a\"");
    defer freeRun(alloc, sees_a);
    try expectExit(sees_a, 0);
    try std.testing.expectEqualStrings("a=1\n", sees_a.stdout);

    const exits = try runProgram(alloc, io, &session, dir, "trap3", "trap 'exit 3' EXIT; b=2");
    defer freeRun(alloc, exits);
    try expectExit(exits, 3);

    const sees_b = try runProgram(alloc, io, &session, dir, "trap4", "echo \"b=$b\"");
    defer freeRun(alloc, sees_b);
    try expectExit(sees_b, 0);
    try std.testing.expectEqualStrings("b=2\n", sees_b.stdout);

    const reset = try runProgram(alloc, io, &session, dir, "trap5", "trap - EXIT; c=3");
    defer freeRun(alloc, reset);
    try expectExit(reset, 0);

    const sees_c = try runProgram(alloc, io, &session, dir, "trap6", "echo \"a=$a b=$b c=$c\"");
    defer freeRun(alloc, sees_c);
    try expectExit(sees_c, 0);
    try std.testing.expectEqualStrings("a=1 b=2 c=3\n", sees_c.stdout);
}

test "a subshell that sets its own EXIT trap never saves state" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const sub = try runProgram(alloc, io, &session, dir, "sub1", "( trap 'true' EXIT; d=4 ); e=5");
    defer freeRun(alloc, sub);
    try expectExit(sub, 0);

    const sees = try runProgram(alloc, io, &session, dir, "sub2", "echo \"d=${d:-none} e=$e\"");
    defer freeRun(alloc, sees);
    try expectExit(sees, 0);
    try std.testing.expectEqualStrings("d=none e=5\n", sees.stdout);
}

test "a subshell's state is never kept when its program is killed after it" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    // The main shell never saves after kill -9, so only a subshell's save could keep d.
    const killed = try runProgram(alloc, io, &session, dir, "subkill1", "( trap 'true' EXIT; d=4 ); e=5; kill -9 $$");
    defer freeRun(alloc, killed);
    switch (killed.term) {
        .signal => {},
        else => return error.TestUnexpectedExit,
    }

    const sees = try runProgram(alloc, io, &session, dir, "subkill2", "echo \"d=${d:-none} e=${e:-none}\"");
    defer freeRun(alloc, sees);
    try expectExit(sees, 0);
    try std.testing.expectEqualStrings("d=none e=none\n", sees.stdout);
}

test "variables fx passes in are never saved, and the program's own exports are" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const inherited = try runProgramWithEnv(alloc, io, &session, dir, "env1", &.{.{ "SECRET_TOKEN", "xyz" }}, "echo \"got=$SECRET_TOKEN\"");
    defer freeRun(alloc, inherited);
    try expectExit(inherited, 0);
    try std.testing.expectEqualStrings("got=xyz\n", inherited.stdout);

    const exported = try runProgram(alloc, io, &session, dir, "env2", "export MINE=1");
    defer freeRun(alloc, exported);
    try expectExit(exported, 0);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "xyz") == null);
    try std.testing.expect(std.mem.find(u8, state, "MINE=\"1\"") != null);
}

test "the saved state is readable by its owner only" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const run = try runProgram(alloc, io, &session, dir, "mode1", "x=1");
    defer freeRun(alloc, run);
    try expectExit(run, 0);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const stat = try folder.statFile(io, "state.sh", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "a program that sets 300 variables has all of them restored" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const set = try runProgram(alloc, io, &session, dir, "many1", "for ((i = 1; i <= 300; i++)); do eval \"v$i=$i\"; done");
    defer freeRun(alloc, set);
    try expectExit(set, 0);

    const check = try runProgram(alloc, io, &session, dir, "many2", "n=0; for ((i = 1; i <= 300; i++)); do eval \"x=\\${v$i}\"; [ \"$x\" = \"$i\" ] && n=$((n + 1)); done; echo \"n=$n\"");
    defer freeRun(alloc, check);
    try expectExit(check, 0);
    try std.testing.expectEqualStrings("n=300\n", check.stdout);
}

test "the start folder is the folder the last saved program ended in" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const moved = try runProgram(alloc, io, &session, dir, "folder1", "cd /");
    defer freeRun(alloc, moved);
    try expectExit(moved, 0);

    session.refreshStartFolder(io);
    try std.testing.expectEqualStrings("/", session.startFolder() orelse return error.TestNoStartFolder);
}

test "a program over the size cap leaves the start folder unchanged" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "folder2", "cd /");
    defer freeRun(alloc, first);
    try expectExit(first, 0);
    session.refreshStartFolder(io);
    try std.testing.expectEqualStrings("/", session.startFolder() orelse return error.TestNoStartFolder);

    const big = try runProgram(alloc, io, &session, dir, "folder3", "cd /tmp; big=$(head -c 1100000 /dev/zero | tr '\\0' a)");
    defer freeRun(alloc, big);
    try expectExit(big, 0);
    try std.testing.expect(std.mem.startsWith(u8, big.stderr, "fx: this program's bash state is "));

    session.refreshStartFolder(io);
    try std.testing.expectEqualStrings("/", session.startFolder() orelse return error.TestNoStartFolder);
}

test "a folder file that names a removed directory gives no start folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    session.refreshStartFolder(io);
    try std.testing.expect(session.startFolder() == null);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.writeFile(io, .{ .sub_path = folder_file, .data = "/fx-bash-no-such-folder" });
    session.refreshStartFolder(io);
    try std.testing.expect(session.startFolder() == null);
}

test "the saved state holds no cd line" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, "/bin/bash", .{}) catch return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const moved = try runProgram(alloc, io, &session, dir, "folder4", "cd /");
    defer freeRun(alloc, moved);
    try expectExit(moved, 0);

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "cd --") == null);
}

test "prepare refuses a temp root with a dollar sign, a backquote, or a backslash" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var session = Session.init(alloc);
    defer session.deinit(io);
    for ([_][]const u8{ "/tmp/a$b", "/tmp/a`b", "/tmp/a\\b" }) |root| {
        try std.testing.expectError(error.UnsafeTmpRoot, session.prepare(io, root, &.{}));
        try std.testing.expect(session.dir == null);
    }
}

test "setting a program twice frees the first id" {
    var session = Session.init(std.testing.allocator);
    defer session.deinit(std.testing.io);
    try session.setProgram("first");
    try session.setProgram("second");
    try std.testing.expectEqualStrings("second", session.program().?);
}

test "deinit frees the program id and leaves none" {
    var session = Session.init(std.testing.allocator);
    try session.setProgram("first");
    session.deinit(std.testing.io);
    try std.testing.expect(session.program() == null);
}

test "prepare removes a folder a dead process left in the temp root" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    try tmp.dir.createDir(io, "fx-bash-2147483646-dead", .default_dir);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &.{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "fx-bash-2147483646-dead", .{}));
}

test "prepare keeps the folders of this process and of a live process" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const own_name = try alloc.print("fx-bash-{d}-live", .{processId()});
    defer alloc.free(own_name);
    try tmp.dir.createDir(io, own_name, .default_dir);
    try tmp.dir.createDir(io, "fx-bash-1-live", .default_dir);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &.{});
    try tmp.dir.access(io, own_name, .{});
    try tmp.dir.access(io, "fx-bash-1-live", .{});
}

test "prepare never follows or removes a link named like a bash folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    try tmp.dir.createDir(io, "target", .default_dir);
    var target = try tmp.dir.openDir(io, "target", .{});
    defer target.close(io);
    try target.writeFile(io, .{ .sub_path = "keep.txt", .data = "kept" });
    const target_path = try alloc.print("{s}/target", .{root});
    defer alloc.free(target_path);
    try tmp.dir.symLink(io, target_path, "fx-bash-2147483646-link", .{ .is_directory = true });

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &.{});

    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = try tmp.dir.readLink(io, "fx-bash-2147483646-link", &link_buffer);
    const kept = try target.readFileAlloc(io, "keep.txt", alloc, .limited(64));
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("kept", kept);
}

test "prepare keeps a file named like a bash folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "fx-bash-2147483646-file", .data = "x" });

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &.{});
    try tmp.dir.access(io, "fx-bash-2147483646-file", .{});
}

test "a new bash folder is named with this process's id" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &.{});
    const name = std.Io.Dir.path.basename(session.dir.?);
    const prefix = try alloc.print("fx-bash-{d}-", .{processId()});
    defer alloc.free(prefix);
    try std.testing.expect(std.mem.startsWith(u8, name, prefix));
    try std.testing.expectEqual(@as(usize, 16), name.len - prefix.len);
    try std.testing.expectEqual(processId(), folderOwner(name).?);
}

/// The names the tests pass as fx's own: the same three `bash.zig` passes.
const test_fx_variables = [_][]const u8{ "AI_AGENT", "FX_MCP_CALL_SOCKET", "FX_MCP_CALL_TOKEN" };

test "a state over the size cap is not saved, and the program says so" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const first = try runProgram(alloc, io, &session, dir, "big1", "x=1");
    defer freeRun(alloc, first);
    try expectExit(first, 0);

    const big = try runProgram(alloc, io, &session, dir, "big2", "big=$(head -c 1100000 /dev/zero | tr '\\0' a)");
    defer freeRun(alloc, big);
    try expectExit(big, 0);
    try std.testing.expect(std.mem.startsWith(u8, big.stderr, "fx: this program's bash state is "));
    try std.testing.expect(std.mem.endsWith(u8, big.stderr, "bytes, over the 1048576-byte limit, so it was not saved; the next program starts from the last saved state.\n"));

    const after = try runProgram(alloc, io, &session, dir, "big3", "echo \"x=${x:-unset} big=${big:-none}\"");
    defer freeRun(alloc, after);
    try expectExit(after, 0);
    try std.testing.expectEqualStrings("x=1 big=none\n", after.stdout);
}

test "a program that ends after its folder is gone saves nothing and prints nothing" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const program = try alloc.print("rm -rf -- '{s}'; x=2", .{dir});
    defer alloc.free(program);
    const run = try runProgram(alloc, io, &session, root, "gone", program);
    defer freeRun(alloc, run);
    try expectExit(run, 0);
    try std.testing.expectEqualStrings("", run.stderr);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, dir, .{}));
}

test "variables fx adds to every program are not restored in the next one" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    var session = Session.init(alloc);
    defer session.deinit(io);
    _ = try session.prepare(io, root, &test_fx_variables);
    const dir = session.dir.?;

    const set = try runProgram(alloc, io, &session, dir, "fx1", "export AI_AGENT=fx FX_MCP_CALL_SOCKET=/tmp/sock FX_KEEP=yes");
    defer freeRun(alloc, set);
    try expectExit(set, 0);

    const read = try runProgram(alloc, io, &session, dir, "fx2", "echo \"agent=${AI_AGENT:-unset} sock=${FX_MCP_CALL_SOCKET:-unset} keep=${FX_KEEP:-unset}\"");
    defer freeRun(alloc, read);
    try expectExit(read, 0);
    try std.testing.expectEqualStrings("agent=unset sock=unset keep=yes\n", read.stdout);
}

test "prepare refuses a variable name that is not a plain word" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    for ([_][]const u8{ "", "BAD NAME", "A|B", "A-B" }) |name| {
        var session = Session.init(alloc);
        defer session.deinit(io);
        try std.testing.expectError(error.InvalidVariableName, session.prepare(io, root, &.{name}));
        try std.testing.expect(session.dir == null);
    }
    var entries = tmp.dir.iterate();
    try std.testing.expect((try entries.next(io)) == null);
}
