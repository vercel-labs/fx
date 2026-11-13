// Fakes for fx processes that share one saved login: an issuer that rotates
// the refresh token on every refresh and stops taking older access tokens, a
// model endpoint that takes only the issuer's newest access token, and one
// ordered log of what both saw. tests/e2e/auth-refresh.test.ts asserts on
// them, and tests/tla/drivers/auth/ hands the log to TLC.
//
// The login is the fx login (the Vercel issuer and AI Gateway), or a Codex
// or Grok subscription login (the provider's token endpoint and its
// responses endpoint). Tokens are numbered by the issuer's generation, and
// the saved login starts at generation 0.
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, envWithoutFxHome, providerVersionTestEnv } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  TITLE_GENERATION_MARKER,
  fakeGatewayFinalText,
  fakeResponsesTitleDefault,
  startDynamicFakeGateway,
} from "./tmux-helpers";

/** Whose login the processes share. */
export type SharedProvider = "fx" | "codex" | "grok";

export const sharedAccess = (generation: number) => `shared-access-${generation}`;
export const sharedRefresh = (generation: number) => `shared-refresh-${generation}`;

/** The account every subscription token in these fakes belongs to. */
export const SHARED_SUBSCRIPTION_ACCOUNT = "acct_shared_login";

/** Generation `generation`'s access token for `provider`. */
export function accessTokenFor(provider: SharedProvider, generation: number): string {
  if (provider === "fx") return sharedAccess(generation);
  if (provider === "grok") return `grok-shared-${generation}`;
  // fx reads the Codex account from the token's namespaced claim.
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: SHARED_SUBSCRIPTION_ACCOUNT },
  })).toString("base64url");
  return `header.${payload}.shared-${generation}`;
}

/** Generation `generation`'s refresh token for `provider`. */
export function refreshTokenFor(provider: SharedProvider, generation: number): string {
  return provider === "fx" ? sharedRefresh(generation) : `${provider}-shared-refresh-${generation}`;
}

/** The prompt that names a process, and the answer the model gives it. */
export const sharedAskPrompt = (label: string) => `SHARED_LOGIN_ASK_${label}`;
export const sharedAskAnswer = (label: string) => `SHARED_LOGIN_DONE_${label}`;

const HOUR_MS = 3_600_000;

/** A generation number from any provider's token, or -1 for anything else. */
export function generationOf(token: string): number {
  const match = /^shared-(?:access|refresh)-(\d+)$/.exec(token) ??
    /^(?:codex|grok)-shared-refresh-(\d+)$/.exec(token) ??
    /^grok-shared-(\d+)$/.exec(token) ??
    /^header\.[\w-]+\.shared-(\d+)$/.exec(token);
  return match ? Number(match[1]) : -1;
}

/** One thing the fakes or the harness saw, in the order they saw it. */
export type SharedLoginEvent =
  | { event: "send"; data: { p: string; tok: number } }
  | { event: "answer"; data: { p: string; tok: number; ok: boolean } }
  | { event: "redeem"; data: { rt: number; saved: number } }
  | { event: "issue"; data: { tok: number } }
  | { event: "refuse"; data: { rt: number } }
  | { event: "fail"; data: { rt: number; status: number } }
  | { event: "revoke"; data: { tok: number } }
  | { event: "replace"; data: { tok: number; expired: boolean } }
  | { event: "remove"; data: { none: number } }
  | { event: "kill"; data: { p: string } };

/** Where fx's file store keeps `provider`'s saved login. */
export function authPath(home: string, provider: SharedProvider = "fx"): string {
  const name = provider === "fx" ? "auth.json" : provider === "codex" ? "chatgpt-auth.json" : "grok-auth.json";
  return join(home, ".fx", name);
}

/** The generation the saved login holds, or -1 when there is none or it can't be read. */
export function savedGeneration(home: string, provider: SharedProvider = "fx"): number {
  try {
    return generationOf(JSON.parse(readFileSync(authPath(home, provider), "utf8")).access_token);
  } catch {
    return -1;
  }
}

/**
 * Saves `provider`'s login for `generation` as fx's file store does, renamed
 * into place so an fx reading it never sees half a file. `expiresAtMs`
 * defaults to an hour from now. `refreshGeneration` names the saved refresh
 * token when it differs, as after a refresh that kept the old one.
 */
