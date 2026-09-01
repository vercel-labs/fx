import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const roots: string[] = [];
const gateways: Array<{ stop(): void }> = [];
const sessions: TmuxSession[] = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

test.skipIf(!tmuxAvailable())("interactive session reveals only the generated title", async () => {
  const root = mkdtempSync(join(tmpdir(), "fx-e2e-session-title-"));
  roots.push(root);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(home);
  mkdirSync(workspace);

  let releaseTitle!: () => void;
  const titleGate = new Promise<void>((resolve) => {
    releaseTitle = resolve;
  });
  const gateway = startDynamicFakeGateway(async (body) => {
    if (body.includes("Generate a brief title that helps the user")) {
      await titleGate;
      return fakeGatewayFinalText("Generate session titles");
    }
    return fakeGatewayFinalText("I can help with that.");
  });
  gateways.push(gateway);

  const session = await TmuxSession.create({
    isolated: true,
    cmd: FX_BIN,
    cwd: realpathSync(workspace),
    env: {
      HOME: realpathSync(home),
      AI_GATEWAY_API_KEY: "fake-session-title-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_E2E_DISABLE_SESSION_TITLE_GENERATION: undefined,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    },
  });
  sessions.push(session);

  await session.waitForComposer(TIMEOUT);
  await session.sendText("/statusline session");
  await session.waitForComposer(TIMEOUT);
  const prompt = "please add automatic naming for saved conversations";
  await session.sendText(prompt);
  await session.waitForText("I can help with that.", TIMEOUT);
  const footer = (await session.capturePaneGrid()).slice(-4).join("\n");
  expect(footer).not.toContain(prompt);

  releaseTitle();
  await session.waitForText("Generate session titles", TIMEOUT);
  await session.sendText("/quit");
  expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);

  const sessionsDir = join(home, ".fx", "sessions");
  const entries = Array.from(new Bun.Glob("*/display.json").scanSync(sessionsDir));
  expect(entries).toHaveLength(1);
  const display = JSON.parse(readFileSync(join(sessionsDir, entries[0]!), "utf8"));
  expect(display.title).toBe("Generate session titles");
}, TIMEOUT);
