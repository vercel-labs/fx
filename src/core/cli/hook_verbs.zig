//! The `fx hook` verbs: how their arguments are read, what each subcommand does, and the text or JSON
//! each prints. `fx hook` in the shell and `/hook` in the TUI both call `run`, so the two print the same
//! thing. Output goes to the writers the caller passes in; nothing here reads a terminal.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const text_utils = @import("../shared/text_utils.zig");
const fuzzy_match = @import("../shared/fuzzy_match.zig");
const cli_flags = @import("cli_flags.zig");
const builtin_commands = @import("../../builtins/commands.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const output_contracts = @import("../output/output_contracts.zig");
const hooks_host = @import("../hooks_host/hooks_host.zig");
const hook_engine = @import("../../hooks/hooks.zig");

const Allocator = std.mem.Allocator;

/// What `run` reads and writes. The writers take the results and the messages; the rest says whose
/// hooks to look at.
pub const Context = struct {
    gpa: Allocator,
    /// Text or JSON results.
    out: *std.Io.Writer,
    /// Usage errors and other messages that are not results.
    err: *std.Io.Writer,
    /// The person's home folder, or null when fx has none.
    home: ?[]const u8,
    workspace_root: []const u8,
    /// Whether `experimental.hooks` is on. `fx hook list` says so; `test` runs hooks either way.
    hooks_enabled: bool,
    /// Whether this process is fx's own agent (`AI_AGENT=fx`), which may not trust or disable a hook.
    /// The CLI reads it from the environment when it starts; the TUI's `/hook` job reads it on the UI thread
    /// when the job is created.
    agent_is_fx: bool,
    /// Stops the hooks of `test` when set, as Esc does in the TUI. The CLI passes null: its signal handler ends the hook groups (R3.9).
    cancel: ?*const std.atomic.Value(bool) = null,
};

const exit_ok: u8 = 0;
const exit_failure: u8 = 1;
const exit_usage: u8 = output_contracts.usage_exit_code;

fn writeStdout(ctx: Context, text: []const u8) !void {
    try ctx.out.writeAll(text);
}

fn writeStderr(ctx: Context, text: []const u8) !void {
    try ctx.err.writeAll(text);
}

/// One line of JSON, with its newline.
fn writeJsonLine(ctx: Context, text: []const u8) !void {
    try writeStdout(ctx, text);
    try writeStdout(ctx, "\n");
}

fn writeFormattedOutput(ctx: Context, text: []const u8, format: output_contracts.OutputFormat) !void {
    switch (format) {
        .text => try writeStdout(ctx, text),
        .json => try writeJsonLine(ctx, text),
    }
}

fn writeJsonCommandFailureCode(alloc: Allocator, ctx: Context, kind: []const u8, code: []const u8, message: []const u8) !void {
    const json = try (output_contracts.CommandFailureSnapshot{
        .kind = kind,
        .message = message,
        .code = code,
    }).renderJson(alloc);
    defer alloc.free(json);
    try writeJsonLine(ctx, json);
}

/// The usage line for `fx hook`.
fn writeUsage(ctx: Context) !void {
    try writeStderr(ctx, "usage: fx ");
    try writeStderr(ctx, command_specs.topLevelUsage(builtin_commands.top_level_registry, .hook));
    try writeStderr(ctx, "\n");
}

/// What is wrong with the flags in `args`, or null when they are fine. The caller frees the result.
fn flagProblem(alloc: Allocator, args: []const [:0]const u8) !?[]u8 {
    const parser: cli_flags.Parser = .init(&builtin_commands.hook_parse_options, args);
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    if (cli_flags.failureOf(parser)) |failure| {
        try failure.write(&writer.writer);
    } else if (!try cli_flags.writeRangeFailure(&writer.writer, parser)) {
        return null;
    }
    return try writer.toOwnedSlice();
}

fn writeFlagProblem(alloc: Allocator, ctx: Context, args: []const [:0]const u8) !void {
    const problem = try flagProblem(alloc, args) orelse return;
    defer alloc.free(problem);
    try writeStderr(ctx, "fx hook: ");
    try writeStderr(ctx, problem);
    try writeStderr(ctx, "\n");
}

/// Whether `args` carries `--json`. Each argument is read alone, as the flag parser reads it, so no
/// flag text is compared by hand.
fn requestsJson(args: []const [:0]const u8) bool {
    for (args) |arg| {
        var parser: cli_flags.Parser = .init(&builtin_commands.hook_parse_options, &.{arg});
        // A flag the parser rejects is reported by the full parse, so this look only skips the argument.
        const item = (parser.next() catch null) orelse continue;
        switch (item) {
            .option => |found| if (hook_flag_ids[found.index].? == .json) return true,
            .positional => {},
        }
    }
    return false;
}

/// What `fx hook trust` names: one hook by id, or every hook that waits for trust.
const HookTrust = union(enum) { id: []const u8, all };

/// What `fx hook test` runs: one event, and optionally a match value and a JSON object of fields.
const HookTest = struct {
    /// Null when the word is not an event name; the run reports it.
    event: ?hook_engine.EventName,
    event_word: []const u8,
    match: ?[]const u8 = null,
    input: ?[]const u8 = null,
};

/// What `fx hook log` shows: how many recent runs.
const HookLog = struct { limit: usize };

/// The seven verbs of `fx hook`, in the order the usage names them. The `/hook` job and the typo suggestion read it.
pub const verb_words = [_][]const u8{ "list", "show", "trust", "enable", "disable", "test", "log" };

/// The words after `fx hook`: `list` (or `ls`), `show ID`, `trust`, `enable`, `disable`, `test`, or `log`,
/// each with `--json` when asked.
const HookOptions = struct {
    command: union(enum) {
        list,
        show: []const u8,
        trust: HookTrust,
        enable: []const u8,
        disable: []const u8,
        @"test": HookTest,
        log: HookLog,
    },
    json: bool = false,
};

const HookFlag = enum { json, all, match, input, limit };
const hook_flag_ids = cli_flags.idTable(HookFlag, &builtin_commands.hook_parse_options);

/// Reads the words after `fx hook`. `ls` names the list action, as `fx sessions ls` does.
pub fn parseHookArgs(args: []const [:0]const u8) error{ InvalidHookFlag, HookNeedsCommand, UnknownHookCommand, HookNeedsId, HookTrustNeedsTarget, HookTrustIdAndAll, HookTestNeedsEvent, InvalidHookLimit, TooManyHookArgs }!HookOptions {
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var json = false;
    var all = false;
    var match_value: ?[]const u8 = null;
    var input_value: ?[]const u8 = null;
    var limit_value: ?[]const u8 = null;
    var parser: cli_flags.Parser = .init(&builtin_commands.hook_parse_options, args);
    while (parser.next() catch return error.InvalidHookFlag) |item| switch (item) {
        .option => |found| switch (hook_flag_ids[found.index].?) {
            .json => json = true,
            .all => all = true,
            .match => match_value = found.value,
            .input => input_value = found.value,
            .limit => limit_value = found.value,
        },
        .positional => |arg| {
            if (positional_len >= positional.len) return error.TooManyHookArgs;
            positional[positional_len] = arg;
            positional_len += 1;
        },
    };
    if (positional_len == 0) return error.HookNeedsCommand;
    const word = positional[0];
    const is_test = std.mem.eql(u8, word, "test");
    const is_log = std.mem.eql(u8, word, "log");
    // Only `test` takes --match and --input, and only `log` takes --limit.
    if ((match_value != null or input_value != null) and !is_test) return error.InvalidHookFlag;
    if (limit_value != null and !is_log) return error.InvalidHookFlag;
    if (is_log) {
        if (all) return error.InvalidHookFlag;
        if (positional_len != 1) return error.TooManyHookArgs;
        return .{ .command = .{ .log = .{ .limit = try parseHookLimit(limit_value) } }, .json = json };
    }
    if (is_test) {
        if (all) return error.InvalidHookFlag;
        if (positional_len == 1) return error.HookTestNeedsEvent;
        if (positional_len != 2) return error.TooManyHookArgs;
        return .{ .command = .{ .@"test" = .{
            .event = hookEventNamed(positional[1]),
            .event_word = positional[1],
            .match = match_value,
            .input = input_value,
        } }, .json = json };
    }
    if (std.mem.eql(u8, word, "trust")) {
        if (all and positional_len == 2) return error.HookTrustIdAndAll;
        if (all) return .{ .command = .{ .trust = .all }, .json = json };
        if (positional_len == 1) return error.HookTrustNeedsTarget;
        return .{ .command = .{ .trust = .{ .id = positional[1] } }, .json = json };
    }
    // Only `trust` takes --all; every other subcommand refuses it as an unknown flag.
    if (all) return error.InvalidHookFlag;
    if (std.mem.eql(u8, word, "list") or std.mem.eql(u8, word, "ls")) {
        if (positional_len != 1) return error.TooManyHookArgs;
        return .{ .command = .list, .json = json };
    }
    if (std.mem.eql(u8, word, "show")) {
        if (positional_len == 1) return error.HookNeedsId;
        if (positional_len != 2) return error.TooManyHookArgs;
        return .{ .command = .{ .show = positional[1] }, .json = json };
    }
    if (std.mem.eql(u8, word, "enable")) {
        if (positional_len == 1) return error.HookNeedsId;
        if (positional_len != 2) return error.TooManyHookArgs;
        return .{ .command = .{ .enable = positional[1] }, .json = json };
    }
    if (std.mem.eql(u8, word, "disable")) {
        if (positional_len == 1) return error.HookNeedsId;
        if (positional_len != 2) return error.TooManyHookArgs;
        return .{ .command = .{ .disable = positional[1] }, .json = json };
    }
    return error.UnknownHookCommand;
}

/// The first word after `fx hook` that is not a flag.
fn firstHookWord(args: []const [:0]const u8) ?[]const u8 {
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) return arg;
    }
    return null;
}

