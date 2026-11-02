import { describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import { sessionDir } from "./saved-sessions";

const TIMEOUT = 60_000;
const OUTER_MODEL = "anthropic/claude-sonnet-4.6";
const LIVE_URL = "https://example.com/";
const LIVE_ROBOTS_URL = "https://vercel.com/robots.txt";
const LIVE_MODELS_URL = "https://ai-gateway.vercel.sh/coding-agent/v1/models";
const LIVE_BINARY_URL =
  "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf";

type GatewayRequest = {
  body: string;
  headers: Headers;
};

function sse(events: object[], done = true) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") +
      (done ? "data: [DONE]\n\n" : ""),
    { headers: { "content-type": "text/event-stream" } },
  );
}

function outerWebFetchCall(url = LIVE_URL) {
  return sse([
    {
      type: "tool-call",
      toolCallId: "fetch_live_1",
      toolName: "web_fetch",
      input: {
        url,
      },
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

function outerText(text: string) {
  return sse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 11 },
        outputTokens: { total: 13 },
      },
    },
  ]);
}

async function reserveLoopbackPort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("failed to reserve loopback port"));
        return;
      }
      const port = address.port;
      server.close(() => resolve(port));
    });
    server.on("error", reject);
  });
}

async function startFakeGateway(responses: Response[]) {
  const requests: GatewayRequest[] = [];
  const port = await reserveLoopbackPort();
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/coding-agent/v1/models") {
        return Response.json({
          data: [{ id: OUTER_MODEL, type: "language", tags: ["tool-use"] }],
        });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      requests.push({ body: await req.text(), headers: req.headers });
      return responses.shift() ?? new Response("unexpected request", { status: 500 });
    },
  });

  return {
    chatUrl: `http://127.0.0.1:${server.port}/v4/ai/language-model`,
    baseUrl: `http://127.0.0.1:${server.port}`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function createIsolatedRoot(domains = ["example.com"]) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-web-fetch-live-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      model: OUTER_MODEL,
      permission: {
        web_fetch: Object.fromEntries(domains.map((domain) => [`domain:${domain}`, "allow"])),
      },
    }),
  );
  return { root, home, workspace: realpathSync(workspace) };
}

function fakeGatewayEnv(
  root: ReturnType<typeof createIsolatedRoot>,
  gateway: Awaited<ReturnType<typeof startFakeGateway>>,
) {
  return {
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-live-web-fetch-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: OUTER_MODEL,
  };
}

