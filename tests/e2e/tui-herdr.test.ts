import { afterEach, expect, test } from "bun:test";
import {
  chmodSync,
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
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const COMMAND_APPROVAL_PROMPT = "Would you like to run the following command?";
const QUESTION_PROMPT = "Run the prepared command?";
const PANE_ID = "w1:p1";

type HerdrRequest = {
  method: string;
  params: Record<string, unknown>;
};

type Status = { state: unknown; message: unknown };

const cleanups: Array<() => void | Promise<void>> = [];

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()!();
});

function createFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-herdr-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const profile = join(home, ".fx");
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  chmodSync(profile, 0o700);
  const settingsPath = join(profile, "settings.json");
  writeFileSync(settingsPath, JSON.stringify({ permission_mode: "ask" }), { mode: 0o600 });
  const stderrPath = join(root, "stderr.log");
  writeFileSync(stderrPath, "");
  // Keep the socket path short: macOS limits Unix socket paths to 104 bytes.
  const socketPath = join("/tmp", `fx-herdr-${process.pid}-${Date.now()}.sock`);
  cleanups.push(() => {
    rmSync(root, { recursive: true, force: true });
    rmSync(socketPath, { force: true });
  });
  return { home, workspace: realpathSync(workspace), stderrPath, socketPath };
}

function startFakeHerdr(socketPath: string) {
  const requests: HerdrRequest[] = [];
  const listener = Bun.listen<{ pending: string }>({
    unix: socketPath,
    socket: {
      open(socket) {
        socket.data = { pending: "" };
      },
      data(socket, chunk) {
        socket.data.pending += chunk.toString();
        let newline = socket.data.pending.indexOf("\n");
        while (newline >= 0) {
          const request = JSON.parse(socket.data.pending.slice(0, newline));
          socket.data.pending = socket.data.pending.slice(newline + 1);
          requests.push({ method: request.method, params: request.params });
          socket.write(`${JSON.stringify({ id: request.id, result: {} })}\n`);
          newline = socket.data.pending.indexOf("\n");
        }
      },
    },
  });
  cleanups.push(() => listener.stop(true));
  return requests;
}

function fxEnv(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
  herdr: Record<string, string | undefined>,
) {
  return {
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "fake-herdr-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
    HERDR_ENV: undefined,
    HERDR_SOCKET_PATH: undefined,
    HERDR_PANE_ID: undefined,
    HERDR_BIN_PATH: undefined,
    FX_HERDR: undefined,
    ...herdr,
  };
}

function statuses(requests: HerdrRequest[]): Status[] {
  return requests
    .filter((request) => request.method === "pane.report_agent")
    .map((request) => ({ state: request.params.state, message: request.params.message }));
}

