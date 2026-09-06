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

Subagent children are internal ordinary sessions with their own `~/.fx/sessions/<child-id>/` directory and history. The parent owns one bounded `subagent/children.json` registry; each child carries only an immutable owner marker. Child sessions are hidden from ordinary session discovery and cannot be resumed directly. A first `subagent.message` creates a named persistent child for that parent; later messages continue it, and optional instructions replace only its child-specific system overlay.

## Skills

There are two distinct skill categories in `fx`:

* `fx` roots that belong to the product itself: `.fx/skills`, `skills/`, `~/.fx/skills`

* compatibility roots discovered for other agent installs: `.opencode/skills`, `.codex/skills`, `.claude/skills`, `.agents/skills`, `.claw/skills`, plus their global equivalents

`/skills list` should make that distinction visible to the user.

`/skills add` and `/skills install` install full skill directories into the profile-owned `~/.fx/skills` managed root, not just `SKILL.md`. Workspace `.fx/skills` and `skills/` remain discoverable project-local instructions, not managed install targets.

The interactive agent can also install skills via the `install_skill` tool when the user asks to install one in conversation, including pasted `npx skills add ...` syntax.

## MCP

Native fx connections use MCP v1 initialization by default over stdio,
Streamable HTTP, and deprecated `2024-11-05` HTTP+SSE. Servers using the newer
`2026-07-28` discovery lifecycle opt in with
`FX_MCP_PROTOCOL_VERSION=2026-07-28` in their configured `environment` map.
The SDK's host-owned client controls its own protocol negotiation. Native
sessions load trusted MCP configuration from the profile:

* `~/.fx/mcp.json`

They also read Claude-compatible workspace configuration from:

* `<workspace>/.mcp.json`

Project `.fx.json` does not define runnable MCP commands, URLs, env, or secrets.
The profile file reads top-level `mcp` and accepts `mcpServers` as a
compatibility alias; `mcp` wins when both exist, and every write uses `mcp`.
Suspicious server-like unsupported keys produce a bounded warning and block
profile mutation instead of being overwritten. The workspace file reads only
top-level `mcpServers`, accepts `command` plus `args`, and is opened as a
bounded no-follow regular file. Profile entries win native name collisions;
ACP request entries win ACP name collisions without deduplicating the request
array. Workspace entries are always optional and never load stored credentials.
Approved workspace `command`, `args`, `env`, and HTTP header values expand
`${VAR}` and `${VAR:-default}` from the fx process environment. Pending and
rejected entries do not read environment values. Missing required variables
leave an approved server unloaded and appear in `/mcp list` without exposing
values.

Interactive sessions keep pending workspace servers disconnected and request
project trust before any project-defined process or network effect. Pending
resource, prompt, completion, and authentication commands require explicit
`/mcp trust approve <name>` and a retry. Rejected servers remain disconnected.
Choices live only in profile `settings.json` under the canonical workspace key,
using `enabledMcpjsonServers`, `disabledMcpjsonServers`, and
`enableAllProjectMcpServers`. Repository files cannot persist their own
approval. `fx ask` and ACP skip pending workspace servers. Noninteractive users
approve them first with `fx mcp trust approve <name>`; rejected servers remain
disabled.

The core feature surface is Tools, Resources and Resource Templates, Prompts,
Completion, pagination, cache-aware discovery, subscriptions, progress,
cancellation, and form or URL elicitation. Keep modern and legacy protocol
behavior in their existing version-scoped modules.

fx bounds schema size and structure before publication. It accepts schemas
without `$schema`, the canonical JSON Schema 2020-12 declaration, and the
canonical Draft 7 declaration used by legacy SDKs; other declared dialects are
rejected. fx does not resolve network references or evaluate semantic schema
assertions. Servers validate their tool arguments and results.

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

* `/mcp add --transport http <name> <url>`

* `/mcp remove <name>`

* `/mcp reload`

* `/mcp auth <name> --open`

* `/mcp logout <name>`

* `/mcp trust approve <name>`

* `/mcp trust reject <name>`

* `/mcp trust approve-all`

* `/mcp trust reset`

* `/mcp path`

The noninteractive MCP surface supports:

* `fx mcp add <name> <command> [args...]`

* `fx mcp add --transport http <name> <url>`

* `fx mcp auth <name>`

* `fx mcp list`

