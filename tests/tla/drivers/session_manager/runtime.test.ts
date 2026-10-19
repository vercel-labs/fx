import { expect, test } from "bun:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, repetitions, targetHelpers, worktree } from "../lib/context";
import { inspectRuntime, requireAccepted, type Model, type RuntimeEvidence } from "./bridge";

const { startDynamicFakeGateway, fakeGatewayFinalText, fakeGatewayToolCall, FAKE_GATEWAY_MODEL } = await targetHelpers();
type Outcome = { pid: number; exitCode: number | null; signal: string | null; stdout: string; stderr: string; args: string[] };

function fixture(label: string) {
  const root = mkdtempSync(join(artifacts, label + "-"));
  const home = join(root, "home"), workspace = join(root, "workspace"), trace = join(root, "wiring.log");
  mkdirSync(home, { mode: 0o700 }); mkdirSync(workspace, { mode: 0o700 });
  const sessionsRoot = join(home, ".fx/sessions/v2");
  const outcomes: Outcome[] = [];
  const active = new Set<ChildProcess>();
  const environment = (gateway: any) => ({
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    AI_GATEWAY_API_KEY: "synthetic-tlc-runtime-fixture", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_MODEL: FAKE_GATEWAY_MODEL, FX_SESSIONS_V2: "1", FX_PERMISSION_MODE: "full-access",
    FX_AUTO_UPGRADE: "0", FX_SOUND: "0", NO_COLOR: "1", FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "wiring",
  });
  function start(gateway: any, args: string[]) {
    const argv = ["ask", "--json", "--auto", ...args];
    const child = spawn(binary, argv, { cwd: workspace, env: environment(gateway), stdio: ["ignore", "pipe", "pipe"] });
    assert(child.pid, "fx did not start"); active.add(child);
    const stdout: Buffer[] = [], stderr: Buffer[] = [];
    child.stdout!.on("data", data => stdout.push(Buffer.from(data)));
    child.stderr!.on("data", data => stderr.push(Buffer.from(data)));
    const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
    const finished = new Promise<Outcome>((resolve, reject) => {
      child.on("error", error => { clearTimeout(timer); active.delete(child); reject(error); });
      child.on("close", (exitCode, signal) => {
        clearTimeout(timer); active.delete(child);
        const result = { pid: child.pid!, exitCode, signal, args: argv, stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString() };
        outcomes.push(result);
        writeFileSync(join(root, "processes.json"), JSON.stringify(outcomes, null, 2));
        resolve(result);
      });
    });
    return { child, finished };
  }
  const ask = async (gateway: any, args: string[]) => {
    const outcome = await start(gateway, args).finished;
    assert.equal(outcome.exitCode, 0, outcome.stderr); assert.equal(outcome.signal, null);
    assert(!/panic|aborted/i.test(outcome.stderr), outcome.stderr);
    return { outcome, json: JSON.parse(outcome.stdout) };
  };
  const lines = (id: string) => readFileSync(join(sessionsRoot, id, "log.jsonl"), "utf8").trimEnd().split("\n").map(line => JSON.parse(line));
  const evidence = (ids: string[], models: Model[]): RuntimeEvidence => ({
    version: 1, sessionsRoot, sessionIds: ids, wiringTrace: trace,
    processes: outcomes.map(({ pid, exitCode, signal }) => ({ pid, exitCode, signal })), requiredModels: models,
    metadata: { worktree, binary, binaryHash: createHash("sha256").update(readFileSync(binary)).digest("hex"),
      head: Bun.spawnSync(["git", "rev-parse", "HEAD"], { cwd: worktree }).stdout.toString().trim() },
  });
  async function finish(gateway: any) {
    for (const child of active) child.kill("SIGKILL");
    if (active.size) await Promise.all([...active].map(child => new Promise(resolve => child.once("close", resolve))));
    writeFileSync(join(root, "gateway-requests.json"), JSON.stringify(gateway.requests.map((request: any) => request.body), null, 2));
    gateway.stop();
  }
  return { root, trace, sessionsRoot, outcomes, start, ask, lines, evidence, finish };
}

async function waitFor(check: () => boolean, description: string) {
  const until = Date.now() + 15_000;
  while (Date.now() < until) { if (check()) return; await Bun.sleep(25); }
  throw new Error(`Owned fault boundary not reached: ${description}`);
}

