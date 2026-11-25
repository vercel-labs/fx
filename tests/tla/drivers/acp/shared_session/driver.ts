// Runtime driver: runs the real fx acp binary through six plans in which the clients of one
// session open it, join it, leave it, and send prompts and steers. The opener is on stdio;
// the others connect to the session's leader socket. f2 does not list sh.fx/sessionClients.
// Each run is checked against tests/tla/acp/AcpSharedSession.tla through
// AcpSharedSessionTrace.tla.
//
// What the driver records is what fx wrote: each client's answers, the lists of connected
// clients, and the prompt and steer chunks, each with the client it names. A step waits for
// the frame it expects before it goes on, so it orders each step by what it has read, not by
// timing. The fake Gateway holds every model reply until the driver ends it, so a turn stays
// in a known phase. No model calls.
//
//   bun tests/tla/drivers/acp/shared_session/driver.ts                 # --model rules
//   bun tests/tla/drivers/acp/shared_session/driver.ts --model today   # the control
//   bun tests/tla/drivers/acp/shared_session/driver.ts --plan prompt-and-steer
//
// --model rules (the default) validates each run with Rules TRUE, the sh.fx rules. --model
// today validates with Rules FALSE, the model before the list and the sender key. Each plan
// expects rules ACCEPTED and today REJECTED. The control moves the main client of one list
// to another client; it must be REJECTED under rules.
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetModule, worktree } from "../../lib/context";
import { Acp, clientCapabilities } from "../disconnect/harness";
import { FrameStream, SharedFixture, SocketClient, isAnswer } from "../shared_input/harness";
import { type Client, type Obs, type Verdict, validate } from "./trace";
import { outDir, sha256File, tlcToolchain, writeJson } from "./tlc";

/// How long a step waits for the frame it expects. A frame that never comes is left out of the
/// trace, and TLC rejects the run.
const WAIT_MS = 10_000;
const LABELS: Client[] = ["opener", "f1", "f2"];
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/// The capabilities of a client. Only a listing client lists sh.fx/sessionClients.
export function capabilities(listing: boolean): { _meta: Record<string, unknown> } {
  const caps = clientCapabilities(false) as { _meta: Record<string, unknown> };
  if (listing) caps._meta["sh.fx/sessionClients"] = {};
  return caps;
}

class Run {
  readonly observations: Obs[] = [];
  private owner: Acp | null = null;
  private readonly ownerFrames = new FrameStream();
  private readonly followers = new Map<Client, SocketClient>();
  /// Each client's id (`c` and a number) as fx gave it at `initialize`.
  private readonly labels = new Map<string, Client>();
  /// `${client}:${id}` for each session/new and session/load request, whose answer is an observation.
  private readonly openIds = new Set<string>();
  /// A joiner's replay comes before its load answer; its chunks are not new messages.
  private readonly replaying = new Map<Client, boolean>();
  private readonly cursor = new Map<Client, number>();
  private sessionId = "";
  /// Prompts and steers so far. The model numbers them in this order, from 1.
  private steps = 0;

  constructor(private readonly fixture: SharedFixture, private readonly sessionDir: (home: string, id: string) => string) {}

  private frames(c: Client): any[] {
    if (c === "opener") return this.ownerFrames.frames;
    return this.followers.get(c)?.stream.frames ?? [];
  }

  private label(id: unknown): Client | undefined {
    return typeof id === "string" ? this.labels.get(id) : undefined;
  }

  /// The client an entry of a list names. A client that lists sh.fx/sessionClients learns its id
  /// from its initialize answer. A client that does not list it has no id on the wire, so its entry
  /// is matched by the clientInfo name the driver sent it; the id is then recorded for its chunks.
  private bind(entry: any): Client | undefined {
    const known = this.label(entry?.clientId);
    if (known !== undefined) return known;
    const name = entry?.clientInfo?.name;
    if (typeof entry?.clientId !== "string" || !LABELS.includes(name)) return undefined;
    this.labels.set(entry.clientId, name);
    return name;
  }

