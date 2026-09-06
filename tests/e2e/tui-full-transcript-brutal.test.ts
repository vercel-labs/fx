import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { platform, tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeGatewaySse,
  fakeShellRun,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";
import { stdoutFrames } from "./render-lab/tape";

const TIMEOUT = 30_000;
const INPUT_SANITY_BUDGET_MS = 5_000;
const BURST_NAVIGATION_EVENTS = 2_048;
const FULL_FOOTER = "Full detail · ctrl o close";
const HISTORY_DONE = "CTRL_O_BRUTAL_HISTORY_DONE";
const LIVE_START = "CTRL_O_BRUTAL_LIVE_0001";
const LIVE_DONE = "CTRL_O_BRUTAL_LIVE_DONE";
const DRAFT = "CTRL_O_BRUTAL_UNSENT_DRAFT";
const RESUME_DRAFT = "CTRL_O_BRUTAL_RESUME_DRAFT";
const TAIL_SENTINEL = "CTRL_O_TAIL_SENTINEL";
const VIEWPORT_ALLOWANCE_BYTES = 64 * 1024;
const RESIZE_SIZES = [[48, 18], [132, 42], [80, 24], [104, 30]] as const;
const CTRL_O = ["0f"] as const;
const PAGE_UP = ["1b", "5b", "35", "7e"] as const;
const PAGE_DOWN = ["1b", "5b", "36", "7e"] as const;
const WHEEL_UP = ["1b", "5b", "3c", "36", "34", "3b", "31", "3b", "31", "4d"] as const;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

type StressConfig = {
  label: string;
  batches: number;
  toolsPerBatch: number;
  chatLinesPerBatch: number;
  chatProfile?: "verbose" | "realistic-compact";
  fileLines: number;
  liveLines: number;
  liveDelaySeconds?: number;
  historyTimeoutMs?: number;
  cycles: number;
  settledCycles?: number;
  resumeCycles: number;
  oldestPageCount?: number;
  minimumHistoryLines?: number;
  retainArtifacts?: boolean;
  profileSeconds?: number;
};

type TransitionKind = "full" | "scroll" | "close" | "resize" | "ready";

type StressMetrics = {
  transitions: Record<TransitionKind, number[]>;
  terminalBytes: Record<TransitionKind, number[]>;
};

type StressRoot = {
  root: string;
  home: string;
  workspace: string;
  stderrPath: string;
  resumedStderrPath: string;
  tapePath: string;
  metricsPath: string;
  profilePath: string;
  tracePath: string;
  resumedTracePath: string;
};

type ProjectionWindowTrace = {
  cols: number;
  offset: number;
};

function pad(value: number, width = 4): string {
  return String(value).padStart(width, "0");
}

function toolMarker(index: number): string {
  return `CTRL_O_BRUTAL_TOOL_${pad(index)}`;
}

function compactToolMarker(index: number): string {
  return index % 5 === 2 || index % 5 === 4
    ? toolMarker(index)
    : fixturePath(index);
}

function fixturePath(index: number): string {
  return `fixture-${pad(index)}.txt`;
}

function compactChatMarker(globalLine: number): string {
  return `L${pad(globalLine, 5)}`;
}

function firstChatMarker(config: StressConfig): string {
  return config.chatProfile === "realistic-compact"
    ? compactChatMarker(0)
    : "CTRL_O_BRUTAL_CHAT_B00_L0000";
}

function lastChatMarker(config: StressConfig): string {
  const totalLines = config.batches * config.chatLinesPerBatch;
  return config.chatProfile === "realistic-compact"
    ? compactChatMarker(totalLines - 1)
    : `CTRL_O_BRUTAL_CHAT_B${pad(config.batches - 1, 2)}_L${pad(config.chatLinesPerBatch - 1)}`;
}

function countOccurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

function committedAssistantOccurrences(home: string, assistant: string): number {
  const sessionsRoot = join(home, ".fx", "sessions");
  let count = 0;
  for (const entry of readdirSync(sessionsRoot, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name === "latest") continue;
    const eventsPath = join(sessionsRoot, entry.name, "events.jsonl");
    if (!existsSync(eventsPath)) continue;
    for (const line of readFileSync(eventsPath, "utf8").split("\n")) {
      if (line.length === 0) continue;
      const event = JSON.parse(line) as {
        event?: { assistant?: { text?: string } };
      };
      if (event.event?.assistant?.text === assistant) {
        count += 1;
      }
    }
  }
  return count;
}

function percentile(values: number[], fraction: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)]!;
}

function summarize(values: number[]) {
  return {
    count: values.length,
    p50Ms: Number(percentile(values, 0.5).toFixed(3)),
    p90Ms: Number(percentile(values, 0.9).toFixed(3)),
    p95Ms: Number(percentile(values, 0.95).toFixed(3)),
    p99Ms: Number(percentile(values, 0.99).toFixed(3)),
    maxMs: Number(Math.max(0, ...values).toFixed(3)),
  };
}

function summarizeBytes(values: number[]) {
  return {
    count: values.length,
    p50Bytes: percentile(values, 0.5),
    p90Bytes: percentile(values, 0.9),
    p95Bytes: percentile(values, 0.95),
    p99Bytes: percentile(values, 0.99),
    maxBytes: Math.max(0, ...values),
  };
}

function summarizeMemory(values: number[]) {
  return {
    startRssKib: values[0],
    endRssKib: values.at(-1),
    peakRssKib: Math.max(...values),
    growthRssKib: values.at(-1)! - values[0]!,
  };
}

function gatewayEnv(
  home: string,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fake-full-transcript-brutal-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

function makeRoot(label: string): StressRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-ctrl-o-${label}-`)));
  return {
    root,
    home: join(root, "home"),
    workspace: join(root, "workspace"),
    stderrPath: join(root, "stderr.log"),
    resumedStderrPath: join(root, "resumed-stderr.log"),
    tapePath: join(root, "ctrl-o-brutal.fxtape"),
    metricsPath: join(root, "ctrl-o-latency.json"),
    profilePath: join(root, "ctrl-o.sample.txt"),
    tracePath: join(root, "ctrl-o-cache-trace.log"),
    resumedTracePath: join(root, "ctrl-o-resumed-cache-trace.log"),
  };
}

function toolEvent(index: number, fileLines: number): object {
  const marker = toolMarker(index);
  const path = fixturePath(index);
  const common = {
    type: "tool-call",
    toolCallId: `ctrl-o-brutal-call-${pad(index)}`,
  };
  switch (index % 5) {
    case 0:
    case 1:
      return { ...common, toolName: "read_file", input: { path, line_count: fileLines } };
    case 2:
      return {
        ...common,
        toolName: "grep_files",
        input: {
          pattern: marker,
          path,
          mode: "matches",
          head_limit: 20,
          context_lines: 1,
        },
      };
    case 3:
      return {
        ...common,
        toolName: "glob_files",
        input: { pattern: path, mode: "matches" },
      };
    default:
      return {
        ...common,
        toolName: "read_file",
        input: { path: `missing-${marker}.txt`, line_count: fileLines },
      };
  }
}

function realisticChatLine(batch: number, line: number, linesPerBatch: number): string {
  const globalLine = batch * linesPerBatch + line;
  const marker = compactChatMarker(globalLine);
  switch (line) {
    case 0:
      return `## Turn ${batch + 1} ${marker}`;
    case 1:
      return "```zig";
    case 2:
      return `const x_${batch} = 1; // ${marker}`;
    case 3:
      return "```";
    case 4:
      return `| item | state | ${marker}`;
    case 5:
      return "| --- | --- |";
    case 6:
      return `| ${batch} | ok |`;
    case 7:
      return `- [x] task ${marker}`;
    case 8:
      return `> note ${marker}`;
    case 9:
      return "";
    default:
      switch (globalLine % 6) {
        case 0:
          return `${marker} x=1`;
        case 1:
          return `${marker} - [x]`;
        case 2:
          return `${marker} {"ok":1}`;
        case 3:
          return `${marker} fn(){}`;
        case 4:
          return `${marker} $ test`;
        default:
          return `${marker} 界`;
      }
  }
}

