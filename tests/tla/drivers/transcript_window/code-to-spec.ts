// Code to spec: runs event sequences through the harness around the real
// core, records each run as a trace, and has TLC check that every trace is a
// behavior of TranscriptWindow and keeps its laws (TraceTranscriptWindow.tla).
//
// Each trace starts in a new harness process. A crash kills the process with
// SIGKILL and starts a new one, which is sent `resumed` with what the log
// holds: the newest compaction start at or below the saved watermark. The
// random traces mix in lost, stale, duplicate and garbage log replies, saves
// past the end, and events the state does not allow; a rejected event must
// leave the core unchanged and is recorded as a repeat of the previous state.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Harness, canonical, checkTlc, codeView, configConstants, seededRandom, specFiles, toTla, type Act, type CheckedTlc, type Config, type Event, type Shown } from "./lib.ts";

type Record_ = Record<string, unknown>;
/// `crash` kills the process before the resume; `resume` restarts the window
/// in the same process, as a /resume does.
export type Step = { event: Event | { event: "crash" } | { event: "resume" } };

export type CodeToSpecResult = {
  traces: number;
  steps: number;
  rejected: number;
  crashes: number;
  tracesPath: string;
  tlc: CheckedTlc;
  problem: string | null;
};

export const SETS = new Set(["live", "cycleStarts", "painted"]);

/// The blocks a step's effects put on the screen, as the model's PaintedBy.
function paintedBy(out: Shown["out"]): number[] {
  const seqs: number[] = [];
  for (const effect of out) {
    if (effect.kind === "paint_final") seqs.push(effect.seq as number);
    if (effect.kind === "reprint_slice") for (let seq = effect.from as number; seq < (effect.to as number); seq += 1) seqs.push(seq);
  }
  return seqs;
}

export class Recorder {
  states: Record_[] = [];
  cycleStarts = [0];
  painted: number[] = [];
  rejected = 0;
  crashes = 0;
  problem: string | null = null;

  constructor(private readonly none: number, private readonly step: number) {}

  record(shown: Shown, act: Act) {
    const s = shown.state;
    const base = act.name === "Resized" || act.name === "Resumed" ? [] : this.painted;
    this.painted = [...new Set([...base, ...paintedBy(shown.out)])].sort((a, b) => a - b);
    this.states.push({
      cycle: s.cycle, cycleFirst: s.cycleFirst, prevFirst: s.prevFirst === -1 ? this.none : s.prevFirst,
      nextSeq: s.nextSeq, savedThrough: s.savedThrough, live: shown.live, turnOpen: s.turnOpen,
      paintedThrough: s.paintedThrough, reprinting: s.reprinting, coOpen: s.coOpen, coLo: s.coLo, coHi: s.coHi,
      coAtStart: s.coAtStart, pending: s.pending, pendingDir: s.pendingDir, nextToken: s.nextToken,
      out: shown.out, act, alive: true, cycleStarts: [...this.cycleStarts], painted: [...this.painted],
    });
  }

  repeat() {
    this.states.push({ ...this.states[this.states.length - 1]! });
  }

  crashed() {
    const last = this.states[this.states.length - 1]!;
    this.states.push({ ...last, alive: false, out: [], act: { name: "Crash" } });
    this.crashes += 1;
  }

  /// The model's act for an accepted event, with the arguments as the model
  /// sees them: a save clamped to what finished, a garbage count capped.
  actFor(event: Event, after: Shown): Act {
    switch (event.event) {
      case "turn_started": return { name: "TurnStarted" };
      case "turn_ended": return { name: "TurnEnded" };
      case "block_opened": return { name: "BlockOpened", id: event.id as number };
      case "block_changed": return { name: "BlockChanged", id: event.id as number };
      case "block_finished": return { name: "BlockFinished", id: event.id as number };
      case "saved_through": return { name: "SavedThrough", through: after.state.savedThrough };
      case "compacted": return { name: "Compacted" };
      case "resized": return { name: "Resized" };
      case "reprint_tick": return { name: "ReprintTick" };
      case "ctrlo_opened": return { name: "CtrlOOpened" };
      case "ctrlo_scrolled": return { name: event.dir === "older" ? "CtrlOScrolledOlder" : "CtrlOScrolledNewer" };
      case "ctrlo_closed": return { name: "CtrlOClosed" };
      case "log_read_done": return { name: "LogReadDone", token: event.token as number, count: Math.min(event.count as number, this.step + 1) };
      case "log_read_failed": return { name: "LogReadFailed", token: event.token as number };
      default: throw new Error(`no act for ${event.event}`);
    }
  }
}

