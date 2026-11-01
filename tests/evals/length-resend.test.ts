/**
 * Live check that each provider takes and answers the resend of a reply its
 * output limit cut off.
 *
 * A proxy in front of AI Gateway answers the turn's first model request itself
 * with a reply that spent its whole limit on reasoning before a tool call it
 * cut off, the way a model stuck in its reasoning stops. Every other request
 * goes to the real model, so the resend fx sends next, without the cut-off call
 * and at low effort, has to be accepted and answered by the provider. Run one
 * model with `EVAL_MODEL=<id> bun test length-resend.test.ts`, or every model
 * in `EVAL_MODELS` with `bun run eval:matrix`. It makes billed calls.
 */
import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EVAL_MODEL, HAS_API_KEY, runFx } from "./eval-helpers";
import { DEFAULT_UPSTREAM } from "./prompt-cache-ab";

const SENTINEL = "cut-call-ran.txt";
const ANSWER = "RESEND_OK";

function cutOffReply(): Response {
  const events = [
    { type: "reasoning-start", id: "spent" },
    { type: "reasoning-delta", id: "spent", delta: "Thinking until the output limit runs out." },
    { type: "reasoning-end", id: "spent" },
    { type: "tool-input-start", id: "cut_call", toolName: "shell" },
    {
      type: "tool-call",
      toolCallId: "cut_call",
      toolName: "shell",
      input: { request: { action: "run", command: `printf ran > ${SENTINEL}` } },
    },
    {
      type: "finish",
      finishReason: { unified: "length", raw: "length" },
      usage: { inputTokens: { total: 1 }, outputTokens: { total: 128_000 } },
    },
  ];
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
}

interface AgentRequest {
  body: any;
  status: number;
}

/** Cuts off the first agent request and forwards everything else upstream. */
function startCuttingProxy(upstream = DEFAULT_UPSTREAM) {
  const agentRequests: AgentRequest[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    async fetch(req) {
      const url = new URL(req.url);
      const raw = req.method === "GET" || req.method === "HEAD" ? undefined : await req.text();
      const agent = req.method === "POST" && url.pathname.endsWith("/language-model") &&
        !raw?.includes("Generate a short title");
      if (agent && agentRequests.length === 0) {
        agentRequests.push({ body: JSON.parse(raw!), status: 200 });
        return cutOffReply();
      }
      const headers = new Headers(req.headers);
      for (const name of ["host", "content-length", "accept-encoding"]) headers.delete(name);
      const response = await fetch(upstream + url.pathname + url.search, { method: req.method, headers, body: raw });
      if (agent) agentRequests.push({ body: JSON.parse(raw!), status: response.status });
      const outHeaders = new Headers(response.headers);
      for (const name of ["content-encoding", "content-length"]) outHeaders.delete(name);
      return new Response(response.body, { status: response.status, headers: outHeaders });
    },
  });
  return { url: `http://127.0.0.1:${server.port}`, agentRequests, stop: () => server.stop(true) };
}

describe.skipIf(!HAS_API_KEY)(`eval: length-cut resend (${EVAL_MODEL})`, () => {
  test("a reply cut off by its output limit is resent at low effort and answered", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-length-resend-"));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(home, { recursive: true });
    mkdirSync(workspace, { recursive: true });
    const proxy = startCuttingProxy();
    try {
      const result = await runFx(
        ["ask", "--json", "--auto", "--no-save", "--", `Reply with exactly ${ANSWER} and nothing else.`],
        {
          cwd: workspace,
          env: {
            HOME: home,
            FX_SOUND: "0",
            FX_MODEL: EVAL_MODEL,
            FX_AUTO_UPGRADE: "0",
            FX_SKIP_ONBOARDING: "1",
            FX_GATEWAY_CHAT_URL: `${proxy.url}/v4/ai/language-model`,
            FX_GATEWAY_BASE_URL: proxy.url,
          },
          timeoutMs: 180_000,
        },
      );
      if (result.code !== 0) throw new Error(`fx exited ${result.code}\n${result.stdout}\n${result.stderr}`);
      expect(JSON.parse(result.stdout).final_output).toContain(ANSWER);
      expect(existsSync(join(workspace, SENTINEL))).toBe(false);

      // The cut-off reply, then the resend the provider took and answered.
      expect(proxy.agentRequests.length).toBeGreaterThanOrEqual(2);
      const [first, resend] = proxy.agentRequests;
      expect(first!.body.reasoning).toBeUndefined();
      expect(resend!.status).toBe(200);
      expect(resend!.body.reasoning).toBe("low");
      expect(JSON.stringify(resend!.body)).not.toContain(SENTINEL);
      expect(`${result.stdout}\n${result.stderr}`).toContain("low effort.");
    } finally {
      proxy.stop();
      rmSync(root, { recursive: true, force: true });
    }
  }, 200_000);
});
