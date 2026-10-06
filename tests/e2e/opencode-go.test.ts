// Local HTTP dogfooding proves the actual executable without calling a paid provider.
import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";
import { cleanupIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { createGoProfile, goEnvironment, KEY, HEADER_VALUE, HOST } from "./fixtures/opencode-go-profile";

const LARGE_TOOL_CONTENT = "é".repeat(40 * 1024);
const CASES = [
  { name: "mixed-case session header", tool: "read_file", sessionHeader: "X-OpenCode-Session", prompt: "Read the fixture file and return the final answer." },
  { name: "read_file with empty reasoning replay", tool: "read_file", sessionHeader: "x-opencode-session", prompt: "Read the fixture file and return the final answer." },
  { name: "large UTF-8 write_file input", tool: "write_file", sessionHeader: "x-opencode-session", prompt: "Write the requested large fixture file and return the final answer." },
];
const RESULT = "go-native-local-ok";
const TOOL_FILENAME = "go-fixture-data.txt";
const TOOL_CONTENT = "go-real-tool-result";
const TOOL_ID = "go-read-call";
const TIMEOUT_MS = 20_000;
const STREAM_DELAY_MS = 2_000;
const TUI_TIMEOUT_MS = 10_000;
const STREAM_PREFIX = "go-live-first-chunk";
const CANCELLED_TEXT = "System: cancelled";
const STDERR_FILENAME = "go-tui-stderr.log";
const TUI_PROMPT = "Reply through the local Go fixture.";
const FOLLOWUP_PROMPT = "Make one fresh local Go request.";
const NEGATIVE_CASES = ["http-error", "redirect", "lost-finish", "aggregate-tools"].map(mode => ({ mode }));
const LARGE_ARGUMENT_BYTES = 600 * 1024;
const ERROR_BODY = "untrusted-go-error-body";
const tuiTest = tmuxAvailable() ? test : test.skip;
const homes: string[] = [];
afterEach(() => { for (const home of homes.splice(0)) cleanupIsolatedTestHome(home); });

// The server is a bounded in-process peer; every reply uses the public chat SSE shape.
function streamReply(chunks: unknown[]): Response {
  const body = chunks.map(chunk => "data: " + JSON.stringify(chunk) + "\n\n").join("") + "data: [DONE]\n\n";
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

describe("native OpenCode Go extension", () => {
  // The real HTTP worker must stop its socket before a fresh explicit user request can recover.
  tuiTest("real TTY sees early Go text, cancels HTTP and completes a fresh request", async () => {
    let requests = 0;
    let completed = 0;
    let cancelled = 0;
    const sessions: (string | null)[] = [];
    const timers = new Set<ReturnType<typeof setTimeout>>();
    const encoder = new TextEncoder();
    const server = Bun.serve({ hostname: HOST, port: 0, fetch(request) {
      requests++;
      sessions.push(request.headers.get("x-opencode-session"));
      return new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(encoder.encode("data: " + JSON.stringify({ choices: [{ index: 0, delta: { content: STREAM_PREFIX } }] }) + "\n\n"));
          const timer = setTimeout(() => {
            timers.delete(timer);
            completed++;
            controller.enqueue(encoder.encode("data: " + JSON.stringify({ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }) + "\n\ndata: [DONE]\n\n"));
            controller.close();
          }, STREAM_DELAY_MS);
          timers.add(timer);
        },
        cancel() { cancelled++; for (const timer of timers) clearTimeout(timer); timers.clear(); },
      }), { headers: { "content-type": "text/event-stream" } });
    } });
    const home = createGoProfile(server.port);
    homes.push(home);
    const stderrPath = join(home, STDERR_FILENAME);
    let session: TmuxSession | undefined;
    try {
      session = await TmuxSession.create({ cmd: FX_BIN, cwd: home, stderrPath, isolated: true,
        env: { ...goEnvironment(home), FX_SKIP_ONBOARDING: "0", AI_GATEWAY_API_KEY: "", VERCEL_OIDC_TOKEN: "" } });
      await session.waitForText("Run /help", TUI_TIMEOUT_MS);
      await session.sendText(TUI_PROMPT);
      await session.waitForText(STREAM_PREFIX, TUI_TIMEOUT_MS);
      expect(completed).toBe(0);
      await session.sendKeys("C-c");
      await session.waitForText(CANCELLED_TEXT, TUI_TIMEOUT_MS);
      expect(session.isAlive()).toBe(true);
      await session.sendText(FOLLOWUP_PROMPT);
      const pane = await session.waitForText(RESULT, TUI_TIMEOUT_MS);
      expect(requests).toBe(2);
      expect(completed).toBe(1);
      expect(cancelled).toBeGreaterThanOrEqual(1);
      expect(sessions[0]).toBeTruthy();
      expect(sessions[1]).toBe(sessions[0]);
      expect(pane.split(RESULT)).toHaveLength(2);
      expect(session.isAlive()).toBe(true);
      await session.sendText("/quit");
      await session.waitForSessionEnd(TUI_TIMEOUT_MS);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    } finally {
      await session?.kill();
      for (const timer of timers) clearTimeout(timer);
      server.stop(true);
    }
  }, TIMEOUT_MS);

  // HTTP failure, redirect and terminal-evidence loss must never trigger provider-side or host-side replay.
  test.each(NEGATIVE_CASES)("$mode remains terminal without secret disclosure or tool side effects", async ({ mode }) => {
    let requests = 0;
    let redirected = 0;
    const destination = Bun.serve({ hostname: HOST, port: 0, fetch() { redirected++; return new Response(RESULT); } });
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      requests++;
      if (mode === "redirect") return Response.redirect(`http://${HOST}:${destination.port}/stolen`);
      if (mode === "http-error") return new Response(ERROR_BODY + KEY, { status: 401 });
      if (mode === "lost-finish") return new Response("data: " + JSON.stringify({ choices: [{ index: 0, delta: { content: STREAM_PREFIX } }] }) + "\n\n", { headers: { "content-type": "text/event-stream" } });
      return streamReply([
        { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: TOOL_ID, function: { name: "write_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME), content: "x".repeat(LARGE_ARGUMENT_BYTES) }) } }] } }] },
        { choices: [{ index: 0, delta: { tool_calls: [{ index: 1, id: TOOL_ID + "-second", function: { name: "write_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME), content: "x".repeat(LARGE_ARGUMENT_BYTES) }) } }] } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
      ]);
    } });
    try {
      home = createGoProfile(server.port);
      homes.push(home);
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code).toBe(1);
      expect(JSON.parse(stdout).error).toBe("ExtensionRpcFailed");
      expect(requests).toBe(1);
      expect(redirected).toBe(0);
      expect(stdout + stderr).not.toContain(KEY);
      expect(stdout + stderr).not.toContain(ERROR_BODY);
      expect(() => readFileSync(join(home, TOOL_FILENAME))).toThrow();
    } finally { server.stop(true); destination.stop(true); }
  }, TIMEOUT_MS);

  test.each(CASES)("local endpoint receives max, scoped headers and $name", async scenario => {
    const requests: { body: any; authorization: string | null; session: string | null; header: string | null; path: string }[] = [];
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      const body = await request.json();
      requests.push({ body, authorization: request.headers.get("authorization"), session: request.headers.get("x-opencode-session"), header: request.headers.get("x-go-fixture"), path: new URL(request.url).pathname });
      if (requests.length === 1) return streamReply([
        { choices: [{ index: 0, delta: { reasoning_content: "", tool_calls: [{ index: 0, id: TOOL_ID, function: { name: scenario.tool, arguments: JSON.stringify({ path: join(home, TOOL_FILENAME), ...(scenario.tool === "write_file" ? { content: LARGE_TOOL_CONTENT } : {}) }) } }] } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }], usage: { prompt_tokens: 10, completion_tokens: 20 } },
      ]);
      return streamReply([
        { choices: [{ index: 0, delta: { content: RESULT } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 15, completion_tokens: 5 } },
      ]);
    } });
    try {
      home = createGoProfile(server.port, scenario.sessionHeader);
      homes.push(home);
      if (scenario.tool === "read_file") writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", scenario.prompt], {
        cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home),
      });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout: stdout.replaceAll(KEY, "[masked]"), stderr: stderr.replaceAll(KEY, "[masked]"), requests: requests.length })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(requests).toHaveLength(2);
      expect(requests.every(request => request.path === "/v1/chat/completions" && request.authorization === "Bearer " + KEY && request.header === HEADER_VALUE)).toBe(true);
      expect(requests[0].body.model).toBe("deepseek-flash");
      expect(requests[0].body.reasoning_effort).toBe("max");
      expect(requests[0].body.tool_choice).toBe("auto");
      expect(requests[0].body.parallel_tool_calls === undefined || typeof requests[0].body.parallel_tool_calls === "boolean").toBe(true);
      const readTool = requests[0].body.tools.find((tool: any) => tool.function.name === "read_file");
      expect(readTool.function.parameters.type).toBe("object");
      expect(readTool.function.parameters.properties.path).toBeTruthy();
      expect(requests[0].session).toBeTruthy();
      expect(requests[1].session).toBe(requests[0].session);
      expect(requests[1].body.messages.some((message: any) => message.role === "assistant" && message.reasoning_content === "")).toBe(true);
      expect(requests[1].body.messages.some((message: any) => message.role === "tool")).toBe(true);
      if (scenario.tool === "read_file") expect(requests[1].body.messages.some((message: any) => message.role === "tool" && message.content.includes(TOOL_CONTENT))).toBe(true);
      else expect(readFileSync(join(home, TOOL_FILENAME), "utf8")).toBe(LARGE_TOOL_CONTENT);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);
});
