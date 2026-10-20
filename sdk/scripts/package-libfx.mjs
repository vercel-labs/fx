#!/usr/bin/env node
// Assembles libfx and the versions of libfx that ship beside it, each in a
// directory of its own under <dist> (default sdk/dist), ready for `npm pack`
// or `npm publish`:
//
//   <dist>/libfx             libfx: the JavaScript, both .wasm files, types and docs
//   <dist>/libfx-<platform>  libfx@<version>-0.<platform>: one native addon (PKG-2)
//
// With no addons named, it packages zig-out/lib/libfx.node as this machine's
// platform. A release names all four, as `libfx.<platform>.node`. libfx gets
// the version in LIBFX_VERSION, or sdk/package.json's, and the others the
// versions companion-version.mjs derives from it. libfx installs each addon
// version as the optional dependency `libfx-<platform>`, an npm alias, so no
// package but libfx exists on npm. The terminal's fx-term.wasm stays in libfx:
// as a version of its own, the alias an app saves for it would resolve to the
// release on its next fresh install.
//
//   node sdk/scripts/package-libfx.mjs [<dist>] [<addon>...]
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, dirname, posix, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { companionVersion } from "./companion-version.mjs";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = resolve(scriptDir, "../..");
const distDir = resolve(process.argv[2] || resolve(repoRoot, "sdk/dist"));
const requestedNativeAddons = process.argv.slice(3).map((path) => resolve(path));
// What npm installs each platform's addon on. The Linux addons link glibc
// 2.34 (`-Dtarget=<arch>-linux-gnu.2.34`), so musl systems skip them.
const platforms = {
  "linux-x64": { os: "linux", cpu: "x64", libc: "glibc", label: "Linux on x64, with glibc 2.34 or newer" },
  "linux-arm64": { os: "linux", cpu: "arm64", libc: "glibc", label: "Linux on arm64, with glibc 2.34 or newer" },
  "darwin-x64": { os: "darwin", cpu: "x64", label: "macOS on x64" },
  "darwin-arm64": { os: "darwin", cpu: "arm64", label: "macOS on arm64" },
};
const localPlatform = `${process.platform}-${process.arch}`;
const nativeAddons = requestedNativeAddons.length
  ? requestedNativeAddons.map((path) => ({ path, platform: /^libfx\.(.+)\.node$/.exec(basename(path))?.[1] }))
  : [{ path: resolve(repoRoot, "zig-out/lib/libfx.node"), platform: localPlatform }];