/// The closest hook word to `word`, for a typo; null when none is close.
pub fn hookWordSuggestion(word: []const u8) ?[]const u8 {
    if (word.len == 0) return null;
    for (verb_words) |candidate| {
        if (fuzzy_match.match(word, &.{.{ .text = candidate }}) != null) return candidate;
    }
    return null;
}

/// The JSON `kind` a failed `fx hook` call reports: the subcommand's kind when the words name one.
fn hookOutputKind(args: []const [:0]const u8) []const u8 {
    const word = firstHookWord(args) orelse return "hook";
    if (std.mem.eql(u8, word, "list") or std.mem.eql(u8, word, "ls")) return "hook_list";
    if (std.mem.eql(u8, word, "show")) return "hook_show";
    if (std.mem.eql(u8, word, "trust")) return "hook_trust";
    if (std.mem.eql(u8, word, "test")) return "hook_test";
    if (std.mem.eql(u8, word, "log")) return "hook_log";
    if (std.mem.eql(u8, word, "enable") or std.mem.eql(u8, word, "disable")) return "hook_state";
    return "hook";
}

/// The text of a `fx hook` usage error. The caller adds the `fx hook: ` prefix in text.
fn hookUsageMessage(alloc: Allocator, args: []const [:0]const u8, err: anyerror) ![]u8 {
    return switch (err) {
        error.HookNeedsCommand => alloc.dupe(u8, "needs a command: list, show, trust, enable, disable, test, or log"),
        error.UnknownHookCommand => blk: {
            const word = firstHookWord(args) orelse "";
            if (hookWordSuggestion(word)) |suggestion| {
                break :blk alloc.print("unknown command {f} (did you mean {s}?)", .{ text_utils.terminalSafe(word), suggestion });
            }
            break :blk alloc.print("unknown command {f}", .{text_utils.terminalSafe(word)});
        },
        error.HookNeedsId => alloc.print("{s} needs the hook ID", .{firstHookWord(args) orelse "show"}),
        error.HookTrustNeedsTarget => alloc.dupe(u8, "trust needs a hook ID or --all"),
        error.HookTrustIdAndAll => alloc.dupe(u8, "trust takes a hook ID or --all, not both"),
        error.HookTestNeedsEvent => alloc.dupe(u8, "test needs an event name, such as PreToolUse"),
        error.InvalidHookLimit => alloc.dupe(u8, "--limit must be a positive whole number"),
        error.TooManyHookArgs => alloc.dupe(u8, "got too many arguments"),
        else => alloc.dupe(u8, "unknown flag"),
    };
}

