//! Deterministic reductions of recognized command output. No execution or I/O.
//! Unknown syntax and lines pass through; callers retain the original output.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Kind = enum { bun_tests, zig_tests, cargo_tests, git_status };
const max_output_bytes = 64 * 1024;

/// Returns an owned smaller view, or null to keep `output`. The recovery
/// notice is included in the size comparison. Caller frees a returned view.
pub fn reduce(alloc: Allocator, command: []const u8, output: []const u8) Allocator.Error!?[]u8 {
    if (output.len < 128 or output.len > max_output_bytes) return null;
    const kind = classify(command) orelse return null;
    if (kind == .git_status and
        !std.mem.startsWith(u8, output, "On branch ") and
        !std.mem.startsWith(u8, output, "HEAD detached ")) return null;

    var retained: std.Io.Writer.Allocating = .init(alloc);
    defer retained.deinit();
    var omitted: usize = 0;
    var at: usize = 0;
    while (at < output.len) {
        const end = if (std.mem.findScalarPos(u8, output, at, '\n')) |newline| newline + 1 else output.len;
        const span = output[at..end];
        const line = std.mem.trimEnd(u8, span, "\r\n");
        if (omittable(kind, line)) {
            omitted += 1;
        } else {
            retained.writer.writeAll(span) catch return error.OutOfMemory;
        }
        at = end;
    }
    if (omitted == 0) return null;

    var view: std.Io.Writer.Allocating = .init(alloc);
    defer view.deinit();
    view.writer.print(
        "[rtk: {d} {s} lines omitted; full output remains available via full_output_handle]\n",
        .{ omitted, if (kind == .git_status) "git status advice" else "passing test" },
    ) catch return error.OutOfMemory;
    view.writer.writeAll(retained.written()) catch return error.OutOfMemory;
    if (view.written().len >= output.len) return null;
    return try view.toOwnedSlice();
}

fn classify(command: []const u8) ?Kind {
    // This is deliberately a small literal-command subset, not a second
    // shell parser. In particular, never interpret pipelines, redirections,
    // quoting, substitutions, globs, comments, or compound commands.
    if (command.len > 8192 or std.mem.findAny(u8, command, "\x00\r\n;&|<>$`'\"(){}[]*?#\\~") != null) return null;
    var words = std.mem.tokenizeAny(u8, command, " \t");
    const executable = words.next() orelse return null;
    const program = std.Io.Dir.path.basename(executable);
    const verb = words.next() orelse return null;
    if (std.mem.eql(u8, program, "git") and std.mem.eql(u8, verb, "status")) {
        return if (words.next() == null) .git_status else null;
    }
    if (std.mem.eql(u8, program, "bun") and std.mem.eql(u8, verb, "test")) return .bun_tests;
    if (std.mem.eql(u8, program, "cargo") and std.mem.eql(u8, verb, "test")) return .cargo_tests;
    if (std.mem.eql(u8, program, "zig")) {
        if (std.mem.eql(u8, verb, "test")) return .zig_tests;
        if (std.mem.eql(u8, verb, "build") and std.mem.eql(u8, words.next() orelse "", "test")) return .zig_tests;
    }
    return null;
}

fn omittable(kind: Kind, line: []const u8) bool {
    // Test runners can interleave application logs with their status lines.
    // Retain diagnostic-looking text even when the surrounding line passes.
    if (kind != .git_status and containsDiagnostic(line)) return false;
    return switch (kind) {
        .bun_tests => bunPass(line),
        .cargo_tests => cargoPass(line),
        .zig_tests => zigPass(line),
        .git_status => blk: {
            const advice = [_][]const u8{
                "  (use \"git restore --staged <file>...\" to unstage)",
                "  (use \"git add <file>...\" to update what will be committed)",
                "  (use \"git add/rm <file>...\" to update what will be committed)",
                "  (use \"git restore <file>...\" to discard changes in working directory)",
                "  (use \"git add <file>...\" to include in what will be committed)",
                "  (use \"git rm --cached <file>...\" to unstage)",
            };
            for (advice) |known| if (std.mem.eql(u8, line, known)) break :blk true;
            break :blk false;
        },
    };
}

fn containsDiagnostic(line: []const u8) bool {
    for ([_][]const u8{ "warning", "error", "panic", "fatal", "failed", "exception", "traceback" }) |word| {
        if (line.len < word.len) continue;
        for (0..line.len - word.len + 1) |index| {
            if (std.ascii.eqlIgnoreCase(line[index..][0..word.len], word)) return true;
        }
    }
    return false;
}

fn cargoPass(line: []const u8) bool {
    if (line.len <= "test ".len + " ... ok".len) return false;
    if (!std.mem.startsWith(u8, line, "test ") or !std.mem.endsWith(u8, line, " ... ok")) return false;
    const name = line["test ".len .. line.len - " ... ok".len];
    return name.len > 0 and std.mem.findAny(u8, name, " \t\r") == null;
}

fn bunPass(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "(pass) ") or !std.mem.endsWith(u8, line, "s]")) return false;
    const start = std.mem.findLast(u8, line, " [") orelse return false;
    const unit_len: usize = if (std.mem.endsWith(u8, line, "ms]")) 3 else 2;
    const duration = std.fmt.parseFloat(f64, line[start + 2 .. line.len - unit_len]) catch return false;
    return std.math.isFinite(duration) and duration >= 0;
}

