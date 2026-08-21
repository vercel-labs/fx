# AGENTS.md

Instructions for AI coding agents working with this codebase.

## Declaring Work Ready

Do not say the work is "ready", "done", "good to go", "complete", or similar until you have personally run the binary and exercised the change on its happy path. A passing test suite is necessary, not sufficient — tests in this repo do not always construct the full runtime, attach a TTY, or spawn background threads, so they will not catch startup crashes, render regressions, or thread-lifetime bugs.

Before reporting the work as ready:

1. Build succeeds.
2. Focused tests for the changed path pass locally.
3. The **Full CI** run for the exact current commit passes on every required Linux and macOS runner.
4. Run the built binary locally and drive at least one real interaction that exercises the change end to end.
5. Confirm the process did not abort, stderr is clean, and the behavior matches what you are about to tell the user.

If you cannot run the binary in your environment, say so explicitly and ask the user to verify. Do not silently skip this step and declare the work ready. "The tests pass" is not a substitute for running the app.

### Always use the built binary in this repo

When running fx for verification, **always use the freshly-built binary at** **`./zig-out/bin/fx`** from this checkout. Never run `fx` from `PATH`, never rely on whatever is at `~/.fx/bin/fx`, and never assume an installed copy reflects your change.

* The user may have an older `fx` on their PATH (e.g. installed via `fx upgrade` or the CDN install script). Running that one will not exercise your edits.

* `zig build` writes to `zig-out/bin/fx`. That is the only binary that contains your latest change.

* When a user reports "still not working" after you believe you fixed something, do not assume they are running the wrong binary. Assume your fix is incomplete and investigate further. If you genuinely suspect a PATH mismatch, ask — do not silently copy binaries into `~/.fx/bin/`.

* In any shell invocation — tmux, direct run, scripts — reference fx as `/Users/<you>/path/to/repo/zig-out/bin/fx` (absolute) or `./zig-out/bin/fx` (when cwd is the repo root). Bare `fx` is always wrong for dev verification.

## Language and Toolchain

This project is written in **Zig 0.16+**. There is no Node.js runtime, no `package.json` at the root, and no JavaScript build step for the main binary.

Build and test commands:

```bash
zig build          # build the binary
zig build test     # run all unit tests
zig build run      # build and run
zig fmt src/       # format all source files
```

The test suites under `tests/` use Bun but are separate from the Zig codebase. See **Testing** below.

## Code Style

* Format all Zig source with `zig fmt` before committing. The canonical check is `zig fmt src/`.

* Do not use emojis in code, output, or documentation. Unicode symbols (e.g. checkmark, arrow) are acceptable.

* In documentation, never use double hyphens (`--`) as a dash. Use an emdash (—) sparingly, or rewrite to avoid dashes.

* CLI flags use kebab-case (e.g. `--no-save`, `--json`). Never use camelCase for flags.

* Prefer `snake_case` for all Zig identifiers. Types use `PascalCase` per Zig convention.

* Keep `pub` surface area minimal. Only mark declarations `pub` when they are used outside the file.

## Architecture

Key rules:

* `src/main.zig` is the composition root. Do not add leaf feature logic here.

* `src/core/` owns contracts, runtimes, config, sessions, permissions, MCP, skills.

* `src/tools/` owns built-in tool implementations. Generic tool contracts and dispatch live in `src/core/tooling/`. Default tool specs are centralized in `src/core/tooling/tool_specs.zig` or `src/builtins/tools.zig`, not in individual tool files.

* `src/ui/` owns terminal rendering, event loop, input, transcript. It must not own product state.

* `src/gateway/` owns provider transport. It must not absorb product-state logic.

* `src/acp/` owns the ACP (Agent Client Protocol) JSON-RPC 2.0 server.

### Adding a Feature

Before implementing, answer in order:

1. Which module owns the behavior?
2. What is the typed contract?
3. Does it need persistence?
4. Does it need both text and JSON output?
5. What docs and tests land with it?
6. How is its deterministic E2E owner classified in the macOS arm64 PGSO corpus?

