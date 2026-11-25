// Code to spec: runs event sequences through the real harness, records each run
// as the states the code showed, and has TLC check every run against ToolEdit
// (TraceToolEdit.tla). A run has named scenarios, which the design's cases
// name, and random walks. A random walk mostly takes a step the model allows
// from the state the code shows; now and then it sends an event the model does
// not allow, a fault. The code decides what a fault does, and TLC checks that
// the result is still a step of the model.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { checkTlc, configNames, seededRandom, singleConfig, toTla, type CheckedTlc } from "../mcp_call/lib.ts";
import { EVENT_NAMES, Harness, MODEL_DIR, newWorkspace, shapeOf, type Graph, type Input, type Vars } from "./lib.ts";

const edit = (event: string, i: number): Input => ({ event, i });
const plain = (event: string): Input => ({ event });

/// The named cases, by what the design says must hold in each.
export const SCENARIOS: Record<string, Input[]> = {
  "an edit from request to publish": [edit("send", 1), edit("prepare", 1), edit("auto_allow", 1), edit("apply", 1), edit("publish", 1), plain("end")],
  "a prompt answered after the program is killed runs nothing": [
    edit("send", 1), edit("prepare", 1), edit("ask", 1), plain("kill"), plain("hangup"), edit("user_allow", 1), plain("close"),
  ],
  "a raw write after review makes the edit stale, and nothing is written": [
    edit("send", 1), edit("prepare", 1), edit("auto_allow", 1), plain("raw_write"), edit("apply", 1), edit("publish", 1), plain("end"),
  ],
  "an allowed edit cancelled by a killed program writes nothing": [
    edit("send", 1), edit("prepare", 1), edit("auto_allow", 1), plain("kill"), plain("hangup"), edit("apply", 1), plain("close"),
  ],
  "two edits share one prompt, one denied and one allowed": [
    edit("send", 1), edit("send", 2), edit("prepare", 1), edit("ask", 1), edit("prepare", 2), edit("user_deny", 1),
    edit("ask", 2), edit("user_allow", 2), edit("apply", 2), edit("publish", 2), plain("end"),
  ],
  "another process writes after review, and the edit goes stale": [
    edit("send", 1), edit("prepare", 1), plain("other_write"), edit("auto_allow", 1), edit("apply", 1), edit("publish", 1), plain("end"),
  ],
  "a review that cannot complete denies the edit": [edit("send", 1), edit("prepare", 1), edit("review_unavailable", 1), plain("end")],
  "a prompt is not opened for a program that already left": [
    edit("send", 1), edit("prepare", 1), plain("kill"), plain("hangup"), edit("ask", 1), edit("withdraw", 1), plain("close"),
  ],
  "a withdrawn edit is not applied when its program ends": [
    edit("send", 1), edit("prepare", 1), edit("auto_allow", 1), plain("kill"), plain("hangup"), edit("withdraw", 1), edit("apply", 1), plain("close"),
  ],
};

const NEEDS_REQUEST = new Set(EVENT_NAMES.filter((name) => !["raw_write", "other_write", "end", "kill", "hangup", "close"].includes(name)));

function faultInput(random: () => number): Input {
  const event = EVENT_NAMES[Math.floor(random() * EVENT_NAMES.length)]!;
  return NEEDS_REQUEST.has(event) ? { event, i: random() < 0.5 ? 1 : 2 } : { event };
}

export type TraceRun = { name: string; states: Vars[] };
export type CodeToSpecResult = {
  traces: number;
  steps: number;
  scenarios: number;
  tracesPath: string;
  tlc: CheckedTlc;
};

/// Runs the scenarios and `randomTraces` random walks through `bin`, then has
/// TLC check them with `cfgText` (TraceToolEdit.cfg by default) and `cfgName`.
export async function codeToSpec(options: {
  bin: string;
  dir: string;
  graph: Graph;
  seed: number;
  randomTraces: number;
  maxLength: number;
  faultRate: number;
  cfgName?: string;
  cfgText?: string;
}): Promise<CodeToSpecResult> {
  const { graph, dir } = options;
  const random = seededRandom(options.seed);
  const traces: TraceRun[] = [];
  let steps = 0;
  let count = 0;

  const record = async (name: string, nextInput: (state: Vars, step: number) => Input | null) => {
    count += 1;
    const harness = await Harness.start(options.bin, newWorkspace(join(dir, "ws", String(count))));
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
    traces.push({ name, states });
  };

  for (const [name, inputs] of Object.entries(SCENARIOS)) {
    await record(name, (_state, step) => inputs[step] ?? null);
  }
  for (let n = 0; n < options.randomTraces; n += 1) {
    const length = 2 + Math.floor(random() * (options.maxLength - 1));
    await record(`random ${n + 1} (seed ${options.seed})`, (state, step) => {
      if (step >= length) return null;
      const node = graph.byShape.get(shapeOf(state));
      const enabled = node ? graph.out.get(node) ?? [] : [];
      if (enabled.length > 0 && random() >= options.faultRate) {
        return enabled[Math.floor(random() * enabled.length)]!.input;
      }
      return faultInput(random);
    });
  }

  mkdirSync(dir, { recursive: true });
  const tracesPath = join(dir, "traces.json");
  writeFileSync(tracesPath, `${JSON.stringify(traces, null, 1)}\n`);
  const data = [
    "---- MODULE TraceData ----",
    "EXTENDS Sequences",
    "Traces == <<",
    traces.map((trace) => `  \\* ${trace.name}\n  ${toTla(trace.states)}`).join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
  const cfgName = options.cfgName ?? "TraceToolEdit.cfg";
  const baseCfg = readFileSync(join(MODEL_DIR, "TraceToolEdit.cfg"), "utf8");
  const files: Record<string, string> = {
    "ToolEdit.tla": readFileSync(join(MODEL_DIR, "ToolEdit.tla"), "utf8"),
    "TraceToolEdit.tla": readFileSync(join(MODEL_DIR, "TraceToolEdit.tla"), "utf8"),
    "TraceData.tla": data,
    [cfgName]: options.cfgText ?? baseCfg,
  };
  const tlc = await checkTlc(join(dir, "tlc"), "TraceToolEdit", cfgName, files);
  return { traces: traces.length, steps, scenarios: Object.keys(SCENARIOS).length, tracesPath, tlc };
}

/// A config that checks one property of the traces, as the planted-bug check needs.
export function aloneConfig(property: string): string {
  const base = readFileSync(join(MODEL_DIR, "TraceToolEdit.cfg"), "utf8");
  return singleConfig(property, "TraceSpec", configNames(base).invariants, base);
}
