// Replays UsageModel DriveSpec behaviors from TLC against the real fx binary.
//
// Two fx TUIs (p1, p2) run in tmux and share one HOME, so one
// ~/.fx/usage-cache. Identities a and b are two AI Gateway API keys. Each
// process has its own fake gateway that holds every /v1/report request until
// the behavior says the fetch completes or fails. The usage clock seam
// (FX_TEST_USAGE_CLOCK_FILE) is the wall clock: wall tick n is 23:40 UTC on
// Oct 20 2026 + 5n minutes, so the 60 s floor is one tick, the 15-minute timer
// three, and UTC midnight falls between ticks 3 and 4.
//
// Non-ideal steps: Fail answers the held request with 500; Crash SIGKILLs the
// fx process and starts a new one in its place; Corrupt writes garbage over an
// identity's cache file; ClockBack moves the wall clock back.
//
// After every step the driver compares the real system with the next model
// state: which processes sent which requests, what each identity's cache file
// holds, and what the today and 7d rows of each open dashboard show. The
// first difference ends the behavior and keeps both sides.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { State, Value } from "./tla-trace.ts";

export const PROCS = ["p1", "p2"] as const;
export type Proc = (typeof PROCS)[number];
const MIN = 60_000;
const DAY_MS = 24 * 60 * MIN;
const MIDNIGHT = Date.UTC(2026, 9, 21);
export const tickMs = (n: number) => MIDNIGHT - 20 * MIN + n * 5 * MIN;
const utcDay = (ms: number) => Math.floor(ms / DAY_MS);
const DAY0 = utcDay(tickMs(0));
const KEYS: Record<string, string> = { a: "drive-key-a", b: "drive-key-b" };
/** Today's spend for identity i fetched at wall tick k is BASE[i] + k dollars. */
const BASE: Record<string, number> = { a: 10, b: 20 };
/** The finished days' 7d spend the driver answers. */
const FIN_7D = 1000;
const SETTLE_MS = 300;
const TIMEOUT_MS = 8_000;

type Fetch = { ident: string; at: number; fin: boolean };
type Held = { url: URL; answer: (response: Response) => void };
export type Action =
  | { kind: "Tick" | "ClockBack" }
  | { kind: "Corrupt"; i: string }
  | { kind: "Open" | "Close" | "Manual" | "Timer" | "Complete" | "Fail" | "Crash"; p: Proc };

