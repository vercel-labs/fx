// Runs the real fx binary through every shell call the shell-contract TLA+
// model covers, then has TLC replay what fx did through the model
// (tests/tla/shell_command/ShellContract.tla). No model calls: a local fake Gateway serves
// exact argument bytes.
//
// 1. The binary must conform to exactly one modeled design, the current or the
//    proposed one, and the design properties on the observed trace must match the
//    exhaustive model check of that design.
// 2. Controls: tampered, partial and empty evidence must not be accepted.
// 3. With FX_TLA_PROPOSED=1: the binary must conform to the proposed design
//    with every property holding. This fails until fx implements it.
import { test } from "bun:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetHelpers } from "../lib/context";
import { checkRuntime, modelOracle, RUNTIME_PROPERTIES, type Design, type ObservedTurn, type RuntimeResult } from "./bridge";
import { collectObservations, turnSpecs } from "./scenarios";

const helpers = await targetHelpers();
const reports = join(artifacts, "tlc");
const TIMEOUT = 900_000;

// Property verdicts from run-all.sh's exhaustive check of each design.
const EXPECTED_PROPERTIES: Record<Design, Record<string, string>> = {
  current: { Exactness: "HOLDS", GuardBound: "HOLDS", Completeness: "VIOLATED", HistoryFidelity: "VIOLATED", ZshForgiving: "VIOLATED" },
  proposed: { Exactness: "HOLDS", GuardBound: "HOLDS", Completeness: "HOLDS", HistoryFidelity: "HOLDS", ZshForgiving: "HOLDS" },
};

let observed: Promise<ObservedTurn[]> | undefined;
function observations(): Promise<ObservedTurn[]> {
  observed ??= (async () => {
    const oracle = await modelOracle("current", reports);
    const turns = await collectObservations({ binary, helpers, artifacts: join(artifacts, "fixtures") }, turnSpecs(oracle.emits));
    writeFileSync(join(artifacts, "observations.json"), JSON.stringify(turns, null, 2), { mode: 0o600 });
    return turns;
  })();
  return observed;
}

const verdicts = new Map<Design, Promise<RuntimeResult>>();
function verdict(design: Design): Promise<RuntimeResult> {
  if (!verdicts.has(design)) {
    verdicts.set(design, (async () => {
      const result = await checkRuntime(await observations(), design, reports);
      writeFileSync(join(artifacts, `${design}-design.json`), JSON.stringify(result, null, 2), { mode: 0o600 });
      return result;
    })());
  }
  return verdicts.get(design)!;
}

function explain(result: RuntimeResult): string {
  return `${result.design} ${result.verdict}: ${result.detail}\nmismatch: ${JSON.stringify(result.mismatch)}\n` +
    `properties: ${JSON.stringify(result.properties)}\nevidence: ${result.report}`;
}

async function acceptedDesign(): Promise<Design> {
  const [current, proposed] = await Promise.all([verdict("current"), verdict("proposed")]);
  const accepted = [current, proposed].filter((result) => result.verdict === "ACCEPTED");
  assert.equal(accepted.length, 1, `expected exactly one design to match\n${explain(current)}\n${explain(proposed)}`);
  return accepted[0]!.design;
}

test("real fx conforms to one modeled design", async () => {
  const design = await acceptedDesign();
  const result = await verdict(design);
  const turns = await observations();
  assert.equal(result.matchedTurns, turns.length);
  for (const property of RUNTIME_PROPERTIES) {
    assert.equal(result.properties[property]?.verdict, EXPECTED_PROPERTIES[design][property], `${property}: ${explain(result)}`);
  }
  writeFileSync(join(artifacts, "conforming-design.txt"), `${design}\n`, { mode: 0o600 });
}, TIMEOUT);

test("bridge rejects tampered, partial and empty evidence", async () => {
  const design = await acceptedDesign();
  const turns = await observations();
  const tampered: ObservedTurn[] = structuredClone(turns);
  const flip = tampered.find((t) => t.calls.length === 1 && t.calls[0]!.executed === false)!;
  flip.calls[0]!.executed = true;
  flip.calls[0]!.decoded = flip.calls[0]!.intent;
  flip.calls[0]!.outcome = "ok";
  const rejected = await checkRuntime(tampered, design, join(reports, "control-tampered"));
  writeFileSync(join(artifacts, "control-tampered.json"), JSON.stringify(rejected, null, 2), { mode: 0o600 });
  assert.equal(rejected.verdict, "REJECTED", explain(rejected));
  assert.equal(rejected.mismatch?.turn, flip.name, explain(rejected));

  // Drop the only turn that covers some modeled call, so coverage is incomplete.
  const key = (call: { intent: string; shape: string }) => `${call.intent}/${call.shape}`;
  const counts = new Map<string, number>();
  for (const turn of turns) for (const call of turn.calls) counts.set(key(call), (counts.get(key(call)) ?? 0) + 1);
  const only = turns.find((t) => t.calls.length === 1 && counts.get(key(t.calls[0]!)) === 1)!;
  const partial = turns.filter((t) => t !== only);
  const missing = await checkRuntime(partial, design, join(reports, "control-partial"));
  assert.equal(missing.verdict, "INCONCLUSIVE", explain(missing));

  const empty = await checkRuntime([], design, join(reports, "control-empty"));
  assert.equal(empty.verdict, "INCONCLUSIVE", explain(empty));
}, TIMEOUT);

test.skipIf(process.env.FX_TLA_PROPOSED !== "1")("real fx meets the proposed design", async () => {
  const result = await verdict("proposed");
  assert.equal(result.verdict, "ACCEPTED", explain(result));
  for (const property of RUNTIME_PROPERTIES) {
    assert.equal(result.properties[property]?.verdict, "HOLDS", `${property}: ${explain(result)}`);
  }
}, TIMEOUT);
