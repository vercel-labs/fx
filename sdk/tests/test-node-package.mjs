#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const temp = await mkdtemp(join(tmpdir(), "libfx-node-package-"));
const packageDir = join(temp, "package");
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
  assert.ok(bunSetup >= 0 && bunSetup < assembly, "publisher must install Bun before building the CommonJS entry");

  run(process.execPath, [resolve(repoRoot, "sdk/scripts/package-libfx.mjs"), packageDir]);

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
  for (const platform of ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"]) {
    archiveFiles.add(`libfx.${platform}.node`);
  }
  const archiveReport = [{ name: manifest.name, version: manifest.version, size: 0, files: [...archiveFiles].map(path => ({ path })) }];
  await writeFile(reportPath, JSON.stringify(archiveReport));
  run(process.execPath, ["-e", archiveValidator.replace("/tmp/libfx-pack.json", reportPath)]);
  archiveReport[0].files = archiveReport[0].files.filter(({ path }) => path !== "fetch-cleanup.js");
  await writeFile(reportPath, JSON.stringify(archiveReport));
  assert.throws(
    () => run(process.execPath, ["-e", archiveValidator.replace("/tmp/libfx-pack.json", reportPath)]),
    /unexpected package file count|package is missing/,
  );

  const cjs = await readFile(join(packageDir, "node.cjs"), "utf8");
  assert.doesNotMatch(cjs, new RegExp(repoRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  for (const platform of ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"]) {
    assert.match(cjs, new RegExp(`libfx\\.${platform}\\.node`));
  }

  const source = await readFile(resolve(repoRoot, "sdk/node.js"), "utf8");
  assert.doesNotMatch(source, /["']\.\/libfx\.node["']/);
  for (const platform of ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"]) {
    assert.match(source, new RegExp(`["']\\.\\/libfx\\.${platform}\\.node["']`));
  }

  await cp(packageDir, installedPackage, { recursive: true });
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
  const cjsResult = run(process.execPath, ["--no-experimental-require-module", "cjs.cjs"], { cwd: consumerDir });
  assert.deepEqual(JSON.parse(cjsResult.stdout), JSON.parse(esm.stdout));
  console.log("Node package passed: publisher prerequisites, archive validation, conditional exports, relocated CJS, literal native assets, and bare imports");
} finally {
  await rm(temp, { recursive: true, force: true });
}
