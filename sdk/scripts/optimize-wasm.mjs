#!/usr/bin/env node
// Shrinks the WebAssembly modules libfx packages with binaryen's wasm-opt -Oz,
// in place. CI and the publisher run it after `zig build`; run
// `npm ci --prefix sdk/tools` first.
//
//   node sdk/scripts/optimize-wasm.mjs zig-out/bin/fx-core.wasm zig-out/bin/fx-term.wasm
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, renameSync, rmSync, statSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(fileURLToPath(new URL(".", import.meta.url)), "../..");
const binaryen = resolve(repoRoot, "sdk/tools/node_modules/binaryen");
if (!existsSync(resolve(binaryen, "package.json"))) throw new Error("optimizing WebAssembly needs `npm ci --prefix sdk/tools` first");
const wasmOpt = resolve(binaryen, JSON.parse(readFileSync(resolve(binaryen, "package.json"), "utf8")).bin["wasm-opt"]);

// The features Zig enables for wasm32-wasi. A stripped module no longer
// records them, so they are listed here, and wasm-opt may use no others. When
// Zig adds one, wasm-opt rejects the module until it is listed; an unstripped
// build names them in its target_features section.
const features = [
  "bulk-memory-opt",
  "call-indirect-overlong",
  "extended-const",
  "multivalue",
  "mutable-globals",
  "nontrapping-float-to-int",
  "sign-ext",
];

const files = process.argv.slice(2).map((path) => resolve(path));
if (!files.length) throw new Error("usage: node sdk/scripts/optimize-wasm.mjs <module.wasm>...");
for (const file of files) {
  const before = statSync(file).size;
  const output = resolve(dirname(file), `.${basename(file)}.optimized`);
  const result = spawnSync(process.execPath, [
    wasmOpt, file, "-Oz", "--strip-debug", "--strip-producers",
    ...features.map((feature) => `--enable-${feature}`),
    "-o", output,
  ], { stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    rmSync(output, { force: true });
    process.exit(result.status ?? 1);
  }
  const after = statSync(output).size;
  if (after >= before) {
    rmSync(output, { force: true });
    throw new Error(`wasm-opt did not shrink ${basename(file)}: ${before} -> ${after} bytes; was it already optimized?`);
  }
  renameSync(output, file);
  console.log(`${basename(file)}: ${before} -> ${after} bytes`);
}
