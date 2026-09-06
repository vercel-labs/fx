#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const output = resolve(process.argv[2] || resolve(repoRoot, "sdk/dist/libfx/node.cjs"));
mkdirSync(dirname(output), { recursive: true });
const result = spawnSync(process.env.BUN_BIN || "bun", [
  "build",
  resolve(repoRoot, "sdk/node.js"),
  "--target=node",
  "--format=cjs",
  "--external=*.node",
  "--define",
  "import.meta.url=__libfxModuleUrl",
  "--banner",
  'var __libfxModuleUrl = require("node:url").pathToFileURL(__filename).href;',
  "--outfile",
  output,
], {
  cwd: repoRoot,
  stdio: "inherit",
});

if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
console.log(`built CommonJS Node entry in ${output}`);
