import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  hasEmptyComposer,
  startDynamicFakeGateway,
  TmuxSession,
} from "../tests/e2e/tmux-helpers";
import { readTapeFrames, type TapeFrame } from "../tests/e2e/render-lab/tape";

const SEED = "0xf17ed1ff20260805";
// Transcript scaling is covered by approval_review.zig. Keep the assembled
// real-TTY run focused on the 50k-line file review instead of measuring the
// inline transcript stream used to prepare the session.
const HISTORY_LINES = 200;
const DIFF_LINES = (() => {
  const value = Number(process.env.FX_APPROVAL_PROFILE_DIFF_LINES ?? "50000");
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`invalid FX_APPROVAL_PROFILE_DIFF_LINES: ${JSON.stringify(value)}`);
  }
  return value;
})();
const DEFAULT_CYCLES = 100;
const TIMEOUT_MS = 120_000;
const WHEEL_UP = [
  "1b", "5b", "3c", "36", "34", "3b", "31", "3b", "31", "4d",
] as const;
const WHEEL_DOWN = [
  "1b", "5b", "3c", "36", "35", "3b", "31", "3b", "31", "4d",
] as const;
const HISTORY_HEAD = "TTY_HISTORY_HEAD_SENTINEL";
const HISTORY_MIDDLE = "TTY_HISTORY_MIDDLE_SENTINEL";
const HISTORY_TAIL = "TTY_HISTORY_TAIL_SENTINEL";
const DIFF_HEAD = "TTY_DIFF_HEAD_SENTINEL";
const DIFF_MIDDLE = "TTY_DIFF_MIDDLE_SENTINEL";
const DIFF_TAIL = "TTY_DIFF_TAIL_SENTINEL";

type ContentKind = "A" | "B";
type ResourceSample = {
  rss_kib: number;
  threads: number;
  fds: number;
  children: number;
};

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function positiveInteger(raw: string | undefined, fallback: number): number {
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`expected a positive integer, got ${JSON.stringify(raw)}`);
  }
  return value;
}

function sha256(bytes: string | Buffer): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function historyLine(index: number): string {
  if (index === 0) return `${HISTORY_HEAD} user context`;
  if (index === Math.floor(HISTORY_LINES / 2)) {
    return `${HISTORY_MIDDLE} tool retry error cancellation interruption`;
  }
  if (index === HISTORY_LINES - 1) return `${HISTORY_TAIL} assistant completion`;
  switch (index % 10) {
    case 0:
      return `user-${index}: short request`;
    case 1:
      return `assistant-${index}: ${"wrapped-response ".repeat(4)}`;
    case 2:
      return `reasoning-${index}: inspect → plan → verify`;
    case 3:
      return `context-${index}: ANSI [31mred[0m malformed [`;
    case 4:
      return `approval-${index}: denied then cancelled`;
    case 5:
      return `tool-start-${index}: write_file`;
    case 6:
      return `tool-chunk-${index}: e\u0301 界 👩‍💻 \u200b`;
    case 7:
      return `tool-complete-${index}: empty output`;
    case 8:
      return "";
    default:
      return `interruption-${index}: resumed safely`;
  }
}

function makeHistory(): string {
  return Array.from({ length: HISTORY_LINES }, (_, index) => historyLine(index)).join("\n");
}

function diffLine(kind: ContentKind, index: number): string {
  const sentinel = index === 0
    ? DIFF_HEAD
    : index === Math.floor(DIFF_LINES / 2)
    ? DIFF_MIDDLE
    : index === DIFF_LINES - 1
    ? DIFF_TAIL
    : `row-${String(index).padStart(5, "0")}`;
  const glyph = index % 4 === 0 ? "ASCII" : index % 4 === 1 ? "e\u0301" : index % 4 === 2 ? "界" : "👩‍💻";
  return `${kind}-${sentinel}-${glyph}`;
}

