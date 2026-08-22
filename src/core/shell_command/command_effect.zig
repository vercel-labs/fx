const std = @import("std");
const command_lex = @import("command_lex.zig");

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
        if (!at_end and !std.mem.eql(u8, argv.tokens[index].value, "&&")) {
            if (isUnsupportedAutoControlOperator(argv.tokens[index])) return false;
            continue;
        }
        if (!reversibleAutoStage(argv.tokens[stage_start..index])) return false;
        stage_start = index + 1;
    }
    return true;
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

fn reversibleAutoStage(raw_tokens: []const command_lex.ArgvToken) bool {
    var tokens = raw_tokens;
    if (tokens.len >= 3 and
        !tokens[tokens.len - 3].quoted and
        !tokens[tokens.len - 2].quoted and
        !tokens[tokens.len - 1].quoted and
        std.mem.eql(u8, tokens[tokens.len - 3].value, "2") and
        std.mem.eql(u8, tokens[tokens.len - 2].value, ">&") and
        std.mem.eql(u8, tokens[tokens.len - 1].value, "1"))
    {
        tokens = tokens[0 .. tokens.len - 3];
    }
    if (tokens.len == 0) return false;
    for (tokens) |token| {
        if (isUnsupportedAutoOperator(token) or tokenHasDynamicShellSyntax(token.raw)) {
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

fn tokenHasDynamicShellSyntax(raw: []const u8) bool {
    for (raw) |byte| switch (byte) {
        '$', '`', '*', '?', '[', '~', '\n', '\r', ';', '(', ')', '{', '}' => return true,
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
    if (std.mem.eql(u8, subcommand, "fetch")) {
        for (words[1..]) |word| {
            if (std.mem.eql(u8, word.value, "--prune") or
                std.mem.eql(u8, word.value, "-p") or
                std.mem.eql(u8, word.value, "--prune-tags")) return false;
        }
        return true;
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

    var planned: std.ArrayList(TemporaryStage) = .empty;
    for (segments) |segment| {
        if (segment.text.len == 0) return .{ .approval_required = .unsupported_shell };

        const argv = command_lex.tokenize_argv(scratch, segment.text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .approval_required = .unsupported_shell },
        };
        const parsed = try parseStage(scratch, argv.tokens, target_os);
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

    const family = try planFamily(alloc, words.items, target_os);
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
    if (std.mem.eql(u8, command, "git")) return planGit(alloc, words);
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
) std.mem.Allocator.Error!StageAdmission {
    if (words.len < 2) return .{ .approval_required = .command_owned_input };
    if (std.mem.eql(u8, words[1], "status")) return planGitStatus(alloc, words[2..]);
    if (std.mem.eql(u8, words[1], "diff")) return planGitDiff(alloc, words[2..]);
    if (std.mem.eql(u8, words[1], "log")) return planGitLog(alloc, words[2..]);
    return .{ .approval_required = .command_owned_input };
}

fn appendGitPrelude(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    try argv.appendSlice(alloc, &.{
        "/usr/bin/git",
        "--no-pager",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
    });
}

fn directGit(argv: []const []const u8) StageAdmission {
    return .{ .direct = .{
        .executable = "/usr/bin/git",
        .argv = argv,
        .environment_profile = .git_read_only,
    } };
}

fn planGitStatus(
    alloc: std.mem.Allocator,
    arguments: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendGitPrelude(alloc, &argv);
    try argv.appendSlice(alloc, &.{ "status", "--ignore-submodules=all" });
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
    return directGit(try argv.toOwnedSlice(alloc));
}

fn planGitDiff(
    alloc: std.mem.Allocator,
    arguments: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendGitPrelude(alloc, &argv);
    try argv.appendSlice(alloc, &.{ "diff", "--no-ext-diff", "--no-textconv", "--color=never" });

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
    return directGit(try argv.toOwnedSlice(alloc));
}

fn planGitLog(
    alloc: std.mem.Allocator,
    arguments: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendGitPrelude(alloc, &argv);
    try argv.appendSlice(alloc, &.{ "log", "--no-ext-diff", "--no-textconv", "--color=never", "--max-count=100" });

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
    return directGit(try argv.toOwnedSlice(alloc));
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

fn expectDirect(command: []const u8, target_os: std.Target.Os.Tag) !Admission {
    const admission = try plan(
        std.testing.allocator,
        command,
        "/workspace",
        false,
        target_os,
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
    var admission = try plan(
        std.testing.allocator,
        command,
        "/workspace",
        background,
        target_os,
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
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--color=never",
        "--name-only",
        "--",
        "src",
    };
    try expectArgv(&expected, stage.argv);
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
                try std.testing.expect(std.fs.path.isAbsolute(stage.executable));
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
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const commands = [_][]const u8{
        "printf x",
        "printf 'hello\\n'",
        "printf '%%'",
        "printf '%s' '--help'",
        "printf '%s%s' one two",
        "printf '%s' 'caf\u{00e9}'",
    };
    for (commands) |command| {
        try expectNativePrintfEquivalent(command, builtin.os.tag);
    }
}

test "planner generated native printf matrix matches shell bytes status and stderr" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

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
        try expectNativePrintfEquivalent(command, builtin.os.tag);
    }
    for ([_][]const u8{ "%s", "prefix:%s", "%s:suffix", "a\\n%%:%s" }) |format| {
        for (data_classes) |data| {
            const command = try buildPrintfCommand(alloc, format, &.{data});
            defer alloc.free(command);
            try expectNativePrintfEquivalent(command, builtin.os.tag);
        }
    }
    for (data_classes) |first| {
        for (data_classes) |second| {
            const command = try buildPrintfCommand(alloc, "%s:%s", &.{ first, second });
            defer alloc.free(command);
            try expectNativePrintfEquivalent(command, builtin.os.tag);
        }
    }
}

test "planner native ls policy preserves reviewed target behavior" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

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
        var admission = try expectDirect(case.command, builtin.os.tag);
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

    var hostile_failure = try expectDirect("ls '\x1bmissing'", builtin.os.tag);
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

    var bare = try expectDirect("ls", builtin.os.tag);
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

    var numeric = try expectDirect("ls -l file", builtin.os.tag);
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
        const operand = try std.fmt.bufPrint(&buffer, " path-{d}", .{index});
        try accepted.appendSlice(std.testing.allocator, operand);
    }

    var direct = try expectDirect(accepted.items, .linux);
    direct.deinit(std.testing.allocator);

    try accepted.appendSlice(std.testing.allocator, " overflow");
    try expectApproval(accepted.items, false, .linux, .unsupported_argument);
}
