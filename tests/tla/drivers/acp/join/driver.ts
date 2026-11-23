// Runtime driver: runs the real fx acp binary through six plans in which a second
// connection joins a session on the leader socket, and checks each run against
// tests/tla/acp/AcpJoin.tla through AcpJoinTrace.tla. The owner's turns and each
// follower's answers and messages are what fx wrote. The driver starts each turn,
// holds the second turn's model reply and releases it, and orders every step by
// what it has read, never by timing. No model calls: the fake Gateway in
// tests/e2e/tmux-helpers.ts answers each request.
//
//   bun tests/tla/drivers/acp/join/driver.ts                          # --model rules
//   bun tests/tla/drivers/acp/join/driver.ts --model today            # the control
//   bun tests/tla/drivers/acp/join/driver.ts --model rules --plan load-running
//
// --model rules (the default) validates each run with Rules TRUE: fx joins a
// session another connection has open. --model today validates with Rules FALSE,
// fx before the join, where a second connection's load or resume is refused. Each
// plan expects rules ACCEPTED and today REJECTED.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, targetModule, worktree } from "../../lib/context";
import { Acp, clientCapabilities } from "../disconnect/harness";
import { LeaderFixture } from "../leader/harness";
import { FrameStream, SocketClient, deferred, framesItems, isAgentText, isAnswer, textItems } from "./harness";
import { type Joiner, type Observation, type Verdict, validate } from "./trace";
import { outDir, sha256File, tlcToolchain, writeJson } from "./tlc";

// ------------------------------------------------------------------- plans --

type Plan = {
  name: string;
  /// The verdict each model is expected to give the run, as the plan was written.
  expect: Record<"rules" | "today", Verdict>;
  run: (run: Run) => Promise<void>;
};

const PLANS: Plan[] = [
  {
    name: "load-running",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    run: async (r) => {
      await r.turn(1);
      await r.startTurn(2);
      await r.waitOwnerText(2, 1);
      await r.waitGatewayRequests(3);
      await r.join("j1", "session/load");
      await r.releaseHeld();
      await r.waitOwnerAnswer(2);
      await r.waitFollowerText("j1", 2, 2);
      await r.finish();
    },
  },
  {
    name: "resume-running",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    run: async (r) => {
      await r.turn(1);
      await r.startTurn(2);
      await r.waitOwnerText(2, 1);
      await r.waitGatewayRequests(3);
      await r.join("j1", "session/resume");
      await r.releaseHeld();
      await r.waitOwnerAnswer(2);
      await r.waitFollowerText("j1", 2, 2);
      await r.finish();
    },
  },
  {
    name: "load-idle",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    run: async (r) => {
      await r.turn(1);
      await r.startTurn(2);
      await r.waitOwnerText(2, 1);
      await r.waitGatewayRequests(3);
      await r.releaseHeld();
      await r.waitOwnerAnswer(2);
      await r.join("j1", "session/load");
      await r.finish();
    },
  },
  {
    name: "load-then-close",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    run: async (r) => {
      await r.turn(1);
      await r.startTurn(2);
      await r.waitOwnerText(2, 1);
      await r.waitGatewayRequests(3);
      await r.join("j1", "session/load");
      await r.closeFollower("j1");
      await r.releaseHeld();
      await r.waitOwnerAnswer(2);
      await r.finish();
    },
  },
  {
    name: "follower-change",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    run: async (r) => {
      await r.turn(1);
      await r.startTurn(2);
      await r.waitOwnerText(2, 1);
      await r.waitGatewayRequests(3);
      await r.join("j1", "session/load");
      await r.followerChange("j1");
      await r.releaseHeld();
      await r.waitOwnerAnswer(2);
      await r.waitFollowerText("j1", 2, 2);
      await r.finish();
    },
  },
  {
    name: "two-followers",
    expect: { rules: "ACCEPTED", today: "REJECTED" },
    run: async (r) => {
      await r.turn(1);
      await r.startTurn(2);
      await r.waitOwnerText(2, 1);
      await r.waitGatewayRequests(3);
      await r.join("j1", "session/load");
      await r.join("j2", "session/resume");
      await r.releaseHeld();
      await r.waitOwnerAnswer(2);
      await r.waitFollowerText("j1", 2, 2);
      await r.waitFollowerText("j2", 2, 2);
      await r.finish();
    },
  },
];

// ------------------------------------------------------------ observations --

const WAIT_MS = 60_000;
// How long fx may stay up after its input ends while a follower is joined. fx exits as soon as
// nothing is left to serve, so a process that exits inside this window fails the plan.
const KEPT_WINDOW_MS = 2_000;
const REFUSAL = "This session is open on another connection; only that connection can change it.";