fn zigPass(line: []const u8) bool {
    if (!std.mem.endsWith(u8, line, "...OK")) return false;
    const space = std.mem.findScalar(u8, line, ' ') orelse return false;
    const slash = std.mem.findScalar(u8, line[0..space], '/') orelse return false;
    const index = std.fmt.parseUnsigned(usize, line[0..slash], 10) catch return false;
    const total = std.fmt.parseUnsigned(usize, line[slash + 1 .. space], 10) catch return false;
    return index > 0 and index <= total;
}

fn testOutput(alloc: Allocator, kind: Kind) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (0..30) |index| switch (kind) {
        .bun_tests => try out.writer.print("(pass) suite > important test {d} [0.12ms]\n", .{index}),
        .cargo_tests => try out.writer.print("test suite::important_test_{d} ... ok\n", .{index}),
        .zig_tests => try out.writer.print("{d}/30 module.test.important test {d}...OK\n", .{ index + 1, index }),
        .git_status => unreachable,
    };
    try out.writer.writeAll("warning: retain this exact diagnostic\n30 tests passed\n");
    return try out.toOwnedSlice();
}

test "rtk collapses only recognized passes and preserves diagnostics and summaries" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { command: []const u8, kind: Kind }{
        .{ .command = "bun test test.ts", .kind = .bun_tests },
        .{ .command = "/tmp/bin/cargo test", .kind = .cargo_tests },
        .{ .command = "zig build test", .kind = .zig_tests },
        .{ .command = "zig test src/root.zig", .kind = .zig_tests },
    };
    for (cases) |case| {
        const raw = try testOutput(alloc, case.kind);
        defer alloc.free(raw);
        const view = (try reduce(alloc, case.command, raw)).?;
        defer alloc.free(view);
        try std.testing.expect(view.len < raw.len);
        try std.testing.expect(std.mem.find(u8, view, "30 passing test lines omitted") != null);
        try std.testing.expect(std.mem.endsWith(u8, view, "warning: retain this exact diagnostic\n30 tests passed\n"));
        try std.testing.expectEqual(@as(?[]u8, null), try reduce(alloc, case.command, view));
    }
}

test "rtk does not interpret shell syntax or unsupported command output" {
    const alloc = std.testing.allocator;
    const raw = try testOutput(alloc, .cargo_tests);
    defer alloc.free(raw);
    for ([_][]const u8{
        "cat test-output.txt",        "cargo test | cat",          "cargo test; cat file",     "cargo test && cat file",
        "cargo test > log",           "cargo test $(echo filter)", "cargo test `echo filter`", "cargo test\ncat file",
        "cargo test 'quoted filter'", "cargo test # comment",      "cargo test *.rs",          "env cargo test",
    }) |command| try std.testing.expectEqual(@as(?[]u8, null), try reduce(alloc, command, raw));
    try std.testing.expectEqual(@as(?[]u8, null), try reduce(alloc, "bun test", "(pass) tiny [1ms]\n"));
}

test "rtk git status preserves branch paths conflicts and unrecognized advice" {
    const alloc = std.testing.allocator;
    const raw =
        "On branch topic\nChanges not staged for commit:\n" ++
        "  (use \"git add <file>...\" to update what will be committed)\n" ++
        "  (use \"git restore <file>...\" to discard changes in working directory)\n" ++
        "\tmodified:   path with spaces.txt\n\tboth modified: conflict.zig\n" ++
        "Untracked files:\n  (use \"git add <file>...\" to include in what will be committed)\n" ++
        "\tnew-file.zig\nunknown advice stays\n";
    const view = (try reduce(alloc, "git status", raw)).?;
    defer alloc.free(view);
    try std.testing.expect(std.mem.find(u8, view, "3 git status advice lines omitted") != null);
    for ([_][]const u8{ "On branch topic", "path with spaces.txt", "both modified: conflict.zig", "new-file.zig", "unknown advice stays" }) |text| {
        try std.testing.expect(std.mem.find(u8, view, text) != null);
    }
    try std.testing.expectEqual(@as(?[]u8, null), try reduce(alloc, "git status --porcelain", raw));
    try std.testing.expectEqual(@as(?[]u8, null), try reduce(alloc, "git status", "Sur la branche topic\n" ++ raw));
}

test "rtk preserves unknown lines and partial pass markers exactly" {
    const alloc = std.testing.allocator;
    const raw = "(pass) missing timing\n(pass) invalid [nanms]\n0/1 invalid...OK\n2/1 invalid...OK\n";
    try std.testing.expectEqual(@as(?[]u8, null), try reduce(alloc, "bun test", raw));
    try std.testing.expect(!zigPass("0/1 invalid...OK"));
    try std.testing.expect(!zigPass("2/1 invalid...OK"));
    try std.testing.expect(!bunPass("(pass) invalid [nanms]"));
    try std.testing.expect(!cargoPass("test ... ok"));
    try std.testing.expect(!omittable(.cargo_tests, "test example WARNING: retain diagnostic ... ok"));
    try std.testing.expect(!omittable(.cargo_tests, "test suite::case arbitrary interleaved output ... ok"));
    try std.testing.expect(!omittable(.bun_tests, "(pass) suite WARNING: retain diagnostic [1ms]"));
    try std.testing.expect(!omittable(.zig_tests, "1/1 suite.test.ERROR: retain diagnostic...OK"));
}
