// Runtime driver: runs the real fx acp binary through four directed plans. In each
// plan a session's lock is read, the socket the lock names is connected, and the
// process is asked whether it leads the session. Each run is then checked against
// tests/tla/acp/AcpLeader.tla through AcpLeaderTrace.tla.
//
//   bun tests/tla/drivers/acp/leader/driver.ts               # after zig build
//   bun tests/tla/drivers/acp/leader/driver.ts --model today
//
// --model rules (the default) validates each run with Records TRUE: a holder
// records its socket in the lock file. --model today validates with Records FALSE,
// fx acp before the record. Each observation is something the driver did, or
// something the real binary wrote: the lock file's bytes, the socket's reply, or a
// process's exit. No model calls: the fake Gateway in tests/e2e/tmux-helpers.ts
// answers each plan's one prompt.
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, targetModule, worktree } from "../../lib/context";
import { Acp, LeaderFixture, askSocket } from "./harness";
import { outDir, sha256File, tlcToolchain, writeJson } from "./tlc";
import { type Observation, type Proc, type Verdict, validate } from "./trace";

// ------------------------------------------------------------------- plans --

type Plan = {
  name: string;
  /// The verdict each model is expected to give the run, as the plan was written.
  expect: Record<"rules" | "today", Verdict>;
  run: (run: Run) => Promise<void>;
};

const PLANS: Plan[] = [
  {
    name: "d1-lead-then-exit",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    run: async (r) => {
      await r.start("p1", true);
      await r.publish();
      await r.readAndConnect();
      await r.exit("p1");
      await r.readAndConnect();
    },
  },
  {
    name: "d2-kill-then-load",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    run: async (r) => {
      await r.start("p1", true);
      await r.publish();
      await r.readAndConnect();
      await r.kill("p1");
      await r.readAndConnect();
      await r.start("p2", true);
      await r.load();
      await r.readAndConnect();
    },
  },
  {
    name: "d3-no-socket",
    expect: { rules: "ACCEPTED", today: "ACCEPTED" },
    run: async (r) => {
      await r.start("p1", false);
      await r.publish();
      await r.readAndConnect();
    },
  },
  {
    name: "d4-dead-record-then-no-socket",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    run: async (r) => {
      await r.start("p1", true);
      await r.publish();
      await r.readAndConnect();
      await r.kill("p1");
      await r.readAndConnect();
      await r.start("p2", false);
      await r.load();
      await r.readAndConnect();
    },
  },
];

// ------------------------------------------------------------ observations --

type Live = { name: Proc; acp: Acp; tmpdir: string; canListen: boolean };

/// One plan's run against the real binary. It keeps the observations the trace
/// validates, and the evidence each one came from: the lock file's bytes, each
/// socket's reply, and each process's exit.
class Run {
  readonly observations: Observation[] = [];
  readonly evidence: Array<Record<string, unknown>> = [];
  readonly processes: Array<Record<string, unknown>> = [];
  private readonly names = new Map<number, Proc>();
  private live: Live | null = null;
  private sessionId: string | null = null;
  private record: { socket: string; pid: number } | null = null;

  constructor(
    private readonly fixture: LeaderFixture,
    private readonly sessionDir: (home: string, id: string) => string,
  ) {}

  private current(): Live {
    if (!this.live) throw new Error("no fx acp process is running");
    return this.live;
  }

  private session(): string {
    if (!this.sessionId) throw new Error("no session yet");
    return this.sessionId;
  }

  /// Starts an fx acp process and initializes it. The start is observed when the
  /// process is spawned.
  async start(name: Proc, canListen: boolean) {
    const { acp, tmpdir } = this.fixture.spawn(canListen);
    this.names.set(acp.proc.pid, name);
    this.live = { name, acp, tmpdir, canListen };
    this.observations.push({ op: "start", proc: name, canListen });
    const { response } = await acp.call("initialize", { protocolVersion: 1 });
    if (response.error) throw new Error(`initialize failed: ${JSON.stringify(response.error)}`);
    this.evidence.push({ op: "start", proc: name, pid: acp.proc.pid, tmpdir, canListen });
  }

  /// Opens a session and sends one prompt, which makes the session live. The
  /// publish is observed once fx has answered the prompt.
  async publish() {
    const live = this.current();
    const created = await live.acp.call("session/new", { cwd: this.fixture.workspace, mcpServers: [] });
    if (created.response.error) throw new Error(`session/new failed: ${JSON.stringify(created.response.error)}`);
    this.sessionId = created.response.result.sessionId;
    const prompted = await live.acp.call("session/prompt", {
      sessionId: this.session(),
      prompt: [{ type: "text", text: `LEADER_PROMPT_${live.name}` }],
    });
    if (prompted.response.error) throw new Error(`session/prompt failed: ${JSON.stringify(prompted.response.error)}`);
    if (prompted.response.result?.stopReason !== "end_turn") {
      throw new Error(`session/prompt answered ${JSON.stringify(prompted.response.result)}`);
    }
    this.observations.push({ op: "published", proc: live.name });
  }

  /// Loads the session in the running process. The publish is observed once fx
  /// has answered the load.
  async load() {
    const live = this.current();
    const loaded = await live.acp.call("session/load", {
      sessionId: this.session(),
      cwd: this.fixture.workspace,
      mcpServers: [],
    });
    if (loaded.response.error) throw new Error(`session/load failed: ${JSON.stringify(loaded.response.error)}`);
    this.observations.push({ op: "published", proc: live.name });
  }