function batchResponse(
  batch: number,
  config: StressConfig,
): Response {
  const firstTool = batch * config.toolsPerBatch;
  const chat = Array.from(
    { length: config.chatLinesPerBatch },
    (_, line) => config.chatProfile === "realistic-compact"
      ? realisticChatLine(batch, line, config.chatLinesPerBatch)
      : `CTRL_O_BRUTAL_CHAT_B${pad(batch, 2)}_L${pad(line)} ` +
        `real-world transcript payload ${"wrap-me-".repeat(9)} 界 e\u0301 👩‍💻`,
  ).join("\n");
  const events: object[] = [
    {
      type: "text-delta",
      id: `ctrl-o-brutal-answer-${batch}`,
      delta: `${chat}\n`,
    },
  ];
  for (let offset = 0; offset < config.toolsPerBatch; offset += 1) {
    events.push(toolEvent(firstTool + offset, config.fileLines));
  }
  events.push({
    type: "text-delta",
    id: `ctrl-o-brutal-tail-${batch}`,
    delta: `${TAIL_SENTINEL}_B${pad(batch, 2)}\n`,
  });
  events.push({
    type: "finish",
    finishReason: { unified: "tool-calls", raw: "tool-calls" },
  });
  return fakeGatewaySse(events);
}

function prepareFixture(config: StressConfig): {
  paths: StressRoot;
  gateway: ReturnType<typeof startFakeGateway>;
  totalTools: number;
} {
  const paths = makeRoot(config.label);
  mkdirSync(join(paths.home, ".fx"), { recursive: true });
  mkdirSync(paths.workspace);
  writeFileSync(paths.stderrPath, "");
  writeFileSync(paths.resumedStderrPath, "");
  writeFileSync(paths.tracePath, "");
  writeFileSync(paths.resumedTracePath, "");
  writeFileSync(
    join(paths.home, ".fx", "settings.json"),
    JSON.stringify({
      sandbox: "none",
      permission_mode: "auto",
      permission: {},
      max_agent_steps: config.batches + 12,
      max_tool_result_bytes: 2 * 1024 * 1024,
    }),
  );

  const totalTools = config.batches * config.toolsPerBatch;
  for (let index = 0; index < totalTools; index += 1) {
    const marker = toolMarker(index);
    const lines = Array.from(
      { length: config.fileLines },
      (_, row) =>
        `${marker}_ROW_${pad(row)} ${"tool-output-".repeat(8)} ` +
        `${row % 3 === 0 ? "界" : row % 3 === 1 ? "e\u0301" : "👩‍💻"}`,
    );
    writeFileSync(join(paths.workspace, fixturePath(index)), `${lines.join("\n")}\n`);
  }

  const liveScript = join(paths.workspace, "ctrl-o-live.sh");
  writeFileSync(
    liveScript,
    `#!/bin/sh
i=1
while [ "$i" -le ${config.liveLines} ]; do
  printf 'CTRL_O_BRUTAL_LIVE_%04d sustained-output-%s\\n' "$i" '${"x".repeat(96)}'
  i=$((i + 1))
  sleep ${config.liveDelaySeconds ?? 0.01}
done
`,
  );
  chmodSync(liveScript, 0o755);

  const responses: Response[] = [];
  for (let batch = 0; batch < config.batches; batch += 1) {
    responses.push(batchResponse(batch, config));
  }
  responses.push(fakeGatewayFinalText(`${HISTORY_DONE}\n${TAIL_SENTINEL}`));
  responses.push(fakeShellRun("ctrl-o-brutal-live", "./ctrl-o-live.sh", {
    timeout_ms: 600_000,
  }));
  responses.push(fakeGatewayFinalText(LIVE_DONE));

  const gateway = startDynamicFakeGateway((body) => {
    const request = JSON.parse(body);
    if (request.toolChoice?.type === "none" && request.tools?.length === 0) {
      return fakeGatewayFinalText(
        "Continue the prepared mixed-history workload without repeating completed tools, then run the requested live command.",
      );
    }
    return responses.shift() ?? new Response("Unexpected stress-fixture request", { status: 500 });
  });
  return { paths, gateway, totalTools };
}

async function waitForScrollback(
  session: TmuxSession,
  marker: string,
  timeout = TIMEOUT,
): Promise<string> {
  const deadline = Date.now() + timeout;
  let latest = "";
  while (Date.now() < deadline) {
    latest = await session.captureFullScrollback();
    if (latest.includes(marker)) return latest;
    await Bun.sleep(100);
  }
  throw new Error(`Timed out waiting for ${marker}.\nScrollback:\n${latest}`);
}

async function waitForMode(
  session: TmuxSession,
  mode: "full" | "main",
  draft: string,
): Promise<string> {
  return session.waitForPane((pane) => {
    if (mode === "full") return pane.includes(FULL_FOOTER);
    return composerContains(pane, draft) &&
      !pane.includes(FULL_FOOTER);
  }, TIMEOUT);
}

function traceSize(tracePath: string): number {
  return statSync(tracePath).size;
}

async function waitForTraceAfter(
  tracePath: string,
  startByte: number,
  needles: string[],
): Promise<string> {
  const deadline = Date.now() + TIMEOUT;
  let appended = "";
  while (Date.now() < deadline) {
    appended = readFileSync(tracePath).subarray(startByte).toString("utf8");
    if (needles.every((needle) => appended.includes(needle))) return appended;
    await sleep(25);
  }
  throw new Error(
    `Timed out waiting for trace markers ${JSON.stringify(needles)}.\nTrace:\n${appended}`,
  );
}

