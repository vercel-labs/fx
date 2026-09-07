#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createRequire } from "node:module";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const directory = resolve(process.argv[2]);
const entries = [
  ["esm", await import(pathToFileURL(join(directory, "node.js")).href)],
  ["cjs", createRequire(import.meta.url)(join(directory, "node.cjs"))],
];
const assets = {
  agent: await readFile(join(directory, "fx-core.wasm")),
  terminal: await readFile(join(directory, "fx-term.wasm")),
};
const requests = new Map();
const corrupt = new Set();
const server = createServer((request, response) => {
  requests.set(request.url, (requests.get(request.url) ?? 0) + 1);
  response.writeHead(200, { "content-type": "application/wasm" });
  response.end(corrupt.has(request.url) ? Buffer.from("invalid Wasm") : assets[request.url.split("/")[1]]);
});
await new Promise((listen) => server.listen(0, "127.0.0.1", listen));
const origin = `http://127.0.0.1:${server.address().port}`;
const modelMethods = [];
const modelFetch = async (_url, init) => {
  const method = init?.method ?? "GET";
  modelMethods.push(method);
  if (method === "GET") return Response.json({ object: "list", data: [] });
  assert.equal(method, "POST");
  return new Response('data: {"type":"text-delta","delta":"async asset"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\ndata: [DONE]\n\n', {
    headers: { "content-type": "text/event-stream" },
  });
};
let completed = 0;
let agentTurns = 0;
const watchdog = setTimeout(() => { console.error("Node async asset test timed out"); process.exit(1); }, 60_000);
watchdog.unref();

async function exercise(sdk, surface, options) {
  if (surface === "agent") {
    const agent = await sdk.createFxAgent({ ...options, apiKey: "async-asset-key", model: "async/model", fetch: modelFetch });
    try {
      const turn = agent.prompt("hello");
      let text = "";
      for await (const event of turn) if (event.type === "text_delta") text += event.delta;
      assert.equal(text, "async asset");
      assert.equal((await turn.result).stopReason, "end_turn");
      assert.ok((await agent.checkpoint()).length > 48);
      agentTurns++;
    }
    finally { await agent.close(); }
    return;
  }
  const data = new Set();
  const resize = new Set();
  let output = 0;
  const terminal = {
    cols: 80, rows: 24,
    write(bytes) { output += bytes.byteLength; },
    onData(listener) { data.add(listener); return () => data.delete(listener); },
    onResize(listener) { resize.add(listener); return () => resize.delete(listener); },
  };
  let runtime;
  try {
    runtime = await sdk.createFxTerminal({ ...options, terminal, fetch: modelFetch,
      env: { AI_GATEWAY_API_KEY: "async-asset-key", FX_SOUND: "0" } });
    await runtime.interactive;
    assert.ok(output > 0);
  }
  finally {
    if (runtime) {
      runtime.abort();
      assert.equal(await runtime.exited, 130);
    }
    assert.equal(data.size, 0);
    assert.equal(resize.size, 0);
  }
}

try {
  for (const [format, sdk] of entries) {
    assert.equal(sdk.supportsJspi(), true, "run with --experimental-wasm-jspi");
    for (const surface of ["agent", "terminal"]) {
      for (const backend of ["wasm", "auto"]) {
        for (const source of ["promise-url", "direct-url", "promise-response", "promise-bytes", "promise-module"]) {
          const path = `/${surface}/${format}-${backend}-${source}.wasm`;
          const url = `${origin}${path}`;
          const wasm = source === "promise-url" ? Promise.resolve(url)
            : source === "direct-url" ? url
            : source === "promise-response" ? fetch(url)
            : source === "promise-bytes" ? Promise.resolve(assets[surface])
            : WebAssembly.compile(assets[surface]);
          await exercise(sdk, surface, { backend, nativeAddon: false, wasm });
          if (source.endsWith("url")) {
            assert.equal(requests.get(path), 1, "cold URL inputs must fetch the selected asset");
            const info = await sdk.getBackendInfo({ surface, backend, nativeAddon: false, wasm: Promise.resolve(url) });
            assert.equal(info.backend, "wasm-jspi", JSON.stringify(info));
            assert.equal(requests.get(path), 1, "probe and factory must reuse the resolved URL's module");
          }
          completed++;
        }
        const error = Object.assign(new Error("asset resolver failed"), { code: "ASSET_RESOLVER_FAILED" });
        await assert.rejects(exercise(sdk, surface, { backend, nativeAddon: false, wasm: Promise.reject(error) }), (actual) => actual === error);
        const info = await sdk.getBackendInfo({ surface, backend, nativeAddon: false, wasm: Promise.reject(error) });
        assert.equal(info.backend, "unavailable");
        assert.equal(info.attempts.at(-1).reason.code, "LIBFX_WASM_LOAD_FAILED");
        assert.equal(info.attempts.at(-1).reason.causeCode, error.code);
      }
      const path = `/${surface}/${format}-repair.wasm`;
      const wasm = Promise.resolve(`${origin}${path}`);
      corrupt.add(path);
      const failed = await sdk.getBackendInfo({ surface, backend: "wasm", wasm });
      assert.equal(failed.backend, "unavailable");
      assert.equal(failed.attempts[0].reason.code, "LIBFX_WASM_LOAD_FAILED");
      assert.equal(requests.get(path), 1, "the failed probe must reach compilation of the requested asset");
      corrupt.delete(path);
      const info = await sdk.getBackendInfo({ surface, backend: "wasm", wasm });
      assert.equal(info.backend, "wasm-jspi", JSON.stringify(info));
      await exercise(sdk, surface, { backend: "wasm", wasm });
      assert.equal(requests.get(path), 2, "failed modules must retry and repaired modules must remain cached");
    }
  }
  assert.equal(modelMethods.filter((method) => method === "POST").length, agentTurns);
  assert.equal(agentTurns, 22);
  console.log(`Node async assets passed: ${completed} input/surface/backend/format cases, ${agentTurns} agent turns, resolver failures, and repair`);
} finally {
  clearTimeout(watchdog);
  server.closeAllConnections();
  await new Promise((close) => server.close(close));
}
