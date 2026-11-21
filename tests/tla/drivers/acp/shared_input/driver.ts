// Runtime driver: runs the real fx acp binary through six plans in which the owner,
// on stdio, and a follower, on the session's leader socket, send prompts, steer,
// queue, cancel, leave, and load with a new system prompt. Each run is checked
// against tests/tla/acp/AcpSharedInput.tla through AcpSharedInputTrace.tla.
//
// What the driver records is what fx wrote: each client's answers and user chunks,
// the stop reasons, the system prompt of each Gateway request, and fx's own trace
// lines (queued prompt, held steer, withdrawn follower input), which it waits on as
// a fence before it acts. The driver orders each step by what it has read, not by
// timing. The fake Gateway in tests/e2e/tmux-helpers.ts holds every model reply
// until the driver ends it, so each step happens while a turn is in a known phase.
// No model calls.
//
//   bun tests/tla/drivers/acp/shared_input/driver.ts                    # --model rules
//   bun tests/tla/drivers/acp/shared_input/driver.ts --model today      # the control
//   bun tests/tla/drivers/acp/shared_input/driver.ts --plan follower-steer
//
// --model rules (the default) validates each run with Rules TRUE: fx's follower
// prompts, steers and cancels take part, and a follower's load applies its prompt
// from the next turn. --model today validates with Rules FALSE, the behavior before
// this branch, where a follower only watches. Each plan uses a follower's input, so
// each expects rules ACCEPTED and today REJECTED.
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetModule, worktree } from "../../lib/context";
import { SharedFixture, SocketClient, isAnswer, settle, userChunkText, FrameStream, WAIT_MS, clientCapabilities, Acp } from "./harness";
import { type Kind, type Obs, type Req, type Sys, type Verdict, type Who, validate } from "./trace";
import { outDir, sha256File, tlcToolchain, writeJson } from "./tlc";

// ------------------------------------------------------------------ requests --

const OWNER1: Req = { who: "owner", n: 1 };
const OWNER2: Req = { who: "owner", n: 2 };
const FOLLOWER1: Req = { who: "follower", n: 1 };
const ALL: Req[] = [OWNER1, OWNER2, FOLLOWER1];

const key = (r: Req) => `${r.who}:${r.n}`;
/// The text of a request's prompt. A chunk or a Gateway request is matched to a
/// request by it, so each marker names one request only.
const marker = (r: Req) => `SHARED_${r.who === "owner" ? "OWNER" : "FOLLOWER"}_${r.n}`;

/// The fx trace lines the driver waits on as a fence (server.zig): a queued prompt,
/// a held steer, and a follower's input withdrawn when it left.
const QUEUED = "queued prompt for a turn of its own";
const STEERED = "queued steering prompt";
const WITHDRAWN = "event=waiting_input_dropped";

const OLD_PROMPT = { mode: "append", content: [{ type: "text", text: "OLD_SYSTEM_PROMPT" }] };
const NEW_PROMPT = { mode: "append", content: [{ type: "text", text: "NEW_SYSTEM_PROMPT" }] };

/// The system prompt of a Gateway request, as the model's Sys: old, new, or neither.
function sysOf(body: string): Sys {
  if (body.includes("NEW_SYSTEM_PROMPT")) return "new";
  if (body.includes("OLD_SYSTEM_PROMPT")) return "old";
  return "other";
}

/// A plan that stops because fx did something the plan does not expect. The
/// observations up to that point still go to the trace, which rejects them.
class PlanStop extends Error {}

// ------------------------------------------------------------------- the run --

/// One plan against the real binary. Each method is one step of the plan; it
/// records what fx did, and returns when fx has done it or the wait ran out.
class Run {
  readonly observations: Obs[] = [];
  readonly evidence: Array<Record<string, unknown>> = [];
  processFailed = false;
  private owner: Acp | null = null;
  private readonly ownerFrames = new FrameStream();
  private follower: SocketClient | null = null;
  private sessionId = "";
  /// Each prompt's request id on its sender's wire, and its kind.
  private readonly ids = new Map<string, number>();
  private readonly kinds = new Map<string, Kind>();
  /// The answers and user chunks an observation has taken, by wire.
  private readonly claimed = new Set<string>();
  /// The model requests (holds) an observation has taken.
  private recorded = 0;

  constructor(private readonly fixture: SharedFixture, private readonly sessionDir: (home: string, id: string) => string) {}

  private wire(who: Who): any[] {
    if (who === "owner") return this.ownerFrames.frames;
    return this.follower?.stream.frames ?? [];
  }

