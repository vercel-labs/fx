// Exhaustive TLC check of tests/tla/acp/AcpSessionState.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone, which
// shows that property catches that mistake. The rules have not landed in
// src/acp/ yet; the model's Today configs, in tests/tla/acp/check.sh, show fx
// now, and driver.ts runs fx along them.
//
//   bun tests/tla/drivers/acp/session_state/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

/// The two bases: two clients on one session, and one client with two
/// sessions in two folders.
type Base = "clients" | "folders";
type Mutant = { id: string; note: string; from: string; to: string; expect: string; base: Base };

const MUTANTS: Mutant[] = [
  {
    id: "open-without-state",
    note: "opening a session doesn't send its current state",
    from: `    /\\ chan' = [chan EXCEPT ![c] = IF Rules THEN Append(@, StateMsg(s, st[s], "none")) ELSE @]`,
    to: `    /\\ chan' = chan`,
    expect: "StateCurrent",
    base: "clients",
  },
  {
    id: "wait-not-reported",
    note: "a turn that waits for a permission answer doesn't report requires_action",
    from: `    /\\ Write(s, "requires_action", "none", FALSE)`,
    to: `    /\\ Write(s, "none", "none", FALSE)`,
    expect: "StateCurrent",
    base: "clients",
  },
  {
    id: "updates-before-running",
    note: "a turn's updates go out before its running state",
    from: `    /\\ turns' = turns + 1\n    /\\ Write(s, "running", "none", FALSE)`,
    to: `    /\\ turns' = turns + 1\n    /\\ UNCHANGED chan`,
    expect: "UpdatesWhileRunning",
    base: "clients",
  },
  {
    id: "stop-on-running",
    note: "the running state carries a stopReason",
    from: `    /\\ turns' = turns + 1\n    /\\ Write(s, "running", "none", FALSE)`,
    to: `    /\\ turns' = turns + 1\n    /\\ Write(s, "running", "end_turn", FALSE)`,
    expect: "IdleCarriesStop",
    base: "clients",
  },
  {
    id: "hint-before-save",
    note: "the list hint goes out when the turn starts, before the save that changes the list",
    from: `    /\\ Write(s, "idle", stop, TRUE)`,
    to: `    /\\ Write(s, "idle", stop, FALSE)`,
    expect: "ListFresh",
    base: "folders",
  },
  {
    id: "retitle-without-hint",
    note: "a new title doesn't send a hint",
    from: `    /\\ Write(s, "none", "none", TRUE)\n    /\\ UNCHANGED <<exists, open, st, owner, saved, deleted,`,
    to: `    /\\ Write(s, "none", "none", FALSE)\n    /\\ UNCHANGED <<exists, open, st, owner, saved, deleted,`,
    expect: "ListFresh",
    base: "folders",
  },
  {
    id: "all-folders-not-hinted",
    note: "a client that listed every folder gets no hints",
    from: `hintOut == IF Rules /\\ listChanged /\\ Covers(c, FolderOf[s])`,
    to: `hintOut == IF Rules /\\ listChanged /\\ FolderOf[s] \\in subs[c]`,
    expect: "ListFresh",
    base: "folders",
  },
  {
    id: "list-busy",
    note: "session/list is refused while a turn runs on the connection, as today (X24)",
    from: `    /\\ IF ~Rules /\\ Busy(c)`,
    to: `    /\\ IF Busy(c)`,
    expect: "ListAnswered",
    base: "folders",
  },
  {
    id: "status-this-connection",
    note: "session/status says open only when the calling connection has the session open",
    from: `    IF Rules THEN Truth(s)`,
    to: `    IF Rules THEN [Truth(s) EXCEPT !.status = IF @ = "none" THEN @ ELSE IF s \\in open[c] THEN "open" ELSE "saved"]`,
    expect: "StatusTruthful",
    base: "clients",
  },
  {
    id: "status-without-state",
    note: "session/status of an open session leaves out its state",
    from: `    IF Rules THEN Truth(s)`,
    to: `    IF Rules THEN [Truth(s) EXCEPT !.state = "none"]`,
    expect: "StatusTruthful",
    base: "clients",
  },
];

const SPEC_FILES = ["AcpSessionState.tla", "MCAcpSessionState.tla", "MCAcpSessionState.cfg", "MCAcpSessionStateLists.cfg"];

const BASES: Record<Base, { conns: string; sessions: string }> = {
  clients: { conns: `{"c1", "c2"}`, sessions: `{"s1"}` },
  folders: { conns: `{"c1"}`, sessions: `{"s1", "s2"}` },
};

/// Checks a mutant against its target property alone, on the base that
/// property needs, so a kill shows that property catches the mistake.
function targetCfg(target: string, base: Base): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    `    Conns = ${BASES[base].conns}`,
    `    Sessions = ${BASES[base].sessions}`,
    "    FolderOf <- MCFolderOf",
    "    MaxTurns = 2",
    "    MaxChanges = 1",
    "    AllowApproval = TRUE",
    "INIT Init",
    "NEXT Next",
    "CONSTRAINT ChanBound",
    `INVARIANT ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-session-state-spec");

  const bases = [];
  for (const cfg of ["MCAcpSessionState.cfg", "MCAcpSessionStateLists.cfg"]) {
    const run = await runTlc(join(reportDir, "base", cfg), "MCAcpSessionState.tla", cfg, SPEC_FILES);
    const passed = run.exitCode === 0 && /No error has been found/.test(run.output);
    console.log(`base ${cfg}: ${passed ? "PASS" : "FAIL"} (exit ${run.exitCode}, ${run.distinctStates} distinct states, depth ${run.depth})`);
    bases.push({ cfg, passed, exitCode: run.exitCode, distinctStates: run.distinctStates, depth: run.depth });
  }

  const source = readFileSync(join(SPEC_DIR, "AcpSessionState.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpSessionState.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect, mutant.base));
    const run = await runTlc(dir, "MCAcpSessionState.tla", "Target.cfg", ["MCAcpSessionState.tla"]);
    const killed = run.exitCode !== 0 && run.violated === mutant.expect;
    console.log(`mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${run.exitCode}, violated ${run.violated ?? "none"}, expected ${mutant.expect})`);
    mutants.push({ ...mutant, exitCode: run.exitCode, violated: run.violated, killed });
  }

  const summary = {
    toolchain: tool,
    spec_sha256: Object.fromEntries(SPEC_FILES.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    bases,
    mutants,
    allKilled: mutants.every((mutant) => mutant.killed),
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`mutants killed: ${mutants.filter((mutant) => mutant.killed).length}/${mutants.length}`);
  console.log(`report: ${reportDir}`);
  if (!bases.every((base) => base.passed) || !summary.allKilled) process.exit(1);
}

await main();
