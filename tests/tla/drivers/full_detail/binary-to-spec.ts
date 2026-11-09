// Binary to spec: runs the built fx binary through one turn of two model
// steps against a fake gateway, reads what Ctrl+O shows live and after a
// resume in a new process, and has TLC check both views against
// FullDetailOrder (TraceFullDetailOrder.tla).
//
// Two runs. In the first the first call is refused with a 429 and retried,
// the step's text and a tool follow, and the second step answers; the turn
// commits. In the second fx is killed while the second step's request is
// still open, so the resume shows what the last write of the turn held.
//
// Each Ctrl+O row the model knows becomes one of its items: the prompt, a
// failed attempt, a step's text, a call's record (its gen ID line) and a
// tool. Rows the model leaves out, such as times and the turn's totals, are
// skipped. --self-check also hands TLC a resume whose record sits above its
// text, which the model must reject.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/full_detail/binary-to-spec.ts [--self-check]
//
// Exit codes: 0 every run is a behavior of the model, 1 a run is not (or a
// self-check was not rejected), 2 a toolchain or setup failure.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TLA_ROOT, fxBin, outDir, runTlc } from "../lib/tlc";
import { onlySessionId } from "../../../e2e/saved-sessions";

process.env.FX_E2E_DISABLE_DOTENV = "1";
const { FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewaySse, startFakeGateway, tmuxAvailable } = await import(
  "../../../e2e/tmux-helpers"
);

type Item = { k: number; t: "prompt" | "fail" | "text" | "rec" | "tool"; a: number };
type Session = Awaited<ReturnType<typeof TmuxSession.create>>;

const TIMEOUT = 30_000;
const HINT = "esc close · pgup/pgdn scroll";
const PROMPT = "DRIVE_FULL_DETAIL_PROMPT";
const TEXT = ["", "DRIVE_STEP_ONE_TEXT", "DRIVE_STEP_TWO_TEXT"];
const MODEL = FAKE_GATEWAY_MODEL.slice(FAKE_GATEWAY_MODEL.lastIndexOf("/") + 1);
const SPEC_DIR = join(TLA_ROOT, "full_detail");

function finish(reason: "stop" | "tool-calls", gen: string) {
  return {
    type: "finish",
    finishReason: { unified: reason, raw: reason },
    usage: { inputTokens: { total: 100 }, outputTokens: { total: 10 } },
    providerMetadata: { gateway: { generationId: gen } },
  };
}

function refused(): Response {
  return new Response(JSON.stringify({ error: { message: "slow down" } }), {
    status: 429,
    headers: { "content-type": "application/json", "retry-after": "1" },
  });
}

function toolStep(): Response {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: TEXT[1] },
    { type: "tool-call", toolCallId: "run_1", toolName: "shell", input: { request: { action: "run", command: "printf ok" } } },
    finish("tool-calls", "gen_01JC7P5XQ2M8VZ000000000001"),
  ]);
}

function answer(): Response {
  return fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: TEXT[2] },
    finish("stop", "gen_01JC7P5XQ2M8VZ000000000002"),
  ]);
}

/// The model's items in the order Ctrl+O shows them.
export function itemsOf(rows: string[]): Item[] {
  const items: Item[] = [];
  let step = 1;
  let fails = 0;
  for (const row of rows) {
    if (row.startsWith("┃ ") && row.includes(PROMPT)) items.push({ k: 0, t: "prompt", a: 0 });
    else if (/^\s+Error · /.test(row)) items.push({ k: step, t: "fail", a: ++fails });
    else if (row.includes(`· ${MODEL} ·`) && row.includes("gen_")) items.push({ k: step, t: "rec", a: 0 });
    else if (TEXT[step] && row.includes(TEXT[step]!)) items.push({ k: step, t: "text", a: 0 });
    else if (/^● Ran /.test(row)) {
      items.push({ k: step, t: "tool", a: 0 });
      step += 1;
      fails = 0;
    }
  }
  return items;
}

function tla(items: Item[]): string {
  return `<<${items.map((it) => `[k |-> ${it.k}, t |-> "${it.t}", a |-> ${it.a}]`).join(", ")}>>`;
}

async function fullDetail(session: Session): Promise<string[]> {
  await session.sendHexBytes(["0f"]);
  await session.waitForText(HINT, TIMEOUT);
  return (await session.capturePane()).split("\n").map((row) => row.trimEnd());
}

async function start(cmd: string, cwd: string, env: Record<string, string | undefined>): Promise<Session> {
  const session = await TmuxSession.create({ cmd, cwd, env, width: 120, height: 70, isolated: true });
  await session.waitForComposer(TIMEOUT);
  return session;
}

