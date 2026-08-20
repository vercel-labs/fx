import { afterEach, expect, test } from "bun:test";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  hasEmptyComposer,
  isComposerLine,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import {
  assertPaneContains,
  assertSingleFooter,
} from "./tui-render-assertions";

const HAS_TMUX = tmuxAvailable();
if (process.env.FX_REQUIRE_TMUX === "1" && !HAS_TMUX) {
  throw new Error("tmux is required for tui-input-navigation.test.ts");
}

const tmuxTest = test.skipIf(!HAS_TMUX);
const TIMEOUT = 45_000;
const READY_TIMEOUT = 10_000;
const SELECTED_COMPLETION_SGR = "\x1b[1m\x1b[38;5;255m";
const RENDER_TRACE_SCOPES =
  "paint,render,scroll,frame_plan,frame_diff,frame_commit,frame_owner_violation";
const imageFixture = join(
  REPO_ROOT,
  "tests/e2e/fixtures/favicon.png",
);

let session: TmuxSession | null = null;
let testHome: string | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let stderrPath: string | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  if (testHome) rmSync(testHome, { recursive: true, force: true });
  testHome = null;
  stderrPath = null;
});

async function startFx(
  width: number,
  height: number,
  withGateway = false,
  recordRender = false,
  gatewayResponseCount = 1,
): Promise<TmuxSession> {
  testHome = mkdtempSync(join(tmpdir(), "fx-tui-input-"));
  stderrPath = join(testHome, "stderr.log");
  writeFileSync(stderrPath, "");
  mkdirSync(join(testHome, ".fx"), { recursive: true });
  writeFileSync(
    join(testHome, ".fx", "settings.json"),
    JSON.stringify({ maxxing_mode: "legacy", sandbox: "none" }),
  );
  if (withGateway) {
    gateway = startFakeGateway(
      Array.from(
        { length: gatewayResponseCount },
        () => fakeGatewayFinalText("history prompt complete"),
      ),
    );
  }
  const active = await TmuxSession.create({
    cmd: withGateway
      ? FX_BIN
      : `env -u AI_GATEWAY_API_KEY -u VERCEL_OIDC_TOKEN FX_DISABLE_KEYCHAIN=1 FX_SKIP_ONBOARDING=1 ${FX_BIN}`,
    env: {
      HOME: testHome,
      ...(gateway
        ? {
          AI_GATEWAY_API_KEY: "fake-input-navigation-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
        }
        : {}),
      ...(recordRender
        ? {
          FX_RECORD: join(testHome, "session.fxtape"),
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: join(testHome, "trace.log"),
          FX_TRACE_SCOPES: RENDER_TRACE_SCOPES,
        }
        : {}),
    },
    width,
    height,
    stderrPath,
  });
  session = active;
  await active.waitForComposer(READY_TIMEOUT);
  return active;
}

function largeTabbedPaste(): string {
  return [
    "\tTAB_START_0001\tquoted=\"value 1\"\tansi_like=\\x1b[32mgreen\\x1b[0m",
    `LONGTOKEN_${"X".repeat(220)}_0003`,
    "    indented code block tok0 tok1 tok2 tok3 tok4 tok5 tok6 tok7 tok8 tok9 tok10 tok11",
    "Pathish ~/tmp/example/nested/nested/nested/nested/nested/nested/nested/nested/file_12.txt",
    `MARKER_0013 ${"word ".repeat(24)}word`,
    "\tTAB_START_0015\tquoted=\"value 15\"\tansi_like=\\x1b[32mgreen\\x1b[0m",
    "\tTAB_START_0029\tquoted=\"value 29\"\tansi_like=\\x1b[32mgreen\\x1b[0m",
    "\tTAB_START_0043\tquoted=\"value 43\"\tansi_like=\\x1b[32mgreen\\x1b[0m",
    "\tTAB_START_0057\tquoted=\"value 57\"\tansi_like=\\x1b[32mgreen\\x1b[0m",
    "\tTAB_START_0071\tquoted=\"value 71\"\tansi_like=\\x1b[32mgreen\\x1b[0m",
    "\tTAB_START_0085\tquoted=\"value 85\"\tansi_like=\\x1b[32mgreen\\x1b[0m",
  ].join("\n") + "\n";
}

function expectCleanStderr(): void {
  if (!stderrPath) throw new Error("stderrPath was not initialized");
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}

async function typeLiteral(active: TmuxSession, text: string): Promise<void> {
  await active.sendKeys(`-l ${shellQuote(text)}`);
}

function shellQuote(text: string): string {
  return `'${text.replace(/'/g, "'\\''")}'`;
}

function hexSeq(text: string): string[] {
  return Array.from(new TextEncoder().encode(text), (byte) =>
    byte.toString(16).padStart(2, "0")
  );
}

function isSlashCommandRow(line: string): boolean {
  const visible = line
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
    .trimStart();
  return visible.startsWith("/");
}

function selectedSlashRow(escapes: string): string | null {
  const rows = escapes
    .split("\n")
    .filter(isSlashCommandRow);
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const line = rows[index]!;
    if (line.includes(SELECTED_COMPLETION_SGR)) return line;
  }
  return null;
}

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
}

function rowWithVisiblePredicate(
  escapes: string,
  predicate: (visible: string, raw: string) => boolean,
): string {
  for (const row of escapes.split("\n")) {
    if (predicate(stripAnsi(row), row)) return row;
  }
  throw new Error(`No ANSI row matched predicate\n${escapes}`);
}

function selectedArgumentLabelRow(escapes: string, label: string): string {
  return rowWithVisiblePredicate(
    escapes,
    (visible, raw) =>
      visible.trimStart().startsWith(label) && raw.includes(SELECTED_COMPLETION_SGR),
  );
}

