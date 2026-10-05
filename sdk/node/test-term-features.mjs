#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-term.wasm"));
if (!supportsJspi()) process.exit(2);

const terminal = new Terminal({ cols: 100, rows: 34, allowProposedApi: true, scrollback: 2000 });
const config = new Map([["model", "test/feature-model"], ["mode", "ask"]]);
const requests = [];
const clipboardWrites = [];
const catalog = {
  object: "list",
  data: [
    { id: "test/feature-model", type: "language", released: 2, tags: ["tool-use", "reasoning"], context_window: 128000, max_tokens: 8192 },
    { id: "test/other-model", type: "language", released: 1, tags: ["tool-use"], context_window: 64000, max_tokens: 4096 },
  ],
};
const encoder = new TextEncoder();
let turn = 0;
let catalogRequests = 0;
const fetch = async (url, init = {}) => {
  if ((init.method || "GET") === "GET") {
    catalogRequests += 1;
    return new Response(JSON.stringify(catalog), { status: 200, headers: { "content-type": "application/json" } });
  }
  const body = JSON.parse(new TextDecoder().decode(init.body));
  requests.push(body);
  turn += 1;
  const response = turn === 1 ? "first answer" : "second answer";
  return new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(`data: {"type":"text-delta","delta":"${response}"}\n\n`));
      controller.enqueue(encoder.encode('data: {"type":"finish","finishReason":{"unified":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}\n\n'));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });
};
const stderrDecoder = new TextDecoder();
let stderrText = "";
const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: xtermAdapter(terminal),
  env: {
    AI_GATEWAY_API_KEY: "feature-key",
    FX_TRACE_STDERR: "1",
    FX_TRACE_SCOPES: "full_transcript,full_transcript_cache,frame_schedule",
  },
  fetch,
  clipboard: { writeText(value) { clipboardWrites.push(value); } },
  configStore: { get(id) { return config.get(id) ?? null; }, set(id, value) { config.set(id, value); } },
  stderr(chunk) { stderrText += stderrDecoder.decode(chunk, { stream: true }); },
});
const flush = () => new Promise((resolve) => terminal.write("", resolve));
const grid = () => {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row++) lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  return lines.join("\n");
};
async function waitFor(predicate, label) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    await flush();
    if (performance.now() >= deadline) {
      const trace = stderrText.split("\n").slice(-50).join("\n");
      throw new Error(`timed out waiting for ${label}:\n${trace}\n${grid()}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
async function command(text, expected) {
  runtime.write(`${text}\r`);
  await waitFor(() => grid().includes(expected), expected);
}

await waitFor(() => grid().includes("𝒇x"), "startup");
assert.equal(catalogRequests, 0, "ordinary terminal startup must not fetch the catalog");
runtime.write("clipboard draft");
runtime.write("\x1b[97;9u\x1b[99;9u");
await waitFor(() => clipboardWrites.length === 1, "composer copy");
runtime.write("\x1b[120;9u");
await waitFor(() => clipboardWrites.length === 2, "composer cut");
if (clipboardWrites.some((value) => value !== "clipboard draft")) {
  throw new Error(`unexpected clipboard writes: ${JSON.stringify(clipboardWrites)}`);
}
runtime.write("undo probe\x1b[122;9u");
await command("first question", "first answer");
await command("second question", "second answer");
if (requests.length !== 2) throw new Error(`expected two gateway turns, got ${requests.length}`);
assert.equal(catalogRequests, 0, "ordinary terminal prompts must not add catalog requests");
const secondBody = JSON.stringify(requests[1]);
const firstBody = JSON.stringify(requests[0]);
for (const removed of ["clipboard draft", "undo probe"]) {
  if (firstBody.includes(removed)) throw new Error(`composer edit survived cut or undo: ${firstBody}`);
}
for (const expected of ["first question", "first answer", "second question"]) {
  if (!secondBody.includes(expected)) throw new Error(`second turn omitted ${expected}: ${secondBody}`);
}

runtime.write("\x0f");
await waitFor(() => terminal.buffer.active.type === "alternate", "full transcript alternate screen");
runtime.write("\x1b[C");
await waitFor(() => grid().includes("full detail"), "full transcript detail");
runtime.write("\x0f");
await waitFor(() => terminal.buffer.active.type === "normal", "full transcript close");

await command("/login", "Vercel sign-in failed. The current credential is unchanged.");
await command("/resume", "Session resume is owned by the embedding SDK");
runtime.write("/mcp list\r");
await waitFor(
  () => grid().includes("MCP 0") && grid().includes("[Servers]") && grid().includes("No MCP servers configured"),
  "MCP server menu",
);
runtime.write("\x1b");
await waitFor(() => !grid().includes("[Servers]"), "MCP server menu close");
await command("/skills list", "Skills are unavailable in this host");

runtime.write("/model\r");
await waitFor(() => grid().includes("feature-model") && grid().includes("other-model"), "model catalog menu");
runtime.write("\x1b");
await waitFor(() => !grid().includes("tab provider"), "model catalog close");

runtime.write("/exit\r");
const code = await Promise.race([runtime.exited, new Promise((_, reject) => setTimeout(() => reject(new Error("exit timeout")), 5000))]);
if (code !== 0) throw new Error(`fx-term exited with ${code}`);
console.log("headless features passed: clipboard, history, transcript, catalog, and host degradation");

async function runUltrafastTerminal(scenario) {
  const terminal = new Terminal({ cols: 100, rows: 32, allowProposedApi: true, scrollback: 2000 });
  const host = xtermAdapter(terminal);
  const released = { data: 0, resize: 0, key: 0 };
  const adapter = {
    ...host,
    onData(callback) {
      const unsubscribe = host.onData(callback);
      return () => { released.data += 1; unsubscribe(); };
    },
    onResize(callback) {
      const unsubscribe = host.onResize(callback);
      return () => { released.resize += 1; unsubscribe(); };
    },
    ...(host.onKeyData ? { onKeyData(callback) {
      const unsubscribe = host.onKeyData(callback);
      return () => { released.key += 1; unsubscribe(); };
    } } : {}),
  };
  const model = "openai/gpt-6-astra";
  const posts = [];
  let gets = 0;
  let catalogAborted = 0;
  const fetch = async (url, init = {}) => {
    const method = String(init.method ?? "GET").toUpperCase();
    if (method === "GET") {
      assert.equal(new URL(url).pathname, "/coding-agent/v1/models");
      gets += 1;
      if (scenario === "cancel") {
        return new Promise((_, reject) => {
          init.signal.addEventListener("abort", () => {
            catalogAborted += 1;
            reject(new DOMException("catalog cancelled", "AbortError"));
          }, { once: true });
        });
      }
      const pricing = {
        service_tiers: { ultrafast: { input: "0.00006", output: "0.0003" } },
        ...(scenario === "unsupported" ? { input_cache_read: "0.000001" } : {}),
      };
      return Response.json({ data: [{ id: model, type: "language", owned_by: "openai", pricing }] });
    }
    assert.equal(method, "POST");
    assert.equal(new URL(url).origin, "http://127.0.0.1:44888");
    const body = JSON.parse(new TextDecoder().decode(init.body));
    posts.push(body);
    const frames = [
      { type: "text-delta", delta: `ultra answer ${posts.length}` },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } }, providerMetadata: { gateway: { serviceTier: body.providerOptions?.openai?.serviceTier === "ultrafast" ? "ultrafast" : "standard" } } },
    ];
    return new Response(frames.map(frame => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
  };
  const runtime = await createFxTerminal({
    backend: "wasm",
    wasm: await readFile(wasmPath),
    terminal: adapter,
    env: { AI_GATEWAY_API_KEY: "term-ultrafast-fake-key", FX_PROVIDER: "gateway", FX_MODEL: model, FX_ULTRAFAST: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_GATEWAY_CHAT_URL: "http://127.0.0.1:44888/v4/ai/language-model" },
    fetch,
  });
  const grid = () => {
    const lines = [];
    for (let row = 0; row < terminal.buffer.active.length; row++) lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
    return lines.join("\n");
  };
  async function waitFor(predicate, label) {
    const deadline = performance.now() + 5000;
    while (!predicate()) {
      await new Promise(resolve => terminal.write("", resolve));
      if (performance.now() >= deadline) throw new Error(`${scenario}: timed out waiting for ${label}:\n${grid()}`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
  }
  async function prompt(text) {
    const count = posts.length + 1;
    runtime.write(`${text}\r`);
    await waitFor(() => grid().includes(`ultra answer ${count}`) && !grid().includes("Thinking"), "completed reply");
    assert.equal(posts.length, count);
    return posts.at(-1);
  }
  function assertUltra(body) {
    assert.equal(body.providerOptions?.openai?.serviceTier, "ultrafast");
    assert.deepEqual(body.providerOptions?.gateway?.only, ["openai"]);
    assert.equal(body.providerOptions?.gateway?.speed, undefined);
    assert.equal(body.providerOptions?.gateway?.fast, undefined);
  }
  try {
    await runtime.interactive;
    await waitFor(() => grid().includes("Run /help for commands"), "startup frame");
    assert.equal(gets, 0, "Ultrafast must not add synchronous catalog I/O to startup");
    if (scenario === "unsupported") {
      runtime.write("unsupported ultra request\r");
      await waitFor(() => grid().includes("UltrafastUnavailable"), "fail-closed catalog rejection");
      assert.equal(gets, 1);
      assert.equal(posts.length, 0);
      runtime.abort();
      assert.equal(await runtime.exited, 130);
    } else if (scenario === "cancel") {
      runtime.write("cancel pending catalog\r");
      await waitFor(() => gets === 1, "pending catalog request");
      assert.equal(posts.length, 0);
      runtime.write("\x03");
      await waitFor(() => grid().includes("Cancelled") || grid().includes("cancelled"), "cancelled turn");
      assert.equal(catalogAborted, 1);
      assert.equal(posts.length, 0);
      runtime.write("/ultrafast off\r");
      await waitFor(() => grid().includes("requested off"), "disable after cancellation");
      const body = await prompt("follow up after cancellation");
      assert.equal(body.providerOptions?.openai?.serviceTier, undefined);
      assert.equal(gets, 1);
      runtime.write("/exit\r");
      assert.equal(await runtime.exited, 0);
    } else {
      assertUltra(await prompt("ultra first"));
      assert.equal(gets, 1);
      runtime.write("/ultrafast off\r");
      await waitFor(() => grid().includes("requested off"), "slash disable");
      const normal = await prompt("ordinary follow up");
      assert.equal(normal.providerOptions?.openai?.serviceTier, undefined);
      assert.equal(normal.providerOptions?.gateway?.only, undefined);
      assert.ok(JSON.stringify(normal.prompt).includes("ultra first"));
      assert.ok(JSON.stringify(normal.prompt).includes("ultra answer 1"));
      runtime.write("/ultrafast on\r");
      await waitFor(() => grid().includes("requested on"), "slash enable");
      assertUltra(await prompt("ultra follow up"));
      assert.equal(gets, 1, "the validated catalog must be reused");
      runtime.write("/exit\r");
      assert.equal(await runtime.exited, 0);
    }
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.deepEqual(released, { data: 1, resize: 1, key: host.onKeyData ? 1 : 0 });
  } finally {
    runtime.abort();
    terminal.dispose();
  }
}

for (const scenario of ["supported", "unsupported", "cancel"]) await runUltrafastTerminal(scenario);
console.log("Ultrafast terminal regressions passed: lazy catalog, exclusive routing, slash controls, rejection, cancellation, follow-up, cleanup");
