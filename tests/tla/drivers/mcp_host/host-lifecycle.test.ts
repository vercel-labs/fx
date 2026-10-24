// HostLifecycle: the real fx shell in tmux with fixture stdio servers. The
// trace is the fixtures' own log (start, listed, eof, sigterm: one process
// each, by pid) merged in time order with what the harness did (`/mcp`
// verbs, Ctrl+C) and the status line once it stopped changing. Checked
// against HostLifecycle.tla through HostLifecycleTrace.tla.
import { expect, test } from "bun:test";
import { join } from "node:path";
import { artifacts } from "../lib/context";
import { BUN, FIXTURE, fixture, merge, save, serverEvents, stdioServer, waitFor, writeProfile, writeProject, type Fixture } from "./driver";
import { serverRecords, Shell } from "./shell";
import { checkTrace } from "./trace";

function alive(pid: number) { try { process.kill(pid, 0); return true; } catch { return false; } }
const started = (f: Fixture, name: string) => serverEvents(f).filter((e) => e.name === name && e.ev === "start");
const listed = (f: Fixture, name: string) => serverEvents(f).filter((e) => e.name === name && e.ev === "listed");
const stopped = (f: Fixture, name: string) => serverEvents(f).filter((e) => e.name === name && e.ev === "eof");

async function finish(shell: Shell, constants: Record<string, unknown>) {
  const events = serverEvents(shell.f);
  const quitAt = shell.records.find((r) => r.event === "quit")?.at ?? null;
  const records = merge(shell.records, serverRecords(events, quitAt));
  const verdict = await checkTrace({ module: "HostLifecycle", records, constants: constants as never, dir: join(shell.f.base, "trace") });
  save(join(shell.f.base, "verdict.json"), verdict);
  return { verdict, events };
}

function setup(name: string, profile: string[], project: string[], slow: string[] = [], extra: Record<string, Record<string, string>> = {}) {
  const f = fixture(artifacts, name);
  writeProfile(f, Object.fromEntries(profile.map((n) => [n, stdioServer(f, n, { ...(slow.includes(n) ? { FIXTURE_INIT_DELAY_MS: "6000" } : {}), ...extra[n] })])));
  if (project.length) writeProject(f, Object.fromEntries(project.map((n) => [n, stdioServer(f, n)])));
  return f;
}

