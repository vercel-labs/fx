// Walks the real fx TUI along tests/tla/recovery/Resume.tla, one fx process at
// a time.
//
// TLC writes Resume.tla's state graph for the proposed design, and the driver
// keeps the states in which process 2 never runs. Between quiet states, where
// process 1 is off, idle, asking, or has a request on the wire, fx's own steps
// (saving and sending, committing, running the tools, retrying) are collapsed.
// What is left are the driver's steps, each one thing a user or the system
// does: launch fx (`fx`, then `fx -c`), send a message, let the response
// finish, answer it with a tool call, cut the stream short, close the window
// (SIGHUP), kill fx (SIGKILL), quit, press Esc or Enter, or send "continue".
// A day passing is left out: a log line's time is under its checksum, and the
// recovery module's own tests cover the day-old question.
//
// The driver covers every step from every observable class of quiet state
// along a shortest path. It runs each walk against the built binary in tmux,
// with a fake gateway that holds every response until the walk releases it.
// After every step, what fx keeps in the session log, whether a request is on
// the wire, and the question fx shows must match one of the model states that
// step can reach. The driver then follows only those. From the log it reads
// how the newest turn ended and that turn's newest `recovery` piece, decoded
// as `src/core/recovery/recovery.zig` encodes it: the phase, the clean flag,
// the abrupt-death count, and the question a waiting record asks.
//
// Runs on request, from the repository root after `zig build`:
//   bun tests/tla/drivers/resume/driver.ts
//   bun tests/tla/drivers/resume/driver.ts --walks 5
//   bun tests/tla/drivers/resume/driver.ts --walks 5 --self-check
//   bun tests/tla/drivers/resume/driver.ts --grep "kill launch kill launch"
//
// --self-check also reruns one walk with the expected clean flag inverted for
// every saved record, which the driver must reject.
//
// Exit codes: 0 every walk matched, 1 a mismatch, 2 a toolchain or setup
// failure.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { parseValue } from "../graph.mjs";
import { TLA_ROOT, outDir, runTlc } from "../lib/tlc";
import { binary, targetHelpers } from "../lib/context";

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; init: string };
type Step =
  | "launch" | "prompt" | "release" | "tool" | "fail" | "close" | "kill" | "quit" | "esc" | "enter" | "continue";
type Obs = {
  running: boolean;
  flight: boolean;
  question: string;
  turn: string;
  ph: string;
  clean: boolean | null;
  deaths: number | null;
  need: string | null;
};

function fail(code: number, message: string): never {
  console.error(message);
  process.exit(code);
}

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) fail(2, `${name} takes a whole number`);
  return value;
}

const maxWalks = option("--walks", Number.MAX_SAFE_INTEGER);
const selfCheck = process.argv.includes("--self-check");
// Only the walks whose steps contain this sequence, such as "kill launch close".
const grep = process.argv.includes("--grep") ? process.argv[process.argv.indexOf("--grep") + 1] ?? "" : "";
// --self-check's planted defect in the expectation.
let tampered = false;
const timeoutMs = 20_000;
const out = outDir("resume-driver");
const resumeNote = "<session_resumed>";

// The model.

async function loadGraph(): Promise<Graph> {
  const dir = join(out, "graph");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), [
    "INIT Init", "NEXT Next", "CONSTANTS",
    `    Policy = "proposed"`, "    MaxReq = 2", "    MaxFaults = 3", `    Bug = "none"`, "",
  ].join("\n"));
  const run = await runTlc(dir, "Resume", "Driver.cfg", ["Resume.tla"], join(TLA_ROOT, "recovery"),
    ["-dump", "dot,actionlabels", "graph"]);
  if (run.exitCode !== 0) fail(2, `TLC failed on Resume.tla (exit ${run.exitCode}); see ${join(dir, "tlc.log")}`);
  const states = new Map<string, Model>();
  const next = new Map<string, Edge[]>();
  let init = "";
  const unescape = (label: string) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  for (const line of readFileSync(join(dir, "graph.dot"), "utf8").split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      const [, from, to, label] = edge;
      if (!next.has(from!)) next.set(from!, []);
      next.get(from!)!.push({ to: to!, label: label! });
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"(.*)$/.exec(line);
    if (!node) continue;
    const [, id, label, rest] = node;
    const state: Model = {};
    for (const entry of unescape(label!).split(/\n(?=\/\\ )/)) {
      const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
      if (match) state[match[1]!] = parseValue(match[2]!.trim());
    }
    states.set(id!, state);
    if (/style\s*=\s*filled/.test(rest!)) init = id!;
  }
  if (!init) fail(2, "the graph has no initial state");
  console.log(`graph: ${states.size} states, ${run.durationMs} ms`);
  return { states, next, init };
}

