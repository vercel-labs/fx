// Exhaustive and random TLC checks of tests/tla/acp/AcpSessionStaysOpen.tla.
// The rows here match the AcpSessionStaysOpen rows in tests/tla/acp/check.sh.
// Each row names a config and its expected verdict:
//   "-"             TLC finds no error (design configs)
//   "simulate"      the random simulation finds no error (simulate configs)
//   an invariant    TLC reports that invariant or action property as violated
// A row that misses its verdict makes the run exit non-zero. For each row this
// prints the distinct state count, the depth, and the time TLC took, so a
// design's cost can be read from the output.
//
//   bun tests/tla/drivers/acp/session_stays_open/check-spec.ts
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, tlcToolchain, writeJson } from "./tlc";

const SPEC = "AcpSessionStaysOpen";
const SPEC_FILE = `${SPEC}.tla`;
const SIMULATE = ["-simulate", "num=20000", "-depth", "20", "-seed", "1"];

type Row = { config: string; expect: "-" | "simulate" | string };

const ROWS: Row[] = [
  { config: "current-stays-open", expect: "StaysOpenWhileMember" },
  { config: "current-one-main", expect: "OneMainInJoinOrder" },
  { config: "current-denied", expect: "DeniedOnlyWhenNoMember" },
  { config: "design-a", expect: "-" },
  { config: "design-b", expect: "-" },
  { config: "mutant-a-captured", expect: "NoDanglingClient" },
  { config: "mutant-a-newest", expect: "OneMainInJoinOrder" },
  { config: "mutant-b-free", expect: "NoDanglingClient" },
  { config: "mutant-b-exit-early", expect: "NoExitWhileServing" },
  { config: "mutant-mode-any", expect: "MainChangesModeOnly" },
  { config: "mutant-a-free", expect: "NoDanglingClient" },
  { config: "mutant-a-close-cancels-others", expect: "LeaveAffectsOnlyOwnInput" },
  { config: "mutant-b-join-withdraws", expect: "LastKeepQueueRuns" },
  { config: "mutant-close-cancels-others", expect: "LeaveAffectsOnlyOwnInput" },
  { config: "mutant-leave-keeps-queue", expect: "LeftInputNeverRuns" },
  { config: "mutant-last-no-cancel", expect: "LastLeaverRule" },
  { config: "mutant-b-free-freed", expect: "SessionFreedWhenIdle" },
  { config: "simulate-ideal-a", expect: "simulate" },
  { config: "simulate-nonideal-a", expect: "simulate" },
  { config: "simulate-ideal-b", expect: "simulate" },
  { config: "simulate-nonideal-b", expect: "simulate" },
];

type Result = { config: string; expect: string; ok: boolean; detail: string; states: number | null; depth: number | null; seconds: number };

async function main() {
  tlcToolchain();
  const reportDir = outDir("acp-session-stays-open");
  const results: Result[] = [];

  for (const row of ROWS) {
    const cfg = `${row.config}.cfg`;
    const run = await runTlc(
      join(reportDir, row.config),
      SPEC_FILE,
      cfg,
      [SPEC_FILE, cfg],
      SPEC_DIR,
      row.expect === "simulate" ? SIMULATE : [],
    );
    let ok: boolean;
    let detail: string;
    if (row.expect === "-") {
      ok = run.exitCode === 0 && /No error has been found/.test(run.output);
      detail = ok ? "no error" : `exit ${run.exitCode}`;
    } else if (row.expect === "simulate") {
      ok = run.exitCode === 0 && !/^Error:/m.test(run.output);
      detail = ok ? "simulation found no error" : `exit ${run.exitCode}`;
    } else {
      ok = run.exitCode !== 0 && run.violated === row.expect;
      detail = ok ? `${row.expect} violated, as required` : `violated ${run.violated ?? "none"}, exit ${run.exitCode}`;
    }
    results.push({
      config: row.config,
      expect: row.expect,
      ok,
      detail,
      states: run.distinctStates,
      depth: run.depth,
      seconds: Math.round(run.durationMs / 100) / 10,
    });
    const tag = ok ? "ok  " : "FAIL";
    console.log(
      `${tag} ${row.config}: ${detail} (distinct states ${run.distinctStates ?? "n/a"}, depth ${run.depth ?? "n/a"}, ${(run.durationMs / 1000).toFixed(1)} s)`,
    );
  }

  writeJson(join(reportDir, "results.json"), results);
  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length} of ${results.length} rows as expected; logs and results.json in ${reportDir}`);
  if (failed.length > 0) process.exit(1);
}

await main();
