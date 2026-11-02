// `bun run verify` from tests/tla/fuzzy_match/: the one gate for the fuzzy
// match engine. In order, and every stage must pass:
//
//   1. the pinned TLC and the Java that runs it;
//   2. TLC on every config in spec/;
//   3. every planted spec bug caught by the law it names;
//   4. the edge table agrees with the model, and a doctored one does not;
//   5. the oracle agrees with TLC on the edge table, random cases, and
//      random listings, and every planted oracle bug is caught;
//   6. the built binary's Models and skills menus against the model;
//   7. the engine: the edge table, random cases against the oracle and TLC,
//      random listings built by its `Ranking` and `Filter` against the
//      oracle and TLC, the laws on its own answers, the stress budgets, and
//      every planted engine bug caught;
//   8. every surface calls the engine, and the matchers it replaced are gone;
//   9. traceability: design/GOAL.md and the checks name each other.
//
// Settings: FX_FUZZY_SEED (default 20261028), FX_FUZZY_RANDOM (random cases,
// default 1500), FX_FUZZY_DIFFERENTIAL (engine against oracle, default
// 20000), FX_BIN (the binary), FX_TLA_OUT (where the report goes).
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { binary } from "../lib/context.ts";
import { REPO_ROOT, outDir, writeJson } from "../lib/tlc.ts";
import { binaryStage } from "./binary.ts";
import { edgeCases, randomCases } from "./cases.ts";
import { buildHarness, codeMutations, edgeThroughEngine, lawsOnEngine, listingsThroughEngine, randomThroughEngine, stress } from "./engine.ts";
import { MODEL_DIR, PINNED_TLC_VERSION, SPEC_DIR, checkTlc, configInfo, engineExists, pinnedToolchain, specFiles } from "./lib.ts";
import { judgeOracle, loadMutations, oracleMutations, pool, specMutations } from "./mutations.ts";
import { judgeCases, modelMatch } from "./tlc-cases.ts";

const seed = Number(process.env.FX_FUZZY_SEED ?? "20261028");
const randomCount = Number(process.env.FX_FUZZY_RANDOM ?? "1500");
const differentialCount = Number(process.env.FX_FUZZY_DIFFERENTIAL ?? "20000");
const out = outDir("fuzzy-match");
const report: Record<string, unknown> = { started: new Date().toISOString(), seed, randomCount, differentialCount, out };
const failures: string[] = [];
const started = performance.now();
const elapsed = (from: number) => `${((performance.now() - from) / 1000).toFixed(1)} s`;