describe.skipIf(process.env.FX_WEB_FETCH_LIVE !== "1")("live web_fetch public URL", () => {
  // These mutable endpoints are operational probes, not deterministic HTTP
  // framing proof. The transport/framing contract is covered by Zig fixtures.
  for (const probe of [
    { url: LIVE_ROBOTS_URL, domain: "vercel.com", label: "robots" },
    { url: LIVE_MODELS_URL, domain: "ai-gateway.vercel.sh", label: "models" },
  ] as const) {
    test(
      `${probe.label} endpoint returns non-empty content through the fresh binary`,
      async () => {
        const root = createIsolatedRoot([probe.domain]);
        const traceLog = join(root.root, `${probe.label}-trace.log`);
        const gateway = await startFakeGateway([
          outerWebFetchCall(probe.url),
          outerText(`Final: ${probe.label} endpoint fetched successfully.`),
        ]);
        try {
          const result = await runFx(
            ["ask", "--auto", "--json", "--no-save", `Fetch ${probe.url} exactly once.`],
            {
              cwd: root.workspace,
              env: {
                ...fakeGatewayEnv(root, gateway),
                FX_TRACE_LOG: traceLog,
                FX_TRACE_SCOPES: "tool",
              },
              timeoutMs: TIMEOUT,
            },
          );

          if (result.code !== 0) {
            throw new Error(
              `fx exited ${result.code}\nstdout: ${result.stdout.slice(-4000)}\nstderr: ${result.stderr.slice(-4000)}`,
            );
          }
          const json = JSON.parse(result.stdout.trim()) as {
            output: string;
            tool_calls: Array<{
              name: string;
              status: string;
              web_fetch?: {
                url: string;
                bytes: number;
                status: number;
              };
            }>;
          };
          const fetches = json.tool_calls.filter((call) => call.name === "web_fetch");
          expect(fetches).toHaveLength(1);
          if (fetches[0].status !== "success") {
            const trace = existsSync(traceLog) ? readFileSync(traceLog, "utf8") : "";
            throw new Error(
              `web_fetch probe failed\nstdout: ${result.stdout.slice(-4000)}\nstderr: ${result.stderr.slice(-4000)}\ntrace: ${trace.slice(-8000)}`,
            );
          }
          expect(fetches[0].status).toBe("success");
          expect(fetches[0].web_fetch?.url).toBe(probe.url);
          expect(fetches[0].web_fetch?.status).toBe(200);
          expect(fetches[0].web_fetch?.bytes).toBeGreaterThan(0);
          expect(json.tool_calls.every((call) => call.name === "web_fetch")).toBe(true);
          expect(result.stderr).toContain("Fetching ");
          expect(result.stderr).toContain("Converting ");
          expect(result.stderr).not.toContain("Extracting ");
          expect(result.stderr).not.toContain("panic");
          expect(result.stderr).not.toContain("abort");
          expect(result.stderr).not.toContain("python");
          expect(result.stderr).not.toContain("curl");
          expect(gateway.requests).toHaveLength(2);
          expect(json.output).toContain(`${probe.label} endpoint`);

          console.log(
            `[live-web-fetch-probe] label=${probe.label} url=${fetches[0].web_fetch!.url} bytes=${fetches[0].web_fetch!.bytes}`,
          );
        } finally {
          gateway.stop();
          rmSync(root.root, { recursive: true, force: true });
        }
      },
      TIMEOUT,
    );
  }

  test(
    "authorized public HTML URL reports progress and cache metadata",
    async () => {
      const root = createIsolatedRoot();
      const gateway = await startFakeGateway([
        outerWebFetchCall(),
        outerWebFetchCall(),
        outerText("Final: Example Domain was fetched and cached."),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "--no-save", "Fetch and then refetch https://example.com/."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        if (result.code !== 0) {
          throw new Error(
            `fx exited ${result.code}\nstdout: ${result.stdout.slice(-4000)}\nstderr: ${result.stderr.slice(-4000)}`,
          );
        }
        const json = JSON.parse(result.stdout.trim()) as {
          output: string;
          tool_calls: Array<{
            name: string;
            status: string;
            web_fetch?: {
              url: string;
              bytes: number;
              status: number;
              duration_ms: number;
              cache_hit: boolean;
              artifact: string;
            };
          }>;
        };
        const fetches = json.tool_calls.filter((call) => call.name === "web_fetch");
        expect(fetches).toHaveLength(2);
        expect(fetches[0].status).toBe("success");
        expect(fetches[0].web_fetch?.url).toBe(LIVE_URL);
        expect(fetches[0].web_fetch?.status).toBe(200);
        expect(fetches[0].web_fetch?.bytes).toBeGreaterThan(0);
        expect(fetches[0].web_fetch?.cache_hit).toBe(false);
        expect(fetches[1].status).toBe("success");
        expect(fetches[1].web_fetch?.cache_hit).toBe(true);
        expect(fetches[1].web_fetch?.artifact).toBe("none");
        expect(result.stderr).toContain("Fetching ");
        expect(result.stderr).toContain("Converting ");
        expect(result.stderr).not.toContain("Extracting ");
        expect(gateway.requests).toHaveLength(3);
        expect(gateway.requests[2].body).toContain("<cache_hit>true</cache_hit>");
        expect(json.output).toContain("Example Domain");

        console.log(
          `[live-web-fetch] url=${fetches[0].web_fetch!.url} bytes=${fetches[0].web_fetch!.bytes} first_cache_hit=${fetches[0].web_fetch!.cache_hit} second_cache_hit=${fetches[1].web_fetch!.cache_hit}`,
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "authorized public binary URL stores a durable artifact without raw bytes in session JSON",
    async () => {
      const root = createIsolatedRoot(["www.w3.org"]);
      const gateway = await startFakeGateway([
        outerWebFetchCall(LIVE_BINARY_URL),
        outerText("Final: PDF artifact metadata was recorded."),
      ]);
      try {
        const result = await runFx(
          ["ask", "--auto", "--json", "Fetch the public PDF artifact."],
          {
            cwd: root.workspace,
            env: fakeGatewayEnv(root, gateway),
            timeoutMs: TIMEOUT,
          },
        );

        if (result.code !== 0) {
          throw new Error(
            `fx exited ${result.code}\nstdout: ${result.stdout.slice(-4000)}\nstderr: ${result.stderr.slice(-4000)}`,
          );
        }
        const json = JSON.parse(result.stdout.trim()) as {
          session_id: string;
          tool_calls: Array<{
            name: string;
            status: string;
            web_fetch?: {
              url: string;
              bytes: number;
              status: number;
              duration_ms: number;
              cache_hit: boolean;
              artifact: string;
            };
          }>;
        };
        const fetch = json.tool_calls.find((call) => call.name === "web_fetch");
        expect(fetch?.status).toBe("success");
        expect(fetch?.web_fetch?.url).toBe(LIVE_BINARY_URL);
        expect(fetch?.web_fetch?.status).toBe(200);
        expect(fetch?.web_fetch?.bytes).toBeGreaterThan(0);
        expect(fetch?.web_fetch?.cache_hit).toBe(false);
        expect(fetch?.web_fetch?.artifact).toBe("stored");

        // The download is a session blob, named in the log by its handle,
        // artifact-<hash>.<ext> (D44, D49).
        const sessionLog = readFileSync(join(sessionDir(root.home, json.session_id), "log.jsonl"), "utf8");
        const files = [...new Set(sessionLog.match(/artifact-[0-9a-f]{64}\.[a-z0-9]+/g) ?? [])];
        expect(files).toHaveLength(1);
        const artifactPath = join(sessionDir(root.home, json.session_id), "blobs", files[0]!.slice("artifact-".length, "artifact-".length + 64));
        const artifactBytes = readFileSync(artifactPath);
        expect(artifactBytes.length).toBe(fetch!.web_fetch!.bytes);
        expect(artifactBytes.subarray(0, 5).toString()).toBe("%PDF-");

        const artifactBase64Prefix = artifactBytes.toString("base64").slice(0, 16);
        expect(sessionLog).not.toContain("%PDF-");
        expect(sessionLog).not.toContain(artifactBase64Prefix);
        expect(sessionLog).not.toContain("Store the file and summarize safe metadata only.");
        const detail = await runFx(["session", "--id", json.session_id, "--json"], {
          cwd: root.workspace,
          env: fakeGatewayEnv(root, gateway),
          timeoutMs: TIMEOUT,
        });
        expect(detail.code).toBe(0);
        expect(detail.stderr).toBe("");
        expect(detail.stdout).toContain(files[0]!);
        expect(detail.stdout).toContain("<artifact_handle>");
        expect(detail.stdout).not.toContain("%PDF-");
        expect(detail.stdout).not.toContain(artifactBase64Prefix);
        expect(detail.stdout).not.toContain("Store the file and summarize safe metadata only.");
        expect(result.stderr).toContain("Fetching ");
        expect(result.stderr).toContain("Converting ");
        expect(result.stderr).not.toContain("Extracting ");
        expect(gateway.requests).toHaveLength(2);

        console.log(
          `[live-web-fetch-binary] url=${fetch!.web_fetch!.url} bytes=${fetch!.web_fetch!.bytes} artifact=${files[0]}`,
        );
      } finally {
        gateway.stop();
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
