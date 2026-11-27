// Runtime driver: runs the real fx acp binary through ten plans in which a main client
// (on stdio) and two more clients (on the leader socket) meet one compaction. Each client
// lists session.compaction or not, joins before, during or after the compaction, or leaves
// before its end. Two plans break the main's connection during the compaction, so a
// follower becomes the main. Each run is checked against tests/tla/acp/AcpCompactionAudience.tla
// (design "a") through AcpCompactionAudienceTrace.tla (see ./trace.ts).
//
// The driver holds the compaction's summary, and the turn's reply after it where a plan
// needs a gap, and releases each when the plan says so. It orders every step by what it has
// read, never by timing. The fake Gateway in tests/e2e/tmux-helpers.ts answers each request;
// no model is called.
//
//   bun tests/tla/drivers/acp/compaction_audience/driver.ts                 # --model rules: design a
//   bun tests/tla/drivers/acp/compaction_audience/driver.ts --model today   # the model of fx acp before the change
//   bun tests/tla/drivers/acp/compaction_audience/driver.ts --plan plain-joiner-during
//   bun tests/tla/drivers/acp/compaction_audience/driver.ts --self-check
//
// Every plan expects ACCEPTED under both models. --model rules fails on today's code: each
// plan that covers a rule today's code breaks is REJECTED, at the step the trace names.
// --self-check runs two base plans, both-list and main-breaks-failover, checks each unmodified
// (it must be ACCEPTED), and plants one observation fault into a base each: each planted fault
// must be REJECTED.
// The faults change what the driver reports, not the binary: fx acp has no hook that plants a
// fault in it, so a code-level self-check is not built.
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, targetModule, worktree } from "../../lib/context";
import { FrameStream, SocketClient, deferred, isAnswer } from "../join/harness";
import {
  ENDS,
  FINAL_TEXT,
  LARGE_TEXT,
  LISTING,
  PLAIN,
  SUMMARY_TEXT,
  SUMMARY_SENTENCE,
  CompactionFixture,
  compactingModels,
  compactingReply,
  compactionMessage,
  isFinalText,
} from "./harness";
import { type Member, type Mutation, type Obs, type Verdict, validate } from "./trace";
import { outDir, sha256File, tlcToolchain, writeJson } from "./tlc";

const WAIT_MS = 60_000;
const MEMBERS: Member[] = ["m1", "m2", "m3"];

// ------------------------------------------------------------------- plans --

type Plan = {
  name: string;
  /// What the plan covers, for the report.
  covers: string;
  /// Hold the turn's reply after the compaction ends, so a client can join in that gap.
  holdTurn?: boolean;
  run: (r: Run) => Promise<void>;
};

