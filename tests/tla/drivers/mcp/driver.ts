// Bun driver for the MCP-v2 engine models in tests/tla/mcp/.
//
// Builds the binaries the selected scenarios need, runs each scenario with an
// isolated HOME and MCPV2_TRACE, checks every expected trace through the
// bridge, and keeps all evidence under <out>/<unit>/<case>/, where <out> is a
// fresh folder under FX_TLA_OUT or the system temp folder.
//
// Usage: bun tests/tla/drivers/mcp/driver.ts [--unit S05] [--case name] [--repeat N] [--list]
//
// The binaries are labs built from labs/ against this checkout's src/mcp/.
// Exit: 0 every case passed, 1 a case failed, 2 usage or tooling error.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { checkTrace } from "./bridge";
import type { Scenario, ScenarioContext } from "./scenario";
import { REPO_ROOT, outDir } from "../lib/tlc";

const ROOT = REPO_ROOT;
const SCENARIO_DIR = join(import.meta.dir, "scenarios");

/** Binaries the driver knows how to build, by name. */
const BUILDABLE: { [name: string]: string } = {
  trace_demo: "tests/tla/drivers/mcp/labs/trace_demo.zig",
  request_lab: "tests/tla/drivers/mcp/labs/request_lab.zig",
  wire_lab: "tests/tla/drivers/mcp/labs/wire_lab.zig",
  stdio_lab: "tests/tla/drivers/mcp/labs/stdio_lab.zig",
  engine_lab: "tests/tla/drivers/mcp/labs/engine_lab.zig",
};

function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function runId(): string {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
  return `${stamp}-${crypto.randomUUID().slice(0, 8)}`;
}

async function loadScenarios(): Promise<Scenario[]> {
  const all: Scenario[] = [];
  for (const file of readdirSync(SCENARIO_DIR).filter((f) => f.endsWith(".ts")).sort()) {
    const mod = await import(join(SCENARIO_DIR, file));
    all.push(...(mod.scenarios as Scenario[]));
  }
  const names = new Set<string>();
  for (const s of all) {
    if (names.has(s.name)) throw new Error(`duplicate scenario name ${s.name}`);
    names.add(s.name);
  }
  return all;
}

function build(names: string[], binDir: string): { [name: string]: { path: string; sha256: string } } {
  mkdirSync(binDir, { recursive: true });
  const built: { [name: string]: { path: string; sha256: string } } = {};
  for (const name of names) {
    const rootFile = BUILDABLE[name];
    if (!rootFile) throw new Error(`no build recipe for binary ${name}`);
    if (!existsSync(join(ROOT, rootFile))) throw new Error(`binary ${name} needs ${rootFile}, which does not exist yet`);
    const out = join(binDir, name);
    const result = Bun.spawnSync(
      ["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "--dep", "mcp", `-Mroot=${rootFile}`, "-Mmcp=src/mcp/mcp.zig", "--name", name, `-femit-bin=${out}`],
      { cwd: ROOT, stdout: "pipe", stderr: "pipe" },
    );
    if (result.exitCode !== 0) throw new Error(`building ${name} failed:\n${result.stderr.toString()}`);
    built[name] = { path: out, sha256: sha256File(out) };
  }
  return built;
}

/** SHA-256 over the sorted `<sha256>  <path>` lines of every Zig file in src/mcp/. */
function treeHash(): string {
  const files = (readdirSync(join(ROOT, "src", "mcp"), { recursive: true }) as string[])
    .filter((name) => name.endsWith(".zig"))
    .map((name) => `src/mcp/${name}`)
    .sort();
  const lines = files.map((file) => `${sha256File(join(ROOT, file))}  ${file}\n`).join("");
  return createHash("sha256").update(lines).digest("hex");
}

interface CaseResult {
  name: string;
  unit: string;
  attempt: number;
  passed: boolean;
  problems: string[];
  exit: number | null;
  signal: string | null;
  seconds: number;
  traces: { machine: string; expected: string; verdict: string; reason: string; reportDir: string }[];
  evidence: string;
}

function runCase(scenario: Scenario, attempt: number, bins: { [name: string]: string }, evidenceRun: string): CaseResult {
  const caseDir = join(evidenceRun, attempt > 1 ? `${scenario.name}-${attempt}` : scenario.name);
  mkdirSync(caseDir, { recursive: true });
  const scratch = mkdtempSync(join(tmpdir(), "mcpv2-case-"));
  const ctx: ScenarioContext = {
    root: ROOT,
    bin: bins,
    home: join(scratch, "home"),
    workdir: join(scratch, "work"),
    tracePath: join(caseDir, "trace.jsonl"),
    caseDir,
  };
  mkdirSync(ctx.home, { recursive: true });
  mkdirSync(ctx.workdir, { recursive: true });
  scenario.setup?.(ctx);

  const command = scenario.command(ctx);
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: ctx.home,
    TMPDIR: scratch,
    MCPV2_HOME: join(ctx.home, ".mcpv2"),
    MCPV2_TRACE: ctx.tracePath,
  };
  writeFileSync(join(caseDir, "scenario.json"), JSON.stringify({ ...scenario, command, env }, null, 2) + "\n");

  const started = performance.now();
  const proc = Bun.spawnSync(command, { cwd: ctx.workdir, env, stdout: "pipe", stderr: "pipe", timeout: scenario.timeoutMs ?? 30_000 });
  const seconds = Math.round(performance.now() - started) / 1000;
  writeFileSync(join(caseDir, "stdout.txt"), proc.stdout);
  writeFileSync(join(caseDir, "stderr.txt"), proc.stderr);
  const signal = proc.signalCode ?? null;
  const exit = proc.exitCode ?? null;
  writeFileSync(join(caseDir, "process.json"), JSON.stringify({ exit, signal, seconds }, null, 2) + "\n");

  const problems: string[] = [];
  if (signal !== null) problems.push(`process ended by signal ${signal}`);
  if (exit !== scenario.expect.exit) problems.push(`exit ${exit}, expected ${scenario.expect.exit}`);
  if (scenario.expect.stdout) {
    const problem = scenario.expect.stdout(proc.stdout.toString());
    if (problem !== null) problems.push(`stdout: ${problem}`);
  }

  const traces = scenario.expect.traces.map((t, index) => {
    const result = checkTrace({
      trace: ctx.tracePath,
      machine: t.machine,
      instance: t.instance,
      specDir: resolve(ROOT, t.specDir),
      wrapper: t.wrapper,
      reportDir: join(caseDir, `bridge-${index + 1}-${t.machine}`),
      constants: t.constants,
    });
    if (result.verdict !== t.verdict) problems.push(`trace ${t.machine}: ${result.verdict} (${result.reason}), expected ${t.verdict}`);
    return { machine: t.machine, expected: t.verdict, verdict: result.verdict, reason: result.reason, reportDir: result.reportDir };
  });

  rmSync(scratch, { recursive: true, force: true });
  const result: CaseResult = { name: scenario.name, unit: scenario.unit, attempt, passed: problems.length === 0, problems, exit, signal, seconds, traces, evidence: caseDir };
  writeFileSync(join(caseDir, "result.json"), JSON.stringify(result, null, 2) + "\n");
  return result;
}

