// Replays LeanUsageDrive behaviors from TLC against the real fx binary.
//
//   bun tests/tla/drivers/usage/lean/drive.ts [--traces N] [--depth D] [--seed S] [file...]
//
// TLC simulates N random behaviors of tests/tla/usage/LeanUsageDrive.tla (or the given
// trace files are replayed). Each behavior runs two fx TUIs (p1, p2) in tmux
// that share one HOME, so one ~/.fx/usage-cache. Identity a and b are two
// AI Gateway API keys; each process has its own fake gateway that holds every
// /v1/report request until the behavior says the fetch completes or fails.
// The usage clock seam (FX_TEST_USAGE_CLOCK_FILE) maps model time to real time:
// tick n is 23:40 UTC + 5n minutes, so the 60 s floor is one tick, the
// 15-minute timer three, and UTC midnight falls between ticks 3 and 4.
//
// After every step the driver checks the real system against the next model
// state: which processes started a fetch and whether it read the finished
// days, what each identity's cache file holds, and what "today" each open
// dashboard shows. The first difference ends that behavior.

import { createHash } from "node:crypto";
import {
  copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync,
  realpathSync, rmSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { REPO_ROOT, TLA_ROOT, outDir as newOutDir, tlcToolchain } from "../../lib/tlc";
import { parseBehavior, type State, type Value } from "./tla.ts";

const WORKTREE = process.env.FX_WORKTREE ?? REPO_ROOT;
const { startFakeGateway, TmuxSession } = await import(join(WORKTREE, "tests/e2e/tmux-helpers.ts"));
const { usageEnv, utcDate, writeUsageClock } = await import(join(WORKTREE, "tests/e2e/usage-fakes.ts"));

const SPECS = join(TLA_ROOT, "usage");
const PROCS = ["p1", "p2"] as const;
type Proc = (typeof PROCS)[number];
const MIN = 60_000;
const DAY_MS = 24 * 60 * MIN;
/** UTC midnight between ticks 3 and 4: Wed Oct 21 2026. */
const MIDNIGHT = Date.UTC(2026, 9, 21);
const tickMs = (n: number) => MIDNIGHT - 20 * MIN + n * 5 * MIN;
const utcDay = (ms: number) => Math.floor(ms / DAY_MS);
const DAY0 = utcDay(tickMs(0));
const KEYS: Record<string, string> = { a: "drive-key-a", b: "drive-key-b" };
/** Today's spend for identity i fetched at tick k is BASE[i] + k dollars. */
const BASE: Record<string, number> = { a: 10, b: 20 };
const SETTLE_MS = 300;
const TIMEOUT_MS = 8_000;

type Fetch = { ident: string; at: number; fin: boolean };
type Held = { url: URL; answer: (response: Response) => void };
type Action =
  | { kind: "Tick" }
  | { kind: "Open" | "Close" | "Manual" | "Timer" | "Complete" | "Fail"; p: Proc };

class Divergence extends Error {
  constructor(message: string, readonly detail: Record<string, unknown> = {}) {
    super(message);
  }
}

const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));
async function until<T>(probe: () => T | undefined | false | Promise<T | undefined | false>, ms = TIMEOUT_MS): Promise<T | undefined> {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await probe();
    if (value) return value as T;
    if (Date.now() > deadline) return undefined;
    await sleep(25);
  }
}

// ---------------------------------------------------------------------------
// The model side

const rec = (v: Value) => v as Record<string, Value>;
const fetchOf = (s: State, p: Proc): Fetch | null => {
  const f = rec(s.inflight)[p];
  return f === null ? null : (f as unknown as Fetch);
};
const since = (t: Value, n: number, now: number) => t === null || now - (t as number) >= n;

function timerDue(s: State, p: Proc): boolean {
  const now = s.now as number;
  const lastStart = rec(s.lastStart)[p];
  return rec(s.open)[p] === true && fetchOf(s, p) === null &&
    since(lastStart, 1, now) && since(rec(s.failedAt)[p], 1, now) &&
    lastStart !== null && since(lastStart, 3, now);
}

/** The action that takes `s` to `t` (LeanUsageDrive's actions leave distinct marks). */
function actionBetween(s: State, t: State): Action {
  if (t.now !== s.now) return { kind: "Tick" };
  for (const p of PROCS) {
    const wasOpen = rec(s.open)[p] === true;
    const isOpen = rec(t.open)[p] === true;
    if (!wasOpen && isOpen) return { kind: "Open", p };
    if (wasOpen && !isOpen) return { kind: "Close", p };
    const before = fetchOf(s, p);
    const after = fetchOf(t, p);
    if (before === null && after !== null) return { kind: timerDue(s, p) ? "Timer" : "Manual", p };
    if (before !== null && after === null) {
      return { kind: rec(t.failedAt)[p] === t.now ? "Fail" : "Complete", p };
    }
  }
  throw new Error("no LeanUsageDrive action explains this step");
}

