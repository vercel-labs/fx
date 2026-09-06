import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { readTapeFrames, type TapeFrame } from "./render-lab/tape";
import {
  composerContains,
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  hasEmptyComposer,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const ENABLED = process.env.FX_TUI_PERFORMANCE === "1";
const LIVE_ENABLED = process.env.FX_E2E_REAL_API === "1" &&
  typeof process.env.AI_GATEWAY_API_KEY === "string" &&
  process.env.AI_GATEWAY_API_KEY.length > 0;
const WARMUPS = 5;
const SAMPLES = 50;
const LOCAL_BUDGETS_MS = { p50: 8, p90: 12, p95: 17 } as const;
const BACKGROUND_WORK_BUDGETS_MS = { p50: 12, p90: 17, p95: 17 } as const;
const EXTERNAL_REFRESH_BUDGETS_MS = { p50: 17, p90: 17, p95: 17 } as const;
const APP_PANE_BUDGETS_MS = { p50: 12, p90: 17, p95: 17 } as const;
const ACTIVE_TURN_DESCRIPTOR_BUDGET = 7;
const TIMEOUT = 60_000;

const LOCAL_MENU_ACTIONS = [
  { name: "helpOpen", command: "/help", marker: "Commands " },
  { name: "settingsOpen", command: "/settings", marker: "Settings" },
  { name: "modelOpen", command: "/model", marker: "Models " },
  { name: "resumeOpen", command: "/resume", marker: "Sessions " },
  { name: "mcpOpen", command: "/mcp", marker: "[Servers]" },
  { name: "usageOpen", command: "/usage", marker: "[30 days]" },
  { name: "statuslineOpen", command: "/statusline", marker: "Status line" },
  { name: "workspaceOpen", command: "/workspace", marker: "Enter Use" },
] as const;

const MEASURED_ACTION_NAMES = [
  "composerEdit",
  "slashOpen",
  "slashQuery",
  "dollarOpen",
  "dollarQuery",
  "fileQuery",
  "questionNavigate",
  "approvalNavigate",
  "fullOpen",
  "fullScroll",
  "fullScrollCacheMiss",
  "skillsOpen",
  "skillsQuery",
  "loginOpen",
  ...LOCAL_MENU_ACTIONS.map((action) => action.name),
] as const;

const INFORMATIONAL_PANE_ACTION_NAMES = new Set<string>();

const APP_PANE_ACTION_NAMES = new Set<string>([
  ...LOCAL_MENU_ACTIONS.map((action) => action.name),
]);

type Samples = {
  firstPaint: number[];
  contentReady: number[];
};

type ResourceSnapshot = {
  rssKib: number;
  threads: number;
  descriptors: number;
};

function findSessionId(value: unknown): string | undefined {
  if (typeof value === "string") {
    try {
      return findSessionId(JSON.parse(value));
    } catch {
      return undefined;
    }
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findSessionId(item);
      if (found !== undefined) return found;
    }
    return undefined;
  }
  if (value === null || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  if (typeof record.session_id === "string") return record.session_id;
  for (const child of Object.values(record)) {
    const found = findSessionId(child);
    if (found !== undefined) return found;
  }
  return undefined;
}

function percentile(values: readonly number[], fraction: number): number {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)]!;
}

function summary(values: readonly number[]) {
  return {
    count: values.length,
    p50: percentile(values, 0.5),
    p90: percentile(values, 0.9),
    p95: percentile(values, 0.95),
    max: Math.max(...values),
    failures: 0,
  };
}

