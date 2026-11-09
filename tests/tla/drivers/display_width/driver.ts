// Runs the built fx composer in tmux along tests/tla/display_width/DisplayWidth.tla
// and has TLC check every walk it observes (DisplayWidthTrace.tla).
//
// Each walk starts by clearing the composer (End, then Ctrl+U) and sends one
// key at a time: a code point of one of the model's classes, a run of them
// sent together, Left, Right, Backspace, Home, or End. After every key the
// driver waits until the pane and the cursor stop changing, then records the
// cursor column tmux reports, counted from the first cell after "┃ ", and the
// class of every code point tmux shows on the composer's rows, with "gap" for
// a blank cell and "circle" for the dotted circle. TLC requires both to match
// the model, and fx to still be running, so a misplaced cursor, a gap, a mark
// left over from an earlier repaint, a mark lost at the right margin, a mark
// with no base left on the prompt's cell, and a cell that fails the step each
// reject a walk. The edge walks come first: the P267 repro (กั้งabc, then
// ที่นี่ok), น้ำ, every Thai nonspacing mark on a base, the spacing Thai code
// points next to them, marks with no base, one and 22 stacked on a base or
// on the circle, a mark with no base after a zero-width space (a mark that
// starts its row, whatever zero-width characters come before it, is bare, and
// one after a base is not), a mark typed in
// front of text that is already there, Thai mixed with a Latin mark and a
// wide character, and marks on a Thai, Latin, and wide character in the last
// column of a row. Seeded random walks follow.
//
// A second session is two columns wide, where the composer row has no content
// cells (Cols 0 in the model). Its walks type the same kinds of text, among
// them 12 Thai clusters, 72 bytes of text and 24 marks, which is past the 64
// bytes a terminal cell holds. The row must stay the bar alone and fx must
// stay alive, and TLC checks that against the model with Cols 0. fx clamps the
// cursor to the window's last column there, so no cursor column is compared.
// --narrow N sets the number of seeded random walks in that session, and
// --only W runs just the pane W columns wide (60 or 2).
//
// TLC replays the walks through the model's own actions under the change
// (FIXED). --self-check also replays the 60-column walks under four models
// of fx before it, each of which must reject them: Rule "today", Thai marks
// that measure one cell, Bare "joins-prefix", a mark with no base left on the
// prompt's cell, Bare "first-unit", this change before its repair, which drew
// only the first unit of a draft on a circle, so a mark after a zero-width
// space joined the prompt's cell, and Limit "refuse", a cell with no room
// that fails the step.
// The 2-column walks are replayed under Margin "cell-less-keeps", a row
// builder that puts the marks of undrawn characters on the prefix cell, which
// must reject them too. The model's cell limit is fx's 64 bytes (CELL_BYTES),
// and a run of marks on one cell is compared up to VIEW_MARKS of them, since
// tmux keeps fewer than fx draws; fx's exact count is read through fx replay in
// tests/e2e/tui-input-navigation.test.ts.
//
// fx runs with FX_SOUND=0, FX_DISABLE_KEYCHAIN=1, a temporary HOME and
// FX_HOME, a fake key, and a local fake gateway. The driver fails if fx sends
// that gateway a model request, since no prompt is ever submitted.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/display_width/driver.ts
//   bun tests/tla/drivers/display_width/driver.ts --self-check --random 30 --seed 7
//   bun tests/tla/drivers/display_width/driver.ts --self-check --only 2 --narrow 30 --seed 7
//
// Exit codes: 0 every walk accepted (and the self-check rejected), 1 a walk
// the model rejects or fx exiting during a walk, 2 a toolchain or harness
// failure.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, hashFile, targetHelpers } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Class = "base" | "mark" | "am" | "ascii" | "wide" | "latin_mark" | "zw";
// What one cell of the composer's rows shows: a class, a blank cell, or the
// dotted circle fx draws under a mark with no base.
type Seen = Class | "gap" | "circle";
type Key = "clear" | "type" | "type_run" | "left" | "right" | "backspace" | "home" | "end";
type Send = { key: Key; text?: string; cls?: Class; n?: number };
type Step = {
  key: Key;
  cls: Class | "none";
  n: number;
  col: number;
  row: Seen[];
  codepoint?: string;
  row_text: string;
};
type Walk = { id: string; steps: Step[] };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const PROMPT = "┃ ";
// What fx draws under a nonspacing mark that has no base character before it.
const DOTTED_CIRCLE = "\u25cc";
const PANE_WIDTH = 60;
// Two columns leave no content cells after the prompt.
const NARROW_WIDTH = 2;
// The cursor column of a step when the pane has no column to compare.
const NO_COLUMN = -1;
// A column no cursor can have: the cursor left the composer's first row.
const OFF_ROW = 999;
// fx's limit of text on one cell, in bytes. tmux, which the driver reads, keeps
// fewer marks on a cell than fx draws and not always the same number (nine and
// ten were seen), so the trace compares a run of marks only up to VIEW_MARKS
// of them. fx's exact count is read through fx replay in
// tests/e2e/tui-input-navigation.test.ts.
const CELL_BYTES = 64;
const VIEW_MARKS = 6;
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
  // A zero-width character that is not a mark. The walks use the zero-width
  // space: tmux, which the driver reads, shows the other two by its own rules
  // (it drops a lone byte order mark, and it puts the character after a joiner
  // on the joiner's cell), so the Zig tests cover the byte order mark and the
  // joiner.
  zw: [0x200b],
};