/// Runs `steps` on a new harness process and records the trace.
export async function runTrace(bin: string, config: Config, steps: Step[], none: number): Promise<Recorder> {
  const recorder = new Recorder(none, config.read_step);
  let harness = await Harness.start(bin, config);
  recorder.record(harness.last, { name: "Init" });
  try {
    for (const { event } of steps) {
      const before = harness.last;
      if (event.event === "crash" || event.event === "resume") {
        if (event.event === "crash") {
          await harness.crash();
          recorder.crashed();
        }
        const saved = before.state.savedThrough;
        recorder.cycleStarts = recorder.cycleStarts.filter((start) => start <= saved);
        const last = Math.max(...recorder.cycleStarts);
        const shown = await harness.send({ event: "resumed", cycle: before.state.cycle, cycle_first: last, next_seq: saved });
        recorder.record(shown, { name: "Resumed" });
        continue;
      }
      const shown = await harness.send(event as Event);
      if (shown.rejected) {
        recorder.rejected += 1;
        const unchanged = canonical({ ...JSON.parse(codeView(shown)), out: [] }) === canonical({ ...JSON.parse(codeView(before)), out: [] });
        if (!unchanged || shown.out.length !== 0) {
          recorder.problem = `rejected ${JSON.stringify(event)} (${shown.rejected}) changed the core: ${codeView(before)} -> ${codeView(shown)}`;
          break;
        }
        recorder.repeat();
        continue;
      }
      if (event.event === "compacted" && !recorder.cycleStarts.includes(before.state.nextSeq)) recorder.cycleStarts.push(before.state.nextSeq);
      recorder.record(shown, recorder.actFor(event as Event, shown));
    }
  } finally {
    await harness.close();
  }
  return recorder;
}

/// A random event sequence. It tracks the core's state from the harness, so
/// it is generated step by step against a running process.
async function randomTrace(bin: string, config: Config, seed: number, length: number, none: number): Promise<{ name: string; recorder: Recorder }> {
  const random = seededRandom(seed);
  const pick = <T>(items: T[]): T => items[Math.floor(random() * items.length)]!;
  const steps: Step[] = [];
  // Generate against a shadow process, then replay on a fresh one for the record.
  const shadow = await Harness.start(bin, config);
  let lastToken = 0;
  let cycleStarts = [0];
  for (let i = 0; i < length; i += 1) {
    const s = shadow.last.state as Record_ & { nextSeq: number; savedThrough: number; pending: number; nextToken: number; cycle: number };
    const live = shadow.last.live;
    const free = [1, 2, 3, 4, 5, 6].filter((id) => !live.includes(id));
    const options: [number, () => Event | { event: "crash" }][] = [
      [s.turnOpen ? 0.3 : 3, () => ({ event: "turn_started" })],
      [s.turnOpen ? 2 : 0.3, () => ({ event: "turn_ended" })],
      [s.turnOpen && free.length ? 4 : 0.3, () => ({ event: "block_opened", id: free.length ? pick(free) : 1 })],
      [live.length ? 3 : 0.3, () => ({ event: "block_changed", id: live.length && random() < 0.9 ? pick(live) : pick([1, 2, 3, 4, 5, 6]) })],
      [live.length ? 4 : 0, () => ({ event: "block_finished", id: pick(live) })],
      [free.length ? 1.5 : 0, () => ({ event: "block_finished", id: pick(free) })],
      [config.saved ? 3 : 0.2, () => ({ event: "saved_through", seq: random() < 0.85 ? s.savedThrough + 1 + Math.floor(random() * Math.max(1, s.nextSeq - s.savedThrough)) : Math.floor(random() * (s.nextSeq + 3)) })],
      [0.6, () => ({ event: "compacted" })],
      [0.8, () => ({ event: "resized" })],
      [s.reprinting ? 5 : 0.2, () => ({ event: "reprint_tick" })],
      [s.coOpen ? 0.2 : 1.5, () => ({ event: "ctrlo_opened" })],
      [s.coOpen ? 3 : 0.2, () => ({ event: "ctrlo_scrolled", dir: "older" })],
      [s.coOpen ? 1.5 : 0.1, () => ({ event: "ctrlo_scrolled", dir: "newer" })],
      [s.coOpen ? 0.7 : 0.1, () => ({ event: "ctrlo_closed" })],
      [s.pending ? 4 : 0, () => ({ event: "log_read_done", token: s.pending, count: Math.floor(random() * 5) })],
      [lastToken ? 0.7 : 0, () => ({ event: "log_read_done", token: random() < 0.5 ? lastToken : lastToken + 1 + Math.floor(random() * 3), count: Math.floor(random() * 5) })],
      [s.pending ? 0.8 : 0.2, () => ({ event: "log_read_failed", token: s.pending || lastToken || 1 })],
      [config.saved ? 0.3 : 0, () => ({ event: "crash" })],
      [config.saved ? 0.15 : 0, () => ({ event: "resume" })],
    ];
    const total = options.reduce((sum, [weight]) => sum + weight, 0);
    let roll = random() * total;
    let chosen = options[options.length - 1]![1];
    for (const [weight, make] of options) {
      roll -= weight;
      if (roll < 0) { chosen = make; break; }
    }
    const event = chosen();
    steps.push({ event });
    if (event.event === "crash" || event.event === "resume") {
      const saved = s.savedThrough;
      cycleStarts = cycleStarts.filter((start) => start <= saved);
      if (event.event === "crash") await shadow.crash();
      await shadow.send({ event: "resumed", cycle: s.cycle, cycle_first: Math.max(...cycleStarts), next_seq: saved });
      lastToken = 0;
      continue;
    }
    if (event.event === "compacted" && !cycleStarts.includes(s.nextSeq)) cycleStarts.push(s.nextSeq);
    const shown = await shadow.send(event as Event);
    const issued = shown.out.find((effect) => effect.kind === "read_log");
    if (issued) lastToken = issued.token as number;
  }
  await shadow.close();
  return { name: `random seed ${seed}`, recorder: await runTrace(bin, config, steps, none) };
}

