// Runs the built fx binary along tests/tla/grok_oauth/GrokIdentity.tla and has
// TLC check every run it observes (GrokIdentityTrace.tla).
//
// Each run is `fx login grok`, `fx login grok` then `fx ask`, or `fx ask` on a
// saved login, on a fresh profile, against a local fake xAI issuer. The issuer
// follows what the reporters of #461 describe, which cannot be checked here
// without a Team account: a Team access token names the Team in its
// principal_type and principal_id claims, /oauth2/userinfo answers 403 for a
// Team token, and a refresh with no principal fields returns a token for the
// person's own account. A personal token's principal_id claim differs from
// its userinfo sub, so a fx that names a personal account from the claim is
// caught.
//
// The principals: a User JWT, an opaque token, a JWT with no principal
// claims, a Team with snake_case or camelCase claims, a Team id of 1024 bytes
// (the largest allowed), a Team token with an 8 KB payload, and three Teams
// whose id is missing, holds a space, or is 1025 bytes. The saved logins are
// placed against the one-minute refresh margin instead of waiting: an hour
// past, 45 s ahead (inside), 90 s and an hour ahead (outside). One run kills
// fx while the issuer holds its refresh reply, checks the saved login is as it
// was, and runs fx again, and one saved login's token names a Team with an
// unsafe id. --stress N adds N back-to-back refreshes of one Team
// login, each fx refreshing the login the one before it saved.
//
// For each run the driver records how fx login ended and what it saved, the
// token types fx sent to userinfo, the principal fields of its refresh, how
// fx ask ended, and what grok-auth.json held at the end. TLC replays the runs
// through the model's own actions. --self-check also replays them through
// the model of fx before the fix (no Team claim, no refresh fields), which
// must reject them.
//
// fx runs only through `env -i` with every variable written out: a temporary
// HOME, TMPDIR, and FX_HOME, FX_DISABLE_KEYCHAIN=1, FX_SOUND=0,
// FX_NO_OPEN_BROWSER=1, the fake issuer and provider URLs, and a fake gateway
// key and URL. Every Grok URL must be a loopback fake before fx starts. The
// fakes count every request; a run that reaches the fake gateway, asks the
// fakes for anything the run does not expect, or makes a different number of
// token or model requests than it should fails the driver.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/grok_oauth/driver.ts
//   bun tests/tla/drivers/grok_oauth/driver.ts --self-check --jobs 4 --stress 50
//   bun tests/tla/drivers/grok_oauth/driver.ts --model today   # fx before the fix must fit the model of today
//   bun tests/tla/drivers/grok_oauth/driver.ts --direct --cases refresh-killed   # chosen runs, no TLC
//   bun tests/tla/drivers/grok_oauth/driver.ts --direct --cases none --faults --race 20 --seed 7
//
// --direct checks each run against the outcome the design gives it instead
// of TLC, for the runs --cases names by id prefix. It also takes --faults,
// runs whose issuer fails on purpose (a refresh that answers 500, one that
// comes back as another Team, a userinfo that answers 500), and --race N,
// rounds of two fx started together on one expired Team login with the
// refresh held a random time from --seed: one refresh, both answered as the Team.
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce or the fakes did not expect, 2 a toolchain or harness
// failure.
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { binary as binaryPath, targetHelpers } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Cmd = "login" | "login_refresh" | "refresh" | "refresh_killed" | "fresh";
type ModelKind = "user" | "opaque" | "team" | "team_bad_id";
type Kind =
  | "user" | "opaque" | "noclaims"
  | "team" | "team_camel" | "team_max_id" | "team_big_token"
  | "team_missing_id" | "team_unsafe_id" | "team_long_id";
type Expiry = "past" | "inside" | "outside" | "hour" | "none";
type Login = "not_run" | "signed_in" | "failed";
type Ask = "not_run" | "answered" | "account_changed" | "signed_out" | "failed" | "unknown";
type Form = "no_refresh" | "none" | "team" | "user";
type Account = "u1" | "t1" | "u_claim" | "bad" | "none";
/** A fault the issuer injects, in --direct runs only: the model has no event for them. */
type Fault = "refresh_500" | "refresh_other_team" | "userinfo_500";
type Case = { id: string; cmd: Cmd; kind: Kind; expiry: Expiry; fault?: Fault };
type Observation = Case & {
  model: ModelKind;
  login: Login;
  signedAs: Account;
  asked: string[];
  form: Form;
  ask: Ask;
  saved: Account;
  afterKill: "none" | "kept" | "lost";
  anomalies: string[];
  evidence: Record<string, unknown>;
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const USER_SUB = "user_tla_sub";
const USER_CLAIM = "user_tla_claim";
const TEAM_ID = "team_tla_e2e";
const ANSWER = "GROK_IDENTITY_DRIVER_ANSWER";
const MODEL = "grok-4.20";
const tlaDir = join(TLA_ROOT, "grok_oauth");
// Absolute, because every fx starts in a scratch folder of its own.
const binary = resolve(binaryPath);

type Principal = { type: "User" | "Team" | "none"; id: string };
type KindSpec = {
  model: ModelKind;
  /** The principal the browser authorization picks; none for a token without claims. */
  principal: Principal;
  /** How the token carries it: as a JWT with snake or camel claims, or not a JWT at all. */
  style: "snake" | "camel" | "opaque" | "noclaims";
  /** Extra payload bytes, for the large token. */
  pad?: number;
  /** For Team kinds whose id is missing from the claims. */
  omitId?: boolean;
};

const KINDS: Record<Kind, KindSpec> = {
  user: { model: "user", principal: { type: "User", id: USER_CLAIM }, style: "snake" },
  opaque: { model: "opaque", principal: { type: "none", id: "" }, style: "opaque" },
  noclaims: { model: "opaque", principal: { type: "none", id: "" }, style: "noclaims" },
  team: { model: "team", principal: { type: "Team", id: TEAM_ID }, style: "snake" },
  team_camel: { model: "team", principal: { type: "Team", id: `${TEAM_ID}_camel` }, style: "camel" },
  team_max_id: { model: "team", principal: { type: "Team", id: "t".repeat(1024) }, style: "snake" },
  team_big_token: { model: "team", principal: { type: "Team", id: TEAM_ID }, style: "snake", pad: 6000 },
  team_missing_id: { model: "team_bad_id", principal: { type: "Team", id: "" }, style: "snake", omitId: true },
  team_unsafe_id: { model: "team_bad_id", principal: { type: "Team", id: "team tla" }, style: "snake" },
  team_long_id: { model: "team_bad_id", principal: { type: "Team", id: "t".repeat(1025) }, style: "snake" },
};

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}
const modelAt = process.argv.indexOf("--model");
const casesAt = process.argv.indexOf("--cases");
const options = {
  /** Which model the runs must fit: the design, or fx before the fix (to show the model of today is fx on main). */
  model: (modelAt < 0 ? "design" : process.argv[modelAt + 1]) as "design" | "today",
  selfCheck: process.argv.includes("--self-check"),
  jobs: Math.max(1, option("--jobs", 4)),
  stress: option("--stress", 0),
  /** Check each run against the outcome the design gives it, without TLC. */
  direct: process.argv.includes("--direct"),
  /** Only the scripted runs whose id starts with one of these, or none for "none". */
  cases: casesAt < 0 ? null : (process.argv[casesAt + 1] ?? "").split(",").filter(Boolean),
  faults: process.argv.includes("--faults"),
  race: option("--race", 0),
  seed: option("--seed", Date.now() % 2_147_483_647),
};