export class Divergence extends Error {
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
// Model side

const rec = (v: Value) => v as Record<string, Value>;
const wall = (s: State) => (s.now as number) + (s.skew as number);
const fetchOf = (s: State, p: Proc): Fetch | null => {
  const f = rec(s.inflight)[p];
  return f === null ? null : (f as unknown as Fetch);
};
// policy.since: a clock that reads earlier than t was corrected and counts as passed.
const since = (t: Value, n: number, w: number) => t === null || w < (t as number) || w - (t as number) >= n;

export function timerDue(s: State, p: Proc): boolean {
  const w = wall(s);
  const lastStart = rec(s.lastStart)[p];
  return rec(s.open)[p] === true && fetchOf(s, p) === null &&
    since(lastStart, 1, w) && since(rec(s.failedAt)[p], 1, w) &&
    lastStart !== null && since(lastStart, 3, w);
}

const procKeys = ["open", "inflight", "lastStart", "failedAt", "mem", "shown"];
const procChanged = (s: State, t: State, p: Proc) =>
  procKeys.some((k) => JSON.stringify(rec(s[k])[p]) !== JSON.stringify(rec(t[k])[p]));

/** The action that takes `s` to `t`; each DriveSpec action leaves a distinct mark. */
export function actionBetween(s: State, t: State): Action {
  if (t.skew !== s.skew) return { kind: "ClockBack" };
  for (const i of Object.keys(KEYS)) {
    if (rec(t.corruptions)[i] !== rec(s.corruptions)[i]) return { kind: "Corrupt", i };
  }
  if (t.faults !== s.faults) {
    const changed = PROCS.find((p) => procChanged(s, t, p));
    if (changed) return { kind: "Crash", p: changed };
    // A crash that changes nothing hit a process already in a fresh fx's
    // state (closed, no fetch history, nothing in memory); crash that one.
    const fresh = PROCS.find((p) =>
      rec(s.open)[p] === false && rec(s.inflight)[p] === null && rec(s.lastStart)[p] === null &&
      rec(s.failedAt)[p] === null && JSON.stringify(rec(s.mem)[p]) === JSON.stringify(rec(t.mem)[p]));
    if (!fresh) throw new Error("a crash that changes nothing, with no process in a fresh state");
    return { kind: "Crash", p: fresh };
  }
  if (t.now !== s.now) return { kind: "Tick" };
  for (const p of PROCS) {
    const wasOpen = rec(s.open)[p] === true;
    const isOpen = rec(t.open)[p] === true;
    if (!wasOpen && isOpen) return { kind: "Open", p };
    if (wasOpen && !isOpen) return { kind: "Close", p };
    const before = fetchOf(s, p);
    const after = fetchOf(t, p);
    if (before === null && after !== null) return { kind: timerDue(s, p) ? "Timer" : "Manual", p };
    if (before !== null && after === null) return { kind: rec(t.failedAt)[p] === wall(t) ? "Fail" : "Complete", p };
  }
  throw new Error("no DriveSpec action explains this step");
}

export const describe = (a: Action) =>
  a.kind === "Tick" || a.kind === "ClockBack" ? a.kind : a.kind === "Corrupt" ? `Corrupt(${a.i})` : `${a.kind}(${a.p})`;

// ---------------------------------------------------------------------------
// Real side

function cachePath(home: string, ident: string): string {
  const hash = createHash("sha256").update(`fx-usage-cache-v1\0api_key\0${KEYS[ident]}\0`).digest("hex");
  return join(home, ".fx", "usage-cache", `${hash}.json`);
}

type CacheRec = { todayDay: number | null; todayAt: number | null; finDay: number | null; corrupt: boolean };

function readCache(home: string, ident: string): CacheRec {
  const empty = { todayDay: null, todayAt: null, finDay: null };
  const path = cachePath(home, ident);
  if (!existsSync(path)) return { ...empty, corrupt: false };
  let wire: any;
  try { wire = JSON.parse(readFileSync(path, "utf8")); } catch { return { ...empty, corrupt: true }; }
  const tick = (ms: number) => (ms - tickMs(0)) / (5 * MIN);
  return {
    todayDay: wire.today ? wire.today.day - DAY0 : null,
    todayAt: wire.today ? tick(wire.today.at_ms) : null,
    finDay: wire.finished ? wire.finished.day - DAY0 : null,
    corrupt: false,
  };
}

const modelCache = (t: State, ident: string): CacheRec => ({
  ...(rec(rec(t.cache)[ident]) as unknown as Omit<CacheRec, "corrupt">),
  corrupt: rec(t.corrupt)[ident] === true,
});

const sameCache = (real: CacheRec, want: CacheRec) =>
  real.corrupt === want.corrupt &&
  (want.corrupt || (real.todayDay === want.todayDay && real.todayAt === want.todayAt && real.finDay === want.finDay));

function dollars(pane: string, row: string): number | null {
  const match = pane.match(new RegExp(`^\\s*(?:❯\\s*)?${row}\\s+\\$([\\d,]+(?:\\.\\d+)?)\\s`, "m"));
  return match ? Number(match[1].replace(/,/g, "")) : null;
}

/** What an open dashboard shows: today decoded to identity and tick, and the 7d spend. */
function shownRows(pane: string) {
  const today = dollars(pane, "today");
  let decoded: { ident: string; today: number } | null = null;
  if (today !== null) {
    for (const [ident, base] of Object.entries(BASE)) {
      const tick = today - base;
      if (Number.isInteger(tick) && tick >= 0 && tick < 10) decoded = { ident, today: tick };
    }
  }
  return { today: decoded, days7: dollars(pane, "7d") };
}

const rows = (cost: number) => ({
  results: [{ model: "drive/usage", request_count: 1, input_tokens: 1, output_tokens: 1, total_cost: cost }],
});

export interface Env {
  TmuxSession: any;
  startFakeGateway: any;
  usageEnv: (baseUrl: string, clock: string) => Record<string, string>;
  utcDate: (ms: number) => string;
  writeUsageClock: (path: string, ms: number) => void;
  cwd: string;
}

class Process {
  held: Held[] = [];
  requests: string[] = [];
  fetch: (Fetch & { today: Held }) | null = null;
  session: any = null;
  gateway: any;
  launches = 0;

