import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  findFooterBlocks,
  isInputRow as isRenderedInputRow,
} from "../tui-render-assertions";
import { stdoutFrames } from "./tape";
import type {
  RenderLabFailure,
  RenderLabFrame,
  RenderLabManifest,
} from "./types";

export const ACTIVE_TOOL_MARKER = "Running sleep 1; i=1";
export const TERMINAL_TOOL_MARKER = "Ran sleep 1; i=1";
const ACTIVE_TOOL_FINAL_MARKER = "RENDER_LAB_LOCAL_GATEWAY_OK";
const OBSERVABILITY_PERMISSION_PROMPT = "Would you like to run the following command?";
const OBSERVABILITY_PERMISSION_REVIEW = "Permission needed";

export function commandMoreCount(text: string): number | null {
  const match = text.match(/│ … (\d+) (?:(?:line|lines) more \(ctrl(?:\+| )o to view\)|more \(ctrl(?:\+| )o\)|more)/);
  if (!match) return null;
  const count = Number.parseInt(match[1]!, 10);
  return Number.isInteger(count) ? count : null;
}

export type RenderLabTraceCounters = {
  frameAttempts: number;
  terminalDiffs: number;
  terminalWrites: number;
  invalidations: number;
  invalidationReasons: Record<string, number>;
};

export type RenderLabQuiescenceEvidence = {
  event: string;
  durationMs: number;
  before: RenderLabTraceCounters;
  after: RenderLabTraceCounters;
  delta: RenderLabTraceCounters;
};

type Footer = {
  topDivider: number;
  input: number;
  bottomDivider: number;
  hint: number;
  multiline: boolean;
  hasTopDivider: boolean;
};

