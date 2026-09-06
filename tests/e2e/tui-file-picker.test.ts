import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, HAS_API_KEY, runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  heldFakeGatewayFinalText,
  isComposerLine,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const HAS_TMUX = tmuxAvailable();
const tmuxTest = test.skipIf(!HAS_TMUX);
const liveTmuxTest = test.skipIf(
  !HAS_TMUX || !HAS_API_KEY || process.env.FX_E2E_REAL_API !== "1",
);
const TIMEOUT = 60_000;
const LIFECYCLE_FILE_COUNT = 12_024;
const PART4_STRESS_CANDIDATE_COUNT = stressCandidateCount();
const PART4_STRESS = PART4_STRESS_CANDIDATE_COUNT > 0;
const LIFECYCLE_CANDIDATE_COUNT = PART4_STRESS
  ? PART4_STRESS_CANDIDATE_COUNT
  : LIFECYCLE_FILE_COUNT + 1;
const LIFECYCLE_CYCLES = boundedEnvInt(
  "FX_FILE_PICKER_LIFECYCLE_CYCLES",
  PART4_STRESS ? 100 : 25,
  PART4_STRESS ? 100 : 2,
  10_000,
);
const LIFECYCLE_MEASURED_CYCLES = boundedEnvInt(
  "FX_FILE_PICKER_MEASURED_CYCLES",
  PART4_STRESS ? 120 : 12,
  PART4_STRESS ? 100 : 2,
  1_000,
);
const LIFECYCLE_QUERY = "@stable-blackout-target";
const LIFECYCLE_RESULT = "stable-blackout-target.txt";
const LIFECYCLE_TEST_TIMEOUT = PART4_STRESS ? 600_000 : 180_000;
const FIXTURE_CLEANUP_TIMEOUT = PART4_STRESS ? 180_000 : 30_000;
const PROVISIONAL_STRESS_P95_MS = 500;
const PROVISIONAL_STRESS_MAX_MS = 1_000;

function stressCandidateCount(): number {
  const raw = process.env.FX_FILE_PICKER_PART4_CANDIDATE_COUNT;
  if (raw === undefined || raw === "0") return 0;
  const value = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(value) || value < 50_000 || value > 100_000) {
    throw new Error(
      "FX_FILE_PICKER_PART4_CANDIDATE_COUNT must be 0 or an integer in [50000, 100000]",
    );
  }
  return value;
}

function boundedEnvInt(
  name: string,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const value = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer in [${minimum}, ${maximum}]`);
  }
  return value;
}

type LatencySummary = {
  count: number;
  p50Ms: number;
  p95Ms: number;
  p99Ms: number;
  maxMs: number;
};

function summarizeLatencies(values: number[]): LatencySummary {
  const sorted = values.toSorted((a, b) => a - b);
  const percentile = (fraction: number) =>
    sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)]!;
  return {
    count: sorted.length,
    p50Ms: percentile(0.5),
    p95Ms: percentile(0.95),
    p99Ms: percentile(0.99),
    maxMs: sorted.at(-1)!,
  };
}

function linearSlope(values: number[]): number {
  if (values.length < 2) return 0;
  const xMean = (values.length - 1) / 2;
  const yMean = values.reduce((sum, value) => sum + value, 0) / values.length;
  let numerator = 0;
  let denominator = 0;
  for (const [index, value] of values.entries()) {
    const x = index - xMean;
    numerator += x * (value - yMean);
    denominator += x * x;
  }
  return denominator === 0 ? 0 : numerator / denominator;
}

function processRssKb(pid: number): number {
  const output = execFileSync("ps", ["-o", "rss=", "-p", String(pid)], {
    encoding: "utf8",
  }).trim();
  const rss = Number.parseInt(output, 10);
  if (!Number.isSafeInteger(rss) || rss <= 0) {
    throw new Error(`invalid RSS for pid ${pid}: ${JSON.stringify(output)}`);
  }
  return rss;
}

function composerTextFromPane(pane: string): string {
  return pane.split("\n")
    .filter(isComposerLine)
    .map((line) => line.replace(/^[ \t]*(?:┃|❯)[ \t]?/, ""))
    .join("")
    .trimEnd();
}

type Fixture = {
  root: string;
  home: string;
  workspace: string;
  stderrPath: string;
  tracePath: string;
  tapePath: string;
};

let session: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;
let fixture: Fixture | null = null;
let stressSamplerCleanup: (() => Promise<void>) | null = null;

afterEach(async () => {
  await stressSamplerCleanup?.();
  stressSamplerCleanup = null;
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  if (fixture) rmSync(fixture.root, { recursive: true, force: true });
  fixture = null;
}, FIXTURE_CLEANUP_TIMEOUT);

function createFixture(prefix: string): Fixture {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  const created = {
    root,
    home,
    workspace: realpathSync(workspace),
    stderrPath: join(root, "stderr.log"),
    tracePath: join(root, "trace.log"),
    tapePath: join(root, "session.fxtape"),
  };
  writeFileSync(created.stderrPath, "");
  writeFileSync(created.tracePath, "");
  fixture = created;
  return created;
}

function git(cwd: string, ...args: string[]): void {
  execFileSync("git", ["--no-optional-locks", ...args], {
    cwd,
    stdio: "pipe",
  });
}

function initGit(workspace: string): void {
  git(workspace, "init", "--quiet");
}

async function startMockFx(
  current: Fixture,
  responses: Response[] = [],
  startupWaitMs = 0,
  extraEnv: Record<string, string | undefined> = {},
): Promise<TmuxSession> {
  gateway = startFakeGateway(responses);
  session = await TmuxSession.create({
    cmd: FX_BIN,
    cwd: current.workspace,
    env: mockFxEnvironment(current, gateway, extraEnv),
    width: 112,
    height: 32,
    stderrPath: current.stderrPath,
    startupWaitMs,
  });
  await session.waitForComposer(TIMEOUT);
  return session;
}

function mockFxEnvironment(
  current: Fixture,
  activeGateway: ReturnType<typeof startFakeGateway>,
  extraEnv: Record<string, string | undefined> = {},
): Record<string, string | undefined> {
  return {
    HOME: current.home,
    AI_GATEWAY_API_KEY: "fake-file-picker-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: activeGateway.baseUrl,
    FX_GATEWAY_CHAT_URL: activeGateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    FX_TRACE_LOG: current.tracePath,
    FX_TRACE_SCOPES: "input,core,prompt,gateway,resize",
    FX_RECORD: current.tapePath,
    FX_RECORD_INPUT: "1",
    ...extraEnv,
  };
}

async function clearComposer(active: TmuxSession): Promise<void> {
  await active.sendKeys("C-u");
}

async function composerPlainText(active: TmuxSession): Promise<string> {
  return (await active.capturePaneGrid())
    .filter(isComposerLine)
    .map((line) => line.replace(/^[ \t]*(?:┃|❯)[ \t]?/, ""))
    .join("")
    .trimEnd();
}

async function waitForGatewayRequestCount(expected: number): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < TIMEOUT) {
    if ((gateway?.requests.length ?? 0) >= expected) return;
    await Bun.sleep(25);
  }
  throw new Error(
    `Timed out waiting for ${expected} gateway request(s); received ${
      gateway?.requests.length ?? 0
    }`,
  );
}

async function waitForFileText(
  path: string,
  needle: string,
  occurrences = 1,
): Promise<string> {
  const started = Date.now();
  let last = "";
  while (Date.now() - started < TIMEOUT) {
    last = existsSync(path) ? readFileSync(path, "utf8") : "";
    if (last.split(needle).length - 1 >= occurrences) return last;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${JSON.stringify(needle)} in ${path}\n${last}`);
}

async function waitForFileSlice(
  path: string,
  offset: number,
  needles: string[],
): Promise<string> {
  const started = Date.now();
  let last = "";
  while (Date.now() - started < TIMEOUT) {
    last = existsSync(path) ? readFileSync(path, "utf8").slice(offset) : "";
    if (needles.some((needle) => last.includes(needle))) return last;
    await Bun.sleep(25);
  }
  throw new Error(
    `Timed out waiting for ${needles.map((needle) => JSON.stringify(needle)).join(" or ")} in ${path}\n${last}`,
  );
}

async function waitForReadyAndAdoptedFileIndex(
  path: string,
  count: number,
  minimumGeneration = 1,
): Promise<number> {
  const started = Date.now();
  let last = "";
  while (Date.now() - started < TIMEOUT) {
    last = existsSync(path) ? readFileSync(path, "utf8") : "";
    for (const match of last.matchAll(
      /file index generation ready generation=(\d+) count=(\d+)/g,
    )) {
      if (Number.parseInt(match[2]!, 10) !== count) continue;
      const generation = Number.parseInt(match[1]!, 10);
      if (generation < minimumGeneration) continue;
      if (last.includes(
        `file index generation adopted generation=${generation} count=${count}`,
      )) return generation;
    }
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for a ready and adopted ${count}-file index\n${last}`);
}

async function waitForFile(path: string): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < TIMEOUT) {
    if (existsSync(path)) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${path}`);
}