/// The command line a hook runs: the shell text, or the argv items joined by spaces.
fn hookCommandText(arena: Allocator, command: anytype) ![]const u8 {
    return switch (command) {
        .shell => |text| text,
        .argv => |items| blk: {
            var out: std.ArrayList(u8) = .empty;
            for (items, 0..) |item, index| {
                if (index > 0) try out.append(arena, ' ');
                try out.appendSlice(arena, item);
            }
            break :blk out.items;
        },
    };
}

/// The status `fx hook list` shows for hook `index`. `fx status` and `fx doctor` count with it too.
fn hookStatus(loaded: *const hooks_host.loader.Snapshot, index: usize) output_contracts.HookStatus {
    if (loaded.disabled[index]) return .disabled;
    if (loaded.trusted[index]) return .trusted;
    return .waiting;
}

/// One loaded hook as the CLI reports it. Strings point into `loaded` or into `arena`.
fn hookRow(arena: Allocator, loaded: *const hooks_host.loader.Snapshot, index: usize) !output_contracts.HookRow {
    const hook = loaded.hooks[index];
    return .{
        .id = hook.id,
        .event = hook.event.fileName(),
        .matcher = if (hook.matcher_text.len == 0) null else @as([]const u8, hook.matcher_text),
        .command = try hookCommandText(arena, hook.command),
        .layer = @tagName(hook.layer),
        .file = loaded.sources[index],
        .status = hookStatus(loaded, index),
    };
}

/// What `fx status` and `fx doctor` say about this workspace's hooks: the same load `fx hook list`
/// makes, counted by the same status. The problem strings are allocated with `arena`.
pub fn loadSummary(
    arena: Allocator,
    enabled: bool,
    home: []const u8,
    workspace_root: []const u8,
) !output_contracts.HooksSummary {
    var loaded = try hooks_host.loader.load(arena, .{ .home = home, .workspace_root = workspace_root });
    defer loaded.deinit(arena);
    var summary: output_contracts.HooksSummary = .{
        .enabled = enabled,
        .count = loaded.hooks.len,
        .trusted = 0,
        .waiting = 0,
        .disabled = 0,
        .trust_refused = loaded.trust_refused,
        .problems = &.{},
    };
    for (0..loaded.hooks.len) |index| switch (hookStatus(&loaded, index)) {
        .trusted => summary.trusted += 1,
        .waiting => summary.waiting += 1,
        .disabled => summary.disabled += 1,
    };
    const problems = try arena.alloc(output_contracts.HookProblem, loaded.problems.len);
    for (problems, loaded.problems) |*problem, source| {
        problem.* = .{
            .file = try arena.dupe(u8, source.path),
            .where = try arena.dupe(u8, source.where),
            .message = try arena.dupe(u8, source.message),
        };
    }
    summary.problems = problems;
    return summary;
}

/// The hooks line of `fx status`. A read failure is traced and shown as unavailable: status never
/// fails because of a hook file.
pub fn statusHooks(arena: Allocator, enabled: bool, home: ?[]const u8, workspace_root: []const u8) output_contracts.HooksStatus {
    const home_path = home orelse {
        debug_trace.logf("hooks", "status did not read the hooks: no home folder", .{});
        return .unavailable;
    };
    const summary = loadSummary(arena, enabled, home_path, workspace_root) catch |err| {
        debug_trace.logf("hooks", "status did not read the hooks: {s}", .{@errorName(err)});
        return .unavailable;
    };
    return .{ .summary = summary };
}

fn hookIndex(loaded: *const hooks_host.loader.Snapshot, id: []const u8) ?usize {
    for (loaded.hooks, 0..) |hook, index| {
        if (std.mem.eql(u8, hook.id, id)) return index;
    }
    return null;
}

fn hookListSnapshot(
    arena: Allocator,
    enabled: bool,
    workspace_root: []const u8,
    home: []const u8,
    loaded: *const hooks_host.loader.Snapshot,
) !output_contracts.HookListSnapshot {
    const rows = try arena.alloc(output_contracts.HookRow, loaded.hooks.len);
    for (rows, 0..) |*row, index| row.* = try hookRow(arena, loaded, index);
    const problems = try arena.alloc(output_contracts.HookProblem, loaded.problems.len);
    for (problems, loaded.problems) |*problem, source| {
        problem.* = .{ .file = source.path, .where = source.where, .message = source.message };
    }
    const checked = try arena.alloc([]const u8, 2);
    checked[0] = try profile_paths.rootPath(arena, home, &.{"hooks.json"});
    checked[1] = try std.Io.Dir.path.join(arena, &.{ workspace_root, ".fx/hooks.json" });
    return .{
        .enabled = enabled,
        .workspace = workspace_root,
        .trust_refused = loaded.trust_refused,
        .hooks = rows,
        .problems = problems,
        .checked_files = checked,
    };
}

fn hookShowSnapshot(
    arena: Allocator,
    loaded: *const hooks_host.loader.Snapshot,
    index: usize,
    workspace_root: []const u8,
    home: []const u8,
) !output_contracts.HookShowSnapshot {
    const hook = loaded.hooks[index];
    const named = try hooks_host.trust.namedFiles(arena, hook.command, workspace_root, home);
    const files = try arena.alloc([]const u8, named.files.len);
    for (files, named.files) |*file, source| file.* = source;
    return .{
        .hook = try hookRow(arena, loaded, index),
        .timeout_ms = hook.timeout_ms,
        .on_failure = @tagName(hook.on_failure),
        .named_files = files,
        .named_files_dropped = named.dropped,
    };
}

fn writeRendered(alloc: Allocator, ctx: Context, snapshot: anytype, format: output_contracts.OutputFormat) !u8 {
    const text = try snapshot.render(alloc, format);
    defer alloc.free(text);
    try writeFormattedOutput(ctx, text, format);
    return exit_ok;
}

