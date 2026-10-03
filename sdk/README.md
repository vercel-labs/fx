# libfx

`libfx` is the small fx agent kernel for JavaScript hosts. One agent is one
in-memory conversation with `prompt`, `checkpoint`, and `close` operations,
plus mid-turn steering on each running turn.

```sh
npm install libfx
```

Node.js uses the native addon when available and falls back to WebAssembly.
Browsers use WebAssembly with JSPI. The default package has no runtime
dependencies and performs no MCP connection, skill scan, process spawn, or
filesystem read when imported.

## Agent

```js
import { createFxAgent } from "libfx";

const agent = await createFxAgent({
  apiKey: process.env.AI_GATEWAY_API_KEY,
  model: "google/gemini-2.5-flash-lite",
  onEvent(event) {
    if (event.type === "transport.response") console.log(event.elapsedMs);
  },
});

const turn = agent.prompt("Explain this project.");

for await (const event of turn) {
  if (event.type === "text_delta") process.stdout.write(event.delta);
}

console.log(await turn.result); // { stopReason, usage }
await agent.close();
```

`apiKey` is required. `model` is optional and defaults to fx's built-in model.
Agent configuration uses named options; `env` is reserved for
`createFxTerminal()`. The canonical model configuration groups the model ID
and model-specific options:

```js
const agent = await createFxAgent({
  apiKey,
  model: { id: "anthropic/claude-opus-5.5-fast", effort: "low", fast: true },
});
```

A string `model` remains supported as shorthand. Top-level `effort` and
`fast` are deprecated but remain supported with a string model or no model;
they cannot be mixed with a model object. New code should use the model object.

`model.effort` sets the reasoning effort for models that advertise effort
levels. It uses the same vocabulary as the fx CLI's `--effort` flag:
`"default"` leaves the choice to the model; named levels such as `"low"`,
`"medium"`, `"high"`, or `"xhigh"` request a specific level. A named level is
validated at creation; an unsupported level rejects with an Error carrying
`code: "LIBFX_MODEL_UNSUPPORTED_EFFORT"`, `model`, and
`capability: "effort"`. Its message names the supported set when available.
Omitting effort or using `"default"` leaves the model default in place.

`model.fast` enables the fast lane for models that advertise one, matching the
fx CLI's `--fast` flag. A model without a fast path rejects at creation with
`code: "LIBFX_MODEL_UNSUPPORTED_FAST"`, `model`, and `capability: "fast"`.
Omitting fast or setting it to `false` leaves the model default in place.

`model.ultrafast` requests Ultra mode. It is off by default and maps to
`openai.serviceTier: "ultrafast"` through the Vercel AI Gateway for models
whose metadata advertises Ultra eligibility. It uses the higher-cost service tier.
Set it to `true` only after the host has selected an eligible model; an
unsupported request rejects with `code: "LIBFX_MODEL_UNSUPPORTED_ULTRAFAST"`,
`model`, and `capability: "ultrafast"`. Set it to `false` to explicitly disable
an inherited request. Ultra and Fast are mutually exclusive, so `ultrafast:
true` disables Fast for the agent. Gateway metadata currently marks Astra
eligible; libfx does not select Ultra automatically.

The new codes replace `LIBFX_UNSUPPORTED_EFFORT` and `LIBFX_UNSUPPORTED_FAST`
for both nested and legacy top-level settings. Callers that check the old codes
must update their error handling.

The host selects the model. Agent creation does not fetch the Gateway model
catalog unless effort requests a named level, fast is enabled, or ultrafast is enabled. Prompting
can resolve model capabilities and context capacity through the supplied
`fetch`; fx caches that metadata for the agent.

`onEvent` receives runtime diagnostics separately from model output. Transport
events report request start, response status and elapsed time, safe Gateway
request metadata, failures, and throttled `transport.activity` liveness while a
response body is streaming. Activity events include the attempt, current chunk
bytes, and cumulative response bytes. They call the host directly at most once
per 250 ms rather than entering the normalized turn queue, so an unread turn
cannot accumulate heartbeat events. Credentials and raw headers are never
included.

libfx makes at most one automatic retry after a retryable transport failure and
only before model output or tool effects escape. Cancellation prevents a retry.

`prompt(input, { signal? })` accepts a string or text, image, and resource
blocks. It returns an async iterable of normalized events:

- `text_delta`
- `reasoning_delta` when supplied by the provider
- `tool_start` with `id`, `name`, and the tool's `input` object. Inputs over
  64 KiB of JSON arrive as an `inputPreview` string prefix plus
  `inputTruncated: true` instead; the tool still receives complete arguments.