function stage(name: string, ok: boolean, summary: string) {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}: ${summary}`);
  if (!ok) failures.push(name);
}

// The surfaces design/CONTEXT.md lists. Each file must use the engine
// through what its listing needs, `Ranking` for ranked surfaces (R10) and
// `Filter` for filtered ones (R11), and none may keep a matcher it replaced.
const CALLERS = [
  { file: "src/core/app/model_cache_runtime.zig", uses: ["fuzzy_match.Ranking("], gone: ["fn matchModelQuery(", "fn containsAlphanumericRun(", "fn containsWordStartSubsequence(", "ranked_model_matches"] },
  { file: "src/core/session/session_commands.zig", uses: ["fuzzy_match.Ranking("], gone: ["fuzzyModelScore(id, query)"] },
  { file: "src/core/slash_commands/command_specs.zig", uses: ["fuzzy_match.Ranking(", "fuzzy_match.Filter("], gone: ["fn completionCommandMatchRank(", "fn bestCompletionCommandMatch(", "fn containsIgnoreCase(", "fn helpCatalogSpecMatches(", "fn runtimeArgMatches("] },
  { file: "src/core/skills/skill_runtime.zig", uses: ["fuzzy_match.Ranking("], gone: ["fn skillMatchRank(", "fn asciiContainsIgnoreCase("] },
  { file: "src/core/session/session_catalog.zig", uses: ["fuzzy_match.Filter("], gone: ["containsIgnoreCase(displayTitle(summary)", "fn pickerLists(", "fn sessionMatchesQuery("] },
  { file: "src/core/mcp_host/menu.zig", uses: ["fuzzy_match.Filter("], gone: ["pub fn matches(name: []const u8, filter: []const u8) bool", "std.ascii.findIgnoreCase(name, filter)", "fn serverMatches(", "fn toolMatches("] },
  { file: "src/core/config/settings_catalog.zig", uses: ["fuzzy_match.Filter("], gone: ["fn tokenMatches(", "std.ascii.findIgnoreCase(spec.label", "fn matchesQuery("] },
  { file: "src/core/input/picker_state.zig", uses: ["fuzzy_match.Filter("], gone: ["text_utils.containsIgnoreCase(option", "text_utils.containsIgnoreCase(labels[i]", "fn labelMatches("] },
  { file: "src/core/app/input_completion_runtime.zig", uses: ["fuzzy_match.Filter("], gone: ["text_utils.containsIgnoreCase(effort.displayLabel()"] },
  { file: "src/core/auth/auth_runtime.zig", uses: ["fuzzy_match.Filter("], gone: ["text_utils.containsIgnoreCase(team.name", "fn teamMatchesQuery("] },
];

try {
  const toolchain = pinnedToolchain();
  report.toolchain = toolchain;
  stage("toolchain", true, `tla2tools.jar sha256 ${toolchain.jarSha256.slice(0, 12)}, ${toolchain.javaVersion}`);

  // 2. Every config, a few at a time.
  let at = performance.now();
  const cfgs = readdirSync(SPEC_DIR).filter((name) => name.startsWith("MC") && name.endsWith(".cfg")).sort();
  const files = specFiles();
  const models = await pool(5, cfgs.map((cfg) => async () => {
    const { module } = configInfo(cfg);
    const run = await checkTlc(join(out, "model", cfg.replace(".cfg", "")), module, cfg, files, ["-workers", "3"]);
    return { cfg, verdict: run.verdict, property: run.property, distinctStates: run.distinctStates, durationMs: run.durationMs, tlcVersion: run.tlcVersion };
  }));
  report.model = models;
  const modelOk = models.every((m) => m.verdict === "pass" && m.tlcVersion === PINNED_TLC_VERSION);
  stage("model check", modelOk, `${models.map((m) => `${m.cfg} ${m.verdict}${m.property ? ` (${m.property})` : ""} ${m.distinctStates} states`).join(", ")}, ${elapsed(at)}`);

  // 3.
  at = performance.now();
  const specBugs = await specMutations(join(out, "spec-mutations"));
  report.specMutations = specBugs;
  for (const bug of specBugs) if (!bug.caught) console.log(`  MISSED ${bug.id}: alone ${bug.alone}, full ${bug.full}`);
  stage("spec mutations", specBugs.every((b) => b.caught), `${specBugs.filter((b) => b.caught).length} of ${specBugs.length} caught, ${elapsed(at)}`);

  // 4.
  at = performance.now();
  const edge = edgeCases();
  const judged = await judgeCases(join(out, "edge"), edge.map((c) => ({ query: c.query, fields: c.fields, expect: modelMatch(c.expect!) })));
  const doctoredAt = 9;
  const doctored = await judgeCases(join(out, "edge-doctored"), edge.map((c, i) => ({ query: c.query, fields: c.fields, expect: i === doctoredAt ? { tier: "words" as const, field: 1 } : modelMatch(c.expect!) })));
  const doctoredRejected = !doctored.ok && doctored.bad.length === 1 && doctored.bad[0]!.index === doctoredAt + 1;
  report.edge = { cases: edge.length, bad: judged.bad, doctoredRejected };
  stage("edge cases", judged.ok && doctoredRejected,
    judged.ok ? `${edge.length} of ${edge.length} agree with TLC; a doctored expectation is rejected: ${doctoredRejected}, ${elapsed(at)}`
      : `TLC disagrees with ${judged.bad.map((b) => `${edge[b.index - 1]!.id} (model: ${b.tier} ${b.field})`).join(", ")}`);

  // 5.
  at = performance.now();
  const random = randomCases(seed, randomCount);
  const real = await judgeOracle(join(out, "oracle"), edge, random);
  const oracleBugs = await oracleMutations(join(out, "oracle-mutations"), edge, random.slice(0, 600));
  report.oracle = { edgeMismatches: real.handMismatches, tlcMismatches: real.tlcMismatches, listings: real.listings, listingMismatches: real.listingMismatches, bugs: oracleBugs };
  for (const bug of oracleBugs) if (!bug.caught) console.log(`  MISSED ${bug.id}: ${bug.detail}`);
  stage("oracle", real.handMismatches.length === 0 && real.tlcMismatches === 0 && real.listingMismatches === 0 && oracleBugs.every((b) => b.caught),
    `${edge.length + random.length} cases and ${real.listings} listings agree with TLC; ${oracleBugs.filter((b) => b.caught).length} of ${oracleBugs.length} planted bugs caught, ${elapsed(at)}`);

  // 6.
  at = performance.now();
  if (!existsSync(binary)) {
    stage("binary", false, `missing ${binary}; run zig build first or set FX_BIN`);
  } else {
    const run = await binaryStage(join(out, "binary"));
    report.binary = run;
    for (const bad of run.bad) console.log(`  ${bad.surface} ${JSON.stringify(bad.query)}: shows ${bad.shown.join(", ") || "nothing"}; the model lists ${bad.model.join(", ") || "nothing"}`);
    stage("binary", run.ok, `${run.observations} menu states of ${binary} list exactly what the model lists, ${elapsed(at)}`);
  }

  // 7.
  if (!engineExists()) {
    stage("engine", false, "src/core/shared/fuzzy_match.zig does not exist");
  } else {
    at = performance.now();
    const bin = buildHarness(join(out, "harness"), "Debug");
    const edgeRun = await edgeThroughEngine(bin, edge);
    for (const wrong of edgeRun.wrong) console.log(`  ${wrong.id}: engine ${JSON.stringify(wrong.got)}, expected ${JSON.stringify(wrong.want)}`);
    stage("engine edge cases", edgeRun.wrong.length === 0, `${edgeRun.cases - edgeRun.wrong.length} of ${edgeRun.cases}, ${elapsed(at)}`);

    at = performance.now();
    const diff = await randomThroughEngine(join(out, "engine-random"), bin, edge, seed + 7, differentialCount, randomCount);
    report.engineRandom = { cases: diff.cases, differ: diff.differ.slice(0, 20), tlcCases: diff.tlcCases, tlcBad: diff.tlcBad };
    for (const d of diff.differ.slice(0, 5)) console.log(`  ${d.id} ${d.query}: engine ${JSON.stringify(d.got)}, oracle ${JSON.stringify(d.oracle)}`);
    stage("engine random", diff.differ.length === 0 && diff.tlcBad === 0, `${diff.cases} cases agree with the oracle, ${diff.tlcCases} with TLC (${diff.tlcBad} disagree), ${elapsed(at)}`);

    at = performance.now();
    const listed = await listingsThroughEngine(join(out, "engine-listings"), bin, seed + 19, 400);
    report.engineListings = listed;
    stage("engine listings", listed.inconsistent === 0 && listed.differ === 0 && listed.tlcBad === 0,
      `${listed.listings} listings from Ranking and Filter agree with themselves and the oracle (${listed.inconsistent} inconsistent, ${listed.differ} differ), ${listed.tlcListings} with TLC (${listed.tlcBad} disagree), ${elapsed(at)}`);

    at = performance.now();
    const laws = await lawsOnEngine(bin, seed + 11, 3000);
    report.engineLaws = { cases: laws.cases, probes: laws.probes, broken: laws.broken.slice(0, 20) };
    for (const b of laws.broken.slice(0, 5)) console.log(`  ${b.law} broken by ${b.id} ${b.query}`);
    stage("engine laws", laws.broken.length === 0, `Narrowing, KeepsSubstringMatches, and CaseInsensitive over ${laws.cases} cases and ${laws.probes} probes, ${elapsed(at)}`);

    at = performance.now();
    const fast = buildHarness(join(out, "harness-release"), "ReleaseSafe");
    const budgets = await stress(fast, seed + 13);
    report.stress = budgets;
    for (const f of budgets.failures) console.log(`  ${f}`);
    stage("stress", budgets.failures.length === 0, `${JSON.stringify(budgets.results)}, ${elapsed(at)}`);

    at = performance.now();
    const bugs = loadMutations().code;
    const codeBugs = await codeMutations(join(out, "code-mutations"), edge, seed + 17, bugs);
    report.codeMutations = codeBugs;
    for (const bug of codeBugs) if (!bug.caught) console.log(`  MISSED ${bug.id}: ${bug.detail}`);
    stage("code mutations", bugs.length > 0 && codeBugs.every((b) => b.caught), `${codeBugs.filter((b) => b.caught).length} of ${codeBugs.length} caught, ${elapsed(at)}`);
  }

  // 8.
  {
    const problems: string[] = [];
    for (const caller of CALLERS) {
      const text = readFileSync(join(REPO_ROOT, caller.file), "utf8");
      for (const use of caller.uses) if (!text.includes(use)) problems.push(`${caller.file} does not use ${use.slice(0, -1)}`);
      for (const gone of caller.gone) if (text.includes(gone)) problems.push(`${caller.file} still has ${gone}`);
    }
    for (const p of problems) console.log(`  ${p}`);
    stage("callers", problems.length === 0, problems.length === 0
      ? `${CALLERS.length} files use the engine and none keeps a replaced matcher`
      : `${problems.length} problems in ${CALLERS.length} files`);
  }

  // 9.
  const goal = readFileSync(join(MODEL_DIR, "design", "GOAL.md"), "utf8");
  const cfgInvariants = new Set(cfgs.flatMap((cfg) => configInfo(cfg).invariants));
  const lawProperties = [...goal.matchAll(/^\| L\d+ \|[^|]*\|([^|]*)\|/gm)].flatMap((m) => [...m[1]!.matchAll(/`(\w+)`/g)].map((p) => p[1]!));
  const problems: string[] = [];
  for (const property of lawProperties) if (!cfgInvariants.has(property)) problems.push(`GOAL.md names ${property}, which no config checks`);
  for (const invariant of cfgInvariants) if (invariant !== "TypeOK" && !lawProperties.includes(invariant)) problems.push(`${invariant} is checked but GOAL.md does not name it`);
  const mutations = loadMutations();
  const ruleIds = [...goal.matchAll(/^\| (R\d+) \|/gm)].map((m) => m[1]!);
  const covered = new Set([...edge.flatMap((c) => c.rules ?? []), ...mutations.spec.map((m) => m.rule), ...mutations.oracle.map((m) => m.rule)]);
  for (const rule of ruleIds) if (!covered.has(rule)) problems.push(`${rule} has no edge case or planted bug`);
  for (const decision of ["D4", "D5"]) if (!mutations.spec.some((m) => m.rule === decision)) problems.push(`${decision} has no planted bug showing why`);
  for (const p of problems) console.log(`  ${p}`);
  stage("traceability", problems.length === 0, `${lawProperties.length} law properties, ${ruleIds.length} rules, and the D4 and D5 witnesses accounted for`);
} catch (error) {
  console.log(`FAIL ${(error as Error).message}`);
  failures.push("exception");
}

report.failures = failures;
report.durationMs = Math.round(performance.now() - started);
writeJson(join(out, "report.json"), report);
console.log(`\n${failures.length === 0 ? "PASS" : "FAIL"} in ${elapsed(started)}; report ${join(out, "report.json")}`);
process.exit(failures.length === 0 ? 0 : 1);
