#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const child = process.argv.includes("--child");
const backend = child
  ? (process.argv[process.argv.indexOf("--child") + 1] || "native")
  : (process.argv[2] || "native");

if (!new Set(["native", "wasm", "auto"]).has(backend)) {
  throw new Error("usage: test-agent-bootstrap.mjs [native|wasm|auto]");
}

if (!child) {
  const result = spawnSync(process.execPath, [...process.execArgv, scriptPath, "--child", backend], {
    cwd: resolve(scriptDir, "../.."),
    encoding: "utf8",
    timeout: 30_000,
  });
  assert.equal(result.error, undefined, `failed startup did not release the ${backend} runtime: ${result.error}`);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  process.stdout.write(result.stdout);
} else {
  const nativeAddon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
  const wasm = backend === "native"
    ? undefined
    : await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"));
  const options = {
    backend,
    nativeAddon,
    ...(wasm ? { wasm } : {}),
    apiKey: "bootstrap-test-key",
  };
  const attempts = backend === "native" ? 65 : 1;

  for (let index = 0; index < attempts; index++) {
    await assert.rejects(
      createFxAgent({ ...options, checkpoint: new Uint8Array([1, 2, 3]) }),
      (error) => {
        assert.match(error.message, /Invalid or non-fresh libfx checkpoint/);
        return true;
      },
    );
  }

  const agent = await createFxAgent(options);
  await agent.close();
  console.log(`${backend} failed bootstrap cleanup passed`);
}
