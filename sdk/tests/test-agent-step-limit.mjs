#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-agent-step-limit.mjs [native|wasm]");
if (backend === "wasm" && !supportsJspi()) throw new Error("WebAssembly backend requires JSPI");

const toolSteps = 65;
let requests = 0;
let executions = 0;
const agent = await createFxAgent({
  backend,
  apiKey: "step-limit-test-key",
  model: "sdk/step-model",
  ...(backend === "native"
    ? { nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node") }
    : { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }),
  fetch(_url, init = {}) {
    if (init.method === "GET") {
      return Response.json({ object: "list", data: [{ id: "sdk/step-model", type: "language", tags: ["tool-use"] }] });
    }
    requests++;
    const events = requests <= toolSteps
      ? [
        { type: "tool-call", toolCallId: `call-${requests}`, toolName: "tick", input: { index: requests } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]
      : [
        { type: "text-delta", delta: "finished" },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      ];
    return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n", {
      headers: { "content-type": "text/event-stream" },
    });
  },
  tools: [{
    name: "tick",
    description: "Record a distinct step",
    inputSchema: { type: "object", properties: { index: { type: "integer" } }, required: ["index"] },
    execute({ index }) {
      assert.equal(index, executions + 1);
      executions++;
      return `completed step ${index}`;
    },
  }],
});
try {
  const turn = agent.prompt("Run 65 distinct tool steps, then finish.");
  const events = [];
  for await (const event of turn) events.push(event);
  const result = await turn.result;
  assert.equal(result.stopReason, "end_turn");
  assert.equal(requests, toolSteps + 1);
  assert.equal(executions, toolSteps);
  assert.equal(events.filter((event) => event.type === "tool_end").length, toolSteps);
  assert.equal(events.filter((event) => event.type === "text_delta").map((event) => event.delta).join(""), "finished");
} finally {
  await agent.close();
}
console.log(`${backend} agent continues after 64 model steps`);