/// One plan's run against the real binary. The owner's frames become steps as
/// the driver reads them, in the order fx wrote them; each follower's answers and
/// its items at the end become steps at the point the driver asks for them.
class Run {
  readonly observations: Observation[] = [];
  readonly evidence: Array<Record<string, unknown>> = [];
  readonly processes: Array<Record<string, unknown>> = [];
  private owner: Acp | null = null;
  private readonly stream = new FrameStream();
  private drained = 0;
  private sessionId = "";
  private readonly turnOfPrompt = new Map<number, number>();
  private readonly followers = new Map<Joiner, { client: SocketClient; requestId: number }>();
  private readonly left = new Set<Joiner>();
  private holdReleased = false;

  constructor(
    private readonly fixture: LeaderFixture,
    private readonly helpers: any,
    private readonly gateway: any,
    private readonly hold: { resolve: (value: unknown) => void },
    private readonly sessionDir: (home: string, id: string) => string,
  ) {}

  /// Whether `who` joined the session: a follower the model never listed has no steps.
  joined(who: Joiner): boolean {
    return this.followers.has(who);
  }

  private async ensureOwner() {
    if (this.owner) return;
    const { acp } = this.fixture.spawn(true);
    this.owner = acp;
    acp.listen((message) => this.stream.push(message));
    const init = await this.ownerCall("initialize", { protocolVersion: 1, clientCapabilities: clientCapabilities(false) });
    if (init.error) throw new Error(`initialize failed: ${JSON.stringify(init.error)}`);
    const created = await this.ownerCall("session/new", { cwd: this.fixture.workspace, mcpServers: [] });
    if (created.error) throw new Error(`session/new failed: ${JSON.stringify(created.error)}`);
    this.sessionId = created.result.sessionId;
    this.evidence.push({ op: "owner", pid: acp.proc.pid, sessionId: this.sessionId });
  }

  private async ownerCall(method: string, params: object): Promise<any> {
    const id = this.owner!.send(method, params);
    await this.stream.until((frames) => frames.some((frame) => isAnswer(frame) && frame.id === id), `the owner's answer to ${method}`, WAIT_MS);
    return this.stream.frames.find((frame) => isAnswer(frame) && frame.id === id);
  }

  /// Turns the owner's frames read so far into steps, in the order fx wrote them:
  /// each labelled text is a send, and each prompt's answer is an end.
  private drain() {
    const frames = this.stream.frames;
    for (; this.drained < frames.length; this.drained++) {
      const frame = frames[this.drained];
      if (isAgentText(frame)) {
        for (const value of textItems(frame.params.update.content?.text ?? "")) {
          this.observations.push({ op: "send", item: value });
        }
      } else if (isAnswer(frame) && this.turnOfPrompt.has(frame.id)) {
        const turn = this.turnOfPrompt.get(frame.id)!;
        if (frame.error) throw new Error(`prompt ${turn} failed: ${JSON.stringify(frame.error)}`);
        if (frame.result?.stopReason !== "end_turn") {
          throw new Error(`prompt ${turn} answered ${JSON.stringify(frame.result)}`);
        }
        this.observations.push({ op: "end", turn });
      }
    }
  }

  /// Sends the owner's prompt for `turn`. The driver's start is recorded before
  /// the prompt goes out, since the model starts a turn only then.
  async startTurn(turn: number) {
    await this.ensureOwner();
    this.drain();
    this.observations.push({ op: "start" });
    const id = this.owner!.send("session/prompt", {
      sessionId: this.sessionId,
      prompt: [{ type: "text", text: `TRACE_PROMPT_${turn}` }],
    });
    this.turnOfPrompt.set(id, turn);
  }

  /// Runs a turn to its answer.
  async turn(n: number) {
    await this.startTurn(n);
    await this.waitOwnerAnswer(n);
  }

  /// Waits until the owner has been sent the labelled text T<turn>K<k>.
  async waitOwnerText(turn: number, k: number) {
    const label = `T${turn}K${k}.`;
    await this.stream.until(
      (frames) => frames.some((frame) => isAgentText(frame) && (frame.params.update.content?.text ?? "").includes(label)),
      `the owner's text ${label}`,
      WAIT_MS,
    );
    this.drain();
  }

