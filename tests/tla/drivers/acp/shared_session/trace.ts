// TLC trace validation: turns one observed run of the real fx acp binary into the
// generated AcpSharedSessionObs module, and asks TLC whether it is a behavior of
// tests/tla/acp/AcpSharedSession.tla, through AcpSharedSessionTrace.tla. "rules" sets
// Rules TRUE, the sh.fx rules; "today" sets it FALSE, the model with no list, no
// sender key, and no delivery to other clients. A run is ACCEPTED when TLC reaches its
// last observation and REJECTED when some observation matches no step.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runTlc, sha256Text, writeJson } from "./tlc";

export type Client = "opener" | "f1" | "f2";
export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

/// What the driver observed, in order. Each one is fx's output or the driver's act.
export type Obs =
  | { op: "open"; c: Client; k: "new" | "load" }
  | { op: "read"; c: Client; kind: "answer" | "clients" | "echo" | "steer"; n: number; who: Client[]; main: Client | "none"; from: Client | "none" }
  | { op: "prompt"; c: Client }
  | { op: "steer"; c: Client }
  | { op: "close"; c: Client }
  | { op: "endTurn" }
  | { op: "quiet" };

export const CONNS: Client[] = ["opener", "f1", "f2"];
/// The clients that list sh.fx/sessionClients. f2 is the client that does not list it.
export const LISTS: Client[] = ["opener", "f1"];

const q = (value: string) => JSON.stringify(value);
const FIELDS = ["op", "c", "k", "kind", "n", "who", "main", "from"] as const;

/// One observation as a TLA record. Every record has the same fields, so the trace module
/// reads any of them; a field an observation does not use has a fixed default.
export function record(o: Obs): string {
  const f: Record<(typeof FIELDS)[number], string> = {
    op: q(o.op),
    c: q("none"),
    k: q("none"),
    kind: q("none"),
    n: "0",
    who: "{}",
    main: q("none"),
    from: q("none"),
  };
  switch (o.op) {
    case "open":
      f.c = q(o.c);
      f.k = q(o.k);
      break;
    case "read":
      f.c = q(o.c);
      f.kind = q(o.kind);
      f.n = String(o.n);
      f.who = `{${o.who.map(q).join(", ")}}`;
      f.main = q(o.main);
      f.from = q(o.from);
      break;
    case "prompt":
    case "steer":
    case "close":
      f.c = q(o.c);
      break;
    default:
      break;
  }
  return `[${FIELDS.map((name) => `${name} |-> ${f[name]}`).join(", ")}]`;
}

/// The generated module: this run's TraceLog and its constants.
export function obsModule(observations: Obs[], rules: boolean): string {
  const prompts = observations.filter((o) => o.op === "prompt" || o.op === "steer").length;
  return [
    "---------------------- MODULE AcpSharedSessionObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    `TRules == ${rules ? "TRUE" : "FALSE"}`,
    `TConns == {${CONNS.map(q).join(", ")}}`,
    `TLists == {${LISTS.map(q).join(", ")}}`,
    "TSenderKey == TRUE",
    `TMaxPrompts == ${prompts}`,
    "TMaxAsks == 0",
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
  "    Conns <- TConns",
  "    Lists <- TLists",
  "    SenderKey <- TSenderKey",
  "    MaxPrompts <- TMaxPrompts",
  "    MaxAsks <- TMaxAsks",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotDone",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

/// Checks one run against AcpSharedSession with Rules set to `rules`, in `dir`.
export async function validate(observations: Obs[], dir: string, rules: boolean): Promise<{ verdict: Verdict; length: number; finalIndex: number | null; violated: string | null; exitCode: number }> {
  mkdirSync(dir, { recursive: true });
  const module = obsModule(observations, rules);
  writeFileSync(join(dir, "AcpSharedSessionObs.tla"), module);
  writeFileSync(join(dir, "AcpSharedSessionTrace.cfg"), TRACE_CFG);
  const run = await runTlc(dir, "AcpSharedSessionTrace.tla", "AcpSharedSessionTrace.cfg", ["AcpSharedSession.tla", "AcpSharedSessionTrace.tla"]);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict = "TOOL_ERROR";
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === observations.length) verdict = "ACCEPTED";
  else if (run.exitCode === 0 && /No error has been found/.test(run.output)) verdict = "REJECTED";
  writeJson(join(dir, "verdict.json"), {
    verdict,
    rules,
    length: observations.length,
    finalIndex,
    exitCode: run.exitCode,
    violated: run.violated,
    obs_sha256: sha256Text(module),
  });
  return { verdict, length: observations.length, finalIndex, violated: run.violated, exitCode: run.exitCode };
}
