# libfx

libfx is the agent from [fx](https://github.com/vercel-labs/fx), the open source coding agent from Vercel Labs, as a JavaScript library. You give it a model, instructions and your own tools, and it runs the conversation: the model loop, streaming, tool calls, retries, steering and images. It's the same Zig engine that runs fx in a terminal, built as a Node.js addon and as WebAssembly.

The hard part of running an agent on a server is that the server goes away. A function reaches its time limit in the middle of a reply, a deploy replaces the process, or it crashes during a tool call. libfx stores every prompt before it accepts it and every step of a turn as the turn runs, so the next process that picks up the session continues the turn where it stopped. On Vercel, that takes one route and one line of `vercel.json`.

```sh
npm install libfx
```

```js
import { createFxAgent } from "libfx";

const agent = createFxAgent({
  model: "anthropic/claude-haiku-5.5",
  instructions: "Answer in one paragraph.",
});

const turn = agent.session().prompt("What is an agent loop?");

for await (const event of turn) {
  if (event.type === "text_delta") process.stdout.write(event.delta);
}

await agent.close();
```

Set `AI_GATEWAY_API_KEY` and run it with Node.js 20 or newer. Model calls go through [AI Gateway](https://vercel.com/docs/ai-gateway), so any model it lists works, and on Vercel libfx uses the deployment's OIDC token instead of a key. libfx can also run on a user's own ChatGPT or Grok plan, or on another server through the OpenAI Chat Completions API. See [Providers](#providers).

Importing libfx and calling `createFxAgent()` touch no network, files or processes. The engine loads when a session runs its first turn.

The full documentation is at [fx.sh/docs/lib](https://fx.sh/docs/lib).

## How it fits together

| Object | What it is | How long it lives |
| --- | --- | --- |
| Agent | Configuration: model, instructions, tools, provider and where sessions live | As long as the server process |
| Session | One conversation | As long as its store keeps it |
| Turn | One prompt and everything the agent does to answer it | Until it ends with a stop reason |

An agent is configuration, and its conversations live in its sessions. Create each agent once per process with the same options on every server, and open a session for each conversation. Any process with that agent can run, continue or stream any of its sessions. An app can have [several agents](#several-agents), each with its own name.

Underneath the agent is `createFxEngine()`, a single conversation with no store, for when you don't want sessions. See [Without sessions](#without-sessions).

## Sessions

```js
const turn = agent.session().prompt("Plan the migration.");
const { sessionId } = await turn.accepted; // the prompt is stored

// Later, in any process that creates the same agent:
agent.session(sessionId).prompt("Start with the schema.");
```

- **One turn at a time.** A prompt sent while a turn runs waits behind it, even when it reaches a different server.
- **Turns finish on their own.** A turn runs to the end whether or not anyone reads its events, and a turn nobody reads holds no connection open: its view starts reading only once you use its events, `readable` or `result`. Stop it with `session.cancel()`, or with the `signal` you passed to `prompt()`.
- **Steering.** `session.steer(text)` adds guidance to the running turn at its next model request. When no turn is running, the text becomes the next turn.
- **Retries are safe.** Give a prompt a `messageId`, and a repeated request with the same id runs nothing new. It follows the original turn, and its result has `repeated: true`.

Each conversation can bring its own settings, which apply to the turns that session object starts:

```js
agent.session(sessionId, {
  model: { id: "anthropic/claude-opus-5.5", effort: "high" },
  instructions: "You review pull requests.",
  context: { userId }, // handed to every tool call
});
```

A turn's result says how it ended:

```js
const { stopReason, usage, error } = await turn.result;
```

`stopReason` is `end_turn`, `max_output_tokens`, `max_model_turns`, `refused` or `cancelled`. It's `error` when the turn failed, with the reason in `error`, and `unknown` when the process running it stopped before recording how it ended.

### Streaming to a browser

`turn.readable` is the turn as newline-delimited JSON, ready to return from a route. `session.stream(cursor)` returns every line after `cursor` and stays open for new ones, so a client that loses its connection reconnects to any server and carries on.

```js
// app/api/chat/route.js
import { agent } from "@/lib/agent";

export async function POST(request) {
  const sessionId = new URL(request.url).searchParams.get("sessionId") ?? undefined;
  // Check that the caller may use this session.
  const turn = agent.session(sessionId).prompt(await request.text());
  return new Response(turn.readable);
}

export async function GET(request) {
  const params = new URL(request.url).searchParams;
  const sessionId = params.get("sessionId");
  if (!sessionId) return new Response("sessionId is required", { status: 400 });
  // Same check as POST.
  return new Response(agent.session(sessionId).stream(Number(params.get("cursor") ?? 0)));
}
```

Each line is one JSON object with a `type`: the model's events, such as `text_delta` and `tool_start`, and the turn's own, `turn_start` (which carries the `sessionId`), `turn_end`, `turn_resume` and `turn_yield`. Lines from `session.stream()` carry a `cursor`. Store the last one you read and pass it back to resume after it. The `FxStreamLine` type lists every field.

## Durability

libfx stores a prompt before `turn.accepted` resolves, and stores each step of a turn while the turn runs. If the process running a turn dies, the next process that gets work for the session continues the turn from its last stored step. The model is told the turn was interrupted, so it can check what happened before going on.

Where sessions live depends on where your code runs. libfx picks for you:

| Where | Durability | Sessions live in |
| --- | --- | --- |
| Vercel | `vercel()` | Vercel's [Workflow World](https://workflow-sdk.dev/worlds), the store and queue behind Vercel Workflow |
| Node.js | `local()` | Files in `FX_SESSIONS_DIR`, or in `libfx/sessions` under the system's temporary directory |
| Browsers | `memory()` | The page's memory |

To choose yourself, pass `durability`:

```js
import { createFxAgent, memory } from "libfx";
import { local } from "libfx/durable-local";

createFxAgent({ durability: local({ dir: ".fx/sessions" }) });
createFxAgent({ durability: memory() }); // nothing outlives the process
```

On `local()`, `vercel()` and `world()`, a session id is a Workflow run id, `wrun_` followed by letters and digits. Take it from `turn.accepted` or `await agent.newSessionId()` instead of making one up. On `memory()`, any 1 to 128 letters, digits, `.`, `_` or `-` work.

A session stores the conversation and nothing else. Every process passes its own model, credentials, tools, MCP clients and skills when it creates the agent. If a session's saved checkpoint came from a different libfx version, tool set or model, the session still loads, and `onEvent` gets a `checkpoint.mismatch` event naming what changed.

### Several agents

An app can have more than one durable agent, each with its own model, instructions and tools. Give each one a name:

```js
export const support = createFxAgent({ name: "support", instructions: "Answer billing questions." });
export const coding = createFxAgent({ name: "coding", model: "anthropic/claude-opus-5.5", tools: codingTools });
```

A session belongs to the agent that created it, and its turns run only on an agent with that name. A prompt sent through another agent, such as `coding.session(supportSessionId).prompt()`, still runs on `support`, and the sending agent's `onEvent` gets a `session.forwarded` event. An agent created without a name is named `default`.

- Agents with the same name are copies of one agent, such as one on each server, and take turns running its sessions.
- Keep names stable. A session keeps the name it was created with, so renaming an agent leaves its sessions with no agent to run them.
- A process that gets a turn for a name it has no agent for refuses it with an `FX_NO_AGENT` error naming the agent, and the queue delivers it again.
- Agents share sessions through their durability. Give agents that share sessions the same durability, or none: agents created without one share the default.

### On Vercel

Add a route for libfx's queue deliveries:

```js
// app/api/libfx/route.js
import { wakeHandler } from "libfx";
import "@/lib/agents"; // creates the app's agents, so this function has them

export const POST = wakeHandler();
```

The route delivers each turn to the agent it belongs to, so one route serves every agent the module it imports creates. With one agent, `agent.wakeHandler()` does the same.

Then subscribe it to libfx's topic in `vercel.json`:

```json
{
  "functions": {
    "app/api/libfx/route.js": {
      "experimentalTriggers": [{ "type": "queue/v2beta", "topic": "__libfx_wkf_workflow_session", "retryAfterSeconds": 5 }]
    }
  }
}
```

That's all. When no other invocation holds the session, `prompt()` runs the turn in the request that called it, so the first model request goes out without a queue hop, and the function stays alive for the turn after the route responds. Vercel Queues keeps the prompt until after that request's time limit, and if the request dies mid-turn, that delivery continues the turn. Other turns go through Vercel Queues to this route:

- When a turn gets within 30 seconds of the function's time limit, libfx stops it, and the next invocation continues it. `vercel({ reserveMs })` from `libfx/durable-vercel` changes that margin.
- A function holds its session for as long as Vercel Queues keeps the turn's message for it, so nothing is written while a turn runs to show the function is alive. If the function's process exits mid-turn, Vercel runs the same delivery again about a second later, and that invocation continues the turn.
- A function that stops without its process exiting holds the message until the queue's hold on it runs out, up to five minutes. A prompt sent to the session meanwhile continues the turn at that function's time limit, if that comes sooner. `vercel({ leaseMs: 15_000 })` bounds that case: the function renews a 15-second lease on its session every 5 seconds, and the session frees about 15 seconds after the last renewal. With it, every prompt goes through the queue instead of running in the request.
- A function that only stalled and wakes up after that is refused at its next write, so two processes never write one session.

### Tools that change things

When a process dies during a tool call, libfx can't know whether the call finished. So each tool says whether it's safe to run twice:

```js
const byId = { type: "object", properties: { id: { type: "string" } }, required: ["id"] };

const tools = [
  {
    name: "get_order",
    description: "Look up an order.",
    inputSchema: byId,
    idempotent: true, // a lookup is harmless to repeat
    execute: ({ id }) => orders.get(id),
  },
  {
    name: "refund_order",
    description: "Refund an order.",
    inputSchema: byId,
    idempotent: true, // keyed on executionId, so running it again refunds once
    writes: true,
    execute: ({ id }, { executionId }) => payments.refund(id, { idempotencyKey: executionId }),
  },
];
```

When the turn continues, a call to an `idempotent: true` tool runs again. A call to any other tool never runs twice on its own: the model gets an error saying the call may have partly run, and decides whether to check, try again or ask the user. The turn's events end the call with that error too, as a `tool_end` with `isError: true`. libfx refuses a tool that doesn't set `idempotent`, so each one makes that choice. A call that finished before the process died keeps its result, whichever kind of tool it is: libfx stores each result as the call finishes.

Each call's `executionId` stays the same when it runs again. Pass it to the service your tool calls as an idempotency key, and a service that honors idempotency keys won't refund twice. That makes the tool safe to mark `idempotent: true` with `writes: true`.

A tool marked `idempotent: true` without `writes: true` starts as soon as the model asks for it, while libfx stores the call. If the process dies before the call is stored, the model asks again and the call gets a new `executionId`, which is harmless for a lookup. Every other tool starts only once its call is stored, so its `executionId` never changes.

### Your own store

`world()` from `libfx/durable-world` keeps sessions in a [Workflow World](https://workflow-sdk.dev/worlds) you create, such as Workflow's Postgres World:

```js
import { createWorld } from "@workflow/world-postgres";
import { createFxAgent } from "libfx";
import { world } from "libfx/durable-world";

const sessions = createWorld({
  connectionString: process.env.DATABASE_URL,
  namespace: "libfx",
  jobPrefix: "libfx_",
});
await sessions.start();

export const agent = createFxAgent({
  durability: world(sessions, { name: "postgres", queueDurable: true }),
});
```

A World that delivers queue messages over HTTP needs `agent.wakeHandler()`, or `wakeHandler()` for several agents, at the address it posts to. Workflow's Postgres World 5.0.2 posts every message to `/.well-known/workflow/v1/flow` on your app. `world()` takes options for what libfx can't learn from the World itself, such as how long a lease lasts and whether the queue keeps a message across crashes. The `WorldOptions` type documents each one.

On a World with Workflow's in-band writer fence, libfx writes each claim and record so that the World itself refuses a write from a worker another has replaced, and nothing of it is stored. libfx finds the fence in the World's capabilities, so there's nothing to configure. On a World without it, libfx detects the replaced worker after its write instead, and the session's log ignores what that worker wrote.

## Tools

```js
const agent = createFxAgent({
  tools: [{
    name: "get_order",
    description: "Look up an order by id.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    idempotent: true,
    async execute({ id }, { signal }) {
      return orders.get(id, { signal });
    },
  }],
});
```

`execute` receives the model's input and a context:

| Field | What it is |
| --- | --- |
| `signal` | Aborts when the turn is cancelled |
| `executionId` | The call's id, the same if the call runs again after a crash |
| `sessionId` | The session the call belongs to |
| `context` | The JSON passed as `context` to `agent.session()` |

Return a string to send it as is, or any other value to send it as JSON. A thrown error reaches the model as a failed tool result. To return images, return `{ type: "libfx.tool-result", text, images }`, with base64 image data.

Validate the input and authorize the action inside `execute`. libfx orders the calls but grants nothing itself.

On the native backend, calls to idempotent tools from one model response run at the same time, up to 16 at once. A tool that isn't idempotent runs alone, and so does one marked `writes: true`. Mark a tool `writes: false` to let it overlap with others anyway. On WebAssembly, calls run one after another.

`tools` can also be an object keyed by tool name. Add `{ name: "web_search", providerExecuted: true }` for AI Gateway's web search, which runs at the provider instead of in your code.

### MCP and skills

```js
import { createMcpAdapter } from "libfx/mcp";
import { createSkillsAdapter } from "libfx/skills";
import { loadSkillFile } from "libfx/skills/node";

const mcp = await createMcpAdapter(client, { prefix: "github_" }); // your MCP SDK client
const skills = createSkillsAdapter([await loadSkillFile("./skills/review/SKILL.md")]);

const agent = createFxAgent({
  tools: [...mcp.tools, ...skills.tools],
  instructions: [mcp.instructions, skills.instructions].join("\n\n"),
});

// When you're done:
await agent.close();
await mcp.close();
```

libfx doesn't own the MCP connection. You create the client, handle its auth and close it after the agent. `loadSkillFile()` reads one `SKILL.md` and nothing it references.

Every MCP tool comes with `idempotent: false`, since a server's hints can't be trusted. Set it to `true` on a tool you know is safe to run twice. A skill's tools set `idempotent` themselves.

## Models

```js
createFxAgent({ model: { id: "anthropic/claude-opus-5.5", effort: "high", fast: true } });
```

`effort` and `fast` mean the same as the fx CLI's `--effort` and `--fast` flags. `ultrafast: true` asks for the faster, more expensive service tier on models that offer it. A setting the model doesn't support fails with an error whose `code` names it, such as `LIBFX_MODEL_UNSUPPORTED_EFFORT`.

`listModels({ apiKey })` returns the ids of AI Gateway's language models. Behind a proxy that forwards only chat requests, pass the catalog yourself as `modelCatalog`, and the agent won't fetch it.

## Providers

### AI Gateway

AI Gateway is the default. libfx uses the first credential it finds: the `apiKey` option, then `AI_GATEWAY_API_KEY`, then on Vercel the deployment's OIDC token.

### ChatGPT plans

An agent can run on a user's ChatGPT plan through Codex. Set `provider: "codex"` and give libfx the user's credentials:

```js
const agent = createFxAgent({
  provider: "codex",
  model: "gpt-6.1-sol",
  credentials: ({ provider, sessionId }) => tokens.load(provider, sessionId),
  onCredentials: (credentials, { provider, sessionId }) => tokens.save(provider, sessionId, credentials),
});
```

libfx calls `credentials()` in whichever process runs the turn. It refreshes the credentials shortly before they expire and once after a rejected request, then passes the new ones to `onCredentials` for you to save. Codex doesn't accept requests from web pages, so these turns run on your server.

To sign a user in, use `libfx/chatgpt`:

```js
import { startSignIn, finishSignIn } from "libfx/chatgpt";

// One request: send the user to signIn.url and keep signIn on the server.
const signIn = await startSignIn();

// A later request: the user pastes back the address OpenAI opened.
const credentials = await finishSignIn(signIn, pastedAddress);
```

After the user signs in, OpenAI opens a page at `localhost:1455` that doesn't load. That's expected: ask the user to copy the page's whole address and paste it back. If their account or ChatGPT workspace allows device code sign-in, `startDeviceSignIn()` returns a short code to enter on OpenAI's site instead, and `pollDeviceSignIn()` or `completeDeviceSignIn()` waits for it. Each step returns plain data, so a later request or function can finish it.

The sign-in uses the same OpenAI client as the Codex CLI, and the user's ChatGPT plan and OpenAI's terms apply to the turns.

### Grok plans

`provider: "grok"` runs on a user's Grok plan, with the same `credentials` and `onCredentials` callbacks, called with `provider: "grok"`. libfx also checks that refreshed credentials still belong to the same xAI account. These turns run on your server too.

To sign a user in, use `libfx/grok`. Device code is the simplest:

```js
import { startDeviceSignIn, completeDeviceSignIn } from "libfx/grok";

// Show device.userCode and a link to device.verificationUrl.
const device = await startDeviceSignIn();

// Waits until the user enters the code. pollDeviceSignIn() checks once, for a later request.
const credentials = await completeDeviceSignIn(device);
```

`startSignIn()` and `finishSignIn()` work as for ChatGPT, except that xAI opens a page at `127.0.0.1`. The sign-in uses the same xAI client as the fx CLI, and the user's Grok plan and xAI's terms apply to the turns.

### Several servers, one account

The sessions in one process share each refresh. Across servers, two can notice the same expiring credentials at once, and the provider accepts only the first refresh. Pass `refreshLock` so they take turns:

```js
refreshLock: ({ provider, sessionId }, refresh) => locks.withLock(`${provider}:${accountOf(sessionId)}`, refresh),
```

libfx calls it with a function to run while you hold a lock on that user's account, for example in Redis. Inside it, libfx calls `credentials()` again and uses what another server already saved.

### Custom providers

An agent can run on a server that speaks the OpenAI Chat Completions API, such as a local model server or a router:

```js
const router = {
  name: "router",
  baseUrl: "https://openrouter.ai/api/v1",
  models: { "qwen/qwen3-coder": { contextWindow: 128000, supportsToolUse: true } },
};

const agent = createFxAgent({
  provider: router,
  model: "qwen/qwen3-coder",
  credentials: async ({ provider, sessionId }) => ({ apiKey: await keys.load(provider, sessionId) }),
});
```

Requests go to `{baseUrl}/chat/completions`, which must use HTTPS, or HTTP on `localhost`. Leave out `credentials` for a server that needs no key. `models` tells libfx what it can't ask the server: each model's context window and output limit, and whether it takes tools and images. A key isn't refreshed, so a rejected one ends the turn with the server's error. In a browser, the server must accept cross-origin requests, and the page can read the key.

Saved sessions follow the agent's provider: point an agent at another base URL and its sessions continue there, history included.

### Where credentials go

libfx adds ChatGPT, Grok and custom-provider credentials to each request in JavaScript, just before it's sent, and sends them only to that provider. They never reach the engine. No credential is written to a saved session or passed to `onEvent`, and if a server quotes a key or token back in an error, libfx masks it before the error reaches the turn.

## Images

```js
agent.session().prompt([
  { type: "text", text: "What's wrong with this chart?" },
  { type: "image", mimeType: "image/png", data: base64Png },
]);
```

A session stores each prompt as JSON before it runs, so a session prompt takes image data as a base64 string. `createFxEngine()` also takes bytes, a `Blob` or a `File`. Each prompt takes up to 8 PNG, JPEG, GIF or WebP images, at most 3.75 MiB each and 6 MiB together. Pass `resizeImage` to downscale or convert prompt images before they're sent.

## Diagnostics

`onEvent` receives diagnostics apart from the model's output: request timing and retries, and session events such as `session.deadline` when a turn stops for a function's time limit. The `FxAgentEvent` type lists them all.

## Without sessions

`createFxEngine()` is the engine under the agent: one conversation in the memory of one process, with no queue and no session store. Use it for a single request, a subagent inside a tool call, or a conversation you store yourself.

```js
import { createFxEngine } from "libfx";

const engine = await createFxEngine({ apiKey: process.env.AI_GATEWAY_API_KEY, model: "anthropic/claude-haiku-5.5" });

const turn = engine.prompt("Summarize this file.");
for await (const event of turn) {
  if (event.type === "text_delta") process.stdout.write(event.delta);
}

const checkpoint = await engine.checkpoint(); // opaque bytes, up to 4 MiB
await engine.close();

const restored = await createFxEngine({ apiKey: process.env.AI_GATEWAY_API_KEY, model: "anthropic/claude-haiku-5.5", checkpoint });
```

An engine differs from a session:

- On AI Gateway, it needs an `apiKey`.
- One prompt runs at a time, and breaking out of a turn's events cancels the turn.
- The turn itself has `cancel()` and `steer()`.

To have the engine record the conversation as it runs, pass a `persistence` store instead of a checkpoint. A new engine on the same store can then `resume()` a turn the last process left open. A store needs two methods and can add a third, and the bytes are opaque, so it never has to understand them:

```ts
interface Persistence {
  load(): Promise<{
    checkpoint?: { data: Uint8Array; through: string };
    journal?: Iterable<JournalRecord> | AsyncIterable<JournalRecord>;
    head?: string | null;
  }>;
  append(input: { expected: string | null; idempotencyKey: string; data: Uint8Array; barrier: boolean; marks?: object[] }): Promise<{ cursor: string }>;
  saveCheckpoint?(input: { through: string; data: Uint8Array }): Promise<void>;
  marks?: boolean;
}

interface JournalRecord {
  cursor: string;
  data: Uint8Array;
}
```

Reject an `append()` whose `expected` isn't the last stored cursor with `FxFencedError`, so two processes can't write the same conversation. If your store keeps entries of its own after the last record, return the cursor the next `append()` should name as `head`. When a resumed turn left a tool call running, `resume({ onAmbiguous })` lets you return `"rerun"` to run it again under the same `executionId`.

The engine sends one `append()` at a time, and everything that happens while one is in flight goes in the next record. `barrier` is `true` when the engine waits for the record before it goes on, such as before a tool call with effects. A store may acknowledge a record with `barrier: false` before it is durable, as long as it keeps records in order and acknowledges a barrier only once it and every record before it are durable. Set `marks: true` to receive each record's `marks`, which say where turns start (`{ start: turnId }`), yield and end, and which inputs a turn took (`{ accepted: id }`), so a store can track turns without reading records.

`prompt()` and `resume()` take `yieldAt`, a time in milliseconds since the epoch: the turn stops before its next model request after that time, with the stop reason `yielded`, and the next `resume()` continues it without telling the model it was interrupted.

A journal or `checkpoint` from a newer libfx fails with `FxJournalVersionError`. `createMemoryPersistence()` is a reference store for tests.

## Runtimes

| Runtime | Backend |
| --- | --- |
| Node.js 20+ on macOS or Linux, x64 or arm64 | Native addon. Linux needs glibc 2.34 or newer. |
| Node.js elsewhere | WebAssembly with JSPI. Some Node versions need `--experimental-wasm-jspi`. |
| Browsers | WebAssembly with JSPI, from `libfx/browser` |
| Bun | The same as Node.js. For WebAssembly, use Bun 1.4.2 or newer. |

The default `backend: "auto"` tries the native addon first. Pass `"native"` or `"wasm"` to require one, and call `getBackendInfo()` to see what would load without creating anything.

Next.js works in Node.js route handlers, with webpack or Turbopack, and doesn't need `serverExternalPackages`. CommonJS apps can `require("libfx")`. With TypeScript's `moduleResolution: "bundler"`, add `"node"` to `customConditions` to get the Node.js types.

## The fx terminal in a browser

```js
import { createFxTerminal, xtermAdapter } from "libfx/browser";

const terminal = await createFxTerminal({
  terminal: xtermAdapter(term), // an xterm.js Terminal
  env: { AI_GATEWAY_API_KEY: shortLivedKey },
});

await terminal.interactive;
```

This is the fx CLI's interface compiled to WebAssembly. Your page supplies storage for its sessions, settings and sign-in, and can give it a workspace that runs commands. See [Terminal](https://fx.sh/docs/lib/terminal).

## Entry points

| Import | What's in it |
| --- | --- |
| `libfx` | `createFxAgent`, `createFxEngine`, `createFxTerminal`, `memory`, `listModels`, `createMemoryPersistence`, `FxFencedError`, `FxJournalVersionError`, `supportsJspi`, `xtermAdapter`, `encodeXtermKeyEvent`, and on Node.js `getBackendInfo` and `wakeHandler` |
| `libfx/node`, `libfx/browser` | The same, for Node.js or browsers explicitly |
| `libfx/wasm` | The WebAssembly SDK without packaged asset paths, so you pass `wasm` yourself |
| `libfx/durable-local`, `libfx/durable-vercel`, `libfx/durable-world` | `local()`, `vercel()` and `world()` |
| `libfx/chatgpt`, `libfx/grok` | Sign-in for ChatGPT and Grok plans, and `refreshCredentials` |
| `libfx/mcp` | `createMcpAdapter` |
| `libfx/skills`, `libfx/skills/node` | `createSkillsAdapter`, and `loadSkillFile` for Node.js and Bun |

Every entry point ships TypeScript types, and the package has no runtime dependencies.

## For coding agents

- **Docs as Markdown:** [fx.sh/llms.txt](https://fx.sh/llms.txt) indexes every page, and each page has a `.md` version, such as `https://fx.sh/docs/lib/durability.md`. The declarations in `types/` are the exact API.
- **Agents at module scope:** create each agent once at module scope, not per request, and open `agent.session(id)` for each conversation.
- **Session ids:** take them from `turn.accepted` or `agent.newSessionId()`. On every durability except `memory()`, an id that isn't a Workflow run id throws.
- **Side effects:** every tool sets `idempotent`. Set it to `true` only on tools that are safe to run twice, and pass `executionId` to services that take an idempotency key.
- **Deployments:** on Vercel, the `wakeHandler()` route and its `vercel.json` trigger are both required, or prompts are stored and never run. The route must import the module that creates the agents.
- **Several agents:** give each durable agent its own `name`, and never rename one that has sessions.
- **Credentials:** keep keys and ChatGPT or Grok credentials on the server, and the object `startSignIn()` returns too.
- **Checking a setup:** `getBackendInfo()` reports which backend would load without creating anything or making requests.
- **Changing libfx:** the source is in the [fx repository](https://github.com/vercel-labs/fx) under `sdk/`. Its `AGENTS.md` files name the tests each change needs.

## Upgrading from 0.0.13

In libfx 0.0.13 and earlier, `createFxAgent()` created the engine. It now creates the durable agent, so rename those calls to `createFxEngine()`. Old code runs against the agent once its tools set `idempotent`, with a few differences: breaking out of a turn's events no longer cancels it, turns have no `cancel()` or `steer()` (the session does), and `persistence` and `sessionId` throw because the durability holds the session.

`libfxApiVersion` is now 3. Every tool given to `createFxAgent()` must set `idempotent`, and a tool's `writes` now defaults to the opposite of `idempotent`, in the engine too, so a tool that isn't marked idempotent runs alone. A journal written by this libfx can't be loaded by an older one, which fails with `FxJournalVersionError`.

## Security

Your tools, MCP clients and skill loaders have whatever access your code gives them. libfx orders their calls but grants nothing itself, and the native backend doesn't turn on fx's built-in shell or file tools. Don't put long-lived keys in browser code, and treat the `nativeAddon` and `gatewayChatUrl` options as trusted configuration.

## Contributing

libfx is developed in the [fx repository](https://github.com/vercel-labs/fx), under `sdk/`. Bug reports and pull requests are welcome. See [CONTRIBUTING.md](https://github.com/vercel-labs/fx/blob/main/CONTRIBUTING.md) to get started.

## License

[Apache-2.0](https://github.com/vercel-labs/fx/blob/main/LICENSE)
