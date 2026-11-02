#!/usr/bin/env node
import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const sdkDir = resolve(repoRoot, "sdk");
const outputDir = resolve(process.argv[2] || resolve(repoRoot, "sdk/dist/term-demo"));
const htmlPath = resolve(repoRoot, "sdk/term-demo.html");
const wasmPath = resolve(repoRoot, "zig-out/bin/fx-term.wasm");

const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
const integrity = (bytes) => `sha256-${createHash("sha256").update(bytes).digest("base64")}`;
const immutable = [{ key: "Cache-Control", value: "public, max-age=31536000, immutable" }];
// Static and dynamic imports of a sibling module: `from "./x.js"` and `import("./x.js")`.
const relativeImport = /(\bfrom\s*|\bimport\s*\(\s*)"\.\/([a-z0-9-]+\.js)"/g;

// Every module the page loads, named by the hash of its content after its own
// imports name their hashed files, so a module's name changes whenever
// anything it loads changes. The SDK's modules import no cycle.
const modules = new Map();
async function packageModule(name, chain = []) {
  if (chain.includes(name)) throw new Error(`import cycle: ${[...chain, name].join(" -> ")}`);
  const packaged = modules.get(name);
  if (packaged) return packaged.file;
  const source = await readFile(resolve(sdkDir, name), "utf8");
  const imports = [...new Set([...source.matchAll(relativeImport)].map((match) => match[2]))];
  const files = new Map();
  for (const dependency of imports) files.set(dependency, await packageModule(dependency, [...chain, name]));
  const bytes = Buffer.from(source.replace(relativeImport, (_, keyword, dependency) => `${keyword}"./${files.get(dependency)}"`));
  const sha256 = digest(bytes);
  const file = `${basename(name, ".js")}.${sha256}.js`;
  modules.set(name, { file, sha256, bytes });
  return file;
}

const [htmlSource, wasmBytes] = await Promise.all([readFile(htmlPath, "utf8"), readFile(wasmPath)]);
const browserName = await packageModule("browser.js");
const wasmHash = digest(wasmBytes);
const wasmName = `fx-term.${wasmHash}.wasm`;

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
    ...[...modules.values()].map(({ file }) => ({ source: `/${file}`, headers: immutable })),
    { source: `/${wasmName}`, headers: immutable },
    {
      source: "/manifest.json",
      headers: [{ key: "Cache-Control", value: "no-store" }],
    },
  ],
};
await Promise.all([
  writeFile(resolve(outputDir, "index.html"), html),
  ...[...modules.values()].map(({ file, bytes }) => writeFile(resolve(outputDir, file), bytes)),
  writeFile(resolve(outputDir, wasmName), wasmBytes),
  writeFile(resolve(outputDir, "vercel.json"), `${JSON.stringify(vercelConfig, null, 2)}\n`),
]);

const entry = (name) => {
  const { file, sha256, bytes } = modules.get(name);
  return { file, sha256, bytes: bytes.byteLength };
};
const manifest = {
  html: "index.html",
  browser: entry("browser.js"),
  terminal: entry("browser-terminal.js"),
  coreOutput: entry("core-output.js"),
  wasmModule: entry("wasm-module.js"),
  toolObservation: entry("tool-observation.js"),
  modules: Object.fromEntries([...modules.keys()].sort().map((name) => [name, entry(name)])),
  wasm: { file: wasmName, sha256: wasmHash, integrity: integrity(wasmBytes), bytes: wasmBytes.byteLength },
};
await writeFile(resolve(outputDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`packaged ${basename(outputDir)}`);
for (const { file } of modules.values()) console.log(`  ${file}`);
console.log(`  ${wasmName}`);
