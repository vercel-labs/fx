// Connects behavior observed from the real fx binary to TLC.
//
// 1. ShellOracle prints the model's emission set and Record(e) for each one.
//    Every modeled emission must have been observed, or the check is INCONCLUSIVE.
// 2. The observations become ShellObserved.tla. ShellTrace replays them through
//    ShellContract's own Process step. ACCEPTED requires TLC exit 12 on the
//    NotAllMatched sentinel with every turn matched; a completed search is REJECTED.
// 3. After acceptance, each design property is checked on the same replay.
//
// Strict verdicts: unreadable or missing evidence is never acceptance.
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { join, resolve } from "node:path";
import { TLA_ROOT, tlcToolchain } from "../lib/tlc";

export type Design = "current" | "proposed";
export type Verdict = "ACCEPTED" | "REJECTED" | "INCONCLUSIVE" | "TOOL_ERROR";
export type PropertyVerdict = "HOLDS" | "VIOLATED" | "NOT_CHECKED" | "TOOL_ERROR";

export interface ObservedCall {
  id: string;
  intent: string;
  shape: string;
  /** Exact argument text sent to fx. */
  sent: string;
  /** null when the result could not be read. */
  executed: boolean | null;
  decoded: string;
  outcome: string;
  /** How the call appeared in the next request; absent when fx sent none. */
  history: { observed: true; input: unknown } | { observed: false };
  resultBody: string;
}

export interface ObservedTurn {
  name: string;
  calls: ObservedCall[];
  ended: "final" | "guard" | "unknown";
}

export interface Prediction { accepted: boolean; decoded: string; history: string; outcome: string }

export interface RuntimeResult {
  version: 1;
  design: Design;
  verdict: Verdict;
  detail: string;
  turns: number;
  matchedTurns: number;
  mismatch?: { turn: string; call?: string; observed?: unknown; predicted?: unknown };
  /** Every observed call that differs from the model's prediction. Diagnostic only;
   * the verdict comes from TLC. */
  divergences?: Array<{ turn: string; call: string; observed: unknown; predicted: unknown }>;
  properties: Record<string, { verdict: PropertyVerdict; detail?: string }>;
  report: string;
  hashes: Record<string, string>;
}

/** Design properties that the runtime trace can decide. AdmissionConsistency needs
 * what permission admission saw, which the runtime does not expose. */
export const RUNTIME_PROPERTIES = ["Exactness", "Completeness", "HistoryFidelity", "ZshForgiving", "GuardBound"] as const;

const tlaDir = join(TLA_ROOT, "shell_command");
const MODULES = ["ShellContract.tla", "ShellTrace.tla", "ShellOracle.tla"];

const sha256 = (bytes: string | Buffer) => createHash("sha256").update(bytes).digest("hex");

function word(value: string): string {
  if (!/^[a-z_:]+$/.test(value)) throw new Error(`refusing unsafe TLA+ string: ${JSON.stringify(value)}`);
  return `"${value}"`;
}

function tryParse(text: string): { ok: true; value: unknown } | { ok: false } {
  try { return { ok: true, value: JSON.parse(text) }; } catch { return { ok: false }; }
}

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** The form an accepted call takes in history under each design. */
function canonical(design: Design, input: unknown): boolean {
  if (!isObject(input)) return false;
  if (design === "current") {
    return !("request" in input) && typeof input.action === "string";
  }
  return !("request" in input) && !("action" in input) &&
    (typeof input.command === "string" || typeof input.session_id === "string");
}

export function historyClass(design: Design, call: ObservedCall): string {
  if (!call.history.observed) return "unobserved";
  const input = call.history.input;
  if (call.executed && canonical(design, input)) return "canonical";
  // Text that is not JSON cannot be replayed; fx shows {} so providers accept the history.
  if (!call.executed && call.shape === "invalid_json" && isDeepStrictEqual(input, {})) return "placeholder";
  const sent = tryParse(call.sent);
  if (sent.ok && isDeepStrictEqual(input, sent.value)) return `as_sent:${call.shape}`;
  // The orchestrator unwraps an exact {"request":{...}} before the call is stored.
  if (sent.ok && isObject(sent.value) && isObject(sent.value.request) &&
    isDeepStrictEqual(input, sent.value.request)) return `unwrapped:${call.shape}`;
  // It also adds the action a call without one means, as the first field.
  if (sent.ok && isObject(sent.value) && !("action" in sent.value) && isObject(input) &&
    typeof input.action === "string" && Object.keys(input)[0] === "action") {
    const { action: _action, ...rest } = input;
    if (isDeepStrictEqual(rest, sent.value)) return `inferred:${call.shape}`;
  }
  return `rewrapped:${call.shape}`;
}

export function abstractCall(design: Design, call: ObservedCall) {
  return {
    intent: call.intent,
    shape: call.shape,
    accepted: call.executed === true,
    decoded: call.executed ? call.decoded : "none",
    history: historyClass(design, call),
    outcome: call.outcome,
  };
}

