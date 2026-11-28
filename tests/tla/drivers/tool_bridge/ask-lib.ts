// Shared pieces of the ask-wait driver: AskWait's state graph as TLC writes it,
// the shape both sides print the same way, the map from each model step to one
// harness event, the JSON-lines harness process, and its build in a work folder
// that holds a copy of src/ and build.zig.
import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT } from "../lib/tlc.ts";
import { parseValue } from "../graph.mjs";
import { canonical } from "./lib.ts";

export const MODEL_DIR = join(TLA_ROOT, "tool_bridge");
export const HARNESS_SOURCE = join(import.meta.dirname, "ask-harness.zig");

export type Vars = Record<string, any>;
export type Input = { event: string; i?: number };
export type Transition = { from: string; to: string; label: string; input: Input; key: string };
export type AskGraph = {
  roots: string[];
  shapes: Map<string, string>;
  byShape: Map<string, string>;
  vars: Map<string, Vars>;
  out: Map<string, Transition[]>;
  edges: number;
  transitions: number;
};

const EVENT_OF: Record<string, string> = {
  Run: "run",
  Yield: "yield",
  Return: "return",
  Gone: "gone",
  Send: "send",
  Show: "show",
  GiveUp: "give_up",
  Answer: "answer",
  Esc: "esc",
  Withdraw: "withdraw",
};
const WITHOUT_REQUEST = new Set(["Run", "Yield", "Return", "Gone"]);

export const EVENT_NAMES = Object.values(EVENT_OF);

export function shapeOf(vars: Vars): string {
  return canonical({
    prog: vars.prog,
    programs: vars.programs,
    ui: vars.ui,
    bash: vars.bash,
    req: vars.req,
    lock: vars.lock,
    slot: vars.slot,
    crashed: vars.crashed,
    asked: vars.asked,
    told: vars.told,
  });
}

export function eventFor(label: string, from: Vars, to: Vars): Input {
  const event = EVENT_OF[label];
  if (!event) throw new Error(`no harness event for model step ${label}`);
  if (WITHOUT_REQUEST.has(label)) return { event };
  const changed = [0, 1].filter((k) => from.req[k] !== to.req[k]);
  if (changed.length !== 1) throw new Error(`${label}: expected one request to change, found ${changed.length}`);
  return { event, i: changed[0]! + 1 };
}

export function loadAskGraph(path: string): AskGraph {
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
  if (roots.length === 0) throw new Error("the graph needs at least one initial state");
  roots.sort((a, b) => Number(Boolean(vars.get(b)!.ui)) - Number(Boolean(vars.get(a)!.ui)));

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
  return { roots, shapes, byShape, vars, out, edges, transitions };
}

export function harnessEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) if (value !== undefined) env[key] = value;
  env.FX_SOUND = "0";
  env.FX_TEST_STEER_YIELD_GRACE_MS = "0";
  return env;
}

const HARNESS_BUILD_ANCHOR = "    const session_manager = addSessionManager(b, exe.root_module, target, optimize, null, fuzz_corpora);\n";
const HARNESS_BUILD_BLOCK = `    const ask_harness_mod = b.createModule(.{
        .root_source_file = b.path("ask-harness.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    _ = addSessionManager(b, ask_harness_mod, target, optimize, null, fuzz_corpora);
    ask_harness_mod.addImport("build_options", build_options.createModule());
    const ask_harness_exe = b.addExecutable(.{ .name = "ask-harness", .root_module = ask_harness_mod });
    const ask_harness_install = b.addInstallArtifact(ask_harness_exe, .{});
    b.step("ask-harness", "Build the ask wait harness").dependOn(&ask_harness_install.step);
`;

