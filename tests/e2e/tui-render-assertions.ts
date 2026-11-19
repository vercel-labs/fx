import { existsSync, readFileSync } from "node:fs";
import { isComposerLine } from "./tmux-helpers";

export type FooterBlock = {
  topDivider: number;
  input: number;
  bottomDivider: number;
  hasTopDivider: boolean;
};

export type FileApprovalBlock = {
  topDivider: number;
  bottomDivider: number;
  lines: string[];
  text: string;
};

export function readTrace(path: string): string {
  if (!existsSync(path)) return "";
  return readFileSync(path, "utf8");
}

export function isInputRow(line: string): boolean {
  const normalized = normalizeGridLine(line);
  return (
    isComposerLine(normalized) ||
    /^\[\d+\/\d+\]\s[\u276f>](\s|$)/.test(normalized)
  );
}

export function isDividerRow(line: string): boolean {
  const normalized = normalizeGridLine(line);
  if (normalized.length < 8) return false;
  const dividerChars = (
    normalized.match(/[\u2500\u2501\u2550\u2574-\u257f]/g) ?? []
  ).length;
  return dividerChars >= Math.floor(normalized.length * 0.6);
}

/**
 * Counts a catalog menu's items from its title row: the item rows it shows
 * plus the hidden ones a `↓ N more` row reports. Messages, status lines, and
 * group headings are not items. Returns null when no row starts with `title`.
 */
export function catalogMenuItemCount(grid: string[], title: string): number | null {
  const start = grid.findIndex((line) => {
    const text = line.trimEnd();
    return text === title || text.startsWith(`${title} `);
  });
  if (start < 0) return null;
  let count = 0;
  for (const line of grid.slice(start + 1)) {
    if (isDividerRow(line)) break;
    const text = line.trim();
    if (text.length === 0) continue;
    const more = /^↓ (\d+) more$/.exec(text);
    if (more) {
      count += Number(more[1]);
      continue;
    }
    // An item is a name without spaces, alone or followed by columns two or
    // more spaces apart. A phrase with single spaces and no columns is a
    // message, a status line, or a group heading.
    if (/ /.test(text) && !/ {2,}/.test(text)) continue;
    if (text === "Tools") continue;
    count += 1;
  }
  return count;
}

function isFooterHintRow(line: string): boolean {
  const normalized = normalizeGridLine(line).trim();
  return (
    normalized.length > 0 &&
    !isDividerRow(normalized) &&
    !isInputRow(normalized)
  );
}

function isInputContinuationRow(line: string): boolean {
  const normalized = normalizeGridLine(line);
  return normalized.trim().length === 0 || normalized.startsWith("  ");
}

function normalizeGridLine(line: string): string {
  if (line.startsWith("|") && line.endsWith("|") && line.length >= 2) {
    return line.slice(1, -1).trimEnd();
  }
  return line;
}

export function findFooterBlocks(grid: string[]): FooterBlock[] {
  const blocks: FooterBlock[] = [];
  for (let i = 0; i < grid.length; i++) {
    if (!isInputRow(grid[i]!)) continue;
    if (normalizeGridLine(grid[i]!).startsWith("┃")) {
      if (i > 0 && normalizeGridLine(grid[i - 1]!).startsWith("┃")) continue;
      let spacer = i + 1;
      while (
        spacer < grid.length &&
        normalizeGridLine(grid[spacer]!).startsWith("┃")
      ) {
        spacer++;
      }
      const hint = spacer + 1;
      if (
        spacer < grid.length &&
        normalizeGridLine(grid[spacer]!).trim().length === 0 &&
        hint < grid.length &&
        isFooterHintRow(grid[hint]!) &&
        grid.slice(hint + 1).every((line) => normalizeGridLine(line).trim().length === 0)
      ) {
        blocks.push({
          topDivider: i,
          input: i,
          bottomDivider: spacer,
          hasTopDivider: false,
        });
      }
      continue;
    }
    const topDivider = i - 1;
    let bottomDivider = i + 1;
    while (bottomDivider < grid.length && !isDividerRow(grid[bottomDivider]!)) {
      bottomDivider++;
    }
    if (bottomDivider >= grid.length || bottomDivider + 1 >= grid.length) continue;
    if (!isDividerRow(grid[bottomDivider]!)) continue;
    if (!isFooterHintRow(grid[bottomDivider + 1]!)) continue;
    if (!grid.slice(i + 1, bottomDivider).every(isInputContinuationRow)) continue;
    const hasTopDivider = topDivider >= 0 && isDividerRow(grid[topDivider]!);
    blocks.push({
      topDivider: hasTopDivider ? topDivider : i,
      input: i,
      bottomDivider,
      hasTopDivider,
    });
  }
  return blocks;
}