function proc(s: Model, p: 1 | 2): Model {
  return Array.isArray(s.ps) ? s.ps[p - 1] : s.ps[p] ?? s.ps[String(p)];
}

const holds = (s: Model, p: number) => (Array.isArray(s.lock) ? s.lock.includes(p) : false);
const onlyFirst = (s: Model) => proc(s, 2).pc === "off" && !holds(s, 2) && s.wall === 0;
const quiet = (s: Model) => ["off", "idle", "ask", "flight", "need"].includes(proc(s, 1).pc);

// fx's own steps between two quiet states.
const internal = new Set(["Save", "Finish", "ToolsDone", "Retry"]);

// The model actions each driver step starts with, and which of its first
// action's targets the step means.
const stepActions: Record<Step, { labels: string[]; pick?: (s: Model) => boolean }> = {
  launch: { labels: ["Launch"] },
  prompt: { labels: ["Prompt"] },
  release: { labels: ["Respond"], pick: (s) => s.turn.work === "final" },
  tool: { labels: ["Respond"], pick: (s) => s.turn.work === "tools" },
  fail: { labels: ["Fail"] },
  close: { labels: ["Close"] },
  kill: { labels: ["Kill"] },
  quit: { labels: ["Quit"] },
  esc: { labels: ["Esc"] },
  enter: { labels: ["Enter"] },
  continue: { labels: ["UserContinue"] },
};

// When the driver takes a step at all, beyond what the model allows.
function allowed(step: Step, s: Model): boolean {
  const pc = proc(s, 1).pc;
  switch (step) {
    case "launch": return pc === "off";
    case "prompt": case "continue": return pc === "idle";
    case "release": case "tool": case "fail": return pc === "flight";
    case "close": case "kill": case "quit": return ["idle", "ask", "flight"].includes(pc);
    case "esc": return ["ask", "flight"].includes(pc);
    case "enter": return pc === "ask";
  }
}

function successors(graph: Graph, id: string, label: string): string[] {
  return (graph.next.get(id) ?? [])
    .filter((edge) => edge.label === label && edge.to !== id && onlyFirst(graph.states.get(edge.to)!))
    .map((edge) => edge.to);
}

// The quiet states fx's own steps reach from `ids`.
function settle(graph: Graph, ids: Set<string>): Set<string> {
  const reached = new Set<string>();
  const seen = new Set<string>(ids);
  const queue = [...ids];
  while (queue.length > 0) {
    const id = queue.pop()!;
    if (quiet(graph.states.get(id)!)) {
      reached.add(id);
      continue;
    }
    for (const edge of graph.next.get(id) ?? []) {
      if (!internal.has(edge.label) || seen.has(edge.to) || !onlyFirst(graph.states.get(edge.to)!)) continue;
      seen.add(edge.to);
      queue.push(edge.to);
    }
  }
  return reached;
}

// The quiet states one driver step can reach from quiet state `id`.
function stepTargets(graph: Graph, id: string, step: Step): Set<string> {
  if (!allowed(step, graph.states.get(id)!)) return new Set();
  const { labels, pick } = stepActions[step];
  let frontier = new Set([id]);
  for (const [at, label] of labels.entries()) {
    const moved = new Set<string>();
    for (const from of frontier) {
      for (const to of successors(graph, from, label)) {
        if (at === 0 && pick && !pick(graph.states.get(to)!)) continue;
        moved.add(to);
      }
    }
    frontier = settle(graph, moved);
  }
  return frontier;
}