function rowHasBackgroundSgr(row: string): boolean {
  return /\x1b\[[0-9;:]*48[;:]/.test(row) || /\x1b\[(?:4[0-7]|10[0-7])m/.test(row);
}

test("selected slash row ignores the welcome header help hint", () => {
  const header = `${SELECTED_COMPLETION_SGR}𝒇x\x1b[0m\x1b[38;5;245m v0.3.27 · Run /help for commands`;
  const composer = `${SELECTED_COMPLETION_SGR}❯ /\x1b[39m`;
  const selected = `${SELECTED_COMPLETION_SGR}  /clear\x1b[38;5;245m Clear the conversation`;

  expect(selectedSlashRow(`${header}\n${composer}\n${selected}`)).toBe(selected);
});

async function waitForSelectedSlashLabel(
  active: TmuxSession,
  label: string,
  timeoutMs: number,
): Promise<string> {
  const start = Date.now();
  let lastRow: string | null = null;
  while (Date.now() - start < timeoutMs) {
    lastRow = selectedSlashRow(await active.capturePaneEscapes());
    if (lastRow?.includes(label)) return lastRow;
    await delay(25);
  }
  throw new Error(`Timed out waiting for selected slash label ${label}; last=${lastRow}`);
}

function rowContaining(grid: string[], needle: string): { index: number; line: string } {
  const index = grid.findIndex((line) => line.includes(needle));
  if (index < 0) throw new Error(`No pane row contains ${JSON.stringify(needle)}\n${grid.join("\n")}`);
  return { index, line: grid[index]! };
}

async function expectOptionColumn(
  active: TmuxSession,
  label: string,
  zeroBasedColumn: number,
): Promise<void> {
  await active.waitForPane((pane) => pane.includes(label), READY_TIMEOUT);
  const matches = (await active.capturePaneGrid()).filter((line) => line.includes(label));
  if (matches.length === 0) throw new Error(`No pane row contains ${JSON.stringify(label)}`);
  const row = matches[matches.length - 1]!;
  expect(row.indexOf(label)).toBe(zeroBasedColumn);
}

async function setupPromptHistory(active: TmuxSession): Promise<void> {
  await active.sendText("zz-history");
  await active.waitForText("history prompt complete", READY_TIMEOUT);
}

async function setupMultilinePromptHistory(active: TmuxSession): Promise<void> {
  await active.sendText("older");
  await active.waitForText("history prompt complete", READY_TIMEOUT);
  await typeLiteral(active, "newer top");
  await active.sendKeys("M-Enter");
  await typeLiteral(active, "newer bottom");
  await active.sendKeys("Enter");
  await active.waitForPane(
    (pane) =>
      gateway?.requests.length === 2 &&
      pane.includes("❯") &&
      !pane.includes("Thinking"),
    READY_TIMEOUT,
  );
}

async function waitForActiveFooter(
  active: TmuxSession,
  predicate: (footer: string) => boolean,
): Promise<string> {
  const started = Date.now();
  let last = "";
  while (Date.now() - started < READY_TIMEOUT) {
    const grid = await active.capturePaneGrid();
    const failures: string[] = [];
    const footer = assertSingleFooter(grid, failures, "active footer");
    if (footer && failures.length === 0) {
      last = grid.slice(footer.input, footer.bottomDivider).join("\n");
      if (predicate(last)) return last;
    }
    await delay(25);
  }
  throw new Error(`Timed out waiting for active footer; last=${last}`);
}

async function waitForExactComposerRow(
  active: TmuxSession,
  expected: string,
): Promise<void> {
  const started = Date.now();
  let lastMatches: string[] = [];
  while (Date.now() - started < READY_TIMEOUT) {
    lastMatches = (await active.capturePaneGrid())
      .map((line) => line.trimEnd())
      .filter((line) => line === expected);
    if (lastMatches.length === 1) return;
    await delay(25);
  }
  throw new Error(
    `Timed out waiting for composer row ${JSON.stringify(expected)}; matches=${lastMatches.length}`,
  );
}

async function typeTwoRowDraft(active: TmuxSession): Promise<void> {
  await typeLiteral(active, "draft");
  await active.sendKeys("M-Enter");
  await typeLiteral(active, "tail");
  await active.waitForPane((pane) => pane.includes("tail"), READY_TIMEOUT);
}

function repeatedImagePaste(count: number): string {
  return Array.from({ length: count }, () => imageFixture).join(" ");
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

tmuxTest(
  "raw control aliases navigate slash completion through submission",
  async () => {
    const active = await startFx(80, 24);
    await typeLiteral(active, "/");
    await waitForSelectedSlashLabel(active, "/help", READY_TIMEOUT);

    await active.sendHexBytes(["0a"]);
    await waitForSelectedSlashLabel(active, "/clear", READY_TIMEOUT);
    await waitForExactComposerRow(active, "❯ /");

    await active.sendHexBytes(["0b"]);
    await waitForSelectedSlashLabel(active, "/help", READY_TIMEOUT);
    await waitForExactComposerRow(active, "❯ /");

    await active.sendKeys("Enter");
    await active.waitForText("Commands 39", READY_TIMEOUT);
    await active.sendKeys("Escape");
    await active.waitForText("Run /help for commands", READY_TIMEOUT);
    expect(active.isAlive()).toBe(true);
    expectCleanStderr();
  },
  TIMEOUT,
);

tmuxTest(
  "unknown terminal escape sequences leave the command catalog open",
  async () => {
    const active = await startFx(80, 24);
    await active.sendText("/help");
    await active.waitForPane(
      (pane) =>
        pane.includes("/help") &&
        pane.includes("/quit") &&
        !pane.includes("Run /help for commands"),
      READY_TIMEOUT,
    );

    await active.sendHexBytes(hexSeq("\x1b[>0q"));
    const afterUnknown = await active.capturePane();
    expect(afterUnknown).toContain("/help");
    expect(afterUnknown).toContain("/quit");
    expect(afterUnknown).not.toContain("Run /help for commands");

    await active.sendKeys("Escape");
    await active.waitForText("Run /help for commands", READY_TIMEOUT);
    expect(active.isAlive()).toBe(true);
    expectCleanStderr();
  },
  TIMEOUT,
);

tmuxTest(
  "plain Up and Down move exactly one hard-newline visual row per press",
  async () => {
    const active = await startFx(60, 24);
    await typeLiteral(active, "alpha");
    await active.sendKeys("M-Enter");
    await typeLiteral(active, "beta");
    await active.sendKeys("M-Enter");
    await typeLiteral(active, "gamma");

    await active.waitForPane((pane) => pane.includes("gamma"), READY_TIMEOUT);
    const bottom = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendKeys("Up");
    const middle = await active.waitForCursor(
      (position) => position.row === bottom.row - 1,
      READY_TIMEOUT,
    );
    await active.sendKeys("Up");
    await active.waitForCursor((position) => position.row === middle.row - 1, READY_TIMEOUT);
    await active.sendKeys("Down");
    await active.waitForCursor((position) => position.row === middle.row, READY_TIMEOUT);
  },
  TIMEOUT,
);

tmuxTest(
  "plain Up and Down move exactly one narrow-pane soft-wrap row",
  async () => {
    const active = await startFx(18, 24);
    await typeLiteral(active, "abcdefghijklmnopqrstuvwxyz0123456789");
    await active.waitForPane((pane) => pane.includes("6789"), READY_TIMEOUT);
    const bottom = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendKeys("Up");
    const previous = await active.waitForCursor(
      (position) => position.row === bottom.row - 1,
      READY_TIMEOUT,
    );
    await active.sendKeys("Down");
    await active.waitForCursor(
      (position) => position.row === previous.row + 1 && position.col === bottom.col,
      READY_TIMEOUT,
    );
  },
  TIMEOUT,
);

tmuxTest(
  "bracketed-pasted tabs preserve columns across rows and vertical arrows move one row",
  async () => {
    const active = await startFx(10, 24);
    await active.pasteText("\tX\naaaaaa\tY");
    await active.waitForPane((pane) => pane.includes("Y"), READY_TIMEOUT);
    const bottom = await active.waitForCursor((position) => position.col === 9, READY_TIMEOUT);
    await active.sendKeys("Up");
    const previous = await active.waitForCursor(
      (position) => position.row === bottom.row - 1,
      READY_TIMEOUT,
    );
    await active.sendKeys("Down");
    await active.waitForCursor(
      (position) => position.row === previous.row + 1 && position.col === bottom.col,
      READY_TIMEOUT,
    );
  },
  TIMEOUT,
);

tmuxTest(
  "typed sentences wrap by word and continuation rows never start with a space",
  async () => {
    // 20 cols, prefix "❯ " = 18 content cells per row.
    const active = await startFx(20, 24);

    // "wrapping" (8 cells) does not fit after "hello world " (12 cells),
    // so it moves whole to the next row.
    await typeLiteral(active, "hello world wrapping here");
    let footer = await waitForActiveFooter(
      active,
      (text) => text.includes("hello world") && text.includes("wrapping here"),
    );
    let rows = footer.split("\n");
    const first = rowContaining(rows, "hello world");
    const second = rowContaining(rows, "wrapping here");
    expect(second.index).toBe(first.index + 1);
    expect(first.line).not.toContain("wrapp");
    // Continuation row starts at the prefix column, not a space.
    expect(second.line.indexOf("wrapping here")).toBe(2);

    // A space landing exactly at the margin hangs there: the row after it
    // still starts at the word.
    await active.sendKeys("C-u");
    await typeLiteral(active, "abcdefghijklmnopqr st");
    footer = await waitForActiveFooter(
      active,
      (text) =>
        text.includes("abcdefghijklmnopqr") &&
        text.split("\n").some((line) => line.trim() === "st"),
    );
    rows = footer.split("\n");
    const full = rowContaining(rows, "abcdefghijklmnopqr");
    const next = rowContaining(rows, "st");
    expect(next.index).toBe(full.index + 1);
    expect(next.line.indexOf("st")).toBe(2);

    // Words wider than a full row still split per character: row 0 fills
    // all 18 content cells and the remainder continues on the next row.
    await active.sendKeys("C-u");
    await typeLiteral(active, "ab cdefghijklmnopqrstuvwxyz");
    footer = await waitForActiveFooter(
      active,
      (text) =>
        text.includes("ab cdefghijklmnopq") && text.includes("rstuvwxyz"),
    );
    rows = footer.split("\n");
    const head = rowContaining(rows, "ab cdefghijklmnopq");
    const tail = rowContaining(rows, "rstuvwxyz");
    expect(tail.index).toBe(head.index + 1);
    expect(tail.line.indexOf("rstuvwxyz")).toBe(2);
  },
  TIMEOUT,
);

tmuxTest(
  "Unicode display units repaint after a wide shift and at the right margin",
  async () => {
    const active = await startFx(60, 24);

    await typeLiteral(active, "A🇺🇸B");
    await waitForActiveFooter(active, (footer) => footer.includes("A🇺🇸B"));
    await active.sendKeys("Left Left BSpace");
    const shifted = await waitForActiveFooter(
      active,
      (footer) => footer.includes("🇺🇸B") && !footer.includes("A🇺🇸B"),
    );
    expect(shifted).not.toContain("A🇺🇸B");

    const margin_prefix = "12345678901234567890123456789012345678901234567890123456";
    await active.sendKeys("End C-u");
    await typeLiteral(active, `${margin_prefix}👩‍💻Z`);
    let footer = await waitForActiveFooter(
      active,
      (text) =>
        text.includes(`${margin_prefix}👩‍💻`) &&
        text.split("\n").some((line) => line.trim() === "Z"),
    );
    let rows = footer.split("\n");
    const margin = rowContaining(rows, `${margin_prefix}👩‍💻`);
    const wrapped = rowContaining(rows, "Z");
    expect(wrapped.index).toBe(margin.index + 1);
    expect(wrapped.line.indexOf("Z")).toBe(2);

    const control_prefix = margin_prefix.slice(0, -1);
    await active.sendKeys("C-u");
    await typeLiteral(active, `${control_prefix}👩‍💻Z`);
    footer = await waitForActiveFooter(
      active,
      (text) => text.includes(`${control_prefix}👩‍💻Z`),
    );
    rows = footer.split("\n");
    expect(rowContaining(rows, `${control_prefix}👩‍💻Z`).line).toContain("👩‍💻Z");

    expectCleanStderr();
    expect(active.isAlive()).toBe(true);
  },
  TIMEOUT,
);

tmuxTest(
  "tab edge wrapping handles final cells, wide runes, and following units",
  async () => {
    const active = await startFx(10, 24);

    await active.pasteText("\tX");
    await active.waitForPane((pane) => pane.includes("X"), READY_TIMEOUT);
    await active.waitForCursor((position) => position.col === 9, READY_TIMEOUT);

    await active.sendKeys("C-u");
    await active.pasteText("aaaaaa\t界");
    await active.waitForPane((pane) => pane.includes("界"), READY_TIMEOUT);
    let grid = await active.capturePaneGrid();
    const wide = rowContaining(grid, "界");
    expect(wide.line.indexOf("界")).toBe(2);

    await active.sendKeys("C-u");
    await active.pasteText("aaaaaa\tXY");
    await active.waitForPane((pane) => pane.includes("Y"), READY_TIMEOUT);
    grid = await active.capturePaneGrid();
    const first = rowContaining(grid, "aaaaaa");
    const wrapped = rowContaining(grid, "Y");
    // "XY" is a word: it wraps whole instead of splitting after "X".
    expect(first.line).not.toContain("X");
    expect(wrapped.index).toBe(first.index + 1);
    expect(wrapped.line.indexOf("XY")).toBe(2);
  },
  TIMEOUT,
);

tmuxTest(
  "large tabbed paste keeps frame scroll plan aligned",
  async () => {
    const prompt = largeTabbedPaste();
    expect(new TextEncoder().encode(prompt)).toHaveLength(1003);
    expect(prompt.match(/\t/g)).toHaveLength(21);

    const active = await startFx(72, 16, true, true);
    const tapePath = join(testHome!, "session.fxtape");
    await active.pasteText(prompt);
    await active.waitForText("[Pasted text #1, 11 lines]", READY_TIMEOUT);
    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => pane.includes("history prompt complete") && pane.includes("❯"),
      READY_TIMEOUT,
    );

    expect(active.isAlive()).toBe(true);
    expectCleanStderr();
    expect(gateway?.requests).toHaveLength(1);

    const messages = JSON.parse(gateway!.requests[0]!.body).prompt as Array<{
      role: string;
      content: Array<{ type: string; text?: string }>;
    }>;
    const finalUser = messages[messages.length - 1];
    expect(finalUser?.role).toBe("user");
    expect(finalUser?.content[0]?.text).toBe(prompt);

    const scrollback = await active.captureFullScrollback();
    const promptTail = scrollback.indexOf("TAB_START_0085");
    const response = scrollback.indexOf("history prompt complete");
    expect(promptTail).toBeGreaterThanOrEqual(0);
    expect(response).toBeGreaterThan(promptTail);

    const trace = readFileSync(join(testHome!, "trace.log"), "utf8");
    expect(trace).toContain("document_append_plan");
    expect(trace).not.toContain("InvalidFrameScrollPlan");
    expect(trace).not.toContain("AnsiBandOverflow");
    expect(trace).not.toContain("frame_owner_violation");

    const goldenPath = join(testHome!, "replay-grid.txt");
    const replay = await runFx(["replay", tapePath, "--golden", goldenPath], {
      cwd: REPO_ROOT,
      timeoutMs: READY_TIMEOUT,
    });
    expect(replay.code).toBe(0);
    expect(replay.stderr).toBe("");
    const gridText = readFileSync(goldenPath, "utf8");
    const failures: string[] = [];
    assertPaneContains(gridText, "history prompt complete", failures, "replay grid");
    assertSingleFooter(gridText.replace(/\n$/, "").split("\n"), failures, "replay grid");
    expect(failures).toEqual([]);
  },
  TIMEOUT,
);

tmuxTest(
  "long short long vertical movement restores the original preferred column",
  async () => {
    const active = await startFx(80, 24);
    await typeLiteral(active, "abcdefghijklmnop");
    await active.sendKeys("M-Enter");
    await typeLiteral(active, "xy");
    await active.sendKeys("M-Enter");
    await typeLiteral(active, "abcdefghijklmnop");
    await active.waitForPane((pane) => pane.includes("xy"), READY_TIMEOUT);

    const bottom = await active.waitForCursor((position) => position.col > 12, READY_TIMEOUT);
    await active.sendKeys("Up");
    await active.waitForCursor((position) => position.row === bottom.row - 1 && position.col < bottom.col, READY_TIMEOUT);
    await active.sendKeys("Down");
    await active.waitForCursor(
      (position) => position.row === bottom.row && position.col === bottom.col,
      READY_TIMEOUT,
    );
  },
  TIMEOUT,
);

tmuxTest(
  "plain arrows navigate recalled multiline history before crossing entries",
  async () => {
    const active = await startFx(60, 24, true, false, 2);
    await setupMultilinePromptHistory(active);
    await typeTwoRowDraft(active);

    const bottom = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendKeys("Up");
    await active.waitForCursor((position) => position.row === bottom.row - 1, READY_TIMEOUT);
    await active.sendKeys("Up");
    await active.waitForCursor((position) => position.col === 2, READY_TIMEOUT);
    await active.sendKeys("Up");
    let footer = await waitForActiveFooter(
      active,
      (text) => text.includes("newer top") && text.includes("newer bottom"),
    );
    expect(footer).not.toContain("older");
    await active.waitForCursor(
      (position) => position.col === 2 + "newer bottom".length,
      READY_TIMEOUT,
    );

    await active.sendKeys("Left");
    const recalledBottom = await active.waitForCursor(
      (position) => position.col === 1 + "newer bottom".length,
      READY_TIMEOUT,
    );
    await active.sendKeys("Up");
    await active.waitForCursor(
      (position) => position.row === recalledBottom.row - 1,
      READY_TIMEOUT,
    );
    footer = await waitForActiveFooter(
      active,
      (text) => text.includes("newer top") && text.includes("newer bottom"),
    );
    expect(footer).not.toContain("older");

    await active.sendKeys("Up");
    await active.waitForCursor((position) => position.col === 2, READY_TIMEOUT);
    await active.sendKeys("Up");
    footer = await waitForActiveFooter(active, (text) => text.includes("❯ older"));
    expect(footer).not.toContain("newer top");
    expect(footer).not.toContain("newer bottom");
    await active.waitForCursor(
      (position) => position.col === 2 + "older".length,
      READY_TIMEOUT,
    );

    await active.sendKeys("Down");
    footer = await waitForActiveFooter(
      active,
      (text) => text.includes("newer top") && text.includes("newer bottom"),
    );
    expect(footer).not.toContain("older");
    await active.waitForCursor(
      (position) => position.col === 2 + "newer bottom".length,
      READY_TIMEOUT,
    );

    await active.sendKeys("Down");
    footer = await waitForActiveFooter(
      active,
      (text) => text.includes("draft") && text.includes("tail"),
    );
    expect(footer).not.toContain("newer top");
    expect(footer).not.toContain("newer bottom");
    await active.waitForCursor(
      (position) => position.row === bottom.row && position.col === bottom.col,
      READY_TIMEOUT,
    );
    expect(active.isAlive()).toBe(true);
    expectCleanStderr();
  },
  TIMEOUT,
);

tmuxTest(
  "composer word editing keeps Option and Ctrl deletion contracts separate",
  async () => {
    const active = await startFx(80, 24);

    await typeLiteral(active, "hello world");
    await active.sendHexBytes(hexSeq("\x1b[98;3u"));
    await typeLiteral(active, "!");
    await active.waitForPane((pane) => pane.includes("hello !world"), READY_TIMEOUT);
    await active.sendHexBytes(hexSeq("\x1b[102;3u"));
    await typeLiteral(active, "!");
    await active.waitForPane((pane) => pane.includes("hello !world!"), READY_TIMEOUT);

    await active.sendKeys("C-a");
    await active.sendHexBytes(hexSeq("\x1bf"));
    await typeLiteral(active, "?");
    await active.waitForPane((pane) => pane.includes("hello? !world!"), READY_TIMEOUT);

    await active.sendKeys("C-u");
    await typeLiteral(active, "foo-bar");
    await active.sendHexBytes(hexSeq("\x1b[119;5u"));
    await active.waitForCursor((position) => position.col === 2, READY_TIMEOUT);

    await active.sendHexBytes(["19"]);
    await active.waitForPane((pane) => pane.includes("foo-bar"), READY_TIMEOUT);

    await active.sendHexBytes(hexSeq("\x1b[127;3u"));
    await active.waitForPane((pane) => pane.includes("foo-"), READY_TIMEOUT);
    expect(active.isAlive()).toBe(true);
  },
  TIMEOUT,
);

tmuxTest(
  "composer aliases edit through raw controls and meta delete",
  async () => {
    const active = await startFx(80, 24, true);

    await setupPromptHistory(active);
    await typeLiteral(active, "draft");
    await active.sendHexBytes(["10"]);
    await active.waitForPane((pane) => pane.includes("❯ zz-history"), READY_TIMEOUT);
    await active.sendHexBytes(["0e"]);
    await active.waitForPane((pane) => pane.includes("draft"), READY_TIMEOUT);
    await active.sendKeys("C-u");

    await typeLiteral(active, "abcd");
    await active.sendHexBytes(["02"]);
    await active.sendHexBytes(["02"]);
    await active.sendHexBytes(["06"]);
    await typeLiteral(active, "X");
    await active.waitForPane((pane) => pane.includes("abcXd"), READY_TIMEOUT);

    await active.sendHexBytes(["04"]);
    await active.waitForPane((pane) => pane.includes("abcX"), READY_TIMEOUT);

    await active.sendKeys("C-u");
    await typeLiteral(active, "alpha beta");
    await active.sendKeys("C-a");
    await active.sendHexBytes(hexSeq("\x1bd"));
    await active.waitForPane((pane) => pane.includes("beta"), READY_TIMEOUT);

    await active.sendKeys("C-u");
    await typeLiteral(active, "one\\");
    await active.sendKeys("Enter");
    await typeLiteral(active, "two");
    await active.waitForPane((pane) => pane.includes("one") && pane.includes("two"), READY_TIMEOUT);

    expect(active.isAlive()).toBe(true);
    expectCleanStderr();
  },
  TIMEOUT,
);

tmuxTest(
  "Ctrl+W edit of recalled history preserves the unsent draft",
  async () => {
    const active = await startFx(60, 24, true);
    await setupPromptHistory(active);
    await typeLiteral(active, "draft");
    await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);

    await active.sendKeys("Up");
    await active.waitForCursor((position) => position.col === 2, READY_TIMEOUT);
    await active.sendKeys("Up");
    await active.waitForPane((pane) => pane.includes("❯ zz-history"), READY_TIMEOUT);
    await active.sendHexBytes(["17"]);
    await active.waitForCursor((position) => position.col === 2, READY_TIMEOUT);

    await active.sendKeys("Down");
    await waitForActiveFooter(active, (footer) => footer === "❯ draft");
    await active.waitForCursor(
      (position) => position.col === 2 + "draft".length,
      READY_TIMEOUT,
    );
    expect(active.isAlive()).toBe(true);
    expectCleanStderr();
  },
  TIMEOUT,
);

tmuxTest(
  "Ctrl+L redraws without clearing the draft or session",
  async () => {
    const active = await startFx(80, 24, true, true, 2);
    await setupPromptHistory(active);
    const draft = "CTRL_L_UNSENT_DRAFT";
    await typeLiteral(active, draft);
    await waitForActiveFooter(active, (footer) => footer === `❯ ${draft}`);

    await active.sendKeys("C-l");
    const footer = await waitForActiveFooter(
      active,
      (visible) => visible === `❯ ${draft}`,
    );
    expect(footer).toBe(`❯ ${draft}`);
    await delay(100);
    expect(readFileSync(join(testHome!, "trace.log"), "utf8")).toContain(
      "visual_epoch_reset_requested trigger=ctrl_l",
    );
    expect(gateway?.requests).toHaveLength(1);

    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => gateway?.requests.length === 2 && pane.includes("history prompt complete"),
      READY_TIMEOUT,
    );
    const followup = gateway!.requests[1]!.body;
    expect(followup).toContain("zz-history");
    expect(followup).toContain("history prompt complete");
    expect(followup).toContain(draft);
    expect(active.isAlive()).toBe(true);
    expectCleanStderr();
  },
  TIMEOUT,
);