- `tool_end`
- `user_message` with `text` when accepted mid-turn steering enters the turn

Consume the turn while it runs, then await `turn.result`. Streamed text and
tool results are lossless and backpressured: a slow reader pauses production
instead of growing an unlimited event queue. Awaiting only `turn.result` can wait for an unread stream to drain.
If you only need the result, explicitly discard events:

```js
const turn = agent.prompt("Update the index.");
for await (const _ of turn) {}
const result = await turn.result;
```

A turn has one event consumer. Breaking out of its iterator cancels the turn;
`turn.cancel()` and `agent.close()` also release blocked output. Embedded agents
have no implicit model-step cap, so hosts should cancel turns that exceed their
own budgets. The CLI's `max_agent_steps` setting does not apply to
`createFxAgent()`. Transport or message-decoding failures reject the result
instead of returning success with missing text.

Native transport buffers at most 8 MiB of output bytes. Unread SDK events apply
backpressure at 1 MiB of encoded messages or 256 events. One message can exceed
that threshold when the queue is empty; an individual encoded ACP message is
limited to 64 MiB on both backends. These are transport bounds, not a total
answer-size limit or a bound on retained conversation history.

Image blocks accept a `Blob` or `File` with a non-empty `type`, raw bytes
(`Uint8Array`, `Buffer`, `ArrayBuffer`, or another typed array) with an
explicit `mimeType`, or canonical base64 (no line wrapping) with an explicit
`mimeType`. The payload must be PNG, JPEG, GIF, or WebP. For a Blob, the MIME
type is inferred from `Blob.type`; an empty type or a conflicting explicit
`mimeType` rejects the input:

```js
const turn = agent.prompt([
  { type: "text", text: "What does this screenshot show?" },
  { type: "image", data: file, sourceRef: "uploads:screenshot-1" }, // File or Blob, with file.type
  // Or: { type: "image", data: pngBytes, mimeType: "image/png" }
  // Or: { type: "image", data: base64Png, mimeType: "image/png" }
]);
```

An optional `sourceRef` identifies a host-owned original. It must be a non-empty
UTF-8 string of at most 512 bytes, without ASCII control characters (0–31 or
DEL). With a reference, you may omit `data` entirely:

```js
agent.prompt([
  { type: "image", mimeType: "image/png", sourceRef: "uploads:screenshot-1" },
]);
```

Image bytes reach the agent core beside the ACP prompt message rather than
inside it. Base64 input is decoded before transfer; prompt image bytes are
encoded as base64 only for the model request. A prompt may contain up to
8 images, including reference-only blocks. Each image may contain up to
3.75 MiB (3,932,160 bytes) of raw data, with at most 6 MiB of raw image data
per prompt. Once encoded for the model request, those limits are 5 MiB per
image and 8 MiB per prompt. The prompt's text, encoded images, and metadata
must fit within the same 8 MiB frame budget.

Without `resizeImage`, the SDK checks Blob size before reading it and the actual
byte count after reading it. If referenced image data would exceed a per-image,
aggregate image, or combined frame limit, the SDK sends its MIME type and
reference without image data. Referenced Blobs known to exceed those limits
remain unread and host-owned. A reference does not increase the limits;
unreferenced oversized input rejects with typed `RangeError`s.

Base64 that is not canonical throws a `TypeError` from `prompt()`. Raw bytes
are copied before `prompt()` returns, so the caller can reuse its buffer. Blob
reads are asynchronous: `prompt()` returns a turn, and read failures reject
`turn.result`. Cancelling or closing during a Blob read settles the turn without
sending its prompt. Without `resizeImage`, size errors for unreferenced base64
and raw-byte input throw synchronously from `prompt()`.

To downscale or convert prompt images before they are sent, pass the optional
`resizeImage` hook when creating the agent. It receives `{ bytes, mimeType }`,
where `bytes` is a `Uint8Array`, and returns `{ bytes, mimeType }` directly or
as a promise. Returned `bytes` may be any typed array or `ArrayBuffer`.
For a Node.js host that already uses `sharp`:

```js
import sharp from "sharp";

const agent = await createFxAgent({
  apiKey,
  model,
  async resizeImage({ bytes }) {
    const png = await sharp(bytes).resize({ width: 1568, withoutEnlargement: true }).png().toBuffer();
    return { bytes: png, mimeType: "image/png" };
  },
});
```

