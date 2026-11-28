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

type Edit = { from: string; to: string };
type Mutant = { id: string; note: string; edits: Edit[]; expect: string };

const lines = (...rows: string[]) => rows.join("\n");

const MUTANTS: Mutant[] = [
  {
    id: "work-before-announce",
    note: "a new child's first update goes out before its announcement",
    edits: [
      {
        from: String.raw`chan' = chan \o ToClient(<<Msg("announce", k, 0), Work(k)>>)`,
        to: String.raw`chan' = chan \o ToClient(<<Work(k), Msg("announce", k, 0)>>)`,
      },
    ],
    expect: "AnnouncedFirst",
  },
  {
    id: "work-under-parent",
    note: "a child's work goes out under the parent's id",
    edits: [{ from: String.raw`Work(k) == Msg("work", k, 0)`, to: String.raw`Work(k) == Msg("parent_work", k, 0)` }],
    expect: "ChildIdUsed",
  },
  {
    id: "request-under-parent",
    note: "a child's permission request goes out under the parent's id",
    edits: [
      {
        from: String.raw`chan' = chan \o ToClient(<<Msg("req", k, asks + 1)>>)`,
        to: String.raw`chan' = chan \o ToClient(<<Msg("parent_req", k, asks + 1)>>)`,
      },
    ],
    expect: "ChildIdUsed",
  },
  {
    id: "stopped-child-keeps-request",
    note: "a child's waiting request isn't cancelled when its work stops",
    edits: [
      {
        from: String.raw`chan' = IF perm[k] # 0 THEN Append(chan, Msg("cancel", k, perm[k])) ELSE chan`,
        to: String.raw`chan' = chan`,
      },
    ],
    expect: "RequestEndsWithChild",
  },
  {
    id: "parent-stop-keeps-requests",
    note: "stopping the parent leaves its children's requests on the client",
    edits: [
      {
        from: String.raw`chan' = chan \o [i \in 1..Len(stopped) |-> Msg("cancel", stopped[i], perm[stopped[i]])]`,
        to: String.raw`chan' = chan`,
      },
    ],
    expect: "RequestEndsWithChild",
  },
  {
    id: "child-stop-stops-parent",
    note: "stopping one child stops the parent's turn too",
    edits: [
      {
        from: String.raw`/\ UNCHANGED <<parent, flags>>`,
        to: lines(String.raw`/\ parent' = "idle"`, String.raw`            /\ UNCHANGED flags`),
      },
    ],
    expect: "ChildStopLeavesParent",
  },
  {
    id: "parent-stop-leaves-children",
    note: "stopping the parent leaves its children running",
    edits: [
      {
        from: String.raw`/\ child' = [k \in Kids |-> IF k \in running THEN (IF waiting[k] > 0 THEN "running" ELSE "idle") ELSE child[k]]`,
        to: String.raw`/\ child' = child`,
      },
    ],
    expect: "ParentStopStopsChildren",
  },
  {
    id: "message-dropped-at-end",
    note: "a message that waited for a child is dropped when the child's work ends",
    edits: [{ from: String.raw`/\ steersTaken' = steersTaken + waiting[k]`, to: String.raw`/\ steersTaken' = steersTaken` }],
    expect: "NoSteerLost",
  },
  {
    id: "report-lost",
    note: "a child's report never reaches the parent",
    edits: [{ from: String.raw`reports' = IF report THEN reports + 1 ELSE reports`, to: String.raw`reports' = reports` }],
    expect: "NoReportLost",
  },
  {
    id: "child-prompt-refused",
    note: "a message to a child is refused",
    edits: [
      {
        from: lines(String.raw`    /\ KnowsChild(k) /\ child[k] # "none" /\ steersSent < MaxSteers`, String.raw`    /\ IF Rules`),
        to: lines(String.raw`    /\ KnowsChild(k) /\ child[k] # "none" /\ steersSent < MaxSteers`, String.raw`    /\ IF FALSE`),
      },
    ],
    expect: "ChildPromptsWork",
  },
  {
    id: "child-cancel-refused",
    note: "session/cancel with a child's id is refused",
    edits: [
      {
        from: lines(String.raw`    /\ cancels' = cancels + 1`, String.raw`    /\ IF Rules`),
        to: lines(String.raw`    /\ cancels' = cancels + 1`, String.raw`    /\ IF FALSE`),
      },
    ],
    expect: "ChildCancelWorks",
  },
  {
    id: "replay-without-children",
    note: "a reload replays no child",
    edits: [{ from: String.raw`replay(k) == ToClient(<<Msg("announce", k, 0), Work(k)>>)`, to: String.raw`replay(k) == <<>>` }],
    expect: "ReplayComplete",
  },
  {
    id: "replay-reissues-decided",
    note: "a reload sends the child's latest request even when it was decided",
    edits: [
      {
        from: String.raw`asksOut(k) == IF perm[k] # 0 THEN ToClient(<<Msg("req", k, perm[k])>>) ELSE <<>>`,
        to: String.raw`asksOut(k) == IF asks # 0 THEN ToClient(<<Msg("req", k, asks)>>) ELSE <<>>`,
      },
    ],
    expect: "RequestEndsWithChild",
  },
  {
    id: "child-work-dropped",
    note: "a child's work never reaches the client, at its start or while it runs",
    edits: [
      {
        from: String.raw`chan' = chan \o ToClient(<<Msg("announce", k, 0), Work(k)>>)`,
        to: String.raw`chan' = chan \o ToClient(<<Msg("announce", k, 0)>>)`,
      },
      {
        from: lines(String.raw`ChildWork(k) ==`, String.raw`    /\ child[k] = "running"`, String.raw`    /\ chan' = chan \o ToClient(<<Work(k)>>)`),
        to: lines(String.raw`ChildWork(k) ==`, String.raw`    /\ child[k] = "running"`, String.raw`    /\ chan' = chan`),
      },
    ],
    expect: "WorkReachesClient",
  },
  {
    id: "child-request-not-sent",
    note: "a child's permission request never reaches the client",
    edits: [{ from: String.raw`chan' = chan \o ToClient(<<Msg("req", k, asks + 1)>>)`, to: String.raw`chan' = chan` }],
    expect: "RequestShown",
  },
  {
    id: "cancel-child-ignored",
    note: "fx ignores session/cancel of a child, and the client's cancel still counts",
    edits: [
      {
        from: lines(String.raw`       THEN /\ ChildStops(k, TRUE)`, String.raw`            /\ UNCHANGED <<parent, flags>>`),
        to: String.raw`       THEN /\ UNCHANGED <<parent, child, childTurns, perm, chan, waiting, steersTaken, reportsMade, reports, flags>>`,
      },
    ],
    expect: "CancelChildStops",
  },
  {
    id: "stopped-child-keeps-working",
    note: "a child that isn't running still sends its work",
    edits: [
      {
        from: lines(String.raw`ChildWork(k) ==`, String.raw`    /\ child[k] = "running"`),
        to: lines(String.raw`ChildWork(k) ==`, String.raw`    /\ child[k] # "none"`),
      },
    ],
    expect: "NoWorkWhenStopped",
  },
  {
    id: "reload-drops-waiting-request",
    note: "a reload forgets a child's request that still waits",
    edits: [{ from: String.raw`asksOut(k) == IF perm[k] # 0 THEN`, to: String.raw`asksOut(k) == IF FALSE THEN` }],
    expect: "RequestShown",
  },
  {
    id: "child-cancel-no-report",
    note: "a cancelled child makes no report, so the parent's tool call gets no result",
    edits: [
      {
        from: lines(String.raw`       THEN /\ ChildStops(k, TRUE)`, String.raw`            /\ UNCHANGED <<parent, flags>>`),
        to: lines(String.raw`       THEN /\ ChildStops(k, FALSE)`, String.raw`            /\ UNCHANGED <<parent, flags>>`),
      },
    ],
    expect: "CancelReports",
  },
  {
    id: "replay-without-history",
    note: "a reload replays a child's announcement but not its history",
    edits: [{ from: String.raw`replay(k) == ToClient(<<Msg("announce", k, 0), Work(k)>>)`, to: String.raw`replay(k) == ToClient(<<Msg("announce", k, 0)>>)` }],
    expect: "ReplayHasHistory",
  },
  {
    id: "steer-taken-twice",
    note: "a child's work takes a waiting message without leaving the queue",
    edits: [
      {
        from: lines(String.raw`    /\ waiting' = [waiting EXCEPT ![k] = @ - 1]`, String.raw`    /\ steersTaken' = steersTaken + 1`),
        to: lines(String.raw`    /\ steersTaken' = steersTaken + 1`, String.raw`    /\ UNCHANGED waiting`),
      },
    ],
    expect: "NoSteerLost",
  },
  {
    id: "steer-counted-not-run",
    note: "a waiting message counts as taken when its child stops, but no next turn starts",
    edits: [{ from: String.raw`childTurns' = IF waiting[k] > 0 THEN childTurns + 1 ELSE childTurns`, to: String.raw`childTurns' = childTurns` }],
    expect: "SteerRunsNext",
  },
];