// ---------------------------------------------------------------------------
// The real side

function cachePath(home: string, ident: string): string {
  const hash = createHash("sha256").update(`fx-usage-cache-v1\0api_key\0${KEYS[ident]}\0`).digest("hex");
  return join(home, ".fx", "usage-cache", `${hash}.json`);
}

type CacheRec = { todayDay: number | null; todayAt: number | null; finDay: number | null };

function readCache(home: string, ident: string): CacheRec {
  const path = cachePath(home, ident);
  if (!existsSync(path)) return { todayDay: null, todayAt: null, finDay: null };
  const wire = JSON.parse(readFileSync(path, "utf8"));
  const tick = (ms: number) => (ms - tickMs(0)) / (5 * MIN);
  return {
    todayDay: wire.today ? wire.today.day - DAY0 : null,
    todayAt: wire.today ? tick(wire.today.at_ms) : null,
    finDay: wire.finished ? wire.finished.day - DAY0 : null,
  };
}

/** The "today" spend on an open dashboard, decoded to identity and tick, or null. */
function shownToday(pane: string): { ident: string; today: number } | null {
  const match = pane.match(/^\s*(?:❯\s*)?today\s+\$([\d,]+(?:\.\d+)?)\s/m);
  if (!match) return null;
  const dollars = Number(match[1].replace(/,/g, ""));
  for (const [ident, base] of Object.entries(BASE)) {
    const tick = dollars - base;
    if (Number.isInteger(tick) && tick >= 0 && tick < 10) return { ident, today: tick };
  }
  return null;
}

const rows = (cost: number) => ({
  results: [{ model: "drive/usage", request_count: 1, input_tokens: 1, output_tokens: 1, total_cost: cost }],
});

class Process {
  held: Held[] = [];
  fetch: (Fetch & { today: Held }) | null = null;
  session: any = null;
  gateway: any;

  constructor(readonly name: Proc, readonly ident: string) {
    this.gateway = startFakeGateway([], {
      usage: (url: URL) =>
        url.pathname !== "/v1/report"
          ? null
          : new Promise<Response>((answer) => this.held.push({ url, answer })),
    });
  }

  async start(home: string, clock: string): Promise<void> {
    this.session = await TmuxSession.create({
      width: 120,
      height: 40,
      env: {
        ...usageEnv(this.gateway.baseUrl, clock),
        HOME: home,
        AI_GATEWAY_API_KEY: KEYS[this.ident],
        VERCEL_OIDC_TOKEN: undefined,
        FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        FX_DEBUG_RECORD: undefined,
        FX_DEBUG_RECORD_SILENT_BANNER: undefined,
      },
    });
    await this.session.waitForComposer(TIMEOUT_MS * 2);
  }

  async stop(): Promise<void> {
    for (const h of this.held) h.answer(new Response("driver stopped", { status: 503 }));
    await this.session?.kill();
    this.gateway.stop();
  }

  /** Claims the first request of a fetch the model started. */
  async claimStart(f: Fetch): Promise<void> {
    const got = await until(() => this.held.length > 0);
    if (!got) throw new Divergence(`${this.name}: the model starts a fetch, fx sent no request`, { fetch: f });
    const today = this.held.shift()!;
    const day = utcDate(tickMs(f.at));
    const range = `${today.url.searchParams.get("start_date")}..${today.url.searchParams.get("end_date")}`;
    if (range !== `${day}..${day}`) {
      throw new Divergence(`${this.name}: first request reads ${range}, model expects today ${day}`, { fetch: f });
    }
    this.fetch = { ...f, today };
  }

  async answerNext(label: string, start: string, end: string, cost: number): Promise<void> {
    const got = await until(() => this.held.length > 0);
    if (!got) throw new Divergence(`${this.name}: fetch reads finished days in the model, fx sent no ${label} request`);
    const h = this.held.shift()!;
    const range = `${h.url.searchParams.get("start_date")}..${h.url.searchParams.get("end_date")}`;
    if (range !== `${start}..${end}`) {
      throw new Divergence(`${this.name}: ${label} request reads ${range}, model expects ${start}..${end}`);
    }
    h.answer(Response.json(rows(cost)));
  }
}

// ---------------------------------------------------------------------------
// One behavior