In a browser, return the `ArrayBuffer` from `Blob.arrayBuffer()`, including a
Blob produced by `OffscreenCanvas.convertToBlob()`. The returned bytes are
copied, so the hook may reuse its buffer. With `resizeImage`, image size limits
apply to its output rather than its input; image count and frame metadata
limits still apply. Image prompts with data are prepared asynchronously like
a Blob prompt, and a failure inside the hook rejects `turn.result`. This
opt-in preprocessing reads supplied Blob data even when its original size
exceeds the limits. Reference-only blocks have no bytes and do not call the
hook or fetch the original. The hook is host-provided, not a built-in image
converter or a libfx runtime dependency.

The kernel sniffs the final bytes and compares them with the claimed MIME type
for every input form that carries data; a mismatch fails the turn with
`Invalid image prompt block`. Eligible images reach the model unchanged unless
your hook changes them. Images are routed only to models that advertise image
input; for any other model the turn fails with
`Image prompts are unavailable for the selected model` and no image bytes
leave the process. Images outside the request's pixel or encoded-size limits,
and reference-only originals, are withheld with model-visible recovery feedback
that includes their `sourceRef` when supplied.

A source reference is metadata, not an access grant or an automatic fetch.
Your host owns the original's lifetime, reference resolution, and authorization.
Expose preparation or retrieval through your existing tools' `execute()`
callbacks if the agent needs a smaller copy. libfx has no built-in image resizer,
shell, global converter, or source store, and a reference grants no native
filesystem authority. If a tool is absent or fails, the original remains
withheld rather than being sent anyway.

For example, a tool can delegate to your app's authorized image store:

```js
const prepareImage = {
  name: "prepare_image",
  description: "Return a new smaller copy of a host-owned image. Use the request limit for maxSide.",
  inputSchema: {
    type: "object",
    properties: { sourceRef: { type: "string" }, maxSide: { type: "integer" } },
    required: ["sourceRef", "maxSide"],
  },
  async execute({ sourceRef, maxSide }, { signal }) {
    const copy = await imageStore.prepareCopy(sourceRef, { maxSide, signal });
    return {
      type: "libfx.tool-result",
      text: "Prepared a new copy; original unchanged.",
      images: [{ type: "image", data: copy.base64, mimeType: copy.mimeType, sourceRef }],
    };
  },
};
// Supply prepareImage in createFxAgent({ tools: [prepareImage], ... }).
```

`imageStore` is application code, not a libfx API. It must authorize references,
validate the requested dimensions, and stop conversion when `signal` aborts.
The returned copy is checked again by the kernel before model submission.
Typed host-tool images still use base64 `data`; `resizeImage` prepares prompt
images only.

Version 2 checkpoints retain prompt images as raw image blobs and preserve
source refs within the existing 4 MiB checkpoint bound on both backends. A
checkpoint does not store a source file or host-owned original for a
reference-only block. On restoration, resupply your tools and restore the
sources those refs identify.

Only one top-level prompt may run at a time. While it runs,
`await turn.steer(text)` appends guidance at the next safe model boundary
without discarding the in-flight response or completed tool work. Steering also
accepts an array of text blocks; image and resource steering blocks are rejected.
Each message is limited to 64 KiB, with at most 64 queued messages and 1 MiB of
queued steering text. Accepted steering appears as a `user_message` event before
the model's continued output. For a Blob prompt or one prepared by
`resizeImage`, steering during that preparation waits for the prompt to be
sent; cancelling before then rejects the pending steering. Calling `steer()` after the turn settles rejects with
`no prompt is running`.

```js
const turn = agent.prompt("Build the feature.");
for await (const event of turn) {
  if (event.type === "tool_end" && event.name === "read_file") {
    await turn.steer("Keep the public API backward compatible.");
  }
}
```