If unclear, define the contract first.

Every root `tests/e2e/*.test.ts` file must have exactly one classification in
`scripts/pgso/corpus.json`:

* **Training:** common or performance-sensitive product behavior that should
  influence LLVM's hot and cold decisions

* **Verification-only:** important correctness, recovery, security, or rare
  behavior that the final candidate must pass without making it hot

* **Intentional exclusion:** nondeterministic, live-network, credentialed,
  sound-related, or harness-only coverage, with a concrete reason

New tests inside an already classified file inherit that file's classification,
but feature work must reconsider whether the existing classification still
matches the file's product role. When removing a feature or E2E owner, remove
its stale corpus entry. Normal PR CI loads the corpus and rejects missing,
duplicate, stale, or unclassified files without running the expensive PGSO
qualification.

### Adding a Command

1. Add the spec to `src/core/slash_commands/command_specs.zig`
2. Add dispatch wiring in `src/core/cli/cli_surface.zig`
3. Add a snapshot type if it has structured output
4. Render text and JSON from the same snapshot via `src/core/output/output_contracts.zig`

Do not scatter help text or argument parsing across multiple files.

## Configuration and State

Profile configuration and runtime state lives under `~/.fx/`. Project `.fx.json` contains committed project defaults only.

Config precedence (highest wins):

1. Environment variables such as `FX_MODEL`, `FX_PERMISSION_MODE`, and `FX_MAX_AGENT_STEPS`
2. `~/.fx/settings.json` → `workspaces["<workspace_path>"]` (profile workspace overrides)
3. `~/.fx/settings.json` top-level (profile global settings)
4. `<workspace>/.fx.json` (committed project defaults)
5. Built-in defaults

Project `.fx.json` accepts only repo-safe defaults: `sandbox`, `max_agent_steps`, `max_tool_result_bytes`, and `context`. Profile-owned keys such as `model`, `effort`, `fast_mode`, `slash_menu_categories`, `startup_scrollback`, `prompt_history`, `statusLine`, `skill_match_fuzzy`, `first_call_tool_choice`, `auto_upgrade`, `permission_mode`, `credential_source`, and `permission` are ignored from project config before their values are parsed.

Runtime state lives under `~/.fx/sessions/<session-id>/` (`session.json`, `background/`, `subagent/`, `logs/`). Sessions are global and portable across workspaces — each session tracks its `workspace_root` which updates when resumed in a different workspace. A subagent child is an ordinary session with its own directory; `subagent/` holds create-operation identities on a parent and the control record on a child.

## Permissions

Security is permission-first. All sensitive tool behavior must integrate with `src/core/permissions/permissions.zig`.

* `permission_mode` controls baseline (`ask`, `auto`, or `yolo`). Yolo bypasses Fx permission policy and uses an effective sandbox of `none` without rewriting saved sandbox configuration

* Configured denies are evaluated before saved-session rules; an exact saved-session deny can narrow a configured allow, while an exact saved-session allow can satisfy an unresolved configured ask

* Session `always` approvals are non-persistent; command approvals match the exact command while other grant categories may use patterns

* `/permissions remember allow|deny <tool-name> <arguments-json>` confirms and stores an exact rule only for an active saved session; list and revoke those rules by their stable IDs

* An `auto_denied` result may carry an opaque approval request ID. Only `ask_user_question` with that exact current-turn ID may enter the real permission screen; generic model or user text never authorizes the action, and execution still requires exact live revalidation

Do not bypass the permission system for new tools.

## Zig-Specific Patterns

### Memory

* Allocators are passed explicitly. Never use a global allocator.

* Free what you allocate. Use `defer` for cleanup at the call site.

* Prefer `ArenaAllocator` for request-scoped work that can be freed in bulk.

* When a function returns allocated memory, document who owns it (caller or callee).

