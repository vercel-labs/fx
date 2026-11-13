#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

// Tool calls from separate model steps and separate turns keep blocks of
// their own on the fx-term.wasm screen. The blocks are keyed by turn and step
// ids (tests/tla/debug_trace/TraceIds.tla TextSplitsBlocks, EveryCallShows).
const { Terminal } = xtermHeadless;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasmPath = resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-term.wasm"));
if (!supportsJspi()) process.exit(2);

const terminal = new Terminal({ cols: 100, rows: 40, allowProposedApi: true, scrollback: 3000 });
const config = new Map([["model", "test/tool-groups-model"], ["mode", "auto"]]);
const requestDecoder = new TextDecoder();
const stderrDecoder = new TextDecoder();
const catalog = {
  object: "list",
  data: [{ id: "test/tool-groups-model", type: "language", released: 1, tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }],
};

// Each prompt's replies: tool steps, then the final answer.
const turns = [
  {
    prompt: "first turn",
    replies: [
      { calls: ["one-a"] },
      { before: "between the steps", calls: ["one-b"] },
      { final: "first turn done" },
    ],
    screen: [
      "● 1 tool call · 1 command",
      "└ Ran echo one-a",
      "  between the steps",
      "● 1 tool call · 1 command",
      "└ Ran echo one-b",
      "  first turn done",
    ],
  },
  {
    prompt: "second turn",
    replies: [
      { calls: ["two-a", "two-b"] },
      { calls: ["two-c"] },
      { final: "second turn done" },
    ],
    screen: [
      "● 3 tool calls · 3 commands",
      "├ Ran echo two-a",
      "├ Ran echo two-b",
      "└ Ran echo two-c",
      "  second turn done",
    ],
  },
  {
    prompt: "third turn",
    replies: [
      { calls: ["three-a"], streamed: true },
      { calls: ["three-b"], streamed: true, after: "after the call" },
      { calls: ["three-c"], streamed: true },
      { final: "third turn done" },
    ],
    screen: [
      "● 2 tool calls · 2 commands",
      "├ Ran echo three-a",
      "└ Ran echo three-b",
      "  after the call",
      "● 1 tool call · 1 command",
      "└ Ran echo three-c",
      "  third turn done",
    ],
  },
];

const execCalls = [];
const workspace = {
  info: { version: 1, root: "/workspace", cwd: "/workspace", home: "/home/visitor", gitAvailable: false, ephemeral: true },
  permission: "allow-sandboxed",
  exec({ command }) {
    execCalls.push(command);
    return { stdout: `${command} done\n`, stderr: "", exitCode: 0 };
  },
};

function sse(events) {
  return new Response(
    `${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`,
    { headers: { "content-type": "text/event-stream" } },
  );
}

function reply(turn, index, step) {
  if (step.final) {
    return sse([
      { type: "text-delta", delta: step.final },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
    ]);
  }
  const events = step.before ? [{ type: "text-delta", delta: step.before }] : [];
  step.calls.forEach((label, call) => {
    const id = `${turn}-${index}-${call}`;
    const input = { action: "run", command: `echo ${label}` };
    if (step.streamed) {
      events.push(
        { type: "tool-input-start", id, toolName: "shell" },
        { type: "tool-input-delta", id, delta: JSON.stringify(input) },
        { type: "tool-input-end", id },
        { type: "tool-call", toolCallId: id, toolName: "shell" },
      );
    } else {
      events.push({ type: "tool-call", toolCallId: id, toolName: "shell", input });
    }
  });
  if (step.after) events.push({ type: "text-delta", delta: `\n${step.after}` });
  events.push({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } });
  return sse(events);
}

