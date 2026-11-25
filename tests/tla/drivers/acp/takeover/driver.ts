// Runtime driver: runs the real fx acp binary through directed plans in which a
// leader process is killed with SIGKILL and another process loads its session.
// Each plan's observations are checked against tests/tla/acp/AcpTakeover.tla
// through AcpTakeoverTrace.tla (see ./trace.ts).
//
//   bun tests/tla/drivers/acp/takeover/driver.ts               # after zig build; --model rules
//   bun tests/tla/drivers/acp/takeover/driver.ts --model today
//
// --model rules (the default) checks each run against the model with the takeover
// rules, the code after the takeover change. --model today checks against the code
// before it, which removes no folder. A plan's expected verdict under each model is
// written with the plan. The last plan changes one observation before the check,
// and must be rejected: the check does not accept a claim fx did not make.
//
// The fake Gateway in tests/e2e/tmux-helpers.ts answers each prompt. No real model
// is called. The lock file, the folders, the session log, and each process's exit
// are the evidence: each observation is something the driver did, or the binary
// wrote.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { binary, targetHelpers, targetModule, worktree } from "../../lib/context";
import { LeaderFixture } from "../leader/harness";
import { outDir, sha256File, tlcToolchain, writeJson } from "./tlc";
import { type Mutation, type Obs, type Proc, type Verdict, validate } from "./trace";

/// A pid no process of the run has: the lock line a plan forges names it.
const FORGED_PID = 2147483646;
const UNTIL_TIMEOUT_MS = 60_000;

type Expect = Record<"rules" | "today", Verdict>;

type Plan = {
  name: string;
  expect: Expect;
  /// The gateway's answers, in order. Each is a response, or a function that returns one.
  responses: (helpers: any, run: Run) => unknown[];
  /// Changes the isolated home before the first fx acp starts.
  prepare?: (fixture: LeaderFixture) => void;
  run: (r: Run) => Promise<void>;
  /// Changes the observations before they are checked, for a control.
  tamper?: (observations: Obs[]) => Obs[];
};

// ----------------------------------------------------------------- helpers --

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

async function until(condition: () => boolean, label: string, timeoutMs = UNTIL_TIMEOUT_MS): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
    await Bun.sleep(10);
  }
}

/// Whether the kernel reports no process with `pid`, or reports one.
function pidState(pid: number): "gone" | "other" {
  try {
    process.kill(pid, 0);
    return "other";
  } catch (caught) {
    if ((caught as { code?: string }).code === "ESRCH") return "gone";
    throw caught;
  }
}

function isAnswer(message: any): boolean {
  return message.result !== undefined || message.error !== undefined;
}

type Client = {
  acp: any;
  /// Every message fx wrote to this client that is not yet taken: answers,
  /// notifications, and requests such as a permission question.
  inbox: any[];
};

// --------------------------------------------------------------------- run --

/// One plan against the real binary: its processes, its requests, and the
/// observations the trace checks.
class Run {
  readonly observations: Obs[] = [];
  readonly evidence: Array<Record<string, unknown>> = [];
  readonly processes: Array<Record<string, unknown>> = [];
  /// The answer a plan's held model request waits for. Resolved after the plan.
  readonly held = deferred<unknown>();
  gateway: any = null;
  private readonly names = new Map<number, Proc>();
  private readonly clients = new Map<Proc, Client>();
  private readonly closed = new Set<Proc>();
  private readonly sockets = new Map<Proc, string>();
  private sessionId = "";

  constructor(
    readonly fixture: LeaderFixture,
    private readonly helpers: any,
    private readonly saved: any,
  ) {}

  private client(name: Proc): Client {
    const client = this.clients.get(name);
    if (!client) throw new Error(`${name} was not started`);
    return client;
  }

  private lockPath(): string {
    return join(this.saved.sessionDir(this.fixture.home, this.sessionId), "lock");
  }

  /// Starts a fx acp process, which listens on its own socket, and initializes it.
  async start(name: Proc) {
    const { acp, tmpdir } = this.fixture.spawn(true);
    this.names.set(acp.proc.pid, name);
    const client: Client = { acp, inbox: [] };
    this.clients.set(name, client);
    const { response } = await acp.call("initialize", { protocolVersion: 1 });
    if (response.error) throw new Error(`initialize failed: ${JSON.stringify(response.error)}`);
    acp.listen((message: any) => client.inbox.push(message));
    this.evidence.push({ op: "start", proc: name, pid: acp.proc.pid, tmpdir });
    this.observations.push({ op: "start", proc: name });
  }

