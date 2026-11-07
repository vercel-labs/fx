// Drives the fx login's refresh lock across fx profiles
// (src/core/auth/oauth_session.zig lockMutation) in real processes and has TLC
// check every run against tests/tla/oauth_session/KeychainLockTrace.tla, the
// rules of KeychainLock.tla.
//
// On macOS the fx login is one Keychain item for the user, and no test may
// touch the Keychain. So the driver copies src/ into a scratch folder, puts
// fake_keychain.zig in place of src/core/hosts/native_keychain.zig, and builds
// lab.zig there: the real oauth_session.zig takes the lock and loads the
// login, and the real credentials.refreshFxSession refreshes it, in as many
// processes as a scenario starts, each with its own FX_HOME and one shared
// HOME. A local issuer rotates refresh tokens and refuses a used one with
// invalid_grant. The Keychain scenarios need macOS, where fx uses the
// Keychain; elsewhere they are skipped.
//
// The profile-file path (FX_DISABLE_KEYCHAIN=1) runs on the built
// zig-out/bin/fx with --binary, on every platform.
//
// Every process is started through `env -i` with its whole environment
// written out: FX_SOUND=0, FX_DISABLE_KEYCHAIN=1, a scratch HOME and FX_HOME,
// and local fakes only.
//
// Usage, from the repository root:
//   bun tests/tla/drivers/oauth_session/driver.ts             scenarios and saved fuzz seeds
//   ... --rev <rev>         build the lab from that revision's src/ (origin/main must fail)
//   ... --fuzz N [--seed S] N random schedules from seed S; a failing seed is printed
//   ... --stress            16 processes in 8 profiles refresh one login
//   ... --crash             kill the lock's holder before it sends, after the issuer
//                           rotated its token, and after it saved
//   ... --repeat N          the two-profile race N times
//   ... --mutants           plant bugs in a copy of oauth_session.zig; each must be caught
//   ... --binary            the built fx on the profile-file path in two FX_HOME profiles
//   ... --only a,b          only the named scenarios, from the default and crash sets
// Exit: 0 every check passed, 1 a check failed, 2 a toolchain or build failure.
import { dlopen, FFIType } from "bun:ffi";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT, outDir, runTlc } from "../lib/tlc";

const HERE = join(TLA_ROOT, "drivers", "oauth_session");
const SPEC_DIR = join(TLA_ROOT, "oauth_session");
const out = outDir("oauth_session");
const isMac = process.platform === "darwin";

function fail(code: number, message: string): never {
  console.error(message);
  process.exit(code);
}

// fx's awake clock is CLOCK_UPTIME_RAW on macOS; the lab and the issuer both read it.
const uptime = isMac
  ? dlopen("/usr/lib/libSystem.B.dylib", { clock_gettime_nsec_np: { args: [FFIType.i32], returns: FFIType.u64 } }).symbols
  : null;
function awakeNs(): number {
  if (uptime) return Number(BigInt(uptime.clock_gettime_nsec_np(8)));
  return Number(process.hrtime.bigint());
}

// ---- The lab ----

type Patch = { target: string; planted: string };

/** Builds lab.zig against src/ from the worktree, or from `rev`, with `patch` planted in oauth_session.zig. */
function buildLab(name: string, rev: string | null, patch: Patch | null = null): string {
  const root = mkdtempSync(join(out, `lab-${name}-`));
  if (rev) {
    const archive = Bun.spawnSync(["git", "-C", REPO_ROOT, "archive", rev, "src"], { stdout: "pipe", stderr: "pipe" });
    if (archive.exitCode !== 0) fail(2, `git archive ${rev} failed: ${archive.stderr}`);
    const untar = Bun.spawnSync(["tar", "-x", "-C", root], { stdin: archive.stdout, stderr: "pipe" });
    if (untar.exitCode !== 0) fail(2, `tar failed: ${untar.stderr}`);
  } else {
    cpSync(join(REPO_ROOT, "src"), join(root, "src"), { recursive: true });
  }
  if (patch) {
    const path = join(root, "src", "core", "auth", "oauth_session.zig");
    const source = readFileSync(path, "utf8");
    if (!source.includes(patch.target)) fail(2, `mutant ${name}: its target is gone from oauth_session.zig`);
    writeFileSync(path, source.replace(patch.target, patch.planted));
  }
  cpSync(join(HERE, "fake_keychain.zig"), join(root, "src", "core", "hosts", "native_keychain.zig"));
  cpSync(join(HERE, "lab.zig"), join(root, "lab.zig"));
  const build = Bun.spawnSync(["zig", "build-exe", "-O", "Debug", "-lc", "--name", "lab", "lab.zig"], { cwd: root, stdout: "pipe", stderr: "pipe" });
  if (build.exitCode !== 0) fail(2, `building the ${name} lab failed:\n${new TextDecoder().decode(build.stderr)}`);
  return join(root, "lab");
}

