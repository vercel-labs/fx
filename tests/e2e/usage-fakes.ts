// Loopback fakes for /usage and `fx usage`. One handler answers every usage
// read fx makes, so a single fake gateway serves chat, models, and usage:
// AI Gateway's /v1/report, the Vercel usage-report budget, ChatGPT's Codex
// usage, and the Grok CLI proxy. Every name and token here is synthetic.

import { chmodSync, mkdirSync, writeFileSync } from "fs";
import { join } from "path";

/** Mon Oct 12 2026 15:30 UTC: the 12th, so the month has finished days. */
export const USAGE_NOW_MS = Date.UTC(2026, 9, 12, 15, 30);
export const DAY_MS = 24 * 60 * 60 * 1000;

export type ReportRow = {
  model: string;
  request_count: number;
  input_tokens: number;
  output_tokens: number;
  total_cost: number;
};

export type UsageRequest = {
  path: string;
  query: URLSearchParams;
  authorization: string | null;
  team: string | null;
  chatgptAccount: string | null;
  grokUser: string | null;
};

type Answer = object | Response;

export type UsageFakeOptions = {
  /** Rows for one `/v1/report` range, by its UTC start and end dates. */
  report?: (start: string, end: string) => ReportRow[] | Response;
  budget?: Answer;
  codex?: { usage?: Answer; profile?: Answer; breakdown?: Answer };
  grok?: { billing?: Answer; settings?: Answer };
};

export function usageFake(options: UsageFakeOptions = {}) {
  const requests: UsageRequest[] = [];
  const reply = (value: Answer | undefined) =>
    value === undefined
      ? new Response("not found", { status: 404 })
      : value instanceof Response
      ? value.clone()
      : Response.json(value);
  const handler = (url: URL, request: Request): Response | null => {
    const routes: Record<string, () => Response> = {
      "/v1/report": () => {
        const rows = options.report?.(
          url.searchParams.get("start_date") ?? "",
          url.searchParams.get("end_date") ?? "",
        ) ?? [];
        return rows instanceof Response ? rows : Response.json({ results: rows });
      },
      "/ai-gateway/usage-report": () => reply(options.budget ?? { users: [] }),
      "/backend-api/wham/usage": () => reply(options.codex?.usage),
      "/backend-api/wham/profiles/me": () => reply(options.codex?.profile),
      "/backend-api/wham/usage/daily-token-usage-breakdown": () =>
        reply(options.codex?.breakdown),
      "/billing": () => reply(options.grok?.billing),
      "/settings": () => reply(options.grok?.settings),
    };
    const route = routes[url.pathname];
    if (!route) return null;
    requests.push({
      path: url.pathname,
      query: url.searchParams,
      authorization: request.headers.get("authorization"),
      team: request.headers.get("x-vercel-ai-gateway-team"),
      chatgptAccount: request.headers.get("chatgpt-account-id"),
      grokUser: request.headers.get("x-userid"),
    });
    return route();
  };
  return {
    handler,
    requests,
    /** The `start..end` range of every `/v1/report` read, in order. */
    reportRanges() {
      return requests
        .filter((request) => request.path === "/v1/report")
        .map((request) =>
          `${request.query.get("start_date")}..${request.query.get("end_date")}`
        );
    },
  };
}

/** Points every usage origin at `baseUrl` and pins `/usage`'s clock. */
export function usageEnv(baseUrl: string, clockFile: string) {
  return {
    FX_GATEWAY_BASE_URL: baseUrl,
    FX_TEST_CHATGPT_ORIGIN: baseUrl,
    FX_TEST_GROK_ORIGIN: baseUrl,
    FX_TEST_USAGE_CLOCK_FILE: clockFile,
    FX_DISABLE_KEYCHAIN: "1",
  };
}

export function writeUsageClock(path: string, ms: number): void {
  writeFileSync(path, `${ms}\n`);
}

/** `2026-10-12` for a time in milliseconds. */
export function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

function writePrivate(home: string, name: string, value: object): void {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const path = join(fxDir, name);
  writeFileSync(path, JSON.stringify(value) + "\n", { mode: 0o600 });
  chmodSync(path, 0o600);
}

