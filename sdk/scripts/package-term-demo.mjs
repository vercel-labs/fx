#!/usr/bin/env node
import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const outputDir = resolve(process.argv[2] || resolve(repoRoot, "sdk/dist/term-demo"));
const htmlPath = resolve(repoRoot, "sdk/term-demo.html");
const browserPath = resolve(repoRoot, "sdk/browser.js");
const sdkPath = resolve(repoRoot, "sdk/fx-sdk.js");
const coreOutputPath = resolve(repoRoot, "sdk/core-output.js");
const wasmPath = resolve(repoRoot, "zig-out/bin/fx-term.wasm");

const [htmlSource, browserBytes, sdkSource, coreOutputBytes, wasmBytes] = await Promise.all([
  readFile(htmlPath, "utf8"),
  readFile(browserPath),
  readFile(sdkPath),
  readFile(coreOutputPath),
  readFile(wasmPath),
]);

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const integrity = (bytes) => `sha256-${createHash("sha256").update(bytes).digest("base64")}`;
const coreOutputHash = digest(coreOutputBytes);
const coreOutputName = `core-output.${coreOutputHash}.js`;
const sdkBytes = Buffer.from(sdkSource.toString().replace('from "./core-output.js";', `from "./${coreOutputName}";`));
const sdkHash = digest(sdkBytes);
const wasmHash = digest(wasmBytes);
const sdkName = `fx-sdk.${sdkHash}.js`;
const wasmName = `fx-term.${wasmHash}.wasm`;
const packagedBrowser = Buffer.from(
  browserBytes.toString().replace('from "./fx-sdk.js";', `from "./${sdkName}";`),
);
const browserHash = digest(packagedBrowser);
const browserName = `browser.${browserHash}.js`;

const replacements = [
  ['const fxWasmAsset = "./fx-term.wasm";', `const fxWasmAsset = "./${wasmName}";`],
  ['const fxWasmIntegrity = "";', `const fxWasmIntegrity = "${integrity(wasmBytes)}";`],
  ['from "./browser.js";', `from "./${browserName}";`],
];
let html = htmlSource;
for (const [source, replacement] of replacements) {
  const first = html.indexOf(source);
  if (first < 0 || html.indexOf(source, first + source.length) >= 0) {
    throw new Error(`expected exactly one packaging placeholder: ${source}`);
  }
  html = html.replace(source, replacement);
}

await rm(outputDir, { recursive: true, force: true });
await mkdir(outputDir, { recursive: true });
const vercelConfig = {
  headers: [
    {
      source: "/",
      headers: [{ key: "Cache-Control", value: "public, max-age=0, must-revalidate" }],
    },
    {
      source: "/index.html",
      headers: [{ key: "Cache-Control", value: "public, max-age=0, must-revalidate" }],
    },
    {
      source: `/${browserName}`,
      headers: [{ key: "Cache-Control", value: "public, max-age=31536000, immutable" }],
    },
    {
      source: `/${sdkName}`,
      headers: [{ key: "Cache-Control", value: "public, max-age=31536000, immutable" }],
    },
    {
      source: `/${coreOutputName}`,
      headers: [{ key: "Cache-Control", value: "public, max-age=31536000, immutable" }],
    },
    {
      source: `/${wasmName}`,
      headers: [{ key: "Cache-Control", value: "public, max-age=31536000, immutable" }],
    },
    {
      source: "/manifest.json",
      headers: [{ key: "Cache-Control", value: "no-store" }],
    },
  ],
};
await Promise.all([
  writeFile(resolve(outputDir, "index.html"), html),
  writeFile(resolve(outputDir, browserName), packagedBrowser),
  writeFile(resolve(outputDir, sdkName), sdkBytes),
  writeFile(resolve(outputDir, coreOutputName), coreOutputBytes),
  writeFile(resolve(outputDir, wasmName), wasmBytes),
  writeFile(resolve(outputDir, "vercel.json"), `${JSON.stringify(vercelConfig, null, 2)}\n`),
]);

const manifest = {
  html: "index.html",
  browser: { file: browserName, sha256: digest(packagedBrowser), bytes: packagedBrowser.byteLength },
  sdk: { file: sdkName, sha256: sdkHash, bytes: sdkBytes.byteLength },
  coreOutput: { file: coreOutputName, sha256: coreOutputHash, bytes: coreOutputBytes.byteLength },
  wasm: { file: wasmName, sha256: wasmHash, integrity: integrity(wasmBytes), bytes: wasmBytes.byteLength },
};
await writeFile(resolve(outputDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`packaged ${basename(outputDir)}`);
console.log(`  ${browserName}`);
console.log(`  ${sdkName}`);
console.log(`  ${coreOutputName}`);
console.log(`  ${wasmName}`);
