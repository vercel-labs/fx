# Goal: `fx mcp call`

## The problem

An MCP tool's result goes into the model's context. A long list, such as every open issue in a Linear team, costs thousands of tokens on every call, crowds out the work, and is the wrong tool for questions like "how many of these are assigned to Malte". Today fx inlines up to 16 KiB of a tool result and keeps the rest behind a handle the model can only page through with `read_tool_result` (`src/core/session/result_store.zig:14-15`, `:66-96`). An MCP result is also cut to 64 KiB before it gets there, so the rest of a larger list is lost (`src/core/mcp/tool_result.zig:245-267`).

The request, from a user of fx: let a tool call's output go to a file instead of through context, or let the shell call MCP tools directly, as in `call_mcp linear_list '{...}' > /tmp/linear_list`. The shell version was preferred because it composes with pipes, `jq`, loops, and files. It is "code mode" for bash.

## What this design covers

The bridge that lets a command run by the agent's shell tool, inside a running fx session, call that session's MCP tools: `fx mcp call <tool> '<json>'`. The result goes to the command's standard output, so the command decides whether it goes to a file, a pipe, or the screen. Only what the agent prints reaches its context.

This workspace designs and verifies the bridge's pure core, `src/core/mcp_host/mcp_call.zig`: which requests are admitted, the order of the permission check and the call, at most one call and one reply per request, what happens when a client, a subagent, or the session goes away, and what is logged when data is dropped. The shell around it (socket, client, permission and catalog adapters, environment, UI) is specified here and tracked in `FINISH.md`.

## Decisions

| Question | Decision |
| --- | --- |
| Name | `fx mcp call`, beside `fx mcp list` and `fx mcp show` |
| A call needs approval while the command runs | Pause the command and ask |
| Where it works | Inside fx sessions only, for now |
| Load the tool's definition first? | No; `fx mcp call help <tool>` is enough |
| What it prints | Just the data |
| Subagents | Allowed, with the parent's limits |
| When the agent uses it | Big or filtered results; normal MCP calls for small answers |
| Result size limit | A setting, defaulting to what the MCP client already allows |
| The 64 KiB cut on normal MCP calls | Fixed in a separate pull request |

## Success criteria

- **G1** A shell command in the session can run any MCP tool the session may use, and the result reaches the command's standard output in full, up to the configured limit. None of it enters the model's context unless the agent prints it.
- **G2** A bridge call gets the same permission check, the same auto-mode review, and, for a subagent, the same scoped access as a direct MCP call by the same agent. No bridge call runs without one (L4, L8, L9).
- **G3** Each admitted request runs at most one MCP call and gets at most one reply, under duplicated, late, and garbage answers, disconnects, stops, subagent ends, and crashes (L3 to L7, L11).
- **G4** A request from a process without a token in force, from another protocol version, or beyond capacity is refused with one reason and changes nothing (L1, L2, L13).
- **G5** Every result or reply the bridge drops is logged with its request id (L12).
- **G6** Every request the bridge admits leaves its table once the shell gives the answers it owes (L15), and the table never holds more than its capacity (L13).
- **G7** The core is checked against a model: TLC proves every law over the model's whole state space, every distinct model transition is replayed against the real core, traces of the real core with faults are checked by TLC, and every planted bug is caught.

## Non-goals

- A "save to file" option on each MCP call. The bash version subsumes it.
- `fx mcp call` from a terminal outside an fx session. It would need its own logins and permissions.
- A JavaScript or TypeScript code-mode sandbox.
- Retrying calls automatically, queueing requests, or streaming partial results.
- Raising the MCP client's own message and result limits.
- The 64 KiB cut on normal MCP calls (its own pull request).

## What 100% done means

Each item is a check that passes. `FINISH.md` lists each one.

1. `bun run verify` in `tests/tla/mcp_call/` exits 0: model check, core tests, harness, spec to code, code to spec, spec mutations, code mutations, and traceability all pass.
2. `zig build test` passes with the `fx mcp call` tests included (`src/main.zig` lists them in its test block).
3. The shell items in `FINISH.md` (B1 to B8) and the client items (C1, C2) each have their named test passing.
4. A binary stage in `verify` drives the built `zig-out/bin/fx` with a fake MCP server and checks each recorded bridge run against `McpCall.tla` (D1).
5. CI passes for the exact commit, including `macOS arm64`, and the startup latency budget holds.
