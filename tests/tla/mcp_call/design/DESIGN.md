# Design: `fx mcp call` bridge

How a running fx session takes MCP tool calls from the commands its shell runs, so the agent can send a large result to a file or a pipe instead of into its context. `CONTEXT.md` describes the code on `6bb36a928`. Line numbers here refer to that commit, except those marked "this change", which refer to this worktree.

`tests/tla/drivers/mcp_call/traceability.ts` reads this file. It requires:
- every question below to be answered or listed as not applicable;
- every rule and law to have a row under Enforcement;
- every law to name a planted bug;
- every entry there to name a check that exists.

## Questions

- Q1: Values cross only as references or small typed fields. The client sends one JSON line (token, version, and an operation: a call's tool and arguments, or a lookup's server, query, or tool) over the session's socket. The core gets a 32-byte token, a version, request ids, and enums (`mcp_call.zig:115-132`, this change). Arguments and results stay in the shell by request id. The result crosses once, from the session to the client's standard output, and the model sees only what the agent prints. Logs get request ids and drop kinds, never tokens or results.
- Q2: A core event is under 64 bytes, and there is one request per `fx mcp call`, a handful per turn. A result crosses the process boundary once and the disk once. Its size is bounded by the MCP client: 16 MiB per HTTP message (`src/mcp/io/http.zig:25`) and 8 MiB per parsed result (`src/core/mcp/tool_result.zig:35`, `src/core/images/image_data.zig:7`). At 100x, such as a script paging in a loop, capacity caps held requests at 8, so held results are at most 8 x 8 MiB. Requests past that are refused `busy`.
- Q3: The core's state has one owner, the bridge's shell thread. Tokens in force live only in the core's registrations, and the environment copies in child processes are derived: a new session issues new ones, and a stop or a subagent's end revokes them (L10, L9). Permission rules and MCP access keep their current owners, `tool_admission` and `Access`.
- Q4: Nothing of a result goes inline anywhere fx controls. It goes to the client's standard output, and the shell tool's own output cap bounds whatever the agent chooses to print. The client's summary line on standard error holds at most 1,500 characters of shape and repeated short values. A lookup's text goes to standard output too: `list` reads at most 100 search pages, each line holds at most 160 bytes of description, and `help` prints at most 2,000 bytes of description and 64 arguments (`src/core/mcp/tool_lookup.zig`, this change). A call's row in the UI holds the tool's name, and its details hold the arguments only when they are at most 16 KiB. The core returns at most 16 effects per step (`max_effects`) and holds at most `max_slots` requests.
- Q5: Yes. The model gets what it prints. The client gets the result bytes. The permission check gets the tool and its arguments, as for a direct call. The core gets no payload at all.
- Q6: Several `fx mcp call` clients from parallel and background commands of the session and its subagents. The model's own direct MCP calls on the same catalog. Another fx process, which has its own bridge, socket, and tokens. The core takes all of them as one event stream.
- Q7: The bridge's shell thread is the core state's only writer. Two clients never share an entry: each connection gets its own id (L3).
- Q8: Every answer names its request id. An answer a request's stage does not wait for (late, duplicated, or for an id never issued) is logged and changes nothing (L11). Answers for abandoned requests free their slot (L5). The model lets every answer arrive in every state.
- Q9: Admission checks and the slot claim happen in one step. The call is emitted on the step that applies the allow, against the stage that step found (L4). The gap between the core's `call` and the catalog is closed as for direct calls: the shell passes the runtime generation, and `Catalog.callTool` refuses if authority changed in between (`src/core/mcp_host/model.zig:205`).
- Q10: The core state, protected by its single writer, with no locks inside the core. The socket and the connection table belong to the shell thread. The catalog keeps its own mutex (`model.zig:208-210`).
- Q11: The client never resends. Each connection carries one request line; a second line is a protocol error and closes the connection, in the shell. A new connection is a new request with a new id, which is why the client must not retry (the `fx mcp call` E2E tests in `tests/e2e/mcp-stdio.test.ts`). A duplicated answer is stale (L11).
- Q12: A lost reply is logged as `reply_lost` (L12), and nothing retries. The client exits non-zero, saying the connection closed, and the agent decides whether to run it again knowing the call may have run.
- Q13: The dedupe key is the request id, unique in a process (L3). `authorize`, `call`, and `reply` happen at most once per id (L4, L6). `withdraw` and `cancel` happen at most once per id, because stages only advance (L5). Stale answers are idempotent (L11).
- Q14: MCP calls keep the engine's timeouts, startup 30 s and operation 60 s (`src/core/mcp/mcp_contract.zig:5-6`), and a timeout ends the call `failed`. A permission prompt has no timeout, because a call that needs approval pauses until the user answers. It ends with an answer, with Ctrl+C on the command (`client_gone`), or with the session. A client killed by its own deadline makes the session cancel its call (L9).
- Q15: A down, slow, or rate-limited MCP server is the engine's case and ends `failed`. A client sending garbage or an oversized line is refused by the shell before the core and logged (`finish:B2`). A client without a token in force is refused before any other check (L2). A slow reader keeps its slot in `replying` until the reply is written (Q23).
- Q16: The process dies, every client's connection resets, and `fx mcp call` exits saying the fx session ended. Calls in flight die with the process or finish at the server unanswered. Nothing is saved, the next start removes a stale socket file (`finish:B1`), and a new process starts from nothing with new tokens (L14). Results in flight are lost and reported to their clients as errors.
- Q17: A reply can be cut short when the session dies mid-write. The reply is framed with its length, and the client writes to standard output only after it has the whole reply, so a redirect never holds part of a result and the client exits non-zero (the E2E test "a bridge that closes without replying exits 1 and writes no data", `finish:B2`).
- Q18: Each refusal and each failure reaches the client as a reason and an exit code: the session is not running, the command is not inside the session that started it, another fx version, too many calls running (safe to run again, since nothing ran), permission denied, or the MCP error text. The agent sees it like any failed command, and each exit code has an E2E test.
- Q19: Every result or reply the core drops is logged with its id (L12), and so is every stale answer (L11). Refusals are answered. A disconnect after the work ended says nothing, because nothing is lost. The shell logs its own drops: unparsable or oversized lines (`finish:B2`) and effects it could not run (`finish:B7`).
- Q20: On stop, tokens are revoked, prompts withdrawn, and calls cancelled (L9, L10). The shell closes the listener and removes the socket file, and the remaining entries drain as answers arrive (L15). On a crash, the OS closes every socket and the next start removes the stale file. Each connection closes after its reply or refusal.
- Q21: None in the core. The engine measures its timeouts on its own monotonic clock (`src/core/mcp_host/runtime.zig:717`).
- Q22: Held requests are bounded by capacity, 8 by default and 16 at most (L13). Owners are bounded by `max_owners`, and the bridge refuses a shell call past it (`McpCallBridgeFull`). Effects are bounded at 16 per step, and `next` is a counter, not a table. The shell bounds its connections by capacity plus refusals in flight, and each request line by a byte cap (`finish:B2`).
- Q23: A script in a loop meets capacity and is refused `busy`; nothing queues. A slow reader of a large reply keeps its slot until the write ends, so results held by the bridge are bounded by capacity times the result limit.
- Q24: Session startup gains one socket bind, deferred until the first shell command so it stays off the startup path (`finish:B1`). Each shell command gains one environment variable. The core runs once per request event, never per token or keystroke.
- Q25: No. Each event costs O(`max_slots` + `max_owners`) and does not depend on history or result size.
- Q26: One bridge per session, holding up to `capacity` requests (default 8, at most `max_slots` 16).
- Q27: It adds a protocol between the client and the session, and no saved format. The request carries a version. A mismatch is refused as `unsupported_version` only after the token is checked (L2), and an fx without the bridge sets no environment variable, so the client reports the bridge as unavailable (`finish:C2`).
- Q29: The session's shell commands and their children read the environment variable. A user can run `fx mcp call` by hand only inside an fx shell command, by the scope decision. Other fx processes have their own bridges and never read this one's tokens.
- Q30: Tool output or repository text can make the agent run `fx mcp call`, and that call meets the same permission check and review as a direct call (`authorize`, L4), so it gains no authority. A process in the session's command tree can read the token, but that tree already has the shell's authority. Anyone else has no token and is refused (L1, L2). The socket lives in a private directory (`finish:B1`).
- Q31: The token lives in the core and in the environment of the session's commands. Effects carry ids, not tokens, so logs and refusal messages cannot echo one. Results may hold secrets from MCP servers, and they go only to the client's standard output, like any command output.
- Q32: No. Every call follows an allow from the same permission check (L4), with the owner's scoped access (L8, `tool_mcp_runtime.zig:44-61`, `model.zig:566-573`, `tests/tla/mcp_host/SubagentAccess.tla`). The bridge drops one step of the direct path, advertising the tool to the model first (`tool_mcp_runtime.zig:379-405`), so a command can call a tool the model never loaded. Admission still checks that the tool exists and is permitted (`finish:B3`). A lookup (`list`, `search`, `help`) has no permission check, as the agent's own `capability_search` has none, and it sees only what that search sees: the tools the owner's access allows and no rule denies outright (`model.zig:262-268`, `:310-312`).
- Q33: The core, one socket listener, one `fx mcp call` verb, one environment variable, and three adapters (permission, call, and lookup). A save-to-file option per call does not compose with pipes or loops. A standalone `fx mcp call` with fresh connections needs its own logins and permissions. Both were rejected.
- Q34: The runtime `capacity` field exists so the model can use 2; a compile-time constant would serve production. Subagent owners cannot go, since subagents are a requirement. The version check cannot go, since the `fx` on `PATH` can be another build.
- Q35: It reuses the permission check and `Catalog.callTool`, so there is no second MCP client. It does not reuse the 64 KiB cut in `serialize_capped` (`tool_result.zig:245-267`), a flaw for this caller (`finish:B4`).
- Q36: No. Nothing here streams, queues, retries, or runs outside a session.
- Q37: The core runs through the harness in both directions and in its own tests. The shell path (socket, client, adapters) is built, with Zig tests in its files and the `fx mcp call` E2E tests in `tests/e2e/mcp-stdio.test.ts`, the TUI rows included. Still open are `finish:B3` and `finish:B4`, and the binary stage is `finish:D1`.
- Q38: Each refusal reaches its client. Each stale, dropped, or lost event is logged under `mcp-call` with its id and kind (`finish:B7`). The TUI shows each call as its own `Running MCP`, then `Ran MCP`, row in its shell call's group, the row a direct call of the tool gets, and logs a row it could not show (`tool_runtime.zig:1059-1105`, this change).
- Q39: A setting that leaves the bridge closed sets no environment variable, and `fx mcp call` then says the bridge is unavailable. Removing the verb removes the feature, and nothing saved needs migrating.

