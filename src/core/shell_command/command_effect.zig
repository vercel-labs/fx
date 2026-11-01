const std = @import("std");
const command_lex = @import("command_lex.zig");
const safe_git = @import("safe_git.zig");

const max_command_bytes = 8 * 1024;
const max_ls_operands = 64;
const max_git_pathspecs = 64;
const max_line_count = 10_000;
const max_git_log_count = 1_000;
pub const max_direct_pipeline_stages = 8;

/// Returns true only for a small parsed set of ordinary development commands
/// whose effects are expected and recoverable in auto mode. Unknown syntax,
/// dynamic shell expansion, publication, deletion, and wrappers remain on the
/// normal review path.
pub fn knownReversibleAutoCommand(
    alloc: std.mem.Allocator,
    command: []const u8,
    background: bool,
) std.mem.Allocator.Error!bool {
    if (background) return false;
    const trimmed = std.mem.trim(u8, command, " \t");
    if (trimmed.len == 0 or trimmed.len > max_command_bytes or
        std.mem.findScalar(u8, trimmed, '\n') != null or
        std.mem.findScalar(u8, trimmed, '\r') != null)
    {
        return false;
    }

    var argv = command_lex.tokenize_argv(alloc, trimmed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer argv.deinit(alloc);
    if (argv.tokens.len == 0) return false;

    var stage_start: usize = 0;
    var index: usize = 0;
    while (index <= argv.tokens.len) : (index += 1) {
        const at_end = index == argv.tokens.len;
        if (!at_end and !isStageSeparator(argv.tokens[index])) {
            if (isUnsupportedAutoControlOperator(argv.tokens[index])) return false;
            continue;
        }
        if (!reversibleAutoStage(argv.tokens[stage_start..index])) return false;
        stage_start = index + 1;
    }
    return true;
}

/// The `&&` between two stages. Only a bare `&&` separates commands: the
/// shell passes a quoted or escaped one, such as `'&&'` or `\&\&`, to the
/// command as an argument, so it is one here too.
fn isStageSeparator(token: command_lex.ArgvToken) bool {
    return std.mem.eql(u8, token.raw, "&&");
}

/// Every shell reads a word that starts with an unquoted `#` as the start of
/// a comment, so the rest of the command never reaches the program.
fn startsComment(raw: []const u8) bool {
    return raw.len > 0 and raw[0] == '#';
}

fn isUnsupportedAutoOperator(token: command_lex.ArgvToken) bool {
    return isUnsupportedAutoControlOperator(token) or
        (!token.quoted and command_lex.redirection_kind(token.value) != null);
}

fn isUnsupportedAutoControlOperator(token: command_lex.ArgvToken) bool {
    if (token.quoted) return false;
    if (std.mem.eql(u8, token.value, "&&")) return false;
    return std.mem.eql(u8, token.value, "|") or
        std.mem.eql(u8, token.value, "||") or
        std.mem.eql(u8, token.value, "&") or
        std.mem.eql(u8, token.value, ";") or
        std.mem.eql(u8, token.value, "(") or
        std.mem.eql(u8, token.value, ")") or
        std.mem.eql(u8, token.value, "{") or
        std.mem.eql(u8, token.value, "}");
}

/// `tokens` without a trailing unquoted `2>&1`, the one redirection a
/// review-free stage may end with. The shell reads `2` as a file descriptor
/// only when it is written bare and touches `>&`: `\2>&1` and `2 >&1` pass
/// `2` to the command and redirect standard output instead.
fn withoutStderrToStdout(tokens: []const command_lex.ArgvToken) []const command_lex.ArgvToken {
    if (tokens.len < 3) return tokens;
    const descriptor = tokens[tokens.len - 3];
    const operator = tokens[tokens.len - 2];
    const target = tokens[tokens.len - 1];
    if (std.mem.eql(u8, descriptor.raw, "2") and
        descriptor.end == operator.start and
        !operator.quoted and
        !target.quoted and
        std.mem.eql(u8, operator.value, ">&") and
        std.mem.eql(u8, target.value, "1"))
    {
        return tokens[0 .. tokens.len - 3];
    }
    return tokens;
}

fn reversibleAutoStage(raw_tokens: []const command_lex.ArgvToken) bool {
    const tokens = withoutStderrToStdout(raw_tokens);
    if (tokens.len == 0) return false;
    for (tokens) |token| {
        if (isUnsupportedAutoOperator(token) or
            tokenHasDynamicShellSyntax(token.raw) or
            startsComment(token.raw))
        {
            return false;
        }
    }

    const executable = tokens[0].value;
    const words = tokens[1..];
    if (std.mem.eql(u8, executable, "node")) {
        return words.len == 1 and isVersionFlag(words[0].value);
    }
    if (std.mem.eql(u8, executable, "which")) {
        return words.len > 0 and allOperands(words);
    }
    if (std.mem.eql(u8, executable, "git")) return reversibleGit(words);
    if (std.mem.eql(u8, executable, "npm")) return reversibleNpm(words);
    if (std.mem.eql(u8, executable, "bun")) return reversiblePackageRunner(words);
    if (std.mem.eql(u8, executable, "pnpm")) return reversiblePackageRunner(words);
    if (std.mem.eql(u8, executable, "yarn")) return reversiblePackageRunner(words);
    if (std.mem.eql(u8, executable, "zig")) {
        return words.len > 0 and std.mem.eql(u8, words[0].value, "build");
    }
    return false;
}

// `^` and `#` are globs in zsh with `extendedglob`, which fx replays from the
// user's startup files: `^x` matches every file not named `x`, and `x#`
// matches any run of `x`, so a workspace file could supply the word.
fn tokenHasDynamicShellSyntax(raw: []const u8) bool {
    for (raw) |byte| switch (byte) {
        '$', '`', '*', '?', '[', '~', '^', '#', '\n', '\r', ';', '(', ')', '{', '}' => return true,
        else => {},
    };
    return false;
}

fn isVersionFlag(value: []const u8) bool {
    return std.mem.eql(u8, value, "-v") or
        std.mem.eql(u8, value, "--version");
}

fn allOperands(tokens: []const command_lex.ArgvToken) bool {
    for (tokens) |token| {
        if (token.value.len == 0 or token.value[0] == '-') return false;
    }
    return true;
}

fn reversibleGit(words: []const command_lex.ArgvToken) bool {
    if (words.len == 0) return false;
    const subcommand = words[0].value;
    if (std.mem.eql(u8, subcommand, "status")) return true;
    if (std.mem.eql(u8, subcommand, "remote")) {
        return words.len == 2 and std.mem.eql(u8, words[1].value, "-v");
    }
    if (std.mem.eql(u8, subcommand, "worktree")) {
        return words.len >= 2 and std.mem.eql(u8, words[1].value, "list");
    }
    if (std.mem.eql(u8, subcommand, "fetch")) return reversibleGitFetch(words[1..]);
    return false;
}

/// Options `git fetch` may use without review. git accepts any unambiguous
/// prefix of a long option, so an option spelled any other way goes to
/// review. That keeps out `--upload-pack`, which names a command for git to
/// run, and the prune options, which delete remote-tracking branches.
const reversible_git_fetch_flags = [_][]const u8{
    "--all",                    "--tags",               "-t",
    "--no-tags",                "-n",                   "--quiet",
    "-q",                       "--verbose",            "-v",
    "--dry-run",                "--force",              "-f",
    "--unshallow",              "--update-shallow",     "--progress",
    "--multiple",               "--atomic",             "--append",
    "-a",                       "--porcelain",          "--show-forced-updates",
    "--no-show-forced-updates", "--write-fetch-head",   "--no-write-fetch-head",
    "--set-upstream",           "--refetch",            "--prefetch",
    "--ipv4",                   "-4",                   "--ipv6",
    "-6",                       "--recurse-submodules", "--no-recurse-submodules",
};

/// Options that take a value, accepted only as `--name=value`. `--filter`
/// is left out: it turns a full clone into a partial clone for good.
const reversible_git_fetch_value_options = [_][]const u8{
    "--depth=", "--deepen=",             "--shallow-since=", "--shallow-exclude=",
    "--jobs=",  "--recurse-submodules=",
};

fn reversibleGitFetch(words: []const command_lex.ArgvToken) bool {
    var options_ended = false;
    for (words) |word| {
        const value = word.value;
        if (!options_ended and std.mem.eql(u8, value, "--")) {
            // Everything after `--` names a repository or a refspec.
            options_ended = true;
            continue;
        }
        if (!options_ended and value.len > 0 and value[0] == '-') {
            if (!isReversibleGitFetchOption(value)) return false;
            continue;
        }
        if (namesGitRemoteHelper(value)) return false;
    }
    return true;
}

/// Transports git runs itself, case-insensitively. git sends any other
/// `<scheme>://` URL to a `git-remote-<scheme>` program, and `http` and
/// `https` to the ones in its own exec path, which it searches before `PATH`.
const builtin_git_url_schemes = [_][]const u8{ "file", "git", "ssh", "git+ssh", "ssh+git", "http", "https" };

/// Whether git hands this repository to a remote helper it may find on
/// `PATH`: `<helper>::<address>`, or a URL whose scheme is not a built-in
/// transport. git reads the helper's name the way `transport_get` does.
fn namesGitRemoteHelper(value: []const u8) bool {
    var end: usize = 0;
    while (end < value.len) : (end += 1) {
        const byte = value[end];
        const special = byte == '+' or byte == '-' or byte == '.';
        if (!std.ascii.isAlphanumeric(byte) and (end == 0 or !special)) break;
    }
    if (end == 0) return false;
    const rest = value[end..];
    if (std.mem.startsWith(u8, rest, "::")) return true;
    if (!std.mem.startsWith(u8, rest, "://")) return false;
    for (builtin_git_url_schemes) |scheme| {
        if (std.ascii.eqlIgnoreCase(value[0..end], scheme)) return false;
    }
    return true;
}

fn isReversibleGitFetchOption(value: []const u8) bool {
    for (reversible_git_fetch_flags) |flag| {
        if (std.mem.eql(u8, value, flag)) return true;
    }
    for (reversible_git_fetch_value_options) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) return true;
    }
    return false;
}

fn reversibleNpm(words: []const command_lex.ArgvToken) bool {
    if (words.len == 1 and isVersionFlag(words[0].value)) return true;
    if (words.len == 0) return false;
    const subcommand = words[0].value;
    if (std.mem.eql(u8, subcommand, "install") or
        std.mem.eql(u8, subcommand, "i") or
        std.mem.eql(u8, subcommand, "ci") or
        std.mem.eql(u8, subcommand, "test"))
    {
        return !hasGlobalPackageFlag(words[1..]);
    }
    return std.mem.eql(u8, subcommand, "run") and words.len >= 2;
}

fn reversiblePackageRunner(words: []const command_lex.ArgvToken) bool {
    if (words.len == 1 and isVersionFlag(words[0].value)) return true;
    if (words.len == 0) return false;
    const subcommand = words[0].value;
    if (std.mem.eql(u8, subcommand, "install") or
        std.mem.eql(u8, subcommand, "test"))
    {
        return !hasGlobalPackageFlag(words[1..]);
    }
    return std.mem.eql(u8, subcommand, "run") and words.len >= 2;
}

fn hasGlobalPackageFlag(words: []const command_lex.ArgvToken) bool {
    for (words) |word| {
        if (std.mem.eql(u8, word.value, "-g") or
            std.mem.eql(u8, word.value, "--global") or
            std.mem.eql(u8, word.value, "--location") or
            std.mem.eql(u8, word.value, "--location=global") or
            std.mem.eql(u8, word.value, "--prefix") or
            std.mem.startsWith(u8, word.value, "--prefix=")) return true;
    }
    return false;
}

