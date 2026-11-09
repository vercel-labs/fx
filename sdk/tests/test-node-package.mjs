#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const temp = await mkdtemp(join(tmpdir(), "libfx-node-package-"));
const packageRoot = join(temp, "packages");
const packageDir = join(packageRoot, "libfx");
// The one platform package a local build produces, and the name node.js
// imports it by.
const nativePackages = {
  "linux-x64": "@libfx/libfx-linux-x64-gnu",
  "linux-arm64": "@libfx/libfx-linux-arm64-gnu",
  "darwin-x64": "@libfx/libfx-darwin-x64",
  "darwin-arm64": "@libfx/libfx-darwin-arm64",
};
const localNativePackage = nativePackages[`${process.platform}-${process.arch}`];
const localNativeDir = join(packageRoot, localNativePackage.slice("@libfx/".length));
const consumerDir = join(temp, "consumer");
const installedPackage = join(consumerDir, "node_modules", "libfx");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    encoding: "utf8",
    env: { ...process.env, ...options.env },
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} ${args.join(" ")} failed:\n${result.stdout}\n${result.stderr}`);
  return result;
}

try {
  const workflow = await readFile(resolve(repoRoot, ".github/workflows/publish-libfx.yml"), "utf8");
  const packageJob = workflow.split("\n  package:\n")[1]?.split("\n  publish:\n")[0];
  assert.ok(packageJob, "publisher package job must exist");
  const bunSetup = packageJob.indexOf("uses: oven-sh/setup-bun@");
  const assembly = packageJob.indexOf("- name: Assemble package");
  assert.ok(bunSetup >= 0 && bunSetup < assembly, "publisher must install Bun before bundling the durable Worlds");

  run(process.execPath, [resolve(repoRoot, "sdk/scripts/package-libfx.mjs"), packageRoot], { env: { LIBFX_VERSION: "1.2.3-test.4" } });

  const manifest = JSON.parse(await readFile(join(packageDir, "package.json"), "utf8"));
  const typed = (types, entry) => ({ types: `./types/${types}`, default: entry });
  const nodeEntry = { import: typed("node.d.ts", "./node.js"), require: typed("node.d.cts", "./node.cjs") };
  assert.deepEqual(manifest.exports["."], {
    node: nodeEntry,
    browser: typed("browser.d.ts", "./browser.js"),
    default: typed("browser.d.ts", "./browser.js"),
  });
  assert.deepEqual(manifest.exports["./node"], nodeEntry);
  assert.deepEqual(manifest.exports["./browser"], typed("browser.d.ts", "./browser.js"));
  assert.deepEqual(manifest.exports["./wasm"], typed("wasm.d.ts", "./fx-sdk.js"));
  assert.deepEqual(manifest.exports["./mcp"], typed("mcp.d.ts", "./mcp.js"));
  assert.deepEqual(manifest.exports["./skills"], typed("skills.d.ts", "./skills.js"));
  assert.deepEqual(manifest.exports["./skills/node"], typed("skills-node.d.ts", "./skills-node.js"));
  // No module does work on import, so bundlers may drop the ones an app never
  // uses. require() of node.js needs Node.js 20.19 or 22.12.
  assert.equal(manifest.sideEffects, false);
  assert.equal(manifest.engines.node, "^20.19.0 || >=22.12.0");
  // libfx pins every platform's package to its own version, and a local
  // build produces the one for this machine.
  assert.equal(manifest.version, "1.2.3-test.4");
  assert.deepEqual(manifest.optionalDependencies, Object.fromEntries(Object.values(nativePackages).map((name) => [name, manifest.version])));
  assert.deepEqual((await readdir(packageRoot)).sort(), ["libfx", basename(localNativeDir)].sort());
  const nativeManifest = JSON.parse(await readFile(join(localNativeDir, "package.json"), "utf8"));
  assert.equal(nativeManifest.name, localNativePackage);
  assert.equal(nativeManifest.version, manifest.version);
  assert.deepEqual(nativeManifest.os, [process.platform]);
  assert.deepEqual(nativeManifest.cpu, [process.arch]);
  assert.deepEqual(nativeManifest.libc, process.platform === "linux" ? ["glibc"] : undefined);
  assert.deepEqual(nativeManifest.exports, { ".": "./index.js", "./package.json": "./package.json" });
  assert.deepEqual((await readdir(localNativeDir)).sort(), ["LICENSE", "README.md", "index.js", "libfx.node", "package.json"]);
  assert.ok(!(await readdir(packageDir)).some((name) => name.endsWith(".node")), "libfx itself carries no native addon");
  // Every `types` condition names a declaration the package carries.
  for (const target of JSON.stringify(manifest.exports).match(/\.\/types\/[^"]+/g)) {
    assert.ok(existsSync(join(packageDir, target)), `package is missing ${target}`);
  }

  const archiveValidator = packageJob.match(/- name: Validate package archive\n\s+run: \|\n\s+node -e '([\s\S]*?)'/)?.[1];
  assert.ok(archiveValidator, "publisher archive validation must exist");
  const reportPath = join(temp, "libfx-pack.json");
  // Every file, at its path in the package, as `npm pack` reports them.
  const archiveFiles = new Set((await readdir(packageDir, { recursive: true, withFileTypes: true }))
    .filter((entry) => entry.isFile())
    .map((entry) => relative(packageDir, join(entry.parentPath, entry.name)).split(sep).join("/")));
  const archiveReport = [{ name: manifest.name, version: manifest.version, size: 0, files: [...archiveFiles].map(path => ({ path })) }];
  await writeFile(reportPath, JSON.stringify(archiveReport));
  run(process.execPath, ["-e", archiveValidator.replace("/tmp/libfx-pack.json", reportPath)]);
  archiveReport[0].files = archiveReport[0].files.filter(({ path }) => path !== "fetch-cleanup.js");
  await writeFile(reportPath, JSON.stringify(archiveReport));
  assert.throws(
    () => run(process.execPath, ["-e", archiveValidator.replace("/tmp/libfx-pack.json", reportPath)]),
    /unexpected package file count|package is missing/,
  );

  // The publisher's platform package check, on reports for every package
  // libfx pins, then on sets it must reject.
  const platformValidator = packageJob.match(/- name: Validate platform package archives\n\s+run: \|\n\s+node -e '([\s\S]*?)'/)?.[1];
  assert.ok(platformValidator, "publisher platform package validation must exist");
  const manifestPath = join(temp, "libfx-manifest.json");
  const platformReportPath = join(temp, "libfx-native-pack.json");
  await writeFile(manifestPath, JSON.stringify(manifest));
  const platformFiles = ["package.json", "index.js", "libfx.node", "LICENSE", "README.md"].map((path) => ({ path }));
  const platformReport = Object.keys(manifest.optionalDependencies).map((name) => ({ name, version: manifest.version, size: 0, files: platformFiles }));
  const validatePlatforms = async (report) => {
    await writeFile(platformReportPath, JSON.stringify(report));
    const script = platformValidator.replace("/tmp/libfx-manifest.json", manifestPath).replace("/tmp/libfx-native-pack.json", platformReportPath);
    return spawnSync(process.execPath, ["-e", script], { encoding: "utf8" });
  };
  const accepted = await validatePlatforms(platformReport);
  assert.equal(accepted.status, 0, accepted.stderr);
  const changeFirst = (change) => platformReport.map((report, index) => index ? report : { ...report, ...change });
  for (const [report, message] of [
    [platformReport.slice(1), /do not match the pinned/],
    [changeFirst({ version: "0.0.0" }), /does not match libfx/],
    [changeFirst({ files: [...platformFiles, { path: "extra.js" }] }), /unexpected files/],
  ]) {
    const rejected = await validatePlatforms(report);
    assert.notEqual(rejected.status, 0, "publisher accepted a broken platform package set");
    assert.match(rejected.stderr, message);
  }

  // node.cjs only runs node.js, which imports each platform's package by a
  // literal name that bundlers and file tracers follow, and names no addon.
  assert.equal(await readFile(join(packageDir, "node.cjs"), "utf8"), await readFile(resolve(repoRoot, "sdk/node.cjs"), "utf8"));
  const source = await readFile(resolve(repoRoot, "sdk/node.js"), "utf8");
  assert.doesNotMatch(source, /libfx\.(linux|darwin)-[a-z0-9]+\.node/, "node.js names a bundled addon");
  for (const name of Object.values(nativePackages)) {
    assert.ok(source.includes(`import("${name}")`), `node.js must import ${name} by a literal name`);
  }
  // Each durable bundle links a sourcemap that names its sources relative to
  // sdk/durable and leaves their text out.
  for (const name of ["local", "vercel", "world"]) {
    const bundle = await readFile(join(packageDir, "durable", `${name}.mjs`), "utf8");
    assert.ok(bundle.trimEnd().endsWith(`//# sourceMappingURL=${name}.mjs.map`), `durable/${name}.mjs must link its sourcemap`);
    const map = JSON.parse(await readFile(join(packageDir, "durable", `${name}.mjs.map`), "utf8"));
    assert.equal(map.sourcesContent, undefined, `durable/${name}.mjs.map must leave the sources out`);
    assert.ok(map.sources.includes(`${name}.mjs`), `durable/${name}.mjs.map must name ${name}.mjs`);
    for (const path of map.sources) assert.ok(!path.startsWith("..") && !path.startsWith("/") && !path.includes("\\"), `durable/${name}.mjs.map names ${path}`);
  }

  await cp(packageDir, installedPackage, { recursive: true });
  await cp(localNativeDir, join(consumerDir, "node_modules", localNativePackage), { recursive: true });
  await writeFile(join(consumerDir, "package.json"), '{"type":"module"}\n');
  await writeFile(join(consumerDir, "esm.mjs"), `
    import * as libfx from "libfx";
    import * as nodeEntry from "libfx/node";
    const { createFxEngine, createFxTerminal, getBackendInfo } = libfx;
    if (JSON.stringify(Object.keys(libfx).sort()) !== JSON.stringify(Object.keys(nodeEntry).sort())) {
      throw new Error("root and Node subpath ESM exports differ");
    }
    const info = await getBackendInfo({ backend: "native" });
    if (typeof createFxEngine !== "function" || typeof createFxTerminal !== "function" || info.backend !== "native") {
      throw new Error(JSON.stringify(info));
    }
    const agent = await createFxEngine({ backend: "native", apiKey: "package-test-key" });
    const checkpoint = await agent.checkpoint();
    await agent.close();
    if (!(checkpoint instanceof Uint8Array) || checkpoint.length === 0) throw new Error("empty checkpoint");
    console.log(JSON.stringify(Object.keys(libfx).sort()));
  `);
  await writeFile(join(consumerDir, "cjs.cjs"), `
    const libfx = require("libfx");
    const nodeEntry = require("libfx/node");
    const { createFxEngine, createFxTerminal, getBackendInfo } = libfx;
    (async () => {
      if (JSON.stringify(Object.keys(libfx).sort()) !== JSON.stringify(Object.keys(nodeEntry).sort())) {
        throw new Error("root and Node subpath CommonJS exports differ");
      }
      const info = await getBackendInfo({ backend: "native" });
      if (typeof createFxEngine !== "function" || typeof createFxTerminal !== "function" || info.backend !== "native") {
        throw new Error(JSON.stringify(info));
      }
      const agent = await createFxEngine({ backend: "native", apiKey: "package-test-key" });
      const checkpoint = await agent.checkpoint();
      await agent.close();
      if (!(checkpoint instanceof Uint8Array) || checkpoint.length === 0) throw new Error("empty checkpoint");
      console.log(JSON.stringify(Object.keys(libfx).sort()));
    })();
  `);

  const esm = run(process.execPath, ["esm.mjs"], { cwd: consumerDir });
  const cjsResult = run(process.execPath, ["cjs.cjs"], { cwd: consumerDir });
  assert.deepEqual(JSON.parse(cjsResult.stdout), JSON.parse(esm.stdout));
  // Without require() of ES modules, as before Node.js 20.19 and 22.12,
  // require("libfx") names the versions it needs.
  const oldNode = spawnSync(process.execPath, ["--no-experimental-require-module", "cjs.cjs"], { cwd: consumerDir, encoding: "utf8" });
  assert.notEqual(oldNode.status, 0, "require() without require(esm) must fail");
  assert.match(oldNode.stderr, /require\("libfx"\) needs Node\.js 20\.19, 22\.12, or newer/);
  console.log("Node package passed: publisher prerequisites, archive and platform package validation, conditional exports, CJS through require(esm), durable sourcemaps, literal native assets, and bare imports");
} finally {
  await rm(temp, { recursive: true, force: true });
}