test("first frame starts the profile servers, the project server waits unspawned, and quitting SIGTERMs all without waiting (trace ACCEPTED)", async () => {
  const shell = new Shell(setup("hl-first-frame", ["a", "b"], ["p"]));
  try {
    await shell.start();
    await waitFor("a and b listed", () => listed(shell.f, "a").length && listed(shell.f, "b").length, 20_000);
    const line = await shell.status({ k: "attn", who: "p", why: "waiting" });
    expect(line).toEqual({ k: "attn", who: "p", why: "waiting", r: 0, e: 0 });
    const pids = [...started(shell.f, "a"), ...started(shell.f, "b")].map((e) => e.pid);
    const quitMs = await shell.quit();
    await waitFor("every server gone", () => pids.every((pid) => !alive(pid)), 5_000);
    const { verdict, events } = await finish(shell, { ObsServers: ["a", "b", "p"], ObsProject: ["p"], ObsReachable: ["a", "b", "p"], ObsNeedsAuth: [], ObsMaxReloads: 0, ObsMaxLeases: 1 });
    expect(started(shell.f, "p")).toEqual([]);
    expect(events.filter((e) => e.ev === "sigterm").map((e) => e.name).sort()).toEqual(["a", "b"]);
    // A graceful stop would wait 1.5 s on the closed stdin before SIGTERM.
    expect(quitMs).toBeLessThan(1_000);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 120_000);

test("approve reloads in place: the project server starts and the unchanged servers keep their processes (trace ACCEPTED)", async () => {
  const shell = new Shell(setup("hl-approve", ["a", "b"], ["p"]));
  try {
    await shell.start();
    await waitFor("a and b listed", () => listed(shell.f, "a").length && listed(shell.f, "b").length, 20_000);
    await shell.status({ k: "attn", who: "p", why: "waiting" });
    await shell.type("/mcp approve p", { event: "reload", data: { server: "p", change: "approved" } });
    await shell.tui.waitForText("Approved p", 10_000);
    await waitFor("p listed", () => listed(shell.f, "p").length, 20_000);
    expect(await shell.status({ k: "none" })).toEqual({ k: "none", who: "", why: "", r: 0, e: 0 });
    // By the servers' own log: one process each of a and b, never stopped.
    expect(started(shell.f, "a").length).toBe(1);
    expect(started(shell.f, "b").length).toBe(1);
    expect(stopped(shell.f, "a")).toEqual([]);
    expect(stopped(shell.f, "b")).toEqual([]);
    await shell.quit();
    await Bun.sleep(500);
    const { verdict } = await finish(shell, { ObsServers: ["a", "b", "p"], ObsProject: ["p"], ObsReachable: ["a", "b", "p"], ObsNeedsAuth: [], ObsMaxReloads: 1, ObsMaxLeases: 1 });
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 150_000);

test("reject and remove reload in place: the project server never starts, the removed one stops for good, and the other keeps its process (trace ACCEPTED)", async () => {
  const shell = new Shell(setup("hl-reject-remove", ["a", "b"], ["p"]));
  try {
    await shell.start();
    await waitFor("a and b listed", () => listed(shell.f, "a").length && listed(shell.f, "b").length, 20_000);
    await shell.status({ k: "attn", who: "p", why: "waiting" });
    await shell.type("/mcp reject p", { event: "reload", data: { server: "p", change: "rejected" } });
    await shell.tui.waitForText("Rejected p", 10_000);
    expect(await shell.status({ k: "none" })).toEqual({ k: "none", who: "", why: "", r: 0, e: 0 });
    await shell.type("/mcp remove b", { event: "reload", data: { server: "b", change: "removed" } });
    await shell.tui.waitForText("Removed b", 10_000);
    await waitFor("b stopped", () => stopped(shell.f, "b").length, 10_000);
    expect(await shell.status({ k: "none" })).toEqual({ k: "none", who: "", why: "", r: 0, e: 0 });
    await shell.quit();
    await Bun.sleep(500);
    const { verdict } = await finish(shell, { ObsServers: ["a", "b", "p"], ObsProject: ["p"], ObsReachable: ["a", "b", "p"], ObsNeedsAuth: [], ObsMaxReloads: 2, ObsMaxLeases: 1 });
    expect(started(shell.f, "p")).toEqual([]);
    expect(started(shell.f, "b").length).toBe(1);
    expect(started(shell.f, "a").length).toBe(1);
    expect(stopped(shell.f, "a")).toEqual([]);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 150_000);

test("a reload while `/mcp show` waits on a server keeps that server's process, and the approved server starts without waiting for the show (trace ACCEPTED)", async () => {
  const shell = new Shell(setup("hl-show-reload", ["s"], ["p"], ["s"]));
  try {
    await shell.start();
    const [first] = await waitFor("s started", () => { const s = started(shell.f, "s"); return s.length === 1 ? s : null; }, 20_000);
    // `/mcp show s` waits for s, which takes 6 s to answer, holding the host it leased.
    await shell.type("/mcp show s", { event: "lease" });
    await Bun.sleep(500);
    await shell.type("/mcp approve p", { event: "reload", data: { server: "p", change: "approved" } });
    await shell.tui.waitForText("Approved p", 10_000);
    const [p] = await waitFor("p started", () => { const x = started(shell.f, "p"); return x.length ? x : null; }, 10_000);
    // The show prints once s answers, from the process it was waiting on.
    await shell.tui.waitForText("status     ready", 20_000);
    shell.records.push({ event: "release", at: Date.now() });
    const [answered] = await waitFor("s listed", () => { const x = listed(shell.f, "s"); return x.length ? x : null; }, 10_000);
    save(join(shell.f.base, "show-reload.json"), { s: started(shell.f, "s").map((e) => ({ pid: e.pid, t: e.t })), p: { pid: p!.pid, t: p!.t }, sListed: answered!.t });
    await shell.status({ k: "none" });
    await shell.quit();
    await Bun.sleep(500);
    const { verdict } = await finish(shell, { ObsServers: ["s", "p"], ObsProject: ["p"], ObsReachable: ["s", "p"], ObsNeedsAuth: [], ObsMaxReloads: 1, ObsMaxLeases: 1 });
    // One s, never stopped by the reload; p started before s answered.
    expect(started(shell.f, "s").map((e) => e.pid)).toEqual([first!.pid]);
    expect(p!.t).toBeLessThan(answered!.t);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 150_000);

test("a removed server added back runs one process at a time: the new one starts only once the old one, slow to stop, has exited (trace ACCEPTED)", async () => {
  const slowStop = { FIXTURE_EXIT_DELAY_MS: "1000" };
  const shell = new Shell(setup("hl-add-back", ["a", "s"], [], [], { s: slowStop }));
  try {
    await shell.start();
    await waitFor("a and s listed", () => listed(shell.f, "a").length && listed(shell.f, "s").length, 20_000);
    await shell.type("/mcp remove s", { event: "reload", data: { server: "s", change: "removed" } });
    await shell.tui.waitForText("Removed s", 10_000);
    // Added back while the first s still lingers after its stdin ended.
    const env = Object.entries({ FIXTURE_NAME: "s", FIXTURE_LOG: shell.f.serverLog, FIXTURE_CONTROL: shell.f.control, ...slowStop }).map(([k, v]) => `--env ${k}=${v}`).join(" ");
    await shell.type(`/mcp add ${env} s -- ${BUN} ${FIXTURE}`, { event: "reload", data: { server: "s", change: "ok" } });
    await shell.tui.waitForText("Added s", 10_000);
    const runs = await waitFor("a second s listed", () => { const x = started(shell.f, "s"); return x.length === 2 && listed(shell.f, "s").length === 2 ? x : null; }, 20_000);
    const firstExit = stopped(shell.f, "s").find((e) => e.pid === runs[0]!.pid);
    save(join(shell.f.base, "add-back.json"), { s: runs.map((e) => ({ pid: e.pid, t: e.t })), firstExit: firstExit?.t ?? null });
    expect(await shell.status({ k: "none" })).toEqual({ k: "none", who: "", why: "", r: 0, e: 0 });
    await shell.quit();
    await Bun.sleep(500);
    const { verdict } = await finish(shell, { ObsServers: ["a", "s"], ObsProject: [], ObsReachable: ["a", "s"], ObsNeedsAuth: [], ObsMaxReloads: 2, ObsMaxLeases: 1 });
    // By the servers' own log: the second s started after the first exited, and a never restarted.
    expect(firstExit).toBeDefined();
    expect(runs[1]!.t).toBeGreaterThanOrEqual(firstExit!.t);
    expect(started(shell.f, "a").length).toBe(1);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 150_000);
