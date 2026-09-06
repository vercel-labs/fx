#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../sdk/node.js";

const args = process.argv.slice(2);
const value = (name, fallback) => {
  const index = args.indexOf(name);
  return index < 0 ? fallback : args[index + 1];
};
const backend = value("--backend", "native");
const samples = Number(value("--samples", "20"));
if (!new Set(["native", "wasm"]).has(backend) || !Number.isInteger(samples) || samples < 1 || samples > 1000) {
  throw new Error("usage: bench-bridge.mjs --backend native|wasm --samples 1..1000");
}

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const stages = [];
let requestIndex = 0;
let catalogRequests = 0;
const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      catalogRequests += 1;
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"object":"list","data":[{"id":"bridge/model","type":"language","tags":["tool-use"]}]}');
      return;
    }
    const sample = Math.floor(requestIndex / 2);
    const followup = requestIndex % 2 === 1;
    requestIndex += 1;
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (!followup) {
      stages[sample] = { tool_event_at: performance.now() };
      response.end(`data: {"type":"tool-call","toolCallId":"bridge_${sample}","toolName":"bridge_echo","input":{"value":"${sample}"}}\n\ndata: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"}}\n\ndata: [DONE]\n\n`);
      return;
    }
    stages[sample].followup_fetch_at = performance.now();
    if (!body.includes(`bridge:${sample}`)) throw new Error("bridge result missing from follow-up request");
    response.end('data: {"type":"text-delta","delta":"ok"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n');
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));

let activeSample = 0;
const agent = await createFxAgent({
  backend,
  nativeAddon: resolve(root, "zig-out/lib/libfx.node"),
  ...(backend === "wasm" ? { wasm: await readFile(resolve(root, "zig-out/bin/fx-core.wasm")) } : {}),
  fetch(input, init) {
    return fetch(init.method === "GET" ? `http://127.0.0.1:${server.address().port}/models` : input, init);
  },
  tools: [{
    name: "bridge_echo",
    description: "Measure the host tool bridge",
    inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] },
    execute(input) {
      stages[activeSample].callback_at = performance.now();
      return `bridge:${input.value}`;
    },
  }],
  apiKey: "bridge-key",
  gatewayChatUrl: `http://127.0.0.1:${server.address().port}/chat`,
  model: "bridge/model",
});

try {
  for (activeSample = 0; activeSample < samples; activeSample++) {
    const turn = agent.prompt(`bridge sample ${activeSample}`);
    for await (const _ of turn) {}
    if ((await turn.result).stopReason !== "end_turn") throw new Error("bridge sample did not finish");
  }
  const report = stages.map((stage) => ({
    tool_event_to_callback_ms: stage.callback_at - stage.tool_event_at,
    callback_to_followup_fetch_ms: stage.followup_fetch_at - stage.callback_at,
    tool_round_trip_ms: stage.followup_fetch_at - stage.tool_event_at,
  }));
  if (catalogRequests !== 1 || requestIndex !== 2 * samples) throw new Error("unexpected bridge request counts");
  process.stdout.write(`${JSON.stringify({
    format_version: 1,
    runtime: typeof Bun === "undefined" ? "node" : "bun",
    runtime_version: typeof Bun === "undefined" ? process.version : Bun.version,
    backend,
    non_prompt_fetches: catalogRequests,
    samples: report,
  }, null, 2)}\n`);
} finally {
  await agent.close();
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
