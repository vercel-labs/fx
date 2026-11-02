#!/usr/bin/env node
// /usage in the WebAssembly terminal reads AI Gateway's usage through the
// host's fetch. While a read waits, the terminal keeps drawing and reading
// keys, and Ctrl+C or aborting the terminal aborts the read.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-term.wasm"));
if (!supportsJspi()) process.exit(2);
const wasm = await readFile(wasmPath);
const apiKey = "usage-test-key";

// A terminal signed in with an API key, against a fake AI Gateway. Once
// `hold` is set, from the start or by `holdReads()`, report reads wait for
// `release()` or their AbortSignal.
async function startTerminal({ hold = false } = {}) {
  const terminal = new Terminal({ cols: 120, rows: 40, allowProposedApi: true, scrollback: 2000 });
  const reports = [];
  let release;
  const released = new Promise((resolve) => { release = resolve; });
  const fetch = async (url, init = {}) => {
    const { pathname, searchParams } = new URL(url);
    if (pathname !== "/v1/report") return new Response("not found", { status: 404 });
    reports.push({ url: new URL(url), method: init.method ?? "GET", headers: new Headers(init.headers), signal: init.signal });
    if (hold) {
      await new Promise((resolve, reject) => {
        released.then(resolve);
        init.signal?.addEventListener("abort", () => reject(init.signal.reason), { once: true });
      });
    }
    const today = searchParams.get("start_date") === searchParams.get("end_date");
    return Response.json({ results: [{
      model: "test/usage-model",
      request_count: today ? 3 : 9,
      input_tokens: 10,
      output_tokens: 20,
      total_cost: today ? 1.25 : 4.5,
    }] });
  };
  let stderr = "";
  const decoder = new TextDecoder();
  const runtime = await createFxTerminal({
    backend: "wasm",
    wasm,
    terminal: xtermAdapter(terminal),
    env: { AI_GATEWAY_API_KEY: apiKey },
    fetch,
    stderr(chunk) { stderr += decoder.decode(chunk, { stream: true }); },
  });
  const flush = () => new Promise((resolve) => terminal.write("", resolve));
  const grid = () => {
    const lines = [];
    for (let row = 0; row < terminal.buffer.active.length; row++) lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
    return lines.join("\n");
  };
  const waitFor = async (predicate, label, ms = 8000) => {
    const deadline = performance.now() + ms;
    while (!predicate()) {
      await flush();
      if (performance.now() >= deadline) throw new Error(`timed out waiting for ${label}:\n${stderr}\n${grid()}`);
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  };
  await waitFor(() => grid().includes("𝒇x"), "startup");
  return { terminal, runtime, reports, release, holdReads: () => { hold = true; }, grid, waitFor, stderr: () => stderr };
}

function assertReportRequest(request) {
  assert.equal(request.method, "GET");
  assert.equal(request.url.origin, "https://ai-gateway.vercel.sh");
  assert.equal(request.url.pathname, "/v1/report");
  assert.equal(request.headers.get("authorization"), `Bearer ${apiKey}`);
}

// The numbers reach the screen, and `r` reads them again.
{
  const t = await startTerminal();
  try {
    t.runtime.write("/usage\r");
    await t.waitFor(() => t.grid().includes("test/usage-model") && t.grid().includes("updated"), "usage numbers");
    assert.ok(t.reports.length >= 1, "opening /usage must read AI Gateway's report");
    t.reports.forEach(assertReportRequest);
    assert.doesNotMatch(t.grid(), /nothing fetched today/);
    assert.match(t.grid(), /\$1\.25/);

    // Tab lists another period in the model table without reading again.
    const period = t.grid().match(/model \((\w+)\)/)?.[1];
    assert.ok(period, "the model table names its period");
    const reads = t.reports.length;
    t.runtime.write("\t");
    await t.waitFor(() => t.grid().match(/model \((\w+)\)/)?.[1] !== period, "Tab to change the period");
    assert.equal(t.reports.length, reads);

    const before = t.reports.length;
    t.runtime.write("r");
    await t.waitFor(() => t.reports.length > before, "refresh");
    assertReportRequest(t.reports.at(-1));

    t.runtime.write("\x1b");
    await t.waitFor(() => !t.grid().includes("usage: API key"), "/usage to close");
    t.runtime.write("/exit\r");
    assert.equal(await t.runtime.exited, 0);
    assert.equal(t.stderr(), "");
    console.log(`usage numbers passed: ${t.reports.length} report reads through the host`);
  } finally {
    t.runtime.abort();
    t.terminal.dispose();
  }
}

// While a read waits, the terminal keeps drawing and reading keys, and Ctrl+C
// aborts the read without losing the numbers already on screen.
{
  const t = await startTerminal();
  try {
    t.runtime.write("/usage\r");
    await t.waitFor(() => t.grid().includes("test/usage-model") && t.grid().includes("updated"), "usage numbers");
    t.holdReads();
    const before = t.reports.length;
    t.runtime.write("r");
    await t.waitFor(() => t.reports.length === before + 1 && t.grid().includes("updating"), "a waiting refresh");
    const waiting = t.reports.at(-1);

    const period = t.grid().match(/model \((\w+)\)/)?.[1];
    t.runtime.write("\t");
    await t.waitFor(() => t.grid().match(/model \((\w+)\)/)?.[1] !== period, "Tab while the read waits");
    assert.equal(waiting.signal?.aborted, false);

    t.runtime.write("\x03");
    await t.waitFor(() => waiting.signal?.aborted && !t.grid().includes("updating"), "Ctrl+C to abort the waiting read");
    assert.ok(t.grid().includes("test/usage-model"), "the numbers already fetched stay on screen");

    t.runtime.write("\x1b");
    await t.waitFor(() => !t.grid().includes("usage: API key"), "/usage to close");
    t.runtime.write("/exit\r");
    assert.equal(await t.runtime.exited, 0);
    assert.equal(t.stderr(), "");
    console.log("waiting read passed: Tab redrew while it waited, and Ctrl+C aborted it");
  } finally {
    t.release();
    t.runtime.abort();
    t.terminal.dispose();
  }
}

// Aborting the terminal while a read waits settles it at once.
{
  const t = await startTerminal({ hold: true });
  try {
    t.runtime.write("/usage\r");
    await t.waitFor(() => t.reports.length === 1 && t.grid().includes("fetching"), "a waiting first read");
    const started = performance.now();
    t.runtime.abort();
    await Promise.race([
      t.runtime.exited.catch(() => {}),
      new Promise((_, reject) => setTimeout(() => reject(new Error("abort() left the terminal running")), 5000)),
    ]);
    assert.equal(t.reports[0].signal?.aborted, true, "abort() must abort the waiting read");
    console.log(`terminal abort passed: settled in ${Math.round(performance.now() - started)} ms`);
  } finally {
    t.release();
    t.terminal.dispose();
  }
}
console.log("Terminal usage passed: /usage reads through the host fetch, stays responsive while a read waits, and stops it on Ctrl+C or abort");