export function analyzeRun(manifest: RenderLabManifest) {
  const frames = readFrames(manifest);
  const failures: RenderLabFailure[] = [];

  for (const frame of frames) {
    const multilineInputMarkers = multilineInputMarkersForFrame(frame, manifest);
    const footers = findFooters(
      frame.grid,
      frame.cursor,
      multilineInputMarkers,
    );
    const input_rows = footers.map((footer) => footer.input).filter((rowIndex) => {
      const row = frame.grid[rowIndex] ?? "";
      return !manifest.markers.submitted.some((marker) => row.includes(marker));
    });
    if (input_rows.length === 0 && footers.some((footer) => footer.multiline)) {
      input_rows.push(footers.find((footer) => footer.multiline)!.input);
    }
    const logoRows = findLogoRows(frame.grid);
    const expectsChrome = expectsFxChrome(frame, manifest, logoRows, input_rows);
    const viewerFooterPresent = hasTranscriptViewerFooter(frame.grid);

    if (frame.evidence && !frame.evidence.stable) {
      push(
        failures,
        "unstable-frame-capture",
        frame,
        `visible state did not settle within ${frame.evidence.durationMs}ms after ${frame.evidence.samples} samples`,
      );
    }

    assertActiveToolPlacementScenario(failures, frame, manifest);
    assertUserCardResizeScenario(failures, frame, manifest);
    assertTuiObservabilityFrame(failures, frame, manifest);

    if (countLogoBlocks(frame.grid, logoRows) > 1) {
      push(failures, "single-active-logo", frame, "more than one active Fx logo block is visible");
    }

    if (footers.length > 1) {
      push(failures, "single-active-footer", frame, "more than one active footer block is visible");
    }

    if (expectsChrome && footers.length === 0 && !viewerFooterPresent) {
      push(failures, "footer-missing", frame, "Fx-owned frame has no complete footer block");
    }

    if (input_rows.length > 1) {
      push(failures, "single-active-input", frame, "more than one footer input row is visible");
    }

    if (expectsChrome && input_rows.length === 0 && !viewerFooterPresent) {
      push(failures, "input-missing", frame, "Fx-owned frame has no footer input row");
    }

    assertActivitySpacing(failures, frame, footers[0]);

    for (const footer of footers) {
      if (footer.hint >= frame.height) {
        push(failures, "footer-bounds", frame, "footer extends outside terminal bounds");
      }
      const forbiddenMarkers = multilineInputMarkers.length > 0
        ? manifest.markers.shell
        : [...manifest.markers.shell, ...manifest.markers.submitted];
      for (const rowIndex of footerOwnedRows(footer)) {
        const row = frame.grid[rowIndex] ?? "";
        for (const marker of forbiddenMarkers) {
          if (row.includes(marker)) {
            push(
              failures,
              "footer-transcript-overlap",
              frame,
              `marker ${marker} appears in a footer-owned row`,
            );
          }
        }
      }

      const dividerRows = footer.hasTopDivider
        ? [footer.topDivider, footer.bottomDivider]
        : [];
      const widthFailures = dividerRows.filter((rowIndex) => {
        const width = visibleWidth(frame.grid[rowIndex] ?? "");
        return width > frame.width || width < Math.max(8, Math.floor(frame.width * 0.55));
      });
      if (widthFailures.length > 0) {
        push(
          failures,
          "divider-width",
          frame,
          `footer divider width does not match current terminal width ${frame.width}`,
        );
      }
    }

    if (frame.cursor) {
      if (
        frame.cursor.row < 0 ||
        frame.cursor.col < 0 ||
        frame.cursor.row >= frame.height ||
        frame.cursor.col >= frame.width
      ) {
        push(
          failures,
          "cursor-bounds",
          frame,
          `cursor ${frame.cursor.col},${frame.cursor.row} is outside ${frame.width}x${frame.height}`,
        );
      }
    }

    const fxBand = findFxBand(frame.grid, logoRows, footers[0]);
    if (fxBand) {
      for (const marker of manifest.markers.shell) {
        const badRows = frame.grid
          .slice(fxBand.start, fxBand.end + 1)
          .filter((row) => row.includes(marker));
        if (badRows.length > 0) {
          push(
            failures,
            "shell-marker-in-fx-band",
            frame,
            `shell marker ${marker} appears inside the Fx-owned viewport band`,
          );
        }
      }
    }
  }

  const trace = readOptional(manifest.traceLogPath);
  assertActiveToolScenarioSequence(failures, frames, manifest);
  assertTuiObservabilitySequence(failures, frames, manifest);
  const finalFrame = frames.find((frame) => frame.index === manifest.finalFrameIndex) ?? frames.at(-1);
  if (finalFrame) {
    const clearedShellMarkers = new Set(manifest.markers.clearedShell ?? []);
    const canAssertScrollbackPreserved = capturesFullScrollback(manifest);
    for (const marker of manifest.markers.shell) {
      const count = countOccurrences(finalFrame.scrollback, marker);
      if (clearedShellMarkers.has(marker)) {
        if (count > 0) {
          push(
            failures,
            "cleared-shell-marker-absent",
            finalFrame,
            `shell marker ${marker} is still present after a native clear-scrollback event`,
          );
        }
      } else if (canAssertScrollbackPreserved && count === 0) {
        push(failures, "shell-marker-preserved", finalFrame, `shell marker ${marker} is missing from scrollback`);
      }
    }
    if (isStartupOverflowScenario(manifest.scenario)) {
      assertStartupOverflowSubmittedTransition(failures, finalFrame, manifest);
      assertStartupOverflowHistory(failures, finalFrame, manifest);
    }
  }

  const traceCounters = traceCountersFromTrace(trace);
  const traceFrame = finalFrame ?? frames[0];
  if (!existsSync(manifest.traceLogPath) || trace.length === 0) {
    if (traceFrame) {
      push(failures, "trace-present", traceFrame, "trace log is missing or empty");
    }
  } else {
    const footerCleanCount = countOccurrences(trace, "[footer.clean]");
    const repaintCount =
      countOccurrences(trace, "[render]") +
      countOccurrences(trace, "[paint]");
    if (traceFrame && footerCleanCount > 1500) {
      push(failures, "footer-clean-spam", traceFrame, `trace contains ${footerCleanCount} footer clean lines`);
    }
    if (
      traceFrame &&
      repaintCount > 500 &&
      manifest.scenario !== "active-tool-placement" &&
      manifest.scenario !== "tui-observability-gauntlet"
    ) {
      push(failures, "repaint-spam", traceFrame, `trace contains ${repaintCount} repaint/render lines`);
    }
    if (
      traceFrame &&
      manifest.scenario !== "active-tool-placement" &&
      /\[frame_diff\].*full_repaint=true.*invalidation=none/.test(trace)
    ) {
      push(failures, "unexpected-streaming-full-repaint", traceFrame, "trace contains a full repaint with no frame invalidation");
    }
  }
  if (traceFrame && isStartupOverflowScenario(manifest.scenario)) {
    assertStartupOverflowTrace(failures, traceFrame, manifest, trace);
    assertStartupOverflowTape(failures, traceFrame, manifest);
  }
  if (traceFrame && manifest.scenario === "tui-observability-gauntlet") {
    assertTuiObservabilityTape(failures, traceFrame, manifest);
  }
  if (
    traceFrame &&
    (
      isStartupOverflowScenario(manifest.scenario) ||
      manifest.scenario === "user-card-resize-replay-scrollback" ||
      manifest.scenario === "active-tool-placement" ||
      manifest.scenario === "tui-observability-gauntlet"
    )
  ) {
    const stderr = readOptional(join(manifest.artifactDir, "stderr.log"));
    if (stderr.length > 0) {
      push(failures, "stderr-empty", traceFrame, "fresh binary wrote to stderr");
    }
  }
  if (traceFrame) {
    for (const sample of readQuiescence(manifest)) {
      if (sample.durationMs <= 50) {
        push(
          failures,
          "quiescence-window-too-short",
          traceFrame,
          `${sample.event} measured only ${sample.durationMs}ms`,
        );
      }
      if (
        sample.delta.frameAttempts > 0 ||
        sample.delta.terminalDiffs > 0 ||
        sample.delta.terminalWrites > 0 ||
        sample.delta.invalidations > 0
      ) {
        push(
          failures,
          "quiescent-frame-work",
          traceFrame,
          `${sample.event} delta=${JSON.stringify(sample.delta)}`,
        );
      }
    }
  }
  return {
    failures: earliestByInvariant(failures),
    traceCounters,
  };
}

