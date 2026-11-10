// Code to spec: runs the built fx through the agent list with seeded random
// steps and has TLC check every run against tests/tla/agents_menu/spec/
// AgentsMenu.tla (TraceAgentsMenu.tla).
//
// Each run starts one fx with --instances N and, under the first instance,
// subagents whose turns the fake gateway holds. Then it takes `--steps` steps,
// each one the person or the environment could take from where the list
// stands: open the list (Ctrl+X or Down), Up, Down, Enter, Esc or Ctrl+X, the
// first Delete on a row that can close, the second Delete, and, with the list
// open, one held subagent finishing its turn, which can reorder the rows
// under the highlight. After each step it reads the model's variables from
// the binary (lib.ts `observe`) and records the state.
//
// Usage:
//   bun tests/tla/drivers/agents_menu/binary-to-spec.ts [--seed 1] [--runs 3] [--steps 60]
//       [--instances 3] [--subs alpha,beta,gamma]
//
// The seed of every run is printed; `--seed S --runs 1` replays one. TLC's
// log, TraceData.tla, and each run's step log stay in the printed folder.
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts } from "../lib/context";
import { TLA_ROOT, runTlc } from "../lib/tlc";
import { NONE, type State, World, perform, seeded, traceModule } from "./lib";

function option(name: string, fallback: string): string {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 && process.argv[at + 1] ? process.argv[at + 1]! : fallback;
}

const baseSeed = Number(option("seed", "1"));
const runs = Number(option("runs", "3"));
const steps = Number(option("steps", "60"));
const instances = Number(option("instances", "3"));
const subs = option("subs", "alpha,beta,gamma").split(",").filter(Boolean);
const specDir = join(TLA_ROOT, "agents_menu", "spec");

function pick<T>(random: () => number, weighted: Array<[T, number]>): T {
  const total = weighted.reduce((sum, [, weight]) => sum + weight, 0);
  let at = random() * total;
  for (const [item, weight] of weighted) {
    at -= weight;
    if (at < 0) return item;
  }
  return weighted.at(-1)![0];
}

function closable(world: World, agent: string): boolean {
  return !world.instances.includes(agent) || world.alive.length > 1;
}

console.log(`output: ${artifacts}`);
const traces: State[][] = [];
let template: World | null = null;
for (let run = 1; run <= runs; run += 1) {
  const seed = baseSeed + run - 1;
  const random = seeded(seed);
  const world = new World({ instances, subs, label: `run-${run}-seed-${seed}` }, artifacts);
  template ??= world;
  console.log(`run ${run}: seed ${seed}, ${instances} instances, subagents ${subs.join(", ") || "none"}`);
  try {
    await world.start();
    const order = await world.calibrate();
    world.note(`initial order ${JSON.stringify(order)}`);
    for (let step = 1; step <= steps; step += 1) {
      const state = world.state;
      if (!state.open) {
        if (state.order.length < 2) break;
        world.record(await perform(world, "open", random));
        continue;
      }
      const releasable = [...world.working].filter((sub) => state.order.includes(sub));
      const choices: Array<[string, number]> = [["down", 30], ["up", 20], ["enter", 10], ["back", 8]];
      if (closable(world, state.sel) && state.armed !== state.sel) choices.push(["arm", 8]);
      if (state.armed !== NONE && state.armed === state.sel) choices.push(["delete", 14]);
      if (releasable.length > 0) choices.push(["release", 10]);
      const act = pick(random, choices);
      if (act === "release") {
        const sub = releasable[Math.floor(random() * releasable.length)]!;
        world.mark();
        world.release(sub);
        await world.waitIdle(sub);
        await world.settle([], 1_500);
        const next = await world.observe("env_reorder");
        world.note(`released ${sub}`);
        // A finish that leaves the rows as they were is no step of the list.
        if (JSON.stringify(next.order) === JSON.stringify(state.order)) {
          world.state = { ...next, act: state.act };
          continue;
        }
        world.record(next);
        continue;
      }
      world.record(await perform(world, act, random));
    }
    traces.push(world.steps);
    console.log(`  ${world.steps.length - 1} steps recorded (${world.log})`);
  } catch (error) {
    traces.push(world.steps);
    console.error(`FAIL run ${run} (seed ${seed}): ${(error as Error).message}`);
    console.error(`  step log: ${world.log}`);
    process.exitCode = 1;
  } finally {
    await world.stop();
  }
}

const dir = join(artifacts, "tlc");
const { mkdirSync } = await import("node:fs");
mkdirSync(dir, { recursive: true });
const kept = traces.filter((trace) => trace.length > 0);
if (kept.length === 0) {
  console.error("FAIL no run recorded a state");
  process.exit(1);
}
writeFileSync(join(dir, "TraceData.tla"), traceModule(template!, kept));
const result = await runTlc(dir, "TraceAgentsMenu", "TraceAgentsMenu.cfg", ["AgentsMenu.tla", "TraceAgentsMenu.tla", "TraceAgentsMenu.cfg"], specDir);
const recorded = traces.reduce((sum, trace) => sum + Math.max(0, trace.length - 1), 0);
if (result.exitCode !== 0) {
  console.error(`FAIL TLC rejected a run of the binary: ${result.violated ?? `exit ${result.exitCode}`}`);
  const trace = /Error: .*\n[\s\S]*?(?=\n\n\d+ states generated|$)/.exec(result.output)?.[0] ?? result.output.slice(-3000);
  console.error(trace.split("\n").slice(0, 60).join("\n"));
  console.error(`TLC log: ${join(dir, "tlc.log")}`);
  process.exitCode = 1;
} else {
  console.log(`TLC: ${traces.length} runs, ${recorded} steps of the binary are behaviors of AgentsMenu (${result.distinctStates} distinct states, ${result.durationMs} ms)`);
}
