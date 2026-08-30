/**
 * Deterministic synthetic fixture for composed lifecycle verification.
 *
 * Run with:
 *   bun test composed-lifecycle-eval.test.ts
 */
import { spawn as nodeSpawn } from "node:child_process";
import {
  chmodSync,
  closeSync,
  constants,
  existsSync,
  fstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

export const LIFECYCLE_TASK_PROMPT = `Repair the bounded task pool in this workspace.

Its public contract is:
- no more than the configured number of jobs run concurrently;
- aborting prevents jobs that have not started from starting;
- the pool rejects with the abort reason only after asynchronous cleanup has settled for every job that did start;
- successful results preserve input order.

Inspect pool.ts and pool.test.ts. Fix the implementation, add a regression test for any missing interaction you find, and run the focused tests. Do not look for or create hidden tests.`;

const MAX_LIFECYCLE_SOURCE_BYTES = 256 * 1024;

export type FixtureImplementation = "flawed" | "correct";

export interface ProcessResult {
  stdout: string;
  stderr: string;
  code: number | null;
  signal: NodeJS.Signals | null;
  timedOut: boolean;
}

export const FLAWED_POOL_SOURCE = `export interface PoolJob<T> {
  run(signal: AbortSignal): Promise<T>;
  cleanup(): Promise<void>;
}


export async function runBounded<T>(
  jobs: readonly PoolJob<T>[],
  limit: number,
  signal: AbortSignal,
): Promise<T[]> {
  if (!Number.isInteger(limit) || limit < 1) {
    throw new RangeError("limit must be a positive integer");
  }

  const results = new Array<T>(jobs.length);
  let nextIndex = 0;

  const worker = async (): Promise<void> => {
    while (true) {
      if (signal.aborted) {
        throw signal.reason ?? new DOMException("Aborted", "AbortError");
      }
      const index = nextIndex;
      if (index >= jobs.length) return;
      nextIndex += 1;

      const job = jobs[index]!;
      try {
        results[index] = await job.run(signal);
      } finally {
        await job.cleanup();
      }
    }
  };

  await Promise.all(
    Array.from({ length: Math.min(limit, jobs.length) }, () => worker()),
  );
  return results;
}
`;

export const CORRECT_POOL_SOURCE = `export interface PoolJob<T> {
  run(signal: AbortSignal): Promise<T>;
  cleanup(): Promise<void>;
}


export async function runBounded<T>(
  jobs: readonly PoolJob<T>[],
  limit: number,
  signal: AbortSignal,
): Promise<T[]> {
  if (!Number.isInteger(limit) || limit < 1) {
    throw new RangeError("limit must be a positive integer");
  }

  const results = new Array<T>(jobs.length);
  let nextIndex = 0;

  const worker = async (): Promise<void> => {
    while (true) {
      if (signal.aborted) {
        throw signal.reason ?? new DOMException("Aborted", "AbortError");
      }
      const index = nextIndex;
      if (index >= jobs.length) return;
      nextIndex += 1;

      const job = jobs[index]!;
      try {
        results[index] = await job.run(signal);
      } finally {
        await job.cleanup();
      }
    }
  };

  const workers = Array.from(
    { length: Math.min(limit, jobs.length) },
    () => worker(),
  );
  const outcomes = await Promise.allSettled(workers);
  const failure = outcomes.find(
    (outcome): outcome is PromiseRejectedResult => outcome.status === "rejected",
  );
  if (failure) throw failure.reason;
  return results;
}
`;

export const VISIBLE_TEST_SOURCE = `import { describe, expect, test } from "bun:test";
import { runBounded, type PoolJob } from "./pool";

function waitForAbort(signal: AbortSignal): Promise<never> {
  const { promise, reject } = Promise.withResolvers<never>();
  const rejectAbort = () => reject(signal.reason);
  if (signal.aborted) {
    rejectAbort();
  } else {
    signal.addEventListener("abort", rejectAbort, { once: true });
  }
  return promise;
}

describe("runBounded", () => {
  test("limits concurrency and preserves result order", async () => {
    let active = 0;
    let maxActive = 0;
    const jobs: PoolJob<number>[] = Array.from({ length: 5 }, (_, index) => ({
      async run() {
        active += 1;
        maxActive = Math.max(maxActive, active);
        await Bun.sleep(5 + (4 - index));
        active -= 1;
        return index;
      },
      async cleanup() {},
    }));

    const results = await runBounded(jobs, 2, new AbortController().signal);

    expect(maxActive).toBe(2);
    expect(results).toEqual([0, 1, 2, 3, 4]);
  });

  test("abort prevents queued work from starting", async () => {
    const controller = new AbortController();
    const reason = new Error("stop");
    const started: number[] = [];
    const { promise: firstStarted, resolve: announceStarted } =
      Promise.withResolvers<void>();
    const jobs: PoolJob<number>[] = [0, 1].map((index) => ({
      async run(signal) {
        started.push(index);
        if (index === 0) announceStarted();
        return waitForAbort(signal);
      },
      async cleanup() {},
    }));

    const running = runBounded(jobs, 1, controller.signal);
    await firstStarted;
    controller.abort(reason);

    await expect(running).rejects.toBe(reason);
    expect(started).toEqual([0]);
  });

  test("normal completion awaits asynchronous cleanup", async () => {
    let cleanupComplete = false;
    const jobs: PoolJob<number>[] = [{
      async run() {
        return 42;
      },
      async cleanup() {
        await Bun.sleep(10);
        cleanupComplete = true;
      },
    }];

    await expect(
      runBounded(jobs, 1, new AbortController().signal),
    ).resolves.toEqual([42]);
    expect(cleanupComplete).toBe(true);
  });
});
`;

export const HELD_OUT_TEST_SOURCE = `import { expect, test } from "bun:test";
import { runBounded, type PoolJob } from "./pool";

function waitForAbort(signal: AbortSignal): Promise<never> {
  const { promise, reject } = Promise.withResolvers<never>();
  const rejectAbort = () => reject(signal.reason);
  if (signal.aborted) {
    rejectAbort();
  } else {
    signal.addEventListener("abort", rejectAbort, { once: true });
  }
  return promise;
}

test("queued abort settles cleanup for every started job before rejection", async () => {
  const controller = new AbortController();
  const reason = new Error("interrupt");
  const started: number[] = [];
  const cleanupCompleted: number[] = [];
  const { promise: bothStarted, resolve: announceBothStarted } =
    Promise.withResolvers<void>();

  const jobs: PoolJob<number>[] = [0, 1, 2].map((index) => ({
    async run(signal) {
      started.push(index);
      if (started.length === 2) announceBothStarted();
      return waitForAbort(signal);
    },
    async cleanup() {
      if (index < 2) await Bun.sleep(index === 0 ? 5 : 80);
      cleanupCompleted.push(index);
    },
  }));

  const running = runBounded(jobs, 2, controller.signal);
  await Promise.race([
    bothStarted,
    Bun.sleep(1_000).then(() => {
      throw new Error("timed out waiting for two started jobs");
    }),
  ]);
  controller.abort(reason);

  await expect(running).rejects.toBe(reason);
  expect(started.sort()).toEqual([0, 1]);
  expect(cleanupCompleted.sort()).toEqual([0, 1]);
});
`;

export function writeLifecycleFixture(
  dir: string,
  implementation: FixtureImplementation,
): void {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  writeFileSync(
    join(dir, "package.json"),
    JSON.stringify({ private: true, type: "module" }, null, 2) + "\n",
    { mode: 0o600 },
  );
  writeFileSync(
    join(dir, "tsconfig.json"),
    JSON.stringify(
      {
        compilerOptions: {
          strict: true,
          target: "ESNext",
          module: "ESNext",
          moduleResolution: "bundler",
          types: ["bun"],
          noEmit: true,
        },
      },
      null,
      2,
    ) + "\n",
    { mode: 0o600 },
  );
  writeFileSync(
    join(dir, "pool.ts"),
    implementation === "flawed" ? FLAWED_POOL_SOURCE : CORRECT_POOL_SOURCE,
    { mode: 0o600 },
  );
  writeFileSync(join(dir, "pool.test.ts"), VISIBLE_TEST_SOURCE, {
    mode: 0o600,
  });
}

export function writeHeldOutLifecycleVerifier(dir: string): string {
  const path = join(dir, "held-out-lifecycle.test.ts");
  if (existsSync(path)) {
    throw new Error(`held-out verifier already exists: ${path}`);
  }
  writeFileSync(path, HELD_OUT_TEST_SOURCE, { mode: 0o600 });
  return path;
}

export function prepareHeldOutLifecycleWorkspace(
  agentWorkspace: string,
  verifierWorkspace: string,
): string {
  rmSync(verifierWorkspace, { recursive: true, force: true });
  writeLifecycleFixture(verifierWorkspace, "flawed");
  const agentPoolPath = join(agentWorkspace, "pool.ts");
  let agentPoolFd: number;
  try {
    agentPoolFd = openSync(
      agentPoolPath,
      constants.O_RDONLY | constants.O_NOFOLLOW,
    );
  } catch (error) {
    throw new Error("agent pool.ts must be a regular file", { cause: error });
  }
  const verifierPoolPath = join(verifierWorkspace, "pool.ts");
  try {
    const sourceStat = fstatSync(agentPoolFd);
    if (!sourceStat.isFile()) {
      throw new Error("agent pool.ts must be a regular file");
    }
    if (sourceStat.size > MAX_LIFECYCLE_SOURCE_BYTES) {
      throw new Error(
        `agent pool.ts exceeds ${MAX_LIFECYCLE_SOURCE_BYTES}-byte verifier limit`,
      );
    }
    const source = readFileSync(agentPoolFd);
    if (source.byteLength > MAX_LIFECYCLE_SOURCE_BYTES) {
      throw new Error(
        `agent pool.ts exceeds ${MAX_LIFECYCLE_SOURCE_BYTES}-byte verifier limit`,
      );
    }
    writeFileSync(verifierPoolPath, source, { mode: 0o600 });
  } finally {
    closeSync(agentPoolFd);
  }
  chmodSync(verifierPoolPath, 0o600);
  return writeHeldOutLifecycleVerifier(verifierWorkspace);
}

export async function runBunTestFile(
  dir: string,
  file: string,
  timeoutMs = 30_000,
): Promise<ProcessResult> {
  return runProcess("bun", ["test", file], { cwd: dir, timeoutMs });
}

async function runProcess(
  command: string,
  args: string[],
  opts: {
    cwd: string;
    timeoutMs: number;
    env?: NodeJS.ProcessEnv;
  },
): Promise<ProcessResult> {
  const { promise, resolve } = Promise.withResolvers<ProcessResult>();
  const child = nodeSpawn(command, args, {
    cwd: opts.cwd,
    env: opts.env ?? process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stdout: Buffer[] = [];
  const stderr: Buffer[] = [];
  let timedOut = false;
  let settled = false;
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill("SIGKILL");
  }, opts.timeoutMs);
  child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
  child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));

  const finish = (code: number | null, signal: NodeJS.Signals | null) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    resolve({
      stdout: Buffer.concat(stdout).toString(),
      stderr: Buffer.concat(stderr).toString(),
      code,
      signal,
      timedOut,
    });
  };
  child.on("error", (error) => {
    stderr.push(Buffer.from(error.message));
    finish(null, null);
  });
  child.on("close", finish);
  return promise;
}
