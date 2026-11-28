// Spec to code for `fx tool ask`: takes every distinct step of AskWait's
// design graph on the real harness, and after each step checks that the state
// the code shows equals the state the model reaches. Because AskWait starts
// with `ui \in BOOLEAN`, the walk starts a harness process for each initial
// state (TUI vs non-UI host) and covers all distinct steps across both.
import { mkdirSync } from "node:fs";
import { AskHarness, HarnessCrashError, harnessEnv, shapeOf, type AskGraph, type Transition } from "./ask-lib.ts";

export type WalkFailure = { path: string[]; expected: string; shown: string; notes: string[] };
export type WalkResult = {
  states: number;
  edges: number;
  transitions: number;
  taken: number;
  steps: number;
  restarts: number;
  failure: WalkFailure | null;
  durationMs: number;
};

const labelOf = (t: Transition) => (t.input.i ? `${t.label}(${t.input.i})` : t.label);

export async function specToCode(
  bin: string,
  graph: AskGraph,
  home: (n: number) => string,
  options: { maxSteps?: number } = {},
): Promise<WalkResult> {
  const started = performance.now();
  const taken = new Set<string>();
  const path: string[] = [];
  let steps = 0;
  let restarts = 0;
  let failure: WalkFailure | null = null;
  let harness: AskHarness | null = null;

  const untaken = (node: string) => (graph.out.get(node) ?? []).filter((t) => !taken.has(t.key));

  const route = (from: string): Transition[] | null => {
    const parent = new Map<string, Transition>();
    const seen = new Set([from]);
    const queue = [from];
    for (let at = 0; at < queue.length; at += 1) {
      const node = queue[at]!;
      if (node !== from && untaken(node).length > 0) {
        const back: Transition[] = [];
        for (let cur = node; cur !== from; cur = parent.get(cur)!.from) back.push(parent.get(cur)!);
        return back.reverse();
      }
      for (const t of graph.out.get(node) ?? []) {
        if (seen.has(t.to)) continue;
        seen.add(t.to);
        parent.set(t.to, t);
        queue.push(t.to);
      }
    }
    return null;
  };

  const nextRoot = (): string | null => {
    for (const root of graph.roots) {
      if (untaken(root).length > 0 || route(root) !== null) return root;
    }
    return null;
  };

  const start = async (root: string) => {
    const dir = home(restarts);
    mkdirSync(dir, { recursive: true });
    const ui = Boolean(graph.vars.get(root)!.ui);
    const next = await AskHarness.start(bin, dir, ui, harnessEnv());
    const initShape = graph.shapes.get(root)!;
    if (shapeOf(next.first.state) !== initShape) {
      failure = { path: ["start"], expected: initShape, shown: shapeOf(next.first.state), notes: next.first.out };
    }
    return next;
  };

  const take = async (t: Transition): Promise<boolean> => {
    path.push(labelOf(t));
    if (path.length > 40) path.shift();
    try {
      const reply = await harness!.send(t.input);
      steps += 1;
      const expected = graph.shapes.get(t.to)!;
      const shown = shapeOf(reply.state);
      if (shown !== expected) {
        failure = { path: [...path], expected, shown, notes: reply.out };
        return false;
      }
      taken.add(t.key);
      return true;
    } catch (error) {
      steps += 1;
      const expected = graph.shapes.get(t.to)!;
      const message = error instanceof HarnessCrashError ? error.message : (error as Error).message;
      failure = { path: [...path], expected, shown: `crashed: ${message}`, notes: [message] };
      return false;
    }
  };

  try {
    let cur = nextRoot() ?? graph.roots[0]!;
    harness = await start(cur);
    while (!failure) {
      if (options.maxSteps !== undefined && steps >= options.maxSteps) break;
      const here = untaken(cur);
      if (here.length > 0) {
        if (!(await take(here[0]!))) break;
        cur = here[0]!.to;
        continue;
      }
      const back = route(cur);
      if (back) {
        for (const t of back) {
          if (!(await take(t))) break;
          cur = t.to;
        }
        continue;
      }
      if (taken.size === graph.transitions) break;
      await harness.close();
      const root = nextRoot();
      if (!root) {
        failure = {
          path: ["restart"],
          expected: "every step reached from the start",
          shown: `${graph.transitions - taken.size} steps are never reached`,
          notes: [],
        };
        break;
      }
      restarts += 1;
      harness = await start(root);
      if (failure) break;
      cur = root;
    }
  } finally {
    await harness?.close();
  }
  return {
    states: graph.shapes.size,
    edges: graph.edges,
    transitions: graph.transitions,
    taken: taken.size,
    steps,
    restarts,
    failure,
    durationMs: Math.round(performance.now() - started),
  };
}
