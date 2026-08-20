import { execFileSync } from "node:child_process";
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { readTapeFrames, stdoutFrames } from "./render-lab/tape";
import {
  assertPaneContains,
  assertSingleFooter,
} from "./tui-render-assertions";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 45_000;
const TRACE_SCOPES =
  "paint,render,scroll,footer.clean,input,resize,frame_layout,frame_plan,frame_diff,frame_commit,frame_owner_violation";
const TRANSIENT_ACTIVITY_CAPTURE_TARBALL = "/private/tmp/fx-render-bug-20260510-073148.tar.gz";
const TRANSIENT_ACTIVITY_CAPTURE_DIR = "/private/tmp/fx-render-bug-20260510-073148";
const READ_ONLY_TOOLS_CAPTURE_TARBALL = join(
  import.meta.dirname,
  "fixtures",
  "fx-render-bug-20260510-075848.tar.gz",
);

let session: TmuxSession | null = null;
const workDirs: string[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  for (const dir of workDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

async function launch(options: {
  recordInput?: boolean;
  syncUpdates?: "0" | "1";
} = {}): Promise<{
  session: TmuxSession;
  tapePath: string;
  goldenPath: string;
  tracePath: string;
}> {
  const workDir = mkdtempSync(join(tmpdir(), "fx-render-replay-"));
  workDirs.push(workDir);

  const tapePath = join(workDir, "render.fxtape");
  const goldenPath = join(workDir, "grid.txt");
  const tracePath = join(workDir, "trace.log");
  mkdirSync(join(workDir, ".fx"), { recursive: true });
  writeFileSync(
    join(workDir, ".fx", "settings.json"),
    JSON.stringify({ maxxing_mode: "legacy" }),
  );

  const s = await TmuxSession.create({
    cmd: `env -u AI_GATEWAY_API_KEY -u VERCEL_OIDC_TOKEN FX_DISABLE_KEYCHAIN=1 FX_SKIP_ONBOARDING=1 ${FX_BIN}`,
    cwd: workDir,
    width: 88,
    height: 30,
    env: {
      HOME: workDir,
      FX_RECORD: tapePath,
      ...(options.recordInput ? { FX_RECORD_INPUT: "1" } : {}),
      ...(options.syncUpdates ? { FX_SYNC_UPDATES: options.syncUpdates } : {}),
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: TRACE_SCOPES,
    },
  });
  session = s;
  await s.waitForComposer(10_000);
  return { session: s, tapePath, goldenPath, tracePath };
}

function parseReplayJson(output: string): {
  frame_count: number;
  resize_count: number;
  stdout_bytes: number;
} {
  return JSON.parse(output.trim());
}

async function launchAutomaticRecording(): Promise<{
  session: TmuxSession;
  tapePath: string;
  goldenPath: string;
  tracePath: string;
  home: string;
}> {
  const workDir = mkdtempSync("/tmp/fx-render-auto-replay-");
  workDirs.push(workDir);
  const home = join(workDir, "home");
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ maxxing_mode: "legacy" }),
  );

  const goldenPath = join(workDir, "grid.txt");
  const tracePath = join(workDir, "trace.log");
  const s = await TmuxSession.create({
    cmd: `env -u AI_GATEWAY_API_KEY -u VERCEL_OIDC_TOKEN FX_DISABLE_KEYCHAIN=1 FX_SKIP_ONBOARDING=1 ${FX_BIN} --record`,
    cwd: workDir,
    width: 180,
    height: 36,
    env: {
      HOME: home,
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: TRACE_SCOPES,
    },
  });
  session = s;
  await s.waitForText("visual terminal capture:", 10_000);
  const grid = (await s.capturePaneGrid()).join("\n");
  const tapePath = grid.match(/visual terminal capture:\s*(\S+\.fxtape)/)?.[1];
  if (!tapePath) {
    throw new Error(`recording path was not printed:\n${grid}`);
  }
  return { session: s, tapePath, goldenPath, tracePath, home };
}

