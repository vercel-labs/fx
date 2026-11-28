// Spec to code: replays every transition of McpCall's TLC state graph
// against the real core through the harness, and after every step checks that
// what the core shows (abstract(state) and the step's effects) equals the
// model's state.
//
// A graph state is the core's variables plus `out` and `act`, the effects and
// event of the step that reached it. No action reads `out` or `act`, so a
// state's successors depend only on its core variables, and two graph edges
// with the same source core and the same event are the same transition. The
// sweep checks that claim on the graph (every such pair must lead to one
// target) and then takes each distinct transition once: complete coverage of
// the model's transition relation, in far fewer steps than its raw edges.
//
// The walk starts a fresh harness, takes an untaken transition from where it
// stands when there is one, and otherwise takes the cheapest route to the
// nearest core state with an untaken transition. A Crash transition kills the
// harness process and starts a new one, which costs about as much as 200
// steps, so routes avoid Crash unless it saves more, and each core state
// takes its own Crash last. Every transition is
// taken, so coverage is complete or the run fails.
import { createReadStream, existsSync } from "node:fs";
import { createInterface } from "node:readline";
import { parseValue } from "../graph.mjs";
import { Harness, canonical, coreOf, eventFor, shownOf, type Act } from "./lib.ts";

type Transition = { index: number; key: string; from: string; to: string; act: Act; expected: string };
type Plan = {
  states: number;
  edges: number;
  zero: string;
  initShown: string;
  transitions: Transition[];
  outgoing: Map<string, Transition[]>;
  conflict: null | { act: Act; first: string; second: string };
  /// Core states by number, and for each pair the distance and the first
  /// transition of a shortest path that takes no Crash, from one BFS per
  /// core state.
  cores: string[];
  coreIndex: Map<string, number>;
  distance: Int32Array;
  firstHop: Int32Array;
};

export type SpecToCodeResult = {
  states: number;
  edges: number;
  coreStates: number;
  transitions: number;
  steps: number;
  crashes: number;
  failure: null | { path: string[]; expected: string; shown: string };
};

function label(act: Act): string {
  const { name, ...rest } = act as Record<string, unknown> & { name: string };
  const args = Object.values(rest).map((v) => String(v)).join(",");
  return args ? `${name}(${args})` : name;
}

const plans = new Map<string, Promise<Plan>>();

/// The distinct transitions of the graph at `graphPath`, built once per graph
/// and shared by every sweep, including the planted-bug ones.
function planFor(graphPath: string): Promise<Plan> {
  let plan = plans.get(graphPath);
  if (!plan) {
    plan = (async () => {
      if (!existsSync(graphPath)) throw new Error(`${graphPath} is missing; run model check first`);
      const unescape = (text: string) => text.replace(/\\(.)/g, (_, char: string) => (char === "n" ? "\n" : char));
      const coreKey = new Map<string, string>();
      const actKey = new Map<string, string>();
      const shownKey = new Map<string, string>();
      const acts = new Map<string, Act>();
      let init: string | null = null;
      let states = 0;

      // Pass 1: read node records without retaining the full edge set in memory.
      for await (const line of createInterface({ input: createReadStream(graphPath, { encoding: "utf8" }), crlfDelay: Infinity })) {
        const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"/.exec(line);
        if (!node) continue;
        const [, id, label] = node;
        const state: Record<string, unknown> = {};
        for (const entry of unescape(label!).split(/\n(?=\/\\ )/)) {
          const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
          if (match) state[match[1]!] = parseValue(match[2]!.trim());
        }
        states += 1;
        coreKey.set(id!, canonical(coreOf(state)));
        actKey.set(id!, canonical(state.act));
        shownKey.set(id!, canonical(shownOf(state)));
        acts.set(id!, state.act as Act);
        const act = state.act as { name?: string } | unknown[];
        if ((!Array.isArray(act) && act?.name === "Init") || (Array.isArray(act) && act[0] === "Init")) init = id!;
      }
      if (!init) throw new Error("the graph has an initial state");

      // Pass 2: stream edges and deduplicate directly by (fromCore, act).
      const byKey = new Map<string, Transition>();
      const outgoing = new Map<string, Transition[]>();
      let edges = 0;
      let conflict: Plan["conflict"] = null;
      for await (const line of createInterface({ input: createReadStream(graphPath, { encoding: "utf8" }), crlfDelay: Infinity })) {
        const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
        if (!edge) continue;
        const [, fromId, toId] = edge;
        edges += 1;
        const act = acts.get(toId!)!;
        const from = coreKey.get(fromId!)!;
        const key = `${from}|${actKey.get(toId!)!}`;
        const expected = shownKey.get(toId!)!;
        const known = byKey.get(key);
        if (known) {
          if (known.expected !== expected && !conflict) conflict = { act, first: known.expected, second: expected };
          continue;
        }
        const transition = { index: byKey.size, key, from, to: coreKey.get(toId!)!, act, expected };
        byKey.set(key, transition);
        if (!outgoing.has(from)) outgoing.set(from, []);
        outgoing.get(from)!.push(transition);
      }
      const zero = coreKey.get(init)!;
      const initShown = shownKey.get(init)!;
      // A fixed order, with each core state's Crash last, so the harness
      // restarts once per core state.
      for (const list of outgoing.values()) {
        list.sort((a, b) => Number(a.act.name === "Crash") - Number(b.act.name === "Crash") || (a.key < b.key ? -1 : 1));
      }
      const transitions = [...byKey.values()];
      const cores = [...outgoing.keys()];
      const coreIndex = new Map(cores.map((core, index) => [core, index]));
      const n = cores.length;
      const distance = new Int32Array(n * n).fill(-1);
      const firstHop = new Int32Array(n * n).fill(-1);
      // Paths that never restart the harness: Crash transitions are left out
      // here, and a route takes one only through `crashFrom` below.
      for (let source = 0; source < n; source += 1) {
        const row = source * n;
        distance[row + source] = 0;
        const queue = [source];
        for (let at = 0; at < queue.length; at += 1) {
          const u = queue[at]!;
          for (const t of outgoing.get(cores[u]!) ?? []) {
            if (t.act.name === "Crash") continue;
            const v = coreIndex.get(t.to)!;
            if (distance[row + v] !== -1) continue;
            distance[row + v] = distance[row + u]! + 1;
            firstHop[row + v] = u === source ? t.index : firstHop[row + u]!;
            queue.push(v);
          }
        }
      }
      return {
        states,
        edges,
        zero,
        initShown,
        transitions,
        outgoing,
        conflict,
        cores,
        coreIndex,
        distance,
        firstHop,
      };
    })();
    plans.set(graphPath, plan);
  }
  return plan;
}

