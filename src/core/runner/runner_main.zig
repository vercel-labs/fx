//! The built-in remote runner's process, `fx __fx_runner__ run …` (spec 3.5,
//! L1 to L7). Block 5e2 has the command line, the contract (N12), the login
//! check (V1, N10), the push (V2 to V5), the extend before exec (V12), and the
//! exec with its reattach and stop (V6 to V10). Outside this folder, code imports
//! only `runner.zig`.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const io_mod = @import("../shared/io.zig");
const vercel = @import("vercel/vercel.zig");
const sha256 = @import("sha256.zig");
const text_utils = @import("../shared/text_utils.zig");
const cli_flags = @import("../cli/cli_flags.zig");
const flags = @import("flags.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const OptionDoc = @import("../slash_commands/command_specs.zig").OptionDoc;

/// The word after the binary name that selects this process (L4).
pub const subcommand = "__fx_runner__";
/// The only contract this runner speaks (L1). Any other value gives N12.
pub const contract_version = "1";
/// Every refusal exits with this code: the command did not run (L6).
pub const exit_did_not_run: u8 = 125;
/// The command may have run, and its result is unknown (L6, V7).
pub const exit_unknown: u8 = 255;
/// A stop, by SIGTERM (V10).
pub const exit_stopped: u8 = 143;
/// The longest team or project id the command line may carry.
const max_id_bytes: usize = 256;
/// The length of a repo key: the sixteen lowercase hex digits that name the state folder (L5).
const repo_key_bytes: usize = 16;

const Allocator = std.mem.Allocator;

/// The options of L1, read through `cli_flags`: one list, one parser (fx-cli-shape). Each
/// flag maps to a `Flag` field, and `flag_ids` fails to compile when the two differ. The
/// runner's grammar is internal: the host writes it, and only the runner reads it.
const runner_options = [_]OptionDoc{
    .{ .flag = "--contract <version>", .description = "the contract version the host speaks" },
    .{ .flag = "--mode <mode>", .description = "remote or isolated" },
    .{ .flag = "--root <path>", .description = "the workspace root" },
    .{ .flag = "--cwd <path>", .description = "the working folder inside the root" },
    .{ .flag = "--state <path>", .description = "the keyed state folder" },
    .{ .flag = "--team <id>", .description = "the Vercel team id" },
    .{ .flag = "--project <id>", .description = "the Vercel project id" },
    .{ .flag = "--token-sha256 <hex>", .description = "the SHA-256 of the login token" },
    .{ .flag = "--team-slug <slug>", .description = "the team slug" },
    .{ .flag = "--project-name <name>", .description = "the project name" },
    .{ .flag = "--user-id <id>", .description = "the Vercel user id" },
    .{ .flag = "--grace-ms <ms>", .description = "the stop grace in milliseconds" },
    .{ .flag = "--timeout-ms <ms>", .description = "the command timeout in milliseconds" },
    .{ .flag = "--vcpus <count>", .description = "the sandbox size" },
    .{ .flag = "--env <name>", .description = "a variable passed to the command" },
    .{ .flag = "--profile <name>", .description = "the isolated profile; its arguments follow" },
    .{ .flag = "--include <path>", .description = "a path to send" },
    .{ .flag = "--bring-back <path>", .description = "a path to bring back" },
};

const Flag = enum {
    contract,
    mode,
    root,
    cwd,
    state,
    team,
    project,
    token_sha256,
    team_slug,
    project_name,
    user_id,
    grace_ms,
    timeout_ms,
    vcpus,
    env,
    profile,
    include,
    bring_back,
};

const flag_ids = cli_flags.idTable(Flag, &runner_options);
const flag_count = @typeInfo(Flag).@"enum".field_names.len;

/// The flags that must be given once. `timeout_ms` and `vcpus` may be absent.
const required_flags = [_]Flag{
    .contract, .mode, .root, .cwd, .state, .team, .project, .token_sha256, .team_slug, .project_name, .user_id, .grace_ms,
};

/// The name a flag is written with on the line, such as `--env`.
fn nameOf(flag: Flag) []const u8 {
    for (flag_ids, 0..) |id, index| {
        if (id == flag) return cli_flags.flagName(runner_options[index]);
    }
    unreachable;
}

const env_flag = nameOf(.env);
const profile_flag = nameOf(.profile);

pub const Mode = enum { remote, isolated };

pub const Profile = struct {
    name: []const u8,
    args: []const []const u8,
};

/// One parsed command line. Its slices point into the argument list or the arena.
pub const Command = struct {
    mode: Mode,
    root: []const u8,
    cwd: []const u8,
    state: []const u8,
    team: []const u8,
    project: []const u8,
    token_sha256: []const u8,
    team_slug: []const u8,
    project_name: []const u8,
    /// `--user-id`: the Vercel user the host logged in as (I1 host key).
    user_id: []const u8,
    /// `--grace-ms`: the stop budget is this less 200 ms (V10).
    grace_ms: i64,
    /// `--timeout-ms`: the call's timeout, or null for the 5-hour default (V6).
    timeout_ms: ?i64,
    /// `--include` paths, sent even when git ignores them (V5).
    include: []const []const u8,
    /// `--bring-back` paths, only counted on the way back (V9). Used by block 5f.
    bring_back: []const []const u8,
    /// `--vcpus`. Used by block 5g.
    vcpus: ?u8,
    profile: ?Profile,
    env: []const []const u8,
    command: []const u8,
};

/// Why the runner did not run. Each is one line on stderr, and the exit code is 125.
pub const Refusal = union(enum) {
    /// No `--contract 1` (L4, AC-26): this is not the runner the host expects. N12.
    contract,
    /// A flag, value or command is wrong. The detail is a fixed phrase or names a
    /// flag from the option list; argument text is never echoed.
    bad_arguments: []const u8,
    /// The login is missing, expired, or not the one the host approved (V1). N10.
    login_changed,
};

pub const Parsed = union(enum) {
    command: Command,
    refused: Refusal,
};

/// The environment and disk values the login check reads. Tests pass fakes.
pub const Inputs = struct {
    env: vercel.Env,
    files: vercel.Files,
    now_unix_s: i64,
};

/// Parses the words after the subcommand (L1). `args[0]` must be `run`. The
/// contract is checked first, so an older host's line gets N12 whatever its other
/// flags are (AC-26).
pub fn parse(arena: Allocator, args: []const []const u8) Allocator.Error!Parsed {
    const words = try flags.sentinelWords(arena, args);
    if (!contractIsSupported(words)) return .{ .refused = .contract };
    if (args.len == 0 or !std.mem.eql(u8, args[0], "run")) {
        return badArguments("the first word after the subcommand is not run");
    }

    var values: [flag_count]?[]const u8 = @splat(null);
    var env: std.ArrayList([]const u8) = .empty;
    var include: std.ArrayList([]const u8) = .empty;
    var bring_back: std.ArrayList([]const u8) = .empty;
    var profile: ?Profile = null;
    var command: ?[]const u8 = null;
    // `words[i]` is `args[i + 1]`: the parser reads the words after `run`.
    var parser = cli_flags.Parser.init(&runner_options, words[1..]);
    while (true) {
        const before = parser.index;
        const item = parser.next() catch return parseFailure(arena, parser.failure.?);
        const found = item orelse break;
        switch (found) {
            .positional => |word| {
                if (!parser.options_ended) return badArguments("an unknown flag is given");
                if (command != null) return badArguments("the command must follow -- as exactly one word");
                command = word;
            },
            .option => |match| {
                const flag = flag_ids[match.index].?;
                const name = cli_flags.flagName(runner_options[match.index]);
                // `--flag=value` is not the L1 form, so it is an unknown flag.
                if (parser.index - before == 1) return badArguments("an unknown flag is given");
                const text = match.value.?;
                switch (flag) {
                    .env => try env.append(arena, text),
                    .include, .bring_back => {
                        var diagnostic: config.Diagnostic = .{};
                        config.validatePath(arena, &diagnostic, text, name) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.InvalidSandboxConfig => return badArguments(diagnostic.message),
                        };
                        const list = if (flag == .include) &include else &bring_back;
                        try list.append(arena, text);
                    },
                    .profile => {
                        if (profile != null) return badArguments("--profile is given twice");
                        // The profile's arguments are opaque words: they run to the next --env or --.
                        const start = parser.index;
                        var end = start;
                        while (end < parser.args.len and !std.mem.eql(u8, parser.args[end], env_flag) and !std.mem.eql(u8, parser.args[end], "--")) : (end += 1) {}
                        profile = .{ .name = text, .args = args[start + 1 .. end + 1] };
                        parser.index = end;
                    },
                    else => {
                        if (values[@backingInt(flag)] != null) return badNamed(arena, "{s} is given twice", name);
                        values[@backingInt(flag)] = text;
                    },
                }
            },
        }
    }

    if (parser.options_ended and command == null) return badArguments("the command must follow -- as exactly one word");
    const cmd = command orelse return badArguments("the command after -- is missing");
    for (required_flags) |flag| {
        if (values[@backingInt(flag)] == null) return badNamed(arena, "{s} is missing", nameOf(flag));
    }
    const mode_text = value(values, .mode);
    const mode: Mode = if (std.mem.eql(u8, mode_text, "remote"))
        .remote
    else if (std.mem.eql(u8, mode_text, "isolated"))
        .isolated
    else
        return badArguments("--mode is not remote or isolated");
    for ([_]Flag{ .root, .cwd, .state }) |flag| {
        if (!std.Io.Dir.path.isAbsolute(value(values, flag))) {
            return badNamed(arena, "{s} is not an absolute path", nameOf(flag));
        }
    }
    if (!isRepoKey(std.Io.Dir.path.basename(value(values, .state)))) {
        return badArguments("the state folder name is not a 16-digit lowercase hex repo key");
    }
    for ([_]Flag{ .team, .project, .team_slug, .project_name, .user_id }) |flag| {
        const id = value(values, flag);
        if (id.len == 0 or id.len > max_id_bytes) {
            return badNamed(arena, "{s} is empty or too long", nameOf(flag));
        }
    }
    if (!sha256.isHexDigest(value(values, .token_sha256))) {
        return badArguments("--token-sha256 is not 64 lowercase hex digits");
    }
    const grace_ms = wholeNumber(value(values, .grace_ms), 0) orelse {
        return badArguments("--grace-ms is not a whole number of milliseconds");
    };
    const timeout_ms: ?i64 = if (values[@backingInt(Flag.timeout_ms)]) |text|
        wholeNumber(text, 1) orelse return badArguments("--timeout-ms is not a whole number of milliseconds above 0")
    else
        null;
    const vcpus: ?u8 = if (values[@backingInt(Flag.vcpus)]) |text|
        parseVcpus(text) orelse return badArguments("--vcpus is not a whole number from 1 to 255")
    else
        null;
    if (cmd.len == 0) return badArguments("the command is empty");
    if (profile) |selected| {
        if (selected.name.len == 0) return badArguments("--profile needs a name");
    }
    for (env.items) |name| {
        if (name.len == 0 or std.mem.findScalar(u8, name, '=') != null) {
            return badArguments("--env needs a name without =");
        }
    }
    return .{ .command = .{
        .mode = mode,
        .root = value(values, .root),
        .cwd = value(values, .cwd),
        .state = value(values, .state),
        .team = value(values, .team),
        .project = value(values, .project),
        .token_sha256 = value(values, .token_sha256),
        .team_slug = value(values, .team_slug),
        .project_name = value(values, .project_name),
        .user_id = value(values, .user_id),
        .grace_ms = grace_ms,
        .timeout_ms = timeout_ms,
        .include = include.items,
        .bring_back = bring_back.items,
        .vcpus = vcpus,
        .profile = profile,
        .env = env.items,
        .command = cmd,
    } };
}

