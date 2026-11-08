// Binary to spec: resumes a long saved session in the built fx, submits a
// prompt while the resume still publishes into scrollback, and waits for the
// turn to finish. It reads what every committed frame did from the trace log
// (the `scroll`, `paint`, `frame_commit`, and `session` scopes), writes the
// run as a trace of TranscriptScrollback, and has TLC check that every frame
// is a step of the model. It also checks what the person sees: the full
// scrollback and screen hold every row of the resumed session once and in
// order, and then the turn.
//
// Why a trace log and not a Zig harness: the transcript runtime cannot be
// built alone, so its frames are read from the real binary, as
// transcript_window/binary-to-spec.ts does for the window.
//
// The abstraction: a row is a visual row of the flow. A frame that scrolls n
// rows pushes the rows [view, view + n) of the old screen into scrollback,
// where `view` is the top of the screen before the frame. The history mark
// the runtime claims is the `target_history_visual_offset` of its frame.
// Frames that a taller composer defers during publication scroll nothing and
// leave the mark alone, so they are left out of the trace (the model says why).
//
// The run is also checked against two planted defects: the trace with the
// scroll of the first live frame that scrolls removed (origin/main's rule at
// the handoff), and with one row too many. TLC must reject both, so a pass
// cannot come from an empty check.
//
// With --control the prompt is submitted after the resume has finished
// publishing, so the growth reaches the model through ordinary live frames.
//
// Run alone: bun binary-to-spec.ts [--bin PATH] [--rows N] [--control]
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc, writeJson, type TlcRun } from "../lib/tlc.ts";
import { onlySessionId } from "../../../e2e/saved-sessions.ts";
import { FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewayFinalText, startDynamicFakeGateway } from "../../../e2e/tmux-helpers.ts";

const TIMEOUT = 60_000;
const MODEL_DIR = join(TLA_ROOT, "transcript_scrollback");
const SPECS = ["TranscriptScrollback.tla", "TraceTranscriptScrollback.tla"];
const TURN_ROWS = ["TURN_ROW_1", "TURN_ROW_2", "TURN_ROW_3"];
const TRACE_SCOPES = "scroll,paint,frame_commit,frame_schedule,session";

export type Frame = {
  /** The transcript commit state the frame started from: invalid, recovering, or stable. */
  source: string;
  /** The state it committed: recovering or stable. */
  commit: string;
  deferred: boolean;
  remaining: number | null;
  view: number;
  mark: number;
  applied: number;
  total: number;
  area: number;
  /** The frame committed the last publication step and handed over to the live flow. */
  handoff: boolean;
};

export type Range = { lo: number; hi: number };
export type ModelState = {
  phase: "publishing" | "handoff" | "live";
  total: number;
  view: number;
  area: number;
  sb: Range[];
  mark: number;
  armed: boolean;
  submits: number;
};

function number(line: string, key: string): number | null {
  const match = line.match(new RegExp(`(?:^|\\s)${key}=(\\d+)`));
  return match ? Number(match[1]) : null;
}

/// The committed transcript frames a trace log holds, in order.
export function parseFrames(log: string): Frame[] {
  const frames: Frame[] = [];
  let current: Partial<Frame> | null = null;
  for (const line of log.split("\n")) {
    if (line.includes("[frame_schedule] attempt_begin")) {
      current = { applied: 0, deferred: false, remaining: null, handoff: false };
      continue;
    }
    if (!current) continue;
    if (line.includes("[paint] transcript_select")) {
      const top = number(line, "top");
      const bottom = number(line, "bottom");
      const total = number(line, "total_lines");
      if (top !== null && bottom !== null && total !== null) {
        current.area = bottom - top + 1;
        current.total = total;
      }
    } else if (line.includes("[scroll] transcript_transition_finalize")) {
      current.source = line.match(/source_state=(\w+)/)?.[1];
      current.view = number(line, "target_visual_offset") ?? undefined;
      current.mark = number(line, "target_history_visual_offset") ?? undefined;
    } else if (line.includes("[frame_commit] wire_frame")) {
      current.applied = number(line, "applied_scroll_rows") ?? 0;
    } else if (line.includes("[scroll] transcript_transition_commit")) {
      current.commit = line.match(/transcript_transition_commit state=(\w+)/)?.[1];
      current.deferred = line.includes("recovery_projection_deferred=true");
      current.remaining = number(line, "remaining_semantic_rows");
    } else if (line.includes("[session] resume historical flow committed")) {
      current.handoff = true;
    } else if (line.includes("[frame_schedule] attempt_end")) {
      const done = current;
      current = null;
      if (!line.includes("outcome=committed")) continue;
      if (done.source === undefined || done.commit === undefined) continue;
      if (done.view === undefined || done.mark === undefined || done.area === undefined || done.total === undefined) continue;
      frames.push(done as Frame);
    }
  }
  return frames;
}

