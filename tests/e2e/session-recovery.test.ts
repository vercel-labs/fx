import { describe, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;

function sessionFileSnapshot(sessionDir: string): Record<string, string> {
  return Object.fromEntries(
    readdirSync(sessionDir, { withFileTypes: true })
      .filter((entry) => entry.isFile())
      .sort((left, right) => left.name.localeCompare(right.name))
      .map((entry) => [
        entry.name,
        readFileSync(join(sessionDir, entry.name)).toString("base64"),
      ]),
  );
}

class LineClient {
  private readonly proc: ChildProcess;
  private buffer = "";
  private lines: string[] = [];
  private stderr = "";

  constructor(proc: ChildProcess) {
    this.proc = proc;
    proc.stdout!.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString();
      const split = this.buffer.split("\n");
      this.buffer = split.pop() ?? "";
      this.lines.push(...split.filter((line) => line.trim().length > 0));
    });
    proc.stderr!.on("data", (chunk: Buffer) => {
      this.stderr += chunk.toString();
    });
  }

  send(value: object): void {
    this.proc.stdin!.write(JSON.stringify(value) + "\n");
  }

  async read(timeoutMs = TIMEOUT): Promise<any> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const line = this.lines.shift();
      if (line) return JSON.parse(line);
      await Bun.sleep(20);
    }
    const stderr = this.stderr.trim();
    throw new Error(
      `timed out waiting for ACP response (exit=${this.proc.exitCode ?? "running"}, signal=${this.proc.signalCode ?? "none"})${stderr ? `\nstderr:\n${stderr}` : ""}`,
    );
  }

  kill(): void {
    this.proc.kill("SIGKILL");
  }
}

function startAcp(cwd: string, home: string, extraEnv: Record<string, string> = {}): LineClient {
  return new LineClient(spawn(FX_BIN, ["acp"], {
    cwd,
    env: {
      ...process.env,
      HOME: home,
      AI_GATEWAY_API_KEY: "e2e-placeholder",
      VERCEL_OIDC_TOKEN: "",
      NO_COLOR: "1",
      ...extraEnv,
    },
    stdio: ["pipe", "pipe", "pipe"],
  }));
}

async function waitForPath(path: string, timeoutMs = 3_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path)) return;
    await Bun.sleep(20);
  }
  throw new Error(`timed out waiting for ${path}`);
}

async function createSession(cwd: string, home: string): Promise<string> {
  const client = startAcp(cwd, home);
  try {
    client.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } });
    expect((await client.read()).result).toBeDefined();
    client.send({ jsonrpc: "2.0", id: 2, method: "session/new", params: { mcpServers: [] } });
    const response = await client.read();
    expect(response.result?.sessionId).toBeDefined();
    return response.result.sessionId;
  } finally {
    client.kill();
  }
}

function sessionIdsFromHome(home: string): string[] {
  const sessionsRoot = join(home, ".fx", "sessions");
  return readdirSync(sessionsRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name !== "latest")
    .map((entry) => entry.name);
}

function writeConnectionSettings(
  home: string,
  selected: "connection-a" | "connection-b",
  endpointA: string,
  endpointB: string,
  includeA = true,
  credentialRefB = "ai_gateway_api_key",
): void {
  const profiles = [
    ...(includeA
      ? [{
        id: "connection-a",
        display_name: "Connection A",
        adapter_id: "vercel_ai_gateway",
        endpoint: endpointA,
        protocol: "vercel_ai_gateway",
        credential_ref: "ai_gateway_api_key",
        remembered_model: "model-a",
        permission_review_model: "reviewer-a",
      }]
      : []),
    {
      id: "connection-b",
      display_name: "Connection B",
      adapter_id: "vercel_ai_gateway",
      endpoint: endpointB,
      protocol: "vercel_ai_gateway",
      credential_ref: credentialRefB,
      remembered_model: "model-b",
      permission_review_model: "reviewer-b",
    },
  ];
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      permission_mode: "auto",
      connections: { selected, profiles },
    }) + "\n",
    { mode: 0o600 },
  );
}

function unavailableResponse(): Response {
  return new Response(
    JSON.stringify({ error: { message: "provider temporarily unavailable" } }),
    {
      status: 503,
      headers: {
        "content-type": "application/json",
        "retry-after": "0",
      },
    },
  );
}

