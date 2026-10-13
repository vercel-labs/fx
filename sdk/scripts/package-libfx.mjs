#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const outputDir = resolve(process.argv[2] || resolve(repoRoot, "sdk/dist/libfx"));
const requestedNativeAddons = process.argv.slice(3).map((path) => resolve(path));
const defaultNativeAddon = resolve(repoRoot, "zig-out/lib/libfx.node");
const nativeAddons = requestedNativeAddons.length ? requestedNativeAddons : [defaultNativeAddon];
const requiredNativeNames = new Set([
  "libfx.linux-x64.node",
  "libfx.linux-arm64.node",
  "libfx.darwin-x64.node",
  "libfx.darwin-arm64.node",
]);
const localNativeName = {
  "linux-x64": "libfx.linux-x64.node",
  "linux-arm64": "libfx.linux-arm64.node",
  "darwin-x64": "libfx.darwin-x64.node",
  "darwin-arm64": "libfx.darwin-arm64.node",
}[`${process.platform}-${process.arch}`];
const files = [
  ["sdk/package.json", "package.json"],
  ["sdk/README.md", "README.md"],
  ["LICENSE", "LICENSE"],
  ["sdk/browser.js", "browser.js"],
  ["sdk/node.js", "node.js"],
  ["sdk/fx-sdk.js", "fx-sdk.js"],
  ["sdk/durable.js", "durable.js"],
  ["sdk/fx-harness.js", "fx-harness.js"],
  ["sdk/wasm-module.js", "wasm-module.js"],
  ["sdk/core-output.js", "core-output.js"],
  ["sdk/subscription.js", "subscription.js"],
  ["sdk/oauth.js", "oauth.js"],
  ["sdk/chatgpt.js", "chatgpt.js"],
  ["sdk/chatgpt-sign-in.js", "chatgpt-sign-in.js"],
  ["sdk/grok.js", "grok.js"],
  ["sdk/grok-sign-in.js", "grok-sign-in.js"],
  ["sdk/custom-provider.js", "custom-provider.js"],
  ["sdk/fetch-cleanup.js", "fetch-cleanup.js"],
  ["sdk/mcp.js", "mcp.js"],
  ["sdk/skills.js", "skills.js"],
  ["sdk/skills-node.js", "skills-node.js"],
  ["zig-out/bin/fx-core.wasm", "fx-core.wasm"],
  ["zig-out/bin/fx-term.wasm", "fx-term.wasm"],
];

if (requestedNativeAddons.length) {
  const names = nativeAddons.map((addon) => basename(addon));
  const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
  const missing = [...requiredNativeNames].filter((name) => !names.includes(name));
  const unexpected = names.filter((name) => !requiredNativeNames.has(name));
  if (duplicates.length || missing.length || unexpected.length) {
    throw new Error([
      "publishable package requires exactly one addon for every supported platform",
      duplicates.length ? `duplicates: ${duplicates.join(", ")}` : null,
      missing.length ? `missing: ${missing.join(", ")}` : null,
      unexpected.length ? `unexpected: ${unexpected.join(", ")}` : null,
    ].filter(Boolean).join("; "));
  }
}
if (!requestedNativeAddons.length && !localNativeName) {
  throw new Error(`local native packaging is unsupported on ${process.platform}-${process.arch}`);
}

await rm(outputDir, { recursive: true, force: true });
await mkdir(outputDir, { recursive: true });
const cjsBuild = spawnSync(process.execPath, [
  resolve(repoRoot, "sdk/scripts/build-node-cjs.mjs"),
  resolve(outputDir, "node.cjs"),
], { cwd: repoRoot, stdio: "inherit" });
if (cjsBuild.error) throw cjsBuild.error;
if (cjsBuild.status !== 0) process.exit(cjsBuild.status ?? 1);
for (const [source, destination] of files) {
  await cp(resolve(repoRoot, source), resolve(outputDir, destination));
}
// The TypeScript declarations the manifest's `types` conditions name.
const declarations = (await readdir(resolve(repoRoot, "sdk/types"))).filter((name) => /\.d\.c?ts$/.test(name)).sort();
await mkdir(resolve(outputDir, "types"), { recursive: true });
for (const name of declarations) await cp(resolve(repoRoot, "sdk/types", name), resolve(outputDir, "types", name));
for (const addon of nativeAddons) {
  if (!addon.endsWith(".node")) throw new Error(`native addon must end in .node: ${addon}`);
  const destination = requestedNativeAddons.length ? basename(addon) : localNativeName;
  await cp(addon, resolve(outputDir, destination));
}

// Each durability module carries the World it wraps; see bundle-durable.mjs.
if (!existsSync(resolve(repoRoot, "sdk/durable/node_modules/@workflow"))) {
  throw new Error("bundling the durable Worlds needs `npm ci --prefix sdk/durable` first");
}
const bundle = spawnSync(process.env.BUN_BIN || "bun", [resolve(repoRoot, "sdk/scripts/bundle-durable.mjs"), outputDir], { cwd: repoRoot, stdio: "inherit" });
if (bundle.error) throw bundle.error;
if (bundle.status !== 0) process.exit(bundle.status ?? 1);

const manifest = JSON.parse(await readFile(resolve(outputDir, "package.json"), "utf8"));
manifest.files = undefined;
await writeFile(resolve(outputDir, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`packaged ${manifest.name} in ${outputDir}`);
console.log("  node.cjs");
for (const [, destination] of files) console.log(`  ${destination}`);
console.log("  durable/local.mjs");
console.log("  durable/vercel.mjs");
console.log("  durable/world.mjs");
for (const name of declarations) console.log(`  types/${name}`);
for (const addon of nativeAddons) {
  console.log(`  ${requestedNativeAddons.length ? basename(addon) : localNativeName}`);
}
