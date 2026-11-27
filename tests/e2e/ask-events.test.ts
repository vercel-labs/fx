import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  FX_BIN,
  fxChildEnv,
} from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySse,
  startDynamicFakeGateway,
} from "./tmux-helpers";

type AskEvent = {
  kind: string;
  seq: number;
  at_ms: number;
  turn_id: number;
  event: string;
  model?: string;
  step?: number;
  status?: string;
  attempt?: number;
  call_id?: string;
  tool?: string;
  summary?: string;
  message?: string;
  exit_code?: number;
};

function parseJsonl(raw: string): AskEvent[] {
  return raw
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as AskEvent);
}

function makeAskEnv(home: string, gateway: ReturnType<typeof startDynamicFakeGateway>) {
  return fxChildEnv({
    HOME: home,
    AI_GATEWAY_API_KEY: "ask-events-fake-key",
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TEST_GATEWAY_CREDITS_URL: "http://127.0.0.1:9/coding-agent/v1/credits",
  });
}

async function waitForFileMatch(path: string, needle: string, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(path) && readFileSync(path, "utf8").includes(needle)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${needle} in ${path}`);
}

describe("fx ask --events-file", () => {
  test("happy path with parallel tools writes ordered JSONL events and preserves --json stdout", async () => {
    const home = createIsolatedTestHome("fx-ask-events-happy-");
    const root = mkdtempSync(join(tmpdir(), "fx-ask-events-ws-"));
    const workspace = join(root, "ws");
    mkdirSync(workspace);
    writeFileSync(join(workspace, "a.txt"), "alpha\n");
    writeFileSync(join(workspace, "b.txt"), "beta\n");
    const eventsPath = join(root, "events.jsonl");

    let reqIdx = 0;
    const gateway = startDynamicFakeGateway(() => {
      if (reqIdx++ === 0) {
        return fakeGatewaySse([
          { type: "tool-call", toolCallId: "call_a", toolName: "read_file", input: { path: "a.txt" } },
          { type: "tool-call", toolCallId: "call_b", toolName: "read_file", input: { path: "b.txt" } },
          { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_calls" } },
        ]);
      }
      return fakeGatewayFinalText("ASK_EVENTS_HAPPY_OK");
    });

    try {
      const proc = Bun.spawn(
        [FX_BIN, "ask", "--json", "--events-file", eventsPath, "--auto", "--no-save", "Read both files."],
        { cwd: workspace, stdin: "ignore", stdout: "pipe", stderr: "pipe", env: makeAskEnv(home, gateway) },
      );
      const [stdout, stderr, code] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      expect(code, stderr).toBe(0);

      const result = JSON.parse(stdout);
      expect(result.output).toBe("ASK_EVENTS_HAPPY_OK");
      expect(result.exit_code).toBe(0);
      expect(result.tool_calls).toHaveLength(2);

      const events = parseJsonl(readFileSync(eventsPath, "utf8"));
      expect(events.length).toBeGreaterThanOrEqual(9);
      for (let i = 0; i < events.length; i += 1) {
        expect(events[i]!.kind).toBe("ask_event");
        expect(events[i]!.seq).toBe(i + 1);
      }
      const names = events.map((e) => e.event);
      expect(names[0]).toBe("run_started");
      expect(names.at(-1)).toBe("run_finished");
      expect(events.filter((e) => e.event === "model_step_started")).toHaveLength(2);
      expect(events.filter((e) => e.event === "model_step_finished")).toHaveLength(2);
      const started = events.filter((e) => e.event === "tool_started");
      const finished = events.filter((e) => e.event === "tool_finished");
      expect(started.map((e) => e.call_id)).toEqual(["call_a", "call_b"]);
      expect(finished.map((e) => e.call_id).sort()).toEqual(["call_a", "call_b"]);
      for (const item of finished) expect(item.status).toBe("completed");
    } finally {
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
      cleanupIsolatedTestHome(home);
    }
  }, 30_000);

  test("SIGTERM mid-tool keeps prior valid JSONL events and appends run_cancelled", async () => {
    const home = createIsolatedTestHome("fx-ask-events-term-");
    const root = mkdtempSync(join(tmpdir(), "fx-ask-events-term-ws-"));
    const workspace = join(root, "ws");
    mkdirSync(workspace);
    const eventsPath = join(root, "events.jsonl");

    let reqIdx = 0;
    const gateway = startDynamicFakeGateway(() => {
      if (reqIdx++ === 0) {
        return fakeGatewaySse([
          {
            type: "tool-call",
            toolCallId: "sh_sleep",
            toolName: "shell",
            input: { request: { action: "run", command: "sleep 10" } },
          },
          { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_calls" } },
        ]);
      }
      return fakeGatewayFinalText("UNREACHED");
    });

    try {
      const proc = Bun.spawn(
        [FX_BIN, "ask", "--json", "--events-file", eventsPath, "--full-access", "--no-save", "Sleep."],
        { cwd: workspace, stdin: "ignore", stdout: "pipe", stderr: "pipe", env: makeAskEnv(home, gateway) },
      );
      await waitForFileMatch(eventsPath, '"tool_started"');
      proc.kill("SIGTERM");

      const [stdout, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
      expect(stdout).toBe("");
      expect(exitCode === 143 || proc.signalCode === "SIGTERM").toBe(true);

      const events = parseJsonl(readFileSync(eventsPath, "utf8"));
      const names = events.map((e) => e.event);
      expect(names).toContain("run_started");
      expect(names).toContain("tool_started");
      expect(names.at(-1)).toBe("run_cancelled");
      expect(names).not.toContain("run_finished");
    } finally {
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
      cleanupIsolatedTestHome(home);
    }
  }, 30_000);

  test.skipIf(!existsSync("/dev/full"))(
    "mid-run ENOSPC on /dev/full latches off events and preserves exit 0 and stdout JSON",
    async () => {
      const home = createIsolatedTestHome("fx-ask-events-full-");
      const root = mkdtempSync(join(tmpdir(), "fx-ask-events-full-ws-"));
      const workspace = join(root, "ws");
      mkdirSync(workspace);
      writeFileSync(join(workspace, "a.txt"), "alpha\n");

      let reqIdx = 0;
      const gateway = startDynamicFakeGateway(() => {
        if (reqIdx++ === 0) {
          return fakeGatewaySse([
            { type: "tool-call", toolCallId: "c1", toolName: "read_file", input: { path: "a.txt" } },
            { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_calls" } },
          ]);
        }
        return fakeGatewayFinalText("SURVIVED_DEV_FULL");
      });

      try {
        const proc = Bun.spawn(
          [FX_BIN, "ask", "--json", "--events-file", "/dev/full", "--auto", "--no-save", "Read a.txt."],
          { cwd: workspace, stdin: "ignore", stdout: "pipe", stderr: "pipe", env: makeAskEnv(home, gateway) },
        );
        const [stdout, stderr, code] = await Promise.all([
          new Response(proc.stdout).text(),
          new Response(proc.stderr).text(),
          proc.exited,
        ]);
        expect(code, stderr).toBe(0);
        const result = JSON.parse(stdout);
        expect(result.output).toBe("SURVIVED_DEV_FULL");
        const warnings = stderr.split("\n").filter((line) => line.includes("events file"));
        expect(warnings).toHaveLength(1);
      } finally {
        gateway.stop();
        rmSync(root, { recursive: true, force: true });
        cleanupIsolatedTestHome(home);
      }
    },
    30_000,
  );

  test("unopenable --events-file path fails fast with exit 2 before any model request", async () => {
    const home = createIsolatedTestHome("fx-ask-events-badpath-");
    const root = mkdtempSync(join(tmpdir(), "fx-ask-events-badpath-ws-"));
    const workspace = join(root, "ws");
    mkdirSync(workspace);
    const badPath = join(root, "missing-dir", "events.jsonl");

    const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText("UNREACHED"));
    try {
      const proc = Bun.spawn(
        [FX_BIN, "ask", "--json", "--events-file", badPath, "--auto", "--no-save", "Hello."],
        { cwd: workspace, stdin: "ignore", stdout: "pipe", stderr: "pipe", env: makeAskEnv(home, gateway) },
      );
      const [stdout, stderr, code] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      expect(code).toBe(2);
      expect(gateway.requestCount()).toBe(0);
      const result = JSON.parse(stdout);
      expect(result.exit_code).toBe(2);
      expect(result.error).toBe("InvalidEventsFile");
      expect(stderr).toBe("");
    } finally {
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
      cleanupIsolatedTestHome(home);
    }
  }, 15_000);

  test("recovery wait emits a recovery event without a duplicate notice event", async () => {
    const home = createIsolatedTestHome("fx-ask-events-rec-");
    const root = mkdtempSync(join(tmpdir(), "fx-ask-events-rec-ws-"));
    const workspace = join(root, "ws");
    mkdirSync(workspace);
    const eventsPath = join(root, "events.jsonl");

    let reqIdx = 0;
    const gateway = startDynamicFakeGateway(() => {
      if (reqIdx++ === 0) {
        return new Response(JSON.stringify({ error: { message: "temp down" } }), {
          status: 503,
          headers: { "content-type": "application/json", "retry-after": "1" },
        });
      }
      return fakeGatewayFinalText("RECOVERED_OK");
    });

    try {
      const proc = Bun.spawn(
        [FX_BIN, "ask", "--json", "--events-file", eventsPath, "--auto", "--no-save", "Recover."],
        { cwd: workspace, stdin: "ignore", stdout: "pipe", stderr: "pipe", env: makeAskEnv(home, gateway) },
      );
      const [stdout, stderr, code] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);
      expect(code, stderr).toBe(0);
      expect(JSON.parse(stdout).output).toBe("RECOVERED_OK");

      const events = parseJsonl(readFileSync(eventsPath, "utf8"));
      const recoveries = events.filter((e) => e.event === "recovery");
      expect(recoveries.length).toBeGreaterThanOrEqual(1);
      expect(recoveries[0]!.status).toBe("waiting");
      expect(recoveries[0]!.attempt).toBe(1);
      expect(events.filter((e) => e.event === "notice")).toHaveLength(0);
    } finally {
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
      cleanupIsolatedTestHome(home);
    }
  }, 30_000);
});