async function waitForCommittedFrameAfter(
  tracePath: string,
  startByte: number,
  markers: string[],
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  let appended = "";
  while (Date.now() < deadline) {
    appended = readFileSync(tracePath).subarray(startByte).toString("utf8");
    let offset = 0;
    const committed = [...markers, "attempt_end outcome=committed"].every((marker) => {
      const index = appended.indexOf(marker, offset);
      if (index < 0) return false;
      offset = index + marker.length;
      return true;
    });
    if (committed) return;
    await sleep(25);
  }
  throw new Error(`Timed out waiting for committed ${markers.join(", ")}.\n${appended}`);
}

async function terminalOutputBytes(tapePath: string): Promise<number> {
  const deadline = Date.now() + TIMEOUT;
  while (true) {
    try {
      return stdoutFrames(tapePath).reduce((bytes, frame) => bytes + frame.payload.length, 0);
    } catch (error) {
      if (!(error instanceof Error) ||
        !error.message.startsWith("truncated tape frame") || Date.now() >= deadline) throw error;
      await sleep(25);
    }
  }
}

async function measurePrimaryResize(
  session: TmuxSession,
  tracePath: string,
  tapePath: string,
  cols: number,
  rows: number,
): Promise<number> {
  const before = await terminalOutputBytes(tapePath);
  const start = traceSize(tracePath);
  await session.resizeWindow(cols, rows, 0);
  await waitForCommittedFrameAfter(tracePath, start, ["settled_reset_committed"]);
  return await terminalOutputBytes(tapePath) - before;
}

async function waitForAnyTraceAfter(
  tracePath: string,
  startByte: number,
  needles: readonly string[],
  timeoutMs = TIMEOUT,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const appended = readFileSync(tracePath).subarray(startByte).toString("utf8");
    const matched = needles.find((needle) => appended.includes(needle));
    if (matched) return matched;
    await sleep(25);
  }
  throw new Error(`Timed out waiting for any trace marker ${JSON.stringify(needles)}.`);
}

function projectionWindows(text: string): ProjectionWindowTrace[] {
  return [...text.matchAll(
    /\[full_transcript_cache\] window cols=(\d+) offset=(\d+)/g,
  )].map((match) => ({
    cols: Number(match[1]),
    offset: Number(match[2]),
  }));
}

function latestProjectionWindow(tracePath: string): ProjectionWindowTrace {
  const windows = projectionWindows(readFileSync(tracePath, "utf8"));
  const latest = windows.at(-1);
  if (latest === undefined) {
    throw new Error(`No rendered Ctrl-O viewport in ${tracePath}`);
  }
  return latest;
}

async function waitForScrollableProjection(
  tracePath: string,
): Promise<ProjectionWindowTrace> {
  const deadline = Date.now() + TIMEOUT;
  let latest = latestProjectionWindow(tracePath);
  while (Date.now() < deadline) {
    latest = latestProjectionWindow(tracePath);
    if (latest.offset > 0) return latest;
    await sleep(10);
  }
  throw new Error(
    `Timed out waiting for a scrollable Ctrl-O page. Last offset: ${latest.offset}.`,
  );
}

async function waitForScrolledViewport(
  tracePath: string,
  startByte: number,
  previousOffset: number,
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  let appended = "";
  while (Date.now() < deadline) {
    appended = readFileSync(tracePath).subarray(startByte).toString("utf8");
    const scrollIndex = appended.indexOf("[full_transcript_cache] scroll ");
    if (scrollIndex >= 0) {
      const afterScroll = appended.slice(scrollIndex);
      const windows = projectionWindows(afterScroll);
      if (windows.some((window) => window.offset !== previousOffset)) return;
      const after = afterScroll.match(/ after=(\d+)/)?.[1];
      if (
        after !== undefined &&
        Number(after) !== previousOffset &&
        /frame_plan\] build [^\n]*body=transcript transcript_body=paint/.test(afterScroll)
      ) return;
    }
    await sleep(10);
  }
  throw new Error(
    `Timed out waiting for a rendered Ctrl-O scroll from offset ${previousOffset}.\n` +
    `Trace appended after action:\n${appended}`,
  );
}

async function waitForRenderedViewportAfter(
  tracePath: string,
  startByte: number,
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  let appended = "";
  while (Date.now() < deadline) {
    appended = readFileSync(tracePath).subarray(startByte).toString("utf8");
    if (
      projectionWindows(appended).length > 0 ||
      /attempt_end outcome=committed reasons=[^\n]*modal/.test(appended) ||
      /frame_plan\] build [^\n]*body=transcript transcript_body=paint/.test(appended)
    ) return;
    await sleep(10);
  }
  throw new Error(
    `Timed out waiting for a rendered Ctrl-O frame.\nTrace appended after action:\n${appended}`,
  );
}

async function waitForResizedViewport(
  tracePath: string,
  startByte: number,
  cols: number,
): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  let appended = "";
  while (Date.now() < deadline) {
    appended = readFileSync(tracePath).subarray(startByte).toString("utf8");
    if (projectionWindows(appended).some((window) => window.cols === cols)) return;
    await sleep(10);
  }
  throw new Error(
    `Timed out waiting for a rendered ${cols}-column Ctrl-O viewport.\n` +
    `Trace appended after action:\n${appended}`,
  );
}

async function timeTransition(
  metrics: StressMetrics,
  kind: TransitionKind,
  action: () => Promise<void>,
  visible: () => Promise<unknown>,
  tapePath?: string,
): Promise<void> {
  const bytesBefore = tapePath === undefined ? undefined : await terminalOutputBytes(tapePath);
  const started = performance.now();
  await action();
  await visible();
  metrics.transitions[kind].push(performance.now() - started);
  if (bytesBefore !== undefined) {
    metrics.terminalBytes[kind].push(await terminalOutputBytes(tapePath!) - bytesBefore);
  }
}

function fxProcessId(session: TmuxSession): number {
  const tty = execFileSync(
    "tmux",
    ["display-message", "-t", session.name, "-p", "#{pane_tty}"],
    { encoding: "utf8" },
  ).trim().replace(/^\/dev\//, "");
  const rows = execFileSync("ps", ["-t", tty, "-o", "pid=,comm="], {
    encoding: "utf8",
  }).trim().split("\n");
  const pid = findFxProcessId(rows);
  if (pid !== undefined) return pid;
  throw new Error(`Unable to find fx on ${tty}. Processes:\n${rows.join("\n")}`);
}

function findFxProcessId(rows: readonly string[]): number | undefined {
  for (const row of rows) {
    const match = row.trim().match(/^(\d+)\s+(.+)$/);
    if (!match) continue;
    const command = match[2]!;
    if (command === "fx" || command === FX_BIN || command.endsWith("/fx")) {
      return Number(match[1]);
    }
  }
  return undefined;
}

test("fx process discovery accepts basename and path process names", () => {
  expect(findFxProcessId(["11361 fx"])).toBe(11361);
  expect(findFxProcessId(["11362 /workspace/zig-out/bin/fx"])).toBe(11362);
});

function residentKib(pid: number): number {
  const value = execFileSync("ps", ["-o", "rss=", "-p", String(pid)], {
    encoding: "utf8",
  }).trim();
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) throw new Error(`Invalid RSS for pid ${pid}: ${value}`);
  return parsed;
}

