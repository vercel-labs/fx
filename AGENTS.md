# AGENTS.md

Instructions for AI coding agents working with this codebase.

## Declaring Work Ready

Do not say the work is "ready", "done", "good to go", "complete", or similar until you have personally run the binary and exercised the change on its happy path. A passing test suite is necessary, not sufficient — tests in this repo do not always construct the full runtime, attach a TTY, or spawn background threads, so they will not catch startup crashes, render regressions, or thread-lifetime bugs.

Before reporting the work as ready:

1. Build succeeds.
2. Focused tests for the changed path pass locally.
3. **CI** passes for the exact current commit, including the **macOS arm64** check. See **CI on Pull Requests**.
4. Run the built binary locally and drive at least one real interaction that exercises the change end to end.
5. Confirm the process did not abort, stderr is clean, and the behavior matches what you are about to tell the user.

If you cannot run the binary in your environment, say so explicitly and ask the user to verify. Do not silently skip this step and declare the work ready. "The tests pass" is not a substitute for running the app.

### Always use the built binary in this repo

When running fx for verification, **always use the freshly-built binary at** **`./zig-out/bin/fx`** from this checkout. Never run `fx` from `PATH`, never rely on the installed copy at `~/.local/bin/fx`, and never assume an installed copy reflects your change.

* The user may have an older `fx` on their PATH (e.g. installed via `fx upgrade` or the install script). Running that one will not exercise your edits.

* When a user reports "still not working" after you believe you fixed something, do not assume they are running the wrong binary. Assume your fix is incomplete and investigate further. If you genuinely suspect a PATH mismatch, ask — do not silently copy binaries onto their `PATH`.

* In any shell invocation — tmux, direct run, scripts — reference fx as `/Users/<you>/path/to/repo/zig-out/bin/fx` (absolute) or `./zig-out/bin/fx` (when cwd is the repo root). Bare `fx` is always wrong for dev verification.

## Language and Toolchain

This project is written in **Zig 0.17+**. There is no Node.js runtime, no `package.json` at the root, and no JavaScript build step for the main binary.

Build and test commands:

```bash
zig build              # build the binary
zig build test         # run all unit tests
zig build run          # build and run
zig fmt src/           # format all source files
zig fmt --check src/   # the formatting check CI runs
```

The test suites under `tests/` use Bun but are separate from the Zig codebase. `tests/tla/` holds the TLA+ models. See **Testing** and **TLA+ Models** below.

## Code Style

* Format all Zig source with `zig fmt src/` before committing.

* Do not use emojis in code, output, or documentation. Unicode symbols (e.g. checkmark, arrow) are acceptable.

* In documentation, never use double hyphens (`--`) as a dash. Use an emdash (—) sparingly, or rewrite to avoid dashes.

* Use the `technical-writer` skill (`.fx/skills/technical-writer/SKILL.md`) when you write or edit prose, including documentation, commit messages, PR titles and descriptions, and issues. Where the skill and this section differ, such as on em dashes, this section takes precedence.

* CLI flags use kebab-case (e.g. `--no-save`, `--json`). Never use camelCase for flags.

* Follow Zig naming: `camelCase` for functions, `snake_case` for variables, fields, and file names, and `PascalCase` for types.

* Keep `pub` surface area minimal. Only mark declarations `pub` when they are used outside the file.

* Never commit personal home-directory paths, real team IDs, internal team slugs, or personal project slugs. `scripts/check-public-surface.sh` rejects them in CI. Use `/Users/example/` in fixtures.

## Architecture

Key rules:

* `src/main.zig` is the composition root. Do not add leaf feature logic here.

* `src/core/` owns contracts, runtimes, config, sessions, permissions, MCP, skills.

* `src/core/compactor/` owns context compaction. Outside code imports only its front door, `compactor.zig`, and the compactor imports only shared basics and model configuration; its caller hands in the model caller, the record store, and the session's projection of saved turns into chat messages. `scripts/check-compactor-boundary.sh` enforces this in CI.

* `src/core/indexer/` is the native workspace indexer. It reads git's ignore rules, repository layout, and git config as data and never starts a process, so a repository's configuration cannot make it run a program. Outside code imports only its front door, `indexer.zig`, and the indexer imports only the standard library, its own files, `io.zig`, and `debug_trace.zig`. `@`-completion, `glob_files`, and `grep_files` list files only through it and never start a process. `scripts/check-indexer-boundary.sh` enforces this in CI.

