import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 120_000;
const READY_TIMEOUT = 15_000;

// A terminal cell holds at most 64 bytes of text: its base character and the
// marks drawn on it. fx drops the marks that would pass that and keeps running.
const CELL_BYTES = 64;
const BASE = "e";

type Case = { label: string; mark: string; count: number };

const cases: Case[] = [
  { label: "U+0301 x40", mark: "\u0301", count: 40 },
  { label: "U+0301 x200", mark: "\u0301", count: 200 },
  { label: "U+200B x40", mark: "\u200b", count: 40 },
  { label: "U+200D x40", mark: "\u200d", count: 40 },
  { label: "U+FE0F x40", mark: "\ufe0f", count: 40 },
  { label: "tag U+E0061 x20", mark: "\u{e0061}", count: 20 },
];

function keptMarks(mark: string): number {
  const markBytes = new TextEncoder().encode(mark).length;
  return Math.floor((CELL_BYTES - BASE.length) / markBytes);
}

type Fx = {
  session: TmuxSession;
  gateway: ReturnType<typeof startFakeGateway>;
  home: string;
  stderrPath: string;
  tape: string;
};

const running: Fx[] = [];

afterEach(async () => {
  for (const fx of running.splice(0)) {
    await fx.session.kill();
    fx.gateway.stop();
    rmSync(fx.home, { recursive: true, force: true });
  }
});

async function startFx(replies: Response[]): Promise<Fx> {
  const home = mkdtempSync(join(tmpdir(), "fx-cell-suffix-"));
  const stderrPath = join(home, "stderr.log");
  writeFileSync(stderrPath, "");
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({ sandbox: "none" }),
  );
  const gateway = startFakeGateway(replies);
  const tape = join(home, "session.fxtape");
  const session = await TmuxSession.create({
    cmd: FX_BIN,
    env: {
      HOME: home,
      FX_RECORD: tape,
      AI_GATEWAY_API_KEY: "fake-cell-suffix-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
    },
    width: 60,
    height: 20,
    stderrPath,
  });
  const fx = { session, gateway, home, stderrPath, tape };
  running.push(fx);
  await session.waitForComposer(READY_TIMEOUT);
  return fx;
}

/** Waits for `text` on screen. A timeout says whether fx is still alive and what it wrote to stderr. */
async function waitFor(fx: Fx, text: string): Promise<void> {
  try {
    await fx.session.waitForText(text, READY_TIMEOUT);
  } catch (error) {
    const stderr = readFileSync(fx.stderrPath, "utf8");
    throw new Error(
      `${JSON.stringify(text)} never showed; fx alive: ${fx.session.isAlive()}; stderr: ${JSON.stringify(stderr)}\n${String(error)}`,
    );
  }
}

/**
 * The rows of the screen fx drew that hold `needle`, read back from its own
 * recording. tmux keeps about 21 bytes per cell, so only fx's replay shows how
 * many marks fx kept on a cell.
 */
async function replayedRows(fx: Fx, needle: string): Promise<string[]> {
  await fx.session.kill();
  const golden = join(fx.home, "golden.txt");
  const replay = spawnSync(FX_BIN, ["replay", fx.tape, "--golden", golden], {
    encoding: "utf8",
    env: {
      HOME: fx.home,
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      FX_SOUND: "0",
      FX_DISABLE_KEYCHAIN: "1",
    },
  });
  expect(replay.status).toBe(0);
  return readFileSync(golden, "utf8")
    .split("\n")
    .filter((row) => row.includes(needle));
}

function expectKeptMarks(rows: string[], c: Case): void {
  expect(rows.length).toBeGreaterThan(0);
  const expected = Math.min(c.count, keptMarks(c.mark));
  for (const row of rows) {
    expect([...row].filter((char) => char === c.mark).length).toBe(expected);
  }
}

function expectRunning(fx: Fx): void {
  expect(fx.session.isAlive()).toBe(true);
  expect(readFileSync(fx.stderrPath, "utf8")).toBe("");
}