tmuxTest(
  "delivered Command and Shift+Option keys edit the composer",
  async () => {
    const active = await startFx(60, 24);
    await typeLiteral(active, "alpha beta");

    await active.sendHexBytes(hexSeq("\x1b[1;9D"));
    await typeLiteral(active, "(");
    await active.sendHexBytes(hexSeq("\x1b[1;9C"));
    await typeLiteral(active, ")");
    await waitForActiveFooter(active, (footer) => footer === "❯ (alpha beta)");

    await active.sendHexBytes(hexSeq("\x1b[1;4D"));
    await typeLiteral(active, "X");
    await waitForActiveFooter(active, (footer) => footer === "❯ (alpha X");

    await active.sendHexBytes(hexSeq("\x1b[97;9u"));
    await typeLiteral(active, "Y");
    await waitForActiveFooter(active, (footer) => footer === "❯ Y");
    await active.sendHexBytes(hexSeq("\x1b[122;9u"));
    await waitForActiveFooter(active, (footer) => footer === "❯ (alpha X");
    await active.sendHexBytes(hexSeq("\x1b[122;10u"));
    await waitForActiveFooter(active, (footer) => footer === "❯ Y");
    await typeLiteral(active, "Z");
    await active.sendHexBytes(hexSeq("\x1b[95;5u"));
    await waitForActiveFooter(active, (footer) => footer === "❯ Y");
    await typeLiteral(active, "Q");
    await active.sendHexBytes(hexSeq("\x1b[27;5;95~"));
    await waitForActiveFooter(active, (footer) => footer === "❯ Y");

    expect(active.isAlive()).toBe(true);
    expectCleanStderr();
  },
  TIMEOUT,
);