const PLANS: Plan[] = [
  {
    name: "both-list",
    covers: "control: the main and a follower that joined before the compaction both list session.compaction",
    run: async (r) => {
      await r.startOwner(true);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", true);
      await r.startTurn("Continue.");
      await r.waitSummary();
      r.releaseSummary();
      await r.finish();
    },
  },
  {
    name: "neither-list",
    covers: "control: no client lists session.compaction; each plain client gets one done line",
    run: async (r) => {
      await r.startOwner(false);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", false);
      await r.startTurn("Continue.");
      await r.waitSummary();
      r.releaseSummary();
      await r.finish();
    },
  },
  {
    name: "plain-follower-gate",
    covers: "rule: the main lists, a joined follower does not; the follower gets only its done line",
    run: async (r) => {
      await r.startOwner(true);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", false);
      await r.startTurn("Continue.");
      await r.waitSummary();
      r.releaseSummary();
      await r.finish();
    },
  },
  {
    name: "listing-follower-gate",
    covers: "rule: the main does not list, a joined follower does; the follower gets the progress and the end",
    run: async (r) => {
      await r.startOwner(false);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", true);
      await r.startTurn("Continue.");
      await r.waitSummary();
      r.releaseSummary();
      await r.finish();
    },
  },
  {
    name: "plain-joiner-during",
    covers: "rule: a plain client joins while the summary runs; it gets no progress and its done line at the end",
    run: async (r) => {
      await r.startOwner(true);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", true);
      await r.startTurn("Continue.");
      await r.waitSummary();
      await r.waitOwnerMessage("in_progress");
      await r.joinFollower("m3", false);
      r.releaseSummary();
      await r.finish();
    },
  },
  {
    name: "listing-joiner-during",
    covers: "control: a listing client joins while the summary runs; it gets the progress and the end",
    run: async (r) => {
      await r.startOwner(true);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", true);
      await r.startTurn("Continue.");
      await r.waitSummary();
      await r.waitOwnerMessage("in_progress");
      await r.joinFollower("m3", true);
      r.releaseSummary();
      await r.finish();
    },
  },
  {
    name: "plain-joiner-after",
    covers: "rule: a plain client joins after the end, while the turn's reply is held; its done line comes by the replay",
    holdTurn: true,
    run: async (r) => {
      await r.startOwner(true);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", true);
      await r.startTurn("Continue.");
      await r.waitSummary();
      r.releaseSummary();
      await r.waitOwnerMessage("completed");
      await r.waitTurnHeld();
      await r.joinFollower("m3", false);
      r.releaseTurn();
      await r.finish();
    },
  },
  {
    name: "plain-joiner-leaves-before-end",
    covers: "rule: a plain client joins during the summary and leaves before the end; it gets no done line",
    run: async (r) => {
      await r.startOwner(true);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", true);
      await r.startTurn("Continue.");
      await r.waitSummary();
      await r.waitOwnerMessage("in_progress");
      await r.joinFollower("m3", false);
      await r.leave("m3");
      r.releaseSummary();
      await r.finish();
    },
  },
  {
    name: "main-breaks-failover",
    covers: "rule: the main's connection breaks during the summary; the oldest follower becomes the main and gets nothing again (both followers list)",
    run: async (r) => {
      await r.startOwner(true);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", true);
      await r.joinFollower("m3", true);
      await r.startTurn("Continue.");
      await r.waitSummary();
      await r.waitOwnerMessage("in_progress");
      await r.mainGone();
      r.releaseSummary();
      await r.finish();
    },
  },
  {
    name: "main-breaks-failover-plain-follower",
    covers: "rule: after a failover the plain follower still gets its done line, and the new main gets nothing again",
    run: async (r) => {
      await r.startOwner(true);
      await r.turn("Read notes.md, then write the large reply.");
      await r.joinFollower("m2", true);
      await r.joinFollower("m3", false);
      await r.startTurn("Continue.");
      await r.waitSummary();
      await r.waitOwnerMessage("in_progress");
      await r.mainGone();
      r.releaseSummary();
      await r.finish();
    },
  },
];

// ------------------------------------------------------------ observations --

/// Waits for a promise, or fails with `label` after WAIT_MS.
function within<T>(promise: Promise<T>, label: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), WAIT_MS);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (caught) => {
        clearTimeout(timer);
        reject(caught);
      },
    );
  });
}

/// One plan's run against the real binary. The observations are the driver's steps and the
/// compaction messages each client read, in the order the driver read them.
class Run {
  readonly observations: Obs[] = [];
  readonly evidence: Array<Record<string, unknown>> = [];
  readonly processes: Array<Record<string, unknown>> = [];
  /// Members that listed session.compaction when they connected.
  readonly listers = new Set<Member>();
  private readonly ownerStream = new FrameStream();
  private owner: ReturnType<CompactionFixture["spawn"]> | null = null;
  private readonly spawned: Array<ReturnType<CompactionFixture["spawn"]>> = [];
  private readonly followers = new Map<Member, SocketClient>();
  private readonly gone = new Set<Member>();
  /// How far the driver has read each client's frames.
  private readonly cursor = new Map<Member, number>();
  private gateway: any = null;
  private sessionId = "";
  private promptId = 0;
  private started = false;
  private settled = false;
  private turns = 0;
  private summaries = 0;
  /// The first bytes of each model request, for the evidence: what the gateway was asked.
  private readonly requestHeads: string[] = [];
  private readonly summaryArrived = deferred<void>();
  private readonly turnArrived = deferred<void>();
  private readonly summaryHold = deferred<unknown>();
  private readonly turnHold = deferred<unknown>();

