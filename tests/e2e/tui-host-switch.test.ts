import { describe, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewaySse,
  startDynamicFakeGateway,
  fakeGatewayFinalText,
  composerContains,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

// Switching between main and its subagents through the agent list, in one fx
// process: ↓ on an empty composer or Ctrl+X opens it, moving through it shows
// each agent, Enter keeps the one shown, and Esc goes back. Each agent keeps
// its own conversation and draft, a message typed on a subagent's screen goes
// to that subagent, and a subagent's approval can be answered on its own
// screen or on main's, once. Option+arrows only move text.

const TIMEOUT = 90_000;
const LIST_HINT = "enter switch";

// Shows the agent `rows` rows below the one on screen, or above it when
// negative, through the agent list: Ctrl+X opens it whatever the composer
// holds, each arrow shows the next row, and Enter keeps it.
async function moveAgent(session: TmuxSession, rows: number) {
  await session.sendKeys("C-x");
  await session.waitForText(LIST_HINT, 10_000);
  for (let step = 0; step < Math.abs(rows); step += 1) await session.sendKeys(rows > 0 ? "Down" : "Up");
  await session.sendKeys("Enter");
  await session.waitForPane((pane) => !pane.includes(LIST_HINT), 10_000);
}

function text(id: string, delta: string): Response {
  return fakeGatewaySse([
    { type: "text-delta", id, delta },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
  ]);
}

function toolCall(id: string, tool: string, input: object): Response {
  return fakeGatewaySse([
    { type: "tool-call", toolCallId: id, toolName: tool, input },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
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

// The tab title once it has held still for half a second.
async function stablePaneTitle(session: TmuxSession, ms = 15_000): Promise<string> {
  const deadline = Date.now() + ms;
  let last = await session.paneTitle();
  let since = Date.now();
  while (Date.now() < deadline) {
    await Bun.sleep(100);
    const now = await session.paneTitle();
    if (now !== last) {
      last = now;
      since = Date.now();
    } else if (Date.now() - since >= 500) {
      return now;
    }
  }
  return last;
}

async function waitForPaneTitle(session: TmuxSession, done: (title: string) => boolean, ms = 15_000): Promise<string> {
  const deadline = Date.now() + ms;
  let title = "";
  while (Date.now() < deadline) {
    title = await session.paneTitle();
    if (done(title)) return title;
    await Bun.sleep(50);
  }
  throw new Error(`pane title never matched; last saw ${JSON.stringify(title)}`);
}

// Every child line in the profile's saved session logs.
function childLogLines(home: string): Array<{ kind?: string; work_id?: string; data?: { by?: string } }> {
  const sessions = join(home, ".fx", "sessions", "v2");
  if (!existsSync(sessions)) return [];
  return readdirSync(sessions).flatMap((id) => {
    const log = join(sessions, id, "log.jsonl");
    if (!existsSync(log)) return [];
    return readFileSync(log, "utf8").split("\n").filter((line) => line.includes('"child_')).map((line) => JSON.parse(line));
  });
}

// The tools a request offered the model, by name.
function toolNames(body: string): string[] {
  const request = JSON.parse(body) as { tools?: Array<{ name?: string }> };
  return (request.tools ?? []).map((tool) => tool.name ?? "");
}

function latestUserText(body: string): string {
  return userTexts(body).at(-1) ?? "";
}

async function until(what: string, done: () => boolean, ms = 30_000) {
  const deadline = Date.now() + ms;
  while (!done()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(50);
  }
}

// A provider outage fx waits out and then sends the request again.
function unavailable(): Response {
  return new Response(JSON.stringify({ error: { message: "provider temporarily unavailable" } }), {
    status: 503,
    headers: { "content-type": "application/json", "retry-after": "1" },
  });
}

// A reply the test holds back until it calls `release`.
function held() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => (release = resolve));
  return { promise, release };
}

// Main's requests carry what the test typed to main, which always starts
// SWITCH_USER; a subagent's carry only its task and what is typed to it. The
// subagent tool can't tell them apart, because a subagent is offered it too.
const isMainRequest = (body: string) => userTexts(body).some((text) => text.includes("SWITCH_USER"));

// Titles the title model gives: the reviewer's task gets its own, so the
// agent list shows a subagent titled as main is.
const subagentTitles = {
  titleResponses: Array.from({ length: 8 }, () => (body: string) =>
    fakeGatewayFinalText(body.includes("src/parser.zig") ? "Review the parser" : "Plan the parser work")),
};

// The saved sessions in `home` whose files hold `marker`.
function sessionsHolding(home: string, marker: string): string[] {
  const sessions = join(home, ".fx", "sessions", "v2");
  const holds = (path: string): boolean => readdirSync(path).some((entry) => {
    const full = join(path, entry);
    return statSync(full).isDirectory() ? holds(full) : readFileSync(full, "latin1").includes(marker);
  });
  return readdirSync(sessions).filter((id) => !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id)));
}

interface Run {
  workspace: string;
  home: string;
  /// Starts another fx with the same profile, such as `--resume <id>`.
  launch: (args?: string) => Promise<TmuxSession>;
  /// The first fx's terminal recording, when `withFx` was asked to record.
  tape: string;
}

async function withFx(
  respond: (body: string) => Response | Promise<Response>,
  run: (session: TmuxSession, context: Run) => Promise<void>,
  setupHome: (home: string) => void = () => {},
  record = false,
  env: Record<string, string> = {},
  gatewayOptions: Parameters<typeof startDynamicFakeGateway>[1] = {},
) {
  const gateway = startDynamicFakeGateway(respond, gatewayOptions);
  const home = createIsolatedTestHome();
  const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-host-switch-")));
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none" }));
  setupHome(home);
  const sessions: TmuxSession[] = [];
  const tape = join(workspace, "fx.fxtape");
  const launch = async (args = "") => {
    const session = await TmuxSession.create({
      cmd: args ? `${JSON.stringify(FX_BIN)} ${args}` : FX_BIN,
      cwd: workspace,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: "fake-switch-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_MODEL: FAKE_GATEWAY_MODEL,
        FX_PERMISSION_MODE: "auto",
        FX_AUTO_UPGRADE: "0",
        FX_SOUND: "0",
        ...(record && sessions.length === 0 ? { FX_RECORD: tape } : {}),
        ...env,
      },
      width: 120,
      height: 40,
    });
    sessions.push(session);
    await session.waitForComposer(30_000);
    return session;
  };
  try {
    await run(await launch(), { workspace, home, launch, tape });
    return gateway.requests.map((request) => request.body);
  } finally {
    gateway.stop();
    try {
      for (const session of sessions) await session.kill();
    } finally {
      cleanupIsolatedTestHome(home);
      rmSync(workspace, { recursive: true, force: true });
    }
  }
}

