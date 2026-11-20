// Runtime driver: runs the real `fx acp` binary through five directed plans in
// which the client disconnects while a turn runs, and asks TLC whether each run
// is a behavior of tests/tla/acp/AcpDisconnect.tla.
//
//   bun tests/tla/drivers/acp/disconnect/driver.ts               # after zig build
//   bun tests/tla/drivers/acp/disconnect/driver.ts --model today
//
// --model rules (the default) validates each run with Rules TRUE: a kept turn
// finishes and is saved, a plain client's running turn stops, and a permission
// the gone client cannot answer is denied. --model today validates with Rules
// FALSE, fx acp before those rules, where a disconnect stops every running turn
// and a permission request waits. Each plan's observations are what the client
// wrote, what fx wrote, and what the fake Gateway served, in the order they
// happened; its exit's outcomes are what a later session/load replays. No model
// calls: every reply comes from the fake Gateway in tests/e2e/tmux-helpers.ts.
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, worktree } from "../../lib/context";
import { Fixture, clientCapabilities } from "./harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { type Observation, validate } from "./trace";

// ------------------------------------------------------------------- plans --

/// A reply the fake Gateway gives, in the order its requests come: `held` waits
/// for a `release` step; `final` is a final text; `write` is the write_file call
/// for the plan's file, served as the request arrives.
type Reply = "held" | "final" | "write";
/// A step the client takes, in order. `prompt` sends a prompt and waits for its
/// first model request. `queue` sends a prompt that waits behind the running
/// turn. `disconnect` closes the client's input. `release` answers the oldest
/// held reply, with a final text or with the plan's write_file call. A plain
/// plan's release first waits for prompt 1's response.
type Step = { op: "prompt" } | { op: "queue" } | { op: "disconnect" } | { op: "release"; as: "final" | "write" };
type Plan = { name: string; keep: boolean; mode: "auto" | "ask"; replies: Reply[]; steps: Step[]; file?: string };

const DIRECTED: Plan[] = [
  {
    name: "keep-held",
    keep: true,
    mode: "auto",
    replies: ["held"],
    steps: [{ op: "prompt" }, { op: "disconnect" }, { op: "release", as: "final" }],
  },
  {
    name: "keep-permission",
    keep: true,
    mode: "ask",
    replies: ["held", "final"],
    file: "kept.txt",
    steps: [{ op: "prompt" }, { op: "disconnect" }, { op: "release", as: "write" }],
  },
  {
    name: "keep-queue",
    keep: true,
    mode: "auto",
    replies: ["held", "final"],
    steps: [{ op: "prompt" }, { op: "queue" }, { op: "disconnect" }, { op: "release", as: "final" }],
  },
  {
    name: "plain-held",
    keep: false,
    mode: "auto",
    replies: ["held"],
    steps: [{ op: "prompt" }, { op: "disconnect" }, { op: "release", as: "final" }],
  },
  {
    name: "plain-queue-permission",
    keep: false,
    mode: "ask",
    replies: ["held", "write", "final"],
    file: "queued.txt",
    steps: [{ op: "prompt" }, { op: "queue" }, { op: "disconnect" }, { op: "release", as: "final" }],
  },
];

/// How long fx has to answer or exit after the client's input ends.
const EXIT_LIMIT_MS = 20_000;
/// Pacing only, for keep plans: their turns finish whether or not the held reply
/// resolves after fx reads the end of input, so this pause does not change their
/// outcome. Plain plans do not pause; they wait for prompt 1's response instead.
const PACING_MS = 500;
/// The notices fx writes for an interrupted turn, as its replay sends them.
const REPLAY_NOTICES = new Set(["cancelled", "failed", "fx stopped before this turn finished"]);

type Hold = { n: number; promise: Promise<Response>; resolve: (value: Response) => void };

function deferred(n: number): Hold {
  let resolve!: (value: Response) => void;
  const promise = new Promise<Response>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { n, promise, resolve };
}