  constructor(
    private readonly fixture: CompactionFixture,
    private readonly helpers: any,
    private readonly sessionDir: (home: string, id: string) => string,
    private readonly holdTurn: boolean,
  ) {
    this.gateway = helpers.startDynamicFakeGateway((raw: string) => this.answer(raw), { models: compactingModels(helpers) });
  }

  /// The fake Gateway's answer to one request. A summary is held until the plan releases
  /// it. The first prompt's turn reads notes.md and then writes the large reply; fx asks for a
  /// model summary only when the conversation holds a tool result, so the read comes first.
  /// The reply after the compaction waits when the plan holds it.
  private answer(raw: string): unknown {
    this.requestHeads.push(raw.slice(0, 160));
    if (raw.includes(SUMMARY_SENTENCE)) {
      this.summaries += 1;
      this.summaryArrived.resolve();
      return this.summaryHold.promise;
    }
    this.turns += 1;
    if (this.turns === 1) return this.helpers.fakeGatewayToolCall("notes_1", "read_file", { path: "notes.md" });
    if (this.turns === 2) return compactingReply(this.helpers, LARGE_TEXT);
    if (this.turns === 3) {
      this.turnArrived.resolve();
      return this.holdTurn ? this.turnHold.promise : compactingReply(this.helpers, FINAL_TEXT);
    }
    return compactingReply(this.helpers, FINAL_TEXT);
  }

  private framesOf(who: Member): any[] | undefined {
    if (who === "m1") return this.ownerStream.frames;
    return this.followers.get(who)?.stream.frames;
  }

  /// Turns the frames each client has received, since the last drain, into observations.
  /// A start comes before any read of progress, and an end (or a done line, which only a
  /// completed compaction writes) before any read of an end or a done line. A member's
  /// reads keep their arrival order.
  private drain(only: Member[] = MEMBERS) {
    const fresh = new Map<Member, any[]>();
    for (const who of only) {
      if (this.gone.has(who)) continue;
      const frames = this.framesOf(who);
      if (!frames) continue;
      fresh.set(who, frames.slice(this.cursor.get(who) ?? 0));
    }
    let sawStart = false;
    let explicitEnd: (typeof ENDS)[number] | null = null;
    let sawDone = false;
    for (const frames of fresh.values()) {
      for (const frame of frames) {
        const msg = compactionMessage(frame);
        if (msg === "in_progress") sawStart = true;
        else if (msg === "done") sawDone = true;
        else if (msg && (ENDS as readonly string[]).includes(msg) && explicitEnd === null) explicitEnd = msg as (typeof ENDS)[number];
      }
    }
    // A summary request means the compaction started, and fx sends its reply only after
    // the compaction ended. A client that does not list the capability may see neither, so
    // the driver takes both steps from those requests, and the evidence says so.
    const seenProgress = sawStart;
    if (this.summaries >= 1) sawStart = true;
    const observed = explicitEnd ?? (sawDone ? "completed" : null);
    const end = observed ?? (this.turns >= 3 ? "completed" : null);
    if (sawStart && !this.started) {
      this.started = true;
      this.observations.push({ op: "start" });
      if (!seenProgress) this.evidence.push({ op: "inferred", step: "start", reason: "the summary request reached the gateway, with no progress line" });
    }
    if (end && !this.settled) {
      this.settled = true;
      this.observations.push({ op: "settle", arg: end });
      if (!observed) this.evidence.push({ op: "inferred", step: "settle", arg: end, reason: "the turn's next request reached the gateway, with no end or done line" });
    }
    for (const [who, frames] of fresh) {
      for (const frame of frames) {
        const msg = compactionMessage(frame);
        if (msg) this.observations.push({ op: "read", who, msg });
      }
      this.cursor.set(who, (this.cursor.get(who) ?? 0) + frames.length);
    }
  }

