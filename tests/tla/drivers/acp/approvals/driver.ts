// Runtime driver: runs the real fx acp binary through six plans in which one turn's
// permission question is shared by a session's clients: the opener, on stdio, and a
// follower, on the session's leader socket. The plans cover a follower's allow once, a
// non-sender's refused allow for this session, the main client leaving while the
// question waits, a joiner answering, the last client leaving, and a turn cancelled
// while it waits. Each run is checked against tests/tla/acp/AcpApprovals.tla through
// AcpApprovalsTrace.tla.
//
// What the driver records is what fx wrote: each client's questions and cancels, the
// answers it sent, and the tool's result on disk. fx's trace lines are fences: the
// driver waits on one before it acts, so it orders each step by what it has read, not
// by timing. No model calls.
//
//   bun tests/tla/drivers/acp/approvals/driver.ts                  # --model rules
//   bun tests/tla/drivers/acp/approvals/driver.ts --model today    # the control
//   bun tests/tla/drivers/acp/approvals/driver.ts --plan joiner-answers
//
// --model rules (the default) validates each run with design "A", the rules fx builds.
// --model today validates with design "current", the code before this change. Every
// plan expects rules ACCEPTED and today REJECTED. The control tampers with the decision
// the tool result shows; it must be REJECTED under rules.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetModule, worktree } from "../../lib/context";
import { Acp, ApprovalsFixture, Follower, FrameStream, WAIT_MS, clientCapabilities, isAnswer, respondOnStdio, settle } from "./harness";
import { type Client, type Design, type Dec, type Obs, type Opt, type Verdict, validate } from "./trace";
import { outDir, sha256File, tlcToolchain, writeJson } from "./tlc";

const CLIENTS: Client[] = ["opener", "f1"];
const OPTION_IDS: Record<Opt, string> = { once: "allow_once", always: "allow_always", reject: "reject_once" };
const REFUSED = "event=permission_answer_refused";
const TURN_ENDED = "event=running_copy_released reason=turn_ended";

class PlanStop extends Error {}

/// One plan's driver state: the opener, the follower, and the observations fx's output
/// supports. A step that finds nothing where the model expects something records an
/// `unmatched` observation and stops, so the trace is rejected.
class Run {
  readonly observations: Obs[] = [];
  processFailed = false;
  private readonly owner: Acp;
  private readonly ownerFrames = new FrameStream();
  private follower: Follower | null = null;
  private sessionId = "";
  private readonly copies = new Map<Client, number>();
  private readonly claimedRequests = new Set<string>();
  private readonly claimedCancels = new Set<string>();
  private endsBefore = 0;

  constructor(
    private readonly fixture: ApprovalsFixture,
    private readonly sessionDir: (home: string, id: string) => string,
  ) {
    this.owner = fixture.spawn();
    this.owner.listen((message) => this.ownerFrames.push(message));
  }

  private wire(c: Client): any[] {
    return c === "opener" ? this.ownerFrames.frames : (this.follower?.stream.frames ?? []);
  }

  private nextRequest(c: Client): any | undefined {
    return this.wire(c).find((frame) => frame?.method === "session/request_permission" && "id" in frame && !this.claimedRequests.has(`${c}:${frame.id}`));
  }

  private cancelFrame(c: Client, k: number): any | undefined {
    return this.wire(c).find((frame) => frame?.method === "$/cancel_request" && frame.params?.requestId === k);
  }

  private claim(c: Client, k: number) {
    this.claimedRequests.add(`${c}:${k}`);
    this.copies.set(c, k);
  }

  private unmatched(what: string) {
    this.observations.push({ op: "unmatched", what });
  }

  private stop(what: string): never {
    this.unmatched(what);
    throw new PlanStop(what);
  }

  private async ownerRequest(method: string, params: object): Promise<any> {
    const id = this.owner.send(method, params as Record<string, unknown>);
    await this.ownerFrames.until((frames) => frames.some((frame) => isAnswer(frame) && frame.id === id), `the answer to ${method}`);
    return this.ownerFrames.frames.find((frame) => isAnswer(frame) && frame.id === id);
  }

  /// Initializes the opener and opens the session. Its turns need a permission question.
  async start() {
    const init = await this.ownerRequest("initialize", { protocolVersion: 1, clientCapabilities: clientCapabilities(false) });
    if (init.error) this.stop(`initialize failed: ${JSON.stringify(init.error)}`);
    const created = await this.ownerRequest("session/new", { cwd: this.fixture.workspace, mcpServers: [] });
    if (created.error) this.stop(`session/new failed: ${JSON.stringify(created.error)}`);
    this.sessionId = created.result.sessionId;
    const mode = await this.ownerRequest("session/set_mode", { sessionId: this.sessionId, modeId: "ask" });
    if (mode.error) this.stop(`session/set_mode failed: ${JSON.stringify(mode.error)}`);
  }

