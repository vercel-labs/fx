// Shared pieces of the agent-wait driver: AgentWait's state graph as TLC writes
// it, the shape both sides print the same way, the map from each model step to
// one harness event, and the build of the harness in a work folder. The work
// folder holds a copy of src/ and of build.zig, where a planted bug is written
// before the build; the product tree is never changed.
import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT } from "../lib/tlc.ts";
import { parseValue } from "../graph.mjs";
import { canonical } from "./lib.ts";

export const MODEL_DIR = join(TLA_ROOT, "tool_bridge");
export const HARNESS_SOURCE = join(import.meta.dirname, "agent-harness.zig");

export type Vars = Record<string, any>;
export type Input = { event: string };
export type Transition = { from: string; to: string; label: string; input: Input; key: string };
export type AgentGraph = {
  shapes: Map<string, string>;
  byShape: Map<string, string>;
  vars: Map<string, Vars>;
  out: Map<string, Transition[]>;
  init: string;
  edges: number;
  transitions: number;
};

/// The harness event for each step of AgentWait's Next.
const EVENT_OF: Record<string, string> = {
  Run: "run",
  WaitMore: "wait_more",
  Yield: "yield",
  Return: "return",
  Gone: "gone",
  StartWait: "start_wait",
  Post: "post",
  ChildEnds: "child_ends",
  Cancel: "cancel",
  Join: "join",
};

/// Every event the model names.
export const EVENT_NAMES = Object.values(EVENT_OF);

/// What a state shows, in a fixed order, the same way on both sides.
export function shapeOf(vars: Vars): string {
  return canonical({
    prog: vars.prog,
    programs: vars.programs,
    call: vars.call,
    waits: vars.waits,
    bash: vars.bash,
    working: vars.working,
    posted: vars.posted,
    queued: vars.queued,
    joined: vars.joined,
    lost: vars.lost,
    told: vars.told,
  });
}

/// Reads TLC's state graph for AgentWait: each state's variables, each step's
/// label, and the initial state, which no step leads to.
export function loadAgentGraph(path: string): AgentGraph {
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
      const event = EVENT_OF[label];
      if (!event) throw new Error(`no harness event for model step ${label}`);
      const input = { event };
      const key = `${from}|${label}`;
      if (seen.has(key)) continue;
      seen.add(key);
      transitions += 1;
      if (!out.has(from)) out.set(from, []);
      out.get(from)!.push({ from, to, label, input, key });
    }
  }
  return { shapes, byShape, vars, out, init: roots[0]!, edges, transitions };
}

/// The environment of every harness process: no sound, and a steering yield
/// that needs no grace, so a yield the walk asks for lands at once. The bridge
/// grace is not touched: it is the 1,000 ms the code defines.
export function harnessEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) if (value !== undefined) env[key] = value;
  env.FX_SOUND = "0";
  env.FX_TEST_STEER_YIELD_GRACE_MS = "0";
  return env;
}

/// The build step that adds the harness to a copy of build.zig. It uses the
/// product's own module wiring, so the harness imports the same session manager
/// and build options as fx.
const HARNESS_BUILD_ANCHOR = "    const session_manager = addSessionManager(b, exe.root_module, target, optimize, null, fuzz_corpora);\n";
const HARNESS_BUILD_BLOCK = `    const agent_harness_mod = b.createModule(.{
        .root_source_file = b.path("harness.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    _ = addSessionManager(b, agent_harness_mod, target, optimize, null, fuzz_corpora);
    agent_harness_mod.addImport("build_options", build_options.createModule());
    const agent_harness_exe = b.addExecutable(.{ .name = "agent-harness", .root_module = agent_harness_mod });
    const agent_harness_install = b.addInstallArtifact(agent_harness_exe, .{});
    b.step("agent-harness", "Build the agent wait harness").dependOn(&agent_harness_install.step);
`;

/// Builds the harness in `work`: a copy of src/, build.zig with the harness step,
/// and an optional planted bug written into the copy before the build.
export async function buildAgentHarness(work: string, plant?: { file: string; find: string; replace: string }): Promise<string> {
  mkdirSync(join(work, "tests"), { recursive: true });
  cpSync(join(REPO_ROOT, "src"), join(work, "src"), { recursive: true });
  cpSync(join(REPO_ROOT, "tests", "fuzz"), join(work, "tests", "fuzz"), { recursive: true });
  copyFileSync(join(REPO_ROOT, "build.zig"), join(work, "build.zig"));
  copyFileSync(join(REPO_ROOT, "build.zig.zon"), join(work, "build.zig.zon"));
  copyFileSync(HARNESS_SOURCE, join(work, "harness.zig"));
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
  const build_ = Bun.spawnSync(
    ["zig", "build", "agent-harness", "--cache-dir", join(REPO_ROOT, ".zig-cache")],
    { cwd: work, stdout: "pipe", stderr: "pipe" },
  );
  const bin = join(work, "zig-out", "bin", "agent-harness");
  if (build_.exitCode !== 0 || !existsSync(bin)) {
    throw new Error(`harness build failed in ${work}:\n${build_.stderr.toString()}${build_.stdout.toString()}`);
  }
  return bin;
}

/// A new, empty home folder for one harness process.
export function newHome(dir: string): string {
  mkdirSync(dir, { recursive: true });
  return dir;
}
