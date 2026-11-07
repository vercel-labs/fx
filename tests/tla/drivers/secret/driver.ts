// Runs the built fx through every sign-in path that handles a secret, with
// scan.c in this folder loaded into it, and has TLC check each run against
// tests/tla/secret/SecretWipe.tla through SecretWipeTrace.tla.
//
// scan.c looks at every block fx gives back to libc, by free or by a realloc
// that moves it, and records each one that still holds one of the run's
// markers. The fake issuers below hand out device codes, authorization codes,
// and tokens that carry those markers, and the driver seeds expired sessions
// that carry them, so a marker reaches every reply parse, request body, saved
// session, and session load the run goes through:
//
//   vercel-login    fx login: the device code, its poll, the token reply, the saved session
//   vercel-refresh  fx ask with an expired login: the load, the refresh body and reply, the save
//   vercel-logout   fx logout: the load and the revocation bodies
//   codex-login     fx login codex: the code exchange body and reply, the saved session
//   codex-refresh   fx ask with an expired Codex login: the refresh body and reply, the save
//   grok-login      fx login grok: the code exchange body and reply, the saved session
//   grok-refresh    fx ask with an expired Grok login: the refresh body and reply, the save
//   grok-logout     fx logout grok: the load and the revocation body
//   napi            libfx in Node: the API key copy, on destruction and on a failed construction
//                   (in the ReleaseSafe addon only the failed construction can show the key:
//                   destruction frees through a runtime allocator, whose @memset(undefined)
//                   the optimizer keeps, while it drops the one before c_allocator's free)
//
// and the same paths when an edge fails:
//
//   vercel-refresh-rejected  the issuer refuses the refresh: the request body still goes back wiped
//   codex-refresh-truncated  the refresh reply ends inside its tokens: the failed parse goes back wiped
//   grok-refresh-truncated   likewise for Grok
//   vercel-refresh-killed    fx is killed while its refresh waits; the next fx refreshes the saved login
//
// Each run must also show that the secret was there to wipe: the fake issuer
// saw it in a request, or the saved session holds it. The run's counts become
// SecretWipeObserved, and TLC checks them under Policy "wiping", the design,
// which accepts only a run that gave no secret back. Each run is also checked
// under "today", the model of fx before secret.Wiping, which accepts the
// leaks fx had.
//
// Every fx process runs through env -i with FX_SOUND=0, FX_DISABLE_KEYCHAIN=1,
// FX_NO_OPEN_BROWSER=1, a private FX_HOME, and only local fakes. A stub `open`
// first on PATH keeps any browser launch local. The napi run needs
// zig-out/lib/libfx.node (zig build libfx-napi -Dnapi-surface=core) and node;
// LIBFX_NODE picks another addon.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/secret/driver.ts
//   bun tests/tla/drivers/secret/driver.ts --only vercel-refresh,codex-refresh
//   bun tests/tla/drivers/secret/driver.ts --repeat 10 --token-bytes 4096
//
// --repeat runs every scenario that many times, and --token-bytes pads each
// token the fakes hand out or seed by that many bytes, so request bodies and
// saved sessions outgrow their buffers several times over.
//
// Exit codes: 0 every run is a behavior of the design, 1 a run gave a secret
// back to libc or missed a precondition, 2 a toolchain or build failure.
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { REPO_ROOT, TLA_ROOT, fxBin, outDir, runTlc, writeJson } from "../lib/tlc";

const SPEC_DIR = join(TLA_ROOT, "secret");
const TIMEOUT_MS = 60_000;

function fail(code: number, message: string): never {
  console.error(message);
  process.exit(code);
}

function argValue(name: string): string | null {
  const at = process.argv.indexOf(name);
  return at < 0 ? null : (process.argv[at + 1] ?? null);
}

if (process.platform !== "darwin") {
  fail(2, "the secret driver needs macOS: scan.c replaces free and realloc through dyld's __interpose section");
}

function count(name: string, fallback: number): number {
  const raw = argValue(name);
  const value = raw === null ? fallback : Number(raw);
  if (!Number.isInteger(value) || value < 0) fail(2, `${name} takes a whole number`);
  return value;
}

const only = argValue("--only")?.split(",").filter(Boolean) ?? null;
const repeat = Math.max(1, count("--repeat", 1));
const tokenBytes = count("--token-bytes", 0);
const out = outDir("secret");
const bin = fxBin();

