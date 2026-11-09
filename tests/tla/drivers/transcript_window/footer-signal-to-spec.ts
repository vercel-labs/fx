// Footer signal, built binary to spec: runs the built fx in a private tmux
// server, with a footer surface open over a long transcript, and ends it with
// a real SIGTERM or SIGHUP. After each step it counts what the terminal holds
// of the transcript: the rows in native history (above the screen) and the
// rows on the screen. Those counts are the model's `hist` and `top`
// (FooterReclaim.tla), so each run becomes a trace (Init, Output, Opened, then
// SigTerm or SigHup) that TLC checks against TraceFooterReclaim.tla:
// ConformsToSpec for every step, and the laws, ExitKeepsRows among them, on
// the states the binary produced. The run also fails when a transcript row is
// in history and on the screen, or twice anywhere.
//
// Four kinds of run, by what covers the main screen at the signal:
//   picker          the slash picker is open on the main screen;
//   resize-picker   the slash picker is open and the window is resized (wider,
//                   as tall) a few milliseconds before the signal, so the
//                   resize debounce is still pending when the signal arrives
//                   and no frame can commit until the close ends it;
//   ctrl-o-resize   the picker is open, Ctrl+O's full transcript screen covers
//                   it, and the window is resized (narrower, as tall) before
//                   the signal: CoveredResize, then the signal;
//   review-screen   a command approval is open inline, and a narrower window
//                   leaves it no room, so it moves to the approval review
//                   screen: ReviewResize, then the signal.
// After a covered resize the anchor is invalid and no frame recovers it before
// the signal, so the exit frame must release the rows from an invalid anchor
// (the log of the run must show the anchor invalidated after the resize). After
// a resize-picker resize the close must end the debounce and draw the frame
// (the log of the run must show the close waiting for the resize in flight).
//
// footer-runtime-to-spec.ts checks the transcript runtime's settle in process.
// This one checks what ends fx: the closer thread that handles the signal must
// get the main thread's exit frame drawn before it restores the terminal
// (`closerMain` in src/core/app/app_lifecycle.zig). It fails on a build that
// restores at once, which leaves the held rows out of scrollback.
//
// Counting is by marker text, so every transcript row of the reply carries a
// numbered marker. Rows before the first marker (the header and the prompt)
// are always in history, and the trailing rows after the last marker (a
// blank line, the turn summary, a blank line) are counted from the idle
// screen. Rows then count from the first marker, which only shifts the
// model's row numbers.
//
// Run alone: bun footer-signal-to-spec.ts [--bin PATH] [--rows N [--signal SIGHUP] [--kind picker|ctrl-o-resize|review-screen|resize-picker] [--delay MS]]
// (--rows runs one scenario with an N-row transcript, for a stress run; --delay
// is how many milliseconds a resize-picker signal follows the resize)
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fxBin, outDir } from "../lib/tlc.ts";
import { TmuxSession, fakeGatewayFinalText, fakeGatewayToolCall, isComposerLine, startFakeGateway } from "../../../e2e/tmux-helpers.ts";
import { checkTlc, specFiles, toTla, type CheckedTlc } from "./lib.ts";

const TIMEOUT = 30_000;
const COLS = 100;
const SCREEN_ROWS = 24;
/// The width a covered resize narrows the window to. The marker lines of the
/// covered runs are short enough to stay one row at every width used, so the
/// resize leaves the transcript's visual rows as they were.
const COVERED_COLS = { "ctrl-o-resize": 80, "review-screen": 40 } as const;
/// The width a resize-picker run widens the window to: the marker lines stay
/// one row, and the screen keeps its height.
const WIDE_COLS = 120;
/// A command that fits an inline approval at COLS wide but needs the approval
/// review screen at COVERED_COLS["review-screen"] wide.
const LONG_COMMAND = `echo ${"scrollback-accounting-".repeat(6)}done`;

export type SignalKind = "picker" | "ctrl-o-resize" | "review-screen" | "resize-picker";
export type SignalScenario = { name: string; rows: number; signal: "SIGTERM" | "SIGHUP"; kind?: SignalKind; delayMs?: number };