### Error Handling

* Return errors rather than panicking. `@panic` is for programmer bugs, not runtime conditions.

* Use `errdefer` to clean up partial state on error paths.

* Prefer specific error sets over `anyerror` when the set is bounded.

### Strings and JSON

* Zig strings are `[]const u8`. There is no implicit null termination.

* For JSON serialization, use `std.json.Stringify.value` with an allocating writer (`std.Io.Writer.Allocating`).

* For JSON string escaping (writing raw JSON), use the project's `writeJsonStr` helper in `src/acp/jsonrpc.zig` rather than assuming `std.json.encodeJsonString` exists.

* Zig 0.16 uses `std.Io.File.stdin()` / `.stdout()` / `.stderr()`, not `std.io.getStdIn()`.

### I/O (Zig 0.16 "Juicy Main")

* `main` uses `pub fn main(init: std.process.Init) !void` signature.

* All I/O goes through `std.Io`, passed explicitly or via the project's `src/core/shared/io.zig` helper (`io_mod.getIo()`).

* File operations use `std.Io.Dir` and `std.Io.File` (not `std.fs`). Most methods require an `io` parameter.

* Environment variables: use `io_mod.getenv(key)` (returns `?[]const u8`), not `std.process.getEnvVarOwned`.

* Time: use `io_mod.milliTimestamp()`, `io_mod.nanoTimestamp()`, `io_mod.sleep(ns)`.

* File reading: use `io_mod.readFileToEnd(alloc, &file, max_bytes)`.

* Realpath: use `io_mod.realpathAlloc(alloc, path)` or `io_mod.dirRealpathAlloc(alloc, dir, sub_path)`.

* Process spawning: use `std.process.spawn(io, opts)` and `std.process.run(alloc, io, opts)`.

* Mutexes: `std.Io.Mutex`, initialized with `.init`, locked with `.lockUncancelable(io)`.

* HTTP: `std.http.Client` requires `.io = io_mod.getIo()` in its initializer.

* `std.mem` renames: `trimLeft` is `trimStart`, `trimRight` is `trimEnd`, `indexOf` is `find`, `indexOfScalar` is `findScalar`.

* `ArrayList(T)` initializes with `.empty` (not `.{}`).

### Testing

* Zig unit tests go inside the source file they test, using `test "description" { ... }` blocks.

* Run the narrowest relevant tests while developing. The complete `zig build test` suite runs in ReleaseSafe in **Full CI** after the feature branch is pushed, and it must pass before the draft PR is marked ready.

* Use `std.testing.expect`, `std.testing.expectEqual`, `std.testing.expectEqualStrings` for assertions.

* In test blocks, use `std.testing.io` for the `Io` parameter. `io_mod.getIo()` automatically returns `std.testing.io` in test builds.

* Use `io_mod.dirRealpathAlloc(alloc, dir, sub_path)` to resolve paths within `std.testing.tmpDir()`.

## Testing (TypeScript)

Two test suites live under `tests/`, both using Bun:

### `tests/evals/` — LLM Evals

Eval scenarios that exercise the agent through `fx ask --json`. Require `AI_GATEWAY_API_KEY`.

```bash
cd tests/evals && bun install && bun test           # run all evals
cd tests/evals && bun run eval:matrix               # cross-model matrix run
```

### `tests/e2e/` — End-to-End Tests

Deterministic runtime tests (CLI commands, ACP protocol, TUI via tmux). No API key needed for most.

```bash
cd tests/e2e && bun install && bun test              # run all e2e tests
cd tests/e2e && bun test cli.test.ts                 # just CLI tests
cd tests/e2e && bun test acp.test.ts                 # just ACP tests
cd tests/e2e && bun test tui-*.test.ts               # just TUI tests (requires tmux)
```

TUI tests use tmux to drive the interactive terminal. They require `tmux` to be installed.

## Pull Request Classification

Every pull request must have exactly one `type:` label, chosen by its primary intent:

