#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";
import { createFxAgent as createSharedAgent } from "../fx-sdk.js";
import { createMcpAdapter } from "../mcp.js";
import { createSkillsAdapter } from "../skills.js";

const maxInstructionsBytes = 65_536;
const encoder = new TextEncoder();
const backend = process.argv[2] || "native";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));

if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-instruction-limits.mjs [native|wasm]");
}

const exactInstructions = "x".repeat(maxInstructionsBytes);
const options = {
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm"
    ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }
    : {}),
  apiKey: "instruction-limit-test-key",
};

const agent = await createFxAgent({ ...options, instructions: exactInstructions });
await agent.close();

let runtimeCreations = 0;
await assert.rejects(
  createSharedAgent({
    apiKey: "instruction-limit-test-key",
    instructions: `${exactInstructions}x`,
    runtimeFactory() {
      runtimeCreations += 1;
      throw new Error("runtime factory must not run for oversized instructions");
    },
  }),
  (error) => error instanceof RangeError && error.message.includes("65536"),
);
assert.equal(runtimeCreations, 0);

const skillPrefix = '<skill name="limit">\n';
const skillSuffix = "\n</skill>";
const skillBody = "s".repeat(maxInstructionsBytes - encoder.encode(skillPrefix + skillSuffix).length);
const skillAdapter = createSkillsAdapter([{ name: "limit", instructions: skillBody }]);
assert.equal(encoder.encode(skillAdapter.instructions).length, maxInstructionsBytes);
assert.throws(
  () => createSkillsAdapter([{ name: "limit", instructions: `${skillBody}s` }]),
  (error) => error instanceof RangeError && error.message.includes("65536"),
);

const mcpPrefix = "<mcp_resource>\n";
const mcpSuffix = "\n</mcp_resource>";
const mcpBody = "m".repeat(maxInstructionsBytes - encoder.encode(mcpPrefix + mcpSuffix).length);
const mcpClient = {
  async listTools() { return []; },
  async callTool() { throw new Error("unused"); },
  async readResource() { return { contents: [{ type: "text", text: mcpBody }] }; },
};
const mcpAdapter = await createMcpAdapter(mcpClient, { resources: ["memory://limit"] });
assert.equal(encoder.encode(mcpAdapter.instructions).length, maxInstructionsBytes);
mcpClient.readResource = async () => ({ contents: [{ type: "text", text: `${mcpBody}m` }] });
await assert.rejects(
  createMcpAdapter(mcpClient, { resources: ["memory://limit"] }),
  (error) => error instanceof RangeError && error.message.includes("65536"),
);

console.log(`${backend} instruction limits passed`);