// What fx should show and keep in a quiet state. A record counts only in a
// turn that a crash or a close left unended.
function expected(s: Model): Obs {
  const p = proc(s, 1);
  const turn = s.turn.req === 0 ? "none" : s.turn.st;
  const rec = ["open", "crash"].includes(turn) ? s.turn.rec : { ph: "none" };
  return {
    running: p.pc !== "off",
    flight: p.pc === "flight",
    question: ["ask", "need"].includes(p.pc) ? p.q : "none",
    // The log has no end for an open turn until a launch ends it.
    turn: turn === "crash" ? "crash" : turn,
    ph: rec.ph,
    clean: ["sending", "waiting"].includes(rec.ph) ? (rec.clean === true) !== tampered : null,
    deaths: rec.ph === "none" ? null : rec.deaths,
    need: rec.ph === "need" ? rec.need : null,
  };
}

// A class of quiet states the driver tells apart, plus what decides where
// they lead: deaths seen, disruptions so far, and the turn's work.
function stateClass(s: Model): string {
  const p = proc(s, 1);
  return JSON.stringify([expected(s), p.pc, p.md, s.seen, s.faults, s.turn.work]);
}

// One walk per (class, step): the shortest step path from the initial state
// to a state of that class, then the step.
function planWalks(graph: Graph): Step[][] {
  const start = [...settle(graph, new Set([graph.init]))][0] ?? graph.init;
  const steps = Object.keys(stepActions) as Step[];
  const parent = new Map<string, { from: string; step: Step } | null>([[start, null]]);
  const queue = [start];
  for (let at = 0; at < queue.length; at += 1) {
    const id = queue[at]!;
    for (const step of steps) {
      for (const to of stepTargets(graph, id, step)) {
        if (parent.has(to)) continue;
        parent.set(to, { from: id, step });
        queue.push(to);
      }
    }
  }
  const pathTo = (id: string): Step[] => {
    const path: Step[] = [];
    for (let at = parent.get(id); at; at = parent.get(at.from)) path.unshift(at.step);
    return path;
  };
  const walks: Step[][] = [];
  const covered = new Set<string>();
  for (const id of queue) {
    const state = graph.states.get(id)!;
    for (const step of steps) {
      if (stepTargets(graph, id, step).size === 0) continue;
      const key = `${stateClass(state)}|${step}`;
      if (covered.has(key)) continue;
      covered.add(key);
      walks.push([...pathTo(id), step]);
    }
  }
  // A walk that is a prefix of a longer one adds nothing.
  const unique = [...new Set(walks.map((walk) => walk.join(" ")))];
  return unique
    .filter((walk) => !unique.some((other) => other !== walk && other.startsWith(`${walk} `)))
    .map((walk) => walk.split(" ") as Step[]);
}

// The real fx.

type Hold = {
  state: "open" | "released" | "cancelled";
  resumed: boolean;
  finish: (body: string) => void;
  drop: () => void;
};

const phases: Record<number, string> = { 1: "sending", 2: "waiting", 3: "need" };
const needs: Record<number, string> = { 6: "crash", 7: "old" };

class Run {
  root = realpathSync(join(out, "runs"));
  home = "";
  workspace = "";
  session: any = null;
  gateway: any;
  holdsOpen: Hold[] = [];
  released = 0;
  launches = 0;

