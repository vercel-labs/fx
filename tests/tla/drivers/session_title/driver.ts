// Runs the built fx binary along tests/tla/session_title/SessionTitle.tla and
// has TLC check every run it observes (SessionTitleTrace.tla).
//
// Each run is one schedule of the model's environment: another fx process
// refreshing the shared login (the old token kept or revoked by the gateway),
// the gateway revoking the stored token, the issuer failing or never
// answering, the gateway rejecting every token fx's own refreshes issue, and a
// second prompt interrupting the first turn. The driver plays the environment
// with a fake gateway, a fake issuer, and edits to ~/.fx/auth.json, then runs
// one surface of fx:
//
//   ask      fx ask, whose title request runs beside the turn
//   tui      the interactive terminal in tmux; the environment can act after launch
//   catalog  the interactive terminal's model list, reloaded by /model
//   acp      fx acp, a session/new followed by one session/prompt
//
// It records, in the order they happen, every title and model list request
// with the token it carried (as a version: 1 is the launch token, and each
// token the driver or the issuer creates takes the next number) and whether
// the gateway took it, every refresh the issuer answered, and how the title and
// the model list ended. TLC replays each run through the model's own actions.
//
// Modes:
//   (default)       every enumerated schedule; the design model must accept every run
//   --self-check    also replays each run through the model of fx before the change
//                   (Bug = "today"), which must reject at least one
//   --base          for a build without the change: the today model must accept
//                   every run and the design model must reject at least one
//   --fuzz N        N seeded random schedules with random delays at the gateway and
//                   the issuer; rejected schedules are saved under the output folder
//   --replay FILE   runs the schedules saved in FILE (a JSON array)
//   --stress N      N fx ask processes in one profile while the login rotates every
//                   50 ms; checks every rule on the observations and prints wall
//                   time and peak memory
//   --only a,b      limits the enumeration to these surfaces
//   --seed S, --jobs J
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/session_title/driver.ts --self-check
//   bun tests/tla/drivers/session_title/driver.ts --base
//   bun tests/tla/drivers/session_title/driver.ts --fuzz 60 --seed 7
//   bun tests/tla/drivers/session_title/driver.ts --stress 64
//
// Exit codes: 0 the mode's verdicts hold, 1 they do not, 2 a toolchain,
// build, or harness failure.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, targetModule, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, tlcToolchain, writeJson } from "../lib/tlc";

