// Runs the built fx binary along tests/tla/skills/SkillWalk.tla and has TLC
// check every run it observes (SkillWalkTrace.tla).
//
// Each run builds one folder layout under the system temp folder: a chain of
// folders f0/f1/.../f<depth>, each with its own skill in
// `skills/walk-p<i>/SKILL.md` (a workspace-only root, so no global root can
// list it), and runs `fx ask` from the deepest folder against a local fake
// gateway. HOME is one of the chain folders, a folder beside the chain, or a
// folder beside a chain folder whose path is a string prefix of it (`.../f`
// beside `.../f1`). Every subset of the chain folders holds `.git`: a
// directory from `git init` at even depths, a linked-worktree `.git` file at
// odd ones. The driver runs every layout up to --depth, reads which chain
// skills the first request advertised, and has TLC replay the runs through the
// model's own Walk action. --self-check also replays them through the model of
// fx before the change (Rule = "today"), which must reject them.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/skills/driver.ts
//   bun tests/tla/drivers/skills/driver.ts --self-check
//   bun tests/tla/drivers/skills/driver.ts --depth 3 --jobs 8
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { existsSync, lstatSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Home = { kind: "at" | "elsewhere" | "prefix"; pos: number };
type Layout = { depth: number; home: Home; gits: number[] };
type Observation = Layout & {
  id: string;
  listed: number[];
  evidence: { exit: number; answered: boolean; requests: number; seconds: number; stderr: string };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const MODEL = "openai/gpt-5.5";
const DONE = "SKILL_WALK_DRIVER_DONE";
const tlaDir = join(TLA_ROOT, "skills");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 1) throw new Error(`${name} takes a whole number above 0`);
  return value;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  depth: option("--depth", 2),
  jobs: option("--jobs", 4),
};

function layouts(maxDepth: number): Layout[] {
  const result: Layout[] = [];
  for (let depth = 1; depth <= maxDepth; depth++) {
    const homes: Home[] = [];
    for (let pos = 0; pos <= depth; pos++) homes.push({ kind: "at", pos });
    homes.push({ kind: "elsewhere", pos: 0 });
    for (let pos = 1; pos <= depth; pos++) homes.push({ kind: "prefix", pos });
    for (const home of homes) {
      for (let mask = 0; mask < 1 << (depth + 1); mask++) {
        const gits: number[] = [];
        for (let pos = 0; pos <= depth; pos++) if (mask & (1 << pos)) gits.push(pos);
        result.push({ depth, home, gits });
      }
    }
  }
  return result;
}