/// The names of the events a hook file can use, in the order the engine declares them, joined for a message.
fn hookEventList(alloc: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (hook_engine.event.user_events, 0..) |event, index| {
        if (index > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, event.fileName());
    }
    return out.toOwnedSlice(alloc);
}

/// The user event whose file name is `name`, such as `PreToolUse`, or null when none is.
/// Engine-only events such as TurnEnd are never returned, so `fx hook test` cannot run them.
fn hookEventNamed(name: []const u8) ?hook_engine.EventName {
    for (hook_engine.event.user_events) |event| {
        if (std.mem.eql(u8, event.fileName(), name)) return event;
    }
    return null;
}

/// Reads `--input`: a JSON object whose keys become the event's fields. Each value keeps its raw JSON text.
fn parseHookInput(arena: Allocator, text: []const u8) ![]hook_engine.Field {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidHookInput,
    };
    if (parsed != .object) return error.InvalidHookInput;
    const fields = try arena.alloc(hook_engine.Field, parsed.object.count());
    var index: usize = 0;
    var entries = parsed.object.iterator();
    while (entries.next()) |entry| : (index += 1) {
        var out: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(entry.value_ptr.*, .{}, &out.writer);
        fields[index] = .{ .key = entry.key_ptr.*, .value = .{ .json = try out.toOwnedSlice() } };
    }
    return fields;
}

/// `fx hook test EVENT`: runs every hook that matches on a sample event, waiting ones included, and shows the merged answer.
/// Disabled hooks do not run. It runs even when experimental.hooks is off, so a person can try a hook before turning hooks on.
fn runHookTest(
    alloc: Allocator,
    ctx: Context,
    arena: Allocator,
    json: bool,
    test_opts: HookTest,
    home: []const u8,
    workspace_root: []const u8,
    trust_refused: bool,
    format: output_contracts.OutputFormat,
) !u8 {
    const name = test_opts.event orelse {
        const events = try hookEventList(arena);
        const message = try arena.print("fx hook test: unknown event \"{f}\". The events are: {s}", .{ text_utils.terminalSafe(test_opts.event_word), events });
        _ = try writeHookFailure(alloc, ctx, json, "hook_test", "UnknownHookEvent", message);
        return exit_usage;
    };
    const fields = parseHookInput(arena, test_opts.input orelse "{}") catch |err| switch (err) {
        error.InvalidHookInput => {
            _ = try writeHookFailure(alloc, ctx, json, "hook_test", "InvalidHookInput", "fx hook test: --input must be a JSON object");
            return exit_usage;
        },
        else => return err,
    };

    var runtime = try hooks_host.Runtime.init(alloc, .{ .enabled = true, .home = home, .workspace_root = workspace_root });
    defer runtime.deinit();
    runtime.refresh();
    const event: hook_engine.Event = .{
        .name = name,
        .scope = .{ .surface = .ask, .cwd = workspace_root, .project_dir = workspace_root, .permission_mode = "" },
        .match_value = test_opts.match,
        .fields = fields,
    };
    // fx's own agent runs only trusted hooks. A person's run also runs the hooks that wait for trust.
    const trust_required = ctx.agent_is_fx;
    const skipped_waiting = if (trust_required) try runtime.countWaiting(name, test_opts.match) else 0;
    var outcome = (try runtime.dispatch(alloc, event, trust_required, ctx.cancel)) orelse hook_engine.Outcome{};
    defer outcome.deinit(alloc);

    const notices = try arena.alloc(output_contracts.HookNoticeRow, outcome.notices.len);
    for (notices, outcome.notices) |*row, notice| {
        row.* = .{ .kind = @tagName(notice.kind), .hook_id = notice.hook_id, .text = notice.text };
    }
    const snapshot: output_contracts.HookTestSnapshot = .{
        .event = name.fileName(),
        .match = test_opts.match,
        .ran = outcome.ran,
        .trust_refused = trust_refused,
        .skipped_waiting = skipped_waiting,
        .decision = @tagName(outcome.decision),
        .reason = outcome.reason,
        .decided_by = outcome.decided_by,
        .updated_input = outcome.updated_input,
        .updated_input_is_json = name == .pre_tool_use,
        .additional_context = outcome.additional_context,
        .continue_reason = outcome.continue_reason,
        .stop_reason = outcome.stop_reason,
        .updated_output = outcome.updated_output,
        .retry = outcome.retry,
        .notices = notices,
    };
    return writeRendered(alloc, ctx, snapshot, format);
}

/// How many recent runs `fx hook log` shows when `--limit` is not given.
const hook_log_default_limit: usize = 20;

/// The `--limit` value: a whole number of at least 1, or the default.
fn parseHookLimit(text: ?[]const u8) error{InvalidHookLimit}!usize {
    const value = text orelse return hook_log_default_limit;
    const limit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidHookLimit;
    if (limit == 0) return error.InvalidHookLimit;
    return limit;
}

/// The largest run-log file `fx hook log` reads. The log keeps each file near 1 MiB, so this leaves room.
const hook_log_max_bytes: usize = 16 * 1024 * 1024;

/// Appends the lines of one run-log file, in order. A missing file adds none; empty lines are skipped.
fn readRunLogLines(arena: Allocator, path: []const u8, lines: *std.ArrayList([]const u8)) !void {
    const io = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(io);
    const text = try io_mod.readFileToEnd(arena, &file, hook_log_max_bytes);
    var rows = std.mem.splitScalar(u8, text, '\n');
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        try lines.append(arena, row);
    }
}

/// Writes the failure for a run log that exists but cannot be read.
fn runLogReadFailure(alloc: Allocator, ctx: Context, json: bool, arena: Allocator, err: anyerror) !u8 {
    const message = try arena.print("could not read the run log: {s}", .{@errorName(err)});
    return writeHookFailure(alloc, ctx, json, "hook_log", @errorName(err), message);
}

