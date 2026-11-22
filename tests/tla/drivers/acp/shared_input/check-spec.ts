// Exhaustive TLC checks of tests/tla/acp/AcpSharedInput.tla plus its planted
// bugs. The base config must find no error, with this branch's follower input
// (Rules TRUE). The Today config, fx before it, where a follower only watches,
// must violate FollowerPromptRuns. Each planted bug must violate the property
// it names, checked alone, which shows that property catches that mistake. A
// bug that TLC does not catch is reported as SURVIVED, and the run exits
// non-zero.
//
// TLC names a violated invariant, but reports a violated temporal property
// without its name, so a liveness target is matched by TLC's temporal message.
//
//   bun tests/tla/drivers/acp/shared_input/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Replacement = { from: string; to: string };
type Mutant = { id: string; note: string; replacements: Replacement[]; expect: string };

const SPEC_FILES = [
  "AcpSharedInput.tla",
  "MCAcpSharedInput.tla",
  "MCAcpSharedInput.cfg",
  "AcpSharedInputToday.cfg",
];

/// The temporal properties. Every other name in a planted bug is an invariant.
const PROPERTIES = new Set(["WaitingInputAnswered", "FollowerPromptRuns"]);

/// The constants every config here uses: this branch's follower input, two
/// requests for the owner and one for the follower.
const MC_CONSTANTS = ["    Rules = TRUE", "    MaxSends = 2", "    FollowerSends = 1"];

/// The config that checks one planted bug: its named property, alone.
function targetCfg(target: string): string {
  const kind = PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT";
  return ["CONSTANTS", ...MC_CONSTANTS, "SPECIFICATION Spec", `${kind} ${target}`, "CHECK_DEADLOCK FALSE", ""].join("\n");
}

/// Whether a run killed a mutant: exit non-zero, and the named property violated.
function killedBy(run: { exitCode: number; violated: string | null; output: string }, expect: string): boolean {
  if (run.exitCode === 0) return false;
  if (PROPERTIES.has(expect)) return /Temporal properties were violated/.test(run.output);
  return run.violated === expect;
}

const MUTANTS: Mutant[] = [
  {
    id: "answer-to-owner",
    note: "every answer goes to the owner, whatever the request's sender",
    replacements: [{ from: String.raw`Recipient(r) == r[1]`, to: String.raw`Recipient(r) == Owner` }],
    expect: "AnswerToSender",
  },
  {
    id: "echo-includes-sender",
    note: "a prompt that starts a turn is also sent to its sender",
    replacements: [{ from: String.raw`EchoTo(r) == PresentSet \ {r[1]}`, to: String.raw`EchoTo(r) == PresentSet` }],
    expect: "EchoExceptSender",
  },
  {
    id: "withdraw-by-id-only",
    note: "a leaving follower's queued prompt is not withdrawn, so it still runs",
    replacements: [{ from: String.raw`ELSE IF q[1][1] = c THEN Without(Tail(q), c)`, to: String.raw`ELSE IF FALSE THEN Without(Tail(q), c)` }],
    expect: "LeftInputNeverRuns",
  },
  {
    id: "only-owner-cancels",
    note: "only the owner's session/cancel stops the running turn; a follower's is handled and ignored",
    replacements: [{ from: String.raw`MayCancel(c) == c = Owner \/ Rules`, to: String.raw`MayCancel(c) == c = Owner` }],
    expect: "AnyClientCancels",
  },
  {
    id: "turn-starts-with-old-prompt",
    note: "a turn starts with the system prompt from before the last load",
    replacements: [{ from: String.raw`StartPrompt == sysNow`, to: String.raw`StartPrompt == sysBefore` }],
    expect: "NewTurnUsesCurrentPrompt",
  },
  {
    id: "load-changes-running-turn",
    note: "a load changes the system prompt of the turn that is running",
    replacements: [{ from: String.raw`  /\ turnSys' = turnSys`, to: String.raw`  /\ turnSys' = sysNow'` }],
    expect: "SystemPromptFromNextTurn",
  },
  {
    id: "queue-last-in-first",
    note: "the next queued prompt is the one that arrived last",
    replacements: [
      { from: String.raw`NextQueued == IF queue = <<>> THEN NoReq ELSE queue[1]`, to: String.raw`NextQueued == IF queue = <<>> THEN NoReq ELSE queue[Len(queue)]` },
      { from: String.raw`RestQueued == IF queue = <<>> THEN <<>> ELSE Tail(queue)`, to: String.raw`RestQueued == IF queue = <<>> THEN <<>> ELSE SubSeq(queue, 1, Len(queue) - 1)` },
    ],
    expect: "OneOrder",
  },
];

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-shared-input-spec");

  const base = await runTlc(join(reportDir, "base"), "MCAcpSharedInput.tla", "MCAcpSharedInput.cfg", SPEC_FILES);
  const basePassed = base.exitCode === 0 && /No error has been found/.test(base.output);
  console.log(
    `base MCAcpSharedInput.cfg: ${basePassed ? "PASS" : "FAIL"} (exit ${base.exitCode}, ${base.distinctStates} distinct states, depth ${base.depth})`,
  );

  const today = await runTlc(join(reportDir, "today"), "MCAcpSharedInput.tla", "AcpSharedInputToday.cfg", SPEC_FILES);
  const todayPassed = today.exitCode !== 0 && /Temporal properties were violated/.test(today.output);
  console.log(
    `today AcpSharedInputToday.cfg: ${todayPassed ? "FollowerPromptRuns violated, as required" : "FAIL"} (exit ${today.exitCode}, ${today.distinctStates} distinct states)`,
  );

  const source = readFileSync(join(SPEC_DIR, "AcpSharedInput.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    let text = source;
    for (const { from, to } of mutant.replacements) {
      const count = text.split(from).length - 1;
      if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
      text = text.replace(from, () => to);
    }
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpSharedInput.tla"), text);
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpSharedInput.tla", "Target.cfg", ["MCAcpSharedInput.tla"]);
    const killed = killedBy(run, mutant.expect);
    console.log(
      `mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${run.exitCode}, violated ${run.violated ?? "none"}, expected ${mutant.expect}, ${run.distinctStates} distinct states)`,
    );
    mutants.push({ id: mutant.id, note: mutant.note, expect: mutant.expect, exitCode: run.exitCode, violated: run.violated, distinctStates: run.distinctStates, killed });
  }

  const allKilled = mutants.every((mutant) => mutant.killed);
  const summary = {
    toolchain: tool,
    spec_sha256: Object.fromEntries(SPEC_FILES.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    base: { passed: basePassed, exitCode: base.exitCode, distinctStates: base.distinctStates, depth: base.depth },
    today: { passed: todayPassed, exitCode: today.exitCode, distinctStates: today.distinctStates },
    mutants,
    allKilled,
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`mutants killed: ${mutants.filter((mutant) => mutant.killed).length}/${mutants.length}`);
  console.log(`report: ${reportDir}`);
  if (!basePassed || !todayPassed || !allKilled) process.exit(1);
}

await main();
