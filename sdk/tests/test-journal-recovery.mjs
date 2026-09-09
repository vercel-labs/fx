#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const backend = process.argv[2] ?? "native";
const target = process.argv[3] ?? backend;
for (const value of [backend, target]) assert.ok(["native", "wasm"].includes(value), `Invalid backend: ${value}`);
const cases = [
  ["test-journal-large-input.mjs", backend, target],
  ["test-journal-compaction.mjs", backend, target],
  ["test-suspension.mjs", backend, target],
  ["test-suspension-boundaries.mjs", backend],
  ["test-suspension-failure.mjs", backend],
  ["test-suspension-cancel.mjs", backend],
];
for (const mode of ["throw", "throw_without_suspend", "throw_rich", "throw_getter", "invalid_result", "invalid_image", "oversized_result", "no_sink", "returned_failure", "returned_plain_failure"]) {
  cases.push(["test-suspension-tool-uncertainty.mjs", backend, target, mode]);
}
for (const sink of ["sink", "no_sink"]) {
  cases.push(["test-host-tool-cancel-owner.mjs", backend, sink, "before"]);
  for (const settlement of ["resolve", "reject"]) cases.push(["test-host-tool-cancel-owner.mjs", backend, sink, "after", settlement]);
}
for (const [script, ...args] of cases) {
  const result = spawnSync(process.execPath, [
    ...(process.versions.bun ? [] : ["--experimental-wasm-jspi"]),
    fileURLToPath(new URL(script, import.meta.url)), ...args,
  ], { cwd: fileURLToPath(new URL("../..", import.meta.url)), stdio: "inherit", timeout: 30_000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${script} ${args.join(" ")} failed (${result.signal ?? result.status})`);
}
console.log(`Journal recovery passed: ${backend} -> ${target}, ${cases.length} isolated scenarios`);