  /// Sends a request, and returns its id. The answer is taken with `answerTo`.
  private send(name: Proc, method: string, params: Record<string, unknown>): number {
    return this.client(name).acp.send(method, params);
  }

  /// Waits for the answer to request `id`, and takes it from the inbox.
  private async answerTo(name: Proc, id: number): Promise<any> {
    const inbox = this.client(name).inbox;
    const matches = (message: any) => message.id === id && isAnswer(message);
    await until(() => inbox.some(matches), `the answer to request ${id} from ${name}`);
    return inbox.splice(inbox.findIndex(matches), 1)[0];
  }

  async newSession(name: Proc) {
    const answer = await this.answerTo(name, this.send(name, "session/new", { cwd: this.fixture.workspace, mcpServers: [] }));
    if (answer.error) throw new Error(`session/new failed: ${JSON.stringify(answer.error)}`);
    this.sessionId = answer.result.sessionId;
  }

  /// Sends a prompt, and returns its id. The prompt's answer is taken with `answerPrompt`.
  sendPrompt(name: Proc, text: string): number {
    const id = this.send(name, "session/prompt", { sessionId: this.sessionId, prompt: [{ type: "text", text }] });
    this.observations.push({ op: "prompt", proc: name });
    return id;
  }

  async answerPrompt(name: Proc, id: number) {
    const answer = await this.answerTo(name, id);
    if (answer.error) throw new Error(`session/prompt failed: ${JSON.stringify(answer.error)}`);
    if (answer.result?.stopReason !== "end_turn") throw new Error(`session/prompt answered ${JSON.stringify(answer.result)}`);
    this.observations.push({ op: "answered", proc: name, arg: "end_turn" });
  }

  async prompt(name: Proc, text: string) {
    await this.answerPrompt(name, this.sendPrompt(name, text));
  }

  /// Sends a load, and returns its id.
  sendLoad(name: Proc): number {
    const id = this.send(name, "session/load", { sessionId: this.sessionId, cwd: this.fixture.workspace, mcpServers: [] });
    this.observations.push({ op: "load", proc: name });
    return id;
  }

  /// Takes a load's answer. The observation is recorded when the answer arrives:
  /// loaded when the process holds the session, busy when another process does.
  async settleLoad(name: Proc, id: number): Promise<"loaded" | "busy"> {
    const answer = await this.answerTo(name, id);
    if (answer.error?.message === "Session is busy") {
      this.observations.push({ op: "busy", proc: name });
      return "busy";
    }
    if (answer.error) throw new Error(`session/load failed: ${JSON.stringify(answer.error)}`);
    this.observations.push({ op: "loaded", proc: name });
    return "loaded";
  }

  async load(name: Proc): Promise<"loaded" | "busy"> {
    return this.settleLoad(name, this.sendLoad(name));
  }

  /// Reads the lock file. Its record names a process the driver started, or
  /// nothing, or a process the driver did not start.
  readLock(): string {
    const text = readFileSync(this.lockPath(), "utf8");
    let target = "none";
    if (text.trim() !== "") {
      const parsed = JSON.parse(text);
      const name = this.names.get(parsed.pid);
      target = name ?? "other";
      if (name) this.sockets.set(name, parsed.socket);
    }
    this.evidence.push({ op: "read", lock: text, target });
    this.observations.push({ op: "read", proc: target });
    return target;
  }

  /// Checks whether the folder that holds the process's socket is still there.
  folder(name: Proc) {
    const socket = this.sockets.get(name);
    if (!socket) throw new Error(`no socket is known for ${name}`);
    const state = existsSync(dirname(socket)) ? "present" : "gone";
    this.evidence.push({ op: "folder", proc: name, folder: dirname(socket), state });
    this.observations.push({ op: "folder", proc: name, arg: state });
  }

