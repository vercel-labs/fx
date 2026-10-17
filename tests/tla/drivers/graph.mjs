// The state graphs tests/tla/sdk/check.sh has TLC write, as the drivers read
// them, and the walk drive-intake.mjs and drive-images.mjs take along one.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";

// A TLA+ value as TLC prints it: numbers, strings, booleans, records (and
// functions over names, which print as records), sequences, and sets, read
// as arrays in TLC's order.
export function parseValue(text) {
  let at = 0;
  const space = () => { while (/\s/.test(text[at] ?? "")) at += 1; };
  const expect = (token) => {
    space();
    if (!text.startsWith(token, at)) throw new Error(`expected ${token} at ${at} in ${text}`);
    at += token.length;
  };
  const value = () => {
    space();
    for (const [open, close] of [["<<", ">>"], ["{", "}"]]) {
      if (!text.startsWith(open, at)) continue;
      at += open.length;
      const items = [];
      space();
      if (text.startsWith(close, at)) { at += close.length; return items; }
      for (;;) {
        items.push(value());
        space();
        if (text[at] === ",") { at += 1; continue; }
        expect(close);
        return items;
      }
    }
    if (text[at] === "[") {
      at += 1;
      const record = {};
      for (;;) {
        space();
        const key = /^[A-Za-z_][A-Za-z0-9_]*/.exec(text.slice(at))?.[0];
        if (!key) throw new Error(`expected a field at ${at} in ${text}`);
        at += key.length;
        expect("|->");
        record[key] = value();
        space();
        if (text[at] === ",") { at += 1; continue; }
        expect("]");
        return record;
      }
    }
    if (text[at] === "\"") {
      const end = text.indexOf("\"", at + 1);
      const string = text.slice(at + 1, end);
      at = end + 1;
      return string;
    }
    for (const [token, result] of [["TRUE", true], ["FALSE", false]]) {
      if (text.startsWith(token, at)) { at += token.length; return result; }
    }
    const number = /^-?\d+/.exec(text.slice(at))?.[0];
    if (number) { at += number.length; return Number(number); }
    throw new Error(`cannot read a value at ${at} in ${text}`);
  };
  const result = value();
  space();
  if (at !== text.length) throw new Error(`trailing text at ${at} in ${text}`);
  return result;
}

/** The graph check.sh wrote to `path`: each state by id, its successors, and the initial state. */
export async function loadGraph(path) {
  const dot = await readFile(path, "utf8").catch(() => {
    throw new Error(`${path} is missing; run tests/tla/sdk/check.sh first`);
  });
  const states = new Map();
  const next = new Map();
  let init = null;
  const unescape = (label) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  for (const line of dot.split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      const [, from, to] = edge;
      if (!next.has(from)) next.set(from, new Set());
      next.get(from).add(to);
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"/.exec(line);
    if (node) {
      const [, id, label] = node;
      const state = {};
      // One entry per variable; TLC wraps a long value over several lines.
      for (const entry of unescape(label).split(/\n(?=\/\\ )/)) {
        const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
        if (match) state[match[1]] = parseValue(match[2].trim());
      }
      states.set(id, state);
      // `act` is a record with a name, or a tuple whose first item is one.
      if (state.act?.name === "Init" || (Array.isArray(state.act) && state.act[0] === "Init")) init = id;
    }
  }
  assert.ok(init, "the graph has an initial state");
  return { states, next, init };
}

// Walks the code along `graph`, `walks` times. Each walk opens the code with
// `open(walk)`, which returns `{ perform(act), settle(), close(), problems }`.
// Each step is one the model allows from where the walk stands, chosen at
// random among those that cross an edge no walk has crossed yet, if any;
// `choose` may narrow that pool. After it the code must show, through
// `view`, a state the model reaches once the code has taken every step in
// `autoActs` it can on its own; `nameOf` gives a step's action name. A walk
// the model does not allow, or whose code reports a problem, prints its path
// and sets `process.exitCode`, and no more walks run. Returns the steps taken
// and the edges covered.
export async function walkGraph({ graph, walks, random, autoActs, nameOf, sameAct, label, view, open, choose = (pool) => pool, verbose = false }) {
  const actOf = (id) => graph.states.get(id).act;
  const successors = (id) => [...(graph.next.get(id) ?? [])].filter((to) => to !== id);
  // The states the code settles in after a step: every path of the steps it
  // takes on its own, to where it can take none.
  const settledFrom = (id, edges) => {
    const seen = new Set([id]);
    const queue = [id];
    const quiet = [];
    while (queue.length > 0) {
      const from = queue.shift();
      const autos = successors(from).filter((to) => autoActs.has(nameOf(actOf(to))));
      if (autos.length === 0) quiet.push(from);
      for (const to of autos) {
        edges.push(`${from}>${to}`);
        if (!seen.has(to)) { seen.add(to); queue.push(to); }
      }
    }
    return quiet;
  };
  const covered = new Set();
  const totalEdges = [...graph.next.values()].reduce((sum, targets) => sum + [...targets].length, 0);
  let steps = 0;
  for (let walk = 1; walk <= walks; walk += 1) {
    const code = await open(walk);
    const path = [];
    let current = new Set(settledFrom(graph.init, []));
    try {
      for (;;) {
        const options = [];
        for (const from of current) {
          for (const to of successors(from)) {
            const act = actOf(to);
            if (autoActs.has(nameOf(act))) continue;
            let item = options.find((entry) => sameAct(entry.act, act));
            if (!item) options.push(item = { act, fresh: false });
            if (!covered.has(`${from}>${to}`)) item.fresh = true;
          }
        }
        if (options.length === 0) break;
        const fresh = options.filter((item) => item.fresh);
        const pool = choose(fresh.length > 0 ? fresh : options);
        const { act } = pool[Math.floor(random() * pool.length)];
        path.push(label(act));
        if (verbose) console.log(`walk ${walk}: ${label(act)}`);
        await code.perform(act);
        const shown = await code.settle();
        if (code.problems.length > 0) throw new Error([...new Set(code.problems)].join("; "));
        const seen = JSON.stringify(shown);
        if (verbose) console.log(`  shows ${seen}`);
        steps += 1;
        const next = new Set();
        const allowed = new Set();
        for (const from of current) {
          for (const to of successors(from).filter((id) => sameAct(actOf(id), act))) {
            const edges = [`${from}>${to}`];
            for (const end of settledFrom(to, edges)) {
              allowed.add(view(graph.states.get(end)));
              if (view(graph.states.get(end)) !== seen) continue;
              next.add(end);
              for (const edge of edges) covered.add(edge);
            }
          }
        }
        if (next.size === 0) {
          console.error(`FAIL walk ${walk} after ${path.join(" ")}`);
          console.error(`  the code shows   ${seen}`);
          for (const item of allowed) console.error(`  the model allows ${item}`);
          process.exitCode = 1;
          break;
        }
        current = next;
      }
    } catch (error) {
      console.error(`FAIL walk ${walk} after ${path.join(" ")}: ${error.message}`);
      process.exitCode = 1;
    } finally {
      await code.close();
    }
    if (process.exitCode) break;
    if (walk % 25 === 0 || walk === walks) console.log(`${walk} walks, ${steps} steps, ${covered.size} of ${totalEdges} edges`);
  }
  assert.ok(steps > 0 || process.exitCode, "the walks took steps");
  return { steps, covered: covered.size, totalEdges };
}
