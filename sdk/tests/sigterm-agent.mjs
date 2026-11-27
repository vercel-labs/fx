#!/usr/bin/env node
// A child process for test-durable-sigterm.mjs: it runs one durable turn
// whose host tool waits, so the test can send SIGTERM while the turn runs.
// Usage: node sdk/tests/sigterm-agent.mjs <mode> <dir> <port> <addon>
import { createInterface } from "node:readline";
import { createFxAgent } from "../node.js";
import { local } from "../durable/local.mjs";

if (process.argv[2] === "app-listener") {
  process.on("SIGTERM", () => { setTimeout(() => process.exit(7), 2000); });
}
const [mode, dir, port, addon] = process.argv.slice(2);

const loopbackFetch = (input, init) => {
  const url = new URL(String(input?.url ?? input));
  const method = String(init?.method ?? input?.method ?? "GET").toUpperCase();
  if (url.hostname === "ai-gateway.vercel.sh" && method === "GET") {
    return fetch(`http://127.0.0.1:${port}${url.pathname}${url.search}`, init);
  }
  return fetch(input, init);
};

const wait = {
  name: "wait",
  description: "Waits for the test",
  idempotent: false,
  inputSchema: { type: "object", properties: {} },
  execute: (_input, { signal }) => new Promise((resolveWait, rejectWait) => {
    process.stdout.write("tool-started\n");
    signal.addEventListener("abort", () => rejectWait(new Error("aborted")), { once: true });
    if (mode !== "short") return;
    const lines = createInterface({ input: process.stdin });
    lines.on("line", (line) => {
      if (line !== "go") return;
      lines.close();
      resolveWait("waited");
    });
  }),
};

const agent = createFxAgent({
  durability: local({ dir }),
  backend: "native",
  nativeAddon: addon,
  fetch: loopbackFetch,
  apiKey: "sigterm-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "journal/model",
  tools: [wait],
  ...(mode === "off" ? { handOffOnSigterm: false } : {}),
});
if (mode === "short") {
  // Registered after libfx's listener, so it prints once libfx has asked the
  // turn to yield.
  process.once("SIGTERM", () => console.log("sigterm-seen"));
}
const turn = agent.session().prompt("use the tool");
const { sessionId } = await turn.accepted;
console.log(`session ${sessionId}`);
try {
  for await (const _ of turn) {}
} catch {
  // The parent stops this process mid-turn, so the turn may end in an error.
}
