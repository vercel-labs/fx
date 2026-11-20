// Exhaustive TLC checks of tests/tla/acp/AcpSessionReaders.tla plus its planted
// bugs. The design (Rules TRUE) must find no error. fx today (Rules FALSE) must
// violate AtMostOneWorker or NoDoubleJoin. Each planted bug is checked alone:
// it must violate the invariant it names. A bug that TLC does not catch is
// reported as SURVIVED, and the run exits non-zero.
//
// The model covers two readers of one session (the owner and a follower), each
// with a start, a reap, a withdrawal, or a cancel, and the owner's close. Each
// planted bug edits one step of the design's text; the text match must hit
// exactly once, or the run throws.
//
//   bun tests/tla/drivers/acp/session_readers/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Replacement = { from: string; to: string };
type Mutant = { id: string; note: string; replacements: Replacement[]; expect: string[] };

const SPEC_FILES = [
  "AcpSessionReaders.tla",
  "MCAcpSessionReaders.tla",
  "MCAcpSessionReaders.cfg",
  "AcpSessionReadersToday.cfg",
];

// The design's claim of a new turn, split into a check and an act: the check
// reads the slot and the guards, and the act claims without a test.
const CLAIM_NEW_HEAD = String.raw`ClaimNew(r) ==
    /\ kind[r] = "prompt"
    /\ pc[r] \in {"check", "retry"}
    /\ ~closing
    /\ ~joining
    /\ slot = 0
    /\ tcount < MaxTurns
`;
const CLAIM_NEW_SPLIT = String.raw`ClaimNewCheck(r) ==
    /\ kind[r] = "prompt"
    /\ pc[r] \in {"check", "retry"}
    /\ ~closing
    /\ ~joining
    /\ slot = 0
    /\ tcount < MaxTurns
    /\ pc' = [pc EXCEPT ![r] = "claimReady"]
    /\ UNCHANGED <<slot, tcount, tstate, joins, tfreed, ptr, kind, reqs, users, closing, registered, closeBegun, freed, joining, claimAfterClose>>

ClaimNewAct(r) ==
    /\ pc[r] = "claimReady"
`;

const MUTANTS: Mutant[] = [
  {
    id: "check-then-start-unlocked",
    note: "(1) the claim checks the slot, then acts in a later step, with no test in between",
    replacements: [
      { from: CLAIM_NEW_HEAD, to: CLAIM_NEW_SPLIT },
      { from: "    \\/ ClaimNew(r)\n", to: "    \\/ ClaimNewCheck(r)\n    \\/ ClaimNewAct(r)\n" },
    ],
    expect: ["AtMostOneWorker"],
  },
  {
    id: "reap-without-take",
    note: "(2) the reap joins the turn but does not take it: the slot keeps it and joining is not set, so another reap joins it again",
    replacements: [
      {
        from: String.raw`    /\ slot' = 0
    /\ pc' = [pc EXCEPT ![r] = "joinOwn"]
    /\ joining' = TRUE`,
        to: String.raw`    /\ slot' = slot
    /\ pc' = [pc EXCEPT ![r] = "joinOwn"]
    /\ joining' = joining`,
      },
    ],
    expect: ["NoDoubleJoin"],
  },
  {
    id: "free-without-waiting-for-users",
    note: "(3) the close frees the session without waiting for the followers' uses",
    replacements: [
      {
        from: String.raw`    /\ users = 0
    /\ pc' = [pc EXCEPT ![Owner] = "cCancel"]`,
        to: String.raw`    /\ pc' = [pc EXCEPT ![Owner] = "cCancel"]`,
      },
    ],
    expect: ["NoUseAfterFree"],
  },
  {
    id: "start-allowed-after-closing",
    note: "(4) a claim is allowed once the close has begun; the wait and the unregister are kept",
    replacements: [
      {
        from: String.raw`    /\ ~closing
    /\ ~joining
    /\ slot = 0
    /\ tcount < MaxTurns
`,
        to: String.raw`    /\ ~joining
    /\ slot = 0
    /\ tcount < MaxTurns
`,
      },
    ],
    expect: ["NoClaimAfterClose"],
  },
  {
    id: "unregister-after-the-wait",
    note: "(5) the close waits for the users, then unregisters: a follower can retain after the wait",
    replacements: [
      {
        from: String.raw`IF Rules THEN "cDetach" ELSE "cCancel"`,
        to: String.raw`IF Rules THEN "cWait" ELSE "cCancel"`,
      },
      {
        from: String.raw`    /\ registered' = FALSE
    /\ pc' = [pc EXCEPT ![Owner] = "cWait"]`,
        to: String.raw`    /\ registered' = FALSE
    /\ pc' = [pc EXCEPT ![Owner] = "cCancel"]`,
      },
      {
        from: String.raw`    /\ users = 0
    /\ pc' = [pc EXCEPT ![Owner] = "cCancel"]`,
        to: String.raw`    /\ users = 0
    /\ pc' = [pc EXCEPT ![Owner] = "cDetach"]`,
      },
    ],
    expect: ["NoUseAfterFree"],
  },
  {
    id: "claim-does-not-wait-while-joining",
    note: "(6) a claim runs while a taken turn is still being joined, so two turns are alive",
    replacements: [
      {
        from: String.raw`    /\ ~joining
    /\ slot = 0
    /\ tcount < MaxTurns
`,
        to: String.raw`    /\ slot = 0
    /\ tcount < MaxTurns
`,
      },
    ],
    expect: ["AtMostOneWorker"],
  },
  {
    id: "extra-start-after-closing-without-wait",
    note: "extra: (3) and (4) together. Without the wait, the closing guard is the only guard left",
    replacements: [
      {
        from: String.raw`    /\ users = 0
    /\ pc' = [pc EXCEPT ![Owner] = "cCancel"]`,
        to: String.raw`    /\ pc' = [pc EXCEPT ![Owner] = "cCancel"]`,
      },
      {
        from: String.raw`    /\ ~closing
    /\ ~joining
    /\ slot = 0
    /\ tcount < MaxTurns
`,
        to: String.raw`    /\ ~joining
    /\ slot = 0
    /\ tcount < MaxTurns
`,
      },
    ],
    expect: ["NoLeakedWorker", "NoUseAfterFree"],
  },
];