export function readQuiescence(
  manifest: RenderLabManifest,
): RenderLabQuiescenceEvidence[] {
  const raw = readOptional(join(manifest.artifactDir, "quiescence.json"));
  if (raw.length === 0) return [];
  const parsed: unknown = JSON.parse(raw);
  return Array.isArray(parsed) ? parsed as RenderLabQuiescenceEvidence[] : [];
}

export function readFrames(manifest: RenderLabManifest): RenderLabFrame[] {
  return manifest.frames.map((frame) => {
    const path = join(manifest.artifactDir, frame.jsonPath);
    return JSON.parse(readFileSync(path, "utf8")) as RenderLabFrame;
  });
}

export function findFooters(
  grid: string[],
  cursor: RenderLabFrame["cursor"] = null,
  multilineInputMarkers: string[] = [],
): Footer[] {
  const footers: Footer[] = findFooterBlocks(grid).map((footer) => ({
    ...footer,
    hint: footer.bottomDivider + 1,
    multiline: false,
  }));
  if (footers.length === 0) {
    for (let bottomDivider = 1; bottomDivider + 1 < grid.length; bottomDivider += 1) {
      if (!isDividerRow(grid[bottomDivider] ?? "")) continue;
      if (!isFooterHintRow(grid[bottomDivider + 1] ?? "")) continue;
      for (let topDivider = bottomDivider - 2; topDivider >= 0; topDivider -= 1) {
        if (!isDividerRow(grid[topDivider] ?? "")) continue;
        if (!isMultilineInputBand(grid, topDivider, bottomDivider, cursor, multilineInputMarkers)) continue;
        footers.push({
          topDivider,
          input: cursor!.row,
          bottomDivider,
          hint: bottomDivider + 1,
          multiline: true,
          hasTopDivider: true,
        });
        return footers;
      }
    }
  }
  return footers;
}

function footerOwnedRows(footer: Footer): number[] {
  const rows: number[] = [];
  for (let row = footerStartRow(footer); row <= footer.hint; row += 1) {
    rows.push(row);
  }
  return rows;
}

function footerStartRow(footer: Footer): number {
  return footer.hasTopDivider ? footer.topDivider : footer.input;
}

function isMultilineInputBand(
  grid: string[],
  topDivider: number,
  bottomDivider: number,
  cursor: RenderLabFrame["cursor"],
  inputMarkers: string[],
): boolean {
  if (!cursor || cursor.row <= topDivider || cursor.row >= bottomDivider) return false;
  const rows = grid.slice(topDivider + 1, bottomDivider).map(semanticText);
  if (!inputMarkers.some((marker) => rows.some((row) => row.includes(marker)))) return false;
  if (!rows.some((row) => row.trim().length > 0)) return false;
  return rows.every((row) => row.trim().length === 0 || isInputRow(row) || row.startsWith("  "));
}

export function findLogoRows(grid: string[]): number[] {
  const rows: number[] = [];
  for (let i = 0; i < grid.length; i += 1) {
    const row = grid[i] ?? "";
    if (row.includes("Run /help for commands") || hasLogoGlyphs(row)) {
      rows.push(i);
    }
  }
  return rows;
}

function assertActivitySpacing(failures: RenderLabFailure[], frame: RenderLabFrame, footer: Footer | undefined): void {
  const footerTop = footer ? footerStartRow(footer) : frame.grid.length;
  for (let rowIndex = 0; rowIndex < frame.grid.length; rowIndex += 1) {
    if (!isThinkingRow(frame.grid[rowIndex] ?? "")) continue;

    let after = rowIndex + 1;
    let blankAfter = 0;
    while (after < footerTop && isSemanticBlank(frame.grid[after] ?? "")) {
      blankAfter += 1;
      after += 1;
    }
    if (blankAfter >= 2) {
      push(
        failures,
        "activity-footer-extra-blank",
        frame,
        `thinking row has ${blankAfter} blank rows before the footer divider`,
      );
    }

    let before = rowIndex - 1;
    let blankBefore = 0;
    while (before >= 0 && isSemanticBlank(frame.grid[before] ?? "")) {
      blankBefore += 1;
      before -= 1;
    }
    if (before >= 0 && blankBefore === 0 && isTranscriptContentRow(frame.grid[before] ?? "")) {
      push(failures, "activity-leading-gap-missing", frame, "thinking row has no semantic gap after transcript content");
    }
  }
}