* `type: bug`: fixes incorrect behavior

* `type: feature`: adds a new user-facing capability

* `type: improvement`: improves existing user-facing behavior

* `type: docs`: changes documentation only

* `type: maintenance`: changes internal tooling, dependencies, CI, or implementation structure without a user-facing behavior change

* `type: release`: prepares or repairs a release

* `type: security`: fixes or hardens a security boundary

Assign the label when the PR is opened and keep it accurate when the PR changes. If the authenticated contributor cannot manage labels, state the required label and keep the PR in draft until a maintainer or repository agent applies it. For a mixed PR, choose the label that describes the primary reason the PR exists. If that is ambiguous, ask before applying or changing the label.

Keep PR titles as clean imperative sentences, such as `Restore feedback report file clipboard`. Do not add bracketed prefixes such as `[bug]`, `[feature]`, or `[improvement]`. Type belongs in the label, not the title.

## Full CI on Feature Branches

Do not run the complete deterministic test suite locally as the default development loop. Run the focused test for the changed path, build the binary, and exercise that path with `./zig-out/bin/fx`.

After the focused checks pass, create a clean checkpoint commit, push the non-`main` feature branch, and open a draft PR immediately. `.github/workflows/full-ci.yml` runs the following on all four supported native runner architectures:

* `ubuntu-24.04` (x86_64)
* `ubuntu-24.04-arm` (aarch64)
* `macos-15-intel` (x86_64)
* `macos-15` (aarch64)

The native matrix builds, tests, and smoke-tests ReleaseSafe on every platform; formatting and the public-surface audit run in those ReleaseSafe jobs. The E2E matrix runs four duration-balanced, isolated ReleaseSafe shards per platform with Bun and tmux. Checked-in weights assign every test file to exactly one shard on each platform, and files inside each shard run sequentially in separate Bun processes so terminal fixtures and process state cannot leak between files. A failed file receives one bounded retry after its tmux server is reset. Live model evals remain separate because they require credentials and are not deterministic.

A Full CI result is valid only when it belongs to the exact current commit and all four `Full suite (...)` jobs succeed. Each platform aggregate requires its ReleaseSafe native check plus all four ReleaseSafe E2E shards. Do not mark the draft PR ready or request review from a stale, partial, queued, cancelled, skipped, or failed run. If Full CI fails, make the smallest repair, rerun the focused local proof, push the new commit to the same draft PR, and wait for Full CI on the new exact commit. After CI passes, run the final ship gate and mark the PR ready only when it reports `SHIP` for that exact commit.

## Reproducing Render Bugs

fx's rendering is inline by default and deliberately emits a small ANSI subset. Five owner classes are the narrow exceptions, and each takes the alternate buffer exclusively through `AlternateScreenOwner` in `src/ui/shell_runtime.zig`: interactive permission review, the full-transcript screen, catalog menus, the ctrl+x subagent manager, and a hosted child-terminal takeover. The terminal-session owner is entered only by an explicit manager handoff after the host grants the human write lease; it renders the shared terminal-engine grid without permanent Fx chrome and releases that lease on detach. Only one class may own the buffer at a time, and each must leave it and restore the main grid, composer, cursor, paste, mouse, focus, and keyboard modes when it closes. Transcript rendering, question prompts, and command-output expansion remain inline. Three tools exist for reproducing and regression-proofing render bugs:

### tmux (live TTY repros)

Best for resize and SIGWINCH interactions. The helper in `tests/e2e/tmux-helpers.ts` exposes `resizeWindow(cols, rows)`, `capturePaneGrid()`, and `capturePaneEscapes()`. See `tests/e2e/tui-resize.test.ts` for the canonical resize matrix.

```bash
cd tests/e2e && bun test tui-resize.test.ts
```

### FX\_RECORD + fx replay (capture-and-replay)

Run fx with `FX_RECORD=<path>` to dump every byte fx writes, every resize, and every Ctrl+C into a framed binary tape. Replay the tape through the built-in virtual terminal:

