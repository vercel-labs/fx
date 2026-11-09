// Runs the built fx binary against a local Chat Completions server and has
// TLC check every request it observes against
// tests/tla/connection_watch/HeadWait.tla (HeadWaitTrace.tla).
//
// Each scenario is one `fx ask` on a configured connection. The local server
// follows a plan for each connection: send the response head after a delay,
// close the socket after a delay, or hold it with no head; the driver may send
// fx SIGINT while a head is held. The server records when each request
// arrived and how its head wait ended: the server sent the head, the server
// closed the socket, or fx closed it, after SIGINT or without one.
//
//   cold    the first send's head comes after 125 s, past the old 120 s bound
//   closed  the server closes the first send's socket after 2 s
//   esc     the server never answers, and the driver sends SIGINT after 3 s
//   review  in auto mode, the permission review of a tool call never answers;
//           each review send has its own 30 s deadline
//   quick   the head comes at once
// plus --random N seeded schedules of short delays, closes, and SIGINT.
//
// Consecutive agent sends with the same body are recovery's resends of one
// request; every review send is a request of its own. Times are rounded to
// the model's 5 s tick. TLC replays each scenario through the design
// (Patient = "no_deadline"). --self-check also replays them through the
// model of fx before the change (Patient = "none"), which must reject the
// cold scenario. Every fx process runs with FX_SOUND=0, FX_DISABLE_KEYCHAIN=1,
// a temporary HOME and FX_HOME, and only the local server's URLs.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/connection_watch/driver.ts
//   bun tests/tla/drivers/connection_watch/driver.ts --self-check
//   bun tests/tla/drivers/connection_watch/driver.ts --only closed,esc,quick --random 20 --seed 7
//
// Exit codes: 0 every scenario accepted (and the self-check rejected), 1 a
// scenario the model cannot produce or an fx result the plan does not allow,
// 2 a toolchain, build, or harness failure.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetModule, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

export type Reply = { text: string } | { command: string };
export type Plan =
  | { do: "answer"; after: number; reply: Reply }
  | { do: "close"; after: number }
  | { do: "hold"; sigint?: number };
type Kind = "agent" | "review" | "other";
type Ending = "head" | "closed" | "esc" | "client_closed";
export type Connection = {
  kind: Kind;
  path: string;
  body: string;
  plan: Plan;
  arrived: number;
  end: Ending | null;
  endMs: number | null;
  sigintMs: number | null;
};
export type Scenario = {
  name: string;
  auto?: boolean;
  timeoutMs: number;
  plan: (kind: "agent" | "review", index: number) => Plan;
  expect: { exit: number; output?: string };
  /// Replaces the connection in settings.json, given the server's base URL.
  connection?: (baseUrl: string) => Record<string, unknown>;
  /// Added to fx's environment.
  env?: Record<string, string>;
};
export type Run = {
  scenario: string;
  exit: number | null;
  output: string;
  stderr: string;
  seconds: number;
  maxRssBytes: number | null;
  connections: Connection[];
};
type Send = { server: "slow" | "hung"; end: Ending; at: number };
type Request = { deadline: number; sends: Send[] };

const TICK_MS = 5000;
// A permission review's own deadline (src/core/permissions/auto_classifier.zig
// Reviewer.default_timeout_ms), in ticks.
const REVIEW_DEADLINE_TICKS = 6;
const MODEL = "local-model";
const REVIEW_TOOL = "permission_decision";
const tlaDir = join(TLA_ROOT, "connection_watch");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

function listOption(name: string): string[] | null {
  const at = process.argv.indexOf(name);
  return at < 0 ? null : (process.argv[at + 1] ?? "").split(",").filter(Boolean);
}

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

const answer = (after: number, text: string): Plan => ({ do: "answer", after, reply: { text } });

export const fixedScenarios: Scenario[] = [
  {
    name: "cold",
    timeoutMs: 200_000,
    plan: (_kind, index) => answer(index === 0 ? 125_000 : 0, "answer from a cold model"),
    expect: { exit: 0, output: "answer from a cold model" },
  },
  {
    name: "closed",
    timeoutMs: 40_000,
    plan: (_kind, index) => index === 0 ? { do: "close", after: 2000 } : answer(0, "answer after a close"),
    expect: { exit: 0, output: "answer after a close" },
  },
  {
    name: "esc",
    timeoutMs: 40_000,
    plan: () => ({ do: "hold", sigint: 3000 }),
    expect: { exit: 130 },
  },
  {
    name: "review",
    auto: true,
    timeoutMs: 150_000,
    plan: (kind, index) => {
      if (kind === "review") return { do: "hold" };
      if (index === 0) return { do: "answer", after: 0, reply: { command: "python3 -c 'print(42)'" } };
      return answer(0, "the action was held");
    },
    expect: { exit: 0, output: "the action was held" },
  },
  {
    name: "quick",
    timeoutMs: 40_000,
    plan: () => answer(0, "a quick answer"),
    expect: { exit: 0, output: "a quick answer" },
  },
];

