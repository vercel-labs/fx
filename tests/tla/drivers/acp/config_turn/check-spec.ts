// Exhaustive TLC check of tests/tla/acp/AcpConfigTurn.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone, which
// shows that property catches that mistake. The model covers a change to the
// settings during a turn in fx acp: the change is answered at once, the
// running turn keeps the settings it started with, the next turn starts with
// the last change's settings, a change never frees what a running turn reads,
// and a renewed credential reaches the session only while it still has the
// turn's provider. The model's Today config, in tests/tla/acp/check.sh, shows
// fx acp before these rules.
//
//   bun tests/tla/drivers/acp/config_turn/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "no-copy",
    note: "the turn borrows the session's settings while a change can free them",
    from: `owned' = Rules`,
    to: `owned' = FALSE`,
    expect: "NoFreedRead",
  },
  {
    id: "live-read",
    note: "a model request reads the session's current settings, not the turn's copy",
    from: `ver |-> turnVer,`,
    to: `ver |-> version,`,
    expect: "TurnKeepsItsSettings",
  },
  {
    id: "stale-next-turn",
    note: "a new turn keeps the last turn's settings",
    from: `turnVer' = version`,
    to: `turnVer' = turnVer`,
    expect: "NextTurnUsesLatest",
  },
  {
    id: "refuse-during-turn",
    note: "a change during a turn fails with -32600",
    from: `IF ~Rules /\\ running`,
    to: `IF running`,
    expect: "AnswersDuringTurn",
  },
  {
    id: "publish-any-provider",
    note: "a renewed credential replaces the session's after the session changed provider",
    from: `IF ~Rules \\/ provOf[version] = provOf[turnVer]`,
    to: `IF TRUE`,
    expect: "CredentialMatchesProvider",
  },
];

const SPEC_FILES = ["AcpConfigTurn.tla", "MCAcpConfigTurn.tla", "MCAcpConfigTurn.cfg"];
// Every property here is a state invariant, so each target is checked as INVARIANT.
const ACTION_PROPERTIES = new Set<string>();

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    "    Providers <- MCProviders",
    "    MaxTurns = 2",
    "    MaxRequests = 2",
    "    MaxChanges = 2",
    "INIT Init",
    "NEXT Next",
    `${ACTION_PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT"} ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-config-turn-spec");

  const bases = [];
  for (const cfg of ["MCAcpConfigTurn.cfg"]) {
    const run = await runTlc(join(reportDir, "base", cfg), "MCAcpConfigTurn.tla", cfg, SPEC_FILES);
    const passed = run.exitCode === 0 && /No error has been found/.test(run.output);
    console.log(`base ${cfg}: ${passed ? "PASS" : "FAIL"} (exit ${run.exitCode}, ${run.distinctStates} distinct states, depth ${run.depth})`);
    bases.push({ cfg, passed, exitCode: run.exitCode, distinctStates: run.distinctStates, depth: run.depth });
  }

  const source = readFileSync(join(SPEC_DIR, "AcpConfigTurn.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpConfigTurn.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpConfigTurn.tla", "Target.cfg", ["MCAcpConfigTurn.tla"]);
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