/// `fx hook log`: the most recent hook runs, oldest first. Reads the run log and the older file it moved aside.
fn runHookLog(
    alloc: Allocator,
    ctx: Context,
    arena: Allocator,
    json: bool,
    limit: usize,
    home: []const u8,
    format: output_contracts.OutputFormat,
) !u8 {
    const current_path = try hooks_host.logPath(arena, home);
    const older_path = try hooks_host.oldLogPath(arena, home);
    var lines: std.ArrayList([]const u8) = .empty;
    readRunLogLines(arena, older_path, &lines) catch |err| {
        if (err == error.OutOfMemory) return err;
        return runLogReadFailure(alloc, ctx, json, arena, err);
    };
    readRunLogLines(arena, current_path, &lines) catch |err| {
        if (err == error.OutOfMemory) return err;
        return runLogReadFailure(alloc, ctx, json, arena, err);
    };
    // The older file's lines come first, so the last `limit` lines are the newest.
    const start = if (lines.items.len > limit) lines.items.len - limit else 0;
    var entries: std.ArrayList(output_contracts.HookLogEntry) = .empty;
    var skipped: usize = 0;
    for (lines.items[start..]) |line| {
        if (try parseHookLogLine(arena, line)) |entry| {
            try entries.append(arena, entry);
        } else {
            skipped += 1;
        }
    }
    const snapshot: output_contracts.HookLogSnapshot = .{
        .file = current_path,
        .entries = entries.items,
        .skipped_lines = skipped,
    };
    return writeRendered(alloc, ctx, snapshot, format);
}

/// Reads one run-log line. Null when the line is not a JSON object with every field the log writes.
pub fn parseHookLogLine(arena: Allocator, line: []const u8) !?output_contracts.HookLogEntry {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .object) return null;
    // A line with a missing or wrongly typed field is not a run. The reader counts it as unreadable.
    return readHookLogEntry(parsed.object) catch null;
}

const LogFieldError = error{MalformedLogField};

fn readHookLogEntry(object: std.json.ObjectMap) LogFieldError!output_contracts.HookLogEntry {
    return .{
        .time_ms = try logInteger(object, "time_ms"),
        .event = try logText(object, "event"),
        .match = try logOptionalText(object, "match"),
        .surface = try logText(object, "surface"),
        .session_id = try logOptionalText(object, "session_id"),
        .ran = try logCount(object, "ran"),
        .decision = try logText(object, "decision"),
        .decided_by = try logOptionalText(object, "decided_by"),
        .reason = try logOptionalText(object, "reason"),
        .notices = try logCount(object, "notices"),
    };
}

fn logValue(object: std.json.ObjectMap, key: []const u8) LogFieldError!std.json.Value {
    return object.get(key) orelse error.MalformedLogField;
}

fn logText(object: std.json.ObjectMap, key: []const u8) LogFieldError![]const u8 {
    const value = try logValue(object, key);
    if (value != .string) return error.MalformedLogField;
    return value.string;
}

fn logOptionalText(object: std.json.ObjectMap, key: []const u8) LogFieldError!?[]const u8 {
    const value = try logValue(object, key);
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.MalformedLogField,
    };
}

fn logInteger(object: std.json.ObjectMap, key: []const u8) LogFieldError!i64 {
    const value = try logValue(object, key);
    if (value != .integer) return error.MalformedLogField;
    return value.integer;
}

fn logCount(object: std.json.ObjectMap, key: []const u8) LogFieldError!usize {
    const number = try logInteger(object, key);
    return std.math.cast(usize, number) orelse error.MalformedLogField;
}

/// Whether a `fx hook` subcommand writes the trust file.
fn writesTrustFile(command: anytype) bool {
    return switch (command) {
        .list, .show, .@"test", .log => false,
        .trust, .enable, .disable => true,
    };
}

/// The subcommand word fx's own agent may not run, or null when the agent may run it.
fn agentRefusedWord(command: anytype) ?[]const u8 {
    return switch (command) {
        .trust => "trust",
        .disable => "disable",
        else => null,
    };
}

/// Writes a `fx hook` failure: a JSON failure with `kind`, `error`, and `code`, or the message on stderr.
fn writeHookFailure(alloc: Allocator, ctx: Context, json: bool, kind: []const u8, code: []const u8, message: []const u8) !u8 {
    if (json) {
        try writeJsonCommandFailureCode(alloc, ctx, kind, code, message);
    } else {
        try writeStderr(ctx, message);
        try writeStderr(ctx, "\n");
    }
    return exit_failure;
}

/// Writes the unknown-hook failure. The text names the id; the JSON code is `UnknownHook`.
fn writeUnknownHook(alloc: Allocator, ctx: Context, json: bool, kind: []const u8, id: []const u8) !u8 {
    const message = try alloc.print("No hook with id \"{f}\" for this workspace.", .{text_utils.terminalSafe(id)});
    defer alloc.free(message);
    return writeHookFailure(alloc, ctx, json, kind, "UnknownHook", message);
}

/// The refusal text for a trust change: the trust file's own problem, worded as `fx hook list` shows it.
fn trustRefusedMessage(alloc: Allocator, loaded: *const hooks_host.loader.Snapshot, trust_file: []const u8) ![]u8 {
    for (loaded.problems) |problem| {
        if (std.mem.eql(u8, problem.path, trust_file)) return alloc.print("The trust file was refused: {f}", .{text_utils.terminalSafe(problem.message)});
    }
    return alloc.dupe(u8, "The trust file was refused.");
}

/// Adds one hook's digest to the trust store. The label names the hook in the trust file.
fn addTrustedHook(alloc: Allocator, arena: Allocator, store: *hooks_host.trust.Store, loaded: *const hooks_host.loader.Snapshot, index: usize) !void {
    const hook = loaded.hooks[index];
    const label = try arena.print("{s} hook {s}", .{ hook.event.fileName(), hook.id });
    try store.add(alloc, loaded.digests[index], label);
}

/// How long a trust command waits for another fx process to release the trust file. Past it,
/// the command says the file is busy and changes nothing.
const trust_lock_wait_ms = 3000;

/// The outcome of taking the trust file's write lock for a command.
const TrustLock = union(enum) {
    locked: hooks_host.trust.WriteLock,
    failed: u8,
};