function cases(): Case[] {
  const out: Case[] = [];
  for (const kind of Object.keys(KINDS) as Kind[]) {
    out.push({ id: `login-${kind}`, cmd: "login", kind, expiry: "none" });
  }
  for (const kind of ["user", "opaque", "noclaims", "team", "team_camel", "team_max_id", "team_big_token"] as Kind[]) {
    out.push({ id: `login-refresh-${kind}`, cmd: "login_refresh", kind, expiry: "none" });
  }
  for (const kind of ["user", "opaque", "noclaims", "team", "team_camel"] as Kind[]) {
    out.push({ id: `refresh-${kind}-past`, cmd: "refresh", kind, expiry: "past" });
  }
  for (const kind of ["user", "team"] as Kind[]) {
    out.push({ id: `refresh-${kind}-inside`, cmd: "refresh", kind, expiry: "inside" });
    out.push({ id: `fresh-${kind}-outside`, cmd: "fresh", kind, expiry: "outside" });
  }
  out.push({ id: "fresh-team-hour", cmd: "fresh", kind: "team", expiry: "hour" });
  out.push({ id: "refresh-killed-team", cmd: "refresh_killed", kind: "team", expiry: "past" });
  // A saved login whose token names a Team with an unsafe id, beside a usable account id.
  out.push({ id: "refresh-team_unsafe_id-past", cmd: "refresh", kind: "team_unsafe_id", expiry: "past" });
  return out;
}

/** Runs whose issuer fails on purpose. */
function faultCases(): Case[] {
  return [
    // A transient failure keeps the Team login for the next fx.
    { id: "fault-refresh-500-team", cmd: "refresh", kind: "team", expiry: "past", fault: "refresh_500" },
    // A refresh that comes back as another Team is another account, and the login is retired.
    { id: "fault-refresh-other-team", cmd: "refresh", kind: "team", expiry: "past", fault: "refresh_other_team" },
    // A personal sign-in still depends on userinfo.
    { id: "fault-userinfo-500-user", cmd: "login", kind: "user", expiry: "none", fault: "userinfo_500" },
  ];
}

/** What the design gives each run, for --direct. */
function expected(c: Case): Pick<Observation, "login" | "signedAs" | "asked" | "form" | "ask" | "saved" | "afterKill"> {
  const spec = KINDS[c.kind];
  const personal = spec.model === "user" || spec.model === "opaque";
  const account: Account = spec.model === "team" ? "t1" : spec.model === "team_bad_id" ? "none" : "u1";
  const asked = personal ? [spec.principal.type] : [];
  const fields: Form = personal ? "none" : "team";
  const none = { login: "not_run" as Login, signedAs: "none" as Account, afterKill: "none" as const };
  if (c.fault === "refresh_500") return { ...none, asked: [], form: "team", ask: "failed", saved: "t1" };
  if (c.fault === "refresh_other_team") return { ...none, asked: [], form: "team", ask: "account_changed", saved: "none" };
  if (c.fault === "userinfo_500") return { ...none, login: "failed", asked: ["User"], form: "no_refresh", ask: "not_run", saved: "none" };
  switch (c.cmd) {
    case "login":
      return spec.model === "team_bad_id"
        ? { ...none, login: "failed", asked: [], form: "no_refresh", ask: "not_run", saved: "none" }
        : { ...none, login: "signed_in", signedAs: account, asked, form: "no_refresh", ask: "not_run", saved: account };
    case "login_refresh":
      return { ...none, login: "signed_in", signedAs: account, asked, form: fields, ask: "answered", saved: account };
    case "refresh":
      return spec.model === "team_bad_id"
        ? { ...none, asked: [], form: "no_refresh", ask: "signed_out", saved: "none" }
        : { ...none, asked, form: fields, ask: "answered", saved: account };
    case "refresh_killed":
      return { ...none, asked: [], form: "team", ask: "answered", saved: "t1", afterKill: "kept" };
    case "fresh":
      return { ...none, asked: [], form: "no_refresh", ask: "answered", saved: account };
  }
}

