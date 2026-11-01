# TLA+ models

TLA+ specifications for fx, checked with TLC, together with the scripts and Bun drivers that check them. CI runs the SDK and MCP models on `main` and on pull requests that change the code they cover, as `scripts/detect-ci-need.sh` decides, and the recovery model, with the driver that walks the recovery module along it, on every pull request. Run the others when you change the behavior they describe.

| Folder | What it models | Checker |
|---|---|---|
| `acp/` | The ACP permission modes, which match the CLI's `/permissions`, and the per-session Standard, Fast, and Ultrafast speed (`src/acp/`). | `acp/check.sh`, then the drivers in `drivers/acp/` |
| `cli/` | How `fx` and `fx ask` handle `--model`, `--fast`, `--ultrafast`, and `--effort` at launch, for the current design and a proposed one that validates them. | `cli/check.sh`, `bun test drivers/cli/` |
| `durable/` | Durable libfx sessions (`sdk/engine.js`): the journal, tool replay, parallel batches, fencing, the inbox, resumption, and snapshots. | `durable/check.sh`, `durable/mutants.py` |
| `fuzzy_match/` | The one engine every menu and picker uses to match typed text (`src/core/shared/fuzzy_match.zig`): the exact, prefix, substring, word, and fuzzy tiers, name and text fields, UTF-8 characters, that typing more never shows more, that a long query matches only as typed, and the ranked and filtered listings menus build from it. `design/` holds the goal and context the checks trace to, `cases/edge.json` the hand-worked edge table, and `mutations.json` the planted bugs. | `fuzzy_match/check.sh`, which runs `bun run verify`: TLC on every config, every planted bug in the spec, the oracle, and the engine, the edge table, the engine against the model and a TypeScript oracle that TLC checks, the stress budgets, and the built binary's Models and skills menus checked by TLC |
| `image_route/` | How images reach the model on each request (`src/core/images/image_route.zig`): whether the catalog's `vision` tag makes image input native, the user-image route and vision tool mode, tool images and images from earlier turns attached or withheld with a notice, only images attached this turn failing a request, one capability request and one catalog-down notice per turn, and crashes, duplicate requests, and lost or stale replies. `design/` holds the goal, vision, context, and design the checks trace to, and `mutations.json` the planted bugs. | `image_route/check.sh`, which runs `bun run verify`: TLC, every graph edge replayed against the real core, code traces checked by TLC, `fx ask` turns of the built `zig-out/bin/fx` checked by TLC (`spec/BinaryImageRoute.tla`), every planted bug, and `design/DESIGN.md` traceability |
| `indexer/` | When a scanned root's listing may be reused, merging parallel grep results, the file picker's loading row, and listing snapshots (`src/core/indexer/`). | `indexer/check.sh` |
| `mcp/` | The MCP engine (`src/mcp/`): wire format, requests, stdio, version detection, the tool catalog, both HTTP transports, input-required rounds, authorization, subscriptions, elicitation, and the engine. `rules.md` lists the MCP specification rules the models cite by ID. | `mcp/check.sh`, then the drivers in `drivers/mcp/` |
| `mcp_host/` | fx's MCP host (`src/core/mcp_host/`): host lifecycle, saved credentials, logins shared between processes, logins beside processes that run an older build (`MixedBuilds.tla`), sign-in, elicitation routing, and calls held for the URLs a server asks the user to open. | `mcp_host/check.sh`, `bun test drivers/mcp_host/` |
| `prompt_context/` | How fx lays out a model request (`src/core/agent/runtime/prompt_context.zig`, `orchestrator.zig` `appendStablePromptContext`) and how Anthropic models and OpenAI GPT-5.6 and later reuse it through AI Gateway: the two stable cache markers in each provider's syntax, the provider's own automatic or implicit breakpoints, the four-marker limit, which sessions, worktrees and repositories read which prefix, and what mid-session changes (rules delivered from a subfolder `AGENTS.md`, a named skill, a branch switch) cost the cached conversation. | `prompt_context/check.sh`, `bun test drivers/prompt_context/` |
| `recovery/` | Recovery for one model request (`src/core/recovery/`): retry waits, the crash-loop guard, resuming after a closed window, the status line, and the save that goes with every send. Eight planted mutations, each a bug fx has had or a promise of the API, must each be caught by its named rule. `RecoveryTimed.tla` puts the model on a one-second clock: no wait passes the 30-second cap, a status with nothing flowing changes every second, and on a healthy world a request ends within one capped wait and one send. Its two planted bugs must each be caught. `Resume.tla` models the app around the module across process exits: the record each send saves in its turn, closing on SIGHUP and SIGTERM, and a launch that resumes the request a kill, a crash, or a close left unfinished, or asks first after two crashes or a day. Its eight planted bugs must each be caught by their named rule, and `resume-today.cfg` shows fx before it stranding the request. | `recovery/check.sh` and `bun tests/tla/drivers/recovery/driver.ts`, then `bun tests/tla/drivers/resume/driver.ts` on request |
| `sdk/` | libfx durable sessions (`DurableSession.tla`), how a session object takes prompts in (`PromptIntake.tla`), images saved once by name (`ImageStore.tla`), agent names and routing (`AgentRouting.tla`), tenants whose agents share one process (`TenantIsolation.tla`), steering (`DurableSteer.tla`), and the provider credential edge (`ProviderAuth.tla`). `check.sh` also writes the TLC state graphs the drivers walk. | `sdk/check.sh`, then the drivers |
| `session/` | The session the interactive app has open across launches, prompts, `/new`, `/clear`, `/resume`, `/fork`, quitting and crashes, and what `/status` and the exit line say about it (`ShellSession.tla`, `src/core/session/`, D90). How an agent turn streams into the session log and commits, and how each tool result keeps the time it was made, so an unchanged rebuild of the turn encodes the same bytes, through results that lost their stamp, compaction, recovery from a checkpoint, and faults (`TurnStream.tla`, `src/core/session/session_adapter.zig`, `src/core/agent/runtime/tool_batch.zig`). | `session/check.sh`, then `bun test ./tests/tla/drivers/session/`, which runs the real binary along both models and has TLC check every run. `stream.test.ts` runs `fx ask` turns against a local gateway fixture, compacting ones included; `FX_TLA_WALKS`, `FX_TLA_WALK_STEPS` and `FX_TLA_SEED` set its random walks, `FX_TLA_STRESS_STEPS` its long turn, and `FX_TLA_BASE_BIN` adds the long and compacting turns on another binary for comparison |
| `session_manager/` | The session log, turn lifecycle, writer lock, snapshots, fork, subagents, catalog, host wiring, the side-file move, v1 conversion, and prompt images saved as blobs (`PromptImages.tla`). `rollout/` holds the models of the changes that moved fx onto the session manager. `system-design.md` is the design record the specs check and defines the `D1` to `D95` decision numbers that code comments cite. | `session_manager/check.sh`, `session_manager/mutants.py`, `session_manager/rollout/run.py`, `bun test drivers/session_manager/` |
| `shell_command/` | How an agent git command is admitted and run (`src/core/shell_command/safe_git.zig`), and one model turn through the shell tool, for the current design and a redesign. | `shell_command/check.sh`, `bun test drivers/shell_command/` |
| `terminal/` | The in-memory shell snapshot owner (`src/core/terminal/shell_snapshot.zig`) and the lifecycle of hosted terminals. | `terminal/check.sh` |
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
bun tests/tla/drivers/recovery/driver.ts --self-check   # recovery.zig along Recovery.tla, and two planted module bugs
bun tests/tla/drivers/resume/driver.ts --walks 5 --self-check   # the TUI along Resume.tla; drop --walks for every walk
tests/tla/sdk/check.sh                                  # the SDK specs; writes the state graphs the drivers walk
bun tests/tla/drivers/drive.mjs send --walks 40         # one durable-session graph; see .github/workflows/ci.yml for the rest
bun tests/tla/drivers/drive-agents.mjs --walks 60       # agent routing
bun tests/tla/drivers/drive-tenants.mjs --walks 60      # tenants in one process
bun tests/tla/drivers/drive-steer.mjs ideal --walks 20  # steering
bun test ./tests/tla/drivers/shell_command/             # a driver written as bun tests; see each check.sh for its own
tests/tla/session/check.sh                              # the shell's session, /status and the exit line, and a turn's stream
bun test ./tests/tla/drivers/session/                   # fx along both; FX_TLA_WALKS, FX_TLA_STEPS, FX_TLA_SEED set the random walks
bun test ./tests/tla/drivers/session/stream.test.ts     # fx ask turns along TurnStream; FX_TLA_WALKS, FX_TLA_WALK_STEPS, FX_TLA_SEED, FX_TLA_STRESS_STEPS, FX_TLA_BASE_BIN
```

A `check.sh` that uses `lib/tlc.sh` takes config names to run only those, for example `tests/tla/usage/check.sh LeanUsage`. `Fork`, `V1Conversion`, and the full `LeanUsage` config can run for many minutes. `session_manager/README.md` describes each session spec, the planted bugs, and the trace checkers.
