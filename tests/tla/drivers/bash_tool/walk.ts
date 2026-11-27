// Spec to code: takes every distinct step of one small instance of ResultStore's
// state graph on the real result store, and after each step checks that the state
// the code shows equals the state the model reaches. A step is distinct when it
// leaves the same state, by the same action with the same arguments, to the same
// state, so the walk takes each one once: complete coverage of the model's steps.
//
// The walk takes an untaken step where it stands, and otherwise the nearest route
// to a state with an untaken step. When no such route exists, the harness is reset
// to the initial state in a new empty results folder, and the walk goes on from
// there. The model never returns to its start, so a reset is the only way back, as
// a new fx process is. Each reset is checked: the state it shows must be the
// model's initial state.
import { Harness, newWorkspace, shapeOf, type Graph, type Transition } from "./lib.ts";

export type WalkFailure = { path: string[]; expected: string; shown: string; notes: string[] };
export type WalkResult = {
  states: number;
  edges: number;
  transitions: number;
  taken: number;
  steps: number;
  resets: number;
  failure: WalkFailure | null;
  durationMs: number;
};

/// One distinct step, numbered: its state numbers, and its number among all steps.
type Edge = { t: Transition; from: number; to: number; id: number };

const labelOf = (t: Transition) =>
  t.input.i ? `${t.label}(p${t.input.i})` : t.input.kind ? `${t.label}(${t.input.kind}${t.input.big ? ", big" : ""})` : t.label;

/// Walks the graph on the harness at `bin`, in the workspace folder `dir`. The
/// searches run on numbers, not names, so a graph of a million steps stays cheap to search.
export async function specToCode(bin: string, graph: Graph, dir: string, options: { maxSteps?: number } = {}): Promise<WalkResult> {
  const started = performance.now();
  const ids = [...graph.shapes.keys()];
  const number = new Map(ids.map((id, i) => [id, i]));
  const out: Edge[][] = ids.map(() => []);
  const edgeOf: Edge[] = [];
  for (const [from, list] of graph.out) {
    for (const t of list) {
      const edge: Edge = { t, from: number.get(from)!, to: number.get(t.to)!, id: edgeOf.length };
      edgeOf.push(edge);
      out[edge.from]!.push(edge);
    }
  }
  const total = edgeOf.length;
  const taken = new Uint8Array(total);
  const left = Int32Array.from(out, (list) => list.length);
  let takenCount = 0;
  let steps = 0;
  let resets = 0;
  let failure: WalkFailure | null = null;
  let harness: Harness | null = null;
  const initial = number.get(graph.init)!;
  const initShape = graph.shapes.get(graph.init)!;

  // Breadth-first search state, reused by every route: a state is seen when its mark is this search's number.
  const mark = new Uint32Array(ids.length);
  const via = new Int32Array(ids.length);
  const queue = new Int32Array(ids.length);
  let search = 0;

  // The nearest route, by steps, to a state with an untaken step; null if none is reachable.
  const route = (from: number): Edge[] | null => {
    search += 1;
    mark[from] = search;
    let head = 0;
    let tail = 0;
    queue[tail++] = from;
    while (head < tail) {
      const node = queue[head++]!;
      if (node !== from && left[node]! > 0) {
        const back: Edge[] = [];
        for (let cur = node; cur !== from; cur = edgeOf[via[cur]!]!.from) back.push(edgeOf[via[cur]!]!);
        return back.reverse();
      }
      for (const edge of out[node]!) {
        if (mark[edge.to] === search) continue;
        mark[edge.to] = search;
        via[edge.to] = edge.id;
        queue[tail++] = edge.to;
      }
    }
    return null;
  };

  const checkInit = (reply: { state: Record<string, any>; out: string[] }, at: string) => {
    if (shapeOf(reply.state, graph.programs) !== initShape) {
      failure = { path: [at], expected: initShape, shown: shapeOf(reply.state, graph.programs), notes: reply.out };
    }
  };

  const path: string[] = [];
  const take = async (edge: Edge): Promise<boolean> => {
    path.push(labelOf(edge.t));
    if (path.length > 40) path.shift();
    const reply = await harness!.send(edge.t.input);
    steps += 1;
    const expected = graph.shapes.get(edge.t.to)!;
    const shown = shapeOf(reply.state, graph.programs);
    if (shown !== expected) {
      failure = { path: [...path], expected, shown, notes: reply.out };
      return false;
    }
    // A route replays steps already taken, so count each step once.
    if (taken[edge.id] === 0) {
      taken[edge.id] = 1;
      left[edge.from] -= 1;
      takenCount += 1;
    }
    return true;
  };

  try {
    harness = await Harness.start(bin, newWorkspace(dir), graph.room);
    checkInit(harness.first, "start");
    let cur = initial;
    while (!failure) {
      if (options.maxSteps !== undefined && steps >= options.maxSteps) break;
      const here = out[cur]!.find((edge) => taken[edge.id] === 0);
      if (here) {
        if (!(await take(here))) break;
        cur = here.to;
        continue;
      }
      const back = route(cur);
      if (back) {
        for (const edge of back) {
          if (!(await take(edge))) break;
          cur = edge.to;
        }
        continue;
      }
      if (takenCount === total) break;
      resets += 1;
      checkInit(await harness.reset(), "reset");
      if (failure) break;
      cur = initial;
      if (left[cur]! <= 0 && route(cur) === null) {
        failure = {
          path: ["reset"],
          expected: "every step reached from the start",
          shown: `${total - takenCount} steps are never reached`,
          notes: [],
        };
        break;
      }
    }
  } finally {
    await harness?.close();
  }
  return {
    states: ids.length,
    edges: graph.edges,
    transitions: total,
    taken: takenCount,
    steps,
    resets,
    failure,
    durationMs: Math.round(performance.now() - started),
  };
}
