// Runs the built fx through the three surfaces that draw text after a fixed
// prefix cell, in tmux, along tests/tla/display_width/DisplayWidth.tla, and has
// TLC check every row it observes (DisplayWidthRows.tla):
//
//   label     a question's option label, after the panel's "    N) "
//   resolved  the answer row a resolved question leaves in the transcript,
//             after a five-cell indent
//   banner    the steering banner of a message queued while a tool runs,
//             after the rail "┋ "
//
// Each surface draws text after a cell that is no base for a mark, so each
// applies the rule the model states for the composer (BareCol0): a mark that
// starts its row, with nothing but zero-width characters before it, takes one
// cell on a dotted circle, and the text wraps after it. The cases are a mark
// with no base, marks stacked on the circle, a Latin mark with no base, a mark
// on a base and a Thai cluster (no circle), a mark after a zero-width space,
// which fx draws as the visible text \u{200b} so the mark sits on that text,
// and a text that wraps. A label is also the answer: option 1 of each question
// is chosen, so its text comes back as the resolved row. The driver reads
// the classes of the code points tmux shows after each prefix, with "circle"
// for U+25CC and "gap" for a blank cell, and TLC requires Shown of the text
// to be exactly those rows. The same walk of the old binary, which put the mark
// on the prefix cell, is rejected.
//
// --self-check also replays the rows under two models of fx before the change,
// each of which must reject them: Bare "joins-prefix", a mark with no base
// left on the prefix cell, and Bare "dotted-uncounted", a circle that is drawn
// but takes no cell in the layout, so a text that wraps puts one cell too many
// on its first row.
//
// fx runs with FX_SOUND=0, FX_DISABLE_KEYCHAIN=1, a temporary HOME and FX_HOME,
// a fake key, and a local fake gateway. The driver fails unless the gateway got
// exactly the model requests it queued answers for.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/display_width/prefixed.ts
//   bun tests/tla/drivers/display_width/prefixed.ts --self-check
//
// Exit codes: 0 every row accepted (and the self-check rejected), 1 a row the
// model rejects, a wrong request count, or fx exiting, 2 a toolchain or
// harness failure.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, hashFile, targetHelpers } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Class = "base" | "mark" | "am" | "ascii" | "wide" | "latin_mark" | "zw";
type Seen = Class | "gap" | "circle";
type Surface = "label" | "resolved" | "banner";
type Observed = { surface: Surface; id: string; source: string; text: Class[]; row: Seen[]; row_text: string[] };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const PANE_WIDTH = 40;
const PANE_HEIGHT = 40;
const DOTTED_CIRCLE = "\u25cc";
// The prefix of each surface, in cells, which the model's Cols leaves out.
const LABEL_PREFIX = "    1) ";
const OPTION_INDENT = "    ";
const RESOLVED_INDENT = "     ";
const RAIL = "┋ ";
const COLS: { [surface in Surface]: number } = {
  label: PANE_WIDTH - LABEL_PREFIX.length,
  resolved: PANE_WIDTH - RESOLVED_INDENT.length,
  banner: PANE_WIDTH - RAIL.length,
};
const tlaDir = join(TLA_ROOT, "display_width");
const TIMEOUT = 20_000;

const THAI_MARKS = [0x0e31, 0x0e34, 0x0e35, 0x0e36, 0x0e37, 0x0e38, 0x0e39, 0x0e3a,
  0x0e47, 0x0e48, 0x0e49, 0x0e4a, 0x0e4b, 0x0e4c, 0x0e4d, 0x0e4e];

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

const classes = (text: string): Class[] => Array.from(text, (ch) => classOf(ch.codePointAt(0)!));

/// The classes of the code points tmux shows in `rowText`, which has no prefix.
function seen(rowText: string): Seen[] {
  return Array.from(rowText.trimEnd(), (ch): Seen =>
    ch === " " ? "gap" : ch === DOTTED_CIRCLE ? "circle" : classOf(ch.codePointAt(0)!),
  );
}

const MARK = "\u0E49";
const ZERO_WIDTH_SPACE = "\u200B";
const WRAPPED = `${MARK}${"a".repeat(40)}`;

/// What fx draws for `text`: a zero-width space is not drawn as itself but as
/// the visible escape `\u{200b}`, so the mark after it sits on that text and
/// is no bare mark. The model checks the text that is drawn.
const drawn = (text: string) => text.replaceAll(ZERO_WIDTH_SPACE, "\\u{200b}");