tmuxTest(
  "draft-edge movement resets preferred-column intent",
  async () => {
    const active = await startFx(80, 24);
    await typeLiteral(active, "abcdefghijklmnop");
    await active.sendKeys("M-Enter");
    await typeLiteral(active, "xy");
    await active.sendKeys("M-Enter");
    await typeLiteral(active, "abcdefghijklmnop");
    await active.waitForPane((pane) => pane.includes("xy"), READY_TIMEOUT);

    const bottom = await active.waitForCursor((position) => position.col > 12, READY_TIMEOUT);
    await active.sendKeys("Up");
    await active.waitForCursor((position) => position.row === bottom.row - 1 && position.col < bottom.col, READY_TIMEOUT);
    await active.sendHexBytes(hexSeq("\x1b[1;9A"));
    await active.sendKeys("Left");
    await active.sendKeys("Down");
    await active.waitForCursor((position) => position.col === 2, READY_TIMEOUT);

    await active.sendHexBytes(hexSeq("\x1b[1;9B"));
    await active.sendKeys("Right");
    expect(active.isAlive()).toBe(true);
  },
  TIMEOUT,
);

tmuxTest(
  "no-op modified Down at input end resets preferred-column intent",
  async () => {
    const active = await startFx(80, 24);
    await typeLiteral(active, "abcdef");
    await active.sendKeys("M-Enter");
    await active.waitForCursor((position) => position.col === 2, READY_TIMEOUT);

    await active.sendKeys("Left");
    const topEnd = await active.waitForCursor((position) => position.col > 6, READY_TIMEOUT);
    await active.sendKeys("Down");
    await active.waitForCursor(
      (position) => position.row === topEnd.row + 1 && position.col === 2,
      READY_TIMEOUT,
    );

    await active.sendHexBytes(hexSeq("\x1b[1;2B"));
    await active.sendKeys("Up");
    await active.waitForCursor(
      (position) => position.row === topEnd.row && position.col === 2,
      READY_TIMEOUT,
    );
  },
  TIMEOUT,
);