async function waitFor(description: string, predicate: () => boolean, timeoutMs = TIMEOUT) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (predicate()) return;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${description}`);
}

async function startSession(
  fixture: ReturnType<typeof createFixture>,
  env: Record<string, string | undefined>,
) {
  const session = await TmuxSession.create({
    cmd: FX_BIN,
    cwd: fixture.workspace,
    env,
    stderrPath: fixture.stderrPath,
  });
  cleanups.push(() => session.kill());
  await session.waitForComposer(TIMEOUT);
  return session;
}

test.skipIf(!tmuxAvailable())(
  "herdr follows fx through a question and an approval and releases the pane on quit",
  async () => {
    const fixture = createFixture();
    const requests = startFakeHerdr(fixture.socketPath);
    const gateway = startFakeGateway([
      fakeGatewayToolCall("herdr_question_1", "ask_user_question", {
        questions: [
          {
            question: QUESTION_PROMPT,
            options: [
              { label: "Run it", description: "Run the prepared command." },
              { label: "Skip it", description: "Leave the workspace alone." },
            ],
          },
        ],
      }),
      fakeShellRun("herdr_approval_1", "sleep 1 && touch herdr-marker.txt", {
        timeout_ms: 600_000,
      }),
      fakeGatewayFinalText("HERDR_TURN_COMPLETE"),
    ]);
    cleanups.push(() => gateway.stop());

    const session = await startSession(
      fixture,
      fxEnv(fixture, gateway, {
        HERDR_ENV: "1",
        HERDR_SOCKET_PATH: fixture.socketPath,
        HERDR_PANE_ID: PANE_ID,
      }),
    );
    await waitFor("the startup idle report", () => statuses(requests).at(-1)?.state === "idle");

    await session.sendText("Run the prepared herdr command.");
    await session.waitForText(QUESTION_PROMPT, TIMEOUT);
    await waitFor("the question block", () => statuses(requests).at(-1)?.state === "blocked");
    expect(statuses(requests).at(-1)).toEqual({ state: "blocked", message: "Waiting for an answer" });

    await session.sendKeys("Enter");
    await session.waitForText(COMMAND_APPROVAL_PROMPT, TIMEOUT);
    await waitFor(
      "the approval block",
      () => statuses(requests).at(-1)?.message === "Waiting for approval",
    );
    expect(statuses(requests).at(-1)).toEqual({ state: "blocked", message: "Waiting for approval" });

    await session.sendKeys("1");
    await waitFor("work to resume after approval", () => statuses(requests).at(-1)?.state === "working");
    await session.waitForText("HERDR_TURN_COMPLETE", TIMEOUT);
    await waitFor("the finished turn", () => statuses(requests).at(-1)?.state === "idle");
    expect(existsSync(join(fixture.workspace, "herdr-marker.txt"))).toBe(true);

    await session.sendText("/quit");
    await waitFor("the pane release", () => requests.at(-1)?.method === "pane.release_agent");
    expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);

    // Each hold is reported with its reason, the approved command runs as
    // working, and the turn ends idle.
    const reported = statuses(requests);
    const messages = reported.map((status) => status.message).filter(Boolean);
    expect(reported[0]).toEqual({ state: "idle", message: undefined });
    expect(messages).toEqual(["Waiting for an answer", "Waiting for approval"]);
    const lastBlockedAt = reported.map((status) => status.state).lastIndexOf("blocked");
    expect(reported.slice(lastBlockedAt + 1).map((status) => status.state)).toEqual([
      "working",
      "idle",
    ]);

    let lastSeq = 0;
    for (const request of requests) {
      expect(["pane.report_agent", "pane.report_agent_session", "pane.release_agent"]).toContain(
        request.method,
      );
      expect(request.params.pane_id).toBe(PANE_ID);
      expect(request.params.source).toBe("custom:fx");
      expect(request.params.agent).toBe("fx");
      expect(request.params).not.toHaveProperty("custom_status");
      expect(Number(request.params.seq)).toBeGreaterThan(lastSeq);
      lastSeq = Number(request.params.seq);
    }

    // herdr can resume the pane's session: the session report names a saved
    // session and the final status report carries it.
    const sessionReport = requests.find((request) => request.method === "pane.report_agent_session");
    const sessionId = String(sessionReport?.params.agent_session_id);
    expect(sessionReport?.params.session_start_source).toBe("startup");
    expect(existsSync(join(fixture.home, ".fx", "sessions", sessionId))).toBe(true);
    const finalReport = requests.filter((request) => request.method === "pane.report_agent").at(-1);
    expect(finalReport?.params.agent_session_id).toBe(sessionId);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT * 2,
);

test.skipIf(!tmuxAvailable())(
  "fx never contacts herdr without HERDR_ENV=1",
  async () => {
    const fixture = createFixture();
    const requests = startFakeHerdr(fixture.socketPath);
    const gateway = startFakeGateway([fakeGatewayFinalText("OUTSIDE_HERDR_COMPLETE")]);
    cleanups.push(() => gateway.stop());

    const session = await startSession(
      fixture,
      fxEnv(fixture, gateway, {
        HERDR_SOCKET_PATH: fixture.socketPath,
        HERDR_PANE_ID: PANE_ID,
      }),
    );
    await session.sendText("Finish without herdr.");
    await session.waitForText("OUTSIDE_HERDR_COMPLETE", TIMEOUT);
    await session.sendText("/quit");
    expect(await session.waitForSessionEnd(TIMEOUT)).toBe(true);

    expect(requests).toEqual([]);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT * 2,
);