function readCompleteTape(path: string): TapeFrame[] {
  let lastError: unknown;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      return readTapeFrames(path);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

function frameLatency(
  frames: readonly TapeFrame[],
  fromIndex: number,
  contentMarker?: string,
): { firstPaint: number; contentReady: number } {
  const inputIndex = frames.findIndex((frame, index) =>
    index >= fromIndex && frame.kind === 2
  );
  if (inputIndex < 0) throw new Error("recording did not contain the measured stdin frame");

  let elapsed = 0;
  let firstPaint: number | undefined;
  let lastPaint: number | undefined;
  let output = "";
  for (let index = inputIndex + 1; index < frames.length; index += 1) {
    const frame = frames[index]!;
    elapsed += frame.deltaMs;
    if (frame.kind === 2) break;
    if (frame.kind !== 1) continue;
    firstPaint ??= elapsed;
    lastPaint = elapsed;
    output += frame.payload.toString("utf8");
    if (contentMarker !== undefined && output.includes(contentMarker)) {
      return { firstPaint, contentReady: elapsed };
    }
  }
  if (firstPaint !== undefined && lastPaint !== undefined) {
    return { firstPaint, contentReady: lastPaint };
  }
  throw new Error(
    `recording did not contain content-ready stdout after input; marker=${JSON.stringify(contentMarker)}`,
  );
}

async function measureAction(
  tapePath: string,
  action: () => void,
  waitReady: () => Promise<unknown>,
  contentMarker?: string,
): Promise<{ firstPaint: number; contentReady: number }> {
  const fromIndex = readCompleteTape(tapePath).length;
  action();
  await waitReady();
  return frameLatency(readCompleteTape(tapePath), fromIndex, contentMarker);
}

async function measurePaneAction(
  action: () => void,
  waitReady: () => Promise<unknown>,
): Promise<{ firstPaint: number; contentReady: number }> {
  const started = performance.now();
  action();
  await waitReady();
  const elapsed = Math.ceil(performance.now() - started);
  return { firstPaint: elapsed, contentReady: elapsed };
}

async function waitForPaneChange(
  session: TmuxSession,
  before: string,
  timeoutMs = TIMEOUT,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await session.capturePane() !== before) return;
    await Bun.sleep(1);
  }
  throw new Error("terminal pane did not change after input");
}

async function waitForPaneText(
  session: TmuxSession,
  marker: string,
  before: string,
  timeoutMs = TIMEOUT,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const pane = await session.capturePane();
    if (pane !== before && pane.includes(marker)) return;
    await Bun.sleep(1);
  }
  throw new Error(`terminal pane did not show ${JSON.stringify(marker)}`);
}

async function waitForTapeQuiescence(
  tapePath: string,
  quietMs = 20,
  timeoutMs = TIMEOUT,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastLength = readCompleteTape(tapePath).length;
  let quietSince = Date.now();
  while (Date.now() < deadline) {
    await Bun.sleep(2);
    const length = readCompleteTape(tapePath).length;
    if (length !== lastLength) {
      lastLength = length;
      quietSince = Date.now();
      continue;
    }
    if (Date.now() - quietSince >= quietMs) return;
  }
  throw new Error("recording did not become quiescent before the next action");
}

async function waitForEscapedPaneChange(
  session: TmuxSession,
  before: string,
  label: string,
  timeoutMs = TIMEOUT,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await session.capturePaneEscapes() !== before) return;
    await Bun.sleep(2);
  }
  throw new Error(`${label} did not produce a changed escaped pane`);
}

async function closeSurface(
  session: TmuxSession,
  visibleMarker: string,
  closeKey = "Escape",
): Promise<void> {
  session.sendKeysImmediate([closeKey, "C-u"]);
  await session.waitForPane(
    (pane) => hasEmptyComposer(pane) && !pane.includes(visibleMarker),
    TIMEOUT,
  );
}

function appendMeasured(samples: Samples, value: { firstPaint: number; contentReady: number }) {
  samples.firstPaint.push(value.firstPaint);
  samples.contentReady.push(value.contentReady);
}

function resourceSnapshot(pid: number): ResourceSnapshot {
  const rssKib = Number.parseInt(
    execFileSync("ps", ["-o", "rss=", "-p", String(pid)], { encoding: "utf8" }).trim(),
    10,
  );
  const threads = process.platform === "linux"
    ? Number.parseInt(
      readFileSync(`/proc/${pid}/status`, "utf8").match(/^Threads:\s+(\d+)$/m)?.[1] ?? "0",
      10,
    )
    : execFileSync("ps", ["-M", "-p", String(pid)], { encoding: "utf8" })
      .trim().split("\n").length - 1;
  const descriptors = process.platform === "linux"
    ? readdirSync(`/proc/${pid}/fd`).length
    : execFileSync("lsof", ["-p", String(pid), "-Fn"], { encoding: "utf8" })
      .split("\n").filter((line) => line.startsWith("n")).length;
  return { rssKib, threads, descriptors };
}

async function peakResourcesWhile(
  pid: number,
  work: () => Promise<unknown>,
): Promise<ResourceSnapshot> {
  let settled = false;
  const pending = work().finally(() => {
    settled = true;
  });
  let peak = resourceSnapshot(pid);
  while (!settled) {
    const current = resourceSnapshot(pid);
    peak = {
      rssKib: Math.max(peak.rssKib, current.rssKib),
      threads: Math.max(peak.threads, current.threads),
      descriptors: Math.max(peak.descriptors, current.descriptors),
    };
    await Bun.sleep(5);
  }
  await pending;
  return peak;
}