async function sendRepeatedKey(
  session: TmuxSession,
  key: string,
  count: number,
  chunkSize = 128,
  interChunkDelayMs = 0,
): Promise<void> {
  for (let sent = 0; sent < count; sent += chunkSize) {
    await session.sendKeys(
      Array.from({ length: Math.min(chunkSize, count - sent) }, () => key).join(" "),
    );
    if (interChunkDelayMs > 0) await sleep(interChunkDelayMs);
  }
}

async function thrashViewer(
  session: TmuxSession,
  draft: string,
  cycles: number,
  metrics: StressMetrics,
  pid: number,
  rssKib: number[],
  tracePath: string,
  tapePath?: string,
): Promise<void> {
  for (let cycle = 0; cycle < cycles; cycle += 1) {
    await timeTransition(
      metrics,
      "full",
      () => session.sendHexBytes(CTRL_O),
      () => waitForMode(session, "full", draft),
      tapePath,
    );

    const scrollWindow = await waitForScrollableProjection(tracePath);
    const scrollTraceStart = traceSize(tracePath);
    await timeTransition(
      metrics,
      "scroll",
      () => session.sendHexBytes(cycle % 2 === 0 ? PAGE_UP : WHEEL_UP),
      async () => {
        await waitForMode(session, "full", draft);
        await waitForRenderedViewportAfter(tracePath, scrollTraceStart);
      },
      tapePath,
    );
    await timeTransition(
      metrics,
      "ready",
      async () => {},
      async () => {
        await waitForScrolledViewport(
          tracePath,
          scrollTraceStart,
          scrollWindow.offset,
        );
      },
      tapePath,
    );

    if (cycle % 4 === 0) {
      const fullDownWindow = latestProjectionWindow(tracePath);
      const fullDownTraceStart = traceSize(tracePath);
      await timeTransition(
        metrics,
        "scroll",
        () => session.sendHexBytes(PAGE_DOWN),
        async () => {
          await waitForMode(session, "full", draft);
          await waitForRenderedViewportAfter(tracePath, fullDownTraceStart);
        },
        tapePath,
      );
      await timeTransition(
        metrics,
        "ready",
        async () => {},
        async () => {
          await waitForScrolledViewport(
            tracePath,
            fullDownTraceStart,
            fullDownWindow.offset,
          );
        },
        tapePath,
      );
    }

    const [cols, rows] = RESIZE_SIZES[cycle % RESIZE_SIZES.length]!;
    const resizeTraceStart = traceSize(tracePath);
    await timeTransition(
      metrics,
      "resize",
      () => session.resizeWindow(cols, rows),
      async () => {
        await waitForMode(session, "full", draft);
        await waitForRenderedViewportAfter(tracePath, resizeTraceStart);
      },
      tapePath,
    );
    await timeTransition(
      metrics,
      "ready",
      async () => {},
      async () => {
        await waitForResizedViewport(tracePath, resizeTraceStart, cols);
      },
      tapePath,
    );

    const closeTraceStart = traceSize(tracePath);
    const closeKey = cycle % 3 === 0 ? "C-o" : cycle % 3 === 1 ? "Escape" : "C-c";
    await timeTransition(
      metrics,
      "close",
      () => closeKey === "C-o" ? session.sendHexBytes(CTRL_O) : session.sendKeys(closeKey),
      async () => {
        await waitForCommittedFrameAfter(tracePath, closeTraceStart, [
          "close_full_transcript restore=resized",
          "transcript_transition_commit state=stable",
        ]);
        await waitForMode(session, "main", draft);
      },
      tapePath,
    );
    expect(session.paneStatus().dead).toBe(false);
    rssKib.push(residentKib(pid));
  }
}

async function verifyTailSurvivesFull(
  session: TmuxSession,
): Promise<void> {
  await session.sendHexBytes(CTRL_O);
  const full = await waitForMode(session, "full", "");
  expect(full).toContain(TAIL_SENTINEL);
  expect(session.paneStatus().dead).toBe(false);

  await session.sendHexBytes(CTRL_O);
  await session.waitForComposer(TIMEOUT);
}

async function verifyOldestTranscriptEntrySurvives(
  session: TmuxSession,
  draft: string,
  config: StressConfig,
): Promise<void> {
  await session.sendHexBytes(CTRL_O);
  const newest = await waitForMode(session, "full", draft);
  expect(newest).toContain(LIVE_DONE);
  const sourceLines = config.batches *
    (config.chatLinesPerBatch + config.toolsPerBatch * config.fileLines) + config.liveLines;
  const pageCount = config.oldestPageCount ?? Math.max(1_024, sourceLines);
  const pageChunk = 64;
  for (let sent = 0; sent < pageCount; sent += pageChunk) {
    await sendRepeatedKey(
      session,
      "PPage",
      Math.min(pageChunk, pageCount - sent),
      pageChunk,
      300,
    );
    const pane = await waitForMode(session, "full", draft);
    if (pane.includes(firstChatMarker(config))) break;
  }
  const oldestMarker = firstChatMarker(config);
  const oldest = await session.waitForText(oldestMarker, TIMEOUT * 4);
  expect(oldest).toContain(oldestMarker);

  await session.sendHexBytes(CTRL_O);
  await waitForMode(session, "main", draft);
}

function olderRetainedChatMarker(
  pane: string,
  config: StressConfig,
): string | undefined {
  const lastChatLine = config.batches * config.chatLinesPerBatch - 1;
  if (config.chatProfile === "realistic-compact") {
    return [...pane.matchAll(/L(\d{5})/g)]
      .find((match) => Number(match[1]) < lastChatLine)?.[0];
  }

  return [...pane.matchAll(/CTRL_O_BRUTAL_CHAT_B(\d{2})_L(\d{4})/g)]
    .find((match) =>
      Number(match[1]) * config.chatLinesPerBatch + Number(match[2]) < lastChatLine
    )?.[0];
}

