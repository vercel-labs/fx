// Code to spec for `fx tool ask`: runs event sequences through the real
// ask-harness, records each run as the states the code showed, and has TLC
// check every run against AskWait (TraceAskWait.tla). When a planted bug such
// as `admission-lock-only` trips `worker_runtime.zig`'s slot assert, the
// harness process aborts; this recorder captures that abort as `crashed = TRUE`
// so `NoCrash` and `OneShown` catch it in TLC.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { checkTlc, configNames, seededRandom, singleConfig, toTla, type CheckedTlc } from "../mcp_call/lib.ts";
import {
  AskHarness,
  EVENT_NAMES,
  HarnessCrashError,
  MODEL_DIR,
  harnessEnv,
  shapeOf,
  type AskGraph,
  type Input,
  type Vars,
} from "./ask-lib.ts";

const plain = (event: string): Input => ({ event });
const req = (event: string, i: number): Input => ({ event, i });

const NEEDS_REQUEST = new Set(["send", "show", "give_up", "answer", "esc", "withdraw"]);

export const SCENARIOS: { name: string; ui: boolean; inputs: Input[] }[] = [
  {
    name: "an answered question reaches the client and the program ends",
    ui: true,
    inputs: [plain("run"), req("send", 1), req("answer", 1), plain("gone"), plain("return")],
  },
  {
    name: "a killed program's open question is withdrawn by the watch and the call returns",
    ui: true,
    inputs: [plain("run"), req("send", 1), plain("gone"), req("withdraw", 1), plain("return")],
  },
  {
    name: "two asks queue on the prompt lock, and the second shows after the first is answered",
    ui: true,
    inputs: [plain("run"), req("send", 1), req("send", 2), req("answer", 1), req("show", 2), req("answer", 2), plain("gone"), plain("return")],
  },
  {
    name: "a queued ask gives up when its program is gone and the first question is withdrawn",
    ui: true,
    inputs: [plain("run"), req("send", 1), req("send", 2), plain("gone"), req("withdraw", 1), req("give_up", 2), plain("return")],
  },
  {
    name: "a queued ask gives up after the first question is answered and the program ends",
    ui: true,
    inputs: [plain("run"), req("send", 1), req("send", 2), req("answer", 1), plain("gone"), req("give_up", 2), plain("return")],
  },
  {
    name: "Esc on an open question cancels the program and ends the call",
    ui: true,
    inputs: [plain("run"), req("send", 1), req("esc", 1), plain("return")],
  },
  {
    name: "Esc on a question with a queued second ask lets the second ask give up",
    ui: true,
    inputs: [plain("run"), req("send", 1), req("send", 2), req("esc", 1), req("give_up", 2), plain("return")],
  },
  {
    name: "a host without question UI refuses at once",
    ui: false,
    inputs: [plain("run"), req("send", 1), plain("gone"), plain("return")],
  },
  {
    name: "an ask after the first bash call yielded is refused",
    ui: true,
    inputs: [plain("run"), plain("yield"), req("send", 1), plain("gone"), plain("return")],
  },
  {
    name: "a yield does not land while a question holds the first call, and lands after it ends",
    ui: true,
    inputs: [plain("run"), req("send", 1), plain("yield"), req("answer", 1), plain("yield"), plain("gone"), plain("return")],
  },
  {
    name: "a second program starts after the first returns",
    ui: true,
    inputs: [plain("run"), req("send", 1), req("answer", 1), plain("gone"), plain("return"), plain("run"), req("send", 1), plain("gone"), req("withdraw", 1), plain("return")],
  },
  {
    name: "an answer after the program is gone ends the question so the call returns",
    ui: true,
    inputs: [plain("run"), req("send", 1), plain("gone"), req("answer", 1), plain("return")],
  },
  {
    name: "Esc after the program is gone ends the question",
    ui: true,
    inputs: [plain("run"), req("send", 1), plain("gone"), req("esc", 1), plain("return")],
  },
];

function faultInput(random: () => number): Input {
  const event = EVENT_NAMES[Math.floor(random() * EVENT_NAMES.length)]!;
  return NEEDS_REQUEST.has(event) ? { event, i: random() < 0.5 ? 1 : 2 } : { event };
}