/// Rows [lo, lo + n) enter scrollback, joining the range before them if they touch it.
function addRange(sb: Range[], lo: number, n: number): Range[] {
  if (n === 0) return sb;
  const last = sb[sb.length - 1];
  if (last && last.hi === lo) return [...sb.slice(0, -1), { lo: last.lo, hi: lo + n }];
  return [...sb, { lo, hi: lo + n }];
}

export type ModelTrace = {
  states: ModelState[];
  publishedRows: number;
  maxArea: number;
  maxStep: number;
  handoffFrame: number | null;
  problem: string | null;
};

/// The trace of TranscriptScrollback the frames make. `tweak` changes the
/// scroll of the first live frame that scrolls, for the planted defects.
export function modelTrace(frames: Frame[], tweak?: (applied: number) => number): ModelTrace {
  const first = frames[0];
  const result: ModelTrace = { states: [], publishedRows: 0, maxArea: 1, maxStep: 1, handoffFrame: null, problem: null };
  if (!first || first.source !== "invalid") {
    result.problem = "the trace does not start with the first frame of a resume";
    return result;
  }
  const published = first.total;
  const area0 = first.area;
  result.publishedRows = published;
  let state: ModelState = { phase: "publishing", total: published, view: 0, area: area0, sb: [], mark: 0, armed: false, submits: 0 };
  result.states.push(state);
  let scrolled = 0;
  for (const [index, frame] of frames.entries()) {
    if (state.phase === "publishing") {
      // A deferred frame paints in place and scrolls nothing.
      if (frame.deferred || (frame.commit === "recovering" && frame.applied === 0)) continue;
      if (frame.area !== state.area || frame.total !== published) {
        result.problem ??= `frame ${index}: the area or the flow changed during publication, which the model leaves out`;
        continue;
      }
      const mark = frame.commit === "recovering" ? published - area0 - (frame.remaining ?? 0) : frame.mark;
      state = { ...state, sb: addRange(state.sb, state.view, frame.applied), view: frame.view, mark };
      result.states.push(state);
      result.maxStep = Math.max(result.maxStep, frame.applied);
      if (frame.handoff) {
        state = { ...state, phase: "handoff", armed: true };
        result.states.push(state);
        result.handoffFrame = index;
      }
      continue;
    }
    if (frame.total < state.total) {
      result.problem ??= `frame ${index}: the flow shrank from ${state.total} to ${frame.total} rows, which the model leaves out`;
      continue;
    }
    if (frame.total > state.total) {
      state = { ...state, total: frame.total, submits: state.submits + 1 };
      result.states.push(state);
    }
    const applied = tweak && frame.applied > 0 && scrolled === 0 ? tweak(frame.applied) : frame.applied;
    if (frame.applied > 0) scrolled += 1;
    state = { ...state, phase: "live", view: frame.view, area: frame.area, sb: addRange(state.sb, state.view, applied), mark: frame.mark, armed: false };
    result.states.push(state);
    result.maxArea = Math.max(result.maxArea, frame.area);
  }
  result.maxArea = Math.max(result.maxArea, area0);
  if (result.handoffFrame === null) result.problem ??= "the resume never handed over to the live flow";
  return result;
}

function toTla(value: unknown): string {
  if (Array.isArray(value)) return `<<${value.map(toTla).join(", ")}>>`;
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "number") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (value && typeof value === "object") {
    return `[${Object.entries(value as Record<string, unknown>).map(([k, v]) => `${k} |-> ${toTla(v)}`).join(", ")}]`;
  }
  throw new Error(`cannot print ${String(value)} as TLA+`);
}

export type Checked = { verdict: "pass" | "fail" | "error"; property: string | null; distinct: number | null; run: TlcRun };

