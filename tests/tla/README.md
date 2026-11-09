# TLA+ models

TLA+ specifications for fx, checked with TLC, together with the scripts and Bun drivers that check them. CI runs the SDK, MCP, and transcript window models on `main` and on pull requests that change the code they cover, as `scripts/detect-ci-need.sh` decides; the `fx mcp call` model on `main` and on pull requests labeled `ci:tla-mcp-call`; and the recovery, gateway_open, and agent_runtime models, each with its driver, on every pull request. Run the others when you change the behavior they describe.

| Folder | What it models | Checker |
|---|---|---|
| `acp/` | The ACP permission modes, which match the CLI's `/permissions`, and the per-session Standard, Fast, and Ultrafast speed (`src/acp/`). | `acp/check.sh`, then the drivers in `drivers/acp/` |
| `agent_runtime/` | The empty-reply nudge in the agent step loop (`src/core/agent/runtime/orchestrator.zig`): a reply that stops for `other` with no text and no tool call, as Gemini's `UNEXPECTED_TOOL_CALL` does through the AI SDK, is asked once to continue, a second empty reply in a row or one with no step left ends the turn as failed instead of with "Done.", separate stalls in one long turn each get their own nudge, and the step limit holds. `empty-reply-today.cfg` shows fx before it, and six planted mutations must each be caught by their named rule. | `agent_runtime/check.sh`, then `bun tests/tla/drivers/agent_runtime/driver.ts --self-check`, which runs `fx ask` turns of the built `zig-out/bin/fx` against a local gateway for every reply script up to three replies under step limits 0 to 3, plus seeded longer ones, and has TLC check every turn (`EmptyReplyTrace.tla`); `--stress N` adds one turn with N separate stalls |
| `cache_warming/` | Claude cache warming (`src/core/agent/runtime/cache_warming.zig` and `cache_warmer.zig`): pings that resend the last request with a one-token reply before Anthropic's prompt cache entry expires, on a discrete clock with the provider's entry, early evictions, and sleeps that make the timer late. Every ping reads a live entry, the entry stays alive while armed, pings stop at the cap, a real request, a session change, or shutdown, and a stale ping's answer never stops a newer arm. Seven planted mutations must each be caught by their named rule. | `cache_warming/check.sh`, then `bun tests/tla/drivers/cache_warming/driver.ts --self-check`, which walks the real planner along every edge of the model's graph the planner can tell apart through a small Zig lab, `drivers/cache_warming/lab.zig`, and rejects four planted bugs in the planner |
| `cli/` | How `fx` and `fx ask` handle `--model`, `--fast`, `--ultrafast`, and `--effort` at launch, for the current design and a proposed one that validates them. | `cli/check.sh`, `bun test drivers/cli/` |
| `durable/` | Durable libfx sessions (`sdk/engine.js`): the journal, tool replay, parallel batches, fencing, the inbox, resumption, and snapshots. | `durable/check.sh`, `durable/mutants.py` |
| `full_detail/` | The order Ctrl+O shows a turn in, live and after a resume: each model call's record (time, model, tokens, gen ID) after the text it wrote, a step's failed attempts before it, the records saved with every write of the turn, and a record kept ahead of steering that arrives after it, so each write only adds to the end (`src/core/output/full_transcript_metadata.zig` `stepModelCalls`, `src/core/session/session_event.zig`, `src/core/agent/runtime/finalization.zig`). | `full_detail/check.sh`, then `bun drivers/full_detail/binary-to-spec.ts --self-check` |
| `fuzzy_match/` | The one engine every menu and picker uses to match typed text (`src/core/shared/fuzzy_match.zig`): the exact, prefix, substring, word, and fuzzy tiers, name and text fields, UTF-8 characters, that typing more never shows more, that a long query matches only as typed, and the ranked and filtered listings menus build from it. `design/` holds the goal and context the checks trace to, `cases/edge.json` the hand-worked edge table, and `mutations.json` the planted bugs. | `fuzzy_match/check.sh`, which runs `bun run verify`: TLC on every config, every planted bug in the spec, the oracle, and the engine, the edge table, the engine against the model and a TypeScript oracle that TLC checks, the stress budgets, and the built binary's Models and skills menus checked by TLC |
| `gateway_open/` | A model request's connection open racing Esc and the setup deadline (`src/gateway/open_job.zig`, and `OpenJob` in `src/gateway/client.zig`). A DNS lookup cannot be cancelled, so the open runs on a job of its own: a request that stops first walks away at once, the job stops a connect or TLS setup it is still in, and it closes or releases the connection it opens late. One atomic state word decides who owns the result, and that side frees the client an unpooled open runs on, never while the job still uses it. Esc always gives the request back, a late connection is never used by the request that stopped, and nothing is left open. `open-cancel-today.cfg` shows fx before it waiting out the lookup, and four planted bugs must each be caught. | `gateway_open/check.sh`, then `bun tests/tla/drivers/gateway_open/driver.ts --self-check`, which walks the real hand-off along every edge of the model's graph through a small Zig lab, `drivers/gateway_open/lab.zig`, and rejects four planted bugs in it |
| `image_route/` | How images reach the model on each request (`src/core/images/image_route.zig`): whether the catalog's `vision` tag makes image input native, the user-image route and vision tool mode, tool images and images from earlier turns attached or withheld with a notice, only images attached this turn failing a request, one capability request and one catalog-down notice per turn, and crashes, duplicate requests, and lost or stale replies. `design/` holds the goal, vision, context, and design the checks trace to, and `mutations.json` the planted bugs. | `image_route/check.sh`, which runs `bun run verify`: TLC, every graph edge replayed against the real core, code traces checked by TLC, `fx ask` turns of the built `zig-out/bin/fx` checked by TLC (`spec/BinaryImageRoute.tla`), every planted bug, and `design/DESIGN.md` traceability |
| `indexer/` | When a scanned root's listing may be reused, merging parallel grep results, the file picker's loading row, and listing snapshots (`src/core/indexer/`). | `indexer/check.sh` |
| `mcp/` | The MCP engine (`src/mcp/`): wire format, requests, stdio, version detection, the tool catalog, both HTTP transports, input-required rounds, authorization, subscriptions, elicitation, and the engine. `rules.md` lists the MCP specification rules the models cite by ID. | `mcp/check.sh`, then the drivers in `drivers/mcp/` |
| `mcp_host/` | fx's MCP host (`src/core/mcp_host/`): host lifecycle, saved credentials, logins shared between processes, logins beside processes that run an older build (`MixedBuilds.tla`), how long the Keychain store's lock is held and waited for (`StoreLockBudget.tla`), how long another fx waits for a login's refresh (`RefreshLease.tla`), sign-in, elicitation routing, and calls held for the URLs a server asks the user to open. | `mcp_host/check.sh`, `bun test drivers/mcp_host/` |
| `mcp_call/` | The `fx mcp call` bridge core (`src/core/mcp_host/mcp_call.zig`): how a session admits MCP calls from its shell commands by token, keeps the permission check ahead of each call, runs each call at most once, replies once, lets work go when a client, subagent, or session ends, and logs every result it drops. The shell around the core has not landed. `design/` holds the goal, vision, context, design, ledger, and finish list the checks trace to, and `mutations.json` the planted bugs. | `mcp_call/check.sh`, which runs `bun run verify`: TLC, the core's tests, every distinct graph transition replayed against the real core, code traces checked by TLC, every planted bug, and `design/DESIGN.md` traceability |
| `prompt_context/` | How fx lays out a model request (`src/core/agent/runtime/prompt_context.zig`, `orchestrator.zig` `appendStablePromptContext`) and how Anthropic models and OpenAI GPT-5.6 and later reuse it through AI Gateway: the two stable cache markers in each provider's syntax, the provider's own automatic or implicit breakpoints, the four-marker limit, which sessions, worktrees and repositories read which prefix, and what mid-session changes (rules delivered from a subfolder `AGENTS.md`, a named skill, a branch switch) cost the cached conversation. | `prompt_context/check.sh`, `bun test drivers/prompt_context/` |
| `recovery/` | Recovery for one model request (`src/core/recovery/`): retry waits, the crash-loop guard, resuming after a closed window, the status line, and the save that goes with every send. Eight planted mutations, each a bug fx has had or a promise of the API, must each be caught by its named rule. `RecoveryTimed.tla` puts the model on a one-second clock: no wait passes the 30-second cap, a waiting countdown changes every second, a resend's retry status gives way to the thinking row within the hand-off time, and on a healthy world a request ends within one capped wait and one send. Its three planted bugs must each be caught. `Resume.tla` models the app around the module across process exits: the record each send saves in its turn, closing on SIGHUP and SIGTERM, and a launch that resumes the request a kill, a crash, or a close left unfinished, or asks first after two crashes or a day. Its eight planted bugs must each be caught by their named rule, and `resume-today.cfg` shows fx before it stranding the request. | `recovery/check.sh` and `bun tests/tla/drivers/recovery/driver.ts`, then `bun tests/tla/drivers/resume/driver.ts` on request |
| `sdk/` | libfx durable sessions (`DurableSession.tla`), how a session object takes prompts in (`PromptIntake.tla`), images saved once by name (`ImageStore.tla`), agent names and routing (`AgentRouting.tla`), tenants whose agents share one process (`TenantIsolation.tla`), steering (`DurableSteer.tla`), and the provider credential edge (`ProviderAuth.tla`). `check.sh` also writes the TLC state graphs the drivers walk. | `sdk/check.sh`, then the drivers |
| `session/` | The session the interactive app has open across launches, prompts, `/new`, `/clear`, `/resume`, `/fork`, quitting and crashes, and what `/status` and the exit line say about it (`ShellSession.tla`, `src/core/session/`, D90). How an agent turn streams into the session log and commits, and how each tool result keeps the time it was made, so an unchanged rebuild of the turn encodes the same bytes, through results that lost their stamp, compaction, recovery from a checkpoint, and faults (`TurnStream.tla`, `src/core/session/session_adapter.zig`, `src/core/agent/runtime/tool_batch.zig`). How a session's writes on more than one thread list the compactor's records, one write at a time, so a subagent's finish line during main's compaction never lists them again or clears more than are due (`SessionWrite.tla`, `Session.write`, D50); `session-write-today*.cfg` show fx before the write lock. | `session/check.sh`, then `bun test ./tests/tla/drivers/session/`, which runs the real binary along the models and has TLC check every run. `stream.test.ts` runs `fx ask` turns against a local gateway fixture, compacting ones included; `FX_TLA_WALKS`, `FX_TLA_WALK_STEPS` and `FX_TLA_SEED` set its random walks, `FX_TLA_STRESS_STEPS` its long turn, and `FX_TLA_BASE_BIN` adds the long and compacting turns on another binary for comparison |
| `session_manager/` | The session log, turn lifecycle, writer lock, snapshots, fork, subagents, catalog, host wiring, the side-file move, v1 conversion, and prompt images saved as blobs (`PromptImages.tla`). `rollout/` holds the models of the changes that moved fx onto the session manager. `system-design.md` is the design record the specs check and defines the `D1` to `D95` decision numbers that code comments cite. | `session_manager/check.sh`, `session_manager/mutants.py`, `session_manager/rollout/run.py`, `bun test drivers/session_manager/` |
| `shell_command/` | How an agent git command is admitted and run (`src/core/shell_command/safe_git.zig`), and one model turn through the shell tool, for the current design and a redesign. `FailureStreak.tla` models when repeated shell failures end a turn (`ShellExecutionFailureRetryState` in `src/core/agent/runtime/tool_admission.zig`): a step that changed a file never ends it, and three unchanged failures in a row always do. Its driver replays seeded turns of the real binary through TLC. | `shell_command/check.sh`, `bun test drivers/shell_command/` |
| `subagent/` | Main's messages into its subagents' running turns (`Owner.steer` in `src/core/subagent/managed_owner.zig`): a subagent with 64 unread messages takes no more until its next step reads them, a read message never counts again, one subagent's full queue never refuses another's, and entries are dropped only at a new work or a saved close, where no worker still holds their receipts. `steer-queue-today.cfg` and `steer-queue-today-close.cfg` show fx before it, and six planted mutations must each be caught by their named rule. | `subagent/check.sh`, then `bun tests/tla/drivers/subagent/driver.ts --self-check`, which runs `fx ask` walks of the built `zig-out/bin/fx` against a local gateway, playing main's and every subagent's model, compares each answer with the model, checks each close's `feedback_forgotten` trace count, and has TLC check every walk (`SteerQueueTrace.tla`); `--stress N` adds 20 subagents taking 30 messages each for N rounds, and `--race N` lets subagents read while messages arrive and checks that each reaches its subagent exactly once |
| `terminal/` | The in-memory shell snapshot owner (`src/core/terminal/shell_snapshot.zig`) and the lifecycle of hosted terminals. | `terminal/check.sh` |
| `transcript_window/` | What the main screen holds of a long session and what Ctrl+O reads (`src/ui/transcript/transcript_window.zig`, a pure core the transcript runtime drives through `transcript_window_shell.zig` for every session). The current compaction cycle is held, plus the previous one until the first turn end at which the session log holds it; live blocks are never dropped; a resize reprints the held blocks in bounded slices; Ctrl+O opens from memory and reads older blocks from the log one window at a time, through crashes and lost, stale, duplicate, and garbage replies. `design/` holds the goal, vision, context, and design the checks trace to, and `mutations.json` the planted bugs. | `transcript_window/check.sh`, which runs `bun run verify`: TLC on every config, every edge of the sweep graphs replayed against the real core, code traces with real crashes checked by TLC, every planted bug in the spec and the core, `design/DESIGN.md` traceability, and the built binary through three compaction cycles, Ctrl+O, a resize, and a resume, its traced window steps replayed on the core and checked by TLC |
| `usage/` | `/usage` refreshes and the shared usage cache (`src/usage/`): `LeanUsage.tla` and `UsageModel.tla`. | `usage/check.sh`, then the drivers in `drivers/usage/` |
| `drivers/` | The Bun drivers. They run the real fx binary or SDK code, record what happens, and have TLC check each run against its model. `drive.mjs`, `drive-intake.mjs`, `drive-images.mjs`, `drive-agents.mjs`, `drive-tenants.mjs`, and `drive-steer.mjs` walk the SDK code along the `sdk/` state graphs. `recovery/driver.ts` walks `src/core/recovery/recovery.zig` along every edge of `recovery/Recovery.tla`'s state graph through a small Zig lab, `recovery/lab.zig`. `resume/driver.ts` walks the fx TUI along `recovery/Resume.tla`'s state graph in tmux; it runs on request. | See each folder's `check.sh` |
| `lib/` | `tlc.sh`, which finds TLC and Java and runs a table of configs with their expected verdicts, `tlc.py`, which asks `tlc.sh` for TLC and Java on behalf of the Python checkers, and `run-tlc.sh`, which runs TLC once for the drivers. | |