/// Option 1 of each question is the one answered. Turn 0 shows every shape in
/// one panel; the later turns answer with the shapes whose row differs.
const SHAPES = [
  { id: "bare", text: `${MARK}abc` },
  { id: "mark-after-escaped-zero-width", text: `${ZERO_WIDTH_SPACE}${MARK}abc` },
  { id: "bare-stacked", text: `${MARK}\u0E48abc` },
  { id: "mark-on-base", text: `a${MARK}bc` },
  { id: "thai-cluster", text: "\u0E01\u0E31\u0E49\u0E07" },
  { id: "bare-latin", text: "\u0301abc" },
];
const TURNS: Array<{ id: string; options: string[]; answer: string }> = [
  { id: "shapes", options: SHAPES.map((shape) => shape.text), answer: SHAPES[0]!.text },
  { id: "escaped-zero-width", options: [SHAPES[1]!.text, "other"], answer: SHAPES[1]!.text },
  { id: "stacked", options: [SHAPES[2]!.text, "other"], answer: SHAPES[2]!.text },
  { id: "latin", options: [SHAPES[5]!.text, "other"], answer: SHAPES[5]!.text },
  { id: "wrapped", options: [WRAPPED, "other"], answer: WRAPPED },
];
const MESSAGES = [
  { id: "bare", text: `${MARK}abc`, rows: 1 },
  { id: "mark-after-escaped-zero-width", text: `${ZERO_WIDTH_SPACE}${MARK}abc`, rows: 1 },
  { id: "wrapped", text: WRAPPED, rows: 2 },
];

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type Session = {
  sendText(text: string): Promise<void>;
  sendKeys(keys: string): Promise<void>;
  capturePaneGrid(): Promise<string[]>;
  waitForComposer(timeoutMs?: number): Promise<string>;
  waitForText(text: string, timeoutMs?: number): Promise<string>;
  isAlive(): boolean;
  kill(): Promise<void>;
};

/// The pane once it has not changed for `steadyMs` and `ready` holds.
async function settled(session: Session, ready: (grid: string[]) => boolean, label: string): Promise<string[]> {
  const started = Date.now();
  let last = "";
  let since = Date.now();
  while (Date.now() - started < TIMEOUT) {
    const grid = await session.capturePaneGrid();
    const key = grid.join("\n");
    if (key !== last) {
      last = key;
      since = Date.now();
    } else if (Date.now() - since >= 300 && ready(grid)) {
      return grid;
    }
    await sleep(25);
  }
  throw new Error(`the pane did not settle: ${label}`);
}

/// The rows of every option of the panel, each as the rows after its prefix:
/// the first row has "    N) " before it, a continuation row seven blanks.
function optionRows(grid: string[], count: number): string[][] {
  const starts = Array.from({ length: count }, (_, index) => {
    const at = grid.findIndex((line) => line.startsWith(`${OPTION_INDENT}${index + 1}) `));
    if (at < 0) throw new Error(`no row for option ${index + 1}`);
    return at;
  });
  const indent = " ".repeat(LABEL_PREFIX.length);
  return starts.map((first, index) => {
    const rows = [grid[first]!.slice(LABEL_PREFIX.length)];
    for (let at = first + 1; at < grid.length; at += 1) {
      if (index + 1 < count && at === starts[index + 1]) break;
      const line = grid[at]!;
      if (!line.startsWith(indent) || line.length === indent.length || line[indent.length] === " ") break;
      rows.push(line.slice(indent.length));
    }
    return rows;
  });
}

/// The answer rows of the resolved question `question`: the rows after its own
/// row that start with the five-cell indent and then something.
function resolvedRows(grid: string[], question: string): string[] {
  const at = grid.findIndex((line) => line.startsWith(`  1) ${question}`));
  if (at < 0) throw new Error(`no resolved block for ${question}`);
  const rows: string[] = [];
  for (let index = at + 1; index < grid.length; index += 1) {
    const line = grid[index]!;
    if (!line.startsWith(RESOLVED_INDENT) || line.length === RESOLVED_INDENT.length || line[RESOLVED_INDENT.length] === " ") break;
    rows.push(line.slice(RESOLVED_INDENT.length));
  }
  return rows;
}

/// The banner's rows, oldest message first, each after the rail.
function bannerRows(grid: string[]): string[] {
  return grid.filter((line) => line.trimStart().startsWith(RAIL)).map((line) => line.trimStart().slice(RAIL.length));
}