/// Takes the trust file's write lock. When it cannot, writes the failure for `command` and
/// returns its exit code.
fn lockTrustFile(
    alloc: Allocator,
    ctx: Context,
    arena: Allocator,
    json: bool,
    command: []const u8,
    trust_file: []const u8,
) !TrustLock {
    const lock = hooks_host.trust.lockWriters(alloc, trust_file, trust_lock_wait_ms) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err == error.TrustFileBusy) {
            return .{ .failed = try writeHookFailure(alloc, ctx, json, command, "TrustFileBusy", "the trust file is busy; try again") };
        }
        const message = try arena.print("could not lock the trust file: {s}", .{@errorName(err)});
        return .{ .failed = try writeHookFailure(alloc, ctx, json, command, @errorName(err), message) };
    };
    return .{ .locked = lock };
}

/// `fx hook trust ID` and `fx hook trust --all`. Saves the trust file only when it changes.
fn runHookTrust(
    alloc: Allocator,
    ctx: Context,
    arena: Allocator,
    target: HookTrust,
    json: bool,
    loaded: *const hooks_host.loader.Snapshot,
    trust_file: []const u8,
    format: output_contracts.OutputFormat,
) !u8 {
    const lock = switch (try lockTrustFile(alloc, ctx, arena, json, "hook_trust", trust_file)) {
        .locked => |held| held,
        .failed => |code| return code,
    };
    defer lock.release();
    var store = hooks_host.trust.load(alloc, trust_file) catch |err| {
        if (err == error.OutOfMemory) return err;
        return writeHookFailure(alloc, ctx, json, "hook_trust", "TrustFileRefused", "The trust file was refused: fx could not read it");
    };
    defer store.deinit(alloc);
    const before = store.entries.items.len;
    var trusted: std.ArrayList([]const u8) = .empty;
    switch (target) {
        .id => |id| {
            const index = hookIndex(loaded, id) orelse return writeUnknownHook(alloc, ctx, json, "hook_trust", id);
            try addTrustedHook(alloc, arena, &store, loaded, index);
            try trusted.append(arena, loaded.hooks[index].id);
        },
        .all => {
            for (loaded.hooks, 0..) |hook, index| {
                if (loaded.trusted[index] or loaded.disabled[index]) continue;
                try addTrustedHook(alloc, arena, &store, loaded, index);
                try trusted.append(arena, hook.id);
            }
        },
    }
    if (store.entries.items.len != before) {
        hooks_host.trust.save(alloc, trust_file, &store) catch |err| {
            const message = try arena.print("could not save the trust file: {s}", .{@errorName(err)});
            return writeHookFailure(alloc, ctx, json, "hook_trust", @errorName(err), message);
        };
    }
    const snapshot: output_contracts.HookTrustSnapshot = .{ .trusted = trusted.items, .file = trust_file };
    return writeRendered(alloc, ctx, snapshot, format);
}

/// `fx hook enable ID` and `fx hook disable ID`. Saves the trust file only when the state changes.
fn runHookState(
    alloc: Allocator,
    ctx: Context,
    arena: Allocator,
    id: []const u8,
    disabled: bool,
    json: bool,
    loaded: *const hooks_host.loader.Snapshot,
    workspace_root: []const u8,
    trust_file: []const u8,
    format: output_contracts.OutputFormat,
) !u8 {
    const lock = switch (try lockTrustFile(alloc, ctx, arena, json, "hook_state", trust_file)) {
        .locked => |held| held,
        .failed => |code| return code,
    };
    defer lock.release();
    var store = hooks_host.trust.load(alloc, trust_file) catch |err| {
        if (err == error.OutOfMemory) return err;
        return writeHookFailure(alloc, ctx, json, "hook_state", "TrustFileRefused", "The trust file was refused: fx could not read it");
    };
    defer store.deinit(alloc);
    // A disabled record can outlive its hook file. Enable clears such a stranded record; disable needs a loaded hook.
    const stranded = !disabled and store.isDisabled(workspace_root, id);
    if (hookIndex(loaded, id) == null and !stranded) return writeUnknownHook(alloc, ctx, json, "hook_state", id);
    if (store.isDisabled(workspace_root, id) != disabled) {
        try store.setDisabled(alloc, workspace_root, id, disabled);
        hooks_host.trust.save(alloc, trust_file, &store) catch |err| {
            const message = try arena.print("could not save the trust file: {s}", .{@errorName(err)});
            return writeHookFailure(alloc, ctx, json, "hook_state", @errorName(err), message);
        };
    }
    const snapshot: output_contracts.HookStateSnapshot = .{ .id = id, .disabled = disabled, .file = trust_file };
    return writeRendered(alloc, ctx, snapshot, format);
}

