// /usage in the TUI against loopback fakes for AI Gateway, ChatGPT (Codex),
// and the Grok CLI proxy. The clock is pinned so day ranges are exact.

import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";
import {
  codexBreakdownBody,
  codexProfileBody,
  codexUsageBody,
  grokBillingBody,
  grokSettingsBody,
  type ReportRow,
  USAGE_NOW_MS,
  usageEnv,
  usageFake,
  type UsageFakeOptions,
  utcDate,
  writeChatGptLogin,
  writeGrokLogin,
  writeUsageClock,
} from "./usage-fakes";

const TIMEOUT = 30_000;
const TODAY = utcDate(USAGE_NOW_MS);

let session: TmuxSession | null = null;
let stop: (() => void) | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  stop?.();
  stop = null;
});

function rows(start: string): ReportRow[] {
  if (start === TODAY) {
    return [{ model: "provider/today", request_count: 2, input_tokens: 10, output_tokens: 5, total_cost: 0.5 }];
  }
  if (start === "2026-10-01") {
    return [{ model: "provider/month", request_count: 4, input_tokens: 40, output_tokens: 8, total_cost: 2 }];
  }
  return [{ model: "provider/week", request_count: 1, input_tokens: 4, output_tokens: 1, total_cost: 0.25 }];
}

function start(prefix: string, options: UsageFakeOptions) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  const home = join(root, "home");
  mkdirSync(home);
  const clock = join(root, "clock");
  writeUsageClock(clock, USAGE_NOW_MS);
  const fake = usageFake(options);
  const gateway = startFakeGateway([], { usage: fake.handler });
  stop = () => {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  };
  const env = {
    ...usageEnv(gateway.baseUrl, clock),
    HOME: realpathSync(home),
    AI_GATEWAY_API_KEY: undefined,
    VERCEL_OIDC_TOKEN: undefined,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_AUTO_UPGRADE: "0",
  };
  return { home, clock, fake, env };
}

describe.skipIf(!tmuxAvailable())("tui: /usage", () => {
  test(
    "an API key's /usage shows AI Gateway's spend by period and model",
    async () => {
      const { fake, env } = start("fx-tui-usage-key-", { report: (from) => rows(from) });
      session = await TmuxSession.create({
        env: { ...env, AI_GATEWAY_API_KEY: "e2e-usage-key" },
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/usage");
      const month = await session.waitForText("model (month)", TIMEOUT);
      expect(month).toContain("usage: API key (AI_GATEWAY_API_KEY)");
      expect(month).toMatch(/today\s+\$0\.5000\s+2\s/);
      expect(month).toMatch(/month\s+\$2\.50\s+6\s/);
      expect(month.indexOf("provider/month")).toBeLessThan(month.indexOf("provider/today"));
      expect(month).not.toContain("provider/week");
      expect(month).toContain("tab period");
      expect(month).toContain("esc close");
      expect(fake.reportRanges()).toEqual([
        `${TODAY}..${TODAY}`,
        "2026-10-06..2026-10-11",
        "2026-10-01..2026-10-11",
      ]);

      await session.sendKeys("Tab");
      const today = await session.waitForText("model (today)", TIMEOUT);
      expect(today).not.toContain("provider/month");
      await session.sendKeys("Tab");
      const week = await session.waitForText("model (7d)", TIMEOUT);
      expect(week).toContain("provider/week");
      expect(week).not.toContain("provider/month");

      // r refreshes at once, inside the one-minute floor, and reads only today.
      await session.sendKeys("r");
      await session.waitForPane(() => fake.reportRanges().length === 4, TIMEOUT);
      expect(fake.reportRanges()[3]).toBe(`${TODAY}..${TODAY}`);

      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
      // Reopening inside the floor shows the cache without reading again.
      await session.sendText("/usage");
      await session.waitForText("model (", TIMEOUT);
      expect(fake.reportRanges()).toHaveLength(4);
      const pane = await session.capturePane();
      expect(pane).not.toContain("e2e-usage-key");
    },
    TIMEOUT * 2,
  );

  test(
    "Codex /usage shows the ChatGPT plan's limits, tokens, and model shares",
    async () => {
      const { home, fake, env } = start("fx-tui-usage-codex-", {
        codex: {
          usage: codexUsageBody(),
          profile: codexProfileBody(),
          breakdown: codexBreakdownBody(),
        },
      });
      writeChatGptLogin(home, "acct_e2e");
      session = await TmuxSession.create({ env: { ...env, FX_PROVIDER: "codex", FX_MODEL: "gpt-5.6-sol" } });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/usage");
      const pane = await session.waitForText("gpt-e2e-large", TIMEOUT);
      expect(pane).toContain("usage: codex (ChatGPT), samdoe");
      expect(pane).toContain("42%");
      expect(pane).toContain("pro");
      expect(pane).toContain("12.40");
      expect(fake.requests.length).toBeGreaterThanOrEqual(3);
      for (const request of fake.requests) {
        expect(request.chatgptAccount).toBe("acct_e2e");
      }
      expect(fake.reportRanges()).toEqual([]);
    },
    TIMEOUT,
  );

  test(
    "Grok /usage shows the plan's weekly allowance, credits, and pay as you go",
    async () => {
      const { home, fake, env } = start("fx-tui-usage-grok-", {
        grok: { billing: grokBillingBody(), settings: grokSettingsBody() },
      });
      writeGrokLogin(home, "acct_grok_e2e");
      session = await TmuxSession.create({ env: { ...env, FX_PROVIDER: "grok", FX_MODEL: "grok-4.20" } });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/usage");
      const pane = await session.waitForText("SuperGrok Heavy", TIMEOUT);
      expect(pane).toContain("usage: grok (xAI)");
      expect(pane).toMatch(/63%\s+in 2d 5h/);
      expect(pane).toContain("$12.50");
      expect(pane).toContain("$3.00 of $100.00");
      expect(pane).toContain("r refresh");
      expect(pane).not.toContain("tab period");
      expect(fake.requests.map((request) => request.path).sort()).toEqual(["/billing", "/settings"]);
      for (const request of fake.requests) {
        expect(request.grokUser).toBe("acct_grok_e2e");
      }
    },
    TIMEOUT,
  );
});
