// Shared pieces of the bash tool's result-store driver: the model's state graph
// as TLC writes it, the map from each model step to one harness event, the shape
// of a state that both sides print the same way, the JSON-lines harness around
// the real result store, and its build in a work folder that holds a copy of
// src/ (where a planted bug can be written).
import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT } from "../lib/tlc.ts";
import { parseValue } from "../graph.mjs";

export const MODEL_DIR = join(TLA_ROOT, "bash_tool");
export const HARNESS_SOURCE = join(import.meta.dirname, "harness.zig");

export type Vars = Record<string, any>;
export type Input = { event: string; i?: number; kind?: string; big?: boolean };
export type Transition = { from: string; to: string; label: string; input: Input; key: string };
export type Graph = {
  /// The programs and the room of the model instance the graph is for.
  programs: string[];
  room: number;
  shapes: Map<string, string>;
  byShape: Map<string, string>;
  vars: Map<string, Vars>;
  out: Map<string, Transition[]>;
  init: string;
  edges: number;
  transitions: number;
};
export type Reply = { state: Vars; out: string[] };

/// The model's variables, in the order ResultStore.tla declares them.
export const VARIABLES = [
  "sent", "current", "phase", "ready", "waiting", "shown", "files", "indexed", "unsaved",
  "fullNoticed", "stopped", "restarts", "runs", "saves", "torn", "how", "savedBy", "refused",
  "noticed", "damaged", "lost", "lostNoticed", "unreported",
];

/// The variables that are sets. A set is compared as its sorted members.
const SET_VARIABLES = new Set([
  "sent", "shown", "files", "indexed", "unsaved", "fullNoticed", "stopped",
  "savedBy", "refused", "noticed", "lost", "lostNoticed",
]);

/// The variables that are functions over the programs, printed as records.
const FUNCTION_VARIABLES = new Set(["runs", "how"]);

/// The programs the harness knows: the three-program design the traces check.
export const PROGRAMS = ["p1", "p2", "p3"];

/// The two-program instances the spec to code walk takes every distinct step of.
export const TWO_PROGRAMS = ["p1", "p2"];

/// The room of the three-program design, which the traces check.
export const DESIGN_ROOM = 2;

/// The harness event for each action of ResultStore's Next.
const EVENT_OF: Record<string, string> = {
  Send: "send",
  Finish: "finish",
  File: "file",
  Index: "index",
  Clear: "clear",
  Show: "show",
  GiveUp: "give_up",
  WaitMore: "wait_more",
  Damage: "damage",
  HealFails: "heal_fails",
  Restart: "restart",
};

/// Every event the harness takes. A random walk sends these, with a fault now and then.
export const EVENT_NAMES = Object.values(EVENT_OF);

/// How a program can end, for the random walks.
export const KINDS = ["ok", "exit", "killed"];

/// The canonical text of a value: keys sorted, so equal values print equally.
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).filter(([, v]) => v !== undefined);
    entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

/// What a state shows, with each set in one order, so the model's print and the
/// harness's print compare equal. A function over the programs keeps only the
/// instance's programs, so a two-program model compares with the harness's three.
export function shapeOf(vars: Vars, programs: string[] = PROGRAMS): string {
  const normal: Record<string, unknown> = {};
  for (const name of VARIABLES) {
    const value = vars[name];
    if (SET_VARIABLES.has(name) && Array.isArray(value)) {
      normal[name] = value.map(canonical).sort();
    } else if (FUNCTION_VARIABLES.has(name)) {
      normal[name] = Object.fromEntries(programs.map((p) => [p, value[p]]));
    } else {
      normal[name] = value;
    }
  }
  return canonical(normal);
}

/// The harness event for one model step, from the states on either side.
export function eventFor(label: string, from: Vars, to: Vars): Input {
  const event = EVENT_OF[label];
  if (!event) throw new Error(`no harness event for model step ${label}`);
  if (label === "Send") {
    const added = (to.sent as string[]).filter((p) => !(from.sent as string[]).includes(p));
    if (added.length !== 1) throw new Error(`Send: expected one program to be added, found ${added.length}`);
    return { event, i: Number(added[0]!.slice(1)) };
  }
  if (label === "Finish") {
    const program = from.current as string;
    return { event, kind: to.how[program] as string, big: (to.refused as string[]).includes(program) };
  }
  return { event };
}

/// A value of a state as TLC prints it. A function over the programs prints as
/// `(p1 :> v @@ p2 :> w)`, which parseValue does not read, so it is split here.
export function parseState(text: string): unknown {
  const value = text.trim();
  if (!value.startsWith("(")) return parseValue(value);
  const record: Record<string, unknown> = {};
  for (const pair of value.slice(1, -1).split(" @@ ")) {
    const at = pair.indexOf(" :> ");
    if (at < 0) throw new Error(`cannot read a function entry: ${pair}`);
    record[pair.slice(0, at).trim()] = parseValue(pair.slice(at + 4));
  }
  return record;
}

