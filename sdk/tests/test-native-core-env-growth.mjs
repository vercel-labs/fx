#!/usr/bin/env node
// The native addon reads the environment from libc at each use. Node.js owns
// the environment, and an app that adds variables after the first native
// runtime started makes libc move its array and free the old one; an addon
// that kept the old array would read freed memory on its next lookup, which
// crashes the process on macOS.
//
//   node sdk/tests/test-native-core-env-growth.mjs [libfx.node]
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(process.argv[2] && process.argv[2] !== "child" ? process.argv[2] : resolve(scriptDir, "../../zig-out/lib/libfx.node"));

if (process.argv.includes("child")) {
  const names = Number(process.argv.at(-1));
  const { createFxEngine } = await import("../node.js");
  // A variable written before the addon loads, as an app's dotenv does,
  // leaves libc's array on the heap, where the next growth can free it.
  process.env.LIBFX_ENV_GROWTH_BEFORE = "1";
  const home = await mkdtemp(join(tmpdir(), "libfx-env-home-"));
  const workspaceRoot = await mkdtemp(join(tmpdir(), "libfx-env-workspace-"));
  const stream = [
    'data: {"type":"text-delta","delta":"ok"}\n\n',
    'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}},"providerMetadata":{"gateway":{"generationId":"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"}}}\n\n',
    "data: [DONE]\n\n",
  ].join("");
  const engine = await createFxEngine({
    nativeAddon: addon,
    backend: "native",
    fetch: async (_input, init) => (init.method === "GET"
      ? Response.json({ object: "list", data: [{ id: "native/test-model", type: "language" }] })
      : new Response(stream, { headers: { "content-type": "text/event-stream" } })),
    home,
    workspaceRoot,
    apiKey: "env-growth-key",
    gatewayChatUrl: "http://127.0.0.1:9/chat",
    model: "native/test-model",
  });
  for (let index = 0; index < names; index += 1) process.env[`LIBFX_ENV_GROWTH_${index}`] = "x".repeat(32);
  for (let round = 0; round < 3; round += 1) {
    const turn = engine.prompt(`round ${round}`);
    for await (const _ of turn) {}
    assert.equal((await turn.result).stopReason, "end_turn");
  }
  await engine.close();
  await rm(home, { recursive: true, force: true });
  await rm(workspaceRoot, { recursive: true, force: true });
  process.exit(0);
}

// Each run is a process of its own: a crash shows as its exit, not ours.
for (const names of [0, 10, 200]) {
  for (let run = 0; run < 3; run += 1) {
    const child = spawnSync(process.execPath, [fileURLToPath(import.meta.url), addon, "child", String(names)], {
      encoding: "utf8",
      env: { PATH: process.env.PATH, HOME: process.env.HOME ?? tmpdir() },
      timeout: 30_000,
    });
    assert.equal(child.signal, null, `${names} new variables, run ${run}: the process died of ${child.signal}\n${child.stderr}`);
    assert.equal(child.status, 0, `${names} new variables, run ${run}: exit ${child.status}\n${child.stderr}`);
  }
}
console.log("native environment growth passed: 0, 10 and 200 new variables after the first runtime, 3 runs each");
