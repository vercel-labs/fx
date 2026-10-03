#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasm = await readFile(resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-term.wasm")));
if (!supportsJspi()) process.exit(2);

const encoder = new TextEncoder();
const requestDecoder = new TextDecoder();
const catalog = {
  object: "list",
  data: [{ id: "test/agents-model", type: "language", released: 1, tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }],
};
const info = {
  version: 1,
  root: "/workspace",
  cwd: "/workspace",
  home: "/home/visitor",
  gitAvailable: false,
  ephemeral: true,
};

function sse(events) {
  return new Response(
    `${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`,
    { headers: { "content-type": "text/event-stream" } },
  );
}

function textResponse(value) {
  return sse([
    { type: "text-delta", delta: value },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
  ]);
}

function shellCall(id, command) {
  return sse([
    { type: "tool-call", toolCallId: id, toolName: "shell", input: { action: "run", command } },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
}

function systemText(body) {
  return (body.prompt || [])
    .filter((message) => message.role === "system")
    .map((message) => (typeof message.content === "string" ? message.content : JSON.stringify(message.content)))
    .join("\n");
}

// Runs `turns` prompts in a fresh terminal and returns every model request's
// system text. `respond(requestNumber)` may script a tool call; otherwise the
// model answers the turn.
async function systemTextsWith(workspace, label, { turns = 1, respond = () => null } = {}) {
  const terminal = new Terminal({ cols: 100, rows: 30, allowProposedApi: true, scrollback: 2000 });
  const config = new Map([["model", "test/agents-model"], ["mode", "code"]]);
  const requests = [];
  let answered = 0;
  let stderr = "";
  const stderrDecoder = new TextDecoder();
  const runtime = await createFxTerminal({
    backend: "wasm",
    wasm,
    terminal: xtermAdapter(terminal),
    env: { AI_GATEWAY_API_KEY: "agents-md-key" },
    async fetch(_url, init = {}) {
      if ((init.method || "GET") === "GET") {
        return new Response(JSON.stringify(catalog), { status: 200, headers: { "content-type": "application/json" } });
      }
      requests.push(JSON.parse(requestDecoder.decode(init.body)));
      const scripted = respond(requests.length);
      if (scripted) return scripted;
      answered += 1;
      return textResponse(`${label} answered ${answered}`);
    },
    configStore: { get(id) { return config.get(id) ?? null; }, set(id, value) { config.set(id, value); } },
    stderr(chunk) { stderr += stderrDecoder.decode(chunk, { stream: true }); },
    workspace,
  });
  const flush = () => new Promise((resolveFlush) => terminal.write("", resolveFlush));
  const grid = () => {
    const lines = [];
    for (let row = 0; row < terminal.buffer.active.length; row += 1) {
      lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
    }
    return lines.join("\n");
  };
  const waitFor = async (predicate, what) => {
    const deadline = performance.now() + 5000;
    while (!predicate()) {
      await flush();
      if (performance.now() >= deadline) throw new Error(`${label}: timed out waiting for ${what}:\n${stderr}\n${grid()}`);
      await new Promise((resolveWait) => setTimeout(resolveWait, 10));
    }
  };
  try {
    await waitFor(() => grid().includes("𝒇x"), "startup");
    for (let turn = 1; turn <= turns; turn += 1) {
      runtime.write(`${label} prompt ${turn}\r`);
      await waitFor(() => grid().includes(`${label} answered ${turn}`), `turn ${turn}`);
    }
    runtime.write("/exit\r");
    const exitCode = await Promise.race([
      runtime.exited,
      new Promise((_, reject) => setTimeout(() => reject(new Error(`${label}: exit timeout`)), 5000)),
    ]);
    if (exitCode !== 0) throw new Error(`${label}: fx-term exited with ${exitCode}`);
  } finally {
    runtime.abort();
  }
  if (requests.length === 0) throw new Error(`${label}: no model request`);
  return requests.map(systemText);
}

function expectIncludes(text, expected, label) {
  if (!text.includes(expected)) throw new Error(`${label}: model context omitted ${JSON.stringify(expected)}:\n${text}`);
}

function expectExcludes(text, unexpected, label) {
  if (text.includes(unexpected)) throw new Error(`${label}: model context unexpectedly included ${JSON.stringify(unexpected)}:\n${text}`);
}

function workspaceWith(readFile) {
  return {
    info,
    permission: "allow-sandboxed",
    exec({ command }) {
      if (command !== "pwd") throw new Error(`unexpected workspace command: ${command}`);
      return { stdout: "/workspace\n", stderr: "", exitCode: 0 };
    },
    ...(readFile ? { readFile } : {}),
  };
}

const reads = [];
function readRules({ path, signal }) {
  if (!(signal instanceof AbortSignal)) throw new Error("readFile did not receive an AbortSignal");
  reads.push(path);
  if (path === "/home/visitor/.fx/AGENTS.md") return encoder.encode("GLOBAL_RULE_SENTINEL\n").buffer;
  if (path === "/workspace/AGENTS.md") return encoder.encode("PROJECT_RULE_SENTINEL\n");
  return null;
}

const [readable] = await systemTextsWith(workspaceWith(readRules), "readable");
expectIncludes(readable, "<project-instructions-guidance>", "readable");
expectIncludes(readable, "<global-rules from=\"/home/visitor/.fx/AGENTS.md\">\nGLOBAL_RULE_SENTINEL\n</global-rules>", "readable");
expectIncludes(readable, "<project-rules from=\"/workspace/AGENTS.md\">\nPROJECT_RULE_SENTINEL\n</project-rules>", "readable");
expectExcludes(readable, "host cannot read instruction files", "readable");
if (reads.join(",") !== "/home/visitor/.fx/AGENTS.md,/workspace/AGENTS.md") {
  throw new Error(`readable: unexpected readFile paths: ${reads.join(",")}`);
}

// A tool call makes later turns rebuild context from history; that rebuild
// must use the host workspace root, not the WebAssembly process root.
const toolTurn = { turns: 2, respond: (request) => (request === 1 ? shellCall("call-1", "pwd") : null) };
const readableAfterTool = await systemTextsWith(workspaceWith(readRules), "readable-after-tool", toolTurn);
const readableTurnTwo = readableAfterTool.at(-1);
expectIncludes(readableTurnTwo, "<project-rules from=\"/workspace/AGENTS.md\">\nPROJECT_RULE_SENTINEL\n</project-rules>", "readable-after-tool");
expectExcludes(readableTurnTwo, "from=\"/AGENTS.md\"", "readable-after-tool");
expectExcludes(readableTurnTwo, "<scoped-rules from=\"/workspace/AGENTS.md\"", "readable-after-tool");
if (reads.some((path) => !path.startsWith("/workspace/") && !path.startsWith("/home/visitor/"))) {
  throw new Error(`readable-after-tool: readFile requested a path outside root and home: ${reads.join(",")}`);
}

const [unreadable] = await systemTextsWith(workspaceWith(null), "unreadable");
expectIncludes(unreadable, "<project-rules-omitted from=\"/workspace/AGENTS.md\" reason=\"host cannot read instruction files\" />", "unreadable");
expectExcludes(unreadable, "<project-rules from=", "unreadable");

const unreadableAfterTool = await systemTextsWith(workspaceWith(null), "unreadable-after-tool", toolTurn);
const unreadableTurnTwo = unreadableAfterTool.at(-1);
expectIncludes(unreadableTurnTwo, "<project-rules-omitted from=\"/workspace/AGENTS.md\" reason=\"host cannot read instruction files\" />", "unreadable-after-tool");
expectExcludes(unreadableTurnTwo, "from=\"/AGENTS.md\"", "unreadable-after-tool");

const [failing] = await systemTextsWith(workspaceWith(({ path }) => {
  if (path === "/home/visitor/.fx/AGENTS.md") throw new Error("host read failed");
  return new Uint8Array([0x72, 0x75, 0xff, 0x6c, 0x65]);
}), "failing");
expectIncludes(failing, "<project-rules-omitted from=\"/home/visitor/.fx/AGENTS.md\" reason=\"unreadable rule file\" />", "failing");
expectIncludes(failing, "<project-rules-omitted from=\"/workspace/AGENTS.md\" reason=\"unreadable rule file\" />", "failing");
expectExcludes(failing, "<global-rules", "failing");

console.log("headless AGENTS.md passed: host readFile delivers global and project rules across tool turns, and missing access or unreadable files are reported to the model");
