#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const commands = [
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-core.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-core-cancel.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-core-home-unavailable.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-term.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-term-session-resume.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-term-login.mjs", import.meta.url))]],
  ["npm", ["run", "--prefix", "sdk/node", "test:term"]],
];

for (const [command, args] of commands) {
  const result = spawnSync(command, args, { cwd: repoRoot, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
console.log("Node + WASM SDK lane passed");