  private async ownerCall(method: string, params: object): Promise<any> {
    const id = this.owner!.send(method, params);
    await this.ownerStream.until((frames) => frames.some((frame) => isAnswer(frame) && frame.id === id), `the owner's answer to ${method}`, WAIT_MS);
    return this.ownerStream.frames.find((frame) => isAnswer(frame) && frame.id === id);
  }

  /// Starts the main client on stdio, lists it when `listing`, and creates the session.
  async startOwner(listing: boolean) {
    const acp = this.fixture.spawn(this.gateway);
    this.owner = acp;
    this.spawned.push(acp);
    acp.listen((message: any) => this.ownerStream.push(message));
    if (listing) this.listers.add("m1");
    const init = await this.ownerCall("initialize", { protocolVersion: 1, clientCapabilities: listing ? LISTING : PLAIN });
    if (init.error) throw new Error(`initialize failed: ${JSON.stringify(init.error)}`);
    const created = await this.ownerCall("session/new", { cwd: this.fixture.workspace, mcpServers: [] });
    if (created.error) throw new Error(`session/new failed: ${JSON.stringify(created.error)}`);
    this.sessionId = created.result.sessionId;
    const mode = await this.ownerCall("session/set_mode", { sessionId: this.sessionId, modeId: "auto" });
    if (mode.error) throw new Error(`session/set_mode failed: ${JSON.stringify(mode.error)}`);
    this.evidence.push({ op: "owner", pid: acp.proc.pid, sessionId: this.sessionId, listing });
  }

  /// Sends the owner a prompt and waits for its answer, which must end the turn.
  async turn(text: string) {
    await this.startTurn(text);
    await this.ownerStream.until(
      (frames) => frames.some((frame) => isAnswer(frame) && frame.id === this.promptId),
      `the owner's answer to ${text}`,
      WAIT_MS,
    );
    const answer = this.ownerStream.frames.find((frame) => isAnswer(frame) && frame.id === this.promptId);
    if (answer.error) throw new Error(`prompt failed: ${JSON.stringify(answer.error)}`);
    if (answer.result?.stopReason !== "end_turn") throw new Error(`prompt answered ${JSON.stringify(answer.result)}`);
    this.drain();
  }

  /// Sends the owner a prompt without waiting for its answer.
  async startTurn(text: string) {
    this.drain();
    this.promptId = this.owner!.send("session/prompt", { sessionId: this.sessionId, prompt: [{ type: "text", text }] });
  }

  async waitSummary() {
    await within(this.summaryArrived.promise, "the compaction's summary request");
  }

  async waitTurnHeld() {
    await within(this.turnArrived.promise, "the turn's reply request");
  }

  async waitOwnerMessage(msg: string) {
    await this.ownerStream.until((frames) => frames.some((frame) => compactionMessage(frame) === msg), `the owner's ${msg}`, WAIT_MS);
  }

  releaseSummary() {
    this.summaryHold.resolve(compactingReply(this.helpers, SUMMARY_TEXT));
  }

  releaseTurn() {
    this.turnHold.resolve(compactingReply(this.helpers, FINAL_TEXT));
  }

  /// Connects a follower to the session's leader socket and loads the session. The join is
  /// recorded before the follower's frames are read, so its replay comes after it.
  async joinFollower(who: Member, listing: boolean) {
    this.drain();
    const lock = readFileSync(join(this.sessionDir(this.fixture.home, this.sessionId), "lock"), "utf8");
    const socket = JSON.parse(lock).socket as string;
    const client = await SocketClient.connect(socket);
    const init = await client.request("initialize", { protocolVersion: 1, clientCapabilities: listing ? LISTING : PLAIN });
    if (init.answer.error) throw new Error(`${who} initialize failed: ${JSON.stringify(init.answer.error)}`);
    const loaded = await client.request("session/load", { sessionId: this.sessionId, cwd: this.fixture.workspace, mcpServers: [] });
    if (loaded.answer.error) throw new Error(`${who} session/load failed: ${JSON.stringify(loaded.answer.error)}`);
    if (listing) this.listers.add(who);
    this.followers.set(who, client);
    this.cursor.set(who, 0);
    this.observations.push({ op: "join", who });
    this.evidence.push({ op: "joined", who, listing, replayFrames: loaded.index });
    this.drain();
  }

