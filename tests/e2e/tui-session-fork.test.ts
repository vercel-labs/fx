import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import {
  TmuxSession,
  fakeGatewayFinalText,
  heldFakeGatewayFinalText,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 90_000;
const STEP_TIMEOUT = 20_000;
const MODEL = "openai/gpt-5";

type Gateway = ReturnType<typeof startFakeGateway>;

let session: TmuxSession | null = null;
let gateway: Gateway | null = null;
const workDirs: string[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  gateway?.stop();
  gateway = null;
  for (const dir of workDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function makeWorkspace(prefix: string) {
  const workDir = mkdtempSync(join(tmpdir(), prefix));
  workDirs.push(workDir);
  const home = join(workDir, "home");
  const workspace = join(workDir, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  return { workDir, home, workspace, stderrPath: join(workDir, "stderr.log") };
}

function gatewayEnvironment(home: string) {
  if (!gateway) throw new Error("fake gateway not started");
  return {
    HOME: home,
    AI_GATEWAY_API_KEY: "fx-session-fork-e2e-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: MODEL,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

// Starts a shell whose model answers each prompt with the matching reply.
async function startShell(replies: string[], prefix: string) {
  const workspace = makeWorkspace(prefix);
  gateway = startFakeGateway(replies.map((text) => fakeGatewayFinalText(text)));
  session = await TmuxSession.create({
    cmd: FX_BIN,
    cwd: workspace.workspace,
    env: gatewayEnvironment(workspace.home),
    stderrPath: workspace.stderrPath,
    width: 120,
    height: 40,
    isolated: true,
  });
  await session.waitForComposer(STEP_TIMEOUT);
  return workspace;
}

async function ask(prompt: string, reply: string) {
  await session!.sendText(prompt);
  await session!.waitForText(reply, STEP_TIMEOUT);
}

// Session ids wrap across pane rows, so compare against the pane with every
// space and line break removed.
async function flatPane(): Promise<string> {
  return (await session!.capturePaneGrid()).join("").replace(/\s+/g, "");
}

async function savedSessions(home: string, workspace: string) {
  const listed = await runFx(["sessions", "--json"], {
    cwd: workspace,
    env: { HOME: home },
  });
  expect(listed.code).toBe(0);
  const ids: string[] = JSON.parse(listed.stdout).sessions.map(
    (entry: { id: string }) => entry.id,
  );
  const details = [];
  for (const id of ids) {
    const detail = await runFx(["session", "--id", id, "--json"], {
      cwd: workspace,
      env: { HOME: home },
    });
    expect(detail.code).toBe(0);
    const parsed = JSON.parse(detail.stdout);
    details.push({
      id: parsed.id as string,
      prompts: parsed.history.map(
        (turn: { user: { text: string } }) => turn.user.text,
      ) as string[],
    });
  }
  return details;
}

async function quitShell(stderrPath: string) {
  await session!.sendText("/quit");
  expect(await session!.waitForSessionEnd(STEP_TIMEOUT)).toBe(true);
  await session!.kill();
  session = null;
  expect(readFileSync(stderrPath, "utf8")).toBe("");
}

describe("interactive session fork and rewind", () => {
  test(
    "a bare /fork or /rewind names its argument instead of acting",
    async () => {
      const { home, workspace, stderrPath } = await startShell(
        ["REPLY_ONE"],
        "fx-tui-fork-usage-",
      );
      await ask("first prompt", "REPLY_ONE");

      await session!.sendText("/fork");
      await session!.waitForText("Use: /fork <turn>", STEP_TIMEOUT);
      await session!.sendText("/rewind");
      await session!.waitForText("Use: /rewind <count>", STEP_TIMEOUT);
      expect(await flatPane()).toContain("Run`fxsession");

      await quitShell(stderrPath);
      const saved = await savedSessions(home, workspace);
      expect(saved).toHaveLength(1);
      expect(saved[0]!.prompts).toEqual(["first prompt"]);
    },
    TIMEOUT,
  );

  test(
    "/rewind drops turns only when the identical request is repeated",
    async () => {
      const { home, workspace, stderrPath } = await startShell(
        ["REPLY_ONE", "REPLY_TWO", "REPLY_THREE"],
        "fx-tui-rewind-confirm-",
      );
      await ask("first prompt", "REPLY_ONE");
      await ask("second prompt", "REPLY_TWO");
      await ask("third prompt", "REPLY_THREE");

      await session!.sendText("/rewind 1");
      const armed = await session!.waitForText(
        "Run /rewind 1 again to confirm",
        STEP_TIMEOUT,
      );
      expect(armed).toContain("File changes are not reverted");

      // An intervening command cancels the arming, so the next request has to
      // ask again rather than executing.
      await session!.sendText("/version");
      await session!.waitForText("Version:", STEP_TIMEOUT);
      await session!.sendText("/rewind 1");
      await session!.waitForText("Run /rewind 1 again to confirm", STEP_TIMEOUT);

      await session!.sendText("/rewind 1");
      const done = await session!.waitForText(
        "Rewound 1 turn; 2 turns left",
        STEP_TIMEOUT,
      );
      expect(done).toContain("File changes were not reverted");

      await quitShell(stderrPath);
      const saved = await savedSessions(home, workspace);
      expect(saved).toHaveLength(1);
      expect(saved[0]!.prompts).toEqual(["first prompt", "second prompt"]);
    },
    TIMEOUT,
  );

  test(
    "/rewind past the live history reports the real turn count and changes nothing",
    async () => {
      const { home, workspace, stderrPath } = await startShell(
        ["REPLY_ONE", "REPLY_TWO"],
        "fx-tui-rewind-range-",
      );
      await ask("first prompt", "REPLY_ONE");
      await ask("second prompt", "REPLY_TWO");

      await session!.sendText("/rewind 9");
      await session!.waitForText(
        "cannot rewind 9 turns; session has 2 turns",
        STEP_TIMEOUT,
      );

      await quitShell(stderrPath);
      const saved = await savedSessions(home, workspace);
      expect(saved).toHaveLength(1);
      expect(saved[0]!.prompts).toEqual(["first prompt", "second prompt"]);
    },
    TIMEOUT,
  );

  test(
    "/fork reports both ids and continues in the branch",
    async () => {
      const { home, workspace, stderrPath } = await startShell(
        ["REPLY_ONE", "REPLY_TWO", "REPLY_THREE", "REPLY_BRANCH"],
        "fx-tui-fork-branch-",
      );
      await ask("first prompt", "REPLY_ONE");
      await ask("second prompt", "REPLY_TWO");
      await ask("third prompt", "REPLY_THREE");

      const before = await savedSessions(home, workspace);
      expect(before).toHaveLength(1);
      const sourceId = before[0]!.id;

      await session!.sendText("/fork 2");
      await session!.waitForText("You are now in the branch", STEP_TIMEOUT);

      const after = await savedSessions(home, workspace);
      expect(after).toHaveLength(2);
      const branch = after.find((entry) => entry.id !== sourceId)!;
      expect(branch.prompts).toEqual(["first prompt", "second prompt"]);

      const pane = await flatPane();
      expect(pane).toContain(sourceId);
      expect(pane).toContain(branch.id);
      expect(pane).toContain(`atturn2into`);

      // The next prompt has to land in the branch, not in the source.
      await ask("branch prompt", "REPLY_BRANCH");
      await quitShell(stderrPath);

      const final = await savedSessions(home, workspace);
      expect(final.find((entry) => entry.id === sourceId)!.prompts).toEqual([
        "first prompt",
        "second prompt",
        "third prompt",
      ]);
      expect(final.find((entry) => entry.id === branch.id)!.prompts).toEqual([
        "first prompt",
        "second prompt",
        "branch prompt",
      ]);
    },
    TIMEOUT,
  );

  test(
    "both commands refuse while a response is still streaming",
    async () => {
      const workspace = makeWorkspace("fx-tui-fork-streaming-");
      const held = heldFakeGatewayFinalText();
      gateway = startFakeGateway([
        fakeGatewayFinalText("REPLY_ONE"),
        held.response,
      ]);
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspace.workspace,
        env: gatewayEnvironment(workspace.home),
        stderrPath: workspace.stderrPath,
        width: 120,
        height: 40,
        isolated: true,
      });
      await session.waitForComposer(STEP_TIMEOUT);
      await ask("first prompt", "REPLY_ONE");

      await session.sendText("second prompt");
      await session.waitForText("second prompt", STEP_TIMEOUT);

      await session.sendText("/fork 1");
      await session.waitForText(
        "fork is unavailable until the response finishes",
        STEP_TIMEOUT,
      );
      await session.sendText("/rewind 1");
      await session.waitForText(
        "rewind is unavailable until the response finishes",
        STEP_TIMEOUT,
      );

      held.release("REPLY_TWO");
      await session.waitForText("REPLY_TWO", STEP_TIMEOUT);

      await quitShell(workspace.stderrPath);
      const saved = await savedSessions(workspace.home, workspace.workspace);
      expect(saved).toHaveLength(1);
      expect(saved[0]!.prompts).toEqual(["first prompt", "second prompt"]);
    },
    TIMEOUT,
  );

  test(
    "/fork past the live history reports the real turn count and creates nothing",
    async () => {
      const { home, workspace, stderrPath } = await startShell(
        ["REPLY_ONE", "REPLY_TWO"],
        "fx-tui-fork-range-",
      );
      await ask("first prompt", "REPLY_ONE");
      await ask("second prompt", "REPLY_TWO");

      await session!.sendText("/fork 9");
      await session!.waitForText(
        "turn 9 is out of range; session has 2 turns",
        STEP_TIMEOUT,
      );

      await quitShell(stderrPath);
      const saved = await savedSessions(home, workspace);
      expect(saved).toHaveLength(1);
      expect(saved[0]!.prompts).toEqual(["first prompt", "second prompt"]);
    },
    TIMEOUT,
  );
});