* `src/core/recovery/` decides how one model request recovers: when to retry, how long to wait, when to try another way, what the status line says, and what to save so the request survives a closed window or a crash. fx reports events to `step` and carries out the plan it returns. The module performs no I/O, reads no clock, and never allocates. Outside code imports only its front door, `recovery.zig`, and the module imports only the standard library. `tests/tla/recovery/Recovery.tla` models it, and `scripts/check-recovery-boundary.sh` enforces the boundary in CI.

* `src/core/shell_command/safe_git.zig` runs git for the `fx pr` and `fx issue` snapshot and for the agent's direct read-only `git status`, `git diff`, and `git log` when the command does not use the user's own shell environment. It turns off every program a repository's own config can name and refuses to run when git would use a different repository than the one fx read. In `auto` mode a git command it refuses is returned to the agent without running. Commands that run in a shell use git with the repository's full config: git in the shell tool's default `user` environment, and the routine commands `auto` mode runs without review, such as `git status` with other flags, `git fetch`, or `npm test`.

* `src/mcp/` is the MCP-v2 engine. `FX_MCP_ENGINE=v2` selects it in place of the default v1 client in `src/core/mcp/`. Its files import only `std` and each other, and the host passes in `std.Io` and every other service through `src/mcp/host.zig`. fx connects to it through `src/core/mcp_host/`.

* `src/tools/` owns built-in tool implementations. Generic tool contracts and dispatch live in `src/core/tooling/`. Default tool specs are centralized in `src/core/tooling/tool_specs.zig` or `src/builtins/tools.zig`, not in individual tool files.

* `src/ui/` owns terminal rendering, event loop, input, transcript. It must not own product state.

* `src/gateway/` owns provider transport. It must not absorb product-state logic.

* `src/acp/` owns the ACP (Agent Client Protocol) JSON-RPC 2.0 server.

* `src/wasm_core_main.zig`, `src/wasm_term_main.zig`, and `src/napi_core_main.zig` are the libfx SDK entry points. Read `sdk/AGENTS.md` before changing them or anything under `sdk/`.

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

Every root E2E file also needs a weight in `tests/e2e/ci-shard-weights.json`.
CI fails on a missing or stale entry.

### Adding a Command

1. Add the command kind in `src/core/slash_commands/command_specs.zig` and its spec, including usage, summary, and options, in `src/builtins/commands.zig`
2. Add dispatch wiring in `src/core/cli/cli_surface.zig`
3. Add a snapshot type if it has structured output
4. Render text and JSON from the same snapshot via `src/core/output/output_contracts.zig`

Do not scatter help text or argument parsing across multiple files.

## Configuration and State

Profile configuration and runtime state lives under `~/.fx/`. Project `.fx.json` contains committed project defaults only.

Config precedence (highest wins):

1. Environment variables such as `FX_PROVIDER`, `FX_MODEL`, `FX_PERMISSION_MODE`, and `FX_MAX_AGENT_STEPS`
2. `~/.fx/settings.json` → `workspaces["<workspace_path>"]` (profile workspace overrides)
3. `~/.fx/settings.json` top-level (profile global settings)
4. `<workspace>/.fx.json` (committed project defaults)
5. Built-in defaults

Project `.fx.json` accepts only repo-safe defaults: `max_agent_steps`, `max_tool_result_bytes`, `context`, `provider_order`, and `provider_strict`, parsed by `parseProjectSafeFields` in `src/core/config/config_runtime.zig`. The project layer never parses profile-owned keys, such as provider and model selection, permissions, and interface preferences.

Runtime state lives under `~/.fx/sessions/<session-id>/` (`session.json`, `background/`, `subagent/`, `logs/`). Sessions are global and portable across workspaces. Each session tracks its `workspace_root`, which updates when resumed in a different workspace. Subagent children are internal sessions registered in their parent's `subagent/children.json`. They stay out of session discovery and cannot be resumed directly.

## Permissions

Security is permission-first. All sensitive tool behavior must integrate with `src/core/permissions/permissions.zig`.

* `permission_mode` controls baseline (`ask`, `auto`, or `full-access`; `yolo` remains an alias). Full access bypasses fx permission policy