/// The refusal for a word `cli_flags` could not read, with the text the runner has
/// always given for it.
fn parseFailure(arena: Allocator, failure: cli_flags.Failure) Allocator.Error!Parsed {
    switch (failure) {
        .missing_value => |flag| {
            if (std.mem.eql(u8, flag, env_flag)) return badArguments("--env needs a name");
            if (std.mem.eql(u8, flag, profile_flag)) return badArguments("--profile needs a name");
            return badNamed(arena, "{s} needs a value", flag);
        },
        .unknown, .unexpected_value, .removed => return badArguments("an unknown flag is given"),
    }
}

/// V1: the login token must hash to the digest the host sent. It reads the login
/// (R2) and the disk. It makes no network call. A missing or expired login is
/// N10 too, because the host checked it before the launch.
const LoginCheck = union(enum) {
    refused: Refusal,
    token: vercel.Token,
};

fn checkLogin(arena: Allocator, inputs: Inputs, expected_sha256: []const u8) !LoginCheck {
    const trace: vercel.Trace = .{ .context = null, .line = ignoreTrace };
    const result = try vercel.load(arena, inputs.env, builtin.target.os.tag, inputs.files, trace, inputs.now_unix_s);
    switch (result) {
        .token => |token| return if (sha256.matches(expected_sha256, token.bytes())) .{ .token = token } else .{ .refused = .login_changed },
        .missing, .expired => return .{ .refused = .login_changed },
    }
}

fn ignoreTrace(context: ?*anyopaque, text: []const u8) void {
    _ = context;
    _ = text;
}

/// What the words after the subcommand ask for: a refusal, or a command whose login passed V1.
pub const Decision = union(enum) {
    refused: Refusal,
    run: Run,
};

pub const Run = struct {
    command: Command,
    token: vercel.Token,
};

/// Parses `args`, the words after the subcommand, and checks the login (V1). It makes no
/// network call.
pub fn decide(arena: Allocator, args: []const []const u8, inputs: Inputs) !Decision {
    return switch (try parse(arena, args)) {
        .refused => |refused| .{ .refused = refused },
        .command => |command| switch (try checkLogin(arena, inputs, command.token_sha256)) {
            .refused => |refusal| .{ .refused = refusal },
            .token => |token| .{ .run = .{ .command = command, .token = token } },
        },
    };
}

fn refusalLine(arena: Allocator, refusal: Refusal) Allocator.Error![]const u8 {
    return switch (refusal) {
        .contract => "fx: did not run: fx was updated while this session ran. Run the command again.\n",
        .bad_arguments => |detail| try arena.print("fx: did not run: the runner arguments are wrong: {s}\n", .{detail}),
        .login_changed => "fx: did not run: the Vercel login changed during the call\n",
    };
}

/// The process entry. `words` is the whole argv, so `words[1]` is the subcommand. It reads
/// fx's login environment and the disk, writes its output (command output to stdout, notes
/// to stderr), and returns the exit code.
pub fn runBuiltin(arena: Allocator, words: []const []const u8) u8 {
    if (words.len < 2) return exit_did_not_run;
    installStopHandler();
    const io = io_mod.getIo();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writer(io, &stderr_buffer);
    const inputs: Inputs = .{
        .env = .{
            .vercel_token = io_mod.getenv("VERCEL_TOKEN"),
            .home = io_mod.getenv("HOME"),
            .xdg_data_home = io_mod.getenv("XDG_DATA_HOME"),
        },
        .files = vercel.disk,
        .now_unix_s = @divFloor(io_mod.milliTimestamp(), 1000),
    };
    const decision = decide(arena, words[2..], inputs) catch return exit_did_not_run;
    return switch (decision) {
        .refused => |refusal| refuse(arena, &stderr.interface, refusal),
        .run => |run| if (run.command.mode == .remote)
            (runRemote(arena, run, &stdout.interface, &stderr.interface) catch |err| failedRun(arena, &stderr.interface, err))
        else
            (runIsolated(arena, run, &stdout.interface, &stderr.interface) catch |err| failedRun(arena, &stderr.interface, err)),
    };
}

fn refuse(arena: Allocator, stderr: *std.Io.Writer, refusal: Refusal) u8 {
    const line = refusalLine(arena, refusal) catch return exit_did_not_run;
    writeNote(stderr, line);
    return exit_did_not_run;
}

