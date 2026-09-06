#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const temp = await mkdtemp(join(tmpdir(), "fx-term-demo-package-"));
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");

try {
  const result = spawnSync(process.execPath, [
    resolve(repoRoot, "sdk/scripts/package-term-demo.mjs"),
    temp,
  ], { cwd: repoRoot, encoding: "utf8" });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stderr);

  const manifest = JSON.parse(await readFile(join(temp, "manifest.json"), "utf8"));
  const wasmModule = await readFile(join(temp, manifest.wasmModule.file));
  assert.equal(digest(wasmModule), manifest.wasmModule.sha256);
  assert.equal(wasmModule.byteLength, manifest.wasmModule.bytes);

  const sdk = await readFile(join(temp, manifest.sdk.file), "utf8");
  assert.match(sdk, new RegExp(`from "\\./${manifest.wasmModule.file.replaceAll(".", "\\.")}";`));
  assert.doesNotMatch(sdk, /from "\.\/wasm-module\.js";/);

  const vercel = JSON.parse(await readFile(join(temp, "vercel.json"), "utf8"));
  const header = vercel.headers.find(({ source }) => source === `/${manifest.wasmModule.file}`);
  assert.deepEqual(header?.headers, [{ key: "Cache-Control", value: "public, max-age=31536000, immutable" }]);
  console.log("terminal demo package passed: shared Wasm module is hashed, rewritten, and immutable");
} finally {
  await rm(temp, { recursive: true, force: true });
}