function assertActiveToolPlacementScenario(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
): void {
  if (manifest.scenario !== "active-tool-placement") return;
  const activeMarker = ACTIVE_TOOL_MARKER;
  const terminalMarker = TERMINAL_TOOL_MARKER;

  const grid = frame.grid.join("\n");
  if ([
    "active-tool-clipped",
    "active-tool-resized-visible",
    "active-tool-terminal",
    "active-tool-command-output-collapsed-again",
    "active-tool-final-update",
  ].includes(frame.event)) {
    const isActiveClippedFrame = frame.event === "active-tool-clipped";
    assertMarkerCount(failures, frame, activeMarker, isActiveClippedFrame ? 1 : 0);
    if (isActiveClippedFrame) {
      assertMarkerCount(failures, frame, terminalMarker, 0);
      assertSemanticScrollbackMarkerCount(
        failures,
        frame,
        activeMarker,
        1,
        "active-tool-activity-scrollback-once",
      );
      assertSemanticScrollbackMarkerCount(
        failures,
        frame,
        terminalMarker,
        0,
        "active-tool-terminal-scrollback-absent",
      );
    } else {
      assertMarkerCount(failures, frame, terminalMarker, 1);
      assertSemanticScrollbackMarkerCount(
        failures,
        frame,
        activeMarker,
        0,
        "active-tool-activity-scrollback-absent",
      );
      assertSemanticScrollbackMarkerCount(
        failures,
        frame,
        terminalMarker,
        1,
        "active-tool-terminal-scrollback-once",
      );
    }
    if (commandMoreCount(grid) !== null) {
      push(failures, "active-tool-compact-output-preview", frame, "compact command frame exposed an output preview");
    }
    if (grid.includes("ACTIVE_TOOL_LINE_06") || grid.includes("ACTIVE_TOOL_LINE_32")) {
      push(failures, "active-tool-folded-output-hidden", frame, "compact command frame exposes raw output");
    }
    if (frame.event === "active-tool-final-update") {
      assertScrollbackMarkerCount(
        failures,
        frame,
        ACTIVE_TOOL_FINAL_MARKER,
        1,
        "active-tool-final-update-once",
      );
    }
    return;
  }
  if ([
    "active-tool-command-output-expanded",
    "active-tool-command-output-expanded-shrink",
    "active-tool-command-output-expanded-grow",
  ].includes(frame.event)) {
    assertMarkerCount(failures, frame, activeMarker, 0);
    if (frame.event !== "active-tool-command-output-expanded-shrink") {
      assertMarkerCount(failures, frame, terminalMarker, 1);
    }
    assertSemanticScrollbackMarkerCount(
      failures,
      frame,
      activeMarker,
      0,
      "active-tool-activity-scrollback-absent",
    );
    if (frame.event !== "active-tool-command-output-expanded-shrink") {
      assertSemanticScrollbackMarkerCount(
        failures,
        frame,
        terminalMarker,
        1,
        "active-tool-terminal-scrollback-once",
      );
    }
    if (frame.event !== "active-tool-command-output-expanded-shrink") {
      assertMarkerCount(failures, frame, "ACTIVE_TOOL_LINE_32", 1);
    }
    if (commandMoreCount(grid) !== null) {
      push(failures, "active-tool-expanded-summary", frame, "expanded frame retained its compact summary");
    }
    if (frame.event !== "active-tool-command-output-expanded-shrink") {
      assertCommandOutputScrollback(failures, frame);
    }
    return;
  }
  if (frame.event !== "active-tool-visible") return;

  const markerCount = countOccurrences(grid, activeMarker);
  if (markerCount !== 1) {
    push(
      failures,
      "active-tool-marker-count",
      frame,
      `expected one active marker, found ${markerCount}`,
    );
    return;
  }

  const markerRow = frame.grid.findIndex((row) => row.includes(activeMarker));
  const footer = findFooters(frame.grid, frame.cursor)[0];
  if (!footer) {
    push(failures, "active-tool-footer", frame, "active-tool frame has no footer");
    return;
  }
  const gapRows = frame.grid.slice(markerRow + 1, footerStartRow(footer));
  const placement = gapRows.length === 1 && gapRows.every(isSemanticBlank) ? "transient" : "transcript";
  const expected = "transcript";
  if (placement !== expected) {
    push(
      failures,
      "active-tool-placement",
      frame,
      `expected ${expected} placement, found ${placement}`,
    );
  }
  if (frame.event === "active-tool-visible") {
    assertSemanticScrollbackMarkerCount(
      failures,
      frame,
      activeMarker,
      1,
      "active-tool-activity-scrollback-once",
    );
    assertActiveActivitySequence(failures, frame, manifest, activeMarker);
  }
}

function assertActiveActivitySequence(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
  activeMarker: string,
): void {
  const submittedMarker = manifest.markers.submitted.at(-1);
  if (!submittedMarker) return;

  const lines = frame.scrollback.split("\n");
  const submittedRows = lines.flatMap((line, row) =>
    line.includes(submittedMarker) ? [row] : []
  );
  const groupRows = lines.flatMap((line, row) =>
    line.includes("tool call") && row < lines.length - 1 ? [row] : []
  );
  const activityRows = lines.flatMap((line, row) =>
    line.includes(activeMarker) ? [row] : []
  );
  if (submittedRows.length !== 1 || groupRows.length !== 1 || activityRows.length !== 1) {
    push(
      failures,
      "active-tool-activity-marker-count",
      frame,
      `expected one submitted row, group row, and activity row, found ${submittedRows.length}, ${groupRows.length}, and ${activityRows.length}`,
    );
    return;
  }

  const submittedRow = submittedRows[0]!;
  const groupRow = groupRows[0]!;
  const activityRow = activityRows[0]!;
  if (submittedRow >= groupRow || groupRow >= activityRow) {
    push(
      failures,
      "active-tool-activity-marker-order",
      frame,
      "grouped activity did not follow the submitted prompt",
    );
    return;
  }

  let blankRows = 0;
  for (let row = groupRow - 1; row > submittedRow; row -= 1) {
    if ((lines[row] ?? "").trim().length !== 0) break;
    blankRows += 1;
  }
  if (blankRows !== 1) {
    push(
      failures,
      "active-tool-activity-blank-hole",
      frame,
      `expected one intentional blank row before activity, found ${blankRows}`,
    );
  }
}

