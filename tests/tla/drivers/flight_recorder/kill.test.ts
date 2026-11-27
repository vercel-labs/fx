// Crash-recovery test for the flight recorder: spawns `flight-recorder-lab emit`
// across 20 rounds, sends SIGKILL mid-flight, reads the MAP_SHARED progress
// file and `flight-recorder-lab read` output, and checks no silent loss.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { artifacts, testEnvironment, worktree } from "../lib/context";

type ThreadSummary = {
  thread: number;
  count: number;
  highest: number | null;
  ranges: Array<[number, number]>;
};

type ReadSummary = {
  threads: ThreadSummary[];
  frames: number;
  torn: number;
  holes: number;
  missing: number;
  overflowed: number;
  dropped: number;
  gap_events: number;
  newer: number;
};

const ROUNDS = 20;
const THREADS = 4;
const EVENTS_PER_THREAD = 200_000;
const SEGMENT_BYTES = 128 * 1024;
const SYNC_MS = 10;
const PACED_EVENTS_PER_THREAD = 50_000;
const PACED_DELAY_US = 20;
const PACED_SYNC_MS = 100;
const MIN_KILL_DELAY_MS = 10;
const MAX_KILL_DELAY_MS = 80;
const MAX_U64 = 0xffff_ffff_ffff_ffffn;

const labBinary =
  process.env.FX_FLIGHT_RECORDER_LAB ?? join(worktree, "zig-out", "bin", "flight-recorder-lab");

const READY_LINE = '{"ready":true}';
// R2.3: a deadline, so a lab that never reports ready fails the test instead of hanging it.
const READY_DEADLINE_MS = 5_000;

// Resolves when the lab prints its ready line, which it does once the progress file is mapped.
async function awaitReady(proc: ReturnType<typeof Bun.spawn>): Promise<void> {
  const reader = (proc.stdout as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let seen = "";
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    void reader.cancel();
  }, READY_DEADLINE_MS);
  try {
    while (!seen.includes(READY_LINE)) {
      const { value, done } = await reader.read();
      if (done) {
        const stderr = await new Response(proc.stderr as ReadableStream<Uint8Array>).text();
        throw new Error(
          timedOut ? "lab emit did not report ready in time" : `lab emit exited before ready: ${stderr}`,
        );
      }
      seen += decoder.decode(value, { stream: true });
    }
  } finally {
    clearTimeout(timer);
  }
}

function countFoundUpTo(ranges: Array<[number, number]>, maxIndex: number): number {
  let found = 0;
  for (const [start, end] of ranges) {
    if (start > maxIndex) break;
    found += Math.min(end, maxIndex) - start + 1;
  }
  return found;
}

function readProgress(path: string, threadCount: number): Array<number | null> {
  const bytes = readFileSync(path);
  expect(bytes.byteLength).toBe(threadCount * 8);
  const progress: Array<number | null> = [];
  for (let t = 0; t < threadCount; t += 1) {
    const raw = bytes.readBigUInt64LE(t * 8);
    progress.push(raw === MAX_U64 ? null : Number(raw));
  }
  return progress;
}

