# TLA+ models

TLA+ specifications for fx, checked with TLC, together with the scripts and Bun drivers that check them. CI runs the SDK and recovery models, and the recovery driver. Run the others when you change the behavior they describe.

| Folder | What it models | Checker |
|---|---|---|
| `acp/` | The ACP permission modes, which match the CLI's `/permissions`, and the per-session Standard, Fast, and Ultrafast speed (`src/acp/`). | `acp/check.sh`, then the drivers in `drivers/acp/` |
| `cli/` | How `fx` and `fx ask` handle `--model`, `--fast`, `--ultrafast`, and `--effort` at launch, for the current design and a proposed one that validates them. | `cli/check.sh`, `bun test drivers/cli/` |
| `durable/` | Durable libfx sessions (`sdk/fx-sdk.js`): the journal, tool replay, parallel batches, fencing, the inbox, resumption, and snapshots. | `durable/check.sh`, `durable/mutants.py` |
| `indexer/` | When a scanned root's listing may be reused, merging parallel grep results, the file picker's loading row, and listing snapshots (`src/core/indexer/`). | `indexer/check.sh` |
| `mcp/` | The MCP-v2 engine (`src/mcp/`): wire format, requests, stdio, version detection, the tool catalog, both HTTP transports, input-required rounds, authorization, subscriptions, elicitation, and the engine. `rules.md` lists the MCP specification rules the models cite by ID. | `mcp/check.sh`, then the drivers in `drivers/mcp/` |
| `mcp_host/` | fx's MCP host (`src/core/mcp_host/`): host lifecycle, saved credentials, logins shared between processes, sign-in, and elicitation routing. | `mcp_host/check.sh`, `bun test drivers/mcp_host/` |
| `recovery/` | Recovery for one model request (`src/core/recovery/`) and fx carrying out its plans (`src/core/agent/runtime/request_recovery.zig`): retry waits, the status line, the durable save before every send, torn records, the crash-loop guard, resuming after a close, deleting the record at every end, late outcomes, compaction, and fx's stop for unclear failures with its lookahead toward dropping Fast. `RecoveryTimed.tla` adds a discrete clock for the 30-second wait cap, a status that changes every second, and a bounded time to finish once the world heals. `Resume.tla` covers closing and resuming a request across process exits: two fx processes on one session, its files as abstract cells, closes (SIGHUP, SIGTERM, terminal EOF), quits, kills, crashes, the 24-hour rule, and /fork. Its `today-*` configs model fx before that design, and each fails the rule its bug breaks. Every planted defect must be caught by its named rule and by no other (`isolate.sh`). fx does not save the module's record yet, so the record, closing, and resume are model-checked only. | `recovery/check.sh`, then `drivers/recovery/driver.ts` |
| `sdk/` | libfx durable sessions (`DurableSession.tla`), agent names and routing (`AgentRouting.tla`), tenants whose agents share one process (`TenantIsolation.tla`), steering (`DurableSteer.tla`), and the provider credential edge (`ProviderAuth.tla`). `check.sh` also writes the TLC state graphs the drivers walk. | `sdk/check.sh`, then the drivers |
| `session_manager/` | The session log, turn lifecycle, writer lock, snapshots, fork, subagents, catalog, host wiring, the side-file move, and v1 conversion. `rollout/` holds the models of the changes that moved fx onto the session manager. `system-design.md` is the design record the specs check and defines the `D1` to `D62` decision numbers that code comments cite. | `session_manager/check.sh`, `session_manager/rollout/run.py`, `bun test drivers/session_manager/` |
| `shell_command/` | How an agent git command is admitted and run (`src/core/shell_command/safe_git.zig`), and one model turn through the shell tool, for the current design and a redesign. | `shell_command/check.sh`, `bun test drivers/shell_command/` |
| `terminal/` | The in-memory shell snapshot owner (`src/core/terminal/shell_snapshot.zig`) and the lifecycle of hosted terminals. | `terminal/check.sh` |
| `usage/` | `/usage` refreshes and the shared usage cache (`src/usage/`): `LeanUsage.tla` and `UsageModel.tla`. | `usage/check.sh`, then the drivers in `drivers/usage/` |
| `drivers/` | The Bun drivers. They run the real fx binary or SDK code, record what happens, and have TLC check each run against its model. `drive.mjs`, `drive-agents.mjs`, `drive-tenants.mjs`, and `drive-steer.mjs` walk the SDK code along the `sdk/` state graphs. `recovery/driver.ts` walks `recovery.zig` along `Recovery.tla`, to every edge of its state graph and along seeded random paths. | See each folder's `check.sh` |
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

