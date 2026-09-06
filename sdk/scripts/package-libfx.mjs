#!/usr/bin/env node
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
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
const files = [
  ["sdk/package.json", "package.json"],
  ["sdk/README.md", "README.md"],
  ["LICENSE", "LICENSE"],
  ["sdk/browser.js", "browser.js"],
  ["sdk/node.js", "node.js"],
  ["sdk/fx-sdk.js", "fx-sdk.js"],
  ["sdk/core-output.js", "core-output.js"],
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

await rm(outputDir, { recursive: true, force: true });
await mkdir(outputDir, { recursive: true });
for (const [source, destination] of files) {
  await cp(resolve(repoRoot, source), resolve(outputDir, destination));
}
for (const addon of nativeAddons) {
  if (!addon.endsWith(".node")) throw new Error(`native addon must end in .node: ${addon}`);
  await cp(addon, resolve(outputDir, basename(addon)));
}

const manifest = JSON.parse(await readFile(resolve(outputDir, "package.json"), "utf8"));
manifest.files = undefined;
await writeFile(resolve(outputDir, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`packaged ${manifest.name} in ${outputDir}`);
for (const [, destination] of files) console.log(`  ${destination}`);
for (const addon of nativeAddons) console.log(`  ${basename(addon)}`);