  constructor(readonly env: Env, readonly name: Proc, readonly ident: string) {
    this.gateway = env.startFakeGateway([], {
      usage: (url: URL) => {
        if (url.pathname !== "/v1/report") return null;
        this.requests.push(`${url.searchParams.get("start_date")}..${url.searchParams.get("end_date")}`);
        return new Promise<Response>((answer) => this.held.push({ url, answer }));
      },
    });
  }

  async start(home: string, clock: string): Promise<void> {
    this.launches += 1;
    this.session = await this.env.TmuxSession.create({
      width: 120,
      height: 40,
      cwd: this.env.cwd,
      env: {
        ...this.env.usageEnv(this.gateway.baseUrl, clock),
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

  dropHeld(): void {
    for (const h of this.held) h.answer(new Response("driver dropped", { status: 503 }));
    this.held = [];
    this.fetch = null;
  }

  /** SIGKILL, then a new fx in its place. Returns the killed pid. */
  async crash(home: string, clock: string): Promise<number> {
    const pid = this.session.processPid();
    process.kill(pid, "SIGKILL");
    const gone = await until(() => { try { process.kill(pid, 0); return false; } catch { return true; } });
    if (!gone) throw new Error(`${this.name}: fx ${pid} survived SIGKILL`);
    await this.session.kill();
    this.dropHeld();
    await this.start(home, clock);
    return pid;
  }

  async stop(): Promise<void> {
    this.dropHeld();
    await this.session?.kill();
    this.gateway.stop();
  }

  async claimStart(f: Fetch): Promise<void> {
    const got = await until(() => this.held.length > 0);
    if (!got) throw new Divergence(`${this.name}: the model starts a fetch, fx sent no request`, { fetch: f });
    const today = this.held.shift()!;
    const day = this.env.utcDate(tickMs(f.at));
    const range = `${today.url.searchParams.get("start_date")}..${today.url.searchParams.get("end_date")}`;
    if (range !== `${day}..${day}`) throw new Divergence(`${this.name}: first request reads ${range}, model expects today ${day}`, { fetch: f });
    this.fetch = { ...f, today };
  }

  async answerNext(label: string, start: string, end: string, cost: number): Promise<void> {
    const got = await until(() => this.held.length > 0);
    if (!got) throw new Divergence(`${this.name}: the model reads finished days, fx sent no ${label} request`);
    const h = this.held.shift()!;
    const range = `${h.url.searchParams.get("start_date")}..${h.url.searchParams.get("end_date")}`;
    if (range !== `${start}..${end}`) throw new Divergence(`${this.name}: ${label} request reads ${range}, model expects ${start}..${end}`);
    h.answer(Response.json(rows(cost)));
  }
}

export interface ReplayResult {
  steps: number;
  actions: string[];
  requests: Record<string, string[]>;
  crashes: number[];
}

/** Replays one behavior in `root` (a fresh private directory). */
export async function replay(env: Env, states: State[], root: string): Promise<ReplayResult> {
  const home = join(root, "home");
  mkdirSync(home, { recursive: true, mode: 0o700 });
  const clock = join(root, "clock");
  env.writeUsageClock(clock, tickMs(0));
  const ident = rec(states[0].ident);
  const procs = Object.fromEntries(PROCS.map((p) => [p, new Process(env, p, ident[p] as string)])) as Record<Proc, Process>;
  const actions: string[] = [];
  const crashes: number[] = [];
  let step = 0;
  try {
    await Promise.all(PROCS.map((p) => procs[p].start(home, clock)));
    for (step = 1; step < states.length; step += 1) {
      const s = states[step - 1];
      const t = states[step];
      const action = actionBetween(s, t);
      actions.push(describe(action));
      try {
        await perform(env, action, s, t, procs, clock, home, crashes);
        await settleAndCheck(t, procs, home);
      } catch (err) {
        if (err instanceof Divergence) {
          err.detail.step = step;
          err.detail.action = describe(action);
          err.detail.model = { now: t.now, skew: t.skew, open: t.open, shown: t.shown, mem: t.mem, cache: t.cache, corrupt: t.corrupt, inflight: t.inflight };
          err.detail.real = Object.fromEntries(Object.keys(KEYS).map((i) => [i, readCache(home, i)]));
          err.detail.requests = Object.fromEntries(PROCS.map((p) => [p, procs[p].requests]));
          err.detail.panes = Object.fromEntries(await Promise.all(PROCS.map(async (p) => [p, await procs[p].session.capturePane()])));
          err.detail.actions = actions;
        }
        throw err;
      }
    }
    return { steps: states.length - 1, actions, requests: Object.fromEntries(PROCS.map((p) => [p, procs[p].requests])), crashes };
  } finally {
    await Promise.all(PROCS.map((p) => procs[p].stop()));
  }
}

async function perform(env: Env, action: Action, s: State, t: State, procs: Record<Proc, Process>, clock: string, home: string, crashes: number[]): Promise<void> {
  switch (action.kind) {
    case "Tick":
    case "ClockBack":
      env.writeUsageClock(clock, tickMs(wall(t)));
      return;
    case "Corrupt": {
      const path = cachePath(home, action.i);
      if (!existsSync(path)) throw new Error(`Corrupt(${action.i}) with no cache file`);
      writeFileSync(path, "{\"schema_version\":2,\"identity\":\"garbage", { mode: 0o600 });
      return;
    }
  }
  const proc = procs[action.p];
  const session = proc.session;
  switch (action.kind) {
    case "Crash":
      crashes.push(await proc.crash(home, clock));
      return;
    case "Open": {
      await session.sendText("/usage");
      const shown = await until(async () => (await session.capturePane()).includes("usage: API key"));
      if (!shown) throw new Divergence(`${action.p}: /usage did not open`);
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
      await proc.claimStart(fetchOf(t, action.p)!);
      return;
    case "Complete": {
      const f = proc.fetch;
      if (!f) throw new Error("Complete without a claimed fetch");
      proc.fetch = null;
      f.today.answer(Response.json(rows(BASE[f.ident] + f.at)));
      if (f.fin) {
        const ms = tickMs(f.at);
        const day = new Date(ms);
        await proc.answerNext("7d", env.utcDate(ms - 6 * DAY_MS), env.utcDate(ms - DAY_MS), FIN_7D);
        const first = Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), 1);
        if (utcDay(first) !== utcDay(ms)) await proc.answerNext("month", env.utcDate(first), env.utcDate(ms - DAY_MS), 2000);
      }
      const want = modelCache(t, f.ident);
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

async function settleAndCheck(t: State, procs: Record<Proc, Process>, home: string): Promise<void> {
  await sleep(SETTLE_MS);
  for (const p of PROCS) {
    const allowed = timerDue(t, p) ? 1 : 0;
    if (procs[p].held.length > allowed) {
      const ranges = procs[p].held.map((h) => `${h.url.searchParams.get("start_date")}..${h.url.searchParams.get("end_date")}`);
      throw new Divergence(`${p}: fx sent a request the model does not make`, { ranges });
    }
  }
  for (const ident of Object.keys(KEYS)) {
    const want = modelCache(t, ident);
    const real = readCache(home, ident);
    if (!sameCache(real, want)) throw new Divergence(`cache for ${ident} differs from the model`, { want, real });
  }
  for (const p of PROCS) {
    if (rec(t.open)[p] !== true) continue;
    const shown = rec(rec(t.shown)[p]);
    const today = shown.today === null ? null : { ident: shown.ident as string, today: shown.today as number };
    const days7 = (shown.fin === null ? 0 : FIN_7D) + (today === null ? 0 : BASE[today.ident] + today.today);
    let last: ReturnType<typeof shownRows> | null = null;
    const ok = await until(async () => {
      last = shownRows(await procs[p].session.capturePane());
      return JSON.stringify(last.today) === JSON.stringify(today) && (last.days7 ?? 0) === days7;
    }, 3_000);
    if (!ok) throw new Divergence(`${p}: dashboard shows ${JSON.stringify(last)}, model shows today ${JSON.stringify(today)} and 7d $${days7}`);
  }
}
