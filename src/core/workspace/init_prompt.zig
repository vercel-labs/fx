const std = @import("std");

pub const Mode = enum { create, audit };

pub const InitRequest = struct {
    workspace_root: []const u8,
    user_focus: []const u8,
    mode: Mode,
    full: bool,
};

const shared_rules =
    \\Never overwrite an existing AGENTS.md; read it first and ask before changing anything.
    \\Never write or modify files silently; report what exists before proposing changes.
    \\Keep it short: under 300 lines absolute max, target 150-400 words.
    \\Every line is injected into every agent session; every line must earn its place.
    \\Ground every statement in the repo; document only verifiable commands and facts.
    \\Include the WHY: 1-2 lines on what the project is and its purpose.
    \\Include the HOW: exact build, test, lint, and dev commands, including how to run a single test.
    \\Include the WHAT: repo structure only where non-obvious.
    \\Verify each command exists in the manifest (package.json scripts, Makefile, etc.) before documenting it.
    \\Exclude detailed directory listings, code style essays, task-specific instructions, and duplicated docs.
    \\Prefer file:line pointers over copied content that goes stale.
    \\Ask the maintainer about ambiguity instead of guessing.
    \\Report the word count and a summary of what was included/excluded and why.
    \\Never reference machine-local credential, session, or state paths.
;

const distilled_intro =
    \\You are generating a repository AGENTS.md contributor guide.
;

// Vendored from the agents-md skill; @embedFile cannot reach paths outside src.
const full_skill_text =
    \\---
    \\name: agents-md
    \\description: Create or improve a repository's AGENTS.md contributor/agent guide. Use when the user asks to generate, write, update, or audit an AGENTS.md (or agent instruction file) for a repo. Produces a short, research-backed, human-quality guide grounded in the actual repo state — not an auto-generated dump.
    \\---
    \\
    \\# AGENTS.md Builder
    \\
    \\## Overview
    \\
    \\AGENTS.md is injected into every agent session — it's the repo's onboarding doc for coding agents. Research (ETH Zurich, "Evaluating AGENTS.md", 2025; HumanLayer practice) shows doing it wrong *hurts*: auto-generated files reduce task success ~3% and raise cost 20%+. Every line must earn its place.
    \\
    \\## Research-backed do's and don'ts
    \\
    \\Include:
    \\- **The WHY** — 1–2 lines: what the project is and its purpose; helps agents prioritize.
    \\- **The HOW** — exact build/test/lint/dev commands, including non-obvious tooling (tools named in AGENTS.md get used ~160x more). Include how to run a *single* test.
    \\- **The WHAT** — structure only where non-obvious (e.g., "this dir isn't compiled", "tests must be registered in the test script").
    \\- **Pre-commit checks** — "run X and Y before committing; fix failures before finishing." Agents treat listed commands as mandatory checks.
    \\- **Commit/PR conventions** — derived from `git log`, not invented.
    \\- **Security gotchas** — env files, secrets handling.
    \\
    \\Exclude:
    \\- **Detailed directory listings** — proven not to help navigation; agents discover structure themselves.
    \\- **Code style essays** — linters/formatters enforce style deterministically; one sentence + tool name suffices.
    \\- **Task-specific instructions** — anything not universally true dilutes every session.
    \\- **Duplicated docs** — if README already says it, point to it. Prefer `file:line` pointers over copied content that goes stale.
    \\- **Auto-generated bulk** — never dump `/init`-style output.
    \\
    \\## Workflow
    \\
    \\1. **Check for existing AGENTS.md** (and CLAUDE.md/GEMINI.md). Read and report existing guides before proceeding. In create mode, if AGENTS.md exists, stop and report instead of overwriting. In audit mode, continue researching and propose diffs with reasons; do not modify existing guides without approval.
    \\2. **Explore the repo**: `package.json` scripts (or Makefile/Cargo.toml/etc.), `git log --oneline -15` for commit style, top-level layout, lint/format configs, CI workflows, test file patterns, env files (`.env.example`), lockfiles.
    \\3. **Verify commands actually exist** — only document scripts present in the manifest.
    \\4. **Draft** with Markdown headings, professional instructional tone, examples (commands, paths, naming patterns). Title it ("Repository Guidelines" works well).
    \\5. **Surface open questions** (package manager choice, coverage requirements) and resolve with the maintainer before finalizing.
    \\6. **Report word count** and a summary of what was included/excluded and why.
    \\
    \\## Optional sections (add only if relevant)
    \\
    \\- Security & configuration tips
    \\- Architecture overview (only if genuinely non-obvious)
    \\- **Self-updating/maintenance block** — instructs agents to detect drift (new scripts, dirs, tooling) before finishing a task and *ask the maintainer* before proposing a minimal diff. Effective because agents read AGENTS.md every session.
    \\- Nested AGENTS.md note — only for monorepos (closest file to the edited code wins).
    \\
    \\## Ecosystem notes
    \\
    \\- AGENTS.md is read by Codex, Cursor, Claude Code, Gemini CLI, Aider, Jules, and 20+ other tools. One file serves all.
    \\- For Claude Code, symlink: `ln -s AGENTS.md CLAUDE.md`. For Gemini CLI: set `context.fileName` in `.gemini/settings.json`. For Aider: add `read: AGENTS.md` to `.aider.conf.yml`.
    \\- Format spec and examples: https://agents.md/