/// A note is one `fx: ` line on stderr. A failed write has no reader left to tell, and the
/// exit code still reports the result.
fn writeNote(stderr: *std.Io.Writer, line: []const u8) void {
    // No reader is left to tell when stderr fails, and the exit code still reports the result.
    stderr.writeAll(line) catch {};
    // The same as the write above: a failed flush leaves no reader to tell.
    stderr.flush() catch {};
}

/// V9 after an exit: the bring-back, then its notes. The command's exit code is kept, so a
/// failed bring-back never changes it. Returns true when the bring-back did not finish.
fn bringBack(arena: Allocator, context: *vercel.SandboxContext, session_id: []const u8, run_id: []const u8, baseline: []const vercel.BringBackFile, command: Command, stderr: *std.Io.Writer) bool {
    const input: vercel.BringBackInput = .{ .run_id = run_id, .roots = command.bring_back, .own_baseline = baseline };
    switch (vercel.bringBack(arena, context, session_id, input)) {
        .failed => |detail| {
            const line = arena.print("fx: did not bring back the files: {s}\n", .{detail}) catch return true;
            writeNote(stderr, line);
            return true;
        },
        .done => |report| {
            writeBringBackNotes(arena, stderr, command, report.counts, .remote);
            return false;
        },
    }
}

/// N18: a size change that applies from the next session, or that could not be made (V3). It is
/// printed once per run, after the push that asked for it.
fn noteSize(arena: Allocator, stderr: *std.Io.Writer, note: vercel.SizeNote) void {
    const line = sizeNoteLine(arena, note) catch return;
    if (line) |text| writeNote(stderr, text);
}

fn sizeNoteLine(arena: Allocator, note: vercel.SizeNote) Allocator.Error!?[]const u8 {
    return switch (note) {
        .none => null,
        .applies_next_session => |size| try arena.print("fx: vcpus {d} applies from the next session of this repository's sandbox; it now has {d}\n", .{ size.wanted, size.now }),
        .failed => |rejected| try arena.print("fx: could not change the sandbox size to {d}: {f}\n", .{ rejected.wanted, text_utils.terminalSafe(rejected.detail) }),
    };
}

test "N18 has its two forms, and nothing when the size did not change (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(@as(?[]const u8, null), try sizeNoteLine(arena, .none));
    const applies = (try sizeNoteLine(arena, .{ .applies_next_session = .{ .wanted = 8, .now = 4 } })).?;
    try std.testing.expectEqualStrings("fx: vcpus 8 applies from the next session of this repository's sandbox; it now has 4\n", applies);
    const failed = (try sizeNoteLine(arena, .{ .failed = .{ .wanted = 8, .detail = "the plan's limit" } })).?;
    try std.testing.expectEqualStrings("fx: could not change the sandbox size to 8: the plan's limit\n", failed);
}

/// N25: a pending record that could not be written (V9). The run's exit code does not change.
fn notePendingFailure(arena: Allocator, stderr: *std.Io.Writer, context: *const vercel.SandboxContext, err: anyerror) void {
    const detail = if (err == error.Refused) context.failure.detail else @errorName(err);
    const line = arena.print("fx: could not record the files this run left in the sandbox: {f}; the next run may not bring them back\n", .{text_utils.terminalSafe(detail)}) catch return;
    writeNote(stderr, line);
}

/// The N26 note text: the sync record could not be read, so it was reset (V5).
const manifest_reset_note = "fx: the sync record for this repository could not be read and was reset; all files are sent again\n";

fn noteManifestReset(stderr: *std.Io.Writer, reset: bool) void {
    if (reset) writeNote(stderr, manifest_reset_note);
}

/// "file" for one, "files" for any other count (N8, N9, N14).
fn noun(count: usize) []const u8 {
    return if (count == 1) "file" else "files";
}

const over_cap_remote_text = "past this run's limit of 2,000 files or 64 MiB; the next run brings them back";
const over_cap_isolated_text = "past this run's limit of 2,000 files or 64 MiB; the isolated sandbox was deleted";
const untracked_text = "too many files left in the sandbox to track; copy them another way";

const BackReason = struct { count: usize, text: []const u8 };

/// The N8 reasons of one bring-back, in the order they print (V9). Pure, so each text is tested.
fn bringBackReasons(counts: vercel.BringBackCounts, isolated: bool) [8]BackReason {
    return .{
        .{ .count = counts.skipped_kind, .text = "not regular files" },
        .{ .count = counts.skipped_path, .text = "outside the repository" },
        .{ .count = counts.skipped_git, .text = "inside .git" },
        .{ .count = counts.skipped_case, .text = "the name differs in case from a file on this machine" },
        .{ .count = counts.skipped_folder, .text = "a folder on this machine is a link or a file" },
        .{ .count = counts.skipped_big, .text = "over 64 MiB" },
        .{ .count = counts.over_cap, .text = if (isolated) over_cap_isolated_text else over_cap_remote_text },
        .{ .count = counts.over_untracked, .text = untracked_text },
    };
}

test "N8 gives each kind of file its own text: a remote over-cap file is kept, an isolated one is not, an untracked one says so (V9)" {
    const counts: vercel.BringBackCounts = .{ .over_cap = 3, .over_untracked = 2 };
    const remote = bringBackReasons(counts, false);
    try std.testing.expectEqualStrings(over_cap_remote_text, remote[6].text);
    try std.testing.expectEqual(@as(usize, 3), remote[6].count);
    try std.testing.expectEqualStrings(untracked_text, remote[7].text);
    try std.testing.expectEqual(@as(usize, 2), remote[7].count);
    const isolated = bringBackReasons(counts, true);
    try std.testing.expectEqualStrings("past this run's limit of 2,000 files or 64 MiB; the isolated sandbox was deleted", isolated[6].text);
}

/// Where a finished run's files are, for the success line (N14). An isolated run's files
/// are not in the repository, so its line names the runs folder instead.
const RunPlace = union(enum) {
    remote,
    isolated: []const u8,
};

fn writeBringBackNotes(arena: Allocator, stderr: *std.Io.Writer, command: Command, counts: vercel.BringBackCounts, place: RunPlace) void {
    const isolated = place == .isolated;
    for (bringBackReasons(counts, isolated)) |reason| {
        if (reason.count == 0) continue;
        const line = arena.print("fx: {d} {s} not brought back: {s}\n", .{ reason.count, noun(reason.count), reason.text }) catch return;
        writeNote(stderr, line);
    }
    if (counts.kept > 0) {
        const line = arena.print("fx: kept your version of {d} {s} changed on this machine during the run\n", .{ counts.kept, noun(counts.kept) }) catch return;
        writeNote(stderr, line);
    }
    const slug = text_utils.terminalSafe(command.team_slug);
    const name = text_utils.terminalSafe(command.project_name);
    const line = switch (place) {
        .remote => arena.print("fx: ran on remote vercel:{f}/{f}; {d} {s} back\n", .{
            slug,
            name,
            counts.written,
            noun(counts.written),
        }),
        .isolated => |runs_dir| arena.print("fx: ran isolated on vercel:{f}/{f}; {d} {s} saved in {f}\n", .{
            slug,
            name,
            counts.written,
            noun(counts.written),
            text_utils.terminalSafe(runs_dir),
        }),
    } catch return;
    writeNote(stderr, line);
}

fn failedRun(arena: Allocator, stderr: *std.Io.Writer, err: anyerror) u8 {
    const line = arena.print("fx: did not run: {s}\n", .{@errorName(err)}) catch return exit_did_not_run;
    writeNote(stderr, line);
    return exit_did_not_run;
}

/// Set by SIGTERM (V10). The handler does only this atomic store, and the run reads it.
var stop_requested: std.atomic.Value(bool) = .init(false);

fn onStop(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    stop_requested.store(true, .seq_cst);
}

/// Installs the SIGTERM handler that starts the stop (V10), before any work begins.
fn installStopHandler() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