  private answerOn(who: Who, r: Req): any | undefined {
    const id = this.ids.get(key(r));
    if (id === undefined || r.who !== who) return undefined;
    return this.wire(who).find((frame) => isAnswer(frame) && frame.id === id);
  }

  private chunkOn(who: Who, r: Req): boolean {
    const text = marker(r);
    return this.wire(who).some((frame) => userChunkText(frame)?.includes(text) === true);
  }

  private claimAnswer(who: Who, r: Req) {
    this.claimed.add(`${who}:answer:${key(r)}`);
  }

  private claimChunk(who: Who, r: Req) {
    this.claimed.add(`${who}:chunk:${key(r)}`);
  }

  private async ownerCall(method: string, params: object): Promise<any> {
    const id = this.owner!.send(method, params);
    await this.ownerFrames.until((frames) => frames.some((frame) => isAnswer(frame) && frame.id === id), `the owner's answer to ${method}`);
    return this.ownerFrames.frames.find((frame) => isAnswer(frame) && frame.id === id);
  }

  /// Starts fx acp on stdio, initializes it, and opens a session with the old prompt.
  async ensureOwner() {
    const acp = this.fixture.spawn();
    this.owner = acp;
    acp.listen((message) => this.ownerFrames.push(message));
    const init = await this.ownerCall("initialize", { protocolVersion: 1, clientCapabilities: clientCapabilities(false) });
    if (init.error) throw new Error(`initialize failed: ${JSON.stringify(init.error)}`);
    const created = await this.ownerCall("session/new", { cwd: this.fixture.workspace, mcpServers: [], systemPrompt: OLD_PROMPT });
    if (created.error) throw new Error(`session/new failed: ${JSON.stringify(created.error)}`);
    this.sessionId = created.result.sessionId;
    this.evidence.push({ op: "owner", pid: acp.proc.pid, sessionId: this.sessionId });
  }

  /// The follower loads the session on the leader socket, with the new prompt or not.
  /// Its replay gives the user chunks of the requests it replays, which the join takes.
  async join(withNewPrompt: boolean) {
    // The load always sends a prompt: the new one, or the session's own, so the
    // load's effect is one the trace knows (the load observation records it).
    const v: Sys = withNewPrompt ? "new" : "old";
    const lock = readFileSync(join(this.sessionDir(this.fixture.home, this.sessionId), "lock"), "utf8");
    const socket = JSON.parse(lock).socket as string;
    this.evidence.push({ op: "lock", who: "follower", lock });
    const client = await SocketClient.connect(socket);
    this.follower = client;
    const init = await client.request("initialize", { protocolVersion: 1, clientCapabilities: clientCapabilities(false) });
    if (init.answer.error) throw new Error(`follower initialize failed: ${JSON.stringify(init.answer.error)}`);
    const { answer, index } = await client.request("session/load", {
      sessionId: this.sessionId,
      cwd: this.fixture.workspace,
      mcpServers: [],
      systemPrompt: v === "new" ? NEW_PROMPT : OLD_PROMPT,
    });
    if (answer.error) {
      this.observations.push({ op: "join_refused" });
      this.evidence.push({ op: "join_refused", error: answer.error });
      throw new PlanStop(`the follower's load was refused: ${answer.error.code} ${answer.error.message}`);
    }
    const replayed = client.stream.frames.slice(0, index).map(userChunkText);
    const rs = ALL.filter((r) => replayed.some((text) => text?.includes(marker(r)) === true));
    for (const r of rs) this.claimChunk("follower", r);
    this.observations.push({ op: "join", rs });
    this.observations.push({ op: "load", v });
  }

  /// Sends a prompt from its sender, and records what fx did with it: a turn started
  /// (its Gateway request arrived), an error answer came at once, or fx queued it or
  /// held it as a steer. Any other result stops the plan.
  async prompt(r: Req, kind: Kind) {
    const params: Record<string, unknown> = { sessionId: this.sessionId, prompt: [{ type: "text", text: marker(r) }] };
    if (kind !== "none") params._meta = { "sh.fx/delivery": kind };
    const id = r.who === "owner" ? this.owner!.send("session/prompt", params) : this.follower!.send("session/prompt", params);
    this.ids.set(key(r), id);
    this.kinds.set(key(r), kind);
    const before = { queued: this.fixture.traceCount(QUEUED), steered: this.fixture.traceCount(STEERED) };
    const deadline = Date.now() + WAIT_MS;
    let outcome: "start" | "queued" | "pending" | "refuse" | null = null;
    let code = 0;
    while (outcome === null) {
      const answer = this.answerOn(r.who, r);
      if (answer?.error) {
        outcome = "refuse";
        code = Number(answer.error.code);
      } else if (kind === "none" && this.fixture.holds.length > this.recorded) outcome = "start";
      else if (kind === "queue" && this.fixture.traceCount(QUEUED) > before.queued) outcome = "queued";
      else if (kind === "steer" && this.fixture.traceCount(STEERED) > before.steered) outcome = "pending";
      else if (Date.now() > deadline) throw new Error(`fx gave no outcome for ${key(r)} (${kind})`);
      else await Bun.sleep(10);
    }
    if (outcome === "refuse") {
      this.observations.push({ op: "refuse", r, k: kind, code });
      this.claimAnswer(r.who, r);
      throw new PlanStop(`${key(r)} (${kind}) was refused with ${code}`);
    }
    if (outcome === "start") {
      this.observations.push({ op: "start", r, k: kind, v: sysOf(this.fixture.holds[this.recorded]!.body) });
      this.recorded += 1;
    } else if (outcome === "queued") this.observations.push({ op: "queued", r });
    else this.observations.push({ op: "pending", r });
  }

