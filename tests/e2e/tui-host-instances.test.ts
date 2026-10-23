import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewaySse,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

// One fx process hosting several identical fx instances: each has its own
// session and conversation, Alt+Left and Alt+Right switch between them, and
// every instance takes prompts and session commands the same way, the first
// one included.

const TIMEOUT = 90_000;

function text(id: string, delta: string): Response {
  return fakeGatewaySse([
    { type: "text-delta", id, delta },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
  ]);
}

function userTexts(body: string): string[] {
  const request = JSON.parse(body) as { prompt?: Array<{ role?: string; content?: unknown }> };
  return (request.prompt ?? []).filter((message) => message.role === "user").map((message) => {
    if (typeof message.content === "string") return message.content;
    if (!Array.isArray(message.content)) return "";
    return message.content.map((part: any) => (typeof part?.text === "string" ? part.text : "")).join("");
  });
}

// Each prompt names its instance as HOST_<letter>; the answer echoes it.
function letterOf(body: string): string {
  return userTexts(body).at(-1)?.match(/HOST_([A-Z])/)?.[1] ?? "X";
}

function answerByLetter(body: string): Response {
  const letter = letterOf(body);
  return text(`answer_${letter}`, `HOST_ANSWER_${letter}`);
}

interface Host {
  home: string;
  workspace: string;
  session: TmuxSession;
}

async function withHost(
  respond: (body: string) => Response | Promise<Response>,
  options: {
    args?: string;
    instances?: number;
    env?: Record<string, string>;
    remainOnExit?: boolean;
    // Reuse a profile and workspace across runs; the caller removes them.
    reuse?: { home: string; workspace: string };
  },
  run: (host: Host) => Promise<void>,
): Promise<string[]> {
  const gateway = startDynamicFakeGateway(respond);
  const home = options.reuse?.home ?? createIsolatedTestHome();
  const workspace = options.reuse?.workspace ?? realpathSync(mkdtempSync(join(tmpdir(), "fx-host-instances-")));
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none" }));
  let session: TmuxSession | null = null;
  try {
    session = await TmuxSession.create({
      cmd: options.args ? `${JSON.stringify(FX_BIN)} ${options.args}` : FX_BIN,
      cwd: workspace,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-host-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "auto",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        ...(options.instances ? { FX_TEST_INSTANCES: String(options.instances) } : {}),
        ...options.env,
      },
      width: 120,
      height: 40,
      remainOnExit: options.remainOnExit ?? false,
    });
    await session.waitForComposer(30_000);
    await run({ home, workspace, session });
    return gateway.requests.map((request) => request.body);
  } finally {
    gateway.stop();
    try {
      if (session) await session.kill();
    } finally {
      if (!options.reuse) {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    }
  }
}

const ANSWERS = ["A", "B", "C", "D"].map((letter) => `HOST_ANSWER_${letter}`);

// The tools a request offered the model, by name.
function toolNames(body: string): string[] {
  const request = JSON.parse(body) as { tools?: Array<{ name?: string }> };
  return (request.tools ?? []).map((tool) => tool.name ?? "");
}

// Whether the request's last message is a tool result, so the model's call
// has been answered.
function answered(body: string): boolean {
  const request = JSON.parse(body) as { prompt?: Array<{ role?: string }> };
  return request.prompt?.at(-1)?.role === "tool";
}

