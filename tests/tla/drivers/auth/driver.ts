// Runs the built fx binary along tests/tla/auth/SignInTeams.tla and has TLC
// check every sign-in it observes (SignInTeamsTrace.tla).
//
// Each run signs in to a local fake Vercel issuer whose /v2/teams answers one
// response from the model's set: a failed request, a body that is not a team
// list, or a list of up to --depth entries of each kind (a plain team, a name
// with control characters, a name with nothing printable, a slug with a
// control character, an unreadable entry). `fx login` runs for every response,
// from a fresh profile and from one with a saved sign-in. The in-app /login
// runs in tmux, from a profile with only an environment key, for every
// response of at most one entry and three pairs.
//
// For each run it records what the person was told, what the saved sign-in
// holds after (compared byte for byte with what it held before), how many
// teams fx login listed, whether fx wrote a control character, and whether fx
// was still running. TLC replays the runs through the model (Rule =
// "design"). --self-check also replays them through the model of fx before
// the change (Rule = "today"), which must reject them; --rule today checks
// them against that model alone, which accepts a run of fx from before the
// change. --stress N adds fx login runs whose list holds N teams with control
// characters in every name, and one list past the 4 MiB response limit, and
// prints their wall time and the binary's peak memory.
//
// Every fx process gets FX_SOUND=0, FX_DISABLE_KEYCHAIN=1, its own HOME and
// FX_HOME, and talks only to the local fakes.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/auth/driver.ts
//   bun tests/tla/drivers/auth/driver.ts --self-check
//   bun tests/tla/drivers/auth/driver.ts --rule today
//   bun tests/tla/drivers/auth/driver.ts --depth 1 --no-app --stress 50000
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Entry = "plain" | "ctl_name" | "ctl_only" | "ctl_slug" | "unreadable";
type Status = "error" | "garbage" | "ok";
type Resp = { status: Status; entries: Entry[] };
type Surface = "cli" | "app";
type Prior = "none" | "teamed";
type Saved = Prior | "new_teamless" | "new_teamed" | "unknown";
type Outcome =
  | "signed_in" | "teams_unavailable" | "no_teams" | "gateway_missing" | "notice_saved" | "crashed" | "unknown";
