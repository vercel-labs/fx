// Exhaustive and random TLC checks of tests/tla/acp/AcpApprovals.tla.
// The rows here match the AcpApprovals rows in tests/tla/acp/check.sh.
// Each row names a config and its expected verdict:
//   "-"             TLC finds no error (design configs)
//   "simulate"      the random simulation finds no error (simulate configs)
//   an invariant    TLC reports that invariant or action property as violated
//                   (current-*, mutant-*, and witness-* configs)
// A row that misses its verdict makes the run exit non-zero. For each row this
// prints the distinct state count, the depth, and the time TLC took, so a
// design's cost can be read from the output.
//
//   bun tests/tla/drivers/acp/approvals/check-spec.ts
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, tlcToolchain, writeJson } from "./tlc";

const SPEC = "AcpApprovals";
const SPEC_FILE = `${SPEC}.tla`;
const SIMULATE = ["-simulate", "num=20000", "-depth", "20", "-seed", "1"];

type Row = { config: string; expect: "-" | "simulate" | string };

const ROWS: Row[] = [
  { config: "approvals-design-a", expect: "-" },
  { config: "approvals-design-b", expect: "-" },
  { config: "approvals-current-fanout", expect: "EveryClientGetsQuestion" },
  { config: "approvals-current-reask", expect: "NoReAsk" },
  { config: "approvals-current-sender-always", expect: "OnlySenderAlways" },
  { config: "approvals-mutant-a-always-anyone", expect: "OnlySenderAlways" },
  { config: "approvals-mutant-a-second-answer", expect: "DecisionStable" },
  { config: "approvals-mutant-a-no-cancel", expect: "OthersTold" },
  { config: "approvals-mutant-a-reask", expect: "NoReAsk" },
  { config: "approvals-mutant-a-joiner-misses", expect: "EveryClientGetsQuestion" },
  { config: "approvals-mutant-a-no-deny-last", expect: "DeniedWhenNoClient" },
  { config: "approvals-mutant-a-foreign-id", expect: "WinnerHadRequest" },
  { config: "approvals-mutant-a-write-after", expect: "OthersTold" },
  { config: "approvals-mutant-a-follower-dropped", expect: "ValidAnswerNotRefused" },
  { config: "approvals-mutant-b-host-collide", expect: "IdsDistinct" },
  { config: "approvals-simulate-ideal-a", expect: "simulate" },
  { config: "approvals-simulate-nonideal-a", expect: "simulate" },
  { config: "approvals-simulate-ideal-b", expect: "simulate" },
  { config: "approvals-simulate-nonideal-b", expect: "simulate" },
  { config: "approvals-witness-follower", expect: "NoFollowerWin" },
  { config: "approvals-witness-always", expect: "NoAlwaysWin" },
  { config: "approvals-single-a", expect: "-" },
  { config: "approvals-single-b", expect: "-" },
];

type Result = { config: string; expect: string; ok: boolean; detail: string; states: number | null; depth: number | null; seconds: number };

async function main() {
  tlcToolchain();
  const reportDir = outDir("acp-approvals");
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
