// Exhaustive TLC check of tests/tla/acp/AcpSystemPrompt.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone, which
// shows that property catches that mistake.
//
//   bun tests/tla/drivers/acp/system_prompt/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "v1-refused-on-new",
    note: "session/new refuses ACP v1's object, as fx did before",
    from: `Accepted == IF Fixed THEN V1 \\cup {"none"} ELSE Old \\cup {"none"}`,
    to: `Accepted == IF Fixed THEN {"none"} ELSE Old \\cup {"none"}`,
    expect: "V1Accepted",
  },
  {
    id: "array-accepted",
    note: "session/new still takes the older bare array",
    from: `Accepted == IF Fixed THEN V1 \\cup {"none"} ELSE Old \\cup {"none"}`,
    to: `Accepted == IF Fixed THEN V1 \\cup Old \\cup {"none"} ELSE Old \\cup {"none"}`,
    expect: "OtherShapesRefused",
  },
  {
    id: "load-ignores-prompt",
    note: "a load with a v1 prompt keeps the stored one, as fx did before",
    from: `             /\\ open' = TRUE\n             /\\ stored' = p\n             /\\ last' = Obs(op, p, TRUE, 0, FALSE, "none")\n             /\\ UNCHANGED exists`,
    to: `             /\\ open' = TRUE\n             /\\ last' = Obs(op, p, TRUE, 0, FALSE, "none")\n             /\\ UNCHANGED <<exists, stored>>`,
    expect: "LoadAppliesPrompt",
  },
  {
    id: "refused-load-opens",
    note: "a load with a prompt fx refuses still opens the session",
    from: `             /\\ last' = Obs(op, p, FALSE, -32602, FALSE, "none")\n             /\\ UNCHANGED state`,
    to: `             /\\ last' = Obs(op, p, FALSE, -32602, FALSE, "none")\n             /\\ open' = TRUE\n             /\\ UNCHANGED <<exists, stored>>`,
    expect: "RefusalChangesNothing",
  },
  {
    id: "bad-load-accepted",
    note: "a load with an unsupported shape succeeds, as fx did before",
    from: `             /\\ last' = Obs(op, p, FALSE, -32602, FALSE, "none")\n             /\\ UNCHANGED state`,
    to: `             /\\ last' = Obs(op, p, TRUE, 0, FALSE, "none")\n             /\\ UNCHANGED state`,
    expect: "OtherShapesRefused",
  },
  {
    id: "refusal-code",
    note: "a refused load answers -32600 instead of -32602",
    from: `             /\\ last' = Obs(op, p, FALSE, -32602, FALSE, "none")\n             /\\ UNCHANGED state`,
    to: `             /\\ last' = Obs(op, p, FALSE, -32600, FALSE, "none")\n             /\\ UNCHANGED state`,
    expect: "OtherShapesRefused",
  },
  {
    id: "no-prompt-clears",
    note: "a load without systemPrompt drops the stored prompt",
    from: `             /\\ last' = Obs(op, p, TRUE, 0, FALSE, "none")\n             /\\ UNCHANGED <<exists, stored>>`,
    to: `             /\\ last' = Obs(op, p, TRUE, 0, FALSE, "none")\n             /\\ stored' = "none"\n             /\\ UNCHANGED exists`,
    expect: "NoPromptKeepsStored",
  },
  {
    id: "new-drops-prompt",
    note: "session/new doesn't store the prompt it took",
    from: `       THEN /\\ open' = TRUE\n            /\\ stored' = p`,
    to: `       THEN /\\ open' = TRUE\n            /\\ stored' = "none"`,
    expect: "NewStoresPrompt",
  },
  {
    id: "turn-sends-nothing",
    note: "a turn's model request leaves out the stored prompt",
    from: `    /\\ last' = Obs("prompt", "none", TRUE, 0, FALSE, stored)`,
    to: `    /\\ last' = Obs("prompt", "none", TRUE, 0, FALSE, "none")`,
    expect: "TurnSendsStored",
  },
  {
    id: "capability-missing",
    note: "initialize stops listing sessionCapabilities.systemPrompt",
    from: `    /\\ last' = Obs("restart", "none", TRUE, 0, TRUE, "none")`,
    to: `    /\\ last' = Obs("restart", "none", TRUE, 0, FALSE, "none")`,
    expect: "CapabilityListed",
  },
];

const SPEC_FILES = ["AcpSystemPrompt.tla", "MCAcpSystemPrompt.tla", "MCAcpSystemPrompt.cfg"];
const ACTION_PROPERTIES = new Set([
  "V1Accepted", "OtherShapesRefused", "RefusalChangesNothing", "NewStoresPrompt", "LoadAppliesPrompt", "NoPromptKeepsStored",
]);

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Fixed = TRUE",
    "INIT Init",
    "NEXT Next",
    `${ACTION_PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT"} ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-system-prompt-spec");

  const base = await runTlc(join(reportDir, "base"), "MCAcpSystemPrompt.tla", "MCAcpSystemPrompt.cfg", SPEC_FILES);
  const basePassed = base.exitCode === 0 && /No error has been found/.test(base.output);
  console.log(`base spec: ${basePassed ? "PASS" : "FAIL"} (exit ${base.exitCode}, ${base.distinctStates} distinct states, depth ${base.depth})`);

  const source = readFileSync(join(SPEC_DIR, "AcpSystemPrompt.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpSystemPrompt.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpSystemPrompt.tla", "Target.cfg", ["MCAcpSystemPrompt.tla"]);
    const killed = run.exitCode !== 0 && run.violated === mutant.expect;
    console.log(`mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${run.exitCode}, violated ${run.violated ?? "none"}, expected ${mutant.expect})`);
    mutants.push({ ...mutant, exitCode: run.exitCode, violated: run.violated, killed });
  }

  const summary = {
    toolchain: tool,
    spec_sha256: Object.fromEntries(SPEC_FILES.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    base: { passed: basePassed, exitCode: base.exitCode, distinctStates: base.distinctStates, depth: base.depth, argv: base.argv },
    mutants,
    allKilled: mutants.every((mutant) => mutant.killed),
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`mutants killed: ${mutants.filter((mutant) => mutant.killed).length}/${mutants.length}`);
  console.log(`report: ${reportDir}`);
  if (!basePassed || !summary.allKilled) process.exit(1);
}

await main();