/// A final text for reply `n`.
function finalReply(helpers: any, n: number): Response {
  return helpers.fakeGatewayFinalText(`DISCONNECT_DONE_${n}`);
}

/// The write_file call for reply `n`, which asks for `path`.
function writeReply(helpers: any, path: string, n: number): Response {
  return helpers.fakeGatewayToolCall(`disconnect_write_${n}`, "write_file", { path, content: `DISCONNECT_WRITE_${n}\n` });
}

/// The Gateway's reply queue, in the order its requests come: one reply per
/// request, so reply n is request n. Each reply is a function, so the fake
/// Gateway calls it as its request arrives: `arrive(n)` runs first, then the
/// reply. A held reply returns a promise the driver resolves at its `release`
/// step. A write_file reply calls `served(n)` when it is given.
function gatewayReplies(
  plan: Plan,
  fixture: Fixture,
  helpers: any,
  holds: Hold[],
  arrive: (n: number) => void,
  served: (n: number) => void,
): unknown[] {
  const path = plan.file ? join(fixture.workspace, plan.file) : "";
  return plan.replies.map((reply, index) => {
    const n = index + 1;
    if (reply === "held") {
      const hold = deferred(n);
      holds.push(hold);
      return () => {
        arrive(n);
        return hold.promise;
      };
    }
    if (reply === "final") {
      return () => {
        arrive(n);
        return finalReply(helpers, n);
      };
    }
    return () => {
      arrive(n);
      served(n);
      return writeReply(helpers, path, n);
    };
  });
}

/// The outcome of a prompt's response: end_turn is completed, cancelled is
/// interrupted, and anything else, or an error, is other.
function responseOutcome(message: any): "completed" | "interrupted" | "other" {
  if (message.error !== undefined) return "other";
  const stopReason = message.result?.stopReason;
  if (stopReason === "end_turn") return "completed";
  if (stopReason === "cancelled") return "interrupted";
  return "other";
}

/// The outcome of each turn a session/load replays. A turn starts at each user
/// message; it is interrupted when one of its agent texts is a notice fx writes
/// for an interrupted turn, and completed otherwise.
function replayOutcomes(notifications: any[]): string[] {
  const interrupted: boolean[] = [];
  for (const message of notifications) {
    const update = message.params?.update;
    if (update?.sessionUpdate === "user_message_chunk") {
      interrupted.push(false);
    } else if (update?.sessionUpdate === "agent_message_chunk" && REPLAY_NOTICES.has(update.content?.text)) {
      if (interrupted.length === 0) interrupted.push(false);
      interrupted[interrupted.length - 1] = true;
    }
  }
  return interrupted.map((stopped) => (stopped ? "interrupted" : "completed"));
}

async function waitFor(condition: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + 30_000;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(20);
  }
}

/// Waits for `promise`, or fails after `ms`.
async function within<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

// -------------------------------------------------------------- observations --

type PlanRun = {
  observations: Observation[];
  error: string | null;
  outcomes: string[] | null;
  exited: boolean;
  exitCode: number | null;
  fileWritten: boolean | null;
  requests: number;
  processes: Array<{ exit: number; stderr: string }>;
};

