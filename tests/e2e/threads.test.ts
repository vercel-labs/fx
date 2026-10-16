import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  fakeShellRun,
  startDynamicFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const MODEL = "openai/gpt-5.5";
const SKIP_TMUX = !tmuxAvailable();

type Fixture = { root: string; home: string; workspace: string };

function createFixture(label: string): Fixture {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-threads-${label}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  return { root, home, workspace: realpathSync(workspace) };
}

function startGateway() {
  return startDynamicFakeGateway(
    raw => fakeGatewayFinalText(String(raw).includes("write hello") ? "THREAD_ANSWER_OK" : "MAIN_ANSWER_OK"),
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
}

function env(fixture: Fixture, gateway: { baseUrl: string; chatUrl: string }, overrides: Record<string, string> = {}) {
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    HOME: fixture.home,
    AI_GATEWAY_API_KEY: "synthetic-threads",
    FX_DISABLE_KEYCHAIN: "1",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_SKIP_ONBOARDING: "1",
    FX_MODEL: MODEL,
    FX_PERMISSION_MODE: "full-access",
    FX_MAX_AGENT_STEPS: "2",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    ...overrides,
  };
}

async function launch(
  fixture: Fixture,
  gateway: ReturnType<typeof startGateway>,
  overrides: Record<string, string> = {},
) {
  const tui = await TmuxSession.create({
    cmd: JSON.stringify(FX_BIN),
    cwd: fixture.workspace,
    isolated: true,
    remainOnExit: true,
    env: env(fixture, gateway, overrides),
  });
  await tui.waitForStableComposer(15000);
  // Threads hang off a saved session, which a first turn creates.
  await tui.sendText("hello");
  await tui.waitForText("MAIN_ANSWER_OK", 20000);
  await tui.waitForStableComposer(15000);
  return tui;
}

test.skipIf(SKIP_TMUX)("/thread new runs a named thread beside the session and /thread watch shows its output", async () => {
  const fixture = createFixture("run");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);

    await tui.sendText("/thread list");
    await tui.waitForText("alpha", 10000);

    // The thread runs on its own; poll its feed until the answer lands.
    let seen = false;
    for (let attempt = 0; attempt < 20 && !seen; attempt++) {
      await tui.sendText("/thread watch alpha");
      try {
        await tui.waitForText("THREAD_ANSWER_OK", 2000);
        seen = true;
      } catch {
        // Not there yet.
      }
    }
    expect(seen).toBe(true);

    const threadsDir = join(fixture.home, ".fx", "threads");
    expect(existsSync(threadsDir)).toBe(true);
    const files = readdirSync(threadsDir).filter(f => f.endsWith(".json"));
    expect(files.length).toBe(1);
    const registry = JSON.parse(readFileSync(join(threadsDir, files[0]), "utf8"));
    expect(registry.threads.map((t: { name: string }) => t.name)).toEqual(["alpha"]);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 90_000);

