// Bundles each durability module with the World it wraps into one
// self-contained ES module, so an app installs nothing more and never loads a
// World of its own. Run with Bun: `bun sdk/scripts/bundle-durable.mjs <out>`.
import { createHash } from "node:crypto";
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

// world-local's in-band fence lock records no holder, so a writer killed
// while it holds the lock makes the next in-band writer wait 30 s for it to
// go stale (DUR-88). The bundled World takes that lock through
// durable/world-local-fence-lock.mjs, which records the holder and frees a
// dead holder's lock at once. The whole lock call is matched, so a change to
// it upstream fails the build here.
const fenceLockImport = "import { lock as lockFile } from 'proper-lockfile';";
const fenceLockCall = `release = await lockFile(countPath, {
                    realpath: false,
                    stale: 30_000,
                    update: 1_000,
                    retries: {
                        retries: 350,
                        factor: 1,
                        minTimeout: 100,
                        maxTimeout: 100,
                    },
                    onCompromised(error) {
                        compromised = error;
                    },
                });`;
const fenceLockFs = fileURLToPath(new URL("../durable/world-local-fence-lock.mjs", import.meta.url));
const recordFenceLockHolder = {
  name: "record-fence-lock-holder",
  setup(build) {
    build.onLoad({ filter: /[\\/]world-local[\\/]dist[\\/]storage[\\/]events-storage\.js$/ }, async ({ path }) => {
      const source = await Bun.file(path).text();
      if (source.split(fenceLockImport).length !== 2 || source.split(fenceLockCall).length !== 2) {
        throw new Error("world-local's withFenceLock() changed; update the fence lock patch, or drop it if world-local now records the lock's holder");
      }
      const patched = source
        .replace(fenceLockImport, `${fenceLockImport}\nimport { fenceLockFs } from ${JSON.stringify(fenceLockFs)};`)
        .replace(fenceLockCall, fenceLockCall.replace("realpath: false,", "fs: fenceLockFs(),\n                    realpath: false,"));
      return { contents: patched, loader: "js" };
    });
  },
};

// world-local names a stream chunk when its write is called, and readers
// order chunks by name, so a write that stalls before it lands can land
// ahead of chunks readers already have (DUR-38). The bundled World lands its
// chunks through durable/world-local-stream-place.mjs, which names each one
// as it lands. World-local's `write`, `writeMulti` and `close` are replaced
// whole, and their source is checked by its digest, so a change to them
// upstream fails the build here.
const streamWritesStart = "            async write(_runId, name, chunk) {\n";
const streamWritesEnd = "            async list(runId) {\n";
const streamWritesDigest = "a878ddc2aeadb4a742cc529e7bb7177a3e4ba0153727593b4049cf64eed5fc93";
const streamerImport = "import { withInProcessLock } from './util.js';\n";
const streamPlace = fileURLToPath(new URL("../durable/world-local-stream-place.mjs", import.meta.url));
const placeStreamChunks = {
  name: "place-stream-chunks-on-landing",
  setup(build) {
    build.onLoad({ filter: /[\\/]world-local[\\/]dist[\\/]streamer\.js$/ }, async ({ path }) => {
      const source = await Bun.file(path).text();
      const start = source.indexOf(streamWritesStart);
      const end = source.indexOf(streamWritesEnd);
      const once = (text) => source.split(text).length === 2;
      const region = start >= 0 && end > start ? source.slice(start, end) : "";
      const digest = createHash("sha256").update(region).digest("hex");
      if (!once(streamWritesStart) || !once(streamWritesEnd) || !once(streamerImport) || digest !== streamWritesDigest) {
        throw new Error("world-local's stream writes changed; update the stream chunk patch, or drop it if world-local now names a chunk as it lands");
      }
      const placed = `            ...placedStreamWrites({ basedir, tagSuffix, streamEmitter, registerStreamForRun, toBuffer, serializeChunk, chunkDirForStream, writeFile: (filePath, data) => write(filePath, data, { overwrite: true }), retry: withWindowsRetry, mint: () => monotonicUlid() }),\n`;
      const patched = source.slice(0, start) + placed + source.slice(end);
      return { contents: patched.replace(streamerImport, `${streamerImport}import { placedStreamWrites } from ${JSON.stringify(streamPlace)};\n`), loader: "js" };
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
    // An ES module has no __dirname, and Bun would write in this machine's
    // path for each module that reads one, such as @vercel/queue's. Undefined,
    // they fall back to import.meta.url, the bundle's own location.
    define: { __dirname: "undefined", __filename: "undefined" },
    plugins: [pinWorldVersion, recordFenceLockHolder, placeStreamChunks, noUndici],
    metafile: true,
  });
  if (!result.success) {
    for (const log of result.logs) console.error(log);
    process.exit(1);
  }
  const bundled = Object.keys(result.metafile.inputs).filter((input) => /(^|[\\/])node_modules[\\/]undici[\\/]/.test(input));
  if (bundled.length > 0) throw new Error(`durable/${name}.mjs would bundle undici: ${bundled.slice(0, 3).join(", ")}`);
  const inputs = Object.keys(result.metafile.inputs);
  const repoRoot = fileURLToPath(new URL("../..", import.meta.url)).replace(/[\\/]$/, "");
  for (const output of result.outputs) {
    if ((await output.text()).includes(repoRoot)) throw new Error(`durable/${name}.mjs carries this machine's path ${repoRoot}`);
  }
  if (name === "local" && !inputs.some((input) => /(^|[\\/])world-local-fence-lock\.mjs$/.test(input))) {
    throw new Error("durable/local.mjs bundles world-local without the fence lock patch");
  }
  if (name === "local" && !inputs.some((input) => /(^|[\\/])world-local-stream-place\.mjs$/.test(input))) {
    throw new Error("durable/local.mjs bundles world-local without the stream chunk patch");
  }
}