describe.skipIf(!tmuxAvailable())("TUI agent switching", () => {
  test(
    "the agent list shows a subagent's conversation, which takes messages typed there",
    async () => {
      let mainCalls = 0;
      const bodies = await withFx((body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TYPED")) return text("child_reply", "SWITCH_CHILD_REPLY");
          return text("child_answer", "SWITCH_CHILD_ANSWER");
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reviewer", message: "SWITCH_TASK look for nothing" },
          });
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_FINAL", 30_000);
        await session.waitForComposer(15_000);

        // The subagent's conversation replaces main's, and the footer names it.
        await moveAgent(session, 1);
        const subagent = await session.waitForPane((pane) =>
          pane.includes("SWITCH_CHILD_ANSWER") && pane.includes("reviewer \u00b7 "), 15_000);
        expect(subagent).toContain("SWITCH_TASK look for nothing");
        // A new subagent opens with fx's welcome, as a fresh fx does.
        expect(subagent).toContain("Run /help for commands");
        expect(subagent).not.toContain("SWITCH_MAIN_FINAL");
        expect(await session.captureFullScrollback()).not.toContain("SWITCH_USER");

        // Typed here, it is a message to the subagent.
        await session.sendText("SWITCH_TYPED to the subagent");
        await session.waitForText("SWITCH_CHILD_REPLY", 30_000);

        // Main's session commands stay on main's screen, /clear and /reset
        // included: on a subagent they would replace its saved conversation.
        for (const command of ["/new", "/clear", "/reset"]) {
          await session.sendText(command);
          await session.waitForText(`${command} works on main's screen`, 15_000);
        }
        expect(await session.capturePane()).toContain("SWITCH_CHILD_REPLY");

        // Main's row is above it, and main is as it was.
        await moveAgent(session, -1);
        const main = await session.waitForPane((pane) => pane.includes("SWITCH_MAIN_FINAL"), 15_000);
        expect(main).toContain("SWITCH_USER");
        expect(main).not.toContain("SWITCH_CHILD_REPLY");
        // The footer names main, not the subagent.
        expect(main).not.toMatch(/^reviewer \u00b7 /m);
        // The subagent's report of main's message shows as a subagent row.
        expect(main).toContain("reviewer completed");
      });

      // Main's model never sees the answer to a message it did not send: its
      // call, the turn after the receipt, and the turn the report started.
      const mainBodies = bodies.filter(isMainRequest);
      expect(mainBodies.length).toBe(3);
      for (const body of mainBodies) expect(body).not.toContain("SWITCH_CHILD_REPLY");
      expect(mainBodies.filter((body) => body.includes("SWITCH_CHILD_ANSWER"))).toHaveLength(1);
      expect(bodies.some((body) => !isMainRequest(body) && latestUserText(body).includes("SWITCH_TYPED"))).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "drafts and images stay with each agent across switches, and no switch enters the alternate screen",
    async () => {
      let mainCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_CHILD_ANSWER");
        mainCalls += 1;
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reviewer", message: "SWITCH_TASK look for nothing" },
          });
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session, { workspace, tape }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_FINAL", 30_000);
        await session.waitForComposer(15_000);

        // Main's unsent draft holds an image and text.
        const image = join(workspace, "switch-draft.png");
        copyFileSync(join(import.meta.dir, "fixtures", "favicon.png"), image);
        await session.sendText(`/image ${image}`);
        await session.waitForText("attached image: switch-draft.png", 15_000);
        await session.sendLiteralText("SWITCH_MAIN_DRAFT");
        await session.waitForPane((pane) => pane.includes("SWITCH_MAIN_DRAFT") && pane.includes("Image 1"), 15_000);
        const beforeSwitches = statSync(tape).size;

        // Ctrl+X opens the list over the draft. The subagent's screen has its
        // own composer, and a draft typed there stays there.
        await moveAgent(session, 1);
        const child = await session.waitForPane((pane) => pane.includes("reviewer \u00b7 "), 15_000);
        expect(child).not.toContain("SWITCH_MAIN_DRAFT");
        expect(child).not.toContain("Image 1");
        await session.sendLiteralText("SWITCH_CHILD_DRAFT");
        await session.waitForText("SWITCH_CHILD_DRAFT", 15_000);

        // Back on main, its draft and image are as it left them.
        await moveAgent(session, -1);
        const main = await session.waitForPane(
          (pane) => pane.includes("SWITCH_MAIN_DRAFT") && pane.includes("Image 1"), 15_000);
        expect(main).not.toContain("SWITCH_CHILD_DRAFT");

        // So is the subagent's.
        await moveAgent(session, 1);
        const again = await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_DRAFT"), 15_000);
        expect(again).not.toContain("SWITCH_MAIN_DRAFT");

        // Every switch redrew the screen inline: the recording after the
        // first one holds both drafts and no alternate-screen switch.
        const switches = readFileSync(tape).subarray(beforeSwitches);
        expect(switches.includes(Buffer.from("SWITCH_CHILD_DRAFT"))).toBe(true);
        expect(switches.includes(Buffer.from("SWITCH_MAIN_DRAFT"))).toBe(true);
        expect(switches.includes(Buffer.from("\x1b[?1049h"))).toBe(false);
      }, undefined, true);
    },
    TIMEOUT,
  );

  test(
    "quitting from a subagent's screen stops main and exits",
    async () => {
      let mainCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_CHILD_ANSWER");
        mainCalls += 1;
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reviewer", message: "SWITCH_TASK look for nothing" },
          });
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_FINAL", 30_000);
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("reviewer \u00b7 "), 15_000);
        // Shutdown is main's own: quitting here used to stop the subagent in
        // main's place and then wait forever for main's worker.
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(10_000)).toBe(true);
      });
    },
    TIMEOUT,
  );

  test(
    "Esc on a subagent's screen drops the message main sent it while it worked, and its report counts it",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      const first = held();
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          // The subagent's first turn waits here until Esc ends it.
          if (childCalls === 1) await first.promise;
          return text("child_answer", "SWITCH_CHILD_RAN");
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "worker", message: "SWITCH_STOP_TASK work slowly" },
          });
        }
        if (mainCalls === 2) {
          // Sent once the subagent's request is out, so the message waits in
          // its turn. Sent sooner, the turn takes it into that request, and
          // the stop then drops nothing.
          await until("the subagent's turn", () => childCalls >= 1);
          return toolCall("main_more", "subagent", {
            request: { action: "message", agent: "worker", message: "SWITCH_MORE one more thing" },
          });
        }
        // The report counts the drop and says the user stopped the turn.
        if (body.includes('\\"dropped\\":1') && body.includes('\\"cause\\":\\"user_stop\\"')) {
          return text("main_saw", "SWITCH_MAIN_SAW_DROP");
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_DONE", 30_000);
        expect(childCalls).toBe(1);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_STOP_TASK") && pane.includes("worker \u2193"), 15_000);
        await session.sendKeys("Escape");
        await session.waitForText("esc again to interrupt", 10_000);
        await session.sendKeys("Escape");
        // The stop shows before the next key, which must not join the Esc.
        await session.waitForText("What can fx do differently?", 15_000);
        await moveAgent(session, -1);
        // Main hears of the dropped message from the stopped work's report.
        await session.waitForText("SWITCH_MAIN_SAW_DROP", 30_000);
        first.release();
        // The message main sent while it worked never ran.
        expect(childCalls).toBe(1);
      });
    },
    TIMEOUT,
  );

  test(
    "a subagent's work that /quit cuts short reports after a resume, saying fx quit",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      const child = held();
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          // The subagent's turn is still waiting when fx quits.
          await child.promise;
          return text("child_answer", "SWITCH_CHILD_LATE");
        }
        mainCalls += 1;
        if (body.includes('\\"cause\\":\\"fx_quit\\"')) return text("main_saw_quit", "SWITCH_MAIN_SAW_QUIT");
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "worker", message: "SWITCH_QUIT_TASK work slowly" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { home, launch }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_DONE", 30_000);
        const deadline = Date.now() + 15_000;
        while (childCalls === 0 && Date.now() < deadline) await Bun.sleep(50);
        expect(childCalls).toBe(1);
        await session.waitForComposer(15_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);
        child.release();

        // The parent is the saved session that holds main's answer.
        const sessions = join(home, ".fx", "sessions", "v2");
        const holds = (path: string, marker: string): boolean => readdirSync(path).some((entry) => {
          const full = join(path, entry);
          return statSync(full).isDirectory() ? holds(full, marker) : readFileSync(full, "latin1").includes(marker);
        });
        const parents = readdirSync(sessions).filter((id) =>
          !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id), "SWITCH_MAIN_DONE"));
        expect(parents.length).toBe(1);

        // The resumed session delivers the report the quit left owed.
        const resumed = await launch(`--resume ${parents[0]}`);
        await resumed.waitForText("SWITCH_MAIN_SAW_QUIT", 30_000);
      });
    },
    TIMEOUT,
  );

  test(
    "a turn typed on a subagent's screen reports to main when the subagent reports every turn",
    async () => {
      let mainCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TYPED_ON_CHILD")) return text("child_typed", "SWITCH_CHILD_ANSWERED_TYPED");
          return text("child_answer", "SWITCH_CHILD_FIRST");
        }
        mainCalls += 1;
        // The report says the user started that turn, not main.
        if (body.includes("SWITCH_CHILD_ANSWERED_TYPED") && body.includes('\\"started_by\\":\\"user\\"')) {
          return text("main_saw_typed", "SWITCH_MAIN_SAW_TYPED");
        }
        if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reviewer", message: "SWITCH_TASK look for nothing", report: "every_turn" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_FIRST"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("SWITCH_TYPED_ON_CHILD please");
        await session.waitForText("SWITCH_CHILD_ANSWERED_TYPED", 30_000);
        await moveAgent(session, -1);
        // The turn typed there was the subagent's work too, and reported.
        await session.waitForText("SWITCH_MAIN_SAW_TYPED", 30_000);
      });
    },
    TIMEOUT,
  );

  test(
    "a subagent knows who started it, so a turn typed on its screen can message main, which sees the user started that turn",
    async () => {
      let markedByUser = false;
      await withFx((body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TELL_MAIN") || body.includes('"child_up"')) {
            // It reaches main through "parent" only once its prompt says who started it.
            if (!body.includes('You are the subagent \\"reviewer\\", started by \\"main\\"')) {
              return text("child_lost", "SWITCH_CHILD_NO_ROLE");
            }
            if (!body.includes('"child_up"')) {
              return toolCall("child_up", "subagent", {
                request: { action: "message", agent: "parent", message: "SWITCH_HI_FROM_CHILD" },
              });
            }
            return text("child_told", "SWITCH_CHILD_TOLD_MAIN");
          }
          return text("child_answer", "SWITCH_CHILD_FIRST");
        }
        if (body.includes("SWITCH_HI_FROM_CHILD")) {
          markedByUser = userTexts(body).some((t) => t.includes("SWITCH_HI_FROM_CHILD") && t.includes('"started_by":"user"'));
          return text("main_got_hi", "SWITCH_MAIN_GOT_HI");
        }
        if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (!body.includes('"main_sub"')) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reviewer", message: "SWITCH_TASK look for nothing" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_FIRST"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("SWITCH_TELL_MAIN tell main I said hi");
        await session.waitForText("SWITCH_CHILD_TOLD_MAIN", 30_000);
        await moveAgent(session, -1);
        await session.waitForText("SWITCH_MAIN_GOT_HI", 30_000);
      });
      expect(markedByUser).toBe(true);
    },
    TIMEOUT,
  );
  test(
    "a task with terminal escapes shows them as text on the subagent's screen and never sends them",
    async () => {
      // A parent model's message could carry these: a title change, a color,
      // and a C1 control that clears the screen.
      const HOSTILE = "SWITCH_TASK \u001b]2;pwned\u0007 \u001b[31mred\u001b[0m \u009b2J tail";
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_CHILD_FIRST");
        if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (!body.includes('"main_sub"')) {
          return toolCall("main_sub", "subagent", { request: { action: "message", agent: "reviewer", message: HOSTILE } });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { tape }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        const pane = await session.waitForPane((value) => value.includes("SWITCH_CHILD_FIRST"), 15_000);
        // The subagent's screen shows the task with its escapes as text.
        expect(pane).toContain("SWITCH_TASK \\x1b]2;pwned\\x07 \\x1b[31mred\\x1b[0m \\u{009b}2J tail");
        expect(await session.paneTitle()).not.toBe("pwned");
        await moveAgent(session, -1);
        await session.waitForComposer(15_000);
        // fx never wrote the sequences themselves to the terminal.
        const written = readFileSync(tape).toString("latin1");
        expect(written).not.toContain("\u001b]2;pwned");
        expect(written).not.toContain("\u001b[31mred");
        expect(written).not.toContain("\u00c2\u009b2J");
      }, () => {}, true);
    },
    TIMEOUT,
  );
  test(
    "the tab title names the agent on screen, and a subagent's title never takes over main's",
    async () => {
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_CHILD_FIRST");
        if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (!body.includes('"main_sub"')) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reviewer", message: "SWITCH_TASK look for nothing" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        await session.waitForComposer(15_000);
        // The subagent's title arrived after main's, and main is still on screen.
        const mainTitle = await stablePaneTitle(session);
        expect(mainTitle).not.toBe("");
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_FIRST"), 15_000);
        const childTitle = await waitForPaneTitle(session, (title) => title !== "" && title !== mainTitle);
        await moveAgent(session, -1);
        await waitForPaneTitle(session, (title) => title === mainTitle);
        expect(childTitle).not.toBe(mainTitle);
      });
    },
    TIMEOUT,
  );

  test(
    "an Enter with nothing typed on a subagent's screen opens no turn there",
    async () => {
      await withFx((body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TYPED")) return text("child_typed", "SWITCH_CHILD_TYPED");
          return text("child_answer", "SWITCH_CHILD_FIRST");
        }
        if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (!body.includes('"main_sub"')) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reviewer", message: "SWITCH_TASK look for nothing" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { home }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_FIRST"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendKeys("Enter");
        await session.sendText("SWITCH_TYPED a real turn");
        await session.waitForText("SWITCH_CHILD_TYPED", 30_000);
        // Only the turn that ran opened a work in main's log, and it says the
        // user started it, so a restart can still tell.
        const spawns = childLogLines(home).filter((line) => line.kind === "child_spawned" && line.work_id?.startsWith("fxuser:"));
        expect(spawns).toHaveLength(1);
        expect(spawns[0]!.data?.by).toBe("user");
      });
    },
    TIMEOUT,
  );
  test(
    "a turn typed on a subagent's screen that fx dies during reaches main after a resume as the user's",
    async () => {
      const typed = held();
      let typedReached = false;
      let reports: string[] = [];
      try {
        await withFx(async (body) => {
          if (!isMainRequest(body)) {
            if (latestUserText(body).includes("SWITCH_TYPED")) {
              typedReached = true;
              await typed.promise;
              return text("child_typed", "SWITCH_CHILD_TYPED");
            }
            return text("child_answer", "SWITCH_CHILD_FIRST");
          }
          const interrupted = userTexts(body).filter((t) => t.includes('"child_id"') && t.includes('"outcome":"interrupted"'));
          if (interrupted.length > 0) {
            reports = interrupted;
            return text("main_saw_report", "SWITCH_MAIN_SAW_REPORT");
          }
          if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
          if (!body.includes('"main_sub"')) {
            return toolCall("main_sub", "subagent", { request: { action: "message", agent: "reviewer", message: "SWITCH_TASK look for nothing" } });
          }
          return text("main_done", "SWITCH_MAIN_DONE");
        }, async (session, { home, launch }) => {
          await session.sendText("SWITCH_USER");
          await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
          await session.waitForComposer(15_000);
          await moveAgent(session, 1);
          await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_FIRST"), 15_000);
          await session.waitForComposer(15_000);
          await session.sendText("SWITCH_TYPED a turn the crash cuts off");
          await until("the typed turn's request", () => typedReached);

          // Kill fx while that turn's request is out, as a crash would.
          const pid = session.processPid();
          process.kill(pid, "SIGKILL");
          const deadline = Date.now() + 10_000;
          while (Date.now() < deadline) {
            try { process.kill(pid, 0); } catch { break; }
            await Bun.sleep(25);
          }
          await session.kill();

          const sessions = join(home, ".fx", "sessions", "v2");
          const holds = (path: string, marker: string): boolean => readdirSync(path).some((entry) => {
            const full = join(path, entry);
            return statSync(full).isDirectory() ? holds(full, marker) : readFileSync(full, "latin1").includes(marker);
          });
          const parents = readdirSync(sessions).filter((id) =>
            !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id), "SWITCH_MAIN_SAW_FIRST"));
          expect(parents).toHaveLength(1);
          const resumed = await launch(`--resume ${parents[0]}`);
          await resumed.waitForText("SWITCH_MAIN_SAW_REPORT", 30_000);
          await resumed.waitForComposer(15_000);
          await resumed.sendText("/quit");
          expect(await resumed.waitForSessionEnd(15_000)).toBe(true);
        });
      } finally {
        typed.release();
      }
      // Main hears of the cut-off turn once, as the user's, not its own.
      expect(reports).toHaveLength(1);
      expect(reports[0]).toContain('"started_by":"user"');
    },
    TIMEOUT,
  );

  test(
    "a message main sent into a subagent's turn whose request fails still reaches the subagent",
    async () => {
      let childCalls = 0;
      let mainCalls = 0;
      let resentAsItWas = false;
      const first = held();
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          // The first request fails after main's second message joins the turn.
          if (childCalls === 1) {
            await first.promise;
            return unavailable();
          }
          const took = userTexts(body).some((t) => t.includes("SWITCH_MORE"));
          if (childCalls === 2) resentAsItWas = !took;
          return text("child_more", took ? "SWITCH_CHILD_DID_MORE" : "SWITCH_CHILD_OTHER");
        }
        mainCalls += 1;
        if (body.includes("SWITCH_CHILD_DID_MORE")) return text("main_saw_more", "SWITCH_MAIN_SAW_MORE");
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "worker", message: "SWITCH_TASK work slowly" },
          });
        }
        if (mainCalls === 2) {
          // Sent while the subagent's turn runs, so it joins that turn.
          await until("the subagent's turn", () => childCalls >= 1);
          return toolCall("main_more", "subagent", {
            request: { action: "message", agent: "worker", message: "SWITCH_MORE one more thing" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_DONE", 30_000);
        first.release();
        // fx waits out the outage and sends the same request again, then the
        // turn takes main's message, and the subagent's report says so.
        await session.waitForText("SWITCH_MAIN_SAW_MORE", 30_000);
        expect(resentAsItWas).toBe(true);
        expect(childCalls).toBe(3);
      });
    },
    TIMEOUT,
  );

  test(
    "a report from a subagent's own subagent wakes it, and what it does then reaches main",
    async () => {
      let leadReported = false;
      let helperRole = false;
      let leadRole = false;
      let helperNests = false;
      let leadNests = false;
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          if (userTexts(body).some((text) => text.includes("SWITCH_HELPER_TASK"))) {
            helperRole ||= body.includes('You are the subagent \\"helper\\", started by \\"lead\\"');
            // fx nests two levels: lead's own subagent starts none.
            helperNests ||= toolNames(body).includes("subagent");
            // The helper answers once lead's turn has ended, so its report wakes lead.
            await until("lead's report", () => leadReported);
            return text("helper", "SWITCH_HELPER_DONE");
          }
          leadRole ||= body.includes('You are the subagent \\"lead\\", started by \\"main\\"');
          leadNests ||= toolNames(body).includes("subagent");
          if (body.includes("SWITCH_HELPER_DONE")) return text("lead_after", "SWITCH_LEAD_SAW_HELPER");
          if (!body.includes('"lead_sub"')) {
            return toolCall("lead_sub", "subagent", {
              request: { action: "message", agent: "helper", message: "SWITCH_HELPER_TASK" },
            });
          }
          return text("lead_started", "SWITCH_LEAD_STARTED");
        }
        if (body.includes("SWITCH_LEAD_STARTED")) leadReported = true;
        if (body.includes("SWITCH_LEAD_SAW_HELPER")) return text("main_saw_after", "SWITCH_MAIN_SAW_LEAD_AFTER");
        if (!body.includes('"main_sub"')) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "lead", message: "SWITCH_LEAD_TASK" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        // Lead's woken turn was its work too, and reported to main.
        await session.waitForText("SWITCH_MAIN_SAW_LEAD_AFTER", 30_000);
      });
      // Each subagent's system prompt names it and the agent that started it.
      expect(leadRole).toBe(true);
      expect(helperRole).toBe(true);
      expect(leadNests).toBe(true);
      expect(helperNests).toBe(false);
    },
    TIMEOUT,
  );

  test(
    "main's stop ends a turn typed on a subagent's screen, which then owes no report",
    async () => {
      const typed = held();
      let typedAsked = false;
      const bodies = await withFx(async (body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TYPED_SLOW")) {
            typedAsked = true;
            await typed.promise;
            return text("child_typed", "SWITCH_CHILD_LATE");
          }
          return text("child_answer", "SWITCH_CHILD_FIRST");
        }
        if (body.includes("Stopped reviewer: its turn ended")) return text("main_stopped", "SWITCH_MAIN_STOPPED");
        if (body.includes("reviewer was not working")) return text("main_not", "SWITCH_MAIN_NOT_STOPPED");
        if (latestUserText(body).includes("SWITCH_USER_STOP")) {
          return toolCall("main_stop", "subagent", { request: { action: "stop", agent: "reviewer" } });
        }
        if (body.includes("SWITCH_CHILD_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (!body.includes('"main_sub"')) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reviewer", message: "SWITCH_TASK look", report: "every_turn" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_CHILD_FIRST"), 15_000);
        await session.waitForComposer(15_000);
        await session.sendText("SWITCH_TYPED_SLOW please");
        await until("the typed turn", () => typedAsked);
        await moveAgent(session, -1);
        await session.waitForComposer(15_000);
        await session.sendText("SWITCH_USER_STOP stop the reviewer");
        await session.waitForText("SWITCH_MAIN_STOPPED", 30_000);
        typed.release();
        await session.waitForComposer(15_000);
        await Bun.sleep(1_000);
      });
      // Main's own stop answers the typed turn, though the subagent reports every turn.
      expect(bodies.some((body) => body.includes('\\"outcome\\":\\"cancelled\\"'))).toBe(false);
      expect(bodies.some((body) => body.includes("SWITCH_MAIN_NOT_STOPPED"))).toBe(false);
    },
    TIMEOUT,
  );

  test(
    "a subagent's approval can be answered on its own screen, and main's clears",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          if (childCalls === 1) {
            return toolCall("child_write", "write_file", { path: "switch-child.txt", content: "SWITCH_WROTE\n" });
          }
          return text("child_done", "SWITCH_WRITER_DONE");
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "writer", message: "SWITCH_WRITE_TASK", profile: "writer" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { workspace }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("Subagent writer needs permission", 30_000);

        // The open list takes the footer from the prompt, which keys can't
        // answer while it is open, and Esc brings the prompt back unanswered.
        await session.sendKeys("C-x");
        const over = await session.waitForText(LIST_HINT, 10_000);
        expect(over).not.toContain("Apply this change?");
        // Its row names the profile it runs in.
        expect(over).toMatch(/writer · [^\n]* · writer · /);
        await session.sendKeys("1");
        await session.sendKeys("Escape");
        const back = await session.waitForPane((pane) => !pane.includes(LIST_HINT) && pane.includes("Apply this change?"), 10_000);
        expect(back).toContain("Subagent writer needs permission");
        expect(existsSync(join(workspace, "switch-child.txt"))).toBe(false);

        // Ctrl+X opens the list while main shows the lent prompt.
        await moveAgent(session, 1);
        await session.waitForPane((pane) =>
          pane.includes("SWITCH_WRITE_TASK") && pane.includes("Subagent writer needs permission"), 15_000);
        await session.sendKeys("1");
        await session.waitForText("SWITCH_WRITER_DONE", 30_000);
        expect(readFileSync(join(workspace, "switch-child.txt"), "utf8")).toBe("SWITCH_WROTE\n");

        // Main's row is above the only subagent's, its prompt gone.
        await moveAgent(session, -1);
        const main = await session.waitForPane((pane) => pane.includes("SWITCH_MAIN_DONE"), 30_000);
        expect(main).not.toContain("needs permission");
      }, (home) => {
        const folder = join(home, ".fx", "agents", "writer");
        mkdirSync(folder, { recursive: true });
        writeFileSync(join(folder, "profile.json"), JSON.stringify({
          description: "Writes one file",
          tools: ["read_file", "write_file"],
          permission_mode: "ask",
        }));
      });
    },
    TIMEOUT,
  );

  test(
    "a subagent's question shows on main's screen, named for it, and is answered there",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      let answer = "";
      await withFx((body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          if (childCalls === 1) {
            return toolCall("child_ask", "ask_user_question", {
              questions: [{ question: "SWITCH_QUESTION pick one", options: [{ label: "SWITCH_ALPHA" }, { label: "SWITCH_BETA" }] }],
            });
          }
          answer = body;
          return text("child_done", "SWITCH_ASKER_DONE");
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "asker", message: "SWITCH_ASK_TASK" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER");
        await session.waitForPane((pane) => pane.includes("SWITCH_QUESTION pick one") && pane.includes("asker asks"), 30_000);
        await session.sendKeys("1");
        const main = await session.waitForPane((pane) => pane.includes("SWITCH_MAIN_DONE"), 30_000);
        expect(main).not.toContain("SWITCH_QUESTION");
        expect(answer).toContain("SWITCH_ALPHA");

        // The question and its answer belong to the subagent's conversation.
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_ASKER_DONE"), 15_000);
      });
    },
    TIMEOUT,
  );

  test(
    "a subagent with no mode of its own follows main's as it changes, on its next tool call",
    async () => {
      let mainCalls = 0;
      let childCalls = 0;
      const first = held();
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TYPED")) {
            if (body.includes('"typed_write"')) return text("typed_done", "SWITCH_TYPED_DONE");
            return toolCall("typed_write", "write_file", { path: "typed.txt", content: "TYPED\n" });
          }
          childCalls += 1;
          if (childCalls > 1) return text("child_done", "SWITCH_FOLLOWER_DONE");
          await first.promise;
          return toolCall("child_write", "write_file", { path: "followed.txt", content: "FOLLOWED\n" });
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "follower", message: "SWITCH_FOLLOW_TASK write a note" },
          });
        }
        return text("main_done", "SWITCH_MAIN_DONE");
      }, async (session, { workspace }) => {
        // The subagent starts while main is in ask, then main moves to auto
        // before the subagent's write, which then runs without asking.
        await session.sendText("SWITCH_USER");
        await until("the subagent's first request", () => childCalls === 1);
        await session.sendKeys("BTab");
        await session.waitForText("auto ·", 10_000);
        first.release();
        // Main's turn ended with the receipt; the report comes once the
        // subagent's write is done.
        await session.waitForText("follower completed", 30_000);
        expect(readFileSync(join(workspace, "followed.txt"), "utf8")).toBe("FOLLOWED\n");
        expect(await session.captureFullScrollback()).not.toContain("needs permission");

        // Its footer shows the mode it follows.
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("SWITCH_FOLLOWER_DONE") && pane.includes("auto ·"), 15_000);

        // Tightening main tightens it: back in ask, a write the user asks of
        // it on its own screen waits for an answer.
        await moveAgent(session, -1);
        await session.sendText("/permissions ask");
        await session.waitForText("mode set to ask", 10_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("ask ·"), 15_000);
        await session.sendText("SWITCH_TYPED write again");
        await session.waitForText("Apply this change?", 30_000);
        expect(existsSync(join(workspace, "typed.txt"))).toBe(false);
        await session.sendKeys("1");
        await session.waitForText("SWITCH_TYPED_DONE", 30_000);
        expect(readFileSync(join(workspace, "typed.txt"), "utf8")).toBe("TYPED\n");
      }, () => {}, false, { FX_PERMISSION_MODE: "ask" });
    },
    TIMEOUT,
  );

  test(
    "main's screen shows the subagent prompt asked first, whichever subagent started first",
    async () => {
      const gates = { first: held(), second: held() };
      const seen = { first: 0, second: 0 };
      const started = { first: false, second: false };
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          const who: "first" | "second" = userTexts(body).some((t) => t.includes("SWITCH_TASK_SECOND")) ? "second" : "first";
          if (body.includes(`"write_${who}"`)) return text(`done_${who}`, `CHILD_DONE_${who.toUpperCase()}`);
          seen[who] += 1;
          await gates[who].promise;
          return toolCall(`write_${who}`, "write_file", { path: `${who}.txt`, content: `${who}\n` });
        }
        if (body.includes("CHILD_DONE_FIRST")) return text("main_saw_first", "SWITCH_MAIN_SAW_FIRST");
        if (body.includes("CHILD_DONE_SECOND")) return text("main_saw_second", "SWITCH_MAIN_SAW_SECOND");
        if (latestUserText(body).includes("START_SECOND") && !started.second) {
          started.second = true;
          return toolCall("main_second", "subagent", {
            request: { action: "message", agent: "second", message: "SWITCH_TASK_SECOND write second.txt" },
          });
        }
        if (!started.first) {
          started.first = true;
          return toolCall("main_first", "subagent", {
            request: { action: "message", agent: "first", message: "SWITCH_TASK_FIRST write first.txt" },
          });
        }
        return text("main_idle", "SWITCH_MAIN_IDLE");
      }, async (session, { workspace }) => {
        await session.sendText("SWITCH_USER start the first");
        await until("the first subagent's request", () => seen.first === 1);
        await session.sendText("SWITCH_USER START_SECOND");
        await until("the second subagent's request", () => seen.second === 1);

        // On the first subagent's screen, the second asks, then the first.
        await moveAgent(session, 1);
        gates.second.release();
        await session.waitForText("second needs approval", 30_000);
        gates.first.release();
        await session.waitForText("Subagent first needs permission", 30_000);

        // Back on main, the second's prompt shows first, then the first's.
        await moveAgent(session, -1);
        const oldest = await session.waitForText("Subagent second needs permission", 15_000);
        expect(oldest).not.toContain("Subagent first needs permission");
        await session.sendKeys("1");
        await session.waitForText("Subagent first needs permission", 15_000);
        expect(readFileSync(join(workspace, "second.txt"), "utf8")).toBe("second\n");
        expect(existsSync(join(workspace, "first.txt"))).toBe(false);
        await session.sendKeys("1");
        await session.waitForText("SWITCH_MAIN_SAW_FIRST", 30_000);
        expect(readFileSync(join(workspace, "first.txt"), "utf8")).toBe("first\n");
      }, () => {}, false, { FX_PERMISSION_MODE: "ask" });
    },
    TIMEOUT,
  );

  test(
    "after a restart, the agent list shows a subagent's saved conversation before it runs again",
    async () => {
      let mainCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) return text("child_answer", "SWITCH_SAVED_ANSWER");
        mainCalls += 1;
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reviewer", message: "SWITCH_SAVED_TASK" },
          });
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session, { home, launch }) => {
        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_FINAL", 30_000);
        await session.waitForComposer(15_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);

        // Main's session is the one holding its final answer; the
        // subagent's own log holds only its task and answer.
        const sessions = join(home, ".fx", "sessions", "v2");
        const holds = (path: string): boolean => readdirSync(path).some((entry) => {
          const full = join(path, entry);
          return statSync(full).isDirectory() ? holds(full) : readFileSync(full, "latin1").includes("SWITCH_MAIN_FINAL");
        });
        const parent = readdirSync(sessions).find((id) => !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id)));
        expect(parent).toBeDefined();
        const resumed = await launch(`--resume ${parent}`);
        await moveAgent(resumed, 1);
        const subagent = await resumed.waitForPane((pane) =>
          pane.includes("SWITCH_SAVED_ANSWER") && pane.includes("reviewer \u00b7 done"), 15_000);
        expect(subagent).toContain("SWITCH_SAVED_TASK");
        // One with a saved conversation shows it instead, as a resumed fx does.
        expect(subagent).not.toContain("Run /help for commands");
        await moveAgent(resumed, -1);
        await resumed.waitForPane((pane) => pane.includes("SWITCH_MAIN_FINAL"), 15_000);
      });
    },
    TIMEOUT,
  );

  test(
    "/compact on a subagent's screen saves to its own session, and its next turns use it, after a restart too",
    async () => {
      const summary = "Facts:\nF1: SWITCH_COMPACT_SUMMARY: the subagent read notes.txt for main.";
      const history = "history alpha beta gamma delta sample line\n".repeat(1600);
      let mainCalls = 0;
      const bodies = await withFx((body) => {
        // The compactor asks for its summary with no tools.
        const request = JSON.parse(body) as { toolChoice?: { type?: string }; tools?: unknown[] };
        if (request.toolChoice?.type === "none" && request.tools?.length === 0) return text("summary", summary);
        if (!isMainRequest(body)) {
          const latest = latestUserText(body);
          if (latest.includes("SWITCH_AFTER_COMPACT")) return text("child_after", "SWITCH_CHILD_AFTER");
          if (latest.includes("SWITCH_AFTER_RESUME")) return text("child_resumed", "SWITCH_CHILD_RESUMED");
          // The subagent reads a file and answers at length, which leaves work to compact.
          if (!body.includes('"child_read"')) return toolCall("child_read", "read_file", { path: "notes.txt" });
          return text("child_answer", `SWITCH_CHILD_ANSWER\n${history}`);
        }
        mainCalls += 1;
        if (mainCalls === 1) {
          return toolCall("main_sub", "subagent", {
            request: { action: "message", agent: "reader", message: "SWITCH_TASK read notes.txt" },
          });
        }
        return text("main_final", "SWITCH_MAIN_FINAL");
      }, async (session, { home, workspace, launch }) => {
        writeFileSync(join(workspace, "notes.txt"), "SWITCH_NOTES\n");
        const sessions = join(home, ".fx", "sessions", "v2");
        const holds = (path: string, marker: string): boolean => readdirSync(path).some((entry) => {
          const full = join(path, entry);
          return statSync(full).isDirectory() ? holds(full, marker) : readFileSync(full, "latin1").includes(marker);
        });
        // The saved sessions whose files hold `marker`.
        const holding = (marker: string) => readdirSync(sessions).filter((id) =>
          !id.startsWith(".") && statSync(join(sessions, id)).isDirectory() && holds(join(sessions, id), marker));

        await session.sendText("SWITCH_USER");
        await session.waitForText("SWITCH_MAIN_FINAL", 30_000);
        await session.waitForComposer(15_000);
        await moveAgent(session, 1);
        await session.waitForPane((pane) => pane.includes("reader \u00b7 "), 15_000);
        await session.sendText("/compact");
        const deadline = Date.now() + 30_000;
        while (holding("SWITCH_COMPACT_SUMMARY").length === 0 && Date.now() < deadline) await Bun.sleep(100);
        await session.waitForComposer(15_000);
        await session.sendText("SWITCH_AFTER_COMPACT");
        await session.waitForText("SWITCH_CHILD_AFTER", 30_000);
        await session.waitForComposer(15_000);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);

        // The summary is saved in the subagent's own session, not main's.
        const parents = holding("SWITCH_MAIN_FINAL");
        expect(parents.length).toBe(1);
        const compacted = holding("SWITCH_COMPACT_SUMMARY");
        expect(compacted.length).toBe(1);
        expect(compacted[0]).not.toBe(parents[0]);
        expect(holding("SWITCH_TASK")).toContain(compacted[0]!);

        // A restart restores the subagent's compacted conversation.
        const resumed = await launch(`--resume ${parents[0]}`);
        await moveAgent(resumed, 1);
        await resumed.waitForPane((pane) => pane.includes("reader \u00b7 "), 15_000);
        await resumed.sendText("SWITCH_AFTER_RESUME");
        await resumed.waitForText("SWITCH_CHILD_RESUMED", 30_000);
      });

      const childTurn = (marker: string) => bodies.find((body) => !isMainRequest(body) && latestUserText(body).includes(marker));
      for (const marker of ["SWITCH_AFTER_COMPACT", "SWITCH_AFTER_RESUME"]) {
        const body = childTurn(marker);
        expect(body).toBeDefined();
        expect(body).toContain("compacted_conversation");
        expect(body).toContain("SWITCH_COMPACT_SUMMARY");
      }
      // Main's model never sees the subagent's summary.
      for (const body of bodies.filter(isMainRequest)) expect(body).not.toContain("SWITCH_COMPACT_SUMMARY");
    },
    TIMEOUT,
  );

  test(
    "with no subagent, Option+Right jumps by word",
    async () => {
      await withFx(() => text("unused", "unused"), async (session) => {
        await session.sendLiteral("alpha beta");
        await session.waitForText("alpha beta", 10_000);
        await session.sendKeys("C-a");
        await session.sendKeys("M-Right");
        await session.sendLiteral("Z");
        const pane = await session.waitForPane((value) => value.includes("Z"), 10_000);
        expect(pane).toMatch(/alpha ?Z ?beta/);
      });
    },
    TIMEOUT,
  );

  // Main has started one subagent, `reviewer`, which answered EDGE_CHILD_ANSWER.
  const withReviewer = (run: (session: TmuxSession) => Promise<void>) => {
    let mainCalls = 0;
    return withFx((body) => {
      if (!isMainRequest(body)) return text("child_answer", "EDGE_CHILD_ANSWER");
      mainCalls += 1;
      if (mainCalls === 1) {
        return toolCall("main_sub", "subagent", {
          request: { action: "message", agent: "reviewer", message: "EDGE_TASK look for nothing" },
        });
      }
      return text("main_final", "EDGE_MAIN_FINAL");
    }, async (session) => {
      await session.sendText("SWITCH_USER_EDGE");
      await session.waitForText("EDGE_MAIN_FINAL", 30_000);
      await session.waitForComposer(15_000);
      await run(session);
    });
  };

  test(
    "with a subagent, Option+arrows only move text and never switch",
    async () => {
      await withReviewer(async (session) => {
        // Inside a draft, Option+Left moves by word.
        await session.sendLiteral("hello world");
        await session.waitForText("hello world", 10_000);
        await session.sendKeys("M-Left");
        await session.sendLiteral("Z");
        await session.waitForPane((pane) => pane.includes("hello Zworld"), 10_000);

        // At the draft's start, and with Terminal.app's ESC b, it stays on
        // main; so does Option+Up.
        await session.sendKeys("C-a");
        await session.sendKeys("M-Left");
        await session.sendKeys("M-b");
        await session.sendKeys("M-Up");
        await session.sendLiteral("Y");
        const stayed = await session.waitForPane((pane) => pane.includes("Yhello Zworld"), 10_000);
        expect(stayed).toContain("main \u00b7 ctrl+x");
        // Main's screen holds the user's prompt; the subagent's opens with
        // main's task as its prompt.
        expect(stayed).toMatch(/^┃ SWITCH_USER_EDGE/m);
        expect(stayed).not.toMatch(/^┃ EDGE_TASK/m);
        expect(stayed).not.toContain(LIST_HINT);
      });
    },
    TIMEOUT,
  );

  test(
    "down on an empty composer opens the agent list, which previews, and Esc goes back",
    async () => {
      await withReviewer(async (session) => {
        // The indicator on the right names main and the key that opens the list.
        expect(await session.capturePane()).toContain("main \u2193");

        // Browsing prompt history, down goes forward through it first: the
        // recalled prompt makes the indicator offer Ctrl+X, and down puts
        // back the empty draft instead of opening the list.
        await session.sendKeys("Up");
        await session.waitForPane((pane) => pane.includes("main \u00b7 ctrl+x"), 10_000);
        await session.sendKeys("Down");
        await session.waitForPane((pane) => pane.includes("main \u2193"), 10_000);
        expect(await session.capturePane()).not.toContain(LIST_HINT);

        // From the idle composer it opens the list on main's row.
        await session.sendKeys("Down");
        const list = await session.waitForText(LIST_HINT, 10_000);
        expect(list).toContain("fx 1 (on screen) \u00b7 ");
        expect(list).toContain("  reviewer \u00b7 ");

        // Down again shows the subagent above the list, and the list stays.
        await session.sendKeys("Down");
        const preview = await session.waitForPane((pane) => pane.includes("EDGE_CHILD_ANSWER") && pane.includes(LIST_HINT), 10_000);
        expect(preview).not.toContain("EDGE_MAIN_FINAL");

        // Esc goes back to main.
        await session.sendKeys("Escape");
        const back = await session.waitForPane((pane) => pane.includes("EDGE_MAIN_FINAL") && !pane.includes(LIST_HINT), 10_000);
        expect(back).toContain("main \u2193");

        // Enter keeps the agent shown.
        await session.sendKeys("Down");
        await session.waitForText(LIST_HINT, 10_000);
        await session.sendKeys("Down");
        await session.waitForText("EDGE_CHILD_ANSWER", 10_000);
        await session.sendKeys("Enter");
        const kept = await session.waitForPane((pane) => !pane.includes(LIST_HINT) && pane.includes("reviewer \u00b7 done \u2193"), 10_000);
        expect(kept).toContain("EDGE_CHILD_ANSWER");
      });
    },
    TIMEOUT,
  );

  test(
    "with a draft, down stays in the composer, Ctrl+X opens the list, and the draft stays where it was typed",
    async () => {
      await withReviewer(async (session) => {
        await session.sendLiteral("EDGE_KEEP_ME");
        await session.waitForPane((pane) => pane.includes("main \u00b7 ctrl+x"), 10_000);
        await session.sendKeys("Down");
        expect(await session.capturePane()).not.toContain(LIST_HINT);

        // Ctrl+X opens the list; typing there does nothing.
        await session.sendKeys("C-x");
        await session.waitForText(LIST_HINT, 10_000);
        await session.sendLiteral("q");
        await session.sendKeys("BSpace");
        await session.sendKeys("Down");
        const preview = await session.waitForPane((pane) => pane.includes("EDGE_CHILD_ANSWER"), 10_000);
        expect(preview).not.toContain("EDGE_KEEP_ME");
        await session.sendKeys("Enter");

        // The subagent's composer is its own and empty.
        const child = await session.waitForPane((pane) => pane.includes("reviewer \u00b7 done \u2193"), 10_000);
        expect(child).not.toContain("EDGE_KEEP_ME");

        // Back on main, the draft is as it was typed.
        await moveAgent(session, -1);
        const main = await session.waitForPane((pane) => pane.includes("\u2503 EDGE_KEEP_ME"), 10_000);
        expect(main).not.toContain("EDGE_KEEP_MEq");
        expect(main).toContain("main \u00b7 ctrl+x");
      });
    },
    TIMEOUT,
  );
  test(
    "the agent list names each agent by its title, profile, state, and model, and main's footer counts the subagents working",
    async () => {
      const reviewer = held();
      let childCalls = 0;
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          await reviewer.promise;
          return text("child_answer", "LIST_CHILD_DONE");
        }
        if (!body.includes('"main_sub"')) {
          return toolCall("main_sub", "subagent", { request: { action: "message", agent: "reviewer", message: "Review src/parser.zig for bugs" } });
        }
        return text("main_wait", "LIST_MAIN_WAITING");
      }, async (session) => {
        await session.sendText("SWITCH_USER plan it");
        await session.waitForText("LIST_MAIN_WAITING", 30_000);
        await until("the reviewer's turn", () => childCalls >= 1);
        // Main shows that work goes on elsewhere, beside the list's key.
        await session.waitForText("1 subagent working \u00b7 main \u2193", 15_000);
        await session.sendKeys("Down");
        // The reviewer's title is the title model's, from its task, as main's is.
        const list = await session.waitForPane((pane) => / {4}reviewer \u00b7 Review the parser \u00b7 main \u00b7 working \u00b7 \S/.test(pane), 15_000);
        expect(list).toMatch(/fx 1 \(on screen\) \u00b7 Plan the parser work \u00b7 main \u00b7 idle \u00b7 \S/);
        expect(list).toContain("\u2191\u2193 preview     enter switch     esc back");
        await session.sendKeys("Escape");
        reviewer.release();
        await session.waitForPane((pane) => !pane.includes("subagent working"), 30_000);
      }, () => {}, false, {}, subagentTitles);
    },
    TIMEOUT,
  );

  test(
    "x, then x again, in the agent list closes a working subagent for good: main hears the user closed it, and a resume doesn't bring it back",
    async () => {
      const reviewer = held();
      let childCalls = 0;
      // The trace lives in the test's home, set before fx starts.
      const env: Record<string, string> = {};
      let tracePath = "";
      await withFx(async (body) => {
        if (!isMainRequest(body)) {
          childCalls += 1;
          await reviewer.promise;
          return text("child_answer", "CLOSE_CHILD_DONE");
        }
        if (!body.includes('"main_sub"')) {
          return toolCall("main_sub", "subagent", { request: { action: "message", agent: "reviewer", message: "Review src/parser.zig for bugs" } });
        }
        if (body.includes('\\"cause\\":\\"user_close\\"')) return text("main_told", "CLOSE_MAIN_TOLD");
        return text("main_wait", "CLOSE_MAIN_WAITING");
      }, async (session, { home, launch }) => {
        await session.sendText("SWITCH_USER review it");
        await session.waitForText("CLOSE_MAIN_WAITING", 30_000);
        await until("the reviewer's turn", () => childCalls >= 1);
        await session.sendKeys("Down");
        await session.waitForText("esc back", 10_000);
        // On main's row, x does nothing: an instance closes with /close. The
        // next key is handled once the hint changes, so by then the trace
        // shows whether x armed anything.
        await session.sendKeys("x");
        await session.sendKeys("Down");
        await session.waitForText("enter switch     x close     esc back", 10_000);
        expect(readFileSync(tracePath, "utf8")).not.toContain("agents_menu_close_armed");
        await session.sendKeys("x");
        await session.waitForText("x again to close it for good", 10_000);
        expect(readFileSync(tracePath, "utf8")).toContain("agents_menu_close_armed");
        // Any other key keeps it.
        await session.sendKeys("Up");
        await session.waitForPane((pane) => !pane.includes("x again to close"), 10_000);
        await session.sendKeys("Down");
        await session.sendKeys("x");
        await session.waitForText("x again to close it for good", 10_000);
        await session.sendKeys("x");
        const closed = await session.waitForPane((pane) => !/^ {4}reviewer \u00b7 /m.test(pane) && pane.includes("esc back"), 15_000);
        // Main is on screen again, and the reviewer's turn ended with the close.
        expect(closed).toContain("SWITCH_USER review it");
        await session.sendKeys("Escape");
        // The list takes every key until it closes, /quit below included.
        await session.waitForPane((pane) => !pane.includes("esc back"), 10_000);
        await session.waitForText("CLOSE_MAIN_TOLD", 30_000);
        expect(await session.capturePane()).not.toContain("subagent working");
        reviewer.release();
        expect(childCalls).toBe(1);
        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(15_000)).toBe(true);

        const parents = sessionsHolding(home, "CLOSE_MAIN_TOLD");
        expect(parents.length).toBe(1);
        const resumed = await launch(`--resume ${parents[0]}`);
        await resumed.waitForText("CLOSE_MAIN_TOLD", 30_000);
        // Main alone: no agent indicator, and ↓ opens no list, which would
        // take the next key; the composer shows it instead.
        expect(await resumed.capturePane()).not.toContain("main \u2193");
        await resumed.sendKeys("Down");
        await resumed.sendLiteral("z");
        const typed = await resumed.waitForPane((pane) => composerContains(pane, "z"), 10_000);
        expect(typed).not.toContain("esc back");
      }, (home) => {
        tracePath = join(home, "fx-trace.log");
        env.FX_TRACE_LOG = tracePath;
      }, false, env);
    },
    TIMEOUT,
  );

  test(
    "closing the middle row of the agent list keeps the highlight on the agent shown, and the first x warns at once",
    async () => {
      await withFx(async (body) => {
        if (!isMainRequest(body)) return text("child_done", "MIDDLE_CHILD_DONE");
        if (!body.includes('"main_r"')) {
          return toolCall("main_r", "subagent", { request: { action: "message", agent: "reviewer", message: "MIDDLE_REVIEW" } });
        }
        if (!body.includes('"main_t"')) {
          return toolCall("main_t", "subagent", { request: { action: "message", agent: "tester", message: "MIDDLE_TEST" } });
        }
        return text("main_done", "MIDDLE_MAIN_DONE");
      }, async (session) => {
        await session.sendText("SWITCH_USER start them");
        await session.waitForText("MIDDLE_MAIN_DONE", 30_000);
        await session.waitForPane((pane) => !pane.includes("subagent working"), 30_000);
        // Rows: fx 1, reviewer, tester. Both subagents are idle, so nothing
        // on screen animates.
        await session.sendKeys("Down");
        await session.waitForText(LIST_HINT, 10_000);
        await session.sendKeys("Down");
        await session.waitForText("enter switch     x close     esc back", 10_000);
        await session.sendKeys("x");
        await session.waitForText("x again to close it for good", 10_000);
        // Any other key keeps it, and its warning goes at once.
        await session.sendKeys("a");
        await session.waitForText("enter switch     x close     esc back", 10_000);
        // X closes too, so Caps Lock doesn't get in the way.
        await session.sendKeys("X");
        await session.waitForText("x again to close it for good", 10_000);
        await session.sendKeys("x");
        // Main is shown, and the highlight is on its row, not on tester's.
        const closed = await session.waitForPane((pane) => !/^ {4}reviewer \u00b7 /m.test(pane) && pane.includes("esc back"), 15_000);
        expect(closed).toMatch(/^ {4}tester \u00b7 /m);
        expect(closed).toContain("\u2191\u2193 preview     enter switch     esc back");
        expect(closed).not.toContain("x close");
        await session.sendKeys("Enter");
        const kept = await session.waitForPane((pane) => !pane.includes("esc back"), 10_000);
        expect(kept).toContain("MIDDLE_MAIN_DONE");
        expect(kept).toContain("main \u2193");
      });
    },
    TIMEOUT,
  );

  test(
    "main's close removes an idle subagent from the agent list, and its row says closed",
    async () => {
      let mainCalls = 0;
      await withFx(async (body) => {
        if (!isMainRequest(body)) return text("child_answer", "MAIN_CLOSE_TESTS_PASS");
        mainCalls += 1;
        if (mainCalls === 1) return toolCall("main_sub", "subagent", { request: { action: "message", agent: "tester", message: "Run the auth tests" } });
        if (body.includes("Closed tester.")) return text("main_done", "MAIN_CLOSE_DONE");
        if (body.includes("MAIN_CLOSE_TESTS_PASS")) return toolCall("main_close", "subagent", { request: { action: "close", agent: "tester" } });
        return text("main_wait", "MAIN_CLOSE_WAITING");
      }, async (session) => {
        await session.sendText("SWITCH_USER run them");
        const pane = await session.waitForText("MAIN_CLOSE_DONE", 60_000);
        expect(pane).toContain("\u2514 closed tester");
        // Main alone again: no agent indicator, and ↓ opens no list, which
        // would take the next key; the composer shows it instead.
        await session.waitForPane((value) => !value.includes("main \u2193"), 10_000);
        await session.sendKeys("Down");
        await session.sendLiteral("z");
        const typed = await session.waitForPane((pane) => composerContains(pane, "z"), 10_000);
        expect(typed).not.toContain("esc back");
      });
    },
    TIMEOUT,
  );
});
