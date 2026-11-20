// Exhaustive TLC check of tests/tla/acp/AcpForkRewind.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone, which
// shows that property catches that mistake. The rules have not landed in
// src/acp/ yet; the model's Today configs, in tests/tla/acp/check.sh, show fx
// now.
//
//   bun tests/tla/drivers/acp/fork_rewind/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "fork-includes-prompt",
    note: "a fork before a prompt also copies that prompt's turn",
    from: `forks' = Append(forks, [log |-> SubSeq(log, 1, i - 1), src |-> log, point |-> i])`,
    to: `forks' = Append(forks, [log |-> SubSeq(log, 1, IF i <= Len(log) THEN i ELSE i - 1), src |-> log, point |-> i])`,
    expect: "ForkIsPrefix",
  },
  {
    id: "fork-changes-source",
    note: "a fork also cuts the source back to the fork's turns",
    from: `            /\\ UNCHANGED <<log, flags>>`,
    to: `            /\\ log' = SubSeq(log, 1, i - 1)\n            /\\ UNCHANGED flags`,
    expect: "ForkLeavesSource",
  },
  {
    id: "rewind-one-short",
    note: "a rewind also removes the turn before the prompt",
    from: `            /\\ LET kept == SubSeq(log, 1, i - 1) IN`,
    to: `            /\\ LET kept == SubSeq(log, 1, IF i > 1 THEN i - 2 ELSE 0) IN`,
    expect: "RewindIsPrefix",
  },
  {
    id: "rewind-without-notice",
    note: "a rewind doesn't tell the other clients",
    from: `               /\\ chan' = [d \\in Conns |-> IF open[d] /\\ d # c THEN Append(chan[d], Replaced) ELSE chan[d]]`,
    to: `               /\\ UNCHANGED chan`,
    expect: "InSync",
  },
  {
    id: "caller-keeps-old-history",
    note: "the client that rewinds keeps its old copy",
    from: `               /\\ copy' = [copy EXCEPT ![c] = kept]`,
    to: `               /\\ UNCHANGED copy`,
    expect: "InSync",
  },
  {
    id: "rewind-same-generation",
    note: "a rewind keeps the log's generation, so an old position still counts",
    from: `               /\\ gen' = gen + 1`,
    to: `               /\\ UNCHANGED gen`,
    expect: "InSync",
  },
  {
    id: "position-trusted-across-rewind",
    note: "a catch-up trusts a position from before a rewind",
    from: `    /\\ LET known == Rules /\\ pos[c].g = gen /\\ pos[c].n <= Len(log) IN`,
    to: `    /\\ LET known == Rules /\\ pos[c].n <= Len(log) IN`,
    expect: "InSync",
  },
  {
    id: "fork-while-running",
    note: "a fork runs while a turn runs",
    from: `       ELSE /\\ ~running\n            /\\ forks' =`,
    to: `       ELSE /\\ TRUE\n            /\\ forks' =`,
    expect: "NotWhileRunning",
  },
  {
    id: "rewind-while-running",
    note: "a rewind runs while a turn runs",
    from: `       ELSE /\\ ~running\n            /\\ LET kept`,
    to: `       ELSE /\\ TRUE\n            /\\ LET kept`,
    expect: "NotWhileRunning",
  },
  {
    id: "fork-refused",
    note: "session/fork is refused, as today",
    from: `    /\\ open[c] /\\ Len(forks) < MaxForks /\\ i \\in 1..(Len(log) + 1)\n    /\\ IF ~Rules`,
    to: `    /\\ open[c] /\\ Len(forks) < MaxForks /\\ i \\in 1..(Len(log) + 1)\n    /\\ IF TRUE`,
    expect: "ForkAvailable",
  },
  {
    id: "rewind-refused",
    note: "_sh.fx/session/rewind is refused, as today",
    from: `    /\\ open[c] /\\ chan[c] = <<>> /\\ rewinds < MaxRewinds /\\ i \\in 1..Len(log)\n    /\\ IF ~Rules`,
    to: `    /\\ open[c] /\\ chan[c] = <<>> /\\ rewinds < MaxRewinds /\\ i \\in 1..Len(log)\n    /\\ IF TRUE`,
    expect: "RewindAvailable",
  },
];

const SPEC_FILES = ["AcpForkRewind.tla", "MCAcpForkRewind.tla", "MCAcpForkRewind.cfg"];
const ACTION_PROPERTIES = new Set(["ForkLeavesSource", "NotWhileRunning"]);

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    `    Conns = {"c1", "c2"}`,
    "    MaxTurns = 3",
    "    MaxForks = 1",
    "    MaxRewinds = 1",
    "INIT Init",
    "NEXT Next",
    "CONSTRAINT ChanBound",
    `${ACTION_PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT"} ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-fork-rewind-spec");

  const run0 = await runTlc(join(reportDir, "base"), "MCAcpForkRewind.tla", "MCAcpForkRewind.cfg", SPEC_FILES);
  const basePassed = run0.exitCode === 0 && /No error has been found/.test(run0.output);
  console.log(`base MCAcpForkRewind.cfg: ${basePassed ? "PASS" : "FAIL"} (exit ${run0.exitCode}, ${run0.distinctStates} distinct states, depth ${run0.depth})`);

  const source = readFileSync(join(SPEC_DIR, "AcpForkRewind.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpForkRewind.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpForkRewind.tla", "Target.cfg", ["MCAcpForkRewind.tla"]);
    const violated = ACTION_PROPERTIES.has(mutant.expect)
      ? (/Action property (\w+) is violated/.exec(run.output)?.[1] ?? run.violated)
      : run.violated;
    const killed = run.exitCode !== 0 && violated === mutant.expect;
    console.log(`mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${run.exitCode}, violated ${violated ?? "none"}, expected ${mutant.expect})`);
    mutants.push({ ...mutant, exitCode: run.exitCode, violated, killed });
  }

  const summary = {
    toolchain: tool,
    spec_sha256: Object.fromEntries(SPEC_FILES.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    base: { passed: basePassed, exitCode: run0.exitCode, distinctStates: run0.distinctStates, depth: run0.depth },
    mutants,
    allKilled: mutants.every((mutant) => mutant.killed),
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`mutants killed: ${mutants.filter((mutant) => mutant.killed).length}/${mutants.length}`);
  console.log(`report: ${reportDir}`);
  if (!basePassed || !summary.allKilled) process.exit(1);
}

await main();
