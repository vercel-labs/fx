import { spawn } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  watch,
  writeFileSync,
  type FSWatcher,
} from "node:fs";
import { join } from "node:path";
import { testEnvironment, worktree } from "../lib/context";
import type { GeminiAuthEvent } from "./trace";

export const CLIENT_ID = "test-google-client-id";
export const CLIENT_SECRET = "test-google-client-secret";
export const SUBJECT = "sub-gemini-auth-1";
export const EMAIL = "ultra@example.com";
export const MODEL = "gemini-4-hydrogen";
export const REQUIRED_SCOPE = "https://www.googleapis.com/auth/generative-language.peruserquota";

const HOUR_S = 3600;
const WEEK_S = 7 * 24 * 3600;

export const accessToken = (gen: number) => `ya29.gemini-access-${gen}`;
export const refreshToken = (gen: number) => `1//gemini-refresh-${gen}`;
export const nonceValue = (n: number) => (n >= 0 ? `nonce-${n}` : null);

// Valid 32-byte non-zero P-256 scalar encoded as base64url (43 chars).
export const TEST_DPOP_PRIVATE_KEY = Buffer.alloc(32, 0x42).toString("base64url");

export function generationOfAccess(token: string | null | undefined): number {
  const m = /^ya29\.gemini-access-(\d+)$/.exec(token ?? "");
  return m ? Number(m[1]) : -1;
}

export function generationOfRefresh(token: string | null | undefined): number {
  const m = /^1\/\/gemini-refresh-(\d+)$/.exec(token ?? "");
  return m ? Number(m[1]) : -1;
}

export function generationOfNonce(nonce: string | null | undefined): number {
  const m = /^nonce-(\d+)$/.exec(nonce ?? "");
  return m ? Number(m[1]) : -1;
}

export function googleAuthPath(home: string): string {
  return join(home, ".fx", "google-auth.json");
}

export type SeedLoginOptions = {
  accessGen?: number;
  refreshGen?: number;
  nonce?: number | null;
  accessExpiresAtS?: number;
  refreshExpiresAtS?: number;
};

export function writeGoogleAuth(home: string, opts: SeedLoginOptions = {}): void {
  const nowS = Math.floor(Date.now() / 1000);
  const accessGen = opts.accessGen ?? 0;
  const refreshGen = opts.refreshGen ?? 0;
  const nonce = opts.nonce === undefined ? 0 : opts.nonce;
  const accessExpiresAtS = opts.accessExpiresAtS ?? nowS + HOUR_S;
  const refreshExpiresAtS = opts.refreshExpiresAtS ?? nowS + WEEK_S;

  const fxDir = join(home, ".fx");
  mkdirSync(fxDir, { recursive: true, mode: 0o700 });
  chmodSync(fxDir, 0o700);

  const account: Record<string, unknown> = {
    subject: SUBJECT,
    email: EMAIL,
    client_id: CLIENT_ID,
    refresh_token: refreshToken(refreshGen),
    refresh_token_expires_at_s: refreshExpiresAtS,
    access_token: accessToken(accessGen),
    access_token_expires_at_s: accessExpiresAtS,
    dpop_private_key: TEST_DPOP_PRIVATE_KEY,
    granted_scopes: ["openid", REQUIRED_SCOPE],
  };
  if (nonce !== null) {
    account.dpop_nonce = nonceValue(nonce);
  }

  const record = {
    schema_version: 1,
    active_account_sub: SUBJECT,
    accounts: {
      [SUBJECT]: account,
    },
  };

  const staged = join(fxDir, "google-auth.json.staged");
  writeFileSync(staged, `${JSON.stringify(record)}\n`, { mode: 0o600 });
  chmodSync(staged, 0o600);
  renameSync(staged, googleAuthPath(home));
}