/// TLC on one trace of the model, in its own folder.
async function checkTrace(dir: string, trace: ModelTrace): Promise<Checked> {
  mkdirSync(dir, { recursive: true });
  const cfg = readFileSync(join(MODEL_DIR, "TraceTranscriptScrollback.cfg"), "utf8")
    .replace(/PublishedRows = \d+/, `PublishedRows = ${trace.publishedRows}`)
    .replace(/MaxArea = \d+/, `MaxArea = ${trace.maxArea}`)
    .replace(/MaxStep = \d+/, `MaxStep = ${trace.maxStep}`);
  writeFileSync(join(dir, "TraceTranscriptScrollback.cfg"), cfg);
  writeFileSync(join(dir, "TraceData.tla"), [
    "---- MODULE TraceData ----",
    "EXTENDS Integers",
    `Traces == << <<${trace.states.map((state) => toTla(state)).join(",\n  ")}>> >>`,
    "====",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "TraceTranscriptScrollback", "TraceTranscriptScrollback.cfg", SPECS, MODEL_DIR);
  const verdict = run.exitCode === 0 && !run.violated ? "pass" : run.violated ? "fail" : "error";
  return { verdict, property: run.violated, distinct: run.distinctStates, run };
}

function seedText(rows: number): string {
  return Array.from({ length: rows }, (_, index) => `row ${String(index + 1).padStart(5, "0")}`).join("\n\n");
}

/// The rows the full scrollback shows, as numbers, and the turn rows in order.
export function shownRows(full: string): { rows: number[]; turn: string[] } {
  const rows = [...full.matchAll(/^\s*row (\d{5})\s*$/gm)].map((match) => Number(match[1]));
  const turn = [...full.matchAll(/TURN_ROW_\d/g)].map((match) => match[0]);
  return { rows, turn };
}

/// What is wrong with the scrollback, or null: the rows end at `rows`, each
/// appears once, in order with none missing, and the turn follows.
export function scrollbackProblem(full: string, rows: number): string | null {
  const shown = shownRows(full);
  if (shown.rows.length === 0) return "the scrollback shows no resumed row";
  const first = shown.rows[0]!;
  for (let i = 0; i < shown.rows.length; i += 1) {
    const want = first + i;
    if (shown.rows[i] !== want) {
      return `the scrollback shows row ${shown.rows[i]} where row ${want} belongs, after ${i} rows from row ${first}`;
    }
  }
  const last = shown.rows[shown.rows.length - 1]!;
  if (last !== rows) return `the scrollback ends at row ${last}, not row ${rows}`;
  if (JSON.stringify(shown.turn) !== JSON.stringify(TURN_ROWS)) return `the scrollback shows the turn as ${JSON.stringify(shown.turn)}`;
  return null;
}

/// Seeds a saved session through the fake gateway, resumes it in tmux, submits
/// a prompt as soon as the composer is up, and returns the trace log and the
/// full scrollback once the turn is done.
async function runScenario(bin: string, dir: string, rows: number, control: boolean) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-transcript-scrollback-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  const trace = join(dir, "fx-trace.log");
  let reply = seedText(rows);
  const gateway = startDynamicFakeGateway(async () => fakeGatewayFinalText(reply));
  const env: Record<string, string> = {
    HOME: home,
    FX_HOME: join(home, ".fx"),
    AI_GATEWAY_API_KEY: "fake-tla-transcript-scrollback",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "full-access",
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    NO_COLOR: "1",
  };
  let session: TmuxSession | null = null;
  try {
    // Async, because the fake gateway runs in this process and must answer.
    const seed = Bun.spawn([bin, "ask", "--json", "seed the saved session"], {
      cwd: workspace,
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin", ...env },
      stdin: "ignore",
      stdout: "ignore",
      stderr: "pipe",
    });
    const [seedCode, seedStderr] = await Promise.all([seed.exited, new Response(seed.stderr).text()]);
    if (seedCode !== 0) throw new Error(`fx ask exited ${seedCode}: ${seedStderr}`);
    const id = onlySessionId(home);
    reply = TURN_ROWS.join("\n\n");
    session = await TmuxSession.create({
      cmd: `${bin} --resume ${id}`,
      cwd: workspace,
      env: { ...env, FX_TRACE_LOG: trace, FX_TRACE_SCOPES: TRACE_SCOPES },
      // Tall enough that the transcript area holds a whole publication frame
      // (64 rows): the brief's 80x73.
      width: 80,
      height: 73,
      isolated: true,
      stderrPath: join(dir, "fx-resumed.stderr"),
    });
    // The composer is up while the resume still publishes the earlier rows.
    await session.waitForComposer(TIMEOUT);
    if (control) {
      await session.waitForText(`row ${String(rows).padStart(5, "0")}`, TIMEOUT);
      await session.waitForStableComposer(TIMEOUT, 500);
    }
    await session.sendText("hello");
    await session.waitForText(TURN_ROWS[TURN_ROWS.length - 1]!, TIMEOUT);
    await session.waitForStableComposer(TIMEOUT, 500);
    const full = await session.captureFullScrollback();
    await session.sendText("/quit");
    await session.waitForSessionEnd(TIMEOUT);
    return { log: existsSync(trace) ? readFileSync(trace, "utf8") : "", full };
  } finally {
    await session?.kill();
    gateway.stop();
  }
}

