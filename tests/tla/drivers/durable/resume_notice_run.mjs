#!/usr/bin/env bun
// One life of a libfx process for tests/tla/drivers/durable/resume_notice.ts.
// It opens an agent on a journal kept in a file, starts a turn or resumes the
// open one, runs it to its end, closes the agent, and prints one JSON line.
// The driver starts it with a clean environment and kills it to crash it.
//
//   bun resume_notice_run.mjs --backend native|wasm --store <file>
//     (--prompt <text> | --resume) [--yield] [--fence <file>] [--hang-first-append]
//
// The store is one JSON event per line, written synchronously, so a kill
// leaves exactly what was stored. Once the file --fence names exists, the
// store refuses every append as fenced, as it does when another worker took
// the session over. With --hang-first-append the life's first append never
// lands. --yield gives the turn a deadline long past, so it stops at its
// first chance. The model gateway is FX_GATEWAY_BASE_URL and nothing else.
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, FxFencedError } from "../../../../sdk/node.js";

const root = resolve(fileURLToPath(new URL(".", import.meta.url)), "../../../..");
const args = process.argv.slice(2);
const option = (name) => {
  const at = args.indexOf(`--${name}`);
  return at >= 0 ? args[at + 1] : undefined;
};
const flag = (name) => args.includes(`--${name}`);
const backend = option("backend") ?? "native";
const storePath = option("store");
const fencePath = option("fence");
const prompt = option("prompt");
if (!storePath || (prompt === undefined) === !flag("resume")) {
  throw new Error("usage: resume_notice_run.mjs --store <file> (--prompt <text> | --resume)");
}
const base = new URL(process.env.FX_GATEWAY_BASE_URL);
const wasm = backend === "wasm" ? await readFile(resolve(root, "zig-out/bin/fx-core.wasm")) : undefined;

const say = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const encodeRecord = (events) => new TextEncoder().encode(JSON.stringify({ format: "libfx-journal-v1", events }));
const decodeRecord = (data) => JSON.parse(new TextDecoder().decode(data)).events;
const stored = () => (existsSync(storePath)
  ? readFileSync(storePath, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line))
  : []);
const headOf = (events) => (events.length ? String(events.at(-1).seq) : null);

let appends = 0;
const persistence = {
  async load() {
    const events = stored();
    return { journal: events.length ? [{ cursor: headOf(events), data: encodeRecord(events) }] : [] };
  },
  async append({ expected, data }) {
    appends += 1;
    if (appends === 1 && flag("hang-first-append")) {
      say({ hanging: true });
      return new Promise(() => {});
    }
    if (fencePath && existsSync(fencePath)) throw new FxFencedError("another worker took the session over");
    const events = stored();
    if (expected !== headOf(events)) throw new FxFencedError(`expected ${expected}, head ${headOf(events)}`);
    const batch = decodeRecord(data);
    appendFileSync(storePath, batch.map((event) => `${JSON.stringify(event)}\n`).join(""));
    return { cursor: String(batch.at(-1).seq) };
  },
};

// The model list is fetched from the public Gateway; it goes to the fake one.
let outside = 0;
const localFetch = (input, init) => {
  const url = new URL(String(input?.url ?? input));
  if (url.host === base.host) return fetch(input, init);
  if (url.hostname === "ai-gateway.vercel.sh") return fetch(new URL(`${url.pathname}${url.search}`, base), init);
  outside += 1;
  return Promise.reject(new Error(`the driver reaches only its fake gateway, not ${url.host}`));
};

const lookup = {
  name: "lookup",
  description: "Looks up a key",
  inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
  execute: async ({ key }) => `value of ${key}`,
};

const agent = await createFxEngine({
  backend,
  nativeAddon: resolve(root, "zig-out/lib/libfx.node"),
  ...(wasm ? { wasm } : {}),
  fetch: localFetch,
  apiKey: process.env.AI_GATEWAY_API_KEY,
  gatewayChatUrl: process.env.FX_GATEWAY_CHAT_URL,
  model: "journal/model",
  tools: [lookup],
  persistence,
});
const turnOptions = flag("yield") ? { yieldAt: 1 } : {};
let stop = null;
let error = null;
try {
  const turn = prompt === undefined ? agent.resume(turnOptions) : agent.prompt(prompt, turnOptions);
  if (!turn) throw new Error("the journal holds no turn to resume");
  for await (const _ of turn) {}
  stop = (await turn.result).stopReason;
} catch (caught) {
  error = `${caught?.name ?? "Error"}: ${caught?.message ?? caught}`;
}
try {
  await agent.close();
} catch (caught) {
  error ??= `${caught?.name ?? "Error"}: ${caught?.message ?? caught}`;
}
say({ done: true, stop, error, outside });
