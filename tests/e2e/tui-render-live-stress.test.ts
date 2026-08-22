import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HAS_API_KEY } from "../evals/eval-helpers";
import {
  assertPaneContains,
  assertSingleFooter,
  assertTraceInvariants,
  readTrace,
} from "./tui-render-assertions";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const LIVE_ENABLED = process.env.FX_LIVE_RENDER_STRESS === "1";
const SKIP = !LIVE_ENABLED || !tmuxAvailable() || !HAS_API_KEY;
const TIMEOUT = 240_000;
const TRACE_SCOPES = "paint,render,scroll,footer.clean,input,tool,gateway";

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

function livePrompt(run: number, step: number): { prompt: string; marker: string; visible: string } {
  const marker = `LIVE_RENDER_STRESS_DONE_${run}_${step}`;
  const visible = `live_user_visible_${run}_${step}`;
  const prompt = [
    `${visible}: this is a real gateway TUI render stress prompt.`,
    "Use read-only tools before answering: list the current directory, then inspect README.md or CHANGELOG.md if present.",
    "Do not edit files.",
    "While you answer, include one compact paragraph of roughly 80 words.",
    `End your final answer with exactly ${marker}.`,
  ].join(" ");
  return { prompt, marker, visible };
}

async function launch(run: number): Promise<{ session: TmuxSession; tracePath: string }> {
  const workDir = mkdtempSync(join(tmpdir(), `fx-render-live-stress-${run}-`));
  workDirs.push(workDir);
  const tracePath = join(workDir, "trace.log");

  const s = await TmuxSession.create({
    cwd: workDir,
    width: 84,
    height: 30,
    env: {
      AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY,
      VERCEL_OIDC_TOKEN: process.env.VERCEL_OIDC_TOKEN,
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: TRACE_SCOPES,
    },
  });
  await s.waitForComposer(10_000);
  return { session: s, tracePath };
}

async function waitForScrollbackText(
  activeSession: TmuxSession,
  text: string,
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let scrollback = "";
  while (Date.now() < deadline) {
    scrollback = await activeSession.captureFullScrollback();
    if (scrollback.includes(text)) return scrollback;
    await sleep(100);
  }
  throw new Error(
    `Timed out waiting for durable scrollback text ${JSON.stringify(text)}.\nScrollback:\n${scrollback}`,
  );
}

async function waitForScrollbackOccurrences(
  activeSession: TmuxSession,
  text: string,
  minimum: number,
  timeoutMs: number,
): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let scrollback = "";
  while (Date.now() < deadline) {
    scrollback = await activeSession.captureFullScrollback();
    if (scrollback.split(text).length - 1 >= minimum) return scrollback;
    await sleep(100);
  }
  throw new Error(
    `Timed out waiting for ${minimum} durable occurrences of ${JSON.stringify(text)}.\nScrollback:\n${scrollback}`,
  );
}

describe.skipIf(SKIP)("tui: live render stress", () => {
  test(
    "live streaming, tool activity, and resize preserve prompts and keep the footer visible",
    async () => {
      const failures: string[] = [];
      const launched = await launch(0);
      session = launched.session;

      for (let step = 0; step < 3; step++) {
        const { prompt, marker, visible } = livePrompt(0, step);
        await session.sendText(prompt);
        await waitForScrollbackText(session, visible, 10_000);
        await sleep(1_500);

        await session.resizeWindow(64, 24);
        await session.resizeWindow(118, 36);
        await session.resizeWindow(84, 30);

        const scrollback = await waitForScrollbackOccurrences(session, marker, 2, 120_000);
        const pane = await session.capturePane();
        assertPaneContains(scrollback, visible, failures, `step ${step} scrollback`);
        assertPaneContains(pane, marker, failures, `step ${step}`);
        const grid = await session.capturePaneGrid();
        assertSingleFooter(grid, failures, `step ${step}`);
      }

      const trace = readTrace(launched.tracePath);
      assertTraceInvariants(trace, failures, "live run", { requireToolCall: true });

      await session.sendText("/quit");
      const exited = await session.waitForSessionEnd(5_000);
      if (!exited) failures.push("/quit did not exit");
      session = null;

      expect(failures).toEqual([]);
    },
    TIMEOUT,
  );
});

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