function assertActiveToolScenarioSequence(
  failures: RenderLabFailure[],
  frames: RenderLabFrame[],
  manifest: RenderLabManifest,
): void {
  if (
    manifest.scenario !== "active-tool-placement" ||
    !frames.some((frame) => frame.event === "active-tool-final-update")
  ) {
    return;
  }
  const required = [
    "active-tool-visible",
    "active-tool-clipped",
    "active-tool-resized-visible",
    "active-tool-terminal",
    "active-tool-command-output-expanded",
    "active-tool-command-output-expanded-shrink",
    "active-tool-command-output-expanded-grow",
    "active-tool-command-output-collapsed-again",
    "active-tool-final-update",
  ];
  const indices = required.map((event) =>
    frames.findIndex((frame) => frame.event === event)
  );
  const anchor = frames.at(-1);
  if (!anchor) return;
  for (const [offset, event] of required.entries()) {
    if (indices[offset] === -1) {
      push(failures, "active-tool-stage-missing", anchor, `missing ${event}`);
    }
  }
  const present = indices.filter((index) => index >= 0);
  if (present.some((index, offset) => offset > 0 && index <= present[offset - 1]!)) {
    push(
      failures,
      "active-tool-stage-order",
      anchor,
      `stages are out of order: ${required.join(", ")}`,
    );
  }
}

function assertCommandOutputScrollback(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
): void {
  const output = frame.scrollback.trim().length > 0
    ? frame.scrollback
    : frame.grid.join("\n");
  const lines = output.split("\n");
  let previousRow = -1;
  for (let index = 1; index <= 32; index++) {
    const marker = `ACTIVE_TOOL_LINE_${String(index).padStart(2, "0")}`;
    const rows = lines.flatMap((line, row) =>
      line.trimStart().startsWith(`│ ${marker}`) ? [row] : []
    );
    if (rows.length !== 1) {
      push(
        failures,
        "active-tool-command-marker-count",
        frame,
        `expected ${marker} once in full scrollback, found ${rows.length}`,
      );
      continue;
    }
    const row = rows[0]!;
    if (row <= previousRow) {
      push(
        failures,
        "active-tool-command-marker-order",
        frame,
        `${marker} appeared out of source order`,
      );
    }
    if (previousRow >= 0) {
      for (let gap = previousRow + 1; gap < row; gap++) {
        if ((lines[gap] ?? "").trim().length === 0) {
          push(
            failures,
            "active-tool-command-blank-hole",
            frame,
            `blank row separates command markers before ${marker}`,
          );
          break;
        }
      }
    }
    previousRow = row;
  }
}

function assertSemanticScrollbackMarkerCount(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  marker: string,
  expected: number,
  invariant: string,
): void {
  const text = frame.scrollback.trim().length > 0
    ? frame.scrollback
    : frame.grid.join("\n");
  const actual = text
    .split("\n")
    .filter((line) => line.includes(marker))
    .length;
  if (actual !== expected) {
    push(
      failures,
      invariant,
      frame,
      `expected semantic row ${JSON.stringify(marker)} ${expected} time(s), found ${actual}`,
    );
  }
}

function assertScrollbackMarkerCount(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  marker: string,
  expected: number,
  invariant: string,
): void {
  const actual = countOccurrences(frame.scrollback, marker);
  if (actual !== expected) {
    push(
      failures,
      invariant,
      frame,
      `expected ${JSON.stringify(marker)} ${expected} time(s) in full scrollback, found ${actual}`,
    );
  }
}

function assertUserCardResizeScenario(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
): void {
  if (manifest.scenario !== "user-card-resize-replay-scrollback") return;
  if (![
    "user-card-wide",
    "user-card-resized-narrow",
    "user-card-resized-wide",
  ].includes(frame.event)) return;

  for (const submittedMarker of manifest.markers.submitted) {
    const visibleCount = countOccurrences(frame.grid.join("\n"), submittedMarker);
    if (visibleCount !== 1) {
      push(
        failures,
        "user-card-visible-once",
        frame,
        `expected submitted user-card marker ${JSON.stringify(submittedMarker)} once in the active grid, found ${visibleCount}`,
      );
    }
  }

  if (!capturesFullScrollback(manifest)) return;
  for (const marker of [...(manifest.markers.history ?? []), ...manifest.markers.submitted]) {
    const count = countOccurrences(frame.scrollback, marker);
    if (count !== 1) {
      push(
        failures,
        "user-card-scrollback-once",
        frame,
        `expected ${JSON.stringify(marker)} once in full scrollback, found ${count}`,
      );
    }
  }
}