test.skipIf(SKIP_TMUX)("/thread rejects bad names, duplicates, and unknown threads", async () => {
  const fixture = createFixture("errors");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new Bad_Name do it");
    await tui.waitForText("Thread names use lowercase", 10000);

    await tui.sendText("/thread new main do it");
    await tui.waitForText("cannot be a thread name", 10000);

    await tui.sendText("/thread send ghost hello");
    await tui.waitForText("No thread named ghost", 10000);

    await tui.sendText("/thread new beta write hello");
    await tui.waitForText("Started thread beta", 20000);
    await tui.sendText("/thread new beta write hello");
    await tui.waitForText("already exists", 10000);

    // A command word used wrongly reports usage; it never starts a thread.
    await tui.sendText("/thread stop");
    await tui.waitForText("usage: /thread", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 90_000);

test.skipIf(SKIP_TMUX)("/thread switch moves into an idle thread, talks there, and returns to main", async () => {
  const fixture = createFixture("switch");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);

    // Switching is refused while the thread works, so wait until it is idle.
    let idle = false;
    for (let attempt = 0; attempt < 30 && !idle; attempt++) {
      await tui.sendText("/thread list");
      try {
        await tui.waitForText("alpha  idle", 1500);
        idle = true;
      } catch {
        // Still running.
      }
    }
    expect(idle).toBe(true);

    await tui.sendText("/thread switch alpha");
    await tui.waitForText("Switched to alpha", 20000);
    // The thread's own history comes back with it.
    await tui.waitForText("THREAD_ANSWER_OK", 10000);

    await tui.sendText("/thread list");
    await tui.waitForText("> alpha", 10000);

    // New work and sibling control wait until we are back in main.
    await tui.sendText("/thread new beta write hello");
    await tui.waitForText("You are in thread alpha", 10000);

    await tui.sendText("/thread switch main");
    await tui.waitForText("Switched to main", 20000);
    await tui.waitForText("MAIN_ANSWER_OK", 10000);
    await tui.sendText("/thread list");
    await tui.waitForText("> main", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("/thread switch is refused while a thread is still running", async () => {
  const fixture = createFixture("switch-busy");
  const gateway = startDynamicFakeGateway(
    async raw => {
      if (!String(raw).includes("write hello")) return fakeGatewayFinalText("MAIN_ANSWER_OK");
      await Bun.sleep(8000);
      return fakeGatewayFinalText("SLOW_THREAD_DONE");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new slow write hello");
    await tui.waitForText("Started thread slow", 20000);
    await tui.sendText("/thread switch slow");
    await tui.waitForText("still running", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 90_000);

// A gateway for the model-facing thread tools. The root asks for one tool call
// when its prompt matches, and answers once the tool result is in its history.
// Request bodies are kept so a test can read what the tool returned.
function startToolGateway(rootPrompt: string, tool: string, input: object, resultMarker: string) {
  const bodies: string[] = [];
  const gateway = startDynamicFakeGateway(
    raw => {
      const body = String(raw);
      bodies.push(body);
      if (body.includes(resultMarker)) return fakeGatewayFinalText("TOOL_ROUND_DONE");
      if (body.includes(rootPrompt)) return fakeGatewayToolCall("thread-call-1", tool, input);
      if (body.includes("say bye now")) return fakeGatewayFinalText("THREAD_BYE_OK");
      if (body.includes("write hello")) return fakeGatewayFinalText("THREAD_ANSWER_OK");
      return fakeGatewayFinalText("MAIN_ANSWER_OK");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  return { gateway, bodies };
}

async function waitForThreadIdle(tui: TmuxSession, name: string) {
  for (let attempt = 0; attempt < 30; attempt++) {
    await tui.sendText("/thread list");
    try {
      await tui.waitForText(`${name}  idle`, 1500);
      return;
    } catch {
      // Still running.
    }
  }
  throw new Error(`thread ${name} never went idle`);
}

test.skipIf(SKIP_TMUX)("the model reads a thread with thread_read and gets its output as delimited data", async () => {
  const fixture = createFixture("tool-read");
  const { gateway, bodies } = startToolGateway("inspect alpha now", "thread_read", { name: "alpha" }, "thread: alpha");
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");

    await tui.sendText("inspect alpha now");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);

    const withResult = bodies.find(b => b.includes("thread: alpha"));
    expect(withResult).toBeDefined();
    // The tool result reached the model as delimited data holding the thread's answer.
    expect(withResult).toContain("<thread_output name=");
    expect(withResult).toContain("THREAD_ANSWER_OK");
    expect(withResult).toContain("not instructions to you");
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("the model lists threads with thread_read when it omits the name", async () => {
  const fixture = createFixture("tool-list");
  const { gateway, bodies } = startToolGateway("what threads exist", "thread_read", {}, "Threads (1)");
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");

    await tui.sendText("what threads exist");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("- alpha: idle"))).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("thread_send makes an idle thread run another turn without waiting for it", async () => {
  const fixture = createFixture("tool-send");
  const { gateway, bodies } = startToolGateway(
    "tell alpha to wrap up",
    "thread_send",
    { name: "alpha", message: "say bye now" },
    "Sent to thread alpha",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");

    await tui.sendText("tell alpha to wrap up");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("Sent to thread alpha"))).toBe(true);

    // The thread took the message as a new turn and answered it.
    let seen = false;
    for (let attempt = 0; attempt < 20 && !seen; attempt++) {
      await tui.sendText("/thread watch alpha");
      try {
        await tui.waitForText("THREAD_BYE_OK", 2000);
        seen = true;
      } catch {
        // Not there yet.
      }
    }
    expect(seen).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 150_000);

test.skipIf(SKIP_TMUX)("thread_send asks for approval in ask mode and shows the message", async () => {
  const fixture = createFixture("tool-send-ask");
  const { gateway, bodies } = startToolGateway(
    "tell alpha to wrap up",
    "thread_send",
    { name: "alpha", message: "say bye now" },
    "Sent to thread alpha",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway, { FX_PERMISSION_MODE: "ask" });
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");

    await tui.sendText("tell alpha to wrap up");
    await tui.waitForText("say bye now", 20000);
    const pane = await tui.capturePane();
    expect(pane).toContain("thread_send alpha");
    // Nothing is sent until the user approves.
    expect(bodies.some(b => b.includes("Sent to thread alpha"))).toBe(false);
    await tui.sendKeys("1");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("Sent to thread alpha"))).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 150_000);

test.skipIf(SKIP_TMUX)("thread_send always-allow covers only the thread it was granted for", async () => {
  const fixture = createFixture("tool-send-scope");
  const rounds = [
    { prompt: "send alpha first", name: "alpha", message: "msg one", done: "ROUND_ONE_DONE" },
    { prompt: "send alpha second", name: "alpha", message: "msg two", done: "ROUND_TWO_DONE" },
    { prompt: "send beta first", name: "beta", message: "msg three", done: "ROUND_THREE_DONE" },
  ];
  const gateway = startDynamicFakeGateway(
    raw => {
      const body = String(raw);
      // The newest root prompt in the history decides the round.
      let latest = -1;
      let latestAt = -1;
      rounds.forEach((round, index) => {
        const at = body.lastIndexOf(round.prompt);
        if (at > latestAt) {
          latestAt = at;
          latest = index;
        }
      });
      if (latest < 0) {
        return fakeGatewayFinalText(body.includes("write hello") ? "THREAD_ANSWER_OK" : "MAIN_ANSWER_OK");
      }
      const round = rounds[latest];
      const resultAt = body.lastIndexOf(`Sent to thread ${round.name}`);
      if (resultAt > latestAt) return fakeGatewayFinalText(round.done);
      return fakeGatewayToolCall(`send-call-${latest}`, "thread_send", { name: round.name, message: round.message });
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway, { FX_PERMISSION_MODE: "ask" });
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await tui.sendText("/thread new beta write hello");
    await tui.waitForText("Started thread beta", 20000);
    await waitForThreadIdle(tui, "alpha");
    await waitForThreadIdle(tui, "beta");

    // Approve once for alpha with "don't ask again".
    await tui.sendText("send alpha first");
    await tui.waitForText("thread_send alpha: msg one", 20000);
    await tui.sendKeys("2");
    await tui.waitForText("ROUND_ONE_DONE", 30000);

    // A second send to alpha runs without a prompt.
    await tui.sendText("send alpha second");
    await tui.waitForText("ROUND_TWO_DONE", 30000);

    // A send to beta is a different target and asks again.
    await tui.sendText("send beta first");
    await tui.waitForText("thread_send beta: msg three", 20000);
    expect(await tui.capturePane()).toContain("Yes, and don't ask again");
    await tui.sendKeys("1");
    await tui.waitForText("ROUND_THREE_DONE", 30000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 240_000);

test.skipIf(SKIP_TMUX)("thread_send refuses unknown threads without creating anything", async () => {
  const fixture = createFixture("tool-send-refuse");
  const { gateway, bodies } = startToolGateway(
    "tell ghost hi",
    "thread_send",
    { name: "ghost", message: "hi" },
    "No thread named ghost",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("tell ghost hi");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("Start one with thread_new"))).toBe(true);
    expect(existsSync(join(fixture.home, ".fx", "threads"))).toBe(false);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 90_000);

test.skipIf(SKIP_TMUX)("a thread that needs approval asks in the main session under its own name and continues after approval", async () => {
  const fixture = createFixture("approval");
  let threadRequests = 0;
  const gateway = startDynamicFakeGateway(
    raw => {
      if (!String(raw).includes("write hello")) return fakeGatewayFinalText("MAIN_ANSWER_OK");
      threadRequests += 1;
      return threadRequests === 1
        ? fakeShellRun("thread_shell_1", "echo from-thread")
        : fakeGatewayFinalText("THREAD_DONE_AFTER_TOOL");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await TmuxSession.create({
      cmd: JSON.stringify(FX_BIN),
      cwd: fixture.workspace,
      isolated: true,
      remainOnExit: true,
      env: { ...env(fixture, gateway), FX_PERMISSION_MODE: "ask", FX_MAX_AGENT_STEPS: "4" },
    });
    await tui.waitForStableComposer(15000);
    await tui.sendText("hello");
    await tui.waitForText("MAIN_ANSWER_OK", 20000);
    await tui.waitForStableComposer(15000);

    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Thread alpha needs permission", 20000);
    await tui.waitForText("echo from-thread", 5000);

    await tui.sendText("1");
    let finished = false;
    for (let attempt = 0; attempt < 30 && !finished; attempt++) {
      await tui.sendText("/thread watch alpha");
      try {
        await tui.waitForText("THREAD_DONE_AFTER_TOOL", 1500);
        finished = true;
      } catch {
        // Still working.
      }
    }
    expect(finished).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("/new is refused while a thread is running and works once it is stopped", async () => {
  const fixture = createFixture("new-guard");
  const gateway = startDynamicFakeGateway(
    async raw => {
      if (!String(raw).includes("write hello")) return fakeGatewayFinalText("MAIN_ANSWER_OK");
      await Bun.sleep(15000);
      return fakeGatewayFinalText("SLOW_THREAD_DONE");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new slow write hello");
    await tui.waitForText("Started thread slow", 20000);
    await tui.sendText("/new");
    await tui.waitForText("Stop it with /thread stop slow", 10000);

    await tui.sendText("/thread stop slow");
    await tui.waitForText("Stopping slow", 10000);
    let stopped = false;
    for (let attempt = 0; attempt < 30 && !stopped; attempt++) {
      await tui.sendText("/new");
      try {
        await tui.waitForText("Stop it with /thread stop slow", 800);
      } catch {
        stopped = true;
      }
    }
    expect(stopped).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("threads survive a restart: resuming the session lists them and keeps their history", async () => {
  const fixture = createFixture("restart");
  const gateway = startGateway();
  let first: TmuxSession | undefined;
  let second: TmuxSession | undefined;
  try {
    first = await launch(fixture, gateway);
    await first.sendText("/thread new alpha write hello");
    await first.waitForText("Started thread alpha", 20000);
    let idle = false;
    for (let attempt = 0; attempt < 30 && !idle; attempt++) {
      await first.sendText("/thread list");
      try {
        await first.waitForText("alpha  idle", 1500);
        idle = true;
      } catch {
        // Still running.
      }
    }
    expect(idle).toBe(true);
    await first.kill();
    first = undefined;

    second = await TmuxSession.create({
      cmd: `${JSON.stringify(FX_BIN)} --resume last`,
      cwd: fixture.workspace,
      isolated: true,
      remainOnExit: true,
      env: env(fixture, gateway),
    });
    await second.waitForStableComposer(15000);
    await second.sendText("/thread list");
    await second.waitForText("alpha", 10000);

    // The thread keeps its own history, so a new message continues it.
    await second.sendText("/thread send alpha write hello again");
    await second.waitForText("Sent to alpha", 20000);
    let again = false;
    for (let attempt = 0; attempt < 30 && !again; attempt++) {
      await second.sendText("/thread watch alpha");
      try {
        await second.waitForText("THREAD_ANSWER_OK", 1500);
        again = true;
      } catch {
        // Not yet.
      }
    }
    expect(again).toBe(true);
  } finally {
    await first?.kill();
    await second?.kill();
    gateway.stop();
  }
}, 120_000);

function threadSessionIds(fixture: Fixture): string[] {
  const threadsDir = join(fixture.home, ".fx", "threads");
  const ids: string[] = [];
  for (const file of readdirSync(threadsDir).filter(f => f.endsWith(".json"))) {
    const registry = JSON.parse(readFileSync(join(threadsDir, file), "utf8"));
    for (const t of registry.threads) if (t.session_id) ids.push(t.session_id);
  }
  return ids;
}

test.skipIf(SKIP_TMUX)("/thread delete removes the session for good and the name restarts with no history", async () => {
  const fixture = createFixture("delete");
  const bodies: string[] = [];
  const gateway = startDynamicFakeGateway(
    raw => {
      const body = String(raw);
      bodies.push(body);
      if (body.includes("write again")) return fakeGatewayFinalText("SECOND_ANSWER_OK");
      if (body.includes("write hello")) return fakeGatewayFinalText("THREAD_ANSWER_OK");
      return fakeGatewayFinalText("MAIN_ANSWER_OK");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");

    const [oldSession] = threadSessionIds(fixture);
    expect(oldSession).toBeTruthy();
    const oldDir = join(fixture.home, ".fx", "sessions", oldSession);
    expect(existsSync(oldDir)).toBe(true);

    await tui.sendText("/thread delete alpha");
    await tui.waitForText("Deleted thread alpha", 20000);
    expect(existsSync(oldDir)).toBe(false);
    expect(threadSessionIds(fixture)).toEqual([]);

    await tui.sendText("/thread list");
    await tui.waitForText("No threads yet", 10000);

    // The name is free, and the new thread starts clean.
    await tui.sendText("/thread new alpha write again");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");
    let seen = false;
    for (let attempt = 0; attempt < 20 && !seen; attempt++) {
      await tui.sendText("/thread watch alpha");
      try {
        await tui.waitForText("SECOND_ANSWER_OK", 1500);
        seen = true;
      } catch {
        // Not there yet.
      }
    }
    expect(seen).toBe(true);
    const [newSession] = threadSessionIds(fixture);
    expect(newSession).not.toBe(oldSession);
    const last = bodies.filter(b => b.includes("write again")).at(-1) ?? "";
    expect(last.includes("write hello")).toBe(false);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("/thread delete is refused while the thread is running and works after it is stopped", async () => {
  const fixture = createFixture("delete-busy");
  const gateway = startDynamicFakeGateway(
    async raw => {
      if (!String(raw).includes("write hello")) return fakeGatewayFinalText("MAIN_ANSWER_OK");
      await Bun.sleep(15000);
      return fakeGatewayFinalText("SLOW_THREAD_DONE");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new slow write hello");
    await tui.waitForText("Started thread slow", 20000);
    const [session] = threadSessionIds(fixture);
    await tui.sendText("/thread delete slow");
    await tui.waitForText("is running. Stop it first", 10000);
    expect(existsSync(join(fixture.home, ".fx", "sessions", session))).toBe(true);

    await tui.sendText("/thread stop slow");
    await tui.waitForText("Stopping slow", 10000);
    let deleted = false;
    for (let attempt = 0; attempt < 30 && !deleted; attempt++) {
      await tui.sendText("/thread delete slow");
      try {
        await tui.waitForText("Deleted thread slow", 1500);
        deleted = true;
      } catch {
        // Still stopping.
      }
    }
    expect(deleted).toBe(true);
    expect(existsSync(join(fixture.home, ".fx", "sessions", session))).toBe(false);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("/thread completes its verbs from the composer", async () => {
  const fixture = createFixture("complete");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendLiteral("/thread sw");
    await tui.waitForText("switch", 10000);
    await tui.sendKeys("Tab");
    // Completing a verb that takes a name leaves the cursor ready for it.
    await tui.waitForText("/thread switch", 10000);
    await tui.sendText("main");
    await tui.waitForText("You are already in main", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 60_000);

test.skipIf(SKIP_TMUX)("/thread watch follows a running thread live and settles when it finishes", async () => {
  const fixture = createFixture("follow");
  const encoder = new TextEncoder();
  const gateway = startDynamicFakeGateway(
    raw => {
      if (!String(raw).includes("write hello")) return fakeGatewayFinalText("MAIN_ANSWER_OK");
      // A reply that arrives a line at a time, styled the way a model's markdown is.
      return new Response(
        new ReadableStream<Uint8Array>({
          async start(controller) {
            for (let step = 1; step <= 14; step++) {
              const delta = `\u001b[2m${step}.\u001b[22m step number ${step} of the plan\n`;
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "a", delta })}\n\n`));
              await Bun.sleep(350);
            }
            controller.enqueue(encoder.encode(`data: ${JSON.stringify({
              type: "finish",
              finishReason: { unified: "stop", raw: "stop" },
              usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } },
            })}\n\ndata: [DONE]\n\n`));
            controller.close();
          },
        }),
        { headers: { "content-type": "text/event-stream" } },
      );
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await tui.sendText("/thread watch alpha");

    // The same entry keeps updating while the thread works: new steps appear
    // and old ones scroll out of the window, with no second copy of the view.
    await tui.waitForText("running", 10000);
    await tui.waitForText("step number 9 of the plan", 15000);
    await tui.waitForText("earlier line", 5000);
    const midway = (await tui.capturePaneGrid()).join("\n");
    expect(midway).not.toContain("step number 1 of the plan");
    expect((midway.match(/alpha: /g) ?? []).length).toBe(1);
    // Styling from the model is dropped, not shown as stray characters.
    expect(midway).not.toContain("?[2m");

    // When the thread finishes the view settles as history and says so.
    await tui.waitForText("step number 14 of the plan", 15000);
    await tui.waitForText("alpha: idle", 10000);
    const done = (await tui.capturePaneGrid()).join("\n");
    expect(done).not.toContain("alpha: running");
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("the model starts a thread on request with thread_new and the thread works on its own", async () => {
  const fixture = createFixture("tool-new");
  const { gateway, bodies } = startToolGateway(
    "spin up a thread called beta",
    "thread_new",
    { name: "beta", task: "write hello for me" },
    "Started thread beta",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("spin up a thread called beta");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("Started thread beta"))).toBe(true);

    // It is a real thread: listed, working through its own turn, and followable.
    await waitForThreadIdle(tui, "beta");
    let seen = false;
    for (let attempt = 0; attempt < 20 && !seen; attempt++) {
      await tui.sendText("/thread watch beta 10");
      try {
        await tui.waitForText("THREAD_ANSWER_OK", 2000);
        seen = true;
      } catch {
        // Not there yet.
      }
    }
    expect(seen).toBe(true);
    // And it was registered, so it survives as an ordinary thread.
    const files = readdirSync(join(fixture.home, ".fx", "threads")).filter(f => f.endsWith(".json"));
    const registry = JSON.parse(readFileSync(join(join(fixture.home, ".fx", "threads"), files[0]), "utf8"));
    expect(registry.threads.map((t: { name: string }) => t.name)).toEqual(["beta"]);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 150_000);

test.skipIf(SKIP_TMUX)("thread_new asks for approval in ask mode and shows the name and task", async () => {
  const fixture = createFixture("tool-new-ask");
  const { gateway, bodies } = startToolGateway(
    "spin up a thread called beta",
    "thread_new",
    { name: "beta", task: "write hello for me" },
    "Started thread beta",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway, { FX_PERMISSION_MODE: "ask" });
    await tui.sendText("spin up a thread called beta");
    await tui.waitForText("write hello for me", 20000);
    expect(await tui.capturePane()).toContain("thread_new beta");
    // Nothing starts until the user approves.
    expect(bodies.some(b => b.includes("Started thread beta"))).toBe(false);
    expect(existsSync(join(fixture.home, ".fx", "threads"))).toBe(false);
    await tui.sendKeys("1");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("Started thread beta"))).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("thread_new refuses a name that already exists and tells the model to message it instead", async () => {
  const fixture = createFixture("tool-new-dup");
  const { gateway, bodies } = startToolGateway(
    "spin up another alpha",
    "thread_new",
    { name: "alpha", task: "write hello for me" },
    "A thread named alpha already exists",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new alpha write hello");
    await tui.waitForText("Started thread alpha", 20000);
    await waitForThreadIdle(tui, "alpha");
    await tui.sendText("spin up another alpha");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("A thread named alpha already exists"))).toBe(true);
    expect(bodies.some(b => b.includes("use thread_send"))).toBe(true);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("/thread with plain instructions starts a thread named from them", async () => {
  const fixture = createFixture("instructions");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread write hello for the docs page");
    await tui.waitForText("Started thread write-hello-docs-page", 20000);

    await tui.sendText("/thread list");
    await tui.waitForText("write-hello-docs-page", 10000);

    // The thread was given the instructions as its task and answered them.
    let seen = false;
    for (let attempt = 0; attempt < 20 && !seen; attempt++) {
      await tui.sendText("/thread watch write-hello-docs-page 10");
      try {
        await tui.waitForText("THREAD_ANSWER_OK", 2000);
        seen = true;
      } catch {
        // Not there yet.
      }
    }
    expect(seen).toBe(true);

    // The same words again make a second, distinct thread.
    await tui.sendText("/thread write hello for the docs page");
    await tui.waitForText("Started thread write-hello-docs-page-2", 20000);

    // A command word used wrongly is a usage error and starts nothing.
    await tui.sendText("/thread list everything");
    await tui.waitForText("usage: /thread", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);

test.skipIf(SKIP_TMUX)("a thread is found by a short, differently cased name from the command and from @thread: mentions", async () => {
  const fixture = createFixture("fuzzy");
  const { gateway, bodies } = startToolGateway(
    "compare with @thread:RISHAV",
    "thread_read",
    { name: "RISHAV" },
    "thread: write-hello-search-rishav",
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    // Filler words drop out of the generated name.
    await tui.sendText("/thread write hello and search up more about rishav");
    await tui.waitForText("Started thread write-hello-search-rishav", 20000);
    await waitForThreadIdle(tui, "write-hello-search-rishav");

    // The command takes a word of the name, in any case.
    await tui.sendText("/thread watch RISHAV 5");
    await tui.waitForText("THREAD_ANSWER_OK", 10000);

    // A mention names it the same loose way and the tool still reads it.
    await tui.sendText("compare with @thread:RISHAV");
    await tui.waitForText("TOOL_ROUND_DONE", 30000);
    expect(bodies.some(b => b.includes("thread: write-hello-search-rishav"))).toBe(true);

    // Two threads that share the word are reported, not guessed.
    await tui.sendText("/thread write hello and search up more about vercel");
    await tui.waitForText("Started thread write-hello-search-vercel", 20000);
    await tui.sendText("/thread watch hello");
    await tui.waitForText("matches several threads", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 150_000);

test.skipIf(SKIP_TMUX)("a thread is found by longer, looser text: word order, typos, and what it was asked", async () => {
  const fixture = createFixture("smart-search");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread write hello and research rishav portfolio pricing page");
    await tui.waitForText("Started thread write-hello-research-rishav", 20000);
    await waitForThreadIdle(tui, "write-hello-research-rishav");
    await tui.sendText("/thread new second write hello about vercel edge functions");
    await tui.waitForText("Started thread second", 20000);

    // The list says what each thread was asked, so a name is easy to place.
    await tui.sendText("/thread list");
    await tui.waitForText("\"write hello about vercel edge functions\"", 10000);

    // Word order, a typo, and words that only the instructions hold all find it.
    for (const query of ["portfolio rishav", "rishva", "pricing"]) {
      await tui.sendText(`/thread watch ${query} 3`);
      await tui.waitForText("THREAD_ANSWER_OK", 10000);
    }
    // A name beats a thread that only mentions the words in its instructions.
    await tui.sendText("/thread watch write hello 3");
    await tui.waitForText("THREAD_ANSWER_OK", 10000);
    // Several equally good matches are reported, not guessed.
    await tui.sendText("/thread new research-a write hello");
    await tui.waitForText("Started thread research-a", 20000);
    await tui.sendText("/thread new research-b write hello");
    await tui.waitForText("Started thread research-b", 20000);
    await tui.sendText("/thread watch research");
    await tui.waitForText("matches several threads", 10000);
    // Something unrelated finds nothing.
    await tui.sendText("/thread watch kubernetes");
    await tui.waitForText("No thread named kubernetes", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 150_000);

test.skipIf(SKIP_TMUX)("/thread status says which threads are still working, for how long, and what each did last", async () => {
  const fixture = createFixture("status");
  const encoder = new TextEncoder();
  const gateway = startDynamicFakeGateway(
    raw => {
      const body = String(raw);
      if (body.includes("slow job")) {
        return new Response(
          new ReadableStream<Uint8Array>({
            async start(controller) {
              for (let step = 1; step <= 40; step++) {
                controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "text-delta", id: "a", delta: `working on step ${step}\n` })}\n\n`));
                await Bun.sleep(300);
              }
              controller.enqueue(encoder.encode(`data: ${JSON.stringify({
                type: "finish",
                finishReason: { unified: "stop", raw: "stop" },
                usage: { inputTokens: { total: 3 }, outputTokens: { total: 5 } },
              })}\n\ndata: [DONE]\n\n`));
              controller.close();
            },
          }),
          { headers: { "content-type": "text/event-stream" } },
        );
      }
      if (body.includes("quick job")) return fakeGatewayFinalText("QUICK_DONE");
      return fakeGatewayFinalText("MAIN_ANSWER_OK");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread status");
    await tui.waitForText("No threads yet", 10000);

    await tui.sendText("/thread new quick quick job");
    await tui.waitForText("Started thread quick", 20000);
    await waitForThreadIdle(tui, "quick");
    await tui.sendText("/thread status");
    await tui.waitForText("No thread is working. All idle.", 10000);
    await tui.waitForText("quick  idle · last active", 10000);

    await tui.sendText("/thread new slow slow job please");
    await tui.waitForText("Started thread slow", 20000);
    let working = false;
    for (let attempt = 0; attempt < 20 && !working; attempt++) {
      await tui.sendText("/thread status");
      try {
        await tui.waitForText("last: working on step", 1500);
        working = true;
      } catch {
        // No output yet.
      }
    }
    expect(working).toBe(true);
    const pane = (await tui.capturePaneGrid()).join("\n");
    expect(pane).toContain("1 working, 1 idle");
    expect(pane).toMatch(/slow {2}running \d+s/);
    expect(pane).toContain("quick  idle");

    // Stopping it brings the summary back to all idle.
    await tui.sendText("/thread stop slow");
    await tui.waitForText("Stopping slow", 10000);
    let settled = false;
    for (let attempt = 0; attempt < 30 && !settled; attempt++) {
      await tui.sendText("/thread status");
      try {
        await tui.waitForText("No thread is working", 1500);
        settled = true;
      } catch {
        // Still stopping.
      }
    }
    expect(settled).toBe(true);

    // Status takes no arguments, and it is a command word, not a new thread.
    await tui.sendText("/thread status of everything");
    await tui.waitForText("usage: /thread", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 180_000);

test.skipIf(SKIP_TMUX)("/thread alone opens a menu to scroll the threads, switch into one, and leave it for main", async () => {
  const fixture = createFixture("menu");
  const gateway = startGateway();
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    // With no threads the menu still opens and lists main.
    await tui.sendText("/thread");
    await tui.waitForText("this session · you are here", 10000);
    await tui.sendKeys("Escape");
    await tui.waitForStableComposer(10000);

    await tui.sendText("/thread write hello for the docs");
    await tui.waitForText("Started thread write-hello-docs", 20000);
    await tui.sendText("/thread new second write hello again");
    await tui.waitForText("Started thread second", 20000);
    await waitForThreadIdle(tui, "second");

    await tui.sendText("/thread");
    await tui.waitForText("enter switch", 10000);
    let grid = (await tui.capturePaneGrid()).join("\n");
    expect(grid).toContain("Threads");
    expect(grid).toContain("write-hello-docs");
    expect(grid).toContain("second");
    expect(grid).toMatch(/❯ main\s+this session/);

    // Scrolling moves the marker, and Escape closes without switching.
    await tui.sendKeys("Down");
    await tui.waitForText("❯ write-hello-docs", 10000);
    await tui.sendKeys("Escape");
    await tui.waitForStableComposer(10000);
    expect((await tui.capturePaneGrid()).join("\n")).not.toContain("enter switch");

    // Enter switches into the selected thread, with its history.
    await tui.sendText("/thread");
    await tui.waitForText("enter switch", 10000);
    await tui.sendKeys("Down");
    await tui.sendKeys("Enter");
    await tui.waitForText("Switched to write-hello-docs", 20000);
    await tui.waitForText("THREAD_ANSWER_OK", 10000);

    // Inside the thread the menu marks where you are and offers main to leave.
    await tui.sendText("/thread");
    await tui.waitForText("leave this thread", 10000);
    grid = (await tui.capturePaneGrid()).join("\n");
    expect(grid).toMatch(/❯ write-hello-docs\s+you are here/);
    await tui.sendKeys("Up");
    await tui.sendKeys("Enter");
    await tui.waitForText("Switched to main", 20000);
    await tui.waitForText("MAIN_ANSWER_OK", 10000);

    // Choosing where you already are says so instead of switching.
    await tui.sendText("/thread");
    await tui.waitForText("enter switch", 10000);
    await tui.sendKeys("Enter");
    await tui.waitForText("You are already in main", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 180_000);

test.skipIf(SKIP_TMUX)("choosing a thread in the menu while another is running explains why it cannot switch", async () => {
  const fixture = createFixture("menu-busy");
  const gateway = startDynamicFakeGateway(
    async raw => {
      if (!String(raw).includes("write hello")) return fakeGatewayFinalText("MAIN_ANSWER_OK");
      await Bun.sleep(10000);
      return fakeGatewayFinalText("SLOW_DONE");
    },
    { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] },
  );
  let tui: TmuxSession | undefined;
  try {
    tui = await launch(fixture, gateway);
    await tui.sendText("/thread new slow write hello");
    await tui.waitForText("Started thread slow", 20000);
    await tui.sendText("/thread");
    await tui.waitForText("running", 10000);
    await tui.sendKeys("Down");
    await tui.sendKeys("Enter");
    await tui.waitForText("still running and would stop", 10000);
  } finally {
    await tui?.kill();
    gateway.stop();
  }
}, 120_000);