  /// Reads the frames each client has received since the last call, in order, and records each
  /// one the model knows as an observation.
  pump() {
    for (const c of LABELS) {
      const frames = this.frames(c);
      let at = this.cursor.get(c) ?? 0;
      while (at < frames.length) {
        this.readFrame(c, frames[at]);
        at += 1;
      }
      this.cursor.set(c, at);
    }
  }

  private readFrame(c: Client, frame: any) {
    if (isAnswer(frame) && this.openIds.has(`${c}:${frame.id}`)) {
      this.replaying.set(c, false);
      this.observations.push({ op: "read", c, kind: "answer", n: 0, who: [], main: "none", from: "none" });
      return;
    }
    if (frame?.method === "_sh.fx/session/clients_update") {
      const clients: any[] = frame.params?.clients ?? [];
      const who = clients.map((entry) => this.bind(entry)).filter((name): name is Client => name !== undefined);
      const main = this.bind(clients.find((entry) => entry.main === true)) ?? "none";
      this.observations.push({ op: "read", c, kind: "clients", n: 0, who, main, from: "none" });
      return;
    }
    if (frame?.method === "session/update" && frame.params?.update?.sessionUpdate === "user_message_chunk") {
      if (this.replaying.get(c)) return;
      const update = frame.params.update;
      const from = this.label(update._meta?.["sh.fx/client"]) ?? "none";
      const marker = /\b([PS])(\d+)\b/.exec(String(update.content?.text ?? ""));
      // A chunk without a marker is one the model has no step for, so it gets a number it cannot match.
      if (marker === null) {
        this.observations.push({ op: "read", c, kind: "echo", n: 999, who: [], main: "none", from });
        return;
      }
      this.observations.push({ op: "read", c, kind: marker[1] === "P" ? "echo" : "steer", n: Number(marker[2]), who: [], main: "none", from });
    }
  }

  /// Reads frames until `ready` holds, for up to WAIT_MS. It returns whether it did.
  async waitUntil(ready: () => boolean): Promise<boolean> {
    const until = Date.now() + WAIT_MS;
    for (;;) {
      this.pump();
      if (ready()) return true;
      if (Date.now() > until) return false;
      await sleep(50);
    }
  }

  private answered(c: Client, id: number): boolean {
    return this.frames(c).some((frame) => isAnswer(frame) && frame.id === id);
  }

  /// The members of the latest list `c` received, sorted and joined, or "" for none.
  private latestMembers(c: Client): string {
    const last = this.frames(c).filter((frame) => frame?.method === "_sh.fx/session/clients_update").at(-1);
    if (!last) return "";
    return (last.params.clients as any[]).map((entry) => this.bind(entry) ?? "?").sort().join(",");
  }

  waitMembers(c: Client, members: Client[]): Promise<boolean> {
    const expected = [...members].sort().join(",");
    return this.waitUntil(() => this.latestMembers(c) === expected);
  }

  waitText(c: Client, text: string): Promise<boolean> {
    return this.waitUntil(() => this.frames(c).some((frame) => frame?.method === "session/update" && String(frame.params?.update?.content?.text ?? "").includes(text)));
  }

  /// The owner starts fx acp, opens the session with session/new, and runs one turn, which
  /// publishes the session on its leader socket.
  async start() {
    this.owner = this.fixture.spawn();
    const init = await this.owner.call("initialize", { protocolVersion: 1, clientCapabilities: capabilities(true), clientInfo: { name: "opener", version: "1" } });
    this.labels.set(init.response?.result?._meta?.["sh.fx/clientId"], "opener");
    this.owner.listen((message) => this.ownerFrames.push(message));
    const id = this.owner.send("session/new", { mcpServers: [] });
    this.openIds.add(`opener:${id}`);
    this.observations.push({ op: "open", c: "opener", k: "new" });
    await this.waitUntil(() => this.answered("opener", id));
    this.sessionId = this.ownerFrames.frames.find((frame) => isAnswer(frame) && frame.id === id)?.result?.sessionId ?? "";
    await this.waitMembers("opener", ["opener"]);
    const publish = this.prompt("opener", "publish");
    await this.waitUntil(() => this.answered("opener", publish.id));
    await this.finish("opener", publish.id);
  }

