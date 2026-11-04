// StoreLockBudget: real fx processes take the MCP credential store's lock on
// the macOS Keychain backend while the harness slows their Keychain reads,
// lets a read hang past the hold budget, freezes or kills a holder, holds
// the lock itself with no stamp as an older fx does, or writes garbage into
// the lock file. Each process is `fx mcp list --json`, which reads the store
// once under the lock and contacts no server. Their "MCP store lock" trace
// lines and the harness's steps are checked by TLC against
// StoreLockBudgetTrace.tla, the rules of StoreLockBudget.tla on the real
// clock, and each run asserts what it must show.
//
// The Keychain is the user's, through a temp HOME that links
// ~/Library/Keychains and a throwaway USER, so no real account is read;
// `fx mcp list` never writes the store.
//
// FX_TLA_REPEAT repeats the turns schedule with fresh seeds.
import { expect, test } from "bun:test";
import { dlopen, FFIType, ptr } from "bun:ffi";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { artifacts, binary, repetitions } from "../lib/context";
import { fixture, save, writeProfile, type Fixture } from "./driver";
import { checkTrace, type TraceRecord, type Verdict } from "./trace";

const SERVICE = "FX_MCP_OAUTH_CREDENTIALS_V3";
const ACCOUNT_PREFIX = "fx-tla-mcp-lock-";
/** credentials.zig hold_budget_ms and hold_slack_ms. */
const BUDGET = 10_000;
const SLACK = 2_000;
/** Scheduling noise allowed around every deadline. */
const TOLERANCE = 600;
const darwin = process.platform === "darwin";

// fx's stamps are on Zig's awake clock, CLOCK_UPTIME_RAW on macOS, which
// stops while the machine sleeps; Bun's hrtime doesn't. libproc finds each
// fx's Keychain calls among its children within a millisecond, before a
// ~100 ms call ends.
const libSystem = darwin
  ? dlopen("/usr/lib/libSystem.B.dylib", {
    clock_gettime_nsec_np: { args: [FFIType.i32], returns: FFIType.u64 },
    proc_listchildpids: { args: [FFIType.i32, FFIType.ptr, FFIType.i32], returns: FFIType.i32 },
    proc_pidpath: { args: [FFIType.i32, FFIType.ptr, FFIType.u32], returns: FFIType.i32 },
  }).symbols
  : null;
const CLOCK_UPTIME_RAW = 8;
const awakeMs = () => Number(BigInt(libSystem!.clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000n);

const childPids = new Int32Array(256);
const pathBytes = new Uint8Array(4096);
function children(pid: number): number[] {
  const n = libSystem!.proc_listchildpids(pid, ptr(childPids), childPids.byteLength);
  return n > 0 ? Array.from(childPids.subarray(0, Math.min(n, childPids.length))) : [];
}
function executable(pid: number): string | null {
  const n = libSystem!.proc_pidpath(pid, ptr(pathBytes), pathBytes.byteLength);
  return n > 0 ? new TextDecoder().decode(pathBytes.subarray(0, n)) : null;
}

interface Scene { f: Fixture; account: string; lock: string; t0: number; records: TraceRecord[]; procs: Proc[]; paused: Set<number>; timers: ReturnType<typeof setTimeout>[]; seeded?: boolean }
interface Proc { label: string; child: ReturnType<typeof Bun.spawn>; started: number; trace: string; done: Promise<{ code: number; out: string; err: string; ended: number }> }

function scene(name: string): Scene {
  const f = fixture(artifacts, name);
  writeProfile(f, { web: { type: "http", url: "http://127.0.0.1:9/mcp" } });
  mkdirSync(join(f.home, "Library"), { recursive: true });
  symlinkSync(join(homedir(), "Library", "Keychains"), join(f.home, "Library", "Keychains"), "dir");
  const account = `${ACCOUNT_PREFIX}${process.pid}-${randomUUID()}`;
  return { f, account, lock: join(f.home, ".fx", "mcp-credentials", "credentials-v3.lock"), t0: awakeMs(), records: [], procs: [], paused: new Set(), timers: [] };
}

function note(s: Scene, event: string, data: Record<string, string | number>) {
  s.records.push({ event, data: { ...data, at: (data.at as number | undefined) ?? awakeMs() - s.t0 }, at: (data.at as number | undefined) ?? awakeMs() - s.t0 });
}

/** One `fx mcp list --json` (or `args`) against the scene's store, traced to its own file. */
function start(s: Scene, label: string, args = ["mcp", "list", "--json"]): Proc {
  const trace = join(s.f.base, `${label}.trace`);
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: s.f.home, USER: s.account, TMPDIR: process.env.TMPDIR ?? "/tmp",
    FX_NO_OPEN_BROWSER: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_TEST_SKIP_ONBOARDING: "1", FX_E2E_DISABLE_DOTENV: "1",
    FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "mcp,keychain", AI_GATEWAY_API_KEY: "fake-store-lock-key",
  };
  const started = awakeMs();
  const child = Bun.spawn([binary, ...args], { cwd: s.f.workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const done = Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()])
    .then(([code, out, err]) => ({ code, out, err, ended: awakeMs() }));
  const proc = { label, child, started, trace, done };
  s.procs.push(proc);
  return proc;
}

