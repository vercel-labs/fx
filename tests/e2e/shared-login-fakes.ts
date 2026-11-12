// Fakes for fx processes that share one saved fx login: an issuer that
// rotates the refresh token on every refresh and stops taking older access
// tokens, a gateway that takes only the issuer's newest access token, and one
// ordered log of what both saw. tests/e2e/auth-refresh.test.ts asserts on
// them, and tests/tla/drivers/auth/ hands the log to TLC.
//
// Tokens are numbered by the issuer's generation: generation n hands out
// access token `shared-access-n` and refresh token `shared-refresh-n`. The
// saved login starts at generation 0.
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN, REPO_ROOT, envWithoutFxHome } from "../evals/eval-helpers";
import { FAKE_GATEWAY_MODEL, fakeGatewayFinalText, startDynamicFakeGateway } from "./tmux-helpers";

export const sharedAccess = (generation: number) => `shared-access-${generation}`;
export const sharedRefresh = (generation: number) => `shared-refresh-${generation}`;

/** The prompt that names a process, and the answer the gateway gives it. */
export const sharedAskPrompt = (label: string) => `SHARED_LOGIN_ASK_${label}`;
export const sharedAskAnswer = (label: string) => `SHARED_LOGIN_DONE_${label}`;

const HOUR_MS = 3_600_000;

/** A generation number from a token, or -1 for anything else. */
export function generationOf(token: string): number {
  const match = /^shared-(?:access|refresh)-(\d+)$/.exec(token);
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

export function authPath(home: string): string {
  return join(home, ".fx", "auth.json");
}

/** The generation the saved login holds, or -1 when there is none or it can't be read. */
export function savedGeneration(home: string): number {
  try {
    return generationOf(JSON.parse(readFileSync(authPath(home), "utf8")).access_token);
  } catch {
    return -1;
  }
}

/**
 * Saves the login for `generation` as fx's file store does, renamed into
 * place so an fx reading it never sees half a file. `expiresAtMs` defaults to
 * an hour from now.
 */
export function writeSharedLogin(home: string, issuerUrl: string, generation: number, expiresAtMs = Date.now() + HOUR_MS): void {
  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);
  const staged = join(home, "auth.json.staged");
  writeFileSync(
    staged,
    JSON.stringify({
      version: 1,
      issuer: issuerUrl,
      client_id: "test-client",
      access_token: sharedAccess(generation),
      refresh_token: sharedRefresh(generation),
      expires_at_ms: expiresAtMs,
      scope: "openid offline_access use:ai-gateway",
      token_type: "Bearer",
      team_id: "team_1",
      team_slug: "example-team",
    }) + "\n",
    { mode: 0o600 },
  );
  chmodSync(staged, 0o600);
  renameSync(staged, authPath(home));
}

export type IssuerOptions = {
  /** Awaited after the issuer redeems a refresh token and before it answers. */
  beforeAnswer?: (index: number) => Promise<void>;
  /** An HTTP status to answer token request `index` with, without redeeming it. */
  failWith?: (index: number) => number | null;
  /** Take the refresh token redeemed last once more, as an issuer with a reuse grace does. */
  reuseGrace?: boolean;
  /** Refuse every refresh with invalid_grant. */
  refuseAll?: boolean;
};

export type GatewayHold = (label: string) => Promise<void>;

/**
 * One shared login's world: the saved login in `home`, the issuer, and the
 * gateway. `hold(label, attempt)` is awaited before the gateway answers
 * request `attempt` (0 for the first) of the process named `label`.
 */