const PrintfFormatLanguage = enum {
    portable_literal_newline_percent_string,
};

const PrintfPolicy = struct {
    executable: []const u8,
    format_language: PrintfFormatLanguage = .portable_literal_newline_percent_string,
};

test "known reversible auto commands exclude destructive and hidden effects" {
    for ([_][]const u8{
        "node -v",
        "node -v && npm -v",
        "which node npm && node -v",
        "git status --short --branch",
        "git remote -v",
        "git worktree list --porcelain",
        "git fetch origin main",
        "git fetch --all --tags",
        "git fetch --depth=1 origin main",
        "git fetch --no-tags origin +main:main",
        "git fetch origin -- --not-an-option",
        "git fetch https://github.com/vercel-labs/fx main",
        "git fetch HTTPS://github.com/vercel-labs/fx",
        "git fetch ssh://git@github.com/vercel-labs/fx.git",
        "git fetch git@github.com:vercel-labs/fx.git",
        "git fetch file:///tmp/repository",
        "git fetch ../other main",
        "npm install 2>&1",
        "npm run dev",
        "zig build test",
        "bun test",
    }) |command| {
        try std.testing.expect(try knownReversibleAutoCommand(
            std.testing.allocator,
            command,
            false,
        ));
    }
    for ([_][]const u8{
        "rm -rf .",
        "git rm -r netlify",
        "git push origin HEAD",
        "cat ~/.ssh/id_rsa",
        "sh -c 'npm install'",
        "npm exec -- rm -rf .",
        "npm install --prefix=/tmp/global",
        "npm install --location global",
        "git fetch --prune origin",
        // A quoted or escaped `&&` is an argument, so `--prune` here reaches
        // `git fetch`.
        "git fetch '&&' git status --prune",
        "git fetch \\&\\& git status --prune",
        // Every shell drops `#note` as a comment.
        "git status #note",
        "git fetch -p",
        // `--upload-pack` names a command for git to run, and git accepts
        // any unambiguous prefix of it.
        "git fetch --upload-pack=x .",
        "git fetch --upload-pack x origin",
        "git fetch --upl=x .",
        "git fetch origin --upload-pack=x",
        "git fetch '--upload-pack=x' .",
        // A filter turns a full clone into a partial clone.
        "git fetch --filter=blob:none origin",
        // git runs a `git-remote-<helper>` program, which it may find on
        // `PATH`, for these repositories, also after `--`.
        "git fetch probe::x",
        "git fetch ext::sh",
        "git fetch 'probe.v2+x::y' main",
        "git fetch -- probe::x",
        "git fetch origin -- probe::x",
        "git fetch --multiple origin probe::x",
        "git fetch probe://host/repository",
        "git fetch PROBE://host/repository",
        "git fetch ftp://host/repository",
        // zsh's `extendedglob` expands these to workspace file names.
        "git fetch ^nomatch .",
        "git fetch --prun#e",
        "npm install react@^18",
        "npm test x##",
        // The shell reads `2` as a file descriptor only when it is bare and
        // touches `>&`. Each of these passes `2` to git as an argument and
        // redirects standard output.
        "git status \\2>&1",
        "git status\t\\2>&1",
        "git status 2 >&1",
        "git status '2'>&1",
    }) |command| {
        try std.testing.expect(!try knownReversibleAutoCommand(
            std.testing.allocator,
            command,
            false,
        ));
    }
    try std.testing.expect(!try knownReversibleAutoCommand(
        std.testing.allocator,
        "npm run dev",
        true,
    ));
}

const LsSymlinkSemantics = enum {
    platform_default,
};

const LsPolicy = struct {
    executable: []const u8,
    forced_argv: []const []const u8,
    symlink_semantics: LsSymlinkSemantics = .platform_default,
};

pub const ApprovalReason = enum {
    filesystem_write,
    network_access,
    process_or_system,
    background_process,
    dynamic_shell,
    unsupported_shell,
    unsupported_platform,
    unsupported_input_redirect,
    unsupported_argument,
    command_owned_input,
    unknown_command,
    planning_failure,
    /// fx could not apply its git safety settings in this directory.
    unsafe_git,
};

pub const EnvironmentProfile = enum {
    basic_read_only,
    git_read_only,
};

pub const DirectStage = struct {
    executable: []const u8,
    argv: []const []const u8,
    environment_profile: EnvironmentProfile,
};

pub const DirectReadOnlyPlan = struct {
    command: []const u8,
    cwd: []const u8,
    stages: []const DirectStage,

    pub fn deinit(self: *DirectReadOnlyPlan, alloc: std.mem.Allocator) void {
        for (self.stages) |stage| {
            for (stage.argv) |arg| alloc.free(arg);
            alloc.free(stage.argv);
        }
        alloc.free(self.stages);
        alloc.free(self.cwd);
        alloc.free(self.command);
        self.* = undefined;
    }
};

pub const Admission = union(enum) {
    direct_read_only: DirectReadOnlyPlan,
    approval_required: ApprovalReason,

    pub fn deinit(self: *Admission, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .direct_read_only => |*direct| direct.deinit(alloc),
            .approval_required => {},
        }
        self.* = undefined;
    }
};

pub fn plan(
    alloc: std.mem.Allocator,
    command: []const u8,
    resolved_cwd: []const u8,
    background: bool,
    target_os: std.Target.Os.Tag,
) std.mem.Allocator.Error!Admission {
    return planWithGit(alloc, command, resolved_cwd, background, target_os, .prepare);
}

/// How git stages learn whether safe git can run: prepared in the command's
/// directory, or fixed by a test.
const GitSource = union(enum) {
    prepare,
    fixed: safe_git.Prepared,
};

const GitResolver = struct {
    source: GitSource,
    cwd: []const u8,
    prepared: ?safe_git.Prepared = null,

    /// Prepares at most once per plan, and only for a supported git stage.
    fn get(self: *GitResolver, arena: std.mem.Allocator) std.mem.Allocator.Error!safe_git.Prepared {
        if (self.prepared) |prepared| return prepared;
        const prepared = switch (self.source) {
            .prepare => try safe_git.prepare(arena, self.cwd),
            .fixed => |fixed| fixed,
        };
        self.prepared = prepared;
        return prepared;
    }
};

fn planWithGit(
    alloc: std.mem.Allocator,
    command: []const u8,
    resolved_cwd: []const u8,
    background: bool,
    target_os: std.Target.Os.Tag,
    git_source: GitSource,
) std.mem.Allocator.Error!Admission {
    if (background) return .{ .approval_required = .background_process };
    if (target_os != .macos and target_os != .linux) {
        return .{ .approval_required = .unsupported_platform };
    }

    const trimmed = std.mem.trim(u8, command, " \t\n");
    if (trimmed.len == 0) return .{ .approval_required = .unknown_command };
    if (trimmed.len > max_command_bytes) return .{ .approval_required = .unsupported_argument };
    if (validateShellShape(trimmed)) |reason| {
        return .{ .approval_required = reason };
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const segments = command_lex.pipe_segments(scratch, trimmed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .approval_required = .unsupported_shell },
    };
    if (segments.len == 0) return .{ .approval_required = .unknown_command };
    if (segments.len > max_direct_pipeline_stages) {
        return .{ .approval_required = .process_or_system };
    }

    var git: GitResolver = .{ .source = git_source, .cwd = resolved_cwd };
    var planned: std.ArrayList(TemporaryStage) = .empty;
    for (segments) |segment| {
        if (segment.text.len == 0) return .{ .approval_required = .unsupported_shell };

        const argv = command_lex.tokenize_argv(scratch, segment.text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .approval_required = .unsupported_shell },
        };
        const parsed = try parseStage(scratch, argv.tokens, target_os, &git);
        switch (parsed) {
            .approval_required => |reason| return .{ .approval_required = reason },
            .direct => |stage| try planned.append(scratch, stage),
        }
    }

    return ownPlan(alloc, command, resolved_cwd, planned.items);
}

const TemporaryStage = struct {
    executable: []const u8,
    argv: []const []const u8,
    environment_profile: EnvironmentProfile = .basic_read_only,
};

const StageAdmission = union(enum) {
    direct: TemporaryStage,
    approval_required: ApprovalReason,
};

