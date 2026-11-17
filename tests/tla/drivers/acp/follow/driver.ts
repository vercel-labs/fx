// Runtime driver: runs the real `fx acp` binary through directed plans that
// open a session, run turns, restart the process and load the session again,
// records what each open and save leaves the client holding, and asks TLC
// whether each run is a behavior of tests/tla/acp/AcpFollow.tla.
//
//   bun tests/tla/drivers/acp/follow/driver.ts               # after zig build
//   bun tests/tla/drivers/acp/follow/driver.ts --model today
//
// --model rules (the default) checks fx now: a replayed message's id
// comes from its place in the log, so every load gives it the same id.
// --model today checks the model of older fx, which no build matches now,
// so every plan must be rejected. No model calls: every reply comes from the
// fake Gateway in tests/e2e/tmux-helpers.ts.
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, worktree } from "../../lib/context";
import { Fixture } from "./harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { type Held, type Observation, validate } from "./trace";

// ------------------------------------------------------------------- plans --

type Turn = "plain" | "tool";
type Step = { op: "open-new" } | { op: "open-load" } | { op: "prompt"; turn: Turn } | { op: "restart" };
type Plan = { name: string; steps: Step[] };

const NEW: Step = { op: "open-new" };
const LOAD: Step = { op: "open-load" };
const RESTART: Step = { op: "restart" };
const prompt = (turn: Turn): Step => ({ op: "prompt", turn });

const DIRECTED: Plan[] = [
  {
    name: "d1-two-loads",
    steps: [NEW, prompt("plain"), prompt("tool"), RESTART, LOAD, RESTART, LOAD],
  },
  {
    name: "d2-load-then-prompt",
    steps: [NEW, prompt("plain"), RESTART, LOAD, prompt("tool"), RESTART, LOAD, prompt("plain"), RESTART, LOAD],
  },
];

/// One Gateway reply queue per plan, in the order of its prompts: a plain
/// turn is one final text, and a tool turn streams text, reads note.txt, and
/// then ends with a final text.
function replies(plan: Plan, helpers: any): unknown[] {
  const queue: unknown[] = [];
  let turn = 0;
  for (const step of plan.steps) {
    if (step.op !== "prompt") continue;
    turn += 1;
    if (step.turn === "plain") {
      queue.push(helpers.fakeGatewayFinalText(`FOLLOW_IDS_ANSWER_${turn}`));
      continue;
    }
    queue.push(helpers.fakeGatewaySse([
      { type: "text-delta", id: "answer_1", delta: `FOLLOW_IDS_STEP_${turn}` },
      {
        type: "tool-call",
        toolCallId: `follow_read_${turn}`,
        toolName: "read_file",
        input: { path: "note.txt" },
      },
      {
        type: "finish",
        finishReason: { unified: "tool-calls", raw: "tool-calls" },
      },
    ]));
    queue.push(helpers.fakeGatewayFinalText(`FOLLOW_IDS_ANSWER_${turn}`));
  }
  return queue;
}

// ------------------------------------------------------------ observations --

const TURN_ID = /^turn-(\d+)-(\d+)$/;
const LIVE_ID = /^[0-9a-f]{32}$/;

/// The replayed user and agent messages of one open, in order, with the ids
/// their turns' messages carry.
function replayedIds(notifications: any[]): string[][] {
  const turns: string[][] = [];
  for (const message of notifications) {
    const update = message?.params?.update;
    const kind = update?.sessionUpdate;
    if (kind !== "user_message_chunk" && kind !== "agent_message_chunk") continue;
    if (kind === "user_message_chunk" || turns.length === 0) turns.push([]);
    turns.at(-1)!.push(String(update.messageId));
  }
  return turns;
}

/// What a load leaves the client holding: one record per replayed turn, whose
/// id is the shared `n` of `turn-{n}-{k}` when the turn's messages carry
/// k = 0, 1, 2, ... in order, else -1.
function heldFromReplay(turns: string[][]): Held[] {
  return turns.map((ids, index) => {
    let number: number | null = null;
    let ok = ids.length > 0;
    ids.forEach((id, place) => {
      const match = TURN_ID.exec(id);
      if (!match) {
        ok = false;
        return;
      }
      const n = Number(match[1]);
      if (number === null) number = n;
      if (n !== number || Number(match[2]) !== place) ok = false;
    });
    return { turn: index + 1, id: ok && number !== null ? number : -1, replayed: true };
  });
}

/// What a prompt leaves the client holding for its new turn: fx's own id
/// (-1), or -2 when a live chunk's id is not fx's 32 hex characters.
function liveId(notifications: any[]): number {
  const ids = notifications
    .map((message) => message?.params?.update)
    .filter((update) => update?.sessionUpdate === "agent_message_chunk")
    .map((update) => String(update.messageId));
  return ids.length > 0 && ids.every((id) => LIVE_ID.test(id)) ? -1 : -2;
}