/// Isolated mode (I1 to I4): the profile's network arguments (N27), the sweep of this host's
/// leftovers and the `runs/` retention, one new sandbox with its network policy, the push of every
/// listed file, the exec with no `--env` values, the bring-back into `runs/{run_id}/`, and the delete
/// of the sandbox on every path after it was created.
fn runIsolated(arena: Allocator, run: Run, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const command = run.command;
    const io = io_mod.getIo();
    const profile_name = if (command.profile) |profile| profile.name else "";
    const profile_args: []const []const u8 = if (command.profile) |profile| profile.args else &.{};
    const network = switch (try vercel.isolated.parseNetwork(arena, profile_args)) {
        .policy => |policy| policy,
        .unknown_argument => |argument| return refuseProfileArgument(arena, stderr, profile_name, argument),
    };
    const repo_key = std.Io.Dir.path.basename(command.state);
    const parent_path = std.Io.Dir.path.dirname(command.state) orelse return exit_did_not_run;
    var parent = io_mod.openDirAbsoluteNoFollow(parent_path, .{ .iterate = true }) catch |err| return stateRefusal(arena, stderr, err);
    defer parent.close(io);
    var state_dir = io_mod.openOrCreateVerifiedPrivateDirFromDir(parent, repo_key) catch |err| return stateRefusal(arena, stderr, err);
    defer state_dir.close();
    if (stop_requested.load(.seq_cst)) return stoppedBeforeSend(stderr);

    var host_name_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host_name = try std.posix.gethostname(&host_name_buffer);
    const key = try vercel.isolated.hostKey(arena, command.user_id, host_name);
    var context: vercel.SandboxContext = .{
        .alloc = arena,
        .cancel = &stop_requested,
        .base = vercel.resolveBaseUrl(io_mod.getenv(vercel.override_env)),
        .token = run.token,
        .trace = .{ .context = null, .line = ignoreTrace },
        .team_id = command.team,
        .project_id = command.project,
        .name = try vercel.isolated.newSandboxName(arena, key),
        .repo_root = command.root,
        .state_dir = &state_dir,
        .vcpus = if (command.vcpus) |count| @as(u32, count) else null,
        .mode = .isolated,
    };
    vercel.isolated.sweep(arena, &context, try vercel.isolated.namePrefix(arena, key), io_mod.milliTimestamp());
    vercel.isolated.pruneRuns(arena, &state_dir);

    const created = vercel.createIsolated(&context, vercel.isolated.body(network)) catch |err| return sandboxFailedUnlessStopped(arena, stderr, &context, err);
    defer {
        var never_cancelled = std.atomic.Value(bool).init(false);
        var cleanup = context;
        cleanup.cancel = &never_cancelled;
        vercel.deleteSandboxNamed(&cleanup, cleanup.name) catch |err| debug_trace.logf("remote run", "event=cleanup_failed what=isolated_sandbox reason={s}", .{@errorName(err)});
    }
    var session: vercel.SandboxSession = .{ .state = created, .generation = .reset, .size_note = .none };
    vercel.prepareIsolatedRoot(&context, &session) catch |err| return sandboxFailedUnlessStopped(arena, stderr, &context, err);

    const run_id = try newRunId(arena);
    var pushed = switch (vercel.pushIsolated(&context, .{ .run_id = run_id, .bring_back = command.bring_back }, &session)) {
        .ok => |result| result,
        .failed => |failure| {
            if (stop_requested.load(.seq_cst)) return stoppedBeforeSend(stderr);
            return pushRefusal(arena, stderr, failure);
        },
    };
    if (extendBeforeExec(&context, &pushed.session, stderr)) |code| return code;
    const request: vercel.ExecRequest = .{
        .root = command.root,
        .cwd = command.cwd,
        .stamp = try arena.print("{s}/.git/fx-stamp-{s}", .{ command.root, run_id }),
        .command = command.command,
        .env = &.{},
        .timeout_ms = command.timeout_ms,
        .grace_ms = command.grace_ms,
    };
    const outcome = vercel.runExec(&context, &pushed.session, request, .{ .stdout = stdout, .stderr = stderr }, .{});
    stdout.flush() catch |err| debug_trace.logf("remote run", "event=output_flush_failed reason={s}", .{@errorName(err)});
    if (std.meta.activeTag(outcome) == .exited) bringBackIsolated(arena, &context, &state_dir, pushed.session.state.session_id, run_id, command, stderr);
    return exitFor(arena, stderr, outcome);
}

/// I3: the bring-back of an isolated run into `{S}/runs/{run_id}/`. It runs after any exit code of the
/// command, and never after a stop or an unknown result (`.exited` only).
fn bringBackIsolated(arena: Allocator, context: *vercel.SandboxContext, state_dir: *io_mod.VerifiedDir, session_id: []const u8, run_id: []const u8, command: Command, stderr: *std.Io.Writer) void {
    var destination = vercel.isolated.openRunFolder(arena, state_dir, run_id) catch |err| return writeBringBackFailed(arena, stderr, @errorName(err));
    defer destination.close(io_mod.getIo());
    const input: vercel.BringBackInput = .{ .run_id = run_id, .roots = command.bring_back, .own_baseline = &.{} };
    switch (vercel.bringBackIsolated(arena, context, session_id, input, destination)) {
        .failed => |detail| writeBringBackFailed(arena, stderr, detail),
        .done => |report| {
            const runs_dir = arena.print("{s}/runs/{s}", .{ command.state, run_id }) catch return;
            writeBringBackNotes(arena, stderr, command, report.counts, .{ .isolated = runs_dir });
        },
    }
}

fn writeBringBackFailed(arena: Allocator, stderr: *std.Io.Writer, detail: []const u8) void {
    const line = arena.print("fx: did not bring back the files: {s}\n", .{detail}) catch return;
    writeNote(stderr, line);
}

/// A sandbox step before the command that failed. A stop that came meanwhile is the stop's result:
/// the command was not sent, so it did not run (V10, N24).
fn sandboxFailedUnlessStopped(arena: Allocator, stderr: *std.Io.Writer, context: *const vercel.SandboxContext, err: anyerror) u8 {
    if (stop_requested.load(.seq_cst)) return stoppedBeforeSend(stderr);
    return sandboxFailed(arena, stderr, context, err);
}

/// A sandbox step that failed: N1 for a refusal, or the error's name for anything else.
fn sandboxFailed(arena: Allocator, stderr: *std.Io.Writer, context: *const vercel.SandboxContext, err: anyerror) u8 {
    if (err == error.Refused) return pushRefusal(arena, stderr, context.failure) catch exit_did_not_run;
    return failedRun(arena, stderr, err);
}

/// N27: a profile argument fx does not understand. Nothing is created (I2).
fn refuseProfileArgument(arena: Allocator, stderr: *std.Io.Writer, profile: []const u8, argument: []const u8) u8 {
    const line = arena.print("fx: did not run: profile {f} has an unknown argument {f}\n", .{
        text_utils.terminalSafe(profile),
        text_utils.terminalSafe(argument),
    }) catch return exit_did_not_run;
    writeNote(stderr, line);
    return exit_did_not_run;
}

/// N28: pending records were cleared without a bring-back, because the sandbox was replaced or its
/// record was reset (V4). It is printed once per run, after the push.
fn noteCleared(arena: Allocator, stderr: *std.Io.Writer, count: usize) void {
    if (count == 0) return;
    const line = arena.print("fx: files from {d} earlier stopped runs were not brought back, because the sandbox was replaced or its record was reset\n", .{count}) catch return;
    writeNote(stderr, line);
}

test "a sandbox step that fails after a stop is a stop before the send, with N24 (V10)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var context: vercel.SandboxContext = undefined;
    stop_requested.store(true, .seq_cst);
    defer stop_requested.store(false, .seq_cst);
    const code = sandboxFailedUnlessStopped(arena, &out.writer, &context, error.Refused);
    try std.testing.expectEqual(exit_stopped, code);
    try std.testing.expectEqualStrings(stopped_before_send_note, out.written());
}

