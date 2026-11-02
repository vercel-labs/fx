// TLC gate for tests/tla/usage/UsageModel.tla: one run per check in a fresh
// folder, and the verdict each check must reach.
//
//   PASS     the configuration's properties hold.
//   CAUGHT   a planted bug is reported by the property it targets.
//   FINDING  a property stated for users is broken by the model of the code;
//            TLC's counterexample is kept in that run's tlc.log.
//
// It also simulates drivable behaviors (DriveSpec) in ideal and non-ideal
// conditions for driver.ts to replay against the real binary. Nothing here
// downloads anything or calls a model.
import { closeSync, cpSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, resolve } from "node:path";
import { TLA_ROOT, outDir, tlcToolchain } from "../../lib/tlc";

export const here = import.meta.dirname;
const tlaDir = join(TLA_ROOT, "usage");
const sha256 = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex");

function tools() {
  return tlcToolchain();
}

export type Verdict = "PASS" | "CAUGHT" | "FINDING";

export interface Check {
  label: string;
  expect: Verdict;
  /** For CAUGHT and FINDING: the invariant or property TLC must name. */
  names?: string;
  config: string;
  /** Planted bug: one exact text replacement in UsageModel.tla. */
  mutant?: { find: string; replace: string };
}

export interface CheckResult extends Check {
  exit: number;
  seconds: number;
  distinct?: number;
  violated?: string;
  verdict: Verdict | "ERROR";
  passed: boolean;
  log: string;
  modelSha256: string;
}

const cfg = (name: string) => readFileSync(join(tlaDir, name), "utf8");
const only = (text: string, keep: string[]) =>
  text.replace(/^(INVARIANTS|PROPERTIES)\n((?:    \w+\n)+)/gm, (_all, head: string, body: string) => {
    const kept = body.split("\n").filter((line) => keep.includes(line.trim()));
    return kept.length ? `${head}\n${kept.join("\n")}\n` : "";
  });

