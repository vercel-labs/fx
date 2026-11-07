// Runs the built fx composer in tmux along tests/tla/display_width/DisplayWidth.tla
// and has TLC check every walk it observes (DisplayWidthTrace.tla).
//
// Each walk starts by clearing the composer (End, then Ctrl+U) and sends one
// key at a time: a code point of one of the model's classes, Left, Right,
// Backspace, Home, or End. After every key the driver waits until the pane
// and the cursor stop changing, then records the cursor column tmux reports,
// counted from the first cell after "┃ ", and the class of every code point
// tmux shows on the composer's rows, with "gap" for a blank cell. TLC requires
// both to match the model, so a misplaced cursor, a gap, a mark left over
// from an earlier repaint, and a mark lost at the right margin each reject a
// walk. The edge walks come first: the P267 repro (กั้งabc, then ที่นี่ok),
// น้ำ, every Thai nonspacing mark on a base, the spacing Thai code points next
// to them, marks with no base, stacked marks, Thai mixed with a Latin mark and
// a wide character, and marks on a Thai, Latin, and wide character in the
// last column of a row. Seeded random walks follow.
//
// TLC replays the walks through the model's own actions under Rule "fixed".
// --self-check also replays them under Rule "today", fx before the change,
// which must reject them.
//
// fx runs with FX_SOUND=0, FX_DISABLE_KEYCHAIN=1, a temporary HOME and
// FX_HOME, a fake key, and a local fake gateway. The driver fails if fx sends
// that gateway a model request, since no prompt is ever submitted.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/display_width/driver.ts
//   bun tests/tla/drivers/display_width/driver.ts --self-check --random 30 --seed 7
//
// Exit codes: 0 every walk accepted (and the self-check rejected), 1 a walk
// the model rejects, 2 a toolchain or harness failure.
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, hashFile, targetHelpers } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Class = "base" | "mark" | "am" | "ascii" | "wide" | "latin_mark";
type Key = "clear" | "type" | "left" | "right" | "backspace" | "home" | "end";
type Send = { key: Key; text?: string; cls?: Class };
type Step = {
  key: Key;
  cls: Class | "none";
  col: number;
  row: Array<Class | "gap">;
  codepoint?: string;
  row_text: string;
};
type Walk = { id: string; steps: Step[] };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const PROMPT = "┃ ";
const PANE_WIDTH = 60;
// A column no cursor can have: the cursor left the composer's first row.
const OFF_ROW = 999;
const tlaDir = join(TLA_ROOT, "display_width");

// Thai's nonspacing marks (general category Mn).
const THAI_MARKS = [0x0e31, 0x0e34, 0x0e35, 0x0e36, 0x0e37, 0x0e38, 0x0e39, 0x0e3a,
  0x0e47, 0x0e48, 0x0e49, 0x0e4a, 0x0e4b, 0x0e4c, 0x0e4d, 0x0e4e];
// Spacing Thai: consonants, the spacing vowels next to the marks, lead
// vowels, MAIYAMOK, the baht sign, and FONGMAN.
const THAI_SPACING = [0x0e01, 0x0e02, 0x0e07, 0x0e17, 0x0e19, 0x0e2e, 0x0e30, 0x0e32,
  0x0e3f, 0x0e40, 0x0e44, 0x0e46, 0x0e4f];
const MEMBERS: Record<Class, number[]> = {
  base: THAI_SPACING,
  mark: THAI_MARKS,
  am: [0x0e33],
  ascii: [0x61, 0x62, 0x6b, 0x6f, 0x7a],
  wide: [0x754c, 0x6f22],
  latin_mark: [0x0300, 0x0301],
};

/// The abstraction function: the model's class of one code point.
function classOf(codepoint: number): Class {
  if (THAI_MARKS.includes(codepoint)) return "mark";
  if (codepoint === 0x0e33) return "am";
  if (codepoint >= 0x0e00 && codepoint <= 0x0e7f) return "base";
  if (codepoint >= 0x0300 && codepoint <= 0x036f) return "latin_mark";
  if (codepoint >= 0x20 && codepoint < 0x7f) return "ascii";
  return "wide";
}

function typed(text: string): Send[] {
  return Array.from(text, (ch) => ({ key: "type" as const, text: ch, cls: classOf(ch.codePointAt(0)!) }));
}

const keys = (...names: Key[]): Send[] => names.map((key) => ({ key }));

