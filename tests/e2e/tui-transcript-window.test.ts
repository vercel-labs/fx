import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { onlySessionId, sessionDir } from "./saved-sessions";

// The shared tmux helper imports eval helpers; do not load repository dotenv files.
process.env.FX_E2E_DISABLE_DOTENV = "1";
const { FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewayFinalText, startFakeGateway, tmuxAvailable } = await import("./tmux-helpers");

const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const TIMEOUT = 30_000;
const NAVIGATION = "full detail · ctrl+o close";
const marker = (n: number) => `WINDOW_C${String(n).padStart(2, "0")}`;
const markers = (count: number) => Array.from({ length: count }, (_, n) => marker(n));
/// About `bytes` of words that never repeat, so every screen of it differs and
/// a page move always changes the pane.
function filler(reply: number, bytes: number): string {
  const words: string[] = [];
  for (let size = 0, n = 0; size < bytes; n += 1) {
    const word = `r${reply}w${n}`;
    words.push(word);
    size += word.length + 1;
  }
  return words.join(" ");
}

type Session = Awaited<ReturnType<typeof TmuxSession.create>>;

async function waitFor(check: () => boolean, what: string, refresh?: () => Promise<void>) {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    await refresh?.();
    if (check()) return;
    await Bun.sleep(50);
  }
  throw new Error(`timed out: ${what}`);
}

function compactions(log: string): number {
  return existsSync(log) ? (readFileSync(log, "utf8").match(/"kind":"compacted"/g) ?? []).length : 0;
}

/// The cycle markers on a page, leaving out the resume notice, which names the
/// session after its first prompt.
function pageMarkers(page: string): string[] {
  const rows = page.split("\n").filter((line) => !line.includes("session resumed:")).join("\n");
  return [...rows.matchAll(/WINDOW_C\d\d/g)].map((match) => match[0]);
}

/// A saved session of `cycles` compaction cycles, two turns each. The first
/// prompt of cycle n carries its marker, and every reply is about
/// `replyBytes` of text ending in "reply <request number>".
async function buildSession(cycles: number, replyBytes: number) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-transcript-window-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);
  // Each cycle takes four requests: two turns and the two a /compact makes.
  const gateway = startFakeGateway(
    Array.from({ length: cycles * 4 + 20 }, (_, index) => fakeGatewayFinalText(`${filler(index, replyBytes)} reply ${index}`)),
  );
  const env: Record<string, string | undefined> = {
    HOME: home,
    TERM: "xterm-256color",
    NO_COLOR: "1",
    AI_GATEWAY_API_KEY: "fake-transcript-window-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_PERMISSION_MODE: "full-access",
    FX_SOUND: "0",
  };
  const session = await TmuxSession.create({ cmd: binary, cwd: workspace, env, width: 200, height: 60, isolated: true });
  await session.waitForComposer(TIMEOUT);
  let log = "";
  for (let n = 0; n < cycles; n += 1) {
    // Two turns a cycle: /compact finds no context after a single turn.
    for (const text of [`${marker(n)} first turn`, `second turn of cycle ${n}`]) {
      // Replies go out in request order, so this turn's reply names `before`.
      const before = gateway.requests.length;
      await session.sendText(text);
      await waitFor(() => gateway.requests.length > before, `the request for ${text}`);
      await session.waitForText(`reply ${before}`, TIMEOUT);
      await session.waitForComposer(TIMEOUT);
    }
    if (n < cycles - 1) {
      log ||= join(sessionDir(home, onlySessionId(home)), "log.jsonl");
      await session.sendText("/compact");
      await waitFor(() => compactions(log) === n + 1, `compaction ${n + 1} in the log`);
      await session.waitForPane((pane) => !/Preparing compaction|Compacting|Stopping compaction/.test(pane), TIMEOUT);
      await session.waitForComposer(TIMEOUT);
    }
  }
  return { session, gateway, home, workspace, env };
}

/// Sends one key and returns the pane once it changes, or after 3 s.
async function press(session: Session, key: string, before: string): Promise<{ pane: string; moved: boolean }> {
  const deadline = Date.now() + 3_000;
  await session.sendKeys(key);
  while (Date.now() < deadline) {
    const pane = await session.capturePane();
    if (pane !== before) return { pane, moved: true };
    await Bun.sleep(10);
  }
  return { pane: await session.capturePane(), moved: false };
}

/// Opens Ctrl+O, pages up until three presses move nothing, closes it, and
/// returns each cycle marker in the order it first appeared.
async function walkUp(session: Session): Promise<string[]> {
  await session.sendHexBytes(["0f"]);
  await session.waitForText(NAVIGATION, TIMEOUT);
  let pane = await session.capturePane();
  const seen: string[] = [];
  const note = (page: string) => {
    for (const found of pageMarkers(page)) if (!seen.includes(found)) seen.push(found);
  };
  // Markers on one page show oldest first; newest-first order across pages
  // comes from reading each page bottom up.
  const noteBottomUp = (page: string) => note(page.split("\n").reverse().join("\n"));
  noteBottomUp(pane);
  for (let stuck = 0, presses = 0; stuck < 3 && presses < 1_000; presses += 1) {
    const step = await press(session, "PageUp", pane);
    stuck = step.moved ? 0 : stuck + 1;
    pane = step.pane;
    noteBottomUp(pane);
  }
  await session.sendHexBytes(["0f"]);
  await session.waitForComposer(TIMEOUT);
  return seen;
}

describe.skipIf(!tmuxAvailable())("tui: transcript window", () => {
  test(
    "Ctrl+O reaches every cycle of a session past 1 MiB of text, and a resume holds only the newest",
    async () => {
      // Six cycles of two 100 KB replies: past the 1 MiB the main screen used
      // to keep, so the oldest cycle is only in the session log.
      const cycles = 6;
      const built = await buildSession(cycles, 100_000);
      let session: Session | null = built.session;
      try {
        expect(await walkUp(session)).toEqual(markers(cycles).reverse());

        const id = onlySessionId(built.home);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        await session.kill();
        session = await TmuxSession.create({
          cmd: `${binary} --resume ${id}`, cwd: built.workspace, env: built.env, width: 200, height: 60, isolated: true,
        });
        await session.waitForComposer(TIMEOUT);
        // The newest cycle's first prompt is far above the screen: read the
        // whole scrollback once the resume has replayed it.
        let scrollback = "";
        const resumed = session;
        await waitFor(() => pageMarkers(scrollback).includes(marker(cycles - 1)), "the resumed cycle in scrollback", async () => {
          scrollback = await resumed.captureFullScrollback();
        });
        expect([...new Set(pageMarkers(scrollback))]).toEqual([marker(cycles - 1)]);
        expect(await walkUp(session)).toEqual(markers(cycles).reverse());
      } finally {
        await session?.kill();
        built.gateway.stop();
      }
    },
    300_000,
  );
});
