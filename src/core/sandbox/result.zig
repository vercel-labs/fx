//! The command result fx keeps for a sandbox command. It has the same shape as
//! a local result. Its stderr ends with the notes that say where the command
//! ran and what moved, or why it did not run.
const std = @import("std");
const command_contract = @import("../execution/command_contract.zig");
const report_text = @import("report_text.zig");
const runtime = @import("runtime.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

/// The command result fx keeps for a sandbox command. The output is owned by
/// `alloc`; `command` and `cwd` are borrowed, as for local results.
pub fn toRunCommandResult(alloc: Allocator, report: runtime.Report, command: []const u8, cwd: []const u8) !command_contract.RunCommandResult {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const notes = try report_text.noteLines(arena, report);
    const outcome = report.outcome orelse {
        // The command never started. Its notes are its whole output, and it has no exit code.
        const snapshot: command_contract.CommandResultSnapshot = .{
            .command = command,
            .cwd = cwd,
            .status = .finished,
            .stdout_display = "",
            .stderr_display = notes,
            .stdout_bytes = 0,
            .stderr_bytes = 0,
        };
        return command_contract.formatCommandResult(alloc, snapshot);
    };

    // The command's own stderr comes first. Its notes follow on their own lines.
    const own_stderr = try text_utils.sanitizeModelText(arena, outcome.stderr);
    const separator: []const u8 = if (own_stderr.len > 0 and own_stderr[own_stderr.len - 1] != '\n') "\n" else "";
    const stderr_display: []const u8 = if (notes.len == 0)
        own_stderr
    else
        try arena.print("{s}{s}{s}", .{ own_stderr, separator, notes });

    const snapshot: command_contract.CommandResultSnapshot = .{
        .command = command,
        .cwd = cwd,
        .status = if (outcome.exit_code) |code| .{ .exit_code = code } else .indeterminate,
        .stdout_display = try text_utils.sanitizeModelText(arena, outcome.stdout),
        .stderr_display = stderr_display,
        .stdout_bytes = outcome.stdout_bytes,
        .stderr_bytes = outcome.stderr_bytes,
        .output_incomplete = outcome.truncated,
        .duration_ms = outcome.duration_ms,
    };
    var result = try command_contract.formatCommandResult(alloc, snapshot);
    errdefer alloc.free(result.output);
    if (outcome.stop == .timed_out) result.command_result.?.timed_out = true;
    if (outcome.stop == .cancelled) result.cancelled = true;
    return result;
}

// ---- tests (run in the full suite) ----

const testing = std.testing;

/// How many times `needle` occurs in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var rest = haystack;
    while (std.mem.find(u8, rest, needle)) |at| {
        count += 1;
        rest = rest[at + needle.len ..];
    }
    return count;
}

test "an exit 3 outcome keeps its code and carries its notes once in stderr" {
    const report: runtime.Report = .{
        .placement = .workspace,
        .sandbox = "fx-ws-x",
        .sync = .{ .session = "sbx_1", .baseline = "c0ffee", .sent = 0, .removed = 0, .full = false, .created = false },
        .outcome = .{ .started = true, .exit_code = 3, .stdout = "hello\n" },
    };

    const result = try toRunCommandResult(testing.allocator, report, "false", "/w");
    defer testing.allocator.free(result.output);
    try testing.expectEqual(@as(?i64, 3), result.command_result.?.exit_code);
    try testing.expect(std.mem.find(u8, result.output, "exit_code=3") != null);
    try testing.expect(std.mem.find(u8, result.output, "<stderr>\nfx: Ran in the workspace sandbox fx-ws-x, synced from this machine first.\n</stderr>\n") != null);
    try testing.expectEqual(@as(usize, 1), countOccurrences(result.output, "fx: Ran in the workspace sandbox"));
}

test "a command's own stderr comes before its notes" {
    const report: runtime.Report = .{
        .placement = .workspace,
        .sandbox = "fx-ws-x",
        .sync = .{ .session = "sbx_1", .baseline = "c0ffee", .sent = 0, .removed = 0, .full = false, .created = false },
        .outcome = .{ .started = true, .exit_code = 0, .stderr = "warn" },
    };

    const result = try toRunCommandResult(testing.allocator, report, "warn", "/w");
    defer testing.allocator.free(result.output);
    try testing.expect(std.mem.find(u8, result.output, "<stderr>\nwarn\nfx: Ran in the workspace sandbox fx-ws-x, synced from this machine first.\n</stderr>\n") != null);
}

test "a command that did not run has no exit code and says so in stderr" {
    const report: runtime.Report = .{ .placement = .workspace, .problem = "No Vercel login." };

    const result = try toRunCommandResult(testing.allocator, report, "ls", "/w");
    defer testing.allocator.free(result.output);
    try testing.expect(std.mem.find(u8, result.output, "process finished\n") != null);
    try testing.expect(std.mem.find(u8, result.output, "<stderr>\nfx: This command did not run. No Vercel login.\n</stderr>\n") != null);
    try testing.expectEqual(@as(?i64, null), result.command_result.?.exit_code);
}

test "a timed-out command sets timed_out" {
    const report: runtime.Report = .{
        .placement = .isolated,
        .outcome = .{ .started = true, .stop = .timed_out, .connection_lost = true },
    };

    const result = try toRunCommandResult(testing.allocator, report, "sleep 99", "/w");
    defer testing.allocator.free(result.output);
    try testing.expect(result.command_result.?.timed_out);
    try testing.expectEqual(@as(?i64, null), result.command_result.?.exit_code);
}
