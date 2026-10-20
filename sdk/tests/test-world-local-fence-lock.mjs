#!/usr/bin/env node
// The World libfx bundles for local(): a writer killed while it holds
// world-local's in-band fence lock does not hold up the next writer, the
// worker taking its session over (DUR-88), and the lock still lets one
// writer at a time through its check-and-advance.
//
//   node sdk/tests/test-world-local-fence-lock.mjs [<libfx-package-dir>]
//
// With a package directory, such as sdk/dist/libfx, this tests its
// durable/local.mjs. Without one, it bundles the durability modules first,
// with Bun (`BUN_BIN`, default `bun`) after `npm ci --prefix sdk/durable`.
// The writers in other processes are this script with `--child`.
import { strict as assert } from "node:assert";
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, readdir, rename as renameDir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";

const args = process.argv.slice(2);
const child = args[0] === "--child" ? Object.fromEntries(args.slice(1).map((value, index, all) => index % 2 === 0 ? [value.replace(/^--/, ""), all[index + 1]] : null).filter(Boolean)) : null;
const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = resolve(fileURLToPath(new URL(".", import.meta.url)), "../..");
const dirs = [];

let packageDir = child ? child.package : args[0];
if (!packageDir) {
  packageDir = await mkdtemp(join(tmpdir(), "libfx-fence-bundle-"));
  dirs.push(packageDir);
  const bundled = spawnSync(process.env.BUN_BIN || "bun", [join(repoRoot, "sdk/scripts/bundle-durable.mjs"), packageDir], { stdio: "inherit" });
  if (bundled.error) throw bundled.error;
  if (bundled.status !== 0) process.exit(bundled.status ?? 1);
}
packageDir = resolve(packageDir);
const localModule = join(packageDir, "durable/local.mjs");
if (!existsSync(localModule)) throw new Error(`no durable/local.mjs in ${packageDir}`);
const { local } = await import(pathToFileURL(localModule).href);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const encoder = new TextEncoder();
const lockDirOf = (dir, runId) => join(dir, ".locks", "runs", `${runId}.in-band.lock`);

async function openWorld(dir) {
  const world = local({ dir }).world();
  await world.start?.();
  return world;
}

// A run as libfx creates one for a session.
async function createRun(world) {
  const created = await world.events.create(null, {
    eventType: "run_created",
    specVersion: world.specVersion,
    eventData: { deploymentId: "libfx", workflowName: "libfx/session", input: encoder.encode("{}") },
  });
  await world.events.create(created.event.runId, { eventType: "run_started", specVersion: world.specVersion });
  return created.event.runId;
}

// One in-band write at `expected`, as libfx writes a session-log entry.
async function writeAt(world, runId, expected, size = 16) {
  try {
    await world.events.create(runId, {
      eventType: "step_created",
      correlationId: `step_${process.pid}_${Math.random().toString(36).slice(2)}`,
      specVersion: world.specVersion,
      eventData: { stepName: "fx.log", input: new Uint8Array(size) },
    }, { eventCount: 0, inBand: true, expectedSeqInBand: expected });
    return { status: "accepted" };
  } catch (error) {
    if (error?.name === "InBandSupersededError") return { status: "refused", seqInBand: error.seqInBand };
    return { status: "error", message: String(error?.message ?? error) };
  }
}

// An in-band write at the count the World reports, again at the count a
// refusal reports: a dead writer's mark counts its write.
async function writeAtCount(world, runId, size) {
  const { snapshot } = await world.events.list({ runId });
  let answer = await writeAt(world, runId, snapshot.seqInBand, size);
  if (answer.status === "refused") answer = await writeAt(world, runId, answer.seqInBand, size);
  return answer;
}

// A writer makes `writes` writes of `size` bytes each, long enough to be
// killed in. A racer makes one small write at the count it was given, when
// told to go.
async function runChild({ role, dir, run, size, writes, expected }) {
  const world = await openWorld(dir);
  const lines = createInterface({ input: process.stdin });
  console.log("ready");
  if (role === "writer") {
    for (let left = Number(writes); left > 0; left -= 1) {
      const answer = await writeAtCount(world, run, Number(size));
      if (answer.status !== "accepted") console.error(answer);
    }
    return;
  }
  for await (const line of lines) {
    if (line !== "go") continue;
    console.log(JSON.stringify(await writeAt(world, run, Number(expected))));
    return;
  }
}