* Configured denies are evaluated before saved-session rules; an exact saved-session deny can narrow a configured allow, while an exact saved-session allow can satisfy an unresolved configured ask

* Session `always` approvals are non-persistent; command approvals match the exact command while other grant categories may use patterns

* `/permissions remember allow|deny <tool-name> <arguments-json>` confirms and stores an exact rule only for an active saved session; list and revoke those rules by their stable IDs

* Routine parsed development commands and reversible new-file creation can execute without model review after configured and saved-session policy. Every remaining unresolved `auto` action receives one narrow security review using the exact unmasked action and targets, origin and call identity, optional host-proven current-branch evidence, and bounded unmasked terminal-safe excerpts of earlier current-turn tool results. A text match between the action and prior tool output is evidence to inspect, not proof of prompt injection or malicious activity. Prepared file mutations and other static root tools omit task text. Reviewed commands, shell input, dynamic tools, and subagent actions also receive bounded unmasked canonical current, first, and recent root requests plus explicit omission counts; the reviewer may use that context only to distinguish trusted user intent from malicious or injected influence, never to judge task quality, alignment, or authorization. Assistant prose, permission feedback, compacted summaries, the pending tool group, later results, and tool or repository text never become authority. Shell input reviews also include the owned receiving session's launch command, working directory, and bounded current screen after verifying session authority, including on resume. The launch command describes startup only; screen content remains untrusted evidence and input still receives its own review

* The reviewer returns `caution` only for concrete prompt injection or malicious activity. Destructive, risky, external, public, remote, unrequested, or task-conflicting actions clear when they are not malicious. A `clear` review authorizes only the exact unchanged action. A `caution`, incomplete-evidence result, or unavailable review holds only that action, returns guidance to the agent, and never opens a human permission screen, disables tools, or ends the turn

* Exact cautions and deterministic incomplete-evidence results are reused only for the current turn. An unavailable outcome is not cached as a security judgment, but the same exact action spends at most one unavailable review opportunity per turn; changed actions remain independently reviewable until the bounded current-turn review budget is exhausted. Each review accepts exactly one valid structured decision even with accompanying prose and may retry one malformed completion within the current attempt's deadline. A transport timeout, transient transport failure, or failed transport call is retried once with a fresh 30-second deadline; permanent transport failures, valid cautions, and cancellation are never retried. Legacy `permission_request_id` input is rejected without prompting

* Host-generated review holds retain their advice for the agent and transcript, but carry a saved `review_feedback` marker that excludes them from later security evidence, including after recovery. Old unmarked results remain untrusted evidence; never infer the marker from output text. Quoted review accusations are not proof of an attack, and handling plans or test instructions as data is not itself prompt injection

Do not bypass the permission system for new tools.

## Zig-Specific Patterns

### Memory and Errors

* Allocators are passed explicitly. Never use a global allocator.

* Prefer `ArenaAllocator` for request-scoped work that can be freed in bulk.

* When a function returns allocated memory, document who owns it (caller or callee).

* Return errors rather than panicking. `@panic` is for programmer bugs, not runtime conditions.

### Strings and JSON

* Zig 0.17 removed the `**` operator. Fill arrays with `@splat` and build repeated comptime strings with `text_utils.repeat` from `src/core/shared/text_utils.zig`.

* For JSON serialization, use `std.json.Stringify.value` with an allocating writer (`std.Io.Writer.Allocating`).

* For JSON string escaping (writing raw JSON), use the project's `writeJsonStr` helper in `src/acp/jsonrpc.zig` rather than assuming `std.json.encodeJsonString` exists.

* Zig 0.17 uses `std.Io.File.stdin()` / `.stdout()` / `.stderr()`, not `std.io.getStdIn()`.

### I/O ("Juicy Main")

* `main` uses `pub fn main(init: std.process.Init) !void` signature.

* All I/O goes through `std.Io`, passed explicitly or via the project's `src/core/shared/io.zig` helper (`io_mod.getIo()`).

* File operations use `std.Io.Dir` and `std.Io.File`. Most methods require an `io` parameter. Everything left in `std.fs` is deprecated: use `std.Io.Dir.path` for path manipulation and `std.Io.Dir.max_path_bytes` for path buffers.

* Environment variables: use `io_mod.getenv(key)` (returns `?[]const u8`), not `std.process.getEnvVarOwned`.