/**
 * Slows each Keychain call the scene's fx processes make, each an
 * `osascript` child, by `pauseFor(n)` ms, n counting calls from 0, until
 * `stop`. `fx mcp list` makes one read per hold of the store lock; other
 * children, such as `security`'s Keychain check, go untouched. Resolves
 * `first` with the first call's pid and its fx parent.
 */
function slowReads(s: Scene, pauseFor: (n: number) => number) {
  const seen = new Set<number>();
  let calls = 0;
  let stopped = false;
  let resolveFirst: (v: { pid: number; parent: number }) => void = () => {};
  const first = new Promise<{ pid: number; parent: number }>((r) => (resolveFirst = r));
  void (async () => {
    while (!stopped) {
      for (const p of s.procs) {
        for (const pid of children(p.child.pid)) {
          if (seen.has(pid)) continue;
          const exe = executable(pid);
          // Forked but not yet exec'd: still fx; look again next time.
          if (exe === null || exe === binary || exe.endsWith("/fx")) continue;
          seen.add(pid);
          if (exe !== "/usr/bin/osascript") continue;
          const n = calls++;
          const ms = pauseFor(n);
          if (ms > 0) {
            try { process.kill(pid, "SIGSTOP"); } catch { continue; }
            s.paused.add(pid);
            s.timers.push(setTimeout(() => { try { process.kill(pid, "SIGCONT"); } catch {} s.paused.delete(pid); }, ms));
          }
          if (n === 0) resolveFirst({ pid, parent: p.child.pid });
        }
      }
      await Bun.sleep(1);
    }
  })();
  return { first, stop: () => { stopped = true; } };
}

// The same Security calls fx's osascript helper makes, for the throwaway account.
const KEYCHAIN_SCRIPT = `
ObjC.import("Security");
ObjC.import("Foundation");
const object = (value) => ObjC.castRefToObject(value);
function run(argv) {
  const query = $.NSMutableDictionary.alloc.init;
  query.setObjectForKey(object($.kSecClassGenericPassword), object($.kSecClass));
  query.setObjectForKey($(argv[1]), object($.kSecAttrAccount));
  query.setObjectForKey($(argv[2]), object($.kSecAttrService));
  if (argv[0] === "delete") {
    const status = $.SecItemDelete(query);
    if (status !== 0 && status !== -25300) throw new Error("keychain status=" + status);
    return "";
  }
  const secret = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  const update = $.NSMutableDictionary.alloc.init;
  update.setObjectForKey(secret, object($.kSecValueData));
  if ($.SecItemUpdate(query, update) === 0) return "";
  query.setObjectForKey(secret, object($.kSecValueData));
  const status = $.SecItemAdd(query, null);
  if (status !== 0) throw new Error("keychain status=" + status);
  return "";
}`;

function keychainItem(s: Scene, op: "store" | "delete", text = "") {
  if (!s.account.startsWith(ACCOUNT_PREFIX)) throw new Error("refusing to touch a non-test MCP Keychain account");
  const r = spawnSync("/usr/bin/osascript", ["-l", "JavaScript", "-e", KEYCHAIN_SCRIPT, op, s.account, SERVICE], {
    input: text, encoding: "utf8", env: { ...process.env, HOME: s.f.home, USER: s.account },
  });
  if (r.status !== 0) throw new Error(`keychain ${op} failed: ${r.stderr}`);
}

/** Holds the lock from another process with no stamp, as an older fx does, for `seconds`. */
async function holdWithoutStamp(s: Scene, seconds: number) {
  mkdirSync(join(s.f.home, ".fx", "mcp-credentials"), { recursive: true, mode: 0o700 });
  const holder = Bun.spawn(["perl", "-e", 'use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "held\\n"; sleep $ARGV[1];', s.lock, String(seconds)], { stdout: "pipe" });
  const { value } = await holder.stdout.getReader().read();
  expect(new TextDecoder().decode(value)).toBe("held\n");
  return holder;
}