function edgeWalks(): Array<{ id: string; sends: Send[] }> {
  const walks: Array<{ id: string; sends: Send[] }> = [
    {
      id: "p267-repro",
      sends: [
        ...typed("\u0E01\u0E31\u0E49\u0E07abc"),
        ...typed("\u0E17\u0E35\u0E48\u0E19\u0E35\u0E48ok"),
        ...keys("left", "left", "left", "left", "end", "backspace", "backspace", "backspace"),
      ],
    },
    { id: "sara-am", sends: [...typed("\u0E19\u0E49\u0E33"), ...keys("left", "left", "right", "right", "backspace")] },
    { id: "bare-marks", sends: [...typed("\u0E49\u0E48a"), ...keys("home", "right", "right", "end", "backspace", "backspace")] },
    {
      id: "stacked",
      sends: [...typed("\u0E01\u0E38\u0E49\u0E4C\u0E4D\u0E4E\u0E07"), ...keys("left", "left", "right", "home", "right", "backspace")],
    },
    {
      id: "mixed",
      sends: [...typed("e\u0301\u754C\u0E01\u0E31a"), ...keys("left", "left", "left", "right", "right", "right", "backspace")],
    },
    { id: "spacing-neighbours", sends: [...typed("\u0E30\u0E32\u0E3F\u0E40\u0E44\u0E46\u0E4F\u0E2E"), ...keys("left", "backspace")] },
    // A character whose cell is the last one of the row, with marks on it:
    // "┃ " leaves 58 cells. Thai and Latin on a one-cell base, and a wide
    // base, which had the margin guard before. fx keeps the cursor on the
    // last cell when the text ends exactly at the margin, which a column
    // count cannot tell from the cursor before that cell, so each walk types
    // the character after the margin first and fills the row in front of it.
    {
      id: "margin-thai",
      sends: [
        ...typed("\u0E07"),
        ...keys("home"),
        ...typed(`${"a".repeat(57)}\u0E01\u0E31\u0E49`),
        ...keys("left", "left", "end"),
      ],
    },
    {
      id: "margin-latin",
      sends: [...typed("b"), ...keys("home"), ...typed(`${"a".repeat(57)}e\u0301`), ...keys("left", "end")],
    },
    {
      id: "margin-wide",
      sends: [...typed("b"), ...keys("home"), ...typed(`${"a".repeat(56)}\u754C\u0301`), ...keys("left", "end")],
    },
  ];
  for (let start = 0; start < THAI_MARKS.length; start += 4) {
    const marks = THAI_MARKS.slice(start, start + 4);
    walks.push({
      id: `marks-${marks[0]!.toString(16)}`,
      sends: [
        ...marks.flatMap((mark) => typed(`\u0E01${String.fromCodePoint(mark)}`)),
        ...keys("left", "left", "right", "backspace"),
      ],
    });
  }
  return walks;
}

