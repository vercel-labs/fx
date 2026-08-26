# Lifecycle hooks

Fx lifecycle hooks run local programs at supported agent-loop events. They are
available in the native interactive CLI, `fx ask`, ACP, and subagent turns.
The interface is versioned as schema `1`.

Hooks are experimental. Pin your adapter to `schema_version` and reject
versions it does not understand.

## Configure hooks

Configure executable hooks only in the private user profile at
`~/.fx/settings.json`. A checked-in project `.fx.json` cannot enable hooks.
This prevents opening an untrusted repository from silently starting a
program.

Each command is an argv array and is executed directly, without a shell. The
workspace root is the child process working directory.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "command": ["/Users/example/.fx/hooks/tool-policy"],
        "timeout_ms": 2000
      }
    ],
    "PostTurnEnd": [
      {
        "command": ["/Users/example/.fx/hooks/telemetry"],
        "timeout_ms": 5000,
        "environment": ["OTEL_EXPORTER_OTLP_ENDPOINT"]
      }
    ]
  }
}
```

Per-workspace hooks use the canonical absolute workspace path under the same
user-owned profile:

```json
{
  "hooks": {
    "PostTurnEnd": [
      { "command": ["/Users/example/.fx/hooks/default-telemetry"] }
    ]
  },
  "workspaces": {
    "/Users/example/src/payments": {
      "hooks": {
        "PreToolUse": [
          { "command": ["/Users/example/.fx/hooks/payments-policy"] }
        ],
        "PostTurnEnd": []
      }
    }
  }
}
```

A workspace event list replaces the matching user-global event list. Other
events continue to use their global lists. An empty workspace list disables
that event. Within a list, Fx runs handlers in array order. User handlers run
before Fx's built-in lifecycle observers.

Limits:

- Up to 32 handlers per event and 64 argv entries per handler.
- Each argv entry is limited to 4 KiB; the encoded event input is limited to 2 MiB.
- `timeout_ms` defaults to 5000 and must be between 1 and 60000.
- `environment` accepts up to 32 environment-variable names of at most 128 bytes each.
- Hook stdout is bounded to approximately 1 MiB; stderr is bounded to 16 KiB.

## Process protocol

Fx writes one JSON document to stdin and closes stdin. A common envelope is
used for every event:

```json
{
  "schema_version": 1,
  "event": "PreToolUse",
  "invocation": {
    "scope": "interactive",
    "workspace_root": "/Users/example/src/project",
    "session_id": "01J...",
    "subagent_id": null,
    "turn_id": 42
  },
  "payload": {}
}
```

Nullable identifiers are JSON `null`. `scope` is one of `interactive`, `ask`,
`acp`, or `subagent`.

### `PreToolUse`

Runs before local tool validation, permission checks, and execution. Its
payload is:

```json
{
  "step_index": 3,
  "call_id": "call_123",
  "tool_name": "terminal",
  "arguments": { "command": "git status" }
}
```

The handler must print one of these responses to stdout:

```json
{ "action": "continue" }
```

```json
{ "action": "rewrite", "arguments": { "command": "git status --short" } }
```

```json
{ "action": "block", "reason": "command rejected by local policy" }
```

Rewrites feed the next handler in the list. The first block stops the chain.
A timeout, cancellation, non-zero exit, oversized output, or invalid response
fails closed and the tool does not run.

### `Stop`

Runs after Fx has a terminal assistant candidate and before turn finalization:

```json
{
  "step_index": 5,
  "assistant_text": "The change is complete.",
  "provider_disposition": "completed",
  "can_continue": true
}
```

Respond with `{ "action": "allow" }`, or request one synthetic continuation:

```json
{ "action": "continue", "context": "Run the focused test before finishing." }
```

Handlers run in order until one requests continuation. Continuation is ignored
when `can_continue` is false. Handler failures fail open and allow the turn to
finish. Cancelling the active turn terminates an in-flight `PreToolUse` or
`Stop` process.

### `PostTurnEnd`

Runs after a terminal turn outcome is accepted:

```json
{
  "outcome": "completed",
  "provider_disposition": "completed"
}
```

`outcome` is `completed`, `interrupted`, `failed`, or `paused`.
`provider_disposition` can be `null`.

### `AttentionRequired`

Runs after Fx presents a foreground decision prompt:

```json
{ "kind": "permission" }
```

`kind` is `permission`, `question`, or `route_recovery`.

`PostTurnEnd` and `AttentionRequired` ignore stdout. Every handler runs even if
an earlier one fails. Failures, including timeouts and non-zero exits, are
recorded in hook debug traces and do not change the turn outcome. Observation
hooks are allowed to run until their configured timeout.

## Permissions and secrets

Hook processes are user-authorized programs, not agent-selected tool calls, so
they do not open a permission prompt on every invocation. Protect
`~/.fx/settings.json` and every referenced executable accordingly.

Fx supplies a minimal environment (`PATH`, home/user, locale, temporary-dir,
shell, and terminal variables where present). Model-provider credentials and
other arbitrary parent variables are not inherited. Add a variable name to a
handler's `environment` list to opt in to passing its current value. Fx also
sets `FX_HOOK_SCHEMA_VERSION`, `FX_HOOK_EVENT`, and
`FX_HOOK_CONFIGURATION_SCOPE`.

Payloads can contain sensitive workspace paths, assistant text, tool names,
and complete tool arguments. A hook can therefore observe secrets that appear
in a tool call even when its environment is scrubbed. Do not send payloads to
an external service unless that disclosure is intended. Stderr contents are
not copied into normal output or debug logs; only their byte count is traced.

## Integration patterns

### Wrap or guard tool calls

Use `PreToolUse` to inspect every proposed tool call. A policy adapter can keep
the call unchanged, normalize arguments, or block it before Fx validates or
executes the tool. The adapter reads the JSON envelope from stdin and prints a
single action object.

### Emit telemetry

Use `PostTurnEnd` for turn-level telemetry and `AttentionRequired` for
foreground-wait signals. Keep these handlers fast: event lists are sequential,
and each handler's configured timeout bounds the delay.

### Connect an external service such as lat.md

Point the command at a user-owned adapter for the installed service version:

```json
{
  "hooks": {
    "PostTurnEnd": [
      {
        "command": ["/Users/example/.fx/hooks/lat-adapter"],
        "environment": ["LAT_API_KEY"]
      }
    ]
  }
}
```

The adapter should validate `schema_version`, translate the Fx envelope to the
external API, apply its own redaction policy, and exit non-zero on delivery
failure. Fx keeps that failure fail-open for the completed turn.
