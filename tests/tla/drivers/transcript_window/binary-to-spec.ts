// Binary to spec: drives the built fx binary through three compaction cycles
// (the transcript window is always on), resizes the terminal, walks Ctrl+O
// over every cycle, quits, resumes in a new process, and walks Ctrl+O again. It reads the steps the binary traced (the `transcript_window` scope),
// replays each window's events through the harness around the core, checks
// that every effect the binary traced is the one the core returns, and has TLC
// check the traces against TranscriptWindow (TraceTranscriptWindow.tla).
//
// The harness stages check the core alone. This one checks the shell around
// it in the real binary (src/ui/transcript/transcript_window_shell.zig): which
// events the runtime derives from its entries, in what order, at which sync
// points, and that it runs the core it ships. It also checks what the user
// sees: Ctrl+O shows every prompt once and in order, live and after resume,
// and the resumed main screen holds only the newest cycle.
//
// Entry ids are renumbered per window so the model's Ids stay small. A
// `resumed` step (the window restarting from the log: a new process, or a
// /resume) is replayed as the model's Resumed: the log's blocks the window has
// not seen are added as finished and saved, the harness crashes and resumes,
// and the resume it derives must be the one the binary traced. Only the
// binary's own steps are checked against its traced effects.
//
// Run alone: bun binary-to-spec.ts [--bin PATH]
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT, outDir, writeJson } from "../lib/tlc.ts";
import { onlySessionId, sessionDir } from "../../../e2e/saved-sessions.ts";
import { FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewayFinalText, startFakeGateway } from "../../../e2e/tmux-helpers.ts";
import { SETS, runTrace, type Step } from "./code-to-spec.ts";
import { buildHarness, checkTlc, specFiles, toTla, type CheckedTlc, type Config, type Effect, type Event } from "./lib.ts";

const TIMEOUT = 30_000;
/// The shell's core config (transcript_window_shell.zig).
const SHELL_CONFIG = { window: 256, read_step: 64, slice: 64 };
const PROMPTS = [
  ["Earlier visible request: release region is ap-southeast-2. Briefly acknowledge receipt only. CYCLE0_A", "CYCLE0_B"],
  ["Earlier visible request: build target is arm64. Briefly acknowledge receipt only. CYCLE1_A", "CYCLE1_B"],
  ["CYCLE2_A", "CYCLE2_B"],
];
const ORDER = ["CYCLE0_A", "CYCLE0_B", "CYCLE1_A", "CYCLE1_B", "CYCLE2_A", "CYCLE2_B"];

export type TracedWindow = { saved: boolean; steps: { event: string; effect: string }[] };

/// The windows a trace log holds, each from its `window_enabled` line.
export function parseTrace(text: string): TracedWindow[] {
  const windows: TracedWindow[] = [];
  for (const line of text.split("\n")) {
    const enabled = line.match(/\[transcript_window\] window_enabled saved=(true|false)/);
    if (enabled) {
      windows.push({ saved: enabled[1] === "true", steps: [] });
      continue;
    }
    const step = line.match(/\[transcript_window\] step event=(\S+) effect=(\S+)/);
    if (step && windows.length > 0) windows[windows.length - 1]!.steps.push({ event: step[1]!, effect: step[2]! });
  }
  return windows;
}

/// A traced event as the harness takes it, with ids renumbered by `ids`.
export function eventOf(text: string, ids: Map<string, number>): Event {
  const [name, ...args] = text.split(":");
  const id = () => {
    const raw = args[0]!;
    if (!ids.has(raw)) ids.set(raw, ids.size + 1);
    return ids.get(raw)!;
  };
  switch (name) {
    case "turn_started":
    case "turn_ended":
    case "compacted":
    case "resized":
    case "reprint_tick":
      return { event: name };
    case "block_opened":
    case "block_changed":
    case "block_finished":
      return { event: name, id: id() };
    case "saved_through":
      return { event: name, seq: Number(args[0]) };
    case "resumed":
      return { event: name, cycle: Number(args[0]), cycle_first: Number(args[1]), next_seq: Number(args[2]) };
    default:
      throw new Error(`untraceable event ${text}`);
  }
}