  /// A turn with no tool call, so the session is saved and its lock exists. It is not
  /// part of the modelled run: the model starts at the question turn.
  async warmUp() {
    const answer = await this.ownerRequest("session/prompt", { sessionId: this.sessionId, prompt: [{ type: "text", text: "warm up" }] });
    if (answer.error) this.stop(`warm-up prompt failed: ${JSON.stringify(answer.error)}`);
    const ended = await settle(() => this.fixture.traceCount(TURN_ENDED) > 0, WAIT_MS);
    if (!ended) this.stop("the warm-up turn did not end");
  }

  /// Lets the question turn's model call go on, after the driver's join or prompt.
  release() {
    this.fixture.release();
  }

  /// The follower joins on the leader socket. A question still open is written to it
  /// with the join, before its load answer, so the copy's id is the one before the answer.
  async join() {
    const lockPath = join(this.sessionDir(this.fixture.home, this.sessionId), "lock");
    if (!(await settle(() => existsSync(lockPath), WAIT_MS))) this.stop("the session's lock did not appear");
    const socket = JSON.parse(readFileSync(lockPath, "utf8")).socket as string;
    this.follower = await Follower.connect(socket);
    const init = await this.follower.request("initialize", { protocolVersion: 1, clientCapabilities: clientCapabilities(false) });
    if (init.answer?.error) this.stop(`follower initialize failed: ${JSON.stringify(init.answer.error)}`);
    const load = await this.follower.request("session/load", { sessionId: this.sessionId, cwd: this.fixture.workspace, mcpServers: [] });
    if (load.answer?.error) this.stop(`follower session/load failed: ${JSON.stringify(load.answer.error)}`);
    const copy = this.follower.stream.frames.slice(0, load.index).find((frame) => frame?.method === "session/request_permission" && "id" in frame);
    const k = copy ? Number(copy.id) : 0;
    if (copy) this.claim("f1", k);
    this.observations.push({ op: "join", c: "f1", k });
  }

  prompt(c: Client) {
    this.endsBefore = this.fixture.traceCount(TURN_ENDED);
    const params = { sessionId: this.sessionId, prompt: [{ type: "text", text: `approval ${c}` }] };
    if (c === "opener") this.owner.send("session/prompt", params);
    else this.follower!.send("session/prompt", params);
    this.observations.push({ op: "prompt", c });
  }

  /// Waits until each target has received its copy of the question, then records the
  /// ask and each copy.
  async ask(targets: Client[]) {
    const ready = await settle(() => targets.every((c) => this.nextRequest(c) !== undefined), WAIT_MS);
    if (!ready) this.stop(`no question reached ${targets.filter((c) => this.nextRequest(c) === undefined).join(" and ")}`);
    this.observations.push({ op: "ask" });
    for (const c of targets) {
      const frame = this.nextRequest(c)!;
      this.claim(c, Number(frame.id));
      this.observations.push({ op: "wrote", c, k: Number(frame.id) });
    }
  }

  /// Sends the client's answer on its copy. The answer is the option id that the
  /// client was offered, or one it was not.
  answer(c: Client, opt: Opt) {
    const k = this.copies.get(c);
    if (k === undefined) this.stop(`no copy of the question for ${c}`);
    const result = { outcome: { outcome: "selected", optionId: OPTION_IDS[opt] } };
    if (c === "opener") respondOnStdio(this.owner, k, result);
    else this.follower!.respond(k, result);
    this.observations.push({ op: "answer", c, k, opt });
  }

  /// An answer that fx must refuse. The next step waits for fx's refusal line, so the
  /// refusal is in the order of the run.
  async refused(c: Client, opt: Opt) {
    const before = this.fixture.traceCount(REFUSED);
    this.answer(c, opt);
    const seen = await settle(() => this.fixture.traceCount(REFUSED) > before, WAIT_MS);
    if (!seen) this.stop(`fx did not refuse the ${opt} answer from ${c}`);
  }

  /// Waits until fx sends $/cancel_request for the copy that `c` holds, and records it.
  async cancelOn(c: Client) {
    const k = this.copies.get(c);
    if (k === undefined) this.stop(`no copy of the question for ${c}`);
    const seen = await settle(() => this.cancelFrame(c, k) !== undefined, WAIT_MS);
    if (!seen) this.stop(`no $/cancel_request for ${c}'s copy ${k}`);
    this.claimedCancels.add(`${c}:${k}`);
    this.observations.push({ op: "cancel", c, k });
  }

  /// The opener leaves with session/close. The other client's copy stays.
  async leaveOpener() {
    const answer = await this.ownerRequest("session/close", { sessionId: this.sessionId });
    if (answer.error) this.stop(`session/close failed: ${JSON.stringify(answer.error)}`);
    this.observations.push({ op: "leave", c: "opener" });
  }