function buildScan(): string {
  const library = join(out, "scan.dylib");
  const built = Bun.spawnSync(
    ["clang", "-dynamiclib", "-O2", "-Wall", "-Wextra", "-Werror", join(import.meta.dirname, "scan.c"), "-o", library],
    { stdout: "pipe", stderr: "pipe" },
  );
  if (built.exitCode !== 0) fail(2, `building scan.c failed:\n${built.stderr.toString()}`);
  return library;
}

const scanLibrary = buildScan();

// A marker no part of fx or its fakes writes on its own.
function marker(label: string): string {
  return `SCAN${label}${randomBytes(6).toString("hex").toUpperCase()}`;
}

type Scan = { frees: number; moves: number; hits: string[]; loaded: boolean };

function readScan(recordPath: string, markers: string[]): Scan {
  const scan: Scan = { frees: 0, moves: 0, hits: [], loaded: false };
  if (!existsSync(recordPath)) return scan;
  for (const line of readFileSync(recordPath, "utf8").split("\n")) {
    const [what, bytes, index] = line.split(" ");
    if (what === "loaded") scan.loaded = true;
    if (what !== "free" && what !== "move") continue;
    if (what === "free") scan.frees += 1;
    else scan.moves += 1;
    scan.hits.push(`${what} ${bytes}B ${markers[Number(index)] ?? `#${index}`}`);
  }
  return scan;
}

// One run's private folders, its markers, and the scan's record.
class Run {
  readonly root: string;
  readonly home: string;
  readonly fxHome: string;
  readonly binDir: string;
  readonly markers: string[] = [];
  readonly recordPath: string;
  readonly markersPath: string;
  readonly preconditions: string[] = [];
  secrets = 0;

  constructor(readonly name: string) {
    this.root = join(out, name);
    this.home = join(this.root, "home");
    this.fxHome = join(this.root, "fx-home");
    this.binDir = join(this.root, "bin");
    for (const dir of [this.root, this.home, this.fxHome, this.binDir]) mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(this.fxHome, 0o700);
    this.recordPath = join(this.root, "scan.log");
    this.markersPath = join(this.root, "markers");
    // Any browser launch stays local: it lands here and opens nothing.
    const openStub = join(this.binDir, "open");
    writeFileSync(openStub, `#!/bin/sh\nprintf '%s\\n' "$*" >> '${join(this.root, "open.log")}'\n`, { mode: 0o700 });
  }

  marker(label: string): string {
    const value = marker(label);
    this.markers.push(value);
    writeFileSync(this.markersPath, this.markers.join("\n") + "\n", { mode: 0o600 });
    return value;
  }

  // A token that carries a new marker, padded by --token-bytes.
  token(label: string): string {
    return this.marker(label) + "x".repeat(tokenBytes);
  }

  seed(file: string, value: object) {
    const path = join(this.fxHome, file);
    writeFileSync(path, JSON.stringify(value) + "\n", { mode: 0o600 });
    chmodSync(path, 0o600);
  }

  saved(file: string): string {
    const path = join(this.fxHome, file);
    return existsSync(path) ? readFileSync(path, "utf8") : "";
  }

  // A secret the run carried in a request or a saved session.
  expect(label: string, holds: boolean) {
    if (holds) this.secrets += 1;
    else this.preconditions.push(label);
  }

  baseEnv(extra: Record<string, string>): Record<string, string> {
    return {
      HOME: this.home,
      PATH: `${this.binDir}:/usr/bin:/bin`,
      TMPDIR: this.root,
      FX_HOME: this.fxHome,
      FX_SOUND: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_NO_OPEN_BROWSER: "1",
      FX_AUTO_UPGRADE: "0",
      FX_E2E_DISABLE_DOTENV: "1",
      FX_TEST_SKIP_ONBOARDING: "1",
      DYLD_INSERT_LIBRARIES: scanLibrary,
      FX_SECRET_SCAN_RECORD: this.recordPath,
      FX_SECRET_SCAN_MARKERS: this.markersPath,
      ...extra,
    };
  }

  // Runs `argv` through env -i with every variable written out, calls
  // `onStdout` with the output so far as it arrives, and kills the process
  // with SIGKILL once `killWhen` holds.
  async exec(
    argv: string[],
    env: Record<string, string>,
    onStdout?: (text: string) => Promise<void> | void,
    killWhen?: () => boolean,
  ): Promise<{ code: number; stdout: string; stderr: string }> {
    const assignments = Object.entries(env).map(([key, value]) => `${key}=${value}`);
    const proc = Bun.spawn(["/usr/bin/env", "-i", ...assignments, ...argv], {
      cwd: this.home,
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => proc.kill("SIGKILL"), TIMEOUT_MS);
    const watch = killWhen && setInterval(() => {
      if (killWhen()) proc.kill("SIGKILL");
    }, 20);
    let stdout = "";
    const reader = (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stdout) {
        stdout += decoder.decode(chunk, { stream: true });
        await onStdout?.(stdout);
      }
    })();
    const stderr = await new Response(proc.stderr).text();
    await reader;
    const code = await proc.exited;
    clearTimeout(timer);
    if (watch) clearInterval(watch);
    this.runs += 1;
    writeFileSync(join(this.root, `stdout-${this.runs}.log`), stdout);
    writeFileSync(join(this.root, `stderr-${this.runs}.log`), stderr);
    return { code, stdout, stderr };
  }

  runs = 0;

  fx(
    args: string[],
    extra: Record<string, string>,
    onStdout?: (text: string) => Promise<void> | void,
    killWhen?: () => boolean,
  ) {
    return this.exec([bin, ...args], this.baseEnv(extra), onStdout, killWhen);
  }
}