Not applicable: Q28 (nothing is saved, so there is no migration and nothing to interrupt).

## Laws

The laws `step` obeys. Each one is a named invariant or property in `spec/McpCall.tla`, checked by TLC over the whole model and on traces of the real core.

- **L1 AdmitOnlyValid**: a request is admitted only on an open bridge, with a token in force, the supported version, and a free slot. Its entry waits for the permission check, acting for the token's owner (ownership).
- **L2 RefusalsAreQuiet**: a refused request changes nothing and gets one reason: the first check it failed, in the order closed, unauthorized, version, busy. A client without a token in force learns nothing about versions or load.
- **L3 FreshIds**: each admission takes the next id, and only an admission or a new process moves it. Every id the table holds was issued in this process (`IdsBelowNext`). The request id is the dedupe key (idempotence).
- **L4 CallOnlyFromAuthorizing**: a call starts only when the permission check allows a request that is waiting for it, on that step. With L3 and L5, each request runs at most one call (idempotence, ordering).
- **L5 StagesOnlyAdvance**: a request's stage only moves forward and its owner never changes. It leaves the table only on the event that ends its stage, or with its process (ordering, ownership).
- **L6 OneReplyPerRequest**: a request gets a reply only on the step it starts replying, so at most once (idempotence).
- **L7 ReplyMatchesOutcome**: a reply carries the call's own outcome, or `denied` for a denial (ordering: no reply before its result).
- **L8 EffectsCarryEntryOwner**: `authorize` and `call` effects act for the owner the request was admitted for, so a subagent's call runs with the subagent's access (ownership).
- **L9 LiveWorkHasOwner**: no prompt waits and no call runs for an owner whose token is revoked. A stop or a subagent's end withdraws its prompts and cancels its calls (ownership).
- **L10 ClosedIsQuiet**: a closed bridge holds no token, and starts no prompt or call.
- **L11 StaleIsQuiet**: an answer for a request that is gone, or that its stage does not wait for, changes nothing and is logged. A disconnect after the work ended says nothing (idempotence, ordering).
- **L12 DroppedStateIsLogged**: a result whose client is gone, and a reply that could not be written, are logged with their request id.
- **L13 Bounded**: at most `MaxInFlight` requests held, abandoned ones included, and at most that many effects per step, with more than one only on a stop or an owner's end. One entry per id, one token per owner, and one owner per token (bounds).
- **L14 CrashResets**: a new process starts closed, with no tokens, no requests, and ids from zero.
- **L15 Drained**: every request the core admits leaves its table once the shell gives the answers it owes: a permission answer, the end of each call, and the end of each reply (liveness).

