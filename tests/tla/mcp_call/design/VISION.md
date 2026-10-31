# Vision: `fx mcp call`

## The end state

The agent treats every MCP tool as a command. It looks a tool up with `fx mcp call help linear_list_issues`, which prints a short typed signature, runs `fx mcp call linear_list_issues '{"team":"ENG"}' > /tmp/issues.json`, and reads back only what it asks `jq` for. The user sees one line per call, such as `Linear · list issues · 212 KB`, and answers the same permission prompt a direct call would raise. The session's logins, permission rules, auto-mode review, and subagent limits apply unchanged, because the bridge reuses them rather than copying them.

## What the bridge is

- **A second way in to the same MCP engine.** A bridge call and a direct call share one catalog, one connection per server, one login, one permission check, and one access policy. There is no second MCP client.
- **Owned by the session.** The bridge opens when a session starts and closes when it ends. Tokens are made per session and per subagent, and revoked when their owner ends.
- **A pure core with a thin shell.** `step(state, event)` decides admission, ordering, and cleanup. It holds no bytes of arguments or results, reads no clock, and performs no I/O. The shell runs effects and reports their results as events.

## What it refuses to be

- **A way around permissions.** Calling through bash grants nothing a direct call would not. Text in a repository or a tool result can make the agent run `fx mcp call`, and the call still meets the permission check and review.
- **A general RPC endpoint.** Only processes that hold a token in force can use it, and those are the session's own shell commands. No other process, user, or session can.
- **A queue or a retry loop.** A full bridge refuses with `busy`. A lost reply is logged and reported, not retried, because the call may have had side effects.
- **A parallel result store.** Results flow to the client once, and fx keeps no second copy.

## Tradeoffs it makes on purpose

- **Bash, not a code sandbox.** Bash already exists in the shell tool, models write it well, and it composes with files, `jq`, and git. The cost is that the shell is not a sandbox, so the bridge must check every call itself (L4) instead of relying on a box around the code.
- **Pause for approval.** A command waits while the user decides. A prompt can hold a slot for as long as it waits. The slot is freed by an answer, by Ctrl+C on the command, or by the session ending (L15).
- **Abandoned work keeps its slot until it ends.** When a client leaves mid-call, the call is cancelled but keeps counting against capacity until the MCP engine reports it ended. This makes `busy` come sooner, but the capacity bound is honest about real concurrent calls (L13).
- **Versioned protocol, refused rather than guessed.** `fx` on `PATH` may be a different build from the running session. A version mismatch is refused with a reason, and only after the token is checked, so the reason leaks nothing to strangers (L2).
- **Ids per process, not per session.** Ids never repeat within a process, even across `/new` and `/resume`, so a late answer can never reach a later request (L3). A crash starts over, and its clients' connections die with it.
