# libfx

`libfx` is the small fx agent kernel for JavaScript hosts. One agent is one
conversation with streaming prompts and optional host-owned execution journaling.
Plain agents keep their history in memory. Journal agents expose explicit
checkpoint, suspend, resume, and abandon controls.

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
`createFxTerminal()`.

The host selects the model. Agent creation does not fetch the Gateway model
catalog. Prompting can resolve model capabilities and context capacity through
the supplied `fetch`; fx caches that metadata for the agent.

`onEvent` receives runtime diagnostics separately from model output. Transport
events report request start, response status and elapsed time, safe Gateway
request metadata, and failures. Credentials and raw headers are never included.

libfx makes at most one automatic retry after a retryable transport failure and
only before model output or tool effects escape. Cancellation prevents a retry.

`prompt(input, { signal? })` accepts a string or text/resource blocks. It
returns an async iterable of normalized events:

- `text_delta`
- `reasoning_delta` when supplied by the provider
- `tool_start`
- `tool_end`

Consume the turn while it runs, then await `turn.result`. Output is lossless and
backpressured: a slow reader pauses production instead of growing an unlimited
event queue. Awaiting only `turn.result` can wait for an unread stream to drain.
If you only need the result, explicitly discard events:

```js
const turn = agent.prompt("Update the index.");
for await (const _ of turn) {}
const result = await turn.result;
```

A turn has one event consumer. Breaking out of its iterator cancels the turn;
`turn.cancel()` and `agent.close()` also release blocked output. Transport or
message-decoding failures reject the result instead of returning success with
missing text.

SDK requests are limited to 8 MiB including their encoded request envelope.
Native transport buffers at most 8 MiB of output bytes. Unread SDK events apply
backpressure at 1 MiB of encoded messages or 256 events. One message can exceed
that threshold when the queue is empty; an individual encoded ACP message is
limited to 64 MiB on both backends. These are transport bounds, not a total
answer-size limit or a bound on retained conversation history.

Only one execution may run at a time. An already-aborted signal on a plain
agent returns `cancelled` without a model request or a history change.

### Journal API (development)

The journal API described here is under qualification in this source tree.
Existing releases that expose `checkpoint` and `onCheckpoint` retain their
versioned API; do not apply these migration instructions to those releases.
Native and Wasm cores must advertise journal version 1 before the SDK creates
a durable session. An incompatible core is rejected.

Supply both `journal`, an iterable or async iterable of entries, and
`onEntry(entry)`, a callback whose resolution means the exact entry is durable.
Each entry is `{ seq, kind, bytes: Uint8Array, hash }`. The core assigns its
sequence, identities, and hash. Preserve them and the exact bytes.

The following Node example uses a file that the application owns exclusively.
The containing directory is synced when the file is created, and each append
is synced before acknowledgement. A production host must enforce one writer
and preserve the journal after an uncertain write.

```js
import { open } from "node:fs/promises";
import { createFxAgent } from "libfx";

const file = await open("./conversation.journal", "a+");
let agent;
try {
  const directory = await open(".", "r");
  try { await directory.sync(); } finally { await directory.close(); }
  const saved = await file.readFile("utf8");
  const journal = saved.split("\n").filter(Boolean).map((line) => {
    const entry = JSON.parse(line);
    return { ...entry, bytes: new Uint8Array(Buffer.from(entry.bytes, "base64")) };
  });
  agent = await createFxAgent({
    apiKey: process.env.AI_GATEWAY_API_KEY,
    journal,
    async onEntry(entry) {
      await file.writeFile(JSON.stringify({
        ...entry, bytes: Buffer.from(entry.bytes).toString("base64"),
      }) + "\n");
      await file.sync();
    },
  });
  const turn = agent.prompt("Explain this project.", { requestId: "explain-project-1" });
  for await (const event of turn) {
    if (event.type === "text_delta") process.stdout.write(event.delta);
  }
  console.log(await turn.result);
} finally {
  try { await agent?.close(); } finally { await file.close(); }
}
```

Loading records validates and restores state without calling a model or a tool.
The host must resupply credentials, instructions, tools, MCP clients, and skill
records. Keep required rich-input and tool-output artifacts available alongside
the journal. The journal contains sensitive conversation and execution data.

The acknowledgement boundaries are `turn_start`, `model_step`, `tool_result`,
`turn_end`, and `checkpoint`. A start precedes model admission; a complete model
decision precedes tool effects; each tool result precedes dependent work; and a
turn end precedes result resolution. No manual final checkpoint is needed to
record a completed journal turn. `onEntry` must await durable storage, rather than
queue a write or retain only an in-memory copy. It may call `status()` to inspect
the last acknowledged position; it must not await another operation on the same
agent. A rejected callback rejects the turn with `PersistenceUncertain`, retains
the callback error as `cause`, and fences the instance. Close it and reconcile
its authoritative storage before recreating an owner.

