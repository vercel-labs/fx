const std = @import("std");
const command_classification = @import("../shell_command/command_classification.zig");

pub const DestructiveEffect = enum {
    discard_version_control_state,
    remove_files,
};

/// Returns a destructive effect only when it appears at an executed command
/// position. Unknown wrappers and quoted or argument text remain unresolved.
pub fn destructive_effect_for(command: []const u8) ?DestructiveEffect {
    const analysis = command_classification.analysis_command_tail(command);
    return destructive_effect_in_analysis(analysis);
}

/// Returns a short policy note for command text with a high-risk shape.
pub fn command_risk_note_for(command: []const u8) ?[]const u8 {
    const risk = destructive_effect_for(command) orelse return null;
    return risk_note_for(risk);
}

/// Returns a narrow alternative when the command text has an unambiguous safer path.
pub fn command_safer_alternative_for(command: []const u8) ?[]const u8 {
    const analysis = command_classification.analysis_command_tail(command);
    if (destructive_effect_in_analysis(analysis)) |risk| {
        return safer_alternative_for_risk(risk);
    }

    if (has_shell_boundary(command)) return null;
    const base = command_classification.base_command_token(analysis) orelse return null;
    if (std.mem.eql(u8, base, "cat") or std.mem.eql(u8, base, "less") or std.mem.eql(u8, base, "more")) {
        return "safer: use read_file for file inspection";
    }
    if (std.mem.eql(u8, base, "ls")) {
        return "safer: use list_files or glob_files for discovery";
    }
    if (is_pattern_matcher(base)) {
        return "safer: use grep_files for exact local search";
    }
    if (std.mem.eql(u8, base, "find")) {
        return "safer: use glob_files or list_files for discovery";
    }
    return null;
}

fn risk_note_for(risk: DestructiveEffect) []const u8 {
    return switch (risk) {
        .discard_version_control_state => "note: command may discard version-control state",
        .remove_files => "note: command may remove files forcefully",
    };
}

fn safer_alternative_for_risk(risk: DestructiveEffect) []const u8 {
    return switch (risk) {
        .discard_version_control_state => "safer: inspect git status first and revert only the intended files",
        .remove_files => "safer: inspect targets first or use delete_file for explicit files",
    };
}

/// Returns an informational annotation for non-error non-zero exit codes.
pub fn semantic_exit_annotation(command_text: []const u8, exit_code: i64, stderr_text: []const u8) ?[]const u8 {
    if (exit_code == 0) return null;

    const analysis = command_classification.analysis_command_tail(command_text);
    const terminal = command_classification.terminal_exit_segment(analysis) orelse return null;
    const base = command_classification.base_command_token(terminal) orelse return null;

    if (is_pattern_matcher(base)) {
        return if (exit_code == 1) "note: no matches found" else null;
    }
    if (std.mem.eql(u8, base, "find")) {
        if (exit_code != 1 or !looks_like_find_access_issue(stderr_text)) return null;
        return "note: some paths could not be read";
    }
    if (std.mem.eql(u8, base, "diff") or std.mem.eql(u8, base, "cmp")) {
        return if (exit_code == 1) "note: compared files differ" else null;
    }
    if (std.mem.eql(u8, base, "test") or std.mem.eql(u8, base, "[")) {
        return if (exit_code == 1) "note: condition evaluated false" else null;
    }
    return null;
}