async function replay(states: State[]): Promise<{ steps: number }> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-usage-drive-")));
  const home = join(root, "home");
  mkdirSync(home);
  const clock = join(root, "clock");
  writeUsageClock(clock, tickMs(0));
  const ident = rec(states[0].ident);
  const procs = Object.fromEntries(PROCS.map((p) => [p, new Process(p, ident[p] as string)])) as Record<Proc, Process>;
  let step = 0;
  try {
    await Promise.all(PROCS.map((p) => procs[p].start(home, clock)));
    for (step = 1; step < states.length; step += 1) {
      const s = states[step - 1];
      const t = states[step];
      const action = actionBetween(s, t);
      try {
        await perform(action, s, t, procs, clock, home);
        await settleAndCheck(t, procs, home);
      } catch (err) {
        if (err instanceof Divergence) {
          err.detail.step = step;
          err.detail.action = action;
          err.detail.model = { now: t.now, open: t.open, shown: t.shown, cache: t.cache, inflight: t.inflight };
          err.detail.real = Object.fromEntries(Object.keys(KEYS).map((i) => [i, readCache(home, i)]));
          err.detail.panes = Object.fromEntries(
            await Promise.all(PROCS.map(async (p) => [p, await procs[p].session.capturePane()])),
          );
        }
        throw err;
      }
    }
    return { steps: states.length - 1 };
  } finally {
    await Promise.all(PROCS.map((p) => procs[p].stop()));
    rmSync(root, { recursive: true, force: true });
  }
}

async function perform(action: Action, s: State, t: State, procs: Record<Proc, Process>, clock: string, home: string): Promise<void> {
  if (action.kind === "Tick") {
    writeUsageClock(clock, tickMs(t.now as number));
    return;
  }
  const proc = procs[action.p];
  const session = proc.session;
  switch (action.kind) {
    case "Open": {
      await session.sendText("/usage");
      const shown = await until(async () => (await session.capturePane()).includes("usage: API key"));
      if (!shown) throw new Divergence(`${action.p}: /usage did not open`);
      // Reopening while a fetch is in flight starts nothing new.
      const f = fetchOf(s, action.p) === null ? fetchOf(t, action.p) : null;
      if (f) await proc.claimStart(f);
      return;
    }
    case "Close": {
      await session.sendKeys("Escape");
      const closed = await until(async () => !(await session.capturePane()).includes("usage: API key"));
      if (!closed) throw new Divergence(`${action.p}: /usage did not close`);
      return;
    }
    case "Manual":
      await session.sendKeys("r");
      await proc.claimStart(fetchOf(t, action.p)!);
      return;
    case "Timer":
      // fx starts it on its own once the clock moved; the request may already be held.
      await proc.claimStart(fetchOf(t, action.p)!);
      return;
    case "Complete": {
      const f = proc.fetch;
      if (!f) throw new Error("Complete without a claimed fetch");
      proc.fetch = null;
      f.today.answer(Response.json(rows(BASE[f.ident] + f.at)));
      if (f.fin) {
        const ms = tickMs(f.at);
        const today = new Date(ms);
        await proc.answerNext("7d", utcDate(ms - 6 * DAY_MS), utcDate(ms - DAY_MS), 1000);
        const first = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1);
        if (utcDay(first) !== utcDay(ms)) await proc.answerNext("month", utcDate(first), utcDate(ms - DAY_MS), 2000);
      }
      // The worker merges into the cache file and then frees the process for
      // its next fetch; wait for the merge the model predicts.
      const want = rec(rec(t.cache)[f.ident]) as unknown as CacheRec;
      await until(() => sameCache(readCache(home, f.ident), want));
      return;
    }
    case "Fail": {
      const f = proc.fetch;
      if (!f) throw new Error("Fail without a claimed fetch");
      proc.fetch = null;
      f.today.answer(new Response("drive: failed on purpose", { status: 500 }));
      return;
    }
  }
}

const sameCache = (real: CacheRec, want: CacheRec) =>
  real.todayDay === want.todayDay && real.todayAt === want.todayAt && real.finDay === want.finDay;

