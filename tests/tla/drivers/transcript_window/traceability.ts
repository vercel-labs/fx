// Traceability: design/DESIGN.md's laws, the checks that enforce them, and
// the files those checks live in must agree.
//
//   - every law in the Laws table has an Enforcement row, and the reverse;
//   - every enforcement entry resolves: `inv:` is an invariant the spec
//     defines and an MC config lists, `prop:` a property one lists, `trace:` a
//     name TraceTranscriptWindow.cfg checks, `test:` an inline test in the
//     core, `check:` a stage verify.ts runs;
//   - every invariant and property a config lists belongs to a law (TypeOK,
//     StartsAtInit, and ConformsToSpec are the harness's own);
//   - every name GOAL.md's checks cite exists in the spec;
//   - every model-checkable law has a planted bug in mutations.json, so each
//     one is shown to fail when broken.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { CORE_SOURCE, MODEL_DIR, configNames, specFiles } from "./lib.ts";
import { loadMutations } from "./mutations.ts";

export type TraceabilityResult = { laws: number; entries: number; problems: string[] };

const OWN_CHECKS = new Set(["TypeOK", "StartsAtInit", "ConformsToSpec"]);

export function checkTraceability(): TraceabilityResult {
  const design = readFileSync(join(MODEL_DIR, "design", "DESIGN.md"), "utf8");
  const goal = readFileSync(join(MODEL_DIR, "design", "GOAL.md"), "utf8");
  const verify = readFileSync(join(import.meta.dirname, "verify.ts"), "utf8");
  const core = readFileSync(CORE_SOURCE, "utf8");
  const files = specFiles();
  const spec = files["TranscriptWindow.tla"]!;
  const trace = files["TraceTranscriptWindow.tla"]!;
  const problems: string[] = [];

  const lawsSection = design.slice(design.indexOf("## Laws"), design.indexOf("## Enforcement"));
  const enforcementSection = design.slice(design.indexOf("## Enforcement"), design.indexOf("## Final design"));
  const laws = new Map<string, string>();
  for (const match of lawsSection.matchAll(/^\| (L\d+) (\w+) \|/gm)) laws.set(match[1]!, match[2]!);
  const enforcement = new Map<string, string[]>();
  for (const match of enforcementSection.matchAll(/^\| (L\d+) \| (.+) \|$/gm)) {
    enforcement.set(match[1]!, [...match[2]!.matchAll(/`([a-z]+):([^`]+)`/g)].map((entry) => `${entry[1]}:${entry[2]}`));
  }
  for (const law of laws.keys()) if (!enforcement.has(law)) problems.push(`${law} has no Enforcement row`);
  for (const law of enforcement.keys()) if (!laws.has(law)) problems.push(`Enforcement row ${law} has no law`);

  const listed = (cfg: string, section: string) => configNames(files[cfg]!)[section] ?? [];
  const mcInvariants = new Set([...listed("MCTranscriptWindow.cfg", "INVARIANT"), ...listed("MCTranscriptWindowUnsaved.cfg", "INVARIANT")]);
  const mcProperties = new Set([...listed("MCTranscriptWindow.cfg", "PROPERTY"), ...listed("MCCtrlOReachesStart.cfg", "PROPERTY")]);
  const traceChecks = new Set([...listed("TraceTranscriptWindow.cfg", "INVARIANT"), ...listed("TraceTranscriptWindow.cfg", "PROPERTY")]);
  const defined = (text: string, name: string) => new RegExp(`^${name} ==`, "m").test(text);
  const enforced = new Set<string>();
  let entries = 0;
  for (const [law, list] of enforcement) {
    for (const entry of list) {
      entries += 1;
      const [kind, name] = entry.split(":") as [string, string];
      enforced.add(name);
      if (kind === "inv" && !(defined(spec, name) && mcInvariants.has(name))) problems.push(`${law} ${entry}: not an invariant the spec defines and an MC config lists`);
      if (kind === "prop" && !(defined(spec, name) && mcProperties.has(name))) problems.push(`${law} ${entry}: not a property the spec defines and an MC config lists`);
      if (kind === "trace" && !(defined(trace, name) && traceChecks.has(name))) problems.push(`${law} ${entry}: not checked on code traces`);
      if (kind === "test" && !core.includes(`test "${name}"`)) problems.push(`${law} ${entry}: no such test in the core`);
      if (kind === "check" && !verify.includes(`"${name}"`)) problems.push(`${law} ${entry}: verify.ts runs no such stage`);
      if (!["inv", "prop", "trace", "test", "check"].includes(kind)) problems.push(`${law} ${entry}: unknown kind`);
    }
  }
  for (const name of [...mcInvariants, ...mcProperties, ...traceChecks]) {
    if (!OWN_CHECKS.has(name) && !enforced.has(name)) problems.push(`${name} is checked but enforces no law in DESIGN.md`);
  }
  const constantsBlock = /^CONSTANTS\n([\s\S]*?)\n\n/m.exec(spec)?.[1] ?? "";
  const constants = new Set([...constantsBlock.matchAll(/^\s+(\w+)/gm)].map((match) => match[1]!));
  for (const match of goal.matchAll(/`([A-Z][A-Za-z]+)`/g)) {
    const name = match[1]!;
    if (!defined(spec, name) && !constants.has(name)) problems.push(`GOAL.md cites ${name}, which the spec neither defines nor declares`);
  }
  const planted = new Set(loadMutations().spec.map((mutation) => mutation.law));
  for (const name of [...mcInvariants, ...mcProperties]) {
    if (!OWN_CHECKS.has(name) && !planted.has(name)) problems.push(`${name} has no planted bug in mutations.json`);
  }
  for (const law of planted) if (!enforced.has(law)) problems.push(`mutations.json names ${law}, which enforces no law`);
  return { laws: laws.size, entries, problems };
}
