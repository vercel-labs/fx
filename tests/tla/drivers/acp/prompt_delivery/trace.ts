// TLC trace validation: turns one observed run into the generated
// AcpPromptDeliveryObs module and asks TLC whether it is a behavior of
// tests/tla/acp/AcpPromptDelivery.tla, through AcpPromptDeliveryTrace.tla.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

export type Answer = { kind: "none" | "ok" | "err"; stop: string; delivery: string; code: number };
export const NO_ANSWER: Answer = { kind: "none", stop: "", delivery: "", code: 0 };

/// One action of the model, with what the driver observed after it.
export type Observation = {
  act: string;
  msg: string;
  checkAnswers: boolean;
  answers: Record<string, Answer>;
  checkCtx: boolean;
  ctx: string[];
  detail?: unknown;
};

const tla = (value: string) => JSON.stringify(value);
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");
const answer = (a: Answer) => `[kind |-> ${tla(a.kind)}, stop |-> ${tla(a.stop)}, delivery |-> ${tla(a.delivery)}, code |-> ${a.code}]`;

export type Bounds = { rules: boolean; msgs: string[]; maxTools: number; maxCancels: number; allowClose: boolean };

export function obsModule(observations: Observation[], bounds: Bounds): string {
  const answers = (record: Record<string, Answer>) =>
    `[${bounds.msgs.map((m) => `${m} |-> ${answer(record[m] ?? NO_ANSWER)}`).join(", ")}]`;
  const record = (o: Observation) =>
    `[act |-> ${tla(o.act)}, msg |-> ${tla(o.msg)}, checkAnswers |-> ${bool(o.checkAnswers)}, answers |-> ${answers(o.answers)}, checkCtx |-> ${bool(o.checkCtx)}, ctx |-> {${o.ctx.map(tla).join(", ")}}]`;
  return [
    "---------------------- MODULE AcpPromptDeliveryObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    "EXTENDS Integers",
    `TRules == ${bool(bounds.rules)}`,
    `TMsgs == {${bounds.msgs.map(tla).join(", ")}}`,
    `TMaxTools == ${bounds.maxTools}`,
    `TMaxCancels == ${bounds.maxCancels}`,
    `TAllowClose == ${bool(bounds.allowClose)}`,
    "TraceLog == <<",
    observations.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  "    Rules <- TRules",
  "    Msgs <- TMsgs",
  "    MaxTools <- TMaxTools",
  "    MaxCancels <- TMaxCancels",
  "    AllowClose <- TAllowClose",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

export async function validate(observations: Observation[], dir: string, bounds: Bounds) {
  mkdirSync(dir, { recursive: true });
  if (observations.length === 0) return { verdict: "TOOL_ERROR" as Verdict, matched: 0, firstDivergence: null };
  const obs = obsModule(observations, bounds);
  writeFileSync(join(dir, "AcpPromptDeliveryObs.tla"), obs);
  writeFileSync(join(dir, "AcpPromptDeliveryTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpPromptDeliveryTrace.tla", "AcpPromptDeliveryTrace.cfg", ["AcpPromptDelivery.tla", "AcpPromptDeliveryTrace.tla"]);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict;
  let matched: number;
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === observations.length) {
    verdict = "ACCEPTED";
    matched = observations.length;
  } else if (run.exitCode === 0 && /No error has been found/.test(run.output)) {
    verdict = "REJECTED";
    // States are i = 0..k, so a search of depth d matched d - 1 steps.
    matched = Math.max(0, (run.depth ?? 1) - 1);
  } else {
    verdict = "TOOL_ERROR";
    matched = 0;
  }
  const result = {
    verdict,
    matched,
    length: observations.length,
    bounds,
    firstDivergence: verdict === "REJECTED" ? { step: matched + 1, observation: observations[matched] ?? null } : null,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(obs),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