async function waitForResourceQuiescence(
  pid: number,
  expected: ResourceSnapshot,
  timeoutMs = 5_000,
): Promise<ResourceSnapshot> {
  const deadline = Date.now() + timeoutMs;
  let current = resourceSnapshot(pid);
  while (Date.now() < deadline) {
    if (
      current.threads === expected.threads &&
      current.descriptors === expected.descriptors
    ) return current;
    await Bun.sleep(25);
    current = resourceSnapshot(pid);
  }
  throw new Error(
    `resources did not return to baseline: ` +
      `expected threads/fds=${expected.threads}/${expected.descriptors} ` +
      `received=${current.threads}/${current.descriptors}`,
  );
}

async function waitForResourceStability(
  pid: number,
  quietMs = 500,
  timeoutMs = 5_000,
): Promise<ResourceSnapshot> {
  const deadline = Date.now() + timeoutMs;
  let current = resourceSnapshot(pid);
  let stableSince = Date.now();
  while (Date.now() < deadline) {
    await Bun.sleep(25);
    const next = resourceSnapshot(pid);
    if (
      next.threads !== current.threads ||
      next.descriptors !== current.descriptors
    ) {
      current = next;
      stableSince = Date.now();
      continue;
    }
    current = next;
    if (Date.now() - stableSince >= quietMs) return current;
  }
  throw new Error("resources did not become stable after feature warmup");
}

function longTranscript(): string {
  const rows: string[] = [];
  for (let index = 0; index < 2_100; index += 1) {
    if (index === 0) rows.push("PERF_TRANSCRIPT_HEAD");
    else if (index === 1_050) rows.push("PERF_TRANSCRIPT_MIDDLE");
    else if (index === 2_099) rows.push("PERF_TRANSCRIPT_TAIL");
    else if (index % 17 === 0) rows.push(`| ${index} | wide unicode 𝒇x 漢字 | wrapped ${"x".repeat(96)} |`);
    else if (index % 11 === 0) rows.push("");
    else rows.push(`transcript row ${String(index).padStart(4, "0")}`);
  }
  return rows.join("\n");
}

function createFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-tui-performance-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const skillsRoot = join(workspace, ".agents", "skills");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(skillsRoot, { recursive: true });
  const hash = createHash("sha256");
  let generationSkillPath = "";
  for (let index = 0; index < 289; index += 1) {
    const name = index === 0
      ? "generation-skill-000"
      : index % 2 === 0
      ? `needle-skill-${String(index).padStart(3, "0")}`
      : `other-skill-${String(index).padStart(3, "0")}`;
    const body = `---\nname: ${name}\ndescription: performance fixture ${index}\n---\nbody ${index}\n`;
    const dir = join(skillsRoot, name);
    mkdirSync(dir, { recursive: true });
    const skillPath = join(dir, "SKILL.md");
    writeFileSync(skillPath, body);
    if (index === 0) generationSkillPath = skillPath;
    hash.update(body);
  }
  const transcript = longTranscript();
  writeFileSync(join(workspace, "performance-target.txt"), "fixture\n");
  hash.update(transcript);
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    tapePath: join(root, "performance.fxtape"),
    stderrPath: join(root, "stderr.log"),
    fixtureHash: hash.digest("hex"),
    transcript,
    generationSkillPath,
  };
}

function writeGenerationSkill(path: string, generation: number): string {
  const name = `generation-skill-${String(generation).padStart(3, "0")}`;
  writeFileSync(
    path,
    `---\nname: ${name}\ndescription: current catalog generation ${generation}\n---\nbody ${generation}\n`,
  );
  return name;
}

function sendOverlappingSkillCommands(
  session: TmuxSession,
  newestSkill: string,
): void {
  execFileSync("tmux", [
    "send-keys", "-t", session.name, "-l", "--", "/skills",
    ";", "send-keys", "-t", session.name, "Enter",
    ";", "send-keys", "-t", session.name, "-l", "--",
    `/skills show ${newestSkill}`,
    ";", "send-keys", "-t", session.name, "Enter",
  ]);
}

