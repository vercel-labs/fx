// Web search slots: fx sends one search tool per request from the
// web_search_backends order, moves to the next slot when AI Gateway refuses
// a Gateway-executed search tool for the team, and ends with no search tool.
import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN, runFx } from "../evals/eval-helpers";
import { fakeGatewayTitleDefault, TITLE_GENERATION_MARKER } from "./tmux-helpers";

const TIMEOUT = 30_000;
const PROMPT = "Search the web for the latest Zig release.";
const GATEWAY_SEARCH_IDS = ["gateway.exa_search", "gateway.parallel_search", "gateway.perplexity_search"];
const NATIVE_IDS = ["anthropic.web_search_20250305", "openai.web_search", "google.google_search"];

function sse(events: object[]) {
  const body = events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

function answer(text = "Zig 0.17.1 is the latest release.") {
  return sse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: { inputTokens: { total: 11 }, outputTokens: { total: 13 } },
    },
  ]);
}

// The body AI Gateway sends when the team may not use a Gateway-executed tool.
function toolsNotAllowed(ids: string[]) {
  const vendors = ids.map((id) => id.replace("gateway.", "").replace("_search", "")).join(", ");
  const message = `Gateway-executed tool(s) are not available for this team: ${ids.join(", ")}. They send request content to vendor(s) outside this team's permitted provider set (${vendors}). Remove the tool(s) to proceed.`;
  return Response.json({ error: { message, type: "invalid_request_error" } }, { status: 400 });
}

type Decide = (body: string, index: number) => Response | Promise<Response>;

function startGateway(model: string, decide: Decide) {
  const requests: string[] = [];
  const server = Bun.serve({
    port: 0,
    idleTimeout: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/coding-agent/v1/models") {
        return Response.json({ data: [{ id: model, type: "language", tags: ["tool-use"] }] });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      if (body.includes(TITLE_GENERATION_MARKER)) return fakeGatewayTitleDefault();
      requests.push(body);
      return decide(body, requests.length - 1);
    },
  });
  return {
    baseUrl: `http://127.0.0.1:${server.port}`,
    chatUrl: `http://127.0.0.1:${server.port}/v4/ai/language-model`,
    requests,
    stop: () => server.stop(true),
  };
}

// A contained team: every listed Gateway search tool the request carries is refused.
function refusing(blocked: string[] = GATEWAY_SEARCH_IDS): Decide {
  return (body) => {
    const carried = blocked.filter((id) => carriesTool(body, id));
    return carried.length > 0 ? toolsNotAllowed(carried) : answer();
  };
}

function carriesTool(body: string, id: string): boolean {
  return searchTools(body).includes(id);
}

function searchTools(body: string): string[] {
  try {
    const tools = JSON.parse(body).tools;
    if (!Array.isArray(tools)) return [];
    return tools
      .map((tool: { id?: string }) => tool.id ?? "")
      .filter((id: string) => GATEWAY_SEARCH_IDS.includes(id) || NATIVE_IDS.includes(id));
  } catch {
    return [];
  }
}

function makeRoot(settings: Record<string, unknown>) {
  const root = realpathSync(createIsolatedTestHome());
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ ...settings, permission: { web_search: { "*": "allow" } } }));
  return { root, home, workspace };
}

function fxEnv(home: string, gateway: ReturnType<typeof startGateway>, model: string) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-e2e-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TEST_GATEWAY_CREDITS_URL: undefined,
    FX_WEB_SEARCH_BACKEND: undefined,
    FX_MODEL: model,
    FX_SOUND: "0",
  };
}

async function ask(model: string, decide: Decide, settings: Record<string, unknown> = {}) {
  const { root, home, workspace } = makeRoot(settings);
  const gateway = startGateway(model, decide);
  try {
    const result = await runFx(["ask", "--auto", "--json", "--no-save", PROMPT], {
      cwd: workspace,
      env: fxEnv(home, gateway, model),
      timeoutMs: TIMEOUT,
    });
    return { result, requests: [...gateway.requests] };
  } finally {
    gateway.stop();
    cleanupIsolatedTestHome(root);
  }
}

function definedEnv(env: Record<string, string | undefined>) {
  return Object.fromEntries(Object.entries(env).filter(([, value]) => value !== undefined)) as Record<string, string>;
}