  /// Waits until the owner has answered the prompt of `turn`.
  async waitOwnerAnswer(turn: number) {
    const id = [...this.turnOfPrompt].find(([, value]) => value === turn)?.[0];
    if (id === undefined) throw new Error(`no prompt for turn ${turn}`);
    await this.stream.until((frames) => frames.some((frame) => isAnswer(frame) && frame.id === id), `the owner's answer to turn ${turn}`, WAIT_MS);
    this.drain();
  }

  /// Waits until the fake Gateway has received `count` model requests. Its
  /// requests are what fx wrote, so this is evidence, not a delay.
  async waitGatewayRequests(count: number) {
    const deadline = Date.now() + WAIT_MS;
    while (this.gateway.requests.length < count) {
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${count} model requests`);
      await Bun.sleep(20);
    }
  }

  /// Waits until `who` has received the items T<turn>K<k>.
  async waitFollowerText(who: Joiner, turn: number, k: number) {
    const follower = this.followers.get(who);
    if (!follower) return;
    await follower.client.stream.until(
      (frames) => framesItems(frames, null).some((value) => value.t === turn && value.k === k),
      `${who} to receive T${turn}K${k}.`,
      WAIT_MS,
    );
  }

  /// Releases the second turn's held model reply, with its final text.
  releaseHeld() {
    if (this.holdReleased) throw new Error("the held reply is already released");
    this.holdReleased = true;
    this.hold.resolve(this.helpers.fakeGatewayFinalText("T2K2."));
  }

  /// Connects `who` to the session's leader socket, and asks fx to join it. The
  /// join is recorded from fx's answer: its items up to the answer, or its refusal.
  async join(who: Joiner, method: "session/load" | "session/resume"): Promise<boolean> {
    await this.ensureOwner();
    this.drain();
    const lock = readFileSync(join(this.sessionDir(this.fixture.home, this.sessionId), "lock"), "utf8");
    const socket = JSON.parse(lock).socket as string;
    this.evidence.push({ op: "lock", who, method, lock });
    const client = await SocketClient.connect(socket);
    const init = await client.request("initialize", { protocolVersion: 1, clientCapabilities: clientCapabilities(false) });
    if (init.answer.error) throw new Error(`${who} initialize failed: ${JSON.stringify(init.answer.error)}`);
    const { id, answer, index } = await client.request(method, {
      sessionId: this.sessionId,
      cwd: this.fixture.workspace,
      mcpServers: [],
    });
    const resume = method === "session/resume";
    if (answer.error) {
      client.close();
      this.observations.push({ op: resume ? "resume_refused" : "load_refused", who });
      this.evidence.push({ op: "refused", who, method, error: answer.error });
      return false;
    }
    this.observations.push({
      op: resume ? "resume" : "load",
      who,
      seq: framesItems(client.stream.frames.slice(0, index + 1), id),
    });
    this.followers.set(who, { client, requestId: id });
    return true;
  }

  /// Sends the follower's session/close and records fx's answer.
  async closeFollower(who: Joiner) {
    const follower = this.followers.get(who);
    if (!follower) return;
    this.drain();
    const { answer } = await follower.client.request("session/close", { sessionId: this.sessionId });
    const closed = !answer.error && JSON.stringify(answer.result) === "{}";
    this.observations.push(closed ? { op: "close", who } : { op: "close_failed", who });
    this.left.add(who);
  }

  /// Sends the follower the two changes that stay refused while it follows the
  /// session: a mode change and a config change. Each answer is recorded: fx's
  /// refusal to change a session another connection has open, or anything else.
  /// A follower's prompt is not sent here. It enters the session's one input order
  /// (sh-fx.md, "Following a session"), which this model does not cover.
  async followerChange(who: Joiner) {
    const follower = this.followers.get(who);
    if (!follower) return;
    const changes: Array<[string, Record<string, unknown>]> = [
      ["session/set_mode", { sessionId: this.sessionId, modeId: "plan" }],
      ["session/set_config_option", { sessionId: this.sessionId, configId: "model", value: "test/other" }],
    ];
    for (const [method, params] of changes) {
      this.drain();
      const { answer } = await follower.client.request(method, params);
      const refused = answer.error?.code === -32600 && answer.error?.message === REFUSAL;
      this.observations.push(refused ? { op: "change_refused", who } : { op: "change_other", who });
    }
  }

  /// After fx exits: every message the owner received, then each joined
  /// follower's full sequence, which its socket delivered before it closed.
  async finish() {
    this.drain();
    if (this.owner) {
      const acp = this.owner;
      acp.disconnect();
      const kept = await acp.waitForExit(KEPT_WINDOW_MS);
      const joined = [...this.followers.keys()].some((who) => !this.left.has(who));
      if (kept.exited && joined) throw new Error("fx acp exited while a follower was still joined");
      for (const who of this.followers.keys()) {
        if (!this.left.has(who)) await this.closeFollower(who);
        this.followers.get(who)?.client.close();
      }
      const outcome = await acp.waitForExit(WAIT_MS);
      this.owner = null;
      this.processes.push({ how: "exit", pid: acp.proc.pid, exit: outcome.code ?? -1, stderr: acp.stderr.slice(-2000) });
      if (!outcome.exited) throw new Error(`fx acp did not exit after its last client left: ${acp.stderr.slice(-400)}`);
      if (outcome.code !== 0) throw new Error(`fx acp exited ${outcome.code}: ${acp.stderr.slice(-400)}`);
    }
    this.drain();
    this.evidence.push({ op: "gateway", requests: this.gateway.requests.length });
    for (const [who, { client, requestId }] of this.followers) {
      await client.stream.until(() => client.stream.closed, `${who}'s connection to close after fx exited`, WAIT_MS);
      this.observations.push({ op: "finish", who, seq: framesItems(client.stream.frames, requestId) });
    }
  }