## Enforcement

### Rules

| Rule | Status | Reason | Enforced by |
| --- | --- | --- | --- |
| R1 | pass | Core events carry tokens, ids, and enums. Arguments and results stay as shell buffers keyed by id, and JSON exists only on the socket. | `review:Event and Effect in mcp_call.zig hold no argument or result bytes, so putting a payload through the core does not compile; a reviewer checks the shell keeps buffers by id`, `finish:B2` |
| R2 | pass | A result crosses once, to the client, and never enters session JSON or model context unless the agent prints it. | `finish:B4`, `finish:D1`, `review:the call adapter writes the result only to the client connection, which the binary stage checks against session.json` |
| R3 | pass | Nothing large is put inline: the agent chooses the file by its redirect, each call's UI row shows the tool's name, and the summary and lookups are bounded. | `inv:Bounded`, `zig:src/core/mcp_host/mcp_call_client.zig#a shape summary stays bounded on deep, wide, and odd input`, `zig:src/core/mcp/tool_lookup.zig#help bounds deep, wide, and hostile schemas` |
| R4 | pass | The core's registrations are the only tokens in force. Environment copies are revoked with their owner, and rules and access stay with their owners. | `prop:AdmitOnlyValid`, `inv:ClosedIsQuiet`, `inv:LiveWorkHasOwner` |
| R5 | pass | One event per request step, capacity 8, owners bounded by `max_owners`, results bounded by the MCP client (Q2). | `inv:Bounded`, `prop:RefusalsAreQuiet`, `finish:B1` |
| R6 | pass | The core never emits a second call or reply for an id, and a lost reply is logged, not retried. The client does not retry. | `prop:CallOnlyFromAuthorizing`, `prop:OneReplyPerRequest`, `prop:StaleIsQuiet`, `review:tests/e2e/mcp-stdio.test.ts "a bridge that closes without replying exits 1 and writes no data" sees one request and no second` |
| R7 | pass | Crashes, stops, subagent ends, disconnects at every stage, lost replies, and late, duplicated, and garbage answers are actions in the model, and the code is checked on traces that inject them. | `inv:CrashResets`, `prop:Drained`, `prop:DroppedStateIsLogged`, `driver:code-to-spec`, `driver:spec-to-code` |
| R8 | pass | The client protocol carries a version, and a mismatch is refused with a reason after the token check. Pipes from the shell tool, loopback HTTP, and a Unix socket with a token were compared; the socket was chosen (Final design). | `prop:RefusalsAreQuiet`, `mutation:S2`, `mutation:C2`, `finish:B2`, `zig:src/core/mcp_host/mcp_call_wire.zig#a reply header round-trips and rejects another version` |
| R9 | pass | It reuses the permission check and the catalog, and refuses two inherited flaws: the 64 KiB cut and the default of unrestricted access. | `inv:EffectsCarryEntryOwner`, `prop:CallOnlyFromAuthorizing`, `finish:B4` |
| R10 | fail | Accepted. A runtime `capacity` exists only so the model can use 2, and `abstract`, the harness, and the drivers exist for the verification this workspace is for (G7). | `review:Q34 names the parts that could go; the core adds no queue, retry, setting, or second MCP client` |
| R11 | pass | The core state has one writer. The socket is created per session in a private directory, and a second process's bind on an existing socket fails instead of sharing it. | `finish:B1`, `review:the core holds no resource another process can open; the shell's bind is exclusive, which B1's test checks` |

