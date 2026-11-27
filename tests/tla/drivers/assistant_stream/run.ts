// One reply on a terminal: `fx ask` runs against a held fake gateway. Each piece
// is sent, then the screen is read once it has stopped changing. The history is
// captured after every piece and after the end of the stream.
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers } from "../lib/context";
import { styleOfWord, type Calibration } from "./screen";

// A prompt without letters: fx infers no expected response language from it
// (response_language.infer_expectation), so the reply is not held until five
// Latin letters arrive. That hold is a product rule outside StreamTail.tla.
const PROMPT = "1234";
const TIMEOUT_MS = 30_000;
const POLL_MS = 50;
// A piece is settled when the pane has not changed for QUIET_MS, and no later
// than SETTLE_CAP_MS after it was sent.
const QUIET_MS = 200;
const SETTLE_CAP_MS = 3_000;
export const PANE_HEIGHT = 40;
// Lines that change while fx works: the spinner and the token counters.
const FOOTER = /Generating|↑/;
const CALIBRATION_REPLY = "Plain words here.\n\n**Calibration** bold line.\n\nTitle\n===\n\nDone.\n";

type TmuxLike = {
  captureFullScrollbackEscapes(): Promise<string>;
  waitForText(pattern: string, timeoutMs: number): Promise<string>;
  kill(): Promise<void>;
};

export type Streamed = { captures: string[]; stderr: string };

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function askCommand(): string {
  const fx = [binary, "ask", "--auto", "--no-save", PROMPT].map(shellQuote).join(" ");
  const script = `${fx}; code=$?; printf '\\n__FX_EXIT_%s__\\n' "$code"; exit "$code"`;
  return `/bin/sh -c ${shellQuote(script)}`;
}

const stableText = (capture: string) => capture.split("\n").filter((line) => !FOOTER.test(line)).join("\n");

// Polls the pane until it has been unchanged for QUIET_MS (the same condition as
// waitForStableGrid, which needs an expected grid this driver does not have).
async function settle(session: TmuxLike): Promise<string> {
  const start = Date.now();
  let capture = await session.captureFullScrollbackEscapes();
  let text = stableText(capture);
  let changedAt = start;
  while (Date.now() - start < SETTLE_CAP_MS) {
    await Bun.sleep(POLL_MS);
    capture = await session.captureFullScrollbackEscapes();
    const next = stableText(capture);
    if (next !== text) {
      text = next;
      changedAt = Date.now();
    } else if (Date.now() - changedAt >= QUIET_MS) {
      return capture;
    }
  }
  throw new Error(`the pane kept changing for ${SETTLE_CAP_MS} ms`);
}

/** Streams `pieces` as one reply and returns the history after each piece and after the end. */
export async function streamReply(pieces: string[]): Promise<Streamed> {
  const { startFakeGateway, heldFakeGatewayFinalText, FAKE_GATEWAY_MODEL, TmuxSession } = await targetHelpers();
  const root = mkdtempSync(join(tmpdir(), "fx-assistant-stream-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  writeFileSync(stderrPath, "");

  const held = heldFakeGatewayFinalText();
  const gateway = startFakeGateway([() => held.response]);
  let session: TmuxLike | undefined;
  try {
    session = await TmuxSession.create({
      isolated: true,
      cmd: askCommand(),
      cwd: realpathSync(workspace),
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-assistant-stream-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "auto",
        FX_SOUND: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        NO_COLOR: undefined,
      },
      width: 120,
      height: 40,
      remainOnExit: true,
      stderrPath,
    });
    const captures: string[] = [];
    for (const piece of pieces) {
      held.send(piece);
      captures.push(await settle(session));
    }
    held.release("");
    await session.waitForText("__FX_EXIT_0__", TIMEOUT_MS);
    captures.push(await session.captureFullScrollbackEscapes());
    return { captures, stderr: readFileSync(stderrPath, "utf8") };
  } finally {
    await session?.kill();
    gateway.stop();
    held.dispose();
    rmSync(root, { recursive: true, force: true });
  }
}

/** Reads the style of the plain, bold and heading words of a reply that shows all three. */
export async function calibrate(): Promise<Calibration> {
  const { captures } = await streamReply([CALIBRATION_REPLY]);
  const capture = captures.at(-1)!;
  const plain = styleOfWord(capture, "Plain");
  const bold = styleOfWord(capture, "Calibration");
  const heading = styleOfWord(capture, "Title");
  if (!plain || !bold || !heading) {
    throw new Error(`calibration: the reply words are not all on screen:\n${capture}`);
  }
  if (plain.bold || !bold.bold) {
    throw new Error(`calibration: bold is not drawn as bold (plain ${plain.key}, bold ${bold.key})`);
  }
  if (heading.key === plain.key || heading.key === bold.key) {
    throw new Error(`calibration: the heading style (${heading.key}) is the same as plain or bold text`);
  }
  return { headingKey: heading.key };
}