async function settleAndCheck(t: State, procs: Record<Proc, Process>, home: string): Promise<void> {
  await sleep(SETTLE_MS);
  // No fetch the model does not start. fx fires every due timer at once,
  // while the model takes them one step at a time: a process whose timer is
  // due may already have sent its first request.
  for (const p of PROCS) {
    const allowed = timerDue(t, p) ? 1 : 0;
    if (procs[p].held.length > allowed) {
      const ranges = procs[p].held.map((h) => `${h.url.searchParams.get("start_date")}..${h.url.searchParams.get("end_date")}`);
      throw new Divergence(`${p}: fx sent a request the model does not make`, { ranges });
    }
  }
  // The shared cache file, per identity.
  for (const ident of Object.keys(KEYS)) {
    const want = rec(rec(t.cache)[ident]) as unknown as CacheRec;
    const real = readCache(home, ident);
    if (!sameCache(real, want)) {
      throw new Divergence(`cache for ${ident} differs from the model`, { want, real });
    }
  }
  // What each open dashboard shows as today (ShowsOwnIdentity, TodayIsToday).
  for (const p of PROCS) {
    if (rec(t.open)[p] !== true) continue;
    const shown = rec(rec(t.shown)[p]);
    const want = shown.today === null ? null : { ident: shown.ident as string, today: shown.today as number };
    let last: ReturnType<typeof shownToday> = null;
    const ok = await until(async () => {
      last = shownToday(await procs[p].session.capturePane());
      return JSON.stringify(last) === JSON.stringify(want);
    }, 3_000);
    if (!ok) throw new Divergence(`${p}: dashboard shows today ${JSON.stringify(last)}, model shows ${JSON.stringify(want)}`);
  }
}

// ---------------------------------------------------------------------------
// Main

function args() {
  const out = { traces: 20, depth: 30, seed: Date.now() % 100_000, files: [] as string[] };
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (flag === "--traces") out.traces = Number(argv[++i]);
    else if (flag === "--depth") out.depth = Number(argv[++i]);
    else if (flag === "--seed") out.seed = Number(argv[++i]);
    else out.files.push(resolve(flag));
  }
  return out;
}

function simulate(dir: string, traces: number, depth: number, seed: number): string[] {
  const { java, jar } = tlcToolchain();
  const run = Bun.spawnSync([
    java, "-XX:+UseParallelGC", `-Djava.io.tmpdir=${mkdtempSync(join(tmpdir(), "fx-tlc-"))}`, "-cp", jar, "tlc2.TLC",
    "-metadir", join(dir, ".tlc-states"),
    "-config", join(SPECS, "LeanUsageDrive.cfg"), join(SPECS, "LeanUsageDrive.tla"),
    "-simulate", `file=${join(dir, "t")},num=${traces}`, "-depth", String(depth), "-seed", String(seed),
  ], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) {
    throw new Error(`TLC simulation failed (${run.exitCode}):\n${run.stdout.toString()}\n${run.stderr.toString()}`);
  }
  return readdirSync(dir).filter((name) => name.startsWith("t_")).sort().map((name) => join(dir, name));
}

const opts = args();
const outDir = newOutDir("usage-lean");
mkdirSync(join(outDir, "traces"), { recursive: true });
const files = opts.files.length > 0 ? opts.files : simulate(join(outDir, "traces"), opts.traces, opts.depth, opts.seed);
console.log(`replaying ${files.length} behavior(s)${opts.files.length ? "" : ` (TLC seed ${opts.seed}, depth ${opts.depth})`}`);

const results: Array<Record<string, unknown>> = [];
for (const file of files) {
  const states = parseBehavior(readFileSync(file, "utf8"));
  const actions = states.slice(1).map((t, i) => actionBetween(states[i], t));
  const name = file.split("/").pop()!;
  if (!actions.some((a) => a.kind === "Open")) {
    results.push({ trace: name, status: "skipped", reason: "never opens /usage" });
    continue;
  }
  const summary = actions.map((a) => (a.kind === "Tick" ? "Tick" : `${a.kind}(${a.p})`)).join(" ");
  const started = Date.now();
  try {
    const run = await replay(states);
    results.push({ trace: name, status: "pass", steps: run.steps, ms: Date.now() - started, actions: summary });
    console.log(`pass  ${name}  ${run.steps} steps  ${summary}`);
  } catch (err) {
    const detail = err instanceof Divergence ? err.detail : { stack: String((err as Error).stack) };
    results.push({ trace: name, status: err instanceof Divergence ? "diverged" : "error", message: (err as Error).message, actions: summary, ...detail });
    copyFileSync(file, join(outDir, name));
    console.log(`${err instanceof Divergence ? "DIVERGED" : "ERROR"}  ${name}: ${(err as Error).message}`);
    console.log(`        ${summary}`);
  }
}

writeFileSync(join(outDir, "report.json"), JSON.stringify({ seed: opts.seed, depth: opts.depth, results }, null, 2) + "\n");
const count = (status: string) => results.filter((r) => r.status === status).length;
console.log(`\n${count("pass")} pass, ${count("diverged")} diverged, ${count("error")} error, ${count("skipped")} skipped`);
console.log(`report: ${join(outDir, "report.json")}`);
process.exit(count("diverged") + count("error") > 0 ? 1 : 0);
