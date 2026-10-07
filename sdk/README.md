# libfx

`libfx` is the fx agent kernel for JavaScript hosts. You create an agent once
and open sessions on it. libfx saves each session as it runs, so a crash, a
function timeout, or a redeploy continues the conversation instead of losing
it. The same code runs on your machine and on Vercel.

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

const agent = createFxAgent({
  model: "google/gemini-2.5-flash-lite",
  instructions: "Answer in one paragraph.",
});

const turn = agent.session().prompt("Explain this project.");

for await (const event of turn) {
  if (event.type === "text_delta") process.stdout.write(event.delta);
}

console.log(await turn.result); // { messageId, stopReason, usage }
await agent.close();
```

`createFxAgent()` returns at once and does no I/O until a session runs a turn.
`apiKey` is optional. Without it, libfx uses `AI_GATEWAY_API_KEY`, then on
Vercel the deployment's OIDC token. `model` defaults to fx's built-in model.
Tools, MCP clients, and skills are agent options, described in
[JavaScript tools and instructions](#javascript-tools-and-instructions) and the
sections after it.

Because nothing loads before a session runs, an option the backend rejects,
such as an effort level the model does not support, fails that session's
first turn rather than the `createFxAgent()` call. The turn's `result` has the
stop reason `error` and the reason in `error`, and `onEvent` receives
`session.error`.

An agent is the configuration its sessions run under. Every process that
creates an agent with the same options can run the same sessions, so create
one agent for your server and open a session per conversation.
`agent.close()` waits for the turns this process is running, then lets their
sessions go.

### Sessions

`agent.session(id)` opens the session `id`, and `agent.session()` starts a new
one. Opening a session reads nothing; its first prompt does. A new session's
`id` is set once that prompt is accepted, so read it from `turn.accepted`:

```js
const turn = agent.session().prompt("Plan the migration.");
const { sessionId } = await turn.accepted;

// Later, in any process:
const followUp = agent.session(sessionId).prompt("Start with the schema.");
```

A session id is 1 to 128 letters, digits, `.`, `_`, or `-`. On `local()` and
`vercel()`, new ids come from the World, and an id you choose must be `wrun_`
followed by 10 to 64 letters or digits. `agent.prompt()` and
`agent.checkpoint()` use a session the agent opens for itself, for code that
holds one conversation.

One process runs a session's turns at a time, one turn after another. A
second process that receives a prompt for a busy session queues it behind the
running turn. Pass `context` to hand JSON to the session's tools:
`agent.session(id, { context: { userId } })` gives every tool call
`context` beside its `executionId`. Each turn runs with the context of the
`session()` call whose prompt or steer started it, and a call without
`context` gives its turns none.

### Turns

`session.prompt(input)` queues `input` as the session's next turn and returns
a view of that turn. Prompt input is a string or an array of content blocks,
as described in [prompt input](#prompt-input), except that image data must be a
base64 string, because the prompt is stored as JSON before it runs. A turn
view has:

- `messageId`: the turn's id, which libfx chooses unless you pass one.
- `accepted`: resolves to `{ messageId, sessionId }` once the prompt is stored,
  or at once for a prompt whose `signal` had already aborted, which is never
  stored.
- `result`: resolves to `{ messageId, stopReason, usage }` when the turn ends.
- Async iteration over the turn's events, as
  [model and tool events](#prompt-input) describes.
- `readable`: the same turn as an NDJSON `ReadableStream` that a route can
  return as its response body. Each line is an event with a `cursor`.

Dropping a turn view cancels nothing: the turn runs to its end whether or not
anyone reads it. Call `session.cancel()` to stop it. A prompt's `signal`
cancels that prompt's turn when it aborts, whether the turn is running or still
waiting behind another, and never a later turn. A prompt whose `signal` had
already aborted is not stored: its `result` resolves with the stop reason
`cancelled`.

Give a prompt a `messageId` when the same request can reach your server more
than once, such as a client retry. A second `prompt()` with an id the session
already accepted runs nothing: while that turn runs, the view follows it, and
after it ends, `result` resolves to its outcome with `repeated: true`. When the
process that ran the turn stopped before writing how it ended, `result`
resolves with the stop reason `unknown` after 30 seconds. An id follows the
session id rule.

`session.stream(cursor)` returns every event the session has produced from
`cursor` on, as NDJSON, and stays open for the events after them. Any process
can serve it, so a browser that loses its connection reconnects with the last
`cursor` it saw and continues where it stopped. Beside the turn events, the
stream marks each turn with `turn_start` and `turn_end`, a continued turn with
`turn_resume`, and a turn that stopped for a function deadline with
`turn_yield`. `turn_start` and `turn_resume` carry the `sessionId`, so a client
that started a new session learns its id from the first line of
`turn.readable`.

Each line carries the `epoch` of the lease its writer held, and epochs only
rise over a session's life. A worker that was replaced while it ran can still land lines late, because the World accepts
them. A worker that takes a turn over writes its `turn_resume` line before it
goes on, and every reader hides a line whose epoch is lower than one before
it, so the replaced worker's later lines never show and every reader, on any
server and after any refresh, shows the same lines. A replaced worker's line
that lands in the moment between its successor's claim and that `turn_resume`
line still shows; only a World that refuses stale stream writes closes that
gap.

`session.steer(text)` adds guidance to the running turn at its next model
request, or to the next turn when none is running. `session.resume()`
continues a turn a stopped process left open and returns its view, whose
`result` has the stop reason `idle` when there was none. A prompt also
continues an open turn before it runs, so most hosts never call `resume()`.

### Durability

The `durability` option chooses where sessions live. Without it, libfx picks
one from the environment:

| Environment | Durability | Sessions live in |
| --- | --- | --- |
| Vercel, where `VERCEL` is set | `vercel()` | Vercel's World, the store and queue behind Vercel Workflow |
| Node.js elsewhere | `local()` | files in `FX_SESSIONS_DIR`, or `$TMPDIR/libfx/sessions` |
| Browsers | `memory()` | this page's memory |

```js
import { createFxAgent, memory } from "libfx";
import { local } from "libfx/durable-local";