* Time: use `io_mod.milliTimestamp()`, `io_mod.nanoTimestamp()`, `io_mod.sleep(ns)`.

* File reading: use `io_mod.readFileToEnd(alloc, &file, max_bytes)`.

* Realpath: use `io_mod.realpathAlloc(alloc, path)` or `io_mod.dirRealpathAlloc(alloc, dir, sub_path)`.

* Process spawning: use `std.process.spawn(io, opts)` and `std.process.run(alloc, io, opts)`.

* Mutexes: `std.Io.Mutex`, initialized with `.init`, locked with `.lockUncancelable(io)`.

* HTTP: `std.http.Client` requires `.io = io_mod.getIo()` in its initializer.

* `ArrayList(T)` initializes with `.empty` (not `.{}`).

### Zig 0.17 Standard Library

fx does not use declarations that Zig 0.17 deprecates. They still compile, so check new code against this list:

* Format with `alloc.print(fmt, args)` and `std.mem.print(buf, fmt, args)`, not `std.fmt.allocPrint` or `std.fmt.bufPrint`.

* Search with the `std.mem.find` family (`find`, `findScalar`, `findAny`, `findLast`, `findScalarLast`, and their `Pos` variants), not `indexOf` or `lastIndexOf`. Trim with `trimStart` and `trimEnd`.

* Copy overlapping slices with `@memmove(dest, src)`, not `std.mem.copyForwards` or `copyBackwards`. Both slices must have the same length.

* Resolve paths with `std.Io.Dir.path.resolveAlloc` and `relativeAlloc`.

* Read the target from `builtin.target.os`, `builtin.target.cpu`, and `builtin.target.abi`, and the optimization mode from `builtin.optimize` (`.debug`, `.safe`, `.fast`, `.small`). Gate safety-only work on `builtin.optimize.runtimeSafety()`. Language types live in `std.lang`, not `std.builtin`.

* Use `std.ArrayList`, `std.array_hash_map.String` and `.Auto`, and `std.bit_set.Dynamic` and `.Static`, not the `Unmanaged` or `BitSet` aliases. Read the last list item with `last()`.

* Convert enums with `@backingInt` and `@fromBackingInt`. Divide rounding up with `@divCeil`.

* `@hasDecl` only finds `pub` declarations, so a declaration that a duck-typed caller probes for must be `pub`.

* Decode one UTF-8 sequence with `display_width.decodeUtf8Sequence` from `src/core/shared/display_width.zig`, not `std.unicode.utf8Decode`.

### Testing

* Zig unit tests go inside the source file they test, using `test "description" { ... }` blocks.

* Run the narrowest relevant tests while developing. The complete `zig build test` suite runs in ReleaseSafe in **CI** after the feature branch is pushed, and it must pass before the draft PR is marked ready.

* In test blocks, use `std.testing.io` for the `Io` parameter. `io_mod.getIo()` automatically returns `std.testing.io` in test builds.

* Use `io_mod.dirRealpathAlloc(alloc, dir, sub_path)` to resolve paths within `std.testing.tmpDir()`.

* Back `std.testing.checkAllAllocationFailures`, hand-written `FailingAllocator` sweeps, and allocation-count comparisons with `testing_allocator.no_resize` from `src/core/shared/testing_allocator.zig`. `std.testing.allocator` may grow an allocation in place on one run and not the next, which changes the allocation sequence and makes those tests flaky.

## Testing (TypeScript)

Two test suites live under `tests/`, both using Bun. `tests/AGENTS.md` says where each kind of test belongs, how to wire a new E2E file into CI, and how code comments cite tests and specs.

Set `FX_SOUND=0` when you run either suite locally, for example `cd tests/e2e && FX_SOUND=0 bun test cli.test.ts`. On macOS, sound playback during a test run can overload the machine and crash it. The variable doesn't cover `notifications.test.ts`, which clears it, or the "TUI user-profile output preserves compact scrollback across slash commands" test in `tui-command-permissions.test.ts`, which sends `/sound on`. Leave those to CI. On Linux, fx rings the terminal bell instead of playing a sound, so they run safely there. The full `bun test` run below includes both, and `bun test tui-*.test.ts` includes the `/sound on` test, so on macOS pass test files by name.

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

## TLA+ Models

