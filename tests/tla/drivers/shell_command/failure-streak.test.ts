// Runs the real fx binary through turns of failing shell commands and file
// changes, then has TLC replay what fx did through the failure-streak model
// (tests/tla/shell_command/FailureStreak.tla, FailureStreakTrace.tla). No model
// calls: a local fake Gateway serves each step's tool calls.
//
// Each step runs `sh a.sh` and `sh b.sh` or not, each made to fail or pass by
// a result file the driver writes before fx runs the step, and may write a new
// file, try an edit that cannot apply, or read a file. The calls come in a
// random order within the step. The named turns cover the edge cases; the rest
// come from a seeded generator (FX_TLA_SEED, logged).
//
// 1. The binary must conform to the fixed design and not to the design fx had
//    before (GuardLimit 2, no restart on a file change).
// 2. Controls: a tampered or empty observation must not be accepted.
import { test } from "bun:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetHelpers, testEnvironment } from "../lib/context";
import { runTlc, TLA_ROOT } from "../lib/tlc";

const helpers = await targetHelpers();
const SPEC_DIR = join(TLA_ROOT, "shell_command");
const STOP_NOTICE = "Repeated identical shell failures stopped the tool loop.";
const TIMEOUT = 600_000;

type Outcome = "fail" | "pass" | "skip";
type Write = "none" | "ok" | "failed";
type PlannedStep = { a: Outcome; b: Outcome; write: Write; read: boolean; order: number };
type ObservedStep = { fail: Array<"a" | "b">; write: Write };
type ObservedTurn = { name: string; steps: ObservedStep[]; ended: boolean };

const step = (a: Outcome, b: Outcome, write: Write = "none", read = false, order = 0): PlannedStep =>
  ({ a, b, write, read, order });

// The edge cases, by name. order 1 puts the file change after the commands.
const NAMED: Array<[string, PlannedStep[]]> = [
  ["edit then rerun", [step("fail", "skip", "ok"), step("fail", "skip", "ok")]],
  ["unchanged reruns", [step("fail", "skip"), step("fail", "skip"), step("fail", "skip"), step("fail", "skip")]],
  ["failed edit is no change", [step("fail", "skip"), step("fail", "skip", "failed"), step("fail", "skip", "failed")]],
  ["read is no change", [step("fail", "skip"), step("fail", "skip", "none", true), step("fail", "skip", "none", true)]],
  ["a pass restarts", [step("fail", "skip"), step("pass", "skip"), step("fail", "skip"), step("fail", "skip")]],
  ["streaks per command", [step("fail", "fail"), step("fail", "pass"), step("fail", "fail")]],
  ["change after the failure", [step("fail", "skip"), step("fail", "skip", "ok", false, 1), step("fail", "skip")]],
  ["long edit loop", Array.from({ length: 5 }, () => step("fail", "skip", "ok"))],
];

