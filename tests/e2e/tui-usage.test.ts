// /usage in the TUI against loopback fakes for AI Gateway, ChatGPT (Codex),
// and the Grok CLI proxy. The clock is pinned so day ranges are exact.

import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startFakeGateway, TmuxSession, tmuxAvailable } from "./tmux-helpers";
import { rotateFxLogin, startFakeIssuer, writeFxLogin } from "./fx-login-fakes";
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
      const month = await session.waitForText("Usage 2  today  7d  [month]", TIMEOUT);
      expect(month).toContain("  model");
      expect(month).toMatch(/today\s+\$0\.5000\s+2\s/);
      expect(month).toMatch(/month\s+\$2\.50\s+6\s/);
      expect(month.indexOf("provider/month")).toBeLessThan(month.indexOf("provider/today"));
      expect(month).not.toContain("provider/week");
      expect(month).toContain("tab period");
      expect(month).toContain("ctrl+r refresh");
      expect(month).toContain("esc close");
      expect(fake.reportRanges()).toEqual([
        `${TODAY}..${TODAY}`,
        "2026-10-06..2026-10-11",
        "2026-10-01..2026-10-11",
      ]);

      await session.sendKeys("Tab");
      const today = await session.waitForText("Usage 1  [today]  7d  month", TIMEOUT);
      expect(today).not.toContain("provider/month");
      await session.sendKeys("Tab");
      const week = await session.waitForText("Usage 2  today  [7d]  month", TIMEOUT);
      expect(week).toContain("provider/week");
      expect(week).not.toContain("provider/month");

      // ctrl+r refreshes at once, inside the one-minute floor, and reads only today.
      await session.sendHexBytes(["12"]);
      await session.waitForPane(() => fake.reportRanges().length === 4, TIMEOUT);
      expect(fake.reportRanges()[3]).toBe(`${TODAY}..${TODAY}`);

      await session.sendKeys("Escape");
      await session.waitForPane(async () => !(await session!.capturePane()).includes("tab period"), TIMEOUT);
      // Reopening inside the floor shows the cache without reading again.
      await session.sendText("/usage");
      await session.waitForText("Usage 2  today  [7d]  month", TIMEOUT);
      expect(fake.reportRanges()).toHaveLength(4);
      const pane = await session.capturePane();
      expect(pane).not.toContain("e2e-usage-key");
    },
    TIMEOUT * 2,
  );

  test(
    "an fx login's /usage refused for a token another fx replaced reads again with the newer stored login",
    async () => {
      const issuer = startFakeIssuer({ refresh: () => "unexpected-refresh" });
      let usage: ReturnType<typeof usageFake> | undefined;
      const { home, fake, env } = start("fx-tui-usage-renewed-", {
        // The fake records each request before it answers.
        report: (from) => usage?.requests.at(-1)?.authorization === "Bearer launch-token"
          ? Response.json({ error: { message: "token expired" } }, { status: 401 })
          : rows(from),
      });
      usage = fake;
      const stopGateway = stop;
      stop = () => {
        stopGateway?.();
        issuer.stop();
      };
      writeFxLogin(home, issuer.issuerUrl, "launch-token");
      session = await TmuxSession.create({
        env: { ...env, FX_TEST_OAUTH_ISSUER_URL: issuer.issuerUrl, FX_OAUTH_CLIENT_ID: "test-client", FX_NO_OPEN_BROWSER: "1" },
      });
      await session.waitForComposer(TIMEOUT);
      // Another fx renews the shared login after this one read it.
      rotateFxLogin(home, "rotated-token");
      await session.sendText("/usage");
      const month = await session.waitForText("Usage 2  today  7d  [month]", TIMEOUT);
      expect(month).toMatch(/month\s+\$2\.50\s+6\s/);
      expect(fake.requests.filter((request) => request.path === "/v1/report").map((request) => request.authorization)).toEqual([
        "Bearer launch-token",
        "Bearer rotated-token",
        "Bearer rotated-token",
        "Bearer rotated-token",
      ]);
      expect(issuer.refreshes).toHaveLength(0);
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
      expect(pane).toContain("Usage 2  today  7d  [month]");
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
      expect(pane).toContain("Usage 2");
      expect(pane).toMatch(/63%\s+in 2d 5h/);
      expect(pane).toContain("$12.50");
      expect(pane).toContain("$3.00 of $100.00");
      expect(pane).toContain("ctrl+r refresh");
      expect(pane).not.toContain("tab period");
      expect(fake.requests.map((request) => request.path).sort()).toEqual(["/billing", "/settings"]);
      for (const request of fake.requests) {
        expect(request.grokUser).toBe("acct_grok_e2e");
      }
    },
    TIMEOUT,
  );

  test(
    "/usage shows catalog header, composer search, ctrl+r refresh, and Esc order at 80 and 50 columns",
    async () => {
      const monthModels: ReportRow[] = [
        { model: "anthropic/claude-opus-4-6", request_count: 18, input_tokens: 120_000, output_tokens: 24_000, total_cost: 4.82 },
        { model: "openai/gpt-5", request_count: 14, input_tokens: 95_000, output_tokens: 18_000, total_cost: 2.65 },
        { model: "anthropic/claude-sonnet-4-5", request_count: 22, input_tokens: 180_000, output_tokens: 32_000, total_cost: 1.94 },
        { model: "openai/gpt-5-pro", request_count: 4, input_tokens: 28_000, output_tokens: 6_200, total_cost: 1.48 },
        { model: "google/gemini-2.5-pro", request_count: 9, input_tokens: 64_000, output_tokens: 11_000, total_cost: 0.72 },
        { model: "xai/grok-4", request_count: 6, input_tokens: 41_000, output_tokens: 7_500, total_cost: 0.54 },
        { model: "deepseek/deepseek-r1", request_count: 8, input_tokens: 55_000, output_tokens: 14_000, total_cost: 0.31 },
        { model: "meta/llama-4-maverick", request_count: 5, input_tokens: 30_000, output_tokens: 4_800, total_cost: 0.19 },
        { model: "mistral/mistral-large", request_count: 3, input_tokens: 19_000, output_tokens: 3_100, total_cost: 0.14 },
        { model: "cohere/command-a", request_count: 2, input_tokens: 12_000, output_tokens: 2_000, total_cost: 0.09 },
        { model: "qwen/qwen3-coder", request_count: 4, input_tokens: 24_000, output_tokens: 5_400, total_cost: 0.07 },
        { model: "perplexity/sonar-pro", request_count: 2, input_tokens: 8_000, output_tokens: 1_200, total_cost: 0.05 },
        { model: "moonshot/kimi-k2", request_count: 1, input_tokens: 6_000, output_tokens: 900, total_cost: 0.03 },
        { model: "minimax/minimax-m1", request_count: 1, input_tokens: 4_000, output_tokens: 600, total_cost: 0.02 },
      ];
      const todayModels: ReportRow[] = [
        { model: "anthropic/claude-opus-4-6", request_count: 3, input_tokens: 20_000, output_tokens: 4_000, total_cost: 0.80 },
        { model: "openai/gpt-5", request_count: 2, input_tokens: 12_000, output_tokens: 2_200, total_cost: 0.35 },
      ];
      const weekModels: ReportRow[] = [
        { model: "anthropic/claude-opus-4-6", request_count: 10, input_tokens: 70_000, output_tokens: 14_000, total_cost: 2.80 },
        { model: "openai/gpt-5", request_count: 8, input_tokens: 50_000, output_tokens: 9_000, total_cost: 1.40 },
        { model: "openai/gpt-5-pro", request_count: 2, input_tokens: 14_000, output_tokens: 3_000, total_cost: 0.70 },
      ];
      const { fake, env } = start("fx-tui-usage-search-", {
        report: (from) => from === TODAY ? todayModels : from === "2026-10-01" ? monthModels : weekModels,
      });
      session = await TmuxSession.create({
        env: { ...env, AI_GATEWAY_API_KEY: "e2e-usage-key", FX_THEME: "dark" },
        width: 80,
        height: 34,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/usage");
      const pane80 = await session.waitForText("Usage 14  today  7d  [month]", TIMEOUT);
      expect(pane80).toContain("4 more");
      expect(pane80).toContain("↑↓ navigate     tab period     enter detail     ctrl+r refresh     esc close");
      expect(pane80).not.toContain("❯");

      await session.sendHexBytes(["6f", "70"]);
      const filtered80 = await session.waitForText("Usage 4  today  7d  [month]", TIMEOUT);
      expect(filtered80).toContain("┃ op");
      expect(filtered80).toContain("anthropic/claude-opus-4-6");
      expect(filtered80).toContain("openai/gpt-5");
      expect(filtered80).toContain("anthropic/claude-sonnet-4-5");
      expect(filtered80).toContain("openai/gpt-5-pro");
      expect(filtered80).not.toContain("4 more");

      await session.resizeWindow(50, 34, 400);
      const filtered50 = await session.waitForText("↑↓ move  tab period  enter detail  ctrl+r  esc", TIMEOUT);
      expect(filtered50).toContain("Usage 4  today  7d  [month]");
      expect(filtered50).toContain("┃ op");

      await session.sendKeys("Down");
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      const detail = await session.waitForText("model 3 of 4", TIMEOUT);
      expect(detail).toContain("perf");

      const beforeReload = fake.reportRanges().length;
      await session.sendHexBytes(["12"]);
      await session.waitForPane(() => fake.reportRanges().length > beforeReload, TIMEOUT);

      // Esc 1: clear query while staying in detail
      await session.sendKeys("Escape");
      await session.waitForText("3 of 14", TIMEOUT);
      // Esc 2: leave detail back to table
      await session.sendKeys("Escape");
      await session.waitForText("Usage 14  today  7d  [month]", TIMEOUT);
      // Esc 3: close /usage
      await session.sendKeys("Escape");
      await session.waitForPane(async () => !(await session!.capturePane()).includes("Usage 14"), TIMEOUT);
    },
    TIMEOUT * 2,
  );
});