  /// Stops what this run started: its followers' connections, and fx if a plan failed first.
  dispose() {
    for (const { client } of this.followers.values()) client.close();
    if (this.owner) this.owner.proc.kill("SIGKILL");
    this.owner = null;
  }
}

function describe(o: Observation): string {
  switch (o.op) {
    case "start":
      return "start";
    case "send":
      return `send(${o.item.t === 0 ? "other" : `T${o.item.t}K${o.item.k}`})`;
    case "end":
      return `end(${o.turn})`;
    case "load":
    case "resume":
      return `${o.op}(${o.who},${o.seq.length})`;
    case "finish":
      return `finish(${o.who},${o.seq.length})`;
    default:
      return `${o.op}(${o.who})`;
  }
}

/// One plan against the real binary, with the observations and evidence it produced.
async function runPlan(plan: Plan, dir: string, helpers: any, sessionDir: (home: string, id: string) => string) {
  mkdirSync(dir, { recursive: true });
  const fixture = new LeaderFixture(binary, helpers.FAKE_GATEWAY_MODEL);
  const hold = deferred<unknown>();
  const gateway = helpers.startFakeGateway([
    () => helpers.fakeGatewayFinalText("T1K1."),
    () => helpers.fakeGatewaySerializedToolCall("join_read_2", "read_file", JSON.stringify({ path: "notes.md" }), "T2K1."),
    () => hold.promise,
  ]);
  fixture.init(gateway);
  writeFileSync(join(fixture.workspace, "notes.md"), "JOIN_NOTES\n");
  const run = new Run(fixture, helpers, gateway, hold, sessionDir);
  let error: string | null = null;
  try {
    await plan.run(run);
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    run.dispose();
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
  const only = argValue("--plan");
  const plans = only === undefined ? PLANS : PLANS.filter((plan) => plan.name === only);
  if (plans.length === 0) throw new Error(`no plan named ${only}`);
  const helpers = await targetHelpers();
  const saved = await targetModule("saved-sessions.ts");
  const reportDir = outDir(`acp-join-${model}`);
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
  console.log(`report: ${reportDir}`);

  const results = [];
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const { run, error } = await runPlan(plan, dir, helpers, saved.sessionDir);
    const checked = error ? null : await validate(run.observations, dir, model === "rules");
    const verdict: Verdict | "RUN_ERROR" = error ? "RUN_ERROR" : checked!.verdict;
    const matched = checked?.matched ?? 0;
    const expected = plan.expect[model];
    const ok = verdict === expected;
    results.push({
      name: plan.name,
      verdict,
      matched,
      length: run.observations.length,
      expected,
      ok,
      error,
      firstDivergence: checked?.firstDivergence ?? null,
    });
    writeJson(join(dir, "run.json"), {
      plan: plan.name,
      model,
      verdict,
      matched,
      expected,
      error,
      firstDivergence: checked?.firstDivergence ?? null,
      observations: run.observations,
    });
    console.log(`  ops: ${run.observations.map(describe).join(" ")}`);
    console.log(
      `${plan.name}: ${verdict} (${matched}/${run.observations.length})${ok ? "" : ` UNEXPECTED, expected ${expected}`}${error ? ` ${error}` : ""}`,
    );
  }
  writeJson(join(reportDir, "summary.json"), { model, results });
  process.exit(results.every((result) => result.ok) ? 0 : 1);
}

await main();
