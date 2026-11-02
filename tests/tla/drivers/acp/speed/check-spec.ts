// Exhaustive TLC check of the speed contract plus mutation qualification:
// each planted mutant must violate the named invariant, which shows the
// invariants are not vacuous. Several mutants match how an earlier fx behaved.
//
//   bun tests/tla/drivers/acp/speed/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { outDir } from "../../lib/tlc";
import { SPEC_DIR, runTlc, sha256File, tlcToolchain, utcStamp, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "fast-ignored",
    note: "an earlier fx: set fast succeeds but changes nothing",
    from: "    ELSE /\\ fast' = b\n         /\\ ultra' = (ultra /\\ ~b)",
    to: "    ELSE /\\ fast' = fast\n         /\\ ultra' = ultra",
    expect: "RequestHonored",
  },
  {
    id: "unknown-accepted",
    note: "an earlier fx: unknown config ids succeed",
    from: 'Result("unknown", "none", FALSE, "none")',
    to: 'Result("unknown", "none", TRUE, "none")',
    expect: "UnknownRejected",
  },
  {
    id: "switch-keeps-ultra",
    note: "an earlier fx: Ultrafast stays on, hidden, after switching to a model without it",
    from: "    /\\ ultra' = (ultra /\\ m \\in SupUltra)",
    to: "    /\\ ultra' = ultra",
    expect: "UltraValid",
  },
  {
    id: "switch-keeps-fast",
    note: "an earlier fx: Fast stays on, hidden, after switching to a model without it",
    from: "    /\\ fast' = (fast /\\ m \\in SupFast)",
    to: "    /\\ fast' = fast",
    expect: "SwitchClearsFast",
  },
  {
    id: "fast-not-exclusive",
    note: "enabling Fast leaves Ultrafast on",
    from: "         /\\ ultra' = (ultra /\\ ~b)",
    to: "         /\\ ultra' = ultra",
    expect: "Exclusive",
  },
  {
    id: "ultra-not-exclusive",
    note: "enabling Ultrafast leaves Fast on",
    from: "         /\\ fast' = (fast /\\ ~b)",
    to: "         /\\ fast' = fast",
    expect: "Exclusive",
  },
  {
    id: "fast-unsupported-accepted",
    note: "Fast can be enabled on a model without it",
    from: "    IF b /\\ model \\notin SupFast",
    to: "    IF FALSE",
    expect: "AcceptOnlySupported",
  },
  {
    id: "fast-disable-rejected",
    note: "turning Fast off is rejected on a model without it",
    from: "    IF b /\\ model \\notin SupFast",
    to: "    IF model \\notin SupFast",
    expect: "RejectOnlyUnsupported",
  },
  {
    id: "prompt-hidden-fast",
    note: "a prompt sends Fast for a model without it",
    from: "ELSE IF fast /\\ model \\in SupFast THEN \"fast\"",
    to: "ELSE IF fast THEN \"fast\"",
    expect: "PromptLaneSupported",
  },
];

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-speed-spec");
  mkdirSync(reportDir, { recursive: true });
  const specFiles = ["AcpSpeed.tla", "MCAcpSpeed.tla", "MCAcpSpeed.cfg"];

  const base = await runTlc(join(reportDir, "base"), "MCAcpSpeed.tla", "MCAcpSpeed.cfg", specFiles);
  const basePassed = base.exitCode === 0 && /No error has been found/.test(base.output);
  console.log(`base spec: ${basePassed ? "PASS" : "FAIL"} (exit ${base.exitCode}, ${base.distinctStates} distinct states, depth ${base.depth})`);

  const source = readFileSync(join(SPEC_DIR, "AcpSpeed.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpSpeed.tla"), source.replace(mutant.from, mutant.to));
    const mutated = await runTlc(dir, "MCAcpSpeed.tla", "MCAcpSpeed.cfg", ["MCAcpSpeed.tla", "MCAcpSpeed.cfg"]);
    const killed = mutated.exitCode === 12 && mutated.violated === mutant.expect;
    console.log(`mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${mutated.exitCode}, violated ${mutated.violated ?? "none"}, expected ${mutant.expect})`);
    mutants.push({ ...mutant, exitCode: mutated.exitCode, violated: mutated.violated, killed });
  }

  const summary = {
    toolchain: tool,
    spec_sha256: Object.fromEntries(specFiles.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    base: { passed: basePassed, exitCode: base.exitCode, distinctStates: base.distinctStates, depth: base.depth, argv: base.argv },
    mutants,
    allKilled: mutants.every((mutant) => mutant.killed),
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`report: ${reportDir}`);
  if (!basePassed || !summary.allKilled) process.exit(1);
}

await main();