/// Every scenario has a transcript longer than the screen, so the idle and
/// the open footer both see a full screen above them.
export const SIGNAL_SCENARIOS: SignalScenario[] = [
  { name: "SIGTERM with the picker open, 41 rows", rows: 41, signal: "SIGTERM" },
  { name: "SIGHUP with the picker open, 82 rows", rows: 82, signal: "SIGHUP" },
  { name: "SIGTERM with the picker open, 82 rows", rows: 82, signal: "SIGTERM" },
  { name: "SIGHUP with the picker open, 200 rows", rows: 200, signal: "SIGHUP" },
  { name: "SIGTERM with the picker open, 200 rows", rows: 200, signal: "SIGTERM" },
  { name: "SIGTERM after Ctrl+O and a resize over the picker, 82 rows", rows: 82, signal: "SIGTERM", kind: "ctrl-o-resize" },
  { name: "SIGHUP after Ctrl+O and a resize over the picker, 82 rows", rows: 82, signal: "SIGHUP", kind: "ctrl-o-resize" },
  { name: "SIGTERM after the approval moved to the review screen, 82 rows", rows: 82, signal: "SIGTERM", kind: "review-screen" },
  { name: "SIGHUP after the approval moved to the review screen, 82 rows", rows: 82, signal: "SIGHUP", kind: "review-screen" },
  { name: "SIGTERM right after a resize with the picker open, 82 rows", rows: 82, signal: "SIGTERM", kind: "resize-picker" },
  { name: "SIGHUP right after a resize with the picker open, 82 rows", rows: 82, signal: "SIGHUP", kind: "resize-picker" },
  { name: "SIGTERM 50 ms after a resize with the picker open, 82 rows", rows: 82, signal: "SIGTERM", kind: "resize-picker", delayMs: 50 },
];

type State = { rows: number; hist: number; top: number; open: boolean; exited: boolean; resizes: number; anchor: string; act: string };
type Seen = { hist: number; top: number; tail: number; problems: string[] };

export type SignalResult = {
  scenarios: number;
  steps: number;
  tlc: CheckedTlc | null;
  /// What the run saw that no model law covers, or why it could not run.
  problems: string[];
};

const marker = (row: number) => `SIGNAL_FOOTER_ROW_${String(row + 1).padStart(3, "0")}`;
const SHORT_FILLER = "scrollback row";
/// What counts a row: its marker and the space after it, so ROW_100 is not
/// found in ROW_1000.
const needle = (row: number) => `${marker(row)} `;
const replyText = (rows: number, filler = "marker line of filler text for scrollback accounting.") =>
  Array.from({ length: rows }, (_, row) => `${marker(row)} ${filler}`).join("\n");
const count = (text: string, needle: string) => text.split(needle).length - 1;

/// The model's `hist` and `top` in marker rows, from the visible screen and
/// the full scrollback (history plus screen), and the rows between the last
/// marker and the footer on the screen: the composer line, or the line above
/// an open approval's header.
function see(visible: string, full: string, rows: number, approval = false): Seen {
  const problems: string[] = [];
  const inHistory: number[] = [];
  const onScreen: number[] = [];
  for (let row = 0; row < rows; row += 1) {
    const shown = count(visible, needle(row));
    const kept = count(full, needle(row)) - shown;
    if (shown > 1 || kept > 1 || (shown > 0 && kept > 0)) {
      problems.push(`${marker(row)} is in history ${kept} times and on the screen ${shown} times`);
    }
    if (kept > 0) inHistory.push(row);
    if (shown > 0) onScreen.push(row);
  }
  if (inHistory.some((row, at) => row !== at)) problems.push(`the rows in history are not the first ${inHistory.length}`);
  if (onScreen.some((row, at) => row !== rows - onScreen.length + at)) problems.push(`the rows on the screen are not the last ${onScreen.length}`);
  const lines = visible.split("\n");
  const lastMarker = lines.findLastIndex((line) => line.includes("SIGNAL_FOOTER_ROW_"));
  const composer = approval ? lines.findLastIndex((line) => line.includes("Permission needed")) : lines.findLastIndex((line) => isComposerLine(line));
  const tail = lastMarker >= 0 && composer > lastMarker ? composer - lastMarker - 1 : -1;
  return { hist: inHistory.length, top: rows - onScreen.length, tail, problems };
}