  /// Replaces the lock line with a record that names a pid the run did not start.
  forge(victimSocket: string) {
    writeFileSync(this.lockPath(), `${JSON.stringify({ socket: victimSocket, pid: FORGED_PID })}\n`);
    this.evidence.push({ op: "forge", socket: victimSocket });
    this.observations.push({ op: "forge" });
  }

  /// Kills the process with SIGKILL, and observes it once it is gone. Then it
  /// asks the kernel whether the pid is still free, or another process has it.
  async kill(name: Proc) {
    const client = this.client(name);
    const pid = client.acp.proc.pid;
    client.acp.proc.kill("SIGKILL");
    const exit = await client.acp.exited;
    this.processes.push({ name, pid, how: "kill", exit, stderr: client.acp.stderr.slice(-2000) });
    this.closed.add(name);
    this.observations.push({ op: "kill", proc: name });
    const state = pidState(pid);
    this.evidence.push({ op: "pid", proc: name, pid, state });
    this.observations.push({ op: state === "gone" ? "pidgone" : "pidother", proc: name });
  }

  /// Closes the process's input, and observes its exit, which must be 0.
  async exit(name: Proc) {
    const client = this.client(name);
    const outcome = await client.acp.close();
    this.processes.push({ name, pid: client.acp.proc.pid, how: "exit", exit: outcome.exit, stderr: outcome.stderr.slice(-2000) });
    this.closed.add(name);
    if (outcome.exit !== 0) throw new Error(`fx acp exited ${outcome.exit}: ${outcome.stderr.slice(-400)}`);
    this.observations.push({ op: "exit", proc: name });
  }

  /// Waits until the session log shows the running turn as interrupted.
  async interrupted() {
    await until(
      () => this.saved.logLines(this.fixture.home, this.sessionId).some((line: any) => line.kind === "turn_interrupted"),
      "the running turn saved as interrupted",
    );
    this.observations.push({ op: "interrupted" });
  }

  /// Waits for the permission question that the process's client receives.
  async asked(name: Proc) {
    const inbox = this.client(name).inbox;
    await until(() => inbox.some((message) => message.method === "session/request_permission"), `a permission question for ${name}`);
    this.observations.push({ op: "asked", proc: name });
  }

  /// Records a permission question the process's client received, if it did.
  recordAskedIfAny(name: Proc): boolean {
    const found = this.client(name).inbox.some((message) => message.method === "session/request_permission");
    if (found) this.observations.push({ op: "asked", proc: name });
    return found;
  }

  /// Records how many model requests the gateway has seen.
  calls() {
    const count = this.gateway.requests.length;
    this.evidence.push({ op: "calls", count });
    this.observations.push({ op: "calls", arg: count });
  }

  requestCount(): number {
    return this.gateway.requests.length;
  }

  /// Stops any process a plan left running, and resolves a held model request.
  async finish() {
    this.held.resolve(this.helpers.fakeGatewayFinalText("UNUSED"));
    for (const [name, client] of this.clients) {
      if (this.closed.has(name)) continue;
      await client.acp.close().catch(() => undefined);
    }
  }
}

// -------------------------------------------------------------------- plans --

type Loader = "p2" | "p3";

const FIRST = "FIRST_PROMPT";
const AFTER = "AFTER_PROMPT";