tmuxTest(
  "resize between consecutive vertical moves resets preferred-column intent",
  async () => {
    const active = await startFx(80, 24);
    await typeLiteral(active, "abcdefghijklmnop");
    await active.sendKeys("M-Enter");
    await typeLiteral(active, "xy");
    await active.sendKeys("M-Enter");
    await typeLiteral(active, "abcdefghijklmnop");
    await active.waitForPane((pane) => pane.includes("xy"), READY_TIMEOUT);
    const bottom = await active.waitForCursor((position) => position.col > 12, READY_TIMEOUT);

    await active.sendKeys("Up");
    const short = await active.waitForCursor((position) => position.row === bottom.row - 1, READY_TIMEOUT);
    await active.resizeWindow(72, 24, 300);
    await active.waitForPane((pane) => pane.includes("xy"), READY_TIMEOUT);
    const resizedShort = await active.waitForCursor(
      (position) => position.col === short.col,
      READY_TIMEOUT,
    );
    await active.sendKeys("Down");
    await active.waitForCursor(
      (position) => position.row === resizedShort.row + 1,
      READY_TIMEOUT,
    );
  },
  TIMEOUT,
);

tmuxTest(
  "long capped input keeps the cursor-containing rows visible",
  async () => {
    const active = await startFx(40, 12);
    const text = Array.from({ length: 20 }, (_, idx) =>
      `line-${String(idx + 1).padStart(2, "0")}`
    ).join("\n");
    await active.pasteText(text);
    await active.waitForPane(
      (pane) => pane.includes("line-20") && pane.includes("line-19"),
      READY_TIMEOUT,
    );
    await active.sendKeys("Up");
    await active.waitForPane(
      (pane) => pane.includes("line-19") && pane.includes("line-18"),
      READY_TIMEOUT,
    );
  },
  TIMEOUT,
);

tmuxTest(
  "typed pasted and slash-command images share the queued Gateway and session contract",
  async () => {
    testHome = mkdtempSync(join(tmpdir(), "fx-tui-input-"));
    stderrPath = join(testHome, "stderr.log");
    writeFileSync(stderrPath, "");
    const workspacePath = join(testHome, "workspace");
    mkdirSync(workspacePath, { recursive: true });
    const workspace = realpathSync(workspacePath);
    const nested = join(workspace, "assets", "nested");
    const sibling = join(workspace, "sibling");
    mkdirSync(nested, { recursive: true });
    mkdirSync(sibling, { recursive: true });
    const scopedImagePath = join(nested, "fixture.png");
    copyFileSync(imageFixture, scopedImagePath);
    const scopedImage = realpathSync(scopedImagePath);
    const rootRule = "TUI_IMAGE_CONTEXT_ROOT_SENTINEL";
    const nestedRule = "TUI_IMAGE_CONTEXT_NESTED_SENTINEL";
    const siblingRule = "TUI_IMAGE_CONTEXT_SIBLING_MUST_BE_ABSENT";
    writeFileSync(join(workspace, "AGENTS.md"), `${rootRule}\n`);
    writeFileSync(join(nested, "AGENTS.md"), `${nestedRule}\n`);
    writeFileSync(join(sibling, "AGENTS.md"), `${siblingRule}\n`);
    const expectScopedContext = (body: string) => {
      expect(body).toContain(rootRule);
      expect(body).toContain(nestedRule);
      expect(body).not.toContain(siblingRule);
      expect(body.indexOf(rootRule)).toBeLessThan(body.indexOf(nestedRule));
    };
    const localGateway = startFakeGateway(
      [
        fakeGatewayFinalText("IMAGE_TYPED_OK"),
        fakeGatewayFinalText("IMAGE_PASTED_OK"),
        fakeGatewayFinalText("IMAGE_COMMAND_OK"),
      ],
      {
        models: [{
          id: FAKE_GATEWAY_MODEL,
          type: "language",
          tags: ["vision", "file-input", "tool-use"],
        }],
      },
    );
    gateway = localGateway;
    const active = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: workspace,
      env: {
        HOME: testHome,
        AI_GATEWAY_API_KEY: "fake-image-input-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: localGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: localGateway.chatUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${localGateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
      },
      width: 100,
      height: 24,
      stderrPath,
    });
    session = active;
    await active.waitForComposer(READY_TIMEOUT);

    await typeLiteral(active, scopedImage);
    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => pane.includes("IMAGE_TYPED_OK") && hasEmptyComposer(pane),
      READY_TIMEOUT,
    );
    expect(localGateway.requests).toHaveLength(1);
    expect(localGateway.requests[0]?.body).toContain('"type":"file"');
    expect(localGateway.requests[0]?.body).not.toContain(scopedImage);
    expectScopedContext(localGateway.requests[0]!.body);

    await active.pasteText(scopedImage);
    await waitForActiveFooter(
      active,
      (footer) => footer.includes("[Image 2]"),
    );
    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => pane.includes("IMAGE_PASTED_OK") && hasEmptyComposer(pane),
      READY_TIMEOUT,
    );
    expect(localGateway.requests).toHaveLength(2);
    expect(localGateway.requests[1]?.body).toContain('"type":"file"');
    expect(localGateway.requests[1]?.body).not.toContain(scopedImage);
    expectScopedContext(localGateway.requests[1]!.body);

    await typeLiteral(active, `/image ${scopedImage}`);
    await active.sendKeys("Enter");
    await waitForActiveFooter(
      active,
      (footer) => footer.includes("[Image 3]"),
    );
    expect(localGateway.requests).toHaveLength(2);
    await typeLiteral(active, " describe via command");
    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => pane.includes("IMAGE_COMMAND_OK") && hasEmptyComposer(pane),
      READY_TIMEOUT,
    );
    expect(localGateway.requests).toHaveLength(3);
    expect(localGateway.requests[2]?.body).toContain('"type":"file"');
    expect(localGateway.requests[2]?.body).not.toContain(scopedImage);
    expectScopedContext(localGateway.requests[2]!.body);

    const escapes = await active.captureFullScrollbackEscapes();
    expect(escapes).toContain("\x1b]8;;file://");
    expect(escapes).toContain("[Image 1]");
    expect(escapes).toContain("\x1b]8;;\x1b\\");

    const listed = await runFx(["sessions", "--json"], {
      cwd: workspace,
      env: { HOME: testHome },
      timeoutMs: READY_TIMEOUT,
    });
    expect(listed.code).toBe(0);
    const sessionId = JSON.parse(listed.stdout).sessions[0]?.id as string | undefined;
    expect(sessionId).toBeDefined();
    const readImageTurns = async () => {
      const detailResult = await runFx(["session", "--id", sessionId!, "--json"], {
        cwd: workspace,
        env: { HOME: testHome },
        timeoutMs: READY_TIMEOUT,
      });
      expect(detailResult.code).toBe(0);
      const detail = JSON.parse(detailResult.stdout) as {
        history: Array<{
          user?: { images: Array<{ path: string; media_type: string }> };
        }>;
      };
      return detail.history.filter((turn) => turn.user?.images.length === 1).slice(-3);
    };
    const detailDeadline = Date.now() + READY_TIMEOUT;
    let imageTurns = await readImageTurns();
    while (imageTurns.length < 3 && Date.now() < detailDeadline) {
      await Bun.sleep(25);
      imageTurns = await readImageTurns();
    }
    expect(imageTurns).toHaveLength(3);
    for (const turn of imageTurns) {
      expect(turn.user!.images[0]).toEqual({
        path: scopedImage,
        media_type: "image/png",
      });
    }

    expectCleanStderr();
    expect(active.isAlive()).toBe(true);
  },
  TIMEOUT,
);

tmuxTest(
  "registered slash command stays local behind a pending image",
  async () => {
    const active = await startFx(100, 24, true);
    const image = realpathSync(imageFixture);

    await typeLiteral(active, `/image ${image}`);
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("[Image 1]"), READY_TIMEOUT);
    expect(gateway?.requests).toHaveLength(0);

    await typeLiteral(active, "/status");
    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => pane.includes("model=") && pane.includes("[Image 1]"),
      READY_TIMEOUT,
    );

    expect(gateway?.requests).toHaveLength(0);
    const composer = (await active.capturePaneGrid())
      .filter(isComposerLine)
      .at(-1);
    expect(composer).toContain("[Image 1]");
    expect(composer).not.toContain("/status");
    expectCleanStderr();
    expect(active.isAlive()).toBe(true);
  },
  TIMEOUT,
);