export function writeSharedLogin(
  home: string,
  issuerUrl: string,
  generation: number,
  expiresAtMs = Date.now() + HOUR_MS,
  provider: SharedProvider = "fx",
  refreshGeneration = generation,
): void {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const staged = join(home, "auth.json.staged");
  const login = provider === "fx"
    ? {
      version: 1,
      issuer: issuerUrl,
      client_id: "test-client",
      access_token: sharedAccess(generation),
      refresh_token: sharedRefresh(refreshGeneration),
      expires_at_ms: expiresAtMs,
      scope: "openid offline_access use:ai-gateway",
      token_type: "Bearer",
      team_id: "team_1",
      team_slug: "example-team",
    }
    : {
      version: 1,
      access_token: accessTokenFor(provider, generation),
      refresh_token: refreshTokenFor(provider, refreshGeneration),
      expires_at_ms: expiresAtMs,
      account_id: SHARED_SUBSCRIPTION_ACCOUNT,
    };
  writeFileSync(staged, JSON.stringify(login) + "\n", { mode: 0o600 });
  chmodSync(staged, 0o600);
  renameSync(staged, authPath(home, provider));
}

export type IssuerOptions = {
  /** Awaited after the issuer redeems a refresh token and before it answers. */
  beforeAnswer?: (index: number) => Promise<void>;
  /** An HTTP status to answer token request `index` with, without redeeming it. */
  failWith?: (index: number) => number | null;
  /** Take the refresh token redeemed last once more, as an issuer with a reuse grace does. */
  reuseGrace?: boolean;
  /** Refuse every refresh, as an issuer that revoked the login does. */
  refuseAll?: boolean;
  /** Leave the refresh token out of the answer, as Codex may; the saved one stays good. */
  keepRefreshToken?: boolean;
};

/** A Codex or Grok SSE reply with `text`. */
function responsesText(text: string): Response {
  return new Response(
    `data: ${JSON.stringify({ type: "response.output_text.delta", delta: text })}\n\n` +
      'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
    { headers: { "content-type": "text/event-stream" } },
  );
}

/**
 * One shared login's world: the saved login in `home`, the issuer, and the
 * model endpoint. `hold(label, attempt)` is awaited before the model endpoint
 * answers request `attempt` (0 for the first) of the process named `label`.
 */
