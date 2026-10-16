// HostLifecycle: the real fx shell in tmux with fixture stdio servers. The
// trace is the fixtures' own log (start, listed, eof, sigterm: one process
// each, by pid) merged in time order with what the harness did (`/mcp`
// verbs, Ctrl+C) and the status line once it stopped changing. Checked
// against HostLifecycle.tla through HostLifecycleTrace.tla.
import { expect, test } from "bun:test";
import { join } from "node:path";
import { artifacts } from "../lib/context";
import { fixture, merge, save, serverEvents, stdioServer, waitFor, writeProfile, writeProject, type Fixture } from "./driver";
import { serverRecords, Shell } from "./shell";
import { checkTrace } from "./trace";

function alive(pid: number) { try { process.kill(pid, 0); return true; } catch { return false; } }
const started = (f: Fixture, name: string) => serverEvents(f).filter((e) => e.name === name && e.ev === "start");
const listed = (f: Fixture, name: string) => serverEvents(f).filter((e) => e.name === name && e.ev === "listed");

async function finish(shell: Shell, constants: Record<string, unknown>) {
  const events = serverEvents(shell.f);
  const quitAt = shell.records.find((r) => r.event === "quit")?.at ?? null;
  const records = merge(shell.records.filter((r) => r.event !== "release"), serverRecords(events, quitAt));
  // A release goes right before the exit of the process its host's end stops
  // (the pane is read after the fact, and one log line can share its millisecond).
  for (const release of shell.records.filter((r) => r.event === "release")) {
    const pid = release.data?.beforeExitOf;
    const at = records.findIndex((r) => r.event === "stop" && r.note?.startsWith(`pid ${pid} `));
    if (at < 0) throw new Error(`harness: no exit of pid ${pid} to place the release before`);
    records.splice(at, 0, { event: "release", at: records[at]!.at, note: release.note });
  }
  const verdict = await checkTrace({ module: "HostLifecycle", records, constants: constants as never, dir: join(shell.f.base, "trace") });
  save(join(shell.f.base, "verdict.json"), verdict);
  return { verdict, events };
}

function setup(name: string, profile: string[], project: string[], slow: string[] = []) {
  const f = fixture(artifacts, name);
  writeProfile(f, Object.fromEntries(profile.map((n) => [n, stdioServer(f, n, slow.includes(n) ? { FIXTURE_INIT_DELAY_MS: "6000" } : {})])));
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
    const { verdict, events } = await finish(shell, { ObsServers: ["a", "b", "p"], ObsProject: ["p"], ObsReachable: ["a", "b", "p"], ObsNeedsAuth: [], ObsMaxHosts: 1, ObsMaxLeases: 1 });
    expect(started(shell.f, "p")).toEqual([]);
    expect(events.filter((e) => e.ev === "sigterm").map((e) => e.name).sort()).toEqual(["a", "b"]);
    // A graceful stop would wait 1.5 s on the closed stdin before SIGTERM.
    expect(quitMs).toBeLessThan(1_000);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 120_000);