  /// The client leaves: its reads come first, so none follows the leave.
  async leave(who: Member) {
    this.drain();
    this.observations.push({ op: "leave", who });
    this.gone.add(who);
    this.followers.get(who)?.close();
  }

  /// The main's connection breaks. The main's frames are not read from here on, so its
  /// last message stays unread, as the model's failed write leaves it.
  async mainGone() {
    this.drain(["m2", "m3"]);
    this.observations.push({ op: "main_gone" });
    this.gone.add("m1");
    this.evidence.push({ op: "main_gone", unreadOwnerFrames: this.ownerStream.frames.length - (this.cursor.get("m1") ?? 0) });
    this.owner!.disconnect();
  }

  /// After the turn's last reply reaches every present client: each one's reads, then the
  /// quiet step, which requires every present client to have read everything written to it.
  async finish() {
    if (!this.gone.has("m1")) {
      await this.ownerStream.until(
        (frames) => frames.some((frame) => isAnswer(frame) && frame.id === this.promptId),
        "the owner's answer to the last prompt",
        WAIT_MS,
      );
    }
    for (const [who, client] of this.followers) {
      if (this.gone.has(who)) continue;
      await client.stream.until((frames) => frames.some(isFinalText), `${who}'s copy of the final reply`, WAIT_MS);
    }
    this.drain();
    this.observations.push({ op: "quiet" });
  }

  /// After the plan: the clients disconnect, and every fx acp must exit cleanly.
  async teardown() {
    for (const client of this.followers.values()) client.close();
    if (this.owner && !this.gone.has("m1")) this.owner.disconnect();
    for (const acp of this.spawned) {
      const outcome = await acp.waitForExit(WAIT_MS);
      this.processes.push({ pid: acp.proc.pid, exited: outcome.exited, exit: outcome.code, stderr: acp.stderr.slice(-2000) });
      if (!outcome.exited) throw new Error(`fx acp did not exit after its last client left: ${acp.stderr.slice(-400)}`);
      if (outcome.code !== 0) throw new Error(`fx acp exited ${outcome.code}: ${acp.stderr.slice(-400)}`);
    }
  }

  /// Stops what the run started: held replies are released, clients closed, fx killed if it still runs.
  dispose() {
    this.releaseSummary();
    this.releaseTurn();
    for (const client of this.followers.values()) client.close();
    for (const acp of this.spawned) {
      if (acp.proc.exitCode === null) acp.proc.kill("SIGKILL");
    }
    this.gateway?.stop();
    this.fixture.dispose();
  }

  record() {
    this.evidence.push({
      op: "gateway",
      summaries: this.summaries,
      turns: this.turns,
      requestHeads: this.requestHeads,
      completions: this.gateway?.requests?.length ?? null,
      classifier: this.gateway?.classifierRequests?.length ?? null,
      titles: this.gateway?.titleRequests?.length ?? null,
      bodyLengths: this.gateway?.requests?.map((request: { body: string }) => request.body.length) ?? null,
      summaryMarkerCounts: this.gateway?.requests?.map((request: { body: string }) => request.body.split(SUMMARY_SENTENCE).length - 1) ?? null,
    });
    this.evidence.push({
      op: "owner_frames",
      frames: this.ownerStream.frames.map((frame) => frame.method ?? (frame.result ? `result:${frame.result.stopReason ?? "ok"}` : `error:${frame.error?.message ?? ""}`)),
    });
    for (const acp of this.spawned) this.evidence.push({ op: "stderr", pid: acp.proc.pid, stderr: acp.stderr.slice(-2000) });
    const trace = existsSync(this.fixture.traceLog) ? readFileSync(this.fixture.traceLog, "utf8") : "";
    this.evidence.push({ op: "compactor_trace", lines: trace.split("\n").filter((line) => /compact|decision/.test(line)).slice(-40) });
  }