type Request = { method: string; path: string; body: string; authorization: string | null };

function serve(handler: (request: Request, url: URL, base: string) => Response | Promise<Response>) {
  const requests: Request[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(raw) {
      const url = new URL(raw.url);
      const request: Request = {
        method: raw.method,
        path: url.pathname,
        body: raw.method === "POST" ? await raw.text() : "",
        authorization: raw.headers.get("authorization"),
      };
      requests.push(request);
      return handler(request, url, `http://127.0.0.1:${server.port}`);
    },
  });
  return { base: `http://127.0.0.1:${server.port}`, requests, stop: () => server.stop(true) };
}

function sse(text: string): Response {
  return new Response(
    `data: {"type":"response.output_text.delta","delta":"${text}"}\n\n` +
      'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
    { headers: { "content-type": "text/event-stream" } },
  );
}

// What a fake issuer's token endpoint does instead of answering at once:
// refuse the grant, answer with a reply cut off inside its tokens, or wait.
type Faults = { reject?: boolean; truncate?: boolean; hold?: Promise<void> };

function tokenReply(body: Record<string, unknown>, faults: Faults): Response {
  if (faults.reject) return Response.json({ error: "invalid_grant" }, { status: 400 });
  const text = JSON.stringify(body);
  if (!faults.truncate) return new Response(text, { headers: { "content-type": "application/json" } });
  // Cut inside the refresh token, after the access token.
  return new Response(text.slice(0, text.indexOf("refresh_token") + 30), { headers: { "content-type": "application/json" } });
}

// The Vercel issuer.
function vercelIssuer(tokens: { device: string; access: string; refresh: string }, faults: Faults = {}) {
  return serve(async (request, url, base) => {
    if (url.pathname === "/.well-known/openid-configuration") {
      return Response.json({
        issuer: base,
        device_authorization_endpoint: `${base}/oauth/device`,
        token_endpoint: `${base}/oauth/token`,
        revocation_endpoint: `${base}/oauth/revoke`,
      });
    }
    if (url.pathname === "/oauth/device") {
      return Response.json({
        device_code: tokens.device,
        user_code: "ABCD-EFGH",
        verification_uri: `${base}/device`,
        expires_in: 600,
        interval: 1,
      });
    }
    if (url.pathname === "/oauth/token") {
      await faults.hold;
      return tokenReply({
        access_token: tokens.access,
        refresh_token: tokens.refresh,
        token_type: "Bearer",
        expires_in: 3600,
        scope: "openid offline_access",
      }, faults);
    }
    if (url.pathname === "/v2/teams") {
      return Response.json({ teams: [{ id: "team_scan", slug: "scan-team", name: "Scan Team" }] });
    }
    if (url.pathname === "/oauth/revoke") return Response.json({ revoked: true });
    return new Response("not found", { status: 404 });
  });
}

// The AI Gateway fake of tests/e2e/, which answers every model request.
const gatewayHelpers = await import(join(REPO_ROOT, "tests", "e2e", "tmux-helpers.ts"));

function startGateway() {
  return gatewayHelpers.startDynamicFakeGateway(() => gatewayHelpers.fakeGatewayFinalText("SCAN_DONE"));
}

function vercelSession(issuer: string, access: string, refresh: string, expiresAtMs: number) {
  return {
    version: 1,
    issuer,
    client_id: "cl_scan",
    access_token: access,
    refresh_token: refresh,
    expires_at_ms: expiresAtMs,
    scope: "openid offline_access",
    token_type: "Bearer",
    team_id: "team_scan",
    team_slug: "scan-team",
  };
}