### Laws

| Law | Statement | Enforced by |
| --- | --- | --- |
| L1 | Admit only valid requests | `prop:AdmitOnlyValid`, `trace:AdmitOnlyValid`, `mutation:S1`, `mutation:S2`, `mutation:C1`, `mutation:C2`, `zig:src/core/mcp_host/mcp_call.zig#a request is admitted only with a token in force and the supported version` |
| L2 | Refusals are quiet and leak nothing | `prop:RefusalsAreQuiet`, `trace:RefusalsAreQuiet`, `mutation:S4`, `mutation:C4`, `zig:src/core/mcp_host/mcp_call.zig#a request is admitted only with a token in force and the supported version` |
| L3 | Fresh ids per process | `prop:FreshIds`, `inv:IdsBelowNext`, `trace:FreshIds`, `trace:IdsBelowNext`, `mutation:S5`, `mutation:S17`, `mutation:C5`, `mutation:C18`, `zig:src/core/mcp_host/mcp_call.zig#seeded random event sequences keep the bounds and run at most one call per request` |
| L4 | A call only from an allowed, waiting request | `prop:CallOnlyFromAuthorizing`, `trace:CallOnlyFromAuthorizing`, `mutation:S6`, `mutation:C6`, `zig:src/core/mcp_host/mcp_call.zig#a call starts only after the permission check allows it, once per request` |
| L5 | Stages only advance | `prop:StagesOnlyAdvance`, `trace:StagesOnlyAdvance`, `mutation:S15`, `mutation:C14`, `zig:src/core/mcp_host/mcp_call.zig#stopping lets work go, but each request keeps its slot until its work ends` |
| L6 | One reply per request | `prop:OneReplyPerRequest`, `trace:OneReplyPerRequest`, `mutation:S14`, `mutation:C13` |
| L7 | The reply matches the outcome | `prop:ReplyMatchesOutcome`, `trace:ReplyMatchesOutcome`, `mutation:S12`, `mutation:C11`, `zig:src/core/mcp_host/mcp_call.zig#a result whose client is gone is dropped and logged, and so is a reply that was lost` |
| L8 | Effects act for their owner | `inv:EffectsCarryEntryOwner`, `trace:EffectsCarryEntryOwner`, `mutation:S13`, `mutation:C12`, `zig:src/core/mcp_host/mcp_call.zig#a subagent's requests act for it, and its end lets them go` |
| L9 | Live work has an owner in force | `inv:LiveWorkHasOwner`, `trace:LiveWorkHasOwner`, `mutation:S8`, `mutation:S9`, `mutation:C8`, `mutation:C15`, `zig:src/core/mcp_host/mcp_call.zig#a subagent's requests act for it, and its end lets them go` |
| L10 | A closed bridge is quiet | `inv:ClosedIsQuiet`, `trace:ClosedIsQuiet`, `mutation:S10`, `mutation:C9` |
| L11 | Stale answers are quiet and logged | `prop:StaleIsQuiet`, `trace:StaleIsQuiet`, `mutation:S7`, `mutation:C7`, `zig:src/core/mcp_host/mcp_call.zig#a call starts only after the permission check allows it, once per request` |
| L12 | Dropped data is logged | `prop:DroppedStateIsLogged`, `trace:DroppedStateIsLogged`, `mutation:S11`, `mutation:C10`, `mutation:C16`, `zig:src/core/mcp_host/mcp_call.zig#a result whose client is gone is dropped and logged, and so is a reply that was lost` |
| L13 | Bounded and keyed | `inv:Bounded`, `trace:Bounded`, `mutation:S3`, `mutation:C3`, `zig:src/core/mcp_host/mcp_call.zig#seeded random event sequences keep the bounds and run at most one call per request` |
| L14 | A new process starts from nothing | `inv:CrashResets`, `trace:CrashResets`, `mutation:S16`, `mutation:C17` |
| L15 | Every admitted request drains | `prop:Drained`, `mutation:S18`, `review:a finite trace cannot show liveness; TLC proves Drained over the whole model under weak fairness of the answers the shell owes, and ConformsToSpec makes each recorded answer move its request on` |