  /// The user chunk of `r`, on each client's wire: which clients got it. Its sender
  /// is expected not to, and the other present client to; a wire without it is not in `to`.
  async chunks(r: Req) {
    const other: Who = r.who === "owner" ? "follower" : "owner";
    await settle(() => this.chunkOn(other, r), WAIT_MS);
    const to = (["owner", "follower"] as Who[]).filter((who) => this.chunkOn(who, r));
    for (const who of to) this.claimChunk(who, r);
    this.observations.push({ op: "chunks", r, to });
  }

  /// A steer the turn took: its chunk on every client's wire, the sender's included.
  async absorb(r: Req) {
    await settle(() => this.chunkOn("owner", r) && this.chunkOn("follower", r), WAIT_MS);
    const to = (["owner", "follower"] as Who[]).filter((who) => this.chunkOn(who, r));
    for (const who of to) this.claimChunk(who, r);
    this.observations.push({ op: "absorb", rs: [r], to });
  }

  /// The turn's next model request, after a steer it took. Its system prompt is checked.
  async requestNext() {
    const arrived = await settle(() => this.fixture.holds.length > this.recorded, WAIT_MS);
    if (!arrived) throw new Error("fx sent no further model request for the running turn");
    this.observations.push({ op: "request", v: sysOf(this.fixture.holds[this.recorded]!.body) });
    this.recorded += 1;
  }

  /// Ends the newest model reply, the running turn's, with final text.
  release() {
    const hold = this.fixture.holds.at(-1);
    if (!hold) throw new Error("there is no model request to release");
    hold.end("final");
  }

  /// The follower sends session/cancel. It is a notification, so fx's effect is the
  /// stop that follows (`stopped`).
  cancel() {
    this.follower!.notify("session/cancel", { sessionId: this.sessionId });
    this.observations.push({ op: "cancel", by: "follower" });
  }

  /// The turn that the cancel stopped: its sender's answer, with stop reason `cancelled`.
  async stopped(r: Req, by: Who) {
    await settle(() => this.answerOn(r.who, r) !== undefined, WAIT_MS);
    const answer = this.answerOn(r.who, r);
    if (!answer) throw new PlanStop(`no answer to ${key(r)} after the cancel`);
    this.claimAnswer(r.who, r);
    this.observations.push({ op: "stopped", rs: [r], by, ok: answer.result?.stopReason === "cancelled" });
  }

  /// The turn ended normally: the answers of `reqs` on their senders' wires. A steer's
  /// answer must say it was absorbed, which is fx's sh.fx/steeringDelivery.
  async finish(reqs: Req[]) {
    await settle(() => reqs.every((r) => this.answerOn(r.who, r) !== undefined), WAIT_MS);
    const answered = reqs.filter((r) => this.answerOn(r.who, r) !== undefined);
    const ok = answered.length === reqs.length && answered.every((r) => {
      const answer = this.answerOn(r.who, r);
      if (answer.error || answer.result?.stopReason !== "end_turn") return false;
      return this.kinds.get(key(r)) !== "steer" || answer.result?._meta?.["sh.fx/steeringDelivery"] === "absorbed";
    });
    for (const r of answered) this.claimAnswer(r.who, r);
    this.observations.push({ op: "finish", rs: answered, ok });
    const missing = reqs.filter((r) => !answered.includes(r));
    if (missing.length > 0) throw new PlanStop(`no answer to ${missing.map(key).join(", ")}`);
  }