function call(id: string, tool: string, input: object): Response {
  return fakeGatewaySse([
    { type: "tool-call", toolCallId: id, toolName: tool, input },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
}

// Saves agent profile `name` under the test home's `~/.fx/agents`.
function writeProfile(home: string, name: string, profile: object) {
  const dir = join(home, ".fx", "agents", name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "profile.json"), JSON.stringify(profile));
}

const COMMAND_APPROVAL_PROMPT = "Would you like to run the following command?";

// The saved session in `sessions/v2/<id>` whose files hold `marker`, by id.
function sessionHolding(home: string, marker: string): string | null {
  const holds = (path: string): boolean => readdirSync(path).some((entry) => {
    const full = join(path, entry);
    return statSync(full).isDirectory() ? holds(full) : readFileSync(full, "latin1").includes(marker);
  });
  const dir = join(home, ".fx", "sessions", "v2");
  if (!existsSync(dir)) return null;
  const ids = readdirSync(dir).filter((id) => !id.startsWith(".") && statSync(join(dir, id)).isDirectory());
  return ids.find((id) => holds(join(dir, id))) ?? null;
}

// The host records in `home`, each as its file's session ids.
function hostRecords(home: string): string[][] {
  const dir = join(home, ".fx", "hosts");
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => (JSON.parse(readFileSync(join(dir, name), "utf8")) as { sessions: string[] }).sessions);
}

// Runs three instances in `home`, prompts each as HOST_A, HOST_B, and
// HOST_C, and quits; returns their session ids.
async function saveGroup(home: string, workspace: string): Promise<string[]> {
  await withHost(answerByLetter, { instances: 3, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
    for (const [index, letter] of ["A", "B", "C"].entries()) {
      if (index > 0) {
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes(`fx ${index + 1}/3`), 15_000);
        await session.waitForComposer(15_000);
      }
      await session.sendText(`HOST_${letter} first run`);
      await session.waitForText(`HOST_ANSWER_${letter}`, 30_000);
    }
    await quitWith(session, "/exit");
  });
  return ["A", "B", "C"].map((letter) => sessionHolding(home, `HOST_ANSWER_${letter}`)!);
}

// Waits for fx to exit after `command` and returns what it printed last.
async function quitWith(session: TmuxSession, command: string): Promise<string> {
  await session.sendText(command);
  const deadline = Date.now() + 15_000;
  while (!session.paneStatus().dead) {
    if (Date.now() > deadline) throw new Error(`fx did not exit after ${command}`);
    await Bun.sleep(50);
  }
  return (await session.captureFullScrollback()).replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");
}

