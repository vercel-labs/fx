#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scripts = ["test-term.mjs", "test-core.mjs", "test-core-cancel.mjs", "test-core-home-unavailable.mjs"];
for (const script of scripts) {
  const path = fileURLToPath(new URL(script, import.meta.url));
  const result = spawnSync(process.execPath, ["--experimental-wasm-jspi", path], {
    cwd: process.cwd(),
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
console.log("Node SDK smoke suite passed");
