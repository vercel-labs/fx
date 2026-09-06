#!/usr/bin/env node
import { strict as assert } from "node:assert";

let fetchCalls = 0;
const originalFetch = globalThis.fetch;
globalThis.fetch = (...args) => {
  fetchCalls += 1;
  return originalFetch(...args);
};

try {
  const entry = await import(`../node.js?default-import=${Date.now()}`);
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(typeof entry.createFxAgent, "function");
  assert.equal(typeof entry.listModels, "function");
  assert.equal("createMcpAdapter" in entry, false);
  assert.equal("createSkillsAdapter" in entry, false);
  assert.equal(fetchCalls, 0);
  console.log("default libfx import passed: no network or optional adapter activation");
} finally {
  globalThis.fetch = originalFetch;
}