fn validateShellShape(command: []const u8) ?ApprovalReason {
    if (!std.unicode.utf8ValidateSlice(command) or std.mem.findScalar(u8, command, 0) != null) {
        return .unsupported_shell;
    }
    if (std.mem.findScalar(u8, command, '\r') != null) return .unsupported_shell;

    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const ch = command[i];

        if (in_single) {
            if (ch == '\'') in_single = false;
            continue;
        }
        if (in_double) {
            if (ch == '"') {
                in_double = false;
                continue;
            }
            if (ch == '$' or ch == '`') return .dynamic_shell;
            if (ch == '\\' or ch == '\n') return .unsupported_shell;
            continue;
        }

        switch (ch) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '$', '`', '*', '?', '[', '~' => return .dynamic_shell,
            '\\', '#', ';', '\n', '(', ')', '{', '}' => return .unsupported_shell,
            '&' => {
                if (i + 1 < command.len and command[i + 1] == '>') return .filesystem_write;
                return .unsupported_shell;
            },
            '|' => {
                if (i + 1 < command.len and command[i + 1] == '|') return .unsupported_shell;
            },
            '>' => return .filesystem_write,
            '<' => {
                if (i + 1 < command.len) {
                    switch (command[i + 1]) {
                        '(' => return .dynamic_shell,
                        '>' => return .filesystem_write,
                        '<', '&' => return .unsupported_shell,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    return if (in_single or in_double) .unsupported_shell else null;
}

fn parseStage(
    alloc: std.mem.Allocator,
    tokens: []const command_lex.ArgvToken,
    target_os: std.Target.Os.Tag,
    git: *GitResolver,
) std.mem.Allocator.Error!StageAdmission {
    var words: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < tokens.len) {
        const token = tokens[index];
        if (!token.quoted and std.mem.eql(u8, token.value, "<")) {
            return .{ .approval_required = .unsupported_input_redirect };
        }
        if (isOperatorToken(token)) return .{ .approval_required = .unsupported_shell };
        try words.append(alloc, token.value);
        index += 1;
    }

    if (words.items.len == 0) return .{ .approval_required = .unknown_command };
    if (std.mem.findScalar(u8, words.items[0], '=') != null) {
        return .{ .approval_required = .dynamic_shell };
    }

    const family = try planFamily(alloc, words.items, target_os, git);
    return switch (family) {
        .approval_required => |reason| .{ .approval_required = reason },
        .direct => |stage| .{ .direct = .{
            .executable = stage.executable,
            .argv = stage.argv,
            .environment_profile = stage.environment_profile,
        } },
    };
}

fn isOperatorToken(token: command_lex.ArgvToken) bool {
    if (token.quoted) return false;
    return std.mem.eql(u8, token.value, "|") or
        std.mem.eql(u8, token.value, "||") or
        std.mem.eql(u8, token.value, "&") or
        std.mem.eql(u8, token.value, "&&") or
        std.mem.eql(u8, token.value, ";") or
        command_lex.redirection_kind(token.value) != null;
}

fn planFamily(
    alloc: std.mem.Allocator,
    words: []const []const u8,
    target_os: std.Target.Os.Tag,
    git: *GitResolver,
) std.mem.Allocator.Error!StageAdmission {
    const command = words[0];
    if (isFilesystemMutation(command)) return .{ .approval_required = .filesystem_write };
    if (isNetworkCommand(command)) return .{ .approval_required = .network_access };
    if (isProcessOrSystemCommand(command)) return .{ .approval_required = .process_or_system };
    if (std.mem.eql(u8, command, "printf")) return planPrintf(alloc, words, target_os);
    if (std.mem.eql(u8, command, "pwd")) return planPwd(alloc, words);
    if (std.mem.eql(u8, command, "ls")) return planLs(alloc, words, target_os);
    if (std.mem.eql(u8, command, "wc")) return planWc(alloc, words);
    if (std.mem.eql(u8, command, "cat")) return planCat(alloc, words);
    if (std.mem.eql(u8, command, "head")) return planHeadOrTail(alloc, words, "/usr/bin/head");
    if (std.mem.eql(u8, command, "tail")) return planHeadOrTail(alloc, words, "/usr/bin/tail");
    if (std.mem.eql(u8, command, "grep")) return planGrep(alloc, words);
    if (std.mem.eql(u8, command, "git")) return planGit(alloc, words, git);
    return .{ .approval_required = .unknown_command };
}

fn planPrintf(
    alloc: std.mem.Allocator,
    words: []const []const u8,
    target_os: std.Target.Os.Tag,
) std.mem.Allocator.Error!StageAdmission {
    const policy = printfPolicy(target_os);
    if (words.len < 2) return .{ .approval_required = .unsupported_argument };
    const format = words[1];
    const conversions = printfStringConversionCount(format) orelse {
        return .{ .approval_required = .unsupported_argument };
    };
    if (words.len - 2 != conversions) return .{ .approval_required = .unsupported_argument };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, policy.executable);
    try argv.appendSlice(alloc, words[1..]);
    return .{ .direct = .{
        .executable = policy.executable,
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn printfPolicy(target_os: std.Target.Os.Tag) PrintfPolicy {
    return switch (target_os) {
        .macos, .linux => .{ .executable = "/usr/bin/printf" },
        else => unreachable,
    };
}

fn printfStringConversionCount(format: []const u8) ?usize {
    if (format.len == 0 or format[0] == '-') return null;

    var count: usize = 0;
    var index: usize = 0;
    while (index < format.len) {
        const ch = format[index];
        if (ch < 0x20 or ch > 0x7e) return null;
        if (ch == '\\') {
            if (index + 1 >= format.len or format[index + 1] != 'n') return null;
            index += 2;
            continue;
        }
        if (ch == '%') {
            if (index + 1 >= format.len) return null;
            switch (format[index + 1]) {
                '%' => {},
                's' => count += 1,
                else => return null,
            }
            index += 2;
            continue;
        }
        index += 1;
    }
    return count;
}

fn planPwd(
    alloc: std.mem.Allocator,
    words: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    if (words.len > 2 or (words.len == 2 and !std.mem.eql(u8, words[1], "-P"))) {
        return .{ .approval_required = .unsupported_argument };
    }
    const argv = try alloc.dupe([]const u8, &.{ "/bin/pwd", "-P" });
    return .{ .direct = .{
        .executable = "/bin/pwd",
        .argv = argv,
    } };
}

fn planLs(
    alloc: std.mem.Allocator,
    words: []const []const u8,
    target_os: std.Target.Os.Tag,
) std.mem.Allocator.Error!StageAdmission {
    const policy = lsPolicy(target_os);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, policy.executable);
    try argv.appendSlice(alloc, policy.forced_argv);

    var operands: std.ArrayList([]const u8) = .empty;
    var parsing_options = true;
    var explicit_separator = false;
    for (words[1..]) |word| {
        if (parsing_options and std.mem.eql(u8, word, "--")) {
            parsing_options = false;
            explicit_separator = true;
            continue;
        }
        if (parsing_options and word.len > 1 and word[0] == '-') {
            for (word[1..]) |flag| {
                const canonical = switch (flag) {
                    '1' => "-1",
                    'a' => "-a",
                    'A' => "-A",
                    'd' => "-d",
                    'F' => "-F",
                    'l', 'n' => "-n",
                    'p' => "-p",
                    else => return .{ .approval_required = .unsupported_argument },
                };
                try argv.append(alloc, canonical);
            }
            continue;
        }
        parsing_options = false;
        if (!explicit_separator and word.len > 1 and word[0] == '-') {
            return .{ .approval_required = .unsupported_argument };
        }
        try operands.append(alloc, word);
    }

    if (operands.items.len > max_ls_operands) {
        return .{ .approval_required = .unsupported_argument };
    }
    try argv.append(alloc, "--");
    try argv.appendSlice(alloc, operands.items);
    return .{ .direct = .{
        .executable = policy.executable,
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn lsPolicy(target_os: std.Target.Os.Tag) LsPolicy {
    return switch (target_os) {
        .macos, .linux => .{
            .executable = "/bin/ls",
            .forced_argv = &.{"-q"},
        },
        else => unreachable,
    };
}

fn planWc(
    alloc: std.mem.Allocator,
    words: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, "/usr/bin/wc");
    for (words[1..]) |word| {
        if (word.len < 2 or word[0] != '-') {
            return .{ .approval_required = .unsupported_argument };
        }
        for (word[1..]) |flag| {
            const canonical = switch (flag) {
                'L' => "-L",
                'c' => "-c",
                'l' => "-l",
                'm' => "-m",
                'w' => "-w",
                else => return .{ .approval_required = .unsupported_argument },
            };
            try argv.append(alloc, canonical);
        }
    }
    return .{ .direct = .{
        .executable = "/usr/bin/wc",
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn planCat(
    alloc: std.mem.Allocator,
    words: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    if (words.len != 1) return .{ .approval_required = .unsupported_argument };
    const argv = try alloc.dupe([]const u8, &.{"/bin/cat"});
    return .{ .direct = .{
        .executable = "/bin/cat",
        .argv = argv,
    } };
}

fn planHeadOrTail(
    alloc: std.mem.Allocator,
    words: []const []const u8,
    executable: []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var index: usize = 1;
    var count: []const u8 = "10";
    if (index < words.len and std.mem.eql(u8, words[index], "-n")) {
        if (index + 1 >= words.len or !boundedDecimal(words[index + 1], max_line_count)) {
            return .{ .approval_required = .unsupported_argument };
        }
        count = words[index + 1];
        index += 2;
    }

    if (index != words.len) return .{ .approval_required = .unsupported_argument };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ executable, "-n", count });
    return .{ .direct = .{
        .executable = executable,
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn planGrep(
    alloc: std.mem.Allocator,
    words: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, "/usr/bin/grep");

    var index: usize = 1;
    while (index < words.len) : (index += 1) {
        const word = words[index];
        if (std.mem.eql(u8, word, "--")) {
            index += 1;
            break;
        }
        if (word.len <= 1 or word[0] != '-') break;
        for (word[1..]) |flag| {
            const canonical = switch (flag) {
                'E' => "-E",
                'F' => "-F",
                'i' => "-i",
                'n' => "-n",
                'v' => "-v",
                else => return .{ .approval_required = .unsupported_argument },
            };
            try argv.append(alloc, canonical);
        }
    }
    if (index >= words.len) return .{ .approval_required = .unsupported_argument };
    if (words.len - index != 1) {
        return .{ .approval_required = .unsupported_argument };
    }
    try argv.append(alloc, "--");
    try argv.append(alloc, words[index]);
    return .{ .direct = .{
        .executable = "/usr/bin/grep",
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn planGit(
    alloc: std.mem.Allocator,
    words: []const []const u8,
    git: *GitResolver,
) std.mem.Allocator.Error!StageAdmission {
    if (words.len < 2) return .{ .approval_required = .command_owned_input };
    const subcommand: safe_git.Subcommand = if (std.mem.eql(u8, words[1], "status"))
        .status
    else if (std.mem.eql(u8, words[1], "diff"))
        .diff
    else if (std.mem.eql(u8, words[1], "log"))
        .log
    else
        return .{ .approval_required = .command_owned_input };
    const ready = switch (try git.get(alloc)) {
        .ready => |ready| ready,
        .refused => return .{ .approval_required = .unsafe_git },
    };
    return switch (subcommand) {
        .status => planGitStatus(alloc, ready, words[2..]),
        .diff => planGitDiff(alloc, ready, words[2..]),
        .log => planGitLog(alloc, ready, words[2..]),
        .branch, .rev_parse => unreachable,
    };
}

fn directGit(ready: safe_git.Ready, argv: []const []const u8) StageAdmission {
    return .{ .direct = .{
        .executable = ready.executable,
        .argv = argv,
        .environment_profile = .git_read_only,
    } };
}

fn planGitStatus(
    alloc: std.mem.Allocator,
    ready: safe_git.Ready,
    arguments: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try safe_git.appendCommand(alloc, &argv, ready, .status);
    for (arguments) |argument| {
        const canonical = if (std.mem.eql(u8, argument, "-s"))
            "--short"
        else if (std.mem.eql(u8, argument, "-b"))
            "--branch"
        else if (std.mem.eql(u8, argument, "--short") or
            std.mem.eql(u8, argument, "--branch") or
            std.mem.eql(u8, argument, "--porcelain") or
            std.mem.eql(u8, argument, "--porcelain=v1") or
            std.mem.eql(u8, argument, "--untracked-files=no") or
            std.mem.eql(u8, argument, "--untracked-files=normal") or
            std.mem.eql(u8, argument, "--untracked-files=all"))
            argument
        else
            return .{ .approval_required = .unsupported_argument };
        try argv.append(alloc, canonical);
    }
    return directGit(ready, try argv.toOwnedSlice(alloc));
}

fn planGitDiff(
    alloc: std.mem.Allocator,
    ready: safe_git.Ready,
    arguments: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try safe_git.appendCommand(alloc, &argv, ready, .diff);
    try argv.append(alloc, "--color=never");

    var index: usize = 0;
    while (index < arguments.len and !std.mem.eql(u8, arguments[index], "--")) : (index += 1) {
        const argument = arguments[index];
        if (!(std.mem.eql(u8, argument, "--cached") or
            std.mem.eql(u8, argument, "--staged") or
            std.mem.eql(u8, argument, "--stat") or
            std.mem.eql(u8, argument, "--shortstat") or
            std.mem.eql(u8, argument, "--numstat") or
            std.mem.eql(u8, argument, "--name-only") or
            std.mem.eql(u8, argument, "--name-status") or
            std.mem.eql(u8, argument, "--check") or
            std.mem.eql(u8, argument, "--no-renames")))
        {
            return .{ .approval_required = .unsupported_argument };
        }
        try argv.append(alloc, argument);
    }
    const operands = if (index < arguments.len) arguments[index + 1 ..] else &.{};
    if (operands.len > max_git_pathspecs) {
        return .{ .approval_required = .unsupported_argument };
    }
    try argv.append(alloc, "--");
    try argv.appendSlice(alloc, operands);
    return directGit(ready, try argv.toOwnedSlice(alloc));
}

fn planGitLog(
    alloc: std.mem.Allocator,
    ready: safe_git.Ready,
    arguments: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try safe_git.appendCommand(alloc, &argv, ready, .log);
    try argv.appendSlice(alloc, &.{ "--color=never", "--max-count=100" });

    var index: usize = 0;
    while (index < arguments.len and !std.mem.eql(u8, arguments[index], "--")) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "-n")) {
            if (index + 1 >= arguments.len or !boundedDecimal(arguments[index + 1], max_git_log_count)) {
                return .{ .approval_required = .unsupported_argument };
            }
            try argv.appendSlice(alloc, arguments[index .. index + 2]);
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--max-count=")) {
            if (!boundedDecimal(argument["--max-count=".len..], max_git_log_count)) {
                return .{ .approval_required = .unsupported_argument };
            }
            try argv.append(alloc, argument);
            continue;
        }
        if (!(std.mem.eql(u8, argument, "--oneline") or
            std.mem.eql(u8, argument, "--stat") or
            std.mem.eql(u8, argument, "--shortstat") or
            std.mem.eql(u8, argument, "--name-only") or
            std.mem.eql(u8, argument, "--name-status") or
            std.mem.eql(u8, argument, "--no-merges") or
            std.mem.eql(u8, argument, "--decorate") or
            std.mem.eql(u8, argument, "--decorate=short") or
            std.mem.eql(u8, argument, "--decorate=no")))
        {
            return .{ .approval_required = .unsupported_argument };
        }
        try argv.append(alloc, argument);
    }
    const operands = if (index < arguments.len) arguments[index + 1 ..] else &.{};
    if (operands.len > max_git_pathspecs) {
        return .{ .approval_required = .unsupported_argument };
    }
    try argv.append(alloc, "--");
    try argv.appendSlice(alloc, operands);
    return directGit(ready, try argv.toOwnedSlice(alloc));
}

fn boundedDecimal(value: []const u8, maximum: usize) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return false;
    return parsed <= maximum;
}

fn isFilesystemMutation(command: []const u8) bool {
    return std.mem.eql(u8, command, "touch") or
        std.mem.eql(u8, command, "rm") or
        std.mem.eql(u8, command, "mkdir") or
        std.mem.eql(u8, command, "rmdir") or
        std.mem.eql(u8, command, "mv") or
        std.mem.eql(u8, command, "cp") or
        std.mem.eql(u8, command, "install") or
        std.mem.eql(u8, command, "chmod") or
        std.mem.eql(u8, command, "chown") or
        std.mem.eql(u8, command, "ln");
}

fn isNetworkCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "curl") or
        std.mem.eql(u8, command, "wget") or
        std.mem.eql(u8, command, "ssh") or
        std.mem.eql(u8, command, "scp") or
        std.mem.eql(u8, command, "nc");
}

fn isProcessOrSystemCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "sh") or
        std.mem.eql(u8, command, "bash") or
        std.mem.eql(u8, command, "zsh") or
        std.mem.eql(u8, command, "dash") or
        std.mem.eql(u8, command, "env") or
        std.mem.eql(u8, command, "xargs") or
        std.mem.eql(u8, command, "sudo") or
        std.mem.eql(u8, command, "doas") or
        std.mem.eql(u8, command, "kill") or
        std.mem.eql(u8, command, "pkill") or
        std.mem.eql(u8, command, "nohup");
}

fn ownPlan(
    alloc: std.mem.Allocator,
    command: []const u8,
    resolved_cwd: []const u8,
    temporary: []const TemporaryStage,
) std.mem.Allocator.Error!Admission {
    const owned_command = try alloc.dupe(u8, command);
    errdefer alloc.free(owned_command);
    const cwd = try alloc.dupe(u8, resolved_cwd);
    errdefer alloc.free(cwd);
    const stages = try alloc.alloc(DirectStage, temporary.len);
    var initialized: usize = 0;
    errdefer {
        for (stages[0..initialized]) |stage| {
            for (stage.argv) |arg| alloc.free(arg);
            alloc.free(stage.argv);
        }
        alloc.free(stages);
    }

    for (temporary, 0..) |stage, stage_index| {
        const argv = try alloc.alloc([]const u8, stage.argv.len);
        var argv_initialized: usize = 0;
        errdefer {
            for (argv[0..argv_initialized]) |arg| alloc.free(arg);
            alloc.free(argv);
        }
        for (stage.argv, 0..) |arg, arg_index| {
            argv[arg_index] = try alloc.dupe(u8, arg);
            argv_initialized += 1;
        }
        stages[stage_index] = .{
            .executable = stage.executable,
            .argv = argv,
            .environment_profile = stage.environment_profile,
        };
        initialized += 1;
    }

    return .{ .direct_read_only = .{
        .command = owned_command,
        .cwd = cwd,
        .stages = stages,
    } };
}

test "planner canonicalizes pwd to a fixed physical path" {
    var admission = try plan(
        std.testing.allocator,
        "pwd",
        "/workspace",
        false,
        .macos,
    );
    defer admission.deinit(std.testing.allocator);

    switch (admission) {
        .direct_read_only => |direct| {
            try std.testing.expectEqualStrings("/workspace", direct.cwd);
            try std.testing.expectEqual(@as(usize, 1), direct.stages.len);
            try std.testing.expectEqualStrings("/bin/pwd", direct.stages[0].executable);
            try std.testing.expectEqual(@as(usize, 2), direct.stages[0].argv.len);
            try std.testing.expectEqualStrings("/bin/pwd", direct.stages[0].argv[0]);
            try std.testing.expectEqualStrings("-P", direct.stages[0].argv[1]);
            try std.testing.expectEqual(EnvironmentProfile.basic_read_only, direct.stages[0].environment_profile);
        },
        .approval_required => |reason| {
            std.debug.print("unexpected approval reason: {s}\n", .{@tagName(reason)});
            return error.TestExpectedDirectPlan;
        },
    }
}

/// Planner tests use a fixed safe-git result, so they do not depend on the
/// host's git. `safe_git.zig` tests the real preparation.
const test_git: GitSource = .{ .fixed = .{ .ready = .{ .executable = "/usr/bin/git", .filter_names = &.{} } } };

fn expectDirect(command: []const u8, target_os: std.Target.Os.Tag) !Admission {
    const admission = try planWithGit(
        std.testing.allocator,
        command,
        "/workspace",
        false,
        target_os,
        test_git,
    );
    if (admission == .approval_required) {
        std.debug.print(
            "expected direct plan for \"{s}\", got {s}\n",
            .{ command, @tagName(admission.approval_required) },
        );
        var unexpected = admission;
        defer unexpected.deinit(std.testing.allocator);
        return error.TestExpectedDirectPlan;
    }
    return admission;
}

fn expectApproval(
    command: []const u8,
    background: bool,
    target_os: std.Target.Os.Tag,
    expected: ApprovalReason,
) !void {
    return expectApprovalWithGit(command, background, target_os, expected, test_git);
}

fn expectApprovalWithGit(
    command: []const u8,
    background: bool,
    target_os: std.Target.Os.Tag,
    expected: ApprovalReason,
    git_source: GitSource,
) !void {
    var admission = try planWithGit(
        std.testing.allocator,
        command,
        "/workspace",
        background,
        target_os,
        git_source,
    );
    defer admission.deinit(std.testing.allocator);

    switch (admission) {
        .direct_read_only => return error.TestExpectedApproval,
        .approval_required => |reason| try std.testing.expectEqual(expected, reason),
    }
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

fn appendShellSingleQuoted(
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    value: []const u8,
) !void {
    std.debug.assert(std.mem.findScalar(u8, value, '\'') == null);
    try list.append(alloc, '\'');
    try list.appendSlice(alloc, value);
    try list.append(alloc, '\'');
}

fn buildPrintfCommand(
    alloc: std.mem.Allocator,
    format: []const u8,
    data: []const []const u8,
) ![]u8 {
    var command: std.ArrayList(u8) = .empty;
    errdefer command.deinit(alloc);
    try command.appendSlice(alloc, "printf ");
    try appendShellSingleQuoted(&command, alloc, format);
    for (data) |value| {
        try command.append(alloc, ' ');
        try appendShellSingleQuoted(&command, alloc, value);
    }
    return command.toOwnedSlice(alloc);
}

fn expectNativePrintfEquivalent(command: []const u8, target_os: std.Target.Os.Tag) !void {
    var admission = try expectDirect(command, target_os);
    defer admission.deinit(std.testing.allocator);
    const argv = admission.direct_read_only.stages[0].argv;

    const shell_argv = [_][]const u8{ "/bin/sh", "-lc", command };
    const shell_result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &shell_argv,
    });
    defer std.testing.allocator.free(shell_result.stdout);
    defer std.testing.allocator.free(shell_result.stderr);

    const direct_result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = argv,
    });
    defer std.testing.allocator.free(direct_result.stdout);
    defer std.testing.allocator.free(direct_result.stderr);

    if (!std.meta.eql(shell_result.term, direct_result.term) or
        !std.mem.eql(u8, shell_result.stdout, direct_result.stdout) or
        !std.mem.eql(u8, shell_result.stderr, direct_result.stderr))
    {
        std.debug.print(
            "native printf mismatch target={s} command={s} shell_term={any} direct_term={any} shell_stdout={any} direct_stdout={any} shell_stderr={any} direct_stderr={any}\n",
            .{
                @tagName(target_os),
                command,
                shell_result.term,
                direct_result.term,
                shell_result.stdout,
                direct_result.stdout,
                shell_result.stderr,
                direct_result.stderr,
            },
        );
        return error.TestExpectedEqual;
    }
}

