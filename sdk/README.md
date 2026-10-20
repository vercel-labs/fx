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
- **Turns finish on their own.** A turn runs to the end whether or not anyone reads its events, and a turn nobody reads holds no connection open: its view starts reading only once you use its events, `readable` or `result`. Stop it with `session.cancel()`, or with the `signal` you passed to `prompt()`. A turn whose end is already being saved has ended: a cancel then stops nothing, and the turn's result and its `turn_end` line say what that end says.
- **Steering.** `session.steer(input)` steers the running turn the way the fx CLI does. While the model streams a reply, the steer cuts it short and the turn continues with it. A steer sent from another server can reach the turn only as the reply ends, and the turn then continues with it after the reply. Once that last reply has ended and the turn has taken its last steers, a new steer becomes the next turn, even while the turn's end is still being saved. While a tool runs, the steer waits for the tool. A steer sent while a turn waits to start joins that turn, and when no turn runs or waits, the steer becomes the next turn. A steer with images can't join a turn, so it runs next: the running turn ends `cancelled` at its next safe point, or `end_turn` when the steer reaches it only as the reply ends. A turn it ended `cancelled` has the steer's `messageId` as `endedBySteer`, in its result and its `turn_end` line, so an app can tell it from a turn `cancel()` ended, which has none. The record that ends the turn names the steer too, so the turn's end still has it when its process stopped before writing that line. Its images are saved once with the session before the steer is sent, as a prompt's are, and a steer whose image can't be saved throws the store's error.
- **Retries are safe.** Give a prompt or a steer a `messageId`, and a repeated request with the same id runs nothing new. A repeated prompt follows the original turn, and its result has `repeated: true`. One id names one input, so a steer that reuses a prompt's id is rejected with `FX_MESSAGE_ID_IN_USE`. A steer's `user_message` event carries its id as `id` where it joined a turn.
- **Inputs have a size limit.** A prompt or steer is rejected with `FX_INPUT_TOO_LARGE` before anything is stored when its text and other content, image data aside, take more than the engine's 8 MiB prompt frame, which the engine can't take, or when what the session stores for it comes to more than 16 MiB: the input with each image named, and the session's `context` and settings, as JSON, and the bytes of its images. Images have their own limits, which apply after `resizeImage`.
- **A refused prompt is never stored.** `prompt()` checks a prompt as the engine's `prompt()` does and throws a `TypeError` or `RangeError` for one libfx would refuse, such as an empty prompt, base64 that isn't canonical, an image whose bytes aren't its type, or more than 8 images. A prompt whose `signal` aborts before the prompt is stored isn't stored either, and its turn ends `cancelled`.

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

`stopReason` is `end_turn`, `max_output_tokens`, `max_model_turns`, `refused` or `cancelled`. It's `error` when the turn failed, with the reason in `error`. The record that ends a turn says how it ended, so a turn whose process stopped right after that record still reports it. That record also holds the turn's reply: the worker that writes the turn's end for the stopped process first streams, as one `text_delta`, the part of the reply the stream doesn't show yet. A finished reply is saved just before the turn's end, so a process that stopped between the two leaves the turn open with its reply: the worker that resumes it ends the turn with that reply without asking the model again, and streams the part of it the stream doesn't show the same way. A turn that took a steer after its reply was saved asks the model again instead, with the steer. Only a turn an earlier libfx ended reports `unknown`, since its record doesn't say. A turn the provider refused has the provider's error in `error` too. A cancelled turn ends every tool call it started with a `tool_end`.

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

On `local()`, `vercel()` and `world()`, a session id is a Workflow run id, `wrun_` followed by letters and digits. Take it from `turn.accepted` or `await agent.newSessionId()` instead of making one up: `agent.session()` throws a `TypeError` with the code `FX_SESSION_ID_INVALID` for any other id. On `memory()`, any 1 to 128 letters, digits, `.`, `_` or `-` work.

`local()` keeps the sessions an older libfx saved in its folder in an older file layout: the first time it opens the folder, it moves their files into the layout it reads. If one can't be moved, such as when a different file already has its name, the prompt's `turn.accepted` rejects with `FX_LOCAL_STORE_LAYOUT` naming it, and nothing in the folder changes.

A session stores the conversation, and with each prompt and steer the caller's `context` and the session object's settings. Every process passes its own model, credentials, tools, MCP clients and skills when it creates the agent.

