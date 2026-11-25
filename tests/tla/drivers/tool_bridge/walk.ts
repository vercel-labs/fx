// Spec to code: takes every distinct step of ToolEdit's "bridge" state graph on
// the real harness, and after each step checks that the state the code shows
// equals the state the model reaches. A step is distinct when it leaves the
// same state, by the same action with the same request, to the same state, so
// the walk takes each one once: complete coverage of the model's steps.
//
// The walk starts a harness process, takes an untaken step where it stands,
// and otherwise takes the nearest route to a state with an untaken step. When
// no such route exists, it starts a new process, with a new workspace at
// version 0, and walks from the initial state. The model never returns to
// its start, so a restart is the only way back, as a fresh program is.
import { Harness, newWorkspace, shapeOf, type Graph, type Transition } from "./lib.ts";

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

/// Walks the graph on the harness at `bin`. `workspace(n)` gives the folder
/// for the n-th harness process, which must not exist yet.
export async function specToCode(
  bin: string,
  graph: Graph,
  workspace: (n: number) => string,
  options: { maxSteps?: number } = {},
): Promise<WalkResult> {
  const started = performance.now();
  const taken = new Set<string>();
  const path: string[] = [];
  let steps = 0;
  let restarts = 0;
  let failure: WalkFailure | null = null;
  let harness: Harness | null = null;
  const initShape = graph.shapes.get(graph.init)!;

  const untaken = (node: string) => (graph.out.get(node) ?? []).filter((t) => !taken.has(t.key));

  // The nearest state, by steps, that has an untaken step; null if none is reachable.
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

  const start = async () => {
    const next = await Harness.start(bin, newWorkspace(workspace(restarts)));
    if (shapeOf(next.first.state) !== initShape) {
      failure = { path: ["start"], expected: initShape, shown: shapeOf(next.first.state), notes: next.first.out };
    }
    return next;
  };

  const take = async (t: Transition): Promise<boolean> => {
    path.push(labelOf(t));
    if (path.length > 40) path.shift();
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
  };

  try {
    harness = await start();
    let cur = graph.init;
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
      restarts += 1;
      harness = await start();
      if (failure) break;
      cur = graph.init;
      if (untaken(cur).length === 0 && route(cur) === null) {
        failure = {
          path: ["restart"],
          expected: "every step reached from the start",
          shown: `${graph.transitions - taken.size} steps are never reached`,
          notes: [],
        };
        break;
      }
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

