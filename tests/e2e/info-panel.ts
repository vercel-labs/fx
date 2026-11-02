// What a read-only footer panel showed, `/status` or `/permissions`, read
// back through fx's own virtual terminal. A test records the terminal with
// `FX_RECORD` and `FX_RECORD_INPUT=1`; `fx replay --frames-dir` feeds that
// tape to the vt_emulator engine (`src/core/terminal/engine.zig`) and writes
// the grid after every frame. Each time the tape's input submitted the
// command, it is matched to the panel fx painted before the next keystroke,
// to every view of it while keys moved it, and to the shell fx painted
// before the command was typed and after the panel closed, so a test can
// prove the panel left the transcript as it was. The tmux helpers at the end
// read the same panels from a live pane.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { readTapeFrames } from "./render-lab/tape";

const STDOUT = 1;
const STDIN = 2;

/// Every label the `/status` panel can show.
export const STATUS_PANEL_LABELS = [
  "Session",
  "Model",
  "Provider",
  "Endpoint",
  "Connected",
  "Auth",
  "Auth help",
  "Team",
  "Settings",
  "Permissions",
  "Workspace",
  "Turns",
  "Session grants",
  "Step limit",
  "Ultrafast",
  "Updates",
  "Build",
] as const;

/// Every label the `/permissions` panel can show.
export const PERMISSIONS_PANEL_LABELS = [
  "Mode",
  "Configured rules",
  "Session grants",
  "Saved rules",
  "Change mode",
  "Remember",
  "Revoke",
] as const;

/// Each panel's title, the command that opens it, and its labels. A label
/// that is the start of another, such as `Session` and `Session grants`, is
/// matched by the two spaces at least that separate it from its value.
const PANELS = {
  Status: { command: "/status", labels: STATUS_PANEL_LABELS },
  Permissions: { command: "/permissions", labels: PERMISSIONS_PANEL_LABELS },
} as const;

export type PanelTitle = keyof typeof PANELS;

export type InfoPanel = {
  /// The panel's lines under its title, as painted.
  rows: string[];
  /// The labels shown, in order.
  labels: string[];
  /// Each label's value, its wrapped lines joined back together.
  fields: Partial<Record<string, string>>;
  /// The entries of each label's list, drawn as bullets under its value,
  /// their wrapped lines joined back together.
  items: Partial<Record<string, string[]>>;
};

/// A panel as one grid showed it.
export type PanelView = InfoPanel & {
  /// The tape frame whose grid holds the panel.
  frame: number;
  /// That frame's grid, one string per terminal row.
  grid: string[];
};

/// One time a panel's command ran: the panel it opened with, every view of
/// it while keys such as ↓ moved it, and the shell before and after.
export type PanelReport = PanelView & {
  /// The panel as it opened, then after each keystroke that repainted it.
  views: PanelView[];
  /// The grid fx painted before the command was typed.
  before: string[];
  /// The grid fx painted once the panel closed, before the next keystroke.
  closed: string[];
};

export type StatusPanel = InfoPanel;
export type StatusPanelView = PanelView;
export type StatusReport = PanelReport;

/// A tape's frames. A process killed mid-write leaves its last frame cut
/// short; it is left out, as `fx replay` leaves it out.
function frames(tapePath: string) {
  return readTapeFrames(tapePath, { ignoreTruncatedTail: true });
}