export function assertSingleFooter(
  grid: string[],
  failures: string[],
  label: string,
): FooterBlock | null {
  const footers = findFooterBlocks(grid);
  if (footers.length !== 1) {
    failures.push(`${label}: expected exactly one footer, found ${footers.length}`);
    return footers[0] ?? null;
  }
  return footers[0]!;
}

export function findActiveFileApprovalBlock(
  grid: string[],
): FileApprovalBlock | null {
  const wholeScreen = grid.map(normalizeGridLine);
  const screenText = wholeScreen.join("\n");
  if (
    screenText.includes("Apply this change?") ||
    screenText.includes("Reveal that this file already matches?")
  ) {
    return {
      topDivider: 0,
      bottomDivider: Math.max(0, wholeScreen.length - 1),
      lines: wholeScreen,
      text: screenText,
    };
  }

  const dividers = grid.flatMap((line, index) =>
    isDividerRow(line) ? [index] : []
  );
  for (let index = dividers.length - 2; index >= 0; index--) {
    const topDivider = dividers[index]!;
    const bottomDivider = dividers[index + 1]!;
    const lines = grid
      .slice(topDivider + 1, bottomDivider)
      .map(normalizeGridLine);
    const text = lines.join("\n");
    if (
      text.includes("Apply this change?") ||
      text.includes("Reveal that this file already matches?")
    ) {
      return { topDivider, bottomDivider, lines, text };
    }
  }
  return null;
}

export function assertActiveFileApprovalBlock(
  grid: string[],
  failures: string[],
  label: string,
): FileApprovalBlock | null {
  const block = findActiveFileApprovalBlock(grid);
  if (!block) {
    failures.push(`${label}: active file approval block was not found`);
  }
  return block;
}

export function assertPaneContains(
  pane: string,
  token: string,
  failures: string[],
  label: string,
): void {
  if (!pane.includes(token) && !visibleText(pane).includes(visibleText(token))) {
    failures.push(`${label}: pane is missing ${token}`);
  }
}

export function visibleText(value: string): string {
  return value.replace(/\s+/g, "");
}

export function assertTraceInvariants(
  trace: string,
  failures: string[],
  label: string,
  opts: { allowFooterClean?: boolean; requireToolCall?: boolean } = {},
): void {
  if (!opts.allowFooterClean && trace.includes("[footer.clean]")) {
    failures.push(`${label}: clean footer trace emitted during idle stress`);
  }
  if (opts.requireToolCall && !trace.includes("[tool] event=tool_call")) {
    failures.push(`${label}: trace did not include a tool call`);
  }
  assertTraceGeometry(trace, failures, label);
}

