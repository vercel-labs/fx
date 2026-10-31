# Context: MCP calls today, and where the bridge attaches

This describes the code on `6bb36a928` (`origin/main` when this workspace was made). Paths are repository-relative. Line numbers refer to that commit, except those marked "this change".

## Entry points

| Entry point | Where | What it does |
| --- | --- | --- |
| A model's MCP tool call | `src/core/tooling/tool_mcp_runtime.zig:379-405` (`isAvailableDynamicTool`, `callAdvertisedDynamicTool`) | Runs a dynamic tool only if the model step advertised it, through the runtime's `call_tool` capability |
| The app's MCP call | `src/core/app/app_agent_runtime.zig:466` (`callMcpTool`) → `src/core/app/app_mcp_runtime.zig:920-931` (`State.callTool`) | Leases the MCP host and calls its catalog |
| The catalog call | `src/core/mcp_host/model.zig:195-235` (`Catalog.callTool`) | Checks access and the runtime generation, finds the server, reports the call to the UI observer (`:219`), and runs it |
| The engine call | `src/core/mcp_host/runtime.zig:647-667` (`call`, `callObserved`), `:708-735` (`submit`) | Queues the call to the runtime's owner thread, waits, and sends a cancel once when the cancel flag is set, then waits for that too |
| `fx mcp` verbs | `src/core/cli/cli_surface.zig:587` (top-level `mcp`), `:2273` (`mcp_verbs.run`); `src/core/mcp_host/verbs.zig:259` (`run`), `:349` (`list`), `:483` (`show`); spec in `src/builtins/commands.zig:144-147` | `fx mcp list`, `fx mcp show`, and the login and config verbs. There is no verb that calls a tool |
| The shell tool's environment | `src/tools/shell/shell.zig:1925-1936` (`commandEnvironment`), `src/core/execution/command_environment.zig:12-34` (`Environment`) | Chooses the clean, user, or workspace environment a command runs in. It adds no fx variables a command could use to reach the session |
| The bridge core (this change) | `src/core/mcp_host/mcp_call.zig` (`step`, `abstract`) | The pure decision this workspace designs. Nothing imports it yet except the MCP host's test block (`src/core/mcp_host/host.zig:136-141`, this change) |

## Data flow of a direct MCP call

1. **Discovery.** The model loads a tool's schema with `capability_search` or `mcp_select_tool`, and only an advertised tool can be called (`tool_mcp_runtime.zig:369-386`).
2. **Admission.** `tool_admission.requestPermissionOutcome` (`src/core/tooling/tool_admission.zig:1278`) decides the call. An MCP tool never takes the fast paths that skip review (`:1114-1124`, `:1333`), so it always meets the configured rules, then a saved-session rule, then the prompt or, in auto mode, the reviewer. Subagent workers prompt through `workerPrompter` (`:2101`).
3. **Execution.** `Catalog.callTool` refuses when `access` does not allow the tool (`model.zig:203`, `:566-573`), when the advertised binding changed (`:204`), or when the authority's runtime generation changed (`:205`). It then calls `runtime.callObserved`.
4. **Result.** `render` (`model.zig:835-853`) wraps the engine's answer, and `tool_result.extract` (`src/core/mcp/tool_result.zig:29-60`) parses it under a cap of `max(max_tool_result_bytes, 8 MiB)` (`:35`, `src/core/images/image_data.zig:7`). `serialize_capped` cuts the model's copy to `max_tool_result_bytes` and marks it truncated (`tool_result.zig:245-267`). The default is 64 KiB (`src/core/tooling/tool_result_limits.zig:7`).
5. **Context.** `prepareCapturedToolModelOutput` (`src/core/agent/runtime/execution_memory.zig:655`) hands the result to `result_store.prepare` (`src/core/session/result_store.zig:66-96`). Above 16 KiB the model sees a 4 KiB preview and a handle (`:14-15`, `:458-463`). By then the MCP result is at most 64 KiB, so a larger result is already cut.

## Who owns each piece of state

