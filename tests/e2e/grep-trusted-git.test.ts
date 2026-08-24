import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";

const TIMEOUT = 30_000;
const MODEL = "openai/gpt-5";
const NEEDLE = "TRUSTED_GIT_E2E_NEEDLE";

// Workspace grep resolves Git from a fixed absolute allowlist and never from
// PATH. These tests drive the built binary with a `git` planted earlier on
// PATH: the grep tool must not run it, and the control must, so an ineffective
// PATH override cannot be mistaken for a guard that held.

type GatewayResponse = Response | ((body: string) => Response);

function sse(events: object[]) {
  return new Response(
    events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
}

function toolCall(id: string, name: string, input: object) {
  return sse([
    { type: "tool-call", toolCallId: id, toolName: name, input },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
}

function finalText(text: string) {
  return sse([
    { type: "text-delta", id: "answer_1", delta: text },
    {
      type: "finish",
      finishReason: { unified: "stop", raw: "stop" },
      usage: { inputTokens: { total: 11 }, outputTokens: { total: 13 } },
    },
  ]);
}

function permissionDecision() {
  return toolCall("permission_decision_1", "permission_decision", {
    risk: "medium",
    decision: "clear",
    rationale: "test fixture",
  });
}

function startFakeGateway(responses: GatewayResponse[]) {
  const requests: { body: string }[] = [];
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/coding-agent/v1/models") {
        return Response.json({
          data: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
        });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      if (body.includes('"permission_decision"')) return permissionDecision();
      requests.push({ body });
      const response = responses.shift();
      if (!response) return new Response("unexpected Gateway request", { status: 500 });
      return typeof response === "function" ? response(body) : response;
    },
  });
  return {
    baseUrl: `http://127.0.0.1:${server.port}`,
    chatUrl: `http://127.0.0.1:${server.port}/v3/ai/language-model`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [contentText(value.text), contentText(value.value), contentText(value.content)].join("");
  }
  return "";
}

function toolResultOutput(body: string, callId: string): string {
  const request = JSON.parse(body) as { prompt: Array<{ content: unknown }> };
  const parts = request.prompt.flatMap((message) =>
    Array.isArray(message.content) ? message.content : []
  ) as Array<Record<string, unknown>>;
  const result = parts.find(
    (part) => part.type === "tool-result" && part.toolCallId === callId,
  );
  if (!result) throw new Error(`Missing tool result for ${callId}`);
  return contentText(result.output);
}

function createRoot() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-trusted-git-e2e-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const fakeBin = join(root, "fakebin");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  mkdirSync(fakeBin, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  const marker = join(root, "planted-git.log");

  // Exits 1 so a caller reading it as "no matches" still records the run.
  writeFileSync(
    join(fakeBin, "git"),
    `#!/bin/sh\nprintf '%s\\n' "$*" >> "${marker}"\nexit 1\n`,
  );
  chmodSync(join(fakeBin, "git"), 0o755);

  writeFileSync(join(workspace, "tracked.txt"), `${NEEDLE} tracked\n`);
  const git = (args: string[]) =>
    execFileSync("/usr/bin/git", args, { cwd: workspace, stdio: "ignore" });
  git(["init"]);
  git(["config", "user.email", "e2e@example.com"]);
  git(["config", "user.name", "e2e"]);
  git(["add", "tracked.txt"]);
  git(["commit", "-m", "seed"]);

  return {
    root,
    home: realpathSync(home),
    workspace: realpathSync(workspace),
    fakeBin,
    marker,
    plantedRuns() {
      if (!existsSync(marker)) return [];
      return readFileSync(marker, "utf8").split("\n").filter((line) => line.length > 0);
    },
  };
}

function envFor(root: ReturnType<typeof createRoot>, gateway: ReturnType<typeof startFakeGateway>) {
  return {
    HOME: root.home,
    PATH: `${root.fakeBin}:${process.env.PATH ?? ""}`,
    AI_GATEWAY_API_KEY: "fake-trusted-git-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_MODEL: MODEL,
    FX_AUTO_UPGRADE: "0",
  };
}

async function runOneToolCall(
  root: ReturnType<typeof createRoot>,
  id: string,
  name: string,
  input: object,
) {
  const gateway = startFakeGateway([toolCall(id, name, input), finalText("done")]);
  try {
    const result = await runFx(
      ["ask", "--auto", "--json", "--no-save", "Execute the requested tool once."],
      { cwd: root.workspace, env: envFor(root, gateway), timeoutMs: TIMEOUT },
    );
    if (result.code !== 0) {
      throw new Error(`fx exited ${result.code}\n${result.stdout}\n${result.stderr}`);
    }
    expect(gateway.requests).toHaveLength(2);
    return toolResultOutput(gateway.requests[1]!.body, id);
  } finally {
    gateway.stop();
  }
}

describe("workspace grep Git resolution", () => {
  test(
    "a git planted on PATH runs for the terminal tool but never for grep_files",
    async () => {
      const root = createRoot();
      try {
        // Control. Without it, "grep did not run the plant" cannot be told
        // apart from a PATH override that never reached the child.
        const control = await runOneToolCall(root, "control_1", "terminal", {
          action: "exec",
          command: "git --version",
        });
        expect(control).not.toContain("Not executed");
        expect(root.plantedRuns()).toEqual(["--version"]);

        rmSync(root.marker, { force: true });

        const output = await runOneToolCall(root, "grep_1", "grep_files", {
          pattern: NEEDLE,
        });
        // The search worked, so the guard is not passing by doing nothing.
        expect(output).toContain("tracked.txt");
        expect(output).not.toContain("Not executed");
        // And it reached no part of the planted binary.
        expect(root.plantedRuns()).toEqual([]);
      } finally {
        rmSync(root.root, { recursive: true, force: true });
      }
    },
    TIMEOUT * 3,
  );
});