test "planner admits the reviewed direct command matrix" {
    const cases = [_][]const u8{
        "printf 'hello\\n'",
        "printf x",
        "printf '%%'",
        "printf '%s' '--help'",
        "printf '%s%s' one two",
        "printf '$(touch x)'",
        "pwd",
        "pwd -P",
        "ls",
        "ls src",
        "ls -la src",
        "ls -- -option-looking-path",
        "wc",
        "wc -Lclmw",
        "cat",
        "head",
        "head -n 20",
        "tail -n 20",
        "grep -n TODO",
        "grep -Fi -- '-needle'",
        "git status",
        "git status --short --branch",
        "git diff --stat",
        "git diff --name-only -- src",
        "git log --oneline -n 5",
        "git log --max-count=20 -- src",
        "printf x | wc -c",
        "git status --short | wc -l",
    };

    for (cases) |command| {
        var admission = try expectDirect(command, .macos);
        admission.deinit(std.testing.allocator);
    }

    try expectApproval(
        "wc -c < input.txt",
        false,
        .linux,
        .unsupported_input_redirect,
    );
}

test "planner returns stable reasons for approval-bearing forms" {
    const Case = struct {
        command: []const u8,
        reason: ApprovalReason,
        target_os: std.Target.Os.Tag = .macos,
    };
    const cases = [_]Case{
        .{ .command = "touch created.txt", .reason = .filesystem_write },
        .{ .command = "printf x>created.txt", .reason = .filesystem_write },
        .{ .command = "printf x >> created.txt", .reason = .filesystem_write },
        .{ .command = "printf x 2>errors.txt", .reason = .filesystem_write },
        .{ .command = "cat <> state.txt", .reason = .filesystem_write },
        .{ .command = "rm file", .reason = .filesystem_write },
        .{ .command = "curl https://example.com", .reason = .network_access },
        .{ .command = "printf \"$(touch created.txt)\"", .reason = .dynamic_shell },
        .{ .command = "printf `touch created.txt`", .reason = .dynamic_shell },
        .{ .command = "cat <(touch created.txt)", .reason = .dynamic_shell },
        .{ .command = "git status && touch created.txt", .reason = .unsupported_shell },
        .{ .command = "printf x | tee created.txt", .reason = .unknown_command },
        .{ .command = "printf x | wc -c < input.txt", .reason = .unsupported_input_redirect, .target_os = .linux },
        .{ .command = "sh -c 'printf x'", .reason = .process_or_system },
        .{ .command = "PATH=/tmp ls", .reason = .dynamic_shell },
        .{ .command = "pwd -L", .reason = .unsupported_argument },
        .{ .command = "pwd extra", .reason = .unsupported_argument },
        .{ .command = "ls -R", .reason = .unsupported_argument },
        .{ .command = "ls -L linked-dir", .reason = .unsupported_argument },
        .{ .command = "ls --color=always", .reason = .unsupported_argument },
        .{ .command = "ls -e", .reason = .unsupported_argument },
        .{ .command = "wc -c input.txt", .reason = .unsupported_argument },
        .{ .command = "wc -c /dev/null", .reason = .unsupported_argument },
        .{ .command = "wc -c fifo", .reason = .unsupported_argument },
        .{ .command = "wc --files0-from=paths", .reason = .unsupported_argument },
        .{ .command = "git -C other status", .reason = .command_owned_input },
        .{ .command = "git push origin HEAD", .reason = .command_owned_input },
        .{ .command = "git status --ignored", .reason = .unsupported_argument },
        .{ .command = "git status --short -- src", .reason = .unsupported_argument },
        .{ .command = "git diff --ext-diff", .reason = .unsupported_argument },
        .{ .command = "git diff HEAD", .reason = .unsupported_argument },
        .{ .command = "git log -p", .reason = .unsupported_argument },
        .{ .command = "git log -n 1001", .reason = .unsupported_argument },
        .{ .command = "git log --format='%x00'", .reason = .unsupported_argument },
        .{ .command = "cat -n README.md", .reason = .unsupported_argument },
        .{ .command = "cat README.md", .reason = .unsupported_argument },
        .{ .command = "cat /tmp/.ssh/id_ed25519", .reason = .unsupported_argument },
        .{ .command = "head README.md", .reason = .unsupported_argument },
        .{ .command = "head -n 20 README.md", .reason = .unsupported_argument },
        .{ .command = "head -n -1 README.md", .reason = .unsupported_argument },
        .{ .command = "head -n 10001 README.md", .reason = .unsupported_argument },
        .{ .command = "tail app.log", .reason = .unsupported_argument },
        .{ .command = "tail -f app.log", .reason = .unsupported_argument },
        .{ .command = "grep TODO src", .reason = .unsupported_argument },
        .{ .command = "grep token /tmp/.env", .reason = .unsupported_argument },
        .{ .command = "grep -r TODO src", .reason = .unsupported_argument },
        .{ .command = "grep -e TODO src", .reason = .unsupported_argument },
        .{ .command = "grep -n", .reason = .unsupported_argument },
        .{ .command = "unknown-reader file", .reason = .unknown_command },
        .{ .command = "wc -c < input.txt", .reason = .unsupported_input_redirect },
        .{ .command = "wc -c < input.txt", .reason = .unsupported_input_redirect, .target_os = .linux },
        .{ .command = "printf \"$HOME\"", .reason = .dynamic_shell },
        .{ .command = "printf \"$x\"", .reason = .dynamic_shell },
        .{ .command = "printf \"a\\q\"", .reason = .unsupported_shell },
        .{ .command = "printf $'x'", .reason = .dynamic_shell },
        .{ .command = "printf x # comment", .reason = .unsupported_shell },
        .{ .command = "printf", .reason = .unsupported_argument },
        .{ .command = "printf ''", .reason = .unsupported_argument },
        .{ .command = "printf '' x", .reason = .unsupported_argument },
        .{ .command = "printf --help", .reason = .unsupported_argument },
        .{ .command = "printf --", .reason = .unsupported_argument },
        .{ .command = "printf %q x", .reason = .unsupported_argument },
        .{ .command = "printf %b '\\x41'", .reason = .unsupported_argument },
        .{ .command = "printf %d 1.5", .reason = .unsupported_argument },
        .{ .command = "printf '%100s' x", .reason = .unsupported_argument },
        .{ .command = "printf 'hello\\n' extra", .reason = .unsupported_argument },
        .{ .command = "printf %% extra", .reason = .unsupported_argument },
        .{ .command = "printf '%s'", .reason = .unsupported_argument },
        .{ .command = "printf '%s%s' one", .reason = .unsupported_argument },
        .{ .command = "printf x\\ y", .reason = .unsupported_shell },
        .{ .command = "printf x \\\n y", .reason = .unsupported_shell },
        .{ .command = "wc -c < first.txt < second.txt", .reason = .unsupported_input_redirect, .target_os = .linux },
        .{ .command = "pwd < input.txt", .reason = .unsupported_input_redirect, .target_os = .linux },
        .{ .command = "printf x < input.txt", .reason = .unsupported_input_redirect, .target_os = .linux },
        .{ .command = "ls < input.txt", .reason = .unsupported_input_redirect, .target_os = .linux },
        .{ .command = "printf x\r|wc -c", .reason = .unsupported_shell },
        .{ .command = "ls alpha\rbeta", .reason = .unsupported_shell },
        .{ .command = "printf 'x\ry'", .reason = .unsupported_shell },
        .{ .command = "printf *.txt", .reason = .dynamic_shell },
        .{ .command = "printf ~", .reason = .dynamic_shell },
        .{ .command = "printf 'unterminated", .reason = .unsupported_shell },
        .{ .command = "", .reason = .unknown_command },
    };

    for (cases) |case| {
        try expectApproval(case.command, false, case.target_os, case.reason);
    }
}