// ---- The local issuer ----

type Ev = { ev: string; p?: string; at: number; token?: string; ok?: boolean; issued?: string; outcome?: string; err?: string; expired?: boolean };

type IssuerOpts = {
  acceptDelay: number;
  refuseDelay: number;
  /** Hold discovery answers until this many arrived, or the wait ran out: lines up a race. */
  barrier?: { count: number; waitMs: number };
  /** Answer the first N refreshes with 503, rotating nothing. */
  fail5xx?: number;
  /** Called on each discovery request and each refresh, before the answer. */
  onDiscovery?: () => Promise<void> | void;
  onRecv?: (rec: Ev) => Promise<void> | void;
};

/** Refresh tokens work once: `chains` maps each chain's first token, and each answer issues `<chain>-r<n>`. */
function startIssuer(opts: IssuerOpts, chains: string[] = ["r0"]) {
  const current = new Map<string, string>(chains.map((t) => [t, t]));
  const counts = new Map<string, number>(chains.map((t) => [t, 0]));
  const log: Ev[] = [];
  let failures = opts.fail5xx ?? 0;
  let arrived = 0;
  let releaseBarrier = () => {};
  const barrier = new Promise<void>((resolve) => { releaseBarrier = resolve; });
  if (opts.barrier) setTimeout(releaseBarrier, opts.barrier.waitMs);
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const issuer = `http://127.0.0.1:${server.port}`;
      if (url.pathname === "/.well-known/openid-configuration") {
        if (opts.barrier) {
          arrived += 1;
          if (arrived >= opts.barrier.count) releaseBarrier();
          await barrier;
        }
        await opts.onDiscovery?.();
        return Response.json({ issuer, device_authorization_endpoint: `${issuer}/oauth/device`, token_endpoint: `${issuer}/oauth/token` });
      }
      if (url.pathname === "/oauth/token") {
        const form = new URLSearchParams(await request.text());
        const token = form.get("refresh_token") ?? "";
        if (failures > 0) {
          failures -= 1;
          log.push({ ev: "unavailable", token, at: awakeNs() });
          return new Response("unavailable", { status: 503 });
        }
        const chain = [...current.keys()].find((c) => token === c || token.startsWith(`${c}-r`)) ?? "";
        const ok = chain !== "" && current.get(chain) === token;
        let issued = "";
        if (ok) {
          const n = counts.get(chain)! + 1;
          counts.set(chain, n);
          issued = `${chain}-r${n}`;
          current.set(chain, issued);
        }
        const rec: Ev = { ev: "recv", token, ok, issued, at: awakeNs() };
        log.push(rec);
        await opts.onRecv?.(rec);
        await Bun.sleep(ok ? opts.acceptDelay : opts.refuseDelay);
        if (!ok) return Response.json({ error: "invalid_grant" }, { status: 400 });
        return Response.json({ access_token: `access-${issued}`, refresh_token: issued, expires_in: 3600, scope: "openid offline_access", token_type: "Bearer" });
      }
      if (url.pathname === "/v2/teams") return Response.json({ teams: [{ id: "team_1", slug: "example-team", name: "Example" }] });
      return new Response("not found", { status: 404 });
    },
  });
  return { url: `http://127.0.0.1:${server.port}`, log, stop: () => server.stop(true) };
}

function sessionJson(issuer: string, refresh: string, expired = true): string {
  return JSON.stringify({
    version: 1, issuer, client_id: "lab-client", access_token: `access-${refresh}`, refresh_token: refresh,
    expires_at_ms: expired ? Date.now() - 60_000 : Date.now() + 3_600_000, scope: "openid offline_access use:ai-gateway", token_type: "Bearer",
    team_id: "team_1", team_slug: "example-team",
  }) + "\n";
}