export function checks(): Check[] {
  const ideal = cfg("Ideal.cfg");
  const hostile = cfg("Hostile.cfg");
  const hostileSwitch = cfg("HostileSwitch.cfg");
  // A planted bug is checked against only the property it targets, so the
  // verdict cannot come from another property tripping first.
  const target = (base: string, name: string) => only(base, ["TypeOK", name]);
  return [
    { label: "ideal", expect: "PASS", config: ideal },
    { label: "hostile", expect: "PASS", config: hostile },
    { label: "hostile-switch", expect: "PASS", config: cfg("HostileSwitch.cfg") },
    {
      label: "bug-store-without-merge", expect: "CAUGHT", names: "CacheNeverRegresses", config: target(ideal, "CacheNeverRegresses"),
      mutant: { find: "        rec == Newer(stored, Fetched(f), Wall)", replace: "        rec == Fetched(f)" },
    },
    {
      label: "bug-always-read-finished", expect: "CAUGHT", names: "FinishedOncePerDay", config: target(ideal, "FinishedOncePerDay"),
      mutant: { find: "fin == m.finDay # Day(Wall)", replace: "fin == TRUE" },
    },
    {
      label: "bug-open-ignores-floor", expect: "CAUGHT", names: "OpenRespectsFloor", config: target(ideal, "OpenRespectsFloor"),
      mutant: { find: "    /\\ IF FloorClear(p)\n       THEN StartFetch(p, m)", replace: "    /\\ IF inflight[p] = None\n       THEN StartFetch(p, m)" },
    },
    {
      label: "bug-switch-keeps-old-numbers", expect: "CAUGHT", names: "ShowsOwnIdentity", config: target(ideal, "ShowsOwnIdentity"),
      mutant: { find: "/\\ shown' = [shown EXCEPT ![p] = IF open[p] THEN ViewOf(m, j, Wall) ELSE Hidden]", replace: "/\\ shown' = shown" },
    },
    {
      label: "bug-view-ignores-day", expect: "CAUGHT", names: "TodayIsToday", config: target(ideal, "TodayIsToday"),
      mutant: { find: "today |-> IF r.todayDay = Day(w) THEN r.todayAt ELSE None", replace: "today |-> r.todayAt" },
    },
    // Two bugs an earlier fx had, planted back.
    {
      label: "bug-future-stamp-wins", expect: "CAUGHT", names: "SuccessShowsToday", config: target(hostile, "SuccessShowsToday"),
      mutant: { find: "    LET xToday == x.todayAt # None /\\ x.todayAt <= w", replace: "    LET xToday == x.todayAt # None" },
    },
    {
      label: "bug-reload-replaces-memory", expect: "CAUGHT", names: "FinishedStaysShown", config: target(hostile, "FinishedStaysShown"),
      mutant: { find: "THEN m ELSE Newer(m, cache[i], Wall)", replace: "THEN m ELSE cache[i]" },
    },
    {
      label: "bug-r-held-by-floor", expect: "CAUGHT", names: "RAlwaysWorks", config: target(ideal, "RAlwaysWorks"),
      mutant: { find: "    /\\ open[p]\n    /\\ inflight[p] = None\n    /\\ StartFetch(p, m)", replace: "    /\\ open[p]\n    /\\ FloorClear(p)\n    /\\ StartFetch(p, m)" },
    },
    {
      label: "bug-switch-keeps-floor", expect: "CAUGHT", names: "OwedNeverWaitsOnFloor", config: target(ideal, "OwedNeverWaitsOnFloor"),
      mutant: { find: "    /\\ lastStart' = [lastStart EXCEPT ![p] = None] /\\ failedAt' = [failedAt EXCEPT ![p] = None]\n", replace: "    /\\ UNCHANGED <<lastStart, failedAt>>\n" },
    },
    {
      label: "bug-old-failure-holds-floor", expect: "CAUGHT", names: "OwedNeverWaitsOnFloor", config: target(hostileSwitch, "OwedNeverWaitsOnFloor"),
      mutant: { find: "[failedAt EXCEPT ![p] = IF inflight[p].ident = ident[p] THEN Wall ELSE @]", replace: "[failedAt EXCEPT ![p] = Wall]" },
    },
    {
      label: "bug-store-from-empty", expect: "CAUGHT", names: "FinishedStaysShown", config: target(hostile, "FinishedStaysShown"),
      mutant: { find: "        own == IF ident[p] = i THEN mem[p] ELSE EmptyRec", replace: "        own == EmptyRec" },
    },
  ];
}

async function runTlc(work: string, cfgText: string, moduleText: string, extra: string[] = [], timeoutMs = 1_800_000) {
  const { java, jar } = tools();
  mkdirSync(join(work, "tmp"), { recursive: true, mode: 0o700 });
  writeFileSync(join(work, "UsageModel.tla"), moduleText);
  writeFileSync(join(work, "run.cfg"), cfgText);
  const command = [java, "-Xmx3g", "-XX:+UseParallelGC", `-Djava.io.tmpdir=${join(work, "tmp")}`, "-cp", jar, "tlc2.TLC",
    "-workers", "4", "-metadir", join(work, "states"), "-config", "run.cfg", ...extra, "UsageModel.tla"];
  const log = join(work, "tlc.log");
  const fd = openSync(log, "w", 0o600);
  const started = Date.now();
  let exit: number;
  try {
    const child = Bun.spawn(command, { cwd: work, stdin: "ignore", stdout: fd, stderr: fd });
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    exit = await child.exited;
    clearTimeout(timer);
  } finally { closeSync(fd); }
  writeFileSync(join(work, "command.json"), JSON.stringify(command, null, 2));
  return { exit, seconds: (Date.now() - started) / 1000, log, output: readFileSync(log, "utf8") };
}