function assertTuiObservabilityFrame(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
): void {
  if (manifest.scenario !== "tui-observability-gauntlet") return;

  const grid = frame.grid.join("\n");
  if (
    frame.event === "observability-permission-inline" ||
    frame.event === "observability-permission-restored"
  ) {
    assertObservabilityCount(
      failures,
      frame,
      grid,
      OBSERVABILITY_PERMISSION_PROMPT,
      1,
      "observability-permission-singleton",
      "active grid",
    );
  }
  if (frame.event === "observability-permission-review") {
    assertObservabilityCount(
      failures,
      frame,
      grid,
      OBSERVABILITY_PERMISSION_REVIEW,
      1,
      "observability-permission-review-singleton",
      "active grid",
    );
  }

  if (
    frame.event === "observability-permission-inline" ||
    frame.event === "observability-permission-restored" ||
    frame.event === "observability-tool-completed"
  ) {
    assertObservabilityScrollbackMarkers(
      failures,
      frame,
      [
        ...manifest.markers.submitted,
        "OBSERVABILITY_TRANSCRIPT_HEAD",
        "OBSERVABILITY_TRANSCRIPT_TAIL",
        ...(frame.event === "observability-tool-completed"
          ? ["OBSERVABILITY_TOOL_OUTPUT"]
          : []),
      ],
    );
  }

  if (frame.event.startsWith("observability-final-")) {
    if (
      grid.includes(OBSERVABILITY_PERMISSION_PROMPT) ||
      grid.includes(OBSERVABILITY_PERMISSION_REVIEW)
    ) {
      push(
        failures,
        "observability-permission-dismissed",
        frame,
        "permission UI remained visible after approval",
      );
    }
    const orderedMarkers = [
      ...manifest.markers.submitted,
      "OBSERVABILITY_TRANSCRIPT_HEAD",
      "OBSERVABILITY_TRANSCRIPT_TAIL",
      "OBSERVABILITY_TOOL_OUTPUT",
      "OBSERVABILITY_FINAL_RESPONSE",
    ];
    assertObservabilityScrollbackMarkers(failures, frame, orderedMarkers);
    assertObservabilityMarkerOrder(failures, frame, orderedMarkers);
  }
}

function assertObservabilityScrollbackMarkers(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  markers: string[],
): void {
  for (const marker of markers) {
    assertObservabilityCount(
      failures,
      frame,
      frame.scrollback,
      marker,
      1,
      "observability-scrollback-once",
      "full scrollback",
    );
  }
}

function assertObservabilityMarkerOrder(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  markers: string[],
): void {
  let previous = -1;
  for (const marker of markers) {
    const index = frame.scrollback.indexOf(marker);
    if (index < 0) return;
    if (index <= previous) {
      push(
        failures,
        "observability-scrollback-order",
        frame,
        `marker ${JSON.stringify(marker)} is out of transcript order`,
      );
      return;
    }
    previous = index;
  }
}

function assertObservabilityCount(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  text: string,
  marker: string,
  expected: number,
  invariant: string,
  source: string,
): void {
  const actual = countOccurrences(text, marker);
  if (actual === expected) return;
  push(
    failures,
    invariant,
    frame,
    `expected ${JSON.stringify(marker)} ${expected} time(s) in ${source}, found ${actual}`,
  );
}

function assertTuiObservabilitySequence(
  failures: RenderLabFailure[],
  frames: RenderLabFrame[],
  manifest: RenderLabManifest,
): void {
  if (manifest.scenario !== "tui-observability-gauntlet") return;
  const required = [
    "observability-permission-inline",
    "observability-permission-review",
    "observability-permission-restored",
    "observability-tool-completed",
    "observability-final-wide",
    "observability-final-narrow",
    "observability-final-restored",
  ];
  const anchor = frames.at(-1);
  if (!anchor) return;
  const indices = required.map((event) =>
    frames.findIndex((frame) => frame.event === event)
  );
  for (const [offset, event] of required.entries()) {
    if (indices[offset] < 0) {
      push(failures, "observability-stage-missing", anchor, `missing ${event}`);
    }
  }
  const present = indices.filter((index) => index >= 0);
  if (present.some((index, offset) => offset > 0 && index <= present[offset - 1]!)) {
    push(
      failures,
      "observability-stage-order",
      anchor,
      `stages are out of order: ${required.join(", ")}`,
    );
  }
}

function assertTuiObservabilityTape(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
): void {
  let tape: string;
  try {
    tape = Buffer.concat(
      stdoutFrames(manifest.tapePath).map((entry) => entry.payload),
    ).toString("binary");
  } catch (error) {
    push(
      failures,
      "observability-tape-parse",
      frame,
      error instanceof Error ? error.message : String(error),
    );
    return;
  }
  const enters = countOccurrences(tape, "\x1b[?1049h");
  const exits = countOccurrences(tape, "\x1b[?1049l");
  if (enters < 1 || exits < 1 || enters !== exits) {
    push(
      failures,
      "observability-alternate-screen-lifecycle",
      frame,
      `expected balanced alternate-screen ownership, found ${enters} enter(s) and ${exits} exit(s)`,
    );
  }
}

function assertMarkerCount(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  marker: string,
  expected: number,
): void {
  const actual = countOccurrences(frame.grid.join("\n"), marker);
  if (actual !== expected) {
    push(
      failures,
      "active-tool-marker-count",
      frame,
      `expected ${JSON.stringify(marker)} ${expected} time(s), found ${actual}`,
    );
  }
}

function isThinkingRow(line: string): boolean {
  return /^(?:• )?thinking(?:\s+\(\d+s\))?(?:\s+\(↑\d+(?:\.\d+)?k?\s+↓\d+(?:\.\d+)?k?\))?$/i.test(
    semanticText(line).trim(),
  );
}