## Models of code that has not landed

Some models describe the next MCP-v2 version, which `src/mcp/` and `src/core/mcp_host/` do not have yet. Their model checks pass, but the real code does not match them until that version lands:

- In `mcp/`, `Engine`, `EngineTrace`, `HttpModern`, `HttpModernTrace`, `HttpLegacy`, and `StdioConn` say so at the top. `drivers/mcp/labs/engine_lab.zig` does not build against `src/mcp/` yet, so `drivers/mcp/driver.ts` runs its scenarios only with `--next`.
- In `drivers/mcp_host/`, the tests marked `NEXT_MCP` run only with `FX_TLA_NEXT_MCP=1`.
- In `recovery/`, the TUI implements `Resume.tla`'s proposed design, but ACP and `fx ask` do not yet: ACP has no SIGHUP or SIGTERM handler, and `fx ask` does not cancel on SIGHUP.

The MCP-v2 models of the two HTTP transports, input-required rounds, authorization, subscriptions, and elicitation are model-checked only. Their traces came from a conformance adapter that is not part of fx. The `drivers/mcp_host/` sign-in tests drive real fx over HTTP against the fake server in `drivers/mcp/fakes/`.

The `cli/` and `shell_command/` tests also check a proposed design. Those checks run only with `FX_TLA_PROPOSED=1`, and they fail until fx implements the design.

## Run

From the repository root:

```sh
tests/tla/session_manager/check.sh                      # every session spec
tests/tla/session_manager/check.sh SessionLog Fork      # selected specs
tests/tla/session_manager/mutants.py                    # every planted bug must be caught
tests/tla/session_manager/trace/selftest.sh             # the trace validator must accept and reject
tests/tla/session_manager/rollout/run.py check          # the rollout models; mutate for their planted bugs
tests/tla/indexer/check.sh                              # every config and its expected verdict
tests/tla/acp/check.sh                                  # likewise for acp/, cli/, durable/, shell_command/, terminal/, usage/
tests/tla/mcp/check.sh                                  # every MCP-v2 model and planted bug
tests/tla/mcp_host/check.sh                             # every MCP host model, planted bug, and finding
tests/tla/recovery/check.sh                             # the recovery models and their planted bugs
bun tests/tla/drivers/recovery/driver.ts --self-check   # recovery.zig along Recovery.tla, and the driver must reject a planted bug
tests/tla/sdk/check.sh                                  # the SDK specs; writes the state graphs the drivers walk
bun tests/tla/drivers/drive.mjs send --walks 40         # one durable-session graph; see .github/workflows/ci.yml for the rest
bun tests/tla/drivers/drive-agents.mjs --walks 60       # agent routing
bun tests/tla/drivers/drive-tenants.mjs --walks 60      # tenants in one process
bun tests/tla/drivers/drive-steer.mjs ideal --walks 20  # steering
bun test ./tests/tla/drivers/shell_command/             # a driver written as bun tests; see each check.sh for its own
```

A `check.sh` that uses `lib/tlc.sh` takes config names to run only those, for example `tests/tla/usage/check.sh LeanUsage`. `Fork`, `V1Conversion`, and the full `LeanUsage` config can run for many minutes. `session_manager/README.md` describes each session spec, the planted bugs, and the trace checkers.
