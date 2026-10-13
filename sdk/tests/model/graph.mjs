// The state graphs check.sh has TLC write, as the model drivers read them.
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
    throw new Error(`${path} is missing; run sdk/tests/model/check.sh first`);
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
      if (state.act?.name === "Init") init = id;
    }
  }
  assert.ok(init, "the graph has an initial state");
  return { states, next, init };
}