/// Whether recorded input holds a keystroke, not only replies the terminal
/// sent by itself: focus events, cursor and device reports, and OSC answers.
export function holdsKeystroke(input: string): boolean {
  for (let at = 0; at < input.length;) {
    if (input[at] !== "\x1b") return true;
    const osc = /^\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/.exec(input.slice(at));
    if (osc) {
      at += osc[0].length;
      continue;
    }
    const csi = /^\x1b\[([0-?]*)([ -/]*)([@-~])/.exec(input.slice(at));
    if (!csi) return true;
    const reply = /^[?>]/.test(csi[1]!) || "RIOcnty".includes(csi[3]!) || csi[2] === "$";
    if (!reply) return true;
    at += csi[0].length;
  }
  return false;
}

/// Every grid `fx replay --frames-dir` wrote for `tapePath`, by tape frame.
export function replayGrids(fxBin: string, tapePath: string, framesRoot: string): Map<number, string[]> {
  execFileSync(fxBin, ["replay", tapePath, "--frames-dir", framesRoot], {
    stdio: "pipe",
    env: { ...process.env, FX_SOUND: "0" },
  });
  const grids = new Map<number, string[]>();
  for (const frame of frames(tapePath)) {
    if (frame.kind !== STDOUT) continue;
    const path = join(framesRoot, "frames", `${String(frame.index).padStart(4, "0")}.grid.txt`);
    const text = readFileSync(path, "utf8");
    // Each row is framed as |row|.
    grids.set(frame.index, text.replace(/\n$/, "").split("\n").map((line) => line.replace(/^\|(.*)\|$/, "$1")));
  }
  return grids;
}

/// The tape frames that hold a keystroke, in order.
export function keystrokeFrames(tapePath: string): number[] {
  return frames(tapePath)
    .filter((frame) => frame.kind === STDIN && holdsKeystroke(frame.payload.toString("latin1")))
    .map((frame) => frame.index);
}

/// Each time the tape's input submitted `command`: the frame where its first
/// character was typed, and the frame where Enter arrived with the composer's
/// line, as the keystrokes typed it, equal to `command`.
export function submittedFrames(tapePath: string, command: string): { typed: number; submitted: number }[] {
  const submits: { typed: number; submitted: number }[] = [];
  let line = "";
  let typed = -1;
  const enter = (index: number) => {
    if (line.trim() === command) submits.push({ typed, submitted: index });
    line = "";
  };
  for (const frame of frames(tapePath)) {
    if (frame.kind !== STDIN) continue;
    const bytes = frame.payload.toString("latin1");
    for (let at = 0; at < bytes.length; at++) {
      const byte = bytes[at]!;
      if (byte === "\x1b") {
        // CSI and SS3 sequences: arrows, focus reports, and Enter as CSI u.
        const csi = /^\x1b(?:\[[0-?]*[ -/]*[@-~]|O.)/.exec(bytes.slice(at));
        const sequence = csi?.[0] ?? "\x1b";
        if (/^\x1b\[13(?:;1)?u$/.test(sequence)) enter(frame.index);
        at += sequence.length - 1;
        continue;
      }
      if (byte === "\r" || byte === "\n") {
        enter(frame.index);
      } else if (byte === "\x15") {
        line = "";
      } else if (byte === "\x7f" || byte === "\b") {
        line = line.slice(0, -1);
      } else if (byte >= " ") {
        if (line === "") typed = frame.index;
        line += byte;
      }
    }
  }
  return submits;
}

/// The panel titled `title` that `grid` shows, or null: its title, a blank
/// row unless the panel is too short for one, and then one line per label, each wrapped value continuing on the
/// next lines under it, and each list entry starting with a bullet under the
/// value, up to the footer's divider. A value wraps at a space, which the
/// join puts back; after a `/`; or, in a word too long for its column, where
/// the column ends, the only break that fills the line. A word that exactly
/// fills its column before a space reads back joined to the next word; no
/// value the tests read holds one.
/// `width` is the terminal's; by default the widest row's, since `fx replay`
/// writes every row at the terminal's full width.
export function infoPanel(grid: string[], title: PanelTitle, width = Math.max(...grid.map((row) => [...row].length))): InfoPanel | null {
  const top = grid.findIndex((row, at) => row.trimEnd() === title && /^(?: *| {2,}\S.*)$/.test(grid[at + 1] ?? ""));
  if (top < 0) return null;
  const known = [...PANELS[title].labels].sort((a, b) => b.length - a.length);
  const rows: string[] = [];
  const labels: string[] = [];
  const fields: Partial<Record<string, string>> = {};
  const items: Partial<Record<string, string[]>> = {};
  let label: string | null = null;
  let inItem = false;
  let valueColumn = 0;
  let previousFilled = false;
  const join = (joined: string, more: string) => joined + (previousFilled || joined.endsWith("/") ? "" : " ") + more;
  const first = (grid[top + 1] ?? "").trim() === "" ? top + 2 : top + 1;
  for (let row = first; row < grid.length; row++) {
    const text = grid[row]!.trimEnd();
    const named = known.find((candidate) => new RegExp(`^ {2}${candidate} {2,}\\S`).test(text));
    let value: string;
    if (!label && !named && /^ {3,}\S/.test(text)) {
      // Scrolled: the line continues a row whose label is above the panel.
      rows.push(text);
      continue;
    }
    if (named) {
      label = named;
      inItem = false;
      labels.push(named);
      value = text.slice(2 + named.length).trimStart();
      valueColumn = text.length - value.length;
      fields[named] = value;
    } else if (label && text.length > valueColumn && /^ +$/.test(text.slice(0, valueColumn))) {
      const rest = text.slice(valueColumn);
      const list = (items[label] ??= []);
      if (rest.startsWith("• ")) {
        inItem = true;
        value = rest;
        list.push(rest.slice(2));
      } else if (inItem && rest.startsWith("  ") && rest[2] !== " ") {
        value = rest;
        list[list.length - 1] = join(list.at(-1)!, rest.slice(2));
      } else if (!inItem && rest[0] !== " ") {
        value = rest;
        fields[label] = join(fields[label]!, rest);
      } else {
        break;
      }
    } else {
      break;
    }
    previousFilled = valueColumn + [...value].length >= width;
    rows.push(text);
  }
  // A scrolled panel may show only a value's continuation lines.
  return rows.length > 0 ? { rows, labels, fields, items } : null;
}

/// The `/status` panel `grid` shows, or null.
export function statusPanel(grid: string[], width?: number): InfoPanel | null {
  return infoPanel(grid, "Status", width);
}

/// The `/permissions` panel `grid` shows, or null.
export function permissionsPanel(grid: string[], width?: number): InfoPanel | null {
  return infoPanel(grid, "Permissions", width);
}

/// Whether `grid` shows any piece of the panel titled `title`: the panel,
/// or a line only it draws.
export function showsPanel(grid: string[], title: PanelTitle): boolean {
  const own = title === "Status" ? /^ {2}Session grants {2,}\S/ : /^ {2}Change mode {2,}\S/;
  return infoPanel(grid, title) !== null || grid.some((row) => own.test(row));
}

export function showsStatusPanel(grid: string[]): boolean {
  return showsPanel(grid, "Status");
}

/// The credential the panel's `Auth` line names, without the ` · expired`
/// and ` · refreshable` that may follow it; undefined when it shows none.
export function panelAuth(panel: InfoPanel): string | undefined {
  return panel.fields.Auth?.split(" · ")[0];
}

/// The session the `/status` panel's `Session` line names: its id and
/// whether a resume opens it, or no id when the shell has no session.
export function panelSession(panel: InfoPanel): { id: string | null; saved: boolean } {
  const value = panel.fields.Session;
  if (value === undefined) throw new Error(`the /status panel shows no Session line:\n${panel.rows.join("\n")}`);
  if (value === "none · this shell can't save sessions") return { id: null, saved: false };
  const match = /^(\S+) · (saved|not saved yet)$/.exec(value);
  if (!match) throw new Error(`the /status panel's Session line did not parse: ${value}`);
  return { id: match[1]!, saved: match[2] === "saved" };
}

/// The transcript `grid` shows: the rows above the composer, its bottom-most
/// `┃` row, without trailing blank rows, and with a running turn's live
/// activity row, such as `• Thinking (1s) (↑2 ↓0)`, as one placeholder: its
/// glyph blinks and its counters tick. The footer is left out, since its
/// status line may change on its own, as a timed warning ends.
function transcriptRows(grid: string[]): string[] {
  const all = grid.map((row) => row.trimEnd());
  const composer = all.findLastIndex((row) => row.startsWith("┃"));
  if (composer < 0) throw new Error(`no composer row in the grid:\n${all.join("\n")}`);
  const rows = all.slice(0, composer).map((row) => (/^[• ] [A-Z][^()]* \(\d+s\)/.test(row) ? "<activity>" : row));
  while (rows.length > 0 && rows.at(-1) === "") rows.pop();
  return rows;
}

/// The last row of the transcript `grid` shows above its composer, which the
/// panel leaves in view while it is open.
export function lastTranscriptRow(grid: string[]): string {
  const row = transcriptRows(grid).at(-1);
  if (row === undefined) throw new Error(`no transcript row above the composer:\n${grid.join("\n")}`);
  return row;
}

/// Whether the transcript in `report.closed` is the one `report.before`
/// showed, or the same with rows that scrolled away above it: the panel
/// opened and closed without adding a row to the transcript.
export function closedAsBefore(report: PanelReport): boolean {
  const before = transcriptRows(report.before);
  const closed = transcriptRows(report.closed);
  if (closed.length > before.length) return false;
  return closed.every((row, at) => row === before[before.length - closed.length + at]);
}

/// One report for each time the tape submitted the command of the panel
/// titled `title`, in order. Each keystroke after the submit bounds the grid
/// painted after the one before it; the report follows those grids until one
/// shows no panel, the panel closed. Throws when the command painted no panel
/// before the next keystroke, when a panel was already showing when it was
/// typed, or when no keystroke after the one that closed it bounds the closed
/// grid.
export function panelReports(fxBin: string, tapePath: string, framesRoot: string, title: PanelTitle): PanelReport[] {
  const command = PANELS[title].command;
  const grids = replayGrids(fxBin, tapePath, framesRoot);
  const keystrokes = keystrokeFrames(tapePath);
  const paintedBetween = (after: number, before: number) =>
    [...grids.keys()].filter((index) => index > after && index < before).sort((a, b) => b - a);
  return submittedFrames(tapePath, command).map(({ typed, submitted }) => {
    const beforeFrame = paintedBetween(-1, typed)[0];
    if (beforeFrame === undefined) throw new Error(`${command} typed at tape frame ${typed} before fx painted anything`);
    const before = grids.get(beforeFrame)!;
    if (showsPanel(before, title)) throw new Error(`a ${command} panel was already showing when ${command} was typed at tape frame ${typed}`);

    const views: PanelView[] = [];
    let start = submitted;
    for (const end of keystrokes.filter((index) => index > submitted)) {
      const painted = paintedBetween(start, end);
      const view = painted.flatMap((frame) => {
        const panel = infoPanel(grids.get(frame)!, title);
        return panel ? [{ frame, grid: grids.get(frame)!, ...panel }] : [];
      })[0];
      if (views.length === 0 && !view) {
        throw new Error(`${command} submitted at tape frame ${submitted} painted no panel before the next keystroke`);
      }
      if (view && painted[0] === view.frame) {
        views.push(view);
      } else if (painted.length > 0) {
        // The newest grid shows no panel: the keystroke before it closed it.
        return { ...views[0]!, views, before, closed: grids.get(painted[0]!)! };
      }
      start = end;
    }
    throw new Error(`${command} submitted at tape frame ${submitted} has no keystroke after the one that closed its panel`);
  });
}

export function statusReports(fxBin: string, tapePath: string, framesRoot: string): PanelReport[] {
  return panelReports(fxBin, tapePath, framesRoot, "Status");
}

/// What a test drives a tmux pane with, as `TmuxSession` does.
type Pane = {
  sendText(text: string): Promise<void>;
  sendKeys(keys: string): Promise<void>;
  capturePane(): Promise<string>;
  paneSize(): { cols: number; rows: number };
};

/// Waits until `pane` shows the panel titled `title` with what `ready` asks
/// for, and returns it; without `ready`, every line of it. When the lines do
/// not all fit and those showing are not what `ready` asks for, the rest are
/// read a line at a time with ↓, and the panel is scrolled back to its first
/// line. Each view counts once it is the same in two captures in a row, so a
/// frame caught half painted is not taken for it. A `ready` that never holds
/// fails with the pane.
export async function waitForPanel(
  pane: Pane,
  title: PanelTitle,
  timeout: number,
  ready?: (panel: InfoPanel) => boolean,
): Promise<InfoPanel> {
  const deadline = Date.now() + timeout;
  while (true) {
    const first = await settledView(pane, title, deadline, () => true);
    let panel = first.panel;
    const overflows = first.grid.some((row) => /^↑↓ scroll\b/.test(row));
    if (overflows && !(ready?.(panel) ?? false)) panel = await readScrolledPanel(pane, title, first.panel);
    if (ready?.(panel) ?? true) return panel;
    if (Date.now() >= deadline) {
      throw new Error(`the ${title} panel never showed what the test waited for:\n${(await pane.capturePane()).trimEnd()}`);
    }
    await Bun.sleep(25);
  }
}

/// Every line of the panel titled `title` that `pane` shows with `first` its
/// first lines, read with ↓ a line at a time to the last, as one panel.
/// Scrolls back to `first` before returning. Scrolling has its own time, so
/// it fits any timeout.
async function readScrolledPanel(pane: Pane, title: PanelTitle, first: InfoPanel): Promise<InfoPanel> {
  const lines = [...first.rows];
  let shown = first;
  let scrolled = 0;
  while (true) {
    await pane.sendKeys("Down");
    // ↓ past the last line paints nothing, so a second waits it out.
    const next = await settledView(pane, title, Date.now() + 1_000, (view) =>
      view.rows.join("\n") !== shown.rows.join("\n") &&
      view.rows.length === shown.rows.length &&
      view.rows.slice(0, -1).join("\n") === shown.rows.slice(1).join("\n")).catch(() => null);
    if (!next) break;
    lines.push(next.panel.rows.at(-1)!);
    shown = next.panel;
    scrolled++;
  }
  for (let up = 0; up < scrolled; up++) await pane.sendKeys("Up");
  await settledView(pane, title, Date.now() + 5_000, (view) => view.rows.join("\n") === first.rows.join("\n"));
  return infoPanel([title, "", ...lines], title, pane.paneSize().cols)!;
}

/// The next panel titled `title` that `pane` shows the same in two captures
/// in a row and `accept` takes, with the grid it is on.
async function settledView(
  pane: Pane,
  title: PanelTitle,
  deadline: number,
  accept: (panel: InfoPanel) => boolean,
): Promise<{ panel: InfoPanel; grid: string[] }> {
  const cols = pane.paneSize().cols;
  let previous = "";
  while (true) {
    const text = await pane.capturePane();
    const grid = text.split("\n");
    const panel = infoPanel(grid, title, cols);
    if (panel && text === previous && accept(panel)) return { panel, grid };
    if (Date.now() >= deadline) throw new Error(`the ${title} panel did not settle:\n${text.trimEnd()}`);
    previous = text;
    await Bun.sleep(25);
  }
}

/// Closes the panel titled `title` with Esc and waits until it is gone, so
/// the composer takes input again.
export async function closePanel(pane: Pane, title: PanelTitle, timeout: number): Promise<void> {
  await pane.sendKeys("Escape");
  const deadline = Date.now() + timeout;
  let text: string;
  while (showsPanel((text = await pane.capturePane()).split("\n"), title)) {
    if (Date.now() >= deadline) throw new Error(`the ${title} panel did not close on Esc:\n${text.trimEnd()}`);
    await Bun.sleep(25);
  }
}

/// Runs the command of the panel titled `title` in `pane`, waits until the
/// panel shows what `ready` asks for, closes it, and returns what it showed.
export async function readPanel(
  pane: Pane,
  title: PanelTitle,
  timeout: number,
  ready?: (panel: InfoPanel) => boolean,
): Promise<InfoPanel> {
  await pane.sendText(PANELS[title].command);
  const panel = await waitForPanel(pane, title, timeout, ready);
  await closePanel(pane, title, timeout);
  return panel;
}

export function waitForStatusPanel(pane: Pane, timeout: number, ready?: (panel: InfoPanel) => boolean): Promise<InfoPanel> {
  return waitForPanel(pane, "Status", timeout, ready);
}

export function closeStatusPanel(pane: Pane, timeout: number): Promise<void> {
  return closePanel(pane, "Status", timeout);
}

export function readStatusPanel(pane: Pane, timeout: number, ready?: (panel: InfoPanel) => boolean): Promise<InfoPanel> {
  return readPanel(pane, "Status", timeout, ready);
}

export function readPermissionsPanel(pane: Pane, timeout: number, ready?: (panel: InfoPanel) => boolean): Promise<InfoPanel> {
  return readPanel(pane, "Permissions", timeout, ready);
}