function frame(entry: Record<string, unknown>): string {
  const { crc: ignored, ...body } = entry;
  const payload = JSON.stringify(body).slice(0, -1);
  let crc = 0xffffffff;
  for (const byte of Buffer.from(payload)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0x82f63b78 : 0);
  }
  return `${payload},"crc":"${((crc ^ 0xffffffff) >>> 0).toString(16).padStart(8, "0")}"}\n`;
}

test("TLC accepts actual committed/resumed logs and rejects corrupted or incomplete evidence", async () => {
  for (let iteration = 0; iteration < repetitions; iteration++) {
    const run = fixture("commit-resume");
    const gateway = startDynamicFakeGateway((body: string) => fakeGatewayFinalText(body.includes("TLC_SECOND_PROMPT") ? "TLC_SECOND_ANSWER" : "TLC_FIRST_ANSWER"));
    try {
      const first = await run.ask(gateway, ["TLC_FIRST_PROMPT"]);
      expect(first.json.output).toBe("TLC_FIRST_ANSWER"); expect(first.outcome.stderr).toBe("");
      const id = first.json.session_id;
      const second = await run.ask(gateway, ["--resume-id", id, "TLC_SECOND_PROMPT"]);
      expect(second.json.session_id).toBe(id); expect(second.json.output).toBe("TLC_SECOND_ANSWER");
      expect(gateway.requests.at(-1).body).toContain("TLC_FIRST_ANSWER");
      expect(run.lines(id).filter(line => line.kind === "turn_committed")).toHaveLength(2);
      const evidence = run.evidence([id], ["turns", "wiring"]);
      requireAccepted(await inspectRuntime(evidence, join(run.root, "positive")));

      const badRoot = join(run.root, "synthetic-invalid-log"); mkdirSync(badRoot);
      cpSync(join(run.sessionsRoot, id), join(badRoot, id), { recursive: true });
      const invalid = run.lines(id); invalid[1].kind = "turn_committed";
      writeFileSync(join(badRoot, id, "log.jsonl"), invalid.map(frame).join(""));
      const rejected = await inspectRuntime({ ...evidence, sessionsRoot: badRoot, requiredModels: ["turns"] }, join(run.root, "negative-log"));
      expect(rejected.verdict).toBe("REJECTED"); expect(() => requireAccepted(rejected)).toThrow();

      const badTrace = join(run.root, "synthetic-invalid-wiring.log");
      const text = readFileSync(run.trace, "utf8"); const rows = text.trimEnd().split("\n");
      const pid = evidence.processes![0]!.pid;
      rows.splice(1, 0, `1 [wiring] action=EndTurn session=- end=commit pid=${pid}`);
      writeFileSync(badTrace, rows.join("\n") + "\n");
      expect((await inspectRuntime({ ...evidence, wiringTrace: badTrace, requiredModels: ["wiring"] }, join(run.root, "negative-wiring"))).verdict).toBe("REJECTED");

      const emptyTrace = join(run.root, "empty.log"); writeFileSync(emptyTrace, "");
      expect((await inspectRuntime({ ...evidence, wiringTrace: emptyTrace }, join(run.root, "empty-trace"))).verdict).toBe("INCONCLUSIVE");
      expect((await inspectRuntime({ ...evidence, sessionIds: [id, "missing-session"] }, join(run.root, "missing-session"))).verdict).toBe("INCONCLUSIVE");
      expect((await inspectRuntime({ ...evidence, requiredModels: ["turns", "children"] }, join(run.root, "missing-child-work"))).verdict).toBe("INCONCLUSIVE");
      const corrupt = Buffer.from(readFileSync(join(run.sessionsRoot, id, "log.jsonl")));
      const at = corrupt.indexOf("TLC_FIRST_PROMPT"); assert(at >= 0, "corruption target not present");
      corrupt[at] ^= 1;
      writeFileSync(join(badRoot, id, "log.jsonl"), corrupt);
      const damaged = await inspectRuntime({ ...evidence, sessionsRoot: badRoot, requiredModels: ["turns"] }, join(run.root, "crc-corruption"));
      expect(damaged.verdict).toBe("INCONCLUSIVE"); expect(damaged.checks[0].detail).toContain("CRC32C mismatch");
      const invalidRequest = await inspectRuntime({ ...evidence, version: 2 } as unknown as RuntimeEvidence, join(run.root, "invalid-request"));
      expect(invalidRequest.verdict).toBe("TOOL_ERROR"); expect(() => requireAccepted(invalidRequest)).toThrow();
      writeFileSync(join(badRoot, id, "log.jsonl"), readFileSync(join(run.sessionsRoot, id, "log.jsonl")).subarray(0, -1));
      expect((await inspectRuntime({ ...evidence, sessionsRoot: badRoot, requiredModels: ["turns"] }, join(run.root, "torn-tail"))).verdict).toBe("INCONCLUSIVE");
    } finally { await run.finish(gateway); }
  }
}, Math.max(120_000, repetitions * 120_000));

