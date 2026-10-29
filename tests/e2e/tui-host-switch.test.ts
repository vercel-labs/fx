import { describe, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
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
) {
  const gateway = startDynamicFakeGateway(respond);
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
        // The subagent's report of main's message shows as a card.
        expect(main).toContain("Report from reviewer: completed (ctrl+o to view)");
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
          return toolCall("main_more", "subagent", {
            request: { action: "message", agent: "worker", message: "SWITCH_MORE one more thing" },
          });
        }
        if (body.includes('\\"dropped\\":1')) return text("main_saw", "SWITCH_MAIN_SAW_DROP");
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
    "a turn typed on a subagent's screen reports to main when the subagent reports every turn",
    async () => {
      let mainCalls = 0;
      await withFx((body) => {
        if (!isMainRequest(body)) {
          if (latestUserText(body).includes("SWITCH_TYPED_ON_CHILD")) return text("child_typed", "SWITCH_CHILD_ANSWERED_TYPED");
          return text("child_answer", "SWITCH_CHILD_FIRST");
        }
        mainCalls += 1;
        if (body.includes("SWITCH_CHILD_ANSWERED_TYPED")) return text("main_saw_typed", "SWITCH_MAIN_SAW_TYPED");
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
        await session.waitForText("Report from follower: completed", 30_000);
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
        expect(stayed).not.toContain("EDGE_CHILD_ANSWER");
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
});
