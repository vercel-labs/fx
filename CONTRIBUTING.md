# Contributing

## Scope

`fx` is a CLI-first coding agent written in Zig.

Contributions should preserve that direction:

* CLI-first over terminal-IDE behavior

* explicit contracts over ad hoc strings and branches

* permission-first security model

* small, reviewable changes

* honest docs and status reporting

## Setup

Requirements:

* Zig `0.16.0+`

* interactive terminal for manual shell testing

* a Vercel OAuth session via `fx login` for model-backed flows. macOS Keychain API keys (via `fx setup`), `AI_GATEWAY_API_KEY`, and `VERCEL_OIDC_TOKEN` are also supported

Common commands:

```bash
zig fmt src/
zig build
zig build test
zig build run
```

## Verification Workflow

Keep the local development loop focused: run the narrowest test that covers the changed path, build fx, and exercise the change using `./zig-out/bin/fx`. The installed `fx` on `PATH` is not valid development evidence.

Once the focused checks pass, create a clean checkpoint commit, push the non-`main` feature branch, and open a draft PR immediately. The **Full CI** workflow runs the complete deterministic suite on native Linux x86_64, Linux aarch64, macOS x86_64, and macOS aarch64 runners. The native matrix builds, tests, and smoke-tests ReleaseSafe on every platform; formatting and the public-surface audit run in those ReleaseSafe jobs. Four duration-balanced, isolated ReleaseSafe E2E shards per platform use checked-in weights to assign every Bun test file once; files inside each shard run sequentially in separate Bun processes so terminal fixtures and process state cannot leak between files. A failed file receives one bounded retry after tmux is reset.

Standard PR CI reports ReleaseSafe Build & Test and deterministic E2E results. Do not mark the draft PR ready until all four Full CI jobs and the final ship gate have succeeded for the exact current commit. Each platform aggregate requires its ReleaseSafe native check and all four ReleaseSafe E2E shards. A result from an older commit does not count. Live model evals are separate from this gate because they require credentials and are not deterministic.

Changes to `build.zig` or `scripts/pgso/` also run the native macOS arm64 PGSO candidate workflow. That lane produces retained size, behavior, and performance evidence but does not alter any release artifact or update channel. Its pinned toolchain, local reproduction command, corpus exclusions, and failure rules are documented in [`scripts/pgso/README.md`](scripts/pgso/README.md).

Every pull request also receives informational ReleaseSafe binary-size
comparisons for Linux x86_64, Linux arm64, macOS x86_64, and macOS arm64. Each
comparison builds the pull request merge commit and base commit on the same
native runner, reports exact file and ELF or Mach-O section deltas, and emits a
warning at increases of 52,429 bytes (0.050000 MiB) or more. The warning requests
investigation but does not replace the full PGSO release gate or reject a valid
feature solely for adding code.

## Pull Requests

Every PR must carry exactly one label that describes its primary intent:

* `type: bug`: fixes incorrect behavior

* `type: feature`: adds a new user-facing capability

* `type: improvement`: improves existing user-facing behavior

* `type: docs`: changes documentation only

* `type: maintenance`: changes internal tooling, dependencies, CI, or implementation structure without a user-facing behavior change

* `type: release`: prepares or repairs a release

* `type: security`: fixes or hardens a security boundary

If you cannot manage labels, a maintainer or repository agent will apply the label before review. For a mixed PR, choose the label that best describes why the PR exists. Keep the title as a clean imperative sentence and do not add bracketed type prefixes such as `[bug]` or `[improvement]`.

## Repo Shape

* `src/main.zig`: composition root only

* `src/core/`: contracts, runtimes, config, sessions, permissions, MCP, skills

* `src/tools/`: built-in tool implementations

* `src/ui/`: terminal rendering, event loop, input, transcript

* `src/gateway/`: AI Gateway client transport

* `.fx/skills/`: optional fx-native workspace-level skill root

* `skills/`: optional shared workspace-level skill root

## Collaboration Rules

Before adding a new feature, answer these first:

1. Which module owns the behavior?
2. What is the typed contract?
3. Does it need persistence?
4. Does it need both text and JSON output?
5. What docs and tests land with it?
6. How is its deterministic E2E owner classified for macOS arm64 PGSO?

If that is unclear, stop and define it first.

### PGSO corpus ownership