/// An effect in the form the shell traces it (`describeEffect`).
export function effectText(out: Effect[]): string {
  if (out.length === 0) return "none";
  const effect = out[0]!;
  switch (effect.kind) {
    case "drop":
    case "reprint_slice":
    case "ctrlo_show":
      return `${effect.kind}:${effect.from}:${effect.to}`;
    case "paint_final":
      return `paint_final:${effect.seq}`;
    default:
      return effect.kind;
  }
}

async function waitFor(check: () => boolean, what: string) {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    if (check()) return;
    await Bun.sleep(100);
  }
  throw new Error(`timed out: ${what}`);
}

async function walkCtrlO(session: TmuxSession): Promise<string[]> {
  await session.sendHexBytes(["0f"]);
  await session.waitForText("full detail · ctrl+o close", TIMEOUT);
  for (let i = 0; i < 40; i += 1) {
    await session.sendKeys("PageUp");
    await Bun.sleep(120);
  }
  await Bun.sleep(500);
  const pages = [await session.capturePane()];
  for (let i = 0; i < 30; i += 1) {
    await session.sendKeys("PageDown");
    await Bun.sleep(150);
    pages.push(await session.capturePane());
  }
  await session.sendHexBytes(["0f"]);
  await session.waitForComposer(TIMEOUT);
  return pages;
}

function promptOrder(pages: string[]): string[] {
  const seen: string[] = [];
  for (const page of pages) {
    for (const match of page.matchAll(/CYCLE\d_[AB]/g)) if (!seen.includes(match[0])) seen.push(match[0]);
  }
  return seen;
}

/// Runs the scenario on the binary and returns its trace log and what it showed.
async function runScenario(bin: string, dir: string) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-transcript-window-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  const trace = join(dir, "fx-trace.log");
  const gateway = startFakeGateway(Array.from({ length: 30 }, (_, index) => fakeGatewayFinalText(`ok reply ${index}`)));
  const env: Record<string, string | undefined> = {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-tla-transcript-window",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "full-access",
    FX_SOUND: "0",
    NO_COLOR: "1",
    FX_TRACE_LOG: trace,
    FX_TRACE_SCOPES: "transcript_window,full_transcript_cache",
  };
  const shown: Record<string, string[]> = {};
  let session: TmuxSession | null = null;
  try {
    // Its own tmux server, so nothing else on the machine can end the run.
    session = await TmuxSession.create({ cmd: bin, cwd: workspace, env, width: 100, height: 30, isolated: true, stderrPath: join(dir, "fx-live.stderr") });
    await session.waitForComposer(TIMEOUT);
    let compactions = 0;
    for (const [index, cycle] of PROMPTS.entries()) {
      for (const prompt of cycle) {
        await session.sendText(prompt);
        await session.waitForText(prompt.split(" ").pop()!, TIMEOUT);
        await session.waitForPane((pane) => /ok reply/.test(pane), TIMEOUT);
        await session.waitForComposer(TIMEOUT);
      }
      if (index === PROMPTS.length - 1) break;
      const log = join(sessionDir(home, onlySessionId(home)), "log.jsonl");
      await session.sendText("/compact");
      compactions += 1;
      await waitFor(() => existsSync(log) && (readFileSync(log, "utf8").match(/"kind":"compacted"/g) ?? []).length === compactions, `compaction ${compactions}`);
      await session.waitForPane((pane) => !/Preparing compaction|Compacting|Stopping compaction/.test(pane), TIMEOUT);
      await session.waitForComposer(TIMEOUT);
    }
    // A resize clears the screen and scrollback and replays what the window
    // holds: the newest cycle only, the compaction on.
    await session.resizeWindow(80, 30);
    await session.resizeWindow(100, 30);
    await session.waitForComposer(TIMEOUT);
    await Bun.sleep(800);
    shown.resizedMain = promptOrder([await session.captureFullScrollback()]);
    shown.live = promptOrder(await walkCtrlO(session));
    const id = onlySessionId(home);
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    await session.kill();
    session = await TmuxSession.create({ cmd: `${bin} --resume ${id}`, cwd: workspace, env, width: 100, height: 30, isolated: true, stderrPath: join(dir, "fx-resumed.stderr") });
    await session.waitForComposer(TIMEOUT);
    await Bun.sleep(800);
    shown.resumedMain = promptOrder([await session.captureFullScrollback()]);
    shown.resumed = promptOrder(await walkCtrlO(session));
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
  } finally {
    await session?.kill();
    gateway.stop();
  }
  return { log: existsSync(trace) ? readFileSync(trace, "utf8") : "", shown };
}

