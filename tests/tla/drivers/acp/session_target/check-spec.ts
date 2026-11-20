// Exhaustive TLC check of tests/tla/acp/AcpSessionTarget.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone, which
// shows that property catches that mistake.
//
//   bun tests/tla/drivers/acp/session_target/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "unknown-is-invalid-params",
    note: "a session that isn't open gets -32602, as fx did before",
    from: `IF Fixed THEN Obs(op, t, FALSE, -32002, TRUE, "none")`,
    to: `IF Fixed THEN Obs(op, t, FALSE, -32602, TRUE, "none")`,
    expect: "UnknownSessionAnswer",
  },
  {
    id: "unknown-without-data",
    note: "the -32002 answer leaves out data.sessionId",
    from: `IF Fixed THEN Obs(op, t, FALSE, -32002, TRUE, "none")`,
    to: `IF Fixed THEN Obs(op, t, FALSE, -32002, FALSE, "none")`,
    expect: "UnknownSessionAnswer",
  },
  {
    id: "close-other-errors",
    note: "closing a session that isn't open fails, as fx did before",
    from: `/\\ last' = IF Fixed THEN Obs("close", t, TRUE, 0, FALSE, "empty")`,
    to: `/\\ last' = IF Fixed THEN Obs("close", t, FALSE, -32602, FALSE, "none")`,
    expect: "CloseIdempotent",
  },
  {
    id: "close-other-closes-open",
    note: "closing another session closes the open one",
    from: `                        ELSE Obs("close", t, FALSE, -32602, FALSE, "none")\n             /\\ UNCHANGED state`,
    to: `                        ELSE Obs("close", t, FALSE, -32602, FALSE, "none")\n             /\\ open' = "none"\n             /\\ UNCHANGED <<created, saved, nextNew>>`,
    expect: "CloseIdempotent",
  },
  {
    id: "close-keeps-open",
    note: "closing the open session leaves it open",
    from: `/\\ last' = Obs("close", t, TRUE, 0, FALSE, "empty")\n             /\\ open' = "none"`,
    to: `/\\ last' = Obs("close", t, TRUE, 0, FALSE, "empty")\n             /\\ open' = open`,
    expect: "CloseClosesOpen",
  },
  {
    id: "oversize-auth-code",
    note: "an oversized frame gets -32000, as fx did before",
    from: `IF Fixed THEN -32600 ELSE -32000`,
    to: `IF Fixed THEN -32000 ELSE -32000`,
    expect: "NeverAuthCode",
  },
  {
    id: "oversize-invalid-params",
    note: "an oversized frame gets -32602",
    from: `IF Fixed THEN -32600 ELSE -32000`,
    to: `IF Fixed THEN -32602 ELSE -32000`,
    expect: "OversizeIs32600",
  },
  {
    id: "missing-id-not-found",
    note: "a request with no sessionId gets -32002",
    from: `InvalidParams(op, t) == Obs(op, t, FALSE, -32602, FALSE, "none")`,
    to: `InvalidParams(op, t) == Obs(op, t, FALSE, -32002, FALSE, "none")`,
    expect: "MissingIdIs32602",
  },
  {
    id: "error-closes-session",
    note: "a request for an unknown session closes the open one",
    from: `      [] OTHER ->\n             /\\ last' = NotFound(op, t)\n             /\\ UNCHANGED state\n\nClose(t) ==`,
    to: `      [] OTHER ->\n             /\\ last' = NotFound(op, t)\n             /\\ open' = "none"\n             /\\ UNCHANGED <<created, saved, nextNew>>\n\nClose(t) ==`,
    expect: "ErrorChangesNothing",
  },
  {
    id: "saved-load-refused",
    note: "a saved session can't be loaded",
    from: `      [] t \\in saved \\/ t = open ->`,
    to: `      [] t = open ->`,
    expect: "SavedSessionOpens",
  },
  {
    id: "open-session-refused",
    note: "a request for the open session fails",
    from: `             /\\ last' = Obs(op, t, TRUE, 0, FALSE, Answer(op))`,
    to: `             /\\ last' = NotFound(op, t)`,
    expect: "OpenSessionAnswers",
  },
  {
    id: "close-answers-null",
    note: "closing a session that isn't open answers null instead of {}",
    from: `/\\ last' = IF Fixed THEN Obs("close", t, TRUE, 0, FALSE, "empty")`,
    to: `/\\ last' = IF Fixed THEN Obs("close", t, TRUE, 0, FALSE, "null")`,
    expect: "CloseIdempotent",
  },
];

const SPEC_FILES = ["AcpSessionTarget.tla", "MCAcpSessionTarget.tla", "MCAcpSessionTarget.cfg"];
const ACTION_PROPERTIES = new Set([
  "UnknownSessionAnswer", "CloseIdempotent", "CloseClosesOpen", "OpenSessionAnswers", "SavedSessionOpens", "ErrorChangesNothing",
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
  const reportDir = outDir("acp-session-target-spec");

  const base = await runTlc(join(reportDir, "base"), "MCAcpSessionTarget.tla", "MCAcpSessionTarget.cfg", SPEC_FILES);
  const basePassed = base.exitCode === 0 && /No error has been found/.test(base.output);
  console.log(`base spec: ${basePassed ? "PASS" : "FAIL"} (exit ${base.exitCode}, ${base.distinctStates} distinct states, depth ${base.depth})`);

  const source = readFileSync(join(SPEC_DIR, "AcpSessionTarget.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpSessionTarget.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpSessionTarget.tla", "Target.cfg", ["MCAcpSessionTarget.tla"]);
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