export function readGoogleAuthDisk(home: string): { access: number; rt: number; nonce: number } | null {
  try {
    const raw = readFileSync(googleAuthPath(home), "utf8");
    const parsed = JSON.parse(raw) as {
      active_account_sub?: string;
      accounts?: Record<string, { access_token?: string; refresh_token?: string; dpop_nonce?: string }>;
    };
    const sub = parsed.active_account_sub;
    if (!sub || !parsed.accounts?.[sub]) return null;
    const acct = parsed.accounts[sub]!;
    return {
      access: generationOfAccess(acct.access_token),
      rt: generationOfRefresh(acct.refresh_token),
      nonce: generationOfNonce(acct.dpop_nonce),
    };
  } catch {
    return null;
  }
}

function decodeJwtPayload(jwt: string): Record<string, unknown> {
  const parts = jwt.split(".");
  if (parts.length !== 3) return {};
  try {
    const padded = parts[1]!.replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(Buffer.from(padded, "base64").toString("utf8")) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function geminiTextSse(text: string, interactionId: string): Response {
  const events: Array<[string, unknown]> = [
    [
      "interaction.created",
      {
        event_type: "interaction.created",
        interaction: { id: interactionId, status: "in_progress", object: "interaction", model: MODEL },
      },
    ],
    ["step.start", { event_type: "step.start", index: 0, step: { type: "model_output" } }],
    ["step.delta", { event_type: "step.delta", index: 0, delta: { type: "text", text } }],
    ["step.stop", { event_type: "step.stop", index: 0 }],
    [
      "interaction.completed",
      {
        event_type: "interaction.completed",
        interaction: { id: interactionId, status: "completed", usage: { total_input_tokens: 8, total_output_tokens: 4 } },
      },
    ],
    ["done", "[DONE]"],
  ];
  const body = events
    .map(([name, data]) => `event: ${name}\ndata: ${typeof data === "string" ? data : JSON.stringify(data)}\n\n`)
    .join("");
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

export type TokenRequestContext = {
  label: string;
  index: number;
  rt: number;
  nonce: number;
  serverNonce: number;
  signal: AbortSignal;
};

export type TokenAction =
  | { kind: "auto" }
  | { kind: "use_dpop_nonce"; nonce: number }
  | { kind: "invalid_grant" }
  | { kind: "fail"; status: number }
  | { kind: "stall" }
  | { kind: "ok"; nonceHeader?: number | null }
  | { kind: "ok_hold_after_200"; on200Started: (closeStream: () => void) => void; nonceHeader?: number | null };

export type WorldOptions = {
  home: string;
  seed?: SeedLoginOptions;
  rotatesRefresh?: boolean;
  initialServerNonce?: number;
  rotateNonceOn200?: boolean;
  onTokenRequest?: (ctx: TokenRequestContext) => Promise<TokenAction> | TokenAction;
  holdApi?: (label: string, attempt: number, access: number) => Promise<void | "drop"> | void | "drop";
};

export type RecordedTokenRequest = {
  label: string;
  rt: number;
  nonce: number;
  dpopHtu: string | null;
  dpopHtm: string | null;
};

export function startFakeGoogleWorld(opts: WorldOptions) {
  const { home } = opts;
  const rotatesRefresh = opts.rotatesRefresh ?? true;
  const rotateNonceOn200 = opts.rotateNonceOn200 ?? true;
  const events: GeminiAuthEvent[] = [];
  const tokenRequests: RecordedTokenRequest[] = [];
  const openControllers = new Set<ReadableStreamDefaultController<Uint8Array>>();
  const revokedAccess = new Set<number>();
  const spentRefresh = new Set<number>();

  let accessGen = opts.seed?.accessGen ?? 0;
  let refreshGen = opts.seed?.refreshGen ?? 0;
  let liveRefresh = refreshGen;
  let serverNonce = opts.initialServerNonce ?? (opts.seed?.nonce ?? 0);
  let loginRevoked = false;
  let signedOut = false;
  let invalidGrantPending = false;
  let logoutPending = false;

  writeGoogleAuth(home, opts.seed);
  let lastDisk = readGoogleAuthDisk(home);

  function syncDiskState(): void {
    const current = readGoogleAuthDisk(home);
    if (current === null) {
      if (lastDisk !== null) {
        lastDisk = null;
        if (logoutPending && !invalidGrantPending) {
          signedOut = true;
          events.push({ event: "sign_out", data: { none: 0 } });
        } else {
          invalidGrantPending = false;
          events.push({ event: "clear", data: { none: 0 } });
        }
      }
      return;
    }
    if (
      lastDisk === null ||
      current.access !== lastDisk.access ||
      current.rt !== lastDisk.rt ||
      current.nonce !== lastDisk.nonce
    ) {
      lastDisk = current;
      invalidGrantPending = false;
      events.push({ event: "save", data: { access: current.access, rt: current.rt, nonce: current.nonce } });
    }
  }

  let watcher: FSWatcher | null = null;
  try {
    watcher = watch(join(home, ".fx"), (_eventType, filename) => {
      if (!filename || filename === "google-auth.json") {
        syncDiskState();
      }
    });
  } catch {
    watcher = null;
  }

  const apiAttempts = new Map<string, number>();

  async function handleToken(request: Request, label: string): Promise<Response> {
    syncDiskState();
    const rawBody = await request.text();
    const form = new URLSearchParams(rawBody);
    const rt = generationOfRefresh(form.get("refresh_token"));
    const dpopRaw = request.headers.get("dpop") ?? "";
    const dpopPayload = dpopRaw ? decodeJwtPayload(dpopRaw) : {};
    const nonce = generationOfNonce(typeof dpopPayload.nonce === "string" ? dpopPayload.nonce : null);
    const dpopHtu = typeof dpopPayload.htu === "string" ? dpopPayload.htu : null;
    const dpopHtm = typeof dpopPayload.htm === "string" ? dpopPayload.htm : null;

    const index = tokenRequests.length;
    tokenRequests.push({ label, rt, nonce, dpopHtu, dpopHtm });
    events.push({ event: "token_req", data: { p: label, rt, nonce } });

    const action: TokenAction = (await opts.onTokenRequest?.({
      label,
      index,
      rt,
      nonce,
      serverNonce,
      signal: request.signal,
    })) ?? { kind: "auto" };

    if (action.kind === "stall") {
      return await new Promise<Response>((resolve) => {
        const onAbort = () => {
          events.push({ event: "token_fail", data: { p: label, status: 0 } });
          resolve(new Response(null, { status: 499 }));
        };
        if (request.signal.aborted) {
          onAbort();
          return;
        }
        request.signal.addEventListener("abort", onAbort, { once: true });
      });
    }

    if (action.kind === "fail") {
      events.push({ event: "token_fail", data: { p: label, status: action.status } });
      return new Response("issuer unavailable", { status: action.status });
    }

    if (action.kind === "use_dpop_nonce") {
      serverNonce = action.nonce;
      events.push({ event: "token_nonce", data: { p: label, nonce: action.nonce } });
      return Response.json(
        { error: "use_dpop_nonce" },
        { status: 400, headers: { "DPoP-Nonce": nonceValue(action.nonce)! } },
      );
    }

    if (action.kind === "invalid_grant") {
      loginRevoked = true;
      invalidGrantPending = true;
      events.push({ event: "token_invalid_grant", data: { p: label } });
      return Response.json({ error: "invalid_grant" }, { status: 400 });
    }

    if (action.kind === "auto") {
      if (loginRevoked || (rotatesRefresh && spentRefresh.has(rt)) || rt !== liveRefresh) {
        loginRevoked = true;
        invalidGrantPending = true;
        events.push({ event: "token_invalid_grant", data: { p: label } });
        return Response.json({ error: "invalid_grant" }, { status: 400 });
      }
      if (nonce !== serverNonce) {
        events.push({ event: "token_nonce", data: { p: label, nonce: serverNonce } });
        return Response.json(
          { error: "use_dpop_nonce" },
          { status: 400, headers: { "DPoP-Nonce": nonceValue(serverNonce)! } },
        );
      }
    }

    // Success (auto matched, ok, or ok_hold_after_200)
    if (rotatesRefresh) {
      spentRefresh.add(rt);
      refreshGen += 1;
      liveRefresh = refreshGen;
    }
    accessGen += 1;

    const explicitNonceHeader =
      action.kind === "ok" || action.kind === "ok_hold_after_200" ? action.nonceHeader : undefined;
    const responseNonce =
      explicitNonceHeader !== undefined
        ? explicitNonceHeader
        : rotateNonceOn200
          ? serverNonce + 1
          : serverNonce;
    if (responseNonce !== null && responseNonce > serverNonce) {
      serverNonce = responseNonce;
    }
    const effectiveNonce = responseNonce ?? (nonce >= 0 ? nonce : serverNonce);

    events.push({
      event: "token_ok",
      data: { p: label, access: accessGen, rt: liveRefresh, nonce: effectiveNonce },
    });

    const headers: Record<string, string> = { "content-type": "application/json" };
    if (responseNonce !== null) {
      headers["DPoP-Nonce"] = nonceValue(responseNonce)!;
    }

    if (action.kind === "ok_hold_after_200") {
      const encoder = new TextEncoder();
      let streamController: ReadableStreamDefaultController<Uint8Array> | null = null;
      const closeStream = () => {
        if (streamController) {
          openControllers.delete(streamController);
          try {
            streamController.close();
          } catch {}
          streamController = null;
        }
      };
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          streamController = controller;
          openControllers.add(controller);
          // Send HTTP 200 status + partial JSON body, then signal the driver to kill by PID before save.
          controller.enqueue(encoder.encode('{"access_token":'));
          action.on200Started(closeStream);
        },
        cancel() {
          if (streamController) openControllers.delete(streamController);
          streamController = null;
        },
      });
      return new Response(stream, { status: 200, headers });
    }

    const payload: Record<string, unknown> = {
      access_token: accessToken(accessGen),
      expires_in: HOUR_S,
      token_type: "Bearer",
      scope: `openid ${REQUIRED_SCOPE}`,
    };
    if (rotatesRefresh) {
      payload.refresh_token = refreshToken(liveRefresh);
      payload.refresh_token_expires_in = WEEK_S;
    }
    return new Response(JSON.stringify(payload), { status: 200, headers });
  }

  async function handleGemini(request: Request): Promise<Response> {
    syncDiskState();
    const rawBody = await request.text();
    const label = /GEMINI_AUTH_ASK_(\w+)/.exec(rawBody)?.[1] ?? "unknown";
    const auth = request.headers.get("authorization") ?? "";
    const access = generationOfAccess(auth.replace(/^Bearer\s+/i, ""));
    const attempt = apiAttempts.get(label) ?? 0;
    apiAttempts.set(label, attempt + 1);

    events.push({ event: "api_send", data: { p: label, access } });
    if ((await opts.holdApi?.(label, attempt, access)) === "drop") {
      return new Response(null, { status: 503 });
    }
    const ok = !loginRevoked && !signedOut && access === accessGen && !revokedAccess.has(access);
    events.push({ event: "api_answer", data: { p: label, access, ok } });
    if (ok) {
      return geminiTextSse(`GEMINI_AUTH_DONE_${label}`, `int_${label}_${attempt}`);
    }
    return Response.json(
      { error: { message: "Request had invalid authentication credentials." } },
      { status: 401 },
    );
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const tokenMatch = /^\/([^/]+)\/token$/.exec(url.pathname);
      if (request.method === "POST" && tokenMatch) {
        return handleToken(request, decodeURIComponent(tokenMatch[1]!));
      }
      if (request.method === "POST" && url.pathname === "/v1beta/interactions:createPerUserQuota") {
        return handleGemini(request);
      }
      return new Response("not found", { status: 404 });
    },
  });

  const baseUrl = `http://127.0.0.1:${server.port}`;

  return {
    home,
    baseUrl,
    events,
    tokenRequests,
    syncDiskState,
    revokeAccess(gen: number) {
      revokedAccess.add(gen);
    },
    setServerNonce(n: number) {
      serverNonce = n;
    },
    setLogoutPending(value: boolean) {
      logoutPending = value;
    },
    noteKill(label: string) {
      syncDiskState();
      events.push({ event: "kill", data: { p: label } });
    },
    envFor(label: string, extra: Record<string, string> = {}): Record<string, string> {
      return testEnvironment({
        HOME: home,
        FX_PROVIDER: "google",
        FX_MODEL: MODEL,
        FX_TEST_SKIP_ONBOARDING: "1",
        FX_TEST_GOOGLE_TOKEN_URL: `${baseUrl}/${encodeURIComponent(label)}/token`,
        FX_TEST_GOOGLE_CLIENT_ID: CLIENT_ID,
        FX_TEST_GOOGLE_CLIENT_SECRET: CLIENT_SECRET,
        FX_TEST_GEMINI_BASE_URL: baseUrl,
        ...extra,
      });
    },
    stop() {
      syncDiskState();
      watcher?.close();
      for (const c of openControllers) {
        try {
          c.close();
        } catch {}
      }
      openControllers.clear();
      server.stop(true);
    },
  };
}

