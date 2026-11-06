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

A change that would break a peer that knows the older shape gets a new capability name, made by adding a version number to the old one, such as `sh.fx/promptDelivery2`. Each method or notification whose shape changes is renamed the same way, such as `_sh.fx/session/steer2`. While clients move, fx can advertise and serve the old and the new names together.

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

Each extension's section defines its capabilities, which `AgentCapabilitiesMeta` and `ClientCapabilitiesMeta` in `sh-fx.schema.json` also list. The steering section defines `sh.fx/promptDelivery` and `sh.fx/hostSteering`. The table in "Keys in use today" names two more that replace fields fx uses today, `sh.fx/hooks` and `sh.fx/hostTools`, which later sections define.

## Extensions

Each extension gets its own section here when it is written.

| Extension | What it adds | ACP proposal it follows |
| --- | --- | --- |
| Steering and queued prompts | Input to a running turn, and prompts that wait for the running turn to end | [Prompt delivery](https://github.com/agentclientprotocol/agent-client-protocol/pull/1261), a draft for ACP v2 |
| Following a session | Several clients on one live session, and whether each session is running | [Multi-Client Session Attach](https://github.com/agentclientprotocol/agent-client-protocol/pull/533) and [`session/status`](https://agentclientprotocol.com/rfds/session-status) |
| Session list changes | A notification when the list of sessions changes | None |
| Journal position | The position of each update in the session's log, so a client that reconnects continues without a gap | `replayFrom` in the [session resume replay proposal](https://agentclientprotocol.com/rfds/v2/session-resume-replay) for ACP v2 |
| Subagents | The child sessions that a turn starts | [Subagent Sessions](https://agentclientprotocol.com/rfds/subagents) |
| Fork and rewind | A new session copied from a point in another, and the removal of the latest turns | [`session/fork`](https://agentclientprotocol.com/rfds/session-fork) for fork, and none for rewind |
| Turn diff | The combined file changes of one turn | None |

### Steering and queued prompts

This extension follows ACP's [prompt delivery proposal](https://github.com/agentclientprotocol/agent-client-protocol/pull/1261), a draft for ACP v2. The proposal adds a `delivery` field to `session/prompt`, which tells the Agent what to do with a prompt that arrives while a turn runs. ACP v1 has no such field, so fx reads the value from `sh.fx/delivery` in the prompt's `_meta`. When ACP adopts the proposal, clients move the value to the standard field.

fx lists the `sh.fx/promptDelivery` capability with the deliveries it supports:

```json
{ "sh.fx/promptDelivery": { "steer": {}, "queue": {} } }
```

A client lists `sh.fx/promptDelivery` to receive the `sh.fx/steerInput` and `sh.fx/steeringDelivery` keys that this section describes.

#### Deliveries

| `sh.fx/delivery` | What fx does with the prompt |
| --- | --- |
| `"steer"` | Adds the prompt's text to the running turn |
| `"queue"` | Holds the prompt and runs it as a turn of its own after the running turn |

For example, this prompt steers the running turn:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "session/prompt",
  "params": {
    "sessionId": "sess_abc123",
    "prompt": [{ "type": "text", "text": "Use the staging database instead." }],
    "_meta": { "sh.fx/delivery": "steer" }
  }
}
```

These rules apply to both deliveries:

- A prompt that arrives while no turn runs starts a turn right away, whatever its delivery.
- A prompt without `sh.fx/delivery` that arrives while a turn runs fails with `-32600`, "Prompt already in progress".
- fx keeps one order for each session across all of its clients.

#### Steers

- A steer holds only text content blocks. fx joins their text, which must be 1 byte to 64 KiB long. A steer with any other block fails with `-32602`, and the client can send the same prompt with `"queue"`.
- A session holds at most 64 steers and 1 MiB of steer text that no turn has taken yet. A steer past either limit fails with `-32600`, "Steering queue is full".
- If the model is writing a reply when a steer arrives, fx stops the reply. The turn takes the steer at its next safe point, before its next model request.
- When a turn takes a steer, fx sends a `user_message_chunk` update with the steer's text. Its `_meta` holds `sh.fx/steerInput`, whose `requestId` is the steer's request id.

When a turn ends, the steers it didn't take run together as the next turn, before any queued prompt. This also applies to a steer that arrives after the turn has stopped taking input, and to a turn that the client stopped.

The response to a steer arrives when the turn that took it ends. It carries that turn's `stopReason`, and its `_meta` holds `sh.fx/steeringDelivery`:

| `sh.fx/steeringDelivery` | Meaning |
| --- | --- |
| `"absorbed"` | The turn that was running took the steer |
| `"next_turn"` | The turn that was running ended first, so the steer ran in the next turn |

#### Queued prompts

- A queued prompt may hold any content that `session/prompt` accepts.
- A session holds at most 64 queued prompts. A prompt past the limit fails with `-32600`, "Prompt queue is full".
- fx starts each queued prompt as a turn of its own when the turn before it ends, in the order it received them. The response to a queued prompt is the response of its own turn.

#### Stopping and withdrawing

- `session/cancel` stops only the running turn. The steers that the turn didn't take and the queued prompts still run after it.
- A client withdraws a steer or a queued prompt that hasn't run yet with `$/cancel_request` and the prompt's request id. fx answers the prompt with `-32800`, "Request cancelled". A steer that a turn has taken can't be withdrawn.
- `session/close` answers each steer and queued prompt that hasn't run with `-32800`.

ACP v2's rule for [prompts during active work](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle) differs on one point: there, `session/cancel` also answers the prompts that haven't run with `-32800`. ACP v1 has no such rule. fx revisits this point when it moves to ACP v2.

#### Host steering

A host that keeps the session's journal itself, such as fx's SDK, steers through methods of its own, because each of its steers carries an input id for the journal. fx lists the `sh.fx/hostSteering` capability for these methods, and a host calls them only when fx lists it:

| Method | Params | What it does | Result |
| --- | --- | --- | --- |
| `_sh.fx/session/steer` | `sessionId`, `text`, and an optional input `id` | Adds the text to the running turn. The text limits of a steer apply | `null` |
| `_sh.fx/session/withdraw_steer` | `sessionId` and the input `id` | Takes back a steer that no turn has taken | `{ "result": "withdrawn" }`, or `{ "result": "already_placed" }` when a turn has taken it |
| `_sh.fx/session/end_turn_for_steer` | `sessionId` | Ends the running turn at its next safe point, so that a steer that can't join it, such as one with images, runs next | `null` |
| `_sh.fx/session/follow_up` | `sessionId`, the input `id`, and 1 byte to 64 KiB of `text` | Records in the journal a prompt that the host queued behind the running turn. The host runs the prompt itself | `null` |

A `user_message_chunk` update for a host steer carries a `requestId` of `null` in `sh.fx/steerInput`, and the steer's input id as `inputId`.

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
| `_meta.fx.steering` | `agentCapabilities` in the `initialize` response | `sh.fx/promptDelivery` | capability | fx accepts steering. Its value lists the deliveries fx supports, in place of `true` |
| `_meta.fx.steering` | the `session/prompt` response to a steer | `sh.fx/steeringDelivery` | `_meta` key | How the steer ran: `absorbed` or `next_turn`. Today's `dropped` goes away, because a steer that a turn doesn't take runs in the next turn |
| `_meta.fx.steering` | a `user_message_chunk` update that shows a steer | `sh.fx/steerInput` | `_meta` key | The steer's request id and input id |
| `_meta.fx.steer` | `session/prompt` params | `sh.fx/delivery` | `_meta` key | What fx does with a prompt sent during a running turn: `steer` or `queue`. Today's `true` means `steer` |
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
| `PromptDeliveryCapability` | The value of the `sh.fx/promptDelivery` capability that fx lists |
| `PromptDelivery` | The value of `sh.fx/delivery`: `steer` or `queue` |
| `SteeringDelivery` | The value of `sh.fx/steeringDelivery`: `absorbed` or `next_turn` |
| `SteerInput` | The value of `sh.fx/steerInput` |