export function epilogue(state: Vars): Input | null {
  if (state.crashed) return null;
  if (state.prog === "running") return plain("gone");
  const shown = [1, 2].find((r) => state.req[r - 1] === "shown");
  if (shown !== undefined) return req("withdraw", shown);
  const queued = [1, 2].find((r) => state.req[r - 1] === "queued");
  if (queued !== undefined && state.lock === 0) return req("give_up", queued);
  if (state.prog === "gone" && (state.bash === "first" || state.bash === "yielded")) return plain("return");
  return null;
}

function crashedStateAfter(prev: Vars, input: Input): Vars {
  const nextReq = [...(prev.req as string[])];
  if (input.i && (input.event === "send" || input.event === "show")) {
    nextReq[input.i - 1] = "shown";
  }
  return {
    ...prev,
    req: nextReq,
    crashed: true,
    asked: Number(prev.asked) + 1,
  };
}

export type TraceRun = { name: string; states: Vars[] };
export type AskCodeToSpecResult = {
  traces: number;
  steps: number;
  scenarios: number;
  tracesPath: string;
  tlc: CheckedTlc;
};

export async function codeToSpec(options: {
  bin: string;
  dir: string;
  graph: AskGraph;
  seed: number;
  randomTraces: number;
  maxLength: number;
  faultRate: number;
  cfgName?: string;
  cfgText?: string;
}): Promise<AskCodeToSpecResult> {
  const { graph, dir } = options;
  const random = seededRandom(options.seed);
  const traces: TraceRun[] = [];
  let steps = 0;
  let count = 0;

  const record = async (name: string, ui: boolean, nextInput: (state: Vars, step: number) => Input | null) => {
    count += 1;
    const home = join(dir, "homes", String(count));
    const harness = await AskHarness.start(options.bin, home, ui, harnessEnv());
    const states: Vars[] = [harness.first.state];
    let state = harness.first.state;
    let aborted = false;
    try {
      for (let step = 0; ; step += 1) {
        const input = nextInput(state, step);
        if (!input) break;
        try {
          const reply = await harness.send(input);
          steps += 1;
          states.push(reply.state);
          state = reply.state;
        } catch (error) {
          if (error instanceof HarnessCrashError) {
            steps += 1;
            state = crashedStateAfter(state, input);
            states.push(state);
            aborted = true;
            break;
          }
          throw error;
        }
      }
      if (!aborted) {
        let prevKey = shapeOf(state);
        for (let guard = 0; guard < 8; guard += 1) {
          const input = epilogue(state);
          if (!input) break;
          try {
            const reply = await harness.send(input);
            steps += 1;
            states.push(reply.state);
            state = reply.state;
            const nextKey = shapeOf(state);
            if (nextKey === prevKey) break;
            prevKey = nextKey;
          } catch (error) {
            if (error instanceof HarnessCrashError) {
              steps += 1;
              state = crashedStateAfter(state, input);
              states.push(state);
              break;
            }
            throw error;
          }
        }
      }
    } finally {
      await harness.close();
    }
    traces.push({ name, states });
  };

  for (const scenario of SCENARIOS) {
    await record(scenario.name, scenario.ui, (_state, step) => scenario.inputs[step] ?? null);
  }
  for (let n = 0; n < options.randomTraces; n += 1) {
    const ui = random() < 0.75;
    const length = 2 + Math.floor(random() * (options.maxLength - 1));
    await record(`random ${n + 1} (seed ${options.seed}, ui=${ui})`, ui, (state, step) => {
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
  const cfgName = options.cfgName ?? "TraceAskWait.cfg";
  const baseCfg = readFileSync(join(MODEL_DIR, "TraceAskWait.cfg"), "utf8");
  const files: Record<string, string> = {
    "AskWait.tla": readFileSync(join(MODEL_DIR, "AskWait.tla"), "utf8"),
    "TraceAskWait.tla": readFileSync(join(MODEL_DIR, "TraceAskWait.tla"), "utf8"),
    "TraceData.tla": data,
    [cfgName]: options.cfgText ?? baseCfg,
  };
  const tlc = await checkTlc(join(dir, "tlc"), "TraceAskWait", cfgName, files);
  return { traces: traces.length, steps, scenarios: SCENARIOS.length, tracesPath, tlc };
}

export function aloneConfig(property: string): string {
  const base = readFileSync(join(MODEL_DIR, "TraceAskWait.cfg"), "utf8");
  return singleConfig(property, "TraceSpec", configNames(base).invariants, base);
}
