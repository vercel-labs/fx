// Code to spec for the agent wait: runs event sequences through the real
// harness, records each run as the states the code showed, and has TLC check
// every run against AgentWait (TraceAgentWait.tla). A run has named scenarios,
// which the design's cases name, and seeded random walks. A random walk mostly
// takes a step the model allows from the state the code shows; now and then it
// sends an event the model does not allow, a fault. The code decides what a
// fault does, and TLC checks that the result is still a step of the model.
// Every run ends with an epilogue that kills its program, cancels its wait,
// and returns its bash call, so a run that leaves a wait open for a gone
// program ends in a state TLC can see.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { checkTlc, configNames, seededRandom, singleConfig, toTla, type CheckedTlc } from "../mcp_call/lib.ts";
import { Harness } from "./lib.ts";
import {
  EVENT_NAMES,
  MODEL_DIR,
  harnessEnv,
  newHome,
  shapeOf,
  type AgentGraph,
  type Input,
  type Vars,
} from "./agent-lib.ts";

const ev = (event: string): Input => ({ event });

/// The named cases, by what the design says must hold in each. The witnesses
/// of AgentWait each have their own case.
export const SCENARIOS: Record<string, Input[]> = {
  "a wait ends on mail a child posts, and the program's end returns its call": [
    ev("run"), ev("start_wait"), ev("post"), ev("gone"), ev("return"),
  ],
  "mail already waiting ends a wait at once, and stays queued until the parent's turn takes it": [
    ev("run"), ev("post"), ev("start_wait"), ev("yield"), ev("join"),
  ],
  "a wait whose program is killed is canceled, and its bash call returns": [
    ev("run"), ev("start_wait"), ev("gone"), ev("cancel"), ev("return"),
  ],
  "a first call yields, and its wait_more yields again": [
    ev("run"), ev("yield"), ev("wait_more"), ev("yield"), ev("gone"),
  ],
  "a wait after the first call yielded is refused": [
    ev("run"), ev("yield"), ev("start_wait"), ev("gone"),
  ],
  "a child that ends without a report makes its waiting wait quiet": [
    ev("run"), ev("start_wait"), ev("child_ends"), ev("gone"), ev("return"),
  ],
  "a wait with no child working is quiet at once": [
    ev("run"), ev("child_ends"), ev("start_wait"), ev("gone"), ev("return"),
  ],
  "a yield does not land while a wait holds the first call, and lands after the wait": [
    ev("run"), ev("start_wait"), ev("yield"), ev("post"), ev("yield"), ev("join"), ev("gone"),
  ],
  "two posts wait for the parent's turn, and each join takes one": [
    ev("run"), ev("post"), ev("post"), ev("start_wait"), ev("yield"), ev("join"), ev("join"), ev("gone"),
  ],
  "a second program starts after the first returns": [
    ev("run"), ev("gone"), ev("return"), ev("run"), ev("start_wait"), ev("gone"), ev("cancel"), ev("return"),
  ],
};

/// The events that end a run, one at a time: the program is killed, its wait is
/// canceled, and its bash call returns. Null when nothing is left to end.
export function epilogue(state: Vars): Input | null {
  if (state.prog === "running") return ev("gone");
  if (state.call === "waiting") return ev("cancel");
  if (state.prog === "gone" && (state.bash === "first" || state.bash === "more")) return ev("return");
  return null;
}

export type TraceRun = { name: string; states: Vars[] };
export type AgentCodeToSpecResult = {
  traces: number;
  steps: number;
  scenarios: number;
  tracesPath: string;
  tlc: CheckedTlc;
};

/// Runs the scenarios and `randomTraces` random walks through `bin`, then has
/// TLC check them with `cfgText` (TraceAgentWait.cfg by default) under `cfgName`.
export async function codeToSpec(options: {
  bin: string;
  dir: string;
  graph: AgentGraph;
  seed: number;
  randomTraces: number;
  maxLength: number;
  faultRate: number;
  cfgName?: string;
  cfgText?: string;
}): Promise<AgentCodeToSpecResult> {
  const { graph, dir } = options;
  const random = seededRandom(options.seed);
  const traces: TraceRun[] = [];
  let steps = 0;
  let count = 0;

  const record = async (name: string, nextInput: (state: Vars, step: number) => Input | null) => {
    count += 1;
    const home = newHome(join(dir, "homes", String(count)));
    const harness = await Harness.start(options.bin, home, harnessEnv());
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
      for (let guard = 0; guard < 6; guard += 1) {
        const input = epilogue(state);
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
      return ev(EVENT_NAMES[Math.floor(random() * EVENT_NAMES.length)]!);
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
  const cfgName = options.cfgName ?? "TraceAgentWait.cfg";
  const baseCfg = readFileSync(join(MODEL_DIR, "TraceAgentWait.cfg"), "utf8");
  const files: Record<string, string> = {
    "AgentWait.tla": readFileSync(join(MODEL_DIR, "AgentWait.tla"), "utf8"),
    "TraceAgentWait.tla": readFileSync(join(MODEL_DIR, "TraceAgentWait.tla"), "utf8"),
    "TraceData.tla": data,
    [cfgName]: options.cfgText ?? baseCfg,
  };
  const tlc = await checkTlc(join(dir, "tlc"), "TraceAgentWait", cfgName, files);
  return { traces: traces.length, steps, scenarios: Object.keys(SCENARIOS).length, tracesPath, tlc };
}

/// A config that checks one property of the traces, as the planted-bug check needs.
export function aloneConfig(property: string): string {
  const base = readFileSync(join(MODEL_DIR, "TraceAgentWait.cfg"), "utf8");
  return singleConfig(property, "TraceSpec", configNames(base).invariants, base);
}
