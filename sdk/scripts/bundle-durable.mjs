// Bundles each durability module with the World it wraps into one
// self-contained ES module, so an app installs nothing more and never loads a
// World of its own. Run with Bun: `bun sdk/scripts/bundle-durable.mjs <out>`.
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const [outputDir] = process.argv.slice(2);
if (!outputDir) throw new Error("usage: bun sdk/scripts/bundle-durable.mjs <output-dir>");
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
    minify: true,
    // cbor-x prefers an optional native addon and falls back without it.
    external: ["cbor-extract"],
    plugins: [pinWorldVersion],
  });
  if (!result.success) {
    for (const log of result.logs) console.error(log);
    process.exit(1);
  }
}
