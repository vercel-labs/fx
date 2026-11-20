// Exhaustive TLC check of tests/tla/acp/AcpTurnEvents.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone,
// which shows that property catches that mistake. The model's Today
// config, in tests/tla/acp/check.sh, shows fx acp before turn events, and its
// RootField config fx acp before sh.fx/commandResult.
//
//   bun tests/tla/drivers/acp/turn_events/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string; parts: string };

const ALL = `{"progress", "calls", "usage", "compaction", "command"}`;

const MUTANTS: Mutant[] = [
  {
    id: "progress-to-plain",
    note: "turn progress goes to a client that doesn't list sh.fx/turnProgress",
    from: `WriteIf(Listed("progress"), Msg("progress", 0, "none", FALSE))`,
    to: `WriteIf(TRUE, Msg("progress", 0, "none", FALSE))`,
    expect: "OptIn",
    parts: `{"calls", "compaction"}`,
  },
  {
    id: "usage-unlisted",
    note: "the response carries sh.fx/usage for a client that doesn't list it",
    from: `Msg("response", 0, "none", Listed("usage"))`,
    to: `Msg("response", 0, "none", Rules)`,
    expect: "OptIn",
    parts: `{"calls"}`,
  },
  {
    id: "drop-call",
    note: "a model call that ends sends nothing, as fx acp's catch-all arm did",
    from: `WriteIf(Listed("calls"), Msg("call", 0, "none", FALSE))`,
    to: `WriteIf(FALSE, Msg("call", 0, "none", FALSE))`,
    expect: "Complete",
    parts: ALL,
  },
  {
    id: "in-progress-twice",
    note: "a compaction sends in_progress at its summary and again as it is saved",
    from: `WriteIf(Listed("compaction") /\\ ~started[k], Msg("comp", k, "in_progress", FALSE))`,
    to: `WriteIf(Listed("compaction"), Msg("comp", k, "in_progress", FALSE))`,
    expect: "Lifecycle",
    parts: ALL,
  },
  {
    id: "cancel-unstarted",
    note: "a compaction that ends before its summary starts, such as one with nothing to compact, still sends an end",
    from: `WriteIf(Listed("compaction") /\\ (started[k] \\/ o = "failed"), Msg("comp", k, EndOf(o), FALSE))`,
    to: `WriteIf(Listed("compaction"), Msg("comp", k, EndOf(o), FALSE))`,
    expect: "Complete",
    parts: ALL,
  },
  {
    id: "no-op-completed",
    note: "a started compaction that finds nothing to compact ends as completed",
    from: `Msg("comp", k, EndOf(o), FALSE))`,
    to: `Msg("comp", k, IF o = "no_op" THEN "completed" ELSE EndOf(o), FALSE))`,
    expect: "Complete",
    parts: ALL,
  },
  {
    id: "respond-early",
    note: "fx answers the prompt before the loop has finished the turn",
    from: `Respond ==\n    /\\ running /\\ finished`,
    to: `Respond ==\n    /\\ running`,
    expect: "BeforeResponse",
    parts: ALL,
  },
  {
    id: "command-root-kept",
    note: "a client that doesn't list sh.fx/commandResult still gets the command_result field at the root of the update",
    from: `THEN IF "command" \\in Parts THEN "meta" ELSE "none"`,
    to: `THEN IF "command" \\in Parts THEN "meta" ELSE "root"`,
    expect: "StandardOnly",
    parts: `{"calls"}`,
  },
  {
    id: "command-to-plain",
    note: "sh.fx/commandResult goes to a client that doesn't list it",
    from: `THEN IF "command" \\in Parts THEN "meta" ELSE "none"`,
    to: `THEN "meta"`,
    expect: "OptIn",
    parts: `{"calls", "compaction"}`,
  },
  {
    id: "command-dropped",
    note: "a shell call's update leaves out its command result for a client that lists sh.fx/commandResult",
    from: `THEN IF "command" \\in Parts THEN "meta" ELSE "none"`,
    to: `THEN "none"`,
    expect: "Complete",
    parts: ALL,
  },
  {
    id: "update-dropped",
    note: "a shell call with nothing for the client's _meta sends no tool_call_update at all",
    from: `/\\ chan' = Append(chan, Msg("tool", 0, CommandTag, FALSE))`,
    to: `/\\ chan' = IF CommandTag = "none" THEN chan ELSE Append(chan, Msg("tool", 0, CommandTag, FALSE))`,
    expect: "Complete",
    parts: "{}",
  },
];

const SPEC_FILES = [
  "AcpTurnEvents.tla",
  "MCAcpTurnEvents.tla",
  "MCAcpTurnEvents.cfg",
  "MCAcpTurnEventsPlain.cfg",
  "MCAcpTurnEventsSome.cfg",
];

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string, parts: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    "    CommandMeta = TRUE",
    `    Parts = ${parts}`,
    "    Ks = {1, 2}",
    "    MaxProgress = 2",
    "    MaxCalls = 1",
    "    MaxShells = 1",
    "    MaxTurns = 2",
    "INIT Init",
    "NEXT Next",
    `INVARIANT ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-turn-events-spec");
  const bases = [];
  for (const cfg of ["MCAcpTurnEvents.cfg", "MCAcpTurnEventsPlain.cfg", "MCAcpTurnEventsSome.cfg"]) {
    const run = await runTlc(join(reportDir, "base", cfg), "MCAcpTurnEvents.tla", cfg, SPEC_FILES);
    const passed = run.exitCode === 0 && /No error has been found/.test(run.output);
    console.log(`base ${cfg}: ${passed ? "PASS" : "FAIL"} (exit ${run.exitCode}, ${run.distinctStates} distinct states, depth ${run.depth})`);
    bases.push({ cfg, passed, exitCode: run.exitCode, distinctStates: run.distinctStates, depth: run.depth });
  }
  const source = readFileSync(join(SPEC_DIR, "AcpTurnEvents.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpTurnEvents.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect, mutant.parts));
    const run = await runTlc(dir, "MCAcpTurnEvents.tla", "Target.cfg", ["MCAcpTurnEvents.tla"]);
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