function assertTraceGeometry(
  trace: string,
  failures: string[],
  label: string,
): void {
  let activeRows: number | null = null;
  let activeCols: number | null = null;
  const lines = trace.split(/\r?\n/);

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]!;
    const layout = /layout=(\d+)x(\d+)/.exec(line);
    if (layout) {
      activeCols = parseInt(layout[1]!, 10);
      activeRows = parseInt(layout[2]!, 10);
      if (activeCols <= 0 || activeRows <= 0) {
        failures.push(`${label}: invalid layout at trace line ${index + 1}`);
      }
    }

    if (line.includes("[paint] transcript_select")) {
      const top = numberField(line, "top");
      const bottom = numberField(line, "bottom");
      if (top !== null && bottom !== null) {
        assertRange(top, bottom, activeRows, failures, label, index, "transcript_select");
      }
    }

    if (line.includes("[paint] transcript_diff")) {
      const band = /band=(\d+)\.\.(\d+)/.exec(line);
      const lastVisibleRow = numberField(line, "last_visible_row");
      const replaceableStartRow = numberField(line, "replaceable_start_row");
      if (band) {
        assertRange(
          parseInt(band[1]!, 10),
          parseInt(band[2]!, 10),
          activeRows,
          failures,
          label,
          index,
          "transcript_diff band",
        );
      }
      assertRow(lastVisibleRow, activeRows, failures, label, index, "last_visible_row");
      assertRow(
        replaceableStartRow,
        activeRows,
        failures,
        label,
        index,
        "replaceable_start_row",
      );
    }

    if (line.includes("[paint] footer_layout")) {
      assertRow(numberField(line, "top"), activeRows, failures, label, index, "footer top");
      assertRow(
        numberField(line, "top_divider"),
        activeRows,
        failures,
        label,
        index,
        "top_divider",
      );
      assertRow(
        numberField(line, "input_base"),
        activeRows,
        failures,
        label,
        index,
        "input_base",
      );
      assertRow(
        numberField(line, "bottom_divider"),
        activeRows,
        failures,
        label,
        index,
        "bottom_divider",
      );
      assertRow(numberField(line, "hint"), activeRows, failures, label, index, "hint");
      assertRow(
        numberField(line, "activity_row"),
        activeRows,
        failures,
        label,
        index,
        "activity_row",
        true,
      );
    }

    if (line.includes("[paint] footer_flush")) {
      const clearTop = numberField(line, "clear_top");
      const rows = numberField(line, "rows");
      if (clearTop !== null && rows !== null) {
        assertRange(
          clearTop,
          clearTop + Math.max(0, rows - 1),
          activeRows,
          failures,
          label,
          index,
          "footer_flush",
        );
      }
      assertRow(
        numberField(line, "activity_row"),
        activeRows,
        failures,
        label,
        index,
        "activity_row",
        true,
      );
    }

    if (line.includes("[paint] shimmer_paint")) {
      assertRow(numberField(line, "row"), activeRows, failures, label, index, "shimmer row");
    }
  }
}

function numberField(line: string, name: string): number | null {
  const match = new RegExp(`${name}=(\\d+)`).exec(line);
  return match ? parseInt(match[1]!, 10) : null;
}

function assertRow(
  row: number | null,
  rows: number | null,
  failures: string[],
  label: string,
  index: number,
  field: string,
  zeroMeansNone = false,
): void {
  if (row === null) return;
  if (zeroMeansNone && row === 0) return;
  if (row < 1) {
    failures.push(`${label}: ${field} below row 1 at trace line ${index + 1}`);
    return;
  }
  if (rows !== null && row > rows) {
    failures.push(
      `${label}: ${field} ${row} exceeds ${rows} rows at trace line ${index + 1}`,
    );
  }
}

function assertRange(
  start: number,
  end: number,
  rows: number | null,
  failures: string[],
  label: string,
  index: number,
  field: string,
): void {
  if (start < 1) {
    failures.push(`${label}: ${field} starts below row 1 at trace line ${index + 1}`);
  }
  if (end < start) {
    failures.push(`${label}: ${field} ends before it starts at trace line ${index + 1}`);
  }
  if (rows !== null && end > rows) {
    failures.push(`${label}: ${field} ends at ${end}, past ${rows} rows at trace line ${index + 1}`);
  }
}
