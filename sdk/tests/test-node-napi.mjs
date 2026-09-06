#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const scripts = [
  "test-core-output.mjs",
  "test-core-output-pressure.mjs",
  "test-native-core-ready.mjs",
  "test-native-core-misuse.mjs",
  "test-native-core-workers.mjs",
  "test-native-core-worker-termination.mjs",
  "test-native-core-security.mjs",
  "test-native-core-exit-code.mjs",
  "test-native-core.mjs",
  "test-native-core-config-isolation.mjs",
  "test-agent-request-context.mjs",
  "test-agent-transport-retry.mjs",
  "test-native-core-stream.mjs",
  "test-native-core-fetch-failure.mjs",
  "test-native-core-image-framing.mjs",
  "test-native-host-tool-frame-limit.mjs",
  "test-native-core-cancel-before-fetch.mjs",
  "test-native-core-cancel.mjs",
  "test-native-host-tool-late-settle.mjs",
  "test-default-import.mjs",
  "test-list-models.mjs",
  "test-libfx-loader.mjs",
  "test-agent-bootstrap.mjs",
  "test-instruction-limits.mjs",
];
for (const script of scripts) {
  const args = [fileURLToPath(new URL(script, import.meta.url))];
  if (script === "test-native-core-workers.mjs") args.unshift("--expose-gc");
  const result = spawnSync(process.execPath, args, {
    cwd: repoRoot,
    stdio: "inherit",
    timeout: 30_000,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
console.log("Node + N-API SDK lane passed");