test("TLC accepts real owned-process crash followed by interrupted recovery and commit", async () => {
  for (let iteration = 0; iteration < repetitions; iteration++) {
    const run = fixture("crash-resume");
    const gateway = startDynamicFakeGateway((body: string) => body.includes("TLC_RECOVERY_PROMPT")
      ? fakeGatewayFinalText("TLC_RECOVERED_ANSWER")
      : new Response(new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode(': held response\n\n')); } }), { headers: { "content-type": "text/event-stream" } }));
    try {
      const pending = run.start(gateway, ["TLC_CRASH_PROMPT"]);
      let id = "";
      await waitFor(() => {
        if (!existsSync(run.sessionsRoot) || !gateway.requests.length) return false;
        for (const name of readdirSync(run.sessionsRoot)) {
          const path = join(run.sessionsRoot, name, "log.jsonl");
          if (existsSync(path) && readFileSync(path, "utf8").includes("TLC_CRASH_PROMPT")) { id = name; return true; }
        }
        return false;
      }, "durable prompt and an outstanding local Gateway request");
      const before = run.lines(id);
      expect(before.some(line => line.kind === "turn_started")).toBe(true);
      expect(before.some(line => line.kind === "turn_committed")).toBe(false);
      writeFileSync(join(run.root, "fault-boundary.json"), JSON.stringify({ pid: pending.child.pid, id, lines: before, gatewayRequests: gateway.requests.length }, null, 2));
      assert(pending.child.kill("SIGKILL"), "owned process was not killed");
      const killed = await pending.finished; expect(killed.signal).toBe("SIGKILL"); expect(killed.exitCode).toBe(null);
      const resumed = await run.ask(gateway, ["--resume-id", id, "TLC_RECOVERY_PROMPT"]);
      expect(resumed.json.output).toBe("TLC_RECOVERED_ANSWER"); expect(resumed.json.session_id).toBe(id);
      expect(gateway.requests.at(-1).body).toContain("TLC_CRASH_PROMPT");
      expect(run.lines(id).some(line => line.kind === "turn_interrupted" && line.reason === "crash")).toBe(true);
      requireAccepted(await inspectRuntime(run.evidence([id], ["turns", "wiring"]), join(run.root, "proof")));
    } finally { await run.finish(gateway); }
  }
}, Math.max(120_000, repetitions * 120_000));

test("TLC accepts actual parent/child work and retains every expected child log", async () => {
  for (let iteration = 0; iteration < repetitions; iteration++) {
    const run = fixture("child-work");
    const gateway = startDynamicFakeGateway((body: string) => {
      if (!body.includes('"name":"subagent"')) return fakeGatewayFinalText("TLC_CHILD_ANSWER");
      if (body.includes("TLC_CHILD_ANSWER")) return fakeGatewayFinalText("TLC_PARENT_DONE");
      return fakeGatewayToolCall("tlc-delegate", "subagent", { request: { action: "run", task: "Report the child marker." } });
    }, { classifierDecision: "clear" });
    try {
      const result = await run.ask(gateway, ["Delegate the TLC marker report."]);
      expect(result.json.output).toBe("TLC_PARENT_DONE");
      const parent = result.json.session_id;
      const childEvents = run.lines(parent).filter(line => line.kind === "child_spawned" || line.kind === "child_finished");
      expect(childEvents.map(line => [line.kind, line.outcome ?? null])).toEqual([["child_spawned", null], ["child_finished", "ok"]]);
      const child = childEvents[0].child;
      expect(childEvents[1].child).toBe(child); expect(childEvents[1].work_id).toBe(childEvents[0].work_id);
      expect(run.lines(child)[0].parent).toBe(parent); expect(JSON.stringify(run.lines(child))).toContain("TLC_CHILD_ANSWER");
      const resultProof = await inspectRuntime(run.evidence([parent, child], ["turns", "children", "wiring"]), join(run.root, "proof"));
      requireAccepted(resultProof);
      expect(resultProof.checks.filter(check => check.kind === "children")).toHaveLength(1);
      expect((await inspectRuntime(run.evidence([parent], ["turns", "children"]), join(run.root, "omitted-child"))).verdict).toBe("INCONCLUSIVE");
    } finally { await run.finish(gateway); }
  }
}, Math.max(120_000, repetitions * 120_000));