  /// Reads the session's lock file. A read that names a process is followed by a
  /// connect to the socket it names, and by an ask when the connect succeeds.
  async readAndConnect() {
    const target = this.readLock();
    if (target === "p1" || target === "p2") await this.connectAndAsk();
  }

  private readLock(): "none" | Proc | "other" {
    const path = join(this.sessionDir(this.fixture.home, this.session()), "lock");
    const text = readFileSync(path, "utf8");
    this.evidence.push({ op: "read", lock: text });
    this.record = null;
    let target: "none" | Proc | "other" = "none";
    if (text.trim() !== "") {
      const parsed = JSON.parse(text);
      this.record = { socket: parsed.socket, pid: parsed.pid };
      target = this.names.get(parsed.pid) ?? "other";
    }
    this.observations.push({ op: "read", target });
    return target;
  }

  private async connectAndAsk() {
    const record = this.record;
    if (!record) throw new Error("connect with no record");
    const request = { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } };
    const answer = await askSocket(record.socket, request);
    this.observations.push({ op: "connect", result: answer.connected ? "connected" : "stale" });
    this.evidence.push({ op: "connect", socket: record.socket, connected: answer.connected, reply: answer.reply });
    if (!answer.connected) return;
    const meta = answer.reply?.result?._meta?.["sh.fx/leader"];
    const found = meta?.pid === record.pid && Array.isArray(meta?.sessions) && meta.sessions.includes(this.session());
    this.observations.push({ op: "ask", result: found ? "found" : "notleader" });
  }

  /// Closes the process's input, and observes its exit, which must be 0.
  async exit(name: Proc) {
    const live = this.current();
    const outcome = await live.acp.close();
    this.processes.push({ name, pid: live.acp.proc.pid, how: "exit", exit: outcome.exit, stderr: outcome.stderr.slice(-2000) });
    this.live = null;
    if (outcome.exit !== 0) throw new Error(`fx acp exited ${outcome.exit}: ${outcome.stderr.slice(-400)}`);
    this.observations.push({ op: "exit", proc: name });
  }

  /// Kills the process, and observes it once it is gone.
  async kill(name: Proc) {
    const live = this.current();
    live.acp.proc.kill("SIGKILL");
    const exit = await live.acp.exited;
    this.processes.push({ name, pid: live.acp.proc.pid, how: "kill", exit, stderr: live.acp.stderr.slice(-2000) });
    this.live = null;
    this.observations.push({ op: "kill", proc: name });
  }

  /// Stops any process a plan left running, after its last step.
  async finish() {
    if (this.live) await this.exit(this.live.name).catch(() => undefined);
  }
}

function describe(o: Observation): string {
  switch (o.op) {
    case "start":
      return `start(${o.proc},${o.canListen ? "listen" : "no-socket"})`;
    case "published":
      return `published(${o.proc})`;
    case "read":
      return `read(${o.target})`;
    case "connect":
      return `connect(${o.result})`;
    case "ask":
      return `ask(${o.result})`;
    case "exit":
      return `exit(${o.proc})`;
    case "kill":
      return `kill(${o.proc})`;
  }
}

/// One plan against the real binary, with the observations and evidence it produced.
async function runPlan(plan: Plan, dir: string, helpers: any, sessionDir: (home: string, id: string) => string) {
  mkdirSync(dir, { recursive: true });
  const fixture = new LeaderFixture(binary, helpers.FAKE_GATEWAY_MODEL);
  fixture.init(helpers.startFakeGateway([() => helpers.fakeGatewayFinalText("LEADER_DONE_1")]));
  const run = new Run(fixture, sessionDir);
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

// -------------------------------------------------------------------- main --

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(["git", "-C", worktree, ...args], { stdout: "pipe", stderr: "pipe" });
  return new TextDecoder().decode(result.stdout).trim();
}

async function main() {
  if (!existsSync(binary)) throw new Error(`missing ${binary}; run zig build first or set FX_BIN`);
  const model = argValue("--model") ?? "rules";
  if (model !== "rules" && model !== "today") throw new Error(`--model must be rules or today, not ${model}`);
  const helpers = await targetHelpers();
  const saved = await targetModule("saved-sessions.ts");
  const reportDir = outDir(`acp-leader-${model}`);
  writeJson(join(reportDir, "manifest.json"), {
    model,
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
    const { run, error } = await runPlan(plan, dir, helpers, saved.sessionDir);
    const checked = error ? null : await validate(run.observations, dir, model === "rules");
    const verdict: Verdict | "RUN_ERROR" = error ? "RUN_ERROR" : checked!.verdict;
    const matched = checked?.matched ?? 0;
    const expected = plan.expect[model];
    const ok = verdict === expected;
    results.push({ name: plan.name, verdict, matched, length: run.observations.length, expected, ok, error, firstDivergence: checked?.firstDivergence ?? null });
    console.log(`${plan.name}: ${verdict} (${matched}/${run.observations.length})${ok ? "" : ` UNEXPECTED, expected ${expected}`}${error ? ` ${error}` : ""}`);
    console.log(`  ops: ${run.observations.map(describe).join(" ")}`);
    writeJson(join(dir, "run.json"), { plan: plan.name, model, verdict, matched, expected, error, firstDivergence: checked?.firstDivergence ?? null, observations: run.observations });
  }
  writeJson(join(reportDir, "summary.json"), { model, results });
  console.log(`report: ${reportDir}`);
  process.exit(results.every((result) => result.ok) ? 0 : 1);
}

await main();
