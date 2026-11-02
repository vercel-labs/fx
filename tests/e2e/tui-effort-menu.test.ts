// `/effort` opens a footer menu of the current model's reasoning effort
// levels, like the `/model` menu, and `/effort <level>` applies one directly.
// Every view of the menu is read back from the recorded tape through
// `fx replay`, and the highlight from the bytes fx wrote for it, so these
// tests check what the terminal showed, not the live pane alone.
import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { keystrokeFrames, lastTranscriptRow, replayGrids } from "./info-panel";
import { readTapeFrames } from "./render-lab/tape";
import {
  fakeGatewayFinalText,
  heldFakeGatewayFinalText,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 60_000;
const MODEL = "acme/thinker";
const PLAIN_MODEL = "acme/plain";
const LEVELS = ["default", "low", "medium", "high", "xhigh"];
const HINT = "↑↓ navigate     enter use     esc close";
const STDOUT = 1;
const STDIN = 2;

const catalog = [
  {
    id: MODEL,
    type: "language",
    released: 200,
    tags: ["reasoning", "tool-use"],
    reasoning_options: [{ type: "effort", values: ["low", "medium", "high", "xhigh"] }],
    context_window: 1_000_000,
    max_tokens: 32_000,
  },
  { id: PLAIN_MODEL, type: "language", released: 100, tags: ["tool-use"], context_window: 128_000 },
];

type Shell = {
  session: TmuxSession;
  gateway: ReturnType<typeof startDynamicFakeGateway>;
  root: string;
  home: string;
  tape: string;
  stderrPath: string;
};

let shell: Shell | null = null;
const roots: string[] = [];

afterEach(async () => {
  if (shell) {
    await shell.session.kill();
    shell.gateway.stop();
    shell = null;
  }
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

/// A shell on `model` over a fake gateway whose catalog gives `MODEL` four
/// levels and `PLAIN_MODEL` none, recording every byte to a tape. Returns once
/// the catalog has been served, so `/effort` sees the levels.
async function launch(options: {
  model?: string;
  width?: number;
  height?: number;
  respond?: (body: string) => Response;
} = {}): Promise<Shell> {
  const root = mkdtempSync(join(tmpdir(), "fx-effort-menu-"));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  let catalogServed = 0;
  const gateway = startDynamicFakeGateway(options.respond ?? (() => fakeGatewayFinalText("ANSWER")), {
    models: () => {
      catalogServed += 1;
      return catalog;
    },
  });
  const tape = join(root, "session.fxtape");
  const stderrPath = join(root, "stderr.log");
  const session = await TmuxSession.create({
    cwd: workspace,
    stderrPath,
    isolated: true,
    width: options.width ?? 80,
    height: options.height ?? 24,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: "effort-menu-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_MODEL: options.model ?? MODEL,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_SOUND: "0",
      FX_AUTO_UPGRADE: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_PERMISSION_MODE: "auto",
      FX_RECORD: tape,
      FX_RECORD_INPUT: "1",
    },
  });
  shell = { session, gateway, root, home, tape, stderrPath };
  await session.waitForComposer(10_000);
  await session.waitForPane(() => catalogServed > 0, 10_000);
  // The shell adopts the served catalog on its next loop turn.
  await Bun.sleep(300);
  return shell;
}

/// Presses `key` and waits until the pane shows something new. A moved
/// highlight changes only styles, so the pane is compared with them.
async function press(session: TmuxSession, key: string): Promise<void> {
  const before = await session.capturePaneEscapes();
  await session.sendKeys(key);
  const deadline = Date.now() + 5_000;
  while ((await session.capturePaneEscapes()) === before) {
    if (Date.now() > deadline) throw new Error(`the pane did not change after ${key}:\n${await session.capturePane()}`);
    await Bun.sleep(25);
  }
}

async function quit(current: Shell): Promise<void> {
  await current.session.sendText("/quit");
  expect(await current.session.waitForSessionEnd(10_000)).toBe(true);
  current.gateway.stop();
  shell = null;
}

/// What the `/effort` menu shows in `grid`, or null: its `Effort` title
/// with the level count and the model, then one row per level, the one in
/// use marked `current`.
type EffortMenuView = { count: number; model: string; levels: string[]; current: string | null };

function effortMenu(grid: string[]): EffortMenuView | null {
  const rows = grid.map((row) => row.trimEnd());
  const top = rows.findIndex((row) => /^Effort \d+(?: {2}\S.*)?$/.test(row));
  if (top < 0) return null;
  const header = /^Effort (\d+)(?: {2}(.*))?$/.exec(rows[top]!)!;
  const levels: string[] = [];
  let current: string | null = null;
  for (let at = top + 1; at < rows.length; at++) {
    const row = rows[at]!;
    if (row === "" && levels.length === 0) continue;
    const level = /^ {2}(\S+)(?: +(current))?$/.exec(row);
    if (!level) break;
    levels.push(level[1]!);
    if (level[2]) current = level[1]!;
  }
  return { count: Number(header[1]), model: header[2] ?? "", levels, current };
}

/// Each grid of the tape that shows the menu, in order, with its frame.
function menuViews(current: Shell, label: string): { frame: number; grid: string[]; menu: EffortMenuView }[] {
  const grids = replayGrids(FX_BIN, current.tape, join(current.root, `${label}.frames`));
  const views: { frame: number; grid: string[]; menu: EffortMenuView }[] = [];
  for (const [frame, grid] of [...grids.entries()].sort((a, b) => a[0] - b[0])) {
    const menu = effortMenu(grid);
    if (menu) views.push({ frame, grid, menu });
  }
  return views;
}

/// The level highlighted after each keystroke in the tape that `key`
/// matches, read from the bytes fx wrote before the next keystroke: the label
/// it drew bold. fx repaints only the cells that changed, so a move redraws
/// the old level dim and the new one bold, with bold set apart from the color
/// that follows it.
function highlightsAfter(current: Shell, key: RegExp): string[] {
  const frames = readTapeFrames(current.tape, { ignoreTruncatedTail: true });
  const keystrokes = keystrokeFrames(current.tape);
  const pressed = frames.filter((frame) => frame.kind === STDIN && key.test(frame.payload.toString("latin1")));
  const labels = LEVELS.join("|");
  return pressed.map((press) => {
    const next = keystrokes.find((index) => index > press.index) ?? Number.MAX_SAFE_INTEGER;
    const painted = frames
      .filter((frame) => frame.kind === STDOUT && frame.index > press.index && frame.index < next)
      .map((frame) => frame.payload.toString("utf8"))
      .join("");
    const bold = [...painted.matchAll(new RegExp(`\\x1b\\[1m(?:\\x1b\\[[0-9;]*m)*(${labels})(?![a-z])`, "g"))];
    return bold.at(-1)?.[1] ?? "<none>";
  });
}

const ARROW = /^\x1b(?:\[|O)[AB]$/;
const TAB = /^\t$/;

/// The running column `/effort ` opens under the composer in `grid`, or
/// null: the levels it lists, as `/model`'s effort column lists them, and the
/// status line under it.
function effortColumn(grid: string[]): { composer: string; levels: string[]; status: string } | null {
  const rows = grid.map((row) => row.trimEnd());
  const composer = rows.findLastIndex((row) => /^┃ \/effort\b/.test(row));
  if (composer < 0 || !/^─+$/.test(rows[composer + 1] ?? "")) return null;
  const end = rows.findIndex((row, at) => at > composer + 1 && /^─+$/.test(row));
  if (end < 0) return null;
  const levels = rows.slice(composer + 2, end).map((row) => row.trim()).filter((row) => row !== "");
  // A level is one word; the slash command list under a typed `/effort` is not.
  if (levels.length === 0 || levels.some((level) => !/^[\w.-]+$/.test(level))) return null;
  return { composer: rows[composer]!, levels, status: rows[end + 1] ?? "" };
}

function columnViews(current: Shell, label: string): { composer: string; levels: string[]; status: string }[] {
  const grids = replayGrids(FX_BIN, current.tape, join(current.root, `${label}.frames`));
  return [...grids.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([, grid]) => effortColumn(grid))
    .filter((view) => view !== null);
}

function savedEffort(current: Shell): string | undefined {
  const path = join(current.home, ".fx", "settings.json");
  if (!existsSync(path)) return undefined;
  return (JSON.parse(readFileSync(path, "utf8")) as { effort?: string }).effort;
}

function count(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

test.skipIf(!tmuxAvailable())("/effort lists the model's levels with the one in use marked, and Enter applies the highlighted one", async () => {
  const current = await launch();
  const { session } = current;
  await session.sendText("/effort");
  await session.waitForText("Effort 5", 5_000);
  // ↑ from the first level wraps to the last, as the /model menu does.
  for (const key of ["Up", "Down", "Down", "Down", "Down"]) await press(session, key);
  await session.sendKeys("Enter");
  await session.waitForText("Reasoning effort set to high for acme/thinker", 5_000);
  expect(savedEffort(current)).toBe("high");

  // Opened again, the menu marks and highlights the level now in use. Esc
  // closes it without a change.
  await session.sendText("/effort");
  await session.waitForText("high     current", 5_000);
  await session.sendKeys("Escape");
  await session.waitForPane((pane) => !pane.includes("Effort 5"), 5_000);
  // A typed character closes the menu and lands in the composer.
  await session.sendText("/effort");
  await session.waitForText("Effort 5", 5_000);
  await session.sendLiteral("x");
  await session.waitForPane((pane) => !pane.includes("Effort 5") && /^┃ x$/m.test(pane), 5_000);
  await session.sendKeys("C-u");
  expect(savedEffort(current)).toBe("high");
  expect(readFileSync(current.stderrPath, "utf8")).toBe("");
  await quit(current);

  const views = menuViews(current, "apply");
  const first = views[0]!;
  expect(first.menu).toEqual({ count: 5, model: MODEL, levels: LEVELS, current: "default" });
  expect(first.grid.some((row) => row.trimEnd() === HINT)).toBe(true);
  expect(highlightsAfter(current, ARROW)).toEqual(["xhigh", "default", "low", "medium", "high"]);
  const reopened = views.find((view) => view.menu.current === "high");
  expect(reopened?.menu.levels).toEqual(LEVELS);
  // The menu leaves no row in the transcript; the one line Enter added names
  // the level once.
  const grids = replayGrids(FX_BIN, current.tape, join(current.root, "apply-final.frames"));
  const last = [...grids.entries()].sort((a, b) => a[0] - b[0]).at(-1)![1].join("\n");
  expect(count(last, "Reasoning effort set to high for acme/thinker")).toBe(1);
  expect(last).not.toContain("Effort 5");
  expect(last).not.toMatch(/^ {2}medium$/m);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("/effort <level> applies the level directly, and the next request carries it", async () => {
  const current = await launch();
  const { session, gateway } = current;
  await session.sendText("/effort xhigh");
  await session.waitForText("Reasoning effort set to xhigh for acme/thinker", 5_000);
  expect(savedEffort(current)).toBe("xhigh");
  await session.sendText("first question");
  await session.waitForText("ANSWER", 10_000);
  await session.waitForComposer(10_000);

  await session.sendText("/effort default");
  await session.waitForText("Reasoning effort set to default for acme/thinker", 5_000);
  expect(savedEffort(current)).toBe("auto");
  await session.sendText("second question");
  await session.waitForPane(() => gateway.requests.some((request) => request.body.includes("second question")), 10_000);
  await session.waitForComposer(10_000);
  expect(readFileSync(current.stderrPath, "utf8")).toBe("");
  await quit(current);

  const turn = (prompt: string) => gateway.requests
    .filter((request) => request.body.includes(prompt))
    .map((request) => JSON.parse(request.body) as { reasoning?: string })[0];
  expect(turn("first question")?.reasoning).toBe("xhigh");
  // The model's default sends no effort at all.
  expect(turn("second question")).not.toHaveProperty("reasoning");
  expect(menuViews(current, "direct")).toEqual([]);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a level the model does not offer, or a malformed one, changes nothing and names the levels", async () => {
  const current = await launch();
  const { session } = current;
  await session.sendText("/effort turbo");
  await session.waitForText("turbo is not available for acme/thinker; levels: default, low, medium,", 5_000);
  await session.sendText("/effort !!");
  await session.waitForText("levels for acme/thinker: default, low, medium, high, xhigh", 5_000);
  expect(savedEffort(current)).toBeUndefined();
  expect(readFileSync(current.stderrPath, "utf8")).toBe("");
  await quit(current);
  expect(menuViews(current, "rejected")).toEqual([]);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a model without levels gets a notice instead of a menu", async () => {
  const current = await launch({ model: PLAIN_MODEL });
  const { session } = current;
  await session.sendText("/effort");
  await session.waitForText("acme/plain has no levels to choose from", 5_000);
  await session.sendText("/effort high");
  await session.waitForPane((pane) => count(pane, "acme/plain has no levels to choose from") === 2, 5_000);
  expect(savedEffort(current)).toBeUndefined();
  expect(readFileSync(current.stderrPath, "utf8")).toBe("");
  await quit(current);
  expect(menuViews(current, "plain")).toEqual([]);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a level chosen during a turn applies to the next turn", async () => {
  const held = heldFakeGatewayFinalText();
  const current = await launch({
    respond: (body) => body.includes("first question") && !body.includes("second question")
      ? held.response
      : fakeGatewayFinalText("SECOND_ANSWER"),
  });
  const { session, gateway } = current;
  await session.sendText("first question");
  await session.waitForText("Thinking", 10_000);
  await session.sendText("/effort");
  await session.waitForText("Effort 5", 5_000);
  await press(session, "Up");
  await session.sendKeys("Enter");
  await session.waitForText("Next turn will use reasoning effort xhigh for acme/thinker", 5_000);
  held.release("FIRST_ANSWER");
  await session.waitForText("FIRST_ANSWER", 10_000);
  await session.waitForComposer(10_000);
  await session.sendText("second question");
  await session.waitForText("SECOND_ANSWER", 10_000);
  await session.waitForComposer(10_000);
  expect(readFileSync(current.stderrPath, "utf8")).toBe("");
  await quit(current);

  const bodies = gateway.requests.map((request) => JSON.parse(request.body) as { reasoning?: string });
  const first = gateway.requests.findIndex((request) => request.body.includes("first question"));
  const second = gateway.requests.findIndex((request) => request.body.includes("second question"));
  expect(bodies[first]).not.toHaveProperty("reasoning");
  expect(bodies[second]?.reasoning).toBe("xhigh");
  // The menu opened over the running turn, above its activity row.
  const views = menuViews(current, "turn");
  expect(views[0]?.grid.some((row) => row.includes("Thinking"))).toBe(true);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a short terminal shows one level at a time, ↓ scrolls to the last, and the transcript stays in view", async () => {
  const current = await launch({ width: 60, height: 12 });
  const { session } = current;
  const kept = lastTranscriptRow((await session.capturePane()).split("\n"));
  await session.sendText("/effort");
  await session.waitForText("Effort 5", 5_000);
  for (let step = 1; step < LEVELS.length; step++) await press(session, "Down");
  await session.sendKeys("Escape");
  await session.waitForPane((pane) => !pane.includes("Effort 5"), 5_000);
  await quit(current);

  const views = menuViews(current, "short");
  // One level shows under the title, and each ↓ shows the next one.
  const shown = views.map((view) => view.menu.levels);
  expect(shown.every((levels) => levels.length === 1)).toBe(true);
  expect([...new Set(shown.map((levels) => levels[0]))]).toEqual(LEVELS);
  // The menu leaves the end of the transcript in view rather than cover it.
  for (const view of views) expect(view.grid.map((row) => row.trimEnd())).toContain(kept);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("Tab opens /effort's running column, as Tab opens /model's: ↑↓ previews a level, Tab completes it, and Enter applies it", async () => {
  const current = await launch();
  const { session } = current;
  // Tab on a partial command completes it and opens the column.
  await session.sendLiteral("/eff");
  await session.sendKeys("Tab");
  await session.waitForText("xhigh", 5_000);
  await press(session, "Down");
  await press(session, "Down");
  await session.waitForText("auto · thinker · medium", 5_000);
  await session.sendKeys("Enter");
  await session.waitForText("Reasoning effort set to medium for acme/thinker", 5_000);
  expect(savedEffort(current)).toBe("medium");

  // Tab on the whole command opens it on the level in use; typing filters
  // it, Tab writes the highlighted level out, and Enter applies it.
  await session.sendLiteral("/effort");
  await session.sendKeys("Tab");
  await session.waitForText("xhigh", 5_000);
  await session.sendLiteral("x");
  await session.waitForPane((pane) => /^┃ \/effort x$/m.test(pane), 5_000);
  await session.sendKeys("Tab");
  await session.waitForPane((pane) => /^┃ \/effort xhigh$/m.test(pane), 5_000);
  await session.sendKeys("Enter");
  await session.waitForText("Reasoning effort set to xhigh for acme/thinker", 5_000);
  expect(savedEffort(current)).toBe("xhigh");

  // A level with no match runs as the command, which names the levels.
  await session.sendText("/effort tur");
  await session.waitForText("tur is not available for acme/thinker; levels: default, low, medium,", 5_000);
  expect(savedEffort(current)).toBe("xhigh");

  // /model keeps its own effort column after the model.
  await session.sendLiteral("/model");
  await session.sendKeys("Tab");
  await session.waitForText("acme/plain", 5_000);
  await session.sendKeys("Enter");
  await session.waitForPane((pane) => /^┃ \/model acme\/thinker$/m.test(pane) && pane.includes("xhigh"), 5_000);
  await session.sendKeys("Escape");
  await session.sendKeys("C-u");
  expect(readFileSync(current.stderrPath, "utf8")).toBe("");
  await quit(current);

  const views = columnViews(current, "column");
  expect(views[0]).toMatchObject({ composer: "┃ /effort", levels: LEVELS });
  // ↓ moved the preview in the status line with the highlight.
  expect(views.some((view) => view.status === "auto · thinker · medium" && view.levels.length === LEVELS.length)).toBe(true);
  expect(views.some((view) => view.composer === "┃ /effort x" && view.levels.join() === "xhigh")).toBe(true);
  expect(views.some((view) => view.composer === "┃ /effort xhigh" && view.levels.join() === "xhigh")).toBe(true);
  expect(highlightsAfter(current, ARROW).slice(0, 2)).toEqual(["low", "medium"]);
  // Tab on `/eff` starts at the first level; Tab on `/effort` at the one in use.
  const [partial, whole] = highlightsAfter(current, TAB);
  expect(partial).toBe("default");
  expect(whole).toBe("medium");
  expect(menuViews(current, "column-menu")).toEqual([]);
}, TIMEOUT);

test.skipIf(!tmuxAvailable())("a model without levels opens no /effort column, and Enter says why", async () => {
  const current = await launch({ model: PLAIN_MODEL });
  const { session } = current;
  await session.sendLiteral("/effort");
  await session.sendKeys("Tab");
  await session.waitForPane((pane) => /^┃ \/effort$/m.test(pane), 5_000);
  await session.sendKeys("Enter");
  await session.waitForText("acme/plain has no levels to choose from", 5_000);
  expect(savedEffort(current)).toBeUndefined();
  expect(readFileSync(current.stderrPath, "utf8")).toBe("");
  await quit(current);
  expect(columnViews(current, "plain-column")).toEqual([]);
}, TIMEOUT);
