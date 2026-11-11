// Spec to code: walks the built fx along the state graph TLC writes for
// tests/tla/agents_menu/spec/agents-menu-drive.cfg (two instances, and the
// first's subagents alpha and beta, with only the person's steps), and after
// every step requires the binary to show a state the model reaches by that
// step.
//
// Each walk starts a fresh fx (lib.ts World) and takes up to `--steps` steps.
// Each step is one the model allows from where the walk stands, chosen at
// random among the steps that cross an edge no walk has crossed yet, when
// there are any. The binary's state comes from lib.ts `observe`: the list's
// rows and highlight from the pane, an armed close from the hint row, and the
// agent on screen from the trace log. A step the binary takes to a state the
// model does not reach prints the walk and fails.
//
// Usage:
//   bun tests/tla/drivers/agents_menu/spec-to-binary.ts [--seed 1] [--walks 3] [--steps 40]
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts } from "../lib/context";
import { TLA_ROOT, runTlc } from "../lib/tlc";
// @ts-ignore graph.mjs has no types.
import { parseValue } from "../graph.mjs";
import { type State, World, perform, seeded } from "./lib";

function option(name: string, fallback: string): string {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 && process.argv[at + 1] ? process.argv[at + 1]! : fallback;
}

const seed = Number(option("seed", "1"));
const walks = Number(option("walks", "3"));
const maxSteps = Number(option("steps", "40"));
const specDir = join(TLA_ROOT, "agents_menu", "spec");
const random = seeded(seed);

type Graph = { states: Map<string, State>; next: Map<string, Set<string>>; init: string };

function loadDot(path: string): Graph {
  const states = new Map<string, State>();
  const next = new Map<string, Set<string>>();
  let init = "";
  const unescape = (label: string) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      if (!next.has(edge[1]!)) next.set(edge[1]!, new Set());
      next.get(edge[1]!)!.add(edge[2]!);
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"/.exec(line);
    if (!node) continue;
    const state: Record<string, unknown> = {};
    for (const entry of unescape(node[2]!).split(/\n(?=\/\\ )/)) {
      const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
      if (match) state[match[1]!] = parseValue(match[2]!.trim());
    }
    states.set(node[1]!, state as State);
    if (state.act === "init") init = node[1]!;
  }
  if (!init) throw new Error(`${path} has no initial state`);
  return { states, next, init };
}

const view = (s: State) => JSON.stringify({ order: s.order, onScreen: s.onScreen, open: s.open, sel: s.sel, armed: s.armed });

console.log(`output: ${artifacts}`);
const dir = join(artifacts, "graph");
const tlc = await runTlc(dir, "MCAgentsMenu", "agents-menu-drive.cfg", ["AgentsMenu.tla", "MCAgentsMenu.tla", "agents-menu-drive.cfg"], specDir, ["-dump", "dot,actionlabels", join(dir, "graph")]);
if (tlc.exitCode !== 0) {
  console.error(`FAIL TLC could not write the drive graph (exit ${tlc.exitCode}); log ${join(dir, "tlc.log")}`);
  process.exit(1);
}
const graph = loadDot(join(dir, "graph.dot"));
const successors = (id: string) => [...(graph.next.get(id) ?? [])].filter((to) => to !== id);
const totalEdges = [...graph.next.entries()].reduce((sum, [from, to]) => sum + [...to].filter((id) => id !== from).length, 0);
console.log(`graph: ${graph.states.size} states, ${totalEdges} edges`);

const covered = new Set<string>();
let steps = 0;
for (let walk = 1; walk <= walks && !process.exitCode; walk += 1) {
  const world = new World({ instances: 2, subs: ["alpha", "beta"], label: `walk-${walk}` }, artifacts);
  const path: string[] = [];
  try {
    await world.start();
    await world.calibrate();
    if (view(world.state) !== view(graph.states.get(graph.init)!)) {
      throw new Error(`the binary starts at ${view(world.state)}, the model at ${view(graph.states.get(graph.init)!)}`);
    }
    let current = new Set([graph.init]);
    for (let step = 1; step <= maxSteps; step += 1) {
      const options = new Map<string, boolean>();
      for (const from of current) {
        for (const to of successors(from)) {
          const act = graph.states.get(to)!.act;
          options.set(act, (options.get(act) ?? false) || !covered.has(`${from}>${to}`));
        }
      }
      if (options.size === 0) break;
      const fresh = [...options].filter(([, isFresh]) => isFresh).map(([act]) => act);
      const pool = fresh.length > 0 ? fresh : [...options.keys()];
      const act = pool[Math.floor(random() * pool.length)]!;
      path.push(act);
      const shown = await perform(world, act, random);
      world.record(shown);
      steps += 1;
      const seen = view(shown);
      const reached = new Set<string>();
      const allowed = new Set<string>();
      for (const from of current) {
        for (const to of successors(from).filter((id) => graph.states.get(id)!.act === act)) {
          allowed.add(view(graph.states.get(to)!));
          if (view(graph.states.get(to)!) !== seen) continue;
          reached.add(to);
          covered.add(`${from}>${to}`);
        }
      }
      if (reached.size === 0) {
        console.error(`FAIL walk ${walk} after ${path.join(" ")}`);
        console.error(`  the binary shows ${seen}`);
        for (const item of allowed) console.error(`  the model allows ${item}`);
        console.error(`  step log: ${world.log}`);
        process.exitCode = 1;
        break;
      }
      current = reached;
    }
    if (!process.exitCode) console.log(`walk ${walk}: ${path.length} steps: ${path.join(" ")}`);
  } catch (error) {
    console.error(`FAIL walk ${walk} after ${path.join(" ")}: ${(error as Error).message}`);
    console.error(`  step log: ${world.log}`);
    process.exitCode = 1;
  } finally {
    await world.stop();
  }
}
console.log(`${steps} steps, ${covered.size} of ${totalEdges} edges covered`);
