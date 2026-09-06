#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const termScripts = [
  "test-xterm-adapter.mjs",
  "test-term-config-restore.mjs",
  "test-term-headless.mjs",
  "test-term-table-stream.mjs",
  "test-term-lifecycle.mjs",
  "test-term-features.mjs",
  "test-term-history.mjs",
  "test-term-workspace.mjs",
];
const commands = [
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-wasm-jspi-tier-up.mjs", import.meta.url))]],
  [process.execPath, [fileURLToPath(new URL("test-core-output.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-core-output-pressure.mjs", import.meta.url)), "wasm"]],
  [process.execPath, [fileURLToPath(new URL("test-wasm-memory.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-agent-bootstrap.mjs", import.meta.url)), "wasm"]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-instruction-limits.mjs", import.meta.url)), "wasm"]],
  [process.execPath, ["--experimental-wasm-jspi", "--expose-gc", fileURLToPath(new URL("test-wasm-module-cache.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-agent-request-context.mjs", import.meta.url)), "wasm"]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-agent-transport-retry.mjs", import.meta.url)), "wasm"]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-core.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-core-cancel.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-core-home-unavailable.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-term.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-term-session-resume.mjs", import.meta.url))]],
  [process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL("test-term-login.mjs", import.meta.url))]],
];
if (process.versions.bun) {
  for (const script of termScripts) {
    commands.push([process.execPath, ["--experimental-wasm-jspi", fileURLToPath(new URL(`../node/${script}`, import.meta.url))]]);
  }
} else {
  commands.push(["npm", ["run", "--prefix", "sdk/node", "test:term"]]);
}

for (const [command, args] of commands) {
  const result = spawnSync(command, args, { cwd: repoRoot, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
console.log(`${process.versions.bun ? "Bun" : "Node"} + WASM SDK lane passed`);
