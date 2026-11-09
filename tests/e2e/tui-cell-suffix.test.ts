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
// Filling the whole combining pool takes about two billion steps of fx's
// scan for an equal suffix, so the cases that do it get much longer.
const POOL_TIMEOUT = 900_000;
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

// fx keeps the text a cell shows in a pool of at most 65,535 distinct suffixes.
// A character with three marks puts up to three suffixes in it, one for each
// prefix of its marks, so a few tens of thousands of characters with different
// marks fill it. fx then drops the marks it has no room for and keeps running.
const POOL_ENTRIES = 65_535;
const POOL_MARKS = Array.from({ length: 112 }, (_, index) =>
  String.fromCodePoint(0x300 + index),
);

/** `count` characters, each `x`, three marks, and a space; no two share all three marks. */
function poolFillingText(count: number): string {
  const n = POOL_MARKS.length;
  const parts: string[] = [];
  for (let index = 0; index < count; index++) {
    const a = index % n;
    const b = Math.floor(index / n) % n;
    const c = Math.floor(index / (n * n)) % n;
    parts.push(`x${POOL_MARKS[a]}${POOL_MARKS[b]}${POOL_MARKS[c]} `);
  }
  return parts.join("");
}

/** The index of the first character whose third mark has no room, from the suffixes the text adds. */
function firstDroppedCharacter(): number {
  const n = POOL_MARKS.length;
  const seen = new Set<string>();
  for (let index = 0; ; index++) {
    const a = index % n;
    const b = Math.floor(index / n) % n;
    const c = Math.floor(index / (n * n)) % n;
    seen.add(`${a}`);
    seen.add(`${a},${b}`);
    seen.add(`${a},${b},${c}`);
    if (seen.size >= POOL_ENTRIES) return index + 1;
  }
}

/** An fx tape of `frames`, each one write to a terminal of `cols` by `rows` cells. */
function tapeBytes(cols: number, rows: number, frames: string[]): Buffer {
  const version = Buffer.from("cell-suffix-pool");
  const head = Buffer.alloc(5 + 2 + 2 + 8 + 1);
  head.write("FXTP\x01", 0, "binary");
  head.writeUInt16LE(cols, 5);
  head.writeUInt16LE(rows, 7);
  head.writeBigUInt64LE(0n, 9);
  head.writeUInt8(version.length, 17);
  const parts: Buffer[] = [head, version];
  for (const text of frames) {
    const payload = Buffer.from(text, "utf8");
    const header = Buffer.alloc(9);
    header.writeInt32LE(0, 0);
    header.writeUInt8(1, 4);
    header.writeUInt32LE(payload.length, 5);
    parts.push(header, payload);
  }
  return Buffer.concat(parts);
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
    isolated: true,
  });
  const fx = { session, gateway, home, stderrPath, tape };
  running.push(fx);
  await session.waitForComposer(READY_TIMEOUT);
  return fx;
}

/**
 * Waits for `text` on screen, and gives up at once when fx has exited. A
 * failure says whether fx is still alive and what it wrote to stderr.
 */
async function waitFor(fx: Fx, text: string, timeout = READY_TIMEOUT): Promise<void> {
  const deadline = Date.now() + timeout;
  for (;;) {
    try {
      await fx.session.waitForText(text, Math.max(1, Math.min(5_000, deadline - Date.now())));
      return;
    } catch (error) {
      if (fx.session.isAlive() && Date.now() < deadline) continue;
      const stderr = readFileSync(fx.stderrPath, "utf8");
      throw new Error(
        `${JSON.stringify(text)} never showed; fx alive: ${fx.session.isAlive()}; stderr: ${JSON.stringify(stderr)}\n${String(error)}`,
      );
    }
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

  test(
    "stress: a model reply that fills the whole combining pool does not end fx",
    async () => {
      const characters = firstDroppedCharacter() + 3_000;
      const fx = await startFx([
        fakeGatewayFinalText(`start ${poolFillingText(characters)}END`),
      ]);
      await fx.session.sendText("hello");
      await waitFor(fx, "END", POOL_TIMEOUT);
      expectRunning(fx);
      expect(fx.gateway.requests.length).toBe(1);
      // The composer still takes input after the reply. fx keeps drawing the
      // long reply for a while, so the typed text can take that long to show.
      await fx.session.sendLiteralText("after");
      await waitFor(fx, "after", POOL_TIMEOUT);
      expectRunning(fx);
      // fx's own recording of the whole reply replays to the end.
      expect((await replayedRows(fx, "after")).length).toBeGreaterThan(0);
    },
    POOL_TIMEOUT,
  );
});

describe("fx replay: a tape whose characters fill the whole combining pool", () => {
  test(
    "plays to the end, keeps the marks the pool has room for, and drops the rest",
    () => {
      const characters = 54_000;
      const home = mkdtempSync(join(tmpdir(), "fx-cell-suffix-pool-"));
      try {
        const tape = join(home, "pool.fxtape");
        const golden = join(home, "golden.txt");
        writeFileSync(tape, tapeBytes(200, 50, [poolFillingText(characters)]));
        const replay = spawnSync(FX_BIN, ["replay", tape, "--golden", golden], {
          encoding: "utf8",
          timeout: POOL_TIMEOUT - 60_000,
          env: {
            HOME: home,
            FX_HOME: join(home, "fx"),
            PATH: process.env.PATH ?? "/usr/bin:/bin",
            FX_SOUND: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_AUTO_UPGRADE: "0",
          },
        });
        expect(replay.stderr).toBe("");
        expect(replay.status).toBe(0);

        // The characters before the pool filled keep all three marks. Each one
        // after it keeps the two marks whose suffixes were already in the pool
        // and loses the third, which would need an entry of its own.
        const screen = readFileSync(golden, "utf8");
        const counts = [...screen.matchAll(/x([\u0300-\u036f]*)/g)].map(
          (match) => match[1]!.length,
        );
        const withTwo = counts.filter((count) => count === 2).length;
        const withThree = counts.filter((count) => count === 3).length;
        expect(withTwo + withThree).toBe(counts.length);
        expect(withTwo).toBe(characters - firstDroppedCharacter());
        expect(withThree).toBeGreaterThan(0);
      } finally {
        rmSync(home, { recursive: true, force: true });
      }
    },
    POOL_TIMEOUT,
  );
});