libfx doesn't know who is calling. Anyone with a session's id can prompt, steer, cancel, stream or checkpoint it, so your app must check that the caller may use a session before it opens it. A queue message only names an input libfx already stored: a delivery that names one the session's log doesn't hold runs nothing, and the agent's `onEvent` gets a `session.refused` event. If a session's saved checkpoint came from a different libfx version, tool set or model, or a session that has saved no checkpoint yet last ran on a different model, the session still loads, and `onEvent` gets a `checkpoint.mismatch` event naming what changed.

### Several agents

An app can have more than one durable agent, each with its own model, instructions and tools. Give each one a name:

```js
export const support = createFxAgent({ name: "support", instructions: "Answer billing questions." });
export const coding = createFxAgent({ name: "coding", model: "anthropic/claude-opus-5.5", tools: codingTools });
```

A session belongs to the agent that created it, and its turns run only on an agent with that name. A prompt sent through another agent, such as `coding.session(supportSessionId).prompt()`, still runs on `support`, and the sending agent's `onEvent` gets a `session.forwarded` event. An agent created without a name is named `default`.

- Agents with the same name are copies of one agent, such as one on each server, and take turns running its sessions. In one process, every agent with a name on a store must have the same configuration: creating one with different options throws `FX_AGENT_NAME_IN_USE`. Agents created without a name or a durability share the name `default` and the default store, so an app with two such agents, or one that serves several customers, gives each agent its own name. Create an agent once, at module scope, or close it when you're done with it. In Node under `NODE_ENV=development`, where a dev server such as `next dev` loads a module again, a new agent with different options replaces the earlier one instead of throwing: turns the earlier agent is running finish, later turns run on the new one, and the new agent's `onEvent` gets an `agent.replaced` event. The newest agent wins even when an earlier one, created without a durability, learns its store only later. In a browser, creating one always throws.
- Keep names stable. A session keeps the name it was created with, so renaming an agent leaves its sessions with no agent to run them.
- A process that gets a turn for a name it has no agent for refuses it with an `FX_NO_AGENT` error naming the agent, and the queue delivers it again.
- Agents share sessions through their durability. Give agents that share sessions the same durability, or none: agents created without one share the default.
- One route takes the deliveries for every World in the process and hands each to the agent of its name on the store it names. A World's store is its `store` option, or its name. An app that serves several customers gives each customer a store of its own, with `world()`'s `store`, and never shares one store between customers who must not reach each other's sessions.

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

The trigger makes the route private: it has no public URL, and only Vercel Queues can call it. Keep `wakeHandler()` on that route only. An app whose own World queues to a route the internet can reach must check that each request comes from its queue before it calls `wakeHandler()`. libfx runs only inputs its sessions already stored, but a forged request can still wake a session.

That's all. When no other invocation holds the session, `prompt()` runs the turn in the request that called it, so the first model request goes out without a queue hop, and the function stays alive for the turn after the route responds. Vercel Queues keeps the prompt until after that request's time limit, and if the request dies mid-turn, that delivery continues the turn. Other turns go through Vercel Queues to this route:

- When a turn gets within 30 seconds of the function's time limit, libfx stops it, and the next invocation continues it. `vercel({ reserveMs })` from `libfx/durable-vercel` changes that margin.
- A function holds its session for as long as Vercel Queues keeps the turn's message for it, so nothing is written while a turn runs to show the function is alive. If the function's process exits mid-turn, Vercel runs the same delivery again about a second later, and that invocation continues the turn.
- A function that stops without its process exiting holds the message until the queue's hold on it runs out, up to five minutes. A prompt sent to the session meanwhile continues the turn at that function's time limit, if that comes sooner. `vercel({ leaseMs: 15_000 })` bounds that case: the function renews a 15-second lease on its session every 5 seconds, and the session frees about 15 seconds after the last renewal. With it, every prompt goes through the queue instead of running in the request.
- A function that only stalled and wakes up after that is refused at its next write, so two processes never write one session. Once its own clock says its lease ran out, it also adds nothing to the session's stream until a lease write of its own lands, so a function another one replaced adds nothing past a write it had already started.

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

A stream cursor counts the lines before it, so a World must put each stream chunk after every chunk the stream holds when it lands. The World `local()` bundles does. Workflow's file system World, `@workflow/world-local` 5.1.1, places a chunk where its write started instead: passed to `world()`, a line that a stalled function had already started writing when another took its session over can land ahead of lines a reader has, and move the cursor of every line after it.

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
| `context` | A copy of the JSON passed as `context` to `agent.session()`, taken when you call it |

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