type Observation = {
  id: string;
  surface: Surface;
  prior: Prior;
  resp: Resp;
  outcome: Outcome;
  saved: Saved;
  offered: number;
  rawOut: boolean;
  alive: boolean;
  evidence: { exit: number | null; requests: string[]; tail: string; seconds: number; max_rss_bytes: number | null };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const ENTRIES: Entry[] = ["plain", "ctl_name", "ctl_only", "ctl_slug", "unreadable"];
const ACCESS_TOKEN = "auth-driver-login-token";
const SEEDED_TOKEN = "auth-driver-seeded-token";
// The size limit fx reads a team list under (src/core/auth/login_flow.zig).
const TEAMS_RESPONSE_MAX_BYTES = 4 * 1024 * 1024;
// A C0 control other than a line break, DEL, or a C1 control.
const TERMINAL_CONTROL = /[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/;
const tlaDir = join(TLA_ROOT, "auth");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

function ruleOption(): string {
  const at = process.argv.indexOf("--rule");
  return at < 0 ? "design" : process.argv[at + 1]!;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  rule: ruleOption(),
  depth: option("--depth", 2),
  app: !process.argv.includes("--no-app"),
  jobs: option("--jobs", 8),
  appJobs: option("--app-jobs", 3),
  stress: option("--stress", 0),
};

function lists(depth: number): Entry[][] {
  const out: Entry[][] = [];
  const grow = (prefix: Entry[]) => {
    out.push(prefix);
    if (prefix.length === depth) return;
    for (const entry of ENTRIES) grow([...prefix, entry]);
  };
  grow([]);
  return out;
}

function responses(depth: number): Resp[] {
  return [
    { status: "error", entries: [] },
    { status: "garbage", entries: [] },
    ...lists(depth).map((entries) => ({ status: "ok" as const, entries })),
  ];
}

// One concrete team-list entry for an abstract kind; index keeps ids apart.
function entryJson(kind: Entry, index: number): unknown {
  const id = `team_${index}`;
  const slug = `team-${index}`;
  switch (kind) {
    case "plain":
      return { id, slug, name: `Team ${index}` };
    case "ctl_name":
      return { id, slug, name: `Example\u001b[2J Team ${index}` };
    case "ctl_only":
      return { id, slug, name: "\u0007\r\n\u001b" };
    case "ctl_slug":
      return { id, slug: `bad\u001b[2Jslug-${index}`, name: `Slug Team ${index}` };
    case "unreadable": {
      const shapes = [{ id: index, slug }, `team-${index}`, { slug }, null, { id, slug: index }];
      return shapes[index % shapes.length];
    }
  }
}

function teamsResponse(resp: Resp, variant: number): Response {
  switch (resp.status) {
    case "error": {
      const statuses = [500, 401, 503];
      return new Response("upstream failure", { status: statuses[variant % statuses.length] });
    }
    case "garbage": {
      const bodies = ["<html></html>", "{\"teams\":\"none\"}", "{}", "[]"];
      return new Response(bodies[variant % bodies.length], { status: 200 });
    }
    case "ok":
      return Response.json({ teams: resp.entries.map((kind, index) => entryJson(kind, index)) });
  }
}

function startIssuer(answer: () => Response) {
  const requests: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      requests.push(`${request.method} ${url.pathname}`);
      const base = `http://127.0.0.1:${server.port}`;
      switch (url.pathname) {
        case "/.well-known/openid-configuration":
          return Response.json({
            issuer: base,
            device_authorization_endpoint: `${base}/oauth/device`,
            token_endpoint: `${base}/oauth/token`,
          });
        case "/oauth/device":
          return Response.json({
            device_code: "device-code",
            user_code: "AUTH-DRIVER",
            verification_uri: `${base}/verify`,
            verification_uri_complete: `${base}/verify?code=AUTH-DRIVER`,
            expires_in: 60,
            interval: 0,
          });
        case "/oauth/token":
          return Response.json({
            access_token: ACCESS_TOKEN,
            refresh_token: "auth-driver-refresh-token",
            expires_in: 3600,
            scope: "openid offline_access use:ai-gateway",
            token_type: "Bearer",
          });
        case "/v2/teams":
          return answer();
        default:
          return new Response("not found", { status: 404 });
      }
    },
  });
  return { url: `http://127.0.0.1:${server.port}`, requests, stop: () => server.stop(true) };
}

const SIGN_IN_REQUESTS = ["GET /.well-known/openid-configuration", "POST /oauth/device", "POST /oauth/token", "GET /v2/teams"];

function makeProfile(scratch: string, id: string, prior: Prior, issuerUrl: string) {
  const root = mkdtempSync(join(scratch, `${id}-`));
  const home = join(root, "home");
  const fxHome = join(root, "fx-home");
  mkdirSync(home, { recursive: true });
  mkdirSync(fxHome, { recursive: true, mode: 0o700 });
  chmodSync(fxHome, 0o700);
  const authPath = join(fxHome, "auth.json");
  let seeded: Buffer | null = null;
  if (prior === "teamed") {
    writeFileSync(authPath, JSON.stringify({
      version: 1,
      issuer: issuerUrl,
      client_id: "test-client",
      access_token: SEEDED_TOKEN,
      refresh_token: "auth-driver-seeded-refresh",
      expires_at_ms: Date.now() + 60 * 60 * 1000,
      scope: "openid",
      token_type: "Bearer",
      team_id: "team_seeded",
      team_slug: "seeded-team",
    }) + "\n", { mode: 0o600 });
    chmodSync(authPath, 0o600);
    seeded = readFileSync(authPath);
  }
  return { root, home, fxHome, authPath, seeded };
}