/// The nearest folder at or above `path` that holds `.git`, or null.
function repositoryAbove(path: string): string | null {
  let current = path;
  for (;;) {
    try {
      lstatSync(join(current, ".git"));
      return current;
    } catch {
      // No .git here.
    }
    const parent = dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

function git(args: string[], home: string) {
  const result = Bun.spawnSync(["git", ...args], {
    env: { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, GIT_CONFIG_NOSYSTEM: "1", LC_ALL: "C" },
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed: ${result.stderr.toString()}`);
}

async function runLayout(
  helpers: any,
  id: string,
  layout: Layout,
  scratch: string,
): Promise<Observation> {
  const root = mkdtempSync(join(scratch, `${id}-`));
  const folders: string[] = [];
  let folder = root;
  for (let pos = 0; pos <= layout.depth; pos++) {
    folder = join(folder, `f${pos}`);
    folders.push(folder);
    const skill = join(folder, "skills", `walk-p${pos}`);
    mkdirSync(skill, { recursive: true });
    writeFileSync(join(skill, "SKILL.md"), `---\nname: walk-p${pos}\ndescription: walk-p${pos} fixture\n---\n\nbody\n`);
  }
  const store = join(root, "store");
  const toolHome = join(root, "git-home");
  mkdirSync(toolHome, { recursive: true });
  if (layout.gits.some((pos) => pos % 2 === 1)) git(["init", "-q", "--template=", store], toolHome);
  for (const pos of layout.gits) {
    if (pos % 2 === 0) git(["init", "-q", "--template=", folders[pos]!], toolHome);
    else writeFileSync(join(folders[pos]!, ".git"), `gitdir: ${join(store, ".git")}\n`);
  }
  const home = layout.home.kind === "at"
    ? folders[layout.home.pos]!
    : layout.home.kind === "prefix"
      ? join(dirname(folders[layout.home.pos]!), "f")
      : join(root, "home");
  mkdirSync(join(home, ".fx", "skills"), { recursive: true });
  const fxHome = join(root, "fx-home");
  mkdirSync(join(fxHome, "skills"), { recursive: true });
  writeFileSync(join(fxHome, "settings.json"), "{}");

  const gateway = helpers.startDynamicFakeGateway(() => helpers.fakeGatewayFinalText(DONE), {
    models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
  });
  try {
    const started = performance.now();
    const child = Bun.spawn([binary, "ask", "--json", "--auto", "--no-save", "Say done."], {
      cwd: folders[layout.depth]!,
      env: testEnvironment({
        HOME: home,
        FX_HOME: fxHome,
        AI_GATEWAY_API_KEY: "fake-skill-walk-driver-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: MODEL,
      }),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 60_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
    const requests = gateway.requestCount();
    const body: string = requests > 0 ? gateway.requests[0].body : "";
    const listed = new Set<number>();
    for (const match of body.matchAll(/- walk-p(\d+): walk-p\1 fixture/g)) listed.add(Number(match[1]));
    return {
      id,
      ...layout,
      listed: [...listed].sort((a, b) => a - b),
      evidence: { exit, answered: exit === 0 && stdout.includes(DONE), requests, seconds, stderr: stderr.trim().slice(-400) },
    };
  } finally {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

function tlaSet(values: number[]): string {
  return `{${values.join(", ")}}`;
}

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[depth |-> ${o.depth}, home |-> [kind |-> "${o.home.kind}", pos |-> ${o.home.pos}], ` +
    `gits |-> ${tlaSet(o.gits)}, listed |-> ${tlaSet(o.listed)}]`;
  return [
    "--------------------------- MODULE SkillWalkObserved ---------------------------",
    "(* Generated by tests/tla/drivers/skills/driver.ts. Do not edit. *)",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], rule: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${rule}-`));
  writeFileSync(join(dir, "SkillWalkObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  MaxDepth = ${options.depth}`,
    `  Rule = "${rule}"`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "SkillWalkTrace.tla", "trace.cfg", ["SkillWalk.tla", "SkillWalkTrace.tla"], tlaDir);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("No error has been found")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], rule: string, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), rule, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function main(): Promise<number> {
  if (!existsSync(binary)) {
    console.log(`TOOL_ERROR: missing ${binary}; run zig build first or set FX_BIN`);
    return 2;
  }
  const helpers = await targetHelpers();
  const out = outDir("skills");
  const scratch = realpathSync(join(out, "."));
  mkdirSync(join(scratch, "layouts"), { recursive: true });
  const layoutsRoot = join(scratch, "layouts");
  // A repository above the layouts would be the nearest one for every layout.
  const outer = repositoryAbove(layoutsRoot);
  if (outer) {
    console.log(`TOOL_ERROR: ${layoutsRoot} is inside the repository at ${outer}; set FX_TLA_OUT to a folder outside any repository`);
    return 2;
  }
  const cases = layouts(options.depth);
  const observations: Observation[] = new Array(cases.length);
  const started = performance.now();
  let next = 0;
  const workers = Array.from({ length: options.jobs }, async () => {
    while (next < cases.length) {
      const index = next++;
      let observation = await runLayout(helpers, `layout${index}`, cases[index]!, layoutsRoot);
      // A run that never reached the gateway says nothing about the walk; it
      // runs once more and then counts as a harness failure.
      if (observation.evidence.requests !== 1 || !observation.evidence.answered) {
        console.log(`harness retry: ${observation.id} ${JSON.stringify(observation.evidence)}`);
        observation = await runLayout(helpers, `layout${index}`, cases[index]!, layoutsRoot);
      }
      observations[index] = observation;
    }
  });
  await Promise.all(workers);
  rmSync(layoutsRoot, { recursive: true, force: true });
  writeJson(join(out, "observations.json"), observations);
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  console.log(`${observations.length} layouts up to depth ${options.depth} with ${binary} in ${seconds}s`);
  console.log(`observations: ${join(out, "observations.json")}`);
  const broken = observations.find((o) => o.evidence.requests !== 1 || !o.evidence.answered);
  if (broken) {
    console.log(`TOOL_ERROR: ${broken.id} did not finish one request against the fake gateway: ${JSON.stringify(broken)}`);
    return 2;
  }

  const design = await runTrace(observations, "fixed", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, "fixed", out);
    console.log(`first run the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await runTrace(observations, "today", out);
    console.log(`self-check, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
  }
  console.log("ACCEPTED");
  return 0;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