`listModels({ apiKey })` returns the ids of AI Gateway's language models. Behind a proxy that forwards only chat requests, pass the catalog yourself as `modelCatalog`, and the agent won't fetch it. Otherwise an agent fetches the catalog at most once for all its sessions, and only when a turn needs to look up its model.

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

Name a model the plan serves, here or in `agent.session(id, { model })`. fx's default model is an AI Gateway id, so libfx refuses a Codex engine or session without one.

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

`provider: "grok"` runs on a user's Grok plan, with the same `credentials` and `onCredentials` callbacks, called with `provider: "grok"`. It needs a Grok model too, such as `model: "grok-4.7"`; the AI Gateway id `spacexai/grok-4.7` doesn't work on a Grok plan. libfx also checks that refreshed credentials still belong to the same xAI account. These turns run on your server too.

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

A session stores each prompt as JSON before it runs, so a session prompt takes image data as a base64 string. `createFxEngine()` also takes bytes, a `Blob` or a `File`. A session saves each image once, named by its SHA-256, before it stores the prompt, and the saved conversation refers to it by that name, so images don't count toward the 32 MiB the session's own checkpoints hold. Images a host tool returns are saved the same way; one that can't be saved stays in the tool's result, held inline. A session keeps as many of its newest images as one model request carries, at most 100, whose base64 takes at most 30 MiB. A request leaves older images out anyway, so the model sees the images it would see if the session kept them all. An older image leaves the conversation, and the model sees a note in its place. Opening a session reads from the store only the images it keeps and those of a turn it left open, several at a time. A checkpoint you take with `checkpoint()` carries the bytes of the images the session keeps, within its 32 MiB, and the names of the older ones. An engine with a `persistence` store of its own keeps images inside its records and checkpoints, so they count toward that 32 MiB; for a conversation with many images, use a session with [durability](#durability). libfx never deletes a saved image, including one that left the conversation; it lasts as long as the session's storage. Each prompt takes up to 8 PNG, JPEG, GIF or WebP images, at most 3.75 MiB each and 6 MiB together. Images travel beside the prompt's 8 MiB frame, so they leave its room for text. Pass `resizeImage` to downscale or convert prompt images before they're sent; the image limits apply to what it returns.

## Diagnostics

`onEvent` receives diagnostics apart from the model's output: request timing and retries, notices fx gives beside a reply as `turn.notice`, such as an Ultrafast tier the provider didn't confirm, and session events such as `session.deadline` when a turn stops for a function's time limit. The `FxAgentEvent` type lists them all.

## Instrumentation hooks

Pass `hooks` to `createFxAgent()` or `createFxEngine()` to observe semantic execution on both native and Wasm backends. Your host owns span topology, naming, redaction, and export. libfx doesn't load a tracing library.

```ts
import { createFxAgent, type FxHookEvent } from "libfx";

const observed: FxHookEvent[] = [];
const agent = createFxAgent({
  hooks: {
    captureContent: true,
    onEvent(event) { observed.push(event); },
    onError(error) { console.error("Instrumentation callback failed", error); },
  },
});
```

`FxHookEvent` includes turn and step boundaries, model requests and completions, provider admission and first output, tool execution and accepted results, permission evaluation, and journal restore/commit/error receipts. Events carry the session ID, logical turn ID, and a fresh execution ID for each prompt or resume. Model-call and step ordinals are scoped to that execution; tool call IDs come from the model and survive recovery. Join a tool to its issuing model through `model.end.data.toolCalls`, without matching tool names or parsing UI events.

`tool.end` reports execution; `tool.result` means the result entered the conversation, not that storage accepted it. `journal.commit` follows a successful append and includes its validated cursor and sequence range. Journal receipts are session-scoped, with null turn and execution IDs. A yielded or paused turn stays resumable; `turn.end.data.handoff` identifies an explicit host handoff. Replaying saved results doesn't emit fresh tool execution events; an authorized rerun emits `tool.start` with `rerun: true` and the original call ID.

`wait.start` and `wait.end` describe actual input requests separately from permission evaluation. Their `kind` is `approval`, `question`, `mcp_form`, or `mcp_url`; request IDs pair outcomes, including denial, cancellation, and failure. Native delegation events carry the child session and durable work ID. Child events retain that work ID, their own session/turn/execution identity, and the root and parent session IDs, so the host can join them even if delivery interleaves.

MCP events include the configured server, original remote tool name, and owning fx call ID. `mcp.request.data.requestIdKind` distinguishes a native JSON-RPC ID, an MCP-v2 engine handle, and an explicitly propagated host correlation token. Hooks don't change remote MCP requests by default: the host adapter emits `mcp.start` and `mcp.end` without adding metadata or emitting a request ID. Opt in with `createMcpAdapter(client, { propagateCorrelation: true })` to send an opaque UUID as `_meta["libfx/correlationId"]` and record it in `mcp.request`. It contains no internal execution/call IDs and doesn't request progress notifications. Give the adapter a `serverName` for a stable local identity; otherwise it uses the client's reported server name when available. Native resource/prompt operations also report their server and action.

`mcp.end.status` uses `success`, `failure`, `cancelled`, `input_required`, `unavailable`, or `unknown`. Native tool/protocol failures map to `failure`; `unavailable` means no operation result was available, and `unknown` means observation couldn't classify a returned host result.

Host tools receive `context.observation` when hooks are enabled. Wrap host-owned approvals or questions with `observation.wait(request, effect)`; the effect still owns the decision, response, cancellation, and error. For a host-created child engine, pass `hooks: context.observation.childHooks()` to retain the parent tool relationship. These helpers are optional, and neither requires a tracing library. Native review, vision, title, and compaction calls use the model event family with an explicit purpose; tool-owned model calls include `parentCallId`.

Always call the host effect when `context.observation` is absent too. Disabling hooks must not skip an approval or question; the observer doesn't make permission decisions.

JavaScript host-tool callbacks apply to the engine's own root session, not native descendant sessions. Descendant hook metadata doesn't authorize a cross-session host-tool request. A host-created child engine has its own root session and can install `childHooks()` for lineage.

Content capture defaults to off. Enabling it includes bounded messages, instructions, tool arguments/results, input prompts/answers, and schemas, which can contain sensitive application content. Each event has a shared 64 KiB text budget. For model requests, the newest messages are kept first from the last 128 messages, followed by instructions, tool descriptions, and schemas. Collections keep at most 128 entries, and tool `inputSchemaJson` fields keep at most 8 KiB each. `contentTruncated` marks omissions. JSON text fields can be prefixes after truncation; `inputSchemaJson` is complete JSON or null. Credentials, request headers, raw image bytes, and opaque provider replay state aren't fields in this protocol. Apply your own redaction before export.

Callbacks run in delivery order, but libfx doesn't await their promises. Callback throws and rejections go to `hooks.onError` and don't fail or retry agent work. A slow synchronous callback still delays delivery, so enqueue events and let the host own buffering and flushing. Hooks are best-effort observations, not a durable trace outbox or exactly-once delivery contract. Existing `onEvent` diagnostics and turn UI streams remain separate.

Auxiliary title-model calls can outlive `turn.end` and report model events with the same turn/execution IDs afterward. Their model-call IDs and `purpose: "title"` distinguish them from the finished agent loop.

## Without sessions

`createFxEngine()` is the engine under the agent: one conversation in the memory of one process, with no queue and no session store. Use it for a single request, a subagent inside a tool call, or a conversation you store yourself.

```js
import { createFxEngine } from "libfx";

const engine = await createFxEngine({ apiKey: process.env.AI_GATEWAY_API_KEY, model: "anthropic/claude-haiku-5.5" });

const turn = engine.prompt("Summarize this file.");
for await (const event of turn) {
  if (event.type === "text_delta") process.stdout.write(event.delta);
}

const checkpoint = await engine.checkpoint(); // opaque bytes, up to 32 MiB
await engine.close();

const restored = await createFxEngine({ apiKey: process.env.AI_GATEWAY_API_KEY, model: "anthropic/claude-haiku-5.5", checkpoint });
```

An engine differs from a session:

- On AI Gateway, it needs an `apiKey`.
- One prompt runs at a time, and breaking out of a turn's events cancels the turn.
- The turn itself has `cancel()` and `steer()`. Like a session's steer, it cuts a streaming reply short and waits for a running tool, and it takes text only. With a `persistence` store, a turn whose end is already on its way to the store has ended, as with a session: `cancel()` then stops nothing, and the result says what that end says.

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

Reject an `append()` whose `expected` isn't the last stored cursor with `FxFencedError`, so two processes can't write the same conversation. The engine whose append you fence stops: its turn rejects with your `FxFencedError`, and so does each later call, and it sends no model request carrying what you refused, however long the refusal takes. If your store keeps entries of its own after the last record, return the cursor the next `append()` should name as `head`. When a resumed turn left a tool call running, `resume({ onAmbiguous })` lets you return `"rerun"` to run it again under the same `executionId`. A resumed turn first sends, as `text_delta`, the reply the last process had started, since the new engine's host saw none of it. If that process stopped after the turn's final reply was stored but before the turn's end was, `resume()` then ends the turn with that reply instead of asking the model again, unless the turn took a steer after the reply was stored.

The engine sends one `append()` at a time, and everything that happens while one is in flight goes in the next record. `barrier` is `true` when something waits for the record, such as a tool call with effects, or a turn's `result`, which resolves only once the record that ends the turn is stored and rejects if that record can't be stored. A store may acknowledge a record with `barrier: false` before it is durable, as long as it keeps records in order and acknowledges a barrier only once it and every record before it are durable. A model request after a tool call waits for your answer to the record that holds the call's result, barrier or not, so it never goes out once you refused that record. Set `marks: true` to receive each record's `marks`, which say where turns start (`{ start: turnId }`), yield and end, with how a turn ended (`{ end: true, stopReason }`), and which inputs a turn took (`{ accepted: id }`), so a store can track turns without reading records.

`prompt()` and `resume()` take `yieldAt`, a time in milliseconds since the epoch: the turn stops before its next model request after that time, with the stop reason `yielded`, and the next `resume()` continues it without telling the model it was interrupted.

A journal or `checkpoint` from a newer libfx fails with `FxJournalVersionError`. An engine's own store keeps the conversation's images inline, where a session saves them by name, so a load may read a checkpoint of up to 32 MiB and up to 32 MiB of records after it; more fails with `FX_JOURNAL_TOO_LARGE`. Once a conversation is past what a checkpoint holds, 32 MiB or 1,024 turns, `checkpoint()` rejects with `FX_CHECKPOINT_TOO_LARGE` and the engine goes on; an engine with a store saves no more checkpoints, and `onEvent` gets a `checkpoint.error` with that code after each turn. `createMemoryPersistence()` is a reference store for tests.

A checkpoint records the libfx version, a hash of the tool set and the model it was taken with, so a restore can tell when one changed. It holds no credentials, instructions or tools, and restoring it doesn't choose the model: pass them again.

## Runtimes

| Runtime | Backend |
| --- | --- |
| Node.js 20+ on macOS or Linux, x64 or arm64 | Native addon. Linux needs glibc 2.34 or newer. |
| Node.js elsewhere | WebAssembly with JSPI. Some Node versions need `--experimental-wasm-jspi`. |
| Browsers | WebAssembly with JSPI, from `libfx/browser` |
| Bun | The same as Node.js. For WebAssembly, use Bun 1.3.10 or newer, except 1.3.14, which can crash when WebAssembly resumes through JSPI. |

Each platform's native addon ships as a version of libfx of its own, such as `libfx@0.0.15-0.linux-x64` beside `libfx@0.0.15`. libfx lists them as optional dependencies under the names `libfx-linux-x64`, `libfx-linux-arm64`, `libfx-darwin-x64` and `libfx-darwin-arm64`, so `npm install libfx` downloads only the one for the machine it runs on, and so do pnpm and Bun. No version range you write for libfx matches one of these versions. Install on the platform that runs the app: `node_modules` copied from a Mac into a Linux container has no Linux addon. Without its addon, such as with `npm install --omit=optional` or on a musl Linux, libfx runs on WebAssembly.

The default `backend: "auto"` tries the native addon first. Pass `"native"` or `"wasm"` to require one, and call `getBackendInfo()` to see what would load without creating anything. A `wasm` URL whose server answers with an error, such as a 404 for a file it doesn't serve, rejects with `LIBFX_WASM_LOAD_FAILED`, naming the URL and the status.

A process runs at most 64 native runtimes at once, across its worker threads. A durable session's turn holds one while it runs, and an engine from `createFxEngine()` holds one until it closes. When agents contend for them, no agent holds more than its share, so one agent's turns can't keep another's off the native addon:

- One agent is a name on a store, as queue deliveries tell agents apart. An agent's copies count as one, and so does an agent that replaced another under `NODE_ENV=development`. The engines that one JavaScript realm, such as the main thread or a worker, creates with `createFxEngine()` outside an agent count together as one more agent.
- An agent may take another native runtime while it holds fewer than 64 divided by the number of agents holding them, itself included, rounded down. The last free runtime is kept for an agent that holds none, so an agent alone holds at most 63, and a new agent's turn always starts natively.
- An engine beyond its agent's share, with `backend: "auto"` or `"native"`, runs on WebAssembly instead, and `onEvent` gets a `runtime.fallback` event. Without JSPI, where WebAssembly can't run, `createFxEngine()` rejects with `LIBFX_NATIVE_LIMIT`, naming the limit, and a durable session's turn ends with that error. libfx never waits for a native runtime to free.

Next.js works in Node.js route handlers, with webpack or Turbopack, and doesn't need `serverExternalPackages`: the build copies the addon into the output, so a Vercel deployment carries it. CommonJS apps can `require("libfx")`. With TypeScript's `moduleResolution: "bundler"`, add `"node"` to `customConditions` to get the Node.js types.

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

The terminal's `onEvent` gets the `transport.*` diagnostics an agent's does, and `terminal.size` only when the size changes. When the session store refuses a save with `FX_SESSION_REVISION_CONFLICT`, the store keeps its record, fx says on screen that it stopped saving the conversation, and `onEvent` gets `session.persist_error`. A workspace that breaks the version 1 rules is refused: fx runs without it, says so, and `onEvent` gets `workspace.invalid` naming the rule. With `permission: "prompt"`, fx asks before a command it would otherwise review, in `auto` mode too, since the browser has no safety reviewer.

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

Every entry point ships TypeScript types. libfx has no runtime dependencies; its native addons are optional dependencies, one version of libfx for each platform.

## For coding agents

- **Docs as Markdown:** the package's `docs/` folder holds the libfx docs as they were when it was built, indexed in `docs/README.md`. [fx.sh/llms.txt](https://fx.sh/llms.txt) indexes the latest pages, and each page has a `.md` version, such as `https://fx.sh/docs/lib/durability.md`. The declarations in `types/` are the exact API.
- **Agents at module scope:** create each agent once at module scope, not per request, and open `agent.session(id)` for each conversation.
- **Session ids:** take them from `turn.accepted` or `agent.newSessionId()`. On every durability except `memory()`, an id that isn't a Workflow run id throws.
- **Side effects:** every tool sets `idempotent`. Set it to `true` only on tools that are safe to run twice, and pass `executionId` to services that take an idempotency key.
- **Deployments:** on Vercel, the `wakeHandler()` route and its `vercel.json` trigger are both required, or prompts are stored and never run. The route must import the module that creates the agents.
- **Several agents:** give each durable agent its own `name`, and never rename one that has sessions.
- **Credentials:** keep keys and ChatGPT or Grok credentials on the server, and the object `startSignIn()` returns too.
- **Checking a setup:** `getBackendInfo()` reports which backend would load without creating anything or making requests.
- **Changing libfx:** the source is in the [fx repository](https://github.com/vercel-labs/fx) under `sdk/`. Its `AGENTS.md` files name the tests each change needs.

## Upgrading from 0.0.14

libfx no longer carries every platform's native addon. The addons are optional dependencies, one version of libfx per platform, which npm installs for the machine that runs `npm install`. Nothing changes in your code.

## Upgrading from 0.0.13

In libfx 0.0.13 and earlier, `createFxAgent()` created the engine. It now creates the durable agent, so rename those calls to `createFxEngine()`. Old code runs against the agent once its tools set `idempotent`, with a few differences: breaking out of a turn's events no longer cancels it, turns have no `cancel()` or `steer()` (the session does), and `persistence` and `sessionId` throw because the durability holds the session.

`libfxApiVersion` is now 3. Every tool given to `createFxAgent()` must set `idempotent`, and a tool's `writes` now defaults to the opposite of `idempotent`, in the engine too, so a tool that isn't marked idempotent runs alone. A journal written by this libfx can't be loaded by an older one, which fails with `FxJournalVersionError`.

## Security

Your tools, MCP clients and skill loaders have whatever access your code gives them. libfx orders their calls but grants nothing itself, and the native backend doesn't turn on fx's built-in shell or file tools. Don't put long-lived keys in browser code, and treat the `nativeAddon` and `gatewayChatUrl` options as trusted configuration.

## Contributing

libfx is developed in the [fx repository](https://github.com/vercel-labs/fx), under `sdk/`. Bug reports and pull requests are welcome. See [CONTRIBUTING.md](https://github.com/vercel-labs/fx/blob/main/CONTRIBUTING.md) to get started.

## License

[Apache-2.0](https://github.com/vercel-labs/fx/blob/main/LICENSE)