## Requirements

Java 11 or later and `tla2tools.jar`:

```sh
brew install openjdk
mkdir -p ~/.local/share/tla
curl -fL -o ~/.local/share/tla/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
```

Set `TLA2TOOLS_JAR` to use a jar in another location. The scripts look for Java in `JAVA_HOME`, then in Homebrew's OpenJDK, then on `PATH`. The `mcp/`, `durable/`, and `session_manager/` runners also need Python 3.

The drivers need Bun. Most of them also run the binary that `zig build` puts in `zig-out/bin/fx`, and the terminal ones need tmux. They take these settings from the environment:

| Variable | Default | Effect |
|---|---|---|
| `FX_BIN` | `zig-out/bin/fx` | The binary under test |
| `FX_WORKTREE` | this checkout | The checkout whose binary and `tests/e2e/` helpers a driver uses |
| `FX_TLA_OUT` | a folder under the system temp folder | Where traces, TLC logs, and reports go |
| `FX_SOUND` | `0` in every driver | Keep it at `0`; sound playback can overload a machine during a run |

The SDK drivers also need the native addon and the durable World packages:

```sh
zig build libfx-napi -Dnapi-surface=core
npm ci --prefix sdk/durable
```

## MCP in CI

CI's `TLA+ MCP models and drivers` job runs each engine model's smoke config (`mcp/run.py check`), `mcp_host/check.sh`, and both MCP drivers, on `main` and on pull requests that change MCP code, these models, their drivers, or the files the drivers load. The engine models' planted bugs (`mcp/check.sh`) run only by hand: they measure the checks, not the code.