test "N28 names the pending records a reset cleared, and prints nothing when none were cleared (V4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var quiet: std.Io.Writer.Allocating = .init(arena);
    noteCleared(arena, &quiet.writer, 0);
    try std.testing.expectEqualStrings("", quiet.written());
    var out: std.Io.Writer.Allocating = .init(arena);
    noteCleared(arena, &out.writer, 1);
    try std.testing.expectEqualStrings("fx: files from 1 earlier stopped runs were not brought back, because the sandbox was replaced or its record was reset\n", out.written());
}

/// The steps of V3 and V4, which set up the sandbox before the push.
const sandbox_steps = [_][]const u8{ "create", "resume", "size", "user", "setup", "generation", "state", "extend" };

/// The note for a cut file list (V5): the push ran, but its scan stopped short. N20.
const cut_short_note = "fx: the file list was cut short, so nothing was deleted in the sandbox\n";

/// Remote mode, V2 to V6: the push (which holds the lock only while it runs), the extend
/// before exec (V12), then the exec (V6 to V10). The lock is released before the exec runs.
fn runRemote(arena: Allocator, run: Run, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const command = run.command;
    const io = io_mod.getIo();
    const repo_key = std.Io.Dir.path.basename(command.state);
    const parent_path = std.Io.Dir.path.dirname(command.state) orelse return exit_did_not_run;
    var parent = io_mod.openDirAbsoluteNoFollow(parent_path, .{ .iterate = true }) catch |err| return stateRefusal(arena, stderr, err);
    defer parent.close(io);
    var state_dir = io_mod.openOrCreateVerifiedPrivateDirFromDir(parent, repo_key) catch |err| return stateRefusal(arena, stderr, err);
    defer state_dir.close();
    if (stop_requested.load(.seq_cst)) return stoppedBeforeSend(stderr);

    var context: vercel.SandboxContext = .{
        .alloc = arena,
        .cancel = &stop_requested,
        .base = vercel.resolveBaseUrl(io_mod.getenv(vercel.override_env)),
        .token = run.token,
        .trace = .{ .context = null, .line = ignoreTrace },
        .team_id = command.team,
        .project_id = command.project,
        .name = try arena.print("fx-{s}", .{repo_key}),
        .repo_root = command.root,
        .state_dir = &state_dir,
        .vcpus = if (command.vcpus) |count| @as(u32, count) else null,
        .mode = .remote,
    };
    const started_ms = io_mod.milliTimestamp();
    const run_id = try newRunId(arena);
    const baseline: []const vercel.BringBackFile = vercel.bringBackBaseline(&context, command.bring_back) catch @as([]const vercel.BringBackFile, &.{});
    const push_outcome = vercel.pushRoot(&context, .{ .run_id = run_id, .include = command.include, .bring_back = command.bring_back });
    noteManifestReset(stderr, context.manifest_reset);
    noteJournalSetAside(stderr, context.journal_set_aside);
    noteCleared(arena, stderr, context.pending_cleared);
    var pushed = switch (push_outcome) {
        .ok => |result| result,
        .failed => |failure| {
            if (stop_requested.load(.seq_cst)) return stoppedBeforeSend(stderr);
            return pushRefusal(arena, stderr, failure);
        },
    };
    noteSize(arena, stderr, pushed.size_note);
    noteCutShort(stderr, pushed.scan_complete);
    noteMissingIncludes(arena, stderr, pushed.missing_include);
    if (extendBeforeExec(&context, &pushed.session, stderr)) |code| return code;

    const request: vercel.ExecRequest = .{
        .root = command.root,
        .cwd = command.cwd,
        .stamp = try arena.print("{s}/.git/fx-stamp-{s}", .{ command.root, run_id }),
        .command = command.command,
        .env = try environmentPairs(arena, command.env),
        .timeout_ms = command.timeout_ms,
        .grace_ms = command.grace_ms,
    };
    const outcome = vercel.runExec(&context, &pushed.session, request, .{ .stdout = stdout, .stderr = stderr }, .{});
    stdout.flush() catch |err| debug_trace.logf("remote run", "event=output_flush_failed reason={s}", .{@errorName(err)});
    const brought_failed = std.meta.activeTag(outcome) == .exited and bringBack(arena, &context, pushed.session.state.session_id, run_id, baseline, command, stderr);
    vercel.notePending(&context, run_id, started_ms, baseline, outcome, brought_failed) catch |err| notePendingFailure(arena, stderr, &context, err);
    return exitFor(arena, stderr, outcome);
}

/// V12: a session with less than 30 minutes left is extended before the exec. A failed extend adds
/// the one `fx:` line, and the run goes on. A 404 or 410 that the run's one resume cannot cover
/// refuses the run before the start request: N1, exit 125, and the command is not sent (V3).
fn extendBeforeExec(context: *vercel.SandboxContext, session: *vercel.SandboxSession, stderr: *std.Io.Writer) ?u8 {
    if (session.state.expires_at_ms - io_mod.milliTimestamp() >= vercel.extend_below_ms) return null;
    const status = vercel.extendBeforeExec(context, session) catch |err| {
        if (err == error.Refused) return pushRefusal(context.alloc, stderr, context.failure) catch exit_did_not_run;
        vercel.writeExtendNote(stderr, @errorName(err));
        return null;
    };
    if (status >= 200 and status <= 299) return null;
    var buffer: [32]u8 = undefined;
    const detail = std.mem.print(&buffer, "HTTP {d}", .{status}) catch {
        vercel.writeExtendNote(stderr, "HTTP status");
        return null;
    };
    vercel.writeExtendNote(stderr, detail);
    return null;
}

/// N24: a stop before the exec request was sent. The command did not run (V10).
const stopped_before_send_note = "fx: stopped before the command was sent; it did not run\n";

fn stoppedBeforeSend(stderr: *std.Io.Writer) u8 {
    writeNote(stderr, stopped_before_send_note);
    return exit_stopped;
}

const journal_set_aside_note = "fx: the sync journal was damaged, so fx set it aside; files from the last bring-back count as changed on this machine\n";

/// N31: push found a damaged sync journal and set it aside (V9). Printed once per run.
fn noteJournalSetAside(stderr: *std.Io.Writer, set_aside: bool) void {
    if (set_aside) writeNote(stderr, journal_set_aside_note);
}

test "N31 is printed when push set a damaged journal aside, and never otherwise (V9)" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    noteJournalSetAside(&out.writer, false);
    try std.testing.expectEqualStrings("", out.written());
    noteJournalSetAside(&out.writer, true);
    try std.testing.expectEqualStrings(journal_set_aside_note, out.written());
}

/// N20: the one note for a cut file list (V5). The push still ran, and nothing was deleted.
fn noteCutShort(stderr: *std.Io.Writer, scan_complete: bool) void {
    if (!scan_complete) writeNote(stderr, cut_short_note);
}

/// N17: one line for each `include` path that was missing or unsafe, in the order the config lists
/// them. The push reports each path once, so each line is printed once per run (V5).
fn noteMissingIncludes(arena: Allocator, stderr: *std.Io.Writer, paths: []const []const u8) void {
    for (paths) |path| {
        const line = arena.print("fx: include path {s} was not found\n", .{path}) catch return;
        writeNote(stderr, line);
    }
}

