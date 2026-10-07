// Local HTTP dogfooding proves the actual executable without calling a paid provider.
import { afterEach, describe, expect, test } from "bun:test";
import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";
import { cleanupIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { createGoProfile, goEnvironment, KEY, HEADER_VALUE, HOST, EXECUTABLE } from "./fixtures/opencode-go-profile";
import { PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY } from "./fixtures/extension-profile";

const IMAGE_FIXTURE = join(import.meta.dir, "fixtures", "placeholder-logo.png");
const IMAGE_FILENAME = "go-image.png";
const SECOND_IMAGE_FILENAME = "go-second-image.png";
const CHANGED_SOURCE = "source changed after capture";
const IMAGE_PROMPT = "Describe the attached local fixture image.";
// A valid tool payload must survive more than one bounded host handoff batch.
const LARGE_TOOL_CONTENT = "é".repeat(200 * 1024);
const CASES = [
  { name: "mixed-case session header", tool: "read_file", sessionHeader: "X-OpenCode-Session", prompt: "Read the fixture file and return the final answer." },
  { name: "read_file with empty reasoning replay", tool: "read_file", sessionHeader: "x-opencode-session", prompt: "Read the fixture file and return the final answer." },
  { name: "large UTF-8 write_file input", tool: "write_file", sessionHeader: "x-opencode-session", prompt: "Write the requested large fixture file and return the final answer." },
];
const RESULT = "go-native-local-ok";
const RPC_VERSION = 1;
const JSONRPC_VERSION = "2.0";
const RPC_TIMEOUT_MS = 5_000;
const SCHEMA_OUTPUT_LIMIT = 128;
const SCHEMA_SESSION = "go-schema-conversation";
const SCHEMA_PROVIDER = "opencode-go";
const SCHEMA_MODEL = "deepseek-v4.1-flash";
// A failed prepare must never leave a stream handle that can transmit a credential.
const RPC_ROUTE_CASES = [
  { name: "selected Chat route", wire: SCHEMA_MODEL, admitted: true },
  { name: "unknown route", wire: "unselected-go-model", admitted: false },
];
const UNPREPARED_HANDLE = "prepared-unknown";
const SCHEMA_BASE_PREFIX = "http://";
const SCHEMA_BASE_PATH = "/v1";
const SCHEMA_PROMPT = "Return the fixture answer as JSON.";
const SCHEMA = { type: "object", properties: { answer: { type: "string" } }, required: ["answer"], additionalProperties: false };
const SCHEMA_FORMAT = { name: "fixture_answer", description: "Return a local fixture answer", schema: SCHEMA };
const SCHEMA_OUTPUT = JSON.stringify({ answer: "go-schema-ok" });
const EXECUTABLE_PERMISSION = "extension_execute";
const SETTINGS_RELATIVE_PATH = ".fx/settings.json";
const EXPLICIT_ACTIVATION_CASES = [{ mode: "ask" }, { mode: "auto" }];
const INPUT_TOKENS = 41;
const OUTPUT_TOKENS = 17;
const SESSION_RELATIVE_DIRECTORY = ".fx/sessions";
const SESSION_FILENAME = "session.json";
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
const GO_MANIFEST_FILENAME = "extension.json";
// The curated choices must preserve native tool continuation without borrowing another provider's preferences.
const CURATED_MODELS = [
  { id: "deepseek-flash", wire: "deepseek-v4.1-flash", effort: "max" },
  { id: "deepseek-v4-pro", wire: "deepseek-v4-pro", effort: "max" },
  { id: "kimi-k3", wire: "kimi-k3", effort: "max" },
  { id: "glm-5.3-flash", wire: "glm-5.3-flash", effort: "max" },
  { id: "mimo-v2.6-flash", wire: "mimo-v2.6-flash", effort: undefined },
];
const CURATED_PROVIDER_PREFIX = "opencode-go/";
const BUILTIN_PREFERENCES = { gateway: "openai/gpt-5.6-sol", codex: "gpt-6.1-sol", grok: "grok-4.7" };
const ENDPOINT_CASES = [
  { name: "bracketed IPv6", hostname: "::1", authority: "[::1]", basePath: "/v1", query: "", expectedTarget: "/v1/chat/completions" },
  { name: "mixed-case localhost", hostname: HOST, authority: "LOCALHOST", basePath: "/v1", query: "", expectedTarget: "/v1/chat/completions" },
  { name: "escaped path and query", hostname: HOST, authority: HOST, basePath: "/tenant%2Fone/v1/", query: "?api-version=fixture%2Freview&route=%2Ftenant", expectedTarget: "/tenant%2Fone/v1/chat/completions?api-version=fixture%2Freview&route=%2Ftenant" },
];
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
  // Real host requests guard against catalog entries that discover correctly but lose tools or encode unsupported effort.
  test.each(CURATED_MODELS)("curated $id discovers and completes native tools", async model => {
    const bodies: any[] = [];
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      bodies.push(await request.json());
      if (bodies.length === 1) return streamReply([{ choices: [{ index: 0, delta: {
        tool_calls: [{ index: 0, id: TOOL_ID, function: { name: "read_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME) }) } }],
      }, finish_reason: "tool_calls" }] }]);
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }]);
    } });
    home = createGoProfile(server.port);
    homes.push(home);
    const settingsPath = join(home, SETTINGS_RELATIVE_PATH);
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    settings.models = { ...BUILTIN_PREFERENCES, extension: CURATED_PROVIDER_PREFIX + model.id };
    writeFileSync(settingsPath, JSON.stringify(settings));
    writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
    try {
      const discovery = Bun.spawn([FX_BIN, "models", "--json"], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [catalog, discoveryError, discoveryCode] = await Promise.all([new Response(discovery.stdout).text(), new Response(discovery.stderr).text(), discovery.exited]);
      expect(discoveryCode, discoveryError).toBe(0);
      expect(JSON.parse(catalog).ids).toEqual(CURATED_MODELS.map(choice => CURATED_PROVIDER_PREFIX + choice.id));
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(bodies).toHaveLength(2);
      for (const body of bodies) {
        expect(body.model).toBe(model.wire);
        expect(body.reasoning_effort).toBe(model.effort);
      }
      expect(bodies[1].messages.some((message: any) => message.role === "tool" && message.content.includes(TOOL_CONTENT))).toBe(true);
      const finalSettings = JSON.parse(readFileSync(settingsPath, "utf8"));
      for (const [provider, preference] of Object.entries(BUILTIN_PREFERENCES)) expect(finalSettings.models[provider]).toBe(preference);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Native request delivery protects accepted endpoints from adapter-specific URI rewriting.
  test.each(ENDPOINT_CASES)("configured loopback endpoint preserves $name", async scenario => {
    const targets: string[] = [];
    const server = Bun.serve({ hostname: scenario.hostname, port: 0, fetch(request) {
      const url = new URL(request.url);
      targets.push(url.pathname + url.search);
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }]);
    } });
    const home = createGoProfile(server.port);
    homes.push(home);
    const manifestPath = join(home, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY, GO_MANIFEST_FILENAME);
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.providers[0].base_url = `${SCHEMA_BASE_PREFIX}${scenario.authority}:${server.port}${scenario.basePath}${scenario.query}`;
    writeFileSync(manifestPath, JSON.stringify(manifest));
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr, targets })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(targets).toEqual([scenario.expectedTarget]);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Exact host-action authority must not disable native permission policy for file tools.
  test.each(EXPLICIT_ACTIVATION_CASES)("explicit native executable allow works under $mode", async ({ mode }) => {
    let requests = 0;
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      requests++;
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }]);
    } });
    const home = createGoProfile(server.port);
    homes.push(home);
    const settingsPath = join(home, SETTINGS_RELATIVE_PATH);
    const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
    settings.permission = { [EXECUTABLE_PERMISSION]: "allow" };
    writeFileSync(settingsPath, JSON.stringify(settings));
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: { ...goEnvironment(home), FX_PERMISSION_MODE: mode } });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(requests).toBe(1);
      expect(stdout + stderr).not.toContain(KEY);
      expect(stderr).not.toContain("YOLO enabled");
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Native CLI does not expose response_format; the shipped provider RPC is its public boundary.
  test.each(RPC_ROUTE_CASES)("native provider $name guards HTTP and structured output", async scenario => {
    const bodies: any[] = [];
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      bodies.push(await request.json());
      return streamReply([{ choices: [{ index: 0, delta: { content: SCHEMA_OUTPUT }, finish_reason: "stop" }] }]);
    } });
    const child = Bun.spawn([EXECUTABLE], { stdin: "pipe", stdout: "pipe", stderr: "pipe", env: {} });
    const reader = child.stdout.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let requestId = 0;
    async function rpc(method: string, params: unknown): Promise<any> {
      const id = ++requestId;
      child.stdin.write(JSON.stringify({ jsonrpc: JSONRPC_VERSION, id, method, params }) + "\n");
      const reply = async () => {
        for (;;) {
          const newline = buffer.indexOf("\n");
          if (newline >= 0) {
            const frame = JSON.parse(buffer.slice(0, newline));
            buffer = buffer.slice(newline + 1);
            if (frame.id !== id) continue;
            if (frame.error) throw new Error(frame.error.message);
            return frame.result;
          }
          const next = await reader.read();
          if (next.done) throw new Error("Provider exited before reply");
          buffer += decoder.decode(next.value, { stream: true });
        }
      };
      let timer: ReturnType<typeof setTimeout> | undefined;
      try { return await Promise.race([reply(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Provider RPC deadline")), RPC_TIMEOUT_MS); })]); }
      finally { clearTimeout(timer); }
    }
    try {
      const initialized = await rpc("initialize", { version: RPC_VERSION });
      expect(initialized.version).toBe(RPC_VERSION);
      const prepare = rpc("provider.prepare", { provider: { id: SCHEMA_PROVIDER, base_url: SCHEMA_BASE_PREFIX + HOST + ":" + server.port + SCHEMA_BASE_PATH }, model: { wire_id: scenario.wire }, request: {
        messages: [{ role: "user", content: SCHEMA_PROMPT, images: [], tool_call_id: null, tool_calls: [], provider_state_json: null }],
        functions: [], additional_functions: [], dynamic_functions: [], reasoning_effort: "max", max_output_tokens: SCHEMA_OUTPUT_LIMIT,
        tool_choice: "none", parallel_tool_calls: null, response_format: SCHEMA_FORMAT,
      } });
      if (scenario.admitted) {
        const prepared = await prepare;
        const completed = await rpc("provider.stream", { handle: prepared.handle, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION });
        expect(JSON.parse(completed.content)).toEqual(JSON.parse(SCHEMA_OUTPUT));
        expect(bodies).toHaveLength(1);
        expect(bodies[0].response_format).toEqual({ type: "json_schema", json_schema: { ...SCHEMA_FORMAT, strict: true } });
        expect(bodies[0].max_tokens).toBe(SCHEMA_OUTPUT_LIMIT);
        expect(bodies[0].reasoning_effort).toBe("max");
      } else {
        await expect(prepare).rejects.toThrow("Provider request failed");
        await expect(rpc("provider.stream", { handle: UNPREPARED_HANDLE, credential: KEY, headers: { "x-opencode-session": SCHEMA_SESSION }, session_id: SCHEMA_SESSION })).rejects.toThrow("Provider request failed");
        expect(bodies).toHaveLength(0);
      }
      await rpc("shutdown", {});
      child.stdin.end();
      expect(await child.exited).toBe(0);
      expect(await new Response(child.stderr).text()).toBe("");
    } finally {
      if (child.exitCode === null) child.kill();
      await child.exited;
      await reader.cancel();
      server.stop(true);
    }
  }, TIMEOUT_MS);

  // Token facts must survive the actual native session writer, not only RPC decoding.
  test("Go usage persists in native saved session totals", async () => {
    const server = Bun.serve({ hostname: HOST, port: 0, fetch() {
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }], usage: { prompt_tokens: INPUT_TOKENS, completion_tokens: OUTPUT_TOKENS } }]);
    } });
    const home = createGoProfile(server.port);
    homes.push(home);
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", TUI_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      const output = JSON.parse(stdout);
      expect(output.output).toBe(RESULT);
      expect(output.session_id).not.toBe("");
      const saved = JSON.parse(readFileSync(join(home, SESSION_RELATIVE_DIRECTORY, output.session_id, SESSION_FILENAME), "utf8"));
      expect(saved.total_input_tokens).toBe(INPUT_TOKENS);
      expect(saved.total_output_tokens).toBe(OUTPUT_TOKENS);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

  // Native snapshot validation must precede provider projection; no local path reaches HTTP.
  test("verified image becomes an OpenAI data URL without exposing snapshot paths", async () => {
    const bodies: any[] = [];
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      bodies.push(await request.json());
      if (bodies.length === 1) {
        writeFileSync(join(home, IMAGE_FILENAME), CHANGED_SOURCE);
        return streamReply([{ choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: TOOL_ID, function: { name: "read_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME) }) } }] }, finish_reason: "tool_calls" }] }]);
      }
      return streamReply([{ choices: [{ index: 0, delta: { content: RESULT }, finish_reason: "stop" }] }]);
    } });
    home = createGoProfile(server.port);
    homes.push(home);
    writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
    const image = join(home, IMAGE_FILENAME);
    copyFileSync(IMAGE_FIXTURE, image);
    const second = join(home, SECOND_IMAGE_FILENAME);
    copyFileSync(IMAGE_FIXTURE, second);
    try {
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", "--image", image, "--image", second, IMAGE_PROMPT], { cwd: home, stdout: "pipe", stderr: "pipe", env: goEnvironment(home) });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code, JSON.stringify({ stdout, stderr })).toBe(0);
      expect(JSON.parse(stdout).output).toBe(RESULT);
      expect(bodies).toHaveLength(2);
      for (const body of bodies) {
        const parts = body.messages.find((message: any) => Array.isArray(message.content)).content;
        expect(parts.some((part: any) => part.type === "text" && part.text.includes(IMAGE_PROMPT))).toBe(true);
        const urls = parts.filter((part: any) => part.type === "image_url").map((part: any) => part.image_url.url);
        expect(urls).toEqual(Array.from({ length: 2 }, () => "data:image/png;base64," + readFileSync(IMAGE_FIXTURE).toString("base64")));
      }
      expect(readFileSync(image, "utf8")).toBe(CHANGED_SOURCE);
      expect(JSON.stringify(bodies)).not.toContain(image);
      expect(JSON.stringify(bodies)).not.toContain(second);
      expect(JSON.stringify(bodies)).not.toContain("snapshot_path");
    } finally { server.stop(true); }
  }, TIMEOUT_MS);

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
      expect(requests[0].body.model).toBe(SCHEMA_MODEL);
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
