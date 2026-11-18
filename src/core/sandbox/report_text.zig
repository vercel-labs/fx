//! The notes that follow a sandbox command's output, and the text of a
//! command that did not run. Pure: it reads a report and writes text.
const std = @import("std");
const config = @import("config.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;

/// Most names one note lists. The rest are counted.
const max_listed = 20;

/// The notes as command output carries them: one `fx: ` line per physical
/// line, each ending in a newline. Empty when there are none. A command that
/// did not run gets one line that says why.
pub fn noteLines(arena: Allocator, report: runtime.Report) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (report.outcome == null) {
        try appendPrefixed(arena, &out, try notRun(arena, report.problem orelse "fx did not run the command."));
        return out.items;
    }
    for (try noteList(arena, report)) |line| try appendPrefixed(arena, &out, line);
    return out.items;
}

/// Writes each non-empty line of `text` as its own `fx: ` line.
fn appendPrefixed(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) error{OutOfMemory}!void {
    var parts = std.mem.splitScalar(u8, text, '\n');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try out.appendSlice(arena, "fx: ");
        try out.appendSlice(arena, part);
        try out.append(arena, '\n');
    }
}

/// Where the command ran and what moved, one entry per note.
fn noteList(arena: Allocator, report: runtime.Report) error{OutOfMemory}![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    if (report.sync) |sync| {
        try addLine(arena, &lines, "Ran in the workspace sandbox {s}, synced from this machine first.", .{report.sandbox orelse ""});
        if (sync.created) {
            try addLine(arena, &lines, "fx copied this repository into a new workspace sandbox.", .{});
        } else if (sync.full) {
            try addLine(arena, &lines, "fx resynced the whole sandbox copy.", .{});
        }
    }
    if (report.bring_back) |back| {
        if (back.taken.len > 0) {
            try addLine(arena, &lines, "Brought back to this machine: {s}.", .{try listNames(arena, back.taken)});
        }
        if (back.conflicts.len > 0) {
            try addLine(arena, &lines, "Kept this machine's version of files that changed here and in the sandbox: {s}.", .{try listNames(arena, back.conflicts)});
        }
        if (back.refused.len > 0) {
            try addLine(arena, &lines, "Not brought back, because links and submodules stay in the sandbox: {s}.", .{try listNames(arena, back.refused)});
        }
        if (back.too_large) try addLine(arena, &lines, "The changed files were over the copy limit, so none came back.", .{});
    }
    if (report.bring_back_problem) |problem| {
        try addLine(arena, &lines, "The sandbox's file changes did not come back: {s}", .{problem});
    }
    if (report.warm_problem) |problem| {
        try addLine(arena, &lines, "The warm script did not finish: {s}", .{problem});
    }
    if (report.env_missing.len > 0) {
        try addLine(arena, &lines, "These profile variables are not set here, so the sandbox did not get them: {s}.", .{try listNames(arena, report.env_missing)});
    }
    if (report.isolated) |iso| {
        try isolatedNotes(arena, &lines, report, iso);
    }
    if (report.outcome) |outcome| {
        if (outcome.connection_lost) {
            if (report.isolated) |iso| {
                if (iso.removed) {
                    try addLine(arena, &lines, "The connection to the sandbox ended before the command finished. fx removed the sandbox, so the command stopped.", .{});
                } else {
                    try addLine(arena, &lines, "The connection to the sandbox ended before the command finished. It may still be running there.", .{});
                }
            } else if (report.sync != null) {
                try addLine(arena, &lines, "The connection to the sandbox ended before the command finished. It may still be running there, and fx will not run it again.", .{});
            }
        }
    }
    return lines.items;
}

/// The text of a command that never ran, with the reason.
fn notRun(arena: Allocator, problem: []const u8) error{OutOfMemory}![]const u8 {
    return arena.print("This command did not run. {s}", .{problem});
}

