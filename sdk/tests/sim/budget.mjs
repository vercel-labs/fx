#!/usr/bin/env node
// Budgets for a long image session: what a turn costs must not grow with the
// images the session has seen. Each turn sends one new 3.75 MiB image to a
// session with an image store, and the run fails when
//
//   - a turn ends other than `end_turn`;
//   - memory passes `--memory-factor` times the image bytes the session
//     holds, plus `--memory-base` MiB: the core's linear memory on wasm,
//     which never shrinks, or the growth of the process's resident memory on
//     native, which also counts the memory store's own copy of each image;
//   - the last ten turns take more than `--time-ratio` times as long as
//     turns 6 to 15.
//
//   node --expose-gc sdk/tests/sim/budget.mjs [--backend wasm|native] [--turns 60]
//
// SIM_ADDON and SIM_WASM measure another build, such as one without a fix.
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, createMemoryPersistence } from "../../node.js";
import { withImageStore } from "./world.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => (args.includes(`--${name}`) ? args[args.indexOf(`--${name}`) + 1] : fallback);
const backend = option("backend", "wasm");
const turns = Number(option("turns", 60));
// Measured at 60 turns: 3.4 on wasm and 4.1 on native, against 11.4 and 10.0
// when each request was first built with every image.
const memoryFactor = Number(option("memory-factor", backend === "wasm" ? 4 : 5));
const memoryBase = Number(option("memory-base", 96));
const timeRatio = Number(option("time-ratio", 3));
if (turns < 25) throw new Error("--turns must be at least 25, so the last ten turns follow the first fifteen");

const scriptDir = dirname(fileURLToPath(import.meta.url));
const addon = process.env.SIM_ADDON ?? resolve(scriptDir, "../../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(process.env.SIM_WASM ?? resolve(scriptDir, "../../../zig-out/bin/fx-core.wasm")) : undefined;
const mib = (bytes) => Math.round((bytes / (1024 * 1024)) * 10) / 10;

// The core's linear memory, captured as the SDK instantiates the module.
const memories = [];
const instantiate = WebAssembly.instantiate;
WebAssembly.instantiate = async (...input) => {
  const result = await instantiate(...input);
  const memory = (result.instance ?? result)?.exports?.memory;
  if (memory) memories.push(memory);
  return result;
};
const memoryBytes = () => (backend === "wasm" ? memories.at(-1)?.buffer.byteLength ?? 0 : process.memoryUsage().rss);

// A PNG header, then filler, then a counter, so each image has its own name.
const imageBytes = 3_932_160;
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=", "base64");
const imageOf = (n) => {
  const bytes = new Uint8Array(imageBytes);
  bytes.set(png);
  for (let index = png.length; index < bytes.length; index += 1) bytes[index] = (index * 31) & 255;
  new DataView(bytes.buffer).setUint32(70, n);
  return bytes;
};

// A model that answers "ok" without reading the request, so the run measures
// libfx and not the stand-in.
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
let largestRequest = 0;
const fetch = async (input, init) => {
  const request = input instanceof Request ? input : new Request(input, init);
  if (request.method === "GET") {
    return Response.json({ object: "list", data: [{ id: "budget/vision", type: "language", context_window: 2_000_000, max_tokens: 8192, tags: ["vision", "file-input"] }] });
  }
  largestRequest = Math.max(largestRequest, (await request.arrayBuffer()).byteLength);
  const frames = [{ type: "text-delta", id: "answer", delta: "ok" }, { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage }];
  return new Response(frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
};

const broken = [];
const times = [];
const engine = await createFxEngine({
  backend,
  nativeAddon: addon,
  ...(wasm ? { wasm } : {}),
  apiKey: "budget-key",
  model: "budget/vision",
  fetch,
  persistence: withImageStore(createMemoryPersistence()),
});
const startMemory = memoryBytes();
let peakMemory = startMemory;
const started = performance.now();
for (let turn = 0; turn < turns; turn += 1) {
  const before = performance.now();
  try {
    const run = engine.prompt([{ type: "text", text: `look ${turn}` }, { type: "image", data: imageOf(turn), mimeType: "image/png" }]);
    for await (const _ of run) {}
    const { stopReason } = await run.result;
    if (stopReason !== "end_turn") broken.push(`turn ${turn + 1} ended ${stopReason}`);
  } catch (error) {
    broken.push(`turn ${turn + 1} failed: ${error?.code ?? ""} ${error?.message}`);
    break;
  }
  times.push(performance.now() - before);
  globalThis.gc?.();
  peakMemory = Math.max(peakMemory, memoryBytes());
  if ((turn + 1) % 10 === 0) console.log(JSON.stringify({ turn: turn + 1, imagesMiB: mib((turn + 1) * imageBytes), memoryMiB: mib(memoryBytes()), turnMs: Math.round(times.at(-1)) }));
}
await engine.close().catch(() => {});

// The session holds every image it was sent, within its default window.
const heldBytes = Math.min(times.length * imageBytes, 512 * 1024 * 1024);
const grown = backend === "wasm" ? peakMemory : peakMemory - startMemory;
const memoryLimit = memoryFactor * heldBytes + memoryBase * 1024 * 1024;
if (grown > memoryLimit) broken.push(`memory reached ${mib(grown)} MiB, past ${mib(memoryLimit)} MiB for ${mib(heldBytes)} MiB of images`);
const mean = (values) => values.reduce((sum, value) => sum + value, 0) / values.length;
const early = times.length >= 15 ? mean(times.slice(5, 15)) : null;
const late = times.length >= 25 ? mean(times.slice(-10)) : null;
if (early !== null && late !== null && late > timeRatio * early) broken.push(`the last ten turns took ${Math.round(late)} ms each, more than ${timeRatio} times turns 6 to 15 (${Math.round(early)} ms)`);
console.log(JSON.stringify({
  backend,
  turns: times.length,
  seconds: Math.round((performance.now() - started) / 100) / 10,
  heldMiB: mib(heldBytes),
  memoryMiB: mib(grown),
  memoryPerImageByte: Math.round((grown / heldBytes) * 100) / 100,
  earlyTurnMs: early && Math.round(early),
  lateTurnMs: late && Math.round(late),
  largestRequestMiB: mib(largestRequest),
}));
for (const rule of broken) console.log(`  ${rule}`);
console.log(`${broken.length === 0 ? "ok" : "FAIL"} budget (${backend}, ${times.length} turns)`);
process.exit(broken.length === 0 ? 0 : 1);