## Final design

### The core

`src/core/mcp_host/mcp_call.zig` (this change) imports only `std` outside its tests.

- **State** (`:99-113`): `open`; `owners`, the tokens in force (session plus up to 256 subagents); `next`, the next request id; and `slots`, at most `capacity` requests, each with id, owner, and stage. The stages are `authorizing`, `calling`, `replying`, `abandoned_auth`, and `abandoned_call` (`:52-65`).
- **Events** (`:115-132`): `started`, `stopped`, `owner_added`, `owner_removed`, `request`, `authorized`, `call_finished`, `reply_done`, and `client_gone`. Time does not enter. I/O results arrive as the last four, and failures as their outcome values.
- **Effects** (`:139-154`), a tagged union of values: `refuse`, `authorize`, `call`, `withdraw`, `cancel`, `reply`, and `log`. At most 16 per step, in a fixed buffer with no allocation (`:157-172`).
- **`step`** (`:174-186`) dispatches to one pure function per event. Absence is `?OwnerId` and `?usize`, and refusals and drops are effects. Mutation stays in a local `out` inside one function. Nothing panics: a full owner table leaves the owner out, so its requests are refused (`:216-228`), and the bridge refuses a shell call before that can happen.
- **`abstract`** (`:393-425`) maps a state onto the spec's `open`, `next`, `registered`, and `entries`.
- **Token comparison** (`ownerOf`, `:352-359`) compares every registered token in constant time.

