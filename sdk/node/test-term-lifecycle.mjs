#!/usr/bin/env node
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-term.wasm"));
if (!supportsJspi()) process.exit(2);

function instrumentTerminal(terminal, disposals, onWrite = () => {}) {
  const host = xtermAdapter(terminal);
  return {
    write(bytes) { onWrite(bytes); host.write(bytes); },
    onData(callback) {
      const unsubscribe = host.onData(callback);
      return () => { disposals.data += 1; unsubscribe(); };
    },
    onResize(callback) {
      const unsubscribe = host.onResize(callback);
      return () => { disposals.resize += 1; unsubscribe(); };
    },
    get cols() { return host.cols; },
    get rows() { return host.rows; },
  };
}

function terminalGrid(terminal) {
  const lines = [];
  for (let row = 0; row < terminal.buffer.active.length; row++) {
    lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
  }
  return lines.join("\n");
}

const activeTransitionChildIndex = process.argv.indexOf("--active-transition-child");
if (activeTransitionChildIndex >= 0) {
  const scenario = process.argv[activeTransitionChildIndex + 1];
  const command = process.argv[activeTransitionChildIndex + 2];
  await runActiveTransitionChild(scenario, command);
  process.exit(0);
}

const terminal = new Terminal({ cols: 80, rows: 24, allowProposedApi: true, scrollback: 1000 });
let terminalWriteCount = 0;
let terminalOutput = "";
const outputDecoder = new TextDecoder();
const disposals = { data: 0, resize: 0 };
const instrumentedTerminalHost = instrumentTerminal(terminal, disposals, (bytes) => {
  terminalWriteCount += 1;
  terminalOutput += outputDecoder.decode(bytes, { stream: true });
});
const events = [];
let fetchStarted = false;
let fetchAborted = false;
const fetch = async (_url, init) => {
  fetchStarted = true;
  return new Promise((_, reject) => {
    init.signal.addEventListener("abort", () => {
      fetchAborted = true;
      reject(new DOMException("aborted", "AbortError"));
    }, { once: true });
  });
};
const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: instrumentedTerminalHost,
  env: { AI_GATEWAY_API_KEY: "term-lifecycle-key" },
  fetch,
  onEvent(event) { events.push(event); },
});
const flush = () => new Promise((resolve) => terminal.write("", resolve));
const grid = () => terminalGrid(terminal);
async function waitFor(predicate, label) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    await flush();
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${label}:\n${grid()}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

await waitFor(() => grid().includes("𝒇x"), "startup");
terminal.resize(112, 36);
await waitFor(
  () => events.some((event) => event.type === "terminal.resize" && event.cols === 112 && event.rows === 36) &&
    events.some((event) => event.type === "terminal.size" && event.cols === 112 && event.rows === 36),
  "resize propagation",
);

const themeQueryStart = terminalOutput.length;
runtime.write("\x1b[?997;2n");
await waitFor(
  () => terminalOutput.slice(themeQueryStart).includes("\x1b[c"),
  "theme response-fence query",
);
runtime.write("\x1b[?1;2c");
await waitFor(
  () => terminalOutput.slice(themeQueryStart).includes("\x1b]11;?\x1b\\\x1b[c"),
  "fenced OSC 11 query",
);
const themeRepaintStart = terminalOutput.length;
runtime.write("\x1b]11;rgb:ffff/ffff/ffff\x1b\\\x1b[?1;2c");
await waitFor(() => {
  const repaint = terminalOutput.slice(themeRepaintStart);
  return repaint.includes("\x1b[3J") && repaint.includes("\x1b[38;5;247m");
}, "light theme retint and repaint");

const submittedAt = performance.now();
runtime.write("wait forever\r");
await waitFor(() => fetchStarted, "stalled fetch");
await waitFor(
  () => grid().includes("Thinking") && grid().includes("wait forever"),
  "accepted prompt presentation before network response",
);
const acceptanceLatencyMs = performance.now() - submittedAt;
if (acceptanceLatencyMs >= 1000) {
  throw new Error(`accepted prompt presentation took ${acceptanceLatencyMs.toFixed(1)}ms`);
}
const writesAfterAcceptance = terminalWriteCount;
await waitFor(
  () => terminalWriteCount >= writesAfterAcceptance + 2,
  "animated terminal frames while fetch is stalled",
);
await waitFor(() => grid().includes("Thinking (1s)"), "thinking counter while fetch is stalled");
runtime.write("\x03");
await waitFor(() => fetchAborted, "fetch abort");
await waitFor(() => grid().includes("Cancelled") || grid().includes("cancelled"), "cancelled turn presentation");