function vercelEnv(issuer: string, gateway: { baseUrl: string; chatUrl: string }): Record<string, string> {
  return {
    FX_TEST_OAUTH_ISSUER_URL: issuer,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: gatewayHelpers.FAKE_GATEWAY_MODEL,
  };
}

// A Codex access token: a JWT whose payload names the account, with the
// marker as its signature.
function codexAccess(signature: string): string {
  const payload = Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: "acct_scan" },
  })).toString("base64url");
  return `header.${payload}.${signature}`;
}

function codexIssuer(tokens: { code: string; access: string; refresh: string }, faults: Faults = {}) {
  return serve((request, url) => {
    if (url.pathname === "/oauth/authorize") {
      const callback = new URL(url.searchParams.get("redirect_uri")!.replace("localhost", "127.0.0.1"));
      callback.searchParams.set("code", tokens.code);
      callback.searchParams.set("state", url.searchParams.get("state")!);
      return Response.redirect(callback.toString(), 302);
    }
    if (url.pathname === "/chatgpt/token") {
      return tokenReply({ access_token: tokens.access, refresh_token: tokens.refresh, expires_in: 3600 }, faults);
    }
    if (url.pathname === "/chatgpt/models") {
      return Response.json({
        models: [{
          slug: "gpt-5.6-luna", visibility: "list", supported_in_api: true,
          supported_reasoning_levels: [{ effort: "medium" }], additional_speed_tiers: [],
          input_modalities: ["text"], context_window: 272000,
        }],
      });
    }
    if (url.pathname === "/chatgpt/responses") return sse("SCAN_DONE");
    return new Response("not found", { status: 404 });
  });
}

function codexEnv(base: string): Record<string, string> {
  return {
    FX_TEST_CHATGPT_ISSUER_URL: base,
    FX_TEST_CHATGPT_TOKEN_URL: `${base}/chatgpt/token`,
    FX_TEST_OPENAI_CODEX_MODELS_URL: `${base}/chatgpt/models`,
    FX_TEST_OPENAI_CODEX_RESPONSES_URL: `${base}/chatgpt/responses`,
    FX_TEST_CODEX_CLIENT_VERSION: "0.153.0",
  };
}

function grokIssuer(tokens: { code: string; access: string; refresh: string }, faults: Faults = {}) {
  return serve((request, url) => {
    if (url.pathname === "/oauth2/authorize") {
      const callback = new URL(url.searchParams.get("redirect_uri")!);
      callback.searchParams.set("code", tokens.code);
      callback.searchParams.set("state", url.searchParams.get("state")!);
      return Response.redirect(callback.toString(), 302);
    }
    if (url.pathname === "/oauth2/token") {
      return tokenReply({ access_token: tokens.access, refresh_token: tokens.refresh, expires_in: 3600 }, faults);
    }
    if (url.pathname === "/oauth2/userinfo") return Response.json({ sub: "acct_scan" });
    if (url.pathname === "/oauth2/revoke") return Response.json({ revoked: true });
    if (url.pathname === "/v1/language-models") {
      return Response.json({ models: [{ id: "grok-4.20", object: "model", input_modalities: ["text"], output_modalities: ["text"] }] });
    }
    if (url.pathname === "/v1/models") {
      return Response.json({
        data: [{
          id: "grok-4.20", model: "grok-4.20", api_backend: "responses", context_window: 1_000_000,
          supports_reasoning_effort: false, reasoning_efforts: [],
        }],
      });
    }
    if (url.pathname === "/v1/responses") return sse("SCAN_DONE");
    return new Response("not found", { status: 404 });
  });
}

function grokEnv(base: string): Record<string, string> {
  return {
    FX_TEST_GROK_ISSUER_URL: base,
    FX_TEST_GROK_TOKEN_URL: `${base}/oauth2/token`,
    FX_TEST_GROK_USERINFO_URL: `${base}/oauth2/userinfo`,
    FX_TEST_GROK_REVOKE_URL: `${base}/oauth2/revoke`,
    FX_TEST_XAI_GROK_MODELS_URL: `${base}/v1/models`,
    FX_TEST_XAI_GROK_MODALITIES_URL: `${base}/v1/language-models`,
    FX_TEST_XAI_GROK_RESPONSES_URL: `${base}/v1/responses`,
    FX_TEST_GROK_CLIENT_VERSION: "1.0.6",
  };
}

function subscriptionSession(access: string, refresh: string, expiresAtMs: number) {
  return { version: 1, access_token: access, refresh_token: refresh, expires_at_ms: expiresAtMs, account_id: "acct_scan" };
}

