import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { stdoutFrames, type TapeFrame } from "./render-lab/tape";
import { rootSessionIds, waitForRootTurnCommitted } from "./saved-sessions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeShellRun,
  startDynamicFakeGateway,
  startUpgradeServer,
  TmuxSession,
  tmuxAvailable,
  turnSettled,
} from "./tmux-helpers";

const TOKEN = "e2e-program-resume-token-0123";
const INVALID_TOKEN = "too-short";
const TIMEOUT = 30_000;
const UPGRADE_TIMEOUT = TIMEOUT * 2;
const TEST_TIMEOUT = 90_000;
const UPGRADE_TEST_TIMEOUT = 180_000;
const POLL_MS = 100;
const SIGHUP_EXIT_STATUS = 128 + 1;
const SIGTERM_EXIT_STATUS = 128 + 15;
const RESUME_TRACE = "report kind=resume";
const CLEAR_TRACE = "report kind=clear";
const UPDATE_READY_TEXT = "update ready: ctrl+g to reload";
const CLOCK_TOLERANCE_SECONDS = 600;
const FIRST_PROMPT = "program resume first prompt";
const SECOND_PROMPT = "program resume second prompt";
const FIRST_ANSWER = "PROGRAM_RESUME_FIRST_ANSWER";
const SECOND_ANSWER = "PROGRAM_RESUME_SECOND_ANSWER";
const PROBE_COMMAND = "printenv OSC7577_TOKEN; echo token-exit=$?";
const PROBE_EXIT_LINE = "token-exit=1";
const PROBE_CALL_ID = "program_resume_token_probe";

type FixtureRoot = {
  root: string;
  home: string;
  workspace: string;
  tape: string;
  trace: string;
  stderr: string;
};

type Gateway = ReturnType<typeof startDynamicFakeGateway>;

function createFixtureRoot(label: string): FixtureRoot {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-program-resume-${label}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    tape: join(root, "session.fxtape"),
    trace: join(root, "trace.log"),
    stderr: join(root, "stderr.log"),
  };
}

type LaunchOptions = {
  cmd?: string;
  env?: Record<string, string>;
};

function launchFx(
  fixture: FixtureRoot,
  gateway: Gateway,
  token: string,
  options: LaunchOptions = {},
): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: JSON.stringify(options.cmd ?? FX_BIN),
    cwd: fixture.workspace,
    isolated: true,
    stderrPath: fixture.stderr,
    env: {
      HOME: fixture.home,
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      AI_GATEWAY_API_KEY: "synthetic-program-resume",
      FX_AUTO_UPGRADE: "0",
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_PERMISSION_MODE: "full-access",
      FX_SOUND: "0",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_RECORD: fixture.tape,
      FX_TRACE_LOG: fixture.trace,
      FX_TRACE_SCOPES: "agent,app,core,gateway,program_resume,stream",
      OSC7577_TOKEN: token,
      ...options.env,
    },
  });
}

function filesUnder(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return filesUnder(path);
    return entry.isFile() ? [path] : [];
  });
}

function reportsIn(stdout: TapeFrame[]): string[] {
  const text = Buffer.concat(stdout.map((frame) => frame.payload)).toString("latin1");
  return [...text.matchAll(/\x1b\]7577;([^\x1b]*)\x1b\\/g)].map((match) => match[1]!);
}

function programResumeReports(tapePath: string): string[] {
  return reportsIn(stdoutFrames(tapePath));
}

function parseReport(report: string, token: string): Record<string, string> {
  const macAt = report.indexOf(":mac=");
  expect(macAt).toBeGreaterThan(0);
  const body = report.slice(0, macAt);
  const mac = report.slice(macAt + ":mac=".length);
  expect(mac).toBe(createHash("sha256").update(`${body}:${token}`).digest("hex"));
  return Object.fromEntries(body.split(":").map((field) => {
    const at = field.indexOf("=");
    return [field.slice(0, at), field.slice(at + 1)];
  }));
}

function decodeBase64(value: string): string {
  return Buffer.from(value, "base64").toString("utf8");
}

