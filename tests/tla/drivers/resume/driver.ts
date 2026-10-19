// Walks the real fx TUI along tests/tla/recovery/Resume.tla, one fx process at
// a time.
//
// TLC writes Resume.tla's state graph with MaxReq = 2, and the driver keeps the
// states in which process 2 never runs. Between quiet states, where process 1
// is off, idle, asking, or has a request on the wire, fx's own steps (saving,
// sending, committing, deleting, exiting) are collapsed. What is left are the
// driver's steps, each one thing a user or the system does: launch fx, send a
// message, let the response finish, close the window (SIGHUP), kill fx
// (SIGKILL), quit, send "continue", or let a day pass.
//
// The driver covers every step from every observable class of quiet state
// along a shortest path. It runs each walk against the built binary in tmux,
// with a fake gateway that holds every response until the walk releases it.
// After every step, what fx keeps on disk, whether a request is on the wire,
// and, at a launch, the question fx shows must match one of the model states
// that step can reach. The driver then follows only those.
//
// It compares whether recovery.json and recovery.state exist, and whether a
// record with a send in flight or a wait is marked clean, which decides
// whether the next launch counts a death. It compares neither the record's
// phase nor its death count: fx shows the crash-loop question without saving
// it as a `need_user` record, which the model does, and a close at that
// question leaves the earlier record as it was. What the user sees next is the
// same: the next launch asks again.
//
// Runs on request (decision 57), from the repository root after `zig build`:
//   bun tests/tla/drivers/resume/driver.ts
//   bun tests/tla/drivers/resume/driver.ts --walks 5
//   bun tests/tla/drivers/resume/driver.ts --walks 5 --self-check
//   bun tests/tla/drivers/resume/driver.ts --grep "kill launch close"
//
// --self-check also reruns one walk with the expected clean flag inverted for
// every saved record, which the driver must reject.
//
// Exit codes: 0 every walk matched, 1 a mismatch, 2 a toolchain or setup
// failure.

import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { TLA_ROOT, outDir, runTlc } from "../lib/tlc";
import { binary, targetHelpers } from "../lib/context";

type Model = Record<string, any>;
type Edge = { to: string; label: string };
type Graph = { states: Map<string, Model>; next: Map<string, Edge[]>; init: string };
type Step = "launch" | "prompt" | "release" | "close" | "kill" | "quit" | "continue" | "day";
// `clean` is null where the model's record is not a send in flight or a wait.
type Obs = { running: boolean; snap: boolean; record: boolean; clean: boolean | null; flight: boolean; question?: string };

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

// The model.