Every TLA+ spec, its TLC checker, the Bun drivers that walk real code along a spec, and the session manager's design record live in `tests/tla/`, and nowhere else. `tests/AGENTS.md` describes the layout and how to add a model, and `tests/tla/README.md` lists the commands. Session decision numbers such as `D44` are defined in `tests/tla/session_manager/system-design.md`.

Code comments cite a spec by its repository-relative path and the property it checks, such as `tests/tla/session_manager/Wiring.tla` `ParentOutlivesChildren`, and never cite a file outside the repository. When a change alters behavior that a spec models, update the spec in the same change and run its checker.

## Pull Request Classification

Every pull request must have exactly one `type:` label before it merges, chosen by its primary intent:

* `type: bug`: fixes incorrect behavior

* `type: feature`: adds a new user-facing capability

* `type: improvement`: improves existing user-facing behavior

* `type: docs`: changes documentation only

* `type: maintenance`: changes internal tooling, dependencies, CI, or implementation structure without a user-facing behavior change

* `type: release`: prepares or repairs a release

* `type: security`: fixes or hardens a security boundary

If the authenticated contributor can manage labels on `vercel-labs/fx`, which takes triage access or higher, assign the label when the PR is opened and keep it accurate when the PR changes. For a mixed PR, choose the label that describes the primary reason the PR exists. If that is ambiguous, ask before applying or changing the label. Outside contributors cannot manage labels, so their pull requests do not need one when opened: a maintainer applies it during review. Do not hold an outside contributor's PR in draft for a missing label.

Keep PR titles as clean imperative sentences, such as `Restore feedback report file clipboard`. Do not add bracketed prefixes such as `[bug]`, `[feature]`, or `[improvement]`. Type belongs in the label, not the title.

## CI on Pull Requests

Do not run the complete deterministic test suite locally as the default development loop. Run the focused test for the changed path, build the binary, and exercise that path with `./zig-out/bin/fx`.

After the focused checks pass, create a clean checkpoint commit, push the non-`main` feature branch, and open a draft PR immediately. Linux is the gate for every change because most fx behavior is identical on every platform:

* `.github/workflows/ci.yml` runs on Linux x86_64. It checks formatting, the PGSO corpus, the public surface, and the compactor, indexer, and recovery boundaries, model-checks request recovery and walks the recovery module along its model, runs the ReleaseSafe unit tests, runs the E2E files in four weighted shards plus the MCP conformance baseline, and qualifies the SDK packages. A failed E2E file is retried once. A file that passes only on retry gets a warning annotation; investigate it as a possible race. `Build & Test` fails when any SDK job fails.
* `.github/workflows/binary-size.yml` builds each release target on its native runner, reports the size change, and smoke-tests every target's binary. See **Binary Size Observability**.
* `.github/workflows/bench.yml` enforces the startup latency budget. See **Benchmarks**.

Linux jobs install Zig through `.github/actions/setup-zig`, which restores the Zig cache that runs on `main` save with `.github/actions/save-zig-cache`. Pull requests never save a Zig cache through these actions, so they cannot push `main`'s entries out of the repository's cache quota. The PGSO workflow keeps its own cache through `.github/actions/setup-pgso`.

macOS runs only when `scripts/detect-macos-need.sh` finds a change that can behave differently there, such as a Zig file with a macOS, BSD, or Linux code path, `build.zig`, the macOS signing script, the native SDK addon, or a platform E2E file. If the detector cannot read the change, the `macOS arm64` check fails instead of passing. When the change does not need macOS, the check passes without starting a macOS runner. To request macOS for any other change, add the `ci:macos` label or run `gh workflow run macos.yml --ref <branch>`. The label needs triage access and the dispatch needs write access, so an outside contributor asks in the PR and a maintainer starts the run. Every E2E file that branches on `process.platform` or `platform()` being `darwin` or `linux` must appear in `tests/e2e/macos-platform-tests.json`, and `tests/e2e/ci-shards.test.ts` enforces that.

The macOS arm64 PGSO workflow runs on a pull request only when the PGSO pipeline changes: `scripts/pgso/` other than `corpus.json`, the `setup-pgso` action, or `.github/workflows/pgso-macos-arm64.yml`. To qualify any other change, run `gh workflow run pgso-macos-arm64.yml --ref <branch>`. The stable release always runs it.

Live model evals and the live ACP suite need credentials and are not deterministic, so they run only on request. Run the live ACP suite with `gh workflow run ci.yml --ref <branch> -f acp_live=true`.