* `fx mcp logout <name>`

* `fx mcp path`

* `fx mcp remove <name>`

* `fx mcp trust approve <name>`

* `fx mcp trust reject <name>`

* `fx mcp trust approve-all`

* `fx mcp trust reset`

The local form saves a stdio command. The HTTP form saves a remote Streamable
HTTP endpoint. List reads effective profile and workspace configuration plus
stored authentication state without connecting servers. Path prints the profile
configuration path. Remove uses the same locked canonical profile writer as
add. Trust updates the canonical workspace entry in profile settings. Auth and
logout run the existing remote credential lifecycle. None of these commands
constructs the TUI or contacts the Gateway.

The default MCP startup timeout is 30 seconds and remains overridable per
server with `startup_timeout_ms`. Exact direct `docker run` stdio commands
without `--cidfile` receive a private cidfile so fx can remove the container
after shutdown or startup failure. An explicit cidfile remains user-owned.

MongoDB Atlas Managed MCP configuration service accounts use the OAuth
client-credentials grant. fx does not implement that grant directly. Use
MongoDB's `mongodb-atlas-mcp-remote` stdio wrapper with inherited
`MDB_MCP_API_CLIENT_ID` and `MDB_MCP_API_CLIENT_SECRET` environment variables.
The Atlas App Connection browser flow is user-delegated access and must not be
treated as equivalent to configuration service-account credentials.

Remote authentication supports configured bearer tokens and OAuth credential
discovery, persistence, refresh, scope challenges, and logout. Credential and
private-cache identity changes invalidate prior private state. macOS persists
OAuth credentials in Keychain and migrates the private profile credential file
only after verified publication. If the user account has no default Keychain,
macOS falls back to the same `0600` credential file used on other platforms
under the `0700` profile directory. `FX_DISABLE_KEYCHAIN=1` selects that portable
backend explicitly for deterministic tests and local troubleshooting.

Servers are optional by default. Required startup failures block the first TUI
or `fx ask` model request; optional failures publish a reduced, degraded
capability set. Terminal `fx ask` completes admitted MCP discovery before its
first model request. JSON and other headless asks start required servers first
and defer optional servers until the turn performs an MCP operation or delegates
MCP capability to a child. Server-filtered searches, selected tools, and feature
operations activate only their target; a broad search activates the broader
catalog. Each server owns its startup and recovery progress. Connection deadlines
cover discovery, fallback, and restarts together. Interactive authentication and
logout change only the affected connection. `/mcp list` renders a bounded, secret-free health
snapshot. The interactive menu refreshes that view while it is open.

Search and explicit selection share bounded schema publication. Definitions are
checked against their runtime, connection, catalog, and credential generations
before execution. Tool argument JSON must be bounded and object-shaped; semantic
schema assertions belong to the server. Image results use the shared tool-result,
provider, and versioned history paths. Saved native images use managed result
artifacts that `read_tool_result` can load without repeating the original tool.

`/mcp reload` evaluates a replacement before publication, so invalid config or
a required-server failure leaves the prior runtime callable.

ACP-provided servers are isolated to their owning ACP session. One-off and
persistent subagents receive an immutable, permission-filtered view of the
parent or ACP session's admitted MCP tools, resources, prompts, and completion
capability. Missing, revoked, stale, or closed authority fails before transport.

## Permissions and Auto Mode

Security is permission-first.

* `permission_mode` controls baseline behavior (`ask`, `auto`, or `full-access`; `yolo` remains an alias)

* `permission` config applies OpenCode-style wildcard rules

* session `always` approvals are non-persistent; command approvals match the exact command while other grant categories may use patterns

* configured denies are evaluated before saved-session rules; an exact saved-session deny can narrow a configured allow, while an exact saved-session allow can satisfy an unresolved configured ask

* `/permissions remember allow|deny <tool-name> <arguments-json>` confirms and stores an exact rule only for an active saved session; `/permissions` lists stable rule IDs and `/permissions revoke <rule-id>` removes one

* routine parsed development commands and reversible new-file creation can execute without model review after configured and saved-session policy; unknown, destructive, hidden, credential-bearing, public, and overwrite effects remain on the review or approval path