  /// The follower leaves by closing its socket. The step after it waits for the turn's
  /// end, which is fx's fence that it handled the leave.
  leaveFollower() {
    this.follower!.close();
    this.observations.push({ op: "leave", c: "f1" });
  }

  /// The follower cancels the turn with session/cancel.
  sessionCancel() {
    this.follower!.notify("session/cancel", { sessionId: this.sessionId });
    this.observations.push({ op: "sessionCancel", c: "f1" });
  }

  /// Waits until the turn has ended: fx releases the question's copies with turn_ended.
  async turnEnded() {
    const seen = await settle(() => this.fixture.traceCount(TURN_ENDED) > this.endsBefore, WAIT_MS);
    if (!seen) this.stop("the turn did not end");
  }

  /// The tool's result on disk shows the decision: a written file is an allow, none is a deny.
  resolved() {
    const dec: Dec = this.fixture.wrote() ? "once" : "deny";
    this.observations.push({ op: "resolved", dec });
  }

  turnEnd() {
    this.observations.push({ op: "turnEnd" });
  }

  /// Every question and cancel that fx sent is one the run took. Then fx exits, once
  /// its input has ended and no follower is joined.
  async finish() {
    this.follower?.close();
    for (const c of CLIENTS) {
      for (const frame of this.wire(c)) {
        if (frame?.method === "session/request_permission" && "id" in frame && !this.claimedRequests.has(`${c}:${frame.id}`)) {
          this.unmatched(`${c} got a question the run did not record: id ${frame.id}`);
        }
        if (frame?.method === "$/cancel_request" && !this.claimedCancels.has(`${c}:${frame.params?.requestId}`)) {
          this.unmatched(`${c} got a cancel the run did not record: id ${frame.params?.requestId}`);
        }
      }
    }
    this.owner.disconnect();
    const outcome = await this.owner.waitForExit(WAIT_MS);
    if (!outcome.exited) this.owner.proc.kill();
    this.processFailed = !(outcome.exited && outcome.code === 0);
  }
}

type Plan = { name: string; steps: (run: Run) => Promise<void>; expect: Record<"rules" | "today", Verdict> };

const EXPECT = { rules: "ACCEPTED", today: "REJECTED" } as const;

const PLANS: Plan[] = [
  {
    // The follower joins without a question. It did not send the prompt, so its allow
    // once decides. The main client is told to cancel its copy, and the tool's result is
    // on disk.
    name: "follower-allow-once",
    expect: EXPECT,
    steps: async (run) => {
      await run.start();
      await run.warmUp();
      await run.join();
      run.prompt("opener");
      run.release();
      await run.ask(["opener", "f1"]);
      run.answer("f1", "once");
      await run.cancelOn("opener");
      await run.turnEnded();
      run.resolved();
      run.turnEnd();
    },
  },
  {
    // The follower sent the prompt, so only its copy offers allow for this session. The
    // opener's copy does not, and its allow for this session is refused. The follower's
    // allow once then decides.
    name: "non-sender-refused-always",
    expect: EXPECT,
    steps: async (run) => {
      await run.start();
      await run.warmUp();
      await run.join();
      run.prompt("f1");
      run.release();
      await run.ask(["opener", "f1"]);
      await run.refused("opener", "always");
      run.answer("f1", "once");
      await run.cancelOn("opener");
      await run.turnEnded();
      run.resolved();
      run.turnEnd();
    },
  },
  {
    // The main client leaves while the question waits. The follower keeps its copy and
    // its allow once decides. Nobody is asked again, and no cancel goes to a client that left.
    name: "main-leaves-while-waiting",
    expect: EXPECT,
    steps: async (run) => {
      await run.start();
      await run.warmUp();
      await run.join();
      run.prompt("opener");
      run.release();
      await run.ask(["opener", "f1"]);
      await run.leaveOpener();
      run.answer("f1", "once");
      await run.turnEnded();
      run.resolved();
      run.turnEnd();
    },
  },
  {
    // A client joins while the question waits. Its copy is written with the join, and
    // its allow once decides.
    name: "joiner-answers",
    expect: EXPECT,
    steps: async (run) => {
      await run.start();
      await run.warmUp();
      run.prompt("opener");
      run.release();
      await run.ask(["opener"]);
      await run.join();
      run.answer("f1", "once");
      await run.cancelOn("opener");
      await run.turnEnded();
      run.resolved();
      run.turnEnd();
    },
  },
  {
    // The opener leaves, then the follower leaves. The last client's leave denies the
    // question at once, and the turn ends with no file written.
    name: "last-client-leaves-denies",
    expect: EXPECT,
    steps: async (run) => {
      await run.start();
      await run.warmUp();
      await run.join();
      run.prompt("opener");
      run.release();
      await run.ask(["opener", "f1"]);
      await run.leaveOpener();
      run.leaveFollower();
      await run.turnEnded();
      run.resolved();
      run.turnEnd();
    },
  },
  {
    // The follower cancels the turn. Every client that holds a copy gets its own cancel,
    // and the question is denied with no file written.
    name: "turn-cancelled-while-waiting",
    expect: EXPECT,
    steps: async (run) => {
      await run.start();
      await run.warmUp();
      await run.join();
      run.prompt("opener");
      run.release();
      await run.ask(["opener", "f1"]);
      run.sessionCancel();
      await run.cancelOn("opener");
      await run.cancelOn("f1");
      await run.turnEnded();
      run.resolved();
    },
  },
];