test("SIGKILL during emit loses no completed events beyond missing + dropped + torn", async () => {
  if (!existsSync(labBinary)) {
    throw new Error(`missing ${labBinary}; run: zig build flight-recorder-lab`);
  }

  const runRoot = join(artifacts, `kill-${Date.now()}-${process.pid}`);
  mkdirSync(runRoot, { recursive: true });

  let killedRounds = 0;
  let minLost = Number.POSITIVE_INFINITY;
  let maxLost = 0;
  let maxTorn = 0;
  let maxMissing = 0;

  try {
    for (let round = 0; round < ROUNDS; round += 1) {
      const roundDir = join(runRoot, `round-${round}`);
      const segDir = join(roundDir, "segs");
      const progressPath = join(roundDir, "progress.bin");
      mkdirSync(segDir, { recursive: true, mode: 0o700 });

      const proc = Bun.spawn(
        [
          labBinary,
          "emit",
          segDir,
          String(THREADS),
          String(EVENTS_PER_THREAD),
          "--segment-bytes",
          String(SEGMENT_BYTES),
          "--sync-ms",
          String(SYNC_MS),
          "--progress",
          progressPath,
        ],
        {
          env: testEnvironment({}),
          stdout: "pipe",
          stderr: "pipe",
        },
      );

      // Start the kill timer only once the lab is ready, so macOS binary startup
      // never gets killed before emit begins.
      await awaitReady(proc);

      // The random delay chooses when SIGKILL lands. It does not wait for state.
      const delayMs =
        MIN_KILL_DELAY_MS + Math.floor(Math.random() * (MAX_KILL_DELAY_MS - MIN_KILL_DELAY_MS + 1));
      await Bun.sleep(delayMs);

      if (proc.exitCode === null) {
        try {
          process.kill(proc.pid, "SIGKILL");
        } catch {
          // Process exited concurrently between exitCode check and kill.
        }
      }

      const exitCode = await proc.exited;
      const killed = proc.signalCode === "SIGKILL";
      if (killed) {
        killedRounds += 1;
      } else {
        expect(exitCode).toBe(0);
      }

      const readProc = Bun.spawnSync([labBinary, "read", segDir], {
        env: testEnvironment({}),
        stdout: "pipe",
        stderr: "pipe",
      });
      if (readProc.exitCode !== 0) {
        throw new Error(`lab read failed in round ${round}: ${readProc.stderr.toString()}`);
      }

      const summary = JSON.parse(readProc.stdout.toString().trim()) as ReadSummary;
      const progress = readProgress(progressPath, THREADS);

      const byThread = new Map<number, ThreadSummary>();
      for (const entry of summary.threads) {
        byThread.set(entry.thread, entry);
      }

      let roundLost = 0;
      for (let t = 0; t < THREADS; t += 1) {
        const p = progress[t];
        const entry = byThread.get(t);
        if (entry !== undefined && entry.highest !== null) {
          expect(entry.highest).toBeLessThan(EVENTS_PER_THREAD);
          expect(entry.count).toBeLessThanOrEqual(EVENTS_PER_THREAD);
        }
        if (p === null) continue;
        expect(p).toBeLessThan(EVENTS_PER_THREAD);
        const foundUpToP = entry ? countFoundUpTo(entry.ranges, p) : 0;
        roundLost += p + 1 - foundUpToP;
      }

      expect(summary.newer).toBe(0);
      expect(summary.gap_events).toBe(0);
      expect(roundLost).toBeLessThanOrEqual(summary.missing + summary.dropped + summary.torn);
      expect(summary.torn).toBeLessThanOrEqual(THREADS);
      expect(summary.missing).toBeLessThanOrEqual(THREADS + summary.overflowed);

      minLost = Math.min(minLost, roundLost);
      maxLost = Math.max(maxLost, roundLost);
      maxTorn = Math.max(maxTorn, summary.torn);
      maxMissing = Math.max(maxMissing, summary.missing);

      rmSync(roundDir, { recursive: true, force: true });
    }
  } finally {
    rmSync(runRoot, { recursive: true, force: true });
  }

  console.log(
    `kill.test.ts (${process.platform}): rounds=${ROUNDS} killed=${killedRounds} min_lost=${minLost} max_lost=${maxLost} max_torn=${maxTorn} max_missing=${maxMissing}`,
  );
  expect(killedRounds).toBeGreaterThanOrEqual(18);
}, 120_000);