fn destructive_effect_in_analysis(command: []const u8) ?DestructiveEffect {
    var effect: ?DestructiveEffect = null;
    var in_single = false;
    var in_double = false;
    var escaped = false;
    var in_comment = false;
    var word_active = false;
    var segment_start: usize = 0;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const ch = command[i];
        if (in_comment) {
            if (ch != '\n') continue;
            in_comment = false;
            word_active = false;
            segment_start = i + 1;
            continue;
        }
        if (escaped) {
            escaped = false;
            if (ch != '\n') word_active = true;
            continue;
        }
        if (ch == '\\' and !in_single) {
            escaped = true;
            continue;
        }
        if (ch == '\'' and !in_double) {
            in_single = !in_single;
            word_active = true;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            word_active = true;
            continue;
        }
        if (!in_single and (ch == '$' or ch == '`')) return null;
        if (in_single or in_double) continue;
        if (ch == '#' and !word_active) {
            if (effect == null) {
                effect = warning_at_command_position(command[segment_start..i]);
            }
            in_comment = true;
            continue;
        }
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            word_active = false;
            continue;
        }
        if (ch == '<' or ch == '>' or ch == '(' or ch == ')' or
            ch == '{' or ch == '}') return null;

        const boundary_start = i;
        const boundary_end = switch (ch) {
            ';', '\n', '&' => blk: {
                if (ch == '&' and i + 1 < command.len and command[i + 1] == '&') {
                    i += 1;
                    break :blk i + 1;
                }
                break :blk i + 1;
            },
            '|' => blk: {
                if (i + 1 < command.len and command[i + 1] == '|') {
                    i += 1;
                    break :blk i + 1;
                }
                break :blk i + 1;
            },
            else => {
                word_active = true;
                continue;
            },
        };
        if (effect == null) {
            effect = warning_at_command_position(command[segment_start..boundary_start]);
        }
        word_active = false;
        segment_start = boundary_end;
    }
    if (in_single or in_double or escaped) return null;
    if (!in_comment and effect == null) {
        effect = warning_at_command_position(command[segment_start..]);
    }
    return effect;
}

fn warning_at_command_position(command: []const u8) ?DestructiveEffect {
    var cursor = command_classification.skip_whitespace(command, 0);
    while (command_classification.next_token(command, cursor)) |token| {
        if (!command_classification.is_env_assignment(token.text)) break;
        cursor = token.end;
    }
    const first = command_classification.next_token(command, cursor) orelse return null;

    if (privileged_command_tail(command, first)) |tail| {
        if (warning_at_command_position(tail)) |risk| return risk;
    }

    const rest = command[first.end..];
    if (git_destructive_effect(first.text, rest)) |risk| return risk;
    if (file_removal_effect(first.text, rest)) |risk| return risk;
    return null;
}

fn privileged_command_tail(command: []const u8, first: command_classification.Token) ?[]const u8 {
    if (std.mem.eql(u8, first.text, "sudo") or std.mem.eql(u8, first.text, "doas")) {
        return sudo_like_command_tail(command, first.end);
    }
    if (std.mem.eql(u8, first.text, "su")) {
        return su_command_tail(command, first.end);
    }
    return null;
}

fn sudo_like_command_tail(command: []const u8, start: usize) ?[]const u8 {
    var cursor = start;
    while (command_classification.next_token(command, cursor)) |token| {
        if (std.mem.eql(u8, token.text, "--")) {
            const next = command_classification.next_token(command, token.end) orelse return null;
            return command[next.start..];
        }
        if (command_classification.is_env_assignment(token.text)) {
            cursor = token.end;
            continue;
        }
        if (std.mem.startsWith(u8, token.text, "-")) {
            if (privilege_option_takes_value(token.text)) {
                const value = command_classification.next_token(command, token.end) orelse return null;
                cursor = value.end;
            } else {
                cursor = token.end;
            }
            continue;
        }
        return command[token.start..];
    }
    return null;
}

fn privilege_option_takes_value(option: []const u8) bool {
    return std.mem.eql(u8, option, "-u") or
        std.mem.eql(u8, option, "-g") or
        std.mem.eql(u8, option, "-h") or
        std.mem.eql(u8, option, "-p") or
        std.mem.eql(u8, option, "-C") or
        std.mem.eql(u8, option, "-T") or
        std.mem.eql(u8, option, "-U") or
        std.mem.eql(u8, option, "--user") or
        std.mem.eql(u8, option, "--group") or
        std.mem.eql(u8, option, "--host") or
        std.mem.eql(u8, option, "--prompt") or
        std.mem.eql(u8, option, "--close-from") or
        std.mem.eql(u8, option, "--command-timeout") or
        std.mem.eql(u8, option, "--other-user");
}