test "planner preserves quoted shell metacharacters as literal argv" {
    const cases = [_]struct {
        command: []const u8,
        expected: []const u8,
    }{
        .{ .command = "printf '%s' '<'", .expected = "<" },
        .{ .command = "printf '%s' '>'", .expected = ">" },
        .{ .command = "printf '%s' '|'", .expected = "|" },
        .{ .command = "printf '%s' ';'", .expected = ";" },
        .{ .command = "printf '%s' '&'", .expected = "&" },
    };
    for (cases) |case| {
        var admission = try expectDirect(case.command, .linux);
        defer admission.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(
            case.expected,
            admission.direct_read_only.stages[0].argv[2],
        );
    }

    try expectApproval(
        "wc -c '<' /etc/passwd",
        false,
        .linux,
        .unsupported_argument,
    );
}

test "planner enforces background and platform boundaries" {
    try expectApproval("pwd", true, .macos, .background_process);
    try expectApproval("pwd", false, .windows, .unsupported_platform);
}

test "planner bounds direct pipelines at eight stages" {
    const accepted = "printf x | wc -c | wc -c | wc -c | wc -c | wc -c | wc -c | wc -c";
    var direct = try expectDirect(accepted, .linux);
    direct.deinit(std.testing.allocator);

    const rejected = accepted ++ " | wc -c";
    try expectApproval(rejected, false, .linux, .process_or_system);
}

test "planner canonicalizes target policies and per-stage environments" {
    var admission = try expectDirect("ls -la src | wc -c", .linux);
    defer admission.deinit(std.testing.allocator);
    const direct = admission.direct_read_only;

    try std.testing.expectEqual(@as(usize, 2), direct.stages.len);
    try std.testing.expectEqualStrings("/bin/ls", direct.stages[0].executable);
    try std.testing.expectEqualStrings("-q", direct.stages[0].argv[1]);
    try std.testing.expectEqualStrings("-n", direct.stages[0].argv[2]);
    try std.testing.expectEqualStrings("-a", direct.stages[0].argv[3]);
    try std.testing.expectEqualStrings("--", direct.stages[0].argv[4]);
    try std.testing.expectEqualStrings("src", direct.stages[0].argv[5]);
    try std.testing.expectEqual(EnvironmentProfile.basic_read_only, direct.stages[0].environment_profile);

    try std.testing.expectEqualStrings("/usr/bin/wc", direct.stages[1].executable);
    try std.testing.expectEqualStrings("-c", direct.stages[1].argv[1]);
    try std.testing.expectEqual(EnvironmentProfile.basic_read_only, direct.stages[1].environment_profile);
}

test "planner pins read-only git inspection to hardened argv and environment" {
    var admission = try expectDirect("git diff --name-only -- src", .linux);
    defer admission.deinit(std.testing.allocator);
    const stage = admission.direct_read_only.stages[0];

    try std.testing.expectEqual(EnvironmentProfile.git_read_only, stage.environment_profile);
    try std.testing.expectEqualStrings("/usr/bin/git", stage.executable);
    const expected = [_][]const u8{
        "/usr/bin/git",
        "--no-pager",
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "log.showSignature=false",
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--ignore-submodules=all",
        "--color=never",
        "--name-only",
        "--",
        "src",
    };
    try expectArgv(&expected, stage.argv);
}

test "planner blanks repository filters and falls back to review when safe git refuses" {
    const with_filter: GitSource = .{ .fixed = .{ .ready = .{ .executable = "/usr/bin/git", .filter_names = &.{"evil"} } } };
    var admission = try planWithGit(std.testing.allocator, "git status --short", "/workspace", false, .linux, with_filter);
    defer admission.deinit(std.testing.allocator);
    const argv = admission.direct_read_only.stages[0].argv;
    for ([_][]const u8{ "filter.evil.clean=", "filter.evil.smudge=", "filter.evil.process=" }) |override| {
        for (argv, 0..) |arg, index| {
            if (std.mem.eql(u8, arg, override)) {
                try std.testing.expectEqualStrings("-c", argv[index - 1]);
                break;
            }
        } else return error.TestExpectedFilterOverride;
    }

    const refused: GitSource = .{ .fixed = .{ .refused = .repository_mismatch } };
    for ([_][]const u8{ "git status", "git diff --stat", "git log --oneline -n 5", "git status --short | wc -l" }) |command| {
        try expectApprovalWithGit(command, false, .linux, .unsafe_git, refused);
    }
    // Subcommands that are never auto-run keep their own reason.
    try expectApprovalWithGit("git push origin HEAD", false, .linux, .command_owned_input, refused);
    try expectApprovalWithGit("git status --ignored", false, .linux, .unsupported_argument, test_git);
}

test "planner limits bounded readers to pipeline input" {
    const cases = [_]struct {
        command: []const u8,
        expected: []const []const u8,
    }{
        .{ .command = "cat", .expected = &.{"/bin/cat"} },
        .{ .command = "head -n 25", .expected = &.{ "/usr/bin/head", "-n", "25" } },
        .{ .command = "tail", .expected = &.{ "/usr/bin/tail", "-n", "10" } },
        .{ .command = "grep -Fin needle", .expected = &.{ "/usr/bin/grep", "-F", "-i", "-n", "--", "needle" } },
    };
    for (cases) |case| {
        var admission = try expectDirect(case.command, .macos);
        defer admission.deinit(std.testing.allocator);
        const stage = admission.direct_read_only.stages[0];
        try std.testing.expectEqual(EnvironmentProfile.basic_read_only, stage.environment_profile);
        try expectArgv(case.expected, stage.argv);
    }
}

