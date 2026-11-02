const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Workflow = enum {
    pull_request,
    issue,
};

pub const Draft = struct {
    title: []u8,
    body: []u8,

    pub fn deinit(self: Draft, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
    }
};

pub const PublishResult = struct {
    ok: bool,
    text: []u8,

    pub fn deinit(self: PublishResult, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

const CompletedProcess = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

/// Splits a drafted PR or issue into its title line and Markdown body. The
/// draft prompts always ask for both, so text without a body is not a draft.
pub fn parseDraft(alloc: Allocator, text: []const u8) !Draft {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const first_break = std.mem.findScalar(u8, trimmed, '\n') orelse return error.InvalidGithubDraft;

    const title_slice = plainTitle(trimmed[0..first_break]);
    if (title_slice.len == 0) return error.InvalidGithubDraft;

    const body_slice = std.mem.trimStart(u8, trimmed[first_break + 1 ..], " \t\r\n");
    const title = try alloc.dupe(u8, title_slice);
    errdefer alloc.free(title);
    const body = try alloc.dupe(u8, body_slice);
    return .{
        .title = title,
        .body = body,
    };
}

/// Returns the title line without the Markdown that GitHub shows literally in
/// a title: a leading heading marker and bold wrapping the whole line.
fn plainTitle(line: []const u8) []const u8 {
    var title = std.mem.trim(u8, line, " \t\r\n");

    const hashes = std.mem.findNone(u8, title, "#") orelse title.len;
    if (hashes >= 1 and hashes <= 6 and (hashes == title.len or title[hashes] == ' ' or title[hashes] == '\t')) {
        title = std.mem.trim(u8, title[hashes..], " \t");
    }

    const bold = "**";
    if (title.len > 2 * bold.len and std.mem.startsWith(u8, title, bold) and std.mem.endsWith(u8, title, bold)) {
        const inner = title[bold.len .. title.len - bold.len];
        if (std.mem.find(u8, inner, bold) == null) title = std.mem.trim(u8, inner, " \t");
    }
    return title;
}

pub fn publish(alloc: Allocator, workflow: Workflow, draft: Draft) !PublishResult {
    var argv = try buildPublishArgv(alloc, workflow, draft.title, draft.body);
    defer argv.deinit(alloc);

    const result = runPublishCommand(alloc, argv.items) catch |err| {
        return publishResultFromRunError(alloc, err);
    };
    return publishResultFromProcess(alloc, result);
}

fn buildPublishArgv(alloc: Allocator, workflow: Workflow, title: []const u8, body: []const u8) !std.ArrayList([]const u8) {
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(alloc);

    try argv.append(alloc, "gh");
    try argv.append(alloc, switch (workflow) {
        .pull_request => "pr",
        .issue => "issue",
    });
    try argv.append(alloc, "create");
    try argv.append(alloc, "--title");
    try argv.append(alloc, title);
    try argv.append(alloc, "--body");
    try argv.append(alloc, body);
    return argv;
}

fn runPublishCommand(alloc: Allocator, argv: []const []const u8) !CompletedProcess {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn publishResultFromRunError(alloc: Allocator, err: anyerror) !PublishResult {
    return switch (err) {
        error.FileNotFound => .{ .ok = false, .text = try alloc.dupe(u8, "gh CLI not found in PATH") },
        else => err,
    };
}

fn publishResultFromProcess(alloc: Allocator, result: CompletedProcess) !PublishResult {
    defer alloc.free(result.stderr);

    if (result.term.exited != 0) {
        defer alloc.free(result.stdout);
        const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_trimmed.len > 0) {
            return .{ .ok = false, .text = try alloc.dupe(u8, stderr_trimmed) };
        }
        return .{ .ok = false, .text = try alloc.dupe(u8, "gh command failed") };
    }

    const stdout_trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (stdout_trimmed.len == 0) {
        alloc.free(result.stdout);
        return .{ .ok = true, .text = try alloc.dupe(u8, "created successfully") };
    }
    if (stdout_trimmed.len == result.stdout.len) {
        return .{ .ok = true, .text = result.stdout };
    }

    const text = alloc.dupe(u8, stdout_trimmed) catch |err| {
        alloc.free(result.stdout);
        return err;
    };
    alloc.free(result.stdout);
    return .{ .ok = true, .text = text };
}

test "parse draft extracts title and body" {
    const draft = try parseDraft(std.testing.allocator, "Title\n\n## Summary\nhello");
    defer draft.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Title", draft.title);
    try std.testing.expectEqualStrings("## Summary\nhello", draft.body);
}

test "parse draft rejects whitespace-only input" {
    try std.testing.expectError(error.InvalidGithubDraft, parseDraft(std.testing.allocator, " \n\t "));
}

test "parse draft rejects text without a body" {
    // "Done." is what fx records when the model's final reply is empty.
    for ([_][]const u8{ "Title only", "Done.", "Title only \r\n\t " }) |text| {
        try std.testing.expectError(error.InvalidGithubDraft, parseDraft(std.testing.allocator, text));
    }
}

test "parse draft trims outer whitespace and preserves body markdown" {
    const draft = try parseDraft(
        std.testing.allocator,
        " \r\n  Title with space  \r\n\r\n  - one\r\n  - two\r\n\n",
    );
    defer draft.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Title with space", draft.title);
    try std.testing.expectEqualStrings("- one\r\n  - two", draft.body);
}

test "parse draft removes Markdown that GitHub shows literally in a title" {
    const cases = [_]struct { input: []const u8, title: []const u8, body: []const u8 }{
        .{ .input = "## Add note probe\n\n## Summary\nbody", .title = "Add note probe", .body = "## Summary\nbody" },
        .{ .input = "**Add note probe**\n\nbody", .title = "Add note probe", .body = "body" },
        .{ .input = "# **Add note probe**\n\nbody", .title = "Add note probe", .body = "body" },
        .{ .input = "#123 Keep `code` and **part** bold\n\nbody", .title = "#123 Keep `code` and **part** bold", .body = "body" },
        .{ .input = "**Bold** and **more**\n\nbody", .title = "**Bold** and **more**", .body = "body" },
        .{ .input = "__init__ runs twice\n\nbody", .title = "__init__ runs twice", .body = "body" },
    };
    for (cases) |case| {
        const draft = try parseDraft(std.testing.allocator, case.input);
        defer draft.deinit(std.testing.allocator);

        try std.testing.expectEqualStrings(case.title, draft.title);
        try std.testing.expectEqualStrings(case.body, draft.body);
    }
}

test "parse draft rejects a title that is only Markdown" {
    try std.testing.expectError(error.InvalidGithubDraft, parseDraft(std.testing.allocator, "##\n\n## Summary\nbody"));
    try std.testing.expectError(error.InvalidGithubDraft, parseDraft(std.testing.allocator, "**  **\n\nbody"));
}

test "publish argv maps pull request workflow" {
    var argv = try buildPublishArgv(std.testing.allocator, .pull_request, "A title", "Body text");
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), argv.items.len);
    try std.testing.expectEqualStrings("gh", argv.items[0]);
    try std.testing.expectEqualStrings("pr", argv.items[1]);
    try std.testing.expectEqualStrings("create", argv.items[2]);
    try std.testing.expectEqualStrings("--title", argv.items[3]);
    try std.testing.expectEqualStrings("A title", argv.items[4]);
    try std.testing.expectEqualStrings("--body", argv.items[5]);
    try std.testing.expectEqualStrings("Body text", argv.items[6]);
}