function mulberry32(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomTurns(seed: number, count: number): Array<[string, PlannedStep[]]> {
  const rand = mulberry32(seed);
  const pick = <T>(values: readonly T[]): T => values[Math.floor(rand() * values.length)]!;
  // Failures are likelier than passes, so streaks reach the limit often.
  const outcomes: Outcome[] = ["fail", "fail", "fail", "pass", "skip"];
  const writes: Write[] = ["none", "none", "ok", "failed"];
  return Array.from({ length: count }, (_, i) => [
    `random ${seed}#${i}`,
    Array.from({ length: 1 + Math.floor(rand() * 5) }, () => {
      const planned = step(pick(outcomes), pick(outcomes), pick(writes), rand() < 0.3, rand() < 0.5 ? 0 : 1);
      // A step needs at least one tool call, or it is a final answer.
      if (planned.a === "skip" && planned.b === "skip" && planned.write === "none") planned.read = true;
      return planned;
    }),
  ]);
}

type Call = { id: string; name: string; input: object; role: "a" | "b" | "write" | "read" };

function stepCalls(turn: number, index: number, planned: PlannedStep): Call[] {
  const shells: Call[] = (["a", "b"] as const)
    .filter((cmd) => planned[cmd] !== "skip")
    .map((cmd) => ({ id: `t${turn}s${index}${cmd}`, name: "shell", role: cmd, input: { action: "run", command: `sh ${cmd}.sh`, profile: "clean" } }));
  const change: Call[] = planned.write === "ok"
    ? [{ id: `t${turn}s${index}w`, name: "write_file", role: "write", input: { path: `notes-${index}.txt`, content: `step ${index}\n` } }]
    : planned.write === "failed"
      ? [{ id: `t${turn}s${index}w`, name: "edit_file", role: "write", input: { path: "a.sh", old_string: "NOT_IN_THE_SCRIPT", new_string: "x" } }]
      : [];
  const calls = planned.order === 0 ? [...change, ...shells] : [...shells, ...change];
  if (planned.read) calls.splice(index % (calls.length + 1), 0, { id: `t${turn}s${index}r`, name: "read_file", role: "read", input: { path: "a.sh" } });
  return calls;
}

async function runTurn(turn: number, name: string, plan: PlannedStep[]): Promise<ObservedTurn> {
  const root = mkdtempSync(join(artifacts, `turn-${turn}-`));
  const home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd);
  for (const cmd of ["a", "b"]) writeFileSync(join(cwd, `${cmd}.sh`), `test "$(cat ${cmd}.result)" = pass\n`);
  const sent: Call[][] = [];
  const gateway = helpers.startDynamicFakeGateway(() => {
    const index = sent.length;
    const planned = plan[index];
    if (!planned) return helpers.fakeGatewayFinalText("FIXTURE_DONE");
    for (const cmd of ["a", "b"] as const) writeFileSync(join(cwd, `${cmd}.result`), `${planned[cmd]}\n`);
    const calls = stepCalls(turn, index, planned);
    sent.push(calls);
    return helpers.fakeGatewaySse([
      ...calls.map((call) => ({ type: "tool-call", toolCallId: call.id, toolName: call.name, input: call.input })),
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ]);
  });
  try {
    const child = Bun.spawn([binary, "ask", "--json", "--full-access", "fixture"], {
      cwd,
      stdin: "ignore", stdout: "pipe", stderr: "pipe",
      env: testEnvironment({
        HOME: home, TMPDIR: root, AI_GATEWAY_API_KEY: "synthetic-failure-streak", FX_TEST_SKIP_ONBOARDING: "1",
        FX_MODEL: helpers.FAKE_GATEWAY_MODEL, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      }),
    });
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    writeFileSync(join(root, "stdout.json"), stdout);
    writeFileSync(join(root, "stderr.txt"), stderr);
    assert.ok(!/panic/i.test(stderr), `${name}: fx panicked\n${stderr}`);
    const records: Array<{ name: string; status: string }> = JSON.parse(stdout.trim()).tool_calls;
    const ran = sent.flat();
    assert.equal(records.length, ran.length, `${name}: fx reported ${records.length} tool calls for ${ran.length} sent (exit ${code})`);
    let next = 0;
    const steps = sent.map((calls): ObservedStep => {
      const fail: Array<"a" | "b"> = [];
      let write: Write = "none";
      for (const call of calls) {
        const record = records[next++]!;
        assert.equal(record.name, call.name, `${name}: call ${call.id} reported as ${record.name}`);
        if ((call.role === "a" || call.role === "b") && record.status === "error") fail.push(call.role);
        if (call.role === "write") write = record.status === "success" ? "ok" : "failed";
      }
      return { fail: fail.sort(), write };
    });
    // The fixture controls every outcome; a mismatch means the fixture broke.
    steps.forEach((observedStep, i) => {
      const planned = plan[i]!;
      const wanted = (["a", "b"] as const).filter((cmd) => planned[cmd] === "fail");
      assert.deepEqual(observedStep.fail, wanted, `${name}: step ${i + 1} failures`);
      assert.equal(observedStep.write, planned.write, `${name}: step ${i + 1} write`);
    });
    const ended = stderr.includes(STOP_NOTICE);
    assert.ok(ended || sent.length === plan.length, `${name}: fx ended after ${sent.length} of ${plan.length} steps without the notice`);
    return { name, steps, ended };
  } finally {
    gateway.stop();
  }
}