/// The pane once five captures 50 ms apart agree and no turn runs.
async function stablePane(session: TmuxSession, what: string): Promise<void> {
  const deadline = Date.now() + 10_000;
  let previous = "";
  let same = 0;
  while (Date.now() < deadline) {
    const pane = await session.capturePane();
    const busy = pane.includes("esc interrupt") || pane.includes("Thinking");
    same = pane === previous && !busy ? same + 1 : 0;
    previous = pane;
    if (same >= 5) return;
    await Bun.sleep(50);
  }
  throw new Error(`the pane never settled: ${what}`);
}

async function observe(session: TmuxSession, rows: number, dir: string, label: string, approval = false): Promise<Seen> {
  const visible = await session.capturePane();
  const full = await session.captureFullScrollback();
  writeFileSync(join(dir, `${label}.pane.txt`), visible);
  writeFileSync(join(dir, `${label}.scrollback.txt`), full);
  return see(visible, full, rows, approval);
}

/// How often the fx trace log of the run says the transcript anchor was
/// invalidated.
const invalidations = (tracePath: string) =>
  (existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "").split("\n").filter((line) => line.includes("transcript_anchor_invalidate")).length;

type Run = { scenario: SignalScenario; states: State[]; baseCap: number; extra: number; maxResizes: number; problems: string[] };