```bash
FX_RECORD=/tmp/bug.fxtape fx        # user reproduces the glitch
fx replay /tmp/bug.fxtape           # print the final cell grid
fx replay /tmp/bug.fxtape --frames  # scrub through every intermediate frame
fx replay /tmp/bug.fxtape --json    # structured frame metadata + grid
fx replay /tmp/bug.fxtape --golden out.txt   # write grid to a file
```

The tape is deterministic — any reviewer can replay it without a TTY, and a golden file can be checked in as a regression test.

### Shared terminal engine (sub-second unit tests)

`src/core/terminal/engine.zig` is the shared bounded text-terminal engine for hosted terminal sessions, recovery, replay, and deterministic rendering tests. `src/ui/resize_tests.zig` drives `TranscriptRuntime` against it in process so resize behavior can be exercised with no fd or timing dependence.

```bash
zig build test                      # runs every VT and resize test
```

When a tmux or tape-based scenario exposes a bug, reproduce it as a Zig unit test in `resize_tests.zig` (or a new sibling) before fixing. The test lands the fix as a regression.

## Benchmarks

Startup latency benchmarks live in `benchmarks/` and run in CI via `.github/workflows/bench.yml`.

```bash
./benchmarks/startup.sh            # full run (100 iterations, builds ReleaseSafe, needs hyperfine)
./benchmarks/startup.sh --quick    # quick run (20 iterations)
```

The CI workflow builds a ReleaseSafe binary, measures six CLI paths with hyperfine, and enforces per-command latency budgets. PRs that exceed a budget fail the check. On `main`, results are uploaded to Vercel Blob for historical tracking.

The startup benchmark uses `FX_BENCH=1`, an environment variable that runs through arg parsing and CLI dispatch, then exits before TTY initialization. This lives in `src/core/app/app_entry_runtime.zig`.

Current raw wall-clock contract:

* Linux CI: 2ms for every command
* Non-Linux local runs: informational raw means

The Linux CI runner is the authoritative product budget. Local macOS process
and dynamic-loader floors vary enough to exceed 2ms independently of Fx, so
local runs report raw means without assigning a substitute product budget. The
process baseline is diagnostic only and is never subtracted.

When adding features, consider their impact on startup latency. The `fx help` path is the baseline cold-start benchmark.

## Binary Size Observability

Every pull request runs `.github/workflows/binary-size.yml` across Linux x86_64,
Linux arm64, macOS x86_64, and macOS arm64. Each matrix job builds the pull
request merge commit and its base commit as stripped ReleaseSafe binaries on
the same native runner, then reports the exact byte and MiB delta plus ELF or
Mach-O section changes.

Each platform check is informational. An increase of at least 52,429 bytes
(0.050000 MiB) emits a warning and retains that platform's binaries for
investigation, but does not reject the pull request. Investigate notable
unexplained growth before changing the threshold. The full macOS arm64 PGSO
release qualification remains authoritative for the 7.800 MiB production
ceiling and performance gates.

## Documentation

When adding or changing user-facing features, update **all** relevant files:

1. `--help` output via command specs in `src/core/slash_commands/command_specs.zig`
2. `README.md` — feature descriptions, usage examples
3. `CONTRIBUTING.md` — if build steps, config, or collaboration rules change

Do not document intended behavior as if it already exists.

## Releasing

Releases use a two-workflow pipeline. The maintainer controls the changelog voice and format.

### Automated flow (preferred)

1. Go to **Actions > Prepare Release** on GitHub
2. Select the bump type (`patch`, `minor`, or `major`) and run the workflow
3. The workflow bumps the version, feeds the actual `git diff` to an LLM to draft the changelog, and opens a PR
4. Review the PR — edit the AI-drafted changelog if needed — then merge
5. The existing `release.yml` detects the version change and handles build, publish, tagging, and the GitHub Release