function isTranscriptContentRow(line: string): boolean {
  const text = semanticText(line).trim();
  if (text.length === 0) return false;
  if (isDividerRow(text)) return false;
  if (text.includes("Run /help for commands") || hasLogoGlyphs(text)) return false;
  return true;
}

function isSemanticBlank(line: string): boolean {
  return semanticText(line).trim().length === 0;
}

function semanticText(line: string): string {
  if (line.startsWith("|") && line.endsWith("|")) return line.slice(1, -1);
  return line;
}

function findFxBand(grid: string[], logoRows: number[], footer: Footer | undefined): { start: number; end: number } | null {
  if (logoRows.length === 0 || !footer) return null;
  const start = Math.min(...logoRows);
  const end = footer.hint;
  if (start > end || start < 0 || end >= grid.length) return null;
  return { start, end };
}

function expectsFxChrome(
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
  logoRows: number[],
  inputRows: number[],
): boolean {
  if (
    frame.event.startsWith("shell-") ||
    frame.event.startsWith("native-shell-") ||
    frame.event.startsWith("observability-permission-") ||
    frame.event.includes("help-visible") ||
    frame.event.includes("slash-menu-expanded") ||
    frame.event.includes("final-third-launch-state") ||
    frame.event.includes("fx-quit-requested") ||
    frame.event.includes("post-quit-shell-prompt")
  ) {
    return false;
  }
  if (logoRows.length > 0 || inputRows.length > 0) return true;
  const visible = frame.grid.join("\n");
  return manifest.markers.submitted.some((marker) => visible.includes(marker));
}

function countLogoBlocks(grid: string[], logoRows: number[]): number {
  let blocks = 0;
  let previous = -2;
  for (const row of logoRows) {
    if (row > previous + 1) blocks += 1;
    previous = row;
  }
  if (blocks === 0 && grid.some((row) => row.includes("Run /help for commands"))) return 1;
  return blocks;
}

function hasLogoGlyphs(row: string): boolean {
  let shaded = 0;
  let block = 0;
  for (const char of row) {
    const code = char.codePointAt(0) ?? 0;
    if (code >= 0x2591 && code <= 0x2593) shaded += 1;
    if (code === 0x2588) block += 1;
  }
  return shaded >= 1 && block >= 2;
}

function isInputRow(line: string): boolean {
  return isRenderedInputRow(line);
}

function isFooterHintRow(line: string): boolean {
  const text = semanticText(line).trim();
  return text.length > 0 && !isDividerRow(line) && !isInputRow(text);
}

function hasTranscriptViewerFooter(grid: string[]): boolean {
  for (let row = 0; row + 2 < grid.length; row += 1) {
    const navigation = semanticText(grid[row] ?? "").trim();
    if (
      navigation !== "┃ Review · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close" &&
      navigation !== "┃ Full detail · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close"
    ) {
      continue;
    }
    if (isSemanticBlank(grid[row + 1] ?? "") && isFooterHintRow(grid[row + 2] ?? "")) {
      return true;
    }
  }
  return false;
}

function isDividerRow(line: string): boolean {
  if (line.length < 8) return false;
  let dividerChars = 0;
  for (const char of line) {
    const code = char.codePointAt(0) ?? 0;
    if ((code >= 0x2500 && code <= 0x257f) || code === 0x2550) dividerChars += 1;
  }
  return dividerChars >= Math.floor(line.length * 0.55);
}

function visibleWidth(line: string): number {
  return [...line].length;
}

function earliestByInvariant(failures: RenderLabFailure[]): RenderLabFailure[] {
  const byInvariant = new Map<string, RenderLabFailure>();
  for (const failure of failures) {
    const existing = byInvariant.get(failure.invariant);
    if (!existing || failure.frameIndex < existing.frameIndex) {
      byInvariant.set(failure.invariant, failure);
    }
  }
  return [...byInvariant.values()].sort((a, b) => a.frameIndex - b.frameIndex);
}

function push(failures: RenderLabFailure[], invariant: string, frame: RenderLabFrame, message: string): void {
  failures.push({
    invariant,
    frameIndex: frame.index,
    event: frame.event,
    message,
  });
}

function capturesFullScrollback(manifest: RenderLabManifest): boolean {
  if (!manifest.native) return true;
  return manifest.native.capture !== "terminal-contents";
}

function isStartupOverflowScenario(scenario: string): boolean {
  return (
    scenario === "startup-scrollback-disabled-overflow" ||
    scenario === "startup-scrollback-enabled-overflow"
  );
}

export function multilineInputMarkersForFrame(
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
): string[] {
  return frame.event === "overflow-long-prompt-editor-tail-visible" && !manifest.markers.history
    ? manifest.markers.submitted
    : [];
}