describe("web search slots", () => {
  test(
    "a refused exa slot moves to native search for each provider family",
    async () => {
      for (const [model, nativeId] of [
        ["anthropic/claude-sonnet-5", "anthropic.web_search_20250305"],
        ["openai/gpt-5", "openai.web_search"],
        ["google/gemini-2.5-flash", "google.google_search"],
      ]) {
        const { result, requests } = await ask(model!, refusing());
        expect({ model, tools: requests.map(searchTools) }).toEqual({ model, tools: [["gateway.exa_search"], [nativeId!]] });
        expect(result.code).toBe(0);
      }
    },
    TIMEOUT * 3,
  );

  test(
    "a model without native search walks every Gateway slot and ends with no search tool",
    async () => {
      const { result, requests } = await ask("xai/grok-4", refusing());
      expect(requests.map(searchTools)).toEqual([
        ["gateway.exa_search"],
        ["gateway.parallel_search"],
        ["gateway.perplexity_search"],
        [],
      ]);
      expect(result.code).toBe(0);
    },
    TIMEOUT,
  );

  test(
    "a refusal that names two tools blocks both",
    async () => {
      const { result, requests } = await ask("xai/grok-4", (body) =>
        carriesTool(body, "gateway.exa_search") ? toolsNotAllowed(["gateway.exa_search", "gateway.parallel_search"]) : answer(),
      );
      expect(requests.map(searchTools)).toEqual([["gateway.exa_search"], ["gateway.perplexity_search"]]);
      expect(result.code).toBe(0);
    },
    TIMEOUT,
  );

  test(
    "a refusal that names 10000 tools, exa first, still moves the slot",
    async () => {
      const many = ["gateway.exa_search", ...Array.from({ length: 9999 }, (_, i) => `gateway.tool_${i}`)];
      const { result, requests } = await ask("xai/grok-4", (body) =>
        carriesTool(body, "gateway.exa_search") ? toolsNotAllowed(many) : answer(),
      );
      expect(requests.map(searchTools)).toEqual([["gateway.exa_search"], ["gateway.parallel_search"]]);
      expect(result.code).toBe(0);
    },
    TIMEOUT,
  );

  test(
    "other refusals and failures move no slot",
    async () => {
      const cases: Array<[string, Decide]> = [
        ["a refusal of an unknown tool", () => toolsNotAllowed(["gateway.tako_search"])],
        ["another 400", () => Response.json({ error: { message: "invalid tool schema", type: "invalid_request_error" } }, { status: 400 })],
        ["a 400 that is not JSON", () => new Response("Bad Request", { status: 400 })],
      ];
      for (const [name, decide] of cases) {
        const { result, requests } = await ask("anthropic/claude-sonnet-5", decide);
        expect({ name, tools: requests.map(searchTools) }).toEqual({ name, tools: [["gateway.exa_search"]] });
        expect({ name, failed: result.code !== 0 }).toEqual({ name, failed: true });
      }
    },
    TIMEOUT * 3,
  );

  test(
    "a 500 keeps the slot and retries after the usual wait",
    async () => {
      const { result, requests } = await ask("anthropic/claude-sonnet-5", (_, index) =>
        index === 0 ? new Response("upstream down", { status: 500 }) : answer(),
      );
      expect(requests.map(searchTools)).toEqual([["gateway.exa_search"], ["gateway.exa_search"]]);
      expect(result.code).toBe(0);
    },
    TIMEOUT,
  );

  test(
    "web_search_backends sets the order",
    async () => {
      const cases: Array<[unknown, string, string[][]]> = [
        [["parallel", "exa"], "xai/grok-4", [["gateway.parallel_search"]]],
        [["EXA"], "xai/grok-4", [["gateway.exa_search"]]],
        [["native", "exa"], "google/gemini-2.5-flash", [["google.google_search"]]],
        [["native"], "xai/grok-4", [[]]],
        [[], "anthropic/claude-sonnet-5", [[]]],
      ];
      for (const [order, model, tools] of cases) {
        const { result, requests } = await ask(model, refusing([]), { web_search_backends: order });
        expect({ order, tools: requests.map(searchTools) }).toEqual({ order, tools });
        expect(result.code).toBe(0);
      }
    },
    TIMEOUT * 5,
  );

  test(
    "a bad web_search_backends is reported and the default order applies",
    async () => {
      const cases: unknown[] = [["bing"], ["exa", "exa"], ["exa", "native", "parallel", "perplexity", "exa"], "exa"];
      for (const order of cases) {
        const { result, requests } = await ask("anthropic/claude-sonnet-5", refusing([]), { web_search_backends: order });
        expect({ order, tools: requests.map(searchTools) }).toEqual({ order, tools: [["gateway.exa_search"]] });
        expect(result.code).toBe(0);
        expect(result.stderr).toContain("invalid_web_search_backends");
        expect(result.stderr).toContain("web_search_backends must be an array of at most 4 different names from exa, native, parallel, and perplexity");
      }
    },
    TIMEOUT * 4,
  );

  test(
    "a recorded native search stream is read and replayed on the next turn",
    async () => {
      const model = "anthropic/claude-sonnet-5";
      const recorded = readFileSync(join(import.meta.dirname, "fixtures", "web-search-native-anthropic.sse"), "utf8");
      const { root, home, workspace } = makeRoot({ web_search_backends: ["native"] });
      const gateway = startGateway(model, (body) => {
        if (carriesTool(body, "gateway.exa_search")) return toolsNotAllowed(["gateway.exa_search"]);
        if (body.includes("srvtoolu_example01")) return answer("You asked about Zig 0.17.1.");
        return new Response(recorded, { headers: { "content-type": "text/event-stream" } });
      });
      try {
        const first = await runFx(["ask", "--auto", "--json", PROMPT], { cwd: workspace, env: fxEnv(home, gateway, model), timeoutMs: TIMEOUT });
        expect(gateway.requests.map(searchTools)).toEqual([["anthropic.web_search_20250305"]]);
        expect(first.code).toBe(0);
        // The recorded answer, as the model wrote it when the stream was saved.
        expect(JSON.parse(first.stdout.trim()).final_output).toContain("Zig 0.16.0");

        const second = await runFx(["ask", "--auto", "--json", "--resume", "last", "Which version was it?"], {
          cwd: workspace,
          env: fxEnv(home, gateway, model),
          timeoutMs: TIMEOUT,
        });
        expect(second.code).toBe(0);
        const replay = gateway.requests.at(-1)!;
        expect(replay).toContain("\"toolName\":\"native_web_search\"");
        expect(replay).toContain("srvtoolu_example01");
      } finally {
        gateway.stop();
        cleanupIsolatedTestHome(root);
      }
    },
    TIMEOUT * 2,
  );

  test(
    "fx killed during the native resend relearns the block once after resume",
    async () => {
      const model = "anthropic/claude-sonnet-5";
      const { root, home, workspace } = makeRoot({});
      let hold: () => void = () => {};
      const held = new Promise<void>((resolve) => (hold = resolve));
      const gateway = startGateway(model, (body, index) => {
        if (carriesTool(body, "gateway.exa_search")) return toolsNotAllowed(["gateway.exa_search"]);
        if (index === 1) {
          hold();
          return new Promise<Response>(() => {});
        }
        return answer();
      });
      try {
        const child = spawn(FX_BIN, ["ask", "--auto", "--json", PROMPT], {
          cwd: workspace,
          env: { ...process.env, NO_COLOR: "1", ...definedEnv(fxEnv(home, gateway, model)) },
          stdio: ["ignore", "pipe", "pipe"],
        });
        const exited = new Promise<void>((resolve) => child.on("exit", () => resolve()));
        const waited = await Promise.race([held.then(() => true), exited.then(() => false), Bun.sleep(TIMEOUT / 2).then(() => false)]);
        expect({ native_resend_held: waited, tools: gateway.requests.map(searchTools) }).toEqual({
          native_resend_held: true,
          tools: [["gateway.exa_search"], ["anthropic.web_search_20250305"]],
        });
        child.kill("SIGKILL");
        await exited;

        const resumed = await runFx(["ask", "--auto", "--json", "--resume", "last", "Go on."], {
          cwd: workspace,
          env: fxEnv(home, gateway, model),
          timeoutMs: TIMEOUT,
        });
        expect(gateway.requests.map(searchTools)).toEqual([
          ["gateway.exa_search"],
          ["anthropic.web_search_20250305"],
          ["gateway.exa_search"],
          ["anthropic.web_search_20250305"],
        ]);
        expect(resumed.code).toBe(0);
        const last = gateway.requests.at(-1)!;
        expect(last.split(PROMPT).length - 1).toBe(1);
      } finally {
        gateway.stop();
        cleanupIsolatedTestHome(root);
      }
    },
    TIMEOUT * 2,
  );
});