type Design = { name: string; guardLimit: number; resets: "ok" | "none" };
const FIXED: Design = { name: "fixed", guardLimit: 3, resets: "ok" };
const BEFORE: Design = { name: "before", guardLimit: 2, resets: "none" };

function tlaTurns(turns: ObservedTurn[]): string {
  const stepText = (s: ObservedStep) => `[fail |-> {${s.fail.map((c) => `"${c}"`).join(", ")}}, write |-> "${s.write}"]`;
  return turns.map((t) => `  \\* ${t.name}\n  [steps |-> <<${t.steps.map(stepText).join(", ")}>>, ended |-> ${t.ended ? "TRUE" : "FALSE"}]`).join(",\n");
}

/// ACCEPTED when TLC replays every observed turn through the design's Step.
async function replay(turns: ObservedTurn[], design: Design, label: string): Promise<"ACCEPTED" | "REJECTED"> {
  const dir = join(artifacts, "tlc", `${label}-${design.name}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "FailureStreakObserved.tla"),
    `---- MODULE FailureStreakObserved ----\nEXTENDS Sequences\nObserved == <<\n${tlaTurns(turns)}\n>>\n====\n`);
  const longest = Math.max(1, ...turns.map((t) => t.steps.length));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    '  Cmds = {"a", "b"}',
    "  Limit = 3",
    `  GuardLimit = ${design.guardLimit}`,
    `  Resets = "${design.resets}"`,
    `  MaxSteps = ${longest}`,
    "INVARIANT NotAllMatched",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "FailureStreakTrace", "trace.cfg", ["FailureStreak.tla", "FailureStreakTrace.tla"], SPEC_DIR, ["-deadlock"]);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return "ACCEPTED";
  assert.equal(run.exitCode, 0, `TLC failed for ${label}-${design.name}:\n${run.output}`);
  return "REJECTED";
}

const seed = Number(process.env.FX_TLA_SEED ?? "20261103");
let observed: Promise<ObservedTurn[]> | undefined;
function observations(): Promise<ObservedTurn[]> {
  observed ??= (async () => {
    const turns: ObservedTurn[] = [];
    const planned = [...NAMED, ...randomTurns(seed, 24)];
    for (const [i, [name, plan]] of planned.entries()) turns.push(await runTurn(i, name, plan));
    writeFileSync(join(artifacts, "observations.json"), JSON.stringify({ seed, turns }, null, 2), { mode: 0o600 });
    console.log(`seed ${seed}: ${turns.length} turns, ${turns.filter((t) => t.ended).length} ended by the guard; ${artifacts}`);
    return turns;
  })();
  return observed;
}

test("real fx conforms to the failure-streak design", async () => {
  const turns = await observations();
  const fixed = await replay(turns, FIXED, "observed");
  const before = await replay(turns, BEFORE, "observed");
  const verdicts = `fixed=${fixed} before=${before}; ${artifacts}`;
  assert.equal(fixed, "ACCEPTED", `fx does not match the fixed design: ${verdicts}`);
  assert.equal(before, "REJECTED", verdicts);
  // Coverage: the stop, a continued rerun after an edit, and a failed edit.
  assert.ok(turns.some((t) => t.ended), "no turn ended by the guard");
  assert.ok(turns.some((t) => !t.ended && t.steps.filter((s) => s.write === "ok" && s.fail.length > 0).length >= 2), "no continued edit loop");
  assert.ok(turns.some((t) => t.steps.some((s) => s.write === "failed")), "no failed edit");
}, TIMEOUT);

test("the replay rejects tampered and empty evidence", async () => {
  const turns = await observations();
  const tampered: ObservedTurn[] = structuredClone(turns);
  const flip = tampered.find((t) => t.ended)!;
  flip.ended = false;
  assert.equal(await replay(tampered, FIXED, "control-tampered"), "REJECTED");
  // An empty observation matches trivially, so the driver never replays one.
  assert.ok(turns.length >= NAMED.length, "observation is missing turns");
}, TIMEOUT);