fn newRunId(arena: Allocator) Allocator.Error![]const u8 {
    var bytes: [8]u8 = undefined;
    io_mod.getIo().random(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return arena.dupe(u8, &hex);
}

/// The `--env` names that are set in fx's environment, with their values (V6).
fn environmentPairs(arena: Allocator, names: []const []const u8) Allocator.Error![]const vercel.ExecPair {
    var pairs: std.ArrayList(vercel.ExecPair) = .empty;
    for (names) |name| {
        const set_value = io_mod.getenv(name) orelse continue;
        try pairs.append(arena, .{ .name = name, .value = set_value });
    }
    return pairs.items;
}

/// N22: the runner state folder could not be opened.
fn stateRefusal(arena: Allocator, stderr: *std.Io.Writer, err: anyerror) u8 {
    const line = arena.print("fx: did not run: the runner state folder could not be opened: {s}\n", .{@errorName(err)}) catch return exit_did_not_run;
    writeNote(stderr, line);
    return exit_did_not_run;
}

/// The notes for a failed push: N16 for the lock, N1 for the sandbox, N2 for the files.
/// The detail carries API text, so it is made terminal-safe first (R4.6).
/// N11 (V13): Vercel rejected the login before the command started. It is the one line for every such refusal.
fn loginRejectedLine(arena: Allocator, status: u16) ![]u8 {
    return arena.print("fx: did not run: Vercel rejected the login ({d}). Run `vercel whoami` or `vercel login`.\n", .{status});
}

fn pushRefusal(arena: Allocator, stderr: *std.Io.Writer, failure: vercel.SandboxFailure) !u8 {
    const detail = text_utils.terminalSafe(failure.detail);
    const line = if (vercel.loginRejected(failure.status))
        try loginRejectedLine(arena, failure.status)
    else if (std.mem.eql(u8, failure.step, "lock"))
        try arena.print("fx: did not run: {f}\n", .{detail})
    else if (isSandboxStep(failure.step))
        try sandboxStartLine(arena, failure.status, detail)
    else
        try arena.print("fx: did not run: sending files failed: {f}\n", .{detail});
    writeNote(stderr, line);
    return exit_did_not_run;
}

/// The N1 line for a sandbox that did not start. A failure with no HTTP status (status 0)
/// leaves the status out, so no `0` reaches the person (spec N1).
fn sandboxStartLine(arena: Allocator, status: u16, detail: anytype) ![]u8 {
    if (status == 0) return arena.print("fx: did not run: the Vercel sandbox could not start: {f}\n", .{detail});
    return arena.print("fx: did not run: the Vercel sandbox could not start: {d} {f}\n", .{ status, detail });
}

test "the N1 line leaves the status out when the failure has none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "fx: did not run: the Vercel sandbox could not start: the marker could not be written\n",
        try sandboxStartLine(arena, 0, text_utils.terminalSafe("the marker could not be written")),
    );
    try std.testing.expectEqualStrings(
        "fx: did not run: the Vercel sandbox could not start: 410 the session ended before the command started; run it again\n",
        try sandboxStartLine(arena, 410, text_utils.terminalSafe("the session ended before the command started; run it again")),
    );
}

test "V13: a login rejected before the exec is N11 at 401 and 403, and any other status keeps N1 (V13, N11)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = try pushRefusal(arena, &out.writer, .{ .step = "create", .status = 403, .detail = "forbidden" });
    try std.testing.expectEqualStrings(
        "fx: did not run: Vercel rejected the login (403). Run `vercel whoami` or `vercel login`.\n",
        out.written(),
    );
    var rejected: std.Io.Writer.Allocating = .init(arena);
    _ = try pushRefusal(arena, &rejected.writer, .{ .step = "push", .status = 401, .detail = "unauthorized" });
    try std.testing.expectEqualStrings(
        "fx: did not run: Vercel rejected the login (401). Run `vercel whoami` or `vercel login`.\n",
        rejected.written(),
    );
    var other: std.Io.Writer.Allocating = .init(arena);
    _ = try pushRefusal(arena, &other.writer, .{ .step = "create", .status = 500, .detail = "boom" });
    try std.testing.expectEqualStrings("fx: did not run: the Vercel sandbox could not start: 500 boom\n", other.written());
}

test "V13: an exec refused with 401 or 403 prints N11 and exits 125 (V13, N11)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    const code = try exitFor(arena, &out.writer, .{ .sandbox_refused = .{ .step = "exec", .status = 403, .detail = "the login was rejected" } });
    try std.testing.expectEqual(exit_did_not_run, code);
    try std.testing.expectEqualStrings(
        "fx: did not run: Vercel rejected the login (403). Run `vercel whoami` or `vercel login`.\n",
        out.written(),
    );
}

fn isSandboxStep(step: []const u8) bool {
    for (sandbox_steps) |name| {
        if (std.mem.eql(u8, step, name)) return true;
    }
    return false;
}

/// The exit code and note for the exec's result (V6 to V10, V12, L6). The command's own exit
/// code is the result when it ran.
fn exitFor(arena: Allocator, stderr: *std.Io.Writer, outcome: vercel.ExecOutcome) !u8 {
    switch (outcome) {
        .exited => |code| return code,
        .not_sent => |detail| {
            const line = try arena.print("fx: did not run: sending the command failed: {f}\n", .{text_utils.terminalSafe(detail)});
            writeNote(stderr, line);
            return exit_did_not_run;
        },
        .stopped_unsent => return stoppedBeforeSend(stderr),
        .refused_by_wrapper => return exit_did_not_run,
        .sandbox_refused => |failure| {
            const line = if (vercel.loginRejected(failure.status))
                try loginRejectedLine(arena, failure.status)
            else
                try sandboxStartLine(arena, failure.status, text_utils.terminalSafe(failure.detail));
            writeNote(stderr, line);
            return exit_did_not_run;
        },
        .stopped => |confirmed| {
            writeNote(stderr, if (confirmed) "fx: stopped; the remote command was killed\n" else "fx: stopped; fx could not confirm that the remote command stopped\n");
            return exit_stopped;
        },
        .unknown => |id| {
            const line = if (id) |text|
                try arena.print("fx: lost contact with remote command {f} after it started; it may still run; fx did not send it again\n", .{text_utils.terminalSafe(text)})
            else
                "fx: result unknown: the command may have run; fx did not send it again\n";
            writeNote(stderr, line);
            return exit_unknown;
        },
        .gone => {
            writeNote(stderr, "fx: the sandbox reached its time limit\n");
            return exit_unknown;
        },
    }
}

/// L4 and AC-26: the contract is checked before anything else. The first `--contract`
/// on the line decides, and only in the `--contract 1` form. Other flags do not matter,
/// so a word the parser cannot read is skipped here, not refused.
fn contractIsSupported(words: []const [:0]const u8) bool {
    var parser = cli_flags.Parser.init(&runner_options, words);
    while (true) {
        const before = parser.index;
        const item = parser.next() catch continue;
        const found = item orelse return false;
        switch (found) {
            .positional => {},
            .option => |match| {
                if (flag_ids[match.index].? != .contract) continue;
                if (parser.index - before != 2) return false;
                return std.mem.eql(u8, match.value.?, contract_version);
            },
        }
    }
}

fn value(values: [flag_count]?[]const u8, flag: Flag) []const u8 {
    return values[@backingInt(flag)].?;
}

/// A whole number of at least `min`, or null.
fn wholeNumber(text: []const u8, min: i64) ?i64 {
    const number = std.fmt.parseInt(i64, text, 10) catch return null;
    return if (number < min) null else number;
}

/// A vCPU count from 1 to 255, or null. The size list is checked in block 5g.
fn parseVcpus(text: []const u8) ?u8 {
    const number = std.fmt.parseInt(u8, text, 10) catch return null;
    return if (number == 0) null else number;
}

