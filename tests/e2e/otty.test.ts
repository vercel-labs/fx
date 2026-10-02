import { expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startDynamicFakeGateway,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const RESPONSIVENESS_TIMEOUT = 5_000;
const SKIP = !["darwin", "linux"].includes(process.platform) || !tmuxAvailable();
const APPROVAL_PROMPT = "Would you like to run the following command?";
const QUESTION_PROMPT = "Continue the otty fixture?";
const IGNORED_OUTPUT = "OTTY_OUTPUT_MUST_BE_IGNORED";

type OttyReport = { argv: string[]; pid: number; ppid: number };

function shellQuote(value: string) {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function createFixture(hung = false) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-otty-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const bin = join(root, "bin");
  const logPath = join(root, "otty.jsonl");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace);
  mkdirSync(bin);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    permission_mode: "ask",
    sandbox: "none",
  }), { mode: 0o600 });
  writeFileSync(logPath, "");
  writeFileSync(stderrPath, "");

  const loggerPath = join(root, "log-argv.js");
  writeFileSync(loggerPath, `import { appendFileSync } from "node:fs";
appendFileSync(${JSON.stringify(logPath)}, JSON.stringify({
  argv: process.argv.slice(2), pid: process.pid, ppid: process.ppid,
}) + "\\n");
`);
  writeFileSync(join(bin, "otty"), hung
    ? `#!/bin/sh
printf '{"argv":[],"pid":%s,"ppid":%s}\\n' "$$" "$PPID" >> ${shellQuote(logPath)}
printf '%s\\n' '${IGNORED_OUTPUT}'
printf '%s\\n' '${IGNORED_OUTPUT}' >&2
exec /bin/sleep 60
`
    : `#!/bin/sh
exec ${shellQuote(process.execPath)} ${shellQuote(loggerPath)} "$@"
`, { mode: 0o755 });
  return { root, home, workspace, bin, logPath, stderrPath };
}

function fixtureEnv(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  return {
    HOME: fixture.home,
    PATH: `${fixture.bin}:${process.env.PATH ?? "/usr/bin:/bin"}`,
    AI_GATEWAY_API_KEY: "fake-otty-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_PERMISSION_MODE: "ask",
    FX_SOUND: "0",
    FX_AUTO_UPGRADE: "0",
    FX_OTTY: undefined,
    TERM_PROGRAM: "otty",
    NO_COLOR: "1",
  };
}

function readReports(path: string): OttyReport[] {
  return readFileSync(path, "utf8").split("\n").filter(Boolean)
    .map((line) => JSON.parse(line) as OttyReport);
}

function states(path: string) {
  return readReports(path).map((report) => report.argv[4]);
}

async function waitUntil(
  predicate: () => boolean,
  label: string,
  timeoutMs = TIMEOUT,
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await Bun.sleep(25);
  }
  throw new Error(`Timed out waiting for ${label}.`);
}

function holdResponse(response: Response) {
  let release!: () => void;
  const pending = new Promise<Response>((resolve) => {
    release = () => resolve(response);
  });
  return { next: () => pending, release };
}

function pidExists(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
    throw error;
  }
}

