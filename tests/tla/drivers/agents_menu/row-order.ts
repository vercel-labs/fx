// Code to spec: runs the built fx and has TLC check that a subagent's row and
// its place in the agent list change together, against tests/tla/agents_menu/
// spec/TraceRowOrder.tla (the rules of RowOrder.tla, read from the frames fx
// draws).
//
// Each run starts one fx with held subagents under the first instance, opens
// the agent list, and lets the subagents finish one at a time in a seeded
// order. While one finishes it reads the list as fast as tmux answers and
// keeps every frame that differs from the one before: each subagent row's
// state, the order of the rows, and the order the driver let them finish in.
// A subagent that shows idle must already be placed by its newest reply, and
// no row moves in a frame that changes no row's state.
//
// Usage:
//   bun tests/tla/drivers/agents_menu/row-order.ts [--seed 1] [--runs 3] [--subs alpha,beta,gamma]
//       [--watch-ms 2500] [--quiet-ms 600]
//
// FX_BIN picks the binary. The seed of every run is printed; `--seed S --runs 1`
// replays one. TLC's log, TraceRowData.tla, and each run's frame log stay in
// the printed folder.
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts } from "../lib/context";
import { TLA_ROOT, runTlc } from "../lib/tlc";
import { LIST_HINT, World, listStates, seeded } from "./lib";

function option(name: string, fallback: string): string {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 && process.argv[at + 1] ? process.argv[at + 1]! : fallback;
}

const baseSeed = Number(option("seed", "1"));
const runs = Number(option("runs", "3"));
const subs = option("subs", "alpha,beta,gamma").split(",").filter(Boolean);
const watchMs = Number(option("watch-ms", "2500"));
const quietMs = Number(option("quiet-ms", "600"));
const specDir = join(TLA_ROOT, "agents_menu", "spec");

type Frame = { shown: Record<string, "working" | "idle">; order: string[]; rank: Record<string, number> };

function shuffled<T>(items: T[], random: () => number): T[] {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i -= 1) {
    const j = Math.floor(random() * (i + 1));
    [out[i], out[j]] = [out[j]!, out[i]!];
  }
  return out;
}

/// The subagent rows of the open list as a frame, or null while it is not open.
function frameOf(escapes: string, rank: Record<string, number>): Frame | null {
  const plain = escapes.replace(/\x1b\[[0-9;]*m/g, "");
  if (!plain.includes(LIST_HINT)) return null;
  const rows = listStates(escapes).filter((row) => !row.instance);
  if (rows.length !== subs.length) return null;
  return {
    shown: Object.fromEntries(rows.map((row) => [row.name, row.state])),
    order: rows.map((row) => row.name),
    rank: { ...rank },
  };
}

const sameFrame = (a: Frame, b: Frame) =>
  JSON.stringify([a.shown, a.order, a.rank]) === JSON.stringify([b.shown, b.order, b.rank]);

function traceModule(traces: Frame[][]): string {
  const str = (value: string) => JSON.stringify(value);
  const fn = (record: Record<string, string | number>) =>
    `(${subs.map((sub) => `${str(sub)} :> ${typeof record[sub] === "number" ? record[sub] : str(record[sub] as string)}`).join(" @@ ")})`;
  const frame = (f: Frame) =>
    `[shown |-> ${fn(f.shown)}, order |-> <<${f.order.map(str).join(", ")}>>, rank |-> ${fn(f.rank)}]`;
  return [
    "---- MODULE TraceRowData ----",
    "\\* Written by tests/tla/drivers/agents_menu/row-order.ts.",
    "EXTENDS Sequences, TLC",
    `TraceSubs == {${subs.map(str).join(", ")}}`,
    "RowTraces == <<",
    traces.map((trace) => `  <<\n${trace.map((f) => `    ${frame(f)}`).join(",\n")}\n  >>`).join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
}

console.log(`output: ${artifacts}`);
const traces: Frame[][] = [];
for (let run = 1; run <= runs; run += 1) {
  const seed = baseSeed + run - 1;
  const random = seeded(seed);
  const world = new World({ instances: 1, subs, label: `row-order-${run}-seed-${seed}` }, artifacts);
  const frames: Frame[] = [];
  const rank: Record<string, number> = Object.fromEntries(subs.map((sub) => [sub, 0]));
  const keep = (frame: Frame | null) => {
    if (frame && (frames.length === 0 || !sameFrame(frames.at(-1)!, frame))) {
      frames.push(frame);
      world.note(JSON.stringify(frame));
    }
    return frame;
  };
  console.log(`run ${run}: seed ${seed}, subagents ${subs.join(", ")}`);
  try {
    await world.start();
    await world.keys("C-x");
    const opened = Date.now() + 10_000;
    while (!keep(frameOf(await world.captureEscapes(), rank))) {
      if (Date.now() > opened) throw new Error("the agent list never opened with every subagent row");
      await Bun.sleep(20);
    }
    let finished = 0;
    for (const sub of shuffled(subs, random)) {
      finished += 1;
      rank[sub] = finished;
      world.note(`release ${sub} as reply ${finished}`);
      world.release(sub);
      const began = performance.now();
      let idleSince: number | null = null;
      for (;;) {
        const frame = keep(frameOf(await world.captureEscapes(), rank));
        const now = performance.now();
        if (frame?.shown[sub] === "idle") idleSince ??= now;
        else idleSince = null;
        if (idleSince !== null && now - idleSince >= quietMs) break;
        if (now - began > watchMs + quietMs) throw new Error(`${sub} never showed idle in ${watchMs} ms`);
        await Bun.sleep(5);
      }
    }
    traces.push(frames);
    console.log(`  ${frames.length} frames recorded (${world.log})`);
  } catch (error) {
    traces.push(frames);
    console.error(`FAIL run ${run} (seed ${seed}): ${(error as Error).message}`);
    console.error(`  frame log: ${world.log}`);
    process.exitCode = 1;
  } finally {
    await world.stop();
  }
}

const dir = join(artifacts, "tlc");
mkdirSync(dir, { recursive: true });
const kept = traces.filter((trace) => trace.length > 0);
if (kept.length === 0) {
  console.error("FAIL no run recorded a frame");
  process.exit(1);
}
writeFileSync(join(dir, "TraceRowData.tla"), traceModule(kept));
const result = await runTlc(dir, "TraceRowOrder", "TraceRowOrder.cfg", ["TraceRowOrder.tla", "TraceRowOrder.cfg"], specDir);
const recorded = kept.reduce((sum, trace) => sum + trace.length, 0);
if (result.exitCode !== 0) {
  console.error(`FAIL TLC rejected a run of the binary: ${result.violated ?? `exit ${result.exitCode}`}`);
  const trace = /Error: .*\n[\s\S]*?(?=\n\n\d+ states generated|$)/.exec(result.output)?.[0] ?? result.output.slice(-3000);
  console.error(trace.split("\n").slice(0, 60).join("\n"));
  console.error(`TLC log: ${join(dir, "tlc.log")}`);
  process.exitCode = 1;
} else {
  console.log(`TLC: ${kept.length} runs, ${recorded} frames of the binary keep each row's state and place together (${result.distinctStates} distinct states, ${result.durationMs} ms)`);
}
appendFileSync(join(artifacts, "summary.txt"), `${result.exitCode === 0 ? "pass" : "fail"} ${kept.length} runs ${recorded} frames\n`);
