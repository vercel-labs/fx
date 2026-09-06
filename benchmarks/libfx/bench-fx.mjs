#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  benchmarkInstructions,
  benchmarkInstructionsBytes,
  benchmarkPrompt,
  requestMetrics,
} from "./workload.mjs";

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const backend = option("--backend", "auto");
const samples = Number(option("--samples", "1"));
const childMode = args.includes("--child");

if (!new Set(["auto", "native", "wasm"]).has(backend)) throw new Error(`invalid backend: ${backend}`);
if (!Number.isSafeInteger(samples) || samples < 1 || samples > 1000) throw new Error(`invalid samples: ${samples}`);

if (childMode) {
  await runChild();
} else {
  await runParent();
}

async function runChild() {
  const gatewayUrl = process.env.LIBFX_BENCH_GATEWAY_URL;
  const diagnosticsPath = process.env.LIBFX_BENCH_DIAGNOSTICS;
  if (!gatewayUrl || !diagnosticsPath) throw new Error("benchmark child environment is incomplete");

  const startedAt = performance.now();
  const { createFxAgent } = await import(new URL("../../sdk/node.js", import.meta.url));
  const importedAt = performance.now();
  let fetchAt = null;
  let firstBodyAt = null;
  let firstTextAt = null;
  let nonPromptFetches = 0;
  let promptRequestMetrics = null;
  const tracedFetch = async (_url, init = {}) => {
    const isPrompt = (init.method ?? "GET") === "POST";
    if (!isPrompt) {
      nonPromptFetches += 1;
      if ((init.method ?? "GET") !== "GET" || String(_url) !== "https://ai-gateway.vercel.sh/coding-agent/v1/models") {
        throw new Error("unexpected non-prompt benchmark request");
      }
      return fetch(gatewayUrl, init);
    }
    fetchAt ??= performance.now();
    promptRequestMetrics ??= requestMetrics(init.body);
    const response = await fetch(gatewayUrl, init);
    if (!response.body) return response;
    const reader = response.body.getReader();
    const body = new ReadableStream({
      async pull(controller) {
        const result = await reader.read();
        if (result.done) {
          controller.close();
          return;
        }
        firstBodyAt ??= performance.now();
        controller.enqueue(result.value);
      },
      cancel(reason) {
        return reader.cancel(reason);
      },
    });
    return new Response(body, {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
    });
  };

  const agent = await createFxAgent({
    backend,
    nativeAddon: resolve(repoRoot, "zig-out/lib/libfx.node"),
    wasm: resolve(repoRoot, "zig-out/bin/fx-core.wasm"),
    fetch: tracedFetch,
    home: repoRoot,
    workspaceRoot: repoRoot,
    apiKey: "libfx-benchmark-key",
    gatewayChatUrl: gatewayUrl,
    model: "benchmark/model",
    instructions: benchmarkInstructions,
  });
  const agentReadyAt = performance.now();
  const promptAt = performance.now();
  const turn = agent.prompt(benchmarkPrompt);
  let text = "";
  for await (const update of turn) {
    if (update.type !== "text_delta") continue;
    const chunk = update.delta;
    firstTextAt ??= performance.now();
    text += chunk;
    process.stdout.write(chunk);
  }
  const result = await turn.result;
  await agent.close();
  const exitCode = 0;
  const finishedAt = performance.now();
  await writeFile(diagnosticsPath, JSON.stringify({
    backend,
    startedAt,
    importedAt,
    agentReadyAt,
    promptAt,
    fetchAt,
    firstBodyAt,
    firstTextAt,
    finishedAt,
    nonPromptFetches,
    ...promptRequestMetrics,
    stopReason: result.stopReason,
    exitCode,
    text,
  }));
}

async function runParent() {
  const encoded = new TextEncoder();
  const server = createServer((request, response) => {
    request.resume();
    request.on("end", () => {
      if (request.method === "GET") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ object: "list", data: [{ id: "benchmark/model", type: "language", released: 1, tags: ["tool-use"] }] }));
        return;
      }
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.write(encoded.encode('data: {"type":"text-delta","id":"bench","delta":"hello"}\n\n'));
      response.write(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n'));
      response.end(encoded.encode("data: [DONE]\n\n"));
    });
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  const { port } = server.address();
  const gatewayUrl = `http://127.0.0.1:${port}/chat`;
  const runDir = await mkdtemp(join(tmpdir(), "libfx-benchmark-"));
  const measured = [];
  try {
    for (let index = 0; index < samples; index++) {
      const diagnosticsPath = join(runDir, `sample-${index}.json`);
      measured.push(await runSample(gatewayUrl, diagnosticsPath));
    }
  } finally {
    server.closeAllConnections();
    await new Promise((resolveClose) => server.close(resolveClose));
    await rm(runDir, { recursive: true, force: true });
  }
  const report = {
    format_version: 1,
    runtime: process.versions.bun ? "bun" : "node",
    runtime_version: process.versions.bun ?? process.version,
    backend,
    samples: measured,
  };
  process.stdout.write(`${JSON.stringify(report, null, args.includes("--json") ? 2 : 0)}\n`);
}

async function runSample(gatewayUrl, diagnosticsPath) {
  const childArgs = [];
  if (!process.versions.bun && backend === "wasm") childArgs.push("--experimental-wasm-jspi");
  childArgs.push(scriptPath, "--child", "--backend", backend);
  const spawnedAt = performance.now();
  const child = spawn(process.execPath, childArgs, {
    cwd: repoRoot,
    env: {
      ...process.env,
      LIBFX_BENCH_GATEWAY_URL: gatewayUrl,
      LIBFX_BENCH_DIAGNOSTICS: diagnosticsPath,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let firstStdoutAt = null;
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    firstStdoutAt ??= performance.now();
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const exitCode = await new Promise((resolveExit, reject) => {
    child.once("error", reject);
    child.once("exit", (code) => resolveExit(code));
  });
  const exitedAt = performance.now();
  if (exitCode !== 0) throw new Error(`benchmark child exited ${exitCode}: ${stderr}`);
  const diagnostics = JSON.parse(await readFile(diagnosticsPath, "utf8"));
  for (const field of ["fetchAt", "firstBodyAt", "firstTextAt"]) {
    if (diagnostics[field] === null) throw new Error(`benchmark child omitted ${field}`);
  }
  if (diagnostics.stopReason !== "end_turn" || diagnostics.text !== "hello" || stdout !== "hello") {
    throw new Error(`benchmark child did not complete the expected response: stdout=${JSON.stringify(stdout)} diagnostics=${JSON.stringify(diagnostics)}`);
  }
  return {
    text: stdout,
    spawn_to_first_stdout_ms: firstStdoutAt - spawnedAt,
    prompt_to_fetch_ms: diagnostics.fetchAt - diagnostics.promptAt,
    first_body_to_first_text_ms: diagnostics.firstTextAt - diagnostics.firstBodyAt,
    total_ms: exitedAt - spawnedAt,
    import_ms: diagnostics.importedAt - diagnostics.startedAt,
    create_agent_ms: diagnostics.agentReadyAt - diagnostics.importedAt,
    non_prompt_fetches: diagnostics.nonPromptFetches,
    request_bytes: diagnostics.request_bytes,
    system_context_bytes: diagnostics.system_context_bytes,
    system_context_overhead_bytes: diagnostics.system_context_bytes - benchmarkInstructionsBytes,
  };
}
