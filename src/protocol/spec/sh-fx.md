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

Each extension's section adds its capability here, and to `AgentCapabilitiesMeta` and `ClientCapabilitiesMeta` in `sh-fx.schema.json`. No capability is defined yet. The table in "Keys in use today" names three that replace fields fx uses today: `sh.fx/steering`, `sh.fx/hooks`, and `sh.fx/hostTools`.

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

fx's ACP server names its additions today with a `libfx/` prefix, which doesn't follow ACP's extension rules, and its wasm build accepts `session/remove`, which ACP calls `session/delete`. Each one gets the new name in this table:

| Today | Direction | New name | What it does |
| --- | --- | --- | --- |
| `libfx/steer` | client to fx, request | `_sh.fx/session/steer` | Adds text to the running turn |
| `libfx/withdraw` | client to fx, request | `_sh.fx/session/withdraw_steer` | Takes back a steer that the running turn hasn't given to the model yet |
| `libfx/handoff` | client to fx, request | `_sh.fx/session/end_turn_for_steer` | Ends the running turn at its next safe point, so that a steer that can't join the turn, such as one with images, runs next |
| `libfx/follow_up` | client to fx, request | `_sh.fx/session/follow_up` | Records a prompt queued behind the running turn, so that the journal keeps it across a crash |
| `libfx/checkpoint` | client to fx, request | `_sh.fx/session/checkpoint` | Saves the state of a session that has no running turn as bytes in a binary attachment |
| `libfx/restore` | client to fx, request | `_sh.fx/session/restore` | Loads the state of a session from a checkpoint attachment |
| `libfx/new` | client to fx, request | `_sh.fx/session/new` | Creates a session with an optional id that the client chooses and optional hooks. ACP's `session/new` requires a folder and MCP servers and lets the agent choose the id |
| `libfx/snapshot` | client to fx, request | `_sh.fx/journal/snapshot` | Returns a snapshot of the session for its journal to store, when no turn is open and no follow-up waits, or at a turn that yielded with nothing waiting for it |
| `libfx/journal_open` | client to fx, request | `_sh.fx/journal/open` | Opens a new session's journal from the events that its host stored |
| `libfx/journal_images` | client to fx, request | `_sh.fx/journal/stage_images` | Stages images from the host's store for the journal that the session opens next |
| `libfx/journal_append` | fx to client, notification | `_sh.fx/journal/append` | Sends a journal event for the host to store, and says whether fx waits until the host has stored it |
| `libfx/journal_flush` | fx to client, request | `_sh.fx/journal/flush` | Waits until the host holds every journal event sent so far |
| `libfx/hook` | fx to client, notification | `_sh.fx/hooks/event` | Reports an observer event, such as the end of a turn, to the client's hooks |
| `libfx/tool_call` | fx to client, request | `_sh.fx/tools/call` | Asks the client to run a tool that the client listed at `initialize` |
| `session/remove` | client to fx, request | `session/delete` | Deletes a session. The new name is ACP's standard method |

For some releases after fx moves to the new names, fx also accepts the `libfx/*` names, and it sends a client the old names unless the client lists the extension's capability. `session/remove` moves to `session/delete` with no such period.

## Keys in use today

fx's ACP server puts its extra data under `_meta.fx.<key>` today, and it reads two fields of a custom `libfx` object at the root of `clientCapabilities`, which ACP forbids. Each one becomes an `sh.fx/` key or capability in this table, or goes away in favor of a standard ACP field:

