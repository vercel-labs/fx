// Exhaustive TLC check of tests/tla/acp/AcpSessions.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone,
// which shows that property catches that mistake. The model's Today
// configs, in tests/tla/acp/check.sh, show fx before many sessions.
//
//   bun tests/tla/drivers/acp/sessions/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "new-replaces",
    note: "session/new closes the open session and stops its turn, as before",
    from: `              THEN /\\ open' = open \\cup {s}\n                   /\\ UNCHANGED <<turn, cur, answer>>`,
    to: `              THEN /\\ open' = {s}\n                   /\\ StopOthers(s)`,
    expect: "OthersUntouched",
  },
  {
    id: "cancel-all",
    note: "session/cancel stops the turn of every session on the connection",
    from: `       THEN /\\ turn' = [turn EXCEPT ![s] = "idle"]\n            /\\ cur' = [cur EXCEPT ![s] = 0]\n            /\\ answer' = [answer EXCEPT ![Run(s)] = "cancelled"]\n       ELSE UNCHANGED <<turn, cur, answer>>\n    /\\ last' = [op |-> "cancel"`,
    to: `       THEN /\\ turn' = [t \\in Sids |-> "idle"]\n            /\\ cur' = [t \\in Sids |-> 0]\n            /\\ answer' = [k \\in Keys |-> IF \\E t \\in Sids : turn[t] = "running" /\\ Run(t) = k THEN "cancelled" ELSE answer[k]]\n       ELSE UNCHANGED <<turn, cur, answer>>\n    /\\ last' = [op |-> "cancel"`,
    expect: "OthersUntouched",
  },
  {
    id: "close-all",
    note: "session/close closes every session on the connection",
    from: `       THEN /\\ open' = open \\ {s}`,
    to: `       THEN /\\ open' = {}`,
    expect: "OthersUntouched",
  },
  {
    id: "shared-workspace",
    note: "every session's tools act in the workspace of the latest session opened",
    from: `Used(s) == IF Rules THEN ws[s] ELSE bound`,
    to: `Used(s) == bound`,
    expect: "OwnWorkspace",
  },
  {
    id: "tag-latest",
    note: "a turn's updates carry the id of the session the latest request named",
    from: `Tag(s) == s`,
    to: `Tag(s) == last.sid`,
    expect: "RoutedUpdates",
  },
  {
    id: "reuse-reopens",
    note: "session/load of an open session stops its turn and opens it again",
    from: `                      /\\ UNCHANGED <<open, ws, bound, turn, cur, answer>>`,
    to: `                      /\\ turn' = [turn EXCEPT ![s] = "idle"]\n                      /\\ cur' = [cur EXCEPT ![s] = 0]\n                      /\\ answer' = IF turn[s] = "running" THEN [answer EXCEPT ![Run(s)] = "cancelled"] ELSE answer\n                      /\\ UNCHANGED <<open, ws, bound>>`,
    expect: "ReuseKeepsTurn",
  },
  {
    id: "close-forgets",
    note: "session/close of a running session stops its turn but never answers its prompt",
    from: `                    /\\ answer' = [answer EXCEPT ![Run(s)] = "cancelled"]\n               ELSE UNCHANGED <<turn, cur, answer>>\n       ELSE UNCHANGED <<open, turn, cur, answer>>`,
    to: `                    /\\ UNCHANGED answer\n               ELSE UNCHANGED <<turn, cur, answer>>\n       ELSE UNCHANGED <<open, turn, cur, answer>>`,
    expect: "NothingLost",
  },
];

const SPEC_FILES = ["AcpSessions.tla", "MCAcpSessions.tla", "MCAcpSessions.cfg", "MCAcpSessionsOverlap.cfg"];
const ACTION_PROPERTIES = new Set(["AnsweredOnce", "OthersUntouched", "ReuseKeepsTurn"]);

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    "    MaxPrompts = 2",
    "    MaxLoads = 1",
    "INIT Init",
    "NEXT Next",
    `${ACTION_PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT"} ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-sessions-spec");

  const bases = [];
  for (const [cfg, expect] of [["MCAcpSessions.cfg", null], ["MCAcpSessionsOverlap.cfg", "AtMostOneRunning"]] as const) {
    const run = await runTlc(join(reportDir, "base", cfg), "MCAcpSessions.tla", cfg, SPEC_FILES);
    const passed = expect === null
      ? run.exitCode === 0 && /No error has been found/.test(run.output)
      : run.exitCode !== 0 && run.violated === expect;
    console.log(`base ${cfg}: ${passed ? "PASS" : "FAIL"} (exit ${run.exitCode}, violated ${run.violated ?? "none"}, ${run.distinctStates} distinct states)`);
    bases.push({ cfg, expect, passed, exitCode: run.exitCode, violated: run.violated, distinctStates: run.distinctStates, depth: run.depth });
  }

  const source = readFileSync(join(SPEC_DIR, "AcpSessions.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpSessions.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpSessions.tla", "Target.cfg", ["MCAcpSessions.tla"]);
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