describe("tui: render record/replay", () => {
  test.skipIf(!existsSync(TRANSIENT_ACTIVITY_CAPTURE_TARBALL) && !existsSync(join(TRANSIENT_ACTIVITY_CAPTURE_DIR, "bug.fxtape")))(
    "replays transient activity capture without layout validation failures",
    () => {
      const failures: string[] = [];
      let captureDir = TRANSIENT_ACTIVITY_CAPTURE_DIR;
      if (!existsSync(join(captureDir, "bug.fxtape"))) {
        const workDir = mkdtempSync(join(tmpdir(), "fx-render-capture-"));
        workDirs.push(workDir);
        execFileSync("tar", ["-xzf", TRANSIENT_ACTIVITY_CAPTURE_TARBALL, "-C", workDir]);
        captureDir = join(workDir, "fx-render-bug-20260510-073148");
      }

      const tapePath = join(captureDir, "bug.fxtape");
      const workDir = mkdtempSync(join(tmpdir(), "fx-render-capture-replay-"));
      workDirs.push(workDir);
      const goldenPath = join(workDir, "grid.txt");
      const tracePath = join(workDir, "trace.log");

      const replayJsonOutput = execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
        encoding: "utf8",
      });
      const replay = parseReplayJson(replayJsonOutput);
      expect(replay.frame_count).toBe(504);
      expect(replay.resize_count).toBe(0);
      expect(replay.stdout_bytes).toBeGreaterThan(0);

      execFileSync(FX_BIN, ["replay", tapePath, "--golden", goldenPath], {
        env: {
          ...process.env,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: TRACE_SCOPES,
        },
      });
      const trace = readTrace(tracePath);
      expect(trace).not.toContain("viewport_validation_clamped");
      expect(trace).not.toContain("layout_refine_failed");
      expect(trace).not.toContain("WriteOutsideBand");
      expect(trace).not.toContain("frame_owner_violation");

      const gridText = readFileSync(goldenPath, "utf8");
      assertSingleFooter(gridText.replace(/\n$/, "").split("\n"), failures, "transient activity replay grid");
      expect(failures).toEqual([]);
    },
    TIMEOUT,
  );

  test.skipIf(SKIP)(
    "composer frames restore the visible cursor after synchronized updates",
    async () => {
      const launched = await launch({ recordInput: true, syncUpdates: "1" });
      session = launched.session;

      for (const draft of ["w", "wh", "why"]) {
        await session.sendLiteral(draft.at(-1)!);
        await session.waitForText(draft, 5_000);
      }

      const frames = readTapeFrames(launched.tapePath);
      let previous_input_index = -1;
      for (const byte of ["w", "h", "y"]) {
        const input_index = frames.findIndex(
          (frame, index) =>
            index > previous_input_index &&
            frame.kind === 2 &&
            frame.payload.toString("binary") === byte,
        );
        expect(input_index).toBeGreaterThan(previous_input_index);
        previous_input_index = input_index;

        const output_index = frames.findIndex(
          (frame, index) => index > input_index && frame.kind === 1,
        );
        const next_input_index = frames.findIndex(
          (frame, index) => index > input_index && frame.kind === 2,
        );
        expect(output_index).toBeGreaterThan(input_index);
        if (next_input_index >= 0) expect(output_index).toBeLessThan(next_input_index);
        const payload = frames[output_index]!.payload.toString("binary");
        const sync_begin = payload.indexOf("\x1b[?2026h");
        const cursor_hide = payload.indexOf("\x1b[?25l");
        const sync_end = payload.indexOf("\x1b[?2026l");
        const cursor_show = payload.indexOf("\x1b[?25h");
        expect(sync_begin).toBeGreaterThanOrEqual(0);
        expect(cursor_hide).toBeGreaterThan(sync_begin);
        expect(sync_end).toBeGreaterThan(cursor_hide);
        expect(cursor_show).toBeGreaterThan(sync_end);
      }

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("why");
      execFileSync(FX_BIN, ["replay", launched.tapePath, "--golden", launched.goldenPath]);
      const grid = readFileSync(launched.goldenPath, "utf8");
      expect(grid).toContain("why");

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(5_000)).toBe(true);
      session = null;
    },
    TIMEOUT,
  );

  test.skipIf(SKIP)(
    "composer frames omit synchronized updates when disabled",
    async () => {
      const launched = await launch({ recordInput: true, syncUpdates: "0" });
      session = launched.session;

      await session.sendLiteral("x");
      await session.waitForText("x", 5_000);

      const stdout = Buffer.concat(
        readTapeFrames(launched.tapePath)
          .filter((frame) => frame.kind === 1)
          .map((frame) => frame.payload),
      ).toString("binary");
      expect(stdout).not.toContain("\x1b[?2026h");
      expect(stdout).not.toContain("\x1b[?2026l");

      const scrollback = await session.captureFullScrollback();
      expect(scrollback).toContain("x");
      execFileSync(FX_BIN, ["replay", launched.tapePath, "--golden", launched.goldenPath]);
      expect(readFileSync(launched.goldenPath, "utf8")).toContain("x");

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(5_000)).toBe(true);
      session = null;
    },
    TIMEOUT,
  );

  test(
    "replays read-only tools capture without layout validation failures",
    () => {
      const failures: string[] = [];
      const extractDir = mkdtempSync(join(tmpdir(), "fx-render-read-only-tools-"));
      workDirs.push(extractDir);
      execFileSync("tar", ["-xzf", READ_ONLY_TOOLS_CAPTURE_TARBALL, "-C", extractDir]);
      const captureDir = join(extractDir, "fx-render-bug-20260510-075848");
      const tapePath = join(captureDir, "bug.fxtape");
      const workDir = mkdtempSync(join(tmpdir(), "fx-render-read-only-tools-replay-"));
      workDirs.push(workDir);
      const goldenPath = join(workDir, "grid.txt");
      const tracePath = join(workDir, "trace.log");

      const replayJsonOutput = execFileSync(FX_BIN, ["replay", tapePath, "--json"], {
        encoding: "utf8",
      });
      const replay = parseReplayJson(replayJsonOutput);
      expect(replay.frame_count).toBe(381);
      expect(replay.resize_count).toBe(0);
      expect(replay.stdout_bytes).toBeGreaterThan(0);

      execFileSync(FX_BIN, ["replay", tapePath, "--golden", goldenPath], {
        env: {
          ...process.env,
          FX_TRACE_LOG: tracePath,
          FX_TRACE_SCOPES: TRACE_SCOPES,
        },
      });
      const trace = readTrace(tracePath);
      expect(trace).not.toContain("InvalidActivityPlacement");
      expect(trace).not.toContain("viewport_validation_clamped");
      expect(trace).not.toContain("layout_refine_failed");
      expect(trace).not.toContain("WriteOutsideBand");
      expect(trace).not.toContain("frame_owner_violation");

      const gridText = readFileSync(goldenPath, "utf8");
      expect(gridText).toContain("run some tools - read only tool for testing");
      expect(gridText).toContain("Listed .");
      assertSingleFooter(gridText.replace(/\n$/, "").split("\n"), failures, "read-only tools replay grid");
      expect(failures).toEqual([]);
    },
    TIMEOUT,
  );

  test.skipIf(SKIP)(
    "opt-in input recording captures bracketed paste and Return without changing replay",
    async () => {
      const pasted = Array.from(
        { length: 33 },
        (_, index) => `captured input line ${index + 1}: ${"x".repeat(32)}`,
      ).join("\n");
      const authNotice = "● Auth: fx needs access to Vercel AI Gateway. Run /login to sign in, /setup to use an API key, or set AI_GATEWAY_API_KEY.";
      const launched = await launch({ recordInput: true });
      session = launched.session;

      await session.pasteText(pasted);
      await session.waitForText("[Pasted text #1, 33 lines]", 5_000);
      await session.sendKeys("Enter");
      await session.waitForText("● Auth: fx needs access", 5_000);
      expect((await session.captureFullScrollback()).replace(/\s+/g, " ")).toContain(authNotice);

      const stdin = readTapeFrames(launched.tapePath)
        .filter((frame) => frame.kind === 2)
        .map((frame) => frame.payload.toString("binary"))
        .join("");
      const recordedPaste = `\x1b[200~${pasted.replaceAll("\n", "\r")}\x1b[201~`;
      const pasteEnd = stdin.indexOf(recordedPaste) + recordedPaste.length;
      expect(pasteEnd).toBeGreaterThanOrEqual(recordedPaste.length);
      expect(stdin.slice(pasteEnd)).toMatch(/^(?:\x1b\[\?[\d;]*c)*\r/);

      execFileSync(FX_BIN, ["replay", launched.tapePath, "--golden", launched.goldenPath]);
      expect(
        readFileSync(launched.goldenPath, "utf8").replaceAll("|", " ").replace(/\s+/g, " "),
      ).toContain(authNotice);

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(5_000)).toBe(true);
      session = null;
    },
    TIMEOUT,
  );

  test.skipIf(SKIP)(
    "recorded stdout and resize bytes replay to a valid final grid",
    async () => {
      const failures: string[] = [];
      const marker = "replay_marker_visible";
      const inputTail = "replay_input_tail_visibl";
      const launched = await launch();
      session = launched.session;

      await session.sendText(marker);
      await session.waitForText("fx needs access to Vercel AI Gateway", 5_000);
      await session.sendKeys("C-u");
      await session.sendText("/status");
      await session.waitForText("permission_mode", 5_000);
      await session.sendKeys("-l 'replay_input_tail_visible'");
      await session.waitForText(inputTail, 5_000);
      await session.resizeWindow(64, 24);
      await session.resizeWindow(116, 36);
      await session.resizeWindow(88, 30);

      const replayJsonOutput = execFileSync(
        FX_BIN,
        ["replay", launched.tapePath, "--json"],
        { encoding: "utf8" },
      );
      const replay = parseReplayJson(replayJsonOutput);
      if (replay.frame_count <= 0) failures.push("replay reported no frames");
      if (replay.stdout_bytes <= 0) failures.push("replay reported no stdout bytes");
      if (replay.resize_count < 3) failures.push("replay reported too few resize frames");

      execFileSync(FX_BIN, ["replay", launched.tapePath, "--golden", launched.goldenPath]);
      const gridText = readFileSync(launched.goldenPath, "utf8");
      const grid = gridText.replace(/\n$/, "").split("\n");
      assertPaneContains(gridText, inputTail, failures, "replay grid");
      assertSingleFooter(grid, failures, "replay grid");

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      const exited = await session.waitForSessionEnd(5_000);
      if (!exited) failures.push("recorded session did not exit");
      session = null;

      assertNoPostFrameScrollSplits(launched.tapePath, failures);
      assertNoFooterlessCapturedRepaintSplit(launched.tapePath, failures);
      assertResizeResetFrames(launched.tapePath, failures);
      assertNoPostFrameNestedSync(launched.tapePath, failures);

      expect(failures).toEqual([]);
    },
    TIMEOUT,
  );

  test.skipIf(SKIP)(
    "automatic recording writes a private tape under the test home",
    async () => {
      const failures: string[] = [];
      const marker = "automatic_recording_marker";
      const inputTail = "automatic_recording_input_tail";
      const launched = await launchAutomaticRecording();
      session = launched.session;

      expect(launched.tapePath.startsWith(join(launched.home, ".fx", "recordings"))).toBe(true);
      await session.sendText(marker);
      await session.waitForText("fx needs access to Vercel AI Gateway", 5_000);
      await session.sendKeys(`-l '${inputTail}'`);
      await session.waitForText(inputTail, 5_000);
      await session.resizeWindow(120, 28);

      const replayJsonOutput = execFileSync(
        FX_BIN,
        ["replay", launched.tapePath, "--json"],
        { encoding: "utf8" },
      );
      const replay = parseReplayJson(replayJsonOutput);
      if (replay.resize_count < 1) failures.push("replay reported no resize frame");

      execFileSync(FX_BIN, ["replay", launched.tapePath, "--golden", launched.goldenPath]);
      const gridText = readFileSync(launched.goldenPath, "utf8");
      assertPaneContains(gridText, inputTail, failures, "automatic recording replay grid");

      await session.sendKeys("C-u");
      await session.sendText("/quit");
      const exited = await session.waitForSessionEnd(5_000);
      if (!exited) failures.push("recorded session did not exit");
      session = null;

      expect(failures).toEqual([]);
    },
    TIMEOUT,
  );

  test.skipIf(SKIP)(
    "frame trace scopes are metadata-only during prompt resize and replay",
    async () => {
      const forbiddenPrompt = "trace_secret_prompt_token_6179";
      const forbiddenTokens = [
        forbiddenPrompt,
        "fx needs access to Vercel AI Gateway",
        "footer row preview secret",
        "shimmer label secret",
        "command output secret",
        "clipboard secret",
        "https://secret.example/osc",
      ];
      const launched = await launch();
      session = launched.session;

      await session.sendText(forbiddenPrompt);
      await session.waitForText("fx needs access to Vercel AI Gateway", 5_000);
      await session.resizeWindow(72, 24);
      await session.sendKeys("C-u");
      await session.sendText("/status");
      await session.waitForText("permission_mode", 5_000);
      const trace = await waitForTrace(
        launched.tracePath,
        (text) =>
          text.includes("[frame_plan]") &&
          text.includes("[frame_layout]") &&
          text.includes("[frame_diff]") &&
          text.includes("[frame_commit]"),
        10_000,
      );

      assertTraceSafety(trace, forbiddenTokens, [
        "[frame_plan]",
        "[frame_layout]",
        "[frame_diff]",
        "[frame_commit]",
        "footer_layout",
      ]);
      expect(trace).not.toContain("shadow_cross_check_failed");
      expect(trace).not.toContain("state=shadow_feed_failed");
      expect(trace).not.toContain("viewport_validation_clamped");
      assertTraceSafety(
        `${trace}\n0 [frame_owner_violation] row=3 col=1 previous_owner=activity next_owner=transcript policy=same_owner reason=owner_conflict invalidation=resize\n0 [paint] shimmer_surface_paint row=3 visible=true over_footer=false label_bytes=20 label_hash=abcd`,
        forbiddenTokens,
        ["[frame_owner_violation]", "shimmer_surface_paint"],
      );

      await session.sendText("/quit");
      const exited = await session.waitForSessionEnd(5_000);
      expect(exited).toBe(true);
      session = null;
    },
    TIMEOUT,
  );
});

