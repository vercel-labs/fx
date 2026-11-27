import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { stdoutFrames, type TapeFrame } from "./render-lab/tape";
import { rootSessionIds, waitForRootTurnCommitted } from "./saved-sessions";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeShellRun,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
  turnSettled,
} from "./tmux-helpers";

const TOKEN = "e2e-program-resume-token-0123";
const INVALID_TOKEN = "too-short";
const TIMEOUT = 30_000;
const TEST_TIMEOUT = 90_000;
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

function launchFx(fixture: FixtureRoot, gateway: Gateway, token: string): Promise<TmuxSession> {
  return TmuxSession.create({
    cmd: JSON.stringify(FX_BIN),
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
      FX_TRACE_SCOPES: "agent,core,gateway,stream",
      OSC7577_TOKEN: token,
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
        realpathSync(join(fixture.home, ".fx", "sessions", "v2", sessionIds[0]!)),
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
