#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { companionVersion } from "../scripts/companion-version.mjs";
import { nativeAlias, nativePackageBeside, nativePlatform } from "./package-siblings.mjs";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const temp = await mkdtemp(join(tmpdir(), "libfx-node-package-"));
const distDir = join(temp, "dist");
const packageDir = join(distDir, "libfx");
const consumerDir = join(temp, "consumer");
const installedPackage = join(consumerDir, "node_modules", "libfx");
const platforms = ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"];
const version = "1.2.3-package.4";

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

// The packager takes the docs from a server in this process, so it runs
// without blocking this process. It writes libfx and the packages beside it
// into `outputDir`.
function packageLibfx(outputDir, env) {
  return new Promise((done, fail) => {
    const child = spawn(process.execPath, [resolve(repoRoot, "sdk/scripts/package-libfx.mjs"), outputDir], {
      cwd: repoRoot,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    for (const stream of [child.stdout, child.stderr]) {
      stream.setEncoding("utf8");
      stream.on("data", (chunk) => { output += chunk; });
    }
    child.on("error", fail);
    child.on("close", (status) => done({ status, output }));
  });
}

// A docs site on this machine, so that no test depends on fx.sh. Its llms.txt
// has fx.sh's format: libfx entries, one of them nested, among other pages.
// The pages link to one another, with anchors, to a page outside libfx, and
// to a libfx page the index does not list. `{site}` stands for the site's
// address. Each page is [path on the site, packaged file, title, text the
// site serves, text the package holds].
const docsPage = (title, text) => `---\ntitle: ${title}\n---\n\n${text}\n`;
const docsPages = [
  ["/docs/lib.md", "index.md", "Overview",
    "Start with the [quick start]({site}/docs/lib/quick-start.md), then read [durability]({site}/docs/lib/durability.md#sessions).",
    "Start with the [quick start](quick-start.md), then read [durability](durability.md#sessions)."],
  ["/docs/lib/quick-start.md", "quick-start.md", "Quick start",
    "The [fx CLI]({site}/docs.md) is another product. Every option is in the [API reference]({site}/docs/lib/api.md).",
    "The [fx CLI]({site}/docs.md) is another product. Every option is in the [API reference](api.md)."],
  ["/docs/lib/durability.md", "durability.md", "Durability",
    "On Vercel, see [Durability on Vercel]({site}/docs/lib/durability/vercel.md). Back to the [overview]({site}/docs/lib.md).",
    "On Vercel, see [Durability on Vercel](durability/vercel.md). Back to the [overview](index.md)."],
  ["/docs/lib/durability/vercel.md", "durability/vercel.md", "Durability on Vercel",
    "Its options are in the [API reference]({site}/docs/lib/api.md#vercel), next to [durability]({site}/docs/lib/durability.md) and [a draft]({site}/docs/lib/draft.md).",
    "Its options are in the [API reference](../api.md#vercel), next to [durability](../durability.md) and [a draft]({site}/docs/lib/draft.md)."],
  ["/docs/lib/api.md", "api.md", "API reference",
    "`createFxAgent(options)` creates an agent. Back to the [overview]({site}/docs/lib.md).",
    "`createFxAgent(options)` creates an agent. Back to the [overview](index.md)."],
];
const llmsTxt = `# fx documentation

> fx is a coding agent for your terminal.

## getting started

- [Quick start]({site}/docs.md): Install fx and send your first prompt.
## libfx / getting started

- [Overview]({site}/docs/lib.md): Run the fx agent from JavaScript.
- [Quick start]({site}/docs/lib/quick-start.md): Install libfx and stream your first reply.
## libfx / build an agent

- [Durability]({site}/docs/lib/durability.md): Keep sessions running through crashes.
- [Durability on Vercel]({site}/docs/lib/durability/vercel.md): Run durable sessions on Vercel.
## libfx / reference

- [API reference]({site}/docs/lib/api.md): Interfaces and options.

## Project and policies

- [Changelog]({site}/changelog.md): New features and fixes in fx.
`;
const docsRequests = [];
let unavailableDocsPath = null;
const docsServer = createServer((request, response) => {
  const path = request.url.split("?")[0];
  docsRequests.push(path);
  const page = docsPages.find(([sitePath]) => sitePath === path);
  const text = path === "/llms.txt" ? llmsTxt : page && docsPage(page[2], page[3]);
  if (path === unavailableDocsPath || !text) {
    response.writeHead(path === unavailableDocsPath ? 503 : 404).end();
    return;
  }
  response.writeHead(200, { "content-type": "text/markdown; charset=utf-8" }).end(text.replaceAll("{site}", docsSite));
});
await new Promise((ready) => docsServer.listen(0, "127.0.0.1", ready));
const docsSite = `http://127.0.0.1:${docsServer.address().port}`;

try {
  const workflow = await readFile(resolve(repoRoot, ".github/workflows/publish-libfx.yml"), "utf8");
  const packageJob = workflow.split("\n  package:\n")[1]?.split("\n  publish:\n")[0];
  assert.ok(packageJob, "publisher package job must exist");
  const bunSetup = packageJob.indexOf("uses: oven-sh/setup-bun@");
  const assembly = packageJob.indexOf("- name: Assemble package");
  assert.ok(bunSetup >= 0 && bunSetup < assembly, "publisher must install Bun before building the CommonJS entry");

  // PKG-5: the publisher requires the docs, and takes them from fx.sh.
  assert.match(packageJob, /LIBFX_REQUIRE_DOCS=1 node sdk\/scripts\/package-libfx\.mjs/, "publisher must require the libfx docs");
  assert.doesNotMatch(workflow, /LIBFX_DOCS_SITE/, "publisher must take the docs fx.sh publishes");

  // When the docs site cannot give a page, a build that requires the docs
  // fails, and any other build packages without them.
  unavailableDocsPath = "/docs/lib/api.md";
  const unavailable = new RegExp(`packaging the libfx docs: ${docsSite.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/docs/lib/api\\.md answered HTTP 503`);
  const required = await packageLibfx(join(temp, "package-docs-required"), { LIBFX_DOCS_SITE: docsSite, LIBFX_REQUIRE_DOCS: "1" });
  assert.notEqual(required.status, 0, "a build that requires the docs must fail without them");
  assert.match(required.output, unavailable);
  const optional = await packageLibfx(join(temp, "package-docs-optional"), { LIBFX_DOCS_SITE: docsSite, LIBFX_REQUIRE_DOCS: "" });
  assert.equal(optional.status, 0, optional.output);
  assert.match(optional.output, new RegExp(`warning: packaging libfx without its docs: ${unavailable.source}`));
  assert.ok(existsSync(join(temp, "package-docs-optional", "libfx", "package.json")), "a build without the docs still packages libfx");
  assert.ok(!existsSync(join(temp, "package-docs-optional", "libfx", "docs")), "a build without the docs leaves no partial docs");
  unavailableDocsPath = null;

  // As the publisher packages it, with the docs required and the release's
  // version.
  docsRequests.length = 0;
  const packaged = await packageLibfx(distDir, { LIBFX_DOCS_SITE: docsSite, LIBFX_REQUIRE_DOCS: "1", LIBFX_VERSION: version });
  assert.equal(packaged.status, 0, packaged.output);
  assert.deepEqual(docsRequests, ["/llms.txt", ...docsPages.map(([sitePath]) => sitePath)], "the packager fetches the index, then each libfx page it lists");

  // PKG-2: libfx carries no native addon. Each platform's addon is a version
  // of libfx that libfx installs, under an alias, only on that platform, and
  // libfx names each addon version exactly. The terminal's fx-term.wasm stays
  // in libfx.
  const nativeDir = nativePackageBeside(packageDir);
  assert.equal(nativeDir, join(distDir, `libfx-${nativePlatform}`));
  assert.deepEqual((await readdir(distDir)).sort(), ["libfx", `libfx-${nativePlatform}`].sort(), "a local build packages this machine's addon only");
  const manifest = JSON.parse(await readFile(join(packageDir, "package.json"), "utf8"));
  assert.equal(manifest.version, version);
  assert.deepEqual(manifest.optionalDependencies, Object.fromEntries(platforms.map((platform) => [`libfx-${platform}`, `npm:libfx@${companionVersion(version, platform)}`])));
  assert.deepEqual(manifest.peerDependenciesMeta, Object.fromEntries(platforms.map((platform) => [`libfx-${platform}`, { optional: true }]).sort()));
  for (const field of ["dependencies", "peerDependencies", "devDependencies", "files"]) assert.equal(manifest[field], undefined, `libfx has no ${field}`);
  assert.ok(!(await readdir(packageDir)).some((name) => name.endsWith(".node")), "libfx carries no addon");
  for (const name of ["fx-core.wasm", "fx-term.wasm"]) assert.ok(existsSync(join(packageDir, name)), `libfx carries ${name}`);
  const nativeManifest = JSON.parse(await readFile(join(nativeDir, "package.json"), "utf8"));
  const [os, cpu] = nativePlatform.split("-");
  assert.deepEqual(
    { name: nativeManifest.name, version: nativeManifest.version, os: nativeManifest.os, cpu: nativeManifest.cpu, libc: nativeManifest.libc, exports: nativeManifest.exports },
    { name: "libfx", version: companionVersion(version, nativePlatform), os: [os], cpu: [cpu], libc: os === "linux" ? ["glibc"] : undefined, exports: { ".": "./index.js", "./package.json": "./package.json" } },
  );
  assert.deepEqual((await readdir(nativeDir)).sort(), ["LICENSE", "README.md", "index.js", `libfx.${nativePlatform}.node`, "package.json"]);
  assert.equal(await readFile(join(nativeDir, "index.js"), "utf8"), `export default new URL("./libfx.${nativePlatform}.node", import.meta.url);\n`);
  // It imports nothing, so under its alias it never resolves `libfx` to itself.
  for (const field of ["dependencies", "peerDependencies", "optionalDependencies"]) assert.equal(nativeManifest[field], undefined, `the addon version has no ${field}`);
  assert.equal(await readFile(join(nativeDir, "LICENSE"), "utf8"), await readFile(resolve(repoRoot, "LICENSE"), "utf8"), "the addon version carries the license (PKG-6)");
  const typed = (types, entry) => ({ types: `./types/${types}`, default: entry });
  const nodeEntry = { import: typed("node.d.ts", "./node.js"), require: typed("node.d.cts", "./node.cjs") };
  assert.deepEqual(manifest.exports["."], {
    node: nodeEntry,
    browser: typed("browser.d.ts", "./browser.js"),
    default: typed("browser.d.ts", "./browser.js"),
  });
  assert.deepEqual(manifest.exports["./node"], nodeEntry);
  assert.deepEqual(manifest.exports["./browser"], typed("browser.d.ts", "./browser.js"));
  assert.deepEqual(manifest.exports["./wasm"], typed("wasm.d.ts", "./wasm.js"));
  assert.deepEqual(manifest.exports["./mcp"], typed("mcp.d.ts", "./mcp.js"));
  assert.deepEqual(manifest.exports["./skills"], typed("skills.d.ts", "./skills.js"));
  assert.deepEqual(manifest.exports["./skills/node"], typed("skills-node.d.ts", "./skills-node.js"));
  // Every `types` condition names a declaration the package carries.
  for (const target of JSON.stringify(manifest.exports).match(/\.\/types\/[^"]+/g)) {
    assert.ok(existsSync(join(packageDir, target)), `package is missing ${target}`);
  }

  const archiveValidator = packageJob.match(/- name: Validate package archives\n(?:\s+env:\n(?:\s+\w+: .*\n)+)?\s+run: \|\n\s+node --input-type=module -e '([\s\S]*?)'/)?.[1];
  assert.ok(archiveValidator, "publisher archive validation must exist");
  const reportPath = join(temp, "libfx-pack.json");
  // Every file of a package directory, at its path in the package, as
  // `npm pack` reports them.
  const packedFiles = async (dir) => (await readdir(dir, { recursive: true, withFileTypes: true }))
    .filter((entry) => entry.isFile())
    .map((entry) => relative(dir, join(entry.parentPath, entry.name)).split(sep).join("/"));
  const archiveFiles = new Set(await packedFiles(packageDir));
  // `npm pack <dir>...` reports each archive, every one of them libfx at a
  // version of its own. This machine built one addon; the other platforms'
  // versions have the same files.
  const archiveReports = () => [
    { name: "libfx", version, size: 0, files: [...archiveFiles].map((path) => ({ path })) },
    ...platforms.map((platform) => ({
      name: "libfx", version: companionVersion(version, platform), size: 0,
      files: ["LICENSE", "README.md", "index.js", `libfx.${platform}.node`, "package.json"].map((path) => ({ path })),
    })),
  ];
  // From a file, so that a failure's message holds the validator's error, not its source.
  const validatorPath = join(temp, "validate-archives.mjs");
  await writeFile(validatorPath, archiveValidator.replace("/tmp/libfx-pack.json", reportPath));
  const validate = async (reports) => {
    await writeFile(reportPath, JSON.stringify(reports));
    return run(process.execPath, [validatorPath], { env: { LIBFX_VERSION: version } });
  };
  await validate(archiveReports());
  const mutated = (change) => archiveReports().map((report) => change(report) || report);
  for (const [reports, message] of [
    [mutated((report) => report.version === version && { ...report, files: report.files.filter(({ path }) => path !== "fetch-cleanup.js") }), /unexpected file count|is missing fetch-cleanup\.js/],
    [mutated((report) => report.version === version && { ...report, files: report.files.filter(({ path }) => !path.startsWith("docs/")) }), /libfx is missing the libfx docs/],
    [mutated((report) => report.version === version && { ...report, files: [...report.files, { path: "libfx.linux-x64.node" }] }), /libfx must not carry/],
    [mutated((report) => report.version === version && { ...report, files: report.files.filter(({ path }) => path !== "fx-term.wasm") }), /unexpected file count|is missing fx-term\.wasm/],
    [mutated((report) => report.version === companionVersion(version, "linux-x64") && { ...report, files: report.files.filter(({ path }) => !path.endsWith(".node")) }), new RegExp(`libfx@${companionVersion(version, "linux-x64").replaceAll(".", "\\.")}(: unexpected file count| is missing)`)],
    [archiveReports().filter((report) => report.version !== companionVersion(version, "darwin-arm64")), /expected libfx at/],
    [mutated((report) => report.version === companionVersion(version, "darwin-x64") && { ...report, version: "0.0.1" }), /expected libfx at/],
    [mutated((report) => report.version === companionVersion(version, "linux-arm64") && { ...report, name: "@libfx/linux-arm64" }), /expected libfx at/],
  ]) {
    await assert.rejects(validate(reports), message);
  }

  // PKG-5: the docs ship in the package: an index in the site's order, and
  // each libfx page as the site served it, with its links to the other
  // packaged pages opening them.
  assert.equal(await readFile(join(packageDir, "docs/README.md"), "utf8"), `# libfx docs

The libfx pages of the fx docs, as fx.sh published them when this package was built. The latest version of each page is at ${docsSite}/docs/lib.

## Getting started

- [Overview](index.md): Run the fx agent from JavaScript.
- [Quick start](quick-start.md): Install libfx and stream your first reply.

## Build an agent

- [Durability](durability.md): Keep sessions running through crashes.
- [Durability on Vercel](durability/vercel.md): Run durable sessions on Vercel.

## Reference

- [API reference](api.md): Interfaces and options.
`);
  assert.deepEqual(
    [...archiveFiles].filter((path) => path.startsWith("docs/")).sort(),
    ["docs/README.md", ...docsPages.map(([, file]) => `docs/${file}`)].sort(),
  );
  for (const [, file, title, , text] of docsPages) {
    assert.equal(await readFile(join(packageDir, "docs", file), "utf8"), docsPage(title, text).replaceAll("{site}", docsSite), `docs/${file}`);
  }

  // PERF-14: no packaged file carries a copy of undici. Its client names its
  // errors UndiciError and parses HTTP with llhttp; the World code libfx
  // bundles mentions neither.
  for (const file of archiveFiles) {
    if (!/\.(c|m)?js$/.test(file)) continue;
    const text = await readFile(join(packageDir, file), "utf8");
    assert.doesNotMatch(text, /UndiciError|llhttp/, `${file} bundles undici`);
  }

  const cjs = await readFile(join(packageDir, "node.cjs"), "utf8");
  assert.doesNotMatch(cjs, new RegExp(repoRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));

  const source = await readFile(resolve(repoRoot, "sdk/node.js"), "utf8");
  // PKG-10: every import() in either Node entry names a module only known at
  // run time, which webpack and Turbopack must leave to Node instead of
  // warning that they can't resolve it, except the imports of the addon
  // versions, which name each alias literally and without hints so bundlers
  // follow them and copy the addon (PKG-2).
  const unhinted = /\bimport\((?!\/\* webpackIgnore: true \*\/ \/\* turbopackIgnore: true \*\/)(?!"libfx-(linux|darwin)-(x64|arm64)"\))/;
  assert.doesNotMatch(source, unhinted, "node.js has an import() bundlers would try to resolve");
  assert.doesNotMatch(cjs, unhinted, "node.cjs has an import() bundlers would try to resolve");
  for (const platform of platforms) {
    for (const [name, text] of [["node.js", source], ["node.cjs", cjs]]) {
      assert.equal(text.split(`import("libfx-${platform}")`).length, 2, `${name} imports libfx-${platform} once, literally and without bundler hints`);
    }
  }
  assert.doesNotMatch(source, /["']\.\/libfx\.(linux|darwin)-(x64|arm64)\.node["']/, "node.js names no addon file of its own");

  await cp(packageDir, installedPackage, { recursive: true });
  // Where npm installs it: under the alias libfx gives it.
  await cp(nativeDir, join(consumerDir, "node_modules", nativeAlias), { recursive: true });
  await writeFile(join(consumerDir, "package.json"), '{"type":"module"}\n');
  await writeFile(join(consumerDir, "esm.mjs"), `
    import * as libfx from "libfx";
    import * as nodeEntry from "libfx/node";
    import { access } from "node:fs/promises";
    import { fileURLToPath } from "node:url";
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
    // libfx carries the terminal's WebAssembly, so its createFxTerminal()
    // needs no wasm. Without JSPI the terminal can't run, which this check
    // accepts; any other reason it couldn't load the file fails it.
    await access(fileURLToPath(new URL("./node_modules/libfx/fx-term.wasm", import.meta.url)));
    const terminalInfo = await getBackendInfo({ surface: "terminal", nativeAddon: false });
    if (terminalInfo.backend !== "wasm-jspi" && terminalInfo.attempts.at(-1).reason?.code !== "LIBFX_JSPI_UNAVAILABLE") throw new Error(JSON.stringify(terminalInfo));
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

  // With no undici of its own, vercel()'s World sends its requests over
  // node:http: these reach a server on this machine, not through fetch.
  await writeFile(join(consumerDir, "vercel-world.mjs"), `
    import { createServer } from "node:http";
    const seen = [];
    const server = createServer((request, response) => {
      request.resume();
      request.on("end", () => {
        seen.push({ method: request.method, path: request.url.split("?")[0], viaFetch: "sec-fetch-mode" in request.headers });
        response.writeHead(400, { "content-type": "application/json" });
        response.end("{}");
      });
    });
    await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
    process.env.VERCEL_WORKFLOW_SERVER_URL = "http://127.0.0.1:" + server.address().port;
    const { vercel } = await import("libfx/durable-vercel");
    const world = vercel().world();
    const runId = "wrun_" + world.createRunId({});
    const errors = [];
    for (const call of [
      () => world.events.create(runId, { eventType: "run_created", specVersion: world.specVersion, eventData: { deploymentId: "dpl_package_test", workflowName: "libfx/session", input: new Uint8Array([123, 125]) } }),
      () => world.events.list({ runId, pagination: { sortOrder: "desc", limit: 1 }, resolveData: "all" }),
      () => world.streams.getInfo(runId, "strm_package_test"),
    ]) {
      try { await call(); } catch (error) { errors.push(String(error?.message ?? error)); }
    }
    server.closeAllConnections();
    server.close();
    console.log(JSON.stringify({ runId, seen, errors }));
    process.exit(0);
  `);
  // A token that has not expired, so the World asks for no other.
  const tokenPart = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const oidcToken = `${tokenPart({ alg: "none" })}.${tokenPart({ exp: Math.floor(Date.now() / 1000) + 3600 })}.`;
  const vercelWorld = JSON.parse(run(process.execPath, ["vercel-world.mjs"], { cwd: consumerDir, env: { VERCEL_OIDC_TOKEN: oidcToken } }).stdout);
  assert.deepEqual(vercelWorld.errors.filter((error) => /undici/.test(error)), [], "nothing builds undici");
  assert.deepEqual(vercelWorld.seen.map(({ method, path }) => `${method} ${path}`), [
    `POST /api/v4/runs/${vercelWorld.runId}/events/run_created`,
    `GET /api/v4/runs/${vercelWorld.runId}/events`,
    `GET /api/v2/runs/${vercelWorld.runId}/streams/strm_package_test/info`,
  ]);
  assert.ok(vercelWorld.seen.every(({ viaFetch }) => !viaFetch), "the World's requests go over node:http");

  const esm = run(process.execPath, ["esm.mjs"], { cwd: consumerDir });
  const cjsResult = run(process.execPath, ["--no-experimental-require-module", "cjs.cjs"], { cwd: consumerDir });
  assert.deepEqual(JSON.parse(cjsResult.stdout), JSON.parse(esm.stdout));
  console.log("Node package passed: publisher prerequisites, archive validation of every package, docs packaged from a local docs site and required by the publisher, the addon as a version of libfx installed under its alias and the terminal in libfx, no bundled undici, the Vercel World over node:http, conditional exports, relocated CJS, literal platform imports, and bare imports");
} finally {
  docsServer.closeAllConnections();
  docsServer.close();
  await rm(temp, { recursive: true, force: true });
}