function savedState(authPath: string, seeded: Buffer | null): Saved {
  if (!existsSync(authPath)) return "none";
  const bytes = readFileSync(authPath);
  if (seeded && bytes.equals(seeded)) return "teamed";
  try {
    const saved = JSON.parse(bytes.toString()) as { access_token?: string; team_id?: string };
    if (saved.access_token === ACCESS_TOKEN) return saved.team_id ? "new_teamed" : "new_teamless";
  } catch {}
  return "unknown";
}

function fxEnv(helpers: any, profile: { home: string; fxHome: string }, issuerUrl: string, gateway: any) {
  return testEnvironment({
    HOME: profile.home,
    FX_HOME: profile.fxHome,
    FX_TEST_SKIP_ONBOARDING: "1",
    FX_NO_OPEN_BROWSER: "1",
    FX_OAUTH_CLIENT_ID: "test-client",
    FX_TEST_OAUTH_ISSUER_URL: issuerUrl,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
    AI_GATEWAY_API_KEY: "fake-auth-driver-key",
  });
}

async function runCli(helpers: any, id: string, prior: Prior, resp: Resp, variant: number, scratch: string, body?: () => Response): Promise<Observation> {
  const issuer = startIssuer(body ?? (() => teamsResponse(resp, variant)));
  const gateway = helpers.startFakeGateway([]);
  const profile = makeProfile(scratch, id, prior, issuer.url);
  try {
    const started = performance.now();
    const child = Bun.spawn([binary, "login"], {
      cwd: profile.root,
      env: fxEnv(helpers, profile, issuer.url, gateway),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 60_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
    const maxRss = child.resourceUsage()?.maxRSS ?? null;
    const alive = child.signalCode === null && exit < 128;
    let outcome: Outcome = "unknown";
    if (!alive) outcome = "crashed";
    else if (stderr.includes("Your Vercel teams could not be loaded")) outcome = "teams_unavailable";
    else if (stderr.includes("No Vercel teams are available")) outcome = "no_teams";
    else if (stderr.includes("configure a Gateway credential first")) outcome = "gateway_missing";
    else if (exit === 0 && stdout.includes("Signed in to Vercel.")) outcome = "signed_in";
    const listed = stdout.split("\n").filter((line) => /^ {2}\d+\. /.test(line)).length;
    const offered = listed > 0 ? listed : outcome === "signed_in" ? 1 : 0;
    return {
      id,
      surface: "cli",
      prior,
      resp,
      outcome,
      saved: savedState(profile.authPath, profile.seeded),
      offered,
      rawOut: TERMINAL_CONTROL.test(stdout),
      alive,
      evidence: { exit, requests: [...issuer.requests], tail: `${stdout.slice(-300)}\n${stderr.slice(-300)}`, seconds, max_rss_bytes: maxRss },
    };
  } finally {
    issuer.stop();
    gateway.stop();
    rmSync(profile.root, { recursive: true, force: true });
  }
}

async function runApp(helpers: any, id: string, resp: Resp, variant: number, scratch: string): Promise<Observation> {
  const issuer = startIssuer(() => teamsResponse(resp, variant));
  const gateway = helpers.startFakeGateway([]);
  const profile = makeProfile(scratch, id, "none", issuer.url);
  const stderrPath = join(profile.root, "stderr.log");
  writeFileSync(stderrPath, "");
  const started = performance.now();
  const session = await helpers.TmuxSession.create({
    cmd: binary,
    cwd: profile.root,
    env: fxEnv(helpers, profile, issuer.url, gateway),
    stderrPath,
    width: 100,
    height: 30,
    isolated: true,
  });
  let outcome: Outcome = "unknown";
  let pane = "";
  try {
    await session.waitForComposer(30_000);
    await session.sendText("/login");
    await session.waitForPane((text: string) => text.includes("vercel") && text.includes("codex") && text.includes("grok"), 30_000);
    await session.sendKeys("Enter");
    await session.waitForPane((text: string) => text.includes("oauth") && text.includes("api-key"), 30_000);
    await session.sendKeys("Enter");
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline && outcome === "unknown") {
      if (!session.isAlive()) {
        outcome = "crashed";
        break;
      }
      pane = await session.capturePane();
      if (pane.includes("Choose a team to finish setup")) {
        await session.waitForText("Vercel team", 30_000);
        await session.sendKeys("Enter");
        pane = await session.waitForPane((text: string) => text.includes("Changed Vercel team to"), 30_000)
          .catch(async () => (session.isAlive() ? await session.capturePane() : ""));
        outcome = session.isAlive() ? (pane.includes("Changed Vercel team to") ? "signed_in" : "unknown") : "crashed";
      } else if (pane.includes("Your Vercel teams could not be loaded")) outcome = "teams_unavailable";
      else if (pane.includes("No Vercel teams are available")) outcome = "no_teams";
      else if (pane.includes("no Vercel teams could be loaded")) outcome = "notice_saved";
      else await Bun.sleep(50);
    }
    const alive = session.isAlive();
    if (!alive) outcome = "crashed";
    return {
      id,
      surface: "app",
      prior: "none",
      resp,
      outcome,
      saved: savedState(profile.authPath, profile.seeded),
      offered: -1,
      rawOut: false,
      alive,
      evidence: {
        exit: null,
        requests: [...issuer.requests],
        tail: `${pane.slice(-400)}\n${readFileSync(stderrPath, "utf8").slice(-300)}`,
        seconds: Number(((performance.now() - started) / 1000).toFixed(2)),
        max_rss_bytes: null,
      },
    };
  } finally {
    await session.kill();
    issuer.stop();
    gateway.stop();
    rmSync(profile.root, { recursive: true, force: true });
  }
}

const str = (value: string) => JSON.stringify(value);

function observedModule(observations: Observation[]): string {
  const resp = (r: Resp) => `[status |-> ${str(r.status)}, entries |-> <<${r.entries.map(str).join(", ")}>>]`;
  const value = (o: Observation) =>
    `[surface |-> ${str(o.surface)}, prior |-> ${str(o.prior)}, resp |-> ${resp(o.resp)}, outcome |-> ${str(o.outcome)}, ` +
    `saved |-> ${str(o.saved)}, offered |-> ${o.offered}, rawOut |-> ${o.rawOut ? "TRUE" : "FALSE"}, alive |-> ${o.alive ? "TRUE" : "FALSE"}]`;
  return [
    "------------------------ MODULE SignInTeamsObserved ------------------------",
    "(* Generated by tests/tla/drivers/auth/driver.ts. Do not edit. *)",
    "EXTENDS Integers, Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], rule: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${rule}-`));
  writeFileSync(join(dir, "SignInTeamsObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    "  Surfaces = {\"cli\", \"app\"}",
    "  Priors = {\"none\", \"teamed\"}",
    "  MaxEntries = 2",
    `  Rule = ${str(rule)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "SignInTeamsTrace.tla", "trace.cfg", ["SignInTeams.tla", "SignInTeamsTrace.tla"], tlaDir);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], rule: string, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), rule, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function pool<T>(count: number, jobs: number, work: (index: number) => Promise<T>): Promise<T[]> {
  const results: T[] = new Array(count);
  let next = 0;
  await Promise.all(Array.from({ length: Math.max(1, jobs) }, async () => {
    while (next < count) {
      const index = next++;
      results[index] = await work(index);
    }
  }));
  return results;
}

function stressBody(count: number): () => Response {
  const teams = Array.from({ length: count }, (_, index) => entryJson("ctl_name", index));
  const body = JSON.stringify({ teams });
  return () => new Response(body, { headers: { "content-type": "application/json" } });
}

async function main(): Promise<number> {
  const helpers = await targetHelpers();
  const out = outDir("auth");
  const scratch = join(out, "runs");
  mkdirSync(scratch, { recursive: true });
  const started = performance.now();

  const cliCases = responses(options.depth).flatMap((resp, index) =>
    (["none", "teamed"] as Prior[]).map((prior) => ({ resp, prior, variant: index })));
  const cli = await pool(cliCases.length, options.jobs, (index) => {
    const { resp, prior, variant } = cliCases[index]!;
    return runCli(helpers, `cli${index}`, prior, resp, variant, scratch);
  });

  const appCases: Resp[] = options.app
    ? [
      ...responses(1),
      { status: "ok", entries: ["ctl_name", "plain"] },
      { status: "ok", entries: ["unreadable", "plain"] },
      { status: "ok", entries: ["plain", "ctl_slug"] },
    ]
    : [];
  const app = await pool(appCases.length, options.appJobs, (index) =>
    runApp(helpers, `app${index}`, appCases[index]!, index, scratch));

  const stress: Observation[] = [];
  if (options.stress > 0) {
    const within = stressBody(options.stress);
    stress.push(await runCli(helpers, "stress", "teamed", { status: "ok", entries: ["ctl_name", "ctl_name"] }, 0, scratch, within));
    const perEntry = JSON.stringify(entryJson("ctl_name", 99_999)).length + 1;
    const past = stressBody(Math.ceil(TEAMS_RESPONSE_MAX_BYTES / perEntry) + 1_000);
    stress.push(await runCli(helpers, "stress-past-limit", "teamed", { status: "error", entries: [] }, 0, scratch, past));
  }

  const observations = [...cli, ...app];
  const all = [...observations, ...stress];
  writeJson(join(out, "observations.json"), all);
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  const counts: Record<string, number> = {};
  for (const o of all) counts[`${o.surface}:${o.outcome}`] = (counts[`${o.surface}:${o.outcome}`] ?? 0) + 1;
  console.log(`${cli.length} fx login and ${app.length} in-app sign-ins of ${binary} in ${seconds}s, outcomes ${JSON.stringify(counts)}`);
  console.log(`observations: ${join(out, "observations.json")}`);

  // A run that never asked for the team list says nothing about it.
  const unreached = all.find((o) => o.evidence.requests.join("\n") !== SIGN_IN_REQUESTS.join("\n"));
  if (unreached) {
    console.log(`TOOL_ERROR: ${unreached.id} made other issuer requests than a sign-in: ${JSON.stringify(unreached.evidence)}`);
    return 2;
  }
  const unknown = all.find((o) => o.outcome === "unknown" || o.saved === "unknown");
  if (unknown) {
    console.log(`REJECTED: ${unknown.id} ended in a way the driver cannot read: ${JSON.stringify(unknown)}`);
    return 1;
  }

  for (const o of stress) {
    console.log(`stress ${o.id}: outcome ${o.outcome}, saved ${o.saved}, offered ${o.offered}, raw controls ${o.rawOut}, ` +
      `${o.evidence.seconds}s, peak RSS ${o.evidence.max_rss_bytes} bytes`);
  }
  if (options.stress > 0) {
    const [within, past] = stress;
    const expected = options.rule === "today"
      ? within!.outcome === "signed_in"
      : within!.outcome === "signed_in" && within!.offered === options.stress && !within!.rawOut &&
        within!.saved === "new_teamed" && past!.outcome === "teams_unavailable" && past!.saved === "teamed";
    if (!expected) {
      console.log("REJECTED: the stress runs did not sign in with every team, or the list past the limit changed the saved sign-in");
      return 1;
    }
  }

  const design = await runTrace(observations, options.rule, out);
  console.log(`${options.rule}: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, options.rule, out);
    console.log(`first run the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await runTrace(observations, "today", out);
    console.log(`self-check, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
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
