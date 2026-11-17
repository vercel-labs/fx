// Exhaustive TLC check of tests/tla/acp/AcpDisconnect.tla plus its planted
// bugs: each mutant must violate the property it names, checked alone, which
// shows that property catches that mistake. The model covers a client of fx acp
// that disconnects: a client that lists sh.fx/keepTurnOnDisconnect keeps its
// running turn and its queued prompts; any other client's running turn stops
// and is saved as interrupted; a permission request after the disconnect is
// denied at once; and fx exits once every prompt the client sent is saved. The
// model's Today configs, in tests/tla/acp/check.sh, show fx acp before these
// rules.
//
//   bun tests/tla/drivers/acp/disconnect/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "cancel-kept-turn",
    note: "a disconnect stops a kept client's turn",
    from: `ELSE IF Rules /\\ Keep`,
    to: `ELSE IF FALSE`,
    expect: "KeptTurnsComplete",
  },
  {
    id: "wait-for-gone-client",
    note: "a permission request after the disconnect waits for an answer",
    from: `IF connected \\/ ~Rules`,
    to: `IF TRUE`,
    expect: "NeverWaitsForGoneClient",
  },
  {
    id: "drop-queue",
    note: "a disconnect drops the queued prompts of a kept client",
    from: `/\\ UNCHANGED <<queue, saved>>`,
    to: `/\\ queue' = 0 /\\ UNCHANGED saved`,
    expect: "EveryPromptSaved",
  },
  {
    id: "deny-ends-turn",
    note: "a denied permission after the disconnect ends the turn without saving it",
    from: `ELSE UNCHANGED turn`,
    to: `ELSE turn' = "idle"`,
    expect: "EveryPromptSaved",
  },
];

const SPEC_FILES = ["AcpDisconnect.tla", "MCAcpDisconnect.tla", "MCAcpDisconnect.cfg"];
// Every property here is a state invariant, so each target is checked as INVARIANT.
const ACTION_PROPERTIES = new Set<string>();

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    "    Keep = TRUE",
    "    MaxPrompts = 3",
    "INIT Init",
    "NEXT Next",
    `${ACTION_PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT"} ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-disconnect-spec");

  const bases = [];
  for (const cfg of ["MCAcpDisconnect.cfg"]) {
    const run = await runTlc(join(reportDir, "base", cfg), "MCAcpDisconnect.tla", cfg, SPEC_FILES);
    const passed = run.exitCode === 0 && /No error has been found/.test(run.output);
    console.log(`base ${cfg}: ${passed ? "PASS" : "FAIL"} (exit ${run.exitCode}, ${run.distinctStates} distinct states, depth ${run.depth})`);
    bases.push({ cfg, passed, exitCode: run.exitCode, distinctStates: run.distinctStates, depth: run.depth });
  }

  const source = readFileSync(join(SPEC_DIR, "AcpDisconnect.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpDisconnect.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpDisconnect.tla", "Target.cfg", ["MCAcpDisconnect.tla"]);
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