test "planner target policies use reviewed absolute executables and argv" {
    for ([_]std.Target.Os.Tag{ .macos, .linux }) |target_os| {
        const printf_policy = printfPolicy(target_os);
        try std.testing.expectEqualStrings("/usr/bin/printf", printf_policy.executable);
        try std.testing.expectEqual(
            PrintfFormatLanguage.portable_literal_newline_percent_string,
            printf_policy.format_language,
        );

        const ls_policy = lsPolicy(target_os);
        try std.testing.expectEqualStrings("/bin/ls", ls_policy.executable);
        try std.testing.expectEqualSlices([]const u8, &.{"-q"}, ls_policy.forced_argv);
        try std.testing.expectEqual(LsSymlinkSemantics.platform_default, ls_policy.symlink_semantics);

        const commands = [_][]const u8{
            "printf x",
            "pwd",
            "ls -1aAdFlnp",
            "wc -Lclmw",
        };
        for (commands) |command| {
            var admission = try expectDirect(command, target_os);
            defer admission.deinit(std.testing.allocator);
            const direct = admission.direct_read_only;
            for (direct.stages) |stage| {
                try std.testing.expect(std.Io.Dir.path.isAbsolute(stage.executable));
                try std.testing.expectEqualStrings(stage.executable, stage.argv[0]);
                try std.testing.expectEqual(EnvironmentProfile.basic_read_only, stage.environment_profile);
                for (stage.argv) |arg| {
                    try std.testing.expect(!std.mem.eql(u8, arg, "sh"));
                    try std.testing.expect(!std.mem.eql(u8, arg, "bash"));
                    try std.testing.expect(!std.mem.eql(u8, arg, "cmd"));
                    try std.testing.expect(!std.mem.eql(u8, arg, "just-bash"));
                    try std.testing.expect(!std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, stage.executable, "/bin/pwd"));
                }
            }
        }
    }
}

test "planner accepts every reviewed wc flag and rejects every operand" {
    const accepted = [_][]const u8{
        "wc",
        "wc -L",
        "wc -c",
        "wc -l",
        "wc -m",
        "wc -w",
        "wc -Lclmw",
        "wc -L -c -l -m -w",
    };
    for (accepted) |command| {
        var admission = try expectDirect(command, .linux);
        admission.deinit(std.testing.allocator);
    }

    const operands = [_][]const u8{
        "wc file",
        "wc -c file",
        "wc /dev/null",
        "wc fifo",
        "wc --",
        "wc --bytes",
    };
    for (operands) |command| {
        try expectApproval(command, false, .linux, .unsupported_argument);
    }
}

test "planner implements the total portable printf grammar" {
    const accepted = [_][]const u8{
        "printf x",
        "printf 'hello world'",
        "printf 'hello\\n'",
        "printf '%%%%'",
        "printf '%s' ''",
        "printf '%s' '-leading'",
        "printf '%s' '100%'",
        "printf '%s' '\\x41'",
        "printf '%s' 'caf\u{00e9}'",
        "printf '%s%s' one two",
        "printf 'a\\n%%:%s' value",
        "printf 'a'\"b\"",
    };
    for (accepted) |command| {
        var admission = try expectDirect(command, .macos);
        admission.deinit(std.testing.allocator);
    }

    const rejected = [_][]const u8{
        "printf ''",
        "printf '-x'",
        "printf '%s'",
        "printf x extra",
        "printf '%s' one two",
        "printf '%s%s' one",
        "printf '%b' x",
        "printf '%q' x",
        "printf '%d' 1",
        "printf '%-s' x",
        "printf '%1s' x",
        "printf '%.1s' x",
        "printf '%1$s' x",
        "printf '\\t'",
        "printf '\\c'",
        "printf '\\101'",
        "printf '\\x41'",
        "printf '%'",
        "printf '\\'",
    };
    for (rejected) |command| {
        try expectApproval(command, false, .macos, .unsupported_argument);
    }
}

test "planner generated printf grammar accepts only exact productions and data counts" {
    const alloc = std.testing.allocator;
    const data_classes = [_][]const u8{
        "",
        "-leading",
        "100%",
        "\\x41",
        "printable ASCII",
        "caf\u{00e9}",
    };
    const zero_data_formats = [_][]const u8{
        "x",
        "hello world",
        "hello\\n",
        "%%",
        "literal\\npercent:%%",
    };
    for (zero_data_formats) |format| {
        const command = try buildPrintfCommand(alloc, format, &.{});
        defer alloc.free(command);
        var admission = try expectDirect(command, .macos);
        admission.deinit(alloc);

        const surplus = try buildPrintfCommand(alloc, format, &.{data_classes[0]});
        defer alloc.free(surplus);
        try expectApproval(surplus, false, .macos, .unsupported_argument);
    }

    const one_data_formats = [_][]const u8{
        "%s",
        "prefix:%s",
        "%s:suffix",
        "a\\n%%:%s",
    };
    for (one_data_formats) |format| {
        for (data_classes) |data| {
            const command = try buildPrintfCommand(alloc, format, &.{data});
            defer alloc.free(command);
            var admission = try expectDirect(command, .linux);
            admission.deinit(alloc);
        }

        const missing = try buildPrintfCommand(alloc, format, &.{});
        defer alloc.free(missing);
        try expectApproval(missing, false, .linux, .unsupported_argument);
        const surplus = try buildPrintfCommand(
            alloc,
            format,
            &.{ data_classes[0], data_classes[1] },
        );
        defer alloc.free(surplus);
        try expectApproval(surplus, false, .linux, .unsupported_argument);
    }

    for (data_classes) |first| {
        for (data_classes) |second| {
            const command = try buildPrintfCommand(alloc, "%s:%s", &.{ first, second });
            defer alloc.free(command);
            var admission = try expectDirect(command, .macos);
            admission.deinit(alloc);
        }
    }

    for ([_][]const u8{
        "",
        "-leading",
        "%b",
        "%q",
        "%d",
        "%-s",
        "%1s",
        "%.1s",
        "%1$s",
        "\\t",
        "\\c",
        "\\101",
        "\\x41",
        "%",
        "\\",
    }) |format| {
        const command = try buildPrintfCommand(alloc, format, &.{"x"});
        defer alloc.free(command);
        try expectApproval(command, false, .macos, .unsupported_argument);
    }
}

test "planner preserves accepted printf argv exactly" {
    var admission = try expectDirect("printf '%s%s' '-x' 'caf\u{00e9}'", .macos);
    defer admission.deinit(std.testing.allocator);
    const argv = admission.direct_read_only.stages[0].argv;
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("/usr/bin/printf", argv[0]);
    try std.testing.expectEqualStrings("%s%s", argv[1]);
    try std.testing.expectEqualStrings("-x", argv[2]);
    try std.testing.expectEqualStrings("caf\u{00e9}", argv[3]);
}

test "planner native printf forms match shell-visible execution" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;

    const commands = [_][]const u8{
        "printf x",
        "printf 'hello\\n'",
        "printf '%%'",
        "printf '%s' '--help'",
        "printf '%s%s' one two",
        "printf '%s' 'caf\u{00e9}'",
    };
    for (commands) |command| {
        try expectNativePrintfEquivalent(command, builtin.target.os.tag);
    }
}

test "planner generated native printf matrix matches shell bytes status and stderr" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const data_classes = [_][]const u8{
        "",
        "-leading",
        "100%",
        "\\x41",
        "printable ASCII",
        "caf\u{00e9}",
    };
    for ([_][]const u8{
        "x",
        "hello world",
        "hello\\n",
        "%%",
        "literal\\npercent:%%",
    }) |format| {
        const command = try buildPrintfCommand(alloc, format, &.{});
        defer alloc.free(command);
        try expectNativePrintfEquivalent(command, builtin.target.os.tag);
    }
    for ([_][]const u8{ "%s", "prefix:%s", "%s:suffix", "a\\n%%:%s" }) |format| {
        for (data_classes) |data| {
            const command = try buildPrintfCommand(alloc, format, &.{data});
            defer alloc.free(command);
            try expectNativePrintfEquivalent(command, builtin.target.os.tag);
        }
    }
    for (data_classes) |first| {
        for (data_classes) |second| {
            const command = try buildPrintfCommand(alloc, "%s:%s", &.{ first, second });
            defer alloc.free(command);
            try expectNativePrintfEquivalent(command, builtin.target.os.tag);
        }
    }
}

test "planner native ls policy preserves reviewed target behavior" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "file", .{ .truncate = true });
    try file.writeStreamingAll(std.testing.io, "file");
    file.close(std.testing.io);
    try tmp.dir.createDir(std.testing.io, "real-dir", .default_dir);
    var inside = try tmp.dir.createFile(std.testing.io, "real-dir/inside", .{ .truncate = true });
    try inside.writeStreamingAll(std.testing.io, "inside");
    inside.close(std.testing.io);
    var option_looking = try tmp.dir.createFile(std.testing.io, "-option-looking", .{ .truncate = true });
    option_looking.close(std.testing.io);
    var hostile = try tmp.dir.createFile(std.testing.io, "\x1bhostile", .{ .truncate = true });
    hostile.close(std.testing.io);
    try tmp.dir.symLink(std.testing.io, "file", "file-link", .{ .is_directory = false });
    try tmp.dir.symLink(std.testing.io, "real-dir", "dir-link", .{ .is_directory = true });

    const cwd = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cwd);
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    try environment.put("LC_ALL", "C");
    try environment.put("LANG", "C");

    const Case = struct {
        command: []const u8,
        expected_stdout: ?[]const u8 = null,
        succeeds: bool = true,
    };
    const cases = [_]Case{
        .{ .command = "ls real-dir", .expected_stdout = "inside\n" },
        .{ .command = "ls file-link", .expected_stdout = "file-link\n" },
        .{ .command = "ls dir-link", .expected_stdout = "inside\n" },
        .{ .command = "ls -d dir-link", .expected_stdout = "dir-link\n" },
        .{ .command = "ls -F file-link dir-link", .expected_stdout = "dir-link@\nfile-link@\n" },
        .{ .command = "ls -- -option-looking", .expected_stdout = "-option-looking\n" },
        .{ .command = "ls missing", .succeeds = false },
    };
    for (cases) |case| {
        var admission = try expectDirect(case.command, builtin.target.os.tag);
        defer admission.deinit(alloc);
        const stage = admission.direct_read_only.stages[0];
        const result = try std.process.run(alloc, std.testing.io, .{
            .argv = stage.argv,
            .cwd = .{ .path = cwd },
            .environ_map = &environment,
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);

        const succeeded = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        try std.testing.expectEqual(case.succeeds, succeeded);
        if (case.expected_stdout) |expected| {
            try std.testing.expectEqualStrings(expected, result.stdout);
            try std.testing.expectEqualStrings("", result.stderr);
        } else {
            try std.testing.expect(result.stderr.len > 0);
        }
    }

    var hostile_failure = try expectDirect("ls '\x1bmissing'", builtin.target.os.tag);
    defer hostile_failure.deinit(alloc);
    const hostile_failure_result = try std.process.run(alloc, std.testing.io, .{
        .argv = hostile_failure.direct_read_only.stages[0].argv,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
    });
    defer alloc.free(hostile_failure_result.stdout);
    defer alloc.free(hostile_failure_result.stderr);
    try std.testing.expectEqualStrings("", hostile_failure_result.stdout);
    try std.testing.expect(hostile_failure_result.stderr.len > 0);
    try std.testing.expect(std.mem.findScalar(u8, hostile_failure_result.stderr, 0x1b) == null);

    var bare = try expectDirect("ls", builtin.target.os.tag);
    defer bare.deinit(alloc);
    const bare_result = try std.process.run(alloc, std.testing.io, .{
        .argv = bare.direct_read_only.stages[0].argv,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
    });
    defer alloc.free(bare_result.stdout);
    defer alloc.free(bare_result.stderr);
    try std.testing.expectEqualStrings("", bare_result.stderr);
    try std.testing.expect(std.mem.find(u8, bare_result.stdout, "?hostile\n") != null);
    try std.testing.expect(std.mem.findScalar(u8, bare_result.stdout, 0x1b) == null);
    for ([_][]const u8{ "-option-looking\n", "dir-link\n", "file\n", "file-link\n", "real-dir\n" }) |entry| {
        try std.testing.expect(std.mem.find(u8, bare_result.stdout, entry) != null);
    }

    var numeric = try expectDirect("ls -l file", builtin.target.os.tag);
    defer numeric.deinit(alloc);
    const numeric_stage = numeric.direct_read_only.stages[0];
    const expected_numeric_argv = [_][]const u8{ "/bin/ls", "-q", "-n", "--", "file" };
    try std.testing.expectEqual(expected_numeric_argv.len, numeric_stage.argv.len);
    for (expected_numeric_argv, numeric_stage.argv) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    const numeric_result = try std.process.run(alloc, std.testing.io, .{
        .argv = numeric_stage.argv,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
    });
    defer alloc.free(numeric_result.stdout);
    defer alloc.free(numeric_result.stderr);
    try std.testing.expectEqualStrings("", numeric_result.stderr);
    try std.testing.expect(std.mem.endsWith(u8, numeric_result.stdout, " file\n"));
    var fields = std.mem.tokenizeScalar(u8, numeric_result.stdout, ' ');
    _ = fields.next() orelse return error.TestExpectedEqual;
    _ = fields.next() orelse return error.TestExpectedEqual;
    const owner = fields.next() orelse return error.TestExpectedEqual;
    const group = fields.next() orelse return error.TestExpectedEqual;
    _ = try std.fmt.parseInt(u64, owner, 10);
    _ = try std.fmt.parseInt(u64, group, 10);
}