function seededRandom(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// Seeded random walks of 12 keys. A walk types at most 14 code points, so
/// it stays on the composer's first row.
function randomWalks(seed: number, count: number): Array<{ id: string; sends: Send[] }> {
  const random = seededRandom(seed);
  const pick = <T>(items: T[]): T => items[Math.floor(random() * items.length)]!;
  const classes = Object.keys(MEMBERS) as Class[];
  const walks: Array<{ id: string; sends: Send[] }> = [];
  for (let index = 0; index < count; index += 1) {
    const sends: Send[] = [];
    let length = 0;
    for (let step = 0; step < 12; step += 1) {
      const roll = random();
      if (roll < 0.6 && length < 14) {
        const cls = pick(classes);
        sends.push({ key: "type", cls, text: String.fromCodePoint(pick(MEMBERS[cls])) });
        length += 1;
      } else {
        sends.push({ key: pick<Key>(["left", "right", "backspace", "home", "end"]) });
      }
    }
    walks.push({ id: `random-${seed}-${index}`, sends });
  }
  return walks;
}

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const TMUX_KEY: Record<Exclude<Key, "type" | "clear">, string> = {
  left: "Left",
  right: "Right",
  backspace: "BSpace",
  home: "Home",
  end: "End",
};

type Session = {
  sendKeys(keys: string): Promise<void>;
  sendLiteralText(text: string): Promise<void>;
  capturePaneGrid(): Promise<string[]>;
  cursorPosition(): { row: number; col: number };
  waitForComposer(timeoutMs?: number): Promise<string>;
  isAlive(): boolean;
  kill(): Promise<void>;
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/// The pane and cursor once neither has changed for `steadyMs`.
async function settled(session: Session, steadyMs = 200, timeoutMs = 10_000) {
  const started = Date.now();
  let last = "";
  let since = Date.now();
  while (Date.now() - started < timeoutMs) {
    const grid = await session.capturePaneGrid();
    const cursor = session.cursorPosition();
    const key = `${cursor.row}:${cursor.col}\n${grid.join("\n")}`;
    if (key !== last) {
      last = key;
      since = Date.now();
    } else if (Date.now() - since >= steadyMs) {
      return { grid, cursor };
    }
    await sleep(20);
  }
  throw new Error("the pane did not settle");
}

/// The classes of the code points tmux shows after the composer's prefix.
function rowClasses(rowText: string): Array<Class | "gap"> {
  // The row is trimmed, so an empty composer row reads as the bar alone.
  if (rowText === PROMPT.trimEnd()) return [];
  if (!rowText.startsWith(PROMPT)) return ["gap"];
  return Array.from(rowText.slice(PROMPT.length), (ch) => (ch === " " ? "gap" : classOf(ch.codePointAt(0)!)));
}

/// The cells a composer row's text takes after the prefix, by the
/// terminal's width of each class (DisplayWidth.tla TermWidth).
function rowCells(rowText: string): number {
  return rowClasses(rowText).reduce(
    (sum, cls) => sum + (cls === "mark" || cls === "latin_mark" ? 0 : cls === "wide" ? 2 : 1),
    0,
  );
}

/// The composer's rows: every pane row that starts with the bar. Nothing is
/// sent, so the transcript above holds no such row.
function composerRows(grid: string[]): number[] {
  return grid.flatMap((line, index) => (line.startsWith(PROMPT.trimEnd()) ? [index] : []));
}

async function runWalks(session: Session, walks: Array<{ id: string; sends: Send[] }>): Promise<Walk[]> {
  const observed: Walk[] = [];
  for (const walk of walks) {
    const steps: Step[] = [];
    for (const send of [{ key: "clear" as const }, ...walk.sends]) {
      if (send.key === "clear") {
        await session.sendKeys("End");
        await session.sendKeys("C-u");
      } else if (send.key === "type") {
        await session.sendLiteralText(send.text!);
      } else {
        await session.sendKeys(TMUX_KEY[send.key]);
      }
      const { grid, cursor } = await settled(session);
      const rows = composerRows(grid).map((index) => ({ index, text: grid[index]!.trimEnd() }));
      // The cursor's column counted across rows: the cells of the rows above
      // it, then its place in its own row.
      const at = rows.findIndex((row) => row.index === cursor.row);
      const col = at < 0
        ? OFF_ROW
        : rows.slice(0, at).reduce((sum, row) => sum + rowCells(row.text), 0) + cursor.col - PROMPT.length;
      steps.push({
        key: send.key,
        cls: send.cls ?? "none",
        col,
        row: rows.flatMap((row) => rowClasses(row.text)),
        ...(send.text ? { codepoint: `U+${send.text.codePointAt(0)!.toString(16).toUpperCase().padStart(4, "0")}` } : {}),
        row_text: rows.map((row) => row.text).join("\n"),
      });
    }
    observed.push({ id: walk.id, steps });
    if (!session.isAlive()) throw new Error(`fx exited during walk ${walk.id}`);
  }
  return observed;
}

function observedModule(walks: Walk[]): string {
  const row = (s: Step) => `<<${s.row.map((cls) => `"${cls}"`).join(", ")}>>`;
  const step = (s: Step) => `[key |-> "${s.key}", cls |-> "${s.cls}", col |-> ${s.col}, row |-> ${row(s)}]`;
  const walk = (w: Walk) => `<< ${w.steps.map(step).join(", ")} >>`;
  return [
    "------------------------ MODULE DisplayWidthObserved ------------------------",
    `\\* Generated by tests/tla/drivers/display_width/driver.ts from ${walks.length} walks.`,
    `Observed == << ${walks.map(walk).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function judge(dir: string, walks: Walk[], rule: "fixed" | "today") {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "DisplayWidthObserved.tla"), observedModule(walks));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `    Rule = "${rule}"`,
    "    MaxLen = 0",
    `    Cols = ${PANE_WIDTH - PROMPT.length}`,
    `    Margin = "${rule === "fixed" ? "fixed" : "row-drops"}"`,
    "INVARIANT NotAllMatched",
    "",
  ].join("\n"));
  // A step the model cannot take leaves no successor; -deadlock makes that a
  // completed search (REJECTED) instead of an error.
  const run = await runTlc(dir, "DisplayWidthTrace", "trace.cfg", ["DisplayWidth.tla", "DisplayWidthTrace.tla"], tlaDir, ["-deadlock"]);
  const verdict: Verdict = run.exitCode === 12 && run.violated === "NotAllMatched"
    ? "ACCEPTED"
    : run.exitCode === 0 && run.output.includes("No error has been found")
      ? "REJECTED"
      : "TOOL_ERROR";
  return { verdict, distinctStates: run.distinctStates, durationMs: run.durationMs, dir };
}

/// When TLC rejects the run, it judges each walk alone, so the report names
/// the walks the model cannot produce.
async function rejectedWalks(dir: string, walks: Walk[]): Promise<string[]> {
  const rejected: string[] = [];
  for (const [index, walk] of walks.entries()) {
    const alone = await judge(join(dir, `walk-${index + 1}`), [walk], "fixed");
    if (alone.verdict !== "ACCEPTED") rejected.push(walk.id);
  }
  return rejected;
}

async function main(): Promise<number> {
  const selfCheck = process.argv.includes("--self-check");
  const seed = option("--seed", 1);
  const randomCount = option("--random", 20);
  const out = outDir("display-width");
  const helpers = await targetHelpers();
  const gateway = helpers.startFakeGateway([]);
  const home = mkdtempSync(join(tmpdir(), "fx-tla-display-width-"));
  const fxHome = join(home, "fx");
  mkdirSync(fxHome, { recursive: true });
  writeFileSync(join(fxHome, "settings.json"), JSON.stringify({ sandbox: "none" }));
  const stderrPath = join(out, "fx-stderr.log");
  writeFileSync(stderrPath, "");
  let session: Session | null = null;
  try {
    session = await helpers.TmuxSession.create({
      cmd: binary,
      env: {
        HOME: home,
        FX_HOME: fxHome,
        FX_SOUND: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        AI_GATEWAY_API_KEY: "fake-display-width-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
      },
      width: PANE_WIDTH,
      height: 24,
      stderrPath,
      isolated: true,
    });
    await session.waitForComposer(15_000);
    const walks = [...edgeWalks(), ...randomWalks(seed, randomCount)];
    const observed = await runWalks(session, walks);
    const steps = observed.reduce((sum, walk) => sum + walk.steps.length, 0);
    const fixed = await judge(join(out, "tlc-fixed"), observed, "fixed");
    const today = selfCheck ? await judge(join(out, "tlc-today"), observed, "today") : null;
    const requests = {
      chat: gateway.requests.length,
      title: gateway.titleRequests.length,
      classifier: gateway.classifierRequests.length,
      models: gateway.modelRequests.length,
    };
    const rejected = fixed.verdict === "REJECTED" ? await rejectedWalks(join(out, "tlc-walks"), observed) : [];
    const report = {
      binary,
      binary_sha256: hashFile(binary),
      seed,
      walks: observed.length,
      steps,
      gateway_requests: requests,
      verdict: fixed.verdict,
      tlc_distinct_states: fixed.distinctStates,
      tlc_ms: fixed.durationMs,
      self_check: today ? { rule: "today", verdict: today.verdict, distinct_states: today.distinctStates } : null,
      rejected_walks: rejected,
      observed,
    };
    writeJson(join(out, "report.json"), report);
    console.log(`binary ${binary} sha256 ${report.binary_sha256}`);
    console.log(`walks ${observed.length}, steps ${steps}, seed ${seed}`);
    console.log(`fake gateway requests: chat ${requests.chat}, title ${requests.title}, classifier ${requests.classifier}, models ${requests.models}`);
    console.log(`TLC (Rule "fixed"): ${fixed.verdict}, ${fixed.distinctStates} distinct states, ${fixed.durationMs} ms`);
    if (today) console.log(`TLC self-check (Rule "today"): ${today.verdict}, ${today.distinctStates} distinct states`);
    if (rejected.length > 0) {
      console.log(`walks TLC rejects alone (${rejected.length} of ${observed.length}): ${rejected.join(", ")}`);
      const first = observed.find((walk) => walk.id === rejected[0])!;
      for (const step of first.steps) {
        console.log(`  ${first.id} ${step.key}${step.codepoint ? ` ${step.codepoint}` : ""}: col ${step.col}, row ${JSON.stringify(step.row_text)}`);
      }
    }
    console.log(`report ${join(out, "report.json")}`);

    if (fixed.verdict === "TOOL_ERROR" || today?.verdict === "TOOL_ERROR") return 2;
    if (requests.chat !== 0) {
      console.log(`FAIL: fx sent ${requests.chat} model requests to the fake gateway; none were expected`);
      return 1;
    }
    if (fixed.verdict !== "ACCEPTED") return 1;
    if (today && today.verdict !== "REJECTED") {
      console.log("FAIL: the model of fx before the change accepted the walks, so they do not test the marks");
      return 1;
    }
    return 0;
  } finally {
    await session?.kill();
    gateway.stop();
    rmSync(home, { recursive: true, force: true });
  }
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.error(error instanceof Error ? error.stack ?? error.message : error);
    process.exit(2);
  },
);