function assertTraceSafety(
  trace: string,
  forbiddenTokens: string[],
  requiredMarkers: string[],
): void {
  for (const marker of requiredMarkers) {
    expect(trace).toContain(marker);
  }
  for (const token of forbiddenTokens) {
    expect(trace).not.toContain(token);
  }
  const unsafeRowDump = /\b(row_text|row_preview|terminal_row|full_row)=/.exec(trace);
  expect(unsafeRowDump).toBeNull();
}

async function waitForTrace(
  path: string,
  predicate: (trace: string) => boolean,
  timeoutMs: number,
): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const trace = readTraceIfExists(path);
    if (predicate(trace)) return trace;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`timed out waiting for trace predicate\n${readTraceIfExists(path)}`);
}

function readTrace(path: string): string {
  expect(existsSync(path)).toBe(true);
  const trace = readFileSync(path, "utf8");
  expect(trace.length).toBeGreaterThan(0);
  return trace;
}

function readTraceIfExists(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function assertNoPostFrameScrollSplits(path: string, failures: string[]): void {
  const frames = stdoutFrames(path);
  for (let i = 0; i < frames.length; i++) {
    const text = frames[i]!.payload.toString("binary");
    const prev = i > 0 ? frames[i - 1]!.payload.toString("binary") : "";
    if (/^\x1b\[\d+;1H$/.test(prev) && /^\n+$/.test(text)) {
      failures.push(`standalone terminal scroll split at stdout frames ${frames[i - 1]!.index}-${frames[i]!.index}`);
    }
    if (/^\x1b\[\d+;1H\n+$/.test(text)) {
      failures.push(`standalone terminal scroll payload at stdout frame ${frames[i]!.index}`);
    }
  }
}

function assertNoFooterlessCapturedRepaintSplit(path: string, failures: string[]): void {
  const frames = stdoutFrames(path);
  for (let i = 0; i + 2 < frames.length; i++) {
    const clear = frames[i]!.payload.toString("binary");
    const syncEnd = frames[i + 1]!.payload.toString("binary");
    const footer = frames[i + 2]!.payload.toString("utf8");
    if (
      clear.includes("\x1b[2J\x1b[3J") &&
      syncEnd === "\x1b[?2026l" &&
      /❯|\[\d+\/\d+\]\s❯/.test(footer)
    ) {
      failures.push(`captured repaint exposed footerless sync split at stdout frames ${frames[i]!.index}-${frames[i + 2]!.index}`);
    }
  }
}

function assertResizeResetFrames(path: string, failures: string[]): void {
  const frames = readTapeFrames(path);
  let seenFrameCommit = false;
  const pendingResizeFrames: number[] = [];
  for (const frame of frames) {
    if (frame.kind === 3 && seenFrameCommit) {
      pendingResizeFrames.push(frame.index);
      continue;
    }
    if (frame.kind !== 1) continue;

    const text = frame.payload.toString("binary");
    const reset = text.includes("\x1b[0m\x1b[3J\x1b[2J\x1b[H");
    if (text.includes("\x1b[3J") && !reset) {
      failures.push(`resize reset used an unexpected clear sequence at tape frame ${frame.index}`);
    }
    if (reset && pendingResizeFrames.length === 0) {
      failures.push(`captured terminal reset without a preceding resize at tape frame ${frame.index}`);
    }
    if (reset) {
      pendingResizeFrames.length = 0;
    }
    if (text.includes("\x1b[?2026h\x1b[?25l")) seenFrameCommit = true;
  }
  if (pendingResizeFrames.length > 0) {
    failures.push(
      `resize frames ${pendingResizeFrames.join(", ")} did not commit a terminal reset`,
    );
  }
}

function assertNoPostFrameNestedSync(path: string, failures: string[]): void {
  const frames = readTapeFrames(path);
  let seenFrameCommit = false;
  let depth = 0;
  for (const frame of frames) {
    if (frame.kind !== 1) continue;
    const text = frame.payload.toString("binary");
    const tokens = [...text.matchAll(/\x1b\[\?2026[hl]/g)];
    for (const token of tokens) {
      const seq = token[0];
      if (seq === "\x1b[?2026h") {
        if (seenFrameCommit && depth > 0) {
          failures.push(`post-frame nested synchronized update at tape frame ${frame.index}`);
        }
        depth += 1;
      } else if (seq === "\x1b[?2026l") {
        if (depth > 0) depth -= 1;
      }
    }
    if (text.includes("\x1b[?2026h\x1b[?25l")) {
      seenFrameCommit = true;
    }
  }
}