const libfxFiles = [
  ["sdk/README.md", "README.md"],
  ["LICENSE", "LICENSE"],
  ["sdk/browser.js", "browser.js"],
  ["sdk/node.js", "node.js"],
  ["sdk/fx-sdk.js", "fx-sdk.js"],
  ["sdk/wasm.js", "wasm.js"],
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

const libfxManifest = JSON.parse(await readFile(resolve(repoRoot, "sdk/package.json"), "utf8"));
const version = process.env.LIBFX_VERSION || libfxManifest.version;
// The names libfx installs its addon versions under (npm aliases).
const platformPackages = Object.keys(platforms).map((platform) => `libfx-${platform}`).sort();
if (JSON.stringify(Object.keys(libfxManifest.optionalDependencies ?? {}).sort()) !== JSON.stringify(platformPackages) ||
    JSON.stringify(Object.keys(libfxManifest.peerDependenciesMeta ?? {}).sort()) !== JSON.stringify(platformPackages)) {
  throw new Error(`sdk/package.json must list exactly ${platformPackages.join(", ")} in optionalDependencies and peerDependenciesMeta`);
}
if (requestedNativeAddons.length) {
  const names = nativeAddons.map(({ path }) => basename(path));
  const required = Object.keys(platforms).map((platform) => `libfx.${platform}.node`);
  const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
  const missing = required.filter((name) => !names.includes(name));
  const unexpected = names.filter((name) => !required.includes(name));
  if (duplicates.length || missing.length || unexpected.length) {
    throw new Error([
      "publishable packages require exactly one addon for every supported platform",
      duplicates.length ? `duplicates: ${duplicates.join(", ")}` : null,
      missing.length ? `missing: ${missing.join(", ")}` : null,
      unexpected.length ? `unexpected: ${unexpected.join(", ")}` : null,
    ].filter(Boolean).join("; "));
  }
} else if (!platforms[localPlatform]) {
  throw new Error(`local native packaging is unsupported on ${localPlatform}`);
}

const libfxDir = resolve(distDir, "libfx");
const platformDir = (platform) => resolve(distDir, `libfx-${platform}`);
for (const dir of [libfxDir, ...Object.keys(platforms).map(platformDir)]) {
  await rm(dir, { recursive: true, force: true });
}
await mkdir(libfxDir, { recursive: true });

// libfx.
const cjsBuild = spawnSync(process.execPath, [
  resolve(repoRoot, "sdk/scripts/build-node-cjs.mjs"),
  resolve(libfxDir, "node.cjs"),
], { cwd: repoRoot, stdio: "inherit" });
if (cjsBuild.error) throw cjsBuild.error;
if (cjsBuild.status !== 0) process.exit(cjsBuild.status ?? 1);
for (const [source, destination] of libfxFiles) {
  await cp(resolve(repoRoot, source), resolve(libfxDir, destination));
}
// The TypeScript declarations the manifest's `types` conditions name.
const declarations = (await readdir(resolve(repoRoot, "sdk/types"))).filter((name) => /\.d\.c?ts$/.test(name)).sort();
await mkdir(resolve(libfxDir, "types"), { recursive: true });
for (const name of declarations) await cp(resolve(repoRoot, "sdk/types", name), resolve(libfxDir, "types", name));

// Each durability module carries the World it wraps; see bundle-durable.mjs.
if (!existsSync(resolve(repoRoot, "sdk/durable/node_modules/@workflow"))) {
  throw new Error("bundling the durable Worlds needs `npm ci --prefix sdk/durable` first");
}
const bundle = spawnSync(process.env.BUN_BIN || "bun", [resolve(repoRoot, "sdk/scripts/bundle-durable.mjs"), libfxDir], { cwd: repoRoot, stdio: "inherit" });
if (bundle.error) throw bundle.error;
if (bundle.status !== 0) process.exit(bundle.status ?? 1);

// A release requires the docs (`LIBFX_REQUIRE_DOCS=1`). Any other build
// packages without them when the docs site cannot give them, so a local build
// or an unrelated test does not fail on the website.
let docs = [];
try {
  docs = await packageDocs(resolve(libfxDir, "docs"));
} catch (error) {
  if (process.env.LIBFX_REQUIRE_DOCS === "1") throw error;
  await rm(resolve(libfxDir, "docs"), { recursive: true, force: true });
  console.warn(`warning: packaging libfx without its docs: ${error.message}`);
}

await writeManifest(libfxDir, {
  ...libfxManifest,
  version,
  files: undefined,
  optionalDependencies: Object.fromEntries(Object.keys(platforms).map((platform) => [`libfx-${platform}`, `npm:libfx@${companionVersion(version, platform)}`])),
});

// One version of libfx for each addon.
for (const { path, platform } of nativeAddons) {
  if (!path.endsWith(".node")) throw new Error(`native addon must end in .node: ${path}`);
  const { os, cpu, libc, label } = platforms[platform];
  const dir = platformDir(platform);
  const addon = `libfx.${platform}.node`;
  await mkdir(dir, { recursive: true });
  await cp(path, resolve(dir, addon));
  await cp(resolve(repoRoot, "LICENSE"), resolve(dir, "LICENSE"));
  // The URL bundlers and tracers follow to the addon (PKG-10); libfx loads it.
  await writeFile(resolve(dir, "index.js"), `export default new URL("./${addon}", import.meta.url);\n`);
  await writeFile(resolve(dir, "README.md"), [
    `# libfx ${companionVersion(version, platform)}`,
    "",
    `The native addon of [libfx](https://www.npmjs.com/package/libfx) ${version} for ${label}. libfx ${version} installs this version as its optional dependency \`libfx-${platform}\`, on this platform only. Install libfx, not this version.`,
    "",
    "## License",
    "",
    "[Apache-2.0](https://github.com/vercel-labs/fx/blob/main/LICENSE)",
    "",
  ].join("\n"));
  await writeManifest(dir, {
    name: "libfx",
    version: companionVersion(version, platform),
    description: `The ${platform} native addon of libfx ${version}`,
    type: "module",
    repository: libfxManifest.repository,
    homepage: libfxManifest.homepage,
    bugs: libfxManifest.bugs,
    os: [os],
    cpu: [cpu],
    ...(libc ? { libc: [libc] } : {}),
    exports: { ".": "./index.js", "./package.json": "./package.json" },
    engines: libfxManifest.engines,
    publishConfig: libfxManifest.publishConfig,
    license: libfxManifest.license,
  });
}

console.log(`packaged libfx ${version} in ${distDir}`);
for (const dir of [libfxDir, ...nativeAddons.map(({ platform }) => platformDir(platform))]) {
  const manifest = JSON.parse(await readFile(resolve(dir, "package.json"), "utf8"));
  console.log(`${manifest.name}@${manifest.version} (${basename(dir)}/)`);
  for (const file of (await readdir(dir, { recursive: true, withFileTypes: true })).filter((entry) => entry.isFile())) {
    console.log(`  ${relative(dir, resolve(file.parentPath, file.name))}`);
  }
}
if (docs.length === 0) console.log("(libfx has no docs/: see the warning above)");

async function writeManifest(dir, manifest) {
  await writeFile(resolve(dir, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);
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