  /// A client loads the session on the leader socket. It reads its list and its answer.
  async join(c: Client) {
    this.observations.push({ op: "open", c, k: "load" });
    const lock = readFileSync(join(this.sessionDir(this.fixture.home, this.sessionId), "lock"), "utf8");
    const socket = JSON.parse(lock).socket as string;
    const client = await SocketClient.connect(socket);
    this.followers.set(c, client);
    this.replaying.set(c, true);
    const init = await client.request("initialize", { protocolVersion: 1, clientCapabilities: capabilities(c !== "f2"), clientInfo: { name: c, version: "1" } });
    const clientId = init.answer?.result?._meta?.["sh.fx/clientId"];
    if (typeof clientId === "string") this.labels.set(clientId, c);
    const id = client.send("session/load", { sessionId: this.sessionId, cwd: this.fixture.workspace, mcpServers: [] });
    this.openIds.add(`${c}:${id}`);
    await this.waitUntil(() => this.answered(c, id));
    this.pump();
  }

  /// A client's prompt, or steer, goes to fx. Its chunk is what the other clients read.
  prompt(c: Client, text: string, steer = false): { k: number; id: number } {
    this.steps += 1;
    const k = this.steps;
    this.observations.push(steer ? { op: "steer", c } : { op: "prompt", c });
    const params: Record<string, unknown> = { sessionId: this.sessionId, prompt: [{ type: "text", text: `${steer ? "S" : "P"}${k} ${text}` }] };
    if (steer) params._meta = { "sh.fx/delivery": "steer" };
    const id = c === "opener" ? this.owner!.send("session/prompt", params) : this.followers.get(c)!.send("session/prompt", params);
    return { k, id };
  }

  steer(c: Client, text: string): { k: number; id: number } {
    return this.prompt(c, text, true);
  }

  /// Ends the running turn: its held model replies end until the sender's prompt is answered.
  async finish(sender: Client, id: number) {
    const until = Date.now() + WAIT_MS;
    while (!this.answered(sender, id) && Date.now() < until) {
      for (const hold of this.fixture.holds) hold.end("final");
      await sleep(100);
      this.pump();
    }
    this.observations.push({ op: "endTurn" });
    this.pump();
  }

  /// A client leaves the session. It has read every message first, as the model requires.
  async close(c: Client) {
    this.pump();
    this.observations.push({ op: "close", c });
    if (c === "opener") this.owner!.send("session/close", { sessionId: this.sessionId });
    else this.followers.get(c)?.close();
  }

  /// The run is over: every message fx wrote for the model has been read.
  quiet() {
    this.pump();
    this.observations.push({ op: "quiet" });
  }

  dispose() {
    this.owner?.disconnect();
    for (const client of this.followers.values()) client.close();
  }
}

type Plan = { name: string; run: (run: Run) => Promise<void> };