test.skipIf(!tmuxAvailable())(
  "overlapping skill commands keep the latest action and the shell alive",
  async () => {
    const fixture = createFixture();
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          NO_COLOR: "1",
        },
        stderrPath: fixture.stderrPath,
        width: 104,
        height: 30,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("/skills");
      await session.waitForText("Skills 289", TIMEOUT);
      await closeSurface(session, "Skills ");

      const newest = writeGenerationSkill(fixture.generationSkillPath, 999);
      sendOverlappingSkillCommands(session, newest);
      await session.waitForText(newest, TIMEOUT);
      await session.waitForText("Skills 289", TIMEOUT);
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    } finally {
      await session?.kill();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  120_000,
);

test.skipIf(!tmuxAvailable())(
  "prompt admission treats missing HOME as an empty optional skill catalog",
  async () => {
    const fixture = createFixture();
    const noHomeGateway = startFakeGateway([
      fakeGatewayFinalText("MISSING_HOME_PROMPT_OK"),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          HOME: undefined,
          AI_GATEWAY_API_KEY: "missing-home-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: noHomeGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: noHomeGateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_SOUND: "0",
          NO_COLOR: "1",
        },
        stderrPath: fixture.stderrPath,
        width: 104,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("Submit without an optional home directory.");
      const pane = await active.waitForText("MISSING_HOME_PROMPT_OK", 5_000);
      expect(pane).not.toContain("HomeNotSet");
      expect(noHomeGateway.requestCount()).toBe(1);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    } finally {
      await active?.kill();
      noHomeGateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  30_000,
);

test.skipIf(!tmuxAvailable())(
  "skills refresh discovers SKILL.md added inside an existing candidate directory",
  async () => {
    const fixture = createFixture();
    const candidate = join(
      fixture.workspace,
      ".agents",
      "skills",
      "late-skill",
    );
    mkdirSync(candidate);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          NO_COLOR: "1",
        },
        stderrPath: fixture.stderrPath,
        width: 104,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      await active.sendText("/skills");
      await active.waitForText("Skills 289", TIMEOUT);
      await closeSurface(active, "Skills ");

      writeFileSync(
        join(candidate, "SKILL.md"),
        "---\nname: late-skill\ndescription: created inside an existing candidate\n---\nbody\n",
      );
      await active.sendText("/skills");
      const refreshed = await active.waitForText("late-skill", TIMEOUT);
      expect(refreshed).toContain("Skills 290");
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    } finally {
      await active?.kill();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  30_000,
);

test.skipIf(!tmuxAvailable())(
  "skills refresh preserves the canonical catalog for a symlinked HOME",
  async () => {
    const fixture = createFixture();
    const linkedHome = join(fixture.root, "linked-home");
    const globalSkill = join(
      fixture.home,
      ".agents",
      "skills",
      "global-skill",
    );
    mkdirSync(globalSkill, { recursive: true });
    writeFileSync(
      join(globalSkill, "SKILL.md"),
      "---\nname: global-skill\ndescription: survives canonical home refresh\n---\nbody\n",
    );
    symlinkSync(fixture.home, linkedHome, "dir");
    const linkedHomeGateway = startFakeGateway([
      fakeGatewayFinalText("SYMLINKED_HOME_PROMPT_OK"),
    ]);
    let active: TmuxSession | null = null;
    try {
      active = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          HOME: linkedHome,
          AI_GATEWAY_API_KEY: "symlinked-home-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: linkedHomeGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: linkedHomeGateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "1",
          FX_SOUND: "0",
          NO_COLOR: "1",
        },
        stderrPath: fixture.stderrPath,
        width: 104,
        height: 30,
      });
      await active.waitForComposer(TIMEOUT);
      active.sendLiteralImmediate("$global");
      await active.waitForText("global-skill", TIMEOUT);
      await closeSurface(active, "Skills ");

      sendOverlappingSkillCommands(active, "global-skill");
      await active.waitForText("global-skill", 5_000);
      await active.waitForText("Skills 290", 5_000);
      await closeSurface(active, "Skills ");

      await active.sendText("Submit after canonical home refresh.");
      await active.waitForText("SYMLINKED_HOME_PROMPT_OK", TIMEOUT);
      expect(linkedHomeGateway.requestCount()).toBe(1);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    } finally {
      await active?.kill();
      linkedHomeGateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  60_000,
);

test.skipIf(!ENABLED || !tmuxAvailable())(
  "interactive terminal surfaces stay within one frame at p95",
  async () => {
    const fixture = createFixture();
    const secondTranscript = fixture.transcript.replace(
      "PERF_TRANSCRIPT_TAIL",
      "PERF_SECOND_TRANSCRIPT_TAIL",
    );
    let hostedTerminalSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayFinalText(fixture.transcript),
      fakeGatewayToolCall("performance-question", "ask_user_question", {
        questions: [{
          question: "Which performance path should I use?",
          options: [
            { label: "Alpha path", description: "Use the first path." },
            { label: "Beta path", description: "Use the second path." },
          ],
        }],
      }),
      fakeGatewayFinalText("PERF_QUESTION_DONE"),
      fakeGatewayToolCall("performance-approval", "shell", {
        request: {
          action: "run",
          command: "touch performance-approval.txt",
          profile: "clean",
          timeout_ms: 600_000,
        },
      }),
      fakeGatewayFinalText("PERF_APPROVAL_DONE"),
      fakeGatewayToolCall("performance-terminal", "shell", {
        request: {
          action: "run",
          cwd: fixture.workspace,
          command:
            "printf 'PERF_TERMINAL_READY\\n'; " +
            "while :; do sleep 1; done",
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
        },
      }),
      (body) => {
        hostedTerminalSessionId = findSessionId(JSON.parse(body)) ?? "";
        if (hostedTerminalSessionId.length === 0) {
          throw new Error("terminal start result did not contain a session id");
        }
        return fakeGatewayFinalText("PERF_TERMINAL_AGENT_READY");
      },
      () => fakeGatewayToolCall("performance-terminal-close", "shell", {
        request: {
          action: "stop",
          session_id: hostedTerminalSessionId,
          force: true,
        },
      }),
      fakeGatewayFinalText("PERF_TERMINAL_CLOSED"),
      fakeGatewayFinalText(secondTranscript),
    ]);
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: "fake-performance-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_PERMISSION_MODE: "ask",
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          FX_RECORD: fixture.tapePath,
          FX_RECORD_INPUT: "1",
          FX_TERMINAL_HOST_IDLE_MS: "250",
          NO_COLOR: "1",
        },
        stderrPath: fixture.stderrPath,
        width: 104,
        height: 30,
        minimumHistoryLines: 20_000,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Build the performance transcript.");
      await session.waitForText("PERF_TRANSCRIPT_TAIL", TIMEOUT);

      // One correctness cycle also fences the inline prewarm before timing.
      session.sendKeysImmediate(["C-o"]);
      await session.waitForText("Full detail · ctrl o close", TIMEOUT);
      expect(await session.captureFullScrollback()).toContain("PERF_TRANSCRIPT_HEAD");
      session.sendKeysImmediate(["Escape"]);
      await session.waitForComposer(TIMEOUT);

      const samples = Object.fromEntries(
        MEASURED_ACTION_NAMES.map((name) => [
          name,
          { firstPaint: [], contentReady: [] } as Samples,
        ]),
      ) as Record<(typeof MEASURED_ACTION_NAMES)[number], Samples>;
      const pid = session.processPid();
      const preFeatureResources = resourceSnapshot(pid);

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        const open = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate(["C-o"]),
          () => session!.waitForText("Full detail · ctrl o close", TIMEOUT),
          "Full detail",
        );
        const beforeScroll = await session.capturePane();
        const scroll = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate(["Up"]),
          () => session!.waitForPane(
            (pane) => pane !== beforeScroll && pane.includes("Full detail"),
            TIMEOUT,
          ),
        );
        session.sendKeysImmediate(["Escape"]);
        await session.waitForComposer(TIMEOUT);
        if (cycle >= WARMUPS) {
          appendMeasured(samples.fullOpen, open);
          appendMeasured(samples.fullScroll, scroll);
        }
      }

      session.sendKeysImmediate(["C-o"]);
      await session.waitForText("Full detail · ctrl o close", TIMEOUT);
      let beforePrime = await session.capturePane();
      // The first key moves one viewport into the three-viewport prepared
      // window. Each loop then moves to its edge before the measured key
      // crosses that edge and waits for the replacement window.
      session.sendKeysImmediate(["PageUp"]);
      await session.waitForPane(
        (pane) => pane !== beforePrime && pane.includes("Full detail"),
        TIMEOUT,
      );
      await waitForTapeQuiescence(fixture.tapePath);
      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        const key = cycle % 2 === 0 ? "PageUp" : "PageDown";
        beforePrime = await session.capturePane();
        session.sendKeysImmediate([key]);
        await session.waitForPane(
          (pane) => pane !== beforePrime && pane.includes("Full detail"),
          TIMEOUT,
        );
        await waitForTapeQuiescence(fixture.tapePath);
        const beforeMiss = await session.capturePane();
        const cacheMiss = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate([key]),
          () => session!.waitForPane(
            (pane) => pane !== beforeMiss && pane.includes("Full detail"),
            TIMEOUT,
          ),
        );
        if (cycle >= WARMUPS) {
          appendMeasured(samples.fullScrollCacheMiss, cacheMiss);
        }
      }
      session.sendKeysImmediate(["Escape"]);
      await session.waitForComposer(TIMEOUT);

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        const generationName = writeGenerationSkill(
          fixture.generationSkillPath,
          cycle + 1,
        );
        await session.sendLiteralText("/skills");
        const open = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate(["Enter"]),
          () => session!.waitForText(generationName, TIMEOUT),
          generationName,
        );
        const query = await measureAction(
          fixture.tapePath,
          () => session!.sendLiteralImmediate("needle"),
          () => session!.waitForText("Skills 144", TIMEOUT),
          "Skills 144",
        );
        session.sendKeysImmediate(["Escape"]);
        await session.waitForComposer(TIMEOUT);
        if (cycle >= WARMUPS) {
          appendMeasured(samples.skillsOpen, open);
          appendMeasured(samples.skillsQuery, query);
        }
      }

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        await session.sendKeys("C-u");
        await session.waitForComposer(TIMEOUT);
        const open = await measureAction(
          fixture.tapePath,
          () => session!.sendLiteralImmediate("/login "),
          () => session!.waitForPane(
            (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
            TIMEOUT,
          ),
          "vercel",
        );
        if (cycle >= WARMUPS) appendMeasured(samples.loginOpen, open);
      }

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        session.sendKeysImmediate(["C-u"]);
        await session.waitForComposer(TIMEOUT);
        const marker = `performance-edit-${cycle}`;
        const edit = await measureAction(
          fixture.tapePath,
          () => session!.sendLiteralImmediate(marker),
          () => session!.waitForText(marker, TIMEOUT),
          marker,
        );
        session.sendKeysImmediate(["C-u"]);
        await session.waitForComposer(TIMEOUT);
        if (cycle >= WARMUPS) appendMeasured(samples.composerEdit, edit);
      }

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        const slashOpen = await measureAction(
          fixture.tapePath,
          () => session!.sendLiteralImmediate("/"),
          () => session!.waitForText("Results ", TIMEOUT),
          "Results ",
        );
        const slashQuery = await measureAction(
          fixture.tapePath,
          () => session!.sendLiteralImmediate("he"),
          () => session!.waitForPane(
            (pane) => composerContains(pane, "/he") &&
              pane.includes("show available slash commands"),
            TIMEOUT,
          ),
          "┃ /he",
        );
        await closeSurface(session, "Results ");
        if (cycle >= WARMUPS) {
          appendMeasured(samples.slashOpen, slashOpen);
          appendMeasured(samples.slashQuery, slashQuery);
        }
      }

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        const dollarOpen = await measureAction(
          fixture.tapePath,
          () => session!.sendLiteralImmediate("$"),
          () => session!.waitForText("Skills 289", TIMEOUT),
          "Skills 289",
        );
        const dollarQuery = await measureAction(
          fixture.tapePath,
          () => session!.sendLiteralImmediate("needle"),
          () => session!.waitForText("Skills 144", TIMEOUT),
          "Skills 144",
        );
        await closeSurface(session, "Skills ");
        if (cycle >= WARMUPS) {
          appendMeasured(samples.dollarOpen, dollarOpen);
          appendMeasured(samples.dollarQuery, dollarQuery);
        }
      }

      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        const fileQuery = await measureAction(
          fixture.tapePath,
          () => session!.sendLiteralImmediate("@performance"),
          () => session!.waitForText("performance-target.txt", TIMEOUT),
          "performance-target.txt",
        );
        await closeSurface(session, "performance-target.txt");
        if (cycle >= WARMUPS) appendMeasured(samples.fileQuery, fileQuery);
      }

      for (const action of LOCAL_MENU_ACTIONS) {
        for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
          await session.sendLiteralText(action.command);
          const before = await session.capturePane();
          const open = await measurePaneAction(
            () => session!.sendKeysImmediate(["Enter"]),
            () => waitForPaneText(session!, action.marker, before),
          );
          await closeSurface(session, action.marker);
          if (cycle >= WARMUPS) appendMeasured(samples[action.name], open);
        }
      }

      await session.sendText("Open the performance question.");
      await session.waitForText("Which performance path should I use?", TIMEOUT);
      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        const before = await session.capturePaneEscapes();
        const key = cycle % 2 === 0 ? "Down" : "Up";
        const navigation = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate([key]),
          () => waitForEscapedPaneChange(session!, before, `questionNavigate.${cycle}`),
        );
        if (cycle >= WARMUPS) appendMeasured(samples.questionNavigate, navigation);
      }
      session.sendKeysImmediate(["2"]);
      await session.waitForText("PERF_QUESTION_DONE", TIMEOUT);
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Open the performance approval.");
      await session.waitForText("touch performance-approval.txt", TIMEOUT);
      for (let cycle = 0; cycle < WARMUPS + SAMPLES; cycle += 1) {
        const before = await session.capturePaneEscapes();
        const key = cycle % 2 === 0 ? "Down" : "Up";
        const navigation = await measureAction(
          fixture.tapePath,
          () => session!.sendKeysImmediate([key]),
          () => waitForEscapedPaneChange(session!, before, `approvalNavigate.${cycle}`),
        );
        if (cycle >= WARMUPS) appendMeasured(samples.approvalNavigate, navigation);
      }
      session.sendKeysImmediate(["3"]);
      await session.waitForText("PERF_APPROVAL_DONE", TIMEOUT);
      await session.waitForComposer(TIMEOUT);

      await session.sendText("Start the performance terminal.");
      await session.waitForText("PERF_TERMINAL_READY", TIMEOUT);
      session.sendKeysImmediate(["1"]);
      await session.waitForText("PERF_TERMINAL_AGENT_READY", TIMEOUT);
      await session.waitForComposer(TIMEOUT);
      await session.sendText("Close the performance terminal.");
      await session.waitForText("shell stop", TIMEOUT);
      session.sendKeysImmediate(["1"]);
      await session.waitForText("PERF_TERMINAL_CLOSED", TIMEOUT);
      await session.waitForComposer(TIMEOUT);
      const resourcesBefore = await waitForResourceStability(pid);
      expect(resourcesBefore.threads - preFeatureResources.threads).toBeLessThanOrEqual(2);
      // Three terminal routes plus command-replay logs, commands, and tool-results routes.
      expect(resourcesBefore.descriptors - preFeatureResources.descriptors).toBeLessThanOrEqual(6);
      expect(resourcesBefore.rssKib - preFeatureResources.rssKib).toBeLessThan(16 * 1024);

      const peakResources = await peakResourcesWhile(pid, async () => {
        await session!.sendText("Build the second performance transcript.");
        await session!.waitForText("PERF_SECOND_TRANSCRIPT_TAIL", TIMEOUT);
      });
      const resourcesAfter = await waitForResourceQuiescence(pid, resourcesBefore);
      const report = {
        boundary: "recorded application stdin frame to recorded stdout frame",
        boundaryExceptions: {
          catalogMenus: "user input dispatch to changed exclusive catalog pane",
        },
        buildMode: "ReleaseSafe",
        warmups: WARMUPS,
        measuredSamples: SAMPLES,
        actions: MEASURED_ACTION_NAMES,
        terminal: { cols: 104, rows: 30 },
        fixture: {
          hash: fixture.fixtureHash,
          skills: 289,
          transcriptLines: 2_100,
          transcriptBytes: Buffer.byteLength(fixture.transcript),
        },
        budgetsMs: {
          local: LOCAL_BUDGETS_MS,
          backgroundWork: BACKGROUND_WORK_BUDGETS_MS,
          externalRefresh: EXTERNAL_REFRESH_BUDGETS_MS,
          appPane: APP_PANE_BUDGETS_MS,
        },
        informationalActions: [...INFORMATIONAL_PANE_ACTION_NAMES],
        results: Object.fromEntries(
          Object.entries(samples).map(([name, values]) => [name, {
            firstPaint: summary(values.firstPaint),
            contentReady: summary(values.contentReady),
          }]),
        ),
        resources: {
          preFeature: preFeatureResources,
          postWarmup: resourcesBefore,
          peak: peakResources,
          after: resourcesAfter,
        },
      };
      const reportPath = process.env.FX_TUI_PERFORMANCE_REPORT;
      if (reportPath) writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);

      for (const [name, values] of Object.entries(samples)) {
        const actionBudget = APP_PANE_ACTION_NAMES.has(name)
          ? APP_PANE_BUDGETS_MS
          : name === "skillsOpen" || name === "loginOpen"
          ? EXTERNAL_REFRESH_BUDGETS_MS
          : name === "fullScrollCacheMiss"
          ? BACKGROUND_WORK_BUDGETS_MS
          : LOCAL_BUDGETS_MS;
        for (const distribution of [values.firstPaint, values.contentReady]) {
          const measured = summary(distribution);
          expect(measured.count).toBe(SAMPLES);
          if (INFORMATIONAL_PANE_ACTION_NAMES.has(name)) continue;
          const budget = APP_PANE_ACTION_NAMES.has(name) || name === "fullScrollCacheMiss"
            ? actionBudget
            : distribution === values.firstPaint
            ? LOCAL_BUDGETS_MS
            : actionBudget;
          const phase = distribution === values.firstPaint ? "firstPaint" : "contentReady";
          if (measured.p50 > budget.p50 ||
              measured.p90 > budget.p90 ||
              measured.p95 > budget.p95) {
            throw new Error(
              `${name}.${phase} exceeded budget: ` +
                `measured=${measured.p50}/${measured.p90}/${measured.p95}ms ` +
                `budget=${budget.p50}/${budget.p90}/${budget.p95}ms`,
            );
          }
        }
      }
      expect(resourcesAfter.threads).toBe(resourcesBefore.threads);
      expect(resourcesAfter.descriptors).toBe(resourcesBefore.descriptors);
      expect(resourcesAfter.rssKib - resourcesBefore.rssKib).toBeLessThan(16 * 1024);
      expect(peakResources.threads - resourcesBefore.threads).toBeLessThanOrEqual(3);
      expect(peakResources.descriptors - resourcesBefore.descriptors).toBeLessThanOrEqual(
        ACTIVE_TURN_DESCRIPTOR_BUDGET,
      );
      expect(peakResources.rssKib - resourcesBefore.rssKib).toBeLessThan(32 * 1024);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    } finally {
      await session?.kill();
      gateway.stop();
      if (process.env.FX_TUI_PERFORMANCE_KEEP !== "1") {
        rmSync(fixture.root, { recursive: true, force: true });
      } else {
        console.error(`retained TUI performance fixture at ${fixture.root}`);
      }
    }
  },
  900_000,
);