The `prepare-release.yml` workflow uses the Vercel AI Gateway (`AI_GATEWAY_API_KEY` secret) to generate the changelog from the real code diff, not from commit messages or PR descriptions.

### Manual flow

To prepare a release by hand:

1. Create a branch (e.g. `prepare-v0.3.0`)
2. Bump `pub const version` in `src/main.zig`
3. Write the changelog entry in `CHANGELOG.md` at the top, under a new `## <version>` heading, wrapped in `<!-- release:start -->` and `<!-- release:end -->` markers. Remove the markers from the previous release entry so only the new release has them.
4. Update `README.md` install example version
5. Open a PR and merge to `main`

When the PR merges, CI compares the version tag to what exists in git. If the tag is missing, it cross-compiles all platform binaries, creates the git tag, and publishes a GitHub Release with the binaries attached. The release body is extracted from the content between the `<!-- release:start -->` and `<!-- release:end -->` markers in `CHANGELOG.md`.

### Writing the changelog

Whether automated or manual, the changelog is public product copy. Describe observable user behavior, not the engineering process behind it. Use the diff, commits, and merged pull requests as research evidence only.

Public changelog entries must:

* Spell the product name `fx`. Preserve different casing only when it is part of an exact code identifier such as `FX_MODEL`.
* Use `### New Features` only when the diff proves users can do something that was not possible at the previous release. Rewritten, moved, exposed, hardened, or extended existing behavior is not automatically new.
* Compare proposed notes with the previous release's changelog and README. Do not announce an existing capability as new; when the current diff improves or fixes it, describe only that new user-visible delta.
* Use only relevant sections from `### Breaking Changes`, `### New Features`, `### Improvements`, `### Bug Fixes`, and `### Security`. Omit empty sections.
* Bold a short feature or fix name, then describe the user-visible change after a colon.
* Omit pull request numbers, issue numbers, commit hashes, contributor names, and author attribution.
* Omit internal details such as repository moves, website or marketing work, CDN layout, CI workflows, test fixtures, branch history, and implementation-only refactors. Translate relevant work into its public user outcome or leave it out.
* Avoid forcing every merged change into the notes. A change without a public user outcome does not need a bullet.

Only the current release should have markers; remove `<!-- release:start -->` and `<!-- release:end -->` from any previous entry:

```markdown
## 0.3.0

<!-- release:start -->
### New Features

- **Interactive terminal startup:** Start an interactive shell when the `terminal` tool receives an empty command
<!-- release:end -->

## 0.2.5

### Improvements

- **Inline rendering:** Keep the active conversation visible in terminal scrollback
```

Do not add a `### Contributors` section or tracker references. Use descriptive section names.

Do not create version tags manually. Do not change `build.zig.zon` version (it is a placeholder).

## Repository and License

The canonical repository is `vercel-labs/fx` on GitHub. All URLs, links, and references to the repo must use `vercel-labs/fx` (not `vercel/fx`, `user/fx`, or any other org/owner). Licensed under Apache-2.0.

## What Not To Do

* Do not grow `main.zig` with leaf feature logic

* Do not add hidden product state that only exists in the live shell

* Do not add a second execution path for the same feature without a clear reason

* Do not commit generated state from `.fx/`, `.zig-cache/`, or `zig-out/`

* Do not add dependencies outside the Zig standard library without discussion

* Do not use `@import` with runtime-computed paths — Zig imports are comptime only

* Do not ignore `zig fmt` failures

* Do not create git tags manually (the release workflow owns tag creation)

* Do not report work as ready without running the binary. See **Declaring Work Ready**.

## Before Marking a PR Ready

1. Run `zig fmt --check src/` and the focused tests for the changed path.
2. Build and exercise the change locally with `./zig-out/bin/fx`.
3. Push a clean checkpoint commit and open a draft PR immediately.
4. Require **Full CI** and the final ship gate to pass on the exact current commit across all four native runners.
5. Update docs if behavior changed.