async function verifyResumedTranscriptNavigation(
  session: TmuxSession,
  draft: string,
  config: StressConfig,
  totalTools: number,
): Promise<void> {
  await session.sendHexBytes(CTRL_O);
  const newest = await waitForMode(session, "full", draft);
  expect(newest).toContain(LIVE_DONE);

  // The footer can stay visible while the scrolled page is still being built.
  let older = newest;
  for (let sent = 0; sent < 512; sent += 64) {
    const previous = older;
    await sendRepeatedKey(session, "PPage", 64, 64, 300);
    older = await session.waitForPane(
      (pane) => pane.includes(FULL_FOOTER) && pane !== previous,
      TIMEOUT,
    );
    if (
      olderRetainedChatMarker(older, config) !== undefined ||
      [...older.matchAll(/CTRL_O_BRUTAL_TOOL_(\d{4})/g)]
        .some((match) => Number(match[1]) < totalTools - 1)
    ) break;
  }
  expect(older).toContain(FULL_FOOTER);
  const retainedChat = olderRetainedChatMarker(older, config);
  const retainedTool = [...older.matchAll(/CTRL_O_BRUTAL_TOOL_(\d{4})/g)]
    .map((match) => Number(match[1]))
    .find((index) => index < totalTools - 1);
  expect(retainedChat ?? retainedTool).toBeDefined();
  const retainedMarker = retainedChat ?? toolMarker(retainedTool!);

  expect(older).toContain(retainedMarker);

  await session.sendHexBytes(CTRL_O);
  await waitForMode(session, "main", draft);
}