`steer()` resolves to `{ id }`, and the returned promise carries the same `id`
at once. Until the model sees a steer, `turn.withdraw(id)` takes it back and
resolves to `withdrawn`; after that it resolves to `already_placed`. With
[persistence](#persistence), a steer resolves only once its acceptance is stored, a model request
carries it only after that, and a withdrawal resolves once it is stored, so a
crash never loses a steer the call reported as accepted: `agent.resume()`
delivers one the model had not seen yet. The web core accepts a steer when it
takes it at the next boundary, so there `steer()` resolves then, and a steer
still queued when the turn ends rejects.

`agent.followUp(input)` queues text to run as its own turn once the current
turn ends, or at once when none is running, instead of failing with
`a prompt is already in progress`. It returns a promise for that turn; the
promise carries the follow-up's `id` and `accepted`, which resolves `{ id }`
once it is stored. With persistence, a follow-up survives a crash. After a
restore, the follow-ups the session held have no caller, so each waits for
`agent.resume()`: every call continues the open turn first, then starts the
next held follow-up, and returns `null` once none is left. Follow-ups this
agent queues run on their own and do not wait behind held ones. Call `resume()`
until it returns `null` whenever a session opens, before this agent queues
follow-ups of its own: one queued during a resumed turn starts when that turn
ends, and `resume()` throws while it runs. A follow-up whose turn ends before
libfx records its first `turn_progress` is withdrawn, and one that ends after
it is recorded like any other turn, so a follow-up never runs twice. `close()`
rejects follow-ups that have not started; the session's records still hold them.

Cancelling a steered turn drops any guidance that has not reached a safe
boundary and releases its queue. Applied guidance is part of the same history
turn, so an idle `checkpoint()` includes the full steered conversation.

`checkpoint()` returns opaque, bounded, versioned bytes. Concurrent calls run
one at a time, and a call still waiting for an earlier one fails the same way a
direct call would if a prompt starts or the agent closes first. A newer libfx
restores checkpoints from older versions, but an older libfx cannot restore one
written by a newer version. Restore them only when creating a fresh agent:

```js
const restored = await createFxAgent({ apiKey, model, checkpoint });
```

An already-aborted prompt signal returns `cancelled` without a model request
or a history change. The next prompt can run normally.

The checkpoint contains conversation history and usage only. The host owns
durable storage and must resupply models, credentials, instructions, tools,
MCP clients, and skill records. Reasoning effort, Fast mode, and Ultra mode are
agent-creation options and are not stored in a checkpoint: recreate the agent
with new `model.effort`, `model.fast`, or `model.ultrafast` values to change
them, the same path as switching models.

### Persistence

Pass a store as `persistence`, and libfx records the session as it runs, so a
new agent can continue it after the process running it stops. libfx writes
opaque records and checkpoints to the store and reads them back. The store
never parses them, and libfx never sees how they are stored.

```js
import { createFxAgent, createMemoryPersistence } from "libfx";

const persistence = createMemoryPersistence();
const agent = await createFxAgent({ apiKey, model, persistence, sessionId: "support-42" });
```

A store is an object with these methods:

```ts
interface Persistence {
  load(): Promise<{
    checkpoint?: { data: Uint8Array; through: string };
    journal?: Iterable<JournalRecord> | AsyncIterable<JournalRecord>;
  }>;
  append(input: { expected: string | null; idempotencyKey: string; data: Uint8Array }): Promise<{ cursor: string }>;
  saveCheckpoint?(input: { through: string; data: Uint8Array }): Promise<void>;
}

interface JournalRecord {
  cursor: string;
  data: Uint8Array;
}
```

`append()` stores one record and resolves to its cursor, a string the store
chooses that places the record after the ones before it. The session's records
are its journal. libfx sends records one at a time, in order, and `expected`
is the cursor of the last record the agent knows of, or `null` for a new
session. Reject the append with an `FxFencedError` when `expected` is not the
cursor of the last stored record, so that a second agent writing the same
session stops the first instead of interleaving with it. `idempotencyKey` is
unique to each write, so a store that retries a write can return the stored
record's cursor instead of storing it twice.

`createFxAgent()` calls `load()` once. Resolve to the latest checkpoint, if any,
and the records stored after it, oldest first, each with its cursor. Resolve to
`{}` for a session with nothing stored. libfx skips any record the checkpoint
already covers.

libfx waits for the store only where a crash could otherwise lose work or
repeat it: the first record of each turn, which holds the prompt, is stored
before the model sees it, and a response's tool calls are stored before any of
them starts. Other appends are not waited for, so a turn's `result` can settle
before its last records land, and `agent.close()` waits for every append. If
`append` rejects, libfx stops the current turn at once: it starts no further
model request or tool call and writes nothing more. The turn fails with an
error whose `code` is `FX_JOURNAL_APPEND_FAILED` and whose `cause` is your
error, and the agent refuses later prompts. When no turn was left to report
the failure, `close()` rejects with it. A model request the turn started while
the failed append was in flight can still complete.

When the store has `saveCheckpoint()`, libfx saves a checkpoint after a turn
ends once the records stored since the last checkpoint reach
`checkpointAfterBytes` (default 1 MiB). `through` is the cursor of the last
record the checkpoint covers, so `load()` can return that checkpoint and only
the records after it, and the cost of opening a session stays bounded as its
history grows. libfx takes a checkpoint only while no turn is running. A saved
checkpoint emits a `checkpoint.save` event. A failed save emits
`checkpoint.error` and changes nothing: the records still restore the session,
and the next turn's end tries again. Deleting the records a checkpoint covers
is up to the store.

The records a load reads, after libfx drops the older progress of an open
turn, must fit in 4 MiB of JSON, a checkpoint in 4 MiB, and the history in
1,024 turns. Otherwise `createFxAgent()` rejects with an error whose `code` is
`FX_JOURNAL_TOO_LARGE`. libfx refuses records that repeat, skip, or do not
parse, and `createFxAgent()` rejects with the reason and the `code`
`FX_JOURNAL_INVALID`. For records written by a newer libfx, it rejects with an
`FxJournalVersionError`, whose `code` is `FX_JOURNAL_VERSION`. Each libfx
release resumes the sessions and checkpoints that the release before it saved,
so upgrade the processes that read a session before the ones that write it.

AI Gateway keys session affinity and prompt caching to the session's id. libfx
picks a new id for each agent unless you pass `sessionId`, so give a restored
session the id it had before. An id is 1 to 255 letters, digits, `.`, `_`, or
`-`. `agent.sessionId` is the id the agent uses.

If the last process stopped during a turn, `agent.resume()` continues that
turn with no new input and returns it, like `prompt()`. The model is told
"Resuming from unexpected session interruption.". A tool call that was
running does not run again: it comes back answered with an error saying it may
have partly run, and the model decides whether to check its effects, call it
again, or ask the user. A turn that fails or is cancelled ends in the journal
as it does in the agent, so only a stopped process leaves one to resume.
`resume()` returns `null` when the session holds no open turn and no held
follow-up, so a host can call it until it does every time it opens a session:

```js
const agent = await createFxAgent({ apiKey, model, persistence, sessionId, tools });
for (let turn = agent.resume(); turn; turn = agent.resume()) {
  for await (const event of turn) console.log(event);
  await turn.result;
}
```

When your host knows a call never ran, such as one it handed to another
process before the call did anything, pass `resume({ onAmbiguous })`. libfx
calls `onAmbiguous({ callId, name, input })` once for each call the turn left
running, and each call it returns `"rerun"` for runs again under the same call
id before the turn continues. Every other call keeps the answer that it may
have partly run.

Calling `prompt()` instead ends the open turn as interrupted and starts a new
one.

Give a prompt a `turnId` when the same request can reach libfx more than once,
such as from a queue that delivers it again after a crash. When the open turn
has that id, `prompt(input, { turnId })` continues it as `resume()` does, and
takes `onAmbiguous` the same way. When
the session's last turn ended with that id, it returns a turn that has already
ended, with the stop reason `end_turn`, without calling the model. Any other id
starts a new turn. A turn id is 1 to 128 letters, digits, `.`, `_`, or `-`.
Without one, libfx names the turn. `turn.id` is the turn's id, and each tool
call receives it.

To move a running session to another process, call
`turn.cancel({ reason: "handoff" })`. The turn stops at once, like any
cancellation, but libfx stores nothing more, so the journal keeps the turn
open and the agent that opens the session next continues it with `resume()`.
The handed-off agent then refuses `prompt()`, `resume()`, and `followUp()`;
close it. A handoff needs persistence.

Pass `persistence` instead of a `checkpoint` option; the two cannot be
combined. Like a checkpoint, persistence holds conversation history only:
resupply models, credentials, instructions, tools, MCP clients, and skill
records when you create the agent. A resumed turn continues under the tools the
new agent has. `createMemoryPersistence()` keeps the records and the latest
checkpoint in memory as `persistence.records` and `persistence.checkpoint`,
which suits tests and hosts that copy them to their own storage. It fences an
append whose `expected` cursor is not its last record's, and returns the stored
cursor for a repeated `idempotencyKey`. `FxFencedError` is exported by `libfx`;
its `code` is `FX_FENCED`, which a store of your own can use for the same case.
`FxJournalVersionError` is exported by `libfx` too.

### Workflow Worlds and other stores

libfx depends on no storage package. A store maps its methods onto the storage
your app already uses, such as a database table, a Durable Object, or a
Workflow World. `sdk/tests/world-persistence.mjs` in the fx repository is a
store over a World: each record and checkpoint is a `step_created` event in
one World run, and a record's cursor is its event slot. A World commits a write
at the next free slot rather than refusing it, so that store also keeps the
cursor each record continued, reads only the unbroken chain of records, and
fences a write that lands after another writer's record for the same cursor.

libfx does not schedule turns. To run each turn in a fresh function
invocation, enqueue it with your app's queue, such as `World.queue()`, and in
the handler create the agent with the same `persistence` and `sessionId`, then
call `prompt(input, { turnId })` or `resume()`.

## Models

Model discovery is explicit and does not create an Agent or load native or Wasm
artifacts:

```js
import { listModels } from "libfx";

const models = await listModels({
  apiKey: process.env.AI_GATEWAY_API_KEY,
});
```

`listModels()` performs one bounded Gateway request and returns sorted, unique
language-model IDs. It accepts the same optional `fetch` override as the Agent
API.

An agent reads the AI Gateway model catalog to learn what its model supports,
such as image input, reasoning effort, and output limits, and those details
shape every request. It fetches the catalog through your `fetch`. If that
request fails, for example behind a proxy that only forwards chat requests,
the agent cannot confirm the model's capabilities and refuses image prompts.
Pass `modelCatalog` to supply the catalog instead: the entries from
`https://ai-gateway.vercel.sh/coding-agent/v1/models`, either the response's
`{ data }` or the array, or only the entries for the models you use. The agent
then makes no catalog request, so every process that receives the same
entries builds the same requests:

```js
const agent = await createFxAgent({ apiKey, model, modelCatalog });
```

## JavaScript tools and instructions

```js
const agent = await createFxAgent({
  apiKey,
  model,
  instructions: "Keep answers concise.",
  tools: [{
    name: "lookup",
    description: "Look up a value.",
    inputSchema: {
      type: "object",
      properties: { key: { type: "string" } },
      required: ["key"],
    },
    async execute(input, { signal }) {
      return database.get(input.key, { signal });
    },
  }],
});
```

Gateway web search can run at the provider instead of in the JavaScript host.
Mark its canonical tool name with `providerExecuted: true` and omit `execute`:

```js
const agent = await createFxAgent({
  apiKey,
  tools: [{ name: "web_search", providerExecuted: true }],
});
```

The kernel supplies the canonical schema and Gateway advertisement. Currently
`web_search` is the supported provider-executed descriptor; unknown or local
names reject agent creation. Provider-executed tools do not
call host code or require a separate provider key; their `tool_start` and
`tool_end` events, results, and checkpoint history use the same turn contract.
Their built-in permission policy is enforced when the request is projected, as
there is no local call-time effect to approve.

`tools` may also be an object keyed by tool name, such as
`tools: { lookup, save }`, where each value is a descriptor without `name`.
A descriptor that does include `name` must match its key.

When one model response calls several tools, the native backend runs them at
the same time and returns their results to the model in the order it called
them. Mark a tool `writes: true` when its calls must not overlap others: it
starts after every earlier call in the response finishes, and later calls
wait for it. WebAssembly runs calls one at a time. Every call still goes
through its own permission check before any of them starts.

`execute` receives `{ signal, turnId, callId }`. `turnId` is the turn's id and
`callId` is the model's id for the call. Both stay the same after a restore, so
a tool with an external effect can use them as an idempotency key.

With persistence, libfx stores the calls of a response before any of them
starts, so no call runs without a record that it was about to. If the process
stops while calls are running, `resume()` answers each of them with an error
saying it may have partly run, so the model checks before calling it again,
unless `onAmbiguous` has the call run again.
When a tool rejects with an empty message, the model receives a non-empty error
so the provider does not refuse the conversation.

For ordinary tools, the JavaScript host is the authority for effects. The same
descriptors, schemas, cancellation, results, and events are used by N-API and
WebAssembly.
Cancelling a prompt aborts its tools' signals and stops waiting for their
callbacks. Late results and rejections are ignored. Tools remain responsible
for stopping their own work when their signal is aborted.

A host tool may use any name, including the kernel's builtin names such as
`write_file` and `edit_file`: the kernel routes by the registered executor, so
a host-defined `write_file` calls the host's `execute()` rather than the
builtin file mutation.

Ordinary objects returned by tools are JSON text. To return rich image content,
use the typed result:

```js
return {
  type: "libfx.tool-result",
  text: "Original is available through the host image tools.",
  images: [
    { type: "image", mimeType: "image/png", sourceRef: "uploads:screenshot-1" },
    // A prepared copy may also include data: base64Png.
  ],
};
```

Tool images require `mimeType` and accept base64 `data`, or a `sourceRef` with no
`data`. They do not accept raw bytes or Blobs and do not run `resizeImage`.
References use the same validation, ownership, recovery feedback, and checkpoint
rules as prompt images. A result may contain up to 8 images, each with up to
5 MiB of base64-encoded data. Its text, encoded images, and metadata must fit
within the 8 MiB result/frame bound. Referenced data is omitted if those bounds
would overflow; an unreferenced oversized result remains a tool error.

Instructions are limited to 64 KiB of UTF-8 text, including text assembled by
the MCP and skills adapters. They are the complete host-owned system context:
libfx adds no hidden base prompt, and omitting `instructions` sends no system
message.

## MCP

`libfx/mcp` accepts a host-owned MCP client. Transport, authentication,
elicitation, and cleanup remain outside the kernel. The client uses the MCP
TypeScript SDK v1 signature: `callTool(params, resultSchema?, options?)`, with
cancellation passed in `options`. Tool text and structured data
reach the model together. PNG, JPEG, GIF, and WebP tool images reach models that
advertise image input support; other models receive an explicit omission notice.
Images are retained in checkpoints within the existing checkpoint size limit.
Each image may contain up to 5 MiB of base64 data, with at most eight images and
an 8 MiB result frame. Ordinary host tool objects remain JSON text. Resource and
prompt options supply text instructions; non-text context has an omission notice.
Tool catalogs are paginated up to the existing 64-tool bound. Tool names are
normalized for model APIs, with collisions kept distinct and original names used
for calls to the MCP client. Each tool description and JSON schema may contain up
to 64 KiB, within the control message's 8 MiB limit.

```js
import { createMcpAdapter } from "libfx/mcp";

const mcp = await createMcpAdapter(client, {
  prefix: "github_",
  resources: ["repo://instructions"],
  prompts: ["review"],
});

const agent = await createFxAgent({
  apiKey,
  model,
  tools: mcp.tools,
  instructions: mcp.instructions,
});

// ...
await agent.close();
await mcp.close();
```

## Skills

Use `libfx/skills` for already-loaded records or `libfx/skills/node` to load a
`SKILL.md` explicitly in Node or Bun.

```js
import { loadSkillFile } from "libfx/skills/node";
import { createSkillsAdapter } from "libfx/skills";

const record = await loadSkillFile("./skills/review/SKILL.md");
const skills = createSkillsAdapter([record]);
const agent = await createFxAgent({ apiKey, model, ...skills });
```

## Backends

```js
await createFxAgent({ apiKey, backend: "auto" });   // native, then Wasm fallback
await createFxAgent({ apiKey, backend: "native" }); // require N-API
await createFxAgent({ apiKey, backend: "wasm" });   // require Wasm + JSPI
```

CommonJS applications can load the same Node API with `require("libfx")`. The
package chooses its generated CommonJS entry automatically and keeps asset
paths relative to the installed package.

Use `getBackendInfo()` to inspect backend availability without creating an
Agent or terminal:

```js
import { getBackendInfo } from "libfx";

const info = await getBackendInfo({ surface: "agent", backend: "auto" });
// {
//   surface: "agent",
//   backend: "native" | "wasm-jspi" | "unavailable",
//   attempts: [{ backend, available, reason }]
// }
```

`surface` is `agent` by default and may also be `terminal`. `backend` has the
same `auto`, `native`, and `wasm` selection as the factories. `nativeAddon` and
`wasm` select explicit assets with the same meanings as their factory options.
The probe loads and validates the native module or compiles the selected Wasm
asset, then stops. It does not create a core, open a runtime socket, read
credentials, start a model request, or write session state. A remote Wasm
source can perform its normal asset fetch.

Expected environmental failures resolve as structured attempts. Invalid
options reject with `TypeError`. The stable reason codes are:

| Code | Meaning |
| --- | --- |
| `LIBFX_UNSUPPORTED_PLATFORM` | No packaged native addon supports the current platform and architecture. |
| `LIBFX_NATIVE_ARTIFACT_MISSING` | The selected native addon file is absent. |
| `LIBFX_NATIVE_LOAD_FAILED` | Node could not load the selected native addon. |
| `LIBFX_NATIVE_API_MISMATCH` | The addon API version is incompatible. |
| `LIBFX_NATIVE_SURFACE_MISSING` | The addon does not implement the selected Agent or terminal surface. |
| `LIBFX_NATIVE_DISABLED` | `nativeAddon: false` disabled native loading. |
| `LIBFX_JSPI_UNAVAILABLE` | The current JavaScript runtime does not provide JSPI. |
| `LIBFX_WASM_LOAD_FAILED` | The selected Wasm asset could not be loaded or compiled. |

The optional `causeCode` field retains a Node error code such as `ENOENT` or
`ERR_DLOPEN_FAILED` when one exists. Probe success establishes backend loading
only; it does not validate credentials, a future Agent initialization, or a
model request.

Within one loaded SDK module, libfx compiles each stable Wasm source once and
creates a separate WebAssembly instance for every Agent. Agent memory, history,
tools, cancellation, and shutdown remain isolated. Workers and separate
processes maintain their own module caches, as do the ESM and CommonJS entries.

Node factories and `getBackendInfo()` also accept a `wasm` Promise resolving
to an HTTP(S) URL string, a `Response`, Wasm bytes, or a compiled
`WebAssembly.Module`. Asset resolver failures propagate from factories and
appear as `LIBFX_WASM_LOAD_FAILED` in diagnostics.

Node.js 20+ is supported. Browser WebAssembly requires a JSPI-capable browser.
The Linux x64 and arm64 native addons require glibc 2.34 or newer. Native
agents do not require JSPI or experimental Node flags.
Some Node versions require `--experimental-wasm-jspi`.
Bun 1.4.2 is the tested recommendation for Bun's WebAssembly backend.
Bun 1.3.14 can crash when a hot WebAssembly loop resumes through JSPI during
JIT tier-up.

### Next.js and Vercel

Create agents in a server route using the Node.js runtime. Import `libfx`
normally; the package includes its native assets and exposes both ESM and
CommonJS Node entrypoints. Native agents support Next.js 15 with webpack and
Next.js 16 with webpack or Turbopack, without `serverExternalPackages` or manual
native-file inclusion. Webpack's emitted assets are resolved relative to the
server bundle, including standalone builds with a custom `distDir` or `assetPrefix`.

This native setup does not require JSPI. Explicit WebAssembly use still needs
JSPI and available Wasm assets; Next.js's standalone tracer excludes `.wasm`
files, so a standalone Wasm host must supply those assets separately.

```js
import { createFxAgent } from "libfx";

export const runtime = "nodejs";

export async function POST(request) {
  const { prompt } = await request.json();
  const agent = await createFxAgent({ apiKey: process.env.AI_GATEWAY_API_KEY });
  try {
    let text = "";
    const turn = agent.prompt(prompt, { signal: request.signal });
    for await (const event of turn) {
      if (event.type === "text_delta") text += event.delta;
    }
    await turn.result;
    return Response.json({ text });
  } finally {
    await agent.close();
  }
}
```

Use the application's normal authentication and request limits around the
route. JavaScript tools and MCP clients remain host-owned and must be supplied
when creating an agent, including after checkpoint restoration. The native
backend does not enable the CLI's built-in shell or filesystem tools.

## Interactive terminal

`createFxTerminal()` remains a separate terminal harness API. In browsers,
connect it to xterm.js with `xtermAdapter()`:

```js
import { createFxTerminal, xtermAdapter } from "libfx/browser";

const runtime = await createFxTerminal({
  terminal: xtermAdapter(term),
  env: { AI_GATEWAY_API_KEY: "<short-lived credential>" },
});

await runtime.interactive;
```

The xterm adapter preserves browser-style composer editing for Shift+Enter,
Command+A, Command+C, Command+X, Command+Z, and Command+Shift+Z. Shift+Enter
inserts a newline without submitting. A click inside the visible composer moves
its caret; pointer drags remain xterm terminal-output selections.
When xterm already has an output selection, Command+C copies that selection
instead of the composer selection.

The terminal runtime exposes `interactive`, `exited`, `write`, `resize`, and
`abort`. Terminal session, config, OAuth, prompt-history, clipboard, URL, and
workspace stores remain terminal-only host integrations. Clipboard copy writes
through the host `clipboard.writeText(text)` adapter and defaults to
`navigator.clipboard`.

During `/compact` and automatic compaction, the terminal shows a live
`Compacting` activity row with elapsed time. Input and cancellation remain
responsive while the summary request is pending. Compaction progress and
outcomes do not add transcript entries, including cancellation after resume.
Stored snapshots retain cancellation-origin metadata; keep them opaque and
resume with the same or a newer SDK build. Older snapshots remain readable.

## Security

Treat `nativeAddon` and `gatewayChatUrl` as trusted host
configuration. Do not embed long-lived credentials in public browser code.
Host tool functions, MCP clients, and skill loaders retain their own authority;
libfx validates and sequences them but does not grant operating-system access.