fn isolatedNotes(arena: Allocator, lines: *std.ArrayList([]const u8), report: runtime.Report, iso: anytype) error{OutOfMemory}!void {
    const network = try networkText(arena, report.network orelse .deny_all);
    try addLine(arena, lines, "Ran in a new isolated sandbox (profile {s}, network {s}), with no keys.", .{ report.profile orelse "default", network });
    if (iso.removed) {
        try addLine(arena, lines, "fx removed the sandbox afterwards.", .{});
    } else {
        try addLine(arena, lines, "fx could not remove the sandbox; the next fx start removes it.", .{});
    }
    if (iso.run_folder) |folder| {
        try addLine(arena, lines, "New and changed files are in {s}: {s}.", .{ folder, try listNames(arena, iso.outputs) });
    }
    if (iso.outputs_too_large) try addLine(arena, lines, "The new files were over the copy limit, so none came back.", .{});
    if (iso.deleted.len > 0) {
        try addLine(arena, lines, "Deleted in the sandbox only; nothing changed here: {s}.", .{try listNames(arena, iso.deleted)});
    }
    if (iso.refused.len > 0) {
        try addLine(arena, lines, "Not brought back, because links and unsafe paths stay in the sandbox: {s}.", .{try listNames(arena, iso.refused)});
    }
}

/// The network as the note words it: none, all, or the domains.
fn networkText(arena: Allocator, network: config.Network) error{OutOfMemory}![]const u8 {
    return switch (network) {
        .deny_all => "none",
        .allow_all => "all",
        .allow => |domains| try listNames(arena, domains),
    };
}

/// The names, joined with ", ". At most `max_listed` are shown, then `and <n> more`.
fn listNames(arena: Allocator, names: []const []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const shown = @min(names.len, max_listed);
    for (names[0..shown], 0..) |name, index| {
        if (index > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, name);
    }
    if (names.len > shown) {
        try out.appendSlice(arena, try arena.print(", and {d} more", .{names.len - shown}));
    }
    return out.items;
}

fn addLine(arena: Allocator, lines: *std.ArrayList([]const u8), comptime format: []const u8, args: anytype) error{OutOfMemory}!void {
    const text = try arena.print(format, args);
    if (text.len == 0) return;
    try lines.append(arena, text);
}

// ---- tests ----

const testing = std.testing;

test "workspace notes name every part in order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report: runtime.Report = .{
        .placement = .workspace,
        .sandbox = "fx-ws-abc",
        .sync = .{ .session = "sbx_1", .baseline = "c0ffee", .sent = 2, .removed = 1, .full = true, .created = false },
        .outcome = .{ .started = true, .exit_code = 0 },
        .bring_back = .{
            .taken = &.{ "a.txt", "b.txt" },
            .conflicts = &.{"c.txt"},
            .refused = &.{"l"},
        },
        .bring_back_problem = "copy failed",
        .warm_problem = "exit 3",
        .env_missing = &.{"FX_X"},
    };

    const text = try noteLines(arena, report);
    try testing.expectEqualStrings(
        "fx: Ran in the workspace sandbox fx-ws-abc, synced from this machine first.\n" ++
            "fx: fx resynced the whole sandbox copy.\n" ++
            "fx: Brought back to this machine: a.txt, b.txt.\n" ++
            "fx: Kept this machine's version of files that changed here and in the sandbox: c.txt.\n" ++
            "fx: Not brought back, because links and submodules stay in the sandbox: l.\n" ++
            "fx: The sandbox's file changes did not come back: copy failed\n" ++
            "fx: The warm script did not finish: exit 3\n" ++
            "fx: These profile variables are not set here, so the sandbox did not get them: FX_X.\n",
        text,
    );
}

test "a new workspace sandbox says it was copied, not resynced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report: runtime.Report = .{
        .placement = .workspace,
        .sandbox = "fx-ws-new",
        .sync = .{ .session = "sbx_1", .baseline = "c0ffee", .sent = 4, .removed = 0, .full = true, .created = true },
        .outcome = .{ .started = true, .exit_code = 0 },
    };

    try testing.expectEqualStrings(
        "fx: Ran in the workspace sandbox fx-ws-new, synced from this machine first.\n" ++
            "fx: fx copied this repository into a new workspace sandbox.\n",
        try noteLines(arena, report),
    );
}

