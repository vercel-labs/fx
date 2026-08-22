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

async function createSession(
  cwd: string,
  home: string,
  options: { durableActivity?: boolean } = {},
): Promise<string> {
  const client = startAcp(cwd, home);
  try {
    client.send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } });
    expect((await client.read()).result).toBeDefined();
    client.send({ jsonrpc: "2.0", id: 2, method: "session/new", params: { mcpServers: [] } });
    const response = await client.read();
    expect(response.result?.sessionId).toBeDefined();
    if (options.durableActivity) {
      await client.read(); // consume session/update notification
      client.send({
        jsonrpc: "2.0",
        id: 3,
        method: "session/set_config_option",
        params: { configId: "model", value: "o4-mini" },
      });
      expect((await client.read()).result).toBeDefined();
    }
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

describe("session recovery", () => {
  test(
    "resume last skips existing zero-turn entries across repeated persistence cycles",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-session-zero-turn-recovery-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      mkdirSync(home);
      mkdirSync(workspace);
      const workspaceRoot = realpathSync(workspace);
      const gateway = startFakeGateway([
        fakeGatewayFinalText("CANONICAL_SESSION_SEEDED"),
        fakeGatewayFinalText("CANONICAL_SESSION_RESUMED_ONCE"),
        fakeGatewayFinalText("CANONICAL_SESSION_RESUMED_TWICE"),
      ]);
      const env = {
        HOME: home,
        AI_GATEWAY_API_KEY: "e2e-placeholder",
        VERCEL_OIDC_TOKEN: "",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      };

      try {
        const seeded = await runFx(
          ["ask", "--json", "--auto", "Create the canonical saved session."],
          { cwd: workspaceRoot, env },
        );
        expect(seeded.code).toBe(0);
        expect(seeded.stderr).toBe("");
        const canonicalId = JSON.parse(seeded.stdout).session_id as string;

        const emptyId = await createSession(workspaceRoot, home);
        expect(emptyId).not.toBe(canonicalId);
        expect(sessionIdsFromHome(home).sort()).toEqual(
          [canonicalId, emptyId].sort(),
        );

        const latest = await runFx(["session", "last", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home },
        });
        expect(latest.code).toBe(0);
        expect(JSON.parse(latest.stdout).id).toBe(canonicalId);

        for (const expected of [
          "CANONICAL_SESSION_RESUMED_ONCE",
          "CANONICAL_SESSION_RESUMED_TWICE",
        ]) {
          const resumed = await runFx(
            ["ask", "--json", "--auto", "--resume", "last", expected],
            { cwd: workspaceRoot, env },
          );
          expect(resumed.code).toBe(0);
          expect(resumed.stderr).toBe("");
          expect(JSON.parse(resumed.stdout).session_id).toBe(canonicalId);
          expect(sessionIdsFromHome(home).sort()).toEqual(
            [canonicalId, emptyId].sort(),
          );
        }

        const listed = await runFx(["sessions", "--json"], {
          cwd: workspaceRoot,
          env: { HOME: home },
        });
        expect(listed.code).toBe(0);
        expect(JSON.parse(listed.stdout)).toMatchObject({
          count: 1,
          sessions: [{ id: canonicalId }],
        });
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
    60_000,
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
      const healthyAId = await createSession(workspaceARoot, home, {
        durableActivity: true,
      });
      await Bun.sleep(10);
      const newestBId = await createSession(workspaceBRoot, home, {
        durableActivity: true,
      });

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
