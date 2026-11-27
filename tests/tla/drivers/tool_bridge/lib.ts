// Shared pieces of the bash tool's file-change driver: the model's state graph
// as TLC writes it, the map from each model step to one harness event, the
// shape of a state that both sides print the same way, the JSON-lines harness
// around the real file path, and its build in a work folder that holds a copy
// of src/ (where a planted bug can be written).
import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT } from "../lib/tlc.ts";
import { parseValue } from "../graph.mjs";

export const MODEL_DIR = join(TLA_ROOT, "tool_bridge");
export const HARNESS_SOURCE = join(import.meta.dirname, "harness.zig");

export type Vars = Record<string, any>;
export type Input = { event: string; i?: number };
export type Transition = { from: string; to: string; label: string; input: Input; key: string };
export type Graph = {
  shapes: Map<string, string>;
  byShape: Map<string, string>;
  vars: Map<string, Vars>;
  out: Map<string, Transition[]>;
  init: string;
  edges: number;
  transitions: number;
};

// The harness event for each step of ToolEdit's Next.
const EVENT_OF: Record<string, string> = {
  RawWrite: "raw_write",
  OtherWrite: "other_write",
  End: "end",
  Kill: "kill",
  Hangup: "hangup",
  Close: "close",
  Send: "send",
  Prepare: "prepare",
  AutoAllow: "auto_allow",
  Ask: "ask",
  UserAllow: "user_allow",
  UserDeny: "user_deny",
  ReviewUnavailable: "review_unavailable",
  Apply: "apply",
  Publish: "publish",
  Withdraw: "withdraw",
};
const WITHOUT_REQUEST = new Set(["RawWrite", "OtherWrite", "End", "Kill", "Hangup", "Close"]);

/// Names every event of the model this driver can perform. DiffReport and
/// SkipReview belong to other designs and are not reached in "bridge".
export const EVENT_NAMES = Object.values(EVENT_OF);

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

/// What a state shows, with each set in one order. The model prints sets as
/// arrays too, so a set is compared as its sorted members.
export function shapeOf(vars: Vars): string {
  const sorted = (items: unknown[]) => items.map(canonical).sort();
  return canonical({
    prog: vars.prog,
    seen: vars.seen,
    call: vars.call,
    history: vars.history,
    raw: vars.raw,
    other: vars.other,
    req: vars.req,
    reviewed: sorted(vars.reviewed),
    prompt: vars.prompt,
    tracker: sorted(vars.tracker),
    rows: vars.rows,
    flags: vars.flags,
    diffDone: vars.diffDone,
  });
}

/// The harness event for one model step, from the states on either side.
export function eventFor(label: string, from: Vars, to: Vars): Input {
  const event = EVENT_OF[label];
  if (!event) throw new Error(`no harness event for model step ${label}`);
  if (WITHOUT_REQUEST.has(label)) return { event };
  if (label === "Ask") return { event, i: to.prompt };
  if (label === "UserAllow" || label === "UserDeny") return { event, i: from.prompt };
  if (label === "Publish") return { event, i: to.rows[to.rows.length - 1] };
  const changed = [0, 1].filter((k) => from.req[k].stage !== to.req[k].stage);
  if (changed.length !== 1) throw new Error(`${label}: expected one request to change, found ${changed.length}`);
  return { event, i: changed[0]! + 1 };
}

/// Reads TLC's state graph for the model: each state's variables, each
/// step's label, and the initial state, which no step leads to.
export function loadGraph(path: string): Graph {
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
        if (match) state[match[1]!] = parseValue(match[2]!.trim());
      }
      vars.set(node[1]!, state);
    }
  }
  const roots = [...vars.keys()].filter((id) => !incoming.has(id));
  if (roots.length !== 1) throw new Error(`the graph needs one initial state, found ${roots.length}`);
  const shapes = new Map<string, string>();
  const byShape = new Map<string, string>();
  for (const [id, state] of vars) {
    const shape = shapeOf(state);
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
  return { shapes, byShape, vars, out, init: roots[0]!, edges, transitions };
}

/// Builds the harness in `work`: a copy of src/, the harness at its root (the
/// one place a file of src/ can be imported from), and an optional planted bug
/// written into the copy before the build.
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

/// A new workspace with its file at version 0: the content every run starts from.
export function newWorkspace(dir: string): string {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "app.txt"), "v0");
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

  static async start(bin: string, root: string, env?: Record<string, string>): Promise<Harness> {
    const proc = Bun.spawn([bin, "--root", root], { stdin: "pipe", stdout: "pipe", stderr: "inherit", env });
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

  async close() {
    (this.proc.stdin as import("bun").FileSink).end();
    await this.proc.exited;
  }
}

function parse(line: string): Reply {
  const parsed = JSON.parse(line) as { state: Vars; out: string[] };
  return { state: parsed.state, out: parsed.out };
}