interface Seen { label: string; takes: { at: number; started: number }[]; releases: number[]; giveups: { at: number; started: number }[]; readFailed: boolean }

/** The process's lock trace lines, on the scene's clock. */
function seen(s: Scene, p: Proc): Seen {
  const text = existsSync(p.trace) ? readFileSync(p.trace, "utf8") : "";
  const out: Seen = { label: p.label, takes: [], releases: [], giveups: [], readFailed: /\[keychain\] load failed/.test(text) };
  for (const line of text.split("\n")) {
    let m = /MCP store lock taken stamp=(\d+) started=(\d+)/.exec(line);
    if (m) out.takes.push({ at: Number(m[1]) - s.t0, started: Number(m[2]) - s.t0 });
    m = /MCP store lock released stamp=\d+ at=(\d+)/.exec(line);
    if (m) out.releases.push(Number(m[1]) - s.t0);
    m = /MCP store lock given up stamp=\S+ started=(\d+) at=(\d+)/.exec(line);
    if (m) out.giveups.push({ at: Number(m[2]) - s.t0, started: Number(m[1]) - s.t0 });
  }
  return out;
}

/** Waits for every process, folds their lines into the trace, and has TLC check it. */
async function finish(s: Scene): Promise<{ verdict: Verdict; seen: Seen[]; results: Awaited<Proc["done"]>[] }> {
  const results = await Promise.all(s.procs.map((p) => p.done));
  const all = s.procs.map((p) => seen(s, p));
  for (const [k, p] of s.procs.entries()) {
    const v = all[k]!;
    // The stamps are on the clock this harness reads: each lies inside its process's life.
    for (const t of v.takes) {
      expect(t.at + s.t0).toBeGreaterThanOrEqual(p.started - 5);
      expect(t.at + s.t0).toBeLessThanOrEqual(results[k]!.ended + 5);
    }
    for (const t of v.takes) s.records.push({ event: "take", data: { p: p.label, at: t.at, started: t.started }, at: t.at });
    for (const at of v.releases) s.records.push({ event: "release", data: { p: p.label, at }, at });
    for (const g of v.giveups) s.records.push({ event: "giveup", data: { p: p.label, at: g.at, started: g.started }, at: g.at });
  }
  // Time order; at the same millisecond a release comes before a take.
  const rank: Record<string, number> = { kill: 0, release: 0, foreign_release: 0, thaw: 1, scribble: 1, freeze: 2, giveup: 3, take: 4, foreign: 4 };
  s.records.sort((a, b) => (a.at ?? 0) - (b.at ?? 0) || (rank[a.event] ?? 5) - (rank[b.event] ?? 5));
  const verdict = await checkTrace({
    module: "StoreLockBudget", records: s.records, dir: join(s.f.base, "trace"),
    constants: { ObsBudget: BUDGET, ObsSlack: SLACK, ObsTolerance: TOLERANCE },
  });
  save(join(s.f.base, "seen.json"), { seen: all, results: results.map((r) => ({ code: r.code, err: r.err })) });
  console.log(`${s.f.base}: ${verdict.verdict}${verdict.broken ? ` broken=${verdict.broken.join(",")}` : ""} records=${verdict.records}`);
  return { verdict, seen: all, results };
}

function cleanup(s: Scene) {
  if (s.seeded) try { keychainItem(s, "delete"); } catch (err) { console.log(String(err)); }
  for (const t of s.timers) clearTimeout(t);
  for (const pid of s.paused) try { process.kill(pid, "SIGCONT"); } catch {}
  for (const p of s.procs) try { process.kill(p.child.pid, "SIGCONT"); p.child.kill("SIGKILL"); } catch {}
  try { unlinkSync(join(s.f.home, "Library", "Keychains")); } catch {}
}

const totals = (all: Seen[]) => ({
  takes: all.reduce((n, v) => n + v.takes.length, 0),
  releases: all.reduce((n, v) => n + v.releases.length, 0),
  giveups: all.reduce((n, v) => n + v.giveups.length, 0),
});

async function waitForTake(p: Proc, s: Scene, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (seen(s, p).takes.length > 0) return;
    await Bun.sleep(10);
  }
  throw new Error(`${p.label} never took the store lock`);
}