const SPEC_FILES = ["AcpSubagents.tla", "MCAcpSubagents.tla", "MCAcpSubagents.cfg"];
const ACTION_PROPERTIES = new Set([
  "ParentStopStopsChildren",
  "ChildStopLeavesParent",
  "WorkReachesClient",
  "NoWorkWhenStopped",
  "CancelChildStops",
  "CancelReports",
  "SteerRunsNext",
  "ReplayHasHistory",
]);

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
    "    MaxCancels = 2",
    "    MaxLoads = 1",
    "INIT Init",
    "NEXT Next",
    "CONSTRAINT ChanBound",
    `${ACTION_PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT"} ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

/// Applies each edit once to the original source. A pattern that matches
/// other than once would make the planted bug ambiguous, so it is an error.
function mutate(source: string, mutant: Mutant): string {
  let text = source;
  for (const edit of mutant.edits) {
    const count = source.split(edit.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    text = text.split(edit.from).join(edit.to);
  }
  return text;
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
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpSubagents.tla"), mutate(source, mutant));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpSubagents.tla", "Target.cfg", ["MCAcpSubagents.tla"]);
    const violated = ACTION_PROPERTIES.has(mutant.expect)
      ? (/Action property (\w+) is violated/.exec(run.output)?.[1] ?? run.violated)
      : run.violated;
    const killed = run.exitCode !== 0 && violated === mutant.expect;
    console.log(`mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${run.exitCode}, violated ${violated ?? "none"}, expected ${mutant.expect})`);
    mutants.push({ id: mutant.id, note: mutant.note, expect: mutant.expect, exitCode: run.exitCode, violated, killed });
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
