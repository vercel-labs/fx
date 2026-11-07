// Exhaustive TLC check of tests/tla/acp/AcpSubagents.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone, which
// shows that property catches that mistake. The rules have not landed in
// src/acp/ yet; the model's Today configs, in tests/tla/acp/check.sh, show fx
// now.
//
//   bun tests/tla/drivers/acp/subagents/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "work-before-announce",
    note: "a new child's first update goes out before its announcement",
    from: `IF Rules THEN chan \\o <<Msg("announce", k, 0), Work(k)>> ELSE Append(chan, Work(k))`,
    to: `IF Rules THEN chan \\o <<Work(k), Msg("announce", k, 0)>> ELSE Append(chan, Work(k))`,
    expect: "AnnouncedFirst",
  },
  {
    id: "work-under-parent",
    note: "a child's work goes out under the parent's id, as today (X26)",
    from: `Work(k) == IF Rules THEN Msg("work", k, 0) ELSE Msg("parent_work", k, 0)`,
    to: `Work(k) == Msg("parent_work", k, 0)`,
    expect: "ChildIdUsed",
  },
  {
    id: "request-under-parent",
    note: "a child's permission request goes out under the parent's id",
    from: `    /\\ chan' = Append(chan, Msg(IF Rules THEN "req" ELSE "parent_req", k, asks + 1))`,
    to: `    /\\ chan' = Append(chan, Msg("parent_req", k, asks + 1))`,
    expect: "ChildIdUsed",
  },
  {
    id: "stopped-child-keeps-request",
    note: "a child's waiting request isn't cancelled when its work stops",
    from: `    /\\ chan' = IF perm[k] # 0 THEN Append(chan, Msg("cancel", k, perm[k])) ELSE chan`,
    to: `    /\\ chan' = chan`,
    expect: "RequestEndsWithChild",
  },
  {
    id: "parent-stop-keeps-requests",
    note: "stopping the parent leaves its children's requests on the client",
    from: `          /\\ chan' = chan \\o [i \\in 1..Len(stopped) |-> Msg("cancel", stopped[i], perm[stopped[i]])]`,
    to: `          /\\ chan' = chan`,
    expect: "RequestEndsWithChild",
  },
  {
    id: "child-stop-stops-parent",
    note: "stopping one child stops the parent's turn too",
    from: `       THEN /\\ ChildStops(k, TRUE)\n            /\\ UNCHANGED <<parent, flags>>`,
    to: `       THEN /\\ ChildStops(k, TRUE)\n            /\\ parent' = "idle"\n            /\\ UNCHANGED flags`,
    expect: "ChildStopLeavesParent",
  },
  {
    id: "parent-stop-leaves-children",
    note: "stopping the parent leaves its children running",
    from: `          /\\ child' = [k \\in Kids |-> IF k \\in running THEN (IF waiting[k] > 0 THEN "running" ELSE "idle") ELSE child[k]]`,
    to: `          /\\ child' = child`,
    expect: "ParentStopStopsChildren",
  },
  {
    id: "message-dropped-at-end",
    note: "a message that waited for a child is dropped when the child's work ends",
    from: `    /\\ steersTaken' = steersTaken + waiting[k]`,
    to: `    /\\ steersTaken' = steersTaken`,
    expect: "NoSteerLost",
  },
  {
    id: "report-lost",
    note: "a child's report never reaches the parent",
    from: `    /\\ reports' = IF report THEN reports + 1 ELSE reports`,
    to: `    /\\ reports' = reports`,
    expect: "NoReportLost",
  },
  {
    id: "child-prompt-refused",
    note: "a message to a child is refused",
    from: `    /\\ seen[k] /\\ child[k] # "none" /\\ steersSent < MaxSteers\n    /\\ IF Rules`,
    to: `    /\\ seen[k] /\\ child[k] # "none" /\\ steersSent < MaxSteers\n    /\\ IF FALSE`,
    expect: "ChildPromptsWork",
  },
  {
    id: "child-cancel-refused",
    note: "session/cancel with a child's id is refused",
    from: `    /\\ seen[k] /\\ child[k] = "running"\n    /\\ IF Rules`,
    to: `    /\\ seen[k] /\\ child[k] = "running"\n    /\\ IF FALSE`,
    expect: "ChildCancelWorks",
  },
  {
    id: "replay-without-children",
    note: "a reload replays no child",
    from: `           replay(k) == IF Rules THEN <<Msg("announce", k, 0), Work(k)>> ELSE <<>>`,
    to: `           replay(k) == <<>>`,
    expect: "ReplayComplete",
  },
  {
    id: "replay-reissues-decided",
    note: "a reload sends the child's latest request even when it was decided",
    from: `           asksOut(k) == IF perm[k] # 0 THEN <<Msg(IF Rules THEN "req" ELSE "parent_req", k, perm[k])>> ELSE <<>>`,
    to: `           asksOut(k) == IF asks # 0 THEN <<Msg("req", k, asks)>> ELSE <<>>`,
    expect: "RequestEndsWithChild",
  },
];

const SPEC_FILES = ["AcpSubagents.tla", "MCAcpSubagents.tla", "MCAcpSubagents.cfg"];
const ACTION_PROPERTIES = new Set(["ParentStopStopsChildren", "ChildStopLeavesParent"]);

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    `    Kids = {"k1", "k2"}`,
    "    MaxChildTurns = 3",
    "    MaxAsks = 2",
    "    MaxSteers = 2",
    "    MaxLoads = 1",
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
  const reportDir = outDir("acp-subagents-spec");

  const run0 = await runTlc(join(reportDir, "base"), "MCAcpSubagents.tla", "MCAcpSubagents.cfg", SPEC_FILES);
  const basePassed = run0.exitCode === 0 && /No error has been found/.test(run0.output);
  console.log(`base MCAcpSubagents.cfg: ${basePassed ? "PASS" : "FAIL"} (exit ${run0.exitCode}, ${run0.distinctStates} distinct states, depth ${run0.depth})`);

  const source = readFileSync(join(SPEC_DIR, "AcpSubagents.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpSubagents.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpSubagents.tla", "Target.cfg", ["MCAcpSubagents.tla"]);
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