test "publish argv maps issue workflow" {
    var argv = try buildPublishArgv(std.testing.allocator, .issue, "A title", "Body text");
    defer argv.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), argv.items.len);
    try std.testing.expectEqualStrings("gh", argv.items[0]);
    try std.testing.expectEqualStrings("issue", argv.items[1]);
    try std.testing.expectEqualStrings("create", argv.items[2]);
    try std.testing.expectEqualStrings("--title", argv.items[3]);
    try std.testing.expectEqualStrings("A title", argv.items[4]);
    try std.testing.expectEqualStrings("--body", argv.items[5]);
    try std.testing.expectEqualStrings("Body text", argv.items[6]);
}

test "publish maps missing gh executable to handled failure" {
    const result = try publishResultFromRunError(std.testing.allocator, error.FileNotFound);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("gh CLI not found in PATH", result.text);
}

test "publish returns trimmed stderr for non-zero exit" {
    const stdout = try std.testing.allocator.dupe(u8, "ignored");
    const stderr = try std.testing.allocator.dupe(u8, " \nfailed to create\n ");

    const result = try publishResultFromProcess(std.testing.allocator, .{
        .term = .{ .exited = 1 },
        .stdout = stdout,
        .stderr = stderr,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("failed to create", result.text);
}

test "publish returns fallback for non-zero exit without stderr" {
    const stdout = try std.testing.allocator.dupe(u8, "ignored");
    const stderr = try std.testing.allocator.dupe(u8, " \n\t ");

    const result = try publishResultFromProcess(std.testing.allocator, .{
        .term = .{ .exited = 1 },
        .stdout = stdout,
        .stderr = stderr,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("gh command failed", result.text);
}

test "publish returns success fallback for empty stdout" {
    const stdout = try std.testing.allocator.dupe(u8, " \n\t ");
    const stderr = try std.testing.allocator.dupe(u8, "");

    const result = try publishResultFromProcess(std.testing.allocator, .{
        .term = .{ .exited = 0 },
        .stdout = stdout,
        .stderr = stderr,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("created successfully", result.text);
}

test "publish trims padded stdout" {
    const stdout = try std.testing.allocator.dupe(u8, " \nhttps://github.com/vercel-labs/fx/pull/1\n ");
    const stderr = try std.testing.allocator.dupe(u8, "");

    const result = try publishResultFromProcess(std.testing.allocator, .{
        .term = .{ .exited = 0 },
        .stdout = stdout,
        .stderr = stderr,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("https://github.com/vercel-labs/fx/pull/1", result.text);
}

test "publish transfers already-trimmed stdout ownership" {
    const stdout = try std.testing.allocator.dupe(u8, "https://github.com/vercel-labs/fx/issues/2");
    const stderr = try std.testing.allocator.dupe(u8, "");

    const result = try publishResultFromProcess(std.testing.allocator, .{
        .term = .{ .exited = 0 },
        .stdout = stdout,
        .stderr = stderr,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.ok);
    try std.testing.expect(result.text.ptr == stdout.ptr);
    try std.testing.expectEqualStrings("https://github.com/vercel-labs/fx/issues/2", result.text);
}