fn su_command_tail(command: []const u8, start: usize) ?[]const u8 {
    var cursor = start;
    while (command_classification.next_token(command, cursor)) |token| {
        if (std.mem.eql(u8, token.text, "-c")) {
            return parse_su_command_argument(command, token.end);
        }
        cursor = token.end;
    }
    return null;
}

fn parse_su_command_argument(command: []const u8, start: usize) ?[]const u8 {
    const cursor = command_classification.skip_whitespace(command, start);
    if (cursor >= command.len) return null;

    const quote = command[cursor];
    if (quote == '\'' or quote == '"') {
        const payload_start = cursor + 1;
        var escaped = false;
        var i = payload_start;
        while (i < command.len) : (i += 1) {
            const ch = command[i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (quote == '"' and ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == quote) return command[payload_start..i];
        }
        return null;
    }

    const token = command_classification.next_token(command, cursor) orelse return null;
    return token.text;
}

fn git_destructive_effect(command_name: []const u8, rest: []const u8) ?DestructiveEffect {
    if (!std.mem.eql(u8, std.fs.path.basename(command_name), "git")) return null;

    const sub = git_subcommand(rest) orelse return null;
    const args = git_effect_args(sub.text, rest[sub.end..]);

    if (!args.supported or args.help_or_version) return null;
    if (std.mem.eql(u8, sub.text, "reset") and args.hard_reset) {
        return .discard_version_control_state;
    }
    if (std.mem.eql(u8, sub.text, "clean") and !args.dry_run) {
        return .remove_files;
    }
    if (std.mem.eql(u8, sub.text, "rm") and
        !args.dry_run and
        args.has_operand)
    {
        return .remove_files;
    }
    return null;
}

const GitEffectArgs = struct {
    supported: bool = true,
    dry_run: bool = false,
    help_or_version: bool = false,
    hard_reset: bool = false,
    has_operand: bool = false,
};

fn git_effect_args(subcommand: []const u8, rest: []const u8) GitEffectArgs {
    var args: GitEffectArgs = .{};
    var options = true;
    var offset: usize = 0;
    while (command_classification.next_token(rest, offset)) |token| {
        offset = token.end;
        if (token_starts_shell_comment(token.text)) break;
        if (options and std.mem.eql(u8, token.text, "--")) {
            options = false;
            continue;
        }
        if (!options) {
            args.has_operand = true;
            continue;
        }
        if (std.mem.eql(u8, subcommand, "clean")) {
            if (clean_exclude_short_index(token.text)) |exclude_index| {
                if (std.mem.findScalar(u8, token.text[1..exclude_index], 'n') != null) {
                    args.dry_run = true;
                }
                if (std.mem.findScalar(u8, token.text[1..exclude_index], 'h') != null) {
                    args.help_or_version = true;
                }
                if (exclude_index + 1 == token.text.len) {
                    const pattern = command_classification.next_token(rest, offset) orelse {
                        args.supported = false;
                        break;
                    };
                    if (token_starts_shell_comment(pattern.text)) {
                        args.supported = false;
                        break;
                    }
                    offset = pattern.end;
                }
                continue;
            }
            if (std.mem.eql(u8, token.text, "--exclude")) {
                const pattern = command_classification.next_token(rest, offset) orelse {
                    args.supported = false;
                    break;
                };
                if (token_starts_shell_comment(pattern.text)) {
                    args.supported = false;
                    break;
                }
                offset = pattern.end;
                continue;
            }
            if (std.mem.startsWith(u8, token.text, "--exclude=")) {
                if (token.text.len == "--exclude=".len) args.supported = false;
                continue;
            }
        }
        if (std.mem.eql(u8, token.text, "--help") or
            std.mem.eql(u8, token.text, "--version") or
            std.mem.eql(u8, token.text, "-h") or
            short_option_contains(token.text, 'h')) args.help_or_version = true;
        if (std.mem.eql(u8, token.text, "--hard")) args.hard_reset = true;
        if (std.mem.eql(u8, token.text, "--dry-run") or
            std.mem.eql(u8, token.text, "-n") or
            short_option_contains(token.text, 'n')) args.dry_run = true;
        if (std.mem.eql(u8, token.text, "--pathspec-from-file") and
            !std.mem.eql(u8, subcommand, "clean"))
        {
            const path = command_classification.next_token(rest, offset) orelse break;
            if (token_starts_shell_comment(path.text)) break;
            args.has_operand = true;
            offset = path.end;
            continue;
        }
        if (!std.mem.eql(u8, subcommand, "clean") and
            std.mem.startsWith(u8, token.text, "--pathspec-from-file=") and
            token.text.len > "--pathspec-from-file=".len)
        {
            args.has_operand = true;
            continue;
        }
        if (!std.mem.startsWith(u8, token.text, "-")) args.has_operand = true;
    }
    return args;
}

fn clean_exclude_short_index(option: []const u8) ?usize {
    if (option.len < 2 or option[0] != '-' or option[1] == '-') return null;
    const relative = std.mem.findScalar(u8, option[1..], 'e') orelse return null;
    return relative + 1;
}

fn short_option_contains(option: []const u8, needle: u8) bool {
    return option.len > 2 and
        option[0] == '-' and
        option[1] != '-' and
        std.mem.findScalar(u8, option[1..], needle) != null;
}

fn git_subcommand(rest: []const u8) ?command_classification.Token {
    var offset: usize = 0;
    while (command_classification.next_token(rest, offset)) |token| {
        if (token_starts_shell_comment(token.text)) return null;
        if (std.mem.eql(u8, token.text, "--")) {
            const subcommand = command_classification.next_token(rest, token.end) orelse return null;
            return if (token_starts_shell_comment(subcommand.text)) null else subcommand;
        }
        if (!std.mem.startsWith(u8, token.text, "-")) return token;
        if (git_global_option_takes_value(token.text)) {
            const value = command_classification.next_token(rest, token.end) orelse return null;
            if (token_starts_shell_comment(value.text)) return null;
            offset = value.end;
            continue;
        }
        if (git_global_option_has_inline_value(token.text) or
            git_global_flag(token.text))
        {
            offset = token.end;
            continue;
        }
        return null;
    }
    return null;
}

fn git_global_option_takes_value(option: []const u8) bool {
    return std.mem.eql(u8, option, "-C") or
        std.mem.eql(u8, option, "-c") or
        std.mem.eql(u8, option, "--git-dir") or
        std.mem.eql(u8, option, "--work-tree") or
        std.mem.eql(u8, option, "--namespace") or
        std.mem.eql(u8, option, "--config-env");
}

fn git_global_option_has_inline_value(option: []const u8) bool {
    if (std.mem.startsWith(u8, option, "-C") and option.len > 2) return true;
    if (std.mem.startsWith(u8, option, "-c") and option.len > 2) return true;
    for ([_][]const u8{
        "--git-dir=",
        "--work-tree=",
        "--namespace=",
        "--config-env=",
    }) |prefix| {
        if (std.mem.startsWith(u8, option, prefix) and option.len > prefix.len) {
            return true;
        }
    }
    return false;
}

fn git_global_flag(option: []const u8) bool {
    return std.mem.eql(u8, option, "--bare") or
        std.mem.eql(u8, option, "--no-replace-objects") or
        std.mem.eql(u8, option, "--literal-pathspecs") or
        std.mem.eql(u8, option, "--glob-pathspecs") or
        std.mem.eql(u8, option, "--noglob-pathspecs") or
        std.mem.eql(u8, option, "--icase-pathspecs") or
        std.mem.eql(u8, option, "--no-optional-locks") or
        std.mem.eql(u8, option, "--no-pager") or
        std.mem.eql(u8, option, "--paginate") or
        std.mem.eql(u8, option, "-p") or
        std.mem.eql(u8, option, "-P");
}

fn file_removal_effect(command_name: []const u8, rest: []const u8) ?DestructiveEffect {
    const executable = std.fs.path.basename(command_name);
    if (!(std.mem.eql(u8, executable, "rm") or
        std.mem.eql(u8, executable, "rmdir") or
        std.mem.eql(u8, executable, "unlink") or
        std.mem.eql(u8, executable, "shred"))) return null;
    return if (removal_has_operand(executable, rest)) .remove_files else null;
}

fn removal_has_operand(executable: []const u8, rest: []const u8) bool {
    var offset: usize = 0;
    while (command_classification.next_token(rest, offset)) |token| {
        offset = token.end;
        if (token_starts_shell_comment(token.text)) return false;
        if (std.mem.eql(u8, token.text, "--help") or
            std.mem.eql(u8, token.text, "--version")) return false;
        if (std.mem.eql(u8, token.text, "--")) {
            const operand = command_classification.next_token(rest, offset) orelse return false;
            return !token_starts_shell_comment(operand.text);
        }
        if (std.mem.eql(u8, executable, "shred") and
            shred_option_takes_value(token.text))
        {
            const value = command_classification.next_token(rest, offset) orelse return false;
            if (token_starts_shell_comment(value.text)) return false;
            offset = value.end;
            continue;
        }
        if (std.mem.eql(u8, token.text, "-") or
            !std.mem.startsWith(u8, token.text, "-")) return true;
    }
    return false;
}

fn shred_option_takes_value(option: []const u8) bool {
    return std.mem.eql(u8, option, "-n") or
        std.mem.eql(u8, option, "-s") or
        std.mem.eql(u8, option, "--iterations") or
        std.mem.eql(u8, option, "--size") or
        std.mem.eql(u8, option, "--random-source");
}

fn token_starts_shell_comment(token: []const u8) bool {
    return token.len > 0 and token[0] == '#';
}

fn is_pattern_matcher(command: []const u8) bool {
    return std.mem.eql(u8, command, "grep") or
        std.mem.eql(u8, command, "egrep") or
        std.mem.eql(u8, command, "fgrep") or
        std.mem.eql(u8, command, "rg") or
        std.mem.eql(u8, command, "ag");
}

fn looks_like_find_access_issue(stderr_text: []const u8) bool {
    return contains_ascii_ignore_case(stderr_text, "permission denied") or
        contains_ascii_ignore_case(stderr_text, "operation not permitted");
}

fn contains_ascii_ignore_case(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (ascii_eql_ignore_case(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn ascii_eql_ignore_case(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn has_shell_boundary(command: []const u8) bool {
    return std.mem.findScalar(u8, command, ';') != null or
        std.mem.findScalar(u8, command, '&') != null or
        std.mem.findScalar(u8, command, '|') != null or
        std.mem.findScalar(u8, command, '<') != null or
        std.mem.findScalar(u8, command, '>') != null or
        std.mem.findScalar(u8, command, '$') != null or
        std.mem.findScalar(u8, command, '`') != null or
        std.mem.findScalar(u8, command, '\n') != null;
}

test "command risk note detects git hard reset" {
    try std.testing.expectEqualStrings("note: command may discard version-control state", command_risk_note_for("git reset --hard").?);
}

test "command safer alternative explains risky commands" {
    try std.testing.expectEqualStrings("safer: inspect git status first and revert only the intended files", command_safer_alternative_for("git reset --hard").?);
    try std.testing.expectEqualStrings("safer: inspect targets first or use delete_file for explicit files", command_safer_alternative_for("rm -rf /tmp/x").?);
}

test "command safer alternative maps shell inspection to dedicated tools" {
    try std.testing.expectEqualStrings("safer: use read_file for file inspection", command_safer_alternative_for("cat src/main.zig").?);
    try std.testing.expectEqualStrings("safer: use list_files or glob_files for discovery", command_safer_alternative_for("ls src").?);
    try std.testing.expectEqualStrings("safer: use grep_files for exact local search", command_safer_alternative_for("rg needle src").?);
    try std.testing.expectEqualStrings("safer: use glob_files or list_files for discovery", command_safer_alternative_for("find src -name '*.zig'").?);
}

test "command safer alternative stays conservative for compound commands" {
    try std.testing.expect(command_safer_alternative_for("cat src/main.zig | wc -l") == null);
    try std.testing.expect(command_safer_alternative_for("git status") == null);
}

test "command risk note stays narrow for ordinary git operations" {
    try std.testing.expect(command_risk_note_for("git status") == null);
    try std.testing.expect(command_risk_note_for("git log --oneline") == null);
    try std.testing.expect(command_risk_note_for("git commit --no-verify -m ok") == null);
}

test "command risk note detects forceful removal" {
    try std.testing.expectEqualStrings("note: command may remove files forcefully", command_risk_note_for("rm -rf /tmp/x").?);
}

test "command risk note detects direct destructive effects only" {
    for ([_][]const u8{
        "rm scratch.txt",
        "rmdir generated",
        "unlink stale-link",
        "shred secret.txt",
        "git clean -fd",
        "git rm tracked.txt",
        "/bin/rm scratch.txt",
        "/usr/bin/git clean -fd",
        "git -C nested clean -fd",
        "git --git-dir=.git rm tracked.txt",
    }) |command| {
        try std.testing.expectEqual(
            DestructiveEffect.remove_files,
            destructive_effect_for(command).?,
        );
        try std.testing.expectEqualStrings(
            "note: command may remove files forcefully",
            command_risk_note_for(command).?,
        );
    }

    try std.testing.expect(command_risk_note_for("git clean --dry-run") == null);
    try std.testing.expect(command_risk_note_for("git clean -nd") == null);
    try std.testing.expect(command_risk_note_for("git clean -nfeignored") == null);
    try std.testing.expect(command_risk_note_for("git -C nested clean --dry-run") == null);
    try std.testing.expect(command_risk_note_for("git rm --dry-run tracked.txt") == null);
    try std.testing.expect(command_risk_note_for("git rm -n -- tracked.txt") == null);
    try std.testing.expect(command_risk_note_for("git rm --help") == null);
    try std.testing.expect(command_risk_note_for("git clean --help") == null);
    try std.testing.expect(command_risk_note_for("git clean -h") == null);
    try std.testing.expect(command_risk_note_for("git clean -hf") == null);
    try std.testing.expect(command_risk_note_for("git clean -fh") == null);
    try std.testing.expect(command_risk_note_for("git rm -h tracked.txt") == null);
    try std.testing.expect(command_risk_note_for("git rm -hf tracked.txt") == null);
    try std.testing.expect(command_risk_note_for("git reset -h --hard") == null);
    try std.testing.expect(command_risk_note_for("git reset -hq --hard") == null);
    try std.testing.expect(command_risk_note_for("git -C clean status") == null);
    try std.testing.expect(command_risk_note_for("git --unknown clean -fd") == null);
    try std.testing.expect(command_risk_note_for("rtk rm -rf generated") == null);
    try std.testing.expectEqual(
        DestructiveEffect.remove_files,
        destructive_effect_for("git rm -- -n").?,
    );
    try std.testing.expectEqual(
        DestructiveEffect.remove_files,
        destructive_effect_for("git clean -f -- -n").?,
    );
    for ([_][]const u8{
        "git clean -f -e --dry-run",
        "git clean -f --exclude --dry-run",
        "git clean -f -e-n",
        "git clean -fe-n",
        "git clean -f --exclude=--dry-run",
        "git clean -f -ehelp",
        "git clean -f -fehelp",
    }) |command| {
        try std.testing.expectEqual(
            DestructiveEffect.remove_files,
            destructive_effect_for(command).?,
        );
    }
    try std.testing.expectEqual(
        DestructiveEffect.discard_version_control_state,
        destructive_effect_for("git reset --hard HEAD~1").?,
    );
}

test "command destructive effect leaves unsupported and targetless removal unresolved" {
    for ([_][]const u8{
        "rm",
        "rm -f",
        "rm --help",
        "rm --version",
        "rm # no target",
        "rm -- # no target",
        "rmdir --verbose",
        "unlink --help",
        "shred -n 3",
        "git rm # no target",
        "git rm -- # no target",
        "git reset # --hard",
        "rm -f; printf ok",
        "git rm --dry-run; printf ok",
        "rm -f < input.txt",
        "rm victim > output.txt",
        "printf ok # harmless; rm victim",
        "cat <<EOF\nrm victim\nEOF",
    }) |command| {
        try std.testing.expect(command_risk_note_for(command) == null);
    }

    try std.testing.expectEqual(
        DestructiveEffect.remove_files,
        destructive_effect_for("rm -- -n").?,
    );
    try std.testing.expectEqual(
        DestructiveEffect.remove_files,
        destructive_effect_for("git clean -f # --dry-run").?,
    );
    try std.testing.expectEqual(
        DestructiveEffect.remove_files,
        destructive_effect_for("printf ok # ignored; rm first\nrm second").?,
    );
    try std.testing.expectEqual(
        DestructiveEffect.remove_files,
        destructive_effect_for("printf foo\\ #bar; rm victim").?,
    );
    try std.testing.expectEqual(
        DestructiveEffect.remove_files,
        destructive_effect_for("printf foo\\;#bar; rm victim").?,
    );
    try std.testing.expectEqual(
        DestructiveEffect.remove_files,
        destructive_effect_for("printf foo\\" ++ "\n#bar; rm victim").?,
    );
    try std.testing.expect(
        destructive_effect_for("printf \\" ++ "\n# comment; rm ignored") == null,
    );
    try std.testing.expectEqual(
        DestructiveEffect.discard_version_control_state,
        destructive_effect_for("git reset --hard; printf ok").?,
    );
    try std.testing.expectEqual(
        DestructiveEffect.remove_files,
        destructive_effect_for("rm victim; printf ok").?,
    );
}

test "command risk note detects privilege-wrapped removal" {
    try std.testing.expectEqualStrings("note: command may remove files forcefully", command_risk_note_for("sudo rm -rf /tmp").?);
    try std.testing.expectEqualStrings("note: command may remove files forcefully", command_risk_note_for("doas rm -rf /tmp").?);
}

test "command risk note detects privilege-wrapped git reset" {
    try std.testing.expectEqualStrings("note: command may discard version-control state", command_risk_note_for("sudo git reset --hard").?);
}

test "command risk note detects quoted su command payload" {
    try std.testing.expectEqualStrings("note: command may remove files forcefully", command_risk_note_for("su -c 'rm -rf /tmp'").?);
    try std.testing.expectEqualStrings("note: command may discard version-control state", command_risk_note_for("su -c \"git reset --hard\"").?);
    try std.testing.expectEqualStrings("note: command may remove files forcefully", command_risk_note_for("su root -c 'rm -rf /tmp'").?);
}

test "command risk note fails closed for malformed su command payload" {
    try std.testing.expect(command_risk_note_for("su -c 'rm -rf /tmp") == null);
    try std.testing.expect(command_risk_note_for("su -c \"git reset --hard") == null);
}

test "command risk note detects process-control wrapped removal" {
    try std.testing.expect(command_risk_note_for("nice rm -rf /tmp") != null);
}

test "command risk note detects timeout wrapped git reset" {
    try std.testing.expect(command_risk_note_for("timeout 5 git reset --hard") != null);
}

test "command risk note detects safe env wrapped git reset" {
    try std.testing.expect(command_risk_note_for("env NODE_ENV=prod git reset --hard") != null);
}

test "command risk note sees removal after unknown env prefix" {
    try std.testing.expectEqualStrings("note: command may remove files forcefully", command_risk_note_for("MY_SECRET=x rm -rf /tmp").?);
}

test "command risk note ignores quoted command text" {
    try std.testing.expect(command_risk_note_for("echo 'rm -rf /tmp'") == null);
}

test "command risk note ignores command text in argument string" {
    try std.testing.expect(command_risk_note_for("git commit -m \"rm -rf /tmp\"") == null);
}

test "command risk note detects command after sequence boundary" {
    try std.testing.expect(command_risk_note_for("echo ok; rm -f scratch") != null);
}

test "semantic annotation explains grep exit one" {
    try std.testing.expectEqualStrings("note: no matches found", semantic_exit_annotation("grep foo bar", 1, "").?);
}

test "semantic annotation leaves grep real errors alone" {
    try std.testing.expect(semantic_exit_annotation("grep foo bar", 2, "") == null);
}

test "semantic annotation leaves zero exits alone" {
    try std.testing.expect(semantic_exit_annotation("grep foo bar", 0, "") == null);
}

test "semantic annotation explains find partial access" {
    try std.testing.expectEqualStrings("note: some paths could not be read", semantic_exit_annotation("find /tmp -name foo", 1, "find: /tmp/private: Permission denied").?);
    try std.testing.expectEqualStrings("note: some paths could not be read", semantic_exit_annotation("find /tmp -name foo", 1, "find: /tmp/private: Operation not permitted").?);
}

test "semantic annotation leaves find usage errors alone" {
    try std.testing.expect(semantic_exit_annotation("find /tmp -bad", 1, "find: -bad: unknown primary or operator") == null);
    try std.testing.expect(semantic_exit_annotation("find /tmp -name", 1, "find: -name: requires additional arguments") == null);
}

test "semantic annotation explains diff differences" {
    try std.testing.expectEqualStrings("note: compared files differ", semantic_exit_annotation("diff a b", 1, "").?);
}

test "semantic annotation explains test false" {
    try std.testing.expectEqualStrings("note: condition evaluated false", semantic_exit_annotation("test -f foo", 1, "").?);
}

test "semantic annotation explains bracket alias false" {
    try std.testing.expectEqualStrings("note: condition evaluated false", semantic_exit_annotation("[ -f foo ]", 1, "").?);
}

test "semantic annotation handles wrapped grep" {
    try std.testing.expectEqualStrings("note: no matches found", semantic_exit_annotation("timeout 5 grep foo bar.txt", 1, "").?);
}

test "semantic annotation uses last pipe segment" {
    try std.testing.expectEqualStrings("note: no matches found", semantic_exit_annotation("diff a b | grep changed", 1, "").?);
}

test "semantic annotation uses last sequence segment" {
    try std.testing.expectEqualStrings("note: no matches found", semantic_exit_annotation("ls -la; grep foo bar.txt", 1, "").?);
}

test "semantic annotation uses last newline segment" {
    try std.testing.expectEqualStrings("note: no matches found", semantic_exit_annotation("ls -la\ngrep foo bar.txt", 1, "").?);
}

test "semantic annotation ignores default last pipe segment" {
    try std.testing.expect(semantic_exit_annotation("grep foo bar | wc -l", 1, "") == null);
}

test "semantic annotation declines short circuit commands" {
    try std.testing.expect(semantic_exit_annotation("grep foo bar && echo done", 1, "") == null);
}

test "semantic annotation declines background commands" {
    try std.testing.expect(semantic_exit_annotation("true & grep foo bar", 1, "") == null);
}

test "semantic annotation ignores quoted pipe" {
    try std.testing.expectEqualStrings("note: no matches found", semantic_exit_annotation("grep 'foo|bar' baz", 1, "").?);
}

test "semantic annotation ignores unknown base command" {
    try std.testing.expect(semantic_exit_annotation("python3 myscript.py", 1, "") == null);
}

test "semantic annotation ignores default nonzero command" {
    try std.testing.expect(semantic_exit_annotation("ls -z", 1, "") == null);
}

test "semantic annotation handles empty and malformed input" {
    try std.testing.expect(semantic_exit_annotation("", 1, "") == null);
    try std.testing.expect(semantic_exit_annotation("grep 'unterminated", 1, "") == null);
}