// Follows the authorization URL fx prints, as a browser would, once.
function authorizeOnce(pattern: RegExp) {
  let started = false;
  return async (stdout: string) => {
    if (started) return;
    const url = stdout.match(pattern)?.[0];
    if (!url) return;
    started = true;
    await fetch(url, { redirect: "follow" }).catch(() => {});
  };
}

// `fails` marks a scenario whose last fx must exit with an error.
type Scenario = {
  name: string;
  fails?: boolean;
  run: (run: Run) => Promise<{ code: number; skipped?: string }>;
};

function expired(): number {
  return Date.now() - 60_000;
}

function live(): number {
  return Date.now() + 3_600_000;
}

const scenarios: Scenario[] = [
  {
    name: "vercel-login",
    async run(run) {
      const tokens = { device: run.token("DEVICE"), access: run.token("ACCESS"), refresh: run.token("REFRESH") };
      const issuer = vercelIssuer(tokens);
      const gateway = startGateway();
      try {
        const result = await run.fx(["login"], vercelEnv(issuer.base, gateway));
        const poll = issuer.requests.find((r) => r.path === "/oauth/token");
        run.expect("the token poll carried the device code", poll?.body.includes(tokens.device) ?? false);
        run.expect("the saved session holds the refresh token", run.saved("auth.json").includes(tokens.refresh));
        return result;
      } finally {
        gateway.stop();
        issuer.stop();
      }
    },
  },
  {
    name: "vercel-refresh",
    async run(run) {
      const old = { access: run.token("OLDACCESS"), refresh: run.token("OLDREFRESH") };
      const tokens = { device: "unused", access: run.token("ACCESS"), refresh: run.token("REFRESH") };
      const issuer = vercelIssuer(tokens);
      const gateway = startGateway();
      try {
        run.seed("auth.json", vercelSession(issuer.base, old.access, old.refresh, expired()));
        const result = await run.fx(["ask", "--json", "--no-save", "Answer directly."], vercelEnv(issuer.base, gateway));
        const refresh = issuer.requests.find((r) => r.path === "/oauth/token");
        run.expect("the refresh request carried the saved refresh token", refresh?.body.includes(old.refresh) ?? false);
        run.expect("the saved session holds the new refresh token", run.saved("auth.json").includes(tokens.refresh));
        run.expect("the gateway answered a model request with the new token",
          gateway.requests.some((r: { headers: Headers }) => r.headers.get("authorization") === `Bearer ${tokens.access}`));
        return result;
      } finally {
        gateway.stop();
        issuer.stop();
      }
    },
  },
  {
    name: "vercel-refresh-rejected",
    fails: true,
    async run(run) {
      const old = { access: run.token("OLDACCESS"), refresh: run.token("OLDREFRESH") };
      const issuer = vercelIssuer({ device: "unused", access: "unused", refresh: "unused" }, { reject: true });
      const gateway = startGateway();
      try {
        run.seed("auth.json", vercelSession(issuer.base, old.access, old.refresh, expired()));
        const result = await run.fx(["ask", "--json", "--no-save", "Answer directly."], vercelEnv(issuer.base, gateway));
        const refresh = issuer.requests.find((r) => r.path === "/oauth/token");
        run.expect("the refused refresh request carried the saved refresh token", refresh?.body.includes(old.refresh) ?? false);
        run.expect("the saved session was read", issuer.requests.length > 0);
        return result;
      } finally {
        gateway.stop();
        issuer.stop();
      }
    },
  },
  {
    name: "vercel-refresh-killed",
    async run(run) {
      const old = { access: run.token("OLDACCESS"), refresh: run.token("OLDREFRESH") };
      const tokens = { device: "unused", access: run.token("ACCESS"), refresh: run.token("REFRESH") };
      let release = () => {};
      const hold = new Promise<void>((resolve) => { release = resolve; });
      const issuer = vercelIssuer(tokens, { hold });
      const gateway = startGateway();
      try {
        run.seed("auth.json", vercelSession(issuer.base, old.access, old.refresh, expired()));
        const env = vercelEnv(issuer.base, gateway);
        // The first fx dies while its refresh waits for the issuer.
        const killed = await run.fx(["ask", "--json", "--no-save", "Answer directly."], env, undefined,
          () => issuer.requests.some((r) => r.path === "/oauth/token"));
        release();
        run.expect("the first fx was killed while it refreshed", killed.code !== 0);
        run.expect("the saved login survived the kill", run.saved("auth.json").includes(old.refresh));
        // The next fx refreshes the same saved login and saves the new one.
        const result = await run.fx(["ask", "--json", "--no-save", "Answer directly."], env);
        const refreshes = issuer.requests.filter((r) => r.path === "/oauth/token" && r.body.includes(old.refresh));
        run.expect("the next fx sent the saved refresh token again", refreshes.length === 2);
        run.expect("the saved session holds the new refresh token", run.saved("auth.json").includes(tokens.refresh));
        return result;
      } finally {
        release();
        gateway.stop();
        issuer.stop();
      }
    },
  },
  {
    name: "vercel-logout",
    async run(run) {
      const old = { access: run.token("OLDACCESS"), refresh: run.token("OLDREFRESH") };
      const issuer = vercelIssuer({ device: "unused", access: "unused", refresh: "unused" });
      const gateway = startGateway();
      try {
        run.seed("auth.json", vercelSession(issuer.base, old.access, old.refresh, live()));
        const result = await run.fx(["logout"], vercelEnv(issuer.base, gateway));
        const revoke = issuer.requests.find((r) => r.path === "/oauth/revoke" && r.body.includes(old.refresh));
        run.expect("a revocation carried the saved refresh token", revoke !== undefined);
        run.expect("the session was removed", !existsSync(join(run.fxHome, "auth.json")));
        return result;
      } finally {
        gateway.stop();
        issuer.stop();
      }
    },
  },
  {
    name: "codex-login",
    async run(run) {
      const tokens = { code: run.token("CODE"), access: codexAccess(run.token("ACCESS")), refresh: run.token("REFRESH") };
      const issuer = codexIssuer(tokens);
      try {
        const result = await run.fx(["login", "codex"], codexEnv(issuer.base),
          authorizeOnce(/http:\/\/127\.0\.0\.1:\d+\/oauth\/authorize\?\S+/));
        const exchange = issuer.requests.find((r) => r.path === "/chatgpt/token");
        run.expect("the code exchange carried the authorization code", exchange?.body.includes(tokens.code) ?? false);
        run.expect("the saved session holds the refresh token", run.saved("chatgpt-auth.json").includes(tokens.refresh));
        return result;
      } finally {
        issuer.stop();
      }
    },
  },
  {
    name: "codex-refresh",
    async run(run) {
      const old = { access: codexAccess(run.token("OLDACCESS")), refresh: run.token("OLDREFRESH") };
      const tokens = { code: "unused", access: codexAccess(run.token("ACCESS")), refresh: run.token("REFRESH") };
      const issuer = codexIssuer(tokens);
      try {
        run.seed("chatgpt-auth.json", subscriptionSession(old.access, old.refresh, expired()));
        const result = await run.fx(["ask", "--json", "--no-save", "Answer directly."],
          { ...codexEnv(issuer.base), FX_PROVIDER: "codex", FX_MODEL: "gpt-5.6-luna" });
        const refresh = issuer.requests.find((r) => r.path === "/chatgpt/token");
        run.expect("the refresh request carried the saved refresh token", refresh?.body.includes(old.refresh) ?? false);
        run.expect("the saved session holds the new refresh token", run.saved("chatgpt-auth.json").includes(tokens.refresh));
        return result;
      } finally {
        issuer.stop();
      }
    },
  },
  {
    name: "codex-refresh-truncated",
    fails: true,
    async run(run) {
      const old = { access: codexAccess(run.token("OLDACCESS")), refresh: run.token("OLDREFRESH") };
      const tokens = { code: "unused", access: codexAccess(run.token("ACCESS")), refresh: run.token("REFRESH") };
      const issuer = codexIssuer(tokens, { truncate: true });
      try {
        run.seed("chatgpt-auth.json", subscriptionSession(old.access, old.refresh, expired()));
        const result = await run.fx(["ask", "--json", "--no-save", "Answer directly."],
          { ...codexEnv(issuer.base), FX_PROVIDER: "codex", FX_MODEL: "gpt-5.6-luna" });
        const refresh = issuer.requests.find((r) => r.path === "/chatgpt/token");
        run.expect("the refresh request carried the saved refresh token", refresh?.body.includes(old.refresh) ?? false);
        run.expect("the cut-off reply carried the new access token", refresh !== undefined);
        return result;
      } finally {
        issuer.stop();
      }
    },
  },
  {
    name: "grok-login",
    async run(run) {
      const tokens = { code: run.token("CODE"), access: run.token("ACCESS"), refresh: run.token("REFRESH") };
      const issuer = grokIssuer(tokens);
      try {
        const result = await run.fx(["login", "grok"], grokEnv(issuer.base),
          authorizeOnce(/http:\/\/127\.0\.0\.1:\d+\/oauth2\/authorize\?\S+/));
        const exchange = issuer.requests.find((r) => r.path === "/oauth2/token");
        run.expect("the code exchange carried the authorization code", exchange?.body.includes(tokens.code) ?? false);
        run.expect("the saved session holds the refresh token", run.saved("grok-auth.json").includes(tokens.refresh));
        return result;
      } finally {
        issuer.stop();
      }
    },
  },
  {
    name: "grok-refresh",
    async run(run) {
      const old = { access: run.token("OLDACCESS"), refresh: run.token("OLDREFRESH") };
      const tokens = { code: "unused", access: run.token("ACCESS"), refresh: run.token("REFRESH") };
      const issuer = grokIssuer(tokens);
      try {
        run.seed("grok-auth.json", subscriptionSession(old.access, old.refresh, expired()));
        const result = await run.fx(["ask", "--json", "--no-save", "Answer directly."],
          { ...grokEnv(issuer.base), FX_PROVIDER: "grok", FX_MODEL: "grok-4.20" });
        const refresh = issuer.requests.find((r) => r.path === "/oauth2/token");
        run.expect("the refresh request carried the saved refresh token", refresh?.body.includes(old.refresh) ?? false);
        run.expect("the saved session holds the new refresh token", run.saved("grok-auth.json").includes(tokens.refresh));
        return result;
      } finally {
        issuer.stop();
      }
    },
  },
  {
    name: "grok-refresh-truncated",
    fails: true,
    async run(run) {
      const old = { access: run.token("OLDACCESS"), refresh: run.token("OLDREFRESH") };
      const tokens = { code: "unused", access: run.token("ACCESS"), refresh: run.token("REFRESH") };
      const issuer = grokIssuer(tokens, { truncate: true });
      try {
        run.seed("grok-auth.json", subscriptionSession(old.access, old.refresh, expired()));
        const result = await run.fx(["ask", "--json", "--no-save", "Answer directly."],
          { ...grokEnv(issuer.base), FX_PROVIDER: "grok", FX_MODEL: "grok-4.20" });
        const refresh = issuer.requests.find((r) => r.path === "/oauth2/token");
        run.expect("the refresh request carried the saved refresh token", refresh?.body.includes(old.refresh) ?? false);
        run.expect("the cut-off reply carried the new access token", refresh !== undefined);
        return result;
      } finally {
        issuer.stop();
      }
    },
  },
  {
    name: "grok-logout",
    async run(run) {
      const old = { access: run.token("OLDACCESS"), refresh: run.token("OLDREFRESH") };
      const issuer = grokIssuer({ code: "unused", access: "unused", refresh: "unused" });
      try {
        run.seed("grok-auth.json", subscriptionSession(old.access, old.refresh, live()));
        const result = await run.fx(["logout", "grok"], grokEnv(issuer.base));
        const revoke = issuer.requests.find((r) => r.path === "/oauth2/revoke" && r.body.includes(old.refresh));
        run.expect("the revocation carried the saved refresh token", revoke !== undefined);
        run.expect("the session was removed", !existsSync(join(run.fxHome, "grok-auth.json")));
        return result;
      } finally {
        issuer.stop();
      }
    },
  },
  {
    name: "napi",
    async run(run) {
      const addon = process.env.LIBFX_NODE ?? join(REPO_ROOT, "zig-out", "lib", "libfx.node");
      const which = Bun.spawnSync(["/bin/sh", "-c", "command -v node"], { stdout: "pipe" });
      const node = which.stdout.toString().trim();
      if (!existsSync(addon)) return { code: 0, skipped: `no ${addon}; run zig build libfx-napi -Dnapi-surface=core` };
      if (!node) return { code: 0, skipped: "no node on PATH" };
      const keys = [run.marker("APIKEY"), run.marker("APIKEYFAIL")];
      const halves = keys.flatMap((key) => [key.slice(0, 8), key.slice(8)]);
      const script = join(run.root, "napi.cjs");
      // Node copies its arguments into memory it frees, so each key arrives
      // in two halves and is joined in JavaScript, whose strings live in V8's
      // heap: the only whole copy in memory libc manages is libfx's own.
      // The first runtime is created and destroyed. The second has its key
      // copied and then fails on a home that is not a string, so its key is
      // released on the partial-construction path.
      writeFileSync(script, [
        "const addon = require(process.argv[2]);",
        "const [home, a, b, c, d] = process.argv.slice(3);",
        "const core = addon.createCore({ apiKey: a + b, home, workspaceRoot: home });",
        "addon.closeCore(core);",
        "addon.destroyCore(core);",
        "let failed = false;",
        "try { addon.createCore({ apiKey: c + d, home: 7, workspaceRoot: home }); } catch { failed = true; }",
        "if (!failed) process.exit(3);",
      ].join("\n"));
      const result = await run.exec([node, script, addon, run.home, ...halves], {
        ...run.baseEnv({}),
        PATH: `${run.binDir}:/usr/bin:/bin:${join(node, "..")}`,
      });
      run.expect("the runtime took the API key", result.code === 0);
      return result;
    },
  },
];