function traceGenerationNumbers(trace: string, fact: string): number[] {
  return trace.split("\n").flatMap((line) => {
    if (!line.includes(fact)) return [];
    const match = line.match(/generation=(\d+)/);
    return match ? [Number.parseInt(match[1]!, 10)] : [];
  });
}

function nextFileIndexAdoption(path: string): string {
  const trace = existsSync(path) ? readFileSync(path, "utf8") : "";
  const generation = Math.max(
    0,
    ...traceGenerationNumbers(trace, "file index generation started"),
  ) + 1;
  return `file index generation adopted generation=${generation}`;
}

function traceThreadIds(trace: string, pattern: RegExp): number[] {
  return [...trace.matchAll(pattern)].map((match) =>
    Number.parseInt(match[1]!, 10)
  );
}

function expectFileDiscoveryOffMainThread(trace: string): void {
  const callerThreads = traceThreadIds(
    trace,
    /file index generation started generation=\d+ caller_thread=(\d+)/g,
  );
  const loaderThreads = new Set(
    traceThreadIds(
      trace,
      /file index loader entered generation=\d+ worker_thread=(\d+)/g,
    ),
  );
  const discoveryThreads = traceThreadIds(
    trace,
    /workspace file discovery process spawning thread=(\d+)/g,
  );
  const mainThreads = new Set(callerThreads);

  expect(mainThreads.size).toBe(1);
  expect(loaderThreads.size).toBeGreaterThan(0);
  expect(discoveryThreads.length).toBeGreaterThan(0);
  for (const thread of discoveryThreads) {
    expect(loaderThreads.has(thread)).toBe(true);
    expect(mainThreads.has(thread)).toBe(false);
  }
}

function replacementIncomplete(trace: string): boolean {
  const started = traceGenerationNumbers(trace, "file index generation started");
  const finished = new Set([
    ...traceGenerationNumbers(trace, "file index generation ready"),
    ...traceGenerationNumbers(trace, "file index generation failed"),
    ...traceGenerationNumbers(trace, "file index generation canceled"),
  ]);
  return started.some((generation) => generation > 1 && !finished.has(generation));
}

function replacementSettled(trace: string): boolean {
  const started = traceGenerationNumbers(trace, "file index generation started");
  if (started.length < 2) return false;
  const finished = new Set([
    ...traceGenerationNumbers(trace, "file index generation ready"),
    ...traceGenerationNumbers(trace, "file index generation failed"),
    ...traceGenerationNumbers(trace, "file index generation canceled"),
  ]);
  const joined = new Set(
    traceGenerationNumbers(trace, "file index generation joined"),
  );
  return started.every((generation) =>
    finished.has(generation) && joined.has(generation)
  );
}