`model_step` also carries provider reservations, context compaction, and accepted
steering input. Reservations and compaction advance the durable sequence without
creating an assistant message. Steering preserves its message identities and any
interrupted response prefix before another model request. The transcript
projection handles these records and identifies drafts retired by steering;
compacting model context does not replace the saved conversation.

Automatic compaction records the retained model context before continuing. A
recreated owner restores that boundary and keeps the complete saved tool history.
Before execution, the core can lower the model-facing tool output limit to keep
enough journal space for the result and completion or abandonment of the turn.

Tool permission feedback projects as user messages with stable call-scoped IDs.

Journal prompts require a nonempty caller `requestId`. Retrying a completed ID
with the same input returns recorded semantic output without new effects or
storage callbacks. Retrying the current live ID attaches to its execution and
future events. Changed input raises `RequestConflict`; a restored pending
request raises `PendingTurnError` until the host explicitly resumes or abandons
it. A different ID does not retry an earlier request. Retained request mappings
are session-lived; this API has no request TTL or eviction setting. Provider
context records refer to the original saved input rather than rewriting it at
every model boundary. Existing records that contain the full input remain readable.

Each attached handle has one consumer, sharing the bounded event buffer. A slow
consumer backpressures all attached handles. Calling `cancel()` or leaving any
handle's iterator cancels their shared execution. An already-aborted journal
prompt rejects with `AbortError` before admission; it does not manufacture a
completed turn.

Journal `turn.result` resolves only after a durable turn end and executor/callback
cleanup. Its result is `{ ok: true, stopReason, usage? }` for success, or
`{ ok: false, reason, retryable, message, pendingTool? }` for a recorded failure.
Successful stop reasons are `stop`, `length`, and `tool_limit`; failure reasons
are `cancelled`, `interrupted`, `refused`, `provider_error`, and `timeout`.
`JournalConflict`, `PersistenceUncertain`, `PendingTurnError`, `RequestConflict`,
and `RecoveryRequired` are exported error classes with matching `name` and
`code`. Storage failures are errors, never ordinary tool `isError` results.

Journal event shapes preserve core identities:

- `turn_start`: `turnId`, `messageId`.
- `text_delta` and `reasoning_delta`: `key: { turnId, messageId, generationId }`,
  `ordinal`, and `delta`.
- `tool_start`: `turnId`, `messageId`, `callId`, `name`, and `input`.
- `tool_end`: `turnId`, `messageId`, `callId`, `content`, and `isError`.
- `turn_end`: `turnId` and `result`.

Completed retry streams are semantic replay, not a reproduction of original
network token chunks. Draft identities never authorize an effect or recovery.

### Checkpoints, projection, and compatibility

`await agent.checkpoint()` is idle-only. It appends a checkpoint through
`onEntry` and returns the same acknowledged `JournalEntry` shape, with
`Uint8Array` bytes. Restore from that checkpoint entry followed by every newer
entry. Never prune records until the checkpoint itself is acknowledged and
retains their transcript, outcomes, and request mappings. Keep receipts for
pending or uncertain tools, including when a provider's ordinary lookup window
has expired. Expiry does not establish that an effect never happened.

Pure transcript inspection does not load native or Wasm code:

```js
import { createProjection, readCheckpoint } from "libfx/transcript";

const projection = createProjection(journal);
const transcript = projection.transcript();
const recordedRequests = projection.requests(); // input hash, turn ID, completion, and recorded result
const candidate = projection.preview(nextEntry);
// After storing nextEntry, adopt candidate.projection and publish its delta.
const checkpointTranscript = readCheckpoint(checkpointEntry.bytes);
```

Projection validates entry integrity and transitions. `preview()` leaves its
source unchanged and returns the candidate projection, changed messages, and
completed draft keys. `apply()` is for entries that are already durable.
`readCheckpoint()` reads the versioned journal checkpoint body; it does not
convert legacy SDK checkpoint bytes into executable journal state.

| Options | Behavior |
| --- | --- |
| Both `journal` and `onEntry` | Journal restore and durable operations; prompts require `requestId`. |
| Only one journal option, or an invalid callback/iterable | Rejected before execution. |
| Neither option | Existing non-durable prompt, stream, tools, and close; durable operations reject. |
| Non-undefined `checkpoint` or `onCheckpoint`, including mixed inputs | Actionable migration error; no automatic import or precedence rule. |

Legacy checkpoint data must remain available to a compatible reader. This SDK
API does not automatically migrate a legacy checkpoint or authorize recovery
from it. Individual journal entries are bounded at 32 MiB; record and runtime
capacity limits also apply. A capacity or storage error is not permission to
truncate history or forget request identities.