| State | Owner | Notes |
| --- | --- | --- |
| MCP connections, logins, catalog | The MCP host runtime's owner thread (`runtime.zig:708-735`) | Shared by every caller through `Catalog` |
| A subagent's MCP access | `Access.scoped` (`tool_mcp_runtime.zig:44-61`), checked by `Catalog.allowsLocked` (`model.zig:562-573`) | Modeled in `tests/tla/mcp_host/SubagentAccess.tla` |
| Permission rules and grants | `tool_admission` with the session's permission state (`tool_admission.zig:1278-1292`) | The bridge must ask here, not copy rules |
| Subagent lifecycle | `src/core/subagent/child_state.zig`, at most `max_children = 256` (`:17`) | A subagent's shell call is its own owner, with that subagent's access (this change) |
| The bridge's admission state | `mcp_call.State` (this change) | One writer: the bridge's shell thread |
| Request arguments and results | The bridge shell, by request id | Never in the core, never in session JSON |

## Contracts and formats it touches

- **`CallOptions`** (`tool_mcp_runtime.zig:74-85`) carries the cancel flag, the input responder for server questions, the observer, and `access`. A bridge call fills the same fields.
- **Timeouts** come from the MCP contract: startup 30 s and operation 60 s (`src/core/mcp/mcp_contract.zig:5-6`). A call that times out ends as a failure, so the core needs no clock.
- **Drop logging** goes through `debug_trace.logf` (`src/core/shared/debug_trace.zig:77`), as the repository's rule on dropped user state requires.
- **New protocol** (this design): one JSON request line per connection with a version, from the `fx mcp call` client to the session's bridge socket, and one framed reply. No saved format changes.

## Callers and constraints

- The shell tool runs commands in the user's or a clean shell. Its children inherit the environment, which is how a token reaches `fx mcp call`.
- Several shell commands can run at once, foreground and background, for the session and each subagent. Each `fx mcp call` is one connection and one request.
- The `fx` on `PATH` may be another build than the running session, so client and bridge can disagree on the protocol.
- Startup latency is budgeted at 2 ms of wall clock per command on Linux CI (`AGENTS.md` **Benchmarks**). The bridge must not add work before the first frame.

## Code that makes the wrong design look easy

- **Calling `Catalog.callTool` straight from a socket handler.** It works, and it skips `tool_admission`: no rules, no prompt, no auto review. The direct path gets its check from the tool loop before the call (step 2), not from the catalog. The core makes `authorize` the only way to reach `call` (L4).
- **Reusing `render` and `tool_result.extract` as they are.** They cut the result to `max_tool_result_bytes` for the model (`tool_result.zig:245-267`), which is the opposite of what a file needs. The bridge needs a full-result path, bounded by the configured limit.
- **`Access.unrestricted` as the default** (`tool_mcp_runtime.zig:84`). A bridge call that forgets to pass its owner's access gets every tool, including for a subagent. Every `authorize` and `call` effect carries its owner (L8).
- **Retrying a call whose reply was lost.** The engine retries nothing for the caller, and a naive client might. A call can have side effects, so a lost reply is logged and reported instead (L12, R6).

## Fakes the drivers use

The drivers run the real core. The harness (`tests/tla/drivers/mcp_call/harness.zig`) is the only shell they use, and it fakes only the edge:

- **Tokens:** the model's names `t1`, `t2`, and `forged` map to fixed 32-byte values. The real shell makes random ones.
- **Owners:** `main` and `child` map to owner ids 0 and 1.
- **Effects** are printed, not run. Their results come back as the events the driver sends: the permission answer, the call's end, the reply's end, and disconnects.
- **A crash** is the driver killing the harness process. The next process, which the driver starts ahead of time so the sweep does not wait for it, begins from `State.init`.

## Fakes the bridge's tests use

The bridge runs real sockets, threads, and the real core. Its tests fake only what a tool call lends it:

- **`FakeTool`** (`src/core/mcp_host/mcp_call_bridge.zig`): a capability whose permission check allows or denies, can wait behind a gate as a prompt does, and whose call echoes the tool and arguments. The Zig tests use it for the happy path, a forged token, a denial, a client that leaves while its prompt waits, and the socket's removal.
- **The E2E tests** (`tests/e2e/mcp-stdio.test.ts`, `fx mcp call`) fake only the model, with the fake gateway, and the MCP server, with `tests/e2e/fixtures/mcp-modern-stdio.mjs`. Everything between them is the built `zig-out/bin/fx`.