A CI result is valid only when it belongs to the exact current commit and `Build & Test`, `E2E (deterministic)`, `Shellcheck`, `Startup Latency`, and `macOS arm64` all succeed. Do not mark the draft PR ready or request review from a stale, partial, queued, cancelled, skipped, or failed run. If CI fails, make the smallest repair, rerun the focused local proof, push the new commit to the same draft PR, and wait for CI on the new exact commit. After CI passes, run the final ship gate and mark the PR ready only when it reports `SHIP` for that exact commit.

## Reproducing Render Bugs

fx's rendering is inline by default and deliberately emits a small ANSI subset. Three owner classes are the narrow exceptions, and each takes the alternate buffer exclusively through `AlternateScreenOwner` in `src/ui/shell_runtime.zig`: interactive file-approval review, the full-transcript screen, and catalog menus. Only one class may own the buffer at a time, and each must leave it and restore the main grid, composer, cursor, paste, mouse, focus, and keyboard modes when it closes. Transcript rendering, question prompts, command-output expansion, and subagent delegation remain inline. Three tools exist for reproducing and regression-proofing render bugs:

### tmux (live TTY repros)

Best for resize and SIGWINCH interactions. The helper in `tests/e2e/tmux-helpers.ts` exposes `resizeWindow(cols, rows)`, `capturePaneGrid()`, and `capturePaneEscapes()`. See `tests/e2e/tui-resize.test.ts` for the canonical resize matrix.

```bash
cd tests/e2e && bun test tui-resize.test.ts
```

### Debug terminal recording and replay

Set `FX_DEBUG_RECORD=1` to create an automatic private tape under
`~/.fx/recordings/`. Set `FX_DEBUG_RECORD_SILENT_BANNER=1` as well when the
developer-only recording notice must stay out of the inline transcript during
a screen share. The notice remains available in the Ctrl+O full transcript.
Use `FX_RECORD=<path>` when a test or investigation needs an exact destination.
Recording dumps every byte fx writes and every resize into a framed binary tape.
Replay the tape through the built-in virtual terminal:

```bash
FX_DEBUG_RECORD=1 ./zig-out/bin/fx
FX_RECORD=/tmp/bug.fxtape ./zig-out/bin/fx
./zig-out/bin/fx replay /tmp/bug.fxtape
./zig-out/bin/fx replay /tmp/bug.fxtape --frames
./zig-out/bin/fx replay /tmp/bug.fxtape --json
./zig-out/bin/fx replay /tmp/bug.fxtape --golden out.txt
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

The `Startup Latency` job builds a ReleaseSafe binary, measures six CLI paths with hyperfine, and enforces per-command latency budgets. The same job runs `tests/e2e/tui-performance.test.ts` as the interactive terminal performance gate. A PR that exceeds either fails the check.

The long-turn memory and libfx runtime benchmarks run only on request. Start them with `gh workflow run bench.yml --ref <branch> -f long_turn_memory=true` or `-f libfx_runtime=true`.

The startup benchmark uses `FX_BENCH=1`, an environment variable that runs through arg parsing and CLI dispatch, then exits before TTY initialization. This lives in `src/core/app/app_entry_runtime.zig`.

To measure the interactive launch up to the first frame, use `benchmarks/first_frame.py`. It drives fx on a pseudo-terminal and interleaves several `--binary` arguments for before-and-after comparisons.

The budget is 2ms of raw wall-clock time for every command on the Linux CI runner, which is the authoritative product budget. Local macOS runs report raw means only, because process and dynamic-loader overhead there can exceed 2ms independently of fx. The process baseline is diagnostic only and is never subtracted.

When adding features, consider their impact on startup latency. The `fx help` path is the baseline cold-start benchmark.

## Binary Size Observability

Every pull request runs `.github/workflows/binary-size.yml`, which builds each
release target and its base commit on native runners, reports the size change,
and smoke-tests the pull request binary with `scripts/smoke-binary.sh`.

Each platform check is informational. An increase of at least 52,429 bytes
(0.050000 MiB) emits a warning and retains that platform's binaries for
investigation, but does not reject the pull request. Investigate notable
unexplained growth before changing the threshold. The full macOS arm64 PGSO
release qualification remains authoritative for the 7.000 MiB production
ceiling and performance gates.

## Documentation

When adding or changing user-facing behavior, update the documentation this repository owns in the same change:

1. `--help` output via command specs in `src/builtins/commands.zig`
2. `sdk/README.md` if libfx's supported public behavior or setup changes, as `sdk/AGENTS.md` describes
3. `CONTRIBUTING.md` if build steps, development setup, or collaboration rules change

The user manual at fx.sh/docs is built from a private repository. When a change makes a page wrong or incomplete, updating the manual is part of the change:

* If you are a member of the `vercel-labs` organization on GitHub, you can fetch the private repository behind fx.sh. When you can push to it, update the page there in a companion pull request and link it from this one. A page's source is `apps/marketing/app/(site)/(docs)/docs/<path>/page.mdx`, where `<path>` is the part of its URL after `fx.sh/docs/`.

* If you can't push to that repository, add a `## Docs` section to the PR description with the exact change each affected page needs, as `CONTRIBUTING.md` describes, so a maintainer can make it.