| Today | Where | New | Kind | What it carries |
| --- | --- | --- | --- | --- |
| `_meta.fx.steering` | `agentCapabilities` in the `initialize` response | `sh.fx/steering` | capability | fx accepts steering. Its value becomes `{}` in place of `true` |
| `_meta.fx.steering` | the `session/prompt` response to a steer | `sh.fx/steeringDelivery` | `_meta` key | How the steer fared in the turn that received it: `absorbed` or `dropped` |
| `_meta.fx.steering` | a `user_message_chunk` update that shows a steer | `sh.fx/steerInput` | `_meta` key | The steer's request id and input id |
| `_meta.fx.steer` | `session/prompt` params | `sh.fx/steer` | `_meta` key | Makes a prompt sent during a running turn a steer. The steering section decides whether it stays |
| `_meta.fx.hooksVersion` | the `session/new` and `session/load` responses | `sh.fx/hooks` | capability | That fx supports hooks, now listed in `agentCapabilities` |
| `_meta.fx.hooks` | `session/new` params | `sh.fx/hooks` | `_meta` key | The client's hook settings, such as `captureContent` |
| `_meta.fx.permissionMode` | each value of the `mode` config option | `sh.fx/permissionMode` | `_meta` key | The permission mode that the session mode applies, with fx's original names, such as `yolo` for full access |
| `_meta.fx.modelResponseRecovery` | `session_info_update` | `sh.fx/modelResponseRecovery` | `_meta` key | A model request that an earlier fx process was running when it stopped, reported when the session loads |
| `_meta.fx.toolCall` | `tool_call` updates | `sh.fx/toolCall` | `_meta` key | Whether the call is fx's own bookkeeping step, and the server and tool name of an MCP call |
| `_meta.fx.alwaysLoaded` | each MCP server that a client supplies | `sh.fx/alwaysLoaded` | `_meta` key | Whether the server's tools stay advertised on every turn. The default is `true` |
| `_meta.fx.profileMcpServers` | `session/new` params | `sh.fx/profileMcpServers` | `_meta` key | Whether fx also loads the MCP servers of the user's profile |
| `_meta.fx.terminal` | `initialize` params | `sh.fx/terminalUi` | `_meta` key | Whether the client is a terminal UI, which picks fx's system prompt. The default is `true` |
| `_meta.fx.attachment` | an image content block in `session/prompt` | `sh.fx/attachment` | `_meta` key | The id of the binary attachment that holds the image's bytes, in place of `data` |
| `_meta.fx.stored` | an image content block in `session/prompt` | `sh.fx/storedImage` | `_meta` key | The name under which the host already stored the image |
| `_meta.fx.continueRecovery` | `session/prompt` params | `sh.fx/continueRecovery` | `_meta` key | The prompt resumes an interrupted turn, so it may have no text |
| `_meta.fx.freshOutput` | `session/prompt` params | `sh.fx/freshOutput` | `_meta` key | The host holds none of the resumed turn's earlier output, so the turn sends its saved reply again |
| `_meta.fx.inputId` | `session/prompt` params | `sh.fx/inputId` | `_meta` key | The id of the follow-up that the prompt runs |
| `_meta.fx.inputAccepted` | `session/prompt` params | `sh.fx/inputAccepted` | `_meta` key | Whether the host already recorded that follow-up as accepted |
| `_meta.fx.turnId` | `session/prompt` params | `sh.fx/turnId` | `_meta` key | The host's id for the turn that the prompt starts |
| `_meta.fx.rerun` | `session/prompt` params | `sh.fx/rerun` | `_meta` key | Tool calls that a crash left running, which the host asks fx to run again |
| `_meta.fx.yieldAt` | `session/prompt` params | `sh.fx/yieldAt` | `_meta` key | The time, in milliseconds since the epoch, at which a journaled turn yields in place of its next model request |
| `_meta.fx.systemPrompt` | `session/new` params | - | removed | A copy of `systemPrompt`. Clients send ACP's standard `systemPrompt` field |
| `systemPromptMode` | `session/new` params, a custom field at the root | - | removed | How fx combines the system prompt with its own. ACP v1 puts it in `systemPrompt.mode` |
| `clientCapabilities.libfx.tools` | the `initialize` request | `sh.fx/hostTools` | capability | The tools that the client runs for fx, as `{ "tools": [...] }` in the capability's value |
| `clientCapabilities.libfx.instructions` | the `initialize` request | - | removed | Text that the client adds to fx's system prompt. The client sends it as ACP's standard `systemPrompt` in `append` mode on each session |

The keys and capabilities move with the method names, under the same rules: for some releases fx also accepts the old forms, and it sends a client the old ones unless the client lists the extension's capability.

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