export function writeChatGptLogin(home: string, accountId = "acct_e2e"): void {
  const claims = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: accountId },
  })).toString("base64url");
  writePrivate(home, "chatgpt-auth.json", {
    version: 1,
    access_token: `header.${claims}.signature`,
    refresh_token: "chatgpt-refresh",
    expires_at_ms: Date.now() + 60 * 60 * 1000,
    account_id: accountId,
  });
}

export function writeGrokLogin(home: string, accountId = "acct_grok_e2e"): void {
  writePrivate(home, "grok-auth.json", {
    version: 1,
    access_token: "grok-access-e2e",
    refresh_token: "grok-refresh",
    expires_at_ms: Date.now() + 60 * 60 * 1000,
    account_id: accountId,
  });
}

/** A Pro plan: a 5-hour and a weekly window, credits, no spend limit hit. */
export function codexUsageBody(nowMs = USAGE_NOW_MS) {
  const seconds = Math.floor(nowMs / 1000);
  return {
    plan_type: "pro",
    rate_limit: {
      allowed: true,
      limit_reached: false,
      primary_window: {
        used_percent: 42,
        limit_window_seconds: 18_000,
        reset_after_seconds: 7_200,
        reset_at: seconds + 7_200,
      },
      secondary_window: {
        used_percent: 18,
        limit_window_seconds: 604_800,
        reset_after_seconds: 3 * 86_400,
        reset_at: seconds + 3 * 86_400,
      },
    },
    credits: { has_credits: true, unlimited: false, balance: "12.40" },
    spend_control: { reached: false, individual_limit: null },
  };
}

export function codexProfileBody(nowMs = USAGE_NOW_MS) {
  return {
    profile: { username: "samdoe12345", display_name: "samdoe" },
    stats: {
      lifetime_tokens: 9_000_000,
      peak_daily_tokens: 700_000,
      current_streak_days: 4,
      longest_streak_days: 9,
      total_threads: 120,
      longest_running_turn_sec: 5_400,
      fast_mode_usage_percentage: 25,
      most_used_reasoning_effort: "high",
      most_used_reasoning_effort_percentage: 60,
      daily_usage_buckets: [
        { start_date: utcDate(nowMs), tokens: 40_000 },
        { start_date: utcDate(nowMs - DAY_MS), tokens: 60_000 },
      ],
    },
    metadata: { stats_as_of: utcDate(nowMs) },
  };
}

export function codexBreakdownBody(nowMs = USAGE_NOW_MS) {
  return {
    data: [
      {
        date: utcDate(nowMs),
        product_surface_usage_values: { cli: 6, desktop_app: 4 },
        models: [
          { model: "gpt-e2e-large", speed: "fast", credits: 7 },
          { model: "gpt-e2e-small", speed: "standard", credits: 3 },
        ],
      },
    ],
    units: "percent",
    group_by: "day",
  };
}

/** SuperGrok Heavy: 63% of the week, two products, credits, pay as you go. */
export function grokBillingBody(nowMs = USAGE_NOW_MS) {
  const at = (offsetMs: number) => new Date(nowMs + offsetMs).toISOString();
  return {
    config: {
      creditUsagePercent: 63.4,
      currentPeriod: {
        type: "USAGE_PERIOD_TYPE_WEEKLY",
        start: at(-4 * DAY_MS),
        end: at(2 * DAY_MS + 5 * 60 * 60 * 1000),
      },
      productUsage: [
        { product: "PRODUCT_GROK_BUILD", usagePercent: 41.2 },
        { product: "PRODUCT_CHAT", usagePercent: 15.8 },
      ],
      prepaidBalance: { val: -1250 },
      onDemandUsed: { val: 300 },
      onDemandCap: { val: 10000 },
    },
  };
}

export function grokSettingsBody() {
  return {
    subscription_tier: "supergrok_heavy",
    subscription_tier_display: "SuperGrok Heavy",
    on_demand_enabled: true,
  };
}
