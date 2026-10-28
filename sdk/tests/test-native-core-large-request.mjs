#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/lib/libfx.node"));
const mib = 1024 * 1024;
const prompts = ["a", "b", "c"].map((fill) => fill.repeat(3.5 * mib));
const timer = setTimeout(() => assert.fail("native large request timed out"), 25_000);
const reply = (text) => new Response(
  [
    `data: ${JSON.stringify({ type: "text-delta", delta: text })}\n\n`,
    `data: ${JSON.stringify({ type: "finish", finishReason: { unified: "stop", raw: "stop" } })}\n\n`,
    "data: [DONE]\n\n",
  ].join(""),
  { headers: { "content-type": "text/event-stream" } },
);

// Sends the three prompts on one native agent, so the third turn's request
// would carry about 10.5 MiB. With `providerLimit`, the mock provider refuses
// larger requests with a 413, as a real one does.
async function converse(providerLimit) {
  const home = await mkdtemp(join(tmpdir(), "fx-native-large-request-"));
  const sent = [];
  let refused = 0;
  let agent;
  try {
    agent = await createFxEngine({
      backend: "native",
      nativeAddon: addon,
      home,
      workspaceRoot: home,
      apiKey: "native-large-request-key",
      model: "native/large-model",
      fetch(_url, init) {
        if (init.method === "GET") {
          return Response.json({ object: "list", data: [{ id: "native/large-model", type: "language", tags: ["tool-use"] }] });
        }
        if (providerLimit !== undefined && init.body.length > providerLimit) {
          refused += 1;
          return Response.json({ error: { message: "request entity too large" } }, { status: 413 });
        }
        sent.push(Buffer.from(init.body).toString("utf8"));
        return reply("noted");
      },
    });
    for (const prompt of prompts) {
      assert.equal((await agent.prompt(prompt).result).stopReason, "end_turn");
    }
    return { sent, refused };
  } finally {
    await agent?.close();
    await rm(home, { recursive: true, force: true });
  }
}

try {
  // Without a provider limit, a request past 8 MiB reaches host fetch whole,
  // as it does on the WebAssembly backend.
  const open = await converse();
  assert.equal(open.sent.length, 3);
  const last = open.sent[2];
  assert.ok(Buffer.byteLength(last) > 10 * mib);
  for (const prompt of prompts) assert.ok(last.includes(prompt));

  // A provider that refuses the request as too large makes the agent compact
  // the conversation and retry, and the session goes on.
  const limit = 9 * mib;
  const limited = await converse(limit);
  assert.equal(limited.refused, 1);
  const retried = limited.sent.at(-1);
  assert.ok(retried.includes("compacted_conversation"));
  assert.ok(retried.includes(prompts[2]));
  assert.ok(!retried.includes(prompts[0]));
  console.log("native large request passed: requests past 8 MiB reach host fetch; a provider's size refusal compacts and continues");
} finally {
  clearTimeout(timer);
}