test "planner bounds ls operands at sixty four" {
    var accepted: std.ArrayList(u8) = .empty;
    defer accepted.deinit(std.testing.allocator);
    try accepted.appendSlice(std.testing.allocator, "ls");
    for (0..64) |index| {
        var buffer: [32]u8 = undefined;
        const operand = try std.mem.print(&buffer, " path-{d}", .{index});
        try accepted.appendSlice(std.testing.allocator, operand);
    }

    var direct = try expectDirect(accepted.items, .linux);
    direct.deinit(std.testing.allocator);

    try accepted.appendSlice(std.testing.allocator, " overflow");
    try expectApproval(accepted.items, false, .linux, .unsupported_argument);
}

const parity_programs = [_][]const u8{
    "printf", "pwd",  "ls",    "wc",  "cat", "head", "tail", "grep",
    "git",    "node", "which", "npm", "bun", "pnpm", "yarn", "zig",
};

/// Builtins that a function can replace in every shell here, including bash
/// in POSIX mode, which is `/bin/sh` on macOS.
const parity_guarded_builtins = [_][]const u8{
    "kill",    "ulimit", "umask", "cd", "command", "builtin", "hash", "alias",
    "unalias", "wait",   "fg",    "bg", "jobs",    "fc",      "read",
};

/// Special builtins that bash and zsh, outside POSIX mode, also let a
/// function replace.
const parity_guarded_special_builtins = [_][]const u8{
    "enable", "disable", "disown", "suspend", "history", "logout",
    "pushd",  "popd",    "source", "exec",    "eval",    "trap",
};

const ParityShell = struct {
    name: []const u8,
    paths: []const []const u8,
    flags: []const []const u8,
    guards_special_builtins: bool,
    /// Runs before anything else in the script. fx turns off zsh's `equals`
    /// option before every command (`zsh_command_prelude` in
    /// `src/core/terminal/shell_resolver.zig`), so zsh here does too.
    prelude: []const u8 = "",
    /// Whether this shell stands in for options a user's startup files can
    /// turn on. fx runs direct read-only commands without a shell, so only
    /// the commands it hands to a shell are compared with this one.
    user_options: bool = false,
};

/// `/bin/sh` is dash on Debian and Ubuntu and bash in POSIX mode on macOS,
/// so dash is listed on its own as well. fx replays a user's zsh glob
/// options, and `extendedglob` makes `^` and `#` glob operators, so zsh also
/// runs with it on.
const parity_shells = [_]ParityShell{
    .{ .name = "sh", .paths = &.{"/bin/sh"}, .flags = &.{"-c"}, .guards_special_builtins = false },
    .{ .name = "dash", .paths = &.{ "/bin/dash", "/usr/bin/dash" }, .flags = &.{"-c"}, .guards_special_builtins = false },
    .{
        .name = "bash",
        .paths = &.{ "/bin/bash", "/usr/bin/bash" },
        .flags = &.{ "--norc", "--noprofile", "-c" },
        .guards_special_builtins = true,
    },
    .{
        .name = "zsh",
        .paths = &.{ "/bin/zsh", "/usr/bin/zsh" },
        .flags = &.{ "-f", "-c" },
        .guards_special_builtins = true,
        .prelude = "\\builtin unsetopt equals\n",
    },
    .{
        .name = "zsh with extendedglob",
        .paths = &.{ "/bin/zsh", "/usr/bin/zsh" },
        .flags = &.{ "-f", "-c" },
        .guards_special_builtins = true,
        .prelude = "\\builtin unsetopt equals\n\\builtin setopt extendedglob\n",
        .user_options = true,
    },
};

const parity_recorder = "#!/bin/sh\nprintf '%s\\0' \"$#\" \"$@\" >> \"$FX_PARITY_LOG\"\n";

const ParityOrder = enum {
    /// `&&` stages run one after another.
    sequence,
    /// Pipeline stages run at the same time, so their records can interleave.
    any_order,
};

const ParityExpectation = struct {
    /// Each stage's words, program first.
    stages: []const []const []const u8,
    order: ParityOrder,
    /// Whether fx hands the command to a shell, rather than running it
    /// itself.
    runs_in_shell: bool,
};

const ParityRun = struct {
    term: std.process.Child.Term,
    /// One record per program call: its name, then its arguments.
    records: []const []const []const u8,
    stderr: []const u8,
    /// Files the command left in its empty working directory.
    created: []const []const u8,
};

const ParityMode = enum { must_run_without_review, if_run_without_review };

/// What fx parsed for each review-free path that accepts `command`. Empty
/// when both send it to review. Allocates from `arena`.
fn parityExpectations(arena: std.mem.Allocator, command: []const u8) ![]const ParityExpectation {
    var expectations: std.ArrayList(ParityExpectation) = .empty;
    if (try knownReversibleAutoCommand(arena, command, false)) {
        // Splits the way `knownReversibleAutoCommand` does.
        const argv = try command_lex.tokenize_argv(arena, std.mem.trim(u8, command, " \t"));
        var stages: std.ArrayList([]const []const u8) = .empty;
        var start: usize = 0;
        for (0..argv.tokens.len + 1) |index| {
            if (index < argv.tokens.len and !isStageSeparator(argv.tokens[index])) continue;
            try stages.append(arena, try parityWords(arena, withoutStderrToStdout(argv.tokens[start..index])));
            start = index + 1;
        }
        try expectations.append(arena, .{ .stages = stages.items, .order = .sequence, .runs_in_shell = true });
    }
    const admission = try planWithGit(arena, command, "/workspace", false, @import("builtin").target.os.tag, test_git);
    if (admission == .direct_read_only) {
        // Splits the way `planWithGit` does: one stage per pipeline segment.
        const segments = try command_lex.pipe_segments(arena, std.mem.trim(u8, command, " \t\n"));
        var stages: std.ArrayList([]const []const u8) = .empty;
        for (segments) |segment| {
            const argv = try command_lex.tokenize_argv(arena, segment.text);
            try stages.append(arena, try parityWords(arena, argv.tokens));
        }
        try expectations.append(arena, .{ .stages = stages.items, .order = .any_order, .runs_in_shell = false });
    }
    return expectations.items;
}

fn parityWords(arena: std.mem.Allocator, tokens: []const command_lex.ArgvToken) ![]const []const u8 {
    const words = try arena.alloc([]const u8, tokens.len);
    for (tokens, words) |token, *word| word.* = token.value;
    return words;
}

fn checkShellParity(command: []const u8, mode: ParityMode) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const expectations = try parityExpectations(arena, command);
    if (expectations.len == 0) {
        if (mode == .if_run_without_review) return;
        // The failure output names the command fx reviews.
        std.testing.expectEqualStrings(
            try arena.print("fx runs without review: {s}", .{command}),
            try arena.print("fx reviews: {s}", .{command}),
        ) catch {};
        return error.TestExpectedReviewFreeCommand;
    }
    for (parity_shells) |shell| {
        const path = try parityShellPath(shell) orelse continue;
        const run = try runParityShell(arena, path, shell, command);
        for (expectations) |expectation| {
            if (shell.user_options and !expectation.runs_in_shell) continue;
            try expectParity(arena, expectation, run, shell.name, command);
        }
    }
}

/// Finds the shell, or returns null to skip it. The Linux unit test job and
/// the nightly Fuzz workflow install every shell and set
/// `FX_SHELL_PARITY_ALL_SHELLS`, so a missing shell there fails instead of
/// quietly narrowing the check. Tests read the process environment from
/// `std.testing.environ`, since fx's own environment is never set up in them.
fn parityShellPath(shell: ParityShell) !?[]const u8 {
    for (shell.paths) |path| {
        std.Io.Dir.accessAbsolute(std.testing.io, path, .{}) catch continue;
        return path;
    }
    if (try std.testing.environ.contains(std.testing.allocator, "FX_SHELL_PARITY_ALL_SHELLS")) {
        // The failure output names the path where the shell was expected.
        std.testing.expectEqualStrings(shell.paths[0], "") catch {};
        return error.TestShellParityShellMissing;
    }
    return null;
}

fn runParityShell(
    arena: std.mem.Allocator,
    shell_path: []const u8,
    shell: ParityShell,
    command: []const u8,
) !ParityRun {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "cwd", "empty", "home" }) |name| try tmp.dir.createDirPath(io, name);
    const root = try @import("../shared/io.zig").dirRealpathAlloc(arena, tmp.dir, ".");
    const recorder = try std.Io.Dir.path.join(arena, &.{ root, "record" });
    {
        var file = try tmp.dir.createFile(io, "record", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, parity_recorder);
        try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o700));
    }

    var script: std.ArrayList(u8) = .empty;
    // Before the functions, since one of them replaces `builtin`.
    try script.appendSlice(arena, shell.prelude);
    try appendParityFunctions(&script, arena, recorder, &parity_programs);
    try appendParityFunctions(&script, arena, recorder, &parity_guarded_builtins);
    if (shell.guards_special_builtins) {
        try appendParityFunctions(&script, arena, recorder, &parity_guarded_special_builtins);
    }
    try script.appendSlice(arena, command);
    try script.append(arena, '\n');

    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("PATH", try std.Io.Dir.path.join(arena, &.{ root, "empty" }));
    try environ.put("HOME", try std.Io.Dir.path.join(arena, &.{ root, "home" }));
    try environ.put("FX_PARITY_LOG", try std.Io.Dir.path.join(arena, &.{ root, "log" }));

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, shell_path);
    try argv.appendSlice(arena, shell.flags);
    try argv.append(arena, script.items);
    const result = try std.process.run(arena, io, .{
        .argv = argv.items,
        .cwd = .{ .path = try std.Io.Dir.path.join(arena, &.{ root, "cwd" }) },
        .environ_map = &environ,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });

    const log = tmp.dir.readFileAlloc(io, "log", arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var created: std.ArrayList([]const u8) = .empty;
    var cwd = try tmp.dir.openDir(io, "cwd", .{ .iterate = true });
    defer cwd.close(io);
    var entries = cwd.iterate();
    while (try entries.next(io)) |entry| try created.append(arena, try arena.dupe(u8, entry.name));

    return .{
        .term = result.term,
        .records = try parseParityLog(arena, log),
        .stderr = result.stderr,
        .created = created.items,
    };
}