### The shell (v1, built)

The core is unchanged. What an owner stands for changed: an owner is one running shell call, not a session or a subagent. A command can reach the bridge only while the shell call that ran it runs, and a subagent's shell call is its own owner, so it acts with that subagent's rules and access. The main registration is the bridge's own, and no command holds its token.

- **Capability** (`src/core/tooling/mcp_call_capability.zig`): what a running tool call lends the bridge, `authorize`, `call`, and `lookup`, built by `tool_runtime` for each tool call when MCP is available (`tool_runtime.zig:878`, `:950-960`).
- **`authorize`** (`tool_runtime.zig:962-1000`): resolves the tool as an unselected MCP tool, builds its review schema, and runs `tool_admission.requestPermissionOutcome` with one synthetic call as the review target and the turn's own grants. Configured rules, saved rules, the prompt, and automatic review all apply. Prompts run one at a time (`mcp_call_bridge.zig:421`), because an agent's worker holds one pending prompt.
- **`call`** (`tool_runtime.zig:1015-1045`): the context's MCP call with the agent's `Access`, the checked tool binding, the request's cancel flag, and `max_result_bytes` (16 MiB, the MCP client's HTTP message limit) instead of the 64 KiB model limit. `bridgeResultData` (`:1050`) returns the structured content, else the text content.
- **Bridge runtime** (`src/core/mcp_host/mcp_call_bridge.zig`): `register` (`:93`) starts the listener for the first shell call, in a new private 0700 directory with a random name (`:177`), so no stale socket can exist. `unregister` (`:118`) revokes the token, cancels a running call, leaves a waiting prompt to be answered, waits until nothing borrows the capability, and removes the socket after the last shell call. Its background work runs as `std.Io` tasks the bridge owns: the accept loop is a future (`:184`) that the last `unregister` awaits, and each connection is a task in the bridge's group (`:260`), at most 64 (`:35`), that the last `unregister` cancels and awaits (`:145`). A connection reads one request line of at most 1 MiB within 10 s (`:279`). A watcher task (`:331`, `:423`) reports `client_gone`. `applyLocked` (`:217`) is the one writer of the core's state and turns `log` and `withdraw` effects into `debug_trace.logf("mcp-call", ...)` lines.
- **Wire** (`src/core/mcp_host/mcp_call_wire.zig`): one JSON request line naming its operation (`call`, `list`, `search`, or `help`, `:50`), one JSON header line, and the bytes it announces. The version stays 1: no release has spoken the earlier line.
- **Lookups** (`tool_runtime.zig:1177`, this change): `list SERVER` and `search QUERY` run the agent's own MCP search, with its access and rules, and print one `NAME<TAB>DESCRIPTION` line per tool; `list` follows the pages' cursors. `help TOOL` resolves the tool as `authorize` does and prints its description and each argument's type (`src/core/mcp/tool_lookup.zig`). The core sees a lookup as any request: the bridge answers its `authorize` at once, with no prompt, and runs the lookup as its `call` (`mcp_call_bridge.zig:422`, `:468`), so admission, capacity, and cleanup are the same.
- **Tool rows** (`tool_runtime.zig:1059`, this change): each bridge call pushes the tool lifecycle a direct MCP call pushes, under its own request id, in the shell call's row group, which the orchestrator now passes with the call's lifecycle id. Only the TUI shows them (`app_agent_runtime.zig:312`); a subagent's are off (`agent_adapter.zig:111`), as its other tool calls are no rows of the parent's, and ACP and `fx ask` keep their own tool lists.
- **Environment and yield** (`src/tools/shell/shell.zig:643-660`): the shell tool registers each non-terminal run, adds `FX_MCP_CALL_SOCKET` and `FX_MCP_CALL_TOKEN` to the command's environment (`command_runner.zig:60-62`), and holds the yield while one of the run's requests is in flight (`managed_execution.zig:613`).
- **Client** (`src/core/mcp_host/mcp_call_client.zig`, `verbs.zig:157-162`): `fx mcp call TOOL [JSON | -]`. It writes standard output only after the whole reply arrives, never retries, and exits 0, 1 (failed), 2 (usage), 3 (no shell call or another version), 4 (busy), 5 (denied), or 6 (tool error). When standard output is not a terminal, a successful call also writes one line to standard error (`shapeSummary`): the result's size and shape, with the values of short text fields that repeat across a list's items, so the agent can filter the file without first inspecting it. Unique values such as titles and IDs never appear. `fx mcp call list SERVER`, `search QUERY...`, and `help TOOL` print the lookup's text with exit 0, or exit 1 with why (`verbs.zig:156-173`).
- **Model guidance** (`src/core/mcp/model_catalog.zig:14`): one sentence in the MCP server list, only where the bridge exists (`mcp_call_capability.supported`).
- **Not built:** the result size setting (`finish:E2`).