/// A repo key (L5): exactly sixteen lowercase hex digits.
fn isRepoKey(text: []const u8) bool {
    if (text.len != repo_key_bytes) return false;
    for (text) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn badArguments(text: []const u8) Parsed {
    return .{ .refused = .{ .bad_arguments = text } };
}

fn badNamed(arena: Allocator, comptime format: []const u8, name: []const u8) Allocator.Error!Parsed {
    return .{ .refused = .{ .bad_arguments = try arena.print(format, .{name}) } };
}

const digest = "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef" ++ "0123456789abcdef";
/// Every L1 flag except the token and the grace, for a command line the tests build.
const fixed_no_grace = [_][]const u8{
    "run",     "--contract",                "1",      "--mode", "remote",    "--root", "/w/repo",     "--cwd", "/w/repo",
    "--state", "/w/state/0123456789abcdef", "--team", "team_1", "--project", "prj_1",  "--team-slug", "ts",    "--project-name",
    "pn",      "--user-id",                 "u1",
};
const fixed = fixed_no_grace ++ [_][]const u8{ "--grace-ms", "0" };
const head = fixed ++ [_][]const u8{ "--token-sha256", digest };
const cmd_tail = [_][]const u8{ "--", "true" };

fn refusalOf(arena: Allocator, args: []const []const u8) !Refusal {
    return switch (try parse(arena, args)) {
        .refused => |refused| refused,
        .command => error.TestUnexpectedCommand,
    };
}

fn expectBad(arena: Allocator, args: []const []const u8, phrase: []const u8) !void {
    const refusal = try refusalOf(arena, args);
    try std.testing.expect(refusal == .bad_arguments);
    try std.testing.expect(std.mem.find(u8, refusal.bad_arguments, phrase) != null);
}

test "a full command line parses to its fields (L1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = [_][]const u8{
        "run",       "--contract",                "1",          "--mode",    "isolated",     "--root",     "/w/repo",        "--cwd",        "/w/repo/app",
        "--state",   "/w/state/0123456789abcdef", "--team",     "team_1",    "--project",    "prj_1",      "--token-sha256", digest,         "--team-slug",
        "team-one",  "--project-name",            "fx-sandbox", "--user-id", "u1",           "--grace-ms", "30000",          "--timeout-ms", "5000",
        "--include", "app/generated",             "--include",  "docs/x.md", "--bring-back", "out/bin",    "--vcpus",        "4",            "--profile",
        "media",     "--network",                 "deny-all",   "--env",     "API_KEY",      "--env",      "MODE",           "--",           "zig build test",
    };
    const parsed = try parse(arena, &args);
    try std.testing.expect(parsed == .command);
    const command = parsed.command;
    try std.testing.expectEqual(Mode.isolated, command.mode);
    try std.testing.expectEqualStrings("/w/repo", command.root);
    try std.testing.expectEqualStrings("/w/repo/app", command.cwd);
    try std.testing.expectEqualStrings("/w/state/0123456789abcdef", command.state);
    try std.testing.expectEqualStrings("team_1", command.team);
    try std.testing.expectEqualStrings("prj_1", command.project);
    try std.testing.expectEqualStrings(digest, command.token_sha256);
    try std.testing.expectEqualStrings("team-one", command.team_slug);
    try std.testing.expectEqualStrings("fx-sandbox", command.project_name);
    try std.testing.expectEqual(@as(i64, 30_000), command.grace_ms);
    try std.testing.expectEqual(@as(?i64, 5_000), command.timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), command.include.len);
    try std.testing.expectEqualStrings("docs/x.md", command.include[1]);
    try std.testing.expectEqualStrings("out/bin", command.bring_back[0]);
    try std.testing.expectEqual(@as(?u8, 4), command.vcpus);
    try std.testing.expectEqualStrings("media", command.profile.?.name);
    try std.testing.expectEqual(@as(usize, 2), command.profile.?.args.len);
    try std.testing.expectEqualStrings("deny-all", command.profile.?.args[1]);
    try std.testing.expectEqual(@as(usize, 2), command.env.len);
    try std.testing.expectEqualStrings("MODE", command.env[1]);
    try std.testing.expectEqualStrings("zig build test", command.command);
}

test "the optional flags may be absent, and the grace is required (L1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parse(arena, &(head ++ cmd_tail));
    try std.testing.expect(parsed == .command);
    try std.testing.expectEqual(@as(?i64, null), parsed.command.timeout_ms);
    try std.testing.expectEqual(@as(?u8, null), parsed.command.vcpus);
    try std.testing.expectEqual(@as(usize, 0), parsed.command.include.len);
    try expectBad(arena, &(fixed_no_grace ++ [_][]const u8{ "--token-sha256", digest } ++ cmd_tail), "--grace-ms is missing");
}

test "a missing or unknown contract is N12, whatever else the line says (L4, AC-26)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old_host = [_][]const u8{ "run", "--contract", "2", "--mode", "remote", "--frozen-flag", "x" };
    try std.testing.expect((try refusalOf(arena, &old_host)) == .contract);
    const no_contract = [_][]const u8{ "run", "--mode", "remote", "--", "true" };
    try std.testing.expect((try refusalOf(arena, &no_contract)) == .contract);
}

test "each malformed line refuses with its own detail (L1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const unknown_flag = head ++ [_][]const u8{ "--frozen", "x" } ++ cmd_tail;
    try expectBad(arena, &unknown_flag, "an unknown flag");
    const no_team = [_][]const u8{
        "run",     "--contract",                "1",         "--mode", "remote",         "--root", "/w/repo", "--cwd", "/w/repo",
        "--state", "/w/state/0123456789abcdef", "--project", "prj_1",  "--token-sha256", digest,
    } ++ cmd_tail;
    try expectBad(arena, &no_team, "--team is missing");
    const twice = head ++ [_][]const u8{ "--root", "/w/other" } ++ cmd_tail;
    try expectBad(arena, &twice, "--root is given twice");
    const relative_cwd = [_][]const u8{
        "run",     "--contract",                "1",      "--mode",    "remote",    "--root",     "/w/repo",        "--cwd", "app",
        "--state", "/w/state/0123456789abcdef", "--team", "team_1",    "--project", "prj_1",      "--token-sha256", digest,  "--team-slug",
        "ts",      "--project-name",            "pn",     "--user-id", "u1",        "--grace-ms", "0",
    } ++ cmd_tail;
    try expectBad(arena, &relative_cwd, "--cwd is not an absolute path");
    const bad_mode = [_][]const u8{
        "run",     "--contract",                "1",      "--mode",    "both",      "--root",     "/w/repo",        "--cwd", "/w/repo",
        "--state", "/w/state/0123456789abcdef", "--team", "team_1",    "--project", "prj_1",      "--token-sha256", digest,  "--team-slug",
        "ts",      "--project-name",            "pn",     "--user-id", "u1",        "--grace-ms", "0",
    } ++ cmd_tail;
    try expectBad(arena, &bad_mode, "--mode is not remote or isolated");
    const upper_digest = [_][]const u8{
        "run",     "--contract",                "1",      "--mode",    "remote",    "--root",     "/w/repo",        "--cwd", "/w/repo",
        "--state", "/w/state/0123456789abcdef", "--team", "team_1",    "--project", "prj_1",      "--token-sha256", "ABC",   "--team-slug",
        "ts",      "--project-name",            "pn",     "--user-id", "u1",        "--grace-ms", "0",
    } ++ cmd_tail;
    try expectBad(arena, &upper_digest, "--token-sha256 is not 64 lowercase hex digits");
    const no_command = head;
    try expectBad(arena, &no_command, "the command after -- is missing");
    const two_words = head ++ [_][]const u8{ "--", "true", "extra" };
    try expectBad(arena, &two_words, "the command must follow -- as exactly one word");
    const empty_command = head ++ [_][]const u8{ "--", "" };
    try expectBad(arena, &empty_command, "the command is empty");
    const env_with_equals = head ++ [_][]const u8{ "--env", "A=B" } ++ cmd_tail;
    try expectBad(arena, &env_with_equals, "--env needs a name without =");
    const env_no_name = head ++ [_][]const u8{"--env"};
    try expectBad(arena, &env_no_name, "--env needs a name");
    const not_run = [_][]const u8{ "--contract", "1", "--mode", "remote", "--", "true" };
    try expectBad(arena, &not_run, "the first word after the subcommand is not run");
}

test "a malformed grace, timeout or vcpus is N19 with its flag named (L1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad_grace = fixed_no_grace ++ [_][]const u8{ "--token-sha256", digest, "--grace-ms", "x" } ++ cmd_tail;
    try expectBad(arena, &bad_grace, "--grace-ms is not a whole number of milliseconds");
    const zero_timeout = head ++ [_][]const u8{ "--timeout-ms", "0" } ++ cmd_tail;
    try expectBad(arena, &zero_timeout, "--timeout-ms is not a whole number of milliseconds above 0");
    const zero_vcpus = head ++ [_][]const u8{ "--vcpus", "0" } ++ cmd_tail;
    try expectBad(arena, &zero_vcpus, "--vcpus is not a whole number from 1 to 255");
}