test "fx hook log reads --limit and --json, and refuses a limit below one" {
    const logged = try parseHookArgs(&.{ "log", "--limit", "5", "--json" });
    try std.testing.expect(logged.json);
    switch (logged.command) {
        .log => |opts| try std.testing.expectEqual(@as(usize, 5), opts.limit),
        else => return error.TestExpectedEqual,
    }
    switch ((try parseHookArgs(&.{"log"})).command) {
        .log => |opts| try std.testing.expectEqual(@as(usize, 20), opts.limit),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectError(error.InvalidHookLimit, parseHookArgs(&.{ "log", "--limit", "0" }));
    try std.testing.expectError(error.InvalidHookLimit, parseHookArgs(&.{ "log", "--limit", "many" }));
    try std.testing.expectError(error.InvalidHookFlag, parseHookArgs(&.{ "list", "--limit", "5" }));
}

test "fx hook test accepts only user events" {
    try std.testing.expect(hookEventNamed("PreToolUse") != null);
    try std.testing.expect(hookEventNamed("TurnEnd") == null);
    switch ((try parseHookArgs(&.{ "test", "TurnEnd" })).command) {
        .@"test" => |opts| try std.testing.expect(opts.event == null),
        else => return error.TestExpectedEqual,
    }
    const names = try hookEventList(std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expect(std.mem.find(u8, names, "TurnEnd") == null);
    try std.testing.expect(std.mem.find(u8, names, "PreToolUse") != null);
}

test "fx hook log skips a line that is not a run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry = try parseHookLogLine(arena, "{\"time_ms\":1,\"event\":\"Stop\",\"match\":null,\"surface\":\"ask\",\"session_id\":null,\"ran\":1,\"decision\":\"proceed\",\"decided_by\":null,\"reason\":null,\"notices\":0}");
    try std.testing.expectEqualStrings("Stop", entry.?.event);
    try std.testing.expect((try parseHookLogLine(arena, "not json")) == null);
    try std.testing.expect((try parseHookLogLine(arena, "{\"time_ms\":1}")) == null);
}

test "fx hook test parses its event, match, and input" {
    const tested = try parseHookArgs(&.{ "test", "PreToolUse", "--match", "shell", "--input", "{\"tool_name\":\"shell\"}", "--json" });
    try std.testing.expect(tested.json);
    switch (tested.command) {
        .@"test" => |opts| {
            try std.testing.expectEqual(hook_engine.EventName.pre_tool_use, opts.event.?);
            try std.testing.expectEqualStrings("shell", opts.match.?);
            try std.testing.expectEqualStrings("{\"tool_name\":\"shell\"}", opts.input.?);
        },
        else => return error.TestExpectedEqual,
    }
    // An unknown event parses; the run answers it with exit 2 and the list of events.
    const unknown = try parseHookArgs(&.{ "test", "Nope" });
    switch (unknown.command) {
        .@"test" => |opts| {
            try std.testing.expect(opts.event == null);
            try std.testing.expectEqualStrings("Nope", opts.event_word);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectError(error.HookTestNeedsEvent, parseHookArgs(&.{"test"}));
    try std.testing.expectError(error.InvalidHookFlag, parseHookArgs(&.{ "list", "--match", "shell" }));
    try std.testing.expectError(error.InvalidHookFlag, parseHookArgs(&.{ "trust", "lint", "--input", "{}" }));
}

test "fx hook test reads --input as a JSON object of raw fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fields = try parseHookInput(arena, "{\"tool_name\":\"shell\",\"tool_input\":{\"command\":\"rm -rf x\"}}");
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("tool_name", fields[0].key);
    try std.testing.expectEqualStrings("\"shell\"", fields[0].value.json);
    try std.testing.expectEqualStrings("tool_input", fields[1].key);
    try std.testing.expectEqualStrings("{\"command\":\"rm -rf x\"}", fields[1].value.json);
    try std.testing.expectError(error.InvalidHookInput, parseHookInput(arena, "[1]"));
    try std.testing.expectError(error.InvalidHookInput, parseHookInput(arena, "not json"));
}

test "fx hook parses trust, enable, and disable" {
    const trusted = try parseHookArgs(&.{ "trust", "lint", "--json" });
    try std.testing.expect(trusted.json);
    switch (trusted.command) {
        .trust => |target| switch (target) {
            .id => |id| try std.testing.expectEqualStrings("lint", id),
            .all => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
    const all = try parseHookArgs(&.{ "trust", "--all" });
    switch (all.command) {
        .trust => |target| switch (target) {
            .all => {},
            .id => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectError(error.HookTrustNeedsTarget, parseHookArgs(&.{"trust"}));
    try std.testing.expectError(error.HookTrustIdAndAll, parseHookArgs(&.{ "trust", "lint", "--all" }));
    switch ((try parseHookArgs(&.{ "disable", "lint" })).command) {
        .disable => |id| try std.testing.expectEqualStrings("lint", id),
        else => return error.TestExpectedEqual,
    }
    switch ((try parseHookArgs(&.{ "enable", "lint" })).command) {
        .enable => |id| try std.testing.expectEqualStrings("lint", id),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectError(error.InvalidHookFlag, parseHookArgs(&.{ "list", "--all" }));
    try std.testing.expectError(error.InvalidHookFlag, parseHookArgs(&.{ "disable", "lint", "--all" }));
    try std.testing.expectError(error.HookNeedsId, parseHookArgs(&.{"enable"}));
}

/// Writes a usage error: a JSON failure when `--json` is in the args, else the message and the usage line.
fn writeHookUsageError(ctx: Context, alloc: Allocator, args: []const [:0]const u8, err: anyerror) !void {
    if (requestsJson(args)) {
        if (try flagProblem(alloc, args)) |problem| {
            defer alloc.free(problem);
            return writeJsonCommandFailureCode(alloc, ctx, hookOutputKind(args), @errorName(err), problem);
        }
        const message = try hookUsageMessage(alloc, args, err);
        defer alloc.free(message);
        return writeJsonCommandFailureCode(alloc, ctx, hookOutputKind(args), @errorName(err), message);
    }
    if (err == error.InvalidHookFlag) {
        try writeFlagProblem(alloc, ctx, args);
    } else {
        const message = try hookUsageMessage(alloc, args, err);
        defer alloc.free(message);
        try writeStderr(ctx, "fx hook: ");
        try writeStderr(ctx, message);
        try writeStderr(ctx, "\n");
    }
    try writeUsage(ctx);
}

/// Whether `run` reads the settings and the workspace for these arguments. A usage error reads nothing,
/// and neither does fx's own agent asking for `trust` or `disable`, which `run` refuses first.
pub fn needsSettings(args: []const [:0]const u8, agent_is_fx: bool) bool {
    const opts = parseHookArgs(args) catch return false;
    return !(agent_is_fx and agentRefusedWord(opts.command) != null);
}

/// Runs the `fx hook` words in `args` and returns the exit code: 0 for a result, 1 for a failure,
/// 2 for a usage error. Output goes to `ctx.out`, messages to `ctx.err`.
pub fn run(ctx: Context, args: []const [:0]const u8) u8 {
    return runChecked(ctx, args) catch |err| {
        // The exit code below still says the command failed, so a message that cannot be written is dropped.
        ctx.err.print("fx hook: {s}\n", .{@errorName(err)}) catch {};
        return exit_failure;
    };
}

fn runChecked(ctx: Context, args: []const [:0]const u8) !u8 {
    const alloc = ctx.gpa;
    const opts = parseHookArgs(args) catch |err| {
        try writeHookUsageError(ctx, alloc, args, err);
        return exit_usage;
    };
    // fx's own agent may not change trust or disable a hook. This runs before the home, the settings,
    // or any file is read, so the answer does not depend on them.
    if (ctx.agent_is_fx) {
        if (agentRefusedWord(opts.command)) |word| {
            const message = try alloc.print("fx hook {s} needs a person, so it does not run inside fx's own agent.", .{word});
            defer alloc.free(message);
            return writeHookFailure(alloc, ctx, opts.json, hookOutputKind(args), "TrustNeedsPerson", message);
        }
    }
    const home = ctx.home orelse {
        try writeStderr(ctx, "fx hook: " ++ io_mod.no_home_dir_reason ++ "\n");
        return exit_failure;
    };
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var loaded = try hooks_host.loader.load(alloc, .{ .home = home, .workspace_root = ctx.workspace_root });
    defer loaded.deinit(alloc);
    const trust_file = try hooks_host.trust.path(alloc, home);
    defer alloc.free(trust_file);
    if (writesTrustFile(opts.command) and loaded.trust_refused) {
        const message = try trustRefusedMessage(alloc, &loaded, trust_file);
        defer alloc.free(message);
        return writeHookFailure(alloc, ctx, opts.json, hookOutputKind(args), "TrustFileRefused", message);
    }
    const format: output_contracts.OutputFormat = if (opts.json) .json else .text;
    switch (opts.command) {
        .list => {
            const snapshot = try hookListSnapshot(arena, ctx.hooks_enabled, ctx.workspace_root, home, &loaded);
            return writeRendered(alloc, ctx, snapshot, format);
        },
        .show => |id| {
            const index = hookIndex(&loaded, id) orelse return writeUnknownHook(alloc, ctx, opts.json, "hook_show", id);
            const snapshot = try hookShowSnapshot(arena, &loaded, index, ctx.workspace_root, home);
            return writeRendered(alloc, ctx, snapshot, format);
        },
        .trust => |target| return runHookTrust(alloc, ctx, arena, target, opts.json, &loaded, trust_file, format),
        .enable => |id| return runHookState(alloc, ctx, arena, id, false, opts.json, &loaded, ctx.workspace_root, trust_file, format),
        .disable => |id| return runHookState(alloc, ctx, arena, id, true, opts.json, &loaded, ctx.workspace_root, trust_file, format),
        .@"test" => |test_opts| return runHookTest(alloc, ctx, arena, opts.json, test_opts, home, ctx.workspace_root, loaded.trust_refused, format),
        .log => |log_opts| return runHookLog(alloc, ctx, arena, opts.json, log_opts.limit, home, format),
    }
}

/// Runs `hook_verbs.run` on its own thread, as the TUI's `/hook` job does, so a test can read the process's signal
/// dispositions while the run is in progress.
const TuiLikeRun = struct {
    home: []const u8,
    words: []const [:0]const u8,
    cancel: std.atomic.Value(bool) = .init(false),
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn go(self: *TuiLikeRun) void {
        _ = run(.{
            .gpa = std.testing.allocator,
            .out = &self.out.writer,
            .err = &self.err.writer,
            .home = self.home,
            .workspace_root = self.home,
            .hooks_enabled = false,
            .agent_is_fx = false,
            .cancel = &self.cancel,
        }, self.words);
    }
};

/// Waits until `path` exists, with a deadline. The hook writes that file before it sleeps, so it is the signal that the run is in progress.
fn waitForFile(io: std.Io, path: []const u8) !void {
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
    while (std.Io.Clock.awake.now(io).toMilliseconds() < deadline) {
        if (std.Io.Dir.openFileAbsolute(io, path, .{})) |file| {
            var opened = file;
            opened.close(io);
            return;
        } else |_| {}
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    return error.HookDidNotStart;
}

test "a /hook test run the way the TUI job runs it leaves the SIGTERM handler alone" {
    const alloc = std.testing.allocator;
    const io = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const pid_path = try std.Io.Dir.path.join(alloc, &.{ home, "hook.pid" });
    defer alloc.free(pid_path);
    const command = try std.mem.concat(alloc, u8, &.{ "echo $$ > '", pid_path, "'; exec sleep 30" });
    defer alloc.free(command);
    const text = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"shell\",\"hooks\":[{\"type\":\"command\",\"id\":\"sleepy\",\"command\":\"",
        command,
        "\"}]}]}}",
    });
    defer alloc.free(text);
    try tmp.dir.createDirPath(io, ".fx");
    const hooks_file = try profile_paths.rootPath(alloc, home, &.{"hooks.json"});
    defer alloc.free(hooks_file);
    try io_mod.writeFileAtomic(alloc, hooks_file, text);
    try std.Io.Dir.cwd().setFilePermissions(io, hooks_file, std.Io.File.Permissions.fromMode(0o600), .{});

    var before: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &before);
    const words = [_][:0]const u8{ "test", "PreToolUse", "--match", "shell" };
    var job: TuiLikeRun = .{ .home = home, .words = &words, .out = .init(alloc), .err = .init(alloc) };
    defer job.out.deinit();
    defer job.err.deinit();
    var thread = try std.Thread.spawn(.{}, TuiLikeRun.go, .{&job});
    const started = waitForFile(io, pid_path);
    // Read the disposition while the hook runs, then stop the run and join it on every path.
    var during: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &during);
    job.cancel.store(true, .seq_cst);
    thread.join();
    try started;
    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &after);
    // `handler` is an untagged C union, so compare the handler pointer, the field an install sets.
    try std.testing.expect(during.handler.handler == before.handler.handler);
    try std.testing.expect(after.handler.handler == before.handler.handler);
}

test "fx's own agent is refused trust and disable before the home or any file is read" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    // No home and no workspace: the refusal must come first, so neither is reached.
    const ctx: Context = .{
        .gpa = std.testing.allocator,
        .out = &out.writer,
        .err = &err.writer,
        .home = null,
        .workspace_root = "",
        .hooks_enabled = false,
        .agent_is_fx = true,
    };
    try std.testing.expectEqual(exit_failure, run(ctx, &.{ "trust", "lint", "--json" }));
    try std.testing.expectEqual(exit_failure, run(ctx, &.{ "disable", "lint", "--json" }));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "\"code\":\"TrustNeedsPerson\""));
    try std.testing.expectEqual(@as(usize, 0), err.written().len);
    try std.testing.expect(!needsSettings(&.{ "trust", "lint" }, true));
    try std.testing.expect(needsSettings(&.{ "enable", "lint" }, true));
}