test.skipIf(SKIP)(
  "otty reports native TUI startup, processing, permission/question waits and fast completion in order",
  async () => {
    const fixture = createFixture();
    const marker = join(fixture.workspace, "permission-marker.txt");
    const toolGate = join(fixture.workspace, "resume-tool.txt");
    // Only the first response needs holding. The approved command stays live
    // until processing resumes, proving it precedes the next gateway request.
    const initial = holdResponse(fakeShellRun(
      "otty_permission_1",
      "touch permission-marker.txt; while [ ! -f resume-tool.txt ]; do sleep 0.05; done",
      { timeout_ms: TIMEOUT },
    ));
    const gateway = startFakeGateway([
      initial.next,
      fakeGatewayToolCall("otty_question_1", "ask_user_question", {
        questions: [{
          question: QUESTION_PROMPT,
          options: [{ label: "Continue" }, { label: "Stop" }],
        }],
      }),
      // Deliberately immediate: a late processing report must not follow idle.
      fakeGatewayFinalText("OTTY_TURN_COMPLETE"),
    ]);
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: fixtureEnv(fixture, gateway),
        stderrPath: fixture.stderrPath,
        remainOnExit: true,
      });
      await session.waitForComposer(TIMEOUT);
      await waitUntil(() => readReports(fixture.logPath).length >= 1, "startup idle");
      expect(states(fixture.logPath)).toEqual(["state=idle"]);
      expect(gateway.requestCount()).toBe(0);
      const fxPid = session.processPid();

      await session.sendText("Run the prepared command, then ask me whether to continue.");
      await waitUntil(
        () => gateway.requestCount() === 1 && readReports(fixture.logPath).length >= 2,
        "processing while the first gateway response is held",
      );
      expect(states(fixture.logPath)).toEqual(["state=idle", "state=processing"]);
      expect(existsSync(marker)).toBe(false);
      initial.release();

      await session.waitForText(APPROVAL_PROMPT, TIMEOUT);
      await waitUntil(() => readReports(fixture.logPath).length >= 3, "permission awaiting");
      expect(states(fixture.logPath)).toEqual([
        "state=idle", "state=processing", "state=awaiting",
      ]);
      expect(existsSync(marker)).toBe(false);
      expect(gateway.requestCount()).toBe(1);
      session.sendKeysImmediate(["1"]);
      await waitUntil(
        () => readReports(fixture.logPath).length >= 4,
        "processing immediately after permission approval",
      );
      expect(states(fixture.logPath)).toEqual([
        "state=idle", "state=processing", "state=awaiting", "state=processing",
      ]);
      await waitUntil(() => existsSync(marker), "approved command running");
      expect(gateway.requestCount()).toBe(1);
      writeFileSync(toolGate, "resume\n");

      await session.waitForText(QUESTION_PROMPT, TIMEOUT);
      await waitUntil(() => readReports(fixture.logPath).length >= 5, "question awaiting");
      expect(states(fixture.logPath)).toEqual([
        "state=idle", "state=processing", "state=awaiting", "state=processing",
        "state=awaiting",
      ]);
      session.sendKeysImmediate(["1"]);
      await session.waitForText("OTTY_TURN_COMPLETE", TIMEOUT);
      await waitUntil(() => readReports(fixture.logPath).length >= 7, "successful idle");
      await session.waitForStableComposer(TIMEOUT);
      expect(gateway.requestCount()).toBe(3);

      await session.sendText("/quit");
      await waitUntil(() => session!.paneStatus().dead, "/quit exit", RESPONSIVENESS_TIMEOUT);
      expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      // Shutdown joins the transport, so this also catches delayed reports
      // that would regress the fast final response from idle to processing.
      expect(states(fixture.logPath)).toEqual([
        "state=idle", "state=processing", "state=awaiting", "state=processing",
        "state=awaiting", "state=processing", "state=idle",
      ]);
      const reports = readReports(fixture.logPath);
      const sessionArg = reports[1]!.argv.find((arg) => arg.startsWith("session-id="));
      expect(sessionArg).toMatch(/^session-id=.+/);
      for (const [index, report] of reports.entries()) {
        const reportedSession = report.argv.find((arg) => arg.startsWith("session-id="));
        if (index > 0 || reportedSession !== undefined) {
          expect(reportedSession).toBe(sessionArg);
        }
        expect(report.argv).toEqual([
          "--timeout", "200", "state", "fx", report.argv[4]!, `agent-pid=${fxPid}`,
          ...(reportedSession === undefined ? [] : [reportedSession]), "label=fx",
        ]);
        expect(report.pid).not.toBe(fxPid);
        expect(report.ppid).toBe(fxPid);
      }
    } finally {
      writeFileSync(toolGate, "resume\n");
      initial.release();
      if (session) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(SKIP)(
  "otty resumes processing after child approval before the child tool completes",
  async () => {
    const fixture = createFixture();
    const marker = join(fixture.workspace, "child-permission-marker.txt");
    const toolGate = join(fixture.workspace, "resume-child-tool.txt");
    const initial = holdResponse(fakeGatewayToolCall("otty_child_start", "subagent", {
      request: {
        action: "message",
        agent: "worker",
        message: "Run the prepared child command and report its result.",
      },
    }));
    let parentCalls = 0;
    let childCalls = 0;
    const gateway = startDynamicFakeGateway((raw) => {
      if (!raw.includes('"name":"subagent"')) {
        childCalls++;
        if (childCalls === 1) {
          return fakeShellRun(
            "otty_child_permission",
            "touch child-permission-marker.txt; while [ ! -f resume-child-tool.txt ]; do sleep 0.05; done; printf OTTY_CHILD_TOOL_COMPLETE",
            { timeout_ms: TIMEOUT },
          );
        }
        return fakeGatewayFinalText("OTTY_CHILD_COMPLETE");
      }
      parentCalls++;
      if (parentCalls === 1) return initial.next();
      return fakeGatewayFinalText("OTTY_PARENT_COMPLETE");
    });
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: fixtureEnv(fixture, gateway),
        stderrPath: fixture.stderrPath,
        remainOnExit: true,
        isolated: true,
      });
      await session.waitForComposer(TIMEOUT);
      await waitUntil(() => readReports(fixture.logPath).length >= 1, "startup idle");
      expect(states(fixture.logPath)).toEqual(["state=idle"]);

      await session.sendText("Start a child to run the prepared command and wait for its result.");
      await waitUntil(
        () => parentCalls === 1 && readReports(fixture.logPath).length >= 2,
        "parent processing before starting the child",
      );
      expect(states(fixture.logPath)).toEqual(["state=idle", "state=processing"]);
      initial.release();

      await session.waitForText(APPROVAL_PROMPT, TIMEOUT);
      await waitUntil(() => readReports(fixture.logPath).length >= 3, "child permission awaiting");
      expect(states(fixture.logPath)).toEqual([
        "state=idle", "state=processing", "state=awaiting",
      ]);
      expect(childCalls).toBe(1);
      expect(parentCalls).toBe(1);
      expect(existsSync(marker)).toBe(false);
      session.sendKeysImmediate(["1"]);
      await waitUntil(() => existsSync(marker), "approved child command running");
      await waitUntil(
        () => states(fixture.logPath).at(-1) === "state=processing",
        "processing after child approval while the child command is gated",
        RESPONSIVENESS_TIMEOUT,
      ).catch((error) => {
        throw new Error(`${error}\nOtty states: ${JSON.stringify(states(fixture.logPath))}`);
      });
      expect(states(fixture.logPath)).toEqual([
        "state=idle", "state=processing", "state=awaiting", "state=processing",
      ]);
      expect(existsSync(toolGate)).toBe(false);
      expect(childCalls).toBe(1);
      expect(parentCalls).toBe(1);

      writeFileSync(toolGate, "resume\n");
      await session.waitForText("OTTY_PARENT_COMPLETE", TIMEOUT);
      await waitUntil(() => states(fixture.logPath).at(-1) === "state=idle", "successful idle");
      await session.waitForStableComposer(TIMEOUT);
      expect(childCalls).toBe(2);
      expect(parentCalls).toBe(2);
      expect(gateway.requests.find(({ body }) => body.includes('"toolCallId":"otty_child_permission"'))?.body)
        .toContain("OTTY_CHILD_TOOL_COMPLETE");
      expect(gateway.requests.at(-1)!.body).toContain("OTTY_CHILD_COMPLETE");

      await session.sendText("/quit");
      await waitUntil(() => session!.paneStatus().dead, "/quit exit", RESPONSIVENESS_TIMEOUT);
      expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      expect(states(fixture.logPath)).toEqual([
        "state=idle", "state=processing", "state=awaiting", "state=processing", "state=idle",
      ]);
    } finally {
      writeFileSync(toolGate, "resume\n");
      initial.release();
      if (session) await session.kill();
      gateway.stop();
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);