export async function runChecks(outDir: string, only?: RegExp): Promise<CheckResult[]> {
  const original = readFileSync(join(tlaDir, "UsageModel.tla"), "utf8");
  const results: CheckResult[] = [];
  for (const check of checks()) {
    if (only && !only.test(check.label)) continue;
    let moduleText = original;
    if (check.mutant) {
      if (original.split(check.mutant.find).length !== 2) throw new Error(`${check.label}: mutant text must occur exactly once`);
      moduleText = original.replace(check.mutant.find, check.mutant.replace);
    }
    const work = join(outDir, check.label);
    const run = await runTlc(work, check.config, moduleText);
    const distinct = /([\d,]+) distinct states found, 0 states left/.exec(run.output)?.[1];
    const violated = /(?:Invariant|Action property|Temporal properties?) (\w+) (?:is|are) violated/.exec(run.output)?.[1];
    const completed = run.output.includes("Model checking completed. No error has been found.");
    const verdict: CheckResult["verdict"] = completed && run.exit === 0
      ? "PASS"
      : violated && check.mutant ? "CAUGHT" : violated ? "FINDING" : "ERROR";
    results.push({
      ...check, exit: run.exit, seconds: run.seconds, distinct: distinct ? Number(distinct.replaceAll(",", "")) : undefined,
      violated, verdict, log: run.log,
      passed: verdict === check.expect && (check.names === undefined || violated === check.names),
      modelSha256: createHash("sha256").update(moduleText).digest("hex"),
    });
  }
  return results;
}

/** Drivable configuration text: DriveSpec in ideal or non-ideal conditions. */
export function driveConfig(hostile: boolean, maxt = 7): string {
  return cfg("Hostile.cfg")
    .replace(/^    HOSTILE = \w+$/m, `    HOSTILE = ${hostile ? "TRUE" : "FALSE"}`)
    .replace(/^    CORRUPT = \w+$/m, `    CORRUPT = ${hostile ? "TRUE" : "FALSE"}`)
    .replace(/^    SKEW = \d+$/m, `    SKEW = ${hostile ? 2 : 0}`)
    .replace(/^    MAXT = \d+$/m, `    MAXT = ${maxt}`)
    .replace(/^    MAXFAULTS = \d+$/m, "    MAXFAULTS = 3");
}

/** Simulates `count` drivable behaviors; returns the trace files. */
export async function simulate(outDir: string, label: string, hostile: boolean, count: number, depth: number, seed: number): Promise<string[]> {
  const work = join(outDir, label);
  const traces = join(work, "traces");
  mkdirSync(traces, { recursive: true, mode: 0o700 });
  const run = await runTlc(work, driveConfig(hostile), readFileSync(join(tlaDir, "UsageModel.tla"), "utf8"),
    ["-simulate", `file=${join(traces, "t")},num=${count}`, "-depth", String(depth), "-seed", String(seed)], 300_000);
  if (run.exit !== 0) throw new Error(`TLC simulation ${label} exited ${run.exit}; see ${run.log}`);
  return readdirSync(traces).filter((name) => name.startsWith("t_")).sort().map((name) => join(traces, name));
}

if (import.meta.main) {
  const out = process.argv[2] ? resolve(process.argv[2]) : outDir("usage-model-checks");
  mkdirSync(out, { recursive: true, mode: 0o700 });
  const results = await runChecks(out, process.env.FX_USAGE_MODEL_ONLY ? new RegExp(process.env.FX_USAGE_MODEL_ONLY) : undefined);
  writeFileSync(join(out, "checks.json"), JSON.stringify(results.map(({ config, ...r }) => r), null, 2));
  for (const r of results) console.log(`${r.passed ? "ok  " : "FAIL"} ${r.label.padEnd(30)} ${r.verdict.padEnd(8)} ${r.violated ?? ""} ${r.distinct ?? ""} ${r.seconds.toFixed(1)}s`);
  process.exit(results.every((r) => r.passed) ? 0 : 1);
}