  /// After a turn ended: the queued prompt `next` started (its request arrived), or
  /// nothing did. With no `next`, a request that arrives now is unmatched.
  async afterFinish(next: Req | null) {
    if (next) {
      const arrived = await settle(() => this.fixture.holds.length > this.recorded, 10_000);
      if (arrived) {
        this.observations.push({ op: "started", r: next, v: sysOf(this.fixture.holds[this.recorded]!.body) });
        this.recorded += 1;
      } else this.observations.push({ op: "idle" });
      return;
    }
    const arrived = await settle(() => this.fixture.holds.length > this.recorded, 1_000);
    if (arrived) {
      this.observations.push({ op: "unmatched", what: "a model request with no turn to start" });
      this.recorded += 1;
    }
  }

  /// The follower disconnects. Its queued prompt is withdrawn when fx has traced it
  /// (server.zig, withdrawFollowerInput, after the prompt leaves the line).
  async leave(r: Req) {
    this.follower!.close();
    this.observations.push({ op: "leave", who: "follower" });
    const needle = `${WITHDRAWN} session=${this.sessionId} request=${this.ids.get(key(r))} reason=follower_left`;
    const traced = await settle(() => this.fixture.traceHas(needle), 30_000);
    this.evidence.push({ op: "withdraw_fence", needle, traced });
  }

  /// After the plan: fx exits when its input ends. Every frame not taken by an
  /// observation, and every model request not recorded, becomes an unmatched observation.
  async finalDrain() {
    if (this.owner) {
      const acp = this.owner;
      const outcome = await acp.close();
      await acp.readerDone;
      this.owner = null;
      this.evidence.push({ op: "owner_exit", exit: outcome.exit, stderr: outcome.stderr.slice(-2000) });
      if (outcome.exit !== 0) this.processFailed = true;
    }
    if (this.follower) await settle(() => this.follower!.stream.closed, 5_000);
    for (const who of ["owner", "follower"] as Who[]) {
      for (const frame of this.wire(who)) {
        for (const r of ALL) {
          if (r.who === who && isAnswer(frame) && frame.id === this.ids.get(key(r)) && !this.claimed.has(`${who}:answer:${key(r)}`)) {
            this.observations.push({ op: "unmatched", what: `an answer to ${key(r)} on the ${who} wire` });
          }
          if (userChunkText(frame)?.includes(marker(r)) === true && !this.claimed.has(`${who}:chunk:${key(r)}`)) {
            this.observations.push({ op: "unmatched", what: `a user chunk of ${key(r)} on the ${who} wire` });
          }
        }
      }
    }
    while (this.recorded < this.fixture.holds.length) {
      this.observations.push({ op: "unmatched", what: "a model request no observation took" });
      this.recorded += 1;
    }
  }

  get holdCount() {
    return this.fixture.holds.length;
  }

  dispose() {
    this.follower?.close();
    this.owner?.proc.kill("SIGKILL");
    this.owner = null;
  }
}

// ----------------------------------------------------------------- the plans --

type Plan = { name: string; run: (r: Run) => Promise<void> };
const EXPECT = { rules: "ACCEPTED", today: "REJECTED" } as const;

const PLANS: Array<Plan & { expect: typeof EXPECT }> = [
  {
    name: "follower-prompt-idle",
    expect: EXPECT,
    run: async (r) => {
      // The owner's turn ends first, so the session is idle when the follower joins and prompts.
      await r.ensureOwner();
      await r.prompt(OWNER1, "none");
      r.release();
      await r.finish([OWNER1]);
      await r.afterFinish(null);
      await r.join(false);
      await r.prompt(FOLLOWER1, "none");
      await r.chunks(FOLLOWER1);
      r.release();
      await r.finish([FOLLOWER1]);
      await r.afterFinish(null);
    },
  },
  {
    name: "follower-queue",
    expect: EXPECT,
    run: async (r) => {
      await r.ensureOwner();
      await r.prompt(OWNER1, "none");
      await r.join(false);
      await r.prompt(FOLLOWER1, "queue");
      r.release();
      await r.finish([OWNER1]);
      await r.afterFinish(FOLLOWER1);
      await r.chunks(FOLLOWER1);
      r.release();
      await r.finish([FOLLOWER1]);
      await r.afterFinish(null);
    },
  },
  {
    name: "follower-steer",
    expect: EXPECT,
    run: async (r) => {
      await r.ensureOwner();
      await r.prompt(OWNER1, "none");
      await r.join(false);
      await r.prompt(FOLLOWER1, "steer");
      await r.absorb(FOLLOWER1);
      await r.requestNext();
      r.release();
      await r.finish([OWNER1, FOLLOWER1]);
      await r.afterFinish(null);
    },
  },
  {
    name: "follower-cancel",
    expect: EXPECT,
    run: async (r) => {
      await r.ensureOwner();
      await r.prompt(OWNER1, "none");
      await r.join(false);
      r.cancel();
      await r.stopped(OWNER1, "follower");
      await r.afterFinish(null);
    },
  },
  {
    name: "follower-leave",
    expect: EXPECT,
    run: async (r) => {
      await r.ensureOwner();
      await r.prompt(OWNER1, "none");
      await r.join(false);
      await r.prompt(FOLLOWER1, "queue");
      await r.leave(FOLLOWER1);
      r.release();
      await r.finish([OWNER1]);
      await r.afterFinish(null);
    },
  },
  {
    name: "follower-system-prompt",
    expect: EXPECT,
    run: async (r) => {
      await r.ensureOwner();
      await r.prompt(OWNER1, "none");
      await r.join(true);
      r.release();
      await r.finish([OWNER1]);
      await r.afterFinish(null);
      await r.prompt(OWNER2, "none");
      await r.chunks(OWNER2);
      r.release();
      await r.finish([OWNER2]);
      await r.afterFinish(null);
    },
  },
];

