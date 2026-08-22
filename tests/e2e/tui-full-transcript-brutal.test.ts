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
  fakeGatewaySse,
  fakeGatewayToolCall,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const INPUT_SANITY_BUDGET_MS = 5_000;
const BURST_NAVIGATION_EVENTS = 2_048;
const REVIEW_FOOTER = "Review · ←/→ switch · ctrl o close";
const FULL_FOOTER = "Full detail · ←/→ switch · ctrl o close";
const HISTORY_DONE = "CTRL_O_BRUTAL_HISTORY_DONE";
const LIVE_START = "CTRL_O_BRUTAL_LIVE_0001";
const LIVE_DONE = "CTRL_O_BRUTAL_LIVE_DONE";
const DRAFT = "CTRL_O_BRUTAL_UNSENT_DRAFT";
const RESUME_DRAFT = "CTRL_O_BRUTAL_RESUME_DRAFT";
const TAIL_SENTINEL = "CTRL_O_TAIL_SENTINEL";
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

type TransitionKind = "review" | "full" | "scroll" | "close" | "resize";

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
        kind?: string;
        payload?: { turn?: { assistant?: string } };
      };
      if (
        event.kind === "history_turn_committed" &&
        event.payload?.turn?.assistant === assistant
      ) {
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
    p95Ms: Number(percentile(values, 0.95).toFixed(3)),
    p99Ms: Number(percentile(values, 0.99).toFixed(3)),
    maxMs: Number(Math.max(0, ...values).toFixed(3)),
  };
}