async function runPlan(plan: Plan, dir: string, sessionDir: (home: string, id: string) => string) {
  const fixture = new ApprovalsFixture(binary);
  let run: Run | null = null;
  let error: string | null = null;
  try {
    await fixture.init();
    fixture.target = `${plan.name}.txt`;
    run = new Run(fixture, sessionDir);
    await plan.steps(run);
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  }
  if (run) {
    await run.finish().catch((caught) => {
      error ??= caught instanceof Error ? caught.message : String(caught);
    });
    if (error) {
      // A run that stopped early has no end, so the trace ends with its own mismatch.
      if (!run.observations.some((o) => o.op === "unmatched")) run.observations.push({ op: "unmatched", what: error });
    } else {
      run.observations.push({ op: "end" });
    }
  }
  const observations = run?.observations ?? [];
  fixture.dispose();
  return { observations, error, processFailed: run?.processFailed ?? false, dir };
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(["git", "-C", worktree, ...args], { stdout: "pipe", stderr: "pipe" });
  return new TextDecoder().decode(result.stdout).trim();
}

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

/// The control: flips the decision the tool's result shows. Under rules, that
/// decision is a fact of the run, so the trace must be rejected.
function tamper(observations: Obs[]): Obs[] {
  return observations.map((o) => (o.op === "resolved" ? { op: "resolved", dec: "always" } : o));
}

async function main() {
  if (!existsSync(binary)) throw new Error(`missing ${binary}; run zig build first or set FX_BIN`);
  const model = argValue("--model") ?? "rules";
  if (model !== "rules" && model !== "today") throw new Error(`--model must be rules or today, not ${model}`);
  const design: Design = model === "rules" ? "A" : "current";
  const only = argValue("--plan");
  const plans = only === undefined ? PLANS : PLANS.filter((plan) => plan.name === only);
  if (plans.length === 0) throw new Error(`no plan named ${only}`);
  const saved = await targetModule("saved-sessions.ts");
  const reportDir = outDir(`acp-approvals-${model}`);
  writeJson(join(reportDir, "manifest.json"), {
    model,
    design,
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
  const observed = new Map<string, Obs[]>();
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const { observations, error, processFailed } = await runPlan(plan, dir, saved.sessionDir);
    observed.set(plan.name, observations);
    const checked = await validate(observations, dir, design);
    const verdict: Verdict | "PROCESS_ERROR" = processFailed ? "PROCESS_ERROR" : checked.verdict;
    const expected = plan.expect[model];
    const ok = verdict === expected;
    results.push({
      name: plan.name,
      verdict,
      matched: checked.matched,
      length: observations.length,
      expected,
      ok,
      error,
      firstDivergence: checked.firstDivergence,
    });
    const divergence = checked.firstDivergence;
    const where = divergence ? ` first divergence at step ${divergence.step}: ${JSON.stringify(divergence.observation)}` : "";
    console.log(
      `${plan.name}: ${verdict} (${checked.matched}/${observations.length})${ok ? "" : ` UNEXPECTED, expected ${expected}`}${error ? ` ${error}` : ""}${where}`,
    );
  }

  const controls = [];
  if (model === "rules") {
    const trace = observed.get("follower-allow-once");
    if (trace) {
      const got = (await validate(tamper(trace), join(reportDir, "controls", "tampered-decision"), design)).verdict;
      controls.push({ name: "tampered-decision", expect: "REJECTED", got });
    }
  }
  for (const control of controls) console.log(`control ${control.name}: ${control.got} (expected ${control.expect})`);

  const controlsPassed = controls.every((control) => control.got === control.expect);
  const passed = results.every((result) => result.ok) && controlsPassed;
  writeJson(join(reportDir, "summary.json"), { model, design, results, controls, passed });
  console.log(`matched ${results.filter((result) => result.ok).length}/${results.length} plans as expected; controls ${controlsPassed ? "passed" : "FAILED"}`);
  console.log(`report: ${reportDir}`);
  process.exit(passed ? 0 : 1);
}

await main();