async function loadGraph(): Promise<Graph> {
  const dir = join(out, "graph");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Driver.cfg"), [
    "INIT Init", "NEXT Next", "CONSTANTS",
    `    Policy = "proposed"`, "    AskProcs = {}", "    MaxReq = 2", "    MaxFaults = 3",
    `    DeathCount = "seen"`, `    Bug = "none"`, "",
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

const onlyFirst = (s: Model) => proc(s, 2).pc === "off" && s.lock !== 2;
const quiet = (s: Model) =>
  ["off", "idle", "ask", "flight"].includes(proc(s, 1).pc) && proc(s, 1).pend.ph === "none";
const currentSnap = (s: Model) => s.snap > 0 && s.snap === s.log + 1;

// fx's own steps between two quiet states.
const internal = new Set(["WriteRec", "Sync", "SendOut", "Commit", "DelSnap", "DelRec", "End2", "ExitClean", "Settle"]);

// The model actions each driver step starts with, in order; fx's own steps
// run between them.
const stepActions: Record<Step, string[][]> = {
  launch: [["Launch"]],
  prompt: [["StartReq"]],
  release: [["ArriveOk"]],
  close: [["ProposedClose"]],
  kill: [["Die"]],
  quit: [["Quit"], ["Esc", "Quit"]],
  continue: [["MoveOn", "StartReq"]],
  day: [["DayPasses"]],
};

// When the driver takes a step at all, beyond what the model allows.
function allowed(step: Step, s: Model): boolean {
  const p = proc(s, 1);
  switch (step) {
    case "launch": return p.pc === "off";
    case "prompt": return p.pc === "idle";
    case "release": return p.pc === "flight";
    case "close": return ["idle", "ask", "flight"].includes(p.pc);
    case "kill": return p.pc !== "off";
    case "quit": return ["idle", "ask", "flight"].includes(p.pc);
    case "continue": return ["idle", "ask"].includes(p.pc) && currentSnap(s);
    case "day": return p.pc === "off" && s.rec.ph !== "none" && s.wall === 0;
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
    const state = graph.states.get(id)!;
    if (quiet(state)) {
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
  const result = new Set<string>();
  for (const sequence of stepActions[step]) {
    let frontier = new Set([id]);
    for (const label of sequence) {
      const moved = new Set<string>();
      for (const from of frontier) for (const to of successors(graph, from, label)) moved.add(to);
      frontier = settle(graph, moved);
    }
    for (const target of frontier) result.add(target);
  }
  return result;
}

function expected(s: Model): Obs {
  const p = proc(s, 1);
  return {
    running: p.pc !== "off",
    snap: s.snap > 0,
    record: s.rec.ph !== "none",
    clean: ["sending", "waiting"].includes(s.rec.ph) ? (s.rec.clean === true) !== tampered : null,
    flight: p.pc === "flight",
    question: p.pc === "off" ? "none" : p.q,
  };
}

// A class of quiet states the driver tells apart, plus what decides where
// they lead: requests used, deaths seen, and the clock.
function stateClass(s: Model): string {
  const p = proc(s, 1);
  return JSON.stringify([expected(s), p.pc, s.log, s.seen, s.wall, s.faults, s.rec.deaths ?? 0]);
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

type Hold = { state: "open" | "released" | "cancelled"; finish: (text: string) => void };

class Run {
  root = realpathSync(join(out, "runs"));
  home = "";
  workspace = "";
  session: any = null;
  gateway: any;
  holds: Hold[] = [];
  sessionId: string | null = null;
  released = 0;
  launches = 0;

  constructor(readonly helpers: any, readonly index: number) {
    const base = join(this.root, `walk-${index}`);
    this.home = join(base, "home");
    this.workspace = join(base, "workspace");
    mkdirSync(join(this.home, ".fx"), { recursive: true });
    mkdirSync(this.workspace, { recursive: true });
    writeFileSync(join(this.home, ".fx", "settings.json"), "{}");
    this.gateway = helpers.startDynamicFakeGateway(() => this.heldResponse());
  }

  heldResponse(): Response {
    const encoder = new TextEncoder();
    let controller: ReadableStreamDefaultController<Uint8Array> | undefined;
    let timer: ReturnType<typeof setInterval> | undefined;
    const hold: Hold = {
      state: "open",
      finish: (text: string) => {
        if (hold.state !== "open" || !controller) return;
        hold.state = "released";
        if (timer) clearInterval(timer);
        controller.enqueue(encoder.encode(
          `data: ${JSON.stringify({ type: "text-delta", id: "answer_1", delta: text })}\n\n` +
            `data: ${JSON.stringify({ type: "finish", finishReason: { unified: "stop", raw: "stop" } })}\n\n` +
            "data: [DONE]\n\n",
        ));
        controller.close();
      },
    };
    this.holds.push(hold);
    return new Response(new ReadableStream<Uint8Array>({
      start(value) {
        controller = value;
        timer = setInterval(() => {
          if (hold.state === "open") value.enqueue(encoder.encode(": hold\n\n"));
        }, 50);
      },
      cancel() {
        if (hold.state === "open") hold.state = "cancelled";
        if (timer) clearInterval(timer);
      },
    }), { headers: { "content-type": "text/event-stream" } });
  }

  openHold(): Hold | undefined {
    return this.holds.find((hold) => hold.state === "open");
  }

  sessionDir(): string | null {
    if (!this.sessionId) {
      const sessions = join(this.home, ".fx", "sessions");
      if (!existsSync(sessions)) return null;
      const ids = readdirSync(sessions, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
      if (ids.length === 0) return null;
      this.sessionId = ids[0]!;
    }
    return join(this.home, ".fx", "sessions", this.sessionId);
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

  async launch(): Promise<string> {
    this.launches += 1;
    const before = this.holds.length;
    this.session = await this.helpers.TmuxSession.create({
      ...(this.sessionId ? { cmd: `${binary} --resume ${this.sessionId}` } : {}),
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
        FX_MODEL: this.helpers.FAKE_GATEWAY_MODEL,
        FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
        FX_E2E_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      },
    });
    await this.session.waitForComposer(timeoutMs);
    // A resend goes out at once, so a short wait tells the two apart.
    const deadline = Date.now() + 2_000;
    while (this.holds.length === before && Date.now() < deadline) await Bun.sleep(25);
    const screen = (await this.session.captureFullScrollback()).replaceAll(/\s+/g, " ");
    if (screen.includes("crashed fx twice")) return "crash";
    if (screen.includes("more than a day ago")) return "old";
    if (screen.includes("not restarted")) return "notice";
    return "none";
  }

  async send(text: string) {
    const before = this.holds.length;
    await this.session.sendText(text);
    await this.waitFor(() => this.holds.length > before && this.openHold() !== undefined, `a request for "${text}"`);
  }

  async release() {
    const hold = this.openHold();
    if (!hold) throw new Error("no request on the wire to release");
    this.released += 1;
    const text = `RESUME_DRIVER_DONE_${this.released}`;
    hold.finish(text);
    await this.session.waitForText(text, timeoutMs);
    await this.waitFor(() => !existsSync(join(this.sessionDir()!, "recovery.json")), "the committed turn");
  }

  async end(signal: "HUP" | "KILL" | null) {
    if (signal) {
      Bun.spawnSync(["kill", `-${signal}`, String(this.session.processPid())]);
    } else if (this.openHold()) {
      this.session.sendKeysImmediate(["C-c", "C-c"]);
    } else {
      await this.session.sendText("/quit");
    }
    await this.session.waitForPane(() => this.session.paneStatus().dead, timeoutMs);
    await this.session.kill();
    this.session = null;
  }

  dayPasses() {
    const record = join(this.sessionDir()!, "recovery.state");
    const twoDaysAgo = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000);
    utimesSync(record, twoDaysAgo, twoDaysAgo);
  }

  async observe(question?: string): Promise<Obs> {
    const dir = this.sessionDir();
    const recordPath = dir ? join(dir, "recovery.state") : null;
    const bytes = recordPath && existsSync(recordPath) ? readFileSync(recordPath) : null;
    const running = this.running();
    return {
      running,
      snap: dir !== null && existsSync(join(dir, "recovery.json")),
      record: bytes !== null,
      clean: bytes !== null && bytes.length === 32 && (bytes[2]! & 1) === 1,
      flight: running && this.openHold() !== undefined,
      ...(question !== undefined ? { question } : {}),
    };
  }

  async take(step: Step): Promise<Obs> {
    switch (step) {
      case "launch": return this.observe(await this.launch());
      case "prompt": await this.send("Work on the report."); break;
      case "continue": await this.send("continue"); break;
      case "release": await this.release(); break;
      case "close": await this.end("HUP"); break;
      case "kill": await this.end("KILL"); break;
      case "quit": await this.end(null); break;
      case "day": this.dayPasses(); break;
    }
    return this.observe();
  }

  async close() {
    if (this.session) await this.session.kill();
    for (const hold of this.holds) if (hold.state === "open") hold.state = "cancelled";
    this.gateway.stop();
  }
}

function matches(model: Obs, real: Obs): boolean {
  return model.running === real.running && model.snap === real.snap && model.record === real.record &&
    (model.clean === null || model.clean === real.clean) && model.flight === real.flight &&
    (real.question === undefined || model.question === real.question);
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
  if (result) {
    mismatches.push(result);
    console.log(`  mismatch: ${result}`);
  }
}
if (selfCheck) {
  const probe = planned.filter((steps) => steps.includes("close")).sort((a, b) => a.length - b.length)[0];
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