if (child) {
  await runChild(child);
  process.exit(0);
}

function spawnChild(role, dir, runId, extra = []) {
  const proc = spawn(process.execPath, [scriptPath, "--child", "--role", role, "--package", packageDir, "--dir", dir, "--run", runId, ...extra], { stdio: ["pipe", "pipe", "inherit"] });
  const lines = createInterface({ input: proc.stdout });
  const queued = [];
  const waiting = [];
  lines.on("line", (line) => (waiting.length ? waiting.shift().resolve(line) : queued.push(line)));
  // After its output is read, so no line is lost to the exit.
  const exited = new Promise((resolve) => proc.once("close", (code, signal) => {
    for (const { reject } of waiting.splice(0)) reject(new Error(`the ${role} exited (${signal ?? code})`));
    resolve(signal ?? code);
  }));
  const next = () => queued.length ? Promise.resolve(queued.shift()) : new Promise((resolve, reject) => waiting.push({ resolve, reject }));
  return { proc, next, exited };
}

// Kills a writer in another process while it holds the run's fence lock,
// so the lock stays behind with no process holding it. With SIGSTOP, the
// writer stays stopped holding it, and makes no write after this one.
async function killWhileHolding(dir, runId, { signal = "SIGKILL" } = {}) {
  const lockDir = lockDirOf(dir, runId);
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const writer = spawnChild("writer", dir, runId, ["--size", String(32 << 20), "--writes", signal === "SIGSTOP" ? "1" : "100"]);
    assert.equal(await writer.next(), "ready");
    const until = Date.now() + 10_000;
    while (!existsSync(lockDir) && writer.proc.exitCode === null && Date.now() < until) await sleep(1);
    // Well into the write: past taking the lock, before releasing it.
    await sleep(20);
    writer.proc.kill(signal === "SIGKILL" ? "SIGKILL" : "SIGSTOP");
    if (signal === "SIGSTOP") {
      if (existsSync(lockDir)) return writer;
      writer.proc.kill("SIGKILL");
      await writer.exited;
      continue;
    }
    await writer.exited;
    if (existsSync(lockDir)) return writer;
  }
  throw new Error("never caught a writer holding the fence lock");
}

// The name of its holder the patched lock keeps in the lock directory,
// `holder-<pid>-<host>-<token>`.
async function holderIn(lockDir) {
  const names = (await readdir(lockDir)).filter((name) => /^holder-\d+-[0-9a-f]{16}-[0-9a-f]{32}$/.test(name));
  assert.equal(names.length, 1, `one holder named in the lock directory, found ${JSON.stringify(names)}`);
  const [, pid, host, token] = names[0].split("-");
  return { path: join(lockDir, names[0]), pid: Number(pid), host, token };
}

async function setUp() {
  const dir = await mkdtemp(join(tmpdir(), "libfx-fence-"));
  dirs.push(dir);
  const world = await openWorld(dir);
  return { dir, world, runId: await createRun(world) };
}

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("DUR-88: a writer killed while it holds the fence lock does not hold up the next one", async () => {
  const { dir, world, runId } = await setUp();
  const killed = await killWhileHolding(dir, runId);
  const holder = await holderIn(lockDirOf(dir, runId)).catch(() => null);
  if (holder) assert.equal(holder.pid, killed.proc.pid, "the lock names the killed writer");
  const started = performance.now();
  const answer = await writeAtCount(world, runId);
  const waited = performance.now() - started;
  assert.deepEqual(answer, { status: "accepted" });
  console.log(`  the next writer waited ${waited.toFixed(0)}ms`);
  assert.ok(waited < 2_000, `the next writer waited ${waited.toFixed(0)}ms for a dead writer's lock`);
});