/// Seeded schedules of up to three sends: closes after up to 2 s, then a head
/// after up to 3 s, or a held head and SIGINT after 0.5 to 3 s.
export function randomScenarios(count: number, seed: number): Scenario[] {
  const next = generator(seed);
  const scenarios: Scenario[] = [];
  for (let i = 0; i < count; i++) {
    const sends = 1 + Math.floor(next() * 3);
    const plans: Plan[] = [];
    for (let s = 0; s < sends - 1; s++) plans.push({ do: "close", after: Math.floor(next() * 2000) });
    const text = `random answer ${seed}-${i}`;
    const last: Plan = next() < 0.6
      ? answer(Math.floor(next() * 3000), text)
      : { do: "hold", sigint: 500 + Math.floor(next() * 2500) };
    plans.push(last);
    scenarios.push({
      name: `random-${seed}-${i}`,
      timeoutMs: 60_000,
      plan: (_kind, index) => plans[Math.min(index, plans.length - 1)]!,
      expect: last.do === "answer" ? { exit: 0, output: text } : { exit: 130 },
    });
  }
  return scenarios;
}

function connection(baseUrl: string): Record<string, unknown> {
  return {
    protocol: "openai-chat-completions", base_url: baseUrl, auth: { type: "none" },
    model_metadata: { [MODEL]: { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } },
  };
}

function settings(port: number, scenario: Scenario) {
  const baseUrl = `http://127.0.0.1:${port}/v1`;
  return {
    provider: "local", auto_upgrade: false, permission_mode: scenario.auto ? "auto" : "ask",
    providers: { local: (scenario.connection ?? connection)(baseUrl) },
    models: { local: MODEL },
  };
}

function httpResponse(sse: string): string {
  return `HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: ${Buffer.byteLength(sse)}\r\nconnection: close\r\n\r\n${sse}`;
}