function record(surface: Surface, id: string, source: string, rows: string[]): Observed {
  return { surface, id, source, text: classes(drawn(source)), row: rows.flatMap(seen), row_text: rows };
}

function observedModule(records: Observed[]): string {
  const list = (items: string[]) => `<<${items.map((item) => `"${item}"`).join(", ")}>>`;
  const one = (r: Observed) => `[surface |-> "${r.surface}", id |-> "${r.id}", text |-> ${list(r.text)}, row |-> ${list(r.row)}]`;
  return [
    "---------------------- MODULE DisplayWidthRowsObserved ----------------------",
    `\\* Generated by tests/tla/drivers/display_width/prefixed.ts from ${records.length} rows.`,
    `Observed == << ${records.map(one).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

type Variant = { bare: "dotted" | "joins-prefix" | "dotted-uncounted" };
const FIXED: Variant = { bare: "dotted" };
const describe = (variant: Variant) => `Bare "${variant.bare}"`;

async function judge(dir: string, records: Observed[], variant: Variant, cols: number) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "DisplayWidthRowsObserved.tla"), observedModule(records));
  writeFileSync(join(dir, "rows.cfg"), [
    "SPECIFICATION RowsSpec",
    "CONSTANTS",
    '    Rule = "fixed"',
    "    MaxLen = 0",
    `    Cols = ${cols}`,
    '    Margin = "fixed"',
    `    Bare = "${variant.bare}"`,
    '    Limit = "drop"',
    "    Cap = 64",
    "INVARIANT NotAllMatched",
    "",
  ].join("\n"));
  // A record the model cannot take leaves no successor; -deadlock makes that a
  // completed search (REJECTED) instead of an error.
  const run = await runTlc(dir, "DisplayWidthRows", "rows.cfg", ["DisplayWidth.tla", "DisplayWidthRows.tla"], tlaDir, ["-deadlock"]);
  const verdict: Verdict = run.exitCode === 12 && run.violated === "NotAllMatched"
    ? "ACCEPTED"
    : run.exitCode === 0 && run.output.includes("No error has been found")
      ? "REJECTED"
      : "TOOL_ERROR";
  return { verdict, distinctStates: run.distinctStates, durationMs: run.durationMs };
}

async function main(): Promise<number> {
  const selfCheck = process.argv.includes("--self-check");
  const out = outDir("display-width-prefixed");
  const helpers = await targetHelpers();
  const home = mkdtempSync(join(tmpdir(), "fx-tla-prefixed-"));
  const fxHome = join(home, "fx");
  const workspace = join(home, "workspace");
  mkdirSync(fxHome, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(fxHome, "settings.json"), JSON.stringify({ sandbox: "none" }));
  const release = join(workspace, ".release-tool");
  const command = `while [ ! -f ${JSON.stringify(release)} ]; do sleep 0.05; done; printf STEERED_TOOL_DONE`;
  const toolFinal = "BANNER-TURN-DONE";
  const responses: Response[] = [];
  TURNS.forEach((turn, index) => {
    responses.push(
      helpers.fakeGatewayToolCall(`question_${index}`, "ask_user_question", {
        questions: [{ question: `Question ${index}?`, options: turn.options.map((label) => ({ label })) }],
      }),
      helpers.fakeGatewayFinalText(`TURN-${index}-DONE`),
    );
  });
  responses.push(
    helpers.fakeGatewayToolCall("banner_tool", "shell", {
      request: { action: "run", yield_time_ms: 30_000, timeout_ms: 600_000, command },
    }),
    helpers.fakeGatewayFinalText(toolFinal),
  );
  const expectedRequests = responses.length;
  const gateway = helpers.startFakeGateway(responses);
  const stderrPath = join(out, "fx-stderr.log");
  writeFileSync(stderrPath, "");
  console.log(`binary ${binary} sha256 ${hashFile(binary)}`);
  const records: Observed[] = [];
  let session: Session | null = null;
  let failed = false;
  try {
    session = await helpers.TmuxSession.create({
      cmd: binary,
      cwd: workspace,
      env: {
        HOME: home,
        FX_HOME: fxHome,
        FX_SOUND: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        FX_PERMISSION_MODE: "yolo",
        AI_GATEWAY_API_KEY: "fake-prefixed-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
      },
      width: PANE_WIDTH,
      height: PANE_HEIGHT,
      stderrPath,
      isolated: true,
    });
    await session.waitForComposer(15_000);

    for (const [index, turn] of TURNS.entries()) {
      const question = `Question ${index}?`;
      await session.sendText(`Ask question ${index}.`);
      await session.waitForText(question, TIMEOUT);
      const panel = await settled(session, (grid) => grid.some((line) => line.startsWith(`${OPTION_INDENT}${turn.options.length}) `)), `panel ${turn.id}`);
      const rows = optionRows(panel, turn.options.length);
      turn.options.forEach((label, option) => {
        if (label === "other") return;
        const shape = SHAPES.find((candidate) => candidate.text === label)?.id ?? turn.id;
        records.push(record("label", `${turn.id}-${shape}`, label, rows[option]!));
      });
      // Enter takes option 1, whose text is the answer.
      await session.sendKeys("Enter");
      await session.waitForText(`TURN-${index}-DONE`, TIMEOUT);
      const after = await settled(session, (grid) => grid.some((line) => line.startsWith(`  1) ${question}`)), `resolved ${turn.id}`);
      const answerRows = resolvedRows(after, question);
      records.push(record("resolved", turn.id, turn.answer, answerRows));
    }

    await session.sendText("Run the held tool.");
    await session.waitForText("Running while", TIMEOUT);
    for (const message of MESSAGES) await session.sendText(message.text);
    const wanted = MESSAGES.reduce((sum, message) => sum + message.rows, 0);
    const banner = await settled(session, (grid) => bannerRows(grid).length >= wanted, "banner");
    const shown = bannerRows(banner);
    let next = 0;
    for (const message of MESSAGES) {
      records.push(record("banner", message.id, message.text, shown.slice(next, next + message.rows)));
      next += message.rows;
    }
    writeFileSync(release, "");
    await session.waitForText(toolFinal, TIMEOUT);
    if (!session.isAlive()) throw new Error("fx exited");
  } catch (error) {
    console.log(`FAIL: ${error instanceof Error ? error.message : error}`);
    failed = true;
  } finally {
    await session?.kill();
  }

  const requests = gateway.requests.length;
  const stderr = readFileSync(stderrPath, "utf8").trim();
  console.log(`fake gateway requests: ${requests}, expected ${expectedRequests}; stderr [${stderr}]`);
  if (requests !== expectedRequests || stderr !== "") failed = true;
  gateway.stop();
  rmSync(home, { recursive: true, force: true });
  if (records.length === 0) {
    console.log("FAIL: no rows were observed");
    return 2;
  }

  let toolError = false;
  const reports: unknown[] = [];
  const groups = (["label", "resolved", "banner"] as Surface[]).map((surface) => ({
    surface,
    cols: COLS[surface],
    records: records.filter((r) => r.surface === surface),
  })).filter((group) => group.records.length > 0);
  const variants = selfCheck ? [FIXED, { bare: "joins-prefix" } as Variant, { bare: "dotted-uncounted" } as Variant] : [FIXED];
  for (const group of groups) {
    console.log(`-- ${group.surface} rows (Cols ${group.cols}): ${group.records.length} records`);
    for (const [index, variant] of variants.entries()) {
      const dir = join(out, `tlc-${group.surface}-${index}`);
      const result = await judge(dir, group.records, variant, group.cols);
      const must = variant === FIXED ? "ACCEPTED" : "REJECTED";
      console.log(`TLC (${describe(variant)}): ${result.verdict}, ${result.distinctStates} distinct states, ${result.durationMs} ms`);
      if (result.verdict === "TOOL_ERROR") toolError = true;
      else if (result.verdict !== must) {
        failed = true;
        if (variant === FIXED) {
          for (const one of group.records) {
            const alone = await judge(join(dir, `record-${one.id}`), [one], FIXED, group.cols);
            if (alone.verdict !== "ACCEPTED") {
              console.log(`  the model rejects ${one.surface} ${one.id}: text ${JSON.stringify(one.source)}, rows ${JSON.stringify(one.row_text)}`);
            }
          }
        } else {
          console.log(`FAIL: the model of fx with the bug (${describe(variant)}) accepted the ${group.surface} rows, so they do not test it`);
        }
      }
      reports.push({ surface: group.surface, cols: group.cols, variant, verdict: result.verdict, distinct_states: result.distinctStates });
    }
  }
  writeJson(join(out, "report.json"), { binary, binary_sha256: hashFile(binary), requests, expected_requests: expectedRequests, records, checks: reports });
  console.log(`report ${join(out, "report.json")}`);
  if (toolError) return 2;
  return failed ? 1 : 0;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.error(error instanceof Error ? error.stack ?? error.message : error);
    process.exit(2);
  },
);
