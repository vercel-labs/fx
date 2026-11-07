// Exhaustive TLC check of tests/tla/acp/AcpSharedSession.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone, which
// shows that property catches that mistake. The rules have not landed in
// src/acp/ yet, and several clients on one session need the leader's socket,
// so there is no driver of fx here; the model's Today configs, in
// tests/tla/acp/check.sh, show fx now.
//
//   bun tests/tla/drivers/acp/shared_session/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "answer-keeps-others",
    note: "the first answer doesn't cancel the request on the other clients",
    from: `            /\\ chan' = [d \\in Conns |-> IF d \\in sentTo \\ {c} THEN Append(chan[d], CancelMsg(perm.id)) ELSE chan[d]]`,
    to: `            /\\ UNCHANGED chan`,
    expect: "NoOrphanRequest",
  },
  {
    id: "late-answer-applied",
    note: "an answer that comes after the request was decided is applied too",
    from: `    /\\ IF shown[c] = perm.id /\\ ~perm.decided\n       THEN /\\ perm' = [perm EXCEPT !.decided = TRUE]`,
    to: `    /\\ IF shown[c] = perm.id\n       THEN /\\ perm' = [perm EXCEPT !.decided = TRUE]`,
    expect: "DecidedOnce",
  },
  {
    id: "joiner-without-request",
    note: "a client that opens the session while a request waits doesn't get it",
    from: `           ask == IF Rules /\\ Waiting THEN <<Req(perm.id)>> ELSE <<>>`,
    to: `           ask == <<>>`,
    expect: "RequestReachesAll",
  },
  {
    id: "request-to-sender-only",
    note: "the request goes only to the client whose prompt runs, as today",
    from: `           to == IF Rules THEN {d \\in Conns : open[d]} ELSE {d \\in {turn} : open[d]}`,
    to: `           to == {d \\in {turn} : open[d]}`,
    expect: "RequestReachesAll",
  },
  {
    id: "decided-request-to-joiner",
    note: "a client that opens the session gets a request that was already decided",
    from: `           ask == IF Rules /\\ Waiting THEN <<Req(perm.id)>> ELSE <<>>`,
    to: `           ask == IF Rules /\\ perm.id # 0 THEN <<Req(perm.id)>> ELSE <<>>`,
    expect: "NoOrphanRequest",
  },
  {
    id: "cancel-keeps-request",
    note: "session/cancel stops the turn but leaves the waiting request on the clients",
    from: `                    /\\ chan' = [d \\in Conns |-> IF d \\in sentTo THEN Append(chan[d], CancelMsg(perm.id)) ELSE chan[d]]`,
    to: `                    /\\ UNCHANGED chan`,
    expect: "NoOrphanRequest",
  },
  {
    id: "prompt-to-sender",
    note: "a prompt goes back to its sender too",
    from: `IF Rules /\\ open[d] /\\ d # c THEN Append(chan[d], Echo(k)) ELSE chan[d]]`,
    to: `IF Rules /\\ open[d] THEN Append(chan[d], Echo(k)) ELSE chan[d]]`,
    expect: "NoSelfEcho",
  },
  {
    id: "prompt-not-sent",
    note: "the other clients don't get a client's prompt",
    from: `IF Rules /\\ open[d] /\\ d # c THEN Append(chan[d], Echo(k)) ELSE chan[d]]`,
    to: `IF FALSE THEN Append(chan[d], Echo(k)) ELSE chan[d]]`,
    expect: "EchoComplete",
  },
  {
    id: "clients-not-on-close",
    note: "the list of clients doesn't go out when a client closes the session",
    from: `       /\\ chan' = [d \\in Conns |-> chan[d] \\o RosterOut(d, now)]`,
    to: `       /\\ UNCHANGED chan`,
    expect: "RosterCurrent",
  },
  {
    id: "clients-not-to-joiner",
    note: "a client that opens the session doesn't get the list of clients",
    from: `IF d = c THEN chan[d] \\o ask \\o RosterOut(d, now)`,
    to: `IF d = c THEN chan[d] \\o ask`,
    expect: "RosterCurrent",
  },
  {
    id: "cancel-sender-only",
    note: "only the client whose prompt runs can stop the turn, as today",
    from: `    /\\ IF Rules \\/ c = turn`,
    to: `    /\\ IF c = turn`,
    expect: "CancelStops",
  },
];

const SPEC_FILES = ["AcpSharedSession.tla", "MCAcpSharedSession.tla", "MCAcpSharedSession.cfg", "MCAcpSharedSessionThree.cfg"];

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    `    Conns = {"c1", "c2"}`,
    "    MaxPrompts = 2",
    "    MaxAsks = 2",
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
  const reportDir = outDir("acp-shared-session-spec");

  const bases = [];
  for (const cfg of ["MCAcpSharedSession.cfg", "MCAcpSharedSessionThree.cfg"]) {
    const run = await runTlc(join(reportDir, "base", cfg), "MCAcpSharedSession.tla", cfg, SPEC_FILES);
    const passed = run.exitCode === 0 && /No error has been found/.test(run.output);
    console.log(`base ${cfg}: ${passed ? "PASS" : "FAIL"} (exit ${run.exitCode}, ${run.distinctStates} distinct states, depth ${run.depth})`);
    bases.push({ cfg, passed, exitCode: run.exitCode, distinctStates: run.distinctStates, depth: run.depth });
  }

  const source = readFileSync(join(SPEC_DIR, "AcpSharedSession.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpSharedSession.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpSharedSession.tla", "Target.cfg", ["MCAcpSharedSession.tla"]);
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