/** A small seeded generator, so a race round can be replayed from its seed. */
function random(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function b64url(value: unknown): string {
  return Buffer.from(typeof value === "string" ? value : JSON.stringify(value)).toString("base64url");
}

/** The fake issuer for one run: it mints every token, so it knows each one's principal. */
function startIssuer(c: Case, helpers: any) {
  const spec = KINDS[c.kind];
  const tokens = new Map<string, Principal>();
  const refreshTokens = new Set<string>();
  const requests: string[] = [];
  const unexpected: string[] = [];
  const asked: string[] = [];
  const forms: Form[] = [];
  const responses: Array<{ authorization: string | null; userId: string | null }> = [];
  let exchanges = 0;
  let minted = 0;
  let holdRefresh: ((value: Response) => void) | null = null;
  let onRefreshHeld: () => void = () => {};
  let holdNext = false;
  let failFirstResponse = false;
  let refreshDelayMs = 0;

  function mint(principal: Principal): string {
    minted += 1;
    const jti = `${c.id}-${minted}`;
    let token: string;
    if (spec.style === "opaque") {
      token = `grok-opaque-${jti}`;
    } else {
      let claims: Record<string, unknown>;
      if (spec.style === "noclaims" || principal.type === "none") {
        claims = { sub: USER_SUB, iss: "fake-xai", jti };
      } else if (spec.style === "camel") {
        claims = { principalType: principal.type, principalId: principal.id, jti };
      } else {
        claims = { principal_type: principal.type, jti };
        if (!(spec.omitId && principal.type === "Team")) claims.principal_id = principal.id;
      }
      if (spec.pad) claims.pad = "x".repeat(spec.pad);
      token = `${b64url({ alg: "RS256", typ: "JWT" })}.${b64url(claims)}.sig-${jti}`;
    }
    tokens.set(token, principal);
    return token;
  }
  function refreshToken(): string {
    const token = `rt-${c.id}-${refreshTokens.size}`;
    refreshTokens.add(token);
    return token;
  }
  /** The token a refresh with no principal fields gets: the person's own account. */
  function personal(): Principal {
    return spec.principal.type === "none" ? spec.principal : { type: "User", id: USER_CLAIM };
  }
  function bearer(request: Request): Principal | undefined {
    const header = request.headers.get("authorization") ?? "";
    return header.startsWith("Bearer ") ? tokens.get(header.slice(7)) : undefined;
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = request.method === "POST" ? await request.text() : "";
      requests.push(`${request.method} ${url.pathname}`);
      if (url.pathname === "/oauth2/authorize") {
        const redirect = url.searchParams.get("redirect_uri");
        const state = url.searchParams.get("state");
        if (!redirect || !state) return new Response("invalid authorize request", { status: 400 });
        const callback = new URL(redirect);
        callback.searchParams.set("code", `code-${c.id}`);
        callback.searchParams.set("state", state);
        return Response.redirect(callback.toString(), 302);
      }
      if (url.pathname === "/oauth2/token") {
        const form = new URLSearchParams(body);
        if (form.get("client_id") !== "b1a00492-073a-47ea-816f-4c329264a828") unexpected.push("token request with another client");
        if (form.get("grant_type") === "authorization_code") {
          exchanges += 1;
          if (form.get("code") !== `code-${c.id}`) unexpected.push("code exchange with an unknown code");
          return Response.json({ access_token: mint(spec.principal), refresh_token: refreshToken(), expires_in: 3600 });
        }
        if (form.get("grant_type") !== "refresh_token") {
          unexpected.push(`token grant ${form.get("grant_type")}`);
          return Response.json({ error: "unsupported_grant_type" }, { status: 400 });
        }
        if (!refreshTokens.has(form.get("refresh_token") ?? "")) {
          unexpected.push("refresh with an unknown refresh token");
          return Response.json({ error: "invalid_grant" }, { status: 400 });
        }
        const type = form.get("principal_type");
        const id = form.get("principal_id");
        let next: Principal;
        if (type === null && id === null) {
          forms.push("none");
          next = personal();
        } else if (type === "Team" && id === spec.principal.id) {
          forms.push("team");
          next = { type: "Team", id };
        } else if (type === "Team") {
          forms.push("team");
          unexpected.push(`refresh named another Team (${String(id).slice(0, 40)})`);
          next = { type: "Team", id: id ?? "" };
        } else {
          forms.push("user");
          next = personal();
        }
        if (c.fault === "refresh_500") return Response.json({ error: "server_error" }, { status: 500 });
        if (c.fault === "refresh_other_team" && next.type === "Team") next = { type: "Team", id: `${TEAM_ID}_other` };
        if (refreshDelayMs > 0) await Bun.sleep(refreshDelayMs);
        const reply = Response.json({ access_token: mint(next), refresh_token: refreshToken(), expires_in: 3600 });
        if (holdNext) {
          holdNext = false;
          // Answered only after the driver has killed the fx that asked.
          return await new Promise<Response>((resolve) => {
            holdRefresh = resolve;
            onRefreshHeld();
          });
        }
        return reply;
      }
      if (url.pathname === "/oauth2/userinfo") {
        const principal = bearer(request);
        if (!principal) {
          unexpected.push("userinfo with a token the issuer never minted");
          return Response.json({ error: "invalid_token" }, { status: 401 });
        }
        asked.push(principal.type);
        if (c.fault === "userinfo_500") return Response.json({ error: "server_error" }, { status: 500 });
        if (principal.type === "Team") {
          return Response.json({ error: "insufficient_scope", error_description: "team principals have no user info" }, { status: 403 });
        }
        return Response.json({ sub: USER_SUB });
      }
      if (url.pathname === "/v1/models") {
        return Response.json({ data: [{ id: MODEL, model: MODEL, api_backend: "responses", context_window: 1_000_000, supports_reasoning_effort: false, reasoning_efforts: [] }] });
      }
      if (url.pathname === "/v1/language-models") {
        return Response.json({ models: [{ id: MODEL, input_modalities: ["text"], output_modalities: ["text"] }] });
      }
      if (url.pathname === "/v1/responses") {
        if (body.includes(helpers.TITLE_GENERATION_MARKER)) return helpers.fakeResponsesTitleDefault();
        const principal = bearer(request);
        responses.push({ authorization: principal ? principal.type : null, userId: request.headers.get("x-grok-user-id") });
        if (!principal) unexpected.push("a model request with a token the issuer never minted");
        if (failFirstResponse) {
          failFirstResponse = false;
          return Response.json({ error: { message: "expired" } }, { status: 401 });
        }
        return new Response(
          `data: ${JSON.stringify({ type: "response.output_text.delta", delta: ANSWER })}\n\n` +
            'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}\n\n',
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      unexpected.push(`${request.method} ${url.pathname}`);
      return new Response("not found", { status: 404 });
    },
  });
  const base = `http://127.0.0.1:${server.port}`;
  return {
    base,
    env: {
      FX_TEST_GROK_ISSUER_URL: base,
      FX_TEST_GROK_TOKEN_URL: `${base}/oauth2/token`,
      FX_TEST_GROK_USERINFO_URL: `${base}/oauth2/userinfo`,
      FX_TEST_GROK_REVOKE_URL: `${base}/oauth2/revoke`,
      FX_TEST_GROK_ORIGIN: base,
      FX_TEST_GROK_VERSION_URL: `${base}/version`,
      FX_TEST_GROK_CLIENT_VERSION: "1.0.6",
      FX_TEST_XAI_GROK_MODELS_URL: `${base}/v1/models`,
      FX_TEST_XAI_GROK_MODALITIES_URL: `${base}/v1/language-models`,
      FX_TEST_XAI_GROK_RESPONSES_URL: `${base}/v1/responses`,
    } as Record<string, string>,
    requests,
    unexpected,
    asked,
    forms,
    responses,
    exchanges: () => exchanges,
    mintSeed: () => ({ access: mint(spec.principal), refresh: refreshToken() }),
    failFirstResponse() { failFirstResponse = true; },
    holdNextRefresh(onHeld: () => void) { holdNext = true; onRefreshHeld = onHeld; },
    delayRefresh(ms: number) { refreshDelayMs = ms; },
    releaseHeld() { holdRefresh?.(Response.json({ error: "server_error" }, { status: 500 })); holdRefresh = null; },
    stop() { server.stop(true); },
  };
}

type Issuer = ReturnType<typeof startIssuer>;

function startGateway() {
  const requests: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      requests.push(`${request.method} ${new URL(request.url).pathname}`);
      return new Response("the fake gateway is not part of this run", { status: 500 });
    },
  });
  const base = `http://127.0.0.1:${server.port}`;
  return { base, requests, stop() { server.stop(true); } };
}