function makeContent(kind: ContentKind): string {
  return `${Array.from({ length: DIFF_LINES }, (_, index) => diffLine(kind, index)).join("\n")}\n`;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function waitForPane(
  session: TmuxSession,
  predicate: (pane: string) => boolean,
  timeoutMs: number,
  description: string,
): Promise<string> {
  const started = performance.now();
  let pane = "";
  while (performance.now() - started < timeoutMs) {
    pane = await session.capturePane();
    if (predicate(pane)) return pane;
    await Bun.sleep(25);
  }
  pane = await session.capturePane();
  throw new Error(`Timed out waiting for ${description} after ${timeoutMs}ms.\nPane contents:\n${pane}`);
}

function frameTimestampMs(frames: TapeFrame[], index: number): number {
  let elapsed = 0;
  for (let cursor = 0; cursor <= index; cursor += 1) elapsed += frames[cursor]!.deltaMs;
  return elapsed;
}

function findFrame(
  frames: TapeFrame[],
  start: number,
  kind: number,
  needle?: string,
): number {
  for (let index = start; index < frames.length; index += 1) {
    const frame = frames[index]!;
    if (frame.kind !== kind) continue;
    if (needle === undefined || frame.payload.includes(needle)) return index;
  }
  return -1;
}

function lastFrame(frames: TapeFrame[], start: number, end: number, kind: number): number {
  for (let index = end; index >= start; index -= 1) {
    if (frames[index]!.kind === kind) return index;
  }
  return -1;
}

function tapeLatency(
  frames: TapeFrame[],
  start: number,
  triggerKind: number,
  outputNeedle?: string,
): { latency_ms: number; end: number; terminal_bytes: number; write_calls: number } {
  const firstTrigger = findFrame(frames, start, triggerKind);
  assert(firstTrigger >= 0, `missing trigger kind ${triggerKind} after ${start}`);
  const end = findFrame(frames, firstTrigger + 1, 1, outputNeedle);
  assert(end >= 0, `missing output frame ${JSON.stringify(outputNeedle)} after ${start}`);
  const trigger = lastFrame(frames, start, end, triggerKind);
  assert(trigger >= 0, `missing trigger kind ${triggerKind} before output frame ${end}`);
  let terminalBytes = 0;
  let writeCalls = 0;
  for (let index = trigger + 1; index <= end; index += 1) {
    if (frames[index]!.kind !== 1) continue;
    terminalBytes += frames[index]!.payload.length;
    writeCalls += 1;
  }
  return {
    latency_ms: frameTimestampMs(frames, end) - frameTimestampMs(frames, trigger),
    end,
    terminal_bytes: terminalBytes,
    write_calls: writeCalls,
  };
}

function qualifyTapeLatencyPairing(): void {
  const frames: TapeFrame[] = [
    { index: 1, deltaMs: 7, kind: 1, payload: Buffer.from("late hydration") },
    { index: 2, deltaMs: 11, kind: 2, payload: Buffer.from("wheel") },
    { index: 3, deltaMs: 13, kind: 1, payload: Buffer.from("updated frame") },
  ];
  const measured = tapeLatency(frames, 0, 2);
  assert(measured.end === 2, "tape latency paired output that preceded its trigger");
  assert(measured.latency_ms === 13, "tape latency used the wrong trigger boundary");

  const trailingTriggerFrames: TapeFrame[] = [
    { index: 1, deltaMs: 5, kind: 3, payload: Buffer.from("resize") },
    { index: 2, deltaMs: 7, kind: 1, payload: Buffer.from("repaint") },
    { index: 3, deltaMs: 11, kind: 3, payload: Buffer.from("late resize") },
  ];
  const trailing = tapeLatency(trailingTriggerFrames, 0, 3);
  assert(trailing.end === 1, "tape latency waited behind a completed repaint");
  assert(trailing.latency_ms === 7, "tape latency used a trailing trigger");
}

qualifyTapeLatencyPairing();

function tapeLatencyToLastOutput(
  frames: TapeFrame[],
  start: number,
  triggerKind: number,
): { latency_ms: number; end: number; terminal_bytes: number; write_calls: number } {
  const trigger = findFrame(frames, start, triggerKind);
  assert(trigger >= 0, `missing trigger kind ${triggerKind} after ${start}`);
  let end = -1;
  let terminalBytes = 0;
  let writeCalls = 0;
  for (let index = trigger + 1; index < frames.length; index += 1) {
    if (frames[index]!.kind !== 1) continue;
    end = index;
    terminalBytes += frames[index]!.payload.length;
    writeCalls += 1;
  }
  assert(end >= 0, `missing output after trigger ${trigger}`);
  return {
    latency_ms: frameTimestampMs(frames, end) - frameTimestampMs(frames, trigger),
    end,
    terminal_bytes: terminalBytes,
    write_calls: writeCalls,
  };
}

async function waitForTapeLatency(
  path: string,
  start: number,
  triggerKind: number,
  outputNeedle: string | undefined,
  timeoutMs: number,
): Promise<ReturnType<typeof tapeLatency>> {
  const started = performance.now();
  while (performance.now() - started < timeoutMs) {
    try {
      const frames = readTapeFrames(path);
      return tapeLatency(frames, start, triggerKind, outputNeedle);
    } catch {}
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for tape output ${JSON.stringify(outputNeedle)}`);
}

function resourceSample(pid: number): ResourceSample {
  const rssRaw = execFileSync("ps", ["-o", "rss=", "-p", String(pid)], { encoding: "utf8" }).trim();
  const rss = Number.parseInt(rssRaw, 10);
  const threadLines = execFileSync("ps", ["-M", String(pid)], { encoding: "utf8" })
    .trimEnd()
    .split("\n");
  const lsof = execFileSync("lsof", ["-a", "-p", String(pid), "-d", "0-999", "-Ff"], {
    encoding: "utf8",
  });
  let childOutput = "";
  try {
    childOutput = execFileSync("pgrep", ["-P", String(pid)], { encoding: "utf8" });
  } catch {}
  assert(Number.isSafeInteger(rss) && rss >= 0, `invalid RSS ${JSON.stringify(rssRaw)}`);
  return {
    rss_kib: rss,
    threads: Math.max(1, threadLines.length - 1),
    fds: lsof.split("\n").filter((line) => /^f\d/.test(line)).length,
    children: childOutput.trim().length === 0 ? 0 : childOutput.trim().split("\n").length,
  };
}

function sameResources(actual: ResourceSample, expected: ResourceSample): boolean {
  return actual.threads === expected.threads &&
    actual.fds === expected.fds &&
    actual.children === expected.children;
}

async function waitForQuiescence(
  pid: number,
  _expected: ResourceSample,
  timeoutMs: number,
): Promise<{ elapsed_ms: number; sample: ResourceSample }> {
  const started = performance.now();
  let stable = 0;
  let latest = resourceSample(pid);
  let previous: ResourceSample | null = null;
  while (performance.now() - started < timeoutMs) {
    latest = resourceSample(pid);
    if (previous !== null && sameResources(latest, previous)) {
      stable += 1;
      if (stable === 2) return { elapsed_ms: performance.now() - started, sample: latest };
    } else {
      stable = 0;
    }
    previous = latest;
    await Bun.sleep(25);
  }
  throw new Error(`resource quiescence timeout actual=${JSON.stringify(latest)}`);
}

function appendJson(path: string, value: unknown): void {
  appendFileSync(path, `${JSON.stringify(value)}\n`);
}

function plannedKinds(cycles: number): ContentKind[] {
  const kinds: ContentKind[] = [];
  let current: ContentKind = "A";
  for (let cycle = 0; cycle < cycles; cycle += 1) {
    const desired: ContentKind = current === "A" ? "B" : "A";
    kinds.push(desired);
    if (cycle % 2 === 0) current = desired;
  }
  return kinds;
}

async function waitForPaneDeath(session: TmuxSession, timeoutMs: number): Promise<number | null> {
  const started = performance.now();
  while (performance.now() - started < timeoutMs) {
    const status = session.paneStatus();
    if (status.dead) return status.status;
    await Bun.sleep(25);
  }
  throw new Error("timed out waiting for fx process exit");
}

const binary = realpathSync(requiredEnv("FX_APPROVAL_PROFILE_BIN"));
const outRoot = requiredEnv("FX_APPROVAL_PROFILE_OUT");
const cycles = positiveInteger(process.env.FX_APPROVAL_PROFILE_CYCLES, DEFAULT_CYCLES);
mkdirSync(outRoot, { recursive: true });

const home = join(outRoot, "home");
const workspace = join(outRoot, "workspace");
const tapePath = join(outRoot, "approval-review.fxtape");
const tracePath = join(outRoot, "approval-review.trace.log");
const stderrPath = join(outRoot, "approval-review.stderr.log");
const samplesPath = join(outRoot, "timings.jsonl");
const resourcesPath = join(outRoot, "resources.jsonl");
const fixturePath = join(outRoot, "fixture.json");
mkdirSync(join(home, ".fx"), { recursive: true });
mkdirSync(workspace, { recursive: true });
writeFileSync(samplesPath, "");
writeFileSync(resourcesPath, "");
writeFileSync(tracePath, "");
writeFileSync(stderrPath, "");
writeFileSync(
  join(home, ".fx", "settings.json"),
  JSON.stringify({
    sandbox: "none",
    permission_mode: "ask",
    permission: {},
    max_agent_steps: cycles * 3 + 20,
    max_tool_result_bytes: 4 * 1024 * 1024,
  }),
);

const history = makeHistory();
const contentA = makeContent("A");
const contentB = makeContent("B");
const contentByKind = { A: contentA, B: contentB } as const;
const targetPath = join(workspace, "approval-profile.txt");
writeFileSync(targetPath, contentA);
const planned = plannedKinds(cycles);
let plannedFinalKind: ContentKind = "A";
for (let cycle = 0; cycle < cycles; cycle += 1) {
  if (cycle % 2 === 0) plannedFinalKind = planned[cycle]!;
}
const cancelledDesired: ContentKind = plannedFinalKind === "A" ? "B" : "A";
planned.push(cancelledDesired, cancelledDesired);
writeFileSync(fixturePath, JSON.stringify({
  seed: SEED,
  binary,
  binary_sha256: sha256(readFileSync(binary)),
  history_logical_lines: HISTORY_LINES,
  diff_logical_lines: DIFF_LINES,
  replacement_review_rows: DIFF_LINES * 2,
  history_bytes: Buffer.byteLength(history),
  diff_a_bytes: Buffer.byteLength(contentA),
  diff_b_bytes: Buffer.byteLength(contentB),
  history_sha256: sha256(history),
  diff_a_sha256: sha256(contentA),
  diff_b_sha256: sha256(contentB),
  cycles,
  operation_count: cycles * 5 + 2,
  geometries: ["48x12", "72x18", "120x41", "180x24", "100x60"],
  timeouts_ms: TIMEOUT_MS,
}, null, 2));

let completionRequests = 0;
const gateway = startDynamicFakeGateway((body) => {
  completionRequests += 1;
  if (completionRequests === 1) return fakeGatewayFinalText(history);
  const matches = [...body.matchAll(/approval-cycle-(\d+)/g)];
  assert(matches.length > 0, `gateway request omitted cycle marker: ${body.slice(-500)}`);
  const cycle = Math.max(...matches.map((match) => Number(match[1])));
  const callId = `approval_call_${cycle}`;
  if (body.includes(callId)) return fakeGatewayFinalText(`approval-cycle-complete-${cycle}`);
  return fakeGatewayToolCall(callId, "write_file", {
    path: "approval-profile.txt",
    content: contentByKind[planned[cycle]!],
  });
});

let session: TmuxSession | null = null;
let passed = false;
try {
  session = await TmuxSession.create({
    cmd: binary,
    cwd: realpathSync(workspace),
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-approval-profile-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: "openai/gpt-5",
      FX_PERMISSION_MODE: "ask",
      FX_AUTO_UPGRADE: "0",
      FX_RECORD: tapePath,
      FX_RECORD_INPUT: "1",
      FX_SYNC_UPDATES: "1",
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: "permission,input,frame_render,terminal_diff",
      NO_COLOR: "1",
    },
    stderrPath,
    width: 120,
    height: 40,
    minimumHistoryLines: 70_000,
    remainOnExit: true,
  });
  await waitForPane(session, hasEmptyComposer, TIMEOUT_MS, "composer");
  const pid = session.panePid();
  const beforeLoad = resourceSample(pid);
  appendJson(resourcesPath, { phase: "before_load", run: -1, ...beforeLoad });

  for (let run = 0; run < 100; run += 1) {
    const started = performance.now();
    await session.capturePane();
    appendJson(samplesPath, {
      kind: "calibration",
      run,
      boundary: "tmux_capture_pane",
      wall_ms: performance.now() - started,
    });
  }

  await session.sendText("profile-preload-history");
  await waitForPane(
    session,
    (pane) => pane.includes(HISTORY_TAIL),
    TIMEOUT_MS,
    HISTORY_TAIL,
  );
  const loadedPane = await session.capturePane();
  assert(loadedPane.includes(HISTORY_TAIL), "history tail sentinel missing at terminal boundary");
  const afterLoad = resourceSample(pid);
  appendJson(resourcesPath, { phase: "after_load", run: -1, ...afterLoad });

  let currentKind: ContentKind = "A";
  const geometries = [
    { cols: 48, rows: 12 },
    { cols: 72, rows: 18 },
    { cols: 120, rows: 41 },
    { cols: 180, rows: 24 },
    { cols: 100, rows: 60 },
  ] as const;

  for (let cycle = 0; cycle < cycles; cycle += 1) {
    const expectedBefore = resourceSample(pid);
    appendJson(resourcesPath, { phase: "before_open", run: cycle, ...expectedBefore });
    const desiredKind = planned[cycle]!;
    const desiredContent = contentByKind[desiredKind];
    const frameStart = readTapeFrames(tapePath).length;
    const openStarted = performance.now();
    await session.sendText(`approval-cycle-${cycle}`);
    const approvalPane = await waitForPane(
      session,
      (pane) => pane.includes("Apply this change?") && pane.includes(DIFF_TAIL),
      TIMEOUT_MS,
      `cycle ${cycle} approval review`,
    );
    const openWallMs = performance.now() - openStarted;
    assert(approvalPane.includes("approval-profile.txt"), `cycle ${cycle} missing file identity`);
    const openFrames = readTapeFrames(tapePath);
    const firstPaint = tapeLatency(openFrames, frameStart, 2, "Permission needed");
    const ready = tapeLatency(openFrames, frameStart, 2, "Apply this change?");
    appendJson(samplesPath, {
      kind: "sample",
      run: cycle,
      path: cycle === 0 ? "cold" : "warm",
      boundary: "open_first_useful_paint",
      tape_ms: firstPaint.latency_ms,
      wall_ready_ms: openWallMs,
      terminal_bytes: firstPaint.terminal_bytes,
      write_calls: firstPaint.write_calls,
    });
    appendJson(samplesPath, {
      kind: "sample",
      run: cycle,
      path: cycle === 0 ? "cold" : "warm",
      boundary: "open_fully_interactive_ready",
      tape_ms: ready.latency_ms,
      wall_ms: openWallMs,
      terminal_bytes: ready.terminal_bytes,
      write_calls: ready.write_calls,
    });

    const navStart = readTapeFrames(tapePath).length;
    const navWallStarted = performance.now();
    const navBefore = await session.capturePane();
    const wheelBytes = Array.from({ length: cycle % 10 === 0 ? 8 : 1 }, () => WHEEL_UP).flat();
    await session.sendHexBytes(wheelBytes);
    await waitForPane(
      session,
      (pane) => pane !== navBefore,
      TIMEOUT_MS,
      `cycle ${cycle} navigation repaint`,
    );
    const navFrames = readTapeFrames(tapePath);
    const navigation = tapeLatency(navFrames, navStart, 2);
    appendJson(samplesPath, {
      kind: "sample",
      run: cycle,
      boundary: "navigation_updated_frame",
      tape_ms: navigation.latency_ms,
      wall_ms: performance.now() - navWallStarted,
      terminal_bytes: navigation.terminal_bytes,
      write_calls: navigation.write_calls,
      wheel_events: cycle % 10 === 0 ? 8 : 1,
    });

    const geometry = geometries[cycle % geometries.length]!;
    const resizeStart = readTapeFrames(tapePath).length;
    const resizeWallStarted = performance.now();
    const resizeBefore = await session.capturePane();
    await session.resizeWindow(geometry.cols, geometry.rows);
    const resizedPane = await waitForPane(
      session,
      (pane) => pane !== resizeBefore,
      TIMEOUT_MS,
      `cycle ${cycle} resize repaint`,
    );
    assert(resizedPane.length > 0, `cycle ${cycle} resize produced an empty grid`);
    const observedGeometry = session.paneSize();
    assert(
      observedGeometry.cols === geometry.cols && observedGeometry.rows === geometry.rows,
      `cycle ${cycle} resize geometry mismatch: ${JSON.stringify(observedGeometry)}`,
    );
    const repaint = await waitForTapeLatency(tapePath, resizeStart, 3, undefined, TIMEOUT_MS);
    appendJson(samplesPath, {
      kind: "sample",
      run: cycle,
      boundary: "resize_correct_repaint",
      tape_ms: repaint.latency_ms,
      wall_ms: performance.now() - resizeWallStarted,
      terminal_bytes: repaint.terminal_bytes,
      write_calls: repaint.write_calls,
      geometry: `${geometry.cols}x${geometry.rows}`,
    });

    if (geometry.cols !== 120 || geometry.rows !== 40) {
      const restoreStart = readTapeFrames(tapePath).length;
      const restoreWallStarted = performance.now();
      await session.resizeWindow(120, 40);
      const restore = await waitForTapeLatency(
        tapePath,
        restoreStart,
        3,
        undefined,
        TIMEOUT_MS,
      );
      appendJson(samplesPath, {
        kind: "sample",
        run: cycle,
        boundary: "resize_restore_controls",
        tape_ms: restore.latency_ms,
        wall_ms: performance.now() - restoreWallStarted,
        terminal_bytes: restore.terminal_bytes,
        write_calls: restore.write_calls,
        geometry: "120x40",
      });
    }

    const tailStart = readTapeFrames(tapePath).length;
    const tailWallStarted = performance.now();
    const tailBefore = await session.capturePane();
    const downBytes = Array.from({ length: cycle % 10 === 0 ? 8 : 1 }, () => WHEEL_DOWN).flat();
    await session.sendHexBytes(downBytes);
    const tailNavigation = await waitForTapeLatency(
      tapePath,
      tailStart,
      2,
      undefined,
      TIMEOUT_MS,
    );
    await waitForPane(
      session,
      (pane) => pane !== tailBefore && pane.includes("Apply this change?"),
      TIMEOUT_MS,
      `cycle ${cycle} controls repaint`,
    );
    appendJson(samplesPath, {
      kind: "sample",
      run: cycle,
      boundary: "navigation_return_to_controls",
      tape_ms: tailNavigation.latency_ms,
      wall_ms: performance.now() - tailWallStarted,
      terminal_bytes: tailNavigation.terminal_bytes,
      write_calls: tailNavigation.write_calls,
      wheel_events: cycle % 10 === 0 ? 8 : 1,
    });

    const choice = cycle % 2 === 0 ? 1 : 3;
    const decisionStart = readTapeFrames(tapePath).length;
    const decisionWallStarted = performance.now();
    await session.sendKeys(String(choice));
    await waitForPane(
      session,
      (pane) => pane.includes(`approval-cycle-complete-${cycle}`),
      TIMEOUT_MS,
      `approval-cycle-complete-${cycle}`,
    );
    await waitForPane(session, hasEmptyComposer, TIMEOUT_MS, "composer");
    const decisionWallMs = performance.now() - decisionWallStarted;
    const decisionFrames = readTapeFrames(tapePath);
    const close = tapeLatency(decisionFrames, decisionStart, 2, "\u001b[?1049l");
    const completion = tapeLatencyToLastOutput(decisionFrames, decisionStart, 2);
    appendJson(samplesPath, {
      kind: "sample",
      run: cycle,
      boundary: "decision_completion",
      choice,
      tape_ms: completion.latency_ms,
      wall_ms: decisionWallMs,
      terminal_bytes: completion.terminal_bytes,
      write_calls: completion.write_calls,
    });
    appendJson(samplesPath, {
      kind: "sample",
      run: cycle,
      boundary: "close_restore",
      choice,
      tape_ms: close.latency_ms,
      wall_ms: decisionWallMs,
      terminal_bytes: close.terminal_bytes,
      write_calls: close.write_calls,
    });

    if (choice === 1) currentKind = desiredKind;
    const targetBytes = readFileSync(targetPath);
    assert(
      sha256(targetBytes) === sha256(contentByKind[currentKind]),
      `cycle ${cycle} choice ${choice} produced the wrong file state`,
    );
    const quiescence = await waitForQuiescence(pid, expectedBefore, 2_000);
    appendJson(samplesPath, {
      kind: "sample",
      run: cycle,
      boundary: "close_resource_quiescence",
      wall_ms: quiescence.elapsed_ms,
    });
    appendJson(resourcesPath, { phase: "after_quiescence", run: cycle, ...quiescence.sample });
  }

  for (const [offset, key] of [[0, "Escape"], [1, "C-c"]] as const) {
    const cycle = cycles + offset;
    const before = resourceSample(pid);
    const desiredKind = planned[cycle]!;
    const expectedHash = sha256(readFileSync(targetPath));
    await session.sendText(`approval-cycle-${cycle}`);
    await waitForPane(
      session,
      (pane) => pane.includes("Apply this change?") && pane.includes(DIFF_TAIL),
      TIMEOUT_MS,
      `${key} approval review`,
    );
    const frameStart = readTapeFrames(tapePath).length;
    const started = performance.now();
    await session.sendKeys(key);
    await waitForPane(session, hasEmptyComposer, TIMEOUT_MS, "composer");
    const frames = readTapeFrames(tapePath);
    const close = tapeLatency(frames, frameStart, 2, "\u001b[?1049l");
    assert(sha256(readFileSync(targetPath)) === expectedHash, `${key} changed the target file`);
    const quiescence = await waitForQuiescence(pid, before, 2_000);
    appendJson(samplesPath, {
      kind: "sample",
      run: cycle,
      boundary: offset === 0 ? "cancel_close_restore" : "interrupt_close_restore",
      tape_ms: close.latency_ms,
      wall_ms: performance.now() - started,
      terminal_bytes: close.terminal_bytes,
      write_calls: close.write_calls,
      desired_kind: desiredKind,
      quiescence_ms: quiescence.elapsed_ms,
    });
  }

  const trace = readFileSync(tracePath, "utf8");
  for (let cycle = 0; cycle < cycles; cycle += 1) {
    const callId = `approval_call_${cycle}`;
    const decisions = trace.split("\n").filter((line) =>
      line.includes("event=permission_decision") && line.includes(`call_id=${callId} `)
    );
    assert(decisions.length === 1, `${callId} decision count was ${decisions.length}, expected 1`);
  }
  assert(readFileSync(stderrPath, "utf8") === "", "fx wrote to stderr");
  // Escape cancels without a tool-result request. Ctrl-C reports the
  // interrupted tool result once before returning to the composer.
  assert(gateway.requests.length === 1 + cycles * 2 + 3, `unexpected gateway request count ${gateway.requests.length}`);

  await session.sendText("/quit");
  const exitStatus = await waitForPaneDeath(session, TIMEOUT_MS);
  appendJson(resourcesPath, {
    phase: "after_exit",
    run: cycles + 2,
    rss_kib: 0,
    threads: 0,
    fds: 0,
    children: 0,
    exit_status: exitStatus,
  });
  assert(exitStatus === 0, `fx exit status was ${exitStatus}`);
  passed = true;
  console.log(JSON.stringify({
    status: "PASS",
    cycles,
    completion_requests: completionRequests,
    gateway_requests: gateway.requests.length,
    samples_path: samplesPath,
    resources_path: resourcesPath,
    tape_path: tapePath,
    trace_path: tracePath,
    fixture_path: fixturePath,
  }));
} finally {
  if (session) await session.kill();
  gateway.stop();
  if (!passed) console.error(`retained failed approval-review TTY artifacts at ${outRoot}`);
}