type Surface = "ask" | "tui" | "catalog" | "acp";
type EnvEvent = "rotate_keep" | "rotate_revoke" | "revoke";
type Schedule = {
  id: string;
  surface: Surface;
  refreshable: boolean;
  /// Environment steps after launch and before the prompt (for ask: before launch,
  /// where only revoke differs from a fresh login).
  before: EnvEvent[];
  /// Another fx refreshes the login when the first title request arrives.
  onFirstTitle: "none" | "rotate_keep" | "rotate_revoke";
  issuer: "up" | "down" | "slow";
  /// Whether the gateway still takes the old token after fx's own refresh.
  forceKeepsOld: boolean;
  /// The gateway rejects every token fx's own refreshes issue.
  rejectNew: boolean;
  /// tui: a second prompt interrupts the first turn.
  interrupt: boolean;
  /// Delays in ms at the gateway's title channel and at the issuer (fuzz).
  titleDelayMs: number;
  issuerDelayMs: number;
};
type Event = {
  kind: string;
  n?: number;
  tok?: number;
  ok?: boolean;
  keep?: boolean;
  prompt?: number;
  title?: string;
  catalog?: string;
  starts?: number;
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
type RunResult = {
  schedule: Schedule;
  events: Event[];
  design: Verdict;
  today: Verdict | null;
  seconds: number;
  error?: string;
};

const PROMPTS = ["refactor the renderer loop to fix the crash", "now write the regression test for it"];
const GENERATED_TITLE = "Renderer Loop Refactor";
const MODEL = "openai/gpt-5.5";
const tlaDir = join(TLA_ROOT, "session_title");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

function stringOption(name: string): string | null {
  const at = process.argv.indexOf(name);
  return at < 0 ? null : process.argv[at + 1] ?? null;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  base: process.argv.includes("--base"),
  fuzz: option("--fuzz", 0),
  stress: option("--stress", 0),
  seed: option("--seed", 1),
  jobs: option("--jobs", 4),
  replay: stringOption("--replay"),
  only: (stringOption("--only") ?? "ask,tui,catalog,acp").split(",") as Surface[],
};

// mulberry32: a small seeded generator, so a failing random schedule replays.
function generator(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function schedule(partial: Partial<Schedule> & { surface: Surface }): Schedule {
  const value: Schedule = {
    id: "",
    refreshable: true,
    before: [],
    onFirstTitle: "none",
    issuer: "up",
    forceKeepsOld: true,
    rejectNew: false,
    interrupt: false,
    titleDelayMs: 0,
    issuerDelayMs: 0,
    ...partial,
  };
  value.id = [
    value.surface,
    value.refreshable ? "login" : "key",
    value.before.join("+") || "fresh",
    `first-${value.onFirstTitle}`,
    `issuer-${value.issuer}`,
    value.forceKeepsOld ? "keep" : "revoke",
    value.rejectNew ? "reject-new" : "take-new",
    value.interrupt ? "interrupt" : "single",
    `d${value.titleDelayMs}-${value.issuerDelayMs}`,
  ].join(".");
  return value;
}

/// Every schedule of the model's environment the driver can play, within small bounds.
function enumerate(): Schedule[] {
  const out: Schedule[] = [];
  const issuers = ["up", "down", "slow"] as const;
  if (options.only.includes("ask")) {
    for (const before of [[], ["revoke"]] as EnvEvent[][]) {
      for (const onFirstTitle of ["none", "rotate_keep", "rotate_revoke"] as const) {
        for (const issuer of issuers) {
          for (const forceKeepsOld of [true, false]) {
            for (const rejectNew of [false, true]) {
              out.push(schedule({ surface: "ask", before, onFirstTitle, issuer, forceKeepsOld, rejectNew }));
            }
          }
        }
      }
      out.push(schedule({ surface: "ask", refreshable: false, before }));
    }
  }
  if (options.only.includes("tui")) {
    const befores: EnvEvent[][] = [[], ["rotate_keep"], ["rotate_revoke"], ["rotate_revoke", "rotate_revoke"], ["revoke"], ["rotate_revoke", "revoke"]];
    for (const before of befores) {
      for (const issuer of ["up", "down"] as const) {
        for (const rejectNew of [false, true]) {
          out.push(schedule({ surface: "tui", before, issuer, rejectNew }));
        }
      }
    }
    out.push(schedule({ surface: "tui", before: ["rotate_revoke"], onFirstTitle: "rotate_revoke" }));
    for (const before of [[], ["revoke"]] as EnvEvent[][]) {
      out.push(schedule({ surface: "tui", refreshable: false, before, interrupt: true }));
      out.push(schedule({ surface: "tui", refreshable: true, before, interrupt: true, rejectNew: true }));
    }
  }
  if (options.only.includes("catalog")) {
    const befores: EnvEvent[][] = [[], ["rotate_keep"], ["rotate_revoke"], ["revoke"], ["rotate_revoke", "revoke"]];
    for (const before of befores) {
      for (const issuer of ["up", "down"] as const) {
        for (const rejectNew of [false, true]) {
          out.push(schedule({ surface: "catalog", before, issuer, rejectNew }));
        }
      }
    }
  }
  if (options.only.includes("acp")) {
    for (const before of [[], ["rotate_revoke"], ["revoke"], ["rotate_keep", "revoke"]] as EnvEvent[][]) {
      out.push(schedule({ surface: "acp", before }));
    }
    out.push(schedule({ surface: "acp", before: ["revoke"], rejectNew: true }));
  }
  return out;
}

function randomSchedules(count: number, seed: number): Schedule[] {
  const next = generator(seed);
  const pick = <T>(values: readonly T[]): T => values[Math.floor(next() * values.length)]!;
  const out: Schedule[] = [];
  for (let i = 0; i < count; i++) {
    const surface = pick(options.only);
    const refreshable = surface === "catalog" || next() < 0.85;
    const length = Math.floor(next() * 4);
    const before: EnvEvent[] = [];
    for (let j = 0; j < length; j++) before.push(refreshable ? pick(["rotate_keep", "rotate_revoke", "revoke"] as const) : "revoke");
    out.push(schedule({
      surface,
      refreshable,
      before: surface === "ask" ? before.filter((event) => event === "revoke").slice(0, 1) : before,
      onFirstTitle: refreshable && surface !== "catalog" ? pick(["none", "rotate_keep", "rotate_revoke"] as const) : "none",
      issuer: pick(surface === "ask" ? ["up", "down", "slow"] as const : ["up", "down"] as const),
      forceKeepsOld: next() < 0.5,
      rejectNew: next() < 0.3,
      interrupt: surface === "tui" && next() < 0.3,
      titleDelayMs: Math.floor(next() * 250),
      issuerDelayMs: Math.floor(next() * 250),
    }));
  }
  return out;
}

/// The tokens the run has seen, the ones the gateway takes, and every event.
class World {
  tokens: string[];
  accepted: Set<string>;
  stored: string;
  events: Event[] = [];
  firstTitleSeen = false;
  armed = false;
  modelRequests = 0;
  catalogFellBack = false;
  forceFailedSinceSend = false;

  constructor(readonly home: string, readonly schedule: Schedule, readonly fakes: any) {
    const launch = schedule.refreshable ? "tok-v1" : "static-key";
    this.tokens = [launch];
    this.accepted = new Set([launch]);
    this.stored = launch;
  }

  version(token: string): number {
    return this.tokens.indexOf(token) + 1;
  }

  private create(): string {
    const token = `tok-v${this.tokens.length + 1}`;
    this.tokens.push(token);
    return token;
  }

  apply(event: EnvEvent) {
    if (event === "revoke") {
      if (!this.accepted.has(this.stored)) return;
      this.accepted.delete(this.stored);
      this.events.push({ kind: "revoke" });
      return;
    }
    const old = this.stored;
    const token = this.create();
    this.accepted.add(token);
    if (event === "rotate_revoke") this.accepted.delete(old);
    this.stored = token;
    this.fakes.rotateFxLogin(this.home, token);
    // Whether the gateway still takes the token stored before this step.
    this.events.push({ kind: "rotate", keep: this.accepted.has(old) });
  }

  /// The issuer answers one of fx's own refreshes.
  issue(channel: "title" | "catalog"): string {
    const old = this.stored;
    const token = this.create();
    this.accepted.add(token);
    if (!this.schedule.forceKeepsOld) this.accepted.delete(old);
    this.stored = token;
    this.events.push({ kind: `${channel}_force`, tok: this.version(token), keep: this.accepted.has(old) });
    if (this.schedule.rejectNew) {
      this.accepted.delete(token);
      this.events.push({ kind: "revoke" });
    }
    this.forceFailedSinceSend = false;
    return token;
  }

  failRefresh(channel: "title" | "catalog") {
    if (this.forceFailedSinceSend) return;
    this.forceFailedSinceSend = true;
    this.events.push({ kind: `${channel}_force`, tok: 0, keep: false });
  }

  send(channel: "title" | "catalog", token: string, prompt = 0): boolean {
    const ok = this.accepted.has(token);
    this.forceFailedSinceSend = false;
    const event: Event = { kind: `${channel}_send`, tok: this.version(token), ok };
    if (channel === "title") event.prompt = prompt;
    this.events.push(event);
    return ok;
  }
}

function titleText(helpers: any): Response {
  return helpers.fakeGatewayFinalText(GENERATED_TITLE);
}

function promptOf(body: string): number {
  if (body.includes(PROMPTS[1]!)) return 2;
  if (body.includes(PROMPTS[0]!)) return 1;
  return 0;
}

type Held = { started: boolean; cancelled: boolean };

function heldReply(held: Held): Response {
  const encoder = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  return new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      held.started = true;
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "held", delta: "Working on it.\n" })}\n\n`));
      timer = setInterval(() => controller.enqueue(encoder.encode(": held\n\n")), 50);
    },
    cancel() {
      held.cancelled = true;
      if (timer) clearInterval(timer);
    },
  }), { headers: { "content-type": "text/event-stream" } });
}

async function waitUntil(condition: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return true;
    await Bun.sleep(25);
  }
  return condition();
}

function sessionTitles(saved: any, home: string): string[] {
  const root = join(home, ".fx", "sessions");
  if (!existsSync(root)) return [];
  return saved.rootSessionIds(home).flatMap((id: string) => {
    const lines = saved.logLines(home, id) as any[];
    const title = lines.filter((line) => line.kind === "set" && line.key === "title").at(-1)?.value;
    return typeof title === "string" ? [title] : [];
  });
}

function readTrace(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

function titleOutcome(world: World, installed: boolean, trace: string): string {
  const sends = world.events.filter((event) => event.kind === "title_send");
  if (sends.length === 0) return "none";
  if (installed) return "ok";
  if (sends.at(-1)!.ok) return "ok";
  if (trace.includes("event=title_generation_dropped") || trace.includes("reason=cancelled")) return "pending";
  if (trace.includes("event=title_generation result=unavailable")) return "failed";
  return "pending";
}

function catalogOutcome(world: World): string {
  const sends = world.events.filter((event) => event.kind === "catalog_send");
  if (sends.length === 0) return "none";
  if (sends.at(-1)!.ok) return "ok";
  return world.catalogFellBack ? "failed" : "pending";
}

function starts(world: World): number {
  return new Set(world.events.filter((event) => event.kind === "title_send").map((event) => event.prompt)).size;
}

/// One run of fx under `schedule`, with every event it produced.
async function runSchedule(helpers: any, fakes: any, saved: any, s: Schedule, scratch: string): Promise<Event[]> {
  const root = realpathSync(mkdtempSync(join(scratch, `${s.surface}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ statusLine: { session: true } }));
  const tracePath = join(root, "trace.log");
  let world!: World;
  const issuer = fakes.startFakeIssuer({
    refresh: async () => {
      if (s.issuerDelayMs) await Bun.sleep(s.issuerDelayMs);
      const channel = s.surface === "catalog" ? "catalog" : "title";
      if (s.issuer === "down") {
        world.failRefresh(channel);
        return new Response("issuer unavailable", { status: 500 });
      }
      if (s.issuer === "slow") {
        await Bun.sleep(120_000);
        return new Response("too late", { status: 500 });
      }
      return world.issue(channel);
    },
  });
  world = new World(home, s, fakes);
  if (s.refreshable) fakes.writeFxLogin(home, issuer.issuerUrl, world.stored);

  const held: Held = { started: false, cancelled: false };
  let mainRequests = 0;
  const title = async (body: string, headers: Headers) => {
    if (s.titleDelayMs) await Bun.sleep(s.titleDelayMs);
    if (s.onFirstTitle !== "none" && !world.firstTitleSeen) world.apply(s.onFirstTitle);
    world.firstTitleSeen = true;
    return world.send("title", fakes.bearer(headers), promptOf(body)) ? titleText(helpers) : fakes.unauthorized();
  };
  const publicModel = { id: MODEL, type: "language", tags: ["tool-use"] };
  const gateway = helpers.startDynamicFakeGateway(() => {
    mainRequests += 1;
    if (s.interrupt && mainRequests === 1) return heldReply(held);
    return helpers.fakeGatewayFinalText("MAIN_ANSWER_OK");
  }, {
    models: (request: Request) => {
      world.modelRequests += 1;
      if (s.surface !== "catalog" || !world.armed) return [publicModel];
      const authorization = request.headers.get("authorization");
      if (authorization === null) {
        world.catalogFellBack = true;
        return [publicModel];
      }
      const token = authorization.replace(/^Bearer /, "");
      if (!world.send("catalog", token)) return fakes.unauthorized();
      return [publicModel, { id: `private/model-v${world.version(token)}`, type: "language", tags: ["tool-use"] }];
    },
    titleResponses: Array.from({ length: 12 }, () => title),
  });
  const env = testEnvironment({
    HOME: home,
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "full-access",
    FX_MAX_AGENT_STEPS: "2",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    ...(s.surface === "catalog" ? {} : { FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models` }),
    FX_TEST_OAUTH_ISSUER_URL: issuer.issuerUrl,
    FX_OAUTH_CLIENT_ID: "test-client",
    FX_NO_OPEN_BROWSER: "1",
    FX_TRACE_LOG: tracePath,
    FX_TRACE_SCOPES: "session,auth,catalog",
    ...(s.refreshable ? {} : { AI_GATEWAY_API_KEY: world.stored }),
  });
  const end = (installed: boolean) => {
    world.events.push({
      kind: "end",
      title: titleOutcome(world, installed, readTrace(tracePath)),
      catalog: catalogOutcome(world),
      starts: starts(world),
    });
  };
  let tui: any;
  try {
    if (s.surface === "ask") {
      for (const event of s.before) world.apply(event);
      world.events.push({ kind: "prompt", n: 1 });
      const proc = Bun.spawn([binary, "ask", PROMPTS[0]!], { cwd: workspace, env, stdout: "pipe", stderr: "pipe" });
      const exit = await Promise.race([proc.exited, Bun.sleep(45_000).then(() => null)]);
      if (exit === null) {
        proc.kill("SIGKILL");
        throw new Error("fx ask did not exit");
      }
      if (exit !== 0) throw new Error(`fx ask exited ${exit}: ${await new Response(proc.stderr).text()}`);
      end(sessionTitles(saved, home).includes(GENERATED_TITLE));
    } else if (s.surface === "acp") {
      const installed = await runAcp(env, workspace, world, s);
      end(installed || sessionTitles(saved, home).includes(GENERATED_TITLE));
    } else {
      tui = await helpers.TmuxSession.create({ cmd: JSON.stringify(binary), cwd: workspace, isolated: true, remainOnExit: true, env });
      await tui.waitForStableComposer(20_000);
      if (s.surface === "catalog") {
        // The model list fx loaded at launch is not part of the run.
        if (!await waitUntil(() => world.modelRequests >= 1, 15_000)) throw new Error("fx loaded no model list at launch");
        await Bun.sleep(200);
        world.armed = true;
        for (const event of s.before) world.apply(event);
        // The picker reloads the list only 5 s after the last load.
        await Bun.sleep(5_500);
        world.events.push({ kind: "catalog_load" });
        await tui.sendText("/model");
        await waitUntil(() => {
          const outcome = catalogOutcome(world);
          return outcome === "ok" || outcome === "failed";
        }, 15_000);
        await Bun.sleep(300);
        end(false);
      } else {
        for (const event of s.before) world.apply(event);
        world.events.push({ kind: "prompt", n: 1 });
        await tui.sendText(PROMPTS[0]!);
        if (s.interrupt) {
          await waitUntil(() => held.started, 15_000);
          await waitUntil(() => readTrace(tracePath).includes("event=title_generation result="), 15_000);
          await Bun.sleep(300);
          world.events.push({ kind: "prompt", n: 2 });
          await tui.sendText(PROMPTS[1]!);
        }
        await tui.waitForText("MAIN_ANSWER_OK", 20_000);
        await waitUntil(() =>
          sessionTitles(saved, home).includes(GENERATED_TITLE) ||
          readTrace(tracePath).includes("event=title_generation result=unavailable") ||
          (s.issuer === "slow" && world.events.some((event) => event.kind === "title_send" && !event.ok)), 15_000);
        await Bun.sleep(s.interrupt ? 1_500 : 500);
        end(sessionTitles(saved, home).includes(GENERATED_TITLE));
      }
    }
  } finally {
    await tui?.kill();
    gateway.stop();
    issuer.stop();
    rmSync(root, { recursive: true, force: true });
  }
  return world.events;
}

/// A minimal ACP client: initialize, session/new, the environment, one prompt.
async function runAcp(env: Record<string, string>, workspace: string, world: World, s: Schedule): Promise<boolean> {
  const proc = Bun.spawn([binary, "acp"], { cwd: workspace, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  const reader = proc.stdout.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  const send = (message: unknown) => {
    proc.stdin.write(`${JSON.stringify(message)}\n`);
    proc.stdin.flush();
  };
  const until = async (id: number): Promise<any[]> => {
    const seen: any[] = [];
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const newline = buffered.indexOf("\n");
      if (newline >= 0) {
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        if (!line.trim()) continue;
        const message = JSON.parse(line);
        seen.push(message);
        if (message.id === id) return seen;
        continue;
      }
      const chunk = await reader.read();
      if (chunk.done) throw new Error("fx acp closed its output");
      buffered += decoder.decode(chunk.value, { stream: true });
    }
    throw new Error(`fx acp did not answer request ${id}`);
  };
  try {
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } });
    await until(1);
    send({ jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: workspace, mcpServers: [] } });
    const sessionId = (await until(2)).at(-1)?.result?.sessionId;
    if (typeof sessionId !== "string") throw new Error("fx acp returned no session id");
    for (const event of s.before) world.apply(event);
    world.events.push({ kind: "prompt", n: 1 });
    send({ jsonrpc: "2.0", id: 3, method: "session/prompt", params: { sessionId, prompt: [{ type: "text", text: PROMPTS[0] }] } });
    const messages = await until(3);
    return JSON.stringify(messages).includes(GENERATED_TITLE);
  } finally {
    proc.stdin.end();
    proc.kill();
    await proc.exited;
  }
}

function tlaValue(event: Event): string {
  return `[kind |-> "${event.kind}", n |-> ${event.n ?? 0}, tok |-> ${event.tok ?? 0}, ok |-> ${event.ok ? "TRUE" : "FALSE"}, ` +
    `keep |-> ${event.keep ? "TRUE" : "FALSE"}, prompt |-> ${event.prompt ?? 0}, title |-> "${event.title ?? ""}", ` +
    `catalog |-> "${event.catalog ?? ""}", starts |-> ${event.starts ?? 0}]`;
}

/// The run's events, with the issuer failing from the start when it is down.
function observedEvents(s: Schedule, events: Event[]): Event[] {
  return s.refreshable && s.issuer === "down" ? [{ kind: "issuer_down" }, ...events] : events;
}

async function check(dir: string, s: Schedule, events: Event[], bug: "none" | "today"): Promise<Verdict> {
  mkdirSync(dir, { recursive: true });
  const observed = observedEvents(s, events);
  writeFileSync(join(dir, "SessionTitleObserved.tla"), [
    "------------------------ MODULE SessionTitleObserved ------------------------",
    `\\* ${s.id}`,
    "EXTENDS Sequences",
    `Observed == <<${observed.map(tlaValue).join(",\n    ")}>>`,
    "=============================================================================",
    "",
  ].join("\n"));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `    Refreshable = ${s.refreshable ? "TRUE" : "FALSE"}`,
    "    MaxRotations = 12",
    "    MaxRevocations = 12",
    `    Bug = "${bug}"`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  writeJson(join(dir, "observed.json"), { schedule: s, events: observed });
  const run = await runTlc(dir, "SessionTitleTrace", "trace.cfg", ["SessionTitle.tla", "SessionTitleTrace.tla"], tlaDir);
  if (run.violated === "NotAllMatched") return "ACCEPTED";
  if (run.exitCode === 0 && run.output.includes("No error has been found")) return "REJECTED";
  return "TOOL_ERROR";
}

async function pool<T, R>(items: T[], jobs: number, work: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.max(1, Math.min(jobs, items.length)) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await work(items[index]!, index);
    }
  }));
  return results;
}

async function runAll(schedules: Schedule[], out: string, wantToday: boolean): Promise<RunResult[]> {
  const helpers = await targetHelpers();
  const fakes = await targetModule("fx-login-fakes.ts");
  const saved = await targetModule("saved-sessions.ts");
  const scratch = mkdtempSync(join(out, "runs-"));
  // TUI runs share tmux; keep them fewer at once than the fx ask runs.
  return await pool(schedules, options.jobs, async (s, index) => {
    const started = performance.now();
    const dir = join(out, "tlc", `${String(index).padStart(3, "0")}-${s.id}`);
    try {
      const events = await runSchedule(helpers, fakes, saved, s, scratch);
      const design = await check(join(dir, "design"), s, events, "none");
      const today = wantToday ? await check(join(dir, "today"), s, events, "today") : null;
      const result: RunResult = { schedule: s, events, design, today, seconds: Math.round(performance.now() - started) / 1000 };
      console.log(`${design.padEnd(8)} ${today ? `today=${today.padEnd(8)} ` : ""}${s.id} (${result.seconds}s)`);
      return result;
    } catch (error) {
      console.log(`TOOL_ERROR ${s.id}: ${(error as Error).message}`);
      return { schedule: s, events: [], design: "TOOL_ERROR", today: null, seconds: 0, error: (error as Error).message };
    }
  });
}

/// N fx ask processes in one profile while the login rotates every 50 ms.
async function stress(count: number, out: string): Promise<number> {
  const helpers = await targetHelpers();
  const fakes = await targetModule("fx-login-fakes.ts");
  const saved = await targetModule("saved-sessions.ts");
  const root = realpathSync(mkdtempSync(join(out, "stress-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  let version = 1;
  const accepted = new Set(["tok-v1"]);
  let refreshes = 0;
  const issuer = fakes.startFakeIssuer({
    refresh: () => {
      refreshes += 1;
      version += 1;
      const token = `tok-v${version}`;
      accepted.add(token);
      return token;
    },
  });
  fakes.writeFxLogin(home, issuer.issuerUrl, "tok-v1");
  // Each process's title requests, keyed by the prompt that names it.
  const sends = new Map<string, Array<{ token: string; ok: boolean }>>();
  const gateway = helpers.startDynamicFakeGateway(() => helpers.fakeGatewayFinalText("MAIN_ANSWER_OK"), {
    models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
    titleResponses: Array.from({ length: count * 4 }, () => (body: string, headers: Headers) => {
      const key = /stress prompt (\d+)/.exec(body)?.[1] ?? "?";
      const token = fakes.bearer(headers);
      const ok = accepted.has(token);
      sends.set(key, [...(sends.get(key) ?? []), { token, ok }]);
      return ok ? helpers.fakeGatewayFinalText(`Stress Title ${key}`) : fakes.unauthorized();
    }),
  });
  // Another fx keeps refreshing the login; the gateway keeps the newest two.
  let rotating = true;
  const rotator = (async () => {
    while (rotating) {
      await Bun.sleep(50);
      version += 1;
      const token = `tok-v${version}`;
      accepted.add(token);
      for (const old of [...accepted]) if (Number(old.slice(5)) < version - 1) accepted.delete(old);
      fakes.rotateFxLogin(home, token);
    }
  })();
  const env = testEnvironment({
    HOME: home,
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "full-access",
    FX_MAX_AGENT_STEPS: "2",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TEST_OAUTH_ISSUER_URL: issuer.issuerUrl,
    FX_OAUTH_CLIENT_ID: "test-client",
  });
  const timeTool = existsSync("/usr/bin/time") ? ["/usr/bin/time", process.platform === "darwin" ? "-l" : "-v"] : [];
  const started = performance.now();
  const results = await Promise.all(Array.from({ length: count }, async (_, i) => {
    const proc = Bun.spawn([...timeTool, binary, "ask", `stress prompt ${i}: ${PROMPTS[0]}`], { cwd: workspace, env, stdout: "pipe", stderr: "pipe" });
    const exit = await Promise.race([proc.exited, Bun.sleep(90_000).then(() => null)]);
    if (exit === null) proc.kill("SIGKILL");
    const stderr = await new Response(proc.stderr).text();
    const rss = /(\d+)\s+maximum resident set size/.exec(stderr)?.[1] ?? /Maximum resident set size \(kbytes\): (\d+)/.exec(stderr)?.[1];
    const rssBytes = rss ? Number(rss) * (process.platform === "darwin" ? 1 : 1024) : null;
    return { i, exit, rssBytes };
  }));
  const wallSeconds = Math.round(performance.now() - started) / 1000;
  rotating = false;
  await rotator;
  gateway.stop();
  issuer.stop();
  const problems: string[] = [];
  for (const { i, exit } of results) {
    if (exit !== 0) problems.push(`process ${i} exited ${exit}`);
    const mine = sends.get(String(i)) ?? [];
    if (mine.length === 0) problems.push(`process ${i} sent no title request`);
    if (mine.length > 2) problems.push(`process ${i} sent ${mine.length} title requests`);
    if (mine.length === 2 && mine[0]!.ok) problems.push(`process ${i} sent again after an accepted title`);
  }
  const titled = sessionTitles(saved, home).filter((title) => title.startsWith("Stress Title")).length;
  const accepted1 = [...sends.values()].filter((list) => list.at(-1)?.ok).length;
  if (titled !== accepted1) problems.push(`${accepted1} titles were accepted but ${titled} sessions show one`);
  const rss = results.map((result) => result.rssBytes).filter((value): value is number => value !== null);
  const summary = {
    processes: count,
    wallSeconds,
    rotations: version - 1 - refreshes,
    issuerRefreshes: refreshes,
    titleRequests: [...sends.values()].reduce((sum, list) => sum + list.length, 0),
    replays: [...sends.values()].filter((list) => list.length === 2).length,
    titled,
    peakRssBytes: rss.length ? Math.max(...rss) : null,
    medianRssBytes: rss.length ? rss.sort((a, b) => a - b)[Math.floor(rss.length / 2)] : null,
    problems,
  };
  writeJson(join(out, "stress.json"), summary);
  console.log(JSON.stringify(summary, null, 2));
  rmSync(root, { recursive: true, force: true });
  return problems.length === 0 ? 0 : 1;
}

async function main(): Promise<number> {
  if (!existsSync(binary)) {
    console.error(`missing ${binary}; run zig build first`);
    return 2;
  }
  tlcToolchain();
  const out = outDir("session-title");
  console.log(`output: ${out}`);
  if (options.stress > 0) return await stress(options.stress, out);

  const schedules = options.replay
    ? (JSON.parse(readFileSync(options.replay, "utf8")) as Schedule[]).map((s) => schedule(s))
    : options.fuzz > 0
      ? randomSchedules(options.fuzz, options.seed)
      : enumerate();
  const wantToday = options.selfCheck || options.base;
  const results = await runAll(schedules, out, wantToday);
  writeJson(join(out, "results.json"), results);

  const errors = results.filter((result) => result.design === "TOOL_ERROR" || result.today === "TOOL_ERROR");
  const designRejected = results.filter((result) => result.design === "REJECTED");
  const todayRejected = results.filter((result) => result.today === "REJECTED");
  console.log(`runs ${results.length}: design rejected ${designRejected.length}` +
    (wantToday ? `, today rejected ${todayRejected.length}` : "") + `, tool errors ${errors.length}`);
  if (designRejected.length > 0) {
    const kept = join(out, "rejected.json");
    writeJson(kept, designRejected.map((result) => result.schedule));
    console.log(`rejected schedules: ${kept} (replay with --replay)`);
  }
  if (errors.length > 0) return 2;
  if (options.base) {
    for (const result of results) {
      if (result.today !== "ACCEPTED") console.log(`today model cannot produce ${result.schedule.id}`);
    }
    if (results.some((result) => result.today !== "ACCEPTED")) return 1;
    return designRejected.length > 0 ? 0 : 1;
  }
  if (designRejected.length > 0) return 1;
  if (options.selfCheck && todayRejected.length === 0) {
    console.log("self-check failed: the model of fx before the change accepts every run");
    return 1;
  }
  return 0;
}

process.exit(await main().catch((error) => {
  console.error(error);
  return 2;
}));
