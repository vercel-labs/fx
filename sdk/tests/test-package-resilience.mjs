#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const captureLimit = 8 * 1024 * 1024;

function parseArgs(argv) {
  const options = {
    packageInput: null,
    cheapCycles: 1000,
    toolWorkflows: 100,
    durationMs: 180_000,
    concurrency: 4,
    stageTimeoutMs: 900_000,
    faultTimeoutMs: 45_000,
    jsonOut: null,
    npmBin: process.env.LIBFX_TEST_NPM_BIN ?? "npm",
    keepTemp: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--keep-temp") {
      options.keepTemp = true;
      continue;
    }
    const key = argument.startsWith("--") ? argument.slice(2) : null;
    if (!key) {
      if (options.packageInput) throw new Error(`unexpected argument: ${argument}`);
      options.packageInput = argument;
      continue;
    }
    const value = argv[++index];
    if (value === undefined) throw new Error(`missing value for ${argument}`);
    if (key === "package") options.packageInput = value;
    else if (key === "cheap-cycles") options.cheapCycles = Number(value);
    else if (key === "tool-workflows") options.toolWorkflows = Number(value);
    else if (key === "duration-ms") options.durationMs = Number(value);
    else if (key === "concurrency") options.concurrency = Number(value);
    else if (key === "stage-timeout-ms") options.stageTimeoutMs = Number(value);
    else if (key === "fault-timeout-ms") options.faultTimeoutMs = Number(value);
    else if (key === "json-out") options.jsonOut = value;
    else if (key === "npm-bin") options.npmBin = value;
    else throw new Error(`unknown option: ${argument}`);
  }
  if (!options.packageInput) {
    throw new Error("usage: test-package-resilience.mjs --package <staged-directory-or-tarball> [options]");
  }
  for (const key of ["cheapCycles", "toolWorkflows", "durationMs", "concurrency", "stageTimeoutMs", "faultTimeoutMs"]) {
    if (!Number.isInteger(options[key]) || options[key] <= 0) throw new Error(`${key} must be a positive integer`);
  }
  if (options.concurrency > 16) throw new Error("concurrency must be at most 16");
  options.packageInput = resolve(options.packageInput);
  if (options.jsonOut) options.jsonOut = resolve(options.jsonOut);
  return options;
}

function isInside(parent, candidate) {
  const path = relative(resolve(parent), resolve(candidate));
  return path === "" || (!path.startsWith(`..${sep}`) && path !== "..");
}

async function sha256File(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

async function packageIdentity(packageDir, input, inputType) {
  const manifestPath = join(packageDir, "package.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const inventory = [];
  async function visit(directory, prefix = "") {
    for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const relativePath = join(prefix, entry.name);
      if (entry.isDirectory()) await visit(join(directory, entry.name), relativePath);
      else if (entry.isFile()) inventory.push([relativePath, await sha256File(join(directory, entry.name))]);
    }
  }
  await visit(packageDir);
  const digest = createHash("sha256");
  for (const [path, hash] of inventory) digest.update(`${path}\0${hash}\n`);
  return {
    input,
    inputType,
    name: manifest.name,
    version: manifest.version,
    packageDigestSha256: digest.digest("hex"),
    fileCount: inventory.length,
  };
}

async function installPackage(input, consumerDir, npmBin) {
  const inputStat = await stat(input);
  await mkdir(join(consumerDir, "node_modules"), { recursive: true });
  await writeFile(join(consumerDir, "package.json"), '{"name":"libfx-resilience-consumer","private":true,"type":"module"}\n');
  if (inputStat.isDirectory()) {
    await cp(input, join(consumerDir, "node_modules", "libfx"), { recursive: true });
    return "staged-directory-copy";
  }
  const npmArgs = ["install", "--ignore-scripts", "--no-audit", "--no-fund", "--no-package-lock", input];
  const npmIsJavaScript = npmBin.endsWith(".js") || npmBin.endsWith(".cjs");
  await runProcess({
    label: "tarball installation",
    command: npmIsJavaScript ? process.execPath : npmBin,
    args: npmIsJavaScript ? [npmBin, ...npmArgs] : npmArgs,
    cwd: consumerDir,
    timeoutMs: 180_000,
    expectedStatus: 0,
    env: { NPM_CONFIG_USERCONFIG: "/dev/null" },
  });
  return "npm-tarball-install";
}

function cleanEnvironment() {
  const env = { ...process.env };
  for (const name of [
    "AI_GATEWAY_API_KEY",
    "VERCEL_OIDC_TOKEN",
    "NPM_TOKEN",
    "NODE_AUTH_TOKEN",
    "GITHUB_TOKEN",
    "GH_TOKEN",
  ]) delete env[name];
  return env;
}

async function runProcess({ label, command, args, cwd, timeoutMs, expectedStatus, relayStderr = false, env = {} }) {
  return await new Promise((resolveRun, rejectRun) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...cleanEnvironment(), ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let overflow = false;
    const append = (current, chunk) => {
      if (current.length >= captureLimit) {
        overflow = true;
        return current;
      }
      return (current + chunk).slice(0, captureLimit);
    };
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout = append(stdout, chunk); });
    child.stderr.on("data", (chunk) => {
      stderr = append(stderr, chunk);
      if (relayStderr) process.stderr.write(chunk);
    });
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.on("error", (error) => {
      clearTimeout(timer);
      rejectRun(error);
    });
    child.on("close", (status, signal) => {
      clearTimeout(timer);
      const result = { label, command, args, cwd, status, signal, stdout, stderr, captureOverflow: overflow };
      if (status !== expectedStatus) {
        const error = new Error(`${label} exited ${status ?? signal}; stdout=${stdout.slice(-4000)} stderr=${stderr.slice(-4000)}`);
        error.result = result;
        rejectRun(error);
        return;
      }
      resolveRun(result);
    });
  });
}