createFxAgent({ durability: local({ dir: ".fx/sessions" }) });
createFxAgent({ durability: memory() }); // nothing survives the process
```

`libfx/durable-local` and `libfx/durable-vercel` carry their World inside
them, and libfx loads one only when a session first needs it, so your app
installs no other package and an app with no sessions loads neither.

libfx records each step of a turn as it happens. A turn's prompt is stored
before the model sees it, and a tool call with effects is stored before it
runs, so a crash never loses a prompt the caller was told was accepted and
never repeats a tool call silently. Other records are written while the model
works, without holding up the turn. A session also saves a checkpoint at the
end of every turn and wherever a turn yields, so the process that continues it
reads the checkpoint and the few records after it, not the whole history.

When the process running a turn stops, the next process to receive work for
the session continues the turn from its last record:

- On `local()`, a session held by a process that died is free at once.
- On `vercel()`, a turn holds its session until its function's deadline. When
  the deadline is near, libfx stops before the next model request and saves
  the turn, and the next invocation continues it. A model request or tool
  call still running shortly before the deadline is cut off: `onEvent`
  receives `session.deadline`, and the next invocation continues the turn,
  running a cut-off idempotent call again and telling the model about any
  other. So a process never runs on after the deadline its hold ends at. A
  process that freezes and wakes after another took its session over stops
  at its next write, and `onEvent` receives `session.fenced`. Until then it
  can finish a model request or a call to an idempotent tool; it never starts
  a tool with effects, because that waits for its record to be stored.
- When a write fails for any other reason, or the engine running a turn stops,
  `onEvent` receives `session.error`, and the same queue message runs the
  session again with a new engine. A turn whose engine stops 3 times is
  cancelled, and the prompts behind it run; one that never got started ends
  with an error instead. When the engine stops twice more, even to cancel the
  turn, the session can run no more turns: the turn and every prompt sent to
  the session end with an error. A turn whose engine stops after storing its
  end resolves with the stop reason `unknown`.
- When an engine cannot open, the turn waiting on it ends with an error, and
  each later engine that cannot open ends the next waiting prompt the same
  way. A started turn that ended this way stays open in the session, and
  `session.resume()` answers `idle` for it. The next prompt's engine first
  continues it, or cancels it when it was cancelled or its engine kept
  stopping, and then runs that prompt.
- On `memory()`, sessions end with the process.

The model is told when its turn was interrupted, so it can check what
happened before going on. A turn that stopped at a model request for a
deadline continues without that notice; one whose call was cut off gets it.

A durability holds conversation history only. Every process supplies the
model, credentials, instructions, tools, MCP clients, and skills when it
creates the agent. Every checkpoint records the libfx version, tool set, and
model that saved it. When a saved session, or a checkpoint passed as
`checkpoint`, was saved under different ones than the agent now has, it still
loads, and `onEvent` receives a `checkpoint.mismatch` event naming what
changed.

`session.checkpoint()` returns the session's history as opaque bytes, read
without changing the session. Pass them as `checkpoint` to start a new agent's
own session from them, for example to move a conversation between
durabilities.

### Tools with effects

When a process stops while a tool call runs, libfx cannot know whether the
call finished. Mark a tool `idempotent: true` when running it twice is safe,
such as a lookup:

```js
const tools = [
  { name: "get_order", idempotent: true, inputSchema, async execute(input, { executionId }) { /* ... */ } },
  { name: "refund_order", inputSchema, async execute(input, { executionId }) { /* ... */ } },
];
```

An idempotent call that was running runs again when the turn continues. Any
other call never runs again on its own: the turn continues at once, and the
model receives that call's result as an error saying it may have partly run,
so it can check the call's effects before calling it again or ask the user.

`executionId` is the same for a call each time it runs, including after a
crash. Pass it to the service the tool calls, as an idempotency key, so a call
that runs again changes nothing twice. Calls to idempotent tools also start
without waiting for their record to be stored.

## Model options

Model configuration groups the model ID and model-specific options:

```js
const agent = createFxAgent({
  model: { id: "anthropic/claude-opus-5.5-fast", effort: "low", fast: true },
});
```

Agent configuration uses named options; `env` is reserved for
`createFxTerminal()`. A string `model` remains supported as shorthand.
Top-level `effort` and `fast` are deprecated but remain supported with a
string model or no model; they cannot be mixed with a model object. New code
should use the model object.

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

## A single engine

`createFxEngine()` is the kernel under `createFxAgent()`: one conversation,
held in the memory of the process that runs it, with no queue and no session
store. Use it to run turns inside one request and keep nothing, or to keep a
conversation in storage of your own through [persistence](#persistence). It
takes the same model, tool, MCP, and skill options, `apiKey` is required, and
it resolves once its backend has loaded. In this section, `agent` is an engine:

```js
import { createFxEngine } from "libfx";