test.skipIf(SKIP)(
  "hung otty cannot stall a native TUI turn or bounded /quit and leaves no direct child",
  async () => {
    const fixture = createFixture(true);
    const gateway = startFakeGateway([fakeGatewayFinalText("OTTY_HUNG_TURN_COMPLETE")]);
    let session: TmuxSession | null = null;
    try {
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: fixture.workspace,
        env: fixtureEnv(fixture, gateway),
        stderrPath: fixture.stderrPath,
        remainOnExit: true,
        startupWaitMs: 0,
      });
      await session.waitForComposer(RESPONSIVENESS_TIMEOUT);
      await waitUntil(
        () => readReports(fixture.logPath).length > 0,
        "hung otty child launch",
        RESPONSIVENESS_TIMEOUT,
      );
      const fxPid = session.processPid();
      const turnStarted = Date.now();
      await session.sendText("Finish this turn without waiting for otty.");
      await session.waitForText("OTTY_HUNG_TURN_COMPLETE", RESPONSIVENESS_TIMEOUT);
      await session.waitForStableComposer(RESPONSIVENESS_TIMEOUT);
      expect(Date.now() - turnStarted).toBeLessThan(RESPONSIVENESS_TIMEOUT);
      expect(gateway.requestCount()).toBe(1);

      const quitStarted = Date.now();
      await session.sendText("/quit");
      await waitUntil(() => session!.paneStatus().dead, "bounded /quit", RESPONSIVENESS_TIMEOUT);
      expect(Date.now() - quitStarted).toBeLessThan(RESPONSIVENESS_TIMEOUT);
      expect(session.paneStatus()).toEqual({ dead: true, status: 0 });
      expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
      expect(await session.captureFullScrollback()).not.toContain(IGNORED_OUTPUT);
      const children = readReports(fixture.logPath);
      expect(children.length).toBeGreaterThan(0);
      for (const child of children) {
        expect(child.ppid).toBe(fxPid);
        expect(child.pid).not.toBe(fxPid);
        expect(pidExists(child.pid)).toBe(false);
      }
    } finally {
      if (session) await session.kill();
      gateway.stop();
      // Keep a failed regression from leaking the fixture's exec-sleep child.
      for (const child of readReports(fixture.logPath)) {
        if (pidExists(child.pid)) process.kill(child.pid, "SIGKILL");
      }
      rmSync(fixture.root, { recursive: true, force: true });
    }
  },
  TIMEOUT,
);