function startRejectingOAuth() {
  const requests: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      requests.push(`${request.method} ${new URL(request.url).pathname}`);
      return new Response("selected connection must not refresh", { status: 500 });
    },
  });
  return {
    issuerUrl: `http://127.0.0.1:${server.port}`,
    requests,
    stop() {
      server.stop(true);
    },
  };
}

function writeExpiredFxLogin(home: string, issuer: string): void {
  writeFileSync(
    join(home, ".fx", "auth.json"),
    JSON.stringify({
      version: 1,
      issuer,
      client_id: "test-client",
      access_token: "expired-access-token",
      refresh_token: "seeded-refresh-token",
      expires_at_ms: Date.now() - 60_000,
      scope: "openid offline_access use:ai-gateway",
      token_type: "Bearer",
    }) + "\n",
    { mode: 0o600 },
  );
}

function gatewayTrafficCount(gateway: ReturnType<typeof startFakeGateway>): number {
  return gateway.requests.length +
    gateway.classifierRequests.length +
    gateway.generationRequests.length +
    gateway.modelRequests.length;
}

describe("session recovery", () => {
  test(
    "fresh binary continues a persisted checkpoint without touching the new default connection",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-session-route-restart-"));
      const gatewayA = startFakeGateway([
        ...Array.from({ length: 10 }, () => unavailableResponse()),
        fakeGatewayFinalText("resumed on A"),
      ], {
        models: [{ id: "model-a", type: "language", tags: ["tool-use"] }],
      });
      const gatewayB = startFakeGateway([
        fakeGatewayFinalText("must not use B"),
      ], {
        models: [{ id: "model-b", type: "language", tags: ["tool-use"] }],
      });
      const oauthB = startRejectingOAuth();
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(join(home, ".fx"), { recursive: true });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        writeConnectionSettings(
          home,
          "connection-a",
          gatewayA.chatUrl,
          gatewayB.chatUrl,
        );
        const env = {
          HOME: home,
          AI_GATEWAY_API_KEY: "route-only-secret",
          VERCEL_OIDC_TOKEN: undefined,
          FX_MODEL: undefined,
          FX_GATEWAY_BASE_URL: gatewayA.baseUrl,
          FX_GATEWAY_CHAT_URL: undefined,
          FX_AUTO_UPGRADE: "0",
          NO_COLOR: "1",
        };

        const first = await runFx(
          ["ask", "--auto", "--json", "Pause this turn on connection A."],
          { cwd: workspaceRoot, env },
        );
        expect(first.code).toBe(1);
        const firstResult = JSON.parse(first.stdout.trim());
        expect(firstResult.recovery).toEqual(expect.objectContaining({
          state: "paused",
          cause: "provider_unavailable",
          attempt: 10,
          attempt_limit: 10,
          durable: true,
        }));
        const sessionId = firstResult.session_id as string;
        expect(sessionId.length).toBeGreaterThan(0);
        expect(gatewayA.requests).toHaveLength(10);
        expect(gatewayTrafficCount(gatewayB)).toBe(0);

        const sessionDir = join(home, ".fx", "sessions", sessionId);
        const pausedDurableText = readdirSync(sessionDir)
          .filter((name) => name.endsWith(".json") || name.endsWith(".jsonl"))
          .map((name) => readFileSync(join(sessionDir, name), "utf8"))
          .join("\n");
        expect(pausedDurableText).toContain('"connection_id":"connection-a"');
        expect(pausedDurableText).toContain('"adapter_kind":"vercel_ai_gateway"');
        expect(pausedDurableText).toContain('"permission_review_model_id":"reviewer-a"');
        expect(pausedDurableText).toContain('"route_model":"model-a"');
        expect(pausedDurableText).toMatch(
          /"delivery":"possibly_sent"[^\n]*"consumed_provider_attempts":10,"outstanding_reservation":false/,
        );
        expect(pausedDurableText).not.toContain("route-only-secret");

        writeConnectionSettings(
          home,
          "connection-b",
          gatewayA.chatUrl,
          gatewayB.chatUrl,
          true,
          "fx_login",
        );
        writeExpiredFxLogin(home, oauthB.issuerUrl);
        const resumed = await runFx(
          [
            "ask",
            "--auto",
            "--json",
            "--resume-id",
            sessionId,
            "--continue-recovery",
          ],
          {
            cwd: workspaceRoot,
            env: {
              ...env,
              FX_E2E_OAUTH_ISSUER_URL: oauthB.issuerUrl,
            },
          },
        );
        expect(resumed.code).toBe(0);
        expect(JSON.parse(resumed.stdout.trim()).output).toContain("resumed on A");
        expect(gatewayA.requests).toHaveLength(11);
        expect(gatewayTrafficCount(gatewayB)).toBe(0);
        expect(oauthB.requests).toEqual([]);
        expect(gatewayA.requests[0]!.headers.get("ai-language-model-id")).toBe(
          "model-a",
        );
        expect(gatewayA.requests[10]!.headers.get("ai-language-model-id")).toBe(
          "model-a",
        );

        const durableText = readdirSync(sessionDir)
          .filter((name) => name.endsWith(".json") || name.endsWith(".jsonl"))
          .map((name) => readFileSync(join(sessionDir, name), "utf8"))
          .join("\n");
        expect(durableText).toContain('"connection_id":"connection-a"');
        expect(durableText).toContain('"model_id":"model-a"');
        expect(durableText).not.toContain("route-only-secret");

        writeConnectionSettings(
          home,
          "connection-b",
          gatewayA.chatUrl,
          gatewayB.chatUrl,
          false,
        );
        const beforeMissingA = gatewayTrafficCount(gatewayA);
        const beforeMissingB = gatewayTrafficCount(gatewayB);
        const missing = await runFx(
          [
            "ask",
            "--auto",
            "--json",
            "--resume-id",
            sessionId,
            "This must not reach a provider.",
          ],
          { cwd: workspaceRoot, env },
        );
        expect(missing.code).not.toBe(0);
        expect(`${missing.stdout}\n${missing.stderr}`).toContain(
          "saved connection is unavailable; select or restore that connection",
        );
        expect(gatewayTrafficCount(gatewayA)).toBe(beforeMissingA);
        expect(gatewayTrafficCount(gatewayB)).toBe(beforeMissingB);
      } finally {
        gatewayA.stop();
        gatewayB.stop();
        oauthB.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  test(
    "ACP load resolves the saved connection before selected connection auth",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-acp-session-route-restart-"));
      const gatewayA = startFakeGateway([], {
        models: [{ id: "model-a", type: "language", tags: ["tool-use"] }],
      });
      const gatewayB = startFakeGateway([], {
        models: [{ id: "model-b", type: "language", tags: ["tool-use"] }],
      });
      const oauthB = startRejectingOAuth();
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        mkdirSync(join(home, ".fx"), { recursive: true });
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);
        const env = {
          AI_GATEWAY_API_KEY: "route-only-secret",
          FX_GATEWAY_BASE_URL: gatewayA.baseUrl,
          FX_AUTO_UPGRADE: "0",
        };
        writeConnectionSettings(
          home,
          "connection-a",
          gatewayA.chatUrl,
          gatewayB.chatUrl,
        );

        const creator = startAcp(workspaceRoot, home, env);
        creator.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } });
        expect((await creator.read()).result).toBeDefined();
        creator.send({ jsonrpc: "2.0", id: 2, method: "session/new", params: { mcpServers: [] } });
        const created = await creator.read();
        const sessionId = created.result?.sessionId as string;
        expect(sessionId.length).toBeGreaterThan(0);
        creator.kill();

        writeConnectionSettings(
          home,
          "connection-b",
          gatewayA.chatUrl,
          gatewayB.chatUrl,
          true,
          "fx_login",
        );
        writeExpiredFxLogin(home, oauthB.issuerUrl);
        const loader = startAcp(workspaceRoot, home, {
          ...env,
          FX_E2E_OAUTH_ISSUER_URL: oauthB.issuerUrl,
        });
        try {
          loader.send({ jsonrpc: "2.0", id: 3, method: "initialize", params: { protocolVersion: 1 } });
          expect((await loader.read()).result).toBeDefined();
          expect(oauthB.requests).toEqual([]);
          loader.send({
            jsonrpc: "2.0",
            id: 4,
            method: "session/load",
            params: { sessionId, mcpServers: [] },
          });
          expect((await loader.read()).result).toBeDefined();
          expect(oauthB.requests).toEqual([]);
          expect(gatewayTrafficCount(gatewayB)).toBe(0);
        } finally {
          loader.kill();
        }
      } finally {
        gatewayA.stop();
        gatewayB.stop();
        oauthB.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    30_000,
  );

  for (const boundary of [
    "after_event_append",
    "after_event_sync",
    "after_watermark_rename",
  ]) {
    test(
      `process death at ${boundary} leaves an uncommitted orphan`,
      async () => {
        const root = mkdtempSync(join(tmpdir(), "fx-session-pre-authority-"));
        try {
          const home = join(root, "home");
          const workspace = join(root, "workspace");
          const ready = join(root, "boundary.ready");
          mkdirSync(home);
          mkdirSync(workspace);
          const workspaceRoot = realpathSync(workspace);

          const first = startAcp(workspaceRoot, home, {
            FX_E2E_SESSION_BOUNDARY: boundary,
            FX_E2E_SESSION_BOUNDARY_READY: ready,
          });
          first.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } });
          expect((await first.read()).result).toBeDefined();
          first.send({ jsonrpc: "2.0", id: 2, method: "session/new", params: { mcpServers: [] } });
          await waitForPath(ready);
          first.kill();
          await Bun.sleep(100);

          const listed = await runFx(["sessions", "--json"], {
            cwd: workspaceRoot,
            env: { HOME: home },
          });
          expect(JSON.parse(listed.stdout).count).toBe(0);

          const doctor = await runFx(["doctor", "--json"], {
            cwd: workspaceRoot,
            env: { HOME: home },
          });
          expect(JSON.parse(doctor.stdout).checks).toEqual(
            expect.arrayContaining([
              expect.objectContaining({
                detail: expect.stringContaining(
                  "authority_less_creation_orphan",
                ),
              }),
            ]),
          );
        } finally {
          rmSync(root, { recursive: true, force: true });
        }
      },
      60_000,
    );
  }

  for (const boundary of [
    "after_authority_marker_rename",
    "after_authority_namespace_sync",
    "after_authority_intent_remove",
  ]) {
    test(
      `writable load confirms proposed authority after ${boundary}`,
      async () => {
        const root = mkdtempSync(join(tmpdir(), "fx-session-post-authority-"));
        try {
          const home = join(root, "home");
          const workspace = join(root, "workspace");
          const ready = join(root, "boundary.ready");
          mkdirSync(home);
          mkdirSync(workspace);
          const workspaceRoot = realpathSync(workspace);

          const first = startAcp(workspaceRoot, home, {
            FX_E2E_SESSION_BOUNDARY: boundary,
            FX_E2E_SESSION_BOUNDARY_READY: ready,
          });
          first.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } });
          expect((await first.read()).result).toBeDefined();
          first.send({ jsonrpc: "2.0", id: 2, method: "session/new", params: { mcpServers: [] } });
          await waitForPath(ready);
          first.kill();
          await Bun.sleep(100);

          const sessionIds = sessionIdsFromHome(home);
          expect(sessionIds).toHaveLength(1);
          const sessionId = sessionIds[0]!;
          expect(JSON.parse((await runFx(["sessions", "--json"], {
            cwd: workspaceRoot,
            env: { HOME: home },
          })).stdout).count).toBe(0);

          const resolver = startAcp(workspaceRoot, home);
          resolver.send({ jsonrpc: "2.0", id: 3, method: "initialize", params: { protocolVersion: 1 } });
          expect((await resolver.read()).result).toBeDefined();
          resolver.send({ jsonrpc: "2.0", id: 4, method: "session/load", params: { sessionId, mcpServers: [] } });
          expect((await resolver.read()).result).toBeDefined();
          resolver.kill();

          const detail = await runFx(["session", "--id", sessionId, "--json"], {
            cwd: workspaceRoot,
            env: { HOME: home },
          });
          expect(detail.code).toBe(0);
          expect(JSON.parse(detail.stdout).id).toBe(sessionId);
        } finally {
          rmSync(root, { recursive: true, force: true });
        }
      },
      60_000,
    );
  }

  test("doctor removes only a validated noncurrent watermark", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-session-doctor-cleanup-"));
    try {
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home);
      mkdirSync(workspace);
      const workspaceRoot = realpathSync(workspace);
      const sessionId = await createSession(workspaceRoot, home);
      const sessionDir = join(home, ".fx", "sessions", sessionId);
      const currentName = readdirSync(sessionDir).find(
        (name) => name.startsWith("commit.") && name.endsWith(".json"),
      )!;
      const candidateGeneration = "ffffffffffffffffffffffffffffffff";
      const candidateName = `commit.${candidateGeneration}.json`;
      const candidatePath = join(sessionDir, candidateName);
      const candidate = JSON.parse(
        readFileSync(join(sessionDir, currentName), "utf8"),
      );
      candidate.log_generation = candidateGeneration;
      writeFileSync(candidatePath, JSON.stringify(candidate) + "\n", {
        mode: 0o600,
      });

      const doctor = await runFx(["doctor", "--json"], {
        cwd: workspaceRoot,
        env: { HOME: home },
      });
      expect(doctor.code).toBe(0);
      expect(doctor.stdout).toContain("cleanup_removed=1");
      expect(existsSync(candidatePath)).toBe(false);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("session recover copies a corrupt-watermark session without changing its source", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-session-copy-recovery-"));
    try {
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home);
      mkdirSync(workspace);
      const workspaceRoot = realpathSync(workspace);
      const sessionId = await createSession(workspaceRoot, home);

      const writer = startAcp(workspaceRoot, home);
      writer.send({ jsonrpc: "2.0", id: 10, method: "initialize", params: { protocolVersion: 1 } });
      expect((await writer.read()).result).toBeDefined();
      writer.send({
        jsonrpc: "2.0",
        id: 11,
        method: "session/load",
        params: { sessionId, mcpServers: [] },
      });
      expect((await writer.read()).result).toBeDefined();
      writer.send({
        jsonrpc: "2.0",
        id: 12,
        method: "session/set_config_option",
        params: { configId: "model", value: "o4-mini" },
      });
      expect((await writer.read()).result).toBeDefined();
      writer.kill();
      await Bun.sleep(100);

      const sessionDir = join(home, ".fx", "sessions", sessionId);
      const watermarkName = readdirSync(sessionDir).find(
        (name) => name.startsWith("commit.") && name.endsWith(".json"),
      )!;
      writeFileSync(join(sessionDir, watermarkName), "{}\n", { mode: 0o600 });
      const sourceBefore = sessionFileSnapshot(sessionDir);

      const doctor = await runFx(["doctor", "--json"], {
        cwd: workspaceRoot,
        env: { HOME: home },
      });
      expect(doctor.code).toBe(0);
      expect(doctor.stdout).toContain("commit_watermark_invalid");
      expect(doctor.stdout).toContain(`fx session recover ${sessionId}`);

      const recovery = await runFx(
        ["session", "recover", sessionId, "--json"],
        {
          cwd: workspaceRoot,
          env: { HOME: home },
        },
      );
      expect(recovery.code).toBe(0);
      const recovered = JSON.parse(recovery.stdout);
      expect(recovered.kind).toBe("session_recovery");
      expect(recovered.source_id).toBe(sessionId);
      expect(recovered.recovered_id).not.toBe(sessionId);
      expect(recovered.status).toBe("recovered");
      expect(sessionFileSnapshot(sessionDir)).toEqual(sourceBefore);

      const recoveredDetail = await runFx(
        ["session", "--id", recovered.recovered_id, "--json"],
        {
          cwd: workspaceRoot,
          env: { HOME: home },
        },
      );
      expect(recoveredDetail.code).toBe(0);
      expect(JSON.parse(recoveredDetail.stdout).id).toBe(recovered.recovered_id);

      const gateway = startFakeGateway([
        fakeGatewayFinalText("RECOVERED_LAST_RESUMED"),
      ]);
      try {
        const resumedLast = await runFx(
          [
            "ask",
            "--json",
            "--resume",
            "last",
            "continue the recovered conversation",
          ],
          {
            cwd: workspaceRoot,
            env: {
              HOME: home,
              AI_GATEWAY_API_KEY: "e2e-placeholder",
              VERCEL_OIDC_TOKEN: "",
              FX_GATEWAY_BASE_URL: gateway.baseUrl,
              FX_GATEWAY_CHAT_URL: gateway.chatUrl,
            },
          },
        );
        if (resumedLast.code !== 0) {
          throw new Error(
            `resume last failed: stdout=${JSON.stringify(resumedLast.stdout)} stderr=${JSON.stringify(resumedLast.stderr)}`,
          );
        }
        expect(resumedLast.stdout).toContain("RECOVERED_LAST_RESUMED");
        expect(gateway.requests).toHaveLength(1);
        expect(sessionFileSnapshot(sessionDir)).toEqual(sourceBefore);
      } finally {
        gateway.stop();
      }

      const sourceDetail = await runFx(
        ["session", "--id", sessionId, "--json"],
        {
          cwd: workspaceRoot,
          env: { HOME: home },
        },
      );
      expect(sourceDetail.code).not.toBe(0);
      expect(JSON.parse(sourceDetail.stdout)).toEqual(
        expect.objectContaining({
          code: "InvalidSessionFormat",
          error: `session ${sessionId} is corrupt; run \`fx session recover ${sessionId}\``,
        }),
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test("cross-workspace recovery preserves both resume-last pointers", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-session-cross-workspace-recovery-"));
    try {
      const home = join(root, "home");
      const workspaceA = join(root, "workspace-a");
      const workspaceB = join(root, "workspace-b");
      mkdirSync(home);
      mkdirSync(workspaceA);
      mkdirSync(workspaceB);
      const workspaceARoot = realpathSync(workspaceA);
      const workspaceBRoot = realpathSync(workspaceB);

      const sourceId = await createSession(workspaceARoot, home);
      await Bun.sleep(10);
      const healthyAId = await createSession(workspaceARoot, home);
      await Bun.sleep(10);
      const newestBId = await createSession(workspaceBRoot, home);

      const sourceDir = join(home, ".fx", "sessions", sourceId);
      const watermarkName = readdirSync(sourceDir).find(
        (name) => name.startsWith("commit.") && name.endsWith(".json"),
      )!;
      writeFileSync(join(sourceDir, watermarkName), "{}\n", { mode: 0o600 });

      const recovery = await runFx(
        ["session", "recover", sourceId, "--json"],
        {
          cwd: workspaceBRoot,
          env: { HOME: home },
        },
      );
      expect(recovery.code).toBe(0);
      expect(JSON.parse(recovery.stdout).status).toBe("recovered");

      const gateway = startFakeGateway([
        fakeGatewayFinalText("WORKSPACE_A_RESUMED"),
        fakeGatewayFinalText("WORKSPACE_B_RESUMED"),
      ]);
      const resumeEnv = {
        HOME: home,
        AI_GATEWAY_API_KEY: "e2e-placeholder",
        VERCEL_OIDC_TOKEN: "",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      };
      try {
        const resumedA = await runFx(
          ["ask", "--json", "--auto", "--resume", "last", "continue A"],
          {
            cwd: workspaceARoot,
            env: resumeEnv,
          },
        );
        expect(resumedA.code).toBe(0);
        expect(JSON.parse(resumedA.stdout).session_id).toBe(healthyAId);
        const resumedB = await runFx(
          ["ask", "--json", "--auto", "--resume", "last", "continue B"],
          {
            cwd: workspaceBRoot,
            env: resumeEnv,
          },
        );
        expect(resumedB.code).toBe(0);
        expect(JSON.parse(resumedB.stdout).session_id).toBe(newestBId);
      } finally {
        gateway.stop();
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test(
    "process death after authority intent leaves a fenced orphan for writable resolution",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-session-recovery-"));
      try {
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const ready = join(root, "boundary.ready");
        const resolverTrace = join(root, "resolver.trace");
        mkdirSync(home);
        mkdirSync(workspace);
        const workspaceRoot = realpathSync(workspace);

        const first = startAcp(workspaceRoot, home, {
          FX_E2E_SESSION_BOUNDARY: "after_authority_intent_sync",
          FX_E2E_SESSION_BOUNDARY_READY: ready,
        });
        first.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } });
        expect((await first.read()).result).toBeDefined();
        first.send({ jsonrpc: "2.0", id: 2, method: "session/new", params: { mcpServers: [] } });
        await waitForPath(ready);
        first.kill();
        await Bun.sleep(100);

        const sessionsRoot = join(home, ".fx", "sessions");
        const ids = sessionIdsFromHome(home);
        expect(ids).toHaveLength(1);
        const sessionId = ids[0]!;

        const pendingDoctor = await runFx(["doctor", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home },
        });
        expect(JSON.parse(pendingDoctor.stdout).checks).toEqual(
          expect.arrayContaining([
            expect.objectContaining({
              detail: expect.stringContaining(
                "authority_transition_pending report_only=true",
              ),
            }),
          ]),
        );

        const listed = await runFx(["sessions", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home },
        });
        expect(JSON.parse(listed.stdout)).toEqual({
          kind: "sessions",
          count: 0,
          sessions: [],
          skipped_invalid: 1,
        });

        const resolver = startAcp(workspaceRoot, home, {
          FX_TRACE_LOG: resolverTrace,
        });
        resolver.send({ jsonrpc: "2.0", id: 3, method: "initialize", params: { protocolVersion: 1 } });
        expect((await resolver.read()).result).toBeDefined();
        resolver.send({ jsonrpc: "2.0", id: 4, method: "session/load", params: { sessionId, mcpServers: [] } });
        const loadResponse = await resolver.read();
        resolver.kill();
        expect(readFileSync(resolverTrace, "utf8")).toContain(
          "session operation=load outcome=failed error=SessionNotFound",
        );
        expect(loadResponse.error?.message).toBe("Session not found");
        expect(existsSync(join(sessionsRoot, sessionId, "authority.pending.json"))).toBe(false);

        const orphanDoctor = await runFx(["doctor", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home },
        });
        expect(JSON.parse(orphanDoctor.stdout).checks).toEqual(
          expect.arrayContaining([
            expect.objectContaining({
              detail: expect.stringContaining(
                "authority_less_creation_orphan",
              ),
            }),
          ]),
        );

        const detail = await runFx(["session", "--id", sessionId, "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home },
        });
        expect(detail.code).not.toBe(0);
        expect(JSON.parse(detail.stdout).error).toContain("record not found");
        expect(detail.stderr).toBe("");
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
  );

  for (const boundary of [
    "after_event_append",
    "after_event_sync",
    "after_commit_intent_sync",
    "after_watermark_rename",
    "after_target_namespace_sync",
    "after_commit_intent_remove",
  ]) {
    test(
      `model commit recovers after process death at ${boundary}`,
      async () => {
        const root = mkdtempSync(join(tmpdir(), "fx-session-commit-"));
        try {
          const home = join(root, "home");
          const workspace = join(root, "workspace");
          const ready = join(root, "boundary.ready");
          mkdirSync(home);
          mkdirSync(workspace);
          const workspaceRoot = realpathSync(workspace);
          const sessionId = await createSession(workspaceRoot, home);

          const writer = startAcp(workspaceRoot, home, {
            FX_E2E_SESSION_BOUNDARY: boundary,
            FX_E2E_SESSION_BOUNDARY_READY: ready,
          });
          writer.send({ jsonrpc: "2.0", id: 10, method: "initialize", params: { protocolVersion: 1 } });
          expect((await writer.read()).result).toBeDefined();
          writer.send({ jsonrpc: "2.0", id: 11, method: "session/load", params: { sessionId, mcpServers: [] } });
          expect((await writer.read()).result).toBeDefined();
          writer.send({
            jsonrpc: "2.0",
            id: 12,
            method: "session/set_config_option",
            params: { configId: "model", value: "o4-mini" },
          });
          await waitForPath(ready);
          writer.kill();
          await Bun.sleep(100);

          const intentPath = join(
            home,
            ".fx",
            "sessions",
            sessionId,
            "commit.pending.json",
          );
          if ([
            "after_commit_intent_sync",
            "after_watermark_rename",
            "after_target_namespace_sync",
          ].includes(boundary)) {
            expect(existsSync(intentPath)).toBe(true);
          }

          const resolver = startAcp(workspaceRoot, home);
          resolver.send({ jsonrpc: "2.0", id: 20, method: "initialize", params: { protocolVersion: 1 } });
          expect((await resolver.read()).result).toBeDefined();
          resolver.send({ jsonrpc: "2.0", id: 21, method: "session/load", params: { sessionId, mcpServers: [] } });
          const loaded = await resolver.read();
          expect(loaded.result).toBeDefined();
          const loadedModel = loaded.result.configOptions.find(
            (option: { id: string; currentValue: string }) => option.id === "model",
          )?.currentValue;
          if ([
            "after_watermark_rename",
            "after_target_namespace_sync",
            "after_commit_intent_remove",
          ].includes(boundary)) {
            expect(loadedModel).toBe("o4-mini");
          } else {
            expect(loadedModel).not.toBe("o4-mini");
          }
          resolver.kill();

          expect(existsSync(intentPath)).toBe(false);
          const detail = await runFx(["session", "--id", sessionId, "--json"], {
            cwd: workspaceRoot,
            env: { HOME: home },
          });
          expect(detail.code).toBe(0);
          expect(JSON.parse(detail.stdout).id).toBe(sessionId);
        } finally {
          rmSync(root, { recursive: true, force: true });
        }
      },
      60_000,
    );
  }
});
