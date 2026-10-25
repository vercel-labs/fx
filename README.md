# proto-fx

A Zig coding-agent harness built on [fx](https://github.com/vercel-labs/fx), retaining its inline terminal interface and native tools. Phase 1 adds detached sessions, scoped subagent browsing, interval heartbeats, and a persistent CPython kernel. It uses direct OpenAI-compatible endpoints rather than a gateway login.

## Build and connect

Use Zig 0.17 on macOS or Linux:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/proto-fx setup --base-url http://127.0.0.1:8394
./zig-out/bin/proto-fx
```

Setup discovers `/v1/models` (then `/models` where appropriate), saves the returned model catalog, and selects the first model. Use `--model MODEL` to choose explicitly without discovery, or `--api-key-env VARIABLE_NAME` for a bearer-authenticated endpoint. Only the variable name is saved, not the key. Configuration and session data live under `~/.proto-fx`.

The native agent needs no language runtime. Persistent Python kernels, which agent Python reaches through `import proto_fx as harness` and people control with `/kernel`, use the project's own environment when it has Python 3.11 or newer, and otherwise provision a dedicated Python 3.11 environment with `dill` on first use through `uv`. Install [uv](https://docs.astral.sh/uv/) first, or set `PROTO_FX_KERNEL_PYTHON` to an existing Python 3.11+ interpreter with `dill` installed.

## Terminal workflow

- Press **Left** with an empty composer to browse root sessions. Press **Right** to browse the current session's real subagents.
- Type to filter, use Up/Down to select, and Enter to open. Escape clears the filter before closing. Left in a child transcript returns to its parent.
- Normal arrow editing remains available when the composer contains text, a selection, pasted content, or attachments.
- `/new` creates another root session. Closing the terminal detaches; it does not cancel the session, its subagents, or its kernel. `proto-fx -c` reconnects to the last attached session; `proto-fx --resume ID` attaches a specific root.
- `/heartbeat start 60 YOUR INSTRUCTION` schedules one recurring prompt for the current session. Use `/heartbeat status`, `pause`, `resume`, or `stop` to inspect or change it.
- `/kernel status`, `interrupt`, `stop`, `restart`, and `prewarm` control the current root's Python process. `stop` saves supported globals before releasing Python. `restart` releases the live process; the next cell restores the last valid snapshot.

Ask the model to use `kernel` for Python. Variables persist between cells, top-level `await` works, and asynchronous tasks can continue after a cell finishes. Each child has its own namespace. Cell time budgets are advisory; cancellation is explicit. Python runtime helper APIs are not included; use the existing native tools instead.

Use `proto-fx daemon status` to inspect retained sessions and `proto-fx daemon stop` to gracefully stop the supervisor and its work.

The detached supervisor runs in the same native executable and starts on demand. Its private control socket lives under `~/.proto-fx/daemon`. Approval requests remain pending while detached. After a supervisor crash, saved conversations and supported Python globals can recover, but running cells are not re-executed automatically.

## Development

Use explicit allocators, bounded buffers, and the existing fx execution and permission paths. Keep the additions small. Run the focused checks for the path you change and exercise the built binary on a real terminal or PTY.

Upstream self-updates are disabled; rebuild this checkout to update. Auto-updates will need a proto-fx release feed and supervisor/client upgrade handoff. Provider-neutral credential onboarding and gateway-independent web search are follow-ups, not permanently removed features. The inherited SDK and release machinery are not the Phase 1 delivery target. Hosted gateway search and vision fallback are unavailable without a separate backend. The detached frontend currently rejects image attachments explicitly. Frontend-only commands such as manual compaction, forking, and workspace or MCP reconfiguration report that they are unavailable instead of changing an inactive local session. The native agent still owns its tools and automatic compaction.

## Licenses

The fx base is Apache-2.0 licensed; see [LICENSE](LICENSE). The adapted CPython execution shim retains its MIT notice and attribution in the source and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
