// Runtime driver: runs the real `fx acp` binary through two directed plans in
// which a session/set_config_option lands while a turn runs, and asks TLC
// whether each run is a behavior of tests/tla/acp/AcpConfigTurn.tla.
//
//   bun tests/tla/drivers/acp/config_turn/driver.ts               # after zig build
//   bun tests/tla/drivers/acp/config_turn/driver.ts --model today
//
// --model rules (the default) validates each run with Rules TRUE: a change
// during a turn is answered at once, and the running turn keeps the settings it
// started with. --model today validates with Rules FALSE, the model before
// those rules, where a change during a turn fails with -32600. The build in this
// checkout answers the change, so under today every plan must be rejected.
// No model calls: every reply comes from the fake Gateway in
// tests/e2e/tmux-helpers.ts.
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, worktree } from "../../lib/context";
import { Fixture } from "./harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { type Observation, validate } from "./trace";

// ------------------------------------------------------------------- plans --

/// A step the client takes, in the order the driver takes it. `prompt` sends a
/// prompt; with `hold`, its first model request waits until a `release`.
/// `config` sends set_config_option for the model. `release` answers the held
/// request with a read_file tool call and waits for that prompt's answer.
type Step = { op: "prompt"; hold: boolean } | { op: "config"; model: string } | { op: "release" };
type Plan = { name: string; steps: Step[] };

const MODEL_B = "o4-mini";
const MODEL_C = "gpt-4.1-mini";
const CONFIG_BUSY = "Prompt already in progress";

const DIRECTED: Plan[] = [
  {
    name: "d1-change-mid-turn",
    steps: [
      { op: "prompt", hold: true },
      { op: "config", model: MODEL_B },
      { op: "release" },
      { op: "prompt", hold: false },
    ],
  },
  {
    name: "d2-change-idle-then-mid-turn",
    steps: [
      { op: "prompt", hold: false },
      { op: "config", model: MODEL_B },
      { op: "prompt", hold: true },
      { op: "config", model: MODEL_C },
      { op: "release" },
      { op: "prompt", hold: false },
    ],
  },
];

type Hold = { promise: Promise<Response>; resolve: (value: Response) => void };

/// The Gateway's reply queue, in the order its requests come. A held prompt
/// gets its first reply from a promise the driver resolves, and then a final
/// text for the request after the tool call. Any other prompt gets one final text.
function replies(plan: Plan, helpers: any, holds: Hold[]): unknown[] {
  const queue: unknown[] = [];
  let turn = 0;
  for (const step of plan.steps) {
    if (step.op !== "prompt") continue;
    turn += 1;
    if (step.hold) {
      const hold = deferred();
      holds.push(hold);
      queue.push(() => hold.promise);
    }
    queue.push(helpers.fakeGatewayFinalText(`CONFIG_TURN_ANSWER_${turn}`));
  }
  return queue;
}

function deferred(): Hold {
  let resolve!: (value: Response) => void;
  const promise = new Promise<Response>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}

/// The reply that asks for note.txt, as the E2E test sends it.
function readFileReply(helpers: any, turn: number): Response {
  return helpers.fakeGatewaySse([
    {
      type: "tool-call",
      toolCallId: `config_turn_read_${turn}`,
      toolName: "read_file",
      input: { path: "note.txt" },
    },
    {
      type: "finish",
      finishReason: { unified: "tool-calls", raw: "tool-calls" },
    },
  ]);
}

/// The models the fake Gateway lists: the session's first model, then B and C.
function catalog(first: string) {
  return [first, MODEL_B, MODEL_C].map((id) => ({ id, type: "language", tags: ["tool-use"] }));
}

// ------------------------------------------------------------ observations --