test "isolated notes name the profile, network, and run folder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report: runtime.Report = .{
        .placement = .isolated,
        .profile = "web",
        .network = .{ .allow = &.{ "registry.npmjs.org", "*.example.com" } },
        .outcome = .{ .started = true, .exit_code = 0 },
        .isolated = .{
            .outcome = .{ .exit_code = 0 },
            .sandbox = "fx-iso-1",
            .run_folder = "/s/runs/x",
            .outputs = &.{"out.png"},
            .deleted = &.{"in.txt"},
            .refused = &.{"link"},
            .removed = true,
        },
    };

    const text = try noteLines(arena, report);
    try testing.expectEqualStrings(
        "fx: Ran in a new isolated sandbox (profile web, network registry.npmjs.org, *.example.com), with no keys.\n" ++
            "fx: fx removed the sandbox afterwards.\n" ++
            "fx: New and changed files are in /s/runs/x: out.png.\n" ++
            "fx: Deleted in the sandbox only; nothing changed here: in.txt.\n" ++
            "fx: Not brought back, because links and unsafe paths stay in the sandbox: link.\n",
        text,
    );
}

test "a sync-only report says only where it ran" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report: runtime.Report = .{
        .placement = .workspace,
        .sandbox = "fx-ws-x",
        .sync = .{ .session = "sbx_1", .baseline = "c0ffee", .sent = 0, .removed = 0, .full = false, .created = false },
        .outcome = .{ .started = true, .exit_code = 0 },
    };

    try testing.expectEqualStrings("fx: Ran in the workspace sandbox fx-ws-x, synced from this machine first.\n", try noteLines(arena, report));
}

test "a list shows 20 names and counts the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: [25][]const u8 = undefined;
    for (&names, 0..) |*name, index| name.* = try arena.print("f{d:0>2}.txt", .{index});
    const report: runtime.Report = .{
        .placement = .workspace,
        .sandbox = "fx-ws-x",
        .sync = .{ .session = "sbx_1", .baseline = "c0ffee", .sent = 0, .removed = 0, .full = false, .created = false },
        .outcome = .{ .started = true, .exit_code = 0 },
        .bring_back = .{ .taken = names[0..] },
    };

    const text = try noteLines(arena, report);
    try testing.expect(std.mem.find(u8, text, "fx: Brought back to this machine: f00.txt, ") != null);
    try testing.expect(std.mem.find(u8, text, "f19.txt, and 5 more.\n") != null);
    try testing.expect(std.mem.find(u8, text, "f20.txt") == null);
}

test "a lost connection says what may still be running" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report: runtime.Report = .{
        .placement = .workspace,
        .sandbox = "fx-ws-x",
        .sync = .{ .session = "sbx_1", .baseline = "c0ffee", .sent = 0, .removed = 0, .full = false, .created = false },
        .outcome = .{ .started = true, .connection_lost = true },
    };

    const text = try noteLines(arena, report);
    try testing.expect(std.mem.endsWith(u8, text, "fx: The connection to the sandbox ended before the command finished. It may still be running there, and fx will not run it again.\n"));
}

test "a command that did not run says so in one line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report: runtime.Report = .{ .placement = .workspace, .problem = "No Vercel login for the sandbox." };

    try testing.expectEqualStrings(
        "fx: This command did not run. No Vercel login for the sandbox.\n",
        try noteLines(arena, report),
    );
}

test "a multi-line note keeps the fx prefix on every line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report: runtime.Report = .{
        .placement = .workspace,
        .outcome = .{ .started = true, .exit_code = 0 },
        .bring_back_problem = "copy failed\nretry later",
    };

    try testing.expectEqualStrings(
        "fx: The sandbox's file changes did not come back: copy failed\n" ++
            "fx: retry later\n",
        try noteLines(arena, report),
    );
}

test "noteLines is empty when a command ran with nothing to note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report: runtime.Report = .{ .placement = .local, .outcome = .{ .started = true, .exit_code = 0 } };

    try testing.expectEqualStrings("", try noteLines(arena, report));
}
