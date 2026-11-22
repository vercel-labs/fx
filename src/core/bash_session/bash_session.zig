//! One agent's saved bash state for the one bash tool. Each bash tool program
//! is one captured bash command. Its BASH_ENV script loads the state the last
//! program saved and saves it again when the program ends, so a program killed
//! by a signal saves nothing (`tests/tla/bash_tool/ResultStore.tla` `Finish`,
//! `StateNeverTorn`, `EndedSaves`). The state never holds the MCP token. This
//! module imports only `std`, so `zig test` runs its tests alone.
const std = @import("std");

/// The whole code a program sends to wait for the program that is running.
pub const wait_word = "wait_more";

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

/// The BASH_ENV script for a session whose state file is `state_path`. The
/// caller owns the result. A `'` in the path becomes `'\''`, so the path stays
/// one shell word.
pub fn envScript(alloc: std.mem.Allocator, state_path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, env_header);
    try out.appendSlice(alloc, "__fx_state='");
    for (state_path) |byte| {
        if (byte == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, byte);
        }
    }
    try out.appendSlice(alloc, "'\n");
    try out.appendSlice(alloc, body);
    return out.toOwnedSlice(alloc);
}

/// One agent's bash session: its private folder and its BASH_ENV script. The
/// folder is made by `prepare` and deleted by `deinit`.
pub const Session = struct {
    /// Makes and frees this session's paths; it lives as long as the session.
    alloc: std.mem.Allocator,
    /// The private folder, `<tmp_root>/fx-bash-<16 hex digits>`. Owned.
    dir: ?[]u8 = null,
    /// `<dir>/env.sh`, the BASH_ENV script. Owned.
    env_path: ?[]u8 = null,
    /// The id of this session's last program, so a new program waits its
    /// turn and wait_more finds it. Owned.
    program_id: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator) Session {
        return .{ .alloc = alloc };
    }

    /// Makes the folder and writes its script, once. `tmp_root` must be an
    /// absolute path, because the script names the state file by its full
    /// path. On failure nothing is left behind and the session stays unprepared.
    pub fn prepare(self: *Session, io: std.Io, tmp_root: []const u8) !void {
        if (self.dir != null) return;
        const alloc = self.alloc;
        if (!std.Io.Dir.path.isAbsolute(tmp_root)) return error.RelativeTmpRoot;
        var suffix: [8]u8 = undefined;
        io.random(&suffix);
        const hex = std.fmt.bytesToHex(suffix, .lower);
        const dir = try alloc.print("{s}/fx-bash-{s}", .{ tmp_root, &hex });
        errdefer alloc.free(dir);
        const env_path = try alloc.print("{s}/env.sh", .{dir});
        errdefer alloc.free(env_path);
        const state_path = try alloc.print("{s}/state.sh", .{dir});
        defer alloc.free(state_path);
        const script = try envScript(alloc, state_path);
        defer alloc.free(script);

        try std.Io.Dir.cwd().createDir(io, dir, .fromMode(0o700));
        errdefer removeTree(io, dir);
        try writeScript(io, dir, script);

        self.dir = dir;
        self.env_path = env_path;
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
    pub fn deinit(self: *Session, io: std.Io) void {
        const alloc = self.alloc;
        if (self.dir) |dir| {
            removeTree(io, dir);
            alloc.free(dir);
        }
        if (self.env_path) |path| alloc.free(path);
        if (self.program_id) |id| alloc.free(id);
        self.* = .{ .alloc = alloc };
    }
};

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

