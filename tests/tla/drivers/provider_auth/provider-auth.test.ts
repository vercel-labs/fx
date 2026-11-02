// Runs the target worktree's real libfx credential edge (the authorizer that
// transportFetch hands Codex, Grok and custom-provider requests to) through
// the scenarios in scenarios.ts, then has TLC replay each run
// through the ProviderAuth model. No network: every endpoint is a local fake.
//
// 1. Every run must be a behavior of the model (TLC ACCEPTED), and each
//    property must reach the verdict its scenario declares.
// 2. Controls: a tampered, a truncated and an empty run must not be accepted.
import { expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, worktree } from "../lib/context";
import { checkTrace, type TraceResult } from "./bridge";
import { loadEdge, runScenario, type Run } from "./driver";
import { scenarios } from "./scenarios";
import { PROPERTIES } from "./tlc";

const TIMEOUT = 900_000;
const reports = join(artifacts, "tlc");
const edge = await loadEdge(worktree);
writeFileSync(join(artifacts, "edge.json"), JSON.stringify({ worktree, shape: edge.shape, providers: edge.providers }, null, 2));

const runs = new Map<string, Run>();

// Code with shared credential memory asks the host again after a 401, which
// AuthTrace does not replay. There, fixed-check.ts checks the rejection
// scenarios from their recorded events instead.
const asksAgain = edge.memory !== undefined;
const replayable = (name: string) => !(asksAgain && /-(rejected-refreshes-once|late-rejection-after-refresh)$/.test(name));

for (const provider of edge.providers) {
  for (const scenario of scenarios(provider)) {
    test.skipIf(!replayable(scenario.name))(`${scenario.name} is a run of the model`, async () => {
      const run = await runScenario(worktree, scenario.name, scenario.setup, scenario.script, { accounts: scenario.accounts });
      runs.set(scenario.name, run);
      const result: TraceResult = await checkTrace(run, reports);
      writeFileSync(join(artifacts, `${scenario.name}.json`), JSON.stringify({ run, result }, null, 2));
      expect(result.verdict, `${result.detail}\nevents: ${JSON.stringify(run.events)}`).toBe("ACCEPTED");
      for (const property of PROPERTIES) {
        expect(result.properties[property], `${property} on ${scenario.name}`).toBe(scenario.expect?.[property] ?? "HOLDS");
      }
    }, TIMEOUT);
  }
}

test("controls: tampered, truncated and empty runs are not accepted", async () => {
  const preferred = asksAgain ? "codex-expiring-refreshes-first" : "codex-rejected-refreshes-once";
  const name = edge.providers.includes("codex") ? preferred : [...runs.keys()][0]!;
  const run = runs.get(name) ?? await (async () => {
    const scenario = scenarios("codex").find((s) => s.name === name)!;
    return runScenario(worktree, scenario.name, scenario.setup, scenario.script);
  })();
  // The resend after the 401 carries the rejected token again.
  const tampered = structuredClone(run);
  const lastSend = tampered.events.findLastIndex((event) => event.k === "send");
  (tampered.events[lastSend] as { at: number }).at = 0;
  tampered.scenario = `${name}-tampered`;
  const truncated = structuredClone(run);
  truncated.events = truncated.events.filter((event) => event.k !== "save");
  truncated.scenario = `${name}-without-save`;
  const empty = { ...structuredClone(run), scenario: `${name}-empty`, events: [] };
  const verdicts = await Promise.all([tampered, truncated, empty].map((r) => checkTrace(r, reports)));
  writeFileSync(join(artifacts, "controls.json"), JSON.stringify(verdicts, null, 2));
  expect(verdicts[0]!.verdict).toBe("REJECTED");
  expect(verdicts[1]!.verdict).toBe("REJECTED");
  expect(verdicts[2]!.verdict).toBe("INCONCLUSIVE");
}, TIMEOUT);