const E = (event: string, extra: Record_ = {}): Step => ({ event: { event, ...extra } });

/// Hand-written edge cases that random runs reach only rarely.
export function scriptedTraces(saved: boolean): { name: string; steps: Step[] }[] {
  const ticks = (n: number) => Array.from({ length: n }, () => E("reprint_tick"));
  const scripted = [
    {
      name: "a compaction mid-turn keeps the live tool line and drops the old cycle at turn end",
      steps: [
        E("turn_started"), E("block_opened", { id: 1 }), E("block_finished", { id: 2 }), E("block_finished", { id: 3 }),
        E("saved_through", { seq: 2 }), E("compacted"), E("block_changed", { id: 1 }), E("turn_ended"),
        E("block_finished", { id: 1 }), E("saved_through", { seq: 3 }), E("turn_ended"), E("resized"), ...ticks(4),
      ],
    },
    {
      name: "a resize during a reprint starts over, and a block finished mid-reprint is painted once",
      steps: [
        E("turn_started"), E("block_finished", { id: 1 }), E("block_finished", { id: 2 }), E("block_finished", { id: 3 }),
        E("resized"), E("reprint_tick"), E("block_finished", { id: 4 }), E("resized"), ...ticks(5),
      ],
    },
    {
      name: "Ctrl+O scrolls back through two dropped cycles to the start of the log",
      steps: [
        E("block_finished", { id: 1 }), E("block_finished", { id: 2 }), E("saved_through", { seq: 2 }), E("compacted"),
        E("block_finished", { id: 3 }), E("block_finished", { id: 4 }), E("saved_through", { seq: 4 }), E("compacted"),
        E("block_finished", { id: 5 }), E("ctrlo_opened"),
        ...Array.from({ length: 4 }, (_, i) => [E("ctrlo_scrolled", { dir: "older" }), E("log_read_done", { token: i + 1, count: 2 })]).flat(),
        E("ctrlo_scrolled", { dir: "older" }), E("ctrlo_scrolled", { dir: "newer" }), E("log_read_done", { token: 5, count: 9 }),
      ],
    },
    {
      name: "duplicate, stale, reordered and lost replies, then a close with a read in flight",
      steps: [
        E("block_finished", { id: 1 }), E("block_finished", { id: 2 }), E("block_finished", { id: 3 }), E("saved_through", { seq: 3 }),
        E("compacted"), E("block_finished", { id: 4 }), E("ctrlo_opened"), E("ctrlo_scrolled", { dir: "older" }),
        E("log_read_done", { token: 7, count: 1 }), E("log_read_failed", { token: 1 }), E("log_read_done", { token: 1, count: 1 }),
        E("ctrlo_scrolled", { dir: "older" }), E("log_read_done", { token: 2, count: 1 }), E("log_read_done", { token: 2, count: 1 }),
        E("ctrlo_scrolled", { dir: "older" }), E("ctrlo_closed"), E("log_read_done", { token: 3, count: 1 }), E("ctrlo_opened"),
      ],
    },
    {
      name: "a crash during a reprint and with a read in flight recovers the last cycle from the log",
      steps: [
        E("turn_started"), E("block_finished", { id: 1 }), E("block_finished", { id: 2 }), E("saved_through", { seq: 2 }),
        E("compacted"), E("block_finished", { id: 3 }), E("block_finished", { id: 4 }), E("saved_through", { seq: 3 }),
        E("resized"), E("reprint_tick"), E("ctrlo_opened"), E("ctrlo_scrolled", { dir: "older" }), E("ctrlo_scrolled", { dir: "older" }),
        E("crash"), ...ticks(3), E("log_read_done", { token: 1, count: 1 }), E("ctrlo_opened"),
      ],
    },
    {
      name: "a resume in the same process drops Ctrl+O, the live blocks, and the unsaved tail",
      steps: [
        E("turn_started"), E("block_opened", { id: 1 }), E("block_finished", { id: 2 }), E("block_finished", { id: 3 }),
        E("saved_through", { seq: 1 }), E("ctrlo_opened"), E("ctrlo_scrolled", { dir: "older" }), E("resume"),
        E("reprint_tick"), E("reprint_tick"), E("block_changed", { id: 1 }), E("log_read_done", { token: 1, count: 1 }),
      ],
    },
    {
      name: "the --no-save shape: Ctrl+O is open while the previous cycle drops",
      steps: [
        E("turn_started"), E("block_finished", { id: 1 }), E("ctrlo_opened"), E("block_finished", { id: 2 }), E("turn_ended"),
        E("compacted"), E("block_finished", { id: 3 }), E("ctrlo_scrolled", { dir: "newer" }), E("ctrlo_scrolled", { dir: "older" }),
        E("saved_through", { seq: 99 }),
      ],
    },
  ];
  return saved
    ? scripted.filter((trace) => !trace.name.startsWith("the --no-save"))
    : scripted.filter((trace) => !trace.steps.some((step) => step.event.event === "crash" || step.event.event === "resume"));
}