/// One plan's run against the real binary. The observations are what the
/// client and the fake Gateway saw, in the order they happened. Each request's
/// `ver` is the index of its model in the settings versions: version 0 is the
/// session's first model, and each ok answer to set_config_option appends its
/// model. A model that is not in the list gives -2.
async function runPlan(plan: Plan, dir: string, helpers: any) {
  mkdirSync(dir, { recursive: true });
  const first: string = helpers.FAKE_GATEWAY_MODEL;
  const holds: Hold[] = [];
  const fixture = new Fixture(binary, first);
  fixture.init(helpers.startFakeGateway(replies(plan, helpers, holds), { models: catalog(first) }));
  const gateway = fixture.gateway;
  const observations: Observation[] = [];
  const versions: string[] = [first];
  const requestModels: Array<string | null> = [];
  let seen = 0;
  let released = 0;
  let turns = 0;
  let sessionId: string | null = null;
  let pending: number | null = null;
  let error: string | null = null;

  /// Records each model request the fake Gateway has got since the last call.
  const recordRequests = () => {
    while (seen < gateway.requests.length) {
      const model: string | null = gateway.requests[seen].headers.get("ai-language-model-id");
      requestModels.push(model);
      const index = model === null ? -1 : versions.indexOf(model);
      observations.push({ op: "request", ver: index < 0 ? -2 : index });
      seen += 1;
    }
  };
  const waitForRequests = async (count: number) => {
    const deadline = Date.now() + 30_000;
    while (true) {
      recordRequests();
      if (seen >= count) return;
      if (Date.now() > deadline) throw new Error(`fx sent ${seen} model requests, not ${count}`);
      await Bun.sleep(20);
    }
  };
  /// Waits for the answer to prompt `id`, recording each model request on the way.
  const finish = async (id: number) => {
    const answer = fixture.acp!.collect(id);
    let settled = false;
    const tracked = answer.finally(() => {
      settled = true;
    });
    // A failed answer is raised by the race below; this keeps it from also
    // counting as an unhandled rejection while the loop sleeps.
    tracked.catch(() => undefined);
    while (!settled) {
      recordRequests();
      await Promise.race([tracked, Bun.sleep(20)]);
    }
    recordRequests();
    const { response } = await answer;
    if (response.error) throw new Error(`session/prompt failed: ${JSON.stringify(response.error)}`);
    if (response.result?.stopReason !== "end_turn") throw new Error(`prompt stopped with ${JSON.stringify(response.result)}`);
    observations.push({ op: "response" });
  };
  /// Sends set_config_option for the model, and records what fx answered. An
  /// answer with no error is "ok" and names the model it applied; the busy
  /// answer is -32600 "Prompt already in progress".
  const configure = async (model: string) => {
    recordRequests();
    const id = fixture.acp!.send("session/set_config_option", { sessionId, configId: "model", value: model });
    const { response } = await fixture.acp!.collect(id);
    if (response.error) {
      if (response.error.code !== -32600 || response.error.message !== CONFIG_BUSY) {
        throw new Error(`session/set_config_option failed: ${JSON.stringify(response.error)}`);
      }
      observations.push({ op: "config", answer: "busy", provider: "gateway" });
      return;
    }
    const option = response.result?.configOptions?.find((o: any) => o.id === "model");
    if (option?.currentValue !== model) {
      throw new Error(`session/set_config_option answered ${JSON.stringify(option?.currentValue)}, not ${model}`);
    }
    versions.push(model);
    observations.push({ op: "config", answer: "ok", provider: "gateway" });
  };
  /// Sends a prompt. A held prompt returns once its first model request is in;
  /// any other prompt returns once its answer is in.
  const prompt = async (hold: boolean) => {
    if (pending !== null) throw new Error("a prompt is already in flight");
    turns += 1;
    pending = fixture.acp!.send("session/prompt", { sessionId, prompt: [{ type: "text", text: `CONFIG_TURN_PROMPT_${turns}` }] });
    observations.push({ op: "prompt" });
    if (hold) {
      await waitForRequests(seen + 1);
      return;
    }
    const id = pending;
    pending = null;
    await finish(id);
  };
  /// Answers the held request with the read_file tool call, then waits for the
  /// held prompt's answer.
  const release = async () => {
    const hold = holds[released];
    if (!hold) throw new Error("release with no held request");
    if (pending === null) throw new Error("release with no prompt in flight");
    released += 1;
    hold.resolve(readFileReply(helpers, released));
    const id = pending;
    pending = null;
    await finish(id);
  };

  try {
    await fixture.start();
    const created = await fixture.acp!.call("session/new", { cwd: fixture.workspace, mcpServers: [] });
    if (created.response.error) throw new Error(`session/new failed: ${JSON.stringify(created.response.error)}`);
    sessionId = created.response.result.sessionId;
    const mode = await fixture.acp!.call("session/set_mode", { sessionId, modeId: "auto" });
    if (mode.response.error) throw new Error(`session/set_mode failed: ${JSON.stringify(mode.response.error)}`);
    for (const step of plan.steps) {
      if (step.op === "prompt") await prompt(step.hold);
      else if (step.op === "config") await configure(step.model);
      else await release();
    }
    recordRequests();
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    for (const hold of holds) hold.resolve(helpers.fakeGatewayFinalText("config turn cleanup"));
    await fixture.close();
    writeJson(join(dir, "observations.json"), observations);
    writeJson(join(dir, "processes.json"), fixture.processes);
    fixture.dispose();
  }
  return { observations, error, versions, requestModels, processes: fixture.processes };
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

  const reportDir = outDir(`acp-config-turn-${model}`);
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
    const checked = run.error ? null : await validate(run.observations, dir, rules);
    const verdict = run.error ? "RUN_ERROR" : checked!.verdict;
    const matched = checked?.matched ?? 0;
    const passed = verdict === "ACCEPTED";
    writeJson(join(dir, "run.json"), {
      plan: plan.name, model, verdict, matched, length: run.observations.length, error: run.error,
      firstDivergence: checked?.firstDivergence ?? null, versions: run.versions, requestModels: run.requestModels,
      processes: run.processes, observations: run.observations,
    });
    results.push({ name: plan.name, verdict, matched, length: run.observations.length, passed, error: run.error });
    console.log(`${plan.name}: ${verdict} (${matched}/${run.observations.length})${run.error ? ` ${run.error}` : ""}`);
  }

  writeJson(join(reportDir, "summary.json"), { manifest, results });
  console.log(`report: ${reportDir}`);
  process.exit(results.every((result) => result.passed) ? 0 : 1);
}

await main();
