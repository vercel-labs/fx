// Spec to code: replays every transition of ImageRoute's TLC state graph
// against the real core through the harness, and after every step checks
// that what the core shows (abstract(state) and the step's effects) equals
// the model's state.
//
// The model keeps no history beyond one turn, so its graph is small enough
// to sweep whole: for each edge, the core is reset to its zero state, driven
// along a shortest path from the initial state to the edge's source, and then
// across the edge. A Crash edge kills the harness process and starts a new
// one. Every edge is taken, so coverage is complete or the run fails.
import { loadGraph } from "../graph.mjs";
import { Harness, canonical, eventFor, shownOf, type Act } from "./lib.ts";

type Graph = { states: Map<string, Record<string, unknown>>; next: Map<string, Set<string>>; init: string };

export type SpecToCodeResult = {
  states: number;
  edges: number;
  steps: number;
  failure: null | { path: string[]; expected: string; shown: string };
};

function label(act: Act): string {
  if (act.name === "TurnStarted" || act.name === "CapabilitiesResolved") {
    const view = act.view.kind === "listed" ? `listed(vision=${act.view.vision},file_input=${act.view.file_input})` : act.view.kind;
    return `${act.name}(${view})`;
  }
  if (act.name === "RequestReady") {
    const flags = Object.entries(act.req).filter(([, on]) => on).map(([name]) => name);
    return `RequestReady(${flags.join(",") || "no images"})`;
  }
  return act.name;
}

/// Shortest paths from the initial state, as state ids from init to each state.
function shortestPaths(graph: Graph): Map<string, string[]> {
  const paths = new Map<string, string[]>([[graph.init, [graph.init]]]);
  const queue = [graph.init];
  while (queue.length > 0) {
    const from = queue.shift()!;
    for (const to of graph.next.get(from) ?? []) {
      if (paths.has(to)) continue;
      paths.set(to, [...paths.get(from)!, to]);
      queue.push(to);
    }
  }
  return paths;
}

export async function specToCode(bin: string, graphPath: string): Promise<SpecToCodeResult> {
  const graph = (await loadGraph(graphPath)) as Graph;
  const paths = shortestPaths(graph);
  const zero = canonical(shownOf(graph.states.get(graph.init)!));
  const edges: [string, string][] = [];
  for (const [from, targets] of graph.next) for (const to of targets) edges.push([from, to]);
  edges.sort(([a1, b1], [a2, b2]) => (a1 + b1 < a2 + b2 ? -1 : 1));

  const harness = await Harness.start(bin);
  let steps = 0;
  try {
    for (const [from, to] of edges) {
      // Back to the zero state: a turn that starts with an unreachable
      // catalog holds exactly the core's initial state.
      const reset = await harness.send({ event: "turn_started", view: { kind: "down", vision: false, file_input: false } });
      if (canonical(reset) !== zero) {
        return { states: graph.states.size, edges: edges.length, steps, failure: { path: ["reset"], expected: zero, shown: canonical(reset) } };
      }
      const route = [...paths.get(from)!.slice(1), to];
      const taken: string[] = [];
      for (const id of route) {
        const state = graph.states.get(id)!;
        const act = state.act as Act;
        taken.push(label(act));
        const shown = canonical(await harness.send(eventFor(act)));
        steps += 1;
        const expected = canonical(shownOf(state));
        if (shown !== expected) {
          return { states: graph.states.size, edges: edges.length, steps, failure: { path: taken, expected, shown } };
        }
      }
    }
  } finally {
    await harness.close();
  }
  return { states: graph.states.size, edges: edges.length, steps, failure: null };
}
