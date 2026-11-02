#!/usr/bin/env node
// Builds an agent-only app and a terminal app against an installed libfx with
// esbuild and Vite, and checks that each bundle carries only what its app
// uses: the agent's WebAssembly host and fx-core.wasm, or the terminal's and
// fx-term.wasm, and never the Node.js native loader. Run
// `npm ci --prefix sdk/tests/tools` first.
//
//   node sdk/tests/test-browser-bundles.mjs <libfx.tgz>
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const tarball = resolve(process.argv[2] ?? "");
const tools = fileURLToPath(new URL("./tools/node_modules/", import.meta.url));
const esbuild = resolve(tools, ".bin/esbuild");
const vite = resolve(tools, "vite/bin/vite.js");
const apps = {
  agent: 'import { createFxAgent } from "libfx/browser";\nglobalThis.fxAgent = createFxAgent();\n',
  terminal: 'import { createFxTerminal, xtermAdapter } from "libfx/browser";\nglobalThis.startFx = (term) => createFxTerminal({ terminal: xtermAdapter(term) });\n',
};
// libfx's modules for Node.js, which a browser bundle must never carry.
const nodeOnly = ["node.js", "node.cjs", "node-wasm.js", "bundled-asset.js", "skills-node.js"];
const expected = {
  agent: { has: ["browser-agent.js", "engine.js", "wasm-runtime.js", "wasm-module.js", "durable.js"], lacks: ["browser-terminal.js", "wasm-terminal.js", "fx-sdk.js"], wasm: "fx-core", other: "fx-term" },
  terminal: { has: ["browser-terminal.js", "wasm-terminal.js", "wasm-runtime.js", "xterm.js"], lacks: ["browser-agent.js", "durable.js", "fx-harness.js", "fx-sdk.js"], wasm: "fx-term", other: "fx-core" },
};

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: "utf8", timeout: 120_000 });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} ${args.join(" ")} failed:\n${result.stdout}\n${result.stderr}`);
  return `${result.stdout}${result.stderr}`;
}

async function emitted(dir) {
  const files = (await readdir(dir, { recursive: true })).map(String);
  let js = "";
  for (const file of files.filter((name) => /\.m?js$/.test(name))) js += await readFile(join(dir, file), "utf8");
  return { wasm: files.filter((name) => name.endsWith(".wasm")).map((name) => name.split("/").pop()).sort(), js };
}

// The bundle reaches no Node.js code: no platform package, and no Node.js
// built-in.
function assertBrowserOnly(name, js) {
  assert.doesNotMatch(js, /@libfx\/libfx-/, `${name} names a native addon package`);
  assert.doesNotMatch(js, /["'`]node:[a-z_/]+["'`]/, `${name} imports a Node.js built-in`);
}

const temp = await mkdtemp(resolve(tmpdir(), "libfx-browser-bundles-"));
try {
  await mkdir(resolve(temp, "node_modules/libfx"), { recursive: true });
  run("tar", ["-xzf", tarball, "-C", resolve(temp, "node_modules/libfx"), "--strip-components=1"], temp);
  for (const [name, source] of Object.entries(apps)) {
    const want = expected[name];

    // esbuild leaves `new URL` assets alone, so its metafile shows which of
    // libfx's modules each bundle carries.
    const esbuildApp = resolve(temp, `esbuild-${name}`);
    await mkdir(esbuildApp);
    await writeFile(resolve(esbuildApp, "main.js"), source);
    run(esbuild, ["main.js", "--bundle", "--format=esm", "--platform=browser", "--outdir=dist", "--metafile=dist/meta.json", "--log-level=warning"], esbuildApp);
    const meta = JSON.parse(await readFile(resolve(esbuildApp, "dist/meta.json"), "utf8"));
    const carried = Object.entries(meta.outputs["dist/main.js"].inputs)
      .filter(([, { bytesInOutput }]) => bytesInOutput > 0)
      .map(([input]) => input.split("node_modules/libfx/")[1])
      .filter(Boolean);
    for (const file of want.has) assert.ok(carried.includes(file), `esbuild ${name} bundle lacks ${file}: ${carried.join(", ")}`);
    for (const file of [...want.lacks, ...nodeOnly]) assert.ok(!carried.includes(file), `esbuild ${name} bundle carries ${file}`);
    assertBrowserOnly(`esbuild ${name}`, (await emitted(resolve(esbuildApp, "dist"))).js);

    // Vite copies the .wasm of every module it compiles. Its default build
    // copies both, though the app's code names only its own. With Rolldown's
    // lazy barrel optimization it compiles only the modules the app reaches.
    for (const lazyBarrel of [false, true]) {
      const viteApp = resolve(temp, `vite-${name}${lazyBarrel ? "-lazy" : ""}`);
      await mkdir(viteApp);
      await writeFile(resolve(viteApp, "main.js"), source);
      await writeFile(resolve(viteApp, "index.html"), '<!doctype html><script type="module" src="./main.js"></script>\n');
      if (lazyBarrel) await writeFile(resolve(viteApp, "vite.config.mjs"), "export default { build: { rolldownOptions: { experimental: { lazyBarrel: true } } } };\n");
      run(process.execPath, [vite, "build", "--logLevel", "warn"], viteApp);
      const { wasm, js } = await emitted(resolve(viteApp, "dist"));
      const label = `vite ${name}${lazyBarrel ? " with lazy barrel" : ""}`;
      assert.match(js, new RegExp(`${want.wasm}-[\\w-]+\\.wasm`), `${label} does not name ${want.wasm}.wasm`);
      assert.doesNotMatch(js, new RegExp(`${want.other}-[\\w-]+\\.wasm`), `${label} names ${want.other}.wasm`);
      if (lazyBarrel) {
        assert.equal(wasm.length, 1, `${label} emitted ${wasm.join(", ")}`);
        assert.ok(wasm[0].startsWith(`${want.wasm}-`), `${label} emitted ${wasm[0]}`);
      } else {
        assert.deepEqual(wasm.map((file) => file.split("-")[0] + "-" + file.split("-")[1]).sort(), ["fx-core", "fx-term"], `${label} emitted ${wasm.join(", ")}`);
      }
      assertBrowserOnly(label, js);
    }
    console.log(`${name} app bundles passed: esbuild carries ${want.has.join(", ")}; Vite names only ${want.wasm}.wasm`);
  }
  console.log("Browser bundles passed: each app carries only its own WebAssembly host and .wasm, and no Node.js code");
} finally {
  await rm(temp, { recursive: true, force: true });
}