runtime.write("/exit\r");
const exitCode = await Promise.race([
  runtime.exited,
  new Promise((_, reject) => setTimeout(() => reject(new Error("timed out waiting for exit")), 5000)),
]);
if (exitCode !== 0) throw new Error(`fx-term exited with ${exitCode}`);
await new Promise((resolve) => setTimeout(resolve, 0));
const exitEvents = events.filter((event) => event.type === "runtime.exit");
if (exitEvents.length !== 1) throw new Error(`expected one runtime.exit event, got ${exitEvents.length}`);
if (disposals.data !== 1 || disposals.resize !== 1) {
  throw new Error(`terminal subscriptions were not released exactly once: data=${disposals.data}, resize=${disposals.resize}`);
}

const abortTerminal = new Terminal({ cols: 80, rows: 24, allowProposedApi: true, scrollback: 1000 });
const abortDisposals = { data: 0, resize: 0 };
const abortRuntime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: instrumentTerminal(abortTerminal, abortDisposals),
  env: { AI_GATEWAY_API_KEY: "term-lifecycle-key" },
  fetch,
});
const abortFlush = () => new Promise((resolve) => abortTerminal.write("", resolve));
const abortGrid = () => terminalGrid(abortTerminal);
const abortStartupDeadline = performance.now() + 5000;
while (!abortGrid().includes("𝒇x")) {
  await abortFlush();
  if (performance.now() >= abortStartupDeadline) throw new Error(`timed out waiting for abort runtime startup:\n${abortGrid()}`);
  await new Promise((resolve) => setTimeout(resolve, 10));
}
abortRuntime.abort();
if (await abortRuntime.exited !== 130) throw new Error("aborted terminal did not exit with code 130");
if (abortDisposals.data !== 1 || abortDisposals.resize !== 1) {
  throw new Error(`aborted terminal subscriptions were not released exactly once: data=${abortDisposals.data}, resize=${abortDisposals.resize}`);
}

await runActiveTransitionScenario("stalled", "/clear");
await runActiveTransitionScenario("streaming", "/clear");
await runActiveTransitionScenario("stalled", "/new");
await runActiveTransitionScenario("stalled", "/reset");

console.log("headless lifecycle passed: active session transitions recovered and Ctrl-C cancelled stalled fetch");

async function runActiveTransitionScenario(scenario, command) {
  const child = spawn(process.execPath, [
    "--experimental-wasm-jspi",
    fileURLToPath(import.meta.url),
    wasmPath,
    "--active-transition-child",
    scenario,
    command,
  ], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  const result = await new Promise((resolveResult) => {
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, 15000);
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      resolveResult({ code, signal, timedOut });
    });
  });

  if (result.timedOut) {
    throw new Error(`active ${command} timed out during ${scenario}; child output:\n${stdout}`);
  }
  if (result.code !== 0) {
    throw new Error(`active ${command} failed during ${scenario}: code=${result.code} signal=${result.signal}\n${stderr}\n${stdout}`);
  }
  if (!stdout.includes("followup_completed")) {
    throw new Error(`active ${command} did not complete a follow-up prompt during ${scenario}:\n${stdout}`);
  }
  if (stderr !== "") throw new Error(`active ${command} wrote stderr during ${scenario}:\n${stderr}`);
}