const agent = await createFxEngine({ apiKey: process.env.AI_GATEWAY_API_KEY, model });
```

### Prompt input

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
`createFxEngine()`. Transport or message-decoding failures reject the result
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

const agent = await createFxEngine({
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
// Supply prepareImage in createFxEngine({ tools: [prepareImage], ... }).
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
const restored = await createFxEngine({ apiKey, model, checkpoint });
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
import { createFxEngine, createMemoryPersistence } from "libfx";

const persistence = createMemoryPersistence();
const agent = await createFxEngine({ apiKey, model, persistence, sessionId: "support-42" });
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

`createFxEngine()` calls `load()` once. Resolve to the latest checkpoint, if any,
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
ends or yields once the records stored since the last checkpoint reach
`checkpointAfterBytes` (default 1 MiB). A checkpoint where a turn yielded
holds the open turn, and the next load continues it. `through` is the cursor of the last
record the checkpoint covers, so `load()` can return that checkpoint and only
the records after it, and the cost of opening a session stays bounded as its
history grows. libfx takes a checkpoint only while no turn is running. A saved
checkpoint emits a `checkpoint.save` event. A failed save emits
`checkpoint.error` and changes nothing: the records still restore the session,
and the next turn's end tries again. Deleting the records a checkpoint covers
is up to the store.

The records a load reads, after libfx drops the older progress of an open
turn, must fit in 4 MiB of JSON, a checkpoint in 4 MiB, and the history in
1,024 turns. Otherwise `createFxEngine()` rejects with an error whose `code` is
`FX_JOURNAL_TOO_LARGE`. libfx refuses records that repeat, skip, or do not
parse, and `createFxEngine()` rejects with the reason and the `code`
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
const agent = await createFxEngine({ apiKey, model, persistence, sessionId, tools });
for (let turn = agent.resume(); turn; turn = agent.resume()) {
  for await (const event of turn) console.log(event);
  await turn.result;
}
```