// -------------------------------------------------------------------- runs --

async function runPlan(plan: Plan, dir: string, sessionDir: (home: string, id: string) => string) {
  mkdirSync(dir, { recursive: true });
  const fixture = new SharedFixture(binary);
  await fixture.init();
  const run = new Run(fixture, sessionDir);
  let error: string | null = null;
  let complete = false;
  try {
    await plan.run(run);
    complete = true;
  } catch (caught) {
    if (!(caught instanceof PlanStop)) error = caught instanceof Error ? caught.message : String(caught);
  }
  try {
    await run.finalDrain();
  } catch (caught) {
    error ??= caught instanceof Error ? caught.message : String(caught);
  }
  if (complete && !error) run.observations.push({ op: "end" });
  writeJson(join(dir, "observations.json"), run.observations);
  writeJson(join(dir, "evidence.json"), run.evidence);
  run.dispose();
  fixture.dispose();
  return { run, error, complete };
}

/// A control: flip the system prompt of the first turn start of a run. The model must
/// reject it, so the check cannot pass a run that the trace does not match.
function tamper(observations: Obs[]): Obs[] | null {
  const copy: Obs[] = structuredClone(observations);
  const index = copy.findIndex((o) => o.op === "start" && o.v === "old");
  if (index === -1) return null;
  const start = copy[index] as Extract<Obs, { op: "start" }>;
  copy[index] = { ...start, v: "new" };
  return copy;
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
  const saved = await targetModule("saved-sessions.ts");
  const reportDir = outDir(`acp-shared-input-${model}`);
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
  const observed = new Map<string, Obs[]>();
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const { run, error, complete } = await runPlan(plan, dir, saved.sessionDir);
    observed.set(plan.name, run.observations);
    const checked = error ? null : await validate(run.observations, dir, model === "rules");
    const verdict: Verdict | "RUN_ERROR" | "PROCESS_ERROR" = error ? "RUN_ERROR" : run.processFailed ? "PROCESS_ERROR" : checked!.verdict;
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
      complete,
      error,
      firstDivergence: checked?.firstDivergence ?? null,
    });
    const divergence = checked?.firstDivergence;
    const where = divergence
      ? ` first divergence at step ${divergence.step}: ${JSON.stringify(divergence.observation)}`
      : "";
    console.log(
      `${plan.name}: ${verdict} (${matched}/${run.observations.length})${ok ? "" : ` UNEXPECTED, expected ${expected}`}${error ? ` ${error}` : ""}${where}`,
    );
  }

  const controls = [];
  if (model === "rules") {
    const name = "follower-system-prompt";
    const trace = observed.get(name);
    const flipped = trace ? tamper(trace) : null;
    if (flipped) {
      const got = (await validate(flipped, join(reportDir, "controls", "tampered-system-prompt"), true)).verdict;
      controls.push({ name: "tampered-system-prompt", expect: "REJECTED", got });
    }
  }
  for (const control of controls) console.log(`control ${control.name}: ${control.got} (expected ${control.expect})`);

  const controlsPassed = controls.every((control) => control.got === control.expect);
  const passed = results.every((result) => result.ok) && controlsPassed;
  writeJson(join(reportDir, "summary.json"), { model, results, controls, passed });
  console.log(`matched ${results.filter((result) => result.ok).length}/${results.length} plans as expected; controls ${controlsPassed ? "passed" : "FAILED"}`);
  console.log(`report: ${reportDir}`);
  process.exit(passed ? 0 : 1);
}

await main();
