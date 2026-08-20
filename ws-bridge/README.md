# fx acp WebSocket bridge

A spec-compliant custom transport bridge that exposes `fx acp` over WebSocket,
preserving the identical JSON-RPC message format and ACP lifecycle as stdio.

ACP officially defines **stdio** and a draft **Streamable HTTP** transport
([transports.md](https://agentclientprotocol.com/protocol/transports)). This
bridge is a **custom transport** (as permitted by the spec) that implements
`GET /acp` with `Upgrade: websocket` as a full-duplex channel. It MUST preserve
the JSON-RPC format and lifecycle defined by ACP.

Each WebSocket connection maps to one `fx acp` subprocess because `ServerState`
holds a single active session per process. Multi-session-per-connection
(Streamable HTTP) is not supported.

## Run

```sh
npm install
npm start
# [ws-bridge] listening on http://127.0.0.1:8787/acp (ws)
```

Configuration via environment variables:

| Variable  | Default     | Purpose                                  |
| --------- | ----------- | ---------------------------------------- |
| `PORT`    | `8787`      | HTTP/WS listen port                      |
| `HOST`    | `127.0.0.1` | Listen address                           |
| `FX_PATH` | `fx`        | Path to the fx binary                    |
| `FX_ARGS` | `acp`       | Arguments passed to fx (space-separated) |

Point it at a built binary during development:

```sh
FX_PATH=/path/to/repo/zig-out/bin/fx npm start
```

## Protocol

Single endpoint: `GET /acp`.

| Method | Behavior                                                       |
| ------ | ------------------------------------------------------------- |
| `GET`  | With `Upgrade: websocket` upgrades to a full-duplex channel.  |
| `GET`  | Without upgrade returns `426 Upgrade Required`.               |
| `POST` | Returns `501` (Streamable HTTP profile not implemented).      |
| `GET /` , `GET /health` | Returns `{"status":"ok","transport":"websocket","endpoint":"/acp"}` |

On WebSocket upgrade the bridge assigns an `Acp-Connection-Id` (UUID) and
sends it as an advisory `transport/connection` control frame (the 101 response
header `Acp-Connection-Id` is also set when the underlying `ws` library
permits). Clients MUST still send `initialize` as the first JSON-RPC message
over the socket, exactly as in stdio. All subsequent messages are plain
JSON-RPC 2.0, one per WebSocket text frame. Binary frames are ignored.

When the socket closes, the subprocess is terminated (`SIGTERM` → `SIGKILL`
after 1s). When the subprocess exits, a `transport/exit` control frame is sent
and the socket closes. `transport/error` is sent if `fx` fails to spawn.

## Working directory (cwd)

The ACP spec defines `cwd` as a required absolute path in `session/new`,
`session/load`, and `session/resume` and states it **MUST be used regardless
of where the agent subprocess was spawned**. `cwd` remains the base for
relative paths and part of the session's effective root set
(`[cwd, ...additionalDirectories]`).

`fx` now honors `cwd` directly per session (see `src/acp/sessions.zig`):
- `session/new` creates the session with the requested `cwd` (canonicalized
  via `realpath` when possible; falls back to the requested absolute path if
  the directory does not yet exist).
- `session/load` and `session/resume` validate that the requested `cwd`
  matches the stored session's `cwd` (error `-32602` otherwise).
- `additionalDirectories` is validated as an array of absolute paths.
- Tool execution uses `session.workspace_root` for `workspace_root` and
  `access_scope`, so `read`/`write`/`shell` operations resolve relative to the
  client-chosen directory.

The bridge assists for backwards compatibility with older `fx` binaries by
buffering the first messages for a short grace window (`50ms`) so a `cwd`
arriving in `session/new` immediately after `initialize` can be used as the
spawn `cwd`. If no `cwd` is seen within the grace period, the subprocess is
spawned in the bridge's own `cwd` and per-session `cwd` is still honored by
`fx` for all subsequent tool calls.

Previously the bridge spawned `fx` immediately on `initialize` without a `cwd`,
so the process `cwd` was `fx/ws-bridge` and every session inherited that
directory regardless of the client's choice. This is now fixed.

## Constraints

This implements the **WebSocket-only** profile. The spec's Streamable HTTP
profile (POST/GET/DELETE with SSE streams and multiple sessions per
connection) is not supported, because fx's `ServerState` holds a single active
session per process. Each WebSocket connection maps to one subprocess and one
session.

For the full spec including multi-session Streamable HTTP, see the feasibility
notes in the repository root.
