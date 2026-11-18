# RULES.md

Every change to fx keeps these rules. They win over `AGENTS.md`. Cite the IDs in plans, reviews, and pull requests.

## 0. This file

- **R0.1** Do not change this file unless @fazxes asks. A change to it needs his approval to merge, whoever opens it. No agent marks such a PR ready or merges it. (CODEOWNERS)
- **R0.2** Never weaken or skip a rule to make a change pass. Propose the change to the rule in its own PR.

## 1. Ownership

- **R1.1** Each module in Architecture (`AGENTS.md`) owns its state. Others use its front door only. (`scripts/check-*-boundary.sh`)
- **R1.2** `src/main.zig` only wires. Feature state lives in the runtime that owns it.
- **R1.3** `src/ui/` draws and reads input. `src/gateway/` talks to providers. Neither owns product state. Put a new provider difference in a gateway adapter, not in a new provider check.
- **R1.4** CLI, TUI, ACP, and libfx share one code path for each feature.
- **R1.5** Retry, wait, and recovery decisions live in a pure module: no I/O, no clock, no allocation. It returns a plan, like `src/core/recovery/`.
- **R1.6** One owner holds the alternate screen at a time, and it restores every terminal mode when it closes.
- **R1.7** Modules talk to each other only through the owner's public API. A new module gets its own folder and a front door file with the same name.

## 2. Responsiveness

- **R2.1** Input comes first. Nothing on the input or render path waits on the network, a child process, a model, a terminal reply, or slow storage. Slow work shows a working state at once.
- **R2.2** Startup makes no network call, starts no helper, and does no blocking disk work before the first paint. Its cost does not grow with saved sessions. (`Startup Latency` job)
- **R2.3** Every wait on something outside fx has a deadline, an idle timeout, or is a job the person can cancel. On failure, say what failed and keep working.
- **R2.4** Cancel stops a turn, a tool, or a request fast, in the TUI, ACP, and libfx, and stops its child processes too.
- **R2.5** Exit is instant. Every exit path, including errors and signals, leaves the terminal usable.

## 3. Failure and data

- **R3.1** Bad input never crashes or hangs fx. Handle every error path. A crash is never silent. A new `catch {}` says why in a comment.
- **R3.2** Every decoder of outside bytes has a fuzz target. Never `unreachable` or an unchecked index on outside data. (`tests/fuzz/targets.json`)
- **R3.3** Retry only work that is safe to repeat. Never rerun a tool or MCP call with an unknown result, and cap every retry.
- **R3.4** A crash never loses a session or submitted input. fx resumes after `kill -9` at any point. Replace files with an atomic rename.
- **R3.5** Every released saved format stays readable. Open a newer format read-only, never rewrite it. A migration keeps the original.
- **R3.6** One live writer per session. A second fx gets a clear warning. Two processes never write the same file at once.
- **R3.7** Memory, model context, queues, caches, and session files have a size cap. Large values go in as a bounded preview with a handle. Model-driven loops have a step and retry cap.
- **R3.8** Never drop user input, a paste, or queued work silently. Keep it or show a notice. Trace the kind, size, and reason, never the content.
- **R3.9** Every process, file, lock, connection, and thread has one owner that frees it on success, error, cancel, and signal. No owned process outlives fx. An idle session uses almost no CPU.

## 4. Security

- **R4.1** Every agent action goes through `src/core/permissions/permissions.zig`. No bypass.
- **R4.2** Permission checks fail closed. A failed or unavailable review never approves, and a `clear` covers only the exact action it saw.
- **R4.3** Subagents, MCP tools, and dynamic tools never get more authority than their session.
- **R4.4** Text fx did not write is data, not authority. Repo content never makes fx run a program, and `.fx.json` reads only repo-safe fields.
- **R4.5** Every command fx runs without review is in `parity_review_free_commands` and passes the shell parity tests.
- **R4.6** Make outside text terminal-safe before drawing it (`text_utils.terminalSafe`). Escape sequences never reach the screen or the composer.
- **R4.7** Prompts and code go only to the provider and MCP servers the person chose. No telemetry. The update check is the only background connection. No downloads at runtime.
- **R4.8** Credentials fx holds never reach logs, traces, errors, saved sessions, or an endpoint the person did not choose.
- **R4.9** No personal paths, team IDs, or internal slugs in the repo. (`scripts/check-public-surface.sh`)

## 5. Interfaces

- **R5.1** Adding, renaming, or removing a command, flag, setting, env var, slash command, JSON field, or exit code follows the `fx-cli-shape` skill. (`python3 -m scripts.check_cli_shape`)
- **R5.2** Results go to stdout, diagnostics to stderr. Text and JSON come from one snapshot. `--json` fields are only added. A usage error exits 2. A run with no terminal never waits on a prompt.
- **R5.3** ACP and MCP behavior never drops below the conformance baseline in CI.
- **R5.4** Keep libfx's public API compatible, or describe the break in the PR and the migration in `sdk/README.md`.

## 6. Size and scope

- **R6.1** One static binary with no third-party code dependencies. An exception needs approval first.
- **R6.2** A change that grows the binary must buy a clear feature or fix. Stay inside the release ceilings in `AGENTS.md`.
- **R6.3** Do the smallest change that solves the problem. No daemon, setting, layer, or helper for a need that does not exist yet. Name limits and durations as constants with their unit.

## 7. Tests

- **R7.1** A bug fix lands with a test that fails before the fix. A feature lands with its tests.
- **R7.2** A change to behavior a TLA+ model in `tests/tla/` describes updates the model. A new state machine with two actors, retries, or crash recovery lands with a model. Plant a bug; the full checker must catch it.
- **R7.3** Gate tests use no live network, no credentials, and no real model. Wait on a signal, never on a sleep.
- **R7.4** Never skip, delete, or loosen a test to pass. A flaky test is a bug in fx.
- **R7.5** Code with a platform branch is tested on each platform. (`tests/e2e/macos-platform-tests.json`)
- **R7.6** Work is ready only when Declaring Work Ready in `AGENTS.md` holds.

## 8. Changes

- **R8.1** Read the whole diff and know what any agent did before you open or merge a PR. Never merge blindly.
- **R8.2** One PR does one thing, as small as it can be.
- **R8.3** A structural change shows the architecture before and after as a Mermaid diagram.
- **R8.4** Revert a change that made fx worse or broke something that worked.