export async function buildAskHarness(work: string, plant?: { file: string; find: string; replace: string }): Promise<string> {
  mkdirSync(join(work, "tests"), { recursive: true });
  cpSync(join(REPO_ROOT, "src"), join(work, "src"), { recursive: true });
  cpSync(join(REPO_ROOT, "tests", "fuzz"), join(work, "tests", "fuzz"), { recursive: true });
  copyFileSync(join(REPO_ROOT, "build.zig"), join(work, "build.zig"));
  copyFileSync(join(REPO_ROOT, "build.zig.zon"), join(work, "build.zig.zon"));
  copyFileSync(HARNESS_SOURCE, join(work, "ask-harness.zig"));
  const build = readFileSync(join(work, "build.zig"), "utf8");
  if (build.split(HARNESS_BUILD_ANCHOR).length !== 2) throw new Error("build.zig: the harness anchor must occur exactly once");
  writeFileSync(join(work, "build.zig"), build.replace(HARNESS_BUILD_ANCHOR, HARNESS_BUILD_ANCHOR + HARNESS_BUILD_BLOCK));
  if (plant) {
    const path = join(work, plant.file);
    const text = readFileSync(path, "utf8");
    const first = text.indexOf(plant.find);
    if (first < 0 || text.indexOf(plant.find, first + 1) >= 0) {
      throw new Error(`${plant.file}: the text to plant must occur exactly once`);
    }
    writeFileSync(path, text.slice(0, first) + plant.replace + text.slice(first + plant.find.length));
  }
  const built = Bun.spawnSync(
    ["zig", "build", "ask-harness", "--cache-dir", join(REPO_ROOT, ".zig-cache")],
    { cwd: work, stdout: "pipe", stderr: "pipe" },
  );
  const bin = join(work, "zig-out", "bin", "ask-harness");
  if (built.exitCode !== 0 || !existsSync(bin)) {
    throw new Error(`ask-harness build failed in ${work}:\n${built.stderr.toString()}${built.stdout.toString()}`);
  }
  return bin;
}

export class HarnessCrashError extends Error {
  constructor(readonly exitCode: number | null, readonly stderr: string) {
    super(`ask-harness exited (${exitCode ?? "signal"}): ${stderr.trim().slice(0, 300)}`);
  }
}

export type AskReply = { state: Vars; out: string[] };

export class AskHarness {
  private lines: string[] = [];
  private waiters: { resolve: (line: string) => void; reject: (err: Error) => void }[] = [];
  private stderrChunks: string[] = [];
  private closed = false;
  private crashError: Error | null = null;
  private readonly proc: ReturnType<typeof Bun.spawn>;
  first!: AskReply;

  private constructor(proc: ReturnType<typeof Bun.spawn>) {
    this.proc = proc;
  }

  static async start(bin: string, root: string, ui: boolean, env?: Record<string, string>): Promise<AskHarness> {
    mkdirSync(root, { recursive: true });
    const proc = Bun.spawn([bin, "--root", root, "--ui", ui ? "true" : "false"], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      env,
    });
    const harness = new AskHarness(proc);
    harness.pumpStderr(proc.stderr as ReadableStream<Uint8Array>);
    harness.pumpStdout(proc.stdout as ReadableStream<Uint8Array>);
    harness.first = parseReply(await harness.nextLine());
    return harness;
  }

  private pumpStderr(stream: ReadableStream<Uint8Array>) {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    (async () => {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        this.stderrChunks.push(decoder.decode(value, { stream: true }));
      }
    })();
  }

  private pumpStdout(stream: ReadableStream<Uint8Array>) {
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
          if (waiter) waiter.resolve(line);
          else this.lines.push(line);
          newline = buffered.indexOf("\n");
        }
      }
      const exitCode = await this.proc.exited;
      this.closed = true;
      const err = new HarnessCrashError(exitCode, this.stderrChunks.join(""));
      this.crashError = err;
      while (this.waiters.length > 0) this.waiters.shift()!.reject(err);
    })();
  }

  private nextLine(): Promise<string> {
    const line = this.lines.shift();
    if (line !== undefined) return Promise.resolve(line);
    if (this.closed) return Promise.reject(this.crashError ?? new HarnessCrashError(null, this.stderrChunks.join("")));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const index = this.waiters.indexOf(entry);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(new Error("the ask-harness did not answer within 10 s"));
      }, 10000);
      const entry = {
        resolve: (value: string) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (err: Error) => {
          clearTimeout(timer);
          reject(err);
        },
      };
      this.waiters.push(entry);
    });
  }

  async send(input: Input): Promise<AskReply> {
    const stdin = this.proc.stdin as import("bun").FileSink;
    stdin.write(`${JSON.stringify(input)}\n`);
    stdin.flush();
    return parseReply(await this.nextLine());
  }

  async close() {
    try {
      (this.proc.stdin as import("bun").FileSink).end();
    } catch {
      // The process may have aborted already (e.g. admission-lock-only).
    }
    await this.proc.exited;
  }
}

function parseReply(line: string): AskReply {
  const parsed = JSON.parse(line) as { state: Vars; out: string[] };
  return { state: parsed.state, out: parsed.out };
}