export async function specToCode(bin: string, graphPath: string): Promise<SpecToCodeResult> {
  const plan = await planFor(graphPath);
  const taken = new Uint8Array(plan.transitions.length);
  const untaken = new Map<string, number>();
  for (const [core, list] of plan.outgoing) untaken.set(core, list.length);
  let steps = 0;
  const result = (crashes: number, failure: SpecToCodeResult["failure"]): SpecToCodeResult => ({
    states: plan.states, edges: plan.edges, coreStates: plan.outgoing.size, transitions: plan.transitions.length, steps, crashes, failure,
  });
  if (plan.conflict) {
    return result(0, { path: [`model: ${label(plan.conflict.act)} from one core state reaches two states`], expected: plan.conflict.first, shown: plan.conflict.second });
  }

  // The cheapest route from `from` to the nearest core state with an untaken
  // transition, or null when every transition is taken. A route either
  // avoids crashes or starts with one and continues from the zero state; a
  // harness restart costs about as much as 200 steps.
  const n = plan.cores.length;
  const crashCost = 200;
  const zero = plan.coreIndex.get(plan.zero)!;
  const walk = (start: number, target: number): Transition[] => {
    const path: Transition[] = [];
    for (let u = start; u !== target;) {
      const hop = plan.transitions[plan.firstHop[u * n + target]!]!;
      path.push(hop);
      u = plan.coreIndex.get(hop.to)!;
    }
    return path;
  };
  const nearest = (from: string): Transition[] | null => {
    const source = plan.coreIndex.get(from)!;
    let best = -1;
    let bestCost = Infinity;
    let viaCrash = false;
    for (let v = 0; v < n; v += 1) {
      if ((untaken.get(plan.cores[v]!) ?? 0) === 0) continue;
      const direct = plan.distance[source * n + v]!;
      const crashed = plan.distance[zero * n + v]!;
      if (direct >= 0 && direct < bestCost) { best = v; bestCost = direct; viaCrash = false; }
      if (crashed >= 0 && crashCost + crashed < bestCost) { best = v; bestCost = crashCost + crashed; viaCrash = true; }
    }
    if (best < 0) return null;
    if (!viaCrash) return walk(source, best);
    const crash = (plan.outgoing.get(from) ?? []).find((t) => t.act.name === "Crash")!;
    return [crash, ...walk(zero, best)];
  };

  const harness = await Harness.start(bin);
  if (canonical(harness.last) !== plan.initShown) {
    await harness.close();
    return result(0, { path: ["start"], expected: plan.initShown, shown: canonical(harness.last) });
  }
  let current = plan.zero;
  const path: string[] = [];
  const take = async (t: Transition): Promise<SpecToCodeResult["failure"]> => {
    path.push(label(t.act));
    if (path.length > 40) path.shift();
    const shown = canonical(await harness.send(eventFor(t.act)));
    steps += 1;
    if (shown !== t.expected) return { path: [...path], expected: t.expected, shown };
    if (!taken[t.index]) {
      taken[t.index] = 1;
      untaken.set(t.from, untaken.get(t.from)! - 1);
    }
    current = t.to;
    return null;
  };
  try {
    for (;;) {
      const here = (plan.outgoing.get(current) ?? []).find((t) => !taken[t.index]);
      if (here) {
        const failure = await take(here);
        if (failure) return result(harness.crashes, failure);
        continue;
      }
      const route = nearest(current);
      if (!route) break;
      for (const t of route) {
        const failure = await take(t);
        if (failure) return result(harness.crashes, failure);
      }
    }
  } finally {
    await harness.close();
  }
  const missed = taken.reduce((sum, flag) => sum + (flag ? 0 : 1), 0);
  if (missed > 0) return result(harness.crashes, { path: [`${missed} transitions were never taken`], expected: "all", shown: String(plan.transitions.length - missed) });
  return result(harness.crashes, null);
}
