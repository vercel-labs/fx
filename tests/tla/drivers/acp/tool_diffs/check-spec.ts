// Exhaustive TLC check of tests/tla/acp/AcpToolDiffs.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone,
// which shows that property catches that mistake. The model's Today
// config, in tests/tla/acp/check.sh, shows fx acp before tool diffs.
//
//   bun tests/tla/drivers/acp/tool_diffs/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string; ask: string; big: string };

const MUTANTS: Mutant[] = [
  {
    id: "completed-without-diff",
    note: "a committed edit's completed update carries text only, as before",
    from: `    /\\ chan' = Append(chan, Upd(c, "completed", TRUE,\n                                IF ShowsDiff(c) THEN <<before[c], after[c]>> ELSE None))`,
    to: `    /\\ chan' = Append(chan, Upd(c, "completed", TRUE, None))`,
    expect: "Complete",
    ask: `{"c2"}`,
    big: "{}",
  },
  {
    id: "stale-old",
    note: "the completed diff's old text is the file as fx finds it at completion, not just before the commit",
    from: `IF ShowsDiff(c) THEN <<before[c], after[c]>> ELSE None))`,
    to: `IF ShowsDiff(c) THEN <<ver[FileOf[c]], after[c]>> ELSE None))`,
    expect: "ShownMatchesDisk",
    ask: "{}",
    big: "{}",
  },
  {
    id: "failed-keeps-diff",
    note: "a denied edit fails with an update that leaves the proposed diff in place",
    from: `    /\\ st' = [st EXCEPT ![c] = "failed"]\n    /\\ chan' = Append(chan, Upd(c, "failed", TRUE, None))\n    /\\ UNCHANGED <<ver, pre, post, before, after, view>>`,
    to: `    /\\ st' = [st EXCEPT ![c] = "failed"]\n    /\\ chan' = Append(chan, Upd(c, "failed", FALSE, None))\n    /\\ UNCHANGED <<ver, pre, post, before, after, view>>`,
    expect: "NoDiffUnlessCommitted",
    ask: `{"c1", "c2"}`,
    big: "{}",
  },
  {
    id: "big-sends-diff",
    note: "a call over the limit sends its diff anyway",
    from: `ShowsDiff(c) == Rules /\\ c \\notin Big`,
    to: `ShowsDiff(c) == Rules`,
    expect: "BigNoDiff",
    ask: "{}",
    big: `{"c3"}`,
  },
  {
    id: "diff-then-text",
    note: "the diff goes in its own update, and the text update after it replaces it",
    from: `    /\\ chan' = Append(chan, Upd(c, "completed", TRUE,\n                                IF ShowsDiff(c) THEN <<before[c], after[c]>> ELSE None))`,
    to: `    /\\ chan' = chan \\o <<Upd(c, "completed", TRUE, IF ShowsDiff(c) THEN <<before[c], after[c]>> ELSE None), Upd(c, "completed", TRUE, None)>>`,
    expect: "Complete",
    ask: "{}",
    big: "{}",
  },
  {
    id: "proposal-from-disk",
    note: "the permission request's diff starts from the file as it is when fx asks, not as the edit was prepared",
    from: `IF ShowsDiff(c) THEN <<pre[c], post[c]>> ELSE None))`,
    to: `IF ShowsDiff(c) THEN <<ver[FileOf[c]], post[c]>> ELSE None))`,
    expect: "ProposedMatchesPrepared",
    ask: `{"c2"}`,
    big: "{}",
  },
];

const SPEC_FILES = ["AcpToolDiffs.tla", "MCAcpToolDiffs.tla", "MCAcpToolDiffs.cfg", "MCAcpToolDiffsAsk.cfg"];

function targetCfg(target: string, ask: string, big: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    '    Calls = {"c1", "c2", "c3"}',
    '    Files = {"f1", "f2"}',
    "    FileOf <- MCFileOf",
    "    InitVer <- MCInitVer",
    `    Ask = ${ask}`,
    `    Big = ${big}`,
    "    Vs = {2, 3, 4}",
    "INIT Init",
    "NEXT Next",
    `INVARIANT ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-tool-diffs-spec");
  const bases = [];
  for (const cfg of ["MCAcpToolDiffs.cfg", "MCAcpToolDiffsAsk.cfg"]) {
    const run = await runTlc(join(reportDir, "base", cfg), "MCAcpToolDiffs.tla", cfg, SPEC_FILES);
    const passed = run.exitCode === 0 && /No error has been found/.test(run.output);
    console.log(`base ${cfg}: ${passed ? "PASS" : "FAIL"} (exit ${run.exitCode}, ${run.distinctStates} distinct states, depth ${run.depth})`);
    bases.push({ cfg, passed, exitCode: run.exitCode, distinctStates: run.distinctStates, depth: run.depth });
  }
  const source = readFileSync(join(SPEC_DIR, "AcpToolDiffs.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpToolDiffs.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect, mutant.ask, mutant.big));
    const run = await runTlc(dir, "MCAcpToolDiffs.tla", "Target.cfg", ["MCAcpToolDiffs.tla"]);
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