  constructor(readonly helpers: any, readonly index: number) {
    const base = join(this.root, `walk-${index}`);
    this.home = join(base, "home");
    this.workspace = join(base, "workspace");
    mkdirSync(join(this.home, ".fx"), { recursive: true });
    mkdirSync(this.workspace, { recursive: true });
    writeFileSync(
      join(this.home, ".fx", "settings.json"),
      JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {} }),
    );
    this.gateway = helpers.startDynamicFakeGateway((body: string) => this.heldResponse(body));
  }

  heldResponse(body: string): Response {
    // The fake gateway answers title and permission requests itself.
    const encoder = new TextEncoder();
    let controller: ReadableStreamDefaultController<Uint8Array> | undefined;
    let timer: ReturnType<typeof setInterval> | undefined;
    const stop = () => {
      if (timer) clearInterval(timer);
    };
    const hold: Hold = {
      state: "open",
      resumed: body.includes(resumeNote),
      finish: (text: string) => {
        if (hold.state !== "open" || !controller) return;
        hold.state = "released";
        stop();
        controller.enqueue(encoder.encode(text));
        controller.close();
      },
      drop: () => {
        if (hold.state !== "open" || !controller) return;
        hold.state = "released";
        stop();
        controller.error(new Error("stream cut short by the resume driver"));
      },
    };
    this.holdsOpen.push(hold);
    return new Response(new ReadableStream<Uint8Array>({
      start(value) {
        controller = value;
        timer = setInterval(() => {
          if (hold.state === "open") value.enqueue(encoder.encode(": hold\n\n"));
        }, 50);
      },
      cancel() {
        if (hold.state === "open") hold.state = "cancelled";
        stop();
      },
    }), { headers: { "content-type": "text/event-stream" } });
  }

  openHold(): Hold | undefined {
    return this.holdsOpen.find((hold) => hold.state === "open");
  }

  logPath(): string | null {
    const store = join(this.home, ".fx", "sessions", "v2");
    if (!existsSync(store)) return null;
    const ids = readdirSync(store).filter((name) => !name.startsWith(".") && !name.startsWith("index"));
    if (ids.length === 0) return null;
    const path = join(store, ids[0]!, "log.jsonl");
    return existsSync(path) ? path : null;
  }

  // The newest turn: how it ended, and its newest `recovery` piece.
  newestTurn(): { turn: string; record: Uint8Array | null } {
    const path = this.logPath();
    if (!path) return { turn: "none", record: null };
    const text = readFileSync(path, "utf8");
    const lines = text.slice(0, text.lastIndexOf("\n") + 1).split("\n").filter(Boolean).map((line) => JSON.parse(line));
    let start = -1;
    for (const [at, line] of lines.entries()) if (line.kind === "turn_started") start = at;
    if (start < 0) return { turn: "none", record: null };
    let turn = "open";
    let record: Uint8Array | null = null;
    for (const line of lines.slice(start + 1)) {
      if (line.kind === "turn_committed") turn = "done";
      if (line.kind === "turn_interrupted") turn = ["crash", "closed"].includes(line.reason) ? "crash" : "cancel";
      if (line.kind === "item" && line.type === "recovery") {
        const hex = line.data?.record;
        record = typeof hex === "string" ? Uint8Array.from(Buffer.from(hex, "hex")) : null;
      }
    }
    return { turn, record };
  }

  running(): boolean {
    return this.session !== null && !this.session.paneStatus().dead;
  }

  async waitFor(condition: () => boolean, what: string, ms = timeoutMs) {
    const deadline = Date.now() + ms;
    while (!condition()) {
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
      await Bun.sleep(25);
    }
  }

  async launch() {
    this.launches += 1;
    const before = this.holdsOpen.length;
    this.session = await this.helpers.TmuxSession.create({
      cmd: this.logPath() ? `${binary} -c` : binary,
      cwd: this.workspace,
      stderrPath: join(this.root, `walk-${this.index}`, `stderr-${this.launches}.log`),
      width: 120,
      height: 40,
      remainOnExit: true,
      isolated: true,
      env: {
        HOME: this.home,
        AI_GATEWAY_API_KEY: "fake-resume-driver-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        NO_COLOR: "1",
        FX_MODEL: this.helpers.FAKE_GATEWAY_MODEL,
        FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      },
    });
    await this.session.waitForComposer(timeoutMs);
    // A resumed request goes out at once, so a short wait tells a resend
    // from a question or from nothing.
    const deadline = Date.now() + 2_500;
    while (this.holdsOpen.length === before && Date.now() < deadline) {
      if ((await this.question()) !== "none") break;
      await Bun.sleep(25);
    }
  }

  async question(): Promise<string> {
    if (!this.running()) return "none";
    const screen = (await this.session.capturePane()).replaceAll(/\s+/g, " ");
    if (screen.includes("crashed fx twice")) return "crash";
    if (screen.includes("more than a day ago")) return "old";
    return "none";
  }

  async send(text: string) {
    const before = this.holdsOpen.length;
    await this.session.sendText(text);
    await this.waitFor(() => this.holdsOpen.length > before && this.openHold() !== undefined, `a request for "${text}"`);
  }

  async release() {
    const hold = this.openHold();
    if (!hold) throw new Error("no request on the wire to release");
    this.released += 1;
    const text = `RESUME_DRIVER_DONE_${this.released}`;
    hold.finish(await this.helpers.fakeGatewayFinalText(text).text());
    await this.session.waitForText(text, timeoutMs);
    await this.waitFor(() => this.newestTurn().turn === "done", "the committed turn");
  }

  async tool() {
    const hold = this.openHold();
    if (!hold) throw new Error("no request on the wire to answer with a tool call");
    this.released += 1;
    const before = this.holdsOpen.length;
    hold.finish(await this.helpers.fakeShellRun(`resume-driver-${this.released}`, "true").text());
    // The tool runs and the turn's next request goes out.
    await this.waitFor(() => this.holdsOpen.length > before && this.openHold() !== undefined, "the request after the tool");
  }

  async drop() {
    const hold = this.openHold();
    if (!hold) throw new Error("no request on the wire to cut short");
    const before = this.holdsOpen.length;
    hold.drop();
    // The module waits a second, then sends again.
    await this.waitFor(() => this.holdsOpen.length > before && this.openHold() !== undefined, "the retry");
  }

  async end(signal: "HUP" | "KILL" | null) {
    if (signal) {
      Bun.spawnSync(["kill", `-${signal}`, String(this.session.processPid())]);
    } else if (this.openHold() || (await this.question()) !== "none") {
      this.session.sendKeysImmediate(["C-c", "C-c"]);
    } else {
      await this.session.sendText("/quit");
    }
    await this.session.waitForPane(() => this.session.paneStatus().dead, timeoutMs);
    await this.session.kill();
    this.session = null;
  }

  // Esc ends a question at once; a request on the wire takes it twice.
  async esc() {
    const presses = this.openHold() ? 2 : 1;
    for (let at = 0; at < presses; at += 1) {
      if (at > 0) await Bun.sleep(150);
      await this.session.sendKeys("Escape");
    }
    await this.waitFor(() => this.newestTurn().turn === "cancel", "the cancelled turn");
    await this.waitFor(() => this.openHold() === undefined, "the cancelled request");
    await this.session.waitForComposer(timeoutMs);
  }

  async enter() {
    const before = this.holdsOpen.length;
    await this.session.sendKeys("Enter");
    await this.waitFor(() => this.holdsOpen.length > before && this.openHold() !== undefined, "the request after Enter");
  }

  async observe(): Promise<Obs> {
    const running = this.running();
    const { turn, record } = this.newestTurn();
    const live = record !== null && record.length === 32 && ["open", "crash"].includes(turn);
    const ph = live ? phases[record![1]!] ?? "none" : "none";
    return {
      running,
      flight: running && this.openHold() !== undefined,
      question: await this.question(),
      turn,
      ph,
      clean: ["sending", "waiting"].includes(ph) ? (record![2]! & 1) === 1 : null,
      deaths: ph === "none" ? null : record![7]!,
      need: ph === "need" ? needs[record![3]!] ?? "other" : null,
    };
  }

  async take(step: Step): Promise<Obs> {
    switch (step) {
      case "launch": await this.launch(); break;
      case "prompt": await this.send("Work on the report."); break;
      case "continue": await this.send("continue"); break;
      case "release": await this.release(); break;
      case "tool": await this.tool(); break;
      case "fail": await this.drop(); break;
      case "close": await this.end("HUP"); break;
      case "kill": await this.end("KILL"); break;
      case "quit": await this.end(null); break;
      case "esc": await this.esc(); break;
      case "enter": await this.enter(); break;
    }
    return this.observe();
  }

  async close() {
    if (this.session) await this.session.kill();
    for (const hold of this.holdsOpen) if (hold.state === "open") hold.state = "cancelled";
    this.gateway.stop();
  }
}