/// Runs one scenario: a local server that follows the plan, and `fx ask`.
export async function runScenario(scenario: Scenario, scratch: string, fxBin = binary): Promise<Run> {
  const fixtures = await targetModule("fixtures/chat-completions.ts");
  const connections: Connection[] = [];
  const counts = { agent: 0, review: 0 };
  let child: ReturnType<typeof Bun.spawn> | null = null;
  const timers: Array<ReturnType<typeof setTimeout>> = [];
  type State = { received: string; record: Connection | null };
  const listener = Bun.listen<State>({
    hostname: "127.0.0.1",
    port: 0,
    socket: {
      open(socket) { socket.data = { received: "", record: null }; },
      async data(socket, chunk) {
        const state = socket.data;
        if (state.record) return;
        state.received += chunk.toString();
        const split = state.received.indexOf("\r\n\r\n");
        if (split < 0) return;
        const head = state.received.slice(0, split);
        const length = Number(/content-length: *(\d+)/i.exec(head)?.[1] ?? 0);
        if (state.received.length < split + 4 + length) return;
        const path = head.split(" ")[1] ?? "";
        const body = state.received.slice(split + 4, split + 4 + length);
        let kind: Kind = "other";
        if (path === "/v1/chat/completions") {
          const parsed = JSON.parse(body);
          kind = parsed.tools?.some((tool: any) => tool.function?.name === REVIEW_TOOL) ? "review" : "agent";
        }
        const plan: Plan = kind === "other" ? { do: "close", after: 0 } : scenario.plan(kind, counts[kind]++);
        const record: Connection = { kind, path, body, plan, arrived: performance.now(), end: null, endMs: null, sigintMs: null };
        state.record = record;
        connections.push(record);
        const finish = (end: Ending) => {
          if (record.end) return false;
          record.end = end;
          record.endMs = performance.now() - record.arrived;
          return true;
        };
        if (plan.do === "answer") {
          const model = JSON.parse(body).model;
          const response = "text" in plan.reply
            ? fixtures.completion(model, plan.reply.text)
            : fixtures.toolCompletion(model, "shell", { request: { action: "run", command: plan.reply.command } });
          const sse = await response.text();
          timers.push(setTimeout(() => { if (finish("head")) socket.end(httpResponse(sse)); }, plan.after));
        } else if (plan.do === "close") {
          timers.push(setTimeout(() => { if (finish("closed")) socket.end(); }, plan.after));
        } else if (plan.sigint !== undefined) {
          timers.push(setTimeout(() => {
            if (record.end) return;
            record.sigintMs = performance.now() - record.arrived;
            child?.kill("SIGINT");
          }, plan.sigint));
        }
      },
      close(socket) {
        const record = socket.data?.record;
        if (!record || record.end) return;
        record.end = record.sigintMs === null ? "client_closed" : "esc";
        record.endMs = performance.now() - record.arrived;
      },
      error() {},
    },
  });
  const root = mkdtempSync(join(scratch, `${scenario.name}-`));
  const home = join(root, "home");
  const fxHome = join(home, ".fx");
  const workspace = join(root, "workspace");
  mkdirSync(fxHome, { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(fxHome, "settings.json"), JSON.stringify(settings(listener.port, scenario)), { mode: 0o600 });
  const unexpected = `http://127.0.0.1:${listener.port}/unexpected-gateway`;
  // Every variable fx sees is written out for env -i, so nothing else leaks in.
  const env = testEnvironment({
    HOME: home,
    FX_HOME: fxHome,
    AI_GATEWAY_API_KEY: "fake-connection-watch-driver-key",
    FX_GATEWAY_BASE_URL: unexpected,
    FX_GATEWAY_CHAT_URL: unexpected,
    NO_COLOR: "1",
    ...scenario.env,
  });
  try {
    const started = performance.now();
    const assignments = Object.entries(env).map(([key, value]) => `${key}=${value}`);
    child = Bun.spawn(["/usr/bin/env", "-i", ...assignments, fxBin, "ask", "--json", "--no-save", "Say hello"], {
      cwd: workspace,
      env: {},
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const killer = setTimeout(() => child?.kill(9), scenario.timeoutMs);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout as ReadableStream).text(),
      new Response(child.stderr as ReadableStream).text(),
      child.exited,
    ]);
    clearTimeout(killer);
    // Let the server see the last close.
    await Bun.sleep(50);
    let output = "";
    try {
      output = String(JSON.parse(stdout.trim()).final_output ?? "");
    } catch {
      output = "";
    }
    return {
      scenario: scenario.name,
      exit,
      output,
      stderr,
      seconds: Number(((performance.now() - started) / 1000).toFixed(2)),
      // env -i execs fx in its own process, so this is fx's peak.
      maxRssBytes: child.resourceUsage()?.maxRSS ?? null,
      connections,
    };
  } finally {
    for (const timer of timers) clearTimeout(timer);
    listener.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
}

/// The requests a run shows, in the model's terms.
export function requestsOf(run: Run): Request[] {
  const requests: Request[] = [];
  let previous: { kind: Kind; body: string } | null = null;
  for (const c of run.connections) {
    if (c.kind === "other" || c.end === null || c.endMs === null) continue;
    const send: Send = { server: c.plan.do === "answer" ? "slow" : "hung", end: c.end, at: Math.round(c.endMs / TICK_MS) };
    const resend = c.kind === "agent" && previous?.kind === "agent" && previous.body === c.body;
    if (resend) requests.at(-1)!.sends.push(send);
    else requests.push({ deadline: c.kind === "review" ? REVIEW_DEADLINE_TICKS : 0, sends: [send] });
    previous = { kind: c.kind, body: c.body };
  }
  return requests;
}

const str = (value: string) => JSON.stringify(value);

function observedModule(requests: Request[]): string {
  const send = (s: Send) => `[server |-> ${str(s.server)}, end |-> ${str(s.end)}, at |-> ${s.at}]`;
  const request = (r: Request) => `[deadline |-> ${r.deadline}, sends |-> << ${r.sends.map(send).join(", ")} >>]`;
  return [
    "------------------------ MODULE HeadWaitObserved ------------------------",
    "(* Generated by tests/tla/drivers/connection_watch/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${requests.map(request).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

/// head-wait.cfg's constants, with the trace spec and the given rule.
function traceConfig(patient: string, maxSends: number): string {
  const cfg = readFileSync(join(tlaDir, "head-wait.cfg"), "utf8");
  return cfg
    .replace(/^SPECIFICATION .*$/m, "SPECIFICATION TraceSpec")
    .replace(/^INVARIANTS .*$/m, "INVARIANT NotAllMatched")
    .replace(/Patient = "[a-z_]+"/, `Patient = ${str(patient)}`)
    .replace(/MaxSends = \d+/, `MaxSends = ${maxSends}`);
}

type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

async function check(requests: Request[], patient: string, dir: string): Promise<{ verdict: Verdict; dir: string; states: number | null }> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "HeadWaitObserved.tla"), observedModule(requests));
  const maxSends = Math.max(3, ...requests.map(r => r.sends.length));
  writeFileSync(join(dir, "trace.cfg"), traceConfig(patient, maxSends));
  const run = await runTlc(dir, "HeadWaitTrace.tla", "trace.cfg", ["HeadWait.tla", "HeadWaitTrace.tla"], tlaDir);
  if (run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir, states: run.distinctStates };
  if (run.exitCode === 0 && run.output.includes("No error has been found")) return { verdict: "REJECTED", dir, states: run.distinctStates };
  return { verdict: "TOOL_ERROR", dir, states: run.distinctStates };
}