function expiresAt(expiry: Expiry): number {
  const now = Date.now();
  switch (expiry) {
    case "past": return now - 3_600_000;
    case "inside": return now + 45_000;
    case "outside": return now + 90_000;
    case "hour": return now + 3_600_000;
    case "none": return now;
  }
}

/** The account a seeded login is saved under: a Team with no usable id keeps a usable one. */
function accountFor(kind: Kind): string {
  const spec = KINDS[kind];
  if (spec.model === "team_bad_id") return TEAM_ID;
  return spec.principal.type === "Team" ? spec.principal.id : USER_SUB;
}

function seedLogin(fxHome: string, c: Case, issuer: Issuer): { path: string; bytes: string } {
  mkdirSync(fxHome, { recursive: true, mode: 0o700 });
  chmodSync(fxHome, 0o700);
  const path = join(fxHome, "grok-auth.json");
  const seed = issuer.mintSeed();
  const bytes = `${JSON.stringify({
    version: 1,
    access_token: seed.access,
    refresh_token: seed.refresh,
    expires_at_ms: expiresAt(c.expiry),
    account_id: accountFor(c.kind),
  })}\n`;
  writeFileSync(path, bytes, { mode: 0o600 });
  chmodSync(path, 0o600);
  return { path, bytes };
}

function readAccount(path: string, kind: Kind): Account {
  if (!existsSync(path)) return "none";
  let account: unknown;
  try {
    account = JSON.parse(readFileSync(path, "utf8")).account_id;
  } catch {
    return "bad";
  }
  if (account === USER_SUB) return "u1";
  if (account === USER_CLAIM) return "u_claim";
  if (account === accountFor(kind) && KINDS[kind].principal.type === "Team") return "t1";
  return "bad";
}

type Spawned = { exit: number | null; signal: string | null; stdout: string; stderr: string };