async function waitForReplacementSettled(path: string): Promise<string> {
  const started = Date.now();
  let last = "";
  while (Date.now() - started < TIMEOUT) {
    last = readFileSync(path, "utf8");
    if (replacementSettled(last)) return last;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for file-index generations to settle\n${last}`);
}

function expectCleanRuntime(current: Fixture, active: TmuxSession): void {
  expect(active.isPaneAlive()).toBe(true);
  expect(readFileSync(current.stderrPath, "utf8")).toBe("");
}

async function replayTape(current: Fixture): Promise<void> {
  await session?.kill();
  session = null;
  const replay = await runFx(["replay", current.tapePath], {
    cwd: current.workspace,
    env: { HOME: current.home },
    timeoutMs: TIMEOUT,
  });
  expect(replay.code).toBe(0);
  expect(replay.stderr).toBe("");
}

describe("@ file picker", () => {
  tmuxTest(
    "opens and selects a file while a turn is in flight",
    async () => {
      const current = createFixture("fx-file-picker-in-flight-");
      initGit(current.workspace);
      writeFileSync(join(current.workspace, "in-flight-context.txt"), "context");
      git(current.workspace, "add", "in-flight-context.txt");
      const held = heldFakeGatewayFinalText();

      try {
        const active = await startMockFx(current, [held.response], 1_000);
        await active.sendText("Keep this turn active.");
        await waitForGatewayRequestCount(1);

        await active.sendLiteral("@in-flight");
        await active.waitForPane(
          (pane) => pane.includes("in-flight-context.txt"),
          5_000,
        );
        await active.sendKeys("Enter");
        await active.waitForPane(
          (pane) => composerTextFromPane(pane).includes("@in-flight-context.txt"),
          5_000,
        );

        expect(gateway?.requests).toHaveLength(1);
        held.release("IN_FLIGHT_FILE_PICKER_COMPLETE");
        await active.waitForText("IN_FLIGHT_FILE_PICKER_COMPLETE", TIMEOUT);
        expectCleanRuntime(current, active);
        await clearComposer(active);
        await active.sendText("/quit");
        expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      } finally {
        held.dispose();
      }
    },
    TIMEOUT,
  );

  tmuxTest(
    "keeps the completed result visible through rapid large-index refreshes",
    async () => {
      const current = createFixture("fx-file-picker-stable-refresh-");
      const artifactDir = process.env.FX_FILE_PICKER_LIFECYCLE_ARTIFACT_DIR;
      const fixtureStartedAt = performance.now();
      let fixtureFileCount = 0;
      let fixtureFileBytes = 0;
      let fixturePathBytes = 0;
      let fixtureLargestFileBytes = 0;
      let fixtureLongestPathBytes = 0;
      const writeFixtureFile = (relativePath: string, contents: string): void => {
        writeFileSync(join(current.workspace, relativePath), contents);
        fixtureFileCount += 1;
        fixtureFileBytes += Buffer.byteLength(contents);
        fixturePathBytes += Buffer.byteLength(relativePath);
        fixtureLargestFileBytes = Math.max(
          fixtureLargestFileBytes,
          Buffer.byteLength(contents),
        );
        fixtureLongestPathBytes = Math.max(
          fixtureLongestPathBytes,
          Buffer.byteLength(relativePath),
        );
      };
      initGit(current.workspace);
      const bulk = join(current.workspace, "bulk");
      mkdirSync(bulk);
      const bulkFileCount = PART4_STRESS
        ? LIFECYCLE_CANDIDATE_COUNT - 21
        : LIFECYCLE_FILE_COUNT - 1;
      const stressSentinels = [
        "bulk/adversarial-head-sentinel.txt",
        "bulk/adversarial-middle-sentinel-界.md",
        "bulk/adversarial-tail-sentinel-with-a-long-distinguishing-name.zig",
      ] as const;
      for (let index = 0; index < bulkFileCount; index += 1) {
        const ordinal = index.toString().padStart(5, "0");
        const relativePath = PART4_STRESS && index === 0
          ? stressSentinels[0]
          : PART4_STRESS && index === Math.floor(bulkFileCount / 2)
          ? stressSentinels[1]
          : PART4_STRESS && index === bulkFileCount - 1
          ? stressSentinels[2]
          : `bulk/tracked-${ordinal}-${
            [
              "short.txt",
              "component_with_underscores.ts",
              "component-with-a-long-descriptive-name.zig",
              "Ärger-unicode.md",
            ][index % 4]
          }`;
        const contents = index % 7 === 0
          ? `line one ${index}\nline two with 界 and Cafe\u{0301}\n`
          : index % 5 === 0
          ? `tool-like payload ${index}: \u001b[31mdata\u001b[0m`
          : `fixture-${index}`;
        writeFixtureFile(relativePath, contents);
      }
      writeFixtureFile(LIFECYCLE_RESULT, "stable");
      if (PART4_STRESS) {
        writeFixtureFile(
          ".gitignore",
          "ignored-profile.txt\nignored-profile-dir/\n",
        );
        mkdirSync(join(current.workspace, ".hidden"));
        mkdirSync(join(current.workspace, "duplicate-a"));
        mkdirSync(join(current.workspace, "duplicate-b"));
        mkdirSync(join(current.workspace, "nested", "deep"), { recursive: true });
        mkdirSync(join(current.workspace, "flip-kind-dir"));
        mkdirSync(join(current.workspace, "ignored-profile-dir"));
        mkdirSync(join(current.workspace, "empty-profile-dir"));
        writeFixtureFile("tracked-profile.txt", "tracked");
        writeFixtureFile("untracked-profile.txt", "untracked");
        writeFixtureFile(".hidden/tracked.txt", "tracked");
        writeFixtureFile(
          ".hidden/untracked.txt",
          "untracked",
        );
        writeFixtureFile("Ärger-profile.txt", "unicode");
        writeFixtureFile(
          "duplicate-a/shared-profile.txt",
          "first",
        );
        writeFixtureFile(
          "duplicate-b/shared-profile.txt",
          "second",
        );
        writeFixtureFile("nested/deep/item.txt", "nested");
        writeFixtureFile("stale-kind-file.txt", "stale");
        writeFixtureFile("flip-kind-file.txt", "file");
        writeFixtureFile("flip-kind-dir/item.txt", "directory");
        writeFixtureFile("ignored-profile.txt", "ignored");
        writeFixtureFile(
          "ignored-profile-dir/item.txt",
          "ignored",
        );
        writeFixtureFile(
          ".git/internal-profile.txt",
          "internal",
        );
        git(
          current.workspace,
          "add",
          ".gitignore",
          "bulk",
          LIFECYCLE_RESULT,
          "tracked-profile.txt",
          ".hidden/tracked.txt",
          "Ärger-profile.txt",
          "duplicate-a/shared-profile.txt",
          "duplicate-b/shared-profile.txt",
          "nested/deep/item.txt",
          "stale-kind-file.txt",
          "flip-kind-file.txt",
          "flip-kind-dir/item.txt",
        );
      } else {
        git(current.workspace, "add", ".");
      }
      const fixtureConstructionMs = performance.now() - fixtureStartedAt;

      const active = await startMockFx(
        current,
        PART4_STRESS ? [fakeGatewayFinalText("PART4_PROFILE_PROMPT_OK")] : [],
      );
      await active.sendLiteral(LIFECYCLE_QUERY);
      await active.waitForText(LIFECYCLE_RESULT, TIMEOUT);
      const initialGeneration = await waitForReadyAndAdoptedFileIndex(
        current.tracePath,
        LIFECYCLE_CANDIDATE_COUNT,
      );
      const firstReplacementGeneration = initialGeneration + 1;

      const targetPid = active.processPid();
      const workloadStartedAt = performance.now();
      const rssStartedKb = processRssKb(targetPid);
      type RssSample = {
        elapsedMs: number;
        rssKb: number;
        source: "sampler" | "cycle";
        cycle?: number;
      };
      const rssSamples: RssSample[] = [];
      let rssSampling = true;
      let frameSampling = false;
      let frameSampler: Promise<void> | null = null;
      const rssSampler = (async () => {
        while (rssSampling) {
          rssSamples.push({
            elapsedMs: performance.now() - workloadStartedAt,
            rssKb: processRssKb(targetPid),
            source: "sampler",
          });
          await Bun.sleep(25);
        }
      })();
      let samplersStopped = false;
      const stopSamplers = async (suppressErrors: boolean): Promise<void> => {
        if (samplersStopped) return;
        rssSampling = false;
        frameSampling = false;
        const settled = await Promise.allSettled([
          rssSampler,
          ...(frameSampler ? [frameSampler] : []),
        ]);
        samplersStopped = true;
        if (suppressErrors) return;
        for (const result of settled) {
          if (result.status === "rejected") throw result.reason;
        }
      };
      stressSamplerCleanup = () => stopSamplers(true);
      const profileReadyPath = process.env.FX_FILE_PICKER_PROFILE_READY;
      const profileGoPath = process.env.FX_FILE_PICKER_PROFILE_GO;
      if (profileReadyPath && profileGoPath) {
        writeFileSync(profileReadyPath, `${targetPid}\n`);
        await waitForFile(profileGoPath);
      }

      type Snapshot = {
        pane: string;
        trace: string;
        cols: number;
        rows: number;
        stableSize: boolean;
        resizeStormActive: boolean;
      };
      const snapshots: Snapshot[] = [];
      let resizeStormActive = false;
      const captureSnapshot = async (): Promise<void> => {
        const beforeSize = active.paneSize();
        const pane = await active.capturePane();
        const afterSize = active.paneSize();
        snapshots.push({
          pane,
          trace: readFileSync(current.tracePath, "utf8"),
          cols: afterSize.cols,
          rows: afterSize.rows,
          stableSize: beforeSize.cols === afterSize.cols &&
            beforeSize.rows === afterSize.rows,
          resizeStormActive,
        });
      };
      frameSampling = true;
      frameSampler = (async () => {
        while (frameSampling) {
          await captureSnapshot();
          await Bun.sleep(5);
        }
      })();

      const injectCycle = () => {
        active.sendKeysImmediate(["Escape", "C-u"]);
        active.sendLiteralImmediate(`${LIFECYCLE_QUERY.slice(0, -1)}`);
        active.sendLiteralImmediate(LIFECYCLE_QUERY.slice(-1));
      };

      injectCycle();
      await waitForFileText(
        current.tracePath,
        `file index generation started generation=${firstReplacementGeneration}`,
      );
      let resizeTransitions = 0;
      resizeStormActive = true;
      for (let cycle = 1; cycle < LIFECYCLE_CYCLES; cycle += 1) {
        injectCycle();
        if (cycle % 4 === 0) {
          const [cols, rows] = cycle % 8 === 0 ? [32, 8] : [200, 70];
          await active.resizeWindow(cols, rows, 0);
          if (rows < 12) {
            await active.waitForPane(
              (pane) => composerTextFromPane(pane) === LIFECYCLE_QUERY,
              TIMEOUT,
            );
            await captureSnapshot();
          }
          active.sendKeysImmediate(["Down", "Down", "Up", "Up"]);
          resizeTransitions += 1;
          if (rows < 12) {
            await active.waitForPane(
              (pane) => composerTextFromPane(pane) === LIFECYCLE_QUERY,
              TIMEOUT,
            );
          }
          await Bun.sleep(5);
        }
        if (cycle % 5 === 0) await Bun.sleep(0);
      }
      if (resizeTransitions > 0) await active.resizeWindow(112, 32);

      await waitForFileText(current.tracePath, "file index refresh coalesced");
      await active.waitForPane(
        (pane) => pane.includes(LIFECYCLE_QUERY) && pane.includes(LIFECYCLE_RESULT),
        TIMEOUT,
      );
      resizeStormActive = false;
      const replacementGeneration = await waitForReadyAndAdoptedFileIndex(
        current.tracePath,
        LIFECYCLE_CANDIDATE_COUNT,
        firstReplacementGeneration,
      );

      const interactionLatenciesMs: number[] = [];
      for (let cycle = 0; cycle < LIFECYCLE_MEASURED_CYCLES; cycle += 1) {
        const query = cycle % 2 === 0
          ? LIFECYCLE_QUERY.slice(0, -1)
          : LIFECYCLE_QUERY;
        const cycleStartedAt = performance.now();
        active.sendKeysImmediate(["Escape", "C-u"]);
        active.sendLiteralImmediate(query);
        await active.waitForPane(
          (pane) =>
            composerTextFromPane(pane) === query && pane.includes(LIFECYCLE_RESULT),
          TIMEOUT,
        );
        interactionLatenciesMs.push(performance.now() - cycleStartedAt);
        rssSamples.push({
          elapsedMs: performance.now() - workloadStartedAt,
          rssKb: processRssKb(targetPid),
          source: "cycle",
          cycle,
        });
      }
      await waitForReplacementSettled(current.tracePath);
      await Bun.sleep(250);
      const rssQuiescentKb = processRssKb(targetPid);
      await stopSamplers(false);
      stressSamplerCleanup = null;
      const rssEndedKb = processRssKb(targetPid);
      const rssPeakKb = Math.max(
        rssStartedKb,
        rssEndedKb,
        ...rssSamples.map((sample) => sample.rssKb),
      );
      const latency = summarizeLatencies(interactionLatenciesMs);
      const workloadRuntimeMs = performance.now() - workloadStartedAt;
      const cycleRssSamples = rssSamples.filter((sample) => sample.source === "cycle");
      const steadyRssStartKb = cycleRssSamples[0]!.rssKb;
      const steadyRssEndKb = cycleRssSamples.at(-1)!.rssKb;
      const steadyRssGrowthKb = steadyRssEndKb - steadyRssStartKb;
      const steadyRssSlopeKbPerCycle = linearSlope(
        cycleRssSamples.map((sample) => sample.rssKb),
      );
      if (artifactDir) {
        mkdirSync(artifactDir, { recursive: true });
        writeFileSync(
          join(artifactDir, "live-metrics.json"),
          JSON.stringify(
            {
              candidateCount: LIFECYCLE_CANDIDATE_COUNT,
              rapidCycles: LIFECYCLE_CYCLES,
              measuredCycles: LIFECYCLE_MEASURED_CYCLES,
              resizeTransitions,
              workloadRuntimeMs,
              fixture: {
                constructionMs: fixtureConstructionMs,
                filesCreated: fixtureFileCount,
                fileBytes: fixtureFileBytes,
                pathBytes: fixturePathBytes,
                largestFileBytes: fixtureLargestFileBytes,
                longestPathBytes: fixtureLongestPathBytes,
                sentinels: PART4_STRESS ? stressSentinels : [],
              },
              latency,
              rssKb: {
                start: rssStartedKb,
                end: rssEndedKb,
                peak: rssPeakKb,
                quiescent: rssQuiescentKb,
                growth: rssEndedKb - rssStartedKb,
                steadyStart: steadyRssStartKb,
                steadyEnd: steadyRssEndKb,
                steadyGrowth: steadyRssGrowthKb,
                steadySlopePerCycle: steadyRssSlopeKbPerCycle,
              },
              perCycleRss: cycleRssSamples,
            },
            null,
            2,
          ),
        );
      }
      expect(steadyRssGrowthKb).toBeLessThan(4 * 1024);
      expect(rssPeakKb - rssStartedKb).toBeLessThan(32 * 1024);
      if (PART4_STRESS) {
        expect(latency.count).toBeGreaterThanOrEqual(100);
        expect(latency.p95Ms).toBeLessThan(PROVISIONAL_STRESS_P95_MS);
        expect(latency.maxMs).toBeLessThan(PROVISIONAL_STRESS_MAX_MS);
      }

      const activeQueryFrames = snapshots.filter((snapshot) =>
        snapshot.pane.split("\n").filter(isComposerLine).join("").includes(
          LIFECYCLE_QUERY,
        )
      );
      const steadyActiveQueryFrames = activeQueryFrames.filter(
        (snapshot) => !snapshot.resizeStormActive,
      );
      const constrainedActiveQueryFrames = activeQueryFrames.filter(
        (snapshot) =>
          snapshot.resizeStormActive && snapshot.stableSize && snapshot.rows < 12,
      );
      expect(steadyActiveQueryFrames.length).toBeGreaterThan(0);
      expect(constrainedActiveQueryFrames.length).toBeGreaterThan(0);
      for (const snapshot of steadyActiveQueryFrames) {
        expect(snapshot.pane).toContain(LIFECYCLE_RESULT);
      }
      for (const snapshot of activeQueryFrames) {
        expect(snapshot.pane).not.toContain("indexing files...");
      }
      expect(
        activeQueryFrames.some((snapshot) => replacementIncomplete(snapshot.trace)),
      ).toBe(true);

      let acceptedFilePrompt = "";
      let acceptedDirectoryPrompt = "";
      let normalProofFrame = "";
      let escapedProofFrame = "";
      if (PART4_STRESS) {
        await active.sendKeys("Enter");
        await active.waitForText(`@${LIFECYCLE_RESULT}`, TIMEOUT);
        acceptedFilePrompt = await composerPlainText(active);
        expect(acceptedFilePrompt).toBe(`@${LIFECYCLE_RESULT}`);

        await clearComposer(active);
        await active.sendLiteral("@bt");
        await active.waitForText("bulk/tracked-", TIMEOUT);

        for (const sentinel of stressSentinels) {
          await clearComposer(active);
          const basename = sentinel.slice(sentinel.lastIndexOf("/") + 1);
          await active.sendLiteral(`@${basename.replace(/\.[^.]+$/, "")}`);
          await active.waitForText(sentinel, TIMEOUT);
        }

        await clearComposer(active);
        await active.sendLiteral("@ärger");
        await active.waitForText("Ärger-profile.txt", TIMEOUT);
        escapedProofFrame = await active.capturePaneEscapes();

        await clearComposer(active);
        await active.sendLiteral("@.hidden/untracked");
        await active.waitForText(".hidden/untracked.txt", TIMEOUT);

        await clearComposer(active);
        await active.sendLiteral("Review @nested/deep");
        await active.waitForText("nested/deep/", TIMEOUT);
        await active.sendKeys("Tab");
        acceptedDirectoryPrompt = await composerPlainText(active);
        expect(acceptedDirectoryPrompt).toBe("Review @nested/deep/");
        normalProofFrame = await active.capturePane();

        await clearComposer(active);
        await active.sendLiteral("@shared-profile");
        await active.waitForText("duplicate-a/shared-profile.txt", TIMEOUT);
        await active.waitForText("duplicate-b/shared-profile.txt", TIMEOUT);
        await active.sendKeys("Down");
        await active.sendKeys("Down");
        await active.sendKeys("Up");
        await active.sendKeys("Down");
        await active.sendKeys("Enter");
        await waitForFileText(
          current.tracePath,
          "file picker Enter consumed selected=true",
          2,
        );
        expect([
          "@duplicate-a/shared-profile.txt",
          "@duplicate-b/shared-profile.txt",
        ]).toContain(await composerPlainText(active));

        await clearComposer(active);
        await active.sendLiteral("@stale-kind-file");
        await active.waitForText("stale-kind-file.txt", TIMEOUT);
        const staleFileTraceOffset = readFileSync(current.tracePath, "utf8").length;
        rmSync(join(current.workspace, "stale-kind-file.txt"));
        mkdirSync(join(current.workspace, "stale-kind-file.txt"));
        await clearComposer(active);
        await active.waitForComposer(TIMEOUT);
        await active.sendLiteral("@stale-kind-file");
        await waitForFileSlice(current.tracePath, staleFileTraceOffset, [
          "file index generation adopted",
        ]);
        await active.waitForText("stale-kind-file.txt/", TIMEOUT);
        const refreshedFileTraceOffset = readFileSync(current.tracePath, "utf8").length;
        await active.sendKeys("Enter");
        await waitForFileSlice(current.tracePath, refreshedFileTraceOffset, [
          "file picker Enter consumed selected=true",
        ]);
        expect(await composerPlainText(active)).toContain("@stale-kind-file.txt/");

        await clearComposer(active);
        await active.sendLiteral("@flip-kind-dir");
        await active.waitForText("flip-kind-dir/", TIMEOUT);
        const staleDirectoryTraceOffset = readFileSync(current.tracePath, "utf8").length;
        rmSync(join(current.workspace, "flip-kind-dir"), {
          recursive: true,
          force: true,
        });
        writeFileSync(join(current.workspace, "flip-kind-dir"), "now a file");
        await clearComposer(active);
        await active.waitForComposer(TIMEOUT);
        await active.sendLiteral("@flip-kind-dir");
        await waitForFileSlice(current.tracePath, staleDirectoryTraceOffset, [
          "file index generation adopted",
        ]);
        const refreshedDirectoryTraceOffset = readFileSync(
          current.tracePath,
          "utf8",
        ).length;
        await active.sendKeys("Enter");
        await waitForFileSlice(current.tracePath, refreshedDirectoryTraceOffset, [
          "file picker Enter consumed selected=true",
        ]);
        expect(await composerPlainText(active)).toBe("@flip-kind-dir");

        await clearComposer(active);
        await active.sendLiteral("Review @nested/deep");
        await active.waitForText("nested/deep/", TIMEOUT);
        await active.sendKeys("Tab");
        await active.sendLiteral(" inspect");
        await active.sendKeys("Enter");
        await active.waitForText("PART4_PROFILE_PROMPT_OK", TIMEOUT);
        expect(gateway?.requests).toHaveLength(1);
        expect(gateway?.requests[0]?.body).toContain(
          "Review @nested/deep/ inspect",
        );
      }

      await active.sendKeys("Escape C-u");
      const terminalRecording = await active.captureFullScrollback();
      const terminalRecordingEscapes = await active.captureFullScrollbackEscapes();
      await active.sendText("/quit");
      expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(active.isAlive()).toBe(false);
      expect(() => process.kill(targetPid, 0)).toThrow();
      expect(readFileSync(current.stderrPath, "utf8")).toBe("");

      const finalTrace = await waitForFileText(
        current.tracePath,
        "file index shutdown complete",
      );
      const replacementStart = finalTrace.indexOf(
        `file index generation started generation=${replacementGeneration}`,
      );
      const replacementReady = finalTrace.indexOf(
        `file index generation ready generation=${replacementGeneration}`,
      );
      const replacementAdopted = finalTrace.indexOf(
        `file index generation adopted generation=${replacementGeneration}`,
      );
      expect(replacementStart).toBeGreaterThanOrEqual(0);
      expect(replacementReady).toBeGreaterThan(replacementStart);
      expect(replacementAdopted).toBeGreaterThan(replacementReady);
      expect(finalTrace).toContain("file index refresh coalesced");
      expect(finalTrace).toContain("file index shutdown requested");
      expectFileDiscoveryOffMainThread(finalTrace);

      if (artifactDir) {
        mkdirSync(artifactDir, { recursive: true });
        writeFileSync(join(artifactDir, "trace.log"), finalTrace);
        writeFileSync(
          join(artifactDir, "frames.json"),
          JSON.stringify(snapshots, null, 2),
        );
        writeFileSync(
          join(artifactDir, "metadata.json"),
          JSON.stringify(
            {
              candidateCount: LIFECYCLE_CANDIDATE_COUNT,
              rapidCycles: LIFECYCLE_CYCLES,
              measuredCycles: LIFECYCLE_MEASURED_CYCLES,
              resizeTransitions,
              targetPid,
              activeQueryFrames: activeQueryFrames.length,
              steadyActiveQueryFrames: steadyActiveQueryFrames.length,
              constrainedActiveQueryFrames: constrainedActiveQueryFrames.length,
              incompleteActiveQueryFrames: activeQueryFrames.filter((snapshot) =>
                replacementIncomplete(snapshot.trace)
              ).length,
              workloadRuntimeMs,
              fixture: {
                constructionMs: fixtureConstructionMs,
                filesCreated: fixtureFileCount,
                fileBytes: fixtureFileBytes,
                pathBytes: fixturePathBytes,
                largestFileBytes: fixtureLargestFileBytes,
                longestPathBytes: fixtureLongestPathBytes,
                sentinels: PART4_STRESS ? stressSentinels : [],
              },
              interactionLatency: latency,
              rss: {
                startKb: rssStartedKb,
                endKb: rssEndedKb,
                peakKb: rssPeakKb,
                quiescentKb: rssQuiescentKb,
                growthKb: rssEndedKb - rssStartedKb,
                steadyStartKb: steadyRssStartKb,
                steadyEndKb: steadyRssEndKb,
                steadyGrowthKb: steadyRssGrowthKb,
                steadySlopeKbPerCycle: steadyRssSlopeKbPerCycle,
                samples: rssSamples.length,
              },
            },
            null,
            2,
          ),
        );
        writeFileSync(join(artifactDir, "normal-frame.txt"), normalProofFrame);
        writeFileSync(join(artifactDir, "escaped-frame.txt"), escapedProofFrame);
        writeFileSync(
          join(artifactDir, "accepted-prompts.json"),
          JSON.stringify(
            {
              file: acceptedFilePrompt,
              directory: acceptedDirectoryPrompt,
              gatewayRequestBody: gateway?.requests[0]?.body ?? null,
            },
            null,
            2,
          ),
        );
        writeFileSync(
          join(artifactDir, "stderr.log"),
          readFileSync(current.stderrPath, "utf8"),
        );
        writeFileSync(
          join(artifactDir, "metrics.json"),
          JSON.stringify(
            {
              workload: {
                candidateCount: LIFECYCLE_CANDIDATE_COUNT,
                rapidCycles: LIFECYCLE_CYCLES,
                measuredCycles: LIFECYCLE_MEASURED_CYCLES,
                resizeTransitions,
                runtimeMs: workloadRuntimeMs,
                fixtureConstructionMs,
                filesCreated: fixtureFileCount,
                fileBytes: fixtureFileBytes,
                pathBytes: fixturePathBytes,
                largestFileBytes: fixtureLargestFileBytes,
                longestPathBytes: fixtureLongestPathBytes,
                sentinels: PART4_STRESS ? stressSentinels : [],
              },
              interactionLatencyMs: {
                summary: latency,
                samples: interactionLatenciesMs,
              },
              rssKb: {
                start: rssStartedKb,
                end: rssEndedKb,
                peak: rssPeakKb,
                quiescent: rssQuiescentKb,
                growth: rssEndedKb - rssStartedKb,
                steadyStart: steadyRssStartKb,
                steadyEnd: steadyRssEndKb,
                steadyGrowth: steadyRssGrowthKb,
                steadySlopePerCycle: steadyRssSlopeKbPerCycle,
                perCycle: cycleRssSamples,
              },
            },
            null,
            2,
          ),
        );
        writeFileSync(
          join(artifactDir, "rss-samples.jsonl"),
          rssSamples.map((sample) => JSON.stringify(sample)).join("\n") + "\n",
        );
        writeFileSync(join(artifactDir, "terminal.txt"), terminalRecording);
        writeFileSync(
          join(artifactDir, "terminal-escapes.txt"),
          terminalRecordingEscapes,
        );
        copyFileSync(current.tapePath, join(artifactDir, "session.fxtape"));
      }

      await active.kill();
      session = null;
    },
    LIFECYCLE_TEST_TIMEOUT,
  );

  tmuxTest(
    "refreshes a completed startup index on the first picker episode",
    async () => {
      const current = createFixture("fx-file-picker-first-episode-refresh-");
      initGit(current.workspace);
      writeFileSync(join(current.workspace, "startup-visible.txt"), "startup");
      git(current.workspace, "add", "startup-visible.txt");

      const active = await startMockFx(current, [], 1000);
      const initialGeneration = await waitForReadyAndAdoptedFileIndex(
        current.tracePath,
        1,
      );

      const latePath = "first-episode-late-file.txt";
      writeFileSync(join(current.workspace, latePath), "created after adoption");
      await active.sendLiteral("@first-episode-late");
      await active.waitForText(latePath, 5_000);

      const trace = readFileSync(current.tracePath, "utf8");
      expect(trace).toContain(
        `file index generation started generation=${initialGeneration + 1}`,
      );
      expectCleanRuntime(current, active);
    },
    TIMEOUT,
  );

  tmuxTest(
    "submits an unmatched file mention without requiring dismissal",
    async () => {
      const current = createFixture("fx-file-picker-unmatched-submit-");
      const active = await startMockFx(current, [
        fakeGatewayFinalText("UNMATCHED_FILE_PROMPT_OK"),
      ]);

      await active.sendLiteral("review @definitely-not-present");
      await active.waitForText("no matching files", TIMEOUT);
      await active.sendKeys("Enter");
      await active.waitForText("UNMATCHED_FILE_PROMPT_OK", TIMEOUT);

      expect(gateway?.requests).toHaveLength(1);
      expect(gateway?.requests[0]?.body).toContain(
        "review @definitely-not-present",
      );
      expect(readFileSync(current.tracePath, "utf8")).not.toContain(
        "file picker Enter consumed",
      );
      expectCleanRuntime(current, active);
      await replayTape(current);
    },
    TIMEOUT,
  );

  tmuxTest(
    "opens after quotes and parentheses and submits the selected path",
    async () => {
      const current = createFixture("fx-file-picker-boundaries-");
      initGit(current.workspace);
      mkdirSync(join(current.workspace, "src"));
      writeFileSync(join(current.workspace, "src", "main.zig"), "fixture");
      git(current.workspace, "add", "src/main.zig");

      const active = await startMockFx(
        current,
        [fakeGatewayFinalText("FILE_BOUNDARY_PROMPT_OK")],
        1000,
      );
      await active.sendLiteral('Compare "@src/main');
      await active.waitForText("src/main.zig", TIMEOUT);

      await clearComposer(active);
      await active.sendLiteral("Review (@src/main");
      await active.waitForText("src/main.zig", TIMEOUT);
      await active.sendKeys("Enter");
      await active.sendLiteral("now)");
      await active.sendKeys("Enter");
      await active.waitForText("FILE_BOUNDARY_PROMPT_OK", TIMEOUT);

      expect(gateway?.requests).toHaveLength(1);
      expect(gateway?.requests[0]?.body).toContain(
        "Review (@src/main.zig now)",
      );
      expectCleanRuntime(current, active);
    },
    TIMEOUT,
  );

  tmuxTest(
    "keeps shared-prefix paths distinguishable at narrow widths",
    async () => {
      const current = createFixture("fx-file-picker-narrow-prefix-");
      initGit(current.workspace);
      const directory = join(
        current.workspace,
        "deeply-nested-source-directory",
      );
      mkdirSync(directory);
      for (let index = 1; index <= 40; index += 1) {
        writeFileSync(
          join(
            directory,
            `alpha-component-${index.toString().padStart(2, "0")}-with-a-very-long-descriptive-name.zig`,
          ),
          "fixture",
        );
      }
      git(current.workspace, "add", "deeply-nested-source-directory");

      const active = await startMockFx(current, [], 1000);
      await active.resizeWindow(40, 12);
      await active.sendLiteral("@alpha");
      await active.waitForText("alpha-component-01", TIMEOUT);

      const rows = (await active.capturePaneGrid())
        .filter((line) => line.includes("/alpha-component-"))
        .map((line) => line.trim());
      expect(rows.length).toBeGreaterThan(1);
      expect(new Set(rows).size).toBe(rows.length);
      expect(rows.some((line) => line.includes("alpha-component-01"))).toBe(true);
      expect(rows.some((line) => line.includes("alpha-component-02"))).toBe(true);
      expectCleanRuntime(current, active);
    },
    TIMEOUT,
  );

  tmuxTest(
    "keeps duplicate basenames distinguishable at narrow widths",
    async () => {
      const current = createFixture("fx-file-picker-duplicate-basename-");
      initGit(current.workspace);
      const basename = "shared-component-id-with-a-very-long-name.zig";
      const directories = [
        "first-distinguishing-parent-with-long-name",
        "second-distinguishing-parent-with-long-name",
      ];
      for (const directory of directories) {
        mkdirSync(join(current.workspace, directory));
        writeFileSync(join(current.workspace, directory, basename), "fixture");
      }
      git(current.workspace, "add", ...directories);

      const active = await startMockFx(current, [], 1000);
      await active.resizeWindow(40, 12);
      await active.sendLiteral("@shared-component");
      const resultPane = await active.waitForPane((pane) => {
        const rows = pane.split("\n").filter((line) =>
          line.includes("/shared-component")
        );
        return rows.length === 2 &&
          rows.some((line) => line.includes("first")) &&
          rows.some((line) => line.includes("second"));
      }, TIMEOUT);

      const rows = resultPane.split("\n")
        .filter((line) => line.includes("/shared-component"))
        .map((line) => line.trim());
      expect(rows).toHaveLength(2);
      expect(new Set(rows).size).toBe(2);
      expect(rows.some((line) => line.includes("first"))).toBe(true);
      expect(rows.some((line) => line.includes("second"))).toBe(true);
      expectCleanRuntime(current, active);
    },
    TIMEOUT,
  );

  tmuxTest(
    "workspace mutation exposes absolute added-root files and directories",
    async () => {
      const current = createFixture("fx-file-picker-added-root-");
      const shared = join(current.root, "shared");
      mkdirSync(join(shared, "added-root-directory"), { recursive: true });
      const sharedRoot = realpathSync(shared);
      const addedFile = join(sharedRoot, "added-root-unique.txt");
      const addedDirectory = join(sharedRoot, "added-root-directory");
      writeFileSync(addedFile, "added root picker fixture");
      writeFileSync(join(addedDirectory, "member.txt"), "directory member");

      const active = await startMockFx(current, [], 1000, {
      });
      await active.sendText(`/workspace add ${sharedRoot}`);
      await active.waitForText("saved_changed=true runtime_changed=true", TIMEOUT);
      await waitForFileText(current.tracePath, "file index generation ready", 2);

      await active.sendLiteral("@added-root-unique");
      await active.waitForText("added-root-unique.txt", TIMEOUT);
      await active.sendKeys("Enter");
      await waitForFileText(current.tracePath, "file picker Enter consumed selected=true");
      const composerText = (await active.capturePaneGrid())
        .filter(isComposerLine)
        .map((line) => line.replace(/^[ \t]*(?:┃|❯)[ \t]?/, ""))
        .join("")
        .replace(/\s/g, "");
      expect(composerText).toContain(`@${addedFile}`);

      await clearComposer(active);
      await active.sendLiteral("@added-root-directory");
      await active.waitForText("added-root-directory/", TIMEOUT);
      await active.sendKeys("Tab");
      const directoryComposerText = (await active.capturePaneGrid())
        .filter(isComposerLine)
        .map((line) => line.replace(/^[ \t]*(?:┃|❯)[ \t]?/, ""))
        .join("")
        .replace(/\s/g, "");
      expect(directoryComposerText).toContain(`@${addedDirectory}/`);
      expectCleanRuntime(current, active);
    },
    TIMEOUT,
  );

  tmuxTest(
    "shows a 50k result and releases zero-match Enter after dismissal",
    async () => {
      const current = createFixture("fx-file-picker-repaint-");
      for (let index = 0; index < 50_000; index += 1) {
        writeFileSync(
          join(current.workspace, `bulk-${index.toString().padStart(5, "0")}.txt`),
          "x",
        );
      }
      writeFileSync(join(current.workspace, "z_target_unique.txt"), "target");

      const active = await startMockFx(current, [
        fakeGatewayFinalText("dismissed file prompt submitted"),
      ]);
      await active.sendLiteral("@z_target_unique");
      await active.waitForText("z_target_unique.txt", TIMEOUT);
      await waitForFileText(
        current.tracePath,
        "file index generation ready generation=1 count=50001",
      );

      await clearComposer(active);
      await active.sendLiteral("@not_present_anywhere");
      await active.waitForText("no matching files", TIMEOUT);
      await active.sendKeys("Escape");
      await active.waitForPane(
        (pane) =>
          pane.includes("@not_present_anywhere") &&
          !pane.includes("no matching files"),
        TIMEOUT,
      );
      await active.sendLiteral("x");
      await active.waitForPane(
        (pane) =>
          pane.includes("@not_present_anywherex") &&
          !pane.includes("no matching files"),
        TIMEOUT,
      );
      await active.sendKeys("Enter");
      await active.waitForText("dismissed file prompt submitted", TIMEOUT);
      expect(gateway?.requests).toHaveLength(1);
      expectCleanRuntime(current, active);
      await replayTape(current);
    },
    120_000,
  );

  tmuxTest(
    "updates tracked and untracked membership while preserving ignores",
    async () => {
      const current = createFixture("fx-file-picker-refresh-");
      initGit(current.workspace);
      writeFileSync(join(current.workspace, ".gitignore"), "ignored.txt\n");
      writeFileSync(join(current.workspace, "tracked.txt"), "tracked");
      writeFileSync(join(current.workspace, "stale.txt"), "stale");
      writeFileSync(join(current.workspace, "ignored.txt"), "ignored");
      writeFileSync(join(current.workspace, "untracked.txt"), "untracked");
      git(current.workspace, "add", ".gitignore", "tracked.txt", "stale.txt");

      const active = await startMockFx(current, [], 1000);
      await active.sendLiteral("@track");
      await active.waitForText("tracked.txt", TIMEOUT);
      await active.sendKeys("Enter");
      await waitForFileText(current.tracePath, "file picker Enter consumed selected=true");
      await active.waitForText("@tracked.txt", TIMEOUT);

      await clearComposer(active);
      await active.sendLiteral("@ignored");
      await waitForFileText(
        current.tracePath,
        "file index generation ready generation=2",
      );
      await active.waitForText("no matching files", TIMEOUT);
      expect(gateway?.requests).toHaveLength(0);

      await clearComposer(active);
      await active.sendLiteral("@untracked");
      await waitForFileText(
        current.tracePath,
        "file index generation ready generation=3",
      );
      await active.waitForText("untracked.txt", TIMEOUT);
      const untrackedPane = await active.capturePane();
      expect(untrackedPane).toContain("@untracked");
      expect(untrackedPane).toContain("untracked.txt");
      expect(gateway?.requests).toHaveLength(0);

      await clearComposer(active);
      writeFileSync(join(current.workspace, "newly-tracked.txt"), "new");
      git(current.workspace, "add", "newly-tracked.txt");
      await active.sendLiteral("@newly-");
      await active.waitForText("newly-tracked.txt", TIMEOUT);

      await clearComposer(active);
      await active.sendLiteral("@stale");
      await active.waitForText("stale.txt", TIMEOUT);
      const staleRefreshOffset = readFileSync(current.tracePath, "utf8").length;
      unlinkSync(join(current.workspace, "stale.txt"));
      await clearComposer(active);
      await active.sendLiteral("@stale");
      await waitForFileSlice(current.tracePath, staleRefreshOffset, [
        "file index generation adopted",
      ]);
      await active.waitForText("no matching files", TIMEOUT);
      expect(gateway?.requests).toHaveLength(0);
      expectCleanRuntime(current, active);
    },
    TIMEOUT,
  );

  tmuxTest(
    "omits unsafe filenames while Unicode matches remain selectable",
    async () => {
      const current = createFixture("fx-file-picker-safety-");
      initGit(current.workspace);
      const unsafe = "evil-\x1b[2J.txt";
      writeFileSync(join(current.workspace, unsafe), "unsafe");
      writeFileSync(join(current.workspace, "evil-safe.txt"), "safe");
      writeFileSync(join(current.workspace, "Ärger-file.txt"), "unicode");
      git(current.workspace, "add", unsafe, "evil-safe.txt", "Ärger-file.txt");

      const active = await startMockFx(current, [], 1000);
      await active.sendLiteral("@evil-");
      await active.waitForText("evil-safe.txt", TIMEOUT);
      await waitForFileText(current.tracePath, "file index omitted unsafe candidate");
      expect((await active.capturePaneEscapes()).includes("\x1b[2J.txt")).toBe(false);

      await clearComposer(active);
      await active.sendLiteral("@ärger");
      await active.waitForText("Ärger-file.txt", TIMEOUT);
      await active.sendKeys("Enter");
      await waitForFileText(current.tracePath, "file picker Enter consumed selected=true");
      await active.waitForText("@Ärger-file.txt", TIMEOUT);
      expectCleanRuntime(current, active);
      await replayTape(current);
    },
    TIMEOUT,
  );

  tmuxTest(
    "renders and accepts fuzzy results across typed file kind changes",
    async () => {
      const current = createFixture("fx-file-picker-typed-integration-");
      initGit(current.workspace);
      writeFileSync(
        join(current.workspace, ".gitignore"),
        "ignored.txt\nignored-dir/\n",
      );
      mkdirSync(join(current.workspace, ".hidden"));
      mkdirSync(join(current.workspace, "nested", "deep"), { recursive: true });
      mkdirSync(join(current.workspace, "ignored-dir"));
      mkdirSync(join(current.workspace, "flip-dir"));
      writeFileSync(join(current.workspace, "tracked.txt"), "tracked");
      writeFileSync(join(current.workspace, "untracked.txt"), "untracked");
      writeFileSync(join(current.workspace, ".hidden", "tracked.txt"), "tracked");
      writeFileSync(
        join(current.workspace, ".hidden", "untracked.txt"),
        "untracked",
      );
      writeFileSync(join(current.workspace, "nested", "deep", "item.txt"), "item");
      writeFileSync(join(current.workspace, "ignored.txt"), "ignored");
      writeFileSync(join(current.workspace, "ignored-dir", "item.txt"), "ignored");
      writeFileSync(join(current.workspace, "alpha-component.txt"), "alpha");
      writeFileSync(join(current.workspace, "beta-component.txt"), "beta");
      writeFileSync(join(current.workspace, "flip-file.txt"), "file");
      writeFileSync(join(current.workspace, "flip-dir", "item.txt"), "dir");
      writeFileSync(
        join(current.workspace, ".git", "internal-secret-picker.txt"),
        "internal",
      );
      git(
        current.workspace,
        "add",
        ".gitignore",
        "tracked.txt",
        ".hidden/tracked.txt",
        "alpha-component.txt",
        "beta-component.txt",
        "flip-file.txt",
        "flip-dir/item.txt",
      );

      const active = await startMockFx(
        current,
        [fakeGatewayFinalText("TYPED_PATH_PROMPT_OK")],
        1000,
      );

      await active.sendLiteral("@.hidden/untracked");
      await active.waitForText(".hidden/untracked.txt", TIMEOUT);

      await clearComposer(active);
      await active.sendLiteral("@ignored");
      await active.waitForText("no matching files", TIMEOUT);
      expect(await active.capturePane()).not.toContain("ignored.txt");

      await clearComposer(active);
      await active.sendLiteral("@internal-secret-picker");
      await active.waitForText("no matching files", TIMEOUT);

      await clearComposer(active);
      await active.sendLiteral("Review @nstdp");
      await active.waitForText("nested/deep/", TIMEOUT);
      const escaped = await active.capturePaneEscapes();
      expect(escaped).toMatch(/\x1b\[1m[nstdp]\x1b\[0m/);
      await active.sendKeys("Tab");
      await active.waitForText("Review @nested/deep/", TIMEOUT);
      await active.sendLiteral(" now");
      await active.sendKeys("Enter");
      await active.waitForText("TYPED_PATH_PROMPT_OK", TIMEOUT);
      expect(gateway?.requests).toHaveLength(1);
      expect(gateway?.requests[0]?.body).toContain("Review @nested/deep/ now");

      await clearComposer(active);
      const componentAdoption = nextFileIndexAdoption(current.tracePath);
      await active.sendLiteral("@component");
      await active.waitForText("alpha-component.txt", TIMEOUT);
      await active.waitForText("beta-component.txt", TIMEOUT);
      await waitForFileText(current.tracePath, componentAdoption);
      await active.sendKeys("Down Down Enter");
      await active.waitForText("@beta-component.txt", TIMEOUT);

      await clearComposer(active);
      const stableFileAdoption = nextFileIndexAdoption(current.tracePath);
      await active.sendLiteral("@flip-file");
      await active.waitForText("flip-file.txt", TIMEOUT);
      await waitForFileText(current.tracePath, stableFileAdoption);
      rmSync(join(current.workspace, "flip-file.txt"));
      mkdirSync(join(current.workspace, "flip-file.txt"));
      await clearComposer(active);
      await active.waitForComposer(TIMEOUT);
      const refreshedFileAdoption = nextFileIndexAdoption(current.tracePath);
      await active.sendLiteral("@flip-file");
      await waitForFileText(current.tracePath, refreshedFileAdoption);
      await active.waitForText("flip-file.txt/", TIMEOUT);
      const refreshedFileTraceOffset = readFileSync(current.tracePath, "utf8").length;
      await active.sendKeys("Enter");
      await waitForFileSlice(current.tracePath, refreshedFileTraceOffset, [
        "file picker Enter consumed selected=true",
      ]);
      expect((await active.capturePane()).split("\n").filter(isComposerLine).join(""))
        .toContain("@flip-file.txt/");
      expect(gateway?.requests).toHaveLength(1);

      await clearComposer(active);
      const stableDirectoryAdoption = nextFileIndexAdoption(current.tracePath);
      await active.sendLiteral("@flip-dir");
      await active.waitForText("flip-dir/", TIMEOUT);
      await waitForFileText(current.tracePath, stableDirectoryAdoption);
      rmSync(join(current.workspace, "flip-dir"), { recursive: true, force: true });
      writeFileSync(join(current.workspace, "flip-dir"), "now a file");
      await clearComposer(active);
      await active.waitForComposer(TIMEOUT);
      const refreshedDirectoryAdoption = nextFileIndexAdoption(current.tracePath);
      await active.sendLiteral("@flip-dir");
      await waitForFileText(current.tracePath, refreshedDirectoryAdoption);
      const refreshedDirectoryTraceOffset = readFileSync(
        current.tracePath,
        "utf8",
      ).length;
      await active.sendKeys("Enter");
      await waitForFileSlice(current.tracePath, refreshedDirectoryTraceOffset, [
        "file picker Enter consumed selected=true",
      ]);
      expect((await active.capturePane()).split("\n").filter(isComposerLine).join(""))
        .toContain("@flip-dir");
      expect(gateway?.requests).toHaveLength(1);
      expectCleanRuntime(current, active);
      await replayTape(current);
    },
    120_000,
  );

  tmuxTest(
    "browses current, parent, home, and absolute filesystem paths",
    async () => {
      const current = createFixture("fx-file-picker-filesystem-");
      initGit(current.workspace);
      mkdirSync(join(current.workspace, "empty-workspace"));
      mkdirSync(join(current.workspace, "filled-dir"));
      mkdirSync(join(current.workspace, "build"));
      mkdirSync(join(current.workspace, "scoped", "@types"), { recursive: true });
      mkdirSync(join(current.home, "home-folder"));
      mkdirSync(join(current.home, "space dir"));
      mkdirSync(join(current.root, "absolute-dir"));
      writeFileSync(join(current.workspace, "filled-dir", "inside.txt"), "inside");
      writeFileSync(join(current.workspace, "build", "tracked.txt"), "tracked");
      writeFileSync(join(current.workspace, "scoped", "@types", "index.d.ts"), "types");
      writeFileSync(join(current.root, "parent-target.txt"), "parent");
      writeFileSync(join(current.home, "home-folder", "home-target.txt"), "home");
      writeFileSync(
        join(current.home, "space dir", "item.txt"),
        "FILE_CONTENT_MUST_NOT_BE_ATTACHED_7C91",
      );
      writeFileSync(join(current.root, "absolute-dir", "absolute.txt"), "absolute");
      git(current.workspace, "add", "filled-dir/inside.txt", "build/tracked.txt");

      const active = await startMockFx(
        current,
        [fakeGatewayFinalText("FILESYSTEM_PATH_PROMPT_OK")],
        1000,
      );

      await active.sendLiteral("@empty-workspace");
      await active.waitForText("empty-workspace/", TIMEOUT);
      await active.sendKeys("Tab");
      expect(await composerPlainText(active)).toBe("@empty-workspace/");
      await active.waitForText("no matching files", TIMEOUT);
      await active.sendKeys("Escape");
      await active.waitForPane((pane) => !pane.includes("no matching files"), TIMEOUT);

      await clearComposer(active);
      await active.sendLiteral("@build");
      await active.waitForText("build/", TIMEOUT);
      await active.sendKeys("Escape");

      await clearComposer(active);
      await active.sendLiteral("@./filled");
      await active.waitForText("./filled-dir/", TIMEOUT);
      await active.sendKeys("Tab");
      await active.sendLiteral("inside");
      await active.waitForText("./filled-dir/inside.txt", TIMEOUT);
      await active.sendKeys("Tab");
      expect(await composerPlainText(active)).toBe("@./filled-dir/inside.txt");

      await clearComposer(active);
      await active.sendLiteral("@./scoped/@t");
      await active.waitForText("./scoped/@types/", TIMEOUT);
      await active.sendKeys("Tab");
      expect(await composerPlainText(active)).toBe("@./scoped/@types/");
      await active.sendLiteral("index");
      await active.waitForText("./scoped/@types/index.d.ts", TIMEOUT);
      await active.sendKeys("Tab");
      expect(await composerPlainText(active)).toBe("@./scoped/@types/index.d.ts");

      await clearComposer(active);
      await active.sendLiteral("@../parent");
      await active.waitForText("../parent-target.txt", TIMEOUT);
      await active.sendKeys("Tab");
      expect(await composerPlainText(active)).toBe("@../parent-target.txt");

      await clearComposer(active);
      await active.sendLiteral("@~/home");
      await active.waitForText("~/home-folder/", TIMEOUT);
      await active.sendKeys("Tab");
      await active.sendLiteral("home-target");
      await active.waitForText("~/home-folder/home-target.txt", TIMEOUT);
      await active.sendKeys("Tab");
      expect(await composerPlainText(active)).toBe("@~/home-folder/home-target.txt");

      await clearComposer(active);
      const absolutePrefix = join(current.root, "absolute-dir");
      await active.sendLiteral(`@${absolutePrefix}/ab`);
      await active.waitForText("absolute.txt", TIMEOUT);
      await active.sendKeys("Tab");
      expect(await composerPlainText(active)).toBe(`@${absolutePrefix}/absolute.txt`);

      await clearComposer(active);
      await active.sendLiteral('@"~/space');
      await active.waitForText("~/space dir/", TIMEOUT);
      await active.sendKeys("Tab");
      await active.sendLiteral("item");
      await active.waitForText("~/space dir/item.txt", TIMEOUT);
      await active.sendKeys("Tab");
      expect(await composerPlainText(active)).toBe('@"~/space dir/item.txt"');
      await active.sendLiteral(" Reply with FILESYSTEM_PATH_PROMPT_OK.");
      await active.sendKeys("Enter");
      await waitForGatewayRequestCount(1);
      await active.waitForText("FILESYSTEM_PATH_PROMPT_OK", TIMEOUT);

      expect(gateway?.requests).toHaveLength(1);
      const request = JSON.parse(gateway!.requests[0]!.body) as {
        prompt: Array<{ role: string; content: unknown }>;
      };
      expect(request.prompt.at(-1)).toEqual({
        role: "user",
        content: [{
          type: "text",
          text: '@"~/space dir/item.txt" Reply with FILESYSTEM_PATH_PROMPT_OK.',
        }],
      });
      expect(gateway?.requests[0]?.body).not.toContain(
        "FILE_CONTENT_MUST_NOT_BE_ATTACHED_7C91",
      );
      expectCleanRuntime(current, active);
    },
    120_000,
  );

  tmuxTest(
    "claims a typed separator after end completion without duplicating it",
    async () => {
      const current = createFixture("fx-file-picker-owned-spacing-");
      initGit(current.workspace);
      writeFileSync(join(current.workspace, "AGENTS.md"), "agents");
      writeFileSync(join(current.workspace, "README.md"), "readme");
      git(current.workspace, "add", "AGENTS.md", "README.md");

      const active = await startMockFx(
        current,
        [fakeGatewayFinalText("FILE_PICKER_OWNED_SPACING_OK")],
        1000,
      );
      await active.sendLiteral("@AGEN");
      await active.waitForText("AGENTS.md", TIMEOUT);
      await active.sendKeys("Enter");
      await active.sendLiteral(" @READ");
      await active.waitForText("@AGENTS.md @READ", TIMEOUT);
      expect((await active.capturePane()).includes("@AGENTS.md  @READ")).toBe(false);

      await active.waitForText("README.md", TIMEOUT);
      await active.sendKeys("Enter");
      await active.waitForText("@AGENTS.md @README.md", TIMEOUT);
      await active.sendKeys("Enter");
      await active.waitForText("FILE_PICKER_OWNED_SPACING_OK", TIMEOUT);
      expect(gateway?.requests).toHaveLength(1);
      expect(gateway?.requests[0]?.body).toContain("@AGENTS.md @README.md ");
      expectCleanRuntime(current, active);
    },
    TIMEOUT,
  );

  tmuxTest(
    "middle completion preserves one separator and submits the exact prompt",
    async () => {
      const current = createFixture("fx-file-picker-spacing-");
      initGit(current.workspace);
      writeFileSync(join(current.workspace, "first-file.txt"), "first");
      git(current.workspace, "add", "first-file.txt");

      const active = await startMockFx(
        current,
        [fakeGatewayFinalText("FILE_PICKER_MOCK_OK")],
        1000,
      );
      await active.sendLiteral("Read @first- suffix");
      await active.sendKeys("Left Left Left Left Left Left Left");
      await active.waitForText("first-file.txt", TIMEOUT);
      await active.sendKeys("Enter");
      await active.waitForText("Read @first-file.txt suffix", TIMEOUT);
      expect((await active.capturePane()).includes("first-file.txt  suffix")).toBe(false);

      await active.sendKeys("Enter");
      await active.waitForText("FILE_PICKER_MOCK_OK", TIMEOUT);
      expect(gateway?.requests).toHaveLength(1);
      expect(gateway?.requests[0]?.body).toContain("Read @first-file.txt suffix");
      expectCleanRuntime(current, active);
    },
    TIMEOUT,
  );

  tmuxTest(
    "persists a selected plain-text path across two process resume cycles",
    async () => {
      const current = createFixture("fx-file-picker-resume-");
      initGit(current.workspace);
      writeFileSync(
        join(current.workspace, "resume-context.txt"),
        "plain text path persistence fixture",
      );
      git(current.workspace, "add", "resume-context.txt");

      const responses = [
        "FILE_PICKER_RESUME_SEEDED",
        "FILE_PICKER_RESUME_ONE",
        "FILE_PICKER_RESUME_TWO",
      ];
      const active = await startMockFx(
        current,
        responses.map((text) => fakeGatewayFinalText(text)),
        1_000,
      );
      await active.sendLiteral("Remember @resume-context");
      await active.waitForText("resume-context.txt", TIMEOUT);
      await active.sendKeys("Tab");
      await active.sendLiteral(" exactly");
      await active.sendKeys("Enter");
      await active.waitForText(responses[0]!, TIMEOUT);
      expect(gateway?.requests).toHaveLength(1);
      expect(gateway?.requests[0]?.body).toContain(
        "Remember @resume-context.txt exactly",
      );

      await active.sendText("/quit");
      expect(await active.waitForSessionEnd(TIMEOUT)).toBe(true);
      session = null;
      expect(readFileSync(current.stderrPath, "utf8")).toBe("");

      const listed = await runFx(["sessions", "--json"], {
        cwd: current.workspace,
        env: { HOME: current.home },
        timeoutMs: TIMEOUT,
      });
      expect(listed.code).toBe(0);
      expect(listed.stderr).toBe("");
      const sessionId = (JSON.parse(listed.stdout) as {
        sessions: Array<{ id: string }>;
      }).sessions[0]?.id;
      expect(sessionId).toBeDefined();
      const saved = await runFx(["session", "--id", sessionId!, "--json"], {
        cwd: current.workspace,
        env: { HOME: current.home },
        timeoutMs: TIMEOUT,
      });
      expect(saved.code).toBe(0);
      expect(saved.stderr).toBe("");
      expect(saved.stdout).toContain("Remember @resume-context.txt exactly");

      for (const cycle of [1, 2] as const) {
        writeFileSync(current.stderrPath, "");
        const activeGateway = gateway!;
        session = await TmuxSession.create({
          cmd: `${FX_BIN} --resume-last`,
          cwd: current.workspace,
          env: mockFxEnvironment(current, activeGateway, {
            FX_RECORD: join(current.root, `resume-${cycle}.fxtape`),
          }),
          width: cycle === 1 ? 48 : 160,
          height: cycle === 1 ? 12 : 50,
          stderrPath: current.stderrPath,
          startupWaitMs: 1_000,
        });
        await session.waitForComposer(TIMEOUT);
        await session.waitForText("@resume-context.txt", TIMEOUT);
        await session.sendText(`Resume cycle ${cycle} keeps the path.`);
        await session.waitForText(responses[cycle]!, TIMEOUT);
        expect(activeGateway.requests).toHaveLength(cycle + 1);
        expect(activeGateway.requests[cycle]?.body).toContain(
          "Remember @resume-context.txt exactly",
        );
        expect(activeGateway.requests[cycle]?.body).toContain(
          `Resume cycle ${cycle} keeps the path.`,
        );
        expect(readFileSync(current.stderrPath, "utf8")).toBe("");
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
        session = null;
      }

      const resumedSaved = await runFx(
        ["session", "--id", sessionId!, "--json"],
        {
          cwd: current.workspace,
          env: { HOME: current.home },
          timeoutMs: TIMEOUT,
        },
      );
      expect(resumedSaved.code).toBe(0);
      expect(resumedSaved.stderr).toBe("");
      expect(resumedSaved.stdout).toContain("@resume-context.txt");
      expect(resumedSaved.stdout).toContain("Resume cycle 1 keeps the path.");
      expect(resumedSaved.stdout).toContain("Resume cycle 2 keeps the path.");
    },
    240_000,
  );

  liveTmuxTest(
    "browses a home path and submits through the live Gateway",
    async () => {
      const current = createFixture("fx-file-picker-live-");
      initGit(current.workspace);
      mkdirSync(join(current.home, "live space"));
      writeFileSync(
        join(current.home, "live space", "live-context.txt"),
        "live picker fixture",
      );

      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: current.workspace,
        env: {
          HOME: current.home,
          AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY,
          VERCEL_OIDC_TOKEN: process.env.VERCEL_OIDC_TOKEN,
          FX_AUTO_UPGRADE: "0",
          FX_MODEL: process.env.FX_FILE_PICKER_LIVE_MODEL ?? "anthropic/claude-sonnet-4.6",
          FX_TRACE_LOG: current.tracePath,
          FX_TRACE_SCOPES: "input,prompt,gateway",
        },
        width: 112,
        height: 32,
        stderrPath: current.stderrPath,
        startupWaitMs: 1000,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendLiteral('@"~/live');
      await session.waitForText("live space/", TIMEOUT);
      await session.sendKeys("Tab");
      await session.sendLiteral("live-context");
      await session.waitForText("live-context.txt", TIMEOUT);
      await session.sendKeys("Enter");
      await session.sendLiteral(
        " Reply with the words LIVE, PICKER, and OK joined by underscores, and nothing else.",
      );
      await session.sendKeys("Enter");
      await session.waitForText("LIVE_PICKER_OK", 180_000);
      expectCleanRuntime(current, session);
    },
    180_000,
  );
});
