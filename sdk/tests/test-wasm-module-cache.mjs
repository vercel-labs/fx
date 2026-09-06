#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"));
const temp = await mkdtemp(join(tmpdir(), "libfx-wasm-cache-"));
const secondPath = join(temp, "second.wasm");
const retryPath = join(temp, "retry.wasm");
const missingPath = join(temp, "missing.wasm");
const wasmBytes = await readFile(wasmPath);
await writeFile(secondPath, wasmBytes);
await writeFile(retryPath, wasmBytes);

const requestBodies = [];
const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"object":"list","data":[]}');
      return;
    }
    requestBodies.push(body);
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end('data: {"type":"text-delta","delta":"cached"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\ndata: [DONE]\n\n');
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));

const compileDescriptor = Object.getOwnPropertyDescriptor(WebAssembly, "compile");
const instantiateDescriptor = Object.getOwnPropertyDescriptor(WebAssembly, "instantiate");
const realInstantiate = WebAssembly.instantiate.bind(WebAssembly);
const instances = [];
Object.defineProperty(WebAssembly, "instantiate", {
  ...instantiateDescriptor,
  value: async (...args) => {
    const instance = await realInstantiate(...args);
    instances.push(new WeakRef(instance));
    return instance;
  },
});
const realCompile = WebAssembly.compile.bind(WebAssembly);
let compileCalls = 0;
let failNextCompile = false;
Object.defineProperty(WebAssembly, "compile", {
  ...compileDescriptor,
  configurable: true,
  value: async (bytes) => {
    compileCalls += 1;
    if (failNextCompile) {
      failNextCompile = false;
      throw new Error("injected Wasm compilation failure");
    }
    return realCompile(bytes);
  },
});

const agents = [];
const signals = [];
const options = (wasm = wasmPath) => ({
  backend: "wasm",
  wasm,
  fetch(input, init) {
    signals.push({ method: init.method, signal: init.signal });
    return fetch(init.method === "GET" ? `http://127.0.0.1:${server.address().port}/models` : input, init);
  },
  apiKey: "wasm-cache-key",
  gatewayChatUrl: `http://127.0.0.1:${server.address().port}/chat`,
  model: "cache/model",
});

async function create(wasm = wasmPath) {
  const agent = await createFxAgent(options(wasm));
  agents.push(agent);
  return agent;
}

async function prompt(agent, text) {
  const turn = agent.prompt(text);
  let output = "";
  for await (const event of turn) if (event.type === "text_delta") output += event.delta;
  assert.equal(output, "cached");
  assert.equal((await turn.result).stopReason, "end_turn");
}

try {
  const [alpha, beta] = await Promise.all([create(), create()]);
  const gamma = await create(pathToFileURL(wasmPath));
  assert.equal(compileCalls, 1, "matching concurrent and sequential Agent creation must compile once");

  await prompt(alpha, "ALPHA_CACHE_SENTINEL");
  await prompt(beta, "BETA_CACHE_SENTINEL");
  await alpha.close();
  await prompt(gamma, "GAMMA_CACHE_SENTINEL");

  assert.match(requestBodies[0], /ALPHA_CACHE_SENTINEL/);
  assert.doesNotMatch(requestBodies[0], /BETA_CACHE_SENTINEL|GAMMA_CACHE_SENTINEL/);
  assert.match(requestBodies[1], /BETA_CACHE_SENTINEL/);
  assert.doesNotMatch(requestBodies[1], /ALPHA_CACHE_SENTINEL|GAMMA_CACHE_SENTINEL/);
  assert.match(requestBodies[2], /GAMMA_CACHE_SENTINEL/);
  assert.doesNotMatch(requestBodies[2], /ALPHA_CACHE_SENTINEL|BETA_CACHE_SENTINEL/);
  assert.equal(compileCalls, 1, "closing one Agent must not evict the shared compiled module");

  await create(secondPath);
  assert.equal(compileCalls, 2, "a distinct canonical source must compile independently");

  failNextCompile = true;
  await assert.rejects(createFxAgent(options(retryPath)), /injected Wasm compilation failure/);
  const retried = await create(retryPath);
  await retried.close();
  assert.equal(compileCalls, 4, "a rejected compilation must be removed so the next attempt retries");

  await assert.rejects(createFxAgent(options(missingPath)), /ENOENT|no such file/i);
  await writeFile(missingPath, wasmBytes);
  const recoveredRead = await create(missingPath);
  await recoveredRead.close();
  assert.equal(compileCalls, 5, "a rejected file read must be removed so the next attempt retries");

  await Promise.all(agents.map((agent) => agent.close()));
  assert.ok(signals.every(({ signal }) => signal instanceof AbortSignal));
  // Completed catalog reads have already released their abort ownership.
  assert.ok(signals.filter(({ method }) => method !== "GET").every(({ signal }) => signal.aborted));
  const collect = globalThis.gc ?? (() => globalThis.Bun?.gc(true));
  const deadline = Date.now() + 5000;
  do {
    await new Promise((resolveGc) => setTimeout(resolveGc, 10));
    collect();
  } while (instances.some((instance) => instance.deref()) && Date.now() < deadline);
  assert.ok(instances.every((instance) => !instance.deref()), "retained closed Agents must release their Wasm instances");

  console.log(`${process.versions.bun ? "Bun" : "Node"} Wasm module cache passed: compilation reuse, retry, isolation, and closed-instance release`);
} finally {
  Object.defineProperty(WebAssembly, "compile", compileDescriptor);
  Object.defineProperty(WebAssembly, "instantiate", instantiateDescriptor);
  await Promise.all(agents.map((agent) => agent.close().catch(() => {})));
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
  await rm(temp, { recursive: true, force: true });
}