export function observedModule(design: Design, turns: ObservedTurn[]): string {
  const record = (call: ObservedCall) => {
    const a = abstractCall(design, call);
    return `[e |-> [intent |-> ${word(a.intent)}, shape |-> ${word(a.shape)}], accepted |-> ${a.accepted ? "TRUE" : "FALSE"}, ` +
      `decoded |-> ${word(a.decoded)}, history |-> ${word(a.history)}, outcome |-> ${word(a.outcome)}]`;
  };
  const turnText = (turn: ObservedTurn) =>
    `  [calls |-> << ${turn.calls.map(record).join(",\n                ")} >>,\n   ended |-> ${word(turn.ended)}]`;
  return [
    "---------------------------- MODULE ShellObserved ----------------------------",
    `(* Generated by bun/bridge.ts from real fx runs. Design under test: ${design}. *)`,
    "Observed == <<",
    turns.map(turnText).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

function config(design: Design, body: string): string {
  return [
    body,
    "CONSTANTS",
    `  Design = "${design}"`,
    '  AdmissionReads = "normalized"',
    "  GuessAmbiguous = FALSE",
    "  MaxCalls = 3",
    "",
  ].join("\n");
}

interface TlcRun { exitCode: number; log: string; dir: string }

async function runTlc(dir: string, spec: string, cfg: string, extra: string[] = []): Promise<TlcRun> {
  writeFileSync(join(dir, "check.cfg"), cfg, { mode: 0o600 });
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const command = [java, "-XX:+UseParallelGC", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar, "tlc2.TLC", "-workers", "1",
    "-metadir", join(dir, ".tlc-states"), "-config", "check.cfg", ...extra, spec];
  const child = Bun.spawn(command, { cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
  ]);
  const log = `${stderr}\n${stdout}`;
  writeFileSync(join(dir, "tlc.log"), log, { mode: 0o600 });
  writeFileSync(join(dir, "result.json"), JSON.stringify({ command, exitCode }, null, 2), { mode: 0o600 });
  return { exitCode, log, dir };
}

function stage(root: string, name: string, observed?: string): string {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const module of MODULES) copyFileSync(join(tlaDir, module), join(dir, module));
  // Only ShellTrace extends ShellObserved; TLC parses just the root module's imports.
  if (observed !== undefined) writeFileSync(join(dir, "ShellObserved.tla"), observed, { mode: 0o600 });
  return dir;
}

const completed = (log: string) => log.includes("Model checking completed. No error has been found.");
const violated = (log: string, name: string) => log.includes(`Invariant ${name} is violated`);

/** The model's emission set and predicted record per emission, from TLC itself. */
export async function modelOracle(design: Design, reportRoot: string) {
  mkdirSync(reportRoot, { recursive: true, mode: 0o700 });
  const dir = stage(mkdtempSync(join(reportRoot, `oracle-${design}-`)), "oracle");
  const run = await runTlc(dir, "ShellOracle.tla", config(design, "INIT Init\nNEXT OracleNext"));
  // TLC wraps long tuples across lines; join them before matching.
  const text = run.log.replace(/\n\s+/g, " ");
  const predictions = new Map<string, Prediction>();
  const line = /<<\s*"FXT_PREDICT",\s*"([a-z_]+)",\s*"([a-z_]+)",\s*(TRUE|FALSE),\s*"([a-z_]+)",\s*"([a-z_:]+)",\s*"([a-z_]+)"\s*>>/g;
  for (const m of text.matchAll(line)) {
    predictions.set(`${m[1]}/${m[2]}`, { accepted: m[3] === "TRUE", decoded: m[4]!, history: m[5]!, outcome: m[6]! });
  }
  const expected = Number(/<<\s*"FXT_EMITS",\s*(\d+)\s*>>/.exec(text)?.[1] ?? NaN);
  if (run.exitCode !== 0 || !completed(run.log) || !(expected > 0) || predictions.size !== expected) {
    throw new Error(`ShellOracle failed (exit ${run.exitCode}, ${predictions.size} of ${expected} predictions parsed); ` +
      `see ${join(dir, "tlc.log")}`);
  }
  return { predictions, emits: [...predictions.keys()].sort(), log: join(dir, "tlc.log") };
}

/** Replays the observations through the model for one design and checks the design properties. */
export async function checkRuntime(turns: ObservedTurn[], design: Design, reportRoot: string,
  options: { requireCoverage?: boolean } = {}): Promise<RuntimeResult> {
  mkdirSync(reportRoot, { recursive: true, mode: 0o700 });
  const root = mkdtempSync(join(reportRoot, `${design}-`));
  const properties: RuntimeResult["properties"] = Object.fromEntries(
    RUNTIME_PROPERTIES.map((p) => [p, { verdict: "NOT_CHECKED" as PropertyVerdict }]));
  const hashes: Record<string, string> = Object.fromEntries(
    [...MODULES.map((m) => [m, sha256(readFileSync(join(tlaDir, m)))]), ["tla2tools.jar", tlcToolchain().jarSha256]]);
  const finish = (verdict: Verdict, detail: string, extra: Partial<RuntimeResult> = {}): RuntimeResult => {
    const result: RuntimeResult = { version: 1, design, verdict, detail, turns: turns.length, matchedTurns: 0,
      properties, report: root, hashes, ...extra };
    writeFileSync(join(root, "verdict.json"), JSON.stringify(result, null, 2), { mode: 0o600 });
    return result;
  };
  writeFileSync(join(root, "observations.json"), JSON.stringify(turns, null, 2), { mode: 0o600 });
  hashes["observations.json"] = sha256(readFileSync(join(root, "observations.json")));

  if (!turns.length || turns.some((t) => !t.calls.length)) return finish("INCONCLUSIVE", "empty observation");
  const unreadable = turns.flatMap((t) => t.calls.filter((c) => c.executed === null).map((c) => `${t.name}/${c.id}`));
  if (unreadable.length) return finish("INCONCLUSIVE", `unreadable results: ${unreadable.join(", ")}`);
  const unended = turns.filter((t) => t.ended === "unknown").map((t) => t.name);
  if (unended.length) return finish("INCONCLUSIVE", `turn end not established: ${unended.join(", ")}`);

  let oracle: Awaited<ReturnType<typeof modelOracle>>;
  try { oracle = await modelOracle(design, root); } catch (error) { return finish("TOOL_ERROR", String(error)); }
  if (options.requireCoverage !== false) {
    const seen = new Set(turns.flatMap((t) => t.calls.map((c) => `${c.intent}/${c.shape}`)));
    const missing = oracle.emits.filter((key) => !seen.has(key));
    if (missing.length) return finish("INCONCLUSIVE", `modeled calls never observed: ${missing.join(", ")}`);
  }

  let observed: string;
  try { observed = observedModule(design, turns); } catch (error) { return finish("TOOL_ERROR", String(error)); }
  hashes["ShellObserved.tla"] = sha256(observed);

  const conformance = await runTlc(stage(root, "conformance", observed), "ShellTrace.tla",
    config(design, "SPECIFICATION TraceSpec\nINVARIANT NotAllMatched"), ["-deadlock"]);
  const matched = new Set([...conformance.log.matchAll(/<<"FXT_MATCHED", (\d+)>>/g)].map((m) => Number(m[1])));
  const accepted = conformance.exitCode === 12 && violated(conformance.log, "NotAllMatched") && matched.size === turns.length;
  if (!accepted) {
    if (!(conformance.exitCode === 0 && completed(conformance.log))) {
      return finish("TOOL_ERROR", `unexpected TLC result (exit ${conformance.exitCode}); see ${join(conformance.dir, "tlc.log")}`,
        { matchedTurns: matched.size });
    }
    const index = matched.size;  // turns replay in order; this is the first unmatched one
    const turn = turns[index]!;
    const differs = (call: ObservedCall) => {
      const p = oracle.predictions.get(`${call.intent}/${call.shape}`);
      const a = abstractCall(design, call);
      return !p || p.accepted !== a.accepted || p.decoded !== a.decoded || p.outcome !== a.outcome ||
        (a.history !== "unobserved" && p.history !== a.history);
    };
    const divergences = turns.flatMap((t) => t.calls.filter(differs).map((call) => ({
      turn: t.name, call: `${call.intent}/${call.shape}`, observed: abstractCall(design, call),
      predicted: oracle.predictions.get(`${call.intent}/${call.shape}`),
    })));
    const wrong = turn.calls.find(differs);
    const mismatch = wrong
      ? { turn: turn.name, call: `${wrong.intent}/${wrong.shape}`, observed: abstractCall(design, wrong),
          predicted: oracle.predictions.get(`${wrong.intent}/${wrong.shape}`) }
      : { turn: turn.name, observed: { ended: turn.ended, calls: turn.calls.length } };
    return finish("REJECTED", `runtime diverges from the ${design} model at turn ${index + 1} (${turn.name}); ` +
      `${divergences.length} call(s) differ from its predictions`, { matchedTurns: matched.size, mismatch, divergences });
  }

  for (const property of RUNTIME_PROPERTIES) {
    const run = await runTlc(stage(root, `property-${property}`, observed), "ShellTrace.tla",
      config(design, `SPECIFICATION TraceSpec\nINVARIANT ${property}`), ["-deadlock"]);
    if (run.exitCode === 0 && completed(run.log)) {
      properties[property] = { verdict: "HOLDS" };
    } else if (run.exitCode === 12 && violated(run.log, property)) {
      const last = run.log.lastIndexOf("/\\ calls = ");
      properties[property] = { verdict: "VIOLATED", detail: last >= 0 ? run.log.slice(last, last + 400).split("\n/\\")[0] : undefined };
    } else {
      properties[property] = { verdict: "TOOL_ERROR", detail: `exit ${run.exitCode}; see ${join(run.dir, "tlc.log")}` };
    }
  }
  return finish("ACCEPTED", `all ${turns.length} observed turns match the ${design} model`, { matchedTurns: matched.size });
}
