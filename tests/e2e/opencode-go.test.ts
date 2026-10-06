// Local HTTP dogfooding proves the actual executable without calling a paid provider.
import { afterEach, describe, expect, test } from "bun:test";
import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { cleanupIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import { createExtensionProfile, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY } from "./fixtures/extension-profile";

const SOURCE = join(import.meta.dir, "..", "..", "extensions", "fx-opencode-go");
const EXECUTABLE = join(dirname(FX_BIN), "fx-opencode-go");
const MODEL = "opencode-go/deepseek-flash";
const KEY = "local-go-fixture-key";
const HEADER_VALUE = "local-go-fixture-header";
const RESULT = "go-native-local-ok";
const TOOL_FILENAME = "go-fixture-data.txt";
const TOOL_CONTENT = "go-real-tool-result";
const TOOL_ID = "go-read-call";
const MANIFEST_FILENAME = "extension.json";
const CATALOG_FILENAME = "models.json";
const SETTINGS_FILENAME = "settings.json";
const HOST = "127.0.0.1";
const TIMEOUT_MS = 20_000;
const homes: string[] = [];
afterEach(() => { for (const home of homes.splice(0)) cleanupIsolatedTestHome(home); });

// The server is a bounded in-process peer; every reply uses the public chat SSE shape.
function streamReply(chunks: unknown[]): Response {
  const body = chunks.map(chunk => "data: " + JSON.stringify(chunk) + "\n\n").join("") + "data: [DONE]\n\n";
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

describe("native OpenCode Go extension", () => {
  test("local endpoint receives max effort, scoped headers and real tool/reasoning replay", async () => {
    const manifest = JSON.parse(readFileSync(join(SOURCE, MANIFEST_FILENAME), "utf8"));
    const requests: { body: any; authorization: string | null; session: string | null; header: string | null; path: string }[] = [];
    let home = "";
    const server = Bun.serve({ hostname: HOST, port: 0, async fetch(request) {
      const body = await request.json();
      requests.push({ body, authorization: request.headers.get("authorization"), session: request.headers.get("x-opencode-session"), header: request.headers.get("x-go-fixture"), path: new URL(request.url).pathname });
      if (requests.length === 1) return streamReply([
        { choices: [{ index: 0, delta: { reasoning_content: "", tool_calls: [{ index: 0, id: TOOL_ID, function: { name: "read_file", arguments: JSON.stringify({ path: join(home, TOOL_FILENAME) }) } }] } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }], usage: { prompt_tokens: 10, completion_tokens: 20 } },
      ]);
      return streamReply([
        { choices: [{ index: 0, delta: { content: RESULT } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 15, completion_tokens: 5 } },
      ]);
    } });
    try {
      manifest.entrypoint = "provider";
      manifest.providers[0].base_url = `http://${HOST}:${server.port}/v1`;
      manifest.providers[0].headers["x-go-fixture"] = { source: "env", name: "FX_GO_TEST_HEADER" };
      home = createExtensionProfile({ version: 1, extensions: [{ path: FIXTURE_EXTENSION_DIRECTORY }] }, manifest);
      homes.push(home);
      const extension = join(home, PROFILE_DIRECTORY, FIXTURE_EXTENSION_DIRECTORY);
      copyFileSync(EXECUTABLE, join(extension, manifest.entrypoint));
      copyFileSync(join(SOURCE, CATALOG_FILENAME), join(extension, CATALOG_FILENAME));
      writeFileSync(join(home, PROFILE_DIRECTORY, SETTINGS_FILENAME), JSON.stringify({ provider: "extension", models: { extension: MODEL }, effort: "max", auto_upgrade: false }));
      writeFileSync(join(home, TOOL_FILENAME), TOOL_CONTENT);
      const child = Bun.spawn([FX_BIN, "ask", "--json", "--no-save", "Read the fixture file and return the final answer."], {
        cwd: home, stdout: "pipe", stderr: "pipe", env: { ...process.env, HOME: home, AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined,
          FX_MODEL: undefined, FX_PERMISSION_MODE: "yolo", OPENCODE_API_KEY: KEY, FX_GO_TEST_HEADER: HEADER_VALUE, FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1" },
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
      expect(requests[1].body.messages.some((message: any) => message.role === "tool" && message.content.includes(TOOL_CONTENT))).toBe(true);
      expect(stdout + stderr).not.toContain(KEY);
    } finally { server.stop(true); }
  }, TIMEOUT_MS);
});