Classify every root `tests/e2e/*.test.ts` file in
`scripts/pgso/corpus.json`. Put common or performance-sensitive behavior in
training. Put important correctness, recovery, security, and rare behavior in
verification-only. Exclude only nondeterministic, live-network, credentialed,
sound-related, or harness-only coverage, and record the reason.

Tests added to an existing file inherit its classification. Reconsider that
classification when a feature changes the file's product role, and remove stale
entries when deleting a feature or E2E owner. Normal PR CI rejects missing,
duplicate, stale, and unclassified files without running the full PGSO gate.

## Configuration and State

Config precedence (highest wins):

1. Environment variables such as `FX_MODEL`, `FX_PERMISSION_MODE`, and `FX_MAX_AGENT_STEPS`
2. `~/.fx/settings.json` → `workspaces["<workspace_path>"]` (profile workspace overrides)
3. `~/.fx/settings.json` top-level (profile global settings)
4. `<workspace>/.fx.json` (committed project defaults)
5. Built-in defaults

Project `.fx.json` accepts only repo-safe defaults: `sandbox`, `max_agent_steps`, `max_tool_result_bytes`, and `context`. Profile-owned keys such as `model`, `effort`, `fast_mode`, `slash_menu_categories`, `startup_scrollback`, `prompt_history`, `statusLine`, `skill_match_fuzzy`, `first_call_tool_choice`, `auto_upgrade`, `update_channel`, `permission_mode`, and `permission` are ignored from project config before their values are parsed.

Runtime state lives under `~/.fx/`:

* `~/.fx/sessions/<session-id>/session.json`

* `~/.fx/sessions/<session-id>/background/`

* `~/.fx/sessions/<session-id>/subagent/`

* `~/.fx/sessions/<session-id>/logs/`

Sessions are global and portable across workspaces. Each session tracks a `workspace_root` that updates when resumed from a different directory.

Subagent children are ordinary sessions with their own `~/.fx/sessions/<child-id>/` directory and their own history. The `subagent/` directory is per session on both sides of the relationship: a parent records create-operation identities there, and a child records its own control state there.

## Skills

There are two distinct skill categories in `fx`:

* `fx` roots that belong to the product itself: `.fx/skills`, `skills/`, `~/.fx/skills`

* compatibility roots discovered for other agent installs: `.opencode/skills`, `.codex/skills`, `.claude/skills`, `.agents/skills`, `.claw/skills`, plus their global equivalents

`/skills list` should make that distinction visible to the user.

`/skills add` and `/skills install` install full skill directories into the profile-owned `~/.fx/skills` managed root, not just `SKILL.md`. Workspace `.fx/skills` and `skills/` remain discoverable project-local instructions, not managed install targets.

The interactive agent can also install skills via the `install_skill` tool when the user asks to install one in conversation, including pasted `npx skills add ...` syntax.

## MCP

fx negotiates MCP `2026-07-28` over local stdio and stateless Streamable HTTP.
Version-scoped adapters retain legacy stdio,
`2025-11-25`/`2025-06-18`/`2025-03-26` Streamable HTTP, and deprecated
`2024-11-05` HTTP+SSE. Native sessions load runnable MCP configuration only
from the trusted profile:

* `~/.fx/mcp.json`

Project `.fx.json` does not define runnable MCP commands, URLs, env, or secrets.

The core feature surface is Tools, Resources and Resource Templates, Prompts,
Completion, pagination, cache-aware discovery, subscriptions, progress,
cancellation, and form or URL elicitation. Keep modern and legacy protocol
behavior in their existing version-scoped modules.

Tool schemas without `$schema` use JSON Schema 2020-12. fx also accepts the
canonical 2020-12 declaration and the canonical Draft 7 declaration used by
legacy SDKs, evaluates each with dialect-specific semantics, and rejects other
dialects or references that would require network fetching before publication.

The interactive surface supports:

* `/mcp list`

* `/mcp resource list <server>`

* `/mcp resource templates <server>`

* `/mcp resource read <server> <uri>`

* `/mcp resource complete <server> <uri-template> <variable> [value]`

* `/mcp prompt list <server>`

* `/mcp prompt get <server> <name> [arguments-json]`

* `/mcp prompt complete <server> <name> <argument> [value]`

* `/mcp add <name> <command> [args...]`

* `/mcp remove <name>`

* `/mcp reload`

* `/mcp auth <name> --open`

* `/mcp logout <name>`

* `/mcp path`