  listersInOrder(): Member[] {
    return MEMBERS.filter((who) => this.listers.has(who));
  }
}

function describe(o: Obs): string {
  switch (o.op) {
    case "start":
    case "main_gone":
    case "quiet":
      return o.op;
    case "join":
    case "leave":
      return `${o.op}(${o.who})`;
    case "read":
      return `${o.who}<-${o.msg}`;
    case "settle":
      return `settle(${o.arg})`;
  }
}

/// One plan against the real binary, with the observations and evidence it produced.
async function runPlan(plan: Plan, dir: string, helpers: any, sessionDir: (home: string, id: string) => string) {
  mkdirSync(dir, { recursive: true });
  const fixture = new CompactionFixture(binary, helpers.FAKE_GATEWAY_MODEL);
  const run = new Run(fixture, helpers, sessionDir, plan.holdTurn === true);
  let error: string | null = null;
  try {
    await plan.run(run);
    await run.teardown();
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    run.record();
    run.dispose();
  }
  writeJson(join(dir, "observations.json"), run.observations);
  writeJson(join(dir, "evidence.json"), run.evidence);
  writeJson(join(dir, "processes.json"), run.processes);
  return { run, error };
}

// -------------------------------------------------------------- self-check --

type Fault = { name: string; base: string; plant: (obs: Obs[]) => Obs[] };

function indexOrThrow(obs: Obs[], at: (o: Obs) => boolean, what: string): number {
  const k = obs.findIndex(at);
  if (k < 0) throw new Error(`self-check: no observation to ${what} in the base run`);
  return k;
}

/// The base runs' observations with one change each. Every planted fault is a claim fx
/// did not make: a done line to a lister, a read fx never wrote, an end that is not the
/// one written, a resend after a failover, or a read that is missing.
const FAULTS: Fault[] = [
  {
    name: "lister-reads-done",
    base: "both-list",
    plant: (obs) => {
      const k = indexOrThrow(obs, (o) => o.op === "settle", "plant after");
      return [...obs.slice(0, k + 1), { op: "read", who: "m2", msg: "done" }, ...obs.slice(k + 1)];
    },
  },
  {
    name: "lister-misses-end",
    base: "both-list",
    plant: (obs) => {
      const k = indexOrThrow(obs, (o) => o.op === "read" && o.who === "m2" && o.msg === "completed", "drop");
      return [...obs.slice(0, k), ...obs.slice(k + 1)];
    },
  },
  {
    name: "owner-reads-progress-twice",
    base: "both-list",
    plant: (obs) => {
      const k = indexOrThrow(obs, (o) => o.op === "read" && o.who === "m1" && o.msg === "in_progress", "duplicate");
      return [...obs.slice(0, k + 1), obs[k]!, ...obs.slice(k + 1)];
    },
  },
  {
    name: "end-reported-failed",
    base: "both-list",
    plant: (obs) =>
      obs.map((o) => (o.op === "settle" ? { op: "settle" as const, arg: "failed" as const } : o)),
  },
  {
    name: "lister-misses-progress",
    base: "both-list",
    plant: (obs) => {
      const k = indexOrThrow(obs, (o) => o.op === "read" && o.who === "m2" && o.msg === "in_progress", "drop");
      return [...obs.slice(0, k), ...obs.slice(k + 1)];
    },
  },
  {
    name: "failover-resends-progress",
    base: "main-breaks-failover",
    plant: (obs) => {
      const k = indexOrThrow(obs, (o) => o.op === "main_gone", "plant after");
      return [...obs.slice(0, k + 1), { op: "read", who: "m2", msg: "in_progress" }, ...obs.slice(k + 1)];
    },
  },
];

// -------------------------------------------------------------------- main --

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(["git", "-C", worktree, ...args], { stdout: "pipe", stderr: "pipe" });
  return new TextDecoder().decode(result.stdout).trim();
}

