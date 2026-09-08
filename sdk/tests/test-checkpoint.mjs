#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const sourceBackend = process.argv[2] || "native";
const targetBackend = process.argv[3] || "wasm";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"));
for (const shape of ["plain", "reasoning-text", "reasoning-only", "provider-terminal"]) {
  let modelRequests = 0;
  const remembered = shape === "reasoning-only" ? "Done." : "remembered value";
  const server = createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      if (request.method === "GET") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ object: "list", data: [{ id: "checkpoint/model", type: "language" }] }));
        return;
      }
      modelRequests += 1;
      response.writeHead(200, { "content-type": "text/event-stream" });
      if (modelRequests === 1) {
        const frames = [];
        if (shape !== "plain") frames.push(
          { type: "reasoning-start", id: "reasoning" },
          { type: "reasoning-delta", id: "reasoning", delta: "Retain this context." },
          { type: "reasoning-end", id: "reasoning", providerMetadata: { vertex: { thoughtSignature: "checkpoint-reasoning" } } },
        );
        if (shape === "provider-terminal") frames.push(
          { type: "tool-call", toolCallId: "lookup", toolName: "exa_search", input: { query: "fixture" }, providerExecuted: true, providerMetadata: { vertex: { thoughtSignature: "checkpoint-call" } } },
          { type: "tool-result", toolCallId: "lookup", result: { content: "stored-provider-evidence" } },
        );
        if (shape !== "reasoning-only") frames.push({ type: "text-delta", id: "answer", delta: remembered });
        frames.push({ type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 2 }, outputTokens: { total: 2 } } });
        response.end(frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n");
        return;
      }
      assert.equal(modelRequests, 2, "unexpected extra model request");
      assert.ok(body.includes("store this context"), "restored request omitted the prior user turn");
      const parts = JSON.parse(body).prompt.flatMap((message) => Array.isArray(message.content) ? message.content : []);
      assert.equal(parts.filter((part) => part.type === "text" && part.text === remembered).length, 1, "restored answer must appear exactly once");
      if (shape !== "plain") {
        const reasoning = parts.filter((part) => part.type === "reasoning");
        assert.equal(reasoning.length, 1, "restored reasoning must appear exactly once");
        assert.equal(reasoning[0].providerOptions.vertex.thoughtSignature, "checkpoint-reasoning");
      }
      if (shape === "provider-terminal") {
        const calls = parts.filter((part) => part.type === "tool-call");
        const results = parts.filter((part) => part.type === "tool-result");
        assert.equal(calls.length, 1);
        assert.equal(results.length, 1);
        assert.equal(calls[0].toolCallId, results[0].toolCallId);
        assert.equal(calls[0].providerOptions.vertex.thoughtSignature, "checkpoint-call");
        assert.ok(body.includes("stored-provider-evidence"));
      }
      response.end([
        'data: {"type":"text-delta","delta":"restored"}',
        'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":4},"outputTokens":{"total":1}}}',
        "data: [DONE]",
        "",
      ].join("\n\n"));
    });
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  const { port } = server.address();

  const options = (backend, checkpoint) => ({
    backend,
    nativeAddon: addon,
    ...(backend === "wasm" ? { wasm } : {}),
    ...(checkpoint ? { checkpoint } : {}),
    fetch,
    apiKey: "checkpoint-key",
    gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
    model: "checkpoint/model",
  });

  let source;
  let target;
  try {
    source = await createFxAgent(options(sourceBackend));
    const first = source.prompt("store this context");
    for await (const _ of first) {}
    assert.equal((await first.result).stopReason, "end_turn");
    const checkpoint = await source.checkpoint();
    assert.ok(checkpoint instanceof Uint8Array && checkpoint.length > 48);
    assert.equal(await source.close(), undefined);
    source = null;

    target = await createFxAgent(options(targetBackend, checkpoint));
    const second = target.prompt("continue");
    let text = "";
    for await (const update of second) {
      if (update.type === "text_delta") text += update.delta;
    }
    assert.equal(text.trim(), "restored");
    assert.equal((await second.result).stopReason, "end_turn");
    assert.equal(await target.close(), undefined);
    target = null;
    assert.equal(modelRequests, 2);
    console.log(`checkpoint integration passed: ${sourceBackend} -> ${targetBackend} (${shape})`);
  } finally {
    await source?.close().catch(() => {});
    await target?.close().catch(() => {});
    server.closeAllConnections();
    await new Promise((resolveClose) => server.close(resolveClose));
  }
}