test.skipIf(!LIVE_ENABLED || !tmuxAvailable())(
  "live provider preserves the fast menu and prepared transcript pipeline",
  async () => {
    const fixture = createFixture();
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: {
          HOME: fixture.home,
          AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY,
          VERCEL_OIDC_TOKEN: process.env.VERCEL_OIDC_TOKEN,
          FX_AUTO_UPGRADE: "0",
          FX_SOUND: "0",
          NO_COLOR: "1",
        },
        stderrPath: fixture.stderrPath,
        width: 104,
        height: 30,
        minimumHistoryLines: 20_000,
      });
      await session.waitForComposer(TIMEOUT);
      await session.sendText(
        "Write 120 short numbered lines, then write LIVE_PERFORMANCE_DONE on its own line.",
      );
      await session.waitForText("LIVE_PERFORMANCE_DONE", TIMEOUT);

      session.sendKeysImmediate(["C-o"]);
      await session.waitForText("Full detail · ctrl o close", TIMEOUT);
      session.sendKeysImmediate(["Up"]);
      await Bun.sleep(25);
      session.sendKeysImmediate(["Escape"]);
      await session.waitForComposer(TIMEOUT);

      await session.sendText("/skills");
      await session.waitForText("Skills 289", TIMEOUT);
      session.sendKeysImmediate(["Escape"]);
      await session.waitForComposer(TIMEOUT);

      session.sendKeysImmediate(["C-u"]);
      await session.waitForComposer(TIMEOUT);
      await session.sendLiteralText("/login ");
      await session.waitForPane(
        (pane) => pane.includes("vercel") && pane.includes("codex") && pane.includes("grok"),
        TIMEOUT,
      );
      session.sendKeysImmediate(["Escape"]);
      await session.waitForComposer(TIMEOUT);
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
    } finally {
      await session?.kill();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  180_000,
);