export function startSharedLoginWorld(opts: {
  home: string;
  provider?: SharedProvider;
  issuer?: IssuerOptions;
  hold?: (label: string, attempt: number) => Promise<void> | void;
}) {
  const { home } = opts;
  const provider = opts.provider ?? "fx";
  const issuerOptions = opts.issuer ?? {};
  const events: SharedLoginEvent[] = [];
  /** The refresh token each token request carried. */
  const tokenRequests: string[] = [];
  const revoked = new Set<number>();
  let generation = 0;
  /** The generation of the refresh token the issuer takes next. */
  let liveRefresh = 0;
  let lastRedeemed = -1;
  let loginRevoked = false;

  const refusal = () => provider === "codex"
    ? Response.json({ error: { code: "refresh_token_reused", message: "the refresh token was already used" } }, { status: 401 })
    : Response.json({ error: "invalid_grant" }, { status: 400 });

  /** Redeems the refresh token one token request presented. */
  async function token(body: string): Promise<Response> {
    // fx holds the login's lock and has read the saved login while it waits
    // for this answer, so the file now is what it read.
    const saved = savedGeneration(home, provider);
    let presented = "";
    try {
      presented = String(JSON.parse(body).refresh_token ?? "");
    } catch {
      presented = new URLSearchParams(body).get("refresh_token") ?? "";
    }
    const rt = generationOf(presented);
    const index = tokenRequests.length;
    tokenRequests.push(presented);
    const status = issuerOptions.failWith?.(index) ?? null;
    if (status !== null) {
      events.push({ event: "fail", data: { rt, status } });
      await issuerOptions.beforeAnswer?.(index);
      return new Response("issuer unavailable", { status });
    }
    events.push({ event: "redeem", data: { rt, saved } });
    let rotated = -1;
    if (!issuerOptions.refuseAll && !loginRevoked) {
      if (rt === liveRefresh || (issuerOptions.reuseGrace && rt >= 0 && rt === lastRedeemed)) {
        lastRedeemed = rt;
        generation += 1;
        rotated = generation;
        if (!issuerOptions.keepRefreshToken) liveRefresh = generation;
      } else {
        // A spent refresh token: the issuer revokes the whole login.
        loginRevoked = true;
      }
    }
    if (rotated < 0) events.push({ event: "refuse", data: { rt } });
    else events.push({ event: "issue", data: { tok: rotated } });
    await issuerOptions.beforeAnswer?.(index);
    if (rotated < 0) return refusal();
    const answer: Record<string, unknown> = {
      access_token: accessTokenFor(provider, rotated),
      expires_in: 3600,
      scope: "openid offline_access use:ai-gateway",
      token_type: "Bearer",
    };
    if (!issuerOptions.keepRefreshToken) answer.refresh_token = refreshTokenFor(provider, rotated);
    return Response.json(answer);
  }

  const accepts = (tok: number) => !loginRevoked && tok === generation && !revoked.has(tok);
  const attempts = new Map<string, number>();
  /** Answers one model request that carried `authorization`. */
  async function model(body: string, authorization: string): Promise<Response> {
    const tok = generationOf(authorization.replace(/^Bearer /, ""));
    const label = /SHARED_LOGIN_ASK_(\w+)/.exec(body)?.[1] ?? "unknown";
    const attempt = attempts.get(label) ?? 0;
    attempts.set(label, attempt + 1);
    events.push({ event: "send", data: { p: label, tok } });
    await opts.hold?.(label, attempt);
    const ok = accepts(tok);
    events.push({ event: "answer", data: { p: label, tok, ok } });
    if (ok) return provider === "fx" ? fakeGatewayFinalText(sharedAskAnswer(label)) : responsesText(sharedAskAnswer(label));
    return new Response(JSON.stringify({ error: { message: "the access token is no longer valid" } }), {
      status: 401,
      headers: { "content-type": "application/json" },
    });
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const base = `http://127.0.0.1:${server.port}`;
      if (url.pathname === "/.well-known/openid-configuration") {
        return Response.json({
          issuer: base,
          device_authorization_endpoint: `${base}/oauth/device`,
          token_endpoint: `${base}/oauth/token`,
          revocation_endpoint: `${base}/oauth/revoke`,
        });
      }
      if (url.pathname === "/oauth/token" || url.pathname === "/token") return token(await request.text());
      if (url.pathname === "/v2/teams") {
        return Response.json({ teams: [{ id: "team_1", slug: "example-team", name: "Example Team" }] });
      }
      if (url.pathname === "/userinfo") return Response.json({ sub: SHARED_SUBSCRIPTION_ACCOUNT });
      if (url.pathname === "/models") {
        return Response.json(provider === "codex"
          ? { models: [{ slug: "gpt-5.4-mini", visibility: "list", supported_in_api: true, supported_reasoning_levels: [{ effort: "low" }], additional_speed_tiers: [], input_modalities: ["text"], context_window: 128000 }] }
          : { data: [{ id: "grok-4.20", model: "grok-4.20", api_backend: "responses", context_window: 1_000_000, supports_reasoning_effort: false, reasoning_efforts: [] }] });
      }
      if (url.pathname === "/modalities") {
        return Response.json({ models: [{ id: "grok-4.20", input_modalities: ["text"], output_modalities: ["text"] }] });
      }
      if (url.pathname === "/responses") {
        const body = await request.text();
        if (body.includes(TITLE_GENERATION_MARKER)) return fakeResponsesTitleDefault();
        return model(body, request.headers.get("authorization") ?? "");
      }
      return new Response("not found", { status: 404 });
    },
  });
  const issuerUrl = `http://127.0.0.1:${server.port}`;

  // fx login's model requests go to the gateway; for a subscription it only
  // keeps fx away from the real gateway.
  let gateway: ReturnType<typeof startDynamicFakeGateway>;
  gateway = startDynamicFakeGateway(async (body) => {
    if (provider !== "fx") return new Response("unexpected gateway request", { status: 500 });
    // serveFakeGateway records each request just before it calls this, so
    // the newest record is this one. Read it before the first await.
    const headers = gateway.requests[gateway.requests.length - 1]!.headers;
    return model(body, headers.get("authorization") ?? "");
  });

  writeSharedLogin(home, issuerUrl, 0, undefined, provider);

  return {
    home,
    provider,
    issuerUrl,
    gateway,
    events,
    tokenRequests,
    get generation() {
      return generation;
    },
    /** The model endpoint stops taking `tok`, as it does once another login replaced it. */
    revoke(tok: number) {
      revoked.add(tok);
      events.push({ event: "revoke", data: { tok } });
    },
    /**
     * Another fx's refresh, done outside the processes under test: the
     * issuer rotates, and the new login is saved with `expiresAtMs`.
     */
    replaceOutside(expiresAtMs = Date.now() + HOUR_MS) {
      lastRedeemed = liveRefresh;
      generation += 1;
      liveRefresh = generation;
      writeSharedLogin(home, issuerUrl, generation, expiresAtMs, provider);
      events.push({ event: "replace", data: { tok: generation, expired: expiresAtMs - 60_000 <= Date.now() } });
      return generation;
    },
    /** Signs the login out from outside: the saved login is gone. */
    removeSaved() {
      rmSync(authPath(home, provider), { force: true });
      events.push({ event: "remove", data: { none: 0 } });
    },
    noteKill(label: string) {
      events.push({ event: "kill", data: { p: label } });
    },
    /** The environment for an fx that uses this world's saved login. */
    env(): Record<string, string | undefined> {
      const common = {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      };
      if (provider === "codex") {
        return {
          ...common,
          FX_PROVIDER: "codex",
          FX_MODEL: "gpt-5.4-mini",
          FX_TEST_OPENAI_CODEX_RESPONSES_URL: `${issuerUrl}/responses`,
          FX_TEST_OPENAI_CODEX_MODELS_URL: `${issuerUrl}/models`,
          FX_TEST_CHATGPT_TOKEN_URL: `${issuerUrl}/token`,
        };
      }
      if (provider === "grok") {
        return {
          ...common,
          FX_PROVIDER: "grok",
          FX_MODEL: "grok-4.20",
          FX_TEST_XAI_GROK_RESPONSES_URL: `${issuerUrl}/responses`,
          FX_TEST_XAI_GROK_MODELS_URL: `${issuerUrl}/models`,
          FX_TEST_XAI_GROK_MODALITIES_URL: `${issuerUrl}/modalities`,
          FX_TEST_GROK_TOKEN_URL: `${issuerUrl}/token`,
          FX_TEST_GROK_USERINFO_URL: `${issuerUrl}/userinfo`,
        };
      }
      return { ...common, FX_TEST_OAUTH_ISSUER_URL: issuerUrl, FX_MODEL: FAKE_GATEWAY_MODEL };
    },
    stop() {
      gateway.stop();
      server.stop(true);
    },
  };
}

