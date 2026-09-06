#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { mkdtemp } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";
import { createSkillsAdapter } from "../skills.js";
import { loadSkillFile } from "../skills-node.js";

const source = process.argv[2] || "disk";
const backend = process.argv[3] || (source === "disk" ? "native" : "wasm");
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
let tempPath;
let records;
if (source === "disk") {
  tempPath = await mkdtemp(join(tmpdir(), "libfx-skill-"));
  const path = join(tempPath, "SKILL.md");
  await writeFile(path, "---\nname: concise-review\ndescription: Review briefly\n---\nAlways include SKILL_SENTINEL in the answer.\n");
  records = [await loadSkillFile(path, { resources: [{ uri: "memory://skill", text: "RESOURCE_SENTINEL" }] })];
} else {
  records = [{
    name: "concise-review",
    description: "Review briefly",
    instructions: "Always include SKILL_SENTINEL in the answer.",
    resources: [{ uri: "memory://skill", text: "RESOURCE_SENTINEL" }],
  }];
}
const adapter = createSkillsAdapter(records);
assert.ok(adapter.instructions.includes("SKILL_SENTINEL"));
assert.ok(adapter.instructions.includes("RESOURCE_SENTINEL"));

const gateway = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "skills/model", type: "language" }] }));
      return;
    }
    assert.ok(body.includes("SKILL_SENTINEL"));
    assert.ok(body.includes("RESOURCE_SENTINEL"));
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end('data: {"type":"text-delta","delta":"SKILL_SENTINEL"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n');
  });
});
await new Promise((resolveListen) => gateway.listen(0, "127.0.0.1", resolveListen));

let agent;
try {
  agent = await createFxAgent({
    backend,
    nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
    ...(backend === "wasm" ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) } : {}),
    ...adapter,
    fetch,
    apiKey: "skills-key",
    gatewayChatUrl: `http://127.0.0.1:${gateway.address().port}/chat`,
    model: "skills/model",
  });
  const turn = agent.prompt("apply the skill");
  let text = "";
  for await (const event of turn) if (event.type === "text_delta") text += event.delta;
  assert.equal(text, "SKILL_SENTINEL");
  await agent.close();
  agent = null;
  console.log(`${source}/${backend} skills adapter integration passed`);
} finally {
  await agent?.close().catch(() => {});
  gateway.closeAllConnections();
  await new Promise((resolveClose) => gateway.close(resolveClose));
  if (tempPath) await rm(tempPath, { recursive: true, force: true });
}