async function runActiveTransitionChild(scenario, command) {
  if (!scenario || !command) throw new Error("active transition child requires scenario and command");

  const childTerminal = new Terminal({ cols: 80, rows: 24, allowProposedApi: true, scrollback: 1000 });
  const childDisposals = { data: 0, resize: 0 };
  let childOutput = "";
  let fetchCount = 0;
  const requestBodies = [];
  let firstFetchAborted = false;
  let streamStarted = false;
  const childDecoder = new TextDecoder();
  const childHost = instrumentTerminal(childTerminal, childDisposals, (bytes) => {
    childOutput += childDecoder.decode(bytes, { stream: true });
  });
  const encoder = new TextEncoder();

  const completedResponse = (text) => new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "followup_1", delta: text })}\n\n`));
      controller.enqueue(encoder.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":1}}}\n\n'));
      controller.enqueue(encoder.encode("data: [DONE]\n\n"));
      controller.close();
    },
  }), { status: 200, headers: { "content-type": "text/event-stream" } });

  const childFetch = async (_url, init) => {
    fetchCount += 1;
    requestBodies.push(new TextDecoder().decode(init.body));
    process.stdout.write(`fetch_started:${fetchCount}\n`);
    if (fetchCount > 1) return completedResponse("FOLLOWUP_OK");
    if (scenario === "stalled") {
      return new Promise((_, reject) => {
        init.signal.addEventListener("abort", () => {
          firstFetchAborted = true;
          process.stdout.write("fetch_aborted\n");
          reject(new DOMException("aborted", "AbortError"));
        }, { once: true });
      });
    }
    let sent = false;
    return new Response(new ReadableStream({
      pull(controller) {
        if (sent) return;
        sent = true;
        controller.enqueue(encoder.encode('data: {"type":"text-delta","id":"stream_1","delta":"STREAM_STARTED"}\n\n'));
        streamStarted = true;
        init.signal.addEventListener("abort", () => {
          firstFetchAborted = true;
          process.stdout.write("fetch_aborted\n");
          controller.error(new DOMException("aborted", "AbortError"));
        }, { once: true });
      },
    }), { status: 200, headers: { "content-type": "text/event-stream" } });
  };

  const childRuntime = await createFxTerminal({
    backend: "wasm",
    wasm: await readFile(wasmPath),
    terminal: childHost,
    env: { AI_GATEWAY_API_KEY: "term-active-transition-key" },
    fetch: childFetch,
  });
  const childFlush = () => new Promise((resolveFlush) => childTerminal.write("", resolveFlush));
  const waitForChild = async (predicate, label, timeoutMs = 5000) => {
    const deadline = performance.now() + timeoutMs;
    while (!predicate()) {
      await childFlush();
      if (performance.now() >= deadline) {
        throw new Error(`timed out waiting for ${label}; output:\n${childOutput}`);
      }
      await new Promise((resolveWait) => setTimeout(resolveWait, 10));
    }
  };

  await childRuntime.interactive;
  await waitForChild(() => childOutput.includes("Run /help for commands"), "child startup");
  process.stdout.write("runtime_interactive\n");
  childRuntime.write("first prompt\r");
  await waitForChild(() => fetchCount === 1, "first fetch");
  if (scenario === "streaming") {
    await waitForChild(() => streamStarted, "stream start");
  } else {
    await waitForChild(() => childOutput.includes("Thinking"), "thinking state");
  }

  process.stdout.write("transition_write\n");
  childRuntime.write(`${command}\r`);
  process.stdout.write("transition_returned\n");
  await waitForChild(() => firstFetchAborted, "first fetch abort");
  process.stdout.write("transition_settled\n");
  childRuntime.write("second prompt\r");
  await waitForChild(
    () => fetchCount === 2 && terminalGrid(childTerminal).includes("FOLLOWUP_OK"),
    "follow-up completion",
  );
  const followupRequest = requestBodies[1] ?? "";
  if (!followupRequest.includes("second prompt")) {
    throw new Error(`follow-up request omitted the new prompt: ${followupRequest}`);
  }
  if (followupRequest.includes("first prompt") || followupRequest.includes("STREAM_STARTED")) {
    throw new Error(`follow-up request retained cancelled session history: ${followupRequest}`);
  }
  process.stdout.write("followup_completed\n");
  childRuntime.write("/exit\r");
  const childExit = await childRuntime.exited;
  if (childExit !== 0) throw new Error(`child runtime exited with ${childExit}`);
  if (childDisposals.data !== 1 || childDisposals.resize !== 1) {
    throw new Error(`child subscriptions were not released exactly once: data=${childDisposals.data}, resize=${childDisposals.resize}`);
  }
}