type Verdict = { policy: string; accepted: boolean; distinctStates: number | null };

async function checkTrace(run: Run, scan: Scan, policy: string): Promise<Verdict> {
  const dir = join(run.root, `tlc-${policy}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "SecretWipeObserved.tla"), [
    "------------------------- MODULE SecretWipeObserved -------------------------",
    `\\* ${run.name}: generated by tests/tla/drivers/secret/driver.ts.`,
    `Observed == [frees |-> ${scan.frees}, moves |-> ${scan.moves}, secrets |-> ${run.secrets}]`,
    "=============================================================================",
    "",
  ].join("\n"));
  writeFileSync(join(dir, "Trace.cfg"), [
    "SPECIFICATION Spec",
    "CONSTANTS",
    "    Blocks = {1, 2}",
    `    Policy = "${policy}"`,
    "    MaxEvents = 0",
    "CONSTRAINT TraceBounded",
    "INVARIANT NotMatched",
    "",
  ].join("\n"));
  const tlc = await runTlc(dir, "SecretWipeTrace", "Trace.cfg", ["SecretWipe.tla", "SecretWipeTrace.tla"], SPEC_DIR);
  if (tlc.exitCode !== 0 && tlc.violated !== "NotMatched") {
    fail(2, `TLC failed on ${run.name} under ${policy} (exit ${tlc.exitCode}); see ${join(dir, "tlc.log")}`);
  }
  return { policy, accepted: tlc.violated === "NotMatched", distinctStates: tlc.distinctStates };
}

const selected = only ? scenarios.filter((s) => only.includes(s.name)) : scenarios;
if (only && selected.length !== only.length) fail(2, `unknown scenario in --only ${only.join(",")}`);
console.log(`fx: ${bin}\nout: ${out}`);

let failed = false;
let passed = 0;
const report: object[] = [];
for (let round = 1; round <= repeat; round++) {
  for (const scenario of selected) {
    const name = repeat > 1 ? `${scenario.name}-${round}` : scenario.name;
    const run = new Run(name);
    const result = await scenario.run(run);
    if (result.skipped) {
      console.log(`SKIP ${name}: ${result.skipped}`);
      report.push({ name, skipped: result.skipped });
      continue;
    }
    const scan = readScan(run.recordPath, run.markers);
    const problems = [...run.preconditions];
    if (!scan.loaded) problems.push("scan.c did not load into the process");
    const exitOk = scenario.fails ? result.code !== 0 : result.code === 0;
    if (!exitOk) problems.push(`exit ${result.code}, expected ${scenario.fails ? "an error" : "0"}; see ${run.root}`);
    const design = await checkTrace(run, scan, "wiping");
    const today = await checkTrace(run, scan, "today");
    const ok = problems.length === 0 && design.accepted;
    if (ok) passed += 1;
    else failed = true;
    console.log(
      `${ok ? "ok  " : "FAIL"} ${name}: exit=${result.code} secrets=${run.secrets} freed_with_secret=${scan.frees} moved_with_secret=${scan.moves}` +
        ` design=${design.accepted ? "accepted" : "rejected"} today=${today.accepted ? "accepted" : "rejected"}`,
    );
    for (const problem of problems) console.log(`     missed: ${problem}`);
    for (const hit of scan.hits.slice(0, 8)) console.log(`     ${hit}`);
    if (scan.hits.length > 8) console.log(`     ... ${scan.hits.length - 8} more in ${run.recordPath}`);
    report.push({ name, code: result.code, secrets: run.secrets, scan, problems, design, today });
  }
}
console.log(`${passed} of ${report.length} runs ok (token padding ${tokenBytes} bytes, ${repeat} round${repeat > 1 ? "s" : ""})`);
writeJson(join(out, "report.json"), report);
console.log(`report: ${join(out, "report.json")}`);
process.exit(failed ? 1 : 0);