// ------------------------------------------------------------------ runs --

async function runPlan(plan: Plan, dir: string) {
  mkdirSync(dir, { recursive: true });
  const helpers = await targetHelpers();
  const fixture = new Fixture(binary);
  fixture.init(helpers.startFakeGateway(replies(plan, helpers), {}));
  const observations: Observation[] = [];
  let error: string | null = null;
  let sessionId: string | null = null;
  let held: Held[] = [];
  let prompts = 0;
  try {
    for (const step of plan.steps) {
      const acp = fixture.acp;
      if (step.op === "restart") {
        await fixture.close();
        observations.push({ op: "close", has: [] });
      } else if (step.op === "open-new") {
        await fixture.start();
        const { response, notifications } = await fixture.acp!.call("session/new", { cwd: fixture.workspace, mcpServers: [] });
        if (response.error) throw new Error(`session/new failed: ${JSON.stringify(response.error)}`);
        sessionId = response.result.sessionId;
        const ids = replayedIds(notifications);
        held = heldFromReplay(ids);
        observations.push({ op: "open", has: held, detail: { ids } });
      } else if (step.op === "open-load") {
        await fixture.start();
        const { response, notifications } = await fixture.acp!.call("session/load", {
          sessionId, cwd: fixture.workspace, mcpServers: [],
        });
        if (response.error) throw new Error(`session/load failed: ${JSON.stringify(response.error)}`);
        const ids = replayedIds(notifications);
        held = heldFromReplay(ids);
        observations.push({ op: "open", has: held, detail: { ids } });
      } else {
        if (!acp) throw new Error("a prompt needs an open session");
        const { response, notifications } = await acp.call("session/prompt", {
          sessionId, prompt: [{ type: "text", text: `FOLLOW_IDS_PROMPT_${prompts + 1}` }],
        });
        if (response.error) throw new Error(`session/prompt failed: ${JSON.stringify(response.error)}`);
        prompts += 1;
        held = [...held, { turn: prompts, id: liveId(notifications), replayed: false }];
        observations.push({ op: "save", has: held });
      }
    }
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally {
    await fixture.close();
    writeJson(join(dir, "observations.json"), observations);
    writeJson(join(dir, "processes.json"), fixture.processes);
    fixture.dispose();
  }

  // Every open must agree, turn by turn, on the raw ids of the turns both hold,
  // and no open may repeat an id.
  const opens = observations.filter((o) => o.op === "open");
  const idsOf = (o: Observation) => ((o.detail as { ids?: string[][] } | undefined)?.ids ?? []);
  let loadsAgree = true;
  for (const open of opens) {
    const flat = idsOf(open).flat();
    if (new Set(flat).size !== flat.length) loadsAgree = false;
  }
  for (let a = 0; a < opens.length; a += 1) {
    for (let b = a + 1; b < opens.length; b += 1) {
      const left = idsOf(opens[a]!);
      const right = idsOf(opens[b]!);
      for (let turn = 0; turn < Math.min(left.length, right.length); turn += 1) {
        if (JSON.stringify(left[turn]) !== JSON.stringify(right[turn])) loadsAgree = false;
      }
    }
  }
  return { observations, loadsAgree, error, processes: fixture.processes };
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
  const idRules = model === "rules";

  const reportDir = outDir(`acp-follow-${model}`);
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
    const run = await runPlan(plan, dir);
    const checked = run.error ? null : await validate(run.observations, dir, idRules);
    const verdict = run.error ? "RUN_ERROR" : checked!.verdict;
    const matched = checked?.matched ?? 0;
    const passed = verdict === "ACCEPTED" && (idRules ? run.loadsAgree : true);
    writeJson(join(dir, "run.json"), {
      plan: plan.name, model, verdict, matched, length: run.observations.length,
      loadsAgree: run.loadsAgree, error: run.error, firstDivergence: checked?.firstDivergence ?? null,
      processes: run.processes, observations: run.observations,
    });
    results.push({ name: plan.name, verdict, matched, length: run.observations.length, loadsAgree: run.loadsAgree, passed, error: run.error });
    console.log(`${plan.name}: ${verdict} (${matched}/${run.observations.length}) loadsAgree=${run.loadsAgree}${run.error ? ` ${run.error}` : ""}`);
  }

  writeJson(join(reportDir, "summary.json"), { manifest, results });
  console.log(`report: ${reportDir}`);
  process.exit(results.every((result) => result.passed) ? 0 : 1);
}

await main();