let requests = 0;
const fetch = async (_url, init = {}) => {
  if ((init.method || "GET") === "GET") {
    return new Response(JSON.stringify(catalog), { status: 200, headers: { "content-type": "application/json" } });
  }
  requests += 1;
  const body = JSON.parse(requestDecoder.decode(init.body));
  const prompt = body.prompt || [];
  let lastUser = -1;
  for (let index = prompt.length - 1; index >= 0; index -= 1) {
    if (prompt[index].role === "user") {
      lastUser = index;
      break;
    }
  }
  const userText = JSON.stringify(prompt[lastUser]?.content ?? "");
  const turn = turns.findIndex((entry) => userText.includes(entry.prompt));
  const index = prompt.slice(lastUser + 1).filter((message) => message.role === "assistant").length;
  const step = turns[turn]?.replies[index];
  if (!step) throw new Error(`unexpected gateway request: ${JSON.stringify(body)}`);
  return reply(turn, index, step);
};

let stderr = "";
const runtime = await createFxTerminal({
  backend: "wasm",
  wasm: await readFile(wasmPath),
  terminal: xtermAdapter(terminal),
  env: { AI_GATEWAY_API_KEY: "tool-groups-key" },
  fetch,
  configStore: { get(id) { return config.get(id) ?? null; }, set(id, value) { config.set(id, value); } },
  stderr(chunk) { stderr += stderrDecoder.decode(chunk, { stream: true }); },
  workspace,
});
const flush = () => new Promise((resolve) => terminal.write("", resolve));
const lines = () => {
  const out = [];
  for (let row = 0; row < terminal.buffer.active.length; row += 1) {
    out.push(terminal.buffer.active.getLine(row)?.translateToString(true).trimEnd() ?? "");
  }
  return out;
};
const timing = /\(↑\d+ ↓\d+\)$/;
async function waitFor(predicate, label) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    await flush();
    if (performance.now() >= deadline) throw new Error(`timed out waiting for ${label}:\n${stderr}\n${lines().join("\n")}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
// The rows under a prompt, up to the next prompt, without the timing line.
function screenUnder(prompt) {
  const shown = lines();
  const start = shown.indexOf(`┃ ${prompt}`);
  if (start < 0) return null;
  const rows = [];
  for (const line of shown.slice(start + 1)) {
    if (line.startsWith("┃")) break;
    if (line.trim() !== "" && !timing.test(line)) rows.push(line);
  }
  return rows;
}

await waitFor(() => lines().some((line) => line.includes("Run /help for commands")), "startup");
for (const turn of turns) {
  runtime.write(`${turn.prompt}\r`);
  const final = `  ${turn.replies.at(-1).final}`;
  await waitFor(() => {
    const shown = lines();
    const at = shown.indexOf(final);
    return at >= 0 && shown.slice(at + 1).some((line) => timing.test(line));
  }, turn.prompt);
}
await flush();
for (const turn of turns) {
  const shown = screenUnder(turn.prompt);
  if (JSON.stringify(shown) !== JSON.stringify(turn.screen)) {
    throw new Error(`${turn.prompt}: expected\n${turn.screen.join("\n")}\nbut the screen shows\n${(shown ?? ["(no prompt)"]).join("\n")}\n\nfull screen:\n${lines().join("\n")}`);
  }
}

runtime.write("/exit\r");
const exitCode = await Promise.race([
  runtime.exited,
  new Promise((_, reject) => setTimeout(() => reject(new Error("tool groups runtime exit timeout")), 5000)),
]);
if (exitCode !== 0) throw new Error(`fx-term exited with ${exitCode}`);
const expectedRequests = turns.reduce((sum, turn) => sum + turn.replies.length, 0);
if (requests !== expectedRequests) throw new Error(`gateway saw ${requests} requests, expected ${expectedRequests}`);
const expectedCalls = turns.flatMap((turn) => turn.replies.flatMap((step) => (step.calls ?? []).map((label) => `echo ${label}`)));
if (execCalls.join(",") !== expectedCalls.join(",")) throw new Error(`unexpected workspace exec calls: ${execCalls.join(",")}`);
console.log(`headless tool groups passed: ${turns.length} turns, ${requests} gateway requests; text between steps splits blocks, steps without text share one, and later turns show their own calls`);