async function main(): Promise<number> {
  const args = process.argv.slice(2);
  const values = (flag: string) => args.flatMap((a, i) => (a === flag && args[i + 1] ? [args[i + 1]] : []));
  const repeat = Number(values("--repeat")[0] ?? "1");
  if (!Number.isInteger(repeat) || repeat < 1) {
    console.error("driver: --repeat must be a positive integer");
    return 2;
  }

  let scenarios = await loadScenarios();
  const units = values("--unit");
  const cases = values("--case");
  if (units.length > 0) scenarios = scenarios.filter((s) => units.includes(s.unit));
  if (cases.length > 0) scenarios = scenarios.filter((s) => cases.includes(s.name));
  scenarios = scenarios.filter((s) => !s.real);
  if (args.includes("--list")) {
    for (const s of scenarios) console.log(`${s.unit} ${s.name.padEnd(36)} ${s.description}`);
    return 0;
  }
  if (scenarios.length === 0) {
    console.error("driver: no scenarios selected");
    return 2;
  }

  const id = runId();
  const out = outDir("mcp");
  const needs = [...new Set(scenarios.flatMap((s) => s.needs))].sort();
  // mkdtemp, not a name from the run id: the driver runs what it builds here.
  const binDir = mkdtempSync(join(tmpdir(), `mcpv2-bin-${id}-`));
  const built = build(needs, binDir);
  const environment = { runId: id, treeSha256: treeHash(), binaries: built, bun: Bun.version, args };
  const bins = Object.fromEntries(Object.entries(built).map(([name, b]) => [name, b.path]));

  const results: CaseResult[] = [];
  for (const unit of [...new Set(scenarios.map((s) => s.unit))].sort()) {
    const evidenceRun = join(out, unit);
    mkdirSync(evidenceRun, { recursive: true });
    writeFileSync(join(evidenceRun, "environment.json"), JSON.stringify(environment, null, 2) + "\n");
    const mine: CaseResult[] = [];
    for (const scenario of scenarios.filter((s) => s.unit === unit)) {
      for (let attempt = 1; attempt <= repeat; attempt++) {
        const r = runCase(scenario, attempt, bins, evidenceRun);
        mine.push(r);
        const label = repeat > 1 ? `${r.name} #${attempt}` : r.name;
        console.log(`${r.passed ? "PASS" : "FAIL"} ${unit} ${label.padEnd(36)} exit=${r.exit} ${r.traces.map((t) => `${t.machine}=${t.verdict}`).join(" ")}`);
        for (const p of r.problems) console.log(`     ${p}`);
      }
    }
    writeFileSync(join(evidenceRun, "summary.json"), JSON.stringify(mine, null, 2) + "\n");
    console.log(`Summary: ${join(evidenceRun, "summary.json")}`);
    results.push(...mine);
  }
  rmSync(binDir, { recursive: true, force: true });
  return results.every((r) => r.passed) ? 0 : 1;
}

if (import.meta.main) {
  main()
    .then((code) => process.exit(code))
    .catch((error) => {
      console.error(`driver: tooling error: ${error instanceof Error ? error.message : String(error)}`);
      process.exit(2);
    });
}
