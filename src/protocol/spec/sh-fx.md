# sh.fx: fx extensions to the Agent Client Protocol

Status: draft. fx doesn't implement any part of this specification yet. A section that says what it will define is not written yet.

`sh.fx` adds the session features that fx's own clients need to version 1 of the [Agent Client Protocol](https://agentclientprotocol.com) (ACP). It uses only ACP's [extension mechanisms](https://agentclientprotocol.com/protocol/v1/extensibility) and changes no standard message, so a client that knows only ACP works with fx and sees the standard part of each session. A client receives an extension's messages only after fx and the client both advertise the extension in `initialize`.

When ACP has a proposal for a feature, the extension takes the proposal's shape and moves to the standard name once ACP adopts it. A feature that has no proposal yet is a candidate for a new one.

## Conventions

### Names

Every name that `sh.fx` adds starts with `sh.fx`, the fx.sh domain in reverse-DNS order, as ACP's [extension rules](https://agentclientprotocol.com/protocol/v1/extensibility) require:

| Name | Form |
| --- | --- |
| Method or notification | `_sh.fx/<area>/<action>`, in snake_case |
| Capability | `sh.fx/<name>`, in camelCase |
| `_meta` key | `sh.fx/<name>`, in camelCase |

The area is the part of ACP that a method acts on, such as `session`, and the action is what the method does there. Together they form a name in ACP's own style, so a method that ACP adopts unchanged moves to its standard name when fx drops the `_sh.fx/` prefix. Methods use snake_case like ACP's `session/request_permission`, and keys use camelCase like ACP fields such as `sessionId`.

The `MethodName`, `CapabilityName`, and `MetaKey` types in `sh-fx.schema.json` give each form as a regular expression.

Extra data on a standard ACP message goes in that message's `_meta` object under an `sh.fx/` key. fx never adds a field at the root of a standard type, because ACP reserves those names for its own future versions.

### Changes to an extension

fx and its clients ignore fields they don't know. An extension can therefore gain optional fields in its messages and in its capability object and keep its names.

A change that would break a peer that knows the older shape gets a new capability name, made by adding a version number to the old one, such as `sh.fx/steering2`. Each method or notification whose shape changes is renamed the same way, such as `_sh.fx/session/steer2`. While clients move, fx can advertise and serve the old and the new names together.

## Capabilities

fx lists each extension it supports in `agentCapabilities._meta` of its `initialize` response. A client lists the extensions it wants in `clientCapabilities._meta` of its `initialize` request. The value of each entry is an object, which stays empty unless the extension defines options for it.

In this exchange, `sh.fx/example` stands for a real capability name:

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": 1,
    "clientCapabilities": {
      "_meta": { "sh.fx/example": {} }
    }
  }
}
```

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "result": {
    "protocolVersion": 1,
    "agentCapabilities": {
      "loadSession": true,
      "_meta": { "sh.fx/example": {} }
    }
  }
}
```

After `initialize`, these rules apply to the connection:

- fx sends an extension's notifications and `_meta` keys to a client only when both lists name the extension. A client that lists no `sh.fx/` capability receives only standard ACP messages.
- A client calls an extension's methods only when fx's list names the extension. fx answers a method it doesn't support with the JSON-RPC error `-32601`, "Method not found".
- Each side ignores the names it doesn't know in the other side's list.

Each extension's section adds its capability here, and to `AgentCapabilitiesMeta` and `ClientCapabilitiesMeta` in `sh-fx.schema.json`. No capability is defined yet.

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

`sh-fx.schema.json` holds the JSON Schema for the types this specification defines. It uses the same JSON Schema draft as ACP's schema in `acp/v1/schema.json`, which holds the standard types. It defines these types so far:

| Type | What it describes |
| --- | --- |
| `MethodName` | The name of an `sh.fx` method or notification |
| `CapabilityName` | The name of an `sh.fx` capability |
| `MetaKey` | An `sh.fx` key in a `_meta` object |
| `Capability` | The value of an `sh.fx` capability entry |
| `AgentCapabilitiesMeta` | The `sh.fx` entries in `agentCapabilities._meta` |
| `ClientCapabilitiesMeta` | The `sh.fx` entries in `clientCapabilities._meta` |