function assertStartupOverflowTrace(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
  trace: string,
): void {
  if (!trace.includes("[frame_layout] fixed_point iteration=")) {
    push(failures, "fixed-point-trace", frame, "trace has no fixed-point planning metadata");
  }
  if (!/\[scroll\] document_append_plan raw_bytes=[1-9]\d* wire_bytes=[1-9]\d*/.test(trace)) {
    push(failures, "document-append-trace", frame, "trace has no planned transcript document append");
  }
  if (!/\[frame_commit\] terminal_movement .*materialized_rows=[1-9]\d*/.test(trace)) {
    push(failures, "document-materialization-trace", frame, "trace has no physically materialized transcript rows");
  }
  if (manifest.scenario === "startup-scrollback-disabled-overflow") {
    if (!/\[scroll\] preserved_row_release .*accepted=[1-9]\d*/.test(trace)) {
      push(failures, "progressive-release-trace", frame, "trace has no accepted preserved-row release");
    }
    if (!/\[scroll\] preserved_row_release .*owned_top=1(?:\s|$)/.test(trace)) {
      push(failures, "progressive-release-row-one", frame, "trace never releases ownership through row 1");
    }
  } else {
    if (/\[scroll\] preserved_row_release .*accepted=[1-9]\d*/.test(trace)) {
      push(failures, "eager-startup-progressive-release", frame, "eager startup unexpectedly released preserved rows");
    }
    if (!/\[frame_layout\] fixed_point .*prior_owned_top=1 post_scroll_owned_top=1/.test(trace)) {
      push(failures, "eager-startup-row-one", frame, "eager startup did not begin from row 1 ownership");
    }
  }
}

function assertStartupOverflowSubmittedTransition(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
): void {
  for (const marker of manifest.markers.submitted) {
    if (!frame.grid.some((row) => row.includes(marker))) {
      push(failures, "submitted-prompt-tail-visible", frame, `submitted prompt marker ${marker} is missing from the active grid`);
    }
  }
  if (!frame.grid.some((row) => {
    const text = semanticText(row);
    return isInputRow(text) && text.trim().length === 1;
  })) {
    push(failures, "submitted-empty-input-visible", frame, "submitted frame has no empty footer prompt");
  }
}

function assertStartupOverflowHistory(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
): void {
  if (!capturesFullScrollback(manifest)) return;
  for (const marker of manifest.markers.history ?? []) {
    if (!frame.scrollback.includes(marker)) {
      push(failures, "submitted-history-preserved", frame, `historical transcript marker ${marker} is missing from scrollback`);
    }
  }
}

function assertStartupOverflowTape(
  failures: RenderLabFailure[],
  frame: RenderLabFrame,
  manifest: RenderLabManifest,
): void {
  let frames;
  try {
    frames = stdoutFrames(manifest.tapePath);
  } catch (error) {
    push(
      failures,
      "tape-parse",
      frame,
      error instanceof Error ? error.message : String(error),
    );
    return;
  }

  const cleanupBytes = new Set([
    "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?25h",
    "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?2026l\x1b[?25h",
  ]);
  let seenFrameCommit = false;
  for (let index = 0; index < frames.length; index += 1) {
    const payload = frames[index]!.payload.toString("binary");
    const previous = index > 0 ? frames[index - 1]!.payload.toString("binary") : "";
    if (payload.includes("\x1b[3J")) {
      push(failures, "tape-no-clear-scrollback", frame, `stdout tape frame ${frames[index]!.index} contains CSI 3 J`);
    }
    if (seenFrameCommit && /^\x1b\[\d+;1H$/.test(previous) && /^\n+$/.test(payload)) {
      push(failures, "tape-no-split-scroll", frame, `stdout tape frames ${frames[index - 1]!.index}-${frames[index]!.index} split terminal scrolling`);
    }
    if (seenFrameCommit && /^\x1b\[\d+;1H\n+$/.test(payload)) {
      push(failures, "tape-no-standalone-scroll", frame, `stdout tape frame ${frames[index]!.index} contains standalone terminal scrolling`);
    }
    if (payload.startsWith("\x18") && !cleanupBytes.has(payload)) {
      push(failures, "tape-cleanup-bytes", frame, `stdout tape frame ${frames[index]!.index} contains unexpected cleanup bytes`);
    }
    if (payload.includes("\x1b[?2026h\x1b[?25l")) {
      seenFrameCommit = true;
    }
  }
}

function countOccurrences(haystack: string, needle: string): number {
  let total = 0;
  let index = 0;
  while (true) {
    const next = haystack.indexOf(needle, index);
    if (next < 0) return total;
    total += 1;
    index = next + needle.length;
  }
}

export function traceCountersFromTrace(trace: string): RenderLabTraceCounters {
  const counters: RenderLabTraceCounters = {
    frameAttempts: 0,
    terminalDiffs: 0,
    terminalWrites: 0,
    invalidations: 0,
    invalidationReasons: {},
  };

  for (const line of trace.split(/\r?\n/)) {
    if (line.includes("[frame_plan] build ")) counters.frameAttempts += 1;
    if (line.includes("[frame_commit] wire_frame ")) counters.terminalWrites += 1;
    if (!line.includes("[frame_diff] result ")) continue;

    counters.terminalDiffs += 1;
    const invalidation = line.match(/\binvalidation=([a-z0-9_]+)/)?.[1];
    if (!invalidation || invalidation === "none") continue;
    counters.invalidations += 1;
    counters.invalidationReasons[invalidation] =
      (counters.invalidationReasons[invalidation] ?? 0) + 1;
  }

  return counters;
}

function readOptional(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}
