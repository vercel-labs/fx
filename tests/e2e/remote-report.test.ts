import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { createReportServer, readReports } from "../../apps/report-server/server";

const TIMEOUT = 20_000;
const MODEL = "anthropic/claude-sonnet-4.6";
const SECRET_FILE_CONTENT = "REMOTE_REPORT_FILE_SECRET_7f3a";
const SECRET_PROMPT = "REMOTE_REPORT_PROMPT_SECRET_91c2";

function sse(events: object[]) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
}

function toolCallResponse() {
  return sse([
    { type: "tool-call", toolCallId: "read_1", toolName: "read_file", input: { path: "notes.txt" } },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage: { inputTokens: { total: 21 }, outputTokens: { total: 4 } } },
  ]);
}

function finalResponse() {
  return sse([
    { type: "text-delta", id: "answer_1", delta: "Done reading." },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 30 }, outputTokens: { total: 5 } } },
  ]);
}

function startFakeGateway(responses: Response[]) {
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/coding-agent/v1/models") {
        return Response.json({ data: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      await req.text();
      return responses.shift() ?? new Response("unexpected request", { status: 500 });
    },
  });
  return {
    baseUrl: `http://127.0.0.1:${server.port}`,
    chatUrl: `http://127.0.0.1:${server.port}/v3/ai/language-model`,
    stop: () => server.stop(true),
  };
}

function createRoot() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-remote-report-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ permission: {} }));
  writeFileSync(join(workspace, "notes.txt"), `${SECRET_FILE_CONTENT}\n`);
  return { root, home, workspace: realpathSync(workspace) };
}

function env(root: ReturnType<typeof createRoot>, gateway: ReturnType<typeof startFakeGateway>, extra: Record<string, string | undefined>) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-e2e-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_E2E_GATEWAY_CREDITS_URL: undefined,
    FX_MODEL: MODEL,
    FX_REPORT_URL: undefined,
    FX_REPORT_TOKEN: undefined,
    ...extra,
  };
}

describe("remote report", () => {
  test(
    "fx ask posts one redacted batch to FX_REPORT_URL on exit",
    async () => {
      const root = createRoot();
      const gateway = startFakeGateway([toolCallResponse(), finalResponse()]);
      const dataFile = join(root.root, "reports.jsonl");
      const reports = createReportServer({ dataFile, token: "e2e-token" });
      try {
        const result = await runFx(["ask", "--auto", "--json", "--no-save", `Read notes.txt ${SECRET_PROMPT}`], {
          cwd: root.workspace,
          env: env(root, gateway, {
            FX_REPORT_URL: `http://127.0.0.1:${reports.port}/v1/reports`,
            FX_REPORT_TOKEN: "e2e-token",
          }),
          timeoutMs: TIMEOUT,
        });
        expect(result.code).toBe(0);
        expect(result.stderr.toLowerCase()).not.toContain("report");
        expect(JSON.parse(result.stdout.trim()).output).toContain("Done reading.");

        const stored = readReports(dataFile);
        expect(stored).toHaveLength(1);
        const report = stored[0];
        expect(report.schema).toBe(1);
        expect(report.fx_version).toMatch(/^\d+\.\d+\.\d+/);
        expect(report.network.filter((call) => call.kind === "gateway" && call.model === MODEL)).toHaveLength(2);
        expect(report.tools).toContainEqual(expect.objectContaining({ name: "read_file", outcome: "succeeded" }));

        const raw = JSON.stringify(report);
        expect(raw).not.toContain(SECRET_FILE_CONTENT);
        expect(raw).not.toContain(SECRET_PROMPT);
        expect(raw).not.toContain("notes.txt");
        expect(raw).not.toContain(root.workspace);

        const summary = await fetch(`http://127.0.0.1:${reports.port}/v1/summary`, {
          headers: { authorization: "Bearer e2e-token" },
        }).then((res) => res.json());
        expect(summary.reports).toBe(1);
        expect(summary.network[MODEL].calls).toBe(2);
        expect(summary.tools.read_file.calls).toBe(1);
      } finally {
        reports.stop(true);
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "unreachable report endpoint does not fail or noticeably delay fx ask",
    async () => {
      const root = createRoot();
      const gateway = startFakeGateway([finalResponse()]);
      try {
        const started = Date.now();
        const result = await runFx(["ask", "--auto", "--json", "--no-save", "Say done."], {
          cwd: root.workspace,
          env: env(root, gateway, { FX_REPORT_URL: "http://127.0.0.1:9/v1/reports" }),
          timeoutMs: TIMEOUT,
        });
        expect(result.code).toBe(0);
        expect(result.stderr.toLowerCase()).not.toContain("report");
        expect(Date.now() - started).toBeLessThan(10_000);
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "server rejects reports without the configured token",
    async () => {
      const root = createRoot();
      const reports = createReportServer({ dataFile: join(root.root, "reports.jsonl"), token: "right" });
      try {
        const res = await fetch(`http://127.0.0.1:${reports.port}/v1/reports`, {
          method: "POST",
          headers: { authorization: "Bearer wrong", "content-type": "application/json" },
          body: "{}",
        });
        expect(res.status).toBe(401);
      } finally {
        reports.stop(true);
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