;

fn mode_text(mode: Mode) []const u8 {
    return switch (mode) {
        .create => "Mode: create. Generate a new AGENTS.md for the workspace below. If one already exists, stop and report instead of overwriting.",
        .audit => "Mode: audit. Read the existing AGENTS.md in the workspace below and propose diffs with reasons for each change. Do not overwrite the file.",
    };
}

/// Caller owns the returned slice; free with alloc.free.
fn build_prompt(alloc: std.mem.Allocator, body: []const u8, workspace_root: []const u8, user_focus: []const u8, mode: Mode) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, body);
    try out.appendSlice(alloc, "\n\n");
    try out.appendSlice(alloc, shared_rules);
    try out.appendSlice(alloc, "\n\n");
    try out.appendSlice(alloc, mode_text(mode));
    try out.appendSlice(alloc, "\nWorkspace root: ");
    try out.appendSlice(alloc, workspace_root);
    try out.appendSlice(alloc, "\n");
    if (user_focus.len > 0) {
        try out.appendSlice(alloc, "Hard constraints:\n");
        try out.appendSlice(alloc, user_focus);
        try out.appendSlice(alloc, "\n");
    }
    return try out.toOwnedSlice(alloc);
}

/// Caller owns the returned slice; free with alloc.free.
pub fn buildDistilled(alloc: std.mem.Allocator, request: InitRequest) ![]u8 {
    return try build_prompt(alloc, distilled_intro, request.workspace_root, request.user_focus, request.mode);
}

/// Caller owns the returned slice; free with alloc.free.
pub fn buildFull(alloc: std.mem.Allocator, request: InitRequest) ![]u8 {
    return try build_prompt(alloc, full_skill_text, request.workspace_root, request.user_focus, request.mode);
}

test "distilled create contains minimality, no-overwrite, workspace root and user_focus" {
    const alloc = std.testing.allocator;
    const prompt = try buildDistilled(alloc, .{ .workspace_root = "/repo/root", .user_focus = "focus on docs", .mode = .create, .full = false });
    defer alloc.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "300") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Never overwrite") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "/repo/root") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "focus on docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "machine-local credential, session, or state paths") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "~/.fx") == null);
}

test "distilled audit proposes diffs and differs from create" {
    const alloc = std.testing.allocator;
    const audit = try buildDistilled(alloc, .{ .workspace_root = "/repo/root", .user_focus = "", .mode = .audit, .full = false });
    defer alloc.free(audit);
    const create = try buildDistilled(alloc, .{ .workspace_root = "/repo/root", .user_focus = "", .mode = .create, .full = false });
    defer alloc.free(create);

    try std.testing.expect(std.mem.indexOf(u8, audit, "diff") != null);
    try std.testing.expect(!std.mem.eql(u8, audit, create));
}

test "full embeds skill text with mode and workspace root" {
    const alloc = std.testing.allocator;
    const create = try buildFull(alloc, .{ .workspace_root = "/repo/root", .user_focus = "", .mode = .create, .full = true });
    defer alloc.free(create);
    const audit = try buildFull(alloc, .{ .workspace_root = "/repo/root", .user_focus = "extra notes", .mode = .audit, .full = true });
    defer alloc.free(audit);

    try std.testing.expect(std.mem.find(u8, audit, "In audit mode, continue researching and propose diffs with reasons") != null);
    try std.testing.expect(std.mem.find(u8, audit, "do not modify existing guides without approval") != null);
    try std.testing.expect(std.mem.find(u8, audit, "If present, stop and report") == null);
    try std.testing.expect(std.mem.find(u8, create, "In create mode, if AGENTS.md exists, stop and report instead of overwriting") != null);
    try std.testing.expect(std.mem.indexOf(u8, create, "AGENTS.md Builder") != null);
    try std.testing.expect(std.mem.indexOf(u8, create, "/repo/root") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "extra notes") != null);
    try std.testing.expect(!std.mem.eql(u8, audit, create));
    try std.testing.expect(std.mem.indexOf(u8, create, "300") != null);
    try std.testing.expect(std.mem.indexOf(u8, create, "Never overwrite") != null);
    try std.testing.expect(std.mem.indexOf(u8, create, "machine-local credential, session, or state paths") != null);
    try std.testing.expect(std.mem.indexOf(u8, create, "~/.fx") == null);
}
