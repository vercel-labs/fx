// Code to spec: runs event sequences through the real result store, records each
// run as the states the code showed, and has TLC check the runs against the
// three-program ResultStore (TraceResultStore.tla). A run is a named scenario,
// which must reach one witness, or a random walk. A random walk mostly sends an
// event the model can take in the phase the code shows (plausibleEvents); now and
// then it sends an event at random, a fault. The harness refuses what the model
// does not allow, and TLC checks that every recorded step is a step of the model.
// The walk does not need the model's graph: its guesses only steer coverage.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { checkTlc, configNames, seededRandom, singleConfig, toTla, type CheckedTlc } from "../mcp_call/lib.ts";
import { DESIGN_ROOM, EVENT_NAMES, Harness, KINDS, MODEL_DIR, PROGRAMS, newWorkspace, type Input, type Vars } from "./lib.ts";

export type TraceRun = { name: string; states: Vars[] };
export type Recorded = { runs: TraceRun[]; steps: number; path: string };

/// The named scenarios. Each one is recorded once, and its name says which witness it reaches.
export const ORPHAN = "orphan: fx stops after a result's file and before its index line";
export const FULL = "full: the third result finds no room, and the result says so";
export const RESUME = "resume: a resumed fx shows a result above an orphan file";

const send = (i: number): Input => ({ event: "send", i });
const finish = (kind: string, big = false): Input => ({ event: "finish", kind, big });
const plain = (event: string): Input => ({ event });

export const SCENARIOS: Record<string, Input[]> = {
  [ORPHAN]: [send(1), finish("ok"), plain("file"), plain("restart")],
  [FULL]: [
    send(1), finish("ok"), plain("file"), plain("index"), plain("show"), plain("clear"),
    send(2), finish("ok"), plain("file"), plain("index"), plain("show"), plain("clear"),
    send(3), finish("ok"), plain("file"), plain("show"), plain("clear"),
  ],
  [RESUME]: [
    send(1), finish("ok"), plain("file"), plain("restart"),
    send(2), finish("ok"), plain("file"), plain("index"), plain("show"), plain("clear"),
  ],
};

/// An event with arguments drawn at random: a fault, or a step of a model that
/// is not in the state yet.
function faultInput(random: () => number): Input {
  const event = EVENT_NAMES[Math.floor(random() * EVENT_NAMES.length)]!;
  if (event === "send") return { event, i: 1 + Math.floor(random() * 3) };
  if (event === "finish") return { event, kind: KINDS[Math.floor(random() * KINDS.length)]!, big: random() < 0.5 };
  return { event };
}

/// The events the model can take in the phase the state shows, with their
/// arguments. This only steers the walk: TLC checks every recorded step.
export function plausibleEvents(state: Vars): Input[] {
  const sent = new Set(state.sent as string[]);
  const sends = PROGRAMS.filter((p) => !sent.has(p)).map((p) => ({ event: "send", i: Number(p.slice(1)) }));
  switch (state.phase) {
    case "idle":
      return [...sends, plain("restart"), plain("wait_more"), plain("damage"), plain("heal_fails")];
    case "run":
      return KINDS.flatMap((kind) => [finish(kind, false), finish(kind, true)]);
    case "ended":
      return [plain("file")];
    case "filed":
      return [plain("index")];
    default:
      return [plain("show"), plain("clear"), plain("give_up"), plain("wait_more"), plain("restart")];
  }
}

/// Runs the scenarios and `randomTraces` random walks through `bin`, and writes
/// the runs to `dir/traces.json`. Each run starts a new harness in a new workspace.
export async function recordRuns(options: {
  bin: string;
  dir: string;
  seed: number;
  randomTraces: number;
  maxLength: number;
  faultRate: number;
}): Promise<Recorded> {
  const { dir } = options;
  const random = seededRandom(options.seed);
  const runs: TraceRun[] = [];
  let steps = 0;
  let count = 0;

  const record = async (name: string, nextInput: (state: Vars, step: number) => Input | null) => {
    count += 1;
    const harness = await Harness.start(options.bin, newWorkspace(join(dir, "ws", String(count))), DESIGN_ROOM);
    const states: Vars[] = [harness.first.state];
    let state = harness.first.state;
    try {
      for (let step = 0; ; step += 1) {
        const input = nextInput(state, step);
        if (!input) break;
        const reply = await harness.send(input);
        steps += 1;
        states.push(reply.state);
        state = reply.state;
      }
    } finally {
      await harness.close();
    }
    runs.push({ name, states });
  };

  for (const [name, inputs] of Object.entries(SCENARIOS)) {
    await record(name, (_state, step) => inputs[step] ?? null);
  }
  for (let n = 0; n < options.randomTraces; n += 1) {
    const length = 2 + Math.floor(random() * (options.maxLength - 1));
    await record(`random ${n + 1} (seed ${options.seed})`, (state, step) => {
      if (step >= length) return null;
      const enabled = plausibleEvents(state);
      if (enabled.length > 0 && random() >= options.faultRate) {
        return enabled[Math.floor(random() * enabled.length)]!;
      }
      return faultInput(random);
    });
  }

  mkdirSync(dir, { recursive: true });
  const path = join(dir, "traces.json");
  writeFileSync(path, `${JSON.stringify(runs, null, 1)}\n`);
  return { runs, steps, path };
}

/// The TLA+ module that holds the runs as sequences of states.
export function traceData(runs: TraceRun[]): string {
  return [
    "---- MODULE TraceData ----",
    "EXTENDS Sequences",
    "Traces == <<",
    runs.map((run) => `  \\* ${run.name}\n  ${toTla(run.states)}`).join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
}

/// The shipped config, which checks every store rule on the runs.
export function baseConfig(): string {
  return readFileSync(join(MODEL_DIR, "TraceResultStore.cfg"), "utf8");
}

/// A config that checks only `property` on the runs, as a planted bug needs.
export function aloneConfig(property: string): string {
  const base = baseConfig();
  return singleConfig(property, "TraceSpec", configNames(base).invariants, base);
}

/// A config that checks one witness, which must be violated: TLC reached its case.
export function witnessConfig(witness: string): string {
  return `SPECIFICATION TraceSpec\nCHECK_DEADLOCK FALSE\nINVARIANT\n    ${witness}\n`;
}

/// Has TLC check `runs` with `cfgText` in `dir/label`.
export async function checkRuns(dir: string, label: string, runs: TraceRun[], cfgName: string, cfgText: string): Promise<CheckedTlc> {
  const files: Record<string, string> = {
    "ResultStore.tla": readFileSync(join(MODEL_DIR, "ResultStore.tla"), "utf8"),
    "TraceResultStore.tla": readFileSync(join(MODEL_DIR, "TraceResultStore.tla"), "utf8"),
    "TraceData.tla": traceData(runs),
    [cfgName]: cfgText,
  };
  return checkTlc(join(dir, label), "TraceResultStore", cfgName, files);
}