const PLANS: Plan[] = [
  {
    name: "new-then-load",
    run: async (r) => {
      await r.start();
      await r.join("f1");
      await r.waitMembers("opener", ["opener", "f1"]);
      await r.waitMembers("f1", ["opener", "f1"]);
    },
  },
  {
    name: "non-listing-joins",
    run: async (r) => {
      await r.start();
      await r.join("f2");
      await r.waitMembers("opener", ["opener", "f2"]);
    },
  },
  {
    name: "follower-closes",
    run: async (r) => {
      await r.start();
      await r.join("f1");
      await r.waitMembers("f1", ["opener", "f1"]);
      await r.close("f1");
      await r.waitMembers("opener", ["opener"]);
    },
  },
  {
    name: "main-leaves",
    run: async (r) => {
      await r.start();
      await r.join("f1");
      await r.waitMembers("f1", ["opener", "f1"]);
      await r.close("opener");
      await r.waitMembers("f1", ["f1"]);
    },
  },
  {
    name: "prompt-and-steer",
    run: async (r) => {
      await r.start();
      await r.join("f1");
      await r.join("f2");
      await r.waitMembers("f1", ["opener", "f1", "f2"]);
      const prompt = r.prompt("opener", "hold");
      await r.waitText("f1", `P${prompt.k}`);
      await r.waitText("f2", `P${prompt.k}`);
      const steer = r.steer("f1", "join");
      await r.waitText("opener", `S${steer.k}`);
      await r.waitText("f2", `S${steer.k}`);
      await r.waitText("f1", `S${steer.k}`);
      await r.finish("opener", prompt.id);
    },
  },
  {
    name: "prompt-from-follower",
    run: async (r) => {
      await r.start();
      await r.join("f1");
      await r.join("f2");
      await r.waitMembers("f1", ["opener", "f1", "f2"]);
      const prompt = r.prompt("f1", "from f1");
      await r.waitText("opener", `P${prompt.k}`);
      await r.waitText("f2", `P${prompt.k}`);
      await r.finish("f1", prompt.id);
    },
  },
];

async function runPlan(plan: Plan, dir: string, sessionDir: (home: string, id: string) => string) {
  mkdirSync(dir, { recursive: true });
  const fixture = new SharedFixture(binary);
  await fixture.init();
  const run = new Run(fixture, sessionDir);
  let error: string | null = null;
  try {
    await plan.run(run);
    run.quiet();
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  }
  writeJson(join(dir, "observations.json"), run.observations);
  run.dispose();
  fixture.dispose();
  return { run, error };
}

/// A control: the first list whose main client is the opener names f1 as its main instead.
/// The model must reject it, so the check cannot pass a run the trace does not match.
function tamper(observations: Obs[]): Obs[] | null {
  const copy: Obs[] = structuredClone(observations);
  const index = copy.findIndex((o) => o.op === "read" && o.kind === "clients" && o.main === "opener");
  if (index === -1) return null;
  const read = copy[index] as Extract<Obs, { op: "read" }>;
  copy[index] = { ...read, main: "f1" };
  return copy;
}

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
  const reportDir = outDir(`acp-shared-session-${model}`);
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

  const rules = model === "rules";
  const expected: Verdict = rules ? "ACCEPTED" : "REJECTED";
  const results = [];
  const observed = new Map<string, Obs[]>();
  for (const plan of plans) {
    const dir = join(reportDir, "traces", plan.name);
    const { run, error } = await runPlan(plan, dir, saved.sessionDir);
    observed.set(plan.name, run.observations);
    const checked = await validate(run.observations, dir, rules);
    const verdict = error ? "RUN_ERROR" : checked.verdict;
    const ok = verdict === expected;
    results.push({ name: plan.name, verdict, matched: checked.finalIndex, length: run.observations.length, expected, ok, error });
    console.log(`${plan.name}: ${verdict} (${checked.finalIndex ?? "-"}/${run.observations.length})${ok ? "" : ` UNEXPECTED, expected ${expected}`}${error ? ` ${error}` : ""}`);
  }

  const controls: Array<{ name: string; expect: Verdict; got: Verdict }> = [];
  if (rules) {
    const trace = observed.get("new-then-load");
    const flipped = trace ? tamper(trace) : null;
    if (flipped) {
      const got = (await validate(flipped, join(reportDir, "controls", "tampered-main"), true)).verdict;
      controls.push({ name: "tampered-main", expect: "REJECTED", got });
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