function summarizeBytes(values: number[]) {
  return {
    count: values.length,
    p50Bytes: percentile(values, 0.5),
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
  responses.push(fakeGatewayToolCall("ctrl-o-brutal-live", "terminal", {
    action: "exec",
    command: "./ctrl-o-live.sh",
  }));
  responses.push(fakeGatewayFinalText(LIVE_DONE));

  return { paths, gateway: startFakeGateway(responses), totalTools };
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
  mode: "review" | "full" | "main",
  draft: string,
): Promise<string> {
  return session.waitForPane((pane) => {
    if (mode === "review") return pane.includes(REVIEW_FOOTER);
    if (mode === "full") return pane.includes(FULL_FOOTER);
    return composerContains(pane, draft) &&
      !pane.includes(REVIEW_FOOTER) &&
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
      const windows = projectionWindows(appended.slice(scrollIndex));
      if (windows.some((window) => window.offset !== previousOffset)) return;
    }
    await sleep(10);
  }
  throw new Error(
    `Timed out waiting for a rendered Ctrl-O scroll from offset ${previousOffset}.\n` +
    `Trace appended after action:\n${appended}`,
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
  const bytesBefore = tapePath === undefined ? undefined : statSync(tapePath).size;
  const started = performance.now();
  await action();
  await visible();
  metrics.transitions[kind].push(performance.now() - started);
  if (bytesBefore !== undefined) {
    metrics.terminalBytes[kind].push(statSync(tapePath!).size - bytesBefore);
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
  throw new Error(`Unable to find Fx on ${tty}. Processes:\n${rows.join("\n")}`);
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

test("Fx process discovery accepts basename and path process names", () => {
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
      "review",
      () => session.sendHexBytes(CTRL_O),
      () => waitForMode(session, "review", draft),
      tapePath,
    );

    const reviewScrollWindow = latestProjectionWindow(tracePath);
    const reviewScrollTraceStart = traceSize(tracePath);
    await timeTransition(
      metrics,
      "scroll",
      () => session.sendHexBytes(cycle % 2 === 0 ? PAGE_UP : WHEEL_UP),
      async () => {
        await waitForMode(session, "review", draft);
        await waitForScrolledViewport(
          tracePath,
          reviewScrollTraceStart,
          reviewScrollWindow.offset,
        );
      },
      tapePath,
    );

    await timeTransition(
      metrics,
      "full",
      () => session.sendKeys("Right"),
      () => waitForMode(session, "full", draft),
      tapePath,
    );

    if (cycle % 4 === 0) {
      const fullUpWindow = latestProjectionWindow(tracePath);
      const fullUpTraceStart = traceSize(tracePath);
      await timeTransition(
        metrics,
        "scroll",
        () => session.sendHexBytes(PAGE_UP),
        async () => {
          await waitForMode(session, "full", draft);
          await waitForScrolledViewport(
            tracePath,
            fullUpTraceStart,
            fullUpWindow.offset,
          );
        },
        tapePath,
      );
      const fullDownWindow = latestProjectionWindow(tracePath);
      const fullDownTraceStart = traceSize(tracePath);
      await timeTransition(
        metrics,
        "scroll",
        () => session.sendHexBytes(PAGE_DOWN),
        async () => {
          await waitForMode(session, "full", draft);
          await waitForScrolledViewport(
            tracePath,
            fullDownTraceStart,
            fullDownWindow.offset,
          );
        },
        tapePath,
      );
    } else {
      const fullScrollWindow = latestProjectionWindow(tracePath);
      const fullScrollTraceStart = traceSize(tracePath);
      await timeTransition(
        metrics,
        "scroll",
        () => session.sendHexBytes(cycle % 2 === 0 ? PAGE_UP : WHEEL_UP),
        async () => {
          await waitForMode(session, "full", draft);
          await waitForScrolledViewport(
            tracePath,
            fullScrollTraceStart,
            fullScrollWindow.offset,
          );
        },
        tapePath,
      );
    }

    const sizes = [
      [48, 18],
      [132, 42],
      [80, 24],
      [104, 30],
    ] as const;
    const [cols, rows] = sizes[cycle % sizes.length]!;
    const resizeTraceStart = traceSize(tracePath);
    await timeTransition(
      metrics,
      "resize",
      () => session.resizeWindow(cols, rows),
      async () => {
        await waitForMode(session, "full", draft);
        await waitForResizedViewport(tracePath, resizeTraceStart, cols);
      },
      tapePath,
    );

    const closeKey = cycle % 3 === 0 ? "C-o" : cycle % 3 === 1 ? "Escape" : "C-c";
    await timeTransition(
      metrics,
      "close",
      () => closeKey === "C-o" ? session.sendHexBytes(CTRL_O) : session.sendKeys(closeKey),
      () => waitForMode(session, "main", draft),
      tapePath,
    );
    expect(session.paneStatus().dead).toBe(false);
    rssKib.push(residentKib(pid));
  }
}

async function verifyTailSurvivesReviewToFull(
  session: TmuxSession,
): Promise<void> {
  await session.sendHexBytes(CTRL_O);
  const review = await waitForMode(session, "review", "");
  expect(review).toContain(TAIL_SENTINEL);

  await session.sendKeys("Right");
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
  const newest = await waitForMode(session, "review", draft);
  expect(newest).toContain(LIVE_DONE);
  const pageCount = config.oldestPageCount ?? 512;
  const pageChunk = 64;
  for (let sent = 0; sent < pageCount; sent += pageChunk) {
    await sendRepeatedKey(
      session,
      "PPage",
      Math.min(pageChunk, pageCount - sent),
      pageChunk,
      300,
    );
    const pane = await waitForMode(session, "review", draft);
    if (pane.includes(firstChatMarker(config))) break;
  }
  const oldestMarker = firstChatMarker(config);
  const oldest = await session.waitForText(oldestMarker, TIMEOUT * 4);
  expect(oldest).toContain(oldestMarker);

  await session.sendKeys("Right");
  const full = await waitForMode(session, "full", draft);
  expect(full).toContain(oldestMarker);

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
  const newest = await waitForMode(session, "review", draft);
  expect(newest).toContain(LIVE_DONE);

  // Resume reconstructs the compact transcript under the product's 256 KiB
  // retention cap, so the original first line is not expected to survive.
  await sendRepeatedKey(session, "PPage", 64, 64, 500);
  const older = await session.waitForPane(
    (pane) =>
      olderRetainedChatMarker(pane, config) !== undefined ||
      [...pane.matchAll(/CTRL_O_BRUTAL_TOOL_(\d{4})/g)]
        .some((match) => Number(match[1]) < totalTools - 1),
    TIMEOUT * 4,
  );
  expect(older).toContain(REVIEW_FOOTER);
  const retainedChat = olderRetainedChatMarker(older, config);
  const retainedTool = [...older.matchAll(/CTRL_O_BRUTAL_TOOL_(\d{4})/g)]
    .map((match) => Number(match[1]))
    .find((index) => index < totalTools - 1);
  expect(retainedChat ?? retainedTool).toBeDefined();
  const retainedMarker = retainedChat ?? compactToolMarker(retainedTool!);

  await session.sendKeys("Right");
  const full = await waitForMode(session, "full", draft);
  expect(full).toContain(retainedMarker);

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
    transitions: { review: [], full: [], scroll: [], close: [], resize: [] },
    terminalBytes: { review: [], full: [], scroll: [], close: [], resize: [] },
  };
  const settledMetrics: StressMetrics = {
    transitions: { review: [], full: [], scroll: [], close: [], resize: [] },
    terminalBytes: { review: [], full: [], scroll: [], close: [], resize: [] },
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
          "full_transcript_cache,full_transcript,scroll,frame_render,terminal_diff,frame_schedule",
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

    await verifyTailSurvivesReviewToFull(session);
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
    session.sendKeysImmediate(["C-o", "Escape"]);
    await waitForTraceAfter(paths.tracePath, immediateTraceStart, [
      "attempt_restore outcome=input_pending",
      "depth_transition from=review to=inline route=root trigger=escape",
    ]);
    await waitForMode(session, "main", DRAFT);
    expect(performance.now() - escapeStarted).toBeLessThan(INPUT_SANITY_BUDGET_MS);

    const repeatedToggleTraceStart = traceSize(paths.tracePath);
    const repeatedToggleStarted = performance.now();
    session.sendKeysImmediate(["C-o", "Right"]);
    await waitForTraceAfter(paths.tracePath, repeatedToggleTraceStart, [
      "depth_transition from=review to=full route=root trigger=right",
    ]);
    await waitForMode(session, "full", DRAFT);
    expect(performance.now() - repeatedToggleStarted).toBeLessThan(
      INPUT_SANITY_BUDGET_MS,
    );
    await session.sendKeys("Escape");
    await waitForMode(session, "main", DRAFT);

    await session.sendKeys("C-o");
    await waitForMode(session, "review", DRAFT);
    const burstToggleTraceStart = traceSize(paths.tracePath);
    const burstToggleStarted = performance.now();
    session.sendRepeatedKeyThenImmediate(
      "PPage",
      BURST_NAVIGATION_EVENTS,
      "Right",
    );
    await waitForTraceAfter(paths.tracePath, burstToggleTraceStart, [
      "depth_transition from=review to=full route=root trigger=right",
    ]);
    await waitForMode(session, "full", DRAFT);
    expect(performance.now() - burstToggleStarted).toBeLessThan(
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
    const writeMetrics = () => {
      const summary = {
        config,
        transitions: {
          review: summarize(metrics.transitions.review),
          full: summarize(metrics.transitions.full),
          scroll: summarize(metrics.transitions.scroll),
          close: summarize(metrics.transitions.close),
          resize: summarize(metrics.transitions.resize),
        },
        settledTransitions: {
          review: summarize(settledMetrics.transitions.review),
          full: summarize(settledMetrics.transitions.full),
          scroll: summarize(settledMetrics.transitions.scroll),
          close: summarize(settledMetrics.transitions.close),
          resize: summarize(settledMetrics.transitions.resize),
        },
        terminalBytes: {
          review: summarizeBytes(metrics.terminalBytes.review),
          full: summarizeBytes(metrics.terminalBytes.full),
          scroll: summarizeBytes(metrics.terminalBytes.scroll),
          close: summarizeBytes(metrics.terminalBytes.close),
          resize: summarizeBytes(metrics.terminalBytes.resize),
        },
        settledTerminalBytes: {
          review: summarizeBytes(settledMetrics.terminalBytes.review),
          full: summarizeBytes(settledMetrics.terminalBytes.full),
          scroll: summarizeBytes(settledMetrics.terminalBytes.scroll),
          close: summarizeBytes(settledMetrics.terminalBytes.close),
          resize: summarizeBytes(settledMetrics.terminalBytes.resize),
        },
        memory: summarizeMemory(primaryRssKib),
        resumedMemory: resumedRssKib.length > 0
          ? summarizeMemory(resumedRssKib)
          : null,
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
    expect(summary.transitions.review.p95Ms).toBeLessThan(5_000);
    expect(summary.transitions.full.p95Ms).toBeLessThan(5_000);
    expect(summary.transitions.close.p95Ms).toBeLessThan(5_000);
    expect(summary.transitions.resize.p95Ms).toBeLessThan(5_000);
    const budgetTransitions = (config.settledCycles ?? 0) > 0
      ? summary.settledTransitions
      : summary.transitions;
    // The budget includes terminal backpressure and host jitter.
    expect(budgetTransitions.review.p95Ms).toBeLessThan(3_500);
    expect(budgetTransitions.full.p95Ms).toBeLessThan(3_000);
    expect(budgetTransitions.close.p95Ms).toBeLessThan(1_500);
    expect(budgetTransitions.resize.p95Ms).toBeLessThan(3_000);
    if ((config.settledCycles ?? 0) > 0) {
      // A resized close may emit the repair frame and next Review viewport only.
      expect(summary.settledTerminalBytes.review.maxBytes).toBeLessThan(64 * 1024);
    }
    // Review-open cost must remain independent of total chat size.
    expect(summary.terminalBytes.review.maxBytes).toBeLessThan(128 * 1024);
    expect(summary.terminalBytes.close.maxBytes).toBeLessThan(256 * 1024);
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
            "full_transcript_cache,full_transcript,scroll,frame_render,terminal_diff",
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
          "depth_transition from=inline to=review route=root trigger=ctrl_o",
        ],
      );
      expect(resumeInputTrace).not.toContain(
        "transcript_transition_commit state=stable",
      );
      await waitForMode(session, "review", RESUME_DRAFT);
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
  "Ctrl-O repeatedly survives mixed long chats, dense tool batches, live output, resize storms, and resume",
  async () => {
    await runStress({
      label: "ci-soak",
      batches: 4,
      toolsPerBatch: 8,
      chatLinesPerBatch: 250,
      fileLines: 120,
      liveLines: 500,
      cycles: 12,
      resumeCycles: 4,
    });
  },
  180_000,
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
