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

// libfx ships no copy of undici (PERF-14). The Worlds send their requests
// through undici dispatchers they build, unless Workflow's `node:http`
// transport (`WORKFLOW_NODE_HTTP`) is on: then Node's own HTTP client sends
// them, the Vercel queue client's go through the runtime's `fetch`, and
// nothing builds undici. The bundled Worlds always use that transport, and
// `undici` resolves to a module that throws if anything does build it.
const flagMarker = "return envFlag(NODE_HTTP_ENV_VAR, NODE_HTTP_DEFAULT, env);";
const noUndici = {
  name: "no-undici",
  setup(build) {
    build.onLoad({ filter: /[\\/]@workflow[\\/]world[\\/]dist[\\/]node-http-flag\.js$/ }, async ({ path }) => {
      const source = await Bun.file(path).text();
      if (source.split(flagMarker).length !== 2) throw new Error("@workflow/world's isNodeHttpEnabled() changed; update the transport pin");
      return { contents: source.replace(flagMarker, "return true;"), loader: "js" };
    });
    build.onResolve({ filter: /^undici$/ }, () => ({ path: "undici", namespace: "no-undici" }));
    build.onLoad({ filter: /.*/, namespace: "no-undici" }, () => ({
      contents: `const unavailable = (name) => function () {
  throw new Error(\`libfx bundles no undici, and its World sends requests over node:http, so nothing may use undici's \${name}\`);
};
export const Agent = unavailable("Agent");
export const DecoratorHandler = unavailable("DecoratorHandler");
export const RetryAgent = unavailable("RetryAgent");
export const request = unavailable("request");
`,
      loader: "js",
    }));
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
    plugins: [pinWorldVersion, noUndici],
    metafile: true,
  });
  if (!result.success) {
    for (const log of result.logs) console.error(log);
    process.exit(1);
  }
  const bundled = Object.keys(result.metafile.inputs).filter((input) => /(^|[\\/])node_modules[\\/]undici[\\/]/.test(input));
  if (bundled.length > 0) throw new Error(`durable/${name}.mjs would bundle undici: ${bundled.slice(0, 3).join(", ")}`);
}
