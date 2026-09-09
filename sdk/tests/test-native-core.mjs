#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultAddon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const addon = process.argv[2] || `./${relative(process.cwd(), defaultAddon)}`;
const events = [];
const agent = await createFxAgent({
  nativeAddon: addon,
  backend: "native",
  apiKey: "native-core-test-key",
  onEvent(event) { events.push(event); },
});
assert.deepEqual(Object.keys(agent).sort(), ["abandon", "checkpoint", "close", "prompt", "resume", "status", "suspend"]);
await assert.rejects(agent.checkpoint(), /journal.*onEntry/);
assert.equal(await agent.close(), undefined);
assert.ok(events.some((event) => event.type === "runtime.ready"));
assert.ok(events.some((event) => event.type === "acp.receive"));
console.log("native core passed: minimal initialization, explicit persistence requirement, and graceful close");
