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
const checkpoint = await agent.checkpoint();
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
The new codes replace `LIBFX_UNSUPPORTED_EFFORT` and `LIBFX_UNSUPPORTED_FAST`
for both nested and legacy top-level settings. Callers that check the old codes
must update their error handling.

The host selects the model. Agent creation does not fetch the Gateway model
catalog unless effort requests a named level or fast is enabled. Prompting
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
`turn.cancel()` and `agent.close()` also release blocked output. Transport or
message-decoding failures reject the result instead of returning success with
missing text.

Native transport buffers at most 8 MiB of output bytes. Unread SDK events apply
backpressure at 1 MiB of encoded messages or 256 events. One message can exceed
that threshold when the queue is empty; an individual encoded ACP message is
limited to 64 MiB on both backends. These are transport bounds, not a total
answer-size limit or a bound on retained conversation history.

Image blocks accept a `Blob` or `File` with a non-empty `type`, or the
existing canonical base64 (no line wrapping) and explicit `mimeType` of a PNG,
JPEG, GIF, or WebP payload:

```js
const turn = agent.prompt([
  { type: "text", text: "What does this screenshot show?" },
  { type: "image", data: file }, // File or Blob, with file.type
  // Or: { type: "image", data: base64Png, mimeType: "image/png" }
]);
```

A prompt may contain up to 8 images, each with up to 5 MiB of base64 data,
with at most 8 MiB of image data per prompt. The SDK checks Blob size before
reading it, encodes it for the same ACP wire format, and rejects larger input
with typed `RangeError`s. The total frame size is checked before reading a
Blob, and the actual byte count is checked before encoding it. Blob reads are
asynchronous: `prompt()` returns a turn, and read failures reject
`turn.result`. Cancelling or closing while a Blob is being read settles the
turn without sending its prompt. For base64 input, size errors still throw
synchronously from `prompt()`.

The kernel sniffs decoded bytes and compares them with the claimed MIME type
for both input forms; a mismatch fails the turn with
`Invalid image prompt block`. Images are routed only to models that advertise
image input; for any other model the turn fails with
`Image prompts are unavailable for the selected model` and no image bytes
leave the process. Prompt images are retained in checkpoints within the
existing 4 MiB checkpoint bound, so a restored agent can refer to earlier
images on either backend.

Only one top-level prompt may run at a time. While it runs,
`await turn.steer(text)` appends guidance at the next safe model boundary
without discarding the in-flight response or completed tool work. Steering also
accepts an array of text blocks; image and resource steering blocks are rejected.
Each message is limited to 64 KiB, with at most 64 queued messages and 1 MiB of
queued steering text. Accepted steering appears as a `user_message` event before
the model's continued output. For a Blob prompt, steering during the read
waits for the prompt to be sent; cancelling before then rejects the pending
steering. Calling `steer()` after the turn settles rejects with
`no prompt is running`.

```js
const turn = agent.prompt("Build the feature.");
for await (const event of turn) {
  if (event.type === "tool_end" && event.name === "read_file") {
    await turn.steer("Keep the public API backward compatible.");
  }
}
```

Cancelling a steered turn drops any guidance that has not reached a safe
boundary and releases its queue. Applied guidance is part of the same history
turn, so an idle `checkpoint()` includes the full steered conversation.
`checkpoint()` returns opaque, bounded, versioned bytes. Restore them only when
creating a fresh agent:

```js
const restored = await createFxAgent({ apiKey, model, checkpoint });
```

An already-aborted prompt signal returns `cancelled` without a model request
or a history change. The next prompt can run normally.

The checkpoint contains conversation history and usage only. The host owns
durable storage and must resupply models, credentials, instructions, tools,
MCP clients, and skill records. Reasoning effort and fast mode are
agent-creation options and are not stored in a checkpoint: recreate the agent
with new `model.effort` or `model.fast` values to change them, the same path as
switching models.

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

## Native fx with a browser UI

Pass `remote` to `createFxTerminal()` to render a native fx process through the
same xterm adapter. This mode does not load WebAssembly or start a browser agent.
The native process owns model requests, tools, settings, and session state.

```js
import { createFxTerminal, xtermAdapter } from "libfx/browser";

const runtime = await createFxTerminal({
  terminal: xtermAdapter(term),
  remote: {
    url: connection.url,
    sessionId: connection.sessionId,
  },
});
await runtime.interactive;
```

The authenticated application backend provides `connection` after authorizing the
user's existing sandbox session. Its URL points to the application WebSocket relay;
the private sandbox capability stays on the server. See the [native backend example](https://github.com/vercel-labs/fx/tree/main/sdk/examples/remote-terminal)
for a working WebSocket broker, PTY helper, and Vercel Sandbox startup integration.
The example requires Node and Python in the sandbox; the SDK itself adds no
transport dependency. Native fx must be installed at session startup. Reuse the
broker for subsequent messages and browser connections.

`interactive` means the transport has attached, not that native fx has completed
startup. `abort()` detaches the view and resolves `exited` with 130; it does not
kill the native session or cancel a turn. `interrupt()` explicitly sends Ctrl+C
to the native terminal. `write()` accepts a string or `Uint8Array` up to 64 KiB.
Terminal input, resize, fx commands, and pickers continue through native fx.
Terminal editing therefore includes network latency; this mode does not perform
speculative local echo or duplicate native command handling.

An unexpected connection loss resolves `exited` with 255. Reconnect explicitly
using a fresh runtime and the same terminal instance, session ID, and last
rendered `runtime.cursor`. A fresh blank terminal needs cursor zero. The example
retains bounded output history and rejects expired cursors rather than replay an
incomplete screen. Input is never retried automatically. `remote.url` may also be
an async function to obtain a freshly authorized URL for each attachment.

Use `createFxView({ remote, onSnapshot })` for semantic HTML state instead of
terminal output. It exposes the same attachment lifecycle plus `interact(action)`.
Its `interactive` promise waits for the first native snapshot. Snapshots and
actions come from native fx's interaction channel, not parsed ANSI.
The optional `libfx/html` renderer consumes them:

```js
import { createFxView } from "libfx/browser";
import { createFxHtmlView } from "libfx/html";

let client;
const view = createFxHtmlView({
  container: document.querySelector("#fx"),
  send(action) { client.interact(action); },
});
client = await createFxView({
  remote: { url: connection.url, sessionId: connection.sessionId },
  onSnapshot: view.render,
});
await client.interactive;
```

The HTML surface is experimental and requires the native interaction channel from
this build. Its supported controls are defined by that channel; it does not make
all terminal-only screens HTML-compatible. Use the terminal presentation for
native interactions not yet projected into semantic snapshots. Neither rendering
mode changes backend tool capabilities or permissions. Native process lifetime
and sandbox billing remain the owning application's responsibility.

Keep model and sandbox credentials on the server. The example includes
`createTerminalRelay` with a server-owned authentication/session resolver, a
separate browser Origin check, and bounded forwarding. The browser connects to
this application backend; it never receives the private sandbox capability URL.
Do not put private connection URLs in logs or analytics. The sandbox broker also
validates an exact Origin and allows one writer at a time; Origin validation
alone is not authentication.

## Security

Treat `nativeAddon` and `gatewayChatUrl` as trusted host
configuration. Do not embed long-lived credentials in public browser code.
Host tool functions, MCP clients, and skill loaders retain their own authority;
libfx validates and sequences them but does not grant operating-system access.