test("a writer that is stopped, not dead, keeps the lock until it continues", async () => {
  const { dir, world, runId } = await setUp();
  const stopped = await killWhileHolding(dir, runId, { signal: "SIGSTOP" });
  try {
    let settled = false;
    const write = writeAtCount(world, runId).finally(() => { settled = true; });
    await sleep(1_500);
    assert.equal(settled, false, "a writer went through the lock of a live holder");
    stopped.proc.kill("SIGCONT");
    const started = performance.now();
    // The holder finishes its write and releases the lock.
    assert.deepEqual(await write, { status: "accepted" });
    assert.ok(performance.now() - started < 5_000);
  } finally {
    stopped.proc.kill("SIGKILL");
    await stopped.exited;
  }
});

test("a dead writer's lock stays until it goes stale when the lock does not show its holder is gone", async () => {
  const { dir, world, runId } = await setUp();
  const lockDir = lockDirOf(dir, runId);
  const cases = {
    // Its pid now names another process, as when the system reused it.
    "a pid in use": (holder) => `holder-${process.pid}-${holder.host}-${holder.token}`,
    "another host": (holder) => `holder-${holder.pid}-${"0".repeat(16)}-${holder.token}`,
    // As a writer killed before it named itself, or a world-local without
    // this change, leaves its lock.
    "no holder named": () => null,
  };
  for (const [label, rename] of Object.entries(cases)) {
    await killWhileHolding(dir, runId);
    const holder = await holderIn(lockDir);
    const renamed = rename(holder);
    if (renamed) await renameDir(holder.path, join(lockDir, renamed));
    else await rm(holder.path, { recursive: true });
    let settled = false;
    const write = writeAtCount(world, runId).finally(() => { settled = true; });
    await sleep(1_000);
    assert.equal(settled, false, `the lock was taken over with ${label}`);
    // What staleness would do, 30 s on.
    await rm(lockDir, { recursive: true, force: true });
    assert.deepEqual(await write, { status: "accepted" }, label);
  }
});

test("of writers racing to take over a dead writer's lock, one at a time checks and advances the count", async () => {
  const { dir, world, runId } = await setUp();
  for (let round = 0; round < 5; round += 1) {
    await killWhileHolding(dir, runId);
    // A killed writer's mark may count its write, so the racers start from
    // the count the World reports and race again at a refusal's count.
    let { snapshot: { seqInBand: expected } } = await world.events.list({ runId });
    for (let race = 0; ; race += 1) {
      assert.ok(race < 2, "the racers never agreed on the count");
      const racers = Array.from({ length: 4 }, () => spawnChild("racer", dir, runId, ["--expected", String(expected)]));
      for (const racer of racers) assert.equal(await racer.next(), "ready");
      for (const racer of racers) racer.proc.stdin.write("go\n");
      const answers = await Promise.all(racers.map(async (racer) => JSON.parse(await racer.next())));
      await Promise.all(racers.map((racer) => racer.exited));
      assert.deepEqual(answers.filter((answer) => answer.status === "error"), []);
      const accepted = answers.filter((answer) => answer.status === "accepted").length;
      assert.ok(accepted <= 1, `${accepted} writers at count ${expected} were accepted in round ${round}`);
      const { snapshot } = await world.events.list({ runId });
      if (accepted === 1) {
        assert.equal(snapshot.seqInBand, expected + 1);
        break;
      }
      // The killed writer's write was counted: every racer was refused at
      // the next count.
      assert.deepEqual(new Set(answers.map((answer) => answer.seqInBand)), new Set([expected + 1]));
      expected += 1;
    }
  }
});

let failed = 0;
for (const [name, fn] of tests) {
  const started = performance.now();
  try {
    let timer;
    await Promise.race([fn(), new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error("timed out after 60s")), 60_000); })]).finally(() => clearTimeout(timer));
    console.log(`ok ${name} (${(performance.now() - started).toFixed(0)}ms)`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}\n  ${error?.stack ?? error}`);
  }
}
for (const dir of dirs) await rm(dir, { recursive: true, force: true }).catch(() => {});
console.log(`${tests.length - failed}/${tests.length} fence lock tests passed (${localModule})`);
process.exit(failed ? 1 : 0);