When your host knows a call never ran, such as one it handed to another
process before the call did anything, pass `resume({ onAmbiguous })`. libfx
calls `onAmbiguous({ executionId, name, input })` once for each call the turn
left running, and each call it returns `"rerun"` for runs again under the same
`executionId` before the turn continues. Every other call keeps the answer that it may
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
Without one, libfx names the turn. `turn.id` is the turn's id.

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
const agent = createFxAgent({ apiKey, model, modelCatalog });
```

## JavaScript tools and instructions

```js
const agent = createFxAgent({
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
const agent = createFxAgent({
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

`execute` receives `{ signal, executionId }`, plus `context` when the turn
has one. `executionId` is the model's id for the call and stays the same when
the call runs again after a crash, so a tool with an external effect can pass
it on as an idempotency key. [Tools with effects](#tools-with-effects)
describes which calls run again.
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

const agent = createFxAgent({
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
const agent = createFxAgent({ apiKey, model, ...skills });
```

## Backends

```js
createFxAgent({ apiKey, backend: "auto" });   // native, then Wasm fallback
createFxAgent({ apiKey, backend: "native" }); // require N-API
createFxAgent({ apiKey, backend: "wasm" });   // require Wasm + JSPI
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

Create one agent for the server and open a session per request. The route
returns the turn's stream and never runs the agent itself:

```js
// lib/agent.js
import { createFxAgent } from "libfx";

export const agent = createFxAgent({ model: "anthropic/claude-haiku-4.5", tools });
```

```js
// app/api/chat/route.js
import { agent } from "@/lib/agent";

export async function POST(request) {
  const sessionId = new URL(request.url).searchParams.get("sessionId") ?? undefined;
  // Check that the caller may use this session.
  const turn = agent.session(sessionId).prompt(await request.text());
  return new Response(turn.readable);
}

// Reconnects from any server.
export async function GET(request) {
  const params = new URL(request.url).searchParams;
  // The same check as POST.
  const stream = agent.session(params.get("sessionId")).stream(Number(params.get("cursor") ?? 0));
  return new Response(stream);
}
```

On your machine, the server runs each turn in its own process and keeps the
session with `local()`. On Vercel, `prompt()` stores the prompt and its
caller's `context` in the session, then sends Vercel Queues a message that
names it, and a separate invocation runs the turn while the `POST` response
streams it. If the route's
response ends first, the turn keeps running, and the client reconnects with
the last `cursor` it read.

Until Vercel's World can deliver queue messages to the function itself, mount
the agent's delivery route and subscribe it to libfx's queue topic in
`vercel.json`:

```js
// app/api/libfx/route.js
import { agent } from "@/lib/agent";

export const POST = agent.wakeHandler();
```

```json
{
  "functions": {
    "app/api/libfx/route.js": {
      "experimentalTriggers": [{ "type": "queue/v2beta", "topic": "__libfx_wkf_workflow_session" }]
    }
  }
}
```

The delivery route is a public URL, so libfx never trusts a delivery's body.
A queue message carries only the session, a message id and its kind, never an
input or a `context`. The route acts only on a message whose session already
holds it, and runs only what the session holds, as the `prompt()` call that
stored it gave. Any other request is dropped before anything is written,
whether or not its session exists. Authorize callers and choose their
`context` in your own routes, where they call `prompt()`.

The delivery route's maximum duration bounds each invocation. libfx stops a
turn 30 seconds before the deadline, at its next model request, and cuts off a
call still running 2 seconds before it; either way the same queue message runs
the rest of the turn in a new invocation. Pass
`durability: vercel({ reserveMs })` from `libfx/durable-vercel` to change that
margin. libfx authenticates to the AI Gateway with the deployment's OIDC token
unless you pass `apiKey` or set `AI_GATEWAY_API_KEY`.

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

Pass `args: ["--fast"]` to request Fast mode. The terminal loads model
capabilities when its first Fast or Ultra turn starts, without adding catalog
requests to startup. After the catalog loads, `/fast` toggles Fast for later
turns. Models without Fast support use their normal routing.

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

A terminal with a `workspace` adapter loads AGENTS.md project instructions from
it the way the CLI reads them from disk: `<home>/.fx/AGENTS.md`,
`<root>/AGENTS.md`, and, when `root` is below `home`, the `AGENTS.md` files in
the directories between them. Provide them through an optional `readFile`
method:

```js
const workspace = {
  info: { version: 1, root: "/workspace", cwd: "/workspace", home: "/home/visitor", gitAvailable: false, ephemeral: true },
  permission: "allow-sandboxed",
  exec({ command, cwd, signal, timeoutMs, outputLimitBytes }) { /* run one command */ },
  async readFile({ path, signal }) {
    // Return a string, UTF-8 bytes (a Uint8Array or ArrayBuffer), or null when the file does not exist.
  },
};
```

fx calls `readFile` only for absolute `AGENTS.md` paths inside `root` or
`home`. Each read has a 10-second deadline, the interrupt key aborts it through
`signal`, and the CLI's project instruction size limits apply. Without
`readFile`, fx tells the model that the workspace's project instructions were
omitted and records the omission in the full transcript.

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