/// Reads TLC's state graph for the model of `programs`: each state's variables,
/// each step's label, and the initial state, which no step leads to.
export function loadGraph(path: string, programs: string[], room: number): Graph {
  const dot = readFileSync(path, "utf8");
  const vars = new Map<string, Vars>();
  const rawEdges = new Map<string, { to: string; label: string }[]>();
  const incoming = new Set<string>();
  const unescape = (label: string) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  for (const line of dot.split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      const [, from, to, label] = edge as unknown as [string, string, string, string];
      if (!rawEdges.has(from)) rawEdges.set(from, []);
      rawEdges.get(from)!.push({ to, label });
      incoming.add(to);
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"/.exec(line);
    if (node) {
      const state: Vars = {};
      for (const entry of unescape(node[2]!).split(/\n(?=\/\\ )/)) {
        const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
        if (match) state[match[1]!] = parseState(match[2]!);
      }
      vars.set(node[1]!, state);
    }
  }
  const roots = [...vars.keys()].filter((id) => !incoming.has(id));
  if (roots.length !== 1) throw new Error(`the graph needs one initial state, found ${roots.length}`);
  const shapes = new Map<string, string>();
  const byShape = new Map<string, string>();
  for (const [id, state] of vars) {
    const shape = shapeOf(state, programs);
    shapes.set(id, shape);
    const known = byShape.get(shape);
    if (known !== undefined && known !== id) throw new Error(`two graph states share one shape: ${known} and ${id}`);
    byShape.set(shape, id);
  }
  const out = new Map<string, Transition[]>();
  let edges = 0;
  let transitions = 0;
  for (const [from, list] of rawEdges) {
    const seen = new Set<string>();
    for (const { to, label } of list) {
      edges += 1;
      const input = eventFor(label, vars.get(from)!, vars.get(to)!);
      const key = `${from}|${label}|${canonical(input)}`;
      if (seen.has(key)) continue;
      seen.add(key);
      transitions += 1;
      if (!out.has(from)) out.set(from, []);
      out.get(from)!.push({ from, to, label, input, key });
    }
  }
  return { programs, room, shapes, byShape, vars, out, init: roots[0]!, edges, transitions };
}

/// Builds the harness in `work`: a copy of src/, the harness at its root (the
/// one place a file of src/ can be imported from), and an optional planted bug
/// written into the copy before the build. The find text must occur once.
export async function buildHarness(work: string, plant?: { file: string; find: string; replace: string }): Promise<string> {
  mkdirSync(work, { recursive: true });
  cpSync(join(REPO_ROOT, "src"), join(work, "src"), { recursive: true });
  copyFileSync(HARNESS_SOURCE, join(work, "harness.zig"));
  if (plant) {
    const path = join(work, plant.file);
    const text = readFileSync(path, "utf8");
    const first = text.indexOf(plant.find);
    if (first < 0 || text.indexOf(plant.find, first + 1) >= 0) {
      throw new Error(`${plant.file}: the text to plant must occur exactly once`);
    }
    writeFileSync(path, text.slice(0, first) + plant.replace + text.slice(first + plant.find.length));
  }
  const bin = join(work, "harness");
  const build = Bun.spawnSync(
    ["zig", "build-exe", "-ODebug", "-lc", "harness.zig", `-femit-bin=${bin}`, "--cache-dir", join(REPO_ROOT, ".zig-cache")],
    { cwd: work, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0 || !existsSync(bin)) {
    throw new Error(`harness build failed in ${work}:\n${build.stderr.toString()}${build.stdout.toString()}`);
  }
  return bin;
}

/// A new workspace folder. The harness keeps its result folders inside it.
export function newWorkspace(dir: string): string {
  mkdirSync(dir, { recursive: true });
  return dir;
}

/// One harness process. Each event is one line in and one line out.
export class Harness {
  private lines: string[] = [];
  private waiters: ((line: string) => void)[] = [];
  private readonly proc: ReturnType<typeof Bun.spawn>;
  /// The state the process printed at start, before any event.
  first!: Reply;

  private constructor(proc: ReturnType<typeof Bun.spawn>) {
    this.proc = proc;
  }

  static async start(bin: string, root: string, room: number): Promise<Harness> {
    const proc = Bun.spawn([bin, "--root", root, "--room", String(room)], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
    const harness = new Harness(proc);
    harness.pump(proc.stdout as ReadableStream<Uint8Array>);
    harness.first = parse(await harness.nextLine());
    return harness;
  }

  private pump(stream: ReadableStream<Uint8Array>) {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buffered = "";
    (async () => {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffered += decoder.decode(value, { stream: true });
        let newline = buffered.indexOf("\n");
        while (newline >= 0) {
          const line = buffered.slice(0, newline);
          buffered = buffered.slice(newline + 1);
          const waiter = this.waiters.shift();
          if (waiter) waiter(line);
          else this.lines.push(line);
          newline = buffered.indexOf("\n");
        }
      }
    })();
  }

  private nextLine(): Promise<string> {
    const line = this.lines.shift();
    if (line !== undefined) return Promise.resolve(line);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("the harness did not answer within 10 s")), 10000);
      this.waiters.push((value) => {
        clearTimeout(timer);
        resolve(value);
      });
    });
  }

  async send(input: Input): Promise<Reply> {
    const stdin = this.proc.stdin as import("bun").FileSink;
    stdin.write(`${JSON.stringify(input)}\n`);
    stdin.flush();
    return parse(await this.nextLine());
  }

  /// Starts again from the initial state in a new empty results folder (not a model step).
  async reset(): Promise<Reply> {
    return this.send({ event: "reset" });
  }

  async close() {
    (this.proc.stdin as import("bun").FileSink).end();
    await this.proc.exited;
  }
}

function parse(line: string): Reply {
  const parsed = JSON.parse(line) as { state: Vars; out: string[] };
  return { state: parsed.state, out: parsed.out };
}