describe.skipIf(SKIP)("tui: a cell that gets more marks than it can hold", () => {
  test(
    "typed marks keep fx running, keep the cursor in step, and reach the model whole",
    async () => {
      for (const c of cases) {
        const fx = await startFx([fakeGatewayFinalText("reply-ok")]);
        const text = `${BASE}${c.mark.repeat(c.count)}END`;
        await fx.session.sendLiteralText(text);
        await waitFor(fx, "END");
        // "┃ " is two cells, then the base, then END: the marks take no cell.
        expect(fx.session.cursorPosition().col).toBe(2 + 1 + 3);
        await fx.session.sendKeys("Enter");
        await waitFor(fx, "reply-ok");
        expectRunning(fx);
        expect(fx.gateway.requests[0]!.body).toContain(text);
        expectKeptMarks(await replayedRows(fx, "END"), c);
      }
    },
    TIMEOUT,
  );

  test(
    "pasted marks keep fx running and reach the model whole",
    async () => {
      for (const c of cases) {
        const fx = await startFx([fakeGatewayFinalText("reply-ok")]);
        const text = `${BASE}${c.mark.repeat(c.count)}END`;
        await fx.session.pasteText(text);
        await waitFor(fx, "END");
        expect(fx.session.cursorPosition().col).toBe(2 + 1 + 3);
        await fx.session.sendKeys("Enter");
        await waitFor(fx, "reply-ok");
        expectRunning(fx);
        expect(fx.gateway.requests[0]!.body).toContain(text);
        expectKeptMarks(await replayedRows(fx, "END"), c);
      }
    },
    TIMEOUT,
  );

  test(
    "a model reply with marks keeps fx running and keeps the marks that fit",
    async () => {
      for (const c of cases) {
        const text = `start ${BASE}${c.mark.repeat(c.count)}END`;
        const fx = await startFx([fakeGatewayFinalText(text)]);
        await fx.session.sendText("hello");
        await waitFor(fx, "END");
        expectRunning(fx);
        expect(fx.gateway.requests.length).toBe(1);
        // The composer still takes input after the reply.
        await fx.session.sendLiteralText("after");
        await waitFor(fx, "after");
        expectRunning(fx);
        expectKeptMarks(await replayedRows(fx, "END"), c);
      }
    },
    TIMEOUT,
  );

  test(
    "stress: 5,000 typed marks, a 20,000-mark paste, and a 100,000-mark reply do not end fx",
    async () => {
      const typedCase: Case = { label: "U+0301", mark: "\u0301", count: 5_000 };
      const typed = await startFx([]);
      await typed.session.sendLiteralText(
        `${BASE}${typedCase.mark.repeat(typedCase.count)}END`,
      );
      await waitFor(typed, "END");
      expect(typed.session.cursorPosition().col).toBe(2 + 1 + 3);
      expectRunning(typed);
      expectKeptMarks(await replayedRows(typed, "END"), typedCase);

      // More than 1,000 characters collapse to a placeholder in the composer
      // and expand again on submit, so the whole run reaches the transcript.
      const run = `${BASE}${"\u0301".repeat(20_000)}END`;
      const paste = await startFx([fakeGatewayFinalText("reply-ok")]);
      await paste.session.pasteText(run);
      await waitFor(paste, "[Pasted text #1");
      await paste.session.sendKeys("Enter");
      await waitFor(paste, "reply-ok");
      expectRunning(paste);
      expect(paste.gateway.requests[0]!.body).toContain(run);

      const hugeCase: Case = { label: "U+0301", mark: "\u0301", count: 100_000 };
      const reply = await startFx([
        fakeGatewayFinalText(
          `start ${BASE}${hugeCase.mark.repeat(hugeCase.count)}END`,
        ),
      ]);
      await reply.session.sendText("hello");
      await waitFor(reply, "END");
      expectRunning(reply);
      expectKeptMarks(await replayedRows(reply, "END"), hugeCase);
    },
    TIMEOUT,
  );
});