export type SharedLoginWorld = ReturnType<typeof startSharedLoginWorld>;

/** Resolves on the `count`th call, for every caller. */
export function barrier(count: number): () => Promise<void> {
  let arrived = 0;
  let open = () => {};
  const opened = new Promise<void>((resolve) => {
    open = resolve;
  });
  return () => {
    arrived += 1;
    if (arrived >= count) open();
    return opened;
  };
}

export type SharedAsk = {
  label: string;
  kill: () => void;
  done: Promise<{ code: number | null; stdout: string; stderr: string }>;
};

/**
 * Starts `fx ask --json --no-save` as process `label`, with the environment
 * runFx gives fx, and keeps the handle so a test can kill it. `bin` defaults
 * to this checkout's zig-out/bin/fx.
 */
export function spawnSharedAsk(
  world: SharedLoginWorld,
  label: string,
  extraEnv: Record<string, string> = {},
  bin = FX_BIN,
): SharedAsk {
  if (!existsSync(bin)) throw new Error(`fx binary not found at ${bin}. Run 'zig build' first.`);
  const env: Record<string, string> = {};
  const merged = providerVersionTestEnv({
    ...envWithoutFxHome(process.env),
    NO_COLOR: "1",
    PATH: process.env.PATH ?? "",
    FX_SOUND: "0",
    ...world.env(),
    ...extraEnv,
  });
  for (const [key, value] of Object.entries(merged)) if (value !== undefined) env[key] = value;
  const child = spawn(bin, ["ask", "--json", "--no-save", sharedAskPrompt(label)], {
    env,
    cwd: REPO_ROOT,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stdout: Buffer[] = [];
  const stderr: Buffer[] = [];
  child.stdout.on("data", (d: Buffer) => stdout.push(d));
  child.stderr.on("data", (d: Buffer) => stderr.push(d));
  const done = new Promise<{ code: number | null; stdout: string; stderr: string }>((resolve) => {
    child.on("close", (code) => resolve({ code, stdout: Buffer.concat(stdout).toString(), stderr: Buffer.concat(stderr).toString() }));
  });
  return {
    label,
    kill: () => {
      child.kill("SIGKILL");
    },
    done,
  };
}

/** A small seeded generator, so a run with jitter can be replayed from its seed. */
export function seededRandom(seed: number): () => number {
  let state = seed >>> 0 || 1;
  return () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 0x1_0000_0000;
  };
}