test "--include and --bring-back use the config path rule, and name the flag (N19, L1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const absolute = head ++ [_][]const u8{ "--include", "/etc/passwd" } ++ cmd_tail;
    try expectBad(arena, &absolute, "--include: must be a relative path");
    const escape = head ++ [_][]const u8{ "--bring-back", "out/../../x" } ++ cmd_tail;
    try expectBad(arena, &escape, "--bring-back: must not contain .. segments");
    const git = head ++ [_][]const u8{ "--include", "a/.GIT/config" } ++ cmd_tail;
    try expectBad(arena, &git, "--include: must not contain a .git component");
    const missing_value = head ++ [_][]const u8{"--include"};
    try expectBad(arena, &missing_value, "--include needs a value");
}

test "the state folder name must be a 16-digit lowercase hex repo key (L5, N19)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plain_name = [_][]const u8{
        "run",     "--contract",     "1",      "--mode",    "remote",    "--root",     "/w/repo",        "--cwd", "/w/repo",
        "--state", "/w/state",       "--team", "team_1",    "--project", "prj_1",      "--token-sha256", digest,  "--team-slug",
        "ts",      "--project-name", "pn",     "--user-id", "u1",        "--grace-ms", "0",
    } ++ cmd_tail;
    try expectBad(arena, &plain_name, "the state folder name is not a 16-digit lowercase hex repo key");
    try std.testing.expect(isRepoKey("0123456789abcdef"));
    try std.testing.expect(!isRepoKey("0123456789ABCDEF"));
    try std.testing.expect(!isRepoKey("0123456789abcde"));
}

fn lineWithToken(arena: Allocator, token_digest: []const u8) ![]const []const u8 {
    var line: std.ArrayList([]const u8) = .empty;
    try line.appendSlice(arena, &fixed);
    try line.appendSlice(arena, &.{ "--token-sha256", token_digest });
    try line.appendSlice(arena, &cmd_tail);
    return line.items;
}

test "V1: a matching login gets past the check, a mismatch gives N10, and no request is made" {
    const test_server = @import("vercel/test_server.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var replies = [_]test_server.Reply{.{ .status = "200 OK", .body = "{}" }};
    var server: test_server.Server = .{ .replies = &replies };
    try server.listen();
    try server.start();
    defer server.close();

    const token = "fx-test-login";
    const inputs: Inputs = .{
        .env = .{ .vercel_token = token },
        .files = vercel.disk,
        .now_unix_s = 1_000,
    };
    const right = sha256.hexDigest(token);
    const wrong = sha256.hexDigest("some-other-token");
    const right_line = try lineWithToken(arena, &right);
    const wrong_line = try lineWithToken(arena, &wrong);

    const right_decision = try decide(arena, right_line, inputs);
    try std.testing.expect(right_decision == .run);
    try std.testing.expectEqualStrings(token, right_decision.run.token.bytes());

    const wrong_decision = try decide(arena, wrong_line, inputs);
    try std.testing.expect(wrong_decision == .refused);
    try std.testing.expectEqualStrings(
        "fx: did not run: the Vercel login changed during the call\n",
        try refusalLine(arena, wrong_decision.refused),
    );
    try std.testing.expect(std.mem.find(u8, try refusalLine(arena, wrong_decision.refused), token) == null);
    try std.testing.expectEqual(@as(usize, 0), server.servedCount());
}

test "V1: a login that is missing gives N10 without a request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const right = sha256.hexDigest("fx-test-login");
    const line = try lineWithToken(arena, &right);
    const inputs: Inputs = .{
        .env = .{ .home = "/nonexistent/fx-runner-test-home" },
        .files = vercel.disk,
        .now_unix_s = 1_000,
    };
    const decision = try decide(arena, line, inputs);
    try std.testing.expect(decision == .refused);
    try std.testing.expectEqualStrings("fx: did not run: the Vercel login changed during the call\n", try refusalLine(arena, decision.refused));
}

test "V1: a login changed after the user check gives N10, and nothing runs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The user check passed for "fx-test-login". The login has since changed to another token.
    const checked = sha256.hexDigest("fx-test-login");
    const line = try lineWithToken(arena, &checked);
    const inputs: Inputs = .{
        .env = .{ .vercel_token = "fx-test-login-changed" },
        .files = vercel.disk,
        .now_unix_s = 1_000,
    };
    const decision = try decide(arena, line, inputs);
    try std.testing.expect(decision == .refused);
    try std.testing.expectEqualStrings("fx: did not run: the Vercel login changed during the call\n", try refusalLine(arena, decision.refused));
}

test "N20: a cut file list writes exactly one note, and a complete one writes none (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    noteCutShort(&out.writer, true);
    try std.testing.expectEqualStrings("", out.written());
    noteCutShort(&out.writer, false);
    try std.testing.expectEqualStrings(cut_short_note, out.written());
}

test "N22: an unopened state folder names its error (L1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.testing.expectEqual(exit_did_not_run, stateRefusal(arena, &out.writer, error.AccessDenied));
    try std.testing.expectEqualStrings("fx: did not run: the runner state folder could not be opened: AccessDenied\n", out.written());
}

const ExitNote = struct {
    code: u8,
    note: []const u8,
};

fn exitNoteOf(arena: Allocator, outcome: vercel.ExecOutcome) !ExitNote {
    var out: std.Io.Writer.Allocating = .init(arena);
    const code = try exitFor(arena, &out.writer, outcome);
    return .{ .code = code, .note = out.written() };
}

test "the exit codes and notes of an exec outcome (V6 to V10, N3, N4, N5, N13, N21)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exited = try exitNoteOf(arena, .{ .exited = 7 });
    try std.testing.expectEqual(@as(u8, 7), exited.code);
    try std.testing.expectEqualStrings("", exited.note);

    const unsent = try exitNoteOf(arena, .stopped_unsent);
    try std.testing.expectEqual(exit_stopped, unsent.code);
    try std.testing.expectEqualStrings("fx: stopped before the command was sent; it did not run\n", unsent.note);

    const killed = try exitNoteOf(arena, .{ .stopped = true });
    try std.testing.expectEqual(exit_stopped, killed.code);
    try std.testing.expectEqualStrings("fx: stopped; the remote command was killed\n", killed.note);

    const unconfirmed = try exitNoteOf(arena, .{ .stopped = false });
    try std.testing.expectEqual(exit_stopped, unconfirmed.code);
    try std.testing.expectEqualStrings("fx: stopped; fx could not confirm that the remote command stopped\n", unconfirmed.note);

    const no_id = try exitNoteOf(arena, .{ .unknown = null });
    try std.testing.expectEqual(exit_unknown, no_id.code);
    try std.testing.expectEqualStrings("fx: result unknown: the command may have run; fx did not send it again\n", no_id.note);

    const with_id = try exitNoteOf(arena, .{ .unknown = "cmd_9" });
    try std.testing.expectEqual(exit_unknown, with_id.code);
    try std.testing.expectEqualStrings("fx: lost contact with remote command cmd_9 after it started; it may still run; fx did not send it again\n", with_id.note);

    const gone = try exitNoteOf(arena, .gone);
    try std.testing.expectEqual(exit_unknown, gone.code);
    try std.testing.expectEqualStrings("fx: the sandbox reached its time limit\n", gone.note);

    const refused = try exitNoteOf(arena, .{ .sandbox_refused = .{ .step = "exec", .status = 410, .detail = vercel.session_ended_detail } });
    try std.testing.expectEqual(exit_did_not_run, refused.code);
    try std.testing.expectEqualStrings("fx: did not run: the Vercel sandbox could not start: 410 the session ended before the command started; run it again\n", refused.note);

    const not_sent = try exitNoteOf(arena, .{ .not_sent = "ConnectionRefused" });
    try std.testing.expectEqual(exit_did_not_run, not_sent.code);
    try std.testing.expectEqualStrings("fx: did not run: sending the command failed: ConnectionRefused\n", not_sent.note);
}