export type BinaryToSpecResult = {
  frames: number;
  states: number;
  /** Rows the first live frame added to the flow; 0 means the prompt came after publication. */
  handoffGrowth: number;
  shown: { rows: number; first: number | null; last: number | null };
  scrollback: string | null;
  tlc: { verdict: string; property: string | null; distinct: number | null } | null;
  planted: { name: string; verdict: string; property: string | null }[];
  problem: string | null;
};

export async function binaryToSpec(options: { bin: string; dir: string; rows: number; control?: boolean }): Promise<BinaryToSpecResult> {
  mkdirSync(options.dir, { recursive: true });
  const control = options.control ?? false;
  const { log, full } = await runScenario(options.bin, options.dir, options.rows, control);
  writeFileSync(join(options.dir, "scrollback.txt"), full);
  const shown = shownRows(full);
  const frames = parseFrames(log);
  const result: BinaryToSpecResult = {
    frames: frames.length,
    states: 0,
    handoffGrowth: 0,
    shown: { rows: shown.rows.length, first: shown.rows[0] ?? null, last: shown.rows[shown.rows.length - 1] ?? null },
    scrollback: scrollbackProblem(full, options.rows),
    tlc: null,
    planted: [],
    problem: null,
  };
  const trace = modelTrace(frames);
  result.states = trace.states.length;
  if (trace.problem) result.problem = trace.problem;
  const handoff = frames.findIndex((frame) => frame.handoff);
  if (handoff >= 0 && handoff + 1 < frames.length) result.handoffGrowth = frames[handoff + 1]!.total - frames[handoff]!.total;
  if (control) {
    if (result.handoffGrowth !== 0) result.problem ??= `the control run grew the flow by ${result.handoffGrowth} rows at the handoff`;
  } else if (result.handoffGrowth <= 0) {
    result.problem ??= "the prompt did not reach the first frame after the handoff: it came after the resume finished, so raise --rows";
  }
  if (result.problem) return result;

  const checked = await checkTrace(join(options.dir, "tlc"), trace);
  result.tlc = { verdict: checked.verdict, property: checked.property, distinct: checked.distinct };
  if (checked.verdict !== "pass") result.problem = `TLC: ${checked.verdict}${checked.property ? ` (${checked.property})` : ""}`;
  if (result.scrollback) result.problem ??= result.scrollback;
  if (checked.verdict !== "pass") return result;

  // The check must reject the defects it names: the same run with the first
  // live frame's scroll removed, and with one row too many.
  const planted: [string, (applied: number) => number][] = [
    ["no scroll at the first live frame that scrolls", () => 0],
    ["one row too many at the first live frame that scrolls", (applied) => applied + 1],
  ];
  for (const [name, tweak] of planted) {
    const mutated = await checkTrace(join(options.dir, `tlc-planted-${result.planted.length}`), modelTrace(frames, tweak));
    result.planted.push({ name, verdict: mutated.verdict, property: mutated.property });
    if (mutated.verdict !== "fail") result.problem ??= `TLC accepted a trace with ${name}`;
  }
  return result;
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const value = (flag: string) => {
    const at = args.indexOf(flag);
    return at >= 0 ? args[at + 1] : undefined;
  };
  const bin = value("--bin") ?? join(REPO_ROOT, "zig-out", "bin", "fx");
  const rows = Number(value("--rows") ?? "8000");
  const dir = join(outDir("transcript_scrollback"), "binary-to-spec");
  const result = await binaryToSpec({ bin, dir, rows, control: args.includes("--control") });
  writeJson(join(dir, "result.json"), result);
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.problem ? 1 : 0);
}