### Suspension and recovery

- `suspend()` requests a safe boundary and waits for callbacks and entered
  executors to settle. It resolves core status, or `null` if no turn is active.
  It does not write `turn_end`. The suspended handle's `turn.result` rejects
  `PendingTurnError` carrying `status` and `pendingTurn`. A turn that finishes
  before suspension takes effect can resolve normally.
- `status()` reports `idle`, `lastSeq`, and, when present, `pendingTurn` containing
  `turnId`, `requestId`, `lastSeq`, and `awaiting`. The latter is `"model"` or
  `{ tool: { callId, name, input, replay } }`. During a persistence callback,
  status describes the previous durable position. Core admission still decides
  whether an operation can proceed.
- `resume({ signal? })` returns a continuation handle for the pending turn. It
  may repeat an unrecorded model request and incur billing. Settled tool results
  are retained. An unresolved tool resumes only under its recorded replay policy.
- `abandon()` records an interrupted turn end without running pending tools.
  The first unresolved selected tool remains `unknown`; later unexecuted calls
  are `skipped`. Abandonment is not evidence that an external effect failed.
- `close()` requests cancellation and waits for callbacks, tools, and turn-result
  cleanup. It is idempotent and remains available after an error. It does not
  replace suspension. A tool that ignores cancellation still must settle before
  cleanup can finish.

Keep the event consumer running while requesting suspension and handle
`PendingTurnError` from both the stream and its result. Recreate the next owner
from acknowledged journal entries, then choose recovery explicitly. Host
adapters should default to abandonment; automatic resume is an opt-in policy.

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

The JavaScript host owns tool effects; the core owns their execution order and
recorded identities. Journal tools default to `replay: "blocked"`. Declare
`replay: "safe"` only when the executor can recover its original authoritative
outcome by the recorded call ID, checking that its tool and input match. A
`recovering` flag does not replace that lookup. Journal tool context contains
`signal`, `turnId`, `callId`, `requestId`, and `recovering`.

Journal arguments use the same secret redaction as saved history. If redaction
changes a call's input, that call is recorded with blocked replay even when its
tool declares safe replay. A pending call requires reconciliation or abandonment;
an already recorded result remains usable without executing the tool again.

Cancellation aborts tool signals. The SDK retains an entered executor until its
actual promise settles, including after cancellation or shutdown. Throwing,
rejecting, invalid encoding, or losing a bridge reply does not prove that an
external effect failed. In journal mode the core preserves the pending tool and
rejects with `RecoveryRequired`; explicit recovery or abandonment is required.
A storage acknowledgement cannot resolve this independent effect uncertainty.

For a known terminal failure, return `{ content: "Known failure", isError: true }`
in journal mode. This is an ordinary recorded result that the model can handle.
Other objects remain JSON text, and typed results preserve media:

```js
return { type: "libfx.tool-result", text: "Known terminal failure", images: [], isError: true };
```

Plain non-durable agents retain their existing tool-event and result shapes.
After cancellation interrupts an entered executor, their uncertainty guard
rejects with `HostToolOutcomeUncertain` and blocks further work on that owner.
Tools remain responsible for stopping or reconciling external work. None of
these APIs makes arbitrary external effects exactly once.

Instructions are limited to 64 KiB of UTF-8 text, including text assembled by
the MCP and skills adapters. They are the complete host-owned system context:
libfx adds no hidden base prompt, and omitting `instructions` sends no system
message.

## MCP

`libfx/mcp` accepts a host-owned MCP client. Transport, authentication,
elicitation, and cleanup remain outside the kernel. The client uses the MCP
TypeScript SDK v1 signature: `callTool(params, resultSchema?, options?)`, with
cancellation passed in `options`. Explicit MCP `isError: true` responses are
returned terminal failures; rejected `callTool()` operations remain uncertain.
Tool text and structured data reach the model together. PNG, JPEG, GIF, and WebP tool images reach models that
advertise image input support; other models receive an explicit omission notice.
Journal persistence must retain image data or required artifacts before acknowledging
the records that reference them. Existing tool-result and journal bounds apply.
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
when creating an agent, including after journal restoration. The native
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

The terminal runtime exposes `interactive`, `exited`, `write`, `resize`, and
`abort`. Terminal session, config, OAuth, prompt-history, URL, and workspace
stores remain terminal-only host integrations.

## Security

Treat `nativeAddon` and `gatewayChatUrl` as trusted host
configuration. Do not embed long-lived credentials in public browser code.
Host tool functions, MCP clients, and skill loaders retain their own authority;
libfx validates and sequences them but does not grant operating-system access.