tmuxTest(
  "repeated image commands stay local and submit together as one prompt",
  async () => {
    testHome = mkdtempSync(join(tmpdir(), "fx-tui-input-"));
    stderrPath = join(testHome, "stderr.log");
    writeFileSync(stderrPath, "");
    const workspace = mkdtempSync(join(tmpdir(), "fx-tui-images-"));
    const firstPath = join(workspace, "first.png");
    const secondPath = join(workspace, "second.png");
    copyFileSync(imageFixture, firstPath);
    copyFileSync(imageFixture, secondPath);
    const first = realpathSync(firstPath);
    const second = realpathSync(secondPath);

    const localGateway = startFakeGateway(
      [fakeGatewayFinalText("Both images received.")],
      {
        models: [{
          id: FAKE_GATEWAY_MODEL,
          type: "language",
          tags: ["vision", "file-input", "tool-use"],
        }],
      },
    );
    gateway = localGateway;
    const active = await TmuxSession.create({
      cmd: FX_BIN,
      env: {
        HOME: testHome,
        AI_GATEWAY_API_KEY: "fake-repeated-image-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: localGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: localGateway.chatUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${localGateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
      },
      width: 100,
      height: 24,
      stderrPath,
    });
    session = active;
    await active.waitForComposer(READY_TIMEOUT);

    await typeLiteral(active, `/image ${first}`);
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("[Image 1]"), READY_TIMEOUT);
    expect(localGateway.requests).toHaveLength(0);

    await typeLiteral(active, `/image ${second}`);
    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => pane.includes("[Image 1]") && pane.includes("[Image 2]"),
      READY_TIMEOUT,
    );
    expect(localGateway.requests).toHaveLength(0);

    const attachedGrid = await active.capturePaneGrid();
    const attachedComposer = attachedGrid.filter(isComposerLine).at(-1);
    expect(attachedComposer).toBeDefined();
    expect(attachedComposer).toContain("[Image 1]");
    expect(attachedComposer).toContain("[Image 2]");
    expect(attachedComposer).not.toContain("/image");
    expect(attachedComposer).not.toContain(second);

    await typeLiteral(active, "/images");
    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => pane.includes("● Images: 2 pending"),
      READY_TIMEOUT,
    );
    expect(localGateway.requests).toHaveLength(0);

    await typeLiteral(active, " describe both");
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("Both images received."), READY_TIMEOUT);

    expect(localGateway.requests).toHaveLength(1);
    const body = localGateway.requests[0]!.body;
    const fileParts = body.match(/"type":"file"/g) ?? [];
    expect(fileParts).toHaveLength(2);
    expect(body).not.toContain("/image ");
    expect(body).not.toContain(first);
    expect(body).not.toContain(second);
    expect(body).not.toContain(workspace);
    expect(body).not.toContain("file://");
    expect(body).not.toContain("data:image");
    expect(body).toContain("describe both");

    const fullScrollback = await active.captureFullScrollback();
    expect(fullScrollback).toContain("● Images: 2 pending");
    expect(fullScrollback).toContain("Both images received.");
    expect(fullScrollback).not.toContain("ImageContextAdapterFailed");
    expect(fullScrollback.match(/describe both/g) ?? []).toHaveLength(1);

    const finalGrid = await active.capturePaneGrid();
    const finalComposer = finalGrid.filter(isComposerLine).at(-1);
    expect(finalComposer).toBeDefined();
    expect(finalComposer).not.toContain("[Image 1]");
    expect(finalComposer).not.toContain("[Image 2]");

    expectCleanStderr();
    expect(active.isAlive()).toBe(true);
    rmSync(workspace, { recursive: true, force: true });
  },
  TIMEOUT,
);

tmuxTest(
  "a later turn's image keeps its own id in the composer and transcript",
  async () => {
    testHome = mkdtempSync(join(tmpdir(), "fx-tui-input-"));
    stderrPath = join(testHome, "stderr.log");
    writeFileSync(stderrPath, "");
    const workspace = mkdtempSync(join(tmpdir(), "fx-tui-image-ids-"));
    const firstPath = join(workspace, "one.png");
    const secondPath = join(workspace, "two.png");
    copyFileSync(imageFixture, firstPath);
    copyFileSync(imageFixture, secondPath);
    const first = realpathSync(firstPath);
    const second = realpathSync(secondPath);

    const localGateway = startFakeGateway(
      [
        fakeGatewayFinalText("turn 1 complete"),
        fakeGatewayFinalText("turn 2 complete"),
      ],
      {
        models: [{
          id: FAKE_GATEWAY_MODEL,
          type: "language",
          tags: ["vision", "file-input", "tool-use"],
        }],
      },
    );
    gateway = localGateway;
    const active = await TmuxSession.create({
      cmd: FX_BIN,
      env: {
        HOME: testHome,
        AI_GATEWAY_API_KEY: "fake-image-id-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: localGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: localGateway.chatUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${localGateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
      },
      width: 120,
      height: 36,
      stderrPath,
    });
    session = active;
    await active.waitForComposer(READY_TIMEOUT);

    await typeLiteral(active, `/image ${first}`);
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("[Image 1]"), READY_TIMEOUT);
    await typeLiteral(active, " first turn");
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("turn 1 complete"), READY_TIMEOUT);

    await typeLiteral(active, `/image ${second}`);
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("[Image 2]"), READY_TIMEOUT);

    const attachedGrid = await active.capturePaneGrid();
    const attachedComposer = attachedGrid.filter(isComposerLine).at(-1);
    expect(attachedComposer).toBeDefined();
    expect(attachedComposer).toContain("[Image 2]");
    expect(attachedComposer).not.toContain("[Image 1]");

    await typeLiteral(active, " second turn");
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("turn 2 complete"), READY_TIMEOUT);

    await active.resizeWindow(88, 24);
    const resized = await active.captureFullScrollback();
    expect(resized).toContain("[Image 1] first turn");
    expect(resized).toContain("[Image 2] second turn");
    expect(resized).not.toContain("[Image 1] second turn");

    // The second request replays turn 1, so it carries both placeholders. What
    // matters is that each turn's text is paired with its own image id.
    expect(localGateway.requests).toHaveLength(2);
    const firstBody = localGateway.requests[0]!.body;
    const secondBody = localGateway.requests[1]!.body;
    expect(firstBody).toContain("[Image #1] first turn");
    expect(secondBody).toContain("[Image #1] first turn");
    expect(secondBody).toContain("[Image #2] second turn");
    expect(secondBody).not.toContain("[Image #1] second turn");
    for (const body of [firstBody, secondBody]) {
      expect(body).not.toContain(workspace);
      expect(body).not.toContain("file://");
      expect(body).not.toContain("data:image");
    }

    expectCleanStderr();
    expect(active.isAlive()).toBe(true);
    rmSync(workspace, { recursive: true, force: true });
  },
  TIMEOUT,
);

tmuxTest(
  "image line kill and repeated yank preserve captured bytes under fresh ids",
  async () => {
    testHome = mkdtempSync(join(tmpdir(), "fx-tui-input-"));
    stderrPath = join(testHome, "stderr.log");
    writeFileSync(stderrPath, "");
    const workspace = mkdtempSync(join(tmpdir(), "fx-tui-image-yank-"));
    const sourcePath = join(workspace, "source.png");
    copyFileSync(imageFixture, sourcePath);
    const source = realpathSync(sourcePath);
    const originalBase64 = readFileSync(source).toString("base64");

    const localGateway = startFakeGateway(
      [fakeGatewayFinalText("YANKED_IMAGES_OK")],
      {
        models: [{
          id: FAKE_GATEWAY_MODEL,
          type: "language",
          tags: ["vision", "file-input", "tool-use"],
        }],
      },
    );
    gateway = localGateway;
    const active = await TmuxSession.create({
      cmd: FX_BIN,
      env: {
        HOME: testHome,
        AI_GATEWAY_API_KEY: "fake-image-yank-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: localGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: localGateway.chatUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${localGateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
      },
      width: 100,
      height: 24,
      stderrPath,
    });
    session = active;
    await active.waitForComposer(READY_TIMEOUT);

    await typeLiteral(active, `/image ${source}`);
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("[Image 1]"), READY_TIMEOUT);
    rmSync(source);

    await active.sendHexBytes(hexSeq("\x15"));
    await active.waitForPane(hasEmptyComposer, READY_TIMEOUT);
    await active.sendHexBytes(hexSeq("\x19"));
    await active.waitForPane((pane) => pane.includes("[Image 2]"), READY_TIMEOUT);
    await active.sendHexBytes(hexSeq("\x19"));
    await active.waitForPane(
      (pane) => pane.includes("[Image 2]") && pane.includes("[Image 3]"),
      READY_TIMEOUT,
    );

    await typeLiteral(active, " inspect both yanks");
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("YANKED_IMAGES_OK"), READY_TIMEOUT);

    expect(localGateway.requests).toHaveLength(1);
    const body = localGateway.requests[0]!.body;
    expect(body.match(/"type":"file"/g) ?? []).toHaveLength(2);
    expect(body.split(originalBase64).length - 1).toBe(2);
    expect(body).toContain("[Image #2][Image #3] inspect both yanks");
    expect(body).not.toContain(source);
    expect(body).not.toContain(workspace);
    expect(body).not.toContain("file://");
    expectCleanStderr();
    expect(active.isAlive()).toBe(true);
    rmSync(workspace, { recursive: true, force: true });
  },
  TIMEOUT,
);