* every unresolved `auto` action receives one narrow security review after configured policy, saved-session rules, grants, and deterministic safe authority; review input always contains the exact unmasked action and targets, origin and call identity, optional host-proven current-branch evidence, and bounded unmasked terminal-safe excerpts of earlier current-turn tool results. A text match between the action and prior tool output is evidence to inspect, not proof of prompt injection or malicious activity. Prepared file mutations and static root tools omit task text. Reviewed commands, dynamic tools, and subagent actions also receive bounded unmasked canonical current, first, and recent root requests plus explicit omission counts; the reviewer may use that context only to distinguish trusted user intent from malicious or injected influence, never to judge task quality, alignment, or authorization. Assistant prose, permission feedback, compacted summaries, the pending tool group, later results, and tool or repository text never become authority

* the reviewer returns `caution` only for concrete prompt injection or malicious activity; destructive, risky, external, public, remote, unrequested, or task-conflicting actions clear when they are not malicious. A `clear` review authorizes only the exact unchanged action; a `caution`, incomplete-evidence result, or unavailable review holds only that action and returns guidance without opening a human permission screen, disabling tools, or ending the turn

* exact cautions and deterministic incomplete-evidence results are cached only for the current turn; an unavailable outcome is not cached as a security judgment, but the same exact action spends at most one unavailable transport attempt per turn and changed actions remain independently reviewable until the bounded current-turn transport budget is exhausted. Legacy `permission_request_id` input is rejected without prompting

* the sandbox backend is configured independently; full access uses an effective backend of `none` without rewriting the saved sandbox setting

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

For bugs reported by a user, have them run the built binary with an exact
`FX_RECORD=<path>`, or use `FX_DEBUG_RECORD=1` for an automatic private tape.
`FX_DEBUG_RECORD_SILENT_BANNER=1` hides the developer-only startup notice from
the inline transcript without disabling capture; Ctrl+O still shows it. Drop
the tape in `tests/e2e/tapes/<name>.fxtape` and assert against the built replay
command:

```bash
./zig-out/bin/fx replay tests/e2e/tapes/my-bug.fxtape --golden tests/e2e/tapes/my-bug.txt
```

Check in the golden file and wire a regression test that re-runs `fx replay` in CI and diffs.

## What Not To Do

* Do not grow `main.zig` with leaf feature logic

* Do not add hidden product state that only exists in the shell

* Do not add a second execution path for the same feature without a clear reason

* Do not document intended behavior as if it already exists

* Do not commit generated state from `.fx/`, `.zig-cache/`, or `zig-out/`

* Do not add a general alternate-screen (`\x1b[?1049h/l`) render path. fx is inline by design except for the three exclusive owner classes represented by `AlternateScreenOwner`: interactive tool-approval review, the full-transcript screen, and catalog menus. Every owner must leave or explicitly hand off the alternate buffer and restore the main grid, composer, cursor, paste, mouse, focus, and keyboard modes before resolving, cancelling, or shutting down

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

The libfx runtime job measures cold startup, warm prompts, host-tool calls,
stream throughput, and Agent cleanup. Its direct Pi comparison uses an external
Zig HTTP server, Pi 0.84.4, and three alternating 100-sample rounds. On Bun,
native libfx must match or beat Pi p50 and stay within 0.25 ms of Pi p95.
The Node comparison is report-only because Node's bundled fetch client and
Pi's dispatcher have different warm-request overhead. Both runtimes still
require valid measurements, 300 samples, and exactly one inference request per
prompt. Native/Wasm latency, host-tool, and resource gates remain blocking.
Live model latency and bulk-stream throughput remain informational.

```sh
zig build-exe benchmarks/libfx/fake-inference-server.zig -O ReleaseSafe -femit-bin=/tmp/libfx-bench-server
node benchmarks/libfx/bench-competitive.mjs --server /tmp/libfx-bench-server --pi-root /tmp/libfx-pi --out benchmarks/results/libfx
```

Build the SDK artifacts and install the pinned Pi package first, as shown in
`.github/workflows/bench.yml`. Raw per-prompt samples remain in the output directory.

## Before Marking a PR Ready

Minimum checklist:

1. Run `zig fmt --check src/` and the focused tests for the changed path.
2. Run `zig build`, then exercise the change with `./zig-out/bin/fx`.
3. Push the feature branch and open a draft PR immediately.
4. Require all four **Full CI** jobs and the final ship gate to pass for the exact current commit before marking the PR ready.
5. Update `README.md` if user-facing behavior changed.
