# Semantic remote attachment

fx can keep an agent session resident on one machine while another fx process presents and controls it. Attachment carries structured conversation and runtime information. It does not carry terminal bytes, ANSI output, a terminal grid, cursor state, resize events, or a hosted shell.

## Ownership model

`fx serve` owns the workspace, credentials, tools, provider requests, permission policy, and writable session store. Each active session has one resident agent actor using the same ACP prompt and tool execution path as `fx acp`. The actor remains alive when presentation connections detach.

`fx attach` owns only its connection, decoded snapshot and events, local input, and append-only presentation. It does not open the remote session store. A server permits multiple observers and one controller per session. Each attachment receives a new random ID. A controller lease is fenced by a monotonically changing control epoch, so requests from a detached or replaced controller fail before mutation.

## Local usage

Start a server in the workspace that should own execution:

```sh
fx serve
```

The default endpoint is `unix://$HOME/.fx/agent.sock`. An explicit endpoint is also supported:

```sh
install -d -m 700 /tmp/fx-agent-$UID
fx serve --listen unix:///tmp/fx-agent-$UID/agent.sock
```

Attach to an existing saved session:

```sh
fx attach unix:///tmp/fx-agent-$UID/agent.sock --session <session-id>
```

Attach read-only:

```sh
fx attach unix:///tmp/fx-agent-$UID/agent.sock --session <session-id> --observe
```

Ordinary input lines submit prompts. The first presentation supports:

- `/abort`
- `/allow`
- `/always`
- `/deny`
- `/respond <json>`
- `/model <id>`
- `/mode <id>`
- `/detach`

EOF and `/detach` release only the presentation. Already accepted work continues in the server.

## Protocol

The wire format is bounded JSON-RPC 2.0. Unix sockets use one newline-delimited JSON value per frame. WebSocket transports use one UTF-8 text message per JSON value. Frames are limited to 8 MiB.

Standard ACP update objects remain the semantic event vocabulary. Attachment lifecycle and asynchronous admission use namespaced methods:

- `fx/attach`
- `fx/detach`
- `fx/prompt`
- `fx/abort`
- `fx/respond`
- `fx/configure`
- `fx/operation/inspect`
- `fx/status`

`fx/attach` registers the connection before capturing a snapshot. It returns an authoritative snapshot at revision R, then the server flushes events buffered after R before entering live delivery. Each live `fx/event` carries its revision and a complete nested ACP notification or request.

The snapshot includes structured history, the current assistant partial, tool records and their latest progress or result, run state, configuration, pending permission or elicitation, operation status, and the controller fence. Durable execution history is projected as structured ACP tool records for remote actors instead of relying only on flattened transcript prose.

Prompts use caller-generated operation IDs. Repeating the same ID with the same prompt returns the existing operation without another provider request. Reusing the ID with different content is rejected. `fx/operation/inspect` reconciles a result when the original response was lost.

## Backpressure and limits

Each presentation sends semantic JSON-RPC through one ordered writer queue. A queue accepts at most 64 messages and 8 MiB. The server closes a slow or overflowing presentation rather than blocking agent execution or silently dropping semantic events. RFC 6455 ping replies are the sole control-frame exception: they are limited to 125 bytes and serialized with the same wire mutex, but do not enter the semantic queue. A resident server is bounded to 16 session actors, 16 attachments per actor, 128 retained operation records per actor, and 256 projected tool records per actor.

## Tailscale Serve

The WebSocket backend deliberately accepts only `ws://127.0.0.1:<port>/<path>`. It rejects wildcard, LAN, Tailscale-IP, and TLS listener addresses. Expose it through Tailscale Serve:

```sh
fx serve \
  --listen ws://127.0.0.1:7741/fx \
  --tailscale-capability fx.sh/cap/remote-attach

tailscale serve --bg \
  --accept-app-caps=fx.sh/cap/remote-attach \
  http://127.0.0.1:7741
```

The WebSocket upgrade requires exactly one `Tailscale-App-Capabilities` header. The configured capability must contain an `actions` array with `observe` or `control` and a `sessions` array with the exact session ID or an explicit `*` grant. Authorization is checked again when the client selects a session and role.

Illustrative grant payload:

```json
{
  "fx.sh/cap/remote-attach": [
    {
      "actions": ["observe", "control"],
      "sessions": ["<session-id>"]
    }
  ]
}
```

The backend never authorizes from a `100.x` source address or from `Tailscale-User-*` headers. Loopback TCP Serve is an explicit same-host trust boundary: enabling Serve is a user-approved host action, so local processes and users able to reach the listener are trusted. Deployments requiring stronger same-host isolation must supply an external private WebSocket-over-Unix or reviewed `tsnet`/WhoIs sidecar. FX itself currently provides semantic newline-delimited JSON-RPC over Unix sockets, not WebSocket-over-Unix. Tailscale Funnel is unsupported because it is public and does not supply Serve identity or app-capability headers.

Clients use the tailnet HTTPS endpoint:

```sh
fx attach wss://builder.example.ts.net/fx --session <session-id>
```

Serve capabilities authorize actions and resources but do not uniquely identify two devices with equivalent grants. Deployments requiring exact node identity should terminate the connection in a separately reviewed `tsnet` or LocalAPI WhoIs sidecar and forward a narrow authenticated assertion to the loopback backend.

## Verification evidence

The first vertical slice is covered by deterministic tests and built-binary probes:

- `zig fmt --check src/` and `zig build -Doptimize=ReleaseSafe`
- focused Zig tests for capability parsing, allocation cleanup, attachment fencing, atomic snapshot registration, UTF-8-safe chunk reassembly, frame and queue limits, operation eviction, connection-task ownership, semantic sanitization, and client protocol failures
- `bun test --max-concurrency 1 remote-attach.test.ts`: six tests covering 194 assertions
- built-binary Unix create, serve, attach, detach, restart, and sole-writer contention
- built-binary WebSocket capability rejection and authorization through a deterministic capability-injecting loopback proxy
- an actual Tailscale Serve HTTPS/WSS negative probe, which rejected a caller lacking the configured app grant with `WebSocketUpgradeRejected`; no tailnet policy was modified to manufacture a positive grant

The end-to-end scenarios attach before and during work, preserve a held assistant partial and pending tool permission across detach, reconcile a lost prompt response by operation ID with one provider request, reject stale attachment IDs and epochs, reject observer mutations, and verify that a presentation process with an empty HOME creates no session store. Exact-commit Full CI across supported Linux and macOS runners remains the release authority.

## Security and lifecycle limitations

- The Unix socket is mode `0600` inside an existing, current-user-owned mode `0700` directory and accepts only the current operating-system user through peer credentials. A held authority lock rejects a second server. FX refuses every pre-existing endpoint path; after a crash, verify and manually remove the stale socket before restarting.
- The remote process is the sole writable session owner. A second local fx process attempting to resume the same session remains blocked by the existing session lock.
- Permission and elicitation requests remain pending in the resident actor if the controller disconnects. A replacement controller must answer the exact pending interaction ID.
- Controller and operation ledgers are resident-process state in this first version. Completed conversation state remains durable, but killing `fx serve` does not preserve an in-flight provider socket or its in-memory operation lookup. The ledger retains 128 records, evicts the oldest terminal record first, and never evicts active work.
- Snapshots larger than one frame use base64-encoded ordered chunks acknowledged before buffered live events are released. The exact decoded snapshot limit is 24 MiB.
- Arbitrary local UI extensions and hosted child-terminal takeover are not transported.
- WebSocket compression, binary messages, continuation fragments, and multiplexing are not supported. Unsupported frames fail closed.