test("approve reloads: the project server starts and the unchanged servers come back (trace ACCEPTED)", async () => {
  const shell = new Shell(setup("hl-approve", ["a", "b"], ["p"]));
  try {
    await shell.start();
    await waitFor("a and b listed", () => listed(shell.f, "a").length && listed(shell.f, "b").length, 20_000);
    await shell.status({ k: "attn", who: "p", why: "waiting" });
    await shell.type("/mcp approve p", { event: "reload", data: { server: "p", change: "approved" } });
    await shell.tui.waitForText("Approved p", 10_000);
    await waitFor("p, a and b listed again", () => listed(shell.f, "p").length && listed(shell.f, "a").length === 2 && listed(shell.f, "b").length === 2, 20_000);
    expect(await shell.status({ k: "none" })).toEqual({ k: "none", who: "", why: "", r: 0, e: 0 });
    await shell.quit();
    await Bun.sleep(500);
    const { verdict, events } = await finish(shell, { ObsServers: ["a", "b", "p"], ObsProject: ["p"], ObsReachable: ["a", "b", "p"], ObsNeedsAuth: [], ObsMaxHosts: 2, ObsMaxLeases: 1 });
    // The first a and b stopped at their stdin's end before their successors started.
    expect(events.filter((e) => e.ev === "eof").map((e) => e.name).sort()).toEqual(["a", "b"]);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 150_000);

test("reject and remove reload: the project server never starts and the removed one stops for good (trace ACCEPTED)", async () => {
  const shell = new Shell(setup("hl-reject-remove", ["a", "b"], ["p"]));
  try {
    await shell.start();
    await waitFor("a and b listed", () => listed(shell.f, "a").length && listed(shell.f, "b").length, 20_000);
    await shell.status({ k: "attn", who: "p", why: "waiting" });
    await shell.type("/mcp reject p", { event: "reload", data: { server: "p", change: "rejected" } });
    await shell.tui.waitForText("Rejected p", 10_000);
    await waitFor("a and b listed again", () => listed(shell.f, "a").length === 2 && listed(shell.f, "b").length === 2, 20_000);
    expect(await shell.status({ k: "none" })).toEqual({ k: "none", who: "", why: "", r: 0, e: 0 });
    await shell.type("/mcp remove b", { event: "reload", data: { server: "b", change: "removed" } });
    await shell.tui.waitForText("Removed b", 10_000);
    await waitFor("a listed a third time", () => listed(shell.f, "a").length === 3, 20_000);
    expect(await shell.status({ k: "none" })).toEqual({ k: "none", who: "", why: "", r: 0, e: 0 });
    await shell.quit();
    await Bun.sleep(500);
    const { verdict } = await finish(shell, { ObsServers: ["a", "b", "p"], ObsProject: ["p"], ObsReachable: ["a", "b", "p"], ObsNeedsAuth: [], ObsMaxHosts: 3, ObsMaxLeases: 1 });
    expect(started(shell.f, "p")).toEqual([]);
    expect(started(shell.f, "b").length).toBe(2);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 150_000);

test("a reload while `/mcp show` holds the old host runs one process of a server at a time: the new host starts nothing until the old one's process stops (trace VIOLATES AtMostOneOwner only, by design)", async () => {
  const shell = new Shell(setup("hl-one-process", ["s"], ["p"], ["s"]));
  try {
    await shell.start();
    const [first] = await waitFor("s started", () => { const s = started(shell.f, "s"); return s.length === 1 ? s : null; }, 20_000);
    // `/mcp show s` waits for s, which takes 6 s to answer, holding the host it leased.
    await shell.type("/mcp show s", { event: "lease" });
    await Bun.sleep(500);
    await shell.type("/mcp approve p", { event: "reload", data: { server: "p", change: "approved" } });
    await shell.tui.waitForText("Approved p", 10_000);
    // The show prints once the first s answers; its lease ends and the old host goes.
    await shell.tui.waitForText("status     ready", 20_000);
    const seen = Date.now();
    const eof = await waitFor("the first s stopped", () => serverEvents(shell.f).find((e) => e.name === "s" && e.ev === "eof" && e.pid === first!.pid), 10_000);
    // `finish` puts the release right before that s's exit.
    shell.records.push({ event: "release", at: seen, note: `seen ${seen}, first s eof ${eof.t}; placed before pid ${eof.pid}'s exit`, data: { beforeExitOf: eof.pid } });
    await waitFor("p and the second s listed", () => listed(shell.f, "p").length && listed(shell.f, "s").length === 2, 20_000);
    const runs = started(shell.f, "s");
    const p = started(shell.f, "p");
    save(join(shell.f.base, "one-process.json"), { firstEof: eof.t, s: runs.map((e) => ({ pid: e.pid, t: e.t })), p: p.map((e) => ({ pid: e.pid, t: e.t })) });
    await shell.status({ k: "none" });
    await shell.quit();
    await Bun.sleep(500);
    const { verdict } = await finish(shell, { ObsServers: ["s", "p"], ObsProject: ["p"], ObsReachable: ["s", "p"], ObsNeedsAuth: [], ObsMaxHosts: 2, ObsMaxLeases: 1 });
    // By the servers' own log: two runs of s, never at once, and the new
    // host started both its servers only after the old s stopped.
    expect(runs.length).toBe(2);
    expect(runs[1]!.t).toBeGreaterThanOrEqual(eof.t);
    expect(p.length).toBe(1);
    expect(p[0]!.t).toBeGreaterThanOrEqual(eof.t);
    // A lease keeps the old host's owner running to finish its calls, so two
    // owners are alive at once by design; one process per server holds.
    expect(verdict.verdict).toBe("VIOLATES");
    expect(verdict.broken).toEqual(["AtMostOneOwner"]);
  } finally { await shell.stop(); }
}, 150_000);