/// One plan's run against the real binary. The observations are the prompts the
/// client sent, its disconnect, the writes the Gateway served, the responses fx
/// wrote, and fx's exit or its being stuck, in the order they happened. The
/// exit's outcomes come from a session/load in a new process.
async function runPlan(plan: Plan, dir: string, helpers: any): Promise<PlanRun> {
  mkdirSync(dir, { recursive: true });
  const fixture = new Fixture(binary, helpers.FAKE_GATEWAY_MODEL);
  const holds: Hold[] = [];
  const observations: Observation[] = [];
  /// The write_file replies the Gateway served whose turns have not yet shown
  /// that they needed a permission, by reply number.
  const writesServed = new Set<number>();
  /// Pushes `ask` for the turn whose write_file reply is `n`, once, and only
  /// while that turn is still pending.
  const askFor = (n: number): void => {
    if (!writesServed.delete(n)) return;
    observations.push({ op: "ask" });
  };
  /// A request arrives. A write_file reply served before it was followed by
  /// that turn's next model request: fx decided the permission without the
  /// client, and asked the model again. That is the second fact that a turn
  /// needed a permission.
  const arrive = (n: number): void => {
    for (const written of [...writesServed]) if (written < n) askFor(written);
  };
  const served = (n: number): void => {
    writesServed.add(n);
  };
  fixture.init(helpers.startFakeGateway(gatewayReplies(plan, fixture, helpers, holds, arrive, served)));
  const gateway = fixture.gateway;
  const capabilities = clientCapabilities(plan.keep);
  const promptIds = new Set<number>();
  let firstPromptId: number | null = null;
  let resolveFirstAnswer!: () => void;
  const firstAnswer = new Promise<void>((resolve) => {
    resolveFirstAnswer = resolve;
  });
  /// Records each response fx writes after the client's input has closed, in
  /// arrival order. A session/request_permission from fx is the first fact that
  /// a turn needed a permission, so it pushes `ask` for the earliest pending
  /// turn. Other requests and notifications are not answers.
  const onFxMessage = (message: any) => {
    if ("method" in message) {
      if (message.method === "session/request_permission") {
        const [earliest] = [...writesServed].sort((a, b) => a - b);
        if (earliest !== undefined) askFor(earliest);
      }
      return;
    }
    if (!("result" in message) && !("error" in message)) return;
    if (!promptIds.has(message.id)) return;
    observations.push({ op: "response", outcome: responseOutcome(message) });
    if (message.id === firstPromptId) resolveFirstAnswer();
  };
  let released = 0;
  let prompts = 0;
  let sessionId: string | null = null;
  let outcomes: string[] | null = null;
  let exited = false;
  let exitCode: number | null = null;
  let error: string | null = null;
  let fileWritten: boolean | null = null;

  try {
    await fixture.start(capabilities);
    const created = await fixture.acp!.call("session/new", { cwd: fixture.workspace, mcpServers: [] });
    if (created.response.error) throw new Error(`session/new failed: ${JSON.stringify(created.response.error)}`);
    sessionId = created.response.result.sessionId;
    if (plan.mode === "ask") {
      const asked = await fixture.acp!.call("session/set_config_option", { sessionId, configId: "mode", value: "ask" });
      if (asked.response.error) throw new Error(`session/set_config_option failed: ${JSON.stringify(asked.response.error)}`);
      const option = asked.response.result?.configOptions?.find((o: any) => o.id === "mode");
      if (option?.currentValue !== "ask") throw new Error(`session/set_config_option answered ${JSON.stringify(option?.currentValue)}, not ask`);
    } else {
      const mode = await fixture.acp!.call("session/set_mode", { sessionId, modeId: "auto" });
      if (mode.response.error) throw new Error(`session/set_mode failed: ${JSON.stringify(mode.response.error)}`);
    }
    for (const step of plan.steps) {
      if (step.op === "prompt" || step.op === "queue") {
        prompts += 1;
        const before = gateway.requests.length;
        const params: Record<string, unknown> = { sessionId, prompt: [{ type: "text", text: `DISCONNECT_PROMPT_${prompts}` }] };
        if (step.op === "queue") params._meta = { "sh.fx/delivery": "queue" };
        const id = fixture.acp!.send("session/prompt", params);
        promptIds.add(id);
        if (firstPromptId === null) firstPromptId = id;
        observations.push({ op: "prompt" });
        if (step.op === "prompt") await waitFor(() => gateway.requests.length > before, "fx's model request for the prompt");
      } else if (step.op === "disconnect") {
        observations.push({ op: "disconnect" });
        fixture.acp!.listen(onFxMessage);
        fixture.acp!.disconnect();
        if (plan.keep) await Bun.sleep(PACING_MS);
      } else {
        const hold = holds[released];
        if (!hold) throw new Error("release with no held reply");
        released += 1;
        if (!plan.keep) await within(firstAnswer, EXIT_LIMIT_MS, "prompt 1's response after the client left");
        if (step.as === "write") served(hold.n);
        hold.resolve(step.as === "write" ? writeReply(helpers, join(fixture.workspace, plan.file!), hold.n) : finalReply(helpers, hold.n));
      }
    }

    const waited = await fixture.acp!.waitForExit(EXIT_LIMIT_MS);
    if (waited.exited) {
      exited = true;
      exitCode = waited.code;
      await fixture.close();
      await fixture.start(capabilities);
      const loaded = await fixture.acp!.call("session/load", { sessionId, cwd: fixture.workspace, mcpServers: [] });
      if (loaded.response.error) throw new Error(`session/load failed: ${JSON.stringify(loaded.response.error)}`);
      outcomes = replayOutcomes(loaded.notifications);
      observations.push({ op: "exit", outcomes });
    } else {
      fixture.acp!.proc.kill("SIGKILL");
      observations.push({ op: "stuck" });
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    for (const hold of holds) hold.resolve(helpers.fakeGatewayFinalText("disconnect cleanup"));
    await fixture.close();
    fileWritten = plan.file ? existsSync(join(fixture.workspace, plan.file)) : null;
    writeJson(join(dir, "observations.json"), observations);
    writeJson(join(dir, "processes.json"), fixture.processes);
    fixture.dispose();
  }
  return { observations, error, outcomes, exited, exitCode, fileWritten, requests: gateway.requests.length, processes: fixture.processes };
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
  const rules = model === "rules";
  const helpers = await targetHelpers();

  const reportDir = outDir(`acp-disconnect-${model}`);
  const status = git("status", "--porcelain");
  const manifest = {
    model, worktree, binary, head: git("rev-parse", "HEAD"), dirty: status.length > 0,
    diff_sha256: status ? sha256Text(git("diff", "HEAD")) : null, fx_binary_sha256: sha256File(binary),
    toolchain: tlcToolchain(), bun: Bun.version, argv: process.argv.slice(1),
  };
  writeJson(join(reportDir, "manifest.json"), manifest);

  const results = [];
  for (const plan of DIRECTED) {
    const dir = join(reportDir, "traces", plan.name);
    const run = await runPlan(plan, dir, helpers);
    const checked = run.error ? null : await validate(run.observations, dir, rules, plan.keep);
    const verdict = run.error ? "RUN_ERROR" : checked!.verdict;
    const matched = checked?.matched ?? 0;
    const passed = verdict === "ACCEPTED" && run.fileWritten !== true;
    writeJson(join(dir, "run.json"), {
      plan: plan.name, model, verdict, matched, length: run.observations.length, error: run.error,
      exited: run.exited, exitCode: run.exitCode, outcomes: run.outcomes, fileWritten: run.fileWritten,
      requests: run.requests, firstDivergence: checked?.firstDivergence ?? null,
      observations: run.observations, processes: run.processes,
    });
    results.push({ name: plan.name, verdict, matched, length: run.observations.length, passed, error: run.error });
    console.log(`${plan.name}: ${verdict} (${matched}/${run.observations.length}) outcomes=${JSON.stringify(run.outcomes ?? [])}${run.error ? ` ${run.error}` : ""}`);
    if (plan.file) console.log(`${plan.name}: ${plan.file} ${run.fileWritten ? "was written, which fails the plan" : "not written"}`);
  }

  writeJson(join(reportDir, "summary.json"), { manifest, results });
  console.log(`report: ${reportDir}`);
  process.exit(results.every((result) => result.passed) ? 0 : 1);
}

await main();