### Alternatives compared for the protocol (R8)

| Option | Why not, or why |
| --- | --- |
| A file descriptor passed to each command | Lost by commands that close inherited descriptors and by `ssh` or `sudo` hops. A pipe has one reader, so parallel calls need a multiplexer. |
| Loopback HTTP with a token | Any local process can connect and probe it, and ports collide between sessions. It adds an HTTP server to fx for a single client. |
| A Unix socket in a private directory, with a token (chosen) | File permissions keep other users out and the token keeps out other sessions' processes. There is one connection per request, and the OS closes it when either side dies, which is what `client_gone` and a crash need. |

### Mechanisms added, and the answers that required them

| Mechanism | Required by |
| --- | --- |
| Tokens per owner, revoked with the owner | Q30, Q32: subagents keep their own limits and a stopped session's commands lose access |
| `authorize` as the only way to `call` | Q32 and R9: the catalog has no permission check of its own |
| Abandoned stages that keep their slot | Q23 and L13: capacity must count calls that are still running |
| Stale answers logged and ignored | Q8, Q11, Q19 |
| Version check after the token check | Q27 and R8: `fx` on `PATH` may be another build, and strangers learn nothing |
| Per-process ids that never repeat | Q13: a late answer must never reach a later request |
| A pure core with `abstract` and a harness | Q37 and G7: the shell's threads and sockets cannot be checked against a model, and a pure step can |

### Rules this design breaks

- **R10, build only what the problem needs.** The runtime `capacity` field exists only so the model can check the bridge with two slots, where production would use a constant. `abstract`, the harness, and the drivers exist for the verification this workspace is for (G7). Without that requirement, the shell could hold this state machine inline. It would then not be checkable against a model, which is how bugs like a late allow running a withdrawn call (S6, C6) get caught.
