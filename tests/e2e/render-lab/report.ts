import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  findFooters,
  findLogoRows,
  multilineInputMarkersForFrame,
  readFrames,
} from "./analyzer";
import type { RenderLabFrame, RenderLabManifest } from "./types";

export function writeReport(manifest: RenderLabManifest): void {
  const frames = readFrames(manifest);
  const failures = manifest.failures;
  const frameButtons = frames
    .map(
      (frame) =>
        `<button type="button" data-frame="${frame.index}">${pad(frame.index)} ${escapeHtml(frame.event)}</button>`,
    )
    .join("");
  const frameSections = frames.map((frame, index) => renderFrame(manifest, frames, frame, index)).join("\n");
  const firstFailure = failures[0]
    ? `<p class="failure">First failing invariant: <strong>${escapeHtml(failures[0].invariant)}</strong> at frame ${failures[0].frameIndex} (${escapeHtml(failures[0].event)}): ${escapeHtml(failures[0].message)}</p>`
    : `<p class="pass">No analyzer failures.</p>`;
  const nativeMeta = manifest.native
    ? `<div>Native: ${escapeHtml(manifest.native.appName)} (${escapeHtml(manifest.native.termProgram)}), capture ${escapeHtml(manifest.native.capture)}, Command-K ${manifest.native.commandK ? "yes" : "no"}</div>`
    : "";
  const evidenceMeta = manifest.evidence
    ? `<div>Oracle: ${escapeHtml(manifest.evidence.oracle)}</div><div>Capture policy: ${escapeHtml(manifest.evidence.capturePolicy)}</div>`
    : "";
  const benchmarkMeta = manifest.benchmark
    ? `<div>Benchmark threshold: ${manifest.benchmark.threshold.terminalSize.cols}x${manifest.benchmark.threshold.terminalSize.rows} ${manifest.benchmark.threshold.phase} ${manifest.benchmark.threshold.percentile} <= ${manifest.benchmark.threshold.maxMs}ms, actual ${manifest.benchmark.threshold.actualMs === null ? "missing" : `${manifest.benchmark.threshold.actualMs}ms`}, ${manifest.benchmark.threshold.passed ? "passed" : "failed"}</div>`
    : "";
  const failureList =
    failures.length === 0
      ? ""
      : `<ol>${failures
          .map(
            (failure) =>
              `<li><strong>${escapeHtml(failure.invariant)}</strong> frame ${failure.frameIndex} (${escapeHtml(failure.event)}): ${escapeHtml(failure.message)}</li>`,
          )
          .join("")}</ol>`;

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>fx Render Lab - ${escapeHtml(manifest.scenario)}</title>
<style>
:root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
body { margin: 0; background: #101214; color: #e9eef2; }
header { padding: 18px 22px; border-bottom: 1px solid #2d333b; background: #15191d; position: sticky; top: 0; z-index: 2; }
h1 { font-size: 18px; margin: 0 0 8px; }
.meta { color: #a9b4be; font-size: 13px; display: grid; gap: 2px; }
.failure { color: #ffb4a8; }
.pass { color: #9de2b5; }
.layout { display: grid; grid-template-columns: 300px minmax(0, 1fr); min-height: calc(100vh - 108px); }
nav { border-right: 1px solid #2d333b; padding: 14px; background: #111519; overflow: auto; }
nav button { display: block; width: 100%; text-align: left; margin: 0 0 6px; padding: 8px; border: 1px solid #39414a; border-radius: 6px; background: #181d22; color: #e9eef2; cursor: pointer; }
nav button.active { border-color: #77bdfb; background: #193247; }
main { padding: 18px 22px 40px; overflow: auto; }
.frame { display: none; }
.frame.active { display: block; }
.grid { font: 12px/1.35 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; border: 1px solid #303841; background: #080a0c; overflow: auto; padding: 10px 0; }
.row { display: grid; grid-template-columns: 54px 1fr; white-space: pre; min-height: 16px; }
.row-num { color: #697681; text-align: right; padding-right: 12px; user-select: none; }
.cell { padding-right: 12px; }
.logo .cell { background: #1d3145; color: #d6ebff; }
.footer .cell { background: #3a2d1d; color: #ffe2b3; }
.shell .cell { background: #28351f; color: #d4f2bd; }
.submitted .cell { background: #33264a; color: #e1d1ff; }
.trace, .diff { font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; white-space: pre-wrap; background: #0b0d10; border: 1px solid #303841; padding: 12px; overflow: auto; }
.columns { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 16px; margin-top: 16px; }
h2 { font-size: 16px; margin: 0 0 10px; }
h3 { font-size: 13px; color: #a9b4be; margin: 18px 0 8px; }
table { border-collapse: collapse; width: 100%; margin: 14px 0 24px; font-size: 12px; }
th, td { border: 1px solid #303841; padding: 7px 8px; text-align: left; vertical-align: top; }
th { background: #15191d; color: #c8d2dc; }
</style>
</head>
<body>
<header>
<h1>fx Render Lab: ${escapeHtml(manifest.scenario)}</h1>
<div class="meta">
<div>Run: ${escapeHtml(manifest.runId)}</div>
<div>Binary: ${escapeHtml(manifest.binaryPath)} (${escapeHtml(manifest.binarySha256.slice(0, 12))})</div>
<div>Frames: ${frames.length}</div>
${nativeMeta}
${evidenceMeta}
${benchmarkMeta}
</div>
${firstFailure}
${failureList}
</header>
<div class="layout">
<nav>${frameButtons}</nav>
<main>${renderBenchmark(manifest)}${frameSections || "<p>No frame captures for this scenario.</p>"}</main>
</div>
<script>
const buttons = [...document.querySelectorAll("nav button")];
const frames = [...document.querySelectorAll(".frame")];
function showFrame(index) {
  for (const button of buttons) button.classList.toggle("active", button.dataset.frame === String(index));
  for (const frame of frames) frame.classList.toggle("active", frame.dataset.frame === String(index));
}
for (const button of buttons) button.addEventListener("click", () => showFrame(button.dataset.frame));
showFrame(${frames[0]?.index ?? 0});
</script>
</body>
</html>
`;
  writeFileSync(manifest.reportPath, html);
}

function renderBenchmark(manifest: RenderLabManifest): string {
  const benchmark = manifest.benchmark;
  if (!benchmark) return "";
  const rows = benchmark.sizes
    .map(
      (result) => `<tr>
<td>${result.terminalSize.cols}x${result.terminalSize.rows}</td>
<td>${result.runs}</td>
<td>${result.timings.plan.p50Ms} / ${result.timings.plan.p95Ms} / ${result.timings.plan.p99Ms}</td>
<td>${result.timings.paint.p50Ms} / ${result.timings.paint.p95Ms} / ${result.timings.paint.p99Ms}</td>
<td>${result.timings.validate.p50Ms} / ${result.timings.validate.p95Ms} / ${result.timings.validate.p99Ms}</td>
<td>${result.timings.diff.p50Ms} / ${result.timings.diff.p95Ms} / ${result.timings.diff.p99Ms}</td>
<td>${result.timings.combined.p50Ms} / ${result.timings.combined.p95Ms} / ${result.timings.combined.p99Ms}</td>
<td>${result.changedCells.p50} / ${result.changedCells.p95} / ${result.changedCells.p99}</td>
<td>${result.diffBytes.p50} / ${result.diffBytes.p95} / ${result.diffBytes.p99}</td>
<td>${result.fullRepaintCount}</td>
<td>${escapeHtml(result.invalidationReasons.join(", "))}</td>
<td>${escapeHtml(result.allocations.instrumentation)}: ${escapeHtml(result.allocations.hotFrame.note)}</td>
</tr>`,
    )
    .join("");

  return `<section>
<h2>Benchmark</h2>
<p class="${benchmark.threshold.passed ? "pass" : "failure"}">200x80 combined p95 ${benchmark.threshold.actualMs === null ? "missing" : `${benchmark.threshold.actualMs}ms`} / ${benchmark.threshold.maxMs}ms.</p>
<div class="diff">Timing columns are p50 / p95 / p99 in milliseconds. Terminal writer I/O is excluded.</div>
<table>
<thead>
<tr><th>Size</th><th>Runs</th><th>Plan</th><th>Paint</th><th>Validate</th><th>Diff</th><th>Combined</th><th>Changed Cells</th><th>Diff Bytes</th><th>Full Repaints</th><th>Invalidation</th><th>Allocations</th></tr>
</thead>
<tbody>${rows}</tbody>
</table>
</section>`;
}

function renderFrame(
  manifest: RenderLabManifest,
  frames: RenderLabFrame[],
  frame: RenderLabFrame,
  frameArrayIndex: number,
): string {
  const logoRows = new Set(findLogoRows(frame.grid));
  const multilineInputMarkers = multilineInputMarkersForFrame(frame, manifest);
  const footerRows = new Set(findFooters(frame.grid, frame.cursor, multilineInputMarkers).flatMap((footer) => [footer.topDivider, footer.input, footer.bottomDivider, footer.hint]));
  const rows = frame.grid
    .map((line, index) => {
      const classes = ["row"];
      if (logoRows.has(index)) classes.push("logo");
      if (footerRows.has(index)) classes.push("footer");
      if (manifest.markers.shell.some((marker) => line.includes(marker))) classes.push("shell");
      if (manifest.markers.submitted.some((marker) => line.includes(marker))) classes.push("submitted");
      return `<div class="${classes.join(" ")}"><span class="row-num">${pad(index + 1)}</span><span class="cell">${escapeHtml(line)}</span></div>`;
    })
    .join("");
  const previous = frames[frameArrayIndex - 1] ?? null;
  const next = frames[frameArrayIndex + 1] ?? null;
  const previousDiff = previous ? renderDiff(previous, frame) : "No previous frame.";
  const nextDiff = next ? renderDiff(frame, next) : "No next frame.";
  const traceText = frame.traceTail.length > 0 ? frame.traceTail.join("\n") : readTraceTail(manifest.traceLogPath);
  const evidence = frame.evidence
    ? `${frame.evidence.captureSource}, ${frame.evidence.stable ? "stable" : "unstable"}, ${frame.evidence.samples} samples in ${frame.evidence.durationMs}ms, grid ${frame.evidence.gridSha256.slice(0, 12)}, scrollback ${frame.evidence.scrollbackSha256.slice(0, 12)}`
    : "not recorded";

  return `<section class="frame" data-frame="${frame.index}">
<h2>${pad(frame.index)} ${escapeHtml(frame.event)}</h2>
<div class="meta">
<div>${frame.width} x ${frame.height}, cursor ${frame.cursor ? `${frame.cursor.col},${frame.cursor.row}` : "unknown"}</div>
<div>${new Date(frame.timestampMs).toISOString()}</div>
<div>Evidence: ${escapeHtml(evidence)}</div>
</div>
<h3>Visible Grid</h3>
<div class="grid">${rows}</div>
<div class="columns">
<div>
<h3>Previous Frame Diff</h3>
<div class="diff">${escapeHtml(previousDiff)}</div>
</div>
<div>
<h3>Next Frame Diff</h3>
<div class="diff">${escapeHtml(nextDiff)}</div>
</div>
</div>
<h3>Trace Tail Near Frame</h3>
<div class="trace">${escapeHtml(traceText)}</div>
</section>`;
}

function renderDiff(before: RenderLabFrame, after: RenderLabFrame): string {
  const max = Math.max(before.grid.length, after.grid.length);
  const changed: string[] = [];
  for (let i = 0; i < max; i += 1) {
    const a = before.grid[i] ?? "";
    const b = after.grid[i] ?? "";
    if (a !== b) changed.push(`${pad(i + 1)} - ${a}\n${pad(i + 1)} + ${b}`);
    if (changed.length >= 40) break;
  }
  return changed.length > 0 ? changed.join("\n") : "No visible row changes.";
}

function readTraceTail(path: string): string {
  try {
    return readFileSync(path, "utf8").split(/\r?\n/).slice(-80).join("\n");
  } catch {
    return "";
  }
}

function pad(value: number): string {
  return String(value).padStart(4, "0");
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
