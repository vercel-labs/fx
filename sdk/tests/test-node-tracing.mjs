#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, rename, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve, sep } from "node:path";
import { serializeError } from "./package-report.mjs";

const packageDir = resolve(process.argv[2]);
const { nodeFileTrace } = createRequire(import.meta.url)(resolve(process.argv[3]));
const artifactRoot = process.env.LIBFX_TEST_ARTIFACT_ROOT || tmpdir();
await mkdir(artifactRoot, { recursive: true });
const root = await mkdtemp(join(artifactRoot, "libfx-trace-"));
const results = [];
let failure;

async function exercise(sdk) {
  const { strict: assert } = await import("node:assert");
  const { createServer } = await import("node:http");
  const { mkdir } = await import("node:fs/promises");
  const { resolve } = await import("node:path");
  const home = resolve("profile");
  await mkdir(home, { recursive: true });
  let modelCalls = 0;
  const server = createServer((request, response) => {
    request.resume();
    request.on("end", () => {
      if (request.method === "GET") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end('{"object":"list","data":[]}');
      } else {
        modelCalls++;
        response.writeHead(200, { "content-type": "text/event-stream" });
        response.end('data: {"type":"text-delta","delta":"traced"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\ndata: [DONE]\n\n');
      }
    });
  });
  await new Promise((listen) => server.listen(0, "127.0.0.1", listen));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const results = [];
  try {
    const info = await sdk.getBackendInfo({ backend: "native" });
    assert.equal(info.backend, "native", JSON.stringify(info));
    for (const backend of ["native", "auto"]) {
      const agent = await sdk.createFxAgent({
        backend, home, workspaceRoot: process.cwd(), apiKey: "trace-key", model: "trace/model",
        gatewayChatUrl: `${origin}/chat`,
        fetch(input, init) {
          const url = init?.method === "GET" ? `${origin}/models` : String(input);
          assert.equal(new URL(url).origin, origin);
          return fetch(url, init);
        },
      });
      try {
        const turn = agent.prompt("hello");
        let text = "";
        for await (const event of turn) if (event.type === "text_delta") text += event.delta;
        assert.equal(text, "traced");
        assert.equal((await turn.result).stopReason, "end_turn");
        const checkpointBytes = (await agent.checkpoint()).length;
        assert.ok(checkpointBytes > 48);
        results.push({ backend, checkpointBytes });
      } finally { await agent.close(); }
    }
    assert.equal(modelCalls, 2);
    console.log(JSON.stringify({ info, results }));
  } finally {
    server.closeAllConnections();
    await new Promise((close) => server.close(close));
  }
}

async function run(entry, cwd, name) {
  const child = spawnSync(process.execPath, ["--no-experimental-require-module", entry], {
    cwd, encoding: "utf8", timeout: 30_000,
    env: { PATH: process.env.PATH, NODE_PATH: "", NODE_OPTIONS: "", FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1" },
  });
  await writeFile(join(root, `${name}.log`), `${child.stdout || ""}\n${child.stderr || ""}`);
  if (child.error) throw child.error;
  assert.equal(child.status, 0, `${name} failed; see ${root}/${name}.log`);
  return JSON.parse(child.stdout.trim());
}

try {
  for (const format of ["esm", "cjs"]) {
    const source = join(root, `${format}-source`);
    const isolated = join(root, `${format}-isolated`);
    const entry = format === "esm" ? "entry.mjs" : "entry.cjs";
    await cp(packageDir, join(source, "node_modules/libfx"), { recursive: true });
    const load = format === "esm" ? 'import * as sdk from "libfx";' : 'const sdk = require("libfx");';
    await writeFile(join(source, entry), `${load}\n(${exercise.toString()})(sdk).catch(error => { console.error(error); process.exitCode = 1; });\n`);
    const result = { format, control: await run(entry, source, `${format}-control`) };
    results.push(result);
    const trace = await nodeFileTrace([join(source, entry)], { base: source, processCwd: source });
    result.files = [...trace.fileList].sort();
    result.warnings = [...trace.warnings].map(String);
    if (format === "cjs") assert.ok(!result.files.includes("node_modules/libfx/node.js"), "CJS tracing must not be rescued by an ESM import");
    for (const file of result.files) {
      const from = resolve(source, file);
      const to = resolve(isolated, file);
      assert.ok(from.startsWith(source + sep) && to.startsWith(isolated + sep), `trace escaped its fixture: ${file}`);
      await mkdir(dirname(to), { recursive: true });
      await cp(from, to);
    }
    await rename(source, `${source}-unavailable`);
    result.isolated = await run(entry, isolated, `${format}-isolated`);
    assert.ok(result.files.some((file) => file.endsWith(`/libfx.${process.platform}-${process.arch}.node`)));
    console.log(`${format} traced native and auto agent turns passed`);
  }
} catch (error) { failure = error; }
finally {
  await writeFile(join(root, "results.json"), JSON.stringify({
    node: process.version, packageDir, status: failure ? "failed" : "passed", results, error: serializeError(failure),
  }, null, 2));
  console.log(`Node tracing evidence: ${root}`);
}
if (failure) throw failure;