Remote authentication supports configured bearer tokens and OAuth credential
discovery, persistence, refresh, scope challenges, and logout. Credential and
private-cache identity changes invalidate prior private state. macOS persists
OAuth credentials in Keychain and migrates the private profile credential file
only after verified publication. Other platforms use the `0600` credential file
under the `0700` profile directory. `FX_DISABLE_KEYCHAIN=1` selects that portable
backend explicitly for deterministic tests and local troubleshooting.

Servers are optional by default. Required startup failures block the first TUI
or `fx ask` model request; optional failures publish a reduced, degraded
capability set. One-shot `fx ask` starts required servers before its first model
request and defers optional servers until the turn first performs an MCP
operation or delegates MCP capability to a child. `/mcp list` renders a bounded,
secret-free health snapshot.
`/mcp reload` evaluates a replacement before publication, so invalid config or
a required-server failure leaves the prior runtime callable.

ACP-provided servers are isolated to their owning ACP session. One-off and
persistent subagents receive an immutable, permission-filtered view of the
parent or ACP session's admitted MCP tools, resources, prompts, and completion
capability. Missing, revoked, stale, or closed authority fails before transport.

## Permissions and Auto Mode

Security is permission-first.

* `permission_mode` controls baseline behavior (`ask`, `auto`, or `yolo`)

* `permission` config applies OpenCode-style wildcard rules

* session `always` approvals are non-persistent; command approvals match the exact command while other grant categories may use patterns

* configured denies are evaluated before saved-session rules; an exact saved-session deny can narrow a configured allow, while an exact saved-session allow can satisfy an unresolved configured ask

* `/permissions remember allow|deny <tool-name> <arguments-json>` confirms and stores an exact rule only for an active saved session; `/permissions` lists stable rule IDs and `/permissions revoke <rule-id>` removes one

* routine parsed development commands and reversible new-file creation can execute without model review after configured and saved-session policy; unknown, destructive, hidden, credential-bearing, public, and overwrite effects remain on the review or approval path

* unresolved sensitive calls in `auto` mode receive one exact automatic review using bounded current, first, and recent proven root requests; historical permission feedback is excluded, and non-allow, unavailable, and invalid review results return a recoverable denial with an opaque action-bound approval request when capacity permits

* the main agent may pass that exact request ID through `ask_user_question` to open the existing permission screen; generic question text cannot authorize an action, and the resulting once or always approval is revalidated and consumed only by the exact bound action

* bounded consecutive all-blocked response groups end the turn with ordinary blocker text and never open the human approval path automatically; any completed successful tool resets that recovery count, and configured and saved-session rules remain authoritative

* the sandbox backend is configured independently; yolo uses an effective backend of `none` without rewriting the saved sandbox setting

Do not add new sensitive tool behavior without integrating it into `src/core/permissions/permissions.zig`.

## Writing a Resize Test

Render bugs that appear during window resize are hard to reason about because the footer is inline (hugs the transcript) rather than pinned to the terminal bottom, and the 100 ms debounce can mask ordering mistakes. The testing rig covers three layers. Pick the lowest layer that can catch the bug.

### Zig unit test (fastest, runs in `zig build test`)

Drive `TranscriptRuntime` against the built-in VT emulator. Assertions are on the cell grid after a sequence of writes and resize calls.

```zig
test "my resize scenario" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 4);
    try h.shell.writeTranscript(h.alloc, &h.metrics, 1024, "hello\n", true);
    try h.flush();

    try h.driveResize(60, 20, 4, true);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(h.alloc);
    try h.vt.rowText(1, &row);
    try std.testing.expectEqualStrings("hello               ", row.items);
}
```

Add it to `src/ui/resize_tests.zig`. See the file header for what each Harness method does.

### tmux end-to-end test (real SIGWINCH, seconds per test)

For bugs that only show up with a real terminal and a real signal (timing, input integration, terminal-emulator quirks), add a scenario to `tests/e2e/tui-resize.test.ts` using the helpers in `tmux-helpers.ts`:

```typescript
test("my scenario", async () => {
    session = await TmuxSession.create({ width: 120, height: 40 });
    await session.waitForText(">", 10_000);
    await session.resizeWindow(80, 30);
    const grid = await session.capturePaneGrid();
    expect(findFooter(grid)).not.toBeNull();
}, 30_000);
```

### Tape-based test (replay a real capture)

For bugs reported by a user, have them run fx with `FX_RECORD=<path>`. Drop the tape in `tests/e2e/tapes/<name>.fxtape` and assert against `fx replay --golden`:

```bash
fx replay tests/e2e/tapes/my-bug.fxtape --golden tests/e2e/tapes/my-bug.txt
```

