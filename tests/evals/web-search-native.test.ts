/**
 * Live check of the native web search slot: with `web_search_backends` set to
 * `["native"]`, fx sends the model provider's own search tool, the provider
 * runs the search, and a follow-up turn that replays the search turn is
 * accepted. Google sends only sources, with no tool call, so its case checks
 * the sources and one turn.
 *
 * A loopback proxy records what fx sends and forwards it to AI Gateway
 * unchanged. Run it with `bun test web-search-native.test.ts`. It makes billed
 * calls.
 */
import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HAS_API_KEY, runFx } from "./eval-helpers";

const TIMEOUT = 180_000;
const GATEWAY = "https://ai-gateway.vercel.sh/v4/ai/language-model";

// A search the provider ran under the native tool's name.
function ranNativeSearch(stream: string): boolean {
  return stream.split("\n").some((line) =>
    line.includes("\"type\":\"tool-call\"") && line.includes("\"toolName\":\"native_web_search\"") &&
    line.includes("\"providerExecuted\":true"));
}

// Google's grounding search answers with sources only.
function sentSources(stream: string): boolean {
  return stream.split("\n").some((line) => line.includes("\"type\":\"source\""));
}

const CASES = [
  { model: "anthropic/claude-fable-5.2", nativeId: "anthropic.web_search_20250305", searched: ranNativeSearch, followUp: true },
  { model: "openai/gpt-5.6-luna", nativeId: "openai.web_search", searched: ranNativeSearch, followUp: true },
  { model: "google/gemini-2.5-flash", nativeId: "google.google_search", searched: sentSources, followUp: false },
];

function startProxy() {
  const bodies: string[] = [];
  const responses: string[] = [];
  const server = Bun.serve({
    port: 0,
    idleTimeout: 0,
    async fetch(req) {
      const body = await req.text();
      bodies.push(body);
      const headers = new Headers(req.headers);
      headers.delete("host");
      headers.delete("content-length");
      const res = await fetch(GATEWAY, { method: "POST", headers, body });
      const text = await res.text();
      responses.push(text);
      const out = new Headers(res.headers);
      out.delete("content-encoding");
      out.delete("content-length");
      return new Response(text, { status: res.status, headers: out });
    },
  });
  return { url: `http://127.0.0.1:${server.port}/v4/ai/language-model`, bodies, responses, stop: () => server.stop(true) };
}

function toolIds(body: string): string[] {
  try {
    const tools = JSON.parse(body).tools;
    return Array.isArray(tools) ? tools.map((tool: { id?: string; name?: string }) => tool.id ?? tool.name ?? "") : [];
  } catch {
    return [];
  }
}

describe.skipIf(!HAS_API_KEY)("eval: native web search", () => {
  for (const { model, nativeId, searched, followUp } of CASES) {
    test(
      `${model}: native search runs${followUp ? ", and a follow-up turn replays it" : ""}`,
      async () => {
        const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-native-search-")));
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(join(home, ".fx"), { recursive: true });
        mkdirSync(workspace, { recursive: true });
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({ web_search_backends: ["native"], session_titles: false, permission: { web_search: { "*": "allow" } } }),
        );
        const proxy = startProxy();
        const env = {
          HOME: home,
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_CHAT_URL: proxy.url,
          FX_WEB_SEARCH_BACKEND: undefined,
          FX_MODEL: model,
          FX_SOUND: "0",
        };
        try {
          const first = await runFx(
            ["ask", "--auto", "--json", "Use web search once to find the latest stable Zig release. Reply in one line with the version and one source URL."],
            { cwd: workspace, env, timeoutMs: TIMEOUT },
          );
          const firstBodies = [...proxy.bodies];
          expect(firstBodies.map(toolIds).some((ids) => ids.includes(nativeId))).toBe(true);
          expect(first.code).toBe(0);
          expect(proxy.responses.some(searched)).toBe(true);
          if (!followUp) return;

          const second = await runFx(
            ["ask", "--auto", "--json", "--resume", "last", "Without searching again: which version did you find? One line."],
            { cwd: workspace, env, timeoutMs: TIMEOUT },
          );
          const secondBodies = proxy.bodies.slice(firstBodies.length);
          expect(second.code).toBe(0);
          // The follow-up request carries turn one's search call and result.
          expect(secondBodies.some((body) => body.includes("\"toolName\":\"native_web_search\""))).toBe(true);
        } finally {
          proxy.stop();
          rmSync(root, { recursive: true, force: true });
        }
      },
      TIMEOUT * 2,
    );
  }
});