/// One run: live Ctrl+O at the end of the turn (or once the second request
/// is open), then Ctrl+O after quitting and resuming.
async function observe(bin: string, crash: boolean): Promise<{ live: Item[]; replay: Item[]; rows: string[][] }> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-full-detail-drive-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  let opened = false;
  const second = crash
    ? () => {
        opened = true;
        return new Promise<Response>(() => {});
      }
    : answer();
  // After the crash, the resumed fx sends the interrupted request again. It
  // gets no answer either, so the resume shows only what the turn saved.
  const gateway = startFakeGateway(
    crash ? [refused(), toolStep(), second, () => new Promise<Response>(() => {})] : [refused(), toolStep(), second],
  );
  const env: Record<string, string | undefined> = {
    HOME: home,
    TERM: "xterm-256color",
    NO_COLOR: "1",
    AI_GATEWAY_API_KEY: "fake-full-detail-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "full-access",
    FX_SOUND: "0",
  };
  let session: Session | undefined;
  try {
    session = await start(bin, workspace, env);
    await session.sendText(PROMPT);
    if (crash) {
      await session.waitForPane(() => opened, TIMEOUT);
      await session.waitForText("ok", TIMEOUT);
    } else {
      await session.waitForText(TEXT[2]!, TIMEOUT);
      await session.waitForComposer(TIMEOUT);
    }
    const liveRows = await fullDetail(session);
    await session.kill();
    session = await start(`${bin} --resume ${onlySessionId(home)}`, workspace, env);
    const replayRows = await fullDetail(session);
    return { live: itemsOf(liveRows), replay: itemsOf(replayRows), rows: [liveRows, replayRows] };
  } finally {
    await session?.kill();
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

/// Whether TLC finds a behavior of FullDetailOrder that shows `live` and
/// then `replay`.
async function isBehavior(dir: string, live: Item[], replay: Item[]): Promise<boolean> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "TraceData.tla"),
    ["---- MODULE TraceData ----", `ObservedLive == ${tla(live)}`, `ObservedReplay == ${tla(replay)}`, "===="].join("\n") + "\n",
  );
  writeFileSync(
    join(dir, "TraceFullDetailOrder.cfg"),
    [
      "CONSTANTS",
      "    Steps = 2",
      "    MaxFails = 1",
      "    PinTop = FALSE",
      '    RecordsSaved = "always"',
      "    SplitFailures = TRUE",
      "INIT Init",
      "NEXT Next",
      "CONSTRAINT OnObservedRun",
      "INVARIANT NotTheRun",
      // A committed or stopped turn has no next step.
      "CHECK_DEADLOCK FALSE",
    ].join("\n") + "\n",
  );
  const run = await runTlc(dir, "TraceFullDetailOrder", "TraceFullDetailOrder.cfg", ["FullDetailOrder.tla", "TraceFullDetailOrder.tla"], SPEC_DIR);
  if (run.violated === "NotTheRun") return true;
  if (run.exitCode === 0) return false;
  console.error(run.output);
  process.exit(2);
}

async function main() {
  if (!tmuxAvailable()) {
    console.error("tmux is required");
    process.exit(2);
  }
  const bin = fxBin();
  const out = outDir("full_detail");
  let failed = false;
  for (const crash of [false, true]) {
    const name = crash ? "crash" : "commit";
    const run = await observe(bin, crash);
    writeFileSync(join(out, `${name}-rows.txt`), run.rows.map((rows) => rows.join("\n")).join("\n\n=== resumed ===\n\n"));
    const ok = await isBehavior(join(out, name), run.live, run.replay);
    console.log(`${name}: live ${run.live.length} items, resume ${run.replay.length} items: ${ok ? "a behavior of the model" : "NOT a behavior of the model"}`);
    if (!ok) failed = true;
    if (!crash && process.argv.includes("--self-check")) {
      // A resume that shows the first call's record above its text.
      const swapped = [...run.replay];
      const text = swapped.findIndex((it) => it.t === "text");
      const rec = swapped.findIndex((it) => it.t === "rec");
      [swapped[text], swapped[rec]] = [swapped[rec]!, swapped[text]!];
      const rejected = !(await isBehavior(join(out, "self-check"), run.live, swapped));
      console.log(`self-check: a record above its text is ${rejected ? "rejected" : "NOT rejected"}`);
      if (!rejected) failed = true;
    }
  }
  console.log(`output in ${out}`);
  process.exit(failed ? 1 : 0);
}

if (import.meta.main) await main();