/// Runs the base plans the faults change, checks each unmodified, then plants each fault
/// into its base and requires the check to reject it.
async function selfCheck(mutation: Mutation, helpers: any, sessionDir: (home: string, id: string) => string, reportDir: string) {
  const bases = new Map<string, { observations: Obs[]; listers: Member[] }>();
  let ok = true;
  for (const name of ["both-list", "main-breaks-failover"]) {
    const plan = PLANS.find((candidate) => candidate.name === name)!;
    const { run, error } = await runPlan(plan, join(reportDir, "self-check", `base-${name}`), helpers, sessionDir);
    if (error) throw new Error(`self-check: the base run ${name} failed: ${error}`);
    const listers = run.listersInOrder();
    bases.set(name, { observations: run.observations, listers });
    const unmodified = await validate(run.observations, join(reportDir, "self-check", name), mutation, listers);
    ok = ok && unmodified.verdict === "ACCEPTED";
    console.log(`self-check: base run ${name} (unmodified) ${unmodified.verdict} (${unmodified.matched}/${unmodified.length})`);
  }
  for (const fault of FAULTS) {
    const base = bases.get(fault.base)!;
    const planted = fault.plant(base.observations);
    const check = await validate(planted, join(reportDir, "self-check", fault.name), mutation, base.listers);
    const caught = check.verdict === "REJECTED";
    ok = ok && caught;
    const at = check.firstDivergence ? `, first divergence at step ${check.firstDivergence.step}` : "";
    console.log(`self-check: ${fault.name} (on ${fault.base}) ${caught ? "rejected" : `NOT rejected (${check.verdict})`}${at}`);
  }
  return ok;
}

async function main() {
  if (!existsSync(binary)) throw new Error(`missing ${binary}; run zig build first or set FX_BIN`);
  const model = argValue("--model") ?? "rules";
  if (model !== "rules" && model !== "today") throw new Error(`--model must be rules or today, not ${model}`);
  const mutation: Mutation = model === "rules" ? "none" : "today";
  const only = argValue("--plan");
  const plans = only === undefined ? PLANS : PLANS.filter((plan) => plan.name === only);
  if (plans.length === 0) throw new Error(`no plan named ${only}`);
  const helpers = await targetHelpers();
  const saved = await targetModule("saved-sessions.ts");
  const selfCheckRun = process.argv.includes("--self-check");
  const reportDir = outDir(selfCheckRun ? `acp-compaction-audience-self-check-${model}` : `acp-compaction-audience-${model}`);
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

  if (selfCheckRun) {
    const ok = await selfCheck(mutation, helpers, saved.sessionDir, reportDir);
    process.exit(ok ? 0 : 1);
  }

  const results = [];
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const { run, error } = await runPlan(plan, dir, helpers, saved.sessionDir);
    const listers = run.listersInOrder();
    const checked = error ? null : await validate(run.observations, dir, mutation, listers);
    const verdict: Verdict | "RUN_ERROR" = error ? "RUN_ERROR" : checked!.verdict;
    const ok = verdict === "ACCEPTED";
    results.push({
      name: plan.name,
      covers: plan.covers,
      verdict,
      matched: checked?.matched ?? 0,
      length: run.observations.length,
      ok,
      error,
      firstDivergence: checked?.firstDivergence ?? null,
    });
    writeJson(join(dir, "run.json"), {
      plan: plan.name,
      model,
      verdict,
      matched: checked?.matched ?? 0,
      error,
      listers,
      firstDivergence: checked?.firstDivergence ?? null,
      observations: run.observations,
    });
    console.log(`  ops: ${run.observations.map(describe).join(" ")}`);
    const at = checked?.firstDivergence ? ` diverges at step ${checked.firstDivergence.step} (${describe(checked.firstDivergence.observation!)})` : "";
    console.log(
      `${plan.name}: ${verdict} (${checked?.matched ?? 0}/${run.observations.length})${at}${error ? ` ${error}` : ""}`,
    );
  }
  writeJson(join(reportDir, "summary.json"), { model, results });
  process.exit(results.every((result) => result.ok) ? 0 : 1);
}

await main();