// Each prompt names a turn as PERM_<n> and a command to run. The model runs
// it with the shell tool, then answers PERM_DONE_<n> once the tool result is
// back.
function runThenAnswer(body: string): Response {
  const request = JSON.parse(body) as { prompt?: Array<{ role?: string }> };
  const turn = userTexts(body).at(-1)?.match(/PERM_(\d+)/)?.[1] ?? "0";
  if (request.prompt?.at(-1)?.role === "tool") return text(`done_${turn}`, `PERM_DONE_${turn}`);
  const command = userTexts(body).at(-1)?.match(/RUN\[(.+?)\]/)?.[1] ?? "true";
  return fakeGatewaySse([
    {
      type: "tool-call",
      toolCallId: `run_${turn}`,
      toolName: "shell",
      input: { request: { action: "run", yield_time_ms: 30_000, timeout_ms: 600_000, command } },
    },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
}

// Sends turn `turn` and waits until it either asks for approval or is done.
async function runTurn(session: TmuxSession, turn: number, command: string): Promise<"asked" | "done"> {
  await session.waitForComposer(15_000);
  await session.sendText(`PERM_${turn} RUN[${command}]`);
  const pane = await session.waitForPane(
    (value) => value.includes(COMMAND_APPROVAL_PROMPT) || value.includes(`PERM_DONE_${turn}`),
    30_000,
  );
  return pane.includes(`PERM_DONE_${turn}`) ? "done" : "asked";
}

// Answers the approval on screen with `choice` (1 once, 2 always) and waits
// for turn `turn` to finish.
async function approve(session: TmuxSession, turn: number, choice: "1" | "2") {
  await session.sendKeys(choice);
  await session.sendKeys("Enter");
  await session.waitForText(`PERM_DONE_${turn}`, 30_000);
}
const shownAnswers = (pane: string) => ANSWERS.filter((answer) => pane.includes(answer));

describe.skipIf(!tmuxAvailable())("TUI host instances", () => {
  test(
    "three instances started together each keep their own conversation",
    async () => {
      const bodies = await withHost(answerByLetter, { instances: 3 }, async ({ session }) => {
        for (const [index, letter] of ["A", "B", "C"].entries()) {
          if (index > 0) {
            await session.sendKeys("M-Right");
            await session.waitForPane((pane) => pane.includes(`fx ${index + 1}/3`), 15_000);
          } else {
            await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
          }
          await session.waitForComposer(15_000);
          await session.sendText(`HOST_${letter} hello`);
          const pane = await session.waitForPane((value) => value.includes(`HOST_ANSWER_${letter}`), 30_000);
          // Each instance opens with fx's welcome, on the model the launch
          // chose, and shows only its own turn.
          expect(pane).toContain("Run /help for commands");
          expect(pane).toContain(`fx ${index + 1}/3 · auto · gpt-5`);
          expect(shownAnswers(pane)).toEqual([`HOST_ANSWER_${letter}`]);
        }
        // Alt+Right from the last instance wraps to the first, still as it was.
        await session.sendKeys("M-Right");
        const first = await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        expect(shownAnswers(first)).toEqual(["HOST_ANSWER_A"]);
        // And Alt+Left from the first wraps to the last.
        await session.sendKeys("M-Left");
        const last = await session.waitForPane((pane) => pane.includes("fx 3/3"), 15_000);
        expect(shownAnswers(last)).toEqual(["HOST_ANSWER_C"]);
      });
      // Every request carries one instance's conversation and nothing else.
      expect(bodies.length).toBe(3);
      for (const body of bodies) {
        const texts = userTexts(body).join("\n");
        expect(texts.match(/HOST_[A-Z]/g)?.length).toBe(1);
      }
      expect(bodies.map(letterOf).sort()).toEqual(["A", "B", "C"]);
    },
    TIMEOUT,
  );

  test(
    "--instances starts several, /launch adds one and shows it, /close closes it",
    async () => {
      await withHost(answerByLetter, { args: "--instances 2" }, async ({ session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);

        await session.sendText("/launch");
        const launched = await session.waitForPane((pane) => pane.includes("fx 3/3"), 15_000);
        expect(launched).toContain("Run /help for commands");
        expect(shownAnswers(launched)).toEqual([]);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_D launched");
        await session.waitForText("HOST_ANSWER_D", 30_000);

        // Closing it leaves the others running; the first comes back.
        await session.sendText("/close");
        const after = await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(shownAnswers(after)).toEqual(["HOST_ANSWER_A"]);
        await session.sendKeys("M-Right");
        const second = await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        expect(shownAnswers(second)).toEqual([]);

        // A profile that won't load says why and opens nothing.
        await session.sendText("/launch nosuch");
        const refused = await session.waitForPane((pane) => pane.includes("no profile named 'nosuch'"), 15_000);
        expect(refused).toContain("Couldn't start another fx instance: no profile named 'nosuch'. Profiles:");
        expect(refused).not.toContain("ProfileNotFound");
        expect(refused).toContain("fx 2/2");
      });
    },
    TIMEOUT,
  );

  test(
    "/new on a later instance starts its own fresh session and leaves the others",
    async () => {
      const bodies = await withHost(answerByLetter, { instances: 2 }, async ({ session }) => {
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B before new");
        await session.waitForText("HOST_ANSWER_B", 30_000);

        // A session command runs on any instance, as on the first.
        await session.sendText("/new");
        await session.waitForPane((pane) => !pane.includes("HOST_ANSWER_B") && pane.includes("fx 2/2"), 15_000);
        expect(await session.capturePane()).not.toContain("works on main's screen");
        await session.waitForComposer(15_000);
        await session.sendText("HOST_C after new");
        await session.waitForText("HOST_ANSWER_C", 30_000);

        await session.sendKeys("M-Left");
        const first = await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(shownAnswers(first)).toEqual(["HOST_ANSWER_A"]);
      });
      // The turn after /new starts a new conversation: it carries only itself.
      const after = bodies.find((body) => letterOf(body) === "C")!;
      expect(userTexts(after).join("\n")).not.toContain("HOST_B");
    },
    TIMEOUT,
  );

  test(
    "an instance keeps working while another one is on screen",
    async () => {
      let releaseSlow: () => void = () => {};
      const slowGate = new Promise<void>((resolve) => { releaseSlow = resolve; });
      const order: string[] = [];
      await withHost(async (body) => {
        const letter = letterOf(body);
        order.push(`request ${letter}`);
        if (letter === "A") {
          await slowGate;
          order.push("answer A");
        }
        return answerByLetter(body);
      }, { instances: 2 }, async ({ session }) => {
        await session.sendText("HOST_A slow");
        // Switch while the first instance's answer is still outstanding.
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B fast");
        await session.waitForText("HOST_ANSWER_B", 30_000);
        order.push("B shown");
        releaseSlow();
        await session.sendKeys("M-Left");
        const first = await session.waitForPane((pane) => pane.includes("HOST_ANSWER_A"), 30_000);
        expect(shownAnswers(first)).toEqual(["HOST_ANSWER_A"]);
      });
      // The second instance was answered while the first still waited.
      expect(order.indexOf("B shown")).toBeLessThan(order.indexOf("answer A"));
    },
    TIMEOUT,
  );

  test(
    "each instance keeps its own permission mode",
    async () => {
      await withHost(runThenAnswer, { instances: 2, env: { FX_PERMISSION_MODE: "ask" } }, async ({ workspace, session }) => {
        // Full access on the second instance only.
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("/permissions full-access");
        await session.waitForText("mode set to full access", 15_000);
        expect(await runTurn(session, 1, "touch second-ran")).toBe("done");
        expect(existsSync(join(workspace, "second-ran"))).toBe(true);

        // The first is still in ask: the same kind of command asks first.
        await session.sendKeys("M-Left");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(await runTurn(session, 2, "touch first-ran")).toBe("asked");
        expect(existsSync(join(workspace, "first-ran"))).toBe(false);
        await approve(session, 2, "1");
        expect(existsSync(join(workspace, "first-ran"))).toBe(true);
      });
    },
    TIMEOUT,
  );

  test(
    "an always approval belongs to its own instance and outlives another's /new",
    async () => {
      await withHost(runThenAnswer, { instances: 2, env: { FX_PERMISSION_MODE: "ask" } }, async ({ workspace, session }) => {
        const marker = join(workspace, "shared-marker");
        // Always on the first instance.
        expect(await runTurn(session, 1, "touch shared-marker")).toBe("asked");
        await approve(session, 1, "2");
        expect(existsSync(marker)).toBe(true);
        rmSync(marker);
        expect(await runTurn(session, 2, "touch shared-marker")).toBe("done");
        expect(existsSync(marker)).toBe(true);
        rmSync(marker);

        // The second instance never approved it, so it asks.
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        expect(await runTurn(session, 3, "touch shared-marker")).toBe("asked");
        await approve(session, 3, "1");
        rmSync(marker);

        // A new session on the second ends only its own approvals.
        await session.waitForComposer(15_000);
        await session.sendText("/new");
        await session.waitForPane((pane) => !pane.includes("PERM_DONE_3") && pane.includes("fx 2/2"), 15_000);
        await session.sendKeys("M-Left");
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(await runTurn(session, 4, "touch shared-marker")).toBe("done");
        expect(existsSync(marker)).toBe(true);
      });
    },
    TIMEOUT,
  );

  test(
    "/close on the first instance hands over to the next, and the host keeps running",
    async () => {
      await withHost(answerByLetter, { instances: 3 }, async ({ home, session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes("fx 2/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B second");
        await session.waitForText("HOST_ANSWER_B", 30_000);

        // Close the first: the second takes over as fx 1, as it was.
        await session.sendKeys("M-Left");
        await session.waitForPane((pane) => pane.includes("fx 1/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("/close");
        const after = await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(shownAnswers(after)).toEqual(["HOST_ANSWER_B"]);
        // The closed one is gone from the switch list.
        await session.sendKeys("M-Right");
        const third = await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        expect(shownAnswers(third)).toEqual([]);
        await session.sendKeys("M-Right");
        const wrapped = await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        expect(shownAnswers(wrapped)).toEqual(["HOST_ANSWER_B"]);

        // Launching still works, from the settings the host started with.
        await session.waitForComposer(15_000);
        await session.sendText("/launch");
        await session.waitForPane((pane) => pane.includes("fx 3/3"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_C launched");
        await session.waitForText("HOST_ANSWER_C", 30_000);
        // The closed instance's conversation was saved in its own session.
        const closed = sessionHolding(home, "HOST_ANSWER_A");
        expect(closed).not.toBeNull();
        expect(sessionHolding(home, "HOST_ANSWER_B")).not.toBe(closed);
      });
    },
    TIMEOUT,
  );

  test(
    "quitting from a later instance prints its own resume command",
    async () => {
      await withHost(answerByLetter, { instances: 2, remainOnExit: true }, async ({ home, session }) => {
        await session.sendText("HOST_A first");
        await session.waitForText("HOST_ANSWER_A", 30_000);
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B second");
        await session.waitForText("HOST_ANSWER_B", 30_000);
        const printed = await quitWith(session, "/exit");
        const second = sessionHolding(home, "HOST_ANSWER_B");
        expect(second).not.toBeNull();
        expect(printed).toContain(`Continue session with: fx --resume ${second}`);
        expect(printed).not.toContain(`fx --resume ${sessionHolding(home, "HOST_ANSWER_A")}`);
      });
    },
    TIMEOUT,
  );

  test(
    "/close on the only open instance ends fx with its resume command",
    async () => {
      await withHost(answerByLetter, { instances: 2, remainOnExit: true }, async ({ home, session }) => {
        await session.sendText("/close");
        await session.waitForPane((pane) => !/fx \d+\/\d+/.test(pane) && pane.includes("Run /help for commands"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("HOST_B last one");
        await session.waitForText("HOST_ANSWER_B", 30_000);
        const printed = await quitWith(session, "/close");
        const last = sessionHolding(home, "HOST_ANSWER_B");
        expect(last).not.toBeNull();
        expect(printed).toContain(`Continue session with: fx --resume ${last}`);
      });
    },
    TIMEOUT,
  );

  test(
    "resuming any session of a host brings back its whole group, the named one first",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-restore-")));
      try {
        await withHost(answerByLetter, { instances: 3, remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          for (const [index, letter] of ["A", "B", "C"].entries()) {
            if (index > 0) {
              await session.sendKeys("M-Right");
              await session.waitForPane((pane) => pane.includes(`fx ${index + 1}/3`), 15_000);
              await session.waitForComposer(15_000);
            }
            await session.sendText(`HOST_${letter} first run`);
            await session.waitForText(`HOST_ANSWER_${letter}`, 30_000);
          }
          await quitWith(session, "/exit");
        });
        const [a, b, c] = ["A", "B", "C"].map((letter) => sessionHolding(home, `HOST_ANSWER_${letter}`)!);
        expect(hostRecords(home)).toEqual([[a, b, c]]);

        // Resume the second: it comes back first and on screen, the others
        // after it in their saved order, each with its own conversation.
        const bodies = await withHost(answerByLetter, { args: `--resume ${b}`, reuse: { home, workspace } }, async ({ session }) => {
          const first = await session.waitForPane((pane) => pane.includes("fx 1/3") && pane.includes("HOST_ANSWER_B"), 30_000);
          expect(shownAnswers(first)).toEqual(["HOST_ANSWER_B"]);
          await session.sendKeys("M-Right");
          const second = await session.waitForPane((pane) => pane.includes("fx 2/3") && pane.includes("HOST_ANSWER_A"), 15_000);
          expect(shownAnswers(second)).toEqual(["HOST_ANSWER_A"]);
          await session.sendKeys("M-Right");
          const third = await session.waitForPane((pane) => pane.includes("fx 3/3") && pane.includes("HOST_ANSWER_C"), 15_000);
          expect(shownAnswers(third)).toEqual(["HOST_ANSWER_C"]);
          // A restored instance carries on its own conversation.
          await session.sendKeys("M-Left");
          await session.waitForPane((pane) => pane.includes("fx 2/3"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("HOST_D carries on A");
          await session.waitForText("HOST_ANSWER_D", 30_000);
          await session.waitForPane(() => hostRecords(home).length === 1 && hostRecords(home)[0]![0] === b, 15_000);
          expect(hostRecords(home)).toEqual([[b, a, c]]);
        });
        const carried = bodies.find((body) => letterOf(body) === "D")!;
        expect(userTexts(carried).join("\n")).toContain("HOST_A first run");
        expect(userTexts(carried).join("\n")).not.toContain("HOST_B");
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "the host record follows the open instances, and a lone session resumes alone",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-record-")));
      try {
        await withHost(answerByLetter, { remainOnExit: true, reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("HOST_A alone");
          await session.waitForText("HOST_ANSWER_A", 30_000);
          expect(hostRecords(home)).toEqual([]);
          await session.sendText("/launch");
          await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
          await session.waitForPane(() => hostRecords(home).length === 1 && hostRecords(home)[0]!.length === 2, 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("/close");
          await session.waitForPane((pane) => !/fx \d+\/\d+/.test(pane), 15_000);
          await session.waitForPane(() => hostRecords(home).length === 0, 15_000);
          await quitWith(session, "/exit");
        });
        const alone = sessionHolding(home, "HOST_ANSWER_A")!;
        await withHost(answerByLetter, { args: `--resume ${alone}`, reuse: { home, workspace } }, async ({ session }) => {
          const pane = await session.waitForPane((value) => value.includes("HOST_ANSWER_A"), 30_000);
          expect(pane).not.toMatch(/fx \d+\/\d+/);
        });
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );


  test(
    "the startup picker restores a group; in-app /resume and a missing session don't",
    async () => {
      const home = createIsolatedTestHome();
      const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-picker-")));
      try {
        const [a, b, c] = await saveGroup(home, workspace);

        // The startup picker (`-r`): picking B brings back the whole group.
        await withHost(answerByLetter, { args: "-r", reuse: { home, workspace } }, async ({ session }) => {
          await session.waitForPane((pane) => pane.includes("Sessions 3"), 30_000);
          await session.sendLiteralText("HOST_B");
          await session.waitForPane((pane) => pane.includes("Sessions 1"), 15_000);
          await session.sendKeys("Enter");
          const first = await session.waitForPane((pane) => pane.includes("fx 1/3") && pane.includes("HOST_ANSWER_B"), 30_000);
          expect(shownAnswers(first)).toEqual(["HOST_ANSWER_B"]);
          await session.sendKeys("M-Right");
          await session.waitForPane((pane) => pane.includes("fx 2/3") && pane.includes("HOST_ANSWER_A"), 15_000);
          await quitWith(session, "/exit").catch(() => "");
        });

        // In-app /resume swaps one instance's session and brings back nothing
        // else.
        await withHost(answerByLetter, { reuse: { home, workspace } }, async ({ session }) => {
          await session.sendText("/resume");
          await session.waitForPane((pane) => /Sessions \d+/.test(pane), 15_000);
          await session.sendLiteralText("HOST_C");
          await session.waitForPane((pane) => pane.includes("Sessions 1"), 15_000);
          await session.sendKeys("Enter");
          const pane = await session.waitForPane((value) => value.includes("HOST_ANSWER_C"), 30_000);
          expect(pane).not.toMatch(/fx \d+\/\d+/);
          await Bun.sleep(500);
          expect(await session.capturePane()).not.toMatch(/fx \d+\/\d+/);
        });

        // A member that can't load is skipped with a notice; the rest come back.
        rmSync(join(home, ".fx", "sessions", "v2", a), { recursive: true, force: true });
        await withHost(answerByLetter, { args: `--resume ${b}`, reuse: { home, workspace } }, async ({ session }) => {
          const pane = await session.waitForPane((value) => value.includes("fx 1/2") && value.includes("HOST_ANSWER_B"), 30_000);
          expect(pane).toContain(`Couldn't bring back session ${a}`);
          await session.sendKeys("M-Right");
          await session.waitForPane((value) => value.includes("fx 2/2") && value.includes("HOST_ANSWER_C"), 15_000);
        });
        expect(c).not.toBeNull();
      } finally {
        cleanupIsolatedTestHome(home);
        rmSync(workspace, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/exit ends every instance, and each kept its own saved session",
    async () => {
      await withHost(answerByLetter, { instances: 3 }, async ({ home, session }) => {
        for (const [index, letter] of ["A", "B", "C"].entries()) {
          if (index > 0) {
            await session.sendKeys("M-Right");
            await session.waitForPane((pane) => pane.includes(`fx ${index + 1}/3`), 15_000);
            await session.waitForComposer(15_000);
          }
          await session.sendText(`HOST_${letter} saved`);
          await session.waitForText(`HOST_ANSWER_${letter}`, 30_000);
        }
        await session.sendText("/exit");
        await session.waitForSessionEnd(15_000);
        const sessions = join(home, ".fx", "sessions", "v2");
        expect(existsSync(sessions)).toBe(true);
        expect(readdirSync(sessions).filter((id) => !id.startsWith(".") && statSync(join(sessions, id)).isDirectory()).length).toBe(3);
      });
    },
    TIMEOUT,
  );

  test(
    "a launched instance's subagent works under that instance",
    async () => {
      const bodies = await withHost((body) => {
        const texts = userTexts(body).join("\n");
        if (texts.includes("TREE_TASK")) {
          if (answered(body)) return text("tree_child_done", "TREE_CHILD_DONE");
          return call("tree_touch", "shell", { request: { action: "run", yield_time_ms: 30_000, timeout_ms: 600_000, command: "touch tree-marker" } });
        }
        if (texts.includes("TREE_USER")) {
          if (answered(body)) return text("tree_main_final", "TREE_MAIN_FINAL");
          return call("tree_sub", "subagent", { request: { action: "message", agent: "helper", message: "TREE_TASK make the marker" } });
        }
        return answerByLetter(body);
      }, { instances: 2, env: { FX_PERMISSION_MODE: "full-access" } }, async ({ workspace, session }) => {
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_USER start a helper");
        await session.waitForText("TREE_MAIN_FINAL", 45_000);
        // The subagent fx 2 started ran its command, so its tree has
        // fx 2's authority rather than none.
        expect(existsSync(join(workspace, "tree-marker"))).toBe(true);
      });
      const child = bodies.filter((body) => userTexts(body).join("\n").includes("TREE_TASK"));
      expect(child.length).toBeGreaterThan(0);
      expect(toolNames(child[0])).toContain("shell");
    },
    TIMEOUT,
  );

  test(
    "a subagent without a profile copies its instance, and one with a profile gets what the profile says",
    async () => {
      let home = "";
      const bodies = await withHost((body) => {
        const texts = userTexts(body).join("\n");
        if (texts.includes("TREE_PLAIN_TASK")) return text("plain_done", "TREE_PLAIN_DONE");
        if (texts.includes("TREE_BUILDER_TASK")) return text("builder_done", "TREE_BUILDER_DONE");
        const last = userTexts(body).at(-1) ?? "";
        if (last.includes("TREE_USER_PLAIN")) {
          if (answered(body)) return text("plain_final", "TREE_PLAIN_FINAL");
          return call("plain_sub", "subagent", { request: { action: "message", agent: "plain", message: "TREE_PLAIN_TASK" } });
        }
        if (last.includes("TREE_USER_BUILDER")) {
          if (answered(body)) return text("builder_final", "TREE_BUILDER_FINAL");
          return call("builder_sub", "subagent", { request: { action: "message", agent: "builder", profile: "builder", message: "TREE_BUILDER_TASK" } });
        }
        return answerByLetter(body);
      }, { env: { FX_PERMISSION_MODE: "full-access" } }, async ({ home: testHome, session }) => {
        home = testHome;
        writeProfile(home, "noshell", { description: "Everything but the shell", tools: ["*", "!shell"] });
        writeProfile(home, "builder", { description: "Builds things with every tool", tools: ["*"] });
        await session.sendText("/launch noshell");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_USER_PLAIN start a plain helper");
        await session.waitForText("TREE_PLAIN_FINAL", 45_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_USER_BUILDER start a builder");
        await session.waitForText("TREE_BUILDER_FINAL", 45_000);
      });
      const holding = (marker: string) => bodies.filter((body) => userTexts(body).join("\n").includes(marker));
      // fx 2 runs in its profile, without the shell.
      const instance = holding("TREE_USER_PLAIN").filter((body) => !userTexts(body).join("\n").includes("TREE_PLAIN_TASK"));
      expect(instance.length).toBeGreaterThan(0);
      expect(toolNames(instance[0])).not.toContain("shell");
      // With no profile, its subagent is a copy of it.
      const plain = holding("TREE_PLAIN_TASK");
      expect(plain.length).toBeGreaterThan(0);
      expect(toolNames(plain[0])).not.toContain("shell");
      expect(toolNames(plain[0])).toContain("read_file");
      // With a profile, the profile decides, even past fx 2's tools.
      const builder = holding("TREE_BUILDER_TASK");
      expect(builder.length).toBeGreaterThan(0);
      expect(toolNames(builder[0])).toContain("shell");
    },
    TIMEOUT,
  );


  test(
    "a launched instance's subagent asks on that instance's screen, not the first's",
    async () => {
      await withHost((body) => {
        const texts = userTexts(body).join("\n");
        if (texts.includes("TREE_LEND_TASK")) {
          if (answered(body)) return text("lend_child_done", "TREE_LEND_CHILD_DONE");
          return call("lend_write", "write_file", { path: "lent.txt", content: "TREE_LENT\n" });
        }
        if (texts.includes("TREE_LEND_USER")) {
          if (answered(body)) return text("lend_main_done", "TREE_LEND_MAIN_DONE");
          return call("lend_sub", "subagent", { request: { action: "message", agent: "writer", profile: "writer", message: "TREE_LEND_TASK" } });
        }
        return answerByLetter(body);
      }, { instances: 2 }, async ({ home, workspace, session }) => {
        writeProfile(home, "writer", { description: "Writes one file", tools: ["read_file", "write_file"], permission_mode: "ask" });
        await session.waitForPane((pane) => pane.includes("fx 1/2"), 15_000);
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes("fx 2/2"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("TREE_LEND_USER write the file");
        // fx 2's own screen, shown by its conversation, holds its subagent's
        // approval, which replaces the footer while it waits.
        await session.waitForPane((pane) => pane.includes("TREE_LEND_USER") && pane.includes("Subagent writer needs permission"), 30_000);

        // The first instance shows only the note that it waits.
        await session.sendKeys("M-Left");
        const first = await session.waitForPane((pane) => pane.includes("fx 1/2") && pane.includes("writer needs approval"), 15_000);
        expect(first).not.toContain("Subagent writer needs permission");

        // Back on fx 2, the answer there reaches the subagent.
        expect(first).not.toContain("TREE_LEND_USER");
        await session.sendKeys("M-Right");
        await session.waitForPane((pane) => pane.includes("TREE_LEND_USER") && pane.includes("Subagent writer needs permission"), 15_000);
        await session.sendKeys("1");
        await session.waitForText("TREE_LEND_MAIN_DONE", 30_000);
        expect(readFileSync(join(workspace, "lent.txt"), "utf8")).toBe("TREE_LENT\n");
      });
    },
    TIMEOUT,
  );

});