test.skipIf(!darwin)("a slow Keychain read: the waiters take the lock in turn and none gives up", async () => {
  const s = scene("slb-slow");
  try {
    const slow = slowReads(s, (n) => (n === 0 ? 5_000 : 0));
    const holder = start(s, "holder");
    await slow.first;
    await waitForTake(holder, s, 10_000);
    for (const k of [1, 2, 3]) start(s, `waiter${k}`);
    const { verdict, seen: all, results } = await finish(s);
    slow.stop();
    expect(results.map((r) => r.code)).toEqual([0, 0, 0, 0]);
    expect(totals(all)).toEqual({ takes: 4, releases: 4, giveups: 0 });
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 90_000);

test.skipIf(!darwin)("a Keychain read that hangs past the budget is cut at it, and the waiters go on", async () => {
  const s = scene("slb-hang");
  try {
    const slow = slowReads(s, (n) => (n === 0 ? 16_000 : 0));
    const holder = start(s, "holder");
    await slow.first;
    await waitForTake(holder, s, 10_000);
    for (const k of [1, 2]) start(s, `waiter${k}`);
    const { verdict, seen: all } = await finish(s);
    slow.stop();
    const h = all[0]!;
    expect(h.readFailed).toBe(true);
    // Cut by its hold's deadline, not its read's own 10 s from a later start.
    expect(h.releases[0]! - h.takes[0]!.at).toBeLessThanOrEqual(BUDGET + TOLERANCE);
    expect(totals(all)).toEqual({ takes: 3, releases: 3, giveups: 0 });
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 90_000);

for (let rep = 0; rep < Math.max(1, repetitions); rep++) {
  test.skipIf(!darwin)(`holders taking turns outlast a waiter's own 12 s and it still waits (seed ${rep})`, async () => {
    const s = scene(`slb-turns-${rep}`);
    try {
      // Seeded: each read is slowed 3 to 6 s; five processes queue, about 22 s in all.
      let seed = 0x5eed + rep;
      const next = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
      const pauses = Array.from({ length: 5 }, () => 3_000 + Math.floor(next() * 3_000));
      save(join(s.f.base, "pauses.json"), pauses);
      const slow = slowReads(s, (n) => pauses[n] ?? 0);
      for (const k of [0, 1, 2, 3, 4]) start(s, `p${k}`);
      const { verdict, seen: all } = await finish(s);
      slow.stop();
      const t = totals(all);
      expect(t).toEqual({ takes: 5, releases: 5, giveups: 0 });
      // The last process waited longer than 12 s from its own start.
      const longest = Math.max(...all.map((v) => (v.takes[0]?.at ?? 0) - (v.takes[0]?.started ?? 0)));
      save(join(s.f.base, "longest-wait.json"), { longest });
      expect(longest).toBeGreaterThan(BUDGET + SLACK);
      expect(verdict.verdict).toBe("ACCEPTED");
    } finally { cleanup(s); }
  }, 120_000);
}

test.skipIf(!darwin)("eight waiters behind slowed reads all get the lock", async () => {
  const s = scene("slb-stress");
  try {
    const slow = slowReads(s, () => 1_800);
    for (const k of [0, 1, 2, 3, 4, 5, 6, 7]) start(s, `p${k}`);
    const { verdict, seen: all, results } = await finish(s);
    slow.stop();
    expect(results.every((r) => r.code === 0)).toBe(true);
    expect(totals(all)).toEqual({ takes: 8, releases: 8, giveups: 0 });
    const waits = all.map((v) => (v.takes[0]?.at ?? 0) - (v.takes[0]?.started ?? 0)).sort((a, b) => a - b);
    save(join(s.f.base, "waits.json"), waits);
    console.log(`waits ms: ${waits.join(" ")}`);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 120_000);

test.skipIf(!darwin)("a frozen holder: waiters give up 12 s after they start waiting, not before", async () => {
  const s = scene("slb-frozen");
  try {
    const slow = slowReads(s, (n) => (n === 0 ? 3_000 : 0));
    const holder = start(s, "holder");
    await slow.first;
    await waitForTake(holder, s, 10_000);
    // ctrl+z: the holder itself stops, with the lock.
    process.kill(holder.child.pid, "SIGSTOP");
    note(s, "freeze", { p: "holder" });
    for (const k of [1, 2]) start(s, `waiter${k}`);
    const waiters = s.procs.slice(1);
    await Promise.all(waiters.map((w) => w.done));
    process.kill(holder.child.pid, "SIGCONT");
    note(s, "thaw", { p: "holder" });
    const { verdict, seen: all } = await finish(s);
    slow.stop();
    expect(totals(all).giveups).toBe(2);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 90_000);

test.skipIf(!darwin)("a holder killed mid-hold: the next waiter takes the lock at once", async () => {
  const s = scene("slb-kill");
  let read: { pid: number; parent: number } | null = null;
  try {
    const slow = slowReads(s, (n) => (n === 0 ? 30_000 : 0));
    const holder = start(s, "holder");
    read = await slow.first;
    await waitForTake(holder, s, 10_000);
    for (const k of [1, 2]) start(s, `waiter${k}`);
    await Bun.sleep(2_000);
    // Its Keychain child stays behind, still paused, as after a crash: the
    // lock must go with fx itself, not wait for the child.
    holder.child.kill("SIGKILL");
    note(s, "kill", { p: "holder" });
    const killedAt = awakeMs() - s.t0;
    await Promise.all(s.procs.slice(1).map((p) => p.done));
    // The store is left readable: one more list reads it.
    start(s, "after");
    const { verdict, seen: all, results } = await finish(s);
    slow.stop();
    const firstTake = Math.min(...all.slice(1, 3).map((v) => v.takes[0]?.at ?? Infinity));
    expect(firstTake - killedAt).toBeLessThan(TOLERANCE);
    expect(totals(all).giveups).toBe(0);
    expect(results.at(-1)!.code).toBe(0);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally {
    cleanup(s);
    if (read && read.pid > 1) try { process.kill(read.pid, "SIGKILL"); } catch {}
  }
}, 90_000);

test.skipIf(!darwin)("an older fx holds the lock with no stamp: waiters give up 12 s after their own start", async () => {
  const s = scene("slb-older");
  try {
    // A stamp from earlier, before the waiters start.
    start(s, "earlier");
    await s.procs[0]!.done;
    const holder = await holdWithoutStamp(s, 16);
    note(s, "foreign", { p: "older" });
    for (const k of [1, 2]) start(s, `waiter${k}`);
    await Promise.all(s.procs.slice(1).map((p) => p.done));
    holder.kill();
    note(s, "foreign_release", { p: "older" });
    const { verdict, seen: all } = await finish(s);
    expect(totals(all).giveups).toBe(2);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 90_000);

test.skipIf(!darwin)("garbage in the lock file counts as no stamp", async () => {
  const s = scene("slb-garbage");
  try {
    mkdirSync(join(s.f.home, ".fx", "mcp-credentials"), { recursive: true, mode: 0o700 });
    // Read as a stamp, these bytes lie far in the future.
    writeFileSync(s.lock, "garbage!", { mode: 0o600 });
    note(s, "scribble", { p: "harness" });
    const holder = await holdWithoutStamp(s, 16);
    note(s, "foreign", { p: "older" });
    start(s, "waiter");
    await s.procs[0]!.done;
    holder.kill();
    note(s, "foreign_release", { p: "older" });
    const { verdict, seen: all } = await finish(s);
    const g = all[0]!.giveups[0]!;
    expect(g.at - g.started).toBeGreaterThanOrEqual(BUDGET + SLACK - TOLERANCE);
    expect(g.at - g.started).toBeLessThanOrEqual(BUDGET + SLACK + TOLERANCE);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 90_000);

test.skipIf(!darwin)("a hold with two slow Keychain calls ends at its budget", async () => {
  const s = scene("slb-two-calls");
  try {
    // web's login is saved, so signing out reads the store and writes it back.
    const credential = JSON.stringify({ access: "a", refresh: "r", expires_at_ms: null, token_endpoint: "http://127.0.0.1:9/token", revocation_endpoint: null, resource: "http://127.0.0.1:9/mcp", client_id: "c", client_secret: null, method: "none" });
    keychainItem(s, "store", JSON.stringify({ version: 1, servers: [{ name: "web", url: "http://127.0.0.1:9/mcp", credential }] }));
    s.seeded = true;
    // Every Keychain call takes 6 s: a read and a write in one hold would take 12.
    const slow = slowReads(s, () => 6_000);
    start(s, "logout", ["mcp", "logout", "web"]);
    await slow.first;
    start(s, "waiter");
    const { verdict, seen: all } = await finish(s);
    slow.stop();
    for (const v of all) {
      for (const [k, t] of v.takes.entries()) {
        const released = v.releases[k];
        if (released !== undefined) expect(released - t.at).toBeLessThanOrEqual(BUDGET + TOLERANCE);
      }
    }
    expect(totals(all).giveups).toBe(0);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { cleanup(s); }
}, 120_000);