const PLANS: Plan[] = [
  {
    name: "p1-kill-then-load",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    responses: (h) => [() => h.fakeGatewayFinalText("FIRST_DONE"), () => h.fakeGatewayFinalText("AFTER_DONE")],
    run: async (r) => {
      await r.start("p1");
      await r.newSession("p1");
      await r.prompt("p1", FIRST);
      r.readLock();
      await r.kill("p1");
      r.readLock();
      await r.start("p2");
      await r.load("p2");
      r.readLock();
      r.folder("p1");
      await r.exit("p2");
    },
  },
  {
    name: "p2-kill-running-turn-then-load",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    responses: (h, run) => [
      () => h.fakeGatewayFinalText("FIRST_DONE"),
      () => run.held.promise,
      () => h.fakeGatewayFinalText("AFTER_DONE"),
    ],
    run: async (r) => {
      await r.start("p1");
      await r.newSession("p1");
      await r.prompt("p1", FIRST);
      r.readLock();
      r.sendPrompt("p1", "HELD_PROMPT");
      await until(() => r.requestCount() === 2, "the held model request");
      r.calls();
      await r.kill("p1");
      r.readLock();
      await r.start("p2");
      await r.load("p2");
      await r.interrupted();
      r.calls();
      r.readLock();
      r.folder("p1");
      await r.prompt("p2", AFTER);
      r.calls();
      await r.exit("p2");
    },
  },
  {
    name: "p3-kill-open-question-then-load",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    prepare: (fixture) => {
      const external = join(fixture.root, "external");
      mkdirSync(external, { recursive: true });
      writeFileSync(
        join(fixture.home, ".fx", "settings.json"),
        `${JSON.stringify({ session_titles: false, permission: { edit: { [`${external}/**`]: "ask" } } })}\n`,
        { mode: 0o600 },
      );
    },
    responses: (h, run) => [
      () => h.fakeGatewayFinalText("FIRST_DONE"),
      () =>
        h.fakeGatewayToolCall("question_call_1", "write_file", {
          path: join(run.fixture.root, "external", "question.txt"),
          content: "held\n",
        }),
      () => h.fakeGatewayFinalText("AFTER_DONE"),
    ],
    run: async (r) => {
      await r.start("p1");
      await r.newSession("p1");
      await r.prompt("p1", FIRST);
      r.readLock();
      r.sendPrompt("p1", "QUESTION_PROMPT");
      await r.asked("p1");
      await r.kill("p1");
      r.readLock();
      await r.start("p2");
      await r.load("p2");
      await r.interrupted();
      r.calls();
      r.folder("p1");
      await r.prompt("p2", AFTER);
      r.recordAskedIfAny("p2");
      r.calls();
      await r.exit("p2");
    },
  },
  {
    name: "p4-two-loads-after-kill",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    responses: (h) => [() => h.fakeGatewayFinalText("FIRST_DONE")],
    run: async (r) => {
      await r.start("p1");
      await r.newSession("p1");
      await r.prompt("p1", FIRST);
      r.readLock();
      await r.kill("p1");
      r.readLock();
      await r.start("p2");
      await r.start("p3");
      const pending = {
        p2: r.settleLoad("p2", r.sendLoad("p2")),
        p3: r.settleLoad("p3", r.sendLoad("p3")),
      };
      const first = await Promise.race([
        pending.p2.then((outcome) => ({ name: "p2" as Loader, outcome })),
        pending.p3.then((outcome) => ({ name: "p3" as Loader, outcome })),
      ]);
      const other: Loader = first.name === "p2" ? "p3" : "p2";
      const second = await pending[other];
      if (first.outcome !== "loaded" && second !== "loaded") throw new Error("neither load took the lock");
      const holder: Loader = first.outcome === "loaded" ? first.name : other;
      const waiter: Loader = holder === "p2" ? "p3" : "p2";
      r.readLock();
      r.folder("p1");
      await r.exit(waiter);
      await r.exit(holder);
    },
  },
  {
    name: "p5-forged-lock-then-load",
    expect: { rules: "ACCEPTED", today: "ACCEPTED" },
    responses: (h) => [() => h.fakeGatewayFinalText("FIRST_DONE")],
    run: async (r) => {
      await r.start("p1");
      await r.newSession("p1");
      await r.prompt("p1", FIRST);
      r.readLock();
      await r.kill("p1");
      const victim = join(r.fixture.root, "victim");
      mkdirSync(victim, { recursive: true });
      writeFileSync(join(victim, "keep.txt"), "keep\n");
      writeFileSync(join(victim, "s"), "");
      r.forge(join(victim, "s"));
      r.readLock();
      await r.start("p2");
      await r.load("p2");
      r.readLock();
      r.folder("p1");
      await r.exit("p2");
    },
  },
  {
    name: "p6-live-leader-folder-stays",
    expect: { rules: "ACCEPTED", today: "ACCEPTED" },
    responses: (h) => [() => h.fakeGatewayFinalText("FIRST_DONE")],
    run: async (r) => {
      await r.start("p1");
      await r.newSession("p1");
      await r.prompt("p1", FIRST);
      r.readLock();
      await r.start("p2");
      await r.load("p2");
      r.readLock();
      r.folder("p1");
      await r.exit("p2");
      await r.exit("p1");
    },
  },
  {
    name: "p7-tampered-live-folder-claim",
    expect: { rules: "REJECTED", today: "REJECTED" },
    responses: (h) => [() => h.fakeGatewayFinalText("FIRST_DONE")],
    run: async (r) => {
      await r.start("p1");
      await r.newSession("p1");
      await r.prompt("p1", FIRST);
      r.readLock();
      await r.start("p2");
      await r.load("p2");
      r.readLock();
      r.folder("p1");
      await r.exit("p2");
      await r.exit("p1");
    },
    tamper: (observations) => observations.map((o) => (o.op === "folder" ? { ...o, arg: "gone" } : o)),
  },
];

// --------------------------------------------------------------------- main --

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(["git", "-C", worktree, ...args], { stdout: "pipe", stderr: "pipe" });
  return new TextDecoder().decode(result.stdout).trim();
}

/// One plan against the real binary: its observations, and the evidence.
async function runPlan(plan: Plan, dir: string, helpers: any, saved: any) {
  mkdirSync(dir, { recursive: true });
  const fixture = new LeaderFixture(binary, helpers.FAKE_GATEWAY_MODEL);
  plan.prepare?.(fixture);
  const run = new Run(fixture, helpers, saved);
  fixture.init(helpers.startFakeGateway(plan.responses(helpers, run)));
  run.gateway = fixture.gateway;
  let error: string | null = null;
  try {
    await plan.run(run);
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    await run.finish();
    fixture.dispose();
  }
  writeJson(join(dir, "observations.json"), run.observations);
  writeJson(join(dir, "evidence.json"), run.evidence);
  writeJson(join(dir, "processes.json"), run.processes);
  return { run, error };
}

async function main() {
  if (!existsSync(binary)) throw new Error(`missing ${binary}; run zig build first or set FX_BIN`);
  const model = argValue("--model") ?? "rules";
  if (model !== "rules" && model !== "today") throw new Error(`--model must be rules or today, not ${model}`);
  const mutation: Mutation = model === "rules" ? "none" : "today";
  const helpers = await targetHelpers();
  const saved = await targetModule("saved-sessions.ts");
  const reportDir = outDir(`acp-takeover-driver-${model}`);
  writeJson(join(reportDir, "manifest.json"), {
    model,
    mutation,
    worktree,
    binary,
    head: git("rev-parse", "HEAD"),
    dirty: git("status", "--porcelain").length > 0,
    fx_binary_sha256: sha256File(binary),
    toolchain: tlcToolchain(),
    bun: Bun.version,
    argv: process.argv.slice(1),
  });

  const results = [];
  for (const plan of PLANS) {
    const dir = join(reportDir, "traces", plan.name);
    const { run, error } = await runPlan(plan, dir, helpers, saved);
    const observations = plan.tamper ? plan.tamper(run.observations) : run.observations;
    const checked = error ? null : await validate(observations, dir, mutation);
    const verdict: Verdict | "RUN_ERROR" = error ? "RUN_ERROR" : checked!.verdict;
    const expected = plan.expect[model];
    const ok = verdict === expected;
    results.push({
      name: plan.name,
      verdict,
      matched: checked?.matched ?? 0,
      length: observations.length,
      expected,
      ok,
      error,
      tampered: Boolean(plan.tamper),
      firstDivergence: checked?.firstDivergence ?? null,
    });
    console.log(
      `${plan.name}: ${verdict} (${checked?.matched ?? 0}/${observations.length})${ok ? "" : ` UNEXPECTED, expected ${expected}`}${error ? ` ${error}` : ""}`,
    );
    console.log(`  ops: ${observations.map((o) => `${o.op}(${o.proc ?? ""}${o.arg !== undefined ? `,${o.arg}` : ""})`).join(" ")}`);
    writeJson(join(dir, "run.json"), {
      plan: plan.name,
      model,
      verdict,
      matched: checked?.matched ?? 0,
      expected,
      error,
      tampered: Boolean(plan.tamper),
      firstDivergence: checked?.firstDivergence ?? null,
      observations,
    });
  }
  writeJson(join(reportDir, "results.json"), results);
  const failed = results.filter((result) => !result.ok);
  console.log(`${results.length - failed.length} of ${results.length} plans as expected under ${model}; reports in ${reportDir}`);
  if (failed.length > 0) process.exit(1);
}

await main();