/// The state script. The test "the bash body keeps the reviewed bytes" pins
/// it by hash, so a change to it must update that test on purpose. A
/// multiline string has no newline after its last line, so the empty last
/// line supplies the final one.
const body =
    \\if [ -r "$__fx_state" ]; then . "$__fx_state" >/dev/null 2>&1; fi
    \\shopt -s expand_aliases
    \\__fx_save() {
    \\  local __fx_name __fx_decl __fx_flags __fx_tmp="$__fx_state.$$.tmp"
    \\  {
    \\    for __fx_name in $(compgen -v); do
    \\      case $__fx_name in
    \\        BASH|BASH_*|BASHOPTS|BASHPID|COLUMNS|COMP_*|DIRSTACK|EPOCHREALTIME|EPOCHSECONDS|EUID|FUNCNAME|GROUPS|HISTCMD|HOSTNAME|HOSTTYPE|IFS|LINENO|LINES|MACHTYPE|OLDPWD|OPTERR|OPTIND|OSTYPE|PIPESTATUS|PPID|PS4|PWD|RANDOM|SECONDS|SHELLOPTS|SHLVL|SRANDOM|UID|_|__fx_*|AI_AGENT|FX_MCP_CALL_*) continue ;;
    \\      esac
    \\      __fx_decl=$(declare -p "$__fx_name" 2>/dev/null) || continue
    \\      __fx_flags=${__fx_decl#declare -}
    \\      __fx_flags=${__fx_flags%% *}
    \\      case $__fx_flags in *r*) continue ;; esac
    \\      printf '%s\n' "$__fx_decl"
    \\    done
    \\    for __fx_name in $(compgen -A function); do
    \\      case $__fx_name in
    \\        __fx_*|alias|builtin|cd|command|declare|eval|exec|exit|printf|set|shopt|source|trap|unalias|unset|.) continue ;;
    \\      esac
    \\      declare -f "$__fx_name"
    \\    done
    \\    alias -p
    \\    shopt -p
    \\    set +o | while read -r __fx_decl; do case $__fx_decl in *' errexit'|*' posix') ;; *) printf '%s\n' "$__fx_decl" ;; esac; done
    \\    printf 'cd -- %q 2>/dev/null\n' "$PWD"
    \\  } >"$__fx_tmp" 2>/dev/null && mv -f "$__fx_tmp" "$__fx_state"
    \\}
    \\trap __fx_save EXIT
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

test "envScript quotes the state path, keeps the header, and ends with the trap" {
    const alloc = std.testing.allocator;
    const script = try envScript(alloc, "/tmp/a'b/state.sh");
    defer alloc.free(script);
    var lines = std.mem.splitScalar(u8, script, '\n');
    try std.testing.expectEqualStrings("# fx bash tool: load the bash state the last program saved, and save it again", lines.next().?);
    try std.testing.expectEqualStrings("# when this program ends (tests/tla/bash_tool/ResultStore.tla Finish).", lines.next().?);
    try std.testing.expectEqualStrings("__fx_state='/tmp/a'\\''b/state.sh'", lines.next().?);
    try std.testing.expect(std.mem.endsWith(u8, script, "trap __fx_save EXIT\n"));
}

test "the bash body keeps the reviewed bytes" {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("2f54bf0975beeab8c152854d4e1b9b6db087fbfec34c2ade7d3bea42b439e9c1", &hex);
}

test "prepare refuses a relative temp root and leaves no session" {
    var session = Session.init(std.testing.allocator);
    try std.testing.expectError(error.RelativeTmpRoot, session.prepare(std.testing.io, "relative/root"));
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
    try session.prepare(io, root);
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
    var environ = std.process.Environ.Map.init(alloc);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");
    try environ.put("BASH_ENV", session.bashEnv().?);
    try environ.put("FX_MCP_CALL_TOKEN", token);
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
    try session.prepare(io, root);
    const dir = session.dir.?;

    var folder = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer folder.close(io);
    try folder.createDir(io, "sub dir", .default_dir);

    const first = try runProgram(alloc, io, &session, dir, "t1", program_one);
    defer freeRun(alloc, first);
    try expectExit(first, 3);

    const second = try runProgram(alloc, io, &session, dir, "t2", program_two);
    defer freeRun(alloc, second);
    try expectExit(second, 0);
    try std.testing.expectEqualStrings(expected_two, second.stdout);

    const third = try runProgram(alloc, io, &session, dir, "t3", program_three);
    defer freeRun(alloc, third);
    switch (third.term) {
        .signal => {},
        else => return error.TestUnexpectedExit,
    }

    const fourth = try runProgram(alloc, io, &session, dir, "t4", program_four);
    defer freeRun(alloc, fourth);
    try expectExit(fourth, 0);
    try std.testing.expectEqualStrings("x=two words\n", fourth.stdout);

    const state = try folder.readFileAlloc(io, "state.sh", alloc, .limited(1 << 20));
    defer alloc.free(state);
    try std.testing.expect(std.mem.find(u8, state, "FX_MCP_CALL_TOKEN") == null);
    try std.testing.expect(std.mem.find(u8, state, "declare -r") == null);
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