`.github/workflows/tla-mcp-call.yml` runs `mcp_call/check.sh`, planted bugs included, on every push to `main` and on pull requests labeled `ci:tla-mcp-call`.

## Transcript window in CI

CI's `TLA+ transcript window model` job runs `transcript_window/check.sh --ci` on `main` and on pull requests that change the window's code, its model, its drivers, or the driver code they share. `--ci` leaves out the planted bugs and the run of a built fx along the model, which run only by hand with `transcript_window/check.sh`.

## MCP models without a driver here

The engine models of the two HTTP transports, input-required rounds, authorization, subscriptions, and elicitation are model-checked only. Their traces came from a conformance adapter that is not part of fx. The `drivers/mcp_host/` sign-in tests drive real fx over HTTP against the fake server in `drivers/mcp/fakes/`.

The `cli/` and `shell_command/` tests also check a proposed design. Those checks run only with `FX_TLA_PROPOSED=1`, and they fail until fx implements the design.

## Run

From the repository root:

```sh
tests/tla/session_manager/check.sh                      # every session spec
tests/tla/session_manager/check.sh SessionLog Fork      # selected specs
tests/tla/session_manager/mutants.py                    # every planted bug must be caught
tests/tla/session_manager/mutants.py PromptImages       # the planted bugs of selected specs
tests/tla/session_manager/trace/selftest.sh             # the trace validator must accept and reject
tests/tla/session_manager/rollout/run.py check          # the rollout models; mutate for their planted bugs
tests/tla/indexer/check.sh                              # every config and its expected verdict
tests/tla/acp/check.sh                                  # likewise for acp/, cli/, durable/, shell_command/, terminal/, usage/
tests/tla/mcp/check.sh                                  # every MCP engine model and planted bug
tests/tla/mcp_host/check.sh                             # every MCP host model, planted bug, and finding
bun tests/tla/drivers/mcp/driver.ts                      # src/mcp/ along the MCP engine models
bun test ./tests/tla/drivers/mcp_host/                  # fx's MCP host along its models; FX_BIN picks the binary
tests/tla/recovery/check.sh                             # the recovery model and its planted bugs
bun tests/tla/drivers/recovery/driver.ts --self-check   # recovery.zig along Recovery.tla, and three planted module bugs
tests/tla/gateway_open/check.sh                         # the connection open hand-off and its planted bugs
bun tests/tla/drivers/gateway_open/driver.ts --self-check   # open_job.zig along OpenCancel.tla, and four planted bugs
bun tests/tla/drivers/resume/driver.ts --walks 5 --self-check   # the TUI along Resume.tla; drop --walks for every walk
tests/tla/sdk/check.sh                                  # the SDK specs; writes the state graphs the drivers walk
bun tests/tla/drivers/drive.mjs send --walks 40         # one durable-session graph; see .github/workflows/ci.yml for the rest
bun tests/tla/drivers/drive-agents.mjs --walks 60       # agent routing
bun tests/tla/drivers/drive-tenants.mjs --walks 60      # tenants in one process
bun tests/tla/drivers/drive-steer.mjs ideal --walks 20  # steering
bun test ./tests/tla/drivers/shell_command/             # a driver written as bun tests; see each check.sh for its own
tests/tla/session/check.sh                              # the shell's session, /status and the exit line, and a turn's stream
tests/tla/subagent/check.sh                             # main's messages into its subagents' turns, and planted bugs
bun tests/tla/drivers/subagent/driver.ts --self-check  # fx ask walks along SteerQueue.tla; --stress N, --race N
bun test ./tests/tla/drivers/session/                   # fx along both; FX_TLA_WALKS, FX_TLA_STEPS, FX_TLA_SEED set the random walks
bun test ./tests/tla/drivers/session/stream.test.ts     # fx ask turns along TurnStream; FX_TLA_WALKS, FX_TLA_WALK_STEPS, FX_TLA_SEED, FX_TLA_STRESS_STEPS, FX_TLA_BASE_BIN
bun test ./tests/tla/drivers/session/write.test.ts      # held writes of one session along SessionWrite; FX_TLA_WRITE_STRESS, FX_TLA_REPEAT
```

A `check.sh` that uses `lib/tlc.sh` takes config names to run only those, for example `tests/tla/usage/check.sh LeanUsage`. `Fork`, `V1Conversion`, and the full `LeanUsage` config can run for many minutes. `session_manager/README.md` describes each session spec, the planted bugs, and the trace checkers.
