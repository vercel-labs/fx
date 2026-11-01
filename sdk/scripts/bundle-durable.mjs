// Bundles each durability module with the World it wraps into one
// self-contained ES module, so an app installs nothing more and never loads a
// World of its own. Run with Bun: `bun sdk/scripts/bundle-durable.mjs <out>`.
//
// The Worlds stay bundled instead of becoming dependencies of libfx. Their
// installed dependencies take about 29 MB, mostly zod and undici, against
// about 2 MB bundled, and every libfx install would carry them, including apps
// that never use durability. As optional peer dependencies, each app would
// install them itself. libfx also loads each durability module through an
// ignored import of one file, which a bundler copies without following its
// imports, so the module must carry everything it runs.
import { readFile, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const [outputDir] = process.argv.slice(2);
if (!outputDir) throw new Error("usage: bun sdk/scripts/bundle-durable.mjs <output-dir>");
const sourceDir = fileURLToPath(new URL("../durable/", import.meta.url));
const worlds = new URL("../durable/node_modules/@workflow/", import.meta.url);
const localWorld = await Bun.file(new URL("world-local/package.json", worlds)).json();

// world-local versions its data directory from the package.json beside its
// own module, which a bundle no longer has, so the version is pinned here.
const marker = "export async function getPackageInfo() {";
const pinWorldVersion = {
  name: "pin-world-local-version",
  setup(build) {
    build.onLoad({ filter: /[\\/]world-local[\\/]dist[\\/]init\.js$/ }, async ({ path }) => {
      const source = await Bun.file(path).text();
      if (source.split(marker).length !== 2) throw new Error("world-local's getPackageInfo() changed; update the version pin");
      const pinned = JSON.stringify({ name: localWorld.name, version: localWorld.version });
      return { contents: source.replace(marker, `${marker}\n    return ${pinned};`), loader: "js" };
    });
  },
};

// `world` carries no World; `local` and `vercel` inline it.
for (const name of ["local", "vercel", "world"]) {
  const result = await Bun.build({
    entrypoints: [fileURLToPath(new URL(`../durable/${name}.mjs`, import.meta.url))],
    outdir: resolve(outputDir, "durable"),
    naming: `${name}.mjs`,
    target: "node",
    format: "esm",
    // The bundles are mostly the Worlds' own dependencies. Minified, a cold
    // import of vercel.mjs takes about a fifth less time; the sourcemaps
    // still name each original file and line.
    minify: true,
    sourcemap: "linked",
    // cbor-x prefers an optional native addon and falls back without it.
    external: ["cbor-extract"],
    plugins: [pinWorldVersion],
  });
  if (!result.success) {
    for (const log of result.logs) console.error(log);
    process.exit(1);
  }
  for (const { path } of result.outputs.filter(({ path }) => path.endsWith(".map"))) await packageSourceMap(path);
}

// Bun names each source by its path on the machine that bundled it. A map in
// the package names it relative to sdk/durable instead, as in
// `node_modules/@workflow/world-local/dist/index.js`, and leaves the sources
// themselves out: they are about four times the size of the bundles.
async function packageSourceMap(path) {
  const map = JSON.parse(await readFile(path, "utf8"));
  map.sources = map.sources.map((source) => {
    const name = relative(sourceDir, resolve(dirname(path), source));
    if (name.startsWith("..") || isAbsolute(name)) throw new Error(`${path} names a source outside sdk/durable: ${source}`);
    return name.split(sep).join("/");
  });
  delete map.sourcesContent;
  await writeFile(path, JSON.stringify(map));
}