fn appendParityFunctions(
    script: *std.ArrayList(u8),
    arena: std.mem.Allocator,
    recorder: []const u8,
    names: []const []const u8,
) !void {
    for (names) |name| {
        try script.appendSlice(arena, name);
        try script.appendSlice(arena, "() { ");
        try appendShellSingleQuoted(script, arena, recorder);
        try script.append(arena, ' ');
        try script.appendSlice(arena, name);
        try script.appendSlice(arena, " \"$@\"; }\n");
    }
}

/// Each record is a count, then that many fields: the program's name and
/// its arguments. Every field ends with a NUL.
fn parseParityLog(arena: std.mem.Allocator, log: []const u8) ![]const []const []const u8 {
    var records: std.ArrayList([]const []const u8) = .empty;
    if (log.len == 0) return records.items;
    if (log[log.len - 1] != 0) return error.TestTruncatedParityLog;
    var fields = std.mem.splitScalar(u8, log[0 .. log.len - 1], 0);
    while (fields.next()) |count_text| {
        const record = try arena.alloc([]const u8, try std.fmt.parseInt(usize, count_text, 10));
        for (record) |*field| field.* = fields.next() orelse return error.TestTruncatedParityLog;
        try records.append(arena, record);
    }
    return records.items;
}

fn expectParity(
    arena: std.mem.Allocator,
    expectation: ParityExpectation,
    run: ParityRun,
    shell_name: []const u8,
    command: []const u8,
) !void {
    var expected = expectation.stages;
    var actual = run.records;
    if (expectation.order == .any_order) {
        expected = try sortedParityRecords(arena, expected);
        actual = try sortedParityRecords(arena, actual);
    }
    const exited_cleanly = switch (run.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (exited_cleanly and run.created.len == 0 and sameParityRecords(expected, actual)) return;

    // The failure output shows what fx parsed against what the shell ran.
    const term = switch (run.term) {
        .exited => |code| try arena.print("exited {d}", .{code}),
        else => try arena.print("{any}", .{run.term}),
    };
    std.testing.expectEqualStrings(
        try parityReport(arena, shell_name, command, expected, "exited 0", "", &.{}),
        try parityReport(arena, shell_name, command, actual, term, run.stderr, run.created),
    ) catch {};
    return error.TestShellParityMismatch;
}

/// One parity run as text: each record on its own line, then how the shell
/// ended and anything it created.
fn parityReport(
    arena: std.mem.Allocator,
    shell_name: []const u8,
    command: []const u8,
    records: []const []const []const u8,
    term: []const u8,
    stderr: []const u8,
    created: []const []const u8,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.print("{s} for: {s}\n", .{ shell_name, command });
    for (records) |record| {
        try writer.writeByte('[');
        for (record, 0..) |field, index| {
            try writer.print("{s}\"{f}\"", .{ if (index == 0) "" else " ", std.zig.fmtString(field) });
        }
        try writer.writeAll("]\n");
    }
    try writer.print("term: {s}\nstderr: {s}\n", .{ term, stderr });
    for (created) |name| try writer.print("created: {s}\n", .{name});
    return out.written();
}

fn sortedParityRecords(
    arena: std.mem.Allocator,
    records: []const []const []const u8,
) ![]const []const []const u8 {
    const sorted = try arena.dupe([]const []const u8, records);
    std.mem.sort([]const []const u8, sorted, {}, parityRecordLessThan);
    return sorted;
}

fn parityRecordLessThan(_: void, lhs: []const []const u8, rhs: []const []const u8) bool {
    for (lhs[0..@min(lhs.len, rhs.len)], rhs[0..@min(lhs.len, rhs.len)]) |left, right| {
        switch (std.mem.order(u8, left, right)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    return lhs.len < rhs.len;
}

fn sameParityRecords(expected: []const []const []const u8, actual: []const []const []const u8) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |expected_record, actual_record| {
        if (expected_record.len != actual_record.len) return false;
        for (expected_record, actual_record) |expected_field, actual_field| {
            if (!std.mem.eql(u8, expected_field, actual_field)) return false;
        }
    }
    return true;
}

/// Every form of command that fx runs without review. Each must still be
/// review-free and must run in every shell exactly as fx parsed it.
const parity_review_free_commands = [_][]const u8{
    "node -v",
    "node --version",
    "npm -v",
    "which node",
    "which node npm bun",
    "git status",
    "git status --short --branch",
    "git remote -v",
    "git worktree list",
    "git worktree list --porcelain",
    "git fetch",
    "git fetch origin main",
    "git fetch --all --tags",
    "git fetch --depth=1 origin main",
    "git fetch -q origin -- main",
    "git fetch https://example.com/repository main",
    "npm install",
    "npm i",
    "npm ci",
    "npm test",
    "npm install --save-dev typescript",
    "npm run build",
    "npm run lint -- --fix",
    "bun -v",
    "bun install",
    "bun test",
    "bun run dev",
    "pnpm install",
    "pnpm test",
    "pnpm run build",
    "yarn install",
    "yarn test",
    "yarn run lint",
    "zig build",
    "zig build test",
    "zig build -Doptimize=ReleaseSafe",
    "node -v && npm -v",
    "git status && npm test",
    "npm test 2>&1",
    "git fetch 2>&1 && git status",
    "npm run 'build:prod'",
    "npm run \"build:prod\"",
    "npm run 'with space'",
    "git   status",
    "npm\ttest",
    "pwd",
    "pwd -P",
    "ls",
    "ls -la",
    "ls -1 src",
    "ls -- -dashed",
    "ls 'with space'",
    "wc -l",
    "cat",
    "head",
    "head -n 5",
    "tail -n 20",
    "git diff",
    "git log -n 5",
    "printf 'hello\\n'",
    "ls | wc -l",
    "printf x | cat",
    "git log -n 5 | head -n 3",
};

/// Near misses that fx may or may not run without review. When it does,
/// they must still run as fx parsed them.
const parity_probe_commands = [_][]const u8{
    "git fetch '&&' git status",
    "git fetch \\&\\& git status --prune",
    "npm test \\&\\& npm run build",
    "npm test &\\&",
    "npm test \\&&",
    "npm run =ls",
    "which =node",
    "git status #note",
    "npm run a#b",
    "git fetch ^x .",
    "git fetch --prun#e",
    "npm install react@^18",
    "npm test x##",
    "ls ^x",
    "git status&&npm test",
    "npm run build 2> &1",
    "npm run x\\ y",
    "npm run \"a\\\"b\"",
    "zig build -Dname=value",
    "npm run !x",
    "git fetch origin +main:main",
    "npm run x,y",
    "npm run %x",
    "npm run ^x",
    "ls =x",
    "ls '#x'",
    "printf '%s' '&&'",
    "npm run 'a''b'",
    "npm run \"\"",
    "npm run ''",
    "git status ''",
    "npm run é",
    "grep -n needle file.txt",
    "grep 'two words' file.txt",
    "git diff --stat",
    "printf '%s\\n' a b",
};

test "shell parity: fx runs every review-free command form as sh, dash, bash, and zsh parse it" {
    const os = @import("builtin").target.os.tag;
    if (os != .macos and os != .linux) return error.SkipZigTest;
    var failures: usize = 0;
    for (parity_review_free_commands) |command| {
        checkShellParity(command, .must_run_without_review) catch |err| switch (err) {
            error.TestExpectedReviewFreeCommand, error.TestShellParityMismatch => failures += 1,
            else => return err,
        };
    }
    for (parity_probe_commands) |command| {
        checkShellParity(command, .if_run_without_review) catch |err| switch (err) {
            error.TestShellParityMismatch => failures += 1,
            else => return err,
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

/// Program words that start a generated stage, weighted toward commands fx
/// runs without review.
const parity_stage_starts = [_][]const u8{
    "node -v",  "which",   "git status",   "git remote -v", "git worktree list", "git fetch",
    "git diff", "git log", "npm install",  "npm test",      "npm run",           "npm ci",
    "bun test", "bun run", "pnpm install", "pnpm run",      "yarn run",          "zig build",
    "pwd",      "ls",      "wc -l",        "cat",           "head -n 3",         "tail",
    "grep",     "printf",
};

/// Pieces of generated words. None contains `/` or a builtin's name, so a
/// stage the shell reads differently cannot reach a real program.
const parity_fragments = [_][]const u8{
    "a",       "build", "src",    "x.txt", "-n",    "-l",   "--",   "--flag",
    "--o=v",   "-Dx=1", "=x",     "x=",    "#",     "#x",   "a#b",  "'q s'",
    "\"d q\"", "''",    "\"\"",   "'",     "\"",    "\\",   "\\ ",  "\\#",
    "&&",      "'&&'",  "\"&&\"", "&",     "|",     "||",   "2>&1", ">",
    "<",       ">>",    "2>",     ";",     "$x",    "${x}", "`x`",  "$(x)",
    "*",       "?",     "[a]",    "~",     "{a,b}", "(x)",  "!",    "!x",
    "%",       "^",     ",",      ":",     "@",     "+",    "\t",   "\u{e9}",
    "\u{a0}",  "\x1b",  "\\&\\&", "\\&",   "^x",    "x#",   "x##",
};

fn writeParityCommand(smith: *std.testing.Smith, out: *std.Io.Writer) std.Io.Writer.Error!void {
    const joiner: []const u8 = if (smith.boolWeighted(1, 1)) " && " else " | ";
    const stage_count = smith.valueRangeAtMost(u8, 1, 4);
    for (0..stage_count) |stage| {
        if (stage > 0) try out.writeAll(joiner);
        try out.writeAll(parity_stage_starts[smith.index(parity_stage_starts.len)]);
        for (0..smith.valueRangeAtMost(u8, 0, 4)) |_| {
            try out.writeByte(if (smith.boolWeighted(7, 1)) ' ' else '\t');
            for (0..smith.valueRangeAtMost(u8, 1, 3)) |_| {
                if (smith.boolWeighted(1, 7)) {
                    try out.writeAll(parity_fragments[smith.index(parity_fragments.len)]);
                    continue;
                }
                var raw: [8]u8 = undefined;
                for (raw[0..smith.slice(&raw)]) |byte| {
                    // No letters, so raw bytes cannot spell a program or
                    // builtin; no `/`, so they cannot name a path to one.
                    const safe = !std.ascii.isAlphabetic(byte) and byte != '/' and byte != 0;
                    try out.writeByte(if (safe) byte else '_');
                }
            }
        }
    }
}

fn fuzzShellParity(_: void, smith: *std.testing.Smith) !void {
    const os = @import("builtin").target.os.tag;
    if (os != .macos and os != .linux) return error.SkipZigTest;
    var buffer: [512]u8 = undefined;
    var command: std.Io.Writer = .fixed(&buffer);
    writeParityCommand(smith, &command) catch |err| switch (err) {
        // A full buffer ends the command early, which is still a command.
        error.WriteFailed => {},
    };
    try checkShellParity(command.buffered(), .if_run_without_review);
}

test "shell parity holds for generated commands" {
    try std.testing.fuzz({}, fuzzShellParity, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").shell_parity.*),
    });
}
