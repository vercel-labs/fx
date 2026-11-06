# sh.fx: fx extensions to the Agent Client Protocol

Status: draft. fx doesn't implement any part of this specification yet, and each section below states what it will define.

`sh.fx` adds the session features that fx's own clients need to version 1 of the [Agent Client Protocol](https://agentclientprotocol.com) (ACP). It uses only ACP's [extension mechanisms](https://agentclientprotocol.com/protocol/v1/extensibility) and changes no standard message, so a client that knows only ACP works with fx and sees the standard part of each session. A client receives an extension's messages only after fx and the client both advertise the extension in `initialize`.

When ACP has a proposal for a feature, the extension takes the proposal's shape and moves to the standard name once ACP adopts it. A feature that has no proposal yet is a candidate for a new one.

## Conventions

The naming rules, which follow ACP's: capability names and `_meta` keys start with `sh.fx/`, and method and notification names start with `_sh.fx/`. How each extension is versioned, and how fx and a client agree on a version.

## Capabilities

How fx advertises each extension in `agentCapabilities._meta`, how a client asks for one in `clientCapabilities._meta`, and the list of every capability.

## Extensions

Each extension gets its own section here when it is written.

| Extension | What it adds | ACP proposal it follows |
| --- | --- | --- |
| Steering and queued prompts | Input to a running turn, and prompts that wait for the running turn to end | None: the [ACP v2 prompt proposal](https://agentclientprotocol.com/rfds/v2/prompt) leaves steering and queueing to a later proposal |
| Following a session | Several clients on one live session, and whether each session is running | [Multi-Client Session Attach](https://github.com/agentclientprotocol/agent-client-protocol/pull/533) and [`session/status`](https://agentclientprotocol.com/rfds/session-status) |
| Session list changes | A notification when the list of sessions changes | None |
| Journal position | The position of each update in the session's log, so a client that reconnects continues without a gap | `replayFrom` in the [session resume replay proposal](https://agentclientprotocol.com/rfds/v2/session-resume-replay) for ACP v2 |
| Subagents | The child sessions that a turn starts | [Subagent Sessions](https://agentclientprotocol.com/rfds/subagents) |
| Fork and rewind | A new session copied from a point in another, and the removal of the latest turns | [`session/fork`](https://agentclientprotocol.com/rfds/session-fork) for fork, and none for rewind |
| Turn diff | The combined file changes of one turn | None |

## Names in use today

The `libfx/*` methods and `_meta.fx` keys that fx's ACP server uses today, and the `sh.fx` name that replaces each one. The old names will keep working for some releases after the new names ship.

## Schema

`sh-fx.schema.json` holds the JSON Schema for the types this specification defines. It uses the same JSON Schema draft as ACP's schema in `acp/v1/schema.json`, which holds the standard types.