function savedToken(path: string): string {
  if (!existsSync(path)) return "";
  try { return JSON.parse(readFileSync(path, "utf8")).refresh_token ?? ""; } catch { return "<unreadable>"; }
}

// ---- Scenarios ----

type ProcSpec = {
  label: string;
  /** null runs in the default profile, ~/.fx; a name runs with FX_HOME at profiles/<name>. */
  profile: string | null;
  /** FX_HOME as given; "" names the scenario's own ~/.fx. */
  fxHome?: string;
  force?: boolean;
  holdMs?: number;
  startDelay?: number;
  failStore?: boolean;
  /** Build the process from the older lab (origin/main). */
  older?: boolean;
};

type Scenario = {
  name: string;
  procs: ProcSpec[];
  issuer: IssuerOpts;
  /** The profile-file backend: each profile keeps its own login (FX_TLA_PROFILE_FILE). */
  profileFile?: boolean;
  /** Kill the lock's holder at this point. */
  crash?: "before-send" | "after-rotate" | "after-save";
  /** The login is still saved at the end (false: a dead one was deleted; null: either, as the schedule decides). */
  loginKept: boolean | null;
};

type Proc = { spec: ProcSpec; child: ReturnType<typeof Bun.spawn>; events: Ev[]; exit: Promise<number>; stderr: Promise<string> };

/** Streams a lab's stdout, one JSON event per line, as it comes. */
async function readEvents(stream: ReadableStream<Uint8Array>, into: Ev[], onEvent: (e: Ev) => void) {
  const decoder = new TextDecoder();
  let pending = "";
  for await (const chunk of stream) {
    pending += decoder.decode(chunk, { stream: true });
    let nl: number;
    while ((nl = pending.indexOf("\n")) >= 0) {
      const line = pending.slice(0, nl);
      pending = pending.slice(nl + 1);
      if (!line.trim()) continue;
      const e = JSON.parse(line) as Ev;
      into.push(e);
      onEvent(e);
    }
  }
}

/** `env -i` with every variable written out, then the program. */
function envArgv(env: Record<string, string>, argv: string[]): string[] {
  return ["/usr/bin/env", "-i", ...Object.entries(env).map(([k, v]) => `${k}=${v}`), ...argv];
}

type Labs = { current: string; older: string | null };