const MC_CONSTANTS = ["    MaxTurns = 2", "    MaxReq = 2", "    Rules = TRUE"];

/// The config that checks one planted bug alone: the invariants it names.
function targetCfg(names: string[]): string {
  return ["CONSTANTS", ...MC_CONSTANTS, "INIT Init", "NEXT Next", "INVARIANTS", ...names.map((name) => `    ${name}`), "CHECK_DEADLOCK FALSE", ""].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-session-readers-spec");

  const base = await runTlc(join(reportDir, "base"), "MCAcpSessionReaders.tla", "MCAcpSessionReaders.cfg", SPEC_FILES);
  // Safety invariants and the liveness property CloseFinishes are all checked by this config.
  const basePassed = base.exitCode === 0 && /No error has been found/.test(base.output);
  console.log(
    `base MCAcpSessionReaders.cfg: ${basePassed ? "PASS" : "FAIL"} (exit ${base.exitCode}, ${base.distinctStates} distinct states, depth ${base.depth})`,
  );

  const today = await runTlc(join(reportDir, "today"), "MCAcpSessionReaders.tla", "AcpSessionReadersToday.cfg", SPEC_FILES);
  const todayPassed = today.exitCode !== 0 && (today.violated === "AtMostOneWorker" || today.violated === "NoDoubleJoin");
  console.log(
    `today AcpSessionReadersToday.cfg: ${todayPassed ? `${today.violated} violated, as required` : "FAIL"} (exit ${today.exitCode}, violated ${today.violated ?? "none"}, ${today.distinctStates} distinct states)`,
  );

  const source = readFileSync(join(SPEC_DIR, "AcpSessionReaders.tla"), "utf8");
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
    writeFileSync(join(dir, "AcpSessionReaders.tla"), text);
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpSessionReaders.tla", "Target.cfg", ["MCAcpSessionReaders.tla"]);
    const killed = run.exitCode !== 0 && run.violated !== null && mutant.expect.includes(run.violated);
    console.log(
      `mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${run.exitCode}, violated ${run.violated ?? "none"}, expected ${mutant.expect.join(" or ")}, ${run.distinctStates} distinct states)`,
    );
    mutants.push({ id: mutant.id, note: mutant.note, expect: mutant.expect, exitCode: run.exitCode, violated: run.violated, distinctStates: run.distinctStates, killed });
  }

  const allKilled = mutants.every((mutant) => mutant.killed);
  const summary = {
    toolchain: tool,
    spec_sha256: Object.fromEntries(SPEC_FILES.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    base: { passed: basePassed, exitCode: base.exitCode, distinctStates: base.distinctStates, depth: base.depth },
    today: { passed: todayPassed, exitCode: today.exitCode, violated: today.violated, distinctStates: today.distinctStates },
    mutants,
    allKilled,
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`mutants killed: ${mutants.filter((mutant) => mutant.killed).length}/${mutants.length}`);
  console.log(`report: ${reportDir}`);
  if (!basePassed || !todayPassed || !allKilled) process.exit(1);
}

await main();