function lastJsonLine(stdout) {
  const lines = stdout.trim().split("\n").filter(Boolean);
  if (lines.length === 0) throw new Error("worker produced no structured result");
  return JSON.parse(lines.at(-1));
}

async function installedWorkerMain() {
  const { strict: assert } = await import("node:assert");
  const { createRequire } = await import("node:module");
  const { createServer } = await import("node:http");
  const { readdir, readFile, writeFile } = await import("node:fs/promises");
  const { performance } = await import("node:perf_hooks");
  const config = JSON.parse(process.argv[2]);

  const errorRecord = (error) => ({
    name: error?.name ?? typeof error,
    code: error?.code ?? null,
    message: error?.message ?? String(error),
    cause: error?.cause ? {
      name: error.cause.name ?? typeof error.cause,
      code: error.cause.code ?? null,
      message: error.cause.message ?? String(error.cause),
    } : null,
  });
  const expectedError = async (action) => {
    try {
      await action();
    } catch (error) {
      return error;
    }
    assert.fail("expected operation to fail");
  };
  const quantile = (values, fraction) => {
    const sorted = [...values].sort((a, b) => a - b);
    if (sorted.length === 0) return null;
    return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
  };
  const stats = (values) => ({
    samples: values.length,
    p50Ms: quantile(values, 0.5),
    p95Ms: quantile(values, 0.95),
    p99Ms: values.length >= 100 ? quantile(values, 0.99) : null,
    maxMs: values.length ? Math.max(...values) : null,
    rawMs: values,
  });
  const slopePerMinute = (values, key) => {
    if (values.length < 2) return null;
    const origin = values[0].timestampMs;
    const points = values.map((value) => ({ x: (value.timestampMs - origin) / 60_000, y: value[key] }));
    const meanX = points.reduce((sum, point) => sum + point.x, 0) / points.length;
    const meanY = points.reduce((sum, point) => sum + point.y, 0) / points.length;
    const denominator = points.reduce((sum, point) => sum + ((point.x - meanX) ** 2), 0);
    if (denominator === 0) return null;
    return points.reduce((sum, point) => sum + (point.x - meanX) * (point.y - meanY), 0) / denominator;
  };
  const activeResources = () => {
    const counts = {};
    for (const name of process.getActiveResourcesInfo()) counts[name] = (counts[name] ?? 0) + 1;
    return counts;
  };
  const fdCount = async () => {
    try { return (await readdir("/dev/fd")).length; } catch { return null; }
  };
  const memorySnapshot = async (label) => ({
    label,
    timestampMs: Date.now(),
    ...process.memoryUsage(),
    fdCount: await fdCount(),
    activeResources: activeResources(),
  });
  const delay = (milliseconds) => new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
  const withTimeout = async (promise, milliseconds, label) => {
    let timer;
    try {
      return await Promise.race([
        promise,
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error(`${label} timed out after ${milliseconds}ms`)), milliseconds);
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  };

  const esm = await import("libfx");
  const cjs = createRequire(import.meta.url)("libfx");
  const exportNames = Object.keys(esm).sort();
  assert.deepEqual(Object.keys(cjs).sort(), exportNames, "ESM and CJS exports differ");

  if (config.mode === "cjs-happy") {
    assert.equal(typeof cjs.createFxAgent, "function");
    const info = await cjs.getBackendInfo({ backend: "native" });
    assert.equal(info.backend, "native");
    console.log(JSON.stringify({ mode: config.mode, exportNames, info }));
    return;
  }

  if (config.mode === "fault-missing-addon" || config.mode === "fault-corrupt-addon") {
    const info = await esm.getBackendInfo({ backend: "native" });
    assert.equal(info.backend, "unavailable");
    const reason = info.attempts[0].reason;
    assert.equal(reason.code, config.mode === "fault-missing-addon"
      ? "LIBFX_NATIVE_ARTIFACT_MISSING"
      : "LIBFX_NATIVE_LOAD_FAILED");
    if (config.mode === "fault-missing-addon") assert.equal(reason.causeCode, "ENOENT");
    else assert.equal(reason.causeCode, "ERR_DLOPEN_FAILED");
    const factoryError = await expectedError(() => esm.createFxAgent({ backend: "native", apiKey: "test-placeholder" }));
    assert.ok(factoryError.code, "factory error must preserve a code");
    console.log(JSON.stringify({ mode: config.mode, info, factoryError: errorRecord(factoryError) }));
    return;
  }

  if (config.mode === "fault-no-jspi") {
    Object.defineProperty(WebAssembly, "Suspending", { configurable: true, value: undefined });
    Object.defineProperty(WebAssembly, "promising", { configurable: true, value: undefined });
    const forcedWasm = await esm.getBackendInfo({ backend: "wasm" });
    assert.equal(forcedWasm.backend, "unavailable");
    assert.equal(forcedWasm.attempts[0].reason.code, "LIBFX_JSPI_UNAVAILABLE");
    const factoryError = await expectedError(() => esm.createFxAgent({ backend: "wasm", apiKey: "test-placeholder" }));
    assert.equal(factoryError.code, "LIBFX_JSPI_REQUIRED");
    const automatic = await esm.getBackendInfo({ backend: "auto" });
    assert.equal(automatic.backend, "native");
    console.log(JSON.stringify({ mode: config.mode, forcedWasm, automatic, factoryError: errorRecord(factoryError) }));
    return;
  }

  if (config.mode === "fault-bad-api") {
    const badAddon = { libfxApiVersion: 2, createCore() { assert.fail("bad API factory must not be called"); } };
    const info = await esm.getBackendInfo({ backend: "native", nativeAddon: badAddon });
    assert.equal(info.backend, "unavailable");
    assert.equal(info.attempts[0].reason.code, "LIBFX_NATIVE_API_MISMATCH");
    const factoryError = await expectedError(() => esm.createFxAgent({
      backend: "native",
      nativeAddon: badAddon,
      apiKey: "test-placeholder",
    }));
    assert.equal(factoryError.code, "LIBFX_NATIVE_UNAVAILABLE");
    assert.match(factoryError.message, /expected API version 3/);
    console.log(JSON.stringify({ mode: config.mode, info, factoryError: errorRecord(factoryError) }));
    return;
  }

  if (config.mode === "fault-invalid-input") {
    const invalidProbe = await expectedError(() => esm.getBackendInfo(null));
    assert.ok(invalidProbe instanceof TypeError);
    assert.equal(invalidProbe.message, "getBackendInfo() options must be an object");
    const invalidBackend = await expectedError(() => esm.createFxAgent({ backend: "other", apiKey: "test-placeholder" }));
    assert.ok(invalidBackend instanceof TypeError);
    assert.equal(invalidBackend.message, 'backend must be "auto", "native", or "wasm"');
    const invalidCheckpoint = await expectedError(() => esm.createFxAgent({
      backend: "native",
      apiKey: "test-placeholder",
      checkpoint: new Uint8Array([1, 2, 3]),
    }));
    assert.match(invalidCheckpoint.message, /Invalid or non-fresh libfx checkpoint/);
    const recovery = await esm.createFxAgent({ backend: "native", apiKey: "test-placeholder" });
    const checkpoint = await recovery.checkpoint();
    await recovery.close();
    assert.ok(checkpoint.length > 48);
    console.log(JSON.stringify({
      mode: config.mode,
      invalidProbe: errorRecord(invalidProbe),
      invalidBackend: errorRecord(invalidBackend),
      invalidCheckpoint: errorRecord(invalidCheckpoint),
      recoveryCheckpointBytes: checkpoint.length,
    }));
    return;
  }

  if (config.mode === "fault-missing-wasm" || config.mode === "fault-corrupt-wasm") {
    const first = await esm.getBackendInfo({ backend: "wasm" });
    assert.equal(first.backend, "unavailable");
    assert.equal(first.attempts[0].reason.code, "LIBFX_WASM_LOAD_FAILED");
    if (config.mode === "fault-missing-wasm") assert.equal(first.attempts[0].reason.causeCode, "ENOENT");
    const factoryError = await expectedError(() => esm.createFxAgent({ backend: "wasm", apiKey: "test-placeholder" }));
    await writeFile(config.wasmPath, await readFile(config.restoreWasmPath));
    const second = await esm.getBackendInfo({ backend: "wasm" });
    assert.equal(second.backend, "wasm-jspi");
    const recovery = await esm.createFxAgent({ backend: "wasm", apiKey: "test-placeholder" });
    const checkpoint = await recovery.checkpoint();
    await recovery.close();
    assert.ok(checkpoint.length > 48);
    console.log(JSON.stringify({
      mode: config.mode,
      first,
      factoryError: errorRecord(factoryError),
      second,
      recoveryCheckpointBytes: checkpoint.length,
    }));
    return;
  }

  assert.equal(config.mode, "workload");
  assert.ok(config.cheapCycles >= 1 && config.toolWorkflows >= 1 && config.durationMs >= 1);
  const baselineNative = await esm.getBackendInfo({ backend: "native" });
  const baselineAuto = await esm.getBackendInfo({ backend: "auto" });
  assert.equal(baselineNative.backend, "native");
  assert.equal(baselineAuto.backend, "native");

  const provider = {
    fetchCalls: 0,
    getRequests: 0,
    requests: 0,
    toolFirstSteps: 0,
    toolResultSteps: 0,
    failures: [],
    markerModes: new Map(),
    markerRequestCounts: new Map(),
    uniqueMarkers: 0,
    lateResultSeen: false,
  };
  const markerPattern = /marker_[a-z0-9_]+/g;
  const sendSse = (response, records) => {
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end([...records.map((record) => `data: ${JSON.stringify(record)}`), "data: [DONE]", ""].join("\n\n"));
  };
  const server = createServer((request, response) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 2 * 1024 * 1024) request.destroy(new Error("provider request exceeded 2 MiB"));
    });
    request.on("end", () => {
      try {
        if (request.method === "GET") {
          provider.getRequests += 1;
          response.writeHead(200, { "content-type": "application/json" });
          response.end(JSON.stringify({ object: "list", data: [{ id: "resilience/model", type: "language" }] }));
          return;
        }
        provider.requests += 1;
        const markers = [...new Set(body.match(markerPattern) ?? [])];
        assert.equal(markers.length, 1, `provider request mixed agent markers: ${JSON.stringify(markers)}`);
        const marker = markers[0];
        const mode = provider.markerModes.get(marker);
        assert.ok(mode, `unknown marker ${marker}`);
        if (body.includes("late-result:")) provider.lateResultSeen = true;
        const seen = provider.markerRequestCounts.get(marker) ?? 0;
        provider.markerRequestCounts.set(marker, seen + 1);
        if (body.includes(`AFTER_LATE ${marker}`)) {
          assert.doesNotMatch(body, /late-result:/);
          sendSse(response, [
            { type: "text-delta", delta: `after-late:${marker}` },
            { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
          ]);
          return;
        }
        if (body.includes(`RECOVER ${marker}`)) {
          assert.doesNotMatch(body, /late-result:/);
          sendSse(response, [
            { type: "text-delta", delta: `recovered:${marker}` },
            { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
          ]);
          return;
        }
        if (body.includes(`RESTORE ${marker}`)) {
          assert.ok(body.includes(`value:${marker}`), "restored request omitted the prior tool result");
          sendSse(response, [
            { type: "text-delta", delta: `restored:${marker}` },
            { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
          ]);
          return;
        }
        if (seen === 0) {
          const payload = JSON.parse(body);
          const expectedToolName = mode === "cancel" ? "wait" : "lookup";
          const advertised = payload.tools?.find((tool) => tool.name === expectedToolName);
          assert.ok(advertised, `${expectedToolName} was not advertised to the provider`);
          assert.equal(advertised.inputSchema?.type, "object");
          assert.equal(advertised.inputSchema?.additionalProperties, false);
          if (expectedToolName === "lookup") {
            assert.equal(advertised.inputSchema.properties?.key?.type, "string");
            assert.deepEqual(advertised.inputSchema.required, ["key"]);
          }
          provider.toolFirstSteps += 1;
          sendSse(response, [
            { type: "tool-call", toolCallId: `call_${marker}`, toolName: mode === "cancel" ? "wait" : "lookup", input: { key: marker } },
            { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
          ]);
          return;
        }
        if (mode === "success" || mode === "restore") {
          assert.ok(body.includes(`value:${marker}`), `tool result did not reach inference for ${marker}`);
        } else if (mode === "reject") {
          assert.ok(body.includes(`rejected:${marker}`), `tool rejection did not reach inference for ${marker}`);
        } else {
          assert.fail(`unexpected second inference request for ${mode}`);
        }
        provider.toolResultSteps += 1;
        sendSse(response, [
          { type: "text-delta", delta: `done:${marker}` },
          { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
        ]);
      } catch (error) {
        provider.failures.push(errorRecord(error));
        response.writeHead(500, { "content-type": "text/plain" });
        response.end("provider assertion failed");
      }
    });
  });
  await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
  const gatewayChatUrl = `http://127.0.0.1:${server.address().port}/chat`;
  const providerOrigin = new URL(gatewayChatUrl).origin;
  const localFetch = (input, init = {}) => {
    const rawUrl = input instanceof Request ? input.url : input;
    const url = init.method === "GET" ? `${providerOrigin}/models` : rawUrl;
    assert.equal(new URL(url).origin, providerOrigin, `kernel attempted fetch outside the fake provider: ${url}`);
    provider.fetchCalls += 1;
    return fetch(url, init);
  };
  let markerCounter = 0;
  const nextMarker = (label) => `marker_${label}_${String(markerCounter++).padStart(8, "0")}`;
  const baseOptions = (backend, tools, checkpoint) => ({
    backend,
    apiKey: "test-placeholder",
    model: "resilience/model",
    gatewayChatUrl,
    fetch: localFetch,
    home: process.cwd(),
    workspaceRoot: process.cwd(),
    tools,
    ...(checkpoint ? { checkpoint } : {}),
  });
  const lookupTool = (marker, mode, state) => ({
    name: "lookup",
    description: "Return a deterministic value for one marker.",
    inputSchema: {
      type: "object",
      properties: { key: { type: "string" } },
      required: ["key"],
      additionalProperties: false,
    },
    async execute(input, { signal }) {
      state.callbacks += 1;
      assert.equal(signal.aborted, false);
      assert.equal(input.key, marker);
      if (mode === "reject") throw new Error(`rejected:${marker}`);
      return `value:${marker}`;
    },
  });
  const consumeTurn = async (turn) => {
    let text = "";
    const events = [];
    for await (const event of turn) {
      events.push(event);
      if (event.type === "text_delta") text += event.delta;
    }
    return { text, events, result: await turn.result };
  };
  const runToolWorkflow = async ({ mode = "success", backend = "native", label = "tool" } = {}) => {
    const marker = nextMarker(label);
    provider.markerModes.set(marker, mode);
    provider.uniqueMarkers += 1;
    const state = { callbacks: 0 };
    const started = performance.now();
    let agent;
    try {
      agent = await esm.createFxAgent(baseOptions(backend, [lookupTool(marker, mode, state)]));
      const observed = await withTimeout(consumeTurn(agent.prompt(`CALL ${marker}`)), 10_000, `tool workflow ${marker}`);
      assert.equal(observed.result.stopReason, "end_turn");
      assert.equal(observed.text, `done:${marker}`);
      assert.equal(state.callbacks, 1);
      assert.equal(observed.events.filter((event) => event.type === "tool_start").length, 1);
      assert.equal(observed.events.filter((event) => event.type === "tool_end").length, 1);
      const toolEnd = observed.events.find((event) => event.type === "tool_end");
      assert.equal(Boolean(toolEnd.isError), mode === "reject");
      const result = { marker, latencyMs: performance.now() - started };
      await agent.close();
      agent = null;
      return result;
    } finally {
      await agent?.close().catch(() => {});
      provider.markerModes.delete(marker);
      provider.markerRequestCounts.delete(marker);
    }
  };
  const runRestoreWorkflow = async () => {
    const marker = nextMarker("restore");
    provider.markerModes.set(marker, "restore");
    provider.uniqueMarkers += 1;
    const state = { callbacks: 0 };
    const tools = [lookupTool(marker, "restore", state)];
    const started = performance.now();
    let source;
    let restored;
    try {
      source = await esm.createFxAgent(baseOptions("native", tools));
      const first = await consumeTurn(source.prompt(`CALL ${marker}`));
      assert.equal(first.text, `done:${marker}`);
      const checkpoint = await source.checkpoint();
      assert.ok(checkpoint.length > 48);
      await source.close();
      source = null;
      restored = await esm.createFxAgent(baseOptions("native", tools, checkpoint));
      const second = await consumeTurn(restored.prompt(`RESTORE ${marker}`));
      assert.equal(second.text, `restored:${marker}`);
      assert.equal(state.callbacks, 1);
      const result = { marker, checkpointBytes: checkpoint.length, latencyMs: performance.now() - started };
      await restored.close();
      restored = null;
      return result;
    } finally {
      await source?.close().catch(() => {});
      await restored?.close().catch(() => {});
      provider.markerModes.delete(marker);
      provider.markerRequestCounts.delete(marker);
    }
  };
  const runCancellationWorkflow = async () => {
    const marker = nextMarker("cancel");
    provider.markerModes.set(marker, "cancel");
    provider.uniqueMarkers += 1;
    let startResolve;
    const toolStarted = new Promise((resolveStarted) => { startResolve = resolveStarted; });
    let settle;
    let signalAborted = false;
    let callbacks = 0;
    const controller = new AbortController();
    const waitTool = {
      name: "wait",
      description: "Wait for cancellation.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
      execute(_input, { signal }) {
        callbacks += 1;
        startResolve();
        signal.addEventListener("abort", () => { signalAborted = true; }, { once: true });
        return new Promise((resolveTool) => { settle = () => resolveTool(`late-result:${marker}`); });
      },
    };
    const started = performance.now();
    const runtimeEvents = [];
    let agent;
    try {
      agent = await esm.createFxAgent({
        ...baseOptions("native", [waitTool]),
        onEvent(event) { runtimeEvents.push(event); },
      });
      const pending = consumeTurn(agent.prompt(`CALL ${marker}`, { signal: controller.signal }));
      await withTimeout(toolStarted, 5_000, `cancel tool start ${marker}`);
      controller.abort();
      const cancelled = await withTimeout(pending, 10_000, `cancelled turn ${marker}`);
      assert.equal(cancelled.result.stopReason, "cancelled");
      assert.equal(callbacks, 1);
      assert.equal(signalAborted, true);
      const recovery = await withTimeout(consumeTurn(agent.prompt(`RECOVER ${marker}`)), 10_000, `cancel recovery ${marker}`);
      assert.equal(recovery.text, `recovered:${marker}`);
      const checkpointBeforeLate = await agent.checkpoint();
      const sendsBeforeLate = runtimeEvents.filter((event) => event.type === "acp.send").length;
      settle();
      await delay(25);
      assert.equal(provider.lateResultSeen, false);
      assert.equal(runtimeEvents.filter((event) => event.type === "acp.send").length, sendsBeforeLate);
      assert.deepEqual(await agent.checkpoint(), checkpointBeforeLate);
      assert.doesNotMatch(JSON.stringify(runtimeEvents), /late-result:/);
      const afterLate = await withTimeout(
        consumeTurn(agent.prompt(`AFTER_LATE ${marker}`)),
        10_000,
        `post-settlement turn ${marker}`,
      );
      assert.equal(afterLate.text, `after-late:${marker}`);
      assert.doesNotMatch(JSON.stringify(afterLate.events), /late-result:/);
      const checkpointAfterLate = await agent.checkpoint();
      assert.equal(Buffer.from(checkpointAfterLate).includes(Buffer.from("late-result:")), false);
      const result = { marker, checkpointBytes: checkpointAfterLate.length, latencyMs: performance.now() - started };
      await agent.close();
      agent = null;
      return result;
    } finally {
      settle?.();
      await agent?.close().catch(() => {});
      provider.markerModes.delete(marker);
      provider.markerRequestCounts.delete(marker);
    }
  };
  const runLifecycle = async (backend = "native") => {
    const started = performance.now();
    const info = await esm.getBackendInfo({ backend });
    assert.equal(info.backend, "native");
    const agent = await esm.createFxAgent({
      backend,
      apiKey: "test-placeholder",
      home: process.cwd(),
      workspaceRoot: process.cwd(),
    });
    try {
      const checkpoint = await agent.checkpoint();
      assert.ok(checkpoint.length > 48);
      return performance.now() - started;
    } finally {
      await agent.close();
    }
  };

  const samples = { lifecycleMs: [], toolMs: [], rejectMs: [], cancelMs: [], restoreMs: [], mixedMs: [] };
  const counts = {
    warmupCycles: 0,
    cheapCycles: 0,
    toolWorkflows: 0,
    isolationWorkflows: 0,
    restoreWorkflows: 0,
    rejectedWorkflows: 0,
    cancellationWorkflows: 0,
    mixedOperations: 0,
    laterSuccessfulInteractions: 0,
  };
  const memory = { samples: [] };
  memory.start = await memorySnapshot("start");
  const sampler = setInterval(async () => {
    if (memory.samples.length < 50_000) memory.samples.push(await memorySnapshot("sample"));
  }, 50);
  try {
    for (let index = 0; index < Math.min(10, config.cheapCycles); index += 1) {
      await runLifecycle(index % 2 ? "auto" : "native");
      counts.warmupCycles += 1;
    }
    memory.afterWarmup = await memorySnapshot("after-warmup");
    for (let index = 0; index < config.cheapCycles; index += 1) {
      samples.lifecycleMs.push(await runLifecycle(index % 2 ? "auto" : "native"));
      counts.cheapCycles += 1;
      if ((index + 1) % 100 === 0) console.error(JSON.stringify({ progress: "cheap-cycles", completed: index + 1 }));
    }
    for (let index = 0; index < config.toolWorkflows; index += 1) {
      const result = await runToolWorkflow({ backend: index % 2 ? "auto" : "native", label: "required" });
      samples.toolMs.push(result.latencyMs);
      counts.toolWorkflows += 1;
      if ((index + 1) % 10 === 0) console.error(JSON.stringify({ progress: "tool-workflows", completed: index + 1 }));
    }
    const isolated = await Promise.all(Array.from({ length: config.concurrency }, (_, index) =>
      runToolWorkflow({ backend: index % 2 ? "auto" : "native", label: "isolation" })));
    samples.toolMs.push(...isolated.map((item) => item.latencyMs));
    counts.isolationWorkflows += isolated.length;
    const restore = await runRestoreWorkflow();
    samples.restoreMs.push(restore.latencyMs);
    counts.restoreWorkflows += 1;

    const mixedStarted = performance.now();
    const mixedDeadline = mixedStarted + config.durationMs;
    let operation = 0;
    let nextProgress = mixedStarted + 15_000;
    while (performance.now() < mixedDeadline) {
      const waveStarted = performance.now();
      const wave = Array.from({ length: config.concurrency }, async () => {
        const selected = operation++ % 16;
        if (selected < 9) {
          const value = await runToolWorkflow({ backend: selected % 2 ? "auto" : "native", label: "mixed_success" });
          samples.toolMs.push(value.latencyMs);
          return "success";
        }
        if (selected < 11) {
          const value = await runToolWorkflow({ mode: "reject", backend: selected % 2 ? "auto" : "native", label: "mixed_reject" });
          samples.rejectMs.push(value.latencyMs);
          return "reject";
        }
        if (selected === 11) {
          const value = await runCancellationWorkflow();
          samples.cancelMs.push(value.latencyMs);
          return "cancel";
        }
        if (selected === 12) {
          const value = await runRestoreWorkflow();
          samples.restoreMs.push(value.latencyMs);
          return "restore";
        }
        samples.lifecycleMs.push(await runLifecycle(selected % 2 ? "auto" : "native"));
        return "lifecycle";
      });
      const outcomes = await Promise.all(wave);
      counts.mixedOperations += outcomes.length;
      counts.rejectedWorkflows += outcomes.filter((value) => value === "reject").length;
      counts.cancellationWorkflows += outcomes.filter((value) => value === "cancel").length;
      counts.restoreWorkflows += outcomes.filter((value) => value === "restore").length;
      samples.mixedMs.push(performance.now() - waveStarted);
      if (performance.now() >= nextProgress) {
        console.error(JSON.stringify({ progress: "mixed", elapsedMs: performance.now() - mixedStarted, operations: counts.mixedOperations }));
        nextProgress += 15_000;
      }
      await delay(5);
    }
    counts.mixedDurationMs = performance.now() - mixedStarted;
    const later = await runToolWorkflow({ backend: "auto", label: "later_success" });
    samples.toolMs.push(later.latencyMs);
    counts.laterSuccessfulInteractions += 1;
  } finally {
    clearInterval(sampler);
    server.closeAllConnections();
    await new Promise((resolveClose) => server.close(resolveClose));
  }
  await delay(500);
  if (typeof globalThis.gc === "function") globalThis.gc();
  await delay(100);
  memory.after = await memorySnapshot("after-quiescence");
  assert.deepEqual(provider.failures, []);
  assert.equal(provider.lateResultSeen, false);
  assert.equal(counts.cheapCycles, config.cheapCycles);
  assert.equal(counts.toolWorkflows, config.toolWorkflows);
  assert.ok(counts.mixedDurationMs >= config.durationMs);
  assert.equal(counts.laterSuccessfulInteractions, 1);
  assert.ok(counts.rejectedWorkflows > 0 && counts.cancellationWorkflows > 0 && counts.restoreWorkflows > 0);
  const allMemory = [memory.start, memory.afterWarmup, ...memory.samples, memory.after];
  memory.peakRss = allMemory.reduce((current, sample) => sample.rss > current.rss ? sample : current);
  memory.peakHeapUsed = allMemory.reduce((current, sample) => sample.heapUsed > current.heapUsed ? sample : current);
  memory.peakFileDescriptors = allMemory
    .filter((sample) => sample.fdCount !== null)
    .reduce((current, sample) => current === null || sample.fdCount > current.fdCount ? sample : current, null);
  memory.sampleCount = allMemory.length;
  const steadySamples = memory.samples.filter((sample) => sample.timestampMs >= memory.afterWarmup.timestampMs);
  memory.growthPerMinute = {
    rssBytes: slopePerMinute(steadySamples, "rss"),
    heapUsedBytes: slopePerMinute(steadySamples, "heapUsed"),
    fileDescriptors: steadySamples.every((sample) => sample.fdCount !== null)
      ? slopePerMinute(steadySamples, "fdCount")
      : null,
  };
  const result = {
    mode: config.mode,
    package: config.packageIdentity,
    runtime: {
      node: process.version,
      execPath: process.execPath,
      platform: process.platform,
      arch: process.arch,
      jspi: typeof WebAssembly.Suspending === "function" && typeof WebAssembly.promising === "function",
      execArgv: process.execArgv,
    },
    exports: exportNames,
    backends: { forcedNative: baselineNative, automatic: baselineAuto },
    counts,
    provider: {
      fetchCalls: provider.fetchCalls,
      getRequests: provider.getRequests,
      requests: provider.requests,
      toolFirstSteps: provider.toolFirstSteps,
      toolResultSteps: provider.toolResultSteps,
      uniqueMarkers: provider.uniqueMarkers,
      retainedMarkerModes: provider.markerModes.size,
      retainedMarkerRequestCounts: provider.markerRequestCounts.size,
    },
    latency: Object.fromEntries(Object.entries(samples).map(([key, values]) => [key, stats(values)])),
    memory,
  };
  console.log(JSON.stringify(result));
}

const workerSource = `#!/usr/bin/env node\n(${installedWorkerMain.toString()})().catch((error) => {\n  const record = { name: error?.name ?? typeof error, code: error?.code ?? null, message: error?.message ?? String(error), stack: error?.stack ?? null };\n  console.error(JSON.stringify({ workerFailure: record }));\n  process.exitCode = 1;\n});\n`;

async function makeConsumer(root, name, sourcePackage) {
  const consumer = join(root, name);
  await mkdir(join(consumer, "node_modules"), { recursive: true });
  await writeFile(join(consumer, "package.json"), '{"name":"libfx-resilience-consumer","private":true,"type":"module"}\n');
  await cp(sourcePackage, join(consumer, "node_modules", "libfx"), { recursive: true });
  await writeFile(join(consumer, "worker.mjs"), workerSource);
  return consumer;
}

function cpuProfileFlags(tempRoot) {
  if (!process.execArgv.some((argument) => argument === "--cpu-prof" || argument.startsWith("--cpu-prof="))) return [];
  const suppliedDir = process.execArgv.find((argument) => argument.startsWith("--cpu-prof-dir="))?.slice("--cpu-prof-dir=".length);
  const directory = resolve(suppliedDir ?? join(tempRoot, "cpu-profile"));
  if (isInside(repoRoot, directory)) throw new Error("CPU profiles must be written outside the source checkout");
  return ["--cpu-prof", `--cpu-prof-dir=${directory}`];
}

async function runWorker({ consumer, config, timeoutMs, flags = [], expectedStatus = 0, relayStderr = false }) {
  const result = await runProcess({
    label: config.mode,
    command: process.execPath,
    args: [...flags, join(consumer, "worker.mjs"), JSON.stringify(config)],
    cwd: consumer,
    timeoutMs,
    expectedStatus,
    relayStderr,
  });
  return { ...result, parsed: expectedStatus === 0 ? lastJsonLine(result.stdout) : null };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.jsonOut && isInside(repoRoot, options.jsonOut)) {
    throw new Error("structured evidence must be written outside the source checkout");
  }
  const tempRoot = await mkdtemp(join(tmpdir(), "libfx-package-resilience-"));
  let failed = true;
  const stages = [];
  try {
    const baseConsumer = join(tempRoot, "base-consumer");
    const installMethod = await installPackage(options.packageInput, baseConsumer, options.npmBin);
    const basePackage = join(baseConsumer, "node_modules", "libfx");
    await writeFile(join(baseConsumer, "worker.mjs"), workerSource);
    const identity = await packageIdentity(basePackage, options.packageInput, installMethod);
    console.error(JSON.stringify({ progress: "package-staged", identity, tempRoot }));
    const profileFlags = cpuProfileFlags(tempRoot);
    if (profileFlags.length) await mkdir(profileFlags[1].slice("--cpu-prof-dir=".length), { recursive: true });

    const workload = await runWorker({
      consumer: baseConsumer,
      config: {
        mode: "workload",
        cheapCycles: options.cheapCycles,
        toolWorkflows: options.toolWorkflows,
        durationMs: options.durationMs,
        concurrency: options.concurrency,
        packageIdentity: identity,
      },
      timeoutMs: options.stageTimeoutMs,
      flags: ["--expose-gc", ...profileFlags],
      relayStderr: true,
    });
    stages.push({ name: "workload", status: "PASS", result: workload.parsed, stderr: workload.stderr });

    const cjsBaseline = await runWorker({
      consumer: baseConsumer,
      config: { mode: "cjs-happy" },
      timeoutMs: options.faultTimeoutMs,
    });
    stages.push({ name: "cjs-happy", status: "PASS", result: cjsBaseline.parsed });

    const nativeFile = `libfx.${process.platform}-${process.arch}.node`;
    for (const mode of ["fault-missing-addon", "fault-corrupt-addon"]) {
      const consumer = await makeConsumer(tempRoot, mode, basePackage);
      const addonPath = join(consumer, "node_modules", "libfx", nativeFile);
      if (mode === "fault-missing-addon") await rm(addonPath);
      else await writeFile(addonPath, "not a native addon");
      const outcome = await runWorker({ consumer, config: { mode }, timeoutMs: options.faultTimeoutMs });
      stages.push({ name: mode, status: "PASS_EXPECTED_FAULT", result: outcome.parsed });
    }

    for (const mode of ["fault-no-jspi", "fault-bad-api", "fault-invalid-input"]) {
      const consumer = await makeConsumer(tempRoot, mode, basePackage);
      const outcome = await runWorker({ consumer, config: { mode }, timeoutMs: options.faultTimeoutMs });
      stages.push({ name: mode, status: "PASS_EXPECTED_FAULT", result: outcome.parsed });
    }

    for (const mode of ["fault-missing-wasm", "fault-corrupt-wasm"]) {
      const consumer = await makeConsumer(tempRoot, mode, basePackage);
      const packageDir = join(consumer, "node_modules", "libfx");
      const wasmPath = join(packageDir, "fx-core.wasm");
      const restoreWasmPath = join(packageDir, "fx-core.valid.wasm");
      await cp(wasmPath, restoreWasmPath);
      if (mode === "fault-missing-wasm") await rm(wasmPath);
      else await writeFile(wasmPath, "not WebAssembly");
      const outcome = await runWorker({
        consumer,
        config: { mode, wasmPath, restoreWasmPath },
        timeoutMs: options.faultTimeoutMs,
        flags: ["--experimental-wasm-jspi"],
      });
      stages.push({ name: mode, status: "PASS_EXPECTED_FAULT_WITH_RECOVERY", result: outcome.parsed });
    }

    const mutationConsumer = await makeConsumer(tempRoot, "mutation-broken-cjs", basePackage);
    const mutationManifestPath = join(mutationConsumer, "node_modules", "libfx", "package.json");
    const mutationManifest = JSON.parse(await readFile(mutationManifestPath, "utf8"));
    mutationManifest.exports["."].node.require = "./missing-node.cjs";
    mutationManifest.exports["./node"].require = "./missing-node.cjs";
    await writeFile(mutationManifestPath, `${JSON.stringify(mutationManifest, null, 2)}\n`);
    const mutation = await runWorker({
      consumer: mutationConsumer,
      config: { mode: "cjs-happy" },
      timeoutMs: options.faultTimeoutMs,
      expectedStatus: 1,
    });
    assert.match(mutation.stderr, /ERR_MODULE_NOT_FOUND|MODULE_NOT_FOUND|Cannot find module/);
    stages.push({
      name: "mutation-broken-cjs-export",
      status: "PASS_ORACLE_REJECTED_MUTATION",
      result: { exitStatus: mutation.status, signal: mutation.signal, stderr: mutation.stderr.slice(-4000) },
    });

    const report = {
      schemaVersion: 1,
      generatedAt: new Date().toISOString(),
      package: identity,
      runtime: {
        node: process.version,
        execPath: process.execPath,
        platform: process.platform,
        arch: process.arch,
        execArgv: process.execArgv,
      },
      configuration: {
        cheapCycles: options.cheapCycles,
        toolWorkflows: options.toolWorkflows,
        sustainedDurationMs: options.durationMs,
        concurrency: options.concurrency,
        stageTimeoutMs: options.stageTimeoutMs,
        faultTimeoutMs: options.faultTimeoutMs,
      },
      summary: {
        passedStages: stages.length,
        failedStages: 0,
        expectedFaultStages: stages.filter((stage) => stage.status.includes("EXPECTED_FAULT")).length,
        qualifiedMutationStages: stages.filter((stage) => stage.status.includes("ORACLE_REJECTED")).length,
      },
      cpuProfileDirectory: profileFlags.length ? profileFlags[1].slice("--cpu-prof-dir=".length) : null,
      tempRoot: options.keepTemp ? tempRoot : null,
      stages,
    };
    if (options.jsonOut) {
      await mkdir(dirname(options.jsonOut), { recursive: true });
      await writeFile(options.jsonOut, `${JSON.stringify(report, null, 2)}\n`);
    }
    console.log(JSON.stringify(report, null, 2));
    failed = false;
  } catch (error) {
    if (options.jsonOut) {
      await mkdir(dirname(options.jsonOut), { recursive: true });
      await writeFile(options.jsonOut, `${JSON.stringify({
        generatedAt: new Date().toISOString(),
        packageInput: options.packageInput,
        runtime: { node: process.version, execPath: process.execPath, platform: process.platform, arch: process.arch },
        failure: { name: error.name, code: error.code ?? null, message: error.message, stack: error.stack },
        processResult: error.result ?? null,
        completedStages: stages,
        retainedTempRoot: tempRoot,
      }, null, 2)}\n`);
    }
    throw error;
  } finally {
    if (!options.keepTemp && !failed) await rm(tempRoot, { recursive: true, force: true });
    else if (failed) console.error(JSON.stringify({ progress: "retained-failure-repro", tempRoot }));
  }
}

await main();