function matches(model: Obs, real: Obs): boolean {
  return (Object.keys(model) as (keyof Obs)[]).every((key) => model[key] === real[key]);
}

// One walk: every step must reach a model state that matches fx.
async function walk(graph: Graph, helpers: any, index: number, steps: Step[]): Promise<string | null> {
  const run = new Run(helpers, index);
  let tracked = settle(graph, new Set([graph.init]));
  try {
    for (const [at, step] of steps.entries()) {
      const candidates = new Set<string>();
      for (const id of tracked) for (const to of stepTargets(graph, id, step)) candidates.add(to);
      if (candidates.size === 0) return null;
      const real = await run.take(step);
      const next = new Set([...candidates].filter((id) => matches(expected(graph.states.get(id)!), real)));
      if (next.size === 0) {
        const allowedObs = [...new Set([...candidates].map((id) => JSON.stringify(expected(graph.states.get(id)!))))];
        return `step ${at + 1} (${step}) of [${steps.join(", ")}]: fx showed ${JSON.stringify(real)}; the model allows ${allowedObs.join(" or ")}`;
      }
      tracked = next;
    }
    return null;
  } finally {
    await run.close();
  }
}

if (!existsSync(binary)) fail(2, `missing ${binary}; run zig build first`);
const helpers = await targetHelpers();
if (!helpers.tmuxAvailable()) fail(2, "tmux is not installed");
mkdirSync(join(out, "runs"), { recursive: true });
const graph = await loadGraph();
const planned = planWalks(graph);
const walks = planned.filter((steps) => ` ${steps.join(" ")} `.includes(` ${grep} `.replace(/ +/g, " "))).slice(0, maxWalks);
console.log(`walks: ${walks.length} of ${planned.length}, steps: ${walks.reduce((sum, w) => sum + w.length, 0)}`);

