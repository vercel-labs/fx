// Exhaustive TLC checks of tests/tla/acp/AcpTakeover.tla: the design, the today
// config (no folder cleanup), the planted bugs, and the witnesses.
// The rows here match the AcpTakeover rows in tests/tla/acp/check.sh.
// Each row names a config and its expected verdict:
//   "-"           TLC finds no error (the design and today-rest)
//   "temporal"    TLC reports a temporal property violated (today)
//   an invariant  TLC reports that invariant violated (planted bugs and witnesses)
// A row that misses its verdict makes the run exit non-zero. For each row this
// prints the distinct state count, the depth, and the time TLC took.
//
//   bun tests/tla/drivers/acp/takeover/check-spec.ts
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, tlcToolchain, writeJson } from "./tlc";

const SPEC = "AcpTakeover";
const SPEC_FILE = `${SPEC}.tla`;

type Row = { config: string; expect: "-" | "temporal" | string };

const ROWS: Row[] = [
  { config: "AcpTakeover", expect: "-" },
  { config: "AcpTakeover-today", expect: "temporal" },
  { config: "AcpTakeover-today-rest", expect: "-" },
  { config: "AcpTakeover-remove-live", expect: "NoLiveFolderRemoved" },
  { config: "AcpTakeover-remove-no-lock", expect: "FolderRemovedByHolder" },
  { config: "AcpTakeover-remove-on-timeout", expect: "NoRemovalAfterTimeout" },
  { config: "AcpTakeover-two-holders", expect: "AtMostOneHolder" },
  { config: "AcpTakeover-restore-grant", expect: "GrantOwnedByHolder" },
  { config: "AcpTakeover-restore-queue", expect: "QueueOwnedByHolder" },
  { config: "AcpTakeover-restore-question", expect: "QuestionOwnedByHolder" },
  { config: "AcpTakeover-continue-turn", expect: "CallsAreAsked" },
  { config: "AcpTakeover-line-by-other", expect: "LineWrittenByHolder" },
  { config: "AcpTakeover-witness-busy", expect: "NoBusyLoad" },
  { config: "AcpTakeover-witness-repair", expect: "NoRepairedTurn" },
  { config: "AcpTakeover-witness-cleanup", expect: "NoDeadFolderRemoved" },
  { config: "AcpTakeover-witness-reconnect", expect: "NoFollowerConnected" },
];

type Result = { config: string; expect: string; ok: boolean; detail: string; states: number | null; depth: number | null; seconds: number };

async function main() {
  tlcToolchain();
  const reportDir = outDir("acp-takeover");
  const results: Result[] = [];

  for (const row of ROWS) {
    const cfg = `${row.config}.cfg`;
    const run = await runTlc(join(reportDir, row.config), SPEC_FILE, cfg, [SPEC_FILE, cfg], SPEC_DIR, []);
    let ok: boolean;
    let detail: string;
    if (row.expect === "-") {
      ok = run.exitCode === 0 && /No error has been found/.test(run.output);
      detail = ok ? "no error" : `exit ${run.exitCode}`;
    } else if (row.expect === "temporal") {
      ok = run.exitCode !== 0 && /Temporal properties were violated/.test(run.output);
      detail = ok ? "temporal property violated, as required" : `exit ${run.exitCode}`;
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
