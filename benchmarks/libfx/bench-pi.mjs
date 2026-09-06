#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
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
const samples = Number(option("--samples", "1"));
const childMode = args.includes("--child");

if (!Number.isSafeInteger(samples) || samples < 1 || samples > 1000) throw new Error(`invalid samples: ${samples}`);
if (childMode) await runChild();
else await runParent();

function piEntry() {
  const root = process.env.LIBFX_BENCH_PI_ROOT;
  if (!root) throw new Error("Install @earendil-works/pi-coding-agent and set LIBFX_BENCH_PI_ROOT to its npm prefix");
  return pathToFileURL(resolve(root, "node_modules/@earendil-works/pi-coding-agent/dist/index.js")).href;
}

async function runChild() {
  const gatewayOrigin = process.env.LIBFX_BENCH_GATEWAY_ORIGIN;
  const diagnosticsPath = process.env.LIBFX_BENCH_DIAGNOSTICS;
  if (!gatewayOrigin || !diagnosticsPath) throw new Error("benchmark child environment is incomplete");

  const startedAt = performance.now();
  const {
    createAgentSession,
    DefaultResourceLoader,
    SessionManager,
  } = await import(piEntry());
  const importedAt = performance.now();
  const nativeFetch = globalThis.fetch;
  let fetchAt = null;
  let firstBodyAt = null;
  let firstTextAt = null;
  let nonPromptFetches = 0;
  let promptRequestMetrics = null;
  globalThis.fetch = async (url, init = {}) => {
    const isPrompt = (init.method ?? "GET") === "POST";
    if (isPrompt) {
      fetchAt ??= performance.now();
      promptRequestMetrics ??= requestMetrics(init.body);
    } else {
      nonPromptFetches += 1;
    }
    const response = await nativeFetch(url, init);
    if (!isPrompt || !response.body) return response;
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

  const model = {
    id: "benchmark/model",
    name: "Benchmark Model",
    api: "openai-completions",
    provider: "openai",
    baseUrl: `${gatewayOrigin}/v1`,
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128_000,
    maxTokens: 4096,
  };
  const resourceLoader = new DefaultResourceLoader({
    cwd: repoRoot,
    agentDir: `${diagnosticsPath}.agent`,
    systemPrompt: benchmarkInstructions,
    appendSystemPrompt: [],
    noExtensions: true,
    noSkills: true,
    noPromptTemplates: true,
    noThemes: true,
    noContextFiles: true,
  });
  await resourceLoader.reload();
  const { session } = await createAgentSession({
    cwd: repoRoot,
    model,
    resourceLoader,
    noTools: "all",
    sessionManager: SessionManager.inMemory(),
  });
  const agentReadyAt = performance.now();
  let text = "";
  const observedEvents = [];
  const unsubscribe = session.subscribe((event) => {
    if (observedEvents.length < 32) {
      observedEvents.push({
        type: event.type,
        messageType: event.assistantMessageEvent?.type,
        stopReason: event.message?.stopReason,
        errorMessage: event.message?.errorMessage,
      });
    }
    if (event.type !== "message_update" || event.assistantMessageEvent.type !== "text_delta") return;
    firstTextAt ??= performance.now();
    text += event.assistantMessageEvent.delta;
    process.stdout.write(event.assistantMessageEvent.delta);
  });
  const promptAt = performance.now();
  await session.prompt(benchmarkPrompt);
  unsubscribe();
  session.dispose();
  const finishedAt = performance.now();
  globalThis.fetch = nativeFetch;
  await writeFile(diagnosticsPath, JSON.stringify({
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
    text,
    observedEvents,
  }));
}

async function runParent() {
  const server = createServer((request, response) => {
    request.resume();
    request.on("end", () => {
      response.writeHead(200, { "content-type": "text/event-stream" });
      const item = { type: "message", id: "msg_bench", role: "assistant", status: "completed", phase: "final_answer", content: [{ type: "output_text", text: "hello", annotations: [] }] };
      response.write(`data: ${JSON.stringify({ type: "response.created", response: { id: "resp_bench", status: "in_progress", output: [] } })}\n\n`);
      response.write(`data: ${JSON.stringify({ type: "response.output_item.added", output_index: 0, item: { ...item, status: "in_progress", content: [] } })}\n\n`);
      response.write(`data: ${JSON.stringify({ type: "response.output_text.delta", output_index: 0, content_index: 0, delta: "hello", item_id: item.id })}\n\n`);
      response.write(`data: ${JSON.stringify({ type: "response.output_item.done", output_index: 0, item })}\n\n`);
      response.write(`data: ${JSON.stringify({ type: "response.completed", response: { id: "resp_bench", status: "completed", output: [item], usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } } })}\n\n`);
      response.end("data: [DONE]\n\n");
    });
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  const { port } = server.address();
  const gatewayOrigin = `http://127.0.0.1:${port}`;
  const runDir = await mkdtemp(join(tmpdir(), "pi-benchmark-"));
  const measured = [];
  try {
    for (let index = 0; index < samples; index++) {
      measured.push(await runSample(gatewayOrigin, join(runDir, `sample-${index}.json`)));
    }
  } finally {
    server.closeAllConnections();
    await new Promise((resolveClose) => server.close(resolveClose));
    await rm(runDir, { recursive: true, force: true });
  }
  process.stdout.write(`${JSON.stringify({
    format_version: 1,
    target: "pi",
    runtime: process.versions.bun ? "bun" : "node",
    runtime_version: process.versions.bun ?? process.version,
    package_version: "0.84.4",
    samples: measured,
  }, null, args.includes("--json") ? 2 : 0)}\n`);
}

async function runSample(gatewayOrigin, diagnosticsPath) {
  const spawnedAt = performance.now();
  const child = spawn(process.execPath, [scriptPath, "--child"], {
    cwd: repoRoot,
    env: {
      ...process.env,
      OPENAI_API_KEY: "pi-benchmark-key",
      LIBFX_BENCH_GATEWAY_ORIGIN: gatewayOrigin,
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
  if (exitCode !== 0) throw new Error(`pi benchmark child exited ${exitCode}: ${stderr}`);
  const diagnostics = JSON.parse(await readFile(diagnosticsPath, "utf8"));
  for (const field of ["fetchAt", "firstBodyAt", "firstTextAt"]) {
    if (diagnostics[field] === null) {
      throw new Error(`pi benchmark child omitted ${field}; stdout=${JSON.stringify(stdout)} stderr=${JSON.stringify(stderr)} diagnostics=${JSON.stringify(diagnostics)}`);
    }
  }
  if (diagnostics.text !== "hello" || stdout !== "hello") {
    throw new Error(`pi benchmark child did not produce the expected response: stdout=${JSON.stringify(stdout)} diagnostics=${JSON.stringify(diagnostics)}`);
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
