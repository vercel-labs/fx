#!/usr/bin/env node
// libfx/browser does no work on import, so a server can render a client
// component that imports it. Its modules reach no Node.js code, and each .wasm
// is named in the module of the factory that loads it, so a bundler emits only
// the .wasm an app uses.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";

// Every fetch and WebAssembly compile counts as work.
const calls = [];
const record = (name, original) => function (...args) {
  calls.push(name);
  return original.apply(this, args);
};
globalThis.fetch = record("fetch", globalThis.fetch);
for (const name of ["compile", "compileStreaming", "instantiate", "instantiateStreaming"]) {
  WebAssembly[name] = record(`WebAssembly.${name}`, WebAssembly[name]);
}

const browser = await import("../browser.js");
// A client component creates its agent at module scope, which a server render
// runs too.
const agent = browser.createFxAgent();
assert.equal(typeof agent.session, "function");
assert.deepEqual(calls, [], `importing libfx/browser and creating an agent did work: ${calls.join(", ")}`);

// The modules browser.js reaches, by following their relative imports.
const nodeOnly = new Set(["node.js", "node.cjs", "node-wasm.js", "bundled-asset.js", "skills-node.js"]);
const importPattern = /(?:\bfrom\s*|\bimport\s*\(\s*|\bimport\s+)["']([^"']+)["']/g;
const sources = new Map();
const queue = ["browser.js"];
while (queue.length) {
  const name = queue.shift();
  if (sources.has(name)) continue;
  const source = await readFile(new URL(`../${name}`, import.meta.url), "utf8");
  sources.set(name, source);
  for (const [, specifier] of source.matchAll(importPattern)) {
    assert.ok(specifier.startsWith("./"), `${name} imports ${specifier}; libfx/browser must reach only its own modules`);
    const target = specifier.slice(2);
    assert.ok(!nodeOnly.has(target), `${name} imports ${target}, which is for Node.js`);
    queue.push(target);
  }
}

// browser.js only re-exports, so a bundler that skips unused re-exports never
// compiles the factory modules an app does not call.
const statements = sources.get("browser.js").split("\n").filter((line) => line.trim() && !line.startsWith("//"));
for (const line of statements) assert.match(line, /^export \{[^}]+\} from "\.\/[a-z-]+\.js";$/, `browser.js must only re-export: ${line}`);

const namers = (asset) => [...sources].filter(([, source]) => source.includes(`"./${asset}"`)).map(([name]) => name);
assert.deepEqual(namers("fx-core.wasm"), ["browser-agent.js"]);
assert.deepEqual(namers("fx-term.wasm"), ["browser-terminal.js"]);
console.log(`libfx/browser import passed: no work on import, ${sources.size} modules with no Node.js code, one module per .wasm`);