/// The abstraction function: the model's class of one code point.
function classOf(codepoint: number): Class {
  if (codepoint === 0x200b || codepoint === 0x200d || codepoint === 0xfeff) return "zw";
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

/// `n` copies of the code point `text`, sent together as one step.
function run(text: string, n: number): Send[] {
  return [{ key: "type_run", text: text.repeat(n), cls: classOf(text.codePointAt(0)!), n }];
}

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
    // A mark with no base is drawn on a dotted circle in a cell of its own,
    // and the marks after it stack on the circle: one cell, one cursor stop.
    { id: "bare-marks", sends: [...typed("\u0E49\u0E48a"), ...keys("home", "right", "right", "end", "backspace", "backspace")] },
    { id: "bare-mark", sends: [...typed("\u0E49a"), ...keys("left", "left", "right", "end", "backspace", "backspace")] },
    { id: "bare-latin", sends: [...typed("\u0301b"), ...keys("home", "right", "end", "backspace")] },
    // A mark after only zero-width characters starts its row and has no base
    // either: it takes the circle's cell, after the zero-width characters,
    // and the cursor steps over the characters and the mark as one.
    {
      id: "bare-after-zero-width-space",
      sends: [...typed("\u200B\u0E49a"), ...keys("left", "left", "right", "right", "end", "backspace", "backspace")],
    },
    {
      id: "bare-latin-after-zero-width-space",
      sends: [...typed("\u200B\u200B\u0301c"), ...keys("home", "right", "end", "left", "backspace")],
    },
    // After a base, the same zero-width character leaves the mark on its base.
    {
      id: "mark-on-base-through-zero-width",
      sends: [...typed("a\u200B\u0E49b"), ...keys("left", "left", "right", "end", "backspace", "backspace")],
    },
    // A mark typed in front of a zero-width character and text that are
    // already there starts the row, and a zero-width character typed in
    // front of a bare mark does not change that.
    { id: "zero-width-in-front", sends: [...typed("\u0E49a"), ...keys("home"), ...typed("\u200B"), ...keys("right", "end")] },
    { id: "zero-width-run-then-mark", sends: [...run("\u200B", 3), ...typed("\u0E49a"), ...keys("left", "left", "end", "backspace")] },
    // A mark typed in front of text that is already there becomes a bare mark.
    { id: "bare-in-front", sends: [...typed("ab"), ...keys("home"), ...typed("\u0E49"), ...keys("right", "left", "end")] },
    { id: "bare-wide-latin", sends: [...typed("\u0301\u754C\u0E01\u0E31"), ...keys("home", "right", "right", "end", "left")] },
    // Marks past what one cell holds: a base and 22 marks of three bytes each
    // are 69 bytes, past fx's 64, so the cell drops the last two.
    {
      id: "stacked-22",
      sends: [...typed("\u0E01"), ...run("\u0E49", 22), ...typed("b"), ...keys("left", "left", "right", "end")],
    },
    { id: "bare-stacked-22", sends: [...run("\u0E49", 22), ...typed("a"), ...keys("left", "end", "backspace")] },
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

/// Walks for the 2-column pane, where the composer row has no content cells
/// and draws nothing. Each walk types text the row cannot draw: Thai clusters,
/// marks with no base, a Latin accent, a wide character, and 12 clusters, 24
/// marks and 72 bytes, past the 64 bytes of combining text a cell holds.
function narrowWalks(): Array<{ id: string; sends: Send[] }> {
  return [
    {
      id: "narrow-thai",
      sends: [...typed("\u0E01\u0E31\u0E49\u0E07\u0E19\u0E49\u0E33"), ...keys("left", "right", "backspace", "home", "end")],
    },
    // Marks with no base come before the first character on the row.
    { id: "narrow-bare-marks", sends: [...typed("\u0E31\u0E49\u0E01\u0E31"), ...keys("home", "backspace", "end")] },
    { id: "narrow-latin", sends: [...typed("e\u0301\u0300a"), ...keys("left", "backspace")] },
    // A mark after a zero-width space has no base, and the circle has no cell.
    { id: "narrow-bare-after-zero-width", sends: [...typed("\u200B\u0E49a"), ...keys("left", "left", "end", "backspace")] },
    { id: "narrow-wide", sends: [...typed("\u754C\u0301"), ...keys("left")] },
    // A run of marks with no base: the circle has no cell either.
    { id: "narrow-bare-run", sends: [...run("\u0E49", 30), ...typed("a"), ...keys("left", "end", "backspace")] },
    {
      id: "narrow-many-clusters",
      sends: [...typed("\u0E01\u0E31\u0E49".repeat(12)), ...keys("left", "left", "end", "backspace")],
    },
  ];
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
function randomWalks(seed: number, count: number, prefix = "random"): Array<{ id: string; sends: Send[] }> {
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
    walks.push({ id: `${prefix}-${seed}-${index}`, sends });
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
function rowClasses(rowText: string): Seen[] {
  // The row is trimmed, so an empty composer row reads as the bar alone.
  if (rowText === PROMPT.trimEnd()) return [];
  if (!rowText.startsWith(PROMPT)) return ["gap"];
  return Array.from(rowText.slice(PROMPT.length), (ch): Seen =>
    ch === " " ? "gap" : ch === DOTTED_CIRCLE ? "circle" : classOf(ch.codePointAt(0)!),
  );
}

/// The cells a composer row's text takes after the prefix, by the
/// terminal's width of each class (DisplayWidth.tla TermWidth).
function rowCells(rowText: string): number {
  return rowClasses(rowText).reduce(
    (sum, cls) => sum + (cls === "mark" || cls === "latin_mark" || cls === "zw" ? 0 : cls === "wide" ? 2 : 1),
    0,
  );
}

/// The composer's rows: every pane row that starts with the bar. Nothing is
/// sent, so the transcript above holds no such row.
function composerRows(grid: string[]): number[] {
  return grid.flatMap((line, index) => (line.startsWith(PROMPT.trimEnd()) ? [index] : []));
}

type Observation = { walks: Walk[]; died: { walk: string; stderr: string } | null };

/// Sends each walk's keys and records what the pane shows after every key.
/// `observeCursor` is false for a pane with no content cells, where the
/// cursor column is not compared. When fx exits, the walks recorded so far
/// come back with the walk it died in and what it wrote to stderr.
async function runWalks(
  session: Session,
  walks: Array<{ id: string; sends: Send[] }>,
  observeCursor: boolean,
  stderrPath: string,
): Promise<Observation> {
  const observed: Walk[] = [];
  const died = (walk: string) => ({ walk, stderr: readFileSync(stderrPath, "utf8").trim() });
  for (const walk of walks) {
    const steps: Step[] = [];
    try {
      for (const send of [{ key: "clear" as const }, ...walk.sends]) {
        if (send.key === "clear") {
          await session.sendKeys("End");
          await session.sendKeys("C-u");
        } else if (send.key === "type" || send.key === "type_run") {
          await session.sendLiteralText(send.text!);
        } else {
          await session.sendKeys(TMUX_KEY[send.key]);
        }
        const { grid, cursor } = await settled(session);
        const rows = composerRows(grid).map((index) => ({ index, text: grid[index]!.trimEnd() }));
        // The cursor's column counted across rows: the cells of the rows above
        // it, then its place in its own row.
        const at = rows.findIndex((row) => row.index === cursor.row);
        const col = !observeCursor
          ? NO_COLUMN
          : at < 0
            ? OFF_ROW
            : rows.slice(0, at).reduce((sum, row) => sum + rowCells(row.text), 0) + cursor.col - PROMPT.length;
        steps.push({
          key: send.key,
          cls: send.cls ?? "none",
          n: send.n ?? 1,
          col,
          row: rows.flatMap((row) => rowClasses(row.text)),
          ...(send.text ? { codepoint: `U+${send.text.codePointAt(0)!.toString(16).toUpperCase().padStart(4, "0")}` } : {}),
          row_text: rows.map((row) => row.text).join("\n"),
        });
      }
    } catch (error) {
      if (session.isAlive()) throw error;
      return { walks: observed, died: died(walk.id) };
    }
    observed.push({ id: walk.id, steps });
    if (!session.isAlive()) return { walks: observed, died: died(walk.id) };
  }
  return { walks: observed, died: null };
}

function observedModule(walks: Walk[]): string {
  const row = (s: Step) => `<<${s.row.map((cls) => `"${cls}"`).join(", ")}>>`;
  const step = (s: Step) => `[key |-> "${s.key}", cls |-> "${s.cls}", n |-> ${s.n}, col |-> ${s.col}, row |-> ${row(s)}]`;
  const walk = (w: Walk) => `<< ${w.steps.map(step).join(", ")} >>`;
  return [
    "------------------------ MODULE DisplayWidthObserved ------------------------",
    "EXTENDS Integers",
    `\\* Generated by tests/tla/drivers/display_width/driver.ts from ${walks.length} walks.`,
    `Observed == << ${walks.map(walk).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

/// One model of the composer: the rules the walks are checked against.
type Variant = {
  rule: "fixed" | "today";
  margin: "fixed" | "row-drops" | "cell-less-keeps";
  bare: "dotted" | "joins-prefix" | "first-unit";
  limit: "drop" | "refuse";
};

/// The change.
const FIXED: Variant = { rule: "fixed", margin: "fixed", bare: "dotted", limit: "drop" };

const describe = (variant: Variant) =>
  `Rule "${variant.rule}", Margin "${variant.margin}", Bare "${variant.bare}", Limit "${variant.limit}"`;

/// `cols` is the model's Cols: the cells a composer row has after its prefix.
async function judge(dir: string, walks: Walk[], variant: Variant, cols: number) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "DisplayWidthObserved.tla"), observedModule(walks));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `    Rule = "${variant.rule}"`,
    "    MaxLen = 0",
    `    Cols = ${cols}`,
    `    Margin = "${variant.margin}"`,
    `    Bare = "${variant.bare}"`,
    `    Limit = "${variant.limit}"`,
    `    Cap = ${CELL_BYTES}`,
    `    ViewMarks = ${VIEW_MARKS}`,
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
async function rejectedWalks(dir: string, walks: Walk[], cols: number): Promise<string[]> {
  const rejected: string[] = [];
  for (const [index, walk] of walks.entries()) {
    const alone = await judge(join(dir, `walk-${index + 1}`), [walk], FIXED, cols);
    if (alone.verdict !== "ACCEPTED") rejected.push(walk.id);
  }
  return rejected;
}

/// One pane width and the walks run in it. The model's Cols is the cells
/// after the prompt, and each self-check names a model of an fx that must
/// reject the walks: at 60 columns fx before the Thai change, an fx that left
/// a mark with no base on the prompt's cell, an fx that drew only the first
/// unit of a draft on a circle, and an fx that fails the step at a full cell;
/// at 2, a row builder that puts the marks of undrawn characters on the
/// prefix cell.
type Batch = {
  name: string;
  width: number;
  walks: Array<{ id: string; sends: Send[] }>;
  observeCursor: boolean;
  selfChecks: Variant[];
};

async function main(): Promise<number> {
  const selfCheck = process.argv.includes("--self-check");
  const seed = option("--seed", 1);
  const randomCount = option("--random", 20);
  const narrowCount = option("--narrow", 6);
  const only = option("--only", 0);
  const out = outDir("display-width");
  const helpers = await targetHelpers();
  const gateway = helpers.startFakeGateway([]);
  const home = mkdtempSync(join(tmpdir(), "fx-tla-display-width-"));
  const fxHome = join(home, "fx");
  mkdirSync(fxHome, { recursive: true });
  writeFileSync(join(fxHome, "settings.json"), JSON.stringify({ sandbox: "none" }));
  const batches: Batch[] = [
    {
      name: `${PANE_WIDTH}-column`,
      width: PANE_WIDTH,
      walks: [...edgeWalks(), ...randomWalks(seed, randomCount)],
      observeCursor: true,
      selfChecks: [
        { ...FIXED, rule: "today", margin: "row-drops" },
        { ...FIXED, bare: "joins-prefix" },
        { ...FIXED, bare: "first-unit" },
        { ...FIXED, limit: "refuse" },
      ],
    },
    {
      name: `${NARROW_WIDTH}-column`,
      width: NARROW_WIDTH,
      walks: [...narrowWalks(), ...randomWalks(seed, narrowCount, "narrow-random")],
      observeCursor: false,
      selfChecks: [{ ...FIXED, margin: "cell-less-keeps" }],
    },
  ];
  const selected = only === 0 ? batches : batches.filter((batch) => batch.width === only);
  if (selected.length === 0) throw new Error(`--only ${only} names no pane: use ${PANE_WIDTH} or ${NARROW_WIDTH}`);
  let failed = false;
  let toolError = false;
  const requests = { chat: 0, title: 0, classifier: 0, models: 0 };
  const reports: unknown[] = [];
  console.log(`binary ${binary} sha256 ${hashFile(binary)}`);
  for (const batch of selected) {
    const stderrPath = join(out, `fx-stderr-${batch.width}.log`);
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
        width: batch.width,
        height: 24,
        stderrPath,
        isolated: true,
      });
      await session.waitForComposer(15_000);
      const { walks: observed, died } = await runWalks(session, batch.walks, batch.observeCursor, stderrPath);
      const steps = observed.reduce((sum, walk) => sum + walk.steps.length, 0);
      const cols = Math.max(0, batch.width - PROMPT.length);
      const fixed = observed.length > 0 ? await judge(join(out, `tlc-fixed-${batch.width}`), observed, FIXED, cols) : null;
      const checks = [];
      if (selfCheck && observed.length > 0 && !died) {
        for (const [index, variant] of batch.selfChecks.entries()) {
          checks.push({ variant, ...(await judge(join(out, `tlc-self-check-${batch.width}-${index + 1}`), observed, variant, cols)) });
        }
      }
      const rejected = fixed?.verdict === "REJECTED"
        ? await rejectedWalks(join(out, `tlc-walks-${batch.width}`), observed, cols)
        : [];
      console.log(`-- ${batch.name} pane (Cols ${cols}): walks ${observed.length} of ${batch.walks.length}, steps ${steps}, seed ${seed}`);
      if (fixed) {
        console.log(`TLC (${describe(FIXED)}): ${fixed.verdict}, ${fixed.distinctStates} distinct states, ${fixed.durationMs} ms`);
      }
      for (const check of checks) {
        console.log(`TLC self-check (${describe(check.variant)}): ${check.verdict}, ${check.distinctStates} distinct states`);
      }
      if (rejected.length > 0) {
        console.log(`walks TLC rejects alone (${rejected.length} of ${observed.length}): ${rejected.join(", ")}`);
        const first = observed.find((walk) => walk.id === rejected[0])!;
        for (const step of first.steps) {
          console.log(`  ${first.id} ${step.key}${step.codepoint ? ` ${step.codepoint}` : ""}: col ${step.col}, row ${JSON.stringify(step.row_text)}`);
        }
      }
      if (died) {
        console.log(`FAIL: fx exited during walk ${died.walk} in the ${batch.name} pane, stderr [${died.stderr}]`);
        failed = true;
      }
      if (fixed?.verdict === "TOOL_ERROR" || checks.some((check) => check.verdict === "TOOL_ERROR")) toolError = true;
      if (fixed && fixed.verdict !== "ACCEPTED") failed = true;
      for (const check of checks) {
        if (check.verdict === "REJECTED") continue;
        console.log(`FAIL: the model of fx with the bug (${describe(check.variant)}) accepted the ${batch.name} walks, so they do not test it`);
        failed = true;
      }
      reports.push({
        pane: batch.name,
        cols,
        walks: observed.length,
        steps,
        verdict: fixed?.verdict ?? "NO_WALKS",
        tlc_distinct_states: fixed?.distinctStates,
        tlc_ms: fixed?.durationMs,
        self_checks: checks.map((check) => ({ ...check.variant, verdict: check.verdict, distinct_states: check.distinctStates })),
        died,
        rejected_walks: rejected,
        observed,
      });
    } finally {
      await session?.kill();
    }
  }
  requests.chat = gateway.requests.length;
  requests.title = gateway.titleRequests.length;
  requests.classifier = gateway.classifierRequests.length;
  requests.models = gateway.modelRequests.length;
  try {
    writeJson(join(out, "report.json"), { binary, binary_sha256: hashFile(binary), seed, gateway_requests: requests, panes: reports });
    console.log(`fake gateway requests: chat ${requests.chat}, title ${requests.title}, classifier ${requests.classifier}, models ${requests.models}`);
    console.log(`report ${join(out, "report.json")}`);
    if (toolError) return 2;
    if (requests.chat !== 0) {
      console.log(`FAIL: fx sent ${requests.chat} model requests to the fake gateway; none were expected`);
      return 1;
    }
    return failed ? 1 : 0;
  } finally {
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
