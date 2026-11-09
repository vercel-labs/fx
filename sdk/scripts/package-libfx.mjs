#!/usr/bin/env node
// Assembles the npm packages in <out-dir>: libfx in <out-dir>/libfx, and one
// package per native addon in <out-dir>/libfx-<platform>.
//
//   node sdk/scripts/package-libfx.mjs <out-dir> [libfx.<platform>.node ...]
//
// With no addons, it packages zig-out/lib/libfx.node for this machine. A
// publishable set names one addon for every supported platform. LIBFX_VERSION
// sets the version of every package and of libfx's optional dependencies.
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const outputRoot = resolve(process.argv[2] || resolve(repoRoot, "sdk/dist"));
const outputDir = resolve(outputRoot, "libfx");
const requestedNativeAddons = process.argv.slice(3).map((path) => resolve(path));
const defaultNativeAddon = resolve(repoRoot, "zig-out/lib/libfx.node");

// One package per addon. node.js names the same packages in nativePackages.
const nativeTargets = {
  "linux-x64": { name: "@libfx/libfx-linux-x64-gnu", os: "linux", cpu: "x64", libc: "glibc", label: "Linux x64 with glibc" },
  "linux-arm64": { name: "@libfx/libfx-linux-arm64-gnu", os: "linux", cpu: "arm64", libc: "glibc", label: "Linux arm64 with glibc" },
  "darwin-x64": { name: "@libfx/libfx-darwin-x64", os: "darwin", cpu: "x64", label: "macOS x64" },
  "darwin-arm64": { name: "@libfx/libfx-darwin-arm64", os: "darwin", cpu: "arm64", label: "macOS arm64" },
};
const localPlatform = `${process.platform}-${process.arch}`;
const nativeAddons = requestedNativeAddons.length
  ? requestedNativeAddons.map((path) => ({ path, platform: basename(path).replace(/^libfx\.(.*)\.node$/, "$1") }))
  : [{ path: defaultNativeAddon, platform: localPlatform }];