Check in the golden file and wire a regression test that re-runs `fx replay` in CI and diffs.

## What Not To Do

* Do not grow `main.zig` with leaf feature logic

* Do not add hidden product state that only exists in the shell

* Do not add a second execution path for the same feature without a clear reason

* Do not document intended behavior as if it already exists

* Do not commit generated state from `.fx/`, `.zig-cache/`, or `zig-out/`

* Do not add a general alternate-screen (`\x1b[?1049h/l`) render path. fx is inline by design except for the five exclusive owner classes represented by `AlternateScreenOwner`: interactive tool-approval review, the full-transcript screen, catalog menus, the ctrl+x subagent manager, and the hosted child-terminal takeover. The terminal-session owner is entered only from the manager after `TerminalHost` grants the human write lease, has no permanent fx chrome, and must release the lease on detach. Every owner must leave or explicitly hand off the alternate buffer and restore the main grid, composer, cursor, paste, mouse, focus, and keyboard modes before resolving, cancelling, or shutting down

## Releases

Releases are triggered automatically when the version in `src/main.zig` changes on `main`:

1. Edit `pub const version = "X.Y.Z";` in `src/main.zig`
2. Merge to `main`
3. The release workflow checks if `vX.Y.Z` tag exists; if not, it builds four platform binaries, creates the git tag, and publishes a GitHub Release with the binaries attached

The install script and `fx upgrade` fetch binaries from `releases.fx.sh`, backed by the public Vercel Blob CDN. No authentication or external CLI tools are required. The release workflow also publishes binaries to the CDN and updates `latest.txt` automatically.

After CI passes for a push to `main`, the dev release workflow publishes commit-addressed binaries and then updates `dev.json`. Dogfooders opt in with `fx upgrade --channel dev`; the choice is stored in their user settings and applies to manual upgrades, automatic upgrades, and the `ctrl+g` handoff. `fx upgrade --channel stable` returns to tagged releases. Dev publishing does not create tags or GitHub Releases.

Release notes are public product copy. Describe user-visible behavior, always spell the product `fx`, and omit contributor attribution, tracker references, repository or website work, delivery infrastructure, CI and test details, branch history, and implementation-only refactors. Use commits and pull requests as research evidence only. Changelog formatting and release-marker rules live in `AGENTS.md`.

Do not create tags manually. The workflow owns tag creation.

## Benchmarks

Startup latency benchmarks run automatically on every PR and push to `main` via `.github/workflows/bench.yml`.

The workflow builds a ReleaseSafe binary, then uses [hyperfine](https://github.com/sharkdp/hyperfine) to measure wall-clock time for six paths:

| Command                | Budget | What it measures                                   |
| ---------------------- | ------ | -------------------------------------------------- |
| `fx` (startup)         | 2ms    | Binary launch through CLI dispatch (no TTY needed) |
| `fx help`              | 2ms    | Minimal startup, pure text output                  |
| `fx status --json`     | 2ms    | Config read + JSON serialization                   |
| `fx background --json` | 2ms    | Background record read                             |
| `fx doctor --json`     | 2ms    | System checks, subprocess spawns                   |
| `fx sessions --json`   | 2ms    | Session directory read                             |

On PRs the check **fails** if any command exceeds its budget.

The table is the authoritative Linux CI contract. Non-Linux local runs report
raw means for comparison but do not assign a substitute product budget because
the host process and dynamic-loader floor can independently exceed 2ms. The
process baseline is diagnostic only and is never subtracted.

The startup benchmark uses `FX_BENCH=1`, which runs through CLI dispatch and exits before TTY initialization.

To run locally:

```bash
brew install hyperfine             # macOS (one-time)
./benchmarks/startup.sh            # full run (100 iterations, builds ReleaseSafe)
./benchmarks/startup.sh --quick    # quick run (20 iterations)
```

CI uses `--runs 100` with a reduced warmup and skips the build step because the
workflow builds ReleaseSafe first. Results are written to
`benchmarks/results/` (gitignored).

## Before Marking a PR Ready

Minimum checklist:

1. Run `zig fmt --check src/` and the focused tests for the changed path.
2. Run `zig build`, then exercise the change with `./zig-out/bin/fx`.
3. Push the feature branch and open a draft PR immediately.
4. Require all four **Full CI** jobs and the final ship gate to pass for the exact current commit before marking the PR ready.
5. Update `README.md` if user-facing behavior changed.