function expectRecentTime(seconds: string): void {
  expect(Math.abs(Date.now() / 1000 - Number(seconds))).toBeLessThanOrEqual(CLOCK_TOLERANCE_SECONDS);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitUntil(description: string, done: () => boolean, timeoutMs = TIMEOUT): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!done()) {
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for ${description}`);
    await sleep(POLL_MS);
  }
}

function readTrace(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

function countOf(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

function indexOfNth(text: string, needle: string, nth: number): number {
  let at = -1;
  for (let i = 0; i < nth; i += 1) at = text.indexOf(needle, at + 1);
  return at;
}

function processGone(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return false;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ESRCH";
  }
}

async function answerFirstPrompt(session: TmuxSession, fixture: FixtureRoot): Promise<void> {
  await session.waitForStableComposer(15_000);
  await session.sendText(FIRST_PROMPT);
  await session.waitForText(FIRST_ANSWER, TIMEOUT);
  await session.waitForPane(turnSettled, TIMEOUT);
  await waitForRootTurnCommitted(fixture.home, 0, TIMEOUT);
  await waitUntil("the first resume report", () => countOf(readTrace(fixture.trace), RESUME_TRACE) >= 1);
}

function expectResumeRecord(report: string, sessionId: string): Record<string, string> {
  const fields = parseReport(report, TOKEN);
  expect(Object.keys(fields)).toEqual(["pid", "time", "argv", "cwd"]);
  expect(fields.pid).toMatch(/^[1-9][0-9]*$/);
  expectRecentTime(fields.time!);
  const argv = fields.argv!.split(",").map(decodeBase64);
  expect(argv[1]).toBe("--resume");
  expect(basename(argv[2]!)).toBe(sessionId);
  return fields;
}

function expectClearRecord(report: string, pid: string): void {
  const fields = parseReport(report, TOKEN);
  expect(Object.keys(fields)).toEqual(["pid", "time", "clear"]);
  expect(fields.pid).toBe(pid);
  expect(fields.clear).toBe("1");
  expectRecentTime(fields.time!);
}

function expectRecordKept(fixture: FixtureRoot, sessionId: string, pid: number): void {
  const trace = readTrace(fixture.trace);
  expect(countOf(trace, RESUME_TRACE)).toBe(1);
  expect(countOf(trace, CLEAR_TRACE)).toBe(0);
  const reports = programResumeReports(fixture.tape);
  expect(reports).toHaveLength(1);
  expect(expectResumeRecord(reports[0]!, sessionId).pid).toBe(String(pid));
}

test.skipIf(!tmuxAvailable())(
  "reports how to resume the session and clears the record on quit",
  async () => {
    const fixture = createFixtureRoot("resume");
    const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText(FIRST_ANSWER));
    let session: TmuxSession | undefined;
    try {
      session = await launchFx(fixture, gateway, TOKEN);
      await session.waitForStableComposer(15_000);
      await session.sendText(FIRST_PROMPT);
      await session.waitForText(FIRST_ANSWER, TIMEOUT);
      await session.waitForPane(turnSettled, TIMEOUT);
      await waitForRootTurnCommitted(fixture.home, 0, TIMEOUT);

      const sessionIds = rootSessionIds(fixture.home);
      expect(sessionIds).toHaveLength(1);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);
      expect(readFileSync(fixture.stderr, "utf8")).toBe("");

      const reports = programResumeReports(fixture.tape);
      expect(reports).toHaveLength(2);
      const start = parseReport(reports[0]!, TOKEN);
      const clear = parseReport(reports[1]!, TOKEN);

      expect(Object.keys(start)).toEqual(["pid", "time", "argv", "cwd"]);
      expect(start.pid).toMatch(/^[1-9][0-9]*$/);
      expectRecentTime(start.time!);
      expect(start.argv!.split(",").map(decodeBase64)).toEqual([
        realpathSync(FX_BIN),
        "--resume",
        sessionIds[0],
      ]);
      expect(decodeBase64(start.cwd!)).toBe(fixture.workspace);

      expect(Object.keys(clear)).toEqual(["pid", "time", "clear"]);
      expect(clear.pid).toBe(start.pid);
      expect(clear.clear).toBe("1");
      expectRecentTime(clear.time!);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "keeps the token out of the programs fx starts and the files it writes",
  async () => {
    const fixture = createFixtureRoot("token-secrecy");
    const gateway = startDynamicFakeGateway((body) => {
      if (body.includes(SECOND_PROMPT)) return fakeGatewayFinalText(SECOND_ANSWER);
      if (body.includes(FIRST_PROMPT) && !body.includes(PROBE_EXIT_LINE)) {
        return fakeShellRun(PROBE_CALL_ID, PROBE_COMMAND);
      }
      return fakeGatewayFinalText(FIRST_ANSWER);
    });
    let session: TmuxSession | undefined;
    try {
      session = await launchFx(fixture, gateway, TOKEN);
      await session.waitForStableComposer(15_000);
      await session.sendText(FIRST_PROMPT);
      await session.waitForPane((pane) => pane.includes(FIRST_ANSWER) && turnSettled(pane), TIMEOUT);
      await session.sendKeys("C-o");
      await session.waitForText("esc close · pgup/pgdn scroll", TIMEOUT);
      await session.waitForText(PROBE_EXIT_LINE, TIMEOUT);
      await session.sendKeys("Escape");
      await session.waitForPane((pane) => !pane.includes("esc close · pgup/pgdn scroll"), TIMEOUT);

      await session.waitForStableComposer(15_000);
      await session.sendText(SECOND_PROMPT);
      await session.waitForText(SECOND_ANSWER, TIMEOUT);
      await session.waitForPane(turnSettled, TIMEOUT);
      await waitForRootTurnCommitted(fixture.home, 0, TIMEOUT);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);

      const reports = programResumeReports(fixture.tape);
      expect(reports.length).toBeGreaterThan(0);
      for (const report of reports) parseReport(report, TOKEN);

      for (const file of [fixture.trace, fixture.tape, fixture.stderr]) {
        expect(existsSync(file)).toBe(true);
      }
      const searched = [...filesUnder(fixture.home), fixture.trace, fixture.tape, fixture.stderr];
      const leaks = searched.filter((file) => readFileSync(file).includes(Buffer.from(TOKEN)));
      expect(leaks).toEqual([]);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "reports nothing when the token is invalid",
  async () => {
    const fixture = createFixtureRoot("invalid-token");
    const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText(FIRST_ANSWER));
    let session: TmuxSession | undefined;
    try {
      session = await launchFx(fixture, gateway, INVALID_TOKEN);
      await session.waitForStableComposer(15_000);
      await session.sendText(FIRST_PROMPT);
      await session.waitForText(FIRST_ANSWER, TIMEOUT);
      await session.waitForPane(turnSettled, TIMEOUT);
      await waitForRootTurnCommitted(fixture.home, 0, TIMEOUT);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);

      expect(stdoutFrames(fixture.tape).length).toBeGreaterThan(0);
      expect(programResumeReports(fixture.tape)).toEqual([]);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "a hang-up keeps the resume record",
  async () => {
    const fixture = createFixtureRoot("hang-up");
    const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText(FIRST_ANSWER));
    let session: TmuxSession | undefined;
    try {
      session = await launchFx(fixture, gateway, TOKEN);
      await answerFirstPrompt(session, fixture);
      const sessionIds = rootSessionIds(fixture.home);
      expect(sessionIds).toHaveLength(1);
      const pid = session.processPid();

      session.killPane();
      await waitUntil("fx to exit after its terminal hung up", () => processGone(pid));

      expectRecordKept(fixture, sessionIds[0]!, pid);
    } finally {
      await session?.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TEST_TIMEOUT,
);

const SIGNAL_EXIT_CASES = [
  { name: "SIGTERM keeps the resume record", signal: "SIGTERM", status: SIGTERM_EXIT_STATUS },
  {
    name: "SIGHUP with the terminal open keeps the resume record",
    signal: "SIGHUP",
    status: SIGHUP_EXIT_STATUS,
  },
] as const;

for (const { name, signal, status } of SIGNAL_EXIT_CASES) {
  test.skipIf(!tmuxAvailable())(
    name,
    async () => {
      const fixture = createFixtureRoot(signal.toLowerCase());
      const gateway = startDynamicFakeGateway(() => fakeGatewayFinalText(FIRST_ANSWER));
      let session: TmuxSession | undefined;
      try {
        session = await launchFx(fixture, gateway, TOKEN);
        await answerFirstPrompt(session, fixture);
        const sessionIds = rootSessionIds(fixture.home);
        expect(sessionIds).toHaveLength(1);
        const pid = session.processPid();

        process.kill(pid, signal);
        expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);

        expectRecordKept(fixture, sessionIds[0]!, pid);
        expect(session.recordedExitStatus()).toBe(status);
      } finally {
        await session?.kill();
        gateway.stop();
        rmSync(fixture.root, { recursive: true, force: true });
      }
    },
    TEST_TIMEOUT,
  );
}

test.skipIf(!tmuxAvailable())(
  "a Ctrl+G update restart keeps the record and the token",
  async () => {
    const fixture = createFixtureRoot("ctrl-g-restart");
    const installDir = join(fixture.root, "install");
    const installedFx = join(installDir, "fx");
    const argvLogPath = join(fixture.root, "upgrade-argv.log");
    const relaunchTape = join(fixture.root, "relaunch.fxtape");
    mkdirSync(installDir);
    copyFileSync(FX_BIN, installedFx);
    chmodSync(installedFx, 0o755);
    const gateway = startDynamicFakeGateway((body) => {
      if (body.includes(PROBE_EXIT_LINE)) return fakeGatewayFinalText(SECOND_ANSWER);
      if (body.includes(SECOND_PROMPT)) return fakeShellRun(PROBE_CALL_ID, PROBE_COMMAND);
      return fakeGatewayFinalText(FIRST_ANSWER);
    });
    const release = startUpgradeServer(fixture.root, argvLogPath, {
      relaunchEnv: { FX_RECORD: relaunchTape },
    });
    let session: TmuxSession | undefined;
    try {
      session = await launchFx(fixture, gateway, TOKEN, {
        cmd: installedFx,
        env: {
          FX_AUTO_UPGRADE: "1",
          FX_TEST_UPGRADE_BASE_URL: release.baseUrl,
        },
      });
      await answerFirstPrompt(session, fixture);
      const sessionIds = rootSessionIds(fixture.home);
      expect(sessionIds).toHaveLength(1);
      const pid = session.processPid();

      await session.waitForText(UPDATE_READY_TEXT, UPGRADE_TIMEOUT);
      await session.sendHexBytes(["07"]);
      await waitUntil(
        "the restarted fx to write its resume record",
        () => countOf(readTrace(fixture.trace), RESUME_TRACE) === 2,
        UPGRADE_TIMEOUT,
      );
      await session.waitForStableComposer(TIMEOUT);

      await session.sendText(SECOND_PROMPT);
      await session.waitForPane((pane) => pane.includes(SECOND_ANSWER) && turnSettled(pane), TIMEOUT);
      await session.sendKeys("C-o");
      await session.waitForText("esc close · pgup/pgdn scroll", TIMEOUT);
      await session.waitForText(PROBE_EXIT_LINE, TIMEOUT);
      await session.sendKeys("Escape");
      await session.waitForPane((pane) => !pane.includes("esc close · pgup/pgdn scroll"), TIMEOUT);
      await session.waitForStableComposer(15_000);
      await waitForRootTurnCommitted(fixture.home, 0, TIMEOUT);

      await session.sendText("/quit");
      expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);

      const trace = readTrace(fixture.trace);
      expect(countOf(trace, RESUME_TRACE)).toBe(2);
      expect(countOf(trace, CLEAR_TRACE)).toBe(1);
      expect(trace.indexOf(CLEAR_TRACE)).toBeGreaterThan(indexOfNth(trace, RESUME_TRACE, 2));

      const firstTape = programResumeReports(fixture.tape);
      expect(firstTape).toHaveLength(1);
      expect(expectResumeRecord(firstTape[0]!, sessionIds[0]!).pid).toBe(String(pid));

      const restartedTape = programResumeReports(relaunchTape);
      expect(restartedTape).toHaveLength(2);
      expect(expectResumeRecord(restartedTape[0]!, sessionIds[0]!).pid).toBe(String(pid));
      expectClearRecord(restartedTape[1]!, String(pid));

      const argvLines = readFileSync(argvLogPath, "utf8").trim().split("\n");
      expect(argvLines).toHaveLength(1);
      expect(argvLines[0]!.split("\t")).toContain("--upgrade-relaunch");
      expect(readFileSync(fixture.stderr, "utf8")).not.toContain("relaunch failed");
    } finally {
      await session?.kill();
      release.stop();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  UPGRADE_TEST_TIMEOUT,
);