tmuxTest(
  "pending image commands stay local",
  async () => {
    testHome = mkdtempSync(join(tmpdir(), "fx-tui-input-"));
    stderrPath = join(testHome, "stderr.log");
    writeFileSync(stderrPath, "");
    const localGateway = startFakeGateway(
      [],
      {
        models: [{
          id: FAKE_GATEWAY_MODEL,
          type: "language",
          tags: ["vision", "file-input", "tool-use"],
        }],
      },
    );
    gateway = localGateway;
    const active = await TmuxSession.create({
      cmd: FX_BIN,
      env: {
        HOME: testHome,
        AI_GATEWAY_API_KEY: "fake-pending-image-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: localGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: localGateway.chatUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${localGateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
      },
      width: 100,
      height: 24,
      stderrPath,
    });
    session = active;
    await active.waitForComposer(READY_TIMEOUT);

    await typeLiteral(active, `/image ${imageFixture}`);
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("[Image 1]"), READY_TIMEOUT);
    expect(localGateway.requests).toHaveLength(0);

    await typeLiteral(active, "/images");
    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => pane.includes("● Images: 1 pending") && pane.includes("favicon.png (image/png)"),
      READY_TIMEOUT,
    );
    expect(localGateway.requests).toHaveLength(0);
    const listedGrid = await active.capturePaneGrid();
    expect(listedGrid.some((line) => isComposerLine(line) && line.includes("[Image 1]"))).toBe(true);

    await typeLiteral(active, "/images clear");
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("cleared pending images"), READY_TIMEOUT);
    expect(localGateway.requests).toHaveLength(0);
    const clearedGrid = await active.capturePaneGrid();
    const currentComposer = clearedGrid.filter(isComposerLine).at(-1);
    expect(currentComposer).toBeDefined();
    expect(currentComposer).not.toContain("[Image 1]");

    const fullScrollback = await active.captureFullScrollback();
    expect(fullScrollback).toContain("● Images: 1 pending");
    expect(fullScrollback).toContain("favicon.png (image/png)");
    expect(fullScrollback).toContain("cleared pending images");
    expect(fullScrollback).not.toContain("ImageContextAdapterFailed");
    expectCleanStderr();
    expect(active.isAlive()).toBe(true);
  },
  TIMEOUT,
);

tmuxTest(
  "repeated image-path paste cannot grow direct input past the cap and leaves fx alive",
  async () => {
    const active = await startFx(120, 24);
    await active.pasteText(repeatedImagePaste(80));
    await active.waitForPane((pane) => pane.includes("[Image 1]"), READY_TIMEOUT);
    expect(active.isAlive()).toBe(true);
  },
  TIMEOUT,
);

tmuxTest(
  "unknown and overflowing image placeholders stay literal and vertically targetable",
  async () => {
    const active = await startFx(60, 24);
    await typeLiteral(active, "[Image #999999999999999999999999999999999999]");
    await active.sendKeys("M-Enter");
    await typeLiteral(active, "tail");
    await active.waitForPane(
      (pane) => pane.includes("[Image #999999999999999999999999999999999999]") &&
        pane.includes("tail"),
      READY_TIMEOUT,
    );
    const bottom = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendKeys("Up");
    await active.waitForCursor((position) => position.row === bottom.row - 1, READY_TIMEOUT);
    await active.sendKeys("Down");
    await active.waitForCursor((position) => position.row === bottom.row, READY_TIMEOUT);
  },
  TIMEOUT,
);

tmuxTest(
  "top-level slash and /mo completion rows stay left anchored",
  async () => {
    const active = await startFx(80, 24);
    await typeLiteral(active, "/");
    await expectOptionColumn(active, "/help", 2);
    await active.sendKeys("C-u");
    await typeLiteral(active, "/mo");
    await expectOptionColumn(active, "/model", 2);
  },
  TIMEOUT,
);

tmuxTest(
  "positive slash argument picker uses exact rendered columns",
  async () => {
    const active = await startFx(80, 24);
    await typeLiteral(active, "  /sandbox ");
    await expectOptionColumn(active, "os", 13);

    // Margin spaces hang on row 0 while the slash command wraps below them.
    await active.resizeWindow(8, 6, 300);
    await active.sendKeys("C-u");
    await typeLiteral(active, "       /sandbox ");
    await expectOptionColumn(active, "non", 5);
  },
  TIMEOUT,
);