function alternateScreenStats(tape: Buffer) {
  let depth = 0;
  let maximumDepth = 0;
  let enters = 0;
  let leaves = 0;
  for (const match of tape.toString("latin1").matchAll(/\x1b\[\?1049([hl])/g)) {
    if (match[1] === "h") {
      enters += 1;
      depth += 1;
      maximumDepth = Math.max(maximumDepth, depth);
    } else {
      leaves += 1;
      depth -= 1;
    }
    expect(depth).toBeGreaterThanOrEqual(0);
  }
  return { depth, maximumDepth, enters, leaves };
}

async function runStress(config: StressConfig): Promise<StressRoot> {
  const { paths, gateway, totalTools } = prepareFixture(config);
  const metrics: StressMetrics = {
    transitions: { full: [], scroll: [], close: [], resize: [], ready: [] },
    terminalBytes: { full: [], scroll: [], close: [], resize: [], ready: [] },
  };
  const settledMetrics: StressMetrics = {
    transitions: { full: [], scroll: [], close: [], resize: [], ready: [] },
    terminalBytes: { full: [], scroll: [], close: [], resize: [], ready: [] },
  };
  const primaryRssKib: number[] = [];
  const resumedRssKib: number[] = [];
  let session: TmuxSession | null = null;
  let resumedGateway: ReturnType<typeof startFakeGateway> | null = null;
  let profiler: ReturnType<typeof Bun.spawn> | null = null;
  let passed = false;
  try {
    session = await TmuxSession.create({
      cmd: FX_BIN,
      cwd: realpathSync(paths.workspace),
      env: {
        ...gatewayEnv(paths.home, gateway),
        FX_RECORD: paths.tapePath,
        FX_RECORD_INPUT: "1",
        FX_TRACE_LOG: paths.tracePath,
        FX_TRACE_SCOPES:
          "full_transcript_cache,full_transcript,scroll,frame_render,terminal_diff,frame_schedule,frame_plan,resize",
      },
      stderrPath: paths.stderrPath,
      width: 104,
      height: 30,
      minimumHistoryLines: config.minimumHistoryLines ?? 50_000,
    });
    await session.waitForComposer(TIMEOUT);
    await session.sendText("Build the prepared mixed history under sustained load.");
    await waitForScrollback(
      session,
      HISTORY_DONE,
      config.historyTimeoutMs ?? TIMEOUT * 4,
    );
    // Held transcript rows settle into native scrollback on the frames
    // right after the answer completes; wait for the settled markers
    // instead of asserting one racy snapshot.
    await waitForScrollback(session, compactToolMarker(0), TIMEOUT);
    const history = await waitForScrollback(
      session,
      compactToolMarker(totalTools - 1),
      TIMEOUT,
    );
    expect(countOccurrences(history, HISTORY_DONE)).toBe(1);
    expect(history).toContain(firstChatMarker(config));
    expect(history).toContain(lastChatMarker(config));
    expect(history).toContain(compactToolMarker(0));

    await verifyTailSurvivesFull(session);
    expect(readFileSync(paths.stderrPath, "utf8")).toBe("");

    await session.sendText("Run the prepared live command while I inspect the transcript.");
    await session.waitForText("Running ./ctrl-o-live.sh", TIMEOUT);
    await session.sendLiteralText(DRAFT);
    await waitForMode(session, "main", DRAFT);
    const pid = fxProcessId(session);
    const rssBeforeThrash = residentKib(pid);
    primaryRssKib.push(rssBeforeThrash);

    const immediateTraceStart = traceSize(paths.tracePath);
    const escapeStarted = performance.now();
    session.sendKeysImmediate(["C-o"]);
    await waitForAnyTraceAfter(
      paths.tracePath,
      immediateTraceStart,
      [
        "open_request state=pending",
        "depth_transition from=inline to=full route=root trigger=ctrl_o",
      ],
    );
    session.sendKeysImmediate(["Escape"]);
    await waitForAnyTraceAfter(paths.tracePath, immediateTraceStart, [
      "open_request state=cancelled",
      "depth_transition from=full to=inline route=root trigger=escape",
    ]);
    await waitForMode(session, "main", DRAFT);
    expect(performance.now() - escapeStarted).toBeLessThan(INPUT_SANITY_BUDGET_MS);

    const repeatedOpenTraceStart = traceSize(paths.tracePath);
    const repeatedOpenStarted = performance.now();
    session.sendKeysImmediate(["C-o"]);
    await waitForTraceAfter(paths.tracePath, repeatedOpenTraceStart, [
      "depth_transition from=inline to=full route=root trigger=ctrl_o",
    ]);
    await waitForMode(session, "full", DRAFT);
    expect(performance.now() - repeatedOpenStarted).toBeLessThan(
      INPUT_SANITY_BUDGET_MS,
    );
    await session.sendKeys("Escape");
    await waitForMode(session, "main", DRAFT);

    await session.sendKeys("C-o");
    await waitForMode(session, "full", DRAFT);
    const burstScrollWindow = await waitForScrollableProjection(paths.tracePath);
    const burstScrollTraceStart = traceSize(paths.tracePath);
    const burstScrollStarted = performance.now();
    session.sendRepeatedKeyThenImmediate(
      "PPage",
      BURST_NAVIGATION_EVENTS,
      "PPage",
    );
    await waitForMode(session, "full", DRAFT);
    await waitForScrolledViewport(
      paths.tracePath,
      burstScrollTraceStart,
      burstScrollWindow.offset,
    );
    expect(performance.now() - burstScrollStarted).toBeLessThan(
      INPUT_SANITY_BUDGET_MS,
    );

    const burstEscapeTraceStart = traceSize(paths.tracePath);
    const burstEscapeStarted = performance.now();
    session.sendRepeatedKeyThenImmediate(
      "PPage",
      BURST_NAVIGATION_EVENTS,
      "Escape",
    );
    await waitForTraceAfter(paths.tracePath, burstEscapeTraceStart, [
      "depth_transition from=full to=inline route=root trigger=escape",
    ]);
    await waitForMode(session, "main", DRAFT);
    expect(performance.now() - burstEscapeStarted).toBeLessThan(
      INPUT_SANITY_BUDGET_MS,
    );

    if (config.profileSeconds !== undefined) {
      profiler = Bun.spawn([
        "/usr/bin/sample",
        String(pid),
        String(config.profileSeconds),
        "1",
        "-mayDie",
        "-file",
        paths.profilePath,
      ], { stdout: "pipe", stderr: "pipe" });
    }

    await thrashViewer(
      session,
      DRAFT,
      config.cycles,
      metrics,
      pid,
      primaryRssKib,
      paths.tracePath,
      paths.tapePath,
    );
    const primaryResizeBytes: number[] = [];
    const writeMetrics = () => {
      const summary = {
        config,
        transitions: {
          full: summarize(metrics.transitions.full),
          scroll: summarize(metrics.transitions.scroll),
          close: summarize(metrics.transitions.close),
          resize: summarize(metrics.transitions.resize),
          ready: summarize(metrics.transitions.ready),
        },
        settledTransitions: {
          full: summarize(settledMetrics.transitions.full),
          scroll: summarize(settledMetrics.transitions.scroll),
          close: summarize(settledMetrics.transitions.close),
          resize: summarize(settledMetrics.transitions.resize),
          ready: summarize(settledMetrics.transitions.ready),
        },
        terminalBytes: {
          full: summarizeBytes(metrics.terminalBytes.full),
          scroll: summarizeBytes(metrics.terminalBytes.scroll),
          close: summarizeBytes(metrics.terminalBytes.close),
          resize: summarizeBytes(metrics.terminalBytes.resize),
          ready: summarizeBytes(metrics.terminalBytes.ready),
        },
        settledTerminalBytes: {
          full: summarizeBytes(settledMetrics.terminalBytes.full),
          scroll: summarizeBytes(settledMetrics.terminalBytes.scroll),
          close: summarizeBytes(settledMetrics.terminalBytes.close),
          resize: summarizeBytes(settledMetrics.terminalBytes.resize),
          ready: summarizeBytes(settledMetrics.terminalBytes.ready),
        },
        memory: summarizeMemory(primaryRssKib),
        resumedMemory: resumedRssKib.length > 0
          ? summarizeMemory(resumedRssKib)
          : null,
        primaryResizeBytes,
        raw: metrics,
        rawSettled: settledMetrics,
        rawMemory: { primaryRssKib, resumedRssKib },
      };
      writeFileSync(paths.metricsPath, `${JSON.stringify(summary, null, 2)}\n`);
      return summary;
    };
    writeMetrics();
    const finalScrollback = await waitForScrollback(session, LIVE_DONE, TIMEOUT * 2);
    expect(finalScrollback).toContain(LIVE_DONE);
    // Terminal reset may duplicate a visible line in tmux; durable state must not.
    expect(committedAssistantOccurrences(paths.home, LIVE_DONE)).toBe(1);
    if ((config.settledCycles ?? 0) > 0) {
      await thrashViewer(
        session,
        DRAFT,
        config.settledCycles!,
        settledMetrics,
        pid,
        primaryRssKib,
        paths.tracePath,
        paths.tapePath,
      );
    }
    // Settled history bounds the streaming prefix measured above at every geometry.
    await measurePrimaryResize(session, paths.tracePath, paths.tapePath, 120, 36);
    for (const [cols, rows] of RESIZE_SIZES) {
      primaryResizeBytes.push(await measurePrimaryResize(
        session, paths.tracePath, paths.tapePath, cols, rows,
      ));
    }
    await verifyOldestTranscriptEntrySurvives(session, DRAFT, config);

    if (profiler) {
      const profileExit = await profiler.exited;
      expect(profileExit).toBe(0);
      expect(existsSync(paths.profilePath)).toBe(true);
      const profile = readFileSync(paths.profilePath, "utf8");
      expect(profile).toContain("Call graph:");
    }

    const altStats = alternateScreenStats(readFileSync(paths.tapePath));
    expect(altStats.maximumDepth).toBe(1);
    expect(altStats.enters).toBeGreaterThanOrEqual(config.cycles);
    expect(altStats.leaves).toBe(altStats.enters);
    expect(altStats.depth).toBe(0);
    expect(readFileSync(paths.stderrPath, "utf8")).toBe("");

    const summary = writeMetrics();
    expect(summary.transitions.full.p95Ms).toBeLessThan(5_000);
    expect(summary.transitions.scroll.p95Ms).toBeLessThan(5_000);
    expect(summary.transitions.close.p95Ms).toBeLessThan(5_000);
    expect(summary.transitions.resize.p95Ms).toBeLessThan(5_000);
    expect(summary.transitions.ready.maxMs).toBeLessThan(30_000);
    const budgetTransitions = (config.settledCycles ?? 0) > 0
      ? summary.settledTransitions
      : summary.transitions;
    // The budget includes terminal backpressure and host jitter.
    expect(budgetTransitions.full.p95Ms).toBeLessThan(3_500);
    expect(budgetTransitions.scroll.p95Ms).toBeLessThan(3_500);
    expect(budgetTransitions.close.p95Ms).toBeLessThan(2_500);
    expect(budgetTransitions.resize.p95Ms).toBeLessThan(3_000);
    if ((config.settledCycles ?? 0) > 0) {
      // Opening after a resize may emit one repair frame and the Full viewport.
      expect(summary.settledTerminalBytes.full.maxBytes).toBeLessThan(64 * 1024);
    }
    // Full-open cost must remain independent of total chat size.
    expect(summary.terminalBytes.full.maxBytes).toBeLessThan(128 * 1024);
    expect(summary.terminalBytes.close.maxBytes).toBeLessThan(
      Math.max(...primaryResizeBytes) + VIEWPORT_ALLOWANCE_BYTES,
    );
    expect(summary.memory.growthRssKib).toBeLessThan(256 * 1024);

    await session.sendKeys("C-u");
    await session.waitForComposer(TIMEOUT);
    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
    await session.kill();
    session = null;

    if (config.resumeCycles > 0) {
      resumedGateway = startFakeGateway([]);
      session = await TmuxSession.create({
        cmd: `${FX_BIN} --resume-last`,
        cwd: realpathSync(paths.workspace),
        env: {
          ...gatewayEnv(paths.home, resumedGateway),
          FX_TRACE_LOG: paths.resumedTracePath,
          FX_TRACE_SCOPES:
            "full_transcript_cache,full_transcript,scroll,frame_render,terminal_diff,frame_schedule,frame_plan,resize",
        },
        stderrPath: paths.resumedStderrPath,
        width: 96,
        height: 28,
        minimumHistoryLines: config.minimumHistoryLines ?? 50_000,
        startupWaitMs: 0,
      });
      await waitForTraceAfter(paths.resumedTracePath, 0, [
        "transcript_transition_commit state=recovering",
      ]);
      const resumeTraceStart = traceSize(paths.resumedTracePath);
      const resumeInputStarted = performance.now();
      session.sendKeysImmediate(["C-o"]);
      const resumeInputTrace = await waitForTraceAfter(
        paths.resumedTracePath,
        resumeTraceStart,
        [
          "depth_transition from=inline to=full route=root trigger=ctrl_o",
        ],
      );
      expect(resumeInputTrace).not.toContain(
        "transcript_transition_commit state=stable",
      );
      await waitForMode(session, "full", RESUME_DRAFT);
      expect(performance.now() - resumeInputStarted).toBeLessThan(
        INPUT_SANITY_BUDGET_MS,
      );
      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
      const resumedScrollback = await waitForScrollback(
        session,
        LIVE_DONE,
        TIMEOUT * 2,
      );
      expect(resumedScrollback).toContain(HISTORY_DONE);
      await session.sendLiteralText(RESUME_DRAFT);
      await waitForMode(session, "main", RESUME_DRAFT);
      const resumedPid = fxProcessId(session);
      resumedRssKib.push(residentKib(resumedPid));
      await thrashViewer(
        session,
        RESUME_DRAFT,
        config.resumeCycles,
        metrics,
        resumedPid,
        resumedRssKib,
        paths.resumedTracePath,
      );
      await verifyResumedTranscriptNavigation(session, RESUME_DRAFT, config, totalTools);
      expect(resumedGateway.requests).toHaveLength(0);
      expect(readFileSync(paths.resumedStderrPath, "utf8")).toBe("");
      expect(summarizeMemory(resumedRssKib).growthRssKib).toBeLessThan(256 * 1024);
      await session.sendKeys("C-u");
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
    }

    writeMetrics();
    passed = true;
    return paths;
  } finally {
    if (profiler) {
      try {
        profiler.kill();
      } catch {}
    }
    if (session) await session.kill();
    gateway.stop();
    resumedGateway?.stop();
    if (config.profileSeconds !== undefined || config.retainArtifacts || !passed) {
      console.error(`retained Ctrl-O stress artifacts at ${paths.root}`);
    } else {
      rmSync(paths.root, { recursive: true, force: true });
    }
  }
}

test.skipIf(!tmuxAvailable())(
  "Ctrl-O keeps saved tool output intact across window replacement",
  async () => {
    const paths = makeRoot("saved-result-lifetime");
    mkdirSync(join(paths.home, ".fx"), { recursive: true });
    mkdirSync(paths.workspace);
    const lines = Array.from({ length: 300 }, (_, i) =>
      `SAVED_ROW_${String(i + 1).padStart(4, "0")} original tool output`,
    );
    writeFileSync(join(paths.workspace, "saved.txt"), lines.join("\n") + "\n");
    const savedGateway = startFakeGateway([
      fakeGatewayToolCall("saved-read", "read_file", { path: "saved.txt", line_count: 300 }),
      fakeGatewayFinalText("Saved read complete."),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: paths.workspace,
        env: { ...gatewayEnv(paths.home, savedGateway), FX_RECORD: paths.tapePath },
        stderrPath: paths.stderrPath,
        width: 100,
        height: 32,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Read saved.txt completely.");
      await active.waitForText("Saved read complete.", TIMEOUT);
      for (const width of [100, 80]) {
        await active.resizeWindow(width, 32);
        await active.sendHexBytes(CTRL_O);
        await active.waitForText(FULL_FOOTER, TIMEOUT);
        let previous = await active.waitForText("SAVED_ROW_0300", TIMEOUT);
        // Each accepted page must show earlier original rows, including cache misses.
        for (let page = 0; page < 6; page++) {
          const first = Number(previous.match(/SAVED_ROW_(\d+)/)?.[1]);
          expect(first).toBeGreaterThan(1);
          await active.sendHexBytes(PAGE_UP);
          previous = await active.waitForPane((pane) => {
            const current = Number(pane.match(/SAVED_ROW_(\d+)/)?.[1]);
            return current > 0 && current < first;
          }, TIMEOUT);
          expect(previous).not.toContain("Full saved result unavailable.");
          for (const marker of previous.matchAll(/SAVED_ROW_(\d+)/g)) {
            expect(previous).toContain(lines[Number(marker[1]) - 1]!);
          }
        }
        await active.sendHexBytes(CTRL_O);
        await active.waitForComposer(TIMEOUT);
      }
      const scrollback = await active.captureFullScrollback();
      expect(scrollback).toContain("Saved read complete.");
      expect(scrollback).not.toContain("Full saved result unavailable.");
      expect(savedGateway.requests).toHaveLength(2);
      expect(active.isAlive()).toBe(true);
      expect(readFileSync(paths.stderrPath, "utf8")).toBe("");
    } finally {
      await active?.kill();
      savedGateway.stop();
      rmSync(paths.root, { recursive: true, force: true });
    }
  },
  60_000,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O fills a viewport taller than the prepared overscan cache",
  async () => {
    const paths = makeRoot("tall-viewport");
    mkdirSync(join(paths.home, ".fx"), { recursive: true });
    mkdirSync(paths.workspace);
    writeFileSync(paths.stderrPath, "");
    const tallTail = "TALL_TRANSCRIPT_TAIL";
    const response = Array.from(
      { length: 500 },
      (_, index) => index === 499
        ? tallTail
        : `TALL_TRANSCRIPT_ROW_${String(index).padStart(3, "0")}`,
    ).join("\n");
    const tallGateway = startFakeGateway([fakeGatewayFinalText(response)]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: realpathSync(paths.workspace),
        env: gatewayEnv(paths.home, tallGateway),
        stderrPath: paths.stderrPath,
        width: 80,
        height: 220,
        minimumHistoryLines: 2_000,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Build a tall transcript.");
      await active.waitForText(tallTail, TIMEOUT);
      await active.sendHexBytes(CTRL_O);
      const full = await active.waitForText(FULL_FOOTER, TIMEOUT);
      const rows = full.split("\n");
      const tail_row = rows.findIndex((row) => row.includes(tallTail));
      const footer_row = rows.findIndex((row) => row.includes(FULL_FOOTER));
      expect(tail_row).toBeGreaterThanOrEqual(0);
      expect(footer_row).toBeGreaterThan(tail_row);
      expect(footer_row - tail_row).toBeLessThanOrEqual(6);

      await active.sendHexBytes(CTRL_O);
      await active.waitForComposer(TIMEOUT);
      expect(readFileSync(paths.stderrPath, "utf8")).toBe("");
    } finally {
      await active?.kill();
      tallGateway.stop();
      rmSync(paths.root, { recursive: true, force: true });
    }
  },
  60_000,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O resized close preserves long history within ordinary resize cost",
  async () => {
    const paths = makeRoot("resize-recovery-cost");
    mkdirSync(join(paths.home, ".fx"), { recursive: true });
    mkdirSync(paths.workspace);
    const paragraphs = Array.from({ length: 4_000 }, (_, index) =>
      `ROW${pad(index + 1)} ALPHA_abcdefghijklmnopqrstuvwxyz0123456789 ` +
      "BRAVO_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    );
    const gateway = startFakeGateway([fakeGatewayFinalText(paragraphs.join("\n\n"))]);
    let session: TmuxSession | null = null;
    let passed = false;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: paths.workspace,
        env: {
          ...gatewayEnv(paths.home, gateway),
          FX_RECORD: paths.tapePath,
          FX_TRACE_LOG: paths.tracePath,
          FX_TRACE_SCOPES: "full_transcript,full_transcript_cache,scroll,frame_schedule,resize",
        },
        stderrPath: paths.stderrPath,
        width: 120,
        height: 36,
        minimumHistoryLines: 50_000,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Return the prepared long response.");
      await session.waitForText("ROW4000", TIMEOUT);
      await session.waitForStableComposer(TIMEOUT);
      await session.sendLiteralText(DRAFT);
      await waitForMode(session, "main", DRAFT);
      const completeHistory = async () => {
        const text = (await session!.captureFullScrollback()).replace(/\s+/g, "");
        let previous = -1;
        for (const paragraph of paragraphs) {
          const needle = paragraph.replace(/\s+/g, "");
          const index = text.indexOf(needle);
          expect(index).toBeGreaterThan(previous);
          expect(text.indexOf(needle, index + 1)).toBe(-1);
          previous = index;
        }
      };
      await completeHistory();
      const primaryBytes = await measurePrimaryResize(session, paths.tracePath, paths.tapePath, 88, 24);
      await completeHistory();
      await measurePrimaryResize(session, paths.tracePath, paths.tapePath, 120, 36);
      await session.sendHexBytes(CTRL_O);
      await waitForMode(session, "full", DRAFT);
      const resizeStart = traceSize(paths.tracePath);
      await session.resizeWindow(88, 24, 0);
      await waitForCommittedFrameAfter(paths.tracePath, resizeStart, ["settled_reset_committed"]);
      const closeStart = traceSize(paths.tracePath);
      const beforeClose = await terminalOutputBytes(paths.tapePath);
      const started = performance.now();
      session.sendKeysImmediate(["Escape"]);
      await waitForCommittedFrameAfter(paths.tracePath, closeStart, [
        "close_full_transcript restore=resized",
        "transcript_transition_commit state=stable",
      ]);
      await waitForMode(session, "main", DRAFT);
      expect(performance.now() - started).toBeLessThan(2_500);
      const closeBytes = await terminalOutputBytes(paths.tapePath) - beforeClose;
      expect(closeBytes).toBeLessThan(primaryBytes + VIEWPORT_ALLOWANCE_BYTES);
      await completeHistory();

      await session.sendHexBytes(CTRL_O);
      await waitForMode(session, "full", DRAFT);
      const beforeOrdinaryClose = await terminalOutputBytes(paths.tapePath);
      const ordinaryCloseStart = traceSize(paths.tracePath);
      await session.sendKeys("Escape");
      await waitForCommittedFrameAfter(paths.tracePath, ordinaryCloseStart, [
        "close_full_transcript restore=exact",
        "transcript_transition_commit state=stable",
      ]);
      await waitForMode(session, "main", DRAFT);
      expect(await terminalOutputBytes(paths.tapePath) - beforeOrdinaryClose).toBeLessThan(256 * 1024);
      await completeHistory();
      expect(readFileSync(paths.stderrPath, "utf8")).toBe("");
      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      passed = true;
    } finally {
      await session?.kill();
      gateway.stop();
      if (passed) rmSync(paths.root, { recursive: true, force: true });
      else console.error(`retained recovery cost artifacts at ${paths.root}`);
    }
  },
  60_000,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-O repeatedly survives mixed long chats, dense tool batches, live output, resize storms, and resume",
  async () => {
    await runStress({
      label: "ci-soak",
      batches: 4,
      toolsPerBatch: 8,
      chatLinesPerBatch: 250,
      fileLines: 120,
      liveLines: 500,
      cycles: 20,
      resumeCycles: 4,
    });
  },
  240_000,
);

test.skipIf(!tmuxAvailable() || process.env.FX_CTRL_O_BRUTAL !== "1")(
  "Ctrl-O extended brutal soak holds under four thousand chat lines and ninety six tools",
  async () => {
    await runStress({
      label: "extended-soak",
      batches: 8,
      toolsPerBatch: 12,
      chatLinesPerBatch: 500,
      fileLines: 400,
      liveLines: 1_200,
      cycles: 40,
      resumeCycles: 12,
    });
  },
  600_000,
);

test.skipIf(
  !tmuxAvailable() ||
    process.env.FX_CTRL_O_PROFILE !== "1" ||
    platform() !== "darwin" ||
    !existsSync("/usr/bin/sample"),
)(
  "Ctrl-O profiler captures latency, memory, and native stacks during sustained thrashing",
  async () => {
    const paths = await runStress({
      label: "profile",
      batches: 6,
      toolsPerBatch: 10,
      chatLinesPerBatch: 350,
      fileLines: 240,
      liveLines: 1_000,
      cycles: 30,
      resumeCycles: 6,
      profileSeconds: 10,
    });
    console.error(`CTRL_O_PROFILE_METRICS=${paths.metricsPath}`);
    console.error(`CTRL_O_PROFILE_SAMPLE=${paths.profilePath}`);
  },
  600_000,
);

test.skipIf(!tmuxAvailable() || process.env.FX_CTRL_O_50K !== "1")(
  "Ctrl-O load test survives a realistic fifty-thousand-line session with large tool sidecars",
  async () => {
    const profileSeconds = process.env.FX_CTRL_O_PROFILE === "1" &&
        platform() === "darwin" &&
        existsSync("/usr/bin/sample")
      ? 30
      : undefined;
    const paths = await runStress({
      label: "real-session-50k",
      batches: 50,
      toolsPerBatch: 6,
      chatLinesPerBatch: 1_000,
      chatProfile: "realistic-compact",
      fileLines: 800,
      liveLines: 3_000,
      liveDelaySeconds: 0.001,
      historyTimeoutMs: 300_000,
      cycles: 30,
      settledCycles: 20,
      resumeCycles: 10,
      oldestPageCount: 16_384,
      minimumHistoryLines: 1_000_000,
      retainArtifacts: true,
      profileSeconds,
    });
    console.error(`CTRL_O_50K_METRICS=${paths.metricsPath}`);
    if (profileSeconds !== undefined) {
      console.error(`CTRL_O_50K_SAMPLE=${paths.profilePath}`);
    }
  },
  1_800_000,
);