Do not move feature descriptions, option lists, or usage examples into `README.md` in place of the manual.

`README.md` is a short introduction that links to fx.sh/docs. Change it only when one of its statements becomes false, such as a command, flag, path, or link it names, or when a change adds a capability as broad as the ones in its feature list. A single new option, command, or environment variable belongs in `--help` and the manual, not in `README.md`.

Do not document intended behavior as if it already exists.

## Releasing

Releases are prepared by hand in a release PR. The maintainer controls the changelog voice and format.

### Preparing a release

To prepare a release:

1. Create a branch (e.g. `prepare-v0.3.0`)
2. Bump `pub const version` in `src/main.zig`
3. Write the changelog entry in `CHANGELOG.md` at the top, under a new `## <version>` heading, wrapped in `<!-- release:start -->` and `<!-- release:end -->` markers. Remove the markers from the previous release entry so only the new release has them.
4. Open a PR and merge to `main`

When the PR merges, CI compares the version tag to what exists in git. If the tag is missing, it cross-compiles all platform binaries, creates the git tag, and publishes a GitHub Release with the binaries attached. The release body is extracted from the content between the `<!-- release:start -->` and `<!-- release:end -->` markers in `CHANGELOG.md`.

### Writing the changelog

The changelog is public product copy. Describe observable user behavior, not the engineering process behind it. Use the diff, commits, and merged pull requests as research evidence only.

Public changelog entries must:

* Spell the product name `fx`. Preserve different casing only when it is part of an exact code identifier such as `FX_MODEL`.
* Open with a short bold summary of the release.
* Use only relevant sections from `### Breaking Changes`, `### New Features`, `### Improvements`, `### Bug Fixes`, and `### Security`. Omit empty sections.
* Write each bullet as one or two plain sentences on a single line. Lead with the concrete change, then say what happens now. Do not add a bold `**Label:**` prefix.
* Omit pull request numbers, issue numbers, commit hashes, contributor names, and author attribution.
* Omit internal details such as repository moves, website or marketing work, CDN layout, CI workflows, test fixtures, branch history, and implementation-only refactors. Translate relevant work into its public user outcome or leave it out.
* Avoid forcing every merged change into the notes. A change without a public user outcome does not need a bullet.

Only the current release should have markers; remove `<!-- release:start -->` and `<!-- release:end -->` from any previous entry:

```markdown
## 0.3.0

<!-- release:start -->

**`fx sessions` can now list saved sessions from every workspace.**

### New Features

- `fx sessions --all` lists saved sessions across every workspace in the profile.
<!-- release:end -->

## 0.2.5

**The active conversation now stays in view.**

### Improvements

- The active conversation stays visible in terminal scrollback.
```

Do not add a `### Contributors` section or tracker references.

Do not create version tags manually. Do not change `build.zig.zon` version (it is a placeholder).

## Repository and License

The canonical repository is `vercel-labs/fx` on GitHub. All URLs, links, and references to the repo must use `vercel-labs/fx` (not `vercel/fx`, `user/fx`, or any other org/owner). Licensed under Apache-2.0.

## What Not To Do

* Do not add hidden product state that only exists in the live shell

* Do not add a second execution path for the same feature without a clear reason

* Do not commit generated state from `.fx/`, `.zig-cache/`, or `zig-out/`

* Do not add dependencies outside the Zig standard library without discussion
