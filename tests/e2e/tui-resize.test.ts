/**
 * Resize cases deliver SIGWINCH through tmux and locate the inline footer by
 * structure, not by absolute terminal row.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync, execSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewaySse,
  fakeGatewayToolCall,
  hasEmptyComposer,
  paneExitMatches,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
  tmuxRawPasteFlags,
} from "./tmux-helpers";
import {
  findActiveFileApprovalBlock,
  findFooterBlocks,
  isDividerRow,
  isInputRow,
  type FooterBlock,
} from "./tui-render-assertions";
import { readTapeFrames, stdoutFrames } from "./render-lab/tape";

const SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;
const TEST_TEARDOWN_HEADROOM_MS = 1_000;
const SELECTED_COMPLETION_SGR = "\x1b[1m\x1b[38;5;255m";
const FILE_APPROVAL_QUESTION = "Apply this change?";
const LARGE_SKILL_COUNT = 85;
const LARGE_SKILL_TIMEOUT = 180_000;
const RAPID_SKILL_COUNT = 4;
const RAPID_SKILL_TIMEOUT = 600_000;
const MINIMUM_RESIZE_HISTORY_LINES = 2_000;
const KEEP_LARGE_SKILL_ARTIFACTS =
  process.env.FX_TUI_RESIZE_KEEP_ARTIFACTS === "1";

let session: TmuxSession | null = null;
const tempDirs: string[] = [];
const gateways: Array<{ stop(): void }> = [];

type TmuxCreateOptions = NonNullable<Parameters<typeof TmuxSession.create>[0]>;

async function createResizeSession(
  opts: TmuxCreateOptions = {},
): Promise<TmuxSession> {
  const env = { ...opts.env };
  let home = env.HOME;
  if (!home) {
    const root = mkdtempSync(join(tmpdir(), "fx-resize-home-"));
    tempDirs.push(root);
    home = join(root, "home");
    env.HOME = home;
  }

  const settingsPath = join(home, ".fx", "settings.json");
  mkdirSync(join(home, ".fx"), { recursive: true });
  const settings = existsSync(settingsPath)
    ? JSON.parse(readFileSync(settingsPath, "utf8")) as Record<string, unknown>
    : {};
  writeFileSync(settingsPath, JSON.stringify(settings));

  return TmuxSession.create({ ...opts, env });
}

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

async function launchAt(
  cols: number,
  rows: number,
  opts?: { stderrPath?: string },
): Promise<TmuxSession> {
  const s = await createResizeSession({ width: cols, height: rows, ...opts });
  await s.waitForComposer(10_000);
  return s;
}

function createStderrPath(label: string): string {
  const dir = mkdtempSync(join(tmpdir(), `fx-resize-${label}-`));
  tempDirs.push(dir);
  return join(dir, "stderr.txt");
}

async function launchRecordedSurfaceSession(
  label: string,
  width: number,
  height: number,
  extraEnv: Record<string, string | undefined> = {},
): Promise<{
  active: TmuxSession;
  stderrPath: string;
}> {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), `fx-footer-surface-${label}-`)),
  );
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(workspace, "AGENTS.md"), "# Test workspace\n");
  writeFileSync(stderrPath, "");
  tempDirs.push(root);

  const active = await createResizeSession({
    cmd: FX_BIN,
    cwd: workspace,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_RECORD: join(root, "session.fxtape"),
      FX_RECORD_INPUT: "1",
      NO_COLOR: "1",
      ...extraEnv,
    },
    width,
    height,
    stderrPath,
  });
  await active.waitForComposer(10_000);
  return { active, stderrPath };
}

function expectEmptyStderr(path: string): void {
  expect(readFileSync(path, "utf8")).toBe("");
}

function countOccurrences(value: string, needle: string): number {
  let count = 0;
  let offset = 0;
  while (true) {
    const next = value.indexOf(needle, offset);
    if (next < 0) return count;
    count += 1;
    offset = next + needle.length;
  }
}

function textHex(value: string): string[] {
  return Array.from(
    Buffer.from(value),
    (byte) => byte.toString(16).padStart(2, "0"),
  );
}

function gatedResizeResponse(
  first: string,
  second: string,
  final: string,
): {
  response: () => Response;
  releaseSecond(): void;
  releaseFinal(): void;
} {
  const encoder = new TextEncoder();
  let releaseSecond!: () => void;
  let releaseFinal!: () => void;
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  const secondGate = new Promise<void>((resolve) => {
    releaseSecond = resolve;
  });
  const finalGate = new Promise<void>((resolve) => {
    releaseFinal = resolve;
  });
  const event = (delta: string) =>
    encoder.encode(
      `data: ${JSON.stringify({
        type: "text-delta",
        id: "resize-stream",
        delta,
      })}\n\n`,
    );
  const sendJson = (controller: ReadableStreamDefaultController<Uint8Array>, value: object) => {
    controller.enqueue(encoder.encode(`data: ${JSON.stringify(value)}\n\n`));
  };

  return {
    response: () =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            sendJson(controller, { type: "text-start", id: "resize-stream" });
            controller.enqueue(event(first));
            timer = setInterval(() => {
              if (!closed) controller.enqueue(encoder.encode(": gated-resize-hold\n\n"));
            }, 50);
            void secondGate.then(() => {
              controller.enqueue(event(second));
              return finalGate;
            }).then(() => {
              closed = true;
              if (timer) clearInterval(timer);
              controller.enqueue(event(final));
              sendJson(controller, { type: "text-end", id: "resize-stream" });
              controller.enqueue(
                encoder.encode(
                  `data: ${JSON.stringify({
                    type: "finish",
                    finishReason: { unified: "stop", raw: "stop" },
                    usage: {
                      inputTokens: { total: 1 },
                      outputTokens: { total: 3 },
                    },
                  })}\n\ndata: [DONE]\n\n`,
                ),
              );
              controller.close();
            });
          },
          cancel() {
            closed = true;
            if (timer) clearInterval(timer);
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      ),
    releaseSecond,
    releaseFinal,
  };
}

function semanticMarkerRows(
  scrollback: string,
  markers: readonly string[],
): number[] {
  return markers.map((marker) => {
    const rows = scrollback
      .split("\n")
      .flatMap((line, row) => line.includes(marker) ? [row] : []);
    expect(rows).toHaveLength(1);
    return rows[0]!;
  });
}

function expectOrderedMarkersWithoutBlankHole(
  scrollback: string,
  markers: readonly string[],
): void {
  const lines = scrollback.split("\n");
  const rows = semanticMarkerRows(scrollback, markers);
  for (let index = 1; index < rows.length; index++) {
    expect(rows[index]).toBeGreaterThan(rows[index - 1]!);
    for (let row = rows[index - 1]! + 1; row < rows[index]!; row++) {
      expect(lines[row]!.trim().length).toBeGreaterThan(0);
    }
  }
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
    if (line.includes(SELECTED_COMPLETION_SGR)) {
      return line;
    }
  }
  return null;
}

test("selected slash row ignores the welcome header help hint", () => {
  const header = `${SELECTED_COMPLETION_SGR}𝒇x\x1b[0m\x1b[38;5;245m v0.3.27 · Run /help for commands`;
  const command = `${SELECTED_COMPLETION_SGR}  /clear\x1b[38;5;245m start a fresh session and keep background processes`;

  expect(selectedSlashRow(`${header}\n${command}`)).toBe(command);
});

async function waitForSelectedSlashLabel(
  active: TmuxSession,
  label: string,
  timeoutMs = 10_000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last: string | null = null;
  while (Date.now() < deadline) {
    last = selectedSlashRow(await active.capturePaneEscapes());
    if (last?.includes(label)) return last;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(
    `Timed out waiting for selected slash label ${label}; last=${last}`,
  );
}

function readTraceLines(path: string): string[] {
  return existsSync(path) ? readFileSync(path, "utf8").split("\n") : [];
}

type TraceAttempt = {
  beginIndex: number;
  endIndex: number;
  beginLine: string;
  lines: Array<{ index: number; text: string }>;
};

type ResizeCycle = {
  applyIndex: number;
  applyLine: string;
  cursorIndex: number;
  cursorLine: string;
  oldSize: { cols: number; rows: number };
  newSize: { cols: number; rows: number };
  historyRowDelta: number;
  attempt: TraceAttempt;
};

function committedTraceAttempts(path: string): TraceAttempt[] {
  const attempts: TraceAttempt[] = [];
  let current:
    | {
      beginIndex: number;
      beginLine: string;
      lines: Array<{ index: number; text: string }>;
    }
    | null = null;

  for (const [index, text] of readTraceLines(path).entries()) {
    if (text.includes("[frame_schedule] attempt_begin ")) {
      current = {
        beginIndex: index,
        beginLine: text,
        lines: [{ index, text }],
      };
      continue;
    }
    if (!current) continue;
    current.lines.push({ index, text });
    if (text.includes("[frame_schedule] attempt_end outcome=committed")) {
      attempts.push({
        ...current,
        endIndex: index,
      });
      current = null;
    } else if (text.includes("[frame_schedule] attempt_restore ")) {
      current = null;
    }
  }
  return attempts;
}

function terminalSizeTraceField(
  line: string,
  field: string,
): { cols: number; rows: number } {
  const match = line.match(new RegExp(`(?:^|\\s)${field}=(\\d+)x(\\d+)`));
  if (!match?.[1] || !match[2]) {
    throw new Error(`Missing terminal size trace field ${field}: ${line}`);
  }
  return {
    cols: Number.parseInt(match[1], 10),
    rows: Number.parseInt(match[2], 10),
  };
}

function signedTraceField(line: string, field: string): number {
  const match = line.match(new RegExp(`(?:^|\\s)${field}=(-?\\d+)`));
  if (!match?.[1]) {
    throw new Error(`Missing signed trace field ${field}: ${line}`);
  }
  return Number.parseInt(match[1], 10);
}

function committedResizeCycles(path: string): ResizeCycle[] {
  const lines = readTraceLines(path);
  const attempts = committedTraceAttempts(path);
  const cycles: ResizeCycle[] = [];
  let lastApplyIndex = -1;
  for (const attempt of attempts) {
    if (!attemptHasReason(attempt, "resize")) continue;
    let applyIndex = -1;
    for (let index = attempt.beginIndex - 1; index > lastApplyIndex; index--) {
      if (lines[index]?.includes("[resize] apply ")) {
        applyIndex = index;
        break;
      }
    }
    if (applyIndex < 0) continue;
    let cursorIndex = -1;
    for (let index = applyIndex + 1; index < attempt.beginIndex; index++) {
      if (lines[index]?.includes("[resize] cursor_measure ")) {
        cursorIndex = index;
        break;
      }
    }
    for (let index = applyIndex - 1; cursorIndex < 0 && index > lastApplyIndex; index--) {
      if (lines[index]?.includes("[resize] cursor_measure ")) {
        cursorIndex = index;
        break;
      }
    }
    if (cursorIndex < 0) continue;
    const applyLine = lines[applyIndex]!;
    const cursorLine = lines[cursorIndex]!;
    if (!cursorLine.includes("valid=true")) continue;
    let committedAttempt = attempt;
    if (applyLine.includes("settled=false")) {
      const settledApplyIndex = lines.findIndex(
        (line, index) =>
          index > attempt.endIndex &&
          line.includes("[resize] apply ") &&
          line.includes("settled=true"),
      );
      const settledAttempt = attempts.find(
        (candidate) =>
          settledApplyIndex >= 0 &&
          candidate.beginIndex > settledApplyIndex &&
          attemptHasReason(candidate, "resize"),
      );
      if (!settledAttempt) continue;
      committedAttempt = settledAttempt;
    }
    cycles.push({
      applyIndex,
      applyLine,
      cursorIndex,
      cursorLine,
      oldSize: terminalSizeTraceField(applyLine, "old"),
      newSize: terminalSizeTraceField(applyLine, "new"),
      historyRowDelta: signedTraceField(cursorLine, "history_row_delta"),
      attempt: committedAttempt,
    });
    lastApplyIndex = applyIndex;
  }
  return cycles;
}

async function waitForResizeCycle(
  tracePath: string,
  afterLine: number,
  predicate: (cycle: ResizeCycle) => boolean,
  timeoutMs = 45_000,
): Promise<ResizeCycle> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const cycle = committedResizeCycles(tracePath).find(
      (candidate) => candidate.applyIndex > afterLine && predicate(candidate),
    );
    if (cycle) return cycle;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(
    `Timed out waiting for resize cycle after line ${afterLine}.\nTrace:\n${
      existsSync(tracePath) ? readFileSync(tracePath, "utf8") : ""
    }`,
  );
}

async function waitForResizeCycles(
  tracePath: string,
  afterLine: number,
  timeoutMs = 45_000,
): Promise<ResizeCycle[]> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const cycles = committedResizeCycles(tracePath).filter(
      (cycle) => cycle.applyIndex > afterLine,
    );
    const shrink = cycles.find((cycle) =>
      cycle.oldSize.cols === 120 &&
      cycle.oldSize.rows === 34 &&
      cycle.newSize.cols === 70 &&
      cycle.newSize.rows === 24
    );
    const grow = cycles.find((cycle) =>
      cycle.oldSize.cols === 70 &&
      cycle.oldSize.rows === 24 &&
      cycle.newSize.cols === 120 &&
      cycle.newSize.rows === 34
    );
    if (shrink && grow) return [shrink, grow];
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(
    `Timed out waiting for shrink/grow resize cycles after line ${afterLine}.\nTrace:\n${
      existsSync(tracePath) ? readFileSync(tracePath, "utf8") : ""
    }`,
  );
}

function attemptLine(attempt: TraceAttempt, needle: string): string | undefined {
  return attempt.lines.find(({ text }) => text.includes(needle))?.text;
}

function attemptHasReason(attempt: TraceAttempt, reason: string): boolean {
  const match = attempt.beginLine.match(/(?:^|\s)reasons=([^\s]+)/);
  return match?.[1]?.split(",").includes(reason) === true;
}

async function waitForCommittedTraceAttempt(
  tracePath: string,
  afterLine: number,
  predicate: (attempt: TraceAttempt) => boolean,
  timeoutMs = 45_000,
): Promise<TraceAttempt> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = committedTraceAttempts(tracePath).find((attempt) =>
      attempt.beginIndex > afterLine && predicate(attempt)
    );
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(
    `Timed out waiting for committed trace attempt after line ${afterLine}.\nTrace:\n${
      existsSync(tracePath) ? readFileSync(tracePath, "utf8") : ""
    }`,
  );
}

function numericTraceField(line: string, field: string): number {
  const match = line.match(new RegExp(`(?:^|\\s)${field}=(\\d+)`));
  if (!match?.[1]) {
    throw new Error(`Missing numeric trace field ${field}: ${line}`);
  }
  return Number.parseInt(match[1], 10);
}

function cursorTraceField(
  line: string,
  field: string,
): { row: number; col: number } {
  const match = line.match(new RegExp(`(?:^|\\s)${field}=(\\d+),(\\d+)`));
  if (!match?.[1] || !match[2]) {
    throw new Error(`Missing cursor trace field ${field}: ${line}`);
  }
  return {
    row: Number.parseInt(match[1], 10),
    col: Number.parseInt(match[2], 10),
  };
}

async function waitForLiveScrollbackText(
  s: TmuxSession,
  needle: string,
  timeoutMs = 30_000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last = "";
  while (Date.now() < deadline) {
    const status = s.paneStatus();
    if (status.dead) {
      throw new Error(
        `Fx exited with status ${status.status} while waiting for ${JSON.stringify(needle)}.\nScrollback:\n${last}`,
      );
    }
    last = await s.captureFullScrollback();
    if (last.includes(needle)) return last;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    `Timed out waiting for ${JSON.stringify(needle)}.\nScrollback:\n${last}`,
  );
}

async function waitForScrollbackWithoutText(
  s: TmuxSession,
  needle: string,
  timeoutMs = 10_000,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last = "";
  while (Date.now() < deadline) {
    last = await s.captureFullScrollback();
    if (!last.includes(needle)) return last;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    `Timed out waiting for scrollback to clear ${JSON.stringify(needle)}.\nScrollback:\n${last}`,
  );
}

async function waitForSettledFooter(
  s: TmuxSession,
  timeoutMs = 10_000,
): Promise<string[]> {
  const deadline = Date.now() + timeoutMs;
  let last: string[] = [];
  while (Date.now() < deadline) {
    last = await s.capturePaneGrid();
    if (findFooter(last) !== null) {
      return last;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for settled footer.\n${last.join("\n")}`);
}

async function waitForSkillsMenuGrid(
  s: TmuxSession,
  count: number,
  timeoutMs = 30_000,
): Promise<string[]> {
  const deadline = Date.now() + timeoutMs;
  let last: string[] = [];
  while (Date.now() < deadline) {
    last = await s.capturePaneGrid();
    const text = last.join("\n");
    if (text.includes(`Skills ${count}`) && findSkillsScreen(last) !== null) {
      return last;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    `Timed out waiting for skills menu with ${count} entries.\n${last.join("\n")}`,
  );
}

function expectSkillsMenuGrid(
  grid: string[],
  count: number,
  names: string[],
): void {
  const text = grid.join("\n");
  expect(text).toContain(`Skills ${count}`);
  expect(text).toContain("[All]");
  expect(text).toContain("Fx");
  expect(text).toContain("Workspace");
  expect(text).toContain("Codex");
  expect(text).toContain("Fx · Global");
  expect(names.some((name) => text.includes(name))).toBe(true);
  expect(text).not.toContain("Visible skills (");
  expect(text).not.toContain("Run /help for commands");
  expect(findSkillsScreen(grid)).not.toBeNull();
  expect(grid.filter(isInputRow)).toHaveLength(1);
}

function expectNoTranscriptSkillInventory(scrollback: string): void {
  expect(scrollback).not.toContain("Visible skills (");
}

function globalTmuxOptions(): { server: string; window: string } {
  return {
    server: execFileSync("tmux", ["show-options", "-g"], {
      encoding: "utf8",
      stdio: "pipe",
    }),
    window: execFileSync("tmux", ["show-options", "-gw"], {
      encoding: "utf8",
      stdio: "pipe",
    }),
  };
}

function matchingTestSessions(): string[] {
  const prefix = `fx-test-${process.pid}-`;
  try {
    return execFileSync(
      "tmux",
      ["list-sessions", "-F", "#{session_name}"],
      { encoding: "utf8", stdio: "pipe" },
    )
      .split("\n")
      .filter((name) => name.startsWith(prefix))
      .sort();
  } catch {
    return [];
  }
}

function quoteShellPath(path: string): string {
  return `'${path.replaceAll("'", "'\\''")}'`;
}

type LargeSkillFixture = {
  root: string;
  home: string;
  workspace: string;
  names: string[];
};

function createSkillFixture(
  attempt: number,
  count: number,
  rootLabel: string,
  descriptionPaddingRows = 0,
): LargeSkillFixture {
  const root = realpathSync(
    mkdtempSync(join(tmpdir(), `fx-resize-${rootLabel}-${attempt}-`)),
  );
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const skillsRoot = join(home, ".fx", "skills");
  mkdirSync(skillsRoot, { recursive: true });
  mkdirSync(workspace, { recursive: true });
  if (!KEEP_LARGE_SKILL_ARTIFACTS) tempDirs.push(root);

  const fixtures = Array.from({ length: count }, (_, index) => {
    const suffix = String(index).padStart(3, "0");
    const attemptSuffix = String(attempt).padStart(3, "0");
    const attemptName = `head-a${attemptSuffix}`;
    const name = `gauntlet-${attemptName}-skill-${suffix}`;
    const marker = `fx-gauntlet-${attemptName}-${suffix}`;
    const padding = Array.from(
      { length: descriptionPaddingRows },
      (_, row) => String.fromCharCode("a".charCodeAt(0) + row).repeat(120),
    ).join("");
    const description =
      `${marker} deterministic transcript resize fixture with stable ASCII ` +
      "content alpha 0123456789 beta 0123456789 gamma 0123456789 " +
      "delta 0123456789 epsilon 0123456789 zeta 0123456789" +
      padding;
    return { name, marker, description };
  });
  const creationOrder = attempt % 2 === 0
    ? [...fixtures].reverse()
    : fixtures;
  for (const fixture of creationOrder) {
    const dir = join(skillsRoot, fixture.name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "SKILL.md"),
      [
        "---",
        `name: ${fixture.name}`,
        `description: ${fixture.description}`,
        "---",
        "",
        `# ${fixture.name}`,
        "",
        "Deterministic resize coverage fixture.",
        "",
      ].join("\n"),
    );
  }

  return {
    root,
    home: realpathSync(home),
    workspace: realpathSync(workspace),
    names: fixtures.map(({ name }) => name),
  };
}

function createLargeSkillFixture(attempt: number): LargeSkillFixture {
  return createSkillFixture(attempt, LARGE_SKILL_COUNT, "large-skills");
}

async function waitForTraceText(
  tracePath: string,
  text: string,
  timeoutMs = 30_000,
  pollIntervalMs = 50,
): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
    if (trace.includes(text)) return trace;
    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }
  throw new Error(
    `Timed out waiting for ${JSON.stringify(text)}.\nTrace:\n${
      existsSync(tracePath) ? readFileSync(tracePath, "utf8") : ""
    }`,
  );
}

async function waitForTraceCount(
  tracePath: string,
  text: string,
  minimumCount: number,
  timeoutMs = 30_000,
): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
    if (countOccurrences(trace, text) >= minimumCount) return trace;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(
    `Timed out waiting for ${minimumCount} copies of ${JSON.stringify(text)}.\nTrace:\n${
      existsSync(tracePath) ? readFileSync(tracePath, "utf8") : ""
    }`,
  );
}

async function waitForQueuedPromptBytes(
  tracePath: string,
  timeoutMs = 30_000,
): Promise<number> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
    const matches = [...trace.matchAll(/queued prompt bytes=(\d+)/g)];
    const latest = matches[matches.length - 1];
    if (latest?.[1]) return Number.parseInt(latest[1], 10);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(
    `Timed out waiting for queued prompt bytes.\nTrace:\n${
      existsSync(tracePath) ? readFileSync(tracePath, "utf8") : ""
    }`,
  );
}

async function waitForSubmittedUserText(
  gateway: ReturnType<typeof startFakeGateway>,
  tracePath: string,
  stderrPath: string,
  timeoutMs = 60_000,
): Promise<string | undefined> {
  const deadline = Date.now() + timeoutMs;
  while (gateway.requests.length === 0 && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const gatewayRequest = gateway.requests[0];
  if (!gatewayRequest) {
    throw new Error(
      `Gateway request not received.\nTrace:\n${readFileSync(tracePath, "utf8")}\nStderr:\n${
        readFileSync(stderrPath, "utf8")
      }`,
    );
  }

  const request = JSON.parse(gatewayRequest.body) as {
    prompt: Array<{
      role: string;
      content?: Array<{ type: string; text?: string }>;
    }>;
  };
  return [...request.prompt]
    .reverse()
    .find((message) => message.role === "user")
    ?.content?.find((part) => part.type === "text")?.text;
}

async function waitForGatewayRequestCount(
  gateway: ReturnType<typeof startFakeGateway>,
  count: number,
  timeoutMs = 10_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (gateway.requests.length < count && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  expect(gateway.requests.length).toBeGreaterThanOrEqual(count);
}

function committedResizeFrameCount(tracePath: string): number {
  if (!existsSync(tracePath)) return 0;
  return committedTraceAttempts(tracePath).filter((attempt) =>
    attemptHasReason(attempt, "resize")
  ).length;
}

async function waitForCommittedResizeFrame(
  tracePath: string,
  previousCount: number,
  timeoutMs = 10_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (committedResizeFrameCount(tracePath) > previousCount) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(
    `Timed out waiting for a committed resize frame.\nTrace:\n${
      existsSync(tracePath) ? readFileSync(tracePath, "utf8") : ""
    }`,
  );
}

async function waitForResizeAndInputTapeFrames(
  tapePath: string,
  startFrame: number,
  input: Buffer,
  timeoutMs = 10_000,
): Promise<ReturnType<typeof readTapeFrames>> {
  const deadline = Date.now() + timeoutMs;
  let frames: ReturnType<typeof readTapeFrames> = [];
  while (Date.now() < deadline) {
    try {
      frames = readTapeFrames(tapePath).slice(startFrame);
      const hasResize = frames.some((frame) => frame.kind === 3);
      const hasInput = frames.some((frame) =>
        frame.kind === 2 && frame.payload.includes(input)
      );
      if (hasResize && hasInput) return frames;
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !error.message.startsWith("truncated tape frame")
      ) throw error;
    }
    await Bun.sleep(25);
  }
  throw new Error(
    `Timed out waiting for resize and input tape frames. Recorded kinds: ${
      frames.map((frame) => frame.kind).join(",")
    }`,
  );
}

function sendRawTmuxBytes(
  session: TmuxSession,
  bufferSuffix: string,
  bytes: Buffer,
): void {
  const buffer = `${session.name}-${bufferSuffix}`;
  execFileSync("tmux", ["load-buffer", "-b", buffer, "-"], {
    input: bytes,
    stdio: ["pipe", "pipe", "pipe"],
  });
  execFileSync("tmux", [
    "paste-buffer",
    ...tmuxRawPasteFlags(),
    "-d",
    "-b",
    buffer,
    "-t",
    session.name,
  ]);
}

function startFileApprovalGateway() {
  const gateway = startFakeGateway([
    fakeGatewayToolCall(
      "resize_file_1",
      "write_file",
      {
        path: "resize-approved.txt",
        content: [
          "preview-one",
          "preview-two",
          "preview-three",
          "preview-four",
          "preview-five",
          "preview-six",
          "preview-seven",
          "preview-eight",
          "preview-nine",
          "",
        ].join("\n"),
      },
    ),
    fakeGatewayFinalText("resize denial complete"),
  ]);
  gateways.push(gateway);
  return gateway;
}

function createFileApprovalRoot() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-resize-file-approval-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {} }),
  );
  tempDirs.push(root);
  return {
    root,
    home: realpathSync(home),
    workspace: realpathSync(workspace),
  };
}

async function waitForMarkersOnDistinctRows(
  s: TmuxSession,
  first: string,
  second: string,
  timeoutMs = 10_000,
): Promise<string[]> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const grid = await s.capturePaneGrid();
    const firstRow = grid.findIndex((line) => line.includes(first));
    const secondRow = grid.findIndex((line) => line.includes(second));
    if (firstRow >= 0 && secondRow >= 0 && firstRow !== secondRow) return grid;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }

  const final = await s.capturePaneGrid();
  throw new Error(
    `Timed out waiting for distinct marker rows: ${first}, ${second}\n${final.join("\n")}`,
  );
}

async function enterHardNewlineInput(
  s: TmuxSession,
  first: string,
  second: string,
): Promise<void> {
  await s.sendLiteral(first);
  await s.sendKeys("-H 1b 0d");
  await s.sendLiteral(second);
  await waitForMarkersOnDistinctRows(s, first, second);
}

async function recoverActiveInput(
  s: TmuxSession,
  markers: string[],
): Promise<void> {
  await s.resizeWindow(80, 24, 500);
  for (const marker of markers) {
    await s.waitForText(marker, 5_000);
  }
  expect(findFooter(await s.capturePaneGrid())).not.toBeNull();
}

function findFooter(grid: string[]): FooterBlock | null {
  return findFooterBlocks(grid).at(-1) ?? null;
}

function findSkillsScreen(grid: string[]): { topDivider: number; header: number; bottomDivider: number; hint: number } | null {
  const header = grid.findIndex((line) => line.includes("Skills "));
  if (header <= 0 || !isDividerRow(grid[header - 1]!)) return null;
  if (!isInputRow(grid[0]!)) return null;
  const bottomDivider = grid.findLastIndex((line) => isDividerRow(line));
  if (bottomDivider <= header || bottomDivider + 1 >= grid.length) return null;
  if (!grid[bottomDivider + 1]!.includes("Esc Close")) return null;
  return {
    topDivider: header - 1,
    header,
    bottomDivider,
    hint: bottomDivider + 1,
  };
}

function findHelpScreen(grid: string[]): { topDivider: number; header: number; bottomDivider: number; hint: number } | null {
  const header = grid.findIndex((line) => line.includes("Commands "));
  if (header <= 0 || !isDividerRow(grid[header - 1]!)) return null;
  if (!isInputRow(grid[0]!)) return null;
  const bottomDivider = grid.findLastIndex((line) => isDividerRow(line));
  if (bottomDivider <= header || bottomDivider + 1 >= grid.length) return null;
  if (!grid[bottomDivider + 1]!.includes("Enter Open")) return null;
  return {
    topDivider: header - 1,
    header,
    bottomDivider,
    hint: bottomDivider + 1,
  };
}

async function runLargeSkillResizeAttempt(attempt: number): Promise<string> {
  const fixture = createLargeSkillFixture(attempt);
  const shrinkRows = attempt === 1 ? 24 : 16;
  const tracePath = join(fixture.root, "trace.log");
  const stderrPath = join(fixture.root, "stderr.log");
  const tapePath = join(fixture.root, "session.fxtape");
  const paneBeforeShrinkPath = join(fixture.root, "pane-before-shrink.txt");
  const paneAfterShrinkPath = join(fixture.root, "pane-after-shrink.txt");
  const scrollbackBeforeShrinkPath = join(
    fixture.root,
    "scrollback-before-shrink.txt",
  );
  const scrollbackAfterShrinkPath = join(
    fixture.root,
    "scrollback-after-shrink.txt",
  );
  const panePath = join(fixture.root, "pane-final.txt");
  const scrollbackPath = join(fixture.root, "scrollback-final.txt");
  const statusPath = join(fixture.root, "pane-status.json");
  writeFileSync(stderrPath, "");
  writeFileSync(
    join(fixture.root, "commands.txt"),
    [
      `cwd=${fixture.workspace}`,
      `HOME=${fixture.home}`,
      `binary=${FX_BIN}`,
      "tmux_size=120x34",
      "tmux_remain_on_exit=on",
      `minimum_history_lines=${MINIMUM_RESIZE_HISTORY_LINES}`,
      "1. /skills list",
      `2. tmux resize-window 70x${shrinkRows}`,
      "3. tmux resize-window 120x34",
      "4. wait for retained footer-only commit",
      "5. /skills list",
      "",
    ].join("\n"),
  );

  let s: TmuxSession | null = null;
  try {
    s = await createResizeSession({
      cmd: FX_BIN,
      cwd: fixture.workspace,
      env: {
        HOME: fixture.home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_RECORD: tapePath,
        FX_RECORD_INPUT: "1",
        FX_TRACE_LOG: tracePath,
        FX_TRACE_SCOPES:
          "frame_schedule,frame_plan,frame_diff,frame_commit,scroll,resize,input",
        NO_COLOR: "1",
      },
      width: 120,
      height: 34,
      stderrPath,
      remainOnExit: true,
      minimumHistoryLines: MINIMUM_RESIZE_HISTORY_LINES,
    });
    session = s;
    const historyLimit = s.historyLimit();
    expect(historyLimit).toBeGreaterThanOrEqual(MINIMUM_RESIZE_HISTORY_LINES);
    await s.waitForComposer(10_000);

    const menuHeading = `Skills ${LARGE_SKILL_COUNT}`;
    await s.sendText("/skills list");
    const beforeShrinkGrid = await waitForSkillsMenuGrid(
      s,
      LARGE_SKILL_COUNT,
      30_000,
    );
    expectSkillsMenuGrid(beforeShrinkGrid, LARGE_SKILL_COUNT, fixture.names);
    const beforeShrinkScrollback = await s.captureFullScrollback();
    expectNoTranscriptSkillInventory(beforeShrinkScrollback);
    writeFileSync(paneBeforeShrinkPath, (await s.capturePane()) + "\n");
    writeFileSync(scrollbackBeforeShrinkPath, beforeShrinkScrollback);
    expect(s.paneStatus().dead).toBe(false);

    const beforeShrink = readTraceLines(tracePath).length - 1;
    await s.resizeWindow(70, shrinkRows, 250);
    const shrinkAttempt = await waitForCommittedTraceAttempt(
      tracePath,
      beforeShrink,
      (candidate) => attemptHasReason(candidate, "resize"),
    );
    expect(s.paneSize()).toEqual({ cols: 70, rows: shrinkRows });
    expect(shrinkAttempt.beginLine).toContain("resize");
    const shrinkCycle = await waitForResizeCycle(tracePath, beforeShrink, (cycle) =>
      cycle.oldSize.cols === 120 &&
      cycle.oldSize.rows === 34 &&
      cycle.newSize.cols === 70 &&
      cycle.newSize.rows === shrinkRows
    );
    expect(shrinkCycle.historyRowDelta).toBeGreaterThanOrEqual(0);
    expect(attemptLine(shrinkAttempt, "attempt_result ")).toBeUndefined();
    expect(attemptLine(shrinkAttempt, "transcript_transition_finalize ")).toBeUndefined();
    expect(attemptLine(shrinkAttempt, "tmux_clear_history_complete")).toBeUndefined();
    const shrinkGrid = await waitForSkillsMenuGrid(s, LARGE_SKILL_COUNT);
    expectSkillsMenuGrid(shrinkGrid, LARGE_SKILL_COUNT, fixture.names);
    const shrinkScrollback = await s.captureFullScrollback();
    writeFileSync(paneAfterShrinkPath, (await s.capturePane()) + "\n");
    writeFileSync(scrollbackAfterShrinkPath, shrinkScrollback);
    expectNoTranscriptSkillInventory(shrinkScrollback);
    expect(s.paneStatus()).toEqual({ dead: false, status: null });
    expect(s.isPaneAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");

    const beforeGrow = readTraceLines(tracePath).length - 1;
    await s.resizeWindow(120, 34, 250);
    const growAttempt = await waitForCommittedTraceAttempt(
      tracePath,
      beforeGrow,
      (candidate) => attemptHasReason(candidate, "resize"),
    );
    expect(s.paneSize()).toEqual({ cols: 120, rows: 34 });
    expect(attemptLine(growAttempt, "attempt_result ")).toBeUndefined();
    expect(attemptLine(growAttempt, "transcript_transition_commit ")).toBeUndefined();
    const growGrid = await waitForSkillsMenuGrid(s, LARGE_SKILL_COUNT);
    expectSkillsMenuGrid(growGrid, LARGE_SKILL_COUNT, fixture.names);
    const growScrollback = await s.captureFullScrollback();
    expectNoTranscriptSkillInventory(growScrollback);

    await s.sendKeys("C-[");
    const restoredPane = await s.waitForPane((pane) => {
      const grid = pane.split("\n");
      return (
        pane.includes("𝒇x") &&
        !pane.includes("↑↓ Navigate") &&
        findFooter(grid) !== null
      );
    }, 5_000);
    expect(findFooter(restoredPane.split("\n"))).not.toBeNull();
    await s.sendText("/skills list");
    const finalGrid = await waitForSkillsMenuGrid(s, LARGE_SKILL_COUNT);
    expectSkillsMenuGrid(finalGrid, LARGE_SKILL_COUNT, fixture.names);
    const scrollback = await s.captureFullScrollback();
    expect(scrollback).toContain(menuHeading);
    expectNoTranscriptSkillInventory(scrollback);
    const scrollbackLines = scrollback.replace(/\n$/, "").split("\n").length;
    expect(scrollbackLines).toBeLessThan(historyLimit / 2);
    expect(finalGrid.filter(isInputRow)).toHaveLength(1);
    expect(findSkillsScreen(finalGrid)).not.toBeNull();
    expect(s.paneStatus()).toEqual({ dead: false, status: null });
    expect(s.isPaneAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    const trace = readFileSync(tracePath, "utf8");
    expect(trace).not.toContain("InvalidFrameScrollPlan");
    expect(trace).not.toContain("attempt_restore outcome=error");
    expect(existsSync(tapePath)).toBe(true);
    expect(readFileSync(tapePath).byteLength).toBeGreaterThan(0);

    writeFileSync(panePath, (await s.capturePane()) + "\n");
    writeFileSync(scrollbackPath, scrollback);
    writeFileSync(
      statusPath,
      JSON.stringify(
        {
          pane: s.paneStatus(),
          size: s.paneSize(),
          historyLimit,
          scrollbackLines,
        },
        null,
        2,
      ) + "\n",
    );
    return fixture.root;
  } catch (err) {
    if (s) {
      writeFileSync(panePath, (await s.capturePane()) + "\n");
      writeFileSync(scrollbackPath, await s.captureFullScrollback());
      writeFileSync(
        statusPath,
        JSON.stringify({ pane: s.paneStatus(), size: s.paneSize() }, null, 2) +
          "\n",
      );
    }
    throw err;
  } finally {
    if (s) await s.kill();
    if (session === s) session = null;
  }
}

type RapidSkillAttemptResult = {
  root: string;
  delayMs: number;
  attempt: number;
};

function retainTempDir(path: string): void {
  const index = tempDirs.indexOf(path);
  if (index >= 0) tempDirs.splice(index, 1);
}

async function runRapidSkillResizeAttempt(
  delayMs: number,
  attempt: number,
): Promise<RapidSkillAttemptResult> {
  const fixture = createSkillFixture(
    attempt,
    RAPID_SKILL_COUNT,
    `rapid-${delayMs}ms`,
    3,
  );
  const tracePath = join(fixture.root, "trace.log");
  const stderrPath = join(fixture.root, "stderr.log");
  const tapePath = join(fixture.root, "session.fxtape");
  const panePath = join(fixture.root, "pane-final.txt");
  const scrollbackPath = join(fixture.root, "scrollback-final.txt");
  const classificationPath = join(fixture.root, "classification.json");
  writeFileSync(stderrPath, "");
  writeFileSync(
    join(fixture.root, "commands.txt"),
    [
      `cwd=${fixture.workspace}`,
      `HOME=${fixture.home}`,
      `binary=${FX_BIN}`,
      `inter_resize_delay_ms=${delayMs}`,
      "tmux_size=120x34",
      "1. /skills list",
      "2. tmux resize-window 70x24",
      `3. wait ${delayMs} ms`,
      "4. tmux resize-window 120x34",
      "5. /skills list",
      "",
    ].join("\n"),
  );

  let s: TmuxSession | null = null;
  try {
    s = await createResizeSession({
      cmd: FX_BIN,
      cwd: fixture.workspace,
      env: {
        HOME: fixture.home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_RECORD: tapePath,
        FX_RECORD_INPUT: "1",
        FX_TRACE_LOG: tracePath,
        FX_TRACE_SCOPES:
          "frame_schedule,frame_plan,frame_diff,frame_commit,scroll,resize,input",
        NO_COLOR: "1",
      },
      width: 120,
      height: 34,
      stderrPath,
      remainOnExit: true,
      minimumHistoryLines: MINIMUM_RESIZE_HISTORY_LINES,
    });
    session = s;
    await s.waitForComposer(10_000);

    await s.sendText("/skills list");
    const beforeGrid = await waitForSkillsMenuGrid(s, RAPID_SKILL_COUNT);
    expectSkillsMenuGrid(beforeGrid, RAPID_SKILL_COUNT, fixture.names);
    const beforeScrollback = await s.captureFullScrollback();
    expectNoTranscriptSkillInventory(beforeScrollback);
    writeFileSync(join(fixture.root, "scrollback-before-shrink.txt"), beforeScrollback);

    const beforeShrink = readTraceLines(tracePath).length - 1;
    await s.resizeWindow(70, 24, delayMs);
    writeFileSync(
      join(fixture.root, "scrollback-after-shrink-signal.txt"),
      await s.captureFullScrollback(),
    );
    await s.resizeWindow(120, 34, 250);
    const [shrink, grow] = await waitForResizeCycles(tracePath, beforeShrink);
    expect(s.paneSize()).toEqual({ cols: 120, rows: 34 });

    const growCommit = attemptLine(grow.attempt, "transcript_transition_commit ");
    expect(growCommit).toBeUndefined();
    const growGrid = await waitForSkillsMenuGrid(s, RAPID_SKILL_COUNT);
    expectSkillsMenuGrid(growGrid, RAPID_SKILL_COUNT, fixture.names);
    const growScrollback = await s.captureFullScrollback();
    expectNoTranscriptSkillInventory(growScrollback);
    writeFileSync(join(fixture.root, "scrollback-after-grow.txt"), growScrollback);

    expect(attemptLine(shrink.attempt, "transcript_transition_finalize ")).toBeUndefined();
    expect(attemptLine(grow.attempt, "transcript_transition_finalize ")).toBeUndefined();
    expect(attemptLine(shrink.attempt, "attempt_result ")).toBeUndefined();
    expect(attemptLine(grow.attempt, "attempt_result ")).toBeUndefined();
    expect(attemptLine(shrink.attempt, "tmux_clear_history_complete")).toBeUndefined();
    expect(attemptLine(grow.attempt, "tmux_clear_history_complete")).toBeUndefined();

    await s.sendKeys("C-[");
    const dismissed = await s.waitForPane(
      (pane) => {
        const grid = pane.replace(/\n$/, "").split("\n");
        return pane.includes("𝒇x") &&
          !pane.includes("↑↓ Navigate") &&
          findFooter(grid) !== null;
      },
      5_000,
    );
    expect(findFooter(dismissed.replace(/\n$/, "").split("\n"))).not.toBeNull();
    await s.sendText("/skills list");
    const finalGrid = await waitForSkillsMenuGrid(s, RAPID_SKILL_COUNT);
    expectSkillsMenuGrid(finalGrid, RAPID_SKILL_COUNT, fixture.names);
    const finalScrollback = await s.captureFullScrollback();
    expectNoTranscriptSkillInventory(finalScrollback);
    expect(finalGrid.filter(isInputRow)).toHaveLength(1);
    expect(findSkillsScreen(finalGrid)).not.toBeNull();
    expect(s.paneStatus()).toEqual({ dead: false, status: null });
    expect(s.isPaneAlive()).toBe(true);
    expect(readFileSync(stderrPath, "utf8")).toBe("");
    const trace = readFileSync(tracePath, "utf8");
    expect(trace).not.toContain("InvalidFrameScrollPlan");
    expect(trace).not.toContain("attempt_restore outcome=error");

    writeFileSync(panePath, (await s.capturePane()) + "\n");
    writeFileSync(scrollbackPath, finalScrollback);
    writeFileSync(
      classificationPath,
      JSON.stringify(
        {
          delayMs,
          attempt,
          shrink: {
            apply: shrink.applyLine,
            cursor: shrink.cursorLine,
            historyRowDelta: shrink.historyRowDelta,
          },
          grow: {
            apply: grow.applyLine,
            cursor: grow.cursorLine,
            historyRowDelta: grow.historyRowDelta,
            commit: growCommit,
          },
        },
        null,
        2,
      ) + "\n",
    );
    return { root: fixture.root, delayMs, attempt };
  } catch (error) {
    retainTempDir(fixture.root);
    writeFileSync(
      classificationPath,
      JSON.stringify(
        {
          delayMs,
          attempt,
          error: error instanceof Error ? error.message : String(error),
        },
        null,
        2,
      ) + "\n",
    );
    if (s) {
      writeFileSync(panePath, (await s.capturePane()) + "\n");
      writeFileSync(scrollbackPath, await s.captureFullScrollback());
    }
    throw error;
  } finally {
    if (s) await s.kill();
    if (session === s) session = null;
  }
}

describe.skipIf(SKIP)("tui: resize", () => {
  test(
    "welcome header starts at the first terminal row",
    async () => {
      session = await launchAt(120, 40);

      const grid = await session.capturePaneGrid();
      const headerRow = grid.findIndex((line) => line.includes("𝒇x v"));
      expect(headerRow).toBe(0);
    },
    TIMEOUT,
  );

  test(
    "gated tmux launch retains an immediate nonzero exit without global option changes",
    async () => {
      session = await createResizeSession({ cmd: "sleep 120" });
      const before = globalTmuxOptions();
      let retained: TmuxSession | null = null;
      try {
        retained = await createResizeSession({
          cmd: "/bin/sh -c \"printf 'TMUX_GATED_EXIT_37\\n'; exit 37\"",
          remainOnExit: true,
          minimumHistoryLines: 1,
        });
        expect(paneExitMatches(retained.paneStatus(), 37)).toBe(true);
        expect(await retained.captureFullScrollback()).toContain(
          "TMUX_GATED_EXIT_37",
        );
        expect(globalTmuxOptions()).toEqual(before);
      } finally {
        if (retained) {
          await retained.kill();
          expect(retained.isAlive()).toBe(false);
        }
      }
    },
    TIMEOUT,
  );

  test(
    "gated tmux setup failure cleans the session before releasing the command",
    async () => {
      session = await createResizeSession({ cmd: "sleep 120" });
      const dir = mkdtempSync(join(tmpdir(), "fx-tmux-gate-failure-"));
      tempDirs.push(dir);
      const markerPath = join(dir, "command-ran");
      const before = matchingTestSessions();

      await expect(
        createResizeSession({
          cmd: `printf reached > ${quoteShellPath(markerPath)}`,
          remainOnExit: true,
          minimumHistoryLines: Number.MAX_SAFE_INTEGER,
        }),
      ).rejects.toThrow("below required minimum");

      expect(matchingTestSessions()).toEqual(before);
      expect(existsSync(markerPath)).toBe(false);
    },
    TIMEOUT,
  );

  test(
    "settled resize replays a long assistant transcript from the header",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-long-transcript-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      tempDirs.push(root);
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(stderrPath, "");

      const markers = Array.from(
        { length: 48 },
        (_, index) => `LONG_RESIZE_REPLAY_MARKER_${String(index).padStart(3, "0")}`,
      );
      const response = markers
        .map(
          (marker) =>
            `${marker} keeps this assistant transcript taller than the terminal viewport.`,
        )
        .join("\n");
      const gateway = startFakeGateway([fakeGatewayFinalText(response)]);
      gateways.push(gateway);
      session = await createResizeSession({
        cmd: `sh -c ${quoteShellPath(
          `printf 'PRE_FX_MARKER_long_resize\\n'; exec ${quoteShellPath(FX_BIN)}`,
        )}`,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-long-resize-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "frame_schedule,frame_diff,frame_commit,scroll,resize",
          NO_COLOR: "1",
        },
        width: 120,
        height: 34,
        stderrPath,
        remainOnExit: true,
        minimumHistoryLines: MINIMUM_RESIZE_HISTORY_LINES,
      });
      await session.waitForComposer(10_000);
      await session.sendText("render the long resize transcript");
      await waitForLiveScrollbackText(session, markers.at(-1)!, 30_000);

      const beforeResize = readTraceLines(tracePath).length - 1;
      await session.resizeWindow(72, 24, 500);
      await waitForCommittedTraceAttempt(
        tracePath,
        beforeResize,
        (candidate) => attemptHasReason(candidate, "resize"),
      );

      const scrollback = await waitForScrollbackWithoutText(
        session,
        "PRE_FX_MARKER_",
      );
      expect(scrollback.match(/𝒇x v\d+\.\d+\.\d+\b/g)).toHaveLength(1);
      expect(scrollback.match(/Run \/help for commands/g)).toHaveLength(1);
      expectOrderedMarkersWithoutBlankHole(scrollback, markers);
      const grid = await waitForSettledFooter(session);
      expect(findFooterBlocks(grid)).toHaveLength(1);
      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(stderrPath);
    },
    LARGE_SKILL_TIMEOUT,
  );

  test(
    "live command resize preserves current grouped scrollback while output is folded",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-live-command-scrollback-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const tapePath = join(root, "session.fxtape");
      const preFxMarker = "PRE_FX_RESIZE_STREAM_MARKER";
      const finalResponse = "RESIZE_STREAM_FINAL_RESPONSE";
      tempDirs.push(root);
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {} }),
      );
      writeFileSync(stderrPath, "");

      const command =
        "for i in $(seq 1 96); do printf 'resize-stream-marker %03d\\n' \"$i\"; sleep 0.03; done";
      const gateway = startFakeGateway([
        fakeGatewayToolCall("resize-live-command", "terminal", { action: "exec", command }),
        fakeGatewayFinalText(finalResponse),
      ]);
      gateways.push(gateway);
      session = await createResizeSession({
        cmd: `sh -c ${quoteShellPath(
          `printf '${preFxMarker}\\n'; exec ${quoteShellPath(FX_BIN)}`,
        )}`,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-resize-command-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "frame_schedule,frame_diff,frame_commit,scroll,resize",
          NO_COLOR: "1",
        },
        width: 110,
        height: 32,
        stderrPath,
        remainOnExit: true,
        minimumHistoryLines: MINIMUM_RESIZE_HISTORY_LINES,
      });
      await session.waitForComposer(10_000);
      await session.sendText("stream the resize marker command");
      await session.waitForText("Running for i in $(seq 1 96)", TIMEOUT);

      const resizeCount = committedResizeFrameCount(tracePath);
      await new Promise((resolve) => setTimeout(resolve, 350));
      await session.resizeWindow(64, 16, 250);
      await waitForCommittedResizeFrame(tracePath, resizeCount);
      await waitForLiveScrollbackText(session, finalResponse, TIMEOUT);

      const scrollback = await session.captureFullScrollback();
      expect(scrollback.match(/𝒇x v\d+\.\d+\.\d+\b/g)).toHaveLength(1);
      expect(scrollback.match(/Run \/help for commands/g)).toHaveLength(1);
      expect(scrollback).toContain("stream the resize marker command");
      expect(scrollback).not.toContain(preFxMarker);
      expect(scrollback).toContain("● 1 tool call · 1 command");
      expect(scrollback).toContain("Ran for i in $(seq 1 96)");
      expect(scrollback).not.toContain("resize-stream-marker 001");
      expect(scrollback).not.toContain("resize-stream-marker 096");
      expect(scrollback).toContain(finalResponse);
      expect(gateway.requests).toHaveLength(2);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(readFileSync(tracePath, "utf8")).not.toContain("InvalidFrameScrollPlan");
      expect(readFileSync(tapePath).byteLength).toBeGreaterThan(0);
      const grid = await waitForSettledFooter(session);
      expect(findFooterBlocks(grid)).toHaveLength(1);
      expect(session.isPaneAlive()).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "structured retention keeps native scrollback complete before resize",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-retention-native-scrollback-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      tempDirs.push(root);
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {} }),
      );
      writeFileSync(stderrPath, "");

      const begin = "RETENTION_SCROLLBACK_BEGIN";
      const end = "RETENTION_SCROLLBACK_END";
      const beforeMarkers = Array.from(
        { length: 120 },
        (_, index) => `RETENTION_A_${String(index).padStart(3, "0")}`,
      );
      const afterMarkers = Array.from(
        { length: 120 },
        (_, index) => `RETENTION_B_${String(index).padStart(3, "0")}`,
      );
      const markers = [
        begin,
        ...beforeMarkers,
        ...afterMarkers,
        end,
      ];
      const response = fakeGatewaySse([
        {
          type: "text-delta",
          id: "retention-text-a",
          delta: `${begin}\n${beforeMarkers.map((marker) =>
            `${marker} retained before semantic code block`
          ).join("\n")}\n`,
        },
        {
          type: "text-delta",
          id: "retention-code",
          delta: "```zig\nconst retained_scrollback = true;\n```\n",
        },
        {
          type: "text-delta",
          id: "retention-text-b",
          delta: `${afterMarkers.map((marker) =>
            `${marker} retained after semantic code block`
          ).join("\n")}\n`,
        },
        {
          type: "text-delta",
          id: "retention-tail",
          delta:
            "| phase | state |\n| --- | --- |\n| middle | retained |\n\n---\n" +
            `${end}\n`,
        },
        {
          type: "finish",
          finishReason: { unified: "stop", raw: "stop" },
          usage: {
            inputTokens: { total: 3 },
            outputTokens: { total: 5_000 },
          },
        },
      ]);
      const command =
        `awk 'BEGIN { for (i = 0; i < 13500; i++) printf "RETENTION_SEED_%05d alpha beta gamma delta epsilon zeta eta theta iota kappa lambda\\n", i }'`;
      const gateway = startFakeGateway([
        fakeGatewayToolCall("retention-seed", "terminal", { action: "exec", command }),
        response,
      ]);
      gateways.push(gateway);

      session = await createResizeSession({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-retention-scrollback-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_MAX_AGENT_STEPS: "4",
          FX_AUTO_UPGRADE: "0",
          NO_COLOR: "1",
        },
        width: 120,
        height: 40,
        stderrPath,
        minimumHistoryLines: MINIMUM_RESIZE_HISTORY_LINES,
      });
      await session.waitForComposer(10_000);
      await session.sendText("exercise structured retention scrollback");
      await waitForLiveScrollbackText(session, end, 60_000);
      await waitForGatewayRequestCount(gateway, 2, 60_000);
      await session.waitForPane(
        (pane) => pane.includes(end) && hasEmptyComposer(pane),
        60_000,
      );

      const assertMarkersExactlyOnce = (scrollback: string) => {
        for (const marker of markers) {
          expect(countOccurrences(scrollback, marker)).toBe(1);
        }
      };
      const beforeResize = await session.captureFullScrollback();
      assertMarkersExactlyOnce(beforeResize);

      await session.resizeWindow(72, 24, 700);
      await waitForSettledFooter(session);
      assertMarkersExactlyOnce(await session.captureFullScrollback());

      await session.resizeWindow(120, 40, 700);
      const grid = await waitForSettledFooter(session);
      assertMarkersExactlyOnce(await session.captureFullScrollback());
      expect(findFooterBlocks(grid)).toHaveLength(1);
      expect(gateway.requests).toHaveLength(2);
      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(stderrPath);
    },
    LARGE_SKILL_TIMEOUT,
  );

  test(
    "cancelling a resized command approval keeps one startup banner",
    async () => {
      const testDeadline = Date.now() + TIMEOUT - TEST_TEARDOWN_HEADROOM_MS;
      const remainingTimeout = () => Math.max(0, testDeadline - Date.now());
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-cancel-command-approval-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const tapePath = join(root, "session.fxtape");
      const markerPath = join(workspace, "approval-cancel-ran.txt");
      const command = "touch approval-cancel-ran.txt";
      const seedMarker = "APPROVAL_CANCEL_RESIZE_SCROLLBACK_SEED";
      const approvalQuestion = "Would you like to run the following command?";
      const stableCommitTrace = "transcript_transition_commit state=stable";
      if (!KEEP_LARGE_SKILL_ARTIFACTS) tempDirs.push(root);
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ sandbox: "none", permission_mode: "ask", permission: {} }),
      );
      writeFileSync(stderrPath, "");
      writeFileSync(
        join(root, "commands.txt"),
        [
          `binary=${FX_BIN}`,
          "tmux_size=120x36",
          "1. submit seed prompt",
          "2. submit effectful command prompt",
          "3. capture full scrollback",
          "4. tmux resize-window 88x24",
          "5. capture full scrollback",
          "6. press Escape",
          "7. capture full scrollback",
          "",
        ].join("\n"),
      );

      const gateway = startFakeGateway([
        fakeGatewayFinalText(seedMarker),
        fakeGatewayToolCall("approval-cancel-resize", "terminal", {
          action: "exec",
          command,
        }),
      ]);
      gateways.push(gateway);
      const active = await createResizeSession({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-approval-cancel-resize-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "frame_schedule,frame_plan,frame_diff,frame_commit,scroll,resize,input,permission,interrupt,render",
          NO_COLOR: "1",
        },
        width: 120,
        height: 36,
        stderrPath,
        remainOnExit: true,
        minimumHistoryLines: MINIMUM_RESIZE_HISTORY_LINES,
      });
      session = active;
      const captureScrollback = async (label: string) => {
        const scrollback = await active.captureFullScrollback();
        writeFileSync(join(root, `${label}-full-scrollback.txt`), scrollback);
        return scrollback;
      };

      await active.waitForComposer(remainingTimeout());
      await active.sendText("Seed the approval cancellation scrollback.");
      await waitForLiveScrollbackText(active, seedMarker, remainingTimeout());
      await waitForGatewayRequestCount(gateway, 1, remainingTimeout());
      await active.waitForPane((pane) => {
        const lastLine = pane.trimEnd().split("\n").at(-1)?.trim() ?? "";
        return pane.includes(seedMarker) && hasEmptyComposer(pane) &&
          lastLine.startsWith("ask ·");
      }, remainingTimeout());

      await active.sendText(`Run command: ${command}`);
      await active.waitForText(approvalQuestion, remainingTimeout());
      await waitForGatewayRequestCount(gateway, 2, remainingTimeout());
      const beforeResizeScrollback = await captureScrollback("before-resize");

      const beforeResizeLine = readTraceLines(tracePath).length - 1;
      await active.resizeWindow(88, 24, 500);
      const resizeAttempt = await waitForCommittedTraceAttempt(
        tracePath,
        beforeResizeLine,
        (candidate) => {
          if (!attemptHasReason(candidate, "resize")) return false;
          const commit = attemptLine(candidate, stableCommitTrace);
          return commit !== undefined &&
            numericTraceField(commit, "history_visual_offset") > 0;
        },
        remainingTimeout(),
      );
      const resizeCommit = attemptLine(resizeAttempt, stableCommitTrace)!;
      expect(numericTraceField(resizeCommit, "history_visual_offset"))
        .toBeGreaterThan(0);
      await active.waitForText(approvalQuestion, remainingTimeout());
      const resizedScrollback = await captureScrollback("resized-approval");

      const beforeCancelLine = readTraceLines(tracePath).length - 1;
      await active.sendKeys("Escape");
      await active.waitForText("■ Cancelled", remainingTimeout());
      const cancellationAttempt = await waitForCommittedTraceAttempt(
        tracePath,
        beforeCancelLine,
        (candidate) =>
          attemptLine(candidate, stableCommitTrace) !== undefined,
        remainingTimeout(),
      );
      const cleanupAttempt = await waitForCommittedTraceAttempt(
        tracePath,
        cancellationAttempt.endIndex,
        (candidate) =>
          attemptLine(candidate, stableCommitTrace) !== undefined,
        remainingTimeout(),
      );
      const cleanupTrace = readTraceLines(tracePath)
        .slice(cancellationAttempt.endIndex + 1, cleanupAttempt.beginIndex)
        .join("\n");
      expect(cleanupTrace).toMatch(
        /transcript_anchor_structured_rewrite_preserve .*reason=lifecycle_pin_cleanup/,
      );
      await active.waitForPane((pane) => {
        const lastLine = pane.trimEnd().split("\n").at(-1)?.trim() ?? "";
        return pane.includes("■ Cancelled") && lastLine.startsWith("ask ·");
      }, remainingTimeout());
      const afterCancelScrollback = await captureScrollback("after-cancel");

      const transcriptCopyCounts = (scrollback: string) => ({
        startup: scrollback.match(/𝒇x v\d+\.\d+\.\d+\b/g)?.length ?? 0,
        help: countOccurrences(scrollback, "Run /help for commands"),
        recording: countOccurrences(
          scrollback,
          "● Recording: visual terminal capture:",
        ),
        seed: countOccurrences(scrollback, seedMarker),
      });
      const counts = {
        beforeResize: transcriptCopyCounts(beforeResizeScrollback),
        resized: transcriptCopyCounts(resizedScrollback),
        afterCancel: transcriptCopyCounts(afterCancelScrollback),
      };
      writeFileSync(
        join(root, "scrollback-counts.json"),
        JSON.stringify(counts, null, 2) + "\n",
      );

      expect(existsSync(markerPath)).toBe(false);
      expect(afterCancelScrollback).toContain("■ Cancelled");
      expect(afterCancelScrollback).not.toContain(approvalQuestion);
      expect(gateway.requests).toHaveLength(2);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      const replay = JSON.parse(
        execFileSync(FX_BIN, ["replay", tapePath, "--json"], { encoding: "utf8" }),
      ) as { resize_count: number };
      expect(replay.resize_count).toBe(1);
      expect(active.paneStatus()).toEqual({ dead: false, status: null });
      expect(active.isPaneAlive()).toBe(true);
      expect(counts.beforeResize).toEqual({
        startup: 1,
        help: 1,
        recording: 1,
        seed: 1,
      });
      expect(counts.resized).toEqual(counts.beforeResize);
      expect(counts.afterCancel).toEqual(counts.beforeResize);
    },
    TIMEOUT,
  );

  test(
    "semantic thematic rule reflows across a live tmux shrink and grow",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-thematic-rule-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      tempDirs.push(root);
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(stderrPath, "");

      const before = "THEMATIC_RULE_BEFORE";
      const after = "THEMATIC_RULE_AFTER";
      const gateway = startFakeGateway([
        fakeGatewayFinalText(`${before}\n\n---\n${after}`),
      ]);
      gateways.push(gateway);
      session = await createResizeSession({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-thematic-rule-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          NO_COLOR: "1",
        },
        width: 120,
        height: 40,
        stderrPath,
      });
      await session.waitForComposer(10_000);
      await session.sendText("render the thematic rule fixture");
      await waitForLiveScrollbackText(session, after);

      const expectRule = async (cols: number) => {
        const deadline = Date.now() + 10_000;
        const gutter = cols >= 3 ? 2 : cols === 2 ? 1 : 0;
        let grid: string[] = [];
        let terminalRows: string[] = [];
        while (Date.now() < deadline) {
          grid = await session!.capturePaneGrid();
          terminalRows = (await session!.captureFullScrollback()).split("\n");
          const ruleRows = terminalRows.filter((line) => {
            const rule = line.trimEnd();
            return rule.startsWith(" ".repeat(gutter)) &&
              Array.from(rule).filter((glyph) => glyph === "─").length === cols - gutter;
          });
          if (findFooter(grid) !== null && ruleRows.length === 1) break;
          await new Promise((resolve) => setTimeout(resolve, 50));
        }

        const footer = findFooter(grid);
        expect(footer).not.toBeNull();
        const ruleRows = terminalRows.filter((line) => {
          const rule = line.trimEnd();
          return rule.startsWith(" ".repeat(gutter)) &&
            Array.from(rule).filter((glyph) => glyph === "─").length === cols - gutter;
        });
        expect(ruleRows).toHaveLength(1);
        const rule = ruleRows[0]!.trimEnd();
        expect(rule.slice(0, gutter)).toBe(" ".repeat(gutter));
        expect(Array.from(rule).filter((glyph) => glyph === "─")).toHaveLength(
          cols - gutter,
        );
        expect(grid[footer!.input]).toBe("┃");
      };

      await expectRule(120);
      await session.resizeWindow(48, 40, 500);
      await expectRule(48);
      await session.resizeWindow(120, 40, 500);
      await expectRule(120);

      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "nested Markdown blockquote reflows across a live tmux shrink and grow",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-nested-blockquote-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      tempDirs.push(root);
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(stderrPath, "");

      const sentinel = "NESTED_QUOTE_RESIZE_SENTINEL";
      const lazySentinel = "LAZY_NESTED_QUOTE_RESIZE_SENTINEL";
      const gateway = startFakeGateway([
        fakeGatewayFinalText(
          `> > ${sentinel} keeps the full nested quote prefix visible while this deliberately long assistant response wraps across multiple terminal rows during the live resize exercise.\n${lazySentinel} keeps both quote rules without repeating the source markers while this continuation also wraps during the live resize exercise.`,
        ),
      ]);
      gateways.push(gateway);
      session = await createResizeSession({
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-nested-blockquote-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "resize,frame_schedule,scroll",
          NO_COLOR: "1",
        },
        width: 120,
        height: 40,
        stderrPath,
      });
      await session.waitForComposer(10_000);
      await session.sendText("render the nested blockquote fixture");
      await waitForLiveScrollbackText(session, lazySentinel);

      const expectNestedQuote = async (cols: number, minimumRows: number) => {
        const deadline = Date.now() + 10_000;
        const gutter = cols >= 3 ? 2 : cols === 2 ? 1 : 0;
        const prefix = " ".repeat(gutter) + "│ │ ";
        let grid: string[] = [];
        let terminalRows: string[] = [];
        while (Date.now() < deadline) {
          grid = await session!.capturePaneGrid();
          terminalRows = (await session!.captureFullScrollback()).split("\n");
          const quoteRows = terminalRows.filter((line) => line.startsWith(prefix));
          if (
            findFooter(grid) !== null &&
            quoteRows.length >= minimumRows &&
            terminalRows.some((line) => line.startsWith(prefix) && line.includes(lazySentinel))
          ) break;
          await new Promise((resolve) => setTimeout(resolve, 50));
        }

        const quoteRows = terminalRows.filter((line) => line.startsWith(prefix));
        expect(quoteRows.length).toBeGreaterThanOrEqual(minimumRows);
        expect(
          terminalRows.some((line) => line.startsWith(prefix) && line.includes(lazySentinel)),
        ).toBe(true);
        expect(terminalRows.join("\n")).not.toContain("> >");
        const footer = findFooter(grid);
        expect(footer).not.toBeNull();
        expect(grid[footer!.input]).toBe("┃");
      };

      await expectNestedQuote(120, 1);
      await session.resizeWindow(48, 40, 500);
      await waitForTraceCount(tracePath, "settled_reset_committed", 1);
      await expectNestedQuote(48, 2);
      await session.resizeWindow(120, 40, 500);
      await waitForTraceCount(tracePath, "settled_reset_committed", 2);
      await expectNestedQuote(120, 1);

      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(stderrPath);
    },
    90_000,
  );

  test(
    "large skills menu remains canonical across shrink grow and footer settle",
    async () => {
      const roots: string[] = [];
      for (const attempt of [1, 2]) {
        roots.push(await runLargeSkillResizeAttempt(attempt));
      }
      if (KEEP_LARGE_SKILL_ARTIFACTS) {
        console.log(`Fx resize artifacts:\n${roots.join("\n")}`);
        console.log(
          `Cleanup: rm -rf ${roots.map(quoteShellPath).join(" ")}`,
        );
      }
    },
    LARGE_SKILL_TIMEOUT,
  );

  test(
    "rapid four-skill resize keeps canonical skills menu content",
    async () => {
      const results: RapidSkillAttemptResult[] = [];
      for (const delayMs of [0, 75]) {
        results.push(await runRapidSkillResizeAttempt(delayMs, 1));
      }

      results.push(await runRapidSkillResizeAttempt(125, 1));
      if (KEEP_LARGE_SKILL_ARTIFACTS) {
        console.log(
          `Fx rapid resize artifacts:\n${results.map(({ root }) => root).join("\n")}`,
        );
      }
    },
    RAPID_SKILL_TIMEOUT,
  );

  test(
    "gated assistant chunks remain ordered across shrink and grow",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-gated-stream-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(stderrPath, "");
      if (!KEEP_LARGE_SKILL_ARTIFACTS) tempDirs.push(root);

      const markers = [
        "GATED_RESIZE_FIRST_CHUNK",
        "GATED_RESIZE_SECOND_CHUNK",
        "GATED_RESIZE_FINAL_CHUNK",
      ] as const;
      const gated = gatedResizeResponse(
        `${markers[0]}\n`,
        `${markers[1]}\n`,
        `${markers[2]}\n`,
      );
      const gateway = startFakeGateway([gated.response]);
      gateways.push(gateway);
      writeFileSync(
        join(root, "commands.txt"),
        [
          `cwd=${workspace}`,
          `HOME=${home}`,
          `binary=${FX_BIN}`,
          "tmux_size=120x34",
          "1. submit gated assistant request",
          "2. wait for active stream",
          "3. resize 70x24 and release second chunk before settle",
          "4. resize 120x34 and wait for committed recovery",
          "5. release final chunk and assert final order",
          "",
        ].join("\n"),
      );

      session = await createResizeSession({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-gated-resize-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "frame_schedule,frame_diff,frame_commit,scroll,resize,worker",
          NO_COLOR: "1",
        },
        width: 120,
        height: 34,
        stderrPath,
        minimumHistoryLines: MINIMUM_RESIZE_HISTORY_LINES,
      });
      await session.waitForComposer(10_000);
      await session.sendText("stream across a resize");
      await session.waitForText("Thinking", 30_000);
      const activeStage = await session.captureFullScrollback();
      expect(activeStage).not.toContain(markers[0]);
      expect(activeStage).not.toContain(markers[1]);
      expect(activeStage).not.toContain(markers[2]);
      writeFileSync(join(root, "scrollback-active-stream.txt"), activeStage);

      let resizeCount = committedResizeFrameCount(tracePath);
      await session.resizeWindow(70, 24, 0);
      gated.releaseSecond();
      await session.waitForText(markers[0], 30_000);
      await waitForCommittedResizeFrame(tracePath, resizeCount);
      const shrinkStage = await session.captureFullScrollback();
      expectOrderedMarkersWithoutBlankHole(shrinkStage, markers.slice(0, 1));
      expect(shrinkStage).not.toContain(markers[1]);
      expect(shrinkStage).not.toContain(markers[2]);
      writeFileSync(join(root, "scrollback-after-shrink.txt"), shrinkStage);

      resizeCount = committedResizeFrameCount(tracePath);
      await session.resizeWindow(120, 34, 0);
      await waitForCommittedResizeFrame(tracePath, resizeCount);
      const growStage = await session.captureFullScrollback();
      expectOrderedMarkersWithoutBlankHole(growStage, markers.slice(0, 1));
      expect(growStage).not.toContain(markers[1]);
      expect(growStage).not.toContain(markers[2]);
      writeFileSync(join(root, "scrollback-after-grow.txt"), growStage);

      gated.releaseFinal();
      await session.waitForText(markers[2], 30_000);
      const finalStage = await session.captureFullScrollback();
      expectOrderedMarkersWithoutBlankHole(finalStage, markers);
      writeFileSync(join(root, "scrollback-final.txt"), finalStage);
      writeFileSync(join(root, "pane-final.txt"), `${await session.capturePane()}\n`);

      const finalGrid = await session.capturePaneGrid();
      expect(finalGrid.filter((line) => line.trim() === "┃")).toHaveLength(1);
      expect(findFooter(finalGrid)).not.toBeNull();
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(session.isPaneAlive()).toBe(true);
      expect(gateway.requests).toHaveLength(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).not.toContain("InvalidFrameScrollPlan");
      expect(trace).not.toContain("attempt_restore outcome=error");
      expect(existsSync(tapePath)).toBe(true);
      expect(readFileSync(tapePath).byteLength).toBeGreaterThan(0);
      writeFileSync(
        join(root, "manifest.json"),
        `${JSON.stringify(
          {
            markers,
            stages: [
              "scrollback-active-stream.txt",
              "scrollback-after-shrink.txt",
              "scrollback-after-grow.txt",
              "scrollback-final.txt",
            ],
            pane: session.paneStatus(),
            size: session.paneSize(),
            requestCount: gateway.requests.length,
          },
          null,
          2,
        )}\n`,
      );
      if (KEEP_LARGE_SKILL_ARTIFACTS) {
        console.log(`Fx gated stream resize artifact:\n${root}`);
      }
    },
    60_000,
  );

  test(
    "visibly open slash picker adapts across shrink and grow without losing transcript state",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-open-picker-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(stderrPath, "");
      if (!KEEP_LARGE_SKILL_ARTIFACTS) tempDirs.push(root);
      writeFileSync(
        join(root, "commands.txt"),
        [
          `cwd=${workspace}`,
          `HOME=${home}`,
          `binary=${FX_BIN}`,
          "tmux_size=120x34",
          "1. /permissions auto",
          "2. type / and assert /help selected",
          "3. resize 70x16 while picker remains open",
          "4. resize 120x34 while picker remains open",
          "5. close picker and run /permissions ask",
          "",
        ].join("\n"),
      );

      session = await createResizeSession({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "frame_schedule,frame_diff,frame_commit,scroll,resize,input",
          NO_COLOR: "1",
        },
        width: 120,
        height: 34,
        stderrPath,
        minimumHistoryLines: MINIMUM_RESIZE_HISTORY_LINES,
      });
      await session.waitForComposer(10_000);
      const beforeMarker = "mode set to auto";
      const afterMarker = "mode set to ask";
      await session.sendText("/permissions auto");
      await session.waitForText(beforeMarker, 10_000);

      await session.sendLiteral("/");
      await session.waitForText("/help", 10_000);
      await session.waitForText("/clear", 10_000);
      await waitForSelectedSlashLabel(session, "/help");
      const openStage = await waitForLiveScrollbackText(
        session,
        beforeMarker,
        10_000,
      );
      semanticMarkerRows(openStage, [beforeMarker]);
      writeFileSync(join(root, "scrollback-picker-open.txt"), openStage);

      await session.resizeWindow(70, 16, 250);
      await session.waitForText("/help", 10_000);
      await waitForSelectedSlashLabel(session, "/help");
      const shrinkStage = await session.captureFullScrollback();
      expect(shrinkStage).toContain("Commands 37 · Type to filter");
      expect(shrinkStage).toContain("1–4");
      writeFileSync(join(root, "scrollback-after-shrink.txt"), shrinkStage);

      await session.resizeWindow(120, 34, 250);
      await session.waitForText("/help", 10_000);
      await waitForSelectedSlashLabel(session, "/help");
      const growStage = await waitForLiveScrollbackText(
        session,
        beforeMarker,
        10_000,
      );
      semanticMarkerRows(growStage, [beforeMarker]);
      expect(growStage).toContain("1–6");
      writeFileSync(join(root, "scrollback-after-grow.txt"), growStage);

      await session.sendKeys("C-u");
      await session.sendText("/permissions ask");
      await session.waitForText(afterMarker, 10_000);
      const finalStage = await session.captureFullScrollback();
      const markerRows = semanticMarkerRows(finalStage, [
        beforeMarker,
        afterMarker,
      ]);
      expect(markerRows[1]).toBeGreaterThan(markerRows[0]!);
      const finalLines = finalStage.split("\n");
      const blankRows = finalLines
        .slice(markerRows[0]! + 1, markerRows[1])
        .filter((line) => line.trim().length === 0);
      expect(blankRows).toHaveLength(1);
      expect(
        finalStage
          .split("\n")
          .some((line) => line.trimStart().startsWith("/permissions")),
      ).toBe(false);
      writeFileSync(join(root, "scrollback-final.txt"), finalStage);
      writeFileSync(join(root, "pane-final.txt"), `${await session.capturePane()}\n`);

      const finalGrid = await session.capturePaneGrid();
      expect(finalGrid.filter((line) => line.trim() === "┃")).toHaveLength(1);
      expect(findFooter(finalGrid)).not.toBeNull();
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(session.isPaneAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      const trace = readFileSync(tracePath, "utf8");
      expect(trace).not.toContain("InvalidFrameScrollPlan");
      expect(trace).not.toContain("attempt_restore outcome=error");
      expect(existsSync(tapePath)).toBe(true);
      expect(readFileSync(tapePath).byteLength).toBeGreaterThan(0);
      writeFileSync(
        join(root, "manifest.json"),
        `${JSON.stringify(
          {
            markers: [beforeMarker, afterMarker],
            selected: "/help",
            stages: [
              "scrollback-picker-open.txt",
              "scrollback-after-shrink.txt",
              "scrollback-after-grow.txt",
              "scrollback-final.txt",
            ],
            pane: session.paneStatus(),
            size: session.paneSize(),
          },
          null,
          2,
        )}\n`,
      );
      if (KEEP_LARGE_SKILL_ARTIFACTS) {
        console.log(`Fx open picker resize artifact:\n${root}`);
      }
    },
    60_000,
  );

  test(
    "slash picker dismissal restores the resized short transcript boundary",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-short-picker-dismissal-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(stderrPath, "");
      tempDirs.push(root);

      session = await createResizeSession({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          NO_COLOR: "1",
        },
        width: 72,
        height: 16,
        stderrPath,
      });
      await session.waitForComposer(10_000);
      const marker = "mode set to auto";
      await session.sendText("/permissions auto");
      await session.waitForText(marker, 10_000);

      await session.resizeWindow(60, 12, 500);
      const baseline = await waitForSettledFooter(session);
      const baselineFooter = findFooter(baseline)!;

      await session.sendLiteral("/mod");
      await session.waitForText("/models", 10_000);
      await session.sendKeys("Escape");
      await session.waitForPane(
        (pane) => !pane.includes("/models"),
        10_000,
      );
      await Bun.sleep(250);

      const settled = await waitForSettledFooter(session);
      const settledFooter = findFooter(settled)!;
      expect(settledFooter).toEqual(baselineFooter);
      expect(
        settled.slice(0, settledFooter.topDivider)
          .filter((line) => line.trim().length === 0).length,
      ).toBe(
        baseline.slice(0, baselineFooter.topDivider)
          .filter((line) => line.trim().length === 0).length,
      );
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(stderrPath);
    },
    TIMEOUT,
  );

  const footerReleaseCases: Array<{
    issue: string;
    label: string;
    width: number;
    height: number;
    surfaceMarker: string;
    editedInput: string;
    fakeModels?: boolean;
    openSurface(active: TmuxSession): Promise<void>;
  }> = [
    {
      issue: "FXC-118",
      label: "statusline",
      width: 72,
      height: 16,
      surfaceMarker: "Status line",
      editedInput: "x",
      async openSurface(active) {
        await active.sendText("/statusline");
        await active.waitForText("Status line", TIMEOUT);
        await active.sendKeys("Right");
        await active.waitForText("off  on", TIMEOUT);
        await active.sendKeys("Down");
        await active.sendKeys("Right");
      },
    },
    {
      issue: "FXC-120",
      label: "help",
      width: 72,
      height: 16,
      surfaceMarker: "Commands ",
      editedInput: "x",
      async openSurface(active) {
        await active.resizeWindow(60, 12, 500);
        await active.sendText("/help");
        await active.waitForText("Commands ", TIMEOUT);
      },
    },
    {
      issue: "FXC-125",
      label: "cost",
      width: 120,
      height: 36,
      surfaceMarker: "Usage · 30 days",
      editedInput: "x",
      async openSurface(active) {
        await active.sendText("/cost");
        await active.waitForText("Usage · 30 days", TIMEOUT);
        await active.resizeWindow(60, 12, 500);
      },
    },
    {
      issue: "FXC-126",
      label: "model",
      width: 120,
      height: 36,
      surfaceMarker: "provider/model-a",
      editedInput: "/model x",
      fakeModels: true,
      async openSurface(active) {
        await active.sendText("/model");
        await active.waitForText("provider/model-a", TIMEOUT);
        await active.resizeWindow(60, 12, 500);
      },
    },
    {
      issue: "FXC-127",
      label: "workspace",
      width: 120,
      height: 36,
      surfaceMarker: "Workspace:",
      editedInput: "x",
      async openSurface(active) {
        await active.sendText("/workspace");
        await active.waitForText("Workspace:", TIMEOUT);
        await active.resizeWindow(60, 12, 500);
      },
    },
    {
      issue: "FXC-129",
      label: "file completion",
      width: 120,
      height: 36,
      surfaceMarker: "AGENTS.md",
      editedInput: "@AGx",
      async openSurface(active) {
        await active.sendLiteral("@AG");
        await active.waitForText("AGENTS.md", TIMEOUT);
        await active.resizeWindow(60, 12, 500);
      },
    },
  ];

  for (const surfaceCase of footerReleaseCases) {
    test(
      `${surfaceCase.issue} ${surfaceCase.label} release does not wait for the next edit to reflow`,
      async () => {
        const gateway = surfaceCase.fakeModels
          ? startFakeGateway([], {
              models: [{
                id: "provider/model-a",
                type: "language",
                released: 1,
                tags: ["tool-use"],
              }],
            })
          : null;
        if (gateway) gateways.push(gateway);
        const fixture = await launchRecordedSurfaceSession(
          surfaceCase.label.replaceAll(" ", "-"),
          surfaceCase.width,
          surfaceCase.height,
          gateway
            ? {
                FX_E2E_GATEWAY_MODELS_URL:
                  `${gateway.baseUrl}/coding-agent/v1/models`,
              }
            : {},
        );
        session = fixture.active;
        await surfaceCase.openSurface(session);

        await session.sendKeys("Escape");
        await session.waitForPane(
          (pane) => !pane.includes(surfaceCase.surfaceMarker),
          TIMEOUT,
        );
        await Bun.sleep(250);
        const releasedGrid = await waitForSettledFooter(session);
        const releasedFooter = findFooter(releasedGrid)!;

        await session.sendLiteral("x");
        await session.waitForPane(
          (pane) =>
            pane.split("\n").some((line) =>
              isInputRow(line) && line.includes(surfaceCase.editedInput)
            ),
          TIMEOUT,
        );
        await Bun.sleep(150);
        const editedGrid = await waitForSettledFooter(session);
        const editedFooter = findFooter(editedGrid)!;

        expect(releasedFooter).toEqual(editedFooter);
        expect(session.paneStatus()).toEqual({ dead: false, status: null });
        expect(session.isPaneAlive()).toBe(true);
        expectEmptyStderr(fixture.stderrPath);
      },
      45_000,
    );
  }

  test(
    "FXC-122 workspace Add handoff suppresses only its synthetic completion row",
    async () => {
      const fixture = await launchRecordedSurfaceSession(
        "workspace-add",
        120,
        36,
      );
      session = fixture.active;
      await session.sendText("/workspace");
      await session.waitForText("Workspace:", TIMEOUT);
      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) =>
          pane.split("\n").some((line) =>
            isInputRow(line) && line.includes("/workspace add")
          ),
        TIMEOUT,
      );
      await Bun.sleep(150);
      const handoffGrid = await session.capturePaneGrid();
      expect(handoffGrid.some((line) => line.trim() === "add")).toBe(false);

      await session.sendKeys("C-u");
      await session.sendLiteral("/workspace add ");
      await session.waitForPane(
        (pane) => pane.split("\n").some((line) => line.trim() === "add"),
        TIMEOUT,
      );
      const directGrid = await session.capturePaneGrid();
      expect(directGrid.some((line) => line.trim() === "add")).toBe(true);
      await session.sendKeys("Escape");
      await session.waitForPane(
        (pane) =>
          pane.split("\n").every((line) => line.trim() !== "add") &&
          pane.split("\n").some((line) =>
            isInputRow(line) && line.includes("/workspace add")
          ),
        TIMEOUT,
      );
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(fixture.stderrPath);
    },
    45_000,
  );

  test(
    "wide user card survives resize without splitting a terminal cell",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-wide-user-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const tapePath = join(root, "session.fxtape");
      const panePath = join(root, "pane-final.txt");
      const scrollbackPath = join(root, "scrollback-final.txt");
      const statusPath = join(root, "pane-status.json");
      mkdirSync(home, { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(stderrPath, "");
      writeFileSync(
        join(root, "commands.txt"),
        [
          `cwd=${workspace}`,
          `HOME=${home}`,
          `binary=${FX_BIN}`,
          "tmux_size=80x24",
          "resize=40x18",
          "prompt=34 ASCII cells + U+754C + U+1F642",
          "",
        ].join("\n"),
      );
      if (!KEEP_LARGE_SKILL_ARTIFACTS) tempDirs.push(root);

      const response = "wide user resize response complete";
      const prompt = `${"a".repeat(34)}界🙂`;
      const gateway = startFakeGateway([
        fakeGatewayFinalText(response),
      ]);
      gateways.push(gateway);
      session = await createResizeSession({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-wide-user-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "render,resize,transcript,input,worker",
          TMUX: undefined,
        },
        width: 80,
        height: 24,
        stderrPath,
        remainOnExit: true,
        minimumHistoryLines: 1_000,
      });
      await session.waitForComposer(10_000);
      await session.resizeWindow(40, 18, 500);
      await session.sendLiteral(prompt);
      await session.sendKeys("Enter");
      const scrollback = await waitForLiveScrollbackText(
        session,
        response,
        30_000,
      );

      const pane = await session.capturePane();
      const status = session.paneStatus();
      writeFileSync(panePath, `${pane}\n`);
      writeFileSync(scrollbackPath, scrollback);
      writeFileSync(
        statusPath,
        `${JSON.stringify(
          {
            pane: status,
            size: session.paneSize(),
            alive: session.isPaneAlive(),
          },
          null,
          2,
        )}\n`,
      );

      expect(status).toEqual({ dead: false, status: null });
      expect(session.isPaneAlive()).toBe(true);
      expect(scrollback).toContain(response);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(readFileSync(tracePath, "utf8")).not.toContain(
        "WideCellInvariantViolation",
      );
      expect(existsSync(tapePath)).toBe(true);
      expect(readFileSync(tapePath).byteLength).toBeGreaterThan(0);
      if (KEEP_LARGE_SKILL_ARTIFACTS) {
        console.log(`Fx wide-user resize artifact:\n${root}`);
      }
    },
    TIMEOUT,
  );

  test(
    "shrink: footer block is well-formed at new size",
    async () => {
      session = await launchAt(120, 40);
      await session.resizeWindow(60, 20);

      const grid = await session.capturePaneGrid();
      expect(grid.length).toBeGreaterThan(0);
      const footer = findFooter(grid);
      expect(footer).not.toBeNull();
      expect(isInputRow(grid[footer!.input]!)).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "height shrink: footer block remains well-formed",
    async () => {
      session = await launchAt(100, 40);
      await session.resizeWindow(100, 18);

      const grid = await session.capturePaneGrid();
      expect(grid.length).toBeGreaterThan(0);
      expect(findFooterBlocks(grid)).toHaveLength(1);
    },
    TIMEOUT,
  );

  test(
    "typed input survives a shrink and stays visible",
    async () => {
      session = await launchAt(120, 40);
      await session.sendKeys("-l 'resize-marker-alpha'");
      await new Promise((r) => setTimeout(r, 200));
      await session.resizeWindow(80, 30);

      const grid = await session.capturePaneGrid();
      const combined = grid.join("\n");
      expect(combined).toContain("resize-marker-alpha");
      expect(findFooter(grid)).not.toBeNull();
    },
    TIMEOUT,
  );

  test(
    "active multiline footer survives resize",
    async () => {
      session = await launchAt(120, 40);
      await session.sendKeys("-l 'resize-footer-alpha resize-footer-beta resize-footer-gamma resize-footer-delta resize-footer-epsilon'");
      await new Promise((r) => setTimeout(r, 200));
      await session.resizeWindow(70, 24);

      const grid = await session.capturePaneGrid();
      const combined = grid.join("\n");
      expect(combined).toContain("resize-footer");
      expect(findFooterBlocks(grid)).toHaveLength(1);
    },
    TIMEOUT,
  );

  test(
    "active hard-newline input survives tiny valid resize",
    async () => {
      const stderrPath = createStderrPath("active-hard");
      const first = "FX_HARD_ROW_ALPHA";
      const second = "FX_HARD_ROW_BETA";
      session = await launchAt(80, 24, { stderrPath });
      await enterHardNewlineInput(session, first, second);

      await session.resizeWindow(8, 6, 500);

      expect(session.paneStatus().dead).toBe(false);
      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(stderrPath);
      await recoverActiveInput(session, [first, second]);
    },
    TIMEOUT,
  );

  test(
    "active soft-wrapped input survives tiny valid resize",
    async () => {
      const stderrPath = createStderrPath("active-soft");
      const first = "FX_SOFT_START";
      const second = "FX_SOFT_END";
      const input = `${first} ${"filler ".repeat(16)}${second}`;
      session = await launchAt(80, 24, { stderrPath });
      await session.sendLiteral(input);
      await waitForMarkersOnDistinctRows(session, first, second);

      await session.resizeWindow(8, 6, 500);

      expect(session.paneStatus().dead).toBe(false);
      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(stderrPath);
      await recoverActiveInput(session, [first, second]);
    },
    TIMEOUT,
  );

  test(
    "active hard-newline input follows height-four recovery",
    async () => {
      const stderrPath = createStderrPath("active-height-four");
      const first = "FX_HARD_4_ROW_ALPHA";
      const second = "FX_HARD_4_ROW_BETA";
      session = await launchAt(80, 24, { stderrPath });
      await enterHardNewlineInput(session, first, second);

      await session.resizeWindow(8, 4, 500);

      expect(session.paneStatus().dead).toBe(false);
      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(stderrPath);
      await recoverActiveInput(session, [first, second]);
    },
    TIMEOUT,
  );

  test(
    "active hard-newline input renders normally at height nine",
    async () => {
      const stderrPath = createStderrPath("active-height-nine");
      const first = "FX_HARD_9_ROW_ALPHA";
      const second = "FX_HARD_9_ROW_BETA";
      session = await launchAt(80, 24, { stderrPath });
      await enterHardNewlineInput(session, first, second);

      await session.resizeWindow(8, 9, 500);

      expect(session.paneStatus().dead).toBe(false);
      expect(session.isPaneAlive()).toBe(true);
      const tinyGrid = await session.capturePaneGrid();
      expect(tinyGrid.some(isInputRow)).toBe(true);
      expectEmptyStderr(stderrPath);
      await recoverActiveInput(session, [first, second]);
    },
    TIMEOUT,
  );

  test(
    "active file approval keeps canonical copy and selection across resize",
    async () => {
      const root = createFileApprovalRoot();
      const gateway = startFileApprovalGateway();
      const stderrPath = join(root.root, "stderr.txt");
      const tapePath = join(root.root, "active-file-approval.fxtape");
      writeFileSync(stderrPath, "");
      session = await createResizeSession({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: {
          HOME: root.home,
          AI_GATEWAY_API_KEY: "fake-resize-file-approval-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_RECORD: tapePath,
          NO_COLOR: "1",
        },
        stderrPath,
        width: 80,
        height: 24,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Create the resize fixture.");
      await session.waitForText(FILE_APPROVAL_QUESTION, TIMEOUT);
      let fullBlock = findActiveFileApprovalBlock(
        await session.capturePaneGrid(),
      );
      expect(fullBlock).not.toBeNull();
      expect(fullBlock!.text).toContain("Permission needed · Review change");
      expect(fullBlock!.text).toContain("Write · +9  -0");
      expect(fullBlock!.text).toContain("resize-approved.txt");
      expect(fullBlock!.text).toContain("Apply once");
      expect(fullBlock!.text).toContain(
        "Apply + allow workspace file access for this session",
      );
      expect(fullBlock!.text).toContain("Don't apply");
      expect(fullBlock!.text).toContain("+ preview-nine");
      await session.sendKeys("Right");
      await session.sendKeys("Right");

      await session.resizeWindow(80, 6, 500);
      let pane = await session.waitForText("❯ 3  Don't apply", 5_000);
      expect(pane).toContain("1  Apply once");
      expect(pane).toContain(
        "2  Apply + allow workspace file access for this session",
      );
      expect(pane).not.toContain(FILE_APPROVAL_QUESTION);

      await session.resizeWindow(80, 8, 500);
      pane = await session.waitForText(FILE_APPROVAL_QUESTION, 5_000);
      expect(pane).toContain("resize-approved.txt");
      expect(pane).toContain("❯ 3  Don't apply");
      expect(pane).toContain("1  Apply once");
      expect(pane).toContain(
        "2  Apply + allow workspace file access for this session",
      );
      expect(pane).not.toContain("1Y");
      expect(pane).not.toContain("2A");
      expect(pane).not.toContain("3N");

      for (const height of [9, 11, 13]) {
        await session.resizeWindow(80, height, 500);
        pane = await session.waitForText("❯ 3  Don't apply", 5_000);
        expect(pane).toContain("Apply once");
        expect(pane).toContain(
          "Apply + allow workspace file access for this session",
        );
        expect(pane).not.toContain("1Y");
        expect(pane).not.toContain("2A");
        expect(pane).not.toContain("3N");
      }

      await session.resizeWindow(80, 17, 500);
      pane = await session.waitForText("1–3 Choose", 5_000);
      expect(pane).toContain(FILE_APPROVAL_QUESTION);
      expect(pane).toContain("resize-approved.txt");
      expect(pane).toContain("+ preview-nine");
      expect(pane).toContain("Wheel Scroll");
      expect(pane).not.toContain("omitted");
      fullBlock = findActiveFileApprovalBlock(await session.capturePaneGrid());
      expect(fullBlock).not.toBeNull();
      expect(
        fullBlock!.lines.filter((row) => row.includes("❯ 3  Don't apply")),
      ).toHaveLength(1);

      for (let index = 0; index < 2; index++) {
        await session.sendHexBytes([
          "1b", "5b", "3c", "36", "34", "3b", "31", "3b", "31", "4d",
        ]);
      }
      pane = await session.waitForText("+ preview-one", 5_000);
      expect(pane).toContain(FILE_APPROVAL_QUESTION);
      expect(pane).not.toContain("❯ 3  Don't apply");

      await session.resizeWindow(70, 17, 500);
      pane = await session.waitForText("+ preview-one", 5_000);
      expect(pane).toContain(FILE_APPROVAL_QUESTION);
      expect(pane).not.toContain("❯ 3  Don't apply");
      const approvalFrames = Buffer.concat(
        stdoutFrames(tapePath).map((frame) => frame.payload),
      ).toString();
      expect(countOccurrences(approvalFrames, "\x1b[?1049h")).toBe(1);
      expect(countOccurrences(approvalFrames, "\x1b[?1049l")).toBe(0);

      await session.sendKeys("Enter");
      await session.waitForText("resize denial complete", TIMEOUT);

      const resolvedFrames = Buffer.concat(
        stdoutFrames(tapePath).map((frame) => frame.payload),
      ).toString();
      expect(countOccurrences(resolvedFrames, "\x1b[?1049h")).toBe(1);
      expect(countOccurrences(resolvedFrames, "\x1b[?1049l")).toBe(1);

      expect(existsSync(join(root.workspace, "resize-approved.txt"))).toBe(false);
      expectEmptyStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "file approval affirmative enter waits for the resized frame to commit",
    async () => {
      const root = createFileApprovalRoot();
      const target = join(root.workspace, "resize-gated.txt");
      const content = [
        "gate-one",
        "gate-two",
        "gate-three",
        "gate-four",
        "gate-five",
        "gate-six",
        "gate-seven",
        "",
      ].join("\n");
      const gateway = startFakeGateway([
        fakeGatewayToolCall("resize_gate_1", "write_file", {
          path: "resize-gated.txt",
          content,
        }),
        fakeGatewayFinalText("resize approval complete"),
      ]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "resize-gated-stderr.txt");
      writeFileSync(stderrPath, "");
      session = await createResizeSession({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: {
          HOME: root.home,
          AI_GATEWAY_API_KEY: "fake-resize-gate-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          NO_COLOR: "1",
        },
        stderrPath,
        width: 80,
        height: 24,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Create the resize-gated fixture.");
      await session.waitForText(FILE_APPROVAL_QUESTION, TIMEOUT);

      await session.resizeWindow(80, 6, 500);
      let pane = await session.waitForText(
        "❯ ! 1  Apply once · resize to review",
        5_000,
      );
      await session.sendKeys("Enter");
      await new Promise((resolve) => setTimeout(resolve, 300));
      pane = await session.capturePane();
      expect(pane).toContain("❯ ! 1  Apply once · resize to review");
      expect(existsSync(target)).toBe(false);

      execFileSync("tmux", [
        "resize-window",
        "-t",
        session.name,
        "-x",
        "80",
        "-y",
        "8",
        ";",
        "send-keys",
        "-t",
        session.name,
        "Enter",
      ]);
      await new Promise((resolve) => setTimeout(resolve, 300));
      pane = await session.capturePane();
      expect(existsSync(target)).toBe(false);
      expect(pane).toContain(FILE_APPROVAL_QUESTION);
      expect(pane).toContain("❯ 1  Apply once");

      pane = await session.waitForText(FILE_APPROVAL_QUESTION, 5_000);
      await session.sendKeys("Enter");
      await session.waitForText("resize approval complete", TIMEOUT);

      expect(readFileSync(target, "utf8")).toBe(content);
      expectEmptyStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "file approval commits a later resize after affirmative acceptance",
    async () => {
      const root = createFileApprovalRoot();
      const target = join(root.workspace, "resize-after-approval.txt");
      const content = "accepted-before-resize\n";
      let releaseFinalResponse!: () => void;
      const finalResponseReady = new Promise<void>((resolve) => {
        releaseFinalResponse = () => resolve();
      });
      const gateway = startFakeGateway([
        fakeGatewayToolCall("resize_after_approval_1", "write_file", {
          path: "resize-after-approval.txt",
          content,
        }),
        async () => {
          await finalResponseReady;
          return fakeGatewayFinalText("post-approval resize complete");
        },
      ]);
      gateways.push(gateway);
      const stderrPath = join(root.root, "resize-after-approval-stderr.txt");
      const tracePath = join(root.root, "resize-after-approval-trace.log");
      writeFileSync(stderrPath, "");
      session = await createResizeSession({
        cmd: FX_BIN,
        cwd: root.workspace,
        env: {
          HOME: root.home,
          AI_GATEWAY_API_KEY: "fake-post-approval-resize-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "frame_schedule",
          NO_COLOR: "1",
        },
        stderrPath,
        width: 80,
        height: 24,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Create the post-approval resize fixture.");
      await session.waitForText(FILE_APPROVAL_QUESTION, TIMEOUT);
      await session.sendKeys("Enter");
      await waitForGatewayRequestCount(gateway, 2);

      expect(readFileSync(target, "utf8")).toBe(content);
      const resizeFramesBefore = committedResizeFrameCount(tracePath);

      await session.resizeWindow(60, 18, 500);
      await waitForCommittedResizeFrame(tracePath, resizeFramesBefore);

      expect(session.paneSize()).toEqual({ cols: 60, rows: 18 });
      expect(session.paneStatus().dead).toBe(false);
      expect(session.isPaneAlive()).toBe(true);
      const grid = await session.capturePaneGrid();
      expect(grid.join("\n")).toContain("┃ Create the post-approval resize fixture.");
      expect(grid.join("\n")).not.toContain(FILE_APPROVAL_QUESTION);

      releaseFinalResponse();
      await session.waitForText("post-approval resize complete", TIMEOUT);

      expect(readFileSync(target, "utf8")).toBe(content);
      expectEmptyStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "active activity survives resize",
    async () => {
      const gated = gatedResizeResponse(
        "resize_activity_started\n",
        "resize_activity_continued\n",
        "resize_activity_done\n",
      );
      const gateway = startFakeGateway([gated.response]);
      gateways.push(gateway);
      const launched = await launchRecordedSurfaceSession(
        "active-activity",
        120,
        40,
        {
          AI_GATEWAY_API_KEY: "fake-resize-activity-key",
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_E2E_GATEWAY_CREDITS_URL: undefined,
          FX_MODEL: FAKE_GATEWAY_MODEL,
        },
      );
      session = launched.active;
      await session.sendText("Reply with exactly resize_activity_done.");
      await waitForGatewayRequestCount(gateway, 1);
      await session.waitForText("Thinking", TIMEOUT);
      await session.resizeWindow(90, 30, 500);

      const grid = await waitForSettledFooter(session);
      expect(session.isAlive()).toBe(true);
      expect(findFooter(grid)).not.toBeNull();
      expect(gateway.requests).toHaveLength(1);

      gated.releaseSecond();
      gated.releaseFinal();
      await session.waitForText("resize_activity_done", TIMEOUT);
      expectEmptyStderr(launched.stderrPath);
    },
    90_000,
  );

  test(
    "resize keeps the current composer at the new terminal width",
    async () => {
      session = await launchAt(120, 40);
      await session.resizeWindow(80, 30);
      await new Promise((r) => setTimeout(r, 300));

      const grid = await session.capturePaneGrid();
      expect(session.paneSize()).toEqual({ cols: 80, rows: 30 });
      const footer = findFooter(grid);
      expect(footer).not.toBeNull();
      expect(grid[footer!.input]).toBe("┃");
    },
    TIMEOUT,
  );

  test(
    "resize does not leave stale divider lines from the old size",
    async () => {
      session = await launchAt(120, 40);
      await session.resizeWindow(80, 30);
      await new Promise((r) => setTimeout(r, 300));

      const grid = await session.capturePaneGrid();
      const dividerWidths = grid.filter(isDividerRow).map((line) => line.length);
      expect(dividerWidths.length).toBeLessThanOrEqual(3);
      for (const w of dividerWidths) {
        expect(w).toBeGreaterThanOrEqual(60);
        expect(w).toBeLessThanOrEqual(80);
      }
    },
    TIMEOUT,
  );

  test(
    "resize below footer_rows does not crash the app",
    async () => {
      session = await launchAt(120, 40);
      await session.sendKeys("invalid-dim-recovery");
      await session.resizeWindow(40, 3, 400);
      expect(session.isAlive()).toBe(true);

      await session.resizeWindow(100, 30, 500);
      const grid = await session.capturePaneGrid();
      expect(grid.join("\n")).toContain("invalid-dim-recovery");
      expect(findFooterBlocks(grid)).toHaveLength(1);
    },
    TIMEOUT,
  );

  test(
    "rapid resize storm settles into exactly one footer",
    async () => {
      session = await launchAt(120, 40);
      await session.resizeWindow(110, 38, 20);
      await session.resizeWindow(100, 36, 20);
      await session.resizeWindow(90, 34, 20);
      await session.resizeWindow(80, 32, 400);

      expect(session.isAlive()).toBe(true);
      const grid = await waitForSettledFooter(session);
      expect(findFooterBlocks(grid)).toHaveLength(1);
    },
    TIMEOUT,
  );

  test(
    "/help remains usable after resize and /quit exits",
    async () => {
      session = await launchAt(120, 40);
      await session.sendText("/help");
      await session.waitForText("Commands 37", 5_000);
      await session.resizeWindow(76, 24, 400);

      const grid = await session.capturePaneGrid();
      expect(grid.join("\n")).toContain("Commands 37");
      expect(findHelpScreen(grid)).not.toBeNull();

      await session.sendKeys("Escape");
      await session.waitForPane((pane) => !pane.includes("Enter Open"), 5_000);
      await session.waitForStableComposer(5_000);
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(5_000)).toBe(true);
      session = null;
    },
    TIMEOUT,
  );

  test(
    "resize replay keeps one startup banner in full scrollback",
    async () => {
      session = await launchAt(120, 40);
      await session.sendText("/help");
      await session.waitForText("Commands 37", 5_000);

      const captureScrollback = () =>
        execSync(`tmux capture-pane -t ${session!.name} -p -S -`, {
          encoding: "utf8",
          stdio: "pipe",
        });
      const expectHelpCatalog = (grid: string[]) => {
        expect(grid.join("\n")).toContain("Commands 37");
        expect(grid.join("\n")).not.toContain("Run /help for commands");
        expect(findHelpScreen(grid)).not.toBeNull();
      };

      await session.resizeWindow(72, 20, 500);
      expectHelpCatalog(await session.capturePaneGrid());

      await session.resizeWindow(140, 45, 500);
      expectHelpCatalog(await session.capturePaneGrid());

      await session.sendKeys("Escape");
      await session.waitForText("Run /help for commands", 5_000);
      const restored = captureScrollback();
      expect(restored.match(/𝒇x v\d+\.\d+\.\d+\b/g)).toHaveLength(1);
      expect(restored.match(/Run \/help for commands/g)).toHaveLength(1);
      expect(restored).not.toContain("Commands 37");
      expect(findFooter(await session.capturePaneGrid())).not.toBeNull();
    },
    TIMEOUT,
  );

  test(
    "grow with immediate input retains pre-paint resize reconciliation",
    async () => {
      const root = realpathSync(
        mkdtempSync(join(tmpdir(), "fx-resize-prepaint-input-")),
      );
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tracePath = join(root, "trace.log");
      const tapePath = join(root, "session.fxtape");
      const replayDir = join(root, "replay");
      const preFxMarker = "PRE_FX_RESIZE_PREPAINT_7319";
      const firstMarker = "RESIZE_PREPAINT_TURN_A_COMPLETE";
      const secondMarker = "RESIZE_PREPAINT_TURN_B_COMPLETE";
      const launchCommand =
        `printf ${quoteShellPath(`${preFxMarker}\n`)}; exec ${quoteShellPath(FX_BIN)}`;
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      tempDirs.push(root);
      const gateway = startFakeGateway([
        fakeGatewayFinalText(
          `${"alpha response wraps across the medium terminal width ".repeat(5)}${firstMarker}`,
        ),
        fakeGatewayFinalText(
          `${"beta response also wraps across the medium terminal width ".repeat(5)}${secondMarker}`,
        ),
      ]);
      gateways.push(gateway);

      session = await createResizeSession({
        cmd: `/bin/sh -c ${quoteShellPath(launchCommand)}`,
        cwd: workspace,
        width: 80,
        height: 24,
        stderrPath,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "test-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_RECORD: tapePath,
          FX_RECORD_INPUT: "1",
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES:
            "frame_schedule,frame_plan,frame_diff,frame_commit,scroll,resize,input,worker",
          NO_COLOR: "1",
        },
      });
      await session.waitForComposer(10_000);

      await session.sendText(
        "first medium width turn with enough words to wrap the user card before resize",
      );
      await session.waitForText(firstMarker, TIMEOUT);
      await session.sendText(
        "second medium width turn with enough words to wrap the user card before resize",
      );
      await session.waitForText(secondMarker, TIMEOUT);
      await waitForGatewayRequestCount(gateway, 2);

      const beforeResizeLine = readTraceLines(tracePath).length - 1;
      const beforeResizeFrame = readTapeFrames(tapePath).length;
      const paneTty = execFileSync(
        "tmux",
        ["display-message", "-p", "-t", session.name, "#{pane_tty}"],
        { encoding: "utf8", stdio: "pipe" },
      ).trim();
      // Drift the terminal position without updating fx's shadow grid. Tmux
      // can then answer the resize probe while reconciliation is still blocked.
      writeFileSync(paneTty, "\x1b[3A");
      await session.resizeWindow(120, 40, 0);
      execFileSync("tmux", ["send-keys", "-t", session.name, "-l", "x"], {
        stdio: "pipe",
      });

      const resizeCycle = await waitForResizeCycle(
        tracePath,
        beforeResizeLine,
        (cycle) =>
          cycle.newSize.cols === 120 &&
          cycle.newSize.rows === 40 &&
          cycle.historyRowDelta !== 0,
        60_000,
      );
      expect(resizeCycle.historyRowDelta).not.toBe(0);
      const requestLine = readTraceLines(tracePath).find(
        (line, index) =>
          index > beforeResizeLine &&
          line.includes("cursor_measure_requested protocol=ansi_tagged"),
      );
      expect(requestLine).toBeDefined();
      expect(signedTraceField(requestLine!, "expected_reflow_row"))
        .toBeGreaterThan(3);
      await waitForTraceText(tracePath, "settled_reset_committed");
      const finalGrid = await session.capturePaneGrid();
      const finalFooter = findFooter(finalGrid);
      expect(finalFooter).not.toBeNull();
      expect(finalGrid[finalFooter!.input]).toContain("┃ x");

      const resizeLines = readTraceLines(tracePath);
      const signalIndex = resizeLines.findIndex(
        (line, index) =>
          index >= beforeResizeLine && line.includes("resize_block begin"),
      );
      const queryIndex = resizeLines.findIndex(
        (line, index) =>
          index > signalIndex && line.includes("cursor_measure_requested"),
      );
      const liveApplyIndex = resizeLines.findIndex(
        (line, index) =>
          index > queryIndex &&
          line.includes("[resize] apply ") &&
          line.includes("settled=false"),
      );
      expect(signalIndex).toBeGreaterThanOrEqual(beforeResizeLine);
      expect(queryIndex).toBeGreaterThan(signalIndex);
      expect(liveApplyIndex).toBeGreaterThan(queryIndex);
      expect(
        resizeLines
          .slice(signalIndex + 1, liveApplyIndex)
          .some((line) => line.includes("attempt_end outcome=committed")),
      ).toBe(false);

      const resizeTapeFrames = await waitForResizeAndInputTapeFrames(
        tapePath,
        beforeResizeFrame,
        Buffer.from("x"),
      );
      const resizeFrameIndex = resizeTapeFrames.findIndex((frame) => frame.kind === 3);
      const inputFrameIndex = resizeTapeFrames.findIndex(
        (frame) => frame.kind === 2 && frame.payload.includes(Buffer.from("x")),
      );
      expect(resizeFrameIndex).toBeGreaterThanOrEqual(0);
      expect(inputFrameIndex).toBeGreaterThanOrEqual(0);

      execFileSync(FX_BIN, ["replay", tapePath, "--frames-dir", replayDir], {
        cwd: workspace,
        stdio: "pipe",
      });
      const gridPaths = readdirSync(join(replayDir, "frames"))
        .filter((name) => name.endsWith(".grid.txt"))
        .sort()
        .map((name) => join(replayDir, "frames", name));
      const replayFrames = gridPaths.map((gridPath) => ({
        grid: readFileSync(gridPath, "utf8"),
        metadata: JSON.parse(
          readFileSync(gridPath.replace(".grid.txt", ".json"), "utf8"),
        ) as {
          cursor: { row: number; col: number; visible: boolean };
          footer_candidates: Array<{ input: number }>;
        },
      }));
      const firstInputFrame = replayFrames.find(
        (frame) =>
          frame.grid.includes("┃ x") && frame.metadata.cursor.visible,
      );
      const finalFooterFrame = replayFrames.findLast(
        (frame) => frame.metadata.cursor.visible,
      );
      expect(firstInputFrame).toBeDefined();
      expect(finalFooterFrame).toBeDefined();
      expect(firstInputFrame!.metadata.cursor.row).toBe(
        finalFooterFrame!.metadata.cursor.row,
      );
      expect(finalFooterFrame!.metadata.cursor.row).toBe(finalFooter!.input + 1);

      const visibleViewport = finalGrid.join("\n");
      expect(countOccurrences(visibleViewport, firstMarker)).toBe(1);
      expect(countOccurrences(visibleViewport, secondMarker)).toBe(1);
      expect(countOccurrences(visibleViewport, "┃ x")).toBe(1);
      expect(visibleViewport).not.toContain(preFxMarker);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(session.isPaneAlive()).toBe(true);
      expectEmptyStderr(stderrPath);
    },
    90_000,
  );

  test(
    "settled resize preserves a multi-megabyte bracketed paste byte-for-byte",
    async () => {
      const dir = mkdtempSync(join(tmpdir(), "fx-resize-large-paste-"));
      tempDirs.push(dir);
      const tracePath = join(dir, "trace.log");
      const stderrPath = join(dir, "stderr.log");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("large paste resize complete"),
      ]);
      gateways.push(gateway);

      session = await createResizeSession({
        width: 120,
        height: 40,
        stderrPath,
        env: {
          AI_GATEWAY_API_KEY: "test-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "input,worker,resize",
        },
      });
      await session.waitForComposer(10_000);

      await session.sendHexBytes(["1b", "5b", "32", "30", "30", "7e"]);
      const payload = "x".repeat(5_000_000);
      const buffer = `${session.name}-large-paste`;
      execFileSync("tmux", ["load-buffer", "-b", buffer, "-"], {
        input: payload,
        stdio: ["pipe", "pipe", "pipe"],
      });
      execFileSync("tmux", [
        "paste-buffer",
        ...tmuxRawPasteFlags(),
        "-d",
        "-b",
        buffer,
        "-t",
        session.name,
      ]);

      await session.resizeWindow(90, 28, 500);
      await session.sendHexBytes(["1b", "5b", "32", "30", "31", "7e"]);
      await waitForTraceText(
        tracePath,
        `paste end owner=composer bytes=${payload.length}`,
        60_000,
      );
      await session.sendKeys("Enter");

      expect(await waitForQueuedPromptBytes(tracePath, 60_000)).toBe(
        payload.length,
      );
      expectEmptyStderr(stderrPath);
    },
    90_000,
  );

  test(
    "tmux resize preserves column-one CPR-shaped paste bytes in the submitted prompt",
    async () => {
      const dir = mkdtempSync(join(tmpdir(), "fx-resize-cpr-paste-"));
      tempDirs.push(dir);
      const tracePath = join(dir, "trace.log");
      const stderrPath = join(dir, "stderr.log");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("CPR-shaped paste resize complete"),
      ]);
      gateways.push(gateway);

      session = await createResizeSession({
        width: 120,
        height: 40,
        stderrPath,
        env: {
          AI_GATEWAY_API_KEY: "test-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "input,worker,resize",
        },
      });
      await session.waitForComposer(10_000);

      await session.sendHexBytes(["1b", "5b", "32", "30", "30", "7e"]);
      await waitForTraceText(tracePath, "paste begin owner=composer");
      await session.resizeWindow(90, 28, 0);
      const targetBytes = 5_000_000;
      const cprPattern = "\x1b[1;1R";
      const patternBytes = Buffer.byteLength(cprPattern);
      const rawPayload =
        cprPattern.repeat(Math.floor(targetBytes / patternBytes)) +
        "x".repeat(targetBytes % patternBytes);
      const expectedPrompt = rawPayload.replaceAll("\x1b", "");
      expect(Buffer.byteLength(rawPayload)).toBe(targetBytes);

      const buffer = `${session.name}-cpr-paste`;
      execFileSync("tmux", ["load-buffer", "-b", buffer, "-"], {
        input: rawPayload,
        stdio: ["pipe", "pipe", "pipe"],
      });
      execFileSync("tmux", [
        "paste-buffer",
        ...tmuxRawPasteFlags(),
        "-d",
        "-b",
        buffer,
        "-t",
        session.name,
      ]);

      await session.sendHexBytes(["1b", "5b", "32", "30", "31", "7e"]);
      const completedPasteTrace = await waitForTraceText(
        tracePath,
        `paste end owner=composer bytes=${Buffer.byteLength(expectedPrompt)}`,
        60_000,
      );
      const pasteEndIndex = completedPasteTrace.indexOf(
        "paste end owner=composer",
      );
      expect(completedPasteTrace.slice(0, pasteEndIndex)).not.toContain(
        "cursor_measure_requested",
      );
      await session.sendKeys("Enter");

      await waitForTraceText(
        tracePath,
        "cursor_measure_requested protocol=ansi_tagged",
      );
      expect(await waitForQueuedPromptBytes(tracePath, 60_000)).toBe(
        Buffer.byteLength(expectedPrompt),
      );
      expect(
        await waitForSubmittedUserText(gateway, tracePath, stderrPath),
      ).toBe(expectedPrompt);
      expectEmptyStderr(stderrPath);
    },
    90_000,
  );

  test(
    "probe-first resize keeps a terminal reply paste-owned",
    async () => {
      const dir = mkdtempSync(join(tmpdir(), "fx-resize-cpr-paste-late-"));
      tempDirs.push(dir);
      const tracePath = join(dir, "trace.log");
      const stderrPath = join(dir, "stderr.log");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("Late CPR-shaped paste resize complete"),
      ]);
      gateways.push(gateway);

      session = await createResizeSession({
        width: 120,
        height: 40,
        stderrPath,
        env: {
          AI_GATEWAY_API_KEY: "test-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "input,worker,resize",
          TMUX: undefined,
        },
      });
      await session.waitForComposer(10_000);

      const traceStartByte = existsSync(tracePath)
        ? readFileSync(tracePath).byteLength + 1
        : 1;
      const pasteStartInjector = Bun.spawn([
        "/bin/sh",
        "-c",
        [
          "needle=$1; trace=$2; target=$3; offset=$4; shift 4",
          "attempt=0",
          "until tail -c +\"$offset\" \"$trace\" 2>/dev/null | grep -Fq -- \"$needle\"; do",
          "  attempt=$((attempt + 1))",
          "  [ \"$attempt\" -ge 2000 ] && exit 124",
          "  sleep 0.005",
          "done",
          "exec tmux send-keys -t \"$target\" -H \"$@\"",
        ].join("\n"),
        "inject-paste-start",
        "cursor_measure_requested protocol=private",
        tracePath,
        session.name,
        String(traceStartByte),
        "1b",
        "5b",
        "32",
        "30",
        "30",
        "7e",
      ], {
        stdout: "ignore",
        stderr: "pipe",
      });
      try {
        await session.resizeWindow(90, 28, 0);
        const injectorExit = await pasteStartInjector.exited;
        if (injectorExit !== 0) {
          const injectorStderr = await new Response(
            pasteStartInjector.stderr,
          ).text();
          throw new Error(
            `paste-start injector exited ${injectorExit}: ${injectorStderr}`,
          );
        }
      } finally {
        if (pasteStartInjector.exitCode === null) pasteStartInjector.kill();
      }
      const pausedTrace = await waitForTraceText(
        tracePath,
        "cursor_measure_paused reason=paste_start",
      );
      expect(pausedTrace.indexOf("cursor_measure_requested protocol=private"))
        .toBeLessThan(pausedTrace.indexOf("cursor_measure_paused reason=paste_start"));
      const cursor = session.cursorPosition();
      const delayedReply = Buffer.from(
        `\x1b[?${cursor.row + 1};1R\x1b[?${cursor.row + 1};2R`,
      );
      const expectedPrompt = `before${delayedReply.toString().replaceAll("\x1b", "")}after`;
      await session.sendLiteral("before");
      sendRawTmuxBytes(session, "in-paste-cpr", delayedReply);
      await session.sendLiteral("after");
      await session.sendHexBytes(["1b", "5b", "32", "30", "31", "7e"]);
      const completedPasteTrace = await waitForTraceText(
        tracePath,
        `paste end owner=composer bytes=${Buffer.byteLength(expectedPrompt)}`,
      );
      const pasteEndIndex = completedPasteTrace.indexOf(
        "paste end owner=composer",
      );
      expect(completedPasteTrace.slice(0, pasteEndIndex)).not.toContain(
        "cursor_measure expected_reflow_row=",
      );
      await session.sendKeys("Enter");

      expect(await waitForQueuedPromptBytes(tracePath, 60_000)).toBe(
        Buffer.byteLength(expectedPrompt),
      );
      expect(
        await waitForSubmittedUserText(gateway, tracePath, stderrPath),
      ).toBe(expectedPrompt);
      expect(findFooter(await session.capturePaneGrid())).not.toBeNull();
      expectEmptyStderr(stderrPath);
    },
    90_000,
  );

  test(
    "timed-out cursor probe does not leak a partial private CSI into later paste",
    async () => {
      const dir = mkdtempSync(join(tmpdir(), "fx-resize-probe-timeout-"));
      tempDirs.push(dir);
      const tracePath = join(dir, "trace.log");
      const stderrPath = join(dir, "stderr.log");
      const gateway = startFakeGateway([
        fakeGatewayFinalText("probe timeout complete"),
      ]);
      gateways.push(gateway);

      session = await createResizeSession({
        width: 120,
        height: 40,
        stderrPath,
        env: {
          AI_GATEWAY_API_KEY: "test-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "input,worker,resize",
          TMUX: undefined,
        },
      });
      await session.waitForComposer(10_000);

      await session.resizeWindow(90, 28, 0);
      await waitForTraceText(
        tracePath,
        "cursor_measure_requested protocol=private",
      );

      await session.sendHexBytes(["1b", "5b", "3f", "31", "32"]);
      await waitForTraceText(tracePath, "cursor_measure_failed err=Timeout");
      await session.sendHexBytes(["1b", "5b", "32", "30", "30", "7e"]);
      await session.sendLiteral("kept");
      await session.sendHexBytes(["1b", "5b", "32", "30", "31", "7e"]);
      await session.sendKeys("Enter");

      expect(await waitForQueuedPromptBytes(tracePath)).toBe(4);
      expect(
        await waitForSubmittedUserText(gateway, tracePath, stderrPath),
      ).toBe("kept");
      expectEmptyStderr(stderrPath);
    },
    TIMEOUT,
  );

  test(
    "settled resize clears pre-fx scrollback in both startup modes",
    async () => {
      for (const startupScrollback of [true, false]) {
        const root = mkdtempSync(join(tmpdir(), "fx-resize-history-reset-"));
        const home = join(root, "home");
        const workspace = join(root, "workspace");
        const marker = `PRE_FX_MARKER_${startupScrollback ? "ON" : "OFF"}_6179`;
        mkdirSync(join(home, ".fx"), { recursive: true });
        mkdirSync(workspace, { recursive: true });
        writeFileSync(
          join(home, ".fx", "settings.json"),
          JSON.stringify({ startup_scrollback: startupScrollback }),
        );
        tempDirs.push(root);
        session = await createResizeSession({
          cmd: `sh -c ${quoteShellPath(`printf '${marker}\\n'; exec ${quoteShellPath(FX_BIN)}`)}`,
          cwd: workspace,
          env: { HOME: home },
          width: 120,
          height: 40,
        });
        await session.waitForComposer(10_000);
        expect(await session.captureFullScrollback()).toContain(marker);

        await session.sendText("/help");
        await session.waitForText("Commands 37", 5_000);
        await session.resizeWindow(84, 28, 500);

        const catalog = await session.capturePaneGrid();
        expect(catalog.join("\n")).not.toContain(marker);
        expect(catalog.join("\n")).not.toContain("Run /help for commands");
        expect(findHelpScreen(catalog)).not.toBeNull();

        await session.sendKeys("Escape");
        await session.waitForText("Run /help for commands", 5_000);
        const scrollback = await session.captureFullScrollback();
        expect(scrollback).not.toContain(marker);
        expect(scrollback.match(/𝒇x v\d+\.\d+\.\d+\b/g)).toHaveLength(1);
        expect(scrollback.match(/Run \/help for commands/g)).toHaveLength(1);
        expect(scrollback.split("\n")[0]).toMatch(/𝒇x v\d+\.\d+\.\d+\b/);
        expect(scrollback).not.toContain("Commands 37");
        const finalGrid = await session.capturePaneGrid();
        expect(findFooter(finalGrid), finalGrid.join("\n")).not.toBeNull();

        await session.kill();
        session = null;
      }
    },
    TIMEOUT,
  );

  test(
    "idle theme monitoring stays silent and notifications retint the transcript once",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-theme-reset-replay-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const tracePath = join(root, "trace.log");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "theme-reset.fxtape");
      tempDirs.push(root);
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(join(home, ".fx", "settings.json"), "{}");
      writeFileSync(stderrPath, "");

      const inlineMarker = "THEME_RESET_INLINE_CODE";
      const inlineTailMarker = "THEME_RESET_INLINE_TAIL";
      const responseFence = textHex("\x1b[?1;2c");
      const darkBackground = textHex("\x1b]11;rgb:0000/0000/0000\x1b\\");
      const lightBackground = textHex("\x1b]11;rgb:ffff/ffff/ffff\x1b\\");
      const gateway = startFakeGateway([
        fakeGatewayFinalText(
          `THEME_RESET_FIRST_RESPONSE \`${inlineMarker} ${"x".repeat(10_000)}\` ${inlineTailMarker}\n`,
        ),
        fakeGatewayFinalText("THEME_RESET_SECOND_RESPONSE"),
      ]);
      gateways.push(gateway);
      session = await createResizeSession({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-theme-reset-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_RECORD: tapePath,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: "theme,frame_schedule,frame_commit,resize",
        },
        stderrPath,
        width: 120,
        height: 40,
      });
      await session.waitForComposer(TIMEOUT);
      await new Promise((resolve) => setTimeout(resolve, 200));
      const initialInputRows = (await session.capturePaneGrid()).filter(isInputRow);
      expect(initialInputRows).toEqual(["┃"]);
      await session.sendText("Record a theme reset transcript marker.");
      await session.waitForText("THEME_RESET_FIRST_RESPONSE", TIMEOUT);

      const resetCountBefore = countOccurrences(
        Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload)).toString(),
        "\x1b[3J",
      );
      let trace = readFileSync(tracePath, "utf8");
      let fenceRequests = countOccurrences(trace, "theme_query_requested kind=response_fence");
      let backgroundRequests = countOccurrences(trace, "theme_query_requested kind=background");
      const stdoutBeforeIdle = Buffer.concat(
        stdoutFrames(tapePath).map((frame) => frame.payload),
      ).toString();
      const rawFenceRequests = countOccurrences(stdoutBeforeIdle, "\x1b[c");
      const rawBackgroundRequests = countOccurrences(
        stdoutBeforeIdle,
        "\x1b]11;?\x1b\\",
      );

      await new Promise((resolve) => setTimeout(resolve, 1_300));
      trace = readFileSync(tracePath, "utf8");
      expect(countOccurrences(trace, "theme_query_requested kind=response_fence")).toBe(
        fenceRequests,
      );
      expect(countOccurrences(trace, "theme_query_requested kind=background")).toBe(
        backgroundRequests,
      );
      const stdoutAfterIdle = Buffer.concat(
        stdoutFrames(tapePath).map((frame) => frame.payload),
      ).toString();
      expect(countOccurrences(stdoutAfterIdle, "\x1b[c")).toBe(rawFenceRequests);
      expect(countOccurrences(stdoutAfterIdle, "\x1b]11;?\x1b\\")).toBe(
        rawBackgroundRequests,
      );

      sendRawTmuxBytes(
        session,
        "initial-theme-notification",
        Buffer.from("\x1b[?997;2n"),
      );
      await waitForTraceCount(
        tracePath,
        "theme_query_requested kind=response_fence",
        fenceRequests + 1,
      );
      await waitForTraceCount(
        tracePath,
        "theme_query_requested kind=background",
        backgroundRequests + 1,
      );
      await session.sendHexBytes([
        ...responseFence,
        ...darkBackground,
        ...lightBackground,
        ...responseFence,
      ]);
      await waitForTraceText(tracePath, "theme_update_settled light=true rgb=terminal");

      const replayed = await session.waitForText(inlineTailMarker, TIMEOUT);
      expect(replayed).not.toContain("?997");
      expect(replayed).not.toContain("rgb:ffff");
      expect((await session.capturePaneGrid()).join("\n")).not.toContain("rgb:ffff");
      const stdoutAfterLightTheme = Buffer.concat(
        stdoutFrames(tapePath).map((frame) => frame.payload),
      ).toString();
      const lightReplayStart = stdoutAfterLightTheme.lastIndexOf("\x1b[3J");
      expect(lightReplayStart).toBeGreaterThanOrEqual(0);
      const lightReplayAndTail = stdoutAfterLightTheme.slice(lightReplayStart);
      expect(lightReplayAndTail).toContain("\x1b[38;5;247m");
      expect(lightReplayAndTail).not.toContain("\x1b[38;5;245m");
      const resetCountAfter = countOccurrences(
        Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload)).toString(),
        "\x1b[3J",
      );
      expect(resetCountAfter).toBe(resetCountBefore + 1);
      expect(
        countOccurrences(
          await session.captureFullScrollback(),
          "THEME_RESET_FIRST_RESPONSE",
        ),
      ).toBe(1);

      trace = readFileSync(tracePath, "utf8");
      fenceRequests = countOccurrences(trace, "theme_query_requested kind=response_fence");
      backgroundRequests = countOccurrences(trace, "theme_query_requested kind=background");
      sendRawTmuxBytes(
        session,
        "theme-notification",
        Buffer.from("\x1b[?997;2n"),
      );
      const queryTrace = await waitForTraceCount(
        tracePath,
        "theme_query_requested kind=background",
        backgroundRequests + 1,
      );
      expect(
        countOccurrences(queryTrace, "theme_query_requested kind=response_fence"),
      ).toBeGreaterThanOrEqual(fenceRequests + 1);
      await session.sendHexBytes([
        ...responseFence,
        ...lightBackground,
        ...darkBackground,
        ...responseFence,
      ]);
      await waitForTraceText(tracePath, "theme_update_settled light=false rgb=terminal");
      expect(
        countOccurrences(
          Buffer.concat(stdoutFrames(tapePath).map((frame) => frame.payload)).toString(),
          "\x1b[3J",
        ),
      ).toBe(resetCountBefore + 2);

      await session.sendText("Confirm input survives the theme reset.");
      await session.waitForText("THEME_RESET_SECOND_RESPONSE", TIMEOUT);
      expect(session.isPaneAlive()).toBe(true);
      trace = readFileSync(tracePath, "utf8");
      expect(trace).not.toContain("rgb=fallback");
      expectEmptyStderr(stderrPath);
    },
    90_000,
  );

  test(
    "grow keeps the current composer at the wider terminal width",
    async () => {
      session = await launchAt(80, 30);
      await session.resizeWindow(120, 40);

      const grid = await session.capturePaneGrid();
      const footer = findFooter(grid);
      expect(footer).not.toBeNull();
      expect(session.paneSize()).toEqual({ cols: 120, rows: 40 });
      expect(grid[footer!.input]).toBe("┃");
    },
    TIMEOUT,
  );
});