/** One fx process through env -i, with every variable on the command line. */
async function runFx(
  vars: Record<string, string>,
  args: string[],
  cwd: string,
  during?: (child: ReturnType<typeof Bun.spawn>, output: () => string) => Promise<void>,
): Promise<Spawned> {
  for (const key of ["FX_TEST_GROK_ISSUER_URL", "FX_TEST_GROK_TOKEN_URL", "FX_TEST_GROK_USERINFO_URL", "FX_TEST_XAI_GROK_RESPONSES_URL"]) {
    if (!vars[key]?.startsWith("http://127.0.0.1:")) throw new Error(`${key} is not a loopback fake; refusing to start fx`);
  }
  const argv = ["/usr/bin/env", "-i", ...Object.entries(vars).map(([k, v]) => `${k}=${v}`), binary, ...args];
  const child = Bun.spawn(argv, { cwd, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  let stdout = "";
  let stderr = "";
  const decoder = new TextDecoder();
  const pump = async (stream: ReadableStream<Uint8Array>, add: (text: string) => void) => {
    for await (const chunk of stream) add(decoder.decode(chunk, { stream: true }));
  };
  const reading = Promise.all([
    pump(child.stdout as ReadableStream<Uint8Array>, (t) => { stdout += t; }),
    pump(child.stderr as ReadableStream<Uint8Array>, (t) => { stderr += t; }),
  ]);
  const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
  try {
    if (during) await during(child, () => stdout);
    await child.exited;
    await reading;
  } catch (error) {
    child.kill("SIGKILL");
    await child.exited;
    throw error;
  } finally {
    clearTimeout(timer);
  }
  const signal = child.signalCode ?? null;
  return { exit: signal === null ? child.exitCode : null, signal, stdout, stderr };
}

function classifyAsk(run: Spawned): Ask {
  let json: any = null;
  try {
    json = JSON.parse(run.stdout);
  } catch {
    json = null;
  }
  if (run.exit === 0 && typeof json?.output === "string" && json.output.includes(ANSWER)) return "answered";
  if (run.exit === 1) {
    switch (json?.error) {
      // The failed refresh deleted the login, so fx asks to sign in again.
      case "MissingCredentials":
      case "CredentialRefreshRejected":
        return "signed_out";
      case "CredentialAuthorityChanged":
      case "GrokAccountChanged":
        return "account_changed";
    }
    if (typeof json?.error === "string") return "failed";
  }
  return "unknown";
}

async function runCase(c: Case, helpers: any, scratch: string): Promise<Observation[]> {
  const root = mkdtempSync(join(scratch, `${c.id}-`));
  const home = join(root, "home");
  const tmp = join(root, "tmp");
  const fxHome = join(home, ".fx");
  mkdirSync(home, { recursive: true });
  mkdirSync(tmp, { recursive: true });
  const issuer = startIssuer(c, helpers);
  const gateway = startGateway();
  const authPath = join(fxHome, "grok-auth.json");
  const vars: Record<string, string> = {
    HOME: home,
    PATH: "/usr/bin:/bin",
    TMPDIR: tmp,
    FX_HOME: fxHome,
    FX_DISABLE_KEYCHAIN: "1",
    FX_SOUND: "0",
    FX_AUTO_UPGRADE: "0",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_NO_OPEN_BROWSER: "1",
    NO_COLOR: "1",
    AI_GATEWAY_API_KEY: "fake-grok-identity-key",
    FX_GATEWAY_BASE_URL: gateway.base,
    FX_GATEWAY_CHAT_URL: `${gateway.base}/v1/chat/completions`,
    ...issuer.env,
  };
  const askVars = { ...vars, FX_PROVIDER: "grok", FX_MODEL: MODEL };
  const askArgs = ["ask", "--json", "--no-save", "Answer directly."];
  const evidence: Record<string, unknown> = {};
  const anomalies: string[] = [];
  const observations: Observation[] = [];
  const started = performance.now();
  try {
    let login: Login = "not_run";
    let signedAs: Account = "none";
    let ask: Ask = "not_run";
    let afterKill: Observation["afterKill"] = "none";
    let askRan = false;
    let refreshesExpected = 0;
    // A run whose saved Team token names no usable id may send one refresh or none; the model says which is right.
    let refreshesAllowed = 0;
    let responsesExpected = 0;

    if (c.cmd === "login" || c.cmd === "login_refresh") {
      const run = await runFx(vars, ["login", "grok"], root, async (_child, output) => {
        const deadline = Date.now() + 20_000;
        let url: string | undefined;
        while (Date.now() < deadline && !url) {
          url = output().match(/http:\/\/127\.0\.0\.1:\d+\/oauth2\/authorize\?\S+/)?.[0];
          if (!url) await Bun.sleep(20);
        }
        if (!url) throw new Error(`fx login grok printed no authorization URL: ${output()}`);
        if (!url.startsWith(issuer.base)) throw new Error(`fx login grok sent the browser to ${url}, not the fake issuer`);
        // The browser step: the fake issuer redirects to fx's loopback callback.
        evidence.callbackStatus = (await fetch(url, { redirect: "follow" })).status;
      });
      evidence.login = { exit: run.exit, signal: run.signal, stdout: run.stdout.slice(-400), stderr: run.stderr.slice(-400) };
      if (run.signal !== null || run.exit === null || run.exit > 1) anomalies.push(`fx login grok crashed: ${JSON.stringify(evidence.login)}`);
      login = run.exit === 0 && run.stdout.includes("Signed in with Grok.") ? "signed_in" : "failed";
      if (run.exit === 0 && login === "failed") anomalies.push("fx login grok exited 0 without signing in");
      if (issuer.exchanges() !== 1) anomalies.push(`${issuer.exchanges()} code exchanges`);
      signedAs = login === "signed_in" ? readAccount(authPath, c.kind) : "none";
      if (c.cmd === "login_refresh" && login === "signed_in") {
        issuer.failFirstResponse();
        const run2 = await runFx(askVars, askArgs, root);
        evidence.ask = { exit: run2.exit, signal: run2.signal, stdout: run2.stdout.slice(-400), stderr: run2.stderr.slice(-400) };
        ask = classifyAsk(run2);
        askRan = true;
        refreshesExpected = 1;
        responsesExpected = ask === "answered" ? 2 : 1;
      }
    } else if (c.cmd === "refresh_killed") {
      const seeded = seedLogin(fxHome, c, issuer);
      let killedAt = "";
      const first = await runFx(askVars, askArgs, root, async (child) => {
        await new Promise<void>((resolve) => issuer.holdNextRefresh(resolve));
        child.kill("SIGKILL");
        killedAt = new Date().toISOString();
      });
      evidence.killed = { exit: first.exit, signal: first.signal, killedAt };
      if (first.signal !== "SIGKILL") anomalies.push(`the first fx was not killed: ${JSON.stringify(evidence.killed)}`);
      issuer.releaseHeld();
      afterKill = existsSync(authPath) && readFileSync(authPath, "utf8") === seeded.bytes ? "kept" : "lost";
      const run = await runFx(askVars, askArgs, root);
      evidence.ask = { exit: run.exit, signal: run.signal, stdout: run.stdout.slice(-400), stderr: run.stderr.slice(-400) };
      ask = classifyAsk(run);
      askRan = true;
      refreshesExpected = 2;
      responsesExpected = ask === "answered" ? 1 : 0;
    } else {
      seedLogin(fxHome, c, issuer);
      const run = await runFx(askVars, askArgs, root);
      evidence.ask = { exit: run.exit, signal: run.signal, stdout: run.stdout.slice(-400), stderr: run.stderr.slice(-400) };
      ask = classifyAsk(run);
      askRan = true;
      refreshesExpected = c.cmd === "refresh" && KINDS[c.kind].model !== "team_bad_id" ? 1 : 0;
      refreshesAllowed = c.cmd === "refresh" ? 1 : 0;
      responsesExpected = ask === "answered" ? 1 : 0;
    }

    if (askRan) {
      const ran = evidence.ask as Spawned;
      if (ran.signal !== null || ran.exit === null || ran.exit > 1) anomalies.push(`fx ask crashed: ${JSON.stringify(ran)}`);
      const allowed = Math.max(refreshesExpected, refreshesAllowed);
      if (issuer.forms.length < refreshesExpected || issuer.forms.length > allowed) {
        anomalies.push(`${issuer.forms.length} refresh requests, expected ${refreshesExpected === allowed ? refreshesExpected : `${refreshesExpected} to ${allowed}`}`);
      }
      if (ask === "answered" && issuer.responses.length !== responsesExpected) {
        anomalies.push(`${issuer.responses.length} model requests, expected ${responsesExpected}`);
      }
      const account = accountFor(c.kind);
      for (const response of issuer.responses) {
        if (response.userId !== account) anomalies.push(`a model request named account ${String(response.userId).slice(0, 40)}`);
      }
    } else if (issuer.forms.length !== 0) {
      anomalies.push(`${issuer.forms.length} refresh requests without fx ask`);
    }
    if (new Set(issuer.forms).size > 1) anomalies.push(`refreshes sent different principal fields: ${issuer.forms.join(", ")}`);
    anomalies.push(...issuer.unexpected);
    if (gateway.requests.length > 0) anomalies.push(`the fake gateway got ${gateway.requests.join(", ")}`);

    const saved = readAccount(authPath, c.kind);
    evidence.requests = issuer.requests;
    evidence.seconds = Math.round(performance.now() - started) / 1000;
    observations.push({
      ...c,
      model: KINDS[c.kind].model,
      login,
      signedAs,
      asked: [...new Set(issuer.asked)].sort(),
      form: issuer.forms.at(-1) ?? "no_refresh",
      ask,
      saved,
      afterKill,
      anomalies,
      evidence,
    });
    return observations;
  } finally {
    issuer.stop();
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

/** N back-to-back fx ask runs on one Team login, each refreshing again. */
async function runStress(n: number, helpers: any, scratch: string): Promise<Observation[]> {
  const c: Case = { id: "stress-team", cmd: "refresh", kind: "team", expiry: "past" };
  const root = mkdtempSync(join(scratch, `${c.id}-`));
  const home = join(root, "home");
  const tmp = join(root, "tmp");
  const fxHome = join(home, ".fx");
  mkdirSync(home, { recursive: true });
  mkdirSync(tmp, { recursive: true });
  const issuer = startIssuer(c, helpers);
  const gateway = startGateway();
  const authPath = join(fxHome, "grok-auth.json");
  const vars: Record<string, string> = {
    HOME: home, PATH: "/usr/bin:/bin", TMPDIR: tmp, FX_HOME: fxHome,
    FX_DISABLE_KEYCHAIN: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_E2E_DISABLE_DOTENV: "1",
    FX_TEST_SKIP_ONBOARDING: "1", FX_NO_OPEN_BROWSER: "1", NO_COLOR: "1",
    AI_GATEWAY_API_KEY: "fake-grok-identity-key", FX_GATEWAY_BASE_URL: gateway.base,
    FX_GATEWAY_CHAT_URL: `${gateway.base}/v1/chat/completions`, FX_PROVIDER: "grok", FX_MODEL: MODEL,
    ...issuer.env,
  };
  const out: Observation[] = [];
  const started = performance.now();
  try {
    seedLogin(fxHome, c, issuer);
    for (let i = 0; i < n; i += 1) {
      // Move the clock past the login fx saved last, so this fx refreshes it again.
      const saved = JSON.parse(readFileSync(authPath, "utf8"));
      saved.expires_at_ms = expiresAt("past");
      writeFileSync(authPath, `${JSON.stringify(saved)}\n`, { mode: 0o600 });
      const formsBefore = issuer.forms.length;
      const responsesBefore = issuer.responses.length;
      const askedBefore = issuer.asked.length;
      const run = await runFx(vars, ["ask", "--json", "--no-save", "Answer directly."], root);
      const anomalies: string[] = [];
      if (run.signal !== null || run.exit === null || run.exit > 1) anomalies.push(`fx ask crashed: ${run.stderr.slice(-300)}`);
      const forms = issuer.forms.slice(formsBefore);
      if (forms.length !== 1) anomalies.push(`${forms.length} refresh requests in round ${i + 1}`);
      if (issuer.responses.length - responsesBefore !== 1) anomalies.push(`${issuer.responses.length - responsesBefore} model requests in round ${i + 1}`);
      out.push({
        ...c,
        id: `stress-team-${i + 1}`,
        model: "team",
        login: "not_run",
        signedAs: "none",
        asked: [...new Set(issuer.asked.slice(askedBefore))].sort(),
        form: forms.at(-1) ?? "no_refresh",
        ask: classifyAsk(run),
        saved: readAccount(authPath, c.kind),
        afterKill: "none",
        anomalies,
        evidence: { exit: run.exit, stdout: run.stdout.slice(-200), stderr: run.stderr.slice(-200) },
      });
      if (out.at(-1)!.ask !== "answered") break;
    }
    if (gateway.requests.length > 0) out.at(-1)?.anomalies.push(`the fake gateway got ${gateway.requests.join(", ")}`);
    if (issuer.unexpected.length > 0) out.at(-1)?.anomalies.push(...issuer.unexpected);
    console.log(`stress: ${out.length} back-to-back refreshes of one Team login in ${((performance.now() - started) / 1000).toFixed(1)}s`);
    return out;
  } finally {
    issuer.stop();
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

/**
 * Rounds of two fx ask runs started together on one expired Team login. The
 * issuer holds each refresh a random time and the second fx starts a random
 * time after the first, from --seed. Only one may refresh: the other waits
 * for the login lock and finds the login fresh. Both must answer as the Team.
 */
async function runRace(rounds: number, seed: number, helpers: any, scratch: string): Promise<string[]> {
  const next = random(seed);
  const failures: string[] = [];
  const started = performance.now();
  for (let round = 1; round <= rounds; round += 1) {
    const c: Case = { id: `race-${round}`, cmd: "refresh", kind: "team", expiry: "past" };
    const root = mkdtempSync(join(scratch, `${c.id}-`));
    const home = join(root, "home");
    const tmp = join(root, "tmp");
    const fxHome = join(home, ".fx");
    mkdirSync(home, { recursive: true });
    mkdirSync(tmp, { recursive: true });
    const issuer = startIssuer(c, helpers);
    const gateway = startGateway();
    const delay = Math.floor(next() * 300);
    const offset = Math.floor(next() * 100);
    issuer.delayRefresh(delay);
    try {
      seedLogin(fxHome, c, issuer);
      const vars: Record<string, string> = {
        HOME: home, PATH: "/usr/bin:/bin", TMPDIR: tmp, FX_HOME: fxHome,
        FX_DISABLE_KEYCHAIN: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_E2E_DISABLE_DOTENV: "1",
        FX_TEST_SKIP_ONBOARDING: "1", FX_NO_OPEN_BROWSER: "1", NO_COLOR: "1",
        AI_GATEWAY_API_KEY: "fake-grok-identity-key", FX_GATEWAY_BASE_URL: gateway.base,
        FX_GATEWAY_CHAT_URL: `${gateway.base}/v1/chat/completions`, FX_PROVIDER: "grok", FX_MODEL: MODEL,
        ...issuer.env,
      };
      const ask = ["ask", "--json", "--no-save", "Answer directly."];
      const first = runFx(vars, ask, root);
      await Bun.sleep(offset);
      const second = runFx(vars, ask, root);
      const runs = await Promise.all([first, second]);
      const problems: string[] = [];
      for (const [i, run] of runs.entries()) {
        if (classifyAsk(run) !== "answered") problems.push(`fx ${i + 1} ended ${classifyAsk(run)}: ${run.stderr.slice(-200)}`);
      }
      if (issuer.forms.length !== 1 || issuer.forms[0] !== "team") problems.push(`refreshes sent ${JSON.stringify(issuer.forms)}`);
      if (issuer.responses.length !== 2) problems.push(`${issuer.responses.length} model requests`);
      for (const response of issuer.responses) {
        if (response.userId !== TEAM_ID) problems.push(`a model request named ${String(response.userId).slice(0, 40)}`);
      }
      if (issuer.asked.length > 0) problems.push(`userinfo asked for ${issuer.asked.join(", ")}`);
      if (readAccount(join(fxHome, "grok-auth.json"), c.kind) !== "t1") problems.push("the saved login is no longer the Team");
      problems.push(...issuer.unexpected);
      if (gateway.requests.length > 0) problems.push(`the fake gateway got ${gateway.requests.join(", ")}`);
      if (problems.length > 0) failures.push(`round ${round} (refresh held ${delay} ms, second fx ${offset} ms later): ${problems.join("; ")}`);
    } finally {
      issuer.stop();
      gateway.stop();
      rmSync(root, { recursive: true, force: true });
    }
  }
  console.log(`race: ${rounds} rounds of two fx on one expired Team login in ${((performance.now() - started) / 1000).toFixed(1)}s, seed ${seed}, ${failures.length} failed`);
  return failures;
}

const str = (value: string) => JSON.stringify(value);

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[cmd |-> ${str(o.cmd)}, kind |-> ${str(o.model)}, login |-> ${str(o.login)}, signedAs |-> ${str(o.signedAs)}, ` +
    `asked |-> {${o.asked.map(str).join(", ")}}, form |-> ${str(o.form)}, ask |-> ${str(o.ask)}, ` +
    `saved |-> ${str(o.saved)}, afterKill |-> ${str(o.afterKill)}]`;
  return [
    "----------------------- MODULE GrokIdentityObserved -----------------------",
    "(* Generated by tests/tla/drivers/grok_oauth/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], model: "design" | "today", parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${model}-`));
  writeFileSync(join(dir, "GrokIdentityObserved.tla"), observedModule(observations));
  const design = model === "design";
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    '    Cmds = {"login", "login_refresh", "refresh", "refresh_killed", "fresh"}',
    '    Kinds = {"user", "opaque", "team", "team_bad_id"}',
    `    TeamClaim = ${design ? "TRUE" : "FALSE"}`,
    `    RefreshFields = ${design ? '"team"' : '"none"'}`,
    "    ValidateTeamId = TRUE",
    "    UserFromClaim = FALSE",
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "GrokIdentityTrace.tla", "trace.cfg", ["GrokIdentity.tla", "GrokIdentityTrace.tla"], tlaDir);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first run the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], model: "design" | "today", parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), model, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

function summary(o: Observation) {
  const { evidence, ...rest } = o;
  return { ...rest, evidence };
}

async function main(): Promise<number> {
  if (!existsSync(binary)) {
    console.log(`TOOL_ERROR: missing ${binary}; run zig build first or set FX_BIN`);
    return 2;
  }
  const helpers = await targetHelpers();
  const out = outDir("grok-oauth");
  const scratch = join(out, "runs");
  mkdirSync(scratch, { recursive: true });
  if (!options.direct && (options.faults || options.race > 0)) throw new Error("--faults and --race run only with --direct");
  const scripted = options.cases === null ? cases() : cases().filter((c) => options.cases!.some((prefix) => c.id.startsWith(prefix)));
  const all = [...scripted, ...(options.faults ? faultCases() : [])];
  const results: Observation[][] = new Array(all.length);
  const started = performance.now();
  let next = 0;
  await Promise.all(Array.from({ length: options.jobs }, async () => {
    while (next < all.length) {
      const index = next++;
      results[index] = await runCase(all[index]!, helpers, scratch);
    }
  }));
  const observations = results.flat();
  if (options.stress > 0) observations.push(...await runStress(options.stress, helpers, scratch));
  writeJson(join(out, "observations.json"), observations);
  const counts: Record<string, number> = {};
  for (const o of observations) {
    const key = `${o.login}/${o.ask}`;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  console.log(`${observations.length} runs of ${binary} in ${((performance.now() - started) / 1000).toFixed(1)}s, login/ask ${JSON.stringify(counts)}`);
  console.log(`observations: ${join(out, "observations.json")}`);

  const odd = observations.find((o) => o.anomalies.length > 0);
  if (odd) {
    console.log(`REJECTED: run ${odd.id} did what the fakes did not expect: ${odd.anomalies.join("; ")}`);
    console.log(JSON.stringify(summary(odd)));
    return 1;
  }
  const unread = observations.find((o) => o.ask === "unknown");
  if (unread) {
    console.log(`REJECTED: run ${unread.id} ended in a way the driver cannot read: ${JSON.stringify(summary(unread))}`);
    return 1;
  }

  if (options.direct) {
    let failed = 0;
    for (const o of observations) {
      const fields = ["login", "signedAs", "asked", "form", "ask", "saved", "afterKill"] as const;
      const pick = (from: Record<string, unknown>) => Object.fromEntries(fields.map((key) => [key, key === "asked" ? [...(from[key] as string[])].sort() : from[key]]));
      const want = pick(expected(o));
      const got = pick(o);
      const same = JSON.stringify(got) === JSON.stringify(want);
      if (!same) failed += 1;
      console.log(`${same ? "ok  " : "FAIL"}  ${o.id}: ${JSON.stringify(got)}${same ? "" : ` (the design gives ${JSON.stringify(want)})`}`);
    }
    const raceFailures = options.race > 0 ? await runRace(options.race, options.seed, helpers, scratch) : [];
    for (const failure of raceFailures) console.log(`FAIL  ${failure}`);
    if (failed > 0 || raceFailures.length > 0) {
      console.log(`REJECTED: ${failed} runs and ${raceFailures.length} race rounds differ from the design`);
      return 1;
    }
    console.log(`ACCEPTED: ${observations.length} runs${options.race > 0 ? ` and ${options.race} race rounds` : ""} match the design`);
    return 0;
  }

  if (options.model !== "design" && options.model !== "today") throw new Error("--model takes design or today");
  const checked = await runTrace(observations, options.model, out);
  console.log(`${options.model}: ${checked.verdict} (TLC work ${checked.dir})`);
  if (checked.verdict === "TOOL_ERROR") return 2;
  if (checked.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, options.model, out);
    console.log(`first run the model cannot produce: ${JSON.stringify(mismatch ? summary(mismatch) : null)}`);
    return 1;
  }
  if (options.selfCheck) {
    const other = options.model === "design" ? "today" : "design";
    const rejected = await runTrace(observations, other, out);
    console.log(`self-check, the ${other === "today" ? "model of fx before the fix" : "design"}: ${rejected.verdict} (must be REJECTED)`);
    if (rejected.verdict !== "REJECTED") return rejected.verdict === "TOOL_ERROR" ? 2 : 1;
  }
  console.log("ACCEPTED");
  return 0;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
