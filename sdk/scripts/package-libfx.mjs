#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, dirname, posix, resolve } from "node:path";
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

// A release requires the docs (`LIBFX_REQUIRE_DOCS=1`). Any other build
// packages without them when the docs site cannot give them, so a local build
// or an unrelated test does not fail on the website.
let docs = [];
try {
  docs = await packageDocs(resolve(outputDir, "docs"));
} catch (error) {
  if (process.env.LIBFX_REQUIRE_DOCS === "1") throw error;
  await rm(resolve(outputDir, "docs"), { recursive: true, force: true });
  console.warn(`warning: packaging libfx without its docs: ${error.message}`);
}

const manifest = JSON.parse(await readFile(resolve(outputDir, "package.json"), "utf8"));
manifest.files = undefined;
await writeFile(resolve(outputDir, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`packaged ${manifest.name} in ${outputDir}`);
console.log("  node.cjs");
for (const [, destination] of files) console.log(`  ${destination}`);
console.log("  durable/local.mjs");
console.log("  durable/vercel.mjs");
console.log("  durable/world.mjs");
for (const name of docs) console.log(`  docs/${name}`);
for (const name of declarations) console.log(`  types/${name}`);
for (const addon of nativeAddons) {
  console.log(`  ${requestedNativeAddons.length ? basename(addon) : localNativeName}`);
}

// The libfx docs ship in the package (PKG-5). They are written in the fx
// website's repository, so each build takes the pages fx.sh publishes as
// Markdown, the libfx entries of its llms.txt, instead of keeping a copy
// here that would go stale. Links between the pages point at the packaged
// files. `LIBFX_DOCS_SITE` takes the pages from another copy of the site,
// such as the fixture `sdk/tests/test-node-package.mjs` serves; a release
// takes fx.sh's. Returns the files written, relative to `docsDir`.
async function packageDocs(docsDir) {
  const site = (process.env.LIBFX_DOCS_SITE || "https://fx.sh").replace(/\/+$/, "");
  const get = async (url) => {
    const response = await fetch(url, { signal: AbortSignal.timeout(30_000) });
    if (!response.ok) throw new Error(`packaging the libfx docs: ${url} answered HTTP ${response.status}`);
    return response.text();
  };
  const sitePattern = site.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // `- [Title](https://fx.sh/docs/lib/<page>.md): what it covers`, under `## libfx / <section>`.
  const pageUrl = new RegExp(`^${sitePattern}/docs/lib((?:/[a-z0-9-]+)*)\\.md$`);
  const pageLink = new RegExp(`\\]\\((${sitePattern}/docs/lib(?:/[a-z0-9-]+)*\\.md)`, "g");
  const pages = new Map();
  const index = [
    "# libfx docs",
    "",
    `The libfx pages of the fx docs, as fx.sh published them when this package was built. The latest version of each page is at ${site}/docs/lib.`,
  ];
  for (const line of (await get(`${site}/llms.txt`)).split("\n")) {
    const section = /^## libfx \/ (.+)$/.exec(line);
    if (section) index.push("", `## ${section[1][0].toUpperCase()}${section[1].slice(1)}`, "");
    const entry = /^- \[([^\]]+)\]\(([^)]+)\)(.*)$/.exec(line);
    const page = entry && pageUrl.exec(entry[2]);
    if (!page) continue;
    const file = page[1] === "" ? "index.md" : `${page[1].slice(1)}.md`;
    pages.set(entry[2], file);
    index.push(`- [${entry[1]}](${file})${entry[3]}`);
  }
  if (pages.size === 0) throw new Error(`packaging the libfx docs: ${site}/llms.txt lists no libfx page`);
  await mkdir(docsDir, { recursive: true });
  await writeFile(resolve(docsDir, "README.md"), `${index.join("\n")}\n`);
  for (const [url, file] of pages) {
    const text = (await get(url)).replace(pageLink, (link, target) => (
      pages.has(target) ? `](${posix.relative(posix.dirname(file), pages.get(target))}` : link
    ));
    await mkdir(dirname(resolve(docsDir, file)), { recursive: true });
    await writeFile(resolve(docsDir, file), text);
  }
  return ["README.md", ...pages.values()];
}
