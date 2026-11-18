// Exhaustive TLC checks of tests/tla/acp/AcpLeader.tla plus its planted bugs.
// The base config must find no error. The Today config, fx acp before the
// leader record, must violate RecordFollowsLock. Each planted bug must violate
// the property it names, checked alone, which shows that property catches that
// mistake. The model covers the lock of a session and the leader socket that
// names its holder: a holder records itself once its socket listens; a process
// whose socket cannot start takes the lock with no record; a reader reaches the
// process its lock file named; and a socket that does not answer is stale only
// when its process is gone.
//
//   bun tests/tla/drivers/acp/leader/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Replacement = { from: string; to: string };
type Mutant = { id: string; note: string; replacements: Replacement[]; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "record-before-listen",
    note: "the holder records its socket before the socket listens",
    replacements: [
      {
        from: String.raw`/\ holder = p /\ listening[p] /\ record # p`,
        to: String.raw`/\ holder = p /\ record # p`,
      },
    ],
    expect: "RecordNamesHolder",
  },
  {
    id: "unlock-before-clear",
    note: "the holder unlocks while its record still names it",
    replacements: [
      {
        from: String.raw`/\ holder = p /\ record # p /\ ~leads[p]`,
        to: String.raw`/\ holder = p`,
      },
    ],
    expect: "RecordNamesHolder",
  },
  {
    id: "fixed-path",
    note: "a reader connects to any listening process, not the one its lock file named",
    replacements: [
      {
        from: String.raw`/\ fconn' = ftarget`,
        to: String.raw`/\ fconn' \in {q \in Procs : listening[q]}`,
      },
    ],
    expect: "ReachedTarget",
  },
  {
    id: "list-stays",
    note: "the session is not unlisted when it is released, and the lock releases while it is listed",
    replacements: [
      {
        from: ["/\\ record' = None", "    /\\ leads' = [leads EXCEPT ![p] = FALSE]"].join("\n"),
        to: ["/\\ record' = None", "    /\\ UNCHANGED <<leads>>"].join("\n"),
      },
      {
        from: String.raw`/\ holder = p /\ record # p /\ ~leads[p]`,
        to: String.raw`/\ holder = p /\ record # p`,
      },
    ],
    expect: "LeadsImpliesHolds",
  },
  {
    id: "stop-before-clear",
    note: "the socket stops while sessions are still open and recorded",
    replacements: [
      {
        from: "\nNext ==\n",
        to: [
          "",
          "StopSocket(p) ==",
          String.raw`    /\ alive[p] /\ listening[p]`,
          String.raw`    /\ listening' = [listening EXCEPT ![p] = FALSE]`,
          String.raw`    /\ UNCHANGED <<started, alive, failed, locked, holder, record, leads>>`,
          String.raw`    /\ UNCHANGED followVars`,
          "",
          "Next ==",
          String.raw`    \/ \E p \in Procs : StopSocket(p)`,
          "",
        ].join("\n"),
      },
    ],
    expect: "RecordNamesHolder",
  },
];

const SPEC_FILES = ["AcpLeader.tla", "MCAcpLeader.tla", "MCAcpLeader.cfg", "AcpLeaderToday.cfg"];

/// The config that checks one planted bug: its named invariant, alone.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Procs = {p1, p2, p3}",
    "    Records = TRUE",
    "INIT Init",
    "NEXT Next",
    `INVARIANT ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-leader-spec");

  const base = await runTlc(join(reportDir, "base"), "MCAcpLeader.tla", "MCAcpLeader.cfg", SPEC_FILES);
  const basePassed = base.exitCode === 0 && /No error has been found/.test(base.output);
  console.log(
    `base MCAcpLeader.cfg: ${basePassed ? "PASS" : "FAIL"} (exit ${base.exitCode}, ${base.distinctStates} distinct states, depth ${base.depth})`,
  );

  const today = await runTlc(join(reportDir, "today"), "MCAcpLeader.tla", "AcpLeaderToday.cfg", SPEC_FILES);
  const todayPassed = today.exitCode !== 0 && /Temporal properties were violated/.test(today.output);
  console.log(
    `today AcpLeaderToday.cfg: ${todayPassed ? "RecordFollowsLock violated, as required" : "FAIL"} (exit ${today.exitCode}, ${today.distinctStates} distinct states)`,
  );

  const source = readFileSync(join(SPEC_DIR, "AcpLeader.tla"), "utf8");
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
    writeFileSync(join(dir, "AcpLeader.tla"), text);
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpLeader.tla", "Target.cfg", ["MCAcpLeader.tla"]);
    const killed = run.exitCode !== 0 && run.violated === mutant.expect;
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