export function startSharedLoginWorld(opts: {
  home: string;
  issuer?: IssuerOptions;
  hold?: (label: string, attempt: number) => Promise<void> | void;
}) {
  const { home } = opts;
  const issuerOptions = opts.issuer ?? {};
  const events: SharedLoginEvent[] = [];
  /** The refresh token each token request carried. */
  const tokenRequests: string[] = [];
  const revoked = new Set<number>();
  let generation = 0;
  let lastRedeemed = -1;
  let loginRevoked = false;

  const issuer = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const base = `http://127.0.0.1:${issuer.port}`;
      if (url.pathname === "/.well-known/openid-configuration") {
        return Response.json({
          issuer: base,
          device_authorization_endpoint: `${base}/oauth/device`,
          token_endpoint: `${base}/oauth/token`,
          revocation_endpoint: `${base}/oauth/revoke`,
        });
      }
      if (url.pathname === "/oauth/token") {
        // fx holds the login's lock and has read the saved login while it
        // waits for this answer, so the file now is what it read.
        const saved = savedGeneration(home);
        const presented = new URLSearchParams(await request.text()).get("refresh_token") ?? "";
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
          if (rt === generation || (issuerOptions.reuseGrace && rt >= 0 && rt === lastRedeemed)) {
            lastRedeemed = rt;
            generation += 1;
            rotated = generation;
          } else {
            // A spent refresh token: the issuer revokes the whole login.
            loginRevoked = true;
          }
        }
        if (rotated < 0) events.push({ event: "refuse", data: { rt } });
        else events.push({ event: "issue", data: { tok: rotated } });
        await issuerOptions.beforeAnswer?.(index);
        if (rotated < 0) return Response.json({ error: "invalid_grant" }, { status: 400 });
        return Response.json({
          access_token: sharedAccess(rotated),
          refresh_token: sharedRefresh(rotated),
          expires_in: 3600,
          scope: "openid offline_access use:ai-gateway",
          token_type: "Bearer",
        });
      }
      if (url.pathname === "/v2/teams") {
        return Response.json({ teams: [{ id: "team_1", slug: "example-team", name: "Example Team" }] });
      }
      return new Response("not found", { status: 404 });
    },
  });
  const issuerUrl = `http://127.0.0.1:${issuer.port}`;

  const accepts = (tok: number) => !loginRevoked && tok === generation && !revoked.has(tok);
  const attempts = new Map<string, number>();
  let gateway: ReturnType<typeof startDynamicFakeGateway>;
  gateway = startDynamicFakeGateway(async (body) => {
    // serveFakeGateway records each request just before it calls this, so
    // the newest record is this one. Read it before the first await.
    const headers = gateway.requests[gateway.requests.length - 1]!.headers;
    const tok = generationOf((headers.get("authorization") ?? "").replace(/^Bearer /, ""));
    const label = /SHARED_LOGIN_ASK_(\w+)/.exec(body)?.[1] ?? "unknown";
    const attempt = attempts.get(label) ?? 0;
    attempts.set(label, attempt + 1);
    events.push({ event: "send", data: { p: label, tok } });
    await opts.hold?.(label, attempt);
    const ok = accepts(tok);
    events.push({ event: "answer", data: { p: label, tok, ok } });
    if (ok) return fakeGatewayFinalText(sharedAskAnswer(label));
    return new Response(JSON.stringify({ error: { message: "the access token is no longer valid" } }), {
      status: 401,
      headers: { "content-type": "application/json" },
    });
  });

  writeSharedLogin(home, issuerUrl, 0);

  return {
    home,
    issuerUrl,
    gateway,
    events,
    tokenRequests,
    get generation() {
      return generation;
    },
    /** The gateway stops taking `tok`, as it does once another login replaced it. */
    revoke(tok: number) {
      revoked.add(tok);
      events.push({ event: "revoke", data: { tok } });
    },
    /**
     * Another fx's refresh, done outside the processes under test: the
     * issuer rotates, and the new login is saved with `expiresAtMs`.
     */
    replaceOutside(expiresAtMs = Date.now() + HOUR_MS) {
      lastRedeemed = generation;
      generation += 1;
      writeSharedLogin(home, issuerUrl, generation, expiresAtMs);
      events.push({ event: "replace", data: { tok: generation, expired: expiresAtMs - 60_000 <= Date.now() } });
      return generation;
    },
    /** Signs the login out from outside: the saved login is gone. */
    removeSaved() {
      rmSync(authPath(home), { force: true });
      events.push({ event: "remove", data: { none: 0 } });
    },
    noteKill(label: string) {
      events.push({ event: "kill", data: { p: label } });
    },
    /** The environment for an fx that uses this world's saved login. */
    env(): Record<string, string | undefined> {
      return {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_AUTO_UPGRADE: "0",
        FX_TEST_OAUTH_ISSUER_URL: issuerUrl,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
      };
    },
    stop() {
      gateway.stop();
      issuer.stop(true);
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
  const merged: Record<string, string | undefined> = {
    ...envWithoutFxHome(process.env),
    NO_COLOR: "1",
    PATH: process.env.PATH ?? "",
    FX_SOUND: "0",
    ...world.env(),
    ...extraEnv,
  };
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