/// What fx's own result must be for the plan, beyond the model.
function resultProblem(scenario: Scenario, run: Run): string | null {
  if (run.exit !== scenario.expect.exit) return `exit ${run.exit}, expected ${scenario.expect.exit}`;
  if (scenario.expect.output !== undefined && run.output !== scenario.expect.output) return `output ${str(run.output)}`;
  return null;
}

async function main(): Promise<number> {
  const selfCheck = process.argv.includes("--self-check");
  const only = listOption("--only");
  const seed = option("--seed", 1);
  const jobs = Math.max(1, option("--jobs", 8));
  const scenarios = [
    ...fixedScenarios.filter(s => only === null || only.includes(s.name)),
    ...randomScenarios(option("--random", 6), seed),
  ];
  const out = outDir("connection_watch");
  const scratch = join(out, "runs");
  mkdirSync(scratch, { recursive: true });
  console.log(`${scenarios.length} scenarios of ${binary} (random seed ${seed}); output ${out}`);
  const runs: Run[] = new Array(scenarios.length);
  let next = 0;
  await Promise.all(Array.from({ length: jobs }, async () => {
    while (next < scenarios.length) {
      const index = next++;
      runs[index] = await runScenario(scenarios[index]!, scratch);
    }
  }));
  writeJson(join(out, "runs.json"), runs);

  let status = 0;
  for (const [index, scenario] of scenarios.entries()) {
    const run = runs[index]!;
    const requests = requestsOf(run);
    const strays = run.connections.filter(c => c.kind === "other").map(c => c.path);
    const counted = `${run.connections.length} connections, ${requests.length} requests`;
    if (run.connections.length === 0 || strays.length > 0) {
      console.log(`TOOL_ERROR ${scenario.name}: ${counted}, unexpected paths ${str(strays.join(" "))}; ${str(run.stderr.slice(-400))}`);
      status = Math.max(status, 2);
      continue;
    }
    const design = await check(requests, "no_deadline", join(out, "tlc", scenario.name, "design"));
    const problem = resultProblem(scenario, run);
    let line = `${design.verdict.padEnd(10)} ${scenario.name}: ${counted} in ${run.seconds}s, exit ${run.exit}, ` +
      `requests ${JSON.stringify(requests)}`;
    if (design.verdict === "TOOL_ERROR") status = Math.max(status, 2);
    else if (design.verdict === "REJECTED") status = Math.max(status, 1);
    if (problem) {
      line += `; fx result: ${problem}`;
      status = Math.max(status, 1);
    }
    if (selfCheck) {
      const today = await check(requests, "none", join(out, "tlc", scenario.name, "today"));
      line += `; fx before the change: ${today.verdict}`;
      if (today.verdict === "TOOL_ERROR") status = Math.max(status, 2);
      // The cold scenario is the one a bounded wait cannot produce.
      if (scenario.name === "cold" && design.verdict === "ACCEPTED" && today.verdict !== "REJECTED") {
        line += " (must be REJECTED)";
        status = Math.max(status, 1);
      }
    }
    console.log(line);
  }
  if (selfCheck && !scenarios.some(s => s.name === "cold")) {
    console.log("--self-check needs the cold scenario");
    status = Math.max(status, 2);
  }
  console.log(status === 0 ? "ACCEPTED" : status === 1 ? "REJECTED" : "TOOL_ERROR");
  return status;
}

if (import.meta.main) {
  try {
    process.exit(await main());
  } catch (error) {
    console.error(error);
    process.exit(2);
  }
}