export type BinaryToSpecResult = {
  windows: number;
  /// Windows that restarted from the log (`resumed`), replayed as a crash and resume.
  resumed: number;
  steps: number;
  rejected: number;
  archiveLoads: number;
  shown: Record<string, string[]>;
  tlc: CheckedTlc | null;
  problem: string | null;
};

export async function binaryToSpec(options: { bin: string; dir: string }): Promise<BinaryToSpecResult> {
  mkdirSync(options.dir, { recursive: true });
  const { log, shown } = await runScenario(options.bin, options.dir);
  const result: BinaryToSpecResult = {
    windows: 0,
    resumed: 0,
    steps: 0,
    rejected: (log.match(/\[transcript_window\] rejected /g) ?? []).length,
    archiveLoads: (log.match(/archive_loaded back=/g) ?? []).length,
    shown,
    tlc: null,
    problem: null,
  };
  const expect = (name: string, got: string[], want: string[]) => {
    if (!result.problem && JSON.stringify(got) !== JSON.stringify(want)) result.problem = `${name} showed ${JSON.stringify(got)}, not ${JSON.stringify(want)}`;
  };
  expect("Ctrl+O live", shown.live ?? [], ORDER);
  expect("Ctrl+O after resume", shown.resumed ?? [], ORDER);
  expect("the resumed main screen", shown.resumedMain ?? [], ["CYCLE2_A", "CYCLE2_B"]);
  expect("the main screen after a resize", shown.resizedMain ?? [], ["CYCLE2_A", "CYCLE2_B"]);
  if (result.rejected > 0) result.problem ??= `the binary traced ${result.rejected} rejected window events`;

  const harness = buildHarness(join(options.dir, "harness"));
  const runs: { name: string; states: Record<string, unknown>[]; maxId: number; maxSeq: number }[] = [];
  let saved: boolean | null = null;
  for (const [index, window] of parseTrace(log).entries()) {
    if (saved !== null && saved !== window.saved) {
      result.problem ??= "the traced windows mix saved and unsaved sessions";
      continue;
    }
    saved = window.saved;
    const ids = new Map<string, number>();
    const config: Config = { ...SHELL_CONFIG, saved: window.saved };
    // The harness steps, and for each traced step the recorded state that
    // shows its effect (a resume records the crash and then the resume).
    const steps: Step[] = [];
    const shownAt: number[] = [];
    let recorded = 0;
    let finished = 0;
    let synthetic = 0;
    for (const step of window.steps) {
      const event = eventOf(step.event, ids);
      if (event.event === "resumed") {
        const nextSeq = event.next_seq as number;
        if (event.cycle !== 0 || event.cycle_first !== 0 || nextSeq < finished) {
          result.problem ??= `window ${index}: resumed ${step.event} is not a restart from a log of ${nextSeq} blocks`;
        }
        for (; finished < nextSeq; finished += 1) {
          synthetic += 1;
          steps.push({ event: { event: "block_finished", id: 1_000_000 + synthetic } });
          recorded += 1;
        }
        steps.push({ event: { event: "saved_through", seq: nextSeq } });
        steps.push({ event: { event: "crash" } });
        recorded += 3;
        shownAt.push(recorded);
        continue;
      }
      if (event.event === "block_finished") finished += 1;
      steps.push({ event });
      recorded += 1;
      shownAt.push(recorded);
    }
    // Synthetic ids are renumbered after the binary's.
    for (const { event } of steps) {
      if (event.event === "block_finished" && (event.id as number) > 1_000_000) event.id = ids.size + ((event.id as number) - 1_000_000);
    }
    const recorder = await runTrace(harness, config, steps, 100_000);
    if (recorder.problem) result.problem ??= `window ${index}: ${recorder.problem}`;
    if (recorder.rejected > 0) result.problem ??= `window ${index}: the core rejected ${recorder.rejected} events the binary applied`;
    window.steps.forEach((step, at) => {
      const state = recorder.states[shownAt[at]!];
      const effect = state ? effectText(state.out as Effect[]) : "missing";
      if (effect !== step.effect) result.problem ??= `window ${index} step ${at} (${step.event}): the binary traced ${step.effect}, the core returns ${effect}`;
    });
    const maxIdUsed = ids.size + synthetic;
    const maxSeq = Math.max(0, ...recorder.states.map((state) => Number(state.nextSeq)));
    runs.push({ name: `window ${index}`, states: recorder.states, maxId: maxIdUsed, maxSeq });
    result.windows += 1;
    if (window.steps.some((step) => step.event.startsWith("resumed:"))) result.resumed += 1;
    result.steps += window.steps.length;
  }
  if (runs.length === 0) {
    result.problem ??= "the binary traced no window";
    return result;
  }
  const files = specFiles();
  const maxId = Math.max(1, ...runs.map((run) => run.maxId));
  const maxSeq = Math.max(400, ...runs.map((run) => run.maxSeq + 1));
  const cfgText = files["TraceTranscriptWindow.cfg"]!
    .replace(/MaxSeq = \d+/, `MaxSeq = ${maxSeq}`)
    .replace(/Ids = \{[^}]*\}/, `Ids = {${Array.from({ length: maxId }, (_, i) => i + 1).join(", ")}}`)
    .replace(/Window = \d+/, `Window = ${SHELL_CONFIG.window}`)
    .replace(/Step = \d+/, `Step = ${SHELL_CONFIG.read_step}`)
    .replace(/Slice = \d+/, `Slice = ${SHELL_CONFIG.slice}`)
    .replace(/Saved = (TRUE|FALSE)/, `Saved = ${saved ? "TRUE" : "FALSE"}`);
  // The runs were recorded with None = 100,000; the model's None is MaxSeq + 1.
  const none = maxSeq + 1;
  const data = [
    "---- MODULE TraceData ----",
    "EXTENDS Integers",
    "Traces == <<",
    runs
      .map((run) => `  \\* ${run.name}\n  <<${run.states.map((state) => toTla({ ...state, prevFirst: state.prevFirst === 100_000 ? none : state.prevFirst }, SETS)).join(",\n   ")}>>`)
      .join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
  writeFileSync(join(options.dir, "TraceData.tla"), data);
  result.tlc = await checkTlc(join(options.dir, "tlc"), "TraceTranscriptWindow", "TraceTranscriptWindow.cfg", {
    ...files,
    "TraceTranscriptWindow.cfg": cfgText,
    "TraceData.tla": data,
  });
  if (result.tlc.verdict !== "pass") result.problem ??= `TLC: ${result.tlc.verdict}${result.tlc.property ? ` (${result.tlc.property})` : ""}`;
  return result;
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const binIndex = args.indexOf("--bin");
  const bin = binIndex >= 0 ? args[binIndex + 1]! : join(REPO_ROOT, "zig-out", "bin", "fx");
  const dir = join(outDir("transcript_window"), "binary-to-spec");
  const result = await binaryToSpec({ bin, dir });
  writeJson(join(dir, "result.json"), result);
  console.log(JSON.stringify({ ...result, tlc: result.tlc ? { verdict: result.tlc.verdict, property: result.tlc.property, distinct: result.tlc.distinct } : null }, null, 2));
  process.exit(result.problem ? 1 : 0);
}