async function runScenario(scenario: SignalScenario, bin: string, dir: string): Promise<Run> {
  mkdirSync(dir, { recursive: true });
  const kind = scenario.kind ?? "picker";
  const covered = kind === "ctrl-o-resize" || kind === "review-screen";
  const work = mkdtempSync(join(tmpdir(), "fx-footer-signal-"));
  const home = join(work, "home");
  const workspace = join(work, "workspace");
  const tracePath = join(work, "trace.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  const reply = replyText(scenario.rows, covered ? SHORT_FILLER : undefined);
  const gateway = startFakeGateway(
    kind === "review-screen"
      ? [fakeGatewayFinalText(reply), fakeGatewayToolCall("signal_footer_shell", "shell", { request: { yield_time_ms: 30_000, action: "run", command: LONG_COMMAND } })]
      : [fakeGatewayFinalText(reply)],
  );
  const socketName = `fx-footer-signal-${process.pid}-${Date.now()}`;
  let session: TmuxSession | null = null;
  try {
    session = await TmuxSession.create({
      cmd: bin,
      cwd: workspace,
      env: {
        HOME: home,
        FX_HOME: join(home, ".fx"),
        AI_GATEWAY_API_KEY: "fake-footer-signal-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: "openai/gpt-5",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FX_DISABLE_KEYCHAIN: "1",
        NO_COLOR: "1",
        FX_PERMISSION_MODE: "ask",
        FX_TRACE: "1",
        FX_TRACE_LOG: tracePath,
        FX_TRACE_SCOPES: "app,render,scroll,resize",
      },
      stderrPath: join(work, "stderr.log"),
      width: COLS,
      height: SCREEN_ROWS,
      isolated: true,
      socketName,
      remainOnExit: true,
      minimumHistoryLines: scenario.rows + 600,
    });
    // tmux writes a "Pane is dead" line under a dead pane, which scrolls a full
    // screen by one row. That row is not fx's, so the driver turns the line off.
    execFileSync("tmux", ["-L", socketName, "set-option", "-w", "-t", `${session.name}:0`, "remain-on-exit-format", ""], { stdio: "pipe" });
    await session.waitForComposer(10_000);
    await session.sendText("Print the signal footer fixture.");
    await session.waitForText(marker(scenario.rows - 1), TIMEOUT);
    await stablePane(session, "after the reply");
    const idle = await observe(session, scenario.rows, dir, "idle");
    const problems = [...idle.problems];
    let open: Seen;
    if (kind === "review-screen") {
      await session.sendText("Request the approval fixture.");
      await session.waitForText("Would you like to run the following command?", TIMEOUT);
      await stablePane(session, "with the approval open");
      open = await observe(session, scenario.rows, dir, "open", true);
    } else {
      await session.sendLiteralText("/");
      await session.waitForText("Commands", 5_000);
      await stablePane(session, "with the picker open");
      open = await observe(session, scenario.rows, dir, "open");
    }
    problems.push(...open.problems);

    // What covers the main screen, and the resize that follows. A resize-picker
    // run resizes with nothing covering the screen and signals at once.
    const invalidatedBefore = invalidations(tracePath);
    if (kind === "ctrl-o-resize") {
      await session.sendKeys("C-o");
      await session.waitForText("esc close · pgup/pgdn scroll", 10_000);
    }
    if (covered) {
      await session.resizeWindow(COVERED_COLS[kind], SCREEN_ROWS);
      if (kind === "review-screen") await session.waitForText("Permission needed", 15_000);
      await Bun.sleep(1_000);
    }
    const pid = session.processPid();
    if (kind === "resize-picker") await session.resizeWindow(WIDE_COLS, SCREEN_ROWS, scenario.delayMs ?? 0);
    process.kill(pid, scenario.signal);
    await session.waitForPane(() => session!.paneStatus().dead, 10_000);
    const ended = await observe(session, scenario.rows, dir, "ended");
    problems.push(...ended.problems);
    if (covered && invalidations(tracePath) <= invalidatedBefore) {
      problems.push("the fx log shows no anchor invalidated after the resize, so the run did not leave the anchor invalid");
    }
    const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
    if (kind === "resize-picker" && !trace.includes("event=signal_close_resize_wait")) {
      problems.push("the fx log shows no resize in flight when the signal closed fx, so the run did not cover the resize debounce");
    }
    if (kind === "resize-picker" && !trace.includes("debounce_skipped reason=close")) {
      problems.push("the fx log shows the close did not end the resize debounce");
    }
    if (!trace.includes("event=signal_close_settle") || /held_rows_settle_(failed|incomplete)|signal_close_settle_unconfirmed/.test(trace)) {
      problems.push("the fx log of the signal close does not show a settled exit frame");
    }

    const problemsOf = problems.map((problem) => `${scenario.name}: ${problem}`);
    // The rows after the last marker are those of the idle screen, with the
    // picker open, and, after an approval, those of the screen it left.
    const tailAfter = kind === "review-screen" ? ended.tail : idle.tail;
    if (idle.tail < 0 || ended.tail < 0 || (kind !== "review-screen" && idle.tail !== open.tail)) {
      problemsOf.push(`${scenario.name}: the rows after the last marker are ${idle.tail} idle, ${open.tail} with the surface open, and ${ended.tail} at the end`);
    }
    const tail = Math.max(0, idle.tail);
    const idleRows = scenario.rows + tail;
    const total = scenario.rows + Math.max(0, tailAfter);
    const act = scenario.signal === "SIGTERM" ? "SigTerm" : "SigHup";
    const state = (seen: Seen, rows: number, fields: Partial<State>): State => ({ rows, hist: seen.hist, top: seen.top, open: false, exited: false, resizes: 0, anchor: "stable", act: "", ...fields });
    const baseCap = scenario.rows - idle.top + tail;
    const states: State[] = [
      { rows: 0, hist: 0, top: 0, open: false, exited: false, resizes: 0, anchor: "invalid", act: "Init" },
      state(idle, idleRows, { act: "Output" }),
      state(open, total, { open: true, act: "Opened" }),
    ];
    if (covered) {
      const surfaceLeaves = kind === "review-screen";
      // No frame draws on the main screen, so history and the screen are as
      // they were when the surface opened.
      states.push(state(open, total, { open: !surfaceLeaves, resizes: 1, anchor: "invalid", act: surfaceLeaves ? "ReviewResize" : "CoveredResize" }));
    }
    states.push(state(ended, total, { open: kind !== "review-screen", exited: true, resizes: covered ? 1 : 0, anchor: "stable", act }));
    // The rows the screen showed above the open footer: with the approval they
    // are the rows between the idle tail and the approval, which `total` holds.
    const extra = baseCap - (total - open.top);
    return { scenario, states, baseCap, extra, maxResizes: covered ? 1 : 0, problems: problemsOf };
  } finally {
    await session?.kill();
    gateway.stop();
    rmSync(work, { recursive: true, force: true });
  }
}

/// `bin` is the fx under test. A run that cannot happen (no tmux, a screen
/// that never settles) is a problem, not a pass.
export async function footerSignalToSpec(options: { dir: string; bin: string; scenarios?: SignalScenario[] }): Promise<SignalResult> {
  mkdirSync(options.dir, { recursive: true });
  const scenarios = options.scenarios ?? SIGNAL_SCENARIOS;
  const problems: string[] = [];
  let steps = 0;
  let tlc: CheckedTlc | null = null;
  for (const [index, scenario] of scenarios.entries()) {
    let run: Run;
    try {
      run = await runScenario(scenario, options.bin, join(options.dir, `run-${index + 1}`));
    } catch (error) {
      problems.push(`${scenario.name}: ${error instanceof Error ? error.message : String(error)}`);
      continue;
    }
    problems.push(...run.problems);
    steps += run.states.length - 1;
    if (run.baseCap <= 0 || run.extra <= 0 || run.extra >= run.baseCap) {
      problems.push(`${scenario.name}: the screen showed ${run.baseCap} rows above the idle footer and ${run.extra} more with the picker open`);
      continue;
    }
    const total = Math.max(...run.states.map((state) => state.rows));
    const files = specFiles();
    const data = [
      "---- MODULE FooterTraceData ----",
      "EXTENDS Integers",
      "Traces == <<",
      `  \\* ${scenario.name}\n  <<${run.states.map((state) => toTla(state)).join(",\n   ")}>>`,
      ">>",
      "====",
      "",
    ].join("\n");
    const cfgText = files["TraceFooterReclaim.cfg"]!.replace(
      /CONSTANTS\n[\s\S]*?\nSPECIFICATION/,
      `CONSTANTS\n    MaxRows = ${total}\n    Burst = ${total}\n    BaseCap = ${run.baseCap}\n    Extra = ${run.extra}\n    MaxResizes = ${run.maxResizes}\n    Release = "base"\n    SignalExits = "settle"\nSPECIFICATION`,
    );
    const checked = await checkTlc(join(options.dir, `run-${index + 1}`, "tlc"), "TraceFooterReclaim", "TraceFooterReclaim.cfg", {
      ...files,
      "TraceFooterReclaim.cfg": cfgText,
      "FooterTraceData.tla": data,
    });
    if (tlc === null || checked.verdict !== "pass") tlc = checked;
    if (checked.verdict !== "pass") problems.push(`${scenario.name}: TLC ${checked.verdict}${checked.property ? ` (${checked.property})` : ""}`);
  }
  return { scenarios: scenarios.length, steps, tlc, problems };
}

if (import.meta.main) {
  const argument = (name: string) => {
    const at = process.argv.indexOf(name);
    return at >= 0 ? process.argv[at + 1] : undefined;
  };
  const bin = argument("--bin") ?? fxBin();
  const rows = argument("--rows");
  const signal = argument("--signal") === "SIGHUP" ? "SIGHUP" : "SIGTERM";
  const kind = (argument("--kind") ?? "picker") as SignalKind;
  const delay = argument("--delay");
  const scenarios =
    rows === undefined
      ? undefined
      : [{ name: `${signal} with the ${kind} scenario, ${rows} rows`, rows: Number(rows), signal, kind, ...(delay === undefined ? {} : { delayMs: Number(delay) }) } as SignalScenario];
  const result = await footerSignalToSpec({ dir: join(outDir("footer-signal"), "signal"), bin, scenarios });
  const ok = result.tlc?.verdict === "pass" && result.problems.length === 0;
  console.log(
    `${ok ? "PASS" : "FAIL"} footer signal to spec: ${result.scenarios} runs of the built binary, ${result.steps} steps; ` +
      `TLC ${result.tlc?.verdict ?? "not run"}${result.tlc?.property ? ` (${result.tlc.property})` : ""}${result.problems.length ? `; ${result.problems.join("; ")}` : ""}`,
  );
  process.exit(ok ? 0 : 1);
}