export async function codeToSpec(options: {
  bin: string;
  saved: boolean;
  dir: string;
  randomTraces: number;
  length: number;
  seed: number;
  cfgText?: string;
}): Promise<CodeToSpecResult> {
  mkdirSync(options.dir, { recursive: true });
  const files = specFiles();
  const cfgText = (options.cfgText ?? files["TraceTranscriptWindow.cfg"]!).replace(/Saved = (TRUE|FALSE)/, `Saved = ${options.saved ? "TRUE" : "FALSE"}`);
  const constants = configConstants(cfgText);
  const config: Config = { window: Number(constants.Window), read_step: Number(constants.Step), slice: Number(constants.Slice), saved: options.saved };
  const none = Number(constants.MaxSeq) + 1;
  const runs: { name: string; recorder: Recorder }[] = [];
  for (const scripted of scriptedTraces(options.saved)) runs.push({ name: scripted.name, recorder: await runTrace(options.bin, config, scripted.steps, none) });
  for (let i = 0; i < options.randomTraces; i += 1) runs.push(await randomTrace(options.bin, config, options.seed + i, options.length, none));
  const problem = runs.find((run) => run.recorder.problem)?.recorder.problem ?? null;
  const tracesPath = join(options.dir, "traces.json");
  writeFileSync(tracesPath, `${JSON.stringify(runs.map((run) => ({ name: run.name, states: run.recorder.states })), null, 1)}\n`);
  const data = [
    "---- MODULE TraceData ----",
    "EXTENDS Integers",
    "Traces == <<",
    runs.map((run) => `  \\* ${run.name}\n  <<${run.recorder.states.map((state) => toTla(state, SETS)).join(",\n   ")}>>`).join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
  const tlc = await checkTlc(join(options.dir, "tlc"), "TraceTranscriptWindow", "TraceTranscriptWindow.cfg", {
    ...files,
    "TraceTranscriptWindow.cfg": cfgText,
    "TraceData.tla": data,
  });
  return {
    traces: runs.length,
    steps: runs.reduce((sum, run) => sum + run.recorder.states.length - 1, 0),
    rejected: runs.reduce((sum, run) => sum + run.recorder.rejected, 0),
    crashes: runs.reduce((sum, run) => sum + run.recorder.crashes, 0),
    tracesPath,
    tlc,
    problem,
  };
}