test("SIGKILL during paced 4 MiB emit finds every progressed event, zero drops, and only in-flight torn + missing", async () => {
  if (!existsSync(labBinary)) {
    throw new Error(`missing ${labBinary}; run: zig build flight-recorder-lab`);
  }

  const runRoot = join(artifacts, `kill-paced-4mib-${Date.now()}-${process.pid}`);
  mkdirSync(runRoot, { recursive: true });

  let killedRounds = 0;
  let maxTorn = 0;
  let maxMissing = 0;

  try {
    for (let round = 0; round < ROUNDS; round += 1) {
      const roundDir = join(runRoot, `round-${round}`);
      const segDir = join(roundDir, "segs");
      const progressPath = join(roundDir, "progress.bin");
      mkdirSync(segDir, { recursive: true, mode: 0o700 });

      const proc = Bun.spawn(
        [
          labBinary,
          "emit",
          segDir,
          String(THREADS),
          String(PACED_EVENTS_PER_THREAD),
          "--sync-ms",
          String(PACED_SYNC_MS),
          "--delay-us",
          String(PACED_DELAY_US),
          "--progress",
          progressPath,
        ],
        {
          env: testEnvironment({}),
          stdout: "pipe",
          stderr: "pipe",
        },
      );

      await awaitReady(proc);

      // The random delay chooses when SIGKILL lands. It does not wait for state.
      const delayMs =
        MIN_KILL_DELAY_MS + Math.floor(Math.random() * (MAX_KILL_DELAY_MS - MIN_KILL_DELAY_MS + 1));
      await Bun.sleep(delayMs);

      if (proc.exitCode === null) {
        try {
          process.kill(proc.pid, "SIGKILL");
        } catch {
          // Process exited concurrently between exitCode check and kill.
        }
      }

      const exitCode = await proc.exited;
      const killed = proc.signalCode === "SIGKILL";
      if (killed) {
        killedRounds += 1;
      } else {
        expect(exitCode).toBe(0);
      }

      const readProc = Bun.spawnSync([labBinary, "read", segDir], {
        env: testEnvironment({}),
        stdout: "pipe",
        stderr: "pipe",
      });
      if (readProc.exitCode !== 0) {
        throw new Error(`lab read failed in paced round ${round}: ${readProc.stderr.toString()}`);
      }

      const summary = JSON.parse(readProc.stdout.toString().trim()) as ReadSummary;
      const progress = readProgress(progressPath, THREADS);

      const byThread = new Map<number, ThreadSummary>();
      for (const entry of summary.threads) {
        byThread.set(entry.thread, entry);
      }

      let roundLost = 0;
      for (let t = 0; t < THREADS; t += 1) {
        const p = progress[t];
        const entry = byThread.get(t);
        if (entry !== undefined && entry.highest !== null) {
          expect(entry.highest).toBeLessThan(PACED_EVENTS_PER_THREAD);
          expect(entry.count).toBeLessThanOrEqual(PACED_EVENTS_PER_THREAD);
        }
        if (p === null) continue;
        expect(p).toBeLessThan(PACED_EVENTS_PER_THREAD);
        const foundUpToP = entry ? countFoundUpTo(entry.ranges, p) : 0;
        roundLost += p + 1 - foundUpToP;
      }

      expect(summary.newer).toBe(0);
      expect(summary.gap_events).toBe(0);
      expect(summary.dropped).toBe(0);
      expect(roundLost).toBe(0);
      expect(summary.torn + summary.missing).toBeLessThanOrEqual(THREADS);

      maxTorn = Math.max(maxTorn, summary.torn);
      maxMissing = Math.max(maxMissing, summary.missing);

      rmSync(roundDir, { recursive: true, force: true });
    }
  } finally {
    rmSync(runRoot, { recursive: true, force: true });
  }

  console.log(
    `kill.test.ts paced-4MiB (${process.platform}): rounds=${ROUNDS} killed=${killedRounds} lost=0 dropped=0 max_torn=${maxTorn} max_missing=${maxMissing}`,
  );
  expect(killedRounds).toBeGreaterThanOrEqual(18);
}, 120_000);
