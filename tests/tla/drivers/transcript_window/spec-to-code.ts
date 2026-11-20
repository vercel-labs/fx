// Spec to code: replays every transition of a TranscriptWindow TLC state
// graph against the real core through the harness, and checks that what the
// core shows after the step (its abstract state and the step's effects)
// equals the model's target state.
//
// For each edge, the core is reset to its zero state, driven along a shortest
// path from the initial state to the edge's source, and then across the edge.
// The path's steps are earlier edges of the same sweep, so only the last step
// of each route is compared. Every edge is taken, so coverage is complete or
// the run fails. A Crash edge resets the core's state, which is all the state
// the harness has (lib.ts, Harness); code-to-spec.ts kills real processes.
import { loadGraph } from "../graph.mjs";
import { Harness, codeView, eventFor, modelView, type Act, type Config, type Event } from "./lib.ts";

type Graph = { states: Map<string, Record<string, unknown>>; next: Map<string, Set<string>>; init: string };

export type SpecToCodeResult = {
  states: number;
  edges: number;
  steps: number;
  byAction: Record<string, number>;
  failure: null | { route: string[]; expected: string; shown: string; rejected?: string };
};

/// Shortest paths from the initial state, as state ids from init to each state.
function shortestPaths(graph: Graph): Map<string, string[]> {
  const paths = new Map<string, string[]>([[graph.init, [graph.init]]]);
  const queue = [graph.init];
  for (let head = 0; head < queue.length; head += 1) {
    const from = queue[head]!;
    for (const to of graph.next.get(from) ?? []) {
      if (paths.has(to)) continue;
      paths.set(to, [...paths.get(from)!, to]);
      queue.push(to);
    }
  }
  return paths;
}

function label(act: Act): string {
  const args = Object.entries(act).filter(([key]) => key !== "name").map(([key, value]) => `${key}=${value}`);
  return args.length ? `${act.name}(${args.join(",")})` : act.name;
}

export async function specToCode(options: { graphPath: string; bin: string; config: Config; none: number }): Promise<SpecToCodeResult> {
  const graph = (await loadGraph(options.graphPath)) as Graph;
  const paths = shortestPaths(graph);
  const edges: [string, string][] = [];
  for (const [from, targets] of graph.next) for (const to of targets) edges.push([from, to]);
  edges.sort(([a1, b1], [a2, b2]) => (a1 + b1 < a2 + b2 ? -1 : 1));
  const harness = await Harness.start(options.bin, options.config);
  const byAction: Record<string, number> = {};
  let steps = 0;
  try {
    for (const [from, to] of edges) {
      const route = [...paths.get(from)!.slice(1), to];
      const events: Event[] = [{ event: "reset" }];
      for (const id of route) {
        const target = graph.states.get(id)!;
        events.push(eventFor(target.act as Act, target));
      }
      const shown = await harness.sendMany(events);
      steps += route.length;
      const target = graph.states.get(to)!;
      const act = target.act as Act;
      byAction[act.name] = (byAction[act.name] ?? 0) + 1;
      // After a crash the model keeps the dead process's variables; the core
      // has none to show until Resumed.
      if (act.name === "Crash") continue;
      const expected = modelView(target, options.none);
      const last = shown[shown.length - 1]!;
      const got = codeView(last);
      if (got !== expected) {
        return {
          states: graph.states.size,
          edges: edges.length,
          steps,
          byAction,
          failure: { route: route.map((id) => label(graph.states.get(id)!.act as Act)), expected, shown: got, rejected: last.rejected },
        };
      }
    }
  } finally {
    await harness.close();
  }
  return { states: graph.states.size, edges: edges.length, steps, byAction, failure: null };
}