async function runScenario(labs: Labs, sc: Scenario): Promise<{ ok: boolean; why: string[]; dir: string }> {
  const dir = mkdtempSync(join(out, `${sc.name}-`));
  const home = join(dir, "home");
  mkdirSync(home, { recursive: true, mode: 0o700 });
  const keychain = join(dir, "keychain-item");
  const procs: Proc[] = [];
  const crashes: Ev[] = [];
  const holder = () => procs.find((p) => p.events.some((e) => e.ev === "take") && !p.events.some((e) => e.ev === "release"));
  const kill = (p: Proc | undefined) => {
    if (!p || p.child.exitCode !== null) return;
    crashes.push({ ev: "crash", p: p.spec.label, at: awakeNs() });
    p.child.kill("SIGKILL");
  };
  let crashed = false;
  const opts: IssuerOpts = { ...sc.issuer };
  if (sc.crash === "before-send") opts.onDiscovery = () => { if (!crashed) { crashed = true; kill(holder()); } };
  if (sc.crash === "after-rotate") opts.onRecv = (r) => { if (!crashed && r.ok) { crashed = true; kill(holder()); } };

  const profileDir = (name: string) => join(dir, "profiles", name);
  const chains = sc.profileFile ? [...new Set(sc.procs.map((s) => s.profile ?? "default"))].map((n) => `${n}-r0`) : ["r0"];
  const issuer = startIssuer(opts, chains);
  try {
    if (sc.profileFile) {
      for (const spec of sc.procs) {
        const folder = spec.profile ? profileDir(spec.profile) : join(home, ".fx");
        mkdirSync(folder, { recursive: true, mode: 0o700 });
        const auth = join(folder, "auth.json");
        if (!existsSync(auth)) writeFileSync(auth, sessionJson(issuer.url, `${spec.profile ?? "default"}-r0`), { mode: 0o600 });
      }
    } else {
      writeFileSync(keychain, sessionJson(issuer.url, "r0"), { mode: 0o600 });
    }
    for (const spec of sc.procs) {
      if (spec.startDelay) await Bun.sleep(spec.startDelay);
      const env: Record<string, string> = {
        PATH: "/usr/bin:/bin",
        HOME: home,
        FX_SOUND: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_TEST_OAUTH_ISSUER_URL: issuer.url,
        FX_TLA_KEYCHAIN_FILE: keychain,
        FX_TLA_LABEL: spec.label,
        FX_TRACE_LOG: join(dir, `${spec.label}.trace`),
        FX_TRACE_SCOPES: "auth",
      };
      const fxHome = spec.fxHome === "" ? join(home, ".fx") : spec.fxHome ?? (spec.profile ? profileDir(spec.profile) : null);
      if (fxHome) { mkdirSync(fxHome, { recursive: true, mode: 0o700 }); env.FX_HOME = fxHome; }
      if (spec.force) env.FX_TLA_FORCE = "1";
      if (spec.failStore) env.FX_TLA_KEYCHAIN_FAIL_STORE = "1";
      if (sc.profileFile) env.FX_TLA_PROFILE_FILE = "1";
      if (spec.holdMs ?? (sc.crash === "after-save" ? 2_000 : 0)) env.FX_TLA_HOLD_MS = String(spec.holdMs ?? 2_000);
      const bin = spec.older ? labs.older! : labs.current;
      const child = Bun.spawn(envArgv(env, [bin]), { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
      const proc: Proc = { spec, child, events: [], exit: child.exited, stderr: new Response(child.stderr).text() };
      procs.push(proc);
      void readEvents(child.stdout, proc.events, (e) => {
        if (sc.crash === "after-save" && !crashed && e.ev === "reply" && e.outcome === "ok") { crashed = true; kill(proc); }
      });
    }
    const timeout = setTimeout(() => procs.forEach((p) => p.child.kill("SIGKILL")), 60_000);
    const codes = await Promise.all(procs.map((p) => p.exit));
    clearTimeout(timeout);
    await Bun.sleep(20); // the last stdout chunks

    const why: string[] = [];
    const lines: string[] = [];
    for (const [i, p] of procs.entries()) {
      const killed = crashes.some((c) => c.p === p.spec.label);
      const errors = p.events.filter((e) => e.ev === "error");
      if (!killed && (codes[i] !== 0 || errors.length > 0)) why.push(`${p.spec.label} exited ${codes[i]} ${errors.map((e) => e.err).join(",")} ${(await p.stderr).trim()}`);
      lines.push(...p.events.map((e) => JSON.stringify(e)));
    }
    writeFileSync(join(dir, "events.jsonl"), lines.join("\n") + "\n");
    writeFileSync(join(dir, "issuer.json"), JSON.stringify(issuer.log, null, 2));

    if (sc.profileFile) {
      // Each profile keeps its own login and lock, and ~/.fx is left alone.
      if (existsSync(join(home, ".fx"))) why.push("the profile-file backend made ~/.fx");
      for (const spec of sc.procs) {
        const folder = spec.profile ? profileDir(spec.profile) : join(home, ".fx");
        if (!existsSync(join(folder, "auth.lock"))) why.push(`no auth.lock in ${spec.profile ?? "~/.fx"}`);
      }
      for (const name of new Set(sc.procs.map((s) => s.profile))) {
        const mine = procs.filter((p) => p.spec.profile === name);
        const chain = `${name ?? "default"}-r0`;
        const events = mergeEvents(mine.flatMap((p) => p.events), crashes, issuer.log.filter((r) => r.token === chain || r.token?.startsWith(`${chain}-r`)));
        const auth = join(name ? profileDir(name) : join(home, ".fx"), "auth.json");
        const verdict = await checkTrace(join(dir, `tlc-${name ?? "default"}`), chain, events, savedToken(auth));
        if (!verdict.accepted) why.push(`profile ${name}: ${verdict.detail}`);
      }
    } else {
      const events = mergeEvents(procs.flatMap((p) => p.events), crashes, issuer.log);
      const verdict = await checkTrace(join(dir, "tlc"), "r0", events, savedToken(keychain));
      if (!verdict.accepted) why.push(verdict.detail);
      const refused = issuer.log.filter((r) => r.ev === "recv" && !r.ok).length;
      if (!sc.crash && refused > 0) why.push(`the issuer refused ${refused} used refresh token(s)`);
      if (sc.crash && crashes.length === 0) why.push("no process was killed");
      if (sc.loginKept === true && savedToken(keychain) === "") why.push("the shared login was deleted");
      if (sc.loginKept === false && savedToken(keychain) !== "") why.push("the dead login was kept");
    }
    return { ok: why.length === 0, why, dir };
  } finally {
    issuer.stop();
  }
}

/** Every step of a run, on the awake clock; at one instant a lock is let go before it is taken. */
function mergeEvents(labEvents: Ev[], crashes: Ev[], issuerLog: Ev[]): Ev[] {
  const rank = (e: Ev) => (e.ev === "release" || e.ev === "crash" ? 0 : e.ev === "take" ? 2 : 1);
  return [...labEvents, ...crashes, ...issuerLog.filter((r) => r.ev === "recv")].sort((a, b) => a.at - b.at || rank(a) - rank(b));
}

// ---- TLC ----

function tlaString(s: string | undefined): string {
  return JSON.stringify(s ?? "");
}

/** `finalToken` is the saved login after the run, or null when the run's steps don't show the saves. */
async function checkTrace(dir: string, initToken: string, events: Ev[], finalToken: string | null): Promise<{ accepted: boolean; detail: string }> {
  mkdirSync(dir, { recursive: true });
  const records = [{ ev: "init", token: initToken } as Ev, ...events];
  if (finalToken !== null) records.push({ ev: "final", token: finalToken } as Ev);
  const body = records.map((r) =>
    `    [ev |-> ${tlaString(r.ev)}, p |-> ${tlaString(r.p)}, token |-> ${tlaString(r.token)}, ok |-> ${r.ok ? "TRUE" : "FALSE"}, ` +
    `issued |-> ${tlaString(r.issued)}, outcome |-> ${tlaString(r.outcome)}]`).join(",\n");
  writeFileSync(join(dir, "KeychainLockObs.tla"), `---- MODULE KeychainLockObs ----\nEXTENDS Sequences\nObserved == <<\n${body}\n>>\n====\n`);
  writeFileSync(join(dir, "trace.cfg"), "INIT TraceInit\nNEXT TraceNext\nINVARIANT NotDone\n");
  const run = await runTlc(dir, "KeychainLockTrace", "trace.cfg", ["KeychainLockTrace.tla"], SPEC_DIR, ["-deadlock"]);
  if (run.exitCode === 0) return { accepted: false, detail: `the run left the model (see ${dir}/tlc.log)` };
  if (run.violated !== "NotDone") return { accepted: false, detail: `TLC exited ${run.exitCode} (see ${dir}/tlc.log)` };
  const states = run.output.split(/^State \d+:/m);
  const last = states[states.length - 1] ?? "";
  const broken = [...(/\/\\ bad = \{([^}]*)\}/.exec(last)?.[1] ?? "").matchAll(/"(\w+)"/g)].map((m) => m[1]!);
  if (broken.length > 0) return { accepted: false, detail: `TLC: the run breaks ${broken.join(", ")} (see ${dir}/tlc.log)` };
  return { accepted: true, detail: "" };
}

// ---- Scenario sets ----

const race: IssuerOpts = { acceptDelay: 300, refuseDelay: 1_200, barrier: { count: 2, waitMs: 1_500 } };

function scenarios(withOlder: boolean): Scenario[] {
  const list: Scenario[] = [
    { name: "two-profiles", issuer: race, loginKept: true, procs: [{ label: "a", profile: "pa" }, { label: "b", profile: "pb" }] },
    { name: "default-and-moved", issuer: race, loginKept: true, procs: [{ label: "a", profile: null }, { label: "b", profile: "pb" }] },
    { name: "same-profile", issuer: race, loginKept: true, procs: [{ label: "a", profile: "pa" }, { label: "b", profile: "pa" }] },
    {
      name: "forced-after", issuer: { acceptDelay: 50, refuseDelay: 50 }, loginKept: true,
      procs: [{ label: "a", profile: "pa" }, { label: "b", profile: "pb", force: true, startDelay: 1_500 }],
    },
    { name: "fx-home-is-dot-fx", issuer: race, loginKept: true, procs: [{ label: "a", profile: null, fxHome: "" }, { label: "b", profile: null }] },
    { name: "profile-file", issuer: race, profileFile: true, loginKept: true, procs: [{ label: "a", profile: "pa" }, { label: "b", profile: "pb" }] },
    {
      name: "slow-issuer-503", issuer: { acceptDelay: 2_500, refuseDelay: 100, fail5xx: 1 }, loginKept: true,
      procs: [{ label: "a", profile: "pa" }, { label: "b", profile: "pb", startDelay: 200 }, { label: "c", profile: null, startDelay: 400 }],
    },
    {
      name: "keychain-write-fails", issuer: { acceptDelay: 100, refuseDelay: 100 }, loginKept: false,
      procs: [{ label: "a", profile: "pa", failStore: true }, { label: "b", profile: "pb", startDelay: 50 }],
    },
  ];
  if (withOlder) {
    list.push({
      name: "older-fx-in-default", issuer: race, loginKept: true,
      procs: [{ label: "old", profile: null, older: true }, { label: "b", profile: "pb" }],
    });
  }
  return list;
}

function crashScenarios(): Scenario[] {
  const procs: ProcSpec[] = [{ label: "a", profile: "pa" }, { label: "b", profile: "pb", startDelay: 100 }];
  return [
    { name: "crash-before-send", crash: "before-send", issuer: { acceptDelay: 100, refuseDelay: 100 }, loginKept: true, procs },
    { name: "crash-after-rotate", crash: "after-rotate", issuer: { acceptDelay: 500, refuseDelay: 100 }, loginKept: false, procs },
    { name: "crash-after-save", crash: "after-save", issuer: { acceptDelay: 100, refuseDelay: 100 }, loginKept: true, procs },
  ];
}

function stressScenario(): Scenario {
  const procs: ProcSpec[] = [];
  for (let i = 0; i < 16; i++) procs.push({ label: `s${i}`, profile: i % 8 === 0 ? null : `p${i % 8}`, force: true });
  return { name: "stress-16", issuer: { acceptDelay: 20, refuseDelay: 20 }, loginKept: true, procs };
}

/** A small seeded generator (mulberry32), so a failing schedule replays from its seed. */
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function fuzzScenario(seed: number): Scenario {
  const r = rng(seed);
  const int = (lo: number, hi: number) => lo + Math.floor(r() * (hi - lo + 1));
  const profiles = [null, "pa", "pb", "pc"].slice(0, int(2, 4));
  const n = int(2, 5);
  const procs: ProcSpec[] = [];
  const failStoreAt = r() < 0.15 ? int(0, n - 1) : -1;
  for (let i = 0; i < n; i++) {
    procs.push({ label: `f${i}`, profile: profiles[int(0, profiles.length - 1)]!, startDelay: int(0, 120), force: r() < 0.3, failStore: i === failStoreAt });
  }
  const issuer: IssuerOpts = { acceptDelay: int(0, 300), refuseDelay: int(0, 800), fail5xx: r() < 0.2 ? 1 : 0 };
  // A process whose Keychain write fails deletes the login only if it refreshed it.
  return { name: `fuzz-${seed}`, issuer, loginKept: failStoreAt < 0 ? true : null, procs };
}

// ---- The built binary on the profile-file path ----

async function binaryCheck(): Promise<string[]> {
  const bin = process.env.FX_BIN ?? join(REPO_ROOT, "zig-out", "bin", "fx");
  if (!existsSync(bin)) fail(2, `missing ${bin}; run zig build first or set FX_BIN`);
  const helpers = await import(join(REPO_ROOT, "tests", "e2e", "tmux-helpers.ts"));
  const dir = mkdtempSync(join(out, "binary-"));
  const home = join(dir, "home");
  mkdirSync(home, { recursive: true, mode: 0o700 });
  const names = ["pa", "pb"];
  const issuer = startIssuer({ acceptDelay: 300, refuseDelay: 300 }, names.map((n) => `${n}-r0`));
  const gateway = helpers.startFakeGateway(names.flatMap(() => [helpers.fakeGatewayFinalText("BINARY_DONE"), helpers.fakeGatewayFinalText("BINARY_DONE")]));
  const why: string[] = [];
  try {
    for (const n of names) {
      mkdirSync(join(dir, n), { recursive: true, mode: 0o700 });
      writeFileSync(join(dir, n, "auth.json"), sessionJson(issuer.url, `${n}-r0`), { mode: 0o600 });
    }
    // Two fx in each profile at once: each profile refreshes its own login once.
    const runs = names.flatMap((n) => [0, 1].map(async (k) => {
      const env: Record<string, string> = {
        PATH: "/usr/bin:/bin", HOME: home, FX_HOME: join(dir, n), FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0", FX_TEST_SKIP_ONBOARDING: "1", FX_E2E_DISABLE_DOTENV: "1",
        FX_TEST_OAUTH_ISSUER_URL: issuer.url, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: helpers.FAKE_GATEWAY_MODEL, FX_TRACE_LOG: join(dir, `${n}-${k}.trace`), FX_TRACE_SCOPES: "auth",
      };
      const child = Bun.spawn(envArgv(env, [bin, "ask", "--json", "--no-save", `hello from ${n}`]), { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
      const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      return { n, k, code, stdout, stderr, trace: join(dir, `${n}-${k}.trace`) };
    }));
    const results = await Promise.all(runs);
    for (const r of results) if (r.code !== 0) why.push(`fx ask in ${r.n} exited ${r.code}: ${r.stderr.trim().slice(0, 300)}`);
    if (gateway.requests.length !== 4) why.push(`the fake gateway counted ${gateway.requests.length} requests, not 4`);
    if (existsSync(join(home, ".fx"))) why.push("fx made ~/.fx with FX_DISABLE_KEYCHAIN=1");
    for (const n of names) {
      if (!existsSync(join(dir, n, "auth.lock"))) why.push(`no auth.lock in ${n}`);
      const sent = issuer.log.filter((e) => e.ev === "recv" && e.token?.startsWith(n));
      if (sent.length !== 1 || !sent[0]!.ok) why.push(`profile ${n} sent ${sent.length} refreshes: ${JSON.stringify(sent)}`);
      // fx's own lock lines, on the awake clock in milliseconds, with the issuer's steps.
      const events: Ev[] = [];
      for (const r of results.filter((x) => x.n === n)) {
        const text = existsSync(r.trace) ? readFileSync(r.trace, "utf8") : "";
        for (const line of text.split("\n")) {
          const taken = /fx login lock taken stamp=(\d+)/.exec(line);
          if (taken) events.push({ ev: "take", p: `${n}${r.k}`, at: Number(taken[1]) * 1e6 });
          const released = /fx login lock released stamp=\d+ at=(\d+)/.exec(line);
          if (released) events.push({ ev: "release", p: `${n}${r.k}`, at: Number(released[1]) * 1e6 });
        }
      }
      if (!events.some((e) => e.ev === "take")) why.push(`no fx login lock lines in ${n}'s traces`);
      // fx's trace lines show the lock, not each save, so the final login is checked by the issuer's count above.
      const verdict = await checkTrace(join(dir, `tlc-${n}`), `${n}-r0`, mergeEvents(events, [], issuer.log.filter((e) => e.token?.startsWith(n))), null);
      if (!verdict.accepted) why.push(`profile ${n}: ${verdict.detail}`);
    }
    console.log(`binary: ${results.length} fx ask runs, gateway requests ${gateway.requests.length}, issuer ${JSON.stringify(issuer.log.map((e) => [e.token, e.ok]))}`);
  } finally {
    gateway.stop();
    issuer.stop();
  }
  return why;
}

// ---- Mutants ----

// Planted bugs in the fixed oauth_session.zig. Each must make a scenario fail.
const mutants: { name: string; patch: Patch; scenarios: string[] }[] = [
  {
    name: "lock-in-profile",
    patch: { target: "lockMutationWithBackend(open_fx_dir, if (shared) |*dir| dir else null,", planted: "lockMutationWithBackend(open_fx_dir, null," },
    scenarios: ["two-profiles", "default-and-moved"],
  },
  {
    name: "shared-without-fx-home-only",
    patch: { target: "if (backend != .macos_keychain or !fx_home_active) return null;", planted: "if (backend != .macos_keychain or fx_home_active) return null;" },
    scenarios: ["two-profiles", "default-and-moved"],
  },
  {
    name: "profile-file-shares",
    patch: { target: "if (backend != .macos_keychain or !fx_home_active) return null;", planted: "_ = backend;\n    if (!fx_home_active) return null;" },
    scenarios: ["profile-file"],
  },
  {
    name: "shared-folder-not-home",
    patch: { target: "return io_mod.openOrCreateVerifiedPrivateDir(&parent_dir, profile_paths.root_dir_name)", planted: "return io_mod.openOrCreateVerifiedPrivateDir(&parent_dir, \"fx-runtime\")" },
    scenarios: ["older-fx-in-default"],
  },
];

// ---- Main ----

async function main() {
  const args = process.argv.slice(2);
  const value = (flag: string) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };
  const has = (flag: string) => args.includes(flag);
  const rev = value("--rev") ?? null;
  console.log(`output: ${out}`);

  if (has("--binary")) {
    const why = await binaryCheck();
    for (const w of why) console.log(`FAIL  binary: ${w}`);
    if (why.length === 0) console.log("ok    binary: each profile refreshed its own login under its own auth.lock; no ~/.fx");
    process.exit(why.length === 0 ? 0 : 1);
  }
  if (!isMac) {
    console.log("skip  the Keychain scenarios: fx uses the Keychain only on macOS (run --binary here)");
    process.exit(0);
  }

  const started = performance.now();
  const current = buildLab(rev ? `rev-${rev.replace(/\W/g, "_")}` : "worktree", rev);
  const older = rev ? null : buildLab("origin-main", "origin/main");
  const labs: Labs = { current, older };
  console.log(`built the lab in ${Math.round(performance.now() - started)} ms`);

  let list: Scenario[];
  if (has("--only")) {
    const names = (value("--only") ?? "").split(",");
    const all = [...scenarios(!rev), ...crashScenarios()];
    list = names.map((name) => all.find((s) => s.name === name) ?? fail(2, `no scenario named ${name}`));
  } else if (has("--fuzz")) {
    const n = Number(value("--fuzz") ?? "10");
    const seed = Number(value("--seed") ?? String(Date.now() % 100_000));
    console.log(`fuzz: ${n} schedules from seed ${seed}`);
    list = Array.from({ length: n }, (_, i) => fuzzScenario(seed + i));
  } else if (has("--stress")) {
    list = [stressScenario()];
  } else if (has("--crash")) {
    list = crashScenarios();
  } else if (has("--repeat")) {
    const n = Number(value("--repeat") ?? "10");
    list = Array.from({ length: n }, (_, i) => ({ ...scenarios(false)[i % 2]!, name: `race-${i}`, procs: scenarios(false)[i % 2]!.procs.map((p, k) => ({ ...p, startDelay: k * ((i * 7) % 40) })) }));
  } else if (has("--mutants")) {
    const base = scenarios(true);
    let missed = 0;
    for (const m of mutants) {
      const lab = buildLab(`mutant-${m.name}`, null, m.patch);
      const results = [];
      for (const name of m.scenarios) results.push(await runScenario({ current: lab, older: labs.older }, base.find((s) => s.name === name)!));
      const caught = results.some((r) => !r.ok);
      if (!caught) missed += 1;
      console.log(`${caught ? "ok   " : "FAIL "} mutant ${m.name}: ${caught ? `caught (${results.flatMap((r) => r.why).slice(0, 2).join("; ")})` : "not caught"}`);
    }
    process.exit(missed === 0 ? 0 : 1);
  } else {
    const saved = JSON.parse(readFileSync(join(HERE, "seeds.json"), "utf8")) as number[];
    list = [...scenarios(!rev), ...saved.map(fuzzScenario)];
  }

  let failed = 0;
  for (const sc of list) {
    const t0 = performance.now();
    const result = await runScenario(labs, sc);
    const ms = Math.round(performance.now() - t0);
    if (result.ok) console.log(`ok    ${sc.name} (${ms} ms)`);
    else { failed += 1; console.log(`FAIL  ${sc.name} (${ms} ms): ${result.why.join("; ")} [${result.dir}]`); }
  }
  console.log(`${list.length - failed}/${list.length} passed`);
  process.exit(failed === 0 ? 0 : 1);
}

await main();