const mismatches: string[] = [];
const started = performance.now();
for (const [index, steps] of walks.entries()) {
  const result = await walk(graph, helpers, index, steps).catch((err) => `walk [${steps.join(", ")}]: ${err}`);
  console.log(`  ${result ? "mismatch" : "ok"}: ${steps.join(" ")}`);
  if (result) {
    mismatches.push(result);
    console.log(`    ${result}`);
  }
}
if (selfCheck) {
  const probe = planned.filter((steps) => steps.includes("close") && steps.at(-1) === "launch")
    .sort((a, b) => a.length - b.length)[0] ?? planned.find((steps) => steps.includes("close"));
  if (!probe) fail(2, "self-check: no planned walk closes fx");
  tampered = true;
  const result = await walk(graph, helpers, walks.length, probe).catch((err) => `${err}`);
  tampered = false;
  if (!result) {
    mismatches.push("self-check: a tampered expectation was not rejected");
    console.log("  self-check: a tampered expectation was not rejected");
  } else {
    console.log(`self-check: tampered expectation rejected (${result.split(":")[0]})`);
  }
}
writeFileSync(join(out, "walks.json"), JSON.stringify({ walks, mismatches }, null, 2));
const seconds = Math.round((performance.now() - started) / 1000);
if (mismatches.length > 0) {
  console.log(`${mismatches.length} of ${walks.length} walks did not match fx (${seconds} s); output in ${out}`);
  process.exit(1);
}
console.log(`ok: ${walks.length} walks matched fx in ${seconds} s; output in ${out}`);