const files = [
  ["sdk/package.json", "package.json"],
  ["sdk/README.md", "README.md"],
  ["LICENSE", "LICENSE"],
  ["sdk/browser.js", "browser.js"],
  ["sdk/browser-agent.js", "browser-agent.js"],
  ["sdk/browser-terminal.js", "browser-terminal.js"],
  ["sdk/node.js", "node.js"],
  ["sdk/node.cjs", "node.cjs"],
  ["sdk/node-wasm.js", "node-wasm.js"],
  ["sdk/bundled-asset.js", "bundled-asset.js"],
  ["sdk/fx-sdk.js", "fx-sdk.js"],
  ["sdk/engine.js", "engine.js"],
  ["sdk/xterm.js", "xterm.js"],
  ["sdk/wasm-runtime.js", "wasm-runtime.js"],
  ["sdk/wasm-terminal.js", "wasm-terminal.js"],
  ["sdk/durable.js", "durable.js"],
  ["sdk/fx-harness.js", "fx-harness.js"],
  ["sdk/wasm-module.js", "wasm-module.js"],
  ["sdk/core-output.js", "core-output.js"],
  ["sdk/tool-observation.js", "tool-observation.js"],
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

for (const { path } of nativeAddons) {
  if (!path.endsWith(".node")) throw new Error(`native addon must end in .node: ${path}`);
}
if (requestedNativeAddons.length) {
  const names = nativeAddons.map(({ platform }) => platform);
  const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
  const missing = Object.keys(nativeTargets).filter((name) => !names.includes(name));
  const unexpected = requestedNativeAddons.filter((path, index) => !nativeTargets[names[index]]).map((path) => basename(path));
  if (duplicates.length || missing.length || unexpected.length) {
    throw new Error([
      "publishable packages require exactly one addon for every supported platform, named libfx.<platform>.node",
      duplicates.length ? `duplicates: ${duplicates.join(", ")}` : null,
      missing.length ? `missing: ${missing.join(", ")}` : null,
      unexpected.length ? `unexpected: ${unexpected.join(", ")}` : null,
    ].filter(Boolean).join("; "));
  }
} else if (!nativeTargets[localPlatform]) {
  throw new Error(`local native packaging is unsupported on ${localPlatform}`);
}

const sourceManifest = JSON.parse(await readFile(resolve(repoRoot, "sdk/package.json"), "utf8"));
const version = process.env.LIBFX_VERSION || sourceManifest.version;

await rm(outputDir, { recursive: true, force: true });
for (const { name } of Object.values(nativeTargets)) {
  await rm(resolve(outputRoot, basename(name)), { recursive: true, force: true });
}
await mkdir(outputDir, { recursive: true });
for (const [source, destination] of files) {
  await cp(resolve(repoRoot, source), resolve(outputDir, destination));
}
// The TypeScript declarations the manifest's `types` conditions name.
const declarations = (await readdir(resolve(repoRoot, "sdk/types"))).filter((name) => /\.d\.c?ts$/.test(name)).sort();
await mkdir(resolve(outputDir, "types"), { recursive: true });
for (const name of declarations) await cp(resolve(repoRoot, "sdk/types", name), resolve(outputDir, "types", name));

// Each durability module carries the World it wraps; see bundle-durable.mjs.
if (!existsSync(resolve(repoRoot, "sdk/durable/node_modules/@workflow"))) {
  throw new Error("bundling the durable Worlds needs `npm ci --prefix sdk/durable` first");
}
const bundle = spawnSync(process.env.BUN_BIN || "bun", [resolve(repoRoot, "sdk/scripts/bundle-durable.mjs"), outputDir], { cwd: repoRoot, stdio: "inherit" });
if (bundle.error) throw bundle.error;
if (bundle.status !== 0) process.exit(bundle.status ?? 1);

const manifest = JSON.parse(await readFile(resolve(outputDir, "package.json"), "utf8"));
manifest.version = version;
manifest.files = undefined;
// Every platform's package at exactly this version; npm installs the one
// whose os, cpu, and libc match the machine.
manifest.optionalDependencies = Object.fromEntries(Object.values(nativeTargets).map(({ name }) => [name, version]));
await writeFile(resolve(outputDir, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);

const nativeDirs = [];
for (const { path, platform } of nativeAddons) {
  const { name, os, cpu, libc, label } = nativeTargets[platform];
  const dir = resolve(outputRoot, basename(name));
  await mkdir(dir, { recursive: true });
  await cp(path, resolve(dir, "libfx.node"));
  await cp(resolve(repoRoot, "LICENSE"), resolve(dir, "LICENSE"));
  await writeFile(resolve(dir, "index.js"), [
    "// libfx loads this addon itself. Install libfx, not this package.",
    "// The literal URL lets a bundler copy the addon and trace it.",
    'export default new URL("./libfx.node", import.meta.url);',
    "",
  ].join("\n"));
  await writeFile(resolve(dir, "README.md"), `# ${name}\n\nThe libfx native addon for ${label}. libfx installs it for you, so install [libfx](https://www.npmjs.com/package/libfx) instead of this package.\n\nFor requirements and what to do when it's missing, see [libfx on Node.js](https://fx.sh/docs/lib/node).\n`);
  await writeFile(resolve(dir, "package.json"), `${JSON.stringify({
    name,
    version,
    description: `The libfx native addon for ${label}`,
    type: "module",
    repository: sourceManifest.repository,
    homepage: sourceManifest.homepage,
    bugs: sourceManifest.bugs,
    os: [os],
    cpu: [cpu],
    ...(libc ? { libc: [libc] } : {}),
    exports: { ".": "./index.js", "./package.json": "./package.json" },
    sideEffects: false,
    engines: sourceManifest.engines,
    publishConfig: sourceManifest.publishConfig,
    license: sourceManifest.license,
  }, null, 2)}\n`);
  nativeDirs.push(dir);
}

console.log(`packaged ${manifest.name}@${version} in ${outputDir}`);
for (const [, destination] of files) console.log(`  ${destination}`);
for (const name of ["local", "vercel", "world"]) console.log(`  durable/${name}.mjs\n  durable/${name}.mjs.map`);
for (const name of declarations) console.log(`  types/${name}`);
for (const dir of nativeDirs) console.log(`packaged ${JSON.parse(await readFile(resolve(dir, "package.json"), "utf8")).name}@${version} in ${dir}`);