export type FakeGoogleWorld = ReturnType<typeof startFakeGoogleWorld>;

export type SpawnedFx = {
  label: string;
  pid: number;
  kill: (signal?: NodeJS.Signals) => void;
  done: Promise<{ code: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string }>;
};

export function spawnGoogleAsk(
  world: FakeGoogleWorld,
  label: string,
  bin: string,
  extraEnv: Record<string, string> = {},
): SpawnedFx {
  if (!existsSync(bin)) throw new Error(`fx binary not found at ${bin}; run zig build first`);
  const env = world.envFor(label, extraEnv);
  const child = spawn(
    bin,
    ["ask", "--provider", "google", "--model", MODEL, "--json", "--no-save", `GEMINI_AUTH_ASK_${label}`],
    {
      env,
      cwd: worktree,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  if (!child.pid) throw new Error(`failed to spawn fx for ${label}`);
  const stdout: Buffer[] = [];
  const stderr: Buffer[] = [];
  child.stdout.on("data", (d: Buffer) => stdout.push(d));
  child.stderr.on("data", (d: Buffer) => stderr.push(d));
  const done = new Promise<{ code: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string }>(
    (resolve) => {
      child.on("close", (code, signal) => {
        world.syncDiskState();
        resolve({
          code,
          signal,
          stdout: Buffer.concat(stdout).toString(),
          stderr: Buffer.concat(stderr).toString(),
        });
      });
    },
  );
  return {
    label,
    pid: child.pid,
    kill: (signal = "SIGKILL") => {
      process.kill(child.pid!, signal);
    },
    done,
  };
}

export function spawnGoogleLogout(world: FakeGoogleWorld, bin: string, extraEnv: Record<string, string> = {}): SpawnedFx {
  if (!existsSync(bin)) throw new Error(`fx binary not found at ${bin}; run zig build first`);
  world.setLogoutPending(true);
  const env = world.envFor("logout", extraEnv);
  const child = spawn(bin, ["logout", "google"], {
    env,
    cwd: worktree,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (!child.pid) throw new Error("failed to spawn fx logout google");
  const stdout: Buffer[] = [];
  const stderr: Buffer[] = [];
  child.stdout.on("data", (d: Buffer) => stdout.push(d));
  child.stderr.on("data", (d: Buffer) => stderr.push(d));
  const done = new Promise<{ code: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string }>(
    (resolve) => {
      child.on("close", (code, signal) => {
        world.syncDiskState();
        world.setLogoutPending(false);
        resolve({
          code,
          signal,
          stdout: Buffer.concat(stdout).toString(),
          stderr: Buffer.concat(stderr).toString(),
        });
      });
    },
  );
  return {
    label: "logout",
    pid: child.pid,
    kill: (signal = "SIGKILL") => {
      process.kill(child.pid!, signal);
    },
    done,
  };
}

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

export function deferred<T = void>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

export async function waitUntil(what: string, condition: () => boolean, timeoutMs = 30_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(10);
  }
}

export function cleanupHome(home: string): void {
  rmSync(home, { recursive: true, force: true });
}
