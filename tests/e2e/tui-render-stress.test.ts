import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  assertPaneContains,
  assertSingleFooter,
  assertTraceInvariants,
  readTrace,
  visibleText,
} from "./tui-render-assertions";
import {
  composerContains,
  hasEmptyComposer,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 45_000;
const RUNS = 4;
const TRACE_SCOPES = "paint,render,scroll,footer.clean,input";

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

function longInput(run: number): string {
  const parts = [`render stress run ${run}`];
  for (let i = 0; i < 24; i++) {
    parts.push(`wrap_${run}_${i}_abcdefghijklmnopqrstuvwxyz`);
  }
  parts.push(`tail_${run}_visible`);
  return parts.join(" ");
}

async function launch(
  run: number,
  width: number,
  height: number,
): Promise<{ session: TmuxSession; tracePath: string }> {
  const workDir = mkdtempSync(join(tmpdir(), `fx-render-stress-${run}-`));
  workDirs.push(workDir);
  const home = join(workDir, "home");
  mkdirSync(home);
  const tracePath = join(workDir, "trace.log");

  const s = await TmuxSession.create({
    cmd: `env -u AI_GATEWAY_API_KEY -u VERCEL_OIDC_TOKEN FX_DISABLE_KEYCHAIN=1 FX_SKIP_ONBOARDING=1 ${FX_BIN}`,
    cwd: workDir,
    width,
    height,
    env: {
      HOME: home,
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: TRACE_SCOPES,
    },
  });
  await s.waitForComposer(10_000);
  return { session: s, tracePath };
}

async function waitForVisibleText(
  session: TmuxSession,
  token: string,
  timeoutMs: number,
): Promise<string> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const pane = await session.capturePane();
    if (visibleText(pane).includes(visibleText(token))) return pane;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  const final = await session.capturePane();
  throw new Error(`Timed out waiting for visible text ${token} after ${timeoutMs}ms.\nPane contents:\n${final}`);
}

describe.skipIf(SKIP)("tui: render stress", () => {
  test(
    "long input, resize, and local transcript writes keep one valid footer",
    async () => {
      const failures: string[] = [];

      for (let run = 0; run < RUNS; run++) {
        const width = 82 + run * 10;
        const height = 26 + run * 3;
        const launched = await launch(run, width, height);
        session = launched.session;

        const firstPrompt = `visible_user_prompt_${run}`;
        await session.sendText(firstPrompt);
        await session.waitForText("fx needs access to Vercel AI Gateway", 5_000);

        const tailToken = `tail_${run}_visibl`;
        await session.sendKeys(`-l '${longInput(run)}'`);
        await waitForVisibleText(session, tailToken, 5_000);

        await session.resizeWindow(62, 24);
        await session.resizeWindow(118, 36);
        await session.resizeWindow(width, height);

        const inputPane = await waitForVisibleText(session, tailToken, 5_000);
        assertPaneContains(inputPane, tailToken, failures, `run ${run}`);

        await session.sendKeys("C-u");
        await session.sendText("/help");
        await session.waitForText("Commands 35", 5_000);
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("Enter Open"), 5_000);
        await session.sendText("/status");
        await session.waitForText("permission_mode", 5_000);
        const unknownCommand = `/unknown-render-stress-${run} local transcript notice`;
        await session.sendLiteralText(unknownCommand);
        await session.waitForPane(
          (pane) => composerContains(pane, unknownCommand),
          5_000,
        );
        await Bun.sleep(100);
        const unmatchedPane = await session.capturePane();
        if (unmatchedPane.includes("no matching slash commands")) {
          failures.push(`run ${run}: unmatched slash input kept an empty picker row`);
        }
        await session.sendKeys("C-u");
        await session.waitForPane(hasEmptyComposer, 5_000);

        const grid = await session.capturePaneGrid();
        assertSingleFooter(grid, failures, `run ${run}`);

        const trace = readTrace(launched.tracePath);
        assertTraceInvariants(trace, failures, `run ${run}`);

        await session.sendText("/quit");
        const exited = await session.waitForSessionEnd();
        if (!exited) failures.push(`run ${run}: /quit did not exit`);
        session = null;
      }

      expect(failures).toEqual([]);
    },
    TIMEOUT,
  );
});