tmuxTest(
  "maxxing minimal connects the composer and submitted prompt rails without changing input appearance",
  async () => {
    testHome = mkdtempSync(join(tmpdir(), "fx-tui-input-"));
    mkdirSync(join(testHome, ".fx"), { recursive: true });
    writeFileSync(
      join(testHome, ".fx", "settings.json"),
      JSON.stringify({ maxxing_mode: "legacy" }),
    );
    const localGateway = startFakeGateway([
      fakeGatewayFinalText("INPUT_TINT_MOCK_OK"),
      fakeGatewayFinalText("MINIMAL_MAXXING_MOCK_OK"),
    ]);
    gateway = localGateway;
    const active = await TmuxSession.create({
      cmd: FX_BIN,
      env: {
        HOME: testHome,
        AI_GATEWAY_API_KEY: "fake-input-appearance-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: localGateway.baseUrl,
        FX_GATEWAY_CHAT_URL: localGateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_AUTO_UPGRADE: "0",
      },
      width: 80,
      height: 24,
    });
    session = active;
    await active.waitForComposer(READY_TIMEOUT);

    await active.sendText("/input");
    await active.waitForPane(
      (pane) =>
        pane.includes("Appearance") &&
        pane.includes("Input appearance") &&
        pane.includes("lines  tint"),
      READY_TIMEOUT,
    );
    await active.sendKeys("Escape");
    await active.waitForComposer(READY_TIMEOUT);

    await active.sendText("/input lines");
    await active.waitForPane((pane) => pane.includes("● Input: switched to lines"), READY_TIMEOUT);
    await active.sendText("/input tint");
    await active.waitForPane((pane) => pane.includes("● Input: switched to tint"), READY_TIMEOUT);
    await typeLiteral(active, "tinted draft");
    await active.waitForPane((pane) => pane.includes("tinted draft"), READY_TIMEOUT);
    const tintedInputRow = rowWithVisiblePredicate(
      await active.capturePaneEscapes(),
      (visible) => visible.includes("❯ tinted draft"),
    );
    expect(rowHasBackgroundSgr(tintedInputRow)).toBe(true);
    const tintedGrid = await active.capturePaneGrid();
    const tintedPosition = rowContaining(tintedGrid, "❯ tinted draft");
    const rowAboveTint = tintedGrid[tintedPosition.index - 1] ?? "";
    expect(rowAboveTint.includes("─")).toBe(false);
    expect(rowAboveTint.trim()).toBe("");
    expect(tintedGrid[tintedPosition.index + 1]?.includes("─")).toBe(true);

    await active.sendKeys("C-u");
    await typeLiteral(active, "/input ");
    await active.waitForPane((pane) => pane.includes("lines") && pane.includes("tint"), READY_TIMEOUT);
    const pickerRow = selectedArgumentLabelRow(await active.capturePaneEscapes(), "tint");
    expect(rowHasBackgroundSgr(pickerRow)).toBe(false);

    await active.sendKeys("C-u");
    await active.sendText("submit while tinted");
    await active.waitForPane(
      (pane) => pane.includes("INPUT_TINT_MOCK_OK") && pane.includes("❯"),
      20_000,
    );
    expect(localGateway.requests.length).toBe(1);
    expect(localGateway.requests[0]?.body).toContain("submit while tinted");
    const submittedPromptRow = rowWithVisiblePredicate(
      await active.capturePaneEscapes(),
      (visible) => visible.includes("❯ submit while tinted"),
    );
    expect(rowHasBackgroundSgr(submittedPromptRow)).toBe(true);

    await active.sendText("/maxxing minimal");
    await active.waitForPane((pane) => pane.includes("● Maxxing: switched to minimal"), READY_TIMEOUT);
    await typeLiteral(active, "minimal draft");
    await active.waitForPane((pane) => pane.includes("minimal draft"), READY_TIMEOUT);
    const minimalInputRow = rowWithVisiblePredicate(
      await active.capturePaneEscapes(),
      (visible) => visible.includes("┃ minimal draft"),
    );
    expect(rowHasBackgroundSgr(minimalInputRow)).toBe(false);
    expect(minimalInputRow).toContain("\x1b[38;5;255m┃\x1b[39m minimal draft");
    const minimalGrid = await active.capturePaneGrid();
    const minimalPosition = rowContaining(minimalGrid, "┃ minimal draft");
    expect(minimalGrid[minimalPosition.index - 1]?.includes("─")).toBe(false);
    expect(minimalGrid[minimalPosition.index + 1]?.includes("─")).toBe(false);

    await active.sendKeys("C-u");
    const minimalLines = Array.from(
      { length: 10 },
      (_, index) => `COMPOSER_RAIL_${String(index + 1).padStart(2, "0")}`,
    );
    for (const [index, line] of minimalLines.entries()) {
      if (index > 0) await active.sendKeys("M-Enter");
      await typeLiteral(active, line);
    }
    await active.waitForPane((pane) => pane.includes(minimalLines.at(-1)!), READY_TIMEOUT);
    const composerRows = await active.capturePaneEscapes();
    for (const line of minimalLines) {
      const composerRow = rowWithVisiblePredicate(
        composerRows,
        (visible) => visible.includes(`┃ ${line}`),
      );
      expect(rowHasBackgroundSgr(composerRow)).toBe(false);
      expect(composerRow).toContain(`\x1b[38;5;255m┃\x1b[39m ${line}`);
    }

    const minimalSubmission = minimalLines.join("\n");
    await active.sendKeys("Enter");
    await active.waitForPane(
      (pane) => pane.includes("MINIMAL_MAXXING_MOCK_OK") && pane.includes("┃"),
      20_000,
    );
    expect(localGateway.requests.length).toBe(2);
    const minimalRequest = JSON.parse(localGateway.requests[1]!.body).prompt as Array<{
      role: string;
      content: Array<{ type: string; text?: string }>;
    }>;
    const minimalUser = minimalRequest.findLast((message) => message.role === "user");
    expect(minimalUser?.content[0]?.text).toBe(minimalSubmission);
    const minimalTranscript = await active.capturePaneEscapes();
    const minimalPromptFirstRow = rowWithVisiblePredicate(
      minimalTranscript,
      (visible) => visible.includes(`┃ ${minimalLines[0]}`),
    );
    const minimalPromptLastRow = rowWithVisiblePredicate(
      minimalTranscript,
      (visible) => visible.includes(minimalLines.at(-1)!),
    );
    expect(rowHasBackgroundSgr(minimalPromptFirstRow)).toBe(false);
    expect(rowHasBackgroundSgr(minimalPromptLastRow)).toBe(false);
    expect(minimalPromptFirstRow).toContain(`\x1b[38;5;255m┃\x1b[39m \x1b[1m${minimalLines[0]}`);
    expect(minimalPromptLastRow).toContain("\x1b[38;5;255m┃\x1b[39m \x1b[1m");
    expect(stripAnsi(minimalPromptLastRow).trimStart().startsWith("┃ ")).toBe(true);

    await active.sendText("/input lines");
    await active.waitForPane((pane) => pane.includes("● Input: switched to lines"), READY_TIMEOUT);
    await typeLiteral(active, "/input ");
    await active.waitForPane((pane) => pane.includes("lines") && pane.includes("tint"), READY_TIMEOUT);
    const selectedLinesRow = selectedArgumentLabelRow(await active.capturePaneEscapes(), "lines");
    expect(rowHasBackgroundSgr(selectedLinesRow)).toBe(false);
    await active.sendKeys("C-u");

    await typeLiteral(active, "plain draft");
    await active.waitForPane((pane) => pane.includes("plain draft"), READY_TIMEOUT);
    const stillMinimalInputRow = rowWithVisiblePredicate(
      await active.capturePaneEscapes(),
      (visible) => visible.includes("┃ plain draft"),
    );
    expect(rowHasBackgroundSgr(stillMinimalInputRow)).toBe(false);
    expect(stillMinimalInputRow).toContain("\x1b[38;5;255m┃\x1b[39m plain draft");
    const stillMinimalGrid = await active.capturePaneGrid();
    const stillMinimalPosition = rowContaining(stillMinimalGrid, "┃ plain draft");
    expect(stillMinimalGrid[stillMinimalPosition.index - 1]?.includes("─")).toBe(false);
    expect(stillMinimalGrid[stillMinimalPosition.index + 1]?.includes("─")).toBe(false);

    await active.sendKeys("C-u");
    await active.sendText("/maxxing legacy");
    await active.waitForPane((pane) => pane.includes("● Maxxing: switched to legacy"), READY_TIMEOUT);
    await typeLiteral(active, "restored lines draft");
    await active.waitForPane((pane) => pane.includes("restored lines draft"), READY_TIMEOUT);
    const lineGrid = await active.capturePaneGrid();
    const linePosition = rowContaining(lineGrid, "❯ restored lines draft");
    expect(lineGrid[linePosition.index - 1]?.includes("─")).toBe(true);
    expect(lineGrid[linePosition.index + 1]?.includes("─")).toBe(true);

    await active.sendKeys("C-u");
    await active.sendText("/quit");
  },
  60_000,
);

tmuxTest(
  "wrapped slash prefix keeps plain-arrow composer precedence and preserves selection",
  async () => {
    const active = await startFx(8, 10);
    await typeLiteral(active, "       /");
    const end = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendKeys("Up");
    const moved = await active.waitForCursor((position) => position.row === end.row - 1, READY_TIMEOUT);
    await active.sendKeys("Down");
    await active.waitForCursor((position) => position.row === moved.row + 1, READY_TIMEOUT);

    await active.resizeWindow(80, 24, 300);
    await active.waitForPane((pane) => pane.includes("/help"), READY_TIMEOUT);
    await waitForSelectedSlashLabel(active, "/help", READY_TIMEOUT);
  },
  TIMEOUT,
);

tmuxTest(
  "wrapped slash picker does not consume selection-modified arrows",
  async () => {
    const active = await startFx(8, 10);
    await typeLiteral(active, "       /");
    const before = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendHexBytes(hexSeq("\x1b[1;2B"));
    await active.waitForCursor(
      (position) => position.row === before.row && position.col === before.col,
      READY_TIMEOUT,
    );

    await active.resizeWindow(80, 24, 300);
    await active.waitForPane((pane) => pane.includes("/help"), READY_TIMEOUT);
    await waitForSelectedSlashLabel(active, "/help", READY_TIMEOUT);
  },
  TIMEOUT,
);

tmuxTest(
  "wrapped slash prefix submits its visible selection",
  async () => {
    const active = await startFx(8, 10, true);
    await typeLiteral(active, "       /he");
    await active.waitForPane((pane) => pane.includes("/he"), READY_TIMEOUT);
    await active.sendKeys("Enter");
    await active.waitForPane((pane) => pane.includes("Command"), READY_TIMEOUT);
    expect(gateway?.requests).toHaveLength(0);
    expectCleanStderr();
  },
  TIMEOUT,
);

tmuxTest(
  "tiny pane keeps capped multiline slash picker visible and plain arrows navigate it",
  async () => {
    const active = await startFx(8, 6);
    await typeLiteral(active, "       /");
    await active.waitForPane((pane) => pane.includes("/help"), READY_TIMEOUT);
    const before = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendKeys("Down");
    await active.waitForCursor(
      (position) => position.row === before.row && position.col === before.col,
      READY_TIMEOUT,
    );
    const selected = await waitForSelectedSlashLabel(active, "/cle", READY_TIMEOUT);
    expect(stripAnsi(selected)).toContain("…");
  },
  TIMEOUT,
);

tmuxTest(
  "resize preserves slash routing and wrapped-composer arrow precedence",
  async () => {
    const active = await startFx(80, 24);
    await typeLiteral(active, "       /");
    await active.waitForPane((pane) => pane.includes("/help"), READY_TIMEOUT);
    const visibleCursor = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendKeys("Down");
    await active.waitForCursor(
      (position) => position.row === visibleCursor.row && position.col === visibleCursor.col,
      READY_TIMEOUT,
    );
    await waitForSelectedSlashLabel(active, "/clear", READY_TIMEOUT);

    await active.resizeWindow(8, 10, 300);
    const wrapped = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendKeys("Up");
    await active.waitForCursor((position) => position.row === wrapped.row - 1, READY_TIMEOUT);

    await active.resizeWindow(80, 24, 300);
    await active.waitForPane((pane) => pane.includes("/clear"), READY_TIMEOUT);
    const visibleAgain = await active.waitForCursor((position) => position.col > 2, READY_TIMEOUT);
    await active.sendKeys("Down");
    await active.waitForCursor(
      (position) => position.row === visibleAgain.row && position.col === visibleAgain.col,
      READY_TIMEOUT,
    );
  },
  TIMEOUT,
);
